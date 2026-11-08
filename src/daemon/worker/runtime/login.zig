const std = @import("std");
const ipc = @import("ipc");
const Pam = @import("pam").Pam;
const PamError = @import("pam").PamError;
const pam_conv = @import("pam_conv.zig");
const session_mod = @import("session.zig");
const signals = @import("signals.zig");
const Vt = @import("vt").Vt;
const Shutdown = @import("../../Shutdown.zig");

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
    shutdown_conn: *Shutdown.Connection,
    env_map: *const std.process.Environ.Map,
    service_name: [:0]const u8,
    ipc_socket: std.Io.File,
    vt: Vt,
    x11: session_mod.X11Options,
};

const SessionSetup = struct {
    env: std.process.Environ.Map,
    info: ipc.SessionInfo,
};

pub fn run(opts: RunOpts) !void {
    var ipc_closed = false;
    defer if (!ipc_closed) opts.ipc_socket.close(opts.io);

    var event_buf: [ipc.event_buf_size]u8 = undefined;
    defer std.crypto.secureZero(u8, &event_buf);
    var rbuf: [ipc.event_buf_size]u8 = undefined;
    defer std.crypto.secureZero(u8, &rbuf);
    var wbuf: [ipc.event_buf_size]u8 = undefined;
    defer std.crypto.secureZero(u8, &wbuf);
    var reader_impl = opts.ipc_socket.reader(opts.io, &rbuf);
    var writer_impl = opts.ipc_socket.writer(opts.io, &wbuf);
    var connection = ipc.Connection.init(.{
        .reader = &reader_impl.interface,
        .writer = &writer_impl.interface,
    }, .{});
    const ipc_conn = &connection;
    const ipc_writer = connection.transport.writer;
    var cancelled = false;

    while (true) {
        defer std.crypto.secureZero(u8, &event_buf);
        // Confirm cleanup has finished after login_cancel.
        if (cancelled) {
            try ipc_conn.writeEvent(&.login_cancelled);
            try ipc_writer.flush();
            cancelled = false;
        }
        log.debug("Waiting for event", .{});
        const event = ipc_conn.readEvent(&event_buf) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        switch (event) {
            .login_cancel => {
                log.debug("Login cancelled before auth start", .{});
                cancelled = true;
                continue;
            },
            .pam_start_auth => |auth| {
                var pam_ctx: PamCtx = .{
                    .ipc_conn = ipc_conn,
                };

                const conv_state: Pam(PamCtx).ConvState = .{
                    .conv = pam_conv.loginConv,
                    .ctx = &pam_ctx,
                };
                var pam = initPam(opts, auth.user, &conv_state) catch |err| {
                    _ = try reportAuthError(&pam_ctx, .setup, err);
                    continue;
                };
                defer pam.deinit();

                authenticate(&pam, &pam_ctx) catch |err| {
                    switch (try reportAuthError(&pam_ctx, .credentials, err)) {
                        .retry => {},
                        .cancelled => cancelled = true,
                    }
                    continue;
                };
                try writeAuthResult(&pam_ctx, true);

                switch (try runSession(opts, ipc_conn, &pam, &event_buf, &ipc_closed)) {
                    .cancelled => cancelled = true,
                    .finished => return,
                }
            },
            else => return error.UnexpectedEvent,
        }
    }
}

fn initPam(
    opts: RunOpts,
    user: [:0]const u8,
    state: *const Pam(PamCtx).ConvState,
) !Pam(PamCtx) {
    var pam = try Pam(PamCtx).init(opts.allocator, .{
        .service_name = opts.service_name,
        .user = user,
        .state = state,
    });
    errdefer pam.deinit();

    var tty_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tty_path = try opts.vt.resolveTtyDevicePath(opts.io, &tty_path_buf);
    try pam.setItem(.tty, tty_path);
    return pam;
}

const AuthFailure = enum { retry, cancelled };
const AuthPhase = enum { setup, credentials };

