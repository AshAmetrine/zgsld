const std = @import("std");
const utils = @import("../user.zig");
const UserInfo = utils.UserInfo;

pub const xauth = @import("xauth.zig");

const XServerOpts = struct {
    x_cmd: [:0]const u8,
    xauth_path: [:0]const u8,
    display: u8,
    vt: ?u8,
    user: ?UserInfo,
    environ: [:null]const ?[*:0]const u8,
};

pub fn startXServer(allocator: std.mem.Allocator, opts: XServerOpts) !std.posix.pid_t {
    var display_buf: [16]u8 = undefined;
    const display_name = try std.fmt.bufPrint(&display_buf, ":{d}", .{opts.display});

    var vt_suffix_buf: [8]u8 = undefined;
    const vt_suffix: []const u8 = if (opts.vt) |vt_num|
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

    const pid = try std.posix.fork();
    if (pid == 0) {
        if (opts.user) |u| {
            utils.dropPrivileges(u) catch std.process.exit(1);
        }

        std.posix.execvpeZ("/bin/sh", &argv, opts.environ) catch {};
        std.process.exit(1);
    }

    return pid;
}

pub fn findFreeDisplay() !u8 {
    var display: u8 = 0;
    while (display < 200) : (display += 1) {
        var lock_buf: [15]u8 = undefined;
        const lock_path = try std.fmt.bufPrint(&lock_buf, "/tmp/.X{d}-lock", .{display});
        std.fs.accessAbsolute(lock_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break,
            error.AccessDenied, error.PermissionDenied => {},
            else => return err,
        };
    }

    if (display >= 200) return error.NoAvailableDisplay;
    return display;
}

// When X server detaches, we can get the PID from the lock file
pub fn readXServerPid(display: u8) ?std.posix.pid_t {
    var lock_buf: [15]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_buf, "/tmp/.X{d}-lock", .{display}) catch return null;
    const lock_file = std.fs.openFileAbsolute(lock_path, .{ .mode = .read_only }) catch return null;
    defer lock_file.close();

    var rbuf: [32]u8 = undefined;
    var reader = lock_file.reader(&rbuf);

    var buf: [32]u8 = undefined;
    const n = reader.interface.readSliceShort(&buf) catch return null;
    if (n == 0) return null;
    const pid_str = std.mem.trim(u8, buf[0..n], " \r\n\t");
    if (pid_str.len == 0) return null;
    return std.fmt.parseInt(std.posix.pid_t, pid_str, 10) catch return null;
}

fn isXServerListening(display: u8) bool {
    var path_buf: [64]u8 = undefined;
    const socket_path = std.fmt.bufPrint(&path_buf, "/tmp/.X11-unix/X{d}", .{display}) catch return false;
    const stream = std.net.connectUnixSocket(socket_path) catch return false;
    stream.close();
    return true;
}

pub const XServerStart = struct {
    server_pid: std.posix.pid_t,
    detached: bool,
};

pub fn waitForXServer(
    display: u8,
    launcher_pid: std.posix.pid_t,
    timeout_ms: u32,
) !XServerStart {
    var elapsed: u32 = 0;
    var launcher_exited = false;
    while (elapsed < timeout_ms) : (elapsed += 50) {
        // The lock PID can appear before the socket is actually ready.
        if (readXServerPid(display)) |pid| {
            if (isXServerListening(display)) {
                return .{
                    .server_pid = pid,
                    .detached = pid != launcher_pid,
                };
            }
        }

        if (!launcher_exited) {
            // The launcher may exit early if the X server daemonizes.
            const wait_res = std.posix.waitpid(launcher_pid, std.posix.W.NOHANG);
            if (wait_res.pid == launcher_pid) {
                launcher_exited = true;
            }
        }

        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
    // If the launcher exited, treat this as an X server failure instead of a timeout.
    return if (launcher_exited) error.XServerExited else error.XServerTimeout;
}
