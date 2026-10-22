//! The MCP servers zode talks to, for the whole process.
//!
//! A module global, like `lsp/manager.zig`: the call site is `tools.execute`,
//! which has no `Model` to hang a registry on, and a server is EXPENSIVE to
//! start (a process, a handshake, a catalogue) and useless if it is restarted
//! per call.
//!
//! ## What lives where
//!
//! - The SERVER LIST is the user's configuration and it is COPIED into the
//!   manager's own arena: the config's arena is freed on every reload
//!   (connecting a provider reloads it), and a server list that pointed into it
//!   would be a command built out of freed memory.
//! - The CATALOGUE (every server's tools, with their schemas) lives in an
//!   arena that is only freed at shutdown, because it is what a search reads
//!   and it has to outlive the call that built it.
//! - The clients are killed at shutdown: a server that outlives the app keeps
//!   running a process for nobody.
//!
//! ## The catalogue is the whole point of the deferred loading
//!
//! The schemas of every tool of every server live HERE, and not in the
//! request's `tools` array. That array is the biggest stable prefix of every
//! request and the provider's cache is indexed by its literal bytes: adding a
//! server's schemas to it would rewrite the prefix of every request of every
//! session, and the cache would never hit again. The schemas come when the
//! model asks for them, in the result of a search.

const std = @import("std");
const client = @import("client.zig");
const process = @import("process.zig");
const servers = @import("servers.zig");
const search = @import("search.zig");

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

/// One running server and the tools it published.
const Entry = struct {
    client: *client.Client,
    tools: []const search.Entry,
};

var lock: std.atomic.Mutex = .unlocked;
var gpa: std.mem.Allocator = std.heap.page_allocator;
var io_g: std.Io = undefined;
/// The process environment, so a server inherits it plus its own variables.
var parent_env: ?*const std.process.Environ.Map = null;
var ready = false;

/// The servers, copied into the manager's own memory.
var server_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
var server_list: []const servers.Server = &.{};

/// The catalogue's arena: it lives until `shutdown`.
var cat_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
/// server name -> the running client and its tools.
var entries: std.StringHashMapUnmanaged(Entry) = .empty;

/// Has the manager been initialised?
///
/// It has not in a test that calls the tool without an app around it, and
/// that is worth saying out loud: "no MCP server is configured" would send
/// the reader looking at the config file when the problem is that nobody
/// started the manager.
pub fn isReady() bool {
    return ready;
}

/// The servers the user configured, in the manager's own memory.
pub fn configuredServers() []const servers.Server {
    return server_list;
}

pub fn init(g: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map) void {
    lock2();
    defer unlock();
    gpa = g;
    io_g = io;
    parent_env = env;
    ready = true;
}

/// Replaces the user's servers with `list`.
///
/// The list is copied: the caller's memory (the config's arena) does not
/// outlive the call.
///
/// The running servers are STOPPED, and not left running: a server whose
/// command changed in the config would keep running the old command until it
/// died, and the tool would answer with a catalogue nobody configured.
pub fn setServers(servers_in: []const servers.Server) !void {
    lock2();
    defer unlock();

    // The new list is built in a FRESH arena and the old one is thrown away
    // only when the new one is complete: a half-installed list is worse than
    // the previous one.
    var new_arena = std.heap.ArenaAllocator.init(gpa);
    errdefer new_arena.deinit();
    const a = new_arena.allocator();
    var out: std.ArrayList(servers.Server) = .empty;
    for (servers_in) |s| {
        var cmd: std.ArrayList([]const u8) = .empty;
        for (s.command) |c| try cmd.append(a, try a.dupe(u8, c));
        var envs: std.ArrayList(servers.EnvVar) = .empty;
        for (s.env) |e| {
            // A name with an `=` in it is not a name, and `Environ.Map.put`
            // ASSERTS on it: an assert in the user's own configuration is a
            // crash the user cannot do anything about.
            if (!servers.validEnvName(e.name)) continue;
            try envs.append(a, .{ .name = try a.dupe(u8, e.name), .value = try a.dupe(u8, e.value) });
        }
        try out.append(a, .{
            .name = try a.dupe(u8, s.name),
            .command = cmd.items,
            .env = envs.items,
        });
    }

    stopAllLocked();
    server_arena.deinit();
    server_arena = new_arena;
    server_list = out.items;
}

