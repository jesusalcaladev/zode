const std = @import("std");

/// La lista de tareas que el modelo se escribe a sí mismo (`todo`) y que el
/// usuario ve EN PANTALLA.
///
/// ## Por qué una tool y no un bloc de texto
///
/// El modelo ya tenía `think` para planificar, y con eso la respuesta de un
/// agente de 20 tool calls es un muro de texto donde no se sabe qué falta. Lo
/// que se busca con esto es que en TODO MOMENTO se pueda responder a "¿cuánto
/// falta y en qué está?" leyendo una fila, sin Ask Mode.
///
/// ## Semántica: reemplazo completo, no parche
///
/// Cada llamada manda la lista ENTERA. Es lo que hace Claude Code con
/// `TodoWrite` y no es capricho: parchea distinto cada modelo y con una lista
/// parcial el servidor no puede saber qué se ha borrado. Con lista completa,
/// "quita el paso 3" es "manda 4 pasos sin el 3".
///
/// ## Por qué un array fijo
///
/// Vive en el `Model`, que la UI lee en cada frame y el worker escribe desde
/// otro hilo. Un `ArrayList` con lock ya obliga a tomar el lock para pintar;
/// un array de 20 entradas hace que el draw sea un bucle sin asignar. El techo
/// es 20 pasos: un plan más largo no es un plan, es un documento.
pub const max_items = 20;
pub const text_max = 120;

pub const Status = enum {
    pending,
    in_progress,
    done,

    pub fn parse(s: []const u8) ?Status {
        if (std.mem.eql(u8, s, "pending")) return .pending;
        if (std.mem.eql(u8, s, "in_progress") or std.mem.eql(u8, s, "in-progress")) return .in_progress;
        if (std.mem.eql(u8, s, "done") or std.mem.eql(u8, s, "completed")) return .done;
        return null;
    }

    pub fn glyph(self: Status) []const u8 {
        return switch (self) {
            .pending => "☐",
            .in_progress => "◐",
            .done => "☑",
        };
    }
};

pub const Item = struct {
    text: [text_max]u8 = undefined,
    len: u8 = 0,
    status: Status = .pending,

    pub fn textOf(self: *const Item) []const u8 {
        return self.text[0..self.len];
    }
};

