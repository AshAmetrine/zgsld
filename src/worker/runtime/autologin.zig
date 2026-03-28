const std = @import("std");
const Ipc = @import("Ipc");
const tty = @import("tty.zig");
const env_mod = @import("env.zig");
const session_mod = @import("session.zig");
const signals = @import("signals.zig");
const pam_mod = @import("pam");

const Pam = pam_mod.Pam;

pub const RunOpts = struct {
    allocator: std.mem.Allocator,
    service_name: []const u8,
    user: [:0]const u8,
    info: Ipc.SessionInfo,
    vt: ?u8,
};

pub fn run(opts: RunOpts) !void {
    var pam = try Pam(void).init(opts.allocator, .{
        .service_name = opts.service_name,
        .user = opts.user,
        .state = .discardAll(),
    });
    defer pam.deinit();

    var tty_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try pam.setItem(.{ .tty = try tty.resolvePamTty(&tty_path_buf, opts.vt) });
    try pam.accountMgmt(.{});
    try pam.setCred(.{ .action = .establish });

    var session_envmap = std.process.EnvMap.init(opts.allocator);
    defer session_envmap.deinit();
    if (opts.info.session_type == .x11) {
        try session_envmap.put("XDG_SESSION_TYPE", "x11");
    }
    try env_mod.applyPamUserSessionEnv(void, &pam, &session_envmap, opts.vt);
    const user_info = try env_mod.applyUserEnv(&session_envmap, opts.user);
    var session = try session_mod.Session.spawn(opts.allocator, .{
        .session_info = opts.info,
        .envmap = &session_envmap,
        .user_info = user_info,
        .vt = opts.vt,
    });
    defer session.deinit();

    signals.setActiveChild(session.pid);
    defer signals.clearActiveChild();

    if (signals.shutdownRequested()) {
        signals.forwardShutdownSignal(signals.shutdownSignal());
    }
    _ = std.posix.waitpid(session.pid, 0);
}
