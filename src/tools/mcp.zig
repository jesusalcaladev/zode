//! The `mcp` tool: reach a capability that no built-in tool has, through a
//! server the USER configured.
//!
//! ## Why one tool and not one tool per MCP tool
//!
//! The request's `tools` array is the biggest stable prefix of every request,
//! and the provider's cache is indexed by its LITERAL BYTES. Ten servers with
//! fifty tools each would be half a megabyte of schema in every request, and
//! adding a server would rewrite the prefix of every request of every session:
//! the cache would never hit again. The same argument is the reason the tool
//! list of the reference implementation is searched and not injected.
//!
//! So the schemas live in the manager's catalogue and come back with the
//! result of a `search`. The model is told about a tool when it asks for it,
//! and the prompt stays the size it was.
//!
//! ## The three operations
//!
//! - `list`: every server and every tool it publishes, WITHOUT the schemas.
//!   It is the map of the territory, and it is cheap enough to be worth a
//!   call.
//! - `search`: the tools that match some words, WITH their schemas. This is
//!   the deferred loading: the schema arrives here and nowhere else.
//! - `call`: one tool, with its arguments.
//!
//! ## Permission
//!
//! `list` and `search` ask for nothing: they read the user's own
//! configuration and change nothing. A `call` DOES ask, and the question is
//! about the qualified name (`github.create_issue`), not about `mcp`: the
//! answer the user gives is about that tool, and the rule it learns is about
//! that tool.

const std = @import("std");
const common = @import("common.zig");
const manager = @import("../mcp/manager.zig");
const search_mod = @import("../mcp/search.zig");

/// The tool's text for a failure.
///
/// The manager's message is COPIED into the arena: it lives in a buffer that
/// belongs to this frame, and a tool result that points at a stack frame is a
/// result the renderer reads after the frame is gone.
fn fail(arena: std.mem.Allocator, err: *const manager.ErrText) []const u8 {
    if (err.slice().len == 0) return "the MCP call failed and said nothing about why.";
    return std.fmt.allocPrint(arena, "{s}", .{err.slice()}) catch "the MCP call failed and said nothing about why.";
}

pub fn toolMcp(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    _ = io;
    const op = common.getStr(obj, "operation") orelse
        return "the `mcp` call needs an `operation`: search, list or call.";

    if (std.ascii.eqlIgnoreCase(op, "list")) {
        var err: manager.ErrText = .{};
        return manager.list(arena, &err) catch fail(arena, &err);
    }

    if (std.ascii.eqlIgnoreCase(op, "search")) {
        const query = common.getStr(obj, "query") orelse
            return "a `search` needs a `query`: one or more words that appear in a tool's name or description.";
        if (query.len == 0) {
            return "the `query` was empty. Give one or more words that appear in a tool's name or description.";
        }
        var err: manager.ErrText = .{};
        return manager.searchTools(arena, query, &err) catch fail(arena, &err);
    }

    if (std.ascii.eqlIgnoreCase(op, "call")) {
        const qualified = qualifiedOf(obj, arena) orelse
            return "a `call` needs a `tool`, and a `server` too unless the tool is named server.tool.";
        const parts = search_mod.splitQualified(qualified).?;
        const args_json = argumentsJson(obj, arena);
        var err: manager.ErrText = .{};
        return manager.callTool(arena, parts.server, parts.name, args_json, &err) catch fail(arena, &err);
    }

    return std.fmt.allocPrint(arena, "unknown `operation` \"{s}\". Use search, list or call.", .{op});
}

