const std = @import("std");
const pam_module = @import("pam");
const Pam = pam_module.Pam;
const ipc_module = @import("ipc.zig");
const builtin = @import("builtin");
const log = std.log.scoped(.zgsld_worker);
const vt_mod = @import("vt.zig");
const c = @cImport({
    if (builtin.os.tag == .linux) {
        @cInclude("grp.h");
    } else if (builtin.os.tag == .freebsd) {
        @cInclude("unistd.h");
    }
});

const UserInfo = struct {
    user: [:0]const u8,
    uid: std.posix.uid_t,
    gid: std.posix.gid_t,
};

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
                    const session_event = try opts.ipc_conn.readEvent(ipc_reader, &event_buf);
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
                            log.debug("Starting session...", .{});
                            const pid = blk: {
                                defer session_envmap.deinit();
                                break :blk try startSession(allocator, user_z, info, &pam, &session_envmap, opts.vt);
                            };

                            log.debug("Waiting for session to end...", .{});
                            _ = std.posix.waitpid(pid, 0);
                            std.process.exit(0);
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

fn ensureRuntimeDir(path: []const u8, uid: std.posix.uid_t, gid: std.posix.gid_t) !void {
    std.posix.mkdir(path, 0o700) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
    defer dir.close();

    try dir.chmod(0o700);
    try dir.chown(uid, gid);
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

    var runtime_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    var runtime_dir = try std.fmt.bufPrint(&runtime_dir_buf, "/run/user/{d}", .{pw.uid});
    ensureRuntimeDir(runtime_dir, pw.uid, pw.gid) catch {
        runtime_dir = try std.fmt.bufPrint(&runtime_dir_buf, "/tmp", .{});
    };

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

        var greeter_env_buf: [5]?[*:0]const u8 = .{ zgsld_sock, xdg_runtime_dir } ++ .{ null } ** 3;
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

        if (std.posix.geteuid() == 0) {
            if (c.initgroups(greeter_user_z, pw.gid) != 0) {
                const err = std.posix.errno(-1);
                log.err("initgroups failed: {s}", .{@tagName(err)});
                std.process.exit(1);
            }
            std.posix.setgid(pw.gid) catch {
                log.err("setgid error", .{});
                std.process.exit(1);
            };
            std.posix.setuid(pw.uid) catch {
                log.err("setuid error", .{});
                std.process.exit(1);
            };
        }

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

fn startSession(
    allocator: std.mem.Allocator,
    user: [:0]const u8,
    info: ipc_module.SessionInfo,
    pam: *Pam(PamCtx),
    session_envmap: *std.process.EnvMap,
    vt: ?u8,
) !std.posix.fd_t {
    const pw = std.c.getpwnam(user) orelse return error.UserUnknown;

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

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const session_environ = try std.process.createNullDelimitedEnvMap(arena.allocator(), session_envmap);

    const user_info: UserInfo = .{
        .user = user,
        .uid = pw.uid,
        .gid = pw.gid,
    };

    const cmd = info.command;
    const argv = try buildArgv(allocator, cmd.argv);
    defer allocator.free(argv);

    if (cmd.source_profile) {
        const shell_cmd = try buildProfileShellCommand(allocator, argv);
        defer allocator.free(shell_cmd);
        const wrapper = [_]?[*:0]const u8{ "/bin/sh", "-c", shell_cmd.ptr, null };
        return switch (info.session_type) {
            .Command => try startCommandSession(user_info, &wrapper, session_environ),
            .X11 => |_| unreachable,
        };
    }

    return switch (info.session_type) {
        .Command => try startCommandSession(user_info, argv, session_environ),
        .X11 => |_| unreachable,
    };
}

fn startCommandSession(
    user_info: UserInfo,
    argv: []const ?[*:0]const u8,
    session_environ: [:null]?[*:0]u8,
) !std.posix.pid_t {
    const session_pid = try std.posix.fork();
    if (session_pid == 0) {
        vt_mod.redirectStdioToControllingTty() catch {
            log.err("Failed to redirect session stdio", .{});
            std.process.exit(1);
        };

        if (std.posix.geteuid() == 0) {
            if (c.initgroups(user_info.user, user_info.gid) != 0) std.process.exit(1);
            std.posix.setgid(user_info.gid) catch std.process.exit(1);
            std.posix.setuid(user_info.uid) catch std.process.exit(1);
        }

        const cmd_path = argv[0] orelse std.process.exit(1);
        const argv_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(argv.ptr);
        std.posix.execvpeZ(cmd_path, argv_ptr, session_environ) catch {};
        std.process.exit(1);
    }

    return session_pid;
}

fn buildProfileShellCommand(
    allocator: std.mem.Allocator,
    argv: []?[*:0]const u8,
) ![:0]const u8 {
    const prefix =
        "[ -f /etc/profile ] && . /etc/profile; [ -f $HOME/.profile ] && . $HOME/.profile; exec";
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);
    try list.appendSlice(allocator, prefix);

    for (argv) |arg| {
        try list.append(allocator, ' ');
        try appendShellEscaped(allocator, &list, std.mem.span(arg.?));
    }

    return try list.toOwnedSliceSentinel(allocator, 0);
}

fn appendShellEscaped(allocator: std.mem.Allocator, list: *std.ArrayList(u8), arg: []const u8) !void {
    try list.append(allocator, '\'');
    for (arg) |ch| {
        if (ch == '\'') {
            try list.appendSlice(allocator, "'\\''");
        } else {
            try list.append(allocator, ch);
        }
    }
    try list.append(allocator, '\'');
}

fn buildArgv(allocator: std.mem.Allocator, argv_buf: []const u8) ![]?[*:0]const u8 {
    // argv_buf must be NUL-separated arguments with a trailing NUL.
    if (argv_buf.len == 0
        or argv_buf[argv_buf.len - 1] != 0
        or argv_buf[0] == 0)
    {
        return error.InvalidPayload;
    }

    var argc: usize = 0;
    for (argv_buf) |b| { if (b == 0) argc += 1; }

    var argv = try allocator.allocSentinel(?[*:0]const u8, argc, null);
    errdefer allocator.free(argv);

    var arg_index: usize = 0;
    var start: usize = 0;
    for (argv_buf,0..) |ch,i| {
        if (ch == 0) {
            if (i == start) return error.InvalidPayload;
            argv[arg_index] = @ptrCast(argv_buf.ptr + start);
            arg_index += 1;
            start = i + 1;
        }
    }
    return argv;
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
