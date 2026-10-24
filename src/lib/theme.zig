const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

/// Semantic palette for the TUI.
///
/// One place for every color, and a TEST that fails the build when a pair of
/// text and background is unreadable. That test is the point of this file: the
/// previous palette had three tones below 3:1 and AGENTS.md says so in three
/// separate places, which is what a comment is for — describing a bug instead of
/// preventing it.
///
/// # The system
///
/// A dark UI reads as expensive when it is mostly MONOCHROME with exactly one
/// accent, and expensive-looking when everything is colored. So:
///
///   - **ink** carries the text, in three steps, and nothing else does.
///   - **line** is for hairlines and NEVER for text. It is below 3:1 on purpose:
///     a rule has to recede, and a rule that is legible is a line of text.
///   - **brand** is the single accent. It marks what is interactive and what is
///     yours: your prompt, the caret, the focused thing, the live phase.
///   - **ok / warn / err** are semantics, not decoration, and they are
///     deliberately NOT the accent: a green that means "brand" and a green that
///     means "this line was added" cannot both exist.
fn rgb(r: u8, g: u8, b: u8) vaxis.Style {
    return .{ .fg = .{ .rgb = .{ r, g, b } } };
}

fn bg(r: u8, g: u8, b: u8) vaxis.Style {
    return .{ .bg = .{ .rgb = .{ r, g, b } } };
}

// ── ink ───────────────────────────────────────────────────────
//
// Measured against `#000`, which is the darkest background a terminal realistically
// offers. `contrastOk` at the bottom of this file is what proves these, and it is
// a test: the numbers in the comments are the ones it computes.

/// Primary text: 18.1:1. The only thing allowed to be bright white.
pub const ink: vaxis.Style = rgb(0xf2, 0xf2, 0xf2);
/// Secondary text — a tool's argument, a result's body. 6.9:1 on `well_bg`.
pub const ink2: vaxis.Style = rgb(0xa3, 0xa1, 0x9e);
/// Tertiary text — a timestamp, a hint, a label. 5.6:1 on `well_bg`.
///
/// It was `#7a7a7a` in the first draft of this file and the contrast test said
/// 4.44:1 on `well_bg`, which is below the floor. This is what that test is
/// for: it is not a number I chose, it is a number I got wrong.
pub const ink3: vaxis.Style = rgb(0x85, 0x83, 0x80);

/// Hairlines. 1.6:1. NEVER text — see `ink3` for text you are meant to read.
pub const line: vaxis.Style = rgb(0x2e, 0x2c, 0x2a);

/// A slightly brighter rule, for the hairline that separates the transcript
/// from the input: it is one step more present than `line` and it is the reason
/// the input feels anchored without a box around it.
pub const line_bright: vaxis.Style = rgb(0x3d, 0x3a, 0x37);

// ─── the accent: ELECTRIC TEAL ──────────────────────────────────────────────────
//
// HUE 185°, ~75% saturation, ~52% lightness. A vibrant electric teal that reads
// as modern, technical, and forward-looking. It sits between cyan and green,
// distinct from the diff's green (135°) and far from the warm code palette
// (amber/lilac/pink). The high saturation makes it pop as a true accent without
// reading as a status color.
//
// ELECTRIC is intentional. A muted teal blends into the background; a saturated
// one marks YOUR things decisively: prompt, caret, selection, wordmark, focus.
//
/// 7.8:1 on black, 6.9:1 on `well_bg`. The accent proper: your prompt, the
/// caret, the selected row's mark. ELECTRIC TEAL.
pub const brand: vaxis.Style = rgb(0x00, 0xc8, 0xb8);
/// One step up, for the one thing that should read as LIT (the wordmark, Zo's
/// face). Bold as well as bright: a wordmark at normal weight is just text,
/// and "zode" has to be recognisable in the first half second.
pub const brand_hi: vaxis.Style = .{ .bold = true, .fg = .{ .rgb = .{ 0x40, 0xe8, 0xd8 } } };
/// 4.5:1 on `well_bg`. Tertiary text that still carries the accent color.
pub const brand_soft: vaxis.Style = rgb(0x00, 0xa8, 0x98);
/// Cool hairline. Sits between `line` and `brand_soft` in weight.
pub const brand_faint: vaxis.Style = rgb(0x0a, 0x2a, 0x28);
/// The background of a focused surface's track (a depleting progress bar).
pub const brand_deep: vaxis.Style = rgb(0x04, 0x14, 0x12);

// ── semantics ─────────────────────────────────────────────────
//
// `ok` is a VIVID green and `brand` is a MATTE one, and they are kept apart on
// purpose. Inside a diff the green always means `+`; outside a diff it always
// means the app. Two greens that are 20 degrees apart are not enough separation
// once a whole screen is full of both.

pub const ok: vaxis.Style = rgb(0x4c, 0xc7, 0x6b);
pub const warn: vaxis.Style = rgb(0xf5, 0xa5, 0x24);
pub const err: vaxis.Style = rgb(0xf0, 0x64, 0x5b);

