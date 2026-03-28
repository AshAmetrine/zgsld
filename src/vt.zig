const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("sys/ioctl.h");
    if (builtin.os.tag == .linux) {
        @cInclude("linux/vt.h");
        @cInclude("linux/kd.h");
    } else if (builtin.os.tag == .freebsd) {
        @cInclude("sys/consio.h");
    }
});
const log = std.log.scoped(.zgsld);
extern "c" fn getsid(pid: std.posix.pid_t) std.posix.pid_t;
extern "c" fn ttyname_r(fd: std.posix.fd_t, buf: [*]u8, buflen: usize) c_int;

// std.c.ioctl definition expects request to be c_int
// but for glibc/BSD, it should be c_ulong, so we use c.ioctl instead

pub fn initCurrentTty() !void {
    var tty_file = try openCurrentTty(.read_write);
    defer tty_file.close();

    try becomeSessionLeader();
    try attachControllingTty(tty_file.handle);
}

pub fn initTty(tty: u8) !void {
    var tty_file = try openAndActivateTty(tty);
    defer if (tty_file.handle > 2) tty_file.close();

    try setTextMode(tty_file.handle);
    try becomeSessionLeader();
    try attachControllingTty(tty_file.handle);
}

pub fn resetTty(tty: u8) !void {
    var tty_file = try openAndActivateTty(tty);
    defer if (tty_file.handle > 2) tty_file.close();

    try setTextMode(tty_file.handle);
}

pub fn resetTermios() void {
    var termios = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch {
        return;
    };
    termios.lflag.ISIG = true;
    termios.lflag.ICANON = true;
    termios.lflag.ECHO = true;
    termios.lflag.ECHONL = true;
    std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, termios) catch {};
}

pub fn restoreControllingTty(target_vt: ?u8) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tty_path = try resolveTargetTtyPath(&path_buf, target_vt);
    var tty_file = try std.fs.openFileAbsolute(tty_path, .{ .mode = .read_write });
    defer if (tty_file.handle > 2) tty_file.close();

    if (controllingTtyIsCurrentSession(tty_file.handle)) {
        log.debug("Controlling TTY already matches desired TTY", .{});
        return;
    }

    try attachControllingTty(tty_file.handle);
}

