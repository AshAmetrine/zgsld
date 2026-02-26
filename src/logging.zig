//! Logging helpers used by zgsld and greeter integrations.

const std = @import("std");

var log_fd: ?std.posix.fd_t = null;

/// Reads `ZGSLD_LOG` and sets the output fd used by `logFn`.
///
/// Call once near process startup before emitting logs.
pub fn initZgsldLog() void {
    if (std.posix.getenv("ZGSLD_LOG")) |value| {
        log_fd = std.fmt.parseInt(std.posix.fd_t, value, 10) catch null;
    }
}

/// Log function for greeters to use the same log output location as zgsld 
///
/// `pub const std_options: std.Options = .{ .logFn = zgsld.logFn };`
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const fd = log_fd orelse std.posix.STDERR_FILENO;

    var buffer: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const writer = stream.writer();

    const prefix = if (scope == .default) "" else "[" ++ @tagName(scope) ++ "]";
    const level_txt = "[" ++ comptime level.asText() ++ "] ";
    writer.print(prefix ++ level_txt ++ format ++ "\n", args) catch return;

    const msg = stream.getWritten();
    _ = std.posix.write(fd, msg) catch return;
}
