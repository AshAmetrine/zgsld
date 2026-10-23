const std = @import("std");
const ipc = @import("ipc");
const SocketPair = @import("SocketPair.zig");
pub const api = @import("preview/api.zig");

pub const Runtime = struct {
    ipc_conn: ipc.Connection,
    thread: ?std.Thread,
    ctx: *Runtime.ServerCtx,

    pub const Options = struct {
        codec: *const ipc.Codec = &ipc.Codec.binary,
        preview: api.Options = .{},
    };

    pub const ServerCtx = struct {
        io: std.Io,
        conn: ipc.Connection,
        opts: api.Options,
        result: anyerror!void,
    };

    pub fn init(io: std.Io, ctx: *Runtime.ServerCtx, opts: Options) !Runtime {
        const fds = try SocketPair.init();

        ctx.* = .{
            .io = io,
            .conn = ipc.Connection.init(fds.parent, .{ .codec = opts.codec }),
            .opts = opts.preview,
            .result = {},
        };
        errdefer ctx.conn.deinit(io);

        var ipc_conn = ipc.Connection.init(fds.child, .{ .codec = opts.codec });
        errdefer ipc_conn.deinit(io);

        const thread = try std.Thread.spawn(.{}, ipcThreadMain, .{ctx});

        return .{
            .ipc_conn = ipc_conn,
            .thread = thread,
            .ctx = ctx,
        };
    }

    pub fn closeAndJoin(self: *Runtime) !void {
        const thread = self.thread orelse return;
        self.thread = null;

        self.ipc_conn.deinit(self.ctx.io);
        thread.join();

        return self.ctx.result;
    }

    pub fn deinit(self: *Runtime) void {
        self.closeAndJoin() catch {};
    }
};

fn ipcThreadMain(ctx: *Runtime.ServerCtx) void {
    defer ctx.conn.deinit(ctx.io);
    ctx.result = runMockIpc(ctx);
}

const AuthState = enum {
    cancelled,
    failed,
    ok,
};

const StepState = struct {
    previous_response_buf: [ipc.event_buf_size]u8 = undefined,
    previous_response_len: ?usize = null,

    fn previousResponse(self: *const StepState) ?[]const u8 {
        const len = self.previous_response_len orelse return null;
        return self.previous_response_buf[0..len];
    }

    fn setPreviousResponse(self: *StepState, resp: []const u8) void {
        @memcpy(self.previous_response_buf[0..resp.len], resp);
        self.previous_response_len = resp.len;
    }
};

fn runMockIpc(ctx: *Runtime.ServerCtx) !void {
    var event_buf: [ipc.event_buf_size]u8 = undefined;
    var rbuf: [ipc.event_buf_size]u8 = undefined;
    var wbuf: [ipc.event_buf_size]u8 = undefined;
    var authenticated = false;

    var reader = ctx.conn.reader(ctx.io, &rbuf);
    var writer = ctx.conn.writer(ctx.io, &wbuf);
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
                authenticated = state == .ok;
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

    var step_state = StepState{};
    const auth_state = try runSteps(
        ctx,
        ctx.opts.authenticate_steps,
        io_reader,
        io_writer,
        event_buf,
        &step_state,
    );
    if (auth_state == .cancelled) {
        return .cancelled;
    }

    if (auth_state == .failed or !expected_user_matches) {
        try sendEvent(ctx, io_writer, &.{ .pam_auth_result = .{ .ok = false } });
        return .failed;
    }

    const post_auth_state = try runSteps(
        ctx,
        ctx.opts.post_auth_steps,
        io_reader,
        io_writer,
        event_buf,
        &step_state,
    );
    if (post_auth_state == .cancelled) {
        return .cancelled;
    }

    try sendEvent(ctx, io_writer, &.{ .pam_auth_result = .{ .ok = post_auth_state == .ok } });

    return post_auth_state;
}

fn runSteps(
    ctx: *Runtime.ServerCtx,
    steps: []const api.Step,
    io_reader: *std.Io.Reader,
    io_writer: *std.Io.Writer,
    event_buf: []u8,
    step_state: *StepState,
) !AuthState {
    for (steps) |step| {
        switch (step) {
            .pam_message => |info| {
                try sendEvent(ctx, io_writer, &.{ .pam_message = info });
            },
            .pam_challenge => |challenge| {
                try sendEvent(ctx, io_writer, &.{ .pam_request = challenge.request });

                const response = try ctx.conn.readEvent(io_reader, event_buf);
                switch (response) {
                    .pam_response => |resp| {
                        const response_matches = switch (challenge.expected_response) {
                            .value => |expected| std.mem.eql(u8, resp, expected),
                            .any => true,
                            .expect_previous => blk: {
                                const expected = step_state.previousResponse() orelse {
                                    return error.InvalidPreviewConfiguration;
                                };
                                break :blk std.mem.eql(u8, resp, expected);
                            },
                        };
                        if (!response_matches) {
                            try emitFailureMessages(ctx, io_writer, challenge.on_failure);
                            return .failed;
                        }

                        step_state.setPreviousResponse(resp);
                    },
                    .login_cancel => return .cancelled,
                    else => return error.UnexpectedPreviewEvent,
                }
            },
            .retry_block => |retry| {
                if (retry.attempts == 0) {
                    return error.InvalidPreviewConfiguration;
                }

                for (0..retry.attempts) |attempt| {
                    var attempt_state = step_state.*;
                    const retry_result = try runSteps(
                        ctx,
                        retry.steps,
                        io_reader,
                        io_writer,
                        event_buf,
                        &attempt_state,
                    );
                    switch (retry_result) {
                        .ok => {
                            step_state.* = attempt_state;
                            break;
                        },
                        .cancelled => return .cancelled,
                        .failed => {
                            if (attempt + 1 == retry.attempts) {
                                return .failed;
                            }
                        },
                    }
                }
            },
        }
    }

    return .ok;
}

fn emitFailureMessages(
    ctx: *Runtime.ServerCtx,
    io_writer: *std.Io.Writer,
    messages: []const ipc.PamMessage,
) !void {
    for (messages) |message| {
        try sendEvent(ctx, io_writer, &.{ .pam_message = message });
    }
}

fn sendEvent(
    ctx: *Runtime.ServerCtx,
    io_writer: *std.Io.Writer,
    event: *const ipc.Event,
) !void {
    try ctx.conn.writeEvent(io_writer, event);
    try io_writer.flush();
}
