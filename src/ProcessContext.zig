const std = @import("std");

gpa: std.mem.Allocator,
io: std.Io,
args: std.process.Args,
environ_map: *const std.process.Environ.Map,

pub fn fromInit(process_init: std.process.Init) @This() {
    return .{
        .gpa = process_init.gpa,
        .io = process_init.io,
        .args = process_init.minimal.args,
        .environ_map = process_init.environ_map,
    };
}
