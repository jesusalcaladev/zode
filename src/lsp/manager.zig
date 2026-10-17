//! The set of running language servers, for the whole process.
//!
//! A server is expensive to start (hundreds of milliseconds while it indexes)
//! and is useless if it is restarted per query, so the client outlives the turn
//! that created it and lives here. The registry is a module global rather than a
//! field of the `Model` for the same reason `bgproc` keeps jobs in the `Model`
//! and the provider keys live in a module global: the call site is
//! `tools.execute`, which has no `Model`.
//!
//! Ownership is explicit. The `gpa` is the app's (never a turn's arena — a server
//! started in one turn is used in the next), the map keys are the static names
//! from `servers.zig`, and `shutdown` is what frees the rest. It is called from
//! `quitFast` (which skips the defers) and from the TUI's teardown, after the
//! workers have stopped.

const std = @import("std");
const client = @import("client.zig");
const process = @import("process.zig");
const servers = @import("servers.zig");

/// A caller-owned failure message. The tool shows it; the manager fills it.
pub const ErrText = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *ErrText, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.buf, fmt, args) catch self.buf[0..0];
        self.len = s.len;
    }
    pub fn setText(self: *ErrText, s: []const u8) void {
        const n = @min(s.len, self.buf.len);
        @memcpy(self.buf[0..n], s[0..n]);
        self.len = n;
    }
    pub fn slice(self: *const ErrText) []const u8 {
        return self.buf[0..self.len];
    }
};

var lock: std.atomic.Mutex = .unlocked;
var gpa: std.mem.Allocator = std.heap.page_allocator;
var io_g: std.Io = undefined;
var ready = false;
/// How long a plain request may take, and how long `initialize` may take. The
/// second is much larger because a cold `rust-analyzer` indexes the crate before
/// it answers anything at all.
var request_timeout_ms: i64 = 15_000;
var init_timeout_ms: i64 = 30_000;
/// The workspace root, and its `file://` form. They live in `root_arena` for the
/// life of the process: `shutdown` frees the whole arena at once, so no caller
/// has to remember how each slice was allocated. (A slice built by an
/// `Io.Writer.Allocating` has capacity past its length, and freeing it by length
/// is an `Invalid free`.)
var root_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
var root: []const u8 = &.{};
var root_uri: []const u8 = &.{};
/// server name -> running client. Keys are the STATIC names from `servers.zig`.
var clients: std.StringHashMapUnmanaged(*client.Client) = .empty;

pub fn init(g: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map) void {
    lock2();
    defer unlock();
    gpa = g;
    io_g = io;
    request_timeout_ms = envMs(env, "ZODE_LSP_TIMEOUT_MS", 15_000);
    init_timeout_ms = envMs(env, "ZODE_LSP_INIT_TIMEOUT_MS", 30_000);
    if (root.len == 0) {
        root_arena = std.heap.ArenaAllocator.init(g);
        const a = root_arena.allocator();
        const cwd = std.Io.Dir.cwd().realPathFileAlloc(io, ".", g) catch null;
        root = if (cwd) |c| (a.dupe(u8, c) catch ".") else ".";
        if (cwd) |c| g.free(c);
        root_uri = @import("protocol.zig").pathToUri(a, root) catch (a.dupe(u8, "file://.") catch "file://.");
    }
    ready = true;
}

/// Kills every server and frees the registry. Safe to call when nothing is
/// running, which is what `quitFast` relies on.
pub fn shutdown() void {
    lock2();
    defer unlock();
    var it = clients.iterator();
    while (it.next()) |e| e.value_ptr.*.destroy();
    clients.deinit(gpa);
    clients = .empty;
    root_arena.deinit();
    root_arena = .init(std.heap.page_allocator);
    root = &.{};
    root_uri = &.{};
    ready = false;
}

pub fn workspaceRoot() []const u8 {
    return root;
}

/// How long a request may wait for its response (see `ZODE_LSP_TIMEOUT_MS`).
pub fn requestTimeoutMs() i64 {
    return request_timeout_ms;
}

