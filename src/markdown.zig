const std = @import("std");
const vaxis = @import("vaxis");
const hl = @import("highlight.zig");
const theme = @import("theme.zig");

pub const Style = vaxis.Style;

/// Segmento de texto con estilo: la unidad de render del historial.
pub const Segment = struct {
    text: []const u8,
    style: Style,
};

pub const Kind = enum {
    user,
    assistant,
    info,
    tool,
    /// Línea de cabecera de una tool en curso: "⏺ Read(src/tui.zig)"
    tool_run,
    /// Línea de resultado de una tool: "⎿  Read 1006 lines · 3ms"
    tool_res,
    /// Diff unificado: líneas con `+`/`-`/` ` (coloreadas por el prefijo).
    diff,
    /// Bloque de cabecera (banner del búho + línea de Zo). Azul de marca en vez
    /// del gris de `.info`, y con `*texto*` pinta en el brillo del wordmark.
    banner,
    error_msg,
    code,
    separator,
};

/// Bloque visual del historial: ya parseado y con estilos.
/// `lines` son segmentos por línea SIN wrap (el wrap es en el draw).
pub const Block = struct {
    kind: Kind,
    lines: []const []const Segment,
    lang: []const u8 = "",
};

const styles = struct {
    fn fg(idx: u8) Style {
        return .{ .fg = .{ .index = idx } };
    }
    const user_prefix = fg(4); // azul
    const user_text = Style{};
    const asst_prefix = fg(5); // magenta
    const asst_text = Style{};
    const info = fg(8); // gris
    const tool = fg(6); // cyan
    const tool_bold: Style = .{ .bold = true, .fg = .{ .index = 6 } };
    const tool_res = fg(8); // el resultado va atenuado
    // El resumen de la tool va en NEGRITA de verdad. Antes era idéntico a
    // `tool_res` (mismo índice, sin `.bold`), así que el "dos tonos" que se
    // describe en AGENTS.md era un no-op: `*write*(hola.js) · *3ms*` salía
    // entero del mismo gris.
    const tool_res_bold: Style = .{ .bold = true, .fg = .{ .index = 8 } };
    const diff_add = fg(2); // verde
    const diff_del = fg(1); // rojo
    const diff_ctx = fg(8); // gris
    const err = fg(1); // rojo
    // Cabecera: el búho va en el color de marca y el wordmark un tono por
    // encima, para que el logo se lea encendido contra el arte.
    // Son los tres azules de `theme.zig`; se repiten aquí porque este módulo
    // no depende de la TUI (lo usan los tests de markdown solos).
    const banner: Style = .{ .fg = .{ .rgb = .{ 0x7a, 0xa2, 0xf7 } } }; // brand
    const banner_bold: Style = .{ .bold = true, .fg = .{ .rgb = .{ 0xc0, 0xca, 0xf5 } } }; // brand_hi
    const heading = Style{ .bold = true, .fg = .{ .index = 4 } };
    const bold = Style{ .bold = true };
    const inline_code = Style{ .fg = .{ .index = 3 } }; // amarillo
    const sep = fg(8);
};

/// Parsea texto (posible markdown) a bloques. Memoria: arena.
pub fn parse(arena: std.mem.Allocator, kind: Kind, text: []const u8) ![]Block {
    return parseBase(arena, kind, text, null, null);
}

/// `parse` con estilo base impuesto (ver `inlineSegmentsBase`).
pub fn parseBase(
    arena: std.mem.Allocator,
    kind: Kind,
    text: []const u8,
    base_override: ?Style,
    mood_style: ?Style,
) ![]Block {
    return parseLang(arena, kind, text, base_override, mood_style, "");
}