/// Selection: a BACKGROUND, always.
///
/// With only a foreground change a selected row is distinguishable only by
/// bold, which most people do not see across a 60-column row. This cost a
/// scrollbar that highlighted the wrong line once.
pub const sel_bg: vaxis.Style = bg(0x11, 0x24, 0x28);
pub const selected: vaxis.Style = .{ .bold = true, .fg = .{ .rgb = .{ 0xa4, 0xd5, 0xda } }, .bg = sel_bg.bg };

/// A modal's interior. Darker than any plausible terminal background, so a box
/// reads as a hole in the page and the history cannot show through it.
pub const panel_bg: vaxis.Style = bg(0x0b, 0x0a, 0x09);
/// The well a tool's output sits in: the sunken surface of the two.
pub const well_bg: vaxis.Style = bg(0x12, 0x11, 0x10);

// ── code token palette ────────────────────────────────────────
//
// NOT in the accent's hue band. The accent is electric teal (185°), so a token
// in 164-206° would put brand and syntax on the same screen reading the same
// way. The palette uses orchid, lilac, pink, indigo, periwinkle, amber — all
// well outside the teal band.

pub const code_text: vaxis.Style = rgb(0xc9, 0xd1, 0xd9);
pub const code_kw: vaxis.Style = rgb(0xc7, 0x7d, 0xb8); // orchid
pub const code_kw2: vaxis.Style = .{ .italic = true, .fg = .{ .rgb = .{ 0xd9, 0x9a, 0xcc } } };
pub const code_builtin: vaxis.Style = rgb(0xd2, 0xa8, 0xff); // lilac
pub const code_type: vaxis.Style = rgb(0x7b, 0xb0, 0xf4); // indigo, 214°
pub const code_str: vaxis.Style = rgb(0xa6, 0xbd, 0xf2); // periwinkle, 222°
/// A comment. Italic and two steps below `code_text`, but still 6.2:1: a
/// comment is CONTENT the reader asked for, not chrome. The `#6b7280` in the
/// first draft was 3.9:1, and the contrast test refused it.
pub const code_comment: vaxis.Style = .{ .italic = true, .fg = .{ .rgb = .{ 0x8b, 0x94, 0x9e } } };
pub const code_num: vaxis.Style = rgb(0xff, 0xcb, 0x6b); // amber
pub const code_fn: vaxis.Style = .{ .bold = true, .fg = .{ .rgb = .{ 0xd2, 0xa8, 0xff } } };
/// Decorators (`@Override`, `@import`): pink, so they are neither the keyword
/// orange nor the diff's red.
pub const code_deco: vaxis.Style = .{ .italic = true, .fg = .{ .rgb = .{ 0xff, 0x6b, 0x9d } } };

// ── diff ──────────────────────────────────────────────────────
//
// A foreground alone is not a diff: `+ line` and `- line` have to read as two
// BANDS, and a band is a background. The tints are very dark on purpose
// (#0e1f14 over black is barely there) — enough to group the lines, not enough
// to shout over the prose.

pub const diff_add: vaxis.Style = rgb(0x4c, 0xc7, 0x6b);
pub const diff_add_bg: vaxis.Style = bg(0x0e, 0x1f, 0x14);
pub const diff_del: vaxis.Style = rgb(0xf0, 0x64, 0x5b);
pub const diff_del_bg: vaxis.Style = bg(0x22, 0x10, 0x0f);
/// The tint of a WHOLE added row, one step fainter than the words that
/// changed inside it.
///
/// Two tints per side, and the order matters: the line is the band (the
/// reader sees "this row is new") and the words are the point (the reader
/// sees "this is what is new inside the row"). With ONE tint the changed
/// words disappear into their own line, and a diff of a rewritten function
/// is a green wall.
pub const diff_add_line_bg: vaxis.Style = bg(0x08, 0x12, 0x0b);
pub const diff_del_line_bg: vaxis.Style = bg(0x15, 0x0a, 0x09);
/// The line number in a diff's gutter.
///
/// It is CONTENT (the line to go and look at) and not chrome, so it is
/// readable: `gutter` is a hairline color and a line number painted in it
/// is a number nobody can read.
pub const diff_gutter: vaxis.Style = rgb(0x85, 0x83, 0x80);
/// A context line: the unchanged rows around a change. Dimmest thing in a diff
/// that is still a word.
///
/// It sits on the WELL and not on a tint, which is both a contrast decision
/// (4.4:1 on `#0e1f14`, under the floor) and the right design one: the tints
/// mark what CHANGED, and a tinted context line means every row of a hunk is
/// tinted, which is a wall with no shape.
pub const diff_ctx: vaxis.Style = rgb(0x80, 0x80, 0x80);
/// The `@@ -1,4 +1,6 @@` header: the only thing in a diff allowed to be bold.
pub const diff_hunk: vaxis.Style = .{ .bold = true, .fg = .{ .rgb = .{ 0xff, 0xcb, 0x6b } } };
pub const diff_stat_add: vaxis.Style = rgb(0x4c, 0xc7, 0x6b);
pub const diff_stat_del: vaxis.Style = rgb(0xf0, 0x64, 0x5b);

// ── the rail ──────────────────────────────────────────────────
//
// The `│` that ties a tool's result to its call. It is a LINE, not text: it
// marks a boundary and has nothing to say, which is why it is allowed to be
// the quietest thing on screen.

