const std = @import("std");
const build_options = @import("build_options");
pub const logging = @import("logging.zig");
const session_manager = if (build_options.standalone) @import("session_manager.zig") else struct {};
const session_worker = if (build_options.standalone) @import("session_worker.zig") else struct {};
const utils = @import("utils.zig");

const log = std.log.scoped(.zgsld);

pub const initZgsldLog = logging.initZgsldLog;
pub const logFn = logging.logFn;

pub const ipc = @import("ipc.zig");
const Ipc = ipc.Ipc;

pub const ZgsldConfig = @import("config.zig").Config;

pub const GreeterContext = struct {
    allocator: std.mem.Allocator,
    ipc: *Ipc,
};

pub const ConfigureContext = struct {
    allocator: std.mem.Allocator,
    cfg: *ZgsldConfigWriter,
};

pub const ZgsldConfigWriter = struct {
    allocator: std.mem.Allocator,
    config: *ZgsldConfig,
    owned_service_name: ?[]u8 = null,
    owned_greeter_user: ?[]u8 = null,
    owned_x11_cmd: if (build_options.x11_support) ?[]u8 else void = if (build_options.x11_support) null else {},

    pub fn init(allocator: std.mem.Allocator, config: *ZgsldConfig) ZgsldConfigWriter {
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *ZgsldConfigWriter) void {
        if (self.owned_service_name) |name| self.allocator.free(name);
        if (self.owned_greeter_user) |user| self.allocator.free(user);
        if (build_options.x11_support) {
            if (self.owned_x11_cmd) |cmd| self.allocator.free(cmd);
        }
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

    pub fn setX11Command(self: *ZgsldConfigWriter, cmd: []const u8) !void {
        if (!build_options.x11_support) unreachable;
        try self.setOwned(&self.config.x11.cmd, &self.owned_x11_cmd, cmd);
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

pub const ZgsldVTable = struct {
    run: *const fn (ctx: GreeterContext) anyerror!void,
    configure: ?*const fn (ctx: ConfigureContext) anyerror!void = null,
};

pub const Zgsld = struct {
    allocator: std.mem.Allocator,
    vtable: ZgsldVTable,

    pub fn init(allocator: std.mem.Allocator, vtable: ZgsldVTable) Zgsld {
        return .{
            .allocator = allocator,
            .vtable = vtable,
        };
    }

    pub fn run(self: Zgsld) !void {
        if (build_options.standalone and utils.isSessionWorker()) {
            log.info("Session Worker Started", .{});
            try session_worker.runFromArgs(self.allocator);
            return;
        }

        var sock_fd: ?std.posix.fd_t = null;
        if (std.posix.getenv("ZGSLD_SOCK")) |sock| {
            sock_fd = try std.fmt.parseInt(std.posix.fd_t, sock, 10);
        }

        if (sock_fd) |fd| {
            var ipc_conn = Ipc.initFromFd(fd);
            defer ipc_conn.deinit();

            try self.vtable.run(.{
                .allocator = self.allocator,
                .ipc = &ipc_conn,
            });

            return;
        }

        if (build_options.standalone) {
            log.info("Session Manager Started", .{});
            try self.runStandalone();
        } else {
            log.err("Is the greeter being run by zgsld?", .{});
            return error.MissingZgsldSock;
        }
    }

    fn runStandalone(self: Zgsld) !void {
        if (build_options.standalone) {
            const self_exe_path_z: [:0]const u8 = std.mem.span(std.os.argv[0]);

            var zgsld_config = ZgsldConfig{};
            var writer = ZgsldConfigWriter.init(self.allocator, &zgsld_config);
            defer writer.deinit();

            if (self.vtable.configure) |configure| {
                try configure(.{
                    .allocator = self.allocator,
                    .cfg = &writer,
                });
            }

            log.debug("Greeter Path: {s}", .{self_exe_path_z});
            log.debug("Greeter User: {s}", .{zgsld_config.greeter_user});
            log.debug("Pam Service Name: {s}", .{zgsld_config.service_name});

            const greeter_argv_buf = try self.allocator.alloc(?[*:0]const u8, std.os.argv.len + 1);
            defer self.allocator.free(greeter_argv_buf);
            greeter_argv_buf[std.os.argv.len] = null;
            for (std.os.argv, 0..) |arg, i| greeter_argv_buf[i] = arg;
            const greeter_argv = greeter_argv_buf[0..std.os.argv.len :null];

            try session_manager.run(.{
                .self_exe_path = self_exe_path_z,
                .greeter_argv = greeter_argv,
                .config = zgsld_config,
            });
        } else {
            unreachable;
        }
    }
};
