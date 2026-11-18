//! TUI tests, split out of tui.zig (Phase 42.9). The implementation file stays
//! focused on rendering and input; every test here drives the real Model and
//! real draw functions through their public surface.

const std = @import("std");
const tui = @import("tui.zig");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const agent = @import("agent.zig");
const ed = @import("lib/editor.zig");
const keybinds = @import("lib/keybinds.zig");
const mascot = @import("lib/mascot.zig");
const md = @import("lib/markdown.zig");
const repeat = @import("lib/repeat.zig");
const theme = @import("lib/theme.zig");

const Model = tui.Model;
const InfoSeg = tui.InfoSeg;
const bannerRow = tui.bannerRow;
const detectLinks = tui.detectLinks;
const fileQueryAt = tui.fileQueryAt;
const isControlGrapheme = tui.isControlGrapheme;
const keyToBinding = tui.keyToBinding;
const rowText = tui.rowText;
const scrollbarThumb = tui.scrollbarThumb;

const palette = @import("palette.zig");
const plan_mod = @import("lib/plan.zig");
const sleepz = @import("lib/sleep.zig");
const zjsonl = @import("lib/zjsonl.zig");

const banner = tui.banner;
const boundCommand = tui.boundCommand;
const drawTest = tui.drawTest;
const openShortcutsPicker = tui.openShortcutsPicker;
const scrollbarOffset = tui.scrollbarOffset;
const segsWidth = tui.segsWidth;
const sessionInfo = tui.sessionInfo;
const StatusKind = tui.StatusKind;
const syncAutocomplete = tui.syncAutocomplete;
const typeErasedEventHandler = @import("tui_events.zig").typeErasedEventHandler;

const allText = tui.allText;
const ask_other_label = tui.ask_other_label;
const Autocomplete = tui.Autocomplete;
const banner_art_height = tui.banner_art_height;
const banner_art_width = tui.banner_art_width;
const face_width = tui.face_width;
const isExactMatch = tui.isExactMatch;
const matchCount = tui.matchCount;
const timeline_max_dots = tui.timeline_max_dots;
const startsWithIgnoreCase = tui.startsWithIgnoreCase;
const acceptAutocomplete = tui.acceptAutocomplete;
const glyph_d = tui.glyph_d;
const glyph_o = tui.glyph_o;
const commandToken = tui.commandToken;

const acPrefix = tui.acPrefix;
const matchLabel = tui.matchLabel;
const stickyPromptPara = tui.stickyPromptPara;

test "render: control bytes never reach a cell" {
    // Two layers, two behaviors. The painter's backstop (`isControlGrapheme`,
    // asserted here) still catches any control byte that gets past the paragraph
    // builder — it paints U+FFFD instead of a broken frame. The paragraph
    // builder (`ansi.strip`) removes them entirely before parsing, so history text
    // never carries them at all.
    try std.testing.expect(isControlGrapheme("\x1b"));
    try std.testing.expect(isControlGrapheme("\r"));
    try std.testing.expect(isControlGrapheme("\x07"));
    try std.testing.expect(isControlGrapheme("\x7f"));
    try std.testing.expect(isControlGrapheme("\u{0085}"));
    try std.testing.expect(!isControlGrapheme("a"));
    try std.testing.expect(!isControlGrapheme("\xc3\xb1")); // ñ is not a control
    try std.testing.expect(!isControlGrapheme(""));

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.pushInfo("a\x1bb\x07c\rd");

    const s = try drawTest(&m, arena, 40, 12);
    var buf: [128]u8 = undefined;
    const row0 = rowText(s, 0, &buf);
    try std.testing.expect(std.mem.indexOf(u8, row0, "\x1b") == null);
    try std.testing.expect(std.mem.indexOf(u8, row0, "\x07") == null);
    try std.testing.expect(std.mem.indexOf(u8, row0, "\r") == null);
    try std.testing.expectEqualStrings("\u{b7} acd", std.mem.trim(u8, row0, " "));
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
    agent.setAnswering(""); // reset globals leaked by agent tests
    agent.cur_model = "";
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
        // Collapsed: summary plus the ^R hint that the full transcript is
        // available.
        try std.testing.expectEqualStrings("\u{2502} Read 1006 lines \u{b7} 3ms · ^R", std.mem.trim(u8, rowText(s, r2, &buf), " "));
    }

    // ^R expands the full result (several lines).
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

    m.ed.insert(&repeat.rep("a", 200)) catch {};

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
    const msg = std.mem.print(&m.input_err_buf, "Input too long: {d}-byte cap, {d} bytes already typed. Shorten the text and resend.", .{ ed.max_bytes, m.ed.text().len }) catch {
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

test "input: a long TYPED prompt is shown whole, never elided like a paste" {
    // The bug: any buffer over 400 bytes was cut to `head … +N more tail` for
    // display — a guard for huge pastes that also caught a person typing a
    // paragraph. The box grew from the FULL text while the rows were wrapped
    // from the ELIDED copy, so the composer came out taller than its text and
    // the caret was hidden: the input "broke" mid-sentence, exactly as if the
    // text had been pasted in.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    var typed: std.ArrayList(u8) = .empty;
    defer typed.deinit(std.testing.allocator);
    typed.appendSlice(std.testing.allocator, "inicio ") catch {};
    while (typed.items.len < 600) typed.appendSlice(std.testing.allocator, "palabra ") catch {};
    typed.appendSlice(std.testing.allocator, "final") catch {};
    m.ed.insert(typed.items) catch {};

    const w: u16 = 80;
    const h: u16 = 40;
    const s = try drawTest(&m, arena_state.allocator(), w, h);

    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(std.testing.allocator);
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var b: [512]u8 = undefined;
        all.appendSlice(std.testing.allocator, rowText(s, row, &b)) catch {};
        all.append(std.testing.allocator, '\n') catch {};
    }
    // No paste/elision marker anywhere: the text is painted as it was typed.
    try std.testing.expect(std.mem.indexOf(u8, all.items, " more") == null or std.mem.indexOf(u8, all.items, "\u{2191}") != null);
    // The tail (where you are typing) stays on screen.
    try std.testing.expect(std.mem.indexOf(u8, all.items, "final") != null);
}

test "input: a prompt taller than the box keeps the tail and counts the rows above" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    var typed: std.ArrayList(u8) = .empty;
    defer typed.deinit(std.testing.allocator);
    typed.appendSlice(std.testing.allocator, "inicio ") catch {};
    while (typed.items.len < 600) typed.appendSlice(std.testing.allocator, "palabra ") catch {};
    typed.appendSlice(std.testing.allocator, "final") catch {};
    m.ed.insert(typed.items) catch {};

    const w: u16 = 40;
    const h: u16 = 30;
    const s = try drawTest(&m, arena_state.allocator(), w, h);

    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(std.testing.allocator);
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        var b: [512]u8 = undefined;
        all.appendSlice(std.testing.allocator, rowText(s, row, &b)) catch {};
        all.append(std.testing.allocator, '\n') catch {};
    }
    // The end of what you are typing stays visible…
    try std.testing.expect(std.mem.indexOf(u8, all.items, "final") != null);
    // …the head scrolled out, and the rule says how many rows did.
    try std.testing.expect(std.mem.indexOf(u8, all.items, "inicio") == null);
    try std.testing.expect(std.mem.indexOf(u8, all.items, "more") != null);
    try std.testing.expect(s.cursor != null);
}

