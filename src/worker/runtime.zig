const std = @import("std");
const Ipc = @import("Ipc");
const fd_utils = @import("../fd.zig");
const autologin = @import("runtime/autologin.zig");
const greeter_mod = @import("runtime/greeter.zig");
const login = @import("runtime/login.zig");
const signals = @import("runtime/signals.zig");
const Config = @import("../Config.zig");
const SessionClass = @import("process.zig").SessionClass;

const Greeter = greeter_mod.Greeter;

pub const WorkerRuntimeOpts = struct {
    allocator: std.mem.Allocator,
};

pub const WorkerRuntime = struct {
    allocator: std.mem.Allocator,

    pub fn init(opts: WorkerRuntimeOpts) WorkerRuntime {
        return .{ .allocator = opts.allocator };
    }

    pub fn run(self: *WorkerRuntime) !void {
        signals.installHandlers();

        const argv = std.os.argv;
        if (argv.len < 3) return error.MissingWorkerArgs;
        const session_class = std.meta.stringToEnum(SessionClass, std.mem.span(argv[2])) orelse return error.InvalidSessionClass;

        const expected_argv_len: usize = if (session_class == .greeter) 5 else 4;
        if (argv.len < expected_argv_len) return error.MissingWorkerArgs;

        const service = std.mem.span(argv[3]);

        const vt = try Config.Vt.parse(std.posix.getenv("ZGSLD_VT"));

        switch (session_class) {
            .greeter => {
                const sock_fd = try parseZgsldSock();
                const greeter_username = std.mem.span(argv[4]);
                const greeter_cmd = std.posix.getenv("ZGSLD_GREETER_CMD") orelse return error.MissingGreeterCmd;
                const greeter_session_type_raw = std.posix.getenv("ZGSLD_GREETER_SESSION_TYPE") orelse return error.MissingGreeterSessionType;
                const greeter_session_type = std.meta.stringToEnum(Ipc.SessionType, greeter_session_type_raw) orelse return error.InvalidGreeterSessionType;

                var greeter = try Greeter.init(self.allocator, .{
                    .service_name = service,
                    .username = greeter_username,
                    .vt = vt,
                });
                defer greeter.deinit();

                const greeter_pid = blk: {
                    defer std.posix.close(sock_fd);
                    break :blk try greeter.spawn(sock_fd, greeter_cmd, greeter_session_type, vt);
                };
                signals.setActiveChild(greeter_pid);
                defer signals.clearActiveChild();

                if (signals.shutdownRequested()) {
                    signals.forwardShutdownSignal(signals.shutdownSignal());
                }
                _ = std.posix.waitpid(greeter_pid, 0);
                return;
            },
            .user => {
                const sock_fd = try parseZgsldSock();
                try fd_utils.setCloseOnExec(sock_fd);

                var ipc_conn = Ipc.Connection.initFromFd(sock_fd);
                try login.run(.{
                    .allocator = self.allocator,
                    .service_name = service,
                    .ipc_conn = &ipc_conn,
                    .vt = vt,
                });
            },
            .autologin => {
                const autologin_user = std.posix.getenv("ZGSLD_AUTOLOGIN_USER") orelse return error.MissingAutologinUser;
                const autologin_session_type_raw = std.posix.getenv("ZGSLD_AUTOLOGIN_SESSION_TYPE") orelse return error.MissingAutologinSessionType;
                const autologin_session_type = std.meta.stringToEnum(Ipc.SessionType, autologin_session_type_raw) orelse return error.InvalidAutologinSessionType;
                const autologin_cmd = std.posix.getenv("ZGSLD_AUTOLOGIN_CMD") orelse return error.MissingAutologinCmd;

                try autologin.run(.{
                    .allocator = self.allocator,
                    .service_name = service,
                    .user = autologin_user,
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
};

fn parseZgsldSock() !std.posix.fd_t {
    const fd = std.posix.getenv("ZGSLD_SOCK") orelse return error.MissingZgsldSock;
    return try std.fmt.parseInt(std.posix.fd_t, fd, 10);
}
