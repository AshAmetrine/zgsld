const std = @import("std");
const Ipc = @import("Ipc");
const SocketPair = @import("SocketPair.zig");
const vt = @import("vt");
const worker = @import("worker.zig");
const log = std.log.scoped(.zgsld);
const Config = @import("Config.zig");
const build_options = @import("build_options");

var greeter_worker_pid = std.atomic.Value(std.posix.pid_t).init(0);
var session_worker_pid = std.atomic.Value(std.posix.pid_t).init(0);
var shutdown_requested = std.atomic.Value(u8).init(0);

const ForwardIpcCtx = struct {
    src: *Ipc.Connection,
    dst: *Ipc.Connection,
    err: ?anyerror = null,
};

const SpawnedWorkers = struct {
    session_proc: worker.WorkerProcess,
    greeter_proc: worker.WorkerProcess,
    session_fd: std.posix.fd_t,
    greeter_fd: std.posix.fd_t,
};

pub const SessionManagerRunOpts = if (build_options.standalone)
    struct {
        allocator: std.mem.Allocator,
        self_exe_path: [:0]const u8,
        greeter_cmd: []const u8,
        config: Config,
    }
else
    struct {
        allocator: std.mem.Allocator,
        self_exe_path: [:0]const u8,
        config: Config,
    };

pub fn run(opts: SessionManagerRunOpts) !void {
    installSignalHandlers();

    if (!build_options.x11_support and opts.config.greeter.session_type == .x11) {
        log.err("Greeter X11 session type requested, but zgsld was built without -Dx11 support", .{});
        return error.X11UnsupportedBuild;
    }

    try vt.normalizeTty(opts.config.vt);

    if (!try userExists(opts.config.greeter.user)) {
        log.err("Greeter user not found: {s}", .{opts.config.greeter.user});
        return error.GreeterUserNotFound;
    }

    const run_autologin = try shouldRunAutologin(opts.config);
    if (run_autologin) {
        defer vt.normalizeTty(opts.config.vt) catch {};
        if (shutdown_requested.load(.seq_cst) != 0) return;
        try runAutologin(opts);
        if (shutdown_requested.load(.seq_cst) != 0) return;
    }

    while (true) {
        defer vt.normalizeTty(opts.config.vt) catch {};
        if (shutdown_requested.load(.seq_cst) != 0) return;

        const greeter_cmd = if (build_options.standalone) opts.greeter_cmd else {};
        const spawned = try spawnWorkers(.{
            .allocator = opts.allocator,
            .worker_path = opts.self_exe_path,
            .greeter_cmd = greeter_cmd,
            .config = opts.config,
        });

        session_worker_pid.store(spawned.session_proc.pid, .seq_cst);
        greeter_worker_pid.store(spawned.greeter_proc.pid, .seq_cst);
        defer terminateWorkerAndClearPid(&session_worker_pid);
        defer terminateWorkerAndClearPid(&greeter_worker_pid);

        if (shutdown_requested.load(.seq_cst) != 0) {
            std.posix.kill(spawned.greeter_proc.pid, std.posix.SIG.TERM) catch {};
            std.posix.kill(spawned.session_proc.pid, std.posix.SIG.TERM) catch {};
        }

        try forwardIpc(spawned.greeter_fd, spawned.session_fd, spawned.greeter_proc);
        try waitWorkerAndClearPid(&greeter_worker_pid, spawned.greeter_proc);
        try waitWorkerAndClearPid(&session_worker_pid, spawned.session_proc);
    }
}

const SpawnWorkersOpts = struct {
    allocator: std.mem.Allocator,
    worker_path: [:0]const u8,
    greeter_cmd: if (build_options.standalone) []const u8 else void,
    config: Config,
};

