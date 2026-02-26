const std = @import("std");
const build_options = @import("build_options");
const logging = @import("logging.zig");
const session_manager = if (build_options.standalone) @import("manager.zig");
const worker = if (build_options.standalone) @import("worker.zig");

const log = std.log.scoped(.zgsld);

pub const initZgsldLog = logging.initZgsldLog;
pub const logFn = logging.logFn;

pub const Ipc = @import("Ipc");
const IpcConnection = Ipc.Connection;

pub const Zgsld = struct {
    allocator: std.mem.Allocator,
    vtable: *const VTable,

    pub const Config = @import("config.zig").Config;

    pub const GreeterContext = struct {
        allocator: std.mem.Allocator,
        ipc: *IpcConnection,
    };

    pub const ConfigureContext = struct {
        allocator: std.mem.Allocator,
        arena_allocator: std.mem.Allocator,
        config: *Config,
    };

    pub const VTable = struct {
        run: *const fn (ctx: GreeterContext) anyerror!void,
        configure: ?*const fn (ctx: ConfigureContext) anyerror!void = null,
    };

    pub fn init(allocator: std.mem.Allocator, vtable: *const VTable) Zgsld {
        return .{
            .allocator = allocator,
            .vtable = vtable,
        };
    }

    pub fn run(self: Zgsld) !void {
        if (build_options.standalone and worker.isSessionWorker()) {
            var runtime = worker.WorkerRuntime.init(.{ .allocator = self.allocator });
            try runtime.run();
            return;
        }

        var sock_fd: ?std.posix.fd_t = null;
        if (std.posix.getenv("ZGSLD_SOCK")) |sock| {
            sock_fd = try std.fmt.parseInt(std.posix.fd_t, sock, 10);
        }

        if (sock_fd) |fd| {
            var ipc_conn = IpcConnection.initFromFd(fd);
            defer ipc_conn.deinit();

            try self.vtable.run(.{
                .allocator = self.allocator,
                .ipc = &ipc_conn,
            });

            return;
        }

        if (build_options.standalone) {
            try self.runStandalone();
        } else {
            log.err("Is the greeter being run by zgsld?", .{});
            return error.MissingZgsldSock;
        }
    }

    fn runStandalone(self: Zgsld) !void {
        if (build_options.standalone) {
            const self_exe_path_z: [:0]const u8 = std.mem.span(std.os.argv[0]);

            var zgsld_config = Zgsld.Config{};
            var configure_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer configure_arena.deinit();

            if (self.vtable.configure) |configure| {
                try configure(.{
                    .allocator = self.allocator,
                    .arena_allocator = configure_arena.allocator(),
                    .config = &zgsld_config,
                });
            }

            log.debug("Greeter Path: {s}", .{self_exe_path_z});
            log.debug("Greeter User: {s}", .{zgsld_config.greeter_user});
            log.debug("PAM Service Name: {s}", .{zgsld_config.service_name});
            log.debug("Greeter PAM Service Name: {s}", .{zgsld_config.greeter_service_name});

            const argv = std.os.argv;

            var total: usize = 0;
            for (argv) |arg| {
                total += std.mem.span(arg).len;
            }

            if (argv.len > 1) {
                total += argv.len - 1;
            }

            var buf = try self.allocator.alloc(u8, total);
            defer self.allocator.free(buf);

            var idx: usize = 0;
            for (argv, 0..) |arg, i| {
                if (i != 0) {
                    buf[idx] = ' ';
                    idx += 1;
                }
                const s = std.mem.span(arg);
                @memcpy(buf[idx .. idx + s.len], s);
                idx += s.len;
            }
            const greeter_cmd: []const u8 = buf[0..idx];

            try session_manager.run(.{
                .self_exe_path = self_exe_path_z,
                .greeter_cmd = greeter_cmd,
                .config = zgsld_config,
            });
        } else {
            unreachable;
        }
    }
};
