const std = @import("std");
const vt = @import("vt.zig");
const log = std.log.scoped(.zgsld);
const ZgsldConfig = @import("config.zig").Config;
const build_options = @import("build_options");

var active_worker_pid = std.atomic.Value(std.posix.pid_t).init(0);
var shutdown_requested = std.atomic.Value(u8).init(0);

pub const SessionManagerRunOpts = struct {
    self_exe_path: [:0]const u8,
    greeter_argv: [:null]const ?[*:0]const u8,
    config: ZgsldConfig,
};

pub fn run(opts: SessionManagerRunOpts) !void {
    installSignalHandlers();

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
        const worker_pid = try spawnWorker(
            opts.self_exe_path,
            opts.config.service_name,
            opts.config.greeter_user,
            opts.greeter_argv,
            if (build_options.x11_support) opts.config.x11.cmd else null,
        );
        active_worker_pid.store(worker_pid, .seq_cst);
        if (shutdown_requested.load(.seq_cst) != 0) {
            std.posix.kill(worker_pid, std.posix.SIG.TERM) catch {};
        }

        const status = std.posix.waitpid(worker_pid, 0);
        active_worker_pid.store(0, .seq_cst);
        if (shutdown_requested.load(.seq_cst) != 0) {
            log.debug("Shutdown requested; exiting after worker cleanup", .{});
            return;
        }
        const st = status.status;
        const code: u8 = if (std.c.W.IFEXITED(st)) std.c.W.EXITSTATUS(st) else 1;
        if (code != 0) {
            if (code == 2) {
                log.err("Greeter exited before starting auth", .{});
                return error.GreeterError;
            }
            return error.WorkerError;
        }
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

pub fn spawnWorker(
    worker_path: [:0]const u8,
    service_name: []const u8,
    greeter_user: []const u8,
    greeter_argv: [:null]const ?[*:0]const u8,
    x11_cmd: ?[]const u8,
) !std.posix.pid_t {
    const pid = try std.posix.fork();
    if (pid == 0) {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const service_z = allocator.dupeZ(u8, service_name) catch {
            log.err("Failed to build worker args", .{});
            std.process.exit(1);
        };
        const user_z = allocator.dupeZ(u8, greeter_user) catch {
            log.err("Failed to build worker args", .{});
            std.process.exit(1);
        };
        const service_ptr: [*:0]const u8 = @ptrCast(service_z.ptr);
        const user_ptr: [*:0]const u8 = @ptrCast(user_z.ptr);

        const argv_len: usize = 5 + greeter_argv.len;
        var argv = allocator.allocSentinel(?[*:0]const u8, argv_len, null) catch {
            log.err("Failed to allocate worker args", .{});
            std.process.exit(1);
        };

        argv[0] = @ptrCast(worker_path.ptr);
        argv[1] = "--session-worker";
        argv[2] = service_ptr;
        argv[3] = user_ptr;
        argv[4] = "--";

        @memmove(argv[5..], greeter_argv);

        var worker_environ: [*:null]const ?[*:0]const u8 = std.c.environ;
        var x11_env_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
        var env_storage: ?[]?[*:0]const u8 = null;

        if (x11_cmd) |cmd| {
            const x11_env = try std.fmt.bufPrintZ(&x11_env_buf, "ZGSLD_X11_CMD={s}", .{cmd});

            var env_count: usize = 0;
            while (std.c.environ[env_count] != null) : (env_count += 1) {}

            env_storage = try allocator.allocSentinel(?[*:0]const u8, env_count + 1, null);
            var i: usize = 0;
            while (std.c.environ[i]) |entry| : (i += 1) {
                env_storage.?[i] = entry;
            }
            env_storage.?[env_count] = x11_env;
            worker_environ = @ptrCast(env_storage.?.ptr);
        }

        const argv_ptr: [*:null]const ?[*:0]const u8 = argv.ptr;
        std.posix.execvpeZ(worker_path, argv_ptr, worker_environ) catch {
            log.err("Worker exec error\n", .{});
        };
        std.process.exit(1);
    }
    return pid;
}

fn userExists(user: []const u8) !bool {
    var user_buf: [64]u8 = undefined;
    const user_z = try std.fmt.bufPrintZ(&user_buf, "{s}", .{user});
    return std.c.getpwnam(user_z) != null;
}
