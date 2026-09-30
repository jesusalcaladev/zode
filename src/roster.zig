const std = @import("std");
const models = @import("models.zig");
const providers = @import("providers.zig");
const config_mod = @import("config.zig");
const http_client = @import("http_client.zig");

/// El pool de modelos gratis de TODOS los providers con key, y la rueda que
/// reparte turnos entre ellos.
///
/// ## Qué resuelve
///
/// Con un solo provider, cuando se le acaba la cuota (402) o el gate lo rechaza
/// (403 "can only be used from within OpenCode"), el turno se muere y el
/// usuario tiene que escribir "continúa" con otro modelo. Aquí, en vez de eso,
/// el turno sigue solo: se marca el par provider/modelo como muerto un rato y se
/// reintenta la misma petición con el siguiente candidato.
///
/// ## Por qué NO se espera a la rotación
///
/// `build` habla con N providers, y eso son N peticiones (cientos de ms cada
/// una). Si se hiciera en el primer fallo, el usuario vería "se queda
/// pensando" justo cuando necesita que pase algo. Se construye en un worker al
/// arrancar, y si no está listo el turno sigue con el modelo actual: la rotación
/// espera al siguiente turno, nunca bloquea.
///
/// ## Lo que NO hace
///
/// - No adivina providers: solo los que `providers.keyFor` devuelve key, que son
///   los que el usuario ha conectado de verdad.
/// - No persiste entre procesos (todavía). El pool se rehace al arrancar, que
///   son N peticiones en background.
/// - No toca `cur_provider_id`/`cur_model`: el modo es una capa encima, y
///   `/use` y `/model` siguen mandando sobre lo que hay activo.

/// Tope de rotaciones por turno. Tres: más que eso y casi seguro es un problema
/// de configuracion (todos los free caidos), no de cuota, y a partir de ahí lo
/// que se hace es dar vueltas y tarayar al usuario.
pub const max_rotations_per_turn = 3;
/// Tope por tarea (prompt). Diez: cubre una sesión larga con varios proveedores
/// muriendo, y corta antes de que el turno parezca colgado.
pub const max_rotations_per_task = 10;

/// Cuánto está muerto un par antes de volver a intentarlo.
///
/// Diez minutos. Un rate limit de openrouter/sonido dura segundos o minutos; una
/// cuota diaria (deepseek) dura horas, y para esa el mensaje al usuario es otro
/// (más "quota" que "rate limit"), no un reintento automático.
pub const cooldown_ms: i128 = 10 * 60 * 1000;

/// Cuánto está fuera de juego un par según POR QUÉ murió.
///
/// Un solo tope para todo era un error: un 429 de openrouter y un 503 pasajero
/// no son lo mismo, y 10 minutos de castigo por un blip de un segundo quitan un
/// modelo bueno del pool cuando el usuario más lo necesita. La cuota (402/429) sí
/// dura: es lo que tarda en volver.
pub const failed_cooldown_ms: i128 = 60 * 1000;

/// Tope de candidatos. Con 5 providers y 3 free cada uno son 15; el tope es para
/// que un provider que devuelva el catálogo entero (openrouter tiene ~460
/// modelos) no infle el array fijo.
pub const max_candidates = 24;

/// Cuántos free se quedan de CADA provider.
///
/// Existe por un motivo que la sonda enseñó: openrouter publica 20 free y
/// opencode 8, y con un tope SOLO global el primero que se lista se come el
/// pool entero. O sea, que el provider con más modelos (el más útil) era el
/// que peor salía. Con este tope cada uno aporta sus mejores y la suma decide
/// quién entra.
pub const per_provider_max = 8;

/// Un par provider/modelo que se puede usar.
pub const Candidate = struct {
    /// Copias propias en el arena del roster (nunca un slice del worker que
    /// construyó la lista de modelos: ese arena muere al salir).
    provider_id: []const u8,
    model_id: []const u8,
    /// Ventana de contexto publicada, 0 = desconocida.
    ctx: u32 = 0,
    /// Baraja estable: menor = preferido. Ver `rankFor`.
    rank: u8 = 0,
    /// El provider es opencode, cuyos `-free` dan 403 fuera del cliente oficial.
    /// Se quedan los ultimos: hay que probarlos alguna vez, pero no son un
    /// plan de Contingencia.
    gated_opencode: bool = false,
    /// Ya ha completado un turno con tools en esta sesion: sube de prioridad.
    worked: bool = false,
    /// Veces que se quedo a medias (subio 2 veces sin cerrar el turno).
    stalls: u8 = 0,
};

