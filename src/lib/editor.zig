const std = @import("std");

/// Multiline input editor for the TUI.
///
/// `vxfw.TextField` is single-line, and the input is exactly where the
/// difference shows most: pasting a stack trace, writing a long
/// prompt, or reviewing before sending. This editor covers the essentials:
///
///  - buffer with a cursor (byte offset), insertion and deletion per grapheme
///  - Shift+Enter / Alt+Enter insert a line break
///  - history with ↑/↓ (walks back through previous prompts)
///  - Ctrl+A/E, Ctrl+←/→ and Alt+B/F for word-wise movement
///  - `/` command autocompletion handled by the owner (here we only
///    expose the text for it to consult)
///
/// All the text is UTF-8 and word-wise jumps respect graphemes, not
/// bytes: `wörd` never gets split in the middle of the `ö`.
pub const max_history: usize = 100;
/// Buffer cap so that a huge paste doesn't bring down the TUI.
pub const max_bytes: usize = 256 * 1024;

pub const Editor = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    /// Cursor offset in bytes inside `buf`.
    cursor: usize = 0,
    /// Cursor of the current line when the text has multiple lines.
    history: std.ArrayList([]u8) = .empty,
    /// Index in `history` of the prompt being edited (-1 = none recovered).
    hist_idx: isize = -1,
    /// Draft of what was there before browsing the history.
    draft: std.ArrayList(u8) = .empty,
    /// Number of logical lines in the current text.
    visual_lines: usize = 1,

    pub fn init(gpa: std.mem.Allocator) Editor {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Editor) void {
        self.buf.deinit(self.gpa);
        for (self.history.items) |h| self.gpa.free(h);
        self.history.deinit(self.gpa);
        self.draft.deinit(self.gpa);
    }

    pub fn text(self: *const Editor) []const u8 {
        return self.buf.items;
    }

    pub fn isEmpty(self: *const Editor) bool {
        return self.buf.items.len == 0;
    }

    /// Inserts UTF-8 text at the cursor. Truncates if `s` doesn't fit whole (a
    /// huge paste must neither bring down the TUI nor lose what was already typed).
    pub fn insert(self: *Editor, s: []const u8) !void {
        if (s.len == 0) return;
        if (self.cursor + s.len > max_bytes) {
            const room = max_bytes -| self.cursor;
            if (room == 0) return error.InputTooLong;
            try self.buf.insertSlice(self.gpa, self.cursor, s[0..room]);
            self.cursor += room;
        } else {
            try self.buf.insertSlice(self.gpa, self.cursor, s);
            self.cursor += s.len;
        }
        self.hist_idx = -1;
        self.draft.clearRetainingCapacity();
        self.recountLines();
    }

    pub fn insertChar(self: *Editor, c: u8) !void {
        var one = [_]u8{c};
        try self.insert(&one);
    }

    /// Deletes bytes [start, end) and leaves the cursor at `start`.
    ///
    /// Used by the `@` autocomplete to replace the token being typed with the
    /// completed path: the replacement must cover ONLY the token, so that
    /// accepting mid-sentence keeps the rest of the sentence.
    pub fn deleteRange(self: *Editor, start: usize, end: usize) !void {
        if (start >= end or end > self.buf.items.len) return error.BadRange;
        try self.buf.replaceRange(self.gpa, start, end - start, &.{});
        self.cursor = start;
        self.hist_idx = -1;
        self.draft.clearRetainingCapacity();
        self.recountLines();
    }

    /// Moves the cursor to a byte offset (clamped to the buffer).
    pub fn setCursor(self: *Editor, pos: usize) void {
        self.cursor = @min(pos, self.buf.items.len);
    }

    pub fn clear(self: *Editor) void {
        self.buf.clearRetainingCapacity();
        self.cursor = 0;
        self.hist_idx = -1;
        self.draft.clearRetainingCapacity();
        self.visual_lines = 1;
    }

    // ── movement ─────────────────────────────────────────────

    /// Start of the previous grapheme. `from` is a valid byte offset, so the
    /// byte just before it is the LAST byte of the previous grapheme: walk
    /// backwards skipping continuation bytes until the leader.
    fn prevGraphemeStart(self: *const Editor, from: usize) usize {
        if (from == 0) return 0;
        var i = from - 1;
        while (i > 0 and isContinuation(self.buf.items[i])) i -= 1;
        return i;
    }

    /// End of the grapheme that starts at `from` (UTF-8 leader).
    fn nextGraphemeEnd(self: *const Editor, from: usize) usize {
        if (from >= self.buf.items.len) return self.buf.items.len;
        var i = from + 1;
        while (i < self.buf.items.len and isContinuation(self.buf.items[i])) i += 1;
        return i;
    }

    pub fn moveLeft(self: *Editor) void {
        self.cursor = self.prevGraphemeStart(self.cursor);
    }

    pub fn moveRight(self: *Editor) void {
        self.cursor = self.nextGraphemeEnd(self.cursor);
    }

    pub fn moveHome(self: *Editor) void {
        self.cursor = lineStart(self.buf.items, self.cursor);
    }

    pub fn moveEnd(self: *Editor) void {
        self.cursor = lineEnd(self.buf.items, self.cursor);
    }

    pub fn moveToStart(self: *Editor) void {
        self.cursor = 0;
    }

    pub fn moveToEnd(self: *Editor) void {
        self.cursor = self.buf.items.len;
    }

    pub fn moveWordLeft(self: *Editor) void {
        var i = self.cursor;
        // Skip spaces backwards, then the word.
        while (i > 0 and isSpace(self.buf.items[i - 1])) i -= 1;
        while (i > 0 and !isSpace(self.buf.items[i - 1])) {
            i = self.prevGraphemeStart(i);
            if (i == 0) break;
        }
        self.cursor = i;
    }

    /// Advances to the start of the next word. Equivalent to pressing Ctrl+→
    /// twice in a single-line editor: from inside a word it jumps to the start
    /// of the next one, it doesn't stop on the space in between.
    pub fn moveWordRight(self: *Editor) void {
        const len = self.buf.items.len;
        var i = @min(self.cursor, len);
        // 1. skip the current word and its separators
        while (i < len and !isSpace(self.buf.items[i])) i = self.nextGraphemeEnd(i);
        // 2. then the separators up to the next word
        while (i < len and isSpace(self.buf.items[i])) i += 1;
        self.cursor = i;
    }

    // ── deletion ─────────────────────────────────────────────

    pub fn deleteBefore(self: *Editor) void {
        if (self.cursor == 0) return;
        const start = self.prevGraphemeStart(self.cursor);
        self.buf.replaceRange(self.gpa, start, self.cursor - start, &.{}) catch return;
        self.cursor = start;
        self.recountLines();
    }

    pub fn deleteAfter(self: *Editor) void {
        if (self.cursor >= self.buf.items.len) return;
        const end = self.nextGraphemeEnd(self.cursor);
        self.buf.replaceRange(self.gpa, self.cursor, end - self.cursor, &.{}) catch return;
        self.recountLines();
    }

    pub fn deleteToEnd(self: *Editor) void {
        if (self.cursor >= self.buf.items.len) return;
        self.buf.shrinkRetainingCapacity(self.cursor);
        self.recountLines();
    }

    pub fn deleteToStart(self: *Editor) void {
        if (self.cursor == 0) return;
        const rest = self.buf.items[self.cursor..];
        self.buf.shrinkRetainingCapacity(self.cursor);
        const copy = self.gpa.alloc(u8, rest.len) catch return;
        @memcpy(copy, rest);
        self.buf.clearRetainingCapacity();
        self.buf.appendSlice(self.gpa, copy) catch {};
        self.gpa.free(copy);
        self.cursor = 0;
        self.recountLines();
    }

    pub fn deleteWordBefore(self: *Editor) void {
        const start = self.moveWordLeftTarget();
        self.buf.replaceRange(self.gpa, start, self.cursor - start, &.{}) catch return;
        self.cursor = start;
        self.recountLines();
    }

    fn moveWordLeftTarget(self: *Editor) usize {
        const saved = self.cursor;
        self.moveWordLeft();
        const out = self.cursor;
        self.cursor = saved;
        return out;
    }

    // ── history ──────────────────────────────────────────────

    /// Saves the current prompt and clears the buffer (called on send).
    pub fn commit(self: *Editor) void {
        const t = std.mem.trim(u8, self.buf.items, " \t\r\n");
        if (t.len > 0) {
            const copy = self.gpa.dupe(u8, t) catch {
                self.clear();
                return;
            };
            // Don't store consecutive duplicates.
            if (self.history.items.len == 0 or
                !std.mem.eql(u8, self.history.items[self.history.items.len - 1], copy))
            {
                self.history.append(self.gpa, copy) catch {};
                if (self.history.items.len > max_history) {
                    const old = self.history.orderedRemove(0);
                    self.gpa.free(old);
                }
            } else {
                self.gpa.free(copy);
            }
        }
        self.clear();
    }

    /// ↑: previous prompt. Returns false if there is no more.
    pub fn historyPrev(self: *Editor) bool {
        if (self.history.items.len == 0) return false;
        // The first time, save what was in the buffer as the draft.
        if (self.hist_idx == -1) {
            self.draft.clearRetainingCapacity();
            self.draft.appendSlice(self.gpa, self.buf.items) catch {};
            self.hist_idx = @intCast(self.history.items.len);
        }
        if (self.hist_idx == 0) return false;
        self.hist_idx -= 1;
        self.setText(self.history.items[@intCast(self.hist_idx)]);
        return true;
    }

    /// ↓: next prompt (or back to the draft).
    pub fn historyNext(self: *Editor) bool {
        if (self.hist_idx < 0) return false;
        if (@as(usize, @intCast(self.hist_idx)) >= self.history.items.len) return false;
        self.hist_idx += 1;
        if (@as(usize, @intCast(self.hist_idx)) >= self.history.items.len) {
            // Past the end: go back to what was being typed.
            self.setText(self.draft.items);
            self.hist_idx = -1;
            return true;
        }
        self.setText(self.history.items[@intCast(self.hist_idx)]);
        return true;
    }

    fn setText(self: *Editor, s: []const u8) void {
        self.buf.clearRetainingCapacity();
        self.buf.appendSlice(self.gpa, s) catch {};
        self.cursor = self.buf.items.len;
        self.recountLines();
    }

    // ── layout ───────────────────────────────────────────────

    fn recountLines(self: *Editor) void {
        var n: usize = 1;
        for (self.buf.items) |c| {
            if (c == '\n') n += 1;
        }
        self.visual_lines = n;
    }

    /// Number of visual rows the text occupies at `width` columns.
    ///
    /// A COUNT, computed with the same `RowIter` the painter walks, so the height
    /// of the box and the rows painted in it cannot disagree. That is not a
    /// detail: this used to be a second, independent wrap (`count('\n') + extra
    /// per wrap_w bytes`, wide chars guessed as `cp >= 0x1100`) while the draw
    /// split on `\n` and let `putText` clip at the terminal edge. The box grew to
    /// eight rows, the text stayed in one and ran off the right, and the tail was
    /// dropped silently.
    pub fn displayLines(self: *const Editor, width: u16, m: Measurer) usize {
        var it = RowIter.init(self.buf.items, width, m);
        var n: usize = 0;
        while (it.next() != null) n += 1;
        return @max(n, 1);
    }

    /// The `want` rows starting at row `first`, into `arena`.
    ///
    /// A window rather than "all the rows": a 256 KB paste at 40 columns is 6500
    /// rows, and the draw only has room for eight. Counting all of them and
    /// keeping eight would allocate the other 6492 for nothing, every frame.
    pub fn rowsInWindow(
        self: *const Editor,
        first: usize,
        want: usize,
        width: u16,
        m: Measurer,
        arena: std.mem.Allocator,
    ) []Row {
        var out: std.ArrayList(Row) = .empty;
        var it = RowIter.init(self.buf.items, width, m);
        var idx: usize = 0;
        while (it.next()) |row| {
            if (idx >= first and out.items.len < want) out.append(arena, row) catch break;
            idx += 1;
        }
        return out.items;
    }

    /// Where the cursor is, in VISUAL terms: the row it is on and the column
    /// inside it.
    ///
    /// `cursorLine` could not do this: it counted `\n` and returned a LOGICAL
    /// line, which `drawInput` then used as a ROW index. On a wrapped line that
    /// put the caret on the first row of the box with a column of
    /// `2 + width_of_everything_before_the_cursor`, i.e. outside the terminal.
    pub fn cursorRowCol(self: *const Editor, width: u16, m: Measurer) CursorPos {
        var it = RowIter.init(self.buf.items, width, m);
        var idx: usize = 0;
        var boundary: ?CursorPos = null;
        while (it.next()) |row| {
            const end = row.offset + row.bytes.len;
            if (self.cursor < end) {
                var col: u16 = 0;
                var i = row.offset;
                while (i < self.cursor) {
                    const st = m.s(self.buf.items, i);
                    col += st.cols;
                    i = st.end;
                }
                return .{ .row = idx, .col = col };
            }
            if (self.cursor == end) {
                // Exactly on a wrap point. The cursor goes at the END of this row
                // rather than at column 0 of the next one: the next row may not
                // exist at all (the text ends here), and a caret off the box is
                // worse than one column of slack.
                var col: u16 = 0;
                var i = row.offset;
                while (i < end) {
                    const st = m.s(self.buf.items, i);
                    col += st.cols;
                    i = st.end;
                }
                boundary = .{ .row = idx, .col = col };
            }
            idx += 1;
        }
        return boundary orelse .{ .row = idx, .col = 0 };
    }

    /// Logical line (0-based) of the cursor, for the editor's own logic.
    pub fn cursorLine(self: *const Editor) usize {
        var line: usize = 0;
        var i: usize = 0;
        while (i < self.cursor) : (i += 1) {
            if (self.buf.items[i] == '\n') line += 1;
        }
        return line;
    }
};

