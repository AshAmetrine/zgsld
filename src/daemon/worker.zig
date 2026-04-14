const std = @import("std");

pub const WorkerRuntime = @import("worker/runtime.zig").WorkerRuntime;
pub const WorkerProcess = @import("worker/process.zig").WorkerProcess;

pub fn isSessionWorker() bool {
    var args = std.process.args();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, "--session-worker", arg)) return true;
    }
    return false;
}
