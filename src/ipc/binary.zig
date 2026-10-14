//! Default binary IPC codec.
//!
//! Events are encoded as:
//! - `u8` event tag
//! - `u32` payload length (native endianness)
//! - payload bytes

const std = @import("std");
const builtin = @import("builtin");
const ipc = @import("../ipc.zig");
const Codec = ipc.Codec;
const Event = ipc.Event;
const EventType = std.meta.Tag(Event);
const SessionType = ipc.SessionType;
const native = builtin.target.cpu.arch.endian();

fn readHeader(io_reader: *std.Io.Reader) !struct { tag: EventType, payload_len: usize } {
    const tag_num = try io_reader.takeByte();
    const payload_len_u32 = try io_reader.takeInt(u32, native);
    const tag: EventType = @fromBackingInt(@intCast(tag_num));
    return .{
        .tag = tag,
        .payload_len = @intCast(payload_len_u32),
    };
}

fn writeHeader(io_writer: *std.Io.Writer, tag: EventType, payload_len: u32) !void {
    try io_writer.writeByte(@backingInt(tag));
    try io_writer.writeInt(u32, payload_len, native);
}

/// Reads and decodes one event from the stream into `event_buf`.
///
/// Returned string/slice fields borrow from `event_buf` and are valid only
/// until the next `readEvent` call that reuses that buffer.
pub fn readEvent(_: *const Codec, io_reader: *std.Io.Reader, event_buf: []u8) !Event {
    const header = try readHeader(io_reader);

    const payload_len = header.payload_len;

    if (payload_len >= event_buf.len) {
        return error.BufferTooSmall;
    }

    const payload = event_buf[0..payload_len];
    try io_reader.readSliceAll(payload);
    event_buf[payload_len] = 0;

    return switch (header.tag) {
        .pam_start_auth => .{
            .pam_start_auth = .{
                .user = event_buf[0..payload_len :0],
            },
        },
        .login_cancel => .login_cancel,
        .pam_message => blk: {
            if (payload_len == 0) return error.InvalidPayload;
            break :blk .{
                .pam_message = .{
                    .is_error = payload[0] != 0,
                    .message = payload[1..],
                },
            };
        },
        .pam_request => blk: {
            if (payload_len == 0) return error.InvalidPayload;
            break :blk .{
                .pam_request = .{
                    .echo = payload[0] != 0,
                    .message = payload[1..],
                },
            };
        },
        .pam_response => .{ .pam_response = payload },
        .pam_auth_result => blk: {
            if (payload_len != 1) return error.InvalidPayload;
            break :blk .{ .pam_auth_result = .{ .ok = payload[0] != 0 } };
        },
        .start_session => blk: {
            if (payload_len < 3) return error.InvalidPayload;
            const session_type: SessionType = @fromBackingInt(@intCast(payload[0]));
            break :blk .{
                .start_session = .{
                    .session_type = session_type,
                    .command = .{
                        .session_cmd = payload[2..],
                        .source_profile = (payload[1] & 0x01) != 0,
                    },
                },
            };
        },
        .set_session_env => blk: {
            const eq = std.mem.indexOfScalar(u8, payload, '=') orelse return error.InvalidPayload;
            if (eq == 0) return error.InvalidPayload;
            break :blk .{
                .set_session_env = .{
                    .key = payload[0..eq],
                    .value = payload[eq + 1 ..],
                },
            };
        },
    };
}

/// Encodes and writes one event to the stream.
pub fn writeEvent(_: *const Codec, io_writer: *std.Io.Writer, event: *const Event) !void {
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
            try io_writer.writeByte(@intFromBool(info.is_error));
            try io_writer.writeAll(info.message);
        },
        .pam_request => |req| {
            const msg_len: u32 = @intCast(req.message.len);
            const payload_len: u32 = msg_len + 1;
            try writeHeader(io_writer, .pam_request, payload_len);
            try io_writer.writeByte(@intFromBool(req.echo));
            try io_writer.writeAll(req.message);
        },
        .pam_response => |resp| {
            const resp_len: u32 = @intCast(resp.len);
            try writeHeader(io_writer, .pam_response, resp_len);
            try io_writer.writeAll(resp);
        },
        .pam_auth_result => |result| {
            try writeHeader(io_writer, .pam_auth_result, 1);
            try io_writer.writeByte(@intFromBool(result.ok));
        },
        .start_session => |info| {
            const cmd = info.command;
            if (cmd.session_cmd.len == 0) {
                return error.InvalidPayload;
            }
            const payload_len: u32 = @intCast(cmd.session_cmd.len + 2);
            try writeHeader(io_writer, .start_session, payload_len);
            try io_writer.writeByte(@backingInt(info.session_type));
            try io_writer.writeByte(@intFromBool(cmd.source_profile));
            try io_writer.writeAll(cmd.session_cmd);
        },
        .set_session_env => |env| {
            if (std.mem.indexOfScalar(u8, env.key, '=') != null) return error.InvalidPayload;
            const payload_len: u32 = @intCast(env.key.len + 1 + env.value.len);
            try writeHeader(io_writer, .set_session_env, payload_len);
            try io_writer.writeAll(env.key);
            try io_writer.writeByte('=');
            try io_writer.writeAll(env.value);
        },
    }
}
