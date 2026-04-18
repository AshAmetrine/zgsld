const Ipc = @import("Ipc");

pub const password_auth_steps = [_]Step{
    .challenge("Password: ", .expect("123"), .{}),
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

pub const Options = struct {
    authenticate_steps: []const Step = &password_auth_steps,
    post_auth_steps: []const Step = &.{},
    expected_user: ?[]const u8 = "user",
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
    on_failure: []const Ipc.PamMessage = &.{},
};

pub const Step = union(enum) {
    pam_message: Ipc.PamMessage,
    pam_challenge: struct {
        request: Ipc.PamConvRequest,
        expected_response: ExpectedResponse,
        on_failure: []const Ipc.PamMessage = &.{},
    },
    retry_block: struct {
        attempts: usize,
        steps: []const Step,
    },

    pub fn challenge(msg: []const u8, expected_response: ExpectedResponse, opts: ChallengeOptions) Step {
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
