const std = @import("std");
const session_manager = @import("session_manager.zig");
const session_worker = @import("session_worker.zig");
const ipc = @import("ipc");
const Greeter = @import("greeter").Greeter;
const utils = @import("utils.zig");

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const service_name = Greeter.serviceName();

    // Check for fd from ZGSLD_SOCK
    var sock_fd: ?std.posix.fd_t = null;
    if (std.posix.getenv("ZGSLD_SOCK")) |sock| {
        sock_fd = try std.fmt.parseInt(std.posix.fd_t, sock, 10);
    }

    if (sock_fd) |fd| {
        var ipc_conn = ipc.Ipc.initFromFd(fd);
        defer ipc_conn.deinit();

        if (isSessionWorker()) {
            std.debug.print("Session Worker Started\n",.{});
            _ = try session_worker.run(allocator, .{ 
                .service_name = service_name,
                .ipc_conn = &ipc_conn,
            });
        } else {
            std.debug.print("Greeter Started\n",.{});

            var greeter = try Greeter.init(allocator,&ipc_conn);
            defer greeter.deinit();

            try greeter.run();

            std.debug.print("Greeter Exiting...\n",.{});
        }
        return;
    }

    // Since this is standalone, 
    // pass args for the greeter to handle now (help,version,verify).
    try Greeter.handleInitialArgs(allocator);

    std.debug.print("Session Manager Started\n",.{});

    const self_exe_path_z = try utils.selfExePathAllocZ(allocator);
    defer allocator.free(self_exe_path_z);

    std.debug.print("Greeter Path: {s}\n",.{self_exe_path_z});

    const greeter_user = "greeter";

    std.debug.print("Greeter User: {s}\nPam Service Name: {s}\n",.{greeter_user,service_name});

    try session_manager.run(.{ 
        .self_exe_path = self_exe_path_z,
        .greeter_argv = &[_]?[*:0]const u8{ self_exe_path_z, null },
        .greeter_user = greeter_user,
    });
}

fn isSessionWorker() bool {
    var args = std.process.args();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, "--session-worker", arg)) return true; 
    }
    return false;
}
