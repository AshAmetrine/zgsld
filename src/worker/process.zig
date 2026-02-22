const std = @import("std");

const log = std.log.scoped(.zgsld);

pub const WorkerProcess = struct {
    pid: std.posix.pid_t,

    pub fn spawn(
        worker_path: [:0]const u8,
        service_name: []const u8,
        greeter_user: []const u8,
        greeter_cmd: []const u8,
        x11_cmd: ?[]const u8,
        vt_opt: ?u8,
    ) !WorkerProcess {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        var worker_envmap = std.process.EnvMap.init(arena_allocator);
        defer worker_envmap.deinit();

        if (std.posix.getenv("PATH")) |path| {
            try worker_envmap.put("PATH", path);
        }
        if (vt_opt) |vt_num| {
            var vt_buf: [4]u8 = undefined;
            const vt_value = try std.fmt.bufPrint(&vt_buf, "{d}", .{vt_num});
            try worker_envmap.put("ZGSLD_VTNR", vt_value);
        }
        if (x11_cmd) |cmd| {
            try worker_envmap.put("ZGSLD_X11_CMD", cmd);
        }
        try worker_envmap.put("ZGSLD_GREETER_CMD", greeter_cmd);

        const worker_environ = try std.process.createNullDelimitedEnvMap(arena_allocator, &worker_envmap);

        const service_z = try arena_allocator.dupeZ(u8, service_name);
        const user_z = try arena_allocator.dupeZ(u8, greeter_user);

        const argv = [_:null]?[*:0]const u8{
            @ptrCast(worker_path.ptr),
            "--session-worker",
            service_z.ptr,
            user_z.ptr,
        };

        const pid = try std.posix.fork();
        if (pid == 0) {
            std.posix.execvpeZ(worker_path, &argv, worker_environ) catch {
                log.err("Worker exec error\n", .{});
            };
            std.process.exit(1);
        }
        return .{ .pid = pid };
    }

    pub fn wait(self: WorkerProcess) !void {
        const status = std.posix.waitpid(self.pid, 0);

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
};
