const std = @import("std");
const pam_module = @import("auth/pam.zig");
const Pam = pam_module.Pam;
const ipc_module = @import("ipc");
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
    greeter_path: [:0]const u8,
    greeter_user: []const u8,
    vt: ?u8 = null,
};

pub fn run(opts: SessionManagerRunOpts) !void {
    while (true) {
        std.debug.print("Spawning Worker...\n",.{});
        var worker = try spawnWorker(opts.self_exe_path);
        defer worker.ipc.deinit();

        std.debug.print("Spawning Greeter...\n",.{});
        var greeter = try spawnGreeter(opts.greeter_path, opts.greeter_user, null);
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
    }
}

pub fn spawnWorker(worker_path: [:0]const u8) !WorkerHandle {
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
        const worker_environ: [*:null]const ?[*:0]const u8 = &.{
            zgsld_sock,
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

pub fn spawnGreeter(greeter_path: [:0]const u8, greeter_user: []const u8, vt: ?u8) !GreeterHandle {
    _ = vt;
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

pub fn forwardIpc(greeter: *GreeterHandle, worker: *WorkerHandle) !void {
    var buf_g: [ipc_module.GREETER_BUF_SIZE]u8 = undefined;
    var buf_w: [ipc_module.GREETER_BUF_SIZE]u8 = undefined;

    var fds = [_]std.posix.pollfd{
        .{ .fd = greeter.ipc.file.handle, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = worker.ipc.file.handle, .events = std.posix.POLL.IN, .revents = 0 },
    };

    while (true) {
        _ = try std.posix.poll(&fds, -1);

        if ((fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP)) != 0) {
            const ev = greeter.ipc.readEvent(&buf_g) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (ev == .start_session) {
                std.debug.print("Waiting for Greeter to exit...\n",.{});
                _ = std.posix.waitpid(greeter.pid,0);
            }
            try worker.ipc.writeEvent(&ev);
            try worker.ipc.flush();
        }
        if ((fds[1].revents & (std.posix.POLL.IN | std.posix.POLL.HUP)) != 0) {
            const ev = worker.ipc.readEvent(&buf_w) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            try greeter.ipc.writeEvent(&ev);
            try greeter.ipc.flush();
        }

        if ((fds[0].revents & (std.posix.POLL.ERR)) != 0) 
            break;
        if ((fds[1].revents & (std.posix.POLL.ERR)) != 0)
            break;
    }
}
