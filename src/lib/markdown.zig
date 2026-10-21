const std = @import("std");
const vaxis = @import("vaxis");
const hl = @import("highlight.zig");
const theme = @import("theme.zig");
const diff_tokenizer = @import("diff_tokenizer.zig");
const diffview = @import("diffview.zig");

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

    // Everything below comes from `theme.zig` and this module used to keep its
    // OWN COPY of the palette, hardcoded, with a comment saying that was on
    // purpose so the tests would run on their own. It is not on purpose: both
    // files live in `src/lib/`, `theme.zig` imports nothing but vaxis, and
    // `highlight.zig` has been importing it all along.
    //
    // The cost of the copy was a UI with two color systems: the banner, the
    // prose, the bullets and the diff came out of one palette and the chrome
    // out of another, and retheming meant grepping. The palette is the ONE
    // place now, and `theme.zig`'s contrast test is what guards the half that
    // lives here.

    const user_prefix = theme.user;
    const user_text = theme.ink;
    // The assistant's prose is DEFAULT BRIGHT with no color at all. It used to
    // be `.{}` and the `◆` prefix was magenta: the model's own words were
    // decorated in the loudest color on the screen, which made every answer
    // look like chrome.
    const asst_prefix = Style{};
    const asst_text = theme.ink;
    /// A notice ("3 tool results elided", "done · 12.4s"). It has to be READ,
    /// so it is `ink3` and not the terminal's gray.
    const info: Style = theme.notice;
    const tool = theme.tool_name;
    const tool_bold = theme.tool_name;
    const tool_res = theme.tool_res;
    /// BOLD, and the SAME tone: the two-tone effect is weight, not color. The
    /// first draft of the new palette pointed both at `theme.tool_res`, which
    /// silently made `tool_res_bold` an alias and the `*3ms*` span came out
    /// indistinguishable from the line it was on — the exact no-op this test
    /// was written to prevent, reintroduced through the refactor.
    const tool_res_bold: Style = .{ .bold = true, .fg = theme.tool_res.fg };
    const diff_add = theme.diff_add;
    const diff_del = theme.diff_del;
    const diff_ctx = theme.diff_ctx;
    const err = theme.err;
    const banner: Style = theme.brand;
    const banner_bold = theme.brand_hi;
    /// A heading is WHITE BOLD, brighter than the prose around it, which is the
    /// entire job of a heading. It was `#c0caf5` and the diff hunk was a blue
    /// bold: two different things that used to be the same color.
    const heading = theme.heading;
    /// The `@@ -a,b +c,d @@` line. Amber bold: it is a label for the block
    /// below it, not a title.
    const hunk: Style = theme.diff_hunk;
    const bullet: Style = theme.bullet;
    const quote_bar: Style = theme.quote;
    const rule: Style = theme.line;
    const bold = Style{ .bold = true };
    /// Inline `code`. Amber, to match the number tokens: an inline code span and
    /// a numeric literal are the same kind of thing you look up.
    const inline_code = Style{ .fg = .{ .rgb = .{ 0xff, 0xcb, 0x6b } } };
    const sep = fg(8);
};

/// Parses text (possibly markdown) into blocks. Memory: arena.
pub fn parse(arena: std.mem.Allocator, kind: Kind, text: []const u8) ![]Block {
    return parseBase(arena, kind, text, null, null, .{});
}

/// `parse` with an imposed base style (see `inlineSegmentsBase`).
pub fn parseBase(
    arena: std.mem.Allocator,
    kind: Kind,
    text: []const u8,
    base_override: ?Style,
    mood_style: ?Style,
    opts: DiffOpts,
) ![]Block {
    return parseLang(arena, kind, text, base_override, mood_style, "", opts);
}

/// How a diff is painted.
pub const DiffOpts = struct {
    /// Compute the WORD-level diff: the words that changed inside a row get
    /// the diff's background.
    ///
    /// Off for a collapsed preview. A preview is twelve rows of a bigger
    /// diff, and a word-level highlight inside it is confetti: the reader
    /// cannot see the whole change anyway, so which words changed inside
    /// those twelve rows is noise. The expanded diff has them.
    word_diff: bool = true,

    /// The width of the terminal the content is painted into, in COLUMNS.
    ///
    /// Only the tables use it: a table has to FIT, and a table that does not
    /// fit is not a table (it becomes a list of `name: value` rows).
    ///
    /// 0 means "the caller does not know the width": the table keeps its
    /// natural column widths, nothing is shrunk, and a cell wider than
    /// `default_cell_width` is wrapped onto more lines inside its cell
    /// instead of becoming a 400-column line.
    width: u16 = 0,
};

/// What the painter needs to know about the row it is painting.
pub const DiffRow = struct {
    /// The line number the gutter shows.
    number: ?usize = null,
    /// The width of the gutter, in columns.
    gutter_width: usize = 0,
    /// The changed byte ranges, in the body (without the `+`/`-`).
    ranges: []const diff_tokenizer.DiffRange = &.{},
};

/// The context a diff's rows are painted in.
///
/// The state is the highlighter's, and there are TWO of them because a diff
/// is two files: a `-` row is a line of the old file and a `+` row is a line
/// of the new one. One state for both would mean that a deleted line which
/// opens a multiline string leaves the ADDED line (which does not open one)
/// painted as inside a string. A context row is the same line in both files,
/// so it carries the two states along together.
pub const DiffCtx = struct {
    row: DiffRow = .{},
    new_state: hl.State = .{},
    old_state: hl.State = .{},
};

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
    opts: DiffOpts,
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

    // The diff is read ONCE, before it is painted: the line numbers, the
    // gutter width and the changed words all come from the same reading of
    // the text, and a painter that recovered them row by row would have to
    // recover them row by row.
    var diff_rows: []const diffview.Line = &.{};
    var diff_ctx = DiffCtx{};
    if (kind == .diff) {
        diff_rows = try diffview.analyze(arena, text, .{ .word_diff = opts.word_diff });
    }

    var idx: usize = 0;
    // The lines are collected BEFORE the loop because a table has to LOOK
    // AHEAD: a header line is only a table when the NEXT line is its
    // separator. A streaming iterator cannot look ahead, so the text is
    // split once and the loop walks the array.
    var src_lines: std.ArrayList([]const u8) = .empty;
    {
        var split = std.mem.splitScalar(u8, text, '\n');
        while (split.next()) |l| try src_lines.append(arena, l);
    }

    while (idx < src_lines.items.len) : (idx += 1) {
        const line = src_lines.items[idx];
        // A diff is NOT prose. It has no fences (a markdown file's own ``` is
        // a context row that starts with a space), no bullets (a deleted
        // line starts with "- " and was being painted as a LIST ITEM), no
        // quotes and no headings. Every one of those readings took a row of
        // the diff and turned it into something else.
        if (kind == .diff) {
            const row = if (idx < diff_rows.len) diff_rows[idx] else diffview.Line{
                .kind = .other,
                .text = line,
                .number = null,
                .gutter_width = 0,
                .ranges = &.{},
            };
            diff_ctx.row = .{
                .number = row.number,
                .gutter_width = row.gutter_width,
                .ranges = row.ranges,
            };
            // Every hunk is a new file: the highlighter's state does not
            // cross from one hunk to the next.
            if (row.kind == .hunk) {
                diff_ctx.new_state = .{};
                diff_ctx.old_state = .{};
            }
            try inline_lines.append(arena, try inlineSegmentsLang(arena, line, kind, base_override, mood_style, diff_lang, &diff_ctx));
            continue;
        }

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

        // ── a table ──
        //
        // A header line followed by its separator is a table, and it is NOT
        // prose: `| a | b |` painted as prose is a row of pipes that the
        // reader has to decode. The table is a BLOCK of its own (the borders
        // are not prose), but it is painted like text: the TUI only treats a
        // `.code` block specially.
        //
        // The banner is a drawing, not prose: do not look for structure in it.
        if (kind != .banner) {
            if (try tableAt(arena, src_lines.items, idx)) |tbl| {
                // The pending text closes first: the table is its own block.
                if (inline_lines.items.len > 0) {
                    try blocks.append(arena, .{
                        .kind = kind,
                        .lines = try inline_lines.toOwnedSlice(arena),
                    });
                    inline_lines = .empty;
                }
                const table_lines = try renderTable(arena, kind, base_override, mood_style, tbl, opts.width);
                try blocks.append(arena, .{
                    .kind = kind,
                    .lines = table_lines,
                });
                // The table used the header, the separator and every body row.
                idx = tbl.last_line;
                continue;
            }
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
                    // Air BEFORE the heading: a title glued to the paragraph above
                    // it is not a title. Only inside the paragraph, so the layout
                    // does not add a second one at the top.
                    if (inline_lines.items.len > 0) {
                        const blank = try arena.alloc(Segment, 1);
                        blank[0] = .{ .text = "", .style = styles.heading };
                        try inline_lines.append(arena, blank);
                    }
                    try inline_lines.append(arena, segs);
                    continue;
                }
            }
        }

        // A quote, a bullet, a numbered item: the MARKER becomes its own styled
        // segment and the body goes through the normal inline pass.
        //
        // Before, all of these came out as the literal characters the model typed,
        // in the base style: `- **Step 1** …` looked like prose that happened to
        // start with a hyphen, and `> note` looked like prose that happened to
        // start with an angle bracket. For an agent whose answers ARE step lists,
        // that is the difference between a shape you can scan and a wall.
        const marker = if (kind != .banner) listMarker(line) else null;
        if (marker) |m| {
            var segs = try arena.alloc(Segment, 0);
            if (m.indent > 0) {
                const pad = try arena.alloc(u8, m.indent);
                @memset(pad, ' ');
                segs = try appendSeg(arena, segs, .{ .text = pad, .style = base_override orelse styles.asst_text });
            }
            segs = try appendSeg(arena, segs, .{ .text = m.marker, .style = styles.bullet });
            const body = try inlineSegmentsLang(arena, m.body, kind, base_override, mood_style, "", null);
            for (body) |sg| segs = try appendSeg(arena, segs, sg);
            try inline_lines.append(arena, segs);
            continue;
        }
        if (kind != .banner and line.len > 0 and line[0] == '>') {
            var segs = try arena.alloc(Segment, 0);
            segs = try appendSeg(arena, segs, .{ .text = "│ ", .style = styles.quote_bar });
            const body = try inlineSegmentsLang(arena, std.mem.trim(u8, line[1..], " "), kind, base_override, mood_style, "", null);
            for (body) |sg| segs = try appendSeg(arena, segs, sg);
            try inline_lines.append(arena, segs);
            continue;
        }

        try inline_lines.append(arena, try inlineSegmentsLang(arena, line, kind, base_override, mood_style, "", null));
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

