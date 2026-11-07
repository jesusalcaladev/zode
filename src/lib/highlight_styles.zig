const std = @import("std");
const vaxis = @import("vaxis");
const theme = @import("theme.zig");

const Style = vaxis.Style;

// ── token styles ───────────────────────────────────────────────
//
// They used to live here as hardcoded xterm-256 indexes and did NOT import `theme.zig`:
// the header went in the brand blue and the code block in 256, i.e. two
// different color systems on the same screen. Now they come from `theme.zig`
// in truecolor, with vaxis falling back to the closest ANSI index.
//
// What shows up the most is `def`: it was `Style{}`, that is the terminal's
// default color, which is the BRIGHTEST thing on the screen, and it covers
// ~90% of the lines of code. The whole block was the loudest point.
pub const T = struct {
    pub const kw = theme.code_kw;
    pub const kw2 = theme.code_kw2;
    pub const builtin = theme.code_builtin;
    pub const typ = theme.code_type;
    pub const str = theme.code_str;
    pub const comment = theme.code_comment;
    pub const num = theme.code_num;
    pub const fn_call = theme.code_fn;
    pub const deco = theme.code_deco;
    pub const def = theme.code_text;
};

pub const Kinds = enum { none, kw, kw2, builtin, typ, str, comment, num, fn_call, deco };

pub fn styleFor(kind: Kinds) Style {
    return switch (kind) {
        .none => T.def,
        .kw => T.kw,
        .kw2 => T.kw2,
        .builtin => T.builtin,
        .typ => T.typ,
        .str => T.str,
        .comment => T.comment,
        .num => T.num,
        .fn_call => T.fn_call,
        .deco => T.deco,
    };
}
