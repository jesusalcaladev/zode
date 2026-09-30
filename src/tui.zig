const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const agent = @import("agent.zig");
const chat = @import("chat.zig");
const md = @import("markdown.zig");
const theme = @import("theme.zig");
const ed_mod = @import("editor.zig");
const mascot = @import("mascot.zig");
const palette = @import("palette.zig");
const models_mod = @import("models.zig");

/// Ítem del picker modal (estilo opencode). Labels/descs son gpa-owned
/// y los libera closePicker.
pub const PickerItem = struct {
    label: []const u8,
    desc: []const u8 = "",
};

pub const PickerCb = *const fn (*Model, tag: u32, label: []const u8) void;

/// Copia inmutable del estado del picker para dibujar (memoria del frame).
const PickerSnapshot = struct {
    title: []const u8,
    query: []const u8,
    sel: usize,
    first_visible: usize,
    total: usize,
    items: []PickerItem,
};

// ── painter: escritura de celdas con graphemes estables ────────
//
// TRAMPA (vaxis 0.6): `vxfw.Surface.writeCell` guarda la `vaxis.Cell` POR
// VALOR, y vaxis lee los BYTES de `char.grapheme` en `Vaxis.render()`, es
// decir DESPUÉS de que este drawFn haya retornado. Un puntero a un temporal
// de stack (`&[_]u8{c}`) llega al renderer como basura (NULs) → pantalla en
// blanco. Regla: el grapheme debe vivir al menos hasta el final del frame,
// es decir ser literal estático, propiedad del Model, o del arena del frame
// (`ctx.arena`, que se resetea al principio del frame SIGUIENTE).
pub const Painter = struct {
    surface: *vxfw.Surface,
    arena: std.mem.Allocator,
    ctx: vxfw.DrawContext,
    width: u16,
    height: u16,

    pub fn measure(self: *const Painter, g: []const u8) u8 {
        return theme.graphemeWidth(self.ctx, g);
    }

    /// Escribe un grapheme YA estable (literal o arena que sobrevive al
    /// frame). No reserva memoria.
    pub fn putStable(self: *Painter, col: u16, row: u16, g: []const u8, w: u8, style: vaxis.Style) void {
        if (col >= self.width or row >= self.height) return;
        self.surface.writeCell(col, row, .{
            .char = .{ .grapheme = g, .width = w },
            .style = style,
        });
    }

    /// Escribe texto efímero: lo copia al arena del frame una sola vez y
    /// luego avanza grapheme a grapheme. Devuelve la columna siguiente.
    /// Escribe texto y devuelve la **columna final** (no el ancho).
    ///
    /// OJO: `col += p.putText(col, ...)` esta MAL, porque suma una posicion
    /// absoluta a otra y el siguiente texto se va a la derecha del todo (fuera
    /// del panel). Para encadenar hay que hacer `col = p.putText(col, ...)`.
    /// Ese bug dejo las opciones del dialogo de permisos con la "A" en la
    /// columna 92 de un panel de 68.
    pub fn putText(self: *Painter, col: u16, row: u16, text: []const u8, style: vaxis.Style) u16 {
        if (text.len == 0 or col >= self.width or row >= self.height) return col;
        const stable = self.arena.dupe(u8, text) catch return col;
        var it = vaxis.unicode.graphemeIterator(stable);
        var c = col;
        while (it.next()) |g| {
            const b = g.bytes(stable);
            const gw = self.measure(b);
            if (c + gw > self.width) break;
            self.putStable(c, row, b, gw, style);
            c += gw;
        }
        return c;
    }

    /// Rellena una fila completa con un grapheme de 1 columna (línea, borde).
    /// El grapheme debe ser literal estático (ej. "─").
    fn fillRow(self: *Painter, row: u16, g: []const u8, style: vaxis.Style) void {
        if (row >= self.height) return;
        var c: u16 = 0;
        while (c < self.width) : (c += 1) {
            self.putStable(c, row, g, 1, style);
        }
    }

    /// Rellena `[c0, c1)` de una fila. Para fondos de modal y selección.
    pub fn fillRange(self: *Painter, c0: u16, c1: u16, row: u16, g: []const u8, style: vaxis.Style) void {
        if (row >= self.height) return;
        var c = c0;
        while (c < @min(c1, self.width)) : (c += 1) {
            self.putStable(c, row, g, 1, style);
        }
    }
};

// ── layout: párrafos → líneas ya envueltas ────────────────────
//
// El wrap se resuelve AQUÍ (no en draw) porque la caché de párrafos ya se
// invalida al cambiar el ancho. Así `lineas.len` es la altura EXACTA y no
// puede desviarse de lo que pinta el draw (antes se medía y se pintaba con
// dos bucles distintos que podían discrepar).
const CellRun = struct {
    text: []const u8, // grapheme, estable (arena del párrafo)
    w: u8, // 1 o 2 columnas
    style: vaxis.Style,
};

const PLine = struct {
    cells: []const CellRun,
    w: u16, // columnas ocupadas
};

/// Parte `cells` en líneas de como mucho `width` columnas.
fn wrapCells(
    pa: std.mem.Allocator,
    lines: *std.ArrayList(PLine),
    cells: []const CellRun,
    width: u16,
) !void {
    if (cells.len == 0) {
        try lines.append(pa, .{ .cells = &.{}, .w = 0 });
        return;
    }
    var start: usize = 0;
    var used: u16 = 0;
    for (cells, 0..) |c, i| {
        const cw: u16 = @min(c.w, @max(width, 1));
        if (used > 0 and used + cw > width) {
            try lines.append(pa, .{ .cells = cells[start..i], .w = used });
            start = i;
            used = 0;
        }
        used += cw;
    }
    try lines.append(pa, .{ .cells = cells[start..], .w = used });
}

/// Convierte un párrafo (markdown ya parseado) en líneas de celdas.
/// Toda la memoria sale de `pa` (arena propia del párrafo o arena del frame).
fn buildLines(
    pa: std.mem.Allocator,
    ctx: vxfw.DrawContext,
    kind: md.Kind,
    text: []const u8,
    width: u16,
) ![]const PLine {
    return buildLinesBase(pa, ctx, kind, text, width, null, null);
}

