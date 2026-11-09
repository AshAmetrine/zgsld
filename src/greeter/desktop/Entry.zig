const std = @import("std");
const parser = @import("parser.zig");

const Entry = @This();

pub const DesktopNames = struct {
    /// Colon-separated names suitable for setting XDG_CURRENT_DESKTOP.
    value: []const u8,

    const Iterator = std.mem.TokenIterator(u8, .scalar);

    pub fn iterator(self: DesktopNames) Iterator {
        return std.mem.tokenizeScalar(u8, self.value, ':');
    }
};

name: []const u8,
exec: []const u8,
comment: ?[]const u8 = null,
icon: ?[]const u8 = null,
desktop_names: ?DesktopNames = null,

pub fn parse(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Entry {
    return parser.parse(allocator, reader);
}

pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
    inline for (.{ "name", "exec", "comment", "icon" }) |field| {
        const value: ?[]const u8 = @field(self.*, field);
        if (value) |v| allocator.free(v);
    }
    if (self.desktop_names) |desktop_names| allocator.free(desktop_names.value);
    self.* = undefined;
}
