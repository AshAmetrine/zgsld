const std = @import("std");
const ipc = @import("ipc");
const SocketPair = @import("common").SocketPair;
const preview = @import("preview");
const Self = @This();

client: Endpoint,
server: Endpoint,
thread: ?std.Thread,
ctx: ServerCtx,

const Endpoint = struct {
    file: std.Io.File,
    read_buf: [ipc.event_buf_size]u8 = undefined,
    write_buf: [ipc.event_buf_size]u8 = undefined,
    reader: std.Io.File.Reader,
    writer: std.Io.File.Writer,
    connection: ipc.Connection,

    fn init(self: *Endpoint, io: std.Io, file: std.Io.File) void {
        self.file = file;
        self.reader = file.reader(io, &self.read_buf);
        self.writer = file.writer(io, &self.write_buf);
        self.connection = ipc.Connection.init(.{
            .reader = &self.reader.interface,
            .writer = &self.writer.interface,
        }, .{});
    }
};

const ServerCtx = struct {
    io: std.Io,
    endpoint: *Endpoint,
    opts: preview.Options,
    result: anyerror!void = {},
};

pub fn init(self: *Self, io: std.Io, opts: preview.Options) !void {
    const fds = try SocketPair.init();
    errdefer fds.parent.close(io);
    errdefer fds.child.close(io);

    self.client.init(io, fds.child);
    self.server.init(io, fds.parent);
    self.ctx = .{ .io = io, .endpoint = &self.server, .opts = opts };
    self.thread = try std.Thread.spawn(.{}, ipcThreadMain, .{&self.ctx});
}

pub fn closeAndJoin(self: *Self) !void {
    const thread = self.thread orelse return;
    self.thread = null;

    self.client.file.close(self.ctx.io);
    thread.join();

    return self.ctx.result;
}

pub fn deinit(self: *Self) void {
    self.closeAndJoin() catch {};
}

fn ipcThreadMain(ctx: *ServerCtx) void {
    defer ctx.endpoint.file.close(ctx.io);
    ctx.result = preview.run(ctx.io, &ctx.endpoint.connection, ctx.opts);
}
