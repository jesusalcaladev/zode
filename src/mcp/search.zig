//! Finding a tool by name, without a schema in the prompt.
//!
//! Pure: the index is a list of entries and the search is a scan. What always
//! breaks in a tool search is not the matching — it is the MATCHING BEING
//! SURPRISING, so the rules are written down and pinned:
//!
//! 1. Every term of the query must appear. A search for "issue list" must not
//!    return a tool called "list_pull_requests" just because it says "list".
//! 2. A tool whose NAME matches scores above one whose DESCRIPTION matches.
//!    The name is what the model remembers; the description is a hint.
//! 3. An exact `server.tool` wins over everything else. It is the model
//!    saying "this one, exactly", and a search that buries it under a
//!    description match is a search the model will run again.
//!
//! The entries carry the tool's schema, and that is the POINT of the whole
//! module: the schema is in the tool RESULT of a search, never in the prompt.
//! Ten servers with fifty tools each would be half a megabyte of schema in
//! every request, and every request's prefix would change whenever a server
//! was added. The schemas come when they are asked for.

const std = @import("std");

/// One tool of one server.
pub const Entry = struct {
    /// The server that publishes it.
    server: []const u8,
    /// The tool's name, as the server spells it.
    name: []const u8,
    /// The one-line description, when the server gave one.
    description: []const u8 = "",
    /// The tool's input schema, as JSON text.
    schema: []const u8 = "{}",
};

/// The name a tool is addressed by: `server.tool`.
///
/// It is the name the model sees, the name the rules match on, and the name
/// the "always allow" list remembers. One spelling for all three, because a
/// permission that remembers a different spelling than the one the model
/// typed is a permission nobody can reason about.
pub fn qualifiedName(arena: std.mem.Allocator, server: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ server, name });
}

/// Splits a qualified name back into its two halves.
///
/// The split is at the FIRST dot, so a tool whose own name has a dot in it
/// (`github.list.issues`) still resolves: the server is `github` and the tool
/// is `list.issues`.
pub fn splitQualified(qualified: []const u8) ?struct { server: []const u8, name: []const u8 } {
    const dot = std.mem.indexOfScalar(u8, qualified, '.') orelse return null;
    if (dot == 0 or dot + 1 >= qualified.len) return null;
    return .{ .server = qualified[0..dot], .name = qualified[dot + 1 ..] };
}

/// The terms of a query: lowercase, split on anything that is not a letter
/// or a digit.
///
/// `createIssue` and `create_issue` and `create issue` are the same words, and
/// a query in any of those spellings has to find the tool.
///
/// The separator set is what makes that true, and it is a SEPARATOR and not a
/// word character: with `_` counted as part of the word, the query
/// `create_issue` was the single term `create_issue`, and the tool called
/// `createIssue` (whose lowercased name is `createissue`) did not contain it.
/// The three spellings of the same query have to be the same TERMS.
fn terms(query: []const u8, out: *std.ArrayList([]const u8), arena: std.mem.Allocator) !void {
    var i: usize = 0;
    while (i < query.len) {
        while (i < query.len and !isWordByte(query[i])) i += 1;
        const start = i;
        while (i < query.len and isWordByte(query[i])) i += 1;
        if (i > start) {
            const word = query[start..i];
            // Lowercasing here means the comparison below never has to think
            // about case, and it is the only place that has to.
            const lower = try arena.alloc(u8, word.len);
            for (word, 0..) |c, k| lower[k] = std.ascii.toLower(c);
            try out.append(arena, lower);
        }
    }
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c);
}

/// The score of one entry against one query. Zero means "does not match".
///
/// The weights are arbitrary and pinned by a test: what matters is that they
/// are ORDERS, and that the order is the one a person would guess.
fn score(candidate: Entry, query: []const u8, query_terms: []const []const u8) u32 {
    var hay_name: std.ArrayList(u8) = .empty;
    defer hay_name.deinit(std.heap.page_allocator);
    for (candidate.name) |c| hay_name.append(std.heap.page_allocator, std.ascii.toLower(c)) catch return 0;
    var hay_desc: std.ArrayList(u8) = .empty;
    defer hay_desc.deinit(std.heap.page_allocator);
    for (candidate.description) |c| hay_desc.append(std.heap.page_allocator, std.ascii.toLower(c)) catch return 0;

    // The exact `server.tool` is the strongest signal there is.
    var qualified_buf: [512]u8 = undefined;
    const qualified = std.fmt.bufPrint(&qualified_buf, "{s}.{s}", .{ candidate.server, candidate.name }) catch "";
    if (qualified.len > 0 and std.ascii.eqlIgnoreCase(qualified, query)) return 1000;

    var total: u32 = 0;
    for (query_terms) |term| {
        const in_name = std.mem.indexOf(u8, hay_name.items, term) != null;
        const in_desc = std.mem.indexOf(u8, hay_desc.items, term) != null;
        if (!in_name and !in_desc) return 0; // every term must appear
        total += if (in_name) 10 else 1;
    }
    if (total == 0) return 0;
    // The whole query inside the name is a stronger signal than the same
    // terms scattered in the description.
    if (query.len > 0 and std.mem.indexOf(u8, hay_name.items, query) != null) total += 25;
    return total;
}

