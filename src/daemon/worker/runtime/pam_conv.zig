const std = @import("std");
const PamMessages = @import("pam").Messages;
const ipc = @import("ipc");

pub const PamCtx = struct {
    cancelled: bool = false,
    conv_error: ?anyerror = null,
    ipc_conn: *ipc.Connection,
};

pub fn loginConv(
    _: std.mem.Allocator,
    msgs: PamMessages,
    ctx: *PamCtx,
) !void {
    if (ctx.cancelled) return error.Abort;
    if (ctx.conv_error) |err| return err;
    runConversation(msgs, ctx) catch |err| {
        if (!ctx.cancelled) ctx.conv_error = err;
        return err;
    };
}

fn runConversation(msgs: PamMessages, ctx: *PamCtx) !void {
    const ipc_writer = ctx.ipc_conn.transport.writer;

    var ipc_buf: [ipc.event_buf_size]u8 = undefined;
    defer std.crypto.secureZero(u8, &ipc_buf);

    var iter = msgs.iter();
    while (try iter.next()) |msg| {
        switch (msg) {
            .prompt_echo_off, .prompt_echo_on => |m| {
                defer std.crypto.secureZero(u8, &ipc_buf);
                defer {
                    // Keep unread events while erasing consumed binary IPC data.
                    const reader = ctx.ipc_conn.transport.reader;
                    std.crypto.secureZero(u8, reader.buffer[0..reader.seek]);
                    std.crypto.secureZero(u8, reader.buffer[reader.end..]);
                }
                try ctx.ipc_conn.writeEvent(&.{
                    .pam_request = .{
                        .echo = msg == .prompt_echo_on,
                        .message = m.message,
                    },
                });
                try ipc_writer.flush();

                const event = try ctx.ipc_conn.readEvent(&ipc_buf);
                switch (event) {
                    .pam_response => |resp_bytes| {
                        try m.respond(resp_bytes);
                    },
                    .login_cancel => {
                        ctx.cancelled = true;
                        return error.Abort;
                    },
                    else => return error.UnexpectedEvent,
                }
            },
            .text_info, .error_msg => |m| {
                try ctx.ipc_conn.writeEvent(&.{
                    .pam_message = .{
                        .is_error = msg == .error_msg,
                        .message = m,
                    },
                });
                try ipc_writer.flush();
            },
        }
    }
}
