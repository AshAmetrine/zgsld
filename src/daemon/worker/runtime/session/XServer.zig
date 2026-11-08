const std = @import("std");
pub const DisplayPipe = @import("XServer/DisplayPipe.zig");
const utils = @import("../user.zig");
const UserInfo = utils.UserInfo;
const Vt = @import("vt").Vt;
const tty = @import("../tty.zig");

const xauth = @import("xauth.zig");
const XServer = @This();
const Shutdown = @import("../../../Shutdown.zig");

child: std.process.Child,
shutdown_conn: *Shutdown.Connection,
xauth_path: [:0]const u8,
allocator: std.mem.Allocator,

pub const Options = struct {
    io: std.Io,
    shutdown_conn: *Shutdown.Connection,
    host_env_map: *const std.process.Environ.Map,
    envmap: *std.process.Environ.Map,
    vt: Vt,
    user: UserInfo,
};

pub fn spawn(allocator: std.mem.Allocator, opts: Options) !XServer {
    const timeout_raw = opts.host_env_map.get("ZGSLD_X11_TIMEOUT_SECONDS") orelse
        return error.MissingX11StartupTimeout;
    const timeout_seconds = try std.fmt.parseInt(u32, timeout_raw, 10);
    if (timeout_seconds == 0) return error.InvalidX11StartupTimeout;

    const display_num = try findFreeDisplay(opts.io);
    var display_buf: [5]u8 = undefined;
    const display = try std.fmt.bufPrintSentinel(&display_buf, ":{d}", .{display_num}, 0);
    try opts.envmap.put("DISPLAY", display);

    var xauth_buf: [std.fs.max_path_bytes]u8 = undefined;
    const xauth_path = try xauth.createXauthEntry(
        opts.io,
        &xauth_buf,
        display[1..],
        opts.user.uid,
        opts.user.gid,
        opts.envmap.get("XDG_RUNTIME_DIR"),
    );
    errdefer std.Io.Dir.deleteFileAbsolute(opts.io, xauth_path) catch {};
    const xauth_path_z = try allocator.dupeSentinel(u8, xauth_path, 0);
    errdefer allocator.free(xauth_path_z);
    try opts.envmap.put("XAUTHORITY", xauth_path_z);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const startup_allocator = arena.allocator();
    const environ = try opts.envmap.createPosixBlock(startup_allocator, .{});

    var vt_buf: [6]u8 = undefined;
    const vt: ?[:0]const u8 = if (opts.vt.ttyNumber(opts.io)) |vt_num|
        try std.fmt.bufPrintSentinel(&vt_buf, "vt{d}", .{vt_num}, 0)
    else
        null;

    const x_cmd = opts.host_env_map.get("ZGSLD_X11_CMD") orelse "/bin/X";
    const shell_cmd_z = try std.fmt.allocPrintSentinel(
        startup_allocator,
        "exec {s} \"$@\"",
        .{x_cmd},
        0,
    );

    var ready = try DisplayPipe.init();
    defer ready.deinit(opts.io);
    var display_fd_buf: [16]u8 = undefined;
    const display_fd = try std.fmt.bufPrintSentinel(
        &display_fd_buf,
        "{d}",
        .{ready.write_file.?.handle},
        0,
    );

    const argv = [_:null]?[*:0]const u8{
        "/bin/sh",
        "-c",
        shell_cmd_z.ptr,
        "zgsld-x11",
        "-auth",
        xauth_path_z.ptr,
        display.ptr,
        "-displayfd",
        display_fd.ptr,
        if (vt) |arg| arg.ptr else null,
    };

    const tty_file = try opts.vt.openDevice(opts.io, .read_write);
    defer tty_file.close(opts.io);
    const groups = try utils.getGroups(allocator, opts.user);
    defer allocator.free(groups);

    const pid = try opts.shutdown_conn.fork(.x11);
    if (pid == 0) {
        ready.prepareChild();
        tty.redirectStdinToTty(tty_file.handle) catch std.c._exit(1);
        if (tty_file.handle > 2) _ = std.c.close(tty_file.handle);
        utils.dropPrivileges(opts.user, groups) catch std.c._exit(1);
        _ = std.c.execve("/bin/sh", &argv, environ.slice.ptr);
        std.c._exit(1);
    }

    ready.closeWriter(opts.io);

    var server = Shutdown.Connection.childFromPid(pid);
    errdefer opts.shutdown_conn.stop(&server, .x11);

    const ready_result = ready.wait(opts.io, opts.shutdown_conn, display_num, timeout_seconds);
    if (hasExited(pid)) {
        server.id = null;
        try opts.shutdown_conn.exited(.x11);
        return error.XServerExited;
    }
    try ready_result;
    return .{
        .child = server,
        .shutdown_conn = opts.shutdown_conn,
        .xauth_path = xauth_path_z,
        .allocator = allocator,
    };
}

pub fn deinit(self: *XServer, io: std.Io) void {
    self.shutdown_conn.stop(&self.child, .x11);
    std.Io.Dir.deleteFileAbsolute(io, self.xauth_path) catch {};
    self.allocator.free(self.xauth_path);
    self.* = undefined;
}

fn findFreeDisplay(io: std.Io) !u8 {
    for (0..200) |display| {
        var lock_buf: [15]u8 = undefined;
        const lock_path = try std.fmt.bufPrint(&lock_buf, "/tmp/.X{d}-lock", .{display});
        std.Io.Dir.accessAbsolute(io, lock_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return @intCast(display),
            error.AccessDenied, error.PermissionDenied => {},
            else => return err,
        };
    }

    return error.NoAvailableDisplay;
}

fn hasExited(pid: std.posix.pid_t) bool {
    while (true) {
        const rc = std.c.waitpid(pid, null, std.posix.W.NOHANG);
        switch (std.c.errno(rc)) {
            .SUCCESS => return rc == pid,
            .INTR => continue,
            .CHILD => unreachable,
            .INVAL => unreachable,
            else => unreachable,
        }
    }
}
