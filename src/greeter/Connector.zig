const ipc = @import("ipc");
const Connector = @This();

pub const Zgsld = @import("Connector/Zgsld.zig");

connect: *const fn (*Connector) anyerror!ipc.Transport,
