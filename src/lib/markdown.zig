const std = @import("std");
const vaxis = @import("vaxis");
const hl = @import("highlight.zig");
const theme = @import("theme.zig");

pub const Style = vaxis.Style;

/// Text segment with style: the render unit of the history.
pub const Segment = struct {
    text: []const u8,
    style: Style,
};

pub const Kind = enum {
    user,
    assistant,
    info,
    tool,
    /// Header line of a running tool: "⏺ Read(src/tui.zig)"
    tool_run,
    /// Result line of a tool: "⎿  Read 1006 lines · 3ms"
    tool_res,
    /// Unified diff: lines with `+`/`-`/` ` (colored by prefix).
    diff,
    /// Header block (owl banner + Zo's line). Brand blue instead of
    /// `.info`'s gray, and with `*text*` it paints in the wordmark's brightness.
    banner,
    error_msg,
    code,
    separator,
};

/// Visual block of the history: already parsed and styled.
/// `lines` are segments per line WITHOUT wrap (wrapping happens in the draw).
pub const Block = struct {
    kind: Kind,
    lines: []const []const Segment,
    lang: []const u8 = "",
};

const styles = struct {
    fn fg(idx: u8) Style {
        return .{ .fg = .{ .index = idx } };
    }
    const user_prefix = fg(4); // blue
    const user_text = Style{};
    const asst_prefix = fg(5); // magenta
    const asst_text = Style{};
    const info = fg(8); // gray
    const tool = fg(6); // cyan
    const tool_bold: Style = .{ .bold = true, .fg = .{ .index = 6 } };
    const tool_res = fg(8); // the result goes dimmed
    // The tool summary goes in REAL BOLD. Before it was identical to
    // `tool_res` (same index, no `.bold`), so the "two tones" described in
    // AGENTS.md was a no-op: `*write*(hola.js) · *3ms*` came out entirely in
    // the same gray.
    const tool_res_bold: Style = .{ .bold = true, .fg = .{ .index = 8 } };
    const diff_add = fg(2); // green
    const diff_del = fg(1); // red
    const diff_ctx = fg(8); // gray
    const err = fg(1); // red
    // Header: the owl goes in the brand color and the wordmark one tone
    // above, so the logo reads lit against the art.
    // These are the three blues from `theme.zig`; they are repeated here
    // because this module does not depend on the TUI (markdown's tests use it
    // on its own).
    const banner: Style = .{ .fg = .{ .rgb = .{ 0x7a, 0xa2, 0xf7 } } }; // brand
    const banner_bold: Style = .{ .bold = true, .fg = .{ .rgb = .{ 0xc0, 0xca, 0xf5 } } }; // brand_hi
    const heading = Style{ .bold = true, .fg = .{ .index = 4 } };
    const bold = Style{ .bold = true };
    const inline_code = Style{ .fg = .{ .index = 3 } }; // yellow
    const sep = fg(8);
};

/// Parses text (possibly markdown) into blocks. Memory: arena.
pub fn parse(arena: std.mem.Allocator, kind: Kind, text: []const u8) ![]Block {
    return parseBase(arena, kind, text, null, null);
}

/// `parse` with an imposed base style (see `inlineSegmentsBase`).
pub fn parseBase(
    arena: std.mem.Allocator,
    kind: Kind,
    text: []const u8,
    base_override: ?Style,
    mood_style: ?Style,
) ![]Block {
    return parseLang(arena, kind, text, base_override, mood_style, "");
}

