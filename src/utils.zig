const std = @import("std");
const builtin = @import("builtin");
const UserInfo = @import("UserInfo.zig");
const c = @cImport({
    if (builtin.os.tag == .linux) {
        @cInclude("grp.h");
    } else if (builtin.os.tag == .freebsd) {
        @cInclude("unistd.h");
    }
});

pub fn isSessionWorker() bool {
    var args = std.process.args();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, "--session-worker", arg)) return true;
    }
    return false;
}

pub fn dropPrivileges(user_info: UserInfo) !void {
    if (std.posix.geteuid() != 0) return;
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .freebsd) {
        return error.UnsupportedPlatform;
    }
    if (c.initgroups(user_info.username, user_info.gid) != 0) {
        return std.posix.unexpectedErrno(std.posix.errno(-1));
    }
    try std.posix.setgid(user_info.gid);
    try std.posix.setuid(user_info.uid);
}
