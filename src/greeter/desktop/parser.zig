const std = @import("std");
const Entry = @import("Entry.zig");

const EntryField = std.meta.FieldEnum(Entry);
const fields = std.StaticStringMap(EntryField).initComptime(.{
    .{ "Name", .name },
    .{ "Exec", .exec },
    .{ "Comment", .comment },
    .{ "Icon", .icon },
    .{ "DesktopNames", .desktop_names },
});

pub fn parse(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Entry {
    var entry: Entry = .{ .name = "", .exec = "" };
    errdefer entry.deinit(allocator);

    var in_entry: bool = false;
    while (try reader.takeDelimiter('\n')) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[') {
            if (line[line.len - 1] != ']') return error.InvalidHeader;
            in_entry = std.mem.eql(u8, "[Desktop Entry]", line);
            continue;
        }

        if (!in_entry) continue;
        const sep = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidProperty;

        const key = std.mem.trimEnd(u8, line[0..sep], " \t");
        const value = std.mem.trimStart(u8, line[sep + 1 ..], " \t");

        const field = fields.get(key) orelse continue;
        switch (field) {
            inline .name, .exec, .comment, .icon => |tag| {
                const len = value.len - try countEscapes(value);
                const buf = try allocator.alloc(u8, len);
                errdefer allocator.free(buf);
                try parseValue(buf, value);
                // Overwrite value if duplicate key is found.
                const dest = &@field(entry, @tagName(tag));
                const old: ?[]const u8 = dest.*;
                if (old) |v| allocator.free(v);
                dest.* = buf;
            },
            .desktop_names => {
                const names = try parseDesktopNames(allocator, value);
                if (entry.desktop_names) |old| allocator.free(old.value);
                entry.desktop_names = names;
            },
        }
    }

    if (entry.name.len == 0) return error.MissingName;
    if (entry.exec.len == 0) return error.MissingExec;
    return entry;
}

fn parseValue(output: []u8, input: []const u8) !void {
    var i: usize = 0;
    var written: usize = 0;

    while (i < input.len) : (i += 1) {
        var c = input[i];

        if (c == '\\') {
            i += 1;
            if (i == input.len) return error.InvalidEscape;

            c = try parseEscape(input[i]);
        }

        output[written] = c;
        written += 1;
    }

    std.debug.assert(written == output.len);
}

fn countEscapes(value: []const u8) !usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        if (value[i] != '\\') continue;

        i += 1;
        if (i == value.len) return error.InvalidEscape;
        count += 1;
    }
    return count;
}

fn parseEscape(c: u8) !u8 {
    return switch (c) {
        's' => ' ',
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        '\\' => '\\',
        else => error.InvalidEscape,
    };
}

fn parseDesktopNames(allocator: std.mem.Allocator, value: []const u8) !?Entry.DesktopNames {
    const len = try desktopNamesSize(value);
    if (len == 0) return null;

    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    try formatDesktopNames(buf, value);
    return .{ .value = buf };
}

fn desktopNamesSize(value: []const u8) !usize {
    var len: usize = 0;
    var i: usize = 0;
    var separator = false;

    while (i < value.len) : (i += 1) {
        if (value[i] == ';') {
            separator = len != 0;
            continue;
        }
        if (value[i] == '\\') {
            i += 1;
            if (i == value.len) return error.InvalidEscape;
        }
        if (separator) {
            len += 1;
            separator = false;
        }
        len += 1;
    }
    return len;
}

fn formatDesktopNames(output: []u8, input: []const u8) !void {
    var i: usize = 0;
    var written: usize = 0;
    var separator = false;

    while (i < input.len) : (i += 1) {
        var c = input[i];
        if (c == ';') {
            separator = written != 0;
            continue;
        }
        if (c == '\\') {
            i += 1;
            if (i == input.len) return error.InvalidEscape;
            // Preserve escaped semicolons
            c = if (input[i] == ';') ';' else try parseEscape(input[i]);
        }

        // XDG_CURRENT_DESKTOP is separated by colons.
        if (c == ':') return error.InvalidDesktopName;
        if (separator) {
            output[written] = ':';
            written += 1;
            separator = false;
        }
        output[written] = c;
        written += 1;
    }
    std.debug.assert(written == output.len);
}

test "parses desktop entry fields" {
    const content =
        \\[Desktop Entry]
        \\Name=Test Entry
        \\Exec=/bin/test
        \\Comment = This is a test
        \\Icon=testicon.png
        \\DesktopNames=test;test1\;test2
    ;

    var reader = std.Io.Reader.fixed(content);
    var entry = try Entry.parse(std.testing.allocator, &reader);
    defer entry.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Test Entry", entry.name);
    try std.testing.expectEqualStrings("/bin/test", entry.exec);
    try std.testing.expectEqualStrings("This is a test", entry.comment.?);
    try std.testing.expectEqualStrings("testicon.png", entry.icon.?);
    try std.testing.expectEqualStrings("test:test1;test2", entry.desktop_names.?.value);

    var names = entry.desktop_names.?.iterator();
    try std.testing.expectEqualStrings("test", names.next().?);
    try std.testing.expectEqualStrings("test1;test2", names.next().?);
    try std.testing.expect(names.next() == null);
}
