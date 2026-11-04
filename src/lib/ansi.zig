//! Strip ANSI escape sequences from text that is going to be PAINTED.
//!
//! Tool output, compiler diagnostics and model text routinely carry escape
//! sequences (colors, cursor moves, terminal titles). Painting them is not a
//! matter of taste: the painter writes one cell per grapheme and measures
//! widths as it goes, so an SGR sequence like `\x1b[1;31m` used to measure
//! its introducer as a 1-cell control glyph and paint the rest of its bytes as
//! literal `[`, `1`, `;`, `3`, `1`, `m` next to it — the "caracteres raros"
//! and the broken layout. The one byte that CAN break the frame (the ESC) is
//! already caught by `isControlGrapheme`; everything after it is still garbage
//! painted as text.
//!
//! This module answers with the whole sequence, byte by byte, in one pass.
//! It is PURE (no I/O, no allocator outside the caller's) and it is what the
//! paragraph builder runs over every paragraph before it is parsed, so ALL
//! history text — streamed model output, tool output, diffs, shell lines —
//! goes through it exactly once.
//!
//! What is stripped:
//!
//!   - CSI sequences: `ESC [` + parameter/intermediate bytes + one final byte.
//!   - OSC sequences: `ESC ]` + anything + `BEL` or `ESC \`.
//!   - SS3 sequences: `ESC O` + one byte.
//!   - Any other two-byte `ESC <x>` pair.
//!   - Lone control bytes (C0, DEL, C1) other than `\n` and `\t`; mixed-content
//!     controls are replaced with nothing — the painter's U+FFFD backstop
//!     exists but this is strictly better.
//!
//! `\n` survives (the paragraph builder splits on it) and `\t` is replaced by
//! four spaces so it does not measure as a control glyph either.

const std = @import("std");

/// Copy `input` to `allocator` with every escape sequence and control byte
/// removed. `\n` is kept; `\t` is expanded to four spaces.
pub fn strip(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        const b = input[i];

        // ── ESC: swallow the whole sequence, not just the introducer ─────
        if (b == 0x1b) {
            if (i + 1 < input.len) {
                const n = input[i + 1];
                if (n == '[') {
                    i = skipCsi(input, i + 2);
                    continue;
                }
                if (n == ']') {
                    i = skipOsc(input, i + 2);
                    continue;
                }
                if (n == 'O') {
                    // SS3: `ESC O <one byte>`.
                    i = @min(input.len, i + 3);
                    continue;
                }
                // Other two-byte escapes (letter-terminated).
                i = @min(input.len, i + 2);
                continue;
            }
            // Lone trailing ESC: drop it.
            i += 1;
            continue;
        }

        // ── \t: expand to spaces ─────────────────────────────────────────
        if (b == '\t') {
            for (0..4) |_| try out.append(allocator, ' ');
            i += 1;
            continue;
        }

        // ── \n: kept; every other control byte is dropped ────────────────
        if (b == '\n') {
            try out.append(allocator, '\n');
            i += 1;
            continue;
        }
        if (isControlByte(b)) {
            i += 1;
            continue;
        }

        try out.append(allocator, b);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// CSI: parameters, intermediates, then ONE final byte in the range 0x40–0x7E.
/// An unterminated sequence is dropped entirely (better missing text than a
/// broken frame).
fn skipCsi(input: []const u8, from: usize) usize {
    var i = from;
    while (i < input.len) : (i += 1) {
        const b = input[i];
        if (b >= 0x40 and b <= 0x7e) return i + 1;
    }
    return input.len;
}

/// OSC: anything until a BEL (0x07) or the two-byte `ESC \`. Unterminated
/// sequence: drop the rest of the text (a title bar never ends, the frame
/// must not pay for it).
fn skipOsc(input: []const u8, from: usize) usize {
    var i = from;
    while (i < input.len) : (i += 1) {
        if (input[i] == 0x07) return i + 1;
        if (input[i] == 0x1b and i + 1 < input.len and input[i + 1] == '\\') return i + 2;
    }
    return input.len;
}

/// A single control byte: C0, DEL, or a C1 introduced by a UTF-8 sequence.
/// For a multi-byte UTF-8 sequence the bytes are all >= 0x80 and checked at
/// the lead-byte position, so only the two-byte `C2 80..9F` shape is C1.
pub fn isControlByte(b: u8) bool {
    if (b == '\n' or b == '\t') return false;
    if (b < 0x20 or b == 0x7f) return true;
    return false;
}

const t = std.testing;

test "strip: a plain string is returned unchanged" {
    const out = try strip(t.allocator, "hello world");
    defer t.allocator.free(out);
    try t.expectEqualStrings("hello world", out);
}

test "strip: SGR color sequences are removed and text is kept" {
    const out = try strip(t.allocator, "\x1b[1;31mred bold\x1b[0m and \x1b[32mgreen\x1b[0m");
    defer t.allocator.free(out);
    try t.expectEqualStrings("red bold and green", out);
}

test "strip: compiler diagnostics with colors come out clean" {
    const out = try strip(t.allocator, "\x1b[31msrc/main.zig:12:5: error: expected ';'\x1b[0m");
    defer t.allocator.free(out);
    try t.expectEqualStrings("src/main.zig:12:5: error: expected ';'", out);
}

test "strip: OSC terminal title is removed, and unterminated OSC drops the rest" {
    const out = try strip(t.allocator, "\x1b]0;my title\x07after the title");
    defer t.allocator.free(out);
    try t.expectEqualStrings("after the title", out);

    const out2 = try strip(t.allocator, "before\x1b]0;never closed");
    defer t.allocator.free(out2);
    try t.expectEqualStrings("before", out2);
}

test "strip: CR and other C0 controls are dropped, \\n survives" {
    const out = try strip(t.allocator, "line one\r\nline two\x00\x07");
    defer t.allocator.free(out);
    try t.expectEqualStrings("line one\nline two", out);
}

test "strip: a tab becomes four spaces" {
    const out = try strip(t.allocator, "a\tb");
    defer t.allocator.free(out);
    try t.expectEqualStrings("a    b", out);
}

test "strip: a lone ESC at the end is dropped" {
    const out = try strip(t.allocator, "trailing\x1b");
    defer t.allocator.free(out);
    try t.expectEqualStrings("trailing", out);
}

test "strip: unicode text is passed through untouched" {
    const out = try strip(t.allocator, "hola — 世界 🎉");
    defer t.allocator.free(out);
    try t.expectEqualStrings("hola — 世界 🎉", out);
}

test "strip: an unterminated CSI is dropped, and text after one is kept" {
    const out = try strip(t.allocator, "start\x1b[31;");
    defer t.allocator.free(out);
    try t.expectEqualStrings("start", out);
}

test "strip: cursor-positioning and clear-screen sequences are removed" {
    const out = try strip(t.allocator, "\x1b[2Jkept\x1b[10;20H positioning");
    defer t.allocator.free(out);
    try t.expectEqualStrings("kept positioning", out);
}

test "isControlByte: C0, DEL and friends, but not \\n/\\t" {
    try t.expect(isControlByte(0x00));
    try t.expect(isControlByte(0x1b));
    try t.expect(isControlByte(0x7f));
    try t.expect(isControlByte(0x1f));
    try t.expect(!isControlByte('\n'));
    try t.expect(!isControlByte('\t'));
    try t.expect(!isControlByte('a'));
}