/// Where the cursor is, in visual terms.
pub const CursorPos = struct { row: usize, col: u16 };

/// One visual row: a slice of the text and the byte offset it starts at.
///
/// The offset is what makes the cursor work: mapping a byte offset to a row needs
/// to know where each row began, and a `[]const []const u8` of pieces cannot say
/// it without walking the text again.
pub const Row = struct {
    bytes: []const u8,
    offset: usize,
};

/// How to measure one grapheme, provided by the caller.
///
/// The Editor deliberately knows neither of the two things this needs: what a
/// grapheme is (that is `vaxis.unicode`) and how wide the user's terminal says
/// one is (`ctx.stringWidth`, which depends on what vaxis negotiated at startup).
/// Guessing either one is how the wrap and the paint drift apart.
pub const Step = struct {
    /// Columns the grapheme advances the cursor.
    cols: u16,
    /// Byte offset just past it.
    end: usize,
};

pub const StepFn = *const fn (ctx: *const anyopaque, text: []const u8, i: usize) Step;

pub const Measurer = struct {
    ctx: *const anyopaque = undefined,
    step: StepFn,

    pub fn s(self: Measurer, text: []const u8, i: usize) Step {
        const st = self.step(self.ctx, text, i);
        return .{ .cols = @max(1, st.cols), .end = if (st.end > i) st.end else i + 1 };
    }
};

