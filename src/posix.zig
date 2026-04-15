const std = @import("std");

pub const WaitPidResult = struct {
    pid: std.posix.pid_t,
    status: u32,
};

pub fn waitpid(pid: std.posix.pid_t, flags: u32) !WaitPidResult {
    var status: c_int = 0;
    while (true) {
        const rc = std.c.waitpid(pid, &status, @intCast(flags));
        switch (std.c.errno(rc)) {
            .SUCCESS => return .{
                .pid = @intCast(rc),
                .status = @bitCast(status),
            },
            .INTR => continue,
            .CHILD => unreachable,
            .INVAL => unreachable,
            else => unreachable,
        }
    }
}
