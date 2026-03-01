const std = @import("std");
const vt = @import("vt.zig");
const worker = @import("worker.zig");
const log = std.log.scoped(.zgsld);
const Config = @import("Config.zig");
const build_options = @import("build_options");

var active_worker_pid = std.atomic.Value(std.posix.pid_t).init(0);
var shutdown_requested = std.atomic.Value(u8).init(0);

pub const SessionManagerRunOpts = struct {
    self_exe_path: [:0]const u8,
    greeter_cmd: []const u8,
    config: Config,
};

pub fn run(opts: SessionManagerRunOpts) !void {
    installSignalHandlers();

    if (!build_options.x11_support and opts.config.greeter_session_type == .x11) {
        log.err("Greeter X11 session type requested, but zgsld was built without -Dx11 support", .{});
        return error.X11UnsupportedBuild;
    }

    if (opts.config.vt) |vt_num| {
        vt.initTty(vt_num) catch |err| {
            log.err("Failed to init VT {d}: {s}", .{ vt_num, @errorName(err) });
            std.process.exit(1);
        };
    }

    if (!try userExists(opts.config.greeter_user)) {
        log.err("Greeter user not found: {s}", .{opts.config.greeter_user});
        return error.GreeterUserNotFound;
    }

    while (true) {
        defer {
            if (opts.config.vt) |vt_id| {
                vt.resetTty(vt_id) catch {};
            }
            vt.resetTermios();
        }
        if (shutdown_requested.load(.seq_cst) != 0) return;

        log.debug("Spawning worker...", .{});
        const worker_proc = try worker.WorkerProcess.spawn(.{
            .worker_path = opts.self_exe_path,
            .service_name = opts.config.service_name,
            .greeter = .{
                .user = opts.config.greeter_user,
                .service_name = opts.config.greeter_service_name,
                .cmd = opts.greeter_cmd,
                .session_type = opts.config.greeter_session_type,
            },
            .x11_cmd = if (build_options.x11_support) opts.config.x11.cmd else null,
            .vt = opts.config.vt,
        });
        active_worker_pid.store(worker_proc.pid, .seq_cst);
        defer active_worker_pid.store(0, .seq_cst);
        if (shutdown_requested.load(.seq_cst) != 0) {
            std.posix.kill(worker_proc.pid, std.posix.SIG.TERM) catch {};
        }

        try worker_proc.wait();
    }
}

fn installSignalHandlers() void {
    const sigact = std.posix.Sigaction{
        .handler = .{ .handler = forwardSignalToWorker },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };

    const forward_signals = [_]u8{
        std.posix.SIG.TERM,
        std.posix.SIG.INT,
        std.posix.SIG.HUP,
        std.posix.SIG.QUIT,
    };

    for (forward_signals) |sig| {
        std.posix.sigaction(sig, &sigact, null);
    }
}

fn forwardSignalToWorker(sig: i32) callconv(.c) void {
    const pid = active_worker_pid.load(.seq_cst);
    const sig_u8: u8 = @intCast(sig);
    shutdown_requested.store(1, .seq_cst);
    if (pid > 0) {
        std.posix.kill(pid, sig_u8) catch {};
    }
}

fn userExists(user: []const u8) !bool {
    var user_buf: [64]u8 = undefined;
    const user_z = try std.fmt.bufPrintZ(&user_buf, "{s}", .{user});
    return std.c.getpwnam(user_z) != null;
}
