const std = @import("std");

// buffer size to read greeter responses in pam conv
pub const PAM_CONV_BUF_SIZE = 4096;
// buffer size to read ipc events in the greeter
pub const GREETER_BUF_SIZE = 4096;
// buffer size to read start_auth event
// (max_username_len+1)
pub const PAM_START_BUF_SIZE = 64;

const SOCK_IO_BUF_SIZE = 4096;

const IpcEventType = enum {
    pam_start_auth,
    pam_message,
    pam_request,
    pam_response,
    pam_auth_result,
    start_session,
    set_session_env,
};

pub const SessionType = enum(u8) {
    Command = 0,
    X11 = 1,
};

pub const SessionCommand = struct {
    // NUL-separated argv with a trailing NUL.
    argv: []const u8,
};

pub const SessionInfo = union(SessionType) {
    Command: SessionCommand,
    X11: SessionCommand,
};

pub const SessionEnvVar = struct {
    key: []const u8,
    value: []const u8,
};

pub const PamConvRequest = struct {
    echo: bool,
    message: []const u8,
};
pub const PamMessage = struct {
    is_error: bool,
    message: []const u8,
};
pub const PamConvResponse = []const u8;
pub const PamAuthResult = struct {
    ok: bool,
};
pub const IpcEvent = union(IpcEventType) {
    pam_start_auth: struct {
        user: [:0]const u8,
    },
    pam_message: PamMessage,
    pam_request: PamConvRequest,
    pam_response: PamConvResponse,
    pam_auth_result: PamAuthResult,
    start_session: SessionInfo,
    set_session_env: SessionEnvVar,
};

