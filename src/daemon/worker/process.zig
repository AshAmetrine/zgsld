const std = @import("std");
const build_options = @import("build_options");
const Config = @import("../../Config.zig");

pub const SessionClass = enum {
    user,
    greeter,
    autologin,
};

pub const SpawnOpts = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    worker_path: []const u8,
    config: Config,
    session_class: SessionClass,
    ipc_file: ?std.Io.File,
};

pub fn spawn(opts: SpawnOpts) !std.process.Child {
    var worker_envmap = std.process.Environ.Map.init(opts.allocator);
    defer worker_envmap.deinit();

    for ([_][]const u8{ "PATH", "TERM", "XDG_SEAT" }) |key| {
        if (opts.env_map.get(key)) |value| {
            try worker_envmap.put(key, value);
        }
    }
    if (opts.config.vt == .unmanaged) {
        if (opts.env_map.get("XDG_VTNR")) |vtnr| {
            try worker_envmap.put("XDG_VTNR", vtnr);
        }
    }
    try putZgsldVtEnv(&worker_envmap, opts.config.vt);
    if (build_options.x11_support) {
        try worker_envmap.put("ZGSLD_X11_CMD", opts.config.x11.command);
        if (opts.config.x11.vt) |x11_vt| {
            var x11_vt_buf: [8]u8 = undefined;
            const x11_vt_value = try std.fmt.bufPrint(&x11_vt_buf, "{d}", .{x11_vt});
            try worker_envmap.put("ZGSLD_X11_VT", x11_vt_value);
        }
    }

    const service_name = switch (opts.session_class) {
        .greeter => opts.config.greeter.service_name,
        .user, .autologin => opts.config.session.service_name,
    };

    if (opts.session_class != .autologin) {
        const ipc_file = opts.ipc_file orelse return error.MissingIpcFd;
        var fd_buf: [16]u8 = undefined;
        const zgsld_sock = try std.fmt.bufPrint(&fd_buf, "{d}", .{ipc_file.handle});
        try worker_envmap.put("ZGSLD_SOCK", zgsld_sock);
    }

    switch (opts.session_class) {
        .greeter => {
            const greeter_cmd = opts.config.greeter.command orelse return error.NullGreeterCmd;
            if (greeter_cmd.len == 0) return error.NullGreeterCmd;

            try worker_envmap.put(
                "ZGSLD_GREETER_SESSION_TYPE",
                @tagName(opts.config.greeter.session_type),
            );
            try worker_envmap.put("ZGSLD_GREETER_CMD", greeter_cmd);
        },
        .autologin => {
            const autologin_user = opts.config.autologin.user orelse return error.NullAutologinUser;
            if (autologin_user.len == 0) return error.NullAutologinUser;

            const autologin_cmd = opts.config.autologin.command orelse return error.NullAutologinCmd;
            if (autologin_cmd.len == 0) return error.NullAutologinCmd;

            try worker_envmap.put("ZGSLD_AUTOLOGIN_USER", autologin_user);
            try worker_envmap.put("ZGSLD_AUTOLOGIN_SESSION_TYPE", @tagName(opts.config.autologin.session_type));
            try worker_envmap.put("ZGSLD_AUTOLOGIN_CMD", autologin_cmd);
        },
        .user => {},
    }

    const argv = [_][]const u8{
        opts.worker_path,
        "--session-worker",
        @tagName(opts.session_class),
        service_name,
        opts.config.greeter.user,
    };

    return std.process.spawn(opts.io, .{
        .argv = if (opts.session_class == .greeter) &argv else argv[0..4],
        .environ_map = &worker_envmap,
        .inherit_files = if (opts.ipc_file) |file| &.{file} else &.{},
    });
}

fn putZgsldVtEnv(envmap: *std.process.Environ.Map, vt: Config.Vt) !void {
    var vt_buf: [8]u8 = undefined;
    const vt_value = switch (vt) {
        .unmanaged => "unmanaged",
        .current => "current",
        .number => |vt_num| try std.fmt.bufPrint(&vt_buf, "{d}", .{vt_num}),
    };
    try envmap.put("ZGSLD_VT", vt_value);
}
