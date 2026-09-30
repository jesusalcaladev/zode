const std = @import("std");

/// Lo que necesita la tool `web_fetch` / `web_search` para convertir una página
/// en algo que un modelo pueda leer: HTML a texto, y resultados de búsqueda a
/// una lista.
///
/// TODO esto es PURO (sin red) a propósito: la parte que falla siempre es la de
/// parsear el HTML que devuelve el server, y eso se testea con un fixture, no
/// con internet. La red la pone `tools.zig` encima.

/// User-Agent de navegador.
///
/// Sin esto medio internet devuelve 403: Cloudflare, GitHub y Wikipedia
/// rechazan el `User-Agent` por defecto de std, que es `zig`, y la respuesta de
/// un 403 no dice absolutamente nada de lo que había detrás. Un 403 con este
/// header es un problema del sitio; sin él, no se puede distinguir de un bloqueo
/// real.
pub const user_agent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36";

/// Etiquetas de bloque: al cerrarlas (o al abrirlas si van solas, como `<br>`)
/// sale un salto de línea en el texto.
const block_tags = [_][]const u8{
    "p",        "div",   "br",     "li",   "tr",   "td",     "th",
    "h1",       "h2",    "h3",     "h4",   "h5",   "h6",     "section",
    "article",  "header", "footer", "nav",  "aside", "ul",     "ol",
    "pre",      "blockquote", "form", "hr", "main", "figure", "figcaption",
    "dl",       "dt",    "dd",     "table", "tbody", "thead", "body",
    "html",     "head",  "title",  "meta", "link", "script", "style",
};

/// Tags cuyo contenido entero se tira (no es texto de la página).
const drop_tags = [_][]const u8{ "script", "style", "noscript", "svg", "head" };

fn isBlockTag(name: []const u8) bool {
    for (block_tags) |t| {
        if (std.ascii.eqlIgnoreCase(t, name)) return true;
    }
    return false;
}

fn isDropTag(name: []const u8) bool {
    for (drop_tags) |t| {
        if (std.ascii.eqlIgnoreCase(t, name)) return true;
    }
    return false;
}

/// HTML a texto legible.
///
/// No es un parser de HTML: es un "quitar lo que no es texto" que aguanta el
/// HTML que devuelve la web real (minificado, con scripts en medio del texto y
/// con entidades). Lo que sale es para que lo lea un modelo, no para
/// reconstruir la página: si el sitio necesita un motor de verdad, aquí no cabe.
///
/// Reglas, en orden:
/// 1. `<!--…-->`, `<script>…</script>`, `<style>…</style>` y `<head>…</head>`
///    fuera.
/// 2. Cada tag de bloque (o su cierre) es un salto de línea.
/// 3. El resto de tags desaparece, dejando su contenido.
/// 4. Las entidades (`&amp;`, `&#39;`, `&hellip;`…) se convierten.
/// 5. Los espacios seguidos se funden en uno, y 3+ saltos de línea en 2.
pub fn htmlToText(arena: std.mem.Allocator, html: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    // Espacio pendiente: se emite solo si detrás viene texto de verdad. Sin esto
    // cada tag deja un hueco y el texto sale con un espacio entre cada palabra.
    var space_pending = false;
    // Saltos pendientes, como máximo 2 (el texto legible no lleva más).
    var nl_pending: u8 = 0;

    while (i < html.len) {
        const c = html[i];
        if (c == '<') {
            // Comentario.
            if (std.mem.startsWith(u8, html[i..], "<!--")) {
                i = (std.mem.indexOfPos(u8, html, i + 4, "-->") orelse html.len) + 3;
                space_pending = true;
                continue;
            }
            const end = tagEnd(html, i) orelse {
                // No es un tag: el `<` va como texto (`a < b`).
                space_pending = flushSpace(arena, &out, &nl_pending, space_pending);
                out.append(arena, '<') catch return "";
                i += 1;
                continue;
            };
            const name = tagName(html[i..]);
            if (name.len > 0 and isDropTag(name)) {
                // Sin cierre (un `<meta …>` suelto): solo se salta el tag.
                i = closingTag(html, i, name) orelse end;
                space_pending = true;
                continue;
            }
            if (isBlockTag(name)) {
                // `<br>`/`<hr>` FUERZAN un salto (dos, para dejar una línea en
                // blanco). Los contenedores solo lo fuerzan si no estamos ya
                // en un límite: `</li><li>` es UN salto, no dos, y con la regla
                // tonta salía una línea en blanco entre cada item de lista.
                const forces = std.ascii.eqlIgnoreCase(name, "br") or std.ascii.eqlIgnoreCase(name, "hr");
                nl_pending = if (forces) 2 else if (nl_pending == 0) 1 else nl_pending;
                space_pending = false;
            }
            i = end;
            continue;
        }
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            space_pending = true;
            i += 1;
            continue;
        }

        // Texto de verdad: primero los saltos pendientes, luego el texto.
        space_pending = flushSpace(arena, &out, &nl_pending, space_pending);
        i += appendEntity(arena, &out, html, i);
    }

    // Cierre: sin espacio colgando ni saltos de más.
    while (out.items.len > 0 and out.items[out.items.len - 1] == '\n') {
        _ = out.pop();
    }
    return out.items;
}

