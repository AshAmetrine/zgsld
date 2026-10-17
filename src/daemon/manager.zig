const std = @import("std");
const ipc = @import("ipc");
const SocketPair = @import("../SocketPair.zig");
const worker = @import("worker.zig");
const log = std.log.scoped(.zgsld);
const Config = @import("../Config.zig");
const build_options = @import("build_options");

var greeter_worker_pid = std.atomic.Value(std.posix.pid_t).init(0);
var session_worker_pid = std.atomic.Value(std.posix.pid_t).init(0);
var shutdown_requested = std.atomic.Value(bool).init(false);

const ForwardIpcCtx = struct {
    io: std.Io,
    src: *ipc.Connection,
    dst: *ipc.Connection,
    result: anyerror!void = {},
};

const SpawnedWorkers = struct {
    session_proc: std.process.Child,
    greeter_proc: std.process.Child,
    session_file: std.Io.File,
    greeter_file: std.Io.File,
};

pub const SessionManagerRunOpts = struct {
    ipc_codec: *const ipc.Codec = &ipc.Codec.binary,
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    self_exe_path: []const u8,
    config: Config,
};

pub fn run(opts: SessionManagerRunOpts) !void {
    installSignalHandlers();

    if (!build_options.x11_support and opts.config.greeter.session_type == .x11) {
        log.err("Greeter X11 session type requested, but zgsld was built without -Dx11 support", .{});
        return error.X11UnsupportedBuild;
    }

    if (!try userExists(opts.config.greeter.user)) {
        log.err("Greeter user not found: {s}", .{opts.config.greeter.user});
        return error.GreeterUserNotFound;
    }

    try opts.config.vt.normalize(opts.io, opts.env_map);

    if (try shouldRunAutologin(opts.config)) {
        defer opts.config.vt.normalize(opts.io, opts.env_map) catch {};
        if (shutdown_requested.load(.seq_cst)) return;
        try runAutologin(opts);
        if (shutdown_requested.load(.seq_cst)) return;
    }

    while (true) {
        defer opts.config.vt.normalize(opts.io, opts.env_map) catch {};
        if (shutdown_requested.load(.seq_cst)) return;

        var spawned = try spawnWorkers(opts);

        session_worker_pid.store(spawned.session_proc.id.?, .seq_cst);
        greeter_worker_pid.store(spawned.greeter_proc.id.?, .seq_cst);
        defer terminateWorkerAndClearPid(opts.io, &session_worker_pid, &spawned.session_proc);
        defer terminateWorkerAndClearPid(opts.io, &greeter_worker_pid, &spawned.greeter_proc);

        if (shutdown_requested.load(.seq_cst)) {
            std.posix.kill(spawned.greeter_proc.id.?, std.posix.SIG.TERM) catch {};
            std.posix.kill(spawned.session_proc.id.?, std.posix.SIG.TERM) catch {};
        }

        try forwardIpc(opts.io, spawned.greeter_file, spawned.session_file, &spawned.greeter_proc, opts.ipc_codec);
        try waitWorkerAndClearPid(opts.io, &greeter_worker_pid, &spawned.greeter_proc);
        try waitWorkerAndClearPid(opts.io, &session_worker_pid, &spawned.session_proc);
    }
}

fn spawnWorkers(opts: SessionManagerRunOpts) !SpawnedWorkers {
    log.debug("Spawning Session Worker...", .{});
    const session_socks = try SocketPair.init();
    errdefer session_socks.parent.close(opts.io);

    var session_proc = blk: {
        defer session_socks.child.close(opts.io);
        break :blk try worker.process.spawn(.{
            .allocator = opts.allocator,
            .io = opts.io,
            .env_map = opts.env_map,
            .worker_path = opts.self_exe_path,
            .config = opts.config,
            .session_class = .user,
            .ipc_file = session_socks.child,
        });
    };
    errdefer session_proc.kill(opts.io);

    log.debug("Spawning Greeter worker...", .{});
    const greeter_socks = try SocketPair.init();
    errdefer greeter_socks.parent.close(opts.io);

    const greeter_proc = blk: {
        defer greeter_socks.child.close(opts.io);
        break :blk try worker.process.spawn(.{
            .allocator = opts.allocator,
            .io = opts.io,
            .env_map = opts.env_map,
            .worker_path = opts.self_exe_path,
            .config = opts.config,
            .session_class = .greeter,
            .ipc_file = greeter_socks.child,
        });
    };

    return .{
        .session_proc = session_proc,
        .greeter_proc = greeter_proc,
        .session_file = session_socks.parent,
        .greeter_file = greeter_socks.parent,
    };
}

