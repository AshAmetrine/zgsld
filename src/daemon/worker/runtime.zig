const std = @import("std");
const ipc = @import("ipc");
const fd_utils = @import("../../fd.zig");
const autologin = @import("runtime/autologin.zig");
const greeter_mod = @import("runtime/greeter.zig");
const login = @import("runtime/login.zig");
const signals = @import("runtime/signals.zig");
const ProcessContext = @import("../../ProcessContext.zig");
const Vt = @import("vt").Vt;
const SessionClass = @import("process.zig").SessionClass;

const Greeter = greeter_mod.Greeter;

pub const Options = struct {
    session_class: SessionClass,
    service_name: []const u8,
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

pub fn run(process: ProcessContext, opts: Options) !void {
    signals.installHandlers();

    const vt = try Vt.parse(process.environ_map.get("ZGSLD_VT"));

    switch (opts.session_class) {
        .greeter => {
            const sock_fd = try parseZgsldSock(process.environ_map);
            const greeter_cmd = process.environ_map.get("ZGSLD_GREETER_CMD") orelse return error.MissingGreeterCmd;
            const greeter_session_type_raw = process.environ_map.get("ZGSLD_GREETER_SESSION_TYPE") orelse return error.MissingGreeterSessionType;
            const greeter_session_type = std.meta.stringToEnum(ipc.SessionType, greeter_session_type_raw) orelse return error.InvalidGreeterSessionType;

            var greeter = try Greeter.init(process.gpa, .{
                .service_name = opts.service_name,
                .username = opts.greeter_username.?,
                .vt = vt,
                .io = process.io,
                .env_map = process.environ_map,
            });
            defer greeter.deinit(process.io);

            const greeter_child = blk: {
                defer _ = std.c.close(sock_fd);
                break :blk try greeter.spawn(sock_fd, greeter_cmd, greeter_session_type, vt, process.io, process.environ_map);
            };
            signals.setActiveChild(greeter_child.id.?);
            defer signals.clearActiveChild();

            if (signals.shutdownRequested()) {
                signals.forwardShutdownSignal(signals.shutdownSignal());
            }
            _ = try greeter_child.wait(process.io);
            return;
        },
        .user => {
            const sock_fd = try parseZgsldSock(process.environ_map);
            try fd_utils.setCloseOnExec(sock_fd);

            var ipc_conn = ipc.Connection.init(.{
                .handle = sock_fd,
                .flags = .{ .nonblocking = false },
            }, .{});
            try login.run(.{
                .allocator = process.gpa,
                .io = process.io,
                .env_map = process.environ_map,
                .service_name = opts.service_name,
                .ipc_conn = &ipc_conn,
                .vt = vt,
            });
        },
        .autologin => {
            const autologin_user = process.environ_map.get("ZGSLD_AUTOLOGIN_USER") orelse return error.MissingAutologinUser;
            const autologin_session_type_raw = process.environ_map.get("ZGSLD_AUTOLOGIN_SESSION_TYPE") orelse return error.MissingAutologinSessionType;
            const autologin_session_type = std.meta.stringToEnum(ipc.SessionType, autologin_session_type_raw) orelse return error.InvalidAutologinSessionType;
            const autologin_cmd = process.environ_map.get("ZGSLD_AUTOLOGIN_CMD") orelse return error.MissingAutologinCmd;
            const autologin_user_z = try process.gpa.dupeSentinel(u8, autologin_user, 0);
            defer process.gpa.free(autologin_user_z);

            try autologin.run(.{
                .allocator = process.gpa,
                .io = process.io,
                .env_map = process.environ_map,
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
    return try std.fmt.parseInt(std.posix.fd_t, fd, 10);
}
