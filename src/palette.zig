const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const theme = @import("theme.zig");
const tui = @import("tui.zig");

const Painter = tui.Painter;

/// Paleta modal de comandos y modelos, al estilo de opencode / Claude Code.
///
/// Dos modos:
///   - `.commands`: lista agrupada de comandos con el atajo a la derecha.
///   - `.models`:   DOS COLUMNAS. La izquierda son los providers (con su
///                  estado de key) y la derecha los modelos del provider
///                  resaltado. Es lo que hace opencode: provider -> modelos.
///
/// El módulo no sabe nada de providers, de red ni de sesiones: quien lo abre
/// le pasa la lista de `Item` y recibe la selección. Eso lo hace testeable sin
/// red y deja el dibujo separado de los datos.
///
/// Invariante importante: `sel[c]` indexa `filtered[c]`, NUNCA `items`. Antes
/// de tener esta nota el dibujo filtraba sobre la marcha mientras la selección
/// contaba sobre la lista completa, y con cualquier filtro la Highlight iba a
/// la fila equivocada.
pub const Mode = enum {
    commands,
    models,
    /// Modal de conectar: columna de providers + "Connect an integration".
    connect,
    /// Escribir la API key de un provider.
    key_prompt,
};

pub const Kind = enum {
    command,
    provider,
    model,
    /// "Connect an integration": pide la key del provider de la fila.
    connect,
};

pub const Item = struct {
    kind: Kind,
    /// Índice del encabezado de grupo (0 = sin grupo). El valor es un índice
    /// +1 sobre `groups`.
    group: u8 = 0,
    label: []const u8 = "",
    /// Columna derecha: atajo de teclado, "free", precio…
    hint: []const u8 = "",
};

pub const Group = struct {
    name: []const u8,
};

pub const max_query = 64;
pub const max_key = 128;

pub const Palette = struct {
    gpa: std.mem.Allocator,
    active: bool = false,
    mode: Mode = .commands,

    /// Filtro de búsqueda (la línea "search" del modal).
    query: [max_query]u8 = undefined,
    query_len: usize = 0,

    /// Columna activa en modo modelos: 0 = providers, 1 = modelos.
    col: u8 = 1,
    sel: [2]usize = .{ 0, 0 },
    scroll: [2]usize = .{ 0, 0 },
    /// Índices (sobre `items`) que sobreviven al filtro, uno por columna.
    filtered: [2]std.ArrayList(u32) = .{ .empty, .empty },

    /// Datos que rellena quien abre la paleta.
    items: []const Item = &.{},
    groups: []const Group = &.{},
    /// ¿La paleta es dueña de `items` (y de sus strings)? Si lo es, los libera
    /// al reemplazarlos. Lo pone `setItemsOwned`.
    owns_items: bool = false,

    /// Modo `.key_prompt`.
    key_item: u32 = 0,
    key_input: [max_key]u8 = undefined,
    key_len: usize = 0,
    key_msg: [96]u8 = undefined,
    key_msg_len: usize = 0,

    pub fn init(gpa: std.mem.Allocator) Palette {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Palette) void {
        self.filtered[0].deinit(self.gpa);
        self.filtered[1].deinit(self.gpa);
    }

    pub fn queryText(self: *const Palette) []const u8 {
        return self.query[0..self.query_len];
    }
    pub fn keyText(self: *const Palette) []const u8 {
        return self.key_input[0..self.key_len];
    }
    pub fn keyMessage(self: *const Palette) []const u8 {
        return self.key_msg[0..self.key_msg_len];
    }

    pub fn setKeyMessage(self: *Palette, msg: []const u8) void {
        const n = @min(msg.len, self.key_msg.len);
        @memcpy(self.key_msg[0..n], msg[0..n]);
        self.key_msg_len = n;
    }

    /// Mensaje con formato (los callers vienen de `agent`, que no puede tocar
    /// el buffer de la palette directamente).
    pub fn setKeyMessagef(self: *Palette, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.key_msg, fmt, args) catch return;
        self.key_msg_len = s.len;
    }

    /// Índice (sobre `items`) del provider resaltado en la columna izquierda,
    /// o null si no hay ninguno. Lo usa Ctrl+A para saber a quién va la key.
    pub fn providerHighlighted(self: *const Palette) ?u32 {
        if (self.mode != .models) return null;
        const f = self.filtered[0].items;
        if (self.sel[0] >= f.len) return null;
        const idx = f[self.sel[0]];
        if (self.items[idx].kind != .provider) return null;
        return idx;
    }

    /// ¿Item de la columna actual? En modo modelos la columna 0 son providers.
    pub fn column(self: *const Palette) usize {
        return if (self.mode == .models) self.col else 0;
    }

    /// ¿Es un modal de una sola columna? (comandos, conectar, key)
    pub fn isSingleColumn(self: *const Palette) bool {
        return self.mode != .models;
    }

    /// Item resaltado de la columna actual, o null.
    pub fn selected(self: *const Palette) ?Item {
        const c = self.column();
        const f = self.filtered[c].items;
        if (self.sel[c] >= f.len) return null;
        return self.items[f[self.sel[c]]];
    }

    /// Ídem por columna explícita (para el test y para el dibujo).
    pub fn selectedIn(self: *const Palette, c: usize) ?Item {
        const f = self.filtered[c].items;
        if (self.sel[c] >= f.len) return null;
        return self.items[f[self.sel[c]]];
    }

    pub fn countIn(self: *const Palette, c: usize) usize {
        return self.filtered[c].items.len;
    }

    /// Carga una lista nueva y vuelve a filtrar. Quien llama mantiene `items`
    /// y `groups` vivos (son de su arena o del allocator del modelo).
    pub fn setItems(self: *Palette, items: []const Item, groups: []const Group) void {
        self.setItemsBorrowed(items, groups);
    }

    /// Igual que `setItems` pero la paleta pasa a ser dueña de `items` (y de
    /// sus strings) y libera los de la lista anterior al reemplazarlos.
    ///
    /// Importante para el worker de modelos: si entregara un slice de
    /// `models_mod.Model` y liberara la lista justo después, los `id` de los
    /// items serían punteros colgantes y el dibujo reventaba con
    /// `InvalidStartByte` al pintar la columna de modelos.
    pub fn setItemsBorrowed(self: *Palette, items: []const Item, groups: []const Group) void {
        self.releaseItems();
        self.items = items;
        self.owns_items = false;
        self.groups = groups;
        self.resetSelection();
    }

    pub fn setItemsOwned(self: *Palette, items: []Item, groups: []const Group) void {
        self.releaseItems();
        self.items = items;
        self.owns_items = true;
        self.groups = groups;
        self.resetSelection();
    }

    fn resetSelection(self: *Palette) void {
        self.sel = .{ 0, 0 };
        self.scroll = .{ 0, 0 };
        // En `.connect` la lista única es la columna 0; en `.models` se empieza
        // en la de modelos, que es la que se viene a mirar.
        self.col = if (self.mode == .models) 1 else 0;
        self.refilter();
    }

    /// Repuebla las dos listas filtradas. Una columna, dos: en modo modelos la
    /// 0 son providers (`provider`/`connect`) y la 1 son `model`. En modo
    /// comandos todo va a la columna 0.
    pub fn refilter(self: *Palette) void {
        const q = self.queryText();
        // En modo `.connect` TODO va a la columna 0 (es una sola lista), así
        // que se comporta como `.commands` pero con los items de provider.
        const single = self.mode == .commands or self.mode == .connect or self.mode == .key_prompt;
        // En el modo de dos columnas SOLO filtra la que tiene el foco. Filtrar
        // las dos dejaba la otra en blanco al buscar, y daba la sensacion de
        // que la lista de modelos no existia: se escribia "sonnet" y no veias
        // ni un modelo, solo "no matches" en las dos columnas.
        const focus = self.column();
        for (0..2) |c| {
            self.filtered[c].clearRetainingCapacity();
            for (self.items, 0..) |it, i| {
                const in_col: bool = if (single)
                    c == 0
                else if (c == 0)
                    (it.kind == .provider or it.kind == .connect)
                else
                    (it.kind == .model);
                if (!in_col) continue;
                if (!single and c != focus and q.len > 0) {
                    self.filtered[c].append(self.gpa, @intCast(i)) catch return;
                    continue;
                }
                if (!matches(it, self.groups, q)) continue;
                self.filtered[c].append(self.gpa, @intCast(i)) catch return;
            }
        }
        for (0..2) |c| {
            if (self.sel[c] >= self.filtered[c].items.len) {
                self.sel[c] = if (self.filtered[c].items.len == 0) 0 else self.filtered[c].items.len - 1;
            }
            if (self.scroll[c] > self.sel[c]) self.scroll[c] = self.sel[c];
        }
    }

    pub fn move(self: *Palette, c: usize, delta: isize) void {
        const n = self.filtered[c].items.len;
        if (n == 0) return;
        const cur: isize = @intCast(self.sel[c]);
        var next = cur + delta;
        if (next < 0) next = 0;
        if (next >= @as(isize, @intCast(n))) next = @as(isize, @intCast(n)) - 1;
        self.sel[c] = @intCast(next);
    }

    /// Mantiene el item resaltado dentro de la ventana de `rows`.
    pub fn clampScroll(self: *Palette, c: usize, rows: usize) void {
        if (rows == 0) return;
        if (self.sel[c] < self.scroll[c]) self.scroll[c] = self.sel[c];
        if (self.sel[c] >= self.scroll[c] + rows) self.scroll[c] = self.sel[c] - rows + 1;
        const n = self.filtered[c].items.len;
        if (n > rows and self.scroll[c] > n - rows) self.scroll[c] = n - rows;
    }

    /// Libera los items propios (labels y hints) y vacía la lista.
    pub fn releaseItems(self: *Palette) void {
        if (self.owns_items) freeItems(self.gpa, self.items);
        self.items = &.{};
        self.owns_items = false;
    }

    /// Cierra la paleta para el redraw. NO libera los items: se puede reabrir en
    /// sitio (paleta de modelos → conectar) y entonces `setItemsOwned` los
    /// libera a los suyos. Para soltar la memoria, `destroy`.
    pub fn close(self: *Palette) void {
        self.active = false;
        self.mode = .commands;
        self.query_len = 0;
        self.key_len = 0;
        self.key_msg_len = 0;
        self.col = 1;
        self.sel = .{ 0, 0 };
        self.scroll = .{ 0, 0 };
        // OJO: los items NO se sueltan aquí. Con `items = &.{}` a pelo se
        // perdían las etiquetas propias (cada Ctrl+P que se cerraba era una
        // fuga) y además `owns_items` se quedaba en `true` con una lista
        // vacía, que es peor: parece que la paleta es dueña de algo.
        self.filtered[0].clearRetainingCapacity();
        self.filtered[1].clearRetainingCapacity();
    }

    /// Cierra la paleta y libera lo que sea suyo. Al salir del proceso.
    pub fn destroy(self: *Palette) void {
        self.releaseItems();
        self.deinit();
    }
};

