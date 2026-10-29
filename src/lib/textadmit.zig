//! Safe admission of incoming text, byte by byte.
//!
//! Text arrives in chunks (a pipe read, a network frame, a session line) and a
//! chunk can end in the middle of a UTF-8 sequence or carry invalid bytes.
//! Feeding those chunks straight into the parser, the session file or the
//! terminal is how half-characters and garbage reach the model.
//!
//! This is the single place that admits incoming text:
//!   - every codepoint is handed out complete, never split;
//!   - invalid bytes and continuation bytes without a lead are dropped;
//!   - an incomplete trailing sequence is kept pending until it completes, and
//!     no other byte is retained;
//!   - when the writer changes, the pending bytes of the previous writer are
//!     discarded and that writer is named, so the caller can say what was lost.
//!
//! Pure: no allocator, no network, no terminal. Output is written into a
//! caller buffer, so nothing here allocates or fails.
//!
//! ## Where it plugs in
//!
//! Nothing in the tree feeds it yet: the session tail reader, the incremental
//! tool output and the chat line buffer all assemble bytes chunk by chunk and
//! are the natural call sites. Wiring one of them is the next step; until then
//! this is the tested primitive they will share, the same way `resultcap`
//! existed before Phase 3 wired it into the tools.

const std = @import("std");

/// One feed's outcome.
pub const Result = struct {
    /// Complete, valid UTF-8 formed from `bytes`, written into the caller's
    /// `out`. Never contains half a character.
    text: []const u8,
    /// The writer whose pending incomplete bytes were discarded, or null when
    /// nothing was discarded. The slice points at the caller's `writer`
    /// argument and must outlive the `Admitter`.
    dropped_writer: ?[]const u8 = null,
};

/// Admits incoming text one chunk at a time.
///
/// `writer` names the source of the bytes (``"stdout"``, a file path, a
/// session id, ...). The same slice must be passed for the same writer; the
/// comparison is by content.
pub const Admitter = struct {
    /// Bytes of the sequence in progress: always a well-formed prefix (a lead
    /// plus the continuations seen so far), never garbage. Up to 4 bytes.
    pending: [4]u8 = undefined,
    pending_len: u8 = 0,
    /// The writer of `pending`; `""` when nothing is pending.
    ctx: []const u8 = "",

    /// Feed `bytes` from `writer`. Complete codepoints are written into `out`;
    /// invalid bytes and incomplete sequences are dropped and never retained.
    ///
    /// When `writer` differs from the previous feed's writer, the pending
    /// (still incomplete) bytes of the previous writer are discarded and named
    /// in `dropped_writer`, then `writer` becomes the current one.
    ///
    /// Output is valid UTF-8 even when `out` is too small: a codepoint that does
    /// not fit is dropped entirely, never written in half. Size `out` for the
    /// worst case (each input byte its own codepoint) to lose nothing.
    pub fn feed(self: *Admitter, bytes: []const u8, writer: []const u8, out: []u8) Result {
    var dropped: ?[]const u8 = null;
    if (self.pending_len > 0 and !std.mem.eql(u8, self.ctx, writer)) {
        // A different writer is taking over: the half-formed character belongs
        // to the previous one. Discard it and name who it belonged to.
        dropped = self.ctx;
        self.pending_len = 0;
    }
    self.ctx = writer;

    var written: usize = 0;
    var i: usize = 0;
    // A sequence may be in progress from a previous feed: recompute how many
    // bytes it needs from its lead byte (always a valid lead we stored).
    var need: u8 = 0;
    if (self.pending_len > 0) {
        const n = std.unicode.utf8ByteSequenceLength(self.pending[0]) catch 4;
        need = @intCast(n);
    }
    while (i < bytes.len) {
        const b = bytes[i];
        if (self.pending_len == 0) {
            const seq = std.unicode.utf8ByteSequenceLength(b) catch {
                // Invalid lead byte (0xFF, 0xFE, 0xC0, 0xC1, ...): drop it,
                // retain nothing.
                i += 1;
                continue;
            };
            if (seq == 1) {
                if (written < out.len) out[written] = b;
                if (written < out.len) written += 1;
                i += 1;
                continue;
            }
            // Start a multi-byte sequence.
            self.pending[0] = b;
            self.pending_len = 1;
            need = @intCast(seq);
            i += 1;
            continue;
        }

        // Inside a sequence: the byte must be a continuation.
        if (b & 0xC0 != 0x80) {
            // Broken sequence: the pending bytes are garbage. Drop them and
            // reprocess this byte as a possible new lead.
            self.pending_len = 0;
            continue;
        }
        self.pending[self.pending_len] = b;
        self.pending_len += 1;
        i += 1;
        if (self.pending_len < need) continue;

        // The sequence is complete: emit it whole, or not at all.
        if (
            std.unicode.utf8ValidateSlice(self.pending[0..self.pending_len]) and
            written + self.pending_len <= out.len
        ) {
            @memcpy(out[written..][0..self.pending_len], self.pending[0..self.pending_len]);
            written += self.pending_len;
        }
        // Invalid (overlong, surrogate, ...): dropped, nothing retained.
        self.pending_len = 0;
    }

    return .{
        .text = out[0..written],
        .dropped_writer = dropped,
    };
    }

    /// Call at end of stream: any sequence still in progress is incomplete, so
    /// it is discarded and its writer is returned (null when nothing is pending).
    ///
    /// After this the admitter is empty: the next feed starts a fresh context.
    pub fn finish(self: *Admitter) ?[]const u8 {
    if (self.pending_len == 0) return null;
    const w = self.ctx;
    self.pending_len = 0;
    self.ctx = "";
    return w;
}
};

