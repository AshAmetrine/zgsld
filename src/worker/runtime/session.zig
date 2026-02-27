const std = @import("std");
const Ipc = @import("Ipc");
const tty = @import("tty.zig");
const build_options = @import("build_options");
const x11 = if (build_options.x11_support) @import("session/x11.zig");
const utils = @import("user.zig");
const UserInfo = utils.UserInfo;

const log = std.log.scoped(.zgsld_worker);

const X11Setup = struct {
    display: u8,
    xauth_path: [:0]const u8,
};

pub const Session = struct {
    pid: std.posix.pid_t,

    x11: if (!build_options.x11_support) void else ?X11Session = if (build_options.x11_support) null else {},

    const X11Session = struct {
        const Self = @This();

        launcher_pid: std.posix.pid_t,
        server_pid: std.posix.pid_t,
        server_detached: bool,

        xauth_path: [:0]const u8,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *Self) void {
            if (self.server_pid > 0) {
                std.posix.kill(self.server_pid, std.posix.SIG.TERM) catch {};
            }

            if (!self.server_detached) {
                _ = std.posix.waitpid(self.server_pid, 0);
            } else if (self.launcher_pid > 0) {
                _ = std.posix.waitpid(self.launcher_pid, std.posix.W.NOHANG);
            }

            std.fs.deleteFileAbsolute(self.xauth_path) catch {};
            self.allocator.free(self.xauth_path);
        }
    };

    pub fn deinit(self: *Session) void {
        if (build_options.x11_support) {
            if (self.x11) |*xsession| xsession.deinit();
        }
    }

    const SpawnOpts = struct {
        session_info: Ipc.SessionInfo,
        envmap: *std.process.EnvMap,
        user_info: UserInfo,
    };

    pub fn spawn(allocator: std.mem.Allocator, opts: SpawnOpts) !Session {
        if (!build_options.x11_support and opts.session_info.session_type == .X11) {
            return error.X11UnsupportedBuild;
        }

        var x11_setup: ?X11Setup = null;
        errdefer if (x11_setup) |setup| {
            std.fs.deleteFileAbsolute(setup.xauth_path) catch {};
            allocator.free(setup.xauth_path);
        };
        if (build_options.x11_support and opts.session_info.session_type == .X11) {
            const display_num = try x11.findFreeDisplay();

            var display_buf: [4]u8 = undefined;
            const display_env = try std.fmt.bufPrint(&display_buf, ":{d}", .{display_num});
            try opts.envmap.put("DISPLAY", display_env);

            var xauth_buf: [std.fs.max_path_bytes]u8 = undefined;
            const runtime_dir = opts.envmap.get("XDG_RUNTIME_DIR");
            const xauth_path = try x11.xauth.createXauthEntry(&xauth_buf, display_env[1..], opts.user_info.uid, opts.user_info.gid, runtime_dir);
            const xauth_path_z = try allocator.dupeZ(u8, xauth_path);
            try opts.envmap.put("XAUTHORITY", xauth_path_z);

            x11_setup = .{
                .display = display_num,
                .xauth_path = xauth_path_z,
            };
        }

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const session_environ = try std.process.createNullDelimitedEnvMap(arena.allocator(), opts.envmap);

        if (build_options.x11_support and opts.session_info.session_type == .X11) {
            const setup = x11_setup orelse return error.X11SetupMissing;
            const x_cmd = std.posix.getenv("ZGSLD_X11_CMD") orelse "/bin/X";
            const vt = if (opts.envmap.get("XDG_VTNR")) |vt_str|
                try std.fmt.parseInt(u8, vt_str, 10)
            else
                null;
            const launcher_pid = try x11.startXServer(.{
                .x_cmd = x_cmd,
                .xauth_path = setup.xauth_path,
                .display = setup.display,
                .vt = vt,
                .user = opts.user_info,
            });

            errdefer {
                if (x11.readXServerPid(setup.display)) |pid| {
                    std.posix.kill(pid, std.posix.SIG.TERM) catch {};
                    if (pid == launcher_pid) {
                        _ = std.posix.waitpid(pid, 0);
                    }
                }
                if (launcher_pid > 0) {
                    std.posix.kill(launcher_pid, std.posix.SIG.TERM) catch {};
                    _ = std.posix.waitpid(launcher_pid, std.posix.W.NOHANG);
                }
            }

            const server_info = try x11.waitForXServer(setup.display, launcher_pid, 5000);

            const client_pid = try runSessionCommand(allocator, .{
                .cmd = opts.session_info.command,
                .environ = session_environ,
                .user_info = opts.user_info,
                .home_dir = opts.envmap.get("HOME"),
            });

            return .{
                .pid = client_pid,
                .x11 = .{
                    .launcher_pid = launcher_pid,
                    .server_pid = server_info.server_pid,
                    .server_detached = server_info.detached,
                    .xauth_path = setup.xauth_path,
                    .allocator = allocator,
                },
            };
        }

        const session_pid = try runSessionCommand(allocator, .{
            .cmd = opts.session_info.command,
            .environ = session_environ,
            .user_info = opts.user_info,
            .home_dir = opts.envmap.get("HOME"),
        });
        return .{ .pid = session_pid };
    }

    const SessionCommandOpts = struct {
        cmd: Ipc.SessionCommand,
        user_info: UserInfo,
        home_dir: ?[]const u8,
        environ: [:null]const ?[*:0]const u8,
    };

    fn runSessionCommand(allocator: std.mem.Allocator, opts: SessionCommandOpts) !std.posix.pid_t {
        const prefix = if (opts.cmd.source_profile) blk: {
            break :blk "[ -f /etc/profile ] && . /etc/profile; [ -f $HOME/.profile ] && . $HOME/.profile; exec ";
        } else "exec ";

        const shell_cmd = try std.mem.concatWithSentinel(allocator, u8, &.{ prefix, opts.cmd.session_cmd }, 0);
        defer allocator.free(shell_cmd);

        const wrapper = [_]?[*:0]const u8{ "/bin/sh", "-c", shell_cmd.ptr, null };

        return try startCommandSession(opts.user_info, opts.home_dir, &wrapper, opts.environ);
    }
};

fn startCommandSession(
    user_info: UserInfo,
    home_dir: ?[]const u8,
    argv: []const ?[*:0]const u8,
    session_environ: [:null]const ?[*:0]const u8,
) !std.posix.pid_t {
    const session_pid = try std.posix.fork();
    if (session_pid == 0) {
        tty.redirectStdioToControllingTty() catch {
            log.err("Failed to redirect session stdio", .{});
            std.process.exit(1);
        };

        utils.dropPrivileges(user_info) catch std.process.exit(1);
        if (home_dir) |dir| {
            std.posix.chdir(dir) catch std.process.exit(1);
        } else {
            std.posix.chdir("/") catch std.process.exit(1);
        }

        const cmd_path = argv[0] orelse std.process.exit(1);
        const argv_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(argv.ptr);
        std.posix.execvpeZ(cmd_path, argv_ptr, session_environ) catch {};
        std.process.exit(1);
    }

    return session_pid;
}
