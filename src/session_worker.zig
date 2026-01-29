const std = @import("std");
const pam_module = @import("auth/pam.zig");
const Pam = pam_module.Pam;
const ipc_module = @import("ipc");
const builtin = @import("builtin");

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

// stored: KEY=VALUE
pub const SessionEnvKV = struct {
    path: ?[:0]const u8  = null,
    xdg_session_desktop: ?[:0]const u8 = null,
    xdg_current_desktop: ?[:0]const u8 = null,
    xdg_session_type: ?[:0]const u8 = null,

    pub fn deinit(self: *SessionEnvKV, allocator: std.mem.Allocator) void {
        if (self.path) |v| allocator.free(v);
        if (self.xdg_session_desktop) |v| allocator.free(v);
        if (self.xdg_current_desktop) |v| allocator.free(v);
        if (self.xdg_session_type) |v| allocator.free(v);
        self.* = .{};
    }
};

pub fn run(allocator: std.mem.Allocator, opts: SessionWorkerRunOpts) !bool {
    var event_buf: [ipc_module.GREETER_BUF_SIZE]u8 = undefined;

    while (true) {
        const event = try opts.ipc_conn.readEvent(&event_buf);
        switch (event) {
            .pam_start_auth => |auth| {
                const user_z = try allocator.dupeZ(u8, auth.user);
                defer allocator.free(user_z);
                var ctx = pam_module.PamCtx{
                    .user = user_z,
                    .ipc = opts.ipc_conn,
                };
                var pam = try Pam.init(opts.service_name, &ctx);
                defer pam.deinit();
                try pam.setItem(pam_module.pam.PAM_USER, user_z);

                pam.authenticate() catch {
                    const fail = ipc_module.IpcEvent{ .pam_auth_result = .{ .ok = false } };
                    opts.ipc_conn.writeEvent(&fail) catch {};
                    opts.ipc_conn.flush() catch {};
                    continue;
                };

                const ok = ipc_module.IpcEvent{ .pam_auth_result = .{ .ok = true } };
                try opts.ipc_conn.writeEvent(&ok);
                try opts.ipc_conn.flush();

                var session_env: SessionEnvKV = .{};

                while (true) {
                    const session_event = try opts.ipc_conn.readEvent(&event_buf);
                    switch (session_event) {
                        .set_session_env => |env| {
                            const env_key = std.meta.stringToEnum(SessionEnvKey, env.key) orelse break;

                            errdefer session_env.deinit(allocator);

                            const value = try std.fmt.allocPrintSentinel(allocator, "{s}={s}", .{env.key, env.value}, 0);

                            switch (env_key) {
                                .PATH => session_env.path = value,
                                .XDG_SESSION_DESKTOP => session_env.xdg_session_desktop = value,
                                .XDG_CURRENT_DESKTOP => session_env.xdg_current_desktop = value,
                                .XDG_SESSION_TYPE => session_env.xdg_session_type = value,
                            }
                        },
                        .start_session => |info| {
                            // We should wait for the greeter to end in the session manager, then forward this event.
                            const pid = blk: {
                                defer session_env.deinit(allocator);
                                break :blk try startSession(allocator, user_z, info, &pam, session_env, opts.vt);
                            };

                            std.debug.print("Waiting for session to end...\n",.{});
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
    session_env: SessionEnvKV,
    vt: ?u8,
) !std.posix.fd_t {
    const pw = std.c.getpwnam(user) orelse return error.UserUnknown;

    if (session_env.xdg_current_desktop) |v| {
        try pam.putEnv(v);
    }
    if (session_env.xdg_session_desktop) |v| {
        try pam.putEnv(v);
    }
    if (session_env.xdg_session_type) |v| {
        try pam.putEnv(v);
    }

    if (vt) |vt_num| {
        var vt_buf: [17]u8 = undefined;
        const vt_z = try std.fmt.bufPrintZ(&vt_buf, "XDG_VTNR={d}", .{vt_num});
        try pam.putEnv(vt_z);
    }
    try pam.putEnv("XDG_SESSION_CLASS=user");

    if (std.posix.geteuid() == 0) {
        try pam.establishCred();
        try pam.openSession();
    }

    var session_envmap = try pam.createEnvListMap(allocator);
    defer session_envmap.deinit();
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

    if (session_env.path) |path| {
        try session_envmap.put("PATH", path);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const session_environ = try std.process.createNullDelimitedEnvMap(arena.allocator(), &session_envmap);
 
    const user_info: UserInfo = .{ 
        .user = user,
        .uid = pw.uid,
        .gid = pw.gid,
    };

    switch (info) {
        .Command => |cmd| {
            const argv = try buildArgv(allocator, cmd.argv);
            defer allocator.free(argv);

            return try startCommandSession(user_info, argv, session_environ);
        },
        .X11 => |_| unreachable,
    }
}

fn startCommandSession(
    user_info: UserInfo,
    argv: []?[*:0]const u8,
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

fn buildArgv(allocator: std.mem.Allocator, argv_buf: []const u8) ![]?[*:0]const u8 {
    if (argv_buf.len == 0 or argv_buf[argv_buf.len - 1] != 0) {
        return error.InvalidPayload;
    }
    if (argv_buf[0] == 0) return error.InvalidPayload;

    var argc: usize = 0;
    for (argv_buf) |b| {
        if (b == 0) argc += 1;
    }

    var argv = try allocator.alloc(?[*:0]const u8, argc + 1);
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
