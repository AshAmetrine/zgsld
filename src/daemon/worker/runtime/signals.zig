const std = @import("std");

var shutdown_requested = std.atomic.Value(bool).init(false);

pub fn installHandlers() void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = handleShutdown },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    for ([_]std.posix.SIG{ .TERM, .INT, .HUP, .QUIT }) |sig| {
        std.posix.sigaction(sig, &action, null);
    }
}

pub fn shutdownRequested() bool {
    return shutdown_requested.load(.seq_cst);
}

fn handleShutdown(_: std.posix.SIG) callconv(.c) void {
    shutdown_requested.store(true, .seq_cst);
}