// ── filtrado ─────────────────────────────────────────────────

/// ¿El item sobrevive al filtro?
///
/// Es una paleta de búsqueda, no el autocompletado de `/`: aquí la SUBCADENA
/// es lo que se quiere. Con prefijo estricto, escribir "mod" no encontraba
/// "/model" (que empieza por barra) y el buscador parecía roto. Orden: prefijo
/// primero (caso habitual y barato), luego subcadena del label, luego el hint
/// y por último el nombre del grupo, para que "model" saque el grupo entero.
pub fn matches(item: Item, groups: []const Group, q: []const u8) bool {
    if (q.len == 0) return true;
    if (startsWithIgnoreCase(item.label, q)) return true;
    if (containsIgnoreCase(item.label, q)) return true;
    if (item.hint.len > 0 and containsIgnoreCase(item.hint, q)) return true;
    // El nombre del grupo es una via MAS para encontrar, nunca un veto: con un
    // `return containsIgnoreCase(...)` el grupo vetaba la coincidencia y buscar
    // "sonnet" no encontraba "claude-sonnet-4" (vive en el grupo "Models",
    // que no tiene "sonnet"). Ademas al hacer Enter con la lista filtrada vacia
    // se acababa aplicando un modelo que no era el resaltado.
    for (groups, 0..) |g, i| {
        if (i + 1 == item.group and containsIgnoreCase(g.name, q)) return true;
    }
    return false;
}

pub fn startsWithIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    for (needle, 0..) |nc, i| {
        if (std.ascii.toLower(hay[i]) != std.ascii.toLower(nc)) return false;
    }
    return true;
}

pub fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

// ── tests ─────────────────────────────────────────────────────

const t = std.testing;

test "matches: prefijo, subcadena, hint y nombre de grupo" {
    const groups = [_]Group{ .{ .name = "Modelo" }, .{ .name = "Sesión" } };

    // Grupo "Modelo": buscar "model" saca el item entero.
    const it = Item{ .kind = .command, .group = 1, .label = "/model" };
    try t.expect(matches(it, &groups, "")); // filtro vacío deja todo
    try t.expect(matches(it, &groups, "/mo")); // prefijo
    try t.expect(matches(it, &groups, "/model"));
    try t.expect(matches(it, &groups, "mod")); // subcadena: sin esto no aparece
    try t.expect(matches(it, &groups, "model")); // y por el nombre del grupo

    // Grupo "Sesión": "mod" NO debe colarse (ni por label ni por grupo).
    const it2 = Item{ .kind = .command, .group = 2, .label = "/new" };
    try t.expect(!matches(it2, &groups, "mod"));
    try t.expect(matches(it2, &groups, "ses")); // sí por el nombre del grupo

    // Un hint hace match aunque el label no (el precio "free").
    const it3 = Item{ .kind = .model, .label = "sonnet", .hint = "free" };
    try t.expect(matches(it3, &groups, "free"));
    try t.expect(matches(it3, &groups, "sonnet"));
    try t.expect(!matches(it3, &groups, "gpt"));
}