/// Un par que no esta disponible ahora mismo, y por que.
/// Longitud del motivo. Con los 4 KB que devuelve a veces un body de error, el
/// texto se recorta: lo que se guarda es "qué pasó", no la respuesta entera.
pub const reason_len_max = 96;

pub const Dead = struct {
    idx: u16 = 0,
    until_ms: i128 = 0,
    reason: [reason_len_max]u8 = undefined,
    reason_len: u8 = 0,

    pub fn reasonStr(self: *const Dead) []const u8 {
        return self.reason[0..self.reason_len];
    }

    pub fn expired(self: *const Dead, now_ms: i128) bool {
        return now_ms >= self.until_ms;
    }
};

/// Por que se murió un par, en una frase que el usuario pueda usar.
pub const Why = enum {
    /// 402: sin créditos. No vuelve solo.
    no_credits,
    /// 429: rate limit. Vuelve solo en un rato.
    rate_limited,
    /// 403 con el texto del gate de opencode: no es la key ni el config.
    gated,
    /// 403/404 sin más historia: casi siempre es un id malo o una config.
    misconfigured,
    /// Se quedó a medias dos veces.
    stalled,
    /// Se agotaron los reintentos con este par (3 intentos con backoff) sin que
    /// el error fuera de cuota. Verá: un 5xx o un body raro NO es motivo para
    /// rotar en el momento (el modelo no tiene la culpa y puede ser un blip), pero
    /// si el turno se muere con él, el SIGUIENTE turno tiene que empezar en otro
    /// sitio o el usuario se queda atascado en el mismo modelo para siempre.
    failed,

    pub fn label(self: Why) []const u8 {
        return switch (self) {
            .no_credits => "no credits",
            .rate_limited => "rate limited",
            .gated => "gated to the official client",
            .misconfigured => "not available on this account",
            .stalled => "stalled twice",
            .failed => "failed 3 times",
        };
    }
};