const Marker = struct {
    /// The indentation the model typed, in columns (2 per level is the norm).
    indent: usize,
    /// The normalized marker, already padded: `"• "` or `"3. "`.
    marker: []const u8,
    ordered: bool,
    /// The text after the marker.
    body: []const u8,
};

/// Is this line a list item? If so, where does its content start.
///
/// `-`, `*` and `+` all become `•` and `N.` keeps its number, so the same list
/// looks the same whoever wrote it. The indent is preserved as indentation: a
/// nested step has to LOOK nested.
fn listMarker(line: []const u8) ?Marker {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    if (i >= line.len) return null;
    const rest = line[i..];

    var digit_end: usize = 0;
    while (digit_end < rest.len and std.ascii.isDigit(rest[digit_end])) digit_end += 1;

    const indent = @min(i, 12); // more than that is not a nesting level
    // `- item` / `* item` / `+ item`
    if (rest.len >= 2 and (rest[0] == '-' or rest[0] == '*' or rest[0] == '+') and rest[1] == ' ') {
        return .{
            .indent = indent,
            .marker = "• ",
            .ordered = false,
            .body = std.mem.trim(u8, rest[2..], " "),
        };
    }
    // `7. item` / `7) item`: both spellings are in wide use, and only handling
    // one of them left half the numbered lists in the answers as prose.
    if (digit_end >= 1 and digit_end + 1 < rest.len and
        (rest[digit_end] == '.' or rest[digit_end] == ')') and rest[digit_end + 1] == ' ')
    {
        return .{
            .indent = indent,
            .marker = rest[0 .. digit_end + 2],
            .ordered = true,
            .body = std.mem.trim(u8, rest[digit_end + 2 ..], " "),
        };
    }
    return null;
}

fn appendSeg(arena: std.mem.Allocator, segs: []const Segment, seg: Segment) ![]Segment {
    const out = try arena.alloc(Segment, segs.len + 1);
    @memcpy(out[0..segs.len], segs);
    out[segs.len] = seg;
    return out;
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

/// One unified diff row: the gutter, the marker, the body.
///
/// Before it was a SINGLE segment for the whole line with `diff_add`, which is a
/// solid green (#00cd00). Writing a 200-line file gave 200 flat green rows: you
/// could not tell a string from a number from a type, and on top of that that
/// green was the SAME one used for code strings (`highlight.zig`), so "green"
/// did not mean anything.
///
/// Now the `+`/`-`/` ` marker goes with its own color and the body goes through
/// the highlighter with `lang`, which is what makes a diff readable: numbers
/// look like numbers and Pascal identifiers look like types.
///
/// Three things were added on top of that, and the three are what a diff is
/// actually FOR:
///
///   - the GUTTER: the line number of every row, so the change can be found in
///     the file. It is the number of the line in the NEW file, and the OLD
///     one for a deletion.
///   - the BACKGROUND: an added row is a band and a deleted row is another
///     band. A foreground alone is not a diff: `+ line` and `- line` have to
///     read as two BANDS, and a band is a background.
///   - the WORD diff: the words that changed inside a row get a stronger
///     background, so the reader sees WHAT changed and not only THAT
///     something changed.
fn diffSegments(
    arena: std.mem.Allocator,
    line: []const u8,
    lang: []const u8,
    ctx: *DiffCtx,
) ![]Segment {
    const row = ctx.row;
    if (line.len == 0) {
        const segs = try arena.alloc(Segment, 1);
        segs[0] = .{ .text = line, .style = theme.diff_ctx };
        return segs;
    }

    // `@@ … @@` is a hunk header, not code: entirely in the hunk color.
    if (line[0] == '@') {
        const segs = try arena.alloc(Segment, 1);
        segs[0] = .{ .text = line, .style = theme.diff_hunk };
        return segs;
    }

    const is_add = line[0] == '+';
    const is_del = line[0] == '-';
    const is_ctx = line[0] == ' ';

    // The tint of the WHOLE row. A context row has none: the tints mark what
    // CHANGED, and a tinted context row means every row of a hunk is tinted,
    // which is a wall with no shape.
    const line_bg: ?vaxis.Color = if (is_add)
        bgOf(theme.diffAddLineBg())
    else if (is_del)
        bgOf(theme.diffDelLineBg())
    else
        null;

    var out: std.ArrayList(Segment) = .empty;

    // ── the gutter ──
    //
    // The number, right-aligned in the hunk's width, and a space. A row
    // without a number (the preview's own header) gets the same columns in
    // blank, so the code of the whole diff stays in one column.
    if (row.gutter_width > 0) {
        const num = if (row.number) |n| try std.fmt.allocPrint(arena, "{d}", .{n}) else "";
        const pad = row.gutter_width -| num.len;
        const cell = try arena.alloc(u8, pad + num.len);
        @memset(cell[0..pad], ' ');
        @memcpy(cell[pad..], num);
        try out.append(arena, .{ .text = cell, .style = withBg(theme.diff_gutter, line_bg) });
        try out.append(arena, .{ .text = " ", .style = withBg(theme.diff_gutter, line_bg) });
    }

    // ── the marker ──
    //
    // The context space is NOT included in the body that goes to the
    // highlighter: otherwise the language would recognize nothing until the
    // first real character.
    const lead: usize = if (is_add or is_del or is_ctx) 1 else 0;
    if (lead > 0) {
        const marker: Style = if (is_add)
            withBg(theme.diffAdd(), line_bg)
        else if (is_del)
            withBg(theme.diffDel(), line_bg)
        else
            withBg(theme.diff_ctx, line_bg);
        try out.append(arena, .{ .text = line[0..lead], .style = marker });
    }

    // ── the body ──
    const body = line[lead..];
    if (body.len > 0) {
        // The state of the file this row belongs to: a `-` row is a line of
        // the OLD file and a `+` row is a line of the NEW one.
        const state = if (is_del) &ctx.old_state else &ctx.new_state;
        const toks = try hl.highlightLineState(arena, body, lang, state);
        // A context row is the same line in both files: from here the two
        // states move together.
        if (is_ctx) ctx.old_state = ctx.new_state;

        const word_bg: ?vaxis.Color = if (is_add)
            bgOf(theme.diffAddBg())
        else if (is_del)
            bgOf(theme.diffDelBg())
        else
            null;

        var body_off: usize = 0;
        for (toks) |t| {
            const seg_start = body_off;
            body_off += t.text.len;
            // A context row is dim grey: it is the row that did NOT change,
            // and it must not compete with the ones that did.
            var st: Style = if (is_ctx) theme.diff_ctx else t.style;
            st = withBg(st, line_bg);
            if (row.ranges.len > 0) {
                try splitByRanges(arena, &out, t.text, st, seg_start, row.ranges, word_bg);
            } else {
                try out.append(arena, .{ .text = t.text, .style = st });
            }
        }
    }
    return out.toOwnedSlice(arena);
}

/// Splits a segment at the boundaries of the changed ranges.
///
/// The ranges are byte ranges in the BODY of the row and the segment is one
/// piece of that body, so `seg_start` is where the segment begins inside it.
fn splitByRanges(
    arena: std.mem.Allocator,
    out: *std.ArrayList(Segment),
    text: []const u8,
    style: Style,
    seg_start: usize,
    ranges: []const diff_tokenizer.DiffRange,
    word_bg: ?vaxis.Color,
) !void {
    var pos: usize = 0;
    var ri: usize = 0;
    while (ri < ranges.len and ranges[ri].end <= seg_start) ri += 1;
    while (pos < text.len) {
        const abs = seg_start + pos;
        while (ri < ranges.len and ranges[ri].end <= abs) ri += 1;
        const inside = ri < ranges.len and ranges[ri].start <= abs and abs < ranges[ri].end;
        var end = text.len;
        if (inside) {
            end = @min(ranges[ri].end -| seg_start, text.len);
        } else if (ri < ranges.len and ranges[ri].start > abs) {
            end = @min(ranges[ri].start -| seg_start, text.len);
        }
        if (end <= pos) end = pos + 1;
        const st = if (inside) changedStyle(style, word_bg) else style;
        try out.append(arena, .{ .text = text[pos..end], .style = st });
        pos = end;
    }
}

/// The style of the CHANGED WORDS.
///
/// With a background it is the background; with no color at all it is BOLD,
/// which is the only weight left to point at them.
fn changedStyle(base: Style, bg: ?vaxis.Color) Style {
    var s = base;
    if (bg) |c| {
        s.bg = c;
    } else {
        s.bold = true;
    }
    return s;
}

/// The background of a style, or null when it has none.
fn bgOf(st: Style) ?vaxis.Color {
    return switch (st.bg) {
        .default => null,
        else => |c| c,
    };
}

/// The style with a background, when it does not have one already.
fn withBg(st: Style, bg: ?vaxis.Color) Style {
    const b = bg orelse return st;
    if (st.bg != .default) return st;
    var s = st;
    s.bg = b;
    return s;
}

/// Line cap per file for the diff.
///
/// `unifiedDiff` is line-wise LCS O(n·m) and the table is (n+1)·(m+1) `usize`: a
/// pair of 10 000-line files is 800 MB of table. Above this cap the diff is not
/// computed: a notice is shown instead. That is degradation, not an error.
pub const max_diff_lines = 2000;

/// Context lines kept around each change.
pub const diff_context_lines = 4;

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
    return inlineSegmentsLang(arena, line, kind, base_override, mood_style, "", null);
}

