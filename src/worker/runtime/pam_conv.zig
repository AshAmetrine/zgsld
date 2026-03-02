const std = @import("std");
const pam_mod = @import("pam");
const Ipc = @import("Ipc");

const PamMessages = pam_mod.Messages;

pub const PamCtx = struct {
    cancelled: bool,
    ipc_conn: *Ipc.Connection,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
};

pub fn loginConv(
    _: std.mem.Allocator,
    msgs: PamMessages,
    ctx: *PamCtx,
) !void {
    if (ctx.cancelled) return error.Abort;

    const ipc_reader = ctx.reader;
    const ipc_writer = ctx.writer;

    var ipc_buf: [Ipc.event_buf_size]u8 = undefined;
    defer std.crypto.secureZero(u8, &ipc_buf);

    var iter = msgs.iter();
    while (try iter.next()) |msg| {
        switch (msg) {
            .prompt_echo_off, .prompt_echo_on => |m| {
                try ctx.ipc_conn.writeEvent(ipc_writer, &.{
                    .pam_request = .{
                        .echo = msg == .prompt_echo_on,
                        .message = m.message,
                    },
                });
                try ipc_writer.flush();

                const event = try ctx.ipc_conn.readEvent(ipc_reader, &ipc_buf);
                switch (event) {
                    .pam_response => |resp_bytes| {
                        try m.respond(resp_bytes);
                    },
                    .login_cancel => {
                        ctx.cancelled = true;
                        return error.Abort;
                    },
                    else => unreachable,
                }
            },
            .text_info, .error_msg => |m| {
                try ctx.ipc_conn.writeEvent(ipc_writer, &.{
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

