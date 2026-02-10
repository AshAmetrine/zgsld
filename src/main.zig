const std = @import("std");
const build_options = @import("build_options");
const ipc = @import("ipc.zig");
const session_manager = @import("session_manager.zig");
const session_worker = @import("session_worker.zig");

const clap = @import("clap");

const log = std.log.scoped(.zgsld);

const clap_param_str =
    \\-h, --help                Shows all commands.
    \\-v, --version             Shows the version of zgsld.
    \\-c, --config <str>        Path to ZGSLD config
    \\--vt <u8>                 Sets the VT number
    \\--greeter-cmd <str>       Sets the greeter command
    \\<str>...                  Greeter Command with args (use `--` before these)
;

const GreeterArgv = struct {
    argv_ptrs: [:null]const ?[*:0]const u8,
    arena: std.heap.ArenaAllocator,

    fn deinit(self: *GreeterArgv) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const is_worker = isSessionWorker();

    var sock_fd: ?std.posix.fd_t = null;
    if (std.posix.getenv("ZGSLD_SOCK")) |sock| {
        sock_fd = try std.fmt.parseInt(std.posix.fd_t, sock, 10);
    }

    if (sock_fd) |fd| {
        if (!is_worker) {
            log.err("ZGSLD_SOCK set without --session-worker", .{});
            return error.UnexpectedSessionWorker;
        }

        var ipc_conn = ipc.Ipc.initFromFd(fd);
        defer ipc_conn.deinit();

        const service_name = std.posix.getenv("ZGSLD_SERVICE_NAME") orelse build_options.service_name;
        log.info("Session Worker Started", .{});
        _ = try session_worker.run(allocator, .{
            .service_name = service_name,
            .ipc_conn = &ipc_conn,
        });
        return;
    }

    if (is_worker) {
        log.err("Session worker requires ZGSLD_SOCK", .{});
        return error.MissingZgsldSock;
    }

    const params = comptime clap.parseParamsComptime(clap_param_str);
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.reportToFile(.stderr(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try clap.helpToFile(.stderr(), clap.Help, &params, .{});
        std.process.exit(0);
    }
    if (res.args.version != 0) {
        var stderr_buf: [1024]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
        const stderr = &stderr_writer.interface;

        try stderr.writeAll("zgsld version " ++ build_options.version ++ "\n");
        try stderr.flush();
        std.process.exit(0);
    }

    if (res.args.config) |config_path| {
        // TODO: check config_path
        _ = config_path;
    } else {
        // TODO: check default config path
    }

    const greeter_path = res.args.@"greeter-cmd".?;
    const greeter_args = res.positionals[0];

    var greeter_argv = try buildGreeterArgv(allocator, greeter_path, greeter_args);
    defer greeter_argv.deinit();

    const self_exe_path_z: [:0]const u8 = std.mem.span(std.os.argv[0]);
    try session_manager.run(.{
        .self_exe_path = self_exe_path_z,
        .greeter_argv = greeter_argv.argv_ptrs,
        .greeter_user = build_options.greeter_user,
        .service_name = build_options.service_name,
        .vt = res.args.vt,
    });
}

fn isSessionWorker() bool {
    var args = std.process.args();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, "--session-worker", arg)) return true;
    }
    return false;
}

fn buildGreeterArgv(
    allocator: std.mem.Allocator,
    command: []const u8,
    args: []const []const u8,
) !GreeterArgv {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    const argv_len = args.len + 1;
    var argv_ptrs = try arena_allocator.alloc(?[*:0]const u8, argv_len + 1);
    argv_ptrs[argv_len] = null;

    const command_z = try arena_allocator.dupeZ(u8, command);
    argv_ptrs[0] = command_z;

    for (args, 1..) |arg, i| {
        const arg_z = try arena_allocator.dupeZ(u8, arg);
        argv_ptrs[i] = arg_z;
    }

    return .{
        .argv_ptrs = argv_ptrs[0..argv_len :null],
        .arena = arena,
    };
}