/// Like `inlineSegmentsBase` but with the line's LANGUAGE.
///
/// Needed for the diff: the marker goes with its own color and the body is
/// tokenized as code, so you have to know which file being edited
/// is in. For the other kinds the language does not matter.
///
/// `diff` is the context of a diff ROW: the line number, the gutter width and
/// the words that changed. It is null for every other kind.
pub fn inlineSegmentsLang(
    arena: std.mem.Allocator,
    line: []const u8,
    kind: Kind,
    base_override: ?Style,
    mood_style: ?Style,
    lang: []const u8,
    diff: ?*DiffCtx,
) ![]Segment {
    if (kind == .diff) {
        var empty = DiffCtx{};
        return diffSegments(arena, line, lang, diff orelse &empty);
    }

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
///
/// # The vocabulary
///
/// There are FIVE marks in this UI and every one of them is in this function.
/// That is the whole rule: a reader learns the screen by learning five glyphs,
/// and a sixth one added "because this case is different" is a sixth thing to
/// learn for no gain.
///
/// | mark | meaning | why this glyph |
/// |---|---|---|
/// | `›` | you | the only thing in the accent color, so it is always findable |
/// | `●` | a tool ran | a filled dot reads as "something happened here" |
/// | `│` | its output | a rail ties a body to the call above it |
/// | `└` | the body's end | the elbow: this is the bottom of it |
/// | `✗` | it failed | the one glyph nobody misreads |
/// | `·` | a notice | the smallest thing on screen, and the smallest thing it says |
///
/// The one that is GONE is `◆`, the assistant's bullet. It was the loudest
/// mark in the transcript and it marked the least remarkable thing in it:
/// prose. The model's own words are not chrome, and removing the glyph is
/// what let the accent mean exactly one thing — "this is yours".
pub fn prefix(kind: Kind) struct { text: []const u8, style: Style } {
    return switch (kind) {
        .user => .{ .text = "› ", .style = styles.user_prefix },
        // No mark at all. The prose starts at the margin and its first word is
        // in `ink`, which is the loudest thing a paragraph should be.
        .assistant => .{ .text = "", .style = styles.asst_prefix },
        .info => .{ .text = "· ", .style = styles.info },
        .tool => .{ .text = "● ", .style = styles.tool_bold },
        .tool_run => .{ .text = "● ", .style = styles.tool_bold },
        .tool_res => .{ .text = "│ ", .style = styles.tool_res },
        .diff => .{ .text = "", .style = styles.diff_ctx },
        .error_msg => .{ .text = "✗ ", .style = styles.err },
        .banner => .{ .text = "", .style = styles.banner },
        else => .{ .text = "  ", .style = styles.info },
    };
}

// ── tables ───────────────────────────────────────────────────────────────────

/// A table read from the text: the header cells and the body rows.
const Table = struct {
    headers: [][]const u8,
    rows: [][][]const u8,
    ncols: usize,
    /// The index of the LAST line the table used: the separator, or the last
    /// body row.
    last_line: usize,
};

/// The narrowest a column can be: one column of content.
const min_col_width = 1;

/// The width of a cell that is wider than any column when the caller does
/// not know the terminal's width.
const default_cell_width = 40;

/// The columns of the box that are NOT content: the borders and the space on
/// each side of every cell.
fn tableOverhead(ncols: usize) usize {
    return 3 * ncols + 1;
}

/// The narrowest a table of `ncols` columns can be: every column at one
/// column of content, plus the box.
fn minTableWidth(ncols: usize) usize {
    return 4 * ncols + 1;
}

/// Reads the table that starts at `lines[i]`, if there is one.
///
/// A table is a header line (it starts with a pipe) followed by a SEPARATOR
/// line (every cell is dashes and maybe colons), and then every line that
/// starts with a pipe is a body row.
///
/// The separator is what makes it a table: a line that starts with a pipe and
/// has no separator after it is prose, and a single line of pipes is not a
/// table either.
fn tableAt(arena: std.mem.Allocator, lines: []const []const u8, i: usize) !?Table {
    if (i + 1 >= lines.len) return null;

    const header_line = std.mem.trimStart(u8, lines[i], " \t");
    if (header_line.len == 0 or header_line[0] != '|') return null;

    const headers = try splitRowCells(arena, header_line);
    // One column is not a table: it is a line that happens to have a pipe.
    if (headers.len < 2) return null;

    const sep = try splitRowCells(arena, lines[i + 1]);
    if (sep.len != headers.len) return null;
    if (!isSeparatorCells(sep)) return null;

    var rows: std.ArrayList([][]const u8) = .empty;
    var ncols = headers.len;
    var j = i + 2;
    while (j < lines.len) : (j += 1) {
        const l = std.mem.trimStart(u8, lines[j], " \t");
        if (l.len == 0 or l[0] != '|') break;
        const cells = try splitRowCells(arena, l);
        // A row with MORE cells than the header gets its own column: the
        // extra cell's text would be lost otherwise, and nothing may be lost.
        if (cells.len > ncols) ncols = cells.len;
        try rows.append(arena, cells);
    }

    // Every row is padded to the number of columns, so the rendering can
    // assume the same shape everywhere.
    const padded_rows = try arena.alloc([][]const u8, rows.items.len);
    for (rows.items, 0..) |r, k| {
        const pr = try arena.alloc([]const u8, ncols);
        for (pr, 0..) |*c, ci| c.* = if (ci < r.len) r[ci] else "";
        padded_rows[k] = pr;
    }
    const hdr = try arena.alloc([]const u8, ncols);
    for (hdr, 0..) |*c, ci| c.* = if (ci < headers.len) headers[ci] else "";

    return Table{
        .headers = hdr,
        .rows = padded_rows,
        .ncols = ncols,
        .last_line = j - 1,
    };
}

/// Splits a table row into its cells.
///
/// A `\|` is a LITERAL pipe: without this a cell that contains one (a table
/// of file paths, a command line) is split in two and the row has one cell
/// too many.
fn splitRowCells(arena: std.mem.Allocator, line: []const u8) ![][]const u8 {
    const t = std.mem.trim(u8, line, " \t");
    var cells: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    if (t.len > 0 and t[0] == '|') i = 1;
    var cell_start = i;
    var has_escape = false;
    var ended_with_pipe = false;
    while (i < t.len) {
        const c = t[i];
        if (c == '\\' and i + 1 < t.len and t[i + 1] == '|') {
            has_escape = true;
            ended_with_pipe = false;
            i += 2;
            continue;
        }
        if (c == '|') {
            try cells.append(arena, try cellText(arena, t[cell_start..i], has_escape));
            has_escape = false;
            cell_start = i + 1;
            ended_with_pipe = true;
            i += 1;
            continue;
        }
        ended_with_pipe = false;
        i += 1;
    }
    // A row that ends with a pipe does not have a cell after it.
    if (!ended_with_pipe) {
        try cells.append(arena, try cellText(arena, t[cell_start..], has_escape));
    }
    return cells.toOwnedSlice(arena);
}

/// The text of a cell: trimmed, and with the escaped pipes unescaped.
fn cellText(arena: std.mem.Allocator, raw: []const u8, has_escape: bool) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (!has_escape) return trimmed;
    const out = try arena.alloc(u8, trimmed.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < trimmed.len) {
        if (trimmed[i] == '\\' and i + 1 < trimmed.len and trimmed[i + 1] == '|') {
            out[n] = '|';
            n += 1;
            i += 2;
            continue;
        }
        out[n] = trimmed[i];
        n += 1;
        i += 1;
    }
    return out[0..n];
}

