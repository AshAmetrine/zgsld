//! IPC events, connections and pluggable codecs for greeters and zgsld.

const std = @import("std");
const Binary = @import("ipc/binary.zig");

/// Recommended buffer size for event payloads and socket IO.
pub const event_buf_size = 4096;

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

    pub fn validate(self: SessionInfo, x11_supported: bool) error{InvalidSession}!void {
        if (self.command.session_cmd.len == 0 or
            std.mem.indexOfScalar(u8, self.command.session_cmd, 0) != null or
            (self.session_type == .x11 and !x11_supported))
        {
            return error.InvalidSession;
        }
    }
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

/// An error reported by ZGSLD to the greeter.
pub const ErrorInfo = struct {
    code: Code,
    message: []const u8 = "",

    pub const max_message_len = event_buf_size - 2;
    pub const Code = enum {
        /// Session request failed validation.
        invalid_request,
        internal_error,
    };
};

pub const Event = union(enum) {
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
    err: ErrorInfo,
    session_accepted: void,
    login_cancelled: void,
};

pub const Codec = struct {
    context: ?*anyopaque = null,
    vtable: *const VTable,

    pub const VTable = struct {
        readEvent: *const fn (?*anyopaque, *std.Io.Reader, *std.Io.Writer, []u8) anyerror!Event,
        writeEvent: *const fn (?*anyopaque, *std.Io.Writer, *const Event) anyerror!void,
    };

    pub const binary: Codec = .{ .vtable = &.{
        .readEvent = Binary.readEvent,
        .writeEvent = Binary.writeEvent,
    } };

    /// Reads an event. The codec can use the writer to send protocol replies.
    /// Any replies must be flushed before reading more data or returning an event.
    pub fn readEvent(
        self: Codec,
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        event_buf: []u8,
    ) !Event {
        return self.vtable.readEvent(self.context, reader, writer, event_buf);
    }

    pub fn writeEvent(self: Codec, writer: *std.Io.Writer, event: *const Event) !void {
        return self.vtable.writeEvent(self.context, writer, event);
    }
};

/// Socket-backed IPC transport with event encode/decode helpers.
pub const Connection = struct {
    const Self = @This();

    file: std.Io.File,
    codec: Codec = .binary,

    pub const Options = struct {
        codec: Codec = .binary,
    };

    /// Takes ownership of `file` and copies the codec handle, borrowing its context.
    pub fn init(file: std.Io.File, opts: Options) Self {
        return .{ .file = file, .codec = opts.codec };
    }

    /// Closes the underlying socket/file.
    pub fn deinit(self: *Self, io: std.Io) void {
        self.file.close(io);
    }

    /// Creates a buffered file reader using caller-provided buffer.
    pub fn reader(self: *Self, io: std.Io, buffer: []u8) std.Io.File.Reader {
        return self.file.reader(io, buffer);
    }

    /// Creates a buffered file writer using caller-provided buffer.
    pub fn writer(self: *Self, io: std.Io, buffer: []u8) std.Io.File.Writer {
        return self.file.writer(io, buffer);
    }

    /// Reads an event using a reader and writer for this connection.
    pub fn readEvent(
        self: *Self,
        io_reader: *std.Io.Reader,
        io_writer: *std.Io.Writer,
        event_buf: []u8,
    ) !Event {
        return self.codec.readEvent(io_reader, io_writer, event_buf);
    }

    pub fn writeEvent(self: *Self, io_writer: *std.Io.Writer, event: *const Event) !void {
        return self.codec.writeEvent(io_writer, event);
    }
};
