const std = @import("std");
const c = @import("c");

pub fn openVtControlDevice(io: std.Io) !std.Io.File {
    return std.Io.Dir.openFileAbsolute(io, "/dev/tty0", .{ .mode = .read_write });
}

pub fn activate(io: std.Io, vt_num: u8) !void {
    var console = try openVtControlDevice(io);
    defer console.close(io);

    const active = queryCurrentTtyNumber(console.handle) catch null;
    if (active == vt_num) return;

    var setactivate = std.mem.zeroes(c.struct_vt_setactivate);
    setactivate.console = vt_num;
    setactivate.mode.mode = c.VT_AUTO;
    const status = c.ioctl(console.handle, c.VT_SETACTIVATE, &setactivate);
    if (status != 0) return error.FailedToActivateTty;

    const wait_status = c.ioctl(console.handle, c.VT_WAITACTIVE, @as(c_int, vt_num));
    if (wait_status != 0) return error.FailedToWaitForActiveTty;
}

pub fn queryCurrentTtyNumber(tty_fd: std.posix.fd_t) !u8 {
    var state = std.mem.zeroes(c.struct_vt_stat);
    const status = c.ioctl(tty_fd, c.VT_GETSTATE, &state);
    if (status != 0) return error.FailedToGetTtyState;

    return std.math.cast(u8, state.v_active) orelse error.InvalidTty;
}

pub fn parseTtyNumberFromPath(tty_path: []const u8) !u8 {
    const prefix = "/dev/tty";
    if (!std.mem.startsWith(u8, tty_path, prefix)) return error.InvalidTtyPath;

    const suffix = tty_path[prefix.len..];
    if (suffix.len == 0) return error.InvalidTtyPath;

    const tty_number = try std.fmt.parseInt(u8, suffix, 10);
    if (tty_number == 0) return error.InvalidTty;
    return tty_number;
}

pub fn getTtyDevicePath(buf: *[std.fs.max_path_bytes]u8, target_vt: u8) ![:0]const u8 {
    if (target_vt == 0) return error.InvalidTty;
    return std.fmt.bufPrintSentinel(buf, "/dev/tty{d}", .{target_vt}, 0);
}

pub fn setTextMode(fd: std.posix.fd_t) !void {
    const status = c.ioctl(fd, c.KDSETMODE, @as(c_int, c.KD_TEXT));
    if (status != 0) return error.FailedToSetTextMode;
}
