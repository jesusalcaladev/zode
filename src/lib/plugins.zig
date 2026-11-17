//! Plugins and the bundled marketplace (Phase 13.1). Pure layer: manifest
//! parsing/validation, catalog search and prompt rendering. Discovery and file
//! IO live in the `plugin` tool; the rules here are testable without a disk.
//!
//! A plugin is an on-disk JSON manifest under `.zode/plugins/<name>/plugin.json`
//! (project) or `~/.config/zode/plugins/<name>/plugin.json` (user). It is
//! DECLARATIVE: it contributes an instruction block to the system prompt and
//! declares a tool allowlist hint. It never executes code — that keeps the
//! marketplace safe to install and cheap to load. Project shadows user by name.

const std = @import("std");
const textcase = @import("textcase.zig");

pub const Manifest = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    version: []const u8 = "1.0.0",
    /// Text appended to the system prompt when the plugin is enabled.
    instructions: []const u8 = "",
    /// Tool names the plugin says it needs (a hint for routing, not a grant).
    tools: []const []const u8 = &.{},
    enabled: bool = true,
};

pub const CatalogEntry = struct {
    name: []const u8,
    description: []const u8,
    version: []const u8,
    instructions: []const u8,
    tools: []const []const u8 = &.{},
};

/// The bundled marketplace. Small, real, declarative instruction bundles —
/// installing one copies its manifest into the project, no network required.
pub const catalog = [_]CatalogEntry{
    .{
        .name = "zig-idioms",
        .description = "Zig 0.17 idioms: explicit allocators, error unions, no C deps",
        .version = "1.0.0",
        .instructions = "When writing Zig, use explicit allocators, prefer error unions over exceptions, and never add a C dependency. Keep modules pure and testable.",
        .tools = &.{"bash"},
    },
    .{
        .name = "review-checklist",
        .description = "Structured code review with severity lines and evidence",
        .version = "1.0.0",
        .instructions = "When reviewing code, report findings as SEVERITY: high|medium|low with a file:line and the concrete risk. Never invent a result you did not check.",
        .tools = &.{ "read", "grep", "bash" },
    },
    .{
        .name = "commit-hygiene",
        .description = "Conventional commits and small, test-backed changes",
        .version = "1.0.0",
        .instructions = "Write conventional commit messages (feat|fix|docs|test|refactor|chore). Keep each change small and back it with a passing test.",
        .tools = &.{ "bash", "read" },
    },
    .{
        .name = "test-first",
        .description = "Add a failing test before implementing a behavior",
        .version = "1.0.0",
        .instructions = "For every new behavior, write a test that fails first, then implement until it passes. Name tests for the behavior they pin.",
        .tools = &.{ "read", "bash" },
    },
};

pub fn findInCatalog(name: []const u8) ?CatalogEntry {
    for (catalog) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

/// Case-insensitive substring search over name + description. Returns indices
/// into `catalog`. An empty query matches everything (the catalog is tiny).
pub fn search(gpa: std.mem.Allocator, query: []const u8) ![]usize {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(gpa);
    var needle_buf: [128]u8 = undefined;
    if (query.len > needle_buf.len) return try out.toOwnedSlice(gpa);
    for (query, 0..) |c, i| needle_buf[i] = std.ascii.toLower(c);
    const needle = needle_buf[0..query.len];
    for (catalog, 0..) |entry, i| {
        if (needle.len == 0 or containsIgnoreCase(entry.name, needle) or containsIgnoreCase(entry.description, needle)) {
            try out.append(gpa, i);
        }
    }
    return try out.toOwnedSlice(gpa);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return textcase.contains(haystack, needle);
}

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-')) return false;
    }
    return name[0] != '-' and name[name.len - 1] != '-';
}