/// Vuelca el espacio/saltos pendientes ANTES de escribir texto de verdad.
///
/// Un salto pendiente se come el espacio que lo precedía, y el espacio solo se
/// escribe si el buffer no está ya en principio de línea: por eso el texto no
/// sale con un hueco detrás de cada tag.
fn flushSpace(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    nl_pending: *u8,
    space_pending: bool,
) bool {
    if (nl_pending.* > 0) {
        var k: u8 = 0;
        while (k < nl_pending.*) : (k += 1) {
            if (out.items.len > 0) out.append(arena, '\n') catch return false;
        }
        nl_pending.* = 0;
        return false;
    }
    if (space_pending and out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
        out.append(arena, ' ') catch return false;
    }
    return false;
}

/// Nombre del tag que empieza en `rest` (que empieza por `<`).
fn tagName(rest: []const u8) []const u8 {
    var j: usize = 1; // el '<'
    if (j < rest.len and rest[j] == '/') j += 1;
    const start = j;
    while (j < rest.len and (std.ascii.isAlphanumeric(rest[j]) or rest[j] == '-')) j += 1;
    return rest[start..j];
}

/// Fin del tag que empieza en `i`, o null si no hay `>` antes del siguiente
/// `<` (o del fin del texto).
///
/// OJO al `null`: `Tom & Jerry <3` NO es un tag, y si se tratara como tal se
/// comería el resto de la línea. Un `<` sin `>` antes de otro `<` es texto.
fn tagEnd(html: []const u8, i: usize) ?usize {
    var j = i + 1; // el '<' no cuenta como "el siguiente '<'"
    while (j < html.len) : (j += 1) {
        switch (html[j]) {
            '>' => return j + 1,
            '<' => return null,
            else => {},
        }
    }
    return null;
}

fn isClosingTag(rest: []const u8) bool {
    return rest.len > 1 and rest[1] == '/';
}

/// Posición ABSOLUTA (justo después del `>`) del tag de cierre `name` que
/// sigue al tag abierto en `open_at`.
///
/// OJO: el índice es del HTML entero, no de un slice que empiece en el tag.
/// Antes se buscaba sobre `html[open_at..]` y se devolvía ese offset, que se
/// usaba como absoluto: con `<head></head>` el salto acababa en el `/` del
/// cierre y el `</head>` entero se colaba en el texto. Un índice que no es del
/// buffer que se indexa es el peor tipo de bug posible: no da error, da basura.
fn closingTag(html: []const u8, open_at: usize, name: []const u8) ?usize {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "</{s}", .{name}) catch return null;
    const at = std.mem.indexOfPos(u8, html, open_at + 1, needle) orelse return null;
    const gt = std.mem.indexOfScalarPos(u8, html, at, '>') orelse return null;
    return gt + 1;
}

/// Escribe el texto desde `i`, decodificando entidades. Devuelve cuántos bytes
/// del HTML se consumieron.
fn appendEntity(arena: std.mem.Allocator, out: *std.ArrayList(u8), html: []const u8, i: usize) usize {
    if (html[i] != '&') {
        out.append(arena, html[i]) catch return html.len - i;
        return 1;
    }
    // `&` suelta (no es entidad) se escribe tal cual.
    const semi = std.mem.indexOfScalarPos(u8, html, i, ';') orelse {
        out.append(arena, '&') catch {};
        return 1;
    };
    const name = html[i + 1 .. semi];
    if (name.len == 0 or name.len > 10) {
        out.append(arena, '&') catch {};
        return 1;
    }
    // Numérica: &#39; &#x27;
    if (name[0] == '#') {
        const parsed: ?u21 = if (name.len > 1 and (name[1] == 'x' or name[1] == 'X'))
            (std.fmt.parseInt(u21, name[2..], 16) catch null)
        else
            (std.fmt.parseInt(u21, name[1..], 10) catch null);
        if (parsed) |v| {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(@intCast(@min(v, 0x10FFFF)), &buf) catch 0;
            out.appendSlice(arena, buf[0..n]) catch {};
            return (semi - i) + 1;
        }
    }
    const replacement: ?[]const u8 = namedEntity(name);
    if (replacement) |r| {
        out.appendSlice(arena, r) catch {};
        return (semi - i) + 1;
    }
    out.append(arena, '&') catch {};
    return 1;
}

