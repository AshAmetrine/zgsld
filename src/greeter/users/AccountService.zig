const std = @import("std");
const goose = @import("goose");
const User = @import("../users.zig").User;
const UserList = @import("../users.zig").UserList;
const GStr = goose.core.value.GStr;
const GPath = goose.core.value.GPath;
const Properties = std.StringHashMap(goose.core.value.GVariant);

const AccountService = @This();

conn: goose.Connection,

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
) !AccountService {
    return .{
        .conn = try goose.Connection.init(allocator, .System, io, env_map),
    };
}
pub fn deinit(self: *AccountService) void {
    self.conn.close();
    self.* = undefined;
}

pub fn getUsers(self: *AccountService, allocator: std.mem.Allocator) !UserList {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const users = try self.getUsersLeaky(arena.allocator());
    return .{
        .arena = arena,
        .items = users,
    };
}

pub fn getUsersLeaky(self: *AccountService, allocator: std.mem.Allocator) ![]User {
    const p = goose.proxy.Proxy.init(
        &self.conn,
        "org.freedesktop.Accounts",
        "/org/freedesktop/Accounts",
        "org.freedesktop.Accounts",
    );
    var result = try p.call("ListCachedUsers", .{});
    defer result.deinit();
    const paths = try result.expect([]GPath);
    var users: std.ArrayList(User) = .empty;

    for (paths) |path| {
        const properties_proxy = goose.proxy.Proxy.init(
            &self.conn,
            "org.freedesktop.Accounts",
            path.s,
            "org.freedesktop.DBus.Properties",
        );
        var properties_result = try properties_proxy.call(
            "GetAll",
            .{GStr.new("org.freedesktop.Accounts.User")},
        );
        defer properties_result.deinit();
        var decoder = properties_result.reader();
        const properties = try decoder.decodeAlloc(Properties);
        const system_account = properties.get("SystemAccount") orelse
            return error.InvalidAccountProperties;
        switch (system_account) {
            .boolean => |value| if (value) continue,
            else => return error.InvalidAccountProperties,
        }

        const name = try getString(properties, "UserName");
        if (name.len == 0) return error.InvalidAccountProperties;
        const real_name = try getString(properties, "RealName");
        const shell = try getString(properties, "Shell");
        const icon = try getString(properties, "IconFile");
        try users.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .display_name = try allocator.dupe(u8, if (real_name.len == 0) name else real_name),
            .shell = try allocator.dupe(u8, shell),
            .avatar_path = if (icon.len == 0) null else try allocator.dupe(u8, icon),
        });
    }
    return users.items;
}

fn getString(properties: Properties, key: []const u8) ![]const u8 {
    const value = properties.get(key) orelse return error.InvalidAccountProperties;
    return switch (value) {
        .string => |string| string.s,
        else => error.InvalidAccountProperties,
    };
}