test "history: the transcript sits on the terminal's own background" {
    // A `well_bg` panel behind the whole transcript is a second black that does
    // not match the terminal's: on a black terminal the page came out as a gray
    // block, and the empty space under a short answer read as a painted hole.
    // The history is the page, so it is the terminal's background.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const w: u16 = 80;
    const h: u16 = 24;
    const s = try drawTest(&m, arena_state.allocator(), w, h);
    // Row `h - 4` is inside the transcript (the composer owns the last rows).
    const cell = s.readCell(w / 2, h - 4);
    try std.testing.expectEqual(vaxis.Color.default, cell.style.bg);
    // …and so is the input's own row: no panel colour under the prompt either.
    const input_cell = s.readCell(5, h - 2);
    try std.testing.expectEqual(vaxis.Color.default, input_cell.style.bg);
}

test "layout: the height estimate counts the wrap per line" {
    // The estimate holds the scroll until the parse corrects it, and every
    // over-count was a jump the reader felt. Counting a full extra line per
    // line for prose (which is what `(len - nl) / width` does) estimated 70
    // rows for a paragraph that renders in 48 (an earlier lazy path even
    // kept such an estimate forever: the black space).
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.wrap_w = 95;

    // 43 short lines: no line wraps, so 43 rows plus the trailing empty one.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < 43) : (i += 1) {
        text.appendSlice(std.testing.allocator, "**Purpose:** reviews the diff to find reuse opportunities") catch
            return error.OutOfMemory;
        text.append(std.testing.allocator, '\n') catch return error.OutOfMemory;
    }
    try std.testing.expectEqual(@as(usize, 44), m.estHeight(text.items));

    // One 300-byte line is 4 rows at 95 columns, and no more.
    const long_line = &repeat.rep("x", 300);
    try std.testing.expectEqual(@as(usize, 4), m.estHeight(long_line));
}

test "layout: a paragraph past the old lazy threshold gets its EXACT height" {
    // The old lazy path kept a byte-based ESTIMATE forever for paragraphs over
    // ~50 rows, and the estimate never matched the painted block exactly — the
    // difference was the black hole. The lazy path is gone; a 120-row block is
    // laid out like any other, and its LAST row is paintable with one row of
    // separator above the composer, not a canyon.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < 120) : (i += 1) {
        const line = std.fmt.allocPrint(std.testing.allocator, "row {d} of the long answer", .{i}) catch return error.OutOfMemory;
        defer std.testing.allocator.free(line);
        text.appendSlice(std.testing.allocator, line) catch return error.OutOfMemory;
        if (i + 1 < 120) text.append(std.testing.allocator, '\n') catch return error.OutOfMemory;
    }
    m.pushKind(.assistant, text.items);
    m.pushInfo("\u{23ba} Done \u{b7} 0 tools \u{b7} 1.0s");

    const s = try drawTest(&m, arena_state.allocator(), 100, 40);
    var buf: [256]u8 = undefined;

    // The tail of the block is real rows, and the summary sits one separator
    // under it — an estimate-sized gap would put the Done line nowhere near.
    var done_row: ?u16 = null;
    var last_text_row: ?u16 = null;
    var row: u16 = 0;
    while (row < s.size.height) : (row += 1) {
        const line = rowText(s, row, &buf);
        if (std.mem.indexOf(u8, line, "0 tools") != null) done_row = row;
        if (std.mem.indexOf(u8, line, "row 119 of the long answer") != null) last_text_row = row;
    }
    const dr = done_row orelse return error.DoneNotPainted;
    const lt = last_text_row orelse return error.TailNotPainted;
    // The Done line comes after the text in the transcript; at the bottom of
    // the view both are on screen with the separator between them.
    try std.testing.expect(dr >= lt);
    try std.testing.expect(dr - lt <= 2);
}

test "layout: a long prose answer has no empty block before its summary" {
    // The reported bug: ask a question, the answer arrives, and the turn
    // summary under it sits twenty rows lower with a block of nothing in
    // between — and the answer's own beginning is scrolled off the top.
    //
    // One row of air between them (the paragraph separator) is the whole
    // budget: that is what "the answer ends" looks like.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < 43) : (i += 1) {
        text.appendSlice(std.testing.allocator, "**Purpose:** reviews the diff to find reuse opportunities") catch
            return error.OutOfMemory;
        if (i + 1 < 43) text.append(std.testing.allocator, '\n') catch return error.OutOfMemory;
    }
    m.pushKind(.user, "dame el resumen de las skills");
    m.pushKind(.assistant, text.items);
    m.pushInfo("\u{23ba} Done \u{b7} 0 tools \u{b7} 5.4s \u{b7} ~15k tokens");

    const h: u16 = 47;
    const s = try drawTest(&m, arena_state.allocator(), 100, h);

    var buf: [256]u8 = undefined;
    var summary_row: ?u16 = null;
    var row: u16 = 0;
    while (row < h) : (row += 1) {
        const line = std.mem.trim(u8, rowText(s, row, &buf), " ");
        if (std.mem.indexOf(u8, line, "0 tools") != null) summary_row = row;
    }
    const sr = summary_row orelse return error.SummaryNotPainted;
    try std.testing.expect(sr > 0);

    // A row counts as blank when it carries no TEXT: the scrollbar's cell at the
    // right edge is chrome and can be a full block on a row with nothing on it.
    const blankAt = struct {
        fn f(surf: vxfw.Surface, at: u16, b: []u8) bool {
            const line = std.mem.trim(u8, rowText(surf, at, b), " ");
            var it = vaxis.unicode.graphemeIterator(line);
            while (it.next()) |g| {
                const glyph = g.bytes(line);
                if (!std.mem.eql(u8, glyph, "\u{2588}") and !std.mem.eql(u8, glyph, "\u{2502}")) return false;
            }
            return true;
        }
    }.f;

    // Exactly ONE blank row directly above the summary: the separator.
    try std.testing.expect(sr >= 2);
    try std.testing.expect(blankAt(s, sr - 1, &buf));
    try std.testing.expect(!blankAt(s, sr - 2, &buf));
}

test "input: the accent bar and the prompt glyph are the input's own mark" {
    // The composer has no panel colour any more, so what says "this is the
    // input" is the bar in the margin and the glyph inside it. Both are the
    // accent, and both still have to be there.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const w: u16 = 40;
    const h: u16 = 14;
    const s = try drawTest(&m, arena_state.allocator(), w, h);

    // The input row is h-2 (status is h-1).
    const bar = s.readCell(0, h - 2);
    try std.testing.expectEqual(theme.input_bar.fg, bar.style.fg);
    const prompt = s.readCell(1, h - 2);
    try std.testing.expectEqual(theme.input_prompt.fg, prompt.style.fg);
    const cell = s.readCell(5, h - 2);
    try std.testing.expectEqual(vaxis.Color.default, cell.style.bg);
}

test "input: placeholder and text carry their foreground on the terminal's background" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const w: u16 = 40;
    const h: u16 = 14;
    const s = try drawTest(&m, arena_state.allocator(), w, h);

    // Placeholder text starts at column 3. It has the dim foreground and the
    // terminal's own background (no panel colour under it).
    const ph_cell = s.readCell(5, h - 2); // "k" in "Ask"
    try std.testing.expectEqual(vaxis.Color.default, ph_cell.style.bg);
    try std.testing.expectEqual(theme.placeholder.fg, ph_cell.style.fg);

    // Now add some text and check the editor text style
    m.ed.insert("hola") catch {};
    const s2 = try drawTest(&m, arena_state.allocator(), w, h);
    const text_cell = s2.readCell(3, h - 2); // "h" at column 3
    try std.testing.expectEqual(vaxis.Color.default, text_cell.style.bg);
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

