const std = @import("std");
const ipc = @import("ipc");
const build_options = @import("build_options");

pub const password_auth_steps = [_]Step{
    .challenge("Password: ", .any, .{}),
};

pub const change_auth_token_steps = [_]Step{
    .info("Authentication token update required."),
    .challenge("Current password: ", .expect_previous, .{
        .on_failure = &.{
            .err("Current password is incorrect."),
        },
    }),
    .retry(3, &.{
        .challenge("New password: ", .any, .{}),
        .challenge("Retype new password: ", .expect_previous, .{
            .on_failure = &.{
                .err("Passwords do not match."),
            },
        }),
    }),
};

pub const Codecs = struct {
    greeter: *ipc.Codec,
    daemon: *ipc.Codec,
};

pub const Options = struct {
    authenticate_steps: []const Step = &password_auth_steps,
    post_auth_steps: []const Step = &.{},
    expected_user: ?[]const u8 = null,
};

pub const ExpectedResponse = union(enum) {
    pub fn expect(value: []const u8) ExpectedResponse {
        return .{ .value = value };
    }

    value: []const u8,
    any: void,
    expect_previous: void,
};

pub const ChallengeOptions = struct {
    echo: bool = false,
    on_failure: []const ipc.PamMessage = &.{},
};

pub const Step = union(enum) {
    internal_error: void,
    pam_message: ipc.PamMessage,
    pam_challenge: struct {
        request: ipc.PamConvRequest,
        expected_response: ExpectedResponse,
        on_failure: []const ipc.PamMessage = &.{},
    },
    retry_block: struct {
        attempts: usize,
        steps: []const Step,
    },

    pub fn challenge(
        msg: []const u8,
        expected_response: ExpectedResponse,
        opts: ChallengeOptions,
    ) Step {
        return .{
            .pam_challenge = .{
                .request = .{
                    .echo = opts.echo,
                    .message = msg,
                },
                .expected_response = expected_response,
                .on_failure = opts.on_failure,
            },
        };
    }

    pub fn retry(attempts: usize, steps: []const Step) Step {
        return .{
            .retry_block = .{
                .attempts = attempts,
                .steps = steps,
            },
        };
    }

    pub fn info(msg: []const u8) Step {
        return .{
            .pam_message = .info(msg),
        };
    }

    pub fn err(msg: []const u8) Step {
        return .{
            .pam_message = .err(msg),
        };
    }
};

const AuthState = enum {
    cancelled,
    internal_error,
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

const Conversation = struct {
    conn: *ipc.Connection,
    opts: Options,
};

pub fn run(_: std.Io, connection: *ipc.Connection, options: Options) !void {
    var conversation: Conversation = .{ .conn = connection, .opts = options };
    const ctx = &conversation;
    var event_buf: [ipc.event_buf_size]u8 = undefined;
    var authenticated = false;

    while (true) {
        const read_result = ctx.conn.readEvent(&event_buf);
        const event = read_result catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };

        switch (event) {
            .login_cancel => {
                authenticated = false;
                try sendEvent(ctx, &.login_cancelled);
            },
            .pam_start_auth => |auth| {
                if (authenticated) {
                    return error.UnexpectedPreviewEvent;
                }
                const state = try runAuthSequence(ctx, auth.user, &event_buf);
                authenticated = state == .ok;
                if (state == .cancelled) try sendEvent(ctx, &.login_cancelled);
            },
            .set_session_env => {
                if (!authenticated) return error.UnexpectedPreviewEvent;
            },
            .start_session => |info| {
                if (!authenticated) return error.UnexpectedPreviewEvent;
                info.validate(build_options.x11_support) catch {
                    try sendEvent(ctx, &.{ .err = .{ .code = .invalid_request } });
                    continue;
                };
                try sendEvent(ctx, &.session_accepted);
                return;
            },
            else => return error.UnexpectedPreviewEvent,
        }
    }
}

fn runAuthSequence(
    ctx: *Conversation,
    user: []const u8,
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
        event_buf,
        &step_state,
    );
    if (auth_state == .cancelled or auth_state == .internal_error) return auth_state;

    if (auth_state == .failed or !expected_user_matches) {
        try sendEvent(ctx, &.{ .pam_auth_result = .{ .ok = false } });
        return .failed;
    }

    const post_auth_state = try runSteps(
        ctx,
        ctx.opts.post_auth_steps,
        event_buf,
        &step_state,
    );
    if (post_auth_state == .cancelled or post_auth_state == .internal_error) return post_auth_state;

    try sendEvent(ctx, &.{ .pam_auth_result = .{ .ok = post_auth_state == .ok } });

    return post_auth_state;
}

fn runSteps(
    ctx: *Conversation,
    steps: []const Step,
    event_buf: []u8,
    step_state: *StepState,
) !AuthState {
    for (steps) |step| {
        switch (step) {
            .internal_error => {
                try sendEvent(ctx, &.{ .err = .{
                    .code = .internal_error,
                } });
                return .internal_error;
            },
            .pam_message => |info| {
                try sendEvent(ctx, &.{ .pam_message = info });
            },
            .pam_challenge => |challenge| {
                try sendEvent(ctx, &.{ .pam_request = challenge.request });

                const response = try ctx.conn.readEvent(event_buf);
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
                            try emitFailureMessages(ctx, challenge.on_failure);
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
                        event_buf,
                        &attempt_state,
                    );
                    switch (retry_result) {
                        .ok => {
                            step_state.* = attempt_state;
                            break;
                        },
                        .cancelled, .internal_error => return retry_result,
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
    ctx: *Conversation,
    messages: []const ipc.PamMessage,
) !void {
    for (messages) |message| {
        try sendEvent(ctx, &.{ .pam_message = message });
    }
}

fn sendEvent(
    ctx: *Conversation,
    event: *const ipc.Event,
) !void {
    try ctx.conn.writeEvent(event);
    try ctx.conn.transport.writer.flush();
}