test "matches: el grupo NO veta la coincidencia del label" {
    // Regresión: el grupo se comprobaba con `return containsIgnoreCase(...)`,
    // es decir como veto. Buscar "sonnet" no encontraba "claude-sonnet-4",
    // porque vive en el grupo "Models" y ahí no aparece "sonnet". Con la lista
    // filtrada vacia, Enter acababa aplicando un modelo que no era el
    // resaltado.
    const groups = [_]Group{ .{ .name = "Providers" }, .{ .name = "" }, .{ .name = "Models" } };
    const m = Item{ .kind = .model, .group = 3, .label = "anthropic/claude-sonnet-4" };
    try t.expect(matches(m, &groups, "sonnet"));
    try t.expect(matches(m, &groups, "claude"));
    // Y buscar por el nombre del grupo sigue funcionando.
    try t.expect(matches(m, &groups, "model"));
    try t.expect(!matches(m, &groups, "gpt"));
}

test "refilter: en dos columnas solo filtra la que tiene el foco" {
    var pal = Palette.init(t.allocator);
    defer pal.deinit();
    pal.mode = .models;
    const groups = [_]Group{ .{ .name = "Providers" }, .{ .name = "" }, .{ .name = "Models" } };
    const items = [_]Item{
        .{ .kind = .provider, .group = 1, .label = "openrouter" },
        .{ .kind = .provider, .group = 1, .label = "groq" },
        .{ .kind = .model, .group = 3, .label = "claude-sonnet-4" },
        .{ .kind = .model, .group = 3, .label = "gpt-5" },
    };
    pal.setItems(&items, &groups);
    try t.expectEqual(@as(u8, 1), pal.col); // foco en modelos

    @memcpy(pal.query[0..6], "sonnet");
    pal.query_len = 6;
    pal.refilter();
    // Solo se filtra la columna enfocada: 1 modelo y los 2 providers intactos.
    try t.expectEqual(@as(usize, 1), pal.countIn(1));
    try t.expectEqual(@as(usize, 2), pal.countIn(0));

    // Al pasar el foco a providers, ahora se filtra esa y no la otra.
    pal.col = 0;
    pal.refilter();
    try t.expectEqual(@as(usize, 0), pal.countIn(0));
    try t.expectEqual(@as(usize, 2), pal.countIn(1));
}

test "refilter: dos columnas, providers y modelos no se mezclan" {
    var pal = Palette.init(t.allocator);
    defer pal.deinit();
    pal.mode = .models;
    const items = [_]Item{
        .{ .kind = .provider, .label = "opencode" },
        .{ .kind = .provider, .label = "openrouter" },
        .{ .kind = .connect, .label = "Connect an integration" },
        .{ .kind = .model, .label = "deepseek-chat" },
        .{ .kind = .model, .label = "gpt-5" },
    };
    pal.setItems(&items, &.{});

    try t.expectEqual(@as(usize, 3), pal.countIn(0)); // 2 providers + connect
    try t.expectEqual(@as(usize, 2), pal.countIn(1)); // 2 modelos

    // El filtro se aplica SOLO a la columna con el foco (aqui la de modelos,
    // col=1): "gpt" deja 1 modelo y la columna de providers intacta, para que
    // siga de contexto en vez de desaparecer.
    @memcpy(pal.query[0..3], "gpt");
    pal.query_len = 3;
    pal.refilter();
    try t.expectEqual(@as(usize, 1), pal.countIn(1));
    try t.expectEqual(@as(usize, 3), pal.countIn(0));
}

test "refilter: la selección se recorta al tamaño de la lista filtrada" {
    var pal = Palette.init(t.allocator);
    defer pal.deinit();
    const items = [_]Item{
        .{ .kind = .command, .label = "/help" },
        .{ .kind = .command, .label = "/model" },
        .{ .kind = .command, .label = "/context" },
    };
    pal.setItems(&items, &.{});
    try t.expectEqual(@as(usize, 3), pal.countIn(0));
    pal.sel[0] = 2; // "/context"

    @memcpy(pal.query[0..3], "mod");
    pal.query_len = 3;
    pal.refilter();
    // Solo "/model" sobrevive: la selección no puede quedarse en el índice 2.
    try t.expectEqual(@as(usize, 1), pal.countIn(0));
    try t.expectEqual(@as(usize, 0), pal.sel[0]);
    try t.expectEqualStrings("/model", pal.selected().?.label);
}

test "move: no se sale de los extremos" {
    var pal = Palette.init(t.allocator);
    defer pal.deinit();
    const items = [_]Item{
        .{ .kind = .command, .label = "a" },
        .{ .kind = .command, .label = "b" },
    };
    pal.setItems(&items, &.{});

    pal.move(0, -1);
    try t.expectEqual(@as(usize, 0), pal.sel[0]);
    pal.move(0, 5);
    try t.expectEqual(@as(usize, 1), pal.sel[0]);
    pal.move(0, 1);
    try t.expectEqual(@as(usize, 1), pal.sel[0]);
    pal.move(0, -2);
    try t.expectEqual(@as(usize, 0), pal.sel[0]);
}

test "clampScroll: la selección siempre visible" {
    var pal = Palette.init(t.allocator);
    defer pal.deinit();
    var items: [10]Item = undefined;
    for (&items) |*it| {
        it.* = .{ .kind = .command, .label = "x" };
    }
    pal.setItems(&items, &.{});

    pal.sel[0] = 9;
    pal.clampScroll(0, 4);
    try t.expect(pal.sel[0] >= pal.scroll[0]);
    try t.expect(pal.sel[0] < pal.scroll[0] + 4);

    pal.sel[0] = 0;
    pal.clampScroll(0, 4);
    try t.expectEqual(@as(usize, 0), pal.scroll[0]);
}

// ── dibujo ────────────────────────────────────────────────────

/// Ancho en COLUMNAS de un texto (los ids de modelo llevan `/` y `·`, que son
/// de 1, pero los emoji y los `▸` no). Contar bytes descuadra la columna
/// derecha, que se alinea por ancho real.
fn displayWidth(text: []const u8) usize {
    var n: usize = 0;
    var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (it.nextCodepoint()) |cp| {
        _ = cp;
        n += 1;
    }
    return n;
}

/// Libera una lista de items con sus strings. Cada `label`/`hint` es una copia
/// propia (dup), no un slice del allocator del llamante: si lo fueran, el
/// liberado dejaría punteros colgantes en la paleta.
pub fn freeItems(gpa: std.mem.Allocator, items: []const Item) void {
    for (items) |it| {
        gpa.free(it.label);
        gpa.free(it.hint);
    }
    gpa.free(@constCast(items));
}

