const std = @import("std");
const builtin = @import("builtin");

extern "c" fn initgroups(user: [*:0]const u8, group: std.posix.gid_t) c_int;

pub const UserInfo = struct {
    username: [:0]const u8,
    uid: std.posix.uid_t,
    gid: std.posix.gid_t,
};

pub fn dropPrivileges(user_info: UserInfo) !void {
    if (initgroups(user_info.username, user_info.gid) != 0) {
        return std.posix.unexpectedErrno(std.posix.errno(-1));
    }
    try std.posix.setgid(user_info.gid);
    try std.posix.setuid(user_info.uid);
}

pub fn ensureOwnedDirAt(
    parent: std.fs.Dir,
    name: []const u8,
    mode: u32,
    uid: std.posix.uid_t,
    gid: std.posix.gid_t,
) !std.fs.Dir {
    const created = blk: {
        parent.makeDir(name) catch |err| switch (err) {
            error.PathAlreadyExists => break :blk false,
            else => return err,
        };
        break :blk true;
    };

    var dir = try parent.openDir(name, .{ .no_follow = true });
    errdefer dir.close();

    const stat = try std.posix.fstat(dir.fd);
    if (created) {
        try dir.chown(uid, gid);
    } else if (stat.uid != uid or stat.gid != gid) {
        return error.UnsafePathOwnership;
    }
    try dir.chmod(mode);
    return dir;
}