/// La lista. Sin allocator: los textos son buffers de tamaño fijo.
pub const Plan = struct {
    items: [max_items]Item = undefined,
    len: u8 = 0,
    /// Lo que tenía antes de la última llamada. Para poder decir "2/4 → 3/4"
    /// y detectar que el modelo no ha cambiado nada.
    prev_done: u8 = 0,
    prev_len: u8 = 0,

    pub fn init() Plan {
        return .{};
    }

    pub fn isEmpty(self: *const Plan) bool {
        return self.len == 0;
    }

    pub fn doneCount(self: *const Plan) u8 {
        var n: u8 = 0;
        for (self.items[0..self.len]) |it| {
            if (it.status == .done) n += 1;
        }
        return n;
    }

    /// El paso en marcha, o el primero pendiente si ninguno lo ha marcado.
    ///
    /// Se usa para decidir cuál se resalta. Y tiene un criterio que no es
    /// obvious: si NO hay nada `in_progress` pero quedan pendientes, se resalta
    /// el primero pendiente. El modelo muchas veces no marca el paso en marcha
    /// (no le hace falta para él), y quedarse sin nada resaltado hace que el
    /// plan parezca muerto.
    pub fn currentIndex(self: *const Plan) ?u8 {
        for (self.items[0..self.len], 0..) |it, i| {
            if (it.status == .in_progress) return @intCast(i);
        }
        for (self.items[0..self.len], 0..) |it, i| {
            if (it.status == .pending) return @intCast(i);
        }
        return null;
    }

    pub fn allDone(self: *const Plan) bool {
        if (self.len == 0) return false;
        return self.doneCount() == self.len;
    }

    /// Vacía la lista. La usa `/new` y el reinicio de sesión: un plan de la
    /// sesión anterior no tiene nada que ver con esta.
    pub fn clear(self: *Plan) void {
        self.len = 0;
        self.prev_len = 0;
        self.prev_done = 0;
    }

    /// Aplica una lista nueva. Devuelve un código para el mensaje del historial:
    /// el llamante decide si dice algo (un "sin cambios" cada tool call es ruido).
    pub const Applied = enum { changed, same, empty };

    pub fn apply(self: *Plan, new_items: []const Item, n: u8) Applied {
        // La lista manda: se compara ANTES de tocar nada para poder decir "igual
        // que antes" sin historiales ni asignaciones.
        var same = n == self.len;
        if (same) {
            for (new_items[0..n], self.items[0..self.len]) |a, b| {
                if (a.status != b.status or !std.mem.eql(u8, a.textOf(), b.textOf())) {
                    same = false;
                    break;
                }
            }
        }
        // Una lista vacía sobre un plan vacío NO es un cambio (el modelo
        // repetiría "plan cleared" en cada llamada), pero vaciar un plan que
        // tenía cosas SÍ lo es: es la señal de que se acabó.
        if (n == 0 and self.len == 0) return .same;
        if (same) return .same;

        self.prev_len = self.len;
        self.prev_done = self.doneCount();
        // OJO: el índice es local a propósito. La primera versión escribía
        // `self.items[self.len] = it` dentro del bucle, y como `self.len` solo
        // se actualiza al final, TODAS las iteraciones caían en la casilla 0: al
        // final el plan era un solo paso repetido. Como `Item.text` es un buffer
        // de tamaño fijo, el plan se dibujaba con basura en vez de texto.
        var i: u8 = 0;
        while (i < n) : (i += 1) self.items[i] = new_items[i];
        self.len = n;
        return if (n == 0) .empty else .changed;
    }

    /// Una línea de resumen para el historial y para el status.
    ///
    /// `arena` porque es un `allocPrint`: el texto es de la duración del turno.
    pub fn summary(self: *const Plan, arena: std.mem.Allocator) []const u8 {
        if (self.len == 0) return "plan cleared";
        const d = self.doneCount();
        if (self.allDone()) {
            return std.fmt.allocPrint(arena, "plan: {d}/{d} done · all steps finished", .{ self.len, self.len }) catch "plan done";
        }
        return std.fmt.allocPrint(arena, "plan: {d}/{d} done · next: {s}", .{
            d,
            self.len,
            if (self.currentIndex()) |i| self.items[i].textOf() else "",
        }) catch "plan updated";
    }
};

/// Lo que devuelve el parseo: la lista y cuántos pasos hay.
pub const Result = struct {
    items: [max_items]Item,
    len: u8,
};

pub const ParseError = error{ BadPlan, TooManyItems };

/// Parsea la lista de `todo` desde el JSON.
///
/// El `arena` es solo para el árbol de `std.json` (los strings del resultado se
/// copian a los buffers fijos de `Item` antes de salir, y el parseo se
/// deserialize... no: `parseFromSliceLeaky` no necesita deserializar). Con un
/// buffer FIJO de 16 KB esto fallaría en un plan de 20 pasos con textos largos,
/// y el modelo vería "no me entendido el plan" sin motivo, así que el llamante
/// pasa un allocator de verdad.
pub fn parseItems(arena: std.mem.Allocator, args_json: []const u8, out: *[max_items]Item) ParseError!Result {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch
        return error.BadPlan;
    return fromValue(parsed, out);
}

