const std = @import("std");

pub fn setCloseOnExec(fd: std.posix.fd_t) !void {
    const flags = std.c.fcntl(fd, std.posix.F.GETFD, @as(c_int, 0));
    if (flags < 0) return std.posix.unexpectedErrno(std.c.errno(flags));

    const rc = std.c.fcntl(fd, std.posix.F.SETFD, flags | std.posix.FD_CLOEXEC);
    if (rc < 0) return std.posix.unexpectedErrno(std.c.errno(rc));
}

pub fn clearCloseOnExec(fd: std.posix.fd_t) !void {
    const flags = std.c.fcntl(fd, std.posix.F.GETFD, @as(c_int, 0));
    if (flags < 0) return std.posix.unexpectedErrno(std.c.errno(flags));

    const rc = std.c.fcntl(fd, std.posix.F.SETFD, flags & ~@as(c_int, std.posix.FD_CLOEXEC));
    if (rc < 0) return std.posix.unexpectedErrno(std.c.errno(rc));
}