/// Entidades nombradas. Solo las que aparecen de verdad en el texto de una
/// página; una tabla de 250 nombres no compensa: lo que no está aquí se queda
/// tal cual (`&foo;`), que es lo que se ve en el fuente.
fn namedEntity(name: []const u8) ?[]const u8 {
    const pairs = [_][2][]const u8{
        .{ "amp", "&" },      .{ "lt", "<" },        .{ "gt", ">" },
        .{ "quot", "\"" },     .{ "apos", "'" },       .{ "nbsp", " " },
        .{ "hellip", "…" },   .{ "mdash", "—" },     .{ "ndash", "–" },
        .{ "laquo", "«" },    .{ "raquo", "»" },     .{ "ldquo", "“" },
        .{ "rdquo", "”" },    .{ "lsquo", "‘" },     .{ "rsquo", "’" },
        .{ "copy", "©" },     .{ "reg", "®" },       .{ "trade", "™" },
        .{ "deg", "°" },      .{ "middot", "·" },    .{ "bull", "•" },
        .{ "times", "×" },    .{ "euro", "€" },      .{ "pound", "£" },
        .{ "frac12", "½" },   .{ "larr", "←" },      .{ "rarr", "→" },
        .{ "harr", "↔" },     .{ "darr", "↓" },      .{ "uarr", "↑" },
        .{ "infin", "∞" },    .{ "ne", "≠" },        .{ "le", "≤" },
        .{ "ge", "≥" },       .{ "auml", "ä" },      .{ "ouml", "ö" },
        .{ "uuml", "ü" },     .{ "szlig", "ß" },     .{ "ntilde", "ñ" },
        .{ "aacute", "á" },   .{ "eacute", "é" },    .{ "iacute", "í" },
        .{ "oacute", "ó" },   .{ "uacute", "ú" },    .{ "agrave", "à" },
        .{ "egrave", "è" },   .{ "ccedil", "ç" },    .{ "shy", "" },
        .{ "ensp", " " },     .{ "emsp", " " },      .{ "thinsp", " " },
    };
    for (pairs) |p| {
        if (std.ascii.eqlIgnoreCase(p[0], name)) return p[1];
    }
    return null;
}

/// Extrae resultados de búsqueda del HTML de DuckDuckGo (endpoint `html/`).
///
/// Devuelve texto con los resultados numerados: título, URL y snippet. Si no
/// encuentra ninguno devuelve un mensaje que dice qué hacer (y no un error
/// opaco), porque este scraper se rompe el día que cambien una clase del HTML.
pub fn searchResults(arena: std.mem.Allocator, html: []const u8, max: usize) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var n: usize = 0;
    var pos: usize = 0;
    while (n < max) {
        const anchor = std.mem.indexOfPos(u8, html, pos, "class=\"result__a\"") orelse break;
        const href_at = std.mem.indexOfPos(u8, html, anchor, "href=\"") orelse break;
        const href_start = href_at + 6;
        const href_end = std.mem.indexOfScalarPos(u8, html, href_start, '"') orelse break;
        const href = html[href_start..href_end];

        // El título va entre el `>` que cierra el `<a …>` y su `</a>`.
        const title_start = (std.mem.indexOfScalarPos(u8, html, href_end, '>') orelse break) + 1;
        const title_end = std.mem.indexOfPos(u8, html, title_start, "</a>") orelse break;

        pos = title_end;

        n += 1;
        out.print(arena, "{d}. ", .{n}) catch return "";
        out.appendSlice(arena, cleanText(arena, html[title_start..title_end])) catch return "";
        out.append(arena, '\n') catch return "";

        const url = realUrl(arena, href);
        if (url.len > 0) {
            out.print(arena, "   {s}\n", .{url}) catch return "";
        }

        // El snippet va después del título, en otro `<a>`.
        if (std.mem.indexOfPos(u8, html, pos, "class=\"result__snippet\"")) |sn| {
            const s_start = (std.mem.indexOfScalarPos(u8, html, sn, '>') orelse sn) + 1;
            const s_end = std.mem.indexOfPos(u8, html, s_start, "</a>") orelse html.len;
            const snip = cleanText(arena, html[s_start..@min(s_end, s_start + 400)]);
            if (snip.len > 0) {
                out.print(arena, "   {s}\n", .{snip}) catch return "";
            }
            pos = s_end;
        }
        out.append(arena, '\n') catch return "";
    }
    if (n == 0) return "";
    return out.items;
}

