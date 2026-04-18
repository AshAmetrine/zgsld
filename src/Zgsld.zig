const std = @import("std");
const build_options = @import("build_options");
const fd_utils = @import("fd.zig");
const Config = @import("Config.zig");
const daemon = @import("daemon.zig");
const Ipc = @import("Ipc");
const preview_mod = @import("preview.zig");
const ProcessContext = @import("ProcessContext.zig");

const IpcConnection = Ipc.Connection;
const log = std.log.scoped(.zgsld);
const worker_runtime = daemon.worker.runtime;
const Self = @This();

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

vtable: *const VTable,
process: ProcessContext,

/// Context passed to `VTable.run`.
pub const GreeterContext = struct {
    /// IPC channel to zgsld for IPC communication.
    ipc: *IpcConnection,
    /// Process state supplied by the host entrypoint.
    process: ProcessContext,
};

/// Context passed to `VTable.configure` in standalone mode.
pub const ConfigureContext = struct {
    /// zgsld-managed arena for values assigned into `config`.
    arena_allocator: std.mem.Allocator,
    /// Mutable config initialized from build defaults.
    config: *Config,
    /// Process state supplied by the host entrypoint.
    process: ProcessContext,
};

/// Integration callbacks implemented by the greeter.
pub const VTable = struct {
    /// Runs the greeter
    run: *const fn (ctx: GreeterContext) anyerror!void,
    /// Optional standalone hook to override `Config`.
    configure: ?*const fn (ctx: ConfigureContext) anyerror!void = null,
};

pub const Options = struct {
    vtable: *const VTable,
    process: ProcessContext,
};

pub fn init(opts: Options) Self {
    return .{
        .vtable = opts.vtable,
        .process = opts.process,
    };
}

pub fn run(self: Self) !void {
    if (build_options.standalone and daemon.worker.isSessionWorker(self.process.args)) {
        try worker_runtime.run(self.process);
        return;
    }

    var sock_fd: ?std.posix.fd_t = null;
    if (self.process.environ_map.get("ZGSLD_SOCK")) |sock| {
        sock_fd = try std.fmt.parseInt(std.posix.fd_t, sock, 10);
    }

    if (sock_fd) |fd| {
        try fd_utils.setCloseOnExec(fd);

        var ipc_conn = IpcConnection.initFromFd(fd);
        defer ipc_conn.deinit(self.process.io);

        try self.vtable.run(self.greeterContext(&ipc_conn));

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
pub fn runPreview(self: Self, opts: preview_mod.api.Options) !void {
    var ctx: preview_mod.Runtime.ServerCtx = undefined;
    var runtime = try preview_mod.Runtime.init(self.process.io, &ctx, opts);
    defer runtime.deinit();

    try self.vtable.run(self.greeterContext(&runtime.ipc_conn));

    try runtime.closeAndJoin();
}

fn runStandalone(self: Self) !void {
    if (!build_options.standalone) unreachable;

    var zgsld_config = Config{};
    var configure_arena = std.heap.ArenaAllocator.init(self.process.gpa);
    defer configure_arena.deinit();

    if (self.vtable.configure) |configure| {
        try configure(self.configureContext(configure_arena.allocator(), &zgsld_config));
    }

    var cmd_buf: std.ArrayList(u8) = .empty;
    defer cmd_buf.deinit(self.process.gpa);

    if (zgsld_config.greeter.command) |greeter_wrapper| {
        try cmd_buf.appendSlice(self.process.gpa, greeter_wrapper);
        if (greeter_wrapper.len != 0 and greeter_wrapper[greeter_wrapper.len - 1] != ' ') {
            try cmd_buf.append(self.process.gpa, ' ');
        }
    }

    var self_exe_path_buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    const self_exe_path_len = try std.process.executablePath(self.process.io, &self_exe_path_buf);
    self_exe_path_buf[self_exe_path_len] = 0;
    const self_exe_path_z = self_exe_path_buf[0..self_exe_path_len :0];

    try appendShellQuotedArg(&cmd_buf, self.process.gpa, self_exe_path_z);

    var args_iter = self.process.args.iterate();
    _ = args_iter.skip();
    while (args_iter.next()) |arg| {
        try cmd_buf.append(self.process.gpa, ' ');
        try appendShellQuotedArg(&cmd_buf, self.process.gpa, arg);
    }

    const greeter_cmd = try cmd_buf.toOwnedSliceSentinel(self.process.gpa, 0);
    zgsld_config.greeter.command = greeter_cmd;

    log.debug("Greeter Cmd: {s}", .{greeter_cmd});
    log.debug("Greeter Path: {s}", .{self_exe_path_z});
    log.debug("Greeter User: {s}", .{zgsld_config.greeter.user});
    log.debug("User Session PAM Service Name: {s}", .{zgsld_config.session.service_name});
    log.debug("Greeter PAM Service Name: {s}", .{zgsld_config.greeter.service_name});

    try daemon.session_manager.run(.{
        .allocator = self.process.gpa,
        .self_exe_path = self_exe_path_z,
        .config = zgsld_config,
        .io = self.process.io,
        .env_map = self.process.environ_map,
    });
}

fn greeterContext(self: Self, ipc: *IpcConnection) GreeterContext {
    return .{
        .ipc = ipc,
        .process = self.process,
    };
}

fn configureContext(
    self: Self,
    arena_allocator: std.mem.Allocator,
    config: *Config,
) ConfigureContext {
    return .{
        .arena_allocator = arena_allocator,
        .config = config,
        .process = self.process,
    };
}
