const std = @import("std");
const pam_module = @import("auth/pam.zig");
const Pam = pam_module.Pam;
const ipc_module = @import("ipc");
const vt = @import("vt.zig");
const c = @cImport({
    @cInclude("grp.h");
    @cInclude("pwd.h");
});

const GreeterHandle = struct {
    ipc: ipc_module.Ipc,
    pid: std.posix.pid_t,
};

const WorkerHandle = struct {
    ipc: ipc_module.Ipc,
    pid: std.posix.pid_t,
};

pub const SessionManagerRunOpts = struct {
    self_exe_path: [:0]const u8,
    greeter_argv: []const ?[*:0]const u8,
    greeter_user: []const u8,
    service_name: []const u8,
    vt: ?u8 = null,
};

pub fn run(opts: SessionManagerRunOpts) !void {
    if (opts.vt) |vt_id| {
        vt.initTty(vt_id) catch |err| {
            std.debug.print("Failed to init VT {d}: {s}\n", .{ vt_id, @errorName(err) });
            return err;
        };
    }

    while (true) {
        std.debug.print("Spawning Worker...\n",.{});
        var worker = try spawnWorker(opts.self_exe_path, opts.service_name);
        defer worker.ipc.deinit();

        std.debug.print("Spawning Greeter...\n",.{});
        var greeter = try spawnGreeter(opts.greeter_argv, opts.greeter_user);
        defer greeter.ipc.deinit();
        
        // Forward greeter/worker things
        try forwardIpc(&greeter, &worker);

        std.debug.print("Finished forwarding IPC\n",.{});

        const status = std.posix.waitpid(worker.pid,0);
        std.debug.print("Worker Stopped\n",.{});

        const st = status.status;
        if (std.c.W.IFEXITED(st) and std.c.W.EXITSTATUS(st) != 0) {
            std.debug.print("Session Error\n",.{});
        } else {
            std.debug.print("Session Executed Successfully\n", .{});
        }

        if (opts.vt) |vt_id| {
            vt.resetTty(vt_id) catch |err| {
                std.debug.print("Failed to reset VT {d}: {s}\n", .{ vt_id, @errorName(err) });
                return err;
            };
        }
    }
}