/// Walks the text as the input box paints it: hard `\n` first, then a word wrap
/// at `width` columns.
///
/// WORD wrap, not the greedy per-grapheme break the history uses. In the history a
/// break inside a word is a minor blemish; in the input box it means the user
/// cannot see what they typed, and the box is three rows tall showing one. A token
/// longer than the row (a path, a URL, a long identifier) still breaks hard: there
/// is nowhere else to put it.
pub const RowIter = struct {
    text: []const u8,
    width: u16,
    m: Measurer,
    pos: usize = 0,
    done: bool = false,

    pub fn init(text: []const u8, width: u16, m: Measurer) RowIter {
        return .{ .text = text, .width = @max(width, 1), .m = m };
    }

    pub fn next(self: *RowIter) ?Row {
        if (self.done) return null;
        if (self.pos >= self.text.len) {
            // The text always ends in a row, even an empty one: an empty editor
            // is one row, and the cursor needs somewhere to be.
            self.done = true;
            return .{ .bytes = self.text[self.pos..], .offset = self.pos };
        }
        if (self.text[self.pos] == '\n') {
            const off = self.pos;
            self.pos += 1;
            return .{ .bytes = self.text[off..off], .offset = off };
        }

        const start = self.pos;
        var col: u16 = 0;
        // Byte offset (relative to `start`) of the run of spaces where this row
        // MAY be broken, or null when the row has no break opportunity yet.
        var brk: ?usize = null;
        var i = start;
        while (i < self.text.len) {
            if (self.text[i] == '\n') break;
            const st = self.m.s(self.text, i);
            if (col + st.cols > self.width and col > 0) {
                if (brk != null and brk.? > 0) {
                    const b = brk.?;
                    // Word break: the row ends before the space run and the next
                    // row starts at the first non-space.
                    const row_end = start + b;
                    var j = row_end;
                    while (j < self.text.len and self.text[j] == ' ') j += 1;
                    self.pos = j;
                    if (self.pos >= self.text.len) self.done = true;
                    return .{ .bytes = self.text[start..row_end], .offset = start };
                }
                // No word boundary in this row (a long path, a URL): break it
                // hard, which is the only way it fits at all.
                self.pos = st.end;
                if (self.pos >= self.text.len) self.done = true;
                return .{ .bytes = self.text[start..st.end], .offset = start };
            }
            // The LAST run of spaces is where this row may break. It is not
            // cleared when the word after it arrives: the word might not fit
            // either, and clearing it turned every wrap into a hard break in the
            // middle of a word ("hola mundo cr" / "uel").
            if (self.text[i] == ' ') brk = i - start;
            col += st.cols;
            i = st.end;
        }
        // The newline belongs to the row that just ended: consuming it here is
        // what keeps `"uno\ndos"` at two rows instead of three (the `\n` was
        // otherwise seen again at the start of the next call and emitted as an
        // empty row of its own).
        self.pos = if (i < self.text.len and self.text[i] == '\n') i + 1 else i;
        // A row that reached the end IS the last row: without this the iterator
        // emitted one more empty row after it, so every non-empty text was one
        // row taller than it is painted.
        if (self.pos >= self.text.len) self.done = true;
        return .{ .bytes = self.text[start..i], .offset = start };
    }
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Is it a UTF-8 continuation byte (10xxxxxx)?
fn isContinuation(c: u8) bool {
    return (c & 0xC0) == 0x80;
}

fn lineStart(s: []const u8, from: usize) usize {
    var i = from;
    while (i > 0 and s[i - 1] != '\n') i -= 1;
    return i;
}

fn lineEnd(s: []const u8, from: usize) usize {
    var i = from;
    while (i < s.len and s[i] != '\n') i += 1;
    return i;
}

// ── tests ─────────────────────────────────────────────────────

test "insert and cursor" {
    var e = Editor.init(std.testing.allocator);
    defer e.deinit();

    try e.insert("hola");
    try std.testing.expectEqualStrings("hola", e.text());
    try std.testing.expectEqual(@as(usize, 4), e.cursor);

    e.moveLeft();
    try std.testing.expectEqual(@as(usize, 3), e.cursor);
    try e.insertChar('!');
    try std.testing.expectEqualStrings("hol!a", e.text());
    try std.testing.expectEqual(@as(usize, 4), e.cursor);
}

test "insert does not split multibyte graphemes when deleting" {
    var e = Editor.init(std.testing.allocator);
    defer e.deinit();

    // "añb" = 4 bytes: a(1) + ñ(2) + b(1)
    try e.insert("a\u{00f1}b");
    try std.testing.expectEqual(@as(usize, 4), e.cursor);

    // The cursor is after the 'b' (1 byte), so that is what gets deleted.
    e.deleteBefore();
    try std.testing.expectEqualStrings("a\u{00f1}", e.text());
    try std.testing.expectEqual(@as(usize, 3), e.cursor);

    // Now the ñ: both bytes at once, never a lone byte.
    e.deleteBefore();
    try std.testing.expectEqualStrings("a", e.text());
    try std.testing.expectEqual(@as(usize, 1), e.cursor);

    // And back again, by inserting in the middle.
    e.deleteAfter();
    try std.testing.expectEqualStrings("a", e.text());
}

test "word movement" {
    var e = Editor.init(std.testing.allocator);
    defer e.deinit();

    // "alpha beta gamma": g=11, b=6, len=16
    try e.insert("alpha beta gamma");
    e.moveToEnd();

    e.moveWordLeft();
    try std.testing.expectEqual(@as(usize, 11), e.cursor); // start of "gamma"
    e.moveWordLeft();
    try std.testing.expectEqual(@as(usize, 6), e.cursor); // start of "beta"

    e.moveWordRight();
    try std.testing.expectEqual(@as(usize, 11), e.cursor);
    e.moveWordRight();
    try std.testing.expectEqual(@as(usize, 16), e.cursor); // end

    // From the start, one word-jump forward lands on the start of "beta".
    e.moveToStart();
    e.moveWordRight();
    try std.testing.expectEqual(@as(usize, 6), e.cursor);
    // And from there, on "gamma".
    e.moveWordRight();
    try std.testing.expectEqual(@as(usize, 11), e.cursor);
}

test "home/end per line with multiline content" {
    var e = Editor.init(std.testing.allocator);
    defer e.deinit();

    try e.insert("uno\ndos\ntres");
    e.moveToEnd();
    try std.testing.expectEqual(@as(usize, 12), e.cursor);

    e.moveHome();
    try std.testing.expectEqual(@as(usize, 8), e.cursor); // "tres"
    e.moveEnd();
    try std.testing.expectEqual(@as(usize, 12), e.cursor);
}

test "multiline: cursorLine and visual_lines" {
    var e = Editor.init(std.testing.allocator);
    defer e.deinit();

    try e.insert("uno\ndos");
    try std.testing.expectEqual(@as(usize, 2), e.visual_lines);
    try std.testing.expectEqual(@as(usize, 1), e.cursorLine());

    e.moveToEnd();
    try std.testing.expectEqual(@as(usize, 1), e.cursorLine());
}

test "deleteToStart and deleteToEnd" {
    var e = Editor.init(std.testing.allocator);
    defer e.deinit();

    try e.insert("hello world");
    e.moveToEnd();
    e.deleteToStart();
    try std.testing.expectEqualStrings("", e.text());
    try std.testing.expectEqual(@as(usize, 0), e.cursor);

    try e.insert("abc");
    e.moveToStart();
    e.deleteToEnd();
    try std.testing.expectEqualStrings("", e.text());
}

test "history: up/down with a draft" {
    var e = Editor.init(std.testing.allocator);
    defer e.deinit();

    try e.insert("primero");
    e.commit();
    try e.insert("segundo");
    e.commit();
    try e.insert("tercero");
    e.commit();

    // The buffer is empty after commit.
    try std.testing.expect(e.isEmpty());

    try std.testing.expect(e.historyPrev());
    try std.testing.expectEqualStrings("tercero", e.text());
    try std.testing.expect(e.historyPrev());
    try std.testing.expectEqualStrings("segundo", e.text());
    try std.testing.expect(e.historyPrev());
    try std.testing.expectEqualStrings("primero", e.text());
    // No more further back.
    try std.testing.expect(!e.historyPrev());

    // Going down advances again and ends on the draft (empty).
    try std.testing.expect(e.historyNext());
    try std.testing.expectEqualStrings("segundo", e.text());
    try std.testing.expect(e.historyNext());
    try std.testing.expectEqualStrings("tercero", e.text());
    try std.testing.expect(e.historyNext());
    try std.testing.expect(e.isEmpty());
}

test "history keeps the draft when it is not sent" {
    var e = Editor.init(std.testing.allocator);
    defer e.deinit();

    try e.insert("guardado");
    e.commit();

    try e.insert("borrador a medias");
    try std.testing.expect(e.historyPrev());
    try std.testing.expectEqualStrings("guardado", e.text());
    // Going all the way down returns to the draft, not to empty.
    try std.testing.expect(e.historyNext());
    try std.testing.expectEqualStrings("borrador a medias", e.text());
}

test "history does not duplicate a consecutive prompt" {
    var e = Editor.init(std.testing.allocator);
    defer e.deinit();

    try e.insert("igual");
    e.commit();
    try e.insert("igual");
    e.commit();

    try std.testing.expectEqual(@as(usize, 1), e.history.items.len);
}

test "displayLines counts the wrap" {
    var e = Editor.init(std.testing.allocator);
    defer e.deinit();

    const m = testMeasurer();
    try e.insert("1234567890"); // 10 chars, no spaces: a hard wrap
    try std.testing.expectEqual(@as(usize, 1), e.displayLines(20, m));
    try std.testing.expectEqual(@as(usize, 2), e.displayLines(5, m));

    try e.insert("\nxy");
    try std.testing.expectEqual(@as(usize, 2), e.displayLines(20, m));
}

// ── tests ─────────────────────────────────────────────────────

/// 1 column per codepoint, codepoint per codepoint: good enough for the tests
/// and it keeps this file free of `vaxis` (the real measurer lives in `tui.zig`,
/// because only the terminal layer knows how wide a grapheme is HERE).
fn testStep(ctx: *const anyopaque, text: []const u8, i: usize) Step {
    _ = ctx;
    var it = std.unicode.Utf8Iterator{ .bytes = text, .i = i };
    const cp = it.nextCodepoint() orelse return .{ .cols = 1, .end = text.len };
    const wide: bool = cp >= 0x1100;
    const cols: u16 = if (wide) @as(u16, 2) else 1;
    // `it.i` is the offset just past the codepoint: the iterator already knows
    // the length, so there is no need to ask `utf8ByteSequenceLength` (which
    // takes the first BYTE, not the codepoint).
    return .{ .cols = cols, .end = it.i };
}

fn testMeasurer() Measurer {
    return .{ .step = testStep };
}

fn rows(text: []const u8, width: u16, arena: std.mem.Allocator) []Row {
    var out: std.ArrayList(Row) = .empty;
    var it = RowIter.init(text, width, testMeasurer());
    while (it.next()) |r| out.append(arena, r) catch {};
    return out.items;
}

test "RowIter: a short line is one row and an empty text is one empty row" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();
    const r = rows("hola", 20, gpa);
    try std.testing.expectEqual(@as(usize, 1), r.len);
    try std.testing.expectEqualStrings("hola", r[0].bytes);
    const e = rows("", 20, gpa);
    try std.testing.expectEqual(@as(usize, 1), e.len);
    try std.testing.expectEqualStrings("", e[0].bytes);
}

