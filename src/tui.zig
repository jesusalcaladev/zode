const std = @import("std");
const textcase = @import("lib/textcase.zig");
const builtin = @import("builtin");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const agent = @import("agent.zig");
const chat = @import("chat.zig");
const md = @import("lib/markdown.zig");
const ansi = @import("lib/ansi.zig");
const theme = @import("lib/theme.zig");
const lang_icons = @import("lib/lang_icons.zig");
const filechange = @import("lib/filechange.zig");
const diffhunks = @import("lib/diffhunks.zig");
const ed = @import("lib/editor.zig");
const textcap = @import("lib/textcap.zig");
const sleepz = @import("lib/sleep.zig");
const taskstore = @import("lib/taskstore.zig");
const team_mod = @import("lib/team.zig");
const verifycounts = @import("lib/verifycounts.zig");
const configmenu = @import("lib/configmenu.zig");
const keybinds = @import("lib/keybinds.zig");
const schedule_mod = @import("lib/schedule.zig");
const tick_mod = @import("lib/tick.zig");
const diag_mod = @import("lib/diag.zig");
const palette = @import("palette.zig");
const compaction = @import("compaction.zig");
const plan_mod = @import("lib/plan.zig");
const facts_mod = @import("lib/facts.zig");
const goal_mod = @import("lib/goal.zig");
const checkpoint = @import("lib/checkpoint.zig");
const bgproc = @import("bgproc.zig");
const images_mod = @import("lib/images.zig");
const readcache = @import("lib/readcache.zig");
const subagent_mod = @import("lib/subagent.zig");
const session_mod = @import("session.zig");
const permrules = @import("lib/permrules.zig");
const filesview = @import("lib/filesview.zig");
const bench_mod = @import("lib/bench.zig");
const cache_stats = @import("cache_stats.zig");
const models_mod = @import("lib/models.zig");
const modelcache = @import("lib/modelcache.zig");
const zjsonl = @import("lib/zjsonl.zig");
const copytext = @import("lib/copytext.zig");
const fuzzy = @import("lib/fuzzy.zig");
const filesearch = @import("lib/filesearch.zig");
const mascot = @import("lib/mascot.zig");
const sessionindex = @import("lib/sessionindex.zig");
const session_search = @import("lib/session_search.zig");
const commands = @import("commands.zig");
const repeat = @import("lib/repeat.zig");

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

/// 33.9: transient notifications channel (absolutely positioned, no layout shift).
pub const Notification = struct {
    text: [160]u8 = undefined,
    len: usize = 0,
    frames: u64 = 0,

    pub fn slice(self: *const Notification) []const u8 {
        return self.text[0..self.len];
    }
};

pub const max_notifications: usize = 4;