pub const Roster = struct {
    /// Arena propia: los strings de los candidatos son copias suyas, y el roster
    /// sobrevive a los workers que lo construyeron.
    arena: std.mem.Allocator = undefined,
    inited: bool = false,
    /// El worker terminó de construirlo (o/video terminó de intentarlo).
    built: bool = false,
    /// Hubo key pero ningún modelo free (o no hubo key). Es un estado LÍCITO.
    empty_reason: []const u8 = "",

    items: [max_candidates]Candidate = undefined,
    len: u8 = 0,
    /// Índice del candidato activo. Apunta al vivo, no al bruto.
    idx: u8 = 0,
    /// Posición real en `items` del activo, para poder marcarlo muerto.
    cur_raw: u8 = 0,

    dead: [max_candidates]Dead = undefined,
    dead_len: u8 = 0,

    rotations_turn: u8 = 0,
    rotations_task: u8 = 0,

    /// Por que fallo el ultimo provider que se listo (para diagnostics).
    last_error: ?anyerror = null,

    pub fn init(gpa: std.mem.Allocator) Roster {
        return .{ .arena = gpa, .inited = true };
    }

    pub fn total(self: *const Roster) u8 {
        return self.len;
    }

    pub fn isEmpty(self: *const Roster) bool {
        return self.len == 0;
    }

    /// Construye el pool: por cada provider con key, sus modelos free.
///
/// Falla el conjunto (no el turno): si un provider da 403 o no tiene key, se
/// salta y se sigue con los demás. Un solo provider que responde 200 pero sin
/// modelos free NO es un error.
    pub fn build(
        self: *Roster,
        io: std.Io,
        env: ?*const std.process.Environ.Map,
        defs: []const providers.ProviderDef,
    ) !void {
        self.len = 0;
        self.dead_len = 0;
        self.built = true;
        self.last_error = null;
        self.empty_reason = "";

        if (defs.len == 0) {
            self.empty_reason = "no providers configured";
            return;
        }

        var http = http_client.Http.init(self.arena, io);
        defer http.deinit();

        var found_any_key = false;
        for (defs) |def| {
            // Inicio del tramo que aporta este provider, para poder recortar SUS
            // candidatos sin tocar los de los anteriores.
            const start: u8 = self.len;
            // Sin key no se pregunta: un 401 aquí solo genera ruido.
            if (providers.keyFor(&def, env) == null) continue;
            found_any_key = true;
            if (self.len >= max_candidates) break;

            // `var` y no `const`: `deinit` necesita un puntero no-const para
            // liberar la lista (Zig no deja pasar un `*const` a un `*`).
            var list = models.listModels(self.arena, &http, def.models_url, providers.keyFor(&def, env)) catch {
                // Un provider caído no tumba el pool: se sigue con el resto.
                self.last_error = error.ProviderListFailed;
                continue;
            };
            defer list.deinit(self.arena);

            for (list.items) |mo| {
                if (!mo.is_free) continue;
                if (self.len >= max_candidates) break;
                self.items[self.len] = .{
                    .provider_id = self.arena.dupe(u8, def.id) catch continue,
                    .model_id = self.arena.dupe(u8, mo.id) catch continue,
                    .ctx = mo.context_length,
                    .gated_opencode = std.mem.eql(u8, def.id, "opencode"),
                };
                self.len += 1;
            }

            trimProvider(self, start);
        }

        if (!found_any_key) {
            self.empty_reason = "no provider has an API key (ctrl+a to connect one)";
            return;
        }
        if (self.len == 0) {
            self.empty_reason = "no free models published by any provider with a key";
            return;
        }

        self.sort();
        self.idx = 0;
        self.cur_raw = 0;
    }

    /// Orden estable y con criterio. Importa: no todos los free saben usar tools
    /// multi-paso, y caer en uno malo produce ediciones basura.
    ///
    /// 1. Los que ya han funcionado (`worked`): lo que se sabe, vale.
    /// 2. Los que no están gateados a opencode (su 403 es conocido y no lo
    ///    arregla nada: probar el último es perder un intento).
    /// 3. Contexto más grande primero: menos probabilidad de compactar a mitad
    ///    de un turno, que es donde duele.
    /// 4. Alfabético como desempate, para que la lista sea la misma en cada
    ///    arranque y los tests puedan fijarla.
    fn sort(self: *Roster) void {
        const items = self.items[0..self.len];
        std.mem.sort(Candidate, items, {}, less);
    }

    /// Recorta a `per_provider_max` los candidatos que aporta ESTE provider (el
    /// tramo `start..self.len`), quedándose con los de contexto más grande.
    ///
    /// Va fuera de `build` a propósito: `build` habla con la red y no se puede
    /// testear, y el recorte es justo la parte donde el fallo se esconde. Así lo
    /// comprueba un test sin salir a la red (el fallo lo encontró la sonda
    /// `zig build roster-probe`: con el tope solo global, openrouter se comía el
    /// pool y de los 20 free solo entraban 16 en cualquier orden).
    fn trimProvider(self: *Roster, start: u8) void {
        const added = self.len - start;
        if (added <= per_provider_max) return;
        // Ordenar ANTES de tirar el resto (y no al revés) es lo que deja en el
        // pool los mejores. Recortar primero se quedaría con los 8 primeros que
        // publicó el provider, que pueden ser los peores.
        std.mem.sort(Candidate, self.items[start..self.len], {}, byCtxThenName);
        self.len = start + per_provider_max;
    }

    /// Contexto grande primero, y alfabético como desempate. Se usa para
    /// recortar los candidatos de UN provider antes de meterlos en el pool.
    ///
    /// No reutiliza `less` a propósito: aquí todos los candidatos son del mismo
    /// provider, así que ni `worked` ni `gated_opencode` los distinguen, y
    /// ordenar por el comparador global mezclaría tramos.
    fn byCtxThenName(_: void, a: Candidate, b: Candidate) bool {
        if (a.ctx != b.ctx) return a.ctx > b.ctx;
        return std.mem.lessThan(u8, a.model_id, b.model_id);
    }

    /// Orden total en UN solo comparador.
    ///
    /// OJO: NO son cuatro `std.mem.sort` seguidos por clave. `std.mem.sort` es un
    /// block sort INESTABLE, así que en una cadena de sorts solo sobrevive el
    /// último: el orden final habría sido solo el alfabético, y los tres
    /// criterios escritos antes se habrían perdido sin avisar. Un comparador
    /// único con desempate alfabético es un orden total y no tiene ese problema.
    fn less(_: void, a: Candidate, b: Candidate) bool {
        // `return a.worked` y no `!a.worked`: los que YA han funcionado van
        // primero. (La primera versión tenía el signo invertido y el test de
        // orden lo cazó: un `!` de más y el pool empezaba por el peor modelo.)
        if (a.worked != b.worked) return a.worked;
        // Los gateados a opencode al final: su 403 es conocido y no lo arregla
        // nada, así que son el último recurso, no el primero.
        if (a.gated_opencode != b.gated_opencode) return !a.gated_opencode;
        // Contexto grande primero: menos compactación a mitad de turno.
        if (a.ctx != b.ctx) return a.ctx > b.ctx;
        if (!std.mem.eql(u8, a.provider_id, b.provider_id)) {
            return std.mem.lessThan(u8, a.provider_id, b.provider_id);
        }
        return std.mem.lessThan(u8, a.model_id, b.model_id);
    }

    /// El candidato activo (sin mirar cooldowns: el que se está usando ahora
    /// mismo, aunque esté a punto de morir). Null si el pool está vacío.
    pub fn currentCandidate(self: *const Roster) ?Candidate {
        if (self.len == 0 or self.cur_raw >= self.len) return null;
        return self.items[self.cur_raw];
    }

    /// El candidato activo, o null si no queda ninguno vivo.
    ///
    /// Avanza solo sobre los que NO están en cooldown: `active()` no muta el
    /// índice, solo lo lee y lo normaliza. (Si todos están muertos, deja el
    /// índice donde estaba y devuelve null: el llamante avisa.)
    pub fn active(self: *const Roster, now_ms: i128) ?Candidate {
        if (self.len == 0) return null;
        var i: u8 = self.idx;
        var tries: u8 = 0;
        while (tries < max_rotations_per_turn) : (tries += 1) {
            if (!self.isDead(i, now_ms)) return self.items[i];
            i = @intCast((i + 1) % self.len);
        }
        return null;
    }

    /// El siguiente vivo DESPUÉS del actual, o null si no queda ninguno.
    ///
    /// Es lo que llama el fallo de cuota: no rota hasta que se le llama, para que
    /// un turno que va bien no consuma rotaciones.
    pub fn nextLive(self: *Roster, now_ms: i128) ?u8 {
        if (self.len == 0) return null;
        var i: u8 = @intCast((self.cur_raw + 1) % self.len);
        var tries: u8 = 0;
        while (tries < max_rotations_per_turn) : (tries += 1) {
            if (!self.isDead(i, now_ms)) {
                self.idx = i;
                self.cur_raw = i;
                return i;
            }
            i = @intCast((i + 1) % self.len);
        }
        return null;
    }

    /// Marca el candidato actual como muerto y salta al siguiente vivo.
    ///
    /// Devuelve el índice del nuevo activo, o null si no queda ninguno (que es
    /// la señal de que hay que rendirse y explicar por qué, no seguir
    /// probando).
    pub fn rotate(self: *Roster, now_ms: i128, why: Why, detail: []const u8) ?u8 {
        self.noteDead(self.cur_raw, now_ms, why, detail);
        return self.nextLive(now_ms);
    }

    pub fn noteDead(self: *Roster, idx: u8, now_ms: i128, why: Why, detail: []const u8) void {
        if (idx >= self.len) return;
        if (self.dead_len >= self.dead.len) return;

        // OJO: el texto se compone en un buffer LOCAL y luego se copia a
        // `d.reason`. Escribir en `d.reason` mientras se lee de un slice de
        // `d.reason` es aliasing, y con un detalle largo revienta en mitad del
        // bufPrint (que es justo lo que hace un body de error de 4 KB).
        var tmp: [reason_len_max]u8 = undefined;
        const text = if (detail.len == 0)
            std.fmt.bufPrint(&tmp, "{s}", .{why.label()}) catch why.label()
        else
            std.fmt.bufPrint(&tmp, "{s}: {s}", .{ why.label(), detail }) catch why.label();

        const cool: i128 = switch (why) {
            .failed, .stalled => failed_cooldown_ms,
            else => cooldown_ms,
        };
        var d = Dead{ .idx = idx, .until_ms = now_ms + cool, .reason_len = 0 };
        const n = @min(text.len, d.reason.len);
        @memcpy(d.reason[0..n], text[0..n]);
        d.reason_len = @intCast(n);
        self.dead[self.dead_len] = d;
        self.dead_len += 1;
    }

    /// ¿El candidato `idx` está en cooldown ahora mismo?
    pub fn isDead(self: *const Roster, idx: u8, now_ms: i128) bool {
        for (self.dead[0..self.dead_len]) |*d| {
            if (d.idx == idx and !d.expired(now_ms)) return true;
        }
        return false;
    }

    /// La razón por la que murió el candidato activo, para el mensaje al
    /// usuario ("groq/openai-free: rate limited: 429 Too Many Requests").
    pub fn deadReason(self: *const Roster, idx: u8) []const u8 {
        for (self.dead[0..self.dead_len]) |*d| {
            if (d.idx == idx) return d.reasonStr();
        }
        return "";
    }

    /// "2/7 · openrouter/qwen3-free", para el status bar.
    ///
    /// Con la lista vacía devuelve el motivo (o una cadena vacía): el status bar
    /// tiene que poder decir "por qué no hay free-auto" y no solo callarse.
    pub fn statusLabel(self: *const Roster, arena: std.mem.Allocator) []const u8 {
        if (!self.built) return "";
        if (self.len == 0) {
            if (self.empty_reason.len == 0) return "free-auto: pool empty";
            return std.fmt.allocPrint(arena, "free-auto: {s}", .{self.empty_reason}) catch "free-auto: pool empty";
        }
        const n = self.idx + 1;
        if (self.idx < self.len) {
            return std.fmt.allocPrint(arena, "free-auto {d}/{d} · {s}/{s}", .{
                n, self.len, self.items[self.idx].provider_id, self.items[self.idx].model_id,
            }) catch "free-auto";
        }
        return std.fmt.allocPrint(arena, "free-auto {d}/{d} · exhausted", .{ n, self.len }) catch "free-auto";
    }

    /// El informe final cuando no queda ningún par vivo: qué se probó y por qué
    /// murió cada uno. Es lo que convierte un fallo opaco en algo accionable.
    pub fn exhaustedReport(self: *const Roster, arena: std.mem.Allocator) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        out.appendSlice(arena, "free-auto: no free model left. ") catch return "";
        if (self.dead_len == 0) {
            out.appendSlice(arena, "The pool was empty from the start.") catch return "";
            return out.items;
        }
        out.appendSlice(arena, "Tried: ") catch return "";
        for (self.dead[0..self.dead_len], 0..) |*d, i| {
            if (i > 0) out.appendSlice(arena, "; ") catch return "";
            if (d.idx >= self.len) continue;
            out.print(arena, "{s}/{s} ({s})", .{
                self.items[d.idx].provider_id, self.items[d.idx].model_id, d.reasonStr(),
            }) catch return "";
        }
        return out.items;
    }
};