/// Lo mismo, pero desde un JSON ya parseado.
///
/// Existe porque quien tiene el `ObjectMap` en la mano (la tool, que ya parseó
/// los args para el resto de tools) no debería volver a parsear 2 KB de JSON
/// para sacar 20 strings.
pub fn fromValue(value: std.json.Value, out: *[max_items]Item) ParseError!Result {
    if (value != .object) return error.BadPlan;
    const maybe = value.object.get("items") orelse value.object.get("todos") orelse
        return error.BadPlan;
    const arr = switch (maybe) {
        .array => |a| a,
        else => return error.BadPlan,
    };
    if (arr.items.len > max_items) return error.TooManyItems;

    var n: u8 = 0;
    for (arr.items) |v| {
        if (v != .object) return error.BadPlan;
        const cmaybe = v.object.get("content") orelse v.object.get("text") orelse
            v.object.get("task") orelse return error.BadPlan;
        const content = switch (cmaybe) {
            .string => |s| s,
            else => return error.BadPlan,
        };
        // Un status que no se conoce cae en `pending` en vez de fallar: el paso
        // no está mal, está mal etiquetado, y tirar el error obligaría a
        // repetir la llamada.
        const st: Status = if (v.object.get("status")) |sv| blk: {
            if (sv != .string) break :blk .pending;
            break :blk Status.parse(sv.string) orelse .pending;
        } else .pending;

        const trimmed = std.mem.trim(u8, content, " \t");
        if (trimmed.len == 0) return error.BadPlan;
        var it = Item{ .status = st };
        const cp = @min(trimmed.len, text_max);
        @memcpy(it.text[0..cp], trimmed[0..cp]);
        it.len = @intCast(cp);
        out[n] = it;
        n += 1;
    }
    return .{ .items = out.*, .len = n };
}

// ── tests ─────────────────────────────────────────────────────

test "Status.parse acepta lo que los modelos escriben de verdad" {
    // Los modelos no se inventan el vocabulario: escriben "in-progress" y
    // "completed" tan a menudo como "in_progress" y "done", y con guiones bajos
    // porque el JSON del tool se escribe a mano.
    try std.testing.expectEqual(Status.pending, Status.parse("pending").?);
    try std.testing.expectEqual(Status.in_progress, Status.parse("in_progress").?);
    try std.testing.expectEqual(Status.in_progress, Status.parse("in-progress").?);
    try std.testing.expectEqual(Status.done, Status.parse("done").?);
    try std.testing.expectEqual(Status.done, Status.parse("completed").?);
    // Y lo que no se sabe: null, no un panic y no un pending silencioso.
    try std.testing.expect(Status.parse("en curso") == null);
    try std.testing.expect(Status.parse("") == null);
}

test "parseItems: la forma que manda el modelo" {
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    var out: [max_items]Item = undefined;

    const args =
        \\{"items":[
        \\ {"content":"leer el roadmap","status":"done"},
        \\ {"content":"implementar la tool","status":"in_progress"},
        \\ {"content":"escribir el test","status":"pending"}
        \\]}
    ;
    const r = try parseItems(arena, args, &out);
    try std.testing.expectEqual(@as(u8, 3), r.len);
    try std.testing.expectEqualStrings("leer el roadmap", r.items[0].textOf());
    try std.testing.expectEqual(Status.done, r.items[0].status);
    try std.testing.expectEqual(Status.in_progress, r.items[1].status);
    try std.testing.expectEqualStrings("escribir el test", r.items[2].textOf());
}

test "parseItems: acepta `todos`, `text` y `task` como alias" {
    // Variación REAL entre modelos: el mismo nombre de campo cambiado por el
    // mismo modelo entre dos llamadas. Si solo se acepta una, el plan se vacía
    // sin que nadie entienda por qué.
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    var out: [max_items]Item = undefined;

    const a = try parseItems(arena, "{\"todos\":[{\"text\":\"a\"}]}", &out);
    try std.testing.expectEqual(@as(u8, 1), a.len);
    try std.testing.expectEqualStrings("a", a.items[0].textOf());

    const b = try parseItems(arena, "{\"items\":[{\"task\":\"b\"}]}", &out);
    try std.testing.expectEqualStrings("b", b.items[0].textOf());
}

test "parseItems: un status que no se conoce cae en pending, no en error" {
    // El caso raro pero real: el modelo escribe "doing" o "finished". Tirar
    // el error obligaría a repetir la llamada, y el paso no está mal: está mal
    // etiquetado. Se acepta como pendiente y el modelo ve la lista correcta.
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    var out: [max_items]Item = undefined;
    const r = try parseItems(
        astate.allocator(),
        "{\"items\":[{\"content\":\"x\",\"status\":\"finished\"}]}",
        &out,
    );
    try std.testing.expectEqual(Status.pending, r.items[0].status);
}

