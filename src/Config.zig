//! Configuration used by zgsld.
//!
//! The concrete field types depend on build options:
//! - `x11` is `void` when built without `-Dx11`.
//! - `greeter_cmd` is `void` for standalone greeter builds.

const build_options = @import("build_options");
const Ipc = @import("Ipc");

const X11Config = struct {
    /// X server command, optionally with args.
    command: []const u8 = build_options.x11_cmd,
};

const GreeterConfig = struct {
    /// System user that runs the greeter process.
    user: []const u8 = build_options.greeter_user,

    /// PAM service used to start the greeter's session.
    service_name: []const u8 = build_options.greeter_service_name,

    /// Session backend used to run the greeter process.
    session_type: Ipc.SessionType = .command,

    /// Greeter command for zgsld to run (`void` in standalone greeter mode).
    command: if (!build_options.standalone) ?[:0]const u8 else void =
    if (!build_options.standalone) null else {},
};

const SessionConfig = struct {
    /// PAM service used for user authentication.
    service_name: []const u8 = build_options.service_name,
};

/// VT to switch to before starting greeter/session.
/// null to use current controlling tty
vt: ?u8 = build_options.vt,

greeter: GreeterConfig = .{},
session: SessionConfig = .{},

/// X11 configuration (`void` when built without `-Dx11`).
x11: if (build_options.x11_support) X11Config else void =
    if (build_options.x11_support) .{} else {},
