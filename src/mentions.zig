const std = @import("std");

/// Las menciones `@fichero` del prompt.
///
/// ## Qué hace
///
/// Escribe `@src/agent.zig` y el contenido del fichero va al modelo, sin que
/// tenga que gastar un turno en un `read`. El prompt del usuario se queda como
/// está (con su `@ruta`) y los bloques se añaden al final, para que la frase que
/// escribió siga siendo legible en el historial.
///
/// ## Por qué NO se inyecta en el sitio de la `@`
///
/// Por la razón de la cache: el contenido del fichero va dentro del mensaje de
/// usuario, y si el usuario edita el prompt (o el mismo prompt se reenvía en una
/// iteración del agent loop) el texto inyectado cambiaría y el prefijo del
/// provider se invalidaría entero. Al final, después de la frase, el bloque es
/// estable mientras el fichero no cambie.
///
/// ## Los topes
///
/// 4 ficheros, 32 KB cada uno. Un `@` a un fichero de 2 MB no es una mención,
/// es un accidente: el modelo recibe 2 MB de contexto que no ha pedido y la
/// compactación lo paga. Y cuando se corta, el bloque lo DICE, porque un fichero
/// truncado en silencio es la forma más rápida de que el modelo se invente el
/// final.
pub const max_files = 4;
pub const file_max = 32 * 1024;
pub const path_max = 200;
pub const scanned_max = 8;

pub const Mention = struct {
    /// El camino tal cual lo escribió el usuario (para el bloque).
    path: [path_max]u8 = undefined,
    len: u8 = 0,

    pub fn pathOf(self: *const Mention) []const u8 {
        return self.path[0..self.len];
    }
};

/// Busca las menciones en un texto. PURE: no toca el disco.
///
/// Devuelve cuántas encontró (como máximo `scanned_max`) y las deja en `out` en
/// el orden en que aparecen, sin repetir.
pub fn scan(text: []const u8, out: *[scanned_max]Mention) u8 {
    var n: u8 = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '@') {
            i += 1;
            continue;
        }
        // Una `@` solo cuenta si NO es parte de otra cosa. El caso real que
        // importa es el correo: `user@example.com` NO es una mención de
        // `example.com`, y si lo fuera se leería un fichero que no existe en
        // cada prompt con una dirección de email.
        if (i > 0) {
            const prev = text[i - 1];
            if (std.ascii.isAlphanumeric(prev) or prev == '_' or prev == '@' or prev == '.' or prev == '/') {
                i += 1;
                continue;
            }
        }
        const start = i + 1;
        var j = start;
        while (j < text.len) : (j += 1) {
            const c = text[j];
            // `>= 0x80` es lo que deja pasar `guía.md` o `año.txt`: los bytes de
            // continuación UTF-8 son todos >= 0x80, así que la condición es
            // segura y no parte nada a mitad de un carácter.
            if (std.ascii.isAlphanumeric(c) or c >= 0x80 or c == '_' or c == '/' or c == '-' or c == '.') continue;
            break;
        }
        // La `@` suelta ("@ los tres") y los signs de puntuación que se han
        // comido la ruta ("@notas.txt,") no son menciones.
        var end = j;
        while (end > start and (text[end - 1] == '.' or text[end - 1] == ',' or text[end - 1] == ':')) {
            end -= 1;
        }
        if (end <= start) {
            i += 1;
            continue;
        }
        // `nombre@dominio` es un correo, y en un correo la parte de la derecha es
        // el dominio. Es el caso que rompe la regla de "la @ tiene que estar
        // precedida de un espacio": en `@jorge@example.com` la primera `@` está
        // al principio del texto. Mirar lo que HAY DETRÁS lo resuelve sin
        // excepciones raras.
        if (end < text.len and text[end] == '@') {
            i = end + 1;
            continue;
        }
        if (n >= scanned_max) return n;
        const path = text[start..end];
        var dup = false;
        for (out[0..n]) |prev| {
            if (std.mem.eql(u8, prev.pathOf(), path)) dup = true;
        }
        if (!dup) {
            if (path.len < path_max) {
                out[n].len = @intCast(path.len);
                @memcpy(out[n].path[0..path.len], path);
                n += 1;
            }
        }
        i = end;
    }
    return n;
}

