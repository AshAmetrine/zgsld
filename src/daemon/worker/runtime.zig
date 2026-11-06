const std = @import("std");
const ipc = @import("ipc");
const fd_utils = @import("common").fd;
const autologin = @import("runtime/autologin.zig");
const greeter = @import("runtime/greeter.zig");
const login = @import("runtime/login.zig");
const signals = @import("runtime/signals.zig");
const Shutdown = @import("../Shutdown.zig");
const Vt = @import("vt").Vt;
const SessionClass = @import("process.zig").SessionClass;

pub const Options = struct {
    session_class: SessionClass,
    service_name: [:0]const u8,
    greeter_username: ?[:0]const u8 = null,
};

pub fn parseArgs(args: std.process.Args) !?Options {
    var arg_it = args.iterate();
    if (!arg_it.skip()) return null;
    const arg = arg_it.next() orelse return null;
    if (!std.mem.eql(u8, "--session-worker", arg)) return null;

    const session_class_arg = arg_it.next() orelse return error.MissingWorkerArgs;
    const session_class = std.meta.stringToEnum(SessionClass, session_class_arg) orelse return error.InvalidSessionClass;

    const service_name = arg_it.next() orelse return error.MissingWorkerArgs;
    const greeter_username = if (session_class == .greeter)
        arg_it.next() orelse return error.MissingWorkerArgs
    else
        null;

    return .{
        .session_class = session_class,
        .service_name = service_name,
        .greeter_username = greeter_username,
    };
}

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    opts: Options,
) !void {
    signals.installHandlers();
    const shutdown_raw = environ_map.get("ZGSLD_CONTROL") orelse
        return error.MissingControlFd;
    const shutdown_fd = try std.fmt.parseInt(std.posix.fd_t, shutdown_raw, 10);
    var shutdown_conn = try Shutdown.Connection.init(io, .{
        .handle = shutdown_fd,
        .flags = .{ .nonblocking = false },
    });
    defer shutdown_conn.deinit();

    const vt = try Vt.parse(environ_map.get("ZGSLD_VT"));

    switch (opts.session_class) {
        .greeter => {
            const sock_fd = try parseZgsldSock(environ_map);
            const greeter_cmd = environ_map.get("ZGSLD_GREETER_CMD") orelse
                return error.MissingGreeterCmd;
            const greeter_session_type_raw = environ_map.get("ZGSLD_GREETER_SESSION_TYPE") orelse
                return error.MissingGreeterSessionType;
            const greeter_session_type = std.meta.stringToEnum(
                ipc.SessionType,
                greeter_session_type_raw,
            ) orelse return error.InvalidGreeterSessionType;

            try greeter.run(.{
                .allocator = gpa,
                .io = io,
                .shutdown_conn = &shutdown_conn,
                .env_map = environ_map,
                .service_name = opts.service_name,
                .username = opts.greeter_username.?,
                .ipc_fd = sock_fd,
                .command = greeter_cmd,
                .session_type = greeter_session_type,
                .vt = vt,
            });
        },
        .user => {
            const sock_fd = try parseZgsldSock(environ_map);
            try fd_utils.setCloseOnExec(sock_fd);

            try login.run(.{
                .allocator = gpa,
                .io = io,
                .shutdown_conn = &shutdown_conn,
                .env_map = environ_map,
                .service_name = opts.service_name,
                .ipc_socket = .{
                    .handle = sock_fd,
                    .flags = .{ .nonblocking = false },
                },
                .vt = vt,
            });
        },
        .autologin => {
            const autologin_user = environ_map.get("ZGSLD_AUTOLOGIN_USER") orelse
                return error.MissingAutologinUser;
            const autologin_session_type_raw = environ_map.get(
                "ZGSLD_AUTOLOGIN_SESSION_TYPE",
            ) orelse return error.MissingAutologinSessionType;
            const autologin_session_type = std.meta.stringToEnum(
                ipc.SessionType,
                autologin_session_type_raw,
            ) orelse return error.InvalidAutologinSessionType;
            const autologin_cmd = environ_map.get("ZGSLD_AUTOLOGIN_CMD") orelse
                return error.MissingAutologinCmd;
            const autologin_user_z = try gpa.dupeSentinel(u8, autologin_user, 0);
            defer gpa.free(autologin_user_z);

            try autologin.run(.{
                .allocator = gpa,
                .io = io,
                .shutdown_conn = &shutdown_conn,
                .env_map = environ_map,
                .service_name = opts.service_name,
                .user = autologin_user_z,
                .info = .{
                    .session_type = autologin_session_type,
                    .command = .{
                        .session_cmd = autologin_cmd,
                        .source_profile = true,
                    },
                },
                .vt = vt,
            });
        },
    }
}

fn parseZgsldSock(env_map: *const std.process.Environ.Map) !std.posix.fd_t {
    const fd = env_map.get("ZGSLD_SOCK") orelse return error.MissingZgsldSock;
    return std.fmt.parseInt(std.posix.fd_t, fd, 10);
}