// ── tests ─────────────────────────────────────────────────────
//
// Todos son PUROS: no tocan la red ni el disco. El `build` con providers reales
// se prueba en el test de integración del final, y lo que se testea aquí es la
// lógica de la rueda, que es donde están los bugs caros (rotar a uno muerto,
// quedarse sin candidatos, pasar el techo).

/// Roster de mentira: `n` candidatos con nombre predecible.
fn fakeRoster(gpa: std.mem.Allocator, n: u8) Roster {
    var r = Roster.init(gpa);
    r.built = true;
    r.len = n;
    for (0..n) |i| {
        r.items[i] = .{
            .provider_id = gpa.dupe(u8, "prov") catch unreachable,
            .model_id = std.fmt.allocPrint(gpa, "m{d}", .{i}) catch unreachable,
        };
    }
    return r;
}

test "trimProvider: de cada provider solo entran los mejores, no los primeros" {
    // El fallo que encontró la sonda: con el tope SOLO global, el provider con más
    // modelos se comía el pool. Y lo peyor: entraban los 8 primeros que publicó,
    // no los 8 mejores.
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    var r = Roster.init(astate.allocator());

    // 20 candidatos de UN provider, en orden de publicación (contexto growing,
    // como los devuelve openrouter: no viene ordenados por nada útil).
    var i: u8 = 0;
    while (i < 20) : (i += 1) {
        r.items[i] = .{ .provider_id = "openrouter", .model_id = "m", .ctx = 1000 + @as(u32, i) * 10 };
    }
    r.len = 20;

    Roster.trimProvider(&r, 0);
    try std.testing.expectEqual(@as(u8, per_provider_max), r.len);
    // Los 8 de más contexto, no los 8 primeros.
    try std.testing.expectEqual(@as(u32, 1000 + 19 * 10), r.items[0].ctx);
    try std.testing.expectEqual(@as(u32, 1000 + 12 * 10), r.items[per_provider_max - 1].ctx);
}