/// La URL real detrás del enlace de DuckDuckGo (`//duckduckgo.com/l/?uddg=…`).
fn realUrl(arena: std.mem.Allocator, href: []const u8) []const u8 {
    if (std.mem.indexOf(u8, href, "uddg=")) |at| {
        var rest = href[at + 5 ..];
        if (std.mem.indexOfScalar(u8, rest, '&')) |amp| rest = rest[0..amp];
        const buf = arena.dupe(u8, rest) catch return "";
        return std.Uri.percentDecodeInPlace(buf);
    }
    if (std.mem.startsWith(u8, href, "//")) {
        return std.fmt.allocPrint(arena, "https:{s}", .{href}) catch "";
    }
    return href;
}

/// Texto de un trozo de HTML: quita etiquetas y decodifica entidades.
fn cleanText(arena: std.mem.Allocator, raw: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '<') {
            i = (std.mem.indexOfScalarPos(u8, raw, i, '>') orelse raw.len) + 1;
            continue;
        }
        i += appendEntity(arena, &out, raw, i);
    }
    return std.mem.trim(u8, out.items, " \t\r\n");
}

// ── tests ─────────────────────────────────────────────────────

test "htmlToText quita script, style y etiquetas" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const html =
        \\<html><head><title>T</title><style>body{color:red}</style></head>
        \\<body><script>var a = 1 < 2;</script>
        \\<h1>Title</h1><p>Hello &amp; <b>bye</b>.</p></body></html>
    ;
    const text = htmlToText(arena_state.allocator(), html);
    try std.testing.expect(std.mem.indexOf(u8, text, "Hello & bye") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "var a") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "color:red") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "<") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Title") != null);
}

test "htmlToText: los saltos de bloque no dejan huecos" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text = htmlToText(arena_state.allocator(), "<li>one</li><li>two</li><br><p>three</p>");
    // Ni espacios sueltos al lado de los tags ni 5 saltos seguidos.
    try std.testing.expectEqualStrings("one\ntwo\n\nthree", text);
}

test "htmlToText decodifica entidades, incluidas las numéricas" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text = htmlToText(arena_state.allocator(), "<p>a &lt; b &#39;c&#39; caf&eacute;</p>");
    try std.testing.expectEqualStrings("a < b 'c' café", text);
}

test "htmlToText no inventa texto con un & suelto" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text = htmlToText(arena_state.allocator(), "<p>Tom & Jerry <3</p>");
    try std.testing.expectEqualStrings("Tom & Jerry <3", text);
}

test "htmlToText: <head></head> vacío no deja el cierre en el texto" {
    // Regresión: el salto al tag de cierre se calculaba sobre `html[i..]` y se
    // usaba como índice del HTML entero. Con un `<head></head>` vacío el salto
    // acababa en el `/` del cierre y el `</head>` entero salía en el texto.
    // Lo peor del bug es que no da error: da basura, y el bucle puede no
    // avanzar (la suite se colgaba).
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text = htmlToText(arena_state.allocator(), "<html><head></head><p>a</p></html>");
    try std.testing.expectEqualStrings("a", text);
}

test "searchResults saca título, URL y snippet" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const html =
        \\<div class="result"><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fziglang.org%2F&amp;rut=abc">Zig Language</a>
        \\<a class="result__snippet" href="#">Fast and <b>readable</b></a></div>
        \\<div class="result"><a class="result__a" href="https://example.com/x">Second</a></div>
    ;
    const out = searchResults(arena_state.allocator(), html, 8);
    try std.testing.expect(std.mem.indexOf(u8, out, "1. Zig Language") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "https://ziglang.org/") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Fast and readable") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "2. Second") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "https://example.com/x") != null);
}

test "searchResults sin resultados devuelve vacío (no texto basura)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = searchResults(arena_state.allocator(), "<html><body>no results here</body></html>", 8);
    try std.testing.expectEqualStrings("", out);
}
