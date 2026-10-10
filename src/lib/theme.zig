const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

/// Modern vibrant theme inspired by Claude Code
pub const accent: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xb4, 0x5d, 0xff } } }; // Electric violet
pub const accent_bold: vaxis.Style = .{ .bold = true, .fg = .{ .rgb = .{ 0xb4, 0x5d, 0xff } } };

/// Brand - vibrant violet/cyan palette
pub const brand: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xb4, 0x5d, 0xff } } }; // Electric violet
pub const brand_bold: vaxis.Style = .{ .bold = true, .fg = .{ .rgb = .{ 0xd4, 0x9b, 0xff } } };
pub const brand_hi: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xe0, 0xb4, 0xff } } };
pub const brand_soft: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x8b, 0x7b, 0xb8 } } };
pub const brand_faint: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x5d, 0x57, 0x7a } } };

/// Accent colors - bright cyan for assistant
pub const assistant: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x22, 0xd3, 0xee } } }; // Bright cyan
pub const assistant_bold: vaxis.Style = .{ .bold = true, .fg = .{ .rgb = .{ 0x22, 0xd3, 0xee } } };
pub const tool: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xa5, 0xb4, 0xfc } } }; // Soft indigo

pub const hint: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x94, 0x9a, 0xb2 } } };
pub const hint_faint: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x6c, 0x75, 0x8f } } };

/// Selection - more vibrant
pub const sel_bg: vaxis.Style = .{ .bg = .{ .rgb = .{ 0x3b, 0x2d, 0x6d } } };
pub const ok: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x86, 0xef, 0xac } } }; // Green-400
pub const warn: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xfd, 0xd9, 0x87 } } }; // Amber-300
pub const warn_bold: vaxis.Style = .{ .bold = true, .fg = .{ .rgb = .{ 0xfd, 0xd9, 0x87 } } };
pub const err: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xf8, 0xa8, 0xa8 } } }; // Red-300
pub const dim: vaxis.Style = .{ .fg = .{ .index = 8 } };
pub const text: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xc9, 0xd1, 0xd9 } } }; // Slate-300
pub const user: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x9b, 0xa3, 0xaf } } }; // Slate-400

pub const rule: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x4a, 0x47, 0x65 } } };

/// Input area - clean modern
pub const input_border: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x6b, 0x5b, 0x9b } } };
pub const input_border_active: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xb4, 0x5d, 0xff } } };
pub const input_prompt: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xb4, 0x5d, 0xff } } };
pub const input_text: vaxis.Style = .{};
pub const placeholder: vaxis.Style = hint_faint;

pub fn ctxColor(pct: u8) vaxis.Style {
    if (pct < 50) return ok;
    if (pct < 80) return warn;
    return err;
}

pub const selected: vaxis.Style = .{ .bold = true, .fg = .{ .rgb = .{ 0xf8, 0xf9, 0xfa } }, .bg = sel_bg.bg };

/// Code - modern syntax highlighting
pub const code_text: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xe1, 0xe6, 0xed } } };
pub const code_kw: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xb4, 0x5d, 0xff } } }; // Violet
pub const code_kw2: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xb4, 0x5d, 0xff } }, .italic = true };
pub const code_builtin: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x22, 0xd3, 0xee } } }; // Cyan
pub const code_type: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x5d, 0xe1, 0xd4 } } }; // Teal
pub const code_str: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x86, 0xef, 0xac } } }; // Green
pub const code_comment: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x6b, 0x73, 0x8e } }, .italic = true };
pub const code_num: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xfd, 0xd9, 0x87 } } }; // Yellow
pub const code_fn: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x93, 0xc5, 0xfd } } }; // Blue
pub const code_deco: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x22, 0xd3, 0xee } }, .italic = true };

/// Diff
pub const diff_add: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x86, 0xef, 0xac } } };
pub const diff_del: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xf8, 0xa8, 0xa8 } } };
pub const diff_ctx: vaxis.Style = code_comment;

pub const code_bg: vaxis.Style = .{ .bg = .{ .rgb = .{ 0x11, 0x11, 0x1f } } };
pub const gutter: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x3d, 0x42, 0x5c } } };
pub const code_gutter: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x4a, 0x4f, 0x69 } } };
pub const code_lang: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x6c, 0x75, 0x8f } }, .italic = true };

/// Palette
pub const item: vaxis.Style = .{};
pub const group: vaxis.Style = .{ .bold = true, .fg = .{ .rgb = .{ 0xb4, 0x5d, 0xff } } };
pub const item_sel: vaxis.Style = .{ .bold = true, .fg = .{ .rgb = .{ 0xf8, 0xf9, 0xfa } }, .bg = sel_bg.bg };

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
    try std.testing.expect(graphemeWidth(ctx, "漢") >= 1);
}
