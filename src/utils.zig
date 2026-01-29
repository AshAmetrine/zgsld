const std = @import("std");

pub fn selfExePathAllocZ(allocator: std.mem.Allocator) ![:0]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    return allocator.dupeZ(u8, try std.fs.selfExePath(&buf));
}