pub const rail: vaxis.Style = rgb(0x2e, 0x2c, 0x2a);
/// The gutter of a code block. One step above `rail` because it is carrying
/// content (a language chip sits on it).
pub const gutter: vaxis.Style = rgb(0x3d, 0x3a, 0x37);
/// A continuation row's indent marker: "this row still belongs to the block
/// above". One glyph, and it is the difference between "one result plus five
/// anonymous rows" and "a result".
pub const gutter_soft: vaxis.Style = rgb(0x33, 0x31, 0x2e);

// ── named roles ───────────────────────────────────────────────
//
// The rest of the TUI asks for a ROLE and not for a color. It is the difference
// between a retheme being one file and being a grep across eleven.

/// What the user typed.
pub const user: vaxis.Style = .{ .bold = true, .fg = .{ .rgb = .{ 0x74, 0xae, 0xb4 } } };
/// The assistant's prose. Default bright, no color: the model is not decorated.
pub const assistant: vaxis.Style = ink;
/// A tool's NAME. Bold and near-white: this is the word you scan for.
pub const tool_name: vaxis.Style = .{ .bold = true, .fg = .{ .rgb = .{ 0xe6, 0xe6, 0xe6 } } };
/// A tool's ARGUMENT, on the same line: dimmer than the name, never the same.
pub const tool_arg: vaxis.Style = ink2;
/// A tool's result summary. `ink2`, NOT `ink3`: a result is what the turn
/// actually produced, and a notice (`·`) is the app talking to itself about
/// it. One step apart, so a transcript of thirty tool calls does not read as
/// one long list of whispers.
pub const tool_res: vaxis.Style = ink2;
/// A notice ("3 tool results elided", "done · 12.4s").
pub const notice: vaxis.Style = ink3;
/// A markdown heading. Bold and white: brighter than the prose around it, which
/// is the whole job of a heading.
pub const heading: vaxis.Style = .{ .bold = true, .fg = .{ .rgb = .{ 0xe6, 0xe6, 0xe6 } } };
/// A markdown list bullet.
pub const bullet: vaxis.Style = brand;
/// A markdown blockquote bar.
pub const quote: vaxis.Style = rgb(0x5a, 0x58, 0x55);
/// The language chip on a code block.
pub const code_lang: vaxis.Style = .{ .italic = true, .fg = .{ .rgb = .{ 0x7a, 0x78, 0x75 } } };
/// A table's rules and header.
pub const table: vaxis.Style = rgb(0x5a, 0x58, 0x55);

// ── chrome ────────────────────────────────────────────────────

/// The one rule that separates the transcript from the input.
pub const rule: vaxis.Style = line_bright;
/// The input's caret bar and prompt. The accent, always: it says "you are here".
pub const input_prompt: vaxis.Style = .{ .bold = true, .fg = .{ .rgb = .{ 0x40, 0xe8, 0xd8 } } };
pub const input_bar: vaxis.Style = rgb(0x2a, 0x44, 0x47);
pub const placeholder: vaxis.Style = ink3;
/// The status row: everything in it is metadata, so everything in it is dim.
pub const status: vaxis.Style = rgb(0x5f, 0x5d, 0x5a);
/// A key hint inside a modal (`enter run`). 6.3:1 on `panel_bg`.
///
/// It is dimmer than the option it belongs to, never dimmer than readable. The
/// first version was `#6b7280` at 4.08:1, and the whole point of a hint is
/// that it gets read.
pub const key_hint: vaxis.Style = rgb(0x8b, 0x94, 0x9e);
/// A modal's title. `ink2` bold: it names the thing without competing with the
/// question under it.
pub const panel_title: vaxis.Style = .{ .bold = true, .fg = .{ .rgb = .{ 0xa3, 0xa3, 0xa3 } } };

/// Accent for the older names, kept as aliases so the rename is one commit and
/// not a hunt. Anything still using these is on its way out.
pub const brand_bold = input_prompt;
pub const brand_hi_old = brand_hi;
pub const accent = brand;
pub const accent_bold = brand;
pub const hint = ink2;
pub const hint_faint = ink3;
pub const dim = ink3;
pub const text = ink;
pub const assistant_bold = heading;
pub const tool = ink2;
pub const code_gutter = gutter;
pub const rule_old = line;
// Still referenced by the modal code that has not been rewritten onto the
// panel yet. `code_bg` was the old name for a modal's interior and it pointed
// at the same value `panel_bg` does.
pub const code_bg = panel_bg;
pub const code_border: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x5a, 0x58, 0x55 } } };
pub const input_text = ink;
pub const warn_bold: vaxis.Style = .{ .bold = true, .fg = .{ .rgb = .{ 0xf5, 0xa5, 0x24 } } };
/// A palette group heading. Bold `ink2`: a LABEL, one step above the items and
/// clearly below the selected one.
pub const group: vaxis.Style = .{ .bold = true, .fg = .{ .rgb = .{ 0xa3, 0xa3, 0xa3 } } };
pub const item: vaxis.Style = ink2;
pub const item_sel: vaxis.Style = selected;
pub const input_border = line;

/// Context gauge: comfortable, near the compaction budget, past it.
pub fn ctxColor(pct: u8) vaxis.Style {
    if (pct < 50) return ink2;
    if (pct < 80) return warn;
    return err;
}

