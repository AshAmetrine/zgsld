const std = @import("std");
const fd = @import("fd.zig");

const SocketPair = @This();

parent: std.posix.fd_t,
child: std.posix.fd_t,

pub fn init(parent_cloexec: bool) !SocketPair {
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (rc != 0) return std.posix.unexpectedErrno(std.posix.errno(rc));
    errdefer _ = std.c.close(fds[0]);
    errdefer _ = std.c.close(fds[1]);

    if (parent_cloexec) {
        try fd.setCloseOnExec(fds[0]);
    }

    return .{
        .parent = fds[0],
        .child = fds[1],
    };
}
