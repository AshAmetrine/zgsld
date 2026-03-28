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

const XauthRootDir = struct {
    path: []const u8,
    dir: std.fs.Dir,
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
    var hostname_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = try std.posix.gethostname(&hostname_buf);

    const auth = Xauth{
        .family = .FamilyLocal,
        .address = hostname,
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

fn resolveXauthDir(
    uid: std.posix.uid_t,
    gid: std.posix.gid_t,
    user_dir_buf: []u8,
    runtime_dir_opt: ?[]const u8,
) !XauthRootDir {
    if (runtime_dir_opt) |runtime_dir_raw| {
        const runtime_dir = std.mem.trimRight(u8, runtime_dir_raw, "/");
        if (runtime_dir.len != 0) {
            if (std.fs.openDirAbsolute(runtime_dir, .{ .no_follow = true })) |dir| {
                return .{
                    .path = runtime_dir,
                    .dir = dir,
                };
            } else |_| {}
        }
    }

    const base_dir = "/tmp/zgsld";
    var tmp_dir = try std.fs.openDirAbsolute("/tmp", .{ .no_follow = true });
    defer tmp_dir.close();

    var base = try utils.ensureOwnedDirAt(tmp_dir, "zgsld", 0o755, 0, 0);
    defer base.close();

    var user_dir_name_buf: [32]u8 = undefined;
    const user_dir_name = try std.fmt.bufPrint(&user_dir_name_buf, "{d}", .{uid});
    const user_dir = try utils.ensureOwnedDirAt(base, user_dir_name, 0o700, uid, gid);
    errdefer user_dir.close();

    const user_dir_path = try std.fmt.bufPrint(user_dir_buf, "{s}/{s}", .{ base_dir, user_dir_name });
    return .{
        .path = user_dir_path,
        .dir = user_dir,
    };
}

const CreatedXauthFile = struct {
    path: []const u8,
    file: std.fs.File,
};

/// Finds a suitable dir to store the Xauth file,
/// then creates the file with a unique id.
fn createUniqueXauthFile(
    buf: []u8,
    uid: std.posix.uid_t,
    gid: std.posix.gid_t,
    runtime_dir: ?[]const u8,
) !CreatedXauthFile {
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const xauth_dir = try resolveXauthDir(uid, gid, &base_buf, runtime_dir);
    defer xauth_dir.dir.close();

    var attempts: usize = 0;
    while (attempts < 16) : (attempts += 1) {
        var raw: [3]u8 = undefined;
        std.crypto.random.bytes(&raw);
        const id = std.fmt.bytesToHex(&raw, .lower);
        const xauthority = try std.fmt.bufPrint(buf, "{s}/Xauthority-{s}", .{ xauth_dir.path, id });
        const file_name = std.fs.path.baseName(xauthority);

        const file = xauth_dir.dir.createFile(file_name, .{
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