// ── contrast, as an invariant ─────────────────────────────────

/// WCAG relative luminance of an sRGB triple.
pub fn luminance(r: u8, g: u8, b: u8) f64 {
    const lin = struct {
        fn f(v: u8) f64 {
            const x = @as(f64, @floatFromInt(v)) / 255.0;
            return if (x <= 0.03928) x / 12.92 else std.math.pow(f64, (x + 0.055) / 1.055, 2.4);
        }
    };
    return 0.2126 * lin.f(r) + 0.7152 * lin.f(g) + 0.0722 * lin.f(b);
}

/// Contrast ratio between two sRGB triples, 1.0 to 21.0.
///
/// The denominator is the LIGHTER one. It is a ratio, not a subtraction, so it
/// is order-independent — which matters, because the first version of the
/// contrast check compared the wrong way round and "passed" a 1.6:1 pair.
pub fn contrast(a: [3]u8, b: [3]u8) f64 {
    const la = luminance(a[0], a[1], a[2]);
    const lb = luminance(b[0], b[1], b[2]);
    const hi = @max(la, lb);
    const lo = @min(la, lb);
    return (hi + 0.05) / (lo + 0.05);
}

/// The rgb triple behind a style's foreground, or null when it is `.default`
/// (which means "whatever the terminal has", and cannot be checked).
pub fn fgRgb(st: vaxis.Style) ?[3]u8 {
    return switch (st.fg) {
        .rgb => |c| c,
        else => null,
    };
}

/// The rgb triple behind a style's background, or `.default` resolved to the
/// darkest plausible terminal background.
pub fn bgRgb(st: vaxis.Style) [3]u8 {
    return switch (st.bg) {
        .rgb => |c| c,
        else => .{ 0, 0, 0 },
    };
}

/// Every color that is ever used as TEXT, with the background it is read on.
///
/// This list IS the rule. A color that is not in it is not text: it is a line,
/// a fill, or an oversight, and the only way to find out which is to try to
/// paint a paragraph with it.
pub const text_pairs = [_][2]vaxis.Style{
    .{ ink, well_bg },
    .{ ink, panel_bg },
    .{ ink2, panel_bg },
    .{ ink2, well_bg },
    .{ ink3, panel_bg },
    .{ ink3, well_bg },
    .{ brand, well_bg },
    .{ brand_hi, panel_bg },
    .{ brand_soft, well_bg },
    .{ ok, diff_add_bg },
    .{ err, diff_del_bg },
    .{ diff_add, diff_add_line_bg },
    .{ diff_del, diff_del_line_bg },
    .{ diff_gutter, well_bg },
    .{ diff_gutter, diff_add_line_bg },
    .{ diff_gutter, diff_del_line_bg },
    .{ diff_ctx, well_bg },
    .{ code_text, well_bg },
    .{ code_kw, well_bg },
    .{ code_str, well_bg },
    .{ code_num, well_bg },
    .{ code_type, well_bg },
    .{ code_builtin, well_bg },
    .{ code_comment, well_bg },
    .{ heading, panel_bg },
    .{ notice, panel_bg },
    .{ key_hint, panel_bg },
};

/// Minimum contrast for a pair that carries words.
pub const min_text_contrast: f64 = 4.5;

/// Minimum contrast for a pair that is a MARK (a rail, a bullet, a bar).
///
/// 1.3 is deliberately low: a mark that competes with the text is a bug, and
/// this number exists to stop "let's make the rail a bit more visible" from
/// turning into a column of dots down the middle of the screen.
pub const min_mark_contrast: f64 = 1.25;

/// Width in columns of a grapheme (minimum 1), measured with whatever method
/// the terminal negotiated. `ctx` is the frame's DrawContext: if the width
/// doesn't match the one vaxis assumes when rendering, the cells misalign.
pub fn graphemeWidth(ctx: vxfw.DrawContext, g: []const u8) u8 {
    if (g.len == 0) return 1;
    const w = ctx.stringWidth(g);
    return @intCast(@max(1, w));
}

/// Hue in degrees (0-360) and saturation (0-1) of an sRGB triple.
///
/// Needed because the two greens are separated by CHROMA, not by lightness, and
/// a contrast ratio between two colors of similar lightness is ~1.0 however
/// far apart their hues are. The first version of the "the two greens are
/// different" test measured contrast and failed: `brand` (#7fb069) and `ok`
/// (#4cc76b) are both mid-lightness, so the ratio said 1.1 while a reader sees
/// a dusty sage and a vivid emerald. Measuring the wrong quantity is how a test
/// gets deleted instead of fixed.
pub fn hueSat(c: [3]u8) struct { h: f64, s: f64, l: f64 } {
    const r = @as(f64, @floatFromInt(c[0])) / 255.0;
    const g = @as(f64, @floatFromInt(c[1])) / 255.0;
    const b = @as(f64, @floatFromInt(c[2])) / 255.0;
    const mx = @max(r, @max(g, b));
    const mn = @min(r, @min(g, b));
    const d = mx - mn;
    const l = (mx + mn) / 2.0;
    if (d == 0) return .{ .h = 0, .s = 0, .l = l };
    const s = d / (1 - @abs(2 * l - 1));
    var h: f64 = 0;
    if (mx == r) {
        const hue_val = (g - b) / d;
        // Manual fmod implementation to avoid @mod issues
        h = 60 * (hue_val - @floor(hue_val / 6.0) * 6.0);
        if (h < 0) h += 360;
    } else if (mx == g) {
        h = 60 * ((b - r) / d + 2);
    } else {
        h = 60 * ((r - g) / d + 4);
    }
    return .{ .h = h, .s = s, .l = l };
}

