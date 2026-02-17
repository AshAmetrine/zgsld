const std = @import("std");
const build_options = @import("build_options");
const session_manager = @import("session_manager.zig");
const session_worker = @import("session_worker.zig");
const utils = @import("utils.zig");
const ZgsldConfig = @import("config.zig").Config;

const clap = @import("clap");
const zigini = @import("zigini");

const log = std.log.scoped(.zgsld);

pub const std_options: std.Options = .{ .logFn = @import("logging.zig").logFn };

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

    if (utils.isSessionWorker()) {
        log.info("Session Worker Started", .{});
        try session_worker.runFromArgs(allocator);
        return;
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

    var conf_ini = zigini.Ini(ZgsldConfig).init(allocator);
    defer conf_ini.deinit();
   
    const config_path = res.args.config orelse "/etc/zgsld/zgsld.ini";
    var config = conf_ini.readFileToStruct(config_path,.{}) catch |err| switch (err) {
        error.FileNotFound => blk: {
            log.debug("No Config File Found", .{});
            break :blk ZgsldConfig{};
        },
        else => return err
    };

    if (res.args.vt) |vt| config.vt = vt;

    var greeter_argv: GreeterArgv = undefined;
    if (res.args.@"greeter-cmd") |greeter_path| {
        greeter_argv = try buildGreeterArgv(allocator, greeter_path, res.positionals[0]);
    } else if (config.greeter_cmd) |cmd| {
        if (cmd.len == 0) return error.NullGreeterCmd;
        greeter_argv = try buildGreeterArgvFromCommandLine(allocator, cmd, res.positionals[0]);
    } else {
        return error.NullGreeterCmd;
    }
    defer greeter_argv.deinit();

    const self_exe_path_z: [:0]const u8 = std.mem.span(std.os.argv[0]);
    try session_manager.run(.{
        .self_exe_path = self_exe_path_z,
        .greeter_argv = greeter_argv.argv_ptrs,
        .config = config,
    });
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

fn buildGreeterArgvFromCommandLine(
    allocator: std.mem.Allocator,
    command_line: []const u8,
    extra_args: []const []const u8,
) !GreeterArgv {
    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(allocator);

    var it = std.mem.tokenizeAny(u8, command_line, " \t\r\n");
    while (it.next()) |part| {
        try parts.append(allocator, part);
    }
    if (parts.items.len == 0) return error.NullGreeterCmd;

    if (extra_args.len != 0) {
        try parts.appendSlice(allocator, extra_args);
    }

    const cmd = parts.items[0];
    const args = parts.items[1..];
    return try buildGreeterArgv(allocator, cmd, args);
}
