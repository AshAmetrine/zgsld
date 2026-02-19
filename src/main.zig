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
;

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
    var config = conf_ini.readFileToStruct(config_path, .{}) catch |err| switch (err) {
        error.FileNotFound => blk: {
            log.debug("No Config File Found", .{});
            break :blk ZgsldConfig{};
        },
        else => return err,
    };

    if (res.args.vt) |vt| config.vt = vt;

    if (config.greeter_cmd) |cmd| {
        if (cmd.len == 0) return error.NullGreeterCmd;

        const greeter_argv = [_:null]?[*:0]const u8{
            "/bin/sh",
            "-c",
            cmd.ptr,
        };

        const self_exe_path_z: [:0]const u8 = std.mem.span(std.os.argv[0]);
        try session_manager.run(.{
            .self_exe_path = self_exe_path_z,
            .greeter_argv = &greeter_argv,
            .config = config,
        });
        return;
    } else {
        return error.NullGreeterCmd;
    }
}
