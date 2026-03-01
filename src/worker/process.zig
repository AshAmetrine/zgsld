const std = @import("std");
const Ipc = @import("Ipc");
const build_options = @import("build_options");
const Config = @import("../Config.zig");

const log = std.log.scoped(.zgsld);

pub const WorkerProcess = struct {
    pid: std.posix.pid_t,

    pub const SpawnOpts = struct {
        allocator: std.mem.Allocator,
        worker_path: [:0]const u8,
        greeter_cmd: if (build_options.standalone) []const u8 else void,
        config: Config,
    };

    pub fn spawn(opts: SpawnOpts) !WorkerProcess {
        var arena = std.heap.ArenaAllocator.init(opts.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        const greeter_cmd_str: []const u8 = if (build_options.standalone) blk: {
            if (opts.greeter_cmd.len == 0) return error.NullGreeterCmd;
            break :blk opts.greeter_cmd;
        } else if (opts.config.greeter.command) |cmd| blk: {
            if (cmd.len == 0) return error.NullGreeterCmd;
            break :blk cmd;
        } else return error.NullGreeterCmd;

        var worker_envmap = std.process.EnvMap.init(arena_allocator);
        defer worker_envmap.deinit();

        if (std.posix.getenv("PATH")) |path| {
            try worker_envmap.put("PATH", path);
        }
        if (opts.config.vt) |vt_num| {
            var vt_buf: [4]u8 = undefined;
            const vt_value = try std.fmt.bufPrint(&vt_buf, "{d}", .{vt_num});
            try worker_envmap.put("ZGSLD_VTNR", vt_value);
        }
        if (build_options.x11_support) {
            try worker_envmap.put("ZGSLD_X11_CMD", opts.config.x11.command);
        }
        try worker_envmap.put(
            "ZGSLD_GREETER_SESSION_TYPE",
            @tagName(opts.config.greeter.session_type),
        );
        try worker_envmap.put("ZGSLD_GREETER_CMD", greeter_cmd_str);

        const worker_environ = try std.process.createNullDelimitedEnvMap(arena_allocator, &worker_envmap);

        const service_z = try arena_allocator.dupeZ(u8, opts.config.session.service_name);
        const user_z = try arena_allocator.dupeZ(u8, opts.config.greeter.user);
        const greeter_service_z = try arena_allocator.dupeZ(u8, opts.config.greeter.service_name);

        const argv = [_:null]?[*:0]const u8{
            @ptrCast(opts.worker_path.ptr),
            "--session-worker",
            service_z.ptr,
            user_z.ptr,
            greeter_service_z.ptr,
        };

        const pid = try std.posix.fork();
        if (pid == 0) {
            std.posix.execvpeZ(opts.worker_path, &argv, worker_environ) catch {
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
