//! Greeter application lifecycle, IPC interfaces and preview support.

const common = @import("common");
pub const ProcessContext = common.ProcessContext;
pub const Config = common.Config;
pub const Greeter = @import("greeter/Greeter.zig");
pub const ZgsldConnector = @import("greeter/ZgsldConnector.zig");
pub const ipc = @import("ipc");
pub const preview = @import("preview");