/// Como `parseBase` pero sabiendo en qué LENGUAJE está el contenido.
///
/// Ahora mismo solo lo usa el diff: sin la extensión del fichero no se puede
/// tokenizar el cuerpo de una línea (`+const x: u32 = 4`) y sale entero del
/// color del prefijo, que es el muro verde que había.
pub fn parseLang(
    arena: std.mem.Allocator,
    kind: Kind,
    text: []const u8,
    base_override: ?Style,
    mood_style: ?Style,
    lang: []const u8,
) ![]Block {
    const diff_lang = lang;
    var blocks: std.ArrayList(Block) = .empty;
    var inline_lines: std.ArrayList([]const Segment) = .empty;

    var in_code = false;
    var code_lang: []const u8 = "";
    var code_lines: std.ArrayList([]const Segment) = .empty;

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        // fences ``` / ~~~
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "```") or
            std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "~~~"))
        {
            if (in_code) {
                try blocks.append(arena, .{
                    .kind = .code,
                    .lines = try code_lines.toOwnedSlice(arena),
                    .lang = code_lang,
                });
                code_lines = .empty;
                in_code = false;
            } else {
                // cerrar bloque inline pendiente
                if (inline_lines.items.len > 0) {
                    try blocks.append(arena, .{
                        .kind = kind,
                        .lines = try inline_lines.toOwnedSlice(arena),
                    });
                    inline_lines = .empty;
                }
                in_code = true;
                const trimmed = std.mem.trimStart(u8, line, " ");
                code_lang = if (trimmed.len > 3) trimmed[3..] else "";
            }
            continue;
        }

        if (in_code) {
            const segs = hl.highlightLine(arena, line, code_lang) catch
                try arena.alloc(Segment, 0);
            try code_lines.append(arena, segs);
            continue;
        }

        // headings
        //
        // OJO: el banner de inicio se salta esto. Su arte empieza por `##`
        // (relleno de `#` de un ASCII art) y TODAS sus filas se comían como
        // encabezados: el logo salía como "####  ####  *zode*". El banner no
        // es prosa, es un dibujo: no se le busca estructura de markdown.
        if (kind != .banner) {
            const trimmed = std.mem.trimStart(u8, line, " ");
            if (trimmed.len >= 2 and trimmed[0] == '#' and (trimmed[1] == ' ' or trimmed[1] == '#')) {
                var nh: usize = 0;
                while (nh < trimmed.len and trimmed[nh] == '#') nh += 1;
                if (nh < trimmed.len and trimmed[nh] == ' ') {
                    const heading_text = trimmed[nh + 1 ..];
                    const segs = try arena.alloc(Segment, 1);
                    segs[0] = .{ .text = heading_text, .style = styles.heading };
                    try inline_lines.append(arena, segs);
                    continue;
                }
            }
        }

        // El diff necesita el LENGUAJE del fichero para tokenizar el cuerpo; el
        // resto de kinds lo ignoran (se les pasa "").
        const line_lang: []const u8 = if (kind == .diff) diff_lang else "";
        try inline_lines.append(arena, try inlineSegmentsLang(arena, line, kind, base_override, mood_style, line_lang));
    }
    // código pendiente sin cierre
    if (in_code and code_lines.items.len > 0) {
        try blocks.append(arena, .{
            .kind = .code,
            .lines = try code_lines.toOwnedSlice(arena),
            .lang = code_lang,
        });
    }
    // texto pendiente
    if (inline_lines.items.len > 0) {
        try blocks.append(arena, .{
            .kind = kind,
            .lines = try inline_lines.toOwnedSlice(arena),
        });
    }
    return blocks.toOwnedSlice(arena);
}

/// Estilo base según kind para texto sin formato especial.
fn baseStyle(kind: Kind) Style {
    return switch (kind) {
        .user => styles.user_text,
        .assistant => styles.asst_text,
        .info => styles.info,
        .tool, .tool_run => styles.tool,
        .tool_res => styles.tool_res,
        .error_msg => styles.err,
        .banner => styles.banner,
        else => styles.asst_text,
    };
}

