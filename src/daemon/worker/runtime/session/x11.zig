const std = @import("std");
const posix = @import("posix");
const utils = @import("../user.zig");
const UserInfo = utils.UserInfo;
const Vt = @import("vt").Vt;
const tty = @import("../tty.zig");

pub const xauth = @import("xauth.zig");

const log = std.log.scoped(.zgsld_worker);

const XServerOpts = struct {
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    x_cmd: []const u8,
    xauth_path: [:0]const u8,
    display: u8,
    vt: Vt,
    user: ?UserInfo,
    environ: [:null]const ?[*:0]const u8,
};

pub fn startXServer(allocator: std.mem.Allocator, opts: XServerOpts) !std.posix.pid_t {
    var display_buf: [16]u8 = undefined;
    const display_name = try std.fmt.bufPrint(&display_buf, ":{d}", .{opts.display});

    var vt_suffix_buf: [8]u8 = undefined;
    const vt_suffix: []const u8 = if (opts.vt.ttyNumber(opts.io, opts.env_map)) |vt_num|
        try std.fmt.bufPrint(&vt_suffix_buf, " vt{d}", .{vt_num})
    else
        "";

    const shell_cmd_z = try std.fmt.allocPrintSentinel(allocator, "exec {s} -auth {s} {s}{s}", .{
        opts.x_cmd,
        opts.xauth_path,
        display_name,
        vt_suffix,
    }, 0);
    defer allocator.free(shell_cmd_z);

    const argv = [_:null]?[*:0]const u8{
        "/bin/sh",
        "-c",
        shell_cmd_z.ptr,
        null,
    };

    const pid = blk: {
        const child_pid = std.c.fork();
        if (child_pid < 0) return std.posix.unexpectedErrno(std.c.errno(child_pid));
        break :blk child_pid;
    };
    if (pid == 0) {
        {
            var tty_file = opts.vt.openDevice(opts.io, opts.env_map, .read_write) catch |err| {
                log.err("Failed to open X server tty device: {s}", .{@errorName(err)});
                std.process.exit(1);
            };
            defer if (tty_file.handle > 2) tty_file.close(opts.io);

            tty.redirectStdinToTty(tty_file.handle) catch |err| {
                log.err("Failed to redirect X server stdin to tty: {s}", .{@errorName(err)});
                std.process.exit(1);
            };
        }

        if (opts.user) |u| {
            utils.dropPrivileges(u) catch std.process.exit(1);
        }

        _ = std.c.execve("/bin/sh", &argv, opts.environ.ptr);
        std.process.exit(1);
    }

    return pid;
}

pub fn findFreeDisplay(io: std.Io) !u8 {
    var display: u8 = 0;
    while (display < 200) : (display += 1) {
        var lock_buf: [15]u8 = undefined;
        const lock_path = try std.fmt.bufPrint(&lock_buf, "/tmp/.X{d}-lock", .{display});
        std.Io.Dir.accessAbsolute(io, lock_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break,
            error.AccessDenied, error.PermissionDenied => {},
            else => return err,
        };
    }

    if (display >= 200) return error.NoAvailableDisplay;
    return display;
}

// When X server detaches, we can get the PID from the lock file
pub fn readXServerPid(io: std.Io, display: u8) ?std.posix.pid_t {
    var lock_buf: [15]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_buf, "/tmp/.X{d}-lock", .{display}) catch return null;
    const lock_file = std.Io.Dir.openFileAbsolute(io, lock_path, .{ .mode = .read_only }) catch return null;
    defer lock_file.close(io);

    var rbuf: [32]u8 = undefined;
    var reader = lock_file.reader(io, &rbuf);

    var buf: [32]u8 = undefined;
    const n = reader.interface.readSliceShort(&buf) catch return null;
    if (n == 0) return null;
    const pid_str = std.mem.trim(u8, buf[0..n], " \r\n\t");
    if (pid_str.len == 0) return null;
    return std.fmt.parseInt(std.posix.pid_t, pid_str, 10) catch return null;
}

fn isXServerListening(io: std.Io, display: u8) bool {
    var path_buf: [64]u8 = undefined;
    const socket_path = std.fmt.bufPrint(&path_buf, "/tmp/.X11-unix/X{d}", .{display}) catch return false;
    const address = std.Io.net.UnixAddress.init(socket_path) catch return false;
    const stream = address.connect(io) catch return false;
    defer stream.close(io);
    return true;
}

pub fn waitForXServer(
    io: std.Io,
    display: u8,
    launcher_pid: std.posix.pid_t,
    timeout_ms: u32,
) !std.posix.pid_t {
    var elapsed: u32 = 0;
    var launcher_exited = false;
    while (elapsed < timeout_ms) : (elapsed += 50) {
        // The lock PID can appear before the socket is actually ready.
        if (readXServerPid(io, display)) |pid| {
            if (isXServerListening(io, display)) return pid;
        }

        if (!launcher_exited) {
            // The launcher may exit early if the X server daemonizes.
            const wait_res = try posix.waitpid(launcher_pid, std.posix.W.NOHANG);
            if (wait_res.pid == launcher_pid) {
                launcher_exited = true;
            }
        }

        try io.sleep(.fromMilliseconds(50), .awake);
    }
    // If the launcher exited, treat this as an X server failure instead of a timeout.
    return if (launcher_exited) error.XServerExited else error.XServerTimeout;
}
