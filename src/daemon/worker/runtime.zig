const std = @import("std");
const Ipc = @import("Ipc");
const posix = @import("posix");
const fd_utils = @import("../../fd.zig");
const autologin = @import("runtime/autologin.zig");
const greeter_mod = @import("runtime/greeter.zig");
const login = @import("runtime/login.zig");
const signals = @import("runtime/signals.zig");
const ProcessContext = @import("../../ProcessContext.zig");
const Vt = @import("vt").Vt;
const SessionClass = @import("process.zig").SessionClass;

const Greeter = greeter_mod.Greeter;

pub fn run(process: ProcessContext) !void {
    signals.installHandlers();

    var arg_it = process.args.iterate();
    if (!arg_it.skip()) return error.MissingWorkerArgs;

    const session_class = if (arg_it.next()) |arg| blk: {
        break :blk std.meta.stringToEnum(SessionClass, arg) orelse return error.InvalidSessionClass;
    } else return error.MissingWorkerArgs;

    const service = arg_it.next() orelse return error.MissingWorkerArgs;

    const greeter_username: ?[:0]const u8 = if (session_class == .greeter) blk: {
        break :blk arg_it.next() orelse return error.MissingWorkerArgs;
    } else null;

    const vt = try Vt.parse(process.environ_map.get("ZGSLD_VT"));

    switch (session_class) {
        .greeter => {
            const sock_fd = try parseZgsldSock(process.environ_map);
            const greeter_cmd = process.environ_map.get("ZGSLD_GREETER_CMD") orelse return error.MissingGreeterCmd;
            const greeter_session_type_raw = process.environ_map.get("ZGSLD_GREETER_SESSION_TYPE") orelse return error.MissingGreeterSessionType;
            const greeter_session_type = std.meta.stringToEnum(Ipc.SessionType, greeter_session_type_raw) orelse return error.InvalidGreeterSessionType;

            var greeter = try Greeter.init(process.gpa, .{
                .service_name = service,
                .username = greeter_username.?,
                .vt = vt,
                .io = process.io,
                .env_map = process.environ_map,
            });
            defer greeter.deinit();

            const greeter_pid = blk: {
                defer _ = std.c.close(sock_fd);
                break :blk try greeter.spawn(sock_fd, greeter_cmd, greeter_session_type, vt, process.io, process.environ_map);
            };
            signals.setActiveChild(greeter_pid);
            defer signals.clearActiveChild();

            if (signals.shutdownRequested()) {
                signals.forwardShutdownSignal(signals.shutdownSignal());
            }
            _ = try posix.waitpid(greeter_pid, 0);
            return;
        },
        .user => {
            const sock_fd = try parseZgsldSock(process.environ_map);
            try fd_utils.setCloseOnExec(sock_fd);

            var ipc_conn = Ipc.Connection.initFromFd(sock_fd);
            try login.run(.{
                .allocator = process.gpa,
                .io = process.io,
                .env_map = process.environ_map,
                .service_name = service,
                .ipc_conn = &ipc_conn,
                .vt = vt,
            });
        },
        .autologin => {
            const autologin_user = process.environ_map.get("ZGSLD_AUTOLOGIN_USER") orelse return error.MissingAutologinUser;
            const autologin_session_type_raw = process.environ_map.get("ZGSLD_AUTOLOGIN_SESSION_TYPE") orelse return error.MissingAutologinSessionType;
            const autologin_session_type = std.meta.stringToEnum(Ipc.SessionType, autologin_session_type_raw) orelse return error.InvalidAutologinSessionType;
            const autologin_cmd = process.environ_map.get("ZGSLD_AUTOLOGIN_CMD") orelse return error.MissingAutologinCmd;
            const autologin_user_z = try process.gpa.dupeZ(u8, autologin_user);
            defer process.gpa.free(autologin_user_z);

            try autologin.run(.{
                .allocator = process.gpa,
                .io = process.io,
                .env_map = process.environ_map,
                .service_name = service,
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
