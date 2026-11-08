const std = @import("std");
const ipc = @import("ipc");
const Pam = @import("pam").Pam;
const Runtime = @import("Runtime.zig");

pub const RunOpts = struct {
    service_name: [:0]const u8,
    user: [:0]const u8,
    info: ipc.SessionInfo,
};

pub fn run(runtime: *const Runtime, opts: RunOpts) !void {
    var pam = try Pam(void).init(runtime.allocator, .{
        .service_name = opts.service_name,
        .user = opts.user,
        .state = .discardAll(),
    });
    defer pam.deinit();

    const session_vt = runtime.resolveSessionVt(opts.info.session_type);

    var tty_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tty_path = try session_vt.resolveTtyDevicePath(runtime.io, &tty_path_buf);
    try pam.setItem(.tty, tty_path);
    try pam.accountMgmt(.{});
    try pam.setCred(.{ .action = .establish });

    var session = blk: {
        const tty_file = try session_vt.openSessionTty(runtime.io);
        errdefer if (tty_file.handle > 2) tty_file.close(runtime.io);

        var session_envmap = std.process.Environ.Map.init(runtime.allocator);
        defer session_envmap.deinit();
        if (opts.info.session_type == .x11) {
            try session_envmap.put("XDG_SESSION_TYPE", "x11");
        }
        break :blk try runtime.startSession(void, &pam, .{
            .info = opts.info,
            .env_map = &session_envmap,
            .vt = session_vt,
            .tty_file = tty_file,
        });
    };
    defer session.deinit(runtime.io);

    try session.wait();
}