test "trimProvider: no toca los candidatos de los providers anteriores" {
    // El recorte va por TRAMO, no sobre el array entero: si ordenara todo, los
    // 8 mejores serían del provider más grande y volveríamos al bug original.
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    var r = Roster.init(astate.allocator());

    // 6 del primer provider (cabe entero), 18 del segundo (hay que recortar; y
    // 6+18 son justo los 24 del tope, como en `build`).
    for (0..6) |k| {
        r.items[@intCast(k)] = .{ .provider_id = "a", .model_id = "a", .ctx = 10 };
    }
    for (0..18) |k| {
        r.items[6 + @as(u8, @intCast(k))] = .{
            .provider_id = "b",
            .model_id = "b",
            .ctx = 1000 + @as(u32, @intCast(k)) * 10,
        };
    }
    r.len = 24;

    Roster.trimProvider(&r, 6);
    try std.testing.expectEqual(@as(u8, 6 + per_provider_max), r.len);
    // Los 6 primeros siguen siendo del provider "a" y con su contexto intacto.
    for (0..6) |k| {
        try std.testing.expectEqualStrings("a", r.items[@intCast(k)].provider_id);
        try std.testing.expectEqual(@as(u32, 10), r.items[@intCast(k)].ctx);
    }
    try std.testing.expectEqualStrings("b", r.items[6].provider_id);
    try std.testing.expectEqual(@as(u32, 1000 + 17 * 10), r.items[6].ctx);
}