/// Is this the separator row of a table (`|---|---|`, `|:---|---:|`, …)?
fn isSeparatorCells(cells: []const []const u8) bool {
    if (cells.len == 0) return false;
    for (cells) |c| {
        if (!isDashCell(c)) return false;
    }
    return true;
}

/// One cell of a separator: dashes, with an optional colon on each side (the
/// alignment markers).
fn isDashCell(c: []const u8) bool {
    var s = std.mem.trim(u8, c, " \t");
    if (s.len > 0 and s[0] == ':') s = s[1..];
    if (s.len > 0 and s[s.len - 1] == ':') s = s[0 .. s.len - 1];
    if (s.len == 0) return false;
    for (s) |ch| {
        if (ch != '-') return false;
    }
    return true;
}

/// The natural width of every column: the widest cell in it.
fn naturalWidths(arena: std.mem.Allocator, table: Table) ![]usize {
    const widths = try arena.alloc(usize, table.ncols);
    for (widths) |*w| w.* = 0;
    for (table.headers, 0..) |c, k| {
        widths[k] = @max(widths[k], textWidth(c));
    }
    for (table.rows) |row| {
        for (row, 0..) |c, k| {
            widths[k] = @max(widths[k], textWidth(c));
        }
    }
    return widths;
}

/// Shrinks the columns until they fit in `budget` columns of content.
///
/// Proportionally first, so a very wide column does not eat everything, and
/// then one column at a time from the widest, which is what "the widest
/// first" means: the reduction lands where there is room to take it.
///
/// The columns never go below `min_col_width`, and the caller has already
/// checked that the budget is at least one column per column.
fn shrinkColumns(widths: []usize, budget: usize) void {
    var total: usize = 0;
    for (widths) |w| total += w;
    if (total <= budget) return;

    for (widths) |*w| {
        const scaled = (w.* * budget) / total;
        w.* = @max(scaled, min_col_width);
    }
    total = 0;
    for (widths) |w| total += w;

    // The floor of the proportional step can leave it over the budget.
    while (total > budget) {
        const k = widestColumn(widths);
        if (widths[k] <= min_col_width) break;
        widths[k] -= 1;
        total -= 1;
    }
    // And the floor can leave room under it: give it back to the widest.
    while (total < budget) {
        const k = widestColumn(widths);
        widths[k] += 1;
        total += 1;
    }
}

/// The index of the widest column (the leftmost one when they tie).
fn widestColumn(widths: []const usize) usize {
    var best: usize = 0;
    for (widths, 0..) |w, k| {
        if (w > widths[best]) best = k;
    }
    return best;
}

/// Renders the table as a box of lines.
fn renderTable(
    arena: std.mem.Allocator,
    kind: Kind,
    base_override: ?Style,
    mood_style: ?Style,
    table: Table,
    width: u16,
) ![]const []const Segment {
    const widths = try naturalWidths(arena, table);

    if (width > 0) {
        const budget: usize = width;
        // It does not fit at all: not even with every column at ONE column.
        // Then it is not a table any more: it is a list of rows.
        if (budget < minTableWidth(table.ncols)) {
            return renderDegraded(arena, kind, base_override, mood_style, table);
        }
        const content = budget - tableOverhead(table.ncols);
        shrinkColumns(widths, content);
    } else {
        // No width known: the columns keep their natural width, but a cell
        // wider than `default_cell_width` is wrapped onto more lines inside
        // its cell instead of becoming a 400-column line.
        for (widths) |*w| w.* = @min(w.*, default_cell_width);
    }

    var out: std.ArrayList([]const Segment) = .empty;
    try out.append(arena, try borderLine(arena, widths, "┌", "┬", "┐"));
    try appendRow(arena, &out, kind, base_override, mood_style, table.headers, widths, true);
    if (table.rows.len > 0) {
        try out.append(arena, try borderLine(arena, widths, "├", "┼", "┤"));
        for (table.rows) |row| {
            try appendRow(arena, &out, kind, base_override, mood_style, row, widths, false);
        }
    }
    try out.append(arena, try borderLine(arena, widths, "└", "┴", "┘"));
    return out.toOwnedSlice(arena);
}

/// One of the three horizontal borders of the box.
fn borderLine(
    arena: std.mem.Allocator,
    widths: []const usize,
    left: []const u8,
    mid: []const u8,
    right: []const u8,
) ![]const Segment {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, left);
    for (widths, 0..) |w, k| {
        if (k > 0) try buf.appendSlice(arena, mid);
        var i: usize = 0;
        while (i < w + 2) : (i += 1) try buf.appendSlice(arena, "─");
    }
    try buf.appendSlice(arena, right);
    const segs = try arena.alloc(Segment, 1);
    segs[0] = .{ .text = buf.items, .style = theme.table };
    return segs;
}

/// Appends the lines of one row (a header or a body row).
///
/// A row can be TALLER than one line: a cell that does not fit in its column
/// is wrapped onto more lines, and the other cells of the row leave that
/// space empty.
fn appendRow(
    arena: std.mem.Allocator,
    out: *std.ArrayList([]const Segment),
    kind: Kind,
    base_override: ?Style,
    mood_style: ?Style,
    cells: []const []const u8,
    widths: []const usize,
    header: bool,
) !void {
    const base = base_override orelse baseStyle(kind);
    var cell_lines: std.ArrayList([]const []const Segment) = .empty;
    var height: usize = 0;
    for (cells, 0..) |c, k| {
        const segs = try inlineSegmentsLang(arena, c, kind, base_override, mood_style, "", null);
        if (header) {
            // The header is the row the reader scans: it is bold.
            for (segs) |*s| s.style = boldStyle(s.style, base);
        }
        const lines = try cellLines(arena, segs, widths[k]);
        height = @max(height, lines.len);
        try cell_lines.append(arena, lines);
    }

    var i: usize = 0;
    while (i < height) : (i += 1) {
        var segs: std.ArrayList(Segment) = .empty;
        for (cell_lines.items, 0..) |cl, k| {
            try segs.append(arena, .{ .text = "│", .style = theme.table });
            try segs.append(arena, .{ .text = " ", .style = base });
            var used: usize = 0;
            if (i < cl.len) {
                for (cl[i]) |s| {
                    try segs.append(arena, s);
                    used += textWidth(s.text);
                }
            }
            const pad = widths[k] -| used;
            if (pad > 0) {
                try segs.append(arena, .{ .text = try spaces(arena, pad), .style = base });
            }
            try segs.append(arena, .{ .text = " ", .style = base });
        }
        try segs.append(arena, .{ .text = "│", .style = theme.table });
        try out.append(arena, try segs.toOwnedSlice(arena));
    }
}