/// Like `parseBase` but knowing which LANGUAGE the content is in.
///
/// Right now only the diff uses it: without the file extension the body of a
/// line (`+const x: u32 = 4`) cannot be tokenized and comes out entirely in the
/// prefix color, which is the green wall that used to be there.
pub fn parseLang(
    arena: std.mem.Allocator,
    kind: Kind,
    text: []const u8,
    base_override: ?Style,
    mood_style: ?Style,
    lang: []const u8,
) ![]Block {
    const diff_lang = lang;
    var blocks: std.ArrayList(Block) = .empty;
    var inline_lines: std.ArrayList([]const Segment) = .empty;

    var in_code = false;
    var code_lang: []const u8 = "";
    var code_lines: std.ArrayList([]const Segment) = .empty;
    // Highlighter state carried across lines (unclosed strings and block
    // comments). Reset every time a fence opens.
    var code_state = hl.State{};

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        // fences ``` / ~~~
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "```") or
            std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "~~~"))
        {
            if (in_code) {
                try blocks.append(arena, .{
                    .kind = .code,
                    .lines = try code_lines.toOwnedSlice(arena),
                    .lang = code_lang,
                });
                code_lines = .empty;
                in_code = false;
            } else {
                // close the pending inline block
                if (inline_lines.items.len > 0) {
                    try blocks.append(arena, .{
                        .kind = kind,
                        .lines = try inline_lines.toOwnedSlice(arena),
                    });
                    inline_lines = .empty;
                }
                in_code = true;
                const trimmed = std.mem.trimStart(u8, line, " ");
                code_lang = if (trimmed.len > 3) trimmed[3..] else "";
                // Every fence starts with no state: whatever stayed open in
                // the previous block is not carried over.
                code_state = .{};
            }
            continue;
        }

        if (in_code) {
            // The state is carried ACROSS LINES of the block: without this a
            // Zig `\` or an unclosed quote made the next line come out entirely
            // green, and sometimes the rest of the file with it.
            const segs = hl.highlightLineState(arena, line, code_lang, &code_state) catch
                try arena.alloc(Segment, 0);
            try code_lines.append(arena, segs);
            continue;
        }

        // headings
        //
        // CAREFUL: the startup banner skips this. Its art starts with `##`
        // (`#` fill of ASCII art) and ALL of its rows were eaten as headings:
        // the logo came out as "####  ####  *zode*". The banner is not prose,
        // it is a drawing: do not look for markdown structure in it.
        if (kind != .banner) {
            const trimmed = std.mem.trimStart(u8, line, " ");
            if (trimmed.len >= 2 and trimmed[0] == '#' and (trimmed[1] == ' ' or trimmed[1] == '#')) {
                var nh: usize = 0;
                while (nh < trimmed.len and trimmed[nh] == '#') nh += 1;
                if (nh < trimmed.len and trimmed[nh] == ' ') {
                    const heading_text = trimmed[nh + 1 ..];
                    const segs = try arena.alloc(Segment, 1);
                    segs[0] = .{ .text = heading_text, .style = styles.heading };
                    try inline_lines.append(arena, segs);
                    continue;
                }
            }
        }

        // The diff needs the file's LANGUAGE to tokenize the body; the other
        // kinds ignore it (they are passed "").
        const line_lang: []const u8 = if (kind == .diff) diff_lang else "";
        try inline_lines.append(arena, try inlineSegmentsLang(arena, line, kind, base_override, mood_style, line_lang));
    }
    // pending code without a closing fence
    if (in_code and code_lines.items.len > 0) {
        try blocks.append(arena, .{
            .kind = .code,
            .lines = try code_lines.toOwnedSlice(arena),
            .lang = code_lang,
        });
    }
    // pending text
    if (inline_lines.items.len > 0) {
        try blocks.append(arena, .{
            .kind = kind,
            .lines = try inline_lines.toOwnedSlice(arena),
        });
    }
    return blocks.toOwnedSlice(arena);
}

/// Base style per kind for text with no special formatting.
fn baseStyle(kind: Kind) Style {
    return switch (kind) {
        .user => styles.user_text,
        .assistant => styles.asst_text,
        .info => styles.info,
        .tool, .tool_run => styles.tool,
        .tool_res => styles.tool_res,
        .error_msg => styles.err,
        .banner => styles.banner,
        else => styles.asst_text,
    };
}