/// Una línea de diff unificada: prefijo por su color + el resto POR TOKENS.
///
/// Antes era UN solo segmento de toda la línea con `diff_add`, que es un verde
/// sólido (#00cd00). Escribir un fichero de 200 líneas daba 200 filas verde
/// plano: no se distinguía una string de un número de un tipo, y además ese
/// verde era el MISMO que el de las strings del código (`highlight.zig`), así
/// que "verde" no significaba nada.
///
/// Ahora el prefijo `+`/`-`/` ` va con su color y el cuerpo pasa por el
/// highlighter con `lang`, que es lo que hace legible un diff: los números se
/// ven números y los identificadores en Pascal se ven tipos.
fn diffSegments(arena: std.mem.Allocator, line: []const u8, lang: []const u8) ![]Segment {
    if (line.len == 0) {
        const segs = try arena.alloc(Segment, 1);
        segs[0] = .{ .text = line, .style = theme.diff_ctx };
        return segs;
    }
    const pre_style: Style = switch (line[0]) {
        '+' => theme.diff_add,
        '-' => theme.diff_del,
        '@' => styles.heading, // cabecera @@ hunk @@
        else => theme.diff_ctx,
    };
    // `@@ … @@` es una cabecera de hunk, no código: entero del color del heading.
    if (line[0] == '@') {
        const segs = try arena.alloc(Segment, 1);
        segs[0] = .{ .text = line, .style = pre_style };
        return segs;
    }

    // El prefijo (`+`, `-` o el espacio de contexto) es un segmento propio, y
    // el resto se tokeniza. El espacio de contexto NO se incluye en el cuerpo
    // que va al highlighter: si no, el lenguaje no reconocería nada hasta el
    // primer carácter real.
    const lead: usize = if (line[0] == '+' or line[0] == '-')
        1
    else if (line[0] == ' ')
        @min(1, line.len)
    else
        0;
    var out: std.ArrayList(Segment) = .empty;
    if (lead > 0) {
        try out.append(arena, .{ .text = line[0..lead], .style = pre_style });
    }
    const body = line[lead..];
    if (body.len > 0) {
        const toks = try hl.highlightLine(arena, body, lang);
        for (toks) |t| {
            // Los tokens del highlight traen sus propios colores; el prefijo
            // del diff ya va aparte. Para el contexto (líneas ` `) sí se
            // atenúa el cuerpo, que si no el diff de un fichero entero sale
            // con el mismo contraste que las líneas cambiadas.
            var st = t.style;
            if (lead == 0 or (lead == 1 and line[0] == ' ')) {
                st = theme.diff_ctx;
            }
            try out.append(arena, .{ .text = t.text, .style = st });
        }
    }
    return out.toOwnedSlice(arena);
}

/// Tope de líneas por fichero para el diff.
///
/// `unifiedDiff` es LCS O(n·m) por líneas y la tabla son (n+1)·(m+1) `usize`: un
/// par de ficheros de 10 000 líneas son 800 MB de tabla. Por encima de este
/// tope no se calcula el diff: se enseña un aviso. Es degradación, no error.
pub const max_diff_lines = 2000;

/// Construye un diff unificado (simplificado) entre dos textos.
/// Algoritmo LCS por líneas: O(n*m), suficiente para ediciones de código
/// donde los bloques son cientos de líneas (y con `max_diff_lines` hay tope).
///
/// Devuelve un slice de arena con líneas ya prefijadas con ' ', '+' o '-'.
pub fn unifiedDiff(arena: std.mem.Allocator, before: []const u8, after: []const u8) ![]const []const u8 {
    var old_lines: std.ArrayList([]const u8) = .empty;
    var new_lines: std.ArrayList([]const u8) = .empty;
    try splitLines(arena, before, &old_lines);
    try splitLines(arena, after, &new_lines);

    // Tabla LCS (n+1) x (m+1) de usize.
    const n = old_lines.items.len;
    const m = new_lines.items.len;
    if (n > max_diff_lines or m > max_diff_lines) {
        const note = try arena.dupe(u8, "diff omitted (file too large)");
        const one = try arena.alloc([]const u8, 1);
        one[0] = note;
        return one;
    }
    const table = try arena.alloc(usize, (n + 1) * (m + 1));
    @memset(table, 0);
    var i = n;
    while (i > 0) {
        i -= 1;
        var j = m;
        while (j > 0) {
            j -= 1;
            table[i * (m + 1) + j] = if (std.mem.eql(u8, old_lines.items[i], new_lines.items[j]))
                table[(i + 1) * (m + 1) + (j + 1)] + 1
            else
                @max(table[(i + 1) * (m + 1) + j], table[i * (m + 1) + (j + 1)]);
        }
    }

    var out: std.ArrayList([]const u8) = .empty;
    var x: usize = 0;
    var y: usize = 0;
    while (x < n and y < m) {
        if (std.mem.eql(u8, old_lines.items[x], new_lines.items[y])) {
            try out.append(arena, try prefixed(arena, ' ', old_lines.items[x]));
            x += 1;
            y += 1;
        } else if (table[(x + 1) * (m + 1) + y] >= table[x * (m + 1) + (y + 1)]) {
            try out.append(arena, try prefixed(arena, '-', old_lines.items[x]));
            x += 1;
        } else {
            try out.append(arena, try prefixed(arena, '+', new_lines.items[y]));
            y += 1;
        }
    }
    while (x < n) : (x += 1) try out.append(arena, try prefixed(arena, '-', old_lines.items[x]));
    while (y < m) : (y += 1) try out.append(arena, try prefixed(arena, '+', new_lines.items[y]));
    return out.items;
}

