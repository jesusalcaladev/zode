const std = @import("std");
const vaxis = @import("vaxis");

/// Zo's moods. Each one has a color (the one its face uses in the status bar
/// and in the header); the agent picks it with `setStatusWithZo`.
pub const Mood = enum {
    idle,
    thinking,
    tooling,
    done,
    warn,
    err,

    /// Color of the face. ANSI indexes: a small status line reads better with
    /// terminal colors than with truecolor.
    /// The mood's color the way `vaxis.Style` wants it (not as a bare index).
    /// The status line uses it to paint the face, and the color IS the signal for
    /// "thinking / waiting for permission / hung", so it has to come out right
    /// without whoever paints having to remember the index.
    pub fn vaxisColor(self: Mood) vaxis.Cell.Color {
        return .{ .index = self.color() };
    }

    pub fn color(self: Mood) u8 {
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

/// Zo's face for a mood: the little face in the status bar and in the activity
/// strip.
///
/// The parentheses are the frame, and inside them go the two eyes (or the mouth,
/// in `tooling`). It only lives in the status bar, which is where it has to be
/// legible without eating rows of the header.
///
/// NO SPACES inside: the status test walks the face's graphemes looking for
/// them in the row, and a space matches any gap on screen (and comes out in the
/// wrong color, which is the style the test checks).
pub fn face(mood: Mood) []const u8 {
    return switch (mood) {
        .idle => "(◕◕)",
        .thinking => "(◕_)",
        .tooling => "(>_<)",
        .done => "(^◕^)",
        .warn => "(!_!)",
        .err => "(××)",
    };
}

/// ## Why PURE ASCII instead of box-drawing letters
///
/// It was tried twice with `█ ╗ ╝ ═ ║` (figlet "big" style) and both came out
/// wrong. The last one looked like a perfect ZODE in the test pty and like a
/// blurry relief in the user's terminal, reading as nothing at all.
///
/// The reason: a box-drawing art piece depends on HOW the font draws the full
/// block. With a double-width cell, with a terminal substitute, or with a weird
/// fallback font, the strokes widen and overlap, and what was a letter turns
/// into a smudge. `#` is a normal ASCII character and looks the same
/// everywhere.
///
/// ## Why it is COMPOSED in comptime instead of written by hand
///
/// The four letters are 6-column boxes separated by a space, and the padding of
/// each row is computed with `glyphCols` (columns, not bytes: each `█` is 3
/// bytes and the padding came out with an underflow). Written by hand the
/// padding gets lost, because editors strip trailing spaces, and the rows stop
/// landing on the same columns: the strokes don't line up and the name reads as
/// noise. Editing the banner means editing the glyph table, not measuring rows
/// by eye. `banner_art_width` is the assertion, and the TUI test checks it.
///
/// The spaces go INSIDE the glyph literal, never at the end of the file:
/// inside `"..."` they survive the editor even if the line ends
/// with `",`.
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
    "##  ##",
    "##  ##",
    "##  ##",
    "####  ",
};
const glyph_e = [_][]const u8{
    "######",
    "##    ",
    "##    ",
    "##    ",
    "######",
};

/// Columns of an art fragment, not bytes.
///
/// In the banner art everything is width 1 (`#` and space), so counting
/// codepoints IS counting columns. With `str.len` the right padding
/// came out wrong.
pub fn glyphCols(s: []const u8) usize {
    // The UTF-8 iterator branches once per byte and blows past the
    // 1000 branch quota. Raise it here only.
    @setEvalBranchQuota(10_000);
    const view = std.unicode.Utf8View.initUnchecked(s);
    var it = view.iterator();
    var n: usize = 0;
    while (it.nextCodepoint()) |_| n += 1;
    return n;
}

/// The wordmark, in order, with its width in columns.
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
fn bannerRow(comptime r: usize) []const u8 {
    comptime var out: []const u8 = "";
    inline for (wordmark, 0..) |letter, i| {
        if (i > 0) out = out ++ " ";
        // Pad on the RIGHT up to the box width. The last letter
        // doesn't need it: the trailing space wouldn't be visible, and the row
        // is measured against `banner_art_width` with a `@min`.
        if (i + 1 < wordmark.len) {
            // CAREFUL: `.len` is BYTES and each `█` is 3, so the padding is
            // computed in COLUMNS. With bytes it raised an `underflow` at comptime.
            const missing = letter.w - glyphCols(letter.rows[r]);
            const filler = " " ** missing;
            out = out ++ letter.rows[r] ++ filler;
        } else {
            out = out ++ letter.rows[r];
        }
    }
    return out;
}

/// Welcome banner for the TUI startup.
///
/// ONLY the wordmark. The header was complained about as "junk in the view",
/// and the user was right: an 18-row mascot, a greeting line and a shortcuts
/// line are 20 header rows before the first word of the chat. This is what was
/// literally asked for ("just put ZODE up there and that's it"), and it is the
///-banner that was there before Houston showed up (see AGENTS.md, v4).
///
/// The art goes in a single block on purpose: split into paragraphs, the
/// widest line dictates the wrapping of all of them.
pub const banner = bannerRow(0) ++ "\n" ++
    bannerRow(1) ++ "\n" ++
    bannerRow(2) ++ "\n" ++
    bannerRow(3) ++ "\n" ++
    bannerRow(4);

/// Two frames of the face for the activity strip.
///
/// The little mascot has to MOVE while the model works: it is the only
/// signal that the app is alive when the stream is slow. A static icon
/// doesn't say whether it's thinking or hung.
///
/// The second frame is the same face with one eye squinted (`◔`), and alternating
/// it with both eyes open (`◕`) reads as a blink.
pub fn faceFrames(mood: Mood, frame: u64) []const u8 {
    const odd = frame % 2 == 1;
    return switch (mood) {
        .idle => if (odd) "(◔◔)" else "(◕◕)",
        .thinking => if (odd) "(◕◔)" else "(◔◕)",
        .tooling => if (odd) "(-◡-)" else "(>_<)",
        .done => if (odd) "(◕◕)" else "(^◕^)",
        .warn => if (odd) "(!◕!)" else "(!_!)",
        .err => if (odd) "(◕×)" else "(××)",
    };
}

