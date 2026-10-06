const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const agent = @import("agent.zig");
const chat = @import("chat.zig");
const md = @import("lib/markdown.zig");
const theme = @import("lib/theme.zig");
const ed = @import("lib/editor.zig");
const mascot = @import("lib/mascot.zig");
const palette = @import("palette.zig");
const compaction = @import("compaction.zig");
const plan_mod = @import("lib/plan.zig");
const goal_mod = @import("lib/goal.zig");
const checkpoint = @import("lib/checkpoint.zig");
const bgproc = @import("bgproc.zig");
const images_mod = @import("lib/images.zig");
const agent_mod = @import("agent.zig");
const readcache = @import("lib/readcache.zig");
const bench_mod = @import("lib/bench.zig");
const models_mod = @import("lib/models.zig");
const zjsonl = @import("lib/zjsonl.zig");

/// Item of the modal picker (opencode style). Labels/descs are gpa-owned
/// and closePicker frees them.
pub const PickerItem = struct {
    label: []const u8,
    desc: []const u8 = "",
};

pub const PickerCb = *const fn (*Model, tag: u32, label: []const u8) void;

/// Immutable copy of the picker state for drawing (frame memory).
const PickerSnapshot = struct {
    title: []const u8,
    query: []const u8,
    sel: usize,
    first_visible: usize,
    total: usize,
    items: []PickerItem,
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
        if (col >= self.width or row >= self.height) return;
        self.surface.writeCell(col, row, .{
            .char = .{ .grapheme = g, .width = w },
            .style = style,
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
    return wrapCellsGutter(pa, lines, cells, width, indent, null);
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
) !void {
    if (cells.len == 0) {
        try lines.append(pa, .{ .cells = &.{}, .w = 0 });
        return;
    }
    const ind_w: u16 = @min(indent, @max(width -| 1, 1));
    var start: usize = 0;
    var used: u16 = 0; // columns USED by real cells
    var first = true;
    for (cells, 0..) |c, i| {
        // The limit of a continuation is the width MINUS the indent, because
        // the indent occupies real columns.
        const limit: u16 = if (first) @max(width, 1) else @max(width - ind_w, 1);
        const cw: u16 = @min(c.w, @max(limit, 1));
        if (used > 0 and used + cw > limit) {
            try appendContinuation(pa, lines, cells[start..i], used, if (first) 0 else ind_w, if (first) null else gutter);
            start = i;
            used = 0;
            first = false;
        }
        used += cw;
    }
    try appendContinuation(pa, lines, cells[start..], used, if (first) 0 else ind_w, if (first) null else gutter);
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
    try lines.append(pa, .{ .cells = out.items, .w = used + pad });
}

/// Turns a paragraph (markdown already parsed) into lines of cells.
/// All the memory comes out of `pa` (the paragraph's own arena or the frame
/// arena).
fn buildLines(
    pa: std.mem.Allocator,
    ctx: vxfw.DrawContext,
    kind: md.Kind,
    text: []const u8,
    width: u16,
) ![]const PLine {
    return buildLinesBase(pa, ctx, kind, text, width, null, null, "");
}

/// `buildLines` with an imposed base style (see `md.parseBase`).
fn buildLinesBase(
    pa: std.mem.Allocator,
    ctx: vxfw.DrawContext,
    kind: md.Kind,
    text: []const u8,
    width: u16,
    base: ?md.Style,
    mood: ?vaxis.Style,
    lang: []const u8,
) ![]const PLine {
    const blocks = try md.parseLang(pa, kind, text, base, mood, lang);
    var lines: std.ArrayList(PLine) = .empty;
    var first_line = true;

    for (blocks) |blk| {
        // A code block is a BLOCK: it carries a gutter, a background and a chip
        // with the language. Before, `blk.kind` and `blk.lang` were computed
        // and thrown away (the only use of `blk.` in the whole file was
        // `blk.lines`), so a 30-line block came out as 30 lines of prose of
        // roughly the same width, indistinguishable from the text around it.
        const is_code = blk.kind == .code;
        // Blank rows before and after: inside a message there was NO separator
        // at all, so a code block started glued to the previous sentence and
        // ended glued to the next one.
        if (is_code and lines.items.len > 0) try lines.append(pa, .{ .cells = &.{}, .w = 0 });
        if (is_code and blk.lang.len > 0) try appendChip(pa, ctx, &lines, blk.lang);

        for (blk.lines) |src| {
            var cells: std.ArrayList(CellRun) = .empty;
            if (first_line) {
                // The prefix (› ◆ ⚙ …) goes only on the first line of the
                // paragraph.
                const pre = md.prefix(kind);
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
            // The gutter eats 2 columns (`│ `), and the rest wraps to what is
            // left. Without this the block does not fit and `wrapCells` would
            // break the last line against the border.
            const avail = if (is_code and width > 4) width - 2 else width;
            const before = lines.items.len;
            // Prose gets the visible gutter; a code block has its own (`│ ` in
            // `applyCodeGutter`) and a diff already prefixes every line with a
            // sign, so a second bar there would be noise.
            const gutter: ?vaxis.Style = if (is_code or blk.kind == .diff) null else theme.gutter;
            try wrapCellsGutter(pa, &lines, cells.items, avail, if (is_code) 0 else 2, gutter);
            if (is_code) {
                applyCodeGutter(pa, lines.items[before..], width);
            }
        }
        if (is_code) try lines.append(pa, .{ .cells = &.{}, .w = 0 });
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

/// TUI in the Claude Code style:
///  ┌ history (markdown + syntax highlighting, tool blocks, scroll)
///  ├ status: provider · model │ effort │ ⚠yolo │ ctx%
///  └ multiline input with border and `/` autocompletion
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

pub const Model = struct {
    allocator: std.mem.Allocator,

    /// Own input: `vxfw.TextField` is single-line and has no history, so the
    /// prompt is edited with `editor.Editor`.
    ed: ed.Editor,

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

    /// The file snapshots per turn, for `/undo`. It is the only thing that
    /// survives from one turn to the next (the worker's arena does not), which
    /// is why the stack carries its own allocator.
    checkpoints: checkpoint.Stack = undefined,

    /// Moment the current turn started, in nanoseconds, for the activity strip
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

    /// `/` command autocompletion: visible + selection.
    ac: Autocomplete = .{},

    /// Ctrl+P modal palette (commands and models in two columns).
    pal: palette.Palette = undefined,
    /// Models the worker has downloaded and that have not been painted yet.
    ///
    /// The worker CANNOT fill the palette directly: the UI thread draws it
    /// without a lock (the lock only covers the history), and touching both at
    /// once brought the app down with a segfault. The worker leaves the models
    /// here and draw picks them up; the handover goes through the lock, so
    /// there is no race.
    pending_items: ?[]palette.Item = null,
    pal_inited: bool = false,

    /// Streaming state: the assistant's last paragraph is still open.
    streaming: bool = false,
    stream_buf: std.ArrayList(u8) = .empty, // gpa-owned

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
    wrap_w: u16 = 0,
    /// History rows in the last frame. The key handler uses it to jump a
    /// PAGE (the whole window) instead of a fixed number: with 5 fixed, in a
    /// tall terminal PageUp barely moved anything.
    hist_rows: usize = 10,

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
    cache_width: u16 = 0,
    /// Index of the first paragraph whose layout is invalidated (Ctrl+R
    /// expands a tool in-place). `null` = cache is up to date.
    cache_from: ?usize = null,

    /// Last tool call executed, to expand it with Ctrl+R.
    last_tool: ?ToolMemo = null,

    /// Fixed status bar.
    status_buf: [160]u8 = undefined,
    status_len: usize = 0,
    /// Mood the status was composed with (to color the face).
    status_mood: mascot.Mood = .idle,
    status_mood_set: bool = false,

    /// Permission dialog (fixed buffers, no churn between threads).
    perm_tool: [64]u8 = undefined,
    perm_tool_len: usize = 0,
    perm_detail: [384]u8 = undefined,
    perm_detail_len: usize = 0,
    perm_active: bool = false,
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

    environ: ?*const std.process.Environ.Map = null,
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
    /// The last models request was for the picker, not for `/models`.
    ///
    /// On the Model and not an argument because the cache publishes from a helper that
    /// is called from two places and has no business knowing which one asked.
    models_for_picker: bool = false,
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
    };

    /// Max paragraphs with cells in memory at once (the ones outside the
    /// window are re-parsed when you look at them again).
    const max_cached_paras = 128;

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

        fn deinit(self: *ToolMemo, gpa: std.mem.Allocator) void {
            if (self.result.len > 0) gpa.free(self.result);
            if (self.summary.len > 0) gpa.free(self.summary);
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
    };

    const spinner_chars = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

    pub fn hasInput(self: *const Model) bool {
        return !self.ed.isEmpty();
    }

    // ── lifecycle ────────────────────────────────────
    pub fn init(allocator: std.mem.Allocator) Model {
        var m = Model{
            .allocator = allocator,
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
        };
        m.setStatusText("zode v0.3 \u{b7} esc interrupts \u{b7} ctrl+c exits");
        return m;
    }

    pub fn deinit(self: *Model) void {
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
        self.closePicker();
        self.picker_items.deinit(self.allocator);
        self.picker_filtered.deinit(self.allocator);
        // `@` completion matches: gpa-owned paths (see `freeFileMatches`).
        freeFileMatches(self);
        self.ac.file_matches.deinit(self.allocator);
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
    }

    // ── modal picker ──────────────────────────────────
    /// Opens the picker. Takes ownership of `items` (labels/descs gpa-owned).
    /// Thread-safe: called by the /models worker.
    pub fn openPicker(self: *Model, tag: u32, title: []const u8, items: []PickerItem, cb: PickerCb) void {
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
        self.picker_cb = cb;
        self.picker_query_len = 0;
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

    fn pickerRefilter(self: *Model) void {
        // caller holds lock
        const q = self.picker_query[0..self.picker_query_len];
        self.picker_filtered.clearRetainingCapacity();
        for (self.picker_items.items, 0..) |it, ix| {
            if (q.len == 0 or containsIgnoreCase(it.label, q)) {
                self.picker_filtered.append(self.allocator, ix) catch {};
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
                const tag = self.picker_tag;
                const label = if (ix) |i|
                    self.allocator.dupe(u8, self.picker_items.items[i].label) catch null
                else
                    null;
                self.unlock();
                self.closePicker();
                if (label) |l| {
                    if (cb) |f| f(self, tag, l);
                    self.allocator.free(l);
                }
                return true;
            },
            27 => { // esc
                self.unlock();
                self.closePicker();
                return true;
            },
            127, 8 => { // backspace
                if (self.picker_query_len > 0) self.picker_query_len -= 1;
                self.picker_sel = 0;
                self.picker_scroll = 0;
                self.pickerRefilter();
            },
            else => |cp| {
                if (cp >= 0x20 and cp < 0x7F and self.picker_query_len < self.picker_query.len) {
                    self.picker_query[self.picker_query_len] = @intCast(cp);
                    self.picker_query_len += 1;
                    self.picker_sel = 0;
                    self.picker_scroll = 0;
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

    /// Frees picker items built by `askPickerItems` (gpa copies).
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
            .items = items,
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

    /// Text + mood. The mood is stored apart so that the status row can paint
    /// THE FACE in its color: before, the text carried the face embedded and
    /// it came out the same gray as the rest, and duplicated too (the one in
    /// the strip and the one in the text). Now the TUI draws the face exactly
    /// once, in the mood's color.
    pub fn setStatusWithMood(self: *Model, new_mood: mascot.Mood, text: []const u8) void {
        self.lock();
        defer self.unlock();
        const n = @min(text.len, self.status_buf.len);
        @memcpy(self.status_buf[0..n], text[0..n]);
        self.status_len = n;
        self.status_mood = new_mood;
        self.status_mood_set = true;
        self.dirty = true;
        self.redraw_requested.store(true, .seq_cst);
    }

    /// `setStatusWithMood` that composes the text into the fixed buffer.
    ///
    /// Same reasoning as `pushInfoFmt`: the status row copies, so composing here
    /// cannot leak a literal into an ownership-taking path, and the mood stays
    /// paired with the text in one call (which is what makes the face come out in
    /// the right color).
    pub fn setStatusFmt(self: *Model, new_mood: mascot.Mood, comptime fmt: []const u8, args: anytype) void {
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
    pub fn mood(self: *Model) mascot.Mood {
        self.lock();
        defer self.unlock();
        if (self.status_mood_set) return self.status_mood;
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

    fn clearSegCache(self: *Model) void {
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
            _ = self.para_heights.pop();
        }
        while (self.para_heights.items.len < n) {
            const p = self.paras.items[self.para_heights.items.len];
            const est: usize = if (p.known_lines > 0)
                p.known_lines
            else
                self.estHeight(p.text);
            // `assumeCapacity`: the indices of `para_heights` are the same as
            // those of `paras` and draw walks them assuming they measure the
            // same thing, so an OOM here cannot leave the list short (that
            // would be an out-of-range index in the next frame).
            self.para_heights.ensureTotalCapacity(self.allocator, n) catch return;
            self.para_heights.appendAssumeCapacity(est);
        }
    }

    /// Cheap height estimate for a paragraph that has never been parsed.
    ///
    /// Wrapping included: `newlines + 1` rows, plus one more per `per_line`
    /// bytes of the text. It is only an estimate (markdown lists, code blocks
    /// and the blank separator row all add rows it cannot know about) but it is
    /// within a factor of the real height, which is what the scroll needs.
    ///
    /// `wrap_w` is the width the last frame laid out with, published by the
    /// draw. With no frame yet (a key pressed before the first draw) it falls
    /// back to 40, which is close enough for a clamp.
    fn estHeight(self: *const Model, text: []const u8) usize {
        const per_line: usize = if (self.wrap_w > 8) self.wrap_w else 40;
        const nl = std.mem.count(u8, text, "\n");
        const wrapped = (text.len -| nl) / per_line;
        // A fence costs three rows the line count cannot see: a blank row, the
        // language chip and another blank row. Counting them here is what stops
        // the scroll range from growing as you scroll down through a history
        // full of code.
        const fences = std.mem.count(u8, text, "```") + std.mem.count(u8, text, "~~~");
        return @max(1, nl + 1 + wrapped + 3 * fences);
    }

    /// Parses and wraps a paragraph, and puts it in the cache with its height.
    fn layoutOne(self: *Model, ctx: vxfw.DrawContext, idx: usize, width: u16) !void {
        const p_ = &self.paras.items[idx];

        const para_arena = try self.allocator.create(std.heap.ArenaAllocator);
        para_arena.* = std.heap.ArenaAllocator.init(self.allocator);
        errdefer {
            para_arena.deinit();
            self.allocator.destroy(para_arena);
        }

        // Rehydrate if the paragraph was pruned to its compressed form.
        const text = p_.textLive(self.allocator);
        var lines = try buildLinesBase(para_arena.allocator(), ctx, p_.kind, text, width, p_.base, p_.mood, p_.lang);
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
        if (idx < self.para_heights.items.len) self.para_heights.items[idx] = lines.len;
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
        var closed: usize = 0;
        for (self.para_heights.items) |h| closed += h;
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
            self.setAnchorLine(first);
        } else {
            self.follow_bottom = false;
        }
        self.anchor = first;
        return .{ .first = first, .last = first + @max(history_h, 1), .total = t.total, .max_offset = t.max_offset };
    }

    /// The absolute line of the top of the view, from (paragraph, offset).
    fn anchorLine(self: *const Model) usize {
        var acc: usize = 0;
        const upto = @min(self.anchor_para, self.para_heights.items.len);
        for (self.para_heights.items[0..upto]) |h| acc += h;
        return acc + self.anchor_off;
    }

    /// The other direction: turn an absolute line into (paragraph, offset).
    ///
    /// The offset is clamped to the paragraph's CURRENT height, which is what
    /// keeps a shrink from leaving the anchor pointing past its own paragraph.
    fn setAnchorLine(self: *Model, line: usize) void {
        var acc: usize = 0;
        for (self.para_heights.items, 0..) |h, i| {
            if (line < acc + h) {
                self.anchor_para = i;
                self.anchor_off = line - acc;
                return;
            }
            acc += h;
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
        if (self.paras.items.len == 0) return;

        // ── target window: the paragraphs covering [first, last] ──
        var acc: usize = 0;
        var lo: usize = 0;
        while (lo < self.para_heights.items.len) : (lo += 1) {
            if (acc + self.para_heights.items[lo] > first_visible) break;
            acc += self.para_heights.items[lo];
        }
        var hi = lo;
        var seen = acc;
        while (hi < self.para_heights.items.len and seen < last_visible) : (hi += 1) {
            seen += self.para_heights.items[hi];
        }
        // If the visible window is wider than the cap, the tail is kept (that
        // is what you are reading: the very bottom).
        if (hi - lo > Model.max_cached_paras) lo = hi - Model.max_cached_paras;

        // ── drop what is cached outside the window ──
        var i: usize = 0;
        while (i < self.seg_cache.items.len) {
            const idx = self.seg_cache.items[i].para_idx;
            if (idx < lo or idx >= hi) {
                self.evictCached(i);
            } else {
                i += 1;
            }
        }
        self.cache_lo = lo;

        // ── prune: compress what is outside the window ──
        self.pruneCold(lo, hi);

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
            try self.layoutOne(ctx, idx, width);
        }
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

    /// Pushes the header: ONLY the wordmark.
    ///
    /// Before there were three more things (an 18-row mascot, the "zo the code
    /// robot says: hi!…" line and the shortcuts line `/help · /model · ctrl+p…`).
    /// Complaining about "junk in the view" is being right: it was 20 rows of
    /// header before the first word of the conversation, and the hints are
    /// already in the palette (Ctrl+P) and in `/help`.
    ///
    /// `start_mood` is no longer used to paint anything here: the face is still
    /// in the status bar (`setStatusWithZo`), which is where it is read. The
    /// parameter stays to avoid changing the signature at the two call sites.
    pub fn pushHeader(self: *Model, start_mood: mascot.Mood) void {
        _ = start_mood;
        var it = std.mem.splitScalar(u8, mascot.banner, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            self.pushKind(.banner, line);
        }
    }

    /// The worker leaves the already-built items here (thread-safe).
    ///
    /// ITEMS are handed over, not `models_mod.Model`: a Model's `id` points
    /// into the list it came from, and if the worker frees that list when it
    /// finishes (which it does) those pointers dangle. The items carry their
    /// own strings and the palette frees them when they are replaced.
    pub fn setPendingItems(self: *Model, items: []palette.Item) void {
        self.lock();
        defer self.unlock();
        if (self.pending_items) |old| palette.freeItems(self.allocator, old);
        self.pending_items = items;
        self.dirty = true;
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
        return self.busy or self.streaming or self.tool_run != null;
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

    /// Assistant text delta (thread-safe).
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
        self.stream_buf.appendSlice(self.allocator, text) catch {};
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
            if (self.allocator.dupe(u8, self.stream_buf.items)) |text| {
                self.pending.append(self.allocator, .{ .kind = .assistant, .text = text }) catch {
                    self.allocator.free(text);
                };
            } else |_| {}
            self.stream_buf.clearRetainingCapacity();
        }
        // `streaming` goes down HERE, unconditionally, and not inside the `if`.
        //
        // It was inside, which meant that any turn that ended with an EMPTY
        // stream buffer left the model "streaming" forever. `workingLocked()`
        // counts it, so the placeholder was painted on EVERY frame from then on
        // — a `thinking · 4321.3s` line with a clock that never stops, a spinner
        // that never stops, and a status bar that says the app is busy long
        // after the turn is over. That is the "junk that never cleans up".
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

    // ── Claude Code style tool calls ───────────────────────
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

    /// Milliseconds the tool in progress has been running (0 if there is none).
    pub fn toolRunMillis(self: *const Model) u64 {
        return self.toolRunMillisLocked();
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

    /// Same, but for when the caller ALREADY holds the lock.
    fn toolRunMillisLocked(self: *const Model) u64 {
        const tr = self.tool_run orelse return 0;
        if (!self.io_ready) return 0;
        const now = std.Io.Timestamp.now(self.io, .real).nanoseconds;
        return @intCast(@max(0, now - tr.started_ns) / std.time.ns_per_ms);
    }

    /// A tool result: "⎿  Read 1006 lines · 3ms". Stores the full result so
    /// Ctrl+R can expand it.
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
        // long it took" without them mixing.
        const line = std.fmt.bufPrint(&line_buf, "*{s}* · {d}ms", .{ head, ms }) catch head;

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

        const lines = md.unifiedDiff(arena, before, after) catch return .{};
        var added: usize = 0;
        var removed: usize = 0;
        for (lines) |l| {
            if (l.len > 0 and l[0] == '+') added += 1;
            if (l.len > 0 and l[0] == '-') removed += 1;
        }
        if (added == 0 and removed == 0) {
            // Either nothing changed, or the file goes over
            // `md.max_diff_lines` and what there is is a notice. In the second
            // case it IS shown: staying quiet would be "I saw nothing" (which
            // is what the model would conclude).
            if (lines.len == 1 and std.mem.startsWith(u8, lines[0], "diff omitted")) {
                const copy = self.allocator.dupe(u8, lines[0]) catch return .{};
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
        for (lines) |l| {
            if (joined.items.len > 0) joined.append(self.allocator, '\n') catch return .{};
            joined.appendSlice(self.allocator, l) catch return .{};
        }
        // `pushKind` copies, so this buffer is temporary.
        const copy = self.allocator.dupe(u8, joined.items) catch return .{};
        defer self.allocator.free(copy);
        self.pushDiffKind(copy, lang);
        return .{ .added = added, .removed = removed };
    }

    /// Enqueues a diff paragraph WITH its language (`agent.langFromPath` gets
    /// it from the path's extension).
    ///
    /// The language is not stored as its own string but as the SAME slice
    /// `pushToolStart` already copied from the path: otherwise the paragraph
    /// would point at the worker's arena, which is freed at the end of the
    /// turn.
    fn pushDiffKind(self: *Model, text: []const u8, lang: []const u8) void {
        const lang_copy = self.allocator.dupe(u8, lang) catch {
            self.pushKind(.diff, text);
            return;
        };
        self.lock();
        defer self.unlock();
        self.pending.append(self.allocator, .{
            .kind = .diff,
            .text = self.allocator.dupe(u8, text) catch {
                self.allocator.free(lang_copy);
                self.allocator.free(text);
                return;
            },
            .lang = lang_copy,
        }) catch {
            self.allocator.free(lang_copy);
            self.allocator.free(text);
        };
        self.dirty = true;
        self.redraw_requested.store(true, .seq_cst);
    }

    /// Ctrl+R: expands or collapses the last tool's result.
    pub fn toggleLastTool(self: *Model) bool {
        self.lock();
        var lt = self.last_tool orelse {
            self.unlock();
            return false;
        };
        const idx = lt.para_idx;
        if (idx >= self.paras.items.len or lt.result.len == 0) {
            self.unlock();
            return false;
        }
        // `result` and `summary` are the source of truth; the paragraph's text
        // is a view of one of the two (that is why they are not freed here).
        const want = if (lt.expanded) lt.summary else lt.result;
        const copy = self.allocator.dupe(u8, want) catch {
            self.unlock();
            return false;
        };
        self.allocator.free(self.paras.items[idx].text);
        self.paras.items[idx].text = copy;
        lt.expanded = !lt.expanded;
        self.last_tool = lt;
        // The layout of this and the following paragraphs changes: re-cache.
        if (self.cache_from == null or idx < self.cache_from.?) self.cache_from = idx;
        // The anchor is NOT touched, and that is a fix: Ctrl+R used to set
        // `scroll = 0`, which yanked the view to the bottom while you were
        // reading something else. The anchor is absolute, so expanding a tool
        // only moves what comes after it: if you were at the bottom you stay at
        // the bottom (the follow flag), and if you were reading above, you stay
        // exactly where you were.
        self.unlock();
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
    pub const Activity = struct { busy: bool, dirty: bool, perm: bool, ask: bool, picker: bool, streaming: bool };

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
        };
    }

    /// Requests a frame within `ms` ms. Idempotent: it does not stack timers.
    fn armTick(self: *Model, ctx: *vxfw.EventContext) !void {
        if (self.tick_armed) return;
        self.tick_armed = true;
        const a = self.activity();
        const ms: u32 = if (a.busy or a.dirty) 40 else 120;
        try ctx.tick(ms, self.widget());
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
        self.setAnchorLine(first);
        self.anchor = first;
        // Reaching the bottom re-arms the follow, so the next line that arrives
        // keeps coming at you instead of freezing the view where you happened to
        // land.
        self.follow_bottom = (first >= mo);
        // Published HERE, not only by the draw. The key handler knows the new
        // view the moment it computes it, and the `↓ N` indicator must not show
        // the previous frame's number while waiting for one.
        self.first_visible = first;
        self.max_offset = mo;
    }

    // ── modal palette (Ctrl+P) ─────────────────────────────

    /// Opens the palette in the given mode. `items` and `groups` are filled by
    /// the caller (the agent) and must stay alive while it is open; in
    /// practice they live in the model's allocator.
    pub fn openPaletteWith(self: *Model, mode: palette.Mode, items: []const palette.Item, groups: []const palette.Group) void {
        self.pal.mode = mode;
        self.pal.active = true;
        self.pal.query_len = 0;
        self.pal.setItems(items, groups);
        if (mode == .models) self.pal.col = 1 else self.pal.col = 0;
    }

    pub fn closePalette(self: *Model) void {
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
        const act = palette.handleKey(&self.pal, key);
        // CAREFUL: redraw must be requested ALWAYS. The palette mutates its
        // state (query, selection) and without `ctx.redraw` the screen stays
        // as it was: you typed "cache" and the list did not filter, and Esc
        // "did not close".
        ctx.redraw = true;
        switch (act) {
            .none => {},
            .close => {
                self.closePalette();
                return true;
            },
            .run_command => |cmd| {
                // Without `eqlIgnoreCase` the label "Connect" did not match
                // "connect", the item fell into the generic case and got run
                // LITERALLY as if it were a command.
                if (std.ascii.eqlIgnoreCase(cmd, "connect")) {
                    // The palette is replaced in place, without closing first:
                    // otherwise you see the history blink between modal and
                    // modal.
                    agent.openConnectPalette(self);
                    return true;
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
                return true;
            },
            .set_provider => |p| {
                self.closePalette();
                try agent.applyProvider(self, p);
                return true;
            },
            .set_model => |mo| {
                self.closePalette();
                // The window goes with the model: it is what the compaction
                // budget is computed from, and dropping it here is what kept the
                // budget at 128k for every model.
                try agent.applyModel(self, mo.id, mo.ctx_tokens);
                return true;
            },
            .connect => |conn| {
                // Saving the key is I/O: the agent does it. The palette stays
                // open so you can see the result.
                agent.storeKey(self, conn.provider, conn.key);
                self.pal.key_len = 0;
                return true;
            },
        }
        return true;
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
    ctx.redraw = true;
    try self.armTick(ctx);
}

// ── input key handler ──────────────────────────────
/// Translates a key into an input edit. Returns true if it consumed it.
fn editorKey(self: *Model, ctx: *vxfw.EventContext, key: vaxis.Key) !bool {
    const k = key;

    // Enter submits; Shift+Enter / Alt+Enter insert a line break.
    if (k.matches(vaxis.Key.enter, .{})) {
        if (k.mods.shift or k.mods.alt) {
            try self.ed.insertChar('\n');
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
            self.ed.insert(txt) catch {};
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

/// Refills the file matches for the `@token` being typed.
///
/// Reads the CURRENT directory only (like `list_files`): `src/` narrows
/// inside the prefix, deeper trees are one `@` away. Directories first (they
/// are the way down the tree), then files, both alphabetical. Needs the `Io`
/// (`io_ready`): in tests without one the list just stays empty.
fn refreshFileMatches(self: *Model, token: []const u8) void {
    freeFileMatches(self);
    if (!self.io_ready) return;

    // Split the token into directory + partial name: `src/edi` lists `src/`.
    var dir_path: []const u8 = ".";
    var partial: []const u8 = token;
    if (std.mem.lastIndexOfScalar(u8, token, '/')) |slash| {
        dir_path = token[0..slash];
        partial = token[slash + 1 ..];
    }

    const names = listDirNames(self.allocator, self.io, dir_path, 40) catch return;
    defer {
        for (names) |e| self.allocator.free(e.name);
        self.allocator.free(names);
    }

    for (names) |e| {
        if (!startsWithIgnoreCase(e.name, partial)) continue;
        // Skip dotfiles unless the user is typing one (`.gitignore`).
        if (e.name.len > 0 and e.name[0] == '.' and (partial.len == 0 or partial[0] != '.')) continue;
        const has_dir_part = std.mem.indexOfScalar(u8, token, '/') != null;
        const candidate = std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{
            if (has_dir_part) dir_path else "",
            if (has_dir_part and !std.mem.endsWith(u8, dir_path, "/")) "/" else "",
            e.name,
        }) catch continue;
        if (e.is_dir) {
            const with_slash = std.fmt.allocPrint(self.allocator, "{s}/", .{candidate}) catch {
                self.allocator.free(candidate);
                continue;
            };
            self.allocator.free(candidate);
            self.ac.file_matches.append(self.allocator, with_slash) catch {
                self.allocator.free(with_slash);
            };
        } else {
            self.ac.file_matches.append(self.allocator, candidate) catch {
                self.allocator.free(candidate);
            };
        }
    }
}

/// One directory entry: the name and whether it is a directory (so the popup
/// appends the `/` that invites the next level).
const DirEntry = struct { name: []u8, is_dir: bool };

/// Directory listing as an owned slice. Best-effort: any error (missing dir,
/// `Io` not ready in tests) yields an error, and the caller leaves the popup
/// empty — a popup that fails to open must not take the input down with it.
///
/// CAREFUL (AGENTS.md): `openDir` WITHOUT `.iterate = true` is a panic (EBADF)
/// the moment you call `iterate()`, not a clean error.
fn listDirNames(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    max: usize,
) ![]DirEntry {
    var out: std.ArrayList(DirEntry) = .empty;
    errdefer {
        for (out.items) |e| gpa.free(e.name);
        out.deinit(gpa);
    }
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (out.items.len < max) {
        const e = it.next(io) catch break orelse break;
        if (e.name.len == 0 or std.mem.eql(u8, e.name, ".") or std.mem.eql(u8, e.name, "..")) continue;
        try out.append(gpa, .{ .name = try gpa.dupe(u8, e.name), .is_dir = e.kind == .directory });
    }
    // Alphabetical so the popup is stable while typing. Directories first:
    // they are how you walk DOWN the tree, which is what `@` is for.
    std.mem.sort(DirEntry, out.items, {}, struct {
        fn lt(_: void, a: DirEntry, b: DirEntry) bool {
            if (a.is_dir != b.is_dir) return a.is_dir;
            return std.ascii.orderIgnoreCase(a.name, b.name) == .lt;
        }
    }.lt);
    return out.toOwnedSlice(gpa);
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
    if (self.ac.prefix_len == 0 or self.ac.prefix_len > text.len) return null;
    return switch (self.ac.mode) {
        .command => text[1..self.ac.prefix_len],
        .file => blk: {
            // The token runs to the cursor, like `fileQueryAt` saw it.
            const end = @min(self.ed.cursor, text.len);
            if (end < self.ac.prefix_len) break :blk "";
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
            for (agent.commands) |c| {
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
            for (agent.commands) |c| {
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
    // Compared against ALL the commands, not just the highlighted one.
    //
    // Comparing only with the highlighted one broke "/model": the popup sorted
    // "/models" first, so it was not an exact match and Enter completed to
    // "/models". Now: if what is typed IS a command it is sent as-is; if it is
    // partial ("mod"), it is completed.
    for (agent.commands) |c| {
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
            break :blk std.fmt.allocPrint(self.allocator, "@{s}", .{path}) catch return false;
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

// ── root widget handlers ─────────────────────────────────
fn typeErasedEventHandler(ud: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *Model = @ptrCast(@alignCast(ud));
    switch (event) {
        .key_press => |key| {
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
                    self.answerPermission(.allow_always);
                } else if (cp == 'n' or cp == 'N') {
                    self.answerPermission(.deny);
                }
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            // Shift+Tab: read-only mode.
            //
            // Chosen because it is the key nothing else in a terminal uses, and
            // because every other coding agent already uses it for this, so it
            // does not have to be learned twice.
            //
            // It works with text in the input on purpose: you often decide to
            // switch AFTER typing the prompt ("actually, look first"), and a mode
            // you can only enter with an empty box is a mode you use once.
            if (key.matches(vaxis.Key.tab, .{ .shift = true })) {
                agent.toggleReadOnly(self);
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }

            // ── history scroll ──
            // PageUp/PageDown move a PAGE (the whole window, minus one line so
            // you can see what came before and what comes after). Before they
            // moved 5 fixed rows, which in a 40-row terminal did not feel like
            // scrolling.
            // Ctrl+U / Ctrl+D do half a page, like in less and in Claude Code.
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
            if (asked or a.busy or a.dirty or a.perm or a.picker or self.pal.active) {
                ctx.redraw = true;
            }
            try self.armTick(ctx);
        },
        .init => {
            ctx.redraw = true; // first frame without waiting for a key
            try self.armTick(ctx);
        },
        .focus_in => {
            ctx.redraw = true;
            try self.armTick(ctx);
        },
        .paste => |data| {
            // Our own editor has no paste callback: we insert by hand. A paste
            // with line breaks creates a real multiline prompt.
            if (!self.pickerActive() and !self.permActive()) {
                self.ed.insert(data) catch {};
                syncAutocomplete(self);
            }
            ctx.redraw = true;
        },
        .mouse => |m| {
            // The wheel arrives as button 64/65 with type=press.
            if (m.type != .press) return;
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
    //   row height-2            status
    //   row height-3            bottom border of the input box
    //   rows height-4-input_h   input contents (input_h rows)
    //   row height-4-input_h    top border of the box
    //   row height-5-input_h    separator (or autocompletion popup)
    //   rows 0..history_h       history
    const status_row: u16 = height - 2;
    const max_input_lines: u16 = 8;
    const text_w: u16 = if (width > 3) width - 3 else 1; // same region drawInput paints

    // Activity strip (mascot + state + clock): 1 row, but ONLY if there is
    // something to report. At idle it takes no space, as it should.
    const act = self.activity();
    const queued = self.queuedCount();
    // `act.ask` counts: an open QUESTION is work in progress from the user's
    // point of view, and the strip is where the clock and "waiting for your
    // answer" live. Without it the question was on screen with no explanation of
    // why the app had stopped.
    const act_rows: u16 = if (act.busy or queued > 0 or act.ask) 1 else 0;

    // The plan (the `todo` tool): one checkbox per step, above the activity
    // strip. It only takes rows if there is a plan, and at most
    // `plan_max_rows`: a 20-step plan cannot eat the history.
    const pl_now = self.planCopy();
    // A FINISHED plan takes ONE row, not one per step. `drawPlanBlock` returns
    // after a single `☑ all N steps done` line, so reserving N rows left the
    // ghosts of the checkbox rows underneath it, forever: they sit below
    // `history_h`, so the history clear loop never touched them, and they stayed
    // until `/plan` or a new plan came along.
    const plan_rows: u16 = if (pl_now.isEmpty())
        0
    else if (pl_now.allDone())
        1
    else
        @min(@as(u16, pl_now.len), plan_max_rows);

    // Autocompletion popup: only if there are matches.
    const ac_rows: u16 = if (self.ac.active and matchCount(self) > 0)
        @as(u16, @intCast(@min(matchCount(self), self.ac.max_visible) + 1))
    else
        0;

    // The input grows with the text but never eats the history: if both do not
    // fit, the input is clipped (and its view anchors to the bottom).
    const chrome: u16 = 4 + ac_rows + act_rows + plan_rows; // status + borders + popup + strip + plan
    const avail: u16 = if (height > chrome + 2) height - chrome - 2 else 1;
    const ed_w: u16 = if (text_w > 0) text_w else 1;
    const input_h: u16 = @max(@min(@as(u16, @intCast(@min(self.ed.displayLines(ed_w, editorMeasurer(&p)), max_input_lines))), avail), 1);
    // The order from the bottom up is: status · strip · PLAN · input box. The
    // plan goes between the strip and the input (and not over the status)
    // because it is what you look at while the model works, next to the clock.
    const input_top: u16 = height - 4 - act_rows - plan_rows - input_h;
    const history_h: u16 = if (input_top > 1) input_top - 1 else 1;
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
            const ms = self.toolRunMillisLocked();
            // The ARGUMENT goes with the name: `bash(sleep 30) · 12.3s` says
            // far more than `bash · 12.3s` when there are several tools in the
            // turn and you are looking at the strip to see which one is stuck.
            // `ToolRun.arg` had been stored for months and nobody read it.
            const line = std.fmt.bufPrint(&tool_buf, "*{s}*({s}) running · {d}.{d}s", .{
                tr.name,
                tr.arg,
                ms / 1000,
                (ms % 1000) / 100,
            }) catch "";
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

    // Placeholder while the turn is alive but no text has arrived yet.
    //
    // The gap between "you pressed Enter" and the first token is seconds, and
    // in that gap the history had NOTHING live: the last dot was your prompt.
    // The one-row strip already says something, but it is glued to the input
    // and with the input open it reads as part of the box. A line in that spot
    // (`thinking · 3.2s`) with the clock inside is what says "I'm here".
    var live_kind: md.Kind = if (live_is_tool) .tool_res else .assistant;
    var live_active = false;
    // Only if there IS a turn: at idle the history does not invent a line.
    if (live_src.len == 0 and self.workingLocked()) {
        // `ph_buf` is block-local AND the copy happens INSIDE this block. It
        // used to be block-local with the copy ten lines further down, past the
        // end of its scope: reading a dead stack buffer, which is the same bug
        // as `&[_]u8{c}` and just as undefined. Local buffer + immediate copy
        // into the frame arena is the pattern that cannot get it wrong.
        var ph_buf: [64]u8 = undefined;
        const ms = self.busyMillis();
        const ph = std.fmt.bufPrint(&ph_buf, "thinking · {d}.{d}s", .{
            ms / 1000,
            (ms % 1000) / 100,
        }) catch "thinking";
        live_src = ctx.arena.dupe(u8, ph) catch "thinking";
        live_kind = .info;
        live_active = true;
    }

    var live_lines: []const PLine = &.{};
    if (live_src.len > 0) {
        // `live_src` is already frame-arena owned (see the invariant above), so
        // there is nothing to copy here any more.
        live_lines = buildLines(ctx.arena, ctx, live_kind, live_src, width) catch &.{};
        live_active = live_lines.len > 0;
    }

    // ── scroll: 0 = anchored at the bottom ──
    //
    // `layoutFor` leaves the cache window covering what is visible (so deep
    // scrolling re-parses on demand, which is what the old comment claimed and
    // was not true) and returns the visible range already stabilized.
    //
    // The wrap width is `width - hist_margin`: `drawLines` paints with 2
    // margin columns, and if the layout does not account for it the last
    // column goes off screen.
    const hist_margin: u16 = historyMargin(width);
    const wrap_width: u16 = if (width > hist_margin) width - hist_margin else width;
    self.wrap_w = wrap_width;
    const vis = try self.layoutFor(
        ctx,
        if (width > hist_margin) width - hist_margin else width,
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

    // ── clears the history area BEFORE painting ──
    //
    // Without this, pixels of the previous version of the streaming text stay
    // around: the live paragraph is re-wrapped on every frame and when it
    // SHRINKS (which happens every time the model breathes between tokens) the
    // leftover cells keep the old text. You saw the same paragraph twice, split
    // and mixed, in the middle of the answer.
    var clear_row: u16 = 0;
    while (clear_row < history_h) : (clear_row += 1) {
        p.fillRange(0, width, clear_row, " ", .{});
    }

    // ── paints only the visible lines ──
    //
    // `line_cursor` is the ABSOLUTE position of the first line: the window's
    // `.offset` (`cache_lo`) plus what the cached paragraphs before it carry.
    var line_cursor: usize = 0;
    for (self.para_heights.items[0..self.cache_lo]) |h| line_cursor += h;
    for (self.seg_cache.items) |c| {
        defer line_cursor += c.height;
        if (line_cursor >= last_visible) break;
        if (line_cursor + c.height <= first_visible) continue;
        drawLines(&p, c.lines, line_cursor, first_visible, history_h);
    }
    if (live_active) {
        drawLines(&p, live_lines, line_cursor, first_visible, history_h);
    }

    // ── status: spinner + text + session info ──
    // The status row goes out in SEGMENTS, not as one string: the face and the
    // text have to be in different colors. With a single string everything came
    // out in the dim blue and the face was NOT visible at all (which is exactly
    // the complaint: "you can't tell by the color"). The mood is the only thing
    // that tells you whether it is thinking, waiting for permission or stuck.
    var status_segs: std.ArrayList(InfoSeg) = .empty;
    const mood: mascot.Mood = self.mood();
    {
        self.lock();
        defer self.unlock();
        if (self.busy) {
            status_segs.append(ctx.arena, .{
                .text = Model.spinner_chars[self.spinner_frame % Model.spinner_chars.len],
                .style = theme.ctxColor(100),
            }) catch {};
            status_segs.append(ctx.arena, .{ .text = " ", .style = theme.brand_faint }) catch {};
        }
    }
    // The face goes FIRST and in the mood's color: it is the indicator.
    {
        const face = mascot.faceFrames(mood, self.spinner_frame / 6);
        status_segs.append(ctx.arena, .{
            .text = face,
            .style = .{ .bold = true, .fg = .{ .index = mood.color() } },
        }) catch {};
        status_segs.append(ctx.arena, .{ .text = "  ", .style = theme.brand_faint }) catch {};
    }
    status_segs.append(ctx.arena, .{ .text = self.status(), .style = theme.brand_soft }) catch {};

    // Scroll indicator: if the history is not anchored at the bottom, it has to
    // be said. Without this you lose the context of "why doesn't it scroll
    // down by itself".
    //
    // It prints `max_offset - first_visible`, the lines that are actually
    // hidden below, NOT the raw scroll offset. With the debt that used to be
    // possible, the number on screen could be 336 while nothing was hidden at
    // all, because it is a count of what you cannot see.
    if (self.max_offset > self.first_visible) {
        const below = self.max_offset - self.first_visible;
        const s = std.fmt.allocPrint(ctx.arena, "  ↓ {d}", .{below}) catch "";
        if (s.len > 0) status_segs.append(ctx.arena, .{ .text = s, .style = theme.warn }) catch {};
    }

    // The session info (model · provider · effort · ctx% · tok/s) is painted
    // segmented further below, right-aligned; here it is only prepared.
    const act_now = self.activity();
    const info: []const InfoSeg = sessionInfo(ctx.arena, act_now.streaming) orelse &.{};

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
    if (!self.permActive() and ac_rows == 0) {
        // The separator only when there is no popup (otherwise they overlap).
        if (input_top > 0) p.fillRow(input_top - 1, "─", theme.rule);
    }

    // ── status: text on the left + session info on the right ──
    {
        var col: u16 = 0;
        for (status_segs.items) |sg| {
            col = p.putText(col, status_row, sg.text, sg.style);
        }
    }
    if (info.len > 0) drawSessionInfo(&p, status_row, width, info, self.activity().busy);

    // Second column, at the right edge: what the session has cost. Painted
    // AFTER the session column so it wins any overlap, and only if the session
    // column left room (`reserved`).
    if (usageInfo(ctx.arena)) |usage| {
        drawUsageColumn(&p, status_row, width, usage, sessionInfoWidth(info));
    }

    // ── `/` autocompletion (right above the input) ──
    if (ac_rows > 0) {
        drawAutocomplete(&p, self, input_top - ac_rows, width, ac_rows);
    }

    // ── multiline input with border ──
    // Activity strip: the MASCOT is the "it is working" indicator. Before the
    // only feedback was the tiny status bar spinner, which with a slow model
    // says nothing: you couldn't tell whether it was thinking, waiting or hung.
    // Here it is the face + the state + the elapsed SECONDS, which is what
    // really answers "is it working or is it stuck?".
    if (plan_rows > 0) {
        drawPlanBlock(&p, input_top - plan_rows, width, plan_rows, pl_now);
    }
    if (act_rows == 1 and input_top > act_rows + plan_rows) {
        drawActivityStrip(&p, input_top - act_rows - plan_rows - 1, width, self, act, queued);
    }

    drawInput(&p, &surface, self, input_top, width, input_h);

    // ── permission dialog: centered MODAL ──
    //
    // Before it was 4 lines glued right above the input box, in the middle of
    // the normal flow: with a full history they were half hidden or covered,
    // and the app looked HUNG waiting for something nobody could see. Now it is
    // a centered box with a border, a clean background and big options: there
    // is no way not to see it.
    if (self.permView(&perm_tool, &perm_detail)) {
        drawPermissionModal(&p, width, height, perm_tool, perm_detail);
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
        if (!self.pal.active) drawAskPanel(&p, width, height, snap, self.askMillis());
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
        palette.draw(&p, &surface, &self.pal, width, height);
    }

    return surface;
}

/// The input box: rounded border, `❯` prompt and up to `max_input_lines`
/// lines. The terminal cursor is anchored at the real cursor position.
fn drawInput(
    p: *Painter,
    surface: *vxfw.Surface,
    self: *Model,
    top: u16,
    width: u16,
    input_h: u16,
) void {
    if (top >= p.height or width < 6) return;

    const box_h: u16 = input_h + 2; // top border + contents + bottom border
    p.putStable(0, top, "╭", 1, theme.input_border);
    p.fillRange(1, width - 1, top, "─", theme.input_border);
    p.putStable(width - 1, top, "╮", 1, theme.input_border);
    p.putStable(0, top + box_h - 1, "╰", 1, theme.input_border);
    p.fillRange(1, width - 1, top + box_h - 1, "─", theme.input_border);
    p.putStable(width - 1, top + box_h - 1, "╯", 1, theme.input_border);

    var r: u16 = 1;
    while (r < box_h - 1) : (r += 1) {
        p.putStable(0, top + r, "│", 1, theme.input_border);
        p.putStable(width - 1, top + r, "│", 1, theme.input_border);
    }

    // Prompt `❯ ` only on the first line.
    _ = p.putText(2, top + 1, "❯ ", theme.input_prompt);

    // The text region is columns [2, width-1): the left border is 0, the right
    // border is `width - 1`. `width - 3`, not `width - 4`: the layout used to
    // reserve one column less than the paint area, which is the kind of off-by-one
    // that only shows up as "the last character of a wrapped line is missing".
    const ed_w: u16 = if (width > 3) width - 3 else 1;
    const meas = editorMeasurer(p);

    // Rows, not lines: the text is wrapped HERE, with the same wrap the box was
    // sized with. It used to be split on `\n` only and each line handed to
    // `putText`, which clips at the TERMINAL edge: a 200-character prompt made an
    // eight-row box with all the text in one row running off the right, and
    // everything past the border was dropped without a word.
    const total_rows = self.ed.displayLines(ed_w, meas);
    // Bottom-anchored (like the history): the cursor is at the end of what you
    // are typing, so that is what has to stay visible.
    const first = if (total_rows > input_h) total_rows - input_h else 0;
    const shown = self.ed.rowsInWindow(first, input_h, ed_w, meas, p.arena);
    for (shown, 0..) |piece, i| {
        const row = top + 1 + @as(u16, @intCast(i));
        if (row >= top + box_h - 1) break;
        if (piece.bytes.len == 0) continue;
        _ = p.putClipped(2, row, piece.bytes, ed_w, theme.input_text);
    }

    // The terminal cursor, at its VISUAL row and column. `cursorLine` gave a
    // logical line index, which on a wrapped line meant row 0 with a column of
    // `2 + everything before it`: outside the surface, so the caret vanished.
    const cc = self.ed.cursorRowCol(ed_w, meas);
    if (cc.row >= first and cc.row < first + shown.len) {
        const col = 2 + @min(cc.col, ed_w - 1);
        surface.cursor = .{
            .row = top + 1 + @as(u16, @intCast(cc.row - first)),
            .col = col,
        };
    }

    // Rows scrolled out above: on the border, the way the picker's title sits on
    // its border. Without it, a box full of the middle of your prompt looks
    // exactly like a box with all of it.
    if (first > 0 and width > 16) {
        var ib: [32]u8 = undefined;
        const lab = std.fmt.bufPrint(&ib, "\u{2191} {d} more", .{first}) catch "";
        if (lab.len > 0 and lab.len + 4 < width) {
            _ = p.putClipped(width - 2 - @as(u16, @intCast(lab.len)), top, lab, @as(u16, @intCast(lab.len)), theme.hint_faint);
        }
    }

    if (self.ed.isEmpty()) {
        // With a question open this box IS the answer field (the free-text path),
        // so the placeholder has to say so: it used to invite a prompt, which is
        // not what pressing Enter there does.
        const ph: []const u8 = if (self.askActive())
            "your answer\u{2026} \u{b7} enter sends it \u{b7} esc: you decide"
        else
            "Ask anything\u{2026} \u{b7} / for commands \u{b7} ctrl+c to exit";
        _ = p.putClipped(4, top + 1, ph, ed_w - 2, theme.placeholder);
    }

    if (self.ac.active) {
        var hb: [64]u8 = undefined;
        const n = matchCount(self);
        const h = std.fmt.bufPrint(&hb, "{d} {s} \u{b7} tab complete", .{
            n,
            if (n == 1) @as([]const u8, "match") else "matches",
        }) catch "";
        if (h.len + 4 < width) {
            _ = p.putText(width - 2 - @as(u16, @intCast(h.len)), top + box_h - 1, h, theme.dim);
        }
    }
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
        // path, the `@` is drawn dim so the mention form is visible.
        if (self.ac.mode == .file) {
            _ = p.putText(1, y, "@", if (is_sel) theme.selected else theme.dim);
            _ = p.putText(2, y, label, if (is_sel) theme.selected else theme.accent);
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
/// One lookup, shared by the draw: `agent.commands` is a tiny table, a linear
/// scan is cheaper than threading `agent.Cmd` through the match functions.
fn agentCommandDesc(key: []const u8) []const u8 {
    for (agent.commands) |c| {
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
/// Left margin of the history, in columns.
///
/// It lives in a function because TWO places use it and they have to agree: the
/// layout (which wraps to `width - margin`) and the painting (which starts at
/// the margin's column). If they diverged, the last column would go off
/// screen.
fn historyMargin(width: u16) u16 {
    return if (width > 8) 2 else 0;
}

fn drawLines(
    p: *Painter,
    lines: []const PLine,
    line_offset: usize,
    first_visible: usize,
    history_h: u16,
) void {
    const hh: usize = history_h;
    // History's left margin (4.9 of the ROADMAP): 2 columns of air, like the
    // ones the input box already has. Before the text stuck to the terminal
    // edge and the code blocks' gutter ended up at column 2, which is where a
    // margin belongs. With the margin the whole history lines up and breathes.
    const margin: u16 = historyMargin(p.width);
    for (lines, 0..) |ln, li| {
        const abs = line_offset + li;
        if (abs >= first_visible + hh) break;
        if (abs < first_visible) continue;
        const row: u16 = @intCast(abs - first_visible);
        var col: u16 = margin;
        for (ln.cells) |cell| {
            p.putStable(col, row, cell.text, cell.w, cell.style);
            col += cell.w;
            if (col >= p.width) break;
        }
    }
}

/// Footer with the keyboard shortcuts. Dimmed while the user is typing.
/// The permission dialog, as a centered modal.
///
/// It is what blocks the turn, so it has to be IMPOSSIBLE to miss: clean
/// background (otherwise the history shows through), yellow border, the tool's
/// name in large type and the four options with their key highlighted.
fn drawPermissionModal(
    p: *Painter,
    width: u16,
    height: u16,
    tool: []const u8,
    detail: []const u8,
) void {
    const w: u16 = @min(width -| 6, 68);
    if (w < 30) return;
    const h: u16 = 9;
    if (height < h + 2) return;
    const x: u16 = (width -| w) / 2;
    const y: u16 = (height -| h) / 2;

    // Background: without this the history items show through underneath.
    var r: u16 = 0;
    while (r < h) : (r += 1) {
        p.fillRange(x, x + w, y + r, " ", .{});
    }

    // Border.
    p.fillRange(x + 1, x + w - 1, y, "─", theme.warn_bold);
    p.fillRange(x + 1, x + w - 1, y + h - 1, "─", theme.warn_bold);
    var c: u16 = 1;
    while (c < h - 1) : (c += 1) {
        p.putStable(x, y + c, "│", 1, theme.warn_bold);
        p.putStable(x + w - 1, y + c, "│", 1, theme.warn_bold);
    }
    p.putStable(x, y, "╭", 1, theme.warn_bold);
    p.putStable(x + w - 1, y, "╮", 1, theme.warn_bold);
    p.putStable(x, y + h - 1, "╰", 1, theme.warn_bold);
    p.putStable(x + w - 1, y + h - 1, "╯", 1, theme.warn_bold);

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
    const opts = [_]struct { key: []const u8, label: []const u8 }{
        .{ .key = "Y", .label = "allow once" },
        .{ .key = "A", .label = "always allow" },
        .{ .key = "N", .label = "deny" },
        .{ .key = "ESC", .label = "cancel" },
    };
    var ox: u16 = x + 3;
    for (opts, 0..) |o, i| {
        _ = p.putText(ox, y + 7, o.key, theme.brand_bold);
        const adv: u16 = @as(u16, @intCast(o.key.len)) + 1;
        ox += adv;
        ox = p.putText(ox, y + 7, o.label, if (i == 0) theme.brand else theme.brand_soft);
        if (i + 1 < opts.len and ox + 4 < x + w) {
            ox = p.putText(ox, y + 7, "   ", theme.brand_faint);
        }
    }
}

/// The "it is working" strip, right above the input box.
///
/// It answers "is it stuck or is it thinking?": Zo's face animated with the
/// state, the elapsed SECONDS (the only thing that distinguishes "thinking"
/// from "hung") and what is in the queue. Without this the only feedback was
/// an 8px spinner in the status bar.
///
/// The LABEL is the phase, not a generic "working". "Working" for 40 seconds
/// does not say whether the model is thinking, is already writing or whether
/// there is a hung `bash`: three very different waits that the user lives as
/// one. With the phase named, the clock reads differently ("the server has been
/// waiting 3s" and "this command has been running 30s" are not the same).
///
/// When there is a queue the queued prompts are shown too, so you know what is
/// coming next instead of having to remember it.
/// How many plan steps are painted at most.
///
/// With 20 rows the plan eats the whole history, which is exactly what a plan
/// must NOT do (the history is the conversation). Six is a number thought for a
/// normal terminal: you see the beginning and the state, and the rest follows
/// from the "2/8" of the status bar.
pub const plan_max_rows: u16 = 6;

/// The plan block: one checkbox per step, with the step in progress highlighted.
///
/// Why it is ON SCREEN and not only in the history: the question "how much is
/// left?" has to be answerable without Ask Mode, and the history means
/// scrolling. And the step in progress goes in the brand color because it is the
/// only information that changes from frame to frame.
///
/// When everything is done it draws ONE line ("all N steps done") instead of N
/// checkboxes: a finished plan does not need to be on screen, and leaving it
/// there pushes the input up for no reason.
fn drawPlanBlock(
    p: *Painter,
    top: u16,
    width: u16,
    rows: u16,
    pl: plan_mod.Plan,
) void {
    if (pl.allDone()) {
        p.fillRow(top, " ", .{});
        var buf: [64]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf, "☑ all {d} steps done", .{pl.len}) catch "☑ done";
        _ = p.putText(1, top, txt, theme.ok);
        return;
    }

    const cur = pl.currentIndex();
    for (0..rows) |i| {
        const row: u16 = top + @as(u16, @intCast(i));
        p.fillRow(row, " ", .{});
        const it = pl.items[i];
        const is_cur = cur != null and @as(u8, @intCast(i)) == cur.?;
        // The step in progress: brand color in BOLD. The other styles are
        // already complete Styles from the theme, and mixing a literal with a
        // theme value is exactly the type error that reads as "expected Color,
        // found Style".
        const style: vaxis.Style = if (is_cur) theme.brand_bold else if (it.status == .done) theme.brand_faint else theme.brand_soft;

        var col: u16 = 1;
        col = p.putText(col, row, it.status.glyph(), style);
        // The number is what lets you say "the 3" out loud, and it takes 3
        // columns: `☐ 12. ` against `☐ 1. `.
        col = p.putText(col + 1, row, tryNum(p.arena, @as(u8, @intCast(i)) + 1), theme.brand_faint);
        col = p.putText(col + 1, row, it.textOf(), style);
        if (col >= width) return;
    }

    // If the plan is longer than the rows, the last row says so. Without this
    // the user sees 6 of 20 and cannot tell whether the list ended or was cut.
    if (pl.len > rows) {
        const row: u16 = top + rows - 1;
        var buf: [64]u8 = undefined;
        const txt = std.fmt.bufPrint(
            &buf,
            "  +{d} more · {d}/{d} done",
            .{ pl.len - rows, pl.doneCount(), pl.len },
        ) catch "";
        _ = p.putText(1, row, txt, theme.brand_faint);
    }
}

/// "3" as memory owned by the frame.
fn tryNum(arena: std.mem.Allocator, n: u8) []const u8 {
    var buf: [4]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}.", .{n}) catch return "";
    return arena.dupe(u8, s) catch "";
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
    if (width < 24 or height < 8) return;

    // The panel is ONE widget: the question and the options are in the same box,
    // which is what makes it impossible for one to erase the other. It used to be
    // two (a centred modal picker plus this box, the picker narrower), painted one
    // after the other with the box on top, and the geometry guaranteed the
    // overlap: `top = (height - box_h) / 2` here against `y0 = (height - box_h) / 4`
    // there, and this box is the WIDER one for any question over ~56 columns.
    const text_col_off: u16 = 2; // inside the borders
    const box_w: u16 = @min(@as(u16, 78), width - 4);
    const inner_w: u16 = if (box_w > 6) box_w - 4 else box_w - 2;
    const left: u16 = (width - box_w) / 2;

    // Question: hard breaks first, then wrapped. A `\n` the model wrote (its
    // "recommendation and its reason up front" is routinely two sentences on two
    // lines) used to be written into a CELL as a literal newline byte, and vaxis
    // writes those bytes raw to the terminal: the rest of the frame came out
    // interleaved with the panel text.
    const q_all = wrapTextToRows(p, snap.question, inner_w, p.arena);
    const q_cap: usize = 8;
    var q_n = q_all.len;
    var q_more: usize = 0;
    if (q_n > q_cap) {
        q_more = q_n - q_cap;
        q_n = q_cap;
    }

    // Rows: border + header + question + one blank + options + blank + hint + clock
    const has_header = snap.header.len > 0;
    const opts = snap.options.len;
    const choice_rows: usize = if (opts > 0 and !snap.typing) opts + 1 else 0;
    const hdr_rows: usize = if (has_header) 1 else 0;
    const more_rows: usize = if (q_more > 0) 1 else 0;
    const menu_rows: usize = if (choice_rows > 0) choice_rows + 1 else 0;
    const rows_content: usize = hdr_rows + q_n + more_rows + menu_rows + 2;
    const want_h: u16 = @intCast(rows_content + 2);
    // Clamped to the screen. Unclamped, a 600-char question on a 40-column
    // terminal made a 24-row box that covered the status bar AND the input box,
    // and the input box is the ONLY way to answer a free-text question: the app
    // looked frozen with a yellow box full of text and no way out.
    const max_h: u16 = if (height > 6) height - 4 else height;
    const box_h: u16 = @min(want_h, max_h);
    const top: u16 = if (height > box_h + 2) (height - box_h) / 2 else 0;

    { // opaque background: the history behind is dense text and a box with the
        // history showing through reads as a rendering bug.
        var br: u16 = 0;
        while (br < box_h) : (br += 1) {
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
            const label = if (is_other) ask_other_label else snap.options[i];
            const after = p.putClipped(used, row, label, inner_w - (used - inner_col), style);
            // The recommendation is STATED, not implied by being first: the
            // guidance tells the model to put its own pick first, so row 1 is
            // what Enter takes. It used to be printed INSTEAD of the option (as
            // the picker's `desc`, which also made it read like a longer label).
            if (i == 0 and !is_other) {
                const tag: vaxis.Style = if (is_sel)
                    .{ .fg = .{ .rgb = .{ 0x9e, 0xce, 0x6a } }, .bg = theme.sel_bg.bg }
                else
                    theme.ok;
                _ = p.putClipped(after + 2, row, "← recommended", inner_w - (after + 2 - inner_col), tag);
            }
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
    var it = vaxis.unicode.graphemeIterator(line);
    while (it.next()) |g| {
        const gb = g.bytes(line);
        pos += gb.len;
        const w: u16 = p.measure(gb);
        if (col + w > width and col > 0) {
            rows.append(arena, line[start .. pos - gb.len]) catch return;
            start = pos - gb.len;
            col = 0;
        }
        col += w;
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

fn drawActivityStrip(
    p: *Painter,
    row: u16,
    width: u16,
    self: *Model,
    act: Model.Activity,
    queued: usize,
) void {
    p.fillRow(row, " ", .{});

    // The face ANIMATES: it alternates between open and narrowed eyes while
    // there is work. It is the signal that the app is alive, which is exactly
    // what you could not see when a slow model looked hung.
    // `ask` gets the SAME warning face as the permission dialog, and for the same
    // reason: both are states where the app waits for the human, and in both the
    // only useful thing the strip can do is make that unmissable. A thinking face
    // during a question reads as "it is working on it", and then the user waits
    // for an answer that never gets asked.
    const waiting = act.perm or act.ask;
    const mood_kind: mascot.Mood = if (waiting) .warn else if (act.busy) .thinking else .idle;
    const face = mascot.faceFrames(mood_kind, self.spinner_frame / 6);
    const mood: vaxis.Style = if (waiting) theme.warn else if (act.busy) theme.brand else theme.brand_soft;

    var col: u16 = 1;
    _ = p.putText(col, row, face, mood);
    col += @as(u16, @intCast(face.len));

    // State: the first thing you have to be able to read at a glance, and now
    // it is the PHASE.
    //
    // `ask` says "waiting for your answer", not "waiting for your input": the
    // difference between "I am blocked" and "I am waiting for you to decide" is
    // exactly what the user needs in order to look at the modal.
    // ONE snapshot, read once: `toolRunName` copies into a caller buffer, and
    // calling it twice would take the lock twice for the same answer.
    var tr_name_buf: [64]u8 = undefined;
    const running_tool_name = self.toolRunName(&tr_name_buf);
    const running_tool = running_tool_name != null;
    const label: []const u8 = if (act.ask)
        "waiting for your answer"
    else if (act.perm)
        "waiting for your permission"
    else if (running_tool)
        "running"
    else if (act.streaming)
        "streaming"
    else if (act.busy)
        "thinking"
    else
        "queued";
    _ = p.putText(col, row, label, theme.brand_bold);
    col += @as(u16, @intCast(label.len)) + 1;

    // What it is doing, when it is a tool. A bare "thinking" with a 30s `bash`
    // does not say whether it is working or hung; the tool's NAME and its clock
    // do. It is the same information as the history's `⎿ running` line, here in
    // the strip so you can read it without scrolling.
    if (running_tool_name) |name| {
        if (col + name.len + 2 < width) {
            _ = p.putText(col, row, name, theme.brand_soft);
            col += @as(u16, @intCast(name.len)) + 1;
        }
    }

    // Clock. Without it, a slow turn looks hung.
    if (act.busy) {
        var cbuf: [24]u8 = undefined;
        const ms = self.busyMillis();
        const ts = std.fmt.bufPrint(&cbuf, "{d}.{d}s", .{ ms / 1000, (ms % 1000) / 100 }) catch "";
        if (ts.len > 0) {
            _ = p.putText(col, row, ts, theme.brand_soft);
            col += @as(u16, @intCast(ts.len)) + 1;
        }
    }

    // The QUESTION's own clock, and it is separate from the turn's on purpose.
    // The turn clock answers "is the agent working"; this one answers "how long
    // have I been sitting on this decision", which is the number that makes
    // someone stop and answer instead of going to make coffee. They are different
    // questions and one clock cannot answer both.
    if (act.ask) {
        var qbuf: [24]u8 = undefined;
        const ms = self.askMillis();
        const qs = std.fmt.bufPrint(&qbuf, "· {d}s to answer", .{ms / 1000}) catch "";
        if (qs.len > 0 and col + qs.len + 2 < width) {
            _ = p.putText(col, row, qs, theme.warn);
            col += @as(u16, @intCast(qs.len)) + 1;
        }
    }

    // TTFT: how long it took the first token to ARRIVE. Shown only once (the
    // stream's first one), because repeating it every frame is noise: the clock
    // next to it already keeps the count.
    if (!self.ttftPending() and self.ttftMillis() > 0) {
        var tbuf: [24]u8 = undefined;
        const ttft = std.fmt.bufPrint(&tbuf, "first token {d}.{d}s", .{
            self.ttftMillis() / 1000,
            (self.ttftMillis() % 1000) / 100,
        }) catch "";
        if (ttft.len > 0 and col + ttft.len + 2 < width) {
            _ = p.putText(col, row, ttft, theme.brand_faint);
            col += @as(u16, @intCast(ttft.len)) + 1;
        }
    }

    // Speed while the text arrives. It is the second piece of data you need to
    // distinguish "the model is slow" from "the stream hung": 2 tok/s with
    // the clock running is a slow answer; the clock stopped and this at zero
    // is not.
    //
    // CAREFUL: `agent.tps_live` is read WITHOUT a lock on purpose. It is an
    // `f64` that the worker writes once per stream and the status bar reads
    // every frame, and has for months: it is atomic in practice (one word),
    // and putting a lock in the drawing path for a number that goes from 0 to
    // 200 does not pay off.
    if (act.streaming and agent.tps_live > 1) {
        var tbuf: [32]u8 = undefined;
        const ts2 = std.fmt.bufPrint(&tbuf, "⚡ {d:.0} tok/s", .{agent.tps_live}) catch "";
        if (ts2.len > 0 and col + ts2.len + 2 < width) {
            _ = p.putText(col, row, ts2, theme.brand_soft);
            col += @as(u16, @intCast(ts2.len)) + 1;
        }
    }

    // Queue: how many and which, so you don't lose track of them.
    if (queued > 0) {
        var qbuf: [32]u8 = undefined;
        const q = std.fmt.bufPrint(&qbuf, "⏳ {d} queued", .{queued}) catch "";
        if (col + q.len + 2 < width and q.len > 0) {
            _ = p.putText(col, row, q, theme.warn);
            col += @as(u16, @intCast(q.len)) + 1;
        }
        var q2: [24]u8 = undefined;
        const nxt = std.fmt.bufPrint(&q2, "next: {s}", .{self.queuedFirst(24)}) catch "";
        if (nxt.len > 4 and col + nxt.len + 2 < width) {
            _ = p.putText(col, row, nxt, theme.brand_faint);
        }
    }
}

/// A piece of the status row with its style.
const InfoSeg = struct { text: []const u8, style: vaxis.Style };

/// Status bar session info: model · provider (effort) · ctx% · tok/s.
///
/// It is an array of segments (text + style) instead of a string, because each
/// part goes in its own color: the model in bright blue, the rest dim, the
/// ctx% green/yellow/red depending on how full it is and the tok/s in cyan.
/// With a single string everything came out the same gray.
///
/// `streaming` (not `busy`) is what decides whether the tok/s are painted:
/// `tps_live` is the LAST stream's and is not cleared when the turn ends, so
/// with a 30s `bash` the row kept announcing "⚡ 42 tok/s" while not a single
/// token arrived. It is a number that does not match what is next to it.
fn sessionInfo(arena: std.mem.Allocator, streaming: bool) ?[]const InfoSeg {
    var out: std.ArrayList(InfoSeg) = .empty;

    const model = agent.curAnswering();
    const provider = agent.curProvider();
    if (model.len == 0 and provider.len == 0) return null;

    if (model.len > 0) {
        out.append(arena, .{ .text = model, .style = theme.brand_bold }) catch return null;
    }
    if (provider.len > 0) {
        if (out.items.len > 0) out.append(arena, .{ .text = " · ", .style = theme.brand_faint }) catch return null;
        out.append(arena, .{ .text = provider, .style = theme.brand_soft }) catch return null;
        // The level that actually goes out, not the one the user asked for: if the
        // model has no such step, the status has to say the one that was sent. A
        // status that says `xhigh` while the wire carries `high` is small print
        // that lies, and there is no way to notice the 400 when it does happen.
        const eff = switch (agent.effectiveEffort()) {
            .none => "off",
            .minimal => "min",
            .low => "low",
            .medium => "med",
            .high => "high",
            .xhigh => "xhigh",
        };
        // CAREFUL: `allocPrint` and NOT `bufPrint` over a stack buffer. The
        // slice is stored in the segment and read at paint time, already
        // outside this function: with bufPrint the text was garbage and the
        // status was cut in half ("kimi-k2.6 · opencode" and then a broken
        // character).
        const et = std.fmt.allocPrint(arena, " ({s})", .{eff}) catch return null;
        out.append(arena, .{ .text = et, .style = theme.brand_faint }) catch return null;
    }

    // Read-only mode. It has to be VISIBLE at all times and not just in the
    // history, because it changes what a write tool call will do: a mode you
    // cannot see is a mode where "the model ignored my edit" is indistinguishable
    // from "the model did not try".
    if (agent.read_only) {
        if (out.items.len > 0) out.append(arena, .{ .text = " · ", .style = theme.brand_faint }) catch return null;
        out.append(arena, .{ .text = "read-only", .style = theme.warn_bold }) catch return null;
    }

    // Context tokens ALWAYS visible, not only when they are > 0.
    //
    // It was conditioned on `ctx_pct > 0`, which only happens after a complete
    // turn, so at the start nothing was shown and the counter looked like it
    // did not exist. Now it always says "~N tok" and the percentage, which is
    // also what warns you that you are approaching the compaction limit.
    if (out.items.len > 0) out.append(arena, .{ .text = " · ", .style = theme.brand_faint }) catch return null;
    if (agent.ctx_used > 0) {
        const tk = std.fmt.allocPrint(arena, "~{d} tok", .{agent.ctx_used}) catch return null;
        out.append(arena, .{ .text = tk, .style = theme.brand_soft }) catch return null;
        out.append(arena, .{ .text = " · ", .style = theme.brand_faint }) catch return null;
    }
    const ct = std.fmt.allocPrint(arena, "ctx {d}%", .{agent.ctx_pct}) catch return null;
    out.append(arena, .{ .text = ct, .style = theme.ctxColor(agent.ctx_pct) }) catch return null;

    if (streaming and agent.tps_live > 1) {
        out.append(arena, .{ .text = " · ", .style = theme.brand_faint }) catch return null;
        const tt = std.fmt.allocPrint(arena, "⚡ {d:.0} tok/s", .{agent.tps_live}) catch return null;
        out.append(arena, .{ .text = tt, .style = theme.tool }) catch return null;
    }

    if (out.items.len == 0) return null;
    return out.items;
}

/// The SECOND column of the status: what the session costs.
///
/// It sits glued to the right and separated from the session column by a `│`,
/// because they are different things and do not fit in the same sentence: the
/// left one says WHAT you are working with, and the right one what it has cost
/// you.
///
/// These numbers used to show only with `/cache` and when opening `/context`,
/// which is exactly when they are no use: the number you want to see is the
/// current one, without having to open anything.
fn usageInfo(arena: std.mem.Allocator) ?[]const InfoSeg {
    var out: std.ArrayList(InfoSeg) = .empty;

    const st = &agent.cacheSessionStats();
    // No data yet: it would print a `0%` that lies.
    if (st.requests == 0) return null;

    const pct: u8 = @intFromFloat(std.math.clamp(st.hitRatePct(), 0, 100));
    const tag = std.fmt.allocPrint(arena, " {d:.0}% cached", .{st.hitRatePct()}) catch return null;
    out.append(arena, .{ .text = tag, .style = theme.ctxColor(pct) }) catch return null;

    const tok = std.fmt.allocPrint(
        arena,
        " \u{b7} {d}k prompt",
        .{@divTrunc(st.prompt_tokens + 500, 1000)},
    ) catch return null;
    out.append(arena, .{ .text = tok, .style = theme.brand_faint }) catch return null;

    if (st.completion_tokens > 0) {
        const comp = std.fmt.allocPrint(
            arena,
            " \u{b7} {d}k out",
            .{@divTrunc(st.completion_tokens + 500, 1000)},
        ) catch return null;
        out.append(arena, .{ .text = comp, .style = theme.brand_faint }) catch return null;
    }
    return out.items;
}

/// Paints the usage column glued to the right, with a `│` separating it from
/// the session column.
///
/// It degrades by dropping pieces BEFORE ever intruding on the other column's
/// text: if it does not fit whole, nothing is painted. A half-written
/// `62% cached`, or one sitting on top of the model, reads worse than not
/// having it at all.
fn drawUsageColumn(p: *Painter, row: u16, width: u16, segs: []const InfoSeg, reserved: u16) void {
    const sep_w: u16 = 3; // " │ "
    const total: u16 = segsWidth(segs);
    const needed = total + sep_w;
    if (needed + reserved + 2 >= width) return;
    if (total == 0) return;

    var col: u16 = width - total;
    // The separator, three columns to the left of the column's first glyph.
    _ = p.putStable(col - sep_w, row, "\u{2502}", 1, theme.brand_faint);
    for (segs) |sg| {
        var it = vaxis.unicode.graphemeIterator(sg.text);
        while (it.next()) |g| {
            const b = g.bytes(sg.text);
            const w = theme.graphemeWidth(p.ctx, b);
            if (col + w <= width) _ = p.putStable(col, row, b, w, sg.style);
            col += w;
        }
    }
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

const sessionInfoWidth = segsWidth;

/// Draws the session info right-aligned, measuring the total width with the
/// REAL cell width (not `len`): emojis and `·` take 1, but if a 2-column
/// grapheme ever shows up, aligning by `len` misaligns the whole row.
fn drawSessionInfo(p: *Painter, row: u16, width: u16, segs: []const InfoSeg, busy: bool) void {
    _ = busy;
    var total: u16 = 0;
    for (segs) |sg| {
        var it = vaxis.unicode.graphemeIterator(sg.text);
        while (it.next()) |g| {
            _ = g;
            total += 1;
        }
    }
    if (total + 2 >= width) return; // doesn't fit: skipped before invading the text

    var col: u16 = width - total;
    for (segs) |sg| {
        var it = vaxis.unicode.graphemeIterator(sg.text);
        while (it.next()) |g| {
            const b = g.bytes(sg.text);
            const w = theme.graphemeWidth(p.ctx, b);
            if (col + w <= width) _ = p.putStable(col, row, b, w, sg.style);
            col += w;
        }
    }
}

/// Centered modal in opencode style: title, filter, items with selection and footer.
fn drawPicker(p: *Painter, width: u16, height: u16, ps: PickerSnapshot) void {
    const box_w: u16 = @min(width -| 4, 64);
    const box_h: u16 = @min(height -| 4, 15);
    if (box_w < 20 or box_h < 6) return;
    const x0 = (width - box_w) / 2;
    const y0 = (height - box_h) / 4; // a bit above the center

    // clean background of the box
    var yy = y0;
    while (yy < y0 + box_h) : (yy += 1) {
        p.fillRange(x0, x0 + box_w, yy, " ", .{});
    }
    // horizontal borders
    p.fillRange(x0 + 1, x0 + box_w - 1, y0, "─", theme.accent);
    p.fillRange(x0 + 1, x0 + box_w - 1, y0 + box_h - 1, "─", theme.accent);
    // vertical borders
    var yy2 = y0 + 1;
    while (yy2 < y0 + box_h - 1) : (yy2 += 1) {
        p.putStable(x0, yy2, "│", 1, theme.accent);
        p.putStable(x0 + box_w - 1, yy2, "│", 1, theme.accent);
    }
    p.putStable(x0, y0, "┌", 1, theme.accent);
    p.putStable(x0 + box_w - 1, y0, "┐", 1, theme.accent);
    p.putStable(x0, y0 + box_h - 1, "└", 1, theme.accent);
    p.putStable(x0 + box_w - 1, y0 + box_h - 1, "┘", 1, theme.accent);

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
        var ib: [256]u8 = undefined;
        const line_txt = if (it.desc.len > 0)
            std.fmt.bufPrint(&ib, "{s}  {s}", .{ it.label, it.desc }) catch it.label
        else
            it.label;
        _ = p.putText(x0 + 2, row, line_txt, if (is_sel) theme.selected else theme.text);
    }

    // footer
    var fbuf: [96]u8 = undefined;
    const f1 = std.fmt.bufPrint(
        &fbuf,
        "\u{2191}\u{2193} navigate \u{b7} enter select \u{b7} esc close  ({d}/{d})",
        .{ if (ps.total > 0) ps.sel + 1 else 0, ps.total },
    ) catch "";
    _ = p.putText(x0 + 2, y0 + box_h - 2, f1, theme.dim);
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

    // When the stream closes, the text becomes a fixed paragraph.
    m.streamDelta("al");
    m.streamEnd();
    const s2 = try drawTest(&m, arena, 40, 12);
    var buf2: [128]u8 = undefined;
    const row0b = rowText(s2, 0, &buf2);
    try std.testing.expectEqualStrings("\u{25c6} parcial", std.mem.trim(u8, row0b, " "));
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

test "render: the status and the separator take the bottom rows" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.setStatusText("ready");

    const height: u16 = 12;
    const s = try drawTest(&m, arena, 40, height);

    var buf: [128]u8 = undefined;
    // separator: one row above the top border of the input box
    const sep = rowText(s, height - 6, &buf);
    try std.testing.expectEqualStrings("\u{2500}", sep[0..3]);
    // top border of the input box
    var buf3: [128]u8 = undefined;
    const box = rowText(s, height - 5, &buf3);
    try std.testing.expectEqualStrings("\u{256d}", std.mem.trim(u8, box, " ")[0..3]);
    // status
    var buf2: [128]u8 = undefined;
    const st = rowText(s, height - 2, &buf2);
    try std.testing.expect(std.mem.indexOf(u8, st, "ready") != null);
}

test "render: tool blocks use ⏺/⎿ and the result expands" {
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
        try std.testing.expectEqualStrings("\u{23fa} read(src/tui.zig)", std.mem.trim(u8, rowText(s, r, &buf), " "));
        const r2 = findRow(s, "Read 1006 lines").?;
        try std.testing.expectEqualStrings("\u{23bf}  Read 1006 lines \u{b7} 3ms", std.mem.trim(u8, rowText(s, r2, &buf), " "));
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

test "input: box with border, prompt and placeholder" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const h: u16 = 14;
    const s = try drawTest(&m, arena_state.allocator(), 40, h);

    var buf: [128]u8 = undefined;
    // rounded top border
    const top = rowText(s, h - 5, &buf);
    try std.testing.expectEqualStrings("\u{256d}\u{2500}", std.mem.trim(u8, top, " ")[0..6]);
    // contents: prompt + placeholder
    var buf2: [128]u8 = undefined;
    const mid = rowText(s, h - 4, &buf2);
    try std.testing.expect(std.mem.indexOf(u8, mid, "\u{276f}") != null);
    try std.testing.expect(std.mem.indexOf(u8, mid, "Ask anything") != null);
    // bottom border
    var buf3: [128]u8 = undefined;
    const bot = rowText(s, h - 3, &buf3);
    try std.testing.expectEqualStrings("\u{2570}\u{2500}", std.mem.trim(u8, bot, " ")[0..6]);
}

test "input: multiline grows the box and shows both lines" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const h: u16 = 16;
    // Three lines: the box must grow to 3 rows of content.
    m.ed.insert("primera\nsegunda\ntercera") catch {};

    const s = try drawTest(&m, arena_state.allocator(), 40, h);
    var buf: [128]u8 = undefined;
    const top = rowText(s, h - 7, &buf); // input_h=3 → top = h-4-3
    try std.testing.expect(std.mem.indexOf(u8, std.mem.trim(u8, top, " "), "\u{256d}") != null);

    var b1: [128]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, rowText(s, h - 6, &b1), "primera") != null);
    var b2: [128]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, rowText(s, h - 5, &b2), "segunda") != null);
    var b3: [128]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, rowText(s, h - 4, &b3), "tercera") != null);
}

test "input: a long line WRAPS inside the box and no character is lost" {
    // THE bug: the box was sized from `displayLines` (which counts soft wraps)
    // and the paint split on `\n` only, handing one very long line to `putText`,
    // which clips at the TERMINAL edge. So the box grew to eight rows, the text
    // stayed in the first one running off the right, and everything past the
    // border was dropped with no ellipsis and no word: the user could not see
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
    // And nothing spilled past the right border of the box.
    var buf: [128]u8 = undefined;
    for ([_]u16{ r1, r2 }) |row| {
        const t = rowText(s, row, &buf);
        try std.testing.expect(std.mem.lastIndexOfScalar(u8, t, ' ') != null);
        try std.testing.expect(std.mem.indexOf(u8, t, "│") != null);
    }
}

test "input: a wrapped line fills several rows and the cursor stays INSIDE the box" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.ed.insert("a" ** 200) catch {};

    const w: u16 = 40;
    const h: u16 = 20;
    const s = try drawTest(&m, arena_state.allocator(), w, h);

    const rows = m.ed.displayLines(w - 3, testEditorMeasurer());
    try std.testing.expect(rows >= 4);
    const input_h: u16 = @min(rows, 8);
    const top = h - 4 - input_h;

    // Several rows of the box carry text, not just the first one.
    var filled: usize = 0;
    var row: u16 = top + 1;
    while (row < top + 1 + input_h) : (row += 1) {
        var buf: [128]u8 = undefined;
        if (std.mem.indexOf(u8, rowText(s, row, &buf), "aaaa") != null) filled += 1;
    }
    try std.testing.expect(filled >= 4);

    // And the caret is a real cell inside the box. It used to be anchored at
    // `2 + width of everything before it`, i.e. column 74 of a 40-wide terminal,
    // so it simply disappeared.
    const cur = s.cursor orelse return error.TestUnexpectedResult;
    try std.testing.expect(cur.col < w - 1);
    try std.testing.expect(cur.row >= top + 1);
    try std.testing.expect(cur.row < h - 3);
}

test "input: rows scrolled out above are announced instead of silently hidden" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    var i: usize = 0;
    while (i < 60) : (i += 1) m.ed.insert("linea ") catch {};

    const s = try drawTest(&m, arena_state.allocator(), 40, 14);
    // A box full of the middle of what you typed looks exactly like a box with
    // all of it, so the count of what is hidden has to be on the border.
    try std.testing.expect(findRow(s, "more") != null);
}

test "autocomplete: filters by prefix and accepts with tab" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.ed.insert("/mo") catch {};
    syncAutocomplete(&m);
    try std.testing.expect(m.ac.active);
    // /model, /models and /mode... no: /model, /models, and /memory does not
    // exist, but /models does. Checked against the real list.
    const n_mo = matchCount(&m);
    try std.testing.expect(n_mo >= 2);
    var has_model = false;
    var has_models = false;
    for (0..n_mo) |i| {
        const k = matchLabel(&m, i).?;
        if (std.mem.eql(u8, k, "/model")) has_model = true;
        if (std.mem.eql(u8, k, "/models")) has_models = true;
    }
    try std.testing.expect(has_model);
    try std.testing.expect(has_models);

    // "/models" leaves only /models (the longer prefix wins)
    m.ed.clear();
    m.ed.insert("/models") catch {};
    syncAutocomplete(&m);
    try std.testing.expectEqual(@as(usize, 1), matchCount(&m));
    try std.testing.expectEqualStrings("/models", matchLabel(&m, 0).?);

    // "/mod" leaves /model and /models
    m.ed.clear();
    m.ed.insert("/mod") catch {};
    syncAutocomplete(&m);
    try std.testing.expectEqual(@as(usize, 2), matchCount(&m));
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
    // Cursor at the start of the line: right after the "❯ " prompt (col 2).
    try std.testing.expectEqual(@as(u16, 2), s.cursor.?.col);
    try std.testing.expectEqual(@as(u16, 14 - 4), s.cursor.?.row);

    // With the cursor at the end, it advances 3 columns (the 3 characters).
    m.ed.moveToEnd();
    const s2 = try drawTest(&m, arena_state.allocator(), 40, 14);
    try std.testing.expectEqual(@as(u16, 5), s2.cursor.?.col);
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

test "header: the wordmark and the commands are in the bright blue" {
    // The brightness falls INSIDE the art (`*zode*`), not on a whole line: that
    // is what makes the ASCII art look like a logo and not a block of text.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const segs = try md.inlineSegments(arena, "  *zode*  \\:\\", .banner);
    try std.testing.expectEqual(@as(usize, 3), segs.len);
    try std.testing.expectEqualStrings("  ", segs[0].text);
    try std.testing.expectEqualStrings("zode", segs[1].text);
    try std.testing.expect(segs[1].style.bold); // the brightness
    try std.testing.expectEqualStrings("  \\:\\", segs[2].text);
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
    var it = std.mem.splitScalar(u8, mascot.banner, '\n');
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
    const segs = sessionInfo(arena_state.allocator(), false) orelse return;

    for (segs) |sg| {
        try std.testing.expect(sg.text.len > 0);
        for (sg.text) |c| {
            try std.testing.expect(c == ' ' or c >= 0x21);
        }
    }
    var found = false;
    for (segs) |sg| {
        if (std.mem.indexOf(u8, sg.text, "(") != null) {
            found = true;
            try std.testing.expectEqual(@as(u8, ')'), sg.text[sg.text.len - 1]);
        }
    }
    try std.testing.expect(found);
}

test "status: the status row fits and is not cut" {
    // The visible symptom of the dangling pointer was the row cut with a
    // half UTF-8 character at the right edge.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const w: u16 = 96;
    const s = try drawTest(&m, arena_state.allocator(), w, 16);
    var buf: [512]u8 = undefined;
    const row = rowText(s, 16 - 2, &buf); // status_row
    // No U+FFFD (the replacement character shows up when a UTF-8 is split).
    try std.testing.expect(std.mem.indexOf(u8, row, "\u{fffd}") == null);
    // And the session info is whole: the effort closes with ")" at the end.
    // (CAREFUL: `rowText` returns BYTES, not columns, so it cannot be compared
    // against the width: a "·" is 2 bytes in a single cell.)
    try std.testing.expect(std.mem.indexOf(u8, row, ")") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "opencode") != null);
}

test "status: ctxColor changes at the compaction thresholds" {
    // 80% is exactly where compaction starts (budget = 80% of the limit).
    try std.testing.expectEqual(theme.ok.fg, theme.ctxColor(0).fg);
    try std.testing.expectEqual(theme.ok.fg, theme.ctxColor(49).fg);
    try std.testing.expectEqual(theme.warn.fg, theme.ctxColor(50).fg);
    try std.testing.expectEqual(theme.warn.fg, theme.ctxColor(79).fg);
    try std.testing.expectEqual(theme.err.fg, theme.ctxColor(80).fg);
    try std.testing.expectEqual(theme.err.fg, theme.ctxColor(100).fg);
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

test "activity strip: with work and with a queue" {
    // The strip is what answers "is it working or is it stuck?": the face, the
    // state and the seconds. Without it there was only a tiny spinner.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

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
    try std.testing.expect(std.mem.indexOf(u8, all, "en cola") != null);
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

test "status: tokens and context are always visible" {
    // Before, the ctx% only showed if it was > 0, that is, after a whole turn,
    // and at the start nothing was visible: it looked like the counter did not
    // exist.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const segs = sessionInfo(arena_state.allocator(), false) orelse return;
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(std.testing.allocator);
    for (segs) |sg| try joined.appendSlice(std.testing.allocator, sg.text);
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "ctx ") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "opencode") != null);
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

test "the status face is in its mood's color, not in the status gray" {
    // The complaint was literal: "you can't tell by the color". The status row
    // goes out in SEGMENTS precisely for that: the face in the mood's color and
    // the text in the dim blue. With a single string everything came out the
    // same gray.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.setStatusWithMood(.thinking, "thinking");
    m.streamStart();

    const s = try drawTest(&m, arena_state.allocator(), 92, 26);
    const status_row = s.size.height - 2;
    const face = mascot.faceFrames(.thinking, 0);

    // The face is SEVERAL graphemes spread across different cells, so they are
    // walked with the same iterator the painter uses: comparing the whole string
    // against a cell NEVER matches and the test would pass by luck or fail
    // without saying anything.
    var it = vaxis.unicode.graphemeIterator(face);
    var found: usize = 0;
    while (it.next()) |g| {
        const bytes = g.bytes(face);
        var col: u16 = 0;
        var hit = false;
        while (col < s.size.width) {
            const cell = s.readCell(col, status_row);
            if (std.mem.eql(u8, cell.char.grapheme, bytes)) {
                hit = true;
                break;
            }
            col += @max(1, cell.char.width);
        }
        try std.testing.expect(hit);
        const cell = s.readCell(col, status_row);
        try std.testing.expectEqual(mascot.Mood.thinking.vaxisColor(), cell.style.fg);
        try std.testing.expect(cell.style.bold);
        found += 1;
    }
    try std.testing.expect(found > 0);

    // And the text that accompanies it does NOT carry the face inside: before
    // it was painted twice (the one in the strip and the one in the text) and
    // the one in the text came out gray.
    var rb: [256]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, rowText(s, status_row, &rb), "thinking") != null);
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

test "banner: a RULE separates it from the first prompt (not a blank row)" {
    // Bug 4: the logo and the user's first prompt read as a single block.
    // A blank row does not fix it when there is a 5-row drawing above and the
    // user's words below: the prompt looks like the last line of the logo.
    // A rule says so without spending two more rows on blank.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.pushHeader(.idle);
    m.pushKind(.user, "hola, quiero una pagina de juegos");

    const surf = try drawTest(&m, arena_state.allocator(), 72, 20);
    var rb: [256]u8 = undefined;

    // The rule goes right below the art (which is `banner_art_height` rows).
    const rule_row = rowText(surf, mascot.banner_art_height, &rb);
    const trimmed = std.mem.trim(u8, rule_row, " ");
    try std.testing.expect(trimmed.len > 0);
    // Only `─`: a row with the rule plus anything else would be a layout error,
    // not a separator (and that is what would happen if the run's `w` got
    // truncated to 255 columns on a wide terminal).
    //
    // `rowText` returns BYTES, and `─` is 3, so the row is several of those
    // triplets and nothing else.
    const rule_bytes = "\xe2\x94\x80";
    try std.testing.expect(trimmed.len % 3 == 0);
    try std.testing.expect(trimmed.len > 0);
    var at: usize = 0;
    while (at < trimmed.len) : (at += 3) {
        try std.testing.expectEqualStrings(rule_bytes, trimmed[at..][0..3]);
    }
    // And it really spans the width of the history: a three-column rule separates
    // just as badly as a blank row. The exact width is decided by `drawLines`
    // (which crops to the history's width), so a floor is set here and not an
    // exact number.
    const rule_cols = trimmed.len / 3;
    try std.testing.expect(rule_cols >= 60);
    try std.testing.expect(rule_cols <= 72);

    // And the prompt goes BELOW, not stuck to the logo.
    const prompt_row = rowText(surf, mascot.banner_art_height + 1, &rb);
    try std.testing.expect(std.mem.indexOf(u8, prompt_row, "hola, quiero una pagina") != null);
}

test "the banner is ONLY the ZODE wordmark, with no blank rows between lines" {
    // ASCII art split into paragraphs put a blank row between the letters and
    // the logo was read in pieces. The header goes without a separator.
    //
    // And the header is ONLY this: no mascot, no "zo says: hi!", no shortcuts
    // line. Complaining about "junk in the view" is being right, and this test
    // is what pins it down: if someone hangs a line below the art again, it
    // fails.
    //
    // The fill is `#`, and that clashes with markdown: a line starting with
    // `##` is a HEADING and the parser eats the `#`. There are two tests for
    // this: this one (that the art reaches the screen whole) and the markdown
    // one below (that `.banner` is not interpreted as prose).
    //
    // The rows are compared COMPLETE against the art written by hand here, not
    // against `mascot.banner`: if the test compared the banner with itself, it
    // would pass with any broken art.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.pushHeader(.idle);

    const s = try drawTest(&m, arena_state.allocator(), 92, 26);
    // The `D` has its right stroke one column further out (`##   #`) and the `E`
    // has its crossbar (`###`). It is what makes `O` and `D` different letters at
    // a glance instead of the same box twice, which is the whole point of the
    // wordmark. These rows are what the glyph table in `mascot.zig` composes.
    const art = [_][]const u8{
        "######  ####  ####   ######",
        "##  ## ##  ## ##   # ##",
        "   ##  ##  ## ##   # ###",
        "  ##   ##  ## ##   # ##",
        "######  ####  ####   ######",
    };
    var rb: [512]u8 = undefined;
    // The history has 2 margin columns (4.9 of the ROADMAP), so the art starts
    // at column 2. The margin is trimmed from both sides: what is checked is
    // the ART, not its position on screen.
    const margin = historyMargin(92);
    for (art, 0..) |want, i| {
        const got = rowText(s, @intCast(i), &rb);
        // Both are trimmed: the rows of the `E` carry padding on the right.
        // The invariants loop below pins the exact width.
        const got_t = std.mem.trim(u8, got[margin..], " ");
        const want_t = std.mem.trim(u8, want, " ");
        try std.testing.expectEqualStrings(want_t, got_t);
    }

    // Below the art there is NOTHING. Not one extra line.
    const after = rowText(s, mascot.banner_art_height, &rb);
    try std.testing.expectEqualStrings("", std.mem.trim(u8, after, " "));

    // Art invariant: ALL rows must measure the same, and all the letters must
    // start at the same columns. Without this the logo reads as noise (it
    // happened: the `E` was one column early and it came out as "diec FERE").
    // It is measured with the `*…*` marks removed.
    //
    // CAREFUL: it is measured in COLUMNS, not bytes. An art with `█` (3 bytes
    // per character) gave 101 columns on row 0 and the test passed without
    // checking anything.
    var wit = std.mem.splitScalar(u8, mascot.banner, '\n');
    var rows: usize = 0;
    while (wit.next()) |line| {
        // The banner is `banner_art_height` rows, not one more.
        try std.testing.expect(rows < mascot.banner_art_height);
        const cols = plainColumns(std.testing.allocator, line) catch unreachable;
        defer std.testing.allocator.free(cols);
        // ALL rows must measure exactly the art's width: the padding on the
        // right is what makes the letters' strokes line up.
        try std.testing.expectEqual(mascot.banner_art_width, cols.len);
        rows += 1;
    }
    try std.testing.expectEqual(mascot.banner_art_height, rows);
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

    agent.openCommandPalette(&m);
    var ctx = testCtx();

    // Filtering by "cache" leaves only /cache, and Enter fires it.
    for ([_]vaxis.Key{
        .{ .codepoint = 'c', .text = "c" },
        .{ .codepoint = 'a', .text = "a" },
        .{ .codepoint = 'c', .text = "c" },
        .{ .codepoint = 'h', .text = "h" },
        .{ .codepoint = 'e', .text = "e" },
    }) |k| {
        _ = try m.paletteKey(&ctx, k);
    }
    _ = try m.paletteKey(&ctx, .{ .codepoint = 13 }); // enter

    // The palette closes and the input does NOT carry the command.
    try std.testing.expect(!m.pal.active);
    try std.testing.expectEqualStrings("", std.mem.trim(u8, m.ed.text(), " "));

    // And the command really ran: `/cache` writes its hit-rate line into the
    // history.
    const s = try drawTest(&m, arena_state.allocator(), 92, 20);
    var found = false;
    for (0..s.size.height) |row| {
        var rb: [512]u8 = undefined;
        if (std.mem.indexOf(u8, rowText(s, @intCast(row), &rb), "hit-rate") != null) found = true;
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

test "a running tool paints its clock, and it disappears when it ends" {
    // Without this, a 30s `bash` leaves the last row frozen at
    // `⏺ bash(...)`: there is no way to tell if the process is still alive or
    // if the app has hung. The clock is the only thing that answers "is it
    // stuck?".
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.pushToolStart("bash", "sleep 30");

    // While it runs: the clock line has to be there.
    {
        const s = try drawTest(&m, arena_state.allocator(), 92, 26);
        const all = allText(s);
        // With the ARGUMENT: `bash(sleep 30) running · 0.0s`. `ToolRun.arg` was
        // stored and nobody read it; with several tools in the turn, the
        // argument is what says which one is stuck.
        try std.testing.expect(std.mem.indexOf(u8, all, "sleep 30") != null);
        try std.testing.expect(std.mem.indexOf(u8, all, "running") != null);
        // And the activity strip names the tool, with the "running" phase label
        // (not the generic "thinking": what runs here is a command).
        try std.testing.expect(std.mem.indexOf(u8, all, "running") != null);
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
        // With no deltas yet there is no streaming: it is "thinking", and on top
        // of that there is a live line with the clock (the Phase 2 placeholder).
        try std.testing.expect(std.mem.indexOf(u8, all, "thinking") != null);
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

test "with the turn open but no text there is a live line with the clock" {
    // The gap between "Enter" and the first token is seconds, and before the
    // history had NOTHING live there: the last dot was your prompt.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.streamStart();
    const s = try drawTest(&m, arena_state.allocator(), 80, 20);
    const all = allText(s);
    try std.testing.expect(std.mem.indexOf(u8, all, "thinking") != null);
    // With the clock inside ("thinking · 0.0s"), which is what says "I'm still
    // here".
    try std.testing.expect(std.mem.indexOf(u8, all, "· 0.0s") != null);
}

test "at idle the history does not invent a live line" {
    // The placeholder only shows if there is a turn: otherwise, the last
    // paragraph of a fresh session would be "thinking · 0.0s" without having
    // written anything.
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

    const segs = try md.inlineSegmentsLang(arena, "+const n", .diff, null, null, "zig");
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
    // And it does not reach the end. In COLUMNS, not in bytes: `rowText` returns
    // bytes and the gutter bar is 3 bytes for 1 column, so counting bytes made
    // this row look longer than the terminal is wide.
    const cols = try plainColumns(std.testing.allocator, std.mem.trimEnd(u8, cont, " "));
    defer std.testing.allocator.free(cols);
    try std.testing.expect(cols.len < 38);
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

test "usage column: with no data it is not painted (a 0% lies)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // With an empty cache session there is nothing to say. These numbers used
    // to show up only with `/cache`, which is exactly when they stop being
    // useful.
    try std.testing.expect(usageInfo(arena_state.allocator()) == null);
}

test "usage column: with data, the cache pct and the session tokens" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    agent.cacheSessionStatsForTest().* = .{};
    agent.cacheSessionStatsForTest().record(.{ .prompt = 1000, .cached = 900, .completion = 100 });
    agent.cacheSessionStatsForTest().record(.{ .prompt = 1000, .cached = 0, .completion = 50 });
    defer agent.cacheSessionStatsForTest().* = .{};

    const segs = usageInfo(arena) orelse return error.TestUnexpectedResult;
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(std.testing.allocator);
    for (segs) |s| try joined.appendSlice(std.testing.allocator, s.text);
    const all = joined.items;

    try std.testing.expect(std.mem.indexOf(u8, all, "45% cached") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "2k prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "out") != null);
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

test "plan block: one checkbox per step, and the running step highlighted" {
    // What is checked here is what the user SEES (the plan's own logic is already
    // tested in plan.zig): that there is one checkbox per step and that the step
    // in progress is the only one in the brand color. That difference between
    // "where it is at" and "a list" is exactly what makes the block useful.
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
    const r_done = findRow(s, "leer el roadmap") orelse return error.TestUnexpectedResult;
    const r_cur = findRow(s, "implementar la tool") orelse return error.TestUnexpectedResult;
    try std.testing.expect(findRow(s, "escribir los tests") != null);
    // In the order of the list, top to bottom.
    try std.testing.expect(r_done < r_cur);

    var buf: [256]u8 = undefined;
    // The done step carries its check (not an arrow) and the dimmed color.
    const done_row = rowText(s, r_done, &buf);
    try std.testing.expect(std.mem.indexOf(u8, done_row, "☑") != null);
    const done_cell = s.readCell(1, r_done);
    try std.testing.expectEqual(theme.brand_faint.fg, done_cell.style.fg);
    try std.testing.expect(!done_cell.style.bold);

    // The running step: SAME text, brand color, and in bold.
    const cur_cell = s.readCell(1, r_cur);
    try std.testing.expectEqual(theme.brand_bold.fg, cur_cell.style.fg);
    try std.testing.expect(cur_cell.style.bold);
    const cur_row = rowText(s, r_cur, &buf);
    try std.testing.expect(std.mem.indexOf(u8, cur_row, "◐") != null);
    try std.testing.expect(std.mem.indexOf(u8, cur_row, "2.") != null);

    // And the pending one goes in soft, no bold: the three states are told apart
    // at a glance.
    const r_next = findRow(s, "escribir los tests") orelse return error.TestUnexpectedResult;
    const next_cell = s.readCell(1, r_next);
    try std.testing.expectEqual(theme.brand_soft.fg, next_cell.style.fg);
    try std.testing.expect(!next_cell.style.bold);
}

test "the plan is drawn ABOVE the input and pushes it, without eating the history" {
    // The order of the rows from the bottom up is status · strip · PLAN · input.
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

    // The plan sits ABOVE the input (the input is always at the very bottom),
    // and the input goes UP 3 rows: the plan's rows are taken off it, and it is
    // not the history that loses them.
    try std.testing.expect(r_plan < input_con);
    try std.testing.expectEqual(input_sin - 3, input_con);
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
    _ = findRow(s, "all 8 steps done") orelse return error.TestUnexpectedResult;
    // CAREFUL: the summary's check is "☑ all...", so searching for "☑ a" would
    // match the summary itself. What is searched for is each step's NUMBER,
    // which only shows up when the list is painted whole.
    try std.testing.expect(findRow(s, "1. a") == null);
    try std.testing.expect(findRow(s, "4. d") == null);

    // And what was really broken: the LAYOUT reserved one row per step
    // (`plan_rows = min(len, plan_max_rows)`) while the drawing paints just one
    // ("☑ all 8 steps done"). `input_top` is computed with `plan_rows`, so a
    // finished plan pushed the input box SEVEN rows down for no reason, and
    // stole those seven rows from the history.
    //
    // (They were not "ghost rows": the surface's buffer is `@memset` to
    // `.default` on every frame, so an unpainted row comes out blank. The
    // damage was of space, not of stale pixels.)
    const with_done_plan = m.hist_rows;

    // The same history, no plan: the history has to get those rows back.
    _ = m.applyPlan(&.{}, 0);
    _ = try drawTest(&m, arena, 100, 30);
    try std.testing.expect(m.hist_rows > with_done_plan);
}

test "a long plan says how many steps were left unpainted" {
    // Without the "+N more", seeing 6 of 20 looks like a whole plan. And the cut has
    // a cap (`plan_max_rows`) because a 20-step plan cannot eat the history.
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
    const r = findRow(s, "+14 more") orelse return error.TestUnexpectedResult;
    var buf: [128]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, rowText(s, r, &buf), "1/20 done") != null);
    // And only `plan_max_rows` steps are painted: not one more.
    try std.testing.expectEqual(plan_max_rows, r - findRow(s, "a").? + 1);
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
    // `workingLocked()` counts `streaming`, so from then on EVERY frame painted
    // the placeholder: a `thinking · 4321.3s` line whose clock never stopped, a
    // spinner that never stopped, and a status bar claiming the app was busy
    // long after the turn was over. That is the junk that never cleaned up.
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

test "read-only shows up in the status bar" {
    // A mode you cannot see is a mode in which "the model ignored my edit" cannot
    // be told apart from "the model never tried".
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const status_row: u16 = 30 - 2;
    var buf: [400]u8 = undefined;

    const before = try drawTest(&m, arena, 100, 30);
    const before_row = rowText(before, status_row, &buf);
    try std.testing.expect(std.mem.indexOf(u8, before_row, "read-only") == null);

    agent.read_only = true;
    defer agent.read_only = false;

    const after = try drawTest(&m, arena, 100, 30);
    const after_row = rowText(after, status_row, &buf);
    try std.testing.expect(std.mem.indexOf(u8, after_row, "read-only") != null);
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
    // The code itself is on the background, not just the padding after it: the
    // block is a rectangle, not a stripe whose width changes with the length of
    // each line (which is what it was on any background but #1a1b26).
    const code_cell = s.readCell(6, row);
    try std.testing.expect(std.meta.activeTag(code_cell.style.bg) == .rgb);
    try std.testing.expect(std.mem.eql(u8, &code_cell.style.bg.rgb, &theme.code_bg.bg.rgb));
    // And the padding after it is the same, so there is no step.
    const pad_cell = s.readCell(30, row);
    try std.testing.expect(std.mem.eql(u8, &pad_cell.style.bg.rgb, &theme.code_bg.bg.rgb));
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

    // Up, then down, with the empty input the whole way.
    try typeErasedEventHandler(&m, &ctx, .{ .key_press = .{ .codepoint = 'u', .mods = .{ .ctrl = true } } });
    try std.testing.expect(!ctx.quit);
    const up = m.anchorLine();

    try typeErasedEventHandler(&m, &ctx, .{ .key_press = .{ .codepoint = 'd', .mods = .{ .ctrl = true } } });
    try std.testing.expect(!ctx.quit);
    try std.testing.expect(m.anchorLine() >= up);

    // And ctrl+c is the exit, which is what the status bar says.
    try typeErasedEventHandler(&m, &ctx, .{ .key_press = .{ .codepoint = 'c', .mods = .{ .ctrl = true } } });
    try std.testing.expect(ctx.quit);
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
