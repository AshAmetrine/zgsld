const std = @import("std");
const c = @import("c");

pub fn openVtControlDevice(io: std.Io) !std.Io.File {
    return std.Io.Dir.openFileAbsolute(io, "/dev/console", .{ .mode = .read_write });
}

pub fn getTtyDevicePath(buf: *[std.fs.max_path_bytes]u8, target_vt: u8) ![:0]const u8 {
    if (target_vt == 0) return error.InvalidTty;

    return std.fmt.bufPrintSentinel(buf, "/dev/ttyv{x}", .{target_vt - 1}, 0);
}

pub fn activate(io: std.Io, vt_num: u8) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tty_path = try getTtyDevicePath(&path_buf, vt_num);
    // FreeBSD requires the target VT to remain open while switching to it.
    var tty_file = try std.Io.Dir.openFileAbsolute(io, tty_path, .{ .mode = .read_write });
    defer tty_file.close(io);

    var active: c_int = 0;
    if (c.ioctl(tty_file.handle, c.VT_GETACTIVE, &active) == 0 and active == vt_num) return;

    var mode = std.mem.zeroes(c.struct_vt_mode);
    mode.mode = c.VT_AUTO;
    const mode_status = c.ioctl(tty_file.handle, c.VT_SETMODE, &mode);
    if (mode_status != 0) return error.FailedToSetTtyMode;

    const status = c.ioctl(tty_file.handle, c.VT_ACTIVATE, @as(c_int, vt_num));
    if (status != 0) return error.FailedToActivateTty;

    const wait_status = c.ioctl(tty_file.handle, c.VT_WAITACTIVE, @as(c_int, vt_num));
    if (wait_status != 0) return error.FailedToWaitForActiveTty;
}

pub fn queryCurrentTtyNumber(tty_fd: std.posix.fd_t) !u8 {
    var tty_index: c_int = 0;
    const status = c.ioctl(tty_fd, c.VT_GETINDEX, &tty_index);
    if (status != 0) return error.FailedToGetTtyIndex;

    // VT_GETINDEX is already one-based, unlike /dev/ttyv names.
    const number = std.math.cast(u8, tty_index) orelse return error.InvalidTty;
    if (number == 0) return error.InvalidTty;
    return number;
}

pub fn parseTtyNumberFromPath(tty_path: []const u8) !u8 {
    const prefix = "/dev/ttyv";
    if (!std.mem.startsWith(u8, tty_path, prefix)) return error.InvalidTtyPath;

    const suffix = tty_path[prefix.len..];
    if (suffix.len == 0) return error.InvalidTtyPath;

    const tty_index = try std.fmt.parseInt(u8, suffix, 16);
    return std.math.add(u8, tty_index, 1) catch error.InvalidTty;
}