/// Kills every server and frees the registry. Safe to call when nothing is
/// running, which is what the exit path relies on.
pub fn shutdown() void {
    lock2();
    defer unlock();
    // `stopAllLocked` frees the map too, so it is NOT deinited again here:
    // `deinit` ends with `self.* = undefined`, and a second one reads
    // undefined memory.
    stopAllLocked();
    cat_arena.deinit();
    cat_arena = .init(std.heap.page_allocator);
    server_arena.deinit();
    server_arena = .init(std.heap.page_allocator);
    server_list = &.{};
    ready = false;
}

/// Kills every running server. The lock is held by the caller.
fn stopAllLocked() void {
    var it = entries.iterator();
    while (it.next()) |e| {
        gpa.free(e.key_ptr.*);
        e.value_ptr.*.client.destroy();
    }
    entries.deinit(gpa);
    entries = .empty;
}

// ── the three operations ──────────────────────────────────────────────────

/// Every server and every tool it publishes, as text.
///
/// The schemas are NOT here: this is the catalogue a model browses, and the
/// schema of a tool arrives with the search that finds it.
pub fn list(arena: std.mem.Allocator, err_out: *ErrText) ![]const u8 {
    lock2();
    defer unlock();
    if (!ready) {
        err_out.set("the MCP manager is not running in this process, so there is no server to ask", .{});
        return error.NotReady;
    }
    if (server_list.len == 0) {
        err_out.set("no MCP server is configured. Add one under `mcp_servers` in ~/.config/zode/config.json", .{});
        return error.NoServers;
    }

    var out: std.ArrayList(u8) = .empty;
    var problems: std.ArrayList(u8) = .empty;
    var started: usize = 0;

    for (server_list) |spec| {
        const e = ensureLocked(spec, err_out) catch {
            try problems.appendSlice(arena, "\n  ");
            try problems.appendSlice(arena, err_out.slice());
            continue;
        };
        started += 1;
        try out.appendSlice(arena, "\n");
        try out.appendSlice(arena, spec.name);
        try out.appendSlice(arena, " (");
        try out.print(arena, "{d}", .{e.tools.len});
        try out.appendSlice(arena, " tools)");
        for (e.tools) |tool_entry| {
            try out.appendSlice(arena, "\n  ");
            try out.appendSlice(arena, tool_entry.name);
            if (tool_entry.description.len > 0) {
                try out.appendSlice(arena, " — ");
                try out.appendSlice(arena, tool_entry.description);
            }
        }
    }

    if (started == 0) {
        // No server answered. The reasons are the answer: "not installed" and
        // "the command is wrong" are two different problems and the model
        // needs to say which one it hit.
        err_out.set("no MCP server could be started:{s}", .{problems.items});
        return error.NoServers;
    }

    if (problems.items.len > 0) {
        try out.appendSlice(arena, "\n\nnot available:");
        try out.appendSlice(arena, problems.items);
    }
    return out.items;
}

