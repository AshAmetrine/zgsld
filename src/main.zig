const std = @import("std");
const build_options = @import("build_options");
const clap = @import("clap");
const session_manager = @import("session_manager.zig");
const session_worker = @import("session_worker.zig");
const ipc = @import("ipc");
const utils = @import("utils.zig");

const GreeterCommand = struct {
    path: [:0]const u8,
    argv: []const [:0]const u8,
    argv_ptrs: []?[*:0]const u8,
    allocator: std.mem.Allocator,

    fn deinit(self: *GreeterCommand) void {
        for (self.argv) |arg| self.allocator.free(arg);
        self.allocator.free(self.argv);
        self.allocator.free(self.argv_ptrs);
        self.* = undefined;
    }
};

fn buildGreeterCommand(allocator: std.mem.Allocator, res: anytype) !GreeterCommand {
    const greeter_cmd = res.args.@"greeter-cmd" orelse return error.MissingGreeterCommand;
    const greeter_args = res.positionals[0];

    const argc = 1 + greeter_args.len;
    var argv = try allocator.alloc([:0]const u8, argc);
    var filled: usize = 0;
    errdefer {
        for (argv[0..filled]) |arg| allocator.free(arg);
        allocator.free(argv);
    }

    argv[0] = try allocator.dupeZ(u8, greeter_cmd);
    filled = 1;
    for (greeter_args, 0..) |arg, i| {
        argv[i + 1] = try allocator.dupeZ(u8, arg);
        filled += 1;
    }

    var argv_ptrs = try allocator.alloc(?[*:0]const u8, argv.len + 1);
    errdefer allocator.free(argv_ptrs);
    for (argv, 0..) |arg, i| argv_ptrs[i] = arg.ptr;
    argv_ptrs[argv.len] = null;

    return GreeterCommand{
        .path = argv[0],
        .argv = argv,
        .argv_ptrs = argv_ptrs,
        .allocator = allocator,
    };
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    if (std.posix.getenv("ZGSLD_SOCK")) |sock| {
        const sock_fd = try std.fmt.parseInt(std.posix.fd_t, sock, 10);
        var ipc_conn = ipc.Ipc.initFromFd(sock_fd);
        defer ipc_conn.deinit();

        _ = try session_worker.run(allocator, .{ 
            .service_name = build_options.service_name, 
            .ipc_conn = &ipc_conn, 
        });
        return;
    }

    const paramStr =
        \\-h, --help                Shows all commands.
        \\-v, --version             Shows the version of zgsld.
        \\--vt <u8>                 Sets the VT number
        \\--greeter-cmd <str>       Sets the greeter command
        \\<str>...                  Greeter args (use `--` before these)
    ;

    const params = comptime clap.parseParamsComptime(paramStr);

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag, .allocator = allocator,
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

    var greeter_cmd = try buildGreeterCommand(allocator, res);
    defer greeter_cmd.deinit();

    const self_exe_path_z = try utils.selfExePathAllocZ(allocator);
    defer allocator.free(self_exe_path_z);

    try session_manager.run(.{
        .greeter_argv = greeter_cmd.argv_ptrs,
        .greeter_user = build_options.greeter_user,
        .self_exe_path = self_exe_path_z,
        .vt = res.args.vt,
    });
}
