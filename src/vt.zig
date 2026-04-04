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

pub const Vt = union(enum) {
    unmanaged,
    current,
    number: u8,

    pub fn parse(raw: ?[]const u8) !Vt {
        const trimmed = std.mem.trim(u8, raw orelse "", " \t\r\n");
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "current")) return .current;
        if (std.mem.eql(u8, trimmed, "unmanaged")) return .unmanaged;

        const number = try std.fmt.parseInt(u8, trimmed, 10);
        if (number == 0) return error.InvalidTty;
        return .{ .number = number };
    }

    pub fn ttyNumber(self: Vt) ?u8 {
        return switch (self) {
            .number => |vt_num| vt_num,
            .unmanaged, .current => null,
        };
    }

    pub fn activate(self: Vt) !void {
        switch (self) {
            .unmanaged, .current => {},
            .number => |vt_num| {
                var console = try openConsoleFile();
                defer console.close();

                if (comptime builtin.os.tag == .linux) {
                    var setactivate = std.mem.zeroes(c.struct_vt_setactivate);
                    setactivate.console = vt_num;
                    setactivate.mode.mode = c.VT_AUTO;
                    const status = c.ioctl(console.handle, c.VT_SETACTIVATE, &setactivate);
                    if (status != 0) return error.FailedToActivateTty;
                } else {
                    var mode = std.mem.zeroes(c.struct_vt_mode);
                    mode.mode = c.VT_AUTO;
                    const mode_status = c.ioctl(console.handle, c.VT_SETMODE, &mode);
                    if (mode_status != 0) return error.FailedToSetTtyMode;

                    const status = c.ioctl(console.handle, c.VT_ACTIVATE, @as(c_int, vt_num));
                    if (status != 0) return error.FailedToActivateTty;
                }

                const wait_status = c.ioctl(console.handle, c.VT_WAITACTIVE, @as(c_int, vt_num));
                if (wait_status != 0) return error.FailedToWaitForActiveTty;
            }
        }
    }

    pub fn open(self: Vt, mode: std.fs.File.OpenMode) !std.fs.File {
        return switch (self) {
            .unmanaged, .current => openControllingTty(mode),
            .number => self.openDevice(mode),
        };
    }

    pub fn openDevice(self: Vt, mode: std.fs.File.OpenMode) !std.fs.File {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tty_path = (try self.resolveTtyDevicePath(&path_buf)) orelse return error.InvalidTtyPath;
        return try std.fs.openFileAbsolute(tty_path, .{ .mode = mode });
    }

    pub fn resolveTtyDevicePath(self: Vt, buf: *[std.fs.max_path_bytes]u8) !?[:0]const u8 {
        switch (self) {
            .number => |vt_num| {
                if (getTtyDevicePath(buf, vt_num)) |tty_path| {
                    return tty_path;
                } else |err| {
                    log.warn("Failed to resolve configured tty device path: {s}", .{@errorName(err)});
                }
            },
            .unmanaged, .current => {},
        }

        if (getInheritedTtyDevicePath(buf)) |tty_path| {
            return tty_path;
        } else |err| {
            log.warn("Failed to resolve inherited tty device path: {s}", .{@errorName(err)});
        }

        return error.InvalidTtyPath;
    }

    pub fn normalize(self: Vt) !void {
        switch (self) {
            .number => {
                try self.activate();
                try self.setTextMode();
                self.resetTermios();
            },
            .current => {
                try self.setTextMode();
                self.resetTermios();
            },
            .unmanaged => self.resetTermios(),
        }
    }

    pub fn establishSessionControllingTty(self: Vt, fd: std.posix.fd_t) !void {
        if (self == .unmanaged) return;

        try becomeSessionLeader();
        try attachControllingTty(fd);
    }

    pub fn watchInput(self: Vt) !InputWatcher {
        return InputWatcher.init(self);
    }

    fn setTextMode(self: Vt) !void {
        var tty_file = try self.open(.read_write);
        defer if (tty_file.handle > 2) tty_file.close();

        if (comptime builtin.os.tag != .linux) return;
        const status = c.ioctl(tty_file.handle, c.KDSETMODE, @as(c_int, c.KD_TEXT));
        if (status != 0) return error.FailedToSetTextMode;
    }

    fn resetTermios(self: Vt) void {
        var tty_file = self.open(.read_write) catch {
            return;
        };
        defer if (tty_file.handle > 2) tty_file.close();

        var termios = std.posix.tcgetattr(tty_file.handle) catch {
            return;
        };
        termios.lflag.ISIG = true;
        termios.lflag.ICANON = true;
        termios.lflag.ECHO = true;
        termios.lflag.ECHONL = true;
        std.posix.tcsetattr(tty_file.handle, .FLUSH, termios) catch {};
    }
    
    pub const InputWatcher = struct {
        file: std.fs.File,
        original: std.posix.termios,

        pub fn init(target_vt: Vt) !InputWatcher {
            var tty_file = try target_vt.open(.read_write);
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

        pub fn deinit(self: *InputWatcher) void {
            std.posix.tcsetattr(self.file.handle, .FLUSH, self.original) catch {};
            self.file.close();
        }

        pub fn waitForInput(self: *InputWatcher, timeout_ms: u64) !bool {
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
};

pub fn getInheritedTtyDevicePath(buf: *[std.fs.max_path_bytes]u8) ![:0]const u8 {
    const inherited_fds = [_]std.posix.fd_t{
        std.posix.STDIN_FILENO,
        std.posix.STDOUT_FILENO,
        std.posix.STDERR_FILENO,
    };

    for (inherited_fds) |fd| {
        const tty_path = ttyPathFromFd(fd, buf) catch continue;
        if (std.mem.eql(u8, tty_path, "/dev/tty")) continue;
        return buf[0..tty_path.len :0];
    }

    return error.NoInheritedTty;
}

pub fn getTtyDevicePath(buf: *[std.fs.max_path_bytes]u8, target_vt: u8) ![:0]const u8 {
    if (target_vt == 0) return error.InvalidTty;

    return switch (builtin.os.tag) {
        .linux => std.fmt.bufPrintZ(buf, "/dev/tty{d}", .{target_vt}),
        .freebsd => std.fmt.bufPrintZ(buf, "/dev/ttyv{x}", .{target_vt - 1}),
        else => error.UnsupportedPlatform,
    };
}

fn ttyPathFromFd(fd: std.posix.fd_t, buf: *[std.fs.max_path_bytes]u8) ![:0]const u8 {
    const rc = ttyname_r(fd, @ptrCast(buf), buf.len);
    if (rc != 0) return std.posix.unexpectedErrno(@enumFromInt(rc));

    const tty_path = std.mem.sliceTo(buf, 0);
    return buf[0..tty_path.len :0];
}

fn openConsoleFile() !std.fs.File {
    return std.fs.openFileAbsolute("/dev/tty0", .{ .mode = .read_write }) catch
        std.fs.openFileAbsolute("/dev/console", .{ .mode = .read_write });
}

fn openControllingTty(mode: std.fs.File.OpenMode) !std.fs.File {
    return std.fs.openFileAbsolute("/dev/tty", .{ .mode = mode });
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