pub fn spawnWorker(worker_path: [:0]const u8, service_name: []const u8) !WorkerHandle {
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
        var service_buf: [std.fs.max_path_bytes]u8 = undefined;
        const zgsld_service = try std.fmt.bufPrintZ(&service_buf, "ZGSLD_SERVICE_NAME={s}", .{service_name});
        const worker_environ: [*:null]const ?[*:0]const u8 = &.{
            zgsld_sock,
            zgsld_service,
            null,
        };

        const argv = [_:null]?[*:0]const u8{ worker_path, "--session-worker", null };
        std.posix.execvpeZ(worker_path, &argv, worker_environ) catch {
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

pub fn spawnGreeter(greeter_argv: []const ?[*:0]const u8, greeter_user: []const u8) !GreeterHandle {
    var user_buf: [64]u8 = undefined;
    const greeter_user_z = try std.fmt.bufPrintZ(&user_buf, "{s}", .{greeter_user});

    const pw = std.c.getpwnam(greeter_user_z) orelse return error.GreeterUserNotFound;

    var fds: [2]std.posix.fd_t = undefined;
    _ = std.c.socketpair(
        std.c.AF.UNIX,
        std.c.SOCK.STREAM,
        0,
        &fds,
    );

    var runtime_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    var runtime_dir = try std.fmt.bufPrint(&runtime_dir_buf, "/run/user/{d}", .{pw.uid});
    ensureRuntimeDir(runtime_dir, pw.uid, pw.gid) catch {
        runtime_dir = try std.fmt.bufPrint(&runtime_dir_buf, "/tmp", .{});
    };

    const pid = try std.posix.fork();
    if (pid == 0) {
        std.posix.close(fds[0]);

        var fd_buf: [32]u8 = undefined;
        const zgsld_sock = try std.fmt.bufPrintZ(&fd_buf, "ZGSLD_SOCK={d}", .{fds[1]});
        var xdg_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
        const xdg_runtime_dir = try std.fmt.bufPrintZ(&xdg_buf, "XDG_RUNTIME_DIR={s}", .{runtime_dir});
        const greeter_environ: [*:null]const ?[*:0]const u8 = &.{ zgsld_sock, xdg_runtime_dir, null };

        if (std.posix.geteuid() == 0) {
            if (c.initgroups(greeter_user_z, pw.gid) != 0) {
                const err = std.posix.errno(-1);
                std.debug.print("initgroups failed: {s}\n", .{@tagName(err)});
                std.process.exit(1);
            }

            std.posix.setgid(pw.gid) catch {
                std.debug.print("setgid error",.{});
                std.process.exit(1);
            };
            std.posix.setuid(pw.uid) catch {
                std.debug.print("setuid error",.{});
                std.process.exit(1);
            };
        }

        if (greeter_argv.len == 0 or greeter_argv[0] == null or greeter_argv[greeter_argv.len - 1] != null) {
            std.debug.print("Invalid greeter argv\n", .{});
            std.process.exit(1);
        }

        const greeter_path = greeter_argv[0].?;
        const argv = @as([*:null]const ?[*:0]const u8, @ptrCast(greeter_argv.ptr));
        std.posix.execvpeZ(greeter_path, argv, greeter_environ) catch {
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

pub fn forwardIpc(greeter: *GreeterHandle, worker: *WorkerHandle) !void {
    var buf_g: [ipc_module.GREETER_BUF_SIZE]u8 = undefined;
    var buf_w: [ipc_module.GREETER_BUF_SIZE]u8 = undefined;

    var greeter_rbuf: [ipc_module.IPC_IO_BUF_SIZE]u8 = undefined;
    var greeter_wbuf: [ipc_module.IPC_IO_BUF_SIZE]u8 = undefined;
    var greeter_reader = greeter.ipc.reader(&greeter_rbuf);
    var greeter_writer = greeter.ipc.writer(&greeter_wbuf);
    const greeter_ipc_reader = &greeter_reader.interface;
    const greeter_ipc_writer = &greeter_writer.interface;

    var worker_rbuf: [ipc_module.IPC_IO_BUF_SIZE]u8 = undefined;
    var worker_wbuf: [ipc_module.IPC_IO_BUF_SIZE]u8 = undefined;
    var worker_reader = worker.ipc.reader(&worker_rbuf);
    var worker_writer = worker.ipc.writer(&worker_wbuf);
    const worker_ipc_reader = &worker_reader.interface;
    const worker_ipc_writer = &worker_writer.interface;

    var fds = [_]std.posix.pollfd{
        .{ .fd = greeter.ipc.file.handle, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = worker.ipc.file.handle, .events = std.posix.POLL.IN, .revents = 0 },
    };

    const Phase = enum {
        idle,
        auth_in_progress,
        awaiting_response,
        authed,
    };
    var phase: Phase = .idle;

    while (true) {
        _ = try std.posix.poll(&fds, -1);

        if ((fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP)) != 0) {
            while (true) {
                std.debug.print("Manager: Waiting for greeter event\n", .{});
                const ev = greeter.ipc.readEvent(greeter_ipc_reader, &buf_g) catch |err| switch (err) {
                    error.EndOfStream => return,
                    else => return err,
                };
                defer std.crypto.secureZero(u8, &buf_g);
                var forward = true;
                switch (ev) {
                    .pam_start_auth => {
                        if (phase != .idle) {
                            std.debug.print("Manager: dropping pam_start_auth in state {s}\n", .{@tagName(phase)});
                            forward = false;
                        } else {
                            phase = .auth_in_progress;
                        }
                    },
                    .pam_response => {
                        if (phase != .awaiting_response) {
                            std.debug.print("Manager: dropping pam_response in state {s}\n", .{@tagName(phase)});
                            forward = false;
                        } else {
                            phase = .auth_in_progress;
                        }
                    },
                    .start_session, .set_session_env => {
                        if (phase != .authed) {
                            std.debug.print("Manager: dropping {s} in state {s}\n", .{ @tagName(ev), @tagName(phase) });
                            forward = false;
                        }
                    },
                    .pam_cancel => {
                        if (phase != .auth_in_progress) {
                            std.debug.print("Manager: dropping {s} in state {s}\n", .{ @tagName(ev), @tagName(phase) });
                            forward = false;
                        } else {
                            phase = .idle;
                        }
                    },
                    else => {},
                }

                std.debug.print("Manager: Received Greeter event: {s}\n", .{@tagName(ev)});
                
                if (forward) {
                    if (ev == .start_session) {
                        std.debug.print("Manager: Waiting for Greeter to exit...\n", .{});
                        _ = std.posix.waitpid(greeter.pid, 0);
                    }

                    try worker.ipc.writeEvent(worker_ipc_writer, &ev);
                    try worker_ipc_writer.flush();
                }


                if (greeter_reader.interface.end == greeter_reader.interface.seek) break;
            }
        }
        if ((fds[1].revents & (std.posix.POLL.IN | std.posix.POLL.HUP)) != 0) {
            while (true) {
                std.debug.print("Manager: Waiting for worker event\n", .{});
                const ev = worker.ipc.readEvent(worker_ipc_reader, &buf_w) catch |err| switch (err) {
                    error.EndOfStream => return,
                    else => return err,
                };
                switch (ev) {
                    .pam_request => phase = .awaiting_response,
                    .pam_auth_result => |r| phase = if (r.ok) .authed else .idle,
                    else => {},
                }
                try greeter.ipc.writeEvent(greeter_ipc_writer, &ev);
                try greeter_ipc_writer.flush();

                if (worker_reader.interface.end == worker_reader.interface.seek) break;
            }
        }

        if ((fds[0].revents & (std.posix.POLL.ERR)) != 0)
            break;
        if ((fds[1].revents & (std.posix.POLL.ERR)) != 0)
            break;
    }
}