pub const ControllingTtyInputWatcher = struct {
    file: std.fs.File,
    original: std.posix.termios,

    pub fn init() !ControllingTtyInputWatcher {
        var tty_file = try openCurrentTty(.read_write);
        errdefer tty_file.close();

        const original = try std.posix.tcgetattr(tty_file.handle);
        var raw = original;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ECHONL = false;
        raw.lflag.ISIG = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        try std.posix.tcsetattr(tty_file.handle, .FLUSH, raw);

        return .{
            .file = tty_file,
            .original = original,
        };
    }

    pub fn deinit(self: *ControllingTtyInputWatcher) void {
        std.posix.tcsetattr(self.file.handle, .FLUSH, self.original) catch {};
        self.file.close();
    }

    pub fn waitForInput(self: *ControllingTtyInputWatcher, timeout_ms: u64) !bool {
        var poll_fds = [1]std.posix.pollfd{.{
            .fd = self.file.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const timeout: i32 = std.math.cast(i32, timeout_ms) orelse std.math.maxInt(i32);
        const ready = try std.posix.poll(&poll_fds, timeout);
        return ready != 0 and (poll_fds[0].revents & std.posix.POLL.IN) != 0;
    }
};

pub fn waitForControllingTtyInput(timeout_seconds: u64) !bool {
    if (timeout_seconds == 0) return false;

    var watcher = try ControllingTtyInputWatcher.init();
    defer watcher.deinit();

    const timeout_ms_u64 = std.math.mul(u64, timeout_seconds, std.time.ms_per_s) catch std.math.maxInt(u64);
    return watcher.waitForInput(timeout_ms_u64);
}

pub fn getCurrentTtyPath(buf: *[std.fs.max_path_bytes]u8) ![:0]const u8 {
    var tty_file = try openCurrentTty(.read_only);
    defer tty_file.close();

    const rc = ttyname_r(tty_file.handle, @ptrCast(buf), buf.len);
    if (rc != 0) return std.posix.unexpectedErrno(@enumFromInt(rc));

    const tty_path = std.mem.sliceTo(buf, 0);
    return buf[0..tty_path.len :0];
}

pub fn getInheritedTtyPath(buf: *[std.fs.max_path_bytes]u8) ![:0]const u8 {
    const inherited_fds = [_]std.posix.fd_t{
        std.posix.STDIN_FILENO,
        std.posix.STDOUT_FILENO,
        std.posix.STDERR_FILENO,
    };

    for (inherited_fds) |fd| {
        const rc = ttyname_r(fd, @ptrCast(buf), buf.len);
        if (rc != 0) continue;

        const tty_path = std.mem.sliceTo(buf, 0);
        if (std.mem.eql(u8, tty_path, "/dev/tty")) continue;
        return buf[0..tty_path.len :0];
    }

    return error.NoInheritedTty;
}

pub fn getTtyPath(buf: *[std.fs.max_path_bytes]u8, target_vt: u8) ![:0]const u8 {
    if (target_vt == 0) return error.InvalidTty;

    return switch (builtin.os.tag) {
        .linux => std.fmt.bufPrintZ(buf, "/dev/tty{d}", .{target_vt}),
        .freebsd => std.fmt.bufPrintZ(buf, "/dev/ttyv{x}", .{target_vt - 1}),
        else => error.UnsupportedPlatform,
    };
}

fn activateTty(tty: u8) !void {
    var console = try openConsoleFile();
    defer console.close();

    if (comptime builtin.os.tag == .linux) {
        var setactivate = std.mem.zeroes(c.struct_vt_setactivate);
        setactivate.console = tty;
        setactivate.mode.mode = c.VT_AUTO;
        const status = c.ioctl(console.handle, c.VT_SETACTIVATE, &setactivate);
        if (status != 0) return error.FailedToActivateTty;
    } else {
        var mode = std.mem.zeroes(c.struct_vt_mode);
        mode.mode = c.VT_AUTO;
        const mode_status = c.ioctl(console.handle, c.VT_SETMODE, &mode);
        if (mode_status != 0) return error.FailedToSetTtyMode;

        const status = c.ioctl(console.handle, c.VT_ACTIVATE, @as(c_int, tty));
        if (status != 0) return error.FailedToActivateTty;
    }

    const wait_status = c.ioctl(console.handle, c.VT_WAITACTIVE, @as(c_int, tty));
    if (wait_status != 0) return error.FailedToWaitForActiveTty;
}

fn openConsoleFile() !std.fs.File {
    return std.fs.openFileAbsolute("/dev/tty0", .{ .mode = .read_write }) catch
        std.fs.openFileAbsolute("/dev/console", .{ .mode = .read_write });
}

fn setTextMode(fd: std.posix.fd_t) !void {
    if (comptime builtin.os.tag != .linux) return;
    const status = c.ioctl(fd, c.KDSETMODE, @as(c_int, c.KD_TEXT));
    if (status != 0) return error.FailedToSetTextMode;
}

fn controllingTtyIsCurrentSession(fd: std.posix.fd_t) bool {
    var tty_sid: std.posix.pid_t = undefined;
    if (c.ioctl(fd, c.TIOCGSID, &tty_sid) != 0) return false;

    const current_sid = getsid(0);
    return current_sid >= 0 and current_sid == tty_sid;
}

fn becomeSessionLeader() !void {
    _ = std.posix.setsid() catch |err| switch (err) {
        error.PermissionDenied => {},
        else => return err,
    };
}

fn attachControllingTty(fd: std.posix.fd_t) !void {
    if (controllingTtyIsCurrentSession(fd)) return;

    const status = c.ioctl(fd, c.TIOCSCTTY, @as(c_int, 0));
    if (status != 0 and !controllingTtyIsCurrentSession(fd)) {
        return error.FailedToSetControllingTty;
    }
}

fn openCurrentTty(mode: std.fs.File.OpenMode) !std.fs.File {
    return std.fs.openFileAbsolute("/dev/tty", .{ .mode = mode });
}

fn openAndActivateTty(tty: u8) !std.fs.File {
    if (tty == 0) return error.InvalidTty;
    try activateTty(tty);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tty_path = try getTtyPath(&path_buf, tty);
    return std.fs.openFileAbsolute(tty_path, .{ .mode = .read_write });
}

fn resolveTargetTtyPath(buf: *[std.fs.max_path_bytes]u8, target_vt: ?u8) ![:0]const u8 {
    if (target_vt) |vt_num| {
        return getTtyPath(buf, vt_num);
    }

    if (getInheritedTtyPath(buf)) |tty_path| {
        return tty_path;
    } else |_| {}

    const tty_path = try getCurrentTtyPath(buf);
    if (std.mem.eql(u8, tty_path, "/dev/tty")) {
        return error.InvalidTtyPath;
    }
    return tty_path;
}
