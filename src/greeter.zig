//! Greeter application lifecycle, IPC interfaces and preview support.

pub const ProcessContext = @import("common").ProcessContext;
pub const Greeter = @import("greeter/Greeter.zig");
pub const ipc = @import("ipc");
pub const preview = @import("preview");
