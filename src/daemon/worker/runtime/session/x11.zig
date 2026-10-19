const std = @import("std");
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

pub fn startXServer(allocator: std.mem.Allocator, opts: XServerOpts) !std.process.Child {
    var display_buf: [5]u8 = undefined;
    const display = try std.fmt.bufPrintSentinel(&display_buf, ":{d}", .{opts.display}, 0);

    var vt_buf: [6]u8 = undefined;
    const vt: ?[:0]const u8 = if (opts.vt.ttyNumber(opts.io, opts.env_map)) |vt_num|
        try std.fmt.bufPrintSentinel(&vt_buf, "vt{d}", .{vt_num}, 0)
    else
        null;

    const shell_cmd_z = try std.fmt.allocPrintSentinel(allocator, "exec {s} \"$@\"", .{opts.x_cmd}, 0);
    defer allocator.free(shell_cmd_z);

    const argv = [_:null]?[*:0]const u8{
        "/bin/sh",
        "-c",
        shell_cmd_z.ptr,
        "zgsld-x11",
        "-auth",
        opts.xauth_path.ptr,
        display.ptr,
        if (vt) |arg| arg.ptr else null,
    };

    const pid = std.c.fork();
    if (pid < 0) return std.posix.unexpectedErrno(std.c.errno(pid));
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

    var server: std.process.Child = .{
        .id = pid,
        .thread_handle = {},
        .stdin = null,
        .stdout = null,
        .stderr = null,
        .request_resource_usage_statistics = false,
    };
    errdefer server.kill(opts.io);

    try waitForXServer(opts.io, opts.display, &server, 5000);
    return server;
}

pub fn findFreeDisplay(io: std.Io) !u8 {
    for (0..200) |display| {
        var lock_buf: [15]u8 = undefined;
        const lock_path = try std.fmt.bufPrint(&lock_buf, "/tmp/.X{d}-lock", .{display});
        std.Io.Dir.accessAbsolute(io, lock_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return @intCast(display),
            error.AccessDenied, error.PermissionDenied => {},
            else => return err,
        };
    }

    return error.NoAvailableDisplay;
}

fn isXServerListening(io: std.Io, address: std.Io.net.UnixAddress) bool {
    const stream = address.connect(io) catch return false;
    defer stream.close(io);
    return true;
}

fn waitForXServer(
    io: std.Io,
    display: u8,
    server: *std.process.Child,
    timeout_ms: u32,
) !void {
    var path_buf: [64]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&path_buf, "/tmp/.X11-unix/X{d}", .{display});
    const address = try std.Io.net.UnixAddress.init(socket_path);

    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromMilliseconds(timeout_ms));
    while (std.Io.Clock.awake.now(io).compare(.lt, deadline)) {
        const pid = server.id orelse return error.XServerExited;
        if (hasExited(pid)) {
            server.id = null;
            return error.XServerExited;
        }

        if (isXServerListening(io, address)) return;

        const next_poll = std.Io.Clock.awake.now(io).addDuration(.fromMilliseconds(50));
        const wake_at = if (next_poll.compare(.lt, deadline)) next_poll else deadline;
        try wake_at.withClock(.awake).wait(io);
    }
    return error.XServerTimeout;
}

fn hasExited(pid: std.posix.pid_t) bool {
    while (true) {
        const rc = std.c.waitpid(pid, null, std.posix.W.NOHANG);
        switch (std.c.errno(rc)) {
            .SUCCESS => return rc == pid,
            .INTR => continue,
            .CHILD => unreachable,
            .INVAL => unreachable,
            else => unreachable,
        }
    }
}
