const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");

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

    pub fn ttyNumber(self: Vt, io: std.Io, env_map: *const std.process.Environ.Map) ?u8 {
        return switch (self) {
            .number => |vt_num| vt_num,
            .current => queryCurrentTtyNumber(io) catch blk: {
                var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                const tty_path = getInheritedTtyDevicePath(&path_buf) catch break :blk null;
                break :blk parseTtyNumberFromPath(tty_path) catch null;
            },
            .unmanaged => blk: {
                const raw = env_map.get("XDG_VTNR") orelse break :blk null;
                break :blk std.fmt.parseInt(u8, raw, 10) catch null;
            },
        };
    }

    pub fn activate(self: Vt, io: std.Io) !void {
        const vt_num = switch (self) {
            .number => |vt_num| vt_num,
            .unmanaged, .current => return,
        };

        var console = try openVtControlDevice(io);
        defer console.close(io);

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

    pub fn open(self: Vt, io: std.Io, env_map: *const std.process.Environ.Map, mode: std.Io.File.OpenMode) !std.Io.File {
        return switch (self) {
            .unmanaged, .current => openControllingTty(io, mode),
            .number => self.openDevice(io, env_map, mode),
        };
    }

    pub fn openDevice(self: Vt, io: std.Io, env_map: *const std.process.Environ.Map, mode: std.Io.File.OpenMode) !std.Io.File {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tty_path = (try self.resolveTtyDevicePath(io, env_map, &path_buf)) orelse return error.InvalidTtyPath;
        return try std.Io.Dir.openFileAbsolute(io, tty_path, .{ .mode = mode });
    }

    pub fn resolveTtyDevicePath(
        self: Vt,
        io: std.Io,
        env_map: *const std.process.Environ.Map,
        buf: *[std.fs.max_path_bytes]u8,
    ) !?[:0]const u8 {
        switch (self) {
            .number => |vt_num| {
                if (getTtyDevicePath(buf, vt_num)) |tty_path| {
                    return tty_path;
                } else |err| {
                    log.warn("Failed to resolve configured tty device path: {s}", .{@errorName(err)});
                }
            },
            .current => {
                if (queryCurrentTtyNumber(io)) |vt_num| {
                    if (getTtyDevicePath(buf, vt_num)) |tty_path| {
                        return tty_path;
                    } else |err| {
                        log.warn("Failed to resolve current tty device path: {s}", .{@errorName(err)});
                    }
                } else |err| {
                    log.warn("Failed to resolve current tty number: {s}", .{@errorName(err)});
                }
            },
            .unmanaged => if (self.ttyNumber(io, env_map)) |vt_num| {
                if (getTtyDevicePath(buf, vt_num)) |tty_path| {
                    return tty_path;
                } else |err| {
                    log.warn("Failed to resolve unmanaged tty device path: {s}", .{@errorName(err)});
                }
            },
        }

        if (getInheritedTtyDevicePath(buf)) |tty_path| {
            return tty_path;
        } else |err| {
            log.warn("Failed to resolve inherited tty device path: {s}", .{@errorName(err)});
        }

        return error.InvalidTtyPath;
    }

    pub fn normalize(self: Vt, io: std.Io, env_map: *const std.process.Environ.Map) !void {
        switch (self) {
            .number => {
                try self.activate(io);
                try self.setTextMode(io, env_map);
                self.resetTermios(io, env_map);
            },
            .current => {
                try self.setTextMode(io, env_map);
                self.resetTermios(io, env_map);
            },
            .unmanaged => {
                self.resetTermios(io, env_map);
            },
        }
    }

    pub fn establishSessionControllingTty(self: Vt, fd: std.posix.fd_t) !void {
        _ = self;

        if (controllingTtyIsCurrentSession(fd)) return;
        try becomeSessionLeader();
        try attachControllingTty(fd);
    }

    pub fn watchInput(self: Vt, io: std.Io, env_map: *const std.process.Environ.Map) !InputWatcher {
        return InputWatcher.init(self, io, env_map);
    }

    fn setTextMode(self: Vt, io: std.Io, env_map: *const std.process.Environ.Map) !void {
        if (comptime builtin.os.tag != .linux) return;

        var tty_file = try self.open(io, env_map, .read_write);
        defer if (tty_file.handle > 2) tty_file.close(io);

        const status = c.ioctl(tty_file.handle, c.KDSETMODE, @as(c_int, c.KD_TEXT));
        if (status != 0) return error.FailedToSetTextMode;
    }

    fn resetTermios(self: Vt, io: std.Io, env_map: *const std.process.Environ.Map) void {
        var tty_file = self.open(io, env_map, .read_write) catch {
            return;
        };
        defer if (tty_file.handle > 2) tty_file.close(io);

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
        file: std.Io.File,
        original: std.posix.termios,

        pub fn init(target_vt: Vt, io: std.Io, env_map: *const std.process.Environ.Map) !InputWatcher {
            var tty_file = try target_vt.open(io, env_map, .read_write);
            errdefer tty_file.close(io);

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

        pub fn deinit(self: *InputWatcher, io: std.Io) void {
            std.posix.tcsetattr(self.file.handle, .FLUSH, self.original) catch {};
            self.file.close(io);
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

fn getInheritedTtyDevicePath(buf: *[std.fs.max_path_bytes]u8) ![:0]const u8 {
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

fn getTtyDevicePath(buf: *[std.fs.max_path_bytes]u8, target_vt: u8) ![:0]const u8 {
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

fn queryCurrentTtyNumber(io: std.Io) !u8 {
    return switch (builtin.os.tag) {
        .linux => linux.queryCurrentTtyNumber(io),
        .freebsd => freebsd.queryCurrentTtyNumber(io),
        else => error.UnsupportedPlatform,
    };
}

fn parseTtyNumberFromPath(tty_path: []const u8) !u8 {
    return switch (builtin.os.tag) {
        .linux => linux.parseTtyNumberFromPath(tty_path),
        .freebsd => freebsd.parseTtyNumberFromPath(tty_path),
        else => error.UnsupportedPlatform,
    };
}

const linux = struct {
    fn queryCurrentTtyNumber(io: std.Io) !u8 {
        var tty_file = try openControllingTty(io, .read_only);
        defer if (tty_file.handle > 2) tty_file.close(io);

        var state = std.mem.zeroes(c.struct_vt_stat);
        const status = c.ioctl(tty_file.handle, c.VT_GETSTATE, &state);
        if (status != 0) return error.FailedToGetTtyState;

        return std.math.cast(u8, state.v_active) orelse error.InvalidTty;
    }

    fn parseTtyNumberFromPath(tty_path: []const u8) !u8 {
        const prefix = "/dev/tty";
        if (!std.mem.startsWith(u8, tty_path, prefix)) return error.InvalidTtyPath;

        const suffix = tty_path[prefix.len..];
        if (suffix.len == 0) return error.InvalidTtyPath;

        const tty_number = try std.fmt.parseInt(u8, suffix, 10);
        if (tty_number == 0) return error.InvalidTty;
        return tty_number;
    }
};

const freebsd = struct {
    fn queryCurrentTtyNumber(io: std.Io) !u8 {
        var tty_file = try openControllingTty(io, .read_only);
        defer if (tty_file.handle > 2) tty_file.close(io);

        var tty_index: c_int = 0;
        const status = c.ioctl(tty_file.handle, c.VT_GETINDEX, &tty_index);
        if (status != 0) return error.FailedToGetTtyIndex;

        const index = std.math.cast(u8, tty_index) orelse return error.InvalidTty;
        return std.math.add(u8, index, 1) catch error.InvalidTty;
    }

    fn parseTtyNumberFromPath(tty_path: []const u8) !u8 {
        const prefix = "/dev/ttyv";
        if (!std.mem.startsWith(u8, tty_path, prefix)) return error.InvalidTtyPath;

        const suffix = tty_path[prefix.len..];
        if (suffix.len == 0) return error.InvalidTtyPath;

        const tty_index = try std.fmt.parseInt(u8, suffix, 16);
        return std.math.add(u8, tty_index, 1) catch error.InvalidTty;
    }
};

fn openVtControlDevice(io: std.Io) !std.Io.File {
    return switch (builtin.os.tag) {
        .linux => std.Io.Dir.openFileAbsolute(io, "/dev/tty0", .{ .mode = .read_write }),
        .freebsd => std.Io.Dir.openFileAbsolute(io, "/dev/console", .{ .mode = .read_write }),
        else => error.UnsupportedPlatform,
    };
}

fn openControllingTty(io: std.Io, mode: std.Io.File.OpenMode) !std.Io.File {
    return std.Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = mode });
}

fn controllingTtyIsCurrentSession(fd: std.posix.fd_t) bool {
    var tty_sid: std.posix.pid_t = undefined;
    if (c.ioctl(fd, c.TIOCGSID, &tty_sid) != 0) return false;

    const current_sid = getsid(0);
    return current_sid >= 0 and current_sid == tty_sid;
}

fn becomeSessionLeader() !void {
    switch (std.c.errno(std.c.setsid())) {
        .SUCCESS => {},
        .PERM => {},
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

fn attachControllingTty(fd: std.posix.fd_t) !void {
    if (controllingTtyIsCurrentSession(fd)) return;

    const status = c.ioctl(fd, c.TIOCSCTTY, @as(c_int, 0));
    if (status != 0 and !controllingTtyIsCurrentSession(fd)) {
        return error.FailedToSetControllingTty;
    }
}
