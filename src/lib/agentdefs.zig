//! Agent definitions on disk (Phase 9, complete).
//!
//! TWO layouts are supported, both discovered by `discovery.zig`:
//!
//!   .zode/agents/<name>/AGENT.md      (directory, allows extra files beside it)
//!   .zode/agents/<name>.md            (flat file, the common case)
//!
//! and the same under `~/.config/zode/agents/`. Project shadows user by name;
//! a flat file and a directory with the same name are ONE definition (the
//! directory wins). Frontmatter keys: `name`, `description`, `tools`, `model`,
//! `effort`. Only read-only tools are allowed — a definition cannot escalate.
//!
//! Pure on purpose: every function here is testable without the TUI, without
//! IO and without a network. Discovery (the part that touches the filesystem)
//! lives in `src/agent/discovery.zig`.

const std = @import("std");
const frontmatter = @import("frontmatter.zig");
const subagent = @import("subagent.zig");

/// A definition name is a stable routing key (used by `task(definition=…)` and
/// by permission rules), so it is deliberately narrow.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!ok) return false;
    }
    return true;
}

/// Template written by "New agent" in the Settings screen. Kept here (pure)
/// so the shape of a definition has one source of truth.
pub fn template(name: []const u8) ![]u8 {
    if (!validName(name)) return error.InvalidName;
    return std.fmt.allocPrint(
        std.heap.page_allocator,
        "---\nname: {s}\ndescription: What this agent does, in one line\ntools: read,grep,glob,list_files\nmodel: \neffort: low\n---\n\n# {s}\n\nDescribe the job this agent does. It is read-only by default; add tools only\nif they are in the read-only subagent set.\n",
        .{ name, name },
    );
}

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
    const parsed = frontmatter.split(text) orelse return null;
    if (!parsed.closed) return null;
    var meta = Meta{};
    var it = parsed.iterator;
    while (it.next()) |kv| {
        if (std.mem.eql(u8, kv.key, "name")) {
            meta.name = kv.value;
        } else if (std.mem.eql(u8, kv.key, "description")) {
            meta.description = kv.value;
        } else if (std.mem.eql(u8, kv.key, "tools")) {
            meta.tools = kv.value;
        } else if (std.mem.eql(u8, kv.key, "model")) {
            meta.model = kv.value;
        } else if (std.mem.eql(u8, kv.key, "effort")) {
            meta.effort = kv.value;
        }
    }
    return .{ .meta = meta, .body = parsed.body };
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

/// `<name>.md` → `name`, or null for a file that is not a definition (a
/// README, a dotfile, a stray note). Mirrors the output-styles discovery rule.
pub fn flatStem(file_name: []const u8) ?[]const u8 {
    const ext = ".md";
    if (!std.mem.endsWith(u8, file_name, ext)) return null;
    const stem = file_name[0 .. file_name.len - ext.len];
    if (!validName(stem)) return null;
    return stem;
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
test "agentdefs: validName rejects routing-unsafe names" {
    try std.testing.expect(validName("explore"));
    try std.testing.expect(validName("my-agent_2"));
    try std.testing.expect(!validName(""));
    try std.testing.expect(!validName("Has Space"));
    try std.testing.expect(!validName("../evil"));
    try std.testing.expect(!validName("dot.name"));
}

test "agentdefs: template is valid and names the agent" {
    const t = try template("reviewer");
    defer std.heap.page_allocator.free(t);
    const r = splitFrontmatter(t) orelse return error.NoFrontmatter;
    try std.testing.expectEqualStrings("reviewer", r.meta.name);
    try std.testing.expectEqualStrings("low", r.meta.effort);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "read-only") != null);
    try std.testing.expectError(error.InvalidName, template("bad name"));
}

test "agentdefs: flatStem recognises definition files only" {
    try std.testing.expectEqualStrings("explore", flatStem("explore.md").?);
    try std.testing.expect(flatStem("README.md") == null); // upper case is not a valid name
    try std.testing.expect(flatStem("notes.txt") == null);
    try std.testing.expect(flatStem("with space.md") == null);
}