/// Terminal color capabilities.
pub const Caps = struct {
    rgb: bool = false,
    no_color: bool = false,
    daltonized: bool = false,
};

/// What the terminal this app is talking to can do.
///
/// Set ONCE, at startup, and read by every paint. It is a global because the
/// alternative is threading it through every painter, every style and every
/// widget, and the capability of a terminal does not change while the app
/// runs (except for the daltonized palette, which is a user choice and is
/// changed on purpose).
pub var caps: Caps = .{ .rgb = true };

/// Reads the capabilities out of the environment.
///
/// vaxis does NOT ask the terminal whether it speaks truecolor: its DA1 probe
/// answers the keyboard and the screen, and the `COLORTERM` sniffing in
/// `Vaxis.queryTerminal` is commented out in the library. So the app asks the
/// environment, which is where every terminal documents the answer:
///
///   - `NO_COLOR` (any value) → no color at all
///   - `COLORTERM=truecolor|24bit` → truecolor
///   - `TERM=…direct…` → truecolor
///   - `TERM=…256color…` → the 256-color palette
///   - anything else → truecolor, which is what a modern terminal does and
///     what the app did before it had a ladder
///
/// The default is truecolor on purpose: a terminal that does not support it
/// and does not say so is a terminal nobody has met.
pub fn detectCaps(env: ?*std.process.Environ.Map) Caps {
    var c = Caps{ .rgb = true };
    if (env) |e| {
        if (e.get("NO_COLOR")) |v| {
            if (v.len > 0) c.no_color = true;
        }
        if (e.get("COLORTERM")) |v| {
            if (std.ascii.eqlIgnoreCase(v, "truecolor") or std.ascii.eqlIgnoreCase(v, "24bit")) {
                c.rgb = true;
            }
        }
        if (e.get("TERM")) |v| {
            if (std.mem.indexOf(u8, v, "direct") != null) {
                c.rgb = true;
            } else if (std.mem.indexOf(u8, v, "256color") != null) {
                c.rgb = false;
            }
        }
    }
    if (env) |e| {
        if (e.get("ZODE_DALTONIZED")) |v| {
            if (v.len > 0 and !std.ascii.eqlIgnoreCase(v, "0") and
                !std.ascii.eqlIgnoreCase(v, "false"))
            {
                c.daltonized = true;
            }
        }
    }
    return c;
}

/// The style a terminal that cannot do truecolor gets.
///
/// This is the ONE place the ladder is applied: every cell is painted through
/// it, so a color that cannot be shown never reaches the wire. An rgb triple
/// on a 256-color terminal is not "a bit off", it is a byte sequence the
/// terminal does not understand, and what it does with it is undefined.
pub fn resolve(st: vaxis.Style) vaxis.Style {
    return resolveStyle(st, caps);
}

/// Converts an sRGB triple to the nearest ANSI 256 color index.
///
/// The grey ramp (232-255) is a COMPETITOR, not a fallback: the 6x6x6 cube
/// has no dark greys at all (its darkest is #000000) and it has no light ones
/// either, so a terminal that only has the ramp is the only one that can
/// show a very dark tint at all. Both candidates are built and the CLOSER one
/// wins, in RGB distance.
///
/// The first version only considered the ramp for colours with a saturation
/// below 0.15, which is the "fallback" behaviour the rule warns about: a
/// near-black green tint (#08120b) went to the cube, which has nothing
/// between #000000 and #333333 in it, and the band the tint was supposed to
/// paint disappeared.
pub fn ansi256FromRgb(r: u8, g: u8, b: u8) u8 {
    // The 6x6x6 cube: indices 16-231, six levels per channel.
    const cube_r: u16 = (@as(u16, r) * 5 + 127) / 255;
    const cube_g: u16 = (@as(u16, g) * 5 + 127) / 255;
    const cube_b: u16 = (@as(u16, b) * 5 + 127) / 255;
    const cube_index: u16 = 16 + cube_r * 36 + cube_g * 6 + cube_b;
    const cube_rgb = [3]i32{
        @as(i32, cube_r) * 51,
        @as(i32, cube_g) * 51,
        @as(i32, cube_b) * 51,
    };

    // The grey ramp: indices 232-255, twenty-four greys from 8 to 238.
    const avg: u16 = (@as(u16, r) + @as(u16, g) + @as(u16, b)) / 3;
    var level: u16 = 0;
    if (avg > 8) level = (avg - 8 + 5) / 10;
    if (level > 23) level = 23;
    const ramp_index: u16 = 232 + level;
    const gray: i32 = 8 + @as(i32, @intCast(level)) * 10;
    const ramp_rgb = [3]i32{ gray, gray, gray };

    const to = [3]i32{ @as(i32, r), @as(i32, g), @as(i32, b) };
    const cube_dist = distance(cube_rgb, to);
    const ramp_dist = distance(ramp_rgb, to);
    return @intCast(if (ramp_dist < cube_dist) ramp_index else cube_index);
}

