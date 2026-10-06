/// Where a patch looked for text that is not there.
///
/// ## Why this exists at all
///
/// When `edit` did not find `old_string` it answered "not found in <path>" and
/// stopped. The model's only way forward was to `read` the file again and look for
/// the difference itself — which costs an ENTIRE iteration, on a turn whose budget is
/// 12. And a failed edit is the most common recoverable failure in a code agent: the
/// model misremembered whitespace, or wrote the patch against the file as it was
/// before its own previous edit.
///
/// So the cost of one mistake was two iterations, one of them spent being told what it
/// already could have been told. Measuring the fix is not possible without a model
/// with quota, so what is pinned here is the part that IS checkable: that the error
/// always comes back with something the model can act on immediately, and never with
/// nothing at all.
///
/// ## The three shapes of "you were nearly right"
///
/// A patch that fails is nearly always one of:
///
///   1. **RIGHT TEXT, WRONG PLACE.** The `old_string` is a line from further down. The
///      single most useful thing to return is the real line, with its number.
///   2. **RIGHT TEXT, WRONG WHITESPACE.** An indent of 4 where the file has a tab, or
///      a trailing space. Invisible to the model because it wrote the patch from
///      memory. Diffing against the nearest region shows it immediately.
///   3. **RIGHT TEXT, NEVER EXISTED.** The model invented it. Nothing to offer, and the
///      message has to say so plainly rather than implying the file is close.
const std = @import("std");

pub const max_snippet: usize = 900;
/// How many lines of context around the best guess.
const context_lines: usize = 4;

pub const Hint = struct {
    /// 1-based line number of the best matching line, or null when nothing came close.
    line: ?usize = null,
    /// `line-N ─ text` lines around the best match.
    text: []const u8,
    /// The patch's text IS in the file, so the failure is about its surroundings.
    verbatim: bool = false,
    /// True when a line looks like the one asked for apart from whitespace.
    whitespace_only: bool = false,
};

/// The best hint for `old_string` inside `file`, or a Hint with no `line` when
/// nothing is close enough to be worth showing.
///
/// Written against BYTES and then trimmed to whole lines, because the editor works in
/// graphemes and a slice in the middle of one is not a line anybody can read. Cutting
/// to the next `\n` keeps the offset valid for the numbering.
pub fn hintFor(arena: std.mem.Allocator, file: []const u8, old_string: []const u8) !Hint {
    const original = firstMeaningfulLine(old_string);
    const probe = std.mem.trim(u8, original, " \t\r");

    // Nothing to search for: a patch made only of blank lines, or empty.
    if (probe.len < 4) return .{ .text = "" };

    var best: Best = .{};
    var it = std.mem.splitScalar(u8, file, '\n');
    var line_no: usize = 0;
    while (it.next()) |line| {
        line_no += 1;
        const score = similarity(std.mem.trimEnd(u8, line, "\r"), probe);
        if (score > best.score) {
            best = .{ .score = score, .line = line_no, .offset = offsetOfLine(file, line_no) };
        }
    }
    if (best.offset == null) return .{ .text = "" };
    // 0.50 over whitespace tokens: above that the line really is the one, and below it
    // we are guessing. Showing an UNRELATED region is worse than saying nothing,
    // because the model then believes the patch was nearly right and patches against
    // the wrong place — which costs another failed edit and another iteration.
    if (best.score < 0.50) return .{ .text = "" };

    const from = best.line.? -| context_lines;
    const to = best.line.? + context_lines;
    // VERBATIM is the load-bearing distinction and it has to come before the spacing
    // case. A patch written from memory normally carries the wrong INDENT, so the two
    // failures look alike at the token level; what separates them is whether the text as
    // written is in the file at all. A trim that equals a trim is not evidence of
    // anything — it is true of every line.
    const verbatim = std.mem.indexOf(u8, file, original) != null;
    return .{
        .line = best.line,
        .text = try window(arena, file, from, to),
        .verbatim = verbatim,
        .whitespace_only = !verbatim and std.mem.eql(u8, tokensOf(lineAt(file, best.line.?)), tokensOf(probe)),
    };
}