test "trimProvider: un provider con 100 free no deja sin sitio al siguiente" {
    // El caso límite del bug original. Con el recorte por tramo, el primer
    // provider llena los 24 slots, se le recortan a 8, y el siguiente tiene sitio
    // de verdad. (Con el tope solo global, el segundo se quedaba con 0 y el
    // free-auto no tenía plan B aunque hubiera 3 providers con key.)
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    var r = Roster.init(astate.allocator());

    for (0..max_candidates) |k| {
        r.items[@intCast(k)] = .{
            .provider_id = "openrouter",
            .model_id = "m",
            .ctx = 1000 + @as(u32, @intCast(k)),
        };
    }
    r.len = max_candidates;
    Roster.trimProvider(&r, 0);
    try std.testing.expectEqual(@as(u8, per_provider_max), r.len);

    // Y ahora entra el segundo con sitio de sobra.
    for (0..4) |k| {
        r.items[per_provider_max + @as(u8, @intCast(k))] = .{
            .provider_id = "groq",
            .model_id = "g",
            .ctx = 2000,
        };
    }
    r.len = per_provider_max + 4;
    Roster.trimProvider(&r, per_provider_max);
    try std.testing.expectEqual(@as(u8, per_provider_max + 4), r.len);
    try std.testing.expectEqualStrings("groq", r.items[per_provider_max].provider_id);
}