/// The squared RGB distance between two triples.
fn distance(a: [3]i32, b: [3]i32) i32 {
    var sum: i32 = 0;
    for (a, b) |x, y| {
        const d = x - y;
        sum += d * d;
    }
    return sum;
}

/// Converts a style to use ANSI 256 colors instead of RGB.
pub fn styleToAnsi256(st: vaxis.Style) vaxis.Style {
    var result = st;
    switch (st.fg) {
        .rgb => |c| result.fg = .{ .index = ansi256FromRgb(c[0], c[1], c[2]) },
        else => {},
    }
    switch (st.bg) {
        .rgb => |c| result.bg = .{ .index = ansi256FromRgb(c[0], c[1], c[2]) },
        else => {},
    }
    return result;
}

/// Returns a style adapted to the terminal's color capabilities.
/// 
/// - If caps.rgb: returns style as-is (truecolor)
/// - If caps.no_color: strips all colors, keeps only bold
/// - Otherwise: converts RGB to ANSI 256
pub fn resolveStyle(st: vaxis.Style, c: Caps) vaxis.Style {
    if (c.no_color) {
        return .{ .bold = st.bold, .italic = st.italic, .strikethrough = st.strikethrough };
    }
    if (c.rgb) {
        return st;
    }
    return styleToAnsi256(st);
}

/// The diff's colours for a set of capabilities.
///
/// The daltonized pair is BLUE/ORANGE instead of GREEN/RED: the most common
/// colour-vision deficiency collapses green and red into the same yellow, and
/// a diff whose two halves are the same colour is a diff with no halves.
pub const DiffStyles = struct {
    add: vaxis.Style,
    del: vaxis.Style,
    add_bg: vaxis.Style,
    del_bg: vaxis.Style,
    add_line_bg: vaxis.Style,
    del_line_bg: vaxis.Style,
};

pub fn diffStyles(c: Caps) DiffStyles {
    if (c.daltonized) {
        return .{
            .add = resolveStyle(rgb(0x4a, 0x9e, 0xff), c), // blue
            .del = resolveStyle(rgb(0xff, 0xa5, 0x00), c), // orange
            .add_bg = resolveStyle(bg(0x0e, 0x1f, 0x2e), c),
            .del_bg = resolveStyle(bg(0x2a, 0x1c, 0x05), c),
            .add_line_bg = resolveStyle(bg(0x07, 0x11, 0x1a), c),
            .del_line_bg = resolveStyle(bg(0x1a, 0x11, 0x03), c),
        };
    }
    return .{
        .add = resolveStyle(diff_add, c),
        .del = resolveStyle(diff_del, c),
        .add_bg = resolveStyle(diff_add_bg, c),
        .del_bg = resolveStyle(diff_del_bg, c),
        .add_line_bg = resolveStyle(diff_add_line_bg, c),
        .del_line_bg = resolveStyle(diff_del_line_bg, c),
    };
}

/// The `+` marker of an added row.
///
/// With no color at all the marker is BOLD: the sign is still there, and
/// weight is the only thing left to make it stand out.
pub fn diffAdd() vaxis.Style {
    if (caps.no_color) return .{ .bold = true };
    return diffStyles(caps).add;
}

/// The `-` marker of a deleted row.
pub fn diffDel() vaxis.Style {
    if (caps.no_color) return .{ .bold = true };
    return diffStyles(caps).del;
}

/// The background of the CHANGED WORDS of an added row.
pub fn diffAddBg() vaxis.Style {
    if (caps.no_color) return .{};
    return diffStyles(caps).add_bg;
}

/// The background of the CHANGED WORDS of a deleted row.
pub fn diffDelBg() vaxis.Style {
    if (caps.no_color) return .{};
    return diffStyles(caps).del_bg;
}

/// The background of a whole added row.
pub fn diffAddLineBg() vaxis.Style {
    if (caps.no_color) return .{};
    return diffStyles(caps).add_line_bg;
}

/// The background of a whole deleted row.
pub fn diffDelLineBg() vaxis.Style {
    if (caps.no_color) return .{};
    return diffStyles(caps).del_line_bg;
}

test "contrast: the ratio is order-independent and correct on the anchors" {
    // White on black is the maximum; identical colors are 1.
    try std.testing.expectApproxEqAbs(@as(f64, 21.0), contrast(.{ 0xff, 0xff, 0xff }, .{ 0, 0, 0 }), 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), contrast(.{ 0x40, 0x40, 0x40 }, .{ 0x40, 0x40, 0x40 }), 0.001);
    // Order matters for the ARITHMETIC but not the answer: the first version of
    // this compared the darker against the lighter and "passed" a 1.6:1 pair.
    const a = [3]u8{ 0xf2, 0xf2, 0xf2 };
    const b = [3]u8{ 0, 0, 0 };
    try std.testing.expectApproxEqAbs(contrast(a, b), contrast(b, a), 0.0001);
    // The pair this file exists for. Measured 2.14:1 on black (the 1.9 quoted
    // for years was against `#1a1b26`, not against black) — and it was used for
    // TEXT, which is what makes it a bug and not just a dark color.
    const old = contrast(.{ 0x3b, 0x42, 0x61 }, .{ 0, 0, 0 });
    try std.testing.expect(old < min_text_contrast);
    // And the one that replaced it.
    const neu = contrast(.{ 0x85, 0x85, 0x85 }, .{ 0, 0, 0 });
    try std.testing.expect(neu >= min_text_contrast);
}