/// The line of `old_string` most worth looking for: the longest one.
///
/// It keeps its LEADING whitespace on purpose, because that is the whole point of the
/// verbatim/spacing distinction below. A tab-indented line CONTAINS the trimmed version
/// of a patch that indented it with four spaces, so "is the trimmed text in the file"
/// answers yes for both failures and cannot tell them apart. Comparing the line AS SENT
/// — indent included — is what separates "wrong place" from "wrong spaces".
///
/// Not the FIRST line either: `old_string` is usually several lines and the longest one
/// is the one that identifies it.
fn firstMeaningfulLine(old_string: []const u8) []const u8 {
    var best: []const u8 = "";
    var it = std.mem.splitScalar(u8, old_string, '\n');
    while (it.next()) |line| {
        const t = std.mem.trimEnd(u8, line, " \t\r");
        if (t.len > best.len) best = t;
    }
    return best;
}

/// Jaccard over WHITESPACE-separated tokens.
///
/// Not characters: character overlap rewards a line of the right LENGTH and not the
/// right content, which is the commonest false positive here — `}`, `});` and `});`
/// score 1.0 against each other.
///
/// Not punctuation-aware tokenizing either, which the first version did and which is
/// wrong for code: `+=`, `=>` and `!=` are made entirely of delimiters, so a line whose
/// tokens are `x += 1;` came back with NO tokens at all and every score was zero. In
/// source, operators are words.
fn similarity(line: []const u8, probe: []const u8) f64 {
    var ps = std.ArrayList([]const u8).empty;
    defer ps.deinit(std.heap.page_allocator);
    var ls = std.ArrayList([]const u8).empty;
    defer ls.deinit(std.heap.page_allocator);
    splitWords(probe, &ps) catch return 0;
    splitWords(line, &ls) catch return 0;
    if (ps.items.len == 0) return 0;

    var inter: usize = 0;
    for (ps.items) |w| {
        for (ls.items) |lw| {
            if (std.mem.eql(u8, w, lw)) {
                inter += 1;
                break;
            }
        }
    }
    const total = ps.items.len + ls.items.len - inter;
    if (total == 0) return 0;
    return @as(f64, @floatFromInt(inter)) / @as(f64, @floatFromInt(total));
}

fn splitWords(text: []const u8, out: *std.ArrayList([]const u8)) !void {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |w| try out.append(std.heap.page_allocator, w);
}

fn tokensOf(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r\n");
}

const Best = struct {
    score: f64 = 0,
    line: ?usize = null,
    offset: ?usize = null,
};

fn offsetOfLine(file: []const u8, line_no: usize) ?usize {
    if (line_no == 0) return null;
    var pos: usize = 0;
    var n: usize = 1;
    while (n < line_no) : (n += 1) {
        const nl = std.mem.indexOfScalarPos(u8, file, pos, '\n') orelse return null;
        pos = nl + 1;
    }
    return pos;
}

fn lineAt(file: []const u8, line_no: usize) []const u8 {
    const off = offsetOfLine(file, line_no) orelse return "";
    const nl = std.mem.indexOfScalarPos(u8, file, off, '\n') orelse return file[off..];
    return file[off..nl];
}

/// `N-M ─ text`, so the model knows WHERE in the file it is looking.
fn window(arena: std.mem.Allocator, file: []const u8, from: usize, to: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const last_line = std.mem.count(u8, file, "\n") + 1;
    const hi = @min(to, last_line);
    var n: usize = from;
    while (n <= hi) : (n += 1) {
        if (n == 1) continue;
        const text = std.mem.trimEnd(u8, lineAt(file, n), "\r");
        try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{d: >5} | {s}\n", .{ n, text }));
        if (out.items.len > max_snippet) break;
    }
    return out.items;
}

