const std = @import("std");
const fd = @import("fd.zig");

const SocketPair = @This();

parent: std.Io.File,
child: std.Io.File,

pub fn init(io: std.Io, parent_cloexec: bool) !SocketPair {
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (rc != 0) return std.posix.unexpectedErrno(std.posix.errno(rc));

    const parent: std.Io.File = .{
        .handle = fds[0],
        .flags = .{ .nonblocking = false },
    };
    errdefer parent.close(io);

    const child: std.Io.File = .{
        .handle = fds[1],
        .flags = .{ .nonblocking = false },
    };
    errdefer child.close(io);

    if (parent_cloexec) {
        try fd.setCloseOnExec(parent.handle);
    }

    return .{
        .parent = parent,
        .child = child,
    };
}