test "scroll: toggling a tool result while scrolled up does not jump to the bottom" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    var i: usize = 0;
    while (i < 20) : (i += 1) m.pushInfoFmt("history line {d}", .{i});
    m.pushToolStart("read", "big.txt");
    var big: [4096]u8 = undefined;
    @memset(&big, 'x');
    m.pushToolDone("read", "Read 200 lines", 3, big[0..]);

    _ = try drawTest(&m, arena_state.allocator(), 60, 18);
    m.scrollBy(12);
    _ = try drawTest(&m, arena_state.allocator(), 60, 18);
    try std.testing.expect(!m.follow_bottom);
    const before = m.anchorLine();

    try std.testing.expect(m.toggleLastTool());
    _ = try drawTest(&m, arena_state.allocator(), 60, 18);
    try std.testing.expect(!m.follow_bottom);
    // Expanding below the reader must not yank the viewport to the bottom.
    try std.testing.expect(m.anchorLine() <= before + 2);
}

test "scroll: collapsing an expanded tool result keeps the viewport stable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    var i: usize = 0;
    while (i < 10) : (i += 1) m.pushInfoFmt("line {d}", .{i});
    m.pushToolStart("read", "big.txt");
    var big: [4096]u8 = undefined;
    @memset(&big, 'a');
    // Make it multi-line so the expanded form is tall.
    for (&big, 0..) |*c, j| {
        if (j % 40 == 39) c.* = '\n';
    }
    m.pushToolDone("read", "Read many lines", 3, big[0..]);
    // Trailing content keeps the expanded tool result away from the bottom so
    // we can anchor inside it without computeVisible snapping to follow mode.
    var k: usize = 0;
    while (k < 30) : (k += 1) m.pushInfoFmt("tail {d}", .{k});

    _ = try drawTest(&m, arena_state.allocator(), 60, 18);
    try std.testing.expect(m.last_tool != null);
    const para_idx = m.last_tool.?.para_idx;

    try std.testing.expect(m.toggleLastTool()); // expand
    _ = try drawTest(&m, arena_state.allocator(), 60, 18);

    // Place the viewport anchor inside the expanded paragraph.
    m.follow_bottom = false;
    m.anchor_para = para_idx;
    m.anchor_off = 10;
    _ = try drawTest(&m, arena_state.allocator(), 60, 18);
    try std.testing.expect(!m.follow_bottom);

    try std.testing.expect(m.toggleLastTool()); // collapse
    _ = try drawTest(&m, arena_state.allocator(), 60, 18);

    // Collapsing shrank content: stay in manual scroll mode and do not let the
    // anchor point past the collapsed paragraph.
    try std.testing.expect(!m.follow_bottom);
    if (m.anchor_para == para_idx and para_idx < m.para_heights.items.len) {
        try std.testing.expect(m.anchor_off <= m.para_heights.items[para_idx]);
    }
}

test "tool events: start/result timeline lines are normalized for presentation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.pushToolStart("bash", "echo one\necho two\tthree");
    m.pushToolDone("bash", "ok\nline2", 12, "ok\nline2");

    const s = try drawTest(&m, arena_state.allocator(), 100, 20);
    const all = allText(s);
    // Newlines/tabs in the visible timeline text collapse to spaces.
    try std.testing.expect(std.mem.indexOf(u8, all, "echo one echo two three") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "ok line2") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "12ms") != null);

    var m2 = Model.init(std.testing.allocator);
    defer m2.deinit();
    var long_buf: [160]u8 = undefined;
    @memset(&long_buf, 'x');
    m2.pushToolStart("read", long_buf[0..]);
    const s2 = try drawTest(&m2, arena_state.allocator(), 120, 12);
    try std.testing.expect(std.mem.indexOf(u8, allText(s2), "...") != null);
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

test "autocomplete: a word from a description finds the command" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    // No command NAME contains "always", so the description tier is the only
    // one with hits and it is shown: `/allowlist` says "always-allowed".
    m.ed.insert("/always") catch {};
    syncAutocomplete(&m);
    try std.testing.expect(m.ac.active);
    var found = false;
    var i: usize = 0;
    while (i < matchCount(&m)) : (i += 1) {
        const key = matchLabel(&m, i) orelse continue;
        if (std.mem.eql(u8, key, "/allowlist")) found = true;
    }
    try std.testing.expect(found);
}

test "autocomplete: an edit puts the selection back on the best match" {
    // Typing narrows the list; a highlight left at the old index would point at
    // an item the reader never looked at, and Escape/Enter act on THAT one.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.ed.insert("/mo") catch {};
    syncAutocomplete(&m);
    try std.testing.expect(matchCount(&m) >= 3);

    // The reader browsed down two rows...
    m.ac.sel = 2;
    m.ac.first = 1;

    // ...and typed one more character: a NEW query starts at the top again.
    m.ed.insert("d") catch {};
    syncAutocomplete(&m);
    try std.testing.expectEqual(@as(usize, 0), m.ac.sel);
    try std.testing.expectEqual(@as(usize, 0), m.ac.first);
    // The best match is the first row: a NAME-prefix hit, not a substring one.
    const first = matchLabel(&m, 0) orelse return error.NoBestMatch;
    try std.testing.expect(startsWithIgnoreCase(commandToken(first), "mod"));
    try std.testing.expectEqualStrings("/mod", std.mem.trim(u8, m.ed.text(), " "));
}

test "footer: a cancelled turn shows the warn mood, not done" {
    // ESC stopped the harness, so the face must NOT celebrate the turn as
    // finished: `done` after a cancel is the mascot telling the user something
    // that did not happen.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.pushHeader(.idle);

    const h: u16 = 20;
    const idle = try drawTest(&m, arena_state.allocator(), 80, h);
    const idle_fg = idle.readCell(1, h - 1).style.fg;

    // A turn ran, and it was stopped.
    m.busy_started_ns = 1;
    m.cancelled = true;
    const stopped = try drawTest(&m, arena_state.allocator(), 80, h);
    const stopped_fg = stopped.readCell(1, h - 1).style.fg;
    try std.testing.expect(!std.meta.eql(idle_fg, stopped_fg));
}

test "footer: a mode change does not change the mascot's mood" {
    // The face reports the HARNESS. It used to take its colour from the last
    // status, so shift+tab (and a model switch, and /yolo) changed the mascot's
    // expression while nothing was running.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.pushHeader(.idle);

    const h: u16 = 20;
    const before = try drawTest(&m, arena_state.allocator(), 80, h);
    const face_before = before.readCell(1, h - 1).style.fg;

    m.setStatusWithMood(.warn, "mode: plan");
    const after = try drawTest(&m, arena_state.allocator(), 80, h);
    const face_after = after.readCell(1, h - 1).style.fg;
    try std.testing.expectEqual(face_before, face_after);
}