/// One unified diff line: prefix in its own color + the rest BY TOKENS.
///
/// Before it was a SINGLE segment for the whole line with `diff_add`, which is a
/// solid green (#00cd00). Writing a 200-line file gave 200 flat green rows: you
/// could not tell a string from a number from a type, and on top of that that
/// green was the SAME one used for code strings (`highlight.zig`), so "green"
/// did not mean anything.
///
/// Now the `+`/`-`/` ` prefix goes with its own color and the body goes through
/// the highlighter with `lang`, which is what makes a diff readable: numbers
/// look like numbers and Pascal identifiers look like types.
fn diffSegments(arena: std.mem.Allocator, line: []const u8, lang: []const u8) ![]Segment {
    if (line.len == 0) {
        const segs = try arena.alloc(Segment, 1);
        segs[0] = .{ .text = line, .style = theme.diff_ctx };
        return segs;
    }
    const pre_style: Style = switch (line[0]) {
        '+' => theme.diff_add,
        '-' => theme.diff_del,
        '@' => styles.heading, // @@ hunk @@ header
        else => theme.diff_ctx,
    };
    // `@@ … @@` is a hunk header, not code: entirely in the heading color.
    if (line[0] == '@') {
        const segs = try arena.alloc(Segment, 1);
        segs[0] = .{ .text = line, .style = pre_style };
        return segs;
    }

    // The prefix (`+`, `-` or the context space) is a segment of its own, and
    // the rest is tokenized. The context space is NOT included in the body that
    // goes to the highlighter: otherwise the language would recognize nothing
    // until the first real character.
    const lead: usize = if (line[0] == '+' or line[0] == '-')
        1
    else if (line[0] == ' ')
        @min(1, line.len)
    else
        0;
    var out: std.ArrayList(Segment) = .empty;
    if (lead > 0) {
        try out.append(arena, .{ .text = line[0..lead], .style = pre_style });
    }
    const body = line[lead..];
    if (body.len > 0) {
        const toks = try hl.highlightLine(arena, body, lang);
        for (toks) |t| {
            // The highlight tokens bring their own colors; the diff prefix
            // already goes separately. For the context (` ` lines) the body IS
            // dimmed, because otherwise the diff of a whole file comes out with
            // the same contrast as the changed lines.
            var st = t.style;
            if (lead == 0 or (lead == 1 and line[0] == ' ')) {
                st = theme.diff_ctx;
            }
            try out.append(arena, .{ .text = t.text, .style = st });
        }
    }
    return out.toOwnedSlice(arena);
}

/// Line cap per file for the diff.
///
/// `unifiedDiff` is line-wise LCS O(n·m) and the table is (n+1)·(m+1) `usize`: a
/// pair of 10 000-line files is 800 MB of table. Above this cap the diff is not
/// computed: a notice is shown instead. That is degradation, not an error.
pub const max_diff_lines = 2000;

/// Context lines kept around each change.
pub const diff_context_lines = 3;

/// One line of the raw diff, before hunking.
const DiffLine = struct {
    /// Already prefixed with ' ', '+' or '-'.
    text: []const u8,
    /// 1-based line number in the OLD file (null for a '+' line).
    old_no: ?usize,
    /// 1-based line number in the NEW file (null for a '-' line).
    new_no: ?usize,

    fn changed(self: DiffLine) bool {
        return self.text[0] != ' ';
    }
};

/// Builds a unified diff between two texts, with REAL HUNKS.
///
/// Line-wise LCS: O(n*m), with `max_diff_lines` as a cap.
///
/// The raw diff used to be emitted whole, so editing 2 lines of a 200-line file
/// painted 200 lines of diff, 198 of them context. Now unchanged runs far from
/// any change are collapsed behind an elision marker, with a `@@ -a,b +c,d @@`
/// header per hunk, which is what `diff -u` does and what makes the diff
/// readable instead of a wall.
///
/// Returns an arena slice whose lines are already prefixed with ' ', '+', '-' or
/// '@' (the hunk headers and elisions, which `diffSegments` paints as headings).
pub fn unifiedDiff(arena: std.mem.Allocator, before: []const u8, after: []const u8) ![]const []const u8 {
    var old_lines: std.ArrayList([]const u8) = .empty;
    var new_lines: std.ArrayList([]const u8) = .empty;
    try splitLines(arena, before, &old_lines);
    try splitLines(arena, after, &new_lines);

    // LCS table (n+1) x (m+1) of usize.
    const n = old_lines.items.len;
    const m = new_lines.items.len;
    if (n > max_diff_lines or m > max_diff_lines) {
        const note = try arena.dupe(u8, "diff omitted (file too large)");
        const one = try arena.alloc([]const u8, 1);
        one[0] = note;
        return one;
    }
    const table = try arena.alloc(usize, (n + 1) * (m + 1));
    @memset(table, 0);
    var i = n;
    while (i > 0) {
        i -= 1;
        var j = m;
        while (j > 0) {
            j -= 1;
            table[i * (m + 1) + j] = if (std.mem.eql(u8, old_lines.items[i], new_lines.items[j]))
                table[(i + 1) * (m + 1) + (j + 1)] + 1
            else
                @max(table[(i + 1) * (m + 1) + j], table[i * (m + 1) + (j + 1)]);
        }
    }

    var raw: std.ArrayList(DiffLine) = .empty;
    var x: usize = 0;
    var y: usize = 0;
    while (x < n and y < m) {
        if (std.mem.eql(u8, old_lines.items[x], new_lines.items[y])) {
            try raw.append(arena, .{
                .text = try prefixed(arena, ' ', old_lines.items[x]),
                .old_no = x + 1,
                .new_no = y + 1,
            });
            x += 1;
            y += 1;
        } else if (table[(x + 1) * (m + 1) + y] >= table[x * (m + 1) + (y + 1)]) {
            try raw.append(arena, .{ .text = try prefixed(arena, '-', old_lines.items[x]), .old_no = x + 1, .new_no = null });
            x += 1;
        } else {
            try raw.append(arena, .{ .text = try prefixed(arena, '+', new_lines.items[y]), .old_no = null, .new_no = y + 1 });
            y += 1;
        }
    }
    while (x < n) : (x += 1) {
        try raw.append(arena, .{ .text = try prefixed(arena, '-', old_lines.items[x]), .old_no = x + 1, .new_no = null });
    }
    while (y < m) : (y += 1) {
        try raw.append(arena, .{ .text = try prefixed(arena, '+', new_lines.items[y]), .old_no = null, .new_no = y + 1 });
    }

    if (raw.items.len == 0) return &.{};
    return hunk(arena, raw.items);
}