/// Parse a plugin manifest from JSON. Unknown fields are ignored, so a newer
/// manifest still loads. Missing required fields are a named error.
pub fn parse(gpa: std.mem.Allocator, json: []const u8) !Manifest {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, gpa, json, .{});
    if (parsed != .object) return error.NotAPlugin;
    const obj = parsed.object;
    var m: Manifest = .{};
    if (obj.get("name")) |v| {
        if (v != .string) return error.BadName;
        m.name = v.string;
    }
    if (obj.get("description")) |v| {
        if (v != .string) return error.BadDescription;
        m.description = v.string;
    }
    if (obj.get("version")) |v| {
        if (v == .string) m.version = v.string;
    }
    if (obj.get("instructions")) |v| {
        if (v == .string) m.instructions = v.string;
    }
    if (obj.get("enabled")) |v| {
        if (v == .bool) m.enabled = v.bool;
    }
    if (obj.get("tools")) |v| {
        if (v == .array) {
            var tools = std.ArrayList([]const u8).empty;
            for (v.array.items) |item| {
                if (item == .string) try tools.append(gpa, item.string);
            }
            m.tools = try tools.toOwnedSlice(gpa);
        }
    }
    try validate(m);
    return m;
}

pub fn validate(m: Manifest) !void {
    if (!validName(m.name)) return error.BadName;
    if (m.description.len == 0) return error.BadDescription;
    if (m.instructions.len > 16 * 1024) return error.InstructionsTooLarge;
}

/// Render the enabled plugins' instruction block for the system prompt,
/// capped at `cap` bytes total. Returns an empty slice when none are enabled.
pub fn renderPromptSection(gpa: std.mem.Allocator, manifests: []const Manifest, cap: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var used: usize = 0;
    for (manifests) |m| {
        if (!m.enabled or m.instructions.len == 0) continue;
        const header = std.fmt.allocPrint(gpa, "\n## Plugin: {s}\n{s}\n", .{ m.name, m.instructions }) catch continue;
        defer gpa.free(header);
        if (used + header.len > cap) break;
        try out.appendSlice(gpa, header);
        used += header.len;
    }
    return try out.toOwnedSlice(gpa);
}

/// Serialize a catalog entry into a manifest file body.
pub fn catalogManifest(gpa: std.mem.Allocator, entry: CatalogEntry) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{\n");
    try out.print(gpa, "  \"name\": \"{s}\",\n  \"description\": \"{s}\",\n  \"version\": \"{s}\",\n  \"instructions\": \"{s}\",\n  \"enabled\": true\n", .{
        entry.name, entry.description, entry.version, entry.instructions,
    });
    try out.appendSlice(gpa, "\n}\n");
    return try out.toOwnedSlice(gpa);
}

test "plugins: catalog lookup and case-insensitive search" {
    try std.testing.expect(findInCatalog("zig-idioms") != null);
    try std.testing.expect(findInCatalog("nope") == null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const all = try search(a, "");
    try std.testing.expectEqual(catalog.len, all.len);
    const zig = try search(a, "ZIG");
    try std.testing.expectEqual(@as(usize, 1), zig.len);
    try std.testing.expectEqualStrings("zig-idioms", catalog[zig[0]].name);
}

test "plugins: parse and validate a manifest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try parse(a,
        \\{"name":"demo","description":"A demo plugin","instructions":"Be brief.","tools":["read"],"extra":1}
    );
    try std.testing.expectEqualStrings("demo", m.name);
    try std.testing.expectEqual(@as(usize, 1), m.tools.len);
    try std.testing.expect(validName("a-good-name"));
    try std.testing.expect(!validName("Bad Name"));
    try std.testing.expectError(error.BadName, parse(a, "{\"name\":\"Bad Name\",\"description\":\"x\"}"));
    try std.testing.expectError(error.BadDescription, parse(a, "{\"name\":\"ok\"}"));
}

test "plugins: prompt section respects enabled and cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const manifests = [_]Manifest{
        .{ .name = "one", .description = "d", .instructions = "FIRST" },
        .{ .name = "two", .description = "d", .instructions = "SECOND", .enabled = false },
    };
    const section = try renderPromptSection(a, &manifests, 4096);
    try std.testing.expect(std.mem.indexOf(u8, section, "FIRST") != null);
    try std.testing.expect(std.mem.indexOf(u8, section, "SECOND") == null);
    const tiny = try renderPromptSection(a, &manifests, 4);
    try std.testing.expectEqual(@as(usize, 0), tiny.len);
}
