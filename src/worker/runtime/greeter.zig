const std = @import("std");
const Ipc = @import("Ipc");
const pam_mod = @import("pam");
const UserInfo = @import("user.zig").UserInfo;
const session_mod = @import("session.zig");
const tty = @import("tty.zig");

const Pam = pam_mod.Pam;
const Session = session_mod.Session;

pub const GreeterOpts = struct {
    username: [:0]const u8,
    service_name: []const u8,
    vt: ?u8,
};

pub const Greeter = struct {
    allocator: std.mem.Allocator,
    pam: Pam(void),
    session: ?Session = null,
    user_info: UserInfo,

    pub fn init(allocator: std.mem.Allocator, opts: GreeterOpts) !Greeter {
        const pw = std.c.getpwnam(opts.username) orelse return error.GreeterUserNotFound;
        var pam = try Pam(void).init(allocator, .{
            .user = opts.username,
            .service_name = opts.service_name,
            .state = Pam(void).ConvState.discardAll(),
        });
        errdefer pam.deinit();

        var tty_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        try pam.setItem(.{ .tty = try tty.resolvePamTty(&tty_path_buf, opts.vt) });

        return .{
            .allocator = allocator,
            .pam = pam,
            .session = null,
            .user_info = .{
                .username = opts.username,
                .uid = pw.uid,
                .gid = pw.gid,
            },
        };
    }

    pub fn spawn(
        self: *Greeter,
        ipc_fd: std.posix.fd_t,
        greeter_cmd: []const u8,
        session_type: Ipc.SessionType,
        vt: ?u8,
    ) !std.posix.pid_t {
        if (vt) |vt_num| {
            var vt_buf: [3]u8 = undefined;
            const vt_value = try std.fmt.bufPrint(&vt_buf, "{d}", .{vt_num});
            try self.pam.putEnvAlloc("XDG_VTNR", vt_value);
        }
        try self.pam.putEnv("XDG_SEAT=seat0");
        try self.pam.putEnv("XDG_SESSION_CLASS=greeter");
        try self.pam.openSession(.{});
        var envmap = try self.pam.createEnvListMap();
        defer envmap.deinit();

        var fd_buf: [16]u8 = undefined;
        const zgsld_sock = try std.fmt.bufPrint(&fd_buf, "{d}", .{ipc_fd});
        try envmap.put("ZGSLD_SOCK", zgsld_sock);

        const log_fd = try std.posix.dup(std.posix.STDERR_FILENO);
        defer std.posix.close(log_fd);
        var log_fd_buf: [16]u8 = undefined;
        const log_fd_str = try std.fmt.bufPrintZ(&log_fd_buf, "{d}", .{log_fd});
        try envmap.put("ZGSLD_LOG", log_fd_str);

        const session_info: Ipc.SessionInfo = .{
            .session_type = session_type,
            .command = .{
                .session_cmd = greeter_cmd,
                .source_profile = false,
            },
        };

        self.session = try Session.spawn(self.allocator, .{
            .session_info = session_info,
            .envmap = &envmap,
            .user_info = self.user_info,
            .vt = vt,
        });

        return self.session.?.pid;
    }

    pub fn deinit(self: *Greeter) void {
        if (self.session) |*session| session.deinit();
        self.pam.deinit();
        self.session = null;
    }
};
