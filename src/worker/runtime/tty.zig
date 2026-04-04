const std = @import("std");

pub fn redirectStdioToTty(tty_fd: std.posix.fd_t) !void {
    try std.posix.dup2(tty_fd, std.posix.STDIN_FILENO);
    try std.posix.dup2(tty_fd, std.posix.STDOUT_FILENO);
    try std.posix.dup2(tty_fd, std.posix.STDERR_FILENO);
}
