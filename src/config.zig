const std = @import("std");
const build_options = @import("build_options");

const X11Config = struct {
    cmd: []const u8 = "/bin/X",
};

const Type = std.builtin.Type;

fn field(
    comptime name: [:0]const u8,
    comptime T: type,
    comptime value: T,
) Type.StructField {
    const dv: T = value;
    return .{
        .name = name,
        .type = T,
        .default_value_ptr = @ptrCast(&dv),
        .is_comptime = false,
        .alignment = @alignOf(T),
    };
}

fn configType() type {
    const base = [_]Type.StructField{
        field("service_name", []const u8, build_options.service_name),
        field("greeter_user", []const u8, build_options.greeter_user),
        field("vt", ?u8, build_options.vt),
    };

    const x11 = if (build_options.x11_support)
        [_]Type.StructField{field("x11", X11Config, .{})}
    else
        [_]Type.StructField{};

    const greeter = if (!build_options.standalone)
        [_]Type.StructField{field("greeter_cmd", ?[]const u8, null)}
    else
        [_]Type.StructField{};

    const fields = base ++ x11 ++ greeter;
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

pub const Config = configType();