/// `buildLines` con estilo base impuesto (ver `md.parseBase`).
fn buildLinesBase(
    pa: std.mem.Allocator,
    ctx: vxfw.DrawContext,
    kind: md.Kind,
    text: []const u8,
    width: u16,
    base: ?md.Style,
    mood: ?vaxis.Style,
) ![]const PLine {
    const blocks = try md.parseBase(pa, kind, text, base, mood);
    var lines: std.ArrayList(PLine) = .empty;
    var first_line = true;

    for (blocks) |blk| {
        for (blk.lines) |src| {
            var cells: std.ArrayList(CellRun) = .empty;
            if (first_line) {
                // El prefijo (› ◆ ⚙ …) va solo en la primera línea del párrafo.
                const pre = md.prefix(kind);
                var pit = vaxis.unicode.graphemeIterator(pre.text);
                while (pit.next()) |pg| {
                    const pb = pg.bytes(pre.text);
                    try cells.append(pa, .{
                        .text = pb,
                        .w = theme.graphemeWidth(ctx, pb),
                        .style = pre.style,
                    });
                }
                first_line = false;
            }
            for (src) |seg| {
                var it = vaxis.unicode.graphemeIterator(seg.text);
                while (it.next()) |g| {
                    const b = g.bytes(seg.text);
                    try cells.append(pa, .{
                        .text = b,
                        .w = theme.graphemeWidth(ctx, b),
                        .style = seg.style,
                    });
                }
            }
            try wrapCells(pa, &lines, cells.items, width);
        }
    }

    if (lines.items.len == 0) {
        const one = try pa.alloc(PLine, 1);
        one[0] = .{ .cells = &.{}, .w = 0 };
        return one;
    }
    return lines.items;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        var ok = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

/// TUI estilo Claude Code:
///  ┌ historial (markdown + syntax highlighting, tool blocks, scroll)
///  ├ status: provider · model │ effort │ ⚠yolo │ ctx%
///  └ input multilínea con borde y autocompletado de `/`
pub const Model = struct {
    allocator: std.mem.Allocator,

    /// Input propio: `vxfw.TextField` es de una sola línea y no tiene
    /// historial, así que el prompt se edita con `editor.Editor`.
    ed: ed_mod.Editor,

    /// Párrafos crudos (propietario). El parse a bloques es on-demand en draw
    /// con arena: la memoria vive un frame, no acumulamos estilos.
    paras: std.ArrayList(Para),
    pending: std.ArrayList(Pending),
    spin: std.atomic.Mutex = .unlocked,

    /// Prompts enviados mientras hay un turno en curso.
    ///
    /// Sin esto, mandar un segundo prompt mientras el primero trabajaba
    /// lanzaba OTRO worker y los dos peleaban por la sesion y por el estado de
    /// streaming: el input se freezeaba, el historial se entrecortaba y no se
    /// tenia idea de si estaba trabajando. Ahora se encolan y el worker los
    /// va sacando al terminar su turno.
    queue: std.ArrayList([]u8) = .empty,

    /// Momento en que empezó el turno en curso, en nanosegundos, para el reloj
    /// de la franja de actividad. 0 = sin turno. Lo escribe `streamStart`.
    busy_started_ns: i128 = 0,

    /// `Io` de la app, para el reloj. Los tests construyen un Model sin app, así
    /// que se guarda aparte de `agent.io_global` y con un flag: leer un `Io`
    /// sin inicializar es usar basura como tabla de vtable.
    io: std.Io = undefined,
    io_ready: bool = false,

    /// Workers en vuelo (chat y descarga de modelos).
    ///
    /// Los hilos se lanzan con `detach`, así que nadie los une. Sin este
    /// contador, al salir el proceso `app.deinit()` destruía el `Io` mientras
    /// un worker seguía dentro de `io.async` → use-after-free y segfault en
    /// `Threaded.cancelThreads`. `waitWorkers` los deja terminar ANTES del
    /// teardown.
    workers: std.atomic.Value(usize) = .init(0),

    /// Autocompletado de comandos `/`: visible + selección.
    ac: Autocomplete = .{},

    /// Paleta modal de Ctrl+P (comandos y modelos en dos columnas).
    pal: palette.Palette = undefined,
    /// Modelos que el worker ha descargado y que aún no se han pintado.
    ///
    /// El worker NO puede rellenar la paleta directamente: la dibuja el hilo de
    /// la UI sin lock (el lock solo cubre el historial), y tocar los dos a la vez
    /// tiraba la app con un segfault. Deja los modelos aquí y el draw los
    /// recoge; el traspaso va con lock, así que no hay carrera.
    pending_items: ?[]palette.Item = null,
    pal_inited: bool = false,

    /// Estado de streaming: último párrafo del asistente sigue abierto.
    streaming: bool = false,
    stream_buf: std.ArrayList(u8) = .empty, // gpa-owned

    /// Hay trabajo pendiente de pintar (el worker encoló texto). Lo lee el
    /// handler de .tick para saber si debe seguir pidiendo frames: sin esto
    /// la UI solo se repinta cuando el usuario pulsa una tecla.
    dirty: bool = false,
    tick_armed: bool = false,

    /// Scroll: 0 = anclado abajo; N = N líneas hacia arriba.
    scroll: usize = 0,
    /// Filas del historial en el último frame. El handler de teclas lo usa
    /// para saltar una PAGINA (la ventana entera) en vez de un numero fijo:
    /// con 5 fijas, en una terminal alta PageUp no movia casi nada.
    hist_rows: usize = 10,

    /// Caché de párrafos: 1 arena por párrafo cerrado, con las líneas YA
    /// envueltas al ancho actual. Se invalida al cambiar el ancho; libera los
    /// más viejos al crecer.
    seg_cache: std.ArrayList(CachedPara) = .empty,
    /// Alto en LÍNEAS de cada párrafo del historial, en el mismo orden que
    /// `paras`. Vive siempre (8 bytes por párrafo) aunque sus celdas estén
    /// fuera de la ventana: es lo que permite calcular el desplazamiento del
    /// scroll sobre el historial ENTERO sin tener todo parseado, y hace posible
    /// la poda por bytes de la Fase 6 sin reparsear el mundo al rehidratar.
    /// Lo que no se ha medido todavía tiene una estimación (ver
    /// `ensureParaHeights`), que se sustituye por la exacta al parsearse.
    para_heights: std.ArrayList(usize) = .empty,
    cache_width: u16 = 0,
    /// Índice del primer párrafo whose layout está invalidado (Ctrl+R expande
    /// un tool in-place). `null` = caché al día.
    cache_from: ?usize = null,

    /// Último tool call ejecutado, para expandirlo con Ctrl+R.
    last_tool: ?ToolMemo = null,

    /// Status bar fijo.
    status_buf: [160]u8 = undefined,
    status_len: usize = 0,
    /// Mood con el que se compuso el status (para colorear la carita).
    status_mood: mascot.Mood = .idle,
    status_mood_set: bool = false,

    /// Diálogo de permisos (buffers fijos, sin churn entre hilos).
    perm_tool: [64]u8 = undefined,
    perm_tool_len: usize = 0,
    perm_detail: [384]u8 = undefined,
    perm_detail_len: usize = 0,
    perm_active: bool = false,
    perm_answer: PermAnswer = .none,

    /// Spinner (contadores, sin alloc).
    spinner_frame: usize = 0,
    busy: bool = false,

    /// Tool en curso. Es lo que hace que un `bash` de 30s no parezca la app
    /// colgada: mientras está puesto se dibuja una línea `⎿ ⠋ running 12.3s`
    /// DEBAJO de la cabecera de la tool, y se repinta cada frame con el reloj.
    ///
    /// Solo puede haber una: las tools del turno se ejecutan en serie.
    tool_run: ?ToolRun = null,

    /// ── picker modal (flechas + filtro, estilo opencode) ──
    picker_items: std.ArrayList(PickerItem) = .empty,
    picker_filtered: std.ArrayList(usize) = .empty, // índices visibles
    picker_query: [64]u8 = undefined,
    picker_query_len: usize = 0,
    picker_title: [64]u8 = undefined,
    picker_title_len: usize = 0,
    picker_sel: usize = 0,
    picker_scroll: usize = 0,
    picker_active: bool = false,
    picker_tag: u32 = 0,
    picker_cb: ?PickerCb = null,

    /// Párrafo del historial al que corresponde `seg_cache.items[0]`.
    /// La caché es una VENTANA `[cache_lo, cache_lo + len)`, no una cola: por eso
    /// los índices del historial y los de la caché son distintos y hay que ir
    /// con cuidado al mezclarlos.
    cache_lo: usize = 0,

    /// Iteraciones del bucle de layout del último frame, y si se tocó el tope
    /// de seguridad.
    ///
    /// El tope existe para que una regresión del bucle (que antes no terminaba
    /// nunca por encima de `max_cached_paras` párrafos) CUELGUE UN TEST Y NO
    /// LA APP: al superarse, el layout para, deja `layout_overflow` a true y el
    /// test falla en 1 s con un número en vez de quedarse colgado hasta el kill.
    layout_iters: usize = 0,
    layout_overflow: bool = false,

    environ: ?*const std.process.Environ.Map = null,

    pub const PermAnswer = enum { none, allow, allow_always, deny };

    const CachedPara = struct {
        arena: ?*std.heap.ArenaAllocator, // owns lines + cells
        lines: []const PLine,
        height: usize,
        /// Párrafo del historial al que pertenece estas líneas.
        ///
        /// OBLIGATORIO desde que la caché es una VENTANA y no una cola: el
        /// bucle antiguo daba por hecho que `seg_cache.items[i]` correspondía a
        /// `paras.items[i]`, así que al evictar por el frente dejaban de
        /// cuadrar los índices y —peor— el bucle `while (cache.len <
        /// paras.len)` no tenía forma de terminar (ver `layoutWindow`).
        para_idx: usize,
    };

    /// Máximo de párrafos con celdas en memoria a la vez (los de fuera de la
    /// ventana se re-parsean al volver a mirarlos).
    const max_cached_paras = 128;

    const Para = struct {
        kind: md.Kind,
        text: []const u8,
        base: ?md.Style = null,
        mood: ?vaxis.Style = null,
    };

    /// Último tool call, para que Ctrl+R pueda mostrar su resultado completo.
    /// Tool que se está ejecutando ahora mismo. La pone `pushToolStart` y la
    /// quita `pushToolDone`; mientras exista se dibuja una línea de reloj.
    const ToolRun = struct {
        name: []const u8,
        arg: []const u8,
        started_ns: i128,

        fn deinit(self: ToolRun, gpa: std.mem.Allocator) void {
            gpa.free(self.name);
            gpa.free(self.arg);
        }
    };

    const ToolMemo = struct {
        /// Índice del párrafo `.tool_res` en `paras`.
        para_idx: usize = 0,
        /// Resultado completo, inmutable (gpa-owned).
        result: []u8 = &.{},
        /// Texto de una línea con el resultado (gpa-owned).
        summary: []u8 = &.{},
        /// Ya está expandido.
        expanded: bool = false,

        fn deinit(self: *ToolMemo, gpa: std.mem.Allocator) void {
            if (self.result.len > 0) gpa.free(self.result);
            if (self.summary.len > 0) gpa.free(self.summary);
        }
    };

    const Pending = struct {
        kind: md.Kind,
        text: []const u8, // copia gpa, liberada en drain
        /// Estilo base impuesto al párrafo. `null` = el que toque por `kind`.
        base: ?md.Style = null,
        /// Color del mood de Zo: pinta lo marcado con `~…~` en la cabecera.
        mood: ?vaxis.Style = null,
    };

    const spinner_chars = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

    pub fn hasInput(self: *const Model) bool {
        return !self.ed.isEmpty();
    }

    // ── ciclo de vida ────────────────────────────────────
    pub fn init(allocator: std.mem.Allocator) Model {
        var m = Model{
            .allocator = allocator,
            .pal = palette.Palette.init(allocator),
            .pal_inited = true,
            .ed = ed_mod.Editor.init(allocator),
            .paras = .empty,
            .pending = .empty,
            .seg_cache = .empty,
        };
        m.setStatusText("zode v0.3 \u{b7} esc interrupts \u{b7} ctrl+c exits");
        return m;
    }

    pub fn deinit(self: *Model) void {
        // `clearQueue` conserva la capacidad (bien para no reasignar en cada
        // prompt), así que el buffer de la lista hay que liberarlo aparte o
        // fuga al salir.
        self.clearQueue();
        self.queue.deinit(self.allocator);
        self.destroyPalette();
        if (self.pending_items) |items| palette.freeItems(self.allocator, items);
        self.ed.deinit();
        for (self.paras.items) |p| self.allocator.free(p.text);
        self.paras.deinit(self.allocator);
        for (self.pending.items) |p| self.allocator.free(p.text);
        self.pending.deinit(self.allocator);
        if (self.last_tool) |*lt| lt.deinit(self.allocator);
        if (self.tool_run) |tr| tr.deinit(self.allocator);
        self.stream_buf.deinit(self.allocator);
        self.clearSegCache(); // vacía `para_heights`
        self.para_heights.deinit(self.allocator);
        self.closePicker();
        self.picker_items.deinit(self.allocator);
        self.picker_filtered.deinit(self.allocator);
    }

    // ── picker modal ──────────────────────────────────
    /// Abre el picker. Toma ownership de `items` (labels/descs gpa-owned).
    /// Thread-safe: lo llama el worker de /models.
    pub fn openPicker(self: *Model, tag: u32, title: []const u8, items: []PickerItem, cb: PickerCb) void {
        self.lock();
        defer self.unlock();
        for (items) |it| {
            self.picker_items.append(self.allocator, it) catch {
                self.allocator.free(it.label);
                if (it.desc.len > 0) self.allocator.free(it.desc);
            };
        }
        self.allocator.free(items);
        const nt = @min(title.len, self.picker_title.len);
        @memcpy(self.picker_title[0..nt], title[0..nt]);
        self.picker_title_len = nt;
        self.picker_tag = tag;
        self.picker_cb = cb;
        self.picker_query_len = 0;
        self.picker_sel = 0;
        self.picker_scroll = 0;
        self.pickerRefilter();
        self.picker_active = true;
    }

    /// Cierra y libera. UI thread.
    pub fn closePicker(self: *Model) void {
        self.lock();
        defer self.unlock();
        if (!self.picker_active and self.picker_items.items.len == 0) return;
        self.picker_active = false;
        self.picker_cb = null;
        for (self.picker_items.items) |it| {
            self.allocator.free(it.label);
            if (it.desc.len > 0) self.allocator.free(it.desc);
        }
        self.picker_items.clearRetainingCapacity();
        self.picker_filtered.clearRetainingCapacity();
    }

    pub fn pickerActive(self: *Model) bool {
        self.lock();
        defer self.unlock();
        return self.picker_active;
    }

    fn pickerRefilter(self: *Model) void {
        // caller holds lock
        const q = self.picker_query[0..self.picker_query_len];
        self.picker_filtered.clearRetainingCapacity();
        for (self.picker_items.items, 0..) |it, ix| {
            if (q.len == 0 or containsIgnoreCase(it.label, q)) {
                self.picker_filtered.append(self.allocator, ix) catch {};
            }
        }
        if (self.picker_sel >= self.picker_filtered.items.len) {
            self.picker_sel = if (self.picker_filtered.items.len > 0) self.picker_filtered.items.len - 1 else 0;
        }
    }

    /// Maneja una tecla con el picker abierto. Devuelve true si la consumió.
    pub fn pickerHandleKey(self: *Model, key: vaxis.Key) bool {
        self.lock();
        if (!self.picker_active) {
            self.unlock();
            return false;
        }
        const visible: usize = 10;
        switch (key.codepoint) {
            57352 => { // up
                if (self.picker_sel > 0) self.picker_sel -= 1;
            },
            57353 => { // down
                if (self.picker_sel + 1 < self.picker_filtered.items.len) self.picker_sel += 1;
            },
            0x0D => { // enter: seleccionar
                const ix = if (self.picker_sel < self.picker_filtered.items.len)
                    self.picker_filtered.items[self.picker_sel]
                else
                    null;
                const cb = self.picker_cb;
                const tag = self.picker_tag;
                const label = if (ix) |i|
                    self.allocator.dupe(u8, self.picker_items.items[i].label) catch null
                else
                    null;
                self.unlock();
                self.closePicker();
                if (label) |l| {
                    if (cb) |f| f(self, tag, l);
                    self.allocator.free(l);
                }
                return true;
            },
            27 => { // esc
                self.unlock();
                self.closePicker();
                return true;
            },
            127, 8 => { // backspace
                if (self.picker_query_len > 0) self.picker_query_len -= 1;
                self.picker_sel = 0;
                self.picker_scroll = 0;
                self.pickerRefilter();
            },
            else => |cp| {
                if (cp >= 0x20 and cp < 0x7F and self.picker_query_len < self.picker_query.len) {
                    self.picker_query[self.picker_query_len] = @intCast(cp);
                    self.picker_query_len += 1;
                    self.picker_sel = 0;
                    self.picker_scroll = 0;
                    self.pickerRefilter();
                }
            },
        }
        // ajusta scroll para que sel sea visible
        if (self.picker_sel < self.picker_scroll) self.picker_scroll = self.picker_sel;
        if (self.picker_sel >= self.picker_scroll + visible) self.picker_scroll = self.picker_sel - visible + 1;
        self.unlock();
        return true;
    }

    /// Snapshot por frame: copias en ctx.arena (≤10 items visibles).
    fn pickerSnapshot(self: *Model, arena: std.mem.Allocator) ?PickerSnapshot {
        self.lock();
        defer self.unlock();
        if (!self.picker_active) return null;
        const visible: usize = 10;
        const total = self.picker_filtered.items.len;
        const start = @min(self.picker_scroll, if (total > visible) total - visible else 0);
        const end = @min(start + visible, total);
        var items = arena.alloc(PickerItem, end - start) catch return null;
        var out_ix: usize = 0;
        var fi = start;
        while (fi < end) : (fi += 1) {
            const it = self.picker_items.items[self.picker_filtered.items[fi]];
            items[out_ix] = .{
                .label = arena.dupe(u8, it.label) catch "",
                .desc = arena.dupe(u8, it.desc) catch "",
            };
            out_ix += 1;
        }
        return .{
            .title = arena.dupe(u8, self.picker_title[0..self.picker_title_len]) catch "",
            .query = arena.dupe(u8, self.picker_query[0..self.picker_query_len]) catch "",
            .sel = self.picker_sel,
            .first_visible = start,
            .total = total,
            .items = items,
        };
    }

    pub fn status(self: *const Model) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    pub fn setStatusText(self: *Model, text: []const u8) void {
        self.lock();
        defer self.unlock();
        const n = @min(text.len, self.status_buf.len);
        @memcpy(self.status_buf[0..n], text[0..n]);
        self.status_len = n;
    }

    /// Texto + mood. El mood se guarda aparte para que la fila de status
    /// pueda pintar LA CARITA en su color: antes el texto traia la carita
    /// embebida y salia del mismo gris que el resto, y ademas duplicada (la de
    /// la franja y la del texto). Ahora la cara la dibuja la TUI una sola vez
    /// y con el color del mood.
    pub fn setStatusWithMood(self: *Model, new_mood: mascot.Mood, text: []const u8) void {
        self.lock();
        defer self.unlock();
        const n = @min(text.len, self.status_buf.len);
        @memcpy(self.status_buf[0..n], text[0..n]);
        self.status_len = n;
        self.status_mood = new_mood;
        self.status_mood_set = true;
    }

    /// Mood del estado actual. Si nadie lo ha puesto, se deduce del trabajo.
    pub fn mood(self: *Model) mascot.Mood {
        self.lock();
        defer self.unlock();
        if (self.status_mood_set) return self.status_mood;
        if (self.perm_active) return .warn;
        if (self.busy or self.streaming) return .thinking;
        return .idle;
    }

    pub fn statusf(self: *Model, comptime fmt: []const u8, args: anytype) void {
        var buf: [160]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.setStatusText(s);
    }

    // ── diálogo de permisos (thread-safe) ────────────────
    /// Lo llama el worker ANTES de ejecutar una tool con permiso.
    /// Bloquea hasta que el usuario responde en la UI.
    pub fn requestPermission(self: *Model, tool: []const u8, detail: []const u8) PermAnswer {
        self.lock();
        const n_tool = @min(tool.len, self.perm_tool.len);
        @memcpy(self.perm_tool[0..n_tool], tool[0..n_tool]);
        self.perm_tool_len = n_tool;
        const n_det = @min(detail.len, self.perm_detail.len);
        @memcpy(self.perm_detail[0..n_det], detail[0..n_det]);
        self.perm_detail_len = n_det;
        self.perm_answer = .none;
        self.perm_active = true;
        self.unlock();

        while (true) {
            std.Thread.yield() catch {};
            self.lock();
            const a = self.perm_answer;
            self.unlock();
            if (a != .none) {
                self.lock();
                self.perm_active = false;
                self.unlock();
                return a;
            }
        }
    }

    /// UI: responde el diálogo abierto.
    pub fn answerPermission(self: *Model, a: PermAnswer) void {
        self.lock();
        self.perm_answer = a;
        self.unlock();
    }

    pub fn permActive(self: *Model) bool {
        self.lock();
        defer self.unlock();
        return self.perm_active;
    }

    pub fn permView(self: *Model, tool: *[]const u8, detail: *[]const u8) bool {
        self.lock();
        defer self.unlock();
        if (!self.perm_active) return false;
        tool.* = self.perm_tool[0..self.perm_tool_len];
        detail.* = self.perm_detail[0..self.perm_detail_len];
        return true;
    }

    fn clearSegCache(self: *Model) void {
        for (self.seg_cache.items) |*c| {
            if (c.arena) |a| {
                a.deinit();
                self.allocator.destroy(a);
            }
        }
        self.seg_cache.deinit(self.allocator);
        self.seg_cache = .empty;
        self.cache_lo = 0;
        // Las alturas dependen del ANCHO (el wrap las cambia), así que al
        // invalidar la caché hay que olvidarlas también. Si no, el scroll se
        // calcularía con alturas del ancho anterior.
        //
        // OJO: `clearRetainingCapacity` hace `@memset(items, undefined)`, y en
        // `deinit` esta función se llama DESPUÉS de `para_heights.deinit()`:
        // un toque de undefined sobre memoria liberada es lo que dispara el GPF.
        // Por eso se vacía bajando `len` a pelo (aquí no hay nada que
        // sobreescribir: las alturas se vuelven a estimar enteras).
        self.para_heights.items.len = 0;
    }

    /// Libera la entrada `i` de la caché y la quita (conservando el orden).
    fn evictCached(self: *Model, i: usize) void {
        if (i >= self.seg_cache.items.len) return;
        if (self.seg_cache.items[i].arena) |a| {
            a.deinit();
            self.allocator.destroy(a);
        }
        _ = self.seg_cache.orderedRemove(i);
    }

    /// Alturas de los párrafos, con estimación para los que aún no se han
    /// medido.
    ///
    /// El alto de un párrafo depende del parseo (markdown + wrap), que es lo
    /// caro. Para el scroll hace falta el total del historial entero, así que
    /// los párrafos fuera de la ventana se estiman por el número de saltos de
    /// línea (una línea por `\n`, sin contar el wrap): la estimación solo mueve
    /// unos píxeles de scroll y se corrige en cuanto el párrafo se parsea.
    /// Nunca sale del rango por el que se puede scrollear, y `layoutWindow` la
    /// sustituye por la exacta en cuanto entra en la ventana.
    fn ensureParaHeights(self: *Model) void {
        const n = self.paras.items.len;
        while (self.para_heights.items.len > n) {
            _ = self.para_heights.pop();
        }
        while (self.para_heights.items.len < n) {
            const p = self.paras.items[self.para_heights.items.len];
            // Separador de fila en blanco entre párrafos, como en el layout.
            const est: usize = @max(1, std.mem.count(u8, p.text, "\n") + 1);
            // `assumeCapacity`: los índices de `para_heights` son los mismos que los de
            // `paras` y el draw los recorre asumiendo que miden lo mismo, así
            // que un OOM aquí no puede dejar la lista corta (sería un índice
            // fuera de rango en el frame siguiente).
            self.para_heights.ensureTotalCapacity(self.allocator, n) catch return;
            self.para_heights.appendAssumeCapacity(est);
        }
    }

    /// Parsea y envuelve un párrafo, y lo mete en la caché con su altura.
    fn layoutOne(self: *Model, ctx: vxfw.DrawContext, idx: usize, width: u16) !void {
        const p_ = self.paras.items[idx];

        const para_arena = try self.allocator.create(std.heap.ArenaAllocator);
        para_arena.* = std.heap.ArenaAllocator.init(self.allocator);
        errdefer {
            para_arena.deinit();
            self.allocator.destroy(para_arena);
        }

        var lines = try buildLinesBase(para_arena.allocator(), ctx, p_.kind, p_.text, width, p_.base, p_.mood);
        // Una fila en blanco ENTRE párrafos: sin ella el historial es un muro
        // de texto y no se ve dónde acaba una respuesta y empieza otra.
        //
        // La fila se AÑADE al array de líneas, no se suma al alto: si solo se
        // sumara al alto, `drawLines` (que recorre `c.lines`) pintaría una fila
        // menos de las que dice el alto y el último bloque se perdería. El
        // primer párrafo NO lleva separador (sería una fila vacía arriba de la
        // cabecera, que descuadra el arte del banner).
        // La cabecera va sin separador: sus líneas son UN dibujo y meter una
        // fila en blanco entre letras parte el logo en trozos.
        const prev_banner = idx > 0 and self.paras.items[idx - 1].kind == .banner;
        if (idx > 0 and p_.kind != .banner and !prev_banner) {
            const grown = try para_arena.allocator().alloc(PLine, lines.len + 1);
            // DELANTE, no detrás: la fila en blanco separa este párrafo del
            // anterior. Puesta al final el hueco salía después de "segunda" y
            // el historial seguía siendo un muro de texto.
            grown[0] = .{ .cells = &.{}, .w = 0 };
            @memcpy(grown[1..], lines);
            lines = grown;
        }

        try self.seg_cache.append(self.allocator, .{
            .arena = para_arena,
            .lines = lines,
            .height = lines.len,
            .para_idx = idx,
        });
        // La altura exacta sustituye a la estimación.
        if (idx < self.para_heights.items.len) self.para_heights.items[idx] = lines.len;
    }

    /// Rango de líneas visibles del historial (absoluto sobre todo el
    /// historial, no sobre la ventana cacheada).
    pub const Visible = struct { first: usize, last: usize, total: usize };

    /// Calcula qué líneas se ven con el scroll actual.
    ///
    /// El total sale de `para_heights` (TODO el historial, no solo la ventana
    /// cacheada): con la caché como ventana, sumar sus alturas daría un total
    /// que depende de qué esté cacheado, y el scroll saltaría al evictar.
    fn computeVisible(self: *Model, live_lines: usize, history_h: usize) Visible {
        var closed: usize = 0;
        for (self.para_heights.items) |h| closed += h;
        const total: usize = closed + live_lines;
        const hh = @max(history_h, 1);
        const max_offset = if (total > hh) total - hh else 0;
        const skip: usize = @min(self.scroll, max_offset);
        const first = max_offset - skip;
        return .{ .first = first, .last = first + hh, .total = total };
    }

    /// Layout + scroll hasta que el rango visible se estabiliza.
    ///
    /// Hace falta porque las alturas empiezan como ESTIMACIÓN y se corrigen al
    /// parsear: parsear cambia el total, el total cambia `first_visible`, y
    /// `first_visible` cambia qué párrafos hay que parsear. Sin este segundo
    /// paso el texto se queda desplazado (se veía el historial saltando al
    /// empezar a scrollear). Con un tope de pasadas (4) por si un caso patológico
    /// no converge: el scroll se queda en lo más cercano en vez de dar vueltas.
    fn layoutFor(
        self: *Model,
        ctx: vxfw.DrawContext,
        width: u16,
        live_lines: usize,
        history_h: usize,
    ) !Visible {
        self.ensureParaHeights();
        var v = self.computeVisible(live_lines, history_h);
        var pass: usize = 0;
        while (pass < 4) : (pass += 1) {
            try self.layoutWindow(ctx, width, v.first, v.last);
            const next = self.computeVisible(live_lines, history_h);
            if (next.first == v.first and next.last == v.last) return next;
            v = next;
        }
        return v;
    }

    /// Deja la caché cubriendo EXACTAMENTE la ventana de párrafos que contiene
    /// las líneas visibles, y solo esa.
    ///
    /// El bucle anterior (`while (cache.len < paras.len)` + `orderedRemove(0)`
    /// al pasar del tope) no terminaba nunca con 129+ párrafos: append → 129 →
    /// evict → 128 → volver a entrar. Con `pushDiff` metiendo un párrafo por
    /// línea de diff, un solo `write` de un fichero de 129 líneas colgaba la
    /// app al instante. Aquí el número de vueltas está acotado por
    /// `max_cached_paras`, así que termina por construcción.
    fn layoutWindow(
        self: *Model,
        ctx: vxfw.DrawContext,
        width: u16,
        first_visible: usize,
        last_visible: usize,
    ) !void {
        self.ensureParaHeights();
        self.layout_iters = 0;
        self.layout_overflow = false;
        if (self.paras.items.len == 0) return;

        // ── ventana objetivo: los párrafos que cubren [first, last] ──
        var acc: usize = 0;
        var lo: usize = 0;
        while (lo < self.para_heights.items.len) : (lo += 1) {
            if (acc + self.para_heights.items[lo] > first_visible) break;
            acc += self.para_heights.items[lo];
        }
        var hi = lo;
        var seen = acc;
        while (hi < self.para_heights.items.len and seen < last_visible) : (hi += 1) {
            seen += self.para_heights.items[hi];
        }
        // Si la ventana visible es más ancha que el tope, se deja el final (es
        // lo que se está leyendo: abajo del todo).
        if (hi - lo > Model.max_cached_paras) lo = hi - Model.max_cached_paras;

        // ── suelta lo cacheado fuera de la ventana ──
        var i: usize = 0;
        while (i < self.seg_cache.items.len) {
            const idx = self.seg_cache.items[i].para_idx;
            if (idx < lo or idx >= hi) {
                self.evictCached(i);
            } else {
                i += 1;
            }
        }
        self.cache_lo = lo;

        // ── parsea lo que falte en la ventana ──
        for (lo..hi) |idx| {
            if (self.hasCached(idx)) continue;
            // Red de seguridad: la ventana no puede pasar del tope, pero si
            // alguien lo cambiara esto volvería a ser un bucle infinito. Con el
            // tope aquí el fallo es un `layout_overflow` (y un test rojo), no
            // un proceso colgado.
            self.layout_iters += 1;
            if (self.layout_iters > Model.max_cached_paras) {
                self.layout_overflow = true;
                return;
            }
            try self.layoutOne(ctx, idx, width);
        }
    }

    fn hasCached(self: *const Model, idx: usize) bool {
        for (self.seg_cache.items) |c| {
            if (c.para_idx == idx) return true;
        }
        return false;
    }

    fn lock(self: *Model) void {
        while (!self.spin.tryLock()) std.Thread.yield() catch {};
    }
    fn unlock(self: *Model) void {
        self.spin.unlock();
    }

    // ── API thread-safe (encola; el draw drena) ──────────
    pub fn pushKind(self: *Model, kind: md.Kind, text: []const u8) void {
        const copy = self.allocator.dupe(u8, text) catch return;
        self.lock();
        defer self.unlock();
        self.pending.append(self.allocator, .{ .kind = kind, .text = copy }) catch {
            self.allocator.free(copy);
        };
        self.dirty = true;
    }

    pub fn pushInfo(self: *Model, text: []const u8) void {
        self.pushKind(.info, text);
    }

    /// Línea de la cabecera con estilo base impuesto (color del mood de Zo).
    pub fn pushBannerStyled(self: *Model, text: []const u8, base: md.Style) void {
        const copy = self.allocator.dupe(u8, text) catch return;
        self.lock();
        defer self.unlock();
        self.pending.append(self.allocator, .{ .kind = .banner, .text = copy, .base = base }) catch {
            self.allocator.free(copy);
        };
        self.dirty = true;
    }

    /// Empuja la cabecera: SOLO el wordmark.
    ///
    /// Antes eran tres cosas más (una mascota de 18 filas, la línea "zo the code
    /// robot says: hi!…" y la de atajos `/help · /model · ctrl+p…`). Quejarse
    /// de "basura en la vista" es tener razón: eran 20 filas de cabecera antes
    /// de la primera palabra de la conversación, y las pistas ya están en la
    /// paleta (Ctrl+P) y en `/help`.
    ///
    /// `start_mood` ya no se usa para pintar nada aquí: la carita sigue estando
    /// en el status bar (`setStatusWithZo`), que es donde se lee. El parámetro
    /// se queda para no cambiar la firma en los dos sitios que la llaman.
    pub fn pushHeader(self: *Model, start_mood: mascot.Mood) void {
        _ = start_mood;
        var it = std.mem.splitScalar(u8, mascot.banner, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            self.pushKind(.banner, line);
        }
    }

    /// El worker deja aquí los items ya construidos (thread-safe).
    ///
    /// Se entregan ITEMS, no `models_mod.Model`: los `id` de un Model apuntan a
    /// la lista de la que salieron, y si el worker la libera al terminar (que es
    /// lo que hace) esos punteros quedan colgando. Los items llevan strings
    /// propios y la paleta los libera al reemplazarse.
    pub fn setPendingItems(self: *Model, items: []palette.Item) void {
        self.lock();
        defer self.unlock();
        if (self.pending_items) |old| palette.freeItems(self.allocator, old);
        self.pending_items = items;
        self.dirty = true;
    }

    /// El hilo de la UI recoge los items y devuelve la propiedad.
    pub fn takePendingItems(self: *Model) ?[]palette.Item {
        self.lock();
        defer self.unlock();
        const items = self.pending_items;
        self.pending_items = null;
        return items;
    }

    /// Encola un prompt. El texto DEBE ser una copia ya hecha por el llamante
    /// (tipo `[]u8` a propósito: la cola es dueña de lo que guarda y la
    /// libera en `deinit`).
    pub fn enqueuePrompt(self: *Model, text: []u8) usize {
        self.lock();
        defer self.unlock();
        self.queue.append(self.allocator, text) catch return self.queue.items.len;
        self.dirty = true;
        return self.queue.items.len;
    }

    /// Saca el siguiente prompt de la cola. `null` si no hay ninguno.
    pub fn takeQueued(self: *Model) ?[]u8 {
        self.lock();
        defer self.unlock();
        if (self.queue.items.len == 0) return null;
        const first = self.queue.orderedRemove(0);
        self.dirty = true;
        return first;
    }

    /// Décimas de segundo que lleva el turno en curso. Se guarda un instante al
    /// abrir el streaming porque `Timestamp.now` a través del `Io` desde el
    /// draw es justo lo que no se quiere en el camino caliente.
    /// Pasa el `Io` de la app. Lo llama `runTui` al arrancar.
    pub fn attachIo(self: *Model, io: std.Io) void {
        self.io = io;
        self.io_ready = true;
    }

    /// Milisegundos desde `start`. 0 si no hay reloj o no hay turno.
    pub fn millisSince(self: *Model, start: i128) i128 {
        if (!self.io_ready) return 0;
        const now = std.Io.Timestamp.now(self.io, .real).nanoseconds;
        if (now <= start) return 0;
        return @divTrunc(now - start, std.time.ns_per_ms);
    }

    /// Milisegundos que lleva el turno en curso (0 si no hay turno o no hay
    /// reloj). OJO: milisegundos, no décimas: se mostraba como "153.3s" con
    /// 1.5s transcurridos porque el valor se trataba como décimas.
    pub fn busyMillis(self: *const Model) u64 {
        const started = self.busy_started_ns;
        if (started == 0) return 0;
        var m2 = @constCast(self);
        return @intCast(m2.millisSince(started));
    }

    /// Los primeros `max` caracteres del primer prompt encolado.
    pub fn queuedFirst(self: *Model, max: usize) []const u8 {
        self.lock();
        defer self.unlock();
        if (self.queue.items.len == 0) return "";
        const t = self.queue.items[0];
        if (t.len <= max) return t;
        return t[0..max];
    }

    pub fn isBusyFlag(self: *Model) bool {
        return self.isBusy();
    }

    /// ¿Hay un turno en curso? Lo consulta `agent.startChat` para decidir entre
    /// lanzar un worker o encolar.
    pub fn isBusy(self: *Model) bool {
        self.lock();
        defer self.unlock();
        return self.workingLocked();
    }

    /// "Hay algo en marcha" con el lock ya cogido.
    ///
    /// Una tool en curso CUENTA como trabajo aunque no haya stream: entre
    /// `streamEnd` y `pushToolDone` hay una ventana (toda la ejecución de la
    /// tool) en la que `busy` ya está a false, y sin esto un `bash` de medio
    /// minuto se quedaba sin spinner, sin reloj y con la franja diciendo
    /// "queued" — que es justo la sensación de app colgada.
    fn workingLocked(self: *const Model) bool {
        return self.busy or self.streaming or self.tool_run != null;
    }

    pub fn queuedCount(self: *Model) usize {
        self.lock();
        defer self.unlock();
        return self.queue.items.len;
    }

    /// Vacía la cola liberando los textos (Ctrl+C limpia el input).
    pub fn clearQueue(self: *Model) void {
        self.lock();
        defer self.unlock();
        for (self.queue.items) |t| self.allocator.free(t);
        self.queue.clearRetainingCapacity();
    }

    /// Marca el arranque de un worker. Lo llama justo después de `Thread.spawn`.
    pub fn beginWorker(self: *Model) void {
        _ = self.workers.fetchAdd(1, .seq_cst);
    }

    /// Marca el final de un worker (normal o por error): va en `defer`.
    pub fn endWorker(self: *Model) void {
        _ = self.workers.fetchSub(1, .seq_cst);
    }

    /// Espera a que no quede ningún worker en vuelo.
    ///
    /// Con tope de tiempo: un worker atascado en una lectura de red no puede
    /// dejar la app colgada al salir. Pasado el tope se sigue adelante (mejor un
    /// aviso que no salir nunca).
    pub fn waitWorkers(self: *Model, budget_ms: u64) void {
        // Se cuenta con vueltas y no con reloj: `waitWorkers` se llama durante
        // el apagado, cuando el `Io` puede estar ya en proceso de destrucción
        // y consultar la hora a través de él es justo lo que no se debe.
        // `yield` cede el procesador, así que un workerBlocked avanza.
        var spins: u64 = 0;
        const max_spins = budget_ms * 200; // ~5 vueltas/ms como techo práctico
        while (self.workers.load(.seq_cst) > 0) {
            if (spins >= max_spins) return;
            spins += 1;
            std.Thread.yield() catch {};
        }
    }

    /// Encola un párrafo YA con su memoria copiada. `text` pasa a ser del
    /// modelo. Libera el lock antes de tocar nada más: quien llama puede
    /// querer encolar más cosas detrás (y el mutex no es reentrante).
    fn pushPending(self: *Model, p: Pending) void {
        self.lock();
        defer self.unlock();
        self.pending.append(self.allocator, p) catch {
            self.allocator.free(p.text);
        };
        self.dirty = true;
    }

    pub fn pushInfoOwned(self: *Model, text: []const u8) void {
        self.enqueueOwned(.info, text);
    }

    fn enqueueOwned(self: *Model, kind: md.Kind, text: []const u8) void {
        self.lock();
        defer self.unlock();
        self.pending.append(self.allocator, .{ .kind = kind, .text = text }) catch {
            self.allocator.free(text);
        };
        self.dirty = true;
    }

    /// Abre un párrafo de streaming del asistente.
    pub fn streamStart(self: *Model) void {
        self.lock();
        defer self.unlock();
        self.streaming = true;
        self.busy = true;
        self.busy_started_ns = if (self.io_ready)
            std.Io.Timestamp.now(self.io, .real).nanoseconds
        else
            0;
        self.stream_buf.clearRetainingCapacity();
        self.dirty = true;
    }

    /// Abre el párrafo en vivo de una ITERACIÓN del agent loop (la que va
    /// después de una tool) SIN resetear el reloj del turno.
    ///
    /// Con `streamStart` el reloj de la franja volvía a cero en cada iteración
    /// y el usuario veía el tiempo saltar hacia atrás justo cuando la tool
    /// terminaba: el feedback de "el reloj corre" es el que dice si algo está
    /// colgado, y un reloj que resetea no sirve para eso.
    pub fn streamStartIteration(self: *Model) void {
        self.lock();
        defer self.unlock();
        self.streaming = true;
        self.busy = true;
        self.stream_buf.clearRetainingCapacity();
        self.dirty = true;
    }

    /// Delta de texto del asistente (thread-safe).
    pub fn streamDelta(self: *Model, text: []const u8) void {
        self.lock();
        defer self.unlock();
        self.stream_buf.appendSlice(self.allocator, text) catch {};
        self.dirty = true;
    }

    /// Cierra el streaming y fija el párrafo en el historial.
    pub fn streamEnd(self: *Model) void {
        self.lock();
        defer self.unlock();
        // VACÍA `pending` ANTES de fijar el párrafo del asistente.
        //
        // `pushToolStart`/`pushToolDone` encolan en `pending` y `pending` se
        // drena en el draw siguiente, pero aquí el párrafo se mete YA en
        // `paras`. Como `paras` se recorre en orden, el texto del asistente
        // acababa POR DELANTE de la tool a la que pertenece: el historial
        // showed "Listo." encima de "⏺ bash(...) ⎿ exit=0".
        self.drainPendingLocked();
        // `or stream_buf.len > 0`: si nadie abrió párrafo (una iteración que se
        // quedó sin `streamStart`) el texto NO se pierde. Antes el `if
        // (streaming)` lo descartaba en silencio y la respuesta final del turno
        // con tools no aparecía nunca: el modelo contestaba, los tokens llegaban
        // y el historial se quedaba en la tool.
        if (self.streaming or self.stream_buf.items.len > 0) {
            const text = self.allocator.dupe(u8, self.stream_buf.items) catch "";
            self.paras.append(self.allocator, .{ .kind = .assistant, .text = text }) catch {
                self.allocator.free(text);
            };
            self.streaming = false;
            self.stream_buf.clearRetainingCapacity();
        }
        self.busy = false;
    }

    /// Línea de tool ejecutada (thread-safe; el worker llama).
    pub fn pushTool(self: *Model, text: []const u8) void {
        self.pushKind(.tool, text);
    }

    // ── tool calls estilo Claude Code ───────────────────────
    /// Cabecera de una tool en curso: "⏺ Read(src/tui.zig)".
    /// Cabecera de una tool: `⏺ write(hola.js)`.
    ///
    /// El nombre va marcado con `*…*` para que el parser lo pinte en el color
    /// fuerte de la tool y el argumento en el apagado. Sin la marca, `write` y
    /// `hola.js` salían del mismo cyan y no se distinguían.
    pub fn pushToolStart(self: *Model, tool: []const u8, arg: []const u8) void {
        const line = if (arg.len == 0)
            std.fmt.allocPrint(self.allocator, "*{s}*", .{tool}) catch return
        else
            std.fmt.allocPrint(self.allocator, "*{s}*({s})", .{ tool, arg }) catch return;
        defer self.allocator.free(line);
        self.pushKind(.tool_run, line);

        // Registra la tool en curso para la línea de "running". Copias propias:
        // `arg` viene de una arena del worker que se libera al final del turno.
        const name_copy = self.allocator.dupe(u8, tool) catch return;
        const arg_copy = self.allocator.dupe(u8, arg) catch {
            self.allocator.free(name_copy);
            return;
        };
        self.lock();
        defer self.unlock();
        if (self.tool_run) |tr| tr.deinit(self.allocator);
        self.tool_run = .{
            .name = name_copy,
            .arg = arg_copy,
            .started_ns = if (self.io_ready) std.Io.Timestamp.now(self.io, .real).nanoseconds else 0,
        };
        self.dirty = true;
    }

    /// Cierra la línea de "running" (la pone `pushToolDone`).
    pub fn toolRunEnd(self: *Model) void {
        self.lock();
        defer self.unlock();
        if (self.tool_run) |tr| {
            tr.deinit(self.allocator);
            self.tool_run = null;
        }
    }

    /// Milisegundos que lleva la tool en curso (0 si no hay ninguna).
    pub fn toolRunMillis(self: *const Model) u64 {
        return self.toolRunMillisLocked();
    }

    /// Nombre de la tool en curso, o null. Copia al allocator que se le pase:
    /// el nombre vive en el Model y lo lee el hilo del dibujo.
    pub fn toolRunName(self: *Model) ?[]const u8 {
        self.lock();
        defer self.unlock();
        const tr = self.tool_run orelse return null;
        return tr.name;
    }

    /// Igual, pero para cuando el llamante YA tiene el lock cogido.
    fn toolRunMillisLocked(self: *const Model) u64 {
        const tr = self.tool_run orelse return 0;
        if (!self.io_ready) return 0;
        const now = std.Io.Timestamp.now(self.io, .real).nanoseconds;
        return @intCast(@max(0, now - tr.started_ns) / std.time.ns_per_ms);
    }

    /// Resultado de una tool: "⎿  Read 1006 lines · 3ms". Guarda el resultado
    /// completo para que Ctrl+R lo pueda desplegar.
    pub fn pushToolDone(
        self: *Model,
        tool: []const u8,
        summary: []const u8,
        ms: u64,
        result: []const u8,
    ) void {
        var line_buf: [256]u8 = undefined;
        const head: []const u8 = if (summary.len > 0) summary else tool;
        // El resumen marcado y el tiempo apagado: se lee "qué pasó" y luego
        // "cuánto tardó" sin que se mezclen.
        const line = std.fmt.bufPrint(&line_buf, "*{s}* · {d}ms", .{ head, ms }) catch head;

        // Tres copias: la del párrafo (pending), el resumen y el resultado
        // completo (para Ctrl+R). Todas gpa-owned.
        const copy = self.allocator.dupe(u8, line) catch return;
        const full = self.allocator.dupe(u8, result) catch {
            self.allocator.free(copy);
            return;
        };
        const sum = self.allocator.dupe(u8, line) catch {
            self.allocator.free(copy);
            self.allocator.free(full);
            return;
        };
        // Antes del lock: `toolRunEnd` lo coge por su cuenta y `std.atomic.Mutex`
        // no es reentrante (atraparse con él dentro = la app se cuelga).
        self.toolRunEnd();
        self.lock();
        defer self.unlock();
        if (self.last_tool) |*lt| lt.deinit(self.allocator);
        self.pending.append(self.allocator, .{ .kind = .tool_res, .text = copy }) catch {
            self.allocator.free(copy);
            self.allocator.free(full);
            self.allocator.free(sum);
            return;
        };
        self.dirty = true;
        // El índice del párrafo se fija al drenar; `pending` aún no está en `paras`.
        self.last_tool = .{
            .para_idx = self.paras.items.len + self.pending.items.len - 1,
            .result = full,
            .summary = sum,
            .expanded = false,
        };
    }

    /// Inserta un diff como párrafos (queda bajo la línea de resultado).
    ///
    /// LCS por líneas: O(n*m), de sobra para ediciones de código. Se hace en
    /// una arena propia y se vuelca línea a línea al historial.
    pub fn pushDiff(self: *Model, before: []const u8, after: []const u8) void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const lines = md.unifiedDiff(arena, before, after) catch return;
        var changed: usize = 0;
        for (lines) |l| {
            if (l.len > 0 and (l[0] == '+' or l[0] == '-')) changed += 1;
        }
        if (changed == 0) return; // nada cambió: no ensuciar el historial

        for (lines) |l| {
            const copy = self.allocator.dupe(u8, l) catch return;
            self.pushKind(.diff, copy);
            self.allocator.free(copy);
        }
    }

    /// Ctrl+R: despliega o repliega el resultado de la última tool.
    pub fn toggleLastTool(self: *Model) bool {
        self.lock();
        var lt = self.last_tool orelse {
            self.unlock();
            return false;
        };
        const idx = lt.para_idx;
        if (idx >= self.paras.items.len or lt.result.len == 0) {
            self.unlock();
            return false;
        }
        // `result` y `summary` son la fuente de verdad; el texto del párrafo
        // es una vista de uno de los dos (por eso no se liberan aquí).
        const want = if (lt.expanded) lt.summary else lt.result;
        const copy = self.allocator.dupe(u8, want) catch {
            self.unlock();
            return false;
        };
        self.allocator.free(self.paras.items[idx].text);
        self.paras.items[idx].text = copy;
        lt.expanded = !lt.expanded;
        self.last_tool = lt;
        // El layout de este y los siguientes párrafos cambia: re-cachear.
        if (self.cache_from == null or idx < self.cache_from.?) self.cache_from = idx;
        self.scroll = 0;
        self.unlock();
        return true;
    }

    fn drainPending(self: *Model) void {
        self.lock();
        defer self.unlock();
        self.drainPendingLocked();
    }

    /// Mueve `pending` a `paras`. El llamante tiene el lock cogido.
    ///
    /// OJO: el Mutex de Zig no es reentrante, así que quien ya tenga el lock
    /// (como `streamEnd`) usa esta y NO `drainPending`.
    fn drainPendingLocked(self: *Model) void {
        // Re-anclar abajo SOLO si ha entrado algo de verdad. Antes se ponía
        // `scroll = 0` en cada frame, y como `drainPending` se llama siempre,
        // cualquier scroll se borraba en el frame siguiente: PageUp no movía
        // NADA y parecía que el scroll no funcionaba.
        const hubo_nuevo = self.pending.items.len > 0;
        for (self.pending.items) |p| {
            self.paras.append(self.allocator, .{ .kind = p.kind, .text = p.text, .base = p.base, .mood = p.mood }) catch {
                self.allocator.free(p.text);
            };
        }
        self.pending.clearRetainingCapacity();
        self.dirty = false;
        // Sticky bottom: si ya estabas scrolleando arriba, el texto nuevo NO
        // te tira de vuelta. Solo se re-ancla si estabas abajo (scroll == 0).
        if (hubo_nuevo and self.scroll == 0) self.scroll = 0;
    }

    /// Vacía el historial visible (Ctrl+L). Los párrafos cacheados se liberan
    /// y la sesión en disco no se toca.
    pub fn clearHistory(self: *Model) void {
        self.clearSegCache();
        for (self.paras.items) |p| self.allocator.free(p.text);
        self.paras.clearRetainingCapacity();
        self.scroll = 0;
    }

    /// Snapshot de "hay trabajo pendiente" bajo un solo lock (los getters
    /// lockeran, así que no se pueden llamar desde dentro).
    ///
    /// `streaming` va aquí y no se lee suelto en el draw: lo escribe el worker
    /// desde otro hilo, y un `bool` leído a pelo en cada frame es una carrera
    /// (benigna, pero gratuitamente difícil de depurar).
    pub const Activity = struct { busy: bool, dirty: bool, perm: bool, picker: bool, streaming: bool };

    fn activity(self: *Model) Activity {
        self.lock();
        defer self.unlock();
        return .{
            .busy = self.workingLocked(),
            .dirty = self.dirty,
            .perm = self.perm_active,
            .picker = self.picker_active,
            .streaming = self.streaming,
        };
    }

    /// Pide un frame dentro de `ms` ms. Idempotente: no apila timers.
    fn armTick(self: *Model, ctx: *vxfw.EventContext) !void {
        if (self.tick_armed) return;
        self.tick_armed = true;
        const a = self.activity();
        const ms: u32 = if (a.busy or a.dirty) 40 else 120;
        try ctx.tick(ms, self.widget());
    }

    /// Sube (`n` > 0) o baja el historial.
    pub fn scrollBy(self: *Model, n: isize) void {
        if (n == 0) return;
        if (n > 0) {
            const add: usize = @intCast(n);
            self.scroll = @min(self.scroll + add, 1_000_000);
        } else {
            const down: usize = @intCast(-n);
            self.scroll = if (self.scroll > down) self.scroll - down else 0;
        }
    }

    // ── paleta modal (Ctrl+P) ─────────────────────────────

    /// Abre la paleta en el modo indicado. `items` y `groups` los rellena
    /// quien llama (el agente) y deben seguir vivos mientras esté abierta;
    /// en la práctica viven en el allocator del modelo.
    pub fn openPaletteWith(self: *Model, mode: palette.Mode, items: []const palette.Item, groups: []const palette.Group) void {
        self.pal.mode = mode;
        self.pal.active = true;
        self.pal.query_len = 0;
        self.pal.setItems(items, groups);
        if (mode == .models) self.pal.col = 1 else self.pal.col = 0;
    }

    pub fn closePalette(self: *Model) void {
        self.pal.close();
    }

    /// Cierra la paleta liberando lo que sea suyo. Al salir del proceso.
    pub fn destroyPalette(self: *Model) void {
        if (self.pal_inited) self.pal.destroy();
    }

    /// Devuelve true si la paleta consumió la tecla.
    ///
    /// Traducir la acción (ejecutar un comando, cambiar de provider) lo hace
    /// el AGENTE, no la TUI: aquí solo se le pasa lo seleccionado y se espera
    /// un bool de "lo consumí".
    pub fn paletteKey(self: *Model, ctx: *vxfw.EventContext, key: vaxis.Key) !bool {
        const act = palette.handleKey(&self.pal, key);
        // OJO: hay que pedir redraw SIEMPRE. La palette muta su estado (query,
        // selección) y sin `ctx.redraw` la pantalla se queda como estaba:
        // se escribía "cache" y la lista no se filtraba, y Esc "no cerraba".
        ctx.redraw = true;
        switch (act) {
            .none => {},
            .close => {
                self.closePalette();
                return true;
            },
            .run_command => |cmd| {
                // Sin `eqlIgnoreCase` la etiqueta "Connect" no casaba con
                // "connect", el item caía en el caso genérico y se ejecutaba
                // LITERALMENTE como si fuera un comando.
                if (std.ascii.eqlIgnoreCase(cmd, "connect")) {
                    // Se reemplaza la paleta en sitio, sin cerrar primero: si
                    // no, se ve un parpadeo del historial entre modal y modal.
                    agent.openConnectPalette(self);
                    return true;
                }
                // Elegir un comando lo EJECUTA. Antes iba al input y había que
                // darle a Enter, y como la paleta se cerraba antes de escribir
                // el input, el comando se quedaba a medias hasta la siguiente
                // tecla (que era justo el síntoma de "esto no hace nada").
                //
                // La paleta se cierra ANTES de despachar: algunos comandos la
                // reabren con otro contenido (`/model` → paleta de modelos) y
                // si siguiera activa, esa se dibujaría encima y el `esc` de la
                // nueva no cerraría la vieja.
                self.closePalette();
                switch (agent.runPaletteCommand(self, cmd)) {
                    .done => {},
                    .needs_args => {
                        // Necesita argumentos: al input, con la barra puesta.
                        self.ed.clear();
                        self.ed.insert(cmd) catch {};
                        self.ed.insertChar(' ') catch {};
                    },
                    .quit => ctx.quit = true,
                }
                ctx.redraw = true;
                return true;
            },
            .set_provider => |p| {
                self.closePalette();
                try agent.applyProvider(self, p);
                return true;
            },
            .set_model => |mo| {
                self.closePalette();
                try agent.applyModel(self, mo);
                return true;
            },
            .connect => |conn| {
                // Guardar la key es I/O: lo hace el agente. La paleta sigue
                // abierta para que se vea el resultado.
                agent.storeKey(self, conn.provider, conn.key);
                self.pal.key_len = 0;
                return true;
            },
        }
        return true;
    }

    /// Llamar una vez al arrancar (el input ya no necesita callbacks).
    pub fn attach(self: *Model) void {
        _ = self;
    }

    pub fn widget(self: *Model) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

};