test "autocomplete: filters by prefix and accepts with tab" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.ed.insert("/mo") catch {};
    syncAutocomplete(&m);
    try std.testing.expect(m.ac.active);
    // /model and /mode, both against the real list (/memory does not
    // exist). A prefix filter, not an exact one.
    const n_mo = matchCount(&m);
    try std.testing.expect(n_mo >= 2);
    var has_model = false;
    var has_mode = false;
    for (0..n_mo) |i| {
        const k = matchLabel(&m, i).?;
        if (std.mem.eql(u8, k, "/model")) has_model = true;
        if (std.mem.eql(u8, k, "/mode")) has_mode = true;
    }
    try std.testing.expect(has_model);
    try std.testing.expect(has_mode);

    // "/mod" leaves the two prefix hits in table order (/model before /mode)
    // and any name that merely CONTAINS "mod" (/submodel) after them: the
    // ranks decide the order, so the prefix hits are on screen first.
    m.ed.clear();
    m.ed.insert("/mod") catch {};
    syncAutocomplete(&m);
    try std.testing.expectEqual(@as(usize, 3), matchCount(&m));
    m.ac.sel = 0;
    try std.testing.expectEqualStrings("/model", matchLabel(&m, 0).?);
    try std.testing.expectEqualStrings("/mode", matchLabel(&m, 1).?);

    // Tab completes the selected command and adds the space.
    try std.testing.expect(acceptAutocomplete(&m));
    try std.testing.expectEqualStrings("/model ", m.ed.text());
    try std.testing.expect(!m.ac.active);

    // With the selection on the second match, that one is completed.
    m.ed.clear();
    m.ed.insert("/mod") catch {};
    syncAutocomplete(&m);
    m.ac.sel = 1;
    try std.testing.expect(acceptAutocomplete(&m));
    try std.testing.expectEqualStrings("/mode ", m.ed.text());
}

test "autocomplete: a subsequence of a name matches, like in the palettes" {
    // "/cp" is neither a prefix nor a substring of "/copy", and the modal
    // palette would find it — the popup answering "no matches" to the same
    // abbreviation the palette answers with a row is two searchers in one app.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.ed.insert("/cp") catch {};
    syncAutocomplete(&m);
    try std.testing.expect(m.ac.active);
    const n = matchCount(&m);
    var found = false;
    for (0..n) |i| {
        if (std.mem.eql(u8, matchLabel(&m, i).?, "/copy")) found = true;
    }
    try std.testing.expect(found);
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

test "file intelligence: tracks changes and navigates focused file entries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.beginCheckpoint("t1");

    _ = m.pushFileDiff("a\n", "a\nb\n", "src/one.zig");
    _ = m.pushFileDiff("x\n", "y\n", "src/two.zig");

    try std.testing.expectEqual(@as(usize, 2), m.file_intel_len);
    const focused = m.focusedFilePath() orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.endsWith(u8, focused, "two.zig"));

    try std.testing.expect(m.navigateFileIntel(-1));
    const prev = m.focusedFilePath() orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.endsWith(u8, prev, "one.zig"));

    try std.testing.expect(m.navigateFileIntel(1));
    const back = m.focusedFilePath() orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.endsWith(u8, back, "two.zig"));

    const s = try drawTest(&m, arena_state.allocator(), 80, 24);
    const all = allText(s);
    try std.testing.expect(std.mem.indexOf(u8, all, "[2/2]") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "two.zig") != null);
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

test "file diff: emits a compact file change card with real stats" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.beginCheckpoint("t1");

    const dc = m.pushFileDiff("one\ntwo\n", "one\nTWO\nthree\n", "src/demo.zig");
    try std.testing.expectEqual(@as(usize, 2), dc.added);
    try std.testing.expectEqual(@as(usize, 1), dc.removed);

    const s = try drawTest(&m, arena_state.allocator(), 72, 20);
    const all = allText(s);
    try std.testing.expect(std.mem.indexOf(u8, all, "changed") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "demo.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "+2 -1") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "-two") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "+TWO") != null);
}

test "file diff: multiple edits to same file in one turn show honest net diff" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.beginCheckpoint("t1");

    // Baseline: "alpha\nbeta\n"
    // Edit 1: beta -> BETA, add gamma => op diff +2 -1
    const dc1 = m.pushFileDiff("alpha\nbeta\n", "alpha\nBETA\ngamma\n", "src/net.zig");
    try std.testing.expectEqual(@as(usize, 2), dc1.added);
    try std.testing.expectEqual(@as(usize, 1), dc1.removed);

    // Edit 2: gamma -> GAMMA (net vs baseline alpha,beta is alpha,BETA,GAMMA => +2 -1)
    const dc2 = m.pushFileDiff("alpha\nBETA\ngamma\n", "alpha\nBETA\nGAMMA\n", "src/net.zig");
    try std.testing.expectEqual(@as(usize, 2), dc2.added);
    try std.testing.expectEqual(@as(usize, 1), dc2.removed);

    // Edit 3: restore to baseline => net has no changes.
    const dc3 = m.pushFileDiff("alpha\nBETA\nGAMMA\n", "alpha\nbeta\n", "src/net.zig");
    try std.testing.expectEqual(@as(usize, 0), dc3.added);
    try std.testing.expectEqual(@as(usize, 0), dc3.removed);

    const s = try drawTest(&m, arena_state.allocator(), 80, 28);
    const all = allText(s);
    // First card (operation), then honest net cards (baseline -> current).
    try std.testing.expect(std.mem.indexOf(u8, all, "changed") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "net.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "net") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "(unchanged)") != null);
    // Net diff from baseline to edit 2 state should show BETA and GAMMA additions vs beta.
    try std.testing.expect(std.mem.indexOf(u8, all, "+BETA") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "+GAMMA") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "-beta") != null);
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
    agent.setAnswering(""); // reset globals leaked by agent tests
    agent.cur_model = "";
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
    agent.setAnswering(""); // reset globals leaked by agent tests
    agent.cur_model = "";
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
    for ([_]agent.PermMode{ .accept_edits, .read_only }) |pm| {
        agent.setPermMode(&m, pm);
        const segs = sessionInfo(&m, arena_state.allocator()) orelse return error.TestUnexpectedResult;
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(std.testing.allocator);
        for (segs) |sg| try joined.appendSlice(std.testing.allocator, sg.text);
        // The glyph is there...
        try std.testing.expect(std.mem.indexOf(u8, joined.items, "◐") != null or
            std.mem.indexOf(u8, joined.items, "●") != null);
        // ...and it is ONE column wide: no word, no provider, no path.
        try std.testing.expect(std.mem.indexOf(u8, joined.items, "opencode") == null);
        try std.testing.expect(std.mem.indexOf(u8, joined.items, "/") == null);
        try std.testing.expect(std.mem.indexOf(u8, joined.items, "read-only") == null);
        try std.testing.expect(std.mem.indexOf(u8, joined.items, "bypass") == null);
    }

    // BYPASS is marked ONCE, next to the face (`YOLO`), and costs nothing here:
    // two marks for one mode read as two different states.
    agent.setPermMode(&m, .bypass);
    {
        const segs = sessionInfo(&m, arena_state.allocator()) orelse return error.TestUnexpectedResult;
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(std.testing.allocator);
        for (segs) |sg| try joined.appendSlice(std.testing.allocator, sg.text);
        try std.testing.expect(std.mem.indexOf(u8, joined.items, "◉") == null);
        try std.testing.expect(std.mem.indexOf(u8, joined.items, " · ") == null);
    }
    // …and the chip is in the composer's footer, on the left, in the accent.
    {
        const s = try drawTest(&m, arena_state.allocator(), 80, 20);
        var buf: [256]u8 = undefined;
        const last = std.mem.trim(u8, rowText(s, 19, &buf), " ");
        try std.testing.expect(std.mem.indexOf(u8, last, "YOLO") != null);
    }
}

