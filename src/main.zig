const std = @import("std");
const build_options = @import("build_options");
const clap = @import("clap");
const session_manager = @import("session_manager.zig");

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const paramStr =
        \\-h, --help                Shows all commands.
        \\-v, --version             Shows the version of zgsld.
        \\--greeter-path <str>      Sets the greeter path
        \\--vt <u8>                Sets the VT number
    ;

    const params = comptime clap.parseParamsComptime(paramStr);

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag, .allocator = allocator
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

    const greeter_path = if (res.args.@"greeter-path") |path| blk: {
        break :blk try allocator.dupeZ(u8, path);
    } else {
        return error.MissingGreeterPath;
    };
    defer allocator.free(greeter_path);

    try session_manager.run(allocator, .{
        .service_name = build_options.service_name,
        .greeter_path = greeter_path,
        .greeter_user = build_options.greeter_user,
        .vt = res.args.vt,
    });
}