/// Estado del autocompletado de comandos `/`.
pub const Autocomplete = struct {
    /// El popup está abierto.
    active: bool = false,
    /// Índice del prefijo escrito tras la barra (`/mo` → 2).
    prefix_len: usize = 0,
    /// Posición en `agent.commands` del item resaltado.
    sel: usize = 0,
    /// Cuántos items caben (se recalcula en draw según la altura).
    max_visible: usize = 6,
    /// Primer índice visible (scroll de la lista).
    first: usize = 0,

    /// ¿El texto actual del input es un comando en curso?
    /// Solo se ofrece si aún no hay espacios: "/mod" sí, "/mod x" no.
    pub fn queryFor(text: []const u8) ?struct { prefix_len: usize } {
        if (text.len == 0 or text[0] != '/') return null;
        for (text) |c| {
            if (c == ' ' or c == '\n') return null;
        }
        return .{ .prefix_len = text.len };
    }
};

/// Todas las filas del surface como un solo texto (tests de dibujo).
pub fn allText(s: vxfw.Surface) []const u8 {
    var buf: [8192]u8 = undefined;
    var n: usize = 0;
    var row: u16 = 0;
    while (row < s.size.height and n < buf.len) : (row += 1) {
        const line = rowText(s, row, buf[n..]);
        n += @min(line.len, buf.len - n);
        if (n < buf.len) {
            buf[n] = '\n';
            n += 1;
        }
    }
    return buf[0..n];
}

