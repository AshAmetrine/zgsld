const std = @import("std");
const ipc = @import("ipc");
const tty = @import("tty.zig");
const env_mod = @import("env.zig");
const build_options = @import("build_options");
const x11 = if (build_options.x11_support) @import("session/x11.zig");
const utils = @import("user.zig");
const Pam = @import("pam").Pam;
const UserInfo = utils.UserInfo;
const Vt = @import("vt").Vt;

const log = std.log.scoped(.zgsld_worker);

const StderrMode = enum {
    inherit,
    tty,
};

pub fn resolveSessionVt(
    session_type: ipc.SessionType,
    host_env_map: *const std.process.Environ.Map,
    fallback: Vt,
) !Vt {
    if (build_options.x11_support and session_type == .x11) {
        if (host_env_map.get("ZGSLD_X11_VT")) |raw| {
            const number = try std.fmt.parseInt(u8, raw, 10);
            if (number == 0) return error.InvalidTty;
            return .{ .number = number };
        }
    }
    return fallback;
}

const X11Setup = struct {
    display: u8,
    xauth_path: [:0]const u8,
};

pub fn start(
    comptime T: type,
    allocator: std.mem.Allocator,
    io: std.Io,
    host_env_map: *const std.process.Environ.Map,
    user: [:0]const u8,
    info: ipc.SessionInfo,
    pam: *Pam(T),
    session_envmap: *std.process.Environ.Map,
    vt: Vt,
) !Session {
    try env_mod.applyPamUserSessionEnv(T, pam, session_envmap, io, host_env_map, vt);
    try env_mod.applyTermEnv(session_envmap, host_env_map);
    const user_info = try env_mod.applyUserEnv(session_envmap, user);
    return Session.spawn(allocator, .{
        .io = io,
        .host_env_map = host_env_map,
        .session_info = info,
        .envmap = session_envmap,
        .user_info = user_info,
        .vt = vt,
    });
}

