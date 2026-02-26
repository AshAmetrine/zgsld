const std = @import("std");
const Ipc = @import("Ipc");
const SocketPair = @import("SocketPair.zig");

pub const Step = union(enum) {
    pam_message: Ipc.PamMessage,
    pam_challenge: struct {
        request: Ipc.PamConvRequest,
        expected_response: []const u8,
    },

    pub fn challenge(echo: bool, msg: []const u8, expected_response: []const u8) Step {
        return .{
            .pam_challenge = .{
                .request = .{
                    .echo = echo,
                    .message = msg,
                },
                .expected_response = expected_response,
            },
        };
    }

    pub fn message(is_error: bool, msg: []const u8) Step {
        return .{
            .pam_message = .{
                .is_error = is_error,
                .message = msg,
            },
        };
    }
};

const default_steps = [_]Step{
    Step.challenge(false, "Password: ", "123"),
};

pub const Options = struct {
    steps: []const Step = &default_steps,
    expected_user: ?[]const u8 = "user",
};

pub const Runtime = struct {
    ipc_conn: Ipc.Connection,
    thread: ?std.Thread,
    ctx: *Runtime.ServerCtx,

    pub const ServerCtx = struct {
        conn: Ipc.Connection,
        opts: Options,
        err: ?anyerror,
    };

    pub fn init(ctx: *Runtime.ServerCtx, opts: Options) !Runtime {
        const fds = try SocketPair.init(false);
        errdefer std.posix.close(fds.parent);
        errdefer std.posix.close(fds.child);

        ctx.* = .{
            .conn = Ipc.Connection.initFromFd(fds.parent),
            .opts = opts,
            .err = null,
        };
        errdefer ctx.conn.deinit();

        var ipc_conn = Ipc.Connection.initFromFd(fds.child);
        errdefer ipc_conn.deinit();

        const thread = try std.Thread.spawn(.{}, ipcThreadMain, .{ctx});

        return .{
            .ipc_conn = ipc_conn,
            .thread = thread,
            .ctx = ctx,
        };
    }

    pub fn closeAndJoin(self: *Runtime) !void {
        if (self.thread == null) return;

        const thread = self.thread.?;
        self.thread = null;

        self.ipc_conn.deinit();
        thread.join();

        if (self.ctx.err) |err| return err;
    }

    pub fn deinit(self: *Runtime) void {
        self.closeAndJoin() catch {};
    }
};

fn ipcThreadMain(ctx: *Runtime.ServerCtx) void {
    defer ctx.conn.deinit();
    runMockIpc(ctx) catch |err| {
        ctx.err = err;
    };
}

const AuthState = enum {
    cancelled,
    failed,
    ok,
};

fn runMockIpc(ctx: *Runtime.ServerCtx) !void {
    var event_buf: [Ipc.event_buf_size]u8 = undefined;
    var rbuf: [Ipc.event_buf_size]u8 = undefined;
    var wbuf: [Ipc.event_buf_size]u8 = undefined;
    var authenticated = false;

    var reader = ctx.conn.reader(&rbuf);
    var writer = ctx.conn.writer(&wbuf);
    const io_reader = &reader.interface;
    const io_writer = &writer.interface;

    while (true) {
        const event = ctx.conn.readEvent(io_reader, &event_buf) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };

        switch (event) {
            .login_cancel => {
                authenticated = false;
            },
            .pam_start_auth => |auth| {
                if (authenticated) {
                    return error.UnexpectedPreviewEvent;
                }
                const state = try runAuthSequence(ctx, auth.user, io_reader, io_writer, &event_buf);
                authenticated = switch (state) {
                    .ok => true,
                    .failed, .cancelled => false,
                };
            },
            .set_session_env => {
                if (!authenticated) return error.UnexpectedPreviewEvent;
            },
            .start_session => {
                if (!authenticated) return error.UnexpectedPreviewEvent;
                return;
            },
            else => return error.UnexpectedPreviewEvent,
        }
    }
}

fn runAuthSequence(
    ctx: *Runtime.ServerCtx,
    user: []const u8,
    io_reader: *std.Io.Reader,
    io_writer: *std.Io.Writer,
    event_buf: []u8,
) !AuthState {
    const expected_user_matches = if (ctx.opts.expected_user) |expected_user|
        std.mem.eql(u8, user, expected_user)
    else
        true;

    var auth_succeeded = expected_user_matches;

    for (ctx.opts.steps) |step| {
        switch (step) {
            .pam_message => |info| {
                var event = Ipc.Event{ .pam_message = info };
                try sendEvent(ctx, io_writer, &event);
            },
            .pam_challenge => |challenge| {
                var event = Ipc.Event{ .pam_request = challenge.request };
                try sendEvent(ctx, io_writer, &event);

                const response = try ctx.conn.readEvent(io_reader, event_buf);
                switch (response) {
                    .pam_response => |resp| {
                        const response_matches = std.mem.eql(u8, resp, challenge.expected_response);
                        auth_succeeded = auth_succeeded and response_matches;
                    },
                    .login_cancel => return .cancelled,
                    else => return error.UnexpectedPreviewEvent,
                }
            },
        }
    }

    var result = Ipc.Event{ .pam_auth_result = .{ .ok = auth_succeeded } };
    try sendEvent(ctx, io_writer, &result);

    return if (auth_succeeded) .ok else .failed;
}

fn sendEvent(
    ctx: *Runtime.ServerCtx,
    io_writer: *std.Io.Writer,
    event: *const Ipc.Event,
) !void {
    try ctx.conn.writeEvent(io_writer, event);
    try io_writer.flush();
}