test "parseItems: lo que esta MAL se rechaza con un motivo" {
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const a = astate.allocator();
    var out: [max_items]Item = undefined;

    // OJO: `expectError` NO sirve aquí. Imprime el valor devuelto cuando el
    // resultado NO es el error esperado, y ese valor es un array de `Item` con
    // buffers `undefined`: el formateo del enum peta con "invalid enum value" y
    // el test revienta con un panic en vez de fallar con un mensaje. Por eso
    // `wantPlanErr`, que solo mira el error.
    try wantPlanErr(a, "no json", &out, error.BadPlan);
    try wantPlanErr(a, "[]", &out, error.BadPlan);
    try wantPlanErr(a, "{}", &out, error.BadPlan);
    try wantPlanErr(a, "{\"items\":\"uno\"}", &out, error.BadPlan);
    // Un paso sin texto: un checkbox con nada al lado no es un paso.
    try wantPlanErr(a, "{\"items\":[{\"content\":\"   \"}]}", &out, error.BadPlan);
    // Y más de 20 es un error, no un recorte silencioso: si el modelo se pasa,
    // tiene que saber que no cabe todo. Silencioso sería peor, porque el plan
    // parecería corto sin motivo y el modelo no sabría qué se perdió.
    var many: [2048]u8 = undefined;
    try wantPlanErr(a, manyItems(21, &many), &out, error.TooManyItems);
    // Justo 20 entra y entra entero.
    const r = try parseItems(a, manyItems(20, &many), &out);
    try std.testing.expectEqual(@as(u8, 20), r.len);
    try std.testing.expectEqualStrings("paso 20", r.items[19].textOf());
}

test "Plan.apply: lista completa, y saber si ha cambiado algo" {
    var p = Plan.init();
    var new: [max_items]Item = undefined;
    // Una lista vacía sobre un plan vacío no es un cambio: si lo fuera, cada
    // llamada con la lista vacía repetiría "plan cleared" en el historial.
    try std.testing.expectEqual(Plan.Applied.same, p.apply(&new, 0));
    try std.testing.expect(p.isEmpty());

    const a = try two("leer", "escribir", .pending, .in_progress);
    try std.testing.expectEqual(Plan.Applied.changed, p.apply(&a, 2));
    try std.testing.expectEqual(@as(u8, 2), p.len);
    try std.testing.expectEqual(@as(u8, 0), p.doneCount());

    // Repetir la MISMA lista no es un cambio: si lo fuera, cada tool call
    // repetiría "plan: 0/2" en el historial y el mensaje perdería sentido.
    try std.testing.expectEqual(Plan.Applied.same, p.apply(&a, 2));

    // Cambiar un estado SÍ lo es, aunque el texto no cambie.
    const b = try two("leer", "escribir", .done, .in_progress);
    try std.testing.expectEqual(Plan.Applied.changed, p.apply(&b, 2));
    try std.testing.expectEqual(@as(u8, 1), p.doneCount());
    // Lo que había ANTES del cambio, que es lo que permite decir "1/2 -> 2/2" en
    // el historial en vez de solo "2/2".
    try std.testing.expectEqual(@as(u8, 2), p.prev_len);
    try std.testing.expectEqual(@as(u8, 0), p.prev_done);

    // Vaciar un plan que tenía cosas SÍ es cambio: es la señal de "se acabó".
    try std.testing.expectEqual(Plan.Applied.empty, p.apply(&new, 0));
    try std.testing.expect(p.isEmpty());
    try std.testing.expect(!p.allDone()); // un plan vacío no está "hecho"
}