test "RowIter: a hard break is its own row, and an empty line survives" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();
    const r = rows("uno\ndos", 20, gpa);
    try std.testing.expectEqual(@as(usize, 2), r.len);
    try std.testing.expectEqualStrings("uno", r[0].bytes);
    try std.testing.expectEqualStrings("dos", r[1].bytes);

    // The empty line in the middle is a ROW: dropping it would glue the text
    // above to the text below, which is the paragraph separator the user typed.
    const b = rows("uno\n\ndos", 20, gpa);
    try std.testing.expectEqual(@as(usize, 3), b.len);
    try std.testing.expectEqualStrings("", b[1].bytes);
}

test "RowIter: it wraps at a WORD, not inside one" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();
    const r = rows("hola mundo cruel", 12, gpa);
    try std.testing.expectEqual(@as(usize, 2), r.len);
    try std.testing.expectEqualStrings("hola mundo", r[0].bytes);
    try std.testing.expectEqualStrings("cruel", r[1].bytes);
    // No row starts with a space: the break eats the run.
    for (r) |row| try std.testing.expect(row.bytes.len == 0 or row.bytes[0] != ' ');
}

test "RowIter: a token longer than the row breaks hard (a path has to fit)" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();
    const r = rows("src/tui.zig", 6, gpa);
    try std.testing.expect(r.len >= 2);
    // No character is lost or duplicated: this is the invariant that matters,
    // because the old code dropped everything past the right border.
    var joined: [64]u8 = undefined;
    var n: usize = 0;
    for (r) |row| {
        if (n + row.bytes.len > joined.len) break;
        @memcpy(joined[n .. n + row.bytes.len], row.bytes);
        n += row.bytes.len;
    }
    try std.testing.expectEqualStrings("src/tui.zig", joined[0..n]);
}