fn spawnWorkers(opts: SpawnWorkersOpts) !SpawnedWorkers {
    log.debug("Spawning Session Worker...", .{});
    const session_socks = try SocketPair.init(true);
    errdefer std.posix.close(session_socks.parent);

    const session_proc = blk: {
        defer std.posix.close(session_socks.child);
        break :blk try worker.WorkerProcess.spawn(.{
            .allocator = opts.allocator,
            .worker_path = opts.worker_path,
            .greeter_cmd = opts.greeter_cmd, // ignored
            .config = opts.config,
            .session_class = .user,
            .ipc_fd = session_socks.child,
        });
    };
    errdefer {
        std.posix.kill(session_proc.pid, std.posix.SIG.TERM) catch {};
        _ = std.posix.waitpid(session_proc.pid, 0);
    }

    log.debug("Spawning Greeter worker...", .{});
    const greeter_socks = try SocketPair.init(true);
    errdefer std.posix.close(greeter_socks.parent);

    const greeter_proc = blk: {
        defer std.posix.close(greeter_socks.child);
        break :blk try worker.WorkerProcess.spawn(.{
            .allocator = opts.allocator,
            .worker_path = opts.worker_path,
            .greeter_cmd = opts.greeter_cmd,
            .config = opts.config,
            .session_class = .greeter,
            .ipc_fd = greeter_socks.child,
        });
    };

    return .{
        .session_proc = session_proc,
        .greeter_proc = greeter_proc,
        .session_fd = session_socks.parent,
        .greeter_fd = greeter_socks.parent,
    };
}

fn runAutologin(opts: SessionManagerRunOpts) !void {
    const autologin = opts.config.autologin;

    if (autologin.timeout_seconds != 0) {
        var remaining = autologin.timeout_seconds;
        var watcher = vt.TtyInputWatcher.init(opts.config.vt) catch |err| {
            if (shutdown_requested.load(.seq_cst) != 0) return;
            log.warn("Failed to watch for autologin interruption: {s}", .{@errorName(err)});
            return;
        };
        defer watcher.deinit();

        while (remaining > 0) : (remaining -= 1) {
            writeAutologinCountdown(&watcher.file, remaining);

            const interrupted = watcher.waitForInput(std.time.ms_per_s) catch |err| {
                clearAutologinCountdown(&watcher.file);
                if (shutdown_requested.load(.seq_cst) != 0) return;
                log.warn("Failed to watch for autologin interruption: {s}", .{@errorName(err)});
                return;
            };
            if (shutdown_requested.load(.seq_cst) != 0) {
                clearAutologinCountdown(&watcher.file);
                return;
            }
            if (interrupted) {
                clearAutologinCountdown(&watcher.file);
                log.debug("Autologin interrupted; starting greeter", .{});
                return;
            }
        }
        clearAutologinCountdown(&watcher.file);
    }

    if (shutdown_requested.load(.seq_cst) != 0) return;

    const autologin_proc = try spawnAutologinWorker(.{
        .allocator = opts.allocator,
        .worker_path = opts.self_exe_path,
        .config = opts.config,
    });

    session_worker_pid.store(autologin_proc.pid, .seq_cst);
    defer terminateWorkerAndClearPid(&session_worker_pid);

    if (shutdown_requested.load(.seq_cst) != 0) {
        std.posix.kill(autologin_proc.pid, std.posix.SIG.TERM) catch {};
    }

    waitWorkerAndClearPid(&session_worker_pid, autologin_proc) catch |err| {
        log.warn("Autologin failed: {s}", .{@errorName(err)});
        return;
    };
}

const SpawnAutologinWorkerOpts = struct {
    allocator: std.mem.Allocator,
    worker_path: [:0]const u8,
    config: Config,
};

fn spawnAutologinWorker(opts: SpawnAutologinWorkerOpts) !worker.WorkerProcess {
    log.debug("Spawning Autologin worker...", .{});
    const greeter_cmd = if (build_options.standalone) "" else {};
    return worker.WorkerProcess.spawn(.{
        .allocator = opts.allocator,
        .worker_path = opts.worker_path,
        .greeter_cmd = greeter_cmd,
        .config = opts.config,
        .session_class = .autologin,
        .ipc_fd = null,
    });
}

fn writeAutologinCountdown(tty_file: *std.fs.File, remaining_seconds: u64) void {
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "\rLaunching session in {d}... (Press any key to interrupt)\x1b[K",
        .{remaining_seconds},
    ) catch return;
    _ = tty_file.write(msg) catch return;
}

fn clearAutologinCountdown(tty_file: *std.fs.File) void {
    _ = tty_file.write("\r\x1b[K") catch return;
}

