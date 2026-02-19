const std = @import("std");
const pam_module = @import("pam");
const Pam = pam_module.Pam;
const ipc_module = @import("ipc.zig");
const log = std.log.scoped(.zgsld_worker);
const vt_mod = @import("vt.zig");
const UserInfo = @import("UserInfo.zig");
const utils = @import("utils.zig");
const build_options = @import("build_options");
const x11 = if (build_options.x11_support) @import("session/x11.zig") else struct {};

var shutdown_signal = std.atomic.Value(u8).init(0);
var active_child_pid = std.atomic.Value(std.posix.pid_t).init(0);

pub const SessionWorkerRunOpts = struct {
    service_name: []const u8,
    ipc_conn: *ipc_module.Ipc,
    vt: ?u8 = null,
    greeter_pid: std.posix.pid_t,
};

const SessionEnvKey = enum {
    PATH,
    XDG_SESSION_DESKTOP,
    XDG_CURRENT_DESKTOP,
    XDG_SESSION_TYPE,
};

pub const PamCtx = struct {
    cancelled: bool,
    ipc_conn: *ipc_module.Ipc,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
};

pub fn runFromArgs(allocator: std.mem.Allocator) !void {
    installSignalHandlers();

    const argv = std.os.argv;
    const service = std.mem.span(argv[2]);
    const user = std.mem.span(argv[3]);
    const start: usize = 5;

    const greeter_len = argv.len - start;
    const greeter_ptr: [*]const ?[*:0]const u8 = @ptrCast(argv.ptr + start);
    const greeter_argv = greeter_ptr[0..greeter_len :null];

    const fds = try createSocketPair();

    const greeter_pid = blk: {
        defer std.posix.close(fds[1]);
        errdefer std.posix.close(fds[0]);
        break :blk try spawnGreeter(greeter_argv, user, fds[1], fds[0]);
    };
    active_child_pid.store(greeter_pid, .seq_cst);
    if (shutdownRequested()) {
        forwardShutdownSignal(shutdown_signal.load(.seq_cst));
    }
    var ipc_conn = ipc_module.Ipc.initFromFd(fds[0]);
    defer ipc_conn.deinit();

    try run(allocator, .{
        .service_name = service,
        .ipc_conn = &ipc_conn,
        .greeter_pid = greeter_pid,
    });
}

pub fn run(allocator: std.mem.Allocator, opts: SessionWorkerRunOpts) !void {
    var event_buf: [ipc_module.GREETER_BUF_SIZE]u8 = undefined;
    var rbuf: [ipc_module.IPC_IO_BUF_SIZE]u8 = undefined;
    var wbuf: [ipc_module.IPC_IO_BUF_SIZE]u8 = undefined;
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
                const user_z = try allocator.dupeZ(u8, auth.user);
                defer allocator.free(user_z);
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
                var pam = try Pam(PamCtx).init(allocator, .{
                    .service_name = opts.service_name,
                    .user = null,
                    .state = &pam_state,
                });
                defer pam.deinit();
                try pam.setItem(.{ .user = user_z });

                pam.authenticate(.{}) catch {
                    if (ctx.cancelled) {
                        log.debug("Pam auth cancelled", .{});
                        continue;
                    }

                    const fail = ipc_module.IpcEvent{ .pam_auth_result = .{ .ok = false } };
                    opts.ipc_conn.writeEvent(ipc_writer, &fail) catch {};
                    ipc_writer.flush() catch {};
                    continue;
                };
                try pam.accountMgmt(.{});

                const ok = ipc_module.IpcEvent{ .pam_auth_result = .{ .ok = true } };
                try opts.ipc_conn.writeEvent(ipc_writer, &ok);
                try ipc_writer.flush();

                var session_envmap = std.process.EnvMap.init(allocator);
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
                                break :blk try startSession(allocator, user_z, info, &pam, &session_envmap, opts.vt);
                            };

                            log.debug("Waiting for session to end...", .{});
                            defer switch (session) {
                                .X11 => |*x11_session| x11_session.deinit(),
                                else => {},
                            };

                            const session_pid = switch (session) {
                                .Command => |pid| pid,
                                .X11 => |x11_session| x11_session.client_pid,
                            };
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
}

fn forwardShutdownSignal(sig: u8) void {
    const child_pid = active_child_pid.load(.seq_cst);
    if (child_pid > 0) {
        std.posix.kill(child_pid, sig) catch {};
    }
}

