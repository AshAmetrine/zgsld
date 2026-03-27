//! Binary IPC protocol between greeter and zgsld.
//!
//! Events are encoded as:
//! - `u8` event tag
//! - `u32` payload length (native endianness)
//! - payload bytes
//!
//! Protocol flow:
//! 1. greeter sends `pam_start_auth`
//! 2. zgsld sends `pam_message`/`pam_request`
//! 3. greeter sends `pam_response` for each `pam_request`
//! 4. zgsld sends `pam_auth_result`
//! 5. greeter sends `set_session_env` + `start_session`

const std = @import("std");
const builtin = @import("builtin");
const native = builtin.target.cpu.arch.endian();

/// Recommended buffer size for event payloads and socket IO.
pub const event_buf_size = 4096;

const EventType = enum {
    pam_start_auth,
    pam_message,
    pam_request,
    pam_response,
    pam_auth_result,
    login_cancel,
    start_session,
    set_session_env,
};

/// Session type chosen by the greeter after authentication succeeds.
pub const SessionType = enum(u8) {
    command = 0,
    x11 = 1,
};

/// Payload for `start_session`.
pub const SessionCommand = struct {
    session_cmd: []const u8,
    source_profile: bool = true,
};

/// Session launch request sent by the greeter.
pub const SessionInfo = struct {
    session_type: SessionType,
    command: SessionCommand,
};

/// Environment variable entry sent by the greeter before `start_session`.
pub const SessionEnvVar = struct {
    key: []const u8,
    value: []const u8,
};

/// PAM prompt request sent from zgsld to greeter.
pub const PamConvRequest = struct {
    echo: bool,
    message: []const u8,
};

/// Informational/error message sent from zgsld to greeter.
pub const PamMessage = struct {
    is_error: bool,
    message: []const u8,

    pub fn info(msg: []const u8) PamMessage {
        return .{
            .is_error = false,
            .message = msg,
        };
    }

    pub fn err(msg: []const u8) PamMessage {
        return .{
            .is_error = true,
            .message = msg,
        };
    }
};

/// PAM response string sent from greeter to zgsld.
pub const PamConvResponse = []const u8;

/// Authentication result sent from zgsld to greeter.
pub const PamAuthResult = struct {
    ok: bool,
};

pub const Event = union(EventType) {
    pam_start_auth: struct {
        user: [:0]const u8,
    },
    pam_message: PamMessage,
    pam_request: PamConvRequest,
    pam_response: PamConvResponse,
    pam_auth_result: PamAuthResult,
    login_cancel: void,
    start_session: SessionInfo,
    set_session_env: SessionEnvVar,
};