/// Reconstruye el texto visible de una fila del surface (para tests).
/// El `arena` del frame debe seguir vivo: los graphemes se leen de ahí.
pub fn rowText(surface: vxfw.Surface, row: u16, buf: []u8) []const u8 {
    if (row >= surface.size.height) return buf[0..0];
    var n: usize = 0;
    var col: u16 = 0;
    while (col < surface.size.width) : (col += 1) {
        const cell = surface.readCell(col, row);
        const g = cell.char.grapheme;
        if (n + g.len > buf.len) break;
        @memcpy(buf[n .. n + g.len], g);
        n += g.len;
        // Una celda ancha ocupa 2 columnas: salta la ocupada.
        if (cell.char.width > 1) col += 1;
    }
    return buf[0..n];
}

// ── submit ───────────────────────────────────────────────────
/// Envía el contenido del input al agente y lo limpia (con historial).
fn submitInput(self: *Model, ctx: *vxfw.EventContext) !void {
    const trimmed = std.mem.trim(u8, self.ed.text(), " \t\r\n");
    if (trimmed.len == 0) {
        self.ed.clear();
        self.ac = .{};
        return;
    }
    if (std.mem.eql(u8, trimmed, "/quit")) {
        self.ed.clear();
        ctx.quit = true;
        return;
    }

    const owned = ctx.alloc.dupe(u8, trimmed) catch return;
    defer ctx.alloc.free(owned);

    // Eco del usuario en el historial, antes de despachar.
    self.pushKind(.user, trimmed);

    agent.submit(self, owned) catch |err| {
        const msg = std.fmt.allocPrint(ctx.alloc, "error: {t}", .{err}) catch "error";
        self.pushInfoOwned(msg);
    };

    self.ed.commit(); // guarda en el historial y limpia
    self.ac = .{};
    ctx.redraw = true;
    try self.armTick(ctx);
}

// ── handler de teclas del input ──────────────────────────────
/// Traduce una tecla a una edición del input. Devuelve true si la consumió.
fn editorKey(self: *Model, ctx: *vxfw.EventContext, key: vaxis.Key) !bool {
    const k = key;

    // Enter envía; Shift+Enter / Alt+Enter insertan salto de línea.
    if (k.matches(vaxis.Key.enter, .{})) {
        if (k.mods.shift or k.mods.alt) {
            try self.ed.insertChar('\n');
            syncAutocomplete(self);
            ctx.redraw = true;
            return true;
        }
        try submitInput(self, ctx);
        return true;
    }
    // Ctrl+J también envía (herencia del TextField de vaxis).
    if (k.matches('j', .{ .ctrl = true })) {
        try submitInput(self, ctx);
        return true;
    }

    if (k.matches(vaxis.Key.backspace, .{})) {
        if (k.mods.alt or k.mods.ctrl) {
            self.ed.deleteWordBefore();
        } else {
            self.ed.deleteBefore();
        }
        syncAutocomplete(self);
        ctx.redraw = true;
        return true;
    }
    if (k.matches(vaxis.Key.delete, .{}) or k.matches('d', .{ .ctrl = true })) {
        self.ed.deleteAfter();
        syncAutocomplete(self);
        ctx.redraw = true;
        return true;
    }

    // Movimiento
    const ctrl = k.mods.ctrl;
    const alt = k.mods.alt;
    if (k.matches(vaxis.Key.left, .{})) {
        if (ctrl or alt) self.ed.moveWordLeft() else self.ed.moveLeft();
        ctx.redraw = true;
        return true;
    }
    if (k.matches(vaxis.Key.right, .{})) {
        if (ctrl or alt) self.ed.moveWordRight() else self.ed.moveRight();
        ctx.redraw = true;
        return true;
    }
    if (k.matches(vaxis.Key.up, .{})) {
        // Arriba = historial de prompts.
        if (self.ed.historyPrev()) {
            syncAutocomplete(self);
            ctx.redraw = true;
        }
        return true;
    }
    if (k.matches(vaxis.Key.down, .{})) {
        if (self.ed.historyNext()) {
            syncAutocomplete(self);
            ctx.redraw = true;
        }
        return true;
    }
    if (k.matches(vaxis.Key.home, .{}) or k.matches('a', .{ .ctrl = true })) {
        self.ed.moveHome();
        ctx.redraw = true;
        return true;
    }
    if (k.matches(vaxis.Key.end, .{}) or k.matches('e', .{ .ctrl = true })) {
        self.ed.moveEnd();
        ctx.redraw = true;
        return true;
    }

    // Borrado de línea completa
    if (k.matches('u', .{ .ctrl = true })) {
        self.ed.deleteToStart();
        syncAutocomplete(self);
        ctx.redraw = true;
        return true;
    }
    if (k.matches('k', .{ .ctrl = true })) {
        self.ed.deleteToEnd();
        syncAutocomplete(self);
        ctx.redraw = true;
        return true;
    }
    if (k.matches('w', .{ .ctrl = true })) {
        self.ed.deleteWordBefore();
        syncAutocomplete(self);
        ctx.redraw = true;
        return true;
    }

    // Cualquier otro carácter imprimible (key.text decodifica UTF-8).
    if (k.text) |txt| {
        if (txt.len > 0 and !ctrl) {
            self.ed.insert(txt) catch {};
            syncAutocomplete(self);
            ctx.redraw = true;
            return true;
        }
    }
    return false;
}

/// Abre/actualiza el autocompletado según lo que haya en el input.
fn syncAutocomplete(self: *Model) void {
    if (Autocomplete.queryFor(self.ed.text())) |q| {
        self.ac.active = true;
        self.ac.prefix_len = q.prefix_len;
        recomputeMatches(self);
    } else {
        self.ac.active = false;
        self.ac.sel = 0;
        self.ac.first = 0;
    }
}

/// ¿`haystack` empieza por `needle` (case-insensitive)?
fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (needle, 0..) |nc, i| {
        if (std.ascii.toLower(haystack[i]) != std.ascii.toLower(nc)) return false;
    }
    return true;
}

/// Nombre del comando sin la barra: "/use <prov> [model]" → "use".
///
/// El autocompletado casa contra esto y no contra la línea entera: con la
/// línea completa, "/mod" casaría con "/use <prov> [model]".
fn commandToken(key: []const u8) []const u8 {
    var k = key;
    if (k.len > 0 and k[0] == '/') k = k[1..];
    if (std.mem.indexOfAny(u8, k, " \t")) |i| k = k[0..i];
    return k;
}

/// Recalcula cuántos comandos casan con el prefijo y dónde está la selección.
fn recomputeMatches(self: *Model) void {
    const n = matchCount(self);
    if (n == 0) {
        self.ac.active = false;
        return;
    }
    if (self.ac.sel >= n) self.ac.sel = n - 1;
    if (self.ac.sel < self.ac.first) self.ac.first = self.ac.sel;
    if (self.ac.sel >= self.ac.first + self.ac.max_visible) {
        self.ac.first = self.ac.sel - self.ac.max_visible + 1;
    }
}

/// Prefijo escrito tras la barra, o null si el input no es un comando.
fn acPrefix(self: *const Model) ?[]const u8 {
    const text = self.ed.text();
    if (self.ac.prefix_len == 0 or self.ac.prefix_len > text.len) return null;
    return text[1..self.ac.prefix_len];
}

/// Número de comandos que casan con el prefijo actual.
fn matchCount(self: *const Model) usize {
    const prefix = acPrefix(self) orelse return 0;
    var n: usize = 0;
    for (agent.commands) |c| {
        if (startsWithIgnoreCase(commandToken(c.key), prefix)) n += 1;
    }
    return n;
}

/// `agent.commands` del match número `n` (en orden de la lista).
fn matchAt(self: *const Model, n: usize) ?agent.Cmd {
    const prefix = acPrefix(self) orelse return null;
    var seen: usize = 0;
    for (agent.commands) |c| {
        if (!startsWithIgnoreCase(commandToken(c.key), prefix)) continue;
        if (seen == n) return c;
        seen += 1;
    }
    return null;
}

/// Acepta el comando resaltado: sustituye el prefijo por el comando completo.
/// ¿Lo escrito en el input es exactamente el comando resaltado?
///
/// Es el caso "no hay nada que completar": entonces Enter debe mandar, no
/// reescribir lo mismo con un espacio detrás.
fn isExactMatch(self: *Model) bool {
    if (!self.ac.active) return false;
    const typed = std.mem.trim(u8, self.ed.text(), " \t\r\n");
    if (typed.len == 0) return false;
    // Se compara contra TODOS los comandos, no solo contra el resaltado.
    //
    // Comparar solo con el resaltado rompía "/model": el popup ordenaba
    // "/models" primero, así que no era coincidencia exacta y Enter completaba
    // a "/models". Ahora: si lo escrito ES un comando se manda tal cual; si es
    // parcial ("mod"), se completa.
    for (agent.commands) |c| {
        if (std.mem.eql(u8, typed, c.key)) return true;
    }
    return false;
}

fn acceptAutocomplete(self: *Model) bool {
    if (!self.ac.active) return false;
    const cmd = matchAt(self, self.ac.sel) orelse return false;
    self.ed.clear();
    self.ed.insert(cmd.key) catch return false;
    self.ed.insertChar(' ') catch {};
    self.ac = .{};
    return true;
}

