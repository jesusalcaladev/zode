const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

/// Semantic palette for the TUI. One single place for the colors: the ANSI
/// index is the terminal's business, we only ask for "accent", "warn", etc.
pub const accent: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xb4, 0x5d, 0xff } } }; // vibrant violet
pub const accent_bold: vaxis.Style = .{ .bold = true, .fg = .{ .index = 4 } };

// ── brand blue ───────────────────────────────────────────────
// Three tones instead of a single `accent`: it gives depth to the chrome
// (header, borders, status) without anything shouting. The values are the
// blues of the Tokyo Night palette, the theme the TUI was reviewed with; if
// your terminal uses a different dark background they still look harmonious
// (same hue, different lightness).
//
// truecolor (`.rgb`) with vaxis falling back to the nearest ANSI index on
// terminals that don't support it.

/// Bright blue: `zode` wordmark, `❯` prompt, active model, commands.
/// Vibrant electric violet/cyan for modern look
pub const brand: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xb4, 0x5d, 0xff } } };
pub const brand_bold: vaxis.Style = .{ .bold = true, .fg = .{ .rgb = .{ 0xe9, 0x7c, 0xff } } };
/// Bright neon cyan for highlights
pub const brand_hi: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x22, 0xd3, 0xee } } };
/// Softer violet for secondary text
pub const brand_soft: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x94, 0x7a, 0xd6 } } };
/// Subtle border color
pub const brand_faint: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x4c, 0x3e, 0x8d } } };
pub const assistant: vaxis.Style = .{ .fg = .{ .index = 5 } }; // magenta
pub const assistant_bold: vaxis.Style = .{ .bold = true, .fg = .{ .index = 5 } };
pub const tool: vaxis.Style = .{ .fg = .{ .index = 6 } }; // cyan

// ── readable secondary text ────────────────────────────────────
//
// `brand_faint` (#3b4261) is ~1.9:1 against a dark background: fine for a
// hairline border, UNREADABLE for a line of text. It was doing both jobs —
// the `ask` panel's hint and clock, the key hints under the code chips — and
// the only legible thing in that panel was the question itself.
//
// The split is by ROLE, not by taste:
//   - `brand_faint`  hairlines: borders, separators, rules. Never text.
//   - `hint`         text the user is meant to read but that is not the
//                    answer. ~4.5:1 on the dark backgrounds we use.
//   - `brand_soft`   text that is genuinely tertiary (a label, a counter).
pub const hint: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x7a, 0x83, 0x99 } } };
/// One step below `hint`: a key hint next to something already labelled.
pub const hint_faint: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x65, 0x6d, 0x82 } } };
/// Background of the selected row in a list. It has to be a BACKGROUND: with
/// only a foreground change, a selected item is distinguishable only by bold,
/// which is a difference most people do not see across a 60-column row.
pub const sel_bg: vaxis.Style = .{ .bg = .{ .rgb = .{ 0x3d, 0x2f, 0x6b } } };
pub const ok: vaxis.Style = .{ .fg = .{ .index = 2 } }; // green
pub const warn: vaxis.Style = .{ .fg = .{ .index = 3 } }; // yellow
pub const warn_bold: vaxis.Style = .{ .bold = true, .fg = .{ .index = 3 } };
pub const err: vaxis.Style = .{ .fg = .{ .index = 1 } }; // red
pub const dim: vaxis.Style = .{ .fg = .{ .index = 8 } };
pub const text: vaxis.Style = .{};
pub const user: vaxis.Style = .{ .fg = .{ .index = 7 } }; // bright white

/// Style of the separator line / borders.
pub const rule: vaxis.Style = brand_faint;

/// Style of the input box (border + prompt).
pub const input_border: vaxis.Style = brand_faint;
pub const input_prompt: vaxis.Style = brand_bold;
pub const input_text: vaxis.Style = .{};
pub const placeholder: vaxis.Style = hint;

/// Color of the context gauge depending on how full it is: comfortable green,
/// yellow as it approaches the compaction budget, red above that.
/// Thresholds: <50%, <80%, the rest. 80% is exactly where compaction starts.
pub fn ctxColor(pct: u8) vaxis.Style {
    if (pct < 50) return ok;
    if (pct < 80) return warn;
    return err;
}

/// Selected row: brand blue AND a background. See `sel_bg` for why the
/// background is not optional.
pub const selected: vaxis.Style = .{ .bold = true, .fg = .{ .index = 4 }, .bg = sel_bg.bg };

