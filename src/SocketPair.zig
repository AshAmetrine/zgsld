const std = @import("std");

const SocketPair = @This();

parent: std.posix.fd_t,
child: std.posix.fd_t,

pub fn init(parent_cloexec: bool) !SocketPair {
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (rc != 0) return std.posix.unexpectedErrno(std.posix.errno(rc));
    errdefer std.posix.close(fds[0]);
    errdefer std.posix.close(fds[1]);

    if (parent_cloexec) {
        const flags = try std.posix.fcntl(fds[0], std.posix.F.GETFD, 0);
        _ = try std.posix.fcntl(fds[0], std.posix.F.SETFD, flags | std.posix.FD_CLOEXEC);
    }

    return .{
        .parent = fds[0],
        .child = fds[1],
    };
}
