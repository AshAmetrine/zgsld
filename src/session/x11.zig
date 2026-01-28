const std = @import("std");


pub fn startXServer(x_cmd: []const u8, xauth_path: []const u8, display_name: []const u8, vt: []const u8) !std.posix.fd_t {
    // Starting X server:
    // x_cmd -auth {s} {display_name} {vt}
    
    const pid = try std.posix.fork();
    if (pid == 0) {
        var args = .{ "-auth", xauth_path, display_name, vt };
        std.posix.execvpeZ(x_cmd, &args, std.c.environ);
        std.process.exit(1);
    }

    // TODO: Does X server detach from the fork, so the pid would be different?
}

pub fn startXClient(x_cmd_setup: []const u8, cmd: []const u8) !std.posix.fd_t {
    // TODO: Set XAUTHORITY and DISPLAY env vars before starting the user session

    const pid = try std.posix.fork();
    if (pid == 0) {
        var args = .{ cmd };
        std.posix.execvpeZ(x_cmd_setup,&args,std.c.environ);
        std.process.exit(1);
    }

    return pid;
}
