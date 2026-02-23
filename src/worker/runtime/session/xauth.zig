const std = @import("std");
const Md5 = std.crypto.hash.Md5;
const utils = @import("../user.zig");

const Family = enum(u16) {
    FamilyLocal = 256,
};

const Xauth = struct {
    family: Family,
    address: []const u8,
    display_number: []const u8,
    name: []const u8,
    data: []const u8,

    pub fn writeAll(self: Xauth, writer: *std.Io.Writer) !void {
        try writer.writeInt(u16, @intFromEnum(self.family), .big);

        try writer.writeInt(u16, @intCast(self.address.len), .big);
        try writer.writeAll(self.address);

        try writer.writeInt(u16, @intCast(self.display_number.len), .big);
        try writer.writeAll(self.display_number);

        try writer.writeInt(u16, @intCast(self.name.len), .big);
        try writer.writeAll(self.name);

        try writer.writeInt(u16, @intCast(self.data.len), .big);
        try writer.writeAll(self.data);
    }
};

fn mcookie() [Md5.digest_length]u8 {
    var buf: [4096]u8 = undefined;
    std.crypto.random.bytes(&buf);

    var out: [Md5.digest_length]u8 = undefined;
    Md5.hash(&buf, &out, .{});

    return out;
}

// var xauth_buf: [256]u8 = undefined;
pub fn createXauthEntry(
    buf: []u8,
    display_num: []const u8,
    uid: std.posix.uid_t,
    gid: std.posix.gid_t,
    runtime_dir: ?[]const u8,
) ![]const u8 {
    if (display_num.len == 0) return error.InvalidDisplay;

    const xauth_file = try createUniqueXauthFile(buf, uid, gid, runtime_dir);
    errdefer _ = std.fs.deleteFileAbsolute(xauth_file.path) catch {};
    defer xauth_file.file.close();

    const magic_cookie = mcookie();

    const auth = Xauth{
        .family = .FamilyLocal,
        .address = "",
        .display_number = display_num,
        .name = "MIT-MAGIC-COOKIE-1",
        .data = &magic_cookie,
    };

    var file_w_buf: [1024]u8 = undefined;
    var writer = xauth_file.file.writer(&file_w_buf);

    try auth.writeAll(&writer.interface);

    try writer.interface.flush();
    return xauth_file.path;
}

const XauthDir = struct {
    path: []const u8,
    file: std.fs.File,
};

fn dirExists(path: []const u8) bool {
    var dir = std.fs.openDirAbsolute(path, .{}) catch return false;
    dir.close();
    return true;
}

fn resolveXauthDir(
    uid: std.posix.uid_t,
    gid: std.posix.gid_t,
    user_dir_buf: []u8,
    runtime_dir_opt: ?[]const u8,
) ![]const u8 {
    if (runtime_dir_opt) |runtime_dir_raw| {
        const runtime_dir = std.mem.trimRight(u8, runtime_dir_raw, "/");
        if (runtime_dir.len != 0 and dirExists(runtime_dir)) {
            return runtime_dir;
        }
    }

    const base_dir = "/tmp/zgsld";
    try utils.ensureDirOwned(base_dir, 0o755, 0, 0);

    const user_dir = try std.fmt.bufPrint(user_dir_buf, "{s}/{d}", .{ base_dir, uid });
    try utils.ensureDirOwned(user_dir, 0o700, uid, gid);
    return user_dir;
}

/// Finds a suitable dir to store the Xauth file,
/// then creates the file with a unique id.
fn createUniqueXauthFile(
    buf: []u8,
    uid: std.posix.uid_t,
    gid: std.posix.gid_t,
    runtime_dir: ?[]const u8,
) !XauthDir {
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const xauth_dir = try resolveXauthDir(uid, gid, &base_buf, runtime_dir);

    var attempts: usize = 0;
    while (attempts < 16) : (attempts += 1) {
        var raw: [3]u8 = undefined;
        std.crypto.random.bytes(&raw);
        const id = std.fmt.bytesToHex(&raw, .lower);
        const xauthority = try std.fmt.bufPrint(
            buf,
            "{s}/Xauthority-{s}",
            .{ xauth_dir, id },
        );
        const file = std.fs.createFileAbsolute(xauthority, .{
            .mode = 0o600,
            .exclusive = true,
            .truncate = false,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        errdefer {
            file.close();
            std.fs.deleteFileAbsolute(xauthority) catch {};
        }
        try file.chown(uid, gid);
        return .{
            .file = file,
            .path = xauthority,
        };
    }

    return error.PathAlreadyExists;
}
