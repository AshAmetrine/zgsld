const std = @import("std");
const signals = @import("../../signals.zig");
const DisplayPipe = @This();

read_file: std.Io.File,
write_file: ?std.Io.File,

pub fn init() !DisplayPipe {
    const fds = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
    return .{
        .read_file = .{ .handle = fds[0], .flags = .{ .nonblocking = false } },
        .write_file = .{ .handle = fds[1], .flags = .{ .nonblocking = false } },
    };
}

pub fn deinit(self: *DisplayPipe, io: std.Io) void {
    self.closeWriter(io);
    self.read_file.close(io);
    self.* = undefined;
}

pub fn closeWriter(self: *DisplayPipe, io: std.Io) void {
    if (self.write_file) |file| file.close(io);
    self.write_file = null;
}

pub fn prepareChild(self: *const DisplayPipe) void {
    _ = std.c.close(self.read_file.handle);
    const fd = (self.write_file orelse std.c._exit(1)).handle;
    if (std.c.fcntl(fd, std.posix.F.SETFD, @as(c_int, 0)) < 0) std.c._exit(1);
}

pub fn wait(self: *const DisplayPipe, io: std.Io, display: u8, timeout_ms: u32) !void {
    std.debug.assert(self.write_file == null);
    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromMilliseconds(timeout_ms));
    var expected_buf: [4]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "{d}\n", .{display});
    var response: [4]u8 = undefined;
    var used: usize = 0;
    var fds = [_]std.c.pollfd{
        .{ .fd = self.read_file.handle, .events = std.c.POLL.IN, .revents = 0 },
    };
    while (true) {
        if (signals.shutdownRequested()) return error.Shutdown;
        const remaining = std.Io.Clock.awake.now(io).durationTo(deadline).toNanoseconds();
        if (remaining <= 0) return error.XServerTimeout;
        const rc = std.c.poll(&fds, fds.len, @intCast(@min(std.math.maxInt(c_int), @divCeil(remaining, std.time.ns_per_ms))));
        if (rc < 0) {
            if (std.c.errno(rc) == .INTR) continue;
            return std.posix.unexpectedErrno(std.c.errno(rc));
        }
        if (fds[0].revents & (std.c.POLL.ERR | std.c.POLL.NVAL) != 0) return error.DisplayReadFailed;
        if (fds[0].revents & (std.c.POLL.IN | std.c.POLL.HUP) == 0) continue;
        const count = self.read_file.readStreaming(io, &.{response[used..]}) catch |err| switch (err) {
            error.EndOfStream => return error.InvalidDisplayResponse,
            else => return err,
        };
        used += count;
        if (used > expected.len or !std.mem.eql(u8, response[0..used], expected[0..used])) return error.InvalidDisplayResponse;
        if (used == expected.len) return;
    }
}