fn handleShutdownSignal(sig: i32) callconv(.c) void {
    const sig_u8: u8 = @intCast(sig);
    shutdown_signal.store(sig_u8, .seq_cst);
    forwardShutdownSignal(sig_u8);
}

// Creates /tmp/zgsld/$UID for a user
fn ensureFallbackRuntimeDir(
    buf: []u8,
    uid: std.posix.uid_t,
    gid: std.posix.gid_t,
) ![]const u8 {
    const base_dir = "/tmp/zgsld";
    try utils.ensureDirOwned(base_dir, 0o755, 0, 0);

    const user_dir = try std.fmt.bufPrint(buf, "{s}/{d}", .{ base_dir, uid });
    try utils.ensureDirOwned(user_dir, 0o700, uid, gid);
    return user_dir;
}

fn resolveUserRuntimeDir(
    buf: []u8,
    uid: std.posix.uid_t,
    gid: std.posix.gid_t,
) ![]const u8 {
    if (std.posix.getenv("XDG_RUNTIME_DIR")) |runtime_dir_z| {
        const runtime_dir = std.mem.trimRight(u8, runtime_dir_z, "/");
        if (runtime_dir.len != 0) {
            if (std.fs.openDirAbsolute(runtime_dir, .{})) |dir| {
                var writable_dir = dir;
                writable_dir.close();
                return runtime_dir;
            } else |_| {}
        }
    }

    const user_dir = try std.fmt.bufPrint(buf, "/tmp/zgsld-{d}", .{uid});
    try utils.ensureDirOwned(user_dir, 0o700, uid, gid);
    return user_dir;
}

pub fn spawnGreeter(
    greeter_argv: [:null]const ?[*:0]const u8,
    greeter_user: []const u8,
    ipc_fd: std.posix.fd_t,
    close_fd: std.posix.fd_t,
) !std.posix.pid_t {
    var user_buf: [64]u8 = undefined;
    const greeter_user_z = try std.fmt.bufPrintZ(&user_buf, "{s}", .{greeter_user});

    const pw = std.c.getpwnam(greeter_user_z) orelse return error.GreeterUserNotFound;
    const greeter_info: UserInfo = .{
        .username = greeter_user_z,
        .uid = pw.uid,
        .gid = pw.gid,
    };

    var runtime_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    var runtime_dir: []const u8 = undefined;
    if (std.posix.geteuid() != 0) {
        // for previews, we can default to this
        runtime_dir = try resolveUserRuntimeDir(&runtime_dir_buf, pw.uid, pw.gid);
    } else {
        runtime_dir = try std.fmt.bufPrint(&runtime_dir_buf, "/run/user/{d}", .{pw.uid});

        utils.ensureDirOwned(runtime_dir, 0o700, pw.uid, pw.gid) catch {
            runtime_dir = try ensureFallbackRuntimeDir(&runtime_dir_buf, pw.uid, pw.gid);
        };
    }

    const pid = try std.posix.fork();
    if (pid == 0) {
        std.posix.close(close_fd);

        var fd_buf: [32]u8 = undefined;
        const zgsld_sock = try std.fmt.bufPrintZ(&fd_buf, "ZGSLD_SOCK={d}", .{ipc_fd});
        var xdg_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
        const xdg_runtime_dir = try std.fmt.bufPrintZ(&xdg_buf, "XDG_RUNTIME_DIR={s}", .{runtime_dir});

        var path_env: ?[*:0]const u8 = null;

        const envp = std.c.environ;
        var i: usize = 0;
        while (envp[i]) |entry| : (i += 1) {
            const span = std.mem.span(entry);
            if (std.mem.startsWith(u8, span, "PATH=")) {
                path_env = entry;
                break;
            }
        }

        const log_fd = std.posix.dup(std.posix.STDERR_FILENO) catch null;
        if (log_fd) |fd| {
            _ = std.posix.fcntl(fd, std.posix.F.SETFD, 0) catch {};
        }
        var log_env: ?[*:0]const u8 = null;
        var log_buf: [64]u8 = undefined;
        if (log_fd) |fd| {
            log_env = std.fmt.bufPrintZ(&log_buf, "ZGSLD_LOG={d}", .{fd}) catch null;
        }

        var greeter_env_buf: [5]?[*:0]const u8 = .{ zgsld_sock, xdg_runtime_dir } ++ .{null} ** 3;
        var greeter_env_len: usize = 2;
        if (path_env) |path| {
            greeter_env_buf[greeter_env_len] = path;
            greeter_env_len += 1;
        }
        if (log_env) |env| {
            greeter_env_buf[greeter_env_len] = env;
            greeter_env_len += 1;
        }
        const greeter_environ: [*:null]const ?[*:0]const u8 = @ptrCast(&greeter_env_buf);

        utils.dropPrivileges(greeter_info) catch std.process.exit(1);

        if (greeter_argv.len == 0 or greeter_argv[0] == null or greeter_argv[greeter_argv.len] != null) {
            log.err("Invalid greeter argv", .{});
            std.process.exit(1);
        }

        const greeter_path = greeter_argv[0].?;
        const argv = @as([*:null]const ?[*:0]const u8, @ptrCast(greeter_argv.ptr));

        vt_mod.redirectStdioToControllingTty() catch {
            log.err("Failed to redirect greeter stdio", .{});
        };

        std.posix.execvpeZ(greeter_path, argv, greeter_environ) catch {
            log.err("Greeter exec error\n", .{});
        };
        std.process.exit(1);
    }
    return pid;
}

