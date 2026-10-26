const std = @import("std");
const ipc = @import("ipc");
const Pam = @import("pam").Pam;
const PamError = @import("pam").PamError;
const pam_conv = @import("pam_conv.zig");
const session_mod = @import("session.zig");
const signals = @import("signals.zig");
const Vt = @import("vt").Vt;

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
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    service_name: []const u8,
    ipc_conn: *ipc.Connection,
    vt: Vt,
};

const SessionSetup = struct {
    env: std.process.Environ.Map,
    info: ipc.SessionInfo,
};

pub fn run(opts: RunOpts) !void {
    var ipc_closed = false;
    defer if (!ipc_closed) opts.ipc_conn.deinit(opts.io);

    var saw_auth = false;
    var event_buf: [ipc.event_buf_size]u8 = undefined;
    var rbuf: [ipc.event_buf_size]u8 = undefined;
    var wbuf: [ipc.event_buf_size]u8 = undefined;
    var reader_impl = opts.ipc_conn.reader(opts.io, &rbuf);
    var writer_impl = opts.ipc_conn.writer(opts.io, &wbuf);
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
                var pam_ctx: PamCtx = .{
                    .ipc_conn = opts.ipc_conn,
                    .reader = ipc_reader,
                    .writer = ipc_writer,
                };

                const user_z = opts.allocator.dupeSentinel(u8, auth.user, 0) catch |err| {
                    try reportInternalError(&pam_ctx, err);
                    continue;
                };
                defer opts.allocator.free(user_z);

                var pam = Pam(PamCtx).init(opts.allocator, .{
                    .service_name = opts.service_name,
                    .user = user_z,
                    .state = &.{
                        .conv = pam_conv.loginConv,
                        .ctx = &pam_ctx,
                    },
                }) catch |err| {
                    try reportInternalError(&pam_ctx, err);
                    continue;
                };
                defer pam.deinit();

                var tty_path_buf: [std.fs.max_path_bytes]u8 = undefined;
                const tty_path = opts.vt.resolveTtyDevicePath(opts.io, opts.env_map, &tty_path_buf) catch |err| {
                    try reportInternalError(&pam_ctx, err);
                    continue;
                };
                pam.setItem(.{ .tty = tty_path }) catch |err| {
                    try reportInternalError(&pam_ctx, err);
                    continue;
                };

                authenticate(&pam, &pam_ctx) catch |err| switch (err) {
                    error.AuthCancelled => continue,
                    error.ConversationFailed => {
                        const conv_err = pam_ctx.conv_error.?;
                        if (conv_err != error.OutOfMemory) return conv_err;
                        try reportInternalError(&pam_ctx, conv_err);
                        continue;
                    },
                    error.AuthError,
                    error.UserUnknown,
                    error.PermissionDenied,
                    error.AccountExpired,
                    error.MaximumTries,
                    error.CredentialsExpired,
                    error.CredentialsInsufficient,
                    => {
                        try writeAuthResult(&pam_ctx, false);
                        continue;
                    },
                    else => {
                        try reportInternalError(&pam_ctx, err);
                        continue;
                    },
                };
                try writeAuthResult(&pam_ctx, true);

                var session_setup = try getSession(opts.allocator, opts.ipc_conn, ipc_reader, &event_buf) orelse continue;
                if (signals.shutdownRequested()) {
                    session_setup.env.deinit();
                    return;
                }
                opts.ipc_conn.deinit(opts.io);
                ipc_closed = true;
                try runSession(opts.allocator, opts.io, opts.env_map, user_z, session_setup.info, &pam, &session_setup.env, opts.vt);
                return;
            },
            else => return error.UnexpectedEvent,
        }
    }
}

fn authenticate(pam: *Pam(PamCtx), ctx: *PamCtx) !void {
    try checkPamResult(ctx, pam.authenticate(.{}));
    checkPamResult(ctx, pam.accountMgmt(.{})) catch |err| switch (err) {
        error.NewAuthTokenRequired => try checkPamResult(ctx, pam.changeAuthToken(.{ .change_expired_authtok = true })),
        else => return err,
    };
    try checkPamResult(ctx, pam.setCred(.{ .action = .establish }));
}

fn checkPamResult(ctx: *const PamCtx, result: PamError!void) !void {
    if (ctx.cancelled) return error.AuthCancelled;
    if (ctx.conv_error != null) return error.ConversationFailed;
    return result;
}

fn reportInternalError(ctx: *PamCtx, err: anyerror) !void {
    log.err("Authentication internal error: {s}", .{@errorName(err)});
    try ctx.ipc_conn.writeEvent(ctx.writer, &.{ .err = .{
        .code = .internal_error,
    } });
    try ctx.writer.flush();
}

fn writeAuthResult(pam_ctx: *PamCtx, ok: bool) !void {
    try pam_ctx.ipc_conn.writeEvent(pam_ctx.writer, &.{ .pam_auth_result = .{ .ok = ok } });
    try pam_ctx.writer.flush();
}

fn getSession(
    allocator: std.mem.Allocator,
    ipc_conn: *ipc.Connection,
    ipc_reader: *std.Io.Reader,
    event_buf: *[ipc.event_buf_size]u8,
) !?SessionSetup {
    var session_envmap = std.process.Environ.Map.init(allocator);
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
            else => return error.UnexpectedEvent,
        }
    }
}

fn runSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    user_z: [:0]const u8,
    info: ipc.SessionInfo,
    pam: *Pam(PamCtx),
    session_envmap: *std.process.Environ.Map,
    vt: Vt,
) !void {
    log.debug("Starting session...", .{});
    var started = blk: {
        defer session_envmap.deinit();
        const session_vt = try session_mod.resolveSessionVt(info.session_type, env_map, vt);
        const tty_file = try session_vt.openSessionTty(io, env_map);
        errdefer if (tty_file.handle > 2) tty_file.close(io);

        const session = try session_mod.start(PamCtx, allocator, io, env_map, user_z, info, pam, session_envmap, session_vt);
        break :blk .{ .session = session, .tty_file = tty_file };
    };
    defer if (started.tty_file.handle > 2) started.tty_file.close(io);
    defer started.session.deinit(io);

    log.debug("Waiting for session to end...", .{});
    try signals.waitForChild(io, &started.session.child);
}
