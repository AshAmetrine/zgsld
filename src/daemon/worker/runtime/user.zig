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

extern "c" fn getgrouplist(
    user: [*:0]const u8,
    group: std.posix.gid_t,
    groups: ?[*]std.posix.gid_t,
    count: *c_int,
) c_int;

pub const UserInfo = struct {
    username: [:0]const u8,
    uid: std.posix.uid_t,
    gid: std.posix.gid_t,
};

pub fn getGroups(allocator: std.mem.Allocator, user: UserInfo) ![]std.posix.gid_t {
    var groups: std.ArrayList(std.posix.gid_t) = .empty;
    errdefer groups.deinit(allocator);
    var count: c_int = 0;
    while (true) {
        const buffer = if (groups.capacity == 0) null else groups.items.ptr;
        if (getgrouplist(user.username, user.gid, buffer, &count) >= 0) break;
        if (count <= 0 or @as(usize, @intCast(count)) <= groups.capacity) {
            return error.GroupLookupFailed;
        }
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