/// Collapses unchanged runs into hunks with `@@` headers.
fn hunk(arena: std.mem.Allocator, raw: []const DiffLine) ![]const []const u8 {
    // `keep[i]` = line i is within `diff_context_lines` of a change.
    var keep = try arena.alloc(bool, raw.len);
    for (keep) |*k| k.* = false;
    for (raw, 0..) |l, i| {
        if (!l.changed()) continue;
        const lo = i -| diff_context_lines;
        const hi = @min(i + diff_context_lines, raw.len - 1);
        var j = lo;
        while (j <= hi) : (j += 1) keep[j] = true;
    }

    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    var first_hunk = true;
    while (i < raw.len) {
        if (!keep[i]) {
            i += 1;
            continue;
        }
        // Run of kept lines [i, end).
        const start = i;
        while (i < raw.len and keep[i]) i += 1;
        const end = i;

        if (!first_hunk) {
            try out.append(arena, try arena.dupe(u8, "@@ ... @@"));
        }
        first_hunk = false;

        // Header: first line number of each side in the run, and its length.
        var old_start: usize = 0;
        var new_start: usize = 0;
        var old_count: usize = 0;
        var new_count: usize = 0;
        for (raw[start..end]) |l| {
            if (l.old_no) |o| {
                if (old_count == 0) old_start = o;
                old_count += 1;
            }
            if (l.new_no) |nn| {
                if (new_count == 0) new_start = nn;
                new_count += 1;
            }
        }
        const header = try std.fmt.allocPrint(arena, "@@ -{d},{d} +{d},{d} @@", .{
            old_start, old_count, new_start, new_count,
        });
        try out.append(arena, header);
        for (raw[start..end]) |l| try out.append(arena, l.text);
    }
    return out.items;
}

fn prefixed(arena: std.mem.Allocator, p: u8, line: []const u8) ![]const u8 {
    const buf = try arena.alloc(u8, line.len + 1);
    buf[0] = p;
    @memcpy(buf[1..], line);
    return buf;
}

/// Splits into lines ignoring the final newline: "a\nb\n" is 2 lines, not 3.
/// (Otherwise a file ending in \n produces a spurious empty line in the diff.)
fn splitLines(arena: std.mem.Allocator, text: []const u8, out: *std.ArrayList([]const u8)) !void {
    const body = if (std.mem.endsWith(u8, text, "\n")) text[0 .. text.len - 1] else text;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |l| try out.append(arena, l);
}

/// Inline segments: **bold**, `code`, and plain text.
/// Inline segments of one line. `pub` so the TUI tests can check the
/// style layout of the banner.
pub fn inlineSegments(arena: std.mem.Allocator, line: []const u8, kind: Kind) ![]Segment {
    return inlineSegmentsBase(arena, line, kind, null, null);
}

