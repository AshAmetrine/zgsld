const std = @import("std");
const Ipc = @import("Ipc");
const posix = @import("posix");
const env_mod = @import("env.zig");
const session_mod = @import("session.zig");
const signals = @import("signals.zig");
const pam_mod = @import("pam");
const Vt = @import("vt").Vt;

const Pam = pam_mod.Pam;

pub const RunOpts = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    service_name: []const u8,
    user: [:0]const u8,
    info: Ipc.SessionInfo,
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
    if (try session_vt.resolveTtyDevicePath(opts.io, opts.env_map, &tty_path_buf)) |tty_path| {
        try pam.setItem(.{ .tty = tty_path });
    }
    try pam.accountMgmt(.{});
    try pam.setCred(.{ .action = .establish });

    var session_envmap = std.process.Environ.Map.init(opts.allocator);
    defer session_envmap.deinit();
    if (opts.info.session_type == .x11) {
        try session_envmap.put("XDG_SESSION_TYPE", "x11");
    }
    try session_vt.activate(opts.io);

    var tty_file = try session_vt.openDevice(opts.io, opts.env_map, .read_write);
    defer if (tty_file.handle > 2) tty_file.close(opts.io);
    try session_vt.establishSessionControllingTty(tty_file.handle);

    try env_mod.applyPamUserSessionEnv(void, &pam, &session_envmap, opts.io, opts.env_map, session_vt);
    try env_mod.applyTermEnv(&session_envmap, opts.env_map);
    const user_info = try env_mod.applyUserEnv(&session_envmap, opts.user);
    var session = try session_mod.Session.spawn(opts.allocator, .{
        .io = opts.io,
        .host_env_map = opts.env_map,
        .session_info = opts.info,
        .envmap = &session_envmap,
        .user_info = user_info,
        .vt = session_vt,
    });
    defer session.deinit();

    signals.setActiveChild(session.pid);
    defer signals.clearActiveChild();

    if (signals.shutdownRequested()) {
        signals.forwardShutdownSignal(signals.shutdownSignal());
    }
    _ = try posix.waitpid(session.pid, 0);
}
