const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    if (builtin.os.tag == .linux) {
        @cInclude("linux/vt.h");
    } else if (builtin.os.tag == .freebsd) {
        @cInclude("sys/consio.h");
    }
});

// TODO
pub fn switchTty(tty: u8) !void {
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .freebsd) {
        return error.Unsupported;
    }

    var status = std.c.ioctl(std.posix.STDIN_FILENO, c.VT_ACTIVATE, @as(c_int, tty));
    if (status != 0) return error.FailedToActivateTty;

    status = std.c.ioctl(std.posix.STDIN_FILENO, c.VT_WAITACTIVE, @as(c_int, tty));
    if (status != 0) return error.FailedToWaitForActiveTty;
}
