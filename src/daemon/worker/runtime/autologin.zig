const std = @import("std");
const ipc = @import("ipc");
const session_mod = @import("session.zig");
const signals = @import("signals.zig");
const Pam = @import("pam").Pam;
const Vt = @import("vt").Vt;

pub const RunOpts = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    service_name: []const u8,
    user: [:0]const u8,
    info: ipc.SessionInfo,
    vt: Vt,
};

pub fn run(opts: RunOpts) !void {
    var pam = try Pam(void).init(opts.allocator, .{
        .service_name = opts.service_name,
        .user = opts.user,
        .state = .discardAll(),
    });
    defer pam.deinit();

    const session_vt = try session_mod.resolveSessionVt(opts.info.session_type, opts.env_map, opts.vt);

    var tty_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tty_path = try session_vt.resolveTtyDevicePath(opts.io, opts.env_map, &tty_path_buf);
    try pam.setItem(.{ .tty = tty_path });
    try pam.accountMgmt(.{});
    try pam.setCred(.{ .action = .establish });

    var session_envmap = std.process.Environ.Map.init(opts.allocator);
    defer session_envmap.deinit();
    if (opts.info.session_type == .x11) {
        try session_envmap.put("XDG_SESSION_TYPE", "x11");
    }
    var tty_file = try session_vt.openSessionTty(opts.io, opts.env_map);
    defer if (tty_file.handle > 2) tty_file.close(opts.io);

    var session = try session_mod.start(void, opts.allocator, opts.io, opts.env_map, opts.user, opts.info, &pam, &session_envmap, session_vt);
    defer session.deinit(opts.io);

    try signals.waitForChild(opts.io, &session.child);
}
