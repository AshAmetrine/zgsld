const std = @import("std");
const SocketPair = @import("common").SocketPair;
const fd_utils = @import("common").fd;
const Connection = @This();

io: std.Io,
file: std.Io.File,

pub const Role = enum(u8) { session, x11 };
pub const Message = enum(u8) { register, exited, stop, accepted, stopping };
pub const Packet = struct { message: Message, role: Role, pid: std.posix.pid_t = 0 };
const packet_size = 2 + @sizeOf(std.posix.pid_t);

pub fn socketPair() !SocketPair {
    var fds: [2]std.posix.fd_t = undefined;
    const socket_type = std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC;
    const rc = std.c.socketpair(std.posix.AF.UNIX, socket_type, 0, &fds);
    if (rc != 0) return std.posix.unexpectedErrno(std.c.errno(rc));
    return .{
        .parent = .{ .handle = fds[0], .flags = .{ .nonblocking = false } },
        .child = .{ .handle = fds[1], .flags = .{ .nonblocking = false } },
    };
}

pub fn init(io: std.Io, file: std.Io.File) !Connection {
    try fd_utils.setCloseOnExec(file.handle);
    return .{ .io = io, .file = file };
}

pub fn deinit(self: *Connection) void {
    self.file.close(self.io);
    self.* = undefined;
}

pub fn send(fd: std.posix.fd_t, packet: Packet) !void {
    var bytes: [packet_size]u8 = undefined;
    bytes[0] = @backingInt(packet.message);
    bytes[1] = @backingInt(packet.role);
    std.mem.writeInt(std.posix.pid_t, bytes[2..], packet.pid, .little);
    while (true) {
        const rc = std.c.send(
            fd,
            &bytes,
            bytes.len,
            std.posix.MSG.NOSIGNAL | std.posix.MSG.DONTWAIT,
        );
        if (rc == bytes.len) return;
        if (rc < 0 and std.c.errno(rc) == .INTR) continue;
        return error.ControlSendFailed;
    }
}

pub fn receive(fd: std.posix.fd_t, nonblocking: bool) !?Packet {
    var bytes: [packet_size + 1]u8 = undefined;
    const flags: c_int = if (nonblocking) std.posix.MSG.DONTWAIT else 0;
    const count = while (true) {
        const rc = std.c.recv(fd, &bytes, bytes.len, flags);
        if (rc >= 0) break rc;
        switch (std.c.errno(rc)) {
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .CONNRESET => return null,
            else => return error.ControlReceiveFailed,
        }
    };
    if (count == 0) return null;
    if (count != packet_size) return error.InvalidControlMessage;
    const message = std.enums.fromInt(Message, bytes[0]) orelse return error.InvalidControlMessage;
    const role = std.enums.fromInt(Role, bytes[1]) orelse return error.InvalidControlMessage;
    const pid = std.mem.readInt(std.posix.pid_t, bytes[2..packet_size], .little);
    const valid_pid = if (message == .register) pid > 0 else pid == 0;
    if (!valid_pid) return error.InvalidControlMessage;
    return .{ .message = message, .role = role, .pid = pid };
}

// Hold the child before exec until the manager knows its PID. If the worker
// exits before registration, closing the gate makes the child exit as well.
pub fn fork(self: *Connection, role: Role) !std.posix.pid_t {
    const gate = try SocketPair.init();
    const pid = std.c.fork();
    if (pid < 0) {
        const err = std.posix.unexpectedErrno(std.c.errno(pid));
        gate.parent.close(self.io);
        gate.child.close(self.io);
        return err;
    }
    if (pid == 0) {
        _ = std.c.close(gate.parent.handle);
        _ = std.c.close(self.file.handle);
        var ready: [1]u8 = undefined;
        while (true) {
            const rc = std.c.read(gate.child.handle, &ready, 1);
            if (rc < 0 and std.c.errno(rc) == .INTR) continue;
            if (rc != 1) std.c._exit(1);
            break;
        }
        _ = std.c.close(gate.child.handle);
        return 0;
    }
    defer gate.parent.close(self.io);
    defer gate.child.close(self.io);
    errdefer {
        _ = std.c.kill(pid, .KILL);
        var child = childFromPid(pid);
        self.wait(&child, role) catch {};
    }
    try send(self.file.handle, .{ .message = .register, .role = role, .pid = pid });
    const reply = try receive(self.file.handle, false) orelse return error.Shutdown;
    if (reply.role != role) return error.InvalidControlMessage;
    switch (reply.message) {
        .accepted => {},
        .stopping => return error.Shutdown,
        else => return error.InvalidControlMessage,
    }
    while (true) {
        const rc = std.c.send(gate.parent.handle, &[_]u8{1}, 1, std.posix.MSG.NOSIGNAL);
        if (rc < 0 and std.c.errno(rc) == .INTR) continue;
        if (rc != 1) return error.ChildSetupFailed;
        break;
    }
    return pid;
}

pub fn wait(self: *Connection, child: *std.process.Child, role: Role) !void {
    if (child.id == null) return;
    _ = try child.wait(self.io);
    try self.exited(role);
}

pub fn exited(self: *Connection, role: Role) !void {
    try send(self.file.handle, .{ .message = .exited, .role = role });
}

pub fn stop(self: *Connection, child: *std.process.Child, role: Role) void {
    if (child.id == null) return;
    send(self.file.handle, .{ .message = .stop, .role = role }) catch {
        _ = std.c.kill(child.id.?, .KILL);
    };
    self.wait(child, role) catch {};
}

pub fn childFromPid(pid: std.posix.pid_t) std.process.Child {
    return .{
        .id = pid,
        .thread_handle = {},
        .stdin = null,
        .stdout = null,
        .stderr = null,
        .request_resource_usage_statistics = false,
    };
}