/// Geometría del modal. Se calcula una vez y la usan tanto el dibujo como el
/// `clampScroll`, para que no se puedan divergir.
pub const Box = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    /// Ancho de la columna izquierda (modo modelos).
    col_w: u16,
    /// Filas útiles para items, sin título, búsqueda ni pie.
    list_rows: usize,
    /// Fila de la primera línea de item.
    list_top: u16,
};

/// Calcula el tamaño del modal. Modo modelos: dos columnas; comandos: una.
pub fn boxFor(pal: *const Palette, width: u16, height: u16) Box {
    const w: u16 = @min(width -| 4, 76);
    const h: u16 = @min(height -| 4, 24);
    // El prompt de key necesita más alto: tiene campo, mensaje y dos hints.
    const hh: u16 = if (pal.mode == .key_prompt) @min(height -| 4, 12) else h;
    const two_cols = pal.mode == .models and pal.countIn(0) > 0;
    const col_w: u16 = if (two_cols) @max(18, w / 3) else w;
    // h = borde(1) + titulo(1) + busqueda(1) + items + pie(1) + borde(1)
    const list_rows: usize = if (hh > 7) @as(usize, hh) - 5 else 1;
    return .{
        .x = (width -| w) / 2,
        .y = @max(1, (height -| hh) / 4),
        .w = w,
        .h = hh,
        .col_w = col_w,
        .list_rows = list_rows,
        .list_top = 0, // lo fija `draw` (depende del modo key_prompt)
    };
}

/// Pinta el modal completo. El historial de detrás se limpia con un espacio:
/// el surface de vaxis ya trae el texto del historial y sin limpiar, los items
/// del modal se transparentaría sobre él.
pub fn draw(
    p: *Painter,
    surface: *vxfw.Surface,
    pal: *Palette,
    width: u16,
    height: u16,
) void {
    const box = boxFor(pal, width, height);
    if (box.w < 24 or box.h < 8) return;

    // ── fondo y bordes ──
    var y: u16 = 0;
    while (y < box.h) : (y += 1) {
        p.fillRange(box.x, box.x + box.w, box.y + y, " ", .{});
    }
    p.fillRange(box.x + 1, box.x + box.w - 1, box.y, "─", theme.brand_faint);
    p.fillRange(box.x + 1, box.x + box.w - 1, box.y + box.h - 1, "─", theme.brand_faint);
    var yy: u16 = 1;
    while (yy < box.h - 1) : (yy += 1) {
        p.putStable(box.x, box.y + yy, "│", 1, theme.brand_faint);
        p.putStable(box.x + box.w - 1, box.y + yy, "│", 1, theme.brand_faint);
    }
    p.putStable(box.x, box.y, "╭", 1, theme.brand_faint);
    p.putStable(box.x + box.w - 1, box.y, "╮", 1, theme.brand_faint);
    p.putStable(box.x, box.y + box.h - 1, "╰", 1, theme.brand_faint);
    p.putStable(box.x + box.w - 1, box.y + box.h - 1, "╯", 1, theme.brand_faint);

    // ── título (izquierda) y "esc" (derecha) ──
    const title = switch (pal.mode) {
        .commands => "Commands",
        .models => "Switch model",
        .connect => "Connect",
        .key_prompt => "Connect",
    };
    var tb: [32]u8 = undefined;
    const t1 = std.fmt.bufPrint(&tb, " {s}", .{title}) catch " ";
    _ = p.putText(box.x + 2, box.y + 1, t1, theme.brand_bold);
    _ = p.putText(box.x + box.w - 4, box.y + 1, "esc", theme.brand_soft);

    if (pal.mode == .key_prompt) {
        drawKeyPrompt(p, pal, box);
        drawFooter(p, pal, box);
        surface.cursor = .{
            .row = box.y + 4,
            .col = box.x + 3 + @as(u16, @intCast(pal.key_len)),
        };
        return;
    }

    // ── línea de búsqueda, con el cursor al final de lo escrito ──
    const sy = box.y + 2;
    _ = p.putText(box.x + 2, sy, "▌", theme.brand_bold);
    const q = pal.queryText();
    if (q.len > 0) {
        _ = p.putText(box.x + 3, sy, q, theme.brand);
    } else {
        _ = p.putText(box.x + 3, sy, "search", theme.brand_faint);
    }
    surface.cursor = .{ .row = sy, .col = box.x + 3 + @as(u16, @intCast(q.len)) };

    // ── lista ──
    if (pal.mode == .models and pal.countIn(0) > 0) {
        // Columna de providers + separador + columna de modelos.
        var ry: u16 = 3;
        while (ry < box.h - 2) : (ry += 1) {
            p.putStable(box.x + box.col_w, box.y + ry, "│", 1, theme.brand_faint);
        }
        drawColumn(p, pal, box, 0, box.x + 1, box.col_w - 1);
        drawColumn(p, pal, box, 1, box.x + box.col_w + 1, box.w - box.col_w - 2);
    } else {
        drawColumn(p, pal, box, 0, box.x + 1, box.w - 2);
    }

    // ── pie ──
    drawFooter(p, pal, box);
}

/// Una columna de items, con encabezado de grupo, scroll y resaltado.
fn drawColumn(p: *Painter, pal: *Palette, box: Box, c: usize, x0: u16, w: u16) void {
    const filtered = pal.filtered[c].items;
    if (filtered.len == 0) {
        const msg: []const u8 = if (pal.mode == .connect) "no providers" else "no matches";
        _ = p.putText(x0 + 2, box.y + 3, msg, theme.brand_faint);
        return;
    }
    pal.clampScroll(c, box.list_rows);

    var shown: usize = 0;
    var last_group: u8 = 0;
    var i = pal.scroll[c];
    while (i < filtered.len and shown < box.list_rows) : (i += 1) {
        const it = pal.items[filtered[i]];

        // Encabezado de grupo, con una línea en blanco antes (como opencode).
        if (it.group != 0 and it.group != last_group) {
            last_group = it.group;
            if (shown > 0) {
                shown += 1; // separador entre grupos
                if (shown >= box.list_rows) break;
            }
            const gname = groupName(pal, it.group);
            if (gname.len > 0 and w > 2) {
                _ = p.putText(x0 + 1, box.y + 3 + @as(u16, @intCast(shown)), gname, theme.group);
            }
            shown += 1;
            if (shown >= box.list_rows) break;
        }

        // OJO: la fila se calcula DESPUÉS del bloque de grupo. Si se calculara
        // antes, la etiqueta salía una fila por encima y el encabezado se
        // comía su sitio (la lista parecía desordenada).
        const row = box.y + 3 + @as(u16, @intCast(shown));
        // Solo la columna CON FOCO resalta de verdad. Antes las dos pintaban su
        // seleccion igual y no habia forma de saber cual estaba activa: se
        // pulsaban las flechas y la lista de modelos no se movia, que es
        // exactamente lo que hace pensar que la lista no existe.
        const is_sel = i == pal.sel[c];
        const focused = c == pal.column();
        if (is_sel and focused) p.fillRange(x0, x0 + w, row, " ", theme.selected);
        // En la columna sin foco, la fila elegida se marca con un ▸ y en azul
        // apagado: se ve cual es sin parecer que tiene el foco.
        if (is_sel and !focused) _ = p.putText(x0, row, "▸", theme.brand_soft);
        _ = p.putText(
            x0 + 1,
            row,
            it.label,
            if (is_sel) theme.item_sel else if (focused) theme.item else theme.dim,
        );

        // Columna derecha alineada al borde: atajo, "free", precio…
        //
        // Solo si caben ETIQUETA y hint con un hueco de por medio. Antes solo
        // se miraba que el hint himself cabía, y en la columna estrecha de
        // providers el hint se pintaba ENCIMA de la etiqueta y se leia
        // "anthrclaude-sonnet-4-5". La etiqueta manda: es lo que se selecciona.
        const label_w = displayWidth(it.label);
        const hint_w = displayWidth(it.hint);
        if (hint_w > 0 and label_w + hint_w + 3 <= w) {
            _ = p.putText(
                x0 + w - 1 - @as(u16, @intCast(hint_w)),
                row,
                it.hint,
                if (is_sel) theme.item_sel else theme.brand_faint,
            );
        }
        shown += 1;
    }
}

