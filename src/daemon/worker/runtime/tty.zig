const std = @import("std");

pub fn redirectStdinToTty(tty_fd: std.posix.fd_t) !void {
    try dupTo(tty_fd, std.posix.STDIN_FILENO);
}

pub fn redirectStdioToTty(tty_fd: std.posix.fd_t) !void {
    try redirectStdinToTty(tty_fd);
    try dupTo(tty_fd, std.posix.STDOUT_FILENO);
    try dupTo(tty_fd, std.posix.STDERR_FILENO);
}

fn dupTo(old_fd: std.posix.fd_t, new_fd: std.posix.fd_t) !void {
    const rc = std.c.dup2(old_fd, new_fd);
    if (rc < 0) return std.posix.unexpectedErrno(std.c.errno(rc));
}
