const std = @import("std");
const goose = @import("goose");
const User = @import("../users.zig").User;
const UserList = @import("../users.zig").UserList;
const GStr = goose.core.value.GStr;
const GPath = goose.core.value.GPath;
const GVariant = goose.core.value.GVariant;
const GVariantTag = goose.core.value.GVariantTag;
const Properties = std.StringHashMap(GVariant);

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
        const system_account = try get(.boolean, properties, "SystemAccount") orelse
            return error.InvalidAccountProperties;
        if (system_account) continue;

        try users.append(allocator, try userFromProperties(allocator, properties));
    }
    return users.items;
}

fn userFromProperties(allocator: std.mem.Allocator, properties: Properties) !User {
    const name = try get(.string, properties, "UserName") orelse
        return error.InvalidAccountProperties;
    const real_name = try get(.string, properties, "RealName") orelse name;
    const shell = try get(.string, properties, "Shell") orelse
        return error.InvalidAccountProperties;
    const icon = try get(.string, properties, "IconFile");
    const language = try get(.string, properties, "Language");
    const session = try get(.string, properties, "Session") orelse
        try get(.string, properties, "XSession");
    const session_type = try get(.string, properties, "SessionType");
    const login_frequency = try get(.uint64, properties, "LoginFrequency");
    const login_time = try get(.int64, properties, "LoginTime");

    return .{
        .name = try allocator.dupe(u8, name),
        .display_name = try allocator.dupe(u8, real_name),
        .shell = try allocator.dupe(u8, shell),
        .avatar_path = if (icon) |path| try allocator.dupe(u8, path) else null,
        .language = if (language) |lang| try allocator.dupeSentinel(u8, lang, 0) else null,
        .session = if (session) |id| try allocator.dupe(u8, id) else null,
        .session_type = if (session_type) |kind| try allocator.dupe(u8, kind) else null,
        .login_frequency = login_frequency,
        .login_time = login_time,
    };
}

fn PropertyType(comptime tag: GVariantTag) type {
    return if (tag == .string) [:0]const u8 else @FieldType(GVariant, @tagName(tag));
}

fn get(comptime tag: GVariantTag, properties: Properties, name: []const u8) !?PropertyType(tag) {
    const property = properties.get(name) orelse return null;
    if (std.meta.activeTag(property) != tag) return error.InvalidAccountProperties;

    const value = @field(property, @tagName(tag));
    if (tag == .string) {
        return if (value.s.len == 0) null else value.s;
    }
    return value;
}
