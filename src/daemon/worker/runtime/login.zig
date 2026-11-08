const std = @import("std");
const ipc = @import("ipc");
const Pam = @import("pam").Pam;
const PamError = @import("pam").PamError;
const pam_conv = @import("pam_conv.zig");
const session_mod = @import("session.zig");
const signals = @import("signals.zig");
const Runtime = @import("Runtime.zig");

const PamCtx = pam_conv.PamCtx;

const log = std.log.scoped(.zgsld_worker);

const SessionEnvKey = enum {
    PATH,
    XDG_SESSION_DESKTOP,
    XDG_CURRENT_DESKTOP,
    XDG_SESSION_TYPE,
};

pub const RunOpts = struct {
    service_name: [:0]const u8,
    ipc_socket: std.Io.File,
};

const SessionSetup = struct {
    env: std.process.Environ.Map,
    info: ipc.SessionInfo,
};

pub fn run(runtime: *const Runtime, opts: RunOpts) !void {
    var ipc_closed = false;
    defer if (!ipc_closed) opts.ipc_socket.close(runtime.io);

    var event_buf: [ipc.event_buf_size]u8 = undefined;
    defer std.crypto.secureZero(u8, &event_buf);
    var rbuf: [ipc.event_buf_size]u8 = undefined;
    defer std.crypto.secureZero(u8, &rbuf);
    var wbuf: [ipc.event_buf_size]u8 = undefined;
    defer std.crypto.secureZero(u8, &wbuf);
    var reader_impl = opts.ipc_socket.reader(runtime.io, &rbuf);
    var writer_impl = opts.ipc_socket.writer(runtime.io, &wbuf);
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
                var pam = initPam(runtime, opts.service_name, auth.user, &conv_state) catch |err| {
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

                switch (try runSession(
                    runtime,
                    opts.ipc_socket,
                    ipc_conn,
                    &pam,
                    &event_buf,
                    &ipc_closed,
                )) {
                    .cancelled => cancelled = true,
                    .finished => return,
                }
            },
            else => return error.UnexpectedEvent,
        }
    }
}

fn initPam(
    runtime: *const Runtime,
    service_name: [:0]const u8,
    user: [:0]const u8,
    state: *const Pam(PamCtx).ConvState,
) !Pam(PamCtx) {
    var pam = try Pam(PamCtx).init(runtime.allocator, .{
        .service_name = service_name,
        .user = user,
        .state = state,
    });
    errdefer pam.deinit();

    var tty_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tty_path = try runtime.vt.resolveTtyDevicePath(runtime.io, &tty_path_buf);
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
    runtime: *const Runtime,
    ipc_socket: std.Io.File,
    ipc_conn: *ipc.Connection,
    pam: *Pam(PamCtx),
    event_buf: *[ipc.event_buf_size]u8,
    ipc_closed: *bool,
) !SessionResult {
    var session = blk: {
        var session_setup = (getSession(
            runtime.allocator,
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
        ipc_socket.close(runtime.io);
        ipc_closed.* = true;
        break :blk try startSession(runtime, pam, session_setup.info, &session_setup.env);
    };
    defer session.deinit(runtime.io);

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
    runtime: *const Runtime,
    pam: *Pam(PamCtx),
    info: ipc.SessionInfo,
    session_envmap: *std.process.Environ.Map,
) !session_mod.Session {
    log.debug("Starting session...", .{});
    const session_vt = runtime.resolveSessionVt(info.session_type);
    var tty_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tty_path = try session_vt.resolveTtyDevicePath(runtime.io, &tty_path_buf);
    try pam.setItem(.tty, tty_path);
    const tty_file = try session_vt.openSessionTty(runtime.io);
    errdefer if (tty_file.handle > 2) tty_file.close(runtime.io);

    return try runtime.startSession(PamCtx, pam, .{
        .info = info,
        .env_map = session_envmap,
        .vt = session_vt,
        .tty_file = tty_file,
    });
}
