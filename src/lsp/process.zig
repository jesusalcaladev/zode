//! A language server as a child process, behind the `client.Transport` vtable.
//!
//! This is the only file that knows a server is a process. Reads go through
//! `poll` + `read` on the stdout fd rather than a buffered reader, because the
//! timeout has to be real: a server that never answers (a crash on startup, a
//! deadlock while indexing) must not freeze the agent, and a `read` on a pipe
//! with no deadline is exactly that freeze.
//!
//! stderr is discarded. Draining it would need a thread per server and a pipe
//! buffer that a chatty `rust-analyzer` can fill; a server that dies on startup
//! shows up as end-of-stream, and the actionable answer is "is the binary
//! installed", not its log.

const std = @import("std");
const client = @import("client.zig");

pub const Process = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    child: std.process.Child,
    /// The group leader's pid, for `kill(-pid)`. Servers such as rust-analyzer
    /// spawn children (cargo, rustc) that must die with the parent.
    pid: std.posix.pid_t,

    pub fn transport(self: *Process) client.Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = client.Transport.VTable{
        .writeAll = writeAll,
        .readSome = readSome,
        .close = close,
    };

    fn writeAll(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *Process = @ptrCast(@alignCast(ctx));
        const in = self.child.stdin orelse return error.ServerClosed;
        in.writeStreamingAll(self.io, bytes) catch return error.ServerClosed;
    }

    fn readSome(ctx: *anyopaque, buf: []u8, timeout_ms: i64) anyerror!usize {
        const self: *Process = @ptrCast(@alignCast(ctx));
        const out = self.child.stdout orelse return error.ServerClosed;
        var fds = [_]std.posix.pollfd{.{ .fd = out.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const capped: i32 = @intCast(@min(@max(timeout_ms, 0), std.math.maxInt(i32)));
        const ready = std.posix.poll(&fds, capped) catch return error.ServerClosed;
        if (ready == 0) return error.Timeout;
        // POLLHUP reaches here as readiness too, and the `read` below returns 0
        // for it — which the client turns into end-of-stream.
        return std.posix.read(out.handle, buf) catch return error.ServerClosed;
    }

    fn close(ctx: *anyopaque) void {
        const self: *Process = @ptrCast(@alignCast(ctx));
        const io = self.io;
        // The whole GROUP first: a server's children are not in the `Child`
        // struct and would be orphaned by killing the leader alone.
        if (self.pid != 0) std.posix.kill(-self.pid, std.posix.SIG.KILL) catch {};
        // Reap, do NOT `Child.kill`: that sends a signal before waiting, and the
        // pid is already dead — `childKillPosix` would answer `.CHILD` and panic.
        _ = self.child.wait(io) catch {};
        if (self.child.stdin) |f| f.close(io);
        if (self.child.stdout) |f| f.close(io);
        if (self.child.stderr) |f| f.close(io);
        self.child.stdin = null;
        self.child.stdout = null;
        self.child.stderr = null;
        self.gpa.destroy(self);
    }
};

/// Starts `argv` and returns its transport, or an error naming what went wrong.
///
/// `error.ServerNotFound` is split out from the rest on purpose: it is the one
/// failure the user can fix by installing a package, and the tool's message says
/// which binary it looked for.
pub fn spawn(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !client.Transport {
    const self = try gpa.create(Process);
    errdefer gpa.destroy(self);

    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
        .pgid = 0,
    }) catch |e| switch (e) {
        error.FileNotFound => return error.ServerNotFound,
        error.AccessDenied => return error.ServerNotFound,
        else => return e,
    };
    errdefer {
        std.posix.kill(-(child.id orelse 0), std.posix.SIG.KILL) catch {};
        _ = child.wait(io) catch {};
    }

    self.* = .{
        .gpa = gpa,
        .io = io,
        .child = child,
        .pid = child.id orelse 0,
    };
    return self.transport();
}