/// The sentence the tool puts under the error. Split out so the wording is in ONE
/// place: the same message appears for a misplaced line, for a whitespace mismatch and
/// for text that never existed, and three copies of it is three chances to have one of
/// them be wrong.
pub fn message(h: Hint, path: []const u8) []const u8 {
    // Every branch opens with the same four words, and that is deliberate: they are
    // the vocabulary the schema and the prompt use, and a test elsewhere pins them.
    // What changes is the SENTENCE after them, because that is the part the model acts
    // on. One message for three failures would leave it with nothing to choose between.
    if (h.line == null) {
        return std.fmt.allocPrint(
            std.heap.page_allocator,
            "old_string not found in {s}, and nothing in the file is close to it — not with different spacing, " ++
                "not somewhere else. It is not in this file at all, so re-reading will not produce it: read the " ++
                "part of {s} you meant to change and patch against what it actually says. If you were editing from " ++
                "memory, that is what failed.",
            .{ path, path },
        ) catch "old_string not found";
    }
    if (h.whitespace_only) {
        return std.fmt.allocPrint(
            std.heap.page_allocator,
            "old_string not found in {s}, but the line IS there at line {d} and the SPACING is what differs. " ++
                "Here is the real text, patch that instead:\n{s}\nUse the indentation from the file, not from memory.",
            .{ path, h.line.?, h.text },
        ) catch "old_string not found";
    }
    if (h.verbatim) {
        return std.fmt.allocPrint(
            std.heap.page_allocator,
            "old_string not found in {s} at that spot — the text IS in the file, but the lines around it are " ++
                "not what the patch expects. Nearest line is {d}:\n{s}\nA patch has to be unambiguous: include a " ++
                "couple of the surrounding lines so it can only match one place.",
            .{ path, h.line.?, h.text },
        ) catch "old_string not found";
    }
    return std.fmt.allocPrint(
        std.heap.page_allocator,
        "old_string not found in {s}. Closest line is {d}:\n{s}\nIf that is the right place, patch against the " ++
            "text shown above rather than what you remembered.",
        .{ path, h.line.?, h.text },
    ) catch "old_string not found";
}

// ── tests ───────────────────────────────────────────────────────────────────────

const std_test = std.testing;

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("missing \"{s}\" in:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedEqual;
    }
}

test "a line that is right but in the wrong place says so, and shows the line" {
    var arena_state = std.heap.ArenaAllocator.init(std_test.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const file =
        \\const std = @import("std");
        \\pub fn main() void {
        \\    var x: u32 = 0;
        \\    x += 1;
        \\    std.debug.print("{d}\n", .{x});
        \\}
    ;
    // A patch built from memory: the line exists, but not with this context.
    const patch = "    x += 1;\n";

    const h = try hintFor(arena, file, patch);
    try std_test.expect(h.line != null);
    try std_test.expectEqual(@as(usize, 4), h.line.?);
    try std_test.expect(h.verbatim);
    const m = message(h, "src/main.zig");
    try expectContains(m, "the text IS in the file");
    try expectContains(m, "x += 1;");
}

test "a spacing mismatch is named as a spacing mismatch" {
    var arena_state = std.heap.ArenaAllocator.init(std_test.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The file uses a tab; the patch used four spaces.
    const file = "pub fn f() void {\n\tx += 1;\n}\n";
    const patch = "    x += 1;";

    const h = try hintFor(arena, file, patch);
    try std_test.expect(h.line != null);
    try std_test.expect(h.whitespace_only);
    const m = message(h, "a.zig");
    try expectContains(m, "the SPACING is what differs");
    try expectContains(m, "Use the indentation from the file");
}

test "text that never existed says so instead of pretending to be close" {
    var arena_state = std.heap.ArenaAllocator.init(std_test.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const file = "pub fn f() void {\n    std.debug.print(\"hello\");\n}\n";
    const patch = "struct WidgetRendererFactoryProviderRegistry { ... }";

    // Nothing with any word overlap: no line, and a message that does not imply it was
    // nearly right.
    const h = try hintFor(arena, file, patch);
    const m = message(h, "a.zig");
    try expectContains(m, "It is not in this file at all");
    try expectContains(m, "that is what failed");
}

test "the hint survives a patch of pure punctuation and an empty one" {
    var arena_state = std.heap.ArenaAllocator.init(std_test.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const file = "pub fn f() void {\n}\n";
    // These have no word of length >= 2, so there is nothing to search for and the
    // answer is "not found", not a random line.
    try std_test.expectEqual(@as(?usize, null), (try hintFor(arena, file, "};\n")).line);
    try std_test.expectEqual(@as(?usize, null), (try hintFor(arena, file, "")).line);
}

test "the three messages are different, because the three failures are different" {
    // Same wording for all three is what made the first version useless: the model
    // cannot choose an action from a sentence that fits all three cases.
    var arena_state = std.heap.ArenaAllocator.init(std_test.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const file = "pub fn f() void {\n\tx += 1;\n}\n";
    const misplaced = message(try hintFor(arena, "a\nb\nc\n    x += 1;\n", "    x += 1;"), "a.zig");
    const spacing = message(try hintFor(arena, file, "    x += 1;"), "a.zig");
    const absent = message(try hintFor(arena, file, "zzz qqq wwww"), "a.zig");
    try std_test.expect(!std.mem.eql(u8, misplaced, spacing));
    try std_test.expect(!std.mem.eql(u8, spacing, absent));
}
