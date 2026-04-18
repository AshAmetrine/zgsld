const std = @import("std");
const Ipc = @import("Ipc");
const posix = @import("posix");
const build_options = @import("build_options");
const Config = @import("../../Config.zig");
const fd = @import("../../fd.zig");

const log = std.log.scoped(.zgsld);

pub const SessionClass = enum {
    user,
    greeter,
    autologin,
};

pub const WorkerProcess = struct {
    pid: std.posix.pid_t,

    pub const SpawnOpts = struct {
        allocator: std.mem.Allocator,
        env_map: *const std.process.Environ.Map,
        worker_path: [:0]const u8,
        config: Config,
        session_class: SessionClass,
        ipc_fd: ?std.posix.fd_t,
    };

    pub fn spawn(opts: SpawnOpts) !WorkerProcess {
        var arena = std.heap.ArenaAllocator.init(opts.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        var worker_envmap = std.process.Environ.Map.init(arena_allocator);
        defer worker_envmap.deinit();

        if (opts.env_map.get("PATH")) |path| {
            try worker_envmap.put("PATH", path);
        }
        if (opts.env_map.get("TERM")) |term| {
            try worker_envmap.put("TERM", term);
        }
        if (opts.env_map.get("XDG_SEAT")) |seat| {
            try worker_envmap.put("XDG_SEAT", seat);
        }
        if (opts.config.vt == .unmanaged) {
            if (opts.env_map.get("XDG_VTNR")) |vtnr| {
                try worker_envmap.put("XDG_VTNR", vtnr);
            }
        }
        var vt_buf: [8]u8 = undefined;
        const vt_value = switch (opts.config.vt) {
            .unmanaged => "unmanaged",
            .current => "current",
            .number => |vt_num| try std.fmt.bufPrint(&vt_buf, "{d}", .{vt_num}),
        };
        try worker_envmap.put("ZGSLD_VT", vt_value);
        if (build_options.x11_support) {
            try worker_envmap.put("ZGSLD_X11_CMD", opts.config.x11.command);
        }

        const service_name = switch (opts.session_class) {
            .greeter => opts.config.greeter.service_name,
            .user, .autologin => opts.config.session.service_name,
        };

        if (opts.session_class != .autologin) {
            const ipc_fd = opts.ipc_fd orelse return error.MissingIpcFd;
            var fd_buf: [16]u8 = undefined;
            const zgsld_sock = try std.fmt.bufPrint(&fd_buf, "{d}", .{ipc_fd});
            try worker_envmap.put("ZGSLD_SOCK", zgsld_sock);
        }

        var greeter_user_z: ?[*:0]const u8 = null;
        switch (opts.session_class) {
            .greeter => {
                const greeter_cmd_str: []const u8 = if (opts.config.greeter.command) |cmd| blk: {
                    if (cmd.len == 0) return error.NullGreeterCmd;
                    break :blk cmd;
                } else return error.NullGreeterCmd;

                try worker_envmap.put(
                    "ZGSLD_GREETER_SESSION_TYPE",
                    @tagName(opts.config.greeter.session_type),
                );
                try worker_envmap.put("ZGSLD_GREETER_CMD", greeter_cmd_str);
                greeter_user_z = try arena_allocator.dupeZ(u8, opts.config.greeter.user);
            },
            .autologin => {
                const autologin_user = opts.config.autologin.user orelse return error.NullAutologinUser;
                if (autologin_user.len == 0) return error.NullAutologinUser;

                const autologin_cmd = opts.config.autologin.command orelse return error.NullAutologinCmd;
                if (autologin_cmd.len == 0) return error.NullAutologinCmd;

                try worker_envmap.put("ZGSLD_AUTOLOGIN_USER", autologin_user);
                try worker_envmap.put("ZGSLD_AUTOLOGIN_SESSION_TYPE", @tagName(opts.config.autologin.session_type));
                try worker_envmap.put("ZGSLD_AUTOLOGIN_CMD", autologin_cmd);
            },
            .user => {},
        }

        const worker_environ = try worker_envmap.createPosixBlock(arena_allocator, .{});

        const service_name_z = try arena_allocator.dupeZ(u8, service_name);

        const argv = [_:null]?[*:0]const u8{
            @ptrCast(opts.worker_path.ptr),
            "--session-worker",
            @tagName(opts.session_class),
            service_name_z,
            greeter_user_z,
        };

        const pid = blk: {
            const child_pid = std.c.fork();
            if (child_pid < 0) return std.posix.unexpectedErrno(std.c.errno(child_pid));
            break :blk child_pid;
        };
        if (pid == 0) {
            if (opts.ipc_fd) |ipc_fd| {
                fd.clearCloseOnExec(ipc_fd) catch {
                    std.process.exit(1);
                };
            }
            _ = std.c.execve(opts.worker_path, &argv, worker_environ.slice.ptr);
            log.err("Worker exec error\n", .{});
            std.process.exit(1);
        }
        return .{ .pid = pid };
    }

    pub fn wait(self: WorkerProcess) !void {
        const result = try posix.waitpid(self.pid, 0);
        const st = result.status;
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
