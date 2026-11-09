const std = @import("std");

/// Iterator for desktop files within a directory
pub const Iterator = struct {
    it: std.Io.Dir.Iterator,

    pub fn init(dir: std.Io.Dir) Iterator {
        return .{ .it = dir.iterate() };
    }

    pub fn next(self: *Iterator, io: std.Io) !?[]const u8 {
        while (try self.it.next(io)) |entry| {
            switch (entry.kind) {
                .file, .sym_link => {
                    const ext = std.fs.path.extension(entry.name);
                    if (std.mem.eql(u8, ext, ".desktop")) return entry.name;
                },
                else => continue,
            }
        }
        return null;
    }
};

test "Iterator only returns desktop files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "test.desktop",
        .data = "",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "image.desktop.png",
        .data = "",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = ".desktop",
        .data = "",
    });

    var it = Iterator.init(tmp.dir);
    try std.testing.expectEqualStrings("test.desktop", (try it.next(io)).?);
    try std.testing.expect(try it.next(io) == null);
}
