const std = @import("std");
const zgipc = @import("ipc");
const pam_mod = @import("pam");
const greeter_mod = @import("runtime/greeter.zig");
const session_mod = @import("runtime/session.zig");
const env_mod = @import("runtime/env.zig");

const Pam = pam_mod.Pam;
const PamMessages = pam_mod.Messages;

const log = std.log.scoped(.zgsld_worker);

var shutdown_signal = std.atomic.Value(u8).init(0);
var active_child_pid = std.atomic.Value(std.posix.pid_t).init(0);

const Greeter = greeter_mod.Greeter;
const Session = session_mod.Session;

pub const WorkerRuntimeOpts = struct {
    allocator: std.mem.Allocator,
};

pub const WorkerRuntime = struct {
    allocator: std.mem.Allocator,

    pub fn init(opts: WorkerRuntimeOpts) WorkerRuntime {
        return .{
            .allocator = opts.allocator,
        };
    }

    pub fn run(self: *WorkerRuntime) !void {
        installSignalHandlers();

        const argv = std.os.argv;
        if (argv.len < 4) return error.MissingWorkerArgs;
        const service = std.mem.span(argv[2]);
        const greeter_username: [:0]const u8 = std.mem.span(argv[3]);
        const greeter_cmd = std.posix.getenv("ZGSLD_GREETER_CMD") orelse return error.MissingGreeterCmd;

        const vt = if (std.posix.getenv("ZGSLD_VTNR")) |vt_str| blk: {
            break :blk try std.fmt.parseInt(u8, vt_str, 10);
        } else null;

        var greeter = try Greeter.init(self.allocator, .{
            .service_name = service,
            .username = greeter_username,
        });
        defer greeter.deinit();

        const fds = try createSocketPair();
        const greeter_pid = blk: {
            defer std.posix.close(fds.child);
            errdefer std.posix.close(fds.parent);
            try greeter.spawn(fds.child, greeter_cmd);
            break :blk greeter.pid() orelse return error.GreeterSessionMissing;
        };

        active_child_pid.store(greeter_pid, .seq_cst);
        if (shutdownRequested()) {
            forwardShutdownSignal(shutdown_signal.load(.seq_cst));
        }

        var ipc_conn = zgipc.Ipc.initFromFd(fds.parent);
        defer ipc_conn.deinit();

        try self.runIpcLoop(.{
            .service_name = service,
            .ipc_conn = &ipc_conn,
            .greeter_pid = greeter_pid,
            .vt = vt,
        });
    }

    const RunOpts = struct {
        service_name: []const u8,
        ipc_conn: *zgipc.Ipc,
        greeter_pid: std.posix.pid_t,
        vt: ?u8,
    };

    fn runIpcLoop(self: *WorkerRuntime, opts: RunOpts) !void {
        var event_buf: [zgipc.GREETER_BUF_SIZE]u8 = undefined;
        var rbuf: [zgipc.IPC_IO_BUF_SIZE]u8 = undefined;
        var wbuf: [zgipc.IPC_IO_BUF_SIZE]u8 = undefined;
        var saw_auth = false;

        var reader = opts.ipc_conn.reader(&rbuf);
        var writer = opts.ipc_conn.writer(&wbuf);
        const ipc_reader = &reader.interface;
        const ipc_writer = &writer.interface;

        while (true) {
            log.debug("Waiting for event", .{});
            const event = opts.ipc_conn.readEvent(ipc_reader, &event_buf) catch |err| {
                if (err == error.EndOfStream and !saw_auth) {
                    if (shutdownRequested()) return;
                    std.process.exit(2);
                }
                return err;
            };
            switch (event) {
                .login_cancel => {
                    log.debug("Login cancelled before auth start", .{});
                    continue;
                },
                .pam_start_auth => |auth| {
                    saw_auth = true;
                    const user_z = try self.allocator.dupeZ(u8, auth.user);
                    defer self.allocator.free(user_z);

                    var ctx: PamCtx = .{
                        .cancelled = false,
                        .ipc_conn = opts.ipc_conn,
                        .reader = ipc_reader,
                        .writer = ipc_writer,
                    };
                    var pam_state: Pam(PamCtx).ConvState = .{
                        .conv = loginConv,
                        .ctx = &ctx,
                    };
                    var pam = try Pam(PamCtx).init(self.allocator, .{
                        .service_name = opts.service_name,
                        .user = user_z,
                        .state = &pam_state,
                    });
                    defer pam.deinit();

                    pam.authenticate(.{}) catch {
                        if (ctx.cancelled) {
                            log.debug("Pam auth cancelled", .{});
                            continue;
                        }

                        const fail = zgipc.IpcEvent{ .pam_auth_result = .{ .ok = false } };
                        opts.ipc_conn.writeEvent(ipc_writer, &fail) catch {};
                        ipc_writer.flush() catch {};
                        continue;
                    };
                    try pam.accountMgmt(.{});
                    try pam.setCred(.{ .action = .establish });

                    const ok = zgipc.IpcEvent{ .pam_auth_result = .{ .ok = true } };
                    try opts.ipc_conn.writeEvent(ipc_writer, &ok);
                    try ipc_writer.flush();

                    var session_envmap = std.process.EnvMap.init(self.allocator);
                    errdefer session_envmap.deinit();

                    while (true) {
                        const session_event = opts.ipc_conn.readEvent(ipc_reader, &event_buf) catch |err| {
                            if (err == error.EndOfStream and shutdownRequested()) {
                                std.process.exit(0);
                            }
                            return err;
                        };
                        switch (session_event) {
                            .login_cancel => {
                                log.debug("Login cancelled before session start", .{});
                                session_envmap.deinit();
                                break;
                            },
                            .set_session_env => |env| {
                                if (std.meta.stringToEnum(SessionEnvKey, env.key) == null) break;
                                try session_envmap.put(env.key, env.value);
                            },
                            .start_session => |info| {
                                log.debug("Waiting for greeter exit before starting session...", .{});
                                _ = std.posix.waitpid(opts.greeter_pid, 0);
                                active_child_pid.store(0, .seq_cst);
                                if (shutdownRequested()) return;
                                log.debug("Starting session...", .{});

                                var session = blk: {
                                    defer session_envmap.deinit();
                                    break :blk try startSession(self.allocator, user_z, info, &pam, &session_envmap, opts.vt);
                                };

                                defer session.deinit();

                                log.debug("Waiting for session to end...", .{});
                                const session_pid = session.pid;
                                active_child_pid.store(session_pid, .seq_cst);
                                if (shutdownRequested()) {
                                    forwardShutdownSignal(shutdown_signal.load(.seq_cst));
                                }
                                _ = std.posix.waitpid(session_pid, 0);
                                active_child_pid.store(0, .seq_cst);
                                return;
                            },
                            else => unreachable,
                        }
                    }
                    break;
                },
                else => unreachable,
            }
        }
    }
};