fn forwardIpc(
    greeter_fd: std.posix.fd_t,
    worker_fd: std.posix.fd_t,
    greeter_worker_proc: worker.WorkerProcess,
) !void {
    var greeter_conn = Ipc.Connection.initFromFd(greeter_fd);
    defer greeter_conn.deinit();
    var worker_conn = Ipc.Connection.initFromFd(worker_fd);
    defer worker_conn.deinit();

    var worker_to_greeter = ForwardIpcCtx{
        .src = &worker_conn,
        .dst = &greeter_conn,
    };

    const worker_to_greeter_thread = try std.Thread.spawn(.{}, forwardIpcThread, .{&worker_to_greeter});
    defer worker_to_greeter_thread.join();

    var event_buf: [Ipc.event_buf_size]u8 = undefined;
    var rbuf: [Ipc.event_buf_size]u8 = undefined;
    var wbuf: [Ipc.event_buf_size]u8 = undefined;

    var reader = greeter_conn.reader(&rbuf);
    var writer = worker_conn.writer(&wbuf);
    const io_reader = &reader.interface;
    const io_writer = &writer.interface;

    while (true) {
        const event = greeter_conn.readEvent(io_reader, &event_buf) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        switch (event) {
            .start_session => {
                try waitWorkerAndClearPid(&greeter_worker_pid, greeter_worker_proc);
            },
            else => {},
        }

        try worker_conn.writeEvent(io_writer, &event);
        try io_writer.flush();
    }

    std.posix.shutdown(worker_conn.file.handle, .both) catch {};
    if (worker_to_greeter.err) |err| return err;
}

fn waitWorkerAndClearPid(
    pid_slot: *std.atomic.Value(std.posix.pid_t),
    proc: worker.WorkerProcess,
) !void {
    if (pid_slot.load(.seq_cst) <= 0) return;
    proc.wait() catch |err| {
        pid_slot.store(0, .seq_cst);
        return err;
    };
    pid_slot.store(0, .seq_cst);
}

fn terminateWorkerAndClearPid(pid_slot: *std.atomic.Value(std.posix.pid_t)) void {
    const pid = pid_slot.load(.seq_cst);
    if (pid <= 0) return;
    std.posix.kill(pid, std.posix.SIG.TERM) catch {};
    _ = std.posix.waitpid(pid, 0);
    pid_slot.store(0, .seq_cst);
}

fn forwardIpcThread(ctx: *ForwardIpcCtx) void {
    var event_buf: [Ipc.event_buf_size]u8 = undefined;
    var rbuf: [Ipc.event_buf_size]u8 = undefined;
    var wbuf: [Ipc.event_buf_size]u8 = undefined;

    var reader = ctx.src.reader(&rbuf);
    var writer = ctx.dst.writer(&wbuf);
    const io_reader = &reader.interface;
    const io_writer = &writer.interface;

    while (true) {
        const event = ctx.src.readEvent(io_reader, &event_buf) catch |err| {
            if (err != error.EndOfStream) {
                ctx.err = err;
            }
            break;
        };

        ctx.dst.writeEvent(io_writer, &event) catch |err| {
            ctx.err = err;
            break;
        };
        io_writer.flush() catch |err| {
            ctx.err = err;
            break;
        };
    }

    std.posix.shutdown(ctx.src.file.handle, .both) catch {};
    std.posix.shutdown(ctx.dst.file.handle, .both) catch {};
}

fn installSignalHandlers() void {
    const sigact = std.posix.Sigaction{
        .handler = .{ .handler = forwardSignalToWorker },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };

    const forward_signals = [_]u8{
        std.posix.SIG.TERM,
        std.posix.SIG.HUP,
        std.posix.SIG.QUIT,
    };

    for (forward_signals) |sig| {
        std.posix.sigaction(sig, &sigact, null);
    }
}

fn forwardSignalToWorker(sig: i32) callconv(.c) void {
    const gwpid = greeter_worker_pid.load(.seq_cst);
    const swpid = session_worker_pid.load(.seq_cst);
    const sig_u8: u8 = @intCast(sig);
    shutdown_requested.store(1, .seq_cst);
    if (gwpid > 0) {
        std.posix.kill(gwpid, sig_u8) catch {};
    }
    if (swpid > 0) {
        std.posix.kill(swpid, sig_u8) catch {};
    }
}

fn shouldRunAutologin(config: Config) !bool {
    if (!autologinEnabled(config)) return false;

    const autologin = config.autologin;
    const autologin_user = autologin.user.?;

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
    const user_z = try std.fmt.bufPrintZ(&user_buf, "{s}", .{user});
    return std.c.getpwnam(user_z) != null;
}

fn autologinEnabled(config: Config) bool {
    const user = config.autologin.user orelse return false;
    return user.len != 0;
}