/// Un resultado de `expand`.
pub const Expansion = struct {
    /// El texto que se manda al modelo. Es de `arena`.
    text: []const u8,
    /// Cuántos ficheros se metieron de verdad.
    files: u8,
    /// Menciones que no se pudieron meter (no existen, o son directorios).
    missing: u8,
};

/// La cabecera de cada bloque. Compartida con el test para no duplicar el
/// formato (que es justo lo que hay que fijar).
pub fn blockHeader(w: *std.Io.Writer, path: []const u8, bytes: usize, truncated: bool) !void {
    try w.print("--- {s} ({d} bytes{s}) ---\n", .{
        path,
        bytes,
        if (truncated) ", truncated" else "",
    });
}

/// Amplía el prompt con el contenido de los ficheros mencionados.
///
/// Devuelve el texto ORIGINAL (sin copiar) si no hay nada que añadir, que es el
/// caso normal y no debe costar una asignación.
pub fn expand(
    arena: std.mem.Allocator,
    io: std.Io,
    text: []const u8,
) !Expansion {
    var found: [scanned_max]Mention = undefined;
    const n = scan(text, &found);
    if (n == 0) return .{ .text = text, .files = 0, .missing = 0 };

    var w: std.Io.Writer = .fixed(arena.alloc(u8, file_max * (max_files + 1)) catch return .{
        .text = text,
        .files = 0,
        .missing = 0,
    });
    try w.writeAll(text);
    try w.writeAll("\n\nArchivos mencionados:\n\n");

    var files: u8 = 0;
    var missing: u8 = 0;
    for (found[0..n]) |*ment| {
        if (files >= max_files) {
            missing += 1;
            continue;
        }
        const path = ment.pathOf();
        // El mismo filtro que las tools: ni `.git` ni `zig-out` ni el caché.
        if (!looksLikeSource(path)) {
            missing += 1;
            continue;
        }
        const dir: std.Io.Dir = .cwd();
        const st = dir.statFile(io, path, .{}) catch {
            missing += 1;
            continue;
        };
        if (st.kind != .file) {
            missing += 1;
            continue;
        }
        const content = dir.readFileAlloc(io, path, arena, .limited(file_max)) catch {
            missing += 1;
            continue;
        };
        try blockHeader(&w, path, content.len, content.len >= file_max);
        try w.writeAll(content);
        // Un separador entre ficheros: sin él, dos bloques pegados parecen uno
        // solo y el modelo no sabe dónde acaba cada uno.
        if (!std.mem.endsWith(u8, content, "\n")) try w.writeAll("\n");
        try w.writeAll("\n");
        files += 1;
    }

    if (files == 0) {
        // Ningún fichero servible: mejor el prompt limpio que un bloque vacío
        // con "Archivos mencionados:" y nada debajo.
        return .{ .text = text, .files = 0, .missing = missing };
    }
    return .{ .text = w.buffered(), .files = files, .missing = missing };
}

/// Un fichero que tiene sentido meter en un prompt.
fn looksLikeSource(path: []const u8) bool {
    const skip = [_][]const u8{ ".zig-cache/", "zig-out/", ".git/", "node_modules/", "sessions/" };
    for (skip) |d| {
        if (std.mem.indexOf(u8, path, d) != null) return false;
    }
    return true;
}

// ── tests ─────────────────────────────────────────────────────

