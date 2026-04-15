//! Logging helpers used by zgsld and greeter integrations.

const std = @import("std");

var log_fd: ?std.posix.fd_t = null;
var log_mutex: std.Io.Mutex = .init;

/// Reads `ZGSLD_LOG` and sets the output fd used by `logFn`.
///
/// Call once near process startup before emitting logs.
pub fn initZgsldLog(env_map: *const std.process.Environ.Map) void {
    if (env_map.get("ZGSLD_LOG")) |value| {
        log_fd = std.fmt.parseInt(std.posix.fd_t, value, 10) catch null;
    }
}

/// Log function for greeters to use the same log output location as zgsld
///
/// `pub const std_options: std.Options = .{ .logFn = zgsld.logFn };`
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const io = std.Options.debug_io;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    const prefix = if (scope == .default) "" else "[" ++ @tagName(scope) ++ "]";
    const level_txt = "[" ++ comptime level.asText() ++ "] ";
    writer.print(prefix ++ level_txt ++ format ++ "\n", args) catch return;

    const msg = buffer[0..writer.end];
    log_mutex.lockUncancelable(io);
    defer log_mutex.unlock(io);

    const file: std.Io.File = if (log_fd) |fd|
        .{ .handle = fd, .flags = .{ .nonblocking = false } }
    else
        .stderr();

    _ = file.writeStreaming(io, &.{}, &.{msg}, 1) catch return;
}
