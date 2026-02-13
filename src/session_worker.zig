const std = @import("std");
const pam_module = @import("auth/pam.zig");
const Pam = pam_module.Pam;
const ipc_module = @import("ipc.zig");
const builtin = @import("builtin");
const log = std.log.scoped(.zgsld_worker);
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
};

const SessionEnvKey = enum {
    PATH,
    XDG_SESSION_DESKTOP,
    XDG_CURRENT_DESKTOP,
    XDG_SESSION_TYPE,
};

pub fn run(allocator: std.mem.Allocator, opts: SessionWorkerRunOpts) !bool {
    var event_buf: [ipc_module.GREETER_BUF_SIZE]u8 = undefined;
    var rbuf: [ipc_module.IPC_IO_BUF_SIZE]u8 = undefined;
    var wbuf: [ipc_module.IPC_IO_BUF_SIZE]u8 = undefined;

    var reader = opts.ipc_conn.reader(&rbuf);
    var writer = opts.ipc_conn.writer(&wbuf);
    const ipc_reader = &reader.interface;
    const ipc_writer = &writer.interface;

    while (true) {
        log.debug("Waiting for event", .{});
        const event = try opts.ipc_conn.readEvent(ipc_reader, &event_buf);
        switch (event) {
            .login_cancel => {
                log.debug("Login cancelled before auth start", .{});
                continue;
            },
            .pam_start_auth => |auth| {
                const user_z = try allocator.dupeZ(u8, auth.user);
                defer allocator.free(user_z);
                var ctx = pam_module.PamCtx{
                    .cancelled = false,
                    .user = user_z,
                    .ipc = opts.ipc_conn,
                    .reader = ipc_reader,
                    .writer = ipc_writer,
                };
                var pam = try Pam.init(opts.service_name, &ctx, allocator);
                defer pam.deinit();
                try pam.setItem(pam_module.pam.PAM_USER, user_z);

                pam.authenticate() catch {
                    if (ctx.cancelled) {
                        log.debug("Pam auth cancelled", .{});
                        continue;
                    }

                    const fail = ipc_module.IpcEvent{ .pam_auth_result = .{ .ok = false } };
                    opts.ipc_conn.writeEvent(ipc_writer, &fail) catch {};
                    ipc_writer.flush() catch {};
                    continue;
                };

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
                            log.debug("Starting session...", .{});
                            const pid = blk: {
                                defer session_envmap.deinit();
                                break :blk try startSession(allocator, user_z, info, &pam, &session_envmap, opts.vt);
                            };

                            log.debug("Waiting for session to end...", .{});
                            const status = std.posix.waitpid(pid, 0);
                            std.process.exit(std.c.W.EXITSTATUS(status.status));
                        },
                        else => unreachable,
                    }
                }
                break;
            },
            else => unreachable,
        }
    }
    return false;
}

fn startSession(
    allocator: std.mem.Allocator,
    user: [:0]const u8,
    info: ipc_module.SessionInfo,
    pam: *Pam,
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
        try pam.establishCred();
        try pam.openSession();
    }

    // Add pam env list to the envmap (overwrites)
    try pam.putEnvList(session_envmap);

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

    var argc: usize = 0;
    while (argc < argv.len and argv[argc] != null) : (argc += 1) {}
    for (argv[0..argc]) |arg| {
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
    if (argv_buf.len == 0 or argv_buf[argv_buf.len - 1] != 0) {
        return error.InvalidPayload;
    }
    if (argv_buf[0] == 0) return error.InvalidPayload;

    var argc: usize = 0;
    for (argv_buf) |b| {
        if (b == 0) argc += 1;
    }

    var argv = try allocator.alloc(?[*:0]const u8, argc + 1);
    errdefer allocator.free(argv);
    var arg_index: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < argv_buf.len) : (i += 1) {
        if (argv_buf[i] == 0) {
            if (i == start) return error.InvalidPayload;
            argv[arg_index] = @ptrCast(argv_buf.ptr + start);
            arg_index += 1;
            start = i + 1;
        }
    }
    argv[arg_index] = null;
    return argv;
}
