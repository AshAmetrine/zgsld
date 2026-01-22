const std = @import("std");
const session_manager = @import("session_manager.zig");
const ipc = @import("ipc");
const Greeter = @import("greeter").Greeter;

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var sock_fd: ?std.posix.fd_t = null;
    for (args[1..], 1..) |arg, i| {
        if (std.mem.eql(u8, arg, "--sock-fd")) {
            sock_fd = try std.fmt.parseInt(std.posix.fd_t, args[i + 1], 10);
        }
    }

    if (sock_fd) |fd| {
        // We are a greeter
        std.debug.print("Greeter Started\n",.{});

        var ipc_conn = ipc.Ipc.initFromFd(fd);
        defer ipc_conn.deinit();
        var greeter = try Greeter.init(allocator,&ipc_conn);
        defer greeter.deinit();

        try greeter.run();

        return;
    }

    // Since this is standalone, it'd be a good idea to pass args for the greeter to handle now.
    // the greeter can return true/false whether to continue with the session manager.
    
    if (try Greeter.handleInitialArgs(allocator)) return;

    std.debug.print("Session Manager Started\n",.{});

    const self_exe_path_z = try selfExePathAllocZ(allocator);
    defer allocator.free(self_exe_path_z);

    std.debug.print("Greeter Path: {s}\n",.{self_exe_path_z});

    const service_name = Greeter.serviceName();
    const greeter_user = "greeter";

    std.debug.print("Greeter User: {s}\nPam Service Name: {s}\n",.{greeter_user,service_name});

    try session_manager.run(.{
        .greeter_path = self_exe_path_z,
        .greeter_user = greeter_user,
        .service_name = service_name,
    });
}

fn selfExePathAllocZ(allocator: std.mem.Allocator) ![:0]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    return allocator.dupeZ(u8, try std.fs.selfExePath(&buf));
}
