const std = @import("std");
const builtin = @import("builtin");

const setgroups = switch (builtin.os.tag) {
    .linux => struct {
        extern "c" fn setgroups(count: usize, groups: [*]const std.posix.gid_t) c_int;
    }.setgroups,
    else => struct {
        extern "c" fn setgroups(count: c_int, groups: [*]const std.posix.gid_t) c_int;
    }.setgroups,
};

extern "c" fn getgrouplist(user: [*:0]const u8, group: std.posix.gid_t, groups: ?[*]std.posix.gid_t, count: *c_int) c_int;

pub const UserInfo = struct {
    username: [:0]const u8,
    uid: std.posix.uid_t,
    gid: std.posix.gid_t,
};

pub fn getGroups(allocator: std.mem.Allocator, user: UserInfo) ![]std.posix.gid_t {
    var groups: std.ArrayList(std.posix.gid_t) = .empty;
    errdefer groups.deinit(allocator);
    var count: c_int = 0;
    while (getgrouplist(user.username, user.gid, if (groups.capacity == 0) null else groups.items.ptr, &count) < 0) {
        if (count <= 0 or @as(usize, @intCast(count)) <= groups.capacity) return error.GroupLookupFailed;
        try groups.ensureTotalCapacityPrecise(allocator, @intCast(count));
    }
    groups.items.len = @intCast(count);
    return groups.toOwnedSlice(allocator);
}

pub fn dropPrivileges(user_info: UserInfo, groups: []const std.posix.gid_t) !void {
    if (setgroups(@intCast(groups.len), groups.ptr) != 0) return error.SetGroupsFailed;
    if (std.c.setgid(user_info.gid) != 0) return error.SetGidFailed;
    if (std.c.setuid(user_info.uid) != 0) return error.SetUidFailed;
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

    if (created) {
        try dir.setOwner(io, uid, gid);
    } else {
        const owner = try getOwner(dir);
        if (owner.uid != uid or owner.gid != gid) {
            return error.UnsafePathOwnership;
        }
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
