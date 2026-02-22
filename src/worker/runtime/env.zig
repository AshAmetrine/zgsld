const std = @import("std");
const UserInfo = @import("user.zig").UserInfo;

pub fn applyPamSessionEnv(
    pam: anytype,
    session_envmap: *std.process.EnvMap,
    vt: ?u8,
) !void {
    if (session_envmap.get("XDG_CURRENT_DESKTOP")) |v| {
        try pam.putEnvAlloc("XDG_CURRENT_DESKTOP", v);
    }
    if (session_envmap.get("XDG_SESSION_DESKTOP")) |v| {
        try pam.putEnvAlloc("XDG_SESSION_DESKTOP", v);
    }
    if (session_envmap.get("XDG_SESSION_TYPE")) |v| {
        try pam.putEnvAlloc("XDG_SESSION_TYPE", v);
    }

    if (vt) |vt_num| {
        var vt_buf: [3]u8 = undefined;
        const vt_value = try std.fmt.bufPrint(&vt_buf, "{d}", .{vt_num});
        try pam.putEnvAlloc("XDG_VTNR", vt_value);
    }

    try pam.putEnv("XDG_SESSION_CLASS=user");

    if (std.posix.geteuid() == 0) {
        try pam.openSession(.{});
    }

    // Add pam env list to the envmap (overwrites)
    try pam.addEnvListToMap(session_envmap);
}

pub fn applyUserEnv(session_envmap: *std.process.EnvMap, user: [:0]const u8) !UserInfo {
    const pw = std.c.getpwnam(user) orelse return error.UserUnknown;

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

    return .{
        .username = user,
        .uid = pw.uid,
        .gid = pw.gid,
    };
}
