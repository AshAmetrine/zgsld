const std = @import("std");
const build_options = @import("build_options");
const zgsld = @import("zgsld");
const Config = zgsld.Config;
const daemon = zgsld.daemon;
const worker_runtime = daemon.worker.runtime;

const clap = @import("clap");
const zigini = @import("zigini");

const log = std.log.scoped(.zgsld);

pub const std_options: std.Options = .{ .logFn = zgsld.logFn };

const clap_param_str =
    \\-h, --help                Shows all commands.
    \\-v, --version             Shows the version of zgsld.
    \\-c, --config <str>        Path to ZGSLD config
    \\--vt <str>                Sets VT to a number, `current` or `unmanaged`
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const process = zgsld.ProcessContext.fromInit(init);

    if (daemon.worker.isSessionWorker(init.minimal.args)) {
        try worker_runtime.run(process);
        return;
    }

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
        try clap.helpToFile(init.io, .stderr(), clap.Help, &params, .{});
        std.process.exit(0);
    }
    if (res.args.version != 0) {
        var stderr_buf: [1024]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buf);
        const stderr = &stderr_writer.interface;

        try stderr.writeAll("zgsld " ++ build_options.version ++ "\n");
        try stderr.print("features: x11={s}\n", .{if (build_options.x11_support) "yes" else "no"});
        try stderr.flush();
        std.process.exit(0);
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

    var self_exe_path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const self_exe_path_len = try std.process.executablePath(init.io, &self_exe_path_buf);
    const self_exe_path = self_exe_path_buf[0..self_exe_path_len];
    self_exe_path_buf[self_exe_path.len] = 0;
    const self_exe_path_z = self_exe_path_buf[0..self_exe_path.len :0];

    try daemon.session_manager.run(.{
        .allocator = allocator,
        .io = init.io,
        .env_map = init.environ_map,
        .self_exe_path = self_exe_path_z,
        .config = config,
    });
}

fn convertIniValue(allocator: std.mem.Allocator, comptime T: type, value: []const u8) anyerror!T {
    if (T == Config.Vt) return Config.Vt.parse(value);
    return zigini.defaultConvert(allocator, T, value);
}