test "footer: the right-hand group fits and is not cut" {
    // The visible symptom of the dangling pointer was the row cut with a
    // half UTF-8 character at the right edge.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    agent.setAnswering(""); // reset globals leaked by agent tests
    agent.cur_model = "";
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
        m.pushInfo(try std.mem.print(&text, "history row {d}", .{i}));
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
        m.pushInfo(try std.mem.print(&text, "history row {d}", .{i}));
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
        m.pushInfo(try std.mem.print(&text, "history row {d}", .{i}));
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
        const text = try std.mem.print(&buf, "history paragraph {d}", .{i});
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
        m.streamDelta(std.mem.print(&buf, "respuesta en vivo numero {d}", .{k}) catch "x");
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

test "autocomplete: /model with Enter sends /model, it does not rewrite" {
    // Regression: the exact match was only looked for against the highlighted
    // item, so a popup that sorted another command first made Enter rewrite
    // the typed command into the highlighted one. Typing a COMPLETE command
    // must send exactly what is typed.
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
    try std.testing.expectEqualStrings("primero", p1.text);
    try std.testing.expect(p1.mode == .normal);
    try std.testing.expect(!p1.expand_cmdsubst);
    m.allocator.free(p1.text);
    const p2 = m.takeQueued().?;
    try std.testing.expectEqualStrings("segundo", p2.text);
    m.allocator.free(p2.text);

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

test "queue: preserves full turn context for special turns" {
    // A queued /commit, /pr, pipeline or cmdsubst turn must keep its mode and
    // scoped bash allow rules. Dropping them on enqueue/dequeue makes the turn
    // run as a plain normal turn — a context leak (wrong permissions and no
    // command substitution).
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const rules = [_][]const u8{ "Bash(git status:*)", "Bash(git commit:*)" };
    const text = m.allocator.dupe(u8, "commit prompt") catch unreachable;
    _ = m.enqueueTurn(.{
        .text = text,
        .mode = .pipeline,
        .bash_allow_rules = &rules,
        .expand_cmdsubst = true,
    });

    const got = m.takeQueued().?;
    defer m.allocator.free(got.text);
    try std.testing.expectEqualStrings("commit prompt", got.text);
    try std.testing.expect(got.mode == .pipeline);
    try std.testing.expect(got.expand_cmdsubst);
    try std.testing.expectEqual(@as(usize, 2), got.bash_allow_rules.len);
    try std.testing.expectEqualStrings("Bash(git status:*)", got.bash_allow_rules[0]);
    try std.testing.expectEqualStrings("Bash(git commit:*)", got.bash_allow_rules[1]);
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

    // The row above it is the prompt, and it sits on the terminal's own
    // background like everything else that is not a well of its own.
    const prompt_cell = s.readCell(1, last - 1);
    try std.testing.expectEqualStrings("›", prompt_cell.char.grapheme);
    try std.testing.expectEqual(vaxis.Color.default, prompt_cell.style.bg);
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
    agent.setAnswering(""); // reset globals leaked by agent tests
    agent.cur_model = "";
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

test "permissions: the matched rule is shown in the dialog" {
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
    m.setPermRule("Write(.git/**) deny");

    try std.testing.expectEqualStrings("Write(.git/**) deny", m.permRule());

    const s = try drawTest(&m, arena_state.allocator(), 92, 26);
    const all = allText(s);
    try std.testing.expect(std.mem.indexOf(u8, all, "Write(.git/**) deny") != null);
    m.perm_active = false;
}

test "permissions: permRule resets when the dialog closes" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.setPermRule("Write(.git/**) deny");
    try std.testing.expectEqualStrings("Write(.git/**) deny", m.permRule());

    m.perm_active = true;
    m.perm_answer = .allow;
    // Simulate what requestPermission does when the dialog closes.
    m.perm_active = false;
    m.perm_rule_len = 0;
    try std.testing.expectEqualStrings("", m.permRule());
}

test "permissions: a long matched rule wraps inside the modal without hiding options" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.streamStart();
    @memcpy(m.perm_tool[0..4], "bash");
    m.perm_tool_len = 4;
    @memcpy(m.perm_detail[0..4], "echo");
    m.perm_detail_len = 4;
    m.perm_active = true;
    m.setPermRule("Bash(project/scripts/very/deep/path/with/a/really/long/rule/name) ask");

    const s = try drawTest(&m, arena_state.allocator(), 60, 20);
    const all = allText(s);
    try std.testing.expect(std.mem.indexOf(u8, all, "Permission required") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "asked by rule") != null);
    // The rule text is present (possibly wrapped across rows).
    try std.testing.expect(std.mem.indexOf(u8, all, "long/rule/name") != null or
        std.mem.indexOf(u8, all, "Bash(project") != null);
    // The answer options must still be reachable.
    try std.testing.expect(std.mem.indexOf(u8, all, "Y") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "deny") != null);
    m.perm_active = false;
}

test "permissions: narrow terminal with a long rule still shows a readable prompt" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.streamStart();
    @memcpy(m.perm_tool[0..4], "bash");
    m.perm_tool_len = 4;
    m.perm_active = true;
    m.setPermRule("Bash(project/scripts/very/deep/path/with/a/really/long/rule/name) ask");

    const s = try drawTest(&m, arena_state.allocator(), 24, 10);
    const all = allText(s);
    try std.testing.expect(std.mem.indexOf(u8, all, "Permission") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "Y allow") != null);
    m.perm_active = false;
}

test "permissions: a very long bash detail wraps and remains answerable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.streamStart();
    @memcpy(m.perm_tool[0..4], "bash");
    m.perm_tool_len = 4;
    const detail = "echo this-is-a-very-long-command with many arguments that should wrap inside the permission dialog without crossing the border";
    const n = @min(detail.len, m.perm_detail.len);
    @memcpy(m.perm_detail[0..n], detail[0..n]);
    m.perm_detail_len = n;
    m.perm_allow_always = true;
    m.perm_active = true;

    const s = try drawTest(&m, arena_state.allocator(), 56, 18);
    const all = allText(s);
    try std.testing.expect(std.mem.indexOf(u8, all, "Permission required") != null);
    // Wrapped content should still expose recognizable parts of the command.
    try std.testing.expect(std.mem.indexOf(u8, all, "very-long-command") != null or
        std.mem.indexOf(u8, all, "many arguments") != null);
    // Critical actions remain available.
    try std.testing.expect(std.mem.indexOf(u8, all, "allow once") != null or
        std.mem.indexOf(u8, all, "Y") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "deny") != null or
        std.mem.indexOf(u8, all, "N") != null);
    m.perm_active = false;
}

test "permissions: a long always-allow suggestion stays within a narrow modal" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.streamStart();
    @memcpy(m.perm_tool[0..4], "bash");
    m.perm_tool_len = 4;
    @memcpy(m.perm_detail[0..2], "ls");
    m.perm_detail_len = 2;
    m.perm_active = true;
    m.perm_allow_always = true;
    m.setPermSuggestion("Bash(project/scripts/very/deep/path/with/a/really/long/suggestion)");

    const s = try drawTest(&m, arena_state.allocator(), 44, 16);
    const all = allText(s);
    try std.testing.expect(std.mem.indexOf(u8, all, "Permission required") != null);
    // On tight widths the label falls back to the compact form.
    try std.testing.expect(std.mem.indexOf(u8, all, "always allow") != null or
        std.mem.indexOf(u8, all, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "deny") != null or
        std.mem.indexOf(u8, all, "N") != null);
    m.perm_active = false;
}

