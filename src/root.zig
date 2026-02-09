const std = @import("std");
const build_options = @import("build_options");

pub const ipc = @import("ipc.zig");
pub const Ipc = ipc.Ipc;
pub const IpcEvent = ipc.IpcEvent;
pub const IPC_IO_BUF_SIZE = ipc.IPC_IO_BUF_SIZE;
pub const GREETER_BUF_SIZE = ipc.GREETER_BUF_SIZE;
pub const PAM_CONV_BUF_SIZE = ipc.PAM_CONV_BUF_SIZE;
pub const SessionInfo = ipc.SessionInfo;

pub const ZgsldConfig = struct {
    service_name: []const u8 = build_options.service_name,
    greeter_user: []const u8 = build_options.greeter_user,
    vt: u8 = build_options.vt,
};

pub const GreeterContext = struct {
    allocator: std.mem.Allocator,
    ipc: *ipc.Ipc,
};

pub const ConfigureContext = struct {
    allocator: std.mem.Allocator,
    cfg: *ZgsldConfigWriter,
};

pub const GreeterApi = struct {
    run: *const fn (ctx: GreeterContext) anyerror!void,
    configure: ?*const fn (ctx: ConfigureContext) anyerror!void = null,
};

pub const ZgsldConfigWriter = struct {
    allocator: std.mem.Allocator,
    config: *ZgsldConfig,
    owned_service_name: ?[]u8 = null,
    owned_greeter_user: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, config: *ZgsldConfig) ZgsldConfigWriter {
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *ZgsldConfigWriter) void {
        if (self.owned_service_name) |name| self.allocator.free(name);
        if (self.owned_greeter_user) |user| self.allocator.free(user);
        self.* = undefined;
    }

    pub fn setServiceName(self: *ZgsldConfigWriter, name: []const u8) !void {
        try self.setOwned(&self.config.service_name, &self.owned_service_name, name);
    }

    pub fn setGreeterUser(self: *ZgsldConfigWriter, user: []const u8) !void {
        try self.setOwned(&self.config.greeter_user, &self.owned_greeter_user, user);
    }

    pub fn setVt(self: *ZgsldConfigWriter, vt: u8) void {
        self.config.vt = vt;
    }

    fn setOwned(
        self: *ZgsldConfigWriter,
        target: *[]const u8,
        owned: *?[]u8,
        value: []const u8,
    ) !void {
        const copy = try self.allocator.dupe(u8, value);
        if (owned.*) |prev| self.allocator.free(prev);
        owned.* = copy;
        target.* = copy;
    }
};
