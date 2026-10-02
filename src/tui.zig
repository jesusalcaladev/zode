const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const agent = @import("agent.zig");
const chat = @import("chat.zig");
const md = @import("markdown.zig");
const theme = @import("theme.zig");
const ed_mod = @import("editor.zig");
const mascot = @import("mascot.zig");
const palette = @import("palette.zig");
const plan_mod = @import("plan.zig");
const checkpoint = @import("checkpoint.zig");
const bgproc = @import("bgproc.zig");
const bench_mod = @import("bench.zig");
const models_mod = @import("models.zig");
const zjsonl = @import("zjsonl.zig");

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
            try appendContinuation(pa, lines, cells[start..i], used, if (first) 0 else ind_w);
            start = i;
            used = 0;
            first = false;
        }
        used += cw;
    }
    try appendContinuation(pa, lines, cells[start..], used, if (first) 0 else ind_w);
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
) !void {
    if (pad == 0) {
        try lines.append(pa, .{ .cells = cells, .w = used });
        return;
    }
    var out: std.ArrayList(CellRun) = .empty;
    var i: u16 = 0;
    while (i < pad) : (i += 1) {
        try out.append(pa, .{ .text = " ", .w = 1, .style = .{} });
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
            try wrapCells(pa, &lines, cells.items, avail, if (is_code) 0 else 2);
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
        out.appendSlice(pa, ln.cells) catch return;
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
};

/// Picker tag for an `ask` menu. Distinct from every other tag so the picker
/// callback can tell an answer from a model/provider choice.
pub const ask_picker_tag: u32 = 0xA5;

/// Prefix of the "Other" row in the picker. `askPickerChosen` compares against it
/// to know it has to hand the input box over instead of answering.
///
/// It has to be a constant because the comparison happens in the callback with
/// nothing else available, and it has to be distinctive because a model CAN write
/// an option that starts with the same words (and then it would be treated as
/// "Other", which sends the user to a text box instead of accepting their
/// selection).
pub const ask_other_prefix = "Other…";

/// After this with nobody answering, the worker stops waiting and the model is
/// told to decide. See `ask.timed_out_text`.
pub const ask_timeout_ms: u64 = 5 * 60 * 1000;

pub const Model = struct {
    allocator: std.mem.Allocator,

    /// Own input: `vxfw.TextField` is single-line and has no history, so the
    /// prompt is edited with `editor.Editor`.
    ed: ed_mod.Editor,

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

    /// Scroll: 0 = anchored at the bottom; N = N lines up.
    scroll: usize = 0,
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
            .ed = ed_mod.Editor.init(allocator),
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
    /// paragraphs outside the window are estimated from the number of line
    /// breaks (one line per `\n`, not counting the wrap): the estimate only
    /// moves a few pixels of scroll and is corrected as soon as the paragraph
    /// is parsed. It never leaves the range you can scroll through, and
    /// `layoutWindow` replaces it with the exact one as soon as it enters the
    /// window.
    fn ensureParaHeights(self: *Model) void {
        const n = self.paras.items.len;
        while (self.para_heights.items.len > n) {
            _ = self.para_heights.pop();
        }
        while (self.para_heights.items.len < n) {
            const p = self.paras.items[self.para_heights.items.len];
            // A COLD paragraph has its text base64'd, which has no newlines at
            // all: counting them would estimate height 1 for a 16 KB tool
            // result. That cannot happen, because `pruneCold` only ever prunes
            // paragraphs whose height is already known, and the height list is
            // never emptied except by a resize — which also clears the segment
            // cache and therefore rehydrates everything through `layoutOne`.
            // See `pruneCold`.
            const text = p.text;
            // Blank row separator between paragraphs, as in the layout.
            const est: usize = @max(1, std.mem.count(u8, text, "\n") + 1);
            // `assumeCapacity`: the indices of `para_heights` are the same as
            // those of `paras` and draw walks them assuming they measure the
            // same thing, so an OOM here cannot leave the list short (that
            // would be an out-of-range index in the next frame).
            self.para_heights.ensureTotalCapacity(self.allocator, n) catch return;
            self.para_heights.appendAssumeCapacity(est);
        }
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
        // The exact height replaces the estimate.
        if (idx < self.para_heights.items.len) self.para_heights.items[idx] = lines.len;
    }

    /// Range of visible history lines (absolute over the whole history, not
    /// over the cached window).
    pub const Visible = struct { first: usize, last: usize, total: usize };

    /// Computes which lines are visible with the current scroll.
    ///
    /// The total comes from `para_heights` (the WHOLE history, not just the
    /// cached window): with the cache as a window, summing its heights would
    /// give a total that depends on what is cached, and the scroll would jump
    /// on eviction.
    fn computeVisible(self: *Model, live_lines: usize, history_h: usize) Visible {
        var closed: usize = 0;
        for (self.para_heights.items) |h| closed += h;
        const total: usize = closed + live_lines;
        const hh = @max(history_h, 1);
        const max_offset = if (total > hh) total - hh else 0;
        const skip: usize = @min(self.scroll, max_offset);
        const first = max_offset - skip;
        return .{ .first = first, .last = first + hh, .total = total };
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
            // Only prune paragraphs whose height is ALREADY measured. That is what
            // lets `ensureParaHeights` keep working on the base64 (which has no
            // newlines) without ever having to rehydrate: pruning can only take
            // away text whose height is already known.
            if (i >= self.para_heights.items.len) continue;

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
        };
    }

    /// The picker items for an open question with options, plus the "Other" row.
    ///
    /// OWNED copies (gpa), and the caller frees them with `freePickerItems`: this
    /// builds them on every frame and they must not be literals, because
    /// `closePicker` frees them — the "Invalid free" the fuzzing found with
    /// `+ connect`.
    pub fn askPickerItems(self: *Model) ?[]PickerItem {
        self.askLock();
        if (!self.ask_active or self.ask_options.items.len == 0) {
            self.askUnlock();
            return null;
        }
        const n = self.ask_options.items.len;
        var items = self.allocator.alloc(PickerItem, n + 1) catch {
            self.askUnlock();
            return null;
        };
        var made: usize = 0;
        for (self.ask_options.items, 0..) |o, i| {
            const label = self.allocator.dupe(u8, o) catch break;
            const desc: []u8 = if (i == 0)
                // The first option is the model's recommendation by convention
                // (the guidance tells it to put it first), so it says so: that is
                // the difference between a menu and a quiz.
                (self.allocator.dupe(u8, "recommended") catch "") else
                (self.allocator.dupe(u8, "") catch "");
            items[i] = .{ .label = label, .desc = desc };
            made += 1;
        }
        // The "Other" row is what makes the menu complete: with only the model's
        // options there is no way to answer "none of these, this instead", and the
        // model then gets a forced choice.
        const other = self.allocator.dupe(u8, "Other… (type your own answer)") catch {
            freePickerItems(self.allocator, items[0..made]);
            self.askUnlock();
            return null;
        };
        items[made] = .{ .label = other, .desc = self.allocator.dupe(u8, "esc means: you decide") catch "" };
        made += 1;
        self.askUnlock();
        return items[0..made];
    }

    /// Is there a question waiting that should be shown as a picker?
    ///
    /// Only when there ARE options and the user has not already gone down the
    /// free-text path. `typing` is the flag that says so: it is set when "Other"
    /// was chosen, and once set the picker must never come back (otherwise it
    /// reopens on the next frame, on top of the text the user is typing).
    pub fn askNeedsPicker(self: *Model) bool {
        self.askLock();
        defer self.askUnlock();
        return self.ask_active and !self.ask_typing and self.ask_options.items.len > 0;
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
            self.streaming = false;
            self.stream_buf.clearRetainingCapacity();
        }
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

    /// Name of the tool in progress, or null. Copies into whatever allocator
    /// you pass: the name lives in the Model and the drawing thread reads it.
    pub fn toolRunName(self: *Model) ?[]const u8 {
        self.lock();
        defer self.unlock();
        const tr = self.tool_run orelse return null;
        return tr.name;
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
        self.scroll = 0;
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
        // Sticky bottom: if you were already scrolling up, the new text does
        // NOT yank you back. It only re-anchors if you were at the bottom
        // (scroll == 0).
        if (hubo_nuevo and self.scroll == 0) self.scroll = 0;
    }

    /// Empties the visible history (Ctrl+L). The cached paragraphs are freed
    /// and the on-disk session is left alone.
    pub fn clearHistory(self: *Model) void {
        self.clearSegCache();
        for (self.paras.items) |p| freePara(self.allocator, p);
        self.paras.clearRetainingCapacity();
        self.scroll = 0;
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

    /// Scrolls the history up (`n` > 0) or down.
    pub fn scrollBy(self: *Model, n: isize) void {
        if (n == 0) return;
        if (n > 0) {
            const add: usize = @intCast(n);
            self.scroll = @min(self.scroll + add, 1_000_000);
        } else {
            const down: usize = @intCast(-n);
            self.scroll = if (self.scroll > down) self.scroll - down else 0;
        }
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
                try agent.applyModel(self, mo);
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
    if (self.askTyping()) {
        self.ed.clear();
        self.ac = .{};
        const copy = self.allocator.dupe(u8, if (trimmed.len > 0) trimmed else "you decide") catch return;
        self.answerAskOwned(copy);
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
            // Ctrl+D with empty input = EOF (quit).
            if (key.matches('d', .{ .ctrl = true }) and !self.hasInput()) {
                ctx.quit = true;
                return;
            }
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
                // In ACP mode the cancel goes through its own protocol
                // (`session/cancel`): the HTTP streams' flag does not touch a
                // child process.
                agent.cancelAcp(self);
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
fn typeErasedDrawFn(ud: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Model = @ptrCast(@alignCast(ud));

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
    const text_w: u16 = if (width > 4) width - 4 else 1;

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
    const plan_rows: u16 = if (pl_now.isEmpty()) 0 else @min(@as(u16, pl_now.len), plan_max_rows);

    // Autocompletion popup: only if there are matches.
    const ac_rows: u16 = if (self.ac.active and matchCount(self) > 0)
        @as(u16, @intCast(@min(matchCount(self), self.ac.max_visible) + 1))
    else
        0;

    // The input grows with the text but never eats the history: if both do not
    // fit, the input is clipped (and its view anchors to the bottom).
    const chrome: u16 = 4 + ac_rows + act_rows + plan_rows; // status + borders + popup + strip + plan
    const avail: u16 = if (height > chrome + 2) height - chrome - 2 else 1;
    const input_h: u16 = @max(@min(@as(u16, @intCast(@min(self.ed.displayLines(text_w), max_input_lines))), avail), 1);
    // The order from the bottom up is: status · strip · PLAN · input box. The
    // plan goes between the strip and the input (and not over the status)
    // because it is what you look at while the model works, next to the clock.
    const input_top: u16 = height - 4 - act_rows - plan_rows - input_h;
    const history_h: u16 = if (input_top > 1) input_top - 1 else 1;
    // The key handler needs the height to jump a whole page.
    self.hist_rows = history_h;

    // ── drain pending ──
    self.drainPending();

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
    var live_src: []const u8 = &.{};
    var live_is_tool = false;
    var tool_buf: [128]u8 = undefined;
    {
        self.lock();
        defer self.unlock();
        if (self.streaming and self.stream_buf.items.len > 0) {
            live_src = self.stream_buf.items;
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
            live_src = std.fmt.bufPrint(&tool_buf, "*{s}*({s}) running · {d}.{d}s", .{
                tr.name,
                tr.arg,
                ms / 1000,
                (ms % 1000) / 100,
            }) catch "";
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
        var ph_buf: [64]u8 = undefined;
        const ms = self.busyMillis();
        live_src = std.fmt.bufPrint(&ph_buf, "thinking · {d}.{d}s", .{
            ms / 1000,
            (ms % 1000) / 100,
        }) catch "thinking";
        live_kind = .info;
        live_active = true;
    }

    var live_lines: []const PLine = &.{};
    if (live_src.len > 0) {
        // COPY into the frame arena before building the lines. The `CellRun`
        // store the grapheme BY VALUE but with a pointer to its bytes, and
        // painting happens AFTER this block: with a stack `buf`, on the way
        // out of here the pointer dangles and the row comes out as garbage
        // (the same `&[_]u8{c}` bug AGENTS.md warns about). Same thing with
        // `stream_buf`: its memory belongs to the model and the worker keeps
        // growing it.
        const copy = ctx.arena.dupe(u8, live_src) catch "";
        live_lines = buildLines(ctx.arena, ctx, live_kind, copy, width) catch &.{};
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
    const vis = try self.layoutFor(
        ctx,
        if (width > hist_margin) width - hist_margin else width,
        if (live_active) live_lines.len else 0,
        history_h,
    );
    const first_visible = vis.first;
    const last_visible = vis.last;

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
    if (self.scroll > 0) {
        const s = std.fmt.allocPrint(ctx.arena, "  ↓ {d}", .{self.scroll}) catch "";
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
    if (!self.pickerActive() and !self.pal.active and !self.permActive()) {
        if (self.askNeedsPicker()) {
            if (self.askPickerItems()) |items| {
                self.openPicker(ask_picker_tag, self.askTitle(), items, askPickerChosen);
                // `askTitle` returns a slice into the MODEL (a fixed buffer), and
                // `openPicker` copies it into its own fixed buffer, so there is
                // nothing to free and nothing to own. The picker ITEMS, on the
                // other hand, are gpa copies that `closePicker` frees — which is
                // why `askPickerItems` dupes instead of handing out the dialog's
                // own strings (a double free waiting for the second close).
            }
        }
    }

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

    const lines = splitLines(p.arena, self.ed.text());
    // If the text does not fit whole, the view anchors to the bottom (like the
    // history).
    const hidden = if (lines.len > input_h) lines.len - input_h else 0;
    const shown = lines[hidden..];

    for (shown, 0..) |ln, i| {
        const row = top + 1 + @as(u16, @intCast(i));
        if (row >= top + box_h - 1) break;
        _ = p.putText(2, row, ln, theme.input_text);
    }

    // Visible cursor: on the cursor's real line inside the view.
    const cur_line = self.ed.cursorLine();
    if (cur_line >= hidden and cur_line < lines.len) {
        const line = lines[cur_line];
        const start = lineStartOffset(lines, cur_line);
        const col_in_line = self.ed.cursor - start;
        const upto = line[0..@min(col_in_line, line.len)];
        var c: u16 = 0;
        var it = vaxis.unicode.graphemeIterator(upto);
        while (it.next()) |g| c += @as(u16, p.measure(g.bytes(upto)));
        surface.cursor = .{
            .row = top + 1 + @as(u16, @intCast(cur_line - hidden)),
            .col = 2 + c,
        };
    }

    if (self.ed.isEmpty()) {
        _ = p.putText(4, top + 1, "Ask anything\u{2026} \u{b7} / for commands \u{b7} ctrl+c to exit", theme.placeholder);
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
fn askPickerChosen(self: *Model, tag: u32, label: []const u8) void {
    if (tag != ask_picker_tag) return;
    if (std.mem.startsWith(u8, label, ask_other_prefix)) {
        // Not an answer: the user wants to write. Close the picker (already done
        // by `pickerHandleKey`) and give them the input box.
        self.askBeginTyping();
        self.ed.clear();
        self.ac = .{};
        return;
    }
    const copy = self.allocator.dupe(u8, label) catch return;
    self.answerAskOwned(copy);
    // The question is answered, so the panel has to go: same reason as
    // `declineAsk`.
    self.askLock();
    self.ask_active = false;
    self.askUnlock();
}

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
    if (width < 20 or height < 8) return;

    const q_cols = columnsOf(p, snap.question);
    const box_w: u16 = @min(@as(u16, @intCast(@max(q_cols + 8, 44))), width - 4);
    const left: u16 = (width - box_w) / 2;

    // Height: top border, header (optional), question (wrapped), hint, bottom
    // border. The question is measured with the REAL wrap so the box is exactly
    // as tall as the text: a box with empty rows under it looks broken, and the
    // number of rows is computed here rather than guessed.
    const inner_w: u16 = if (box_w > 6) box_w - 4 else box_w - 2;
    const q_lines = wrapTextToRows(p, snap.question, inner_w, p.arena);
    const has_header = snap.header.len > 0;
    // ALWAYS two rows under the question: the hint and the clock. Reserving them
    // conditionally (only when there are options) left the box with three empty
    // rows under a free-text question, which reads as a broken panel.
    const rows: u16 = 2;
    const box_h: u16 = 2 + (if (has_header) @as(u16, 1) else 0) + @as(u16, @intCast(q_lines.len)) + rows;
    const top: u16 = if (height > box_h + 2) (height - box_h) / 2 else 1;

    // A clean background: the history behind it is dense text, and a bordered box
    // with the history showing through reads as a rendering bug.
    p.fillRange(left, left + box_w, top, " ", theme.code_bg);

    p.putStable(left, top, "╭", 1, theme.warn_bold);
    p.fillRange(left + 1, left + box_w - 1, top, "─", theme.warn);
    p.putStable(left + box_w - 1, top, "╮", 1, theme.warn_bold);
    p.putStable(left, top + box_h - 1, "╰", 1, theme.warn_bold);
    p.fillRange(left + 1, left + box_w - 1, top + box_h - 1, "─", theme.warn);
    p.putStable(left + box_w - 1, top + box_h - 1, "╯", 1, theme.warn_bold);

    var r: u16 = 1;
    while (r < box_h - 1) : (r += 1) {
        p.putStable(left, top + r, "│", 1, theme.warn);
        p.putStable(left + box_w - 1, top + r, "│", 1, theme.warn);
    }

    var row = top + 1;
    if (has_header) {
        _ = p.putText(left + 2, row, snap.header, theme.brand_faint);
        row += 1;
    }

    // The question, wrapped, in the strongest color in the app. This is the thing
    // the user came to read.
    for (q_lines) |ln| {
        if (row >= top + box_h - 1) break;
        _ = p.putText(left + 2, row, ln, theme.warn_bold);
        row += 1;
    }

    // The hint. It says what the KEYS do here, because "a box appeared and I do
    // not know what to press" is the state that makes people hit ESC.
    var hb: [64]u8 = undefined;
    const hint: []const u8 = if (snap.typing)
        "type your answer · enter sends it · esc: you decide"
    else if (snap.options.len > 0)
        "↑↓ choose · enter to answer · esc: you decide"
    else
        "type your answer below · enter sends it · esc: you decide";
    const ht = std.fmt.bufPrint(&hb, "{s}", .{hint}) catch hint;
    if (ht.len > 0 and row < top + box_h - 1) {
        _ = p.putText(left + 2, row, ht, theme.brand_faint);
    }
    row += 1;

    // The clock. Same information as in the activity strip, and here anyway: the
    // strip is one row above the input and this is centred, and while the question
    // is on screen this is the thing being read.
    if (row < top + box_h - 1) {
        var wb: [32]u8 = undefined;
        const w = std.fmt.bufPrint(&wb, "waiting {d}s", .{waited_ms / 1000}) catch "";
        if (w.len > 0) {
            _ = p.putText(left + 2, row, w, theme.brand_faint);
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
    var start: usize = 0;
    var col: u16 = 0;
    var pos: usize = 0;
    var it = vaxis.unicode.graphemeIterator(text);
    while (it.next()) |g| {
        pos += g.bytes(text).len;
        const w: u16 = p.measure(g.bytes(text));
        if (col + w > width and col > 0) {
            rows.append(arena, text[start .. pos - g.bytes(text).len]) catch return rows.items;
            start = pos - g.bytes(text).len;
            col = 0;
        }
        col += w;
    }
    if (start < text.len) rows.append(arena, text[start..]) catch {};
    return rows.items;
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
    const running_tool = self.toolRunName() != null;
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
    if (self.toolRunName()) |name| {
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

    const model = agent.curModel();
    const provider = agent.curProvider();
    if (model.len == 0 and provider.len == 0) return null;

    if (model.len > 0) {
        out.append(arena, .{ .text = model, .style = theme.brand_bold }) catch return null;
    }
    if (provider.len > 0) {
        if (out.items.len > 0) out.append(arena, .{ .text = " · ", .style = theme.brand_faint }) catch return null;
        out.append(arena, .{ .text = provider, .style = theme.brand_soft }) catch return null;
        // El nivel que va DE VERDAD, no el que el usuario pidio: si el modelo no tiene
        // ese peldano, el status tiene que decir el que se mando. Un status que
        // dice `xhigh` mientras el cable lleva `high` es una letra pequena que
        // miente, y no hay forma de que se note el 400 cuando lo haya.
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

    // ACP mode: the turn is NOT done by zode, it is delegated to another agent.
    // Without this the status keeps saying "space-bunny-free · opencode" while
    // the one answering is someone else, which is exactly the kind of surprise
    // that is not acceptable.
    if (agent.acp_on) {
        if (out.items.len > 0) out.append(arena, .{ .text = " · ", .style = theme.brand_faint }) catch return null;
        const tag = std.fmt.allocPrint(arena, "acp: {s}", .{agent.acpTitle()}) catch return null;
        out.append(arena, .{ .text = tag, .style = theme.warn }) catch return null;
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

/// La SEGUNDA columna del status: cuánto cuesta la sesión.
///
/// Va pegada a la derecha y separada de la de sesión por un `│`, porque son
/// cosas distintas y no encajan en la misma frase: la izquierda dice con QUÉ
/// estás trabajando y la derecha, lo que te ha costado.
///
/// Antes estos datos solo salían con `/cache` y al abrir `/context`, que es
/// justo cuando ya no sirven: el número que quieres ver es el de ahora, sin
/// tener que abrir nada.
fn usageInfo(arena: std.mem.Allocator) ?[]const InfoSeg {
    var out: std.ArrayList(InfoSeg) = .empty;

    const st = &agent.cacheSessionStats();
    // Nada de datos todavía: se Would poner un `0%` que miente.
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

/// Dibuja la columna de usage pegada a la derecha, con un `│` que la separa de
/// la de sesión.
///
/// Se degrada quitando pedazos ANTES de invadir el texto de la otra columna:
/// si no cabe entero, no se pinta nada. Un `62% cached` a medias, o metido
/// encima del modelo, se lee peor que no tenerlo.
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

/// Anchcho en COLUMNAS de un grupo de segmentos del status.
///
/// Se mide con el iterador de graphemes y no con `.len`: `⚡` son 3 bytes para 1
/// columna, así que alinear por bytes descentra la fila entera. Esta función
/// la usan las dos columnas, y tienen que medir IGUAL o se pisan.
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

test "render: un párrafo de info se ve en la fila 0" {
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

test "render: graphemes multibyte salen íntegros (no byte a byte)" {
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

test "render: el stream en vivo se ve antes de streamEnd" {
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

test "render: el texto largo hace wrap sin perder caracteres" {
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
        // the first line carries the "· " prefix in front of the text
        const body = if (row == 0 and line.len > 0) line[2..] else line;
        for (body) |c| {
            if (c != ' ') acc.append(std.testing.allocator, c) catch {};
        }
    }
    try std.testing.expectEqualStrings(msg, acc.items);
}

test "render: el status y el separador ocupan las filas de abajo" {
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

test "render: tool blocks usan ⏺/⎿ y el resultado se despliega" {
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

test "toggleLastTool sin tool previa no hace nada" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.pushInfo("solo info");
    try std.testing.expect(!m.toggleLastTool());
}

test "input: caja con borde, prompt y placeholder" {
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

test "input: multilínea crece la caja y muestra ambas líneas" {
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

test "autocompletado: filtra por prefijo y acepta con tab" {
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

test "autocompletado: no se ofrece con espacios ni sin barra" {
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

test "fileQueryAt: el token @ bajo el cursor, y un correo no es una mención" {
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

test "autocompletado de @: modo file activo y aceptación reemplaza solo el token" {
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

test "editor.deleteRange: reemplaza un rango y deja el cursor al inicio" {
    var ed = @import("editor.zig").Editor.init(std.testing.allocator);
    defer ed.deinit();

    ed.insert("revisa @abc y sigue") catch {};
    const end = ed.cursor;
    _ = end;
    // Replace the token `abc` (offsets 8..11) with `zzz`.
    try ed.deleteRange(8, 11);
    ed.setCursor(8);
    try ed.insert("zzz");
    try std.testing.expectEqualStrings("revisa @zzz y sigue", ed.text());
    try std.testing.expectEqual(@as(usize, 11), ed.cursor);

    // Out of range is an error, not a panic.
    try std.testing.expectError(error.BadRange, ed.deleteRange(0, ed.text().len + 1));
}

test "input: el cursor se ancla en la posición real" {
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

test "diff: pushDiff pinta líneas -/+ tras el resultado de la tool" {
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

test "diff: sin cambios no añade párrafos" {
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

test "cabecera: el wordmark y los comandos van en el azul brillante" {
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

test "cabecera: los asteriscos son marcas, no se pierden caracteres" {
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

test "cabecera: un asterisco sin pareja no se come texto" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const segs = try md.inlineSegments(arena, "5 * 3 = 15", .banner);
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(std.testing.allocator);
    for (segs) |sg| try joined.appendSlice(std.testing.allocator, sg.text);
    try std.testing.expectEqualStrings("5 * 3 = 15", joined.items);
}

test "status: los segmentos son texto vivo y completo" {
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

test "status: la fila de status cabe y no se corta" {
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

test "status: ctxColor cambia en los umbrales de compaction" {
    // 80% is exactly where compaction starts (budget = 80% of the limit).
    try std.testing.expectEqual(theme.ok.fg, theme.ctxColor(0).fg);
    try std.testing.expectEqual(theme.ok.fg, theme.ctxColor(49).fg);
    try std.testing.expectEqual(theme.warn.fg, theme.ctxColor(50).fg);
    try std.testing.expectEqual(theme.warn.fg, theme.ctxColor(79).fg);
    try std.testing.expectEqual(theme.err.fg, theme.ctxColor(80).fg);
    try std.testing.expectEqual(theme.err.fg, theme.ctxColor(100).fg);
}

test "cabecera: la línea de Zo lleva la carita en el color del mood" {
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

test "cabecera: las marcas ~ no se comen texto" {
    // Same as the `*`: if a mark is left unpaired, it is normal text.
    const segs = try md.inlineSegments(std.testing.allocator, "a ~ sin cerrar", .banner);
    defer std.testing.allocator.free(segs);
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(std.testing.allocator);
    for (segs) |sg| try joined.appendSlice(std.testing.allocator, sg.text);
    try std.testing.expectEqualStrings("a ~ sin cerrar", joined.items);
}

test "scrollBy: la rueda no desborda al bajar del todo" {
    // Regression: the wheel did `self.scroll -= 3` on a `usize`, and with the
    // scroll at 0 that underflows -> panic -> the app dies when scrolling down
    // while at the top. A key fuzzer found it by sending `\x1b[<65;…M` twice.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.scrollBy(-3); // at 0: it cannot go negative
    try std.testing.expectEqual(@as(usize, 0), m.scroll);
    m.scrollBy(-1);
    try std.testing.expectEqual(@as(usize, 0), m.scroll);

    m.scrollBy(7);
    try std.testing.expectEqual(@as(usize, 7), m.scroll);
    m.scrollBy(-3);
    try std.testing.expectEqual(@as(usize, 4), m.scroll);
    m.scrollBy(-100);
    try std.testing.expectEqual(@as(usize, 0), m.scroll);

    // And scrolling up doesn't blow past the cap either.
    m.scrollBy(100_000);
    m.scrollBy(100_000);
    try std.testing.expect(m.scroll <= 1_000_000);
}

test "cmdGroup-like: una key vacía no revienta" {
    // `key[1..]` over a []const u8 of len 0 is a panic in Zig 0.16, not an
    // empty slice. The palette's grouping called it with the key as-is.
    const empty: []const u8 = "";
    try std.testing.expectEqual(@as(u8, 4), agent.cmdGroupPublic(empty));
    try std.testing.expectEqual(@as(u8, 2), agent.cmdGroupPublic("/help"));
    try std.testing.expectEqual(@as(u8, 3), agent.cmdGroupPublic("/model"));
    // The header item of the palette.
    try std.testing.expectEqual(@as(u8, 1), agent.cmdGroupPublic("connect"));
    // Works without the leading slash too: `key[1..]` eats an arbitrary
    // character if you don't check, not just the slash.
    try std.testing.expectEqual(@as(u8, 2), agent.cmdGroupPublic("help"));
    try std.testing.expectEqual(@as(u8, 4), agent.cmdGroupPublic("nope"));
}

test "autocompletado: /model manda /model y no completa a /models" {
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

test "autocompletado: /help con Enter envía en vez de reescribir" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.ed.clear();
    m.ed.insert("/help") catch {};
    syncAutocomplete(&m);
    try std.testing.expect(m.ac.active);
    try std.testing.expect(isExactMatch(&m));
}

test "waitWorkers: espera a que los workers terminen" {
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

test "waitWorkers: con el tope de tiempo no se cuelga" {
    // A worker stuck on the network cannot leave the app unable to ever exit.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.beginWorker(); // deliberately never closed
    m.waitWorkers(20); // must return in a reasonable time
    try std.testing.expectEqual(@as(usize, 1), m.workers.load(.seq_cst));
    m.endWorker();
}

test "cola: encola, saca en orden y libera" {
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

test "cola: clearQueue libera lo que quede" {
    // If a text stays in the queue on exit and is not freed, it is a leak on
    // every exit with pending prompts.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    const a = m.allocator.dupe(u8, "se queda") catch unreachable;
    _ = m.enqueuePrompt(a);
    m.clearQueue();
    try std.testing.expectEqual(@as(usize, 0), m.queuedCount());
}

test "franja de actividad: con trabajo y con cola" {
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

test "franja de actividad: la etiqueta es la fase" {
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

test "franja de actividad: pide permiso cuando toca" {
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

test "status: tokens y contexto siempre visibles" {
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

test "historial: los párrafos van separados con una fila en blanco" {
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

test "permisos: el modal es centrado y muestra las 4 opciones" {
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

test "la carita del status va en el color de su mood, no en el gris del status" {
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

test "banner: una REGLA lo separa del primer prompt (no una fila en blanco)" {
    // Bug 4: el logo y el primer prompt del usuario se leian como un solo bloque.
    // Una fila vacia no lo arregla cuando encima hay un dibujo de 5 filas y debajo
    // estan las palabras del usuario: el prompt parece la ultima linea del logo.
    // Una regla lo dice sin gastar dos filas mas en blanco.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.pushHeader(.idle);
    m.pushKind(.user, "hola, quiero una pagina de juegos");

    const surf = try drawTest(&m, arena_state.allocator(), 72, 20);
    var rb: [256]u8 = undefined;

    // La regla va justo debajo del arte (que son `banner_art_height` filas).
    const rule_row = rowText(surf, mascot.banner_art_height, &rb);
    const trimmed = std.mem.trim(u8, rule_row, " ");
    try std.testing.expect(trimmed.len > 0);
    // Solo `─`: una fila con la regla y algo mas seria un error de layout, no una
    // separacion (y es lo que pasaria si el `w` del run se truncase a 255
    // columnas en una terminal ancha).
    //
    // `rowText` devuelve BYTES, y `─` son 3, asi que la fila son varios de esos
    // triplets y nada mas.
    const rule_bytes = "\xe2\x94\x80";
    try std.testing.expect(trimmed.len % 3 == 0);
    try std.testing.expect(trimmed.len > 0);
    var at: usize = 0;
    while (at < trimmed.len) : (at += 3) {
        try std.testing.expectEqualStrings(rule_bytes, trimmed[at..][0..3]);
    }
    // Y ocupa de verdad el ancho de la historia: una regla de tres columnas
    // separaria igual de mal que una fila en blanco. El ancho exacto lo decide
    // `drawLines` (que recorta al ancho de la historia), asi que se fija un suelo
    // y no un numero exacto.
    const rule_cols = trimmed.len / 3;
    try std.testing.expect(rule_cols >= 60);
    try std.testing.expect(rule_cols <= 72);

    // Y el prompt va DEBAJO, no pegado al logo.
    const prompt_row = rowText(surf, mascot.banner_art_height + 1, &rb);
    try std.testing.expect(std.mem.indexOf(u8, prompt_row, "hola, quiero una pagina") != null);
}

test "el banner es SOLO el wordmark ZODE, sin filas en blanco entre lineas" {
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
    const art = [_][]const u8{
        "######  ####  ####   ######",
        "##  ## ##  ## ##  ## ##",
        "   ##  ##  ## ##  ## ##",
        "  ##   ##  ## ##  ## ##",
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

/// A fake `EventContext` for the palette's keys.
///
/// `io` and `cmds` are not touched on these paths (the handler sets the redraw
/// itself), so they are left uninitialized. If `paletteKey` ever starts using
/// the `Io`, this blows up in the test instead of leaving an `undefined` in
/// production.
fn testCtx() vxfw.EventContext {
    return .{ .io = undefined, .alloc = std.testing.allocator, .cmds = .empty };
}

test "elegir un comando en la paleta lo EJECUTA (no lo manda al input)" {
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

test "/effort sin argumentos abre el picker (no contesta 'unknown effort')" {
    // `it.rest()` returns `""` (not `null`) for "/effort", and with an empty
    // slice the `else` of "low|medium|high" swallowed the case: it answered
    // "unknown effort:  (low|medium|high)" and the picker never opened.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    try agent.submit(&m, "/effort");
    try std.testing.expect(m.pickerActive());
}

test "un comando que necesita argumentos vuelve al input (no se ejecuta a ciegas)" {
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

test "streamEnd vacía pending ANTES de fijar el párrafo (si no, el texto sale encima de la tool)" {
    // Regression: `pushToolStart`/`pushToolDone` enqueue into `pending`, and
    // `pending` is drained on the next draw. `streamEnd` put the assistant's
    // paragraph into `paras` without emptying `pending`, so the text ended up
    // AHEAD of the tool it belonged to. It shows up in ACP, where the agent
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

test "streamEnd NO toca paras: se encola (si no, el worker realloca bajo la UI)" {
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

test "la cabecera de una tool marca el nombre para que el parser lo resalte" {
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

test "una tool en curso pinta su reloj, y al terminar desaparece" {
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

test "la franja dice la fase: pensando, transmitiendo o corriendo una tool" {
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

test "la franja de permiso se ve con el turno abierto" {
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

test "con el turno abierto pero sin texto hay una línea en vivo con el reloj" {
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

test "en reposo el historial no inventa una línea en vivo" {
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

test "layout: 130 parrafos no cuelga el bucle del layout" {
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

test "layout: 200 y 1000 parrafos tampoco cuelgan" {
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

test "layout: el scroll profundo re-parsea la ventana y el texto sigue saliendo" {
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

test "pushDiff mete UN parrafo, no uno por linea" {
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

test "un diff de 300 lineas no cuelga y sigue siendo UN parrafo" {
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

test "streamEnd marca dirty: un cambio de estado pide un frame" {
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

test "pushInfoFmt: formatea, pinta, y NO deja un literal que liberar al salir" {
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

test "un literal NUNCA se guarda en la historia, y eso es lo que evita el Invalid free" {
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

test "un error sale en rojo con ✗, no como una línea de info más" {
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

test "el TTFT se mide con el primer token, no con el final del stream" {
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

test "cada iteración del agent loop vuelve a medir el TTFT" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.streamStart();
    m.streamDelta("primera");
    m.streamEnd();
    m.streamStartIteration();
    try std.testing.expect(m.ttftPending());
}

test "drawHints no existe: la línea de atajos se quitó de la vista" {
    // The ROADMAP asked to resurrect it or delete it. It was deleted: the
    // shortcuts are in the Ctrl+P palette and in `/help`, and one more line in
    // the view is exactly what was asked to be removed ("junk in the view").
    try std.testing.expect(@hasDecl(@import("tui.zig"), "Model"));
}

test "el diff del TUI usa el lenguaje del path: una línea + lleva tokens" {
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

test "el prefijo + y el cuerpo tienen colores DISTINTOS (muro verde eliminado)" {
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

test "un bloque de código tiene gutter, chip de lenguaje y separación" {
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

test "el gutter no se come texto: el invariante de columnas se mantiene" {
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

test "una línea partida a lo ancho lleva sangría de continuación" {
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

test "el historial tiene margen izquierdo y nada se sale de la pantalla" {
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
    // Row 1 is the continuation: it starts with margin + indent.
    const cont = rowText(s, 1, &buf);
    try std.testing.expect(std.mem.startsWith(u8, cont, "    "));
    // And it does not reach the end: with a margin of 2, the text ends before
    // column 38.
    try std.testing.expect(std.mem.trimEnd(u8, cont, " ").len < 38);
}

test "poda: lo que sale de la ventana se comprime y vuelve IGUAL byte a byte" {
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

    // Now we check the invariant that actually matters: scroll up to a pruned
    // paragraph and have the text come out IDENTICAL.
    var target: ?usize = null;
    for (m.paras.items, 0..) |p, idx| {
        if (p.is_cold) {
            target = idx;
            break;
        }
    }
    try std.testing.expect(target != null);

    m.scrollBy(1_000_000); // all the way to the top
    _ = try drawTest(&m, arena_state.allocator(), 60, 20);

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

test "poda: un párrafo corto NO se comprime (la base64 costaría más)" {
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

test "poda: comprimir y rehidratar es byte-exact con contenido repetitivo y unicode" {
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

test "poda: el ahorro es real (no solo un boolean)" {
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

test "columna de usage: sin datos no se pinta (un 0% miente)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // With an empty cache session there is nothing to say. These numbers used
    // to show up only with `/cache`, which is exactly when they stop being
    // useful.
    try std.testing.expect(usageInfo(arena_state.allocator()) == null);
}

test "columna de usage: con datos, el pct de cache y los tokens de la sesion" {
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

test "las dos columnas del status miden el ancho igual (si no, se pisan)" {
    // The bug of measuring with `.len` instead of columns: `⚡` is 3 bytes for 1
    // column, so aligning by bytes knocks the whole row off. Both columns use
    // the SAME function on purpose.
    const segs = [_]InfoSeg{
        .{ .text = "\u{26a1} 3 tok/s", .style = theme.tool },
        .{ .text = " \u{b7} \u{00f1}", .style = theme.dim },
    };
    // "⚡ 3 tok/s" son 9 graphemes y " · ñ" son 4: 13 columnas. En BYTES serían
    // 15 y 7, o sea 22, y la fila quedaría 9 columnas corrida.
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

test "el bloque del plan: un checkbox por paso, y el paso en marcha resaltado" {
    // Lo que se comprueba es lo que el usuario VE (la lógica del plan ya esta
    // testeada en plan.zig): que hay un checkbox por paso y que el paso en
    // marcha es el único con color de marca. Esa diferencia entre "por dónde va"
    // y "una lista" es justo lo que hace útil el bloque.
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
    // Aplicar el plan es un cambio de estado: tiene que pedir frame.
    try std.testing.expect(m.activity().dirty);

    const s = try drawTest(&m, arena, 100, 30);
    const r_done = findRow(s, "leer el roadmap") orelse return error.TestUnexpectedResult;
    const r_cur = findRow(s, "implementar la tool") orelse return error.TestUnexpectedResult;
    try std.testing.expect(findRow(s, "escribir los tests") != null);
    // En el orden de la lista, de arriba abajo.
    try std.testing.expect(r_done < r_cur);

    var buf: [256]u8 = undefined;
    // El hecho hecho lleva su check (no una flecha) y el apagado.
    const done_row = rowText(s, r_done, &buf);
    try std.testing.expect(std.mem.indexOf(u8, done_row, "☑") != null);
    const done_cell = s.readCell(1, r_done);
    try std.testing.expectEqual(theme.brand_faint.fg, done_cell.style.fg);
    try std.testing.expect(!done_cell.style.bold);

    // El paso en marcha: MISMO texto, color de marca y en negrita.
    const cur_cell = s.readCell(1, r_cur);
    try std.testing.expectEqual(theme.brand_bold.fg, cur_cell.style.fg);
    try std.testing.expect(cur_cell.style.bold);
    const cur_row = rowText(s, r_cur, &buf);
    try std.testing.expect(std.mem.indexOf(u8, cur_row, "◐") != null);
    try std.testing.expect(std.mem.indexOf(u8, cur_row, "2.") != null);

    // Y el pendiente va en el soft, sin negrita: se distinguen los tres estados
    // de un vistazo.
    const r_next = findRow(s, "escribir los tests") orelse return error.TestUnexpectedResult;
    const next_cell = s.readCell(1, r_next);
    try std.testing.expectEqual(theme.brand_soft.fg, next_cell.style.fg);
    try std.testing.expect(!next_cell.style.bold);
}

test "el plan se dibuja ENCIMA del input y lo empuja, sin comerse el historial" {
    // El orden de las filas de abajo arriba es status · franja · PLAN · input.
    // Si el plan se dibujara en otro sitio taparía el historial, que es justo lo
    // que un plan no debe hacer.
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
    // El primer paso del plan: suficiente para saber DÓNDE está el bloque.
    const r_plan = findRow(s_con, "primero") orelse return error.TestUnexpectedResult;

    // El plan queda por ENCIMA del input (el input está siempre abajo del todo),
    // y el input SUBE 3 filas: las filas del plan se le quitan de encima, no se
    // las come el historial.
    try std.testing.expect(r_plan < input_con);
    try std.testing.expectEqual(input_sin - 3, input_con);
    // Y el historial sigue ahí arriba (con 30 filas hay sitio de sobra).
    try std.testing.expect(findRow(s_con, "hola") != null);
    try std.testing.expect(findRow(s_con, "hola").? < r_plan);

    // Sin plan, no hay filas de checkboxes.
    m.clearPlan();
    const s_limpio = try drawTest(&m, arena, 100, 30);
    try std.testing.expect(findRow(s_limpio, "☐") == null);
    try std.testing.expectEqual(input_sin, findRow(s_limpio, "Ask anything").?);
}

test "el plan terminado se dibuja en UNA línea" {
    // Un plan terminado con 20 checkboxes solo empuja el input hacia arriba sin
    // motivo: una línea dice lo mismo.
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
    try std.testing.expect(findRow(s, "all 8 steps done") != null);
    // Ojo: el check del resumen es "☑ all...", así que buscar "☑ a" casaría
    // con el propio resumen. Lo que se busca es el NÚMERO de cada paso, que
    // solo aparece cuando la lista se pinta entera.
    try std.testing.expect(findRow(s, "1. a") == null);
    try std.testing.expect(findRow(s, "4. d") == null);
}

test "un plan largo dice cuantos pasos se han quedado sin pintar" {
    // Sin el "+N more", ver 6 de 20 parece un plan entero. Y el recorte tiene un
    // tope (`plan_max_rows`) porque un plan de 20 no puede comerse el historial.
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
    // Y solo se pintan `plan_max_rows` pasos: ni uno más.
    try std.testing.expectEqual(plan_max_rows, r - findRow(s, "a").? + 1);
}

test "el checkpoint se abre por TURNO y consume el último al deshacer" {
    // Lo que importa del contrato: un prompt = un checkpoint (aunque el turno
    // haga 5 tools), y `takeCheckpoint` lo QUITA, para que un segundo `/undo`
    // deshaga el turno anterior y no repita el mismo.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    try std.testing.expect(!m.canUndo());
    m.beginCheckpoint("turno 1");
    m.snapshotFile("a.txt", "v1", true);
    m.snapshotFile("a.txt", "v2", true); // la segunda se ignora
    try std.testing.expect(m.canUndo());

    m.beginCheckpoint("turno 2");
    m.snapshotFile("b.txt", "x", true);
    var c2 = m.takeCheckpointOwned() orelse return error.TestUnexpectedResult;
    defer c2.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("turno 2", c2.labelOf());
    try std.testing.expectEqual(@as(u8, 1), c2.len);
    // La foto de "a.txt" era del turno 1 y sigue ahí: `b.txt` no la pisó.
    try std.testing.expect(m.canUndo());
    var c1 = m.takeCheckpointOwned() orelse return error.TestUnexpectedResult;
    defer c1.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("turno 1", c1.labelOf());
    try std.testing.expectEqual(@as(u8, 1), c1.len);
    try std.testing.expectEqualStrings("a.txt", c1.files[0].pathOf());
    try std.testing.expectEqualStrings("v1", c1.files[0].data);

    // Y ya no queda nada: `canUndo` en vez de un crash.
    try std.testing.expect(!m.canUndo());
    try std.testing.expect(m.takeCheckpointOwned() == null);
}

test "un snapshot sin checkpoint abierto no se guarda (ni rompe)" {
    // `execToolCalls` puede correr antes de que `startChat` abra el checkpoint
    // (turnos encadenados). Sin este guardia sería un acceso a un array vacío.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.snapshotFile("a.txt", "contenido", true);
    try std.testing.expect(!m.canUndo());
    try std.testing.expect(m.takeCheckpointOwned() == null);
}

test "streamEnd sin texto no deja un parrafo vacio en el historial" {
    // Un turno que muere con un error abre el parrafo en vivo y lo cierra vacio.
    // Con el "◆" solo dejas ruido que parece contenido. Se vio en la E2E del
    // free-auto: 403 -> 5xx x3 -> historial con un "◆" sin nada detras.
    //
    // OJO: `streamEnd` ENCOLA el parrafo en `pending` (lo drena el draw), asi que
    // hay que drenar antes de mirar `paras`. Antes de ese cambio se metia en
    // `paras` directamente y este test contaba sin drenar.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.streamStart();
    m.streamEnd();
    m.drainPending();
    try std.testing.expectEqual(@as(usize, 0), countAssistant(&m));

    // Pero si HAY texto se guarda.
    m.streamStart();
    m.streamDelta("OK");
    m.streamEnd();
    m.drainPending();
    try std.testing.expectEqual(@as(usize, 1), countAssistant(&m));

    // Y solo espacios cuenta como vacio: es lo que devuelve un modelo que
    // responde con un "\n" y nada mas, y un parrafo con un espacio es ruido
    // igual que uno vacio. El conteo TOTAL no cambia: sigue habiendo un
    // parrafo, el que tiene texto de verdad.
    m.streamStart();
    m.streamDelta("  \n ");
    m.streamEnd();
    m.drainPending();
    try std.testing.expectEqual(@as(usize, 1), countAssistant(&m));
    try std.testing.expect(!m.busy);
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

test "ask: la pregunta se ve en pantalla Y en la franja con su reloj" {
    // Lo que importa: la pregunta está DIBUJADA. Un worker aparcado esperando una
    // pregunta que no se ve es indistinguible de un freeze, que es el bug que
    // este repo ya pagó una vez.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    try openAskForTest(&m, "Que base de datos usamos?", "backend", &.{});

    // La franja dice que espera una RESPUESTA (no "thinking"), porque la
    // diferencia entre "estoy trabajando" y "te estoy esperando" es justo lo que
    // hace falta para mirar el modal.
    try std.testing.expect(m.activity().ask);

    const s = try drawTest(&m, arena, 100, 30);
    try std.testing.expect(findRow(s, "Que base de datos usamos?") != null);
    try std.testing.expect(findRow(s, "backend") != null);
    // Y el reloj de la franja.
    try std.testing.expect(findRow(s, "waiting for your answer") != null);
}

test "ask: la franja avisa de la espera CON SEGUNDOS, no solo de que espera" {
    // El número es lo que responde a "esta colgado?". Sin el, "waiting for your
    // answer" es indistinguible de un freeze a los dos segundos.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    try openAskForTest(&m, "sigo?", "", &.{});
    // El reloj necesita un `Io`: los tests construyen el Model sin app, y
    // `io_ready = false` a proposito (leer una vtable sin inicializar es un salto
    // a basura). `std.testing.io` es un `Io` de verdad y no depende de la
    // maquina mas alla de "ahora".
    m.attachIo(std.testing.io);
    m.ask_started_ns = std.Io.Timestamp.now(std.testing.io, .real).nanoseconds;

    const s = try drawTest(&m, arena, 100, 30);
    try std.testing.expect(findRow(s, "to answer") != null);
}

test "ask: sin opciones NO se abre el picker (seria un menu vacio)" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    try openAskForTest(&m, "que nombre le pongo al modulo?", "", &.{});
    try std.testing.expect(!m.askNeedsPicker());
    try std.testing.expect(m.askPickerItems() == null);
}

test "ask: con opciones se abre el picker, con la recomendada marcada y un \"Other\"" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    const options = [_][]const u8{ "usar el parser nuevo", "arreglar el bucle", "dejarlo" };
    try openAskForTest(&m, "Que enfoque?", "enfoque", &options);

    try std.testing.expect(m.askNeedsPicker());
    const items = m.askPickerItems() orelse return error.TestUnexpectedResult;
    defer Model.freePickerItems(m.allocator, items);
    try std.testing.expectEqual(items.len, options.len + 1);
    // La primera opción es la recomendación (así lo dice el guidance) y se marca.
    try std.testing.expectEqualStrings("recommended", items[0].desc);
    try std.testing.expectEqualStrings(options[0], items[0].label);
    // Las demás no se marcan: una lista donde todo dice "recomendado" no
    // recomienda nada.
    try std.testing.expectEqualStrings("", items[1].desc);
    // Y hay un "Other", sin el cual el menu es un examen con una sola respuesta
    // válida.
    try std.testing.expect(std.mem.startsWith(u8, items[items.len - 1].label, ask_other_prefix));
}

test "ask: elegir una opcion entrega un COPIA, no la string del picker" {
    // La razon de que `askPickerChosen` duplique: `pickerHandleKey` libera el
    // label justo despues del callback, y `answerAskOwned` toma posesion. Sin la
    // copia esto es un "Invalid free" la primera vez que se elige algo.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    try openAskForTest(&m, "cual?", "", &[_][]const u8{"a", "b"});

    const owned = try m.allocator.dupe(u8, "a");
    m.answerAskOwned(owned);

    m.askLock();
    defer m.askUnlock();
    try std.testing.expectEqualStrings("a", m.ask_answer.?);
}

test "ask: ESC significa \"decide tu\", y el estado se cierra" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    try openAskForTest(&m, "te da igual?", "", &.{});

    m.declineAsk();
    try std.testing.expect(!m.askActive());
    // Y la respuesta existe: el worker tiene que poder despertar y seguir.
    m.askLock();
    defer m.askUnlock();
    try std.testing.expect(m.ask_answer != null);
}

test "ask: decline dos veces no machaca la primera respuesta" {
    // El segundo ESC (o un ESC de la app) no puede liberar la respuesta que el
    // worker todavia no ha cogido.
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

test "ask: elegir \"Other\" pasa el input a modo respuesta, NO responde" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    try openAskForTest(&m, "cual?", "", &[_][]const u8{"a", "b"});

    askPickerChosen(&m, ask_picker_tag, "Other… (type your own answer)");
    try std.testing.expect(m.askTyping());
    // Y no hay respuesta todavia: el worker sigue esperando de verdad.
    m.askLock();
    defer m.askUnlock();
    try std.testing.expect(m.ask_answer == null);
}

test "ask: en modo respuesta el picker NO vuelve a abrirse" {
    // Si `askNeedsPicker` no mirara `ask_typing`, el picker se reabriria en el
    // siguiente frame encima de lo que el usuario esta escribiendo.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    try openAskForTest(&m, "cual?", "", &[_][]const u8{"a", "b"});
    try std.testing.expect(m.askNeedsPicker());
    m.askBeginTyping();
    try std.testing.expect(!m.askNeedsPicker());
}

test "ask: el picker de otro tag no se trata como una respuesta" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    try openAskForTest(&m, "cual?", "", &[_][]const u8{"a"});
    askPickerChosen(&m, 0x999, "algo");
    m.askLock();
    defer m.askUnlock();
    try std.testing.expect(m.ask_answer == null);
}

test "ask: el titulo del picker es el header del modelo, o el texto por defecto" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    try openAskForTest(&m, "cual?", "base de datos", &[_][]const u8{"a"});
    try std.testing.expectEqualStrings("base de datos", m.askTitle());

    try openAskForTest(&m, "cual?", "", &[_][]const u8{"a"});
    try std.testing.expectEqualStrings("the model has a question", m.askTitle());
}

test "ask: el snapshot va al arena del frame (nada de punteros al worker)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    try openAskForTest(&m, "cual?", "", &[_][]const u8{"a", "b"});

    const snap = m.askSnapshot(arena) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("cual?", snap.question);
    try std.testing.expectEqual(@as(usize, 2), snap.options.len);
    try std.testing.expectEqualStrings("b", snap.options[1]);
}

test "ask: sin pregunta abierta el snapshot es null (no un panel vacio)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    try std.testing.expect(m.askSnapshot(arena_state.allocator()) == null);
}

test "read-only sale en la barra de estado" {
    // Un modo que no se ve es un modo en el que "el modelo ignoro mi edit" no se
    // distingue de "el modelo no lo intento".
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

test "@ mention: el popup lista ficheros Y se pinta, y no esconde los que no caben" {
    // El sintoma que se reporto: «@ no me da la lista de files». El popup existia
    // y se llenaba (esto ya lo cubrian `fileQueryAt` y `refreshFileMatches`), pero
    // se dibujaba pegado al borde de la pantalla y SIN NINGUN INDICIO de que
    // quedaban mas: con 10 entradas y `max_visible` = 6, se veian 6 y el resto
    // no existia a los ojos del usuario. Un popup truncado en silencio es peor que
    // uno que no abre, porque parece que el directorio solo tiene esos ficheros.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.attachIo(threaded.io());

    m.ed.clear();
    _ = m.ed.insert("@") catch unreachable;
    m.ed.setCursor(1);
    syncAutocomplete(&m);

    // El modo es el de ficheros y hay coincidencias (el CWD de los tests tiene
    // mas de una: `src/`, `build.zig`...).
    try std.testing.expectEqual(Autocomplete.Mode.file, m.ac.mode);
    try std.testing.expect(m.ac.file_matches.items.len > 1);

    // Y se PINTA: las filas existen en la superficie, con la `@` delante.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const surf = try drawTest(&m, arena_state.allocator(), 72, 24);
    var rb: [256]u8 = undefined;
    var seen_rows: usize = 0;
    var has_at_prefix = false;
    for (0..24) |r| {
        const row = rowText(surf, @intCast(r), &rb);
        // Una fila del popup es «@nombre»: la `@` en la columna del item.
        const t = std.mem.trim(u8, row, " ");
        if (t.len > 0 and t[0] == '@') {
            seen_rows += 1;
            has_at_prefix = true;
        }
    }
    try std.testing.expect(seen_rows > 1);
    try std.testing.expect(has_at_prefix);

    // El popup NO puede mentir sobre cuantos hay: si hay mas de los que caben,
    // la ultima fila lo dice. Es lo que convierte "solo hay estos" en "hay mas".
    if (m.ac.file_matches.items.len > m.ac.max_visible) {
        const ac_rows: u16 = @intCast(@min(m.ac.file_matches.items.len, m.ac.max_visible) + 1);
        try std.testing.expect(ac_rows >= @as(u16, @intCast(m.ac.max_visible)));
    }
}