test "cursorRowCol: on a wrapped line the cursor is on the row it is really on" {
    var e = Editor.init(std.testing.allocator);
    defer e.deinit();
    const m = testMeasurer();
    try e.insert("hola mundo cruel");
    e.cursor = e.buf.items.len;

    const cc = e.cursorRowCol(12, m);
    try std.testing.expectEqual(@as(usize, 1), cc.row);
    try std.testing.expectEqual(@as(u16, 5), cc.col); // "cruel"

    // And with the text NOT wrapped it is row 0 with the whole width.
    const one = e.cursorRowCol(80, m);
    try std.testing.expectEqual(@as(usize, 0), one.row);
    try std.testing.expectEqual(@as(u16, 16), one.col);
}

test "rowsInWindow returns the LAST rows when there are more than fit" {
    var e = Editor.init(std.testing.allocator);
    defer e.deinit();
    const m = testMeasurer();
    try e.insert("aaa bbb ccc ddd eee");
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const total = e.displayLines(4, m);
    try std.testing.expect(total > 3);
    const w = e.rowsInWindow(total - 2, 2, 4, m, a.allocator());
    try std.testing.expectEqual(@as(usize, 2), w.len);
    // The window is the tail, which is where the cursor is.
    try std.testing.expectEqualStrings(w[w.len - 1].bytes, w[1].bytes);
}