test "feed: ASCII passes through unchanged" {
    var a: Admitter = .{};
    var out: [16]u8 = undefined;
    const r = a.feed("hello", "w", &out);
    try std.testing.expectEqualStrings("hello", r.text);
    try std.testing.expect(r.dropped_writer == null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(r.text));
}

test "feed: multi-byte characters are never split" {
    var a: Admitter = .{};
    var out: [64]u8 = undefined;
    const input = "héllo ✓ 世界";
    const r = a.feed(input, "w", &out);
    try std.testing.expectEqualStrings(input, r.text);
    try std.testing.expect(std.unicode.utf8ValidateSlice(r.text));
}

test "feed: a chunk ending mid-sequence emits nothing and completes later" {
    var a: Admitter = .{};
    var out: [16]u8 = undefined;
    // "é" = 0xC3 0xA9
    const r1 = a.feed("\xC3", "w", &out);
    try std.testing.expectEqualStrings("", r1.text);
    const r2 = a.feed("\xA9tail", "w", &out);
    try std.testing.expectEqualStrings("étail", r2.text);
    try std.testing.expect(std.unicode.utf8ValidateSlice(r2.text));
}

test "feed: invalid lead bytes are dropped, valid neighbors kept" {
    var a: Admitter = .{};
    var out: [16]u8 = undefined;
    var buf: [4]u8 = [_]u8{ 'a', 0xFF, 0xFE, 'b' };
    const r = a.feed(buf[0..], "w", &out);
    try std.testing.expectEqualStrings("ab", r.text);
}

test "feed: a continuation byte without a lead is dropped" {
    var a: Admitter = .{};
    var out: [16]u8 = undefined;
    var buf: [2]u8 = [_]u8{ 0x80, 'a' };
    const r = a.feed(buf[0..], "w", &out);
    try std.testing.expectEqualStrings("a", r.text);
}

test "feed: a broken sequence leaves no garbage" {
    var a: Admitter = .{};
    var out: [16]u8 = undefined;
    // 0xC3 'A' -> the lead is dropped and 'A' is emitted; then 0xC3 0xA9 -> "é".
    var buf: [4]u8 = [_]u8{ 0xC3, 'A', 0xC3, 0xA9 };
    const r = a.feed(buf[0..], "w", &out);
    try std.testing.expectEqualStrings("Aé", r.text);
    try std.testing.expect(std.unicode.utf8ValidateSlice(r.text));
}

