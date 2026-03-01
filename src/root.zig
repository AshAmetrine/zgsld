const std = @import("std");
const build_options = @import("build_options");
const logging = @import("logging.zig");
const session_manager = if (build_options.standalone) @import("manager.zig");
const worker = if (build_options.standalone) @import("worker.zig");
const preview = @import("preview.zig");

const log = std.log.scoped(.zgsld);

pub const initZgsldLog = logging.initZgsldLog;
pub const logFn = logging.logFn;

pub const Ipc = @import("Ipc");
const IpcConnection = Ipc.Connection;

fn appendShellQuotedArg(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    arg: []const u8,
) !void {
    try buf.append(allocator, '\'');
    for (arg) |ch| {
        if (ch == '\'') {
            try buf.appendSlice(allocator, "'\"'\"'");
        } else {
            try buf.append(allocator, ch);
        }
    }
    try buf.append(allocator, '\'');
}

pub const Zgsld = struct {
    allocator: std.mem.Allocator,
    vtable: *const VTable,

    pub const Config = @import("Config.zig");

    /// Context passed to `VTable.run`.
    pub const GreeterContext = struct {
        /// Allocator supplied to `Zgsld.init`.
        allocator: std.mem.Allocator,
        /// IPC channel to zgsld for IPC communication.
        ipc: *IpcConnection,
    };

    /// Context passed to `VTable.configure` in standalone mode.
    pub const ConfigureContext = struct {
        /// Allocator supplied to `Zgsld.init` for temporary allocations.
        allocator: std.mem.Allocator,
        /// zgsld-managed arena for values assigned into `config`.
        arena_allocator: std.mem.Allocator,
        /// Mutable config initialized from build defaults.
        config: *Config,
    };

    /// Integration callbacks implemented by the greeter.
    pub const VTable = struct {
        /// Runs the greeter
        run: *const fn (ctx: GreeterContext) anyerror!void,
        /// Optional standalone hook to override `Config`.
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

    /// Runs the greeter against a mock IPC daemon.
    pub fn runPreview(self: Zgsld, opts: preview.Options) !void {
        var ctx: preview.Runtime.ServerCtx = undefined;
        var runtime = try preview.Runtime.init(&ctx, opts);
        defer runtime.deinit();

        try self.vtable.run(.{
            .allocator = self.allocator,
            .ipc = &runtime.ipc_conn,
        });

        try runtime.closeAndJoin();
    }

    fn runStandalone(self: Zgsld) !void {
        if (build_options.standalone) {
            const self_exe_path_z: [:0]const u8 = std.mem.span(std.os.argv[0]);

            var zgsld_config = Config{};
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
            log.debug("Greeter User: {s}", .{zgsld_config.greeter.user});
            log.debug("User Session PAM Service Name: {s}", .{zgsld_config.session.service_name});
            log.debug("Greeter PAM Service Name: {s}", .{zgsld_config.greeter.service_name});

            const argv = std.os.argv;
            var cmd_buf: std.ArrayList(u8) = .empty;
            defer cmd_buf.deinit(self.allocator);

            for (argv, 0..) |arg, i| {
                if (i != 0) {
                    try cmd_buf.append(self.allocator, ' ');
                }
                try appendShellQuotedArg(&cmd_buf, self.allocator, std.mem.span(arg));
            }
            const greeter_cmd = cmd_buf.items;
            log.debug("Greeter Cmd: {s}", .{greeter_cmd});

            try session_manager.run(.{
                .allocator = self.allocator,
                .self_exe_path = self_exe_path_z,
                .greeter_cmd = greeter_cmd,
                .config = zgsld_config,
            });
        } else {
            unreachable;
        }
    }
};
