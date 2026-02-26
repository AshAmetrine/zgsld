//! Configuration used by zgsld.
//!
//! The concrete field types depend on build options:
//! - `x11` is `void` when built without `-Dx11`.
//! - `greeter_cmd` is `void` for standalone greeter builds.

const build_options = @import("build_options");

const X11Config = struct {
    cmd: []const u8 = build_options.x11_cmd,
};

/// PAM service used for user authentication.
service_name: []const u8 = build_options.service_name,

/// System user that runs the greeter process.
greeter_user: []const u8 = build_options.greeter_user,

/// PAM service used to start the greeter's session.
greeter_service_name: []const u8 = build_options.greeter_service_name,

/// VT to switch to before starting greeter/session.
/// null to use current controlling tty
vt: ?u8 = build_options.vt,

/// X11 configuration (`void` when built without `-Dx11`).
x11: if (build_options.x11_support) X11Config else void =
    if (build_options.x11_support) .{} else {},

/// Greeter command for zgsld to run (`void` in standalone greeter mode).
greeter_cmd: if (!build_options.standalone) ?[:0]const u8 else void =
    if (!build_options.standalone) null else {},