/// Phase 5 workbench view mode (presentation layer only).
/// Must not change agent/session/permission/tool runtime behavior.
pub const ViewMode = enum {
    normal,
    focus,
    flow,
    review,

    pub fn name(self: ViewMode) []const u8 {
        return switch (self) {
            .normal => "normal",
            .focus => "focus",
            .flow => "flow",
            .review => "review",
        };
    }

    pub fn desc(self: ViewMode) []const u8 {
        return switch (self) {
            .normal => "default presentation",
            .focus => "reduced chrome/metadata (presentation only)",
            .flow => "conversation/streaming emphasis (presentation only)",
            .review => "diff/file/review emphasis (presentation only)",
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
pub const glyph_o = [_][]const u8{
    " #### ",
    "##  ##",
    "##  ##",
    "##  ##",
    " #### ",
};
pub const glyph_d = [_][]const u8{
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
pub fn bannerRow(comptime r: usize) []const u8 {
    comptime var out: []const u8 = "";
    inline for (wordmark, 0..) |letter, i| {
        if (i > 0) out = out ++ " ";
        if (i + 1 < wordmark.len) {
            const missing = letter.w - letter.rows[r].len;
            const filler = repeat.rep(" ", missing);
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
    semantic_searching: bool = false,
    semantic_mode: bool = false,
    preview: bool = false,
    /// Preview lines: first byte is kind prefix (U/A/T/E/D/I), rest is text.
    preview_lines: []const []const u8 = &.{},
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

/// True when a grapheme is a raw control byte (C0, DEL, or a C1 byte in
/// UTF-8). Those never belong in a cell: vaxis writes cell bytes raw, so
/// they come out as broken frames instead of text.
pub fn isControlGrapheme(g: []const u8) bool {
    if (g.len == 0) return false;
    const b = g[0];
    if (b < 0x20 or b == 0x7f) return true;
    // UTF-8 lead byte of a C1 control (U+0080..U+009F = 0xC2 0x80..0x9F).
    if (b == 0xc2 and g.len >= 2 and g[1] >= 0x80 and g[1] <= 0x9f) return true;
    return false;
}

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
        self.putStableLinked(col, row, g, w, style, .{});
    }

    /// Like `putStable`, but with an OSC 8 hyperlink.
    pub fn putStableLinked(self: *Painter, col: u16, row: u16, g: []const u8, w: u8, style: vaxis.Style, link: vaxis.Cell.Hyperlink) void {
        // A control byte must NEVER reach a cell: vaxis emits grapheme bytes
        // raw, so a `\r`, `\n`, ESC or DEL from tool output or streamed text
        // breaks the frame (interleaved text, weird glyphs, broken layout).
        // The width measured it as 1, so it slipped past the clipping below.
        // Render it as a visible replacement instead of dropping it silently.
        if (isControlGrapheme(g)) {
            self.putStableLinked(col, row, "\u{fffd}", 1, style, link);
            return;
        }
        if (col >= self.width or row >= self.height or col + w > self.width) return;
        self.surface.writeCell(col, row, .{
            .char = .{ .grapheme = g, .width = w },
            // THE LADDER, in the one place a cell is written: a color the
            // terminal cannot show never reaches the wire. vaxis does not
            // convert rgb→256 (it sends `38;2;r;g;b` whatever the terminal
            // said), so a 256-color terminal got a byte sequence it does not
            // understand, and what it did with it was undefined.
            .style = theme.resolve(style),
            .link = link,
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
    link: vaxis.Cell.Hyperlink = .{},
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

/// Large code blocks are previewed in the rendered transcript for readability.
/// The full content remains in the message/session (honest fallback). When a
/// generic per-block expand state is added, this becomes the default collapsed
/// size; until then, the preview is stable and non-destructive.
pub const code_preview_lines = 80;
pub const code_preview_head = 50;
pub const code_preview_tail = 20;

const max_net_baselines: usize = 64;
const max_net_baseline_file: usize = 256 * 1024;
const max_net_baseline_total: usize = 1024 * 1024;

const NetBaseline = struct {
    path: [filesview.path_max]u8 = undefined,
    path_len: u16 = 0,
    baseline: ?[]u8 = null,
    /// Latest honest net diff stats from `baseline` to the most recent `after`.
    /// Valid once `has_stats` is set; sourced from real diffs only.
    net_added: usize = 0,
    net_removed: usize = 0,
    has_stats: bool = false,
};

const max_file_intel: usize = 128;

/// One file-change event in the timeline (file intelligence): structured state
/// for focus/actions/navigation. Backed by real diff stats and paragraph indices.
pub const FileIntelEntry = struct {
    path: [filesview.path_max]u8 = @splat(0),
    path_len: u16 = 0,
    diff_para: ?usize = null,
    added: u32 = 0,
    removed: u32 = 0,
    is_net: bool = false,
    op: filechange.Operation = .modified,

    pub fn pathOf(self: *const FileIntelEntry) []const u8 {
        return self.path[0..self.path_len];
    }
};

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
    nerd_icons: bool,
) ![]const PLine {
    return buildLinesBase(pa, ctx, para, width, nerd_icons);
}

fn appendTextRun(
    pa: std.mem.Allocator,
    ctx: vxfw.DrawContext,
    cells: *std.ArrayList(CellRun),
    text: []const u8,
    style: vaxis.Style,
    remaining: *u16,
) !void {
    var it = vaxis.unicode.graphemeIterator(text);
    while (it.next()) |g| {
        const b = g.bytes(text);
        const gw = theme.graphemeWidth(ctx, b);
        if (remaining.* < gw) return;
        remaining.* -= gw;
        try cells.append(pa, .{ .text = b, .w = gw, .style = style });
    }
}

/// Optional language chip row: `│ ` + [icon + space] + label + padding + ` │`.
/// The icon comes from Nerd Fonts when enabled; the label is always shown.
fn appendLangChipLine(
    pa: std.mem.Allocator,
    ctx: vxfw.DrawContext,
    lines: *std.ArrayList(PLine),
    raw_lang: []const u8,
    box_w: u16,
    nerd_icons: bool,
) !void {
    const chip = lang_icons.lookup(raw_lang, nerd_icons);
    if (chip.label.len == 0) return;

    var cells: std.ArrayList(CellRun) = .empty;
    try cells.append(pa, .{ .text = "\u{2502} ", .w = 2, .style = theme.code_border }); // │

    // Budget inside the box: left `│ ` (2) + content + right ` │` (2).
    var remaining: u16 = box_w -| 4;
    if (chip.icon) |icon| {
        try appendTextRun(pa, ctx, &cells, icon, theme.code_lang, &remaining);
        if (remaining > 0) {
            try cells.append(pa, .{ .text = " ", .w = 1, .style = theme.code_lang });
            remaining -= 1;
        }
    } else {
        try cells.append(pa, .{ .text = "\u{259A} ", .w = 2, .style = theme.code_lang }); // ▚  (fallback marker)
        remaining -|= 2;
    }
    try appendTextRun(pa, ctx, &cells, chip.label, theme.code_lang, &remaining);

    // Pad to align the closing border with code rows: `│ ` + content + pad + ` │` = box_w.
    while (remaining > 0) : (remaining -= 1) {
        try cells.append(pa, .{ .text = " ", .w = 1, .style = theme.code_bg });
    }
    try cells.append(pa, .{ .text = " \u{2502}", .w = 2, .style = theme.code_border }); //  │
    try lines.append(pa, .{ .cells = cells.items, .w = box_w });
}

const LinkSpan = struct {
    start: usize,
    end: usize,
    uri: []const u8,
};

fn isLinkChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or switch (c) {
        '-', '_', '.', '~', '/', ':', '?', '#', '[', ']', '@', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '%', '=', '\\' => true,
        else => false,
    };
}

fn trimLinkEnd(text: []const u8, start: usize, end: usize) usize {
    var e = end;
    while (e > start) {
        const c = text[e - 1];
        if (c == '.' or c == ',' or c == ';' or c == ':' or c == '!' or c == '?' or c == ')' or c == ']' or c == '\'' or c == '"' or c == '>') {
            e -= 1;
            continue;
        }
        break;
    }
    return e;
}

fn isPathTokenChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or switch (c) {
        '/', '.', '_', '-', '~', ':', '@', '+', '%' => true,
        else => false,
    };
}

pub fn detectLinks(pa: std.mem.Allocator, text: []const u8) []const LinkSpan {
    var out: std.ArrayList(LinkSpan) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const at_token_start = i == 0 or std.ascii.isWhitespace(text[i - 1]) or switch (text[i - 1]) {
            '(', '[', '{', '"', '\'', '`', '<', '=', ',', ';' => true,
            else => false,
        };
        const rest = text[i..];
        if (at_token_start and (std.mem.startsWith(u8, rest, "https://") or std.mem.startsWith(u8, rest, "http://"))) {
            var e = i;
            while (e < text.len and isLinkChar(text[e]) and text[e] != '<' and text[e] != '>' and text[e] != '"') : (e += 1) {}
            e = trimLinkEnd(text, i, e);
            if (e > i + 8) {
                const uri = pa.dupe(u8, text[i..e]) catch text[i..e];
                out.append(pa, .{ .start = i, .end = e, .uri = uri }) catch {};
                i = e;
                continue;
            }
        }
        if (at_token_start and isPathTokenChar(text[i])) {
            var e = i;
            var has_slash = false;
            var dots_only = true;
            while (e < text.len and isPathTokenChar(text[e])) : (e += 1) {
                if (text[e] == '/') has_slash = true;
                if (text[e] != '.' and text[e] != '/') dots_only = false;
            }
            e = trimLinkEnd(text, i, e);
            const token = text[i..e];
            const path_like = has_slash and !dots_only and token.len > 1;
            if (path_like) {
                const uri = if (std.mem.startsWith(u8, token, "/"))
                    (std.fmt.allocPrint(pa, "file://{s}", .{token}) catch token)
                else
                    (std.fmt.allocPrint(pa, "file:{s}", .{token}) catch token);
                out.append(pa, .{ .start = i, .end = e, .uri = uri }) catch {};
                i = e;
                continue;
            }
        }
        i += 1;
    }
    return out.items;
}

fn linkForOffset(spans: []const LinkSpan, off: usize) ?[]const u8 {
    for (spans) |s| {
        if (off >= s.start and off < s.end) return s.uri;
    }
    return null;
}

/// Builds the lines of a code block with a full rounded border.
///
/// The block gets:
///   - a top border `╭─────╮`
///   - an optional language chip with a background
///   - each line wrapped in `│ … │`
///   - optional line numbers (when useful, for multi-line blocks)
///   - a bottom border `╰─────╯`
///
/// All memory comes out of `pa`.
fn buildCodeBlockLines(
    pa: std.mem.Allocator,
    ctx: vxfw.DrawContext,
    blk: anytype,
    width: u16,
    nerd_icons: bool,
) ![]const PLine {
    // ── first pass: build every line's cells and find the max width ─────────
    var raw_lines: std.ArrayList([]const CellRun) = .empty;
    var max_w: usize = 0;
    for (blk.lines) |src| {
        var cells: std.ArrayList(CellRun) = .empty;
        // Display COLUMNS, not grapheme count: one full-width glyph used to
        // shift the whole right border a column left of where it is painted.
        var ln_w: usize = 0;
        for (src) |seg| {
            const spans = detectLinks(pa, seg.text);
            var it = vaxis.unicode.graphemeIterator(seg.text);
            while (it.next()) |g| {
                const b = g.bytes(seg.text);
                const off: usize = @intFromPtr(b.ptr) - @intFromPtr(seg.text.ptr);
                const uri = linkForOffset(spans, off);
                const gw = theme.graphemeWidth(ctx, b);
                try cells.append(pa, .{
                    .text = b,
                    .w = gw,
                    .style = seg.style,
                    .link = if (uri) |u| .{ .uri = u } else .{},
                });
                ln_w += gw;
            }
        }
        try raw_lines.append(pa, cells.items);
        if (ln_w > max_w) max_w = ln_w;
    }

    // Line numbers: useful for multi-line code blocks. Continuation rows from
    // wrapping keep gutter space without repeating the number.
    const show_line_numbers = blk.lines.len > 1;
    const line_no_width: u16 = if (!show_line_numbers) 0 else blk: {
        var n = blk.lines.len;
        var digits: u16 = 1;
        while (n >= 10) : (n /= 10) digits += 1;
        break :blk digits + 1; // right-aligned number field + trailing space
    };

    // Inner width: code text + left gutter `│ ` + optional line-number gutter
    // + right gutter ` │`. A line wider than that WRAPS inside the box, so
    // `max_w` sizes the box but never pushes it past the terminal.
    const inner_w: u16 = @intCast(@min(max_w, std.math.maxInt(u16)));
    const desired = inner_w + 4 + line_no_width;
    const box_w: u16 = @min(desired, width);
    const text_w: u16 = box_w -| (4 + line_no_width);

    var lines: std.ArrayList(PLine) = .empty;

    // ── top border ──────────────────────────────────────────────────────────
    {
        var cells: std.ArrayList(CellRun) = .empty;
        try cells.append(pa, .{ .text = "╭", .w = 1, .style = theme.code_border });
        var i: u16 = 1;
        while (i < box_w -| 1) : (i += 1) {
            try cells.append(pa, .{ .text = "─", .w = 1, .style = theme.code_border });
        }
        try cells.append(pa, .{ .text = "╮", .w = 1, .style = theme.code_border });
        try lines.append(pa, .{ .cells = cells.items, .w = box_w });
    }

    // ── language chip with background ───────────────────────────────────────
    try appendLangChipLine(pa, ctx, &lines, blk.lang, box_w, nerd_icons);

    // ── code lines, wrapped to `text_w` columns inside the box ──────────────
    // Large blocks show head+tail preview with an honest omission notice; full
    // content remains in the session/message (no data loss).
    const total_lines = raw_lines.items.len;
    const truncated = total_lines > code_preview_lines;
    const head_n: usize = if (truncated) @min(code_preview_head, total_lines) else total_lines;
    const tail_n: usize = if (truncated) @min(code_preview_tail, total_lines - head_n) else 0;
    const hidden_lines: usize = if (truncated) total_lines - head_n - tail_n else 0;

    const RenderCodeLine = struct {
        fn run(
            pa_: std.mem.Allocator,
            out_lines: *std.ArrayList(PLine),
            src: []const CellRun,
            line_no: usize,
            show_nums: bool,
            line_no_w: u16,
            text_w_: u16,
            box_w_: u16,
        ) !void {
            var i: usize = 0;
            var first_chunk = true;
            while (true) {
                var out: std.ArrayList(CellRun) = .empty;
                try out.append(pa_, .{ .text = "│ ", .w = 2, .style = theme.code_border });
                if (show_nums) {
                    if (first_chunk) {
                        var num_buf: [16]u8 = undefined;
                        const num_field_w: u16 = line_no_w -| 1;
                        const num_text = std.mem.print(&num_buf, "{d}", .{line_no}) catch "?";
                        const num_cols: u16 = @intCast(@min(num_text.len, num_field_w));
                        var pad_n: u16 = num_field_w -| num_cols;
                        while (pad_n > 0) : (pad_n -= 1) {
                            try out.append(pa_, .{ .text = " ", .w = 1, .style = theme.diff_gutter });
                        }
                        const num_owned = try pa_.dupe(u8, num_text);
                        var ni: usize = 0;
                        while (ni < num_owned.len and ni < num_cols) : (ni += 1) {
                            try out.append(pa_, .{ .text = num_owned[ni .. ni + 1], .w = 1, .style = theme.diff_gutter });
                        }
                        try out.append(pa_, .{ .text = " ", .w = 1, .style = theme.diff_gutter });
                    } else {
                        var pad_n: u16 = line_no_w;
                        while (pad_n > 0) : (pad_n -= 1) {
                            try out.append(pa_, .{ .text = " ", .w = 1, .style = theme.diff_gutter });
                        }
                    }
                }
                var used: u16 = 0;
                while (i < src.len) : (i += 1) {
                    const c = src[i];
                    if (used + c.w > text_w_) break;
                    var st = c.style;
                    st.bg = theme.code_bg.bg;
                    try out.append(pa_, .{ .text = c.text, .w = c.w, .style = st });
                    used += c.w;
                }
                if (text_w_ == 0) i = src.len;
                var pad: u16 = text_w_ -| used;
                while (pad > 0) : (pad -= 1) {
                    try out.append(pa_, .{ .text = " ", .w = 1, .style = theme.code_bg });
                }
                try out.append(pa_, .{ .text = " │", .w = 2, .style = theme.code_border });
                try out_lines.append(pa_, .{ .cells = out.items, .w = box_w_ });
                first_chunk = false;
                if (i >= src.len) break;
            }
        }
    };

    for (raw_lines.items[0..head_n], 0..) |src, line_idx| {
        try RenderCodeLine.run(pa, &lines, src, line_idx + 1, show_line_numbers, line_no_width, text_w, box_w);
    }

    if (truncated) {
        var notice_buf: [176]u8 = undefined;
        const notice = if (tail_n > 0)
            (std.mem.print(
                &notice_buf,
                "… {d} lines omitted (preview; full content preserved in session)",
                .{hidden_lines},
            ) catch "… preview omitted (full content preserved in session)")
        else
            (std.mem.print(
                &notice_buf,
                "… +{d} more lines (preview; full content preserved in session)",
                .{hidden_lines},
            ) catch "… preview truncated (full content preserved in session)");
        var out: std.ArrayList(CellRun) = .empty;
        try out.append(pa, .{ .text = "│ ", .w = 2, .style = theme.code_border });
        if (show_line_numbers) {
            var pad_n: u16 = line_no_width;
            while (pad_n > 0) : (pad_n -= 1) {
                try out.append(pa, .{ .text = " ", .w = 1, .style = theme.diff_gutter });
            }
        }
        var used: u16 = 0;
        var itn = vaxis.unicode.graphemeIterator(notice);
        while (itn.next()) |g| {
            const b = g.bytes(notice);
            const gw = theme.graphemeWidth(ctx, b);
            if (used + gw > text_w) break;
            const owned_b = try pa.dupe(u8, b);
            try out.append(pa, .{ .text = owned_b, .w = gw, .style = theme.ink3 });
            used += gw;
        }
        var pad: u16 = text_w -| used;
        while (pad > 0) : (pad -= 1) {
            try out.append(pa, .{ .text = " ", .w = 1, .style = theme.code_bg });
        }
        try out.append(pa, .{ .text = " │", .w = 2, .style = theme.code_border });
        try lines.append(pa, .{ .cells = out.items, .w = box_w });

        if (tail_n > 0) {
            const tail_start = total_lines - tail_n;
            for (raw_lines.items[tail_start..], 0..) |src, j| {
                try RenderCodeLine.run(pa, &lines, src, tail_start + j + 1, show_line_numbers, line_no_width, text_w, box_w);
            }
        }
    }

    // ── bottom border ───────────────────────────────────────────────────────
    {
        var cells: std.ArrayList(CellRun) = .empty;
        try cells.append(pa, .{ .text = "╰", .w = 1, .style = theme.code_border });
        var i: u16 = 1;
        while (i < box_w -| 1) : (i += 1) {
            try cells.append(pa, .{ .text = "─", .w = 1, .style = theme.code_border });
        }
        try cells.append(pa, .{ .text = "╯", .w = 1, .style = theme.code_border });
        try lines.append(pa, .{ .cells = cells.items, .w = box_w });
    }

    return lines.items;
}

/// Same box as `buildCodeBlockLines` (rounded borders, language chip,
/// `│ … │` cell padding) but for **diff** paragraphs. The diff's own per-line
/// styles (added / removed / context / hunk) are preserved — nothing is
/// overwritten with `code_bg` — so the colours the user already sees inside
/// the diff now live inside the same rounded box that code blocks get.
fn buildDiffBlockLines(
    pa: std.mem.Allocator,
    ctx: vxfw.DrawContext,
    blk: anytype,
    width: u16,
    nerd_icons: bool,
) ![]const PLine {
    // ── first pass: build every line's cells and find the max width ─────────
    var raw_lines: std.ArrayList([]const CellRun) = .empty;
    var max_w: usize = 0;
    for (blk.lines) |src| {
        var cells: std.ArrayList(CellRun) = .empty;
        var ln_w: usize = 0;
        for (src) |seg| {
            const spans = detectLinks(pa, seg.text);
            var it = vaxis.unicode.graphemeIterator(seg.text);
            while (it.next()) |g| {
                const b = g.bytes(seg.text);
                const off: usize = @intFromPtr(b.ptr) - @intFromPtr(seg.text.ptr);
                const uri = linkForOffset(spans, off);
                const gw = theme.graphemeWidth(ctx, b);
                try cells.append(pa, .{
                    .text = b,
                    .w = gw,
                    .style = seg.style,
                    .link = if (uri) |u| .{ .uri = u } else .{},
                });
                ln_w += gw;
            }
        }
        try raw_lines.append(pa, cells.items);
        if (ln_w > max_w) max_w = ln_w;
    }

    const inner_w: u16 = @intCast(@min(max_w, std.math.maxInt(u16)));
    const box_w: u16 = @min(inner_w + 4, width);
    const text_w: u16 = box_w -| 4;

    var lines: std.ArrayList(PLine) = .empty;

    // ── top border ──────────────────────────────────────────────────────────
    {
        var cells: std.ArrayList(CellRun) = .empty;
        try cells.append(pa, .{ .text = "╭", .w = 1, .style = theme.code_border });
        var i: u16 = 1;
        while (i < box_w -| 1) : (i += 1) {
            try cells.append(pa, .{ .text = "─", .w = 1, .style = theme.code_border });
        }
        try cells.append(pa, .{ .text = "╮", .w = 1, .style = theme.code_border });
        try lines.append(pa, .{ .cells = cells.items, .w = box_w });
    }

    // ── language chip with background ───────────────────────────────────────
    try appendLangChipLine(pa, ctx, &lines, blk.lang, box_w, nerd_icons);

    // ── diff lines, wrapped to `text_w` columns inside the box ──────────────
    for (raw_lines.items) |src| {
        var i: usize = 0;
        while (true) {
            var out: std.ArrayList(CellRun) = .empty;
            try out.append(pa, .{ .text = "│ ", .w = 2, .style = theme.code_border });
            var used: u16 = 0;
            while (i < src.len) : (i += 1) {
                const c = src[i];
                if (used + c.w > text_w) break;
                // Preserve the diff's own style (fg/bg). Do NOT overwrite with
                // code_bg — an added line keeps its green band, a removed line
                // its red band, context stays untinted.
                try out.append(pa, .{ .text = c.text, .w = c.w, .style = c.style });
                used += c.w;
            }
            if (text_w == 0) i = src.len;
            var pad: u16 = text_w -| used;
            while (pad > 0) : (pad -= 1) {
                try out.append(pa, .{ .text = " ", .w = 1, .style = theme.code_bg });
            }
            try out.append(pa, .{ .text = " │", .w = 2, .style = theme.code_border });
            try lines.append(pa, .{ .cells = out.items, .w = box_w });
            if (i >= src.len) break;
        }
    }

    // ── bottom border ───────────────────────────────────────────────────────
    {
        var cells: std.ArrayList(CellRun) = .empty;
        try cells.append(pa, .{ .text = "╰", .w = 1, .style = theme.code_border });
        var i: u16 = 1;
        while (i < box_w -| 1) : (i += 1) {
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
    nerd_icons: bool,
) ![]const PLine {
    // The width goes to the parser so a TABLE knows how much room it has: a
    // table that does not fit is degraded into `name: value` rows, and that
    // decision can only be made with the width in hand.
    //
    // The two columns are the paragraph's prefix ("› "), which lands on the
    // first line: a table that OPENS a paragraph would otherwise be two
    // columns wider than the terminal and the TUI would wrap the box.
    //
    // The text is sanitized ONCE, here, before the parser ever sees it: every
    // paragraph (streamed model output, tool output, diffs, shell lines) goes
    // through this function, and an ANSI sequence in it used to paint as
    // literal `[31m` next to a control glyph — the "caracteres raros" and the
    // broken layout. `ansi.strip` is the only thing that removes a WHOLE
    // sequence (parameters and tail), which the painter's control-byte
    // backstop cannot do.
    const clean_text = ansi.strip(pa, para.text) catch para.text;
    const blocks = try md.parseLang(pa, para.kind, clean_text, para.base, para.mood, para.lang, .{
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
            const code_lines = try buildCodeBlockLines(pa, ctx, blk, width, nerd_icons);
            for (code_lines) |ln| try lines.append(pa, ln);
            continue;
        }

        if (blk.kind == .diff) {
            // A diff block gets the SAME rounded box as a code block: top /
            // bottom borders, optional language chip, `│ … │` padding. The
            // diff's own per-line colours (green add / red del / grey context)
            // are preserved inside the box.
            const diff_lines = try buildDiffBlockLines(pa, ctx, blk, width, nerd_icons);
            for (diff_lines) |ln| try lines.append(pa, ln);
            continue;
        }

        // ── prose / table (unchanged) ───────────────────────────────────────
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
                const spans = detectLinks(pa, seg.text);
                var it = vaxis.unicode.graphemeIterator(seg.text);
                while (it.next()) |g| {
                    const b = g.bytes(seg.text);
                    const off: usize = @intFromPtr(b.ptr) - @intFromPtr(seg.text.ptr);
                    const uri = linkForOffset(spans, off);
                    try cells.append(pa, .{
                        .text = b,
                        .w = theme.graphemeWidth(ctx, b),
                        .style = seg.style,
                        .link = if (uri) |u| .{ .uri = u } else .{},
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

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return textcase.contains(haystack, needle);
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

/// Turn context preserved across the prompt queue. `text` is owned by the
/// queue (freed on take/clear/deinit); the other fields are value types or
/// static slices with turn/command lifetime.
pub const QueuedTurn = struct {
    text: []u8,
    mode: agent.ChatJob.Mode = .normal,
    bash_allow_rules: []const []const u8 = &.{},
    expand_cmdsubst: bool = false,
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

    /// Nerd Font language icons in code block chips (`ZODE_NERD_ICONS`). Default
    /// enabled (`auto`): the language label is always shown, so a missing font
    /// degrades to a replacement glyph plus a readable label.
    nerd_icons: bool = true,

    /// Interactive Settings screen (the Claude-Code-style internal config).
    /// A full-screen two-column surface, deliberately NOT the generic picker —
    /// that one is used by Ctrl+P / model selection and looking alike was the
    /// source of the "is this the model picker again?" confusion.
    settings_active: bool = false,
    settings_section: usize = 0,
    settings_row: usize = 0,
    /// 0 = section column, 1 = value rows. Tab switches.
    settings_col: u8 = 0,

    /// Whether the terminal window currently has focus. `true` at startup;
    /// `focus_in`/`focus_out` from vaxis flip it, and the composer's caret is
    /// dimmed while it is `false` so the reader sees at a glance that typing
    /// here does nothing until the window is focused again.
    focused: bool = true,

    /// Own input: `vxfw.TextField` is single-line and has no history, so the
    /// prompt is edited with `editor.Editor`.
    ed: ed.Editor,

    /// User keybindings (Phase 13.3), owned by the config arena. Resolved
    /// before the composer sees a key, so a binding can call any slash command.
    keybindings: []const keybinds.Binding = &.{},
    /// Vim-like modal editing for the input (Phase 13/35.13): `/vim` toggles.
    /// When enabled, starts in insert mode; Esc enters normal mode.
    vim_mode: bool = false,
    vim_normal: bool = false,
    /// Pending vim operator/key (e.g. 'd', 'g') in normal mode.
    vim_pending: u8 = 0,

    /// Additional directories added via `/add-dir` (35.13). Owned strings.
    extra_dirs: std.ArrayList([]u8) = .empty,

    /// Transient "input too long" note: an edit was rejected because it would
    /// exceed `ed.max_bytes`. The message names the limit; it is painted inside
    /// the composer zone (the affected zone) by `drawInput` and cleared on the
    /// next keystroke. The buffer itself is never touched by a rejected edit
    /// and no UTF-8 grapheme is ever split.
    input_err_buf: [160]u8 = undefined,
    input_err: []const u8 = "",
    input_too_long: bool = false,

    /// Bracketed-paste aggregation.
    ///
    /// vaxis forwards `paste_start`/`paste_end` as boundary markers and parses
    /// everything between them as ordinary key events. Without aggregation a
    /// 40-line paste submits 40 prompts: every Enter inside the paste reaches
    /// `submitInput` like a real keypress, each line echoes as its own `›`
    /// paragraph and queues behind the worker the first line started. While
    /// `pasting` is set, key events accumulate in `paste_buf` and go into the
    /// editor in one insert when the paste ends.
    pasting: bool = false,
    paste_buf: std.ArrayList(u8) = .empty,

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
    /// no way to tell whether it was working. Now they are queued and the UI
    /// tick starts them as soon as no turn is in flight.
    ///
    /// Each queued item carries its full turn context (mode, scoped bash allow
    /// rules, cmdsubst expansion). Losing that context on queue/dequeue is a
    /// context leak: a queued `/commit`/`/pr` or pipeline turn would run as a
    /// plain normal turn without its allowlist or substitutions. The rules are
    /// static slices (turn lifetime); only `text` is owned and freed.
    queue: std.ArrayList(QueuedTurn) = .empty,

    /// The visible plan (the `todo` tool). The worker writes it from another
    /// thread and the draw reads it every frame, so it lives under the SAME lock
    /// as the rest.
    ///
    /// It is not an `ArrayList`: the list is a fixed-size array (see `plan.zig`),
    /// so the draw paints it without allocating.
    plan: plan_mod.Plan = .{},
    /// Verified facts for the session (`lib/facts.zig`). Written by the worker
    /// (typecheck verdicts, poll invalidation), read by the turn loop, same
    /// lock as `plan`. Not drawn: the `[Facts]` block is context, not UI.
    facts: facts_mod.Store = .{},
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
    /// ESC stopped the turn in flight. The face says `warn` until the next turn
    /// starts: a cancelled harness did not finish, and `done` would be a lie.
    cancelled: bool = false,
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
    /// ZODE_CRASH_TEST: panic inside the draw path (alt screen active), to
    /// exercise the panic handler with something real to restore.
    crash_test: bool = false,
    /// No tools for the rest of this turn: used by the ceiling turn, where
    /// the model is asked for its final word with every tool removed from
    /// the schema.
    deny_all_tools: bool = false,
    /// Which pipeline stage is active right now: "explorer", "investigator",
    /// "implementer", "tester", "reviewer", or null when not in a pipeline.
    /// Zo paints this so the user always knows what the harness is doing.
    pipeline_stage: ?[]const u8 = null,
    /// Phase 32: three-way verify counts from a verify-role subagent report.
    /// Painted in the activity strip as "N found · N verified" (refuted hidden
    /// at zero). Empty counts read as "setting up", never "0 findings".
    verify_counts: verifycounts.Counts = .{},
    verify_phase: verifycounts.Phase = .setting_up,
    verify_counter: verifycounts.Counter = .{},
    /// How many times the harness has nudged the model to implement instead of
    // just exploring. Reset each turn; bounded to avoid endless nudges.
    implementation_nudges: u8 = 0,
    /// How many times the harness has nudged the model after an empty reply.
    // Reset each turn; bounded to avoid endless nudges.
    empty_reply_nudges: u8 = 0,
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
    /// Show the prompt rail dots (the right-margin timeline): click a dot to
    /// jump back to that prompt.
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
    /// Active hunk selection for the last diff (UI navigation, Phase 3).
    hunk_nav_para: ?usize = null,
    hunk_nav_idx: ?usize = null,

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

    /// Phase 4 (Zode Motion): motion accessibility/performance controls.
    /// `no_animation` disables decorative/continuous motion and renders final
    /// states immediately. `reduced_motion` keeps essential status changes but
    /// avoids continuous motion (e.g. mascot lean/jitter loops). Correctness
    /// and responsiveness take priority over motion.
    reduced_motion: bool = false,
    no_animation: bool = false,
    motion_tick_count: u64 = 0,
    mascot_motion_repaints: u64 = 0,

    /// Phase 5 (Workbench): presentation-only workspace view mode.
    /// This is a UI layer over shared runtime state; it must not change agent,
    /// session, permission, or tool execution behavior.
    view_mode: ViewMode = .normal,

    /// Permission dialog (fixed buffers, no churn between threads).
    perm_tool: [64]u8 = undefined,
    perm_tool_len: usize = 0,
    perm_detail: [384]u8 = undefined,
    perm_detail_len: usize = 0,
    perm_active: bool = false,
    /// The rule that matched and caused this permission question.
    ///
    /// Shown as its own line in the dialog so the user sees WHY they are
    /// being asked ("your rule `Write(.git/**) deny` blocks this"), not just
    /// a blind "may I run this?".
    perm_rule: [128]u8 = undefined,
    perm_rule_len: usize = 0,
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
    /// Whether the open dialog offers "run in sandbox" (Phase 25).
    ///
    /// True for a flagged `bash` command when a sandbox (bwrap/firejail) is
    /// installed: the sandbox is a real alternative to running with full
    /// permissions, so the dialog is not the only answer.
    perm_sandbox_available: bool = false,
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
    /// Images the USER staged for the message being typed (Ctrl+V off the
    /// clipboard). They move to `pending_images` at submit and die with a
    /// Ctrl+C'd draft: a staged image belongs to the text it was pasted next
    /// to, and the two must never disagree about what is being sent.
    draft_images: images_mod.Pending = .{},
    /// The automatic typecheck the harness starts after a write tool touches code.
    ///
    /// It is a struct and not three fields because the headless runner keeps one on
    /// its stack (`agent.AutoCheck`), and the automatic check used to exist only here
    /// — so `zode --chat`, the runner every pty test and measurement drives, edited
    /// code and never compiled it. One implementation, two owners.
    auto_check: agent.AutoCheck = .{},
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
    /// File paths that already emitted a compact card in the current turn.
    turn_file_cards: filesview.Changed = .{},
    /// Last file path that produced a file-diff card/change event (session-scoped).
    /// Used by explicit file navigation/copy actions (no rendered-string parsing).
    last_changed_file: [filesview.path_max]u8 = undefined,
    last_changed_file_len: u16 = 0,
    /// File intelligence timeline: structured file-change entries (card + diff)
    /// for focus/actions/navigation. Runtime-owned; never inferred from rendered UI.
    file_intel: [max_file_intel]FileIntelEntry = @splat(.{}),
    file_intel_len: usize = 0,
    file_focus: ?usize = null,
    /// Turn-scoped baseline content for honest net diffs: first edit stores the
    /// "before" content, subsequent edits diff against that baseline.
    net_baselines: [max_net_baselines]NetBaseline = @splat(.{}),
    net_baselines_len: usize = 0,
    net_baselines_bytes: usize = 0,
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
    /// The active team (Phase 20). Team equals TaskList: the roster and
    /// mailboxes live here, while the shared work list is `tasks` above.
    team: team_mod.Team = .{ .gpa = std.heap.page_allocator },
    /// Phase 19: recurring prompts for this project (sidecar next to the
    /// session) and the periodic-tick state (off by default).
    schedule_store: schedule_mod.Store = .{},
    tick_state: tick_mod.State = .{},
    /// Bench counters for `/bench`.
    bench: bench_mod.Stats = .{},
    /// Phase 37: recent /proc memory samples for leak detection. Fixed ring,
    /// no allocator, so the UI thread can read while a worker pushes.
    diag_monitor: diag_mod.Monitor = .{},
    diag_seq: usize = 0,

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
    /// Scope for the session/resume picker (29.4): .project = this project (default),
    /// .all = all projects under the sessions dir, .branch = this git branch when known.
    session_picker_scope: enum { project, all, branch } = .project,
    /// In-place session preview (29.4): shows focused session content with the
    /// live markdown renderer styles, never a summary. Lazily loaded.
    session_picker_preview: bool = false,
    session_picker_preview_path: ?[]u8 = null,
    session_picker_preview_lines: std.ArrayList([]u8) = .empty,
    /// Called when F2 is pressed on a picker item (for renaming).
    picker_rename_cb: ?PickerCb = null,
    /// The session path being renamed (for the sessions picker).
    picker_rename_target: ?[]u8 = null,

    // ── modal diff viewer (33.18) ──
    diff_viewer_active: bool = false,
    diff_viewer_sel: usize = 0,
    diff_viewer_scroll: usize = 0,

    // ── transcript search (33.13) ──
    search_bar_active: bool = false,
    search_query_buf: [128]u8 = undefined,
    search_query_len: usize = 0,
    search_matches: std.ArrayList(usize) = .empty, // paragraph indices
    search_current: usize = 0,
    search_has_query: bool = false,

    // ── per-message targeting (33.12) ──
    message_target_para: ?usize = null,

    // ── transcript screen (33.4) ──
    transcript_view_active: bool = false,
    transcript_view_scroll: usize = 0,
    transcript_view_show_all: bool = false,

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
    /// `copy_toast_buf` is Model-owned so the text slice stays valid across the
    /// frames the toast is drawn (a stack local here dangles - the `memaudit`
    /// stack-field-slice crash class).
    copy_toast_text: []const u8 = "",
    copy_toast_buf: [64]u8 = undefined,
    copy_toast_frames: u64 = 0,

    /// 33.9: transient notifications channel (absolutely positioned, no layout shift).
    notifications: [max_notifications]Notification = .{ .{}, .{}, .{}, .{} },
    notification_len: usize = 0,

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
    /// re-resolved on `/provider` and `/model`. `0` means "not yet", not
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

    pub const PermAnswer = enum { none, allow, allow_always, allow_sandbox, deny };

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
    pub const max_cached_paras = 64;

    const SelectionPoint = struct { row: u16, col: u16 };

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
        /// Milliseconds since app clock when the paragraph became visible
        /// (drained to history). Used by Phase 4 motion for layout-neutral,
        /// deterministic reveal/entrance accents. 0 means "not recent / unknown".
        born_ms: u64 = 0,
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
        pub fn textLive(self: *Para, gpa: std.mem.Allocator) []const u8 {
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
        /// File path associated with the diff (when known). Honest metadata for
        /// navigation/review context; never inferred from rendered text.
        diff_path: []u8 = &.{},

        /// Collapsible diff (Ctrl+R toggles between short/full).
        pub fn hasDiff(self: *const ToolMemo) bool {
            return self.diff_para_idx != null and self.diff_full.len > 0 and self.diff_short.len > 0;
        }

        /// Any diff text available for hunk navigation (collapsed or expanded).
        fn hasNavigableDiff(self: *const ToolMemo) bool {
            return self.diff_para_idx != null and self.diff_full.len > 0;
        }

        fn deinit(self: *ToolMemo, gpa: std.mem.Allocator) void {
            if (self.result.len > 0) gpa.free(self.result);
            if (self.summary.len > 0) gpa.free(self.summary);
            if (self.diff_full.len > 0) gpa.free(self.diff_full);
            if (self.diff_short.len > 0) gpa.free(self.diff_short);
            if (self.diff_path.len > 0) gpa.free(self.diff_path);
            self.diff_full = &.{};
            self.diff_short = &.{};
            self.diff_path = &.{};
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
        m.team.gpa = allocator;
        // Empty initial status; real content appears once there's a model/turn.
        m.setStatusText("");
        // The read cache's table is heap-allocated (it is ~300 KB by VALUE at
        // the default ladder step and 1.2 MB for a 1M-window model; the Model
        // is carried everywhere, so the header stays a slice). `runOneTurn`
        // re-sizes it per model; this is the floor that makes `read` work from
        // the first moment, headless or TUI.
        m.reads.configure(allocator, 0);
        return m;
    }

    pub fn deinit(self: *Model) void {
        // Custom keybindings are owned by the model's allocator.
        if (self.keybindings.len > 0) {
            keybinds.freeBindings(self.allocator, self.keybindings);
        }
        // The read cache's table is heap memory of the model's allocator.
        self.reads.deinit();
        // The task graph holds its own strings and its file path.
        self.tasks.deinit();
        // The team (roster + mailboxes) owns its own strings. Acknowledge any
        // teammate still live first — no teammate outlives the app.
        _ = self.team.sweepOnExit();
        self.team.deinit();
        // `/copy`: the pending clipboard text and the picker's context are
        // the model's memory, and nobody else frees them.
        if (self.copy_pending) |p| self.allocator.free(p);
        if (self.copy_ctx) |*c| c.deinit();
        // The checkpoint snapshots are memory of the model's allocator and
        // nobody else frees them: without this, every turn with tools leaves the
        // whole repo in memory until exit.
        self.checkpoints.deinit();
        self.clearNetBaselinesLocked();
        // `clearQueue` keeps the capacity (good, so we don't reallocate on
        // every prompt), so the list's buffer must be freed separately or it
        // leaks on exit.
        self.clearQueue();
        self.queue.deinit(self.allocator);
        self.paste_buf.deinit(self.allocator);
        for (self.shell_out.items) |so| {
            self.allocator.free(so.cmd);
            self.allocator.free(so.text);
        }
        self.shell_out.deinit(self.allocator);
        self.search_matches.deinit(self.allocator);
        self.destroyPalette();
        if (self.pending_items) |items| palette.freeItems(self.allocator, items);
        self.ed.deinit();
        for (self.extra_dirs.items) |d| self.allocator.free(d);
        self.extra_dirs.deinit(self.allocator);
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
        for (self.session_picker_preview_lines.items) |l| self.allocator.free(l);
        self.session_picker_preview_lines.deinit(self.allocator);
        if (self.session_picker_preview_path) |p| self.allocator.free(p);
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
            if (e.first_prompt.len > 0) self.allocator.free(e.first_prompt);
            if (e.last_prompt.len > 0) self.allocator.free(e.last_prompt);
            if (e.agent_name.len > 0) self.allocator.free(e.agent_name);
            if (e.summary.len > 0) self.allocator.free(e.summary);
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
    /// Thread-safe: called by the model catalog worker.
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
        // Re-opening without close must not leak the previous list.
        for (self.picker_items.items) |it| {
            self.allocator.free(it.label);
            if (it.desc.len > 0) self.allocator.free(it.desc);
        }
        self.picker_items.clearRetainingCapacity();
        for (self.session_picker_paths.items) |p| self.allocator.free(p);
        self.session_picker_paths.clearRetainingCapacity();
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
        self.clearSessionPickerPreview();
        if (tag == sessions_picker_tag) {
            self.session_picker_scope = .project;
        }
        self.picker_sel = 0;
        self.picker_scroll = 0;
        self.pickerRefilter();
        self.picker_active = true;
    }

    // ── per-message targeting (33.12) ─────────────────
    pub fn clearMessageTarget(self: *Model) void {
        if (self.message_target_para != null) {
            self.message_target_para = null;
            self.dirty = true;
            self.redraw_requested.store(true, .seq_cst);
        }
    }

    fn isTargetableMessagePara(self: *const Model, idx: usize) bool {
        if (idx >= self.paras.items.len) return false;
        return switch (self.paras.items[idx].kind) {
            .user, .assistant => true,
            else => false,
        };
    }

    fn targetBasePara(self: *const Model) usize {
        if (self.paras.items.len == 0) return 0;
        const last = self.paras.items.len - 1;
        if (self.follow_bottom) return last;
        return @min(self.anchor_para, last);
    }

    pub fn targetPrevMessage(self: *Model) bool {
        const n = self.paras.items.len;
        if (n == 0) return false;
        var i: usize = if (self.message_target_para) |tp|
            (if (tp == 0) return true else tp - 1)
        else
            self.targetBasePara();
        while (true) {
            if (self.isTargetableMessagePara(i)) {
                self.message_target_para = i;
                self.scrollToParaIndex(i);
                self.dirty = true;
                self.redraw_requested.store(true, .seq_cst);
                return true;
            }
            if (i == 0) break;
            i -= 1;
        }
        return false;
    }

    pub fn targetNextMessage(self: *Model) bool {
        const n = self.paras.items.len;
        if (n == 0) return false;
        var i: usize = if (self.message_target_para) |tp| tp + 1 else self.targetBasePara();
        while (i < n) : (i += 1) {
            if (self.isTargetableMessagePara(i)) {
                self.message_target_para = i;
                self.scrollToParaIndex(i);
                self.dirty = true;
                self.redraw_requested.store(true, .seq_cst);
                return true;
            }
        }
        return self.message_target_para != null;
    }

    pub fn targetedMessageText(self: *Model) ?[]const u8 {
        const idx = self.message_target_para orelse return null;
        if (idx >= self.paras.items.len) return null;
        if (!self.isTargetableMessagePara(idx)) return null;
        const p = &self.paras.items[idx];
        return p.textLive(self.allocator);
    }

    // ── transcript screen (33.4) ──────────────────────
    pub fn transcriptViewActive(self: *const Model) bool {
        return self.transcript_view_active;
    }

    pub fn openTranscriptView(self: *Model) void {
        self.transcript_view_active = true;
        self.transcript_view_scroll = 0;
        self.dirty = true;
        self.redraw_requested.store(true, .seq_cst);
    }

    pub fn closeTranscriptView(self: *Model) void {
        self.transcript_view_active = false;
        self.dirty = true;
        self.redraw_requested.store(true, .seq_cst);
    }

    pub fn toggleTranscriptView(self: *Model) void {
        if (self.transcript_view_active) self.closeTranscriptView() else self.openTranscriptView();
    }

    pub fn toggleTranscriptShowAll(self: *Model) void {
        self.transcript_view_show_all = !self.transcript_view_show_all;
        self.transcript_view_scroll = 0;
        self.dirty = true;
        self.redraw_requested.store(true, .seq_cst);
    }

    pub fn transcriptViewHandleKey(self: *Model, key: vaxis.Key) bool {
        if (!self.transcript_view_active) return false;
        if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{}) or key.matches('o', .{ .ctrl = true })) {
            self.closeTranscriptView();
            return true;
        }
        if (key.matches('e', .{ .ctrl = true })) {
            self.toggleTranscriptShowAll();
            return true;
        }
        if (key.codepoint == 57352 or key.matches('k', .{})) { // up
            self.transcript_view_scroll -|= 1;
            self.dirty = true;
            self.redraw_requested.store(true, .seq_cst);
            return true;
        }
        if (key.codepoint == 57353 or key.matches('j', .{})) { // down
            self.transcript_view_scroll +|= 1;
            self.dirty = true;
            self.redraw_requested.store(true, .seq_cst);
            return true;
        }
        if (key.matches(vaxis.Key.page_up, .{}) or key.codepoint == 2 or key.matches('u', .{ .ctrl = true })) {
            self.transcript_view_scroll -|= 10;
            self.dirty = true;
            self.redraw_requested.store(true, .seq_cst);
            return true;
        }
        if (key.matches(vaxis.Key.page_down, .{}) or key.codepoint == 6 or key.matches('d', .{ .ctrl = true })) {
            self.transcript_view_scroll +|= 10;
            self.dirty = true;
            self.redraw_requested.store(true, .seq_cst);
            return true;
        }
        if (key.matches('g', .{})) {
            self.transcript_view_scroll = 0;
            self.dirty = true;
            self.redraw_requested.store(true, .seq_cst);
            return true;
        }
        if (key.matches('G', .{})) {
            self.transcript_view_scroll = std.math.maxInt(usize) / 4;
            self.dirty = true;
            self.redraw_requested.store(true, .seq_cst);
            return true;
        }
        return true; // consume keys while transcript view is open
    }

    // ── transcript search (33.13) ─────────────────────
    pub fn transcriptSearchActive(self: *const Model) bool {
        return self.search_bar_active;
    }

    pub fn openTranscriptSearch(self: *Model) void {
        self.search_bar_active = true;
        self.search_query_len = 0;
        self.dirty = true;
        self.redraw_requested.store(true, .seq_cst);
    }

    pub fn closeTranscriptSearch(self: *Model) void {
        self.search_bar_active = false;
        self.dirty = true;
        self.redraw_requested.store(true, .seq_cst);
    }


    fn scrollToParaIndex(self: *Model, para_idx: usize) void {
        if (para_idx >= self.paras.items.len) return;
        self.ensureParaHeights();
        const line = self.heightPrefix(para_idx);
        self.scrollTo(line);
        self.follow_bottom = false;
        self.anchor_para = para_idx;
        self.anchor_off = 0;
        self.anchor = line;
    }

    pub fn runTranscriptSearch(self: *Model) void {
        self.search_matches.clearRetainingCapacity();
        self.search_current = 0;
        self.search_has_query = self.search_query_len > 0;
        if (self.search_query_len == 0) return;
        const q = self.search_query_buf[0..self.search_query_len];
        for (self.paras.items, 0..) |*p, i| {
            const text = p.textLive(self.allocator);
            if (containsIgnoreCase(text, q)) {
                self.search_matches.append(self.allocator, i) catch {};
            }
        }
        if (self.search_matches.items.len > 0) {
            self.search_current = 0;
            self.scrollToParaIndex(self.search_matches.items[0]);
        }
        self.dirty = true;
        self.redraw_requested.store(true, .seq_cst);
    }

    pub fn transcriptSearchNext(self: *Model, forward: bool) bool {
        const n = self.search_matches.items.len;
        if (n == 0) {
            if (self.search_has_query) self.pushInfo("search: no matches");
            return false;
        }
        if (forward) {
            self.search_current = if (self.search_current + 1 < n) self.search_current + 1 else 0;
        } else {
            self.search_current = if (self.search_current == 0) n - 1 else self.search_current - 1;
        }
        self.scrollToParaIndex(self.search_matches.items[self.search_current]);
        self.dirty = true;
        self.redraw_requested.store(true, .seq_cst);
        return true;
    }

    /// Handles keys while the transcript search bar is active.
    pub fn searchBarHandleKey(self: *Model, key: vaxis.Key) bool {
        if (!self.search_bar_active) return false;
        if (key.matches(vaxis.Key.escape, .{})) {
            self.closeTranscriptSearch();
            return true;
        }
        if (key.codepoint == 0x0D) { // enter
            self.runTranscriptSearch();
            self.closeTranscriptSearch();
            if (self.search_matches.items.len == 0 and self.search_query_len > 0) {
                self.pushInfo("search: no matches");
            } else if (self.search_matches.items.len > 0) {
                self.pushInfoFmt("search: {d}/{d}", .{ self.search_current + 1, self.search_matches.items.len });
            }
            return true;
        }
        if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.search_query_len > 0) self.search_query_len -= 1;
            self.dirty = true;
            self.redraw_requested.store(true, .seq_cst);
            return true;
        }
        if (key.text) |txt| {
            if (txt.len > 0 and !key.mods.ctrl and palette.isPrintableText(txt)) {
                const space = self.search_query_buf.len - self.search_query_len;
                const ncopy = @min(space, txt.len);
                if (ncopy > 0) {
                    @memcpy(self.search_query_buf[self.search_query_len..][0..ncopy], txt[0..ncopy]);
                    self.search_query_len += ncopy;
                }
                self.dirty = true;
                self.redraw_requested.store(true, .seq_cst);
                return true;
            }
        }
        if (!key.mods.ctrl and !key.mods.alt and key.codepoint >= 32 and key.codepoint < 127) {
            if (self.search_query_len < self.search_query_buf.len) {
                self.search_query_buf[self.search_query_len] = @intCast(key.codepoint);
                self.search_query_len += 1;
                self.dirty = true;
                self.redraw_requested.store(true, .seq_cst);
            }
            return true;
        }
        return true;
    }

    // ── modal diff viewer (33.18) ─────────────────────
    pub fn diffViewerActive(self: *const Model) bool {
        return self.diff_viewer_active;
    }

    pub fn openDiffViewer(self: *Model) bool {
        if (self.file_intel_len == 0) return false;
        const focus = @min(self.file_focus orelse (self.file_intel_len - 1), self.file_intel_len - 1);
        self.diff_viewer_active = true;
        self.diff_viewer_sel = focus;
        self.diff_viewer_scroll = 0;
        self.dirty = true;
        self.redraw_requested.store(true, .seq_cst);
        return true;
    }

    pub fn closeDiffViewer(self: *Model) void {
        self.diff_viewer_active = false;
        self.diff_viewer_scroll = 0;
        self.dirty = true;
        self.redraw_requested.store(true, .seq_cst);
    }

    fn diffViewerSelectedPara(self: *const Model) ?usize {
        if (self.file_intel_len == 0) return null;
        const idx = @min(self.diff_viewer_sel, self.file_intel_len - 1);
        return self.file_intel[idx].diff_para;
    }

    /// Handles keys while the diff viewer modal is active. Returns true if consumed.
    pub fn diffViewerHandleKey(self: *Model, key: vaxis.Key) bool {
        if (!self.diff_viewer_active) return false;
        if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) {
            self.closeDiffViewer();
            return true;
        }
        const n = self.file_intel_len;
        if (n == 0) {
            self.closeDiffViewer();
            return true;
        }
        if (key.codepoint == 57352 or key.matches('k', .{})) { // up
            self.diff_viewer_sel = if (self.diff_viewer_sel == 0) n - 1 else self.diff_viewer_sel - 1;
            self.diff_viewer_scroll = 0;
            return true;
        }
        if (key.codepoint == 57353 or key.matches('j', .{})) { // down
            self.diff_viewer_sel = if (self.diff_viewer_sel + 1 < n) self.diff_viewer_sel + 1 else 0;
            self.diff_viewer_scroll = 0;
            return true;
        }
        if (key.matches(vaxis.Key.page_down, .{}) or key.codepoint == 6) { // ctrl+f
            self.diff_viewer_scroll +|= 10;
            return true;
        }
        if (key.matches(vaxis.Key.page_up, .{}) or key.codepoint == 2) { // ctrl+b
            self.diff_viewer_scroll -|= 10;
            return true;
        }
        if (key.matches('d', .{ .ctrl = true })) {
            self.diff_viewer_scroll +|= 10;
            return true;
        }
        if (key.matches('u', .{ .ctrl = true })) {
            self.diff_viewer_scroll -|= 10;
            return true;
        }
        if (key.codepoint == 0x0D) { // enter: jump to diff in transcript
            const idx = @min(self.diff_viewer_sel, n - 1);
            self.closeDiffViewer();
            _ = self.showFileIntelFocus(idx, true);
            return true;
        }
        return true; // consume other keys while modal is open
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
        self.clearSessionPickerPreview();
        self.session_picker_scope = .project;
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

    /// Is any modal surface currently on top of the composer? Used so global
    /// keys (Ctrl+C especially) do not quit the app while a picker is open.
    pub fn anyModalActive(self: *Model) bool {
        return self.pal.active or self.pickerActive() or self.transcript_view_active or
            self.search_bar_active or self.diff_viewer_active or self.settings_active;
    }

    /// Close the topmost modal. Returns false when there was none. The order
    /// is the reverse of the key handler's modal checks.
    pub fn closeTopModal(self: *Model, ctx: *vxfw.EventContext) !bool {
        if (self.pal.active) {
            self.closePalette();
            ctx.redraw = true;
            return true;
        }
        if (self.pickerActive()) {
            self.closePicker();
            ctx.redraw = true;
            return true;
        }
        if (self.transcript_view_active) {
            self.closeTranscriptView();
            ctx.redraw = true;
            return true;
        }
        if (self.search_bar_active) {
            self.closeTranscriptSearch();
            ctx.redraw = true;
            return true;
        }
        if (self.diff_viewer_active) {
            self.closeDiffViewer();
            ctx.redraw = true;
            return true;
        }
        if (self.settings_active) {
            self.settingsClose();
            ctx.redraw = true;
            return true;
        }
        return false;
    }

    pub fn settingsOpen(self: *Model) void {
        self.settings_active = true;
        self.settings_section = 0;
        self.settings_row = 0;
        self.settings_col = 0;
    }

    pub fn settingsClose(self: *Model) void {
        self.settings_active = false;
    }

    /// The Settings screen owns every key while it is open, like the picker.
    /// Returns true when the key was consumed.
    pub fn settingsHandleKey(self: *Model, key: vaxis.Key) bool {
        if (!self.settings_active) return false;
        const sec = configmenu.all_sections[@min(self.settings_section, configmenu.all_sections.len - 1)];
        const rows = configmenu.settingsFor(sec);
        switch (key.codepoint) {
            9 => { // Tab: switch column
                self.settings_col = if (self.settings_col == 0) 1 else 0;
                return true;
            },
            57352 => { // up
                if (self.settings_col == 0) {
                    if (self.settings_section > 0) {
                        self.settings_section -= 1;
                        self.settings_row = 0;
                    }
                } else if (self.settings_row > 0) {
                    self.settings_row -= 1;
                }
                return true;
            },
            57353 => { // down
                if (self.settings_col == 0) {
                    if (self.settings_section + 1 < configmenu.all_sections.len) {
                        self.settings_section += 1;
                        self.settings_row = 0;
                    }
                } else if (self.settings_row + 1 < rows.len) {
                    self.settings_row += 1;
                }
                return true;
            },
            0x0D => { // Enter
                if (self.settings_col == 0) {
                    self.settings_col = 1;
                    self.settings_row = @min(self.settings_row, rows.len -| 1);
                    return true;
                }
                if (self.settings_row >= rows.len) return true;
                agent.applySettingsRow(self, rows[self.settings_row], .enter);
                return true;
            },
            0x1b => { // Esc: back to sections, then close
                if (self.settings_col == 1) {
                    self.settings_col = 0;
                } else {
                    self.settingsClose();
                }
                return true;
            },
            0x08, 127 => { // backspace: previous value
                if (self.settings_col == 1 and self.settings_row < rows.len) {
                    agent.applySettingsRow(self, rows[self.settings_row], .prev);
                }
                return true;
            },
            else => {
                // ← / → cycle a value when a row is selected.
                if (key.codepoint == 57356 or key.codepoint == 57357) {
                    if (self.settings_col == 1 and self.settings_row < rows.len) {
                        agent.applySettingsRow(self, rows[self.settings_row], if (key.codepoint == 57357) .next else .prev);
                    }
                    return true;
                }
                return true; // capture everything else while the screen is up
            },
        }
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
            for (self.session_picker_paths.items) |p| self.allocator.free(p);
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
                    var sbuf: [24]u8 = undefined;
                    const sz = if (e.size_bytes > 0) (std.mem.print(&sbuf, "{d} KB", .{e.size_bytes / 1024}) catch "") else "";
                    const summary = if (e.summary.len > 0) e.summary else (if (e.last_prompt.len > 0) e.last_prompt else "");
                    const desc = if (summary.len > 0 and e.tag.len > 0 and sz.len > 0)
                        (std.fmt.allocPrint(self.allocator, "{s} · {s} · #{s} · {s}", .{ age, sz, e.tag, summary }) catch self.allocator.dupe(u8, age) catch "")
                    else if (summary.len > 0 and e.tag.len > 0)
                        (std.fmt.allocPrint(self.allocator, "{s} · #{s} · {s}", .{ age, e.tag, summary }) catch self.allocator.dupe(u8, age) catch "")
                    else if (summary.len > 0 and sz.len > 0)
                        (std.fmt.allocPrint(self.allocator, "{s} · {s} · {s}", .{ age, sz, summary }) catch self.allocator.dupe(u8, age) catch "")
                    else if (summary.len > 0)
                        (std.fmt.allocPrint(self.allocator, "{s} · {s}", .{ age, summary }) catch self.allocator.dupe(u8, age) catch "")
                    else if (e.tag.len > 0 and sz.len > 0)
                        (std.fmt.allocPrint(self.allocator, "{s} · {s} · #{s}", .{ age, sz, e.tag }) catch self.allocator.dupe(u8, age) catch "")
                    else if (e.tag.len > 0)
                        (std.fmt.allocPrint(self.allocator, "{s} · #{s}", .{ age, e.tag }) catch self.allocator.dupe(u8, age) catch "")
                    else if (sz.len > 0)
                        (std.fmt.allocPrint(self.allocator, "{s} · {s}", .{ age, sz }) catch self.allocator.dupe(u8, age) catch "")
                    else
                        self.allocator.dupe(u8, age) catch "";
                    self.picker_items.append(self.allocator, .{ .label = label, .desc = desc }) catch {
                        self.allocator.free(label);
                        if (desc.len > 0) self.allocator.free(desc);
                    };
                    const pd = self.allocator.dupe(u8, e.path) catch "";
                    _ = self.session_picker_paths.append(self.allocator, pd) catch self.allocator.free(pd);
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
                            const summary = if (e.summary.len > 0) e.summary else (if (e.last_prompt.len > 0) e.last_prompt else "");
                            const desc = if (summary.len > 0 and e.tag.len > 0)
                                (std.fmt.allocPrint(self.allocator, "{s} · #{s} · {s}", .{ age, e.tag, summary }) catch self.allocator.dupe(u8, age) catch "")
                            else if (summary.len > 0)
                                (std.fmt.allocPrint(self.allocator, "{s} · {s}", .{ age, summary }) catch self.allocator.dupe(u8, age) catch "")
                            else if (e.tag.len > 0)
                                (std.fmt.allocPrint(self.allocator, "{s} · #{s}", .{ age, e.tag }) catch self.allocator.dupe(u8, age) catch "")
                            else
                                self.allocator.dupe(u8, age) catch "";
                            self.picker_items.append(self.allocator, .{ .label = label, .desc = desc }) catch {
                                self.allocator.free(label);
                                if (desc.len > 0) self.allocator.free(desc);
                            };
                            const pd2 = self.allocator.dupe(u8, e.path) catch "";
                            _ = self.session_picker_paths.append(self.allocator, pd2) catch self.allocator.free(pd2);
                        }
                    }
                } else {
                    var all_hits: std.ArrayList(session_search.SessionHit) = .empty;
                    defer all_hits.deinit(self.allocator);

                    // Tier 1: title substring — always runs, instant.
                    const title_hits: ?[]session_search.SessionHit = session_search.searchTitle(self.allocator, self.session_picker_entries.items, q) catch null;
                    if (title_hits) |h| {
                        defer self.allocator.free(h);
                        for (h) |hit| {
                            all_hits.append(self.allocator, hit) catch {};
                        }
                    }

                    // Tier 2: transcript fuzzy — debounced. Only runs after the user
                    // pauses typing for `picker_transcript_debounce_s`. While typing,
                    // only tier-1 results are shown (Phase 29.5).
                    const debounce_ok = self.picker_query_changed_at == 0 or now - self.picker_query_changed_at >= picker_transcript_debounce_s;
                    if (debounce_ok) {
                        const transcript_hits: ?[]session_search.SessionHit = session_search.searchTranscript(self.allocator, self.io, self.session_picker_entries.items, q) catch null;
                        if (transcript_hits) |h| {
                            defer self.allocator.free(h);
                            for (h) |hit| {
                                all_hits.append(self.allocator, hit) catch {};
                            }
                        }
                    }

                    const ranked: ?[]session_search.SessionHit = session_search.rankHits(self.allocator, all_hits.items) catch null;
                    if (ranked) |h| {
                        defer self.allocator.free(h);
                        // `ranked` may be empty on error; that's fine, shows nothing.
                        for (h) |hit| {
                            const session_id = std.fs.path.basename(hit.entry.path);
                            const title = hit.entry.title(session_id);
                            const label = self.allocator.dupe(u8, title) catch "";
                            var desc: []const u8 = "";
                            var desc_owned: ?[]u8 = null;
                            if (hit.tier == .transcript and hit.snippet.len > 0) {
                                desc_owned = self.allocator.dupe(u8, hit.snippet) catch null;
                                if (desc_owned) |d| desc = d;
                            } else {
                                const age = sessionindex.ageLabel(now, hit.entry.created_at, &now_buf);
                                const summary = if (hit.entry.summary.len > 0) hit.entry.summary else (if (hit.entry.last_prompt.len > 0) hit.entry.last_prompt else "");
                                desc_owned = if (summary.len > 0 and hit.entry.tag.len > 0)
                                    (std.fmt.allocPrint(self.allocator, "{s} · #{s} · {s}", .{ age, hit.entry.tag, summary }) catch null)
                                else if (summary.len > 0)
                                    (std.fmt.allocPrint(self.allocator, "{s} · {s}", .{ age, summary }) catch null)
                                else if (hit.entry.tag.len > 0)
                                    (std.fmt.allocPrint(self.allocator, "{s} · #{s}", .{ age, hit.entry.tag }) catch null)
                                else
                                    (self.allocator.dupe(u8, age) catch null);
                                if (desc_owned) |d| desc = d;
                            }
                            self.picker_items.append(self.allocator, .{ .label = label, .desc = desc }) catch {
                                self.allocator.free(label);
                                if (desc_owned) |d| self.allocator.free(d);
                            };
                            const pdupe = self.allocator.dupe(u8, hit.entry.path) catch "";
                            _ = self.session_picker_paths.append(self.allocator, pdupe) catch self.allocator.free(pdupe);
                        }
                    }
                }
            }
            // The session branch rebuilds items, so the visible list must be
            // rebuilt too. Without this `picker_filtered` stays empty and the
            // picker opens blank: `/session` showed nothing even with sessions
            // on disk. Paths stay aligned 1:1 with items so `onSessionPick`
            // and F2 never see an index past the end (index 22 len 21).
            for (0..self.picker_items.items.len) |ix| {
                self.picker_filtered.append(self.allocator, ix) catch break;
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
        const is_sessions = self.picker_tag == sessions_picker_tag;
        const visible: usize = 10;

        // Session picker chords (29.4/29.5): must not become filter text.
        if (is_sessions) {
            if (key.matches('s', .{ .ctrl = true })) {
                if (self.session_picker_semantic_searching) {
                    self.session_picker_semantic_searching = false;
                    self.session_picker_semantic = false;
                    for (self.session_picker_semantic_results.items) |p| self.allocator.free(p);
                    self.session_picker_semantic_results.clearRetainingCapacity();
                    self.pickerRefilter();
                    self.unlock();
                    return true;
                }
                self.session_picker_semantic = true;
                self.session_picker_semantic_searching = true;
                self.beginWorker();
                self.unlock();
                const th = std.Thread.spawn(.{}, sessionSemanticSearchThread, .{self}) catch {
                    self.endWorker();
                    self.lock();
                    self.session_picker_semantic_searching = false;
                    self.pickerRefilter();
                    self.unlock();
                    return true;
                };
                th.detach();
                return true;
            }
            if (key.matches('a', .{ .ctrl = true })) {
                self.session_picker_scope = .all;
                self.unlock();
                self.reloadSessionPickerScope();
                return true;
            }
            if (key.matches('b', .{ .ctrl = true })) {
                self.session_picker_scope = .branch;
                self.unlock();
                self.reloadSessionPickerScope();
                return true;
            }
            if (key.matches('v', .{ .ctrl = true })) {
                self.session_picker_preview = !self.session_picker_preview;
                if (self.session_picker_preview) self.loadSessionPickerPreview();
                self.unlock();
                return true;
            }
        }

        switch (key.codepoint) {
            57352 => { // up (29.4): on first row, stay (filter remains the input)
                if (self.picker_sel > 0) self.picker_sel -= 1;
                if (is_sessions and self.session_picker_preview) self.loadSessionPickerPreview();
            },
            57353 => { // down
                if (self.picker_sel + 1 < self.picker_filtered.items.len) self.picker_sel += 1;
                if (is_sessions and self.session_picker_preview) self.loadSessionPickerPreview();
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
                    if (i < self.picker_items.items.len)
                        self.allocator.dupe(u8, self.picker_items.items[i].label) catch null
                    else
                        null
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
            27 => { // esc (29.4): clear filter when filtering, else cancel semantic/close
                if (self.session_picker_semantic_searching) {
                    self.session_picker_semantic_searching = false;
                    self.unlock();
                    self.pickerRefilter();
                    return true;
                }
                if (self.session_picker_semantic) {
                    self.session_picker_semantic = false;
                    self.session_picker_semantic_results.clearRetainingCapacity();
                    self.unlock();
                    self.pickerRefilter();
                    return true;
                }
                if (self.picker_query_len > 0) {
                    self.picker_query_len = 0;
                    self.picker_sel = 0;
                    self.picker_scroll = 0;
                    self.pickerRefilter();
                    self.unlock();
                    return true;
                }
                const cancel = self.picker_cancel_cb;
                const tag = self.picker_tag;
                self.unlock();
                self.closePicker();
                if (cancel) |f| f(self, tag);
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
                        // Bounds guard: stale filtered indices after a rebuild
                        // must not panic (index 22 len 21).
                        if (i >= self.session_picker_paths.items.len or i >= self.picker_items.items.len) {
                            self.unlock();
                            return true;
                        }
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
                if (is_sessions and self.session_picker_preview) self.loadSessionPickerPreview();
            },
            else => |cp| {
                if (!key.mods.ctrl and !key.mods.alt and cp >= 0x20 and cp < 0x7F and self.picker_query_len < self.picker_query.len) {
                    self.picker_query[self.picker_query_len] = @intCast(cp);
                    self.picker_query_len += 1;
                    self.picker_sel = 0;
                    self.picker_scroll = 0;
                    self.picker_query_changed_at = if (self.io_ready) std.Io.Timestamp.now(self.io, .real).toSeconds() else 0;
                    self.pickerRefilter();
                    if (is_sessions and self.session_picker_preview) self.loadSessionPickerPreview();
                }
            },
        }
        // adjust scroll so sel is visible
        if (self.picker_sel < self.picker_scroll) self.picker_scroll = self.picker_sel;
        if (self.picker_sel >= self.picker_scroll + visible) self.picker_scroll = self.picker_sel - visible + 1;
        self.unlock();
        return true;
    }

    fn clearSessionPickerPreview(self: *Model) void {
        self.session_picker_preview = false;
        if (self.session_picker_preview_path) |p| {
            self.allocator.free(p);
            self.session_picker_preview_path = null;
        }
        for (self.session_picker_preview_lines.items) |l| self.allocator.free(l);
        self.session_picker_preview_lines.clearRetainingCapacity();
    }

    fn loadSessionPickerPreview(self: *Model) void {
        // Lazily render the focused session with the same markdown parser/styles
        // as the live transcript (never a summary). 29.4.
        self.clearSessionPickerPreview();
        self.session_picker_preview = true;
        if (self.picker_tag != sessions_picker_tag) return;
        const ix = if (self.picker_sel < self.picker_filtered.items.len)
            self.picker_filtered.items[self.picker_sel]
        else
            return;
        if (ix >= self.session_picker_paths.items.len) return;
        const path = self.session_picker_paths.items[ix];
        self.session_picker_preview_path = self.allocator.dupe(u8, path) catch null;
        if (!self.io_ready) return;

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const data = std.Io.Dir.cwd().readFileAlloc(self.io, path, a, .limited(1024 * 1024)) catch return;
        var line_it = std.mem.splitScalar(u8, data, '\n');
        while (line_it.next()) |raw| {
            if (raw.len == 0) continue;
            const line = if (raw[0] == 'z' and zjsonl.isCompressed(raw))
                (zjsonl.decompressInto(a, raw, 1024 * 1024) catch continue)
            else
                raw;
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch continue;
            if (parsed != .object) continue;
            const obj = parsed.object;
            const role_v = obj.get("role") orelse continue;
            if (role_v != .string) continue;
            const role = role_v.string;
            const content_v = obj.get("content") orelse continue;
            if (content_v != .string) continue;
            const content = content_v.string;
            if (std.mem.eql(u8, role, "user")) {
                if (agent.isHarnessInternalUserMessage(content)) continue;
                self.appendPreviewBlock(.user, content);
            } else if (std.mem.eql(u8, role, "assistant")) {
                self.appendPreviewBlock(.assistant, content);
            } else if (std.mem.eql(u8, role, "tool")) {
                self.appendPreviewBlock(.tool_res, content);
            }
        }
        if (self.session_picker_preview_lines.items.len == 0) {
            self.appendPreviewBlock(.info, "(no previewable messages)");
        }
    }

    fn appendPreviewBlock(self: *Model, kind: md.Kind, text: []const u8) void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const blocks = md.parse(a, kind, text) catch {
            self.appendPreviewLine(kind, text);
            return;
        };
        for (blocks) |blk| {
            for (blk.lines) |segs| {
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(self.allocator);
                for (segs) |seg| buf.appendSlice(self.allocator, seg.text) catch {};
                self.appendPreviewLine(blk.kind, buf.items);
            }
        }
    }

    fn appendPreviewLine(self: *Model, kind: md.Kind, text: []const u8) void {
        const prefix: u8 = switch (kind) {
            .user => 'U',
            .assistant => 'A',
            .tool, .tool_run, .tool_res => 'T',
            .error_msg => 'E',
            .diff => 'D',
            else => 'I',
        };
        const max_take: usize = 400;
        const take = @min(text.len, max_take);
        const owned = self.allocator.alloc(u8, take + 1) catch return;
        owned[0] = prefix;
        if (take > 0) @memcpy(owned[1..][0..take], text[0..take]);
        self.session_picker_preview_lines.append(self.allocator, owned) catch self.allocator.free(owned);
    }

    fn reloadSessionPickerScope(self: *Model) void {
        if (self.picker_tag != sessions_picker_tag) return;
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();

        const gpa = self.allocator;
        self.lock();
        for (self.session_picker_entries.items) |e| {
            gpa.free(e.path);
            if (e.name.len > 0) gpa.free(e.name);
            if (e.model.len > 0) gpa.free(e.model);
            if (e.custom_title.len > 0) gpa.free(e.custom_title);
            if (e.ai_title.len > 0) gpa.free(e.ai_title);
            if (e.first_prompt.len > 0) gpa.free(e.first_prompt);
            if (e.last_prompt.len > 0) gpa.free(e.last_prompt);
            if (e.agent_name.len > 0) gpa.free(e.agent_name);
        }
        self.session_picker_entries.clearRetainingCapacity();
        for (self.session_picker_paths.items) |p| gpa.free(p);
        self.session_picker_paths.clearRetainingCapacity();
        for (self.picker_items.items) |it| {
            gpa.free(it.label);
            if (it.desc.len > 0) gpa.free(it.desc);
        }
        self.picker_items.clearRetainingCapacity();
        self.picker_filtered.clearRetainingCapacity();
        self.clearSessionPickerPreview();
        const scope = self.session_picker_scope;
        const state_dir = session_mod.sessions_dir;
        const io_ready = self.io_ready;
        self.unlock();

        var entries: []sessionindex.Entry = &.{};
        if (io_ready and scope == .all) {
            const parent = std.fs.path.dirname(state_dir) orelse state_dir;
            if (std.Io.Dir.cwd().openDir(self.io, parent, .{ .iterate = true })) |dir_val| {
                var dir = dir_val;
                defer dir.close(self.io);
                var acc: std.ArrayList(sessionindex.Entry) = .empty;
                var it = dir.iterate();
                while (it.next(self.io) catch null) |ent| {
                    if (ent.kind != .directory) continue;
                    const sub = std.fs.path.join(a, &.{ parent, ent.name }) catch continue;
                    const found = sessionindex.scan(a, self.io, sub);
                    acc.appendSlice(a, found) catch {};
                }
                const here = sessionindex.scan(a, self.io, state_dir);
                acc.appendSlice(a, here) catch {};
                entries = acc.toOwnedSlice(a) catch &.{};
            } else |_| {
                entries = sessionindex.scan(a, self.io, state_dir);
            }
        } else if (io_ready) {
            // .project and .branch (branch metadata not persisted: project scope)
            entries = sessionindex.scan(a, self.io, state_dir);
        }

        self.lock();
        const now = if (self.io_ready) std.Io.Timestamp.now(self.io, .real).toSeconds() else 0;
        for (entries) |e| {
            const pth = gpa.dupe(u8, e.path) catch continue;
            const ne = sessionindex.Entry{
                .path = pth,
                .name = gpa.dupe(u8, e.name) catch "",
                .model = gpa.dupe(u8, e.model) catch "",
                .custom_title = gpa.dupe(u8, e.custom_title) catch "",
                .ai_title = gpa.dupe(u8, e.ai_title) catch "",
                .created_at = e.created_at,
                .first_prompt = gpa.dupe(u8, e.first_prompt) catch "",
                .last_prompt = gpa.dupe(u8, e.last_prompt) catch "",
                .agent_name = gpa.dupe(u8, e.agent_name) catch "",
                .size_bytes = e.size_bytes,
                .summary = gpa.dupe(u8, e.summary) catch "",
            };
            self.session_picker_entries.append(gpa, ne) catch {
                gpa.free(pth);
                continue;
            };
            const session_id = std.fs.path.basename(ne.path);
            const title = ne.title(session_id);
            const label = gpa.dupe(u8, title) catch continue;
            var age_buf: [24]u8 = undefined;
            const age = sessionindex.ageLabel(now, ne.created_at, &age_buf);
            const summary = if (ne.summary.len > 0) ne.summary else (if (ne.last_prompt.len > 0) ne.last_prompt else "");
            var desc_buf: [96]u8 = undefined;
            const desc_text = if (summary.len > 0 and ne.size_bytes > 0)
                (std.mem.print(&desc_buf, "{s} · {d} KB · {s}", .{ age, ne.size_bytes / 1024, summary }) catch age)
            else if (summary.len > 0)
                (std.mem.print(&desc_buf, "{s} · {s}", .{ age, summary }) catch age)
            else if (ne.size_bytes > 0)
                (std.mem.print(&desc_buf, "{s} · {d} KB", .{ age, ne.size_bytes / 1024 }) catch age)
            else
                age;
            const desc = gpa.dupe(u8, desc_text) catch "";
            self.picker_items.append(gpa, .{ .label = label, .desc = desc }) catch {};
            self.session_picker_paths.append(gpa, gpa.dupe(u8, ne.path) catch "") catch {};
        }
        var tbuf: [64]u8 = undefined;
        const scope_label: []const u8 = switch (scope) {
            .project => "",
            .all => " · all projects",
            .branch => " · branch (project)",
        };
        const ttext = std.mem.print(&tbuf, "Resume ({d} sessions){s}", .{ entries.len, scope_label }) catch "Resume";
        const nt = @min(ttext.len, self.picker_title.len);
        @memcpy(self.picker_title[0..nt], ttext[0..nt]);
        self.picker_title_len = nt;
        self.pickerRefilter();
        self.unlock();
    }

    fn sessionSemanticSearchThread(self: *Model) void {
        defer self.endWorker();
        self.sessionSemanticSearch();
    }

    fn sessionSemanticSearch(self: *Model) void {
        self.lock();
        const q_owned = self.allocator.dupe(u8, self.picker_query[0..self.picker_query_len]) catch {
            self.session_picker_semantic_searching = false;
            self.unlock();
            return;
        };
        self.unlock();
        defer self.allocator.free(q_owned);

        if (q_owned.len == 0) {
            self.lock();
            self.session_picker_semantic_searching = false;
            self.unlock();
            return;
        }

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const sarena = arena_state.allocator();
        const task = subagent_mod.Task{
            .description = sarena.dupe(u8, "semantic session search") catch "",
            .prompt = std.fmt.allocPrint(
                sarena,
                "Find zode session files semantically relevant to this query: \"{s}\"\n\nSession files are JSONL in the sessions directory. Each line is a message with role, content, etc. Use glob to list session files, then read to examine promising ones. Look at titles and user/assistant messages to judge semantic relevance.\n\nReturn ONLY the file paths of relevant sessions, one per line, no other text. Return nothing if none match.",
                .{q_owned},
            ) catch "",
        };
        if (task.description.len == 0 or task.prompt.len == 0) {
            self.lock();
            self.session_picker_semantic_searching = false;
            self.unlock();
            return;
        }
        var rep = subagent_mod.Report{};
        const text = agent.runSubagent(self, task, &rep);

        self.lock();
        for (self.session_picker_semantic_results.items) |p| self.allocator.free(p);
        self.session_picker_semantic_results.clearRetainingCapacity();
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            if (std.mem.indexOf(u8, trimmed, ".jsonl") == null) continue;
            if (std.mem.indexOf(u8, trimmed, "zode-") == null) continue;
            const pdupe = self.allocator.dupe(u8, trimmed) catch continue;
            self.session_picker_semantic_results.append(self.allocator, pdupe) catch {
                self.allocator.free(pdupe);
            };
        }
        self.session_picker_semantic_searching = false;
        self.pickerRefilter();
        self.dirty = true;
        self.redraw_requested.store(true, .seq_cst);
        self.unlock();
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
            const target = self.picker_filtered.items[fi];
            if (target >= self.picker_items.items.len) continue;
            const it = self.picker_items.items[target];
            items[out_ix] = .{
                .label = arena.dupe(u8, it.label) catch "",
                .desc = arena.dupe(u8, it.desc) catch "",
            };
            out_ix += 1;
        }
        // Trim if we skipped stale indices (keeps the snapshot from exposing
        // uninitialized holes).
        var preview_lines: []const []const u8 = &.{};
        if (self.session_picker_preview and self.picker_tag == sessions_picker_tag) {
            if (arena.alloc([]const u8, self.session_picker_preview_lines.items.len)) |pl| {
                var pi: usize = 0;
                for (self.session_picker_preview_lines.items) |l| {
                    pl[pi] = arena.dupe(u8, l) catch "";
                    pi += 1;
                }
                preview_lines = pl[0..pi];
            } else |_| {}
        }
        return .{
            .title = arena.dupe(u8, self.picker_title[0..self.picker_title_len]) catch "",
            .query = arena.dupe(u8, self.picker_query[0..self.picker_query_len]) catch "",
            .sel = self.picker_sel,
            .first_visible = start,
            .total = total,
            .tag = self.picker_tag,
            .items = items[0..out_ix],
            .semantic_searching = self.session_picker_semantic_searching,
            .semantic_mode = self.session_picker_semantic,
            .preview = self.session_picker_preview and self.picker_tag == sessions_picker_tag,
            .preview_lines = preview_lines,
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
        const s = std.mem.print(&buf, fmt, args) catch {
            self.setStatusWithMood(new_mood, fmt);
            return;
        };
        self.setStatusWithMood(new_mood, s);
    }

    /// Phase 32.1: fold a verify-role subagent report into the activity strip.
    /// The protocol lines ("found:", "verified:", "refuted:") are counted; the
    /// pill animates +1 toward the target on each tick via `verify_counter`.
    pub fn setVerifyReport(self: *Model, report: []const u8) void {
        self.lock();
        defer self.unlock();
        self.verify_counts = verifycounts.parseReport(report);
        self.verify_phase = if (self.verify_counts.hasData()) .verifying else .setting_up;
        self.verify_counter.setTarget(self.verify_counts.found + self.verify_counts.verified + self.verify_counts.refuted);
        self.dirty = true;
    }

    /// Sets the active pipeline stage label ("explorer", "investigator",
    /// "implementer", "tester", "verify", "reviewer") or null. The draw path
    /// uses it to show what the harness is doing and to keep the mascot/legend
    /// in sync. Pass static string literals.
    pub fn setPipelineStage(self: *Model, stage: ?[]const u8) void {
        self.lock();
        defer self.unlock();
        self.pipeline_stage = stage;
        self.dirty = true;
        self.redraw_requested.store(true, .seq_cst);
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
        // `perm_sandbox_available` is set by the caller before this blocks:
        // clearing it here would discard a "run sandboxed" offer (Phase 25).
        self.perm_active = true;
        // The tick must keep running while the user decides: without this the
        // dialog appears but is not repainted (the clock, the face...).
        self.redraw_requested.store(true, .seq_cst);
        const sess = self.session;
        self.permUnlock();
        if (sess) |sp| sp.bumpPermissionsAsked();

        // SLEEPING wait: the backoff grows up to 20 ms, so the worker burns no
        // CPU while the user decides (before it was spin-yield).
        self.waitPermAnswer();

        self.permLock();
        const a = self.perm_answer;
        self.perm_active = false;
        self.perm_rule_len = 0;
        self.perm_suggestion_len = 0;
        self.perm_sandbox_available = false;
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

    /// The rule that caused this permission question, or "" when none matched.
    pub fn setPermRule(self: *Model, text: []const u8) void {
        self.permLock();
        defer self.permUnlock();
        const n = @min(text.len, self.perm_rule.len);
        @memcpy(self.perm_rule[0..n], text[0..n]);
        self.perm_rule_len = n;
    }

    /// The rule that caused this permission question, or "" when none matched.
    pub fn permRule(self: *Model) []const u8 {
        self.permLock();
        defer self.permUnlock();
        return self.perm_rule[0..self.perm_rule_len];
    }

    /// Whether the open dialog offers "always allow".
    pub fn permAllowAlways(self: *Model) bool {
        self.permLock();
        defer self.permUnlock();
        return self.perm_allow_always;
    }

    /// Whether the open dialog offers "run in sandbox" (a flagged bash command
    /// with bwrap/firejail available). Set by the worker before asking.
    pub fn setPermSandboxAvailable(self: *Model, available: bool) void {
        self.permLock();
        defer self.permUnlock();
        self.perm_sandbox_available = available;
    }

    pub fn permSandboxAvailable(self: *Model) bool {
        self.permLock();
        defer self.permUnlock();
        return self.perm_sandbox_available;
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
    pub fn ensureParaHeights(self: *Model) void {
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

    pub fn setHeightTreeValue(self: *Model, index: usize, value: usize) void {
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
    pub fn heightPrefix(self: *const Model, end: usize) usize {
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
    pub fn heightIndexAt(self: *const Model, line: usize) usize {
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

    pub fn estHeight(self: *const Model, text: []const u8) usize {
        const per_line: usize = @intCast(self.wrap_w);
        // The wrap is counted PER LINE, not as "every line is as wide as the
        // terminal".
        //
        // It used to be `(text.len - nl) / per_line` added to `nl + 1`, which
        // charges every line the extra rows of a FULL line. Prose is the shape
        // that breaks it: a 2.5 KB answer in 43 short lines estimated 70 rows
        // for a paragraph that renders in 48, and the overshoot is not
        // cosmetic — the estimate holds the scroll until the parse corrects it,
        // and the bigger the gap, the bigger the jump the reader feels (this
        // was the era of "it finished and left an empty space").
        //
        // A line of `n` bytes takes `ceil(n / per_line)` rows and never fewer
        // than one. Bytes stand in for columns: this is an estimate, and a
        // multi-byte character only makes it a little bigger, never smaller.
        var rows: usize = 0;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            const line_rows: usize = if (per_line == 0 or line.len <= per_line)
                1
            else
                line.len / per_line + @intFromBool(line.len % per_line != 0);
            rows = satAdd(rows, line_rows);
        }
        // A fenced block adds rows the line count cannot see, but NOT the
        // three-per-marker this used to charge: the fence LINES themselves
        // become the top and bottom borders (1:1 with the rows already
        // counted), and the only extra row a closed block draws is its
        // language chip. Charging 3 per marker made a code-heavy answer
        // estimate six rows too tall per block, and an over-estimate is what
        // paints the black holes: above the lazy-parse threshold the
        // paragraph keeps this number as its height, so the scroll reserves
        // rows the text never fills.
        //
        // Walking the lines (and not counting "```" occurrences) keeps the
        // open/close state honest: an UNCLOSED fence (mid-stream) has no
        // closing line to become the bottom border, so it adds one more row
        // than a closed one.
        var extra: usize = 0;
        var in_block = false;
        var fit = std.mem.splitScalar(u8, text, '\n');
        while (fit.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (!std.mem.startsWith(u8, t, "```") and !std.mem.startsWith(u8, t, "~~~")) continue;
            if (in_block) {
                in_block = false; // the closing fence became the bottom border
            } else {
                in_block = true;
                if (t.len > 3) extra += 1; // ```zig -> the chip row
            }
        }
        if (in_block) extra += 1; // unclosed: a bottom border with no line behind it
        return @max(1, satAdd(rows, extra));
    }

    /// Parses and wraps a paragraph, and puts it in the cache with its height.
    ///
    /// ALWAYS the whole paragraph. An earlier version wrapped only the visible
    /// lines of long ones and kept the ESTIMATE as the height forever, and that
    /// was the last systematic hole in the transcript: an over-estimate reserved
    /// rows the text never filled (the black space), an under-estimate clipped
    /// the tail nobody had laid out (the erased output). The height is now,
    /// always, whatever the painter actually produced, so the two cannot
    /// disagree.
    fn layoutOne(
        self: *Model,
        ctx: vxfw.DrawContext,
        idx: usize,
        width: u16,
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

        var lines = try buildLinesBase(para_arena.allocator(), ctx, p_, width, self.nerd_icons);
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
    pub fn currentMaxOffset(self: *Model) usize {
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
            // A paragraph can shrink (e.g. collapsing an expanded tool result).
            // Keep the anchor offset within the paragraph's current height so the
            // viewport does not jump past it.
            if (self.anchor_para < self.para_heights.items.len) {
                const ph = self.para_heights.items[self.anchor_para];
                if (self.anchor_off > ph) self.anchor_off = ph;
            }
            first = self.anchorLine();
        }
        self.anchor = first;
        return .{ .first = first, .last = satAdd(first, @max(history_h, 1)), .total = t.total, .max_offset = t.max_offset };
    }

    /// The absolute line of the top of the view, from (paragraph, offset).
    pub fn anchorLine(self: *const Model) usize {
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
            // Only the rows of this paragraph that are INSIDE the window.
            //
            // It used to add the whole height, including the lines above
            // `first_visible` of the paragraph that straddles the top. Those
            // rows are not on screen, so they made the window look full one
            // paragraph too early and the last visible paragraph was never
            // parsed — it painted nothing, and its rows came out blank (the
            // turn summary under an answer, for one).
            const para_start = self.heightPrefix(p);
            const para_end = satAdd(para_start, self.para_heights.items[p]);
            const from = @max(para_start, first_visible);
            const to = @min(para_end, last_visible);
            lines_used = satAdd(lines_used, to -| from);
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
            // The whole paragraph, always: the height the parse leaves behind
            // (see `layoutOne`) is the painter's own line count, so the scroll
            // math and the screen cannot disagree — which is exactly what the
            // old lazy path, keeping the estimate above a row threshold, could
            // not guarantee (holes when over, clipped text when under).
            try self.layoutOne(ctx, idx, width);
            // Mark as recently used.
            if (self.seg_cache.items.len > 0) {
                self.seg_cache.items[self.seg_cache.items.len - 1].last_frame_used = self.frame_counter;
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
        // `tools/ui_frame` (`zig build ui-frame -Drun-args="--layout turn 96 30"`) and
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

    pub fn lock(self: *Model) void {
        while (!self.spin.tryLock()) std.Thread.yield() catch {};
    }
    pub fn unlock(self: *Model) void {
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

    pub fn askLock(self: *Model) void {
        while (!self.ask_mutex.tryLock()) std.Thread.yield() catch {};
    }
    pub fn askUnlock(self: *Model) void {
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
    pub fn freeAskStringsLocked(self: *Model) void {
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
            resetAutocomplete(self);
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
        const notice = std.mem.print(&self.catalog_notice_buf, "Loading {s} model catalog…", .{provider_id}) catch "";
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
        agent.resetModelPaletteRefreshThrottle();
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

    /// Enqueues a prompt as a normal turn (compatibility shim). Prefer
    /// `enqueueTurn` when the turn carries scoped rules or a non-normal mode.
    /// The text MUST be a copy already made by the caller (the queue owns and
    /// frees it).
    pub fn enqueuePrompt(self: *Model, text: []u8) usize {
        return self.enqueueTurn(.{ .text = text });
    }

    /// Enqueues a turn with its full context preserved. Losing mode/rules on
    /// queue would make a queued git workflow or pipeline turn run with wrong
    /// semantics (context leak).
    pub fn enqueueTurn(self: *Model, turn: QueuedTurn) usize {
        self.lock();
        defer self.unlock();
        self.queue.append(self.allocator, turn) catch {
            self.allocator.free(turn.text);
            return self.queue.items.len;
        };
        self.dirty = true;
        return self.queue.items.len;
    }

    /// Takes the next queued turn out of the queue. `null` if there is none.
    /// The caller owns `text` and must free it.
    pub fn takeQueued(self: *Model) ?QueuedTurn {
        self.lock();
        defer self.unlock();
        if (self.queue.items.len == 0) return null;
        const first = self.queue.orderedRemove(0);
        self.dirty = true;
        return first;
    }

    /// Takes the next queued turn ONLY when it is time to run one: the
    /// queue is not empty and no turn is in flight. The caller starts it.
    ///
    /// The gate lives here, and not inline in the tick, because the starting
    /// (`agent.startChat`) spawns threads and writes the session — nothing a
    /// unit test can call — while the GATE is exactly what regresses when a
    /// queued prompt is shown in the footer and never runs.
    pub fn takeQueuedWhenIdle(self: *Model) ?QueuedTurn {
        if (self.isBusy()) return null;
        return self.takeQueued();
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
        return self.queue.items[0].text;
    }

    /// Tenths of a second the current turn has been running. An instant is
    /// stored when streaming opens because `Timestamp.now` through the `Io`
    /// from draw is exactly what you don't want in the hot path.
    /// Hands the app's `Io` over. `runTui` calls it at startup.
    pub fn attachIo(self: *Model, io: std.Io) void {
        self.io = io;
        self.io_ready = true;
        self.refreshMotionEnv();
    }

    /// Reads motion preferences from the environment. Safe to call repeatedly.
    /// `ZODE_NO_ANIMATION=1|true|yes|on` disables decorative motion.
    /// `ZODE_REDUCED_MOTION=1|true|yes|on` avoids continuous motion.
    pub fn refreshMotionEnv(self: *Model) void {
        self.no_animation = agent.envTruthyIn(self.environ, "ZODE_NO_ANIMATION", false) or
            agent.envTruthyIn(self.environ, "NO_ANIMATION", false);
        self.reduced_motion = agent.envTruthyIn(self.environ, "ZODE_REDUCED_MOTION", false) or
            agent.envTruthyIn(self.environ, "REDUCED_MOTION", false) or
            self.no_animation;
    }

    pub fn motionAllowed(self: *const Model) bool {
        return !self.no_animation and !self.reduced_motion;
    }

    /// Mascot pose for rendering. Reduced/no animation returns a stable
    /// representative pose (frame 0, no lean, no jump hint) so status remains
    /// readable without continuous motion. Final state/correctness first.
    fn mascotPose(self: *Model, kind: mascot.StatusKind, now_ms: u64) mascot.Pose {
        // Note: setKind mutates animator clock; only meaningful in animated mode.
        if (self.no_animation or self.reduced_motion) {
            return .{ .text = mascot.face(kind), .hint = .none, .dx = 0 };
        }
        self.mascot_animator.setKind(kind, now_ms);
        return self.mascot_animator.pose(now_ms);
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
    pub fn workingLocked(self: *const Model) bool {
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
        for (self.queue.items) |item| self.allocator.free(item.text);
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
        self.cancelled = false;
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


    // ── tool calls in the timeline ─────────────────────────
    /// Header of a tool in progress: "⏺ Read(src/tui.zig)".
    /// Header of a tool: `⏺ write(hola.js)`.
    ///
    /// The name is marked with `*…*` so the parser paints it in the tool's
    /// bright color and the argument in the dim one. Without the mark, `write`
    /// and `hola.js` came out the same cyan and were indistinguishable.
    pub fn pushToolStart(self: *Model, tool: []const u8, arg: []const u8) void {
        // Timeline presentation: collapse control whitespace and cap very long
        // arguments so one tool line stays readable. The full argument is still
        // kept in `tool_run` state for live status/details.
        var arg_buf: [160]u8 = undefined;
        const display_arg = if (arg.len == 0)
            ""
        else blk: {
            const max_display: usize = 120;
            const limit = @min(arg.len, max_display);
            var n: usize = 0;
            var i: usize = 0;
            while (i < limit and n < arg_buf.len) : (i += 1) {
                const c = arg[i];
                arg_buf[n] = switch (c) {
                    '\n', '\r', '\t' => ' ',
                    else => if (c < 0x20) ' ' else c,
                };
                n += 1;
            }
            if (arg.len > max_display) {
                // Avoid cutting inside a UTF-8 continuation byte.
                while (n > 0 and (arg_buf[n - 1] & 0xc0) == 0x80) n -= 1;
                if (n > 0 and arg_buf[n - 1] >= 0x80 and (arg_buf[n - 1] & 0xc0) != 0xc0) n -= 1;
                if (n + 3 <= arg_buf.len) {
                    @memcpy(arg_buf[n..][0..3], "...");
                    n += 3;
                }
            }
            break :blk arg_buf[0..n];
        };

        const line = if (display_arg.len == 0)
            std.fmt.allocPrint(self.allocator, "*{s}*", .{tool}) catch return
        else
            std.fmt.allocPrint(self.allocator, "*{s}*({s})", .{ tool, display_arg }) catch return;
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

    /// A tool result: "│  Read 1006 lines · 3ms · ^R". Stores the
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
        var head_buf: [180]u8 = undefined;
        const raw_head: []const u8 = if (summary.len > 0) summary else tool;
        // Keep the timeline result on one readable line; full details remain in
        // the expandable result.
        const head = blk: {
            const max_head: usize = 140;
            const limit = @min(raw_head.len, max_head);
            var n: usize = 0;
            var i: usize = 0;
            while (i < limit and n < head_buf.len) : (i += 1) {
                const c = raw_head[i];
                head_buf[n] = switch (c) {
                    '\n', '\r', '\t' => ' ',
                    else => if (c < 0x20) ' ' else c,
                };
                n += 1;
            }
            if (raw_head.len > max_head) {
                while (n > 0 and (head_buf[n - 1] & 0xc0) == 0x80) n -= 1;
                if (n > 0 and head_buf[n - 1] >= 0x80 and (head_buf[n - 1] & 0xc0) != 0xc0) n -= 1;
                if (n + 3 <= head_buf.len) {
                    @memcpy(head_buf[n..][0..3], "...");
                    n += 3;
                }
            }
            break :blk head_buf[0..n];
        };
        // Clear failure marker for tool outputs (presentation only). Never hide
        // errors: collapsed summaries still show this text and ^R expands details.
        var fail_head_buf: [184]u8 = undefined;
        const display_head: []const u8 = blk: {
            const s = std.mem.trimStart(u8, head, " \t");
            if (s.len == 0) break :blk head;
            // UTF-8 ✗ is 3 bytes; also accept ASCII markers.
            if (std.mem.startsWith(u8, s, "\xe2\x9c\x97") or std.mem.startsWith(u8, s, "!")) break :blk head;
            const prefixes = [_][]const u8{ "error", "denied", "refused", "failed", "panic", "aborted", "killed" };
            for (prefixes) |pfx| {
                if (s.len >= pfx.len and std.ascii.eqlIgnoreCase(s[0..pfx.len], pfx)) {
                    const boundary = if (s.len == pfx.len)
                        true
                    else blk_b: {
                        const c = s[pfx.len];
                        break :blk_b (c == ':' or c == ' ' or c == ',' or c == '!' or c == '.');
                    };
                    if (boundary) {
                        break :blk std.mem.print(&fail_head_buf, "\xe2\x9c\x97 {s}", .{head}) catch head;
                    }
                }
            }
            break :blk head;
        };
        // Marked summary and dim time: you read "what happened" and then "how
        // long it took" without them mixing. When the full result differs from
        // the summary, append a Ctrl+R hint so the user knows the tool result
        // is condensed and can be expanded to the full transcript.
        const can_expand = result.len > 0 and !std.mem.eql(u8, result, summary);
        const line = if (can_expand)
            std.mem.print(&line_buf, "*{s}* · {d}ms · ^R", .{ display_head, ms }) catch display_head
        else
            std.mem.print(&line_buf, "*{s}* · {d}ms", .{ display_head, ms }) catch display_head;

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
        return self.pushDiffLang(before, after, "", "");
    }

    /// Like `pushDiffLang` but also emits a compact file-change card using the
    /// file path and real diff statistics. The card is shown before the diff so
    /// the change is scannable.
    ///
    /// Net diff is honest: on the first edit of a path in the current turn, the
    /// operation's `before` is stored as a bounded baseline. Subsequent edits of
    /// the same path compute and display the real net diff from that baseline to
    /// the new `after` content. If baseline storage is unavailable (caps or
    /// allocation failure), this falls back to the real operation diff without
    /// inventing net stats.
    pub fn pushFileDiff(self: *Model, before: []const u8, after: []const u8, path: []const u8) DiffCounts {
        return self.pushFileDiffOp(before, after, path, .modified);
    }

    /// Returns the last changed file path, if any (structured state, not parsed UI).
    pub fn lastChangedFile(self: *const Model) ?[]const u8 {
        if (self.last_changed_file_len == 0) return null;
        return self.last_changed_file[0..self.last_changed_file_len];
    }

    /// Focused file-intelligence entry (runtime state), or the most recent one.
    pub fn focusedFileIntel(self: *const Model) ?*const FileIntelEntry {
        if (self.file_intel_len == 0) return null;
        const idx = self.file_focus orelse (self.file_intel_len - 1);
        if (idx >= self.file_intel_len) return &self.file_intel[self.file_intel_len - 1];
        return &self.file_intel[idx];
    }

    pub fn focusedFilePath(self: *const Model) ?[]const u8 {
        const e = self.focusedFileIntel() orelse return self.lastChangedFile();
        const p = e.pathOf();
        return if (p.len > 0) p else self.lastChangedFile();
    }

    pub fn clearFileIntel(self: *Model) void {
        self.file_intel_len = 0;
        self.file_focus = null;
    }

    fn recordFileIntel(
        self: *Model,
        path: []const u8,
        diff_para: ?usize,
        added: usize,
        removed: usize,
        is_net: bool,
        op: filechange.Operation,
    ) void {
        if (path.len == 0 or path.len > filesview.path_max) return;
        if (self.file_intel_len >= max_file_intel) {
            // Keep the newest entries: drop the oldest so navigation stays useful.
            const keep = max_file_intel - 1;
            std.mem.copyForwards(FileIntelEntry, self.file_intel[0..keep], self.file_intel[1..self.file_intel_len]);
            self.file_intel_len = keep;
            if (self.file_focus) |f| {
                self.file_focus = if (f == 0) 0 else f - 1;
            }
        }
        const idx = self.file_intel_len;
        var e = &self.file_intel[idx];
        @memcpy(e.path[0..path.len], path);
        e.path_len = @intCast(path.len);
        e.diff_para = diff_para;
        e.added = @intCast(@min(added, std.math.maxInt(u32)));
        e.removed = @intCast(@min(removed, std.math.maxInt(u32)));
        e.is_net = is_net;
        e.op = op;
        self.file_intel_len = idx + 1;
        // Focus follows the latest change by default (matches "last changed").
        self.file_focus = idx;
    }

    fn fileIntelLabel(self: *const Model, path: []const u8) struct { has: bool, label: []const u8 } {
        _ = self;
        const chip = lang_icons.forPath(path, false);
        const base = filechange.pathParts(path).base;
        const has = chip.label.len > 0 and !std.mem.eql(u8, chip.label, base);
        return .{ .has = has, .label = chip.label };
    }

    fn fileIntelOpWord(e: *const FileIntelEntry) []const u8 {
        return if (e.is_net) "net" else switch (e.op) {
            .created => "created",
            .deleted => "deleted",
            .renamed => "renamed",
            .restored => "restored",
            else => "changed",
        };
    }

    fn showFileIntelFocus(self: *Model, idx: usize, jump: bool) bool {
        if (idx >= self.file_intel_len) return false;
        self.file_focus = idx;
        const e = &self.file_intel[idx];
        const path = e.pathOf();
        const n = self.file_intel_len;

        if (path.len > 0 and path.len <= self.last_changed_file.len) {
            @memcpy(self.last_changed_file[0..path.len], path);
            self.last_changed_file_len = @intCast(path.len);
        }

        if (jump) {
            if (e.diff_para) |ti| {
                self.ensureParaHeights();
                self.lock();
                const lt = self.last_tool;
                const needs_expand = if (lt) |t| t.diff_para_idx == ti and !t.diff_expanded else false;
                self.scrollTo(self.heightPrefix(ti));
                self.follow_bottom = false;
                self.anchor_para = ti;
                self.anchor_off = 0;
                self.dirty = true;
                self.redraw_requested.store(true, .seq_cst);
                self.unlock();
                if (needs_expand) {
                    _ = self.toggleLastTool();
                    self.ensureParaHeights();
                    self.scrollTo(self.heightPrefix(ti));
                }
            }
        }

        const info = self.fileIntelLabel(path);
        const op_word = fileIntelOpWord(e);
        var path_buf: [200]u8 = undefined;
        const shown_path = filechange.shortenPathInto(&path_buf, path, 56);
        if (e.added == 0 and e.removed == 0) {
            if (info.has)
                self.pushInfoFmt("  [{d}/{d}] {s} [{s}] {s}  (unchanged)", .{ idx + 1, n, op_word, info.label, shown_path })
            else
                self.pushInfoFmt("  [{d}/{d}] {s} {s}  (unchanged)", .{ idx + 1, n, op_word, shown_path });
        } else {
            if (info.has)
                self.pushInfoFmt("  [{d}/{d}] {s} [{s}] {s}  +{d} -{d}", .{ idx + 1, n, op_word, info.label, shown_path, e.added, e.removed })
            else
                self.pushInfoFmt("  [{d}/{d}] {s} {s}  +{d} -{d}", .{ idx + 1, n, op_word, shown_path, e.added, e.removed });
        }
        return true;
    }

    /// Jump to and report the currently focused file-intelligence entry.
    pub fn showFocusedFileIntel(self: *Model) bool {
        if (self.file_intel_len == 0) return false;
        const idx = self.file_focus orelse (self.file_intel_len - 1);
        return self.showFileIntelFocus(@min(idx, self.file_intel_len - 1), true);
    }

    /// List tracked file-intelligence entries (compact, navigable state).
    pub fn pushFileIntelList(self: *Model) bool {
        const n = self.file_intel_len;
        if (n == 0) {
            self.pushInfo("file: no changed files in this session");
            return false;
        }
        const focus = @min(self.file_focus orelse (n - 1), n - 1);
        self.pushInfoFmt("file changes  ({d})", .{n});
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const e = &self.file_intel[i];
            const path = e.pathOf();
            const marker: []const u8 = if (i == focus) ">" else " ";
            const info = self.fileIntelLabel(path);
            const op_word = fileIntelOpWord(e);
            var path_buf: [200]u8 = undefined;
            const shown_path = filechange.shortenPathInto(&path_buf, path, 52);
            if (e.added == 0 and e.removed == 0) {
                if (info.has)
                    self.pushInfoFmt("{s} [{d}] {s} [{s}] {s}  (unchanged)", .{ marker, i + 1, op_word, info.label, shown_path })
                else
                    self.pushInfoFmt("{s} [{d}] {s} {s}  (unchanged)", .{ marker, i + 1, op_word, shown_path });
            } else {
                if (info.has)
                    self.pushInfoFmt("{s} [{d}] {s} [{s}] {s}  +{d} -{d}", .{ marker, i + 1, op_word, info.label, shown_path, e.added, e.removed })
                else
                    self.pushInfoFmt("{s} [{d}] {s} {s}  +{d} -{d}", .{ marker, i + 1, op_word, shown_path, e.added, e.removed });
            }
        }
        self.pushInfo("  /file next|prev · /file show · /file copy|open");
        return true;
    }

    /// Navigate file-intelligence entries (changed files/diffs) and focus one.
    /// Scrolls to its diff (expanding when it is the tracked collapsed diff),
    /// updates the focused file path for actions, and reports position/stats.
    pub fn navigateFileIntel(self: *Model, delta: i8) bool {
        if (self.file_intel_len == 0) {
            self.pushInfo("file: no changed files in this session");
            return false;
        }
        const cur = self.file_focus orelse (self.file_intel_len - 1);
        const n = self.file_intel_len;
        const next_idx: usize = if (delta > 0)
            if (cur + 1 < n) cur + 1 else 0
        else if (cur == 0) n - 1 else cur - 1;
        return self.showFileIntelFocus(next_idx, true);
    }

    pub fn pushFileDiffOp(
        self: *Model,
        before: []const u8,
        after: []const u8,
        path: []const u8,
        operation: filechange.Operation,
    ) DiffCounts {
        const lang = langFromPath(path);
        if (path.len > 0 and path.len <= self.last_changed_file.len) {
            @memcpy(self.last_changed_file[0..path.len], path);
            self.last_changed_file_len = @intCast(path.len);
        }

        // Under lock: resolve/create baseline for honest net diffs.
        // Copy baseline bytes out before diffing so we never hold the model lock
        // across diff computation or rendering (pushInfoFmt/pushDiffLang lock).
        var baseline_copy: ?[]u8 = null;
        var is_net = false;
        var first_card = false;
        var can_record_net = false;
        self.lock();
        const existing = self.netBaselineFor(path);
        if (existing) |base| {
            baseline_copy = self.allocator.dupe(u8, base) catch null;
            if (baseline_copy != null) {
                is_net = true;
                can_record_net = true;
            }
            // If copy failed, fall back to operation diff and keep prior net stats.
        } else {
            self.noteNetBaseline(path, before);
            if (self.netBaselineFor(path) != null) can_record_net = true;
            // Check if a card was already shown for this path this turn (defensive).
            var seen = false;
            var i: usize = 0;
            while (i < self.turn_file_cards.count()) : (i += 1) {
                if (std.mem.eql(u8, self.turn_file_cards.at(i), path)) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                self.turn_file_cards.note(path);
                first_card = true;
            }
        }
        self.unlock();
        defer if (baseline_copy) |b| self.allocator.free(b);

        const diff_from = if (is_net) baseline_copy.? else before;
        const dc = self.peekDiffCounts(diff_from, after);

        // Record honest net stats for grouped summaries when the diff is
        // relative to the turn baseline (or operation==net on first edit).
        if (can_record_net) {
            self.lock();
            self.updateNetBaselineStats(path, dc);
            self.unlock();
        }

        // Card policy: show the first operation card, and show net cards on
        // subsequent edits (honest cumulative state vs original baseline).
        // If net becomes empty, still report it explicitly — but compactly.
        const show_card = first_card or is_net;
        var pre_count: usize = 0;
        self.lock();
        pre_count = self.paras.items.len + self.pending.items.len;
        self.unlock();
        if (show_card) {
            const chip = lang_icons.forPath(path, false);
            const base = filechange.pathParts(path).base;
            const has_label = chip.label.len > 0 and !std.mem.eql(u8, chip.label, base);
            const op_word: []const u8 = if (is_net) "net" else switch (operation) {
                .created => "created",
                .deleted => "deleted",
                .renamed => "renamed",
                .restored => "restored",
                else => "changed",
            };
            var path_buf: [200]u8 = undefined;
            const shown_path = filechange.shortenPathInto(&path_buf, path, 64);
            if (is_net and dc.added == 0 and dc.removed == 0) {
                if (has_label)
                    self.pushInfoFmt("  {s} [{s}] {s}  (unchanged)", .{ op_word, chip.label, shown_path })
                else
                    self.pushInfoFmt("  {s} {s}  (unchanged)", .{ op_word, shown_path });
            } else if (is_net or dc.added > 0 or dc.removed > 0) {
                if (has_label)
                    self.pushInfoFmt("  {s} [{s}] {s}  +{d} -{d}", .{ op_word, chip.label, shown_path, dc.added, dc.removed })
                else
                    self.pushInfoFmt("  {s} {s}  +{d} -{d}", .{ op_word, shown_path, dc.added, dc.removed });
            }
        }

        _ = self.pushDiffLang(diff_from, after, lang, path);

        // Record structured file-intelligence entry for focus/navigation/actions.
        if (show_card or dc.added > 0 or dc.removed > 0) {
            const expected_diff = pre_count + @as(usize, if (show_card) 1 else 0);
            var focus_para: ?usize = null;
            self.lock();
            if (self.last_tool) |lt| {
                if (lt.diff_para_idx) |dpi| {
                    if (dpi == expected_diff and lt.diff_path.len > 0 and std.mem.eql(u8, lt.diff_path, path)) {
                        focus_para = dpi;
                    }
                }
            }
            self.unlock();
            if (focus_para == null and show_card) focus_para = pre_count;
            self.recordFileIntel(path, focus_para, dc.added, dc.removed, is_net, operation);
        }
        return dc;
    }

    fn peekDiffCounts(self: *Model, before: []const u8, after: []const u8) DiffCounts {
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
        return .{ .added = added, .removed = removed };
    }

    fn langFromPath(path: []const u8) []const u8 {
        const ext = std.fs.path.extension(path);
        if (ext.len > 1) return ext[1..];
        return std.fs.path.basename(path);
    }

    pub fn pushDiffLang(
        self: *Model,
        before: []const u8,
        after: []const u8,
        lang: []const u8,
        path: []const u8,
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
            var hunks: usize = 0;
            for (diff_lines) |l| {
                if (std.mem.startsWith(u8, l, "@@ -")) hunks += 1;
            }
            var s: std.ArrayList(u8) = .empty;
            if (hunks > 0)
                s.print(arena, "diff preview · +{d} −{d} · {d} hunk{s}\n", .{ added, removed, hunks, if (hunks == 1) "" else "s" }) catch {}
            else
                s.print(arena, "diff preview · +{d} −{d}\n", .{ added, removed }) catch {};
            for (diff_lines[0..diff_preview_lines], 0..) |l, i| {
                if (i > 0 or s.items.len > 0) s.append(arena, '\n') catch break;
                s.appendSlice(arena, l) catch break;
            }
            s.print(
                arena,
                "\n… {d} more lines  ·  Ctrl+R to expand",
                .{diff_lines.len - diff_preview_lines},
            ) catch {};
            if (s.items.len > 0) short = s.items;
        }

        // The WORD-level diff is painted when the paragraph shows the whole
        // diff. A preview is a summary, and a word-level highlight inside a
        // summary is confetti: the reader cannot see the whole change, so
        // which words changed inside those twelve rows is noise.
        self.pushDiffKind(joined.items, short, lang, path, short == null);
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
    fn pushDiffKind(self: *Model, text: []const u8, short: ?[]const u8, lang: []const u8, path: []const u8, word_diff: bool) void {
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
        const path_copy: []u8 = if (path.len > 0)
            (gpa.dupe(u8, path) catch gpa.dupe(u8, "") catch @constCast(@as([]const u8, "")))
        else
            (gpa.dupe(u8, "") catch @constCast(@as([]const u8, "")));

        self.lock();
        defer self.unlock();
        self.hunk_nav_para = null;
        self.hunk_nav_idx = null;
        const idx = self.paras.items.len + self.pending.items.len;
        self.pending.append(self.allocator, .{
            .kind = .diff,
            .text = text_copy,
            .lang = lang_copy,
            .word_diff = word_diff,
        }) catch {
            gpa.free(text_copy);
            gpa.free(lang_copy);
            if (path_copy.len > 0) gpa.free(path_copy);
            freeDiffMemoParts(gpa, keep_full, keep_short);
            return;
        };
        // Track diff for Ctrl+R (collapsed) and hunk navigation (any diff).
        if (self.last_tool) |*lt| {
            // Always keep full text for hunk navigation.
            const nav_full = if (collapsed)
                keep_full
            else
                gpa.dupe(u8, text) catch &.{};
            if (lt.diff_full.len > 0) gpa.free(lt.diff_full);
            if (lt.diff_short.len > 0) gpa.free(lt.diff_short);
            if (lt.diff_path.len > 0) gpa.free(lt.diff_path);
            lt.diff_para_idx = idx;
            lt.diff_full = if (nav_full.len > 0) @constCast(nav_full) else @constCast(@as([]const u8, &.{}));
            lt.diff_short = if (collapsed) keep_short else @constCast(@as([]const u8, &.{}));
            lt.diff_path = @constCast(path_copy);
            lt.diff_expanded = !collapsed;
            if (collapsed) {
                keep_full = &.{}; // ownership moved to lt.diff_full
                keep_short = &.{};
            } else if (nav_full.len > 0) {
                // nav_full is a separate copy for non-collapsed case
            }
            // path_copy ownership moved to lt.diff_path (even if empty, it's &.{}).
        } else if (path_copy.len > 0) {
            gpa.free(path_copy);
        }
        freeDiffMemoParts(gpa, keep_full, keep_short);
        self.dirty = true;
        self.redraw_requested.store(true, .seq_cst);
    }

    fn freeDiffMemoParts(gpa: std.mem.Allocator, full: []u8, short: []u8) void {
        if (full.len > 0) gpa.free(full);
        if (short.len > 0) gpa.free(short);
    }

    /// Navigate between diff paragraphs in the timeline (Phase 3 file/diff
    /// navigation foundation). Scrolls to the target diff and reports position.
    /// Presentation-only navigation: history and runtime state are unchanged.
    pub fn navigateDiff(self: *Model, delta: i8) bool {
        self.ensureParaHeights();
        self.lock();
        var count: usize = 0;
        for (self.paras.items) |p| {
            if (p.kind == .diff) count += 1;
        }
        if (count == 0) {
            self.unlock();
            self.pushInfo("Diff nav: no diff blocks in the timeline");
            return false;
        }
        const cur_para = if (self.follow_bottom and self.paras.items.len > 0)
            self.paras.items.len - 1
        else
            @min(self.anchor_para, if (self.paras.items.len == 0) 0 else self.paras.items.len - 1);

        var target: ?usize = null;
        var target_ord: usize = 0;
        if (delta > 0) {
            // Next diff after the current position; wrap to first.
            var ord: usize = 0;
            for (self.paras.items, 0..) |p, i| {
                if (p.kind != .diff) continue;
                ord += 1;
                if (i > cur_para) {
                    target = i;
                    target_ord = ord;
                    break;
                }
            }
            if (target == null) {
                ord = 0;
                for (self.paras.items, 0..) |p, i| {
                    if (p.kind != .diff) continue;
                    ord += 1;
                    target = i;
                    target_ord = ord;
                    break;
                }
            }
        } else {
            // Previous diff before the current position; wrap to last.
            var ord: usize = 0;
            var last: ?struct { i: usize, ord: usize } = null;
            for (self.paras.items, 0..) |p, i| {
                if (p.kind != .diff) continue;
                ord += 1;
                if (i < cur_para) last = .{ .i = i, .ord = ord };
            }
            if (last) |l| {
                target = l.i;
                target_ord = l.ord;
            } else {
                ord = 0;
                for (self.paras.items, 0..) |p, i| {
                    if (p.kind != .diff) continue;
                    ord += 1;
                    target = i;
                    target_ord = ord;
                }
            }
        }

        const ti = target orelse {
            self.unlock();
            return false;
        };
        // Expand collapsed diff if this target is the tracked last diff.
        const lt = self.last_tool;
        const needs_expand = if (lt) |t| t.diff_para_idx == ti and !t.diff_expanded else false;
        self.ensureParaHeights();
        const target_line = self.heightPrefix(ti);
        self.scrollTo(target_line);
        self.follow_bottom = false;
        self.anchor_para = ti;
        self.anchor_off = 0;
        self.anchor = target_line;
        self.dirty = true;
        self.redraw_requested.store(true, .seq_cst);
        self.unlock();

        if (needs_expand) {
            _ = self.toggleLastTool();
            // Expanding changes paragraph height; re-scroll to the diff.
            self.ensureParaHeights();
            self.scrollTo(self.heightPrefix(ti));
        }
        self.pushInfoFmt("Diff {d}/{d}  (use /diff next|prev)", .{ target_ord, count });
        return true;
    }

    /// Navigate to next/prev hunk in the last diff (Phase 3). Expands the diff
    /// when collapsed. Scrolls to the diff paragraph and reports hunk position.
    pub fn navigateLastDiffHunk(self: *Model, delta: i8) bool {
        // Expand collapsed diff first (toggleLastTool manages locking).
        {
            self.lock();
            const lt = self.last_tool;
            const needs_expand = if (lt) |t| t.hasDiff() and !t.diff_expanded else false;
            self.unlock();
            if (needs_expand) _ = self.toggleLastTool();
        }

        self.lock();
        const lt = self.last_tool orelse {
            self.unlock();
            self.pushInfo("Hunk nav: no active diff (expand or run a file edit first)");
            return false;
        };
        if (!lt.hasNavigableDiff()) {
            self.unlock();
            self.pushInfo("Hunk nav: no active diff (expand or run a file edit first)");
            return false;
        }
        const para_idx = lt.diff_para_idx.?;
        const full = lt.diff_full;
        // Parse hunks from full diff text.
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var lines_list: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, full, '\n');
        while (it.next()) |line| lines_list.append(arena, line) catch {
            self.unlock();
            self.pushError("Hunk nav: out of memory");
            return false;
        };
        const parsed = diffhunks.parse(arena, lines_list.items) catch {
            self.unlock();
            self.pushError("Hunk nav: could not parse diff hunks");
            return false;
        };
        if (parsed.count() == 0) {
            self.unlock();
            self.pushInfo("Hunk nav: no hunks in diff");
            return false;
        }
        const cur = if (self.hunk_nav_para == para_idx) self.hunk_nav_idx else null;
        const next_idx = if (delta > 0) parsed.next(cur) else parsed.prev(cur);
        const idx = next_idx orelse {
            self.unlock();
            return false;
        };
        const boundary = if (cur) |c| c == idx else false;
        const h = parsed.at(idx).?;
        var path_buf: [filesview.path_max]u8 = undefined;
        var path_len: usize = 0;
        if (self.last_tool) |lt2| {
            if (lt2.diff_path.len > 0) {
                path_len = @min(lt2.diff_path.len, path_buf.len);
                @memcpy(path_buf[0..path_len], lt2.diff_path[0..path_len]);
            }
        }
        self.hunk_nav_para = para_idx;
        self.hunk_nav_idx = idx;
        // Best-effort scroll to the selected hunk header. `header_line` is the
        // 0-based unified-diff line index; rendered rows can differ with
        // wrapping/word-diff layout, so this is approximate and clamped by
        // scroll bounds. Precise layout-aware focus is a follow-up.
        self.ensureParaHeights();
        const para_start = if (para_idx < self.para_heights.items.len) self.heightPrefix(para_idx) else 0;
        const para_h = if (para_idx < self.para_heights.items.len) self.para_heights.items[para_idx] else 0;
        const approx_off: usize = @min(h.header_line, if (para_h > 0) para_h - 1 else h.header_line);
        const target_line = para_start + approx_off;
        self.scrollTo(target_line);
        self.follow_bottom = false;
        self.anchor_para = para_idx;
        self.anchor_off = 0;
        self.anchor = target_line;
        self.dirty = true;
        self.redraw_requested.store(true, .seq_cst);
        self.unlock();

        const path = path_buf[0..path_len];
        if (boundary) {
            if (path.len > 0)
                self.pushInfoFmt("Hunk {d}/{d} (boundary)  {s}  @@ -{d},{d} +{d},{d} @@  (/hunk next|prev)", .{
                    idx + 1, parsed.count(), path, h.old_start, h.old_count, h.new_start, h.new_count,
                })
            else
                self.pushInfoFmt("Hunk {d}/{d} (boundary)  @@ -{d},{d} +{d},{d} @@  (/hunk next|prev)", .{
                    idx + 1, parsed.count(), h.old_start, h.old_count, h.new_start, h.new_count,
                });
        } else {
            if (path.len > 0)
                self.pushInfoFmt("Hunk {d}/{d}  {s}  @@ -{d},{d} +{d},{d} @@  (Alt+] next, Alt+[ prev)", .{
                    idx + 1, parsed.count(), path, h.old_start, h.old_count, h.new_start, h.new_count,
                })
            else
                self.pushInfoFmt("Hunk {d}/{d}  @@ -{d},{d} +{d},{d} @@  (Alt+] next, Alt+[ prev)", .{
                    idx + 1, parsed.count(), h.old_start, h.old_count, h.new_start, h.new_count,
                });
        }
        return true;
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
        self.clearNetBaselinesLocked();
        self.turn_file_cards.clear();
        self.checkpoints.begin(label);
    }

    fn clearNetBaselinesLocked(self: *Model) void {
        var i: usize = 0;
        while (i < self.net_baselines_len) : (i += 1) {
            if (self.net_baselines[i].baseline) |b| self.allocator.free(b);
            self.net_baselines[i] = .{};
        }
        self.net_baselines_len = 0;
        self.net_baselines_bytes = 0;
    }

    fn updateNetBaselineStats(self: *Model, path: []const u8, dc: DiffCounts) void {
        var i: usize = 0;
        while (i < self.net_baselines_len) : (i += 1) {
            const nb = &self.net_baselines[i];
            if (std.mem.eql(u8, nb.path[0..nb.path_len], path)) {
                nb.net_added = dc.added;
                nb.net_removed = dc.removed;
                nb.has_stats = true;
                return;
            }
        }
    }


    fn netBaselineFor(self: *Model, path: []const u8) ?[]const u8 {
        var i: usize = 0;
        while (i < self.net_baselines_len) : (i += 1) {
            const nb = &self.net_baselines[i];
            const p = nb.path[0..nb.path_len];
            if (std.mem.eql(u8, p, path)) return nb.baseline;
        }
        return null;
    }

    fn noteNetBaseline(self: *Model, path: []const u8, before: []const u8) void {
        if (path.len == 0 or path.len > filesview.path_max) return;
        if (self.netBaselineFor(path) != null) return;
        if (self.net_baselines_len >= max_net_baselines) return;
        if (before.len > max_net_baseline_file) return;
        if (self.net_baselines_bytes + before.len > max_net_baseline_total) return;
        const copy = self.allocator.dupe(u8, before) catch return;
        var nb = &self.net_baselines[self.net_baselines_len];
        nb.* = .{};
        @memcpy(nb.path[0..path.len], path);
        nb.path_len = @intCast(path.len);
        nb.baseline = copy;
        self.net_baselines_len += 1;
        self.net_baselines_bytes += copy.len;
    }

    /// Appends a compact grouped summary of turn-scoped file changes with honest
    /// net stats (from real baseline->after diffs). Returns false when there is
    /// nothing to report or output could not be produced.
    pub fn appendTurnFileSummary(self: *Model, out: *std.ArrayList(u8), gpa: std.mem.Allocator) bool {
        self.lock();
        defer self.unlock();
        if (self.net_baselines_len == 0) return false;
        var total_added: usize = 0;
        var total_removed: usize = 0;
        var files: usize = 0;
        var i: usize = 0;
        while (i < self.net_baselines_len) : (i += 1) {
            if (!self.net_baselines[i].has_stats) continue;
            files += 1;
            total_added += self.net_baselines[i].net_added;
            total_removed += self.net_baselines[i].net_removed;
        }
        if (files == 0) return false;
        out.appendSlice(gpa, "files (turn net)\n") catch return false;
        i = 0;
        while (i < self.net_baselines_len) : (i += 1) {
            const nb = &self.net_baselines[i];
            if (!nb.has_stats) continue;
            const path = nb.path[0..nb.path_len];
            const chip = lang_icons.forPath(path, false);
            const base = filechange.pathParts(path).base;
            const has_label = chip.label.len > 0 and !std.mem.eql(u8, chip.label, base);
            var path_buf: [200]u8 = undefined;
            const shown_path = filechange.shortenPathInto(&path_buf, path, 64);
            if (nb.net_added == 0 and nb.net_removed == 0) {
                if (has_label)
                    out.print(gpa, "  net [{s}] {s}  (unchanged)\n", .{ chip.label, shown_path }) catch return false
                else
                    out.print(gpa, "  net {s}  (unchanged)\n", .{shown_path}) catch return false;
            } else {
                if (has_label)
                    out.print(gpa, "  net [{s}] {s}  +{d} -{d}\n", .{ chip.label, shown_path, nb.net_added, nb.net_removed }) catch return false
                else
                    out.print(gpa, "  net {s}  +{d} -{d}\n", .{ shown_path, nb.net_added, nb.net_removed }) catch return false;
            }
        }
        out.print(gpa, "  total  {d} file{s}  +{d} -{d}", .{ files, if (files == 1) "" else "s", total_added, total_removed }) catch return false;
        return true;
    }

    pub fn pushTurnFileSummary(self: *Model) void {
        var out: std.ArrayList(u8) = .empty;
        defer self.allocator.free(out.allocatedSlice());
        if (self.appendTurnFileSummary(&out, self.allocator)) {
            self.pushInfoOwned(out.toOwnedSlice(self.allocator) catch return);
            return;
        }
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

    /// Adds a verified fact. Returns true when the store changed (add
    /// dedupes, so a repeated verdict is no event).
    pub fn addFact(self: *Model, kind: facts_mod.Kind, text: []const u8, source: []const u8, source_hash: u64) bool {
        self.lock();
        defer self.unlock();
        return self.facts.add(kind, text, source, source_hash);
    }

    /// Copy of the store for the turn loop (a value with fixed buffers:
    /// a memcpy, like `planCopy`).
    pub fn factsCopy(self: *Model) facts_mod.Store {
        self.lock();
        defer self.unlock();
        return self.facts;
    }

    /// Forgets every fact. Facts belong to the session: a new or resumed
    /// session starts empty, exactly like the read cache and the plan.
    pub fn clearFacts(self: *Model) void {
        self.lock();
        defer self.unlock();
        self.facts.clear();
    }

    /// Drops the facts whose source file changed (see `facts.Store`).
    /// Returns how many were removed.
    pub fn invalidateFactSource(self: *Model, path: []const u8, new_hash: u64) usize {
        self.lock();
        defer self.unlock();
        return self.facts.invalidateSource(path, new_hash);
    }

    /// Drops the project-wide verdicts (check pass/fail): the project
    /// changed under them. Returns how many were removed.
    pub fn invalidateProjectFacts(self: *Model) usize {
        self.lock();
        defer self.unlock();
        return self.facts.invalidateProject();
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
        const born_ms = if (hubo_nuevo) self.nowMs() else 0;
        for (self.pending.items) |p| {
            self.paras.append(self.allocator, .{
                .kind = p.kind,
                .text = p.text,
                .base = p.base,
                .mood = p.mood,
                .lang = p.lang,
                .born_ms = born_ms,
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

    }

    /// Empties the visible history (Ctrl+L). The cached paragraphs are freed
    /// and the on-disk session is left alone. The plan block goes with the
    /// transcript: a checklist written next to paragraphs that no longer
    /// exist is orphaned noise above the input.
    pub fn clearHistory(self: *Model) void {
        self.clearSegCache();
        for (self.paras.items) |p| freePara(self.allocator, p);
        self.paras.clearRetainingCapacity();
        self.anchor = 0;
        self.anchor_para = 0;
        self.anchor_off = 0;
        self.follow_bottom = true;
        self.clearFileIntel();
        self.last_changed_file_len = 0;
        self.lock();
        defer self.unlock();
        self.plan.clear();
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

    pub fn activity(self: *Model) Activity {
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
            // The alt screen hides stderr. A dead tick timer looks like a
            // frozen app, so say it where the user is looking.
            self.pushNotification("redraw clock failed - press a key to refresh");
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
    ///
    /// Phase 4 (reduced/no animation): continuous mascot motion ticks are
    /// disabled; the loop keeps worker-wakeup cadence only.
    fn tickInterval(self: *Model) u32 {
        const a = self.activity();
        var cap: u32 = if (a.busy or a.dirty) 40 else 120;
        if (self.no_animation or self.reduced_motion) return cap;
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
        if (self.no_animation or self.reduced_motion) return false;
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

    pub fn scrollTo(self: *Model, first_line: usize) void {
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
        if (!self.show_prompt_dots) {
            self.prompt_dot_hover = null;
            return;
        }
        // The rail lives in the right margin, one column left of the
        // scrollbar (scrollbar is at width-1). Below 12 columns there is no
        // margin left to use, and drawing there would paint over the text.
        self.prompt_dot_col = if (width >= 12) width - 2 else 0;
        if (self.prompt_dot_col == 0 or history_h == 0) {
            self.prompt_dot_hover = null;
            return;
        }
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
        if (!self.show_prompt_dots) return null;
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
    pub fn unseenTurns(self: *const Model) usize {
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
                cell.style.bold = true;
                cell.style.fg = theme.selected.fg;
                surface.writeCell(col, row, cell);
            }
        }
    }

    /// Push a transient notification (33.9). Absolutely positioned; no layout shift.
    /// Keeps a bounded queue (drops the oldest when full). Safe to call from UI thread.
    pub fn pushNotification(self: *Model, text: []const u8) void {
        if (text.len == 0) return;
        if (self.notification_len == max_notifications) {
            // Drop oldest: shift left.
            var i: usize = 1;
            while (i < self.notification_len) : (i += 1) {
                self.notifications[i - 1] = self.notifications[i];
            }
            self.notification_len -= 1;
        }
        var n = &self.notifications[self.notification_len];
        const nlen = @min(text.len, n.text.len);
        @memcpy(n.text[0..nlen], text[0..nlen]);
        n.len = nlen;
        n.frames = 240; // ~4s at 60fps
        self.notification_len += 1;
        self.requestRedraw();
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
        self.copy_toast_frames = 60; // ~1 s at 60 fps
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
                // Saving/removing the key is I/O: the agent does it. The palette
                // stays open so you can see the result. Empty submit removes key.
                const trimmed = std.mem.trim(u8, conn.key, " \t\r\n");
                if (trimmed.len == 0) {
                    agent.removeProviderKey(self, conn.provider);
                } else {
                    agent.storeKey(self, conn.provider, conn.key);
                }
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
        resetAutocomplete(self);
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
        resetAutocomplete(self);
        ctx.redraw = true;
        try self.armTick(ctx);
        return;
    }

    if (trimmed.len == 0) {
        self.ed.clear();
        resetAutocomplete(self);
        if (!self.draft_images.isEmpty()) {
            // Enter on an empty box with a staged image is not a message: the
            // model gets bytes and no question. Say the image is still waiting
            // instead of letting it ride on a message nobody typed.
            self.pushInfo("· message is empty — the staged image goes with your next message");
            ctx.redraw = true;
        }
        return;
    }
    if (std.mem.eql(u8, trimmed, "/quit") or std.mem.eql(u8, trimmed, "/exit")) {
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
    // Images the user staged with Ctrl+V DO ride along: they were pasted for
    // this very message.
    if (!self.draft_images.isEmpty()) {
        self.pending_images = self.draft_images;
        self.draft_images = .{};
    }
    // `@shot.png` typed in the prompt becomes a real attachment, not 32 KB of
    // binary inlined as text. Vision is checked here AND at the wire (the
    // answering model can change mid-turn).
    agent.stageImageMentions(self, owned);

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
    resetAutocomplete(self);
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
pub fn openShortcutsPicker(self: *Model) void {
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
    // The legend goes FIRST: the picker shows one page, and a legend appended
    // after twenty-odd shortcuts is a legend nobody sees. It is also what the
    // reader needs most — the shortcuts have their own keys printed on screen.
    for (modes, 0..) |m, i| {
        items[i] = .{
            .label = gpa.dupe(u8, m[0]) catch return,
            .desc = gpa.dupe(u8, m[1]) catch return,
        };
    }
    for (agent.shortcuts, 0..) |s, i| {
        // The palette OWNS the labels and frees them when it closes: a literal
        // here is an "Invalid free" on exit.
        items[modes.len + i] = .{
            .label = gpa.dupe(u8, s.key) catch return,
            .desc = gpa.dupe(u8, s.desc) catch return,
        };
    }
    self.openPicker(9, "keyboard shortcuts", items, onShortcutPick);
}

/// Picking a shortcut does nothing: the list is a REFERENCE, not a menu.
/// The callback exists because the picker's contract is a callback.
fn onShortcutPick(_: *Model, _: u32, _: []const u8) void {}

/// Turn a Vaxis key into the canonical string `keybinds` looks up. Returns
/// null for a key we deliberately do not bind (a Unicode codepoint with no
/// single-byte name). Named keys use their Vaxis codepoints; modifiers are
/// spelled in the same order as `keybinds.canonicalize` produces.
pub fn keyToBinding(gpa: std.mem.Allocator, key: vaxis.Key) !?[]u8 {
    var one: [1]u8 = undefined;
    var fbuf: [4]u8 = undefined;
    const base: []const u8 = blk: {
        const cp = key.codepoint;
        if (cp == vaxis.Key.tab) break :blk "tab";
        if (cp == vaxis.Key.backspace) break :blk "backspace";
        if (cp == 27) break :blk "esc";
        if (cp == 13 or cp == 10) break :blk "enter";
        if (cp == 32) break :blk "space";
        if (cp == 57349) break :blk "delete";
        if (cp == 57350) break :blk "left";
        if (cp == 57351) break :blk "right";
        if (cp == 57352) break :blk "up";
        if (cp == 57353) break :blk "down";
        if (cp == 57354) break :blk "pageup";
        if (cp == 57355) break :blk "pagedown";
        if (cp == 57356) break :blk "home";
        if (cp == 57357) break :blk "end";
        if (cp >= vaxis.Key.f1 and cp <= vaxis.Key.f12) {
            break :blk std.mem.print(&fbuf, "f{d}", .{cp - vaxis.Key.f1 + 1}) catch return null;
        }
        if (cp < 0x20 or cp > 0x7e) return null;
        one[0] = @intCast(cp);
        break :blk one[0..];
    };
    // A one-byte base already carries its shifted spelling (e.g. 'P'); adding
    // `shift` would make the canonical form unmatchable. Named keys need it.
    const with_shift = key.mods.shift and base.len > 1;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (key.mods.ctrl) try out.appendSlice(gpa, "ctrl+");
    if (key.mods.alt) try out.appendSlice(gpa, "alt+");
    if (with_shift) try out.appendSlice(gpa, "shift+");
    try out.appendSlice(gpa, base);
    return try out.toOwnedSlice(gpa);
}

/// The command bound to this key, or null. Custom bindings do not fire while
/// vim is in normal mode — in that mode vim owns every key by design.
pub fn boundCommand(self: *const Model, gpa: std.mem.Allocator, key: vaxis.Key) !?[]const u8 {
    if (self.vim_mode and self.vim_normal) return null;
    if (self.keybindings.len == 0) return null;
    const name = (try keyToBinding(gpa, key)) orelse return null;
    defer gpa.free(name);
    return (keybinds.Map{ .bindings = self.keybindings }).resolve(name);
}

fn editorKey(self: *Model, ctx: *vxfw.EventContext, key: vaxis.Key) !bool {
    const k = key;

    // Custom keybindings run here, AFTER every modal had its chance: the
    // global key handler calls editorKey last. A binding executes an existing
    // slash command through the same door the palette uses, so permissions,
    // session writes and the transcript are identical either way.
    if (try boundCommand(self, self.allocator, key)) |command| {
        _ = agent.runPaletteCommand(self, command);
        ctx.redraw = true;
        return true;
    }

    // Vim mode (35.13 / Phase 13): modal input editing.
    if (self.vim_mode) {
        if (!self.vim_normal) {
            // Insert mode: Esc returns to normal mode.
            if (k.matches(vaxis.Key.escape, .{})) {
                self.vim_normal = true;
                self.vim_pending = 0;
                ctx.redraw = true;
                return true;
            }
        } else {
            // Normal mode: interpret keys as commands (minimal subset).
            const handled = try vimNormalKey(self, ctx, k);
            if (handled) return true;
        }
    }

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
            if (self.ed.insertChar('\n')) |_| {} else |err| {
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
        // Same hole as the palette: a terminal reply (kitty `CSI 13;129;3u`,
        // an SGR mouse report) reaches this path as key text with control
        // bytes inside, and the composer would insert the sequence into the
        // prompt — which then goes to the model. Only printable text enters.
        if (txt.len > 0 and !ctrl and palette.isPrintableText(txt)) {
            if (self.ed.insert(txt)) |_| {} else |err| {
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
pub fn syncAutocomplete(self: *Model) void {
    // Every edit is a NEW query, so the list starts at its best match.
    //
    // The selection used to survive an edit: type `/mo`, arrow down to `/mode`,
    // then keep typing, and the highlight stayed on whatever item now happened
    // to hold that index — Enter accepted a command the user had not looked at.
    // The arrows do not come through here, so browsing with them still keeps
    // the selection where the reader put it.
    self.ac.sel = 0;
    self.ac.first = 0;

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

/// Minimal vim normal-mode handling for the input editor (35.13).
fn vimNormalKey(self: *Model, ctx: *vxfw.EventContext, k: vaxis.Key) !bool {
    // Allow Ctrl combos to fall through to normal handling when not a vim command.
    if (k.mods.ctrl) {
        self.vim_pending = 0;
        return false;
    }
    // Special keys
    if (k.matches(vaxis.Key.escape, .{})) {
        self.vim_pending = 0;
        ctx.redraw = true;
        return true;
    }
    if (k.codepoint == vaxis.Key.enter) {
        if (self.vim_pending == 0) {
            try submitInput(self, ctx);
            return true;
        }
        self.vim_pending = 0;
        return false;
    }
    if (k.matches(vaxis.Key.backspace, .{}) or k.matches(vaxis.Key.left, .{})) {
        self.ed.moveLeft();
        self.vim_pending = 0;
        ctx.redraw = true;
        return true;
    }
    if (k.matches(vaxis.Key.right, .{})) {
        self.ed.moveRight();
        self.vim_pending = 0;
        ctx.redraw = true;
        return true;
    }
    if (k.matches(vaxis.Key.up, .{})) {
        self.ed.moveUp();
        self.vim_pending = 0;
        ctx.redraw = true;
        return true;
    }
    if (k.matches(vaxis.Key.down, .{})) {
        self.ed.moveDown();
        self.vim_pending = 0;
        ctx.redraw = true;
        return true;
    }

    const txt = k.text orelse {
        self.vim_pending = 0;
        return false;
    };
    if (txt.len != 1) return false;
    const c = txt[0];

    // Pending 'g' (gg)
    if (self.vim_pending == 'g') {
        self.vim_pending = 0;
        if (c == 'g') {
            self.ed.moveToStart();
            ctx.redraw = true;
            return true;
        }
        return false;
    }
    // Pending 'd' (dd, dw, db, d$)
    if (self.vim_pending == 'd') {
        self.vim_pending = 0;
        if (c == 'd') {
            // delete current logical line
            const s = self.ed.text();
            var ls = self.ed.cursor;
            while (ls > 0 and s[ls - 1] != '\n') ls -= 1;
            var le = self.ed.cursor;
            while (le < s.len and s[le] != '\n') le += 1;
            if (le < s.len and s[le] == '\n') le += 1; // include newline
            if (le > ls) self.ed.deleteRange(ls, le) catch {};
            syncAutocomplete(self);
            ctx.redraw = true;
            return true;
        } else if (c == 'w') {
            const start = self.ed.cursor;
            self.ed.moveWordRight();
            const end = self.ed.cursor;
            self.ed.cursor = start;
            if (end > start) self.ed.deleteRange(start, end) catch {};
            syncAutocomplete(self);
            ctx.redraw = true;
            return true;
        } else if (c == 'b') {
            self.ed.deleteWordBefore();
            syncAutocomplete(self);
            ctx.redraw = true;
            return true;
        } else if (c == '$') {
            self.ed.deleteToEnd();
            syncAutocomplete(self);
            ctx.redraw = true;
            return true;
        }
        return false;
    }

    switch (c) {
        'h' => {
            self.ed.moveLeft();
            ctx.redraw = true;
            return true;
        },
        'l' => {
            self.ed.moveRight();
            ctx.redraw = true;
            return true;
        },
        'j' => {
            self.ed.moveDown();
            ctx.redraw = true;
            return true;
        },
        'k' => {
            self.ed.moveUp();
            ctx.redraw = true;
            return true;
        },
        'w' => {
            self.ed.moveWordRight();
            ctx.redraw = true;
            return true;
        },
        'b' => {
            self.ed.moveWordLeft();
            ctx.redraw = true;
            return true;
        },
        '0' => {
            self.ed.moveHome();
            ctx.redraw = true;
            return true;
        },
        '$' => {
            self.ed.moveEnd();
            ctx.redraw = true;
            return true;
        },
        'G' => {
            self.ed.moveToEnd();
            ctx.redraw = true;
            return true;
        },
        'g' => {
            self.vim_pending = 'g';
            ctx.redraw = true;
            return true;
        },
        'd' => {
            self.vim_pending = 'd';
            ctx.redraw = true;
            return true;
        },
        'x' => {
            self.ed.deleteAfter();
            syncAutocomplete(self);
            ctx.redraw = true;
            return true;
        },
        'D' => {
            self.ed.deleteToEnd();
            syncAutocomplete(self);
            ctx.redraw = true;
            return true;
        },
        '/' => {
            self.openTranscriptSearch();
            ctx.redraw = true;
            return true;
        },
        'n' => {
            if (self.search_has_query or self.search_matches.items.len > 0) {
                _ = self.transcriptSearchNext(true);
                ctx.redraw = true;
                return true;
            }
        },
        'N' => {
            if (self.search_has_query or self.search_matches.items.len > 0) {
                _ = self.transcriptSearchNext(false);
                ctx.redraw = true;
                return true;
            }
        },
        'y', 'c' => {
            if (self.message_target_para) |_| {
                if (self.targetedMessageText()) |text| {
                    commands.copyTargetedText(self, text);
                } else {
                    self.pushInfo("nothing to copy");
                }
                self.clearMessageTarget();
                ctx.redraw = true;
                return true;
            }
        },
        'i' => {
            self.vim_normal = false;
            self.vim_pending = 0;
            ctx.redraw = true;
            return true;
        },
        'I' => {
            self.ed.moveHome();
            self.vim_normal = false;
            self.vim_pending = 0;
            ctx.redraw = true;
            return true;
        },
        'a' => {
            self.ed.moveRight();
            self.vim_normal = false;
            self.vim_pending = 0;
            ctx.redraw = true;
            return true;
        },
        'A' => {
            self.ed.moveEnd();
            self.vim_normal = false;
            self.vim_pending = 0;
            ctx.redraw = true;
            return true;
        },
        'o' => {
            self.ed.moveEnd();
            if (self.ed.insertChar('\n')) |_| {} else |_| {}
            self.vim_normal = false;
            self.vim_pending = 0;
            syncAutocomplete(self);
            ctx.redraw = true;
            return true;
        },
        'O' => {
            const s = self.ed.text();
            var ls = self.ed.cursor;
            while (ls > 0 and s[ls - 1] != '\n') ls -= 1;
            self.ed.setCursor(ls);
            if (self.ed.insertChar('\n')) |_| {} else |_| {}
            self.ed.setCursor(ls);
            self.vim_normal = false;
            self.vim_pending = 0;
            syncAutocomplete(self);
            ctx.redraw = true;
            return true;
        },
        else => {},
    }
    self.vim_pending = 0;
    return false;
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

fn freeFilePool(self: *Model) void {
    for (self.ac.file_pool.items) |p| self.allocator.free(p);
    self.ac.file_pool.clearRetainingCapacity();
    self.ac.file_pool_ready = false;
}

/// Reset autocomplete without leaking file_matches / file_pool. The old
/// `self.ac = .{}` discarded owned strings without freeing them.
fn resetAutocomplete(self: *Model) void {
    freeFileMatches(self);
    freeFilePool(self);
    self.ac.active = false;
    self.ac.mode = .none;
    self.ac.prefix_len = 0;
    self.ac.sel = 0;
    self.ac.first = 0;
}

/// The `@token` under the cursor: where it starts and what it says, or null
/// when the cursor is not on (or right after) an at-mention.
///
/// PURE over the input text: the disk is `refreshFileMatches`' business, so the
/// tests can pin down the token logic without a filesystem.
pub fn fileQueryAt(text: []const u8, cursor: usize) ?struct { token_start: usize, token: []const u8 } {
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
pub fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (needle, 0..) |nc, i| {
        if (std.ascii.toLower(haystack[i]) != std.ascii.toLower(nc)) return false;
    }
    return true;
}

/// Command name without the slash: "/effort none|minimal|low|…" → "effort".
///
/// Autocompletion matches against this and not against the whole line: with
/// the whole line, "/e" would match the argument vocabulary too.
pub fn commandToken(key: []const u8) []const u8 {
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
pub fn acPrefix(self: *const Model) ?[]const u8 {
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

/// How well a command answers the query, as a rank the list is built from.
///
///   0  the NAME starts with it                    (`/mo` → `/model`)
///   1  the name contains it                       (`del` → `/submodel`)
///   2  the name holds it as a SUBSEQUENCE         (`cp` → `/copy`)
///   3  only the DESCRIPTION contains it           (`always` → `/allowlist`)
///   4  no match
///
/// Rank 3 exists because the popup said it was a search and behaved like a
/// completion: a word the user remembers from a description matched nothing.
/// It is a FALLBACK, and that detail is the whole design: with descriptions in
/// the same pass as names, `/mod` returned thirteen commands — the three
/// `/mod*` ones buried in ten that merely mention "model" — and a filter that
/// returns half the table is a filter that does not filter.
///
/// Rank 2 is the same subsequence matcher the palettes use (`lib/fuzzy.zig`,
/// window and all), so the popup answers the abbreviations the modal answers.
fn commandTier(c: anytype, q: []const u8) u8 {
    const token = commandToken(c.key);
    if (startsWithIgnoreCase(token, q)) return 0;
    if (containsIgnoreCase(token, q)) return 1;
    var buf: [64]u32 = undefined;
    if (fuzzy.matchPositions(token, q, &buf) != null) return 2;
    if (containsIgnoreCase(c.desc, q)) return 3;
    return 4;
}

/// Is the description tier the only one with hits? Then — and only then — it is
/// shown: "always" finds `/allowlist`, "mod" stays the three names it names.
fn commandDescTierOn(q: []const u8) bool {
    var i: usize = 0;
    while (agent.commandAt(i)) |c| : (i += 1) {
        if (commandTier(c, q) < 3) return false;
    }
    return true;
}

/// Number of items matching the current prefix.
pub fn matchCount(self: *const Model) usize {
    return switch (self.ac.mode) {
        .command => blk: {
            const prefix = acPrefix(self) orelse break :blk 0;
            const desc_on = commandDescTierOn(prefix);
            var n: usize = 0;
            var i: usize = 0;
            while (agent.commandAt(i)) |c| : (i += 1) {
                const tier = commandTier(c, prefix);
                if (tier < 3 or (tier == 3 and desc_on)) n += 1;
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
pub fn matchLabel(self: *const Model, n: usize) ?[]const u8 {
    return switch (self.ac.mode) {
        .command => blk: {
            const prefix = acPrefix(self) orelse break :blk null;
            const desc_on = commandDescTierOn(prefix);
            var seen: usize = 0;
            // Walks the ranks in order, so the list reads "best match first"
            // without scoring or sorting anything.
            var rank: u8 = 0;
            while (rank < 4) : (rank += 1) {
                if (rank == 3 and !desc_on) break;
                var i: usize = 0;
                while (agent.commandAt(i)) |c| : (i += 1) {
                    if (commandTier(c, prefix) != rank) continue;
                    if (seen == n) break :blk c.key;
                    seen += 1;
                }
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
pub fn isExactMatch(self: *Model) bool {
    if (!self.ac.active or self.ac.mode != .command) return false;
    const typed = std.mem.trim(u8, self.ed.text(), " \t\r\n");
    if (typed.len == 0) return false;
    // Compared against ALL the commands, not just the highlighted one —
    // builtins AND the user's own (`commandAt` walks both), so Enter on a
    // completed `/review` submits instead of re-completing.
    //
    // Comparing only with the highlighted one broke "/model": another command
    // sorted first in the popup, so it was not an exact match and Enter
    // completed to THAT one. Now: if what is typed IS a command it is sent as-is; if it is
    // partial ("mod"), it is completed.
    var ac_i: usize = 0;
    while (agent.commandAt(ac_i)) |c| : (ac_i += 1) {
        if (std.mem.eql(u8, typed, c.key)) return true;
    }
    return false;
}

pub fn acceptAutocomplete(self: *Model) bool {
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
            resetAutocomplete(self);
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
    resetAutocomplete(self);
    return true;
}

/// Names the byte cap in a clear message: what the limit is, how many bytes
/// are already typed, and what to do. The buffer was not modified by the
/// rejected edit, so the message is accurate at paint time.
fn inputTooLongRejected(self: *Model) void {
    const text_len = self.ed.text().len;
    const msg = std.mem.print(&self.input_err_buf, "Input too long: {d}-byte cap, {d} bytes already typed. Shorten the text and resend.", .{ ed.max_bytes, text_len }) catch {
        self.input_err = "Input too long: shorten the text.";
        self.input_too_long = true;
        return;
    };
    self.input_err = msg;
    self.input_too_long = true;
}

/// One insert path for every bulk text that lands in the input: an OSC-52
/// `.paste` event and an aggregated bracketed paste both come through here, so
/// the modals keep their guard and the cap keeps its message.
fn insertIntoInput(self: *Model, data: []const u8) void {
    if (data.len == 0) return;
    if (self.pickerActive() or self.permActive()) return;
    if (self.ed.insert(data)) |_| {
        self.input_too_long = false;
        self.input_err = "";
    } else |err| {
        if (std.mem.eql(u8, @errorName(err), "InputTooLong")) inputTooLongRejected(self);
    }
    syncAutocomplete(self);
}

/// Accumulates one key event that arrived between `paste_start` and
/// `paste_end`. The bytes of a paste reach us as ordinary keys, so the only
/// thing to decide per key is which text it carries: `key.text` when the
/// terminal reports it, the codepoint otherwise, and Enter as a newline.
fn capturePasteKey(self: *Model, k: vaxis.Key) void {
    // A newline inside a paste reaches us twice over: terminals that report
    // Enter send the enter codepoint, and the raw 0x0A byte of a multi-line
    // selection is parsed as Ctrl+J (vaxis Parser: `0x0A => 'j' + ctrl`).
    // Both mean a line break HERE — during a paste there is no hand to press
    // the key.
    if (k.codepoint == vaxis.Key.enter or
        (k.codepoint == 'j' and k.mods.ctrl and (k.text == null or k.text.?.len == 0)))
    {
        self.paste_buf.append(self.allocator, '\n') catch {};
        return;
    }
    if (k.text) |txt| {
        // Same rule as the composer and the palette: a terminal reply that
        // arrives as key text carries control bytes, and a paste is not the
        // place to let them in either. Tabs never reach here — a raw 0x09 is
        // Ctrl+I with no text.
        if (txt.len > 0 and !k.mods.ctrl and palette.isPrintableText(txt)) {
            self.paste_buf.appendSlice(self.allocator, txt) catch {};
        }
        return;
    }
    if (!k.mods.ctrl and !k.mods.alt and k.codepoint >= 32) {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(k.codepoint), &buf) catch return;
        self.paste_buf.appendSlice(self.allocator, buf[0..n]) catch {};
    }
}

// ── root widget handlers ─────────────────────────────────
pub fn typeErasedEventHandler(ud: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *Model = @ptrCast(@alignCast(ud));
    // `/copy`: a text waiting for the clipboard leaves through the RENDER.
    // It is flushed at the TOP of every event, so it goes out with the next
    // tick even if the user does not touch anything (a tick is an event, and
    // it carries an EventContext).
    self.flushCopyPending(ctx);
    switch (event) {
        .key_press => |key| {
            // Between `paste_start` and `paste_end` a key is CONTENT, not a
            // command: no submit, no shortcut, no modal navigation.
            // Escape is the escape hatch: a lost `paste_end` (11-line pastes
            // left the TUI swallowing every key, Ctrl+P included) would
            // otherwise trap all input in the paste buffer forever.
            if (self.pasting) {
                if (key.matches(vaxis.Key.escape, .{})) {
                    self.pasting = false;
                    insertIntoInput(self, self.paste_buf.items);
                    self.paste_buf.clearRetainingCapacity();
                    ctx.redraw = true;
                    return;
                }
                capturePasteKey(self, key);
                return;
            }
            // A rejected-input note refers to the buffer as it was; once the
            // user presses another key it is stale.
            self.input_too_long = false;
            self.input_err = "";
            // Ctrl+C: first clears the input, the second press exits (so
            // half-typed text is never lost in one go).
            if (key.matches('c', .{ .ctrl = true })) {
                // A modal owns Ctrl+C too: closing it is the expected action.
                // With empty input this branch used to QUIT the app from inside
                // a picker or the palette, losing the work on screen.
                if (self.anyModalActive()) {
                    if (try self.closeTopModal(ctx)) return;
                }
                if (self.hasInput()) {
                    self.ed.clear();
                    resetAutocomplete(self);
                    // The draft dies whole: an image staged for a discarded
                    // message must not ride on the next one.
                    self.draft_images.clear(self.allocator);
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
            // Transcript screen (33.4): captures input while open.
            if (self.transcriptViewActive()) {
                if (self.transcriptViewHandleKey(key)) {
                    self.flushCopyPending(ctx);
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
            }
            // Modal diff viewer (33.18): captures input while open.
            if (self.diffViewerActive()) {
                if (self.diffViewerHandleKey(key)) {
                    self.flushCopyPending(ctx);
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
            }
            // Transcript search bar (33.13): captures input while typing query.
            if (self.transcriptSearchActive()) {
                if (self.searchBarHandleKey(key)) {
                    self.flushCopyPending(ctx);
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
            }
            // Ctrl+, — the Settings screen (internal config). Distinct from
            // Ctrl+P/T so it cannot be mistaken for the model picker again.
            if (key.matches(',', .{ .ctrl = true })) {
                if (self.settings_active) {
                    self.settingsClose();
                } else {
                    self.settingsOpen();
                }
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            // The Settings screen captures every key while it is open.
            if (self.settings_active) {
                if (self.settingsHandleKey(key)) {
                    self.flushCopyPending(ctx);
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
            }
            // Modal picker active: captures ALL input (before global shortcuts so
            // session-picker chords like Ctrl+A/B/V/S work; Ctrl+C quit is above).
            if (self.pickerActive()) {
                if (self.pickerHandleKey(key)) {
                    self.flushCopyPending(ctx);
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
            }
            // Ctrl+P: command palette (commands and models in two columns).
            // Toggle: pressing it while the commands palette is open closes it,
            // so a stuck-open palette is escapable with the same key.
            if (key.matches('p', .{ .ctrl = true })) {
                if (self.pal.active and self.pal.mode == .commands) {
                    self.closePalette();
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
                agent.openCommandPalette(self);
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            if (key.matches('t', .{ .ctrl = true })) {
                if (self.pal.active and self.pal.mode == .models) {
                    self.closePalette();
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
                agent.openModelPaletteAsync(self);
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            // An open palette OWNS its keys. Dispatch here, BEFORE the global
            // shortcuts below: otherwise Ctrl+R expands a tool instead of
            // refreshing the model catalog, and Ctrl+L wipes the transcript
            // behind the modal. Both are documented palette keys (44.1/44.2).
            if (self.pal.active) {
                if (try self.paletteKey(ctx, key)) {
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
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
            if (key.matches('r', .{ .ctrl = true }) and !self.pal.active) {
                if (self.toggleLastTool()) {
                    ctx.redraw = true;
                } else {
                    self.cache_from = 0;
                    ctx.redraw = true;
                }
                return;
            }
            // Phase 3: hunk navigation on the last diff (alt+] next, alt+[ prev).
            if (key.matches(']', .{ .alt = true })) {
                if (self.navigateLastDiffHunk(1)) ctx.redraw = true;
                return;
            }
            if (key.matches('[', .{ .alt = true })) {
                if (self.navigateLastDiffHunk(-1)) ctx.redraw = true;
                return;
            }
            // Ctrl+V: stage the clipboard's IMAGE for the next message.
            if (key.matches('v', .{ .ctrl = true })) {
                agent.attachClipboardImage(self);
                ctx.redraw = true;
                return;
            }
            // Ctrl+G: edit the current prompt in $VISUAL/$EDITOR.
            if (key.matches('g', .{ .ctrl = true })) {
                agent.openExternalEditor(self);
                syncAutocomplete(self);
                ctx.redraw = true;
                return;
            }
            // Ctrl+F: transcript search (33.13).
            if (key.matches('f', .{ .ctrl = true })) {
                if (self.transcriptSearchActive()) self.closeTranscriptSearch() else self.openTranscriptSearch();
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            // Ctrl+O: transcript screen (33.4).
            if (key.matches('o', .{ .ctrl = true })) {
                self.toggleTranscriptView();
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            // Ctrl+P palette open: captures ALL input, scroll included.
            if (self.pal.active) {
                if (try self.paletteKey(ctx, key)) {
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
                // "/model" completed to a different command because the popup
                // sorted that one first and the match was only looked for there.
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
                        resetAutocomplete(self);
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

            // Per-message targeting (33.12): Shift+↑/↓ targets previous/next message.
            if (key.codepoint == vaxis.Key.up and key.mods.shift and !key.mods.ctrl and !key.mods.alt) {
                if (self.targetPrevMessage()) {
                    self.pushInfo("targeted message · Shift+↑/↓ move, y copy, Esc clear");
                } else {
                    self.pushInfo("no previous message to target");
                }
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            if (key.codepoint == vaxis.Key.down and key.mods.shift and !key.mods.ctrl and !key.mods.alt) {
                if (self.targetNextMessage()) {
                    self.pushInfo("targeted message · Shift+↑/↓ move, y copy, Esc clear");
                } else {
                    self.pushInfo("no next message to target");
                }
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            // Copy targeted message action (33.12).
            if (self.message_target_para != null and !self.hasInput() and !key.mods.ctrl and !key.mods.alt) {
                if (key.codepoint == 'y' or key.codepoint == 'c') {
                    if (self.targetedMessageText()) |text| {
                        commands.copyTargetedText(self, text);
                    } else {
                        self.pushInfo("nothing to copy");
                    }
                    self.clearMessageTarget();
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
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
                if (self.message_target_para != null) {
                    self.clearMessageTarget();
                    self.pushInfo("message target cleared");
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
                if (self.session) |sp| sp.bumpEscs();
                // The face follows the fact: a cancelled turn is `warn`, not
                // `done`. Set here (the UI thread) and cleared by the next
                // `streamStart`, so the mark belongs to THIS turn.
                self.cancelled = true;
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
                // Nothing to kill but a turn in flight: the legend says the ESC
                // landed, so the key never looks like it did nothing.
                if (killed == 0 and bg_killed == 0 and self.isBusyFlag()) {
                    agent.setStatusWithZo(self, .warn, "stopping\u{2026}");
                }
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            // Permission dialog active: y/s/a/n decide, rest ignored.
            if (self.permActive()) {
                const cp = key.codepoint;
                if (cp == 'y' or cp == 'Y') {
                    self.answerPermission(.allow);
                } else if (cp == 's' or cp == 'S') {
                    // Phase 25: run a flagged bash command in a sandbox, when
                    // one is available. Not the only answer — an alternative
                    // to granting full permissions.
                    if (self.permSandboxAvailable()) self.answerPermission(.allow_sandbox);
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
            if (k.matches(vaxis.Key.page_up, .{}) or
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
            self.motion_tick_count +%= 1;
            // Phase 37: sample RSS about once per second (the tick fires every
            // ~120 ms). The ring is fixed and allocation-free, so this is safe
            // from the UI thread and gives /diag a growth history.
            if (self.motion_tick_count % 8 == 0 and self.io_ready) {
                self.diag_seq +%= 1;
                var s = diag_mod.sample(self.io);
                s.seq = self.diag_seq;
                self.diag_monitor.push(s);
            }
            // Phase 19: a parked turn may need a scheduled prompt or a periodic
            // check-in even when no model iteration is running. The same door
            // (appendHarnessPrompt) is used; both are suppressed while busy.
            agent.drainScheduleNotifications(self);
            const a = self.activity();
            const asked = self.redraw_requested.swap(false, .seq_cst);
            // `mascotMoved` and not "there is an animation": at rest the face
            // changes once every couple of seconds, and the tick fires eight
            // times a second in between. The face is the ONLY thing that moves
            // when the app is otherwise idle, so without this the idle track
            // (blinks, exhale, yawn) was only ever painted when a key happened
            // to arrive — which is why it read as a frozen glyph.
            // Phase 4: mascot motion repaints are disabled by reduced/no animation.
            const mascot_moved = self.mascotMoved();
            if (mascot_moved) self.mascot_motion_repaints +%= 1;
            // Phase 32.1: advance the three-way count pill by +1 per tick so it
            // animates toward the target like the tps rolling window.
            const verify_moved = self.verify_counter.tick();
            if (verify_moved) self.dirty = true;
            if (asked or a.busy or a.dirty or a.perm or a.picker or self.pal.active or mascot_moved or verify_moved) {
                ctx.redraw = true;
            }
            // The queue is drained here and not by the worker: `startChat`
            // enqueues when busy, and the worker thread has no `EventContext`
            // to start the next turn with, so until now a queued prompt was
            // shown in the footer and never ran. The tick is the UI thread
            // waking up anyway, and the turn has just ended by then.
            if (self.takeQueuedWhenIdle()) |turn| {
                agent.startTurn(self, turn.text, turn.mode, turn.bash_allow_rules, turn.expand_cmdsubst) catch |err| {
                    self.pushInfoFmt("error: {t}", .{err});
                };
                self.allocator.free(turn.text);
                ctx.redraw = true;
            }
            // The model catalogue on disk refreshes itself, quietly, about
            // every quarter hour — only while idle, by the worker that already
            // does the startup warmup. The palette never waits on the network
            // for a list the user expected to be current.
            agent.maybeRefreshCatalog(self);
            agent.maybeRefreshModelPalette(self);
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
        .paste_start => {
            self.pasting = true;
            self.paste_buf.clearRetainingCapacity();
        },
        .paste_end => {
            self.pasting = false;
            // Route bracketed paste to the active key prompt (provider connect),
            // otherwise insert into the composer. Newlines/control chars are
            // filtered by the key buffer so a pasted API key stays valid.
            if (self.pal.active and self.pal.mode == .key_prompt) {
                self.pal.appendKeyText(self.paste_buf.items);
            } else {
                insertIntoInput(self, self.paste_buf.items);
            }
            self.paste_buf.clearRetainingCapacity();
            ctx.redraw = true;
        },
        .paste => |data| {
            // OSC-52 clipboard paste (the terminal already aggregated it).
            if (self.pal.active and self.pal.mode == .key_prompt) {
                self.pal.appendKeyText(data);
            } else {
                insertIntoInput(self, data);
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
            // Skip while overlays own the surface so hover never gets stranded.
            if (m.type == .motion and !self.scrollbar_dragging and !self.selecting_text and
                !self.pal.active and !self.askActive() and !self.permActive())
            {
                const hot: ?usize = if (self.promptDotAt(m)) |d| d.para else null;
                if (hot != self.prompt_dot_hover) {
                    self.prompt_dot_hover = hot;
                    ctx.redraw = true;
                }
                return;
            }
            if (m.type == .motion and self.prompt_dot_hover != null and
                (self.pal.active or self.askActive() or self.permActive()))
            {
                self.prompt_dot_hover = null;
                ctx.redraw = true;
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
    // ZODE_CRASH_TEST=1: die with the alternate screen ACTIVE (vaxis owns it
    // by now), so the crash path runs with something real to give back.
    if (self.crash_test) @panic("crash test requested (ZODE_CRASH_TEST)");
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
    if (height < 6 or width < 12) {
        // An empty surface in a small split pane looks like a frozen app. Paint
        // one clipped line that says what is wrong, then return — no composer,
        // no modal geometry, no event work until the pane grows.
        if (height == 0 or width == 0) return vxfw.Surface.empty(self.widget());
        const tiny_size: vxfw.Size = .{ .width = width, .height = height };
        var tiny = try vxfw.Surface.init(ctx.arena, self.widget(), tiny_size);
        var tp = Painter{ .surface = &tiny, .arena = ctx.arena, .ctx = ctx, .width = width, .height = height };
        _ = tp.putText(0, 0, "zode: terminal too small (min 12x6)", theme.warn);
        return tiny;
    }

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
    // wrapped) or if a paragraph was edited in-place (^R expands a tool
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
                    std.mem.print(&tool_buf, "*{s}* running", .{tr.name}) catch ""
                else
                    std.mem.print(&tool_buf, "*{s}*({s}) running", .{ tr.name, arg_shown }) catch ""
            else if (tr.arg.len == 0)
                std.mem.print(&tool_buf, "*{s}* running · {d}.{d}s", .{ tr.name, secs, (ms % 1000) / 100 }) catch ""
            else
                std.mem.print(&tool_buf, "*{s}*({s}) running · {d}.{d}s", .{ tr.name, arg_shown, secs, (ms % 1000) / 100 }) catch "";
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
        // Streaming text is rebuilt from the current snapshot each frame so
        // incomplete markdown (unclosed fences, partial structures) keeps
        // rendering as it arrives. We force redraw while live content is shown.
        self.diff_needs_full_redraw = true;
        // `live_src` is already frame-arena owned (see the invariant above), so
        // there is nothing to copy here any more.
        var live_para = Model.Para{
            .kind = live_kind,
            .text = live_src,
            .lang = if (live_kind == .diff) "zig" else "",
        };
        live_lines = buildLines(ctx.arena, ctx, &live_para, wrap_width, self.nerd_icons) catch &.{};
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

    // Clear the transcript area up to the hairline, INCLUDING the rows a plan
    // or autocomplete popup reserves (history_h stops short of `rule_row`
    // there), so no row keeps the previous frame's pixels.
    //
    // On the TERMINAL's background and not on `well_bg`: a panel that is
    // almost black looks like a second, wrong black next to the terminal's
    // own, and on a black terminal the whole transcript read as a gray block
    // with the user's own background nowhere in sight. The history is the
    // page; only a well that MEANS something (a tool result, a code block, a
    // modal) is allowed to be a surface.
    {
        var clear_row: u16 = 0;
        while (clear_row < rule_row) : (clear_row += 1) {
            p.fillRange(0, width, clear_row, " ", .{});
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
        // The cached entry is the WHOLE paragraph (separator row counted in
        // already, see `layoutOne`), so its first line sits exactly at the
        // paragraph's absolute start.
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
    // raised the question. That is not a style choice: the model catalog worker once
    // filled the palette while the UI thread was drawing it, with no lock on the
    // palette's own state, and the app segfaulted. The worker leaves the question
    // in the `Model`; the draw is what turns it into a picker.
    // ── modal picker (opencode style, centered) ──
    if (self.pickerSnapshot(ctx.arena)) |ps| {
        drawPicker(&p, width, height, ps);
    }
    // ── modal diff viewer (33.18) ──
    if (self.diffViewerActive()) {
        drawDiffViewer(&p, self, width, height);
    }
    // ── transcript screen (33.4) ──
    if (self.transcriptViewActive()) {
        drawTranscriptView(&p, self, width, height);
    }
    // ── transcript search bar (33.13) ──
    if (self.transcriptSearchActive()) {
        drawTranscriptSearchBar(&p, self, width, height);
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
            self.permRule(),
            self.permAllowAlways(),
            self.permSandboxAvailable(),
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
    // only owner. Only in models mode: a late catalog worker must not clobber
    // the commands list the user is looking at.
    if (self.pal.active and self.pal.mode == .models) {
        if (self.takePendingItems()) |items| {
            self.pal.setItemsOwned(items, &agent.model_groups);
        }
    } else {
        // Drop stale pending items so they do not leak into the next open.
        if (self.takePendingItems()) |items| {
            palette.freeItems(self.allocator, items);
        }
    }
    if (self.pal.active) {
        palette.draw(&p, &surface, &self.pal, width, height, self.catalogNotice(ctx.arena));
    }

    // ── copy toast: top-right, rounded border, ~2 seconds ──
    var notif_y: u16 = 2;
    if (self.copy_toast_frames > 0) {
        self.copy_toast_frames -= 1;
        drawCopyToast(&p, width, height, self.copy_toast_text);
        notif_y += 4;
    }

    // ── transient notifications (33.9): top-right stack, absolutely positioned ──
    {
        var i: usize = 0;
        while (i < self.notification_len) {
            if (self.notifications[i].frames == 0) {
                // Remove expired: shift left.
                var j = i + 1;
                while (j < self.notification_len) : (j += 1) {
                    self.notifications[j - 1] = self.notifications[j];
                }
                self.notification_len -= 1;
                continue;
            }
            self.notifications[i].frames -= 1;
            drawNotificationToast(&p, width, height, self.notifications[i].slice(), notif_y);
            notif_y +|= 4;
            i += 1;
        }
    }

    // ── Settings screen: FULL-SURFACE, painted last so nothing overlaps it ──
    if (self.settings_active) {
        drawSettingsScreen(&p, self, width, height);
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

    drawRoundedBox(p, toast_x, toast_y, toast_w, toast_h, theme.code_bg, theme.line_bright);

    // Text, centered.
    const text_x: u16 = toast_x + (toast_w - text_w) / 2;
    _ = p.putText(text_x, toast_y + 1, text, theme.ink);
}

/// 33.9: transient notification toast, absolutely positioned at (top-right, y).
fn drawNotificationToast(p: *Painter, width: u16, height: u16, text: []const u8, y: u16) void {
    if (width < 10 or height < 4) return;
    const pad: u16 = 2;
    const toast_h: u16 = 3;
    if (y + toast_h >= height) return;
    const max_text_w: u16 = if (width > 2 * pad + 8) width - 2 * pad - 4 else 8;
    const text_w: u16 = @min(@as(u16, @intCast(@min(text.len, 60))), max_text_w);
    const toast_w: u16 = @min(@max(text_w + 4, 20), width -| 2 * pad);
    const toast_x: u16 = width -| toast_w -| pad;

    drawRoundedBox(p, toast_x, y, toast_w, toast_h, theme.code_bg, theme.line_bright);

    // Text, centered and clipped to the box.
    const inner_w: u16 = if (toast_w > 4) toast_w - 4 else 0;
    const draw_w: u16 = @min(text_w, inner_w);
    if (draw_w == 0) return;
    const text_x: u16 = toast_x + 2 + (inner_w -| draw_w) / 2;
    const shown = text[0..@min(text.len, draw_w)];
    _ = p.putText(text_x, y + 1, shown, theme.ink);
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

    // The input rows are CLEARED every frame, on the terminal's own background.
    //
    // They used to be filled with `well_bg` so the composer read as a sunken
    // surface. On a black terminal that fill is a second black that does not
    // match the first: the composer, the transcript and the empty rows between
    // them came out as three shades of almost-black, which is what the user
    // meant by "the background changed color, it is not the terminal's black".
    // The accent bar and the prompt glyph already say "this is the input"; a
    // panel colour under them was saying it twice and wrong.
    // Zero extra rows: the clear lives inside the rows the input already owns.
    {
        var i: u16 = 0;
        while (i < well_h and top + i < p.height) : (i += 1) {
            p.fillRange(1, width, top + i, " ", .{});
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
    // The text is painted WHOLE. It used to be elided with `… +N more` once it
    // passed 400 bytes — a guard meant for huge pastes that also caught anyone
    // typing a normal paragraph. The box grew from the full text while the row
    // was wrapped from the ELIDED copy, so the composer ended up taller than
    // its text and the caret was hidden outright: from the user's side the
    // input "broke" mid-sentence and cut itself like a paste. The wrap already
    // knows how to scroll (bottom-anchored, `↑ N more` on the rule), so there
    // is nothing to elide.
    const disp_text = self.ed.text();

    // The staged images announce themselves HERE, as `[name]` tags on a row of
    // their own above the text: an image that lives only in the outgoing
    // message and nowhere on your screen is an image you forget you attached,
    // and then you wonder what the model is looking at.
    var tags: std.ArrayList(u8) = .empty;
    var tag_count: usize = 0;
    {
        var i: usize = 0;
        while (i < self.draft_images.len) : (i += 1) {
            const img = self.draft_images.images[i];
            const base = if (img.path.len > 0) std.fs.path.basename(img.path) else "image";
            tags.appendSlice(p.arena, "[") catch {};
            tags.appendSlice(p.arena, base) catch {};
            tags.appendSlice(p.arena, "] ") catch {};
            tag_count += 1;
        }
    }
    const tag_text: []const u8 = if (tag_count == 0) "" else tags.items;
    var disp_all: []const u8 = disp_text;
    if (tag_count > 0) {
        const sep: []const u8 = if (disp_text.len > 0) "\n" else "";
        disp_all = std.mem.concat(p.arena, u8, &.{ tag_text, sep, disp_text }) catch disp_text;
    }
    // Rows the tag block costs, for the cursor mapping: the tags wrap too at
    // narrow widths, and the typed text starts one row after wherever they end.
    var tag_rows: usize = 0;
    if (tag_count > 0) {
        var tri = ed.RowIter.init(tag_text, ed_w, meas);
        while (tri.next() != null) tag_rows += 1;
    }
    // Wrap the text into rows, counting them FIRST so the window can be
    // bottom-anchored: the cursor is at the end of what you are typing, and
    // that is the row that has to stay on screen. Only the visible rows are
    // kept — a 256 KB paste is thousands of rows and the box shows at most
    // `input_h` of them.
    var total_rows: usize = 0;
    {
        var rit = ed.RowIter.init(disp_all, ed_w, meas);
        while (rit.next() != null) total_rows += 1;
    }
    const first = if (total_rows > input_h) total_rows - input_h else 0;
    {
        var rit = ed.RowIter.init(disp_all, ed_w, meas);
        var idx: usize = 0;
        while (rit.next()) |piece| : (idx += 1) {
            if (idx < first) continue;
            const i = idx - first;
            if (i >= input_h) break;
            if (piece.bytes.len == 0) continue;
            const row = top + @as(u16, @intCast(i));
            const text_style: vaxis.Style = .{ .fg = theme.input_text.fg };
            _ = p.putClipped(3, row, piece.bytes, ed_w, text_style);
        }
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
            const est = theme.warn_bold;
            _ = p.putClipped(3, err_row, self.input_err, ed_w, est);
        }
    }

    // The terminal cursor, at its VISUAL row and column. It is always shown:
    // the text is no longer elided, so there is no "truncated" case where the
    // caret would point at the wrong place. When the caret is outside the
    // visible window (the user moved it above the scrolled rows) there is no
    // cell to anchor it to, and the accent bar already marks the composer.
    {
        const cc = self.ed.cursorRowCol(ed_w, meas);
        // The typed text sits `tag_rows` below the top of the box: the visual
        // row of the cursor is the editor's row PLUS the tag block.
        const vrow = cc.row + tag_rows;
        if (vrow >= first and vrow < first + input_h and vrow < total_rows) {
            const col = 3 + @min(cc.col, ed_w - 1);
            surface.cursor = .{
                .row = top + @as(u16, @intCast(vrow - first)),
                .col = col,
            };
        }
    }

    // Show the clipped prompt's hidden-row count on the workspace rule, not in
    // the prompt text itself.
    if (first > 0 and width > 16 and hint_row != top and !self.ac.active) {
        var ib: [32]u8 = undefined;
        const lab = std.mem.print(&ib, "\u{2191} {d} more", .{first}) catch "";
        if (lab.len > 0 and lab.len + 4 < width) {
            _ = p.putClipped(width - 2 - @as(u16, @intCast(lab.len)), hint_row, lab, @as(u16, @intCast(lab.len)), theme.key_hint);
        }
    }

    if (self.ed.isEmpty() and tag_count == 0) {
        // With a question open this box IS the answer field (the free-text path).
        const ph: []const u8 = if (self.askActive())
            "Type your answer\u{2026}  Enter to send \u{00b7} Esc to choose"
        else
            "Ask anything\u{2026}  / commands \u{00b7} @ files \u{00b7} ! shell";
        // Placeholder on terminal background (no fill).
        const ph_style: vaxis.Style = .{ .fg = theme.placeholder.fg };
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
        if (is_sel) _ = p.putText(0, y, "▸", theme.brand_bold);
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
            const d = std.mem.print(&db, "  {s}", .{agentCommandDesc(label)}) catch continue;
            _ = p.putText(3 + @as(u16, @intCast(label.len)), y, d, theme.dim);
        }
    }

    // Footer: how many matches there are, and how many are off screen. Both
    // numbers, because "6 matches" with 6 rows shown looks complete and is not.
    var fb: [64]u8 = undefined;
    const foot = if (hidden > 0)
        std.mem.print(&fb, "{d} matches · +{d} more · ↑↓ · tab", .{ total, hidden }) catch ""
    else
        std.mem.print(&fb, "{d} {s} · ↑↓ · tab", .{
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

pub fn scrollbarOffset(row: usize, track_rows: usize, max_offset: usize) usize {
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
pub fn stickyPromptPara(self: *const Model) ?usize {
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
        std.mem.print(&buf, "1 new message", .{}) catch "new"
    else
        std.mem.print(&buf, "{d} new messages", .{unseen}) catch "new";
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
            p.putStableLinked(col, row, cell.text, cell.w, cell.style, cell.link);
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
        expandWideCells(p.surface, y + r, p.width);
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
    rule: []const u8,
    allow_always: bool,
    allow_sandbox: bool,
    suggestion: []const u8,
) void {
    // Responsive width: fit the terminal, keep readable margins, and adapt
    // cleanly to zoom/resize (vaxis redraws on winsize).
    const margin: u16 = if (width > 16) 4 else 2;
    const w: u16 = @min(width -| (margin * 2), 110);
    const inner_x_pad: u16 = 3;
    const inner_w: u16 = w -| (inner_x_pad * 2 + 2);
    const dangerous_suggestion = allow_always and suggestion.len > 0 and permrules.isDangerousRuleText(suggestion);
    const sandbox_note = allow_sandbox and std.ascii.eqlIgnoreCase(tool, "bash");

    // Wrap the detail (bash command / args) so long commands stay inside the
    // modal borders instead of overflowing. Cap lines so the dialog remains
    // usable on small terminals.
    const max_detail_lines: usize = blk: {
        if (height <= 14) break :blk 2;
        if (height <= 22) break :blk 4;
        break :blk 6;
    };
    const detail_rows_all: []const []const u8 = if (detail.len > 0 and inner_w > 0)
        wrapTextToRows(p, detail, inner_w, p.arena)
    else
        &.{};
    const detail_lines: usize = @min(detail_rows_all.len, max_detail_lines);
    const detail_truncated = detail_rows_all.len > max_detail_lines;

    // Rule text can be long (paths/patterns). Wrap it so the dialog explains why
    // without overflowing; cap lines to keep the modal compact.
    var rbuf: [160]u8 = undefined;
    const rtext: []const u8 = if (rule.len > 0)
        (std.mem.print(&rbuf, "asked by rule: {s}", .{rule}) catch rule)
    else
        "";
    const rule_rows_all: []const []const u8 = if (rtext.len > 0 and inner_w > 0)
        wrapTextToRows(p, rtext, inner_w, p.arena)
    else
        &.{};
    const max_rule_lines: usize = 2;
    const rule_lines: usize = @min(rule_rows_all.len, max_rule_lines);

    // Height: title+label(4) + tool(1) + detail + optional rows + options(1) + padding.
    var h: u16 = 7;
    if (detail.len > 0) h +|= @intCast(@max(detail_lines, 1));
    if (detail_truncated) h +|= 1;
    if (rule_lines > 0) h +|= @intCast(rule_lines);
    if (sandbox_note) h +|= 1;
    if (dangerous_suggestion) h +|= 1;
    h = @min(h, height -| 2);

    // Too small for a readable box: compact form keeps the turn answerable.
    if (w < 28 or height < 8 or h < 7) {
        drawPermissionModalCompact(p, width, height, tool, detail, rule, allow_always, sandbox_note);
        return;
    }
    if (h > height -| 2) {
        drawPermissionModalCompact(p, width, height, tool, detail, rule, allow_always, sandbox_note);
        return;
    }
    const x: u16 = (width -| w) / 2;
    const y: u16 = (height -| h) / 2;

    drawRoundedBox(p, x, y, w, h, theme.panel_bg, theme.warn_bold);

    // Title
    _ = p.putClipped(x + inner_x_pad, y + 1, "⚠  Permission required", inner_w, theme.warn_bold);

    // Tool
    _ = p.putClipped(x + inner_x_pad, y + 3, "This tool wants to run:", inner_w, theme.brand_soft);
    var nb: [64]u8 = undefined;
    const tname = std.mem.print(&nb, "{s}", .{tool}) catch tool;
    _ = p.putClipped(x + inner_x_pad, y + 4, tname, inner_w, theme.brand_bold);

    var dy: u16 = y + 5;
    const bottom_limit: u16 = y + h -| 2; // leave room for options row

    // Detail, wrapped and clipped so it never crosses the modal border.
    if (detail.len > 0 and dy < bottom_limit) {
        var di: usize = 0;
        while (di < detail_lines and dy < bottom_limit) : (di += 1) {
            _ = p.putClipped(x + inner_x_pad, dy, detail_rows_all[di], inner_w, theme.dim);
            dy += 1;
        }
        if (detail_truncated and dy < bottom_limit) {
            _ = p.putClipped(x + inner_x_pad, dy, "… (command truncated in dialog)", inner_w, theme.hint_faint);
            dy += 1;
        }
    }

    // Rule that matched / asked: explain WHY this dialog appeared, wrapped to
    // stay inside the modal on narrow terminals.
    if (rule_lines > 0 and dy < bottom_limit) {
        var ri: usize = 0;
        while (ri < rule_lines and dy < bottom_limit) : (ri += 1) {
            _ = p.putClipped(x + inner_x_pad, dy, rule_rows_all[ri], inner_w, theme.warn);
            dy += 1;
        }
    }

    // Sandbox note (Phase 25)
    if (sandbox_note and dy < bottom_limit) {
        const note = "sandbox: S runs isolated (project writable, rest read-only)";
        _ = p.putClipped(x + inner_x_pad, dy, note, inner_w, theme.ok);
        dy += 1;
    }

    // Dangerous broad-allow warning
    if (dangerous_suggestion and dy < bottom_limit) {
        const warn = "warning: broad allow can run arbitrary commands";
        _ = p.putClipped(x + inner_x_pad, dy, warn, inner_w, theme.err);
        dy += 1;
    }

    // Options row — always on the last content row, clipped to the border.
    const opts_y: u16 = y + h -| 2;
    const Opt = struct { key: []const u8, label: []const u8, is_always: bool, is_sandbox: bool };
    const opts_all = [_]Opt{
        .{ .key = "Y", .label = "allow once", .is_always = false, .is_sandbox = false },
        .{ .key = "S", .label = "run sandboxed", .is_always = false, .is_sandbox = true },
        .{ .key = "A", .label = "always allow", .is_always = true, .is_sandbox = false },
        .{ .key = "N", .label = "deny", .is_always = false, .is_sandbox = false },
        .{ .key = "ESC", .label = "cancel", .is_always = false, .is_sandbox = false },
    };
    var opts_buf: [5]Opt = undefined;
    var opts_n: usize = 0;
    for (opts_all) |o| {
        if (o.is_always and !allow_always) continue;
        if (o.is_sandbox and !sandbox_note) continue;
        opts_buf[opts_n] = o;
        opts_n += 1;
    }
    const opts = opts_buf[0..opts_n];
    var suggestion_buf: [128]u8 = undefined;
    const suggestion_label_text = if (allow_always) suggestion_label(suggestion, &suggestion_buf) else "";
    var ox: u16 = x + inner_x_pad;
    const right_edge: u16 = x + w -| 2;
    for (opts, 0..) |o, i| {
        if (ox >= right_edge) break;
        const key_w = p.measure(o.key);
        if (ox +| key_w > right_edge) break;
        _ = p.putClipped(ox, opts_y, o.key, right_edge -| ox, theme.brand_bold);
        ox +|= key_w +| 1;
        if (ox >= right_edge) break;
        var label: []const u8 = if (o.is_always and suggestion_label_text.len > 0) suggestion_label_text else o.label;
        // Keep the suggestion label from blowing past the border on narrow/zoomed terminals.
        if (o.is_always and suggestion_label_text.len > 0) {
            const room: usize = @intCast(right_edge -| ox);
            if (room < 18) label = "always allow";
        }
        const label_style = if (i == 0)
            theme.brand
        else if (o.is_sandbox)
            theme.ok
        else if (o.is_always and dangerous_suggestion)
            theme.err
        else
            theme.brand_soft;
        const label_room: u16 = right_edge -| ox;
        ox = p.putClipped(ox, opts_y, label, label_room, label_style);
        if (i + 1 < opts.len and ox + 4 < right_edge) {
            ox = p.putClipped(ox, opts_y, "   ", 3, theme.brand_faint);
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
    return std.mem.print(buf, "always allow {s}", .{suggestion}) catch "";
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
    detail: []const u8,
    rule: ?[]const u8,
    allow_always: bool,
    allow_sandbox: bool,
) void {
    if (height == 0 or width == 0) return;
    // Show critical context when space allows, but never hide the options row.
    const has_ctx = allow_sandbox or rule != null or detail.len > 0;
    const rows: u16 = if (height >= 3 and has_ctx) 3 else if (height >= 2) 2 else 1;
    const y: u16 = height - rows;

    // The whole row is cleared first: the history would show through the
    // question, and a question you cannot read is a question you cannot answer.
    var r: u16 = 0;
    while (r < rows) : (r += 1) {
        expandWideCells(p.surface, y + r, width);
        p.fillRange(0, width, y + r, " ", .{});
    }

    var nb: [96]u8 = undefined;
    const head = std.mem.print(&nb, "⚠ Permission: {s}", .{tool}) catch "⚠ Permission";
    _ = p.putClipped(1, y, head, width -| 2, theme.warn_bold);

    const opts_y: u16 = y + rows - 1;
    if (rows >= 3) {
        // Critical context (clipped). Full modal explains why/effects; compact
        // preserves the most important cue when there is room.
        if (allow_sandbox and std.ascii.eqlIgnoreCase(tool, "bash")) {
            _ = p.putClipped(1, y + 1, "sandbox available (S): OS restrictions if kernel allows", width -| 2, theme.hint);
        } else if (rule) |rname| {
            var rb: [160]u8 = undefined;
            const why = std.mem.print(&rb, "asked by rule: {s}", .{rname}) catch "asked by permission rule";
            _ = p.putClipped(1, y + 1, why, width -| 2, theme.hint);
        } else {
            // Detail summary (first line/chunk), clipped.
            const d = std.mem.trim(u8, detail, " \t\r\n");
            if (d.len > 0) _ = p.putClipped(1, y + 1, d, width -| 2, theme.ink3);
        }
    }

    if (rows >= 2) {
        // Show only the actions the runtime actually accepts; the normal modal
        // already filters "always allow", and the compact fallback must not
        // advertise a key that will be ignored.
        const opts = if (allow_sandbox and std.ascii.eqlIgnoreCase(tool, "bash"))
            (if (allow_always)
                "Y allow · S sandbox · A always · N deny · ESC cancel"
            else
                "Y allow · S sandbox · N deny · ESC cancel")
        else if (allow_always)
            "Y allow · A always · N deny · ESC cancel"
        else
            "Y allow · N deny · ESC cancel";
        _ = p.putClipped(1, opts_y, opts, width -| 2, theme.brand_soft);
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
        const txt = std.mem.print(&buf, "☑ plan {d}/{d} · complete", .{ pl.len, pl.len }) catch "☑ plan complete";
        _ = p.putClipped(1, top, txt, width -| 1, theme.ok);
        return;
    }

    const i = pl.currentIndex() orelse return;
    const item = pl.items[i];
    var buf: [64]u8 = undefined;
    const prefix = std.mem.print(&buf, "{s} plan {d}/{d} · {d} open · ", .{
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
            const prefix = std.mem.print(&marker, "▸ {d} ", .{idx + 1}) catch "▸ ";
            const used = p.putClipped(1, compact_row, prefix, compact_w, theme.selected);
            const marker_cols = used - 1;
            const label = askLineForWidth(p, option, compact_w -| marker_cols, p.arena);
            _ = p.putClipped(used, compact_row, label, compact_w -| marker_cols, theme.selected);
            compact_row += 1;
        }
        if (compact_row < compact_rows) {
            const hint: []const u8 = if (choice_rows > 0)
                "↑↓ choose · Enter · Esc"
            else if (snap.typing)
                "Enter sends · Esc: decide"
            else
                "Type answer below · Esc: decide";
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
        const m = std.mem.print(&mb, "… {d} more lines of the question", .{q_more}) catch "…";
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
            var marker: [8]u8 = undefined;
            // Every row is NUMBERED, including the way out of the menu: an
            // unnumbered last row is the one that reads as chrome ("type your own
            // answer…" looks like a button, not a choice), and a menu whose rows
            // are not all the same shape is hard to scan.
            const mk = if (is_sel)
                std.mem.print(&marker, "▸ {d} ", .{i + 1}) catch "  "
            else
                std.mem.print(&marker, "  {d} ", .{i + 1}) catch "  ";
            const used = p.putClipped(inner_col, row, mk, inner_w, style);
            const marker_cols = used - inner_col;
            const tag_text = if (i == 0 and !is_other) " · Recommended" else "";
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
        "Enter sends · Esc: you decide"
    else if (choice_rows > 0)
        "↑↓ choose · Enter answers · Esc: you decide"
    else
        "Type your answer below · Enter sends · Esc: you decide";
    const ht = std.mem.print(&hb, "{s}", .{hint_txt}) catch hint_txt;
    if (ht.len > 0 and row < last_row) {
        _ = p.putClipped(inner_col, row, ht, inner_w, theme.hint);
    }
    row += 1;

    if (row < last_row) {
        var wb: [32]u8 = undefined;
        const w = std.mem.print(&wb, "waiting {d}s", .{waited_ms / 1000}) catch "";
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
    // The face reports the HARNESS — thinking, writing, running a tool, done,
    // waiting on a human — and nothing else.
    //
    // An active pipeline stage is harness work even when activity flags are
    // between internal waits (e.g. the test suite runs outside the model loop),
    // so the stage/status keeps the mascot and legend in sync.
    const mood: StatusKind = if (act.ask or act.perm)
        .warn
    else if (running_tool or act.subagent_completed < act.subagent_total)
        .tooling
    else if (act.streaming or act.busy)
        .thinking
    else if (self.cancelled)
        // The turn was stopped by ESC: it did not finish, and the face says so
        // until the next turn starts.
        .warn
    else if (self.pipeline_stage) |stage| blk: {
        if (self.status_kind_set and (self.status_kind == .warn or self.status_kind == .err))
            break :blk self.status_kind;
        break :blk if (std.mem.eql(u8, stage, "verify"))
            .tooling
        else if (std.mem.eql(u8, stage, "done"))
            .done
        else
            .thinking;
    } else if (self.busy_started_ns != 0)
        // A turn has run and nothing is running now: `done` until the next one
        // starts, whatever else the status says in between.
        .done
    else
        .idle;

    // Convert tui.StatusKind -> mascot.StatusKind (same variant order, safe cast).
    const m_kind: mascot.StatusKind = switch (mood) {
        .idle => .idle,
        .thinking => .thinking,
        .tooling => .tooling,
        .done => .done,
        .warn => .warn,
        .err => .err,
    };
    // Phase 4 (Zode Motion): reduced/no animation renders a stable pose
    // (representative face, no lean/jump hint) immediately. Continuous motion
    // is only sampled when motion is allowed.
    const now_ms = self.nowMs();
    if (self.motionAllowed()) self.mascot_animator.setKind(m_kind, now_ms);
    const pose = self.mascotPose(m_kind, now_ms);
    const face_text = pose.text;

    var legend: []const u8 = "";
    var detail: []const u8 = "";
    var detail_buf: [96]u8 = undefined;

    // ── pipeline stage: Zo tells you WHAT the harness is doing ──
    //
    // When a pipeline stage is active, the face says THAT stage, not the
    // generic activity. The user never has to guess whether zode is
    // investigating, writing code, running tests or reviewing.
    if (self.verify_counts.hasData()) {
        // Phase 32.1: the pill reads the three-way count. No data never lands
        // here (it reads "setting up" via the pipeline stage / idle branch), so
        // this is always real evidence, never "0 findings" pretending to be one.
        legend = self.verify_phase.label();
        detail = verifycountsCountdown(self, &detail_buf);
    } else if (self.pipeline_stage) |stage| {
        const stage_en = if (std.mem.eql(u8, stage, "explorer")) "exploring" else if (std.mem.eql(u8, stage, "investigator")) "investigating" else if (std.mem.eql(u8, stage, "implementer")) "implementing" else if (std.mem.eql(u8, stage, "tester")) "testing" else if (std.mem.eql(u8, stage, "verify")) "verifying" else if (std.mem.eql(u8, stage, "reviewer")) "reviewing" else if (std.mem.eql(u8, stage, "done")) "done" else stage;
        legend = stage_en;
        // No detail for pipeline stages: the stage name IS the message.
    } else if (act.ask) {
        legend = "waiting for your answer";
        const ms = self.askMillis();
        detail = std.mem.print(&detail_buf, "· {d}s to answer", .{ms / 1000}) catch "";
    } else if (act.perm) {
        legend = "waiting for your permission";
    } else if (act.subagent_total > 0) {
        legend = std.mem.print(&detail_buf, "subagents {d}/{d}", .{
            act.subagent_completed,
            act.subagent_total,
        }) catch "subagents";
    } else if (running_tool) {
        legend = "running";
        const ms = self.toolRunMillis();
        detail = std.mem.print(&detail_buf, "{s} · {d}.{d}s", .{
            running_tool_name.?,
            ms / 1000,
            (ms % 1000) / 100,
        }) catch "";
    } else if (act.streaming) {
        legend = "streaming";
        const ms = self.busyMillis();
        detail = std.mem.print(&detail_buf, "{d}.{d}s", .{ ms / 1000, (ms % 1000) / 100 }) catch "";
    } else if (act.busy) {
        legend = "thinking";
        const ms = self.busyMillis();
        detail = std.mem.print(&detail_buf, "{d}.{d}s", .{ ms / 1000, (ms % 1000) / 100 }) catch "";
    } else {
        // Idle: the agent's own last word, if it said one ("done", "ready").
        legend = self.status();
        if (legend.len == 0) legend = "ready";
        // Phase 5 Review mode (presentation-only): subtle review affordance when
        // idle and there is file/diff context. Never shown during critical states.
        if (self.view_mode == .review and detail.len == 0 and self.lastChangedFile() != null) {
            detail = "review: /diff /hunk /file";
        }
    }
    if (queued > 0) {
        var qbuf: [32]u8 = undefined;
        const q = std.mem.print(&qbuf, "{d} queued", .{queued}) catch "";
        if (q.len > 0) {
            if (detail.len > 0) {
                var both: [128]u8 = undefined;
                detail = std.mem.print(&both, "{s} · {s}", .{ detail, q }) catch detail;
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
                    std.mem.print(&tbuf, "{s}…", .{trimmed[0..39]}) catch "";
                if (shown.len > 0) {
                    var both: [192]u8 = undefined;
                    const joined = std.mem.print(&both, "{s} · {s}", .{ detail, shown }) catch "";
                    if (joined.len > 0) detail = joined;
                }
            }
        }
    }

    // How much room the left group's CORE needs, in columns: the face ONLY.
    //
    // It used to include the whole legend, and the legend is whatever the last
    // status said. `/yolo` writes a sentence, so turning it on made `room` zero
    // and the right group — the model, the context gauge — was dropped from the
    // row: the status bar "disappeared". The face and the right group are what
    // the row cannot do without; the legend is text, and `putClipped` truncates
    // it to whatever is left.
    const left_core: u16 = face_width + 2;

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
        const speed = std.mem.print(&tb, "⚡ {d:.0} tok/s", .{agent.tps_live}) catch "";
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
            const txt = std.mem.print(&nb2, "↓ {d} new", .{unseen}) catch label;
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
    // `YOLO` in the accent colour, next to the face: the mode is a state of the
    // harness and two words say it, without spending the row. The old /yolo
    // sentence went into the legend and pushed the status bar off the right
    // end; the bar stays and this is the mark.
    if (agent.currentPermMode() == .bypass and col + 5 <= left_limit) {
        _ = p.putClipped(col, row, "YOLO", left_limit -| col, theme.brand_bold);
        col += 5;
    }
    if (legend.len > 0) {
        // The legend is WHITE and the face is COLOURED, on purpose: with both
        // in the theme's teal the face and its own label read as one smudge
        // (they were the same colour, and the same pixels, for the "tooling"
        // mood). The face carries the mood; the word carries the phase.
        var legend_style = theme.ink;
        legend_style.bold = true;
        // Clipped WITH an ellipsis: the legend is whatever the last status said,
        // it can outgrow the room left after the right group, and a word cut in
        // half reads as a typo. The budget is inside the columns, so the row
        // never grows and the status bar keeps its space.
        const avail = left_limit -| col;
        var lbuf: [textcap.scratchFor(192)]u8 = undefined;
        const shown = textcap.clipInto(legend, avail, &lbuf);
        col = p.putClipped(col, row, shown, avail, legend_style);
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
        // The segment's own style, and NOT the well's background: the footer's
        // row sits on the terminal's background (like the face on its left),
        // and forcing a panel colour here painted the right half of the row as
        // a strip of a different black.
        const st = sg.style;
        var it = vaxis.unicode.graphemeIterator(sg.text);
        while (it.next()) |g| {
            const b = g.bytes(sg.text);
            const w = theme.graphemeWidth(p.ctx, b);
            if (rcol + w <= p.width) _ = p.putStable(rcol, row, b, w, st);
            rcol += w;
        }
    }
}

fn drawTranscriptSearchBar(p: *Painter, m: *const Model, width: u16, height: u16) void {
    if (!m.search_bar_active) return;
    const box_w: u16 = @min(width -| 4, 80);
    if (box_w < 20 or height < 3) return;
    const x0 = (width - box_w) / 2;
    const y0 = if (height > 6) height - 4 else 0;
    p.fillRange(x0, x0 + box_w, y0, " ", theme.selected);
    var buf: [192]u8 = undefined;
    const q = m.search_query_buf[0..m.search_query_len];
    const label = std.mem.print(&buf, " / {s}_  (Enter search, Esc close)", .{q}) catch " / ";
    _ = p.putClipped(x0 + 1, y0, label, box_w -| 2, theme.selected);
}

fn drawTranscriptView(p: *Painter, m: *Model, width: u16, height: u16) void {
    if (!m.transcript_view_active) return;
    const box_w: u16 = if (width > 8) width - 4 else width;
    const box_h: u16 = if (height > 4) height - 2 else height;
    if (box_w < 20 or box_h < 6) return;
    const x0 = (width - box_w) / 2;
    const y0 = (height - box_h) / 2;

    var wr: u16 = 0;
    while (wr < box_h) : (wr += 1) {
        expandWideCells(p.surface, y0 + wr, width);
        p.fillRange(x0, x0 + box_w, y0 + wr, " ", .{});
    }
    drawRoundedBox(p, x0, y0, box_w, box_h, .{}, theme.line_bright);

    var title_buf: [96]u8 = undefined;
    const mode: []const u8 = if (m.transcript_view_show_all) "show all" else "compact";
    const title = std.mem.print(&title_buf, " Transcript ({s}) ", .{mode}) catch " Transcript ";
    _ = p.putText(x0 + 2, y0, title, theme.accent_bold);
    const hint = " ↑↓/j k scroll · PgUp/PgDn · g/G · Ctrl+E show all · Ctrl+O/Esc close ";
    _ = p.putClipped(x0 + 2, y0 + box_h - 1, hint, box_w -| 4, theme.hint);

    const content_y = y0 + 1;
    const content_h: usize = @intCast(box_h -| 2);
    if (content_h == 0) return;

    // Collect visible lines from paragraph texts (view of existing history, no new content).
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(p.ctx.arena);
    for (m.paras.items, 0..) |*para, pi| {
        const kind_label: []const u8 = switch (para.kind) {
            .user => "user",
            .assistant => "assistant",
            .tool => "tool",
            .diff => "diff",
            .info => "info",
            .error_msg => "error",
            .banner => "banner",
            else => "text",
        };
        var hdr: [96]u8 = undefined;
        const header = std.mem.print(&hdr, "[{d}] {s}", .{ pi + 1, kind_label }) catch kind_label;
        lines.append(p.ctx.arena, p.ctx.arena.dupe(u8, header) catch header) catch {};

        const text = para.textLive(m.allocator);
        if (text.len == 0) {
            lines.append(p.ctx.arena, "") catch {};
            lines.append(p.ctx.arena, "") catch {};
            continue;
        }
        if (!m.transcript_view_show_all and text.len > 1200) {
            // Compact mode: show a bounded preview of very long content.
            var it = std.mem.splitScalar(u8, text[0..@min(text.len, 1200)], '\n');
            var shown: usize = 0;
            while (it.next()) |ln| {
                if (shown >= 12) break;
                lines.append(p.ctx.arena, ln) catch {};
                shown += 1;
            }
            if (shown >= 12) lines.append(p.ctx.arena, "… (Ctrl+E to show all)") catch {};
        } else {
            var it = std.mem.splitScalar(u8, text, '\n');
            var shown: usize = 0;
            const max_lines: usize = if (m.transcript_view_show_all) 400 else 80;
            while (it.next()) |ln| {
                if (shown >= max_lines) {
                    lines.append(p.ctx.arena, "… (content truncated in transcript view)") catch {};
                    break;
                }
                lines.append(p.ctx.arena, ln) catch {};
                shown += 1;
            }
        }
        lines.append(p.ctx.arena, "") catch {};
    }

    if (lines.items.len == 0) {
        _ = p.putClipped(x0 + 2, content_y, "(no transcript history)", box_w -| 4, theme.hint);
        return;
    }

    const max_scroll = if (lines.items.len > content_h) lines.items.len - content_h else 0;
    const scroll = @min(m.transcript_view_scroll, max_scroll);
    m.transcript_view_scroll = scroll;

    var i: usize = 0;
    while (i < content_h and scroll + i < lines.items.len) : (i += 1) {
        const row = content_y + @as(u16, @intCast(i));
        const line = lines.items[scroll + i];
        const style = if (line.len > 0 and line[0] == '[') theme.accent else theme.ink;
        _ = p.putClipped(x0 + 2, row, line, box_w -| 4, style);
    }
}

fn drawDiffViewer(p: *Painter, m: *const Model, width: u16, height: u16) void {
    const n = m.file_intel_len;
    if (n == 0) return;

    const box_w: u16 = @min(width -| 4, 120);
    const box_h: u16 = @min(height -| 4, 32);
    if (box_w < 40 or box_h < 10) return;
    const x0 = (width - box_w) / 2;
    const y0 = (height - box_h) / 6;

    var wr: u16 = 0;
    while (wr < box_h) : (wr += 1) {
        expandWideCells(p.surface, y0 + wr, width);
        p.fillRange(x0, x0 + box_w, y0 + wr, " ", .{});
    }
    drawRoundedBox(p, x0, y0, box_w, box_h, .{}, theme.line_bright);

    const sel = @min(m.diff_viewer_sel, n - 1);
    var title_buf: [96]u8 = undefined;
    const title = std.mem.print(&title_buf, " Diff viewer  ({d}/{d} files) ", .{ sel + 1, n }) catch " Diff viewer ";
    _ = p.putText(x0 + 2, y0, title, theme.accent_bold);
    const hint = " ↑↓ file · PgUp/PgDn scroll · Enter jump · Esc close ";
    _ = p.putClipped(x0 + 2, y0 + box_h - 1, hint, box_w -| 4, theme.hint);

    // File list area
    const list_rows: u16 = @min(@as(u16, @intCast(@min(n, 6))), box_h -| 8);
    var i: usize = 0;
    while (i < n and i < list_rows) : (i += 1) {
        const e = &m.file_intel[i];
        const path = e.pathOf();
        const row = y0 + 1 + @as(u16, @intCast(i));
        const selected = i == sel;
        if (selected) p.fillRange(x0 + 1, x0 + box_w - 1, row, " ", theme.selected);
        var line_buf: [256]u8 = undefined;
        const marker: []const u8 = if (selected) "▸ " else "  ";
        const info = m.fileIntelLabel(path);
        const op_word = Model.fileIntelOpWord(e);
        const text = if (e.added == 0 and e.removed == 0)
            if (info.has)
                (std.mem.print(&line_buf, "{s}{s} [{s}] {s}  (unchanged)", .{ marker, op_word, info.label, path }) catch path)
            else
                (std.mem.print(&line_buf, "{s}{s} {s}  (unchanged)", .{ marker, op_word, path }) catch path)
        else if (info.has)
            (std.mem.print(&line_buf, "{s}{s} [{s}] {s}  +{d} -{d}", .{ marker, op_word, info.label, path, e.added, e.removed }) catch path)
        else
            (std.mem.print(&line_buf, "{s}{s} {s}  +{d} -{d}", .{ marker, op_word, path, e.added, e.removed }) catch path);
        const style = if (selected) theme.selected else theme.ink;
        _ = p.putClipped(x0 + 2, row, text, box_w -| 4, style);
    }

    const sep_y = y0 + 1 + list_rows;
    if (sep_y + 2 < y0 + box_h - 1) {
        p.fillRange(x0 + 1, x0 + box_w - 1, sep_y, "─", theme.rule);
    }

    // Diff content area
    const diff_top = sep_y + 1;
    const diff_bottom = y0 + box_h - 2;
    if (diff_bottom <= diff_top) return;
    const diff_rows: usize = diff_bottom - diff_top + 1;

    const para_idx_opt = m.diffViewerSelectedPara();
    if (para_idx_opt == null or para_idx_opt.? >= m.paras.items.len) {
        _ = p.putClipped(x0 + 2, diff_top, "(no diff content available for this file)", box_w -| 4, theme.hint);
        return;
    }
    const para = m.paras.items[para_idx_opt.?];
    if (para.kind != .diff) {
        _ = p.putClipped(x0 + 2, diff_top, "(selected entry is not a diff)", box_w -| 4, theme.hint);
        return;
    }

    // Count lines and render visible window
    var total_lines: usize = 0;
    {
        var it = std.mem.splitScalar(u8, para.text, '\n');
        while (it.next()) |_| total_lines += 1;
    }
    const max_scroll = if (total_lines > diff_rows) total_lines - diff_rows else 0;
    const scroll = @min(m.diff_viewer_scroll, max_scroll);

    var line_idx: usize = 0;
    var drawn: usize = 0;
    var it = std.mem.splitScalar(u8, para.text, '\n');
    while (it.next()) |line| : (line_idx += 1) {
        if (line_idx < scroll) continue;
        if (drawn >= diff_rows) break;
        const row = diff_top + @as(u16, @intCast(drawn));
        const style: vaxis.Style = if (line.len > 0) switch (line[0]) {
            '+' => theme.diff_add,
            '-' => theme.diff_del,
            '@' => theme.diff_hunk,
            '\\' => theme.hint,
            else => theme.diff_ctx,
        } else theme.diff_ctx;
        _ = p.putClipped(x0 + 2, row, line, box_w -| 4, style);
        drawn += 1;
    }
}

/// A piece of the footer's right-hand group, with its style.
pub const InfoSeg = struct { text: []const u8, style: vaxis.Style };

/// The RIGHT zone of the footer: the model name.
///
/// The footer is for the things you read without thinking: what model am I
/// talking to right now. Everything else (provider, ctx%, tokens, cache, mode)
/// has a command: `/context`, `/cache`, `/bench`, `/provider`.
pub fn sessionInfo(m: *Model, arena: std.mem.Allocator) ?[]const InfoSeg {
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

    // Permission mode: only show when NOT default (read-only is a deviation).
    //
    // `accept_edits` is shown as a GLYPH, and that is the point: the mode
    // decides whether the next tool call asks, and the only way to know is to
    // look. A word costs twelve columns in a footer that has to survive an
    // eighty-column terminal; a glyph costs one.
    //
    // The shapes are the ones the reference implementation uses: `◐` for
    // accept-edits and `●` for read-only. The DEFAULT and BYPASS show nothing:
    // the default is the default, and bypass is marked ONCE, by the `YOLO` chip
    // next to the face — two marks for one mode read as two different states.
    switch (agent.currentPermMode()) {
        .read_only, .accept_edits => {
            if (out.items.len > 0) {
                out.append(arena, .{ .text = " · ", .style = theme.line }) catch return null;
            }
            const glyph = switch (agent.currentPermMode()) {
                .accept_edits => "◐",
                .read_only => "●",
                .bypass, .default => "",
            };
            out.append(arena, .{ .text = glyph, .style = theme.warn }) catch return null;
        },
        .bypass, .default => {},
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
    // Phase 5 Focus mode: reduce secondary chrome (runtime state unchanged).
    if (m.view_mode != .focus and chat.effortSupport(shown_model) != .none) {
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

    // Phase 5 workbench view mode (presentation-only, secondary metadata).
    if (m.view_mode != .normal) {
        if (out.items.len > 0) {
            out.append(arena, .{ .text = " · ", .style = theme.line }) catch return null;
        }
        out.append(arena, .{ .text = m.view_mode.name(), .style = theme.brand }) catch return null;
    }

    if (out.items.len == 0) return null;
    return out.items;
}

/// Context gauge segments for the footer: the context percentage.
fn contextInfo(arena: std.mem.Allocator) ?[]const InfoSeg {
    // Genuinely missing context is not shown at all: no number is an answer
    // ("not tracked yet"), a fake one is a lie the user has to detect.
    if (agent.ctx_used == 0 and !agent.ctx_real) return null;
    var out: std.ArrayList(InfoSeg) = .empty;
    const label = if (agent.ctx_real) "ctx" else "ctx~";
    const pct_suffix = if (agent.ctx_pct > 999) ">" else "";
    out.append(arena, .{ .text = label, .style = theme.status }) catch return null;
    out.append(arena, .{ .text = " ", .style = theme.status }) catch return null;
    var nb: [8]u8 = undefined;
    const pct_txt = std.mem.print(&nb, "{d}{s}%", .{ agent.ctx_pct, pct_suffix }) catch return null;
    // The percentage is printed with `putStable`, which does NOT copy the
    // bytes: `pct_txt` points at THIS frame's stack, and the renderer reads
    // the cells after the frame is over. It has to live in the frame's arena.
    //
    // This was a real bug, and it was invisible: the number usually came out
    // right because the stack still held the bytes, and came out as garbage
    // when it did not.
    const owned = arena.dupe(u8, pct_txt) catch return null;
    out.append(arena, .{ .text = owned, .style = theme.status }) catch return null;
    // Cache-hit shown only with >=2 requests (first is always 0% cold).
    if (cacheStats().requests >= 2) {
        out.append(arena, .{ .text = " · ", .style = theme.line }) catch return null;
        out.append(arena, .{ .text = "cache", .style = theme.status }) catch return null;
        out.append(arena, .{ .text = " ", .style = theme.status }) catch return null;
        const hit = cacheStats().hitRatePct();
        var hb: [8]u8 = undefined;
        const hit_txt = std.mem.print(&hb, "{d:.0}%", .{hit}) catch return out.items;
        const owned_hit = arena.dupe(u8, hit_txt) catch return out.items;
        out.append(arena, .{ .text = owned_hit, .style = theme.status }) catch return null;
    }
    return out.items;
}

fn cacheStats() cache_stats.CacheStats {
    return cache_stats.session;
}

/// Width in COLUMNS of a group of status segments.
///
/// Measured with the grapheme iterator and not with `.len`: `⚡` is 3 bytes for 1
/// column, so aligning by bytes throws the whole row off center. Both columns
/// use this function, and they have to measure IDENTICALLY or they overlap.
pub fn segsWidth(segs: []const InfoSeg) u16 {
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

/// The Settings screen: a full-surface two-column layout, deliberately a
/// DIFFERENT shape from drawPicker so it never reads as "the model picker
/// again". Left column = sections, right column = rows with current values,
/// bottom detail = description and output-style preview.
/// The activity-strip detail for a verify report. Uses the +1 counter so the
/// numbers climb toward the target instead of jumping to the final count.
fn verifycountsCountdown(m: *Model, buf: []u8) []const u8 {
    var c = m.verify_counts;
    // Only show as many findings as the animation has reached.
    const shown = m.verify_counter.shown;
    const total: usize = c.found + c.verified + c.refuted;
    if (shown < total) {
        var left = shown;
        c.refuted = 0;
        c.verified = @min(c.verified, left);
        left -= c.verified;
        c.found = @min(c.found, left);
    }
    const text = c.format(m.allocator) catch return "";
    defer m.allocator.free(text);
    return std.mem.print(buf, "· {s}", .{text}) catch "";
}

fn drawSettingsScreen(p: *Painter, m: *Model, width: u16, height: u16) void {
    if (width < 40 or height < 12) return;
    const secs = configmenu.all_sections;
    const sec = secs[@min(m.settings_section, secs.len - 1)];
    const rows = configmenu.settingsFor(sec);

    // Opaque background: clear every cell so nothing from the transcript
    // shows through the screen.
    var row: u16 = 0;
    while (row < height) : (row += 1) {
        p.fillRow(row, " ", .{});
    }

    const left_w: u16 = @intCast(@min(@as(usize, 34), @as(usize, width) / 3));
    const split: u16 = left_w + 1;
    const top: u16 = 2;
    const bottom: u16 = height - 2;

    // Title and keyboard hints.
    _ = p.putText(2, 0, "Settings · internal configuration", theme.brand_hi);
    const hint = "Tab column · ↑↓ move · ←→ value · Enter cycle · Esc back";
    const hint_x: u16 = if (width > hint.len + 2) @intCast(width - hint.len - 2) else 2;
    _ = p.putClipped(hint_x, 0, hint, width - hint_x - 1, theme.ink3);
    p.fillRange(0, width, 1, "─", theme.line_bright);

    // Vertical divider between columns.
    row = top;
    while (row <= bottom) : (row += 1) {
        p.putStable(split, row, "│", 1, theme.line);
    }

    // Left column: sections.
    for (secs, 0..) |s, i| {
        const y = top + @as(u16, @intCast(i)) + 1;
        if (y > bottom) break;
        const chosen = i == m.settings_section;
        if (chosen) p.fillRange(1, split, y, " ", theme.sel_bg);
        const mark: []const u8 = if (chosen) "▸ " else "  ";
        _ = p.putText(2, y, mark, if (chosen) theme.brand else theme.ink3);
        _ = p.putClipped(4, y, s.label(), left_w - 4, if (chosen) theme.selected else theme.ink);
        if (chosen and m.settings_col == 0) {
            p.putStable(1, y, "│", 1, theme.brand);
        }
    }

    // Right column: the selected section's rows and their current values.
    const rx: u16 = split + 2;
    const rw: u16 = width - rx - 2;
    for (rows, 0..) |s, i| {
        const y = top + @as(u16, @intCast(i)) + 1;
        if (y > bottom - 5) break;
        const chosen = i == m.settings_row;
        if (chosen) p.fillRange(rx - 1, width - 1, y, " ", theme.sel_bg);
        const value = commands.settingsValue(m, s);
        defer m.allocator.free(value);
        _ = p.putClipped(rx, y, s.label(), 24, if (chosen) theme.selected else theme.ink);
        var shown = value;
        if (shown.len == 0) shown = "(not set)";
        if (shown.len > 28) shown = shown[0..28];
        _ = p.putClipped(rx + 25, y, shown, rw - 25, if (chosen) theme.brand_hi else theme.ink2);
        if (s.persisted()) {
            _ = p.putText(width - 10, y, "saved", theme.ok);
        }
        if (chosen and m.settings_col == 1) {
            p.putStable(rx - 1, y, "▸", 1, theme.brand);
        }
    }

    // Detail area: description + output-style preview (last 4 rows).
    const dtop: u16 = bottom - 3;
    p.fillRange(rx - 1, width - 1, dtop - 1, "─", theme.line);
    if (m.settings_row < rows.len) {
        const s = rows[@min(m.settings_row, rows.len - 1)];
        _ = p.putClipped(rx, dtop, s.description(), rw, theme.ink2);
        if (s == .output_style) {
            const body = agent.stylePreview(m.allocator, m.environ) catch "";
            defer if (body.len > 0) m.allocator.free(body);
            if (body.len > 0) {
                _ = p.putClipped(rx, dtop + 1, body, rw, theme.code_comment);
            }
        }
    }
    _ = p.putText(2, height - 1, "Esc: close · changes apply now and are saved to config.json", theme.ink3);
}

fn drawPicker(p: *Painter, width: u16, height: u16, ps: PickerSnapshot) void {
    const is_sessions = ps.tag == sessions_picker_tag;
    // Bottom-anchored modal pane (33.5): keeps 2 transcript rows visible above a ▔ divider.
    const box_w: u16 = if (width > 2) width else 20;
    const desired_h: u16 = @as(u16, if (ps.preview) 20 else 13);
    const max_h: u16 = if (height > 3) height - 2 else height; // leave >=2 transcript rows above divider
    var box_h: u16 = @min(desired_h, max_h);
    if (box_h < 7) box_h = @min(@as(u16, 7), height);
    if (box_w < 20 or box_h < 6 or height < 8) return;

    var y0: u16 = if (height > box_h) height - box_h else 0;
    if (y0 < 2) {
        y0 = 2;
        box_h = if (height > y0) height - y0 else box_h;
    }
    const x0: u16 = 0;

    var wr: u16 = 0;
    while (wr < box_h) : (wr += 1) {
        const row = y0 + wr;
        if (row >= height) break;
        expandWideCells(p.surface, row, width);
        p.fillRange(0, box_w, row, " ", .{});
    }

    // Top divider (▔) keeps 2 transcript rows visible above the pane.
    var dx: u16 = 0;
    while (dx < box_w) : (dx += 1) {
        _ = p.putStable(x0 + dx, y0, "▔", 1, theme.line_bright);
    }

    // title with dynamic position for session picker (29.3/29.4)
    var tbuf: [128]u8 = undefined;
    const pos = if (ps.total > 0) ps.sel + 1 else 0;
    const t1 = if (is_sessions)
        (std.mem.print(&tbuf, " {s}  ({d} of {d})", .{ ps.title, pos, ps.total }) catch " Resume")
    else
        (std.mem.print(&tbuf, " {s}", .{ps.title}) catch " picker");
    _ = p.putText(x0 + 2, y0 + 1, t1, theme.accent_bold);

    var qbuf: [96]u8 = undefined;
    const q1 = if (ps.query.len > 0)
        std.mem.print(&qbuf, "filter: {s}_", .{ps.query}) catch "filter: _"
    else
        "filter: (type to search)";
    _ = p.putText(x0 + 2, y0 + 2, q1, theme.dim);

    // Layout: divider/title/filter/content/footer
    const content_top = y0 + 3;
    const footer_row = y0 + box_h - 1;
    const item_rows: usize = if (footer_row > content_top) footer_row - content_top else 0;

    if (ps.preview and ps.preview_lines.len > 0) {
        // In-place preview (29.4): same markdown parser/styles, never a summary.
        var pi: usize = 0;
        while (pi < ps.preview_lines.len and pi < item_rows) : (pi += 1) {
            const row = content_top + @as(u16, @intCast(pi));
            if (row >= footer_row) break;
            const raw = ps.preview_lines[pi];
            if (raw.len == 0) continue;
            const kindc = raw[0];
            const text = raw[1..];
            const st: vaxis.Style = switch (kindc) {
                'U' => theme.user,
                'A' => theme.text,
                'T' => theme.tool_res,
                'E' => theme.err,
                'D' => theme.diff_add,
                else => theme.dim,
            };
            p.fillRange(x0, x0 + box_w, row, " ", .{});
            _ = p.putClipped(x0 + 2, row, text, box_w -| 4, st);
        }
    } else {
        for (ps.items, 0..) |it, i| {
            if (i >= item_rows) break;
            const row = content_top + @as(u16, @intCast(i));
            if (row >= footer_row) break;
            const is_sel = ps.first_visible + i == ps.sel;
            if (is_sel) {
                p.fillRange(x0, x0 + box_w, row, " ", theme.selected);
                _ = p.putText(x0 + 1, row, "▸", theme.brand_bold);
            } else {
                p.fillRange(x0, x0 + box_w, row, " ", .{});
            }
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
                _ = p.putClipped(after, row, it.desc, if (after < box_w - 2) box_w - 2 - after else 0, if (is_sel) theme.selected else theme.dim);
            }
        }
    }

    // footer (29.4): must say when esc clears filter
    var fbuf: [160]u8 = undefined;
    var f1_text: []const u8 = "";
    if (ps.semantic_searching) {
        f1_text = "Searching…  ·  esc cancel";
    } else if (is_sessions and ps.query.len > 0) {
        f1_text = std.mem.print(
            &fbuf,
            "\u{2191}\u{2193} nav · enter resume · ctrl+v preview · ctrl+s semantic · esc clears filter ({d}/{d})",
            .{ pos, ps.total },
        ) catch "esc clears filter · esc closes";
    } else if (is_sessions) {
        const sem = if (ps.semantic_mode) " · semantic" else "";
        f1_text = std.mem.print(
            &fbuf,
            "\u{2191}\u{2193} nav · enter resume · ctrl+v preview · ctrl+a/b scope · ctrl+s semantic{s} · esc close ({d}/{d})",
            .{ sem, pos, ps.total },
        ) catch "enter resume · esc close";
    } else if (ps.query.len > 0) {
        f1_text = std.mem.print(
            &fbuf,
            "\u{2191}\u{2193} navigate · enter select · esc clears filter · esc closes  ({d}/{d})",
            .{ pos, ps.total },
        ) catch "esc clears filter · esc closes";
    } else {
        f1_text = std.mem.print(
            &fbuf,
            "\u{2191}\u{2193} navigate · enter select · esc close  ({d}/{d})",
            .{ pos, ps.total },
        ) catch "";
    }
    _ = p.putClipped(x0 + 2, footer_row, f1_text, box_w -| 4, theme.dim);
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
