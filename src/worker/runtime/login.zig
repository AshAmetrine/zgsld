const std = @import("std");
const Ipc = @import("Ipc");
const pam_mod = @import("pam");
const pam_conv = @import("pam_conv.zig");
const tty = @import("tty.zig");
const session_mod = @import("session.zig");
const signals = @import("signals.zig");

const Pam = pam_mod.Pam;
const PamCtx = pam_conv.PamCtx;

const log = std.log.scoped(.zgsld_worker);

const SessionEnvKey = enum {
    PATH,
    XDG_SESSION_DESKTOP,
    XDG_CURRENT_DESKTOP,
    XDG_SESSION_TYPE,
};

pub const RunOpts = struct {
    allocator: std.mem.Allocator,
    service_name: []const u8,
    ipc_conn: *Ipc.Connection,
    vt: ?u8,
};

const SessionSetup = struct {
    env: std.process.EnvMap,
    info: Ipc.SessionInfo,
};

pub fn run(opts: RunOpts) !void {
    var saw_auth = false;
    var event_buf: [Ipc.event_buf_size]u8 = undefined;
    var rbuf: [Ipc.event_buf_size]u8 = undefined;
    var wbuf: [Ipc.event_buf_size]u8 = undefined;
    var reader_impl = opts.ipc_conn.reader(&rbuf);
    var writer_impl = opts.ipc_conn.writer(&wbuf);
    const ipc_reader = &reader_impl.interface;
    const ipc_writer = &writer_impl.interface;

    while (true) {
        log.debug("Waiting for event", .{});
        const event = opts.ipc_conn.readEvent(ipc_reader, &event_buf) catch |err| {
            if (err == error.EndOfStream and !saw_auth) {
                if (signals.shutdownRequested()) return;
                std.process.exit(2);
            }
            return err;
        };
        switch (event) {
            .login_cancel => {
                log.debug("Login cancelled before auth start", .{});
                continue;
            },
            .pam_start_auth => |auth| {
                saw_auth = true;
                const user_z = try opts.allocator.dupeZ(u8, auth.user);
                defer opts.allocator.free(user_z);

                var pam_ctx: PamCtx = .{
                    .cancelled = false,
                    .ipc_conn = opts.ipc_conn,
                    .reader = ipc_reader,
                    .writer = ipc_writer,
                };

                var pam = try Pam(PamCtx).init(opts.allocator, .{
                    .service_name = opts.service_name,
                    .user = user_z,
                    .state = &.{
                        .conv = pam_conv.loginConv,
                        .ctx = &pam_ctx,
                    },
                });
                defer pam.deinit();

                var tty_path_buf: [std.fs.max_path_bytes]u8 = undefined;
                try pam.setItem(.{ .tty = try tty.resolvePamTty(&tty_path_buf, opts.vt) });

                if (!(try authenticate(&pam, &pam_ctx))) continue;

                var session_setup = try getSession(opts.allocator, opts.ipc_conn, ipc_reader, &event_buf) orelse continue;
                if (signals.shutdownRequested()) return;
                try runSession(opts.allocator, user_z, session_setup.info, &pam, &session_setup.env, opts.vt);
            },
            else => unreachable,
        }
    }
}

fn authenticate(
    pam: *Pam(PamCtx),
    pam_ctx: *PamCtx,
) !bool {
    pam.authenticate(.{}) catch {
        if (pam_ctx.cancelled) {
            log.debug("Pam auth cancelled", .{});
            return false;
        }

        try pam_ctx.ipc_conn.writeEvent(pam_ctx.writer, &.{ .pam_auth_result = .{ .ok = false } });
        try pam_ctx.writer.flush();
        return false;
    };
    try pam.accountMgmt(.{});
    try pam.setCred(.{ .action = .establish });

    try pam_ctx.ipc_conn.writeEvent(pam_ctx.writer, &.{ .pam_auth_result = .{ .ok = true } });
    try pam_ctx.writer.flush();
    return true;
}

fn getSession(
    allocator: std.mem.Allocator,
    ipc_conn: *Ipc.Connection,
    ipc_reader: *std.Io.Reader,
    event_buf: *[Ipc.event_buf_size]u8,
) !?SessionSetup {
    var session_envmap = std.process.EnvMap.init(allocator);
    errdefer session_envmap.deinit();

    while (true) {
        const session_event = ipc_conn.readEvent(ipc_reader, event_buf) catch |err| {
            if (err == error.EndOfStream and signals.shutdownRequested()) {
                std.process.exit(0);
            }
            return err;
        };
        switch (session_event) {
            .login_cancel => {
                log.debug("Login cancelled before session start", .{});
                session_envmap.deinit();
                return null;
            },
            .set_session_env => |env| {
                if (std.meta.stringToEnum(SessionEnvKey, env.key) == null) continue;
                try session_envmap.put(env.key, env.value);
            },
            .start_session => |info| {
                return .{
                    .info = info,
                    .env = session_envmap,
                };
            },
            else => unreachable,
        }
    }
    return null;
}

fn runSession(
    allocator: std.mem.Allocator,
    user_z: [:0]const u8,
    info: Ipc.SessionInfo,
    pam: *Pam(PamCtx),
    session_envmap: *std.process.EnvMap,
    vt: ?u8,
) !void {
    log.debug("Starting session...", .{});

    var session = blk: {
        defer session_envmap.deinit();
        break :blk try session_mod.start(allocator, user_z, info, pam, session_envmap, vt);
    };
    defer session.deinit();

    log.debug("Waiting for session to end...", .{});
    signals.setActiveChild(session.pid);
    defer signals.clearActiveChild();

    if (signals.shutdownRequested()) {
        signals.forwardShutdownSignal(signals.shutdownSignal());
    }
    _ = std.posix.waitpid(session.pid, 0);
}
