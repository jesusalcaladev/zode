const std = @import("std");

/// Multiline input editor for the TUI.
///
/// `vxfw.TextField` is single-line, and the input is exactly where the
/// difference with Claude Code shows most: pasting a stack trace, writing a long
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

    /// Number of visual lines the text occupies at `width` columns.
    /// Counts hard breaks + wrap by columns (not by bytes: a wide grapheme
    /// takes 2 columns).
    pub fn displayLines(self: *const Editor, width: u16) usize {
        if (width == 0) return self.visual_lines;
        const w: usize = width;
        var total: usize = 0;
        var lines = std.mem.splitScalar(u8, self.buf.items, '\n');
        while (lines.next()) |line| {
            var used: usize = 0;
            var count: usize = 1;
            var it = std.unicode.Utf8Iterator{ .bytes = line, .i = 0 };
            while (it.nextCodepoint()) |cp| {
                const gw: usize = if (cp >= 0x1100) 2 else 1;
                if (used + gw > w and used > 0) {
                    count += 1;
                    used = gw;
                } else {
                    used += gw;
                }
            }
            total += count;
        }
        return @max(total, 1);
    }

    /// Visual line (0-based) where the cursor lands, for drawing the input.
    /// Assumes the text doesn't wrap (or that the caller only uses multiline).
    pub fn cursorLine(self: *const Editor) usize {
        var line: usize = 0;
        var i: usize = 0;
        while (i < self.cursor) : (i += 1) {
            if (self.buf.items[i] == '\n') line += 1;
        }
        return line;
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

test "insert y cursor" {
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

test "insert no parte graphemes multibyte al borrar" {
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

test "movimiento por palabra" {
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

test "home/end por línea con multilínea" {
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

test "multilínea: cursorLine y visual_lines" {
    var e = Editor.init(std.testing.allocator);
    defer e.deinit();

    try e.insert("uno\ndos");
    try std.testing.expectEqual(@as(usize, 2), e.visual_lines);
    try std.testing.expectEqual(@as(usize, 1), e.cursorLine());

    e.moveToEnd();
    try std.testing.expectEqual(@as(usize, 1), e.cursorLine());
}

test "deleteToStart y deleteToEnd" {
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

test "historial: ↑/↓ con borrador" {
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

test "historial guarda el borrador si no se envía" {
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

test "historial no duplica el prompt consecutivo" {
    var e = Editor.init(std.testing.allocator);
    defer e.deinit();

    try e.insert("igual");
    e.commit();
    try e.insert("igual");
    e.commit();

    try std.testing.expectEqual(@as(usize, 1), e.history.items.len);
}

test "displayLines cuenta wrap" {
    var e = Editor.init(std.testing.allocator);
    defer e.deinit();

    try e.insert("1234567890"); // 10 chars
    try std.testing.expectEqual(@as(usize, 1), e.displayLines(20));
    try std.testing.expectEqual(@as(usize, 2), e.displayLines(5));

    try e.insert("\nxy");
    try std.testing.expectEqual(@as(usize, 2), e.displayLines(20));
}
