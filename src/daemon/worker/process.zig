const std = @import("std");
const build_options = @import("build_options");
const Config = @import("common").Config;

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
    control_file: std.Io.File,
};

pub fn spawn(opts: SpawnOpts) !std.process.Child {
    var worker_envmap = try createWorkerEnv(opts);
    defer worker_envmap.deinit();

    const service_name = switch (opts.session_class) {
        .greeter => opts.config.greeter.service_name orelse opts.config.session.service_name,
        .user, .autologin => opts.config.session.service_name,
    };

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
        .inherit_files = if (opts.ipc_file) |file| &.{ file, opts.control_file } else &.{opts.control_file},
    });
}

fn createWorkerEnv(opts: SpawnOpts) !std.process.Environ.Map {
    var worker_envmap = std.process.Environ.Map.init(opts.allocator);
    errdefer worker_envmap.deinit();

    const inherited_vars = [_][]const u8{
        "PATH",
        "TERM",
        "LANG",
        "LANGUAGE",
        "LOCALE_ARCHIVE",
        "LOCPATH",
        "PATH_LOCALE",
    };
    for (inherited_vars) |key| {
        if (opts.env_map.get(key)) |value| {
            try worker_envmap.put(key, value);
        }
    }

    var it = opts.env_map.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.startsWith(u8, key, "LC_")) {
            try worker_envmap.put(key, entry.value_ptr.*);
        }
    }

    const vt_num = opts.config.vt.ttyNumber(opts.io);
    // PAM also reads the process environment. A PTY must not inherit its outer seat.
    if (opts.config.vt != .unmanaged or vt_num != null) {
        if (opts.env_map.get("XDG_SEAT")) |seat| {
            try worker_envmap.put("XDG_SEAT", seat);
        }
    }
    if (opts.config.vt == .unmanaged) {
        if (vt_num) |number| {
            var vt_buf: [3]u8 = undefined;
            const value = try std.fmt.bufPrint(&vt_buf, "{d}", .{number});
            try worker_envmap.put("XDG_VTNR", value);
        }
    }
    try putZgsldVtEnv(&worker_envmap, opts.config.vt);
    if (build_options.x11_support) {
        try worker_envmap.put("ZGSLD_X11_CMD", opts.config.x11.command);
        var timeout_buf: [10]u8 = undefined;
        const timeout = try std.fmt.bufPrint(
            &timeout_buf,
            "{d}",
            .{opts.config.x11.startup_timeout_seconds},
        );
        try worker_envmap.put("ZGSLD_X11_TIMEOUT_SECONDS", timeout);
        if (opts.config.x11.vt) |x11_vt| {
            var x11_vt_buf: [8]u8 = undefined;
            const x11_vt_value = try std.fmt.bufPrint(&x11_vt_buf, "{d}", .{x11_vt});
            try worker_envmap.put("ZGSLD_X11_VT", x11_vt_value);
        }
    }

    if (opts.session_class != .autologin) {
        const ipc_file = opts.ipc_file orelse return error.MissingIpcFd;
        var fd_buf: [16]u8 = undefined;
        const zgsld_sock = try std.fmt.bufPrint(&fd_buf, "{d}", .{ipc_file.handle});
        try worker_envmap.put("ZGSLD_SOCK", zgsld_sock);
    }

    var control_buf: [16]u8 = undefined;
    try worker_envmap.put("ZGSLD_CONTROL", try std.fmt.bufPrint(&control_buf, "{d}", .{opts.control_file.handle}));

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

    return worker_envmap;
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
