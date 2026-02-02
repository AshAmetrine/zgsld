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

pub fn initTty(tty: u8) !void {
    if (tty == 0) return error.InvalidTty;
    try activateTty(tty);

    var path_buf: [32]u8 = undefined;
    const tty_path = try std.fmt.bufPrintZ(&path_buf, "/dev/tty{d}", .{tty});
    var tty_file = try std.fs.openFileAbsolute(tty_path, .{ .mode = .read_write });
    defer if (tty_file.handle > 2) tty_file.close();

    try setTextMode(tty_file.handle);

    _ = std.posix.setsid() catch |err| switch (err) {
        error.PermissionDenied => {},
        else => return err,
    };

    const status = std.c.ioctl(tty_file.handle, c.TIOCSCTTY, @as(c_int, 0));
    if (status != 0) return error.FailedToSetControllingTty;

    try std.posix.dup2(tty_file.handle, std.posix.STDIN_FILENO);
    try std.posix.dup2(tty_file.handle, std.posix.STDOUT_FILENO);
    try std.posix.dup2(tty_file.handle, std.posix.STDERR_FILENO);
}

pub fn resetTty(tty: u8) !void {
    if (tty == 0) return error.InvalidTty;
    try activateTty(tty);

    var path_buf: [32]u8 = undefined;
    const tty_path = try std.fmt.bufPrintZ(&path_buf, "/dev/tty{d}", .{tty});
    var tty_file = try std.fs.openFileAbsolute(tty_path, .{ .mode = .read_write });
    defer if (tty_file.handle > 2) tty_file.close();

    try setTextMode(tty_file.handle);
}

fn activateTty(tty: u8) !void {
    var console = try openConsoleFile();
    defer console.close();

    if (comptime builtin.os.tag == .linux) {
        var setactivate = std.mem.zeroes(c.struct_vt_setactivate);
        setactivate.console = tty;
        setactivate.mode.mode = c.VT_AUTO;
        const status = std.c.ioctl(console.handle, c.VT_SETACTIVATE, &setactivate);
        if (status != 0) return error.FailedToActivateTty;
    } else {
        var mode = std.mem.zeroes(c.struct_vt_mode);
        mode.mode = c.VT_AUTO;
        const mode_status = std.c.ioctl(console.handle, c.VT_SETMODE, &mode);
        if (mode_status != 0) return error.FailedToSetTtyMode;

        const status = std.c.ioctl(console.handle, c.VT_ACTIVATE, @as(c_int, tty));
        if (status != 0) return error.FailedToActivateTty;
    }

    const wait_status = std.c.ioctl(console.handle, c.VT_WAITACTIVE, @as(c_int, tty));
    if (wait_status != 0) return error.FailedToWaitForActiveTty;
}

fn openConsoleFile() !std.fs.File {
    return std.fs.openFileAbsolute("/dev/tty0", .{ .mode = .read_write }) catch
        std.fs.openFileAbsolute("/dev/console", .{ .mode = .read_write });
}

fn setTextMode(fd: std.posix.fd_t) !void {
    if (comptime builtin.os.tag != .linux) return;
    const status = std.c.ioctl(fd, c.KDSETMODE, @as(c_int, c.KD_TEXT));
    if (status != 0) return error.FailedToSetTextMode;
}
