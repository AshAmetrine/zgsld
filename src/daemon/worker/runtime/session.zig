const std = @import("std");
const ipc = @import("ipc");
const tty = @import("tty.zig");
const env_mod = @import("env.zig");
const build_options = @import("build_options");
const XServer = if (build_options.x11_support) @import("session/XServer.zig");
const utils = @import("user.zig");
const Pam = @import("pam").Pam;
const UserInfo = utils.UserInfo;
const Vt = @import("vt").Vt;
const Shutdown = @import("../../Shutdown.zig");

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

pub fn start(
    comptime T: type,
    allocator: std.mem.Allocator,
    io: std.Io,
    shutdown_conn: *Shutdown.Connection,
    host_env_map: *const std.process.Environ.Map,
    info: ipc.SessionInfo,
    pam: *Pam(T),
    session_envmap: *std.process.Environ.Map,
    vt: Vt,
) !Session {
    try env_mod.applyPamUserSessionEnv(T, pam, session_envmap, io, host_env_map, vt);
    try env_mod.applyTermEnv(session_envmap, host_env_map);
    const user_info = try env_mod.applyUserEnv(T, pam, session_envmap);
    return Session.spawn(allocator, .{
        .io = io,
        .shutdown_conn = shutdown_conn,
        .host_env_map = host_env_map,
        .session_info = info,
        .envmap = session_envmap,
        .user_info = user_info,
        .vt = vt,
    });
}

pub const Session = struct {
    child: std.process.Child,
    shutdown_conn: *Shutdown.Connection,

    x11: if (build_options.x11_support) ?XServer else void =
        if (build_options.x11_support) null else {},

    pub fn deinit(self: *Session, io: std.Io) void {
        self.shutdown_conn.stop(&self.child, .session);
        if (build_options.x11_support) {
            if (self.x11) |*xsession| xsession.deinit(io);
        }
    }

    const SpawnOpts = struct {
        io: std.Io,
        shutdown_conn: *Shutdown.Connection,
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
        var xserver: if (build_options.x11_support) ?XServer else void =
            if (build_options.x11_support) null else {};
        errdefer if (build_options.x11_support) {
            if (xserver) |*server| server.deinit(opts.io);
        };
        if (build_options.x11_support and opts.session_info.session_type == .x11) {
            xserver = try XServer.spawn(allocator, .{
                .io = opts.io,
                .shutdown_conn = opts.shutdown_conn,
                .host_env_map = opts.host_env_map,
                .envmap = opts.envmap,
                .vt = opts.vt,
                .user = opts.user_info,
            });
        }

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const session_environ = try opts.envmap.createPosixBlock(arena.allocator(), .{});

        const session_child = try runSessionCommand(allocator, .{
            .io = opts.io,
            .shutdown_conn = opts.shutdown_conn,
            .cmd = opts.session_info.command,
            .environ = session_environ.slice,
            .user_info = opts.user_info,
            .home_dir = opts.envmap.get("HOME"),
            .vt = opts.vt,
            .stderr = opts.stderr,
        });
        return .{
            .child = session_child,
            .shutdown_conn = opts.shutdown_conn,
            .x11 = xserver,
        };
    }

    const SessionCommandOpts = struct {
        io: std.Io,
        shutdown_conn: *Shutdown.Connection,
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

        // The session VT is already active. Reactivation would reset Xorg's VT mode.
        const tty_file = try opts.vt.openDevice(opts.io, .read_write);
        defer tty_file.close(opts.io);
        const groups = try utils.getGroups(allocator, opts.user_info);
        defer allocator.free(groups);
        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir = try std.fmt.bufPrintSentinel(&dir_buf, "{s}", .{opts.home_dir orelse "/"}, 0);

        const session_pid = try opts.shutdown_conn.fork(.session);
        if (session_pid == 0) {
            (switch (opts.stderr) {
                .inherit => tty.redirectStdinAndStdoutToTty(tty_file.handle),
                .tty => tty.redirectStdioToTty(tty_file.handle),
            }) catch std.c._exit(1);
            if (tty_file.handle > 2) _ = std.c.close(tty_file.handle);
            utils.dropPrivileges(opts.user_info, groups) catch std.c._exit(1);
            if (std.c.chdir(dir) != 0) std.c._exit(1);
            _ = std.c.execve("/bin/sh", &wrapper, opts.environ.ptr);
            std.c._exit(1);
        }

        return Shutdown.Connection.childFromPid(session_pid);
    }
};
