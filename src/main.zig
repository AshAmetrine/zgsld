const std = @import("std");
const build_options = @import("build_options");
const daemon = @import("daemon");
const Config = daemon.Config;

const clap = @import("clap");
const zigini = @import("zigini");

const log = std.log.scoped(.zgsld);

const clap_param_str =
    \\-h, --help                Shows all commands.
    \\-v, --version             Shows the version of zgsld.
    \\-c, --config <str>        Path to ZGSLD config
    \\--vt <str>                Sets VT to a number, `current` or `unmanaged`
;

pub fn main(init: std.process.Init) !void {
    if (try daemon.runWorkerIfRequested(.fromInit(&init))) return;

    const allocator = init.gpa;
    const params = comptime clap.parseParamsComptime(clap_param_str);
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, init.minimal.args, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.reportToFile(init.io, .stderr(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.helpToFile(init.io, .stderr(), clap.Help, &params, .{});
    }
    if (res.args.version != 0) {
        var stderr_buf: [1024]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buf);
        const stderr = &stderr_writer.interface;

        try stderr.writeAll("zgsld " ++ build_options.version ++ "\n");
        try stderr.print("features: x11={s}\n", .{if (build_options.x11_support) "yes" else "no"});
        try stderr.flush();
        return;
    }

    var conf_ini = zigini.Ini(Config).init(allocator);
    defer conf_ini.deinit();

    const config_path = res.args.config orelse "/etc/zgsld/zgsld.ini";
    var config = conf_ini.readFileToStruct(init.io, config_path, .{ .convert = convertIniValue }) catch |err| switch (err) {
        error.FileNotFound => {
            log.err("Config file not found: {s}", .{config_path});
            return error.MissingConfig;
        },
        else => return err,
    };

    if (res.args.vt) |vt| config.vt = try Config.Vt.parse(vt);

    try daemon.run(.fromInit(&init), .{
        .config = config,
    });
}

fn convertIniValue(allocator: std.mem.Allocator, comptime T: type, value: []const u8) anyerror!T {
    if (T == Config.Vt) return Config.Vt.parse(value);
    return zigini.defaultConvert(allocator, T, value);
}
