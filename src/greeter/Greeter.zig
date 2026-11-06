const std = @import("std");
const build_options = @import("build_options");
const Config = @import("common").Config;
const ProcessContext = @import("common").ProcessContext;
const daemon = if (build_options.embed_daemon) @import("daemon") else void;
const ipc = @import("ipc");
const preview = @import("preview");
const PreviewRuntime = @import("../preview/Runtime.zig");
const ZgsldConnector = @import("ZgsldConnector.zig");

const IpcConnection = ipc.Connection;
const log = std.log.scoped(.zgsld);
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
pub const RunContext = struct {
    /// IPC connection to the daemon.
    ipc: *IpcConnection,
    gpa: std.mem.Allocator,
    io: std.Io,
    args: std.process.Args,
    environ_map: *const std.process.Environ.Map,
};

/// Context passed to `VTable.configure` when starting the embedded daemon.
pub const ConfigureContext = struct {
    /// zgsld-managed arena for values assigned into `config`.
    arena_allocator: std.mem.Allocator,
    /// Mutable config initialized from build defaults.
    config: *Config,
    gpa: std.mem.Allocator,
    io: std.Io,
    args: std.process.Args,
    environ_map: *const std.process.Environ.Map,
};

/// Integration callbacks implemented by the greeter.
pub const VTable = struct {
    /// Runs the greeter
    run: *const fn (ctx: RunContext) anyerror!void,
    /// Optional hook to override the embedded daemon's configuration.
    configure: ?*const fn (ctx: ConfigureContext) anyerror!void = null,
};

pub const Options = struct {
    vtable: *const VTable,
};

pub fn init(process: ProcessContext, opts: Options) Self {
    return .{
        .vtable = opts.vtable,
        .process = process,
    };
}

pub const RunOptions = struct {
    ipc_conn: ?*IpcConnection = null,
};

pub fn run(self: Self, opts: RunOptions) !void {
    if (build_options.embed_daemon) {
        if (try daemon.runWorkerIfRequested(self.process)) return;
    }

    if (opts.ipc_conn) |connection| {
        return self.vtable.run(self.greeterContext(connection));
    }

    var connector = ZgsldConnector.init(self.process);
    defer connector.deinit();
    if (try connector.connect()) |transport| {
        var connection = IpcConnection.init(transport, .{});
        return self.vtable.run(self.greeterContext(&connection));
    }

    if (build_options.embed_daemon) {
        try self.runDaemon();
    } else {
        log.err("Is the greeter being run by zgsld?", .{});
        return error.MissingZgsldSock;
    }
}

/// Runs the greeter against a mock IPC daemon.
pub fn runPreview(self: Self, opts: preview.Options) !void {
    var runtime: PreviewRuntime = undefined;
    try runtime.init(self.process.io, opts);
    defer runtime.deinit();

    try self.vtable.run(self.greeterContext(&runtime.client.connection));

    try runtime.closeAndJoin();
}

fn runDaemon(self: Self) !void {
    std.debug.assert(build_options.embed_daemon);

    var zgsld_config = Config{};
    var configure_arena = std.heap.ArenaAllocator.init(self.process.gpa);
    defer configure_arena.deinit();

    if (self.vtable.configure) |configure| {
        try configure(.{
            .arena_allocator = configure_arena.allocator(),
            .config = &zgsld_config,
            .gpa = self.process.gpa,
            .io = self.process.io,
            .args = self.process.args,
            .environ_map = self.process.environ_map,
        });
    }

    var cmd_buf: std.ArrayList(u8) = .empty;
    defer cmd_buf.deinit(self.process.gpa);

    if (zgsld_config.greeter.command) |greeter_wrapper| {
        try cmd_buf.appendSlice(self.process.gpa, greeter_wrapper);
        if (greeter_wrapper.len != 0 and greeter_wrapper[greeter_wrapper.len - 1] != ' ') {
            try cmd_buf.append(self.process.gpa, ' ');
        }
    }

    var self_exe_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const self_exe_path_len = try std.process.executablePath(self.process.io, &self_exe_path_buf);
    const self_exe_path = self_exe_path_buf[0..self_exe_path_len];

    try appendShellQuotedArg(&cmd_buf, self.process.gpa, self_exe_path);

    var args_iter = self.process.args.iterate();
    _ = args_iter.skip();
    while (args_iter.next()) |arg| {
        try cmd_buf.append(self.process.gpa, ' ');
        try appendShellQuotedArg(&cmd_buf, self.process.gpa, arg);
    }

    zgsld_config.greeter.command = cmd_buf.items;

    log.debug("Greeter Cmd: {s}", .{cmd_buf.items});
    log.debug("Greeter Path: {s}", .{self_exe_path});
    log.debug("Greeter User: {s}", .{zgsld_config.greeter.user});
    log.debug("User Session PAM Service Name: {s}", .{zgsld_config.session.service_name});
    log.debug("Greeter PAM Service Name: {s}", .{
        zgsld_config.greeter.service_name orelse zgsld_config.session.service_name,
    });

    try daemon.run(self.process, .{
        .config = zgsld_config,
    });
}

fn greeterContext(self: Self, ipc_conn: *IpcConnection) RunContext {
    return .{
        .ipc = ipc_conn,
        .gpa = self.process.gpa,
        .io = self.process.io,
        .args = self.process.args,
        .environ_map = self.process.environ_map,
    };
}