fn prefixed(arena: std.mem.Allocator, p: u8, line: []const u8) ![]const u8 {
    const buf = try arena.alloc(u8, line.len + 1);
    buf[0] = p;
    @memcpy(buf[1..], line);
    return buf;
}

/// Parte en líneas ignorando el salto final: "a\nb\n" son 2 líneas, no 3.
/// (Si no, un fichero terminado en \n genera una línea vacía espuria en el diff.)
fn splitLines(arena: std.mem.Allocator, text: []const u8, out: *std.ArrayList([]const u8)) !void {
    const body = if (std.mem.endsWith(u8, text, "\n")) text[0 .. text.len - 1] else text;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |l| try out.append(arena, l);
}

/// Segmentos inline: **bold**, `code`, y texto normal.
/// Segmentos inline de una línea. `pub` para que los tests de la TUI
/// puedan comprobar el reparto de estilos del banner.
pub fn inlineSegments(arena: std.mem.Allocator, line: []const u8, kind: Kind) ![]Segment {
    return inlineSegmentsBase(arena, line, kind, null, null);
}

/// Igual que `inlineSegments` pero con un estilo base imposed por el llamante
/// (la TUI lo usa para pintar la carita de Zo con el color de su mood).
pub fn inlineSegmentsBase(
    arena: std.mem.Allocator,
    line: []const u8,
    kind: Kind,
    base_override: ?Style,
    mood_style: ?Style,
) ![]Segment {
    return inlineSegmentsLang(arena, line, kind, base_override, mood_style, "");
}

/// Como `inlineSegmentsBase` pero con el LENGUAJE de la línea.
///
/// Hace falta para el diff: el prefijo va con su color y el cuerpo se tokeniza
/// como código, así que hay que saber en qué lenguaje está el fichero que se
/// edita. Para el resto de kinds el idioma da igual.
pub fn inlineSegmentsLang(
    arena: std.mem.Allocator,
    line: []const u8,
    kind: Kind,
    base_override: ?Style,
    mood_style: ?Style,
    lang: []const u8,
) ![]Segment {
    if (kind == .diff) return diffSegments(arena, line, lang);

    // Cabecera: `*zode*` y `*─────*` brillan dentro del arte del búho. Con
    // esto el brillo cae DENTRO del dibujo en vez de pintar una línea entera,
    // que es lo que hace que el ASCII art parezca un logo y no un bloque.
    if (kind == .banner and
        (std.mem.indexOfScalar(u8, line, '*') != null or std.mem.indexOfScalar(u8, line, '~') != null))
    {
        return markedSegments(arena, line, styles.banner, styles.banner_bold, mood_style orelse styles.banner);
    }

    // Las tools usan la MISMA marca `*…*` para partir el nombre del resto:
    // `write(hola.js)` sale entero del mismo color y no se distingue la tool de
    // su argumento. Con `*write* (hola.js)` el nombre va en el color fuerte y
    // el argumento en el apagado, que es como lo lee el ojo de un vistazo.
    if (kind == .tool_run and std.mem.indexOfScalar(u8, line, '*') != null) {
        return markedSegments(arena, line, styles.tool, styles.tool_bold, styles.tool);
    }
    if (kind == .tool_res and std.mem.indexOfScalar(u8, line, '*') != null) {
        return markedSegments(arena, line, styles.tool_res, styles.tool_res_bold, styles.tool_res);
    }

    var segs: std.ArrayList(Segment) = .empty;
    const base = base_override orelse baseStyle(kind);
    var i: usize = 0;
    var start: usize = 0;

    while (i < line.len) {
        // **bold**
        if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '*') {
            if (constClose(line, i + 2, "**")) |end| {
                if (i > start) try segs.append(arena, .{ .text = line[start..i], .style = base });
                try segs.append(arena, .{ .text = line[i + 2 .. end], .style = styles.bold });
                i = end + 2;
                start = i;
                continue;
            }
        }
        // `code`
        if (line[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, line, i + 1, '`')) |end| {
                if (end > i + 1) {
                    if (i > start) try segs.append(arena, .{ .text = line[start..i], .style = base });
                    try segs.append(arena, .{ .text = line[i + 1 .. end], .style = styles.inline_code });
                    i = end + 1;
                    start = i;
                    continue;
                }
            }
        }
        i += 1;
    }
    if (start < line.len) {
        try segs.append(arena, .{ .text = line[start..], .style = base });
    }
    if (segs.items.len == 0) {
        try segs.append(arena, .{ .text = "", .style = base });
    }
    return segs.toOwnedSlice(arena);
}

