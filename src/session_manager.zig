const std = @import("std");
const vt = @import("vt.zig");
const log = std.log.scoped(.zgsld);
const ZgsldConfig = @import("Config.zig");


pub const SessionManagerRunOpts = struct {
    self_exe_path: [:0]const u8,
    greeter_argv: [:null]const ?[*:0]const u8,
    config: ZgsldConfig,
};

pub fn run(opts: SessionManagerRunOpts) !void {
    if (opts.config.vt) |vt_num| {
        vt.initTty(vt_num) catch |err| {
            log.err("Failed to init VT {d}: {s}", .{ vt_num, @errorName(err) });
            std.process.exit(1);
        };
    }

    if (!try userExists(opts.config.greeter_user)) {
        log.err("Greeter user not found: {s}", .{ opts.config.greeter_user });
        return error.GreeterUserNotFound;
    }

    while (true) {
        defer if (opts.config.vt) |vt_id| {
            vt.resetTty(vt_id) catch {};
        };

        log.debug("Spawning worker...", .{});
        const worker_pid = try spawnWorker(
            opts.self_exe_path,
            opts.config.service_name,
            opts.config.greeter_user,
            opts.greeter_argv,
        );

        const status = std.posix.waitpid(worker_pid, 0);
        log.info("Worker stopped", .{});
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

pub fn spawnWorker(
    worker_path: [:0]const u8,
    service_name: []const u8,
    greeter_user: []const u8,
    greeter_argv: [:null]const ?[*:0]const u8,
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

        const argv_ptr: [*:null]const ?[*:0]const u8 = argv.ptr;
        std.posix.execvpeZ(worker_path, argv_ptr, std.c.environ) catch {
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
