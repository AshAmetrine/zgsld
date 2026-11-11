const common = @import("common");
pub const ProcessContext = common.ProcessContext;
pub const Config = common.Config;
pub const Greeter = @import("greeter/Greeter.zig");
pub const Connector = @import("greeter/Connector.zig");
pub const ipc = @import("ipc");
pub const preview = @import("preview");

/// Helpers for desktop files
pub const desktop = @import("greeter/desktop.zig");
pub const users = @import("greeter/users.zig");

test {
    _ = desktop;
    _ = users;
}
