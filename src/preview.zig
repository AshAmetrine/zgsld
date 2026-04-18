const std = @import("std");
const Ipc = @import("Ipc");
const SocketPair = @import("SocketPair.zig");
pub const types = @import("preview/types.zig");
const Options = types.Options;

pub const Runtime = struct {
    io: std.Io,
    ipc_conn: Ipc.Connection,
    thread: ?std.Thread,
    ctx: *Runtime.ServerCtx,

    pub const ServerCtx = struct {
        io: std.Io,
        conn: Ipc.Connection,
        opts: Options,
        err: ?anyerror,
    };

    pub fn init(io: std.Io, ctx: *Runtime.ServerCtx, opts: Options) !Runtime {
        const fds = try SocketPair.init(io);

        ctx.* = .{
            .io = io,
            .conn = Ipc.Connection.init(fds.parent),
            .opts = opts,
            .err = null,
        };
        errdefer ctx.conn.deinit(io);

        var ipc_conn = Ipc.Connection.init(fds.child);
        errdefer ipc_conn.deinit(io);

        const thread = try std.Thread.spawn(.{}, ipcThreadMain, .{ctx});

        return .{
            .io = io,
            .ipc_conn = ipc_conn,
            .thread = thread,
            .ctx = ctx,
        };
    }

    pub fn closeAndJoin(self: *Runtime) !void {
        if (self.thread == null) return;

        const thread = self.thread.?;
        self.thread = null;

        self.ipc_conn.deinit(self.io);
        thread.join();

        if (self.ctx.err) |err| return err;
    }

    pub fn deinit(self: *Runtime) void {
        self.closeAndJoin() catch {};
    }
};

fn ipcThreadMain(ctx: *Runtime.ServerCtx) void {
    defer ctx.conn.deinit(ctx.io);
    runMockIpc(ctx) catch |err| {
        ctx.err = err;
    };
}

const AuthState = enum {
    cancelled,
    failed,
    ok,
};

const StepState = struct {
    previous_response_buf: [Ipc.event_buf_size]u8 = undefined,
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
    var event_buf: [Ipc.event_buf_size]u8 = undefined;
    var rbuf: [Ipc.event_buf_size]u8 = undefined;
    var wbuf: [Ipc.event_buf_size]u8 = undefined;
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
        var failed_result = Ipc.Event{ .pam_auth_result = .{ .ok = false } };
        try sendEvent(ctx, io_writer, &failed_result);
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

    var result = Ipc.Event{ .pam_auth_result = .{
        .ok = post_auth_state == .ok,
    } };
    try sendEvent(ctx, io_writer, &result);

    return post_auth_state;
}

fn runSteps(
    ctx: *Runtime.ServerCtx,
    steps: []const types.Step,
    io_reader: *std.Io.Reader,
    io_writer: *std.Io.Writer,
    event_buf: []u8,
    step_state: *StepState,
) !AuthState {
    for (steps) |step| {
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

                var attempt: usize = 0;
                while (attempt < retry.attempts) : (attempt += 1) {
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
    messages: []const Ipc.PamMessage,
) !void {
    for (messages) |message| {
        var event = Ipc.Event{ .pam_message = message };
        try sendEvent(ctx, io_writer, &event);
    }
}

fn sendEvent(
    ctx: *Runtime.ServerCtx,
    io_writer: *std.Io.Writer,
    event: *const Ipc.Event,
) !void {
    try ctx.conn.writeEvent(io_writer, event);
    try io_writer.flush();
}
