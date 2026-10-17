const std = @import("std");

const SocketPair = @This();

parent: std.Io.File,
child: std.Io.File,

pub fn init() !SocketPair {
    var fds: [2]std.posix.fd_t = undefined;
    const sock_type = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC;
    const rc = std.c.socketpair(std.posix.AF.UNIX, sock_type, 0, &fds);
    if (rc != 0) return std.posix.unexpectedErrno(std.posix.errno(rc));

    return .{
        .parent = .{
            .handle = fds[0],
            .flags = .{ .nonblocking = false },
        },
        .child = .{
            .handle = fds[1],
            .flags = .{ .nonblocking = false },
        },
    };
}
