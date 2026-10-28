//! Agent definitions on disk: `.zode/agents/*.md` (project) and
//! `~/.config/zode/agents/*.md` (user), with frontmatter `name`, `description`,
//! `tools`, `model`, `effort`.
//!
//! Pure on purpose: discovery, parsing and validation are testable without
//! touching the real filesystem beyond reading the fixture files the tests
//! provide.

const std = @import("std");
const subagent = @import("subagent.zig");

/// One agent definition's frontmatter.
pub const Meta = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    /// Comma-separated tool names the definition allows. Must be read-only.
    tools: []const u8 = "",
    model: []const u8 = "",
    effort: []const u8 = "",
};

/// One discovered agent definition.
pub const Entry = struct {
    name: []const u8,
    description: []const u8,
    tools: [][]const u8,
    model: []const u8,
    effort: []const u8,
    path: []const u8,
    /// "project" for `.zode/agents/`, "user" for `~/.config/zode/agents/`.
    source: []const u8,
};

/// Directories, in shadowing order: project first, user second.
pub const project_dir = ".zode/agents";
pub const user_subdir = "zode/agents";

/// Splits the frontmatter from the body.
///
/// `null` when there is no frontmatter, which is legal: a definition can be
/// just a markdown file. Returns slices into `text`.
///
/// The parser is hand-written and DELIBERATELY narrow: `key: value` lines, one
/// `---`-fenced block at the top, `#` comments inside it. It does not do YAML.
pub fn splitFrontmatter(text: []const u8) ?struct { meta: Meta, body: []const u8 } {
    const trimmed = std.mem.trimStart(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "---")) return null;
    const after = trimmed[3..];
    if (after.len > 0 and after[0] != '\n' and after[0] != '\r') return null;

    var rest = after;
    if (std.mem.startsWith(u8, rest, "\r\n")) rest = rest[2..] else if (rest.len > 0 and rest[0] == '\n') rest = rest[1..];

    var meta = Meta{};
    var i: usize = 0;
    while (i < rest.len) {
        const nl = std.mem.indexOfScalar(u8, rest[i..], '\n') orelse rest.len - i;
        const line = rest[i .. i + nl];
        i = @min(i + nl + 1, rest.len);
        const t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, t, "---")) {
            return .{ .meta = meta, .body = std.mem.trimStart(u8, rest[i..], " \t\r\n") };
        }
        if (t.len == 0 or t[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, t, ':') orelse continue;
        const key = std.mem.trim(u8, t[0..colon], " \t");
        var val = std.mem.trim(u8, t[colon + 1 ..], " \t");
        if (val.len >= 2 and ((val[0] == '"' and val[val.len - 1] == '"') or
            (val[0] == '\'' and val[val.len - 1] == '\'')))
        {
            val = val[1 .. val.len - 1];
        }
        if (std.mem.eql(u8, key, "name")) {
            meta.name = val;
        } else if (std.mem.eql(u8, key, "description")) {
            meta.description = val;
        } else if (std.mem.eql(u8, key, "tools")) {
            meta.tools = val;
        } else if (std.mem.eql(u8, key, "model")) {
            meta.model = val;
        } else if (std.mem.eql(u8, key, "effort")) {
            meta.effort = val;
        }
    }
    return null; // unterminated frontmatter
}

/// Parses the comma-separated `tools` field into an array of tool names.
///
/// Empty input yields an empty array. Whitespace around names is trimmed.
pub fn parseTools(tools: []const u8, arena: std.mem.Allocator) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= tools.len) {
        if (i == tools.len or tools[i] == ',') {
            const item = std.mem.trim(u8, tools[start..i], " \t");
            if (item.len > 0) {
                const dup = try arena.dupe(u8, item);
                try list.append(arena, dup);
            }
            start = i + 1;
        }
        i += 1;
    }
    return list.toOwnedSlice(arena);
}

/// True when every tool in `tools` is in the subagent's read-only set.
///
/// A definition cannot escalate: `write`, `edit`, `bash` and anything outside
/// `subagent.tool_names` makes this false.
pub fn toolsAreReadOnly(tools: [][]const u8) bool {
    for (tools) |t| {
        if (!subagent.allowsTool(t)) return false;
    }
    return true;
}

/// Looks up a definition by name. Returns null when unknown.
pub fn find(entries: []const Entry, name: []const u8) ?Entry {
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

/// Effort clamp: a definition's effort is clamped to the model's ladder.
/// `low` is always safe; anything higher is passed through (the caller's
/// `effectiveEffort` clamps it to what the model supports).
pub fn effortFor(definition_effort: []const u8, default_effort: []const u8) []const u8 {
    if (definition_effort.len == 0) return default_effort;
    return definition_effort;
}

// ── tests ─────────────────────────────────────────────────────

test "agentdefs: splitFrontmatter parses all five keys" {
    const text = "---\nname: explore\ndescription: Broad search\ntools: read,grep,glob\nmodel: kimi-k2.6\neffort: low\n---\n# Body\nhere";
    const r = splitFrontmatter(text) orelse return error.NoFrontmatter;
    try std.testing.expectEqualStrings("explore", r.meta.name);
    try std.testing.expectEqualStrings("Broad search", r.meta.description);
    try std.testing.expectEqualStrings("read,grep,glob", r.meta.tools);
    try std.testing.expectEqualStrings("kimi-k2.6", r.meta.model);
    try std.testing.expectEqualStrings("low", r.meta.effort);
    try std.testing.expect(std.mem.eql(u8, r.body, "# Body\nhere"));
}

test "agentdefs: splitFrontmatter returns null without frontmatter" {
    try std.testing.expect(splitFrontmatter("just a markdown file") == null);
}

test "agentdefs: parseTools splits comma-separated names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tools = try parseTools("read, grep , glob", arena);
    try std.testing.expectEqual(3, tools.len);
    try std.testing.expectEqualStrings("read", tools[0]);
    try std.testing.expectEqualStrings("grep", tools[1]);
    try std.testing.expectEqualStrings("glob", tools[2]);
}

test "agentdefs: parseTools empty yields empty array" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tools = try parseTools("", arena);
    try std.testing.expectEqual(0, tools.len);
}

test "agentdefs: toolsAreReadOnly accepts read-only tools" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tools = try parseTools("read,grep,glob,list_files,web_fetch,web_search,lsp", arena);
    try std.testing.expect(toolsAreReadOnly(tools));
}

test "agentdefs: toolsAreReadOnly rejects write tools" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tools = try parseTools("read,write", arena);
    try std.testing.expect(!toolsAreReadOnly(tools));
}

test "agentdefs: toolsAreReadOnly rejects unknown tools" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tools = try parseTools("read,nothing_tool", arena);
    try std.testing.expect(!toolsAreReadOnly(tools));
}

test "agentdefs: find returns the matching entry" {
    const entries = [_]Entry{
        .{ .name = "explore", .description = "", .tools = &[_][]const u8{}, .model = "", .effort = "", .path = "", .source = "project" },
        .{ .name = "plan", .description = "", .tools = &[_][]const u8{}, .model = "", .effort = "", .path = "", .source = "user" },
    };
    try std.testing.expect(find(&entries, "explore") != null);
    try std.testing.expect(find(&entries, "plan") != null);
    try std.testing.expect(find(&entries, "unknown") == null);
}

test "agentdefs: effortFor returns default when definition has none" {
    try std.testing.expect(std.mem.eql(u8, effortFor("", "low"), "low"));
    try std.testing.expect(std.mem.eql(u8, effortFor("medium", "low"), "medium"));
}