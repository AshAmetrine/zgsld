const std = @import("std");
pub const passwd = @import("users/passwd.zig");
pub const AccountService = @import("users/AccountService.zig");

pub const User = struct {
    name: []const u8,
    display_name: []const u8,
    shell: []const u8,
    avatar_path: ?[]const u8 = null,
};

pub const UserList = struct {
    items: []const User,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *UserList) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn getUsers(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    opts: passwd.Options,
) !UserList {
    var service = AccountService.init(allocator, io, env_map) catch |err| {
        return switch (err) {
            error.OutOfMemory, error.Canceled => err,
            else => passwd.getUsers(allocator, io, opts),
        };
    };
    defer service.deinit();

    return service.getUsers(allocator) catch |err| switch (err) {
        error.OutOfMemory, error.Canceled => err,
        else => passwd.getUsers(allocator, io, opts),
    };
}

test {
    _ = passwd;
}