/// The lines of one cell, wrapped to `width` columns.
///
/// The wrapping is done on the SEGMENTS and not on the text: a cell that is
/// half bold is wrapped without losing the bold, and the padding is computed
/// on what is actually painted.
fn cellLines(arena: std.mem.Allocator, segs: []const Segment, width: usize) ![][]const Segment {
    const w = @max(width, 1);
    var out: std.ArrayList([]const Segment) = .empty;
    var cur: std.ArrayList(Segment) = .empty;
    var col: usize = 0;

    for (segs) |sg| {
        var text = sg.text;
        while (text.len > 0) {
            const tw = textWidth(text);
            if (col + tw <= w) {
                // `text` and not `sg`: after a split this is the REMAINDER of
                // the segment, and appending the segment would put the whole
                // text back into the line that was just closed.
                try cur.append(arena, .{ .text = text, .style = sg.style });
                col += tw;
                break;
            }
            if (col > 0) {
                // The line is full: close it and start the next one with
                // this segment.
                try out.append(arena, try cur.toOwnedSlice(arena));
                cur = .empty;
                col = 0;
                continue;
            }
            // The segment does not fit even in an empty line: split it.
            const take = fitPrefix(text, w);
            var brk: usize = 0;
            var k = @min(take, text.len - 1);
            while (k > 0) : (k -= 1) {
                if (text[k] == ' ') {
                    brk = k;
                    break;
                }
            }
            const cut = if (brk > 0) brk else take;
            try cur.append(arena, .{ .text = text[0..cut], .style = sg.style });
            try out.append(arena, try cur.toOwnedSlice(arena));
            cur = .empty;
            col = 0;
            text = text[cut..];
            // The space the line broke at is not repeated at the start of
            // the next one.
            if (brk > 0 and text.len > 0 and text[0] == ' ') text = text[1..];
        }
    }
    try out.append(arena, try cur.toOwnedSlice(arena));
    return out.toOwnedSlice(arena);
}

/// The table as a list of rows, for a table that does not fit.
///
/// `Name: value · Other: value` is readable where a squeezed box is not, and
/// it loses nothing: every cell is there.
fn renderDegraded(
    arena: std.mem.Allocator,
    kind: Kind,
    base_override: ?Style,
    mood_style: ?Style,
    table: Table,
) ![]const []const Segment {
    const base = base_override orelse baseStyle(kind);
    var out: std.ArrayList([]const Segment) = .empty;

    if (table.rows.len == 0) {
        var segs: std.ArrayList(Segment) = .empty;
        for (table.headers, 0..) |h, k| {
            if (k > 0) try segs.append(arena, .{ .text = " · ", .style = base });
            for (try inlineSegmentsLang(arena, h, kind, base_override, mood_style, "", null)) |s| {
                try segs.append(arena, .{ .text = s.text, .style = boldStyle(s.style, base) });
            }
        }
        try out.append(arena, try segs.toOwnedSlice(arena));
        return out.toOwnedSlice(arena);
    }

    for (table.rows) |row| {
        var segs: std.ArrayList(Segment) = .empty;
        for (table.headers, 0..) |h, k| {
            if (k > 0) try segs.append(arena, .{ .text = " · ", .style = base });
            for (try inlineSegmentsLang(arena, h, kind, base_override, mood_style, "", null)) |s| {
                try segs.append(arena, .{ .text = s.text, .style = boldStyle(s.style, base) });
            }
            try segs.append(arena, .{ .text = ": ", .style = base });
            for (try inlineSegmentsLang(arena, row[k], kind, base_override, mood_style, "", null)) |s| {
                try segs.append(arena, s);
            }
        }
        try out.append(arena, try segs.toOwnedSlice(arena));
    }
    return out.toOwnedSlice(arena);
}

/// A style in bold, keeping its color, and taking the base's color when it
/// has none.
fn boldStyle(st: Style, base: Style) Style {
    var s = st;
    s.bold = true;
    if (s.fg == .default) s.fg = base.fg;
    return s;
}

/// `n` spaces.
fn spaces(arena: std.mem.Allocator, n: usize) ![]const u8 {
    const buf = try arena.alloc(u8, n);
    @memset(buf, ' ');
    return buf;
}

/// How many bytes of `text` fit in `avail` columns.
fn fitPrefix(text: []const u8, avail: usize) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const cw = codepointWidthAt(text, i);
        if (w + cw > avail) break;
        w += cw;
        i += len;
    }
    if (i == 0 and text.len > 0) {
        // The first character does not fit even in an empty line: take it
        // anyway, or the wrap would not make progress.
        return std.unicode.utf8ByteSequenceLength(text[0]) catch 1;
    }
    return i;
}

/// The columns a piece of text takes.
///
/// The table's cells are padded to a width in COLUMNS, not in bytes: a CJK
/// character is two columns, and a byte count paints a table whose right
/// border does not line up.
pub fn textWidth(text: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        w += codepointWidthAt(text, i);
        i += len;
    }
    return w;
}

/// The columns the character at `i` takes.
fn codepointWidthAt(text: []const u8, i: usize) usize {
    const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
    const end = @min(i + len, text.len);
    const cp = std.unicode.utf8Decode(text[i..end]) catch return 1;
    return codepointWidth(cp);
}

/// The columns one codepoint takes.
///
/// The East Asian Wide and Fullwidth ranges are two columns, and the
/// combining marks ride on the character before them.
fn codepointWidth(cp: u21) usize {
    if (cp >= 0x0300 and cp <= 0x036f) return 0;
    if (cp >= 0x1100 and cp <= 0x115f) return 2;
    if (cp >= 0x2e80 and cp <= 0x303e) return 2;
    if (cp >= 0x3041 and cp <= 0x33ff) return 2;
    if (cp >= 0x3400 and cp <= 0x4dbf) return 2;
    if (cp >= 0x4e00 and cp <= 0x9fff) return 2;
    if (cp >= 0xa000 and cp <= 0xa4cf) return 2;
    if (cp >= 0xac00 and cp <= 0xd7a3) return 2;
    if (cp >= 0xf900 and cp <= 0xfaff) return 2;
    if (cp >= 0xfe30 and cp <= 0xfe6f) return 2;
    if (cp >= 0xff00 and cp <= 0xff60) return 2;
    if (cp >= 0xffe0 and cp <= 0xffe6) return 2;
    if (cp >= 0x1f300 and cp <= 0x1f9ff) return 2;
    if (cp >= 0x20000 and cp <= 0x3fffd) return 2;
    return 1;
}

// basic test
test "basic markdown parse" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const blocks = try parse(arena, .assistant, "# Titulo\nHola **mundo** con `code`\n```zig\nconst x = 1;\n```\nfin");
    // block 1: heading + inline line (2 lines)
    try std.testing.expect(blocks.len >= 3);
    try std.testing.expectEqual(Kind.code, blocks[1].kind);
}

test "unifiedDiff: simple change, with a hunk header" {
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

test "unifiedDiff: no changes produces no +/-" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // With no changes there is nothing to show: not even a hunk.
    const d = try unifiedDiff(arena, "igual\n", "igual\n");
    try std.testing.expectEqual(@as(usize, 0), d.len);
}

test "unifiedDiff: new lines at the end" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try unifiedDiff(arena, "a\n", "a\nb\nc\n");
    try std.testing.expectEqualStrings("@@ -1,1 +1,3 @@", d[0]);
    try std.testing.expectEqualStrings(" a", d[1]);
    try std.testing.expectEqualStrings("+b", d[2]);
    try std.testing.expectEqualStrings("+c", d[3]);
}

test "unifiedDiff: deletion" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try unifiedDiff(arena, "a\nb\nc\n", "a\nc\n");
    try std.testing.expectEqualStrings("@@ -1,3 +1,2 @@", d[0]);
    try std.testing.expectEqualStrings(" a", d[1]);
    try std.testing.expectEqualStrings("-b", d[2]);
    try std.testing.expectEqualStrings(" c", d[3]);
}