// ── handlers del widget raíz ─────────────────────────────────
fn typeErasedEventHandler(ud: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *Model = @ptrCast(@alignCast(ud));
    switch (event) {
        .key_press => |key| {
            // Ctrl+C: primero limpia el input, segundo pulso sale (así un
            // texto a medias nunca se pierde de un tirón).
            if (key.matches('c', .{ .ctrl = true })) {
                if (self.hasInput()) {
                    self.ed.clear();
                    self.ac = .{};
                    ctx.redraw = true;
                } else {
                    ctx.quit = true;
                }
                return;
            }
            // Ctrl+D con input vacío = EOF (salir).
            if (key.matches('d', .{ .ctrl = true }) and !self.hasInput()) {
                ctx.quit = true;
                return;
            }
            // Ctrl+P: paleta de comandos. Ctrl+T: paleta de modelos a dos
            // columnas (provider | sus modelos), como en opencode.
            if (key.matches('p', .{ .ctrl = true })) {
                agent.openCommandPalette(self);
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            if (key.matches('t', .{ .ctrl = true })) {
                agent.openModelPaletteAsync(self);
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            // Ctrl+A: conectar un provider. El pie de la paleta lo anunciaba y
            // no hacia nada, que es peor que no anunciarlo.
            if (key.matches('a', .{ .ctrl = true })) {
                agent.openConnectPalette(self);
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            // Ctrl+L: limpiar la vista.
            if (key.matches('l', .{ .ctrl = true })) {
                self.clearHistory();
                ctx.redraw = true;
                return;
            }
            // Ctrl+R: desplegar/replegar el resultado de la última tool.
            if (key.matches('r', .{ .ctrl = true })) {
                if (self.toggleLastTool()) {
                    ctx.redraw = true;
                } else {
                    // Sin tool previa, hace refresh del historial.
                    self.cache_from = 0;
                    ctx.redraw = true;
                }
                return;
            }
            // Paleta de Ctrl+P: captura TODO el input, incluido el scroll.
            if (self.pal.active) {
                if (try self.paletteKey(ctx, key)) {
                    try self.armTick(ctx);
                    return;
                }
            }

            // Picker modal activo: captura TODO el input.
            if (self.pickerActive()) {
                if (self.pickerHandleKey(key)) {
                    ctx.redraw = true;
                    try self.armTick(ctx);
                    return;
                }
            }
            // Autocompletado de `/` abierto: navega y acepta.
            if (self.ac.active and matchCount(self) > 0) {
                if (key.matches(vaxis.Key.up, .{})) {
                    if (self.ac.sel > 0) self.ac.sel -= 1;
                    recomputeMatches(self);
                    ctx.redraw = true;
                    return;
                }
                if (key.matches(vaxis.Key.down, .{})) {
                    const n = matchCount(self);
                    if (self.ac.sel + 1 < n) self.ac.sel += 1;
                    recomputeMatches(self);
                    ctx.redraw = true;
                    return;
                }
                // Tab y Enter (sin modificadores) aceptan el resaltado: con
                // el popup abierto, mandar "mod" a secas no es lo que el
                // usuario quiere, quiere /model.
                //
                // PERO si lo escrito ya es un comando COMPLETO, Enter lo MANDA
                // en vez de volver a completarlo. Antes no pasaba: "/help" +
                // Enter solo reescribía "/help " y no enviaba nada, así que
                // había que pulsarlo dos veces y parecía que el scroll no
                // tenía nada que enseñar. Y al revés tampoco: "/model" se
                // completaba a "/models" porque el popup ordenaba "/models"
                // primero y la coincidencia se miraba solo ahí.
                const plain_enter = key.matches(vaxis.Key.enter, .{}) and
                    !key.mods.shift and !key.mods.alt and !key.mods.ctrl;
                if (key.matches(vaxis.Key.tab, .{}) or plain_enter) {
                    // Si lo escrito ya es exactamente el comando, Enter MANDA.
                    // Se cierra el popup y se sale del bloque SIN `return` para
                    // que la tecla siga bajando hasta el editor, que hace el
                    // submit. Con `return` se perdía: "/help" + Enter solo
                    // reescribía "/help " y no enviaba nada.
                    if (plain_enter and isExactMatch(self)) {
                        self.ac = .{};
                        ctx.redraw = true;
                    } else {
                        if (acceptAutocomplete(self)) {
                            ctx.redraw = true;
                            try self.armTick(ctx);
                        }
                        return;
                    }
                } else {
                // Escape cierra el popup sin borrar lo escrito.
                if (key.matches(vaxis.Key.escape, .{})) {
                    self.ac.active = false;
                    ctx.redraw = true;
                    return;
                }
                }
            }
            // ESC aborta el stream en curso y cierra el diálogo de permisos.
            if (key.matches(vaxis.Key.escape, .{})) {
                chat.cancel_current.store(true, .seq_cst);
                // En modo ACP el corte va por su propio protocolo
                // (`session/cancel`): la bandera de los streams HTTP no
                // toca un proceso hijo.
                agent.cancelAcp(self);
                if (self.permActive()) self.answerPermission(.deny);
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            // Permission dialog active: y/a/n decide, rest ignored.
            if (self.permActive()) {
                const cp = key.codepoint;
                if (cp == 'y' or cp == 'Y') {
                    self.answerPermission(.allow);
                } else if (cp == 'a' or cp == 'A') {
                    self.answerPermission(.allow_always);
                } else if (cp == 'n' or cp == 'N') {
                    self.answerPermission(.deny);
                }
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            // ── scroll del historial ──
            // PageUp/PageDown mueven una PAGINA (la ventana entera, menos una
            // linea para que se vea lo anterior y lo posterior). Antes iban 5
            // fijas, que en una terminal de 40 filas no se sentian como scroll.
            // Ctrl+U / Ctrl+D hacen media pagina, como en less y en Claude Code.
            const k = key;
            const page: usize = @max(3, self.hist_rows -| 1);
            const half: usize = @max(2, self.hist_rows / 2);
            if (k.matches(vaxis.Key.page_up, .{}) or k.codepoint == 5 or
                (k.codepoint == 'k' and k.mods.shift) or
                (k.matches('u', .{ .ctrl = true })))
            {
                const step = if (k.matches('u', .{ .ctrl = true })) half else page;
                self.scrollBy(@intCast(step));
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }
            if (k.matches(vaxis.Key.page_down, .{}) or k.codepoint == 6 or
                (k.codepoint == 'j' and k.mods.shift) or
                (k.matches('d', .{ .ctrl = true })))
            {
                const step = if (k.matches('d', .{ .ctrl = true })) half else page;
                self.scrollBy(-@as(isize, @intCast(step)));
                ctx.redraw = true;
                try self.armTick(ctx);
                return;
            }

            // Todo lo demás va al editor del input.
            if (try editorKey(self, ctx, k)) {
                try self.armTick(ctx);
                return;
            }
            ctx.redraw = true;
        },
        .tick => {
            self.tick_armed = false;
            const a = self.activity();
            if (a.busy or a.dirty or a.perm or a.picker or self.pal.active) {
                ctx.redraw = true;
                try self.armTick(ctx); // sigue solo mientras haya trabajo
            }
        },
        .init => {
            ctx.redraw = true; // primer frame sin esperar a una tecla
            try self.armTick(ctx);
        },
        .focus_in => {
            ctx.redraw = true;
            try self.armTick(ctx);
        },
        .paste => |data| {
            // El editor propio no tiene callback de paste: insertamos a mano.
            // Un pegado con saltos crea un prompt multilínea de verdad.
            if (!self.pickerActive() and !self.permActive()) {
                self.ed.insert(data) catch {};
                syncAutocomplete(self);
            }
            ctx.redraw = true;
        },
        .mouse => |m| {
            // La rueda llega como botón 64/65 con type=press.
            if (m.type != .press) return;
            switch (m.button) {
                // OJO: `self.scroll` es usize. `self.scroll -= 3` con el
                // scroll en 0 desborda y tumba la app (integer overflow ->
                // panic), que es lo que pasaba al bajar con la rueda estando
                // arriba del todo. `scrollBy` es el que satura en 0.
                .wheel_up => self.scrollBy(3),
                .wheel_down => self.scrollBy(-3),
                else => return,
            }
            ctx.redraw = true;
        },
        .winsize => ctx.redraw = true,
        else => {},
    }
}

// ── helpers de dibujo ────────────────────────────────────────
fn typeErasedDrawFn(ud: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Model = @ptrCast(@alignCast(ud));

    const width: u16 = @intCast(ctx.max.width orelse ctx.min.width);
    const height: u16 = @intCast(ctx.max.height orelse ctx.min.height);
    if (height < 6 or width < 12) return vxfw.Surface.empty(self.widget());

    const size: vxfw.Size = .{ .width = width, .height = height };
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    var p = Painter{
        .surface = &surface,
        .arena = ctx.arena,
        .ctx = ctx,
        .width = width,
        .height = height,
    };

    // ── layout de abajo hacia arriba ──
    //   row height-2            status
    //   row height-3            borde inferior de la caja del input
    //   rows height-4-input_h   contenido del input (input_h filas)
    //   row height-4-input_h    borde superior de la caja
    //   row height-5-input_h    separador (o popup de autocompletado)
    //   rows 0..history_h       historial
    const status_row: u16 = height - 2;
    const max_input_lines: u16 = 8;
    const text_w: u16 = if (width > 4) width - 4 else 1;

    // Franja de actividad (mascota + estado + reloj): 1 fila, pero SOLO si hay
    // algo que contar. En reposo no ocupa nada, como debe ser.
    const act = self.activity();
    const queued = self.queuedCount();
    const act_rows: u16 = if (act.busy or queued > 0) 1 else 0;

    // Popup de autocompletado: solo si hay coincidencias.
    const ac_rows: u16 = if (self.ac.active and matchCount(self) > 0)
        @as(u16, @intCast(@min(matchCount(self), self.ac.max_visible) + 1))
    else
        0;

    // El input crece con el texto, pero nunca se come el historial: si no
    // caben las dos cosas, se recorta el input (y su vista se ancla abajo).
    const chrome: u16 = 4 + ac_rows + act_rows; // status + bordes + popup + franja
    const avail: u16 = if (height > chrome + 2) height - chrome - 2 else 1;
    const input_h: u16 = @max(@min(@as(u16, @intCast(@min(self.ed.displayLines(text_w), max_input_lines))), avail), 1);
    const input_top: u16 = height - 4 - act_rows - input_h;
    const history_h: u16 = if (input_top > 1) input_top - 1 else 1;
    // El handler de teclas necesita el alto para saltar una pagina entera.
    self.hist_rows = history_h;

    // ── drena pendientes ──
    self.drainPending();

    // Invalida la caché si cambió el ancho (las líneas ya vienen envueltas)
    // o si un párrafo se editó in-place (Ctrl+R despliega un tool result).
    if (self.cache_width != width) {
        self.clearSegCache();
        self.cache_width = width;
        self.cache_from = null;
    } else if (self.cache_from) |from| {
        // Suelta los párrafos desde `from` en adelante. OJO: `from` es un
        // índice del HISTORIAL, no de la caché (la caché es una ventana, así
        // que sus índices van desplazados: por eso se busca por `para_idx`).
        var i: usize = 0;
        while (i < self.seg_cache.items.len) {
            if (self.seg_cache.items[i].para_idx >= from) {
                self.evictCached(i);
            } else {
                i += 1;
            }
        }
        self.cache_from = null;
    }

    // ── layout del párrafo en vivo (se rehace cada frame) ──
    //
    // El SNAPSHOT se hace con el lock cogido y el PARSEO FUERA (1.6): antes se
    // parseaba markdown + highlighter + anchura de graphemes de TODO
    // `stream_buf` en cada frame y con el lock del modelo cogido, así que el
    // worker (que mete un `streamDelta` por token) competía con el draw en cada
    // token y el lock se convertía en un cuello de botella. Copiar es un
    // memcpy; parsear no.
    var live_src: []const u8 = &.{};
    var live_is_tool = false;
    var tool_buf: [128]u8 = undefined;
    {
        self.lock();
        defer self.unlock();
        if (self.streaming and self.stream_buf.items.len > 0) {
            live_src = self.stream_buf.items;
        }
        // Feedback de tool en curso. Sin esto, un `bash` de 30s deja la última
        // fila congelada en `⏺ bash(...)` y no hay forma de saber si el proceso
        // sigue vivo o si la app se ha colgado: el reloj es lo único que
        // contesta a "¿se ha pegado?".
        //
        // No hace falta concatenar con el streaming: nunca coexisten (una tool
        // se ejecuta con el stream cerrado), así que la línea de reloj REEMPLAZA
        // al párrafo vivo en vez de añadirse.
        if (self.tool_run) |tr| {
            const ms = self.toolRunMillisLocked();
            live_src = std.fmt.bufPrint(&tool_buf, "*{s}* running · {d}.{d}s", .{
                tr.name,
                ms / 1000,
                (ms % 1000) / 100,
            }) catch "";
            live_is_tool = true;
        }
        if (self.busy) self.spinner_frame +%= 1;
    }

    var live_lines: []const PLine = &.{};
    var live_active = false;
    if (live_src.len > 0) {
        // COPIA al arena del frame antes de construir las líneas. Los
        // `CellRun` guardan el grapheme POR VALOR pero con un puntero a sus
        // bytes, y el pintado ocurre DESPUÉS de este bloque: con `buf` de
        // stack, al salir de aquí el puntero queda colgando y la fila sale con
        // basura (el mismo bug de `&[_]u8{c}` que avisa AGENTS.md). Lo mismo
        // con `stream_buf`: su memoria es del modelo y el worker la sigue
        // creciendo.
        const copy = ctx.arena.dupe(u8, live_src) catch "";
        live_lines = buildLines(
            ctx.arena,
            ctx,
            if (live_is_tool) .tool_res else .assistant,
            copy,
            width,
        ) catch &.{};
        live_active = live_lines.len > 0;
    }

    // ── scroll: 0 = anclado abajo ──
    //
    // `layoutFor` deja la ventana de la caché cubriendo lo que se ve (así el
    // scroll profundo re-parsea on demand, que es lo que decía el comentario
    // viejo y no era verdad) y devuelve el rango visible ya estabilizado.
    const vis = try self.layoutFor(ctx, width, if (live_active) live_lines.len else 0, history_h);
    const first_visible = vis.first;
    const last_visible = vis.last;

    // ── limpia el área del historial ANTES de pintar ──
    //
    // Sin esto se quedan pixels de la version anterior del texto en streaming:
    // el parrafo en vivo se re-envuelve en cada frame y al ENCOGER (que pasa
    // cada vez que el modelo respira entre tokens) las celdas sobrantes
    // conservan el texto viejo. Se veía el mismo parrafo dos veces, partido y
    // mezclado, en medio de la respuesta.
    var clear_row: u16 = 0;
    while (clear_row < history_h) : (clear_row += 1) {
        p.fillRange(0, width, clear_row, " ", .{});
    }

    // ── pinta solo las líneas visibles ──
    //
    // `line_cursor` es la posición ABSOLUTA de la primera línea: el.offset de
    // la ventana (`cache_lo`) más lo que llevan los párrafos cacheados antes.
    var line_cursor: usize = 0;
    for (self.para_heights.items[0..self.cache_lo]) |h| line_cursor += h;
    for (self.seg_cache.items) |c| {
        defer line_cursor += c.height;
        if (line_cursor >= last_visible) break;
        if (line_cursor + c.height <= first_visible) continue;
        drawLines(&p, c.lines, line_cursor, first_visible, history_h);
    }
    if (live_active) {
        drawLines(&p, live_lines, line_cursor, first_visible, history_h);
    }

    // ── status: spinner + texto + info de sesión ──
    // La fila de status va por SEGMENTOS, no como una string: la carita y el
    // texto tienen que ir en colores distintos. Con una sola string todo salia
    // en el azul apagado y la carita no se veia NADA (que es justo la queja:
    // "no se nota por el color"). El mood es lo unico que hace que se sepa si
    // esta pensando, esperando permiso ooyo.
    var status_segs: std.ArrayList(InfoSeg) = .empty;
    const mood: mascot.Mood = self.mood();
    {
        self.lock();
        defer self.unlock();
        if (self.busy) {
            status_segs.append(ctx.arena, .{
                .text = Model.spinner_chars[self.spinner_frame % Model.spinner_chars.len],
                .style = theme.ctxColor(100),
            }) catch {};
            status_segs.append(ctx.arena, .{ .text = " ", .style = theme.brand_faint }) catch {};
        }
    }
    // La carita va PRIMERO y en el color del mood: es el indicador.
    {
        const face = mascot.faceFrames(mood, self.spinner_frame / 6);
        status_segs.append(ctx.arena, .{
            .text = face,
            .style = .{ .bold = true, .fg = .{ .index = mood.color() } },
        }) catch {};
        status_segs.append(ctx.arena, .{ .text = "  ", .style = theme.brand_faint }) catch {};
    }
    status_segs.append(ctx.arena, .{ .text = self.status(), .style = theme.brand_soft }) catch {};

    // Indicador de scroll: si el historial no está anclado abajo, hay que
    // decirlo. Sin esto se pierde contexto de "por qué no baja solo".
    if (self.scroll > 0) {
        const s = std.fmt.allocPrint(ctx.arena, "  ↓ {d}", .{self.scroll}) catch "";
        if (s.len > 0) status_segs.append(ctx.arena, .{ .text = s, .style = theme.warn }) catch {};
    }

    // La info de sesión (modelo · provider · effort · ctx% · tok/s) se pinta
    // segmentada más abajo, alineada a la derecha; aquí solo se prepara.
    const act_now = self.activity();
    const info: []const InfoSeg = sessionInfo(ctx.arena, act_now.streaming) orelse &.{};

    // ── picker modal (estilo opencode, centrado) ──
    if (self.pickerSnapshot(ctx.arena)) |ps| {
        drawPicker(&p, width, height, ps);
    }

    // ── diálogo de permisos (modal sobre el historial, abajo) ──
    var perm_tool: []const u8 = "";
    var perm_detail: []const u8 = "";
    if (!self.permActive() and ac_rows == 0) {
        // El separador solo cuando no hay popup (si no, se solaparían).
        if (input_top > 0) p.fillRow(input_top - 1, "─", theme.rule);
    }

    // ── status: texto a la izquierda + info de sesión a la derecha ──
    {
        var col: u16 = 0;
        for (status_segs.items) |sg| {
            col = p.putText(col, status_row, sg.text, sg.style);
        }
    }
    if (info.len > 0) drawSessionInfo(&p, status_row, width, info, self.activity().busy);

    // ── autocompletado de `/` (justo encima del input) ──
    if (ac_rows > 0) {
        drawAutocomplete(&p, self, input_top - ac_rows, width, ac_rows);
    }

    // ── input multilínea con borde ──
    // Franja de actividad: la MASCOTA es el indicador de "está trabajando".
    // Antes el único feedback era el spinner diminuto del status bar, que con
    // un modelo lento no dice nada: no se sabía si estaba pensando, esperando o
    // colgado. Aquí va la carita + el estado + los segundos Transcurridos, que
    // es lo que de verdad responde a "¿está trabajando o se ha pegado?".
    if (act_rows == 1 and input_top > 0) {
        drawActivityStrip(&p, input_top - 1, width, self, act, queued);
    }

    drawInput(&p, &surface, self, input_top, width, input_h);

    // ── diálogo de permisos: MODAL centrado ──
    //
    // Antes eran 4 líneas pegadas justo encima de la caja del input, en medio
    // del flujo normal: con el historial lleno se veían a medias o se tapaban,
    // y la app parecia COLGADA esperando algo que nadie veia. Ahora es una caja
    // centrada con borde, fondo limpio y las opciones en grande: no hay forma de
    // no verlo.
    if (self.permView(&perm_tool, &perm_detail)) {
        drawPermissionModal(&p, width, height, perm_tool, perm_detail);
    }

    // ── paleta modal (Ctrl+P): lo último, encima de todo ──
    //
    // Antes de dibujar: si el worker ha dejado modelos nuevos, se recarga la
    // paleta con ellos. Ocurre AQUÍ, en el hilo de la UI, que es el único
    // dueño de la paleta.
    if (self.takePendingItems()) |items| {
        self.pal.setItemsOwned(items, &agent.model_groups);
    }
    if (self.pal.active) {
        palette.draw(&p, &surface, &self.pal, width, height);
    }

    return surface;
}

/// Caja del input: borde redondeado, prompt `❯` y hasta `max_input_lines`
/// líneas. El cursor del terminal se ancla en la posición real del cursor.
fn drawInput(
    p: *Painter,
    surface: *vxfw.Surface,
    self: *Model,
    top: u16,
    width: u16,
    input_h: u16,
) void {
    if (top >= p.height or width < 6) return;

    const box_h: u16 = input_h + 2; // borde sup + contenido + borde inf
    p.putStable(0, top, "╭", 1, theme.input_border);
    p.fillRange(1, width - 1, top, "─", theme.input_border);
    p.putStable(width - 1, top, "╮", 1, theme.input_border);
    p.putStable(0, top + box_h - 1, "╰", 1, theme.input_border);
    p.fillRange(1, width - 1, top + box_h - 1, "─", theme.input_border);
    p.putStable(width - 1, top + box_h - 1, "╯", 1, theme.input_border);

    var r: u16 = 1;
    while (r < box_h - 1) : (r += 1) {
        p.putStable(0, top + r, "│", 1, theme.input_border);
        p.putStable(width - 1, top + r, "│", 1, theme.input_border);
    }

    // Prompt `❯ ` solo en la primera línea.
    _ = p.putText(2, top + 1, "❯ ", theme.input_prompt);

    const lines = splitLines(p.arena, self.ed.text());
    // Si el texto no cabe entero, la vista se ancla abajo (como el historial).
    const hidden = if (lines.len > input_h) lines.len - input_h else 0;
    const shown = lines[hidden..];

    for (shown, 0..) |ln, i| {
        const row = top + 1 + @as(u16, @intCast(i));
        if (row >= top + box_h - 1) break;
        _ = p.putText(2, row, ln, theme.input_text);
    }

    // Cursor visible: en la línea real del cursor dentro de la vista.
    const cur_line = self.ed.cursorLine();
    if (cur_line >= hidden and cur_line < lines.len) {
        const line = lines[cur_line];
        const start = lineStartOffset(lines, cur_line);
        const col_in_line = self.ed.cursor - start;
        const upto = line[0..@min(col_in_line, line.len)];
        var c: u16 = 0;
        var it = vaxis.unicode.graphemeIterator(upto);
        while (it.next()) |g| c += @as(u16, p.measure(g.bytes(upto)));
        surface.cursor = .{
            .row = top + 1 + @as(u16, @intCast(cur_line - hidden)),
            .col = 2 + c,
        };
    }

    if (self.ed.isEmpty()) {
        _ = p.putText(4, top + 1, "Ask anything\u{2026} \u{b7} / for commands \u{b7} ctrl+c to exit", theme.placeholder);
    }

    if (self.ac.active) {
        var hb: [64]u8 = undefined;
        const n = matchCount(self);
        const h = std.fmt.bufPrint(&hb, "{d} {s} \u{b7} tab complete", .{
            n,
            if (n == 1) @as([]const u8, "match") else "matches",
        }) catch "";
        if (h.len + 4 < width) {
            _ = p.putText(width - 2 - @as(u16, @intCast(h.len)), top + box_h - 1, h, theme.dim);
        }
    }
}

/// Lista de comandos que casan con lo escrito tras la `/`.
fn drawAutocomplete(
    p: *Painter,
    self: *const Model,
    top: u16,
    width: u16,
    rows: u16,
) void {
    if (width < 10 or rows < 2) return;
    p.fillRange(0, width, top, " ", .{});
    p.fillRange(0, width, top + rows - 1, "─", theme.rule);

    const first = self.ac.first;
    for (0..rows -| 1) |i| {
        const cmd = matchAt(self, first + i) orelse break;
        const y = top + @as(u16, @intCast(i));
        const is_sel = first + i == self.ac.sel;
        if (is_sel) p.fillRange(0, width, y, " ", theme.selected);
        _ = p.putText(1, y, cmd.key, if (is_sel) theme.selected else theme.accent);
        if (cmd.key.len + 4 < width) {
            var db: [96]u8 = undefined;
            const d = std.fmt.bufPrint(&db, "  {s}", .{cmd.desc}) catch continue;
            _ = p.putText(3 + @as(u16, @intCast(cmd.key.len)), y, d, theme.dim);
        }
    }
}

/// Parte el texto en líneas lógicas. Arena del frame: el slice vive un frame.
fn splitLines(arena: std.mem.Allocator, text: []const u8) [][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| out.append(arena, l) catch break;
    return out.items;
}

/// Offset en bytes del inicio de la línea `line`.
fn lineStartOffset(lines: [][]const u8, line: usize) usize {
    var off: usize = 0;
    for (lines[0..@min(line, lines.len)]) |l| off += l.len + 1; // +1 por el '\n'
    return off;
}

/// Pinta las líneas de un párrafo, recortadas a la ventana visible
/// [first_visible, last_visible) mapeada a las filas [0, history_h).
fn drawLines(
    p: *Painter,
    lines: []const PLine,
    line_offset: usize,
    first_visible: usize,
    history_h: u16,
) void {
    const hh: usize = history_h;
    for (lines, 0..) |ln, li| {
        const abs = line_offset + li;
        if (abs >= first_visible + hh) break;
        if (abs < first_visible) continue;
        const row: u16 = @intCast(abs - first_visible);
        var col: u16 = 0;
        for (ln.cells) |cell| {
            p.putStable(col, row, cell.text, cell.w, cell.style);
            col += cell.w;
            if (col >= p.width) break;
        }
    }
}

/// Pie con los atajos de teclado. Se atenúa cuando el usuario está escribiendo.
/// El diálogo de pedir permiso, como modal centrado.
///
/// Es lo que bloquea el turno, asi que tiene que ser IMPOSIBLE de no ver:
/// fondo limpio (si no, el historial se transparenta a traves), borde en
/// amarillo, el nombre de la tool en grande y las cuatro opciones con su tecla
/// resaltada.
fn drawPermissionModal(
    p: *Painter,
    width: u16,
    height: u16,
    tool: []const u8,
    detail: []const u8,
) void {
    const w: u16 = @min(width -| 6, 68);
    if (w < 30) return;
    const h: u16 = 9;
    if (height < h + 2) return;
    const x: u16 = (width -| w) / 2;
    const y: u16 = (height -| h) / 2;

    // Fondo: sin esto los items del historial se transparentan debajo.
    var r: u16 = 0;
    while (r < h) : (r += 1) {
        p.fillRange(x, x + w, y + r, " ", .{});
    }

    // Borde.
    p.fillRange(x + 1, x + w - 1, y, "─", theme.warn_bold);
    p.fillRange(x + 1, x + w - 1, y + h - 1, "─", theme.warn_bold);
    var c: u16 = 1;
    while (c < h - 1) : (c += 1) {
        p.putStable(x, y + c, "│", 1, theme.warn_bold);
        p.putStable(x + w - 1, y + c, "│", 1, theme.warn_bold);
    }
    p.putStable(x, y, "╭", 1, theme.warn_bold);
    p.putStable(x + w - 1, y, "╮", 1, theme.warn_bold);
    p.putStable(x, y + h - 1, "╰", 1, theme.warn_bold);
    p.putStable(x + w - 1, y + h - 1, "╯", 1, theme.warn_bold);

    // Titulo, con la carita de Zo en el color de "warn".
    _ = p.putText(x + 3, y + 1, "⚠  Permission required", theme.warn_bold);

    // Que tool y con que argumentos.
    _ = p.putText(x + 3, y + 3, "This tool wants to run:", theme.brand_soft);
    var nb: [64]u8 = undefined;
    const tname = std.fmt.bufPrint(&nb, "{s}", .{tool}) catch tool;
    _ = p.putText(x + 3, y + 4, tname, theme.brand_bold);

    // Detalle, recortado al ancho de la caja.
    const max_d = @as(usize, w - 6);
    if (detail.len > 0) {
        const d: []const u8 = if (detail.len > max_d) detail[0..max_d] else detail;
        _ = p.putText(x + 3, y + 5, d, theme.dim);
    }

    // Opciones, cada una con su tecla en grande. La primera (y) es la que se
    // pulsa sin mirar, asi que va resaltada.
    const opts = [_]struct { key: []const u8, label: []const u8 }{
        .{ .key = "Y", .label = "allow once" },
        .{ .key = "A", .label = "always allow" },
        .{ .key = "N", .label = "deny" },
        .{ .key = "ESC", .label = "cancel" },
    };
    var ox: u16 = x + 3;
    for (opts, 0..) |o, i| {
        _ = p.putText(ox, y + 7, o.key, theme.brand_bold);
        const adv: u16 = @as(u16, @intCast(o.key.len)) + 1;
        ox += adv;
        ox = p.putText(ox, y + 7, o.label, if (i == 0) theme.brand else theme.brand_soft);
        if (i + 1 < opts.len and ox + 4 < x + w) {
            ox = p.putText(ox, y + 7, "   ", theme.brand_faint);
        }
    }
}

/// La franja de "está trabajando", justo encima de la caja del input.
///
/// Es la respuesta a "¿se ha pegado o está pensando?": la carita de Zoanimate
/// con el estado, los SEGUNDOS transcurridos (que es lo único que distingue
/// "pensando" de "colgado") y lo que hay en cola. Sin esto el único feedback
/// era un spinner de 8px en el status bar.
///
/// La ETIQUETA es la fase, no un "working" genérico. "Working" durante 40
/// segundos no dice si el modelo está pensando, si ya está escribiendo o si hay
/// un `bash` colgado: son tres esperas muy distintas y el usuario las vive como
/// la misma. Con la fase nombrada, el reloj se lee distinto ("hace 3s que
/// espera el servidor" y "hace 30s que corre este comando" no son lo mismo).
///
/// Cuando hay cola se ven también los prompts encolados, para que se sepa qué
/// va a salir después en vez de tener que acordarse.
fn drawActivityStrip(
    p: *Painter,
    row: u16,
    width: u16,
    self: *Model,
    act: Model.Activity,
    queued: usize,
) void {
    p.fillRow(row, " ", .{});

    // La carita ANIMA: alterna entre ojos abiertos y entornados mientras hay
    // trabajo. Es la señal de que la app está viva, que es justo lo que no se
    // veía cuando un modelo lento parecía colgado.
    const mood_kind: mascot.Mood = if (act.perm) .warn else if (act.busy) .thinking else .idle;
    const face = mascot.faceFrames(mood_kind, self.spinner_frame / 6);
    const mood: vaxis.Style = if (act.perm) theme.warn else if (act.busy) theme.brand else theme.brand_soft;

    var col: u16 = 1;
    _ = p.putText(col, row, face, mood);
    col += @as(u16, @intCast(face.len));

    // Estado: lo primero que hay que poder leer de un vistazo, y ahora la FASE.
    const running_tool = self.toolRunName() != null;
    const label: []const u8 = if (act.perm)
        "waiting for your permission"
    else if (running_tool)
        "running"
    else if (act.streaming)
        "streaming"
    else if (act.busy)
        "thinking"
    else
        "queued";
    _ = p.putText(col, row, label, theme.brand_bold);
    col += @as(u16, @intCast(label.len)) + 1;

    // Qué está haciendo, cuando es una tool. "thinking" a secas con un `bash`
    // de 30s no dice si está trabajando o colgado; el NOMBRE de la tool y su
    // reloj sí. Es la misma información que la línea `⎿ running` del historial,
    // aquí en la franja para que se lea sin tener que scrollear.
    if (self.toolRunName()) |name| {
        if (col + name.len + 2 < width) {
            _ = p.putText(col, row, name, theme.brand_soft);
            col += @as(u16, @intCast(name.len)) + 1;
        }
    }

    // Reloj. Sin el, un turno lento parece colgado.
    if (act.busy) {
        var cbuf: [24]u8 = undefined;
        const ms = self.busyMillis();
        const ts = std.fmt.bufPrint(&cbuf, "{d}.{d}s", .{ ms / 1000, (ms % 1000) / 100 }) catch "";
        if (ts.len > 0) {
            _ = p.putText(col, row, ts, theme.brand_soft);
            col += @as(u16, @intCast(ts.len)) + 1;
        }
    }

    // Velocidad mientras llega el texto. Es el segundo dato que hace falta para
    // distinguir "el modelo va lento" de "se ha colgado el stream": 2 tok/s con
    // el reloj corriendo es una respuesta lenta; el reloj parado y esto a cero,
    // no.
    //
    // OJO: `agent.tps_live` se lee SIN lock a propósito. Es un `f64` que
    // escribe el worker una vez por stream y lo lee el status bar en cada frame
    // desde hace meses: es atómico en la práctica (una palabra), y meter un lock
    // en el camino de dibujo para un número que va de 0 a 200 no compensa.
    if (act.streaming and agent.tps_live > 1) {
        var tbuf: [32]u8 = undefined;
        const ts2 = std.fmt.bufPrint(&tbuf, "⚡ {d:.0} tok/s", .{agent.tps_live}) catch "";
        if (ts2.len > 0 and col + ts2.len + 2 < width) {
            _ = p.putText(col, row, ts2, theme.brand_soft);
            col += @as(u16, @intCast(ts2.len)) + 1;
        }
    }

    // Cola: cuántos y cuáles, para no perderlos de vista.
    if (queued > 0) {
        var qbuf: [32]u8 = undefined;
        const q = std.fmt.bufPrint(&qbuf, "⏳ {d} queued", .{queued}) catch "";
        if (col + q.len + 2 < width and q.len > 0) {
            _ = p.putText(col, row, q, theme.warn);
            col += @as(u16, @intCast(q.len)) + 1;
        }
        var q2: [24]u8 = undefined;
        const nxt = std.fmt.bufPrint(&q2, "next: {s}", .{self.queuedFirst(24)}) catch "";
        if (nxt.len > 4 and col + nxt.len + 2 < width) {
            _ = p.putText(col, row, nxt, theme.brand_faint);
        }
    }
}

/// Un trozo de la fila de status con su estilo.
const InfoSeg = struct { text: []const u8, style: vaxis.Style };

/// Info de sesión del status bar: modelo · provider (effort) · ctx% · tok/s.
///
/// Es un array de segmentos (texto + estilo) en vez de una string, porque cada
/// parte va en un color: el modelo en el azul brillante, el resto en el
/// apagado, el ctx% verde/amarillo/rojo según lo lleno que esté y los tok/s
/// en cyan. Con una sola string todo salía del mismo gris.
///
/// `streaming` (y no `busy`) es lo que decide si se pintan los tok/s:
/// `tps_live` es el del ÚLTIMO stream y no se borra al terminar el turno, así
/// que con un `bash` de 30s la fila seguía anunciando "⚡ 42 tok/s" mientras no
/// llegaba ni un token. Es un número que no va con lo que dice al lado.
fn sessionInfo(arena: std.mem.Allocator, streaming: bool) ?[]const InfoSeg {
    var out: std.ArrayList(InfoSeg) = .empty;

    const model = agent.curModel();
    const provider = agent.curProvider();
    if (model.len == 0 and provider.len == 0) return null;

    if (model.len > 0) {
        out.append(arena, .{ .text = model, .style = theme.brand_bold }) catch return null;
    }
    if (provider.len > 0) {
        if (out.items.len > 0) out.append(arena, .{ .text = " · ", .style = theme.brand_faint }) catch return null;
        out.append(arena, .{ .text = provider, .style = theme.brand_soft }) catch return null;
        const eff = switch (agent.current_effort) {
            .low => "low",
            .medium => "med",
            .high => "high",
        };
        // OJO: `allocPrint` y NO `bufPrint` sobre un buffer de stack. El
        // slice se guarda en el segmento y se lee al pintar, ya fuera de esta
        // función: con bufPrint el texto era basura y el status se cortaba a
        // mitad ("kimi-k2.6 · opencode" y luego un caracter roto).
        const et = std.fmt.allocPrint(arena, " ({s})", .{eff}) catch return null;
        out.append(arena, .{ .text = et, .style = theme.brand_faint }) catch return null;
    }

    // Modo ACP: el turno NO lo hace zode, lo delega a otro agente. Sin esto el
    // status sigue diciendo "space-bunny-free · opencode" mientras el que
    // responde es otro, que es justo la clase de sorpresa que no vale.
    if (agent.acp_on) {
        if (out.items.len > 0) out.append(arena, .{ .text = " · ", .style = theme.brand_faint }) catch return null;
        const tag = std.fmt.allocPrint(arena, "acp: {s}", .{agent.acpTitle()}) catch return null;
        out.append(arena, .{ .text = tag, .style = theme.warn }) catch return null;
    }

    // Tokens de contexto SIEMPRE visibles, no solo cuando son > 0.
    //
    // Estaba condicionado a `ctx_pct > 0`, que solo ocurre tras un turno
    // completo, así que al empezar no se veía nada y parecía que el contador no
    // existía. Ahora siempre dice "~N tok" y el porcentaje, que además es lo
    // que avisa de que se está acercando al límite de compaction.
    if (out.items.len > 0) out.append(arena, .{ .text = " · ", .style = theme.brand_faint }) catch return null;
    if (agent.ctx_used > 0) {
        const tk = std.fmt.allocPrint(arena, "~{d} tok", .{agent.ctx_used}) catch return null;
        out.append(arena, .{ .text = tk, .style = theme.brand_soft }) catch return null;
        out.append(arena, .{ .text = " · ", .style = theme.brand_faint }) catch return null;
    }
    const ct = std.fmt.allocPrint(arena, "ctx {d}%", .{agent.ctx_pct}) catch return null;
    out.append(arena, .{ .text = ct, .style = theme.ctxColor(agent.ctx_pct) }) catch return null;

    if (streaming and agent.tps_live > 1) {
        out.append(arena, .{ .text = " · ", .style = theme.brand_faint }) catch return null;
        const tt = std.fmt.allocPrint(arena, "⚡ {d:.0} tok/s", .{agent.tps_live}) catch return null;
        out.append(arena, .{ .text = tt, .style = theme.tool }) catch return null;
    }

    if (out.items.len == 0) return null;
    return out.items;
}

/// Dibuja la info de sesión alineada a la derecha, midiendo el ancho total
/// con el ancho de celda REAL (no `len`): los emojis y los `·` ocupan 1, pero
/// si alguna vez entra un grapheme de 2 columnas, alinear por `len` descuadra
/// la fila entera.
fn drawSessionInfo(p: *Painter, row: u16, width: u16, segs: []const InfoSeg, busy: bool) void {
    _ = busy;
    var total: u16 = 0;
    for (segs) |sg| {
        var it = vaxis.unicode.graphemeIterator(sg.text);
        while (it.next()) |g| {
            _ = g;
            total += 1;
        }
    }
    if (total + 2 >= width) return; // no cabe: se omite antes de invadir el texto

    var col: u16 = width - total;
    for (segs) |sg| {
        var it = vaxis.unicode.graphemeIterator(sg.text);
        while (it.next()) |g| {
            const b = g.bytes(sg.text);
            const w = theme.graphemeWidth(p.ctx, b);
            if (col + w <= width) _ = p.putStable(col, row, b, w, sg.style);
            col += w;
        }
    }
}

fn drawHints(p: *Painter, row: u16, self: *const Model) void {
    const typing = self.hasInput();
    if (typing) return; // con texto en el input solo dejamos la pista
    _ = p.putText(2, row, "esc interrupts · ctrl+r expands · ctrl+l clears · ctrl+p palette", theme.dim);
}

/// Modal centrado estilo opencode: título, filtro, items con selección y footer.
fn drawPicker(p: *Painter, width: u16, height: u16, ps: PickerSnapshot) void {
    const box_w: u16 = @min(width -| 4, 64);
    const box_h: u16 = @min(height -| 4, 15);
    if (box_w < 20 or box_h < 6) return;
    const x0 = (width - box_w) / 2;
    const y0 = (height - box_h) / 4; // un poco arriba del centro

    // fondo limpio del box
    var yy = y0;
    while (yy < y0 + box_h) : (yy += 1) {
        p.fillRange(x0, x0 + box_w, yy, " ", .{});
    }
    // bordes horizontales
    p.fillRange(x0 + 1, x0 + box_w - 1, y0, "─", theme.accent);
    p.fillRange(x0 + 1, x0 + box_w - 1, y0 + box_h - 1, "─", theme.accent);
    // bordes verticales
    var yy2 = y0 + 1;
    while (yy2 < y0 + box_h - 1) : (yy2 += 1) {
        p.putStable(x0, yy2, "│", 1, theme.accent);
        p.putStable(x0 + box_w - 1, yy2, "│", 1, theme.accent);
    }
    p.putStable(x0, y0, "┌", 1, theme.accent);
    p.putStable(x0 + box_w - 1, y0, "┐", 1, theme.accent);
    p.putStable(x0, y0 + box_h - 1, "└", 1, theme.accent);
    p.putStable(x0 + box_w - 1, y0 + box_h - 1, "┘", 1, theme.accent);

    // título y filtro
    var tbuf: [96]u8 = undefined;
    const t1 = std.fmt.bufPrint(&tbuf, " {s}", .{ps.title}) catch " picker";
    _ = p.putText(x0 + 2, y0, t1, theme.accent_bold);
    var qbuf: [96]u8 = undefined;
    const q1 = if (ps.query.len > 0)
        std.fmt.bufPrint(&qbuf, "filter: {s}_", .{ps.query}) catch "filter: _"
    else
        "filter: (type to search)";
    _ = p.putText(x0 + 2, y0 + 1, q1, theme.dim);

    // items
    const item_rows: usize = box_h - 5; // title + query + footer + 2 bordes
    for (ps.items, 0..) |it, i| {
        if (i >= item_rows) break;
        const row = y0 + 2 + @as(u16, @intCast(i));
        const is_sel = ps.first_visible + i == ps.sel;
        if (is_sel) p.fillRange(x0 + 1, x0 + box_w - 1, row, " ", theme.selected);
        var ib: [256]u8 = undefined;
        const line_txt = if (it.desc.len > 0)
            std.fmt.bufPrint(&ib, "{s}  {s}", .{ it.label, it.desc }) catch it.label
        else
            it.label;
        _ = p.putText(x0 + 2, row, line_txt, if (is_sel) theme.selected else theme.text);
    }

    // footer
    var fbuf: [96]u8 = undefined;
    const f1 = std.fmt.bufPrint(
        &fbuf,
        "\u{2191}\u{2193} navigate \u{b7} enter select \u{b7} esc close  ({d}/{d})",
        .{ if (ps.total > 0) ps.sel + 1 else 0, ps.total },
    ) catch "";
    _ = p.putText(x0 + 2, y0 + box_h - 2, f1, theme.dim);
}

// ── tests de render ──────────────────────────────────────────
//
// Regresión del bug que dejaba la pantalla en blanco: los graphemes se
// escribían con `&[_]u8{c}` (puntero a temporal de stack) y vaxis los leía
// DESPUÉS de retornar de drawFn → NULs. Estos tests leen el buffer del
// surface y comparan el texto real, que es lo que el renderer va a imprimir.

/// Pinta un frame del modelo con la arena dada (para tests). El surface solo
/// vale mientras la arena siga viva.
pub fn drawTest(model: *Model, arena: std.mem.Allocator, w: u16, h: u16) !vxfw.Surface {
    const wd = model.widget();
    return wd.drawFn(wd.userdata, .{
        .arena = arena,
        .min = .{ .width = w, .height = h },
        .max = .{ .width = w, .height = h },
        .cell_size = .{ .width = 1, .height = 1 },
    });
}

test "render: un párrafo de info se ve en la fila 0" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.pushInfo("hola mundo");

    const s = try drawTest(&m, arena, 40, 12);
    var buf: [128]u8 = undefined;
    const row0 = rowText(s, 0, &buf);
    // Prefijo de info + texto.
    try std.testing.expectEqualStrings("\u{b7} hola mundo", std.mem.trim(u8, row0, " "));
}

test "render: graphemes multibyte salen íntegros (no byte a byte)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.pushInfo("a\u{00f1}o \u{2500}\u{2500} \u{2713}");

    const s = try drawTest(&m, arena, 40, 12);
    var buf: [128]u8 = undefined;
    const row0 = rowText(s, 0, &buf);
    try std.testing.expectEqualStrings(
        "\u{b7} a\u{00f1}o \u{2500}\u{2500} \u{2713}",
        std.mem.trim(u8, row0, " "),
    );
}

test "render: el stream en vivo se ve antes de streamEnd" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.streamStart();
    m.streamDelta("parci");
    const s = try drawTest(&m, arena, 40, 12);
    var buf: [128]u8 = undefined;
    const row0 = rowText(s, 0, &buf);
    try std.testing.expect(std.mem.indexOf(u8, row0, "parci") != null);

    // Al cerrar el stream, el texto pasa a párrafo fijo.
    m.streamDelta("al");
    m.streamEnd();
    const s2 = try drawTest(&m, arena, 40, 12);
    var buf2: [128]u8 = undefined;
    const row0b = rowText(s2, 0, &buf2);
    try std.testing.expectEqualStrings("\u{25c6} parcial", std.mem.trim(u8, row0b, " "));
}

test "render: el texto largo hace wrap sin perder caracteres" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const msg = "abcdefghijklmnopqrstuvwxyz0123456789";
    m.pushInfo(msg);

    const width: u16 = 20;
    const s = try drawTest(&m, arena, width, 12);

    // Reconstruye todas las filas del historial y comprueba que la concatenación
    // (sin espacios de relleno) devuelve el mensaje intacto.
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(std.testing.allocator);
    var buf: [128]u8 = undefined;
    // El historial ahora ocupa todo menos status + caja del input.
    const history_rows: u16 = 12 - 6; // status + caja(3) + separador
    var row: u16 = 0;
    while (row < history_rows) : (row += 1) {
        const line = std.mem.trim(u8, rowText(s, row, &buf), " ");
        // la primera línea lleva el prefijo "· " delante del texto
        const body = if (row == 0 and line.len > 0) line[2..] else line;
        for (body) |c| {
            if (c != ' ') acc.append(std.testing.allocator, c) catch {};
        }
    }
    try std.testing.expectEqualStrings(msg, acc.items);
}

test "render: el status y el separador ocupan las filas de abajo" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.setStatusText("ready");

    const height: u16 = 12;
    const s = try drawTest(&m, arena, 40, height);

    var buf: [128]u8 = undefined;
    // separador: una fila encima del borde superior de la caja del input
    const sep = rowText(s, height - 6, &buf);
    try std.testing.expectEqualStrings("\u{2500}", sep[0..3]);
    // borde superior de la caja del input
    var buf3: [128]u8 = undefined;
    const box = rowText(s, height - 5, &buf3);
    try std.testing.expectEqualStrings("\u{256d}", std.mem.trim(u8, box, " ")[0..3]);
    // status
    var buf2: [128]u8 = undefined;
    const st = rowText(s, height - 2, &buf2);
    try std.testing.expect(std.mem.indexOf(u8, st, "ready") != null);
}