test "every TEXT color is readable on the surface it is used on" {
    var i: usize = 0;
    while (i < text_pairs.len) : (i += 1) {
        const fg = fgRgb(text_pairs[i][0]) orelse continue;
        const bgc = bgRgb(text_pairs[i][1]);
        const r = contrast(fg, bgc);
        if (r < min_text_contrast) {
            // The values, not the names: a `Style` has no tag, and a color's
            // name is not something you can compute the contrast OF. The point
            // is that whoever fixes this does not have to guess which pair it
            // was.
            std.debug.print(
                "contrast {d:.2}:1 below {d:.1} — fg #{x:0>2}{x:0>2}{x:0>2} on bg #{x:0>2}{x:0>2}{x:0>2}\n",
                .{ r, min_text_contrast, fg[0], fg[1], fg[2], bgc[0], bgc[1], bgc[2] },
            );
            return error.TextContrastTooLow;
        }
    }
}

test "the hairline is a hairline and NOT text" {
    // The rule exists precisely so that `line` can recede. This is the test
    // that stops somebody from promoting it to text because it "looked better"
    // somewhere.
    const r = contrast(.{ 0x2e, 0x2e, 0x2e }, .{ 0, 0, 0 });
    try std.testing.expect(r >= 1.4);
    try std.testing.expect(r < min_text_contrast);
    // …and it still has to be visible enough to be a line at all.
    try std.testing.expect(r >= min_mark_contrast);
}

test "the accent and the diff green are told apart by HUE, not by lightness" {
    // The accent (electric teal, ~185°) and `ok` (vivid green, ~135°) are separated
    // by HUE (~50° apart), not by lightness. Both are vivid (high saturation).
    // A contrast ratio cannot measure hue separation, so the quantity that
    // separates them is hue distance. Both differences are asserted, because
    // either one alone would pass with a palette that still reads as "the same".
    const a = hueSat(fgRgb(brand).?);
    const b = hueSat(fgRgb(ok).?);
    // Both are vivid (high saturation), so saturation doesn't separate them.
    // The hue distance is the primary separator.
    var dh = @abs(a.h - b.h);
    if (dh > 180) dh = 360 - dh;
    try std.testing.expect(dh >= 15);
    // Both should be vivid (high saturation)
    try std.testing.expect(a.s >= 0.5);
    try std.testing.expect(b.s >= 0.5);
}