test "scan: encuentra las menciones en orden" {
    var out: [scanned_max]Mention = undefined;
    const n = scan("revisa @src/agent.zig y luego @src/tui.zig", &out);
    try std.testing.expectEqual(@as(u8, 2), n);
    try std.testing.expectEqualStrings("src/agent.zig", out[0].pathOf());
    try std.testing.expectEqualStrings("src/tui.zig", out[1].pathOf());
}

test "scan: un correo NO es una mención" {
    // El caso que hace falta de verdad: escribirle a alguien con su dirección.
    var out: [scanned_max]Mention = undefined;
    try std.testing.expectEqual(@as(u8, 0), scan("mándaselo a jorge@example.com", &out));
    try std.testing.expectEqual(@as(u8, 0), scan("@jorge@example.com", &out));
    // Y el caso difícil: la `@` pegada a una letra por delante no la salva nadie.
    try std.testing.expectEqual(@as(u8, 0), scan("a@b", &out));
}

test "scan: la puntuación final no se come la ruta" {
    // `@notas.txt,` y `@notas.txt.` son el fichero `notas.txt` con la coma o el
    // punto de la frase detrás. Sin quitarlo, `statFile` fallaba y la mención se
    // perdía en silencio.
    var out: [scanned_max]Mention = undefined;
    const n = scan("mira @notas.txt, y @docs/guía.md.", &out);
    try std.testing.expectEqual(@as(u8, 2), n);
    try std.testing.expectEqualStrings("notas.txt", out[0].pathOf());
    try std.testing.expectEqualStrings("docs/guía.md", out[1].pathOf());
}

test "scan: la @ suelta y el texto sin ruta no son menciones" {
    var out: [scanned_max]Mention = undefined;
    try std.testing.expectEqual(@as(u8, 0), scan("4 de 3 personas @ los tres", &out));
    try std.testing.expectEqual(@as(u8, 0), scan("@", &out));
    try std.testing.expectEqual(@as(u8, 0), scan("sin nada", &out));
    try std.testing.expectEqual(@as(u8, 0), scan("", &out));
    // Y una mención justo al principio del texto sí vale.
    try std.testing.expectEqual(@as(u8, 1), scan("@a.txt", &out));
}

test "scan: no repite el mismo fichero" {
    // Meter dos veces el mismo fichero son 32 KB de contexto de regalo.
    var out: [scanned_max]Mention = undefined;
    const n = scan("@a.txt y otra vez @a.txt y @b.txt", &out);
    try std.testing.expectEqual(@as(u8, 2), n);
    try std.testing.expectEqualStrings("a.txt", out[0].pathOf());
    try std.testing.expectEqualStrings("b.txt", out[1].pathOf());
}

test "scan: una mención dentro de paréntesis o comillas también vale" {
    var out: [scanned_max]Mention = undefined;
    const n = scan("(mira @src/a.zig) y \"@src/b.zig\"", &out);
    try std.testing.expectEqual(@as(u8, 2), n);
}

test "la cabecera del bloque dice si está truncado" {
    // Un fichero cortado en silencio hace que el modelo se invente el final, así
    // que el "(truncated)" va SIEMPRE que se corte.
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try blockHeader(&w, "a.zig", 100, false);
    try blockHeader(&w, "b.zig", 32768, true);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "--- a.zig (100 bytes) ---") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "--- b.zig (32768 bytes, truncated) ---") != null);
}

test "lookslikeSource: ni el caché ni git" {
    // Meter 40 MB de `.zig-cache` en un prompt no es una mención, es un
    // accidente.
    try std.testing.expect(looksLikeSource("src/agent.zig"));
    try std.testing.expect(looksLikeSource("notas.txt"));
    try std.testing.expect(!looksLikeSource(".zig-cache/o/abc/tablas.zig"));
    try std.testing.expect(!looksLikeSource("zig-out/bin/zode"));
    try std.testing.expect(!looksLikeSource(".git/config"));
    try std.testing.expect(!looksLikeSource("sessions/zode-1.jsonl"));
}