test "Plan.currentIndex: el paso en marcha, o el primero pendiente" {
    var p = Plan.init();
    // Vacío: no hay nada que resaltar.
    try std.testing.expect(p.currentIndex() == null);

    const a = try three("a", "b", "c", .done, .pending, .pending);
    try std.testing.expectEqual(Plan.Applied.changed, p.apply(&a, 3));
    // El modelo no ha marcado ninguno: se resalta el primer pendiente, porque
    // un plan sin nada resaltado parece un plan parado.
    try std.testing.expectEqual(@as(u8, 1), p.currentIndex().?);

    const b = try three("a", "b", "c", .done, .pending, .in_progress);
    try std.testing.expectEqual(Plan.Applied.changed, p.apply(&b, 3));
    // Ahora sí hay uno en marcha, y gana.
    try std.testing.expectEqual(@as(u8, 2), p.currentIndex().?);

    const c = try three("a", "b", "c", .done, .done, .done);
    try std.testing.expectEqual(Plan.Applied.changed, p.apply(&c, 3));
    // Todo hecho: no hay paso actual (el resumen dice "all steps finished").
    try std.testing.expect(p.currentIndex() == null);
}

test "el texto largo se corta sin desbordar el buffer" {
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    var out: [max_items]Item = undefined;
    var args: [text_max * 2]u8 = undefined;
    var w: std.Io.Writer = .fixed(&args);
    try w.print("{{\"items\":[{{\"content\":\"", .{});
    for (0..text_max * 2 - 32) |_| try w.writeByte('x');
    try w.print("\"}}]}}", .{});

    const r = try parseItems(astate.allocator(), w.buffered(), &out);
    try std.testing.expectEqual(@as(u8, 1), r.len);
    // Cortado a `text_max`: en el plan se lee "leerse esto entero en una fila"
    // como una sola linea, y el texto largo esta en el historial del turno.
    try std.testing.expectEqual(@as(u8, text_max), r.items[0].len);
}

test "el resumen dice lo que falta, no el porcentaje" {
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    var p = Plan.init();

    const a = try three("leer el roadmap", "implementar", "testear", .done, .in_progress, .pending);
    _ = p.apply(&a, 3);
    const s = p.summary(arena);
    try std.testing.expect(std.mem.indexOf(u8, s, "1/3") != null);
    // El nombre del paso que sigue: es lo que convierte el plan en algo
    // accionable de un vistazo.
    try std.testing.expect(std.mem.indexOf(u8, s, "implementar") != null);

    const b = try three("leer el roadmap", "implementar", "testear", .done, .done, .done);
    _ = p.apply(&b, 3);
    try std.testing.expect(std.mem.indexOf(u8, p.summary(arena), "all steps finished") != null);

    p.clear();
    try std.testing.expectEqualStrings("plan cleared", p.summary(arena));
}

// ── helpers de los tests ──────────────────────────────────────

/// Como `expectError` pero sin imprimir el valor de acierto (que aquí es un
/// array con buffers sin inicializar y revienta el formateo del enum).
fn wantPlanErr(
    arena: std.mem.Allocator,
    json: []const u8,
    out: *[max_items]Item,
    want: ParseError,
) !void {
    if (parseItems(arena, json, out)) |_| {
        std.debug.print("se esperaba {t} y el plan se acepto\n", .{want});
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expectEqual(want, err);
    }
}

fn item(text: []const u8, status: Status) Item {
    var it = Item{ .status = status };
    const cp = @min(text.len, text_max);
    @memcpy(it.text[0..cp], text[0..cp]);
    it.len = @intCast(cp);
    return it;
}

fn two(a: []const u8, b: []const u8, sa: Status, sb: Status) ![max_items]Item {
    var arr: [max_items]Item = undefined;
    arr[0] = item(a, sa);
    arr[1] = item(b, sb);
    return arr;
}

fn three(
    a: []const u8,
    b: []const u8,
    c: []const u8,
    sa: Status,
    sb: Status,
    sc: Status,
) ![max_items]Item {
    var arr: [max_items]Item = undefined;
    arr[0] = item(a, sa);
    arr[1] = item(b, sb);
    arr[2] = item(c, sc);
    return arr;
}

fn manyItems(n: usize, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print("{{\"items\":[", .{}) catch return "";
    for (0..n) |i| {
        w.print("{s}{{\"content\":\"paso {d}\"}}", .{ if (i > 0) "," else "", i + 1 }) catch return "";
    }
    w.print("]}}", .{}) catch return "";
    return w.buffered();
}
