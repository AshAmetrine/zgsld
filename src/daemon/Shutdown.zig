const std = @import("std");
pub const Connection = @import("Shutdown/Connection.zig");
const Shutdown = @This();
const fd_utils = @import("../fd.zig");
const log = std.log.scoped(.zgsld);
const handled_signals = [_]std.posix.SIG{ .TERM, .INT, .HUP, .QUIT, .ALRM };

var wake_fd = std.atomic.Value(std.posix.fd_t).init(-1);
var shutdown_requested = std.atomic.Value(bool).init(false);
var active_handlers = std.atomic.Value(usize).init(0);

io: std.Io,
wake_pipe: [2]std.posix.fd_t,
previous: [handled_signals.len]std.posix.Sigaction,
mutex: std.Io.Mutex = .init,
thread: ?std.Thread = null,
stopped: bool = false,
workers: [2]Worker = .{ .{}, .{} },
options: Options,

pub const Options = struct {
    term_seconds: c_uint = 5,
    cleanup_seconds: c_uint = 10,
};
const Phase = union(enum) { running, grace, term: Connection.Role, kill: Connection.Role, cleanup, killed };

pub const Worker = struct {
    process: std.process.Child = undefined,
    pid: ?std.posix.pid_t = null,
    socket: std.posix.fd_t = -1,
    ipc: ?std.posix.fd_t = null,
    connected: bool = false,
    generation: usize = 0,
    pids: [2]?std.posix.pid_t = .{ null, null },
    phase: Phase = .running,
    deadline: ?std.Io.Timestamp = null,
    forced: bool = false,

    fn arm(self: *Worker, control: *Shutdown, phase: Phase, seconds: c_uint) void {
        self.phase = phase;
        self.deadline = std.Io.Clock.awake.now(control.io).addDuration(.fromSeconds(seconds));
    }

    fn signal(self: *Worker, role: Connection.Role, sig: std.posix.SIG) void {
        if (self.pids[@backingInt(role)]) |pid| std.posix.kill(pid, sig) catch {};
    }

    fn stopChild(self: *Worker, control: *Shutdown, role: Connection.Role) void {
        if (self.pids[@backingInt(role)] != null) {
            self.signal(role, .TERM);
            self.arm(control, .{ .term = role }, control.options.term_seconds);
        } else switch (role) {
            .session => self.stopChild(control, .x11),
            .x11 => self.arm(control, .cleanup, control.options.cleanup_seconds),
        }
    }

    fn beginStop(self: *Worker, control: *Shutdown, grace_seconds: c_uint) void {
        if (self.phase != .running) return;
        if (grace_seconds != 0 and self.pids[0] != null) {
            self.arm(control, .grace, grace_seconds);
            return;
        }
        self.cancel();
        self.stopChild(control, .session);
    }

    fn cancel(self: *Worker) void {
        if (self.ipc) |fd| _ = std.c.shutdown(fd, 2);
        if (self.pid) |pid| std.posix.kill(pid, .TERM) catch {};
    }

    fn exited(self: *Worker, control: *Shutdown, role: Connection.Role) void {
        self.pids[@backingInt(role)] = null;
        switch (self.phase) {
            .running => self.beginStop(control, 0),
            .grace => if (role == .session) {
                self.cancel();
                self.stopChild(control, .session);
            },
            .term, .kill => |current| if (role == current) self.stopChild(control, current),
            .cleanup, .killed => {},
        }
    }

    fn killChildren(self: *Worker) void {
        self.signal(.session, .KILL);
        self.signal(.x11, .KILL);
        self.pids = .{ null, null };
    }

    fn expire(self: *Worker, control: *Shutdown) void {
        self.deadline = null;
        switch (self.phase) {
            .grace => {
                self.cancel();
                self.stopChild(control, .session);
            },
            .term => |role| {
                self.forced = true;
                self.signal(role, .KILL);
                self.arm(control, .{ .kill = role }, control.options.cleanup_seconds);
            },
            .kill, .cleanup => {
                self.killChildren();
                if (self.pid) |pid| std.posix.kill(pid, .KILL) catch {};
                self.forced = true;
                self.phase = .killed;
                log.err("Worker did not finish shutdown; sending SIGKILL", .{});
            },
            .running, .killed => unreachable,
        }
    }

    fn disconnected(self: *Worker, control: *Shutdown) void {
        self.connected = false;
        _ = std.c.shutdown(self.socket, 2);
        self.killChildren();
        self.arm(control, .cleanup, control.options.cleanup_seconds);
    }

    fn receive(self: *Worker, control: *Shutdown, packet: Connection.Packet) !void {
        const index = @backingInt(packet.role);
        switch (packet.message) {
            .register => {
                if (self.pids[index] != null) return error.DuplicateProcess;
                self.pids[index] = packet.pid;
                const stopping = self.phase != .running;
                try Connection.send(self.socket, .{ .message = if (stopping) .stopping else .accepted, .role = packet.role });
                if (stopping) self.signal(packet.role, .KILL);
            },
            .exited => {
                if (self.pids[index] == null) return error.InvalidControlMessage;
                self.exited(control, packet.role);
            },
            .stop => self.beginStop(control, 0),
            .accepted, .stopping => return error.InvalidControlMessage,
        }
    }

    fn drain(self: *Worker, control: *Shutdown) void {
        while (self.connected) {
            const packet = Connection.receive(self.socket, true) catch |err| {
                if (err == error.WouldBlock) return;
                log.err("Worker process notification failed: {s}", .{@errorName(err)});
                self.disconnected(control);
                return;
            };
            self.receive(control, packet orelse {
                self.disconnected(control);
                return;
            }) catch |err| {
                log.err("Invalid worker process notification: {s}", .{@errorName(err)});
                self.disconnected(control);
            };
        }
    }
};

