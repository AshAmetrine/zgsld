const build_options = @import("build_options");

const X11Config = struct {
    cmd: []const u8 = build_options.x11_cmd,
};

service_name: []const u8 = build_options.service_name,
greeter_user: []const u8 = build_options.greeter_user,
greeter_service_name: []const u8 = build_options.greeter_service_name,
vt: ?u8 = build_options.vt,

x11: if (build_options.x11_support) X11Config else void =
    if (build_options.x11_support) .{} else {},

greeter_cmd: if (!build_options.standalone) ?[:0]const u8 else void =
    if (!build_options.standalone) null else {},