/// The tools matching `query`, WITH their schemas.
///
/// This is the deferred loading: the schema of a tool is in the RESULT of the
/// search that found it, and nowhere else. Ten servers with fifty tools each
/// would be half a megabyte of schema in every request if the schemas were in
/// the prompt, and the prompt is the cached prefix.
pub fn searchTools(arena: std.mem.Allocator, query: []const u8, err_out: *ErrText) ![]const u8 {
    lock2();
    defer unlock();
    if (!ready) {
        err_out.set("the MCP manager is not running in this process, so there is no server to ask", .{});
        return error.NotReady;
    }
    if (server_list.len == 0) {
        err_out.set("no MCP server is configured. Add one under `mcp_servers` in ~/.config/zode/config.json", .{});
        return error.NoServers;
    }
    if (query.len == 0) {
        err_out.set("a search needs a query: one or more words that appear in the tool's name or description", .{});
        return error.BadQuery;
    }

    var all: std.ArrayList(search.Entry) = .empty;
    var problems: std.ArrayList(u8) = .empty;
    var started: usize = 0;

    for (server_list) |spec| {
        const e = ensureLocked(spec, err_out) catch {
            try problems.appendSlice(arena, "\n  ");
            try problems.appendSlice(arena, err_out.slice());
            continue;
        };
        started += 1;
        try all.appendSlice(arena, e.tools);
    }

    if (started == 0) {
        err_out.set("no MCP server could be started:{s}", .{problems.items});
        return error.NoServers;
    }

    const hits = try search.search(arena, all.items, query, servers.max_search_results);
    if (hits.len == 0) {
        var msg: std.ArrayList(u8) = .empty;
        try msg.appendSlice(arena, "no tool matches \"");
        try msg.appendSlice(arena, query);
        try msg.appendSlice(arena, "\". The tools that exist are:");
        for (all.items) |tool_entry| {
            try msg.appendSlice(arena, "\n  ");
            try msg.appendSlice(arena, tool_entry.server);
            try msg.appendSlice(arena, ".");
            try msg.appendSlice(arena, tool_entry.name);
        }
        if (problems.items.len > 0) {
            try msg.appendSlice(arena, "\n\nnot searched:");
            try msg.appendSlice(arena, problems.items);
        }
        return msg.items;
    }

    var out: std.ArrayList(u8) = .empty;
    for (hits) |h| {
        try out.appendSlice(arena, "\n");
        try out.appendSlice(arena, h.server);
        try out.appendSlice(arena, ".");
        try out.appendSlice(arena, h.name);
        if (h.description.len > 0) {
            try out.appendSlice(arena, "\n  ");
            try out.appendSlice(arena, h.description);
        }
        try out.appendSlice(arena, "\n  input schema: ");
        try out.appendSlice(arena, h.schema);
    }

    // The count of what was NOT shown is in the answer: a list that is cut
    // without saying so reads as "these are all of them", and the model then
    // searches again with a worse word instead of a better one.
    if (all.items.len > hits.len) {
        try out.print(arena, "\n\n{d} tools matched; {d} are shown. Search again with a different word for the rest.", .{
            all.items.len,
            hits.len,
        });
    }
    if (problems.items.len > 0) {
        try out.appendSlice(arena, "\n\nnot searched:");
        try out.appendSlice(arena, problems.items);
    }
    return out.items;
}

/// Calls one tool of one server.
pub fn callTool(
    arena: std.mem.Allocator,
    server: []const u8,
    tool: []const u8,
    arguments_json: []const u8,
    err_out: *ErrText,
) ![]const u8 {
    lock2();
    defer unlock();
    if (!ready) {
        err_out.set("the MCP manager is not running in this process, so there is no server to call", .{});
        return error.NotReady;
    }
    const spec = findServer(server) orelse {
        err_out.set("there is no MCP server named `{s}`. The configured ones are: {s}", .{ server, namesJoined(arena) });
        return error.UnknownServer;
    };

    const e = ensureLocked(spec, err_out) catch return error.ServerFailed;
    const result = e.client.callTool(arena, tool, arguments_json) catch |err| switch (err) {
        error.ServerError => {
            err_out.set("the MCP server `{s}` refused the call: {s}", .{ spec.name, e.client.last_error.message });
            return error.ServerFailed;
        },
        error.Timeout => {
            err_out.set("the MCP server `{s}` did not answer in time", .{spec.name});
            return error.ServerFailed;
        },
        error.ServerClosed => {
            err_out.set("the MCP server `{s}` closed its pipe (it died or it was killed)", .{spec.name});
            return error.ServerFailed;
        },
        else => {
            err_out.set("the MCP server `{s}` failed: {t}", .{ spec.name, err });
            return error.ServerFailed;
        },
    };

    if (result.text.len == 0) {
        if (result.is_error) return "the tool failed and said nothing about why.";
        return "the tool succeeded and returned no content.";
    }
    if (result.is_error) {
        return std.fmt.allocPrint(arena, "the tool failed: {s}", .{result.text}) catch result.text;
    }
    return result.text;
}