pub fn init(io: std.Io, options: Options) !Shutdown {
    std.debug.assert(options.term_seconds > 0 and options.cleanup_seconds > 0);
    const pipe = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
    std.debug.assert(wake_fd.load(.seq_cst) == -1);
    shutdown_requested.store(false, .seq_cst);
    wake_fd.store(pipe[1], .seq_cst);
    var previous: [handled_signals.len]std.posix.Sigaction = undefined;
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = handleSignal }, .mask = std.posix.sigemptyset(), .flags = 0 };
    for (handled_signals, &previous) |sig, *old| std.posix.sigaction(sig, &action, old);
    return .{ .io = io, .wake_pipe = pipe, .previous = previous, .options = options };
}

pub fn start(self: *Shutdown) !void {
    self.thread = try std.Thread.spawn(.{}, run, .{self});
}

pub fn deinit(self: *Shutdown) void {
    for (&self.workers) |*worker| if (worker.pid != null) self.requestStop(worker, 0);
    for (&self.workers) |*worker| self.stop(worker);
    self.mutex.lockUncancelable(self.io);
    self.stopped = true;
    self.mutex.unlock(self.io);
    self.wake();
    if (self.thread) |thread| thread.join();
    _ = std.c.alarm(0);
    // Discard an alarm already pending before restoring its old disposition.
    const ignore: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.ALRM, &ignore, null);
    for (handled_signals, &self.previous) |sig, *old| std.posix.sigaction(sig, old, null);
    wake_fd.store(-1, .seq_cst);
    // A handler that already loaded the descriptor must finish before it closes.
    while (active_handlers.load(.seq_cst) != 0) std.atomic.spinLoopHint();
    for (self.wake_pipe) |fd| _ = std.c.close(fd);
    self.* = undefined;
}

// Takes ownership of the process and socket on success; duplicates the IPC file.
pub fn addWorker(self: *Shutdown, process: std.process.Child, socket: std.Io.File, ipc: ?std.Io.File) !*Worker {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    for (&self.workers) |*worker| {
        if (worker.pid != null) continue;
        const ipc_fd = if (ipc) |file| blk: {
            const fd = std.c.fcntl(file.handle, if (@hasDecl(std.posix.F, "DUPFD_CLOEXEC")) std.posix.F.DUPFD_CLOEXEC else std.posix.F.DUPFD, @as(c_int, 0));
            if (fd < 0) return std.posix.unexpectedErrno(std.c.errno(fd));
            errdefer _ = std.c.close(fd);
            if (!@hasDecl(std.posix.F, "DUPFD_CLOEXEC")) try fd_utils.setCloseOnExec(fd);
            break :blk fd;
        } else null;
        worker.* = .{ .process = process, .pid = process.id.?, .socket = socket.handle, .ipc = ipc_fd, .connected = true, .generation = worker.generation +% 1 };
        self.wake();
        return worker;
    }
    return error.TooManyWorkers;
}

