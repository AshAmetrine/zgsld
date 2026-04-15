const std = @import("std");

pub const runtime = @import("worker/runtime.zig");
pub const WorkerProcess = @import("worker/process.zig").WorkerProcess;

pub fn isSessionWorker(args: std.process.Args) bool {
    var it = args.iterate();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, "--session-worker", arg)) return true;
    }
    return false;
}
