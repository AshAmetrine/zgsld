const std = @import("std");
const vt = @import("vt.zig");
const builtin = @import("builtin");
const c = @cImport({
    if (builtin.os.tag == .linux) {
        @cInclude("grp.h");
    } else if (builtin.os.tag == .freebsd) {
        @cInclude("unistd.h");
    }
});
const log = std.log.scoped(.zgsld);

pub const SessionManagerRunOpts = struct {
    self_exe_path: [:0]const u8,
    greeter_argv: [:null]const ?[*:0]const u8,
    greeter_user: []const u8,
    service_name: []const u8,
    vt: ?u8 = null,
};

pub fn run(opts: SessionManagerRunOpts) !void {
    if (opts.vt) |vt_num| {
        vt.initTty(vt_num) catch |err| {
            log.err("Failed to init VT {d}: {s}", .{ vt_num, @errorName(err) });
            std.process.exit(1);
        };
    }

    if (!try userExists(opts.greeter_user)) {
        log.err("Greeter user not found: {s}", .{ opts.greeter_user });
        return error.GreeterUserNotFound;
    }

    while (true) {
        const child_pids = blk: {
            const fds = try createSocketPair();
            defer {
                std.posix.close(fds[0]);
                std.posix.close(fds[1]);
            }

            log.debug("Spawning worker...", .{});
            const worker_pid = try spawnWorker(opts.self_exe_path, opts.service_name, fds[0], fds[1]);

            log.debug("Spawning greeter...", .{});
            const greeter_pid = try spawnGreeter(opts.greeter_argv, opts.greeter_user, fds[1], fds[0]);

            break :blk .{ .worker = worker_pid, .greeter = greeter_pid };
        };

        _ = std.posix.waitpid(child_pids.greeter, 0);
        log.info("Greeter stopped", .{});

        const status = std.posix.waitpid(child_pids.worker, 0);
        log.info("Worker stopped", .{});

        const st = status.status;
        if (std.c.W.IFEXITED(st) and std.c.W.EXITSTATUS(st) != 0) {
            log.err("Session error", .{});
        } else {
            log.info("Session executed successfully", .{});
        }

        if (opts.vt) |vt_id| {
            vt.resetTty(vt_id) catch |err| {
                log.err("Failed to reset VT {d}: {s}", .{ vt_id, @errorName(err) });
                return err;
            };
        }
    }
}

pub fn spawnWorker(worker_path: [:0]const u8, service_name: []const u8, ipc_fd: std.posix.fd_t, close_fd: std.posix.fd_t) !std.posix.pid_t {
    const pid = try std.posix.fork();
    if (pid == 0) {
        std.posix.close(close_fd);

        var fd_buf: [27]u8 = undefined;
        const zgsld_sock = try std.fmt.bufPrintZ(&fd_buf, "ZGSLD_SOCK={d}", .{ipc_fd});
        var service_buf: [std.fs.max_path_bytes]u8 = undefined;
        const zgsld_service = try std.fmt.bufPrintZ(&service_buf, "ZGSLD_SERVICE_NAME={s}", .{service_name});
        const worker_environ: [*:null]const ?[*:0]const u8 = &.{
            zgsld_sock,
            zgsld_service,
            null,
        };

        const argv = [_:null]?[*:0]const u8{ worker_path, "--session-worker", null };
        std.posix.execvpeZ(worker_path, &argv, worker_environ) catch {
            log.err("Worker exec error\n", .{});
        };
        std.process.exit(1);
    }
    return pid;
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

        const log_fd = captureGreeterLogFd();
        var log_fd_buf: [64]u8 = undefined;
        var log_fd_env: ?[*:0]const u8 = null;
        if (log_fd) |fd| {
            log_fd_env = std.fmt.bufPrintZ(&log_fd_buf, "ZGSLD_LOG={d}", .{fd}) catch null;
        }

        var fd_buf: [32]u8 = undefined;
        const zgsld_sock = try std.fmt.bufPrintZ(&fd_buf, "ZGSLD_SOCK={d}", .{ipc_fd});
        var xdg_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
        const xdg_runtime_dir = try std.fmt.bufPrintZ(&xdg_buf, "XDG_RUNTIME_DIR={s}", .{runtime_dir});

        var path_env: ?[*:0]const u8 = null;
        const envp = std.c.environ;
        var i: usize = 0;
        while (envp[i] != null) : (i += 1) {
            const entry = envp[i].?;
            if (std.mem.startsWith(u8, std.mem.span(entry), "PATH=")) {
                path_env = entry;
                break;
            }
        }

        var greeter_env_buf: [5]?[*:0]const u8 = .{ zgsld_sock, xdg_runtime_dir } ++ .{ null } ** 3;
        var greeter_env_len: usize = 2;
        if (path_env) |path| {
            greeter_env_buf[greeter_env_len] = path;
            greeter_env_len += 1;
        }
        if (log_fd_env) |env| {
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

        vt.redirectStdioToControllingTty() catch {
            log.err("Failed to redirect greeter stdio", .{});
        };

        std.posix.execvpeZ(greeter_path, argv, greeter_environ) catch {
            log.err("Greeter exec error\n", .{});
        };
        std.process.exit(1);
    }
    return pid;
}

fn userExists(user: []const u8) !bool {
    var user_buf: [64]u8 = undefined;
    const user_z = try std.fmt.bufPrintZ(&user_buf, "{s}", .{user});
    return std.c.getpwnam(user_z) != null;
}

fn captureGreeterLogFd() ?std.posix.fd_t {
    const fd = std.posix.dup(std.posix.STDERR_FILENO) catch return null;
    _ = std.posix.fcntl(fd, std.posix.F.SETFD, 0) catch {};
    return fd;
}

fn createSocketPair() ![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (rc != 0) return std.posix.unexpectedErrno(std.posix.errno(rc));
    return fds;
}
