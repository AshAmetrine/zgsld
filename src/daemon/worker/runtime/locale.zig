const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.zgsld_worker);

// std.c.LC does not define values for FreeBSD.
// LC_ALL on FreeBSD is 0.
pub const all: std.c.LC = if (builtin.os.tag == .freebsd) @fromBackingInt(@intCast(0)) else .ALL;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

pub fn restore(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
) !void {
    for ([_][:0]const u8{ "LANG", "LC_ALL", "LANGUAGE" }) |key| {
        if (environment.get(key)) |value| {
            const value_z = try allocator.dupeSentinel(u8, value, 0);
            defer allocator.free(value_z);
            if (setenv(key, value_z, 1) != 0) return error.OutOfMemory;
        } else if (unsetenv(key) != 0) {
            return error.Unexpected;
        }
    }
    // Fall back to "C" if the default locale is unavailable.
    _ = std.c.setlocale(all, "C");
    _ = std.c.setlocale(all, "");
}

pub fn apply(name: [:0]const u8) !void {
    if (name.len == 0) return;

    // Reject paths and composite locales.
    for (name) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.', '@' => {},
            else => {
                log.warn("Invalid authentication locale", .{});
                return;
            },
        }
    }

    if (std.c.setlocale(all, name) == null) {
        log.warn("Authentication locale unavailable: {s}", .{name});
        return;
    }
    if (setenv("LANG", name, 1) != 0 or setenv("LC_ALL", name, 1) != 0) {
        return error.OutOfMemory;
    }
    if (unsetenv("LANGUAGE") != 0) return error.Unexpected;
}