test "diffSegments: the prefix gets its color and the body BY TOKENS" {
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

test "a + line of the diff carries tokens, not a green segment" {
    // The green wall: `+const n: u32 = 42` was ONE segment with `diff_add`. Now
    // the prefix goes with its own color and the body is tokenized, so `const`
    // is a keyword, `u32` a type and `42` a number. That is what makes a diff
    // readable without opening the file.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const segs = try inlineSegmentsLang(arena, "+const n: u32 = 42", .diff, null, null, "zig", null);
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

test "the diff with an unknown language comes out plain but keeps the prefix" {
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

test "a banner starting with ## is NOT eaten as a heading" {
    // The banner art uses `#` as fill and ALL of its rows start with `##`, so
    // the parser interpreted them as markdown headings and returned
    // "####  ####  *zode*" instead of the whole drawing. The banner is a
    // drawing, not prose: do not look for structure in it.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const blocks = try parseBase(arena, .banner, "######  ####   ######\n##  ## ##  ## ##    ", null, null, .{});
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    const segs = blocks[0].lines[0];
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    for (segs) |seg| try text.appendSlice(std.testing.allocator, seg.text);
    try std.testing.expectEqualStrings("######  ####   ######", text.items);

    // And the other kinds STILL interpret headings: the fix is for `.banner`,
    // not a general deactivation.
    const h = try parseBase(arena, .info, "## un titulo", null, null, .{});
    var ht: std.ArrayList(u8) = .empty;
    defer ht.deinit(std.testing.allocator);
    for (h[0].lines[0]) |seg| try ht.appendSlice(std.testing.allocator, seg.text);
    try std.testing.expectEqualStrings("un titulo", ht.items);
}

test "unifiedDiff: above the cap the LCS is not computed (it would be O(n*m))" {
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

test "tool_res_bold is bold FOR REAL (the 'two tones' was not a no-op)" {
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

test "unifiedDiff: a small change in a large file does NOT dump the whole file" {
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
    // A single hunk: header + 4 context lines + 1 '-' change + 1 '+' + 4 context lines.
    // The 4 is `diff_context_lines`: the test follows the constant, because a
    // hunk's size is exactly that number and pinning "9" would pin a value
    // that only ever described one setting.
    try std.testing.expectEqual(@as(usize, 1 + 4 + 1 + 1 + 4), d.len);
    try std.testing.expectEqualStrings("@@ -27,9 +27,9 @@", d[0]);
    try std.testing.expectEqualStrings("-linea 30", d[5]);
    try std.testing.expectEqualStrings("+linea 999", d[6]);
    // And the rest of the file does NOT come out.
    for (d) |l| {
        try std.testing.expect(std.mem.indexOf(u8, l, "linea 0") == null or
            std.mem.startsWith(u8, l, " ") or std.mem.startsWith(u8, l, "-") and l.len < 12);
    }
}

test "unifiedDiff: two distant changes give two hunks with an ellipsis in between" {
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

test "unifiedDiff: no changes returns empty (not a context hunk)" {
    // `pushDiff` already filtered this on its own, but it is better for the
    // function to invent nothing: a context-only hunk would be noise in the
    // history.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try unifiedDiff(arena, "a\nb\nc\n", "a\nb\nc\n");
    try std.testing.expectEqual(@as(usize, 0), d.len);
}

test "list markers become a colored bullet and keep the nesting as indent" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const blocks = try parse(a.allocator(), .assistant,
        \\- primero
        \\  - anidado
        \\7. numerado
        \\* con estrella
    );
    const segs = blocks[0].lines;
    try std.testing.expectEqual(@as(usize, 4), segs.len);

    // The marker is its OWN segment, in the bullet style: that is what makes a
    // list look like a list instead of like prose that starts with a hyphen.
    try std.testing.expectEqualStrings("• ", segs[0][0].text);
    try std.testing.expectEqual(styles.bullet, segs[0][0].style);
    try std.testing.expectEqualStrings("primero", segs[0][1].text);

    // Nested: two spaces of indent BEFORE the bullet, and the marker itself is
    // still a bullet.
    try std.testing.expectEqualStrings("  ", segs[1][0].text);
    try std.testing.expectEqualStrings("• ", segs[1][1].text);
    try std.testing.expectEqualStrings("anidado", segs[1][2].text);

    // Ordered keeps its number.
    try std.testing.expectEqualStrings("7. ", segs[2][0].text);
    try std.testing.expectEqualStrings("numerado", segs[2][1].text);
}

test "listMarker is not fooled by prose, a dash word or a lone dash" {
    try std.testing.expect(listMarker("hola") == null);
    try std.testing.expect(listMarker("-5 es un numero") == null); // no space after
    try std.testing.expect(listMarker("---") == null); // a rule, not an item
    try std.testing.expect(listMarker("a - b") == null); // not at the start
    try std.testing.expect(listMarker("") == null);
    try std.testing.expect(listMarker("- si") != null);
    try std.testing.expect(listMarker("1) si") != null);
}

test "a list keeps its bold and code inside the item" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const blocks = try parse(a.allocator(), .assistant, "- **fix** the `read` path");
    const segs = blocks[0].lines[0];
    var joined: [128]u8 = undefined;
    var n: usize = 0;
    for (segs) |sg| {
        if (n + sg.text.len > joined.len) break;
        @memcpy(joined[n .. n + sg.text.len], sg.text);
        n += sg.text.len;
    }
    // The invariant that must never break: the line is still the line.
    try std.testing.expectEqualStrings("• fix the read path", joined[0..n]);
}

test "a quote is a bar in its own style, not a stray angle bracket" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const blocks = try parse(a.allocator(), .assistant, "> esto es una cita");
    const segs = blocks[0].lines[0];
    try std.testing.expectEqualStrings("│ ", segs[0].text);
    try std.testing.expectEqual(styles.quote_bar, segs[0].style);
    var joined: [128]u8 = undefined;
    var n: usize = 0;
    for (segs) |sg| {
        if (n + sg.text.len > joined.len) break;
        @memcpy(joined[n .. n + sg.text.len], sg.text);
        n += sg.text.len;
    }
    try std.testing.expectEqualStrings("│ esto es una cita", joined[0..n]);
}

test "a heading gets an empty row in front of it (unless it opens the paragraph)" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    // Prose, then a heading: air before it, because a title glued to the
    // paragraph above is not a title.
    const mid = try parse(a.allocator(), .assistant, "algo\n## Titulo\nmas cosas");
    try std.testing.expectEqual(@as(usize, 4), mid[0].lines.len);
    try std.testing.expectEqualStrings("Titulo", mid[0].lines[2][0].text);

    // A heading that OPENS the paragraph gets no leading blank: it would push
    // the paragraph down one row for nothing.
    const first = try parse(a.allocator(), .assistant, "## Titulo\nmas cosas");
    try std.testing.expectEqual(@as(usize, 2), first[0].lines.len);
    try std.testing.expectEqualStrings("Titulo", first[0].lines[0][0].text);
}

test "the notice style is readable and NOT the tool-result gray" {
    // They were both `fg(8)` at ~2.8:1, so a notice and a tool result were the
    // same thing in a long history. Both now come from `theme.zig` and both are
    // above the contrast floor; the test is that they are still DIFFERENT, and
    // that "different" means different, not "one is a color and the other is
    // an index".
    try std.testing.expect(std.meta.activeTag(styles.info.fg) == .rgb);
    try std.testing.expect(std.meta.activeTag(styles.tool_res.fg) == .rgb);
    try std.testing.expect(!std.meta.eql(styles.info.fg.rgb, styles.tool_res.fg.rgb));

    // The floor itself, checked here and not only in `theme.zig`, because this
    // is the module that decides which style a NOTICE gets. A retheme that
    // forgot this file would pass the theme test and fail this one.
    const bg = [3]u8{ 0, 0, 0 };
    for ([_]Style{ styles.info, styles.tool_res }) |st| {
        const c = theme.contrast(theme.fgRgb(st).?, bg);
        if (c < 4.5) {
            std.debug.print("markdown style at {d:.2}:1 is unreadable\n", .{c});
            return error.MarkdownStyleUnreadable;
        }
    }
}

test "a markdown heading is not the diff hunk header" {
    // They shared one style, so `@@ -1,4 +1,6 @@` looked exactly like a
    // markdown heading: bold blue, same as the `›` of a user prompt.
    try std.testing.expect(std.meta.activeTag(styles.heading.fg) == .rgb);
    try std.testing.expect(std.meta.activeTag(styles.hunk.fg) == .rgb);
    try std.testing.expect(!std.meta.eql(styles.heading.fg.rgb, styles.hunk.fg.rgb));
}

test "the assistant's prose carries NO mark, and its color is ink and not the accent" {
    // The `◆` was the loudest glyph in the transcript and it marked the least
    // remarkable thing in it. Two separate decisions, asserted separately:
    // the MARK is gone, and the prose is not wearing the accent.
    //
    // The prose is `ink`, not the terminal's default color. `Style{}` used to
    // mean "whatever the terminal has", which on a light-background terminal is
    // black-on-white and on a dark one is "the brightest thing on screen" —
    // the reason `code_text` had to be pulled DOWN to `#a9b1d6`. Saying `ink`
    // makes the paragraph's color ours and stops it depending on the terminal's
    // idea of what normal text is.
    const p = prefix(.assistant);
    try std.testing.expectEqualStrings("", p.text);
    try std.testing.expectEqual(Style{}, p.style);
    try std.testing.expectEqual(theme.ink.fg, styles.asst_text.fg);
    // …and specifically NOT the accent: the green means "yours" and "live",
    // and if the model's prose were green too the accent would mean nothing.
    try std.testing.expect(!std.meta.eql(styles.asst_text.fg, theme.brand.fg));
    try std.testing.expect(!std.meta.eql(styles.asst_text.fg, theme.ink3.fg));
}

test "the transcript has five marks and not six" {
    // Every prefix the transcript can draw, collected. A new kind with a new
    // glyph has to be added to this list on purpose, which is the whole point:
    // the vocabulary is the interface, and it is the thing most likely to grow
    // by accident.
    const seen = [_]Kind{
        .user, .assistant, .info, .tool, .tool_run,
        .tool_res, .diff, .error_msg, .banner,
    };
    for (seen) |k| {
        const p = prefix(k);
        if (p.text.len > 0) {
            // Only the marks below are allowed. Anything else is a sixth glyph.
            const allowed = std.mem.eql(u8, p.text, "› ") or
                std.mem.eql(u8, p.text, "● ") or
                std.mem.eql(u8, p.text, "│ ") or
                std.mem.eql(u8, p.text, "✗ ") or
                std.mem.eql(u8, p.text, "· ") or
                std.mem.eql(u8, p.text, "  ");
            try std.testing.expect(allowed);
        }
    }
}

// ── the diff you can read ──────────────────────────────────────────────────────

test "the diff paints the line number in a gutter, right-aligned" {
    // The gutter is what turns a diff into something you can ACT on: the
    // change is a line of a file, and without the number the reader has to
    // count the rows to find it.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const diff =
        \\@@ -98,2 +98,2 @@
        \\ context
        \\+added
    ;
    const blocks = try parseLang(arena, .diff, diff, null, null, "", .{});
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    const rows = blocks[0].lines;
    try std.testing.expectEqual(@as(usize, 3), rows.len);

    // The hunk header has no number: it is a label, not a row of the file.
    try std.testing.expect(std.mem.startsWith(u8, rows[0][0].text, "@@"));

    // The context row: the number, right-aligned in the hunk's width (two
    // digits, because the hunk is at line 98), then the space, then the
    // marker.
    try std.testing.expectEqualStrings("98", rows[1][0].text);
    try std.testing.expectEqual(theme.diff_gutter.fg, rows[1][0].style.fg);
    try std.testing.expectEqualStrings(" ", rows[1][1].text);
    try std.testing.expectEqualStrings(" ", rows[1][2].text);

    // The added row is the next line of the NEW file.
    try std.testing.expectEqualStrings("99", rows[2][0].text);
}

test "the gutter is as wide as the hunk, and the next hunk gets its own" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const diff =
        \\@@ -1,2 +1,2 @@
        \\ one
        \\@@ -98,2 +98,2 @@
        \\ ninety
    ;
    const blocks = try parseLang(arena, .diff, diff, null, null, "", .{});
    const rows = blocks[0].lines;
    // The first hunk: one digit.
    try std.testing.expectEqualStrings("1", rows[1][0].text);
    // The second hunk: two, and the number is right-aligned in them.
    try std.testing.expectEqualStrings("98", rows[3][0].text);
}

test "the word diff paints the background on the changed words ONLY" {
    // The whole point of the word diff: the reader sees WHAT changed, and
    // not only THAT something changed on the row.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const diff =
        \\@@ -1,2 +1,2 @@
        \\-const x = 1;
        \\+const x = 42;
    ;
    const blocks = try parseLang(arena, .diff, diff, null, null, "zig", .{});
    const rows = blocks[0].lines;

    const added = rows[2];
    const changed = findDiffSeg(added, "42") orelse return error.TestUnexpectedResult;
    const same = findDiffSeg(added, "const") orelse return error.TestUnexpectedResult;

    // The changed words carry the diff's background...
    try std.testing.expectEqual(theme.diffAddBg().bg, changed.style.bg);
    // ...and the words that did not change carry the tint of the row, which
    // is a DIFFERENT background. Without the difference the word diff is
    // invisible: everything is green.
    try std.testing.expect(!vaxis.Style.eql(
        .{ .bg = theme.diffAddBg().bg },
        .{ .bg = theme.diffAddLineBg().bg },
    ));
    try std.testing.expectEqual(theme.diffAddLineBg().bg, same.style.bg);
}

test "the segments of a diffed row concatenate to the row" {
    // The invariant of the painter: nothing is lost and nothing is invented.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const diff =
        \\@@ -1,2 +1,2 @@
        \\-const x = 1;
        \\+const x = 42;
    ;
    const blocks = try parseLang(arena, .diff, diff, null, null, "zig", .{});
    const rows = blocks[0].lines;

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(std.testing.allocator);
    for (rows[2]) |sg| try joined.appendSlice(std.testing.allocator, sg.text);
    // The gutter, the space, the marker and the body.
    try std.testing.expect(std.mem.endsWith(u8, joined.items, "+const x = 42;"));
    // The added row is line 1 of the NEW file (the old line 1 was the one
    // that was deleted), and the gutter comes before the marker.
    try std.testing.expect(std.mem.startsWith(u8, joined.items, "1 +"));
}

test "a row of the diff is never read as a list item" {
    // A deleted line starts with "- " and the markdown parser read that as
    // a BULLET: the row came out as a list item with the diff's green, and
    // the `+`/`-` that says what happened was gone.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const diff =
        \\@@ -1,2 +1,2 @@
        \\- const x = 1;
    ;
    const blocks = try parseLang(arena, .diff, diff, null, null, "zig", .{});
    const rows = blocks[0].lines;
    // The marker is still there, and it is the diff's marker.
    try std.testing.expectEqualStrings("-", rows[1][2].text);
    try std.testing.expectEqual(theme.diffDel().fg, rows[1][2].style.fg);
}

test "with no color at all the diff still points at what changed" {
    // A terminal that asked for no color still gets a diff: the marker is
    // BOLD and the words that changed are BOLD. Without a color the sign is
    // the only thing left, and the changed words have to be pointed at with
    // the one thing that is left.
    const prev = theme.caps;
    defer theme.caps = prev;
    theme.caps = .{ .no_color = true };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const diff =
        \\@@ -1,2 +1,2 @@
        \\-const x = 1;
        \\+const x = 42;
    ;
    const blocks = try parseLang(arena, .diff, diff, null, null, "zig", .{});
    const rows = blocks[0].lines;

    // The marker: bold, and no color.
    const marker = rows[2][2];
    try std.testing.expect(marker.style.bold);
    try std.testing.expect(marker.style.fg == .default);

    // The words that changed: bold.
    const changed = findDiffSeg(rows[2], "42") orelse return error.TestUnexpectedResult;
    try std.testing.expect(changed.style.bold);

    // And the row has no background: there is nothing to tint it with.
    for (rows[2]) |sg| {
        try std.testing.expect(sg.style.bg == .default);
    }
}

// ── the tables ───────────────────────────────────────────────────────────────

/// The text of every line of a block, one string per line.
fn blockLines(arena: std.mem.Allocator, blk: Block) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (blk.lines) |line| {
        var buf: std.ArrayList(u8) = .empty;
        for (line) |seg| try buf.appendSlice(arena, seg.text);
        try out.append(arena, buf.items);
    }
    return out.items;
}

