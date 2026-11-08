const std = @import("std");
pub const ipc = @import("ipc");
pub const preview = @import("preview");
pub const ProcessContext = @import("common").ProcessContext;
const SocketPair = @import("common").SocketPair;
const worker = @import("daemon/worker.zig");
const Shutdown = @import("daemon/Shutdown.zig");
const relay = @import("daemon/relay.zig");
const log = std.log.scoped(.zgsld);
pub const Config = @import("common").Config;
const build_options = @import("build_options");

const SpawnedWorkers = struct {
    session: *Shutdown.Worker,
    greeter: *Shutdown.Worker,
    session_file: std.Io.File,
    greeter_file: std.Io.File,
};

pub const RunOptions = struct {
    ipc_codec: *ipc.Codec = ipc.Codec.binary,
    config: Config,
};

/// Handles child processes started by the daemon to run greeters and user sessions
/// Call this before anything else in `main`.
/// Continue normal startup if it returns false. Otherwise, return from `main`.
pub fn runWorkerIfRequested(process: ProcessContext) !bool {
    const opts = try worker.runtime.parseArgs(process.args) orelse return false;
    try worker.runtime.run(process.gpa, process.io, process.environ_map, opts);
    return true;
}

pub fn run(process: ProcessContext, opts: RunOptions) !void {
    var exe_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path_len = try std.process.executablePath(process.io, &exe_path_buf);
    const exe_path = exe_path_buf[0..exe_path_len];

    if (build_options.x11_support and opts.config.x11.startup_timeout_seconds == 0) {
        return error.InvalidX11StartupTimeout;
    }

    var shutdown = try Shutdown.init(process.io);
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

    try opts.config.vt.normalize(process.io);

    if (try shouldRunAutologin(opts.config)) {
        defer opts.config.vt.normalize(process.io) catch {};
        if (Shutdown.shutdownRequested()) return;
        try runAutologin(process, exe_path, opts.config, &shutdown);
        if (Shutdown.shutdownRequested()) return;
    }

    while (true) {
        defer opts.config.vt.normalize(process.io) catch {};
        if (Shutdown.shutdownRequested()) return;

        const spawned = try spawnWorkers(process, exe_path, opts.config, &shutdown);
        defer {
            shutdown.requestStop(spawned.greeter, 0);
            shutdown.requestStop(spawned.session, 0);
            shutdown.stop(spawned.greeter);
            shutdown.stop(spawned.session);
        }

        try relay.run(
            process.io,
            spawned.greeter_file,
            spawned.session_file,
            &shutdown,
            spawned.greeter,
            spawned.session,
            opts.ipc_codec,
        );
        try shutdown.waitChecked(spawned.greeter);
        shutdown.waitChecked(spawned.session) catch |err| switch (err) {
            error.WorkerError => {
                log.err("Session worker failed; returning to greeter", .{});
            },
            else => return err,
        };
    }
}

fn spawnWorkers(
    process: ProcessContext,
    exe_path: []const u8,
    config: Config,
    shutdown: *Shutdown,
) !SpawnedWorkers {
    const session_socks = try SocketPair.init(.{});
    errdefer session_socks.parent.close(process.io);
    const session_proc = try spawnWorker(process, exe_path, config, shutdown, .user, session_socks);
    errdefer shutdown.stop(session_proc);

    const greeter_socks = try SocketPair.init(.{});
    errdefer greeter_socks.parent.close(process.io);
    const greeter_proc = try spawnWorker(process, exe_path, config, shutdown, .greeter, greeter_socks);
    return .{
        .session = session_proc,
        .greeter = greeter_proc,
        .session_file = session_socks.parent,
        .greeter_file = greeter_socks.parent,
    };
}

fn spawnWorker(
    process: ProcessContext,
    exe_path: []const u8,
    config: Config,
    shutdown: *Shutdown,
    session_class: worker.process.SessionClass,
    ipc_socks: ?SocketPair,
) !*Shutdown.Worker {
    defer if (ipc_socks) |socks| socks.child.close(process.io);
    const control = try SocketPair.init(.{ .mode = .seqpacket });
    defer control.child.close(process.io);
    errdefer control.parent.close(process.io);
    var proc = try worker.process.spawn(.{
        .allocator = process.gpa,
        .io = process.io,
        .env_map = process.environ_map,
        .worker_path = exe_path,
        .config = config,
        .session_class = session_class,
        .ipc_file = if (ipc_socks) |socks| socks.child else null,
        .control_file = control.child,
    });
    errdefer {
        std.posix.kill(proc.id.?, .KILL) catch {};
        _ = proc.wait(process.io) catch {};
    }
    return shutdown.addWorker(proc, control.parent, if (ipc_socks) |socks| socks.parent else null);
}

fn runAutologin(
    process: ProcessContext,
    exe_path: []const u8,
    config: Config,
    shutdown: *Shutdown,
) !void {
    const autologin = config.autologin;

    if (autologin.timeout_seconds != 0) {
        try config.vt.activate(process.io);
        var watcher = config.vt.watchInput(process.io) catch |err| {
            if (Shutdown.shutdownRequested()) return;
            log.warn("Failed to watch for autologin interruption: {s}", .{@errorName(err)});
            return;
        };
        defer watcher.deinit(process.io);

        const interrupted = waitAutologinCountdown(
            process.io,
            &watcher,
            autologin.timeout_seconds,
        ) catch |err| {
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
    const autologin_proc = try spawnWorker(process, exe_path, config, shutdown, .autologin, null);
    defer shutdown.stop(autologin_proc);

    shutdown.waitChecked(autologin_proc) catch |err| {
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