/// Parte la línea por marcas y pinta cada tramo con su estilo.
///
/// Hay DOS tipos de marca porque el logo es fijo y el color de Zo no:
///   `*…*`  → `hi` (el wordmark, siempre el mismo azul claro)
///   `~…~`  → `mood` (lo que pase el llamante: el color del estado de Zo)
///
/// Las marcas se QUITAN del texto de salida (son marcas, no contenido), así que
/// quien llama ve el texto limpio mientras el dibujo sale con varios colores.
/// Una marca sin pareja se trata como texto normal, para no perder caracteres.
fn markedSegments(
    arena: std.mem.Allocator,
    line: []const u8,
    base: Style,
    hi: Style,
    mood: Style,
) ![]Segment {
    var segs: std.ArrayList(Segment) = .empty;
    var i: usize = 0;
    var start: usize = 0;

    while (i < line.len) {
        const m: ?struct { ch: u8, style: Style } = switch (line[i]) {
            '*' => .{ .ch = '*', .style = hi },
            '~' => .{ .ch = '~', .style = mood },
            else => null,
        };
        if (m) |mark| {
            if (constClose(line, i + 1, &.{mark.ch})) |end| {
                if (i > start) try segs.append(arena, .{ .text = line[start..i], .style = base });
                if (end > i + 1) try segs.append(arena, .{ .text = line[i + 1 .. end], .style = mark.style });
                i = end + 1;
                start = i;
                continue;
            }
        }
        i += 1;
    }
    if (start < line.len) try segs.append(arena, .{ .text = line[start..], .style = base });
    if (segs.items.len == 0) try segs.append(arena, .{ .text = "", .style = base });
    return segs.toOwnedSlice(arena);
}

/// Busca `needle` en `line` desde `from`; devuelve el índice de inicio si está.
fn constClose(line: []const u8, from: usize, needle: []const u8) ?usize {
    const rel = std.mem.indexOfPos(u8, line, from, needle) orelse return null;
    return rel;
}

/// Prefijos de prompt por kind (se dibujan en la primera línea del bloque).
pub fn prefix(kind: Kind) struct { text: []const u8, style: Style } {
    return switch (kind) {
        .user => .{ .text = "› ", .style = styles.user_prefix },
        .assistant => .{ .text = "◆ ", .style = styles.asst_prefix },
        .info => .{ .text = "· ", .style = styles.info },
        .tool => .{ .text = "⚙ ", .style = styles.tool },
        // Tool calls estilo Claude Code: cabecera y resultado con guiones.
        .tool_run => .{ .text = "⏺ ", .style = styles.tool_bold },
        .tool_res => .{ .text = "⎿  ", .style = styles.tool_res },
        .diff => .{ .text = "", .style = styles.diff_ctx },
        .error_msg => .{ .text = "✗ ", .style = styles.err },
        .banner => .{ .text = "", .style = styles.banner },
        else => .{ .text = "  ", .style = styles.info },
    };
}

