const std = @import("std");
const ipc = @import("ipc");
const SocketPair = @import("common").SocketPair;
const preview = @import("preview");
const Self = @This();

ipc_conn: ipc.Connection,
thread: ?std.Thread,
ctx: *ServerCtx,

pub const Options = struct {
    codec: *ipc.Codec = ipc.Codec.binary,
    preview: preview.Options = .{},
};

pub const ServerCtx = struct {
    io: std.Io,
    conn: ipc.Connection,
    opts: preview.Options,
    result: anyerror!void,
};

pub fn init(io: std.Io, ctx: *ServerCtx, opts: Options) !Self {
    const fds = try SocketPair.init();

    ctx.* = .{
        .io = io,
        .conn = ipc.Connection.init(fds.parent, .{ .codec = opts.codec }),
        .opts = opts.preview,
        .result = {},
    };
    errdefer ctx.conn.deinit(io);

    var ipc_conn = ipc.Connection.init(fds.child, .{ .codec = opts.codec });
    errdefer ipc_conn.deinit(io);

    const thread = try std.Thread.spawn(.{}, ipcThreadMain, .{ctx});

    return .{
        .ipc_conn = ipc_conn,
        .thread = thread,
        .ctx = ctx,
    };
}

pub fn closeAndJoin(self: *Self) !void {
    const thread = self.thread orelse return;
    self.thread = null;

    self.ipc_conn.deinit(self.ctx.io);
    thread.join();

    return self.ctx.result;
}

pub fn deinit(self: *Self) void {
    self.closeAndJoin() catch {};
}

fn ipcThreadMain(ctx: *ServerCtx) void {
    defer ctx.conn.deinit(ctx.io);
    ctx.result = preview.run(ctx.io, &ctx.conn, ctx.opts);
}
