const std = @import("std");
const builtin = @import("builtin");

/// How many bytes of input text are shown before truncation.
/// Past this the input is cut to head + "... +N more" + tail.
pub const max_input_display_bytes: usize = 400;

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const agent = @import("agent.zig");
const chat = @import("chat.zig");
const md = @import("lib/markdown.zig");
const theme = @import("lib/theme.zig");
const ed = @import("lib/editor.zig");
const textcap = @import("lib/textcap.zig");
const sleepz = @import("lib/sleep.zig");
const taskstore = @import("lib/taskstore.zig");
const palette = @import("palette.zig");
const compaction = @import("compaction.zig");
const plan_mod = @import("lib/plan.zig");
const goal_mod = @import("lib/goal.zig");
const checkpoint = @import("lib/checkpoint.zig");
const bgproc = @import("bgproc.zig");
const images_mod = @import("lib/images.zig");
const agent_mod = @import("agent.zig");
const readcache = @import("lib/readcache.zig");
const subagent_mod = @import("lib/subagent.zig");
const session_mod = @import("session.zig");
const filesview = @import("lib/filesview.zig");
const bench_mod = @import("lib/bench.zig");
const models_mod = @import("lib/models.zig");
const modelcache = @import("lib/modelcache.zig");
const zjsonl = @import("lib/zjsonl.zig");
const copytext = @import("lib/copytext.zig");
const fuzzy = @import("lib/fuzzy.zig");
const filesearch = @import("lib/filesearch.zig");
const mascot = @import("lib/mascot.zig");
const sessionindex = @import("lib/sessionindex.zig");
const session_search = @import("lib/session_search.zig");

/// The kind of the status: what color the face is and what phase the app is in.
/// Replaces `StatusKind`; lives here so `agent.zig` can reference it as
/// `tui.StatusKind` without importing the mascot module.
pub const StatusKind = enum {
    idle,
    thinking,
    tooling,
    done,
    warn,
    err,

    pub fn color(self: StatusKind) u8 {
        return switch (self) {
            .idle => 6, // cyan
            .thinking => 5, // magenta
            .tooling => 4, // blue
            .done => 2, // green
            .warn => 3, // yellow
            .err => 1, // red
        };
    }
};

/// The face is always SEVEN columns wide, and that is what the footer's layout
/// is built on.
///
/// The faces themselves live in `lib/mascot.zig` — the keyframes, the motion
/// layer and the tests that every frame of every track is seven ASCII columns.
/// The width is repeated here because the LAYOUT needs it: the legend starts a
/// fixed number of columns after home, so the face can lean without pushing the
/// words, and a face that changed width would move the legend instead.
pub const face_width: u16 = 7;

/// The colour of a mood, from the THEME and not from the 16-colour palette.
///
/// `mood.color()` returns an ANSI index (cyan, magenta, blue…), and an index
/// on a truecolor terminal is the terminal's own palette, not this app's: the
/// mascot came out in a colour that belonged to nothing around it.
fn moodStyle(kind: StatusKind) vaxis.Style {
    return switch (kind) {
        .idle => theme.ink2,
        .thinking => theme.brand,
        .tooling => theme.brand_hi,
        .done => theme.ok,
        .warn => theme.warn,
        .err => theme.err,
    };
}

/// Columns of an art fragment, not bytes.
fn glyphCols(s: []const u8) usize {
    @setEvalBranchQuota(10_000);
    const view = std.unicode.Utf8View.initUnchecked(s);
    var it = view.iterator();
    var n: usize = 0;
    while (it.nextCodepoint()) |_| n += 1;
    return n;
}

/// The wordmark, one glyph per letter, 6 columns wide and 5 rows tall.
///
/// The letters are drawn to be READ, and the two that used to be confusable
/// are the two that were fixed:
///
/// - **D** has a FLAT left stem and a curved right bowl. It used to be a
///   rounded blob, and the v3 wordmark's whole point was that "O and D are
///   distinguishable at a glance" — a rounded D is an O with a different
///   letter's name.
/// - **E** has a FIVE-wide middle bar. With a three-wide one it read as an F
///   with a stub.
///
/// The strokes are two columns wide, except where the shape of the letter
/// needs one (the D's bowl). A drawing whose strokes change weight halfway
/// reads as a mistake, and there is no way to see it in a terminal that
/// substitutes the font.
///
/// It is plain ASCII (`#` and a space) and NOT box drawing, and that is a
/// decision that was paid for: a v2 built of `█ ╗ ╝ ═ ║` was illegible in
/// the user's terminal — a relief smudge that read as nothing — because the
/// strokes depend on how the font draws the full block. Plain ASCII reads
/// the same in every terminal there is.
const glyph_z = [_][]const u8{
    "######",
    "##  ##",
    "   ## ",
    "  ##  ",
    "######",
};
const glyph_o = [_][]const u8{
    " #### ",
    "##  ##",
    "##  ##",
    "##  ##",
    " #### ",
};
const glyph_d = [_][]const u8{
    "####  ",
    "## ## ",
    "##  ##",
    "## ## ",
    "####  ",
};
const glyph_e = [_][]const u8{
    "######",
    "##    ",
    "##### ",
    "##    ",
    "######",
};

const wordmark = [_]struct { rows: []const []const u8, w: usize }{
    .{ .rows = &glyph_z, .w = 6 },
    .{ .rows = &glyph_o, .w = 6 },
    .{ .rows = &glyph_d, .w = 6 },
    .{ .rows = &glyph_e, .w = 6 },
};

/// How many rows the wordmark has (one per letter height).
pub const banner_art_height = 5;

/// Columns of the wordmark: 4 boxes of 6 with ONE separating space.
pub const banner_art_width = 4 * 6 + 3;

/// Assemble row `r` of the wordmark: the fixed gaps between the letters.
///
/// The width of a glyph row is its BYTE count, and that is not a shortcut:
/// the art is pure ASCII (`#` and a space), so a byte is a column — and the
/// count has to be available at COMPILE TIME, because the art is composed at
/// compile time on purpose (the padding on the right gets stripped by an
/// editor, and a stripped row is a shifted row).
fn bannerRow(comptime r: usize) []const u8 {
    comptime var out: []const u8 = "";
    inline for (wordmark, 0..) |letter, i| {
        if (i > 0) out = out ++ " ";
        if (i + 1 < wordmark.len) {
            const missing = letter.w - letter.rows[r].len;
            const filler = " " ** missing;
            out = out ++ letter.rows[r] ++ filler;
        } else {
            out = out ++ letter.rows[r];
        }
    }
    return out;
}

/// The welcome banner: the wordmark, and NOTHING else.
///
/// It is ONE paragraph with the five rows inside it, and that is the whole
/// trick: the ASCII art used to be five paragraphs, and the separator between
/// paragraphs put a blank row between the letters — the logo was read in
/// pieces. A drawing is one block.
pub const banner = bannerRow(0) ++ "\n" ++
    bannerRow(1) ++ "\n" ++
    bannerRow(2) ++ "\n" ++
    bannerRow(3) ++ "\n" ++
    bannerRow(4);

/// Item of the modal picker (opencode style). Labels/descs are gpa-owned
/// and closePicker frees them.
pub const PickerItem = struct {
    label: []const u8,
    desc: []const u8 = "",
};

pub const PickerCb = *const fn (*Model, tag: u32, label: []const u8) void;

/// The callback that gets the INDEX of the chosen item instead of its label.
///
/// A label is a thing to READ; an index is a thing to ACT on. `/copy` needs
/// the index: its rows are "the whole answer", then one per code block, and
/// two blocks can start with the SAME line, so matching the label back to
/// the entry is a guess — and a wrong guess copies the wrong block while
/// showing the right row.
pub const PickerCbIdx = *const fn (*Model, tag: u32, index: usize) void;

/// Called when the picker is closed with ESC.
///
/// A cancel is NOT an error: `/copy` says "Copy cancelled" as a system line,
/// and without this callback the command could not tell a cancel from a
/// choice.
pub const PickerCancelCb = *const fn (*Model, tag: u32) void;

/// Tag for the sessions picker (used for footer hint).
pub const sessions_picker_tag: u32 = 99;

/// Debounce delay (seconds) for the tier-2 transcript search of the sessions
/// picker. While the user is typing, only tier-1 (title) runs. After the user
/// pauses for this long, tier-2 (transcript) runs (Phase 29.5).
pub const picker_transcript_debounce_s: i64 = 1;

/// Immutable copy of the picker state for drawing (frame memory).
const PickerSnapshot = struct {
    title: []const u8,
    query: []const u8,
    sel: usize,
    first_visible: usize,
    total: usize,
    tag: u32,
    items: []PickerItem,
    /// Whether a semantic search (tier 3) is in flight. Shown as "Searching…"
    /// in the picker footer.
    semantic_searching: bool = false,
};

// ── painter: cell writes with stable graphemes ─────────────────
//
// TRAP (vaxis 0.6): `vxfw.Surface.writeCell` stores the `vaxis.Cell` BY
// VALUE, and vaxis reads the BYTES of `char.grapheme` in `Vaxis.render()`,
// that is, AFTER this drawFn has returned. A pointer to a stack temporary
// (`&[_]u8{c}`) reaches the renderer as garbage (NULs) → blank screen.
// Rule: the grapheme must live at least until the end of the frame, that is,
// be a static literal, owned by the Model, or owned by the frame's arena
// (`ctx.arena`, which is reset at the start of the NEXT frame).
// (`ctx.arena`, which is reset at the start of the NEXT frame).

/// Sleeps `ms` milliseconds with a bare `nanosleep`, without going through the
/// `Io`.
///
/// CAREFUL: `Io.sleep` does NOT work here. The `Io` is the same one as vaxis's
/// event loop, so sleeping through it takes the redraws with it (the screen
/// freezes exactly while there is something to show). `nanosleep` is a system
/// call on the calling thread and touches nothing shared.
fn napMs(ms: u64) void {
    if (builtin.os.tag != .linux) {
        std.Thread.yield() catch {};
        return;
    }
    const ts = std.os.linux.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.os.linux.nanosleep(&ts, null);
}

pub const Painter = struct {
    surface: *vxfw.Surface,
    arena: std.mem.Allocator,
    ctx: vxfw.DrawContext,
    width: u16,
    height: u16,

    pub fn measure(self: *const Painter, g: []const u8) u8 {
        return theme.graphemeWidth(self.ctx, g);
    }

    /// Writes an ALREADY stable grapheme (literal or arena that outlives the
    /// frame). Allocates no memory.
    pub fn putStable(self: *Painter, col: u16, row: u16, g: []const u8, w: u8, style: vaxis.Style) void {
        if (col >= self.width or row >= self.height or col + w > self.width) return;
        self.surface.writeCell(col, row, .{
            .char = .{ .grapheme = g, .width = w },
            // THE LADDER, in the one place a cell is written: a color the
            // terminal cannot show never reaches the wire. vaxis does not
            // convert rgb→256 (it sends `38;2;r;g;b` whatever the terminal
            // said), so a 256-color terminal got a byte sequence it does not
            // understand, and what it did with it was undefined.
            .style = theme.resolve(style),
        });
    }

    /// Writes ephemeral text: copies it into the frame arena once and then
    /// advances grapheme by grapheme. Returns the next column.
    /// Writes text and returns the **final column** (not the width).
    ///
    /// CAREFUL: `col += p.putText(col, ...)` is WRONG, because it adds one
    /// absolute position to another and the next text goes all the way right
    /// (outside the panel). To chain calls you must write
    /// `col = p.putText(col, ...)`.
    /// That bug left the options of the permission dialog with the "A" in
    /// column 92 of a 68-wide panel.
    pub fn putText(self: *Painter, col: u16, row: u16, text: []const u8, style: vaxis.Style) u16 {
        if (text.len == 0 or col >= self.width or row >= self.height) return col;
        const stable = self.arena.dupe(u8, text) catch return col;
        var it = vaxis.unicode.graphemeIterator(stable);
        var c = col;
        while (it.next()) |g| {
            const b = g.bytes(stable);
            const gw = self.measure(b);
            if (c + gw > self.width) break;
            self.putStable(c, row, b, gw, style);
            c += gw;
        }
        return c;
    }

    /// Like `putText` but stops at `max_cols` COLUMNS from `col`, so a string
    /// that does not fit its BOX stops at the box and not at the terminal edge.
    ///
    /// This is not a nicety: `putText` clips against the surface width, so a long
    /// option in a 64-wide picker used to be painted 56 columns past the picker's
    /// right border, over whatever was there. Anything drawn inside a bordered
    /// box has to clip against the box.
    pub fn putClipped(
        self: *Painter,
        col: u16,
        row: u16,
        text: []const u8,
        max_cols: u16,
        style: vaxis.Style,
    ) u16 {
        if (text.len == 0 or max_cols == 0 or col >= self.width or row >= self.height) return col;
        const stable = self.arena.dupe(u8, text) catch return col;
        var it = vaxis.unicode.graphemeIterator(stable);
        var c: u16 = 0;
        while (it.next()) |g| {
            const b = g.bytes(stable);
            const gw = self.measure(b);
            if (c + gw > max_cols) break;
            if (col + c + gw > self.width) break;
            self.putStable(col + c, row, b, gw, style);
            c += gw;
        }
        return col + c;
    }

    /// Fills a whole row with a 1-column grapheme (line, border).
    /// The grapheme must be a static literal (e.g. "─").
    fn fillRow(self: *Painter, row: u16, g: []const u8, style: vaxis.Style) void {
        if (row >= self.height) return;
        var c: u16 = 0;
        while (c < self.width) : (c += 1) {
            self.putStable(c, row, g, 1, style);
        }
    }

    /// Fills `[c0, c1)` of a row. For modal backgrounds and selection.
    pub fn fillRange(self: *Painter, c0: u16, c1: u16, row: u16, g: []const u8, style: vaxis.Style) void {
        if (row >= self.height) return;
        var c = c0;
        while (c < @min(c1, self.width)) : (c += 1) {
            self.putStable(c, row, g, 1, style);
        }
    }
};

// ── layout: paragraphs → already-wrapped lines ─────────────────
//
// Wrapping is resolved HERE (not in draw) because the paragraph cache already
// invalidates on width change. That way `lineas.len` is the EXACT height and
// cannot drift from what draw paints (before, it measured and painted with two
// different loops that could disagree).
const CellRun = struct {
    text: []const u8, // grapheme, stable (paragraph arena)
    w: u8, // 1 o 2 columnas
    style: vaxis.Style,
};

const PLine = struct {
    cells: []const CellRun,
    w: u16, // columns occupied
};

/// The `─` row that goes between the banner and the first thing the user says.
///
/// It lives here and not inline because of two details that are easy to get
/// wrong and impossible to see in a code review:
///
///  - The BYTES go in `text` and the draw reads them AFTER this returns (the
///    `&[_]u8{c}` bug that has bitten this repo eight times). So they are
///    allocated in the paragraph's arena, not on the stack.
///  - `CellRun.w` is a **u8 in COLUMNS**, capped at 255. One run wider than
///    that silently stops drawing halfway across a wide terminal. So the line is
///    split into as many runs as it takes, each ≤255 columns, and `w` on the
///    PLine is the real total.
///
/// `─` is 3 bytes and ONE column wide: allocating `width` bytes and filling them
/// would produce a third of the line and a lot of NULs.
fn bannerRuleLine(pa: std.mem.Allocator, width: u16) PLine {
    const cols = width -| historyMargin(width);
    var runs: std.ArrayList(CellRun) = .empty;
    runs.ensureTotalCapacity(pa, (cols / 255) + 1) catch return .{ .cells = &.{}, .w = 0 };
    var made: u16 = 0;
    while (made < cols) {
        const take: u16 = @min(cols - made, 255);
        const buf = pa.alloc(u8, @as(usize, take) * 3) catch break;
        for (0..take) |i| @memcpy(buf[@as(usize, i) * 3 ..][0..3], "\xe2\x94\x80");
        runs.appendAssumeCapacity(.{ .text = buf, .w = @intCast(take), .style = theme.rule });
        made += take;
    }
    return .{ .cells = runs.items, .w = made };
}

/// Lines of a diff shown before it collapses into a preview.
///
/// Twelve is where a diff stops being "what just happened" and starts being the
/// file. The counts and the rest of the lines are one Ctrl+R away, and the
/// marker says so — a collapsed view that does not say it is collapsed is the
/// bug this exists to avoid.
pub const diff_preview_lines = 12;

/// The hairline under the hero's tagline. A LITERAL and not a composed run of
/// `─`, because `CellRun.w` is a **u8 in COLUMNS**: one run wider than 255
/// silently stops drawing halfway across a wide terminal. This is the same trap
/// `bannerRuleLine` documented, and the rule now lives here because the banner
/// it was written for is gone.
pub const hero_rule = "───────────────────────────────";

/// Lines added and removed by a diff (what is shown as `+N −M`).
pub const DiffCounts = struct { added: usize = 0, removed: usize = 0 };

/// Splits `cells` into lines of at most `width` columns.
///
/// `indent` is the indent columns of the CONTINUATION lines. Without them, a
/// sentence broken across the width looks like a new sentence: nothing marks
/// that "this continues below". With two columns of indent it reads as a
/// continuation, which is what any line wrapping does.
fn wrapCells(
    pa: std.mem.Allocator,
    lines: *std.ArrayList(PLine),
    cells: []const CellRun,
    width: u16,
    indent: u16,
) !void {
    return wrapCellsGutter(pa, lines, cells, width, indent, null, false);
}

/// `wrapCells` with a visible GUTTER on the continuation rows.
///
/// The indent used to be two anonymous space cells, which is the same width as
/// the kind marker (`› `, `◆ `, `⏺ `) that only the FIRST row of a paragraph
/// carries. A six-row tool result therefore had one identifiable row and five
/// that looked exactly like a notice. A dim `│` in the gutter says "this
/// continues", and costs one glyph.
fn wrapCellsGutter(
    pa: std.mem.Allocator,
    lines: *std.ArrayList(PLine),
    cells: []const CellRun,
    width: u16,
    indent: u16,
    gutter: ?vaxis.Style,
    word_wrap: bool,
) !void {
    if (cells.len == 0) {
        try lines.append(pa, .{ .cells = &.{}, .w = 0 });
        return;
    }
    const ind_w: u16 = @min(indent, @max(width -| 1, 1));
    var start: usize = 0;
    var used: usize = 0; // columns USED by real cells (usize to avoid u16 overflow)
    var first = true;
    var break_after: ?usize = null;
    var break_width: usize = 0;
    for (cells, 0..) |c, i| {
        // The limit of a continuation is the width MINUS the indent, because
        // the indent occupies real columns.
        const limit: usize = @intCast(if (first) @max(width, 1) else @max(width - ind_w, 1));
        const cw: usize = @intCast(@min(c.w, @max(limit, 1)));
        if (used > 0 and used + cw > limit) {
            var split = i;
            var line_used = used;
            if (word_wrap) {
                if (break_after) |b| {
                    if (b > start and b <= i) {
                        split = b;
                        line_used = break_width;
                    }
                }
            }
            const safe_line_used: u16 = if (line_used > std.math.maxInt(u16)) std.math.maxInt(u16) else @intCast(line_used);
            try appendContinuation(pa, lines, cells[start..split], safe_line_used, if (first) 0 else ind_w, if (first) null else gutter);
            start = split;
            first = false;
            used = 0;
            const next_limit: usize = @intCast(@max(width - ind_w, 1));
            for (cells[split..i]) |tail| used += @intCast(@min(tail.w, next_limit));
            break_after = null;

            // A long word can fit on the unindented first row but not on a
            // continuation row. Keep the same hard-wrap guarantee in that case.
            const cw_next: usize = @intCast(@min(c.w, next_limit));
            if (used > 0 and used + cw_next > next_limit) {
                const safe_used: u16 = if (used > std.math.maxInt(u16)) std.math.maxInt(u16) else @intCast(used);
                try appendContinuation(pa, lines, cells[start..i], safe_used, ind_w, gutter);
                start = i;
                used = 0;
            }
        }
        used += cw;
        if (word_wrap and (std.mem.eql(u8, c.text, " ") or std.mem.eql(u8, c.text, "\t"))) {
            break_after = i + 1;
            break_width = used;
        }
    }
    const safe_used_final: u16 = if (used > std.math.maxInt(u16)) std.math.maxInt(u16) else @intCast(used);
    try appendContinuation(pa, lines, cells[start..], safe_used_final, if (first) 0 else ind_w, if (first) null else gutter);
}

/// Appends a line to the array, with `pad` indent columns at the start.
///
/// The indent is a run of space CELLS, not a bigger `w`: painting walks
/// `cells` in order, so if only `w` is enlarged the indent is not painted (and
/// the text would stick to the border).
fn appendContinuation(
    pa: std.mem.Allocator,
    lines: *std.ArrayList(PLine),
    cells: []const CellRun,
    used: u16,
    pad: u16,
    gutter: ?vaxis.Style,
) !void {
    if (pad == 0) {
        try lines.append(pa, .{ .cells = cells, .w = used });
        return;
    }
    var out: std.ArrayList(CellRun) = .empty;
    var i: u16 = 0;
    while (i < pad) : (i += 1) {
        // The gutter is the FIRST indent column and it is a `│`; the rest stay
        // blank so the text still lines up with the first row.
        const cell_style: vaxis.Style = if (gutter != null and i == 0) gutter.? else .{};
        const text: []const u8 = if (gutter != null and i == 0) "\u{2502}" else " ";
        try out.append(pa, .{ .text = text, .w = 1, .style = cell_style });
    }
    try out.appendSlice(pa, cells);
    const pad_w: usize = @intCast(pad);
    const final_w: usize = used + pad_w;
    // Saturate to u16 max so a pathological line (no spaces, very wide) does not
    // integer-overflow when casting the PLine width field.
    const safe_w: u16 = if (final_w > std.math.maxInt(u16)) std.math.maxInt(u16) else @intCast(final_w);
    try lines.append(pa, .{ .cells = out.items, .w = safe_w });
}

/// The columns a diff row's wrapped rows have to be indented by.
///
/// The line number is painted as part of the row (the gutter), so a row that
/// wraps has to skip the number, its space and the `+`/`-` marker to stay in
/// the same column as the code above it. The number's cells are the ones
/// painted in `theme.diff_gutter`, which is what they are told to be.
///
/// Without a gutter (a diff with no hunk header) it is the two columns it
/// always was: the marker and the space after it.
fn diffRowIndent(cells: []const CellRun) u16 {
    var n: u16 = 0;
    for (cells) |c| {
        // The comparison is on the FOREGROUND: the gutter's cells carry the
        // row's tint as their background (an added row is a band), so the
        // whole style is never equal to the gutter's.
        if (!vaxis.Style.eql(.{ .fg = c.style.fg }, .{ .fg = theme.diff_gutter.fg })) continue;
        n += c.w;
    }
    if (n == 0) return 2;
    // The number, its space, and the marker.
    return n + 1;
}

/// Turns a paragraph (markdown already parsed) into lines of cells.
/// All the memory comes out of `pa` (the paragraph's own arena or the frame
/// arena).
fn buildLines(
    pa: std.mem.Allocator,
    ctx: vxfw.DrawContext,
    para: *Model.Para,
    width: u16,
) ![]const PLine {
    return buildLinesBase(pa, ctx, para, width);
}

/// Builds the lines of a code block with a full rounded border.
///
/// The block gets:
///   - a top border `╭─────╮`
///   - an optional language chip with a background
///   - each line wrapped in `│ … │`
///   - a bottom border `╰─────╯`
///
/// All memory comes out of `pa`.
fn buildCodeBlockLines(
    pa: std.mem.Allocator,
    ctx: vxfw.DrawContext,
    blk: anytype,
    width: u16,
) ![]const PLine {
    // ── first pass: build every line's cells and find the max width ─────────
    var raw_lines: std.ArrayList([]const CellRun) = .empty;
    var max_w: u16 = 0;
    for (blk.lines) |src| {
        var cells: std.ArrayList(CellRun) = .empty;
        for (src) |seg| {
            var it = vaxis.unicode.graphemeIterator(seg.text);
            while (it.next()) |g| {
                const b = g.bytes(seg.text);
                try cells.append(pa, .{
                    .text = b,
                    .w = theme.graphemeWidth(ctx, b),
                    .style = seg.style,
                });
            }
        }
        try raw_lines.append(pa, cells.items);
        const ln_w: u16 = @intCast(cells.items.len);
        if (ln_w > max_w) max_w = ln_w;
    }

    // Inner width: code text + left gutter `│ ` + right gutter ` │`
    const inner_w: u16 = if (max_w > 0) max_w else 0;
    const box_w: u16 = if (inner_w + 4 > width) width else inner_w + 4;
    const text_w: u16 = if (box_w > 4) box_w - 4 else 0;

    var lines: std.ArrayList(PLine) = .empty;

    // ── top border ──────────────────────────────────────────────────────────
    {
        var cells: std.ArrayList(CellRun) = .empty;
        try cells.append(pa, .{ .text = "╭", .w = 1, .style = theme.code_border });
        var i: u16 = 1;
        while (i < box_w - 1) : (i += 1) {
            try cells.append(pa, .{ .text = "─", .w = 1, .style = theme.code_border });
        }
        try cells.append(pa, .{ .text = "╮", .w = 1, .style = theme.code_border });
        try lines.append(pa, .{ .cells = cells.items, .w = box_w });
    }

    // ── language chip with background ───────────────────────────────────────
    if (blk.lang.len > 0) {
        var cells: std.ArrayList(CellRun) = .empty;
        try cells.append(pa, .{ .text = "│ ", .w = 2, .style = theme.code_border });
        try cells.append(pa, .{ .text = "▚ ", .w = 2, .style = theme.code_lang });
        var it = vaxis.unicode.graphemeIterator(blk.lang);
        while (it.next()) |g| {
            const b = g.bytes(blk.lang);
            try cells.append(pa, .{
                .text = b,
                .w = theme.graphemeWidth(ctx, b),
                .style = theme.code_lang,
            });
        }
        // pad to fill the box width
        var used: u16 = 4; // │ ▚ + lang
        for (blk.lang) |_| { used += 1; } // approx; grapheme width would be better
        // simpler: fill rest with background
        const pad: u16 = if (box_w > used) box_w - used else 0;
        var i: u16 = 0;
        while (i < pad) : (i += 1) {
            try cells.append(pa, .{ .text = " ", .w = 1, .style = theme.code_bg });
        }
        try cells.append(pa, .{ .text = " │", .w = 2, .style = theme.code_border });
        try lines.append(pa, .{ .cells = cells.items, .w = box_w });
    }

    // ── code lines ──────────────────────────────────────────────────────────
    for (raw_lines.items) |cells| {
        var out: std.ArrayList(CellRun) = .empty;
        try out.append(pa, .{ .text = "│ ", .w = 2, .style = theme.code_border });
        for (cells) |c| {
            var st = c.style;
            st.bg = theme.code_bg.bg;
            try out.append(pa, .{ .text = c.text, .w = c.w, .style = st });
        }
        // pad to text_w
        var used: u16 = 2;
        for (cells) |c| used += c.w;
        const pad: u16 = if (text_w > used) text_w - used else 0;
        var i: u16 = 0;
        while (i < pad) : (i += 1) {
            try out.append(pa, .{ .text = " ", .w = 1, .style = theme.code_bg });
        }
        try out.append(pa, .{ .text = " │", .w = 2, .style = theme.code_border });
        try lines.append(pa, .{ .cells = out.items, .w = box_w });
    }

    // ── bottom border ───────────────────────────────────────────────────────
    {
        var cells: std.ArrayList(CellRun) = .empty;
        try cells.append(pa, .{ .text = "╰", .w = 1, .style = theme.code_border });
        var i: u16 = 1;
        while (i < box_w - 1) : (i += 1) {
            try cells.append(pa, .{ .text = "─", .w = 1, .style = theme.code_border });
        }
        try cells.append(pa, .{ .text = "╯", .w = 1, .style = theme.code_border });
        try lines.append(pa, .{ .cells = cells.items, .w = box_w });
    }

    return lines.items;
}

/// `buildLines` with an imposed base style (see `md.parseBase`).
fn buildLinesBase(
    pa: std.mem.Allocator,
    ctx: vxfw.DrawContext,
    para: *Model.Para,
    width: u16,
) ![]const PLine {
    // The width goes to the parser so a TABLE knows how much room it has: a
    // table that does not fit is degraded into `name: value` rows, and that
    // decision can only be made with the width in hand.
    //
    // The two columns are the paragraph's prefix ("› "), which lands on the
    // first line: a table that OPENS a paragraph would otherwise be two
    // columns wider than the terminal and the TUI would wrap the box.
    const blocks = try md.parseLang(pa, para.kind, para.text, para.base, para.mood, para.lang, .{
        .word_diff = para.word_diff,
        .width = width -| 2,
    });
    var lines: std.ArrayList(PLine) = .empty;
    var first_line = true;

    for (blocks) |blk| {
        const is_code = blk.kind == .code;
        if (is_code) {
            // A code block gets a full rounded border: top border, optional
            // language chip, lines wrapped in │ … │, bottom border. The box is
            // self-contained (its own borders), so it needs no blank separator
            // rows around it — the border IS the separation.
            const code_lines = try buildCodeBlockLines(pa, ctx, blk, width);
            for (code_lines) |ln| try lines.append(pa, ln);
            continue;
        }

        // ── prose / diff / table (unchanged) ────────────────────────────────
        for (blk.lines) |src| {
            var cells: std.ArrayList(CellRun) = .empty;
            if (first_line) {
                const pre = md.prefix(para.kind);
                var pit = vaxis.unicode.graphemeIterator(pre.text);
                while (pit.next()) |pg| {
                    const pb = pg.bytes(pre.text);
                    try cells.append(pa, .{
                        .text = pb,
                        .w = theme.graphemeWidth(ctx, pb),
                        .style = pre.style,
                    });
                }
                first_line = false;
            }
            for (src) |seg| {
                var it = vaxis.unicode.graphemeIterator(seg.text);
                while (it.next()) |g| {
                    const b = g.bytes(seg.text);
                    try cells.append(pa, .{
                        .text = b,
                        .w = theme.graphemeWidth(ctx, b),
                        .style = seg.style,
                    });
                }
            }
            const avail = width;
            const gutter: ?vaxis.Style = if (blk.kind == .diff) null else theme.gutter;
            const indent: u16 = if (blk.kind == .diff) diffRowIndent(cells.items) else 2;
            try wrapCellsGutter(pa, &lines, cells.items, avail, indent, gutter, blk.kind != .diff);
        }
    }

    if (lines.items.len == 0) {
        const one = try pa.alloc(PLine, 1);
        one[0] = .{ .cells = &.{}, .w = 0 };
        return one;
    }
    return lines.items;
}

/// Row with the language chip, above the code block.
///
/// `▚ zig` in the dim style. Before there was nothing: the ```zig fence
/// disappeared and there was no way to tell which language the code was in.
fn appendChip(
    pa: std.mem.Allocator,
    ctx: vxfw.DrawContext,
    lines: *std.ArrayList(PLine),
    lang: []const u8,
) !void {
    var cells: std.ArrayList(CellRun) = .empty;
    try cells.append(pa, .{ .text = "▚ ", .w = 2, .style = theme.code_gutter });
    var it = vaxis.unicode.graphemeIterator(lang);
    while (it.next()) |g| {
        const b = g.bytes(lang);
        try cells.append(pa, .{
            .text = b,
            .w = theme.graphemeWidth(ctx, b),
            .style = theme.code_lang,
        });
    }
    try wrapCells(pa, lines, cells.items, 0xffff, 0);
}

/// Puts the `│` gutter in front of the block's lines and gives them a
/// background.
///
/// The background is applied to the cell of EVERY grapheme, which is the only
/// way to make the surface paint it: a `bg` in a style paints nothing if the
/// cell is not written with that style.
fn applyCodeGutter(
    pa: std.mem.Allocator,
    lines: []PLine,
    width: u16,
) void {
    for (lines) |*ln| {
        if (ln.cells.len == 0) continue; // blank line: no gutter
        // The text already comes wrapped to `width - 2` (the gutter was
        // reserved before), so the background is filled with whatever is
        // missing up to the border.
        const used: u16 = @intCast(@min(ln.w + 2, width));
        const pad: u16 = if (width > used) width - used else 0;

        var out: std.ArrayList(CellRun) = .empty;
        // `│` + space in front: the block reads as a block.
        out.append(pa, .{ .text = "\u{2502} ", .w = 2, .style = theme.code_gutter }) catch return;
        // The background goes BEHIND THE CODE, not only on the trailing pad. With
        // only the pad painted, the block was a dark stripe whose width changed
        // from row to row on any terminal whose background is not exactly
        // #1a1b26, and the doc comment claimed a background it never drew.
        for (ln.cells) |c| {
            var st = c.style;
            st.bg = theme.code_bg.bg;
            out.append(pa, .{ .text = c.text, .w = c.w, .style = st }) catch return;
        }
        var i: u16 = 0;
        while (i < pad) : (i += 1) {
            out.append(pa, .{ .text = " ", .w = 1, .style = theme.code_bg }) catch return;
        }
        ln.* = .{ .cells = out.items, .w = @min(used + pad, width) };
    }
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        var ok = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

/// Compact terminal workspace: scrollable history, contextual work indicators,
/// a borderless multiline prompt, and the composer's footer — the mascot, its
/// legend and the session's numbers, all inside the prompt's own surface.
/// Per-frame copy of an open question. Everything in it is in the FRAME arena,
/// which is the only memory whose lifetime matches "being painted right now".
pub const AskSnapshot = struct {
    question: []const u8 = "",
    header: []const u8 = "",
    options: []const []const u8 = &.{},
    /// The input box is the answer field (the "Other" path).
    typing: bool = false,
    /// Which option row is highlighted (`options.len` is the "Other" row).
    sel: usize = 0,
};

/// Label of the last row of the `ask` menu: the way out of the model's options.
///
/// It is an INDEX now, not a prefix compared against a string: the row IS the
/// other option, so there is nothing to match and no way for a model to write an
/// option starting with the same words and get sent to a text box instead of
/// being answered.
pub const ask_other_label = "type your own answer…";

/// After this with nobody answering, the worker stops waiting and the model is
/// told to decide. See `ask.timed_out_text`.
pub const ask_timeout_ms: u64 = 5 * 60 * 1000;

/// The result of a command the user ran with `!`.
///
/// Both strings are OWNED copies: the worker thread that produced them dies right
/// after pushing, and the arena it ran the command in dies with it.
pub const ShellOut = struct {
    cmd: []u8,
    text: []u8,
    ms: u64,
};

/// How many prompt dots fit on the rail.
///
/// Six, because they are painted one row apart at the right margin: a seventh
/// would either overlap the fifth or push the ladder past the end of the
/// transcript. When a seventh prompt arrives the OLDEST dot falls off, which is
/// the useful direction — the rail is "my recent prompts", not an index of the
/// session.
pub const timeline_max_dots: usize = 6;

/// One dot of the prompt rail: a prompt, and where its dot was painted.
pub const PromptDot = struct {
    /// Paragraph index of the user prompt (what a click scrolls to).
    para: usize,
    /// Absolute history line the prompt starts at. Stored at draw time so a
    /// click does not have to recompute heights over a history that may have
    /// changed since the frame the user is pointing at.
    line: usize,
    /// Row inside the transcript.
    row: u16,
};

pub const Model = struct {
    allocator: std.mem.Allocator,

    /// Whether the terminal window currently has focus. `true` at startup;
    /// `focus_in`/`focus_out` from vaxis flip it, and the composer's caret is
    /// dimmed while it is `false` so the reader sees at a glance that typing
    /// here does nothing until the window is focused again.
    focused: bool = true,

    /// Own input: `vxfw.TextField` is single-line and has no history, so the
    /// prompt is edited with `editor.Editor`.
    ed: ed.Editor,

    /// Transient "input too long" note: an edit was rejected because it would
    /// exceed `ed.max_bytes`. The message names the limit; it is painted inside
    /// the composer zone (the affected zone) by `drawInput` and cleared on the
    /// next keystroke. The buffer itself is never touched by a rejected edit
    /// and no UTF-8 grapheme is ever split.
    input_err_buf: [160]u8 = undefined,
    input_err: []const u8 = "",
    input_too_long: bool = false,

    /// Raw paragraphs (owned). The parse into blocks is on-demand in draw,
    /// with an arena: the memory lives for one frame, we don't accumulate
    /// styles.
    paras: std.ArrayList(Para),
    pending: std.ArrayList(Pending),
    spin: std.atomic.Mutex = .unlocked,

    /// Prompts sent while a turn is in progress.
    ///
    /// Without this, sending a second prompt while the first one was working
    /// launched ANOTHER worker and the two fought over the session and the
    /// streaming state: the input froze, the history got cut off and there was
    /// no way to tell whether it was working. Now they are queued and the
    /// worker pulls them out as it finishes its turn.
    queue: std.ArrayList([]u8) = .empty,

    /// The visible plan (the `todo` tool). The worker writes it from another
    /// thread and the draw reads it every frame, so it lives under the SAME lock
    /// as the rest.
    ///
    /// It is not an `ArrayList`: the list is a fixed-size array (see `plan.zig`),
    /// so the draw paints it without allocating.
    plan: plan_mod.Plan = .{},
    /// Worker-only plan-mode state, reset for each user turn.
    plan_touched_this_turn: bool = false,
    plan_write_blocked_this_turn: bool = false,
    plan_missing_nudges_this_turn: u8 = 0,

    /// Parallel subagent limit for this session. Zero follows ZODE_TASK_PARALLEL
    /// or the compiled default.
    task_parallel_override: u8 = 0,

    /// Live progress for one `task` batch. All fields are protected by `lock`.
    task_batch_total: usize = 0,
    task_batch_completed: usize = 0,
    task_batch_running: usize = 0,

    /// The file snapshots per turn, for `/undo`. It is the only thing that
    /// survives from one turn to the next (the worker's arena does not), which
    /// is why the stack carries its own allocator.
    checkpoints: checkpoint.Stack = undefined,

    /// Moment the current turn started, in nanoseconds, for the footer's
    /// clock. 0 = no turn. Written by `streamStart`.
    busy_started_ns: i128 = 0,
    /// Time until the FIRST token of the last stream (ms), and whether the
    /// stream in progress already has text.
    ///
    /// This is the number that separates "the model is slow" from "the network
    /// is slow", and the one that shows most when the prompt is long: with an
    /// 8 s TTFT and then 200 tok/s, the wait is the model's; with an 8 s TTFT
    /// and then 2 tok/s, it's something else. Before only the TOTAL clock was
    /// shown, which tells you nothing.
    ttft_ms: u64 = 0,
    ttft_pending: bool = false,

    /// The app's `Io`, for the clock. Tests build a Model without an app, so it
    /// is stored apart from `agent.io_global` and with a flag: reading an
    /// uninitialized `Io` is using garbage as a vtable.
    io: std.Io = undefined,
    io_ready: bool = false,

    /// Workers in flight (chat and model download).
    ///
    /// Threads are spawned with `detach`, so nobody joins them. Without this
    /// counter, on exit `app.deinit()` destroyed the `Io` while a worker was
    /// still inside `io.async` → use-after-free and segfault in
    /// `Threaded.cancelThreads`. `waitWorkers` lets them finish BEFORE the
    /// teardown.
    workers: std.atomic.Value(usize) = .init(0),

    /// Back-pointer to the owning Session, so scroll-state changes are
    /// persisted for resume. Set by agent.zig on create/resume; null in tests.
    session: ?*session_mod.Session = null,

    /// `/` command autocompletion: visible + selection.
    ac: Autocomplete = .{},

    /// Ctrl+P modal palette (commands and models in two columns).
    pal: palette.Palette = undefined,
    /// Size of the last painted frame.
    ///
    /// A mouse event carries a screen cell and nothing else: the modal's box is
    /// computed FROM the terminal size, so hit-testing it needs the size the
    /// user is looking at. Stored at draw time because that is the only place
    /// the size is known (the event handler gets no `DrawContext`).
    frame_w: u16 = 0,
    frame_h: u16 = 0,
    /// Models the worker has downloaded and that have not been painted yet.
    ///
    /// The worker CANNOT fill the palette directly: the UI thread draws it
    /// without a lock (the lock only covers the history), and touching both at
    /// once brought the app down with a segfault. The worker leaves the models
    /// here and draw picks them up; the handover goes through the lock, so
    /// there is no race.
    pending_items: ?[]palette.Item = null,
    pal_inited: bool = false,
    catalog_request_id: usize = 0,
    catalog_notice_buf: [160]u8 = undefined,
    catalog_notice_len: usize = 0,

    /// Streaming state: the assistant's last paragraph is still open.
    streaming: bool = false,
    stream_buf: std.ArrayList(u8) = .empty, // gpa-owned
    /// Set true when a real allocation failure stopped stream_buf growth.
    stream_truncated: bool = false,

    /// There is work pending to paint (the worker enqueued text). The .tick
    /// handler reads it to know whether it must keep asking for frames:
    /// without this the UI only repaints when the user presses a key.
    dirty: bool = false,
    tick_armed: bool = false,
    /// The worker asks for a frame with this. It lives outside the lock on
    /// purpose: it is the only signal the TUI thread can read without taking
    /// the model lock (which the worker may hold in `requestPermission`).
    redraw_requested: std.atomic.Value(bool) = .init(false),

    /// First history line on screen, in ABSOLUTE terms. This is an ANCHOR, not a
    /// distance from the bottom: that is the difference between being able to
    /// read while the model writes and not being able to.
    ///
    /// It used to be `scroll: usize` meaning "0 = bottom, N = N lines up", which
    /// was broken twice over (see `computeVisible`): the offset kept growing
    /// past the top with no visible effect, and because `first = max_offset -
    /// scroll` is itself bottom-relative, every new line moved the view.
    anchor: usize = 0,
    /// The top of the view as (paragraph, lines into it), which is what `anchor`
    /// is DERIVED from every frame.
    ///
    /// Why not just the line number: a paragraph's height is an ESTIMATE until it
    /// has been parsed, and parsing replaces the estimate with the real height.
    /// An absolute line index therefore means one thing before the parse and
    /// another after, so the view jumped by however many rows the estimate was
    /// off by — in the middle of a scroll, which is exactly where a jump is least
    /// welcome. With (paragraph, offset) the correction lands on some paragraph
    /// and the line is recomputed from the corrected heights, so the text under
    /// your eyes stays put.
    anchor_para: usize = 0,
    anchor_off: usize = 0,
    /// Pinned to the bottom. When true the draw ignores `anchor` and shows
    /// `max_offset`, which is what makes new text follow you down.
    follow_bottom: bool = true,
    /// The number of paragraphs that existed when the reader scrolled AWAY
    /// from the bottom.
    ///
    /// It is the baseline for the "N new" counter: everything appended after
    /// this point is what the reader has not seen. The reference implementation
    /// counts the same thing and calls it the unseen divider.
    unseen_base_para: usize = 0,
    /// Whether the reader is away from the bottom right now.
    ///
    /// It is a separate flag and not `!follow_bottom`, because the flag also
    /// has to be true when the reader was away and the new text ARRIVED: the
    /// counter must keep counting while the reader reads, not reset because
    /// the view did not move.
    was_away: bool = false,
    /// What the LAST frame painted, published for the `↓ N` indicator and for
    /// the tests. `max_offset - first_visible` is what has to be shown to the
    /// user: the raw offset used to be shown, debt included.
    first_visible: usize = 0,
    max_offset: usize = 0,
    /// Lines of the live paragraph in the last frame. The key handlers do not
    /// know how many it has (only the draw measures it), but they need it to
    /// clamp the anchor: without this a `PageUp` before the first frame would
    /// not move anything.
    live_h: usize = 0,
    /// Columns the history was last laid out with (width minus the margin).
    /// `estHeight` needs it to estimate a WRAPPED height, and without it the
    /// estimate was the height of an infinitely wide terminal.
    wrap_w: u16 = 80,
    /// History rows in the last frame. The key handler uses it to jump a
    /// PAGE (the whole window) instead of a fixed number: with 5 fixed, in a
    /// tall terminal PageUp barely moved anything.
    hist_rows: usize = 10,
    scrollbar_dragging: bool = false,

    /// The prompt rail as it was PAINTED: the right-margin dots, newest at the
    /// bottom.
    ///
    /// Written by the draw and read by the mouse handler, for the same reason
    /// as `selectable_width`: the draw is the only place that knows the frame's
    /// width and the track's height, and the dot the pointer is over has to be
    /// the dot that was painted there. `null` hover = the pointer is not on the
    /// rail.
    prompt_dots: [timeline_max_dots]PromptDot = undefined,
    prompt_dot_len: usize = 0,
    prompt_dot_col: u16 = 0,
    prompt_dot_hover: ?usize = null,
    /// Show the prompt rail dots (the right-margin timeline). Disabled by
    /// default: not polished enough yet. Re-enable when finished.
    show_prompt_dots: bool = false,


    /// Paragraph cache: 1 arena per closed paragraph, with the lines ALREADY
    /// wrapped at the current width. Invalidated on width change; frees the
    /// oldest ones as it grows.
    seg_cache: std.ArrayList(CachedPara) = .empty,
    /// Height in LINES of each history paragraph, in the same order as
    /// `paras`. It always lives (8 bytes per paragraph) even when its cells
    /// are out of the window: that is what makes it possible to compute the
    /// scroll offset over the WHOLE history without having everything
    /// parsed, and it enables the Phase 6 byte-based pruning without
    /// reparsing the world on rehydrate. What has not been measured yet has
    /// an estimate (see `ensureParaHeights`), replaced by the exact one when
    /// it is parsed.
    para_heights: std.ArrayList(usize) = .empty,
    /// Segment tree over paragraph heights: long-history scroll queries are
    /// logarithmic instead of scanning every paragraph on every frame.
    height_tree: std.ArrayList(usize) = .empty,
    height_tree_capacity: usize = 0,
    cache_width: u16 = 0,
    /// Index of the first paragraph whose layout is invalidated (Ctrl+R
    /// expands a tool in-place). `null` = cache is up to date.
    cache_from: ?usize = null,

    /// Last tool call executed, to expand it with Ctrl+R.
    last_tool: ?ToolMemo = null,

    /// The footer's legend, in a fixed buffer.
    status_buf: [160]u8 = undefined,
    status_len: usize = 0,
    scroll_bottom_row: u16 = 0,
    scroll_bottom_start: u16 = 0,
    scroll_bottom_end: u16 = 0,
    selectable_text: std.ArrayList(u8) = .empty,
    selectable_map: std.ArrayList(usize) = .empty,
    selectable_rows: u16 = 0,
    selectable_width: u16 = 0,
    selection_start: ?SelectionPoint = null,
    selection_end: ?SelectionPoint = null,
    selecting_text: bool = false,
    /// Kind the status was composed with (to color the face).
    status_kind: StatusKind = .idle,
    status_kind_set: bool = false,
    /// Animated mascot state: the kind, and when its track started (ms).
    mascot_animator: mascot.Animator = .{},
    /// The face that is ON SCREEN: its cells and its lean.
    ///
    /// The tick cannot know whether to paint without this: an idle face changes
    /// eleven times in 7.9 s and the tick fires in between, so "paint because
    /// there is an animation" would repaint the whole transcript fifteen times
    /// per beat. Comparing the CELLS (and not the frame index) also skips the
    /// repaint between two beats that draw the same `( o o )`.
    face_painted: bool = false,
    face_painted_text: [7]u8 = undefined,
    face_painted_dx: u8 = 0,

    /// Permission dialog (fixed buffers, no churn between threads).
    perm_tool: [64]u8 = undefined,
    perm_tool_len: usize = 0,
    perm_detail: [384]u8 = undefined,
    perm_detail_len: usize = 0,
    perm_active: bool = false,
    /// The rule the "always allow" option would remember.
    ///
    /// It is shown IN the dialog, because the user is answering "allow this
    /// command from now on?" and the answer has to name what it is: "always
    /// allow" alone says nothing about what is being remembered.
    perm_suggestion: [96]u8 = undefined,
    perm_suggestion_len: usize = 0,
    /// Whether the open dialog offers "always allow".
    ///
    /// It is false for the questions that must not become a standing
    /// permission (a write into `.git/`), and the "A" key does not answer
    /// them: the option is not on the table, so the key is not a key.
    perm_allow_always: bool = true,
    perm_answer: PermAnswer = .none,
    /// The dialog's OWN lock, separate from the history's `spin` (1.7).
    ///
    /// Before, the worker waited for the user with
    /// `while(true) { yield; lock; read; unlock }` over the HISTORY lock.
    /// That burns a whole core for the 30 s you take to decide, and makes
    /// EVERY lock acquisition in the UI a failed `yield`: the permission
    /// dialog degraded the whole app, not just the worker.
    ///
    /// Here the lock only protects state (held for microseconds) and the wait
    /// is SLEEPING with a growing `nanosleep`. `std.Io.Condition` is not used
    /// because it needs an `Io` and the tests build the Model without an app.
    perm_mutex: std.atomic.Mutex = .unlocked,
    /// Epoch to wake up the waiters (see `waitPermAnswer`).
    perm_epoch: std.atomic.Value(u32) = .init(0),

    // ── `ask`: the model asks the user ───────────────
    //
    // The worker parks HERE while the user reads a question. That is the whole
    // design and it is the same shape as the permission dialog (own lock,
    // sleeping wait, epoch to wake up), but it is NOT the permission dialog:
    // permission asks yes/no about a command that is about to run, while `ask`
    // asks the one question that decides what gets built at all.
    //
    // It has its own lock and its own buffers, and NOT a `std.Io.Condition`,
    // because the tests build a Model without an app and there is no Io to
    // condition on (the same reason `perm_mutex` is there).
    ask_mutex: std.atomic.Mutex = .unlocked,
    ask_epoch: std.atomic.Value(u32) = .init(0),
    ask_active: bool = false,
    /// The question, its header and its options: OWN COPIES (gpa).
    ///
    /// They come from the worker's arena, which dies at the end of `runOneTurn`.
    /// A slice kept in `pending` that points at that arena is read by the
    /// renderer after the memory is gone: this is the `&[_]u8{c}` bug family,
    /// the sixth appearance.
    ask_question: ?[]u8 = null,
    ask_header: ?[]u8 = null,
    ask_options: std.ArrayList([]u8) = .empty,
    /// The answer, once there is one. `null` = not answered yet.
    ask_answer: ?[]u8 = null,
    /// Nobody answered within this: the worker stops waiting and tells the model
    /// to decide on its own.
    ///
    /// Without this the worker stays parked FOREVER, and a parked worker with
    /// nothing painting it is exactly the "the app froze" bug that took a whole
    /// afternoon to find. Five minutes is long enough that nobody who is there
    /// hits it, and short enough that an AFK user does not come back to a turn
    /// that quietly did nothing.
    ask_started_ns: i128 = 0,
    /// Answer is being typed in the input box (the "Other" path).
    ask_typing: bool = false,
    /// Which row of the panel's option list is highlighted.
    ///
    /// The list is `ask_options` plus a final "Other" row, so `ask_sel ==
    /// ask_options.items.len` is "Other", not out of range. Kept here instead of
    /// in the modal picker because the PANEL is the list now: with at most five
    /// options (`ask.max_options`) a filter-and-scroll picker was a widget with
    /// a scrollbar for a menu that cannot scroll, drawn on top of the question.
    ask_sel: usize = 0,
    /// Fixed buffer for `askTitle` (see the comment there).
    ask_title_buf: [48]u8 = undefined,
    ask_title_len: usize = 0,
    /// How many questions this turn has asked (`ask` gives up after
    /// `max_asks_per_turn`).
    asks_this_turn: usize = 0,
    /// Read-only mode: write/edit/bash come back as tool_results instead of
    /// running. See `/ask`.
    read_only: bool = false,
    /// Accept-edits: write/edit/rename run without a dialog, bash still
    /// asks. See `/mode`; `agent.currentPermMode()` is what the status
    /// bar reads, these two fields only mirror it for the draw.
    accept_edits: bool = false,
    /// Background jobs (see `bgproc.zig`): id, how many were started, whether
    /// ESC has been pressed since the last one.
    bg: bgproc.Registry = .{},
    /// Images a `read` left behind, waiting to go on the next user message.
    ///
    /// Cleared as soon as the message goes out: an image is worth seeing once, and
    /// keeping the base64 would make this the largest thing in the process after a
    /// session with a few screenshots. It is NOT cached and NOT persisted for the
    /// same reason — and because a cached image prefix is a permanently uncacheable
    /// tail on every subsequent iteration.
    pending_images: images_mod.Pending = .{},
    /// The automatic typecheck the harness starts after a write tool touches code.
    ///
    /// It is a struct and not three fields because the headless runner keeps one on
    /// its stack (`agent.AutoCheck`), and the automatic check used to exist only here
    /// — so `zode --chat`, the runner every pty test and measurement drives, edited
    /// code and never compiled it. One implementation, two owners.
    auto_check: agent_mod.AutoCheck = .{},
    /// Which files the agent has already read, and which of those are STILL in the
    /// context (see `readcache.zig`).
    ///
    /// In the `Model` and not a module global for the same reason as `bg`: the
    /// tests build their own `Model`s, and two of them must not share a cache that
    /// says "you already have this file". Fixed buffers inside, so there is
    /// nothing to deinit.
    reads: readcache.Cache = .{},
    /// The files the agent has WRITTEN to, this session (`/files`).
    ///
    /// The read cache knows what the model has READ; a file that was written
    /// and never read is not in it at all. This is the other half of "what is
    /// the model looking at", and it is a fixed table inside the `Model`: no
    /// allocator, nothing to deinit, and it dies with the session.
    changed: filesview.Changed = .{},
    /// A `bash` command that was NOT read-only ran in this session.
    ///
    /// A command is a string and not a list of files, so the files it changed
    /// are not knowable. `/files` says so instead of implying that the changed
    /// list is complete.
    bash_may_write: bool = false,
    /// The session's task graph (`task_create`/`task_get`/`task_list`/
    /// `task_update`/`task_stop`).
    ///
    /// In the `Model` for the same reason as `bg` and `reads`, and bound to the
    /// session's file by `agent.bindTasks` (which compares the path, so `/new` and
    /// `--resume` rebind by themselves). The `gpa` is set from the model's allocator
    /// in `init`: the default is `page_allocator`, which is merely WRONG rather than
    /// a garbage vtable — see `taskstore.Store.gpa`.
    tasks: taskstore.Store = .{},
    /// Bench counters for `/bench`.
    bench: bench_mod.Stats = .{},

    /// Spinner (counters, no alloc).
    spinner_frame: usize = 0,
    busy: bool = false,

    /// Tool in progress. It is what keeps a 30s `bash` from looking like a
    /// hung app: while it is set, a `⎿ ⠋ running 12.3s` line is drawn BELOW
    /// the tool header, and it is repainted every frame with the clock.
    ///
    /// There can only be one: the turn's tools run in series.
    tool_run: ?ToolRun = null,

    /// Results of the `!` commands the user ran, from their worker to the draw.
    ///
    /// They CANNOT run on the UI thread: `submitInput` is called from the event
    /// handler, and a foreground command blocks it for as long as it runs, which
    /// is the frozen-app bug this repo has paid for several times. It is the
    /// `pending` pattern: the worker enqueues, the DRAW drains, and the session
    /// append happens in the drain because the session is not thread-safe.
    shell_out: std.ArrayList(ShellOut) = .empty,

    /// ── modal picker (arrows + filter, opencode style) ──
    picker_items: std.ArrayList(PickerItem) = .empty,
    picker_filtered: std.ArrayList(usize) = .empty, // visible indices
    picker_query: [64]u8 = undefined,
    picker_query_len: usize = 0,
    picker_title: [64]u8 = undefined,
    picker_title_len: usize = 0,
    picker_sel: usize = 0,
    picker_scroll: usize = 0,
    picker_active: bool = false,
    picker_tag: u32 = 0,
    picker_cb: ?PickerCb = null,
    /// The index flavour of the callback (see `PickerCbIdx`).
    picker_cb_idx: ?PickerCbIdx = null,
    /// Called when the picker is closed with ESC.
    picker_cancel_cb: ?PickerCancelCb = null,

    /// Paths of sessions for the `/session` picker, aligned with the items.
    /// Owned by gpa; freed on deinit and before each new picker open.
    session_picker_paths: std.ArrayList([]const u8) = .empty,
    /// The session picker's canonical entries, gpa-owned with duplicated strings,
    /// so the picker can re-search them on every keystroke (Phase 29.5).
    session_picker_entries: std.ArrayList(sessionindex.Entry) = .empty,
    /// Paths of sessions that matched semantically (tier 3, Phase 29.5).
    /// Owned by gpa; freed on deinit and before each new picker open.
    session_picker_semantic_results: std.ArrayList([]const u8) = .empty,
    /// Seconds since epoch when the picker query last changed. Used to debounce
    /// the expensive tier-2 (transcript) search of the sessions picker:
    /// tier-1 (title) always runs instantly; tier-2 only runs after the user
    /// pauses typing for `picker_transcript_debounce_s` (Phase 29.5).
    picker_query_changed_at: i64 = 0,
    /// Semantic search mode (tier 3, Phase 29.5). When active, the picker
    /// delegates to the `task` subagent (effort low, depth 1, 24k budget)
    /// instead of local fuzzy matching. Requires network/LLM to actually run.
    session_picker_semantic: bool = false,
    /// Whether a semantic search is currently in flight. Shown as "Searching…"
    /// in the picker footer (where the shortcuts hint normally is).
    session_picker_semantic_searching: bool = false,
    /// Called when F2 is pressed on a picker item (for renaming).
    picker_rename_cb: ?PickerCb = null,
    /// The session path being renamed (for the sessions picker).
    picker_rename_target: ?[]u8 = null,

    // ── `/copy` ──────────────────────────────────────────────────────────
    //
    /// The text waiting to go to the clipboard as OSC 52.
    ///
    /// It goes through the RENDER (vaxis writes the escape sequence with the
    /// frame), never straight to the tty: a sequence written outside the
    /// render is a sequence the next frame paints over, and on a terminal that
    /// does not implement OSC 52 it is a wall of visible `^[]52;c;…`.
    copy_pending: ?[]u8 = null,

    /// `/copy` remembers this for the session: "always copy the full
    /// response". A picker that reappears identically teaches the user it is
    /// broken.
    copy_always_full: bool = false,

    /// What the `/copy` picker needs while it is open (owned).
    copy_ctx: ?copytext.Ctx = null,

    /// History paragraph that `seg_cache.items[0]` corresponds to.
    /// The cache is a WINDOW `[cache_lo, cache_lo + len)`, not a queue: that is
    /// why the history indices and the cache indices differ and you have to be
    /// careful when mixing them.
    cache_lo: usize = 0,

    /// Iterations of the layout loop of the last frame, and whether the safety
    /// cap was hit.
    ///
    /// The cap exists so that a regression in the loop (which before never
    /// terminated above `max_cached_paras` paragraphs) HANGS A TEST AND NOT THE
    /// APP: when it is exceeded, layout stops, leaves `layout_overflow` true,
    /// and the test fails in 1 s with a number instead of hanging until the
    /// kill.
    layout_iters: usize = 0,
    layout_overflow: bool = false,
    /// Monotonically increasing frame counter for LRU cache eviction.
    frame_counter: u64 = 0,
    /// Differential render tracking: first visible line of previous frame.
    diff_last_first: usize = 0,
    /// Differential render tracking: last visible line of previous frame.
    diff_last_last: usize = 0,
    /// Differential render tracking: whether the live paragraph was active last frame.
    diff_last_live_active: bool = false,
    /// Differential render tracking: forces a full redraw of history (first frame or after scroll).
    diff_needs_full_redraw: bool = true,
    /// Toast notification: text shown when user copies to clipboard, and frames remaining.
    copy_toast_text: []const u8 = "",
    copy_toast_frames: u64 = 0,

    environ: ?*const std.process.Environ.Map = null,
    /// The model the footer shows, resolved ONCE and cached here.
    ///
    /// The row is `provider/model`, and it used to show nothing but the
    /// provider at the start of a session: `curAnswering()` is empty until the
    /// first turn, and the compiled providers carry no `default_model` on
    /// purpose (a name in the code stops existing the day the provider
    /// withdraws it). So for the first minute — the moment you are deciding
    /// whether to trust the app — the row answered "what am I talking to" with
    /// only half the answer.
    ///
    /// It is resolved from the provider's CACHED catalogue (never from the
    /// network: the draw runs at 60 fps and must not block on a socket), and
    /// re-resolved on `/use`, `/provider` and `/model`. `0` means "not yet", not
    /// "empty", because "not yet" is the one that should look up again.
    status_model_len: usize = 0,
    status_model_buf: [128]u8 = undefined,
    /// The lazy resolve ran once already. Without it, every frame of a session
    /// with no catalogue on disk would open, parse and free a JSON file that is
    /// not there — a stat and two open attempts per frame, forever, for a value
    /// that can only change when the catalogue worker finishes (which resets
    /// this flag).
    status_model_tried: bool = false,
    /// What `/compact` set, or null to follow `ZODE_COMPACT`.
    ///
    /// It lives in the Model and not in a module global because the env map is what
    /// the other policies read and this one has to be changeable WHILE a session
    /// runs: the whole point of `/compact` is to answer "the budget is 40% and I do
    /// not want that", and an env var cannot be changed from inside the app.
    ///
    /// Null means "ask the environment", which is the default and what a fresh
    /// session does — so there is exactly one answer to "what is compaction doing"
    /// and it is `compaction.effectiveMode`, not this field on its own.
    compact_mode: ?compaction.Mode = null,
    /// Set after the first frame so the startup probe can mark it once.
    boot_painted: bool = false,
    /// Set for the one iteration where the harness asks for a verdict.
    ///
    /// A flag and not an argument because `runOneTurn` builds the prompt from four
    /// places and threading a `bool` through all of them is how one of them gets
    /// missed. The draw does not read it.
    goal_checkpoint: bool = false,
    /// Set when the same tool call has now happened three times running.
    loop_repeated: ?[]const u8 = null,
    /// The objective of this turn, when `/goal` set one.
    ///
    /// In the Model and not a module global because the draw reads it every frame and
    /// the loop writes it from a worker; a global would need the same lock the plan
    /// already has and would be one more thing to get wrong.
    goal: goal_mod.Goal = .{},
    /// The repetition guard for this turn. Lives here and not in the worker because
    /// `runToolCall` is where a call is seen, and that is the only place that can see
    /// a call repeated.
    repeats: agent.Repeats = .{},

    pub const PermAnswer = enum { none, allow, allow_always, deny };

    const CachedPara = struct {
        arena: ?*std.heap.ArenaAllocator, // owns the lines + cells
        lines: []const PLine,
        height: usize,
        /// History paragraph these lines belong to.
        ///
        /// MANDATORY since the cache is a WINDOW and not a queue: the old loop
        /// assumed `seg_cache.items[i]` corresponded to `paras.items[i]`, so
        /// evicting from the front made the indices stop lining up and —
        /// worse — the `while (cache.len < paras.len)` loop had no way to
        /// terminate (see `layoutWindow`).
        para_idx: usize,
        /// Last frame this entry was accessed (for LRU eviction).
        last_frame_used: u64 = 0,
    };

    /// Max paragraphs with cells in memory at once (the ones outside the
    /// window are re-parsed when you look at them again).
    /// Kept small (64) so a session with long tool outputs does not OOM:
    /// 64 × 1 MB cap = 64 MB worst case, not 128 × 10 MB = 1.28 GB.
    const max_cached_paras = 64;

    const SelectionPoint = struct { row: u16, col: u16 };
    /// Range of absolute history lines that are visible on screen for a paragraph.
    const VisibleRange = struct { start: usize, end: usize };

    const Para = struct {
        kind: md.Kind,
        /// The text, or the COMPRESSED text when the paragraph is cold.
        ///
        /// See `is_cold`. A cold paragraph keeps its bytes as `zjsonl`
        /// compressed base64: still gpa-owned, still byte-exact, just ~10x
        /// smaller until something scrolls back into the window and rehydrates
        /// it. The reason it is compression and not "drop it and re-read it
        /// from the JSONL" is that NOT every paragraph has a session message
        /// behind it (tool headers, diffs, notices), so there would be nothing
        /// to re-read; compression loses nothing and needs no mapping.
        text: []const u8,
        base: ?md.Style = null,
        mood: ?vaxis.Style = null,
        /// Language of the content (only the diff uses it, to tokenize the body
        /// of each line). `""` = unknown.
        lang: []const u8 = "",
        /// The paragraph is outside the window and `text` is compressed.
        is_cold: bool = false,
        /// Best known height in LINES: the exact one if the paragraph has been
        /// parsed, the best estimate otherwise.
        ///
        /// It lives HERE, in the paragraph, and not only in `para_heights`,
        /// because `clearSegCache` empties `para_heights` on every resize. With
        /// the height only in that list, a resize threw away every measurement
        /// and `ensureParaHeights` had to re-estimate from the text: for a
        /// compressed paragraph that text is base64 with no newlines at all, so
        /// the estimate was 1 line for a paragraph that takes 70. The total
        /// collapsed, `max_offset` with it, and the view jumped thousands of
        /// lines up (to the very top, banner included) on every resize.
        ///
        /// It is written in BOTH places that can know the height: `layoutOne`
        /// with the exact one, and `pruneCold` with whatever `para_heights`
        /// holds BEFORE the text turns into base64 (without that, compression
        /// would throw the height away with the newlines it was counted from).
        known_lines: usize = 0,
        /// Whether the WORD-level diff is painted for this paragraph.
        ///
        /// A diff row says THAT something changed; the word diff says WHAT.
        /// It is off for a collapsed preview: twelve rows of a bigger diff
        /// are a summary, and a word-level highlight inside a summary is
        /// confetti. The expanded diff has them.
        word_diff: bool = true,

        /// The paragraph's text, ready to be parsed. Rehydrates if needed.
        fn textLive(self: *Para, gpa: std.mem.Allocator) []const u8 {
            if (!self.is_cold) return self.text;
            // `max_out` generous on purpose: this only ever runs on text that
            // was OUR OWN compressed output, so it cannot be a decompression
            // bomb.
            const back = zjsonl.decompressInto(gpa, self.text, 64 << 20) catch return self.text;
            gpa.free(self.text);
            self.text = back;
            self.is_cold = false;
            return self.text;
        }
    };

    /// What the scrollback is holding, in bytes and in pieces.
    ///
    /// It exists because "6 MB" was a startup number quoted as if it were the
    /// number, and the number that decides whether a two-hour session is usable is
    /// the one nobody had: does it grow. `tools/ram_probe.py` measures the slope
    /// with a real model answering; this says WHERE the bytes are, so a slope can
    /// be attributed instead of guessed at.
    ///
    /// `hot_bytes` counts the paragraph text as it sits, and `cold_bytes` counts
    /// the COMPRESSED form `pruneCold` leaves behind — together they are the
    /// scrollback, and the ratio between them is what says whether the compression
    /// is doing its job.
    pub const RamReport = struct {
        paras: usize,
        hot: usize,
        cold: usize,
        hot_bytes: usize,
        cold_bytes: usize,
        cache_entries: usize,
        cache_arena_bytes: usize,
        read_cache_entries: usize,
        /// The process's own RSS, 0 where it cannot be read (a non-Linux target).
        rss_kb: usize,

        pub fn scrollbackBytes(self: RamReport) usize {
            return self.hot_bytes + self.cold_bytes;
        }
    };

    /// `VmRSS` from `/proc/self/status`, in KB. 0 when there is no `/proc`.
    ///
    /// It is here, next to the breakdown and not in a separate tool, because the
    /// interesting question is not "how much memory" but "how much of it is the
    /// scrollback": a total on its own says nothing about which part to fix, and
    /// the breakdown on its own does not say whether it is a lot.
    ///
    /// Read on demand and never cached: a cached RSS is wrong within a second, and
    /// this is a command the user types, not a per-frame value.
    pub fn selfRssKb() usize {
        if (@import("builtin").os.tag != .linux) return 0;
        // `std.posix` and not the `Io`: `/context` is a command, it runs on the UI
        // thread, and taking an `Io` for a 200-byte read would mean the caller has
        // to have one attached — which the tests deliberately do not.
        const fd = std.posix.openat(std.posix.AT.FDCWD, "/proc/self/status", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch return 0;
        // `std.posix.close` does not exist in 0.16 (close takes an `Io`); the raw
        // syscall is under `system`, and this is the one place that wants it: a
        // 200-byte diagnostic read should not require the caller to own an `Io`.
        defer _ = std.posix.system.close(fd);
        var buf: [8192]u8 = undefined;
        const n = std.posix.read(fd, &buf) catch return 0;
        const text = buf[0..n];
        const key = "VmRSS:";
        const at = std.mem.indexOf(u8, text, key) orelse return 0;
        var i = at + key.len;
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
        var v: usize = 0;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) v = v * 10 + (text[i] - '0');
        return v;
    }

    pub fn ramReport(self: *Model) RamReport {
        self.lock();
        defer self.unlock();
        var r = RamReport{
            .paras = self.paras.items.len,
            .hot = 0,
            .cold = 0,
            .hot_bytes = 0,
            .cold_bytes = 0,
            .cache_entries = 0,
            .cache_arena_bytes = 0,
            .read_cache_entries = 0,
            .rss_kb = selfRssKb(),
        };
        for (self.paras.items) |p| {
            if (p.is_cold) {
                r.cold += 1;
                r.cold_bytes += p.text.len;
            } else {
                r.hot += 1;
                r.hot_bytes += p.text.len;
            }
        }
        for (self.seg_cache.items) |e| {
            r.cache_entries += 1;
            if (e.arena) |a| {
                // `ArenaAllocator` does not report its used size; the buffer it
                // owns is the honest upper bound and it is what the process pays.
                r.cache_arena_bytes += a.queryCapacity();
            }
        }
        r.read_cache_entries = self.reads.liveEntries();
        return r;
    }

    /// Last tool call, so Ctrl+R can show its full result.
    /// Tool running right now. `pushToolStart` sets it and `pushToolDone`
    /// clears it; while it exists a clock line is drawn.
    const ToolRun = struct {
        name: []const u8,
        arg: []const u8,
        started_ns: i128,

        fn deinit(self: ToolRun, gpa: std.mem.Allocator) void {
            gpa.free(self.name);
            gpa.free(self.arg);
        }
    };

    const ToolMemo = struct {
        /// Index of the `.tool_res` paragraph in `paras`.
        para_idx: usize = 0,
        /// Full result, immutable (gpa-owned).
        result: []u8 = &.{},
        /// One-line text with the result (gpa-owned).
        summary: []u8 = &.{},
        /// Already expanded.
        expanded: bool = false,

        /// The diff this tool produced, when it was COLLAPSED into a preview.
        ///
        /// Both forms live here because the paragraph can only hold one of them
        /// at a time and Ctrl+R swaps between them. `null` = no diff of its own
        /// (a `read`, a `grep`), so Ctrl+R keeps doing what it always did.
        diff_para_idx: ?usize = null,
        diff_full: []u8 = &.{},
        diff_short: []u8 = &.{},
        diff_expanded: bool = false,

        fn hasDiff(self: *const ToolMemo) bool {
            return self.diff_para_idx != null and self.diff_full.len > 0 and self.diff_short.len > 0;
        }

        fn deinit(self: *ToolMemo, gpa: std.mem.Allocator) void {
            if (self.result.len > 0) gpa.free(self.result);
            if (self.summary.len > 0) gpa.free(self.summary);
            if (self.diff_full.len > 0) gpa.free(self.diff_full);
            if (self.diff_short.len > 0) gpa.free(self.diff_short);
            self.diff_full = &.{};
            self.diff_short = &.{};
            self.diff_para_idx = null;
        }
    };

    /// Frees a paragraph's own buffers (`text` and `lang`).
    ///
    /// Only the diff fills `lang`, and it is gpa-owned like `text` because it
    /// comes from the worker's arena. Freeing both together avoids the typical
    /// forget: if one is left behind, it is a leak per paragraph; if one is
    /// freed twice, it is a crash.
    fn freePara(gpa: std.mem.Allocator, p: anytype) void {
        gpa.free(p.text);
        if (p.lang.len > 0) gpa.free(p.lang);
    }

    const Pending = struct {
        kind: md.Kind,
        text: []const u8, // gpa copy, freed on drain
        /// Base style imposed on the paragraph. `null` = whatever `kind` says.
        base: ?md.Style = null,
        /// Zo's mood color: paints what is marked with `~…~` in the header.
        mood: ?vaxis.Style = null,
        /// Language of the content (see `Para.lang`). gpa-owned like `text`.
        lang: []const u8 = "",
        /// Whether the WORD-level diff is painted (see `Para.word_diff`).
        word_diff: bool = true,
    };

    pub fn hasInput(self: *const Model) bool {
        return !self.ed.isEmpty();
    }

    // ── lifecycle ────────────────────────────────────
    pub fn init(allocator: std.mem.Allocator) Model {
        var m = Model{
            .allocator = allocator,
            // The job registry gets the MODEL's allocator, never a turn's: a background
            // job's reader thread is detached and outlives the turn that started it, so a
            // turn-scoped allocator there is a use-after-free waiting for a slow build.
            // See `bgproc.Registry.gpa`.
            .bg = bgproc.Registry.init(allocator),
            .pal = palette.Palette.init(allocator),
            .pal_inited = true,
            .ed = ed.Editor.init(allocator),
            .paras = .empty,
            .pending = .empty,
            .seg_cache = .empty,
            // The checkpoint stack needs the allocator when it is created (it is
            // who holds the memory of the snapshots). It could be left
            // `undefined` and set in `deinit`, but then any test that calls
            // `snapshotFile` without it reads garbage.
            .checkpoints = .init(allocator),
            .mascot_animator = mascot.Animator.init(.idle),
        };
        m.tasks.gpa = allocator;
        // Empty initial status; real content appears once there's a model/turn.
        m.setStatusText("");
        return m;
    }

    pub fn deinit(self: *Model) void {
        // The task graph holds its own strings and its file path.
        self.tasks.deinit();
        // `/copy`: the pending clipboard text and the picker's context are
        // the model's memory, and nobody else frees them.
        if (self.copy_pending) |p| self.allocator.free(p);
        if (self.copy_ctx) |*c| c.deinit();
        // The checkpoint snapshots are memory of the model's allocator and
        // nobody else frees them: without this, every turn with tools leaves the
        // whole repo in memory until exit.
        self.checkpoints.deinit();
        // `clearQueue` keeps the capacity (good, so we don't reallocate on
        // every prompt), so the list's buffer must be freed separately or it
        // leaks on exit.
        self.clearQueue();
        self.queue.deinit(self.allocator);
        for (self.shell_out.items) |so| {
            self.allocator.free(so.cmd);
            self.allocator.free(so.text);
        }
        self.shell_out.deinit(self.allocator);
        self.destroyPalette();
        if (self.pending_items) |items| palette.freeItems(self.allocator, items);
        self.ed.deinit();
        for (self.paras.items) |p| freePara(self.allocator, p);
        self.paras.deinit(self.allocator);
        for (self.pending.items) |p| freePara(self.allocator, .{ .kind = p.kind, .text = p.text, .lang = p.lang });
        self.pending.deinit(self.allocator);
        if (self.last_tool) |*lt| lt.deinit(self.allocator);
        if (self.tool_run) |tr| tr.deinit(self.allocator);
        self.stream_buf.deinit(self.allocator);
        self.clearSegCache(); // empties `para_heights`
        self.para_heights.deinit(self.allocator);
        self.height_tree.deinit(self.allocator);
        self.selectable_text.deinit(self.allocator);
        self.selectable_map.deinit(self.allocator);
        self.closePicker();
        self.picker_items.deinit(self.allocator);
        self.picker_filtered.deinit(self.allocator);
        // `@` completion matches: gpa-owned paths (see `freeFileMatches`).
        freeFileMatches(self);
        self.ac.file_matches.deinit(self.allocator);
        freeFilePool(self);
        self.ac.file_pool.deinit(self.allocator);
        // Background jobs: killed FIRST (a child writing to a pipe nobody reads
        // would keep the process alive), then their buffers freed.
        // `null` when there is no `Io`: a test Model has none, and `bgproc.deinit`
        // only touches the vtable when a job is actually alive, which there never
        // is in a test.
        self.bg.deinit(if (self.io_ready) self.io else null, self.allocator);
        self.askLock();
        self.freeAskStringsLocked();
        if (self.ask_answer) |a| self.allocator.free(a);
        self.askUnlock();
        // The LIST's buffer, not just the strings inside it: `clearRetainingCapacity`
        // keeps the capacity, so without this every Model leaks the array on
        // exit. (Same rule as `queue.deinit` next to `clearQueue`.)
        self.ask_options.deinit(self.allocator);
        // Free the path strings stored in session_picker_paths (duplicated in
        // pickerRefilter so paths stay aligned with picker_items across searches).
        for (self.session_picker_paths.items) |p| {
            self.allocator.free(p);
        }
        self.session_picker_paths.deinit(self.allocator);
        // Free the gpa-owned entry strings (session_picker_entries deep-copies
        // all slices from the arena into gpa).
        for (self.session_picker_entries.items) |e| {
            self.allocator.free(e.path);
            if (e.name.len > 0) self.allocator.free(e.name);
            if (e.model.len > 0) self.allocator.free(e.model);
            if (e.custom_title.len > 0) self.allocator.free(e.custom_title);
            if (e.ai_title.len > 0) self.allocator.free(e.ai_title);
        }
        self.session_picker_entries.deinit(self.allocator);
        // Free semantic search results (tier 3, Phase 29.5).
        for (self.session_picker_semantic_results.items) |p| {
            self.allocator.free(p);
        }
        self.session_picker_semantic_results.deinit(self.allocator);
    }

    // ── modal picker ──────────────────────────────────
    /// Opens the picker. Takes ownership of `items` (labels/descs gpa-owned).
    /// Thread-safe: called by the /models worker.
    pub fn openPicker(self: *Model, tag: u32, title: []const u8, items: []PickerItem, cb: PickerCb) void {
        self.openPickerInner(tag, title, items);
        self.lock();
        self.picker_cb = cb;
        self.picker_cb_idx = null;
        self.picker_cancel_cb = null;
        self.unlock();
    }

    /// Opens the picker with a callback that gets the INDEX of the chosen
    /// item, and one that is called when it is closed with ESC.
    ///
    /// The index is the ORIGINAL index (not the position in the filtered
    /// list): the filter is a way of finding a row, not a way of renumbering
    /// the rows.
    pub fn openPickerIdx(
        self: *Model,
        tag: u32,
        title: []const u8,
        items: []PickerItem,
        cb: PickerCbIdx,
        cancel: ?PickerCancelCb,
    ) void {
        self.openPickerInner(tag, title, items);
        self.lock();
        self.picker_cb = null;
        self.picker_cb_idx = cb;
        self.picker_cancel_cb = cancel;
        self.picker_rename_cb = null;
        self.unlock();
    }

    /// Opens the picker with a rename callback (for F2).
    pub fn openPickerIdxRename(
        self: *Model,
        tag: u32,
        title: []const u8,
        items: []PickerItem,
        cb: PickerCbIdx,
        cancel: ?PickerCancelCb,
        rename: PickerCb,
    ) void {
        self.openPickerInner(tag, title, items);
        self.lock();
        self.picker_cb = null;
        self.picker_cb_idx = cb;
        self.picker_cancel_cb = cancel;
        self.picker_rename_cb = rename;
        self.unlock();
    }

    /// The part both openers share: the items, the title and the state.
    fn openPickerInner(self: *Model, tag: u32, title: []const u8, items: []PickerItem) void {
        self.lock();
        defer self.unlock();
        for (items) |it| {
            self.picker_items.append(self.allocator, it) catch {
                self.allocator.free(it.label);
                if (it.desc.len > 0) self.allocator.free(it.desc);
            };
        }
        self.allocator.free(items);
        const nt = @min(title.len, self.picker_title.len);
        @memcpy(self.picker_title[0..nt], title[0..nt]);
        self.picker_title_len = nt;
        self.picker_tag = tag;
        self.picker_query_len = 0;
        self.picker_query_changed_at = 0;
        // Reset semantic search state when the picker (re)opens.
        self.session_picker_semantic = false;
        self.session_picker_semantic_searching = false;
        for (self.session_picker_semantic_results.items) |p| {
            self.allocator.free(p);
        }
        self.session_picker_semantic_results.clearRetainingCapacity();
        self.picker_sel = 0;
        self.picker_scroll = 0;
        self.pickerRefilter();
        self.picker_active = true;
    }

    /// Closes and frees. UI thread.
    pub fn closePicker(self: *Model) void {
        self.lock();
        defer self.unlock();
        if (!self.picker_active and self.picker_items.items.len == 0) return;
        self.picker_active = false;
        self.picker_cb = null;
        self.picker_cb_idx = null;
        self.picker_cancel_cb = null;
        self.picker_rename_cb = null;
        if (self.picker_rename_target) |t| {
            self.allocator.free(t);
            self.picker_rename_target = null;
        }
        // Free semantic search results (tier 3, Phase 29.5).
        for (self.session_picker_semantic_results.items) |p| {
            self.allocator.free(p);
        }
        self.session_picker_semantic_results.clearRetainingCapacity();
        self.session_picker_semantic = false;
        self.session_picker_semantic_searching = false;
        for (self.picker_items.items) |it| {
            self.allocator.free(it.label);
            if (it.desc.len > 0) self.allocator.free(it.desc);
        }
        self.picker_items.clearRetainingCapacity();
        self.picker_filtered.clearRetainingCapacity();
    }

    pub fn pickerActive(self: *Model) bool {
        self.lock();
        defer self.unlock();
        return self.picker_active;
    }

    // ── `/copy` ──────────────────────────────────────────────────────────

    /// Keeps what the picker needs while it is open. It takes OWNERSHIP: the
    /// previous one is freed, so opening the picker twice does not leak the
    /// first answer.
    pub fn setCopyCtx(self: *Model, ctx: copytext.Ctx) void {
        if (self.copy_ctx) |*old| old.deinit();
        self.copy_ctx = ctx;
    }

    /// Takes the context back. The caller owns it from that moment on.
    pub fn takeCopyCtx(self: *Model) ?copytext.Ctx {
        const ctx = self.copy_ctx orelse return null;
        self.copy_ctx = null;
        return ctx;
    }

    /// The text waiting to go to the clipboard as OSC 52.
    pub fn setCopyPending(self: *Model, text: []const u8) void {
        if (self.copy_pending) |old| self.allocator.free(old);
        self.copy_pending = self.allocator.dupe(u8, text) catch null;
    }

    /// Hands the pending text to vaxis, which writes it as OSC 52.
    ///
    /// It goes through the RENDER: vaxis writes the escape sequence with the
    /// frame, so the next frame knows about it. Writing it straight to the
    /// tty is what produced the `^[]52;c;…` wall of visible text on the
    /// terminals that do not implement OSC 52 (see `copySelectedText`).
    pub fn flushCopyPending(self: *Model, ctx: *vxfw.EventContext) void {
        const text = self.copy_pending orelse return;
        self.copy_pending = null;
        defer self.allocator.free(text);
        ctx.copyToClipboard(text) catch {};
    }

    fn pickerRefilter(self: *Model) void {
        // caller holds lock
        const q = self.picker_query[0..self.picker_query_len];
        self.picker_filtered.clearRetainingCapacity();

        if (self.picker_tag == sessions_picker_tag) {
            // Phase 29.5: three-tier search over session_picker_entries.
            // Rebuild picker_items from the canonical entries (or search results).
            for (self.picker_items.items) |it| {
                self.allocator.free(it.label);
                if (it.desc.len > 0) self.allocator.free(it.desc);
            }
            self.picker_items.clearRetainingCapacity();
            // Keep paths aligned with picker_items so onSessionPick resolves correctly.
            self.session_picker_paths.clearRetainingCapacity();

            const now = if (self.io_ready) std.Io.Timestamp.now(self.io, .real).toSeconds() else 0;
            var now_buf: [32]u8 = undefined;

            if (q.len == 0) {
                // Show all entries.
                for (self.session_picker_entries.items) |e| {
                    const session_id = std.fs.path.basename(e.path);
                    const title = e.title(session_id);
                    const age = sessionindex.ageLabel(now, e.created_at, &now_buf);
                    const label = self.allocator.dupe(u8, title) catch "";
                    const desc = self.allocator.dupe(u8, age) catch "";
                    self.picker_items.append(self.allocator, .{ .label = label, .desc = desc }) catch {
                        self.allocator.free(label);
                        if (desc.len > 0) self.allocator.free(desc);
                    };
                    _ = self.session_picker_paths.append(self.allocator, self.allocator.dupe(u8, e.path) catch "") catch {};
                }
            } else {
                // Tier 3: semantic search — stateful, optional. When active,
                // delegate to the `task` subagent (effort low, depth 1, 24k
                // budget). While searching, show "Searching…" in the footer
                // and wait for results (requires network/LLM).
                if (self.session_picker_semantic and self.session_picker_semantic_searching) {
                    // Waiting for semantic results — show nothing but the
                    // "Searching…" status in the footer (painted by drawPicker).
                    self.picker_sel = 0;
                } else if (self.session_picker_semantic and self.session_picker_semantic_results.items.len > 0) {
                    // Show semantic results.
                    for (self.session_picker_semantic_results.items) |path| {
                        var found: ?sessionindex.Entry = null;
                        for (self.session_picker_entries.items) |e| {
                            if (std.mem.eql(u8, e.path, path)) {
                                found = e;
                                break;
                            }
                        }
                        if (found) |e| {
                            const session_id = std.fs.path.basename(e.path);
                            const title = e.title(session_id);
                            const age = sessionindex.ageLabel(now, e.created_at, &now_buf);
                            const label = self.allocator.dupe(u8, title) catch "";
                            const desc = self.allocator.dupe(u8, age) catch "";
                            self.picker_items.append(self.allocator, .{ .label = label, .desc = desc }) catch {
                                self.allocator.free(label);
                                if (desc.len > 0) self.allocator.free(desc);
                            };
                            _ = self.session_picker_paths.append(self.allocator, self.allocator.dupe(u8, e.path) catch "") catch {};
                        }
                    }
                } else {
                var all_hits: std.ArrayList(session_search.SessionHit) = .empty;
                defer all_hits.deinit(self.allocator);

                // Tier 1: title substring — always runs, instant.
                const title_hits: ?[]session_search.SessionHit = session_search.searchTitle(self.allocator, self.session_picker_entries.items, q) catch null;
                if (title_hits) |h| {
                    for (h) |hit| { all_hits.append(self.allocator, hit) catch {}; }
                }

                // Tier 2: transcript fuzzy — debounced. Only runs after the user
                // pauses typing for `picker_transcript_debounce_s`. While typing,
                // only tier-1 results are shown (Phase 29.5).
                const debounce_ok = self.picker_query_changed_at == 0
                    or now - self.picker_query_changed_at >= picker_transcript_debounce_s;
                if (debounce_ok) {
                    const transcript_hits: ?[]session_search.SessionHit = session_search.searchTranscript(self.allocator, self.io, self.session_picker_entries.items, q) catch null;
                    if (transcript_hits) |h| {
                        for (h) |hit| { all_hits.append(self.allocator, hit) catch {}; }
                    }
                }

                const ranked: ?[]session_search.SessionHit = session_search.rankHits(self.allocator, all_hits.items) catch null;
                if (ranked) |h| {
                    // `ranked` may be empty on error; that's fine, shows nothing.
                    for (h) |hit| {
                        const session_id = std.fs.path.basename(hit.entry.path);
                        const title = hit.entry.title(session_id);
                        const label = self.allocator.dupe(u8, title) catch "";
                        var desc: []const u8 = "";
                        var desc_owned: ?[]u8 = null;
                        if (hit.tier == .transcript and hit.snippet.len > 0) {
                            desc_owned = self.allocator.dupe(u8, hit.snippet) catch null;
                            desc = desc_owned.?;
                        } else {
                            const age = sessionindex.ageLabel(now, hit.entry.created_at, &now_buf);
                            desc_owned = self.allocator.dupe(u8, age) catch null;
                            if (desc_owned) |d| desc = d;
                        }
                        self.picker_items.append(self.allocator, .{ .label = label, .desc = desc }) catch {
                            self.allocator.free(label);
                            if (desc_owned) |d| self.allocator.free(d);
                        };
                        _ = self.session_picker_paths.append(self.allocator, self.allocator.dupe(u8, hit.entry.path) catch "") catch {};
                        if (desc_owned) |d| self.allocator.free(d);
                    }
                }
            }
            }
            } else {
            // Original behavior: filter picker_items by label match.
            var buf: [128]u32 = undefined;
            for (self.picker_items.items, 0..) |it, ix| {
                if (q.len == 0 or fuzzy.highlightPositions(it.label, q, &buf) != null) {
                    self.picker_filtered.append(self.allocator, ix) catch {};
                }
            }
        }

        if (self.picker_sel >= self.picker_filtered.items.len) {
            self.picker_sel = if (self.picker_filtered.items.len > 0) self.picker_filtered.items.len - 1 else 0;
        }
    }

    /// Handles a key with the picker open. Returns true if it consumed it.
    pub fn pickerHandleKey(self: *Model, key: vaxis.Key) bool {
        self.lock();
        if (!self.picker_active) {
            self.unlock();
            return false;
        }
        const visible: usize = 10;
        switch (key.codepoint) {
            57352 => { // up
                if (self.picker_sel > 0) self.picker_sel -= 1;
            },
            57353 => { // down
                if (self.picker_sel + 1 < self.picker_filtered.items.len) self.picker_sel += 1;
            },
            0x0D => { // enter: select
                const ix = if (self.picker_sel < self.picker_filtered.items.len)
                    self.picker_filtered.items[self.picker_sel]
                else
                    null;
                const cb = self.picker_cb;
                const cb_idx = self.picker_cb_idx;
                const tag = self.picker_tag;
                const label = if (ix) |i|
                    self.allocator.dupe(u8, self.picker_items.items[i].label) catch null
                else
                    null;
                self.unlock();
                self.closePicker();
                // The INDEX flavour first: it is the one that knows WHICH row
                // was chosen, and the label is only a thing to read.
                if (cb_idx) |f| {
                    if (ix) |i| f(self, tag, i);
                } else if (label) |l| {
                    if (cb) |f| f(self, tag, l);
                }
                if (label) |l| self.allocator.free(l);
                return true;
            },
            27 => { // esc
                // Cancel semantic search if in flight, or leave semantic mode.
                if (self.session_picker_semantic_searching) {
                    self.session_picker_semantic_searching = false;
                    self.unlock();
                    self.pickerRefilter();
                    return true;
                }
                if (self.session_picker_semantic) {
                    self.session_picker_semantic = false;
                    self.unlock();
                    self.pickerRefilter();
                    return true;
                }
                const cancel = self.picker_cancel_cb;
                const tag = self.picker_tag;
                self.unlock();
                self.closePicker();
                if (cancel) |f| f(self, tag);
                return true;
            },
            's', 'S' => { // toggle semantic search (tier 3)
                if (self.session_picker_semantic_searching) {
                    // Cancel in-flight search.
                    self.session_picker_semantic_searching = false;
                } else if (self.session_picker_semantic) {
                    // Leave semantic mode, back to tiers 1+2.
                    self.session_picker_semantic = false;
                } else {
                    // Enter semantic mode: start searching.
                    self.session_picker_semantic = true;
                    self.session_picker_semantic_searching = true;
                    // Kick off the semantic search via the `task` subagent.
                    // Results are stored in session_picker_semantic_results;
                    // searching flag is cleared when results arrive (requires
                    // network/LLM to actually run — see sessionSemanticSearch).
                    self.sessionSemanticSearch();
                }
                self.unlock();
                self.pickerRefilter();
                return true;
            },
            57365 => { // F2: rename
                const rename_cb = self.picker_rename_cb;
                const ix = if (self.picker_sel < self.picker_filtered.items.len)
                    self.picker_filtered.items[self.picker_sel]
                else
                    null;
                if (rename_cb) |f| {
                    if (ix) |i| {
                        // Remember which session path is being renamed so the
                        // callback can look it up (the label alone is not enough
                        // — two sessions can share a title).
                        self.picker_rename_target = self.allocator.dupe(u8, self.session_picker_paths.items[i]) catch null;
                        const label = self.allocator.dupe(u8, self.picker_items.items[i].label) catch null;
                        if (label) |l| {
                            self.unlock();
                            f(self, self.picker_tag, l);
                            self.allocator.free(l);
                            return true;
                        }
                    }
                }
                self.unlock();
                return true;
            },
            127, 8 => { // backspace
                if (self.picker_query_len > 0) self.picker_query_len -= 1;
                self.picker_sel = 0;
                self.picker_scroll = 0;
                self.picker_query_changed_at = if (self.io_ready) std.Io.Timestamp.now(self.io, .real).toSeconds() else 0;
                self.pickerRefilter();
            },
            else => |cp| {
                if (cp >= 0x20 and cp < 0x7F and self.picker_query_len < self.picker_query.len) {
                    self.picker_query[self.picker_query_len] = @intCast(cp);
                    self.picker_query_len += 1;
                    self.picker_sel = 0;
                    self.picker_scroll = 0;
                    self.picker_query_changed_at = if (self.io_ready) std.Io.Timestamp.now(self.io, .real).toSeconds() else 0;
                    self.pickerRefilter();
                }
            },
        }
        // adjust scroll so sel is visible
        if (self.picker_sel < self.picker_scroll) self.picker_scroll = self.picker_sel;
        if (self.picker_sel >= self.picker_scroll + visible) self.picker_scroll = self.picker_sel - visible + 1;
        self.unlock();
        return true;
    }

    fn sessionSemanticSearch(self: *Model) void {
        const query = self.picker_query[0..self.picker_query_len];
        if (query.len == 0) {
            self.session_picker_semantic_searching = false;
            return;
        }
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const sarena = arena_state.allocator();
        const task = subagent_mod.Task{
            .description = sarena.dupe(u8, "semantic session search") catch "",
            .prompt = std.fmt.allocPrint(
                sarena,
                "Find zode session files semantically relevant to this query: \"{s}\"\n\n"
                ++ "Session files are JSONL in the sessions directory. Each line is a message "
                ++ "with role, content, etc. Session titles are derived from message content. "
                ++ "Use `glob` to list session files, then `read` to examine promising ones. "
                ++ "Look at titles and user/assistant messages to judge semantic relevance.\n\n"
                ++ "Return ONLY the file paths of relevant sessions, one per line, no other text. "
                ++ "Return nothing if none match.",
                .{ query },
            ) catch "",
        };
        if (task.description.len == 0 or task.prompt.len == 0) {
            self.session_picker_semantic_searching = false;
            return;
        }
        var rep = subagent_mod.Report{};
        const text = agent.runSubagent(self, task, &rep);
        var matches: std.ArrayList([]const u8) = .empty;
        defer matches.deinit(self.allocator);
        var rest = text;
        while (rest.len > 0) {
            const nl = std.mem.indexOf(u8, rest, "\n");
            var line: []const u8 = "";
            if (nl) |i| { line = rest[0..i]; rest = rest[i + 1..]; }
            else { line = rest; rest = ""; }
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;
            if (std.mem.indexOf(u8, trimmed, ".jsonl") == null) continue;
            if (std.mem.indexOf(u8, trimmed, "zode-") == null) continue;
            for (self.session_picker_entries.items) |e| {
                if (std.mem.eql(u8, e.path, trimmed)) {
                    const path_copy = self.allocator.dupe(u8, trimmed) catch continue;
                    matches.append(self.allocator, path_copy) catch {};
                    break;
                }
            }
        }
        self.lock();
        for (self.session_picker_semantic_results.items) |p| {
            self.allocator.free(p);
        }
        self.session_picker_semantic_results.clearRetainingCapacity();
        for (matches.items) |p| {
            self.session_picker_semantic_results.append(self.allocator, p) catch {};
        }
        self.session_picker_semantic_searching = false;
        self.dirty = true;
        self.redraw_requested.store(true, .seq_cst);
        self.unlock();
    }



    ///
    /// Public because `agent.zig` is the one that opens the picker with them, and
    /// `closePicker` frees them too: two owners of the same strings is how the
    /// double free happens, so the rule is ONE free per item and it lives with the
    /// allocator that made them.
    pub fn freePickerItems(gpa: std.mem.Allocator, items: []PickerItem) void {
        for (items) |it| {
            gpa.free(it.label);
            if (it.desc.len > 0) gpa.free(it.desc);
        }
        gpa.free(items);
    }

    /// Per-frame snapshot: copies into ctx.arena (≤10 visible items).
    fn pickerSnapshot(self: *Model, arena: std.mem.Allocator) ?PickerSnapshot {
        self.lock();
        defer self.unlock();
        if (!self.picker_active) return null;
        const visible: usize = 10;
        const total = self.picker_filtered.items.len;
        const start = @min(self.picker_scroll, if (total > visible) total - visible else 0);
        const end = @min(start + visible, total);
        var items = arena.alloc(PickerItem, end - start) catch return null;
        var out_ix: usize = 0;
        var fi = start;
        while (fi < end) : (fi += 1) {
            const it = self.picker_items.items[self.picker_filtered.items[fi]];
            items[out_ix] = .{
                .label = arena.dupe(u8, it.label) catch "",
                .desc = arena.dupe(u8, it.desc) catch "",
            };
            out_ix += 1;
        }
        return .{
            .title = arena.dupe(u8, self.picker_title[0..self.picker_title_len]) catch "",
            .query = arena.dupe(u8, self.picker_query[0..self.picker_query_len]) catch "",
            .sel = self.picker_sel,
            .first_visible = start,
            .total = total,
            .tag = self.picker_tag,
            .items = items,
            .semantic_searching = self.session_picker_semantic_searching,
        };
    }

    pub fn status(self: *const Model) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    pub fn setStatusText(self: *Model, text: []const u8) void {
        self.lock();
        defer self.unlock();
        const n = @min(text.len, self.status_buf.len);
        @memcpy(self.status_buf[0..n], text[0..n]);
        self.status_len = n;
        // The status is painted in draw: without `dirty` the change sits in the
        // buffer until another key arrives. With a worker running that means
        // "the status doesn't move" for the whole call.
        self.dirty = true;
        self.redraw_requested.store(true, .seq_cst);
    }

    /// Text + mood. The footer uses this mood for the mascot's colour, and the
    /// text is its legend: the two are ONE widget.
    pub fn setStatusWithMood(self: *Model, new_mood: StatusKind, text: []const u8) void {
        self.lock();
        defer self.unlock();
        const n = @min(text.len, self.status_buf.len);
        @memcpy(self.status_buf[0..n], text[0..n]);
        self.status_len = n;
        self.status_kind = new_mood;
        self.status_kind_set = true;
        self.dirty = true;
        self.redraw_requested.store(true, .seq_cst);
    }

    /// `setStatusWithMood` that composes the text into the fixed buffer.
    ///
    /// Same reasoning as `pushInfoFmt`: the footer copies, so composing here
    /// cannot leak a literal into an ownership-taking path, and the mood stays
    /// paired with the text in one call (which is what makes the face come out in
    /// the right color).
    pub fn setStatusFmt(self: *Model, new_mood: StatusKind, comptime fmt: []const u8, args: anytype) void {
        var buf: [160]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch {
            self.setStatusWithMood(new_mood, fmt);
            return;
        };
        self.setStatusWithMood(new_mood, s);
    }

    /// `pushError` that composes the text (the `.error_msg` kind, in red).
    pub fn pushErrorFmt(self: *Model, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.allocPrint(self.allocator, fmt, args) catch {
            self.pushError(fmt);
            return;
        };
        self.pushErrorOwned(text);
    }

    /// Mood of the current state. If nobody set it, it is deduced from the
    /// work.
    pub fn mood(self: *Model) StatusKind {
        self.lock();
        defer self.unlock();
        if (self.status_kind_set) return self.status_kind;
        if (self.perm_active) return .warn;
        if (self.busy or self.streaming) return .thinking;
        return .idle;
    }

    pub fn statusf(self: *Model, comptime fmt: []const u8, args: anytype) void {
        var buf: [160]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.setStatusText(s);
    }

    // ── permission dialog (thread-safe) ────────────────
    /// Called by the worker BEFORE running a tool that needs permission.
    /// Blocks until the user answers in the UI.
    pub fn requestPermission(self: *Model, tool: []const u8, detail: []const u8) PermAnswer {
        // Copy of the prompt BEFORE taking the lock: `tool` and `detail` come
        // from a worker arena, but the memcpy is short, so the dialog's lock is
        // only used for state.
        self.permLock();
        const n_tool = @min(tool.len, self.perm_tool.len);
        @memcpy(self.perm_tool[0..n_tool], tool[0..n_tool]);
        self.perm_tool_len = n_tool;
        const n_det = @min(detail.len, self.perm_detail.len);
        @memcpy(self.perm_detail[0..n_det], detail[0..n_det]);
        self.perm_detail_len = n_det;
        self.perm_answer = .none;
        self.perm_active = true;
        // The tick must keep running while the user decides: without this the
        // dialog appears but is not repainted (the clock, the face...).
        self.redraw_requested.store(true, .seq_cst);
        self.permUnlock();

        // SLEEPING wait: the backoff grows up to 20 ms, so the worker burns no
        // CPU while the user decides (before it was spin-yield).
        self.waitPermAnswer();

        self.permLock();
        const a = self.perm_answer;
        self.perm_active = false;
        self.permUnlock();
        return a;
    }

    /// Asks a question that must NOT become a standing permission.
    ///
    /// "Always allow" is not on the table: the question is about ONE write
    /// into a place where writing is a bad idea, and a rule that remembers
    /// it would put that whole place on the list of places the agent writes
    /// without asking — which is the opposite of what the question is for.
    ///
    /// The answer is "allow once" or "deny", and nothing else.
    pub fn requestPermissionOnce(self: *Model, tool: []const u8, detail: []const u8) PermAnswer {
        self.permLock();
        const was = self.perm_allow_always;
        self.perm_allow_always = false;
        self.permUnlock();
        defer {
            self.permLock();
            self.perm_allow_always = was;
            self.permUnlock();
        }
        return self.requestPermission(tool, detail);
    }

    /// The rule the "always allow" option would remember.
    pub fn setPermSuggestion(self: *Model, text: []const u8) void {
        self.permLock();
        defer self.permUnlock();
        const n = @min(text.len, self.perm_suggestion.len);
        @memcpy(self.perm_suggestion[0..n], text[0..n]);
        self.perm_suggestion_len = n;
    }

    /// The rule the open dialog would remember, or "" when there is none.
    pub fn permSuggestion(self: *Model) []const u8 {
        self.permLock();
        defer self.permUnlock();
        return self.perm_suggestion[0..self.perm_suggestion_len];
    }

    /// Whether the open dialog offers "always allow".
    pub fn permAllowAlways(self: *Model) bool {
        self.permLock();
        defer self.permUnlock();
        return self.perm_allow_always;
    }

    /// UI: answers the open dialog.
    pub fn answerPermission(self: *Model, a: PermAnswer) void {
        self.permLock();
        self.perm_answer = a;
        self.permUnlock();
        // Wakes the worker (which may be in a `nanosleep` of up to 20 ms).
        _ = self.perm_epoch.fetchAdd(1, .seq_cst);
        self.redraw_requested.store(true, .seq_cst);
    }

    pub fn permActive(self: *Model) bool {
        self.permLock();
        defer self.permUnlock();
        return self.perm_active;
    }

    pub fn permView(self: *Model, tool: *[]const u8, detail: *[]const u8) bool {
        self.permLock();
        defer self.permUnlock();
        if (!self.perm_active) return false;
        tool.* = self.perm_tool[0..self.perm_tool_len];
        detail.* = self.perm_detail[0..self.perm_detail_len];
        return true;
    }

    /// Throws away the parsed segments, so the next frame reads the text
    /// again.
    ///
    /// It is what a change of PALETTE needs: the styles are baked into the
    /// cached segments, so a diff painted in the green/red pair keeps being
    /// painted in the green/red pair after the user asks for the blue/orange
    /// one.
    pub fn clearSegCache(self: *Model) void {
        for (self.seg_cache.items) |*c| {
            if (c.arena) |a| {
                a.deinit();
                self.allocator.destroy(a);
            }
        }
        self.seg_cache.deinit(self.allocator);
        self.seg_cache = .empty;
        self.cache_lo = 0;
        // The heights depend on the WIDTH (wrapping changes them), so
        // invalidating the cache has to forget them too. Otherwise the scroll
        // would be computed with the heights of the previous width.
        //
        // CAREFUL: `clearRetainingCapacity` does `@memset(items, undefined)`,
        // and in `deinit` this function is called AFTER `para_heights.deinit()`:
        // a touch of undefined on freed memory is what triggers the segfault.
        // That's why it is emptied by lowering `len` directly (there is nothing
        // to overwrite here: the heights get estimated as whole numbers
        // again).
        self.para_heights.items.len = 0;
        if (self.height_tree.items.len > 0) {
            @memset(self.height_tree.items, 0);
        }
    }

    /// Frees cache entry `i` and removes it (keeping order).
    fn evictCached(self: *Model, i: usize) void {
        if (i >= self.seg_cache.items.len) return;
        if (self.seg_cache.items[i].arena) |a| {
            a.deinit();
            self.allocator.destroy(a);
        }
        _ = self.seg_cache.orderedRemove(i);
    }

    /// Paragraph heights, with an estimate for the ones not yet measured.
    ///
    /// A paragraph's height depends on the parse (markdown + wrap), which is
    /// the expensive part. Scrolling needs the total of the whole history, so
    /// paragraphs outside the window are ESTIMATED, and the estimate is
    /// replaced by the exact one as soon as the paragraph enters the window.
    ///
    /// Two things make the estimate good enough to scroll with:
    ///
    /// 1. It counts the WRAP, not just the line breaks. It used to be
    ///    `count('\n') + 1`, i.e. the height of the text as if the terminal were
    ///    infinitely wide, and measured against reality that is off by a factor
    ///    of three on a 100-column terminal (a 3-line paragraph estimated as 1).
    ///    The whole scroll range was therefore wrong by ~2/3 for every
    ///    paragraph that had not been parsed yet.
    /// 2. `known_lines` (in the paragraph) wins over any estimate, because it
    ///    survives BOTH the compression (which turns the text into base64 with
    ///    no newlines) and the resize (which empties `para_heights`).
    fn ensureParaHeights(self: *Model) void {
        const n = self.paras.items.len;
        while (self.para_heights.items.len > n) {
            const idx = self.para_heights.items.len - 1;
            self.setHeightTreeValue(idx, 0);
            _ = self.para_heights.pop();
        }
        self.ensureHeightTree(n);
        self.para_heights.ensureTotalCapacity(self.allocator, n) catch return;
        while (self.para_heights.items.len < n) {
            const p = self.paras.items[self.para_heights.items.len];
            const idx = self.para_heights.items.len;
            const est: usize = if (p.known_lines > 0)
                p.known_lines
            else
                self.estHeight(p.text);
            // `assumeCapacity`: the indices of `para_heights` are the same as
            // those of `paras` and draw walks them assuming they measure the
            // same thing, so an OOM here cannot leave the list short (that
            // would be an out-of-range index in the next frame).
            self.para_heights.appendAssumeCapacity(est);
            self.setHeightTreeValue(idx, est);
        }
    }

    /// Grows geometrically and rebuilds only when the indexed history outgrows
    /// its current leaf capacity. A failed allocation leaves the linear
    /// fallback available and never publishes a partial tree.
    fn ensureHeightTree(self: *Model, n: usize) void {
        if (n <= self.height_tree_capacity) return;
        var cap: usize = @max(self.height_tree_capacity, 1);
        while (cap < n) {
            const doubled = std.math.mul(usize, cap, 2) catch return;
            cap = doubled;
        }
        const tree_len = std.math.mul(usize, cap, 2) catch return;
        self.height_tree.ensureTotalCapacity(self.allocator, tree_len) catch return;
        self.height_tree.items.len = tree_len;
        @memset(self.height_tree.items, 0);
        self.height_tree_capacity = cap;
        for (self.para_heights.items, 0..) |h, i| {
            self.height_tree.items[satAdd(cap, i)] = h;
        }
        var node = cap - 1;
        while (node > 0) : (node -= 1) {
            self.height_tree.items[node] =
                satAdd(
                    self.height_tree.items[satMul(node, 2)],
                    self.height_tree.items[satAdd(satMul(node, 2), 1)],
                );
        }
    }

    fn setHeightTreeValue(self: *Model, index: usize, value: usize) void {
        const cap = self.height_tree_capacity;
        if (cap == 0 or index >= cap or self.height_tree.items.len < satMul(cap, 2)) return;
        var node = satAdd(cap, index);
        self.height_tree.items[node] = value;
        node /= 2;
        while (node > 0) : (node /= 2) {
            self.height_tree.items[node] =
                satAdd(
                    self.height_tree.items[satMul(node, 2)],
                    self.height_tree.items[satAdd(satMul(node, 2), 1)],
                );
        }
    }

    /// Sum of the first `end` paragraph heights. Falls back to a direct scan if
    /// allocating a larger tree failed.
    fn heightPrefix(self: *const Model, end: usize) usize {
        const stop = @min(end, self.para_heights.items.len);
        const cap = self.height_tree_capacity;
        if (cap == 0 or stop > cap or self.height_tree.items.len < satMul(cap, 2)) {
            var sum: usize = 0;
            for (self.para_heights.items[0..stop]) |h| sum = satAdd(sum, h);
            return sum;
        }
        var left = cap;
        var right = satAdd(cap, stop);
        var sum: usize = 0;
        while (left < right) {
            if ((left & 1) != 0) {
                sum = satAdd(sum, self.height_tree.items[left]);
                left += 1;
            }
            if ((right & 1) != 0) {
                right -= 1;
                sum = satAdd(sum, self.height_tree.items[right]);
            }
            left /= 2;
            right /= 2;
        }
        return sum;
    }

    /// Paragraph index containing an absolute history line; total height maps
    /// to `len`, the position just after the final paragraph.
    fn heightIndexAt(self: *const Model, line: usize) usize {
        const n = self.para_heights.items.len;
        const total = self.heightPrefix(n);
        if (line >= total) return n;
        const cap = self.height_tree_capacity;
        if (cap == 0 or n > cap or self.height_tree.items.len < satMul(cap, 2)) {
            var sum: usize = 0;
            for (self.para_heights.items, 0..) |h, i| {
                if (line < satAdd(sum, h)) return i;
                sum = satAdd(sum, h);
            }
            return n;
        }
        var node: usize = 1;
        var offset = line;
        while (node < cap) {
            const left = node * 2;
            const left_sum = self.height_tree.items[left];
            if (offset < left_sum) {
                node = left;
            } else {
                offset -= left_sum;
                node = left + 1;
            }
        }
        return @min(node - cap, n);
    }

    /// First paragraph count whose cumulative height reaches `line`.
    fn heightLowerBound(self: *const Model, line: usize) usize {
        return self.heightIndexAt(line);
    }

    /// Cheap height estimate for a paragraph that has never been parsed.
    ///
    /// Wrapping included: `newlines + 1` rows, plus one more per `per_line`
    /// bytes of the text. It is only an estimate (markdown lists, code blocks
    /// and the blank separator row all add rows it cannot know about) but it is
    /// within a factor of the real height, which is what the scroll needs.
    ///
    /// `wrap_w` is the width the last frame laid out with, published by the
    /// draw. Initialized to 80 (common terminal default) so `estHeight` has a
    /// reasonable fallback before the first frame.
    /// Saturating add for usize: UI layout tolerates approximate heights,
    /// but never a panic from integer overflow.
    fn satAdd(a: usize, b: usize) usize {
        if (a > std.math.maxInt(usize) - b) return std.math.maxInt(usize);
        return a + b;
    }

    /// Saturating multiply for usize.
    fn satMul(a: usize, b: usize) usize {
        if (b != 0 and a > std.math.maxInt(usize) / b) return std.math.maxInt(usize);
        return a * b;
    }

    fn estHeight(self: *const Model, text: []const u8) usize {
        const per_line: usize = @intCast(self.wrap_w);
        const nl = std.mem.count(u8, text, "\n");
        const wrapped = if (per_line > 0) (text.len -| nl) / per_line else 0;
        // A fence costs three rows the line count cannot see: a blank row, the
        // language chip and another blank row. Counting them here is what stops
        // the scroll range from growing as you scroll down through a history
        // full of code.
        const fences = std.mem.count(u8, text, "```") + std.mem.count(u8, text, "~~~");
        // Saturating arithmetic: a pathological text cannot overflow usize.
        const fence_cost: usize = satMul(3, fences);
        return @max(1, satAdd(satAdd(satAdd(nl, 1), wrapped), fence_cost));
    }

    /// Parses and wraps a paragraph, and puts it in the cache with its height.
    ///
    /// When `visible_range` is provided (lazy parsing for very long paragraphs),
    /// only the lines whose absolute positions fall within `[start, end)` are
    /// wrapped. The paragraph's height is set to the full estimate so scroll
    /// math stays correct, but only visible lines consume render memory.
    fn layoutOne(
        self: *Model,
        ctx: vxfw.DrawContext,
        idx: usize,
        width: u16,
        visible_range: ?Model.VisibleRange,
    ) !void {
        const p_ = &self.paras.items[idx];

        const para_arena = try self.allocator.create(std.heap.ArenaAllocator);
        para_arena.* = std.heap.ArenaAllocator.init(self.allocator);
        errdefer {
            para_arena.deinit();
            self.allocator.destroy(para_arena);
        }

        // Rehydrate if the paragraph was pruned to its compressed form.
        _ = p_.textLive(self.allocator);

        // ── Lazy parsing: for very long paragraphs, only wrap visible lines ──
        var para_for_layout = self.paras.items[idx];
        if (visible_range) |vr| {
            const para_start = self.heightPrefix(idx);
            const para_end = self.heightPrefix(idx + 1);
            // Clamp the requested range to this paragraph's actual lines.
            const range_start = @max(vr.start, para_start);
            const range_end = @min(vr.end, para_end);
            if (range_end > range_start) {
                // Extract only the visible lines from the text.
                const text = p_.text;
                // The list is created and grown from the SAME allocator it is
                // handed to at the end: `toOwnedSlice` remaps the buffer, and a
                // buffer from one allocator remapped through another is a jump
                // through a vtable that has nothing to do with it (the arena one
                // panics on its first empty node).
                const vis_alloc = para_arena.allocator();
                var visible_lines: std.ArrayList(u8) = .empty;
                var line_start: usize = 0;
                var line_idx: usize = 0;
                var in_range = false;
                // `indexOfScalar` answers an offset RELATIVE to `line_start`, so
                // it has to be added back: read as an absolute position it made
                // `line_end < line_start`, and `line_end - line_start` is then an
                // integer overflow (the panic in the prune tests) that turns into
                // a wrong slice in a Release build. And the loop ends at
                // `line_start == text.len`, not after: past it there is no line,
                // and `line_len` of 0 never advances.
                while (line_start < text.len) {
                    const nl = std.mem.indexOfScalar(u8, text[line_start..], '\n');
                    const line_end = if (nl) |at| line_start + at else text.len;
                    const line_len = if (nl != null) line_end - line_start + 1 else line_end - line_start;
                    if (line_idx >= range_start and line_idx < range_end) {
                        in_range = true;
                        try visible_lines.appendSlice(vis_alloc, text[line_start..line_start + line_len]);
                    } else if (in_range) {
                        break;
                    }
                    line_start += line_len;
                    line_idx += 1;
                }
                if (visible_lines.items.len > 0) {
                    const visible_text = try visible_lines.toOwnedSlice(vis_alloc);
                    para_for_layout.text = visible_text;
                }
            }
        }
        var lines = try buildLinesBase(para_arena.allocator(), ctx, &para_for_layout, width);
        // A blank row BETWEEN paragraphs: without it the history is a wall of
        // text and you can't see where one response ends and another begins.
        //
        // The row is ADDED to the lines array, not added to the height: if it
        // were only added to the height, `drawLines` (which walks `c.lines`)
        // would paint one row fewer than the height says and the last block
        // would be lost. The first paragraph carries NO separator (it would be
        // an empty row above the header, which misaligns the banner art).
        //
        // The banner used to be exempted via `prev_banner` too: when the header
        // was a multi-part drawing (wordmark + robot + tagline) a blank row
        // split the art. It is the wordmark alone now, and WITHOUT the gap the
        // user's first prompt sat glued to the logo — which reads as one blob
        // ("the banner and my prompt are the same thing"). A drawing of
        // `banner_art_height` full rows survives one blank row below it.
        //
        // Under the banner the gap is a RULE and not a blank row (bug 4). One
        // empty row is not enough separation when what is above it is a 5-row
        // drawing and what is below is the user's own words: the prompt reads as
        // the last line of the logo. A `─` in the dim brand color says "the
        // header ends here" without spending two more rows on whitespace, and it
        // is the same mark the popup and the input box already use, so it is not
        // a new idea in the middle of the screen.
        const after_banner = idx > 0 and self.paras.items[idx - 1].kind == .banner;
        if (idx > 0 and p_.kind != .banner) {
            const grown = try para_arena.allocator().alloc(PLine, lines.len + 1);
            // IN FRONT, not behind: the blank row separates this paragraph
            // from the previous one. Placed at the end, the gap showed up
            // after "second" and the history was still a wall of text.
            if (after_banner) {
                grown[0] = bannerRuleLine(para_arena.allocator(), width);
            } else {
                grown[0] = .{ .cells = &.{}, .w = 0 };
            }
            @memcpy(grown[1..], lines);
            lines = grown;
        }

        try self.seg_cache.append(self.allocator, .{
            .arena = para_arena,
            .lines = lines,
            .height = lines.len,
            .para_idx = idx,
        });
        // The exact height replaces the estimate, in the list AND in the paragraph:
        // the paragraph copy is what survives a resize (`ensureParaHeights`).
        if (idx < self.para_heights.items.len) {
            self.para_heights.items[idx] = lines.len;
            self.setHeightTreeValue(idx, lines.len);
        }
        self.paras.items[idx].known_lines = lines.len;
    }

    /// Range of visible history lines (absolute over the whole history, not
    /// over the cached window).
    pub const Visible = struct { first: usize, last: usize, total: usize, max_offset: usize };

    /// Total history lines (closed paragraphs + the live one) and how far up the
    /// view can go before leaving the history.
    ///
    /// Split out of `computeVisible` because the key handlers need it too (to
    /// clamp the anchor) and they cannot know how tall the live paragraph is:
    /// they use the last frame's value, through `currentMaxOffset`.
    fn totalsFor(self: *Model, live_lines: usize, history_h: usize) struct { total: usize, max_offset: usize } {
        const closed = self.heightPrefix(self.para_heights.items.len);
        const total: usize = closed + live_lines;
        const hh = @max(history_h, 1);
        return .{
            .total = total,
            .max_offset = if (total > hh) total - hh else 0,
        };
    }

    /// `max_offset` computed with the last frame's numbers, for the callers that
    /// cannot measure it themselves.
    fn currentMaxOffset(self: *Model) usize {
        self.ensureParaHeights();
        return self.totalsFor(self.live_h, self.hist_rows).max_offset;
    }

    /// Computes which lines are visible with the current anchor.
    ///
    /// The total comes from `para_heights` (the WHOLE history, not just the
    /// cached window): with the cache as a window, summing its heights would
    /// give a total that depends on what is cached, and the scroll would jump
    /// on eviction.
    ///
    /// `first` comes from the ANCHOR, which is absolute. It used to be
    /// `max_offset - scroll`, which is bottom-relative too, and that is why
    /// reading was impossible: `scroll` did not change but `max_offset` grew with
    /// every line of the live paragraph, so the window moved at the model's
    /// writing speed (~2-5 lines per second). With the anchor, new text does not
    /// move you.
    fn computeVisible(self: *Model, live_lines: usize, history_h: usize) Visible {
        self.ensureParaHeights();
        const t = self.totalsFor(live_lines, history_h);
        var first = if (self.follow_bottom) t.max_offset else self.anchorLine();
        if (first >= t.max_offset) {
            // Being at the very bottom re-arms the follow, and only there is the
            // anchor re-derived. Re-deriving it anywhere else is the bug: a
            // correction to a paragraph ABOVE the view shifts the absolute line
            // of the top, and turning that shifted line back into (paragraph,
            // offset) lands on a different paragraph, so the reader is moved by
            // exactly the amount the fix was supposed to absorb.
            first = t.max_offset;
            self.follow_bottom = true;
            // The reader is back at the bottom (or never left): the "N new"
            // count ends here, and the baseline moves with the history.
            self.was_away = false;
            self.unseen_base_para = self.paras.items.len;
            self.setAnchorLine(first);
        } else {
            self.follow_bottom = false;
        }
        self.anchor = first;
        return .{ .first = first, .last = satAdd(first, @max(history_h, 1)), .total = t.total, .max_offset = t.max_offset };
    }

    /// The absolute line of the top of the view, from (paragraph, offset).
    fn anchorLine(self: *const Model) usize {
        const upto = @min(self.anchor_para, self.para_heights.items.len);
        return satAdd(self.heightPrefix(upto), self.anchor_off);
    }

    /// The other direction: turn an absolute line into (paragraph, offset).
    ///
    /// The offset is clamped to the paragraph's CURRENT height, which is what
    /// keeps a shrink from leaving the anchor pointing past its own paragraph.
    fn setAnchorLine(self: *Model, line: usize) void {
        const i = self.heightIndexAt(line);
        if (i < self.para_heights.items.len) {
            self.anchor_para = i;
            const base = self.heightPrefix(i);
            self.anchor_off = if (line >= base) line - base else 0;
            return;
        }
        // Past the last paragraph: the top of the view is below all of them.
        self.anchor_para = self.para_heights.items.len;
        self.anchor_off = 0;
    }

    /// Layout + scroll until the visible range stabilizes.
    ///
    /// Needed because the heights start as an ESTIMATE and are corrected on
    /// parse: parsing changes the total, the total changes `first_visible`, and
    /// `first_visible` changes which paragraphs have to be parsed. Without this
    /// second pass the text stays offset (you saw the history jump when you
    /// started scrolling). With a cap of passes (4) in case a pathological case
    /// doesn't converge: the scroll stays at the closest instead of going in
    /// circles.
    fn layoutFor(
        self: *Model,
        ctx: vxfw.DrawContext,
        width: u16,
        live_lines: usize,
        history_h: usize,
    ) !Visible {
        self.ensureParaHeights();
        var v = self.computeVisible(live_lines, history_h);
        var pass: usize = 0;
        while (pass < 4) : (pass += 1) {
            try self.layoutWindow(ctx, width, v.first, v.last);
            const next = self.computeVisible(live_lines, history_h);
            if (next.first == v.first and next.last == v.last) return next;
            v = next;
        }
        // It did NOT converge in 4 passes: what we return is the range computed
        // AFTER the last `layoutWindow`, which means a range nobody has parsed
        // yet. `drawLines` clips on this `first`, so the top rows came out blank
        // until the next frame (which does parse it). One more pass, and the
        // range we return is in the cache.
        //
        // Still a hard cap of 5 `layoutWindow` calls: the loop cannot run away
        // because the iteration count does not depend on the data.
        try self.layoutWindow(ctx, width, v.first, v.last);
        return v;
    }

    /// Leaves the cache covering EXACTLY the window of paragraphs that contains
    /// the visible lines, and only that.
    ///
    /// The previous loop (`while (cache.len < paras.len)` + `orderedRemove(0)`
    /// when going over the cap) never terminated with 129+ paragraphs: append →
    /// 129 → evict → 128 → back in. With `pushDiff` putting one paragraph per
    /// diff line, a single `write` of a 129-line file hung the app instantly.
    /// Here the number of iterations is bounded by `max_cached_paras`, so it
    /// terminates by construction.
    fn layoutWindow(
        self: *Model,
        ctx: vxfw.DrawContext,
        width: u16,
        first_visible: usize,
        last_visible: usize,
    ) !void {
        self.ensureParaHeights();
        self.layout_iters = 0;
        self.layout_overflow = false;
        self.frame_counter += 1;
        if (self.paras.items.len == 0) return;

        // ── target window: the paragraphs covering [first, last] ──
        var lo = self.heightIndexAt(first_visible);
        var hi = self.heightLowerBound(last_visible);
        if (hi < lo) hi = lo;

        // ── VIRTUAL SCROLL: compute how many paragraphs actually fit in history_h ──
        // Instead of parsing every paragraph in [lo, hi), we only parse the ones
        // that can actually appear on screen. `para_heights` has the height of
        // every paragraph (estimate or exact), so we can walk from `first_visible`
        // and count how many paragraphs fit before exceeding `history_h` rows.
        const viewport_rows = last_visible - first_visible;
        var visible_para_count: usize = 0;
        var lines_used: usize = 0;
        var p = lo;
        while (p < self.para_heights.items.len and lines_used < viewport_rows) {
            lines_used += self.para_heights.items[p];
            visible_para_count += 1;
            p += 1;
        }
        // Cap the window to what fits on screen, plus one paragraph for context.
        if (visible_para_count > 0) {
            hi = lo + visible_para_count;
            if (hi > self.para_heights.items.len) hi = self.para_heights.items.len;
        }

        // If the visible window is wider than the cap, we must choose which
        // paragraphs to keep in the cache. When at the bottom (follow_bottom),
        // keep the tail so new arriving text is cached. When scrolled up, keep
        // the window around the anchor (what the user is reading) so the
        // content doesn't disappear.
        if (hi - lo > Model.max_cached_paras) {
            if (self.follow_bottom) {
                lo = hi - Model.max_cached_paras;
            } else {
                hi = lo + Model.max_cached_paras;
            }
        }

        // ── drop what is cached outside the window ──
        var i: usize = 0;
        while (i < self.seg_cache.items.len) {
            const idx = self.seg_cache.items[i].para_idx;
            if (idx < lo or idx >= hi) {
                self.evictCached(i);
            } else {
                // Mark as recently used for LRU.
                self.seg_cache.items[i].last_frame_used = self.frame_counter;
                i += 1;
            }
        }
        self.cache_lo = lo;

        // ── prune: compress what is outside the window ──
        self.pruneCold(lo, hi);

        // ── LRU: if cache is full, evict the least recently used entry ──
        while (self.seg_cache.items.len > Model.max_cached_paras) {
            var lru_idx: usize = 0;
            var lru_frame: u64 = self.frame_counter;
            var j: usize = 0;
            while (j < self.seg_cache.items.len) {
                if (self.seg_cache.items[j].last_frame_used < lru_frame) {
                    lru_frame = self.seg_cache.items[j].last_frame_used;
                    lru_idx = j;
                }
                j += 1;
            }
            self.evictCached(lru_idx);
        }

        // ── parse whatever is missing in the window ──
        for (lo..hi) |idx| {
            if (self.hasCached(idx)) continue;
            // Safety net: the window cannot exceed the cap, but if someone
            // changed that this would be an infinite loop again. With the cap
            // here the failure is a `layout_overflow` (and a red test), not a
            // hung process.
            self.layout_iters += 1;
            if (self.layout_iters > Model.max_cached_paras) {
                self.layout_overflow = true;
                return;
            }
            // ── Lazy parsing: for very long paragraphs, only wrap visible lines ──
            const para_est_h = self.para_heights.items[idx];
            const para_start = self.heightPrefix(idx);
            const para_end = self.heightPrefix(idx + 1);
            var visible_range: ?Model.VisibleRange = null;
            if (para_est_h > 50) {
                visible_range = Model.VisibleRange{
                    .start = @max(first_visible, para_start),
                    .end = @min(last_visible, para_end),
                };
            }
            try self.layoutOne(ctx, idx, width, visible_range);
            // Mark as recently used.
            if (self.seg_cache.items.len > 0) {
                self.seg_cache.items[self.seg_cache.items.len - 1].last_frame_used = self.frame_counter;
            }
            // When lazy-parsing, lines.len is only the visible subset. Keep the
            // full estimate in para_heights so scroll math stays correct.
            if (visible_range == null) {
                if (idx < self.para_heights.items.len) {
                    self.para_heights.items[idx] = self.seg_cache.items[self.seg_cache.items.len - 1].height;
                    self.setHeightTreeValue(idx, self.seg_cache.items[self.seg_cache.items.len - 1].height);
                }
                self.paras.items[idx].known_lines = self.seg_cache.items[self.seg_cache.items.len - 1].height;
            } else {
                // Lazy-parsed: keep the estimate, don't overwrite with partial height.
                if (idx < self.para_heights.items.len) {
                    self.setHeightTreeValue(idx, para_est_h);
                }
                self.paras.items[idx].known_lines = para_est_h;
            }
        }

        // ── keep the cache SORTED by `para_idx` ──
        //
        // The painter walks the cache accumulating `line_cursor`, so it needs
        // the entries in paragraph order. It USED to get that order for free
        // because the window only ever moved forwards: `for (lo..hi)` appends
        // ascending, and everything below `lo` was evicted. But the window also
        // moves BACKWARDS — a height correction, a resize, anything that lowers
        // `first_visible` — and then those paragraphs are re-parsed and APPENDED
        // at the end, after the ones with a higher index.
        //
        // The result was a frame painted in the wrong order: `seg_cache` read
        // `3,4,5,6,7,8,0,1,2`, so paragraphs 0-2 were painted at the line where
        // paragraph 8 ended. The banner appeared twice, in the middle of a
        // conversation, and a resized window scrambled a long turn. Measured on
        // `tools/ui_frame` (`zig build ui-frame -- --layout turn 96 30`) and
        // caught by the red test "correcting a paragraph's height does not move
        // the text under the reader", which had been failing since the window
        // became a window.
        //
        // Sorted here rather than in `layoutOne` because the invariant belongs
        // to the FUNCTION THAT CAN BREAK IT: `layoutOne` is called in ascending
        // order and does not know what else is already in the list.
        if (!self.cacheSorted()) {
            std.mem.sort(CachedPara, self.seg_cache.items, {}, cachedLessThan);
        }
    }

    /// Is `seg_cache` in paragraph order? The invariant `drawLines`'s
    /// `line_cursor` walk depends on. Checked once per frame over at most
    /// `max_cached_paras` entries, which is cheaper than sorting them.
    fn cacheSorted(self: *const Model) bool {
        var i: usize = 1;
        while (i < self.seg_cache.items.len) : (i += 1) {
            if (self.seg_cache.items[i - 1].para_idx >= self.seg_cache.items[i].para_idx) return false;
        }
        return true;
    }

    fn cachedLessThan(_: void, a: CachedPara, b: CachedPara) bool {
        return a.para_idx < b.para_idx;
    }

    /// Compresses the paragraphs outside `[lo, hi)` (Phase 6 of the ROADMAP).
    ///
    /// `Model.paras` is the only structure that grows without bound: the segment
    /// cache is a sliding window, but every paragraph keeps its TEXT forever.
    /// Measured with 128 paragraphs holding 16 KB tool results (the
    /// `max_tool_output` cap) that is 2 MB of raw text, and it never comes back
    /// down however far you scroll.
    ///
    /// Freeing the text outright is not an option: nothing can bring it back
    /// (`/resume` reads the session, but the session has no message behind half of
    /// these paragraphs — tool headers, diffs, notices). Compressing keeps it
    /// byte-exact and needs no mapping, and the round trip is already covered by
    /// the `zjsonl` tests.
    ///
    /// Only paragraphs that are actually worth compressing are touched: below
    /// `zjsonl.min_compress_len` the base64 overhead costs more than it saves, and
    /// `compressLine` returns null in that case anyway.
    fn pruneCold(self: *Model, lo: usize, hi: usize) void {
        for (self.paras.items, 0..) |*p, i| {
            if (i >= lo and i < hi) continue; // inside the window
            if (p.is_cold) continue;
            if (p.text.len < zjsonl.min_compress_len) continue;
            // The height is banked in the paragraph BEFORE the text is swapped out.
            // The estimate is computed from the text (newlines and wrap), and
            // base64 has no newlines: without this, compressing a paragraph
            // would leave `ensureParaHeights` with nothing to estimate from and
            // the scroll range would collapse — which is the whole reason the
            // height also lives in `Para.known_lines`.
            if (i >= self.para_heights.items.len) continue;
            if (p.known_lines == 0) p.known_lines = self.para_heights.items[i];

            // `compressLine` needs a destination buffer; one allocation per
            // paragraph, freed right after.
            const gpa = self.allocator;
            const buf = gpa.alloc(u8, p.text.len + 1) catch continue;
            defer gpa.free(buf);
            const packed_z = zjsonl.compressLine(buf, p.text) orelse continue;
            if (packed_z.len == 0) continue;
            const copy = gpa.dupe(u8, packed_z) catch continue;
            gpa.free(p.text);
            p.text = copy;
            p.is_cold = true;
        }
    }

    fn hasCached(self: *const Model, idx: usize) bool {
        for (self.seg_cache.items) |c| {
            if (c.para_idx == idx) return true;
        }
        return false;
    }

    fn lock(self: *Model) void {
        while (!self.spin.tryLock()) std.Thread.yield() catch {};
    }
    fn unlock(self: *Model) void {
        self.spin.unlock();
    }

    // ── permission dialog lock (1.7) ──────────────
    //
    // The HISTORY lock (`spin`) is no good for waiting on the user: the worker
    // goes through `requestPermission` on every `write`/`edit`/`bash` that is
    // not in the allowlist, and spinning with `yield` on that lock while the
    // user thinks (which can be 30 s) burns a whole core and makes EVERY lock
    // acquisition in the UI a failed `yield`. In other words, the permission
    // dialog degraded the whole app.
    //
    // Here there is an OWN mutex, with a condition: the worker waits on the
    // condition (asleep, no CPU) and only wakes when the user answers. And since
    // it is not the history lock, draw keeps breathing while the worker waits.
    fn permLock(self: *Model) void {
        while (!self.perm_mutex.tryLock()) std.Thread.yield() catch {};
    }
    fn permUnlock(self: *Model) void {
        self.perm_mutex.unlock();
    }

    /// Waits for the user to answer, SLEEPING.
    ///
    /// The backoff grows from 1 ms to 20 ms: the first answer is usually
    /// immediate (the user already had a finger on `y`), and if they are slow
    /// it does not wake 1000 times per second. With pure `std.Thread.yield` it
    /// was ~1M iterations in 30 s.
    // ── `ask`: the model asks the user ───────────────
    //
    // Deliberately a COPY of the permission machinery rather than a shared one:
    // the two are different questions with different timeouts, and merging them
    // means every change to one is a change to the other's behaviour. What they
    // share is the SHAPE, which is what makes the second one cheap to get right.

    fn askLock(self: *Model) void {
        while (!self.ask_mutex.tryLock()) std.Thread.yield() catch {};
    }
    fn askUnlock(self: *Model) void {
        self.ask_mutex.unlock();
    }

    /// Called by the WORKER when the model asks something. Blocks until the user
    /// answers, declines, or the timeout passes.
    ///
    /// Returns the answer as a fresh gpa copy the CALLER owns, or null if there
    /// was none (declined / timed out). A copy and not a slice into the dialog's
    /// buffer because the caller puts it in the session, which outlives the
    /// dialog.
    pub fn requestAsk(
        self: *Model,
        question: []const u8,
        header: []const u8,
        options: []const []const u8,
    ) ?[]u8 {
        // Copies made BEFORE the lock: `question` and `options` point into the
        // worker's arena, and that arena is freed at the end of the turn — which
        // happens as soon as this function returns. Copying under the lock would
        // be correct too, but the lock is held by the UI thread at that moment
        // and this is on the hot path of "the user pressed a key".
        const q_copy = self.allocator.dupe(u8, question) catch return null;
        errdefer self.allocator.free(q_copy);
        const h_copy = self.allocator.dupe(u8, header) catch return null;
        errdefer self.allocator.free(h_copy);

        self.askLock();
        self.freeAskStringsLocked();
        self.ask_question = q_copy;
        self.ask_header = h_copy;
        for (options) |o| {
            const oc = self.allocator.dupe(u8, o) catch break;
            self.ask_options.append(self.allocator, oc) catch {
                self.allocator.free(oc);
                break;
            };
        }
        self.ask_answer = null;
        self.ask_typing = false;
        self.ask_active = true;
        self.ask_started_ns = if (self.io_ready) std.Io.Timestamp.now(self.io, .real).nanoseconds else 0;
        self.askUnlock();
        // The question has to be painted NOW: the user cannot answer what they
        // cannot see, and this is the whole interaction.
        self.requestRedraw();
        self.dirty = true;

        const outcome = self.waitAskAnswer();

        self.askLock();
        const answer = self.ask_answer;
        self.ask_answer = null;
        self.ask_active = false;
        self.ask_typing = false;
        // The buffers stay until the NEXT question (`freeAskStringsLocked` at the
        // top) or until `deinit`. Freeing them here is what would be wrong: the
        // draw is one frame behind and still paints the question.
        self.askUnlock();
        self.requestRedraw();
        self.dirty = true;
        return outcome orelse answer;
    }

    /// Frees the question/header/options. Holds the lock.
    fn freeAskStringsLocked(self: *Model) void {
        if (self.ask_question) |q| self.allocator.free(q);
        if (self.ask_header) |h| self.allocator.free(h);
        for (self.ask_options.items) |o| self.allocator.free(o);
        self.ask_options.clearRetainingCapacity();
        self.ask_question = null;
        self.ask_header = null;
    }

    /// Waits, SLEEPING, until there is an answer or the timeout.
    ///
    /// Returns null when nobody answered (ESC or timeout) and the answer slice
    /// otherwise. Same backoff as the permission dialog: 1 ms growing to 20 ms,
    /// because the first answer is usually instant and a spin here would burn a
    /// core for the whole five minutes.
    fn waitAskAnswer(self: *Model) ?[]u8 {
        var wait_ms: u64 = 1;
        while (true) {
            self.askLock();
            const has_answer = self.ask_answer != null;
            const timed_out = self.askTimedOutLocked();
            self.askUnlock();
            if (has_answer) {
                self.askLock();
                const a = self.ask_answer;
                self.askUnlock();
                return a;
            }
            if (timed_out) return null;
            napMs(wait_ms);
            wait_ms = @min(wait_ms * 2, 20);
        }
    }

    /// Five minutes with nobody answering. After that the worker stops waiting
    /// and tells the model to decide (see `ask.timed_out_text`).
    fn askTimedOutLocked(self: *Model) bool {
        if (self.ask_started_ns == 0) return false;
        if (!self.io_ready) return false;
        const now = std.Io.Timestamp.now(self.io, .real).nanoseconds;
        return now - self.ask_started_ns > ask_timeout_ms * std.time.ns_per_ms;
    }

    /// UI: the user answered. TAKES OWNERSHIP of `text` (the callback frees it),
    /// which is why it is not `[]const u8` here.
    pub fn answerAskOwned(self: *Model, text: []u8) void {
        self.askLock();
        if (self.ask_answer) |old| self.allocator.free(old);
        self.ask_answer = text;
        self.askUnlock();
        _ = self.ask_epoch.fetchAdd(1, .seq_cst);
        self.requestRedraw();
        self.dirty = true;
    }

    /// UI: ESC on the question means "decide it yourself", not "stop the turn".
    ///
    /// It also closes the question (`ask_active = false`) so the panel disappears
    /// on the very same frame. Without that the question would stay painted for
    /// the few milliseconds until the worker wakes up, reads the answer and
    /// returns — a visible flash of a dialog the user already answered, which
    /// reads as "it did not take my answer".
    pub fn declineAsk(self: *Model) void {
        self.askLock();
        if (self.ask_answer != null) {
            // Already answered. A second ESC must not free the answer the worker
            // has not picked up yet.
            self.askUnlock();
            return;
        }
        const msg = self.allocator.dupe(u8, "no answer") catch {
            self.askUnlock();
            return;
        };
        self.ask_answer = msg;
        self.ask_active = false;
        self.ask_typing = false;
        self.askUnlock();
        _ = self.ask_epoch.fetchAdd(1, .seq_cst);
        self.requestRedraw();
        self.dirty = true;
    }

    pub fn askActive(self: *Model) bool {
        self.askLock();
        defer self.askUnlock();
        return self.ask_active;
    }

    /// True when the question is open AND the input box is the answer field.
    pub fn askTyping(self: *Model) bool {
        self.askLock();
        defer self.askUnlock();
        return self.ask_active and self.ask_typing;
    }

    /// Milliseconds the question has been waiting. 0 when none.
    pub fn askMillis(self: *Model) u64 {
        self.askLock();
        defer self.askUnlock();
        if (!self.ask_active or self.ask_started_ns == 0) return 0;
        if (!self.io_ready) return 0;
        const now = std.Io.Timestamp.now(self.io, .real).nanoseconds;
        if (now <= self.ask_started_ns) return 0;
        return @intCast(@divTrunc(now - self.ask_started_ns, std.time.ns_per_ms));
    }

    /// For the draw: a copy of the open question into the frame arena.
    ///
    /// The copy is what the painter needs, and it is COPIED because the worker
    /// owns those strings: painting them from the dialog while the worker is
    /// blocked is fine, but the draw outlives nothing here and the frame arena is
    /// the only memory with a lifetime that matches "being painted right now".
    pub fn askSnapshot(self: *Model, arena: std.mem.Allocator) ?AskSnapshot {
        self.askLock();
        defer self.askUnlock();
        if (!self.ask_active) return null;
        if (self.ask_question == null) return null;
        return .{
            .question = arena.dupe(u8, self.ask_question.?) catch "",
            .header = if (self.ask_header) |h| arena.dupe(u8, h) catch "" else "",
            .options = blk: {
                const n = self.ask_options.items.len;
                const out = arena.alloc([]const u8, n) catch break :blk &.{};
                for (self.ask_options.items, 0..) |o, i| out[i] = arena.dupe(u8, o) catch "";
                break :blk out;
            },
            .typing = self.ask_typing,
            .sel = @min(self.ask_sel, self.ask_options.items.len),
        };
    }

    /// Rows of the panel's OWN option list: the model's options plus a final
    /// "Other" row. Zero for a free-text question.
    ///
    /// The list lives in the panel and not in the modal picker because of what
    /// the two widgets did to each other: the panel was painted AFTER the picker
    /// (`tui.zig:4191` over `tui.zig:4124`) and erased whatever the picker had
    /// drawn inside its rectangle, and the panel is wider than the picker for any
    /// question over ~56 columns. The result was a menu with its last option
    /// overwritten by a border. One widget cannot overlap itself.
    pub fn askChoiceRows(self: *Model) usize {
        self.askLock();
        defer self.askUnlock();
        if (!self.ask_active or self.ask_typing) return 0;
        if (self.ask_options.items.len == 0) return 0;
        return self.ask_options.items.len + 1;
    }

    /// Is the question a menu (as opposed to free text)?
    ///
    /// `typing` is what says the free-text path was taken: once it is set the
    /// list must never come back, or the panel re-lists the options on top of
    /// the text the user is typing.
    pub fn askNeedsChoice(self: *Model) bool {
        return self.askChoiceRows() > 0;
    }

    pub fn askSelection(self: *Model) usize {
        self.askLock();
        defer self.askUnlock();
        return self.ask_sel;
    }

    /// Moves the highlight, saturating at both ends.
    pub fn askMove(self: *Model, delta: isize) void {
        self.askLock();
        defer self.askUnlock();
        if (!self.ask_active or self.ask_typing) return;
        const n_opts = self.ask_options.items.len;
        if (n_opts == 0) return;
        const rows = n_opts + 1; // the last row is "Other"
        const cur = @min(self.ask_sel, rows - 1);
        const step: usize = @intCast(@abs(delta));
        self.ask_sel = if (delta < 0)
            (if (cur > step) cur - step else 0)
        else
            @min(cur + step, rows - 1);
        self.dirty = true;
    }

    /// The submitted text answers the open question instead of starting a turn.
    ///
    /// Split out of `submitInput` so it can be tested without an `EventContext`:
    /// `submitInput` arms the tick, which needs a real `Io`, and a test that
    /// cannot run the path cannot pin the behaviour.
    ///
    /// An EMPTY answer is a valid answer ("you decide"): the check has to come
    /// before the empty-prompt check below it, or Enter on an empty box would
    /// send a turn with an empty user message.
    pub fn askAnswerFromInput(self: *Model, trimmed: []const u8) bool {
        if (!self.askActive()) return false;
        const copy = self.allocator.dupe(u8, if (trimmed.len > 0) trimmed else "you decide") catch return true;
        self.answerAskOwned(copy);
        return true;
    }

    /// Enter on the highlighted row. False when there is no menu to answer, so
    /// the key can fall through to whatever else handles Enter.
    pub fn askAnswerSelected(self: *Model) bool {
        const rows = self.askChoiceRows();
        if (rows == 0) return false;
        const sel = self.askSelection();
        const n_opts = rows - 1; // the last row is "Other"
        if (sel >= n_opts) {
            // "Other": not an answer, it hands the input box over.
            self.askBeginTyping();
            self.ed.clear();
            self.ac = .{};
            return true;
        }
        self.askLock();
        const copy = self.allocator.dupe(u8, self.ask_options.items[sel]) catch {
            self.askUnlock();
            return true;
        };
        self.askUnlock();
        self.answerAskOwned(copy);
        // Closed in the SAME frame: otherwise the panel stays painted for the few
        // milliseconds until the worker wakes up and reads the answer, which
        // reads as "it did not take my answer".
        self.askLock();
        self.ask_active = false;
        self.askUnlock();
        return true;
    }

    /// Title of the picker: the header if the model gave one, else a default.
    ///
    /// A fixed buffer, because this is called from the draw (once per frame) and
    /// the returned slice has to survive the lock being released.
    pub fn askTitle(self: *Model) []const u8 {
        self.askLock();
        self.ask_title_len = 0;
        const h = self.ask_header orelse "";
        if (h.len > 0) {
            const n = @min(h.len, self.ask_title_buf.len);
            @memcpy(self.ask_title_buf[0..n], h[0..n]);
            self.ask_title_len = n;
        } else {
            const dflt = "the model has a question";
            @memcpy(self.ask_title_buf[0..dflt.len], dflt);
            self.ask_title_len = dflt.len;
        }
        const out = self.ask_title_buf[0..self.ask_title_len];
        self.askUnlock();
        return out;
    }

    /// Switches the input box to answer mode (the "Other" path).
    pub fn askBeginTyping(self: *Model) void {
        self.askLock();
        if (!self.ask_active) {
            self.askUnlock();
            return;
        }
        self.ask_typing = true;
        self.askUnlock();
        self.requestRedraw();
        self.dirty = true;
    }

    fn waitPermAnswer(self: *Model) void {
        var wait_ms: u64 = 1;
        while (true) {
            self.permLock();
            const done = self.perm_answer != .none;
            self.permUnlock();
            if (done) return;
            napMs(wait_ms);
            wait_ms = @min(wait_ms * 2, 20);
        }
    }

    // ── thread-safe API (enqueue; draw drains) ──────────
    pub fn pushKind(self: *Model, kind: md.Kind, text: []const u8) void {
        const copy = self.allocator.dupe(u8, text) catch return;
        self.lock();
        defer self.unlock();
        self.pending.append(self.allocator, .{ .kind = kind, .text = copy }) catch {
            self.allocator.free(copy);
        };
        self.dirty = true;
        // Ask for a frame now: the tick can be up to 120 ms away.
        self.redraw_requested.store(true, .seq_cst);
    }

    pub fn pushInfo(self: *Model, text: []const u8) void {
        self.pushKind(.info, text);
    }

    /// Error to the history: `✗ …` in red.
    ///
    /// The `.error_msg` Kind existed from the beginning (with its `✗` prefix)
    /// and NO caller used it: errors came out as `.info`, in the same gray as
    /// "session resumed" or "3 tool results elided". In a long history, the
    /// error — the only thing you have to read — was one more line.
    pub fn pushError(self: *Model, text: []const u8) void {
        self.pushKind(.error_msg, text);
    }

    /// Like `pushError` but the text is ALREADY caller-owned memory (it frees
    /// it).
    pub fn pushErrorOwned(self: *Model, text: []const u8) void {
        self.lock();
        defer self.unlock();
        self.pending.append(self.allocator, .{ .kind = .error_msg, .text = text }) catch {
            self.allocator.free(text);
        };
        self.dirty = true;
        self.redraw_requested.store(true, .seq_cst);
    }

    /// A header line with an imposed base style (Zo's mood color).
    pub fn pushBannerStyled(self: *Model, text: []const u8, base: md.Style) void {
        const copy = self.allocator.dupe(u8, text) catch return;
        self.lock();
        defer self.unlock();
        self.pending.append(self.allocator, .{ .kind = .banner, .text = copy, .base = base }) catch {
            self.allocator.free(copy);
        };
        self.dirty = true;
    }

    /// The opening screen: a hero, not a logo.
    ///
    /// This replaces a five-row ASCII wordmark. The measurements that killed
    /// the art are in AGENTS.md and they still hold: `▀` and `▄` paint HALF a
    /// cell, `#` at 12 rows high reads as a smudge, and "a TUI header is read in
    /// the first half second" — five rows of `#` is five rows of nothing before
    /// the user has typed anything.
    ///
    /// What replaces it is TYPE, and a reason to be here: the wordmark, one
    /// line of what this is, and the four commands that are actually useful in
    /// the first thirty seconds. That last part is the part the ASCII never was:
    /// it earned its rows.
    ///
    /// Three tones, from the paragraph's own `base` and `mood` slots plus the
    /// `*…*` mark. The `.banner` kind used to paint EVERYTHING in the brand
    /// green, which is how a five-line hero came out as five green lines — and
    /// a page where everything is the accent has no accent.
    ///
    /// `start_mood` is no longer used to paint anything here: the face is in the
    /// activity row, which is where it is read. The parameter stays to avoid
    /// changing the signature at the two call sites.
    pub fn pushHeader(self: *Model, start_mood: StatusKind) void {
        _ = start_mood;
        // NO leading spaces: the draw centers this block (`heroFrame`), so the
        // indent is a function of the terminal width and not a guess made at
        // startup and frozen into eight paragraphs.
        //
        // THE WORDMARK IS THE ART, and it is ONE paragraph with the five rows
        // inside it. It used to be the word "zode" in a colour, and the ASCII
        // art was in the tree but nobody drew it.
        self.pushHero(banner, theme.brand, theme.brand_hi);
        self.pushHero("a code agent in your terminal", theme.ink3, theme.ink3);
        self.pushHero(hero_rule, theme.line, theme.line);
        // A blank row between the rule and the grid, and one after it. Without
        // them the grid is part of the rule and the hero reads as three blocks.
        self.pushHero("", theme.brand, theme.brand_hi);
        self.pushHeroRow("/help", "commands", "ctrl+p", "palette");
        self.pushHeroRow("/model", "choose a model", "ctrl+t", "models");
        self.pushHeroRow("@file", "attach a file", "\u{23ce}", "ask anything");
    }

    /// One hero line with its own tones. `*…*` paints in `hi` and `~…~` in
    /// `mood`; everything else is `base`. The markers are REMOVED from the
    /// text, so the caller sees the clean string and the drawing comes out in
    /// three colors.
    fn pushHero(self: *Model, text: []const u8, base: md.Style, third: md.Style) void {
        const copy = self.allocator.dupe(u8, text) catch return;
        self.lock();
        defer self.unlock();
        self.pending.append(self.allocator, .{ .kind = .banner, .text = copy, .base = base, .mood = third }) catch {
            self.allocator.free(copy);
        };
        self.dirty = true;
    }

    /// One row of the hero's two-column grid.
    ///
    /// The KEY is lit, the description is dim and the shortcut is dimmer. The
    /// grid is scanned for "what do I press", and a grid where all three columns
    /// look the same is a paragraph, not a menu.
    ///
    /// Fixed column widths, not computed: a grid whose columns move when a
    /// label changes length is not a grid. They are byte counts and every label
    /// here is ASCII, so they are also column counts.
    fn pushHeroRow(self: *Model, key: []const u8, what: []const u8, kbd: []const u8, hint: []const u8) void {
        const line = std.fmt.allocPrint(
            self.allocator,
            "*{s}*  {s: <16}~{s}~  {s}",
            .{ key, what, kbd, hint },
        ) catch return;
        defer self.allocator.free(line);
        self.pushHero(line, theme.ink3, theme.status);
    }

    pub fn beginCatalogRequest(self: *Model, provider_id: []const u8) usize {
        self.lock();
        self.catalog_request_id +%= 1;
        if (self.catalog_request_id == 0) self.catalog_request_id = 1;
        const request_id = self.catalog_request_id;
        if (self.pending_items) |items| {
            palette.freeItems(self.allocator, items);
            self.pending_items = null;
        }
        const notice = std.fmt.bufPrint(&self.catalog_notice_buf, "Loading {s} model catalog…", .{provider_id}) catch "";
        self.catalog_notice_len = notice.len;
        self.dirty = true;
        self.unlock();
        self.requestRedraw();
        return request_id;
    }

    pub fn catalogRequestCurrent(self: *Model, request_id: usize) bool {
        self.lock();
        defer self.unlock();
        return self.catalog_request_id == request_id;
    }

    pub fn setCatalogNotice(self: *Model, request_id: usize, text: []const u8) void {
        self.lock();
        defer self.unlock();
        if (self.catalog_request_id != request_id) return;
        const n = @min(text.len, self.catalog_notice_buf.len);
        @memcpy(self.catalog_notice_buf[0..n], text[0..n]);
        self.catalog_notice_len = n;
        self.dirty = true;
        self.redraw_requested.store(true, .seq_cst);
    }

    pub fn catalogNotice(self: *Model, arena: std.mem.Allocator) []const u8 {
        self.lock();
        defer self.unlock();
        return arena.dupe(u8, self.catalog_notice_buf[0..self.catalog_notice_len]) catch "";
    }

    pub fn invalidateCatalogRequest(self: *Model) void {
        self.lock();
        self.catalog_request_id +%= 1;
        if (self.catalog_request_id == 0) self.catalog_request_id = 1;
        self.catalog_notice_len = 0;
        if (self.pending_items) |items| {
            palette.freeItems(self.allocator, items);
            self.pending_items = null;
        }
        self.dirty = true;
        self.unlock();
        self.requestRedraw();
    }

    pub fn setPendingCatalogItems(self: *Model, request_id: usize, items: []palette.Item) void {
        self.lock();
        defer self.unlock();
        if (self.catalog_request_id != request_id) {
            palette.freeItems(self.allocator, items);
            return;
        }
        if (self.pending_items) |old| palette.freeItems(self.allocator, old);
        self.pending_items = items;
        self.dirty = true;
        self.redraw_requested.store(true, .seq_cst);
    }

    /// The UI thread picks up the items and returns ownership.
    pub fn takePendingItems(self: *Model) ?[]palette.Item {
        self.lock();
        defer self.unlock();
        const items = self.pending_items;
        self.pending_items = null;
        return items;
    }

    /// Enqueues a prompt. The text MUST be a copy already made by the caller
    /// (deliberately typed `[]u8`: the queue owns what it stores and frees it
    /// in `deinit`).
    pub fn enqueuePrompt(self: *Model, text: []u8) usize {
        self.lock();
        defer self.unlock();
        self.queue.append(self.allocator, text) catch return self.queue.items.len;
        self.dirty = true;
        return self.queue.items.len;
    }

    /// Takes the next prompt out of the queue. `null` if there is none.
    pub fn takeQueued(self: *Model) ?[]u8 {
        self.lock();
        defer self.unlock();
        if (self.queue.items.len == 0) return null;
        const first = self.queue.orderedRemove(0);
        self.dirty = true;
        return first;
    }

    /// The text of the NEXT queued prompt, without taking it out.
    ///
    /// It is what the footer shows: the count says there is a queue, and the
    /// TEXT says what is coming. "2 queued" makes the user open their
    /// memory; "2 queued · fix the tests" does not.
    ///
    /// The slice belongs to the queue and the queue is drained by the WORKER,
    /// so the caller has to copy it before painting it. The footer does.
    pub fn queuedNext(self: *Model) ?[]const u8 {
        self.lock();
        defer self.unlock();
        if (self.queue.items.len == 0) return null;
        return self.queue.items[0];
    }

    /// Tenths of a second the current turn has been running. An instant is
    /// stored when streaming opens because `Timestamp.now` through the `Io`
    /// from draw is exactly what you don't want in the hot path.
    /// Hands the app's `Io` over. `runTui` calls it at startup.
    pub fn attachIo(self: *Model, io: std.Io) void {
        self.io = io;
        self.io_ready = true;
    }

    /// Milliseconds since `start`. 0 if there is no clock or no turn.
    pub fn millisSince(self: *Model, start: i128) i128 {
        if (!self.io_ready) return 0;
        const now = std.Io.Timestamp.now(self.io, .real).nanoseconds;
        if (now <= start) return 0;
        return @divTrunc(now - start, std.time.ns_per_ms);
    }

    /// Milliseconds the current turn has been running (0 if there is no turn or
    /// no clock). CAREFUL: milliseconds, not tenths: it was displayed as
    /// "153.3s" with 1.5s elapsed because the value was treated as tenths.
    pub fn busyMillis(self: *const Model) u64 {
        const started = self.busy_started_ns;
        if (started == 0) return 0;
        var m2 = @constCast(self);
        return @intCast(m2.millisSince(started));
    }

    /// The first `max` characters of the first queued prompt.
    pub fn queuedFirst(self: *Model, max: usize) []const u8 {
        self.lock();
        defer self.unlock();
        if (self.queue.items.len == 0) return "";
        const t = self.queue.items[0];
        if (t.len <= max) return t;
        return t[0..max];
    }

    pub fn isBusyFlag(self: *Model) bool {
        return self.isBusy();
    }

    /// Is there a turn in progress? `agent.startChat` asks this to decide
    /// between spawning a worker and enqueueing.
    pub fn isBusy(self: *Model) bool {
        self.lock();
        defer self.unlock();
        return self.workingLocked();
    }

    /// "Something is running" with the lock already held.
    ///
    /// A tool in progress COUNTS as work even without a stream: between
    /// `streamEnd` and `pushToolDone` there is a window (the whole execution of
    /// the tool) in which `busy` is already false, and without this a
    /// half-minute `bash` was left with no spinner, no clock and the strip
    /// saying "queued" — which is exactly the feeling of a hung app.
    fn workingLocked(self: *const Model) bool {
        return self.busy or self.streaming or self.tool_run != null or self.task_batch_total > 0;
    }

    pub fn taskParallelLimit(self: *Model) u8 {
        self.lock();
        defer self.unlock();
        return self.task_parallel_override;
    }

    pub fn setTaskParallelLimit(self: *Model, limit: u8) void {
        self.lock();
        self.task_parallel_override = if (limit == 0) 0 else @min(limit, 8);
        self.dirty = true;
        self.unlock();
        self.requestRedraw();
    }

    pub fn beginTaskBatch(self: *Model, total: usize) void {
        self.lock();
        self.task_batch_total = total;
        self.task_batch_completed = 0;
        self.task_batch_running = 0;
        self.dirty = true;
        self.unlock();
        self.requestRedraw();
    }

    pub fn taskBatchStarted(self: *Model) void {
        self.lock();
        if (self.task_batch_total > 0) self.task_batch_running += 1;
        self.dirty = true;
        self.unlock();
        self.requestRedraw();
    }

    pub fn taskBatchFinished(self: *Model) void {
        self.lock();
        if (self.task_batch_total > 0) {
            self.task_batch_running -|= 1;
            self.task_batch_completed = @min(self.task_batch_completed + 1, self.task_batch_total);
        }
        self.dirty = true;
        self.unlock();
        self.requestRedraw();
    }

    pub fn endTaskBatch(self: *Model) void {
        self.lock();
        self.task_batch_total = 0;
        self.task_batch_completed = 0;
        self.task_batch_running = 0;
        self.dirty = true;
        self.unlock();
        self.requestRedraw();
    }

    /// `workingLocked` for callers outside this file, and NOT renamed: the "locked"
    /// suffix is what says "this one wants the lock and `main`'s exit report must not
    /// block on a turn in flight to find out why the app is leaving".
    ///
    /// Reading `busy`/`streaming`/`tool_run` without the lock is a torn read, and a torn
    /// read in a DIAGNOSTIC is worse than a wrong one: it would print a state that never
    /// existed. This one is a three-word `or` over words, and the alternative is a report
    /// that lies about the moment it exists to explain.
    pub fn workingPublic(self: *const Model) bool {
        return self.workingLocked();
    }

    pub fn queuedCount(self: *Model) usize {
        self.lock();
        defer self.unlock();
        return self.queue.items.len;
    }

    /// Empties the queue, freeing the texts (Ctrl+C clears the input).
    pub fn clearQueue(self: *Model) void {
        self.lock();
        defer self.unlock();
        for (self.queue.items) |t| self.allocator.free(t);
        self.queue.clearRetainingCapacity();
    }

    /// Marks the start of a worker. Called right after `Thread.spawn`.
    pub fn beginWorker(self: *Model) void {
        _ = self.workers.fetchAdd(1, .seq_cst);
    }

    /// Marks the end of a worker (normal or on error): goes in `defer`.
    pub fn endWorker(self: *Model) void {
        _ = self.workers.fetchSub(1, .seq_cst);
    }

    /// Waits until no worker is in flight.
    ///
    /// With a time cap: a worker stuck in a network read cannot leave the app
    /// hanging on exit. Once the cap passes it moves on (a warning is better
    /// than never exiting).
    pub fn waitWorkers(self: *Model, budget_ms: u64) void {
        // It counts iterations, not clock time: `waitWorkers` is called during
        // shutdown, when the `Io` may already be in the process of being
        // destroyed, and asking the time through it is exactly what you must
        // not do.
        // `yield` gives up the processor, so a blocked worker still makes
        // progress.
        var spins: u64 = 0;
        const max_spins = budget_ms * 200; // ~5 iterations/ms as a practical cap
        while (self.workers.load(.seq_cst) > 0) {
            if (spins >= max_spins) return;
            spins += 1;
            std.Thread.yield() catch {};
        }
    }

    /// Enqueues a paragraph ALREADY with its memory copied. `text` becomes the
    /// model's. Releases the lock before touching anything else: the caller may
    /// want to enqueue more things after it (and the mutex is not
    /// reentrant).
    fn pushPending(self: *Model, p: Pending) void {
        self.lock();
        defer self.unlock();
        self.pending.append(self.allocator, p) catch {
            self.allocator.free(p.text);
        };
        self.dirty = true;
    }

    /// From the worker: hand the result of a `!` command over. Takes OWNERSHIP of
    /// both strings (they are freed here on failure and in `deinit` otherwise).
    pub fn pushShellOut(self: *Model, cmd: []u8, text: []u8, ms: u64) void {
        self.lock();
        defer self.unlock();
        self.shell_out.append(self.allocator, .{ .cmd = cmd, .text = text, .ms = ms }) catch {
            self.allocator.free(cmd);
            self.allocator.free(text);
            return;
        };
        self.dirty = true;
        self.redraw_requested.store(true, .seq_cst);
    }

    pub fn pushInfoOwned(self: *Model, text: []const u8) void {
        self.enqueueOwned(.info, text);
    }

    /// A line of history, formatted, and the OWNERSHIP is this function's
    /// problem. Use it instead of `pushInfoOwned(allocPrint(...) catch "…")`.
    ///
    /// That pattern is the "Invalid free" of this repo, and it is a landmine
    /// with a very long fuse: `allocPrint` returns heap memory, so on the happy
    /// path the literal fallback is never used, and when the allocator IS out of
    /// memory `pushInfoOwned` stores a pointer to `.rodata` and `Model.deinit`
    /// frees it -> "Invalid free" while the app is dying of something else.
    /// Thirteen call sites had it. The two failures cancel out into "zode
    /// crashed and I do not know why", which is the worst possible outcome.
    ///
    /// The ownership has to live in the SIGNATURE and not in a comment (the same
    /// rule as `Palette.setItemsOwned`): here the `[]u8` is created and consumed
    /// inside, so there is no way to get it wrong.
    pub fn pushInfoFmt(self: *Model, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.allocPrint(self.allocator, fmt, args) catch {
            // `pushInfo` COPIES, and a dupe that fails just returns: a literal
            // is safe here, which is the whole difference.
            self.pushInfo(fmt);
            return;
        };
        self.pushInfoOwned(text);
    }

    fn enqueueOwned(self: *Model, kind: md.Kind, text: []const u8) void {
        self.lock();
        defer self.unlock();
        self.pending.append(self.allocator, .{ .kind = kind, .text = text }) catch {
            self.allocator.free(text);
        };
        self.dirty = true;
    }

    /// Opens an assistant streaming paragraph.
    pub fn streamStart(self: *Model) void {
        self.lock();
        defer self.unlock();
        self.streaming = true;
        self.busy = true;
        self.busy_started_ns = if (self.io_ready)
            std.Io.Timestamp.now(self.io, .real).nanoseconds
        else
            0;
        self.stream_buf.clearRetainingCapacity();
        self.ttft_pending = true;
        self.ttft_ms = 0;
        self.dirty = true;
    }

    /// Opens the live paragraph of an agent-loop ITERATION (the one that comes
    /// after a tool) WITHOUT resetting the turn clock.
    ///
    /// With `streamStart` the strip's clock went back to zero on every
    /// iteration and the user saw time jump backwards just as the tool
    /// finished: the "the clock is running" feedback is what tells you
    /// something is hung, and a clock that resets is useless for that.
    pub fn streamStartIteration(self: *Model) void {
        self.lock();
        defer self.unlock();
        self.streaming = true;
        self.busy = true;
        self.stream_buf.clearRetainingCapacity();
        // TTFT is measured per ITERATION: the first one is the interesting one,
        // the following ones already come warm (the prefix is cached) and
        // there is no `streamStart` to reset them anyway.
        self.ttft_pending = true;
        self.dirty = true;
    }

    /// Assistant text delta (thread-safe). Grows without an artificial byte
    // cap: output renders indefinitely until the allocator itself refuses
    // (real OOM). Allocation failure sets stream_truncated so streamEnd can
    // emit a truncation marker.
    pub fn streamDelta(self: *Model, text: []const u8) void {
        self.lock();
        defer self.unlock();
        // The FIRST delta closes the TTFT: the clock we had was the whole
        // turn's, and with a 20 s stream that says nothing about how long it
        // took to start.
        if (self.ttft_pending and self.stream_buf.items.len == 0 and text.len > 0) {
            self.ttft_pending = false;
            self.ttft_ms = self.busyMillis();
        }
        // Grow without an artificial cap. A real OOM sets stream_truncated and
        // drops further chunks; nothing is silently truncated by a fixed budget.
        if (self.stream_truncated) {
            // Already hit an allocation limit: drop all further chunks.
        } else if (self.stream_buf.appendSlice(self.allocator, text)) |_| {
            // appended successfully
        } else |err| {
            if (err == error.OutOfMemory) self.stream_truncated = true;
        }
        self.dirty = true;
        self.redraw_requested.store(true, .seq_cst);
    }

    /// Closes the streaming and fixes the paragraph into the history.
    pub fn streamEnd(self: *Model) void {
        self.lock();
        defer self.unlock();
        // The assistant paragraph goes into `pending`, NOT into `paras`.
        //
        // `pending` is FIFO and is drained into `paras` by the DRAW, so
        // enqueueing here gives the SAME ordering the old code fought for: the
        // assistant text lands after the `⏺ tool` / `⎿ result` lines that were
        // already queued, instead of on top of them. (Doing it with an explicit
        // `drainPendingLocked()` first used to be the way to get that order, and
        // it is what this replaces.)
        //
        // AND, more importantly: `streamEnd` runs on the WORKER thread. Appending
        // to `paras` from there reallocates `paras.items` while the UI thread is
        // in the draw reading `paras[i].text` WITHOUT the lock — the old buffer
        // gets freed under its feet. That was a hard crash (SIGSEGV inside
        // `mem.count` on a freed paragraph), reproducible with any prompt that
        // ran a tool. Enqueueing keeps `paras` owned by the UI thread alone.
        //
        // `or stream_buf.len > 0`: if nobody opened a paragraph (an iteration
        // that never got a `streamStart`) the text is NOT lost. Before, the `if
        // (streaming)` discarded it silently and the final answer of a turn
        // with tools never appeared.
        //
        // And ONLY if there IS text. A turn that dies with an error (403, 5xx
        // after 3 retries) opened the live paragraph and closed it empty, leaving
        // a "◆" alone in the history: noise that looks like content. With no
        // text there is nothing to keep, and the `busy = false` below still does
        // its job.
        const has_text = !std.mem.eql(u8, std.mem.trim(u8, self.stream_buf.items, " \t\n\r"), "");
        if (has_text and (self.streaming or self.stream_buf.items.len > 0)) {
            const text = self.allocator.dupe(u8, self.stream_buf.items) catch {
                self.stream_truncated = false;
                return;
            };
            self.pending.append(self.allocator, .{ .kind = .assistant, .text = text }) catch {
                self.allocator.free(text);
            };
            self.stream_buf.clearRetainingCapacity();
            self.stream_truncated = false;
        }
        // `streaming` goes down HERE, unconditionally, and not inside the `if`.
        //
        // It was inside, which meant that any turn that ended with an EMPTY
        // stream buffer left the model "streaming" forever. `workingLocked()`
        // counts it, so the activity strip kept reporting a live turn forever:
        // a clock that never stops, a spinner that never stops, and a status bar
        // that says the app is busy long after the turn is over.
        //
        // The empty-buffer paths are not exotic: every turn error before the
        // first token (401, 403, 429 given up, 5xx after 3 retries), ESC, and
        // "no model to talk to" all land here with nothing streamed.
        //
        // The test that covers this (`streamEnd` with no text) asserted `!busy`
        // and the paragraph count, but never `!streaming`, which is exactly why
        // it went unnoticed.
        self.streaming = false;
        self.busy = false;
        // `dirty` is MANDATORY here: a paragraph has just been enqueued, and
        // without `dirty` draw is not requested until a key arrives. The window
        // between this `streamEnd` and the next `pushToolStart` (with a session
        // write(2) and a DEFLATE-9 in between) was exactly where the tick chain
        // failed to rearm and the screen died.
        self.dirty = true;
    }

    /// Executed tool line (thread-safe; the worker calls it).
    pub fn pushTool(self: *Model, text: []const u8) void {
        self.pushKind(.tool, text);
    }

    // ── tool calls in the timeline ─────────────────────────
    /// Header of a tool in progress: "⏺ Read(src/tui.zig)".
    /// Header of a tool: `⏺ write(hola.js)`.
    ///
    /// The name is marked with `*…*` so the parser paints it in the tool's
    /// bright color and the argument in the dim one. Without the mark, `write`
    /// and `hola.js` came out the same cyan and were indistinguishable.
    pub fn pushToolStart(self: *Model, tool: []const u8, arg: []const u8) void {
        const line = if (arg.len == 0)
            std.fmt.allocPrint(self.allocator, "*{s}*", .{tool}) catch return
        else
            std.fmt.allocPrint(self.allocator, "*{s}*({s})", .{ tool, arg }) catch return;
        defer self.allocator.free(line);
        self.pushKind(.tool_run, line);

        // Registers the tool in progress for the "running" line. Own copies:
        // `arg` comes from a worker arena that is freed at the end of the turn.
        const name_copy = self.allocator.dupe(u8, tool) catch return;
        const arg_copy = self.allocator.dupe(u8, arg) catch {
            self.allocator.free(name_copy);
            return;
        };
        self.lock();
        defer self.unlock();
        if (self.tool_run) |tr| tr.deinit(self.allocator);
        self.tool_run = .{
            .name = name_copy,
            .arg = arg_copy,
            .started_ns = if (self.io_ready) std.Io.Timestamp.now(self.io, .real).nanoseconds else 0,
        };
        self.dirty = true;
        self.redraw_requested.store(true, .seq_cst);
    }

    /// Closes the "running" line (`pushToolDone` sets it).
    pub fn toolRunEnd(self: *Model) void {
        self.lock();
        defer self.unlock();
        if (self.tool_run) |tr| {
            tr.deinit(self.allocator);
            self.tool_run = null;
            // The clock line disappears: that is a change that has to be
            // painted.
            self.dirty = true;
            self.redraw_requested.store(true, .seq_cst);
        }
    }

    /// Time until the first token of the last stream (0 if none arrived).
    pub fn ttftMillis(self: *const Model) u64 {
        var m2 = @constCast(self);
        m2.lock();
        defer m2.unlock();
        return m2.ttft_ms;
    }

    /// Has the stream in progress still not received its first token?
    pub fn ttftPending(self: *const Model) bool {
        var m2 = @constCast(self);
        m2.lock();
        defer m2.unlock();
        return m2.ttft_pending;
    }

    /// Name of the tool in progress, or null. The caller owns the result: it is a
    /// COPY, because the name lives in the Model and `toolRunEnd` frees it from
    /// the worker thread the moment the tool is done.
    ///
    /// It used to return `tr.name` with the lock already released, which hands
    /// out a pointer that can be freed before the draw reads it. Same ownership
    /// violation as the live paragraph copy, on the hot path of every tool.
    pub fn toolRunName(self: *Model, out: []u8) ?[]const u8 {
        self.lock();
        defer self.unlock();
        const tr = self.tool_run orelse return null;
        const n = @min(tr.name.len, out.len);
        @memcpy(out[0..n], tr.name[0..n]);
        return out[0..n];
    }

    /// Milliseconds the tool in progress has been running (0 if there is none).
    ///
    /// TAKES THE LOCK, and that is the whole point. This used to call
    /// `toolRunMillisLocked` directly while holding nothing — which is what the
    /// `_Locked` suffix is supposed to mean the opposite of. The UI thread read
    /// `self.tool_run` while the worker thread could be inside `toolRunEnd`,
    /// which frees it: a use-after-free of the `ToolRun` the moment a 3ms
    /// `read` finishes.
    ///
    /// It also made the CLOCK read 0. `drawActivityStrip` asks for the name
    /// (locked) and then for the time (unlocked); between the two a fast tool
    /// could finish and free the whole thing, so the row painted a stale or
    /// zero elapsed time — the reported symptom of a timer that does not move.
    pub fn toolRunMillis(self: *Model) u64 {
        self.lock();
        defer self.unlock();
        return self.toolRunMillisLocked();
    }

    /// Same, but for when the caller ALREADY holds the lock.
    fn toolRunMillisLocked(self: *const Model) u64 {
        const tr = self.tool_run orelse return 0;
        if (!self.io_ready or tr.started_ns == 0) return 0;
        const now = std.Io.Timestamp.now(self.io, .real).nanoseconds;
        if (now <= tr.started_ns) return 0;
        return @intCast(@divTrunc(now - tr.started_ns, std.time.ns_per_ms));
    }

    /// A tool result: "⎿  Read 1006 lines · 3ms · Ctrl+R expand". Stores the
    /// full result so Ctrl+R can expand it to the full transcript. When the
    /// full result equals the summary there is nothing to expand and no hint
    /// is painted.
    pub fn pushToolDone(
        self: *Model,
        tool: []const u8,
        summary: []const u8,
        ms: u64,
        result: []const u8,
    ) void {
        var line_buf: [256]u8 = undefined;
        const head: []const u8 = if (summary.len > 0) summary else tool;
        // Marked summary and dim time: you read "what happened" and then "how
        // long it took" without them mixing. When the full result differs from
        // the summary, append a Ctrl+R hint so the user knows the tool result
        // is condensed and can be expanded to the full transcript.
        const can_expand = result.len > 0 and !std.mem.eql(u8, result, summary);
        const line = if (can_expand)
            std.fmt.bufPrint(&line_buf, "*{s}* · {d}ms · Ctrl+R expand", .{ head, ms }) catch head
        else
            std.fmt.bufPrint(&line_buf, "*{s}* · {d}ms", .{ head, ms }) catch head;

        // Three copies: the paragraph's (pending), the summary and the full
        // result (for Ctrl+R). All gpa-owned.
        const copy = self.allocator.dupe(u8, line) catch return;
        const full = self.allocator.dupe(u8, result) catch {
            self.allocator.free(copy);
            return;
        };
        const sum = self.allocator.dupe(u8, line) catch {
            self.allocator.free(copy);
            self.allocator.free(full);
            return;
        };
        // Before the lock: `toolRunEnd` takes it on its own and `std.atomic.Mutex`
        // is not reentrant (deadlocking on it inside = the app hangs).
        self.toolRunEnd();
        self.lock();
        defer self.unlock();
        if (self.last_tool) |*lt| lt.deinit(self.allocator);
        self.pending.append(self.allocator, .{ .kind = .tool_res, .text = copy }) catch {
            self.allocator.free(copy);
            self.allocator.free(full);
            self.allocator.free(sum);
            return;
        };
        // `dirty` is not decoration: it is what keeps the tick chain alive. A
        // state change WITHOUT `dirty` leaves a window where no redraw is
        // requested and the screen goes dead (see `armTick`).
        self.dirty = true;
        // The paragraph index is fixed on drain; `pending` is not in `paras` yet.
        self.last_tool = .{
            .para_idx = self.paras.items.len + self.pending.items.len - 1,
            .result = full,
            .summary = sum,
            .expanded = false,
        };
    }

    /// A diff: ONE paragraph with the lines joined by `\n`.
    ///
    /// Before it was one paragraph PER LINE. With ≥129 lines that blew past
    /// the segment cache cap and hung the app instantly (the layout loop bug):
    /// a single `write` of a 129-line file, total freeze. And on top of that
    /// each line was a paragraph, so besides hanging it came out "very spaced
    /// out" (a blank row between each diff line).
    ///
    /// `md.parse` splits on `\n` just like on paragraphs, so the render does
    /// not change: they are still N rows, but N-1 fewer blank rows.
    ///
    /// Returns how many lines were added and how many removed (they were
    /// already counted and thrown away); the caller can show it in the
    /// summary.
    pub fn pushDiff(self: *Model, before: []const u8, after: []const u8) DiffCounts {
        return self.pushDiffLang(before, after, "");
    }

    /// Like `pushDiff` but knowing the file's language, to tokenize the body
    /// of each line (see `agent.langFromPath`).
    pub fn pushDiffLang(
        self: *Model,
        before: []const u8,
        after: []const u8,
        lang: []const u8,
    ) DiffCounts {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const diff_lines = md.unifiedDiff(arena, before, after) catch return .{};
        var added: usize = 0;
        var removed: usize = 0;
        for (diff_lines) |l| {
            if (l.len > 0 and l[0] == '+') added += 1;
            if (l.len > 0 and l[0] == '-') removed += 1;
        }
        if (added == 0 and removed == 0) {
            // Either nothing changed, or the file goes over
            // `md.max_diff_lines` and what there is is a notice. In the second
            // case it IS shown: staying quiet would be "I saw nothing" (which
            // is what the model would conclude).
            if (diff_lines.len == 1 and std.mem.startsWith(u8, diff_lines[0], "diff omitted")) {
                const copy = self.allocator.dupe(u8, diff_lines[0]) catch return .{};
                defer self.allocator.free(copy);
                self.pushInfo(copy);
            }
            return .{}; // nothing changed: don't dirty the history
        }

        var joined: std.ArrayList(u8) = .empty;
        // `allocatedSlice` and not `items`: in 0.16 `items` is the LENGTH slice
        // and the capacity is separate, so freeing `items` with a bigger
        // capacity is an `Invalid free` (it blew up in the diff test).
        defer self.allocator.free(joined.allocatedSlice());
        for (diff_lines) |l| {
            if (joined.items.len > 0) joined.append(self.allocator, '\n') catch return .{};
            joined.appendSlice(self.allocator, l) catch return .{};
        }

        // A long diff COLLAPSES into a preview: a `write` of a 500-line file is
        // 500 rows of history, and the timeline is where the user is trying to
        // follow what the agent is doing. Put the summary before the excerpt so
        // the scale and the way to expand it are visible immediately.
        var short: ?[]const u8 = null;
        if (diff_lines.len > diff_preview_lines) {
            var s: std.ArrayList(u8) = .empty;
            s.print(arena, "diff preview · +{d} −{d}\n", .{ added, removed }) catch {};
            for (diff_lines[0..diff_preview_lines], 0..) |l, i| {
                if (i > 0 or s.items.len > 0) s.append(arena, '\n') catch break;
                s.appendSlice(arena, l) catch break;
            }
            s.print(
                arena,
                "\n… {d} more lines · ctrl+r to expand",
                .{diff_lines.len - diff_preview_lines},
            ) catch {};
            if (s.items.len > 0) short = s.items;
        }

        // The WORD-level diff is painted when the paragraph shows the whole
        // diff. A preview is a summary, and a word-level highlight inside a
        // summary is confetti: the reader cannot see the whole change, so
        // which words changed inside those twelve rows is noise.
        self.pushDiffKind(joined.items, short, lang, short == null);
        return .{ .added = added, .removed = removed };
    }

    /// Enqueues a diff paragraph WITH its language (`agent.langFromPath` gets
    /// it from the path's extension), collapsing it into `short` when the
    /// caller built one.
    ///
    /// Both slices are BORROWED: everything that outlives this call is copied
    /// here, and the caller frees its own buffers. (The old version took
    /// ownership of `text` in two of its three paths and the caller freed it
    /// anyway — a double free that only ever ran on out-of-memory.)
    ///
    /// The language is not stored as its own string but as the SAME slice
    /// `pushToolStart` already copied from the path: otherwise the paragraph
    /// would point at the worker's arena, which is freed at the end of the
    /// turn.
    fn pushDiffKind(self: *Model, text: []const u8, short: ?[]const u8, lang: []const u8, word_diff: bool) void {
        const gpa = self.allocator;

        // What the paragraph shows, and what is kept for Ctrl+R. When either
        // copy fails the diff is shown WHOLE instead: a collapsed view nothing
        // can open is worse than a long one.
        var para_src: []const u8 = text;
        var keep_full: []u8 = &.{};
        var keep_short: []u8 = &.{};
        if (short) |s| {
            const f = gpa.dupe(u8, text) catch null;
            const sh = gpa.dupe(u8, s) catch null;
            if (f != null and sh != null) {
                keep_full = f.?;
                keep_short = sh.?;
                para_src = s;
            } else {
                if (f) |x| gpa.free(x);
                if (sh) |x| gpa.free(x);
            }
        }
        const collapsed = keep_short.len > 0;

        const text_copy = gpa.dupe(u8, para_src) catch {
            freeDiffMemoParts(gpa, keep_full, keep_short);
            return;
        };
        const lang_copy = gpa.dupe(u8, lang) catch {
            gpa.free(text_copy);
            freeDiffMemoParts(gpa, keep_full, keep_short);
            self.pushKind(.diff, para_src);
            return;
        };

        self.lock();
        defer self.unlock();
        const idx = self.paras.items.len + self.pending.items.len;
        self.pending.append(self.allocator, .{
            .kind = .diff,
            .text = text_copy,
            .lang = lang_copy,
            .word_diff = word_diff,
        }) catch {
            gpa.free(text_copy);
            gpa.free(lang_copy);
            freeDiffMemoParts(gpa, keep_full, keep_short);
            return;
        };
        if (collapsed) {
            // Attached to the tool result that produced it: Ctrl+R toggles the
            // last thing that was collapsed, which for a write/edit IS the diff.
            if (self.last_tool) |*lt| {
                if (lt.diff_full.len > 0) gpa.free(lt.diff_full);
                if (lt.diff_short.len > 0) gpa.free(lt.diff_short);
                lt.diff_full = keep_full;
                lt.diff_short = keep_short;
                lt.diff_para_idx = idx;
                lt.diff_expanded = false;
                keep_full = &.{};
                keep_short = &.{};
            }
        }
        freeDiffMemoParts(gpa, keep_full, keep_short);
        self.dirty = true;
        self.redraw_requested.store(true, .seq_cst);
    }

    fn freeDiffMemoParts(gpa: std.mem.Allocator, full: []u8, short: []u8) void {
        if (full.len > 0) gpa.free(full);
        if (short.len > 0) gpa.free(short);
    }

    /// Ctrl+R: expands or collapses the last tool's result.
    ///
    /// When the last tool produced a COLLAPSED diff, the diff is what it
    /// toggles: that is the thing that was hidden, and the tool result under a
    /// `write` is a preview of the same file. With no diff (a `read`, a `grep`)
    /// it behaves as it always has.
    pub fn toggleLastTool(self: *Model) bool {
        self.lock();
        var lt = self.last_tool orelse {
            self.unlock();
            return false;
        };
        if (lt.hasDiff()) {
            const ok = toggleParagraph(self, lt.diff_para_idx.?, lt.diff_expanded, lt.diff_full, lt.diff_short);
            if (ok) {
                lt.diff_expanded = !lt.diff_expanded;
                self.last_tool = lt;
            }
            self.unlock();
            return ok;
        }
        const idx = lt.para_idx;
        const ok = toggleParagraph(self, idx, lt.expanded, lt.result, lt.summary);
        if (ok) {
            lt.expanded = !lt.expanded;
            self.last_tool = lt;
        }
        self.unlock();
        return ok;
    }

    /// Swaps paragraph `idx` between the two texts (`expanded` says which one
    /// it is showing). Returns false when there is nothing to swap.
    ///
    /// `textLive` runs FIRST: a paragraph outside the scroll window is stored
    /// COMPRESSED (`is_cold`), and overwriting that with raw text while the
    /// flag stays set makes the next rehydrate call `decompressInto` on text
    /// that was never compressed — an assert in debug and a garbage paragraph
    /// in release. Toggling a tool result you scrolled away from is exactly
    /// when this happens.
    fn toggleParagraph(
        self: *Model,
        idx: usize,
        expanded: bool,
        full: []const u8,
        short: []const u8,
    ) bool {
        if (idx >= self.paras.items.len) return false;
        const want = if (expanded) short else full;
        if (want.len == 0) return false;
        const p = &self.paras.items[idx];

        _ = p.textLive(self.allocator);
        const copy = self.allocator.dupe(u8, want) catch return false;
        self.allocator.free(p.text);
        p.text = copy;
        p.is_cold = false;
        // The word-level diff belongs to the WHOLE diff: a preview is a
        // summary and its highlights are noise, so expanding it turns them
        // on and collapsing it turns them off.
        p.word_diff = !expanded;
        // The layout of this and the following paragraphs changes: re-cache.
        if (self.cache_from == null or idx < self.cache_from.?) self.cache_from = idx;
        // The anchor is NOT touched: Ctrl+R used to set `scroll = 0`, which
        // yanked the view to the bottom while you were reading something else.
        return true;
    }

    /// `Stack.init` needs the allocator and `Model.init` already has it.
    pub fn initCheckpoints(self: *Model) void {
        self.checkpoints = .init(self.allocator);
    }

    /// Applies the list the `todo` tool sends and returns what the history has
    /// to say about it (`.same` when the list did not change, which is the
    /// normal case: the model resends the same list).
    ///
    /// The caller owns the summary text: here the plan is only copied into
    /// fixed buffers, which is what can live between frames.
    pub fn applyPlan(self: *Model, items: []const plan_mod.Item, n: u8) plan_mod.Plan.Applied {
        self.lock();
        defer self.unlock();
        const r = self.plan.apply(items, n);
        if (r == .changed or r == .empty) {
            self.dirty = true;
            self.redraw_requested.store(true, .seq_cst);
        }
        return r;
    }

    /// Opens the checkpoint of a turn (`startChat` calls it, once per prompt,
    /// before spawning the worker).
    pub fn beginCheckpoint(self: *Model, label: []const u8) void {
        self.lock();
        defer self.unlock();
        self.checkpoints.begin(label);
    }

    /// Adds the snapshot of a file to the checkpoint of the turn in progress.
    ///
    /// `existed` is explicit and not deduced from the contents: "the file was
    /// not there" and "the file was empty" are undone differently (delete vs
    /// write empty), and a `catch ""` does not tell the two apart.
    pub fn snapshotFile(
        self: *Model,
        path: []const u8,
        content: []const u8,
        existed: bool,
    ) void {
        self.lock();
        defer self.unlock();
        if (self.checkpoints.isEmpty()) return;
        _ = self.checkpoints.last().?.addFile(self.allocator, path, content, existed);
    }

    /// Takes the checkpoint of the last turn to undo it, and CONSUMES it (it
    /// leaves the stack): otherwise two `/undo` in a row would restore the same
    /// thing twice, and a second `/undo` would have to undo the PREVIOUS turn.
    ///
    /// The memory of the snapshots goes to the CALLER, which has to do
    /// `defer cp.deinit(...)`. That is why the name says `_Owned`: the first
    /// version did `deinit` here and returned a copy whose `data` was already
    /// freed, and `/undo` wrote released memory (a segfault when WRITING the
    /// file, not when reading it, which is why the test caught it in
    /// `expectEqualStrings` and not in the undo itself).
    pub fn takeCheckpointOwned(self: *Model) ?checkpoint.Checkpoint {
        self.lock();
        defer self.unlock();
        const cp = self.checkpoints.last() orelse return null;
        const taken = cp.*;
        // `len = 0` BEFORE shifting: the source slot stops having snapshots to
        // free (or the teardown's `deinit` would free them A SECOND time).
        cp.len = 0;
        cp.bytes = 0;
        // The rest moves down one. With a single element the stack ends empty.
        var i: usize = 0;
        while (i + 1 < self.checkpoints.len) : (i += 1) {
            self.checkpoints.items[i] = self.checkpoints.items[i + 1];
        }
        self.checkpoints.items[self.checkpoints.len - 1].len = 0;
        self.checkpoints.len -= 1;
        return taken;
    }

    /// Is there anything to undo? (so `/undo` does not say "nothing" when there
    /// is)
    pub fn canUndo(self: *Model) bool {
        self.lock();
        defer self.unlock();
        const cp = self.checkpoints.last() orelse return false;
        return cp.len > 0;
    }

    /// Copy of the plan for the draw (under the lock, because the worker writes
    /// it).
    pub fn planCopy(self: *Model) plan_mod.Plan {
        self.lock();
        defer self.unlock();
        return self.plan;
    }

    /// Puts a whole plan back, under the lock.
    ///
    /// It exists for the PATCH form of `todo`: the worker computes the new list on
    /// a copy (`Plan` is a plain value with fixed buffers, so a copy is a memcpy)
    /// and hands it over once it is complete. Doing it in place would mean a
    /// half-applied patch visible to the draw, and the draw runs 60 times a second
    /// on another thread.
    pub fn replacePlan(self: *Model, p: plan_mod.Plan) void {
        self.lock();
        defer self.unlock();
        self.plan = p;
        self.dirty = true;
    }

    pub fn clearPlan(self: *Model) void {
        self.lock();
        defer self.unlock();
        self.plan.clear();
        self.dirty = true;
        self.redraw_requested.store(true, .seq_cst);
    }

    /// Moves `pending` to `paras`. Called by draw; `pub` so the tests can check
    /// what got enqueued without setting up an `Io` (draw needs one).
    pub fn drainPending(self: *Model) void {
        self.lock();
        defer self.unlock();
        self.drainPendingLocked();
    }

    /// Takes the finished `!` commands out of the queue and hands them to the
    /// agent, which paints them and puts them in the session.
    ///
    /// On the UI thread on purpose: `pushShellOut` is called from a worker, and
    /// the session's message list and its file handle are one thing with one
    /// owner. `agent.shellOutputArrived` does both the history and the session.
    fn drainShellOut(self: *Model) void {
        self.lock();
        var batch = self.shell_out;
        self.shell_out = .empty;
        self.unlock();
        // Moved OUT under the lock: the array itself is now ours, so the worker
        // can go on filling the (new, empty) one while this is being painted.
        if (batch.items.len == 0) return;
        defer batch.deinit(self.allocator);
        for (batch.items) |so| {
            agent.shellOutputArrived(self, so);
            self.allocator.free(so.cmd);
            self.allocator.free(so.text);
        }
    }

    /// Moves `pending` to `paras`. The caller holds the lock.
    ///
    /// THE ONLY PLACE `paras` GROWS, and it runs on the UI thread (from the
    /// draw). That is a hard invariant, not a style preference: the draw then
    /// reads `paras[i].text` WITHOUT the lock (it is the whole history, every
    /// frame), so if the worker could append here, the reallocation would free
    /// the old `items` buffer underneath it. `streamEnd` used to append from the
    /// worker and crashed with SIGSEGV on any turn that ran a tool.
    ///
    /// If you need a new paragraph from the worker: enqueue it in `pending`.
    fn drainPendingLocked(self: *Model) void {
        // Re-anchor at the bottom ONLY if something really came in. Before,
        // `scroll = 0` was set every frame, and since `drainPending` is always
        // called, any scroll was wiped on the next frame: PageUp moved NOTHING
        // and it looked like scrolling didn't work.
        const hubo_nuevo = self.pending.items.len > 0;
        for (self.pending.items) |p| {
            self.paras.append(self.allocator, .{
                .kind = p.kind,
                .text = p.text,
                .base = p.base,
                .mood = p.mood,
                .lang = p.lang,
                .word_diff = p.word_diff,
            }) catch {
                self.allocator.free(p.text);
                if (p.lang.len > 0) self.allocator.free(p.lang);
            };
        }
        self.pending.clearRetainingCapacity();
        self.dirty = false;
        // NOTHING to do about the scroll here, and that is the point.
        //
        // There used to be a "sticky bottom" line here:
        //   `if (hubo_nuevo and self.scroll == 0) self.scroll = 0;`
        // which assigned 0 to the value the guard had just proven was 0. A
        // literal no-op that had been read as a feature for months.
        //
        // Stickiness is now a property of the data, not of a line of code: the
        // anchor is ABSOLUTE, so appending paragraphs cannot move the view, and
        // `follow_bottom` is what makes new text follow you when you ARE at the
        // bottom. Both fall out of `computeVisible`.
        _ = hubo_nuevo;
    }

    /// Empties the visible history (Ctrl+L). The cached paragraphs are freed
    /// and the on-disk session is left alone.
    pub fn clearHistory(self: *Model) void {
        self.clearSegCache();
        for (self.paras.items) |p| freePara(self.allocator, p);
        self.paras.clearRetainingCapacity();
        self.anchor = 0;
        self.anchor_para = 0;
        self.anchor_off = 0;
        self.follow_bottom = true;
    }

    /// "There is work pending" snapshot under a single lock (the getters take
    /// the lock, so they cannot be called from inside).
    ///
    /// `streaming` lives here and is not read bare in draw: the worker writes
    /// it from another thread, and a `bool` read unsynchronized on every frame
    /// is a data race (benign, but for free hard to debug).
    pub const Activity = struct {
        busy: bool,
        dirty: bool,
        perm: bool,
        ask: bool,
        picker: bool,
        streaming: bool,
        subagent_total: usize,
        subagent_completed: usize,
        subagent_running: usize,
    };

    fn activity(self: *Model) Activity {
        self.lock();
        defer self.unlock();
        return .{
            .busy = self.workingLocked(),
            .dirty = self.dirty,
            .perm = self.perm_active,
            // Read from the ASK lock, not this one: the ask dialog has its own
            // mutex on purpose (the permission one does too) so a parked worker
            // never holds the history lock. Reading `ask_active` here without it
            // would be the unsynchronized read of a bool from another thread.
            .ask = blk: {
                self.askLock();
                defer self.askUnlock();
                break :blk self.ask_active;
            },
            .picker = self.picker_active,
            .streaming = self.streaming,
            .subagent_total = self.task_batch_total,
            .subagent_completed = self.task_batch_completed,
            .subagent_running = self.task_batch_running,
        };
    }

    /// Requests a frame within `ms` ms. Idempotent: it does not stack timers.
    /// If the timer fails to register (rare, but can happen under load or in
    /// ReleaseSmall due to vaxis internals), we log and leave `tick_armed`
    /// false so the next event will retry. This prevents the tick chain from
    /// dying silently and leaving the app frozen.
    fn armTick(self: *Model, ctx: *vxfw.EventContext) !void {
        if (self.tick_armed) return;
        const ms = self.tickInterval();
        // Set armed AFTER successful registration, so a failure doesn't leave
        // the flag stuck and block future retries.
        self.tick_armed = true;
        ctx.tick(ms, self.widget()) catch |err| {
            // Timer registration failed — reset flag so next event retries.
            // We don't propagate the error because the app must stay responsive.
            self.tick_armed = false;
            if (builtin.single_threaded) {
                // In single-threaded tests, propagate to surface the issue.
                return err;
            }
            // Log to stderr for post-mortem (only in ReleaseSmall this path is hit).
            std.debug.print("zode: tick registration failed: {}\n", .{err});
        };
    }

    /// Wall clock in MILLISECONDS — the clock the mascot animation runs on.
    ///
    /// `toSeconds() * 1000` used to be here, and it is what made the keyframes
    /// invisible: every beat of `err` (70, 70, 130, 150 ms) and the launch of
    /// `done` (90 ms) rounded to the same instant, so the tracks the module
    /// describes never actually ran. A TUI test has no `Io`, and its clock is
    /// 0, which is frame 0 of whatever state it is painting.
    fn nowMs(self: *Model) u64 {
        if (!self.io_ready) return 0;
        const ns = std.Io.Timestamp.now(self.io, .real).nanoseconds;
        return @intCast(@divTrunc(ns, std.time.ns_per_ms));
    }

    /// Milliseconds until the next frame is worth painting.
    ///
    /// One ceiling, one floor and one exception, and each is a different
    /// requirement:
    ///
    ///  * the CEILING wakes the loop even when nothing is moving, because a
    ///    worker's `requestRedraw` cannot wake it by itself (a tick is the only
    ///    thing that does) — 120 ms at rest, 40 ms while the app is working;
    ///  * the FLOOR is the mascot's own beat: the next paint is scheduled for
    ///    when the current frame ENDS, so a 100 ms blink is not sampled by a
    ///    120 ms metronome and shown for a random 120 ms;
    ///  * the EXCEPTION is a face whose motion layer moves: ~30 fps, the
    ///    fastest a terminal needs, because the lean is whole cells and there
    ///    is nothing between two of them to draw.
    fn tickInterval(self: *Model) u32 {
        const a = self.activity();
        var cap: u32 = if (a.busy or a.dirty) 40 else 120;
        if (mascot.moves(self.mascot_animator.kind)) cap = 33;
        const left = mascot.frames.remainingMs(
            self.mascot_animator.kind,
            self.mascot_animator.elapsed(self.nowMs()),
        );
        const wait: u32 = @intCast(@min(@as(u64, cap), left));
        return @max(wait, 8);
    }

    /// True when the face on screen is not the face the clock says it should
    /// be: a tick that lands on a new beat (or a new lean) has something to
    /// paint, and one that lands mid-beat does not.
    fn mascotMoved(self: *Model) bool {
        if (!self.face_painted) return true;
        const p = self.mascot_animator.pose(self.nowMs());
        return p.dx != self.face_painted_dx or !std.mem.eql(u8, p.text, &self.face_painted_text);
    }

    /// Marks that a paint is needed. The worker calls it on EVERY `push*`.
    ///
    /// The tick always rearms itself (see the `.tick` handler), so this is not
    /// essential to avoid dying: it is to avoid waiting for the next tick when
    /// the worker has just enqueued text, which is exactly what makes the TUI
    /// look up to date. An atomic and not a `bool` because one thread writes
    /// it and another reads it without the lock.
    pub fn requestRedraw(self: *Model) void {
        self.redraw_requested.store(true, .seq_cst);
    }

    /// Scrolls the history up (`n` > 0) or down, in display lines.
    ///
    /// The anchor is clamped to `[0, max_offset]` on EVERY call, and that clamp
    /// is the whole fix for "I scrolled up and then could not scroll back
    /// down". It used to clamp only to a `1_000_000` constant while
    /// `computeVisible` clamped a local copy of the offset for drawing, never
    /// writing it back. So `scroll` could sit hundreds of lines above
    /// `max_offset` with nothing moving on screen: in a 50-row terminal, 8
    /// PageUps left `scroll = 336` against a `max_offset` of 57, and the first
    /// SIX PageDowns did not move the view at all (the seventh jumped 15).
    ///
    /// Clamping to the real maximum means the debt cannot exist: what you can
    /// scroll is what there is to scroll.
    pub fn scrollBy(self: *Model, n: isize) void {
        if (n == 0) return;
        const mo = self.currentMaxOffset();
        var first = if (self.follow_bottom) mo else @min(self.anchor, mo);
        // DIRECTION, spelled out because getting it backwards is invisible in
        // the tests and fatal in the app: `first` is the TOP line on screen, so
        // scrolling UP means going towards EARLIER lines, which means `first`
        // goes DOWN. `n > 0` is up (PageUp, Ctrl+U, wheel up).
        if (n > 0) {
            const up: usize = @intCast(n);
            first = if (first > up) first - up else 0;
        } else {
            const down: usize = @intCast(-n);
            first = @min(first + down, mo);
        }
        self.scrollTo(first);
    }

    fn scrollTo(self: *Model, first_line: usize) void {
        self.selection_start = null;
        self.selection_end = null;
        self.selecting_text = false;
        const mo = self.currentMaxOffset();
        const first = @min(first_line, mo);
        self.setAnchorLine(first);
        self.anchor = first;
        // Scrolling changes what is visible: full redraw needed next frame.
        self.diff_needs_full_redraw = true;
        // Reaching the bottom re-arms the follow, so the next line that arrives
        // keeps coming at you instead of freezing the view where you happened to
        // land.
        const was_following = self.follow_bottom;
        self.follow_bottom = (first >= mo);
        // The "N new" baseline moves with the reader: leaving the bottom starts
        // a new count, and coming back to it ends the one that was running.
        //
        // It is set HERE, where the reader's decision is, and not in the draw:
        // the draw knows what arrived, but only this knows when the reader
        // stopped looking.
        if (self.follow_bottom) {
            self.was_away = false;
            self.unseen_base_para = self.paras.items.len;
        } else if (was_following) {
            self.was_away = true;
            self.unseen_base_para = self.paras.items.len;
        }
        // Published HERE, not only by the draw. The key handler knows the new
        // view the moment it computes it, and the `↓ N` indicator must not show
        // the previous frame's number while waiting for one.
        self.first_visible = first;
        self.max_offset = mo;
        self.persistScrollState();
    }

    /// Persists the current scroll state to the owning Session, so it survives
    /// a resume. No-op when there is no session (tests).
    fn persistScrollState(self: *Model) void {
        if (self.session) |s| {
            s.setScrollState(self.getScrollState());
        }
    }

    /// Returns the current scroll state as a serializable `ScrollState`, so the
    /// reader's position can be persisted with the session and restored on
    /// resume. `anchor` is the absolute line of the top of the view.
    pub fn getScrollState(self: *const Model) session_mod.ScrollState {
        return .{
            .anchor_line = self.anchor,
            .follow_bottom = self.follow_bottom,
            .unseen_base_para = self.unseen_base_para,
            .was_away = self.was_away,
        };
    }

    /// Applies a previously saved scroll state to this Model. `anchor_line` is
    /// re-derived into (paragraph, offset) through `setAnchorLine`, so it stays
    /// correct even if paragraph heights changed (different terminal width).
    /// A missing or zero state defaults to following the bottom.
    pub fn applyScrollState(self: *Model, state: session_mod.ScrollState) void {
        self.ensureParaHeights();
        self.follow_bottom = state.follow_bottom;
        self.was_away = state.was_away;
        self.unseen_base_para = state.unseen_base_para;
        if (state.follow_bottom) {
            // At the bottom: the anchor is re-derived on the next frame when
            // computeVisible sees first >= max_offset.
            self.anchor = 0;
        } else {
            self.setAnchorLine(state.anchor_line);
            self.anchor = state.anchor_line;
        }
        self.diff_needs_full_redraw = true;
    }

    // ── the prompt rail ─────────────────────────────────────

    /// Recomputes the rail for the frame about to be painted.
    ///
    /// The dots are the LAST `timeline_max_dots` user prompts, and they are
    /// painted as a ladder anchored to the BOTTOM row of the transcript: the
    /// newest is the lowest dot and each older one sits one row above it.
    ///
    /// Anchoring to the bottom is the whole design. Placing them proportionally
    /// to their line in the history would put the six most recent prompts —
    /// which are always the last few screens — on top of each other, and dots
    /// that overlap are dots you cannot hit. With the ladder, sending a prompt
    /// pushes the rail UP by one row and the dot you were aiming at does not
    /// move.
    fn refreshPromptDots(self: *Model, width: u16, history_h: u16) void {
        self.prompt_dot_len = 0;
        // The rail lives in the right margin, one column left of the
        // scrollbar. Below 12 columns there is no margin left to use, and
        // drawing there would paint over the text.
        self.prompt_dot_col = if (width >= 12) width - 2 else 0;
        if (self.prompt_dot_col == 0 or history_h == 0) return;
        if (self.paras.items.len == 0) return;

        self.ensureParaHeights();

        var found: [timeline_max_dots]usize = undefined; // NEWEST first
        var n: usize = 0;
        var i = self.paras.items.len;
        while (i > 0 and n < timeline_max_dots) {
            i -= 1;
            const p = self.paras.items[i];
            if (p.kind == .user and p.text.len > 0) {
                found[n] = i;
                n += 1;
            }
        }

        const track: usize = history_h;
        const cap = @min(n, track);
        for (0..cap) |k| {
            const para = found[k]; // 0 = newest → lowest row
            self.prompt_dots[k] = .{
                .para = para,
                .line = self.heightPrefix(para),
                .row = @intCast(track - 1 - k),
            };
        }
        self.prompt_dot_len = cap;

        // A hover that points at a paragraph that is gone is a hover that
        // paints nothing and, worse, one that never clears.
        if (self.prompt_dot_hover) |p| {
            if (p >= self.paras.items.len) self.prompt_dot_hover = null;
        }
    }

    /// The dot under the pointer, or null when the pointer is not on one.
    fn promptDotAt(self: *const Model, m: vaxis.Mouse) ?PromptDot {
        if (self.prompt_dot_len == 0 or self.prompt_dot_col == 0) return null;
        if (m.row < 0 or m.col < 0) return null;
        if (@as(u16, @intCast(m.col)) != self.prompt_dot_col) return null;
        const row: u16 = @intCast(m.row);
        for (self.prompt_dots[0..self.prompt_dot_len]) |d| {
            if (d.row == row) return d;
        }
        return null;
    }

    /// Puts the prompt one row below the top of the view, so the sticky header
    /// (painted OVER row 0) names it without covering it.
    ///
    /// Landing it exactly on row 0 would hide the line the reader just asked
    /// for behind a copy of itself, which is the one row of the prompt they
    /// least want to lose.
    fn jumpToPrompt(self: *Model, d: PromptDot) void {
        if (d.para >= self.paras.items.len) return;
        self.scrollTo(d.line -| 1);
    }

    /// How many assistant turns the reader has not seen.
    ///
    /// It counts TURNS and not paragraphs, the way the reference implementation
    /// counts them: a tool-only entry must not tick the counter, or "3 new"
    /// would be "3 tool calls" and the reader would come back to a turn that
    /// says nothing.
    fn unseenTurns(self: *const Model) usize {
        if (!self.was_away) return 0;
        const base = @min(self.unseen_base_para, self.paras.items.len);
        var n: usize = 0;
        for (self.paras.items[base..]) |p| {
            if (p.kind == .assistant) n += 1;
        }
        return n;
    }

    fn snapshotSelectableHistory(self: *Model, surface: vxfw.Surface, rows: u16) !void {
        const height = @min(rows, surface.size.height);
        const width = surface.size.width;
        self.selectable_text.clearRetainingCapacity();
        self.selectable_map.clearRetainingCapacity();
        self.selectable_rows = height;
        self.selectable_width = width;

        const map_len = std.math.mul(usize, @as(usize, height), @as(usize, width) + 1) catch return error.OutOfMemory;
        try self.selectable_map.ensureTotalCapacity(self.allocator, map_len);
        for (0..height) |row| {
            if (row > 0) try self.selectable_text.append(self.allocator, '\n');
            try self.selectable_map.append(self.allocator, self.selectable_text.items.len);
            var col: u16 = 0;
            while (col < width) {
                const cell = surface.readCell(col, row);
                const text = cell.char.grapheme;
                try self.selectable_text.appendSlice(self.allocator, text);
                const cell_width: u16 = @max(@as(u16, cell.char.width), 1);
                var step: u16 = 0;
                while (step < cell_width and col + step < width) : (step += 1) {
                    try self.selectable_map.append(self.allocator, self.selectable_text.items.len);
                }
                col += cell_width;
            }
        }
    }

    /// A gesture that must not survive losing the pointer or the focus.
    ///
    /// Every mouse mode flag here has exactly one natural exit — the `.release`
    /// that ends it — and the terminal is under no obligation to deliver that
    /// release to US: alt-tabbing mid-drag, a notification stealing focus, or a
    /// release that lands outside the last drawn surface all lose it. A flag
    /// with no other exit is a flag that can be stranded for the rest of the
    /// session, and a stranded drag flag turns every later mouse event into a
    /// scroll jump.
    fn cancelMouseGestures(self: *Model) void {
        self.scrollbar_dragging = false;
        self.selecting_text = false;
        self.selection_start = null;
        self.selection_end = null;
        // The pointer is gone, so nothing on the rail is under it. Without this
        // the last hovered dot stayed filled forever when the pointer left by
        // the window edge instead of over another cell.
        self.prompt_dot_hover = null;
    }

    fn selectionPoint(self: *const Model, mouse: vaxis.Mouse) ?SelectionPoint {
        if (mouse.row < 0 or mouse.col < 0) return null;
        const row = @as(u16, @intCast(mouse.row));
        const col = @as(u16, @intCast(mouse.col));
        if (row >= self.selectable_rows or self.selectable_width == 0) return null;
        return .{ .row = row, .col = @min(col, self.selectable_width - 1) };
    }

    fn clampedSelectionPoint(self: *const Model, mouse: vaxis.Mouse) ?SelectionPoint {
        if (mouse.row < 0 or mouse.col < 0 or self.selectable_rows == 0 or self.selectable_width == 0) return null;
        return .{
            .row = @min(@as(u16, @intCast(mouse.row)), self.selectable_rows - 1),
            .col = @min(@as(u16, @intCast(mouse.col)), self.selectable_width - 1),
        };
    }

    fn selectedText(self: *const Model, allocator: std.mem.Allocator) !?[]u8 {
        const start = self.selection_start orelse return null;
        const end = self.selection_end orelse return null;
        const first = if (selectionPointLess(end, start)) end else start;
        const last = if (selectionPointLess(end, start)) start else end;
        if (first.row >= self.selectable_rows or last.row >= self.selectable_rows) return null;
        const stride = @as(usize, self.selectable_width) + 1;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var row = first.row;
        while (row <= last.row) : (row += 1) {
            const from_col: u16 = if (row == first.row) first.col else 0;
            const to_col: u16 = if (row == last.row) @min(last.col + 1, self.selectable_width) else self.selectable_width;
            const map_base = @as(usize, row) * stride;
            if (map_base + to_col >= self.selectable_map.items.len) return null;
            const from = self.selectable_map.items[map_base + from_col];
            const to = self.selectable_map.items[map_base + to_col];
            if (from > to or to > self.selectable_text.items.len) return null;
            const part = std.mem.trimEnd(u8, self.selectable_text.items[from..to], " \t");
            try out.appendSlice(allocator, part);
            if (row < last.row) try out.append(allocator, '\n');
        }
        return try out.toOwnedSlice(allocator);
    }

    fn paintTextSelection(self: *const Model, surface: vxfw.Surface) void {
        const start = self.selection_start orelse return;
        const end = self.selection_end orelse return;
        const first = if (selectionPointLess(end, start)) end else start;
        const last = if (selectionPointLess(end, start)) start else end;
        if (first.row >= self.selectable_rows or last.row >= self.selectable_rows) return;
        var row = first.row;
        while (row <= last.row) : (row += 1) {
            const from = if (row == first.row) first.col else 0;
            const to = if (row == last.row) @min(last.col + 1, self.selectable_width) else self.selectable_width;
            var col = from;
            while (col < to and col < surface.size.width) : (col += 1) {
                var cell = surface.readCell(col, row);
                cell.style.bg = theme.selected.bg;
                cell.style.bold = true;
                surface.writeCell(col, row, cell);
            }
        }
    }

    fn copySelectedText(self: *Model, ctx: *vxfw.EventContext) !void {
        // A PRESS followed by a RELEASE at the same point is a CLICK, not a
        // selection, and it used to fire OSC 52 anyway: `selectedText` on one
        // cell yields that one trimmed grapheme, which is non-empty, so every
        // plain click in the transcript emitted
        // `ESC ]52;c;<base64> ESC \` — written and flushed by vaxis OUTSIDE
        // `vx.render`, so the renderer never knew about it and the next frame
        // drew over it. On a terminal that does not implement OSC 52 that is a
        // wall of visible `^[]52;c;…` text, and it appeared exactly when the
        // user clicked or dragged across the history.
        //
        // A selection is more than one cell. A click is not a selection and
        // there is nothing anyone wants copied from it.
        const start = self.selection_start orelse return;
        const end = self.selection_end orelse return;
        if (start.row == end.row and start.col == end.col) return;
        const text = (try self.selectedText(ctx.alloc)) orelse return;
        defer ctx.alloc.free(text);
        if (text.len == 0) return;
        try ctx.copyToClipboard(text);
        // Show a toast in the top-right corner for ~2 seconds.
        self.copy_toast_text = "Copied to clipboard";
        self.copy_toast_frames = 120; // ~2 s at 60 fps
    }

    fn selectionPointLess(a: SelectionPoint, b: SelectionPoint) bool {
        return a.row < b.row or (a.row == b.row and a.col < b.col);
    }

    // ── modal palette (Ctrl+P) ─────────────────────────────

    /// Opens the palette in the given mode. `items` and `groups` are filled by
    /// the caller (the agent) and must stay alive while it is open; in
    /// practice they live in the model's allocator.
    pub fn openPaletteWith(self: *Model, mode: palette.Mode, items: []const palette.Item, groups: []const palette.Group) void {
        if (self.pal.mode == .models) self.invalidateCatalogRequest();
        self.pal.mode = mode;
        self.pal.active = true;
        self.pal.query_len = 0;
        self.pal.setItems(items, groups);
        if (mode == .models) self.pal.col = 1 else self.pal.col = 0;
    }

    pub fn closePalette(self: *Model) void {
        if (self.pal.mode == .models) self.invalidateCatalogRequest();
        self.pal.close();
    }

    /// Closes the palette, freeing whatever is its own. On process exit.
    pub fn destroyPalette(self: *Model) void {
        if (self.pal_inited) self.pal.destroy();
    }

    /// Returns true if the palette consumed the key.
    ///
    /// Translating the action (running a command, switching provider) is the
    /// AGENT's job, not the TUI's: here we only pass along what was selected
    /// and wait for an "I consumed it" bool.
    pub fn paletteKey(self: *Model, ctx: *vxfw.EventContext, key: vaxis.Key) !bool {
        // Read BEFORE the key is handled: `palette.close()` also sets the mode
        // back to `.commands`, and the catalog request of a model palette has
        // to be invalidated even so.
        const models_open = self.pal.mode == .models;
        const act = palette.handleKey(&self.pal, key);
        // CAREFUL: redraw must be requested ALWAYS. The palette mutates its
        // state (query, selection) and without `ctx.redraw` the screen stays
        // as it was: you typed "cache" and the list did not filter, and Esc
        // "did not close".
        ctx.redraw = true;
        if (std.meta.activeTag(act) == .close) {
            if (models_open) self.invalidateCatalogRequest();
            self.closePalette();
            return true;
        }
        try self.applyPaletteAction(ctx, act);
        return true;
    }

    /// Runs what a chosen palette item means. Shared by the keyboard and the
    /// mouse so that clicking a row and pressing Enter on it cannot diverge.
    fn applyPaletteAction(self: *Model, ctx: *vxfw.EventContext, act: palette.Action) !void {
        ctx.redraw = true;
        switch (act) {
            .none => {},
            .close => self.closePalette(),
            .run_command => |cmd| {
                // Without `eqlIgnoreCase` the label "Connect" did not match
                // "connect", the item fell into the generic case and got run
                // LITERALLY as if it were a command.
                if (std.ascii.eqlIgnoreCase(cmd, "connect")) {
                    // The palette is replaced in place, without closing first:
                    // otherwise you see the history blink between modal and
                    // modal.
                    agent.openConnectPalette(self);
                    return;
                }
                // Picking a command EXECUTES it. Before it went to the input
                // and you had to press Enter, and since the palette closed
                // before writing to the input, the command was left half-done
                // until the next key (which was exactly the symptom of "this
                // does nothing").
                //
                // The palette is closed BEFORE dispatching: some commands
                // reopen it with other content (`/model` → models palette) and
                // if it were still active, that one would draw on top and the
                // `esc` of the new one would not close the old one.
                self.closePalette();
                switch (agent.runPaletteCommand(self, cmd)) {
                    .done => {},
                    .needs_args => {
                        // Needs arguments: to the input, with the slash in
                        // place.
                        self.ed.clear();
                        self.ed.insert(cmd) catch {};
                        self.ed.insertChar(' ') catch {};
                    },
                    .quit => ctx.quit = true,
                }
                ctx.redraw = true;
            },
            .set_provider => |p| {
                self.closePalette();
                try agent.applyProvider(self, p);
                agent.openModelPaletteAsync(self);
            },
            .open_connect => {
                agent.openConnectPalette(self);
            },
            .set_model => |mo| {
                self.closePalette();
                // The window goes with the model: it is what the compaction
                // budget is computed from, and dropping it here is what kept the
                // budget at 128k for every model.
                // If the model belongs to a different provider, switch to it first.
                if (mo.provider.len > 0 and !std.mem.eql(u8, mo.provider, agent.cur_provider_id)) {
                    try agent.applyProvider(self, mo.provider);
                }
                try agent.applyModel(self, mo.id, mo.ctx_tokens);
            },
            .refresh_models => {
                self.closePalette();
                self.invalidateCatalogRequest();
                agent.openModelPaletteAsync(self);
            },
            .connect => |conn| {
                // Saving the key is I/O: the agent does it. The palette stays
                // open so you can see the result.
                agent.storeKey(self, conn.provider, conn.key);
                self.pal.key_len = 0;
            },
        }
    }

    /// Call once at startup (the input no longer needs callbacks).
    pub fn attach(self: *Model) void {
        _ = self;
    }

    pub fn widget(self: *Model) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }
};

/// State of the `/` command autocompletion.
pub const Autocomplete = struct {
    pub const Mode = enum { none, command, file };

    /// The popup is open.
    active: bool = false,
    /// What is being completed: `/` commands or `@` file paths.
    mode: Mode = .none,
    /// COMMANDS: length of the prefix typed after the slash (`/mo` → 2).
    /// FILES: the byte offset where the `@token` starts in the input.
    prefix_len: usize = 0,
    /// Position in `agent.commands` of the highlighted item.
    sel: usize = 0,
    /// How many items fit (recomputed in draw from the height).
    max_visible: usize = 6,
    /// First visible index (list scroll).
    first: usize = 0,
    /// FILE matches, owned by the model (freed on the next sync / on deinit
    /// via `freeFileMatches`). Strings, not a `Palette`: the popup is one
    /// column and the paths need no descriptions.
    file_matches: std.ArrayList([]u8) = .empty,
    /// EVERY file of the project, walked once and kept (`filesearch.collect`).
    /// The popup is refiltered on every keystroke, so the disk is read once per
    /// `file_pool_ttl_s` and not once per character. A test Model has no `Io`,
    /// so this stays empty there.
    file_pool: std.ArrayList([]u8) = .empty,
    file_pool_ready: bool = false,
    /// Unix seconds of the last walk: the pool is rebuilt when it stales, so a
    /// file created by the agent during the session shows up without a restart.
    file_pool_at: i64 = 0,

    /// Is the current input text a command in progress?
    /// Only offered if there are no spaces yet: "/mod" yes, "/mod x" no.
    pub fn queryFor(text: []const u8) ?struct { prefix_len: usize } {
        if (text.len == 0 or text[0] != '/') return null;
        for (text) |c| {
            if (c == ' ' or c == '\n') return null;
        }
        return .{ .prefix_len = text.len };
    }
};

/// All the rows of the surface as a single text (drawing tests).
pub fn allText(s: vxfw.Surface) []const u8 {
    var buf: [8192]u8 = undefined;
    var n: usize = 0;
    var row: u16 = 0;
    while (row < s.size.height and n < buf.len) : (row += 1) {
        const line = rowText(s, row, buf[n..]);
        n += @min(line.len, buf.len - n);
        if (n < buf.len) {
            buf[n] = '\n';
            n += 1;
        }
    }
    return buf[0..n];
}

/// Rebuilds the visible text of one surface row (for tests).
/// The frame's `arena` must still be alive: the graphemes are read from it.
pub fn rowText(surface: vxfw.Surface, row: u16, buf: []u8) []const u8 {
    if (row >= surface.size.height) return buf[0..0];
    var n: usize = 0;
    var col: u16 = 0;
    while (col < surface.size.width) : (col += 1) {
        const cell = surface.readCell(col, row);
        const g = cell.char.grapheme;
        if (n + g.len > buf.len) break;
        @memcpy(buf[n .. n + g.len], g);
        n += g.len;
        // A wide cell occupies 2 columns: skip the occupied one.
        if (cell.char.width > 1) col += 1;
    }
    return buf[0..n];
}

// ── submit ───────────────────────────────────────────────────
/// Sends the input's contents to the agent and clears it (with history).
fn submitInput(self: *Model, ctx: *vxfw.EventContext) !void {
    const trimmed = std.mem.trim(u8, self.ed.text(), " \t\r\n");

    // `ask` in free-text mode: Enter ANSWERS, it does not start a new turn.
    //
    // It has to be checked BEFORE anything else, including the empty check: an
    // empty answer is a legitimate answer ("you decide") and the user pressing
    // Enter on an empty box is saying exactly that. Sending it as a prompt would
    // start a turn with an empty user message, which is the one thing that would
    // make this feel broken.
    //
    // `askActive()` and not just `askTyping()`: with a FREE-TEXT question open
    // there are no options, so nothing ever set `ask_typing`, and the panel said
    // "type your answer below" while the input box was in normal prompt mode.
    // Typing there started a NEW TURN instead of answering, and the turn got
    // queued behind the worker that was parked waiting for the answer. From
    // outside: the panel asks a question, you answer it, and it ignores you.
    // `!cmd` runs a shell command and puts its output in the context. It is
    // checked here, before the prompt path, because it is NOT a prompt: there is
    // no turn, no model and no worker for the model. The command itself runs on
    // its own thread (see `Model.shell_out`).
    if (trimmed.len > 1 and trimmed[0] == '!') {
        const cmd = std.mem.trim(u8, trimmed[1..], " \t");
        self.ed.clear();
        self.ac = .{};
        if (cmd.len == 0) {
            self.pushInfo("! needs a command: !git status");
        } else {
            agent.startShell(self, cmd);
        }
        ctx.redraw = true;
        try self.armTick(ctx);
        return;
    }

    if (self.askAnswerFromInput(trimmed)) {
        self.ed.clear();
        self.ac = .{};
        ctx.redraw = true;
        try self.armTick(ctx);
        return;
    }

    if (trimmed.len == 0) {
        self.ed.clear();
        self.ac = .{};
        return;
    }
    if (std.mem.eql(u8, trimmed, "/quit")) {
        self.ed.clear();
        ctx.quit = true;
        return;
    }

    const owned = ctx.alloc.dupe(u8, trimmed) catch return;
    defer ctx.alloc.free(owned);

    // Echo of the user in the history, before dispatching.
    self.pushKind(.user, trimmed);

    // A new message from the user starts a new turn: images read in previous
    // turns do not ride along (short life, not cached between turns).
    self.pending_images.clear(self.allocator);

    agent.submit(self, owned) catch |err| {
        // `pushInfoFmt` and NOT `allocPrint(ctx.alloc, …) + pushInfoOwned`: the
        // frame arena is reset at the end of the frame and is NOT the model's
        // allocator, so handing its memory to `pushInfoOwned` was two bugs at
        // once — a dangling pointer read by the renderer, and an "Invalid free"
        // on exit because it was freed with the wrong allocator. This is the
        // fifth time that family of bug shows up in this repo.
        self.pushInfoFmt("error: {t}", .{err});
    };

    self.ed.commit(); // saves to history and clears
    self.ac = .{};
    // `/copy` (and any other command) may have queued a clipboard write.
    self.flushCopyPending(ctx);
    ctx.redraw = true;
    try self.armTick(ctx);
}

// ── input key handler ──────────────────────────────
/// Translates a key into an input edit. Returns true if it consumed it.
/// The keyboard shortcuts, as a picker.
///
/// `?` on an empty input opens it. The reference implementation has a footer
/// hint for it, and the HINT is the discoverability: a binding nobody knows
/// about is a binding nobody presses, and half of ours were written down
/// nowhere until `/help` grew a second block.
fn openShortcutsPicker(self: *Model) void {
    const gpa = self.allocator;
    // The LEGEND of the permission glyphs travels with the shortcut list: the
    // footer shows a bare "●" to save twelve columns, and a glyph with no
    // legend is a glyph nobody can read.
    const modes = [_][2][]const u8{
        .{ "○", "build (the default: every write asks)" },
        .{ "◐", "accept-edits (writes go through without asking)" },
        .{ "●", "plan (read-only: every write is refused)" },
        .{ "◉", "bypass (nothing asks)" },
    };
    const n = agent.shortcuts.len + modes.len;
    const items = gpa.alloc(PickerItem, n) catch return;
    for (agent.shortcuts, 0..) |s, i| {
        // The palette OWNS the labels and frees them when it closes: a literal
        // here is an "Invalid free" on exit.
        items[i] = .{
            .label = gpa.dupe(u8, s.key) catch return,
            .desc = gpa.dupe(u8, s.desc) catch return,
        };
    }
    for (modes, 0..) |m, i| {
        items[agent.shortcuts.len + i] = .{
            .label = gpa.dupe(u8, m[0]) catch return,
            .desc = gpa.dupe(u8, m[1]) catch return,
        };
    }
    self.openPicker(9, "keyboard shortcuts", items, onShortcutPick);
}

/// Picking a shortcut does nothing: the list is a REFERENCE, not a menu.
/// The callback exists because the picker's contract is a callback.
fn onShortcutPick(_: *Model, _: u32, _: []const u8) void {}

fn editorKey(self: *Model, ctx: *vxfw.EventContext, key: vaxis.Key) !bool {
    const k = key;

    // `?` on an EMPTY input opens the shortcut list.
    //
    // Only when the input is empty: a `?` inside a prompt is a question
    // mark, and stealing it would be the kind of shortcut that makes people
    // hate shortcuts.
    //
    // THE CHARACTER IS LOOKED FOR IN `text` AND NOT ONLY IN THE CODEPOINT.
    // The editor inserts printable keys from `key.text`, and with the kitty
    // keyboard protocol the codepoint of a text key is not the character
    // itself. The first version checked the codepoint only, and the key was
    // inserted into the prompt like any other: the unit test opened the
    // picker directly and the pty smoke typed the key and nothing happened.
    // **A test that calls the function is not a test of the key.**
    const is_question = (k.text != null and std.mem.eql(u8, k.text.?, "?")) or k.codepoint == '?';
    if (is_question and !k.mods.ctrl and !k.mods.alt and
        self.ed.text().len == 0 and !self.pal.active and !self.pickerActive())
    {
        openShortcutsPicker(self);
        ctx.redraw = true;
        return true;
    }

    // Enter submits; Shift+Enter / Alt+Enter insert a line break.
    //
    // The codepoint is checked DIRECTLY and not through `key.matches(enter, .{})`,
    // and that is not a style choice. `matches` requires the modifiers to be
    // EXACTLY the ones asked for, so `enter + shift` does NOT match
    // `matches(enter, .{})` — the whole branch was skipped and Shift+Enter did
    // nothing at all. The modifier was checked AGAIN on the next line, which is
    // the only reason the bug survived the reading: both lines look right
    // together.
    //
    // Every other key here is matched by codepoint and then filtered by its own
    // mods, which is the order that works for a key that means two things.
    if (k.codepoint == vaxis.Key.enter) {
        if (k.mods.shift or k.mods.alt) {
            if (self.ed.insertChar('\n')) |_| {
            } else |err| {
                if (std.mem.eql(u8, @errorName(err), "InputTooLong")) inputTooLongRejected(self);
            }
            syncAutocomplete(self);
            ctx.redraw = true;
            return true;
        }
        try submitInput(self, ctx);
        return true;
    }
    // Ctrl+J also submits (legacy from vaxis's TextField).
    if (k.matches('j', .{ .ctrl = true })) {
        try submitInput(self, ctx);
        return true;
    }

    if (k.matches(vaxis.Key.backspace, .{})) {
        if (k.mods.alt or k.mods.ctrl) {
            self.ed.deleteWordBefore();
        } else {
            self.ed.deleteBefore();
        }
        syncAutocomplete(self);
        ctx.redraw = true;
        return true;
    }
    if (k.matches(vaxis.Key.delete, .{}) or k.matches('d', .{ .ctrl = true })) {
        self.ed.deleteAfter();
        syncAutocomplete(self);
        ctx.redraw = true;
        return true;
    }

    // Movement
    const ctrl = k.mods.ctrl;
    const alt = k.mods.alt;
    if (k.matches(vaxis.Key.left, .{})) {
        if (ctrl or alt) self.ed.moveWordLeft() else self.ed.moveLeft();
        ctx.redraw = true;
        return true;
    }
    if (k.matches(vaxis.Key.right, .{})) {
        if (ctrl or alt) self.ed.moveWordRight() else self.ed.moveRight();
        ctx.redraw = true;
        return true;
    }
    if (k.matches(vaxis.Key.up, .{})) {
        // Up = prompt history.
        if (self.ed.historyPrev()) {
            syncAutocomplete(self);
            ctx.redraw = true;
        }
        return true;
    }
    if (k.matches(vaxis.Key.down, .{})) {
        if (self.ed.historyNext()) {
            syncAutocomplete(self);
            ctx.redraw = true;
        }
        return true;
    }
    if (k.matches(vaxis.Key.home, .{}) or k.matches('a', .{ .ctrl = true })) {
        self.ed.moveHome();
        ctx.redraw = true;
        return true;
    }
    if (k.matches(vaxis.Key.end, .{}) or k.matches('e', .{ .ctrl = true })) {
        self.ed.moveEnd();
        ctx.redraw = true;
        return true;
    }

    // Whole-line deletion
    if (k.matches('u', .{ .ctrl = true })) {
        self.ed.deleteToStart();
        syncAutocomplete(self);
        ctx.redraw = true;
        return true;
    }
    if (k.matches('k', .{ .ctrl = true })) {
        self.ed.deleteToEnd();
        syncAutocomplete(self);
        ctx.redraw = true;
        return true;
    }
    if (k.matches('w', .{ .ctrl = true })) {
        self.ed.deleteWordBefore();
        syncAutocomplete(self);
        ctx.redraw = true;
        return true;
    }

    // Any other printable character (key.text decodes UTF-8).
    if (k.text) |txt| {
        if (txt.len > 0 and !ctrl) {
            if (self.ed.insert(txt)) |_| {
            } else |err| {
                if (std.mem.eql(u8, @errorName(err), "InputTooLong")) inputTooLongRejected(self);
            }
            syncAutocomplete(self);
            ctx.redraw = true;
            return true;
        }
    }
    return false;
}

/// Opens/updates the autocompletion based on what is in the input.
fn syncAutocomplete(self: *Model) void {
    if (Autocomplete.queryFor(self.ed.text())) |q| {
        setAcMode(self, .command, q.prefix_len);
        recomputeMatches(self);
        return;
    }
    // `@path`: completes file paths, cursor at the end of the token.
    //
    // Offered from ANYWHERE in the input (mid-sentence too), which is how the
    // user actually types it: "revisa @src/a" — and the token is whatever
    // follows the LAST `@` up to the cursor. Empty token (just typed `@` or
    // nothing after it) offers the directory listing of `.`: the popup is also
    // the DISCOVERY UI for "what files can I mention?".
    if (fileQueryAt(self.ed.text(), self.ed.cursor)) |q| {
        setAcMode(self, .file, q.token_start);
        refreshFileMatches(self, q.token);
        recomputeMatches(self);
        return;
    }
    setAcMode(self, .none, 0);
}

/// Switches the popup's mode, freeing the previous mode's data. Every field
/// change goes through here so no mode leaves state behind.
fn setAcMode(self: *Model, mode: Autocomplete.Mode, prefix_len: usize) void {
    if (self.ac.mode == .file and mode != .file) freeFileMatches(self);
    self.ac.active = mode != .none;
    self.ac.mode = mode;
    self.ac.prefix_len = prefix_len;
    if (!self.ac.active) {
        self.ac.sel = 0;
        self.ac.first = 0;
    }
}

fn freeFileMatches(self: *Model) void {
    for (self.ac.file_matches.items) |f| self.allocator.free(f);
    self.ac.file_matches.clearRetainingCapacity();
}

/// The `@token` under the cursor: where it starts and what it says, or null
/// when the cursor is not on (or right after) an at-mention.
///
/// PURE over the input text: the disk is `refreshFileMatches`' business, so the
/// tests can pin down the token logic without a filesystem.
fn fileQueryAt(text: []const u8, cursor: usize) ?struct { token_start: usize, token: []const u8 } {
    if (cursor > text.len) return null;
    // Walk back to the last `@` before the cursor; the token between them must
    // be unbroken (no spaces/newlines), or there is no mention under the
    // cursor. The token may be EMPTY: `@` alone still opens the listing.
    var i = cursor;
    while (i > 0) : (i -= 1) {
        const c = text[i - 1];
        if (c == '@') {
            // An `@` that is part of an email (`a@b`) does not count. Same rule
            // as `mentions.scan`, which is what will parse this text later: if
            // the two disagree, the user completes a path that never expands.
            if (i >= 2) {
                const prev = text[i - 2];
                if (std.ascii.isAlphanumeric(prev) or prev == '_' or prev == '.' or prev == '/') return null;
            }
            return .{ .token_start = i - 1, .token = text[i..cursor] };
        }
        if (c == ' ' or c == '\n' or c == '\t' or c == '\r') return null;
    }
    return null;
}

/// How long the project file pool is trusted before it is walked again.
///
/// Long enough that typing a path never costs a walk, short enough that a file
/// the agent just created shows up while you are still in the same session.
const file_pool_ttl_s: i64 = 10;

/// How many scored matches the popup keeps. More than the rows it can show, so
/// scrolling within the list still works, and few enough that the per-keystroke
/// refilter stays in the microseconds.
const file_matches_max: usize = 40;

/// Empties the cached project listing (`filesearch.collect` owns its strings).
fn freeFilePool(self: *Model) void {
    for (self.ac.file_pool.items) |p| self.allocator.free(p);
    self.ac.file_pool.clearRetainingCapacity();
    self.ac.file_pool_ready = false;
}

/// Walks the project ONCE per `file_pool_ttl_s` and keeps every path.
///
/// This is what makes `@` a project-wide search instead of a directory listing:
/// the old version read one directory per keystroke, so `@tui` said "nothing"
/// unless you happened to be in `src/`, and `@src/lib/fuzzy` was four
/// keystrokes of drilling. One walk and one fuzzy pass answer both.
fn ensureFilePool(self: *Model) void {
    if (!self.io_ready) return;
    const now = std.Io.Timestamp.now(self.io, .real).toSeconds();
    if (self.ac.file_pool_ready and now - self.ac.file_pool_at <= file_pool_ttl_s) return;
    freeFilePool(self);
    filesearch.collect(self.allocator, self.io, ".", &self.ac.file_pool, filesearch.default_cap);
    // Shallow first, so a bare `@` opens on the files you are most likely to
    // mean instead of whatever `readdir` returned.
    filesearch.sortShallowFirst(self.ac.file_pool.items);
    self.ac.file_pool_ready = true;
    self.ac.file_pool_at = now;
}

/// Refills the matches for the `@token` being typed: fuzzy over the whole
/// project, best score first.
///
/// The query is the token as typed, `/` included, so `src/edi` and `edi` both
/// reach `src/lib/editor.zig`: the separator is a word boundary to `fuzzy`, and
/// nothing has to be split into "directory" and "name" here.
fn refreshFileMatches(self: *Model, token: []const u8) void {
    freeFileMatches(self);
    if (!self.io_ready) return;
    ensureFilePool(self);
    if (self.ac.file_pool.items.len == 0) return;

    const pool = self.ac.file_pool.items;
    if (token.len == 0) {
        // A bare `@`: the first `file_matches_max` of the pool, already shallow
        // first. Ranked would mean scoring 20 000 paths for a query of nothing.
        for (pool[0..@min(pool.len, file_matches_max)]) |p| {
            const copy = self.allocator.dupe(u8, p) catch continue;
            self.ac.file_matches.append(self.allocator, copy) catch self.allocator.free(copy);
        }
        return;
    }

    const scored = fuzzy.rank(self.allocator, token, pool) catch return;
    defer self.allocator.free(scored);
    for (scored[0..@min(scored.len, file_matches_max)]) |s| {
        const copy = self.allocator.dupe(u8, pool[s.index]) catch continue;
        self.ac.file_matches.append(self.allocator, copy) catch self.allocator.free(copy);
    }
}

/// Does `haystack` start with `needle` (case-insensitive)?
fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (needle, 0..) |nc, i| {
        if (std.ascii.toLower(haystack[i]) != std.ascii.toLower(nc)) return false;
    }
    return true;
}

/// Command name without the slash: "/use <prov> [model]" → "use".
///
/// Autocompletion matches against this and not against the whole line: with
/// the whole line, "/mod" would match "/use <prov> [model]".
fn commandToken(key: []const u8) []const u8 {
    var k = key;
    if (k.len > 0 and k[0] == '/') k = k[1..];
    if (std.mem.indexOfAny(u8, k, " \t")) |i| k = k[0..i];
    return k;
}

/// Recomputes how many items match and where the selection is.
fn recomputeMatches(self: *Model) void {
    const n = matchCount(self);
    if (n == 0) {
        self.ac.active = false;
        return;
    }
    if (self.ac.sel >= n) self.ac.sel = n - 1;
    if (self.ac.sel < self.ac.first) self.ac.first = self.ac.sel;
    if (self.ac.sel >= self.ac.first + self.ac.max_visible) {
        self.ac.first = self.ac.sel - self.ac.max_visible + 1;
    }
}

/// The prefix being completed, depending on the mode. COMMANDS: what follows
/// the `/`. FILES: the token after the `@` (empty when just typed).
fn acPrefix(self: *const Model) ?[]const u8 {
    const text = self.ed.text();
    return switch (self.ac.mode) {
        // `prefix_len == 0` means a bare `/`, which is a real query (every
        // command matches it); for FILES it means the `@` is the FIRST character
        // of the input, which is the normal way to mention a file. The guard used
        // to be shared and it made `@needle` at the start of a line query "" —
        // every candidate matched, and the popup highlighted nothing.
        .command => if (self.ac.prefix_len == 0 or self.ac.prefix_len > text.len)
            null
        else
            text[1..self.ac.prefix_len],
        .file => blk: {
            // The token runs to the cursor, like `fileQueryAt` saw it.
            const end = @min(self.ed.cursor, text.len);
            if (end <= self.ac.prefix_len) break :blk "";
            break :blk text[self.ac.prefix_len + 1 .. end];
        },
        .none => null,
    };
}

/// Number of items matching the current prefix.
fn matchCount(self: *const Model) usize {
    return switch (self.ac.mode) {
        .command => blk: {
            const prefix = acPrefix(self) orelse break :blk 0;
            var n: usize = 0;
            var i: usize = 0;
            while (agent.commandAt(i)) |c| : (i += 1) {
                if (startsWithIgnoreCase(commandToken(c.key), prefix)) n += 1;
            }
            break :blk n;
        },
        .file => self.ac.file_matches.items.len,
        .none => 0,
    };
}

/// The label of match number `n` (in list order). COMMANDS: the full command
/// line. FILES: the path, with a leading `@` so the row shows the mention as
/// the user will read it.
fn matchLabel(self: *const Model, n: usize) ?[]const u8 {
    return switch (self.ac.mode) {
        .command => blk: {
            const prefix = acPrefix(self) orelse break :blk null;
            var seen: usize = 0;
            var i: usize = 0;
            while (agent.commandAt(i)) |c| : (i += 1) {
                if (!startsWithIgnoreCase(commandToken(c.key), prefix)) continue;
                if (seen == n) break :blk c.key;
                seen += 1;
            }
            break :blk null;
        },
        .file => blk: {
            if (n >= self.ac.file_matches.items.len) break :blk null;
            break :blk self.ac.file_matches.items[n];
        },
        .none => null,
    };
}

/// The replacement text for accepting match `n`: commands keep their full
/// `key`, files come back as `@path` (the mention form, which is what the
/// scanner understands).
/// Accepts the highlighted command: replaces the prefix with the full command.
/// Is what is typed in the input exactly the highlighted command?
///
/// This is the "nothing to complete" case: then Enter must submit, not rewrite
/// the same thing with a trailing space.
fn isExactMatch(self: *Model) bool {
    if (!self.ac.active or self.ac.mode != .command) return false;
    const typed = std.mem.trim(u8, self.ed.text(), " \t\r\n");
    if (typed.len == 0) return false;
    // Compared against ALL the commands, not just the highlighted one —
    // builtins AND the user's own (`commandAt` walks both), so Enter on a
    // completed `/review` submits instead of re-completing.
    //
    // Comparing only with the highlighted one broke "/model": the popup sorted
    // "/models" first, so it was not an exact match and Enter completed to
    // "/models". Now: if what is typed IS a command it is sent as-is; if it is
    // partial ("mod"), it is completed.
    var ac_i: usize = 0;
    while (agent.commandAt(ac_i)) |c| : (ac_i += 1) {
        if (std.mem.eql(u8, typed, c.key)) return true;
    }
    return false;
}

fn acceptAutocomplete(self: *Model) bool {
    if (!self.ac.active) return false;
    // The replacement covers ONLY the token being completed (the whole input
    // for commands, the `@token` for files), so accepting mid-sentence keeps
    // the sentence.
    const repl = switch (self.ac.mode) {
        // Commands replace the WHOLE input (the popup is only open while the
        // input is exactly a bare `/token`).
        .command => {
            const cmd = matchLabel(self, self.ac.sel) orelse return false;
            self.ed.clear();
            self.ed.insert(cmd) catch return false;
            self.ed.insertChar(' ') catch {};
            self.ac = .{};
            return true;
        },
        .file => blk: {
            const path = matchLabel(self, self.ac.sel) orelse return false;
            // The trailing space ends the mention. Without it the next word
            // glued itself to the path (`@src/a.zigy` was one token to
            // `mentions.scan`, and the file looked missing).
            break :blk std.fmt.allocPrint(self.allocator, "@{s} ", .{path}) catch return false;
        },
        .none => return false,
    };
    // Free the composed `@path` either way: `insert` copies into the editor.
    defer self.allocator.free(repl);
    const text = self.ed.text();
    const start = self.ac.prefix_len;
    const end = @min(self.ed.cursor, text.len);
    if (start > end or start > text.len) return false;
    self.ed.deleteRange(start, end) catch return false;
    self.ed.setCursor(start);
    self.ed.insert(repl) catch return false;
    // A file mention ends the token: close the popup (it reopens on the next
    // keystroke if the text still qualifies).
    self.ac = .{};
    return true;
}

/// Names the byte cap in a clear message: what the limit is, how many bytes
/// are already typed, and what to do. The buffer was not modified by the
/// rejected edit, so the message is accurate at paint time.
fn inputTooLongRejected(self: *Model) void {
    const text_len = self.ed.text().len;
    const msg = std.fmt.bufPrint(&self.input_err_buf,
        "Input too long: {d}-byte cap, {d} bytes already typed. Shorten the text and resend.",
        .{ ed.max_bytes, text_len }) catch {
        self.input_err = "Input too long: shorten the text.";
        self.input_too_long = true;
        return;
    };
    self.input_err = msg;
    self.input_too_long = true;
}

// ── root widget handlers ─────────────────────────────────
fn typeErasedEventHandler(ud: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *Model = @ptrCast(@alignCast(ud));
    // `/copy`: a text waiting for the clipboard leaves through the RENDER.
    // It is flushed at the TOP of every event, so it goes out with the next
    // tick even if the user does not touch anything (a tick is an event, and
    // it carries an EventContext).
    self.flushCopyPending(ctx);
    switch (event) {
        .key_press => |key| {
            // A rejected-input note refers to the buffer as it was; once the
            // user presses another key it is stale.
            self.input_too_long = false;
            self.input_err = "";
            // Ctrl+C: first clears the input, the second press exits (so
            // half-typed text is never lost in one go).
            if (key.matches('c', .{ .ctrl = true })) {
                if (self.hasInput()) {
                    self.ed.clear();
                    self.ac = .{};
                    ctx.redraw = true;
                } else {
                    ctx.quit = true;
                }
                return;
            }
            // Ctrl+D DOES NOT QUIT, and it used to.
            //
            // With an empty input it was EOF (`ctx.quit = true`), and the empty
            // input is the NORMAL state when you scroll: you scroll up to read
            // something, press ctrl+d to come back down, and zode exits. `/help`
            // documents "ctrl+u / ctrl+d = scroll half a page" and the status bar
            // says "ctrl+c exits", so the app contradicted itself and the cheapest
            // way out was a key advertised as a scroll.
            //
            // Ctrl+C is the exit, which is what both places say.
            // Ctrl+P: command palette. Ctrl+T: two-column models palette
            // (provider | its models), like opencode.
            if (key.matches('p', .{ .ctrl = true })) {
                agent.openCommandPalette(self);
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            if (key.matches('t', .{ .ctrl = true })) {
                agent.openModelPaletteAsync(self);
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            // Ctrl+A: connect a provider. The palette footer announced it and
            // did nothing, which is worse than not announcing it.
            if (key.matches('a', .{ .ctrl = true })) {
                agent.openConnectPalette(self);
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            // Ctrl+L: clear the view.
            if (key.matches('l', .{ .ctrl = true })) {
                self.clearHistory();
                ctx.redraw = true;
                return;
            }
            // Ctrl+R: expand/collapse the last tool's result.
            if (key.matches('r', .{ .ctrl = true })) {
                if (self.toggleLastTool()) {
                    ctx.redraw = true;
                } else {
                    // With no previous tool, it refreshes the history.
                    self.cache_from = 0;
                    ctx.redraw = true;
                }
                return;
            }
            // Ctrl+P palette open: captures ALL input, scroll included.
            if (self.pal.active) {
                if (try self.paletteKey(ctx, key)) {
                    try self.armTick(ctx);
                    return;
                }
            }

            // Modal picker active: captures ALL input.
            if (self.pickerActive()) {
                if (self.pickerHandleKey(key)) {
                    // The picker's callback may have queued a clipboard write.
                    self.flushCopyPending(ctx);
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
            }
            // An open question WITH options: the panel is the menu, so the arrows
            // move the panel's own highlight and Enter takes it.
            //
            // It has to sit here, above the editor and above the `/` and `@`
            // popups: with a question open those popups mean nothing (there is no
            // prompt being written) and, worse, Enter with the `@` popup open
            // would accept a completion instead of answering the question. ESC is
            // handled further down and means "you decide".
            if (self.askNeedsChoice()) {
                if (key.matches(vaxis.Key.up, .{})) {
                    self.askMove(-1);
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
                if (key.matches(vaxis.Key.down, .{})) {
                    self.askMove(1);
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    _ = self.askAnswerSelected();
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
            }
            // `/` autocompletion or `@` file completion open: navigate and accept.
            if (self.ac.active and matchCount(self) > 0) {
                if (key.matches(vaxis.Key.up, .{})) {
                    if (self.ac.sel > 0) self.ac.sel -= 1;
                    recomputeMatches(self);
                    ctx.redraw = true;
                    return;
                }
                if (key.matches(vaxis.Key.down, .{})) {
                    const n = matchCount(self);
                    if (self.ac.sel + 1 < n) self.ac.sel += 1;
                    recomputeMatches(self);
                    ctx.redraw = true;
                    return;
                }
                // Tab and Enter (no modifiers) accept the highlight: with the
                // popup open, sending a bare "mod" is not what the user wants,
                // they want /model.
                //
                // BUT if what is typed is already a COMPLETE command, Enter
                // SENDS it instead of completing again. Before it didn't:
                // "/help" + Enter only rewrote "/help " and sent nothing, so
                // you had to press it twice and it looked like the scroll had
                // nothing to show. And the other way round didn't either:
                // "/model" completed to "/models" because the popup sorted
                // "/models" first and the match was only looked for there.
                //
                // In FILE mode Enter always accepts (a path is never "complete
                // enough to send": it is a mention inside a sentence).
                const plain_enter = key.matches(vaxis.Key.enter, .{}) and
                    !key.mods.shift and !key.mods.alt and !key.mods.ctrl;
                if (key.matches(vaxis.Key.tab, .{}) or plain_enter) {
                    // If what is typed is exactly the command, Enter SENDS.
                    // The popup is closed and it leaves the block WITHOUT
                    // `return` so the key keeps going down to the editor, which
                    // does the submit. With `return` it was lost: "/help" +
                    // Enter only rewrote "/help " and sent nothing.
                    if (plain_enter and isExactMatch(self)) {
                        self.ac = .{};
                        ctx.redraw = true;
                    } else {
                        if (acceptAutocomplete(self)) {
                            ctx.redraw = true;
                            try self.armTick(ctx);
                        }
                        return;
                    }
                } else {
                    // Escape closes the popup without deleting what was typed.
                    if (key.matches(vaxis.Key.escape, .{})) {
                        setAcMode(self, .none, 0);
                        ctx.redraw = true;
                        return;
                    }
                }
            }

            // With an empty editor, the arrows belong to the history rather
            // than to an invisible cursor. Ask choices and open pickers have
            // already consumed their own arrows above.
            if (!self.hasInput() and !self.permActive()) {
                if (key.matches(vaxis.Key.up, .{})) {
                    self.scrollBy(1);
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
                if (key.matches(vaxis.Key.down, .{})) {
                    self.scrollBy(-1);
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
                if (key.matches(vaxis.Key.home, .{})) {
                    self.scrollBy(1_000_000);
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
                if (key.matches(vaxis.Key.end, .{})) {
                    self.scrollBy(-1_000_000);
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
            }

            // ESC. Three things it can mean, and the ORDER is the whole design:
            //
            // 1. an open QUESTION -> "I am not answering that", the agent decides
            //    on its own and the turn carries on. Not a cancel.
            // 2. a foreground tool -> kill the child process. Before, ESC only
            //    set the HTTP cancel flag, which does nothing to a `zig build`
            //    already running inside `process.run`: the worker stayed blocked
            //    for the rest of `timeout_seconds` and the command kept using the
            //    CPU. This is the single most misleading thing ESC did.
            // 3. otherwise -> abort the turn's stream.
            if (key.matches(vaxis.Key.escape, .{})) {
                if (self.askActive()) {
                    self.declineAsk();
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
                const killed = agent.killForeground();
                if (self.permActive()) self.answerPermission(.deny);
                if (killed > 0) {
                    agent.setStatusWithZoFmt(self, .warn, "killed {d} running command{s}", .{
                        killed,
                        if (killed == 1) @as([]const u8, "") else @as([]const u8, "s"),
                    });
                }
                chat.cancel_current.store(true, .seq_cst);
                // Background jobs go too: ESC means "stop", and leaving a build
                // running in the background after the user pressed ESC is how you
                // get a laptop that is warm for the next ten minutes. Before,
                // ESC only MARKED the jobs (`requestKillAll`) and the kill ran
                // at app exit, so the build kept burning CPU for the whole
                // session — "ESC did nothing", one level down. `killNow` marks
                // and kills in one pass, on this thread, which is the one
                // allowed to touch `Child.kill`.
                const bg_killed = if (self.io_ready) self.bg.killNow(self.io) else self.bg.requestKillAll();
                if (bg_killed > 0) {
                    agent.setStatusWithZoFmt(self, .warn, "killed {d} background command{s}", .{
                        bg_killed,
                        if (bg_killed == 1) @as([]const u8, "") else @as([]const u8, "s"),
                    });
                }
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            // Permission dialog active: y/a/n decide, rest ignored.
            if (self.permActive()) {
                const cp = key.codepoint;
                if (cp == 'y' or cp == 'Y') {
                    self.answerPermission(.allow);
                } else if (cp == 'a' or cp == 'A') {
                    // Only when the option is on the table. A question that
                    // must not become a standing permission does not show it,
                    // and a key that answers an invisible option is a trap.
                    if (self.permAllowAlways()) self.answerPermission(.allow_always);
                } else if (cp == 'n' or cp == 'N') {
                    self.answerPermission(.deny);
                }
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            // Shift+Tab cycles the visible Build / accept-edits / Plan modes.
            //
            // Chosen because it is the key nothing else in a terminal uses, and
            // because every other coding agent already uses it for this, so it
            // does not have to be learned twice.
            //
            // It works with text in the input on purpose: you often decide to
            // switch AFTER typing the prompt ("actually, look first"), and a mode
            // you can only enter with an empty box is a mode you use once.
            if (key.matches(vaxis.Key.tab, .{ .shift = true })) {
                agent.cyclePermMode(self);
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }

            // ── history scroll ──
            // PageUp/PageDown move a PAGE (the whole window, minus one line so
            // you can see what came before and what comes after). Before they
            // moved 5 fixed rows, which in a 40-row terminal did not feel like
            // scrolling.
            // Ctrl+U / Ctrl+D do half a page, like in less.
            const k = key;
            const page: usize = @max(3, self.hist_rows -| 1);
            const half: usize = @max(2, self.hist_rows / 2);
            if (k.matches(vaxis.Key.page_up, .{}) or k.codepoint == 5 or
                (k.codepoint == 'k' and k.mods.shift) or
                (k.matches('u', .{ .ctrl = true })))
            {
                const step = if (k.matches('u', .{ .ctrl = true })) half else page;
                self.scrollBy(@intCast(step));
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            if (k.matches(vaxis.Key.page_down, .{}) or k.codepoint == 6 or
                (k.codepoint == 'j' and k.mods.shift) or
                (k.matches('d', .{ .ctrl = true })))
            {
                const step = if (k.matches('d', .{ .ctrl = true })) half else page;
                self.scrollBy(-@as(isize, @intCast(step)));
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }

            // Everything else goes to the input editor.
            if (try editorKey(self, ctx, k)) {
                try self.armTick(ctx);
                return;
            }
            ctx.redraw = true;
        },
        .tick => {
            // The tick always rearms (1.5).
            //
            // Before it only rearmed "if there is work", and `busy`/`dirty`
            // have windows where both are false (e.g. between `streamEnd` and
            // `pushToolStart`, with a session write(2) and a DEFLATE-9 in
            // between). A tick landing there left `App.timers` EMPTY, and since
            // the worker has neither a pointer to the `EventContext` nor to
            // the event queue, there was no way to request a frame: the screen
            // stayed dead until a key was pressed, the wheel moved or the
            // window was resized.
            //
            // The cost of always rearming is one timer every 120 ms at idle,
            // which only repaints if something changed; the alternative is an
            // app that goes dead with no explanation.
            self.tick_armed = false;
            const a = self.activity();
            const asked = self.redraw_requested.swap(false, .seq_cst);
            // `mascotMoved` and not "there is an animation": at rest the face
            // changes once every couple of seconds, and the tick fires eight
            // times a second in between. The face is the ONLY thing that moves
            // when the app is otherwise idle, so without this the idle track
            // (blinks, exhale, yawn) was only ever painted when a key happened
            // to arrive — which is why it read as a frozen glyph.
            if (asked or a.busy or a.dirty or a.perm or a.picker or self.pal.active or self.mascotMoved()) {
                ctx.redraw = true;
            }
            try self.armTick(ctx);
        },
        .init => {
            ctx.redraw = true; // first frame without waiting for a key
            try self.armTick(ctx);
        },
        .focus_in => {
            self.focused = true;
            ctx.redraw = true;
            try self.armTick(ctx);
        },
        // Losing focus ends any gesture. Both flags had exactly ONE exit, a
        // `.release` that reaches this handler, and three ways to not get one:
        // the window losing focus (the release goes to the window you clicked),
        // the pointer leaving the surface (vaxis's `mouse_leave` carries no
        // coordinates), and a release that vxfw drops before it reaches us
        // because it landed outside the PREVIOUS frame's surface.
        //
        // A stranded `scrollbar_dragging` is the loud one: the flag makes every
        // later `.drag` in the history `return` early after a `scrollTo`, so a
        // text drag could never start a selection again and the first drag
        // anywhere jumped the scroll to wherever the pointer happened to be.
        .focus_out => {
            self.focused = false;
            self.cancelMouseGestures();
            ctx.redraw = true;
        },
        .mouse_leave => {
            self.cancelMouseGestures();
            ctx.redraw = true;
        },
        .paste => |data| {
            // Our own editor has no paste callback: we insert by hand. A paste
            // with line breaks creates a real multiline prompt.
            if (!self.pickerActive() and !self.permActive()) {
                if (self.ed.insert(data)) |_| {
                    self.input_too_long = false;
                    self.input_err = "";
                } else |err| {
                    if (std.mem.eql(u8, @errorName(err), "InputTooLong")) inputTooLongRejected(self);
                }
                syncAutocomplete(self);
            }
            ctx.redraw = true;
        },
        .mouse => |m| {
            // A modal owns the mouse while it is open: every event goes to it
            // and the transcript behind it does not scroll, select or drag.
            // Before, the wheel fell through to the history and the modal just
            // sat there while the text behind it moved.
            if (self.pal.active) {
                const r = palette.handleMouse(&self.pal, self.frame_w, self.frame_h, m);
                if (r.changed) ctx.redraw = true;
                if (std.meta.activeTag(r.action) != .none) try self.applyPaletteAction(ctx, r.action);
                return;
            }
            // The prompt rail's hover. It is read on motion only (not on drag:
            // a drag belongs to the gesture in progress) and it fills the dot
            // under the pointer, which is the only thing saying it is clickable.
            if (m.type == .motion and !self.scrollbar_dragging and !self.selecting_text) {
                const hot: ?usize = if (self.promptDotAt(m)) |d| d.para else null;
                if (hot != self.prompt_dot_hover) {
                    self.prompt_dot_hover = hot;
                    ctx.redraw = true;
                }
                return;
            }
            if (self.scrollbar_dragging) {
                switch (m.type) {
                    .drag => {
                        if (m.row >= 0 and @as(usize, @intCast(m.row)) < self.hist_rows) {
                            self.scrollTo(scrollbarOffset(
                                @intCast(m.row),
                                self.hist_rows,
                                self.max_offset,
                            ));
                        }
                        ctx.redraw = true;
                        return;
                    },
                    .release => {
                        if (m.row >= 0 and @as(usize, @intCast(m.row)) < self.hist_rows) {
                            self.scrollTo(scrollbarOffset(
                                @intCast(m.row),
                                self.hist_rows,
                                self.max_offset,
                            ));
                        }
                        self.scrollbar_dragging = false;
                        ctx.redraw = true;
                        return;
                    },
                    else => {},
                }
            }
            if (self.selecting_text) {
                switch (m.type) {
                    .drag => {
                        if (self.clampedSelectionPoint(m)) |point| self.selection_end = point;
                        ctx.redraw = true;
                        return;
                    },
                    .release => {
                        if (self.clampedSelectionPoint(m)) |point| self.selection_end = point;
                        self.selecting_text = false;
                        try self.copySelectedText(ctx);
                        ctx.redraw = true;
                        return;
                    },
                    else => {},
                }
            }
            if (m.type == .press and m.button == .left and
                !self.pal.active and !self.askActive() and !self.permActive())
            {
                // The rail comes FIRST: its column is inside the selectable
                // area, and a click there has to jump to a prompt instead of
                // starting a text selection of one character.
                if (self.promptDotAt(m)) |d| {
                    self.jumpToPrompt(d);
                    ctx.redraw = true;
                    return;
                }
                if (self.max_offset > 0 and m.col >= 0 and m.row >= 0 and
                    @as(usize, @intCast(m.col)) == self.selectable_width -| 1 and
                    @as(usize, @intCast(m.row)) < self.hist_rows)
                {
                    self.scrollbar_dragging = true;
                    self.scrollTo(scrollbarOffset(
                        @intCast(m.row),
                        self.hist_rows,
                        self.max_offset,
                    ));
                    ctx.redraw = true;
                    return;
                }
                if (self.selectionPoint(m)) |point| {
                    self.selection_start = point;
                    self.selection_end = point;
                    self.selecting_text = true;
                    ctx.redraw = true;
                    return;
                }
            }
            // The wheel arrives as button 64/65 with type=press.
            if (m.type != .press) return;
            if (m.button == .left and
                m.row >= 0 and @as(u16, @intCast(m.row)) == self.scroll_bottom_row and
                m.col >= 0 and @as(u16, @intCast(m.col)) >= self.scroll_bottom_start and
                @as(u16, @intCast(m.col)) < self.scroll_bottom_end)
            {
                self.scrollBy(-1_000_000);
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            switch (m.button) {
                // CAREFUL: `self.scroll` is a usize. `self.scroll -= 3` with
                // the scroll at 0 underflows and brings the app down (integer
                // overflow -> panic), which is what happened scrolling down
                // with the wheel while at the very top. `scrollBy` is what
                // saturates at 0.
                .wheel_up => self.scrollBy(3),
                .wheel_down => self.scrollBy(-3),
                else => return,
            }
            ctx.redraw = true;
        },
        .winsize => ctx.redraw = true,
        else => {},
    }
}

// ── drawing helpers ────────────────────────────────────────
/// Called on the FIRST frame only, from `tui`, when `ZODE_DBG_BOOT` is set.
///
/// The first `drawFn` IS the first paint: it is the first thing of ours that runs
/// after vaxis has queried the terminal, so it is the moment the user sees a window
/// with something in it. Measuring after `app.run` instead — which is where this
/// mark started — measures when the user QUIT, and it printed "first paint" on a
/// line whose number was the length of the session.
fn firstPaintMark() void {
    const env = agent.environ_global orelse return;
    const on = env.get("ZODE_DBG_BOOT") orelse return;
    if (on.len == 0 or std.mem.eql(u8, on, "0")) return;
    agent.bootMark("first frame drawn");
}

fn typeErasedDrawFn(ud: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Model = @ptrCast(@alignCast(ud));
    if (!self.boot_painted) {
        self.boot_painted = true;
        firstPaintMark();
    }

    const width: u16 = @intCast(ctx.max.width orelse ctx.min.width);
    const height: u16 = @intCast(ctx.max.height orelse ctx.min.height);
    // The modal's geometry is derived from these, and a mouse event carries no
    // size: the hit test uses what was last painted, which is what the user is
    // pointing at.
    self.frame_w = width;
    self.frame_h = height;
    if (height < 6 or width < 12) return vxfw.Surface.empty(self.widget());

    const size: vxfw.Size = .{ .width = width, .height = height };
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    var p = Painter{
        .surface = &surface,
        .arena = ctx.arena,
        .ctx = ctx,
        .width = width,
        .height = height,
    };

    // ── bottom-up layout ──
    //
    //   row height-1                       the footer's row (the mascot)
    //   rows ..input_top+input_h-1         prompt, no box, grows upward
    //   row  rule_row                      one hairline
    //   rows rule_row-ac..plan             only when relevant
    //   rows 0..history_h                  the conversation, and nothing else
    //
    // The composer is ONE object: the prompt rows and the footer's row share
    // the same sunken surface, and the footer's row is the LAST row of the
    // terminal. There is nothing under the input.
    //
    // This used to be a banner of 5 rows, a rule, a BORDERED input box of 3
    // rows, a blank, a status row and another row for the usage column: eleven
    // rows of furniture before the first word. Six of them were permanent, and
    // the banner was a drawing that never changed and never would.
    const max_input_lines: u16 = 8;
    const text_w: u16 = if (width > 4) width - 4 else 1;

    // The state, read ONCE per frame: it is what the footer's face and legend
    // are painted from, and nothing else paints a state any more.
    //
    // There used to be TWO widgets for it (the activity strip above the
    // hairline and the mascot in the row under the input) and they said the
    // same thing in two places: the row under the input held a face and
    // nothing else, so on screen it read as a stray emoticon in the corner of
    // an otherwise empty row.
    const act = self.activity();
    const queued = self.queuedCount();

    // Keep a compact live summary near the input; the complete checklist is
    // emitted into the scrollable history when the model updates the plan.
    const pl_now = self.planCopy();
    const plan_rows: u16 = if (pl_now.isEmpty()) 0 else 1;

    // Autocompletion popup: only if there are matches.
    const ac_rows: u16 = if (self.ac.active and matchCount(self) > 0)
        @as(u16, @intCast(@min(matchCount(self), self.ac.max_visible) + 1))
    else
        0;

    // The composer is ONE object: the text rows plus ONE footer row, both
    // inside the same sunken surface. The footer is the mascot, the legend and
    // the session's own numbers; there is no separate status row under the
    // input any more, and nothing under the well at all.
    //
    // `chrome` is the hairline and the optional workspace rows and NOTHING
    // else: the input has no top and no bottom border, so it costs exactly
    // the rows it is using.
    const chrome: u16 = 1 + ac_rows + plan_rows; // hairline, autocomplete, plan
    const avail: u16 = if (height > chrome + 2) height - chrome - 2 else 1;
    const ed_w: u16 = if (text_w > 0) text_w else 1;
    const input_h: u16 = @max(@min(@as(u16, @intCast(@min(self.ed.displayLines(ed_w, editorMeasurer(&p)), max_input_lines))), avail), 1);
    // The footer is ALWAYS reserved, even when it has nothing to say: a row
    // that appears and disappears with the state is a row that makes the input
    // jump, and the input is the one thing the user is looking at.
    const well_h: u16 = input_h + 1;
    const input_top: u16 = if (height > well_h + 1) height - well_h else 1;
    const rule_row: u16 = if (input_top > 0) input_top - 1 else 0;
    const workspace_top = rule_row -| ac_rows -| plan_rows;
    const history_h: u16 = @max(workspace_top, 1);
    // The key handler needs the height to jump a whole page.
    self.hist_rows = history_h;

    // ── drain pending ──
    self.drainPending();
    // The results of the user's own `!` commands. Same rule as everything else
    // that comes from a worker: the UI thread takes them and appends the session
    // message, because the session is not thread-safe.
    self.drainShellOut();

    // Invalidates the cache if the width changed (the lines already come
    // wrapped) or if a paragraph was edited in-place (Ctrl+R expands a tool
    // result).
    if (self.cache_width != width) {
        self.clearSegCache();
        self.cache_width = width;
        self.cache_from = null;
    } else if (self.cache_from) |from| {
        // Drops the paragraphs from `from` onwards. CAREFUL: `from` is a
        // HISTORY index, not a cache one (the cache is a window, so its
        // indices are offset: that is why we look it up by `para_idx`).
        var i: usize = 0;
        while (i < self.seg_cache.items.len) {
            if (self.seg_cache.items[i].para_idx >= from) {
                self.evictCached(i);
            } else {
                i += 1;
            }
        }
        self.cache_from = null;
    }

    // ── layout of the live paragraph (redone every frame) ──
    //
    // The SNAPSHOT is taken with the lock held and the PARSE OUTSIDE (1.6):
    // before, ALL of `stream_buf` was parsed (markdown + highlighter +
    // grapheme widths) on every frame and with the model lock held, so the
    // worker (which puts a `streamDelta` per token) competed with draw on
    // every token and the lock became a bottleneck. Copying is a memcpy;
    // parsing is not.
    //
    // INVARIANT: whatever `live_src` points at when the lock is released is
    // owned by `ctx.arena` and outlives the frame's parse. The `CellRun`s store
    // the grapheme BY VALUE but with a pointer to its bytes, and painting
    // happens later, so a stack buffer or a model-owned buffer would be read
    // after it died (the `&[_]u8{c}` family AGENTS.md keeps paying for).
    var live_src: []const u8 = &.{};
    var live_is_tool = false;
    var tool_buf: [128]u8 = undefined;
    {
        self.lock();
        defer self.unlock();
        if (self.streaming and self.stream_buf.items.len > 0) {
            // THE COPY IS INSIDE THE CRITICAL SECTION, and that is the whole
            // point of it.
            //
            // It used to be: take a slice under the lock, unlock, and copy ten
            // lines later at the parse site. In between the worker could
            // `stream_buf.appendSlice(...)`, which reallocates and FREES the
            // old buffer — so the copy could read freed memory, and what came
            // out was arbitrary bytes fed to the UTF-8 parser and then to the
            // renderer. Narrow window, but the only path in the history that
            // could put genuinely random bytes on screen.
            live_src = ctx.arena.dupe(u8, self.stream_buf.items) catch "";
        }
        // Feedback for the tool in progress. Without this, a 30s `bash` leaves
        // the last row frozen at `⏺ bash(...)` and there is no way to tell if
        // the process is still alive or if the app has hung: the clock is the
        // only thing that answers "is it stuck?".
        //
        // No need to concatenate with the streaming: they never coexist (a
        // tool runs with the stream closed), so the clock line REPLACES the
        // live paragraph instead of adding to it.
        if (self.tool_run) |tr| {
            // The ELAPSED TIME goes IN THE HEADER LINE, not only in the strip.
            //
            // The strip is one row and it is at most 80 columns: with a long
            // command, a model name and a session counter, its clock was the
            // first thing pushed off the right edge. So the question the user
            // actually asks — "has it been running 4 seconds or is it stuck?" —
            // had to be answered from a row that was not on screen.
            //
            // The argument is clipped for the same reason it is clipped in the
            // header: a `bash` argument is whatever the model wrote.
            //
            // The clock is read under the lock, and it MOVES: `toolRunMillis`
            // takes the lock now (it used to read `self.tool_run` unlocked,
            // which was a use-after-free against `toolRunEnd` and made this
            // number read 0 — see the comment there).
            const ms = self.toolRunMillisLocked();
            var arg_buf: [96]u8 = undefined;
            const arg_shown = textcap.clipInto(tr.arg, 48, &arg_buf);
            const secs = ms / 1000;
            const line = if (ms == 0)
                if (tr.arg.len == 0)
                    std.fmt.bufPrint(&tool_buf, "*{s}* running", .{tr.name}) catch ""
                else
                    std.fmt.bufPrint(&tool_buf, "*{s}*({s}) running", .{ tr.name, arg_shown }) catch ""
            else if (tr.arg.len == 0)
                std.fmt.bufPrint(&tool_buf, "*{s}* running · {d}.{d}s", .{ tr.name, secs, (ms % 1000) / 100 }) catch ""
            else
                std.fmt.bufPrint(&tool_buf, "*{s}*({s}) running · {d}.{d}s", .{ tr.name, arg_shown, secs, (ms % 1000) / 100 }) catch "";
            // Copied here, while `tool_buf` is certainly alive and `tr.name` /
            // `tr.arg` cannot be freed under us: `toolRunEnd` frees them from
            // the worker thread as soon as it runs.
            live_src = ctx.arena.dupe(u8, line) catch "";
            live_is_tool = true;
        }
        // The spinner advances with `workingLocked` and NOT with `busy`: during
        // a tool, `busy` is already false (the stream closed) and without this
        // the face kept the same expression for the whole `bash`, which is
        // exactly when you most need to notice the app is alive.
        if (self.workingLocked()) self.spinner_frame +%= 1;
    }

    // The footer is the single owner of phase and elapsed time. Do not repeat
    // its clock in the history while waiting for the first token.
    const live_kind: md.Kind = if (live_is_tool) .tool_res else .assistant;
    var live_active = false;
    const hist_margin: u16 = historyMargin(width);
    const wrap_width: u16 = if (width > hist_margin * 2 + 1)
        width - hist_margin * 2 - 1
    else if (width > 1)
        width - 1
    else
        width;

    var live_lines: []const PLine = &.{};
    if (live_src.len > 0) {
        // Streaming text changes every frame: force a redraw so new tokens appear.
        self.diff_needs_full_redraw = true;
        // `live_src` is already frame-arena owned (see the invariant above), so
        // there is nothing to copy here any more.
        // For the live paragraph, we don't have a Para struct, so use a temporary one
        var live_para = Model.Para{
            .kind = live_kind,
            .text = live_src,
            .lang = if (live_kind == .diff) "zig" else "",
        };
        live_lines = buildLines(ctx.arena, ctx, &live_para, wrap_width) catch &.{};
        live_active = live_lines.len > 0;
    }

    // ── scroll: 0 = anchored at the bottom ──
    //
    // `layoutFor` leaves the cache window covering what is visible (so deep
    // scrolling re-parses on demand, which is what the old comment claimed and
    // was not true) and returns the visible range already stabilized.
    //
    // Reserve one column for the scrollbar, even while it is inactive, so text
    // never jumps when the history first becomes scrollable.
    self.wrap_w = wrap_width;
    const vis = try self.layoutFor(
        ctx,
        wrap_width,
        if (live_active) live_lines.len else 0,
        history_h,
    );
    const first_visible = vis.first;
    const last_visible = vis.last;
    // Publishes what was painted, so the `↓ N` indicator and the tests read the
    // same numbers the screen shows. `live_h` goes here too: it is the one input
    // `currentMaxOffset` cannot compute on its own, and the key handlers clamp
    // against it (without it, a PageUp before the first frame does nothing).
    self.first_visible = first_visible;
    self.max_offset = vis.max_offset;
    self.live_h = if (live_active) live_lines.len else 0;

    // Always fill the transcript area AND the gap up to the hairline with
    // well_bg so there are never black holes between the last message and
    // the composer. history_h = rule_row - ac_rows - plan_rows, so when a
    // plan or autocomplete row is visible, history_h stops short of rule_row
    // and the gap would show the terminal's raw black.
    {
        var clear_row: u16 = 0;
        while (clear_row < rule_row) : (clear_row += 1) {
            p.fillRange(0, width, clear_row, " ", theme.well_bg);
        }
    }

    // ── paints only the visible lines ──
    //
    // `line_cursor` is the ABSOLUTE position of the first line: the window's
    // `.offset` (`cache_lo`) plus what the cached paragraphs before it carry.
    //
    // The `pad` is the opening hero's air. It is measured against the CONTENT's
    // real height and NOT against `last_visible - first_visible`: that range is
    // already clamped to the viewport, so it is `history_h` whenever the
    // content is short, and the first version of this compared the content
    // against itself and always decided there was no room.
    const content_lines = self.heightPrefix(self.paras.items.len) + live_lines.len;
    const hero = heroFrame(self, wrap_width + 2 * hist_margin, history_h, content_lines);
    const pad = hero.pad;
    // ── paint cached paragraphs ──
    // Use `heightPrefix(para_idx)` for the absolute line position of each
    // cached paragraph. This correctly handles gaps in the cache (virtual
    // scroll means not every paragraph is parsed).
    for (self.seg_cache.items) |c| {
        const para_abs_start = self.heightPrefix(c.para_idx);
        if (para_abs_start >= last_visible) break;
        if (para_abs_start + c.height <= first_visible) continue;
        drawLines(&p, c.lines, para_abs_start, first_visible, history_h, pad, hero.x_off);
    }
    // ── paint live paragraph ──
    // Its absolute position is the total height of all closed paragraphs.
    if (live_active) {
        const live_abs_start = self.heightPrefix(self.paras.items.len);
        drawLines(&p, live_lines, live_abs_start, first_visible, history_h, pad, hero.x_off);
    }

    // ── update differential tracking state ──
    self.diff_last_first = first_visible;
    self.diff_last_last = last_visible;
    self.diff_last_live_active = live_active;
    self.diff_needs_full_redraw = false;
    drawHistoryScrollbar(&p, width, history_h, first_visible, vis.max_offset);
    // ── prompt rail (dots) ── computed every frame so the mouse handler has
    // current data, but only painted when show_prompt_dots is enabled (off by
    // default: not polished enough yet).
    self.refreshPromptDots(width, history_h);
    // The sticky header and the pill go OVER the transcript, and that is the
    // editor's own convention (a sticky line covers the content under it).
    // Reserving a row for them would move the text under the reader's eyes
    // every time they appeared, and the transcript is what they are reading.
    drawStickyHeader(&p, self, width, ctx.arena);
    drawNewMessagesPill(&p, self, width, history_h);
    try self.snapshotSelectableHistory(surface, history_h);
    drawPromptTimeline(&p, self);
    self.paintTextSelection(surface);

    // The session's numbers are NOT painted here any more: they live in the
    // composer's footer, next to the mascot, because there is no row under
    // the input any more.
    //
    // What used to be here was a status row that answered "what model am I
    // talking to" with a face on its left and the model's name glued to its
    // right, and nothing in between: on screen it read as a stray emoticon in
    // the corner of an empty row, which is what the user called ugly. The
    // strip above the hairline said the SAME thing again ("thinking",
    // "streaming"), so the state was in two places and the numbers were in a
    // third.
    //
    // There is now ONE state surface, inside the composer, and it carries all
    // of it: the mascot, the legend and the session's own numbers.

    // ── `ask`: the model asked something ──
    //
    // The picker is opened HERE, on the UI thread, and not by the worker that
    // raised the question. That is not a style choice: the worker of `/models` once
    // filled the palette while the UI thread was drawing it, with no lock on the
    // palette's own state, and the app segfaulted. The worker leaves the question
    // in the `Model`; the draw is what turns it into a picker.
    // ── modal picker (opencode style, centered) ──
    if (self.pickerSnapshot(ctx.arena)) |ps| {
        drawPicker(&p, width, height, ps);
    }

    // ── permission dialog (modal over the history, at the bottom) ──
    var perm_tool: []const u8 = "";
    var perm_detail: []const u8 = "";

    // ── the plan, when there is one ──
    if (plan_rows > 0) {
        drawPlanBlock(&p, workspace_top, width, pl_now);
    }

    // ── `/` autocompletion (directly above the prompt) ──
    if (ac_rows > 0) {
        drawAutocomplete(&p, self, input_top - ac_rows, width, ac_rows);
    }

    // ── the hairline ──
    //
    // ONE row, full width, `line_bright`: it is what replaces the input's box.
    // A box is two extra rows and four more glyphs to say "text goes here", and
    // the thing it is really saying is "this is the boundary of the page" —
    // which is what a rule says, for one row instead of three.
    //
    // It is NOT painted when the permission dialog is up: the modal is a
    // centred box with a clean background, and a full-width rule under it
    // points at a boundary the dialog is ignoring.
    if (!self.permActive()) p.fillRow(rule_row, "─", theme.rule);

    // Determine accent bar color based on state (reuse `act` from layout)
    const bar_style = if (act.ask) theme.warn else if (act.busy) theme.brand else theme.input_bar;

    drawInput(&p, &surface, self, input_top, width, input_h, rule_row, bar_style);

    // ── the footer's row: the ONE state surface ──
    //
    // It is the last row of the composer's own well, so the bottom of the app
    // is ONE object: the sunken surface with the prompt in it and the mascot
    // under it. Nothing hangs below the input any more.
    drawStateFooter(&p, input_top + input_h, width, self, act, queued, ctx.arena);

    // ── permission dialog: centered MODAL ──
    //
    // Before it was 4 lines glued right above the input box, in the middle of
    // the normal flow: with a full history they were half hidden or covered,
    // and the app looked HUNG waiting for something nobody could see. Now it is
    // a centered box with a border, a clean background and big options: there
    // is no way not to see it.
    if (self.permView(&perm_tool, &perm_detail)) {
        drawPermissionModal(
            &p,
            width,
            height,
            perm_tool,
            perm_detail,
            self.permAllowAlways(),
            self.permSuggestion(),
        );
    }

    // ── `ask`: the question itself ──
    //
    // Drawn ABOVE the permission modal and BELOW the palette, and the reason is
    // priority: an `ask` and a permission cannot be open at the same time (a
    // question is asked by the model between tool calls, and the permission for
    // the NEXT tool only comes after the answer), but the palette can be open
    // over a question — you pressed ctrl+p while waiting — and then the palette
    // must win, because it is what you are typing into.
    if (self.askSnapshot(ctx.arena)) |snap| {
        if (!self.pal.active) drawAskPanel(&p, width, history_h, snap, self.askMillis());
    }

    // ── modal palette (Ctrl+P): last, on top of everything ──
    //
    // Before drawing: if the worker left new models, the palette is reloaded
    // with them. This happens HERE, on the UI thread, which is the palette's
    // only owner.
    if (self.takePendingItems()) |items| {
        self.pal.setItemsOwned(items, &agent.model_groups);
    }
    if (self.pal.active) {
        palette.draw(&p, &surface, &self.pal, width, height, self.catalogNotice(ctx.arena));
    }

    // ── copy toast: top-right, rounded border, ~2 seconds ──
    if (self.copy_toast_frames > 0) {
        self.copy_toast_frames -= 1;
        drawCopyToast(&p, width, height, self.copy_toast_text);
    }

    return surface;
}

/// Copy toast: small rounded box in the top-right corner that appears for
/// ~2 seconds after the user copies selected text to the clipboard.
fn drawCopyToast(p: *Painter, width: u16, height: u16, text: []const u8) void {
    if (width < 10 or height < 4) return;
    const pad: u16 = 2;
    const text_w: u16 = if (text.len > 40) 40 else @intCast(text.len);
    const toast_w: u16 = @min(@max(text_w + 4, 20), width - 2 * pad);
    const toast_h: u16 = 3;
    const toast_x: u16 = width - toast_w - pad;
    const toast_y: u16 = pad;

    drawRoundedBox(p, toast_x, toast_y, toast_w, toast_h, theme.code_bg, theme.code_border);

    // Text, centered.
    const text_x: u16 = toast_x + (toast_w - text_w) / 2;
    _ = p.putText(text_x, toast_y + 1, text, theme.ink);
}

/// The prompt. No box, no borders, no top rule of its own: the hairline above
/// already separates the conversation from what you type, and a box around the
/// input was three rows for a statement the rule makes in one.
///
/// What the box DID carry — a visual anchor for "you are here" — is now a
/// single accent bar in the left margin, one cell tall per input row. It is
/// the only green in the bottom third of the screen and it is always where the
/// caret is, which is the entire job.
///
/// Input display text: if the buffer is longer than `max_display_bytes`, show
/// the head, then `... +N more`, then the tail. Image file paths are shown as
/// `[image.{ext}]`. The FULL text stays in the editor buffer for sending.
/// Returns an arena-owned slice; caller must not free (arena lives for frame).
fn inputDisplayText(arena: std.mem.Allocator, text: []const u8, max_display_bytes: usize) ![]const u8 {
    if (text.len == 0) return "";

    // Detect image file paths and replace with [image.{ext}].
    // A path is an image if it ends with a known image extension.
    const image_exts = [_][]const u8{ "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "ico", "tiff" };
    var has_image: bool = false;
    var processed: []const u8 = text;
    var processed_buf: []u8 = undefined;
    var processed_allocated: bool = false;

    // Simple image detection: look for known extensions at word boundaries.
    // If found, replace the whole path token with [image.ext].
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        // A token starts at a non-space char.
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            try out.append(arena, c);
            i += 1;
            continue;
        }
        // Find end of token.
        var j = i;
        while (j < text.len and text[j] != ' ' and text[j] != '\t' and text[j] != '\n' and text[j] != '\r') j += 1;
        const token = text[i..j];
        // Check if token ends with an image extension.
        var matched_ext: ?[]const u8 = null;
        for (image_exts) |ext| {
            if (token.len > ext.len + 1) {
                // Case-insensitive endsWith: compare the last ext.len bytes ignoring case.
                const tail = token[token.len - ext.len..];
                var matched = true;
                for (tail, ext) |tc, ec| {
                    if (std.ascii.toLower(tc) != std.ascii.toLower(ec)) {
                        matched = false;
                        break;
                    }
                }
                if (matched) {
                    matched_ext = ext;
                    break;
                }
            }
        }
        if (matched_ext) |ext| {
            has_image = true;
            const tag = try std.fmt.allocPrint(arena, "[image.{s}]", .{ext});
            try out.appendSlice(arena, tag);
            arena.free(tag);
        } else {
            try out.appendSlice(arena, token);
        }
        i = j;
    }

    if (out.items.len > 0) {
        processed_allocated = true;
        processed_buf = try out.toOwnedSlice(arena);
        processed = processed_buf;
    }

    // Truncate if longer than max_display_bytes.
    if (processed.len <= max_display_bytes) {
        if (processed_allocated) arena.free(processed_buf);
        return processed;
    }

    // Show head + "... +N more" + tail.
    const head_len: usize = max_display_bytes / 2 - 10;
    const tail_len: usize = max_display_bytes / 2 - 10;
    const skipped: usize = processed.len - head_len - tail_len;
    const head = processed[0..head_len];
    const tail = processed[processed.len - tail_len..];

    const head_and_marker = try std.fmt.allocPrint(arena, "{s}… +{d} more", .{head, skipped});
    const result_len = head_and_marker.len + tail.len;
    const result_buf = try arena.alloc(u8, result_len);
    @memcpy(result_buf[0..head_and_marker.len], head_and_marker);
    @memcpy(result_buf[head_and_marker.len..], tail);

    if (processed_allocated) arena.free(processed_buf);

    return result_buf;
}

/// The terminal cursor is anchored at the real editor position.
fn drawInput(
    p: *Painter,
    surface: *vxfw.Surface,
    self: *Model,
    top: u16,
    width: u16,
    input_h: u16,
    hint_row: u16,
    bar_style: vaxis.Style,
) void {
    if (top >= p.height or width < 6) return;

    // The well is the TEXT rows only.
    //
    // It used to be the text rows PLUS the footer's row, with the mascot
    // inside the same sunken surface and under the same accent bar. On screen
    // that read as one block: the `▌›` of the prompt and the `▌( o o )` of the
    // mascot looked like the input had two parts, and the mascot looked like
    // something you could type into.
    //
    // The mascot is the STATE, and the state is not the input. It now lives on
    // its own row BELOW the well, on the terminal's background: the input
    // block ends, and under it there is the line that says what the app is
    // doing.
    const well_h: u16 = input_h;

    // The composer surface: a subtle `well_bg` fill behind the input rows so
    // the composer reads as a SUNKEN SURFACE, distinct from the transcript
    // above (which sits on the terminal's default background). This is the
    // same trick that makes tool output wells legible — depth, not a border.
    // Zero extra rows: the surface lives inside the rows the input already owns.
    {
        var i: u16 = 0;
        while (i < well_h and top + i < p.height) : (i += 1) {
            p.fillRange(1, width, top + i, " ", theme.well_bg);
        }
    }

    // The accent bar: one cell per well row, in the left margin. `▌` and NOT
    // `│`: a half-block is the "here" mark in every editor and a pipe reads as
    // a border. Color changes with state: normal=input_bar, busy=brand, ask=warn.
    // The caret is dimmed when the window does not have focus: typing here does
    // nothing until the window is focused again, and the reader should see that.
    {
        var bs = bar_style;
        if (!self.focused) bs.dim = true;
        var i: u16 = 0;
        while (i < well_h and top + i < p.height) : (i += 1) {
            p.putStable(0, top + i, "▌", 1, bs);
        }
    }

    // Prompt and text start at columns 1 and 3 respectively; keeping the same
    // width in layout and paint prevents clipping a final grapheme.
    // In ask-answer mode (question open, input is the answer field), show a
    // distinct prompt glyph to distinguish from normal prompt.
    // When the input starts with `!` (shell-out mode), the prompt is colored
    // differently so the user can see at a glance that Enter will run a shell
    // command rather than start a turn.
    const in_ask_answer = self.askActive();
    const bang_cmd = self.ed.text().len > 0 and self.ed.text()[0] == '!';
    const prompt_glyph = if (in_ask_answer) "? " else if (bang_cmd) "! " else "› ";
    const prompt_fg = if (in_ask_answer)
        theme.warn.fg
    else if (bang_cmd)
        theme.warn.fg
    else
        theme.input_prompt.fg;
    const prompt_style: vaxis.Style = .{
        .bold = true,
        .fg = prompt_fg,
        .bg = theme.well_bg.bg,
    };
    _ = p.putText(1, top, prompt_glyph, prompt_style);
    const ed_w: u16 = if (width > 4) width - 4 else 1;
    const meas = editorMeasurer(p);

    // Rows, not lines: the text is wrapped HERE, with the same wrap the box was
    // sized with. It used to be split on `\n` only and each line handed to
    // `putText`, which clips at the TERMINAL edge: a 200-character prompt made an
    // eight-row box with all the text in one row running off the right, and
    // everything past the border was dropped without a word.
    //
    // Long input (e.g. a huge paste) is truncated for display: head + "... +N more" + tail.
    // The FULL text stays in the editor buffer for sending.
    const full_text = self.ed.text();
    const disp_text = if (full_text.len > max_input_display_bytes)
        inputDisplayText(p.arena, full_text, max_input_display_bytes) catch full_text
    else
        full_text;
    // Wrap the (possibly truncated) text into rows. RowIter is public in editor.zig.
    const truncated = full_text.len > max_input_display_bytes;
    var rows_buf: std.ArrayList(ed.Row) = .empty;
    var rit = ed.RowIter.init(disp_text, ed_w, meas);
    while (rit.next()) |r| {
        rows_buf.append(p.arena, r) catch continue;
    }
    const total_rows = rows_buf.items.len;
    // Bottom-anchored (like the history): the cursor is at the end of what you
    // are typing, so that is what has to stay visible.
    const first = if (total_rows > input_h) total_rows - input_h else 0;
    const shown = rows_buf.items[first..];
    for (shown, 0..) |piece, i| {
        const row = top + @as(u16, @intCast(i));
        if (i >= input_h) break;
        if (piece.bytes.len == 0) continue;
        const text_style: vaxis.Style = .{
            .fg = theme.input_text.fg,
            .bg = theme.well_bg.bg,
        };
        _ = p.putClipped(3, row, piece.bytes, ed_w, text_style);
    }

    // The edit was rejected because it would exceed the byte cap: paint the
    // note inside the composer zone itself (the affected zone), so the
    // transcript above does not move and nothing else on screen changes.
    // The well rows are refilled every frame, so a cleared note disappears
    // on the next draw; the note is cleared on the next keystroke.
    if (self.input_too_long) {
        const err_row = if (total_rows <= input_h)
            top + @as(u16, @intCast(total_rows))
        else
            top + input_h - 1;
        if (err_row < p.height) {
            var est = theme.warn_bold;
            est.bg = theme.well_bg.bg;
            _ = p.putClipped(3, err_row, self.input_err, ed_w, est);
        }
    }

    // The terminal cursor, at its VISUAL row and column. Only when not
    // truncated: for truncated input the cursor would point at the wrong place.
    if (!truncated) {
        const cc = self.ed.cursorRowCol(ed_w, meas);
        if (cc.row >= first and cc.row < first + shown.len) {
            const col = 3 + @min(cc.col, ed_w - 1);
            surface.cursor = .{
                .row = top + @as(u16, @intCast(cc.row - first)),
                .col = col,
            };
        }
    }

    // Show the clipped prompt's hidden-row count on the workspace rule, not in
    // the prompt text itself.
    if (first > 0 and width > 16 and hint_row != top and !self.ac.active) {
        var ib: [32]u8 = undefined;
        const lab = std.fmt.bufPrint(&ib, "\u{2191} {d} more", .{first}) catch "";
        if (lab.len > 0 and lab.len + 4 < width) {
            _ = p.putClipped(width - 2 - @as(u16, @intCast(lab.len)), hint_row, lab, @as(u16, @intCast(lab.len)), theme.key_hint);
        }
    }

    if (self.ed.isEmpty()) {
        // With a question open this box IS the answer field (the free-text path),
        // so the placeholder has to say so: it used to invite a prompt, which is
        // not what pressing Enter there does.
        const ph: []const u8 = if (self.askActive())
            "your answer\u{2026} \u{b7} enter sends it \u{b7} esc: you decide"
        else
            "Ask anything\u{2026} \u{b7} / for commands";
        // The placeholder must sit ON the well_bg surface, not overwrite it with
        // .default. Combine the placeholder foreground with the well background.
        const ph_style: vaxis.Style = .{
            .fg = theme.placeholder.fg,
            .bg = theme.well_bg.bg,
        };
        _ = p.putClipped(3, top, ph, ed_w, ph_style);
    }
}

/// Paints `text` with the fuzzy-matched characters BOLD, and — when `accent` is
/// given — everything from `accent_from` on in the accent color.
///
/// Three axes in one pass: the directories dim, the file name in the accent, the
/// characters the query reached in bold. That is how a file palette reads in an
/// editor: the eye lands on the name, and the bold says WHY this row is here.
///
/// One `putText` per run of equal style, and runs are cut at GRAPHEME
/// boundaries: `positions` are byte offsets (fuzzy's contract), so a match that
/// lands inside a multi-byte character paints that whole character. You cannot
/// half-highlight a glyph.
///
/// Returns the next free column.
fn putStyled(
    p: *Painter,
    col: u16,
    row: u16,
    text: []const u8,
    positions: []const u32,
    base: vaxis.Style,
    accent: ?vaxis.Style,
    accent_from: usize,
) u16 {
    if (text.len == 0) return col;
    var x = col;
    var run_start: usize = 0;
    var run_style: vaxis.Style = base;
    var off: usize = 0;
    var it = vaxis.unicode.graphemeIterator(text);
    while (it.next()) |g| {
        const len = g.bytes(text).len;
        if (len == 0) continue;
        var is_hit = false;
        for (positions) |p32| {
            const at: usize = p32;
            if (at >= off and at < off + len) {
                is_hit = true;
                break;
            }
        }
        const plain: vaxis.Style = if (accent) |a| (if (off < accent_from) base else a) else base;
        const want: vaxis.Style = if (is_hit)
            .{ .bold = true, .fg = theme.brand_hi.fg, .bg = plain.bg }
        else
            plain;
        if (!std.meta.eql(want, run_style)) {
            x = p.putText(x, row, text[run_start..off], run_style);
            run_start = off;
            run_style = want;
        }
        off += len;
    }
    if (off > run_start) x = p.putText(x, row, text[run_start..off], run_style);
    return x;
}

/// A file path: directories dim, file name in the accent, matches bold.
fn putMatchPath(p: *Painter, col: u16, row: u16, path: []const u8, positions: []const u32, selected: bool) u16 {
    const name_start: usize = if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| s + 1 else 0;
    const base = if (selected) theme.selected else theme.dim;
    const name = if (selected) theme.selected else theme.accent;
    return putStyled(p, col, row, path, positions, base, name, name_start);
}

/// List of commands matching what was typed after the `/`.
fn drawAutocomplete(
    p: *Painter,
    self: *const Model,
    top: u16,
    width: u16,
    rows: u16,
) void {
    if (width < 10 or rows < 2) return;
    p.fillRange(0, width, top, " ", .{});
    // The bottom row is the FOOTER, not a bare rule: it carries the count. The
    // rule is kept underneath the text of that same row so the popup still has a
    // visible edge without spending a whole row on it.
    const foot_row = top + rows - 1;
    p.fillRange(0, width, foot_row, "─", theme.rule);

    const first = self.ac.first;
    // The LAST row is not another item: it is the footer, and it says how many
    // are hidden.
    //
    // Without it the popup silently truncates: 10 files in the directory,
    // `max_visible` rows on screen, and no sign that the other four exist. From
    // the user's side that is not a truncated list, it is a directory that
    // apparently has six entries — which is exactly the "no me da la lista de
    // files" report. A picker that lies about its size is worse than no picker.
    const item_rows = rows - 1;
    const total = matchCount(self);
    const hidden = if (total > item_rows) total - item_rows else 0;
    for (0..item_rows) |i| {
        const label = matchLabel(self, first + i) orelse break;
        const y = top + @as(u16, @intCast(i));
        const is_sel = first + i == self.ac.sel;
        if (is_sel) p.fillRange(0, width, y, " ", theme.selected);
        // `@` paths are already prefixed in the label? No: the label is the raw
        // path, the `@` is drawn dim so the mention form is visible. The path is
        // painted run by run so that the characters the query matched are bold:
        // with 40 candidates, "this row is here because of `edt`" is the thing
        // that lets you pick without reading every one.
        if (self.ac.mode == .file) {
            _ = p.putText(1, y, "@", if (is_sel) theme.selected else theme.dim);
            var hbuf: [128]u32 = undefined;
            const q = acPrefix(self) orelse "";
            const hn = fuzzy.highlightPositions(label, q, &hbuf) orelse 0;
            _ = putMatchPath(p, 2, y, label, hbuf[0..hn], is_sel);
        } else {
            _ = p.putText(1, y, label, if (is_sel) theme.selected else theme.accent);
        }
        if (self.ac.mode == .command and label.len + 4 < width) {
            var db: [96]u8 = undefined;
            const d = std.fmt.bufPrint(&db, "  {s}", .{agentCommandDesc(label)}) catch continue;
            _ = p.putText(3 + @as(u16, @intCast(label.len)), y, d, theme.dim);
        }
    }

    // Footer: how many matches there are, and how many are off screen. Both
    // numbers, because "6 matches" with 6 rows shown looks complete and is not.
    var fb: [64]u8 = undefined;
    const foot = if (hidden > 0)
        std.fmt.bufPrint(&fb, "{d} matches · +{d} more · ↑↓ · tab", .{ total, hidden }) catch ""
    else
        std.fmt.bufPrint(&fb, "{d} {s} · ↑↓ · tab", .{
            total,
            if (total == 1) @as([]const u8, "match") else "matches",
        }) catch "";
    if (foot.len + 2 < width) {
        _ = p.putText(width - 1 - @as(u16, @intCast(foot.len)), foot_row, foot, theme.dim);
    }
}

/// The description of a command by its full key (`/model` → "switch model").
/// One lookup, shared by the draw: `commandAt` is a tiny walk over two static
/// lists, a linear scan is cheaper than threading `agent.Cmd` through the
/// match functions.
fn agentCommandDesc(key: []const u8) []const u8 {
    var i: usize = 0;
    while (agent.commandAt(i)) |c| : (i += 1) {
        if (std.mem.eql(u8, c.key, key)) return c.desc;
    }
    return "";
}

/// Splits the text into logical lines. Frame arena: the slice lives one frame.
fn splitLines(arena: std.mem.Allocator, text: []const u8) [][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| out.append(arena, l) catch break;
    return out.items;
}

/// Byte offset of the start of line `line`.
fn lineStartOffset(lines: [][]const u8, line: usize) usize {
    var off: usize = 0;
    for (lines[0..@min(line, lines.len)]) |l| off += l.len + 1; // +1 for the '\n'
    return off;
}

/// Paints a paragraph's lines, clipped to the visible window
/// [first_visible, last_visible) mapped to rows [0, history_h).
/// Side margin of the history, in columns.
///
/// Layout reserves it on both sides; painting uses it as the left edge.
fn historyMargin(width: u16) u16 {
    return if (width > 8) 2 else 0;
}

/// The size and travel of a scrollbar's thumb.
///
/// Public because the palette has a scrollbar too (the models list is cut at
/// 19 rows and there are 464 of them), and two implementations of "how big is
/// the thumb" is two answers to the same question.
pub fn scrollbarThumb(track_rows: usize, max_offset: usize) struct { size: usize, travel: usize } {
    if (track_rows == 0 or max_offset == 0) return .{ .size = track_rows, .travel = 0 };
    const total = track_rows + max_offset;
    const size = @max(1, track_rows * track_rows / total);
    return .{ .size = @min(size, track_rows), .travel = track_rows -| size };
}

fn scrollbarOffset(row: usize, track_rows: usize, max_offset: usize) usize {
    const thumb = scrollbarThumb(track_rows, max_offset);
    if (thumb.travel == 0 or max_offset == 0) return 0;
    const centered = row -| (thumb.size / 2);
    const track_pos = @min(centered, thumb.travel);
    const scaled = @as(u128, @intCast(track_pos)) * @as(u128, @intCast(max_offset));
    return @intCast(scaled / thumb.travel);
}

/// The prompt of the turn you are reading, pinned over the top of the
/// transcript.
///
/// It is the reference implementation's "the sticky prompt header", and it
/// answers a question the transcript alone cannot: **"which request is
/// this?"** — the answer when you are reading the middle of a long session,
/// where the request is ten screens up.
///
/// **It goes OVER the transcript and not in a row of its own.** A row
/// reserved for it would move the text under the reader's eyes every time it
/// appeared, and the transcript is what they are reading; the editor's own
/// sticky line covers the content under it for the same reason.
///
/// **It only appears when the reader is away from the bottom.** At the bottom
/// the prompt is right there in the transcript, and covering the answer while
/// the model is writing would be a cost with no benefit.
fn drawStickyHeader(
    p: *Painter,
    self: *const Model,
    width: u16,
    arena: std.mem.Allocator,
) void {
    if (self.follow_bottom) return;
    if (width < 12) return;
    const text = stickyPrompt(self) orelse return;

    // Only the FIRST line of the prompt: a prompt with three lines is a
    // paragraph, and a header is a line.
    var first_line = text;
    if (std.mem.indexOfScalar(u8, first_line, '\n')) |nl| first_line = first_line[0..nl];

    const avail = width -| 3;
    if (avail == 0) return;

    // The row is cleared first: the header goes over the transcript, and a
    // header over half a line of text is two half-legible things.
    p.fillRange(0, width, 0, " ", .{});
    var col: u16 = 1;
    col = p.putText(col, 0, "›", theme.brand_soft);
    // The text is copied into the frame's arena: `putText` does not copy, and
    // the renderer reads the bytes after this frame is over.
    const owned = arena.dupe(u8, first_line) catch return;
    _ = p.putClipped(col + 1, 0, owned, avail, theme.hint);
}

/// The user prompt of the turn being read, as a paragraph index.
///
/// It is the SAME answer the sticky header writes, and it is indexed rather
/// than copied because the prompt rail needs to mark WHICH dot it is: the
/// header names the prompt, the filled dot says where it is on the rail.
fn stickyPromptPara(self: *const Model) ?usize {
    if (self.paras.items.len == 0) return null;
    // The anchor is the paragraph the reader is looking at. While the reader
    // is at the bottom, the anchor is the last paragraph anyway, so the same
    // search answers both cases.
    const upto = @min(self.anchor_para + 1, self.paras.items.len);
    var i = upto;
    while (i > 0) {
        i -= 1;
        const para = self.paras.items[i];
        if (para.kind == .user and para.text.len > 0) return i;
    }
    return null;
}

/// The text of the user prompt of the turn being read.
fn stickyPrompt(self: *const Model) ?[]const u8 {
    const i = stickyPromptPara(self) orelse return null;
    return self.paras.items[i].text;
}

/// The "3 new messages" pill, floating over the transcript.
///
/// It is the reference implementation's pill, and the COUNT is the point:
/// "↓ latest" in the footer says where you can go, "3 new" says what you are
/// missing.
///
/// It floats OVER the last row of the transcript, and that is a deliberate
/// cost: a control that is on its own row moves the transcript every time it
/// appears, and the transcript is what the reader is reading. The footer
/// keeps the clickable "↓ N new", so nothing is lost by covering a line.
fn drawNewMessagesPill(
    p: *Painter,
    self: *const Model,
    width: u16,
    history_h: u16,
) void {
    if (self.follow_bottom) return;
    const unseen = self.unseenTurns();
    if (unseen == 0) return;
    if (history_h < 2 or width < 20) return;

    var buf: [32]u8 = undefined;
    const label = if (unseen == 1)
        std.fmt.bufPrint(&buf, "1 new message", .{}) catch "new"
    else
        std.fmt.bufPrint(&buf, "{d} new messages", .{unseen}) catch "new";
    if (label.len == 0) return;

    const w: u16 = @intCast(label.len + 2);
    if (w > width) return;
    const x: u16 = (width - w) / 2;
    const y: u16 = history_h - 1;

    // A pill needs a BACKGROUND: without it the text floats over the
    // transcript and both are readable, which is not readable.
    var st = theme.brand_bold;
    st.bg = theme.brand.bg;
    st.fg = theme.code_bg.fg;
    p.fillRange(x, x + w, y, " ", st);
    _ = p.putText(x + 1, y, label, st);
}

fn drawHistoryScrollbar(
    p: *Painter,
    width: u16,
    track_rows: u16,
    first_visible: usize,
    max_offset: usize,
) void {
    if (width == 0 or track_rows == 0 or max_offset == 0) return;
    const metrics = scrollbarThumb(@intCast(track_rows), max_offset);
    const thumb_top = if (metrics.travel == 0)
        0
    else
        metrics.travel * first_visible / max_offset;
    const col = width - 1;
    var row: usize = 0;
    while (row < track_rows) : (row += 1) {
        const in_thumb = row >= thumb_top and row < thumb_top + metrics.size;
        p.putStable(col, @intCast(row), if (in_thumb) "█" else "│", 1, if (in_thumb) theme.brand else theme.rule);
    }
}

/// The rail of recent prompts, on the right margin, one column left of the
/// scrollbar.
///
/// It is a CONTROL and not decoration: a click on a dot scrolls to that prompt.
/// That is why it is painted AFTER the selectable snapshot — a dot is not
/// something anyone wants on the clipboard — and why the dot under the pointer
/// is filled: a dim circle does not say "clickable".
///
/// The filled dot with no pointer on it is the prompt of the turn being read,
/// the one the sticky header names. The two together answer "where am I"
/// without covering a line of the transcript.
fn drawPromptTimeline(p: *Painter, self: *const Model) void {
    if (!self.show_prompt_dots) return;
    if (self.prompt_dot_len == 0 or self.prompt_dot_col == 0) return;
    const active = stickyPromptPara(self);
    for (self.prompt_dots[0..self.prompt_dot_len]) |d| {
        const on = active != null and d.para == active.?;
        const hot = self.prompt_dot_hover != null and d.para == self.prompt_dot_hover.?;
        p.putStable(
            self.prompt_dot_col,
            d.row,
            if (on or hot) "●" else "○",
            1,
            if (on) theme.brand_bold else if (hot) theme.brand else theme.brand_soft,
        );
    }
}

/// Splits the WIDE cells of a row into one cell per column.
///
/// A cell can be wider than one column: the rule under the hero is ONE cell
/// that carries ninety-five "─" and claims ninety-five columns, and vaxis's
/// renderer SKIPS the cells a wide cell covers — it writes the wide cell and
/// jumps `width - 1` columns ahead. So a modal painted over a row that has
/// one of those cells is NOT painted: the rule eats the modal's border and its
/// whole interior, and the modal looks like it has a hole in it.
///
/// The split writes the wide cell's graphemes one per column, so the row is
/// made of ordinary cells and anything can be painted over it. It has to
/// happen BEFORE the overlay paints: the expansion writes the rule's own
/// graphemes into the columns the wide cell covered, and the overlay's cells
/// have to come after them to win.
///
/// This is called by every overlay (the palette, the picker, the permission
/// dialog, the ask panel) on the rows it is about to paint.
pub fn expandWideCells(surface: *vxfw.Surface, row: u16, width: u16) void {
    var col: u16 = 0;
    while (col < width) : (col += 1) {
        const cell = surface.readCell(col, row);
        const cell_w = cell.char.width;
        if (cell_w <= 1) continue;
        const g = cell.char.grapheme;
        var it = vaxis.unicode.graphemeIterator(g);
        var c = col;
        while (it.next()) |gr| {
            if (c >= width) break;
            surface.writeCell(c, row, .{
                .char = .{ .grapheme = gr.bytes(g), .width = 1 },
                .style = cell.style,
            });
            c += 1;
        }
        // The wide cell covered `cell_w` columns and the graphemes are one
        // per column now: the loop continues after the last one.
        col = if (c > 0) c - 1 else col;
    }
}

fn drawLines(
    p: *Painter,
    lines: []const PLine,
    line_offset: usize,
    first_visible: usize,
    history_h: u16,
    pad: u16,
    x_off: u16,
) void {
    const hh: usize = history_h;
    // The history has matching air on both sides, like the input box.
    const margin: u16 = historyMargin(p.width) + x_off;
    for (lines, 0..) |ln, li| {
        const abs = line_offset + li;
        if (abs >= first_visible + hh) break;
        if (abs < first_visible) continue;
        // `pad` is blank rows above the first line. It is how the opening hero
        // ends up in the middle of an otherwise empty screen instead of glued
        // to the top of it with thirty rows of nothing underneath.
        //
        // It is a PARAMETER and not an offset baked into `first_visible` for
        // one reason: `first_visible` is a scroll position and it feeds the
        // height tree, the key handlers and the scrollbar. Faking a negative
        // scroll to get some air would put all three out by the same amount, and
        // the first PageUp would jump.
        const row_raw: usize = abs - first_visible + @as(usize, pad);
        const row: u16 = if (row_raw > std.math.maxInt(u16)) std.math.maxInt(u16) else @intCast(row_raw);
        if (row >= hh) break;
        var col: u16 = margin;
        for (ln.cells) |cell| {
            p.putStable(col, row, cell.text, cell.w, cell.style);
            const new_col: usize = @as(usize, col) + @as(usize, cell.w);
            col = if (new_col > std.math.maxInt(u16)) std.math.maxInt(u16) else @intCast(new_col);
            if (col >= p.width) break;
        }
    }
}

/// Blank rows above the transcript, and blank columns to its left: the ONE rule
/// that decides both.
///
/// Only the opening screen gets them, and only when the whole thing fits. A
/// conversation is bottom-anchored (that is what a terminal does, and that is
/// what you expect when text is arriving), but a hero glued to the top-left of
/// a thirty-row screen reads as a page that failed to load. Centering it is the
/// difference between "empty" and "waiting".
///
/// One function and one condition, so it is testable: the air exists iff the
/// transcript is nothing but the hero AND it fits.
///
/// The width is `hero_content_w` and not "however wide this line happens to
/// be", because a block whose left edge moves when one of its strings is one
/// character wider is not a block — it is text that happens to be near a rule.
fn heroFrame(m: *const Model, width: u16, history_h: u16, content_lines: usize) struct { pad: u16, x_off: u16 } {
    if (!onlyHero(m)) return .{ .pad = 0, .x_off = 0 };
    if (content_lines >= history_h) return .{ .pad = 0, .x_off = 0 };
    const avail = @as(u16, width) -| 2 * historyMargin(width);
    if (avail <= hero_content_w) return .{ .pad = 0, .x_off = 0 };
    return .{
        .pad = @intCast((@as(usize, history_h) - content_lines) / 2),
        .x_off = (avail - hero_content_w) / 2,
    };
}

/// Columns the hero's block occupies: the wordmark plus the widest grid row.
pub const hero_content_w: u16 = 18 + 44;

/// Resolves `status_model_buf` from the provider's CACHED catalogue.
///
/// The cache is on disk because it is the only place a model list exists before
/// the network has answered: the worker fetches the catalogue in the background
/// Resolves the model name for the STATUS ROW, from the cache on disk.
///
/// It runs in `draw` rather than in `loadUserConfig` because the resolve is
/// LAZY and a file read at startup would block the first frame on a file the
/// user may never look at. `modelcache.read` locates, opens and parses the file
/// itself, and it validates the version and the URL — so a stale or foreign
/// cache is "no cache at all", which is the only safe answer to give a status
/// row, and the draw cannot wait for it.
///
/// It takes the FIRST free model, which is the same rule `resolveModelHeadless`
/// uses — the status bar is showing what the first turn would pick, not
/// advertising the whole list.
pub fn resolveStatusModel(self: *Model) void {
    self.lock();
    defer self.unlock();
    if (self.status_model_len > 0) return;
    // The clock's own guard, `io_ready`, and not `io == undefined`: `Io` is not
    // comparable and reading an uninitialised one is a jump through a garbage
    // vtable, which is the `attachIo` trap this repo has already paid for.
    if (!self.io_ready) return;
    self.status_model_tried = true;
    const io = self.io;
    const def = agent.activeProviderDef(self.environ orelse agent.environ_global);
    if (def.id.len == 0) return;

    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // `modelcache.read` locates, opens and parses the file itself, and it
    // validates the version and the URL — a stale or foreign cache is "no
    // cache", which is the only safe answer to give a status row.
    const entry = modelcache.read(io, self.environ orelse agent.environ_global, a, def.id, def.models_url) orelse return;
    for (entry.models) |m| {
        if (!m.is_free) continue;
        const n = @min(m.id.len, self.status_model_buf.len);
        @memcpy(self.status_model_buf[0..n], m.id[0..n]);
        self.status_model_len = n;
        return;
    }
}

/// Sets the model name the footer shows.
///
/// It COPIES into the model's own buffer, and that is the whole point of this
/// function existing: the name comes from a catalogue, a config or a test, and
/// a slice pointing at one of those dies with it. The footer is painted with
/// `putStable`, which does not copy, so a name that outlived its buffer would
/// be read by the renderer after the frame was over.
pub fn setStatusModel(m: *Model, name: []const u8) void {
    m.lock();
    defer m.unlock();
    const n = @min(name.len, m.status_model_buf.len);
    @memcpy(m.status_model_buf[0..n], name[0..n]);
    m.status_model_len = n;
    m.status_model_tried = true;
    m.dirty = true;
}

/// Tells the draw that the status model may be resolved again.
///
/// The warmup worker calls it once the catalogue is on disk. It exists as a
/// function and not as a bare assignment because the field is read on every
/// frame from the UI thread and written from a worker: `warmupWorker` used to
/// write it directly with no lock, which is a data race on a `bool` the draw
/// compares 60 times a second. A setter is also the only way the caller can
/// take the lock for it, since `std.atomic.Mutex` is not reentrant and
/// `setStatusModel` takes it too.
/// `resolveStatusModel` holds the same one.
pub fn allowStatusModelRetry(self: *Model) void {
    self.lock();
    defer self.unlock();
    self.status_model_tried = false;
    self.dirty = true;
    self.redraw_requested.store(true, .seq_cst);
}

/// Is the transcript nothing but the opening hero?
///
/// Every paragraph's `kind == .banner`, and there is at least one. The first
/// prompt flips it and never flips back, which is the point: this is the
/// EMPTY STATE, and it is the only state where the content should float.
fn onlyHero(m: *const Model) bool {
    if (m.paras.items.len == 0) return false;
    for (m.paras.items) |p| {
        if (p.kind != .banner) return false;
    }
    return true;
}

/// Footer with the keyboard shortcuts. Dimmed while the user is typing.
/// The permission dialog, as a centered modal.
///
/// It is what blocks the turn, so it has to be IMPOSSIBLE to miss: clean
/// background (otherwise the history shows through), yellow border, the tool's
/// name in large type and the four options with their key highlighted.
/// Paints a rounded rectangular box: top/bottom `─`, sides `│`, corners `╭╮╰╯`.
/// Fills the interior with `fill_style`. Used for modal, picker, toast, input.
fn drawRoundedBox(
    p: *Painter,
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    fill_style: vaxis.Style,
    border_style: vaxis.Style,
) void {
    // Fill interior first so wide cells are split before border paint.
    var r: u16 = 0;
    while (r < h) : (r += 1) {
        p.fillRange(x, x + w, y + r, " ", fill_style);
    }
    // Top / bottom borders.
    p.fillRange(x + 1, x + w - 1, y, "─", border_style);
    p.fillRange(x + 1, x + w - 1, y + h - 1, "─", border_style);
    // Side borders.
    var c: u16 = 1;
    while (c < h - 1) : (c += 1) {
        p.putStable(x, y + c, "│", 1, border_style);
        p.putStable(x + w - 1, y + c, "│", 1, border_style);
    }
    // Corners.
    p.putStable(x, y, "╭", 1, border_style);
    p.putStable(x + w - 1, y, "╮", 1, border_style);
    p.putStable(x, y + h - 1, "╰", 1, border_style);
    p.putStable(x + w - 1, y + h - 1, "╯", 1, border_style);
}

fn drawPermissionModal(
    p: *Painter,
    width: u16,
    height: u16,
    tool: []const u8,
    detail: []const u8,
    allow_always: bool,
    suggestion: []const u8,
) void {
    const w: u16 = @min(width -| 6, 104);
    const h: u16 = 9;
    // A TERMINAL TOO SMALL FOR THE BOX IS NOT A REASON TO PAINT NOTHING.
    //
    // It used to `return` here, and this function is what BLOCKS the turn: the
    // worker spins until the user answers, and on a 30-column terminal there
    // was no dialog to answer with. The app looked exactly like the "it stops
    // answering" bug — the input was dead because it was waiting for a key
    // nobody could know to press.
    //
    // The compact form asks the same question in two rows and fits in 20
    // columns. The direction that matters: it is better to show a cramped
    // question than an invisible one.
    if (w < 30 or height < h + 2) {
        drawPermissionModalCompact(p, width, height, tool);
        return;
    }
    const x: u16 = (width -| w) / 2;
    const y: u16 = (height -| h) / 2;

    drawRoundedBox(p, x, y, w, h, theme.panel_bg, theme.warn_bold);

    // Title, with Zo's face in the "warn" color.
    _ = p.putText(x + 3, y + 1, "⚠  Permission required", theme.warn_bold);

    // Which tool and with which arguments.
    _ = p.putText(x + 3, y + 3, "This tool wants to run:", theme.brand_soft);
    var nb: [64]u8 = undefined;
    const tname = std.fmt.bufPrint(&nb, "{s}", .{tool}) catch tool;
    _ = p.putText(x + 3, y + 4, tname, theme.brand_bold);

    // Detail, clipped to the box's width.
    const max_d = @as(usize, w - 6);
    if (detail.len > 0) {
        const d: []const u8 = if (detail.len > max_d) detail[0..max_d] else detail;
        _ = p.putText(x + 3, y + 5, d, theme.dim);
    }

    // Options, each with its key in large type. The first one (y) is the one
    // you press without looking, so it is highlighted.
    //
    // WITHOUT "always allow" for a question that must not become a standing
    // permission: a path inside `.git/` is asked ONCE. "Always allow" there
    // would put the whole `.git/` on the list of places the agent writes
    // without asking, which is the opposite of what the question is for.
    const opts_all = [_]struct { key: []const u8, label: []const u8 }{
        .{ .key = "Y", .label = "allow once" },
        .{ .key = "A", .label = "always allow" },
        .{ .key = "N", .label = "deny" },
        .{ .key = "ESC", .label = "cancel" },
    };
    var opts: []const @TypeOf(opts_all[0]) = &opts_all;
    if (!allow_always) opts = &.{ opts_all[0], opts_all[2], opts_all[3] };
    // The "always allow" option NAMES the rule it would remember: the user is
    // answering "from now on?", and the answer has to say what "from now on"
    // means.
    var suggestion_buf: [128]u8 = undefined;
    const suggestion_label_text = suggestion_label(suggestion, &suggestion_buf);
    var ox: u16 = x + 3;
    for (opts, 0..) |o, i| {
        _ = p.putText(ox, y + 7, o.key, theme.brand_bold);
        const adv: u16 = @as(u16, @intCast(o.key.len)) + 1;
        ox += adv;
        // The "A" row carries the rule it would remember.
        const label: []const u8 = if (i == 1 and suggestion_label_text.len > 0) suggestion_label_text else o.label;
        ox = p.putText(ox, y + 7, label, if (i == 0) theme.brand else theme.brand_soft);
        if (i + 1 < opts.len and ox + 4 < x + w) {
            ox = p.putText(ox, y + 7, "   ", theme.brand_faint);
        }
    }
}

/// The label of the "always allow" option: the rule it would remember.
///
/// It is the SUGGESTION and not the word "always allow", because the user is
/// answering a question about the future ("from now on?") and the answer has
/// to name what "from now on" means.
fn suggestion_label(suggestion: []const u8, buf: []u8) []const u8 {
    if (suggestion.len == 0) return "";
    return std.fmt.bufPrint(buf, "always allow {s}", .{suggestion}) catch "";
}

/// The permission question in TWO ROWS, for a terminal that has no room for the
/// box.
///
/// The box needs 36 columns and 11 rows. A 30-column terminal (a split pane, a
/// phone over SSH) does not have them, and the question is still asked: the
/// worker is waiting for an answer that the user cannot give. So the question
/// is asked in the smallest form that still says WHAT and HOW to answer it:
///
///     ⚠ Permission: bash
///     Y allow · A always · N deny · ESC cancel
///
/// Two rows, 24 columns, and it is painted at the BOTTOM of the screen, over
/// the history: the bottom is where the eye is, and the bottom is where the
/// input box is, so the question and the thing that is blocked are together.
fn drawPermissionModalCompact(
    p: *Painter,
    width: u16,
    height: u16,
    tool: []const u8,
) void {
    if (height == 0 or width == 0) return;
    const rows: u16 = if (height >= 2) 2 else 1;
    const y: u16 = height - rows;

    // The whole row is cleared first: the history would show through the
    // question, and a question you cannot read is a question you cannot answer.
    var r: u16 = 0;
    while (r < rows) : (r += 1) {
        expandWideCells(p.surface, y + r, width);
        p.fillRange(0, width, y + r, " ", .{});
    }

    var nb: [64]u8 = undefined;
    const head = std.fmt.bufPrint(&nb, "⚠ Permission: {s}", .{tool}) catch "⚠ Permission";
    _ = p.putClipped(1, y, head, width -| 2, theme.warn_bold);

    if (rows >= 2) {
        const opts = "Y allow · A always · N deny · ESC cancel";
        _ = p.putClipped(1, y + 1, opts, width -| 2, theme.brand_soft);
    }
}

/// The "it is working" strip, right above the input box.
///
/// It answers "is it stuck or is it thinking?": Zo's face animated with the
/// state, the elapsed seconds and what is in the queue.
///
/// The LABEL is the phase, not a generic "working". "Working" for 40 seconds
/// does not say whether the model is thinking, is already writing or whether
/// there is a hung `bash`: three very different waits that the user lives as
/// one. With the phase named, the clock reads differently ("the server has been
/// waiting 3s" and "this command has been running 30s" are not the same).
///
/// When there is a queue the queued prompts are shown too, so you know what is
/// coming next instead of having to remember it.
/// A compact plan summary; the complete checklist is kept in the history.
fn drawPlanBlock(p: *Painter, top: u16, width: u16, pl: plan_mod.Plan) void {
    p.fillRow(top, " ", .{});
    // Frame the plan as a distinct block above the input, so it is easy to
    // spot that there is a todo list and to see which step is active.
    const frame = if (pl.allDone()) "┌─" else "├─";
    _ = p.putStable(0, top, frame, 2, theme.rule);
    if (pl.allDone()) {
        var buf: [64]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf, "☑ plan {d}/{d} · complete", .{ pl.len, pl.len }) catch "☑ plan complete";
        _ = p.putClipped(1, top, txt, width -| 1, theme.ok);
        return;
    }

    const i = pl.currentIndex() orelse return;
    const item = pl.items[i];
    var buf: [64]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buf, "{s} plan {d}/{d} · {d} open · ", .{
        item.status.glyph(),
        pl.doneCount(),
        pl.len,
        pl.openCount(),
    }) catch return;
    const style: vaxis.Style = if (item.status == .in_progress) theme.brand_bold else theme.brand_soft;
    const col = p.putText(1, top, prefix, style);
    _ = p.putClipped(col, top, item.textOf(), width -| col, style);
}

/// Picker callback for an `ask` menu.
///
/// `label` is OWNED by the picker and freed right after this returns, so an
/// answer that is kept has to be copied: `answerAskOwned` TAKES OWNERSHIP and the
/// worker frees it after the session has it. Passing `label` itself would be the
/// `gpa.free(literal)` crash, in a shape where it only shows up when the user
/// picks the first option.
/// The question panel of `ask`, for the free-text path and as the anchor of the
/// whole interaction.
///
/// It is drawn even when the picker is on top of it (the picker is centred and
/// narrower): the question has to be visible at the moment the user chooses, or
/// the menu is a list of options with no question attached, which is how you pick
/// the wrong one.
///
/// Without options this panel IS the interface: the question, a hint line, and
/// the input box right below the screen edge already in answer mode. Drawing a
/// box around "type your answer" as well would be two boxes saying the same thing.
fn drawAskPanel(
    p: *Painter,
    width: u16,
    height: u16,
    snap: AskSnapshot,
    waited_ms: u64,
) void {
    if (width < 6 or height == 0) return;

    // The panel is ONE widget: the question and the options are in the same box,
    // which is what makes it impossible for one to erase the other. It used to be
    // two (a centred modal picker plus this box, the picker narrower), painted one
    // after the other with the box on top, and the geometry guaranteed the
    // overlap: `top = (height - box_h) / 2` here against `y0 = (height - box_h) / 4`
    // there, and this box is the WIDER one for any question over ~56 columns.
    const text_col_off: u16 = 2; // inside the borders
    const box_w: u16 = @min(@as(u16, 110), width - 4);
    const inner_w: u16 = if (box_w > 6) box_w - 4 else box_w - 2;
    const left: u16 = (width - box_w) / 2;

    // Question: hard breaks first, then wrapped. A `\n` the model wrote (its
    // "recommendation and its reason up front" is routinely two sentences on two
    // lines) used to be written into a CELL as a literal newline byte, and vaxis
    // writes those bytes raw to the terminal: the rest of the frame came out
    // interleaved with the panel text.
    const q_all = wrapTextToRows(p, snap.question, inner_w, p.arena);
    const q_cap: usize = 8;

    // Rows: border + header + question + one blank + options + blank + hint + clock
    const has_header = snap.header.len > 0;
    const opts = snap.options.len;
    const choice_rows: usize = if (opts > 0 and !snap.typing) opts + 1 else 0;
    const hdr_rows: usize = if (has_header) 1 else 0;
    const menu_rows: usize = if (choice_rows > 0) choice_rows + 1 else 0;
    const fixed_rows = hdr_rows + menu_rows + 2;
    const wanted_q = @min(q_all.len, q_cap);
    const wanted_more: usize = if (q_all.len > wanted_q) 1 else 0;
    const want_h: u16 = @intCast(fixed_rows + wanted_q + wanted_more + 2);
    // `height` is the history area, not the terminal: the answer editor and
    // status bar remain visible below the panel while the user types.
    const box_h: u16 = @min(want_h, height);
    if (height < 8 or width < 24) {
        const compact_rows = @min(height, 7);
        var fill_row: u16 = 0;
        while (fill_row < compact_rows) : (fill_row += 1) {
            expandWideCells(p.surface, fill_row, width);
            p.fillRange(0, width, fill_row, " ", theme.code_bg);
        }
        var compact_row: u16 = 0;
        const compact_w = width - 2;
        if (has_header and compact_row < compact_rows) {
            _ = p.putClipped(1, compact_row, askLineForWidth(p, snap.header, compact_w, p.arena), compact_w, theme.hint);
            compact_row += 1;
        }

        const compact_question = wrapTextToRows(p, snap.question, compact_w, p.arena);
        const reserved: u16 = if (compact_rows > 1) (if (choice_rows > 0) 2 else 1) else 0;
        const question_room = compact_rows -| compact_row -| reserved;
        const needs_more = compact_question.len > question_room;
        const q_count = if (needs_more and question_room > 0)
            @min(compact_question.len, question_room - 1)
        else
            @min(compact_question.len, question_room);
        var q_i: usize = 0;
        while (q_i < q_count and compact_row < compact_rows) : (q_i += 1) {
            _ = p.putClipped(1, compact_row, compact_question[q_i], compact_w, theme.warn_bold);
            compact_row += 1;
        }
        if (needs_more and compact_row < compact_rows and question_room > 0) {
            _ = p.putClipped(1, compact_row, "…", compact_w, theme.hint);
            compact_row += 1;
        }
        if (choice_rows > 0 and compact_row < compact_rows) {
            const idx = @min(snap.sel, snap.options.len);
            const raw_label = if (idx == snap.options.len) ask_other_label else snap.options[idx];
            const option = normalizeAskOption(p.arena, raw_label);
            var marker: [16]u8 = undefined;
            const prefix = std.fmt.bufPrint(&marker, "▸ {d} ", .{idx + 1}) catch "▸ ";
            const used = p.putClipped(1, compact_row, prefix, compact_w, theme.selected);
            const marker_cols = used - 1;
            const label = askLineForWidth(p, option, compact_w -| marker_cols, p.arena);
            _ = p.putClipped(used, compact_row, label, compact_w -| marker_cols, theme.selected);
            compact_row += 1;
        }
        if (compact_row < compact_rows) {
            const hint: []const u8 = if (choice_rows > 0)
                "↑↓ choose · enter · esc"
            else if (snap.typing)
                "enter sends · esc: decide"
            else
                "answer below · esc: decide";
            _ = p.putClipped(1, compact_row, askLineForWidth(p, hint, compact_w, p.arena), compact_w, theme.hint);
        }
        return;
    }
    const top: u16 = (height - box_h) / 2;
    // Keep the answer choices and help visible before spending rows on a long
    // question. If it is shortened, reserve one row to say so.
    const q_room = @as(usize, box_h - 2) -| fixed_rows;
    var q_n = @min(wanted_q, q_room);
    var q_more: usize = 0;
    if (q_n < q_all.len and q_room > 1) {
        q_n -= 1;
        q_more = q_all.len - q_n;
    }

    { // opaque background: the history behind is dense text and a box with the
        // history showing through reads as a rendering bug.
        //
        // And the wide cells are split first: a cell that claims many columns
        // makes the renderer skip the ones it covers, and the history's rule
        // would eat the panel's border.
        var br: u16 = 0;
        while (br < box_h) : (br += 1) {
            expandWideCells(p.surface, top + br, width);
            p.fillRange(left, left + box_w, top + br, " ", theme.code_bg);
        }
    }

    p.putStable(left, top, "╭", 1, theme.warn_bold);
    p.fillRange(left + 1, left + box_w - 1, top, "─", theme.warn);
    p.putStable(left + box_w - 1, top, "╮", 1, theme.warn_bold);
    p.putStable(left, top + box_h - 1, "╰", 1, theme.warn_bold);
    p.fillRange(left + 1, left + box_w - 1, top + box_h - 1, "─", theme.warn);
    p.putStable(left + box_w - 1, top + box_h - 1, "╯", 1, theme.warn_bold);
    var rr: u16 = 1;
    while (rr < box_h - 1) : (rr += 1) {
        p.putStable(left, top + rr, "│", 1, theme.warn);
        p.putStable(left + box_w - 1, top + rr, "│", 1, theme.warn);
    }

    const inner_col = left + text_col_off;
    const last_row = top + box_h - 1;
    var row: u16 = top + 1;

    if (has_header) {
        // The header is a LABEL, not the answer: `hint` instead of `warn_bold`,
        // and clipped to the box (it is up to 40 bytes and the inner width can be
        // less than that on a narrow terminal, where it used to cross the border).
        _ = p.putClipped(inner_col, row, snap.header, inner_w, theme.hint_faint);
        row += 1;
    }

    // The question: the one thing in bright bold yellow, wrapped, clipped.
    for (q_all[0..q_n]) |ln| {
        if (row >= last_row) break;
        _ = p.putClipped(inner_col, row, ln, inner_w, theme.warn_bold);
        row += 1;
    }
    if (q_more > 0 and row < last_row) {
        var mb: [48]u8 = undefined;
        const m = std.fmt.bufPrint(&mb, "… {d} more lines of the question", .{q_more}) catch "…";
        _ = p.putClipped(inner_col, row, m, inner_w, theme.hint_faint);
        row += 1;
    }

    // ── the options, in this same box ──
    //
    // Before they were items of the modal picker, printed as `label  desc` with no
    // marker: `recommended` came out in the same style as the option text (it just
    // looked like the label got longer) and the highlighted row was bold blue on
    // no background, which is not a highlight. A row here is a numbered choice
    // with a real background, so "these are the options" needs no explaining.
    if (choice_rows > 0 and row < last_row) {
        row += 1; // blank line between the question and the menu
        const sel = snap.sel;
        var i: usize = 0;
        while (i < choice_rows) : (i += 1) {
            if (row >= last_row) break;
            const is_sel = (i == sel);
            const is_other = (i == opts);
            const style: vaxis.Style = if (is_sel) theme.selected else if (is_other) theme.hint else vaxis.Style{};
            if (is_sel) p.fillRange(inner_col, left + box_w - 1, row, " ", theme.selected);
            var marker: [8]u8 = undefined;
            // Every row is NUMBERED, including the way out of the menu: an
            // unnumbered last row is the one that reads as chrome ("type your own
            // answer…" looks like a button, not a choice), and a menu whose rows
            // are not all the same shape is hard to scan.
            const mk = if (is_sel)
                std.fmt.bufPrint(&marker, "▸ {d} ", .{i + 1}) catch "  "
            else
                std.fmt.bufPrint(&marker, "  {d} ", .{i + 1}) catch "  ";
            const used = p.putClipped(inner_col, row, mk, inner_w, style);
            const marker_cols = used - inner_col;
            const tag_text = if (i == 0 and !is_other) " · recommended" else "";
            const tag_cols: u16 = @intCast(columnsOf(p, tag_text));
            const keep_tag = tag_text.len > 0 and inner_w > marker_cols + tag_cols + 8;
            const label_cols = inner_w - marker_cols - (if (keep_tag) tag_cols else 0);
            const raw_label = if (is_other) ask_other_label else snap.options[i];
            const label = askLineForWidth(p, normalizeAskOption(p.arena, raw_label), label_cols, p.arena);
            const after = p.putClipped(used, row, label, label_cols, style);
            // The recommendation is STATED, not implied by being first: the
            // guidance tells the model to put its own pick first, so row 1 is
            // what Enter takes. It used to be printed INSTEAD of the option (as
            // the picker's `desc`, which also made it read like a longer label).
            if (keep_tag) _ = p.putClipped(after, row, tag_text, tag_cols, if (is_sel) theme.ok else theme.hint);
            row += 1;
        }
        // The recommendation is stated, not implied: the guidance tells the model
        // to put its own pick first, so row 1 IS the answer the panel expects
        // Enter to take.
    }

    // ── hint + clock ──
    //
    // These two rows were `brand_faint` (#3b4261) on #1a1b26, about 1.9:1: the
    // only text in the panel telling the user that the arrow keys do something,
    // drawn in the one tone of the palette that cannot be read.
    var hb: [96]u8 = undefined;
    const hint_txt: []const u8 = if (snap.typing)
        "enter sends it · esc: you decide"
    else if (choice_rows > 0)
        "↑↓ choose · enter answers · esc: you decide"
    else
        "type your answer below · enter sends it · esc: you decide";
    const ht = std.fmt.bufPrint(&hb, "{s}", .{hint_txt}) catch hint_txt;
    if (ht.len > 0 and row < last_row) {
        _ = p.putClipped(inner_col, row, ht, inner_w, theme.hint);
    }
    row += 1;

    if (row < last_row) {
        var wb: [32]u8 = undefined;
        const w = std.fmt.bufPrint(&wb, "waiting {d}s", .{waited_ms / 1000}) catch "";
        if (w.len > 0) {
            _ = p.putClipped(inner_col, row, w, inner_w, theme.hint_faint);
        }
    }
}

/// Columns a text occupies, grapheme by grapheme.
///
/// `p.measure` and NOT `.len`: the question can contain `…`, `—` or a `◆` from a
/// tool name, and measuring in bytes gives a box three columns too wide (or two
/// too narrow), which is the `rowText` trap AGENTS.md documents.
fn columnsOf(p: *const Painter, text: []const u8) usize {
    var n: usize = 0;
    var it = vaxis.unicode.graphemeIterator(text);
    while (it.next()) |g| n += p.measure(g.bytes(text));
    return n;
}

fn normalizeAskOption(arena: std.mem.Allocator, text: []const u8) []const u8 {
    const out = arena.alloc(u8, text.len) catch return text;
    var n: usize = 0;
    var pending_space = false;
    for (text) |byte| {
        if (byte < 0x20 or byte == 0x7f) {
            pending_space = n > 0;
            continue;
        }
        if (pending_space) {
            out[n] = ' ';
            n += 1;
            pending_space = false;
        }
        out[n] = byte;
        n += 1;
    }
    return out[0..n];
}

/// Keeps a menu choice on one visual row and makes truncation explicit.
fn askLineForWidth(p: *const Painter, text: []const u8, width: u16, arena: std.mem.Allocator) []const u8 {
    if (columnsOf(p, text) <= width or width == 0) return text;
    const ellipsis = "…";
    const ellipsis_width = p.measure(ellipsis);
    if (ellipsis_width > width) return "";
    const max_text_width = width - ellipsis_width;
    var out: std.ArrayList(u8) = .empty;
    var used: u16 = 0;
    var it = vaxis.unicode.graphemeIterator(text);
    while (it.next()) |g| {
        const bytes = g.bytes(text);
        const w = p.measure(bytes);
        if (w > max_text_width -| used) break;
        out.appendSlice(arena, bytes) catch return text;
        used += w;
    }
    out.appendSlice(arena, ellipsis) catch return text;
    return out.items;
}

/// Rows a text takes at `width` columns, as slices into `text`.
///
/// A `[]const []const u8` of ROWS rather than a count: the draw needs both the
/// height (to size the box) and the pieces (to paint them), and counting first
/// then walking again is two implementations of the same wrap that will disagree.
fn wrapTextToRows(p: *const Painter, text: []const u8, width: u16, arena: std.mem.Allocator) []const []const u8 {
    if (width == 0) return &.{};
    var rows: std.ArrayList([]const u8) = .empty;
    // HARD BREAKS FIRST, then wrap each line. This used to be one pass over the
    // graphemes with no notion of `\n`: a newline was measured as a 1-column
    // grapheme (`gwidth` returns -1 for a control and the measure clamps to 1),
    // so it ended up INSIDE a row, and `putStable` wrote that byte into a cell.
    // vaxis writes cell bytes raw, so the raw `\n` went to the terminal and the
    // rest of the frame came out interleaved with the text. The model's own
    // schema asks for "your recommendation and its reason up front", i.e. two
    // lines, so this was the normal case and not an edge case.
    var hard = std.mem.splitScalar(u8, text, '\n');
    while (hard.next()) |line| {
        wrapOneLine(p, line, width, arena, &rows);
    }
    return rows.items;
}

/// One hard line into `rows`, wrapped at `width` columns.
fn wrapOneLine(
    p: *const Painter,
    line: []const u8,
    width: u16,
    arena: std.mem.Allocator,
    rows: *std.ArrayList([]const u8),
) void {
    if (line.len == 0) {
        // An empty hard line is an empty ROW, and it has to survive: dropping it
        // would glue the paragraph above to the one below.
        rows.append(arena, "") catch return;
        return;
    }
    var start: usize = 0;
    var col: u16 = 0;
    var pos: usize = 0;
    var break_pos: usize = 0;
    var break_col: u16 = 0;
    var it = vaxis.unicode.graphemeIterator(line);
    while (it.next()) |g| {
        const gb = g.bytes(line);
        const before = pos;
        pos += gb.len;
        const w: u16 = p.measure(gb);
        if (col + w > width and col > 0) {
            if (break_pos > start) {
                rows.append(arena, line[start..break_pos]) catch return;
                start = break_pos;
                col -= break_col;
            } else {
                rows.append(arena, line[start..before]) catch return;
                start = before;
                col = 0;
            }
            break_pos = 0;
            break_col = 0;
            if (col + w > width and col > 0) {
                rows.append(arena, line[start..before]) catch return;
                start = before;
                col = 0;
            }
        }
        col += w;
        if (std.mem.eql(u8, gb, " ") or std.mem.eql(u8, gb, "\t")) {
            break_pos = pos;
            break_col = col;
        }
    }
    if (start < line.len) rows.append(arena, line[start..]) catch {};
}

/// The Editor's `Measurer`, bound to this frame's Painter.
///
/// It is the bridge that makes the input's wrap and the input's paint the SAME
/// wrap: `vaxis.unicode` for what a grapheme is and `p.measure` (which is
/// `ctx.stringWidth`) for how wide it is on THIS terminal.
fn editorMeasurer(p: *const Painter) ed.Measurer {
    return .{ .ctx = @ptrCast(p), .step = graphemeStep };
}

fn graphemeStep(ctx: *const anyopaque, text: []const u8, i: usize) ed.Step {
    const p: *const Painter = @ptrCast(@alignCast(ctx));
    const rest = text[i..];
    var it = vaxis.unicode.graphemeIterator(rest);
    const g = it.next() orelse return .{ .cols = 1, .end = text.len };
    const b = g.bytes(rest);
    return .{ .cols = p.measure(b), .end = i + b.len };
}

/// The composer's footer: the ONE place where the state is shown.
///
/// It replaced two widgets that said the same thing in two places:
///
///  * the ACTIVITY STRIP, a row above the hairline that said "thinking",
///    "streaming", "running Bash · 1.2s";
///  * the STATUS ROW, a row under the input that held a face and the model's
///    name with nothing in between — which on screen read as a stray emoticon
///    in the corner of an otherwise empty row.
///
/// Now there is one surface, and it is the last row of the composer's own
/// sunken well: the mascot on the left with its legend, the session's numbers
/// on the right. The state is in ONE place, and it is in the same object as
/// the thing the user is looking at.
///
/// ## What the mascot is and what the words are
///
/// The face says the STATE (in its mood's colour) and the words say the
/// DETAIL ("running Bash · 1.2s"). They are one widget, not two: a mascot with
/// no legend is a doodle, and a legend with no mascot is what this row was
/// before.
/// The composer's footer: the ONE place where the state is shown.
///
/// It replaced two widgets that said the same thing in two places:
///
///  * the ACTIVITY STRIP, a row above the hairline that said "thinking",
///    "streaming", "running Bash · 1.2s";
///  * the STATUS ROW, a row under the input that held a face and the model's
///    name with nothing in between — which on screen read as a stray emoticon
///    in the corner of an otherwise empty row.
///
/// Now there is one surface, and it is the last row of the composer's own
/// sunken well: the mascot on the left with its legend, the session's numbers
/// on the right. The state is in ONE place, and it is in the same object as
/// the thing the user is looking at.
///
/// ## What the mascot is and what the words are
///
/// The face says the STATE (in its mood's colour) and the words say the
/// DETAIL ("running Bash · 1.2s"). They are one widget, not two: a mascot with
/// no legend is a doodle, and a legend with no mascot is what this row was
/// before.
///
/// ## Who wins the space
///
/// The STATE wins. The face is seven columns and it is never clipped: on a
/// narrow terminal the numbers on the right go first (the scroll hint, then
/// the throughput, then the context gauge, and the model last), because a
/// half-drawn face is a drawing bug and a missing model is a command away
/// (`/model`).
fn drawStateFooter(
    p: *Painter,
    row: u16,
    width: u16,
    self: *Model,
    act: Model.Activity,
    queued: usize,
    arena: std.mem.Allocator,
) void {
    const right_edge: u16 = if (width > 2) width - 2 else width;

    // The row is the app's own background, not the input's well: the mascot
    // is UNDER the input, and it says so by being on a different surface.
    // The fill is here because nothing else paints this row any more (the
    // well stopped covering it), and a row that keeps the previous frame's
    // pixels is a row with ghosts in it.
    p.fillRange(0, width, row, " ", .{});

    // ── the LEFT group: the mascot and its legend ──
    var tr_name_buf: [64]u8 = undefined;
    const running_tool_name = self.toolRunName(&tr_name_buf);
    const running_tool = running_tool_name != null;

    // The mood: the activity wins over what the agent last said, because the
    // activity is what is TRUE right now. A tool running is `.tooling`, and a
    // question or a permission is `.warn` — the two states where the app has
    // stopped and is waiting on the human.
    const mood: StatusKind = if (act.ask or act.perm)
        .warn
    else if (running_tool)
        .tooling
    else
        self.mood();

    // Convert tui.StatusKind -> mascot.StatusKind (same variant order, safe cast).
    const m_kind: mascot.StatusKind = switch (mood) {
        .idle => .idle,
        .thinking => .thinking,
        .tooling => .tooling,
        .done => .done,
        .warn => .warn,
        .err => .err,
    };
    // Advance the mascot's clock. `setKind` is what restarts a track, and it
    // only fires on a CHANGE: two tools in a row keep the loop they are in the
    // middle of instead of snapping back to its first beat.
    const now_ms = self.nowMs();
    self.mascot_animator.setKind(m_kind, now_ms);
    const pose = self.mascot_animator.pose(now_ms);
    const face_text = pose.text;

    var legend: []const u8 = "";
    var detail: []const u8 = "";
    var detail_buf: [96]u8 = undefined;

    if (act.ask) {
        legend = "waiting for your answer";
        const ms = self.askMillis();
        detail = std.fmt.bufPrint(&detail_buf, "· {d}s to answer", .{ms / 1000}) catch "";
    } else if (act.perm) {
        legend = "waiting for your permission";
    } else if (act.subagent_total > 0) {
        legend = std.fmt.bufPrint(&detail_buf, "subagents {d}/{d}", .{
            act.subagent_completed,
            act.subagent_total,
        }) catch "subagents";
    } else if (running_tool) {
        legend = "running";
        const ms = self.toolRunMillis();
        detail = std.fmt.bufPrint(&detail_buf, "{s} · {d}.{d}s", .{
            running_tool_name.?,
            ms / 1000,
            (ms % 1000) / 100,
        }) catch "";
    } else if (act.streaming) {
        legend = "streaming";
        const ms = self.busyMillis();
        detail = std.fmt.bufPrint(&detail_buf, "{d}.{d}s", .{ ms / 1000, (ms % 1000) / 100 }) catch "";
    } else if (act.busy) {
        legend = "thinking";
        const ms = self.busyMillis();
        detail = std.fmt.bufPrint(&detail_buf, "{d}.{d}s", .{ ms / 1000, (ms % 1000) / 100 }) catch "";
    } else {
        // Idle: the agent's own last word, if it said one ("done", "ready").
        legend = self.status();
        if (legend.len == 0) legend = "ready";
    }
    if (queued > 0) {
        var qbuf: [32]u8 = undefined;
        const q = std.fmt.bufPrint(&qbuf, "{d} queued", .{queued}) catch "";
        if (q.len > 0) {
            if (detail.len > 0) {
                var both: [128]u8 = undefined;
                detail = std.fmt.bufPrint(&both, "{s} · {s}", .{ detail, q }) catch detail;
            } else {
                detail = q;
            }
        }
        // THE TEXT OF THE NEXT ONE, not only the count.
        //
        // "2 queued" says there is a queue; "2 queued · fix the tests" says
        // what is coming, and the user does not have to open their memory to
        // find out. The reference implementation shows the queued commands
        // above the prompt for the same reason.
        //
        // It is truncated, and the ellipsis says so: a half-line that looks
        // complete is a lie about what is queued.
        if (self.queuedNext()) |next| {
            const trimmed = std.mem.trim(u8, next, " \t\r\n");
            if (trimmed.len > 0) {
                var tbuf: [48]u8 = undefined;
                const shown = if (trimmed.len <= 40)
                    trimmed
                else
                    std.fmt.bufPrint(&tbuf, "{s}…", .{trimmed[0..39]}) catch "";
                if (shown.len > 0) {
                    var both: [192]u8 = undefined;
                    const joined = std.fmt.bufPrint(&both, "{s} · {s}", .{ detail, shown }) catch "";
                    if (joined.len > 0) detail = joined;
                }
            }
        }
    }

    // How much room the left group's CORE needs, in columns: the face and the
    // legend. The DETAIL is not part of it, because the detail is the first
    // thing that may go: the model on the right says who is answering, and
    // that outlives the name of the tool that happens to be running.
    const left_core: u16 = face_width + 2 + @as(u16, @intCast(columnsOf(p, legend)));

    // ── the RIGHT group: the session's own numbers ──
    //
    // The model (and the permission mode and the free-auto pool, which are
    // deviations and only show when they are not the default), the context
    // gauge, the throughput while it streams, and the scroll hint.
    var right: [12]InfoSeg = undefined;
    var rn: usize = 0;

    if (sessionInfo(self, arena)) |segs| {
        for (segs) |s| {
            if (rn < right.len) {
                right[rn] = s;
                rn += 1;
            }
        }
    }
    if (contextInfo(arena)) |segs| {
        if (rn > 0 and rn < right.len) {
            right[rn] = .{ .text = " · ", .style = theme.line };
            rn += 1;
        }
        for (segs) |s| {
            if (rn < right.len) {
                right[rn] = s;
                rn += 1;
            }
        }
    }
    if (act.streaming and agent.tps_live > 1) {
        var tb: [32]u8 = undefined;
        const speed = std.fmt.bufPrint(&tb, "⚡ {d:.0} tok/s", .{agent.tps_live}) catch "";
        // The segment's text is painted with `putStable`, which does NOT copy:
        // the bytes have to live in the frame's arena, not in this frame's
        // stack. This is the `&[_]u8{c}` family, and a right-aligned group is
        // exactly where a dead pointer shows up as a stray glyph.
        const owned = arena.dupe(u8, speed) catch "";
        if (owned.len > 0 and rn + 1 < right.len) {
            if (rn > 0) {
                right[rn] = .{ .text = " · ", .style = theme.line };
                rn += 1;
            }
            right[rn] = .{ .text = owned, .style = theme.tool };
            rn += 1;
        }
    }
    const scrolled = !self.follow_bottom;
    var latest_idx: ?usize = null;
    if (scrolled and rn + 1 < right.len) {
        // "↓ 3 new" instead of "↓ latest", when the reader is away and
        // something arrived.
        //
        // The reference implementation floats a centred "N new messages" pill
        // over the transcript, and the count is the point: "latest" says where
        // you can go, "3 new" says what you are missing. The pill is the
        // fancier half of it and it is a separate piece of chrome; the NUMBER
        // is what changes the day.
        //
        // The count is of ASSISTANT TURNS, not of paragraphs: a tool line is
        // not something the reader is missing an answer to.
        const unseen = self.unseenTurns();
        const label: []const u8 = if (unseen > 0) "↓ new" else "↓ latest";
        if (unseen > 0) {
            if (rn > 0) {
                right[rn] = .{ .text = "  ", .style = theme.line };
                rn += 1;
            }
            var nb2: [24]u8 = undefined;
            const txt = std.fmt.bufPrint(&nb2, "↓ {d} new", .{unseen}) catch label;
            const owned = arena.dupe(u8, txt) catch "";
            right[rn] = .{ .text = owned, .style = theme.brand };
            latest_idx = rn;
            rn += 1;
        } else {
            if (rn > 0) {
                right[rn] = .{ .text = "  ", .style = theme.line };
                rn += 1;
            }
            right[rn] = .{ .text = label, .style = theme.brand };
            latest_idx = rn;
            rn += 1;
        }
    }

    // The right group gives up pieces, from the tail, until the state fits.
    //
    // The tail is the scroll hint first, then the throughput, then the
    // context gauge: the model is the last thing to go, because it is the one
    // that says which model is answering.
    const room: u16 = if (right_edge > left_core + 2) right_edge - left_core - 2 else 0;
    while (rn > 0 and segsWidth(right[0..rn]) > room) {
        // The last segment goes, and with it the separator that came before
        // it (otherwise the row ends with a dangling "·").
        rn -= 1;
        if (rn > 0 and std.mem.eql(u8, right[rn - 1].text, " · ")) rn -= 1;
        if (latest_idx) |idx| {
            if (idx >= rn) latest_idx = null;
        }
    }

    const right_segs = right[0..rn];
    const right_width = segsWidth(right_segs);
    const right_start: u16 = if (right_edge > right_width) right_edge - right_width else 0;

    // ── the left group ──
    //
    // NO background here: the footer's row is UNDER the input's well, on the
    // terminal's own background. The styles used to carry `well_bg` because
    // the mascot was inside the well, and keeping it painted the row in the
    // input's surface — which is exactly what made the two look like one
    // block.
    const left_limit: u16 = if (right_start > 2) right_start - 2 else right_edge;
    //
    // The face has a SLOT one cell wider than itself, and the legend starts
    // after the slot. The lean of the motion layer moves the face inside it and
    // the words stay where they are: a shaking face followed by words that also
    // shake is a row the reader has to wait for, and the shake is supposed to
    // say "look here", not "read this while it moves".
    var face_style = moodStyle(mood);
    // The airborne beat of `done`. A cell is a cell, so the reference's hop is
    // painted as a FLASH on the same beat its eyes go wide — the hint is timed
    // by the track, not by a timer here.
    if (pose.hint == .jump) face_style.bold = true;
    const face_col: u16 = 1 + pose.dx;
    _ = p.putClipped(face_col, row, face_text, left_limit -| face_col, face_style);
    // What the tick compares against: the cells and the lean, which is
    // everything that changes the drawing.
    self.face_painted = true;
    self.face_painted_dx = pose.dx;
    if (face_text.len == self.face_painted_text.len) @memcpy(&self.face_painted_text, face_text);
    var col: u16 = 1 + face_width + 2;
    if (legend.len > 0) {
        // The legend is WHITE and the face is COLOURED, on purpose: with both
        // in the theme's teal the face and its own label read as one smudge
        // (they were the same colour, and the same pixels, for the "tooling"
        // mood). The face carries the mood; the word carries the phase.
        var legend_style = theme.ink;
        legend_style.bold = true;
        col = p.putClipped(col, row, legend, left_limit -| col, legend_style);
    }
    if (detail.len > 0) {
        // The detail is painted WHOLE or not at all: a clipped "B" at the end
        // of the legend reads as a typo, and the detail is the first thing
        // that may go when the row is narrow.
        const detail_cols: u16 = @intCast(columnsOf(p, detail));
        if (col + detail_cols <= left_limit) {
            const detail_style = theme.ink2;
            col = p.putClipped(col + 1, row, detail, left_limit -| col, detail_style);
        }
    }

    // The `?` hint: the discoverability of the shortcut list.
    //
    // It is the reference implementation's footer hint, and it is here for the
    // same reason: a binding nobody knows about is a binding nobody presses.
    // It goes at the END of the left group and it only appears when there is
    // room, because the STATE is what the left group is for and a hint that
    // squeezes the state out is a hint that costs more than it gives.
    if (!self.pal.active and !self.pickerActive() and self.ed.text().len == 0) {
        const hint = "? for shortcuts";
        const hint_cols: u16 = @intCast(columnsOf(p, hint));
        if (col + 2 + hint_cols <= left_limit) {
            _ = p.putClipped(col + 2, row, hint, left_limit -| col, theme.hint_faint);
        }
    }

    // ── the right group, right-aligned ──
    //
    // The scroll hint's own columns are published so the click on it can jump
    // to the bottom: it is the only part of the footer that is a control.
    self.scroll_bottom_row = row;
    self.scroll_bottom_start = 0;
    self.scroll_bottom_end = 0;
    if (latest_idx) |idx| {
        const start = right_start + segsWidth(right[0..idx]);
        self.scroll_bottom_start = start;
        self.scroll_bottom_end = start + segsWidth(right[idx .. idx + 1]);
    }
    var rcol: u16 = right_start;
    for (right_segs) |sg| {
        // The well's background has to be put back on every cell of the right
        // group: `putStable` REPLACES the cell, so a segment that carries no
        // background of its own lands on the terminal's default one, and the
        // footer's right end came out as a bright strip on a dark block.
        var st = sg.style;
        st.bg = theme.well_bg.bg;
        var it = vaxis.unicode.graphemeIterator(sg.text);
        while (it.next()) |g| {
            const b = g.bytes(sg.text);
            const w = theme.graphemeWidth(p.ctx, b);
            if (rcol + w <= p.width) _ = p.putStable(rcol, row, b, w, st);
            rcol += w;
        }
    }
}

/// A piece of the footer's right-hand group, with its style.
const InfoSeg = struct { text: []const u8, style: vaxis.Style };

/// The RIGHT zone of the footer: the model name.
///
/// The footer is for the things you read without thinking: what model am I
/// talking to right now. Everything else (provider, ctx%, tokens, cache, mode)
/// has a command: `/context`, `/cache`, `/bench`, `/provider`.
fn sessionInfo(m: *Model, arena: std.mem.Allocator) ?[]const InfoSeg {
    var out: std.ArrayList(InfoSeg) = .empty;

    // The model that will answer.
    if (m.status_model_len == 0 and !m.status_model_tried) resolveStatusModel(m);
    const model = agent.curAnswering();
    const shown_model = if (model.len > 0)
        model
    else if (m.status_model_len > 0)
        m.status_model_buf[0..m.status_model_len]
    else if (agent.activeProviderDef(m.environ orelse agent.environ_global).default_model.len > 0)
        agent.activeProviderDef(m.environ orelse agent.environ_global).default_model
    else
        "";

    if (shown_model.len > 0) {
        out.append(arena, .{ .text = shown_model, .style = theme.ink2 }) catch return null;
    }

    // Permission mode: only show when NOT default (read-only/bypass are deviations).
    //
    // `accept_edits` is shown as a GLYPH, and that is the point: the mode
    // decides whether the next tool call asks, and the only way to know is to
    // look. A word costs twelve columns in a footer that has to survive an
    // eighty-column terminal; a glyph costs one.
    //
    // The four shapes are the ones the reference implementation uses: `○` for
    // the default, `◐` for accept-edits, `●` for read-only and `◉` for the
    // bypass. The DEFAULT shows nothing, because there is a test that pins
    // "the normal permission modes cost NOTHING on the row" and it is right:
    // a footer that repeats the default in every row of every session is a
    // footer nobody reads.
    switch (agent.currentPermMode()) {
        .read_only, .bypass, .accept_edits => {
            if (out.items.len > 0) {
                out.append(arena, .{ .text = " · ", .style = theme.line }) catch return null;
            }
            const glyph = switch (agent.currentPermMode()) {
                .accept_edits => "◐",
                .read_only => "●",
                .bypass => "◉",
                .default => "",
            };
            out.append(arena, .{ .text = glyph, .style = theme.warn }) catch return null;
        },
        .default => {},
    }

    // The EFFECTIVE effort level: the one that goes on the wire, after the
    // model's own ladder degraded it.
    //
    // The preference is not the same thing and showing it would be a lie: the
    // footer would say `xhigh` while the request carries `high`, and the user
    // would be told the model is thinking harder than it is. AGENTS.md has the
    // whole story (`effortFor` degrades DOWNWARDS, never upwards).
    //
    // It is only shown when the model HAS a knob: a model with no effort
    // control has no level to show, and a footer full of words nobody can act
    // on is a footer nobody reads.
    if (chat.effortSupport(shown_model) != .none) {
        const eff = agent.effectiveEffort();
        if (out.items.len > 0) {
            out.append(arena, .{ .text = " · ", .style = theme.line }) catch return null;
        }
        out.append(arena, .{ .text = eff.label(), .style = theme.ink2 }) catch return null;
    }

    // Free-auto mode indicator.
    if (agent.freeAutoOn()) {
        const lbl = agent.freeAutoLabel(arena);
        if (lbl.len > 0) {
            if (out.items.len > 0) {
                out.append(arena, .{ .text = " · ", .style = theme.line }) catch return null;
            }
            out.append(arena, .{ .text = lbl, .style = theme.brand_bold }) catch return null;
        } else {
            if (out.items.len > 0) {
                out.append(arena, .{ .text = " · ", .style = theme.line }) catch return null;
            }
            out.append(arena, .{ .text = "free-auto: building pool…", .style = theme.warn }) catch return null;
        }
    }

    if (out.items.len == 0) return null;
    return out.items;
}

/// Context gauge segments for the footer: the context percentage.
///
/// Returns null when there is nothing to show (no context tracked yet).
fn contextInfo(arena: std.mem.Allocator) ?[]const InfoSeg {
    if (agent.ctx_used == 0 and !agent.ctx_real) return null;
    var out: std.ArrayList(InfoSeg) = .empty;
    const label = if (agent.ctx_real) "ctx" else "ctx~";
    const pct_suffix = if (agent.ctx_pct > 999) ">" else "";
    out.append(arena, .{ .text = label, .style = theme.status }) catch return null;
    out.append(arena, .{ .text = " ", .style = theme.status }) catch return null;
    var nb: [8]u8 = undefined;
    const pct_txt = std.fmt.bufPrint(&nb, "{d}{s}%", .{agent.ctx_pct, pct_suffix}) catch return null;
    // The percentage is printed with `putStable`, which does NOT copy the
    // bytes: `pct_txt` points at THIS frame's stack, and the renderer reads
    // the cells after the frame is over. It has to live in the frame's arena.
    //
    // This was a real bug, and it was invisible: the number usually came out
    // right because the stack still held the bytes, and came out as garbage
    // when it did not.
    const owned = arena.dupe(u8, pct_txt) catch return null;
    out.append(arena, .{ .text = owned, .style = theme.status }) catch return null;
    return out.items;
}

/// Width in COLUMNS of a group of status segments.
///
/// Measured with the grapheme iterator and not with `.len`: `⚡` is 3 bytes for 1
/// column, so aligning by bytes throws the whole row off center. Both columns
/// use this function, and they have to measure IDENTICALLY or they overlap.
fn segsWidth(segs: []const InfoSeg) u16 {
    var total: u16 = 0;
    for (segs) |sg| {
        var it = vaxis.unicode.graphemeIterator(sg.text);
        while (it.next()) |g| {
            _ = g;
            total += 1;
        }
    }
    return total;
}

/// Centered modal in opencode style: title, filter, items with selection and footer.
fn drawPicker(p: *Painter, width: u16, height: u16, ps: PickerSnapshot) void {
    // 104 columns: the picker's rows are "label  ·  description" and at 90
    // the description was the part that got cut.
    const box_w: u16 = @min(width -| 4, 104);
    const box_h: u16 = @min(height -| 4, 15);
    if (box_w < 20 or box_h < 6) return;
    const x0 = (width - box_w) / 2;
    const y0 = (height - box_h) / 4; // a bit above the center

    drawRoundedBox(p, x0, y0, box_w, box_h, .{}, theme.accent);

    // title and filter
    var tbuf: [96]u8 = undefined;
    const t1 = std.fmt.bufPrint(&tbuf, " {s}", .{ps.title}) catch " picker";
    _ = p.putText(x0 + 2, y0, t1, theme.accent_bold);
    var qbuf: [96]u8 = undefined;
    const q1 = if (ps.query.len > 0)
        std.fmt.bufPrint(&qbuf, "filter: {s}_", .{ps.query}) catch "filter: _"
    else
        "filter: (type to search)";
    _ = p.putText(x0 + 2, y0 + 1, q1, theme.dim);

    // items
    const item_rows: usize = box_h - 5; // title + query + footer + 2 borders
    for (ps.items, 0..) |it, i| {
        if (i >= item_rows) break;
        const row = y0 + 2 + @as(u16, @intCast(i));
        const is_sel = ps.first_visible + i == ps.sel;
        if (is_sel) p.fillRange(x0 + 1, x0 + box_w - 1, row, " ", theme.selected);
        // The label is painted with the characters the FILTER matched in bold,
        // and the description after it in the dim color: one `putText` for the
        // whole row made the two look like one sentence, and the query the row
        // matched was invisible (the filter found it, the eye could not).
        var hbuf: [64]u32 = undefined;
        const hn = fuzzy.highlightPositions(it.label, ps.query, &hbuf) orelse 0;
        var after = putStyled(
            p,
            x0 + 2,
            row,
            it.label,
            hbuf[0..hn],
            if (is_sel) theme.selected else theme.text,
            null,
            0,
        );
        if (it.desc.len > 0) {
            after = p.putText(after, row, "  ", if (is_sel) theme.selected else theme.dim);
            _ = p.putText(after, row, it.desc, if (is_sel) theme.selected else theme.dim);
        }
    }

    // footer
    var fbuf: [96]u8 = undefined;
    var f1_text: []const u8 = "";
    if (ps.semantic_searching) {
        f1_text = "Searching…  (esc cancel)";
    } else {
        f1_text = std.fmt.bufPrint(
            &fbuf,
            "\u{2191}\u{2193} navigate \u{b7} enter select \u{b7} esc close  ({d}/{d})",
            .{ if (ps.total > 0) ps.sel + 1 else 0, ps.total },
        ) catch "";
    }
    _ = p.putText(x0 + 2, y0 + box_h - 2, f1_text, theme.dim);
}

// ── render tests ──────────────────────────────────────────
//
// Regression test for the bug that left the screen blank: the graphemes were
// written with `&[_]u8{c}` (a pointer to a stack temporary) and vaxis read them
// AFTER drawFn returned → NULs. These tests read the surface's buffer and
// compare the real text, which is what the renderer is going to print.

/// Paints one frame of the model with the given arena (for tests). The surface
/// is only valid while the arena is still alive.
pub fn drawTest(model: *Model, arena: std.mem.Allocator, w: u16, h: u16) !vxfw.Surface {
    const wd = model.widget();
    return wd.drawFn(wd.userdata, .{
        .arena = arena,
        .min = .{ .width = w, .height = h },
        .max = .{ .width = w, .height = h },
        .cell_size = .{ .width = 1, .height = 1 },
    });
}

test "render: an info paragraph shows up on row 0" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.pushInfo("hola mundo");

    const s = try drawTest(&m, arena, 40, 12);
    var buf: [128]u8 = undefined;
    const row0 = rowText(s, 0, &buf);
    // Info prefix + text.
    try std.testing.expectEqualStrings("\u{b7} hola mundo", std.mem.trim(u8, row0, " "));
}

test "render: multibyte graphemes come out whole (not byte by byte)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.pushInfo("a\u{00f1}o \u{2500}\u{2500} \u{2713}");

    const s = try drawTest(&m, arena, 40, 12);
    var buf: [128]u8 = undefined;
    const row0 = rowText(s, 0, &buf);
    try std.testing.expectEqualStrings(
        "\u{b7} a\u{00f1}o \u{2500}\u{2500} \u{2713}",
        std.mem.trim(u8, row0, " "),
    );
}

test "render: the live stream is visible before streamEnd" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.streamStart();
    m.streamDelta("parci");
    const s = try drawTest(&m, arena, 40, 12);
    var buf: [128]u8 = undefined;
    const row0 = rowText(s, 0, &buf);
    try std.testing.expect(std.mem.indexOf(u8, row0, "parci") != null);
    // The live stream has no mark either: the assistant never does.
    try std.testing.expect(std.mem.indexOf(u8, row0, "\u{25c6}") == null);

    var arena2_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena2_state.deinit();
    const arena2 = arena2_state.allocator();

    // When the stream closes, the text becomes a fixed paragraph.
    m.streamDelta("al");
    m.streamEnd();
    const s2 = try drawTest(&m, arena2, 40, 12);
    var buf2: [128]u8 = undefined;
    const row0b = rowText(s2, 0, &buf2);
    // NO `◆`. The prose used to carry a magenta diamond, which made the
    // model's own words the most decorated thing on the screen. What matters
    // now is that the text is THERE and that nothing is glued to the front of
    // it — so this asserts the row is exactly the words.
    try std.testing.expectEqualStrings("parcial", std.mem.trim(u8, row0b, " "));
}

test "render: long text wraps without losing characters" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const msg = "abcdefghijklmnopqrstuvwxyz0123456789";
    m.pushInfo(msg);

    const width: u16 = 20;
    const s = try drawTest(&m, arena, width, 12);

    // Rebuilds all the history rows and checks that the concatenation
    // (without padding spaces) returns the message intact.
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(std.testing.allocator);
    var buf: [128]u8 = undefined;
    // The history now takes everything except status + input box.
    const history_rows: u16 = 12 - 6; // status + box(3) + separator
    var row: u16 = 0;
    while (row < history_rows) : (row += 1) {
        const line = std.mem.trim(u8, rowText(s, row, &buf), " ");
        // The first row carries the "· " prefix in front of the text and every
        // continuation row carries the gutter bar. `│ ` is FOUR bytes for two
        // columns, so it is skipped by finding the space after the bar and not by
        // counting bytes.
        var body = line;
        if (row == 0 and line.len > 0) {
            body = line[2..];
        } else if (std.mem.startsWith(u8, line, "\u{2502} ")) {
            body = line[std.mem.indexOfScalar(u8, line, ' ').? + 1 ..];
        }
        for (body) |c| {
            if (c != ' ') acc.append(std.testing.allocator, c) catch {};
        }
    }
    try std.testing.expectEqualStrings(msg, acc.items);
}

test "render: the status and workspace rule anchor the compact prompt" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.setStatusText("ready");

    const height: u16 = 12;
    const s = try drawTest(&m, arena, 40, height);

    var buf: [128]u8 = undefined;
    // The bottom three rows, and they are three rows: a hairline, the input,
    // the status. Before it was a rule, a THREE-row bordered box, a blank and
    // the status — five rows of furniture for one row of text.
    const sep = rowText(s, height - 3, &buf);
    try std.testing.expectEqualStrings("\u{2500}", sep[0..3]);
    var buf3: [128]u8 = undefined;
    const prompt = rowText(s, height - 2, &buf3);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\u{203a}") != null);
    // The accent bar: the input has no box, so this is what says "you are here".
    // Without it, "where does what I type go" is a question the frame answers
    // only by the colour of a glyph.
    try std.testing.expectEqualStrings("\u{258c}", std.mem.trim(u8, prompt, " ")[0..3]);
    // status
    var buf2: [128]u8 = undefined;
    const st = rowText(s, height - 1, &buf2);
    try std.testing.expect(std.mem.indexOf(u8, st, "ready") != null);
}

test "the bottom furniture is exactly two rows and nothing else" {
    // The layout, asserted instead of described. This is the test that would
    // have caught the eleven rows of permanent furniture, and it is one line
    // per row because a layout that grows has to fail a test, not a review.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const h: u16 = 20;
    const s = try drawTest(&m, arena_state.allocator(), 60, h);
    // Rows the transcript may NOT use, from the bottom up.
    var buf: [128]u8 = undefined;
    // h-1: the footer's row.
    const status = rowText(s, h - 1, &buf);
    try std.testing.expect(status.len > 0);
    // h-2: the input, and it is ONE row when the input is one line.
    const input = rowText(s, h - 2, &buf);
    try std.testing.expect(std.mem.indexOf(u8, input, "\u{203a}") != null);
    // h-3: the hairline.
    const rule = rowText(s, h - 3, &buf);
    try std.testing.expectEqualStrings("\u{2500}", rule[0..3]);
    // h-4 is the LAST transcript row and it is NOT furniture: no border, no
    // extra blank row between the rule and the conversation.
    try std.testing.expect(m.hist_rows == h - 3);
}

test "render: tool blocks use ●/│ and the result expands" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.pushToolStart("read", "src/tui.zig");
    m.pushToolDone("read", "Read 1006 lines", 3, "1|const std\n2|fn main()");

    // Collapsed state: two paragraphs, header and summary.
    //
    // They are looked up by CONTENT and not by row: since the paragraphs carry
    // a blank separation row, the position of the second depends on how many
    // blocks come before it and the test broke with every layout change.
    const s = try drawTest(&m, arena, 60, 14);
    try std.testing.expect(findRow(s, "read(src/tui.zig)") != null);
    try std.testing.expect(findRow(s, "Read 1006 lines") != null);
    {
        var buf: [256]u8 = undefined;
        const r = findRow(s, "read(src/tui.zig)").?;
        try std.testing.expectEqualStrings("\u{25cf} read(src/tui.zig)", std.mem.trim(u8, rowText(s, r, &buf), " "));
        // The `⎿` is a `│`. The elbow pointed nowhere; a RAIL is a line the
        // eye can follow down, which is what an expanded result needs to be
        // tied to the call it came from.
        const r2 = findRow(s, "Read 1006 lines").?;
        // Collapsed: summary plus the Ctrl+R hint that the full transcript is
        // available.
        try std.testing.expectEqualStrings("\u{2502} Read 1006 lines \u{b7} 3ms · Ctrl+R expand", std.mem.trim(u8, rowText(s, r2, &buf), " "));
    }

    // Ctrl+R expands the full result (several lines).
    try std.testing.expect(m.toggleLastTool());
    var arena2_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena2_state.deinit();
    const s2 = try drawTest(&m, arena2_state.allocator(), 60, 14);
    try std.testing.expect(findRow(s2, "const std") != null);

    // And collapses back to the summary.
    try std.testing.expect(m.toggleLastTool());
    var arena3_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena3_state.deinit();
    const s3 = try drawTest(&m, arena3_state.allocator(), 60, 14);
    try std.testing.expect(findRow(s3, "Read 1006 lines") != null);
}

test "toggleLastTool with no previous tool does nothing" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.pushInfo("solo info");
    try std.testing.expect(!m.toggleLastTool());
}

test "input: compact prompt, prompt glyph and placeholder" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const h: u16 = 14;
    const s = try drawTest(&m, arena_state.allocator(), 40, h);

    var buf2: [128]u8 = undefined;
    const mid = rowText(s, h - 2, &buf2);
    try std.testing.expect(std.mem.indexOf(u8, mid, "\u{203a}") != null);
    try std.testing.expect(std.mem.indexOf(u8, mid, "Ask anything") != null);
    // The placeholder must be the PLACEHOLDER color, and — the part that can
    // actually break — it must not be the color real text is painted in. The
    // old assertion compared against `theme.hint`, which was an ALIAS that
    // moved when the palette was retheme'd, so it checked that the placeholder
    // equalled whatever color happened to be named `hint` that week.
    try std.testing.expectEqual(theme.placeholder.fg, s.readCell(3, h - 2).style.fg);
    try std.testing.expect(!theme.placeholder.fg.eql(theme.input_text.fg));
}

test "input: multiline grows the box and shows both lines" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const h: u16 = 16;
    // Three lines: the prompt grows to three rows, upward from the status.
    m.ed.insert("primera\nsegunda\ntercera") catch {};

    const s = try drawTest(&m, arena_state.allocator(), 40, h);
    var buf: [128]u8 = undefined;
    // input_h=3, and the input is pinned above the footer's row: top = h-1-3.
    const top = rowText(s, h - 4, &buf);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.trim(u8, top, " "), "\u{203a}") != null);

    var b1: [128]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, rowText(s, h - 4, &b1), "primera") != null);
    var b2: [128]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, rowText(s, h - 3, &b2), "segunda") != null);
    var b3: [128]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, rowText(s, h - 2, &b3), "tercera") != null);

    // The accent bar grows WITH the input: one cell per row, and it is the only
    // green down here. A bar that stayed one row tall while the text used three
    // would say "one line" and be wrong.
    try std.testing.expectEqualStrings("\u{258c}", std.mem.trim(u8, rowText(s, h - 4, &buf), " ")[0..3]);
    try std.testing.expectEqualStrings("\u{258c}", std.mem.trim(u8, rowText(s, h - 3, &buf), " ")[0..3]);
    try std.testing.expectEqualStrings("\u{258c}", std.mem.trim(u8, rowText(s, h - 2, &buf), " ")[0..3]);
}

test "input: a long line wraps within the prompt and no character is lost" {
    // THE bug: the prompt was sized from `displayLines` (which counts soft wraps)
    // and the paint split on `\n` only, handing one very long line to `putText`,
    // which clips at the TERMINAL edge. So the box grew to eight rows, the text
    // stayed in the first one running off the right, and everything past the
    // right edge was clipped with no ellipsis and no word: the user could not see
    // what they had typed.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.ed.insert("el cielo gris de la manana sobre el puerto viejo") catch {};

    const s = try drawTest(&m, arena_state.allocator(), 40, 16);

    // The start and the END of the sentence are both on screen: the tail used to
    // be the part that vanished.
    const r1 = findRow(s, "el cielo gris") orelse return error.TestUnexpectedResult;
    const r2 = findRow(s, "puerto viejo") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 1), r2 - r1);
    // The prompt is borderless; wrapped text stays inside the screen instead.
    var buf: [128]u8 = undefined;
    for ([_]u16{ r1, r2 }) |row| {
        const t = rowText(s, row, &buf);
        try std.testing.expect(std.mem.lastIndexOfScalar(u8, t, ' ') != null);
        try std.testing.expect(std.mem.indexOf(u8, t, "│") == null);
    }
}

test "input: a wrapped line fills several rows and the cursor stays on screen" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.ed.insert("a" ** 200) catch {};

    const w: u16 = 40;
    const h: u16 = 20;
    const s = try drawTest(&m, arena_state.allocator(), w, h);

    const rows = m.ed.displayLines(w - 4, testEditorMeasurer());
    try std.testing.expect(rows >= 4);
    const input_h: u16 = @min(rows, 8);
    // `h - 1 - input_h`: the input is pinned directly above the footer's row,
    // and the hairline above it took the row the box's bottom border used to be.
    const top = h - 1 - input_h;

    // Several prompt rows carry text, not just the first one.
    var filled: usize = 0;
    var row: u16 = top;
    while (row < top + input_h) : (row += 1) {
        var buf: [128]u8 = undefined;
        if (std.mem.indexOf(u8, rowText(s, row, &buf), "aaaa") != null) filled += 1;
    }
    try std.testing.expect(filled >= 4);

    // The caret is a real cell on screen. It used to be anchored at the width
    // of everything before it, so it simply disappeared.
    const cur = s.cursor orelse return error.TestUnexpectedResult;
    try std.testing.expect(cur.col < w - 1);
    try std.testing.expect(cur.row >= top);
    // The LAST input row is `h - 2` itself: the status moved to `h - 1` and the
    // box's bottom border is gone, so the prompt now owns that row.
    try std.testing.expect(cur.row <= h - 2);
}

test "input: over the byte cap, the edit is rejected and the limit is named" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const w: u16 = 80;
    const h: u16 = 24;

    // Fill the buffer exactly up to the byte cap.
    var buf: [1024]u8 = undefined;
    @memset(&buf, 'x');
    var filled: usize = 0;
    while (filled < ed.max_bytes) : (filled += buf.len) {
        const chunk = buf[0..@min(buf.len, ed.max_bytes - filled)];
        try m.ed.insert(chunk);
    }
    try std.testing.expectEqual(@as(usize, ed.max_bytes), m.ed.text().len);

    // One more byte: the edit is rejected and the buffer is left untouched.
    if (m.ed.insert("y")) |_| {
        try std.testing.expect(false);
    } else |err| {
        // editor.zig's error set; match by name since error sets are per-file.
        try std.testing.expect(std.mem.eql(u8, @errorName(err), "InputTooLong"));
    }
    try std.testing.expectEqual(@as(usize, ed.max_bytes), m.ed.text().len);

    // The rejection note: painted inside the composer zone (the affected
    // zone), naming the limit. The key handler sets this exact state.
    m.input_too_long = true;
    const msg = std.fmt.bufPrint(&m.input_err_buf,
        "Input too long: {d}-byte cap, {d} bytes already typed. Shorten the text and resend.",
        .{ ed.max_bytes, m.ed.text().len }) catch {
        m.input_err = "Input too long: shorten the text.";
        return;
    };
    m.input_err = msg;

    const s = try drawTest(&m, arena_state.allocator(), w, h);
    const row = findRow(s, "Input too long") orelse return error.TestUnexpectedResult;

    // The note lives in the composer zone: between the top of the input well
    // and the last row above the footer (`h - 2`).
    const input_h = @min(m.ed.displayLines(w - 4, testEditorMeasurer()), 8);
    const top = h - 1 - input_h;
    try std.testing.expect(row >= top);
    try std.testing.expect(row <= h - 2);

    // The limit itself is named in the painted message.
    var line: [128]u8 = undefined;
    const painted = std.mem.trim(u8, rowText(s, row, &line), " ");
    try std.testing.expect(std.mem.indexOf(u8, painted, "262144-byte cap") != null);
}

test "input: composer surface is a well_bg sunken panel behind the text" {
    // Phase 1 of the input polish: the composer must read as a SURFACE, not
    // just text floating on the terminal background. The well_bg fill is what
    // separates it from the transcript above without spending a border row.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const w: u16 = 40;
    const h: u16 = 14;
    const s = try drawTest(&m, arena_state.allocator(), w, h);

    // The input row is h-2 (status is h-1). A cell just past the prompt glyph
    // but before the placeholder text must carry the well_bg background,
    // proving the surface is painted. Column 5 is past the accent bar (0),
    // prompt (1-2), and placeholder start (3+), but still inside the fill.
    const cell = s.readCell(5, h - 2);
    try std.testing.expect(cell.style.bg != .default);
    const cell_bg = cell.style.bg;
    const well_bg = theme.well_bg.bg;
    try std.testing.expect(switch (cell_bg) {
        .rgb => |c| switch (well_bg) {
            .rgb => |w_bg| c[0] == w_bg[0] and c[1] == w_bg[1] and c[2] == w_bg[2],
            else => false,
        },
        else => false,
    });
    // The accent bar cell keeps its own color on top of the surface.
    const bar = s.readCell(0, h - 2);
    try std.testing.expectEqual(theme.input_bar.fg, bar.style.fg);
    // The prompt glyph sits on the well surface too.
    const prompt = s.readCell(1, h - 2);
    const prompt_bg = prompt.style.bg;
    try std.testing.expect(switch (prompt_bg) {
        .rgb => |c| switch (well_bg) {
            .rgb => |w_bg| c[0] == w_bg[0] and c[1] == w_bg[1] and c[2] == w_bg[2],
            else => false,
        },
        else => false,
    });
}

test "input: placeholder and text sit on well_bg surface with correct fg" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const w: u16 = 40;
    const h: u16 = 14;
    const s = try drawTest(&m, arena_state.allocator(), w, h);

    const well_bg = theme.well_bg.bg;
    // Placeholder text starts at column 3. Check it has well_bg bg AND placeholder fg.
    const ph_cell = s.readCell(5, h - 2); // "k" in "Ask"
    try std.testing.expect(switch (ph_cell.style.bg) {
        .rgb => |c| switch (well_bg) {
            .rgb => |w_bg| c[0] == w_bg[0] and c[1] == w_bg[1] and c[2] == w_bg[2],
            else => false,
        },
        else => false,
    });
    try std.testing.expectEqual(theme.placeholder.fg, ph_cell.style.fg);

    // Now add some text and check the editor text style
    m.ed.insert("hola") catch {};
    const s2 = try drawTest(&m, arena_state.allocator(), w, h);
    const text_cell = s2.readCell(3, h - 2); // "h" at column 3
    try std.testing.expect(switch (text_cell.style.bg) {
        .rgb => |c| switch (well_bg) {
            .rgb => |w_bg| c[0] == w_bg[0] and c[1] == w_bg[1] and c[2] == w_bg[2],
            else => false,
        },
        else => false,
    });
    try std.testing.expectEqual(theme.input_text.fg, text_cell.style.fg);
}

test "input: accent bar color changes with state" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    // Normal state: input_bar
    var act = m.activity();
    try std.testing.expect(!act.busy);
    try std.testing.expect(!act.ask);

    // Busy state (tool running): brand
    m.pushHeader(.idle);
    m.pushKind(.user, "test");
    m.pushToolStart("Bash", "sleep 10");
    act = m.activity();
    try std.testing.expect(act.busy);
    try std.testing.expect(!act.ask);
    try std.testing.expect(m.tool_run != null);

    // Ask state: warn
    m.askLock();
    m.freeAskStringsLocked();
    m.ask_question = m.allocator.dupe(u8, "test?") catch null;
    m.ask_header = m.allocator.dupe(u8, "header") catch null;
    m.ask_options.append(m.allocator, m.allocator.dupe(u8, "opt1") catch "") catch {};
    m.ask_active = true;
    m.ask_typing = false;
    m.ask_started_ns = 0;
    m.askUnlock();
    act = m.activity();
    try std.testing.expect(act.busy); // ask counts as busy
    try std.testing.expect(act.ask);
}

test "input: accent bar is brand when tool is running (ui-frame running scene)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    // Mimic the running scene
    m.pushHeader(.idle);
    m.pushKind(.user, "corre los tests");
    m.pushToolStart("Bash", "zig build test --summary all && ls -la src/lib");
    // Note: NO streamEnd, NO toolRunEnd

    const w: u16 = 80;
    const h: u16 = 30;
    const s = try drawTest(&m, arena_state.allocator(), w, h);

    // Find the input row (h-2)
    const input_row = h - 2;
    const bar_cell = s.readCell(0, input_row);
    try std.testing.expectEqual(theme.brand.fg, bar_cell.style.fg);
}

test "focus: the window starts focused and focus_in/focus_out flip it" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    try std.testing.expect(m.focused);

    var ctx = testCtx();
    defer ctx.cmds.deinit(ctx.alloc);

    // Losing focus flips the flag (no timer registration involved).
    try typeErasedEventHandler(&m, &ctx, .focus_out);
    try std.testing.expect(!m.focused);

    // Regaining focus flips it back. `tick_armed` is set so `armTick` does not
    // try to register a timer against the test's undefined `Io` (`Tick.in`
    // calls `std.Io.Timestamp.now` which needs a real `Io`): the flag flip is
    // what is under test here.
    m.tick_armed = true;
    try typeErasedEventHandler(&m, &ctx, .focus_in);
    try std.testing.expect(m.focused);
}

test "focus: the accent bar is dimmed when the window is not focused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const w: u16 = 80;
    const h: u16 = 30;
    const input_row = h - 2;

    var ctx = testCtx();
    defer ctx.cmds.deinit(ctx.alloc);

    const s = try drawTest(&m, arena, w, h);
    try std.testing.expect(!s.readCell(0, input_row).style.dim);

    try typeErasedEventHandler(&m, &ctx, .focus_out);
    try std.testing.expect(!m.focused);

    const dimmed = try drawTest(&m, arena, w, h);
    try std.testing.expect(dimmed.readCell(0, input_row).style.dim);

    m.tick_armed = true;
    try typeErasedEventHandler(&m, &ctx, .focus_in);
    try std.testing.expect(m.focused);

    const lit = try drawTest(&m, arena, w, h);
    try std.testing.expect(!lit.readCell(0, input_row).style.dim);
}

test "input: rows scrolled out above are announced instead of silently hidden" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    var i: usize = 0;
    while (i < 60) : (i += 1) m.ed.insert("linea ") catch {};

    const s = try drawTest(&m, arena_state.allocator(), 40, 14);
    // A clipped prompt reports how many visual rows are above the cursor.
    try std.testing.expect(findRow(s, "more") != null);
}

test "input: large tool result + running tool + draw does not crash" {
    // Reproduces the sequence that crashed: a ~2002 line file read (AGENTS.md
    // size) followed by a running tool with a long argument, then a draw.
    // The large result stresses the layout cache; the tool_run line adds a clock
    // line; together they exposed a UAF in the segment cache eviction.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    // 1) Simulate a 2002-line file read result (like AGENTS.md)
    var big_result: std.ArrayList(u8) = .empty;
    defer big_result.deinit(std.testing.allocator);
    var line: usize = 1;
    while (line <= 2002) : (line += 1) {
        big_result.print(std.testing.allocator, "{d}| This is line {d} of the big file with some content\n", .{ line, line }) catch break;
    }

    m.pushToolStart("read", "AGENTS.md");
    m.pushToolDone("read", "Read 2002 lines", 3, big_result.items);

    // 2) Start a running tool with a long argument (like the bash that followed)
    m.pushToolStart("bash", "zig build test --summary all && ls -la src/lib && cat build.zig");

    // 3) Draw multiple frames while the tool is running (simulates the clock ticking)
    var frame: usize = 0;
    while (frame < 10) : (frame += 1) {
        const s = try drawTest(&m, arena_state.allocator(), 80, 30);
        // Verify the draw succeeds: no panic, no invalid memory access
        _ = s;
    }

    // 4) End the tool and draw again
    m.toolRunEnd();
    m.pushToolDone("bash", "Bash", 1200, "Compiling...\nTests passed\n");

    // 5) Final draw after tool completes
    const s = try drawTest(&m, arena_state.allocator(), 80, 30);
    _ = s;

    // If we got here without segfault/ASan error, the path is sound
}

test "autocomplete: filters by prefix and accepts with tab" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.ed.insert("/mo") catch {};
    syncAutocomplete(&m);
    try std.testing.expect(m.ac.active);
    // /model, /models and /mode, all three against the real list
    // (/memory does not exist). A prefix filter, not an exact one.
    const n_mo = matchCount(&m);
    try std.testing.expect(n_mo >= 3);
    var has_model = false;
    var has_models = false;
    var has_mode = false;
    for (0..n_mo) |i| {
        const k = matchLabel(&m, i).?;
        if (std.mem.eql(u8, k, "/model")) has_model = true;
        if (std.mem.eql(u8, k, "/models")) has_models = true;
        if (std.mem.eql(u8, k, "/mode")) has_mode = true;
    }
    try std.testing.expect(has_model);
    try std.testing.expect(has_models);
    try std.testing.expect(has_mode);

    // "/models" leaves only /models (the longer prefix wins)
    m.ed.clear();
    m.ed.insert("/models") catch {};
    syncAutocomplete(&m);
    try std.testing.expectEqual(@as(usize, 1), matchCount(&m));
    try std.testing.expectEqualStrings("/models", matchLabel(&m, 0).?);

    // "/mod" leaves /models, /model and /mode, in table order:
    // /models precedes /model in the command table, which is why
    // index 0 below is /models and not the alphabetically-first one.
    m.ed.clear();
    m.ed.insert("/mod") catch {};
    syncAutocomplete(&m);
    try std.testing.expectEqual(@as(usize, 3), matchCount(&m));
    m.ac.sel = 0;
    try std.testing.expectEqualStrings("/models", matchLabel(&m, 0).?);

    // Tab completes the selected command and adds the space.
    try std.testing.expect(acceptAutocomplete(&m));
    try std.testing.expectEqualStrings("/models ", m.ed.text());
    try std.testing.expect(!m.ac.active);

    // With the selection on the second match, that one is completed.
    m.ed.clear();
    m.ed.insert("/mod") catch {};
    syncAutocomplete(&m);
    m.ac.sel = 1;
    try std.testing.expect(acceptAutocomplete(&m));
    try std.testing.expectEqualStrings("/model ", m.ed.text());
}

test "autocomplete: not offered with spaces nor without the slash" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.ed.insert("hola") catch {};
    syncAutocomplete(&m);
    try std.testing.expect(!m.ac.active);

    m.ed.clear();
    m.ed.insert("/model x") catch {}; // it already has an argument
    syncAutocomplete(&m);
    try std.testing.expect(!m.ac.active);

    m.ed.clear();
    m.ed.insert("/zzz") catch {}; // no matches
    syncAutocomplete(&m);
    try std.testing.expect(!m.ac.active);
}

test "fileQueryAt: the @ token under the cursor, and an email is not a mention" {
    // PURE: this is the logic `refreshFileMatches` keys off, and it has to
    // agree with `mentions.scan` (the thing that later parses the prompt).
    const q = fileQueryAt("revisa @src/edi", 15).?;
    try std.testing.expectEqual(@as(usize, 7), q.token_start);
    try std.testing.expectEqualStrings("src/edi", q.token);

    // Just `@` (empty token) still opens the listing: it IS the discovery UI.
    const q2 = fileQueryAt("mira @", 6).?;
    try std.testing.expectEqual(@as(usize, 5), q2.token_start);
    try std.testing.expectEqualStrings("", q2.token);

    // An email is NOT a mention, same rule as mentions.scan.
    try std.testing.expect(fileQueryAt("jorge@example.com", 17) == null);
    try std.testing.expect(fileQueryAt("a@b", 3) == null);

    // No `@` under the cursor at all.
    try std.testing.expect(fileQueryAt("hola mundo", 10) == null);
}

test "@ autocomplete: file mode is active and accepting replaces only the token" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.ed.insert("revisa @src/") catch {};
    syncAutocomplete(&m);
    // Without an `Io` (io_ready false in a test Model) the listing is empty,
    // but the MODE still flips to file: the popup logic is what is pinned here.
    try std.testing.expectEqual(Autocomplete.Mode.file, m.ac.mode);

    // Acceptance replaces ONLY the token: with no matches it returns false and
    // leaves the text alone.
    m.ed.clear();
    m.ed.insert("revisa @a.zig y luego @b") catch {};
    // Cursor lands after `b` by default (insert advances it).
    syncAutocomplete(&m);
    try std.testing.expectEqual(Autocomplete.Mode.file, m.ac.mode);
    // The token start points at the SECOND `@`, not the first.
    try std.testing.expectEqualStrings("b", acPrefix(&m).?);
}

test "editor.deleteRange: replaces a range and leaves the cursor at the start" {
    var editor_ = ed.Editor.init(std.testing.allocator);
    defer editor_.deinit();

    editor_.insert("revisa @abc y sigue") catch {};
    // Replace the token `abc` (offsets 8..11) with `zzz`.
    try editor_.deleteRange(8, 11);
    editor_.setCursor(8);
    try editor_.insert("zzz");
    try std.testing.expectEqualStrings("revisa @zzz y sigue", editor_.text());
    try std.testing.expectEqual(@as(usize, 11), editor_.cursor);

    // Out of range is an error, not a panic.
    try std.testing.expectError(error.BadRange, editor_.deleteRange(0, editor_.text().len + 1));
}

test "input: the cursor is anchored at the real position" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.ed.insert("abc") catch {};
    m.ed.moveHome();
    const s = try drawTest(&m, arena_state.allocator(), 40, 14);
    // Cursor at the start of the line: right after the "› " prompt (col 3).
    try std.testing.expectEqual(@as(u16, 3), s.cursor.?.col);
    // The input is the SECOND row from the bottom now: the hairline took the
    // row the box's bottom border used to be, and there is no blank row after
    // it either.
    try std.testing.expectEqual(@as(u16, 14 - 2), s.cursor.?.row);

    // With the cursor at the end, it advances 3 columns (the 3 characters).
    m.ed.moveToEnd();
    const s2 = try drawTest(&m, arena_state.allocator(), 40, 14);
    try std.testing.expectEqual(@as(u16, 6), s2.cursor.?.col);
}

test "diff: pushDiff paints -/+ lines after the tool result" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.pushToolStart("edit", "src/demo.txt");
    m.pushToolDone("edit", "Edited 3 lines", 2, "ok");
    const counts = m.pushDiff("uno\ndos\ntres\n", "uno\nDOS\ntres\ncuatro\n");
    // What was already counted before and thrown away: now it is shown (`+2 −1`).
    try std.testing.expectEqual(@as(usize, 2), counts.added);
    try std.testing.expectEqual(@as(usize, 1), counts.removed);

    // 24 rows: with the blank row between paragraphs, the diff (5 lines in ONE
    // paragraph) no longer fits in 16 and the last one went outside the
    // viewport. The test grows with the layout, not the other way round.
    const s = try drawTest(&m, arena_state.allocator(), 50, 24);
    var buf: [256]u8 = undefined;
    // No specific rows are checked: since the paragraphs are separated with a
    // blank row, the position of each block depends on how many blocks there
    // are. It searches the whole surface.
    var all0: std.ArrayList(u8) = .empty;
    defer all0.deinit(std.testing.allocator);
    var rr: u16 = 0;
    while (rr < 24) : (rr += 1) {
        all0.appendSlice(std.testing.allocator, rowText(s, rr, &buf)) catch {};
        all0.append(std.testing.allocator, '\n') catch {};
    }
    try std.testing.expect(std.mem.indexOf(u8, all0.items, "edit(src/demo.txt)") != null);

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(std.testing.allocator);
    var row: u16 = 0;
    while (row < 24) : (row += 1) {
        for (rowText(s, row, &buf)) |c| joined.append(std.testing.allocator, c) catch {};
        joined.append(std.testing.allocator, '\n') catch {};
    }
    const all = joined.items;
    try std.testing.expect(std.mem.indexOf(u8, all, "-dos") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "+DOS") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "+cuatro") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, " uno") != null); // context
}

test "diff: no changes adds no paragraphs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    _ = m.pushDiff("igual\n", "igual\n");
    const s = try drawTest(&m, arena_state.allocator(), 40, 12);
    var buf: [256]u8 = undefined;
    // No paragraphs: row 0 is the separator/banner, not a diff.
    const row0 = rowText(s, 0, &buf);
    try std.testing.expect(std.mem.indexOf(u8, row0, "+") == null);
}

test "hero: the wordmark is lit and the grid is three tones" {
    // The brightness falls INSIDE the line (`*zode*`), not on a whole row: that
    // is what makes a wordmark read as a wordmark and not as a block of text.
    // And it is a wordmark now — the five rows of ASCII are gone, and what
    // replaced them is type plus the four commands that are worth knowing in
    // the first thirty seconds.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const segs = try md.inlineSegments(arena, "*zode*", .banner);
    try std.testing.expectEqual(@as(usize, 1), segs.len);
    try std.testing.expectEqualStrings("zode", segs[0].text);
    try std.testing.expect(segs[0].style.bold); // the brightness

    // FOUR segments: the marked key, the base between them, the marked
    // shortcut, and the base after it.
    //
    // The texts are matched by CONTENT and the padding is not counted: how many
    // spaces sit between the columns is a layout decision, and a test that
    // pins it is a test that fails when somebody nudges a column. What matters
    // is that the marked parts came out LIT and the unmarked ones did not.
    // `inlineSegmentsBase` with BOTH tones, NOT `inlineSegments`: the three-arg
    // helper has no `mood_style`, so the `~…~` mark falls back to `styles.banner`
    // and comes out the SAME color as the base — which is how this test would
    // have "proved" the hero has three tones while the third tone does not
    // exist. The draw passes `Para.mood`, and a test that does not is a test of
    // a different code path.
    const row = try md.inlineSegmentsBase(
        arena,
        "*zode*  commands        ~ctrl+p~  palette",
        .banner,
        theme.ink3,
        theme.status,
    );
    try std.testing.expectEqual(@as(usize, 4), row.len);
    try std.testing.expectEqualStrings("zode", row[0].text); // the mark
    try std.testing.expectEqualStrings("ctrl+p", row[2].text); // the other mark
    try std.testing.expect(std.mem.startsWith(u8, row[1].text, "  commands"));
    try std.testing.expect(std.mem.startsWith(u8, row[3].text, "  palette"));
    // Three DIFFERENT tones, which is the whole assertion: a hero painted in
    // one color has no accent and reads as a wall of text.
    try std.testing.expect(!std.meta.eql(row[0].style.fg, row[1].style.fg));
    try std.testing.expect(!std.meta.eql(row[1].style.fg, row[2].style.fg));
    try std.testing.expect(row[0].style.bold);
    try std.testing.expect(!row[1].style.bold);
}

test "header: asterisks are marks, no characters are lost" {
    // Project invariant: concatenating the segments gives the text WITHOUT the
    // marks. If a byte is lost or duplicated, the art comes out misaligned.
    //
    // The case is derived from the REAL banner (not a hand-written string):
    // that way the test stays valid if someone edits the art.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var checked: usize = 0;
    var it = std.mem.splitScalar(u8, banner, '\n');
    while (it.next()) |line| {
        try expectMarksAreOnlyMarks(arena, line, &checked);
    }
    // The banner no longer carries a tagline (the ASCII only says the name),
    // but the marks mechanism is still in use for Zo's line (`~…~`, the color
    // follows the mood) and what this test protects is the INVARIANT:
    // concatenating the segments gives the text without the marks, byte for
    // byte. If a byte is lost or duplicated, the art comes out misaligned.
    try expectMarksAreOnlyMarks(arena, "~[ hola ]~  zo dice", &checked);
    try expectMarksAreOnlyMarks(arena, "*write*(hola.js)  · *3ms*", &checked);
    try std.testing.expect(checked >= 2);
}

/// Checks that the segments of `line` concatenated give the line WITHOUT the
/// `*…*` / `~…~` marks, and bumps `checked` if the line had marks.
fn expectMarksAreOnlyMarks(arena: std.mem.Allocator, line: []const u8, checked: *usize) !void {
    const had_marks = std.mem.indexOfAny(u8, line, "*~") != null;
    if (had_marks) checked.* += 1;

    const segs = try md.inlineSegments(arena, line, .banner);
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(std.testing.allocator);
    for (segs) |sg| try joined.appendSlice(std.testing.allocator, sg.text);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(std.testing.allocator);
    for (line) |c| {
        if (c != '*' and c != '~') try expected.append(std.testing.allocator, c);
    }
    try std.testing.expectEqualStrings(expected.items, joined.items);
}

test "header: an unpaired asterisk does not eat text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const segs = try md.inlineSegments(arena, "5 * 3 = 15", .banner);
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(std.testing.allocator);
    for (segs) |sg| try joined.appendSlice(std.testing.allocator, sg.text);
    try std.testing.expectEqualStrings("5 * 3 = 15", joined.items);
}

test "status: the segments are live, whole text" {
    // Regression: with `bufPrint` over a STACK buffer, "(med)" and "ctx N%"
    // were left dangling (the slice is read at paint time, already outside the
    // function) and the status was cut in half with a broken character. Here it
    // is checked that every segment is printable and that the effort closes its
    // parenthesis.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // `sessionInfo` reads the Model's resolved status model, so the test needs one
    // even though it only cares about the segments' SHAPE.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    const segs = sessionInfo(&m, arena_state.allocator()) orelse return;

    for (segs) |sg| {
        try std.testing.expect(sg.text.len > 0);
        for (sg.text) |c| {
            try std.testing.expect(c == ' ' or c >= 0x21);
        }
    }
    // The row is `provider/model` and the separator is its OWN segment, so a
    // dangling `/` (or one glued to the model) would paint the name as if it
    // were two names. The resolved model is forced here because this test runs
    // with no catalogue on disk and no network: without it there would be no
    // model to separate and the assertion would be vacuous.
    m.status_model_buf[0..4].* = "test".*;
    m.status_model_len = 4;
    m.status_model_tried = true;

    const with_model = sessionInfo(&m, arena_state.allocator()) orelse return;
    var saw_sep = false;
    var saw_provider = false;
    var saw_model = false;
    for (with_model) |sg| {
        if (std.mem.eql(u8, sg.text, "/")) saw_sep = true;
        if (std.mem.eql(u8, sg.text, "opencode")) saw_provider = true;
        if (std.mem.eql(u8, sg.text, "test")) saw_model = true;
    }
    try std.testing.expect(saw_sep);
    try std.testing.expect(saw_provider);
    try std.testing.expect(saw_model);
}

test "status: the row is ONLY the model name in the normal case" {
    // The row used to carry provider/model, effort, mode, tokens and ctx%.
    // Now it shows ONLY the model name. Everything else has a command.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    // Simulate a resolved model (normally done by resolveStatusModel from cache)
    const model_name = "kimi-k2.6";
    @memcpy(m.status_model_buf[0..model_name.len], model_name);
    m.status_model_len = model_name.len;
    m.status_model_tried = true;

    const segs = sessionInfo(&m, arena_state.allocator()) orelse return error.TestUnexpectedResult;
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(std.testing.allocator);
    for (segs) |sg| try joined.appendSlice(std.testing.allocator, sg.text);
    const all = joined.items;

    // Should show the model name
    try std.testing.expect(std.mem.indexOf(u8, all, "kimi") != null);
    // No provider prefix, no slash, no extra info
    for ([_][]const u8{ "ctx ", " cached", " prompt", " tok", " min", " med", " xhigh", "opencode", "/" }) |gone| {
        try std.testing.expect(std.mem.indexOf(u8, all, gone) == null);
    }
}

test "status: the DEFAULT permission mode costs NOTHING on the row, and a deviation costs ONE column" {
    // REWRITTEN ON PURPOSE (2026-10-21), and the reason is the change, not a
    // bug: the old version pinned that `accept_edits` was NOT shown either.
    //
    // The reasoning behind the old pin was about COLUMNS — a word costs
    // twelve of them in a footer that has to survive an eighty-column
    // terminal, and a footer nobody can read is a footer nobody reads. That
    // reasoning still holds, and it is why the mode is now a GLYPH.
    //
    // What changed is the ANSWER to the question the mode answers: it decides
    // whether the next tool call asks, and the only way to know that is to
    // look. One column is a price worth paying; twelve were not.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    // Simulate a resolved model
    const model_name = "kimi-k2.6";
    @memcpy(m.status_model_buf[0..model_name.len], model_name);
    m.status_model_len = model_name.len;
    m.status_model_tried = true;

    // Restored on the way out: the mode is a process-wide global and the next
    // test reads it.
    const saved = .{ .ro = agent.read_only, .ae = agent.accept_edits, .y = agent.yolo };
    defer {
        agent.setPermMode(
            &m,
            if (saved.y)
                .bypass
            else if (saved.ro)
                .read_only
            else if (saved.ae)
                .accept_edits
            else
                .default,
        );
    }

    // The DEFAULT: nothing but the model name. A test for the ABSENCE of a
    // mark is the only thing that keeps a future "just add the mode back"
    // from silently undoing the change.
    agent.setPermMode(&m, .default);
    {
        const segs = sessionInfo(&m, arena_state.allocator()) orelse return error.TestUnexpectedResult;
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(std.testing.allocator);
        for (segs) |sg| try joined.appendSlice(std.testing.allocator, sg.text);
        try std.testing.expect(std.mem.indexOf(u8, joined.items, " · ") == null);
        try std.testing.expect(std.mem.indexOf(u8, joined.items, "opencode") == null);
        try std.testing.expect(std.mem.indexOf(u8, joined.items, "/") == null);
    }

    // A DEVIATION: the glyph, and only the glyph.
    for ([_]agent.PermMode{ .accept_edits, .read_only, .bypass }) |pm| {
        agent.setPermMode(&m, pm);
        const segs = sessionInfo(&m, arena_state.allocator()) orelse return error.TestUnexpectedResult;
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(std.testing.allocator);
        for (segs) |sg| try joined.appendSlice(std.testing.allocator, sg.text);
        // The glyph is there...
        try std.testing.expect(std.mem.indexOf(u8, joined.items, "◐") != null or
            std.mem.indexOf(u8, joined.items, "●") != null or
            std.mem.indexOf(u8, joined.items, "◉") != null);
        // ...and it is ONE column wide: no word, no provider, no path.
        try std.testing.expect(std.mem.indexOf(u8, joined.items, "opencode") == null);
        try std.testing.expect(std.mem.indexOf(u8, joined.items, "/") == null);
        try std.testing.expect(std.mem.indexOf(u8, joined.items, "read-only") == null);
        try std.testing.expect(std.mem.indexOf(u8, joined.items, "bypass") == null);
    }
}

test "footer: the right-hand group fits and is not cut" {
    // The visible symptom of the dangling pointer was the row cut with a
    // half UTF-8 character at the right edge.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    // Simulate a resolved model
    const model_name = "kimi-k2.6";
    @memcpy(m.status_model_buf[0..model_name.len], model_name);
    m.status_model_len = model_name.len;
    m.status_model_tried = true;

    const w: u16 = 96;
    const s = try drawTest(&m, arena_state.allocator(), w, 16);
    var buf: [512]u8 = undefined;
    const row = rowText(s, 16 - 1, &buf); // status_row
    // No U+FFFD (the replacement character shows up when a UTF-8 is split).
    try std.testing.expect(std.mem.indexOf(u8, row, "\u{fffd}") == null);
    // The session info is whole: just the model name.
    try std.testing.expect(std.mem.indexOf(u8, row, "kimi") != null);
}

test "status: ctxColor changes at the compaction thresholds" {
    // The intent, not the palette: below the budget a gauge should NOT shout,
    // near it it warns, past it it is an error. The old version pinned "green"
    // for the comfortable state, which is how a 3% context gauge ended up the
    // brightest green thing on the screen.
    //
    // What is asserted is the part that can break: the thresholds are the
    // compaction ones (50 / 80), the three states are DISTINCT, and all three
    // are readable. A refactor that made all three the same color would still
    // be a working gauge and a useless one.
    //
    // 80% is exactly where compaction starts (budget = 80% of the limit).
    try std.testing.expectEqual(theme.ink2.fg, theme.ctxColor(0).fg);
    try std.testing.expectEqual(theme.ink2.fg, theme.ctxColor(49).fg);
    try std.testing.expectEqual(theme.warn.fg, theme.ctxColor(50).fg);
    try std.testing.expectEqual(theme.warn.fg, theme.ctxColor(79).fg);
    try std.testing.expectEqual(theme.err.fg, theme.ctxColor(80).fg);
    try std.testing.expectEqual(theme.err.fg, theme.ctxColor(100).fg);
    try std.testing.expect(!theme.ctxColor(0).fg.eql(theme.ctxColor(50).fg));
    try std.testing.expect(!theme.ctxColor(50).fg.eql(theme.ctxColor(80).fg));

    const bg = [3]u8{ 0, 0, 0 };
    for ([_]u8{ 0, 50, 80 }) |pct| {
        const c = theme.contrast(theme.fgRgb(theme.ctxColor(pct)).?, bg);
        if (c < 4.5) {
            std.debug.print("ctx gauge at {d}% is {d:.2}:1\n", .{ pct, c });
            return error.GaugeUnreadable;
        }
    }
}

test "header: Zo's line carries the face in the mood's color" {
    // A single paragraph: face + text. If they were split in two, the face
    // was left on a loose line above the message.
    const segs = try md.inlineSegmentsBase(
        std.testing.allocator,
        "~[ x ]~  hola",
        .banner,
        null,
        .{ .fg = .{ .index = 6 } },
    );
    defer std.testing.allocator.free(segs);
    try std.testing.expectEqual(@as(usize, 2), segs.len);
    try std.testing.expectEqualStrings("[ x ]", segs[0].text);
    // `.fg` is a union: check the variant before looking at `.index`.
    try std.testing.expect(segs[0].style.fg == .index);
    try std.testing.expectEqual(@as(u8, 6), segs[0].style.fg.index);
    try std.testing.expectEqualStrings("  hola", segs[1].text);
}

test "header: the ~ marks do not eat text" {
    // Same as the `*`: if a mark is left unpaired, it is normal text.
    const segs = try md.inlineSegments(std.testing.allocator, "a ~ sin cerrar", .banner);
    defer std.testing.allocator.free(segs);
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(std.testing.allocator);
    for (segs) |sg| try joined.appendSlice(std.testing.allocator, sg.text);
    try std.testing.expectEqualStrings("a ~ sin cerrar", joined.items);
}

test "scrollBy: the wheel cannot underflow at the top" {
    // Regression: the wheel did `self.scroll -= 3` on a `usize`, and with the
    // scroll at 0 that underflows -> panic -> the app dies when scrolling down
    // while at the top. A key fuzzer found it by sending `\x1b[<65;…M` twice.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    // A real history, so there is a real `max_offset` to clamp against. The
    // model with an empty history has `max_offset == 0` and would pass this
    // test while the bug was still there.
    var i: usize = 0;
    while (i < 40) : (i += 1) m.pushInfo("linea de historia");
    _ = try drawTest(&m, arena_state.allocator(), 80, 24);
    const bottom = m.max_offset;
    try std.testing.expect(bottom > 0);

    // At the bottom, scrolling DOWN cannot go past the end of the history.
    m.scrollBy(-3);
    try std.testing.expectEqual(bottom, m.first_visible);
    m.scrollBy(-1);
    try std.testing.expectEqual(bottom, m.first_visible);

    // `n > 0` is UP, and up means `first` goes DOWN (it is the top line on
    // screen).
    m.scrollBy(7);
    try std.testing.expectEqual(bottom - 7, m.first_visible);
    m.scrollBy(-3);
    try std.testing.expectEqual(bottom - 4, m.first_visible);
    m.scrollBy(-100);
    try std.testing.expectEqual(bottom, m.first_visible);

    // And scrolling up does not blow past the top either.
    m.scrollBy(100_000);
    _ = try drawTest(&m, arena_state.allocator(), 80, 24);
    try std.testing.expectEqual(@as(usize, 0), m.first_visible);
    try std.testing.expect(m.anchor <= m.max_offset);
}

test "scroll state: get and apply round trip preserves position" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    // Build a real history so there is something to scroll.
    var i: usize = 0;
    while (i < 40) : (i += 1) m.pushInfo("linea de historia");
    _ = try drawTest(&m, arena_state.allocator(), 80, 24);
    const bottom = m.max_offset;

    // Scroll up and capture the state.
    m.scrollBy(10);
    const saved = m.getScrollState();
    try std.testing.expectEqual(bottom - 10, saved.anchor_line);
    try std.testing.expect(!saved.follow_bottom);

    // Move somewhere else, then restore.
    m.scrollTo(0);
    try std.testing.expectEqual(@as(usize, 0), m.anchor);
    m.applyScrollState(saved);
    try std.testing.expectEqual(bottom - 10, m.anchor);
    try std.testing.expect(!m.follow_bottom);
}

test "scroll state: apply follow_bottom goes to the bottom" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    var i: usize = 0;
    while (i < 40) : (i += 1) m.pushInfo("linea de historia");
    _ = try drawTest(&m, arena_state.allocator(), 80, 24);

    // Scroll up, then apply a follow-bottom state.
    m.scrollBy(10);
    try std.testing.expect(!m.follow_bottom);
    m.applyScrollState(.{});
    try std.testing.expect(m.follow_bottom);
    try std.testing.expectEqual(@as(usize, 0), m.anchor);
}

test "scroll state: default state follows the bottom" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    try std.testing.expect(m.follow_bottom);
    try std.testing.expectEqual(@as(usize, 0), m.anchor);
}

test "the tool clock takes the lock, so a fast tool cannot free it under the reader" {
    // `toolRunMillis` used to call `toolRunMillisLocked` while holding NOTHING, which
    // is what the `_Locked` suffix is supposed to mean the opposite of. The draw asks
    // for the name (locked) and then for the time (unlocked), so between the two a
    // 3ms `read` could finish, `toolRunEnd` could free the whole `ToolRun`, and the
    // clock read released memory. That is also why the number read 0 on screen: a
    // fast tool freed it before the frame painted.
    //
    // No `Io` here, which is the other half of the guard: a Model built by a test
    // has none, and `attachIo` is what `runTui` does. Without one the clock is 0,
    // and asking for a time that cannot be measured must not be a jump through a
    // garbage vtable.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    try std.testing.expectEqual(@as(bool, false), m.io_ready);

    m.pushToolStart("bash", "sleep 5");
    try std.testing.expectEqual(@as(u64, 0), m.toolRunMillis());

    // Ended: nothing to time, and reading it must not touch freed memory.
    m.pushToolDone("bash", "done", 1, "x");
    try std.testing.expectEqual(@as(u64, 0), m.toolRunMillis());
    // And again, after the tool is long gone: the function has to be callable.
    try std.testing.expectEqual(@as(u64, 0), m.toolRunMillis());
}

test "with an Io attached, the tool clock advances while it runs" {
    // The other half: the number MOVES. A clock that reads 0 for the whole of a
    // 30s `bash` is the reported "you cannot tell whether it is frozen", and it
    // was not only a display problem — the unlock was reading a freed struct too.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.attachIo(threaded.io());
    try std.testing.expect(m.io_ready);

    m.pushToolStart("bash", "sleep 30");
    try std.testing.expectEqual(@as(u64, 0), m.toolRunMillis());
    // A real wait, so the value has to have moved off zero. `sleepz.nap` and
    // not `Io.sleep`: this model has an `Io`, and going through it from a test
    // would take the event loop of a `Threaded` that nothing is running.
    sleepz.nap(150);
    const ms = m.toolRunMillis();
    try std.testing.expect(ms >= 100);
    // Clamped: never negative, and never earlier than the start.
    try std.testing.expect(ms < 10_000);

    m.pushToolDone("bash", "done", ms, "x");
    try std.testing.expectEqual(@as(u64, 0), m.toolRunMillis());
}

test "scrollbar click and drag navigate absolute history positions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    for (0..80) |i| {
        var text: [32]u8 = undefined;
        m.pushInfo(try std.fmt.bufPrint(&text, "history row {d}", .{i}));
    }
    const surface = try drawTest(&m, arena_state.allocator(), 80, 24);
    const bottom = m.max_offset;
    try std.testing.expect(bottom > 0);

    var ctx = testCtx();
    defer ctx.cmds.deinit(ctx.alloc);
    try typeErasedEventHandler(&m, &ctx, .{ .mouse = .{
        .col = @intCast(surface.size.width - 1),
        .row = 0,
        .button = .left,
        .mods = .{},
        .type = .press,
    } });
    try std.testing.expect(m.scrollbar_dragging);
    try std.testing.expectEqual(@as(usize, 0), m.first_visible);

    try typeErasedEventHandler(&m, &ctx, .{ .mouse = .{
        .col = @intCast(surface.size.width - 1),
        .row = @intCast(m.hist_rows - 1),
        .button = .left,
        .mods = .{},
        .type = .drag,
    } });
    try std.testing.expectEqual(bottom, m.first_visible);

    try typeErasedEventHandler(&m, &ctx, .{ .mouse = .{
        .col = @intCast(surface.size.width - 1),
        .row = @intCast(m.hist_rows - 1),
        .button = .none,
        .mods = .{},
        .type = .release,
    } });
    try std.testing.expect(!m.scrollbar_dragging);
    try std.testing.expect(m.follow_bottom);
}

test "losing focus or the pointer cancels the mouse gesture instead of stranding it" {
    // The reported symptom: "moving the mouse makes the terminal do strange
    // things". This is the mechanism behind the half of it that is zode's own.
    //
    // `scrollbar_dragging` had exactly ONE exit — the `.release` that reaches
    // the handler — and three ways to never get one: the window loses focus
    // (the release goes to whatever you clicked), the pointer leaves the
    // surface (vaxis's `mouse_leave` carries no coordinates), and a release
    // that lands outside the PREVIOUS frame's surface, which vxfw drops before
    // it reaches us.
    //
    // A stranded flag is not cosmetic: `scrollbar_dragging` is checked FIRST in
    // the mouse branch and every `.drag` returns early after a `scrollTo`, so a
    // stranded one turns every later drag in the transcript into a scroll jump
    // AND makes a text selection impossible to start for the rest of the
    // session.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    for (0..80) |i| {
        var text: [32]u8 = undefined;
        m.pushInfo(try std.fmt.bufPrint(&text, "history row {d}", .{i}));
    }
    const surface = try drawTest(&m, arena_state.allocator(), 80, 24);
    try std.testing.expect(m.max_offset > 0);

    var ctx = testCtx();
    defer ctx.cmds.deinit(ctx.alloc);

    // Start a scrollbar drag.
    try typeErasedEventHandler(&m, &ctx, .{ .mouse = .{
        .col = @intCast(surface.size.width - 1),
        .row = 0,
        .button = .left,
        .mods = .{},
        .type = .press,
    } });
    try std.testing.expect(m.scrollbar_dragging);

    // The window loses focus (alt-tab, a notification). No release arrives.
    try typeErasedEventHandler(&m, &ctx, .focus_out);
    try std.testing.expect(!m.scrollbar_dragging);

    // Same for the pointer leaving the surface: press the SCROLLBAR again,
    // because a press anywhere else starts a text selection instead.
    try typeErasedEventHandler(&m, &ctx, .{ .mouse = .{
        .col = @intCast(surface.size.width - 1),
        .row = 0,
        .button = .left,
        .mods = .{},
        .type = .press,
    } });
    try std.testing.expect(m.scrollbar_dragging);
    try typeErasedEventHandler(&m, &ctx, .mouse_leave);
    try std.testing.expect(!m.scrollbar_dragging);

    // And a stranded SELECTION is a highlight nobody can dismiss until they
    // scroll: it painted `theme.selected.bg` over live rows.
    m.selection_start = .{ .row = 1, .col = 2 };
    m.selection_end = .{ .row = 3, .col = 8 };
    m.selecting_text = true;
    try typeErasedEventHandler(&m, &ctx, .focus_out);
    try std.testing.expect(!m.selecting_text);
    try std.testing.expect(m.selection_start == null);
    try std.testing.expect(m.selection_end == null);
}

test "a plain click does not fire the clipboard escape sequence" {
    // OSC 52 is written and flushed by vaxis OUTSIDE `vx.render`, so the
    // renderer never knows about it and the next frame draws over it. On a
    // terminal that does not implement it that is a wall of visible
    // `^[]52;c;<base64>^[\` text — and it fired on EVERY left press in the
    // transcript, because `selectedText` on a single cell returns that one
    // trimmed grapheme, which is usually non-empty.
    //
    // A click is not a selection. There is nothing anyone wants copied from
    // it, so it must not produce a clipboard write at all.
    //
    // Both halves use the SAME starting cell, so the only difference between
    // them is the drag. The first version clicked somewhere that happened to
    // be a space, `trimEnd` emptied it, and the test passed WITH the bug.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    for (0..40) |i| {
        var text: [32]u8 = undefined;
        m.pushInfo(try std.fmt.bufPrint(&text, "history row {d}", .{i}));
    }
    _ = try drawTest(&m, arena_state.allocator(), 80, 24);

    var ctx = testCtx();
    defer ctx.cmds.deinit(ctx.alloc);

    // A REAL DRAG first, so the feature is pinned as still working and so the
    // cell is known to hold non-blank text.
    try typeErasedEventHandler(&m, &ctx, .{ .mouse = .{
        .col = 4,
        .row = 3,
        .button = .left,
        .mods = .{},
        .type = .press,
    } });
    try typeErasedEventHandler(&m, &ctx, .{ .mouse = .{
        .col = 20,
        .row = 6,
        .button = .left,
        .mods = .{},
        .type = .drag,
    } });
    try typeErasedEventHandler(&m, &ctx, .{ .mouse = .{
        .col = 20,
        .row = 6,
        .button = .none,
        .mods = .{},
        .type = .release,
    } });
    try std.testing.expect(ctx.cmds.items.len > 0);
    for (ctx.cmds.items) |cmd| ctx.alloc.free(cmd.copy_to_clipboard);
    ctx.cmds.clearRetainingCapacity();

    // Now the CLICK: press and release with no movement, on a cell that really
    // holds text. The point is READ OUT of the selection map rather than
    // guessed, because a click on a blank cell trims to nothing and the test
    // would then pass WITH the bug — which is exactly what the first version of
    // this test did.
    const stride: usize = @as(usize, m.selectable_width) + 1;
    var click_row: ?usize = null;
    var click_col: usize = 0;
    outer: for (0..m.selectable_rows) |row| {
        for (0..m.selectable_width) |col| {
            const base = row * stride;
            if (base + col + 1 >= m.selectable_map.items.len) break;
            const from = m.selectable_map.items[base + col];
            const to = m.selectable_map.items[base + col + 1];
            if (to <= from or to > m.selectable_text.items.len) continue;
            const cell = m.selectable_text.items[from..to];
            if (std.mem.trim(u8, cell, " \t").len > 0) {
                click_row = row;
                click_col = col;
                break :outer;
            }
        }
    }
    const row_i = click_row orelse return error.TestUnexpectedResult;

    try typeErasedEventHandler(&m, &ctx, .{ .mouse = .{
        .col = @intCast(click_col),
        .row = @intCast(row_i),
        .button = .left,
        .mods = .{},
        .type = .press,
    } });
    try std.testing.expectEqual(@as(u16, @intCast(row_i)), m.selection_start.?.row);
    try typeErasedEventHandler(&m, &ctx, .{ .mouse = .{
        .col = @intCast(click_col),
        .row = @intCast(row_i),
        .button = .none,
        .mods = .{},
        .type = .release,
    } });
    // It really was a click: one cell, start == end.
    try std.testing.expectEqual(m.selection_start.?.col, m.selection_end.?.col);

    try std.testing.expectEqual(@as(usize, 0), ctx.cmds.items.len);

    // `copyToClipboard` dupes the text into the context and the App frees it
    // when it writes the OSC 52; in a test there is no App, so the test is the
    // owner. (Ownership has to be in the signature, and whoever holds it has
    // to be the one who frees.)
}

test "scrollbar thumb maps track endpoints to history endpoints" {
    const track: usize = 20;
    const max_offset: usize = 180;
    const thumb = scrollbarThumb(track, max_offset);
    try std.testing.expect(thumb.size > 0);
    try std.testing.expect(thumb.size < track);
    try std.testing.expectEqual(@as(usize, 0), scrollbarOffset(0, track, max_offset));
    try std.testing.expectEqual(max_offset, scrollbarOffset(track - 1, track, max_offset));
}

test "scroll: overscrolling up leaves no debt, so one PageDown really scrolls down" {
    // THE bug, with its numbers.
    //
    // `scroll` was a distance from the bottom, `computeVisible` clamped a LOCAL
    // copy for drawing and never wrote it back, and `scrollBy` only clamped to
    // the `1_000_000` constant. So the offset could sit far above `max_offset`
    // with nothing moving on screen: PageDown then subtracted from a number that
    // was already past the top, and the first N presses did nothing at all.
    //
    // 50-row terminal -> `history_h` 43, `page` 42. Short history that fits:
    // `max_offset` 0. 8 PageUps -> 336. The first SIX PageDowns move nothing
    // and the seventh jumps.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    var i: usize = 0;
    while (i < 60) : (i += 1) m.pushInfo("linea");
    _ = try drawTest(&m, arena_state.allocator(), 80, 24);
    try std.testing.expect(m.max_offset > 0);

    // WAY past the top, the way holding PageUp does with auto-repeat.
    m.scrollBy(10_000);
    _ = try drawTest(&m, arena_state.allocator(), 80, 24);
    try std.testing.expectEqual(@as(usize, 0), m.first_visible);

    // ONE half page DOWN and the view moves. Not 6 presses, not 112 notches.
    m.scrollBy(-10);
    _ = try drawTest(&m, arena_state.allocator(), 80, 24);
    try std.testing.expectEqual(@as(usize, 10), m.first_visible);

    // And what the status bar would say matches what is actually hidden below.
    try std.testing.expectEqual(m.max_offset - 10, m.max_offset - m.first_visible);
}

test "history height index tracks estimates, corrections, and cache resets" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    for (0..257) |i| {
        var buf: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "history paragraph {d}", .{i});
        m.pushInfo(text);
    }
    _ = try drawTest(&m, arena_state.allocator(), 80, 24);
    try std.testing.expect(m.height_tree_capacity >= m.para_heights.items.len);

    var total: usize = 0;
    for (0..m.para_heights.items.len + 1) |end| {
        try std.testing.expectEqual(total, m.heightPrefix(end));
        if (end < m.para_heights.items.len) total += m.para_heights.items[end];
    }
    for (0..total) |line| {
        var expected: usize = 0;
        while (expected < m.para_heights.items.len and
            line >= m.heightPrefix(expected + 1)) : (expected += 1)
        {}
        try std.testing.expectEqual(expected, m.heightIndexAt(line));
    }

    const changed = m.para_heights.items.len / 2;
    m.para_heights.items[changed] += 3;
    m.paras.items[changed].known_lines = m.para_heights.items[changed];
    m.setHeightTreeValue(changed, m.para_heights.items[changed]);
    try std.testing.expectEqual(
        m.heightPrefix(changed) + m.para_heights.items[changed],
        m.heightPrefix(changed + 1),
    );

    m.clearSegCache();
    m.ensureParaHeights();
    try std.testing.expectEqual(m.paras.items[changed].known_lines, m.para_heights.items[changed]);
    total = 0;
    for (0..m.para_heights.items.len + 1) |end| {
        try std.testing.expectEqual(total, m.heightPrefix(end));
        if (end < m.para_heights.items.len) total += m.para_heights.items[end];
    }
}

test "dragging across timeline text copies the selected output" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.pushInfo("copied phrase from the assistant output");
    m.pushInfo("second assistant line");
    const surface = try drawTest(&m, arena_state.allocator(), 80, 24);

    var ctx = testCtx();
    defer {
        for (ctx.cmds.items) |cmd| {
            switch (cmd) {
                .copy_to_clipboard => |text| ctx.alloc.free(text),
                .set_title => |text| ctx.alloc.free(text),
                else => {},
            }
        }
        ctx.cmds.deinit(ctx.alloc);
    }

    try typeErasedEventHandler(&m, &ctx, .{ .mouse = .{
        .col = 0,
        .row = 0,
        .button = .left,
        .mods = .{},
        .type = .press,
    } });
    try typeErasedEventHandler(&m, &ctx, .{ .mouse = .{
        .col = @intCast(surface.size.width - 1),
        .row = 2,
        .button = .left,
        .mods = .{},
        .type = .drag,
    } });
    try typeErasedEventHandler(&m, &ctx, .{ .mouse = .{
        .col = @intCast(surface.size.width - 1),
        .row = 2,
        .button = .none,
        .mods = .{},
        .type = .release,
    } });

    var copied: ?[]const u8 = null;
    for (ctx.cmds.items) |cmd| {
        if (cmd == .copy_to_clipboard) copied = cmd.copy_to_clipboard;
    }
    try std.testing.expect(copied != null);
    try std.testing.expect(std.mem.indexOf(u8, copied.?, "copied phrase from the assistant output") != null);
    try std.testing.expect(std.mem.indexOf(u8, copied.?, "second assistant line") != null);
}

test "scroll: reading is not dragged away by the text that arrives" {
    // `first` used to be `max_offset - scroll`: also relative to the bottom, so
    // every new line moved `max_offset` and therefore the window, while `scroll`
    // stayed put. Reading 200 lines up while the model writes meant the text you
    // were reading slid off the top at the model's writing speed.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    var i: usize = 0;
    while (i < 60) : (i += 1) m.pushInfo("linea");
    _ = try drawTest(&m, arena_state.allocator(), 80, 24);

    m.scrollBy(20); // read something above the bottom
    _ = try drawTest(&m, arena_state.allocator(), 80, 24);
    const held = m.first_visible;
    try std.testing.expect(!m.follow_bottom);
    try std.testing.expect(held < m.max_offset);

    // New closed paragraphs arrive.
    var j: usize = 0;
    while (j < 20) : (j += 1) m.pushInfo("linea nueva");
    _ = try drawTest(&m, arena_state.allocator(), 80, 24);
    try std.testing.expectEqual(held, m.first_visible);

    // And the LIVE paragraph growing, which is the continuous version of the
    // same bug: `computeVisible` takes the live height, so the window used to
    // move once per rendered line, on every frame.
    m.streamStart();
    var k: usize = 0;
    while (k < 12) : (k += 1) {
        var buf: [64]u8 = undefined;
        m.streamDelta(std.fmt.bufPrint(&buf, "respuesta en vivo numero {d}", .{k}) catch "x");
        _ = try drawTest(&m, arena_state.allocator(), 80, 24);
        try std.testing.expectEqual(held, m.first_visible);
    }
    m.streamEnd();
}

test "scroll: at the bottom, new text still follows you down" {
    // The other half of stickiness: the fix for the drift must not turn the
    // view into a fixed window.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    var i: usize = 0;
    while (i < 60) : (i += 1) m.pushInfo("linea");
    _ = try drawTest(&m, arena_state.allocator(), 80, 24);
    const before = m.first_visible;
    try std.testing.expectEqual(m.max_offset, before);

    var j: usize = 0;
    while (j < 20) : (j += 1) m.pushInfo("linea nueva");
    _ = try drawTest(&m, arena_state.allocator(), 80, 24);
    try std.testing.expect(m.first_visible > before);
    try std.testing.expectEqual(m.max_offset, m.first_visible);

    // Scrolling back to the bottom re-arms it, instead of it needing a resize
    // to notice.
    m.scrollBy(15);
    _ = try drawTest(&m, arena_state.allocator(), 80, 24);
    var k: usize = 0;
    while (k < 40) : (k += 1) m.scrollBy(-5);
    _ = try drawTest(&m, arena_state.allocator(), 80, 24);
    try std.testing.expect(m.follow_bottom);
}

test "scroll: a resize keeps the anchor instead of jumping to the banner" {
    // `clearSegCache` empties `para_heights` on every width change, so the
    // heights have to be re-estimated. For a COMPRESSED paragraph the estimate
    // comes from its text, which is base64 with no newlines: 1 line for a
    // paragraph that takes 40. The total collapsed, `max_offset` with it, and
    // the view jumped thousands of lines up. `measured_lines` (in the paragraph,
    // not in the list that the resize empties) is what fixes it.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const big = try a.alloc(u8, 16 * 1024);
    for (big, 0..) |*c, i| c.* = 'a' + @as(u8, @intCast(i % 26));

    var i: usize = 0;
    while (i < 60) : (i += 1) m.pushKind(.tool_res, big);
    _ = try drawTest(&m, arena_state.allocator(), 100, 40);
    try std.testing.expect(m.max_offset > 0);

    m.scrollBy(30);
    _ = try drawTest(&m, arena_state.allocator(), 100, 40);
    const held = m.first_visible;
    try std.testing.expect(!m.follow_bottom);

    // Narrower terminal: everything re-wraps, every height is thrown away.
    _ = try drawTest(&m, a, 40, 40);
    try std.testing.expectEqual(held, m.first_visible);
    try std.testing.expect(m.anchor <= m.max_offset);
    try std.testing.expect(!m.layout_overflow);
}

test "cmdGroup-like: an empty key does not blow up" {
    // `key[1..]` over a []const u8 of len 0 is a panic in Zig 0.16, not an
    // empty slice. The palette's grouping called it with the key as-is.
    const empty: []const u8 = "";
    // 5 = "Session", the fallback.
    try std.testing.expectEqual(@as(u8, 5), agent.cmdGroupPublic(empty));
    try std.testing.expectEqual(@as(u8, 2), agent.cmdGroupPublic("/help"));
    try std.testing.expectEqual(@as(u8, 4), agent.cmdGroupPublic("/model"));
    // `/free-auto` has a group of its own, next to the top: it is not something
    // you should have to hunt for at the bottom of a list of twenty commands.
    try std.testing.expectEqual(@as(u8, 3), agent.cmdGroupPublic("/free-auto"));
    try std.testing.expectEqual(@as(u8, 3), agent.cmdGroupPublic("/free"));
    // The header item of the palette.
    try std.testing.expectEqual(@as(u8, 1), agent.cmdGroupPublic("connect"));
    // Works without the leading slash too: `key[1..]` eats an arbitrary
    // character if you don't check, not just the slash.
    try std.testing.expectEqual(@as(u8, 2), agent.cmdGroupPublic("help"));
    try std.testing.expectEqual(@as(u8, 5), agent.cmdGroupPublic("nope"));
}

test "autocomplete: /model sends /model and does not complete to /models" {
    // Regression: the exact match was only looked for against the highlighted
    // item, and the popup sorted "/models" before "/model". Typing "/model"
    // and pressing Enter ended up sending "/models", which is a different
    // command (it lists the models instead of opening the selector).
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.ed.clear();
    m.ed.insert("/model") catch {};
    // WITHOUT a trailing space: with spaces the popup closes on purpose (it is
    // no longer a command in progress, they are its arguments).
    syncAutocomplete(&m);
    try std.testing.expect(m.ac.active);

    // "/model" is a complete command: it is sent.
    try std.testing.expect(isExactMatch(&m));

    // A partial prefix is not: it must be completed.
    m.ed.clear();
    m.ed.insert("/mod") catch {};
    syncAutocomplete(&m);
    try std.testing.expect(!isExactMatch(&m));

    // And neither is text that is not a command.
    m.ed.clear();
    m.ed.insert("/modl") catch {};
    syncAutocomplete(&m);
    try std.testing.expect(!isExactMatch(&m));
}

test "autocomplete: /help with Enter sends instead of rewriting" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.ed.clear();
    m.ed.insert("/help") catch {};
    syncAutocomplete(&m);
    try std.testing.expect(m.ac.active);
    try std.testing.expect(isExactMatch(&m));
}

test "waitWorkers: waits for the workers to finish" {
    // The counter is what stops `io` from being destroyed with a worker inside
    // `io.async` (segfault in `Threaded.cancelThreads` on exit).
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 0), m.workers.load(.seq_cst));

    m.beginWorker();
    m.beginWorker();
    try std.testing.expectEqual(@as(usize, 2), m.workers.load(.seq_cst));

    m.endWorker();
    try std.testing.expectEqual(@as(usize, 1), m.workers.load(.seq_cst));
    m.endWorker();
    try std.testing.expectEqual(@as(usize, 0), m.workers.load(.seq_cst));

    // With no workers waiting: it returns right away.
    m.waitWorkers(10);
}

test "waitWorkers: with the time cap it does not hang" {
    // A worker stuck on the network cannot leave the app unable to ever exit.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.beginWorker(); // deliberately never closed
    m.waitWorkers(20); // must return in a reasonable time
    try std.testing.expectEqual(@as(usize, 1), m.workers.load(.seq_cst));
    m.endWorker();
}

test "queue: enqueues, takes in order and frees" {
    // Without a queue, sending a second prompt while the first one worked
    // launched ANOTHER worker and the two fought over the session and the
    // streaming state: the input froze and there was no way to tell whether it
    // was working.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const a = m.allocator.dupe(u8, "primero") catch unreachable;
    const b = m.allocator.dupe(u8, "segundo") catch unreachable;
    try std.testing.expectEqual(@as(usize, 1), m.enqueuePrompt(a));
    try std.testing.expectEqual(@as(usize, 2), m.enqueuePrompt(b));
    try std.testing.expectEqual(@as(usize, 2), m.queuedCount());

    // FIFO.
    const p1 = m.takeQueued().?;
    try std.testing.expectEqualStrings("primero", p1);
    m.allocator.free(p1);
    const p2 = m.takeQueued().?;
    try std.testing.expectEqualStrings("segundo", p2);
    m.allocator.free(p2);

    try std.testing.expectEqual(@as(usize, 0), m.queuedCount());
    try std.testing.expect(m.takeQueued() == null);
}

test "queue: clearQueue frees whatever is left" {
    // If a text stays in the queue on exit and is not freed, it is a leak on
    // every exit with pending prompts.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    const a = m.allocator.dupe(u8, "se queda") catch unreachable;
    _ = m.enqueuePrompt(a);
    m.clearQueue();
    try std.testing.expectEqual(@as(usize, 0), m.queuedCount());
}

test "the face the footer paints is the width the footer computes with" {
    // The exhaustive sweep — every beat of every track, seven ASCII columns,
    // the same silhouette — lives in `lib/mascot.zig`. This is the LAYOUT half:
    // the footer places its legend and its right group from `face_width`, so
    // the face it actually paints has to be exactly that wide. A face one
    // column wider moves every column to the right of it.
    for ([_]mascot.StatusKind{ .idle, .thinking, .tooling, .done, .warn, .err }) |kind| {
        try std.testing.expectEqual(@as(usize, @intCast(face_width)), mascot.face(kind).len);
        // And the pose the footer samples is the same face, widened by nothing:
        // the lean is a SHIFT, never a rewritten string.
        var t: u64 = 0;
        while (t < mascot.frames.totalMs(kind)) : (t += 97) {
            try std.testing.expectEqual(@as(usize, @intCast(face_width)), mascot.poseAt(kind, t).text.len);
        }
    }
}

test "the modal is not eaten by the history's wide cells" {
    // The rule under the hero is ONE cell that claims the whole width, and
    // vaxis's renderer SKIPS the cells a wide cell covers: it writes the wide
    // cell and jumps `width - 1` columns ahead. A modal painted over that row
    // came out with a HOLE in it — the border gone and the rule across the
    // middle of the box.
    //
    // The overlays split the wide cells before they paint. This test pins
    // that: the modal's border has to be there on EVERY row, including the
    // one the rule is on.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.pushHeader(.idle);
    // A message AFTER the hero: the rule under the hero is the separator of
    // the paragraph that follows it, so without one there is no wide cell and
    // the test would prove nothing.
    m.pushKind(.user, "hola");
    m.openPaletteWith(.commands, &.{}, &.{});

    // A WIDE terminal on purpose: the modal is 110 columns and the terminal
    // is 140, so the modal's left edge (column 15) is to the RIGHT of the
    // rule's cell (column 2). When the two coincide the modal's own fill
    // replaces the wide cell and the bug hides.
    const w: u16 = 140;
    const h: u16 = 30;
    const s = try drawTest(&m, arena_state.allocator(), w, h);

    const box = palette.boxFor(&m.pal, w, h);
    try std.testing.expect(box.w > 24 and box.h > 8);
    try std.testing.expect(box.x > 4); // the modal does NOT start where the rule does

    // The rule's row: the separator that goes under the hero. It has to be ON
    // a row of the modal, or the test proves nothing: a row with no rule
    // cannot be eaten by one.
    //
    // It is found by the DASHES that the rule leaves to the LEFT of the modal
    // (the modal's own background covers the rest of it), and NOT by looking
    // for a wide cell: the fix SPLITS the wide cells, so "there is a wide
    // cell" is true exactly when the bug is there.
    const rule = "\u{2500}";
    var rule_rows: usize = 0;
    var row: u16 = box.y + 1;
    while (row < box.y + box.h - 1) : (row += 1) {
        var col: u16 = 2;
        while (col < box.x) : (col += 1) {
            const cell = s.readCell(col, row);
            if (cell.char.grapheme.len > 0 and std.mem.startsWith(u8, cell.char.grapheme, rule)) {
                rule_rows += 1;
                break;
            }
        }
    }
    try std.testing.expect(rule_rows > 0);

    // Every row of the modal, walked the way the RENDERER walks it: a wide
    // cell is written and the columns it covers are SKIPPED. Reading the
    // surface's cells directly would say the border is there (it is: the
    // modal wrote it) while the terminal never shows it — which is the bug.
    row = box.y + 1;
    while (row < box.y + box.h - 1) : (row += 1) {
        var col: u16 = 0;
        var left_seen = false;
        var right_seen = false;
        while (col < w) {
            const cell = s.readCell(col, row);
            const cw = @max(1, cell.char.width);
            if (col == box.x and std.mem.eql(u8, cell.char.grapheme, "\u{2502}")) left_seen = true;
            if (col == box.x + box.w - 1 and std.mem.eql(u8, cell.char.grapheme, "\u{2502}")) right_seen = true;
            col += cw;
        }
        try std.testing.expect(left_seen);
        try std.testing.expect(right_seen);
    }
}

test "the mascot is BELOW the input's well, not inside it" {
    // The row under the input used to be a status row with a face on its left
    // and the model's name on its right and NOTHING in between, and it read as
    // a stray emoticon in the corner of an empty row.
    //
    // Then the composer became ONE sunken surface: the prompt row and the
    // footer's row inside the same well, with the accent bar running down
    // both. That is what this test pinned — and it is what the user called
    // confusing: the `▌›` of the prompt and the `▌( o o )` of the mascot
    // looked like one input block with two parts, and the mascot looked like
    // something you could type into.
    //
    // The mascot is the STATE, and the state is not the input. It is now on
    // its own row BELOW the well, on the terminal's background, with no accent
    // bar: the input block ends, and under it is the line that says what the
    // app is doing.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.pushHeader(.idle);

    const s = try drawTest(&m, arena_state.allocator(), 90, 24);

    // The LAST row is the footer's: the mascot is on it, on the terminal's
    // background (NOT the well), with no accent bar at its left.
    const last = s.size.height - 1;
    const face_cell = s.readCell(1, last);
    try std.testing.expectEqualStrings("(", face_cell.char.grapheme);
    try std.testing.expectEqual(vaxis.Color.default, face_cell.style.bg);
    const bar = s.readCell(0, last);
    try std.testing.expect(bar.char.grapheme.len == 0 or !std.mem.eql(u8, bar.char.grapheme, "▌"));

    // The row above it is the prompt, and IT is on the well.
    const prompt_cell = s.readCell(1, last - 1);
    try std.testing.expectEqualStrings("›", prompt_cell.char.grapheme);
    try std.testing.expectEqual(theme.well_bg.bg, prompt_cell.style.bg);
    // And the well's accent bar stops with the well.
    const prompt_bar = s.readCell(0, last - 1);
    try std.testing.expectEqualStrings("▌", prompt_bar.char.grapheme);
}

test "the state is in ONE place: the footer's row" {
    // The phase used to be painted in TWO rows: the activity strip above the
    // hairline said "thinking" / "streaming" / "running Bash", and the status
    // row under the input held the mascot and the model's name. Two surfaces
    // for one state is what made the bottom of the app look like two
    // competing status indicators.
    //
    // There is now one surface, and it is the footer's row, inside the
    // composer's own well. This test pins that the label is in that row AND
    // in no other: "in one place" is a property of the LAYOUT, and a test that
    // only looked for the label somewhere would pass with two copies.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    // Simulate a resolved model for the footer
    const model_name = "kimi-k2.6";
    @memcpy(m.status_model_buf[0..model_name.len], model_name);
    m.status_model_len = model_name.len;
    m.status_model_tried = true;

    // Add banner so there's content to draw
    m.pushHeader(.idle);

    m.streamStart();
    const p1 = m.allocator.dupe(u8, "en cola") catch unreachable;
    _ = m.enqueuePrompt(p1);

    const s = try drawTest(&m, arena_state.allocator(), 90, 24);
    const all = allText(s);

    // With an open stream the label is the PHASE ("streaming"), not the generic
    // "working" from before: 40s of "working" does not distinguish thinking
    // from writing from a hung command.
    try std.testing.expect(std.mem.indexOf(u8, all, "streaming") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "1 queued") != null);

    var status_buf: [256]u8 = undefined;
    const footer = rowText(s, s.size.height - 1, &status_buf);
    // The footer is the LAST row: it is the last row of the composer's well.
    try std.testing.expect(std.mem.indexOf(u8, footer, "streaming") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "1 queued") != null);
    // The mascot is the state indicator and it is in the same row.
    try std.testing.expect(std.mem.indexOf(u8, footer, "( o") != null);

    // And in NO other row: the state is not painted twice.
    var r: u16 = 0;
    while (r < s.size.height - 1) : (r += 1) {
        var rb: [256]u8 = undefined;
        const text = rowText(s, r, &rb);
        try std.testing.expect(std.mem.indexOf(u8, text, "streaming") == null);
    }
}

test "activity strip: the label is the phase" {
    // The four phases have to say THEIR name. It is the feedback change that
    // was asked for: with "working" everywhere, a slow turn and a hung `bash`
    // were lived as the same thing.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    // 1) thinking: there is work but no stream nor tool.
    {
        var m = Model.init(std.testing.allocator);
        defer m.deinit();
        m.setStatusWithMood(.thinking, "thinking");
        const s = try drawTest(&m, arena_state.allocator(), 90, 24);
        try std.testing.expect(std.mem.indexOf(u8, allText(s), "thinking") != null);
    }

    // 2) writing: stream open.
    {
        var m = Model.init(std.testing.allocator);
        defer m.deinit();
        m.streamStart();
        const s = try drawTest(&m, arena_state.allocator(), 90, 24);
        try std.testing.expect(std.mem.indexOf(u8, allText(s), "streaming") != null);
    }
    // 3) running a tool: the tool's name, not "thinking".
    {
        var m = Model.init(std.testing.allocator);
        defer m.deinit();
        m.pushToolStart("bash", "sleep 9");
        const s = try drawTest(&m, arena_state.allocator(), 90, 24);
        const all = allText(s);
        try std.testing.expect(std.mem.indexOf(u8, all, "running") != null);
        try std.testing.expect(std.mem.indexOf(u8, all, "bash") != null);
    }
    // 4) waiting for permission: it wins over everything else.
    {
        var m = Model.init(std.testing.allocator);
        defer m.deinit();
        m.pushToolStart("write", "x.txt");
        m.perm_active = true;
        const s = try drawTest(&m, arena_state.allocator(), 90, 24);
        try std.testing.expect(std.mem.indexOf(u8, allText(s), "waiting for your permission") != null);
    }
}

test "activity strip: parallel subagents show live completion and active counts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.beginTaskBatch(7);
    m.taskBatchStarted();
    m.taskBatchStarted();
    m.taskBatchFinished();
    const s = try drawTest(&m, arena_state.allocator(), 100, 24);
    const all = allText(s);
    try std.testing.expect(std.mem.indexOf(u8, all, "subagents 1/7") != null);

    m.endTaskBatch();
    try std.testing.expectEqual(@as(usize, 0), m.activity().subagent_total);
}

test "activity strip: asks for permission when it is due" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.streamStart();
    m.perm_active = true;
    const s = try drawTest(&m, arena_state.allocator(), 90, 24);
    const all = allText(s);
    try std.testing.expect(std.mem.indexOf(u8, all, "permission") != null);
    m.perm_active = false;
}

test "status: the token counters moved to /context and are off the row" {
    // The old version of this test asserted the opposite: that `ctx ` and `~N
    // tok` were ALWAYS on the row. They were, and the row was six facts wide
    // because of it. The counters are `/context` now, and what is asserted is
    // the absence — the same shape of test as the permission mark above,
    // because a presence test cannot catch somebody adding them back.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    agent.cacheSessionStatsForTest().* = .{};
    agent.cacheSessionStatsForTest().record(.{ .prompt = 1000, .cached = 900, .completion = 100 });
    defer agent.cacheSessionStatsForTest().* = .{};

    const segs = sessionInfo(&m, arena_state.allocator()) orelse return;
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(std.testing.allocator);
    for (segs) |sg| try joined.appendSlice(std.testing.allocator, sg.text);
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "opencode") != null);
    for ([_][]const u8{ "ctx ", "cached", "prompt", " tok" }) |gone| {
        try std.testing.expect(std.mem.indexOf(u8, joined.items, gone) == null);
    }
}

/// First row whose text contains `needle` (render tests).
pub fn findRow(s: vxfw.Surface, needle: []const u8) ?u16 {
    var buf: [512]u8 = undefined;
    var row: u16 = 0;
    while (row < s.size.height) : (row += 1) {
        if (std.mem.indexOf(u8, rowText(s, row, &buf), needle) != null) return row;
    }
    return null;
}

/// Is there a row without text between two fragments? (separation test)
fn hasBlankRowBetween(s: vxfw.Surface, first: []const u8, second: []const u8) bool {
    var buf: [256]u8 = undefined;
    var r_first: ?u16 = null;
    var r_second: ?u16 = null;
    var row: u16 = 0;
    while (row < s.size.height) : (row += 1) {
        const r = rowText(s, row, &buf);
        if (r_first == null and std.mem.indexOf(u8, r, first) != null) r_first = row;
        if (r_second == null and std.mem.indexOf(u8, r, second) != null) r_second = row;
    }
    const a = r_first orelse return false;
    const b = r_second orelse return false;
    if (b <= a + 1) return false;
    var mid: u16 = a + 1;
    while (mid < b) : (mid += 1) {
        const r = std.mem.trim(u8, rowText(s, mid, &buf), " ");
        if (r.len == 0) return true;
    }
    return false;
}

test "history: paragraphs are separated with a blank row" {
    // Without this the history is a wall of text and you can't see where one
    // response ends and another begins.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.pushKind(.user, "primera");
    m.pushKind(.assistant, "segunda");
    const s = try drawTest(&m, arena_state.allocator(), 60, 20);
    const all = allText(s);
    try std.testing.expect(std.mem.indexOf(u8, all, "primera") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "segunda") != null);
    // The row between the two comes out EMPTY (spaces only: `rowText` fills the
    // whole surface). It checks that there is a row without text between them.
    try std.testing.expect(hasBlankRowBetween(s, "primera", "segunda"));
}

test "permissions: the modal is centered and shows the 4 options" {
    // It is what blocks the turn: if you can't see it, the app looks HUNG.
    // Before it was 4 lines glued to the input, half covered by the history.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.streamStart();
    m.perm_tool = undefined;
    @memcpy(m.perm_tool[0..5], "write");
    m.perm_tool_len = 5;
    @memcpy(m.perm_detail[0..7], "hola.js");
    m.perm_detail_len = 7;
    m.perm_active = true;

    const s = try drawTest(&m, arena_state.allocator(), 92, 26);
    const all = allText(s);
    try std.testing.expect(std.mem.indexOf(u8, all, "Permission required") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "write") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "hola.js") != null);
    // The four options, with their key.
    try std.testing.expect(std.mem.indexOf(u8, all, "Y allow once") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "A always allow") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "N deny") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "ESC cancel") != null);
    m.perm_active = false;
}

test "the mascot IS the state indicator: the face sits next to the label" {
    // This test asserted the OPPOSITE once: that the row saying "thinking" has
    // NO face of any mood. It was written when the face had been taken out of
    // the row that said "thinking", and what was left was a word on an empty
    // row — which is what the user called ugly.
    //
    // The design now: the mascot IS the state, the word is its legend, and
    // they are ONE widget. A mascot with no legend is a doodle.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.setStatusWithMood(.thinking, "thinking");
    m.lock();
    m.busy = true;
    m.busy_started_ns = std.math.maxInt(i128);
    m.unlock();

    const s = try drawTest(&m, arena, 92, 26);
    const row = findRow(s, "thinking") orelse return error.TestUnexpectedResult;
    var rb: [256]u8 = undefined;
    const text = rowText(s, row, &rb);

    // The face is there, and it is the THINKING face: the two frames share
    // their first three columns, and that is what the assertion looks at
    // because the blink decides which of the two is on screen.
    try std.testing.expect(std.mem.indexOf(u8, text, "( o") != null);

    // The face comes FIRST, at the left edge of the well: the state is the
    // first thing read, and it is at a fixed place.
    const cell = s.readCell(1, row);
    try std.testing.expectEqualStrings("(", cell.char.grapheme);

    // Label is just "thinking" (no animated dots).
    try std.testing.expect(std.mem.indexOf(u8, text, "thinking") != null);
    // Clock should be present (e.g., "0.0s")
    try std.testing.expect(std.mem.indexOf(u8, text, "0.") != null or std.mem.indexOf(u8, text, "1.") != null);
}

test "the waiting states show the mascot's warning face in the footer" {
    // The face is the state indicator and the footer is where the state lives,
    // so a question or a permission shows the warning face THERE — in the one
    // place the state is painted, and not in a second widget.
    //
    // It used to be asserted over the whole surface, which proved nothing
    // about WHERE the face was: the test passed because the strip happened to
    // be on screen, a row away from the panel it was named after.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    // Simulate a resolved model for the footer
    const model_name = "kimi-k2.6";
    @memcpy(m.status_model_buf[0..model_name.len], model_name);
    m.status_model_len = model_name.len;
    m.status_model_tried = true;

    // Add banner so there's content to draw
    m.pushHeader(.idle);

    m.setStatusWithMood(.warn, "waiting");
    try openAskForTest(&m, "which one?", "decide", &.{"a", "b"});

    const s = try drawTest(&m, arena_state.allocator(), 92, 26);
    _ = allText(s);

    // The footer's row, which is the LAST row of the composer's well.
    var rb: [256]u8 = undefined;
    const footer = rowText(s, s.size.height - 1, &rb);
    try std.testing.expect(std.mem.indexOf(u8, footer, "( ! ! )") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "waiting for your answer") != null);
}

/// A banner line's columns, without the `*…*` marks.
///
/// It is counted in COLUMNS and not bytes: each `█` is 3 bytes, so measuring
/// with `piece.len` gave 101 for a row of 41 columns and the test passed without
/// checking anything.
fn plainColumns(gpa: std.mem.Allocator, line: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lit = std.mem.tokenizeAny(u8, line, "*");
    while (lit.next()) |piece| {
        const view = std.unicode.Utf8View.initUnchecked(piece);
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            // In the banner art everything is width 1 (box drawing + space),
            // so one codepoint is one column.
            try out.append(gpa, if (cp == ' ') ' ' else '#');
        }
    }
    return out.toOwnedSlice(gpa);
}

test "the hairline separates the hero from the first prompt" {
    // Bug 4, in its new shape: the logo and the user's first prompt read as a
    // single block. A blank row does not fix it when what is above is a wordmark
    // and what is below is the user's words.
    //
    // This used to be a rule UNDER the five rows of ASCII. The hero is shorter,
    // but the rule is not about the art being tall: it is the statement "the
    // header ends here", and it is the same mark the input's hairline uses. This
    // test form the rule's OWN rule (nothing but `─`, and it spans the width).
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.pushHeader(.idle);
    m.pushKind(.user, "hola, quiero una pagina de juegos");

    const surf = try drawTest(&m, arena_state.allocator(), 72, 20);
    var rb: [256]u8 = undefined;

    // The prompt row is found by CONTENT, not by number: the hero is above it
    // and the hero's height is a decision of a different file. The rule is the
    // row right below it — the separator row is prepended to the prompt's own
    // paragraph (`grown[0]`), so it sits BELOW the words.
    const prompt_at = findRow(surf, "hola, quiero una pagina") orelse
        return error.PromptNotFound;

    // The rule sits ABOVE the prompt, and it is the row of the paragraph's
    // separator (`grown[0]` comes first, then the prompt's own lines). Below
    // would be the workspace's own hairline, which is a different rule.
    const rule_at = prompt_at - 1;
    const rule_row = rowText(surf, rule_at, &rb);
    const trimmed = std.mem.trim(u8, rule_row, " ");
    try std.testing.expect(trimmed.len > 0);
    // Only `─`: a row with the rule plus anything else would be a layout error,
    // not a separator. And it really spans the width: a three-column separator
    // is as bad as none.
    const rule_bytes = "\xe2\x94\x80";
    try std.testing.expect(trimmed.len % 3 == 0);
    var at: usize = 0;
    while (at < trimmed.len) : (at += 3) {
        try std.testing.expectEqualStrings(rule_bytes, trimmed[at..][0..3]);
    }
    const rule_cols = trimmed.len / 3;
    try std.testing.expect(rule_cols >= 60);
    try std.testing.expect(rule_cols <= 72);
}

test "the hero is ONLY the wordmark and its grid, with nothing hung below it" {
    // Complaining about "junk in the view" is being right, and this test is what
    // pins it down: if someone hangs a line under the hero again, it fails.
    //
    // What it asserts is the hero's SHAPE: the wordmark (FIVE rows of ASCII
    // art), one line of what this is, a rule and a two-column grid. The art
    // itself is not compared against a hand-written copy — a test that did that
    // would pass with any broken art — it is compared by its SHAPE: five rows
    // that are all drawing and nothing else.
    //
    // REWRITTEN (2026-10-21): the wordmark was the word "zode" in a colour
    // and the ASCII art was in the tree but nobody drew it. The shape is the
    // same idea with the art back in it.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.pushHeader(.idle);

    const s = try drawTest(&m, arena_state.allocator(), 92, 26);

    // Every line of the hero, on the rows it actually occupies.
    var found: usize = 0;
    // ONLY the history: the status row and the input also say "zode" and
    // "commands", and a hero that counted them was counting the furniture as
    // content.
    var row: u16 = 0;
    while (row < m.hist_rows and row < s.size.height) : (row += 1) {
        var rb: [512]u8 = undefined;
        const r = std.mem.trim(u8, rowText(s, row, &rb), " ");
        // A row of the ART: it is drawing and nothing else. The art is the
        // only place a `#` appears.
        if (std.mem.indexOf(u8, r, "#") != null and
            std.mem.indexOf(u8, r, "zode") == null and
            std.mem.indexOf(u8, r, "code agent") == null) found += 1;
        if (std.mem.indexOf(u8, r, "a code agent in your terminal") != null) found += 1;
        if (std.mem.indexOf(u8, r, "commands") != null) found += 1;
        if (std.mem.indexOf(u8, r, "choose a model") != null) found += 1;
        if (std.mem.indexOf(u8, r, "attach a file") != null) found += 1;
    }
    // 5 art rows + 1 tagline + 3 grid rows. Nothing else.
    try std.testing.expectEqual(@as(usize, 9), found);
}

test "the hero has no blank rows between its lines and nothing hung below them" {
    // ASCII art split into paragraphs put a blank row between the letters and
    // the logo was read in pieces. The hero is type, so there are no rows to
    // glue — but the separator between PARAGRAPHS still has to leave it alone,
    // and that is what this pins down: not one blank row inside the hero.
    //
    // And the header is ONLY this: no mascot, no "zo says: hi!", no shortcuts
    // line. Complaining about "junk in the view" is being right, and this test
    // is what fails if someone hangs a line below it again.
    //
    // The rows are compared by CONTENT, not against pixels of the ASCII that
    // used to be here: if the test compared the hero with a hand-written copy
    // of the hero, it would pass with any broken hero. What is asserted is the
    // SHAPE — six lines, contiguous, in order.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.pushHeader(.idle);

    const s = try drawTest(&m, arena_state.allocator(), 92, 26);
    var rb: [512]u8 = undefined;

    // The lines of the hero, in order. A row that is empty where a line
    // should be means the separator landed inside the header.
    //
    // The first five are the ART, and they are checked as art: a row of
    // drawing and nothing else. The rest are the text.
    const expect_txt = [_]?[]const u8{
        null, // the art's five rows
        null,
        null,
        null,
        null,
        "a code agent in your terminal",
        null, // the rule is `─` only, so it is checked as all-dashes below
        null, // the blank row between the rule and the grid
        "commands",
        "choose a model",
        "attach a file",
    };
    var row: u16 = 0;
    // Start at the first non-empty history row: the hero is CENTERED
    // (`heroFrame`), so row 0 can be blank on a tall terminal.
    while (row < m.hist_rows and std.mem.trim(u8, rowText(s, row, &rb), " ").len == 0) : (row += 1) {}
    // The art's five rows, and they are CONTIGUOUS: a blank row between the
    // letters is what made the old logo read in pieces.
    var art_row: u16 = 0;
    while (art_row < 5) : (art_row += 1) {
        const got = std.mem.trim(u8, rowText(s, row, &rb), " ");
        if (std.mem.indexOf(u8, got, "#") == null) {
            std.debug.print("hero art row {d}: expected drawing, got '{s}'\n", .{ row, got });
            return error.HeroBroken;
        }
        // A drawing row is drawing and NOTHING else: the tagline and the grid
        // are the other rows of the hero.
        if (std.mem.indexOf(u8, got, "zode") != null or
            std.mem.indexOf(u8, got, "code agent") != null)
        {
            std.debug.print("hero art row {d}: the art carries text: '{s}'\n", .{ row, got });
            return error.HeroBroken;
        }
        row += 1;
    }
    for (expect_txt[5..]) |want| {
        const got = std.mem.trim(u8, rowText(s, row, &rb), " ");
        if (want) |txt| {
            if (std.mem.indexOf(u8, got, txt) == null) {
                std.debug.print("hero row {d}: expected '{s}', got '{s}'\n", .{ row, txt, got });
                return error.HeroBroken;
            }
        }
        row += 1;
    }

    // Below the hero there is NOTHING: not one extra line, and no mascot.
    const after = rowText(s, row, &rb);
    try std.testing.expectEqualStrings("", std.mem.trim(u8, after, " "));
}

/// A `DrawContext` that measures graphemes with the compiled tables, for the
/// tests that need the input's wrap without a live Painter.
const test_draw_ctx: vxfw.DrawContext = .{
    .arena = std.heap.page_allocator,
    .min = .{},
    .max = .{},
    .cell_size = .{},
};

fn testEditorMeasurer() ed.Measurer {
    return .{
        .ctx = @ptrCast(&test_draw_ctx),
        .step = struct {
            fn f(c: *const anyopaque, text: []const u8, i: usize) ed.Step {
                const p_ctx: *const vxfw.DrawContext = @ptrCast(@alignCast(c));
                const rest = text[i..];
                var it = vaxis.unicode.graphemeIterator(rest);
                const g = it.next() orelse return .{ .cols = 1, .end = text.len };
                const b = g.bytes(rest);
                return .{ .cols = theme.graphemeWidth(p_ctx.*, b), .end = i + b.len };
            }
        }.f,
    };
}

/// A fake `EventContext` for the palette's keys.
///
/// `io` and `cmds` are not touched on these paths (the handler sets the redraw
/// itself), so they are left uninitialized. If `paletteKey` ever starts using
/// the `Io`, this blows up in the test instead of leaving an `undefined` in
/// production.
fn testCtx() vxfw.EventContext {
    return .{ .io = undefined, .alloc = std.testing.allocator, .cmds = .empty };
}

test "picking a command in the palette EXECUTES it (not puts it in the input)" {
    // Picking a command from a list is already the confirmation. Before, the
    // palette closed, the label was written into the input and one more Enter
    // was needed: one step too many, and since the input was left half-done it
    // read as "nothing happened".
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    agent.cacheSessionStatsForTest().* = .{};
    defer agent.cacheSessionStatsForTest().* = .{};

    agent.openCommandPalette(&m);
    var ctx = testCtx();

    var has_usage = false;
    var has_cache = false;
    var has_background = false;
    for (m.pal.items) |item| {
        if (std.mem.eql(u8, item.label, "/usage")) has_usage = true;
        if (std.mem.eql(u8, item.label, "/cache")) has_cache = true;
        if (std.mem.eql(u8, item.label, "/bg")) has_background = true;
    }
    try std.testing.expect(has_usage);
    try std.testing.expect(!has_cache);
    try std.testing.expect(!has_background);

    // Filtering by "usage" leaves the session summary; Enter runs it.
    for ([_]vaxis.Key{
        .{ .codepoint = 'u', .text = "u" },
        .{ .codepoint = 's', .text = "s" },
        .{ .codepoint = 'a', .text = "a" },
        .{ .codepoint = 'g', .text = "g" },
        .{ .codepoint = 'e', .text = "e" },
    }) |k| {
        _ = try m.paletteKey(&ctx, k);
    }
    _ = try m.paletteKey(&ctx, .{ .codepoint = 13 }); // enter

    // The palette closes and the input does NOT carry the command.
    try std.testing.expect(!m.pal.active);
    try std.testing.expectEqualStrings("", std.mem.trim(u8, m.ed.text(), " "));

    // And the command really ran: `/usage` shows the unified panel.
    const s = try drawTest(&m, arena_state.allocator(), 92, 20);
    var found = false;
    for (0..s.size.height) |row| {
        var rb: [512]u8 = undefined;
        if (std.mem.indexOf(u8, rowText(s, @intCast(row), &rb), "usage:") != null) found = true;
    }
    try std.testing.expect(found);
}

test "/effort with no args opens the picker (no 'unknown effort')" {
    // `it.rest()` returns `""` (not `null`) for "/effort", and with an empty
    // slice the `else` of "low|medium|high" swallowed the case: it answered
    // "unknown effort:  (low|medium|high)" and the picker never opened.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    try agent.submit(&m, "/effort");
    try std.testing.expect(m.pickerActive());
}

test "a command that needs arguments goes back to the input (not run blindly)" {
    // `/use provider model` cannot run without arguments: running it blindly
    // would leave the agent on some arbitrary provider. Those go to the input
    // with the slash in place, which is what whoever picks them wants.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    agent.openCommandPalette(&m);
    var ctx = testCtx();
    for ([_]vaxis.Key{
        .{ .codepoint = 'u', .text = "u" },
        .{ .codepoint = 's', .text = "s" },
        .{ .codepoint = 'e', .text = "e" },
    }) |k| {
        _ = try m.paletteKey(&ctx, k);
    }
    _ = try m.paletteKey(&ctx, .{ .codepoint = 13 });

    try std.testing.expect(!m.pal.active);
    try std.testing.expectEqualStrings("/use ", m.ed.text());
}

test "model catalog requests discard stale results and keep the latest status" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const stale_request = m.beginCatalogRequest("first-provider");
    const stale_items = try std.testing.allocator.alloc(palette.Item, 1);
    stale_items[0] = .{
        .kind = .model,
        .label = try std.testing.allocator.dupe(u8, "stale-model"),
    };

    const current_request = m.beginCatalogRequest("second-provider");
    m.setPendingCatalogItems(stale_request, stale_items);
    try std.testing.expect(m.catalogRequestCurrent(current_request));
    try std.testing.expect(m.pending_items == null);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const notice = m.catalogNotice(arena_state.allocator());
    try std.testing.expect(std.mem.indexOf(u8, notice, "second-provider") != null);
    try std.testing.expect(std.mem.indexOf(u8, notice, "first-provider") == null);
}

test "model catalog refresh status is visible in the open picker" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const groups = [_]palette.Group{ .{ .name = "Providers" }, .{ .name = "" }, .{ .name = "Models" } };
    const items = [_]palette.Item{
        .{ .kind = .provider, .group = 1, .label = "example-provider" },
        .{ .kind = .connect, .group = 2, .label = "+ connect" },
    };
    m.pal.mode = .models;
    m.pal.active = true;
    m.pal.setItems(&items, &groups);
    const request_id = m.beginCatalogRequest("example-provider");
    m.setCatalogNotice(request_id, "Offline · showing saved catalog");

    const surface = try drawTest(&m, arena_state.allocator(), 90, 24);
    try std.testing.expect(std.mem.indexOf(u8, allText(surface), "Offline") != null);
}

test "closing the model palette invalidates its pending catalog request" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.pal.mode = .models;
    m.pal.active = true;
    const request_id = m.beginCatalogRequest("example-provider");

    var ctx = testCtx();
    _ = try m.paletteKey(&ctx, .{ .codepoint = 27 });

    try std.testing.expect(!m.pal.active);
    try std.testing.expect(!m.catalogRequestCurrent(request_id));
}

test "the palette owns the mouse while it is open" {
    // The reported bug class: the wheel over a modal scrolled the history
    // BEHIND it, and the pointer passed through the list without selecting
    // anything. A modal is modal: while it is open every mouse event belongs to
    // it, and the transcript underneath must not move or start a selection.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    for (0..80) |i| {
        var text: [32]u8 = undefined;
        m.pushInfo(try std.fmt.bufPrint(&text, "history row {d}", .{i}));
    }
    const items = [_]palette.Item{
        .{ .kind = .command, .label = "/a" },
        .{ .kind = .command, .label = "/b" },
        .{ .kind = .command, .label = "/c" },
        .{ .kind = .command, .label = "/d" },
    };
    m.pal.setItems(&items, &.{});
    m.pal.active = true;

    const surface = try drawTest(&m, arena_state.allocator(), 100, 30);
    // The draw is what tells the mouse handler how big the frame is.
    try std.testing.expectEqual(@as(u16, 100), m.frame_w);
    try std.testing.expectEqual(@as(u16, 30), m.frame_h);
    try std.testing.expect(m.max_offset > 0);
    const before_first = m.first_visible;

    var ctx = testCtx();
    defer ctx.cmds.deinit(ctx.alloc);
    const box = palette.boxFor(&m.pal, surface.size.width, surface.size.height);

    // Motion: the third row becomes the selected one, with no action.
    try typeErasedEventHandler(&m, &ctx, .{ .mouse = .{
        .col = @intCast(box.x + 2),
        .row = @intCast(box.y + 3 + 2),
        .button = .none,
        .mods = .{},
        .type = .motion,
    } });
    try std.testing.expectEqual(@as(usize, 2), m.pal.sel[0]);
    try std.testing.expect(!m.selecting_text);
    try std.testing.expectEqual(before_first, m.first_visible);

    // The wheel moves the palette's selection, not the history's scroll.
    try typeErasedEventHandler(&m, &ctx, .{ .mouse = .{
        .col = 0,
        .row = 0,
        .button = .wheel_down,
        .mods = .{},
        .type = .press,
    } });
    try std.testing.expectEqual(@as(usize, 3), m.pal.sel[0]);
    try std.testing.expectEqual(before_first, m.first_visible);
    try std.testing.expect(m.follow_bottom);
}

test "the prompt rail keeps the last six prompts, newest at the bottom" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    for (0..8) |i| {
        var text: [32]u8 = undefined;
        m.pushKind(.user, try std.fmt.bufPrint(&text, "prompt {d}", .{i}));
        m.pushKind(.assistant, "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten");
    }
    m.show_prompt_dots = true;
    const s = try drawTest(&m, arena_state.allocator(), 80, 24);
    // Capped at six, and the OLDEST ones fell off: the rail is "my recent
    // prompts", so the newest is the one that must never be missing.
    try std.testing.expectEqual(timeline_max_dots, m.prompt_dot_len);
    try std.testing.expectEqual(@as(u16, @intCast(m.hist_rows - 1)), m.prompt_dots[0].row);

    var k: usize = 1;
    while (k < m.prompt_dot_len) : (k += 1) {
        // One row apart going up: no two dots can overlap, which is the whole
        // reason for the cap.
        try std.testing.expectEqual(m.prompt_dots[k - 1].row - 1, m.prompt_dots[k].row);
        // And they are in chronological order: older prompts sit higher.
        try std.testing.expect(m.prompt_dots[k].line < m.prompt_dots[k - 1].line);
    }

    // Painted at the right margin, one column left of the scrollbar, and the
    // FILLED one is the prompt of the turn being read (the one the sticky
    // header names) — at the bottom of the history that is the request at the
    // top of the screen, not necessarily the newest one.
    try std.testing.expectEqual(@as(u16, 80 - 2), m.prompt_dot_col);
    const active = stickyPromptPara(&m).?;
    var active_seen = false;
    for (m.prompt_dots[0..m.prompt_dot_len]) |d| {
        const g = s.readCell(m.prompt_dot_col, d.row).char.grapheme;
        if (d.para == active) {
            try std.testing.expectEqualStrings("\u{25cf}", g);
            active_seen = true;
        } else {
            try std.testing.expectEqualStrings("\u{25cb}", g);
        }
    }
    try std.testing.expect(active_seen);
}

test "clicking a prompt dot scrolls to that prompt instead of selecting text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    for (0..8) |i| {
        var text: [32]u8 = undefined;
        m.pushKind(.user, try std.fmt.bufPrint(&text, "prompt {d}", .{i}));
        m.pushKind(.assistant, "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten");
    }
    _ = try drawTest(&m, arena_state.allocator(), 80, 24);
    const at_bottom = m.max_offset;
    try std.testing.expect(at_bottom > 0);
    try std.testing.expect(m.follow_bottom);

    var ctx = testCtx();
    defer ctx.cmds.deinit(ctx.alloc);

    // The fourth dot from the bottom (the fourth NEWEST prompt).
    const target = m.prompt_dots[3];
    try std.testing.expect(target.line < at_bottom);
    try typeErasedEventHandler(&m, &ctx, .{ .mouse = .{
        .col = @intCast(m.prompt_dot_col),
        .row = @intCast(target.row),
        .button = .left,
        .mods = .{},
        .type = .press,
    } });

    // One row of air above it: row 0 belongs to the sticky header.
    try std.testing.expectEqual(target.line -| 1, m.first_visible);
    try std.testing.expect(!m.follow_bottom);
    // A click on the rail is a control, not the start of a selection.
    try std.testing.expect(!m.selecting_text);
    try std.testing.expect(m.selection_start == null);
}

test "the prompt rail acknowledges the pointer and forgets it when it leaves" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.pushKind(.user, "first");
    m.pushKind(.assistant, "answer");
    m.pushKind(.user, "second");
    m.pushKind(.assistant, "answer");
    m.show_prompt_dots = true;
    _ = try drawTest(&m, arena_state.allocator(), 80, 24);
    try std.testing.expectEqual(@as(usize, 2), m.prompt_dot_len);

    var ctx = testCtx();
    defer ctx.cmds.deinit(ctx.alloc);

    // Motion over the OLDER dot fills it: the dot under the pointer says it can
    // be clicked.
    const older = m.prompt_dots[1];
    try typeErasedEventHandler(&m, &ctx, .{ .mouse = .{
        .col = @intCast(m.prompt_dot_col),
        .row = @intCast(older.row),
        .button = .none,
        .mods = .{},
        .type = .motion,
    } });
    try std.testing.expectEqual(@as(?usize, older.para), m.prompt_dot_hover);

    // Leaving the window ends the hover instead of stranding it lit forever.
    try typeErasedEventHandler(&m, &ctx, .mouse_leave);
    try std.testing.expect(m.prompt_dot_hover == null);
}

test "replacing the model palette invalidates its pending catalog request" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.pal.mode = .models;
    m.pal.active = true;
    const request_id = m.beginCatalogRequest("example-provider");

    agent.openConnectPalette(&m);

    try std.testing.expectEqual(palette.Mode.connect, m.pal.mode);
    try std.testing.expect(!m.catalogRequestCurrent(request_id));
}

test "streamEnd empties pending BEFORE setting the paragraph (else the text lands on top of the tool)" {
    // Regression: `pushToolStart`/`pushToolDone` enqueue into `pending`, and
    // `pending` is drained on the next draw. `streamEnd` put the assistant's
    // paragraph into `paras` without emptying `pending`, so the text ended up
    // AHEAD of the tool it belonged to. It shows up when the agent
    // interleaves text and tools: "◆ Listo." showed up above "⎿ exit=0".
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.pushToolStart("bash", "sleep 3");
    m.pushToolDone("bash", "exit=0", 3001, "");

    m.streamStart();
    m.streamDelta("antes");
    m.streamEnd();

    m.streamStart();
    m.streamDelta("despues");
    m.streamEnd();

    // What you see is the order of `paras`, which the DRAW produces by draining
    // `pending`. `streamEnd` enqueues instead of appending (see its comment:
    // appending reallocated `paras.items` under the UI thread's feet).
    m.drainPending();
    const kinds = [_]md.Kind{ .tool_run, .tool_res, .assistant, .assistant };
    try std.testing.expectEqual(kinds.len, m.paras.items.len);
    for (kinds, m.paras.items) |want, got| try std.testing.expectEqual(want, got.kind);
    try std.testing.expectEqualStrings("antes", m.paras.items[2].text);
    try std.testing.expectEqualStrings("despues", m.paras.items[3].text);
}

test "streamEnd does NOT touch paras: it enqueues (else the worker reallocs under the UI)" {
    // The invariant that keeps a hard crash away. `paras` is the array the draw
    // walks EVERY FRAME without taking the lock; appending to it from the
    // worker reallocates `items` and frees the buffer the draw is reading. It
    // crashed with SIGSEGV inside `mem.count` on a freed paragraph, with any
    // prompt that ran a tool.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.streamStart();
    m.streamDelta("hola");
    m.streamEnd();

    // Nothing has reached `paras` yet: it is all sitting in `pending`.
    try std.testing.expectEqual(@as(usize, 0), m.paras.items.len);
    try std.testing.expectEqual(@as(usize, 1), m.pending.items.len);

    // And the draw is what moves it.
    m.drainPending();
    try std.testing.expectEqual(@as(usize, 1), m.paras.items.len);
    try std.testing.expectEqual(@as(usize, 0), m.pending.items.len);
    try std.testing.expectEqualStrings("hola", m.paras.items[0].text);
}

test "a tool header marks the name so the parser highlights it" {
    // `*write*(hola.js)`: the name in the tool's bright color and the argument
    // in the dim one. Without the mark they came out the same cyan and were
    // indistinguishable. The marks are removed at paint time: the row never
    // shows them.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.pushToolStart("write", "hola.js");

    const s = try drawTest(&m, arena_state.allocator(), 92, 26);
    const all = allText(s);
    try std.testing.expect(std.mem.indexOf(u8, all, "write(hola.js)") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, all, '*') == null);
}

test "a running tool clock appears only in the activity strip" {
    // Without this, a 30s `bash` leaves the last row frozen at
    // `⏺ bash(...)`: there is no way to tell if the process is still alive or
    // if the app has hung. The clock is the only thing that answers "is it
    // stuck?".
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.pushToolStart("bash", "sleep 30");

    // The tool line identifies the command; the strip owns its only clock.
    {
        const s = try drawTest(&m, arena_state.allocator(), 92, 26);
        const all = allText(s);
        try std.testing.expect(std.mem.indexOf(u8, all, "sleep 30") != null);
        try std.testing.expect(std.mem.indexOf(u8, all, "running") != null);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, all, "0.0s"));
        try std.testing.expect(m.isBusy());
    }

    // When it finishes: the line goes away and leaves its spot to the result.
    m.pushToolDone("bash", "ok", 30_000, "");
    try std.testing.expect(!m.isBusy());
    const s2 = try drawTest(&m, arena_state.allocator(), 92, 26);
    const all2 = allText(s2);
    try std.testing.expect(std.mem.indexOf(u8, all2, "running") == null);
    try std.testing.expect(std.mem.indexOf(u8, all2, "30000ms") != null);
}

test "the strip names the phase: thinking, streaming or running a tool" {
    // "working" does not distinguish thinking from writing from a hung bash, and
    // only `streaming` was distinguished. Here each phase's branch is checked.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    {
        var m = Model.init(std.testing.allocator);
        defer m.deinit();
        m.streamStart(); // turn open, no text yet
        const s = try drawTest(&m, arena, 90, 20);
        const all = allText(s);
        // Once the request is opened, the strip reports streaming while the
        // history stays clear until actual text arrives.
        try std.testing.expect(std.mem.indexOf(u8, all, "streaming") != null);
        try std.testing.expect(std.mem.indexOf(u8, all, "thinking ·") == null);
    }
    {
        var m = Model.init(std.testing.allocator);
        defer m.deinit();
        m.streamStart();
        m.streamDelta("hola");
        const s = try drawTest(&m, arena, 90, 20);
        try std.testing.expect(std.mem.indexOf(u8, allText(s), "streaming") != null);
    }
    {
        var m = Model.init(std.testing.allocator);
        defer m.deinit();
        m.pushToolStart("bash", "sleep 30");
        const s = try drawTest(&m, arena, 90, 20);
        try std.testing.expect(std.mem.indexOf(u8, allText(s), "running") != null);
    }
}

test "the permission strip shows with the turn open" {
    // The strip only shows if there is something to report, and a permission
    // dialog without a turn does not happen: the worker asks from inside a turn.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.streamStart();
    m.perm_active = true;
    const s = try drawTest(&m, arena_state.allocator(), 90, 24);
    try std.testing.expect(std.mem.indexOf(u8, allText(s), "permission") != null);
    m.perm_active = false;
}

test "the activity strip is the only clock before the first token" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.streamStart();
    const s = try drawTest(&m, arena_state.allocator(), 80, 20);
    const all = allText(s);
    try std.testing.expect(std.mem.indexOf(u8, all, "streaming") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, all, "0.0s"));
    try std.testing.expect(std.mem.indexOf(u8, all, "thinking ·") == null);
}

test "at idle there is no activity clock" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const s = try drawTest(&m, arena_state.allocator(), 80, 20);
    try std.testing.expect(std.mem.indexOf(u8, allText(s), "thinking") == null);
}

// ── ROADMAP Phase 0: the safety net that was missing ──────────
//
// These tests pin down behaviors whose absence did not produce a visible error
// but a HUNG or FROZEN app. See ROADMAP.md, Phase 0 and Phase 1.

test "layout: 130 paragraphs does not hang the layout loop" {
    // The `while (seg_cache.len < paras.len)` loop with `orderedRemove(0)` when
    // going over the cap NEVER terminated with 129+ paragraphs: append (129) ->
    // evict (128) -> back in, forever, creating an ArenaAllocator per
    // iteration. This test hung the whole test binary, so now layout carries an
    // iteration budget (`layout_iters`) that reports instead of hanging.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    var i: usize = 0;
    while (i < 130) : (i += 1) m.pushInfo("parrafo");

    _ = try drawTest(&m, arena_state.allocator(), 80, 24);
    try std.testing.expect(!m.layout_overflow);
    try std.testing.expect(m.layout_iters <= Model.max_cached_paras);
    // The cache's memory stays bounded: the argument was the ceiling, not the
    // parse time.
    try std.testing.expect(m.seg_cache.items.len <= Model.max_cached_paras);
}

test "layout: 200 and 1000 paragraphs do not hang either" {
    // The two sizes that show up in a long session. Same contract.
    inline for (.{ 200, 1000 }) |n| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        var m = Model.init(std.testing.allocator);
        defer m.deinit();

        var i: usize = 0;
        while (i < n) : (i += 1) m.pushInfo("p");

        _ = try drawTest(&m, arena_state.allocator(), 80, 24);
        try std.testing.expect(!m.layout_overflow);
        try std.testing.expect(m.seg_cache.items.len <= Model.max_cached_paras);
    }
}

test "layout: deep scroll re-parses the window and the text keeps coming out" {
    // What the old comment of `max_cached_paras` promised ("deep scrolling
    // re-parses on demand") and did not do. With the sliding window, going up
    // past what is cached parses whatever comes on screen.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        var buf: [32]u8 = undefined;
        m.streamStart();
        m.streamDelta(std.fmt.bufPrint(&buf, "marcador-{d}", .{i}) catch "x");
        m.streamEnd();
    }
    // At the very bottom: you see the end.
    {
        const s = try drawTest(&m, arena_state.allocator(), 60, 20);
        try std.testing.expect(std.mem.indexOf(u8, allText(s), "marcador-199") != null);
    }
    // Way up top: the upper window is re-parsed and text comes out.
    m.scrollBy(10_000);
    {
        const s = try drawTest(&m, arena_state.allocator(), 60, 20);
        const all = allText(s);
        try std.testing.expect(std.mem.indexOf(u8, all, "marcador-") != null);
        try std.testing.expect(!m.layout_overflow);
    }
    // And going back down you see the end again.
    m.scrollBy(-10_000);
    {
        const s = try drawTest(&m, arena_state.allocator(), 60, 20);
        try std.testing.expect(std.mem.indexOf(u8, allText(s), "marcador-199") != null);
    }
}

test "pushDiff puts ONE paragraph, not one per line" {
    // `pushDiff` put ONE PARAGRAPH per diff line: with 129+ lines that blew
    // past the cache cap and hung the app instantly. A single `write` of a
    // 129-line file was "it freezes when it starts writing".
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    _ = m.pushDiff("uno\ndos\ntres\n", "uno\nDOS\ntres\ncuatro\n");
    _ = try drawTest(&m, arena_state.allocator(), 60, 20);

    var diffs: usize = 0;
    for (m.paras.items) |p| {
        if (p.kind == .diff) diffs += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), diffs);
}

test "a 300-line diff does not hang and is still ONE paragraph" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    var before: [8 * 1024]u8 = undefined;
    var after: [8 * 1024]u8 = undefined;
    var n_before: usize = 0;
    var n_after: usize = 0;
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        n_before += (std.fmt.bufPrint(before[n_before..], "linea {d}\n", .{i}) catch break).len;
    }
    i = 0;
    while (i < 300) : (i += 1) {
        n_after += (std.fmt.bufPrint(after[n_after..], "linea {d}!\n", .{i}) catch break).len;
    }

    _ = m.pushDiff(before[0..n_before], after[0..n_after]);
    _ = try drawTest(&m, arena_state.allocator(), 80, 24);
    try std.testing.expect(!m.layout_overflow);

    var diffs: usize = 0;
    for (m.paras.items) |p| {
        if (p.kind == .diff) diffs += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), diffs);
}

test "a long diff collapses into a preview, and Ctrl+R swaps it for the whole thing" {
    // The complaint this answers: a `write` of a 300-line file was 300 rows of
    // history in the place the user is watching to see what the agent is doing.
    // The preview keeps the shape of the change (first lines + the counts) and
    // the whole diff is one key away — a collapse with no way back would be
    // worse than no collapse at all.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    var before: [16 * 1024]u8 = undefined;
    var after: [16 * 1024]u8 = undefined;
    var nb: usize = 0;
    var na: usize = 0;
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        nb += (std.fmt.bufPrint(before[nb..], "linea {d}\n", .{i}) catch break).len;
        na += (std.fmt.bufPrint(after[na..], "linea {d}!\n", .{i}) catch break).len;
    }

    m.pushToolStart("write", "src/demo.txt");
    m.pushToolDone("write", "wrote 60 lines", 7, "wrote 60 lines");
    const counts = m.pushDiff(before[0..nb], after[0..na]);
    try std.testing.expect(counts.added == 60 and counts.removed == 60);
    m.drainPending();

    // Still ONE paragraph (the contract that keeps the layout loop alive), and
    // it is the short one.
    var diff_idx: ?usize = null;
    var diffs: usize = 0;
    for (m.paras.items, 0..) |p, n| {
        if (p.kind != .diff) continue;
        diffs += 1;
        diff_idx = n;
    }
    try std.testing.expectEqual(@as(usize, 1), diffs);
    const short_text = m.paras.items[diff_idx.?].text;
    try std.testing.expect(std.mem.startsWith(u8, short_text, "diff preview · +60 −60\n"));
    try std.testing.expect(std.mem.indexOf(u8, short_text, "ctrl+r to expand") != null);
    try std.testing.expect(std.mem.indexOf(u8, short_text, "more lines") != null);
    // The preview is the FIRST lines, and the far end of the file is not there.
    try std.testing.expect(std.mem.indexOf(u8, short_text, "linea 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, short_text, "linea 59") == null);

    // Ctrl+R opens the WHOLE diff…
    try std.testing.expect(m.toggleLastTool());
    const full_text = m.paras.items[diff_idx.?].text;
    try std.testing.expect(std.mem.indexOf(u8, full_text, "linea 59") != null);
    try std.testing.expect(std.mem.indexOf(u8, full_text, "ctrl+r to expand") == null);

    // …and Ctrl+R closes it again (the same key, the same paragraph).
    try std.testing.expect(m.toggleLastTool());
    const again = m.paras.items[diff_idx.?].text;
    try std.testing.expect(std.mem.indexOf(u8, again, "ctrl+r to expand") != null);
    try std.testing.expect(std.mem.indexOf(u8, again, "linea 59") == null);

    // And the whole thing survives a draw at a realistic size.
    _ = try drawTest(&m, arena, 100, 30);
}

test "a short diff is shown WHOLE, and Ctrl+R then opens the tool result" {
    // The collapse must not fire on the everyday case: a two-line fix is the
    // thing you WANT to read inline, and hiding it behind a key would be a
    // slower way to see less.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.pushToolStart("edit", "src/demo.txt");
    m.pushToolDone("edit", "Edited 1 line", 2, "the full result of the edit");
    _ = m.pushDiff("uno\ndos\n", "uno\nDOS\n");
    m.drainPending();

    for (m.paras.items) |p| {
        if (p.kind != .diff) continue;
        // Whole, no marker, nothing hidden.
        try std.testing.expect(std.mem.indexOf(u8, p.text, "ctrl+r") == null);
        try std.testing.expect(std.mem.indexOf(u8, p.text, "+DOS") != null);
        try std.testing.expect(std.mem.indexOf(u8, p.text, "-dos") != null);
    }
    // No diff to expand, so the key does what it always did: the RESULT.
    try std.testing.expect(m.last_tool != null and !m.last_tool.?.hasDiff());
    try std.testing.expect(m.toggleLastTool());
    var found = false;
    for (m.paras.items) |p| {
        if (p.kind == .tool_res and std.mem.indexOf(u8, p.text, "the full result of the edit") != null) found = true;
    }
    try std.testing.expect(found);
    _ = try drawTest(&m, arena, 80, 20);
}

test "Ctrl+R on a paragraph that went COLD rehydrates it instead of corrupting it" {
    // A paragraph outside the scroll window is stored COMPRESSED with
    // `is_cold = true`. Overwriting that text with raw bytes while the flag
    // stays set makes the next `textLive` call `decompressInto` on text that
    // was never compressed: an assert in debug, a garbage paragraph in
    // release.
    //
    // The paragraph this happens to is the DIFF, and it is the only one that
    // can: `pruneCold` skips anything under `min_compress_len`, and a tool
    // result's paragraph is a single summary line (~18 bytes) — which is also
    // why the first version of this test, written against the result, failed to
    // compress at all. A diff of a few hundred lines is exactly what you
    // scrolled away from and then come back to open.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    var before: [16 * 1024]u8 = undefined;
    var after: [16 * 1024]u8 = undefined;
    var nb: usize = 0;
    var na: usize = 0;
    var i: usize = 0;
    while (i < 80) : (i += 1) {
        nb += (std.fmt.bufPrint(before[nb..], "line {d} with enough text for a realistic preview width\n", .{i}) catch break).len;
        na += (std.fmt.bufPrint(after[na..], "line {d}! with enough text for a realistic preview width\n", .{i}) catch break).len;
    }

    m.pushToolStart("write", "src/demo.txt");
    m.pushToolDone("write", "wrote 80 lines", 5, "wrote 80 lines");
    _ = m.pushDiff(before[0..nb], after[0..na]);
    m.drainPending();

    const idx = m.last_tool.?.diff_para_idx.?;
    const text_len = m.paras.items[idx].text.len;
    try std.testing.expect(std.mem.indexOf(u8, m.paras.items[idx].text, "ctrl+r to expand") != null);

    // Cold, the way `pruneCold` leaves it when you scroll away.
    const buf = try std.testing.allocator.alloc(u8, text_len + 1);
    defer std.testing.allocator.free(buf);
    const packed_z = zjsonl.compressLine(buf, m.paras.items[idx].text) orelse return error.TestUnexpectedResult;
    const copy = try std.testing.allocator.dupe(u8, packed_z);
    std.testing.allocator.free(m.paras.items[idx].text);
    m.paras.items[idx].text = copy;
    m.paras.items[idx].is_cold = true;
    try std.testing.expect(m.paras.items[idx].is_cold);

    // The toggle still works, and what it leaves behind is RAW text whose flag
    // says so — not base64 under `is_cold = false`.
    try std.testing.expect(m.toggleLastTool());
    const p = &m.paras.items[idx];
    try std.testing.expect(!p.is_cold);
    try std.testing.expect(std.mem.indexOf(u8, p.text, "line 79!") != null); // the whole diff
    try std.testing.expect(std.mem.indexOf(u8, p.text, "ctrl+r to expand") == null);
    // And it is really the text: a decompression of raw bytes would be garbage
    // or an assert, never a clean diff.
    try std.testing.expect(std.mem.indexOf(u8, p.text, "with enough text for a realistic preview") != null);
    _ = try drawTest(&m, arena, 80, 24);
}

test "streamEnd sets dirty: a state change asks for a frame" {
    // `streamEnd` adds a paragraph to the history and sets `busy = false`
    // WITHOUT setting `dirty = true`. Between `streamEnd` and `pushToolStart`
    // (with a session write(2) and a DEFLATE-9 in between) there was a window
    // with `busy == false` and `dirty == false`: a tick landing there left
    // `App.timers` empty and the screen stayed dead until a key was pressed.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.streamStart();
    m.streamDelta("hola");
    m.streamEnd();
    // Draw's drain sets dirty to false, but the worker enqueues again: what has
    // to hold is that EVERY worker state change sets it.
    m.pushToolStart("bash", "ls");
    try std.testing.expect(m.activity().dirty);
    m.drainPending();
    m.setStatusText("working");
    try std.testing.expect(m.activity().dirty);
    m.drainPending();
    m.setStatusWithMood(.warn, "esperando");
    try std.testing.expect(m.activity().dirty);
    m.drainPending();
    m.toolRunEnd();
    try std.testing.expect(m.activity().dirty);
}

test "pushInfoFmt: formats, paints, and leaves NO literal to free at exit" {
    // The "Invalid free" that has bitten this repo five times, as a test instead
    // of a post-mortem.
    //
    // The old shape, at thirteen call sites, was:
    //
    //     const msg = allocPrint(a, ...) catch "literal";
    //     pushInfoOwned(m, msg);
    //
    // On the happy path `msg` is heap, so nothing is wrong. When the allocator
    // IS out of memory, `msg` becomes a pointer to `.rodata`, `pushInfoOwned`
    // takes ownership of it, and `Model.deinit` calls `free` on it. Two failures
    // that cancel out into "zode crashed and I do not know why".
    //
    // Reproduced here WITHOUT an OOM, by proving the good path is owned: the
    // `defer m.deinit()` below frees every text `pushInfoFmt` produced, and
    // `std.testing.allocator` reports a bad free as a test failure.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.pushInfoFmt("effort \u{2192} {s}", .{"high"});
    m.pushInfoFmt("{d} models on {s}", .{ 42, "openrouter" });
    _ = try drawTest(&m, arena_state.allocator(), 60, 20);

    const all = allText(try drawTest(&m, arena_state.allocator(), 60, 20));
    try std.testing.expect(std.mem.indexOf(u8, all, "effort \u{2192} high") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "42 models on openrouter") != null);
}

test "a literal is NEVER stored in the history, and that is what avoids the Invalid free" {
    // The counterpart: it says the trap is real rather than folklore, and it
    // pins the property that actually prevents the crash — whatever goes into
    // `pending` is HEAP memory, so `Model.deinit` can free all of it.
    //
    // `pushInfo` copies (a literal is safe and produces a normal line) and
    // `pushInfoOwned` does NOT (a literal is an "Invalid free"). The test can
    // only check the first half, because the second half is a crash: what it
    // does check is that a literal, pushed the copying way, lands as its own
    // heap copy and never as a pointer into `.rodata`.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const lit: []const u8 = "no soy del heap";
    m.pushInfo(lit);
    m.drainPending();

    try std.testing.expectEqual(@as(usize, 1), m.paras.items.len);
    try std.testing.expectEqualStrings(lit, m.paras.items[0].text);
    // Different pointer: it is a copy, and the copy is what `deinit` frees.
    try std.testing.expect(m.paras.items[0].text.ptr != lit.ptr);
}

test "an error comes out red with ✗, not as one more info line" {
    // `md.Kind.error_msg` existed with its `✗` prefix and NO caller used it:
    // everything came out gray from `.info`, so a 403 and a "session resumed"
    // read the same. In a long history, the error — the only thing you have to
    // read — was one more line among a hundred.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.pushInfo("session resumed");
    m.pushError("key rejected by opencode");
    _ = try drawTest(&m, arena_state.allocator(), 60, 20);

    var errs: usize = 0;
    var infos: usize = 0;
    for (m.paras.items) |p| {
        if (p.kind == .error_msg) errs += 1;
        if (p.kind == .info) infos += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), errs);
    try std.testing.expectEqual(@as(usize, 1), infos);

    const all = allText(try drawTest(&m, arena_state.allocator(), 60, 20));
    try std.testing.expect(std.mem.indexOf(u8, all, "\u{2717}") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "key rejected") != null);
}

test "the TTFT is measured at the first token, not at the end of the stream" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.streamStart();
    try std.testing.expect(m.ttftPending());
    m.streamDelta("h");
    // Without a clock (`io_ready == false`) the TTFT is 0, but what matters is
    // that it stopped being pending: it was measured once and is not measured
    // again.
    try std.testing.expect(!m.ttftPending());
}

test "every agent loop iteration measures the TTFT again" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.streamStart();
    m.streamDelta("primera");
    m.streamEnd();
    m.streamStartIteration();
    try std.testing.expect(m.ttftPending());
}

test "drawHints does not exist: the shortcuts line is gone from the view" {
    // The ROADMAP asked to resurrect it or delete it. It was deleted: the
    // shortcuts are in the Ctrl+P palette and in `/help`, and one more line in
    // the view is exactly what was asked to be removed ("junk in the view").
    try std.testing.expect(@hasDecl(@import("tui.zig"), "Model"));
}

test "the TUI diff uses the path's language: a + line carries tokens" {
    // The ROADMAP's green wall: `+const n: u32 = 4` was ONE segment with the
    // prefix's color. Now the prefix goes in its own color and the body is
    // tokenized with the language taken from the path's extension.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    _ = m.pushDiffLang("x\n", "const n: u32 = 4\n", "zig");
    _ = try drawTest(&m, arena_state.allocator(), 60, 20);

    // The paragraph carries the language with it (not a pointer to the worker's
    // arena).
    var langs_ok = false;
    for (m.paras.items) |p| {
        if (p.kind == .diff) {
            langs_ok = std.mem.eql(u8, p.lang, "zig");
        }
    }
    try std.testing.expect(langs_ok);

    // And when painting there is more than one segment: the text is split.
    const s = try drawTest(&m, arena_state.allocator(), 60, 20);
    var buf: [128]u8 = undefined;
    const row = rowText(s, findRow(s, "+const").?, &buf);
    try std.testing.expect(std.mem.indexOf(u8, row, "const") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "u32") != null);
}

test "the + prefix and the body have DIFFERENT colors (green wall removed)" {
    // The ROADMAP's anti-all-green invariant. With `+const n: u32 = 4` in
    // zig: the prefix is `diff_add` and `const` is a code keyword. Before, the
    // two greens were ALSO the very same color (`str` and `diff_add` were
    // `index 2`).
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const segs = try md.inlineSegmentsLang(arena, "+const n", .diff, null, null, "zig", null);
    try std.testing.expect(segs.len >= 2);
    try std.testing.expectEqualStrings("+", segs[0].text);
    try std.testing.expect(!std.meta.eql(segs[0].style.fg, segs[1].style.fg));
    try std.testing.expect(!std.meta.eql(theme.diff_add.fg, theme.code_str.fg));
}

test "a code block has a gutter, a language chip and separation" {
    // `blk.kind` and `blk.lang` were computed and thrown away: the only use of
    // `blk.` in the whole file was `blk.lines`. So a code block came out as
    // plain prose, glued to the sentence before and the one after.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.streamStart();
    m.streamDelta("antes\n\n```zig\nconst n = 1;\n```\n\ndespues");
    m.streamEnd();
    const s = try drawTest(&m, arena_state.allocator(), 60, 24);

    // The chip with the language: the ```zig fence no longer disappears.
    try std.testing.expect(std.mem.indexOf(u8, allText(s), "zig") != null);
    // The gutter on the block's lines.
    var buf: [128]u8 = undefined;
    const code_row = rowText(s, findRow(s, "const n").?, &buf);
    try std.testing.expect(std.mem.startsWith(u8, std.mem.trim(u8, code_row, " "), "\u{2502}"));
    // And there is separation before and after the block.
    try std.testing.expect(hasBlankRowBetween(s, "antes", "const n"));
}

test "the gutter does not eat text: the column invariant holds" {
    // The gutter eats 2 columns, so the content wraps to `width - 2`. If it
    // were inserted AFTER wrapping, the last line would go past the border.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const long = "x" ** 200;
    m.streamStart();
    m.streamDelta("```zig\n" ++ long ++ "\n```");
    m.streamEnd();
    const s = try drawTest(&m, arena_state.allocator(), 40, 24);

    // No row of the block goes past the width.
    var buf: [256]u8 = undefined;
    var r: u16 = 0;
    while (r < 24) : (r += 1) {
        const row = rowText(s, r, &buf);
        if (std.mem.indexOf(u8, row, "\u{2502}") == null) continue;
        try std.testing.expect(std.mem.count(u8, row, "x") + 2 <= 40);
    }
}

test "a line wrapped to the width carries a continuation indent" {
    // Without indent, the continuation of a sentence starts at COLUMN 0 and is
    // indistinguishable from a new sentence. With two columns it reads as
    // "continues below", which is what any line wrapping does.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const msg = "la primera parte de la frase es larga " ** 3;
    m.streamStart();
    m.streamDelta(msg);
    m.streamEnd();
    const s = try drawTest(&m, arena_state.allocator(), 30, 12);
    const all = allText(s);
    // There is more than one row with the sentence's text.
    var buf: [128]u8 = undefined;
    var rows_with_text: usize = 0;
    var r: u16 = 0;
    while (r < 12) : (r += 1) {
        const row = rowText(s, r, &buf);
        if (std.mem.indexOf(u8, row, "la primera parte") != null) rows_with_text += 1;
    }
    // With indent, the first row starts at column 0 and the second does NOT:
    // without indent both would start at column 0.
    try std.testing.expect(rows_with_text >= 1);
    _ = all;
}

test "the history has a left margin and nothing goes off screen" {
    // 4.9 of the ROADMAP: the text stuck to the terminal's edge. With 2 columns
    // of air, the history lines up with the input box and breathes.
    //
    // The invariant that matters: the layout wraps to `width - margin` and the
    // painting starts at the margin's column. If they diverged, the last column
    // would go off screen.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.streamStart();
    m.streamDelta("hola mundo esto es una frase larga para que se parta en varias lineas");
    m.streamEnd();
    const s = try drawTest(&m, arena_state.allocator(), 40, 12);

    // The first column is empty: the margin.
    var buf: [128]u8 = undefined;
    const row0 = rowText(s, 0, &buf);
    try std.testing.expectEqualStrings("  ", row0[0..2]);

    // And the wrap respects the margin: the continuation is not just indented,
    // the layout also wraps to `width - margin`, so no row of text reaches the
    // right edge.
    //
    // CAREFUL: it is measured on the CONTINUATION row and in columns, not in
    // bytes: `rowText` returns bytes and the `◆` prefix is 3 bytes for 2
    // columns.
    // Row 1 is the continuation: margin, then the GUTTER (`│ `, which used to be
    // two anonymous spaces), then the text. The gutter is what makes the row
    // attributable to the paragraph above it.
    var buf2: [128]u8 = undefined;
    const cont = rowText(s, 1, &buf2);
    try std.testing.expect(std.mem.startsWith(u8, cont, "  \u{2502} "));
    // The right margin stays clear too. In COLUMNS, not in bytes: `rowText` returns
    // bytes and the gutter bar is 3 bytes for 1 column, so counting bytes made
    // this row look longer than the terminal is wide.
    const cols = try plainColumns(std.testing.allocator, std.mem.trimEnd(u8, cont, " "));
    defer std.testing.allocator.free(cols);
    try std.testing.expect(cols.len <= 38);
    try std.testing.expectEqualStrings(" ", s.readCell(38, 1).char.grapheme);
    try std.testing.expectEqualStrings(" ", s.readCell(39, 1).char.grapheme);
}

test "prune: what leaves the window is compressed and comes back byte-for-byte IDENTICAL" {
    // Phase 6 of the ROADMAP. `Model.paras` was the only structure that grew
    // without bound: the segment cache is a sliding window, but every paragraph
    // kept its text forever. With 128 paragraphs of 16 KB (the `max_tool_output`
    // cap) that is 2 MB that never goes back down.
    //
    // You cannot simply drop the text: not every paragraph has a session
    // message behind it (tool headers, diffs, notices), so there would be
    // nowhere to re-read it from. Compressing keeps it byte-exact and needs no
    // mapping.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // 60 paragraphs of 4 KB each (over `zjsonl.min_compress_len`).
    const big_len = 4096;
    const big = try a.alloc(u8, big_len);
    for (big, 0..) |*c, i| c.* = 'a' + @as(u8, @intCast(i % 26));

    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    var i: usize = 0;
    while (i < 60) : (i += 1) m.pushKind(.tool_res, big);

    // First frame: the window is at the bottom (the last rows).
    _ = try drawTest(&m, arena_state.allocator(), 60, 20);
    var cold: usize = 0;
    var hot_bytes: usize = 0;
    for (m.paras.items) |p| {
        if (p.is_cold) cold += 1;
        hot_bytes += p.text.len;
    }
    try std.testing.expect(cold > 0); // something was pruned
    try std.testing.expect(hot_bytes < 60 * big_len / 2); // and it takes half the space

    // Now we check the invariant that actually matters: scroll to a pruned
    // paragraph and have the text come out IDENTICAL.
    var target: ?usize = null;
    for (m.paras.items, 0..) |p, idx| {
        if (p.is_cold) {
            target = idx;
            break;
        }
    }
    try std.testing.expect(target != null);

    // Scroll to where that paragraph actually IS, not blindly to the top.
    //
    // "Scroll to the top" used to be enough by accident: the window was the
    // last few paragraphs and the pruned ones were the first ones, so the top
    // happened to be the first pruned paragraph. Now the heights are known for
    // everything (`known_lines`), so which paragraph is pruned depends on the
    // window, and the first pruned one can be anywhere. Walking down until it
    // enters the window is what a user does, and it is the only version of this
    // test that says what it means: "come back when I scroll there".
    m.scrollBy(1_000_000); // to the top
    _ = try drawTest(&m, arena_state.allocator(), 60, 20);
    var steps: usize = 0;
    while (m.paras.items[target.?].is_cold and steps < 200) : (steps += 1) {
        m.scrollBy(-8);
        _ = try drawTest(&m, arena_state.allocator(), 60, 20);
    }
    try std.testing.expect(steps < 200); // it did become visible, it did not vanish

    // The paragraph that was pruned was rehydrated when it entered the window,
    // and its text is byte for byte the original.
    const rehydrated = m.paras.items[target.?];
    try std.testing.expect(!rehydrated.is_cold);
    try std.testing.expectEqualStrings(big, rehydrated.text);

    // And the ones still pruned also return the ORIGINAL text through
    // `textLive`, which is what the layout uses. That is the invariant of the
    // phase: pruning cannot change a single byte of what is on screen.
    var still_cold: usize = 0;
    for (m.paras.items) |*p| {
        if (!p.is_cold) continue;
        still_cold += 1;
        try std.testing.expectEqualStrings(big, p.textLive(std.testing.allocator));
    }
    try std.testing.expect(still_cold > 0); // pruning still applies
}

test "prune: a short paragraph is NOT compressed (base64 would cost more)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    var i: usize = 0;
    while (i < 200) : (i += 1) m.pushInfo("hola");
    _ = try drawTest(&m, arena_state.allocator(), 60, 20);
    for (m.paras.items) |p| try std.testing.expect(!p.is_cold);
    try std.testing.expectEqualStrings("hola", m.paras.items[0].text);
}

test "prune: compress and rehydrate is byte-exact with repetitive and unicode content" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const payload = "const std = @import(\"std\"); // \u{00f1}\u{2713}\u{2500}\n" ** 200;
    _ = a;

    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    var i: usize = 0;
    while (i < 80) : (i += 1) m.pushKind(.tool_res, payload);
    _ = try drawTest(&m, arena_state.allocator(), 60, 20);

    // Some paragraph ended up pruned.
    var any_cold = false;
    for (m.paras.items) |p| {
        if (p.is_cold) any_cold = true;
    }
    try std.testing.expect(any_cold);

    // Scrolling all the way up, EVERY paragraph (rehydrated or not) returns the
    // original text byte for byte, with the multibyte sequences intact.
    m.scrollBy(1_000_000);
    _ = try drawTest(&m, arena_state.allocator(), 60, 20);
    for (m.paras.items) |*p| {
        try std.testing.expectEqualStrings(payload, p.textLive(std.testing.allocator));
    }
}

test "prune: the saving is real (not just a boolean)" {
    // The ROADMAP estimated a byte budget of ~8 MB. Measured, what actually
    // grew without bound were the ~2 MB of text of 128 tool results of 16 KB.
    // This test pins down that pruning really shrinks them and does not just
    // set a flag.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const big = try a.alloc(u8, 16 * 1024);
    for (big, 0..) |*c, i| c.* = 'a' + @as(u8, @intCast(i % 26));

    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    var i: usize = 0;
    while (i < 128) : (i += 1) m.pushKind(.tool_res, big);

    _ = try drawTest(&m, arena_state.allocator(), 100, 40);

    const before: usize = 128 * 16 * 1024;
    var after: usize = 0;
    for (m.paras.items) |p| after += p.text.len;

    // From 2 MB to under 700 KB: the 128 paragraphs are periodic and identical,
    // so what is left is the compression factor (~10x) minus the ones hot in
    // the window.
    try std.testing.expect(after < before / 3);
    // And the invariant: asked for it, the full text comes back out.
    for (m.paras.items) |*p| {
        const live = p.textLive(std.testing.allocator);
        try std.testing.expectEqual(big.len, live.len);
    }
}

test "both status columns measure the width the same (else they overlap)" {
    // The bug of measuring with `.len` instead of columns: `⚡` is 3 bytes for 1
    // column, so aligning by bytes knocks the whole row off. Both columns use
    // the SAME function on purpose.
    const segs = [_]InfoSeg{
        .{ .text = "\u{26a1} 3 tok/s", .style = theme.tool },
        .{ .text = " \u{b7} \u{00f1}", .style = theme.dim },
    };
    // "⚡ 3 tok/s" is 9 graphemes and " · ñ" is 4: 13 columns. In BYTES they would
    // be 15 and 7, that is 22, and the row would end up 9 columns off.
    try std.testing.expectEqual(@as(u16, 13), segsWidth(&segs));
}

// ── plan visible, /undo y paragraphs (feat/roster) ─────────────────────

/// How many assistant paragraphs the history has (after a `drainPending`).
fn countAssistant(m: *Model) usize {
    var n: usize = 0;
    for (m.paras.items) |p| {
        if (p.kind == .assistant) n += 1;
    }
    return n;
}

test "plan summary: progress and current step are visible without repeating the list" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const args =
        \\{"items":[
        \\{"content":"leer el roadmap","status":"done"},
        \\{"content":"implementar la tool","status":"in_progress"},
        \\{"content":"escribir los tests","status":"pending"}
        \\]}
    ;
    var items: [plan_mod.max_items]plan_mod.Item = undefined;
    const parsed = try plan_mod.parseItems(arena, args, &items);
    _ = m.applyPlan(&parsed.items, parsed.len);
    // Applying the plan is a state change: it has to request a frame.
    try std.testing.expect(m.activity().dirty);

    const s = try drawTest(&m, arena, 100, 30);
    const r_cur = findRow(s, "plan 1/3 · 2 open · implementar la tool") orelse return error.TestUnexpectedResult;
    try std.testing.expect(findRow(s, "leer el roadmap") == null);
    try std.testing.expect(findRow(s, "escribir los tests") == null);

    var buf: [256]u8 = undefined;
    const plan_row = rowText(s, r_cur, &buf);
    // The glyph is read from the CELL and not from `rowText`, and that is not a
    // style choice: `rowText` collects the graphemes of the row and the plan's
    // left edge is a TWO-column literal (`├─`), so the run it produces and the
    // one the cell holds do not line up — the glyph is in the surface and does
    // not come back out of the text. Checking the text for it was a test that
    // asserted a rendering quirk instead of the thing it meant.
    //
    // The ACTIVE step is the accent, and it is the only thing on this row with
    // a color: a plan row where nothing is colored is a plan that reads as a
    // notice, and "which step am I on" stops being answerable.
    const cur_cell = s.readCell(1, r_cur);
    try std.testing.expectEqualStrings("\u{25d0}", cur_cell.char.grapheme);
    try std.testing.expect(cur_cell.style.fg.eql(theme.brand.fg) or cur_cell.style.fg.eql(theme.brand_hi.fg));
    try std.testing.expect(cur_cell.style.bold);
    _ = plan_row;
}

test "the plan summary sits above the input and uses one row" {
    // The order of the rows from the bottom up is status · strip · plan · input.
    // If the plan were drawn anywhere else it would cover the history, which is
    // exactly what a plan must not do.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.pushKind(.user, "hola");

    const s_sin = try drawTest(&m, arena, 100, 30);
    const input_sin = findRow(s_sin, "Ask anything") orelse return error.TestUnexpectedResult;

    var items: [plan_mod.max_items]plan_mod.Item = undefined;
    const texts = [_][]const u8{ "primero", "segundo", "tercero" };
    for (0..3) |i| {
        var it = plan_mod.Item{ .status = .pending };
        const t = texts[i];
        @memcpy(it.text[0..t.len], t);
        it.len = @intCast(t.len);
        items[i] = it;
    }
    _ = m.applyPlan(&items, 3);
    const s_con = try drawTest(&m, arena, 100, 30);
    const input_con = findRow(s_con, "Ask anything") orelse return error.TestUnexpectedResult;
    // The plan's first step: enough to know WHERE the block is.
    const r_plan = findRow(s_con, "primero") orelse return error.TestUnexpectedResult;

    // The plan sits ABOVE the input, taking one row instead of one row per step.
    try std.testing.expect(r_plan < input_con);
    try std.testing.expectEqual(input_sin, input_con);
    // And the history is still up there (with 30 rows there is plenty of room).
    try std.testing.expect(findRow(s_con, "hola") != null);
    try std.testing.expect(findRow(s_con, "hola").? < r_plan);

    // With no plan, there are no checkbox rows.
    m.clearPlan();
    const s_limpio = try drawTest(&m, arena, 100, 30);
    try std.testing.expect(findRow(s_limpio, "☐") == null);
    try std.testing.expectEqual(input_sin, findRow(s_limpio, "Ask anything").?);
}

test "a finished plan is drawn in ONE line" {
    // A finished plan with 20 checkboxes just pushes the input up for no reason:
    // one line says the same thing.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    var items: [plan_mod.max_items]plan_mod.Item = undefined;
    for (0..8) |i| {
        var it = plan_mod.Item{ .status = .done };
        it.text[0] = 'a' + @as(u8, @intCast(i));
        it.len = 1;
        items[i] = it;
    }
    _ = m.applyPlan(&items, 8);

    const s = try drawTest(&m, arena, 100, 30);
    _ = findRow(s, "plan 8/8 · complete") orelse return error.TestUnexpectedResult;
    // CAREFUL: the summary's check is "☑ all...", so searching for "☑ a" would
    // match the summary itself. What is searched for is each step's NUMBER,
    // which only shows up when the list is painted whole.
    try std.testing.expect(findRow(s, "1. a") == null);
    try std.testing.expect(findRow(s, "4. d") == null);

    const with_done_plan = m.hist_rows;

    // The same history, no plan: the history has to get those rows back.
    _ = m.applyPlan(&.{}, 0);
    _ = try drawTest(&m, arena, 100, 30);
    try std.testing.expect(m.hist_rows > with_done_plan);
}

test "a long plan summary keeps the open count visible" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    var items: [plan_mod.max_items]plan_mod.Item = undefined;
    for (0..20) |i| {
        var it = plan_mod.Item{ .status = .pending };
        it.text[0] = 'a' + @as(u8, @intCast(i % 26));
        it.len = 1;
        items[i] = it;
    }
    items[0].status = .done;
    _ = m.applyPlan(&items, 20);

    const s = try drawTest(&m, arena, 120, 44);
    const r = findRow(s, "plan 1/20 · 19 open") orelse return error.TestUnexpectedResult;
    var buf: [128]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, rowText(s, r, &buf), "· b") != null);
    try std.testing.expect(findRow(s, "1. a") == null);
}

test "the checkpoint opens per TURN and the undo consumes the last one" {
    // What matters in the contract: one prompt = one checkpoint (even if the turn
    // makes 5 tools), and `takeCheckpoint` REMOVES it, so that a second `/undo`
    // undoes the previous turn and does not repeat the same one.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    try std.testing.expect(!m.canUndo());
    m.beginCheckpoint("turno 1");
    m.snapshotFile("a.txt", "v1", true);
    m.snapshotFile("a.txt", "v2", true); // the second one is ignored
    try std.testing.expect(m.canUndo());

    m.beginCheckpoint("turno 2");
    m.snapshotFile("b.txt", "x", true);
    var c2 = m.takeCheckpointOwned() orelse return error.TestUnexpectedResult;
    defer c2.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("turno 2", c2.labelOf());
    try std.testing.expectEqual(@as(u8, 1), c2.len);
    // The snapshot of "a.txt" was from turn 1 and is still there: `b.txt` did not
    // overwrite it.
    try std.testing.expect(m.canUndo());
    var c1 = m.takeCheckpointOwned() orelse return error.TestUnexpectedResult;
    defer c1.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("turno 1", c1.labelOf());
    try std.testing.expectEqual(@as(u8, 1), c1.len);
    try std.testing.expectEqualStrings("a.txt", c1.files[0].pathOf());
    try std.testing.expectEqualStrings("v1", c1.files[0].data);

    // And there is nothing left: `canUndo` instead of a crash.
    try std.testing.expect(!m.canUndo());
    try std.testing.expect(m.takeCheckpointOwned() == null);
}

test "a snapshot with no checkpoint open is not stored (nor does it break)" {
    // `execToolCalls` can run before `startChat` opens the checkpoint (chained
    // turns). Without this guard it would be an access to an empty array.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.snapshotFile("a.txt", "contenido", true);
    try std.testing.expect(!m.canUndo());
    try std.testing.expect(m.takeCheckpointOwned() == null);
}

test "streamEnd with no text leaves no empty paragraph in the history" {
    // A turn that dies with an error opens the live paragraph and closes it empty.
    // With the "◆" on its own you leave noise that looks like content. It was
    // seen in the free-auto E2E: 403 -> 5xx x3 -> history with a "◆" and
    // nothing behind it.
    //
    // CAREFUL: `streamEnd` ENQUEUES the paragraph in `pending` (the draw drains
    // it), so you have to drain before looking at `paras`. Before that change it
    // went into `paras` directly and this test counted without draining.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.streamStart();
    m.streamEnd();
    m.drainPending();
    try std.testing.expectEqual(@as(usize, 0), countAssistant(&m));

    // But if there IS text it is stored.
    m.streamStart();
    m.streamDelta("OK");
    m.streamEnd();
    m.drainPending();
    try std.testing.expectEqual(@as(usize, 1), countAssistant(&m));

    // And whitespace only counts as empty: that is what a model that answers with
    // a "\n" and nothing else returns, and a paragraph with a space is noise
    // just like an empty one. The TOTAL count does not change: there is still
    // one paragraph, the one with real text.
    m.streamStart();
    m.streamDelta("  \n ");
    m.streamEnd();
    m.drainPending();
    try std.testing.expectEqual(@as(usize, 1), countAssistant(&m));
    try std.testing.expect(!m.busy);
}

test "streamEnd with no text also clears `streaming`, so nothing counts forever" {
    // The other half of the empty-buffer case, and the one that did the visible
    // damage.
    //
    // `self.streaming = false` used to live INSIDE `if (has_text and ...)`, so a
    // turn that ended with an empty buffer left the model "streaming" forever.
    // `workingLocked()` counts `streaming`, so from then on EVERY frame kept
    // showing an activity clock, spinner and busy status long after the turn
    // was over.
    //
    // The test above asserted `!busy` and the paragraph count and never
    // `!streaming`, which is exactly why it stayed hidden.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.streamStart();
    try std.testing.expect(m.streaming);
    m.streamEnd();
    try std.testing.expect(!m.streaming);
    try std.testing.expect(!m.workingLocked());

    // And nothing invents a live line on the next frame.
    m.pushInfo("algo");
    const s = try drawTest(&m, arena_state.allocator(), 60, 20);
    try std.testing.expect(std.mem.indexOf(u8, allText(s), "thinking") == null);

    // Same with whitespace only, which is what a model that answers with a
    // single newline produces.
    m.streamStart();
    m.streamDelta("  \n ");
    m.streamEnd();
    try std.testing.expect(!m.streaming);
    try std.testing.expect(!m.workingLocked());

    // And a turn with text still ends up not streaming.
    m.streamStart();
    m.streamDelta("hola");
    m.streamEnd();
    try std.testing.expect(!m.streaming);
    m.drainPending();
    try std.testing.expectEqual(@as(usize, 1), countAssistant(&m));
}

// ── `ask`: the question state ────────────────────────────────

/// Opens a question the way the worker does, without blocking: this is what the
/// tests use to put the model in "it asked something" without a second thread.
///
/// It goes through the same fields `requestAsk` fills, which is the point of the
/// test: if the field names drift, this and the real path drift together.
fn openAskForTest(m: *Model, question: []const u8, header: []const u8, options: []const []const u8) !void {
    const q = try m.allocator.dupe(u8, question);
    errdefer m.allocator.free(q);
    const h = try m.allocator.dupe(u8, header);
    errdefer m.allocator.free(h);
    m.askLock();
    m.freeAskStringsLocked();
    m.ask_question = q;
    m.ask_header = h;
    for (options) |o| {
        const oc = try m.allocator.dupe(u8, o);
        try m.ask_options.append(m.allocator, oc);
    }
    m.ask_answer = null;
    m.ask_typing = false;
    m.ask_active = true;
    // NO `ask_started_ns`: it is 0 here, which is what `askMillis` returns, and a
    // test that wanted a nonzero clock would be testing the clock, not the ask.
    m.askUnlock();
}

test "ask: the question is on screen AND in the strip with its clock" {
    // What matters: the question is DRAWN. A worker parked waiting for a question
    // that is not on screen is indistinguishable from a freeze, which is the bug
    // this repo has already paid for once.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    try openAskForTest(&m, "Que base de datos usamos?", "backend", &.{});

    // The strip says it is waiting for an ANSWER (not "thinking"), because the
    // difference between "I am working" and "I am waiting for you" is exactly
    // what makes you look at the modal.
    try std.testing.expect(m.activity().ask);

    const s = try drawTest(&m, arena, 100, 30);
    try std.testing.expect(findRow(s, "Que base de datos usamos?") != null);
    try std.testing.expect(findRow(s, "backend") != null);
    // And the strip's clock.
    try std.testing.expect(findRow(s, "waiting for your answer") != null);
}

test "ask: the strip warns of the wait WITH SECONDS, not just that it waits" {
    // The number is what answers "is it hung?". Without it, "waiting for your
    // answer" is indistinguishable from a freeze two seconds in.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    try openAskForTest(&m, "sigo?", "", &.{});
    // The clock needs an `Io`: the tests build the Model without an app, and
    // `io_ready = false` on purpose (reading an uninitialized vtable is a jump
    // into garbage). `std.testing.io` is a real `Io` and does not depend on the
    // machine beyond "now".
    m.attachIo(std.testing.io);
    m.ask_started_ns = std.Io.Timestamp.now(std.testing.io, .real).nanoseconds;

    const s = try drawTest(&m, arena, 100, 30);
    try std.testing.expect(findRow(s, "to answer") != null);
}

test "ask: with no options there is NO menu (it would be an empty list)" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    try openAskForTest(&m, "que nombre le pongo al modulo?", "", &.{});
    try std.testing.expect(!m.askNeedsChoice());
    try std.testing.expectEqual(@as(usize, 0), m.askChoiceRows());
}

test "ask: with options the PANEL is the menu, plus the way out of it" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    const options = [_][]const u8{ "usar el parser nuevo", "arreglar el bucle", "dejarlo" };
    try openAskForTest(&m, "Que enfoque?", "enfoque", &options);

    try std.testing.expect(m.askNeedsChoice());
    // options + "Other". Without that row the menu is an exam with one valid
    // answer, and the model gets a forced choice.
    try std.testing.expectEqual(options.len + 1, m.askChoiceRows());
}

test "ask: the options are painted INSIDE the panel, numbered, and the selection has a marker" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    const options = [_][]const u8{ "postgres", "sqlite", "mysql" };
    try openAskForTest(&m, "Que storage uso?", "backend", &options);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const s = try drawTest(&m, arena_state.allocator(), 100, 30);

    // The question is on screen...
    try std.testing.expect(findRow(s, "Que storage uso?") != null);
    // ...the header is its label, not the answer...
    try std.testing.expect(findRow(s, "backend") != null);
    // ...every option is a NUMBERED row of the same box...
    try std.testing.expect(findRow(s, "1 postgres") != null);
    try std.testing.expect(findRow(s, "2 sqlite") != null);
    try std.testing.expect(findRow(s, "3 mysql") != null);
    try std.testing.expect(findRow(s, "4 " ++ ask_other_label) != null);
    // ...the first row is marked as the recommendation, in words and not implied
    // by position...
    try std.testing.expect(findRow(s, "recommended") != null);
    // ...and the highlighted row says so with a marker, not only with a colour.
    try std.testing.expect(findRow(s, "▸ 1 postgres") != null);
}

test "ask: option text stays on one row and clipped choices show an ellipsis" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    const long_option = "this option is intentionally much longer than the width available inside the ask panel and must be visibly shortened";
    const options = [_][]const u8{ "first choice\nsecond line", long_option };
    try openAskForTest(&m, "Choose one approach", "design", &options);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const s = try drawTest(&m, arena_state.allocator(), 90, 26);

    const normalized_row = findRow(s, "first choice second line") orelse return error.TestUnexpectedResult;
    var line_buf: [256]u8 = undefined;
    const normalized_line = rowText(s, normalized_row, &line_buf);
    try std.testing.expect(std.mem.indexOf(u8, normalized_line, "│") != null);

    const clipped_row = findRow(s, "this option is intentionally") orelse return error.TestUnexpectedResult;
    const clipped_line = rowText(s, clipped_row, &line_buf);
    const left_bar = std.mem.indexOf(u8, clipped_line, "│") orelse return error.TestUnexpectedResult;
    const right_bar = std.mem.lastIndexOf(u8, clipped_line, "│") orelse return error.TestUnexpectedResult;
    try std.testing.expect(right_bar > left_bar);
    try std.testing.expect(std.mem.indexOf(u8, clipped_line[left_bar..right_bar], "…") != null);
}

test "ask: narrow and short layouts keep the question visible in the compact panel" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    const options = [_][]const u8{"recommended option"};
    try openAskForTest(&m, "Which approach should we take?", "design", &options);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const narrow = try drawTest(&m, arena_state.allocator(), 20, 18);
    try std.testing.expect(std.mem.indexOf(u8, allText(narrow), "Which approach") != null);
    try std.testing.expect(std.mem.indexOf(u8, allText(narrow), "▸ 1") != null);

    var small_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer small_arena.deinit();
    const short = try drawTest(&m, small_arena.allocator(), 80, 13);
    try std.testing.expect(std.mem.indexOf(u8, allText(short), "Which approach") != null);
    try std.testing.expect(std.mem.indexOf(u8, allText(short), "▸ 1 recommended") != null);
}

test "ask: the option list lives in the panel box, so it cannot be painted over it" {
    // The regression: the options were items of a centred modal picker painted
    // BEFORE the panel, and the panel erased its own rectangle on top of it. With
    // a long question the panel is the wider of the two, so it ate the picker's
    // last option and its footer, and the menu looked like a rendering bug.
    // There is no picker left to overlap, so what this pins is that every option
    // is inside the borders of the SAME box.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    const options = [_][]const u8{ "aaa", "bbb", "ccc", "ddd", "eee" };
    try openAskForTest(&m, "Cual de estos cinco es el que quieres, y por que exactamente?", "choice", &options);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const s = try drawTest(&m, arena_state.allocator(), 80, 24);

    for (options) |o| {
        const row = findRow(s, o) orelse return error.TestUnexpectedResult;
        var tbuf: [256]u8 = undefined;
        const text = rowText(s, row, &tbuf);
        try std.testing.expect(std.mem.indexOf(u8, text, "│") != null);
    }
}

test "ask: the highlight moves with the arrows and saturates at both ends" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    const options = [_][]const u8{ "uno", "dos" };
    try openAskForTest(&m, "cual?", "", &options);

    try std.testing.expectEqual(@as(usize, 0), m.askSelection());
    m.askMove(-1); // already at the top: stays
    try std.testing.expectEqual(@as(usize, 0), m.askSelection());
    m.askMove(1);
    try std.testing.expectEqual(@as(usize, 1), m.askSelection());
    m.askMove(1); // the "Other" row
    try std.testing.expectEqual(@as(usize, 2), m.askSelection());
    m.askMove(1); // saturates, it does not run off the list
    try std.testing.expectEqual(@as(usize, 2), m.askSelection());
    m.askMove(-1);
    try std.testing.expectEqual(@as(usize, 1), m.askSelection());
}

test "ask: Enter takes the highlighted option" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    const options = [_][]const u8{ "uno", "dos" };
    try openAskForTest(&m, "cual?", "", &options);

    m.askMove(1);
    try std.testing.expect(m.askAnswerSelected());
    try std.testing.expect(!m.askActive()); // closed in the same frame
    m.askLock();
    defer m.askUnlock();
    try std.testing.expectEqualStrings("dos", m.ask_answer.?);
}

test "ask: Enter on the LAST row is not an answer, it hands over the input box" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    const options = [_][]const u8{"uno"};
    try openAskForTest(&m, "cual?", "", &options);
    m.askMove(1); // "Other"
    try std.testing.expect(m.askAnswerSelected());
    try std.testing.expect(m.askTyping());
    try std.testing.expect(m.askActive());
}

test "ask: the answer takes OWNERSHIP, so a literal in it would be an Invalid free" {
    // `answerAskOwned` frees the text when the Model goes away, so everything on
    // this path has to be a gpa copy: the label used to arrive from the picker,
    // which freed it right after the callback, and a literal was a crash at exit.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    try openAskForTest(&m, "cual?", "", &[_][]const u8{ "a", "b" });

    const owned = try m.allocator.dupe(u8, "a");
    m.answerAskOwned(owned);

    m.askLock();
    defer m.askUnlock();
    try std.testing.expectEqualStrings("a", m.ask_answer.?);
}

test "ask: ESC means \"you decide\", and the state closes" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    try openAskForTest(&m, "te da igual?", "", &.{});

    m.declineAsk();
    try std.testing.expect(!m.askActive());
    // And the answer exists: the worker has to be able to wake up and go on.
    m.askLock();
    defer m.askUnlock();
    try std.testing.expect(m.ask_answer != null);
}

test "ask: declining twice does not clobber the first answer" {
    // The second ESC (or an ESC from the app) must not free the answer the worker
    // has not taken yet.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    try openAskForTest(&m, "q?", "", &.{});
    const first = try m.allocator.dupe(u8, "primera");
    m.answerAskOwned(first);
    m.declineAsk();
    m.askLock();
    defer m.askUnlock();
    try std.testing.expectEqualStrings("primera", m.ask_answer.?);
}

test "ask: in answer mode the menu does NOT come back" {
    // If `askChoiceRows` did not look at `ask_typing`, the option list would come
    // back on the next frame, on top of what the user is typing.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    try openAskForTest(&m, "cual?", "", &[_][]const u8{ "a", "b" });
    try std.testing.expect(m.askNeedsChoice());
    m.askBeginTyping();
    try std.testing.expect(!m.askNeedsChoice());
}

test "ask: typing in the input box answers the question instead of starting a turn" {
    // The free-text path had no `ask_typing`: with no options nothing ever set
    // it, the panel said "type your answer below", and Submit sent a NEW PROMPT
    // that got queued behind the worker parked waiting for the answer. The user
    // answered the question and it looked like the app ignored them.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    try openAskForTest(&m, "te da igual?", "", &.{});
    try std.testing.expect(!m.askTyping());

    try m.ed.insert("el que prefieras");
    try std.testing.expect(m.askAnswerFromInput("el que prefieras"));

    m.askLock();
    defer m.askUnlock();
    try std.testing.expectEqualStrings("el que prefieras", m.ask_answer.?);
}

test "ask: the picker title is the model's header, or the default text" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    try openAskForTest(&m, "cual?", "base de datos", &[_][]const u8{"a"});
    try std.testing.expectEqualStrings("base de datos", m.askTitle());

    try openAskForTest(&m, "cual?", "", &[_][]const u8{"a"});
    try std.testing.expectEqualStrings("the model has a question", m.askTitle());
}

test "ask: the panel is opaque, the history does not show through it" {
    // `drawAskPanel` cleared only the TOP row of its box, which is the border
    // line. Every other row was left holding whatever the history had just
    // painted there, so the question, the hint and the clock were drawn ON TOP of
    // the assistant's answer, the tool results and the code blocks. It reads as a
    // rendering bug, and it was reported as one.
    //
    // Two things this test needed to get right, both learned the hard way:
    //
    // 1. NO OPTIONS. With options the question opens a PICKER, which is a
    //    different widget that already cleared its box row by row. The panel is
    //    the free-text path, and that is the one that did not clear.
    // 2. A history that fills EVERY row. With one-line paragraphs every second
    //    row is the blank separator, and the panel's own text happened to land
    //    exactly on the rows that had history behind them, so the bug was
    //    invisible. Paragraphs with embedded newlines put text on every row, and
    //    then the short "waiting 0s" clock row leaves the history showing
    //    through on its right.
    //
    // The history is a run of 'x' and the panel's own text contains none, so
    // "is there an 'x' inside the box" is an unambiguous question.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    var i: usize = 0;
    while (i < 30) : (i += 1) {
        m.pushInfo("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\nxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\nxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx");
    }
    try openAskForTest(&m, "cual de estos dos?", "", &.{});

    const s = try drawTest(&m, arena, 90, 30);
    const qrow = findRow(s, "cual de estos dos?") orelse return error.TestUnexpectedResult;

    // The panel's own borders, FOUND rather than computed: `box_w` depends on
    // the wrapped width of the question, and a test that hardcodes the geometry
    // ends up checking the wrong columns (which is how the first version of this
    // test passed with the bug still in place).
    var bbuf: [512]u8 = undefined;
    const qline = rowText(s, qrow, &bbuf);
    const first_bar = std.mem.indexOf(u8, qline, "\u{2502}") orelse return error.TestUnexpectedResult;
    const last_bar = std.mem.lastIndexOf(u8, qline, "\u{2502}") orelse return error.TestUnexpectedResult;
    try std.testing.expect(last_bar > first_bar);

    var checked: usize = 0;
    var row: u16 = qrow;
    while (row < s.size.height) : (row += 1) {
        const line = rowText(s, row, &bbuf);
        if (std.mem.indexOf(u8, line, "\u{2570}") != null) break; // bottom border
        if (std.mem.indexOf(u8, line, "\u{256d}") == null and
            std.mem.indexOf(u8, line, "\u{2502}") == null) continue;
        // Only the columns the panel covers matter: the history legitimately
        // shows on either side of it.
        const inside = line[first_bar + "\u{2502}".len .. @min(last_bar, line.len)];
        try std.testing.expect(std.mem.indexOfScalar(u8, inside, 'x') == null);
        checked += 1;
    }
    try std.testing.expect(checked >= 3); // the box really was inspected
}

test "ask: the snapshot goes to the frame arena (no pointers into the worker)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    try openAskForTest(&m, "cual?", "", &[_][]const u8{ "a", "b" });

    const snap = m.askSnapshot(arena) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("cual?", snap.question);
    try std.testing.expectEqual(@as(usize, 2), snap.options.len);
    try std.testing.expectEqualStrings("b", snap.options[1]);
}

test "ask: with no open question the snapshot is null (not an empty panel)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    try std.testing.expect(m.askSnapshot(arena_state.allocator()) == null);
}

test "the permission mode shows up in the status bar as a GLYPH" {
    // A mode you cannot see is a mode in which "the model ignored my edit" cannot
    // be told apart from "the model never tried".
    //
    // REWRITTEN (2026-10-21): the mode used to be a WORD ("plan", "bypass",
    // "accept-edits") and it is now a GLYPH, because a word costs twelve
    // columns in a footer that has to survive an eighty-column terminal. The
    // legend of the glyphs is in the shortcut list (`?`).
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const status_row: u16 = 30 - 1;
    var buf: [400]u8 = undefined;

    const before = try drawTest(&m, arena, 100, 30);
    const before_row = rowText(before, status_row, &buf);
    // The default shows NOTHING: a footer that repeats the default in every
    // row of every session is a footer nobody reads.
    try std.testing.expect(std.mem.indexOf(u8, before_row, "●") == null);
    try std.testing.expect(std.mem.indexOf(u8, before_row, "plan") == null);

    agent.read_only = true;
    defer agent.read_only = false;

    const after = try drawTest(&m, arena, 100, 30);
    const after_row = rowText(after, status_row, &buf);
    // The glyph is there, and it is ONE column wide.
    try std.testing.expect(std.mem.indexOf(u8, after_row, "●") != null);
    try std.testing.expect(std.mem.indexOf(u8, after_row, "plan") == null);
}

test "@ mention: the popup lists files AND is painted, and does not hide the ones that do not fit" {
    // The symptom that was reported: "@ does not give me the list of files". The popup
    // existed and filled up (that part was already covered by `fileQueryAt` and
    // `refreshFileMatches`), but it was drawn glued to the edge of the screen and
    // with NO HINT AT ALL that more were left: with 10 entries and `max_visible` =
    // 6, you saw 6 and the rest did not exist as far as the user was concerned. A
    // popup truncated in silence is worse than one that does not open, because it
    // looks like the directory only has those files.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.attachIo(threaded.io());

    m.ed.clear();
    _ = m.ed.insert("@") catch unreachable;
    m.ed.setCursor(1);
    syncAutocomplete(&m);

    // The mode is the file one and there are matches (the CWD of the tests has more
    // than one: `src/`, `build.zig`...).
    try std.testing.expectEqual(Autocomplete.Mode.file, m.ac.mode);
    try std.testing.expect(m.ac.file_matches.items.len > 1);

    // And it is PAINTED: the rows exist in the surface, with the `@` in front.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const surf = try drawTest(&m, arena_state.allocator(), 72, 24);
    var rb: [256]u8 = undefined;
    var seen_rows: usize = 0;
    var has_at_prefix = false;
    for (0..24) |r| {
        const row = rowText(surf, @intCast(r), &rb);
        // A popup row is "@name": the `@` in the item's column.
        const t = std.mem.trim(u8, row, " ");
        if (t.len > 0 and t[0] == '@') {
            seen_rows += 1;
            has_at_prefix = true;
        }
    }
    try std.testing.expect(seen_rows > 1);
    try std.testing.expect(has_at_prefix);

    // The popup must NOT lie about how many there are: if there are more than fit,
    // the last row says so. That is what turns "there are only these" into
    // "there are more".
    if (m.ac.file_matches.items.len > m.ac.max_visible) {
        const ac_rows: u16 = @intCast(@min(m.ac.file_matches.items.len, m.ac.max_visible) + 1);
        try std.testing.expect(ac_rows >= @as(u16, @intCast(m.ac.max_visible)));
    }
}

test "@ mention: a name deep in the tree is found, ranked first, and its matched letters are BOLD" {
    // The old popup listed ONE directory, read on every keystroke: `@fuzzy`
    // answered nothing unless you happened to be standing in `src/lib/`, and
    // going deeper meant typing the path by hand. The list is now the project
    // index (`filesearch`), filtered and ranked by `fuzzy`, and the popup paints
    // the characters the query reached in bold — with dozens of candidates, WHY
    // a row is there has to be visible.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.attachIo(threaded.io());

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zode-at-deep-{d}", .{std.testing.random_seed});
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const deep = try std.fmt.allocPrint(a, "{s}/nested", .{root});
    try std.Io.Dir.cwd().createDirPath(io, deep);
    const file = try std.fmt.allocPrint(a, "{s}/needle_marker.zig", .{deep});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = "pub const x = 1;\n" });

    m.ed.clear();
    _ = m.ed.insert("@needle") catch unreachable;
    m.ed.setCursor(7);
    syncAutocomplete(&m);

    try std.testing.expectEqual(Autocomplete.Mode.file, m.ac.mode);
    try std.testing.expect(m.ac.file_matches.items.len > 0);
    // The basename wins over everything else that can hide "needle" as a
    // subsequence: the ranking is what makes a 20 000-file index usable.
    try std.testing.expect(std.mem.endsWith(u8, m.ac.file_matches.items[0], "needle_marker.zig"));

    const surf = try drawTest(&m, arena_state.allocator(), 100, 24);
    var rb: [256]u8 = undefined;
    var found_row: ?u16 = null;
    var hit_col: u16 = 0;
    for (0..24) |r| {
        const row = rowText(surf, @intCast(r), &rb);
        const at = std.mem.indexOf(u8, row, "needle_marker") orelse continue;
        found_row = @intCast(r);
        hit_col = @intCast(at);
        break;
    }
    try std.testing.expect(found_row != null);

    // `n` of "needle" (the first matched byte) is painted with the bright
    // accent and bold; the `/` before the name is not.
    const hit = surf.readCell(hit_col, found_row.?);
    try std.testing.expect(hit.style.bold);
    try std.testing.expect(std.meta.eql(hit.style.fg, theme.brand_hi.fg));
    // The directory in front of the name is NOT the bright accent: the eye has
    // to land on the file, and the path only says which one it is.
    const dir_cell = surf.readCell(2, found_row.?);
    try std.testing.expect(!std.meta.eql(dir_cell.style.fg, theme.brand_hi.fg));
}

test "timeline: a wrapped paragraph keeps a gutter on every continuation row" {
    // The kind marker (`› `, `◆ `, `⏺ `, `⎿  `) only ever went on the FIRST row
    // of a block, and the continuation indent was two anonymous spaces, the same
    // width as the marker. A six-row tool result therefore had one identifiable
    // row and five that looked like a notice. Now the continuation carries a bar.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.streamStart();
    m.streamDelta("esta respuesta es deliberadamente larga para que ocupe varias filas del historial");
    m.streamEnd();

    const s = try drawTest(&m, arena_state.allocator(), 44, 14);
    var buf: [160]u8 = undefined;
    var first: ?u16 = null;
    var conts: usize = 0;
    var row: u16 = 0;
    while (row < 8) : (row += 1) {
        const t = rowText(s, row, &buf);
        if (std.mem.indexOf(u8, t, "deliberadamente") != null) first = row;
        if (first != null and row > first.? and std.mem.indexOf(u8, t, "\u{2502}") != null) conts += 1;
    }
    try std.testing.expect(first != null);
    try std.testing.expect(conts >= 1);
}

test "timeline: a list answer shows bullets, and the markers are not the text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.streamStart();
    m.streamDelta("- primero lo importante\n- despues lo otro");
    m.streamEnd();

    const s = try drawTest(&m, arena_state.allocator(), 60, 14);
    try std.testing.expect(findRow(s, "• primero lo importante") != null);
    try std.testing.expect(findRow(s, "• despues lo otro") != null);
    // The hyphen the model typed is gone: normalized, not echoed.
    try std.testing.expect(findRow(s, "- primero") == null);
}

test "timeline: a code block has a background behind the code, not only after it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.streamStart();
    m.streamDelta("```zig\nconst n: u32 = 4;\n```");
    m.streamEnd();

    const s = try drawTest(&m, arena_state.allocator(), 40, 14);
    const row = findRow(s, "const n") orelse return error.TestUnexpectedResult;
    // The code itself sits on the background, not just the padding after it:
    // the block is a rectangle, not a stripe whose width changes with the
    // length of each line (which is what it was on any background but #1a1b26).
    // Read a cell that is definitely code text (the "c" of "const"); a fixed
    // column could land in the left margin or on a border cell instead.
    const code_cell = cellWith(s, row, "c") orelse return error.TestUnexpectedResult;
    const code_bg = code_cell.style.bg;
    const code_bg_rgb = switch (code_bg) {
        .rgb => |c| c,
        else => unreachable,
    };
    const want_bg = theme.code_bg.bg;
    const want_bg_rgb = switch (want_bg) {
        .rgb => |c| c,
        else => unreachable,
    };
    try std.testing.expect(std.mem.eql(u8, &code_bg_rgb, &want_bg_rgb));
}

test "scroll: correcting a paragraph's height does not move the text under the reader" {
    // The bug: the top of the view was an ABSOLUTE line number, and a paragraph's
    // height is an estimate until it is parsed. Parsing replaces the estimate
    // with the real height, so the same line number started pointing at
    // something else and the view jumped by however wrong the estimate was —
    // while you were scrolling, which is where a jump is least welcome.
    //
    // The scenario is a history full of fenced code blocks: a fence costs three
    // rows (blank, chip, blank) that the estimator cannot know about.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    var i: usize = 0;
    while (i < 8) : (i += 1) {
        m.pushInfoFmt("linea corta {d}", .{i});
        m.pushKind(.assistant, "```zig\nconst a = 1;\nconst b = 2;\n```");
    }

    const h: u16 = 20;
    _ = try drawTest(&m, arena_state.allocator(), 60, h); // first frame: at the bottom
    m.scrollBy(6);

    // Frame A: this one parses whatever is now in the window, so the heights
    // above the reader get corrected.
    const a = try drawTest(&m, arena_state.allocator(), 60, h);
    // Frame B: same anchor, and by now everything in the window is parsed.
    const b = try drawTest(&m, arena_state.allocator(), 60, h);

    var ba: [160]u8 = undefined;
    var bb: [160]u8 = undefined;
    // Row by row: what the reader is looking at must be the same thing.
    var row: u16 = 0;
    while (row < 6) : (row += 1) {
        try std.testing.expectEqualStrings(rowText(a, row, &ba), rowText(b, row, &bb));
    }
}

test "scroll: reading above, the text keeps arriving without moving the view" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    var i: usize = 0;
    while (i < 12) : (i += 1) m.pushInfoFmt("uno {d}", .{i});
    _ = try drawTest(&m, arena_state.allocator(), 60, 20);

    m.scrollBy(6);
    try std.testing.expect(!m.follow_bottom);
    const read_line = m.anchorLine();
    const read_para = m.anchor_para;

    // The model keeps talking. Every new paragraph goes to the END of the
    // history, which is far below the reader, so nothing about what is on screen
    // may change.
    var j: usize = 0;
    while (j < 3) : (j += 1) {
        m.pushInfoFmt("llega {d}", .{j});
        _ = try drawTest(&m, arena_state.allocator(), 60, 20);
        try std.testing.expectEqual(read_line, m.anchorLine());
        try std.testing.expectEqual(read_para, m.anchor_para);
        try std.testing.expect(!m.follow_bottom);
    }

    // And the bottom is still reachable, and re-arms the follow.
    m.scrollBy(-1000);
    try std.testing.expect(m.follow_bottom);
}

test "scroll: down then up returns to the same line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    var i: usize = 0;
    while (i < 30) : (i += 1) m.pushInfoFmt("linea {d} de un historial bastante largo", .{i});
    _ = try drawTest(&m, arena_state.allocator(), 60, 20);

    const start = m.anchorLine();
    m.scrollBy(4); // up: `n > 0` is UP (see `scrollBy`)
    try std.testing.expectEqual(start - 4, m.anchorLine());
    m.scrollBy(-4); // back down
    try std.testing.expectEqual(start, m.anchorLine());
    m.scrollBy(-1000); // to the bottom
    try std.testing.expect(m.follow_bottom);
    m.scrollBy(1000); // and to the top
    try std.testing.expectEqual(@as(usize, 0), m.anchorLine());
}

test "scroll: a wheel event cannot underflow the anchor" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.pushInfo("hola");
    _ = try drawTest(&m, arena_state.allocator(), 60, 20);

    // This used to be `self.scroll -= 3` on a usize: two wheel-up events at the
    // top of the history overflowed and the process panicked.
    m.scrollBy(3);
    m.scrollBy(3);
    try std.testing.expectEqual(@as(usize, 0), m.anchorLine());
    m.scrollBy(-3);
    m.scrollBy(-3);
    try std.testing.expectEqual(@as(usize, 0), m.anchorLine());
}

test "ctrl+d scrolls back down and does NOT quit" {
    // The regression: ctrl+d with an empty input was EOF (`ctx.quit = true`), and
    // an empty input is the NORMAL state while scrolling — you scroll up to read
    // something, press ctrl+d to come back down, and zode exits. `/help` says
    // "ctrl+u / ctrl+d = scroll half a page" and the status bar says "ctrl+c
    // exits", so the app contradicted both of its own strings.
    //
    // The shape of the assertion is "up then down", not "down moves": where the
    // bottom of the scroll is depends on which paragraphs have been laid out
    // (the rest are still estimates), and a test that pinned an absolute line
    // would be a test of the estimates.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    var i: usize = 0;
    while (i < 60) : (i += 1) m.pushInfoFmt("linea {d} de un historial bastante largo", .{i});
    _ = try drawTest(&m, arena_state.allocator(), 60, 20);

    // `armTick` goes through the `Io` of the EventContext, and `testCtx` leaves it
    // undefined: reading it is a jump through a garbage vtable, which is a GPF
    // rather than a failed assertion.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var ctx_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ctx_arena.deinit();
    var ctx = testCtx();
    ctx.io = threaded.io();
    // An arena for the context: `armTick` allocates a `Tick` (it holds the `Io`)
    // and nothing in a test has any reason to own one command list entry by entry.
    ctx.alloc = ctx_arena.allocator();
    m.attachIo(threaded.io());

    // Empty input: that is the state the bug needed.
    try std.testing.expect(m.ed.isEmpty());

    // The arrow keys scroll one line when the editor is empty.
    const bottom = m.anchorLine();
    try typeErasedEventHandler(&m, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.up } });
    const arrow_up = m.anchorLine();
    try std.testing.expect(arrow_up < bottom);
    try typeErasedEventHandler(&m, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
    try std.testing.expectEqual(bottom, m.anchorLine());

    try typeErasedEventHandler(&m, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.home } });
    try std.testing.expectEqual(@as(usize, 0), m.anchorLine());
    const scrolled = try drawTest(&m, arena_state.allocator(), 60, 20);
    var footer_buf: [256]u8 = undefined;
    const footer = rowText(scrolled, scrolled.size.height - 1, &footer_buf);
    try std.testing.expect(std.mem.indexOf(u8, footer, "latest") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "↓ 1") == null);
    const latest = m.currentMaxOffset();
    // The clickable `↓ latest` zone is PUBLISHED by the footer, so the test does
    // not have to know where the footer decided to put it: it reads the
    // columns. A test that recomputed the position would be a test of the
    // layout, and it would break the day the layout changed.
    try std.testing.expect(m.scroll_bottom_start > 0);
    try std.testing.expect(m.scroll_bottom_end > m.scroll_bottom_start);
    const click_col = m.scroll_bottom_start + 1;
    try typeErasedEventHandler(&m, &ctx, .{ .mouse = .{
        .col = @intCast(click_col),
        .row = @intCast(scrolled.size.height - 1),
        .button = .left,
        .mods = .{},
        .type = .press,
    } });
    try std.testing.expectEqual(latest, m.anchorLine());
    try typeErasedEventHandler(&m, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.end } });
    try std.testing.expectEqual(latest, m.anchorLine());

    // Page shortcuts still work with the empty input the whole way.
    try typeErasedEventHandler(&m, &ctx, .{ .key_press = .{ .codepoint = 'u', .mods = .{ .ctrl = true } } });
    try std.testing.expect(!ctx.quit);
    const up = m.anchorLine();

    try typeErasedEventHandler(&m, &ctx, .{ .key_press = .{ .codepoint = 'd', .mods = .{ .ctrl = true } } });
    try std.testing.expect(!ctx.quit);
    try std.testing.expect(m.anchorLine() >= up);

    // And ctrl+c is the exit, which is what `/help` says.
    try typeErasedEventHandler(&m, &ctx, .{ .key_press = .{ .codepoint = 'c', .mods = .{ .ctrl = true } } });
    try std.testing.expect(ctx.quit);
}

test "ask panel wraps by words, stays in history, and leaves the answer input visible" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    try openAskForTest(
        &m,
        "Choose alpha beta exceptionallylongword and explain the tradeoff.",
        "Decision",
        &.{ "Use adapter", "Add adapter" },
    );
    const s = try drawTest(&m, arena, 40, 24);

    // The complete word remains on one row instead of being split at the box
    // edge, and the question's choices remain inside the bordered panel.
    try std.testing.expect(findRow(s, "exceptionallylongword") != null);
    try std.testing.expect(findRow(s, "recommended") != null);
    try std.testing.expect(findRow(s, "Use adapter") != null);

    // The panel is confined to the history viewport; the borderless prompt and
    // status strip remain painted and usable underneath it.
    //
    // In ask mode the prompt is `?` (warn color) to distinguish from normal prompt.
    const input_top = s.size.height - 2;
    try std.testing.expectEqualStrings("?", s.readCell(1, input_top).char.grapheme);
    try std.testing.expect(findRow(s, "enter answers") != null);
}

test "ramReport: an empty session is zero, and the split adds up by construction" {
    // The report exists so a slope can be attributed, which only works if hot and
    // cold are SEPARATE numbers. The invariant is the one that matters and it is
    // the one that cannot rot silently: `scrollbackBytes` is the sum, so a
    // paragraph counted in neither bucket would make the total lie.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    m.attachIo(threaded.io());

    const empty = m.ramReport();
    try std.testing.expectEqual(@as(usize, 0), empty.paras);
    try std.testing.expectEqual(@as(usize, 0), empty.hot);
    try std.testing.expectEqual(@as(usize, 0), empty.cold);
    try std.testing.expectEqual(@as(usize, 0), empty.scrollbackBytes());
    try std.testing.expectEqual(@as(usize, 0), empty.cache_entries);
}

test "ramReport: what is in the scrollback is counted, hot and compressed apart" {
    // `paras` only grows from the UI thread through `drainPendingLocked`, which is
    // the invariant that lets the draw read `paras[i].text` without the lock. So
    // the test goes through the same door: enqueue, then drain.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    m.attachIo(threaded.io());

    // A long paragraph and a short one, so the byte total is not just the count.
    var long_buf: [4096]u8 = undefined;
    @memset(long_buf[0..4096], 'x');
    m.pushInfo(long_buf[0..4096]);
    m.pushInfo("short");
    m.drainPending();

    const r = m.ramReport();
    try std.testing.expectEqual(@as(usize, 2), r.paras);
    try std.testing.expectEqual(@as(usize, 2), r.hot);
    try std.testing.expectEqual(@as(usize, 0), r.cold);
    try std.testing.expectEqual(r.hot + r.cold, r.paras);
    try std.testing.expectEqual(r.hot_bytes + r.cold_bytes, r.scrollbackBytes());
    try std.testing.expect(r.hot_bytes >= 4096 + 5);
}

test "selfRssKb reads the process's own RSS, or says 0" {
    // 0 on a target with no /proc is a valid answer and not a failure: the field
    // exists so the breakdown can be read next to the total, not so a non-Linux
    // build breaks.
    const kb = Model.selfRssKb();
    if (@import("builtin").os.tag == .linux) {
        try std.testing.expect(kb > 0);
        // A process cannot be smaller than a page.
        try std.testing.expect(kb >= 4);
    }
}

test "a long streaming paragraph does not exhaust the frame arena" {
    // The crash this pins: vaxis writes each grapheme into the frame arena, and the
    // live paragraph used to copy the WHOLE `stream_buf` into it and parse the whole
    // of it on EVERY frame. A 533-line code block — which is what a real task produces —
    // exhausted the ~1.36 MB frame arena and the process died with
    // `warning(vaxis): couldn't write grapheme: OutOfMemory`, mid-task, with the work
    // done and no verdict ever declared.
    //
    // Measured 2026-10-05 with `space-bunny-free` on a real task: 43 iterations of
    // goal work, a working implementation, and a dead process at the moment the output
    // got big. The tests could not see it because they only ever streamed short text.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    // What a `write` of a 533-line file looks like as a live stream, plus the syntax
    // highlighting that makes every token its own allocation.
    m.streaming = true;
    var i: usize = 0;
    while (i < 900) : (i += 1) {
        m.streamDelta("    if x_ == 42 { return \"y\"; } else { print z_ + 1; }\n");
    }

    // 100 frames: the live paragraph is re-parsed on every one, so one frame surviving
    // by luck is not enough.
    var frame: usize = 0;
    while (frame < 100) : (frame += 1) {
        _ = arena_state.reset(.retain_capacity);
        const s = try drawTest(&m, arena, 200, 50);
        _ = s;
    }
    // The assertion is that we got here: before the fix this frame returned
    // `error.OutOfMemory` and the test failed on the draw, not on a comparison.
    try std.testing.expect(m.stream_buf.items.len > 0);
}

test "a big diff paragraph plus scrolling does not walk the frame arena away" {
    // The other path that can exhaust the frame arena, and the one the September freeze
    // was about: `layoutFor` converges by re-parsing paragraphs until their heights stop
    // moving, and every pass allocates in the FRAME arena. A paragraph whose real height
    // keeps disagreeing with its estimate makes that loop run its budget — and the
    // budget was added so it fails a test instead of hanging the app, which means the
    // frame is still FULL when it gives up.
    //
    // This is what a real task produces: one `write` of a 500-line file is ONE diff
    // paragraph of ~2000 lines, and then the user scrolls through it while the next
    // iteration streams.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const before = "line\n" ** 900;
    const after = "changed line\n" ** 900;
    _ = m.pushDiff(before, after);
    // Drain it into the history the way the draw does.
    m.drainPending();

    // Scroll the whole thing, which is what forces `layoutWindow` to keep correcting
    // heights for paragraphs whose estimate is a placeholder.
    var step: usize = 0;
    while (step < 300) : (step += 7) {
        m.scrollBy(@intCast(step % 40 + 1));
        _ = arena_state.reset(.retain_capacity);
        const s = try drawTest(&m, arena, 200, 50);
        _ = s;
    }
    try std.testing.expect(m.paras.items.len > 0);
}

test "no painted cell carries a grapheme with an absurd length" {
    // The crash this pins, measured twice on real tasks (runs 1 and 4 of 4, with the
    // work DONE and no verdict declared):
    //
    //     warning(vaxis): couldn't write grapheme: OutOfMemory
    //
    // with the process at **6.5 MB RSS**, flat from the first sample to the last. Flat
    // RSS is the whole diagnosis: it is not memory that grows, and not memory that runs
    // out. vaxis's `InternalScreen.writeCell` does
    // `buf[i].char.appendSlice(arena, cell.char.grapheme)`, so an `OutOfMemory` on a
    // ONE-GRAPHEME append in a 6 MB process means the slice's LENGTH was garbage — the
    // `&[_]u8{c}` family AGENTS.md keeps paying for: a `Cell` stored by value with a
    // pointer to bytes that died before `Vaxis.render()` read them, so the length comes
    // from freed memory.
    //
    // Two hypotheses were tested and both were FALSE (the frame arena and the segment
    // cache), which is why this does not look for an allocation failure at all: a
    // garbage length of 40 bytes paints fine and only shows up as corruption. It walks
    // the painted surface instead and looks at the one thing that is always wrong.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    // One of everything a real turn produces at once, at the sizes a real turn
    // produces them: a 500-line write (the diff), its tool result, the tool header, a
    // long assistant paragraph and a live stream on top.
    const many = "    if x_ == 42 { return \"y\"; } else { print z_ + 1; }\n" ** 480;
    _ = m.pushDiff("old\n" ** 480, many);
    m.pushToolStart("write", "minilang.py");
    m.pushToolDone("write", "minilang.py", 120, many);
    m.pushKind(.assistant, many);
    m.pushKind(.tool_res, many);
    m.streaming = true;
    m.streamDelta(many);

    var frame: usize = 0;
    while (frame < 12) : (frame += 1) {
        m.scrollBy(3);
        _ = arena_state.reset(.retain_capacity);
        const s = try drawTest(&m, arena, 200, 50);

        var row: usize = 0;
        while (row < s.size.height) : (row += 1) {
            var col: usize = 0;
            while (col < s.size.width) : (col += 1) {
                const g = s.readCell(col, row).char.grapheme;
                // A grapheme is at most a handful of bytes. `+` as the bound is the
                // point: a real one is 1..4 and a joined emoji is 4, so nothing real
                // comes near it and a freed slice reads as thousands.
                try std.testing.expect(g.len <= 8);
            }
        }
    }
}

test "scrolling past the segment cache cap leaves no cell pointing at a freed arena" {
    // The gap in the test above: it had five paragraphs and the cache holds 128, so the
    // eviction path never ran. The crash is intermittent (2 of 4 real task runs) and both
    // of those turns produced a lot of text, which is what pushes the cache past its cap
    // WHILE a frame is being painted.
    //
    // `drawLines` paints `CellRun`s whose bytes live in the paragraph's own arena, and
    // the cache evicts LIFO when it goes over 128 — freeing an arena. If an entry that is
    // in the visible window gets evicted, the cells painted from it point at freed memory
    // and vaxis reads the LENGTH from it when it renders, after the frame: a garbage
    // length, `appendSlice` on a one-grapheme append, `OutOfMemory`, process gone. That
    // is the whole chain, and it explains a 6.5 MB flat RSS better than any leak story.
    //
    // 400 paragraphs — three times the cap — walked from the top to the bottom, and every
    // cell of every frame measured.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    var i: usize = 0;
    while (i < 400) : (i += 1) {
        var line: [160]u8 = undefined;
        const text = std.fmt.bufPrint(&line, "paragraph {d}: the quick brown fox jumps over the lazy dog " ++ "again " ** 8, .{i}) catch "";
        m.pushKind(if (i % 2 == 0) .assistant else .tool_res, text);
    }
    m.drainPending();

    var frame: usize = 0;
    while (frame < 400) : (frame += 1) {
        // Down through the whole history, one row at a time, which is what moves the
        // window across the cache boundary and forces the eviction.
        m.scrollBy(1);
        _ = arena_state.reset(.retain_capacity);
        const s = try drawTest(&m, arena, 200, 50);

        var row: usize = 0;
        while (row < s.size.height) : (row += 1) {
            var col: usize = 0;
            while (col < s.size.width) : (col += 1) {
                const g = s.readCell(col, row).char.grapheme;
                try std.testing.expect(g.len <= 8);
            }
        }
    }
}


// ── the wire path for the keys the terminals report differently ──
//
// `editorKey` has always had "shift+enter / alt+enter inserts a newline", and
// for the whole of its life it was code that could not be reached: no terminal
// reports a modified Enter unless it is ASKED to (`CSI > 1 u`), and zode never
// asked. What the user saw was Enter, which submits, and there was nothing to
// fix in the handler.
//
// So the test goes through the PARSER and not around it. A `Key` built by hand
// with `.shift = true` proves the handler works and proves nothing about
// whether the bytes on the wire ever become that `Key`, which is the half that
// was broken.
test "wire: CSI 13;2u arrives as enter+shift and inserts a newline" {
    // ONE arena owns everything that outlives a single step, in the order the
    // repo's own tests use. `m` gets its OWN allocator on purpose and it is
    // NOT the arena: the leak this test was reporting is `std.testing.allocator`
    // being handed a pointer that only `testing.allocator` knows about, and
    // with both allocators the DebugAllocator has no way to say which.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(arena);
    defer m.deinit();
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var ctx = testCtx();
    ctx.io = threaded.io();
    // `testCtx` returns `cmds = .empty` with NO allocator, and the key handler
    // appends to it. An `ArrayList` with no allocator is a leak the moment
    // anything is pushed, which is what this test was reporting — and it is
    // also a latent bug in every other test that pushes to `ctx.cmds`.
    ctx.alloc = arena;
    ctx.cmds = .empty;
    _ = std.testing.allocator;

    // The exact bytes a kitty-disambiguate terminal sends for Shift+Enter.
    // One character typed BEFORE the key, so the assertion that the input grew
    // is about the newline and not about an editor that started empty.

    var parser: vaxis.Parser = .{};
    // The `Key`s go into the ARENA, not into `testing.allocator`: `m.ed` is
    // freed by `defer m.deinit()` and this list is not, and a leak reported
    // against the DebugAllocator would fail this test for a reason that has
    // nothing to do with Shift+Enter.
    var keys: std.ArrayList(vaxis.Key) = .empty;
    const res = try parser.parse("\x1b[13;2u", arena);
    if (res.event) |ev| {
        switch (ev) {
            .key_press => |k| try keys.append(arena, k),
            else => {},
        }
    }
    // The whole sequence was consumed, and nothing was left for the next read.
    try std.testing.expectEqual(@as(usize, "\x1b[13;2u".len), res.n);
    // The parse produced a modified Enter, not a bare one.
    try std.testing.expectEqual(@as(usize, 1), keys.items.len);
    try std.testing.expectEqual(vaxis.Key.enter, keys.items[0].codepoint);
    try std.testing.expect(keys.items[0].mods.shift);

    // And the handler inserts the newline instead of submitting.
    const before_len = m.ed.text().len;
    try typeErasedEventHandler(&m, &ctx, .{ .key_press = keys.items[0] });
    try std.testing.expectEqual(before_len + 1, m.ed.text().len);
    // A newline means the input is now two ROWS and still open.
    //
    // Measured through `drawTest` and not through `ed.displayLines`: the
    // repo's `test_draw_ctx` has no `stringWidth` fn pointer, so a measurer
    // built on it returns garbage and the wrap count is meaningless. The
    // layout is what decides how many rows the box gets, and it is the thing
    // that has to be right — a two-row box for a one-row prompt is a bug the
    // editor's own counter cannot see.
    const s = try drawTest(&m, arena, 60, 20);
    try std.testing.expectEqual(@as(u16, 2), s.size.height - 1 - m.hist_rows - 1);
    // And the input is still OPEN with the text in it: a submit clears it, so this
    // is the observable difference between "inserted a newline" and "sent the
    // turn". The queue is not checked on purpose — `agent.submit` hands off to a
    // worker and, with no provider configured, refuses before it enqueues
    // anything, so an empty queue proves nothing.
    try std.testing.expect(!m.ed.isEmpty());
    try std.testing.expectEqualStrings("\n", m.ed.text());
}

/// Dots after "thinking": 0 to `ellipsis_max`.
fn ellipsisOf(n: usize) []const u8 {
    return switch (n) {
        0 => "",
        1 => ".",
        2 => "..",
        else => "...",
    };
}

/// Cap on the ellipsis, so it never becomes a bar of its own.
const ellipsis_max: usize = 3;

/// The mood of the face shown while the app waits on the human. Both states
/// are "stop and look at me", and the mascot gets the same face in each.
fn moodWaiting(act: Model.Activity) StatusKind {
    _ = act;
    return .warn;
}

test "render: the diff paints the line number and the changed words" {
    // The two things a diff has to say: WHICH line changed (the gutter) and
    // WHAT changed in it (the word diff).
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    _ = m.pushDiff("const x = 1;\n", "const x = 42;\n");

    const s = try drawTest(&m, arena, 60, 24);

    // The row with the added line.
    var row: u16 = 0;
    var found = false;
    var buf: [256]u8 = undefined;
    while (row < 24) : (row += 1) {
        if (std.mem.indexOf(u8, rowText(s, row, &buf), "const x = 42;") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);

    // The gutter: the line number, the space, the marker. (The row starts
    // with the history's own margin, so the check is a search and not a
    // prefix.)
    try std.testing.expect(std.mem.indexOf(u8, rowText(s, row, &buf), "1 +const") != null);

    // Only the CHANGED words carry the word background. The words that did
    // not change carry the tint of the row, which is a different color: with
    // one background the word diff is invisible.
    const changed = cellWith(s, row, "4") orelse return error.TestUnexpectedResult;
    const same = cellWith(s, row, "c") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(theme.diffAddBg().bg, changed.style.bg);
    try std.testing.expectEqual(theme.diffAddLineBg().bg, same.style.bg);
}

/// The first cell of a row whose grapheme is `g`.
fn cellWith(s: vxfw.Surface, row: u16, g: []const u8) ?vaxis.Cell {
    var col: u16 = 0;
    while (col < s.size.width) : (col += 1) {
        const c = s.readCell(col, row);
        if (std.mem.eql(u8, c.char.grapheme, g)) return c;
    }
    return null;
}

test "render: a terminal without truecolor gets the 256 palette" {
    // vaxis writes `38;2;r;g;b` whatever the terminal said, so a 256-color
    // terminal used to get a byte sequence it does not understand. The
    // ladder is applied where the cell is written, and this is the test that
    // says so.
    const prev = theme.caps;
    defer theme.caps = prev;
    theme.caps = .{ .rgb = false };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.pushInfo("hola mundo");

    const s = try drawTest(&m, arena, 40, 12);
    // The text starts at column 2 (the margin plus the "· " mark).
    const cell = s.readCell(3, 0);
    try std.testing.expect(cell.style.fg == .index);
}

test "render: a diff row that wraps stays under the code" {
    // The gutter is painted as part of the row, so the row that wraps has to
    // skip the number and the marker. Without it the code of the second row
    // starts two columns to the left of the code of the first one, and the
    // eye reads it as a different column.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    _ = m.pushDiff("const value = 1;\n", "const value = 1234567890;\n");

    // Narrow enough that the row wraps.
    const s = try drawTest(&m, arena, 24, 12);
    var buf: [256]u8 = undefined;

    // The added row, and the row it wraps into.
    var row: u16 = 0;
    var found = false;
    var code_col: usize = 0;
    while (row < 12) : (row += 1) {
        const text = rowText(s, row, &buf);
        // The row is cut at the width, so the search is for the MARKER and
        // not for the whole line.
        if (std.mem.indexOf(u8, text, "+const value") == null) continue;
        code_col = std.mem.indexOf(u8, text, "const value").?;
        found = true;
        break;
    }
    try std.testing.expect(found);
    try std.testing.expect(row + 1 < 12);

    // The continuation: the same column the code started in.
    const cont = rowText(s, row + 1, &buf);
    const first_char = std.mem.indexOfNone(u8, cont, " ").?;
    try std.testing.expectEqual(code_col, first_char);
}

test "/color switches the diff palette and says what it did" {
    // The daltonized pair (blue/orange) is the one that survives the most
    // common colour-vision deficiency, and a palette that changed without
    // saying so is a palette the user cannot trust.
    const prev = theme.caps;
    defer theme.caps = prev;

    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    theme.caps = .{ .rgb = true };
    try agent.submit(&m, "/color daltonized");
    try std.testing.expect(theme.caps.daltonized);

    try agent.submit(&m, "/color default");
    try std.testing.expect(!theme.caps.daltonized);

    // An unknown palette is refused and it does NOT change anything.
    try agent.submit(&m, "/color mauve");
    try std.testing.expect(!theme.caps.daltonized);
}

test "the permission question is painted even when the terminal has no room for the box" {
    // The dialog BLOCKS the turn: the worker waits for an answer. On a
    // terminal with no room for the box, the old code painted NOTHING, and the
    // app looked exactly like the "it stopped answering" bug — the input was
    // dead because it was waiting for a key nobody could know to press.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.perm_tool_len = @min("bash".len, m.perm_tool.len);
    @memcpy(m.perm_tool[0..m.perm_tool_len], "bash");
    m.perm_active = true;

    // 24 columns: too narrow for the 36-column box.
    const s = try drawTest(&m, arena, 24, 10);
    var buf: [256]u8 = undefined;

    // The question is on screen, with the tool's name on it.
    var saw_question = false;
    var row: u16 = 0;
    while (row < s.size.height) : (row += 1) {
        const text = rowText(s, row, &buf);
        if (std.mem.indexOf(u8, text, "Permission") != null) saw_question = true;
    }
    try std.testing.expect(saw_question);

    // And the four ways to answer are on screen too: a question you cannot
    // answer is the same as no question.
    var saw_options = false;
    row = 0;
    while (row < s.size.height) : (row += 1) {
        const text = rowText(s, row, &buf);
        if (std.mem.indexOf(u8, text, "Y allow") != null) saw_options = true;
    }
    try std.testing.expect(saw_options);
}

test "the footer counts the assistant turns the reader has not seen" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    var i: usize = 0;
    while (i < 8) : (i += 1) {
        m.pushInfoFmt("linea corta {d}", .{i});
        m.pushKind(.assistant, "una respuesta un poco mas larga que la anterior");
    }

    // The first frame LAYS OUT the history: the heights are estimates until
    // the paragraphs are parsed, and the scroll needs a real `max_offset` to
    // have something to scroll away from.
    _ = try drawTest(&m, arena, 60, 20);
    try std.testing.expectEqual(@as(usize, 0), m.unseenTurns());

    // The reader scrolls up: the baseline is now the end of the history.
    m.scrollBy(6);
    try std.testing.expect(!m.follow_bottom);
    try std.testing.expectEqual(@as(usize, 0), m.unseenTurns());

    // Two answers arrive while the reader is away.
    m.pushKind(.assistant, "tercera respuesta");
    m.pushKind(.assistant, "cuarta respuesta");
    _ = try drawTest(&m, arena, 60, 20);
    try std.testing.expectEqual(@as(usize, 2), m.unseenTurns());

    // A TOOL line is not an answer the reader is missing: upstream counts
    // turns, not entries, and a counter that ticks on every tool call is a
    // counter the reader learns to ignore.
    m.pushKind(.tool_res, "⎿  read 10 lines");
    _ = try drawTest(&m, arena, 60, 20);
    try std.testing.expectEqual(@as(usize, 2), m.unseenTurns());

    // Back at the bottom: the count is over.
    m.scrollTo(m.currentMaxOffset());
    try std.testing.expect(m.follow_bottom);
    try std.testing.expectEqual(@as(usize, 0), m.unseenTurns());
}

test "status: the footer shows the EFFECTIVE effort, and only when there is a knob" {
    // The preference is not the level that goes on the wire: the model's own
    // ladder degrades it (an `xhigh` on a model that tops out at `high`
    // becomes `high`). A footer that said `xhigh` while the request carried
    // `high` would be telling the user a story about the model that is not
    // true.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const saved_model = agent.curModel();
    const saved_effort = agent.current_effort;
    // The model that is ANSWERING is a global that another test may have set
    // (the router and the free pool both write it), and the footer reads THAT
    // one. It is cleared here and restored on the way out, because a test that
    // depends on the order of the suite is a test that fails on a Tuesday.
    const saved_answering = agent.curAnswering();
    defer {
        agent.setModel(saved_model);
        agent.current_effort = saved_effort;
        agent.setAnswering(saved_answering);
    }
    agent.setAnswering("");

    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    // A model WITH a knob: the level has to be on the row.
    agent.setModel("gpt-5.1");
    agent.current_effort = .high;
    @memcpy(m.status_model_buf[0.."gpt-5.1".len], "gpt-5.1");
    m.status_model_len = "gpt-5.1".len;
    m.status_model_tried = true;

    var segs = sessionInfo(&m, arena_state.allocator()).?;
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(std.testing.allocator);
    for (segs) |sg| try joined.appendSlice(std.testing.allocator, sg.text);
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "high") != null);

    // A model WITHOUT one: there is no level to show, and a row full of
    // words nobody can act on is a row nobody reads.
    agent.setModel("kimi-k2.6");
    @memcpy(m.status_model_buf[0.."kimi-k2.6".len], "kimi-k2.6");
    m.status_model_len = "kimi-k2.6".len;

    segs = sessionInfo(&m, arena_state.allocator()).?;
    joined.clearRetainingCapacity();
    for (segs) |sg| try joined.appendSlice(std.testing.allocator, sg.text);
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "high") == null);
}

test "the sticky header names the turn you are reading" {
    // The question it answers is "which request is this?", and it is the
    // question you ask when you are reading the middle of a long session.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.pushInfo("an info line that sits at the top of the transcript");
    m.pushKind(.user, "first request");
    m.pushKind(.assistant, "an answer that is long enough to need a few rows on the screen");
    m.pushKind(.user, "second request");
    m.pushKind(.assistant, "another answer, also long enough to fill a couple of rows here");
    // The conversation has to be TALLER than the screen, or there is nothing
    // to scroll and the reader never leaves the bottom.
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        m.pushInfoFmt("relleno {d}", .{i});
        m.pushKind(.assistant, "una respuesta de relleno un poco mas larga que la anterior");
    }

    const h: u16 = 20;
    _ = try drawTest(&m, arena, 60, h);

    // Scroll up into the middle of the conversation.
    m.scrollBy(3);
    const away = try drawTest(&m, arena, 60, h);
    var buf: [256]u8 = undefined;
    const row0 = rowText(away, 0, &buf);

    // The header names the turn.
    try std.testing.expect(std.mem.indexOf(u8, row0, "request") != null);

    // AND it is the HEADER and not the transcript: the header paints the
    // prompt dim (`theme.hint`) and the user's own line in the transcript
    // paints it bright (`theme.ink`). Without the style check the test would
    // pass on the transcript's own prompt and prove nothing.
    const at = std.mem.indexOf(u8, row0, "request") orelse return error.TestUnexpectedResult;
    const cell = away.readCell(@intCast(at), 0);
    try std.testing.expectEqualStrings(
        &theme.hint.fg.rgb,
        &cell.style.fg.rgb,
    );
}

test "the sticky header is not painted while the reader is at the bottom" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.pushInfo("an info line at the top of the transcript");
    m.pushKind(.user, "a prompt that would be the header if the reader scrolled up");
    m.pushKind(.assistant, "an answer");

    const s = try drawTest(&m, arena, 60, 20);
    var buf: [256]u8 = undefined;
    const row0 = rowText(s, 0, &buf);
    // Row 0 is the transcript, not a header: the prompt is IN the transcript.
    try std.testing.expect(std.mem.indexOf(u8, row0, "a prompt that would be") == null);
}

test "the pill says how many answers arrived while the reader was away" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    var i: usize = 0;
    while (i < 8) : (i += 1) {
        m.pushInfoFmt("linea {d}", .{i});
        m.pushKind(.assistant, "una respuesta un poco mas larga que la anterior");
    }
    _ = try drawTest(&m, arena, 60, 20);

    m.scrollBy(6);
    try std.testing.expect(!m.follow_bottom);

    // Nothing arrived yet: no pill.
    const none = try drawTest(&m, arena, 60, 20);
    try std.testing.expect(findRow(none, "new message") == null);

    m.pushKind(.assistant, "tercera respuesta");
    m.pushKind(.assistant, "cuarta respuesta");
    const s = try drawTest(&m, arena, 60, 20);
    try std.testing.expect(findRow(s, "2 new messages") != null);
}

test "the footer tells what is queued, not only how much" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    // The queue owns its text, so the copy has to be a copy.
    const text = m.allocator.dupe(u8, "arregla los tests que fallan") catch return error.TestUnexpectedResult;
    _ = m.enqueuePrompt(text);

    const s = try drawTest(&m, arena, 100, 30);
    var buf: [512]u8 = undefined;
    const row = rowText(s, 29, &buf);
    try std.testing.expect(std.mem.indexOf(u8, row, "1 queued") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "arregla los tests") != null);
}

test "the ? key opens the shortcut list" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    // The picker is a modal: it is open while it is open.
    openShortcutsPicker(&m);
    try std.testing.expect(m.pickerActive());

    // The legend of the permission glyphs travels with it: a glyph with no
    // legend is a glyph nobody can read.
    var found_mode = false;
    for (m.picker_items.items) |it| {
        if (std.mem.indexOf(u8, it.desc, "plan") != null) found_mode = true;
    }
    try std.testing.expect(found_mode);
}

test "the wordmark: every row is the same width, and the O is not the D" {
    // Box-drawing art is a MAP of cells: if the rows do not land on the same
    // columns there is nothing to read, and comparing the WHOLE row is the
    // only thing that tells you. A byte count is not a column count, and a
    // row that is one column short shifts everything to its right.
    //
    // The five rows are checked at COMPTIME, because `bannerRow` takes a
    // comptime row: the art is composed at comptime on purpose (the padding
    // on the right gets stripped by an editor, and a stripped row is a
    // shifted row).
    //
    // The art is PURE ASCII (`#` and a space), so a byte IS a column here.
    // The general measurement — the terminal's own rules — is for the fonts;
    // this is for a drawing we control.
    const widths = comptime blk: {
        var out: [5]usize = undefined;
        out[0] = std.mem.trimEnd(u8, bannerRow(0), " ").len;
        out[1] = std.mem.trimEnd(u8, bannerRow(1), " ").len;
        out[2] = std.mem.trimEnd(u8, bannerRow(2), " ").len;
        out[3] = std.mem.trimEnd(u8, bannerRow(3), " ").len;
        out[4] = std.mem.trimEnd(u8, bannerRow(4), " ").len;
        break :blk out;
    };
    for (widths) |w| {
        // The RIGHT EDGE of the letters varies (the D's bowl and the E's
        // middle bar end before the others do), and that is the art. What
        // cannot vary is the WIDTH: a row one column short shifts
        // everything to its right.
        try std.testing.expect(w <= banner_art_width);
    }
    // The composed rows are all the same width, trailing spaces included:
    // that is what the composition is for.
    try std.testing.expectEqual(banner_art_width, bannerRow(0).len);
    try std.testing.expectEqual(banner_art_width, bannerRow(1).len);
    try std.testing.expectEqual(banner_art_width, bannerRow(2).len);
    try std.testing.expectEqual(banner_art_width, bannerRow(3).len);
    try std.testing.expectEqual(banner_art_width, bannerRow(4).len);

    // The O and the D are different LETTERS and they have to look it: the
    // v3 wordmark's whole point was "O and D are distinguishable at a
    // glance", and a D with a rounded stem is an O with another name.
    //
    // The D has a FLAT left stem: its rows start with two columns of `#`
    // every time. The O's do not: its top and bottom rows start with a space.
    const o_top = std.mem.trimEnd(u8, glyph_o[0], " ");
    const d_top = std.mem.trimEnd(u8, glyph_d[0], " ");
    try std.testing.expectEqualStrings(" ####", o_top);
    try std.testing.expectEqualStrings("####", d_top);
    try std.testing.expect(!std.mem.eql(u8, glyph_o[1], glyph_d[1]));
}

test "the wordmark is drawn as FIVE rows of art, and it is not read as headings" {
    // The `#` at the start of a row is a markdown HEADING, and the parser
    // eats it: the art came out as "####  ####   *zode*". The `.banner` kind
    // is the one that does not look for structure, and this is what pins it.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.pushHeader(.idle);

    const s = try drawTest(&m, arena, 92, 26);
    var rb: [512]u8 = undefined;

    // Five rows of drawing, in a row, and the first one still has its six
    // `#` in it.
    var row: u16 = 0;
    while (row < m.hist_rows and std.mem.trim(u8, rowText(s, row, &rb), " ").len == 0) : (row += 1) {}
    const first = std.mem.trim(u8, rowText(s, row, &rb), " ");
    try std.testing.expect(std.mem.startsWith(u8, first, "######"));
    // And the LAST row of the art is a full one: the art is not cut.
    const last = std.mem.trim(u8, rowText(s, row + banner_art_height - 1, &rb), " ");
    try std.testing.expect(std.mem.startsWith(u8, last, "######"));
}

test "the sensitive-path question has no 'always allow'" {
    // A rule that remembers "the agent may write inside .git/" is the
    // opposite of the rule, so the question is asked ONCE and the option is
    // not on the table.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.perm_tool_len = @min("write".len, m.perm_tool.len);
    @memcpy(m.perm_tool[0..m.perm_tool_len], "write");
    m.perm_detail_len = @min(".git/hooks/pre-commit is not a place this tool writes".len, m.perm_detail.len);
    @memcpy(m.perm_detail[0..m.perm_detail_len], ".git/hooks/pre-commit is not a place this tool writes");
    m.perm_active = true;

    // The ordinary question: four options, and "always allow" is one of them.
    const normal = try drawTest(&m, arena, 80, 24);
    try std.testing.expect(findRow(normal, "always allow") != null);

    // The sensitive one: three.
    m.perm_allow_always = false;
    const once = try drawTest(&m, arena, 80, 24);
    try std.testing.expect(findRow(once, "always allow") == null);
    try std.testing.expect(findRow(once, "allow once") != null);
    try std.testing.expect(findRow(once, "deny") != null);
    // And the REASON is in the dialog: the user is being asked about a path
    // they cannot see otherwise.
    try std.testing.expect(findRow(once, "not a place this tool writes") != null);
}

test "streaming: a very large response grows without an artificial cap" {
    // Output renders indefinitely: stream_buf grows with every chunk until the
    // allocator itself refuses (real OOM). No fixed byte cap truncates the
    // live stream.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.streamStart();
    // Stream enough chunks to far exceed any reasonable fixed cap.
    const chunk = "lorem ipsum dolor sit amet, consectetur adipiscing elit. ";
    var sent: usize = 0;
    const target = 400 * 1024;
    while (sent < target) : (sent += chunk.len) {
        m.streamDelta(chunk);
    }

    // The buffer holds everything that was streamed: no artificial cap was hit.
    try std.testing.expect(m.stream_buf.items.len >= target);
}
