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
    /// El color del mood como lo espera `vaxis.Style` (no como índice suelto).
    /// El status lo usa para pintar la carita, y el color ES la señal de "está
    /// pensando / esperando permiso /.colgado", así que tiene que salir bien
    /// sin que quien pinta tenga que acordarse del índice.
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

/// Zo's face for a mood: la carita del status bar y de la franja de actividad.
///
/// Los paréntesis son el marco y dentro van los dos ojos (o la boca, en
/// `tooling`). Solo vive en el status bar, que es donde tiene que ser legible
/// sin ocupar filas de la cabecera.
///
/// SIN ESPACIOS dentro: el test del status recorre los graphemes de la carita
/// buscándolos en la fila, y un espacio casa con cualquier hueco de la pantalla
/// (y sale del color equivocado, que es el estilo que el test comprueba).
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

/// ## Por qué ASCII PURO y no letras de cajetín
///
/// Se intentó dos veces con `█ ╗ ╝ ═ ║` (estilo figlet "big") y las dos
/// salieron mal. La última se veía en la pty de pruebas como un ZODE
/// perfecto y en la terminal del usuario como una mancha con relieve que no
/// se leia como nada.
///
/// El motivo: un art de cajetin depende de CÓMO dibuja la fuente el bloque
/// completo. Con un doble ancho, con un sustituto de la terminal o con una
/// fuente de relleno raro, los trazos se ensanchan y se solapan, y lo que
/// era una letra se convierte en un borron. `#` es un caracter ASCII normal
/// y se ve igual en todas partes.
///
/// ## Por qué se COMPONE en comptime y no escrito a mano
///
/// Las cuatro letras son cajas de 6 columnas separadas por un espacio, y el
/// relleno de cada fila se calcula con `glyphCols` (columnas, no bytes: cada
/// `█` eran 3 bytes y el relleno salia con underflow). Escrito a mano el
/// relleno se pierde, porque los editores recortan los espacios al final de
/// la linea, y las filas dejan de caer en las mismas columnas: los trazos no
/// alinean y el nombre se lee como ruido. Editar el banner es editar la
/// tabla de glifos, no medir filas a ojo. `banner_art_width` es la
/// asercion y la comprueba el test del TUI.
///
/// Los espacios van DENTRO del literal de la glifo, nunca al final del
/// archivo: dentro de `"..."` sobreviven al editor aunque la linea termine
/// en `",`.
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

/// Columnas de un fragmento de art, no bytes.
///
/// En el art del banner todo es de ancho 1 (`#` y espacio), asi que contar
/// codepoints ES contar columnas. Con `str.len` el relleno a la derecha
/// salia mal.
pub fn glyphCols(s: []const u8) usize {
    // El iterador de UTF-8 da un salto por byte y se pasa del presupuesto de
    // 1000 branches. Se sube solo aqui.
    @setEvalBranchQuota(10_000);
    const view = std.unicode.Utf8View.initUnchecked(s);
    var it = view.iterator();
    var n: usize = 0;
    while (it.nextCodepoint()) |_| n += 1;
    return n;
}

/// El wordmark, en orden, con su anchura en columnas.
const wordmark = [_]struct { rows: []const []const u8, w: usize }{
    .{ .rows = &glyph_z, .w = 6 },
    .{ .rows = &glyph_o, .w = 6 },
    .{ .rows = &glyph_d, .w = 6 },
    .{ .rows = &glyph_e, .w = 6 },
};

/// Cuantas filas tiene el wordmark (una por letra de alto).
pub const banner_art_height = 5;

/// Columnas del wordmark: 4 cajas de 6 con UN espacio de separacion.
pub const banner_art_width = 4 * 6 + 3;

/// Ensambla la fila `r` del wordmark: los huecos fijos de las letras.
fn bannerRow(comptime r: usize) []const u8 {
    comptime var out: []const u8 = "";
    inline for (wordmark, 0..) |letter, i| {
        if (i > 0) out = out ++ " ";
        // Relleno por la DERECHA hasta la anchura de la caja. La última letra
        // no lo necesita: el trailing space no se vería, y la fila se mide
        // contra `banner_art_width` con un `@min`.
        if (i + 1 < wordmark.len) {
            // OJO: `.len` son BYTES y cada `█` son 3, así que el relleno se
            // calcula en COLUMNAS. Con bytes salía un `underflow` en comptime.
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
/// SOLO el wordmark. La cabecera se queja de "basura en la vista", y el usuario
/// tiene razón: una mascota de 18 filas, una línea de saludo y otra de atajos
/// son 20 filas de cabecera antes de la primera palabra del chat. Esto es lo
/// que se pidió literalmente ("solo coloca arriba ZODE y listo"), y es el
///-banner que había antes de meter a Houston (ver AGENTS.md, v4).
///
/// El art va en un solo bloque a propósito: partido en párrafos, la línea más
/// ancha manda en el ajuste de todos ellos.
pub const banner = bannerRow(0) ++ "\n" ++
    bannerRow(1) ++ "\n" ++
    bannerRow(2) ++ "\n" ++
    bannerRow(3) ++ "\n" ++
    bannerRow(4);

/// Dos fotogramas de la cara para la franja de actividad.
///
/// La mascotita tiene que MOVERSE mientras el modelo trabaja: es la unica
/// señal de que la app esta viva cuando el stream va lento. Un icono estatico
/// no dice si esta pensando o colgado.
///
/// El segundo fotograma es el mismo visor con un ojo entornado (`◔`), que con
/// los dos abiertos (`◕`) alternando se lee como un parpadeo.
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

/// Does this art line carry a mark? (for the invariant test)
pub fn isWordmarkLine(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "*") != null;
}
