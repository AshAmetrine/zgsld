const std = @import("std");
const pam_module = @import("auth/pam.zig");
const Pam = pam_module.Pam;
const ipc_module = @import("ipc");
const c = @cImport({
    @cInclude("grp.h");
    @cInclude("pwd.h");
    @cInclude("unistd.h");
});

const GreeterHandle = struct {
    ipc: ipc_module.Ipc,
    pid: std.posix.pid_t,
};

pub const SessionManagerRunOpts = struct {
    service_name: []const u8,
    greeter_path: [:0]const u8,
    greeter_user: []const u8,
};

pub fn run(opts: SessionManagerRunOpts) !void {
    var event_buf: [ipc_module.PAM_START_BUF_SIZE]u8 = undefined;

    var greeter = try spawnGreeter(opts.greeter_path, opts.greeter_user);
    defer {
        _ = std.posix.waitpid(greeter.pid, 0);
        greeter.ipc.deinit();
    }

    while (true) {
        const event = try greeter.ipc.readEvent(event_buf[0..]);
        switch (event) {
            .pam_start_auth => |auth| {
                var ctx = pam_module.PamCtx{
                    .user = auth.user,
                    .ipc = &greeter.ipc,
                };
                var pam = try Pam.init(opts.service_name, &ctx);
                defer pam.deinit();
                try pam.setItem(pam_module.pam.PAM_USER, auth.user);

                pam.authenticate() catch {
                    const fail = ipc_module.IpcEvent{ .pam_auth_result = .{ .ok = false } };
                    greeter.ipc.writeEvent(&fail) catch {};
                    greeter.ipc.flush() catch {};
                    continue;
                };

                const ok = ipc_module.IpcEvent{ .pam_auth_result = .{ .ok = true } };
                try greeter.ipc.writeEvent(&ok);
                try greeter.ipc.flush();
                break;
            },
            else => unreachable,
        }
    }
}

fn spawnGreeter(greeter_path: [:0]const u8, greeter_user: []const u8) !GreeterHandle {
    std.debug.print("Spawning Greeter...", .{});
    _ = greeter_user;
    //var user_buf: [64]u8 = undefined;
    //const greeter_user_z = try std.fmt.bufPrintZ(&user_buf, "{s}", .{greeter_user});

    //const pw = c.getpwnam(greeter_user_z) orelse return error.GreeterUserNotFound;
    //const greeter_uid: std.posix.uid_t = @intCast(pw.*.pw_uid);
    //const greeter_gid: std.posix.gid_t = @intCast(pw.*.pw_gid);
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

        var fd_buf: [16]u8 = undefined;
        const fd_str = try std.fmt.bufPrintZ(&fd_buf, "{d}", .{fds[1]});

        const argv = [_:null]?[*:0]const u8{
            greeter_path,
            "--sock-fd",
            fd_str,
            null,
        };
        //if (c.initgroups(greeter_user_z, greeter_gid) != 0) {
            //const err = std.posix.errno(-1);
            //std.debug.print("initgroups failed: {s}\n", .{@tagName(err)});
            //std.process.exit(1);
        //}

        //std.posix.setgid(greeter_gid) catch {
            //std.debug.print("setgid error",.{});
            //std.process.exit(1);
        //};
        //std.posix.setuid(greeter_uid) catch {
            //std.debug.print("setuid error",.{});
            //std.process.exit(1);
        //};

        std.posix.execvpeZ(greeter_path, &argv, std.c.environ) catch {
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
