const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("sys/ioctl.h");
    if (builtin.os.tag == .linux) {
        @cInclude("linux/vt.h");
        @cInclude("linux/kd.h");
    } else if (builtin.os.tag == .freebsd) {
        @cInclude("sys/consio.h");
    }
});
const log = std.log.scoped(.zgsld);
extern "c" fn getsid(pid: std.posix.pid_t) std.posix.pid_t;
extern "c" fn ttyname_r(fd: std.posix.fd_t, buf: [*]u8, buflen: usize) c_int;

// std.c.ioctl definition expects request to be c_int
// but for glibc/BSD, it should be c_ulong, so we use c.ioctl instead

pub fn initTty(tty: u8) !void {
    if (tty == 0) return error.InvalidTty;
    try activateTty(tty);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tty_path = try getTtyPath(&path_buf, tty);
    var tty_file = try std.fs.openFileAbsolute(tty_path, .{ .mode = .read_write });
    defer if (tty_file.handle > 2) tty_file.close();

    try setTextMode(tty_file.handle);

    if (controllingTtyIs(tty_file.handle)) {
        log.debug("Controlling TTY already matches desired TTY", .{});
        return;
    }

    _ = std.posix.setsid() catch |err| switch (err) {
        error.PermissionDenied => {},
        else => return err,
    };

    const status = c.ioctl(tty_file.handle, c.TIOCSCTTY, @as(c_int, 0));
    if (status != 0) return error.FailedToSetControllingTty;
}

pub fn resetTty(tty: u8) !void {
    if (tty == 0) return error.InvalidTty;
    try activateTty(tty);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tty_path = try getTtyPath(&path_buf, tty);
    var tty_file = try std.fs.openFileAbsolute(tty_path, .{ .mode = .read_write });
    defer if (tty_file.handle > 2) tty_file.close();

    try setTextMode(tty_file.handle);
}

pub fn resetTermios() void {
    var termios = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch {
        return;
    };
    termios.lflag.ISIG = true;
    termios.lflag.ICANON = true;
    termios.lflag.ECHO = true;
    termios.lflag.ECHONL = true;
    std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, termios) catch {};
}

pub fn ensureControllingTty() !void {
    var tty_file = try std.fs.openFileAbsolute("/dev/tty", .{ .mode = .read_write });
    tty_file.close();
}

fn activateTty(tty: u8) !void {
    var console = try openConsoleFile();
    defer console.close();

    if (comptime builtin.os.tag == .linux) {
        var setactivate = std.mem.zeroes(c.struct_vt_setactivate);
        setactivate.console = tty;
        setactivate.mode.mode = c.VT_AUTO;
        const status = c.ioctl(console.handle, c.VT_SETACTIVATE, &setactivate);
        if (status != 0) return error.FailedToActivateTty;
    } else {
        var mode = std.mem.zeroes(c.struct_vt_mode);
        mode.mode = c.VT_AUTO;
        const mode_status = c.ioctl(console.handle, c.VT_SETMODE, &mode);
        if (mode_status != 0) return error.FailedToSetTtyMode;

        const status = c.ioctl(console.handle, c.VT_ACTIVATE, @as(c_int, tty));
        if (status != 0) return error.FailedToActivateTty;
    }

    const wait_status = c.ioctl(console.handle, c.VT_WAITACTIVE, @as(c_int, tty));
    if (wait_status != 0) return error.FailedToWaitForActiveTty;
}

fn openConsoleFile() !std.fs.File {
    return std.fs.openFileAbsolute("/dev/tty0", .{ .mode = .read_write }) catch
        std.fs.openFileAbsolute("/dev/console", .{ .mode = .read_write });
}

fn setTextMode(fd: std.posix.fd_t) !void {
    if (comptime builtin.os.tag != .linux) return;
    const status = c.ioctl(fd, c.KDSETMODE, @as(c_int, c.KD_TEXT));
    if (status != 0) return error.FailedToSetTextMode;
}

fn controllingTtyIs(fd: std.posix.fd_t) bool {
    var sid: std.posix.pid_t = undefined;
    if (c.ioctl(fd, c.TIOCGSID, &sid) == 0) {
        const current_sid = getsid(0);
        if (current_sid >= 0 and sid == current_sid) return true;
    }
    return false;
}

pub fn getCurrentTtyPath(buf: *[std.fs.max_path_bytes]u8) ![:0]const u8 {
    var tty_file = try std.fs.openFileAbsolute("/dev/tty", .{ .mode = .read_only });
    defer tty_file.close();

    const rc = ttyname_r(tty_file.handle, @ptrCast(buf), buf.len);
    if (rc != 0) return std.posix.unexpectedErrno(@enumFromInt(rc));

    const tty_path = std.mem.sliceTo(buf, 0);
    return buf[0..tty_path.len :0];
}

pub fn getInheritedTtyPath(buf: *[std.fs.max_path_bytes]u8) ![:0]const u8 {
    const inherited_fds = [_]std.posix.fd_t{
        std.posix.STDIN_FILENO,
        std.posix.STDOUT_FILENO,
        std.posix.STDERR_FILENO,
    };

    for (inherited_fds) |fd| {
        const rc = ttyname_r(fd, @ptrCast(buf), buf.len);
        if (rc != 0) continue;

        const tty_path = std.mem.sliceTo(buf, 0);
        if (std.mem.eql(u8, tty_path, "/dev/tty")) continue;
        return buf[0..tty_path.len :0];
    }

    return error.NoInheritedTty;
}

pub fn getTtyPath(buf: *[std.fs.max_path_bytes]u8, target_vt: u8) ![:0]const u8 {
    if (target_vt == 0) return error.InvalidTty;

    return switch (builtin.os.tag) {
        .linux => std.fmt.bufPrintZ(buf, "/dev/tty{d}", .{target_vt}),
        .freebsd => std.fmt.bufPrintZ(buf, "/dev/ttyv{x}", .{target_vt - 1}),
        else => error.UnsupportedPlatform,
    };
}