fn reportAuthError(ctx: *PamCtx, phase: AuthPhase, err: anyerror) !AuthFailure {
    var failure = err;
    if (phase == .credentials) {
        if (err == error.AuthCancelled) return .cancelled;
        if (ctx.conv_error) |conv_err| {
            if (conv_err != error.OutOfMemory) return conv_err;
            failure = conv_err;
        }
        switch (failure) {
            error.AuthError,
            error.UserUnknown,
            error.PermissionDenied,
            error.AccountExpired,
            error.MaximumTries,
            error.CredentialsExpired,
            error.CredentialsInsufficient,
            => {
                try writeAuthResult(ctx, false);
                return .retry;
            },
            else => {},
        }
    }
    try reportInternalError(ctx, failure);
    return .retry;
}

const SessionResult = enum { cancelled, finished };

fn runSession(
    opts: RunOpts,
    ipc_conn: *ipc.Connection,
    pam: *Pam(PamCtx),
    event_buf: *[ipc.event_buf_size]u8,
    ipc_closed: *bool,
) !SessionResult {
    var session = blk: {
        var session_setup = (getSession(
            opts.allocator,
            ipc_conn,
            event_buf,
        ) catch |err| {
            if (err == error.EndOfStream and signals.shutdownRequested()) return .finished;
            return err;
        }) orelse {
            return .cancelled;
        };
        defer session_setup.env.deinit();
        if (signals.shutdownRequested()) return .finished;
        opts.ipc_socket.close(opts.io);
        ipc_closed.* = true;
        break :blk try startSession(
            opts.allocator,
            opts.io,
            opts.shutdown_conn,
            opts.env_map,
            session_setup.info,
            pam,
            &session_setup.env,
            opts.vt,
            opts.x11,
        );
    };
    defer session.deinit(opts.io);

    log.debug("Waiting for session to end...", .{});
    try session.wait();
    return .finished;
}

fn authenticate(pam: *Pam(PamCtx), ctx: *PamCtx) !void {
    try checkPamResult(ctx, pam.authenticate(.{}));
    checkPamResult(ctx, pam.accountMgmt(.{})) catch |err| switch (err) {
        error.NewAuthTokenRequired => {
            try checkPamResult(ctx, pam.changeAuthToken(.{ .change_expired_authtok = true }));
        },
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
    try ctx.ipc_conn.writeEvent(&.{ .err = .{
        .code = .internal_error,
    } });
    try ctx.ipc_conn.transport.writer.flush();
}

fn writeAuthResult(pam_ctx: *PamCtx, ok: bool) !void {
    try pam_ctx.ipc_conn.writeEvent(&.{ .pam_auth_result = .{ .ok = ok } });
    try pam_ctx.ipc_conn.transport.writer.flush();
}

fn getSession(
    allocator: std.mem.Allocator,
    ipc_conn: *ipc.Connection,
    event_buf: *[ipc.event_buf_size]u8,
) !?SessionSetup {
    var session_envmap = std.process.Environ.Map.init(allocator);
    errdefer session_envmap.deinit();

    while (true) {
        const session_event = try ipc_conn.readEvent(event_buf);
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

fn startSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    shutdown_conn: *Shutdown.Connection,
    env_map: *const std.process.Environ.Map,
    info: ipc.SessionInfo,
    pam: *Pam(PamCtx),
    session_envmap: *std.process.Environ.Map,
    vt: Vt,
    x11: session_mod.X11Options,
) !session_mod.Session {
    log.debug("Starting session...", .{});
    const session_vt = session_mod.resolveSessionVt(info.session_type, x11, vt);
    var tty_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tty_path = try session_vt.resolveTtyDevicePath(io, &tty_path_buf);
    try pam.setItem(.tty, tty_path);
    const tty_file = try session_vt.openSessionTty(io);
    errdefer if (tty_file.handle > 2) tty_file.close(io);

    return try session_mod.start(
        PamCtx,
        allocator,
        io,
        shutdown_conn,
        env_map,
        info,
        pam,
        session_envmap,
        session_vt,
        tty_file,
        x11,
    );
}