test "currentCandidate es el que se está usando, aunque esté muerto" {
    // Es lo que necesita la línea de "cambié de modelo": el par que se cae, no el
    // siguiente. Y tiene que seguir dando el muerto (es justo cuando se consulta).
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    var r = fakeRoster(astate.allocator(), 3);

    const before = r.currentCandidate().?;
    try std.testing.expectEqualStrings("m0", before.model_id);

    _ = r.rotate(0, .no_credits, "402");
    // El activo ya es otro, y el muerto se puede consultar por su motivo.
    const now = r.currentCandidate().?;
    try std.testing.expectEqualStrings("m1", now.model_id);
    try std.testing.expect(std.mem.indexOf(u8, r.deadReason(0), "402") != null);
}

test "active devuelve el primero y respeta la longitud" {
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    var r = fakeRoster(astate.allocator(), 3);

    const a = r.active(0).?;
    try std.testing.expectEqualStrings("m0", a.model_id);
    try std.testing.expectEqual(@as(u8, 3), r.total());
    try std.testing.expect(!r.isEmpty());

    // Pool vacío: null y no un crash.
    var empty = Roster.init(astate.allocator());
    try std.testing.expect(empty.active(0) == null);
    try std.testing.expect(empty.nextLive(0) == null);
    try std.testing.expect(empty.isEmpty());
}

test "rotate mata el actual y salta al siguiente vivo" {
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    var r = fakeRoster(astate.allocator(), 3);

    // El primero muere → el activo pasa a ser el segundo.
    const next = r.rotate(0, .rate_limited, "429 Too Many Requests").?;
    try std.testing.expectEqualStrings("m1", r.items[next].model_id);
    try std.testing.expect(r.isDead(0, 0));
    try std.testing.expect(!r.isDead(1, 0));
    // Y el motivo guardado es legible, no un código.
    try std.testing.expect(std.mem.indexOf(u8, r.deadReason(0), "rate limited") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.deadReason(0), "429") != null);
}

test "rotate se salta los que siguen en cooldown" {
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    var r = fakeRoster(astate.allocator(), 4);

    // m0 muere, y al rotar cae en m1.
    _ = r.rotate(0, .rate_limited, "429").?;
    // m1 también muere a mano (como si hubiera caído entre medias).
    r.noteDead(1, 0, .no_credits, "402 out of credits");
    // El siguiente vivo tiene que ser m2, no m1.
    const next = r.nextLive(0).?;
    try std.testing.expectEqualStrings("m2", r.items[next].model_id);
}

test "el cooldown expira: pasado el rato el par vuelve a ser usable" {
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    var r = fakeRoster(astate.allocator(), 2);

    r.noteDead(0, 0, .rate_limited, "429");
    try std.testing.expect(r.isDead(0, 0));
    try std.testing.expect(r.isDead(0, cooldown_ms - 1));
    // Justo al cumplirse deja de estar muerto (rate limits de segundos).
    try std.testing.expect(!r.isDead(0, cooldown_ms));
}

test "sin candidatos vivos devuelve null, y no un bucle infinito" {
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    var r = fakeRoster(astate.allocator(), 2);

    r.noteDead(0, 0, .no_credits, "402");
    r.noteDead(1, 0, .no_credits, "402");
    try std.testing.expect(r.active(0) == null);
    try std.testing.expect(r.nextLive(0) == null);
    try std.testing.expect(r.rotate(0, .no_credits, "402") == null);
}

test "sort: workings primero, luego sin gate, luego contexto, y alfabético" {
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    var r = Roster.init(astate.allocator());
    r.built = true;
    // a: gateado y pequeño. b: grande pero gateado. c: grande sin gate.
    // d: pequeño sin gate pero YA FUNCIONÓ.
    r.items[0] = .{ .provider_id = "a", .model_id = "small-gated", .ctx = 1000, .gated_opencode = true };
    r.items[1] = .{ .provider_id = "b", .model_id = "big-gated", .ctx = 200000, .gated_opencode = true };
    r.items[2] = .{ .provider_id = "c", .model_id = "big-open", .ctx = 200000 };
    r.items[3] = .{ .provider_id = "d", .model_id = "small-open-worked", .ctx = 1000, .worked = true };
    r.len = 4;
    r.sort();

    // 1º el que ya funcionó, aunque sea el más pequeño.
    try std.testing.expectEqualStrings("small-open-worked", r.items[0].model_id);
    // 2º el grande sin gate.
    try std.testing.expectEqualStrings("big-open", r.items[1].model_id);
    // 3º y 4º los gateados, por contexto.
    try std.testing.expectEqualStrings("big-gated", r.items[2].model_id);
    try std.testing.expectEqualStrings("small-gated", r.items[3].model_id);
}

