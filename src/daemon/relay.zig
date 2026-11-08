const std = @import("std");
const ipc = @import("ipc");
const Shutdown = @import("Shutdown.zig");
const build_options = @import("build_options");
const log = std.log.scoped(.zgsld);

const ForwardIpcCtx = struct {
    io: std.Io,
    src: *ipc.Connection,
    dst: *ipc.Connection,
    src_file: std.Io.File,
    dst_file: std.Io.File,
    mutex: std.Io.Mutex = .init,
    authenticated: bool = false,
    result: anyerror!void = {},

    fn sendEvent(self: *ForwardIpcCtx, event: ipc.Event) !void {
        try self.dst.writeEvent(&event);
        try self.dst.transport.writer.flush();
    }

    fn acceptSession(self: *ForwardIpcCtx, info: ipc.SessionInfo) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.authenticated) return error.UnexpectedEvent;
        info.validate(build_options.x11_support) catch {
            try self.sendEvent(.{ .err = .{ .code = .invalid_request } });
            return false;
        };
        try self.sendEvent(.session_accepted);
        self.authenticated = false;
        return true;
    }
};

/// Prevents forwarded events from interrupting codec replies before they're flushed
const ReplyWriter = struct {
    writer: std.Io.Writer = .{
        .vtable = &.{ .drain = drain, .flush = flush },
        .buffer = &.{},
    },
    ctx: *ForwardIpcCtx,
    locked: bool = false,

    fn unlock(self: *ReplyWriter) void {
        if (!self.locked) return;
        self.locked = false;
        self.ctx.mutex.unlock(self.ctx.io);
    }

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) !usize {
        const self: *ReplyWriter = @fieldParentPtr("writer", writer);
        if (!self.locked) {
            self.ctx.mutex.lockUncancelable(self.ctx.io);
            self.locked = true;
        }
        return self.ctx.dst.transport.writer.writeSplat(data, splat);
    }

    fn flush(writer: *std.Io.Writer) !void {
        const self: *ReplyWriter = @fieldParentPtr("writer", writer);
        if (!self.locked) return;
        defer self.unlock();
        try self.ctx.dst.transport.writer.flush();
    }
};

// Takes ownership of both socket files; all other arguments are borrowed.
pub fn run(
    io: std.Io,
    greeter_file: std.Io.File,
    worker_file: std.Io.File,
    shutdown: *Shutdown,
    greeter_worker_proc: *Shutdown.Worker,
    session_worker_proc: *Shutdown.Worker,
    ipc_codec: *ipc.Codec,
) !void {
    // A completed handoff has already reaped the greeter. Otherwise both
    // workers belong to the aborted login attempt.
    defer if (greeter_worker_proc.process.id != null) {
        shutdown.requestStop(greeter_worker_proc, 0);
        shutdown.requestStop(session_worker_proc, 0);
    };
    defer greeter_file.close(io);
    defer worker_file.close(io);

    var greeter_rbuf: [ipc.event_buf_size]u8 = undefined;
    defer std.crypto.secureZero(u8, &greeter_rbuf);
    var greeter_wbuf: [ipc.event_buf_size]u8 = undefined;
    defer std.crypto.secureZero(u8, &greeter_wbuf);
    var worker_rbuf: [ipc.event_buf_size]u8 = undefined;
    defer std.crypto.secureZero(u8, &worker_rbuf);
    var worker_wbuf: [ipc.event_buf_size]u8 = undefined;
    defer std.crypto.secureZero(u8, &worker_wbuf);
    var greeter_reader = greeter_file.reader(io, &greeter_rbuf);
    var greeter_writer = greeter_file.writer(io, &greeter_wbuf);
    var worker_reader = worker_file.reader(io, &worker_rbuf);
    var worker_writer = worker_file.writer(io, &worker_wbuf);

    var greeter_conn = ipc.Connection.init(.{
        .reader = &greeter_reader.interface,
        .writer = &greeter_writer.interface,
    }, .{ .codec = ipc_codec });
    var worker_conn = ipc.Connection.init(.{
        .reader = &worker_reader.interface,
        .writer = &worker_writer.interface,
    }, .{});
    var worker_to_greeter = ForwardIpcCtx{
        .io = io,
        .src = &worker_conn,
        .dst = &greeter_conn,
        .src_file = worker_file,
        .dst_file = greeter_file,
    };
    var replies = ReplyWriter{ .ctx = &worker_to_greeter };

    const worker_to_greeter_thread = try std.Thread.spawn(
        .{},
        forwardIpcThread,
        .{&worker_to_greeter},
    );
    var session_started = false;
    {
        defer {
            _ = std.c.shutdown(greeter_file.handle, 2);
            _ = std.c.shutdown(worker_file.handle, 2);
            worker_to_greeter_thread.join();
        }

        var event_buf: [ipc.event_buf_size]u8 = undefined;
        while (true) {
            defer std.crypto.secureZero(u8, &event_buf);
            defer std.crypto.secureZero(u8, &worker_wbuf);
            defer {
                std.crypto.secureZero(u8, greeter_rbuf[0..greeter_reader.interface.seek]);
                std.crypto.secureZero(u8, greeter_rbuf[greeter_reader.interface.end..]);
            }
            const read_result = blk: {
                defer replies.unlock();
                break :blk ipc_codec.readEvent(&greeter_reader.interface, &replies.writer, &event_buf);
            };
            const event = read_result catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };

            switch (event) {
                .pam_start_auth, .login_cancel => {
                    worker_to_greeter.mutex.lockUncancelable(io);
                    worker_to_greeter.authenticated = false;
                    worker_to_greeter.mutex.unlock(io);
                },
                .start_session => |info| {
                    if (!try worker_to_greeter.acceptSession(info)) continue;
                    shutdown.requestStop(greeter_worker_proc, 5);
                    try shutdown.waitChecked(greeter_worker_proc);
                    if (Shutdown.shutdownRequested()) return error.Shutdown;
                },
                else => {},
            }

            try worker_conn.writeEvent(&event);
            try worker_conn.transport.writer.flush();
            if (event == .start_session) session_started = true;
        }
    }

    if (Shutdown.shutdownRequested()) return;

    if (!session_started) {
        log.err("Greeter disconnected before starting a session", .{});
        return error.GreeterError;
    }
    return worker_to_greeter.result;
}

fn forwardIpcThread(ctx: *ForwardIpcCtx) void {
    defer {
        _ = std.c.shutdown(ctx.src_file.handle, 2);
        _ = std.c.shutdown(ctx.dst_file.handle, 2);
    }
    ctx.result = forwardIpcEvents(ctx);
}

fn forwardIpcEvents(ctx: *ForwardIpcCtx) !void {
    var event_buf: [ipc.event_buf_size]u8 = undefined;
    while (true) {
        defer std.crypto.secureZero(u8, &event_buf);
        const event = ctx.src.readEvent(&event_buf) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };

        ctx.mutex.lockUncancelable(ctx.io);
        defer ctx.mutex.unlock(ctx.io);
        switch (event) {
            .pam_auth_result => |result| ctx.authenticated = result.ok,
            .err, .login_cancelled => ctx.authenticated = false,
            else => {},
        }
        try ctx.sendEvent(event);
    }
}
