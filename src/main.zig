const std = @import("std");
const build_options = @import("build_options");
const session_manager = @import("manager.zig");
const worker = @import("worker.zig");
const Config = @import("Config.zig");

const clap = @import("clap");
const zigini = @import("zigini");

const log = std.log.scoped(.zgsld);

pub const std_options: std.Options = .{ .logFn = @import("logging.zig").logFn };

const clap_param_str =
    \\-h, --help                Shows all commands.
    \\-v, --version             Shows the version of zgsld.
    \\-c, --config <str>        Path to ZGSLD config
    \\--vt <u8>                 Sets the VT number
    \\--no-vt                   Unset VT and use current controlling TTY
;

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    if (worker.isSessionWorker()) {
        var runtime = worker.WorkerRuntime.init(.{ .allocator = allocator });
        try runtime.run();
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

    var conf_ini = zigini.Ini(Config).init(allocator);
    defer conf_ini.deinit();

    const config_path = res.args.config orelse "/etc/zgsld/zgsld.ini";
    var config = conf_ini.readFileToStruct(config_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            log.err("Config file not found: {s}", .{config_path});
            return error.MissingConfig;
        },
        else => return err,
    };

    if (res.args.@"no-vt" != 0 and res.args.vt != null) {
        return error.ConflictingVtArgs;
    }
    if (res.args.@"no-vt" != 0) {
        config.vt = null;
    } else if (res.args.vt) |vt| {
        config.vt = vt;
    }

    const self_exe_path_z: [:0]const u8 = std.mem.span(std.os.argv[0]);
    try session_manager.run(.{
        .allocator = allocator,
        .self_exe_path = self_exe_path_z,
        .config = config,
    });
}
