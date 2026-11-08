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

const Session = @import("session.zig").Session;
const X11Options = @import("session.zig").X11Options;
const Runtime = @This();

allocator: std.mem.Allocator,
io: std.Io,
shutdown_conn: *Shutdown.Connection,
env_map: *const std.process.Environ.Map,
vt: Vt,
x11: X11Options,

const StderrMode = enum {
    inherit,
    tty,
};

pub fn resolveSessionVt(self: *const Runtime, session_type: ipc.SessionType) Vt {
    if (build_options.x11_support and session_type == .x11) {
        if (self.x11.vt) |number| return .{ .number = number };
    }
    return self.vt;
}

pub const StartOptions = struct {
    info: ipc.SessionInfo,
    env_map: *std.process.Environ.Map,
    vt: Vt,
    tty_file: std.Io.File,
};

/// Takes ownership of opts.tty_file on success.
pub fn startSession(
    self: *const Runtime,
    comptime T: type,
    pam: *Pam(T),
    opts: StartOptions,
) !Session {
    try env_mod.preparePamUserEnv(T, pam, opts.env_map);
    try env_mod.preparePamSessionEnv(T, pam, self.io, self.env_map, opts.vt, .user);
    try pam.openSession(.{});
    try env_mod.applyPamEnv(T, pam, opts.env_map, self.io, opts.vt);
    try env_mod.applyTermEnv(opts.env_map, self.env_map);
    const user_info = try env_mod.applyUserEnv(T, pam, opts.env_map);
    return self.spawnSession(.{
        .session_info = opts.info,
        .envmap = opts.env_map,
        .user_info = user_info,
        .vt = opts.vt,
        .tty_file = opts.tty_file,
    });
}

const SpawnOpts = struct {
    session_info: ipc.SessionInfo,
    envmap: *std.process.Environ.Map,
    user_info: UserInfo,
    vt: Vt,
    tty_file: std.Io.File,
    stderr: StderrMode = .tty,
};

// Takes ownership of opts.tty_file on success.
pub fn spawnSession(self: *const Runtime, opts: SpawnOpts) !Session {
    if (!build_options.x11_support and opts.session_info.session_type == .x11) {
        return error.X11UnsupportedBuild;
    }
    var xserver: if (build_options.x11_support) ?XServer else void =
        if (build_options.x11_support) null else {};
    errdefer if (build_options.x11_support) {
        if (xserver) |*server| server.deinit(self.io);
    };
    if (build_options.x11_support and opts.session_info.session_type == .x11) {
        xserver = try XServer.spawn(self.allocator, .{
            .io = self.io,
            .shutdown_conn = self.shutdown_conn,
            .command = self.x11.command,
            .startup_timeout_seconds = self.x11.startup_timeout_seconds,
            .envmap = opts.envmap,
            .vt = opts.vt,
            .user = opts.user_info,
        });
    }

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const session_environ = try opts.envmap.createPosixBlock(arena.allocator(), .{});

    const session_child = try self.runSessionCommand(.{
        .cmd = opts.session_info.command,
        .environ = session_environ.slice,
        .user_info = opts.user_info,
        .home_dir = opts.envmap.get("HOME"),
        .vt = opts.vt,
        .stderr = opts.stderr,
    });
    return .{
        .child = session_child,
        .tty_file = opts.tty_file,
        .shutdown_conn = self.shutdown_conn,
        .x11 = xserver,
    };
}

const SessionCommandOpts = struct {
    cmd: ipc.SessionCommand,
    user_info: UserInfo,
    home_dir: ?[]const u8,
    environ: [:null]const ?[*:0]const u8,
    vt: Vt,
    stderr: StderrMode,
};

fn runSessionCommand(self: *const Runtime, opts: SessionCommandOpts) !std.process.Child {
    const prefix = if (opts.cmd.source_profile)
        "[ -f /etc/profile ] && . /etc/profile; [ -f $HOME/.profile ] && . $HOME/.profile; exec "
    else
        "exec ";

    const shell_cmd = try std.mem.concatWithSentinel(
        self.allocator,
        u8,
        &.{ prefix, opts.cmd.session_cmd },
        0,
    );
    defer self.allocator.free(shell_cmd);

    const wrapper = [_:null]?[*:0]const u8{ "/bin/sh", "-c", shell_cmd.ptr };

    // The session VT is already active. Reactivation would reset Xorg's VT mode.
    const tty_file = try opts.vt.openDevice(self.io, .read_write);
    defer tty_file.close(self.io);
    const groups = try utils.getGroups(self.allocator, opts.user_info);
    defer self.allocator.free(groups);
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrintSentinel(&dir_buf, "{s}", .{opts.home_dir orelse "/"}, 0);

    const session_pid = try self.shutdown_conn.fork(.session);
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
