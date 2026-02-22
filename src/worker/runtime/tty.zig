const std = @import("std");

pub fn redirectStdioToControllingTty() !void {
    var tty_file = try std.fs.openFileAbsolute("/dev/tty", .{ .mode = .read_write });
    defer if (tty_file.handle > 2) tty_file.close();

    try std.posix.dup2(tty_file.handle, std.posix.STDIN_FILENO);
    try std.posix.dup2(tty_file.handle, std.posix.STDOUT_FILENO);
    try std.posix.dup2(tty_file.handle, std.posix.STDERR_FILENO);
}
