const std = @import("std");
const Md5 = std.crypto.hash.Md5;

const Family = enum(u16) {
    FamilyLocal = 256,
};

const Xauth = struct {
    family: Family,
    address: []const u8,
    display_number: []const u8,
    name: []const u8,
    data: []const u8,
};

fn writeXauthRecord(writer: *std.Io.Writer, xauth: Xauth) !void {
    try writer.writeInt(u16, @intFromEnum(xauth.family), .big);

    try writer.writeInt(u16, @intCast(xauth.address.len), .big);
    try writer.writeAll(xauth.address);

    try writer.writeInt(u16, @intCast(xauth.display_number.len), .big);
    try writer.writeAll(xauth.display_number);

    try writer.writeInt(u16, @intCast(xauth.name.len), .big);
    try writer.writeAll(xauth.name);

    try writer.writeInt(u16, @intCast(xauth.data.len), .big);
    try writer.writeAll(xauth.data);
}

fn mcookie() [Md5.digest_length]u8 {
    var buf: [4096]u8 = undefined;
    std.crypto.random.bytes(&buf);

    var out: [Md5.digest_length]u8 = undefined;
    Md5.hash(&buf, &out, .{});

    return out;
}

// var xauth_buf: [256]u8 = undefined;
pub fn createXauthEntry(buf: []u8, display_num: []const u8, home: []const u8) ![]const u8 {
    if (display_num.len == 0) return error.InvalidDisplay;

    const xauth_file = try createUniqueXauthFile(buf, home);
    errdefer _ = std.fs.deleteFileAbsolute(xauth_file.path) catch {};
    defer xauth_file.file.close();

    const magic_cookie = mcookie();

    const auth = Xauth {
        .family = .FamilyLocal,
        .address = "",
        .display_number = display_num,
        .name = "MIT-MAGIC-COOKIE-1",
        .data = &magic_cookie,
    };

    var file_w_buf: [1024]u8 = undefined;
    var writer = xauth_file.file.writer(&file_w_buf);

    try writeXauthRecord(&writer.interface,auth);
    try writer.interface.flush();
    return xauth_file.path;
}

const XauthDir = struct {
    path: []const u8,
    file: std.fs.File,
};

fn dirExists(path: []const u8) bool {
    var dir = std.fs.cwd().openDir(path, .{}) catch return false;
    dir.close();
    return true;
}

const XauthPath = struct {
    dirname: []const u8,
    filename: []const u8,
};

fn resolveXauthPath(buf: []u8, home: []const u8) ![]const u8 {
    var xauth_dir: []const u8 = undefined;
    const xdg_rt_dir = std.posix.getenv("XDG_RUNTIME_DIR");

    var xauth_file: []const u8 = "Xauthority";
    if (xdg_rt_dir == null or !dirExists(xdg_rt_dir.?)) {
        // fallback to $HOME/.Xauthority
        xauth_dir = home;
        xauth_file = ".Xauthority";
    } else {
        // /run/user/UID/Xauthority
        xauth_dir = xdg_rt_dir.?;
    }

    xauth_dir = std.mem.trimRight(u8, xauth_dir, "/");
    return try std.fmt.bufPrint(buf, "{s}/{s}",.{xauth_dir,xauth_file});
}

/// Finds a suitable dir to store the Xauth file, 
/// then creates the file with a unique id.
fn createUniqueXauthFile(buf: []u8, home: []const u8) !XauthDir {
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const xauth_path = try resolveXauthPath(base_buf[0..], home);

    var attempts: usize = 0;
    while (attempts < 16) : (attempts += 1) {
        var raw: [3]u8 = undefined;
        std.crypto.random.bytes(&raw);
        const id = std.fmt.bytesToHex(&raw, .lower);
        const xauthority = try std.fmt.bufPrint(
            buf,
            "{s}-{s}",
            .{ xauth_path, id },
        );
        const file = std.fs.createFileAbsolute(xauthority, .{
            .mode = 0o600,
            .exclusive = true,
            .truncate = false,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        return .{ .file = file, .path = xauthority, };
    }

    return error.PathAlreadyExists;
}
