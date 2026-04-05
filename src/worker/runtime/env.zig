const builtin = @import("builtin");
const std = @import("std");
const Pam = @import("pam").Pam;
const UserInfo = @import("user.zig").UserInfo;
const Config = @import("../../Config.zig");

pub fn applyPamUserSessionEnv(
    comptime T: type,
    pam: *Pam(T),
    session_envmap: *std.process.EnvMap,
    vt: Config.Vt,
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

    if (vt.ttyNumber()) |vt_num| {
        var vt_buf: [3]u8 = undefined;
        const vt_value = try std.fmt.bufPrint(&vt_buf, "{d}", .{vt_num});
        try pam.putEnvAlloc("XDG_VTNR", vt_value);
    } else if (std.posix.getenv("XDG_VTNR")) |vt_num| {
        try pam.putEnvAlloc("XDG_VTNR", vt_num);
    }

    if (std.posix.getenv("XDG_SEAT")) |seat| {
        try pam.putEnvAlloc("XDG_SEAT", seat);
    } else {
        try pam.putEnv("XDG_SEAT=seat0");
    }

    try pam.putEnv("XDG_SESSION_CLASS=user");
    try pam.openSession(.{});

    // Add pam env list to the envmap (overwrites)
    try pam.addEnvListToMap(session_envmap);
}

pub fn applyUserEnv(session_envmap: *std.process.EnvMap, user: [:0]const u8) !UserInfo {
    const pw = std.c.getpwnam(user) orelse return error.UserUnknown;

    if (pw.dir) |home_dir| {
        const s = std.mem.span(home_dir);
        try session_envmap.put("HOME", s);
        try session_envmap.put("PWD", s);
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

pub fn applyTermEnv(session_envmap: *std.process.EnvMap) !void {
    if (session_envmap.get("TERM") != null) return;

    if (std.posix.getenv("TERM")) |term| {
        try session_envmap.put("TERM", term);
        return;
    }

    switch (builtin.os.tag) {
        .linux => try session_envmap.put("TERM", "linux"),
        .freebsd => try session_envmap.put("TERM", "xterm"),
        else => {},
    }
}