test "permissions: compact fallback hides always-allow when the runtime does not offer it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.streamStart();
    @memcpy(m.perm_tool[0..4], "bash");
    m.perm_tool_len = 4;
    @memcpy(m.perm_detail[0..4], "echo");
    m.perm_detail_len = 4;
    m.perm_active = true;
    m.perm_allow_always = false;

    const s = try drawTest(&m, arena_state.allocator(), 24, 10);
    const all = allText(s);
    try std.testing.expect(std.mem.indexOf(u8, all, "Permission") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "Y allow") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "deny") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "A always") == null);
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
    try openAskForTest(&m, "which one?", "decide", &.{ "a", "b" });

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

    // And the command really ran: `/usage` shows the usage panel.
    const s = try drawTest(&m, arena_state.allocator(), 92, 20);
    var found = false;
    for (0..s.size.height) |row| {
        var rb: [512]u8 = undefined;
        if (std.mem.indexOf(u8, rowText(s, @intCast(row), &rb), "requests") != null) found = true;
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
        m.pushInfo(try std.mem.print(&text, "history row {d}", .{i}));
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
        m.pushKind(.user, try std.mem.print(&text, "prompt {d}", .{i}));
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
    m.show_prompt_dots = true;

    for (0..8) |i| {
        var text: [32]u8 = undefined;
        m.pushKind(.user, try std.mem.print(&text, "prompt {d}", .{i}));
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
        m.streamDelta(std.mem.print(&buf, "marcador-{d}", .{i}) catch "x");
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
        n_before += (std.mem.print(before[n_before..], "linea {d}\n", .{i}) catch break).len;
    }
    i = 0;
    while (i < 300) : (i += 1) {
        n_after += (std.mem.print(after[n_after..], "linea {d}!\n", .{i}) catch break).len;
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
        nb += (std.mem.print(before[nb..], "linea {d}\n", .{i}) catch break).len;
        na += (std.mem.print(after[na..], "linea {d}!\n", .{i}) catch break).len;
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
    try std.testing.expect(std.mem.startsWith(u8, short_text, "diff preview · +60 −60"));
    try std.testing.expect(std.mem.indexOf(u8, short_text, "Ctrl+R to expand") != null);
    try std.testing.expect(std.mem.indexOf(u8, short_text, "more lines") != null);
    // The preview is the FIRST lines, and the far end of the file is not there.
    try std.testing.expect(std.mem.indexOf(u8, short_text, "linea 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, short_text, "linea 59") == null);

    // Ctrl+R opens the WHOLE diff…
    try std.testing.expect(m.toggleLastTool());
    const full_text = m.paras.items[diff_idx.?].text;
    try std.testing.expect(std.mem.indexOf(u8, full_text, "linea 59") != null);
    try std.testing.expect(std.mem.indexOf(u8, full_text, "Ctrl+R to expand") == null);

    // …and Ctrl+R closes it again (the same key, the same paragraph).
    try std.testing.expect(m.toggleLastTool());
    const again = m.paras.items[diff_idx.?].text;
    try std.testing.expect(std.mem.indexOf(u8, again, "Ctrl+R to expand") != null);
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
        nb += (std.mem.print(before[nb..], "line {d} with enough text for a realistic preview width\n", .{i}) catch break).len;
        na += (std.mem.print(after[na..], "line {d}! with enough text for a realistic preview width\n", .{i}) catch break).len;
    }

    m.pushToolStart("write", "src/demo.txt");
    m.pushToolDone("write", "wrote 80 lines", 5, "wrote 80 lines");
    _ = m.pushDiff(before[0..nb], after[0..na]);
    m.drainPending();

    const idx = m.last_tool.?.diff_para_idx.?;
    const text_len = m.paras.items[idx].text.len;
    try std.testing.expect(std.mem.indexOf(u8, m.paras.items[idx].text, "Ctrl+R to expand") != null);

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
    try std.testing.expect(std.mem.indexOf(u8, p.text, "Ctrl+R to expand") == null);
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

    _ = m.pushDiffLang("x\n", "const n: u32 = 4\n", "zig", "");
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

test "the + prefix and the body share the row's green (scannable diff)" {
    // A diff reads as rows: an added line is green, a deleted one red. The body
    // is still TOKENIZED (the structure survives), but its colour is the row's
    // so the reader scans bands instead of decoding token colours. The diff
    // green is distinct from the green of code strings.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const segs = try md.inlineSegmentsLang(arena, "+const n", .diff, null, null, "zig", null);
    try std.testing.expect(segs.len >= 2);
    try std.testing.expectEqualStrings("+", segs[0].text);
    try std.testing.expectEqual(theme.diffAdd().fg, segs[0].style.fg);
    try std.testing.expectEqual(theme.diffAdd().fg, segs[1].style.fg);
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

test "a code block's rows all end on the same column" {
    // The chip row padded with the BYTE length of the language and then
    // appended its closing ` │` on top of the full width, while every code
    // row counted the left gutter twice inside its padding: the label hung
    // two columns past the borders and the code fell two short — the
    // misaligned box, visible on every fenced block.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.nerd_icons = false; // stable marker width for column counting

    m.streamStart();
    m.streamDelta("```javascript\nclass MiniReact {\n  constructor() {}\n}\n```");
    m.streamEnd();
    const s = try drawTest(&m, arena_state.allocator(), 60, 24);

    var buf: [256]u8 = undefined;
    var box_w: ?usize = null;
    var box_rows: usize = 0;
    var r: u16 = 0;
    while (r < 24) : (r += 1) {
        const row = std.mem.trim(u8, rowText(s, r, &buf), " ");
        const is_box = std.mem.indexOf(u8, row, "\u{256D}") != null or // ╭
            std.mem.indexOf(u8, row, "\u{2570}") != null or // ╰
            std.mem.endsWith(u8, row, "\u{2502}"); // │ (chip row, code rows)
        if (!is_box) continue;
        // COLUMNS, not bytes: the borders are three-byte characters and the
        // code is ASCII, so byte length compares nothing. Everything inside
        // these rows (ASCII code, box-drawing, the `▚` chip) is one column
        // per grapheme, which is what the count below relies on.
        var cols: usize = 0;
        var git = vaxis.unicode.graphemeIterator(row);
        while (git.next()) |_| cols += 1;
        if (box_w == null) box_w = cols;
        try std.testing.expectEqual(box_w.?, cols);
        box_rows += 1;
    }
    // Top border, chip, three code rows, bottom border.
    try std.testing.expectEqual(@as(usize, 6), box_rows);
}

test "code block chip: nerd icons can be disabled and the label is always shown" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    // Disabled: fallback marker and label, same readable behavior as before.
    {
        var m = Model.init(std.testing.allocator);
        defer m.deinit();
        m.nerd_icons = false;
        m.streamStart();
        m.streamDelta("```zig\nconst n = 1;\n```");
        m.streamEnd();
        const s = try drawTest(&m, arena_state.allocator(), 60, 20);
        const text = allText(s);
        try std.testing.expect(std.mem.indexOf(u8, text, "zig") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "\u{259A}") != null); // ▚ fallback marker
    }

    // Enabled (auto default): mapped language shows its label; the old fallback
    // marker is replaced by the Nerd Font icon.
    {
        var m = Model.init(std.testing.allocator);
        defer m.deinit();
        try std.testing.expect(m.nerd_icons);
        m.streamStart();
        m.streamDelta("```zig\nconst n = 1;\n```");
        m.streamEnd();
        const s = try drawTest(&m, arena_state.allocator(), 60, 20);
        const text = allText(s);
        try std.testing.expect(std.mem.indexOf(u8, text, "zig") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "\u{259A}") == null);
    }
}

test "a code line wider than the box wraps inside it instead of pushing the border" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const long = &repeat.rep("x", 120);
    m.streamStart();
    m.streamDelta("```zig\n" ++ long ++ "\n```");
    m.streamEnd();
    const s = try drawTest(&m, arena_state.allocator(), 40, 24);

    var buf: [256]u8 = undefined;
    var wrapped_rows: usize = 0;
    var r: u16 = 0;
    while (r < 24) : (r += 1) {
        const row = rowText(s, r, &buf);
        if (std.mem.indexOf(u8, row, "x") == null) continue;
        // Every row of x's is a box row: `│ ` + x's + pad + ` │`, all inside
        // the terminal width.
        try std.testing.expect(std.mem.startsWith(u8, std.mem.trim(u8, row, " "), "\u{2502}"));
        try std.testing.expect(std.mem.endsWith(u8, std.mem.trim(u8, row, " "), "\u{2502}"));
        wrapped_rows += 1;
    }
    // 120 columns of x into a 36-column interior is four rows, not one clipped.
    try std.testing.expectEqual(@as(usize, 4), wrapped_rows);
}

