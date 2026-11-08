//! Configuration used by zgsld.
//!
//! The concrete field types depend on build options:
//! - `x11` is `void` when built with `-Dx11=false`.

const build_options = @import("build_options");
const ipc = @import("ipc");
pub const Vt = @import("vt").Vt;

pub const X11Config = struct {
    /// X server command, optionally with args.
    command: []const u8 = build_options.x11_cmd,

    /// VT used for X11 sessions. `null` follows the main `vt` setting.
    vt: ?u8 = null,

    /// Timeout for Xorg startup
    startup_timeout_seconds: u32 = 10,
};

const GreeterConfig = struct {
    /// System user that runs the greeter process.
    user: []const u8 = build_options.greeter_user,

    /// PAM service used to start the greeter's session.
    service_name: ?[]const u8 = build_options.greeter_service_name,

    /// Session backend used to run the greeter process.
    session_type: ipc.SessionType = .command,

    /// Command used to launch the greeter.
    /// When using the embedded daemon, the greeter's executable path and arguments are appended.
    command: ?[]const u8 = null,
};

const SessionConfig = struct {
    /// PAM service used for user authentication and session management.
    service_name: []const u8 = build_options.service_name,
};

const AutologinConfig = struct {
    /// User account to autologin. Unset/empty disables autologin.
    user: ?[]const u8 = null,

    /// Session backend used for autologin.
    session_type: ipc.SessionType = .command,

    /// Session command with optional args.
    command: ?[]const u8 = null,

    /// Delay before autologin. 0 for immediate start.
    timeout_seconds: u64 = 0,
};

/// VT handling policy for greeter/session startup.
/// `unmanaged` uses tty/VT context established by an external launcher.
vt: Vt = .current,

greeter: GreeterConfig = .{},
session: SessionConfig = .{},
autologin: AutologinConfig = .{},

/// X11 configuration (`void` when built with `-Dx11=false`).
x11: if (build_options.x11_support) X11Config else void =
    if (build_options.x11_support) .{} else {},
