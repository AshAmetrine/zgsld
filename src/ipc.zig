//! IPC events, connections and pluggable codecs for greeters and zgsld.

const std = @import("std");
const binary_codec = @import("ipc/binary.zig");

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
        locale: ?[:0]const u8 = null,
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
    vtable: *const VTable,

    pub const VTable = struct {
        readEvent: *const fn (*Codec, *std.Io.Reader, *std.Io.Writer, []u8) anyerror!Event,
        writeEvent: *const fn (*Codec, *std.Io.Writer, *const Event) anyerror!void,
    };

    pub const binary: *Codec = &binary_codec.interface;

    /// Reads an event. The codec can use the writer to send protocol replies.
    /// Any replies must be flushed before reading more data or returning an event.
    pub fn readEvent(
        self: *Codec,
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        event_buf: []u8,
    ) !Event {
        return self.vtable.readEvent(self, reader, writer, event_buf);
    }

    pub fn writeEvent(self: *Codec, writer: *std.Io.Writer, event: *const Event) !void {
        return self.vtable.writeEvent(self, writer, event);
    }
};

pub const Transport = struct {
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
};

pub const Connector = struct {
    connect: *const fn (*Connector) anyerror!Transport,
};

/// IPC event encoding and decoding over borrowed streams.
pub const Connection = struct {
    const Self = @This();

    transport: Transport,
    codec: *Codec = Codec.binary,

    pub const Options = struct {
        codec: *Codec = Codec.binary,
    };

    /// The transport streams, their backing storage, and codec must outlive the connection.
    pub fn init(transport: Transport, opts: Options) Self {
        return .{ .transport = transport, .codec = opts.codec };
    }

    /// Reads an event using a reader and writer for this connection.
    pub fn readEvent(self: *Self, event_buf: []u8) !Event {
        return self.codec.readEvent(self.transport.reader, self.transport.writer, event_buf);
    }

    pub fn writeEvent(self: *Self, event: *const Event) !void {
        return self.codec.writeEvent(self.transport.writer, event);
    }
};
