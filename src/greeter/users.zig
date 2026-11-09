const std = @import("std");

pub const User = struct {
    name: []const u8,
    display_name: []const u8,
    shell: []const u8,
    avatar_path: ?[]const u8 = null,
};

pub const Passwd = struct {
    name: []const u8,
    uid: std.posix.uid_t,
    shell: []const u8,
};

pub const Options = struct {
    filter: *const fn (user: Passwd) bool = defaultUserFilter,
};

pub fn defaultUserFilter(user: Passwd) bool {
    if (user.uid < 500) return false;

    const shell_name = std.fs.path.basename(user.shell);
    for ([_][]const u8{ "false", "nologin" }) |shell| {
        if (std.mem.eql(u8, shell_name, shell)) return false;
    }

    return true;
}

pub const UserList = struct {
    items: []const User,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *UserList) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Returns filtered users from the password database.
/// Call `deinit` on the returned list to free its memory.
pub fn getUsers(allocator: std.mem.Allocator, io: std.Io, opts: Options) !UserList {
    var arena = std.heap.ArenaAllocator.init(allocator);
    const arena_allocator = arena.allocator();
    errdefer arena.deinit();
    const users = try getUsersLeaky(arena_allocator, io, opts);
    return .{
        .arena = arena,
        .items = users,
    };
}

/// Returns filtered users from the password database.
/// It's recommended to use a `std.heap.ArenaAllocator` or similar.
/// Allocations are not freed on error.
pub fn getUsersLeaky(allocator: std.mem.Allocator, io: std.Io, opts: Options) ![]User {
    std.c.setpwent();
    defer std.c.endpwent();

    var users = std.ArrayList(User).empty;

    while (true) {
        std.c._errno().* = 0;
        const pwd = std.c.getpwent() orelse {
            switch (std.c.errno(@as(c_int, -1))) {
                .SUCCESS => break,
                .INTR => continue,
                .NOMEM => return error.OutOfMemory,
                else => return error.UserEnumerationFailed,
            }
        };
        const passwd: Passwd = .{
            .name = std.mem.span(pwd.name.?),
            .uid = pwd.uid,
            .shell = std.mem.span(pwd.shell.?),
        };
        if (!opts.filter(passwd)) continue;
        const display_name = blk: {
            if (pwd.gecos) |gecos| {
                const name = std.mem.sliceTo(std.mem.span(gecos), ',');
                if (name.len != 0) break :blk name;
            }
            break :blk passwd.name;
        };
        const home = std.mem.span(pwd.dir.?);
        const avatar_path = try getAvatarPath(io, allocator, home);

        try users.append(allocator, .{
            .display_name = try allocator.dupe(u8, display_name),
            .name = try allocator.dupe(u8, passwd.name),
            .shell = try allocator.dupe(u8, passwd.shell),
            .avatar_path = avatar_path,
        });
    }

    return users.items;
}

fn getAvatarPath(io: std.Io, allocator: std.mem.Allocator, home: []const u8) !?[]const u8 {
    if (!std.fs.path.isAbsolute(home)) return null;

    for ([_][]const u8{ ".face", ".face.icon" }) |filename| {
        const path = try std.fs.path.join(allocator, &.{ home, filename });
        std.Io.Dir.accessAbsolute(io, path, .{ .read = true }) catch |err| {
            allocator.free(path);
            switch (err) {
                error.FileNotFound, error.AccessDenied, error.PermissionDenied => continue,
                else => return err,
            }
        };
        return path;
    }
    return null;
}

test "enumerates users" {
    var users = try getUsers(std.testing.allocator, std.testing.io, .{});
    defer users.deinit();

    for (users.items) |user| {
        try std.testing.expect(user.name.len != 0);
        try std.testing.expect(user.display_name.len != 0);
    }
}

test "get avatar path" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const size = try tmp.dir.realPath(io, &buf);
    const home = buf[0..size];

    try tmp.dir.writeFile(io, .{
        .sub_path = ".face",
        .data = "",
    });

    const avatar_path = try getAvatarPath(io, allocator, home);
    defer allocator.free(avatar_path.?);

    const expected = try std.fs.path.join(allocator, &.{ home, ".face" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, avatar_path.?);
}