/// Same as `inlineSegments` but with a base style imposed by the caller
/// (the TUI uses it to paint Zo's face in the color of its mood).
pub fn inlineSegmentsBase(
    arena: std.mem.Allocator,
    line: []const u8,
    kind: Kind,
    base_override: ?Style,
    mood_style: ?Style,
) ![]Segment {
    return inlineSegmentsLang(arena, line, kind, base_override, mood_style, "");
}

/// Like `inlineSegmentsBase` but with the line's LANGUAGE.
///
/// Needed for the diff: the prefix goes with its own color and the body is
/// tokenized as code, so you have to know which language the file being edited
/// is in. For the other kinds the language does not matter.
pub fn inlineSegmentsLang(
    arena: std.mem.Allocator,
    line: []const u8,
    kind: Kind,
    base_override: ?Style,
    mood_style: ?Style,
    lang: []const u8,
) ![]Segment {
    if (kind == .diff) return diffSegments(arena, line, lang);

    // Header: `*zode*` and `*─────*` glow inside the owl's art. With this the
    // glow lands INSIDE the drawing instead of painting a whole line, which is
    // what makes the ASCII art look like a logo and not a block.
    if (kind == .banner and
        (std.mem.indexOfScalar(u8, line, '*') != null or std.mem.indexOfScalar(u8, line, '~') != null))
    {
        return markedSegments(arena, line, styles.banner, styles.banner_bold, mood_style orelse styles.banner);
    }

    // Tools use the SAME `*…*` marker to split the name off the rest:
    // `write(hola.js)` comes out entirely in one color and you cannot tell the
    // tool from its argument. With `*write* (hola.js)` the name goes in the
    // strong color and the argument in the dimmed one, which is how the eye
    // reads it at a glance.
    if (kind == .tool_run and std.mem.indexOfScalar(u8, line, '*') != null) {
        return markedSegments(arena, line, styles.tool, styles.tool_bold, styles.tool);
    }
    if (kind == .tool_res and std.mem.indexOfScalar(u8, line, '*') != null) {
        return markedSegments(arena, line, styles.tool_res, styles.tool_res_bold, styles.tool_res);
    }

    var segs: std.ArrayList(Segment) = .empty;
    const base = base_override orelse baseStyle(kind);
    var i: usize = 0;
    var start: usize = 0;

    while (i < line.len) {
        // **bold**
        if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '*') {
            if (constClose(line, i + 2, "**")) |end| {
                if (i > start) try segs.append(arena, .{ .text = line[start..i], .style = base });
                try segs.append(arena, .{ .text = line[i + 2 .. end], .style = styles.bold });
                i = end + 2;
                start = i;
                continue;
            }
        }
        // `code`
        if (line[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, line, i + 1, '`')) |end| {
                if (end > i + 1) {
                    if (i > start) try segs.append(arena, .{ .text = line[start..i], .style = base });
                    try segs.append(arena, .{ .text = line[i + 1 .. end], .style = styles.inline_code });
                    i = end + 1;
                    start = i;
                    continue;
                }
            }
        }
        i += 1;
    }
    if (start < line.len) {
        try segs.append(arena, .{ .text = line[start..], .style = base });
    }
    if (segs.items.len == 0) {
        try segs.append(arena, .{ .text = "", .style = base });
    }
    return segs.toOwnedSlice(arena);
}

/// Splits the line on markers and paints each span with its style.
///
/// There are TWO kinds of marker because the logo is fixed and Zo's color is
/// not:
///   `*…*`  → `hi` (the wordmark, always the same light blue)
///   `~…~`  → `mood` (whatever the caller passes: the color of Zo's mood)
///
/// The markers are STRIPPED from the output text (they are markers, not
/// content), so the caller sees clean text while the drawing comes out in
/// several colors. An unpaired marker is treated as normal text, so no
/// character is ever lost.
fn markedSegments(
    arena: std.mem.Allocator,
    line: []const u8,
    base: Style,
    hi: Style,
    mood: Style,
) ![]Segment {
    var segs: std.ArrayList(Segment) = .empty;
    var i: usize = 0;
    var start: usize = 0;

    while (i < line.len) {
        const m: ?struct { ch: u8, style: Style } = switch (line[i]) {
            '*' => .{ .ch = '*', .style = hi },
            '~' => .{ .ch = '~', .style = mood },
            else => null,
        };
        if (m) |mark| {
            if (constClose(line, i + 1, &.{mark.ch})) |end| {
                if (i > start) try segs.append(arena, .{ .text = line[start..i], .style = base });
                if (end > i + 1) try segs.append(arena, .{ .text = line[i + 1 .. end], .style = mark.style });
                i = end + 1;
                start = i;
                continue;
            }
        }
        i += 1;
    }
    if (start < line.len) try segs.append(arena, .{ .text = line[start..], .style = base });
    if (segs.items.len == 0) try segs.append(arena, .{ .text = "", .style = base });
    return segs.toOwnedSlice(arena);
}

