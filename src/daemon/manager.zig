const std = @import("std");
const ipc = @import("ipc");
const SocketPair = @import("../SocketPair.zig");
const worker = @import("worker.zig");
const Shutdown = @import("Shutdown.zig");
const log = std.log.scoped(.zgsld);
const Config = @import("../Config.zig");
const build_options = @import("build_options");

const ForwardIpcCtx = struct {
    io: std.Io,
    src: *ipc.Connection,
    dst: *ipc.Connection,
    writer: *std.Io.Writer,
    mutex: std.Io.Mutex = .init,
    authenticated: bool = false,
    result: anyerror!void = {},

    fn sendEvent(self: *ForwardIpcCtx, event: ipc.Event) !void {
        try self.dst.writeEvent(self.writer, &event);
        try self.writer.flush();
    }

    fn acceptSession(self: *ForwardIpcCtx, info: ipc.SessionInfo) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.authenticated) return error.UnexpectedEvent;
        info.validate(build_options.x11_support) catch {
            try self.sendEvent(.{ .err = .{ .code = .invalid_request } });
            return false;
        };
        try self.sendEvent(.session_accepted);
        self.authenticated = false;
        return true;
    }
};

/// Prevents forwarded events from interrupting codec replies before they're flushed
const ReplyWriter = struct {
    writer: std.Io.Writer = .{
        .vtable = &.{ .drain = drain, .flush = flush },
        .buffer = &.{},
    },
    ctx: *ForwardIpcCtx,
    locked: bool = false,

    fn unlock(self: *ReplyWriter) void {
        if (!self.locked) return;
        self.locked = false;
        self.ctx.mutex.unlock(self.ctx.io);
    }

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) !usize {
        const self: *ReplyWriter = @fieldParentPtr("writer", writer);
        if (!self.locked) {
            self.ctx.mutex.lockUncancelable(self.ctx.io);
            self.locked = true;
        }
        return self.ctx.writer.writeSplat(data, splat);
    }

    fn flush(writer: *std.Io.Writer) !void {
        const self: *ReplyWriter = @fieldParentPtr("writer", writer);
        if (!self.locked) return;
        defer self.unlock();
        try self.ctx.writer.flush();
    }
};

const SpawnedWorkers = struct {
    session: *Shutdown.Worker,
    greeter: *Shutdown.Worker,
    session_file: std.Io.File,
    greeter_file: std.Io.File,
};

pub const SessionManagerRunOpts = struct {
    ipc_codec: *ipc.Codec = ipc.Codec.binary,
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    self_exe_path: []const u8,
    config: Config,
};

pub fn run(opts: SessionManagerRunOpts) !void {
    var shutdown = try Shutdown.init(opts.io);
    defer shutdown.deinit();
    try shutdown.start();

    if (!build_options.x11_support and opts.config.greeter.session_type == .x11) {
        log.err("Greeter X11 session type requested, but zgsld was built without X11 support", .{});
        return error.X11UnsupportedBuild;
    }

    if (!try userExists(opts.config.greeter.user)) {
        log.err("Greeter user not found: {s}", .{opts.config.greeter.user});
        return error.GreeterUserNotFound;
    }

    try opts.config.vt.normalize(opts.io, opts.env_map);

    if (try shouldRunAutologin(opts.config)) {
        defer opts.config.vt.normalize(opts.io, opts.env_map) catch {};
        if (Shutdown.shutdownRequested()) return;
        try runAutologin(opts, &shutdown);
        if (Shutdown.shutdownRequested()) return;
    }

    while (true) {
        defer opts.config.vt.normalize(opts.io, opts.env_map) catch {};
        if (Shutdown.shutdownRequested()) return;

        const spawned = try spawnWorkers(opts, &shutdown);
        defer {
            shutdown.requestStop(spawned.greeter, 0);
            shutdown.requestStop(spawned.session, 0);
            shutdown.stop(spawned.greeter);
            shutdown.stop(spawned.session);
        }

        try forwardIpc(
            opts.io,
            spawned.greeter_file,
            spawned.session_file,
            &shutdown,
            spawned.greeter,
            spawned.session,
            opts.ipc_codec,
        );
        try waitWorker(&shutdown, spawned.greeter);
        waitWorker(&shutdown, spawned.session) catch |err| switch (err) {
            error.WorkerError => {
                log.err("Session worker failed; returning to greeter", .{});
            },
            else => return err,
        };
    }
}

