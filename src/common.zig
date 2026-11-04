//! Configuration and IO helpers shared by greeter and daemon implementations.
pub const Config = @import("Config.zig");
pub const fd = @import("fd.zig");
pub const SocketPair = @import("SocketPair.zig");
pub const ProcessContext = @import("ProcessContext.zig");