test "sort es estable y determinista" {
    // Mismo input, mismo output: si no, la lista de candidatos cambia entre
    // arranques y el test de la rotación no puede fijar nada.
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const ids = [_][]const u8{ "z", "a", "m", "b" };
    for (0..2) |_| {
        var r = Roster.init(astate.allocator());
        r.len = 4;
        for (ids, 0..) |id, i| r.items[i] = .{ .provider_id = "p", .model_id = id };
        r.sort();
        for (ids, 0..) |_, i| {
            const want = [_][]const u8{ "a", "b", "m", "z" };
            try std.testing.expectEqualStrings(want[i], r.items[i].model_id);
        }
    }
}

test "statusLabel dice dónde está y por qué no hay pool" {
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();

    var r = fakeRoster(arena, 3);
    const lbl = r.statusLabel(arena);
    try std.testing.expect(std.mem.indexOf(u8, lbl, "free-auto 1/3") != null);
    try std.testing.expect(std.mem.indexOf(u8, lbl, "prov/m0") != null);

    // Sin construir: nada (no se molesta al usuario con un modo que no ha
    // pedido).
    var fresh = Roster.init(arena);
    try std.testing.expectEqualStrings("", fresh.statusLabel(arena));

    // Construido y vacío: SÍ tiene que decir por qué.
    var e = Roster.init(arena);
    e.built = true;
    e.empty_reason = "no provider has an API key";
    try std.testing.expect(std.mem.indexOf(u8, e.statusLabel(arena), "no provider has an API key") != null);
}

test "exhaustedReport lista qué se probó y por qué" {
    // El fallo que el usuario lee cuando ya no queda nada: si esto no dice qué
    // pasó con cada provider, no hay nada que hacer salvo adivinar.
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    var r = fakeRoster(arena, 2);
    r.noteDead(0, 0, .no_credits, "402 out of credits");
    r.noteDead(1, 0, .gated, "403 can only be used from within OpenCode");

    const rep = r.exhaustedReport(arena);
    try std.testing.expect(std.mem.indexOf(u8, rep, "no free model left") != null);
    try std.testing.expect(std.mem.indexOf(u8, rep, "prov/m0 (no credits") != null);
    try std.testing.expect(std.mem.indexOf(u8, rep, "prov/m1 (gated") != null);
}

test "el cooldown depende de POR QUÉ murió, no es uno para todo" {
    // 10 minutos por un 503 pasajero quitaban un modelo bueno del pool justo
    // cuando el usuario lo necesita. Y al revés: un 402 sí tiene que durar.
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    var r = fakeRoster(astate.allocator(), 2);

    r.noteDead(0, 0, .failed, "JSON parsing failed");
    r.noteDead(1, 0, .no_credits, "402");

    // El que fallo por un blip vuelve antes que el que se quedo sin creditos:
    // sigue fuera a los 59 s (el tope de un minuto) y ya esta dentro a los 60.
    try std.testing.expect(r.isDead(0, failed_cooldown_ms - 1));
    try std.testing.expect(!r.isDead(0, failed_cooldown_ms));
    try std.testing.expect(r.isDead(1, cooldown_ms - 1));
    try std.testing.expect(!r.isDead(1, cooldown_ms));
    // Y la etiqueta lo dice, para que el historial no mienta.
    try std.testing.expect(std.mem.indexOf(u8, r.deadReason(0), "failed 3 times") != null);
}

test "noteDead con detalle larguísimo no se desborda" {
    // El reason es un buffer fijo de 96: un body de error de 4 KB no puede
    // escribir más allá (es el mismo trabajo que hace un path de error de otro
    // sitio: truncado, no panic).
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    var r = fakeRoster(astate.allocator(), 1);
    const huge = "x" ** 4096;
    r.noteDead(0, 0, .rate_limited, huge);
    try std.testing.expect(r.deadReason(0).len <= r.dead[0].reason.len);
    try std.testing.expect(r.deadReason(0).len > 0);
}
