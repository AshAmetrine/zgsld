const std = @import("std");
const build_options = @import("build_options");
const Config = @import("common").Config;
const XServer = if (build_options.x11_support) @import("session/XServer.zig");
const Shutdown = @import("../../Shutdown.zig");

pub const X11Options = if (build_options.x11_support) Config.X11Config else void;

pub const Session = struct {
    child: std.process.Child,
    tty_file: std.Io.File,
    shutdown_conn: *Shutdown.Connection,

    x11: if (build_options.x11_support) ?XServer else void =
        if (build_options.x11_support) null else {},

    pub fn wait(self: *Session) !void {
        try self.shutdown_conn.wait(&self.child, .session);
    }

    pub fn deinit(self: *Session, io: std.Io) void {
        defer if (self.tty_file.handle > 2) self.tty_file.close(io);
        self.shutdown_conn.stop(&self.child, .session);
        if (build_options.x11_support) {
            if (self.x11) |*xsession| xsession.deinit(io);
        }
    }
};