/// The whole block as one string, with a newline per line.
fn blockText(arena: std.mem.Allocator, blk: Block) ![]const u8 {
    const lines = try blockLines(arena, blk);
    var out: std.ArrayList(u8) = .empty;
    for (lines) |l| {
        try out.appendSlice(arena, l);
        try out.append(arena, '\n');
    }
    return out.items;
}

/// The text without the spaces: the padding and the wrapping do not count.
fn stripSpaces(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |c| {
        if (c != ' ' and c != '\t' and c != '\n') try out.append(arena, c);
    }
    return out.items;
}

/// Is `needle` a subsequence of `haystack`? (the order matters, the gaps do not)
fn isSubsequence(needle: []const u8, haystack: []const u8) bool {
    var i: usize = 0;
    for (haystack) |c| {
        if (i < needle.len and c == needle[i]) i += 1;
    }
    return i == needle.len;
}

test "a table is detected and painted as a box" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const blocks = try parse(arena, .assistant,
        \\| Name | Context |
        \\|---|---|
        \\| gpt | 200k |
    );
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    const lines = try blockLines(arena, blocks[0]);
    try std.testing.expectEqual(@as(usize, 5), lines.len);
    try std.testing.expectEqualStrings("┌──────┬─────────┐", lines[0]);
    try std.testing.expectEqualStrings("│ Name │ Context │", lines[1]);
    try std.testing.expectEqualStrings("├──────┼─────────┤", lines[2]);
    try std.testing.expectEqualStrings("│ gpt  │ 200k    │", lines[3]);
    try std.testing.expectEqualStrings("└──────┴─────────┘", lines[4]);
}