test "render: tool blocks usan ⏺/⎿ y el resultado se despliega" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.pushToolStart("read", "src/tui.zig");
    m.pushToolDone("read", "Read 1006 lines", 3, "1|const std\n2|fn main()");

    // Estado colapsado: dos párrafos, cabecera y resumen.
    //
    // Se buscan por CONTENIDO y no por fila: desde que los párrafos llevan una
    // fila en blanco de separación, la posición del segundo depende de cuántos
    // bloques haya delante y el test se rompía con cada cambio de layout.
    const s = try drawTest(&m, arena, 60, 14);
    try std.testing.expect(findRow(s, "read(src/tui.zig)") != null);
    try std.testing.expect(findRow(s, "Read 1006 lines") != null);
    {
        var buf: [256]u8 = undefined;
        const r = findRow(s, "read(src/tui.zig)").?;
        try std.testing.expectEqualStrings("\u{23fa} read(src/tui.zig)", std.mem.trim(u8, rowText(s, r, &buf), " "));
        const r2 = findRow(s, "Read 1006 lines").?;
        try std.testing.expectEqualStrings("\u{23bf}  Read 1006 lines \u{b7} 3ms", std.mem.trim(u8, rowText(s, r2, &buf), " "));
    }

    // Ctrl+R despliega el resultado completo (varias líneas).
    try std.testing.expect(m.toggleLastTool());
    var arena2_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena2_state.deinit();
    const s2 = try drawTest(&m, arena2_state.allocator(), 60, 14);
    try std.testing.expect(findRow(s2, "const std") != null);

    // Y repliega de vuelta al resumen.
    try std.testing.expect(m.toggleLastTool());
    var arena3_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena3_state.deinit();
    const s3 = try drawTest(&m, arena3_state.allocator(), 60, 14);
    try std.testing.expect(findRow(s3, "Read 1006 lines") != null);
}

test "toggleLastTool sin tool previa no hace nada" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.pushInfo("solo info");
    try std.testing.expect(!m.toggleLastTool());
}

test "input: caja con borde, prompt y placeholder" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const h: u16 = 14;
    const s = try drawTest(&m, arena_state.allocator(), 40, h);

    var buf: [128]u8 = undefined;
    // borde superior redondeado
    const top = rowText(s, h - 5, &buf);
    try std.testing.expectEqualStrings("\u{256d}\u{2500}", std.mem.trim(u8, top, " ")[0..6]);
    // contenido: prompt + placeholder
    var buf2: [128]u8 = undefined;
    const mid = rowText(s, h - 4, &buf2);
    try std.testing.expect(std.mem.indexOf(u8, mid, "\u{276f}") != null);
    try std.testing.expect(std.mem.indexOf(u8, mid, "Ask anything") != null);
    // borde inferior
    var buf3: [128]u8 = undefined;
    const bot = rowText(s, h - 3, &buf3);
    try std.testing.expectEqualStrings("\u{2570}\u{2500}", std.mem.trim(u8, bot, " ")[0..6]);
}

test "input: multilínea crece la caja y muestra ambas líneas" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const h: u16 = 16;
    // Tres líneas: la caja debe pasar a 3 filas de contenido.
    m.ed.insert("primera\nsegunda\ntercera") catch {};

    const s = try drawTest(&m, arena_state.allocator(), 40, h);
    var buf: [128]u8 = undefined;
    const top = rowText(s, h - 7, &buf); // input_h=3 → top = h-4-3
    try std.testing.expect(std.mem.indexOf(u8, std.mem.trim(u8, top, " "), "\u{256d}") != null);

    var b1: [128]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, rowText(s, h - 6, &b1), "primera") != null);
    var b2: [128]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, rowText(s, h - 5, &b2), "segunda") != null);
    var b3: [128]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, rowText(s, h - 4, &b3), "tercera") != null);
}