test "feed: an overlong encoding is dropped" {
    var a: Admitter = .{};
    var out: [16]u8 = undefined;
    // 0xC0 0x80 = overlong NUL: 0xC0 is not a valid lead, both bytes dropped.
    var buf: [2]u8 = [_]u8{ 0xC0, 0x80 };
    const r = a.feed(buf[0..], "w", &out);
    try std.testing.expectEqualStrings("", r.text);
}

test "feed: a surrogate sequence is dropped" {
    var a: Admitter = .{};
    var out: [16]u8 = undefined;
    // 0xED 0xA0 0x80 = U+D800 surrogate: well-formed lead but invalid codepoint.
    var buf: [3]u8 = [_]u8{ 0xED, 0xA0, 0x80 };
    const r = a.feed(buf[0..], "w", &out);
    try std.testing.expectEqualStrings("", r.text);
}

test "feed: the output is always valid UTF-8, even with hostile input" {
    var a: Admitter = .{};
    var out: [64]u8 = undefined;
    // 'h', 0xFF, bare continuation, overlong lead, 'i', broken 0xC3, "é",
    // surrogate sequence, 'j' -> expect "hiAéj".
    var buf: [14]u8 = [_]u8{
        'h', 0xFF, 0x80, 0xC0, 0x80, 'i', 0xC3, 'A', 0xC3, 0xA9, 0xED, 0xA0,
        0x80, 'j',
    };
    const r = a.feed(buf[0..], "w", &out);
    try std.testing.expectEqualStrings("hiAéj", r.text);
    try std.testing.expect(std.unicode.utf8ValidateSlice(r.text));
}

test "feed: a codepoint that does not fit is dropped whole, never halved" {
    var a: Admitter = .{};
    var out: [1]u8 = undefined;
    // "é" needs 2 bytes; out holds 1.
    const r = a.feed("é", "w", &out);
    try std.testing.expectEqualStrings("", r.text);
    try std.testing.expect(std.unicode.utf8ValidateSlice(r.text));
    // A later byte still gets through.
    const r2 = a.feed("z", "w", &out);
    try std.testing.expectEqualStrings("z", r2.text);
}

test "feed: writer change discards the pending bytes and names the previous writer" {
    var a: Admitter = .{};
    var out: [16]u8 = undefined;
    const r1 = a.feed("\xC3", "stdout", &out);
    try std.testing.expectEqualStrings("", r1.text);
    // A different writer takes over: the pending lead of "stdout" is discarded
    // and "stdout" is named.
    const r2 = a.feed("bye", "stderr", &out);
    try std.testing.expectEqualStrings("bye", r2.text);
    try std.testing.expectEqualStrings("stdout", r2.dropped_writer.?);
}

test "feed: same writer keeps the pending sequence across feeds" {
    var a: Admitter = .{};
    var out: [16]u8 = undefined;
    _ = a.feed("\xC3", "w", &out);
    const r = a.feed("\xA9", "w", &out);
    try std.testing.expectEqualStrings("é", r.text);
    try std.testing.expect(r.dropped_writer == null);
}

test "feed: writer change with nothing pending does not report a drop" {
    var a: Admitter = .{};
    var out: [16]u8 = undefined;
    const r1 = a.feed("a", "stdout", &out);
    try std.testing.expectEqualStrings("a", r1.text);
    const r2 = a.feed("b", "stderr", &out);
    try std.testing.expectEqualStrings("b", r2.text);
    try std.testing.expect(r2.dropped_writer == null);
}

test "finish: a trailing incomplete sequence is discarded and its writer named" {
    var a: Admitter = .{};
    var out: [8]u8 = undefined;
    _ = a.feed("\xC3", "stdout", &out);
    const w = a.finish();
    try std.testing.expect(w != null);
    try std.testing.expectEqualStrings("stdout", w.?);
    // Empty now: a lone continuation is dropped, nothing is retained.
    const r = a.feed("\xA9", "stdout", &out);
    try std.testing.expectEqualStrings("", r.text);
}

test "finish: nothing pending returns null" {
    var a: Admitter = .{};
    var out: [8]u8 = undefined;
    _ = a.feed("ok", "w", &out);
    try std.testing.expect(a.finish() == null);
}