/// A `ZODE_*_MS` value clamped to `[1s, 10min]`. An unparsable or absent value
/// takes the default rather than 0: a 0 here would make every request timeout on
/// the spot, which reads as "the language server is broken".
fn envMs(env: ?*const std.process.Environ.Map, key: []const u8, default: i64) i64 {
    const m = env orelse return default;
    const raw = m.get(key) orelse return default;
    const n = std.fmt.parseInt(i64, raw, 10) catch return default;
    return @min(@max(n, 1000), 600_000);
}

/// A client for the language of `abs_path`, LOCKED (release it with `done`), or
/// null when no server is configured for that extension.
///
/// The registry lock is held across a spawn and a handshake, so two servers
/// cannot be started at the same instant. That is a deliberate simplification: a
/// turn that needs two languages at once is rare, and a half-initialized client
/// published to the map would be worse.
pub fn use(abs_path: []const u8, err_out: *ErrText) !?*client.Client {
    lock2();
    defer unlock();
    if (!ready) return null;
    const spec = servers.find(&.{}, abs_path) orelse return null;

    if (clients.get(spec.name)) |c| {
        c.acquire();
        return c;
    }

    const t = process.spawn(gpa, io_g, spec.command) catch |e| switch (e) {
        error.ServerNotFound => {
            err_out.set("language server `{s}` is not installed (command not found in PATH)", .{spec.command[0]});
            return error.ServerNotFound;
        },
        else => {
            err_out.set("could not start `{s}`: {t}", .{ spec.command[0], e });
            return error.SpawnFailed;
        },
    };
    const c = client.Client.create(gpa, io_g, t, spec.language_id, root_uri) catch |e| {
        t.close();
        err_out.set("out of memory starting `{s}`", .{spec.command[0]});
        return e;
    };
    c.init_timeout_ms = init_timeout_ms;
    c.request_timeout_ms = request_timeout_ms;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    c.handshake(arena_state.allocator()) catch |e| {
        switch (e) {
            error.InitializeFailed => err_out.set("`{s}` refused to initialize: {s} (code {d})", .{ spec.command[0], c.init_fail.message, c.init_fail.code }),
            error.Timeout => err_out.set("`{s}` did not answer `initialize` in time", .{spec.command[0]}),
            else => err_out.set("`{s}` failed during `initialize`: {t}", .{ spec.command[0], e }),
        }
        c.destroy();
        return e;
    };

    try clients.put(gpa, spec.name, c);
    c.acquire();
    return c;
}

/// Releases the client lock taken by `use`.
pub fn done(c: *client.Client) void {
    c.release();
}

fn lock2() void {
    var spins: u32 = 0;
    while (!lock.tryLock()) {
        spins += 1;
        if (spins > 1000) {
            @import("../lib/sleep.zig").nap(@min(spins / 100, 20));
        } else {
            std.Thread.yield() catch {};
        }
    }
}

fn unlock() void {
    lock.unlock();
}

test "manager: an extension with no server starts nothing and reports null" {
    init(std.testing.allocator, std.testing.io, null);
    defer shutdown();

    var err_text: ErrText = .{};
    const none = try use("notes.txt", &err_text);
    try std.testing.expect(none == null);
    try std.testing.expectEqual(@as(usize, 0), err_text.len);
}

test "manager: a known extension with a missing binary names the binary" {
    init(std.testing.allocator, std.testing.io, null);
    defer shutdown();

    // `.zig` maps to zls. If zls IS installed the spawn succeeds and this test
    // has nothing to say, so it is skipped rather than made flaky — the missing
    // path is exercised by every machine that does not have it.
    var err_text: ErrText = .{};
    const c = use("a.zig", &err_text) catch |e| {
        try std.testing.expect(e == error.ServerNotFound or e == error.SpawnFailed);
        try std.testing.expect(std.mem.indexOf(u8, err_text.slice(), "zls") != null);
        return;
    };
    if (c) |client_ptr| {
        // zls is installed: the spawn worked, so there is no message to check.
        done(client_ptr);
    }
}