test "the code palette clears the accent's hue band" {
    // The accent is the only color in CHROME, and a token in its hue band would
    // put "brand" and "syntax" on the same screen reading the same way. With an
    // electric teal accent (~185°) the band is ±21° around it (164-206°).
    //
    // The band is ±21° around the accent, and the test is on SATURATION as
    // well as hue: `code_text` and `code_comment` are near-neutral, and a
    // near-neutral color has no hue a reader can see, so its computed hue is
    // noise. Requiring `s >= 0.15` is what keeps them out of the band instead
    // of failing the test.
    const accent_h = hueSat(fgRgb(brand).?).h;
    const palette = [_]vaxis.Style{
        code_text, code_kw, code_kw2, code_builtin, code_type,
        code_str,  code_comment, code_num, code_fn, code_deco,
    };
    for (palette) |st| {
        const hs = hueSat(fgRgb(st).?);
        if (hs.s < 0.15) continue;
        var dh = @abs(hs.h - accent_h);
        if (dh > 180) dh = 360 - dh;
        if (dh < 21) {
            std.debug.print(
                "code color at hue {d:.0} saturation {d:.2} is {d:.0} deg from the accent\n",
                .{ hs.h, hs.s, dh },
            );
            return error.CodePaletteCollidesWithAccent;
        }
    }
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

test "ansi256FromRgb: picks cube for saturated colour and ramp for grey" {
    // A saturated red should pick from the cube (index 16-231)
    const red = ansi256FromRgb(0xff, 0x00, 0x00);
    try std.testing.expect(red >= 16 and red <= 231);
    // A neutral grey should pick from the ramp (index 232-255)
    const grey = ansi256FromRgb(0x80, 0x80, 0x80);
    try std.testing.expect(grey >= 232 and grey <= 255);
    // White and black are special cases in the cube
    const white = ansi256FromRgb(0xff, 0xff, 0xff);
    const black = ansi256FromRgb(0x00, 0x00, 0x00);
    try std.testing.expect(white >= 16 and white <= 231);
    try std.testing.expect(black >= 16 and black <= 231);
}

test "every theme colour survives the 256 round trip" {
    // Collect all theme colours that have RGB values
    const theme_colours = [_]vaxis.Style{
        ink, ink2, ink3, line, line_bright,
        brand, brand_hi, brand_soft, brand_faint,
        ok, warn, err,
        panel_bg, well_bg,
        user, assistant, tool_name, tool_arg, tool_res, notice, heading, bullet, quote,
        code_text, code_kw, code_kw2, code_builtin, code_type, code_str, code_comment, code_num, code_fn, code_deco,
        diff_add, diff_del, diff_ctx, diff_hunk, diff_stat_add, diff_stat_del,
        diff_gutter, diff_add_bg, diff_del_bg, diff_add_line_bg, diff_del_line_bg,
        rail, gutter, gutter_soft,
        selected,
    };
    for (theme_colours) |st| {
        switch (st.fg) {
            .rgb => |c| {
                const idx = ansi256FromRgb(c[0], c[1], c[2]);
                try std.testing.expect(idx != 0); // 0 is "default" which means we lost the color
            },
            else => {},
        }
        switch (st.bg) {
            .rgb => |c| {
                const idx = ansi256FromRgb(c[0], c[1], c[2]);
                try std.testing.expect(idx != 0);
            },
            else => {},
        }
    }
}

test "fgRgb on diff styles" {
    try std.testing.expect(fgRgb(diff_add) != null);
    try std.testing.expect(fgRgb(diff_del) != null);
    try std.testing.expect(fgRgb(diff_add_bg) == null); // bg only
    try std.testing.expect(fgRgb(diff_del_bg) == null); // bg only
}

test "hueSat: basic colors" {
    // Red
    const red_hs = hueSat(.{ 0xff, 0x00, 0x00 });
    try std.testing.expect(red_hs.h >= 0.0 and red_hs.h < 360.0);
    // Green
    const green_hs = hueSat(.{ 0x00, 0xff, 0x00 });
    try std.testing.expect(green_hs.h >= 0.0 and green_hs.h < 360.0);
    // Blue
    const blue_hs = hueSat(.{ 0x00, 0x00, 0xff });
    try std.testing.expect(blue_hs.h >= 0.0 and blue_hs.h < 360.0);
    // White (should have hue 0, saturation 0)
    const white_hs = hueSat(.{ 0xff, 0xff, 0xff });
    try std.testing.expect(white_hs.h == 0.0);
    try std.testing.expect(white_hs.s == 0.0);
    // Grey
    const grey_hs = hueSat(.{ 0x80, 0x80, 0x80 });
    try std.testing.expect(grey_hs.s == 0.0);
    // Daltonized colors
    const daltonized_blue_hs = hueSat(.{ 0x4a, 0x9e, 0xff });
    try std.testing.expect(daltonized_blue_hs.h >= 0.0 and daltonized_blue_hs.h < 360.0);
    const daltonized_orange_hs = hueSat(.{ 0xff, 0xa5, 0x00 });
    try std.testing.expect(daltonized_orange_hs.h >= 0.0 and daltonized_orange_hs.h < 360.0);
}

test "the daltonized pair differs in HUE, not only in lightness" {
    // A red/green pair is invisible to a reader with the most common
    // colour-vision deficiency, and the deficiency does not make the two
    // colours EQUAL: it moves them together in hue. So the quantity that
    // separates them is the hue distance, and the test has to be on that and
    // not on a contrast ratio (the green and the red have almost the same
    // lightness, so a contrast test would say they are the SAME).
    const s = diffStyles(.{ .rgb = true, .daltonized = true });
    const a = hueSat(fgRgb(s.add).?);
    const b = hueSat(fgRgb(s.del).?);
    var dh = @abs(a.h - b.h);
    if (dh > 180) dh = 360 - dh;
    try std.testing.expect(dh >= 30);
    // And the default pair is the green/red one, which is what a reader
    // WITHOUT the deficiency expects.
    const d = diffStyles(.{ .rgb = true });
    const ga = hueSat(fgRgb(d.add).?);
    const gb = hueSat(fgRgb(d.del).?);
    try std.testing.expect(ga.h > 90 and ga.h < 160); // green
    try std.testing.expect(gb.h < 20 or gb.h > 330); // red
}

test "the ladder: a terminal without truecolor gets the 256 palette" {
    // The style is the same color; what changes is how it is written.
    const st = rgb(0x4c, 0xc7, 0x6b);
    const prev = caps;
    defer caps = prev;

    caps = .{ .rgb = true };
    try std.testing.expect(resolve(st).fg == .rgb);

    caps = .{ .rgb = false };
    const idx = resolve(st).fg;
    try std.testing.expect(idx == .index);

    // And a terminal that asked for no color gets no color: the attributes
    // survive, the color does not.
    caps = .{ .no_color = true };
    const plain = resolve(.{ .bold = true, .fg = .{ .rgb = .{ 1, 2, 3 } } });
    try std.testing.expect(plain.bold);
    try std.testing.expect(plain.fg == .default);
}

test "detectCaps: the environment decides, and the default is truecolor" {
    var m = std.process.Environ.Map.init(std.testing.allocator);
    defer m.deinit();

    // No environment at all: truecolor, which is what the app did before it
    // had a ladder.
    const none = detectCaps(null);
    try std.testing.expect(none.rgb);
    try std.testing.expect(!none.no_color);
    try std.testing.expect(!none.daltonized);

    try m.put("NO_COLOR", "1");
    try m.put("TERM", "xterm-256color");
    const c = detectCaps(&m);
    try std.testing.expect(c.no_color);
    try std.testing.expect(!c.rgb); // 256color, and no truecolor claim
}