pub const Ipc = struct {
    file: std.fs.File,
    w_buf: [SOCK_IO_BUF_SIZE]u8 = undefined,
    r_buf: [SOCK_IO_BUF_SIZE]u8 = undefined,
    writer: std.fs.File.Writer = undefined,
    reader: std.fs.File.Reader = undefined,

    pub fn init(file: std.fs.File) Ipc {
        var self = Ipc{ .file = file };
        self.writer = file.writer(&self.w_buf);
        self.reader = file.reader(&self.r_buf);
        return self;
    }

    pub fn initFromFd(fd: std.posix.fd_t) Ipc {
        return Ipc.init(std.fs.File{ .handle = fd });
    }

    pub fn deinit(self: *Ipc) void {
        self.file.close();
    }

    fn readHeader(self: *Ipc) !struct { tag: IpcEventType, payload_len: usize } {
        const reader = &self.reader.interface;
        const tag_num = try reader.takeInt(u8, .little);
        const payload_len_u32 = try reader.takeInt(u32, .little);
        const tag: IpcEventType = @enumFromInt(tag_num);
        return .{
            .tag = tag,
            .payload_len = @intCast(payload_len_u32),
        };
    }

    fn writeHeader(self: *Ipc, tag: IpcEventType, payload_len: u32) !void {
        const writer = &self.writer.interface;
        try writer.writeInt(u8, @intFromEnum(tag), .little);
        try writer.writeInt(u32, payload_len, .little);
    }

    pub fn readEvent(self: *Ipc, event_buf: []u8) !IpcEvent {
        const header = try self.readHeader();
        const payload_len = header.payload_len;

        if (payload_len + 1 > event_buf.len) {
            return error.BufferTooSmall;
        }

        const payload = event_buf[0..payload_len];
        const reader = &self.reader.interface;
        try reader.readSliceAll(payload);
        event_buf[payload_len] = 0;

        return switch (header.tag) {
            .pam_start_auth => IpcEvent{
                .pam_start_auth = .{
                    .user = event_buf[0..payload_len :0],
                },
            },
            .pam_message => blk: {
                if (payload_len < 1) return error.InvalidPayload;
                const is_error = event_buf[0] != 0;
                const msg = event_buf[1..payload_len];
                break :blk IpcEvent{
                    .pam_message = .{
                        .is_error = is_error,
                        .message = msg,
                    },
                };
            },
            .pam_request => blk: {
                if (payload_len < 1) return error.InvalidPayload;
                const echo = event_buf[0] != 0;
                const msg = event_buf[1..payload_len];
                break :blk IpcEvent{
                    .pam_request = .{
                        .echo = echo,
                        .message = msg,
                    },
                };
            },
            .pam_response => IpcEvent{ .pam_response = event_buf[0..payload_len] },
            .pam_auth_result => blk: {
                if (payload_len != 1) return error.InvalidPayload;
                const ok = event_buf[0] != 0;
                break :blk IpcEvent{ .pam_auth_result = .{ .ok = ok } };
            },
            .start_session => blk: {
                if (payload_len < 2) return error.InvalidPayload;
                const session_type: SessionType = @enumFromInt(event_buf[0]);
                const argv = event_buf[1..payload_len];
                if (argv[0] == 0) return error.InvalidPayload;
                if (argv[argv.len - 1] != 0) return error.InvalidPayload;
                break :blk switch (session_type) {
                    .Command => IpcEvent{ .start_session = .{ .Command = .{ .argv = argv } } },
                    .X11 => IpcEvent{ .start_session = .{ .X11 = .{ .argv = argv } } },
                };
            },
            .set_session_env => blk: {
                const env_bytes = event_buf[0..payload_len];
                const eq = std.mem.indexOfScalar(u8, env_bytes, '=') orelse return error.InvalidPayload;
                if (eq == 0) return error.InvalidPayload;
                break :blk IpcEvent{
                    .set_session_env = .{
                        .key = env_bytes[0..eq],
                        .value = env_bytes[eq + 1 .. payload_len],
                    },
                };
            },
        };
    }

    pub fn writeEvent(self: *Ipc, event: *const IpcEvent) !void {
        const writer = &self.writer.interface;
        switch (event.*) {
            .pam_start_auth => |ev| {
                const user_len: u32 = @intCast(ev.user.len);
                try self.writeHeader(.pam_start_auth, user_len);
                try writer.writeAll(ev.user);
            },
            .pam_message => |info| {
                const msg_len: u32 = @intCast(info.message.len);
                const payload_len: u32 = msg_len + 1;
                try self.writeHeader(.pam_message, payload_len);
                const is_error: u8 = if (info.is_error) 1 else 0;
                try writer.writeAll(&[_]u8{is_error});
                try writer.writeAll(info.message);
            },
            .pam_request => |req| {
                const msg_len: u32 = @intCast(req.message.len);
                const payload_len: u32 = msg_len + 1;
                try self.writeHeader(.pam_request, payload_len);
                const echo_byte: u8 = if (req.echo) 1 else 0;
                try writer.writeAll(&[_]u8{echo_byte});
                try writer.writeAll(req.message);
            },
            .pam_response => |resp| {
                const resp_len: u32 = @intCast(resp.len);
                try self.writeHeader(.pam_response, resp_len);
                try writer.writeAll(resp);
            },
            .pam_auth_result => |result| {
                try self.writeHeader(.pam_auth_result, 1);
                const ok_byte: u8 = if (result.ok) 1 else 0;
                try writer.writeAll(&[_]u8{ok_byte});
            },
            .start_session => |info| {
                switch (info) {
                    .Command => |cmd| {
                        if (cmd.argv.len == 0 or cmd.argv[cmd.argv.len - 1] != 0) {
                            return error.InvalidPayload;
                        }
                        const payload_len: u32 = @intCast(cmd.argv.len + 1);
                        try self.writeHeader(.start_session, payload_len);
                        try writer.writeAll(&[_]u8{@intFromEnum(SessionType.Command)});
                        try writer.writeAll(cmd.argv);
                    },
                    .X11 => |cmd| {
                        if (cmd.argv.len == 0 or cmd.argv[cmd.argv.len - 1] != 0) {
                            return error.InvalidPayload;
                        }
                        const payload_len: u32 = @intCast(cmd.argv.len + 1);
                        try self.writeHeader(.start_session, payload_len);
                        try writer.writeAll(&[_]u8{@intFromEnum(SessionType.X11)});
                        try writer.writeAll(cmd.argv);
                    },
                }
            },
            .set_session_env => |env| {
                if (std.mem.indexOfScalar(u8, env.key, '=') != null) return error.InvalidPayload;
                const payload_len: u32 = @intCast(env.key.len + 1 + env.value.len);
                try self.writeHeader(.set_session_env, payload_len);
                try writer.writeAll(env.key);
                try writer.writeAll("=");
                try writer.writeAll(env.value);
            },
        }
    }

    pub fn flush(self: *Ipc) !void {
        try self.writer.interface.flush();
    }
};
