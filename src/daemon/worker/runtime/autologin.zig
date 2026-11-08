const std = @import("std");
const ipc = @import("ipc");
const session_mod = @import("session.zig");
const Pam = @import("pam").Pam;
const Vt = @import("vt").Vt;
const Shutdown = @import("../../Shutdown.zig");

pub const RunOpts = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    shutdown_conn: *Shutdown.Connection,
    env_map: *const std.process.Environ.Map,
    service_name: [:0]const u8,
    user: [:0]const u8,
    info: ipc.SessionInfo,
    vt: Vt,
    x11: session_mod.X11Options,
};

pub fn run(opts: RunOpts) !void {
    var pam = try Pam(void).init(opts.allocator, .{
        .service_name = opts.service_name,
        .user = opts.user,
        .state = .discardAll(),
    });
    defer pam.deinit();

    const session_vt = session_mod.resolveSessionVt(opts.info.session_type, opts.x11, opts.vt);

    var tty_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tty_path = try session_vt.resolveTtyDevicePath(opts.io, &tty_path_buf);
    try pam.setItem(.tty, tty_path);
    try pam.accountMgmt(.{});
    try pam.setCred(.{ .action = .establish });

    var session = blk: {
        const tty_file = try session_vt.openSessionTty(opts.io);
        errdefer if (tty_file.handle > 2) tty_file.close(opts.io);

        var session_envmap = std.process.Environ.Map.init(opts.allocator);
        defer session_envmap.deinit();
        if (opts.info.session_type == .x11) {
            try session_envmap.put("XDG_SESSION_TYPE", "x11");
        }
        break :blk try session_mod.start(void, opts.allocator, &pam, .{
            .io = opts.io,
            .shutdown_conn = opts.shutdown_conn,
            .host_env_map = opts.env_map,
            .info = opts.info,
            .session_envmap = &session_envmap,
            .vt = session_vt,
            .tty_file = tty_file,
            .x11 = opts.x11,
        });
    };
    defer session.deinit(opts.io);

    try session.wait();
}