/// Socket-backed IPC transport with event encode/decode helpers.
pub const Connection = struct {
    const Self = @This();

    file: std.fs.File,

    /// Initializes a connection from an owned file handle.
    pub fn init(file: std.fs.File) Self {
        return .{ .file = file };
    }

    /// Initializes a connection from an fd.
    pub fn initFromFd(fd: std.posix.fd_t) Self {
        return init(std.fs.File{ .handle = fd });
    }

    /// Closes the underlying socket/file.
    pub fn deinit(self: *Self) void {
        self.file.close();
    }

    /// Creates a buffered file reader using caller-provided buffer.
    pub fn reader(self: *Self, buffer: []u8) std.fs.File.Reader {
        return self.file.reader(buffer);
    }

    /// Creates a buffered file writer using caller-provided buffer.
    pub fn writer(self: *Self, buffer: []u8) std.fs.File.Writer {
        return self.file.writer(buffer);
    }

    fn readHeader(io_reader: *std.Io.Reader) !struct { tag: EventType, payload_len: usize } {
        const tag_num = try io_reader.takeInt(u8, native);
        const payload_len_u32 = try io_reader.takeInt(u32, native);
        const tag: EventType = @enumFromInt(tag_num);
        return .{
            .tag = tag,
            .payload_len = @intCast(payload_len_u32),
        };
    }

    fn writeHeader(io_writer: *std.Io.Writer, tag: EventType, payload_len: u32) !void {
        try io_writer.writeInt(u8, @intFromEnum(tag), native);
        try io_writer.writeInt(u32, payload_len, native);
    }

    /// Reads and decodes one event from the stream into `event_buf`.
    ///
    /// Returned string/slice fields borrow from `event_buf` and are valid only
    /// until the next `readEvent` call that reuses that buffer.
    pub fn readEvent(_: *Self, io_reader: *std.Io.Reader, event_buf: []u8) !Event {
        const header = try readHeader(io_reader);

        const payload_len = header.payload_len;

        if (payload_len + 1 > event_buf.len) {
            return error.BufferTooSmall;
        }

        const payload = event_buf[0..payload_len];
        try io_reader.readSliceAll(payload);
        event_buf[payload_len] = 0;

        return switch (header.tag) {
            .pam_start_auth => Event{
                .pam_start_auth = .{
                    .user = event_buf[0..payload_len :0],
                },
            },
            .login_cancel => Event.login_cancel,
            .pam_message => blk: {
                if (payload_len < 1) return error.InvalidPayload;
                const is_error = event_buf[0] != 0;
                const msg = event_buf[1..payload_len];
                break :blk Event{
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
                break :blk Event{
                    .pam_request = .{
                        .echo = echo,
                        .message = msg,
                    },
                };
            },
            .pam_response => Event{ .pam_response = event_buf[0..payload_len] },
            .pam_auth_result => blk: {
                if (payload_len != 1) return error.InvalidPayload;
                const ok = event_buf[0] != 0;
                break :blk Event{ .pam_auth_result = .{ .ok = ok } };
            },
            .start_session => blk: {
                if (payload_len < 3) return error.InvalidPayload;
                const session_type: SessionType = @enumFromInt(event_buf[0]);
                const flags = event_buf[1];
                const session_cmd = event_buf[2..payload_len];
                if (session_cmd.len == 0) return error.InvalidPayload;

                const source_profile = (flags & 0x01) != 0;
                break :blk Event{
                    .start_session = .{
                        .session_type = session_type,
                        .command = .{
                            .session_cmd = session_cmd,
                            .source_profile = source_profile,
                        },
                    },
                };
            },
            .set_session_env => blk: {
                const env_bytes = event_buf[0..payload_len];
                const eq = std.mem.indexOfScalar(u8, env_bytes, '=') orelse return error.InvalidPayload;
                if (eq == 0) return error.InvalidPayload;
                break :blk Event{
                    .set_session_env = .{
                        .key = env_bytes[0..eq],
                        .value = env_bytes[eq + 1 .. payload_len],
                    },
                };
            },
        };
    }

    /// Encodes and writes one event to the stream.
    pub fn writeEvent(_: *Self, io_writer: *std.Io.Writer, event: *const Event) !void {
        switch (event.*) {
            .pam_start_auth => |ev| {
                const user_len: u32 = @intCast(ev.user.len);
                try writeHeader(io_writer, .pam_start_auth, user_len);
                try io_writer.writeAll(ev.user);
            },
            .login_cancel => {
                try writeHeader(io_writer, .login_cancel, 0);
            },
            .pam_message => |info| {
                const msg_len: u32 = @intCast(info.message.len);
                const payload_len: u32 = msg_len + 1;
                try writeHeader(io_writer, .pam_message, payload_len);
                const is_error: u8 = if (info.is_error) 1 else 0;
                try io_writer.writeAll(&[_]u8{is_error});
                try io_writer.writeAll(info.message);
            },
            .pam_request => |req| {
                const msg_len: u32 = @intCast(req.message.len);
                const payload_len: u32 = msg_len + 1;
                try writeHeader(io_writer, .pam_request, payload_len);
                const echo_byte: u8 = if (req.echo) 1 else 0;
                try io_writer.writeAll(&[_]u8{echo_byte});
                try io_writer.writeAll(req.message);
            },
            .pam_response => |resp| {
                const resp_len: u32 = @intCast(resp.len);
                try writeHeader(io_writer, .pam_response, resp_len);
                try io_writer.writeAll(resp);
            },
            .pam_auth_result => |result| {
                try writeHeader(io_writer, .pam_auth_result, 1);
                const ok_byte: u8 = if (result.ok) 1 else 0;
                try io_writer.writeAll(&[_]u8{ok_byte});
            },
            .start_session => |info| {
                const cmd = info.command;
                if (cmd.session_cmd.len == 0) {
                    return error.InvalidPayload;
                }
                const payload_len: u32 = @intCast(cmd.session_cmd.len + 2);
                try writeHeader(io_writer, .start_session, payload_len);
                try io_writer.writeInt(u8, @intFromEnum(info.session_type), native);
                const flags: u8 = if (cmd.source_profile) 0x01 else 0x00;
                try io_writer.writeInt(u8, flags, native);
                try io_writer.writeAll(cmd.session_cmd);
            },
            .set_session_env => |env| {
                if (std.mem.indexOfScalar(u8, env.key, '=') != null) return error.InvalidPayload;
                const payload_len: u32 = @intCast(env.key.len + 1 + env.value.len);
                try writeHeader(io_writer, .set_session_env, payload_len);
                try io_writer.writeAll(env.key);
                try io_writer.writeAll("=");
                try io_writer.writeAll(env.value);
            },
        }
    }
};