fn createSocketPair() ![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (rc != 0) return std.posix.unexpectedErrno(std.posix.errno(rc));
    return fds;
}

const Session = union(ipc_module.SessionType) {
    Command: std.posix.pid_t,
    X11: struct {
        const X11Session = @This();

        client_pid: std.posix.pid_t,
        launcher_pid: std.posix.pid_t,
        server_pid: std.posix.pid_t,
        server_detached: bool,

        xauth_path: [:0]const u8,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *X11Session) void {
            if (self.server_pid > 0) {
                std.posix.kill(self.server_pid, std.posix.SIG.TERM) catch {};
            }

            if (!self.server_detached) {
                _ = std.posix.waitpid(self.server_pid, 0);
            } else if (self.launcher_pid > 0) {
                _ = std.posix.waitpid(self.launcher_pid, std.posix.W.NOHANG);
            }

            std.fs.deleteFileAbsolute(self.xauth_path) catch {};
            self.allocator.free(self.xauth_path);
        }
    },
};

const X11Setup = struct {
    display: u8,
    xauth_path: [:0]const u8,
};

fn startSession(
    allocator: std.mem.Allocator,
    user: [:0]const u8,
    info: ipc_module.SessionInfo,
    pam: *Pam(PamCtx),
    session_envmap: *std.process.EnvMap,
    vt: ?u8,
) !Session {
    if (!build_options.x11_support and info.session_type == .X11) {
        return error.X11UnsupportedBuild;
    }

    const pw = std.c.getpwnam(user) orelse return error.UserUnknown;
    var x11_setup: ?X11Setup = null;
    errdefer if (x11_setup) |setup| {
        std.fs.deleteFileAbsolute(setup.xauth_path) catch {};
        allocator.free(setup.xauth_path);
    };

    if (session_envmap.get("XDG_CURRENT_DESKTOP")) |v| {
        try pam.putEnvAlloc("XDG_CURRENT_DESKTOP", v);
    }
    if (session_envmap.get("XDG_SESSION_DESKTOP")) |v| {
        try pam.putEnvAlloc("XDG_SESSION_DESKTOP", v);
    }
    if (session_envmap.get("XDG_SESSION_TYPE")) |v| {
        try pam.putEnvAlloc("XDG_SESSION_TYPE", v);
    }

    if (vt) |vt_num| {
        var vt_buf: [3]u8 = undefined;
        const vt_value = try std.fmt.bufPrint(&vt_buf, "{d}", .{vt_num});
        try pam.putEnvAlloc("XDG_VTNR", vt_value);
    }

    try pam.putEnv("XDG_SESSION_CLASS=user");

    if (std.posix.geteuid() == 0) {
        try pam.setCred(.{ .action = .establish });
        try pam.openSession(.{});
    }

    // Add pam env list to the envmap (overwrites)
    try pam.addEnvListToMap(session_envmap);

    if (pw.dir) |home_dir| {
        const s = std.mem.span(home_dir);
        try session_envmap.put("HOME", s);
        try session_envmap.put("PWD", s);
        std.posix.chdir(s) catch {};
    }

    try session_envmap.put("USER", user);
    try session_envmap.put("LOGNAME", user);
    if (pw.shell) |shell| {
        try session_envmap.put("SHELL", std.mem.span(shell));
    }

    if (build_options.x11_support and info.session_type == .X11) {
        const display_num = try x11.findFreeDisplay();

        var display_buf: [4]u8 = undefined;
        const display_env = try std.fmt.bufPrint(&display_buf, ":{d}", .{display_num});
        try session_envmap.put("DISPLAY", display_env);

        var xauth_buf: [std.fs.max_path_bytes]u8 = undefined;
        const runtime_dir = session_envmap.get("XDG_RUNTIME_DIR");
        const xauth_path = try x11.xauth.createXauthEntry(&xauth_buf, display_env[1..], pw.uid, pw.gid, runtime_dir);
        const xauth_path_z = try allocator.dupeZ(u8, xauth_path);
        try session_envmap.put("XAUTHORITY", xauth_path_z);

        x11_setup = .{
            .display = display_num,
            .xauth_path = xauth_path_z,
        };
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const session_environ = try std.process.createNullDelimitedEnvMap(arena.allocator(), session_envmap);

    const user_info: UserInfo = .{
        .username = user,
        .uid = pw.uid,
        .gid = pw.gid,
    };

    if (build_options.x11_support and info.session_type == .X11) {
        const setup = x11_setup orelse return error.X11SetupMissing;
        const x_cmd = std.posix.getenv("ZGSLD_X11_CMD") orelse "/bin/X";

        const launcher_pid = try x11.startXServer(.{
            .x_cmd = x_cmd,
            .xauth_path = setup.xauth_path,
            .display = setup.display,
            .vt = vt,
            .user = user_info,
        });

        errdefer {
            if (x11.readXServerPid(setup.display)) |pid| {
                std.posix.kill(pid, std.posix.SIG.TERM) catch {};
                if (pid == launcher_pid) {
                    _ = std.posix.waitpid(pid, 0);
                }
            }
            if (launcher_pid > 0) {
                std.posix.kill(launcher_pid, std.posix.SIG.TERM) catch {};
                _ = std.posix.waitpid(launcher_pid, std.posix.W.NOHANG);
            }
        }

        const server_info = try x11.waitForXServer(setup.display, launcher_pid, 5000);

        const client_pid = try runSessionCommand(allocator, info.command, user_info, session_environ);

        return .{
            .X11 = .{
                .client_pid = client_pid,
                .launcher_pid = launcher_pid,
                .server_pid = server_info.server_pid,
                .server_detached = server_info.detached,
                .xauth_path = setup.xauth_path,
                .allocator = allocator,
            },
        };
    }

    const session_pid = try runSessionCommand(allocator, info.command, user_info, session_environ);
    return .{ .Command = session_pid };
}

pub fn runSessionCommand(allocator: std.mem.Allocator, cmd: ipc_module.SessionCommand, user_info: UserInfo, environ: [:null]const ?[*:0]const u8) !std.posix.pid_t {
    const prefix = if (cmd.source_profile) blk: {
        break :blk "[ -f /etc/profile ] && . /etc/profile; [ -f $HOME/.profile ] && . $HOME/.profile; exec ";
    } else "exec ";

    const shell_cmd = try std.mem.concatWithSentinel(allocator, u8, &.{ prefix, cmd.session_cmd }, 0);
    defer allocator.free(shell_cmd);

    const wrapper = [_]?[*:0]const u8{ "/bin/sh", "-c", shell_cmd.ptr, null };

    return try startCommandSession(user_info, &wrapper, environ);
}

fn startCommandSession(
    user_info: UserInfo,
    argv: []const ?[*:0]const u8,
    session_environ: [:null]const ?[*:0]const u8,
) !std.posix.pid_t {
    const session_pid = try std.posix.fork();
    if (session_pid == 0) {
        vt_mod.redirectStdioToControllingTty() catch {
            log.err("Failed to redirect session stdio", .{});
            std.process.exit(1);
        };

        utils.dropPrivileges(user_info) catch std.process.exit(1);

        const cmd_path = argv[0] orelse std.process.exit(1);
        const argv_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(argv.ptr);
        std.posix.execvpeZ(cmd_path, argv_ptr, session_environ) catch {};
        std.process.exit(1);
    }

    return session_pid;
}

fn loginConv(
    _: std.mem.Allocator,
    msgs: pam_module.Messages,
    ctx: *PamCtx,
) !void {
    if (ctx.cancelled) return error.Abort;

    const ipc_reader = ctx.reader;
    const ipc_writer = ctx.writer;

    var ipc_buf: [ipc_module.PAM_CONV_BUF_SIZE]u8 = undefined;
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