/// Searches for `needle` in `line` starting at `from`; returns its start index
/// if found.
fn constClose(line: []const u8, from: usize, needle: []const u8) ?usize {
    const rel = std.mem.indexOfPos(u8, line, from, needle) orelse return null;
    return rel;
}

/// Prompt prefixes per kind (they are drawn on the first line of the block).
pub fn prefix(kind: Kind) struct { text: []const u8, style: Style } {
    return switch (kind) {
        .user => .{ .text = "› ", .style = styles.user_prefix },
        .assistant => .{ .text = "◆ ", .style = styles.asst_prefix },
        .info => .{ .text = "· ", .style = styles.info },
        .tool => .{ .text = "⚙ ", .style = styles.tool },
        // Claude Code style tool calls: header and result with dashes.
        .tool_run => .{ .text = "⏺ ", .style = styles.tool_bold },
        .tool_res => .{ .text = "⎿  ", .style = styles.tool_res },
        .diff => .{ .text = "", .style = styles.diff_ctx },
        .error_msg => .{ .text = "✗ ", .style = styles.err },
        .banner => .{ .text = "", .style = styles.banner },
        else => .{ .text = "  ", .style = styles.info },
    };
}

// basic test
test "parse markdown básico" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const blocks = try parse(arena, .assistant, "# Titulo\nHola **mundo** con `code`\n```zig\nconst x = 1;\n```\nfin");
    // block 1: heading + inline line (2 lines)
    try std.testing.expect(blocks.len >= 3);
    try std.testing.expectEqual(Kind.code, blocks[1].kind);
}

test "unifiedDiff: cambio simple, con cabecera de hunk" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try unifiedDiff(arena, "uno\ndos\ntres\n", "uno\nDOS\ntres\n");
    // Header + 3 lines + context: it all fits in a single hunk.
    try std.testing.expectEqual(@as(usize, 5), d.len);
    try std.testing.expectEqualStrings("@@ -1,3 +1,3 @@", d[0]);
    try std.testing.expectEqualStrings(" uno", d[1]);
    try std.testing.expectEqualStrings("-dos", d[2]);
    try std.testing.expectEqualStrings("+DOS", d[3]);
    try std.testing.expectEqualStrings(" tres", d[4]);
}

test "unifiedDiff: sin cambios no produce +/-" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // With no changes there is nothing to show: not even a hunk.
    const d = try unifiedDiff(arena, "igual\n", "igual\n");
    try std.testing.expectEqual(@as(usize, 0), d.len);
}

test "unifiedDiff: lineas nuevas al final" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try unifiedDiff(arena, "a\n", "a\nb\nc\n");
    try std.testing.expectEqualStrings("@@ -1,1 +1,3 @@", d[0]);
    try std.testing.expectEqualStrings(" a", d[1]);
    try std.testing.expectEqualStrings("+b", d[2]);
    try std.testing.expectEqualStrings("+c", d[3]);
}

test "unifiedDiff: borrado" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try unifiedDiff(arena, "a\nb\nc\n", "a\nc\n");
    try std.testing.expectEqualStrings("@@ -1,3 +1,2 @@", d[0]);
    try std.testing.expectEqualStrings(" a", d[1]);
    try std.testing.expectEqualStrings("-b", d[2]);
    try std.testing.expectEqualStrings(" c", d[3]);
}

