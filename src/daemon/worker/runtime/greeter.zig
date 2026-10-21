const std = @import("std");
const ipc = @import("ipc");
const env_mod = @import("env.zig");
const Pam = @import("pam").Pam;
const UserInfo = @import("user.zig").UserInfo;
const session_mod = @import("session.zig");
const signals = @import("signals.zig");
const Vt = @import("vt").Vt;

const Session = session_mod.Session;

pub const RunOpts = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    username: [:0]const u8,
    service_name: []const u8,
    ipc_fd: std.posix.fd_t,
    command: []const u8,
    session_type: ipc.SessionType,
    vt: Vt,
};

pub fn run(opts: RunOpts) !void {
    const pw = std.c.getpwnam(opts.username) orelse return error.GreeterUserNotFound;
    var pam = try Pam(void).init(opts.allocator, .{
        .user = opts.username,
        .service_name = opts.service_name,
        .state = .discardAll(),
    });
    defer pam.deinit();

    const user_info: UserInfo = .{
        .username = opts.username,
        .uid = pw.uid,
        .gid = pw.gid,
    };

    var session = blk: {
        defer _ = std.c.close(opts.ipc_fd);

        const session_vt = try session_mod.resolveSessionVt(opts.session_type, opts.env_map, opts.vt);
        var tty_file = try session_vt.openSessionTty(opts.io, opts.env_map);
        defer if (tty_file.handle > 2) tty_file.close(opts.io);

        var tty_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tty_path = try session_vt.resolveTtyDevicePath(opts.io, opts.env_map, &tty_path_buf);
        try pam.setItem(.{ .tty = tty_path });

        try env_mod.openPamSession(void, &pam, opts.io, opts.env_map, session_vt, .greeter);
        var envmap = try pam.createEnvListMap();
        defer envmap.deinit();

        var fd_buf: [16]u8 = undefined;
        const zgsld_sock = try std.fmt.bufPrint(&fd_buf, "{d}", .{opts.ipc_fd});
        try envmap.put("ZGSLD_SOCK", zgsld_sock);

        try env_mod.applyTermEnv(&envmap, opts.env_map);

        const session_info: ipc.SessionInfo = .{
            .session_type = opts.session_type,
            .command = .{
                .session_cmd = opts.command,
                .source_profile = false,
            },
        };

        break :blk try Session.spawn(opts.allocator, .{
            .io = opts.io,
            .host_env_map = opts.env_map,
            .session_info = session_info,
            .envmap = &envmap,
            .user_info = user_info,
            .vt = session_vt,
            .stderr = .inherit,
        });
    };
    defer session.deinit(opts.io);

    try signals.waitForChild(opts.io, &session.child);
}