// ── code token palette (ROADMAP Phase 4.4/4.5/4.6) ──────────────
//
// They were hardcoded in `highlight.zig` as xterm-256 indexes, without
// importing `theme.zig`. Two consequences:
//  - The code was shown in the terminal's default colors, not the app's: the
//    header in brand blue and the code block in 256 came from
//    different systems.
//  - `str` and `diff_add` were BOTH `index 2`. That is, a code string and
//    an added diff line came out in the SAME green, which is exactly what
//    makes "the whole diff is green" indistinguishable from "this is a string".
//
// They are separated here: strings in dim green (#9ece6a) and added lines in
// a brighter green (#73daca), and normal text (`def`) drops to a light
// gray (#a9b1d6) instead of `Style{}`, which is the terminal's default
// color: the BRIGHTEST thing on screen. With ~90% of the code's
// lines landing in `def`, the whole block was the loudest thing there.

/// Normal code text. Before it was `Style{}` = the terminal's default
/// color, that is, the brightest thing on screen.
pub const code_text: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xa9, 0xb1, 0xd6 } } };
pub const code_kw: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xbb, 0x9a, 0xf7 } } }; // lilac
pub const code_kw2: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xbb, 0x9a, 0xf7 } }, .italic = true };
pub const code_builtin: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x22, 0xd3, 0xee } } }; // cyan
pub const code_type: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x2a, 0xc7, 0xb9 } } }; // cyan
pub const code_str: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x9e, 0xce, 0x6a } } }; // dim green
pub const code_comment: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x56, 0x5f, 0x89 } }, .italic = true };
pub const code_num: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xe0, 0xaf, 0x68 } } }; // amber
/// Function call: now with COLOR, not just `bold` (which is indistinguishable
/// from normal bold text).
pub const code_fn: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xb4, 0x5d, 0xff } }, .bold = true };
pub const code_deco: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xe0, 0xaf, 0x68 } }, .italic = true };

// ── diff ───────────────────────────────────────────────────────
// Decoupled from `code_str` on purpose: see above.
pub const diff_add: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x73, 0xda, 0xca } } };
pub const diff_del: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xf7, 0x76, 0x8e } } };
pub const diff_ctx: vaxis.Style = code_comment;

/// Background and gutter of a code block (Phase 4.1).
pub const code_bg: vaxis.Style = .{ .bg = .{ .rgb = .{ 0x1a, 0x1b, 0x26 } } };
/// The `│` in the gutter of a CONTINUATION row: the line under a tool result or
/// a wrapped paragraph still belongs to it. One glyph per row, and it is the
/// difference between "one result plus five anonymous rows" and "a result".
pub const gutter: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x4a, 0x51, 0x70 } } };

/// The `│` that frames a code block. It was `brand_faint` (#3b4261, 1.9:1),
/// which made the ONE thing that says "this is a block" the least visible mark
/// in the UI. `hint_faint` is 3.4:1 and still recedes.
pub const code_gutter: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x65, 0x6d, 0x82 } } };
/// Chip with the block's language.
pub const code_lang: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x7a, 0x83, 0x99 } }, .italic = true };

// ── modal palette (Ctrl+P) ───────────────────────────────────

/// Unhighlighted item: normal text, not grey, so the list stays readable.
pub const item: vaxis.Style = .{};
/// Group heading ("Suggested", "Model", "Session"...).
pub const group: vaxis.Style = .{ .bold = true, .fg = .{ .rgb = .{ 0xbb, 0x9a, 0xf7 } } };
/// Highlighted row: accent bar + text in brand blue.
pub const item_sel: vaxis.Style = .{ .bold = true, .fg = .{ .rgb = .{ 0x7a, 0xa2, 0xf7 } } };

/// Width in columns of a grapheme (minimum 1), measured with whatever method
/// the terminal negotiated. `ctx` is the frame's DrawContext: if the width
/// doesn't match the one vaxis assumes when rendering, the cells misalign.
pub fn graphemeWidth(ctx: vxfw.DrawContext, g: []const u8) u8 {
    if (g.len == 0) return 1;
    const w = ctx.stringWidth(g);
    return @intCast(@max(1, w));
}

test "graphemeWidth: ascii=1, empty=1" {
    const ctx = vxfw.DrawContext{
        .arena = std.testing.allocator,
        .min = .{},
        .max = .{},
        .cell_size = .{},
    };
    try std.testing.expectEqual(@as(u8, 1), graphemeWidth(ctx, "a"));
    try std.testing.expectEqual(@as(u8, 1), graphemeWidth(ctx, ""));
    // Wide CJK: 2 columns. We don't assert the exact value because it depends
    // on the compiled Unicode tables; only that it is never 0 nor truncated.
    try std.testing.expect(graphemeWidth(ctx, "漢") >= 1);
}