test "diffSegments: el prefijo va con su color y el cuerpo POR TOKENS" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The prefix is a segment of its own...
    const add = try inlineSegments(arena, "+nuevo", .diff);
    try std.testing.expectEqualStrings("+", add[0].text);
    try std.testing.expectEqual(theme.diff_add.fg, add[0].style.fg);

    const del = try inlineSegments(arena, "-viejo", .diff);
    try std.testing.expectEqualStrings("-", del[0].text);
    try std.testing.expectEqual(theme.diff_del.fg, del[0].style.fg);

    const ctx = try inlineSegments(arena, " igual", .diff);
    try std.testing.expectEqualStrings(" ", ctx[0].text);
    try std.testing.expectEqual(theme.diff_ctx.fg, ctx[0].style.fg);

    // ...and the text is NEVER lost: module invariant.
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(std.testing.allocator);
    for (add) |sg| try joined.appendSlice(std.testing.allocator, sg.text);
    try std.testing.expectEqualStrings("+nuevo", joined.items);
}

test "una línea + del diff lleva tokens, no un segmento verde" {
    // The green wall: `+const n: u32 = 42` was ONE segment with `diff_add`. Now
    // the prefix goes with its own color and the body is tokenized, so `const`
    // is a keyword, `u32` a type and `42` a number. That is what makes a diff
    // readable without opening the file.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const segs = try inlineSegmentsLang(arena, "+const n: u32 = 42", .diff, null, null, "zig");
    try std.testing.expect(segs.len >= 4);

    const kw = findDiffSeg(segs, "const") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(theme.code_kw.fg, kw.style.fg);
    const typ = findDiffSeg(segs, "u32") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(theme.code_type.fg, typ.style.fg);
    const num = findDiffSeg(segs, "42") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(theme.code_num.fg, num.style.fg);

    // And the prefix keeps its diff green, which is DISTINCT from the green of
    // the code strings (before, both were `index 2`).
    try std.testing.expect(!std.meta.eql(theme.diff_add.fg, theme.code_str.fg));

    // Invariant: every byte is preserved.
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(std.testing.allocator);
    for (segs) |sg| try joined.appendSlice(std.testing.allocator, sg.text);
    try std.testing.expectEqualStrings("+const n: u32 = 42", joined.items);
}

fn findDiffSeg(segs: []const Segment, needle: []const u8) ?Segment {
    for (segs) |s| {
        if (std.mem.eql(u8, s.text, needle)) return s;
    }
    return null;
}

test "el diff sin saber el lenguaje sale plano pero conserva el prefijo" {
    // With `lang = ""` it falls back to `generic`, which now has a table: it is
    // not a green wall, but it does not invent colors either.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const segs = try inlineSegments(arena, "+hola", .diff);
    try std.testing.expectEqualStrings("+", segs[0].text);
    try std.testing.expectEqual(theme.diff_add.fg, segs[0].style.fg);
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(std.testing.allocator);
    for (segs) |sg| try joined.appendSlice(std.testing.allocator, sg.text);
    try std.testing.expectEqualStrings("+hola", joined.items);
}

test "un banner que empieza por ## NO se come como encabezado" {
    // The banner art uses `#` as fill and ALL of its rows start with `##`, so
    // the parser interpreted them as markdown headings and returned
    // "####  ####  *zode*" instead of the whole drawing. The banner is a
    // drawing, not prose: do not look for structure in it.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const blocks = try parseBase(arena, .banner, "######  ####   ######\n##  ## ##  ## ##    ", null, null);
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    const segs = blocks[0].lines[0];
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    for (segs) |seg| try text.appendSlice(std.testing.allocator, seg.text);
    try std.testing.expectEqualStrings("######  ####   ######", text.items);

    // And the other kinds STILL interpret headings: the fix is for `.banner`,
    // not a general deactivation.
    const h = try parseBase(arena, .info, "## un titulo", null, null);
    var ht: std.ArrayList(u8) = .empty;
    defer ht.deinit(std.testing.allocator);
    for (h[0].lines[0]) |seg| try ht.appendSlice(std.testing.allocator, seg.text);
    try std.testing.expectEqualStrings("un titulo", ht.items);
}

test "unifiedDiff: por encima del tope no se calcula el LCS (sería O(n*m))" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // With the normal cap the diff is computed.
    const small = try unifiedDiff(arena, "a\nb\n", "a\nc\n");
    try std.testing.expectEqual(@as(usize, 4), small.len); // header + 3
    try std.testing.expectEqualStrings("-b", small[2]);

    // Above the cap the notice comes out, and it comes out FAST: without the
    // 4000x4000 table.
    var big_a: std.ArrayList(u8) = .empty;
    var big_b: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < max_diff_lines + 10) : (i += 1) {
        try big_a.appendSlice(arena, "x\n");
        try big_b.appendSlice(arena, "y\n");
    }
    const out = try unifiedDiff(arena, big_a.items, big_b.items);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expect(std.mem.indexOf(u8, out[0], "too large") != null);
}

