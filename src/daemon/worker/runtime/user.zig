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
    if (std.c.setgid(user_info.gid) != 0) return std.posix.unexpectedErrno(std.posix.errno(-1));
    if (std.c.setuid(user_info.uid) != 0) return std.posix.unexpectedErrno(std.posix.errno(-1));
}

pub fn ensureOwnedDirAt(
    parent: std.Io.Dir,
    io: std.Io,
    name: []const u8,
    permissions: std.Io.Dir.Permissions,
    uid: std.posix.uid_t,
    gid: std.posix.gid_t,
) !std.Io.Dir {
    const created = blk: {
        parent.createDir(io, name, permissions) catch |err| switch (err) {
            error.PathAlreadyExists => break :blk false,
            else => return err,
        };
        break :blk true;
    };

    var dir = try parent.openDir(io, name, .{ .follow_symlinks = false, .iterate = true });
    errdefer dir.close(io);

    const owner = try getOwner(dir);
    if (created) {
        try dir.setOwner(io, uid, gid);
    } else if (owner.uid != uid or owner.gid != gid) {
        return error.UnsafePathOwnership;
    }
    try dir.setPermissions(io, permissions);
    return dir;
}

fn getOwner(dir: std.Io.Dir) !struct { uid: std.posix.uid_t, gid: std.posix.gid_t } {
    switch (comptime builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            var statx = std.mem.zeroes(linux.Statx);
            switch (linux.errno(linux.statx(
                dir.handle,
                "",
                linux.AT.EMPTY_PATH,
                .{ .UID = true, .GID = true },
                &statx,
            ))) {
                .SUCCESS => {
                    if (!statx.mask.UID or !statx.mask.GID) return error.Unexpected;
                    return .{ .uid = statx.uid, .gid = statx.gid };
                },
                else => |err| return std.posix.unexpectedErrno(err),
            }
        },
        else => {
            var stat: std.c.Stat = undefined;
            const rc = std.c.fstat(dir.handle, &stat);
            switch (std.c.errno(rc)) {
                .SUCCESS => return .{ .uid = stat.uid, .gid = stat.gid },
                else => |err| return std.posix.unexpectedErrno(err),
            }
        },
    }
}