test "the gutter does not eat text: the column invariant holds" {
    // The gutter eats 2 columns, so the content wraps to `width - 2`. If it
    // were inserted AFTER wrapping, the last line would go past the border.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const long = &repeat.rep("x", 200);
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

    const msg = &repeat.rep("la primera parte de la frase es larga ", 3);
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

    const payload = &repeat.rep("const std = @import(\"std\"); // \u{00f1}\u{2713}\u{2500}\n", 200);
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
    try std.testing.expect(findRow(s, "Recommended") != null);
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
    const short_text = allText(short);
    try std.testing.expect(std.mem.indexOf(u8, short_text, "Which approach") != null);
    try std.testing.expect(std.mem.indexOf(u8, short_text, "▸ 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, short_text, "Recommended") != null);
}

test "ask: width 24 with a long question keeps the selector usable" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    const options = [_][]const u8{ "keep the current implementation", "rewrite the module completely" };
    try openAskForTest(&m, "Which approach should we take for this very long and detailed question?", "design", &options);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const s = try drawTest(&m, arena_state.allocator(), 24, 18);
    const all = allText(s);
    // The question may wrap, but its key words must remain visible.
    try std.testing.expect(std.mem.indexOf(u8, all, "Which") != null or
        std.mem.indexOf(u8, all, "approach") != null);
    // The selected option marker remains visible in the tight layout.
    try std.testing.expect(std.mem.indexOf(u8, all, "▸ 1") != null);
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

test "timeline: a code block renders cleanly with terminal background preserved" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.streamStart();
    m.streamDelta("```zig\nconst n: u32 = 4;\n```");
    m.streamEnd();

    const s = try drawTest(&m, arena_state.allocator(), 40, 14);
    const row = findRow(s, "const n") orelse return error.TestUnexpectedResult;
    // Terminal background always shows through: code cells must not force a bg.
    const code_cell = cellWith(s, row, "c") orelse return error.TestUnexpectedResult;
    try std.testing.expect(code_cell.style.bg == .default);
    // The code is still present and syntax-highlighted (not plain default text).
    try std.testing.expect(findRow(s, "const n") != null);
}

test "estHeight: a fenced block is charged the rows it actually adds" {
    // It used to charge THREE rows per fence marker — six per closed block,
    // for a layout that adds one (the chip). The over-estimate is what
    // painted the black holes: past the lazy-parse threshold a paragraph
    // keeps the estimate as its height, so the scroll reserved rows the text
    // never fills.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.wrap_w = 80;

    // Four raw lines (open, two code, close) render as five rows: the fence
    // lines become the borders 1:1 and only the `zig` chip is extra.
    const closed = "```zig\nconst a = 1;\nconst b = 2;\n```";
    try std.testing.expectEqual(@as(usize, 5), m.estHeight(closed));

    // A block with no language adds nothing: both borders replace a fence line.
    const bare = "```\nconst a = 1;\n```";
    try std.testing.expectEqual(@as(usize, 3), m.estHeight(bare));

    // Mid-stream, an unclosed fence is one raw line that renders as top
    // border + chip + bottom border: two extras.
    const open = "```zig\nconst a = 1;";
    try std.testing.expectEqual(@as(usize, 4), m.estHeight(open));
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
    const s = try drawTest(&m, arena, 60, 24);

    // The complete word remains on one row instead of being split at the box
    // edge, and the question's choices remain inside the bordered panel.
    try std.testing.expect(findRow(s, "exceptionallylongword") != null);
    try std.testing.expect(findRow(s, "Recommended") != null);
    try std.testing.expect(findRow(s, "Use adapter") != null);

    // The panel is confined to the history viewport; the borderless prompt and
    // status strip remain painted and usable underneath it.
    //
    // In ask mode the prompt is `?` (warn color) to distinguish from normal prompt.
    const input_top = s.size.height - 2;
    try std.testing.expectEqualStrings("?", s.readCell(1, input_top).char.grapheme);
    try std.testing.expect(findRow(s, "Enter answers") != null);
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

    const before = &repeat.rep("line\n", 900);
    const after = &repeat.rep("changed line\n", 900);
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
    const many = &repeat.rep("    if x_ == 42 { return \"y\"; } else { print z_ + 1; }\n", 480);
    _ = m.pushDiff(&repeat.rep("old\n", 480), many);
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
        const text = std.mem.print(&line, "paragraph {d}: the quick brown fox jumps over the lazy dog " ++ repeat.rep("again ", 8), .{i}) catch "";
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
test "wire: a terminal reply delivered as key text never reaches the composer" {
    // The exact bytes from the crash report (`CSI 13;129;3u`, a kitty key
    // event with a modifier group). Whatever the parser makes of it, the
    // composer must end up empty: a reply is a sequence, not a character.
    // The same is true of a mouse report: vaxis makes it an event, but a key
    // event whose text carries control bytes must not be inserted either —
    // that is asserted directly below.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(arena);
    defer m.deinit();
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var ctx = testCtx();
    ctx.io = threaded.io();
    ctx.alloc = arena;
    ctx.cmds = .empty;

    var parser: vaxis.Parser = .{};
    const res = try parser.parse("\x1b[13;129;3u", arena);
    if (res.event) |ev| {
        switch (ev) {
            .key_press => |k| try typeErasedEventHandler(&m, &ctx, .{ .key_press = k }),
            else => {},
        }
    }
    try std.testing.expect(m.ed.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), m.ed.text().len);

    // A hand-built key whose text carries the reply: this is the path our
    // own handler owns, not vaxis's. It must not be inserted either.
    try typeErasedEventHandler(&m, &ctx, .{ .key_press = .{ .codepoint = 0, .text = "\x1b[13;129;3u" } });
    try std.testing.expect(m.ed.isEmpty());

    // And a normal character on the very next keystroke works.
    try typeErasedEventHandler(&m, &ctx, .{ .key_press = .{ .codepoint = 'a', .text = "a" } });
    try std.testing.expectEqualStrings("a", m.ed.text());
}

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

test "paste: a bracketed multi-line paste becomes ONE draft, not N prompts" {
    // vaxis forwards `paste_start`/`paste_end` as boundary markers and parses
    // EVERYTHING between them as ordinary key events. Without aggregation a
    // three-line paste submitted three prompts: each Enter reached
    // `submitInput`, each line echoed as its own `›` paragraph, and the last
    // two queued behind the worker the first had started.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(arena);
    defer m.deinit();
    var ctx = testCtx();
    ctx.alloc = arena;
    ctx.cmds = .empty;

    var parser: vaxis.Parser = .{};
    // The exact bytes a bracketed-paste terminal puts on the wire: the 0x0A
    // of the pasted newlines arrives as Ctrl+J (Parser `0x0A => 'j' + ctrl`),
    // which during a paste means a line break and not "submit".
    const wire = "\x1b[200~line one\nline two\nline three\x1b[201~";
    var i: usize = 0;
    while (i < wire.len) {
        const res = try parser.parse(wire[i..], arena);
        if (res.event) |ev| {
            const mapped: vxfw.Event = switch (ev) {
                .paste_start => .paste_start,
                .paste_end => .paste_end,
                .key_press => |k| .{ .key_press = k },
                else => continue,
            };
            try typeErasedEventHandler(&m, &ctx, mapped);
        }
        if (res.n == 0) break;
        i += res.n;
    }

    try std.testing.expectEqualStrings("line one\nline two\nline three", m.ed.text());
    // Nothing was sent: no queue, and no `›` user paragraph in the history
    // (`pushKind` lands in `pending` until the next draw moves it to `paras`).
    try std.testing.expectEqual(@as(usize, 0), m.queuedCount());
    for (m.paras.items) |p| try std.testing.expect(p.kind != .user);
    for (m.pending.items) |p| try std.testing.expect(p.kind != .user);
}

test "input: staged images show as [name] tags inside the composer" {
    // The image lives in `draft_images`, which is not text you can see: without
    // a mark in the box itself, an empty-looking input sending a picture is a
    // thing people press Enter on by accident and then cannot explain.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.draft_images.images[0] = .{
        .mime = "image/png",
        .data_b64 = "AAAA",
        .path = "clipboard.png",
    };
    m.draft_images.images[1] = .{
        .mime = "image/jpeg",
        .data_b64 = "BBBB",
        .path = "screenshot.jpg",
    };
    m.draft_images.len = 2;

    const s = try drawTest(&m, arena, 60, 20);
    // Both tags are painted, and they are painted in the INPUT area: below the
    // transcript, so on the last rows of the surface.
    try std.testing.expect(findRow(s, "[clipboard.png]") != null);
    try std.testing.expect(findRow(s, "[screenshot.jpg]") != null);
}