fn drawFooter(p: *Painter, pal: *const Palette, box: Box) void {
    const fy = box.y + box.h - 2;
    const hint: []const u8 = switch (pal.mode) {
        .commands => "↑↓ move · enter run · esc close",
        .models => "↑↓ move · tab switch column · enter use",
        .connect => "↑↓ move · enter choose · esc back",
        .key_prompt => "",
    };
    if (hint.len > 0 and hint.len + 4 < box.w) {
        _ = p.putText(box.x + box.w - 2 - @as(u16, @intCast(hint.len)), fy, hint, theme.brand_soft);
    }
    if (pal.mode == .models) {
        // Atajo para conectar sin tener que llegar al item de abajo.
        const left = "ctrl+a connect";
        if (left.len + 4 < box.w) {
            _ = p.putText(box.x + 2, fy, left, theme.brand);
        }
    }
}

fn drawKeyPrompt(p: *Painter, pal: *const Palette, box: Box) void {
    const top = box.y + 3;
    const label = if (pal.key_item < pal.items.len) pal.items[pal.key_item].label else "provider";

    // Explicar a qué provider va la key ANTES del campo: si no, no se sabe si
    // se está connectando el que está resaltado o el que está activo.
    _ = p.putText(box.x + 3, top, "Connecting", theme.brand_soft);
    _ = p.putText(box.x + 3 + 11, top, label, theme.brand_bold);

    var pb: [96]u8 = undefined;
    const prompt = std.fmt.bufPrint(&pb, "API key for {s}", .{label}) catch "API key";
    _ = p.putText(box.x + 3, top + 1, prompt, theme.brand);

    // Enmascarado, como un campo de password. Se ven los últimos 3 caracteres
    // para poder comprobar que no has pegado algo truncado.
    const typed = pal.keyText();
    const masked_len: usize = if (typed.len > 3) typed.len - 3 else 0;
    var w: u16 = 0;
    var x = box.x + 3;
    while (w < masked_len) : (w += 1) {
        _ = p.putStable(x, top + 3, "*", 1, theme.brand_soft);
        x += 1;
    }
    if (typed.len > masked_len) {
        const tail = typed[masked_len..];
        _ = p.putText(x, top + 3, tail, theme.brand);
        x += @as(u16, @intCast(tail.len));
    }
    // Cursor al final del campo (subrayado, para que se vea dónde escribir).
    _ = p.putStable(x, top + 3, "_", 1, theme.brand_bold);

    const msg = pal.keyMessage();
    const my = top + 5;
    if (msg.len > 0) {
        const bad = std.mem.indexOf(u8, msg, "no se pudo") != null or
            std.mem.indexOf(u8, msg, "vacía") != null;
        _ = p.putText(box.x + 3, my, msg, if (bad) theme.err else theme.brand_soft);
    }

    const hint = "enter saves · esc cancels";
    if (hint.len + 6 < box.w) {
        _ = p.putText(box.x + box.w - 2 - @as(u16, @intCast(hint.len)), my, hint, theme.brand_faint);
    }
    if (my + 1 < box.y + box.h - 1) {
        const hint2 = "saved to ~/.config/zode/auth.json (0600), never to config.json";
        if (hint2.len + 6 < box.w) {
            _ = p.putText(box.x + 3, my + 1, hint2, theme.brand_faint);
        }
    }
}

const palette_max_key_plus = max_key + 8;

fn groupName(pal: *const Palette, group: u8) []const u8 {
    if (group == 0) return "";
    const i: usize = @as(usize, group) - 1;
    if (i >= pal.groups.len) return "";
    return pal.groups[i].name;
}

// ── entrada ───────────────────────────────────────────────────

/// Qué hacer con la paleta cerrada. Lo decide el modelo (que es quien conoce
/// los providers y el agente), así que aquí solo se reporta la intención.
pub const Action = union(enum) {
    none,
    /// Ejecutar este comando del agente (p. ej. "model", "new", "context").
    run_command: []const u8,
    /// Cambiar a este provider.
    set_provider: []const u8,
    /// Cambiar a este modelo.
    set_model: []const u8,
    /// Conectar un provider con esta key. Los dos slices apuntan a buffers de
    /// la propia palette: quien recibe la acción debe copiarlos ANTES de
    /// cerrar la palette.
    connect: struct { provider: []const u8, key: []const u8 },
    /// Cerrar.
    close,
};