fn spawnWorkers(opts: SessionManagerRunOpts, shutdown: *Shutdown) !SpawnedWorkers {
    const session_socks = try SocketPair.init();
    errdefer session_socks.parent.close(opts.io);
    const session_proc = try spawnWorker(opts, shutdown, .user, session_socks);
    errdefer shutdown.stop(session_proc);

    const greeter_socks = try SocketPair.init();
    errdefer greeter_socks.parent.close(opts.io);
    const greeter_proc = try spawnWorker(opts, shutdown, .greeter, greeter_socks);
    return .{
        .session = session_proc,
        .greeter = greeter_proc,
        .session_file = session_socks.parent,
        .greeter_file = greeter_socks.parent,
    };
}

fn spawnWorker(
    opts: SessionManagerRunOpts,
    shutdown: *Shutdown,
    session_class: worker.process.SessionClass,
    ipc_socks: ?SocketPair,
) !*Shutdown.Worker {
    defer if (ipc_socks) |socks| socks.child.close(opts.io);
    const control = try Shutdown.Connection.socketPair();
    defer control.child.close(opts.io);
    errdefer control.parent.close(opts.io);
    var proc = try worker.process.spawn(.{
        .allocator = opts.allocator,
        .io = opts.io,
        .env_map = opts.env_map,
        .worker_path = opts.self_exe_path,
        .config = opts.config,
        .session_class = session_class,
        .ipc_file = if (ipc_socks) |socks| socks.child else null,
        .control_file = control.child,
    });
    errdefer {
        std.posix.kill(proc.id.?, .KILL) catch {};
        _ = proc.wait(opts.io) catch {};
    }
    return shutdown.addWorker(proc, control.parent, if (ipc_socks) |socks| socks.parent else null);
}

fn runAutologin(opts: SessionManagerRunOpts, shutdown: *Shutdown) !void {
    const autologin = opts.config.autologin;

    if (autologin.timeout_seconds != 0) {
        try opts.config.vt.activate(opts.io);
        var watcher = opts.config.vt.watchInput(opts.io, opts.env_map) catch |err| {
            if (Shutdown.shutdownRequested()) return;
            log.warn("Failed to watch for autologin interruption: {s}", .{@errorName(err)});
            return;
        };
        defer watcher.deinit(opts.io);

        const interrupted = waitAutologinCountdown(opts.io, &watcher, autologin.timeout_seconds) catch |err| {
            if (Shutdown.shutdownRequested()) return;
            log.warn("Failed to watch for autologin interruption: {s}", .{@errorName(err)});
            return;
        };
        if (Shutdown.shutdownRequested()) return;
        if (interrupted) {
            log.debug("Autologin interrupted; starting greeter", .{});
            return;
        }
    }

    if (Shutdown.shutdownRequested()) return;

    log.debug("Spawning Autologin worker...", .{});
    const autologin_proc = try spawnWorker(opts, shutdown, .autologin, null);
    defer shutdown.stop(autologin_proc);

    waitWorker(shutdown, autologin_proc) catch |err| {
        log.warn("Autologin failed: {s}", .{@errorName(err)});
    };
}

fn waitAutologinCountdown(io: std.Io, watcher: *Config.Vt.InputWatcher, timeout_seconds: u64) !bool {
    defer clearAutologinCountdown(io, &watcher.file);

    var remaining = timeout_seconds;
    while (remaining > 0) : (remaining -= 1) {
        writeAutologinCountdown(io, &watcher.file, remaining);
        const interrupted = try watcher.waitForInput(std.time.ms_per_s);
        if (Shutdown.shutdownRequested() or interrupted) return true;
    }
    return false;
}

fn writeAutologinCountdown(io: std.Io, tty_file: *std.Io.File, remaining_seconds: u64) void {
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "\rLaunching session in {d}... (Press any key to interrupt)\x1b[K",
        .{remaining_seconds},
    ) catch return;
    tty_file.writeStreamingAll(io, msg) catch return;
}

fn clearAutologinCountdown(io: std.Io, tty_file: *std.Io.File) void {
    tty_file.writeStreamingAll(io, "\r\x1b[K") catch return;
}