pub fn sepStyle() Style {
    return styles.sep;
}
pub fn infoStyle() Style {
    return styles.info;
}

// test básico
test "parse markdown básico" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const blocks = try parse(arena, .assistant, "# Titulo\nHola **mundo** con `code`\n```zig\nconst x = 1;\n```\nfin");
    // bloque 1: heading + línea inline (2 líneas)
    try std.testing.expect(blocks.len >= 3);
    try std.testing.expectEqual(Kind.code, blocks[1].kind);
}

test "unifiedDiff: cambio simple" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try unifiedDiff(arena, "uno\ndos\ntres\n", "uno\nDOS\ntres\n");
    try std.testing.expectEqual(@as(usize, 4), d.len);
    try std.testing.expectEqualStrings(" uno", d[0]);
    try std.testing.expectEqualStrings("-dos", d[1]);
    try std.testing.expectEqualStrings("+DOS", d[2]);
    try std.testing.expectEqualStrings(" tres", d[3]);
}

test "unifiedDiff: sin cambios no produce +/-" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try unifiedDiff(arena, "igual\n", "igual\n");
    try std.testing.expectEqual(@as(usize, 1), d.len);
    try std.testing.expectEqualStrings(" igual", d[0]);
}

test "unifiedDiff: lineas nuevas al final" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try unifiedDiff(arena, "a\n", "a\nb\nc\n");
    try std.testing.expectEqualStrings(" a", d[0]);
    try std.testing.expectEqualStrings("+b", d[1]);
    try std.testing.expectEqualStrings("+c", d[2]);
}

test "unifiedDiff: borrado" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try unifiedDiff(arena, "a\nb\nc\n", "a\nc\n");
    try std.testing.expectEqualStrings(" a", d[0]);
    try std.testing.expectEqualStrings("-b", d[1]);
    try std.testing.expectEqualStrings(" c", d[2]);
}

test "diffSegments: el prefijo va con su color y el cuerpo POR TOKENS" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // El prefijo es su propio segmento...
    const add = try inlineSegments(arena, "+nuevo", .diff);
    try std.testing.expectEqualStrings("+", add[0].text);
    try std.testing.expectEqual(theme.diff_add.fg, add[0].style.fg);

    const del = try inlineSegments(arena, "-viejo", .diff);
    try std.testing.expectEqualStrings("-", del[0].text);
    try std.testing.expectEqual(theme.diff_del.fg, del[0].style.fg);

    const ctx = try inlineSegments(arena, " igual", .diff);
    try std.testing.expectEqualStrings(" ", ctx[0].text);
    try std.testing.expectEqual(theme.diff_ctx.fg, ctx[0].style.fg);

    // ...y el texto NO se pierde nunca: invariante del módulo.
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(std.testing.allocator);
    for (add) |sg| try joined.appendSlice(std.testing.allocator, sg.text);
    try std.testing.expectEqualStrings("+nuevo", joined.items);
}

test "una línea + del diff lleva tokens, no un segmento verde" {
    // El muro verde: `+const n: u32 = 42` era UN segmento con `diff_add`. Ahora
    // el prefijo va con su color y el cuerpo se tokeniza, así que `const` es
    // keyword, `u32` un tipo y `42` un número. Es lo que hace legible un diff
    // sin abrir el fichero.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const segs = try inlineSegmentsLang(arena, "+const n: u32 = 42", .diff, null, null, "zig");
    try std.testing.expect(segs.len >= 4);

    const kw = findDiffSeg(segs, "const") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(theme.code_kw.fg, kw.style.fg);
    const typ = findDiffSeg(segs, "u32") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(theme.code_type.fg, typ.style.fg);
    const num = findDiffSeg(segs, "42") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(theme.code_num.fg, num.style.fg);

    // Y el prefijo conserva su verde de diff, que es DISTINTO del verde de las
    // strings del código (antes ambos eran `index 2`).
    try std.testing.expect(!std.meta.eql(theme.diff_add.fg, theme.code_str.fg));

    // Invariante: se conserva cada byte.
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(std.testing.allocator);
    for (segs) |sg| try joined.appendSlice(std.testing.allocator, sg.text);
    try std.testing.expectEqualStrings("+const n: u32 = 42", joined.items);
}