/// Traduce una tecla a la acción correspondiente.
///
/// El llamante pasa la key ya filtrada por el modal (Ctrl+P no debe abrir la
/// paleta mientras se escribe un "p" normal, así que el handler de la TUI
/// decide qué teclas se le pasan).
pub fn handleKey(pal: *Palette, key: vaxis.Key) Action {
    // ── prompt de key ──
    if (pal.mode == .key_prompt) {
        if (key.matches(vaxis.Key.escape, .{})) {
            pal.mode = .models;
            pal.key_len = 0;
            pal.key_msg_len = 0;
            return .{ .none = {} };
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            const provider = if (pal.key_item < pal.items.len) pal.items[pal.key_item].label else "";
            // Se devuelven los slices SIN limpiar: el llamante los copia
            // (guardar la key es I/O) y luego llama a `close`.
            return .{ .connect = .{ .provider = provider, .key = pal.keyText() } };
        }
        if (key.matches(vaxis.Key.backspace, .{})) {
            if (pal.key_len > 0) pal.key_len -= 1;
            return .{ .none = {} };
        }
        if (key.text) |txt| {
            if (txt.len > 0 and pal.key_len < max_key) {
                @memcpy(pal.key_input[pal.key_len .. pal.key_len + txt.len], txt);
                pal.key_len += txt.len;
            }
        }
        return .{ .none = {} };
    }

    const c = pal.column();

    // ── navegación ──
    if (key.matches(vaxis.Key.up, .{})) {
        pal.move(c, -1);
        return .{ .none = {} };
    }
    if (key.matches(vaxis.Key.down, .{})) {
        pal.move(c, 1);
        return .{ .none = {} };
    }
    if (key.matches(vaxis.Key.page_up, .{})) {
        pal.move(c, -8);
        return .{ .none = {} };
    }
    if (key.matches(vaxis.Key.page_down, .{})) {
        pal.move(c, 8);
        return .{ .none = {} };
    }
    if (key.matches(vaxis.Key.escape, .{})) {
        pal.close();
        return .{ .close = {} };
    }

    // En modo modelos, Tab / ←→ cambian de columna (providers <-> modelos).
    if (pal.mode == .models) {
        if (key.matches(vaxis.Key.tab, .{})) {
            pal.col = if (pal.col == 0) 1 else 0;
            pal.refilter(); // la columna que entra en foco pasa a filtrar
            return .{ .none = {} };
        }
        if (key.matches(vaxis.Key.left, .{}) and pal.col == 1) {
            pal.col = 0;
            pal.refilter();
            return .{ .none = {} };
        }
        if (key.matches(vaxis.Key.right, .{}) and pal.col == 0) {
            pal.col = 1;
            pal.refilter();
            return .{ .none = {} };
        }
    }

    // ── búsqueda ──
    if (key.matches(vaxis.Key.backspace, .{})) {
        if (pal.query_len > 0) {
            // Backspace borra un grapheme, no un byte: los acentos y los emoji
            // son multi-byte y parteirlos deja bytes sueltos.
            pal.query_len = backOneGrapheme(pal.query[0..pal.query_len]);
        }
        pal.sel = .{ 0, 0 };
        pal.scroll = .{ 0, 0 };
        pal.refilter();
        return .{ .none = {} };
    }
    if (key.text) |txt| {
        // Solo texto imprimible: las teclas con modificador ya se han filtrado.
        if (txt.len > 0 and !key.mods.ctrl and !key.mods.alt) {
            const n = @min(txt.len, max_query - pal.query_len);
            @memcpy(pal.query[pal.query_len .. pal.query_len + n], txt[0..n]);
            pal.query_len += n;
            pal.sel = .{ 0, 0 };
            pal.scroll = .{ 0, 0 };
            pal.refilter();
        }
        return .{ .none = {} };
    }

    // ── confirmar ──
    if (key.matches(vaxis.Key.enter, .{})) {
        const filtered_index = if (pal.sel[c] < pal.filtered[c].items.len)
            pal.filtered[c].items[pal.sel[c]]
        else
            return Action{ .none = {} };
        const it = pal.items[filtered_index];
        return switch (it.kind) {
            // "Connect" sale como `run_command` y lo atiende el modelo, que es
            // quien sabe abrir la lista de providers. Si se resolviera aquí
            // (cambiando `mode` a `.connect` sin cambiar `items`) la lista
            // seguiría siendo la de comandos con el titulo de Connect.
            .command => .{ .run_command = it.label },
            .provider => blk: {
                if (pal.mode == .connect) {
                    pal.key_item = filtered_index;
                    pal.mode = .key_prompt;
                    pal.key_len = 0;
                    pal.key_msg_len = 0;
                    pal.setKeyMessage("paste the key and press enter");
                    break :blk Action{ .none = {} };
                }
                break :blk Action{ .set_provider = it.label };
            },
            .model => .{ .set_model = it.label },
            .connect => blk: {
                pal.mode = .key_prompt;
                pal.key_len = 0;
                pal.key_msg_len = 0;
                pal.setKeyMessage("choose a provider first");
                break :blk Action{ .none = {} };
            },
        };
    }
    return .{ .none = {} };
}

/// Índice del último carácter UTF-8 completo antes de `len`.
fn backOneGrapheme(s: []const u8) usize {
    if (s.len == 0) return 0;
    var i = s.len - 1;
    while (i > 0) {
        // Un byte UTF-8 de continuación vale 10xxxxxx.
        if ((s[i] & 0xC0) != 0x80) break;
        i -= 1;
    }
    return i;
}

// ── tests ─────────────────────────────────────────────────────

test "backOneGrapheme: borra un grapheme, no un byte" {
    // "ñ" son 2 bytes y "🙂" son 4: con un `len - 1` a secas se dejaban bytes
    // sueltos y el buscador acumulaba basura UTF-8 inválida.
    try t.expectEqual(@as(usize, 0), backOneGrapheme(""));
    try t.expectEqual(@as(usize, 0), backOneGrapheme("a"));
    try t.expectEqual(@as(usize, 1), backOneGrapheme("ab"));
    // "añ"
    try t.expectEqual(@as(usize, 1), backOneGrapheme("a\xc3\xb1"));
    // "🙂" (4 bytes)
    try t.expectEqual(@as(usize, 0), backOneGrapheme("\xf0\x9f\x99\x82"));
    // "🙂ñ" -> deja "🙂"
    try t.expectEqual(@as(usize, 4), backOneGrapheme("\xf0\x9f\x99\x82\xc3\xb1"));
}

test "handleKey: escribir filtra y enter devuelve la acción" {
    var pal = Palette.init(t.allocator);
    defer pal.deinit();
    const items = [_]Item{
        .{ .kind = .command, .label = "/help" },
        .{ .kind = .command, .label = "/model" },
        .{ .kind = .command, .label = "/context" },
    };
    pal.setItems(&items, &.{});
    pal.active = true;

    // Escribir "mod" deja solo /model.
    // Una Key real de vaxis trae `.text`; el código de caracteres solo no
    // suffitiría (y el test no lo notaría si `text` fuera null).
    for ([_]vaxis.Key{
        .{ .codepoint = 'm', .text = "m" },
        .{ .codepoint = 'o', .text = "o" },
        .{ .codepoint = 'd', .text = "d" },
    }) |k| {
        _ = handleKey(&pal, k);
    }
    try t.expectEqual(@as(usize, 1), pal.countIn(0));
    try t.expectEqualStrings("mod", pal.queryText());

    // Enter devuelve run_command con la etiqueta del item (no el prefijo).
    const act = handleKey(&pal, .{ .codepoint = 13 });
    try t.expectEqualStrings("/model", act.run_command);
}

test "handleKey: esc cierra" {
    var pal = Palette.init(t.allocator);
    defer pal.deinit();
    pal.active = true;
    const act = handleKey(&pal, .{ .codepoint = 27 });
    try t.expect(!pal.active);
    try t.expect(act == .close);
}