/// The entries matching `query`, best first, at most `max_results` of them.
///
/// The result is allocated in `arena`; the entries themselves are COPIES of the
/// caller's entries, so the caller keeps the ownership of the strings.
pub fn search(
    arena: std.mem.Allocator,
    entries: []const Entry,
    query: []const u8,
    max_results: usize,
) ![]Entry {
    if (query.len == 0) return &.{};

    var query_terms: std.ArrayList([]const u8) = .empty;
    defer query_terms.deinit(arena);
    try terms(query, &query_terms, arena);
    if (query_terms.items.len == 0) return &.{};

    const Scored = struct { entry: Entry, score: u32 };
    var scored: std.ArrayList(Scored) = .empty;
    defer scored.deinit(arena);
    for (entries) |e| {
        const s = score(e, query, query_terms.items);
        if (s == 0) continue;
        try scored.append(arena, .{ .entry = e, .score = s });
    }
    if (scored.items.len == 0) return &.{};

    // Sort by score, then by name, so the order does not depend on the order
    // the servers happened to answer in.
    std.mem.sort(Scored, scored.items, {}, struct {
        fn lessThan(_: void, a: Scored, b: Scored) bool {
            if (a.score != b.score) return a.score > b.score;
            return std.mem.lessThan(u8, a.entry.name, b.entry.name);
        }
    }.lessThan);

    const n = @min(max_results, scored.items.len);
    const out = try arena.alloc(Entry, n);
    for (out, 0..) |*e, i| e.* = scored.items[i].entry;
    return out;
}

// ── tests ────────────────────────────────────────────────────────────────

const t = std.testing;

fn entry(server: []const u8, name: []const u8, description: []const u8) Entry {
    return .{ .server = server, .name = name, .description = description };
}

test "a search finds a tool by name" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const entries = [_]Entry{
        entry("github", "create_issue", "Create an issue on a repository"),
        entry("github", "list_pull_requests", "List pull requests"),
    };
    const hits = try search(a, &entries, "create_issue", 5);
    try t.expectEqual(@as(usize, 1), hits.len);
    try t.expectEqualStrings("create_issue", hits[0].name);
}

test "every term of the query must appear" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const entries = [_]Entry{
        entry("github", "list_issues", "List issues in a repository"),
        entry("github", "list_pull_requests", "List pull requests"),
    };
    // "issue list" must not match "list_pull_requests": it says "list", and the
    // description does not say "issue".
    const hits = try search(a, &entries, "issue list", 5);
    try t.expectEqual(@as(usize, 1), hits.len);
    try t.expectEqualStrings("list_issues", hits[0].name);
}

test "a name match outranks a description match" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const entries = [_]Entry{
        entry("a", "other", "mentions issue in the description"),
        entry("b", "issue", "no mention of the word in here"),
    };
    const hits = try search(a, &entries, "issue", 5);
    try t.expectEqual(@as(usize, 2), hits.len);
    try t.expectEqualStrings("issue", hits[0].name);
}

test "the exact server.tool wins" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const entries = [_]Entry{
        entry("github", "issue", "a tool about issues"),
        entry("github", "repo", "the repository itself"),
    };
    const hits = try search(a, &entries, "github.repo", 5);
    try t.expectEqual(@as(usize, 1), hits.len);
    try t.expectEqualStrings("repo", hits[0].name);
}

test "the result is capped, and the best ones are the ones kept" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var entries: [10]Entry = undefined;
    for (&entries, 0..) |*e, i| {
        e.* = entry("s", std.fmt.allocPrint(a, "tool{d}", .{i}) catch unreachable, "shared word");
    }
    const hits = try search(a, &entries, "shared", 3);
    try t.expectEqual(@as(usize, 3), hits.len);
}

test "an empty query matches nothing, and a query of punctuation matches nothing" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const entries = [_]Entry{entry("s", "tool", "a tool")};
    try t.expectEqual(@as(usize, 0), (try search(a, &entries, "", 5)).len);
    try t.expectEqual(@as(usize, 0), (try search(a, &entries, "  ... ", 5)).len);
}

test "the query's spelling does not matter: camelCase, snake_case and spaces are the same words" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const entries = [_]Entry{entry("s", "createIssue", "Create an issue")};
    try t.expectEqual(@as(usize, 1), (try search(a, &entries, "create_issue", 5)).len);
    try t.expectEqual(@as(usize, 1), (try search(a, &entries, "create issue", 5)).len);
    try t.expectEqual(@as(usize, 1), (try search(a, &entries, "CREATEISSUE", 5)).len);
}

test "a qualified name is one string, and it splits back into its two halves" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const q = try qualifiedName(a, "github", "create_issue");
    try t.expectEqualStrings("github.create_issue", q);

    const parts = splitQualified(q).?;
    try t.expectEqualStrings("github", parts.server);
    try t.expectEqualStrings("create_issue", parts.name);

    // A tool whose own name has a dot in it still splits at the FIRST one.
    const dotted = splitQualified("github.list.issues").?;
    try t.expectEqualStrings("github", dotted.server);
    try t.expectEqualStrings("list.issues", dotted.name);

    try t.expect(splitQualified("nodots") == null);
    try t.expect(splitQualified(".leading") == null);
    try t.expect(splitQualified("trailing.") == null);
}