fn runAutologin(opts: SessionManagerRunOpts) !void {
    const autologin = opts.config.autologin;

    if (autologin.timeout_seconds != 0) {
        try opts.config.vt.activate(opts.io);
        var watcher = opts.config.vt.watchInput(opts.io, opts.env_map) catch |err| {
            if (shutdown_requested.load(.seq_cst)) return;
            log.warn("Failed to watch for autologin interruption: {s}", .{@errorName(err)});
            return;
        };
        defer watcher.deinit(opts.io);

        const interrupted = waitAutologinCountdown(opts.io, &watcher, autologin.timeout_seconds) catch |err| {
            if (shutdown_requested.load(.seq_cst)) return;
            log.warn("Failed to watch for autologin interruption: {s}", .{@errorName(err)});
            return;
        };
        if (shutdown_requested.load(.seq_cst)) return;
        if (interrupted) {
            log.debug("Autologin interrupted; starting greeter", .{});
            return;
        }
    }

    if (shutdown_requested.load(.seq_cst)) return;

    log.debug("Spawning Autologin worker...", .{});
    var autologin_proc = try worker.process.spawn(.{
        .allocator = opts.allocator,
        .io = opts.io,
        .env_map = opts.env_map,
        .worker_path = opts.self_exe_path,
        .config = opts.config,
        .session_class = .autologin,
        .ipc_file = null,
    });

    session_worker_pid.store(autologin_proc.id.?, .seq_cst);
    defer terminateWorkerAndClearPid(opts.io, &session_worker_pid, &autologin_proc);

    if (shutdown_requested.load(.seq_cst)) {
        std.posix.kill(autologin_proc.id.?, std.posix.SIG.TERM) catch {};
    }

    waitWorkerAndClearPid(opts.io, &session_worker_pid, &autologin_proc) catch |err| {
        log.warn("Autologin failed: {s}", .{@errorName(err)});
    };
}

fn waitAutologinCountdown(io: std.Io, watcher: *Config.Vt.InputWatcher, timeout_seconds: u64) !bool {
    defer clearAutologinCountdown(io, &watcher.file);

    var remaining = timeout_seconds;
    while (remaining > 0) : (remaining -= 1) {
        writeAutologinCountdown(io, &watcher.file, remaining);
        const interrupted = try watcher.waitForInput(std.time.ms_per_s);
        if (shutdown_requested.load(.seq_cst) or interrupted) return true;
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
    greeter_worker_proc: *std.process.Child,
    ipc_codec: *const ipc.Codec,
) !void {
    var greeter_conn = ipc.Connection.init(greeter_file, .{ .codec = ipc_codec });
    defer greeter_conn.deinit(io);
    var worker_conn = ipc.Connection.init(worker_file, .{});
    defer worker_conn.deinit(io);

    var worker_to_greeter = ForwardIpcCtx{
        .io = io,
        .src = &worker_conn,
        .dst = &greeter_conn,
    };

    const worker_to_greeter_thread = try std.Thread.spawn(.{}, forwardIpcThread, .{&worker_to_greeter});
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

        while (true) {
            const event = greeter_conn.readEvent(io_reader, &event_buf) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };

            if (event == .start_session) {
                try waitWorkerAndClearPid(io, &greeter_worker_pid, greeter_worker_proc);
            }

            try worker_conn.writeEvent(io_writer, &event);
            try io_writer.flush();
        }
    }

    return worker_to_greeter.result;
}

fn waitWorkerAndClearPid(
    io: std.Io,
    pid_slot: *std.atomic.Value(std.posix.pid_t),
    proc: *std.process.Child,
) !void {
    defer pid_slot.store(0, .seq_cst);
    if (proc.id == null) return;
    const term = try proc.wait(io);
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

fn terminateWorkerAndClearPid(
    io: std.Io,
    pid_slot: *std.atomic.Value(std.posix.pid_t),
    proc: *std.process.Child,
) void {
    defer pid_slot.store(0, .seq_cst);
    proc.kill(io);
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
    var writer = ctx.dst.writer(ctx.io, &wbuf);
    const io_reader = &reader.interface;
    const io_writer = &writer.interface;

    while (true) {
        const event = ctx.src.readEvent(io_reader, &event_buf) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };

        try ctx.dst.writeEvent(io_writer, &event);
        try io_writer.flush();
    }
}

fn installSignalHandlers() void {
    const sigact = std.posix.Sigaction{
        .handler = .{ .handler = forwardSignalToWorker },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };

    const forward_signals = [_]std.posix.SIG{
        std.posix.SIG.TERM,
        std.posix.SIG.HUP,
        std.posix.SIG.QUIT,
    };

    for (forward_signals) |sig| {
        std.posix.sigaction(sig, &sigact, null);
    }
}

fn forwardSignalToWorker(sig: std.posix.SIG) callconv(.c) void {
    const gwpid = greeter_worker_pid.load(.seq_cst);
    const swpid = session_worker_pid.load(.seq_cst);
    shutdown_requested.store(true, .seq_cst);
    if (gwpid > 0) {
        std.posix.kill(gwpid, sig) catch {};
    }
    if (swpid > 0) {
        std.posix.kill(swpid, sig) catch {};
    }
}

fn shouldRunAutologin(config: Config) !bool {
    const autologin = config.autologin;
    const autologin_user = autologin.user orelse return false;
    if (autologin_user.len == 0) return false;

    if (!build_options.x11_support and autologin.session_type == .x11) {
        log.warn("Autologin X11 session type requested, but zgsld was built without -Dx11 support; starting greeter instead", .{});
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