test "close NO suelta los items propios: los libera el siguiente setItemsOwned" {
    // `close` se llama en cada Esc y en cada comando ejecutado, y la paleta se
    // puede reabrir EN SITE (modelos → conectar). Antes `close` hacía
    // `items = &.{}` sin liberar: cada Ctrl+P cerrado era una fuga de las
    // etiquetas, y además `owns_items` se quedaba en `true` sobre una lista
    // vacía (la paleta parecía dueña de algo que ya no tenía).
    var pal = Palette.init(t.allocator);
    // `destroy` y no `deinit`: los items son del allocator de test y solo él
    // los suelta (es lo que hace `Model.deinit` → `destroyPalette`).
    defer pal.destroy();

    const owned = t.allocator.alloc(Item, 2) catch unreachable;
    owned[0] = .{ .kind = .command, .label = t.allocator.dupe(u8, "/help") catch unreachable };
    owned[1] = .{ .kind = .command, .label = t.allocator.dupe(u8, "/new") catch unreachable };
    pal.setItemsOwned(owned, &.{});
    pal.active = true;

    pal.close();
    try t.expect(!pal.active);
    // Los items siguen ahí: se pueden reutilizar o liberar después.
    try t.expectEqual(@as(usize, 2), pal.items.len);
    try t.expectEqualStrings("/help", pal.items[0].label);

    // Y al repoblar, los antiguos se sueltan de verdad (el allocator de test
    // falla si no).
    const next = t.allocator.alloc(Item, 1) catch unreachable;
    next[0] = .{ .kind = .command, .label = t.allocator.dupe(u8, "/cache") catch unreachable };
    pal.setItemsOwned(next, &.{});
    try t.expectEqualStrings("/cache", pal.items[0].label);
}

test "handleKey: modo modelos, tab cambia de columna" {
    var pal = Palette.init(t.allocator);
    defer pal.deinit();
    pal.mode = .models;
    const items = [_]Item{
        .{ .kind = .provider, .label = "opencode" },
        .{ .kind = .model, .label = "sonnet" },
    };
    pal.setItems(&items, &.{});
    pal.active = true;

    try t.expectEqual(@as(u8, 1), pal.col);
    _ = handleKey(&pal, .{ .codepoint = 9 }); // tab
    try t.expectEqual(@as(u8, 0), pal.col);
    _ = handleKey(&pal, .{ .codepoint = 9 });
    try t.expectEqual(@as(u8, 1), pal.col);
}

test "handleKey: el prompt de key acumula texto enmascarado" {
    var pal = Palette.init(t.allocator);
    defer pal.deinit();
    pal.mode = .key_prompt;
    pal.active = true;

    for ([_]vaxis.Key{
        .{ .codepoint = 'a', .text = "a" },
        .{ .codepoint = 'b', .text = "b" },
    }) |k| {
        _ = handleKey(&pal, k);
    }
    try t.expectEqualStrings("ab", pal.keyText());
    _ = handleKey(&pal, .{ .codepoint = 127 }); // backspace
    try t.expectEqualStrings("a", pal.keyText());
}

// ── tests de dibujo ───────────────────────────────────────────

test "draw: el modal pinta título, búsqueda y el item resaltado" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var m = tui.Model.init(t.allocator);
    defer m.deinit();

    // OJO: la palette que dibuja el frame es la del MODELO. Configurar una
    // local no cambiaría nada en pantalla.
    const items = [_]Item{
        .{ .kind = .command, .label = "/help" },
        .{ .kind = .command, .label = "/model" },
    };
    m.pal.setItems(&items, &.{});
    m.pal.active = true;

    const s = try tui.drawTest(&m, arena_state.allocator(), 80, 24);
    const all = tui.allText(s);
    try t.expect(std.mem.indexOf(u8, all, "Commands") != null);
    try t.expect(std.mem.indexOf(u8, all, "search") != null);
    try t.expect(std.mem.indexOf(u8, all, "/help") != null);
    try t.expect(std.mem.indexOf(u8, all, "/model") != null);
}

test "draw: los grupos salen con su encabezado y en orden" {
    // Regresión: la fila de cada item se calculaba ANTES del bloque de grupo,
    // así que la etiqueta salía una fila por encima y el encabezado se
    // colocaba encima de la etiqueta siguiente. La lista parecía desordenada.
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var m = tui.Model.init(t.allocator);
    defer m.deinit();

    const groups = [_]Group{ .{ .name = "AAA" }, .{ .name = "BBB" } };
    const items = [_]Item{
        .{ .kind = .command, .group = 1, .label = "uno" },
        .{ .kind = .command, .group = 2, .label = "dos" },
    };
    m.pal.setItems(&items, &groups);
    m.pal.active = true;

    const s = try tui.drawTest(&m, arena_state.allocator(), 80, 24);
    var i_a: ?usize = null;
    var i_uno: ?usize = null;
    var i_b: ?usize = null;
    var i_dos: ?usize = null;
    var line: [256]u8 = undefined;
    var row: u16 = 0;
    while (row < s.size.height) : (row += 1) {
        const r = tui.rowText(s, row, &line);
        if (std.mem.indexOf(u8, r, "AAA") != null) i_a = row;
        if (std.mem.indexOf(u8, r, "uno") != null) i_uno = row;
        if (std.mem.indexOf(u8, r, "BBB") != null) i_b = row;
        if (std.mem.indexOf(u8, r, "dos") != null) i_dos = row;
    }
    try t.expect(i_a != null and i_uno != null and i_b != null and i_dos != null);
    // El encabezado va justo ANTES de su primer item, y en orden.
    try t.expect(i_uno.? > i_a.?);
    try t.expect(i_dos.? > i_b.?);
    try t.expect(i_b.? > i_uno.?);
}

test "draw: modo modelos pinta las dos columnas y el pie" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var m = tui.Model.init(t.allocator);
    defer m.deinit();

    m.pal.mode = .models;
    const groups = [_]Group{ .{ .name = "Providers" }, .{ .name = "" }, .{ .name = "Modelos" } };
    const items = [_]Item{
        .{ .kind = .provider, .group = 1, .label = "openrouter", .hint = "activo" },
        .{ .kind = .connect, .group = 2, .label = "+ connect" },
        .{ .kind = .model, .group = 3, .label = "deepseek-chat", .hint = "free" },
    };
    m.pal.setItems(&items, &groups);
    m.pal.active = true;

    const s = try tui.drawTest(&m, arena_state.allocator(), 90, 26);
    const all = tui.allText(s);
    try t.expect(std.mem.indexOf(u8, all, "Switch model") != null);
    try t.expect(std.mem.indexOf(u8, all, "openrouter") != null);
    try t.expect(std.mem.indexOf(u8, all, "deepseek-chat") != null);
    try t.expect(std.mem.indexOf(u8, all, "free") != null);
    // El pie anuncia el atajo para conectar, que es la vía corta.
    try t.expect(std.mem.indexOf(u8, all, "ctrl+a connect") != null);
}

