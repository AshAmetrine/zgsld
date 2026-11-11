const std = @import("std");
const ipc = @import("ipc");
const Connector = @import("../Connector.zig");
const ProcessContext = @import("common").ProcessContext;
const fd_utils = @import("common").fd;

const Zgsld = @This();

interface: Connector = .{ .connect = connectInterface },

process: ProcessContext,
file: ?std.Io.File = null,

read_buf: [ipc.event_buf_size]u8 = undefined,
write_buf: [ipc.event_buf_size]u8 = undefined,
reader: std.Io.File.Reader = undefined,
writer: std.Io.File.Writer = undefined,

pub fn init(process: ProcessContext) Zgsld {
    return .{ .process = process };
}

pub fn deinit(self: *Zgsld) void {
    if (self.file) |file| file.close(self.process.io);
    self.file = null;
    std.crypto.secureZero(u8, &self.read_buf);
    std.crypto.secureZero(u8, &self.write_buf);
}

pub fn connect(self: *Zgsld) !?ipc.Transport {
    if (self.file == null) {
        const socket = self.process.environ_map.get("ZGSLD_SOCK") orelse
            return null;
        const fd = try std.fmt.parseInt(std.posix.fd_t, socket, 10);
        const file: std.Io.File = .{
            .handle = fd,
            .flags = .{ .nonblocking = false },
        };
        errdefer file.close(self.process.io);
        try fd_utils.setCloseOnExec(fd);

        self.reader = file.reader(self.process.io, &self.read_buf);
        self.writer = file.writer(self.process.io, &self.write_buf);
        self.file = file;
    }

    return .{
        .reader = &self.reader.interface,
        .writer = &self.writer.interface,
    };
}

fn connectInterface(interface: *Connector) !ipc.Transport {
    const self: *Zgsld = @fieldParentPtr("interface", interface);
    return (try self.connect()) orelse error.MissingZgsldSock;
}
