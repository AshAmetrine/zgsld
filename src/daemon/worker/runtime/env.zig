const builtin = @import("builtin");
const std = @import("std");
const Pam = @import("pam").Pam;
const UserInfo = @import("user.zig").UserInfo;
const Vt = @import("vt").Vt;

pub fn applyPamUserSessionEnv(
    comptime T: type,
    pam: *Pam(T),
    session_envmap: *std.process.Environ.Map,
    io: std.Io,
    host_env_map: *const std.process.Environ.Map,
    vt: Vt,
) !void {
    for ([_][]const u8{ "XDG_CURRENT_DESKTOP", "XDG_SESSION_DESKTOP", "XDG_SESSION_TYPE" }) |key| {
        if (session_envmap.get(key)) |value| {
            try pam.putEnvAlloc(key, value);
        }
    }

    try openPamSession(T, pam, io, host_env_map, vt, .user);

    // Add pam env list to the envmap (overwrites)
    try pam.addEnvListToMap(session_envmap);
}

pub fn openPamSession(
    comptime T: type,
    pam: *Pam(T),
    io: std.Io,
    host_env_map: *const std.process.Environ.Map,
    vt: Vt,
    comptime session_class: enum { greeter, user },
) !void {
    if (vt.ttyNumber(io, host_env_map)) |vt_num| {
        var vt_buf: [3]u8 = undefined;
        const vt_value = try std.fmt.bufPrint(&vt_buf, "{d}", .{vt_num});
        try pam.putEnvAlloc("XDG_VTNR", vt_value);
    }

    if (host_env_map.get("XDG_SEAT")) |seat| {
        try pam.putEnvAlloc("XDG_SEAT", seat);
    } else {
        try pam.putEnv("XDG_SEAT=seat0");
    }

    try pam.putEnv("XDG_SESSION_CLASS=" ++ @tagName(session_class));
    try pam.openSession(.{});
}

pub fn applyUserEnv(session_envmap: *std.process.Environ.Map, user: [:0]const u8) !UserInfo {
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

pub fn applyTermEnv(session_envmap: *std.process.Environ.Map, host_env_map: *const std.process.Environ.Map) !void {
    if (session_envmap.get("TERM") != null) return;

    const term = host_env_map.get("TERM") orelse switch (builtin.os.tag) {
        .linux => "linux",
        .freebsd => "xterm",
        else => return,
    };
    try session_envmap.put("TERM", term);
}
