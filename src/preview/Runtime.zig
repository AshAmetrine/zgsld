const std = @import("std");
const ipc = @import("ipc");
const SocketPair = @import("common").SocketPair;
const preview = @import("preview");
const Self = @This();

client: Endpoint,
server: Endpoint,
io: std.Io,
opts: preview.Options,
thread: ?std.Thread,
result: anyerror!void,

const Endpoint = struct {
    file: std.Io.File,
    read_buf: [ipc.event_buf_size]u8 = undefined,
    write_buf: [ipc.event_buf_size]u8 = undefined,
    reader: std.Io.File.Reader,
    writer: std.Io.File.Writer,
    connection: ipc.Connection,

    fn init(self: *Endpoint, io: std.Io, file: std.Io.File, codec: *ipc.Codec) void {
        self.file = file;
        self.reader = file.reader(io, &self.read_buf);
        self.writer = file.writer(io, &self.write_buf);
        self.connection = ipc.Connection.init(.{
            .reader = &self.reader.interface,
            .writer = &self.writer.interface,
        }, .{ .codec = codec });
    }
};

pub fn init(self: *Self, io: std.Io, codecs: ?preview.Codecs, opts: preview.Options) !void {
    const fds = try SocketPair.init();
    errdefer fds.parent.close(io);
    errdefer fds.child.close(io);

    const selected = codecs orelse preview.Codecs{
        .greeter = ipc.Codec.binary,
        .daemon = ipc.Codec.binary,
    };
    self.client.init(io, fds.child, selected.greeter);
    self.server.init(io, fds.parent, selected.daemon);
    self.io = io;
    self.opts = opts;
    self.result = {};
    self.thread = try std.Thread.spawn(.{}, ipcThreadMain, .{self});
}

pub fn closeAndJoin(self: *Self) !void {
    const thread = self.thread orelse return;
    self.thread = null;

    self.shutdownSockets();
    thread.join();
    std.crypto.secureZero(u8, &self.client.read_buf);
    std.crypto.secureZero(u8, &self.client.write_buf);
    std.crypto.secureZero(u8, &self.server.read_buf);
    std.crypto.secureZero(u8, &self.server.write_buf);
    self.client.file.close(self.io);
    self.server.file.close(self.io);
    return self.result;
}

pub fn deinit(self: *Self) void {
    self.closeAndJoin() catch {};
}

fn ipcThreadMain(self: *Self) void {
    defer self.shutdownSockets();
    self.result = preview.run(self.io, &self.server.connection, self.opts);
}

fn shutdownSockets(self: *Self) void {
    // Wake either endpoint before joining; storage and files remain alive until then.
    _ = std.c.shutdown(self.client.file.handle, 2);
    _ = std.c.shutdown(self.server.file.handle, 2);
}
