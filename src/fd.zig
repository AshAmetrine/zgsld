const std = @import("std");

pub fn setCloseOnExec(fd: std.posix.fd_t) !void {
    const flags = try std.posix.fcntl(fd, std.posix.F.GETFD, 0);
    _ = try std.posix.fcntl(fd, std.posix.F.SETFD, flags | std.posix.FD_CLOEXEC);
}
