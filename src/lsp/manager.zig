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
/// The user's own servers (`lsp_servers` in config.json).
///
/// COPIED into the manager's own arena, and that is not tidiness: the config's
/// arena is freed on every reload (connecting a provider reloads it), and a
/// server list that pointed into it would be a dangling pointer from the next
/// reload on — the manager would hand the model a command built from freed
/// memory.
var extra: []const servers.Server = &.{};
var extra_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

/// The servers the user configured, in the manager's own memory.
pub fn extraServers() []const servers.Server {
    return extra;
}

/// Has the manager been initialised?
///
/// It has not in a test that calls the tool without an app around it, and
/// that is worth saying out loud: "no language server is configured for .zig"
/// would send the reader looking at the server TABLE when the problem is that
/// nobody started the manager.
pub fn isReady() bool {
    return ready;
}

/// The language id of the server that would answer for `path` ("zig", "c"...).
///
/// It is asked per FILE and not per client because one server can serve two
/// languages: `typescript-language-server` answers for `.ts` ("typescript") and
/// for `.tsx` ("typescriptreact"), and a client that carries ONE language id
/// opens a `.tsx` file as TypeScript — which is a parse error waiting to
/// happen.
pub fn languageIdFor(path: []const u8) []const u8 {
    const spec = servers.find(extra, path) orelse return "";
    return spec.language_id;
}

/// Replaces the user's servers with `list`.
///
/// The list is copied: the caller's memory (the config's arena) does not
/// outlive the call.
pub fn setServers(list: []const servers.Server) !void {
    lock2();
    defer unlock();
    // The new list is built in a FRESH arena and the old one is thrown away
    // only when the new one is complete: a half-installed list is worse than
    // the previous one, and the old arena is freed while it is still in use.
    var new_arena = std.heap.ArenaAllocator.init(gpa);
    errdefer new_arena.deinit();
    const a = new_arena.allocator();
    var out: std.ArrayList(servers.Server) = .empty;
    for (list) |s| {
        var cmd: std.ArrayList([]const u8) = .empty;
        for (s.command) |c| try cmd.append(a, try a.dupe(u8, c));
        var ext: std.ArrayList([]const u8) = .empty;
        for (s.extensions) |e| try ext.append(a, try a.dupe(u8, e));
        try out.append(a, .{
            .name = try a.dupe(u8, s.name),
            .language_id = try a.dupe(u8, s.language_id),
            .command = cmd.items,
            .extensions = ext.items,
        });
    }
    extra_arena.deinit();
    extra_arena = new_arena;
    extra = out.items;
}

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
    while (it.next()) |e| {
        gpa.free(e.key_ptr.*);
        // A client is only freed if NOBODY is inside it. A worker in the
        // middle of a question holds the client's lock, and freeing it under
        // that thread is a use-after-free in a thread that is not the turn's.
        //
        // The server is killed either way: a `zls` that outlives the app keeps
        // indexing a project nobody is looking at any more. Killing the
        // process (and not freeing the transport) closes the pipe, so the
        // thread inside it wakes up and unwinds on its own.
        if (tryTake(e.value_ptr.*)) {
            e.value_ptr.*.destroy();
        } else {
            e.value_ptr.*.kill();
        }
    }
    clients.deinit(gpa);
    clients = .empty;
    extra_arena.deinit();
    extra_arena = .init(std.heap.page_allocator);
    extra = &.{};
    root_arena.deinit();
    root_arena = .init(std.heap.page_allocator);
    root = &.{};
    root_uri = &.{};
    ready = false;
}

/// Takes the client's lock if nobody holds it, and gives it back.
///
/// Bounded on purpose: the exit does not wait for a server that is thinking.
fn tryTake(c: *client.Client) bool {
    var spins: u32 = 0;
    while (!c.lock.tryLock()) {
        spins += 1;
        if (spins > 1000) return false;
        std.Thread.yield() catch {};
    }
    c.lock.unlock();
    return true;
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
    const spec = servers.find(extra, abs_path) orelse return null;

    if (clients.get(spec.name)) |c| {
        if (!c.dead) {
            c.acquire();
            return c;
        }
        // The server is GONE (its pipe closed). Handing out this client again
        // would answer every question with `ServerClosed`, so it is replaced.
        //
        // The client is taken over FIRST: `destroy` frees it, and a thread that
        // is still inside it would be reading freed memory. Nobody can be
        // inside it AND waiting for the manager's lock (the tool takes the
        // client lock before it takes the manager's), so this is safe.
        if (tryTake(c)) {
            if (clients.fetchRemove(spec.name)) |kv| gpa.free(kv.key);
            c.destroy();
        } else {
            // Somebody is inside it right now: they will get the error, and the
            // NEXT call replaces the client.
            c.acquire();
            return c;
        }
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

    // The KEY is a copy and not `spec.name`: a user's server name lives in the
    // config's arena, which is freed when the config is reloaded, and a map key
    // that dangles is a use-after-free the next time the map is walked.
    const key = try gpa.dupe(u8, spec.name);
    errdefer gpa.free(key);
    try clients.put(gpa, key, c);
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

test "manager: the user's server wins over the built-in one" {
    init(std.testing.allocator, std.testing.io, null);
    defer shutdown();

    // Without the user's server, `.zig` is zls and `.txt` is nothing.
    try std.testing.expectEqualStrings("zls", servers.find(extraServers(), "a.zig").?.name);
    try std.testing.expect(servers.find(extraServers(), "a.txt") == null);

    try setServers(&[_]servers.Server{
        .{
            .name = "my-zls",
            .language_id = "zig",
            .command = &.{"my-lsp"},
            .extensions = &.{".zig"},
        },
        .{
            .name = "txtlsp",
            .language_id = "text",
            .command = &.{"txtlsp"},
            .extensions = &.{".txt"},
        },
    });

    // The user's server wins for the extension it claims...
    try std.testing.expectEqualStrings("my-zls", servers.find(extraServers(), "a.zig").?.name);
    // ...and it can claim one zode does not ship at all.
    try std.testing.expectEqualStrings("txtlsp", servers.find(extraServers(), "a.txt").?.name);
    // The language id is asked PER FILE: one server can serve two languages.
    try std.testing.expectEqualStrings("zig", languageIdFor("a.zig"));
    try std.testing.expectEqualStrings("text", languageIdFor("a.txt"));
    try std.testing.expectEqualStrings("", languageIdFor("a.unknown"));
}

test "manager: the user's servers are COPIED, not borrowed" {
    init(std.testing.allocator, std.testing.io, null);
    defer shutdown();

    // The caller's memory is the config's arena, which is freed on the next
    // reload. A manager that kept the pointer would be holding freed memory
    // from then on, and the symptom would be a command built out of garbage.
    var name: [8]u8 = undefined;
    @memcpy(name[0..4], "mine");
    const list = [_]servers.Server{.{
        .name = name[0..4],
        .language_id = "zig",
        .command = &.{"my-lsp"},
        .extensions = &.{".zig"},
    }};
    try setServers(&list);
    // The caller's buffer goes away...
    @memset(&name, 'x');
    // ...and the manager still has the real name.
    try std.testing.expectEqualStrings("mine", extraServers()[0].name);
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