pub fn shutdownRequested() bool {
    return shutdown_requested.load(.seq_cst);
}

pub fn requestStop(self: *Shutdown, worker: *Worker, grace_seconds: c_uint) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (worker.pid != null) worker.beginStop(self, grace_seconds);
    self.wake();
}

pub fn wait(self: *Shutdown, worker: *Worker) !std.process.Child.Term {
    const protection = self.io.swapCancelProtection(.blocked);
    defer _ = self.io.swapCancelProtection(protection);
    const term = try worker.process.wait(self.io);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    worker.drain(self);
    worker.killChildren();
    worker.pid = null;
    worker.connected = false;
    worker.deadline = null;
    _ = std.c.close(worker.socket);
    worker.socket = -1;
    if (worker.ipc) |fd| _ = std.c.close(fd);
    worker.ipc = null;
    self.wake();
    return term;
}

pub fn stop(self: *Shutdown, worker: *Worker) void {
    if (worker.pid == null) return;
    self.requestStop(worker, 0);
    _ = self.wait(worker) catch |err| log.err("Failed to wait for worker: {s}", .{@errorName(err)});
}

fn wake(self: *Shutdown) void {
    notify(self.wake_pipe[1]);
}

fn run(self: *Shutdown) void {
    while (true) {
        self.mutex.lockUncancelable(self.io);
        if (self.stopped) {
            self.mutex.unlock(self.io);
            return;
        }
        const now = std.Io.Clock.awake.now(self.io);
        var next: ?std.Io.Timestamp = null;
        var fds: [3]std.c.pollfd = undefined;
        var generations: [2]usize = undefined;
        fds[0] = .{ .fd = self.wake_pipe[0], .events = std.c.POLL.IN, .revents = 0 };
        for (&self.workers, 0..) |*worker, i| {
            if (worker.pid != null) {
                if (shutdownRequested()) worker.beginStop(self, 0);
                if (worker.deadline) |deadline| if (now.compare(.gte, deadline)) worker.expire(self);
                if (worker.deadline) |deadline| if (next == null or deadline.compare(.lt, next.?)) {
                    next = deadline;
                };
            }
            fds[i + 1] = .{ .fd = if (worker.connected) worker.socket else -1, .events = std.c.POLL.IN, .revents = 0 };
            generations[i] = worker.generation;
        }
        const seconds: c_uint = if (next) |deadline| @intCast(@max(1, @divCeil(std.Io.Clock.awake.now(self.io).durationTo(deadline).toNanoseconds(), std.time.ns_per_s))) else 0;
        _ = std.c.alarm(seconds);
        self.mutex.unlock(self.io);

        const rc = std.c.poll(&fds, fds.len, -1);
        if (rc < 0 and std.c.errno(rc) == .INTR) continue;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (rc < 0) {
            for (&self.workers) |*worker| if (worker.pid != null) {
                worker.killChildren();
                std.posix.kill(worker.pid.?, .KILL) catch {};
            };
            return;
        }
        if (fds[0].revents != 0) {
            var bytes: [64]u8 = undefined;
            while (std.c.read(self.wake_pipe[0], &bytes, bytes.len) > 0) {}
        }
        for (&self.workers, 0..) |*worker, i| {
            if (worker.connected and worker.generation == generations[i] and fds[i + 1].revents != 0) worker.drain(self);
        }
    }
}

fn handleSignal(sig: std.posix.SIG) callconv(.c) void {
    const saved_errno = std.c._errno().*;
    defer std.c._errno().* = saved_errno;
    _ = active_handlers.fetchAdd(1, .seq_cst);
    defer _ = active_handlers.fetchSub(1, .seq_cst);
    if (sig != .ALRM) shutdown_requested.store(true, .seq_cst);
    const fd = wake_fd.load(.seq_cst);
    if (fd >= 0) notify(fd);
}

fn notify(fd: std.posix.fd_t) void {
    while (true) {
        const rc = std.c.write(fd, &[_]u8{1}, 1);
        if (rc < 0 and std.c.errno(rc) == .INTR) continue;
        // A full nonblocking pipe already contains a wakeup.
        return;
    }
}