test "draw: el hint no se pisa con la etiqueta" {
    // Regresión: en la columna estrecha de providers, el hintDefault se
    // pintaba encima de la etiqueta y se leia "anthrclaude-sonnet-4-5".
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var m = tui.Model.init(t.allocator);
    defer m.deinit();

    m.pal.mode = .models;
    const groups = [_]Group{ .{ .name = "Providers" }, .{ .name = "" }, .{ .name = "Modelos" } };
    const items = [_]Item{
        .{ .kind = .provider, .group = 1, .label = "anthropic", .hint = "claude-sonnet-4-5" },
        .{ .kind = .connect, .group = 2, .label = "+ connect" },
        .{ .kind = .model, .group = 3, .label = "x", .hint = "free" },
    };
    m.pal.setItems(&items, &groups);
    m.pal.active = true;

    const s = try tui.drawTest(&m, arena_state.allocator(), 90, 26);
    const all = tui.allText(s);
    // La etiqueta se lee ENTERA: sin el hint encima.
    try t.expect(std.mem.indexOf(u8, all, "anthropic") != null);
    // Y el hint largo, al no caber con la etiqueta, no sale en absoluto.
    try t.expect(std.mem.indexOf(u8, all, "claude-sonnet-4-5") == null);
    // El hint corto sí cabe y se ve.
    try t.expect(std.mem.indexOf(u8, all, "+ connect") != null);
}

test "displayWidth: cuenta columnas, no bytes" {
    // Los ids de modelo llevan "/" y "·" (1 columna, 1-2 bytes). Contar bytes
    // descentraba la columna derecha del hint.
    try t.expectEqual(@as(usize, 9), displayWidth("anthropic"));
    try t.expectEqual(@as(usize, 3), displayWidth("a/b"));
    try t.expectEqual(@as(usize, 0), displayWidth(""));
}

test "draw: el modal Connect lista los providers" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var m = tui.Model.init(t.allocator);
    defer m.deinit();

    m.pal.mode = .connect;
    const items = [_]Item{
        .{ .kind = .provider, .label = "opencode", .hint = "no key" },
        .{ .kind = .provider, .label = "openrouter", .hint = "active" },
    };
    m.pal.setItems(&items, &.{});
    m.pal.active = true;

    const s = try tui.drawTest(&m, arena_state.allocator(), 90, 26);
    const all = tui.allText(s);
    try t.expect(std.mem.indexOf(u8, all, "Connect") != null);
    try t.expect(std.mem.indexOf(u8, all, "opencode") != null);
    try t.expect(std.mem.indexOf(u8, all, "openrouter") != null);
    try t.expect(std.mem.indexOf(u8, all, "no key") != null);
}

test "freeItems: todos los strings son copias propias" {
    // Regresión: el item "+ connect" traía LITERALES ("+ connect", "ctrl+a") y
    // `freeItems` los liberaba. `gpa.free` sobre texto en .rodata es un
    // "Invalid free" que solo salía al salir de la app, con la paleta ya a
    // medio destruir y el canary del allocator reventando: muy difícil de
    // atribuir al item que lo causó.
    //
    // Este test construye los items igual que el worker y los destruye: si
    // alguien vuelve a meter un literal, revienta aquí y no al salir.
    const gpa = std.testing.allocator;
    const items = gpa.alloc(Item, 2) catch return error.OutOfMemory;
    items[0] = .{
        .kind = .provider,
        .label = gpa.dupe(u8, "opencode") catch return error.OutOfMemory,
        .hint = gpa.dupe(u8, "no key") catch return error.OutOfMemory,
    };
    items[1] = .{
        .kind = .connect,
        .label = gpa.dupe(u8, "+ connect") catch return error.OutOfMemory,
        .hint = gpa.dupe(u8, "ctrl+a") catch return error.OutOfMemory,
    };
    freeItems(gpa, items);
}

test "setItemsOwned: reemplaza y libera lo anterior" {
    const gpa = std.testing.allocator;
    var pal = Palette.init(gpa);
    defer pal.deinit();

    const mk = struct {
        fn build(g: std.mem.Allocator, name: []const u8) []Item {
            const it = g.alloc(Item, 1) catch unreachable;
            it[0] = .{
                .kind = .command,
                .label = g.dupe(u8, name) catch unreachable,
                .hint = g.dupe(u8, "hint") catch unreachable,
            };
            return it;
        }
    };

    pal.setItemsOwned(mk.build(gpa, "uno"), &.{});
    try t.expectEqualStrings("uno", pal.items[0].label);
    // Reemplazar debe liberar la anterior: si no, la memoria crece cada vez que
    // se abre la paleta (y `testing.allocator` lo detectaría como fuga).
    pal.setItemsOwned(mk.build(gpa, "dos"), &.{});
    try t.expectEqualStrings("dos", pal.items[0].label);
    pal.releaseItems();
    try t.expectEqual(@as(usize, 0), pal.items.len);
    try t.expect(!pal.owns_items);
}

test "modo modelos: la columna de modelos es la que tiene el foco" {
    // Regresión: `openModelPalette` fijaba el modo DESPUÉS de `setItemsOwned`,
    // y `resetSelection` calcula la columna activa a partir del modo. Con el
    // modo viejo se quedaba en la columna de providers: las flechas no movian
    // la lista de modelos y parecia que no habia nada que elegir.
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var m = tui.Model.init(t.allocator);
    defer m.deinit();

    const items = [_]Item{
        .{ .kind = .provider, .group = 1, .label = "openrouter" },
        .{ .kind = .model, .group = 3, .label = "sonnet" },
        .{ .kind = .model, .group = 3, .label = "gpt-5" },
    };
    m.pal.mode = .models;
    m.pal.setItems(&items, &model_groups_test);
    m.pal.active = true;

    try t.expectEqual(@as(u8, 1), m.pal.col);
    try t.expectEqualStrings("sonnet", m.pal.selected().?.label);
    m.pal.move(1, 1);
    try t.expectEqualStrings("gpt-5", m.pal.selected().?.label);
}

const model_groups_test = [_]Group{
    .{ .name = "Providers" },
    .{ .name = "" },
    .{ .name = "Models" },
};

test "draw: solo la columna enfocada resalta" {
    // Las dos columnas resaltaban su fila y no habia forma de saber cual
    // tenia el foco. La que no lo tiene marca con ▸ y en apagado.
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var m = tui.Model.init(t.allocator);
    defer m.deinit();

    const items = [_]Item{
        .{ .kind = .provider, .group = 1, .label = "openrouter" },
        .{ .kind = .model, .group = 3, .label = "sonnet" },
    };
    m.pal.mode = .models;
    m.pal.setItems(&items, &model_groups_test);
    m.pal.active = true;

    const s = try tui.drawTest(&m, arena_state.allocator(), 90, 26);
    const all = tui.allText(s);
    // El provider elegido se marca con ▸ (sin foco) y el modelo enfocado con
    // la barra de resaltado, que en texto plano solo se ve como la fila entera.
    try t.expect(std.mem.indexOf(u8, all, "▸") != null);
}