test "the column of a table is as wide as its widest cell" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    // The first column is `Name` (4) against `gpt` (3): the column is 4 and
    // the shorter cell is padded, not the column shrunk.
    const blocks = try parse(arena, .assistant,
        \\| Name | Context |
        \\|---|---|
        \\| gpt | 200k |
    );
    const lines = try blockLines(arena, blocks[0]);
    for (lines) |l| {
        // Every line of the box is exactly as wide as the top border.
        try std.testing.expectEqual(textWidth(lines[0]), textWidth(l));
    }
    try std.testing.expectEqual(@as(usize, 18), textWidth(lines[0]));
}

test "a table wider than the width shrinks and never exceeds it" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const text =
        \\| Model | Context | Price |
        \\|---|---|---|
        \\| claude-sonnet-4-5 | 200000 | 3.00 |
    ;
    // Without a width the table is 38 columns wide: the width is what makes
    // it shrink.
    const natural = try parse(arena, .assistant, text);
    const nat_lines = try blockLines(arena, natural[0]);
    try std.testing.expect(textWidth(nat_lines[0]) > 30);

    const blocks = try parseLang(arena, .assistant, text, null, null, "", .{ .width = 30 });
    const lines = try blockLines(arena, blocks[0]);
    for (lines) |l| {
        try std.testing.expect(textWidth(l) <= 30);
    }
    // And it is still a table (the box is there).
    try std.testing.expect(std.mem.startsWith(u8, lines[0], "┌"));
}

test "a cell longer than its column wraps instead of being clipped" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const cell = "a very long description that does not fit in a narrow column";
    const text = try std.fmt.allocPrint(arena,
        \\| Name | Description |
        \\|---|---|
        \\| x | {s} |
    , .{cell});

    const blocks = try parseLang(arena, .assistant, text, null, null, "", .{ .width = 40 });
    const lines = try blockLines(arena, blocks[0]);
    // The row took more than one line: the cell was wrapped, not clipped.
    try std.testing.expect(lines.len > 5);
    for (lines) |l| {
        try std.testing.expect(textWidth(l) <= 40);
    }
    // And the text is NOT lost: every character of the cell is in the table,
    // in order.
    const all = try stripSpaces(arena, try blockText(arena, blocks[0]));
    const stripped = try stripSpaces(arena, cell);
    try std.testing.expect(isSubsequence(stripped, all));
}

test "an escaped pipe does not split the cell" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const blocks = try parse(arena, .assistant,
        \\| Cmd | Note |
        \\|---|---|
        \\| a \| b | two cells |
    );
    const lines = try blockLines(arena, blocks[0]);
    // Two columns, not three: the escaped pipe is part of the cell.
    try std.testing.expectEqualStrings("┌───────┬───────────┐", lines[0]);
    try std.testing.expectEqualStrings("│ Cmd   │ Note      │", lines[1]);
    try std.testing.expectEqualStrings("│ a | b │ two cells │", lines[3]);
}

test "a table that does not fit degrades to name: value rows" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const blocks = try parseLang(arena, .assistant,
        \\| Name | Context |
        \\|---|---|
        \\| gpt | 200k |
    , null, null, "", .{ .width = 8 });
    const lines = try blockLines(arena, blocks[0]);
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqualStrings("Name: gpt · Context: 200k", lines[0]);
    // And it is NOT a box any more: there is no room for one.
    try std.testing.expect(std.mem.indexOf(u8, lines[0], "┌") == null);
}

test "a line that starts with a pipe and has no separator is prose" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    // No separator: it is not a table and it stays prose.
    const blocks = try parse(arena, .assistant, "| a | b |\n| c | d |");
    const text = try blockText(arena, blocks[0]);
    try std.testing.expect(std.mem.indexOf(u8, text, "┌") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "| a | b |") != null);

    // A separator with another number of cells is not the separator of this
    // header.
    const mismatch = try parse(arena, .assistant, "| a | b |\n|---|");
    const mismatch_text = try blockText(arena, mismatch[0]);
    try std.testing.expect(std.mem.indexOf(u8, mismatch_text, "┌") == null);

    // And one column is a line that happens to have a pipe, not a table.
    const one = try parse(arena, .assistant, "| a |\n|---|");
    const one_text = try blockText(arena, one[0]);
    try std.testing.expect(std.mem.indexOf(u8, one_text, "┌") == null);
}

test "the prose around a table survives the table" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const blocks = try parse(arena, .assistant,
        \\antes
        \\| Name | Context |
        \\|---|---|
        \\| gpt | 200k |
        \\despues
    );
    // The table is a block of its own, and the prose before and after it is
    // still prose.
    try std.testing.expectEqual(@as(usize, 3), blocks.len);
    const first = try blockText(arena, blocks[0]);
    try std.testing.expectEqualStrings("antes\n", first);
    const last = try blockText(arena, blocks[2]);
    try std.testing.expectEqualStrings("despues\n", last);
    const middle = try blockText(arena, blocks[1]);
    try std.testing.expect(std.mem.indexOf(u8, middle, "┌") != null);
}

test "every cell of a table survives the rendering" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    // The invariant that matters: the text of every cell is IN the table.
    // A table that drops a cell (or a whole column) looks fine and says
    // nothing about the half of the answer that is missing.
    const blocks = try parse(arena, .assistant,
        \\| Name | Context | Price |
        \\|---|---|---|
        \\| gpt | 200k | 3.00 |
        \\| claude | 1m | 15.00 |
    );
    const text = try blockText(arena, blocks[0]);
    const cells = [_][]const u8{
        "Name", "Context", "Price",
        "gpt",  "200k",    "3.00",
        "claude", "1m",   "15.00",
    };
    for (cells) |c| {
        if (std.mem.indexOf(u8, text, c) == null) {
            std.debug.print("the cell `{s}` is not in the table\n", .{c});
            return error.TestUnexpectedResult;
        }
    }
}

test "the inline markdown inside a cell still works" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const blocks = try parse(arena, .assistant,
        \\| Name | Kind |
        \\|---|---|
        \\| **bold** | `code` |
    );
    const lines = try blockLines(arena, blocks[0]);
    // The markers are markers: the cell says `bold`, not `**bold**`.
    try std.testing.expect(std.mem.indexOf(u8, lines[3], "**") == null);
    try std.testing.expect(std.mem.indexOf(u8, lines[3], "bold") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines[3], "`") == null);
    // And the styles are the ones of the module: the bold is bold.
    var bold_found = false;
    for (blocks[0].lines[3]) |seg| {
        if (std.mem.eql(u8, seg.text, "bold")) {
            bold_found = true;
            try std.testing.expect(seg.style.bold);
        }
    }
    try std.testing.expect(bold_found);
}

test "a table inside a code block is code, not a table" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const blocks = try parse(arena, .assistant,
        \\```markdown
        \\| Name | Context |
        \\|---|---|
        \\| gpt | 200k |
        \\```
    );
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqual(Kind.code, blocks[0].kind);
    const text = try blockText(arena, blocks[0]);
    try std.testing.expect(std.mem.indexOf(u8, text, "┌") == null);
}
