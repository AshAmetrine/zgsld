const std = @import("std");
const pam_module = @import("auth/pam.zig");
const Pam = pam_module.Pam;
const ipc_module = @import("ipc");
const c = @cImport({
    @cInclude("grp.h");
    @cInclude("pwd.h");
});

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, replace: c_int) c_int;

const GreeterHandle = struct {
    ipc: ipc_module.Ipc,
    pid: std.posix.pid_t,
};


pub const SessionManagerRunOpts = struct {
    service_name: []const u8,
    greeter_path: [:0]const u8,
    greeter_user: []const u8,
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

pub fn run(allocator: std.mem.Allocator, opts: SessionManagerRunOpts) !void {
    var event_buf: [ipc_module.GREETER_BUF_SIZE]u8 = undefined;

    var greeter = try spawnGreeter(opts.greeter_path, opts.greeter_user, opts.vt);
    defer {
        _ = std.posix.waitpid(greeter.pid, 0);
        greeter.ipc.deinit();
    }

    while (true) {
        const event = try greeter.ipc.readEvent(&event_buf);
        switch (event) {
            .pam_start_auth => |auth| {
                const user_z = try allocator.dupeZ(u8, auth.user);
                defer allocator.free(user_z);
                var ctx = pam_module.PamCtx{
                    .user = user_z,
                    .ipc = &greeter.ipc,
                };
                var pam = try Pam.init(opts.service_name, &ctx);
                defer pam.deinit();
                try pam.setItem(pam_module.pam.PAM_USER, user_z);

                pam.authenticate() catch {
                    const fail = ipc_module.IpcEvent{ .pam_auth_result = .{ .ok = false } };
                    greeter.ipc.writeEvent(&fail) catch {};
                    greeter.ipc.flush() catch {};
                    continue;
                };

                const ok = ipc_module.IpcEvent{ .pam_auth_result = .{ .ok = true } };
                try greeter.ipc.writeEvent(&ok);
                try greeter.ipc.flush();

                var session_env: SessionEnvKV = .{};

                while (true) {
                    const session_event = try greeter.ipc.readEvent(&event_buf);
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
                            const pid = try startSession(allocator, user_z, info, &pam, session_env, opts.vt);
                            session_env.deinit(allocator);
                            // We can deinit pam outside the fork()
                            pam.deinit();

                            // kill greeter
                            std.debug.print("Waiting for session to end...",.{});
                            const status = std.posix.waitpid(pid, 0);
                            if (status.status != 0) {
                                std.debug.print("Session Start Failed\n",.{});
                            }
                            break;
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

fn startSession(
    allocator: std.mem.Allocator,
    user: [:0]const u8,
    info: ipc_module.SessionInfo,
    pam: *Pam,
    session_env: SessionEnvKV,
    vt: ?u8,
) !std.posix.fd_t {
    switch (info) {
        .Command => |cmd| {
            return try startCommandSession(allocator, user, cmd.argv, pam, session_env, vt);
        },
        .X11 => |_| unreachable,
    }
}

fn startCommandSession(
    allocator: std.mem.Allocator,
    user: [:0]const u8,
    argv_buf: []const u8,
    pam: *Pam,
    session_env: SessionEnvKV,
    vt: ?u8,
) !std.posix.pid_t {
    const pw = c.getpwnam(user) orelse return error.UserNotFound;
    const uid: std.posix.uid_t = @intCast(pw.*.pw_uid);
    const gid: std.posix.gid_t = @intCast(pw.*.pw_gid);
    const shell: [*:0]const u8 = pw.*.pw_shell;
    const home: ?[*:0]const u8 = pw.*.pw_dir;

    const helper_pid = try std.posix.fork();
    if (helper_pid == 0) {
        std.debug.print("Helper Started...\n",.{});
        if (session_env.xdg_current_desktop) |v| {
            pam.putEnv(v) catch std.process.exit(1);
        }
        if (session_env.xdg_session_desktop) |v| {
            pam.putEnv(v) catch std.process.exit(1);
        }
        if (session_env.xdg_session_type) |v| {
            pam.putEnv(v) catch std.process.exit(1);
        }
        if (vt) |vt_num| {
            var vt_buf: [17]u8 = undefined;
            const vt_z = std.fmt.bufPrintZ(&vt_buf, "XDG_VTNR={d}", .{vt_num}) catch std.process.exit(1);
            pam.putEnv(vt_z) catch std.process.exit(1);
        }
        pam.putEnv("XDG_SESSION_CLASS=user") catch std.process.exit(1);

        if (std.posix.geteuid() == 0) {
            pam.establishCred() catch std.process.exit(1);
            pam.openSession() catch std.process.exit(1);
        }

        var session_envmap = pam.createEnvListMap(allocator) catch std.process.exit(1);
        if (home) |home_dir| {
            const s = std.mem.span(home_dir);
            session_envmap.put("HOME", s) catch std.process.exit(1);
            session_envmap.put("PWD", s) catch std.process.exit(1);
            std.posix.chdir(s) catch {};
            //std.posix.chdirZ(home_dir) catch {};
        }

        session_envmap.put("USER", user) catch std.process.exit(1);
        session_envmap.put("LOGNAME", user) catch std.process.exit(1);
        session_envmap.put("SHELL", std.mem.span(shell)) catch std.process.exit(1);

        if (session_env.path) |path| {
            session_envmap.put("PATH", path) catch std.process.exit(1);
        }

        var arena = std.heap.ArenaAllocator.init(allocator);
        const session_environ = std.process.createNullDelimitedEnvMap(arena.allocator(), &session_envmap) catch std.process.exit(1);
        session_envmap.deinit();

        const session_pid = std.posix.fork() catch std.process.exit(1);
        if (session_pid == 0) {
            if (std.posix.geteuid() == 0) {
                if (c.initgroups(user, gid) != 0) return error.InitGroupsFailed;
                std.posix.setgid(gid) catch std.process.exit(1);
                std.posix.setuid(uid) catch std.process.exit(1);
            }

            const argv = buildArgv(allocator, argv_buf) catch std.process.exit(1);
            defer allocator.free(argv);
            const cmd_path = argv[0] orelse std.process.exit(1);
            const argv_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(argv.ptr);
            std.posix.execvpeZ(cmd_path, argv_ptr, session_environ) catch {};
            std.process.exit(1);
        }

        // deinit session_envmap
        arena.deinit();

        const status = std.posix.waitpid(session_pid, 0);
        pam.deinit();
        if (status.status != 0) {
            std.process.exit(1);
        }
        std.process.exit(0);
    }

    return helper_pid;
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

fn spawnGreeter(greeter_path: [:0]const u8, greeter_user: []const u8, vt: ?u8) !GreeterHandle {
    _ = vt;
    std.debug.print("Spawning Greeter...\n", .{});
    var user_buf: [64]u8 = undefined;
    const greeter_user_z = try std.fmt.bufPrintZ(&user_buf, "{s}", .{greeter_user});

    const pw = c.getpwnam(greeter_user_z) orelse return error.GreeterUserNotFound;
    const greeter_uid: std.posix.uid_t = @intCast(pw.*.pw_uid);
    const greeter_gid: std.posix.gid_t = @intCast(pw.*.pw_gid);
    var fds: [2]std.posix.fd_t = undefined;
    _ = std.c.socketpair(
        std.c.AF.UNIX,
        std.c.SOCK.STREAM,
        0,
        &fds,
    );

    const pid = try std.posix.fork();
    if (pid == 0) {
        std.posix.close(fds[0]);

        var fd_buf: [27]u8 = undefined;
        const zgsld_sock = try std.fmt.bufPrintZ(&fd_buf, "ZGSLD_SOCK={d}", .{fds[1]});
        const greeter_environ: [*:null]const ?[*:0]const u8 = &.{
            zgsld_sock,
            null,
        };

        if (std.posix.geteuid() == 0) {
            if (c.initgroups(greeter_user_z, greeter_gid) != 0) {
                const err = std.posix.errno(-1);
                std.debug.print("initgroups failed: {s}\n", .{@tagName(err)});
                std.process.exit(1);
            }

            std.posix.setgid(greeter_gid) catch {
                std.debug.print("setgid error",.{});
                std.process.exit(1);
            };
            std.posix.setuid(greeter_uid) catch {
                std.debug.print("setuid error",.{});
                std.process.exit(1);
            };
        }

        const argv = [_:null]?[*:0]const u8{ greeter_path, null };
        std.posix.execvpeZ(greeter_path, &argv, greeter_environ) catch {
            std.debug.print("Exec error",.{});
        };
        std.process.exit(1);
    }
    std.posix.close(fds[1]);

    return .{
        .ipc = ipc_module.Ipc.initFromFd(fds[0]),
        .pid = pid,
    };
}
