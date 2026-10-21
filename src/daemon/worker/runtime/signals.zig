const std = @import("std");

var shutdown_signal = std.atomic.Value(u32).init(0);
var active_child_pid = std.atomic.Value(std.posix.pid_t).init(0);

pub fn installHandlers() void {
    const sigact = std.posix.Sigaction{
        .handler = .{ .handler = handleShutdownSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };

    const forward_signals = [_]std.posix.SIG{
        std.posix.SIG.TERM,
        std.posix.SIG.HUP,
        std.posix.SIG.QUIT,
    };

    for (forward_signals) |sig| {
        std.posix.sigaction(sig, &sigact, null);
    }

    const alarm_sigact = std.posix.Sigaction{
        .handler = .{ .handler = handleKillTimeout },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.ALRM, &alarm_sigact, null);
}

pub fn shutdownRequested() bool {
    return shutdown_signal.load(.seq_cst) != 0;
}

pub fn waitForChild(io: std.Io, child: *std.process.Child) !void {
    active_child_pid.store(child.id.?, .seq_cst);
    defer active_child_pid.store(0, .seq_cst);

    if (shutdownRequested()) {
        forwardShutdownSignal(shutdownSignal());
    }
    _ = try child.wait(io);
}

fn shutdownSignal() std.posix.SIG {
    return @fromBackingInt(@intCast(shutdown_signal.load(.seq_cst)));
}

fn forwardShutdownSignal(sig: std.posix.SIG) void {
    const child_pid = active_child_pid.load(.seq_cst);
    if (child_pid > 0) {
        std.posix.kill(child_pid, sig) catch {};
    }
    _ = std.c.alarm(5);
}

fn handleShutdownSignal(sig: std.posix.SIG) callconv(.c) void {
    shutdown_signal.store(@backingInt(sig), .seq_cst);
    forwardShutdownSignal(sig);
}

fn handleKillTimeout(_: std.posix.SIG) callconv(.c) void {
    if (!shutdownRequested()) return;
    const child_pid = active_child_pid.load(.seq_cst);
    if (child_pid > 0) {
        std.posix.kill(child_pid, std.posix.SIG.KILL) catch {};
    }
}