const SessionEnvKey = enum {
    PATH,
    XDG_SESSION_DESKTOP,
    XDG_CURRENT_DESKTOP,
    XDG_SESSION_TYPE,
};

const SocketPair = struct {
    parent: std.posix.fd_t,
    child: std.posix.fd_t,
};

fn createSocketPair() !SocketPair {
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (rc != 0) return std.posix.unexpectedErrno(std.posix.errno(rc));

    const flags = try std.posix.fcntl(fds[0], std.posix.F.GETFD, 0);
    _ = try std.posix.fcntl(fds[0], std.posix.F.SETFD, flags |
        std.posix.FD_CLOEXEC);

    return .{ .parent = fds[0], .child = fds[1] };
}

// PAM CONV

pub const PamCtx = struct {
    cancelled: bool,
    ipc_conn: *zgipc.Ipc,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
};

fn loginConv(
    _: std.mem.Allocator,
    msgs: PamMessages,
    ctx: *PamCtx,
) !void {
    if (ctx.cancelled) return error.Abort;

    const ipc_reader = ctx.reader;
    const ipc_writer = ctx.writer;

    var ipc_buf: [zgipc.PAM_CONV_BUF_SIZE]u8 = undefined;
    defer std.crypto.secureZero(u8, &ipc_buf);

    var iter = msgs.iter();
    while (try iter.next()) |msg| {
        switch (msg) {
            .prompt_echo_off, .prompt_echo_on => |m| {
                try ctx.ipc_conn.writeEvent(ipc_writer, &.{
                    .pam_request = .{
                        .echo = msg == .prompt_echo_on,
                        .message = m.message,
                    },
                });
                try ipc_writer.flush();

                const event = try ctx.ipc_conn.readEvent(ipc_reader, &ipc_buf);
                switch (event) {
                    .pam_response => |resp_bytes| {
                        try m.respond(resp_bytes);
                    },
                    .login_cancel => {
                        ctx.cancelled = true;
                        return error.Abort;
                    },
                    else => unreachable,
                }
            },
            .text_info, .error_msg => |m| {
                try ctx.ipc_conn.writeEvent(ipc_writer, &.{
                    .pam_message = .{
                        .is_error = msg == .error_msg,
                        .message = m,
                    },
                });
                try ipc_writer.flush();
            },
        }
    }
}

fn startSession(
    allocator: std.mem.Allocator,
    user: [:0]const u8,
    info: zgipc.SessionInfo,
    pam: *Pam(PamCtx),
    session_envmap: *std.process.EnvMap,
    vt: ?u8,
) !Session {
    try env_mod.applyPamSessionEnv(pam, session_envmap, vt);
    const user_info = try env_mod.applyUserEnv(session_envmap, user);
    return Session.spawn(allocator, .{
        .session_info = info,
        .envmap = session_envmap,
        .user_info = user_info,
    });
}

// Signal Handling

fn shutdownRequested() bool {
    return shutdown_signal.load(.seq_cst) != 0;
}

fn installSignalHandlers() void {
    const sigact = std.posix.Sigaction{
        .handler = .{ .handler = handleShutdownSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };

    const forward_signals = [_]u8{
        std.posix.SIG.TERM,
        std.posix.SIG.HUP,
        std.posix.SIG.QUIT,
    };

    for (forward_signals) |sig| {
        std.posix.sigaction(sig, &sigact, null);
    }

    const alarm_sigact = std.posix.Sigaction{
        .handler = .{ .handler = handleKillTimeout },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.ALRM, &alarm_sigact, null);
}

fn forwardShutdownSignal(sig: u8) void {
    const child_pid = active_child_pid.load(.seq_cst);
    if (child_pid > 0) {
        std.posix.kill(child_pid, sig) catch {};
    }
    // 5s timeout until sigkill
    _ = std.c.alarm(5);
}

fn handleShutdownSignal(sig: i32) callconv(.c) void {
    const sig_u8: u8 = @intCast(sig);
    shutdown_signal.store(sig_u8, .seq_cst);
    forwardShutdownSignal(sig_u8);
}

fn handleKillTimeout(_: i32) callconv(.c) void {
    if (!shutdownRequested()) return;
    const child_pid = active_child_pid.load(.seq_cst);
    if (child_pid > 0) {
        std.posix.kill(child_pid, std.posix.SIG.KILL) catch {};
    }
}
