const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    if (builtin.os.tag == .linux) {
        @cInclude("grp.h");
    } else if (builtin.os.tag == .freebsd) {
        @cInclude("unistd.h");
    }
});

pub const UserInfo = struct {
    username: [:0]const u8,
    uid: std.posix.uid_t,
    gid: std.posix.gid_t,
};

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

pub fn ensureDirOwned(
    path: []const u8,
    mode: u32,
    uid: std.posix.uid_t,
    gid: std.posix.gid_t,
) !void {
    std.posix.mkdir(path, mode) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var dir = try std.fs.openDirAbsolute(path, .{});
    defer dir.close();

    const stat = try std.posix.fstat(dir.fd);
    if (stat.uid != uid or stat.gid != gid) {
        if (std.posix.geteuid() != 0) return error.PermissionDenied;
        try dir.chown(uid, gid);
    }
    try dir.chmod(mode);
}
