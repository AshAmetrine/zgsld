const std = @import("std");
const ipc = @import("ipc");
const env_mod = @import("env.zig");
const Pam = @import("pam").Pam;
const session_mod = @import("session.zig");
const Vt = @import("vt").Vt;
const Shutdown = @import("../../Shutdown.zig");

const Session = session_mod.Session;

pub const RunOpts = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    shutdown_conn: *Shutdown.Connection,
    env_map: *const std.process.Environ.Map,
    username: [:0]const u8,
    service_name: [:0]const u8,
    ipc_fd: std.posix.fd_t,
    command: []const u8,
    session_type: ipc.SessionType,
    vt: Vt,
    x11: session_mod.X11Options,
};

pub fn run(opts: RunOpts) !void {
    var pam = try Pam(void).init(opts.allocator, .{
        .user = opts.username,
        .service_name = opts.service_name,
        .state = .discardAll(),
    });
    defer pam.deinit();

    var session = blk: {
        defer _ = std.c.close(opts.ipc_fd);

        const session_vt = session_mod.resolveSessionVt(opts.session_type, opts.x11, opts.vt);
        var tty_file = try session_vt.openSessionTty(opts.io);
        errdefer if (tty_file.handle > 2) tty_file.close(opts.io);

        var tty_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tty_path = try session_vt.resolveTtyDevicePath(opts.io, &tty_path_buf);
        try pam.setItem(.tty, tty_path);

        try env_mod.preparePamSessionEnv(void, &pam, opts.io, opts.env_map, session_vt, .greeter);
        try pam.openSession(.{});
        var envmap = try pam.createEnvListMap();
        defer envmap.deinit();
        const user_info = try env_mod.applyUserEnv(void, &pam, &envmap);

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
            .shutdown_conn = opts.shutdown_conn,
            .x11 = opts.x11,
            .session_info = session_info,
            .envmap = &envmap,
            .user_info = user_info,
            .vt = session_vt,
            .tty_file = tty_file,
            .stderr = .inherit,
        });
    };
    defer session.deinit(opts.io);

    try session.wait();
}