/// The qualified name of the tool a `call` is about, or null.
///
/// It is the SAME name the model sees, the name the permission rules match on
/// and the name the "always allow" list remembers. One spelling for all
/// three: a permission that remembers a different spelling than the one the
/// model typed is a permission nobody can reason about.
pub fn qualifiedOf(obj: std.json.ObjectMap, arena: std.mem.Allocator) ?[]const u8 {
    const op = common.getStr(obj, "operation") orelse return null;
    if (!std.ascii.eqlIgnoreCase(op, "call")) return null;
    const tool = common.getStr(obj, "tool") orelse return null;
    if (tool.len == 0) return null;

    if (common.getStr(obj, "server")) |server| {
        if (server.len == 0) return null;
        // An allocation that fails leaves the call with NO subject, and a call
        // with no subject asks for permission: the direction that is safe to be
        // wrong in.
        return search_mod.qualifiedName(arena, server, tool) catch null;
    }
    // No server: the tool is named `server.tool` already.
    const parts = search_mod.splitQualified(tool) orelse return null;
    return search_mod.qualifiedName(arena, parts.server, parts.name) catch null;
}

/// The arguments of a `call`, as JSON text.
///
/// An absent `arguments` is an empty object and not an error: a tool with no
/// parameters is a tool called with `{}`.
fn argumentsJson(obj: std.json.ObjectMap, arena: std.mem.Allocator) []const u8 {
    const v = obj.get("arguments") orelse return "{}";
    if (v == .null) return "{}";
    return std.json.Stringify.valueAlloc(arena, v, .{}) catch "{}";
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn parseObj(arena: std.mem.Allocator, json: []const u8) !std.json.ObjectMap {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    if (v != .object) return error.NotAnObject;
    return v.object;
}

test "mcp: a missing operation says which ones exist" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const out = try toolMcp(testing.io, try parseObj(a, "{}"), a);
    try testing.expect(std.mem.indexOf(u8, out, "needs an `operation`") != null);
    try testing.expect(std.mem.indexOf(u8, out, "search") != null);
}

test "mcp: an unknown operation lists the vocabulary" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const out = try toolMcp(testing.io, try parseObj(a, "{\"operation\":\"lookup\"}"), a);
    try testing.expect(std.mem.indexOf(u8, out, "unknown `operation` \"lookup\"") != null);
}

test "mcp: a search without a query says what a query is" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const out = try toolMcp(testing.io, try parseObj(a, "{\"operation\":\"search\"}"), a);
    try testing.expect(std.mem.indexOf(u8, out, "needs a `query`") != null);
}

test "mcp: the qualified name is server.tool, whichever way it is spelled" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // The server and the tool in two fields.
    const two = (qualifiedOf(try parseObj(a, "{\"operation\":\"call\",\"server\":\"github\",\"tool\":\"create_issue\"}"), a) orelse unreachable);
    try testing.expectEqualStrings("github.create_issue", two);

    // The tool already qualified.
    const one = (qualifiedOf(try parseObj(a, "{\"operation\":\"call\",\"tool\":\"github.create_issue\"}"), a) orelse unreachable);
    try testing.expectEqualStrings("github.create_issue", one);

    // A tool whose own name has a dot: the split is at the FIRST one.
    const dotted = (qualifiedOf(try parseObj(a, "{\"operation\":\"call\",\"tool\":\"github.list.issues\"}"), a) orelse unreachable);
    try testing.expectEqualStrings("github.list.issues", dotted);

    // Not a call: there is no qualified name.
    try testing.expect((qualifiedOf(try parseObj(a, "{\"operation\":\"search\",\"query\":\"x\"}"), a)) == null);
    // A call with no tool: there is no qualified name either.
    try testing.expect((qualifiedOf(try parseObj(a, "{\"operation\":\"call\",\"server\":\"github\"}"), a)) == null);
    // A tool with no dot and no server: it is not a qualified name.
    try testing.expect((qualifiedOf(try parseObj(a, "{\"operation\":\"call\",\"tool\":\"create_issue\"}"), a)) == null);
}

test "mcp: the arguments of a call are JSON, and an absent one is an empty object" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const none = argumentsJson(try parseObj(a, "{\"operation\":\"call\"}"), a);
    try testing.expectEqualStrings("{}", none);

    const some = argumentsJson(try parseObj(a, "{\"operation\":\"call\",\"arguments\":{\"title\":\"hi\",\"n\":2}}"), a);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, some, .{});
    try testing.expect(v == .object);
    try testing.expectEqualStrings("hi", v.object.get("title").?.string);
}
