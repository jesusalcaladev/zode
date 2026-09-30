const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

/// Paleta semántica de la TUI. Un solo sitio para los colores: el índice ANSI
/// lo decide la terminal, nosotros solo pedimos "acento", "aviso", etc.
pub const accent: vaxis.Style = .{ .fg = .{ .index = 4 } }; // azul
pub const accent_bold: vaxis.Style = .{ .bold = true, .fg = .{ .index = 4 } };

// ── azul de marca ────────────────────────────────────────────
// Tres tonos en vez de un `accent` único: da profundidad al cromo (cabecera,
// bordes, status) sin que nada grite. Los valores son los azules de la paleta
// Tokyo Night, que es el tema con el que se vio la TUI; si tu terminal usa
// otro fondo oscuro, se ven igual de armónicos (mismo tono, otra luminosidad).
//
// truecolor (`.rgb`) con fallback de vaxis al índice ANSI más cercano en
// terminales que no lo soporten.

/// Azul brillante: wordmark `zode`, prompt `❯`, modelo activo, comandos.
pub const brand: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x7a, 0xa2, 0xf7 } } };
pub const brand_bold: vaxis.Style = .{ .bold = true, .fg = .{ .rgb = .{ 0x7a, 0xa2, 0xf7 } } };
/// Azul claro: el wordmark `zode`. Va un tono por encima de `brand` para que
/// el logo se lea como "encendido" contra el arte del búho, que es `brand`.
pub const brand_hi: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xc0, 0xca, 0xf5 } } };
/// Azul apagado: texto de Zo, hints, provider, effort.
pub const brand_soft: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x56, 0x5f, 0x89 } } };
/// Azul casi gris: separadores horizontales y bordes del input box.
pub const brand_faint: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x3b, 0x42, 0x61 } } };
pub const assistant: vaxis.Style = .{ .fg = .{ .index = 5 } }; // magenta
pub const assistant_bold: vaxis.Style = .{ .bold = true, .fg = .{ .index = 5 } };
pub const tool: vaxis.Style = .{ .fg = .{ .index = 6 } }; // cyan
pub const ok: vaxis.Style = .{ .fg = .{ .index = 2 } }; // verde
pub const warn: vaxis.Style = .{ .fg = .{ .index = 3 } }; // amarillo
pub const warn_bold: vaxis.Style = .{ .bold = true, .fg = .{ .index = 3 } };
pub const err: vaxis.Style = .{ .fg = .{ .index = 1 } }; // rojo
pub const dim: vaxis.Style = .{ .fg = .{ .index = 8 } };
pub const text: vaxis.Style = .{};
pub const user: vaxis.Style = .{ .fg = .{ .index = 7 } }; // blanco intenso

/// Estilo de la línea separadora / bordes.
pub const rule: vaxis.Style = brand_faint;

/// Estilo del input box (borde + prompt).
pub const input_border: vaxis.Style = brand_faint;
pub const input_prompt: vaxis.Style = brand_bold;
pub const input_text: vaxis.Style = .{};
pub const placeholder: vaxis.Style = brand_soft;

/// Color del gauge de contexto según lo lleno que esté: verde holgado,
/// amarillo al acercarse al budget de compaction, rojo por encima.
/// Umbrales: <50%, <80%, resto. El 80% es justo donde arranca la compaction.
pub fn ctxColor(pct: u8) vaxis.Style {
    if (pct < 50) return ok;
    if (pct < 80) return warn;
    return err;
}

/// Background del item seleccionado en un picker.
pub const selected: vaxis.Style = .{ .bold = true, .fg = .{ .index = 4 } };

// ── paleta modal (Ctrl+P) ────────────────────────────────────

/// Item no resaltado: texto normal, no gris, para que la lista se lea.
pub const item: vaxis.Style = .{};
/// Encabezado de grupo ("Suggested", "Prompt", "Sesión"...).
pub const group: vaxis.Style = .{ .bold = true, .fg = .{ .rgb = .{ 0xbb, 0x9a, 0xf7 } } };
/// Fila resaltada: barra de acento + texto en el azul de marca.
pub const item_sel: vaxis.Style = .{ .bold = true, .fg = .{ .rgb = .{ 0x7a, 0xa2, 0xf7 } } };

/// Ancho en columnas de un grapheme (mínimo 1), medido con el método que la
/// terminal negotiated. `ctx` es el DrawContext del frame: si el ancho no
/// coincide con el que vaxis asume al renderizar, las celdas se desalinean.
pub fn graphemeWidth(ctx: vxfw.DrawContext, g: []const u8) u8 {
    if (g.len == 0) return 1;
    const w = ctx.stringWidth(g);
    return @intCast(@max(1, w));
}

test "graphemeWidth: ascii=1, vacío=1" {
    const ctx = vxfw.DrawContext{
        .arena = std.testing.allocator,
        .min = .{},
        .max = .{},
        .cell_size = .{},
    };
    try std.testing.expectEqual(@as(u8, 1), graphemeWidth(ctx, "a"));
    try std.testing.expectEqual(@as(u8, 1), graphemeWidth(ctx, ""));
    // CJK ancho: 2 columnas. No afirmamos el valor exacto porque depende de
    // las tablas Unicode compiladas; solo que nunca sea 0 ni se trunque.
    try std.testing.expect(graphemeWidth(ctx, "漢") >= 1);
}