test "tool_res_bold es bold DE VERDAD (el 'dos tonos' no era un no-op)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The tool summary (`*3ms*`) has to come out in bold; before,
    // `tool_res_bold` was identical to `tool_res` (same index, no `.bold`) and
    // the tools' "two tones" painted nothing.
    const segs = try inlineSegments(arena, "*3ms*", .tool_res);
    try std.testing.expectEqual(@as(usize, 1), segs.len);
    try std.testing.expect(segs[0].style.bold);
    try std.testing.expectEqual(styles.tool_res_bold.fg, segs[0].style.fg);
    try std.testing.expectEqualStrings("3ms", segs[0].text);

    // And the UNMARKED text comes out dimmed and WITHOUT bold: the two tones
    // exist.
    const plain = try inlineSegments(arena, "salida", .tool_res);
    try std.testing.expect(!plain[0].style.bold);
    try std.testing.expectEqual(styles.tool_res.fg, plain[0].style.fg);
}

test "unifiedDiff: un cambio pequeno en un fichero grande NO escupe el fichero entero" {
    // The raw diff used to be emitted in full: editing 2 lines of a 200-line
    // file painted 200 diff lines, 198 of them context. That is what made a
    // `write` look like a wall.
    //
    // Now only the ranges with context around the change are emitted, with an
    // `@@` header and an ellipsis between hunks, like `diff -u`.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 60 lines, line 30 is changed.
    var before: std.ArrayList(u8) = .empty;
    var after: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        try before.appendSlice(arena, try std.fmt.allocPrint(arena, "linea {d}\n", .{i}));
        try after.appendSlice(arena, try std.fmt.allocPrint(arena, "linea {d}\n", .{if (i == 30) @as(usize, 999) else i}));
    }

    const d = try unifiedDiff(arena, before.items, after.items);
    // A single hunk: header + 3 context lines + 1 '-' change + 1 '+' + 3 context lines.
    try std.testing.expectEqual(@as(usize, 9), d.len);
    try std.testing.expectEqualStrings("@@ -28,7 +28,7 @@", d[0]);
    try std.testing.expectEqualStrings("-linea 30", d[4]);
    try std.testing.expectEqualStrings("+linea 999", d[5]);
    // And the rest of the file does NOT come out.
    for (d) |l| {
        try std.testing.expect(std.mem.indexOf(u8, l, "linea 0") == null or
            std.mem.startsWith(u8, l, " ") or std.mem.startsWith(u8, l, "-") and l.len < 12);
    }
}

test "unifiedDiff: dos cambios alejados dan dos hunks con elipsis en medio" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var before: std.ArrayList(u8) = .empty;
    var after: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        const changed = i == 5 or i == 50;
        try before.appendSlice(arena, try std.fmt.allocPrint(arena, "linea {d}\n", .{i}));
        try after.appendSlice(arena, try std.fmt.allocPrint(arena, "linea {d}\n", .{if (changed) @as(usize, 999) else i}));
    }

    const d = try unifiedDiff(arena, before.items, after.items);
    // Two headers and one ellipsis between them.
    var headers: usize = 0;
    var elisions: usize = 0;
    for (d) |l| {
        if (std.mem.startsWith(u8, l, "@@ -")) headers += 1;
        if (std.mem.eql(u8, l, "@@ ... @@")) elisions += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), headers);
    try std.testing.expectEqual(@as(usize, 1), elisions);
    // And both changed lines are present.
    var found_a = false;
    var found_b = false;
    for (d) |l| {
        if (std.mem.eql(u8, l, "+linea 999")) {
            if (!found_a) found_a = true;
            if (!found_b) found_b = true;
        }
    }
    try std.testing.expect(found_a and found_b);
}

test "unifiedDiff: sin cambios devuelve vacío (no un hunk de contexte)" {
    // `pushDiff` already filtered this on its own, but it is better for the
    // function to invent nothing: a context-only hunk would be noise in the
    // history.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try unifiedDiff(arena, "a\nb\nc\n", "a\nb\nc\n");
    try std.testing.expectEqual(@as(usize, 0), d.len);
}
