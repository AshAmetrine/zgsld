//! Configuration used by zgsld.
//!
//! The concrete field types depend on build options:
//! - `x11` is `void` when built without `-Dx11`.

const build_options = @import("build_options");
const Ipc = @import("Ipc");
pub const Vt = @import("vt").Vt;

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

    /// Greeter command for zgsld to run (acts as a wrapper in standalone greeter mode).
    command: ?[:0]const u8 = null,
};

const SessionConfig = struct {
    /// PAM service used for user authentication.
    service_name: []const u8 = build_options.service_name,
};

const AutologinConfig = struct {
    /// User account to autologin. Unset/empty disables autologin.
    user: ?[:0]const u8 = null,

    /// Session backend used for autologin.
    session_type: Ipc.SessionType = .command,

    /// Session command with optional args.
    command: ?[:0]const u8 = null,

    /// Delay before launching autologin. 0 for immediate start.
    timeout_seconds: u64 = 0,
};

/// VT handling policy for greeter/session startup.
/// `unmanaged` uses tty/VT context established by an external launcher.
vt: Vt = .current,

greeter: GreeterConfig = .{},
session: SessionConfig = .{},
autologin: AutologinConfig = .{},

/// X11 configuration (`void` when built without `-Dx11`).
x11: if (build_options.x11_support) X11Config else void =
    if (build_options.x11_support) .{} else {},