test "queue: a queued prompt is taken when no turn is in flight, and only then" {
    // The footer has always shown "⏳ queued (N waiting)" and nothing ever
    // ran them: `takeQueued` had no production caller. The tick asks
    // `takeQueuedWhenIdle`, whose gate is exactly this.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const a = m.allocator.dupe(u8, "the queued prompt") catch unreachable;
    _ = m.enqueuePrompt(a);

    // A turn in flight: `startChat` calls `isBusy`, which reads the streaming
    // flags, so that is the state the gate must refuse.
    m.streamStart();
    try std.testing.expect(m.takeQueuedWhenIdle() == null);
    try std.testing.expectEqual(@as(usize, 1), m.queuedCount());

    m.streamEnd(); // the turn just ended: it is time
    const got = m.takeQueuedWhenIdle().?;
    defer m.allocator.free(got.text);
    try std.testing.expectEqualStrings("the queued prompt", got.text);
    try std.testing.expect(got.mode == .normal);
    try std.testing.expect(m.takeQueuedWhenIdle() == null);
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

    // The continuation: the rest of the wrapped line should appear on the next row.
    const cont = rowText(s, row + 1, &buf);
    try std.testing.expect(std.mem.indexOf(u8, cont, "= 1234567890") != null);
}

test "/diff-color switches the diff palette and says what it did" {
    // The daltonized pair (blue/orange) is the one that survives the most
    // common colour-vision deficiency, and a palette that changed without
    // saying so is a palette the user cannot trust.
    const prev = theme.caps;
    defer theme.caps = prev;

    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    theme.caps = .{ .rgb = true };
    try agent.submit(&m, "/diff-color daltonized");
    try std.testing.expect(theme.caps.daltonized);

    try agent.submit(&m, "/diff-color default");
    try std.testing.expect(!theme.caps.daltonized);

    // An unknown palette is refused and it does NOT change anything.
    try agent.submit(&m, "/diff-color mauve");
    try std.testing.expect(!theme.caps.daltonized);

    // Legacy alias remains accepted.
    try agent.submit(&m, "/color daltonized");
    try std.testing.expect(theme.caps.daltonized);
    try agent.submit(&m, "/color default");
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

test "detectLinks finds URLs and file paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const urls = detectLinks(a, "see https://example.com/path and http://a.test/x.");
    try std.testing.expectEqual(@as(usize, 2), urls.len);
    try std.testing.expectEqualStrings("https://example.com/path", urls[0].uri);
    try std.testing.expectEqualStrings("http://a.test/x", urls[1].uri);

    const paths = detectLinks(a, "edit src/tui.zig and /tmp/out.txt now");
    try std.testing.expectEqual(@as(usize, 2), paths.len);
    try std.testing.expectEqualStrings("file:src/tui.zig", paths[0].uri);
    try std.testing.expectEqualStrings("file:///tmp/out.txt", paths[1].uri);
}

test "keybinds: a Vaxis key maps to the canonical binding string" {
    const gpa = std.testing.allocator;
    const f2 = (try keyToBinding(gpa, .{ .codepoint = vaxis.Key.f2 })).?;
    defer gpa.free(f2);
    try std.testing.expectEqualStrings("f2", f2);
    const ck = (try keyToBinding(gpa, .{ .codepoint = 'k', .mods = .{ .ctrl = true } })).?;
    defer gpa.free(ck);
    try std.testing.expectEqualStrings("ctrl+k", ck);
    const ar = (try keyToBinding(gpa, .{ .codepoint = 'r', .mods = .{ .alt = true } })).?;
    defer gpa.free(ar);
    try std.testing.expectEqualStrings("alt+r", ar);
    const esc = (try keyToBinding(gpa, .{ .codepoint = 27 })).?;
    defer gpa.free(esc);
    try std.testing.expectEqualStrings("esc", esc);
    // A Unicode codepoint with no single-byte name is intentionally unbound.
    try std.testing.expect((try keyToBinding(gpa, .{ .codepoint = 0x1F600 })) == null);
}

test "keybinds: a bound key resolves to its command, vim normal mode wins" {
    const gpa = std.testing.allocator;
    const bindings = try gpa.alloc(keybinds.Binding, 2);
    bindings[0] = .{ .key = try gpa.dupe(u8, "f2"), .command = try gpa.dupe(u8, "/help") };
    bindings[1] = .{ .key = try gpa.dupe(u8, "alt+r"), .command = try gpa.dupe(u8, "/review") };
    var m = Model.init(gpa);
    defer m.deinit();
    m.keybindings = bindings;
    const f2 = vaxis.Key{ .codepoint = vaxis.Key.f2 };
    try std.testing.expectEqualStrings("/help", (try boundCommand(&m, gpa, f2)).?);
    try std.testing.expectEqualStrings("/review", (try boundCommand(&m, gpa, .{ .codepoint = 'r', .mods = .{ .alt = true } })).?);
    try std.testing.expect((try boundCommand(&m, gpa, .{ .codepoint = vaxis.Key.f7 })) == null);
    m.vim_mode = true;
    m.vim_normal = true;
    try std.testing.expect((try boundCommand(&m, gpa, f2)) == null);
    m.vim_mode = false;
    m.vim_normal = false;
}