fn findDiffSeg(segs: []const Segment, needle: []const u8) ?Segment {
    for (segs) |s| {
        if (std.mem.eql(u8, s.text, needle)) return s;
    }
    return null;
}

test "el diff sin saber el lenguaje sale plano pero conserva el prefijo" {
    // Con `lang = ""` cae en el `generic`, que ahora tiene tabla: no es un
    // muro verde, pero tampoco inventa colores.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const segs = try inlineSegments(arena, "+hola", .diff);
    try std.testing.expectEqualStrings("+", segs[0].text);
    try std.testing.expectEqual(theme.diff_add.fg, segs[0].style.fg);
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(std.testing.allocator);
    for (segs) |sg| try joined.appendSlice(std.testing.allocator, sg.text);
    try std.testing.expectEqualStrings("+hola", joined.items);
}

test "un banner que empieza por ## NO se come como encabezado" {
    // El art del banner usa `#` como relleno y TODAS sus filas empiezan por
    // `##`, así que el parser las interpretaba como encabezados markdown y
    // devolvía "####  ####  *zode*" en vez del dibujo entero. El banner es un
    // dibujo, no prosa: no se le busca estructura.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const blocks = try parseBase(arena, .banner, "######  ####   ######\n##  ## ##  ## ##    ", null, null);
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    const segs = blocks[0].lines[0];
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    for (segs) |seg| try text.appendSlice(std.testing.allocator, seg.text);
    try std.testing.expectEqualStrings("######  ####   ######", text.items);

    // Y el resto de tipos SIGUE interpretando los encabezados: el arreglo es
    // para `.banner`, no una desactivar general.
    const h = try parseBase(arena, .info, "## un titulo", null, null);
    var ht: std.ArrayList(u8) = .empty;
    defer ht.deinit(std.testing.allocator);
    for (h[0].lines[0]) |seg| try ht.appendSlice(std.testing.allocator, seg.text);
    try std.testing.expectEqualStrings("un titulo", ht.items);
}

test "unifiedDiff: por encima del tope no se calcula el LCS (sería O(n*m))" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Con el tope normal el diff se calcula.
    const small = try unifiedDiff(arena, "a\nb\n", "a\nc\n");
    try std.testing.expectEqual(@as(usize, 3), small.len);
    try std.testing.expectEqualStrings("-b", small[1]);

    // Por encima del tope sale el aviso, y sale RÁPIDO: sin la tabla de 4000x4000.
    var big_a: std.ArrayList(u8) = .empty;
    var big_b: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < max_diff_lines + 10) : (i += 1) {
        try big_a.appendSlice(arena, "x\n");
        try big_b.appendSlice(arena, "y\n");
    }
    const out = try unifiedDiff(arena, big_a.items, big_b.items);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expect(std.mem.indexOf(u8, out[0], "too large") != null);
}

test "tool_res_bold es bold DE VERDAD (el 'dos tonos' no era un no-op)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // El resumen de la tool (`*3ms*`) tiene que salir en negrita; antes
    // `tool_res_bold` era idéntico a `tool_res` (mismo índice, sin `.bold`) y
    // el "dos tonos" de las tools no pintaba nada.
    const segs = try inlineSegments(arena, "*3ms*", .tool_res);
    try std.testing.expectEqual(@as(usize, 1), segs.len);
    try std.testing.expect(segs[0].style.bold);
    try std.testing.expectEqual(styles.tool_res_bold.fg, segs[0].style.fg);
    try std.testing.expectEqualStrings("3ms", segs[0].text);

    // Y el texto SIN marcar sale apagado y SIN bold: los dos tonos existen.
    const plain = try inlineSegments(arena, "salida", .tool_res);
    try std.testing.expect(!plain[0].style.bold);
    try std.testing.expectEqual(styles.tool_res.fg, plain[0].style.fg);
}