/// The names of the configured servers, comma-separated.
fn namesJoined(arena: std.mem.Allocator) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (server_list, 0..) |s, i| {
        if (i > 0) out.append(arena, ',') catch return "";
        out.appendSlice(arena, s.name) catch return "";
    }
    return out.items;
}

/// The server with that name, or null.
fn findServer(name: []const u8) ?servers.Server {
    for (server_list) |s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

// ── starting a server ─────────────────────────────────────────────────────

/// The running entry of `spec`, starting it if it is not running yet.
///
/// The lock is held across the spawn and the handshake, so two servers cannot
/// be started at the same instant. That is a deliberate simplification: a turn
/// that needs two servers at once is rare, and a half-initialized client
/// published to the map would be worse.
fn ensureLocked(spec: servers.Server, err_out: *ErrText) !Entry {
    if (entries.get(spec.name)) |e| {
        if (!e.client.dead) return e;
        // The server is GONE (its pipe closed). Handing out this client again
        // would answer every question with `ServerClosed`, so it is replaced.
        if (entries.fetchRemove(spec.name)) |kv| gpa.free(kv.key);
        e.client.destroy();
    }

    const transport = process.spawn(gpa, io_g, spec.command, buildEnvLocked(spec)) catch |err| switch (err) {
        error.ServerNotFound => {
            err_out.set("the MCP server `{s}` is not installed (command `{s}` not found in PATH)", .{ spec.name, spec.command[0] });
            return error.ServerNotFound;
        },
        else => {
            err_out.set("could not start the MCP server `{s}`: {t}", .{ spec.name, err });
            return error.SpawnFailed;
        },
    };

    const c = client.Client.create(gpa, io_g, transport) catch |err| {
        transport.close();
        err_out.set("out of memory starting the MCP server `{s}`", .{spec.name});
        return err;
    };
    errdefer c.destroy();

    var handshake_arena = std.heap.ArenaAllocator.init(gpa);
    defer handshake_arena.deinit();
    c.handshake(handshake_arena.allocator()) catch |err| {
        switch (err) {
            error.ServerError => err_out.set("the MCP server `{s}` refused to initialize: {s}", .{ spec.name, c.last_error.message }),
            error.Timeout => err_out.set("the MCP server `{s}` did not answer `initialize` in time", .{spec.name}),
            error.ServerClosed => err_out.set("the MCP server `{s}` closed its pipe before it was ready", .{spec.name}),
            else => err_out.set("the MCP server `{s}` failed during `initialize`: {t}", .{ spec.name, err }),
        }
        return error.HandshakeFailed;
    };

    // The catalogue is built ONCE, when the server starts, and it lives in the
    // catalogue's arena: it has to outlive this call, because a search reads
    // it later.
    const tools = c.listTools(cat_arena.allocator()) catch |err| {
        switch (err) {
            error.ServerError => err_out.set("the MCP server `{s}` refused to list its tools: {s}", .{ spec.name, c.last_error.message }),
            error.Timeout => err_out.set("the MCP server `{s}` did not answer `tools/list` in time", .{spec.name}),
            else => err_out.set("the MCP server `{s}` failed while listing its tools: {t}", .{ spec.name, err }),
        }
        return error.ListFailed;
    };

    const entries_out = cat_arena.allocator().alloc(search.Entry, tools.len) catch {
        err_out.set("out of memory reading the catalogue of `{s}`", .{spec.name});
        return error.OutOfMemory;
    };
    for (entries_out, tools) |*e, tool| {
        e.* = .{
            .server = spec.name,
            .name = tool.name,
            .description = tool.description,
            .schema = tool.schema,
        };
    }

    // The KEY is a copy and not `spec.name`: the name lives in the config's
    // arena, which is freed when the config is reloaded, and a map key that
    // dangles is a use-after-free the next time the map is walked.
    const key = gpa.dupe(u8, spec.name) catch {
        err_out.set("out of memory starting the MCP server `{s}`", .{spec.name});
        return error.OutOfMemory;
    };
    errdefer gpa.free(key);
    try entries.put(gpa, key, .{ .client = c, .tools = entries_out });

    return entries.get(spec.name).?;
}

/// The environment of a server: the process environment plus its own.
///
/// The map REPLACES the child's environment entirely, so the parent's is
/// copied in first: a server that lost `HOME` or `PATH` would fail in ways
/// that have nothing to do with MCP.
///
/// The map is allocated in the catalogue's arena and NOT on the stack: it is
/// handed to the spawn as a pointer, and a pointer to a local is a pointer to
/// a stack frame that is gone when the function returns. (The spawn copies the
/// environment block out of it, so it only has to survive the call — but the
/// CALLER holds the pointer, not the spawn.)
fn buildEnvLocked(spec: servers.Server) ?*const std.process.Environ.Map {
    if (parent_env == null and spec.env.len == 0) return null;
    const a = cat_arena.allocator();
    const map = a.create(std.process.Environ.Map) catch return null;
    map.* = std.process.Environ.Map.init(a);
    if (parent_env) |p| {
        for (p.keys(), p.values()) |k, v| {
            map.put(k, v) catch {};
        }
    }
    for (spec.env) |e| {
        if (!servers.validEnvName(e.name)) continue;
        map.put(e.name, e.value) catch {};
    }
    return map;
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

// ── tests ──────────────────────────────────────────────────────────────────

const t = std.testing;

test "manager: no server configured says so, and names the file to edit" {
    init(t.allocator, std.testing.io, null);
    defer shutdown();

    var err_text: ErrText = .{};
    try t.expectError(error.NoServers, list(t.allocator, &err_text));
    try t.expect(std.mem.indexOf(u8, err_text.slice(), "mcp_servers") != null);
}

test "manager: the user's servers are COPIED, not borrowed" {
    init(t.allocator, std.testing.io, null);
    defer shutdown();

    var name: [8]u8 = undefined;
    @memcpy(name[0..4], "mine");
    const list_in = [_]servers.Server{.{
        .name = name[0..4],
        .command = &.{"my-mcp"},
        .env = &.{.{ .name = "TOKEN", .value = "abc" }},
    }};
    try setServers(&list_in);
    // The caller's buffer goes away...
    @memset(&name, 'x');
    // ...and the manager still has the real name.
    try t.expectEqualStrings("mine", configuredServers()[0].name);
    try t.expectEqualStrings("abc", configuredServers()[0].env[0].value);
}

test "manager: an environment variable with an invalid name is dropped, not an assert" {
    init(t.allocator, std.testing.io, null);
    defer shutdown();

    // `Environ.Map.put` ASSERTS on a name with an `=` in it, and an assert in
    // the user's own configuration is a crash the user cannot do anything
    // about.
    try setServers(&[_]servers.Server{.{
        .name = "s",
        .command = &.{"my-mcp"},
        .env = &.{
            .{ .name = "BAD=NAME", .value = "x" },
            .{ .name = "GOOD", .value = "y" },
        },
    }});
    try t.expectEqual(@as(usize, 1), configuredServers()[0].env.len);
    try t.expectEqualStrings("GOOD", configuredServers()[0].env[0].name);
}

test "manager: an unknown server names the ones that exist" {
    init(t.allocator, std.testing.io, null);
    defer shutdown();

    try setServers(&[_]servers.Server{.{ .name = "github", .command = &.{"gh-mcp"} }});

    // The message is built in the CALLER's arena: the manager does not own it.
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var err_text: ErrText = .{};
    try t.expectError(error.UnknownServer, callTool(a, "nope", "tool", "{}", &err_text));
    try t.expect(std.mem.indexOf(u8, err_text.slice(), "github") != null);
}

test "manager: a server whose binary is missing says the binary is missing" {
    init(t.allocator, std.testing.io, null);
    defer shutdown();

    try setServers(&[_]servers.Server{.{ .name = "ghost", .command = &.{"zode-no-such-mcp-binary"} }});

    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var err_text: ErrText = .{};
    try t.expectError(error.NoServers, list(a, &err_text));
    try t.expect(std.mem.indexOf(u8, err_text.slice(), "not installed") != null);
    try t.expect(std.mem.indexOf(u8, err_text.slice(), "zode-no-such-mcp-binary") != null);
}