test "autocompletado: filtra por prefijo y acepta con tab" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.ed.insert("/mo") catch {};
    syncAutocomplete(&m);
    try std.testing.expect(m.ac.active);
    // /model, /models y /mode... no: /model, /models y /memory no existe,
    // pero /models sí. Comprobamos contra la lista real.
    const n_mo = matchCount(&m);
    try std.testing.expect(n_mo >= 2);
    var has_model = false;
    var has_models = false;
    for (0..n_mo) |i| {
        const k = matchAt(&m, i).?.key;
        if (std.mem.eql(u8, k, "/model")) has_model = true;
        if (std.mem.eql(u8, k, "/models")) has_models = true;
    }
    try std.testing.expect(has_model);
    try std.testing.expect(has_models);

    // "/models" deja solo /models (el prefijo más largo manda)
    m.ed.clear();
    m.ed.insert("/models") catch {};
    syncAutocomplete(&m);
    try std.testing.expectEqual(@as(usize, 1), matchCount(&m));
    try std.testing.expectEqualStrings("/models", matchAt(&m, 0).?.key);

    // "/mod" deja /model y /models
    m.ed.clear();
    m.ed.insert("/mod") catch {};
    syncAutocomplete(&m);
    try std.testing.expectEqual(@as(usize, 2), matchCount(&m));
    m.ac.sel = 0;
    try std.testing.expectEqualStrings("/models", matchAt(&m, 0).?.key);

    // Tab completa el comando seleccionado y añade el espacio.
    try std.testing.expect(acceptAutocomplete(&m));
    try std.testing.expectEqualStrings("/models ", m.ed.text());
    try std.testing.expect(!m.ac.active);

    // Con la selección en el segundo match completa ese.
    m.ed.clear();
    m.ed.insert("/mod") catch {};
    syncAutocomplete(&m);
    m.ac.sel = 1;
    try std.testing.expect(acceptAutocomplete(&m));
    try std.testing.expectEqualStrings("/model ", m.ed.text());
}

test "autocompletado: no se ofrece con espacios ni sin barra" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.ed.insert("hola") catch {};
    syncAutocomplete(&m);
    try std.testing.expect(!m.ac.active);

    m.ed.clear();
    m.ed.insert("/model x") catch {}; // ya tiene argumento
    syncAutocomplete(&m);
    try std.testing.expect(!m.ac.active);

    m.ed.clear();
    m.ed.insert("/zzz") catch {}; // sin coincidencias
    syncAutocomplete(&m);
    try std.testing.expect(!m.ac.active);
}

test "input: el cursor se ancla en la posición real" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.ed.insert("abc") catch {};
    m.ed.moveHome();
    const s = try drawTest(&m, arena_state.allocator(), 40, 14);
    // Cursor al inicio de la línea: justo tras el prompt "❯ " (col 2).
    try std.testing.expectEqual(@as(u16, 2), s.cursor.?.col);
    try std.testing.expectEqual(@as(u16, 14 - 4), s.cursor.?.row);

    // Con el cursor al final, avanza 3 columnas (los 3 caracteres).
    m.ed.moveToEnd();
    const s2 = try drawTest(&m, arena_state.allocator(), 40, 14);
    try std.testing.expectEqual(@as(u16, 5), s2.cursor.?.col);
}

test "diff: pushDiff pinta líneas -/+ tras el resultado de la tool" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.pushToolStart("edit", "src/demo.txt");
    m.pushToolDone("edit", "Edited 3 lines", 2, "ok");
    m.pushDiff("uno\ndos\ntres\n", "uno\nDOS\ntres\ncuatro\n");

    // 24 filas: con la fila en blanco entre párrafos, el diff (5 líneas, cada
    // una en su propio párrafo) ya no cabe en 16 y la última se salía del
    // viewport. El test grows con el layout, no al revés.
    const s = try drawTest(&m, arena_state.allocator(), 50, 24);
    var buf: [256]u8 = undefined;
    // No se comprueban filas concretas: desde que los párrafos van separados
    // con una fila en blanco, la posición de cada bloque depende de cuantos
    // bloques haya. Se busca en toda la superficie.
    var all0: std.ArrayList(u8) = .empty;
    defer all0.deinit(std.testing.allocator);
    var rr: u16 = 0;
    while (rr < 24) : (rr += 1) {
        all0.appendSlice(std.testing.allocator, rowText(s, rr, &buf)) catch {};
        all0.append(std.testing.allocator, '\n') catch {};
    }
    try std.testing.expect(std.mem.indexOf(u8, all0.items, "edit(src/demo.txt)") != null);

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(std.testing.allocator);
    var row: u16 = 0;
    while (row < 24) : (row += 1) {
        for (rowText(s, row, &buf)) |c| joined.append(std.testing.allocator, c) catch {};
        joined.append(std.testing.allocator, '\n') catch {};
    }
    const all = joined.items;
    try std.testing.expect(std.mem.indexOf(u8, all, "-dos") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "+DOS") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "+cuatro") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, " uno") != null); // contexto
}

test "diff: sin cambios no añade párrafos" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.pushDiff("igual\n", "igual\n");
    const s = try drawTest(&m, arena_state.allocator(), 40, 12);
    var buf: [256]u8 = undefined;
    // Sin párrafos: la fila 0 es el separador/banner, no un diff.
    const row0 = rowText(s, 0, &buf);
    try std.testing.expect(std.mem.indexOf(u8, row0, "+") == null);
}

test "cabecera: el wordmark y los comandos van en el azul brillante" {
    // El brillo cae DENTRO del arte (`*zode*`), no en una línea entera: es lo
    // que hace que el ASCII art parezca un logo y no un bloque de texto.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const segs = try md.inlineSegments(arena, "  *zode*  \\:\\", .banner);
    try std.testing.expectEqual(@as(usize, 3), segs.len);
    try std.testing.expectEqualStrings("  ", segs[0].text);
    try std.testing.expectEqualStrings("zode", segs[1].text);
    try std.testing.expect(segs[1].style.bold); // el brillo
    try std.testing.expectEqualStrings("  \\:\\", segs[2].text);
}

test "cabecera: los asteriscos son marcas, no se pierden caracteres" {
    // Invariante del proyecto: concatenar los segmentos da el texto SIN las
    // marcas. Si se pierde o duplica un byte, el arte se descuadra.
    //
    // El caso se deriva del banner REAL (no de una cadena escrita a mano):
    // así el test sigue siendo válido si alguien edita el arte.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var checked: usize = 0;
    var it = std.mem.splitScalar(u8, mascot.banner, '\n');
    while (it.next()) |line| {
        try expectMarksAreOnlyMarks(arena, line, &checked);
    }
    // El banner ya no lleva tagline (el ASCII solo dice el nombre), pero el
    // mecanismo de marcas sigue en uso para la linea de Zo (`~…~`, el color va
    // con el mood) y lo que protege este test es el INVARIANTE: concatenar los
    // segmentos da el texto sin las marcas, byte a byte. Si se pierde o
    // duplica un byte, el arte se descuadra.
    try expectMarksAreOnlyMarks(arena, "~[ hola ]~  zo dice", &checked);
    try expectMarksAreOnlyMarks(arena, "*write*(hola.js)  · *3ms*", &checked);
    try std.testing.expect(checked >= 2);
}

/// Comprueba que los segmentos de `line` concatenados dan la línea SIN las
/// marcas `*…*` / `~…~`, e incrementa `checked` si la línea tenía marcas.
fn expectMarksAreOnlyMarks(arena: std.mem.Allocator, line: []const u8, checked: *usize) !void {
    const had_marks = std.mem.indexOfAny(u8, line, "*~") != null;
    if (had_marks) checked.* += 1;

    const segs = try md.inlineSegments(arena, line, .banner);
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(std.testing.allocator);
    for (segs) |sg| try joined.appendSlice(std.testing.allocator, sg.text);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(std.testing.allocator);
    for (line) |c| {
        if (c != '*' and c != '~') try expected.append(std.testing.allocator, c);
    }
    try std.testing.expectEqualStrings(expected.items, joined.items);
}

test "cabecera: un asterisco sin pareja no se come texto" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const segs = try md.inlineSegments(arena, "5 * 3 = 15", .banner);
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(std.testing.allocator);
    for (segs) |sg| try joined.appendSlice(std.testing.allocator, sg.text);
    try std.testing.expectEqualStrings("5 * 3 = 15", joined.items);
}

test "status: los segmentos son texto vivo y completo" {
    // Regresión: con `bufPrint` sobre un buffer de STACK, "(med)" y "ctx N%"
    // quedaban colgando (el slice se lee al pintar, ya fuera de la función) y
    // el status se cortaba a mitad con un caracter roto. Aquí se comprueba
    // que todo segmento es imprimible y que el effort cierra su parentesis.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const segs = sessionInfo(arena_state.allocator(), false) orelse return;

    for (segs) |sg| {
        try std.testing.expect(sg.text.len > 0);
        for (sg.text) |c| {
            try std.testing.expect(c == ' ' or c >= 0x21);
        }
    }
    var found = false;
    for (segs) |sg| {
        if (std.mem.indexOf(u8, sg.text, "(") != null) {
            found = true;
            try std.testing.expectEqual(@as(u8, ')'), sg.text[sg.text.len - 1]);
        }
    }
    try std.testing.expect(found);
}

test "status: la fila de status cabe y no se corta" {
    // El síntoma visible del puntero colgante era la fila cortada con un
    // caracter UTF-8 a medias en el borde derecho.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const w: u16 = 96;
    const s = try drawTest(&m, arena_state.allocator(), w, 16);
    var buf: [512]u8 = undefined;
    const row = rowText(s, 16 - 2, &buf); // status_row
    // Sin U+FFFD (el caracter de reemplazo sale cuando se parte un UTF-8).
    try std.testing.expect(std.mem.indexOf(u8, row, "\u{fffd}") == null);
    // Y la info de sesión está entera: el effort cierra con ")" al final.
    // (OJO: `rowText` devuelve BYTES, no columnas, así que no se puede
    // comparar con el ancho: un "·" son 2 bytes en una sola celda.)
    try std.testing.expect(std.mem.indexOf(u8, row, ")") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "opencode") != null);
}

test "status: ctxColor cambia en los umbrales de compaction" {
    // 80% es justo donde arranca la compaction (budget = 80% del límite).
    try std.testing.expectEqual(theme.ok.fg, theme.ctxColor(0).fg);
    try std.testing.expectEqual(theme.ok.fg, theme.ctxColor(49).fg);
    try std.testing.expectEqual(theme.warn.fg, theme.ctxColor(50).fg);
    try std.testing.expectEqual(theme.warn.fg, theme.ctxColor(79).fg);
    try std.testing.expectEqual(theme.err.fg, theme.ctxColor(80).fg);
    try std.testing.expectEqual(theme.err.fg, theme.ctxColor(100).fg);
}

test "cabecera: la línea de Zo lleva la carita en el color del mood" {
    // Un solo párrafo: carita + texto. Si se partiesen en dos, la carita
    // quedaba en una línea suelta arriba del mensaje.
    const segs = try md.inlineSegmentsBase(
        std.testing.allocator,
        "~[ x ]~  hola",
        .banner,
        null,
        .{ .fg = .{ .index = 6 } },
    );
    defer std.testing.allocator.free(segs);
    try std.testing.expectEqual(@as(usize, 2), segs.len);
    try std.testing.expectEqualStrings("[ x ]", segs[0].text);
    // `.fg` es una union: hay que comprobar la variante antes de mirar `.index`.
    try std.testing.expect(segs[0].style.fg == .index);
    try std.testing.expectEqual(@as(u8, 6), segs[0].style.fg.index);
    try std.testing.expectEqualStrings("  hola", segs[1].text);
}

test "cabecera: las marcas ~ no se comen texto" {
    // Igual que las `*`: si una marca se queda sin pareja, es texto normal.
    const segs = try md.inlineSegments(std.testing.allocator, "a ~ sin cerrar", .banner);
    defer std.testing.allocator.free(segs);
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(std.testing.allocator);
    for (segs) |sg| try joined.appendSlice(std.testing.allocator, sg.text);
    try std.testing.expectEqualStrings("a ~ sin cerrar", joined.items);
}

test "scrollBy: la rueda no desborda al bajar del todo" {
    // Regresión: la rueda hacía `self.scroll -= 3` sobre un `usize`, y con el
    // scroll en 0 eso desborda -> panic -> la app muere al bajar estando arriba.
    // Lo encontró un fuzzer de teclas reproduciendo `\x1b[<65;…M` dos veces.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.scrollBy(-3); // en 0: no puede quedarse negativo
    try std.testing.expectEqual(@as(usize, 0), m.scroll);
    m.scrollBy(-1);
    try std.testing.expectEqual(@as(usize, 0), m.scroll);

    m.scrollBy(7);
    try std.testing.expectEqual(@as(usize, 7), m.scroll);
    m.scrollBy(-3);
    try std.testing.expectEqual(@as(usize, 4), m.scroll);
    m.scrollBy(-100);
    try std.testing.expectEqual(@as(usize, 0), m.scroll);

    // Y subiendo tampoco se dispara el tope hasta reventar.
    m.scrollBy(100_000);
    m.scrollBy(100_000);
    try std.testing.expect(m.scroll <= 1_000_000);
}

test "cmdGroup-like: una key vacía no revienta" {
    // `key[1..]` sobre un []const u8 de len 0 es un panic en Zig 0.16, no un
    // slice vacío. El agrupado de la paleta lo llamaba con la key tal cual.
    const empty: []const u8 = "";
    try std.testing.expectEqual(@as(u8, 4), agent.cmdGroupPublic(empty));
    try std.testing.expectEqual(@as(u8, 2), agent.cmdGroupPublic("/help"));
    try std.testing.expectEqual(@as(u8, 3), agent.cmdGroupPublic("/model"));
    // El item de la cabecera de la paleta.
    try std.testing.expectEqual(@as(u8, 1), agent.cmdGroupPublic("connect"));
    // Sin barra inicial también funciona: `key[1..]` se come un carácter
    // cualquiera si no se comprueba, no solo la barra.
    try std.testing.expectEqual(@as(u8, 2), agent.cmdGroupPublic("help"));
    try std.testing.expectEqual(@as(u8, 4), agent.cmdGroupPublic("nope"));
}

test "autocompletado: /model manda /model y no completa a /models" {
    // Regresión: la coincidencia exacta se miraba SOLO contra el item
    // resaltado, y el popup ordenaba "/models" antes que "/model". Escribiendo
    // "/model" y pulsando Enter se acababa mandando "/models", que es otro
    // comando (lista los modelos en vez de abrir el selector).
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.ed.clear();
    m.ed.insert("/model") catch {};
    // SIN espacio final: con espacios el popup se cierra a proposito (ya no es
    // un comando en curso, son sus argumentos).
    syncAutocomplete(&m);
    try std.testing.expect(m.ac.active);

    // "/model" es un comando completo: se manda.
    try std.testing.expect(isExactMatch(&m));

    // Un prefijo parcial no lo es: hay que completar.
    m.ed.clear();
    m.ed.insert("/mod") catch {};
    syncAutocomplete(&m);
    try std.testing.expect(!isExactMatch(&m));

    // Y un texto que no es comando tampoco.
    m.ed.clear();
    m.ed.insert("/modl") catch {};
    syncAutocomplete(&m);
    try std.testing.expect(!isExactMatch(&m));
}

test "autocompletado: /help con Enter envía en vez de reescribir" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.ed.clear();
    m.ed.insert("/help") catch {};
    syncAutocomplete(&m);
    try std.testing.expect(m.ac.active);
    try std.testing.expect(isExactMatch(&m));
}

test "waitWorkers: espera a que los workers terminen" {
    // El contador es lo que impide que `io` se destruya con un worker dentro
    // de `io.async` (segfault en `Threaded.cancelThreads` al salir).
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 0), m.workers.load(.seq_cst));

    m.beginWorker();
    m.beginWorker();
    try std.testing.expectEqual(@as(usize, 2), m.workers.load(.seq_cst));

    m.endWorker();
    try std.testing.expectEqual(@as(usize, 1), m.workers.load(.seq_cst));
    m.endWorker();
    try std.testing.expectEqual(@as(usize, 0), m.workers.load(.seq_cst));

    // Sin workers esperando: vuelve enseguida.
    m.waitWorkers(10);
}

test "waitWorkers: con el tope de tiempo no se cuelga" {
    // Un worker atascado en red no puede dejar la app sin salir nunca.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.beginWorker(); // nunca se cierra a proposito
    m.waitWorkers(20); // debe volver en un tiempo razonable
    try std.testing.expectEqual(@as(usize, 1), m.workers.load(.seq_cst));
    m.endWorker();
}

test "cola: encola, saca en orden y libera" {
    // Sin cola, mandar un segundo prompt mientras el primero trabaja lanzaba
    // OTRO worker y los dos peleaban por la sesion y por el estado de
    // streaming: el input se freezeaba y no se sabia si estaba trabajando.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    const a = m.allocator.dupe(u8, "primero") catch unreachable;
    const b = m.allocator.dupe(u8, "segundo") catch unreachable;
    try std.testing.expectEqual(@as(usize, 1), m.enqueuePrompt(a));
    try std.testing.expectEqual(@as(usize, 2), m.enqueuePrompt(b));
    try std.testing.expectEqual(@as(usize, 2), m.queuedCount());

    // FIFO.
    const p1 = m.takeQueued().?;
    try std.testing.expectEqualStrings("primero", p1);
    m.allocator.free(p1);
    const p2 = m.takeQueued().?;
    try std.testing.expectEqualStrings("segundo", p2);
    m.allocator.free(p2);

    try std.testing.expectEqual(@as(usize, 0), m.queuedCount());
    try std.testing.expect(m.takeQueued() == null);
}

test "cola: clearQueue libera lo que quede" {
    // Si un texto se queda en la cola al salir y no se libera, es una fuga en
    // cada salida con prompts pendientes.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    const a = m.allocator.dupe(u8, "se queda") catch unreachable;
    _ = m.enqueuePrompt(a);
    m.clearQueue();
    try std.testing.expectEqual(@as(usize, 0), m.queuedCount());
}

test "franja de actividad: con trabajo y con cola" {
    // La franja es lo que responde a "¿está trabajando o se ha pegado?": la
    // carita, el estado y los segundos. Sin ella solo había un spinner diminuto.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.streamStart();
    const p1 = m.allocator.dupe(u8, "en cola") catch unreachable;
    _ = m.enqueuePrompt(p1);

    const s = try drawTest(&m, arena_state.allocator(), 90, 24);
    const all = allText(s);
    // Con un stream abierto la etiqueta es la FASE ("streaming"), no el
    // "working" genérico de antes: 40s de "working" no distinguen pensar de
    // escribir de un comando colgado.
    try std.testing.expect(std.mem.indexOf(u8, all, "streaming") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "1 queued") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "en cola") != null);
}

test "franja de actividad: la etiqueta es la fase" {
    // Las cuatro fases tienen que decir SU nombre. Es el cambio de feedback que
    // se pidió: con "working" en todo, un turno lento y un `bash` colgado se
    // vivían igual.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    // 1) pensando: hay trabajo pero no hay stream ni tool.
    {
        var m = Model.init(std.testing.allocator);
        defer m.deinit();
        m.setStatusWithMood(.thinking, "thinking");
        const s = try drawTest(&m, arena_state.allocator(), 90, 24);
        try std.testing.expect(std.mem.indexOf(u8, allText(s), "thinking") != null);
    }
    // 2) escribiendo: stream abierto.
    {
        var m = Model.init(std.testing.allocator);
        defer m.deinit();
        m.streamStart();
        const s = try drawTest(&m, arena_state.allocator(), 90, 24);
        try std.testing.expect(std.mem.indexOf(u8, allText(s), "streaming") != null);
    }
    // 3) corriendo una tool: el nombre de la tool, no "thinking".
    {
        var m = Model.init(std.testing.allocator);
        defer m.deinit();
        m.pushToolStart("bash", "sleep 9");
        const s = try drawTest(&m, arena_state.allocator(), 90, 24);
        const all = allText(s);
        try std.testing.expect(std.mem.indexOf(u8, all, "running") != null);
        try std.testing.expect(std.mem.indexOf(u8, all, "bash") != null);
    }
    // 4) esperando permiso: gana a todo lo demás.
    {
        var m = Model.init(std.testing.allocator);
        defer m.deinit();
        m.pushToolStart("write", "x.txt");
        m.perm_active = true;
        const s = try drawTest(&m, arena_state.allocator(), 90, 24);
        try std.testing.expect(std.mem.indexOf(u8, allText(s), "waiting for your permission") != null);
    }
}

test "franja de actividad: pide permiso cuando toca" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.streamStart();
    m.perm_active = true;
    const s = try drawTest(&m, arena_state.allocator(), 90, 24);
    const all = allText(s);
    try std.testing.expect(std.mem.indexOf(u8, all, "permission") != null);
    m.perm_active = false;
}

test "status: tokens y contexto siempre visibles" {
    // Antes el ctx% solo salia si era > 0, o sea tras un turno entero, y al
    // empezar no se veia nada: parecia que el contador no existia.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const segs = sessionInfo(arena_state.allocator(), false) orelse return;
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(std.testing.allocator);
    for (segs) |sg| try joined.appendSlice(std.testing.allocator, sg.text);
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "ctx ") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "opencode") != null);
}

/// Primera fila cuyo texto contenga `needle` (tests de render).
pub fn findRow(s: vxfw.Surface, needle: []const u8) ?u16 {
    var buf: [512]u8 = undefined;
    var row: u16 = 0;
    while (row < s.size.height) : (row += 1) {
        if (std.mem.indexOf(u8, rowText(s, row, &buf), needle) != null) return row;
    }
    return null;
}