pub const Session = struct {
    child: std.process.Child,

    x11: if (build_options.x11_support) ?X11Session else void = if (build_options.x11_support) null else {},

    const X11Session = struct {
        const Self = @This();

        server: std.process.Child,

        xauth_path: [:0]const u8,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *Self, io: std.Io) void {
            self.server.kill(io);

            std.Io.Dir.deleteFileAbsolute(io, self.xauth_path) catch {};
            self.allocator.free(self.xauth_path);
        }
    };

    pub fn deinit(self: *Session, io: std.Io) void {
        self.child.kill(io);
        if (build_options.x11_support) {
            if (self.x11) |*xsession| xsession.deinit(io);
        }
    }

    const SpawnOpts = struct {
        io: std.Io,
        host_env_map: *const std.process.Environ.Map,
        session_info: ipc.SessionInfo,
        envmap: *std.process.Environ.Map,
        user_info: UserInfo,
        vt: Vt,
        stderr: StderrMode = .tty,
    };

    pub fn spawn(allocator: std.mem.Allocator, opts: SpawnOpts) !Session {
        if (!build_options.x11_support and opts.session_info.session_type == .x11) {
            return error.X11UnsupportedBuild;
        }
        var x11_setup: ?X11Setup = null;
        errdefer if (x11_setup) |setup| {
            std.Io.Dir.deleteFileAbsolute(opts.io, setup.xauth_path) catch {};
            allocator.free(setup.xauth_path);
        };
        if (build_options.x11_support and opts.session_info.session_type == .x11) {
            const display_num = try x11.findFreeDisplay(opts.io);

            var display_buf: [4]u8 = undefined;
            const display_env = try std.fmt.bufPrint(&display_buf, ":{d}", .{display_num});
            try opts.envmap.put("DISPLAY", display_env);

            var xauth_buf: [std.fs.max_path_bytes]u8 = undefined;
            const runtime_dir = opts.envmap.get("XDG_RUNTIME_DIR");
            const xauth_path = try x11.xauth.createXauthEntry(opts.io, &xauth_buf, display_env[1..], opts.user_info.uid, opts.user_info.gid, runtime_dir);
            errdefer std.Io.Dir.deleteFileAbsolute(opts.io, xauth_path) catch {};

            const xauth_path_z = try allocator.dupeSentinel(u8, xauth_path, 0);
            errdefer allocator.free(xauth_path_z);

            try opts.envmap.put("XAUTHORITY", xauth_path_z);

            x11_setup = .{
                .display = display_num,
                .xauth_path = xauth_path_z,
            };
        }

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const session_environ = try opts.envmap.createPosixBlock(arena.allocator(), .{});

        var x11_session: ?X11Session = null;
        errdefer if (x11_session) |*session| session.server.kill(opts.io);

        if (build_options.x11_support) {
            if (x11_setup) |setup| {
                const x_cmd = opts.host_env_map.get("ZGSLD_X11_CMD") orelse "/bin/X";
                x11_session = .{
                    .server = try x11.startXServer(allocator, .{
                        .io = opts.io,
                        .env_map = opts.host_env_map,
                        .x_cmd = x_cmd,
                        .xauth_path = setup.xauth_path,
                        .display = setup.display,
                        .vt = opts.vt,
                        .user = opts.user_info,
                        .environ = session_environ.slice,
                    }),
                    .xauth_path = setup.xauth_path,
                    .allocator = allocator,
                };
            }
        }

        const child = try runSessionCommand(allocator, .{
            .io = opts.io,
            .env_map = opts.host_env_map,
            .cmd = opts.session_info.command,
            .environ = session_environ.slice,
            .user_info = opts.user_info,
            .home_dir = opts.envmap.get("HOME"),
            .vt = opts.vt,
            .stderr = opts.stderr,
        });
        return .{
            .child = child,
            .x11 = if (build_options.x11_support) x11_session else {},
        };
    }

    const SessionCommandOpts = struct {
        io: std.Io,
        env_map: *const std.process.Environ.Map,
        cmd: ipc.SessionCommand,
        user_info: UserInfo,
        home_dir: ?[]const u8,
        environ: [:null]const ?[*:0]const u8,
        vt: Vt,
        stderr: StderrMode,
    };

    fn runSessionCommand(allocator: std.mem.Allocator, opts: SessionCommandOpts) !std.process.Child {
        const prefix = if (opts.cmd.source_profile)
            "[ -f /etc/profile ] && . /etc/profile; [ -f $HOME/.profile ] && . $HOME/.profile; exec "
        else
            "exec ";

        const shell_cmd = try std.mem.concatWithSentinel(allocator, u8, &.{ prefix, opts.cmd.session_cmd }, 0);
        defer allocator.free(shell_cmd);

        const wrapper = [_:null]?[*:0]const u8{ "/bin/sh", "-c", shell_cmd.ptr };

        const session_pid = std.c.fork();
        if (session_pid < 0) return std.posix.unexpectedErrno(std.c.errno(session_pid));
        if (session_pid == 0) {
            {
                opts.vt.activate(opts.io) catch |err| {
                    log.err("Failed to activate session tty: {s}", .{@errorName(err)});
                    std.process.exit(1);
                };

                var tty_file = opts.vt.openDevice(opts.io, opts.env_map, .read_write) catch |err| {
                    log.err("Failed to open session tty device: {s}", .{@errorName(err)});
                    std.process.exit(1);
                };
                defer if (tty_file.handle > 2) tty_file.close(opts.io);

                (switch (opts.stderr) {
                    .inherit => tty.redirectStdinAndStdoutToTty(tty_file.handle),
                    .tty => tty.redirectStdioToTty(tty_file.handle),
                }) catch |err| {
                    log.err("Failed to redirect session stdio: {s}", .{@errorName(err)});
                    std.process.exit(1);
                };
            }

            utils.dropPrivileges(opts.user_info) catch std.process.exit(1);
            const dir = opts.home_dir orelse "/";
            var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
            const dir_z = std.fmt.bufPrintSentinel(&dir_buf, "{s}", .{dir}, 0) catch std.process.exit(1);
            if (std.c.chdir(dir_z) != 0) std.process.exit(1);

            _ = std.c.execve("/bin/sh", &wrapper, opts.environ.ptr);
            std.process.exit(1);
        }

        return .{
            .id = session_pid,
            .thread_handle = {},
            .stdin = null,
            .stdout = null,
            .stderr = null,
            .request_resource_usage_statistics = false,
        };
    }
};
