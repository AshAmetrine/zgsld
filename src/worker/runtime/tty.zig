const std = @import("std");
const vt_mod = @import("vt");
const Config = @import("../../Config.zig");

const log = std.log.scoped(.zgsld_worker);

pub fn redirectStdioToControllingTty(tty_fd: std.posix.fd_t) !void {
    try std.posix.dup2(tty_fd, std.posix.STDIN_FILENO);
    try std.posix.dup2(tty_fd, std.posix.STDOUT_FILENO);
    try std.posix.dup2(tty_fd, std.posix.STDERR_FILENO);
}

pub fn resolvePamTty(tty_path_buf: *[std.fs.max_path_bytes]u8, vt: Config.Vt) !?[:0]const u8 {
    switch (vt) {
        .number => |vt_num| {
            if (vt_mod.getTtyPath(tty_path_buf, vt_num)) |tty_path| {
                return tty_path;
            } else |err| {
                log.warn("Failed to resolve configured VT path for PAM_TTY: {s}", .{@errorName(err)});
            }
        },
        .unmanaged, .current => {},
    }

    if (vt_mod.getInheritedTtyPath(tty_path_buf)) |tty_path| {
        return tty_path;
    } else |err| {
        log.warn("Failed to resolve inherited TTY path for PAM_TTY: {s}", .{@errorName(err)});
    }

    if (vt_mod.getCurrentTtyPath(tty_path_buf)) |tty_path| {
        if (std.mem.eql(u8, tty_path, "/dev/tty")) {
            log.err("Refusing to set PAM_TTY to /dev/tty alias", .{});
            return error.InvalidPamTty;
        }
        return tty_path;
    } else |err| {
        log.err("Failed to resolve current TTY path for PAM_TTY: {s}", .{@errorName(err)});
        return error.InvalidPamTty;
    }
}
