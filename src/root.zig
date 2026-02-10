const std = @import("std");
const build_options = @import("build_options");
const session_manager_mod = if (build_options.standalone) @import("session_manager.zig") else struct {};
const session_worker_mod = if (build_options.standalone) @import("session_worker.zig") else struct {};
const utils = @import("utils.zig");

pub const session_manager = session_manager_mod;
pub const session_worker = session_worker_mod;

const ipc = @import("ipc.zig");
pub const Ipc = ipc.Ipc;
pub const IpcEvent = ipc.IpcEvent;
pub const IPC_IO_BUF_SIZE = ipc.IPC_IO_BUF_SIZE;
pub const GREETER_BUF_SIZE = ipc.GREETER_BUF_SIZE;
pub const PAM_CONV_BUF_SIZE = ipc.PAM_CONV_BUF_SIZE;
pub const PAM_START_BUF_SIZE = ipc.PAM_START_BUF_SIZE;
pub const SessionInfo = ipc.SessionInfo;

const log = std.log.scoped(.zgsld);

pub const ZgsldConfig = struct {
    service_name: []const u8 = build_options.service_name,
    greeter_user: []const u8 = build_options.greeter_user,
    vt: ?u8 = build_options.vt,
};

pub const GreeterContext = struct {
    allocator: std.mem.Allocator,
    ipc: *ipc.Ipc,
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

pub const ZgsldVTable = struct {
    run: *const fn (ctx: GreeterContext) anyerror!void,
    configure: ?*const fn (ctx: ConfigureContext) anyerror!void = null,
};

const GreeterSettings = struct {
    greeter_user: []const u8,
    service_name: []const u8,
    vt: ?u8,
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
        var sock_fd: ?std.posix.fd_t = null;
        if (std.posix.getenv("ZGSLD_SOCK")) |sock| {
            sock_fd = try std.fmt.parseInt(std.posix.fd_t, sock, 10);
        }

        if (sock_fd) |fd| {
            var ipc_conn = Ipc.initFromFd(fd);
            defer ipc_conn.deinit();

            try self.runWithIpc(&ipc_conn);
            return;
        }

        if (build_options.standalone) {
            log.info("Session Manager Started", .{});
            try self.runStandalone();
        } else {
            log.err("Is the greeter being run by zgsld?", .{});
            unreachable;
        }
    }

    fn runWithIpc(self: Zgsld, ipc_conn: *Ipc) !void {
        if (build_options.standalone and utils.isSessionWorker()) {
            const service_name = std.posix.getenv("ZGSLD_SERVICE_NAME") orelse build_options.service_name;
            log.info("Session Worker Started", .{});
            _ = try session_worker_mod.run(self.allocator, .{
                .service_name = service_name,
                .ipc_conn = ipc_conn,
            });
            return;
        }

        log.info("Greeter Started", .{});

        try self.vtable.run(.{
            .allocator = self.allocator,
            .ipc = ipc_conn,
        });

        log.info("Greeter Exiting...", .{});
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

            const settings = greeterSettingsFromConfig(zgsld_config);

            log.debug("Greeter Path: {s}", .{self_exe_path_z});
            log.debug("Greeter User: {s}", .{settings.greeter_user});
            log.debug("Pam Service Name: {s}", .{settings.service_name});

            const greeter_argv_buf = try self.allocator.alloc(?[*:0]const u8, std.os.argv.len + 1);
            defer self.allocator.free(greeter_argv_buf);
            greeter_argv_buf[std.os.argv.len] = null;
            for (std.os.argv, 0..) |arg, i| greeter_argv_buf[i] = arg;
            const greeter_argv = greeter_argv_buf[0..std.os.argv.len :null];

            try runSessionManager(self_exe_path_z, greeter_argv, settings);
        } else {
            unreachable;
        }
    }

    fn greeterSettingsFromConfig(config: ZgsldConfig) GreeterSettings {
        return .{
            .greeter_user = config.greeter_user,
            .service_name = config.service_name,
            .vt = @as(?u8, config.vt),
        };
    }

    fn runSessionManager(
        self_exe_path_z: [:0]const u8,
        greeter_argv: [:null]const ?[*:0]const u8,
        settings: GreeterSettings,
    ) !void {
        if (build_options.standalone) {
            if (settings.vt) |vt| {
                log.debug("VT: {d}", .{vt});
            }
            try session_manager_mod.run(.{
                .self_exe_path = self_exe_path_z,
                .greeter_argv = greeter_argv,
                .greeter_user = settings.greeter_user,
                .service_name = settings.service_name,
                .vt = settings.vt,
            });
        } else {
            unreachable;
        }
    }
};