/// ¿Hay alguna fila sin texto entre dos fragmentos? (test de separación)
fn hasBlankRowBetween(s: vxfw.Surface, first: []const u8, second: []const u8) bool {
    var buf: [256]u8 = undefined;
    var r_first: ?u16 = null;
    var r_second: ?u16 = null;
    var row: u16 = 0;
    while (row < s.size.height) : (row += 1) {
        const r = rowText(s, row, &buf);
        if (r_first == null and std.mem.indexOf(u8, r, first) != null) r_first = row;
        if (r_second == null and std.mem.indexOf(u8, r, second) != null) r_second = row;
    }
    const a = r_first orelse return false;
    const b = r_second orelse return false;
    if (b <= a + 1) return false;
    var mid: u16 = a + 1;
    while (mid < b) : (mid += 1) {
        const r = std.mem.trim(u8, rowText(s, mid, &buf), " ");
        if (r.len == 0) return true;
    }
    return false;
}

test "historial: los párrafos van separados con una fila en blanco" {
    // Sin esto el historial es un muro de texto y no se ve dónde acaba una
    // respuesta y empieza otra.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.pushKind(.user, "primera");
    m.pushKind(.assistant, "segunda");
    const s = try drawTest(&m, arena_state.allocator(), 60, 20);
    const all = allText(s);
    try std.testing.expect(std.mem.indexOf(u8, all, "primera") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "segunda") != null);
    // La fila entre ambas sale VACIA (solo espacios: `rowText` rellena la
    // superficie entera). Se comprueba que hay una fila sin texto entre las dos.
    try std.testing.expect(hasBlankRowBetween(s, "primera", "segunda"));
}

test "permisos: el modal es centrado y muestra las 4 opciones" {
    // Es lo que bloquea el turno: si no se ve, la app parece COLGADA. Antes eran
    // 4 líneas pegadas al input, medio tapadas por el historial.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.streamStart();
    m.perm_tool = undefined;
    @memcpy(m.perm_tool[0..5], "write");
    m.perm_tool_len = 5;
    @memcpy(m.perm_detail[0..7], "hola.js");
    m.perm_detail_len = 7;
    m.perm_active = true;

    const s = try drawTest(&m, arena_state.allocator(), 92, 26);
    const all = allText(s);
    try std.testing.expect(std.mem.indexOf(u8, all, "Permission required") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "write") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "hola.js") != null);
    // Las cuatro opciones, con su tecla.
    try std.testing.expect(std.mem.indexOf(u8, all, "Y allow once") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "A always allow") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "N deny") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "ESC cancel") != null);
    m.perm_active = false;
}

test "la carita del status va en el color de su mood, no en el gris del status" {
    // La queja era literal: "esto ni se nota por el color". La fila de status va
    // por SEGMENTOS justo para eso: la carita en el color del mood y el texto en
    // el azul apagado. Con una sola string todo salia del mismo gris.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.setStatusWithMood(.thinking, "thinking");
    m.streamStart();

    const s = try drawTest(&m, arena_state.allocator(), 92, 26);
    const status_row = s.size.height - 2;
    const face = mascot.faceFrames(.thinking, 0);

    // La carita son VARIOS graphemes repartidos en celdas distintas, asi que
    // se recorren con el mismo iterador que usa el painter: comparar la string
    // entera contra una celda NUNCA casa y el test pasaria por casualidad o
    // fallaria sin decir nada.
    var it = vaxis.unicode.graphemeIterator(face);
    var found: usize = 0;
    while (it.next()) |g| {
        const bytes = g.bytes(face);
        var col: u16 = 0;
        var hit = false;
        while (col < s.size.width) {
            const cell = s.readCell(col, status_row);
            if (std.mem.eql(u8, cell.char.grapheme, bytes)) {
                hit = true;
                break;
            }
            col += @max(1, cell.char.width);
        }
        try std.testing.expect(hit);
        const cell = s.readCell(col, status_row);
        try std.testing.expectEqual(mascot.Mood.thinking.vaxisColor(), cell.style.fg);
        try std.testing.expect(cell.style.bold);
        found += 1;
    }
    try std.testing.expect(found > 0);

    // Y el texto que la acompana NO lleva la carita dentro: antes se pintaba
    // dos veces (la de la franja y la del texto) y la del texto salia en gris.
    var rb: [256]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, rowText(s, status_row, &rb), "thinking") != null);
}

/// Las columnas de una línea del banner, sin las marcas `*…*`.
///
/// Se cuenta por COLUMNAS y no por bytes: cada `█` son 3 bytes, así que medir
/// con `piece.len` daba 101 para una fila de 41 columnas y el test pasaba sin
/// comprobar nada.
fn plainColumns(gpa: std.mem.Allocator, line: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lit = std.mem.tokenizeAny(u8, line, "*");
    while (lit.next()) |piece| {
        const view = std.unicode.Utf8View.initUnchecked(piece);
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            // En el art del banner todo es de ancho 1 (cajetín + espacio), así
            // que un codepoint es una columna.
            try out.append(gpa, if (cp == ' ') ' ' else '#');
        }
    }
    return out.toOwnedSlice(gpa);
}

test "el banner es SOLO el wordmark ZODE, sin filas en blanco entre lineas" {
    // ASCII art partido en parrafos metia una fila en blanco entre letras y el
    // logo se leia en trozos. La cabecera va sin separador.
    //
    // Y la cabecera es SOLO esto: ni mascota, ni "zo says: hi!", ni la linea de
    // atajos. Quejarse de "basura en la vista" es tener razon, y este test es el
    // que lo fija: si alguien vuelve a colgar una linea debajo del art, falla.
    //
    // El relleno es `#`, y eso choca con el markdown: una linea que empieza por
    // `##` es un ENCABEZADO y el parser se come los `#`. Hay dos tests para
    // esto: este (que el art llegue entero a la pantalla) y el de markdown de
    // abajo (que `.banner` no se interprete como prosa).
    //
    // Las filas se comparan COMPLETAS contra el arte escrito aqui a mano, no
    // contra `mascot.banner`: si el test comparase el banner consigo mismo,
    // pasaria con cualquier arte roto.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.pushHeader(.idle);

    const s = try drawTest(&m, arena_state.allocator(), 92, 26);
    const art = [_][]const u8{
        "######  ####  ####   ######",
        "##  ## ##  ## ##  ## ##",
        "   ##  ##  ## ##  ## ##",
        "  ##   ##  ## ##  ## ##",
        "######  ####  ####   ######",
    };
    var rb: [512]u8 = undefined;
    for (art, 0..) |want, i| {
        const got = rowText(s, @intCast(i), &rb);
        // Se recortan los dos: las filas de la `E` llevan relleno a la derecha.
        // El ancho exacto lo fija el bucle de invariantes de abajo.
        const got_t = std.mem.trimEnd(u8, got, " ");
        const want_t = std.mem.trimEnd(u8, want, " ");
        try std.testing.expectEqualStrings(want_t, got_t);
    }

    // Debajo del art NO hay nada. Ni una linea de mas.
    const after = rowText(s, mascot.banner_art_height, &rb);
    try std.testing.expectEqualStrings("", std.mem.trim(u8, after, " "));

    // Invariante del arte: TODAS las filas tienen que medir lo mismo, y todas
    // las letras empezar en las mismas columnas. Sin esto el logo se lee como
    // ruido (pasó: la `E` iba una columna antes y salía "diec FERE"). Se mide
    // quitando las marcas `*…*`.
    //
    // OJO: se mide en COLUMNAS, no en bytes. Un art con `█` (3 bytes por
    // caracter) daba 101 columnas en la fila 0 y el test pasaba sin comprobar
    // nada.
    var wit = std.mem.splitScalar(u8, mascot.banner, '\n');
    var rows: usize = 0;
    while (wit.next()) |line| {
        // El banner son `banner_art_height` filas, ni una más.
        try std.testing.expect(rows < mascot.banner_art_height);
        const cols = plainColumns(std.testing.allocator, line) catch unreachable;
        defer std.testing.allocator.free(cols);
        // TODAS las filas tienen que medir exactamente el ancho del art: el
        // relleno por la derecha es lo que hace que los trazos de las letras
        // alineen.
        try std.testing.expectEqual(mascot.banner_art_width, cols.len);
        rows += 1;
    }
    try std.testing.expectEqual(mascot.banner_art_height, rows);
}

/// Un `EventContext` de mentira para las teclas de la paleta.
///
/// `io` y `cmds` no se tocan en estos paths (el redraw lo marca el propio
/// handler), así que van sin inicializar. Si algún día `paletteKey` empieza a
/// usar el `Io`, esto revienta en el test en vez de dejar un `undefined` en
/// producción.
fn testCtx() vxfw.EventContext {
    return .{ .io = undefined, .alloc = std.testing.allocator, .cmds = .empty };
}

test "elegir un comando en la paleta lo EJECUTA (no lo manda al input)" {
    // Elegir un comando de una lista ya es la confirmación. Antes se cerraba la
    // paleta, se escribía la etiqueta en el input y hacía falta un Enter más:
    // un paso de más, y como el input quedaba a medias se leía como «no ha
    // hecho nada».
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    agent.openCommandPalette(&m);
    var ctx = testCtx();

    // Filtrar por "cache" deja solo /cache, y Enter lo dispara.
    for ([_]vaxis.Key{
        .{ .codepoint = 'c', .text = "c" },
        .{ .codepoint = 'a', .text = "a" },
        .{ .codepoint = 'c', .text = "c" },
        .{ .codepoint = 'h', .text = "h" },
        .{ .codepoint = 'e', .text = "e" },
    }) |k| {
        _ = try m.paletteKey(&ctx, k);
    }
    _ = try m.paletteKey(&ctx, .{ .codepoint = 13 }); // enter

    // La paleta se cierra y el input NO lleva el comando.
    try std.testing.expect(!m.pal.active);
    try std.testing.expectEqualStrings("", std.mem.trim(u8, m.ed.text(), " "));

    // Y el comando se ha ejecutado de verdad: `/cache` escribe su línea de
    // hit-rate en el historial.
    const s = try drawTest(&m, arena_state.allocator(), 92, 20);
    var found = false;
    for (0..s.size.height) |row| {
        var rb: [512]u8 = undefined;
        if (std.mem.indexOf(u8, rowText(s, @intCast(row), &rb), "hit-rate") != null) found = true;
    }
    try std.testing.expect(found);
}

test "/effort sin argumentos abre el picker (no contesta 'unknown effort')" {
    // `it.rest()` devuelve `""` (no `null`) para "/effort", y con un slice
    // vacío el `else` de "low|medium|high" se comía el caso: contestaba
    // "unknown effort:  (low|medium|high)" y el picker no se abría nunca.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    try agent.submit(&m, "/effort");
    try std.testing.expect(m.pickerActive());
}

test "un comando que necesita argumentos vuelve al input (no se ejecuta a ciegas)" {
    // `/use provider modelo` no se puede correr sin argumentos: ejecutarlo a
    // ciegas dejaría al agente en un provider cualquiera. Esos van al input con
    // la barra puesta, que es lo que quiere quien los elige.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    agent.openCommandPalette(&m);
    var ctx = testCtx();
    for ([_]vaxis.Key{
        .{ .codepoint = 'u', .text = "u" },
        .{ .codepoint = 's', .text = "s" },
        .{ .codepoint = 'e', .text = "e" },
    }) |k| {
        _ = try m.paletteKey(&ctx, k);
    }
    _ = try m.paletteKey(&ctx, .{ .codepoint = 13 });

    try std.testing.expect(!m.pal.active);
    try std.testing.expectEqualStrings("/use ", m.ed.text());
}

test "streamEnd vacía pending ANTES de fijar el párrafo (si no, el texto sale encima de la tool)" {
    // Regresión: `pushToolStart`/`pushToolDone` encolan en `pending`, y
    // `pending` se drena en el draw siguiente. `streamEnd` metía el párrafo del
    // asistente en `paras` sin vaciar `pending`, así que el texto acababa
    // DELANTE de la tool a la que pertenecía. Se nota en ACP, donde el agente
    // intercala texto y tools: "◆ Listo." salía encima de "⎿ exit=0".
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.pushToolStart("bash", "sleep 3");
    m.pushToolDone("bash", "exit=0", 3001, "");

    m.streamStart();
    m.streamDelta("antes");
    m.streamEnd();

    m.streamStart();
    m.streamDelta("despues");
    m.streamEnd();

    // Lo que se ve es el orden de `paras`.
    const kinds = [_]md.Kind{ .tool_run, .tool_res, .assistant, .assistant };
    try std.testing.expectEqual(kinds.len, m.paras.items.len);
    for (kinds, m.paras.items) |want, got| try std.testing.expectEqual(want, got.kind);
    try std.testing.expectEqualStrings("antes", m.paras.items[2].text);
    try std.testing.expectEqualStrings("despues", m.paras.items[3].text);
}

test "la cabecera de una tool marca el nombre para que el parser lo resalte" {
    // `*write*(hola.js)`: el nombre en el color fuerte de la tool y el
    // argumento en el apagado. Sin la marca salian del mismo cyan y no se
    // distinguian. Las marcas se quitan al pintar: la fila nunca las muestra.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.pushToolStart("write", "hola.js");

    const s = try drawTest(&m, arena_state.allocator(), 92, 26);
    const all = allText(s);
    try std.testing.expect(std.mem.indexOf(u8, all, "write(hola.js)") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, all, '*') == null);
}

test "una tool en curso pinta su reloj, y al terminar desaparece" {
    // Sin esto, un `bash` de 30s deja la última fila congelada en
    // `⏺ bash(...)`: no hay forma de saber si el proceso sigue vivo o si la app
    // se ha colgado. El reloj es lo único que contesta a "¿se ha pegado?".
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.pushToolStart("bash", "sleep 30");

    // Mientras corre: la línea de reloj tiene que estar.
    {
        const s = try drawTest(&m, arena_state.allocator(), 92, 26);
        const all = allText(s);
        try std.testing.expect(std.mem.indexOf(u8, all, "bash running") != null);
        // Y la franja de actividad nombra la tool, con la etiqueta de fase
        // "running" (no el "thinking" genérico: aquí lo que corre es un comando).
        try std.testing.expect(std.mem.indexOf(u8, all, "running") != null);
        try std.testing.expect(m.isBusy());
    }

    // Al terminar: la línea se va y deja su sitio al resultado.
    m.pushToolDone("bash", "ok", 30_000, "");
    try std.testing.expect(!m.isBusy());
    const s2 = try drawTest(&m, arena_state.allocator(), 92, 26);
    const all2 = allText(s2);
    try std.testing.expect(std.mem.indexOf(u8, all2, "bash running") == null);
    try std.testing.expect(std.mem.indexOf(u8, all2, "30000ms") != null);
}


// ── Fase 0 del ROADMAP: la red de seguridad que faltaba ──────────
//
// Estos tests fijan comportamientos cuya ausencia no producía un error visible
// sino una app COLGADA o CONGELADA. Ver ROADMAP.md, Fase 0 y Fase 1.

test "layout: 130 parrafos no cuelga el bucle del layout" {
    // El bucle `while (seg_cache.len < paras.len)` con `orderedRemove(0)` al
    // superar el tope no terminaba NUNCA con 129+ parrafos: append (129) ->
    // evict (128) -> volver a entrar, para siempre, creando un ArenaAllocator
    // por vuelta. Este test colgaba el binario de test entero, asi que ahora el
    // layout lleva un presupuesto de iteraciones (`layout_iters`) que avisa en
    // vez de colgarse.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    var i: usize = 0;
    while (i < 130) : (i += 1) m.pushInfo("parrafo");

    _ = try drawTest(&m, arena_state.allocator(), 80, 24);
    try std.testing.expect(!m.layout_overflow);
    try std.testing.expect(m.layout_iters <= Model.max_cached_paras);
    // La memoria de la cache sigue acotada: el argumento era el techo, no el
    // tiempo de parseo.
    try std.testing.expect(m.seg_cache.items.len <= Model.max_cached_paras);
}

test "layout: 200 y 1000 parrafos tampoco cuelgan" {
    // Los dos tamanos que aparecen en una sesion larga. Mismo contrato.
    inline for (.{ 200, 1000 }) |n| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        var m = Model.init(std.testing.allocator);
        defer m.deinit();

        var i: usize = 0;
        while (i < n) : (i += 1) m.pushInfo("p");

        _ = try drawTest(&m, arena_state.allocator(), 80, 24);
        try std.testing.expect(!m.layout_overflow);
        try std.testing.expect(m.seg_cache.items.len <= Model.max_cached_paras);
    }
}

test "layout: el scroll profundo re-parsea la ventana y el texto sigue saliendo" {
    // Lo que prometia el comentario viejo de `max_cached_paras` ("el scroll
    // profundo re-parsea on demand") y que no existia. Con la ventana
    // deslizante, al subir por encima de lo cacheado se parsea lo que entra en
    // pantalla.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        var buf: [32]u8 = undefined;
        m.streamStart();
        m.streamDelta(std.fmt.bufPrint(&buf, "marcador-{d}", .{i}) catch "x");
        m.streamEnd();
    }
    // Abajo del todo: se ve el final.
    {
        const s = try drawTest(&m, arena_state.allocator(), 60, 20);
        try std.testing.expect(std.mem.indexOf(u8, allText(s), "marcador-199") != null);
    }
    // Muy arriba: la ventana de arriba se re-parsea y sale texto.
    m.scrollBy(10_000);
    {
        const s = try drawTest(&m, arena_state.allocator(), 60, 20);
        const all = allText(s);
        try std.testing.expect(std.mem.indexOf(u8, all, "marcador-") != null);
        try std.testing.expect(!m.layout_overflow);
    }
    // Y al volver abajo se ve el final otra vez.
    m.scrollBy(-10_000);
    {
        const s = try drawTest(&m, arena_state.allocator(), 60, 20);
        try std.testing.expect(std.mem.indexOf(u8, allText(s), "marcador-199") != null);
    }
}

test "pushDiff mete UN parrafo, no uno por linea" {
    // `pushDiff` metia un PARRAFO por linea de diff: con 129+ lineas eso
    // reventaba el tope de la cache y colgaba la app al instante. Un solo
    // `write` de un fichero de 129 lineas era "se congela cuando entra a
    // escribir".
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.pushDiff("uno\ndos\ntres\n", "uno\nDOS\ntres\ncuatro\n");
    _ = try drawTest(&m, arena_state.allocator(), 60, 20);

    var diffs: usize = 0;
    for (m.paras.items) |p| {
        if (p.kind == .diff) diffs += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), diffs);
}

test "un diff de 300 lineas no cuelga y sigue siendo UN parrafo" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    var before: [8 * 1024]u8 = undefined;
    var after: [8 * 1024]u8 = undefined;
    var n_before: usize = 0;
    var n_after: usize = 0;
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        n_before += (std.fmt.bufPrint(before[n_before..], "linea {d}\n", .{i}) catch break).len;
    }
    i = 0;
    while (i < 300) : (i += 1) {
        n_after += (std.fmt.bufPrint(after[n_after..], "linea {d}!\n", .{i}) catch break).len;
    }

    m.pushDiff(before[0..n_before], after[0..n_after]);
    _ = try drawTest(&m, arena_state.allocator(), 80, 24);
    try std.testing.expect(!m.layout_overflow);

    var diffs: usize = 0;
    for (m.paras.items) |p| {
        if (p.kind == .diff) diffs += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), diffs);
}

test "streamEnd marca dirty: un cambio de estado pide un frame" {
    // `streamEnd` anade un parrafo al historial y pone `busy = false` SIN poner
    // `dirty = true`. Entre `streamEnd` y `pushToolStart` (con un write(2) de
    // sesion y un DEFLATE-9 en medio) hayia una ventana con `busy == false` y
    // `dirty == false`: un tick que caia ahi dejaba `App.timers` vacio y la
    // pantalla se quedaba muerta hasta que se pulsaba una tecla.
    var m = Model.init(std.testing.allocator);
    defer m.deinit();

    m.streamStart();
    m.streamDelta("hola");
    m.streamEnd();
    // El drain del draw pone dirty a false, pero el worker vuelve a encolar:
    // lo que tiene que valer es que CADA cambio de estado del worker lo ponga.
    m.pushToolStart("bash", "ls");
    try std.testing.expect(m.activity().dirty);
    m.drainPending();
    m.setStatusText("working");
    try std.testing.expect(m.activity().dirty);
    m.drainPending();
    m.setStatusWithMood(.warn, "esperando");
    try std.testing.expect(m.activity().dirty);
    m.drainPending();
    m.toolRunEnd();
    try std.testing.expect(m.activity().dirty);
}