fn forwardIpc(
    io: std.Io,
    greeter_file: std.Io.File,
    worker_file: std.Io.File,
    shutdown: *Shutdown,
    greeter_worker_proc: *Shutdown.Worker,
    session_worker_proc: *Shutdown.Worker,
    ipc_codec: *ipc.Codec,
) !void {
    // A completed handoff has already reaped the greeter. Otherwise both
    // workers belong to the aborted login attempt.
    defer if (greeter_worker_proc.process.id != null) {
        shutdown.requestStop(greeter_worker_proc, 0);
        shutdown.requestStop(session_worker_proc, 0);
    };
    var greeter_conn = ipc.Connection.init(greeter_file, .{ .codec = ipc_codec });
    defer greeter_conn.deinit(io);
    var worker_conn = ipc.Connection.init(worker_file, .{});
    defer worker_conn.deinit(io);

    var reply_buf: [ipc.event_buf_size]u8 = undefined;
    var reply_writer = greeter_conn.writer(io, &reply_buf);
    var worker_to_greeter = ForwardIpcCtx{
        .io = io,
        .src = &worker_conn,
        .dst = &greeter_conn,
        .writer = &reply_writer.interface,
    };

    const worker_to_greeter_thread = try std.Thread.spawn(
        .{},
        forwardIpcThread,
        .{&worker_to_greeter},
    );
    {
        defer {
            _ = std.c.shutdown(greeter_conn.file.handle, 2);
            _ = std.c.shutdown(worker_conn.file.handle, 2);
            worker_to_greeter_thread.join();
        }

        var event_buf: [ipc.event_buf_size]u8 = undefined;
        var rbuf: [ipc.event_buf_size]u8 = undefined;
        var wbuf: [ipc.event_buf_size]u8 = undefined;

        var reader = greeter_conn.reader(io, &rbuf);
        var writer = worker_conn.writer(io, &wbuf);
        const io_reader = &reader.interface;
        const io_writer = &writer.interface;
        var replies = ReplyWriter{ .ctx = &worker_to_greeter };

        while (true) {
            const read_result = blk: {
                defer replies.unlock();
                break :blk greeter_conn.readEvent(io_reader, &replies.writer, &event_buf);
            };
            const event = read_result catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };

            switch (event) {
                .pam_start_auth, .login_cancel => {
                    worker_to_greeter.mutex.lockUncancelable(io);
                    worker_to_greeter.authenticated = false;
                    worker_to_greeter.mutex.unlock(io);
                },
                .start_session => |info| {
                    if (!try worker_to_greeter.acceptSession(info)) continue;
                    shutdown.requestStop(greeter_worker_proc, 5);
                    try waitWorker(shutdown, greeter_worker_proc);
                    if (Shutdown.shutdownRequested()) return error.Shutdown;
                },
                else => {},
            }

            try worker_conn.writeEvent(io_writer, &event);
            try io_writer.flush();
        }
    }

    return worker_to_greeter.result;
}

fn waitWorker(shutdown: *Shutdown, proc: *Shutdown.Worker) !void {
    if (proc.process.id == null) return;
    const term = try shutdown.wait(proc);
    if (proc.forced) return;
    const code: u8 = if (term == .exited) term.exited else 1;
    switch (code) {
        0 => {},
        2 => {
            log.err("Greeter exited before starting auth", .{});
            return error.GreeterError;
        },
        else => return error.WorkerError,
    }
}

fn forwardIpcThread(ctx: *ForwardIpcCtx) void {
    defer {
        _ = std.c.shutdown(ctx.src.file.handle, 2);
        _ = std.c.shutdown(ctx.dst.file.handle, 2);
    }
    ctx.result = forwardIpcEvents(ctx);
}

fn forwardIpcEvents(ctx: *ForwardIpcCtx) !void {
    var event_buf: [ipc.event_buf_size]u8 = undefined;
    var rbuf: [ipc.event_buf_size]u8 = undefined;
    var wbuf: [ipc.event_buf_size]u8 = undefined;

    var reader = ctx.src.reader(ctx.io, &rbuf);
    var writer = ctx.src.writer(ctx.io, &wbuf);
    const io_reader = &reader.interface;
    const io_writer = &writer.interface;

    while (true) {
        const event = ctx.src.readEvent(io_reader, io_writer, &event_buf) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };

        ctx.mutex.lockUncancelable(ctx.io);
        defer ctx.mutex.unlock(ctx.io);
        switch (event) {
            .pam_auth_result => |result| ctx.authenticated = result.ok,
            .err, .login_cancelled => ctx.authenticated = false,
            else => {},
        }
        try ctx.sendEvent(event);
    }
}

fn shouldRunAutologin(config: Config) !bool {
    const autologin = config.autologin;
    const autologin_user = autologin.user orelse return false;
    if (autologin_user.len == 0) return false;

    if (!build_options.x11_support and autologin.session_type == .x11) {
        log.warn("Autologin X11 session type requested, but zgsld was built without X11 support; starting greeter instead", .{});
        return false;
    }

    if (!try userExists(autologin_user)) {
        log.warn("Autologin user not found: {s}; starting greeter instead", .{autologin_user});
        return false;
    }

    const autologin_cmd = autologin.command orelse {
        log.warn("Autologin command is unset; starting greeter instead", .{});
        return false;
    };
    if (autologin_cmd.len == 0) {
        log.warn("Autologin command is empty; starting greeter instead", .{});
        return false;
    }

    return true;
}

fn userExists(user: []const u8) !bool {
    var user_buf: [64]u8 = undefined;
    const user_z = try std.fmt.bufPrintSentinel(&user_buf, "{s}", .{user}, 0);
    return std.c.getpwnam(user_z) != null;
}
