const std = @import("std");
const agent = @import("agent.zig");
const roster_mod = @import("roster.zig");
const tui = @import("tui.zig");

/// El pool de modelos free y la rueda que reparte turnos entre ellos
/// (`/free-auto`).
///
/// ## Por qué vive en un global con spinlock y no dentro de `Model`
///
/// Lo escribe un WORKER (el que lista los modelos de cada provider) y lo leen
/// dos hilos más: el worker del chat, para rotar, y el de la UI, para pintar el
/// status. Es el mismo problema que `acp_client`, con la misma solución: un
/// spinlock `tryLock` de secciones de dos líneas, porque `std.atomic.Mutex` no
/// es reentrante y cogerse el lock con el suyo cuelga la app.
///
/// La diferencia con ACP es que aquí el contenido NO se puede invalidar en
/// runtime: los strings son copias de un arena que vive hasta el teardown, y la
/// regla del AGENTS.md es exacta: un dato que se lee desde varios hilos no se
/// libera nunca en runtime.
///
/// ## Por qué el pool no espera
///
/// `build` habla con N providers: son N peticiones. Si se hiciera en el primer
/// fallo, el usuario vería "se queda pensando" justo cuando necesita que pase
/// algo. Se construye en un worker al encender el modo, y si no está listo el
/// turno sigue con el modelo activo.

var free_auto_on: bool = false;
var roster_state = roster_mod.Roster{};
var roster_inited = false;
var roster_lock: std.atomic.Mutex = .unlocked;

fn rosterLock() void {
    while (!roster_lock.tryLock()) std.Thread.yield() catch {};
}

fn rosterUnlock() void {
    roster_lock.unlock();
}

/// El `Io` para el reloj, si lo hay.
///
/// Es `?std.Io` y no `agent.io_global` a pelo porque ese es `undefined` hasta
/// que el arranque lo asigna, y leer el reloj de un `Io` sin inicializar es
/// saltar por una vtable de basura: un GPF imediato (y NO un 0). Es la misma
/// trampa que `Model.attachIo` con su flag `io_ready`, y el mismo remedio.
var roster_io: ?std.Io = null;

pub fn attachIo(io: std.Io) void {
    roster_io = io;
}

/// Milisegundos desde epoch, para los cooldowns del roster.
///
/// Sin reloj devuelve 0. No es perfecto (los cooldowns no caducan solos) pero es
/// el fallo que NO puede tumbar la app, y solo pasa en tests: en producción
/// siempre hay `Io`.
pub fn nowMs() i128 {
    const io = roster_io orelse return 0;
    return @divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms);
}

/// El roster global, creándolo si hace falta.
pub fn rosterGet(gpa: std.mem.Allocator) *roster_mod.Roster {
    if (!roster_inited) {
        roster_state = roster_mod.Roster.init(gpa);
        roster_inited = true;
    }
    return &roster_state;
}

/// Etiqueta para el status bar, o "" si el modo está apagado o sin construir.
///
/// OJO al contrato: el slice que devuelve es del allocator que le pasa el
/// llamante (el del modelo), no del global. Es lo que permite pintar sin
/// worrying de que el global cambie entre el chequeo y el uso, y es la misma
/// razón por la que `sessionInfo` usa `allocPrint` y no un buffer fijo.
pub fn freeAutoLabel(gpa: std.mem.Allocator) []const u8 {
    if (!free_auto_on) return "";
    rosterLock();
    defer rosterUnlock();
    if (!roster_inited) return "";
    return roster_state.statusLabel(gpa);
}

pub fn freeAutoOn() bool {
    rosterLock();
    defer rosterUnlock();
    return free_auto_on;
}

/// Cuántos candidatos hay en el pool (0 si no está construido). Para el worker
/// del chat, que necesita saber si merece la pena rotar.
pub fn poolSize() u8 {
    rosterLock();
    defer rosterUnlock();
    if (!roster_inited) return 0;
    return roster_state.len;
}

/// El resultado de cambiar de par a mitad de un turno.
pub const Switch = struct {
    /// El par al que se pasa.
    cand: roster_mod.Candidate,
    /// El par que se queda sin cuota (para el mensaje).
    prev_provider: []const u8,
    prev_model: []const u8,
    /// Por qué murió el anterior, ya con la etiqueta ("rate limited: 429 …").
    prev_reason: []const u8,
};

/// Mata el par actual y devuelve el siguiente vivo, o null si no queda ninguno.
///
/// Devuelve EL ANTERIOR también, y no solo el nuevo, porque el mensaje al
/// usuario tiene que poder decir los dos ("quota gone on groq/x → openrouter/y").
/// Con el roster solo (`rotate`) hay que acordarse del índice de antes, que es
/// justo el dato que se pierde en cuanto se mueve.
pub fn switchTo(gpa: std.mem.Allocator, why: roster_mod.Why, detail: []const u8) ?Switch {
    const r = rosterGet(gpa);
    const prev_idx = r.cur_raw;
    const prev = r.currentCandidate() orelse return null;
    const next = r.rotate(nowMs(), why, detail) orelse return null;
    return .{
        .cand = r.items[next],
        .prev_provider = prev.provider_id,
        .prev_model = prev.model_id,
        .prev_reason = r.deadReason(prev_idx),
    };
}

// ── puente para los tests de `agent.zig` ──────────────────────
//
// `pickTarget` vive en agent.zig (porque necesita el provider activo) y el
// estado del modo vive aquí. Los tests de uno necesitan tocar el del otro, y
// hacerlo con `free_auto_on` a pelo desde el otro fichero no compila (es privado).
// Estos tres son el puente, y son la razón de que existan en vez de un
// `pub var` a lo bruto: obligan a restaurar el estado.

pub const StateSnapshot = struct {
    on: bool,
    inited: bool,
    state: roster_mod.Roster,
};

pub fn stateSave() StateSnapshot {
    rosterLock();
    defer rosterUnlock();
    return .{ .on = free_auto_on, .inited = roster_inited, .state = roster_state };
}

pub fn stateRestore(s: StateSnapshot) void {
    rosterLock();
    free_auto_on = s.on;
    roster_inited = s.inited;
    roster_state = s.state;
    rosterUnlock();
}

pub fn stateSet(on: bool, inited: bool, state: roster_mod.Roster) void {
    rosterLock();
    free_auto_on = on;
    roster_inited = inited;
    roster_state = state;
    rosterUnlock();
}

/// Job del worker que construye el pool.
const RosterJob = struct {
    model: *tui.Model,
};

/// Construye el pool en segundo plano.
///
/// Los `defs` (providers compilados + los de `config.json`) salen de un arena
/// que muere al terminar el worker, y por eso `Roster.build` DUPLICA todo lo que
/// necesita del provider: los ids de los candidatos son copias del arena del
/// roster, no del def.
fn rosterWorker(job: *RosterJob) void {
    const m = job.model;
    defer {
        m.allocator.destroy(job);
        m.endWorker();
    }

    var astate = std.heap.ArenaAllocator.init(m.allocator);
    defer astate.deinit();
    const defs = agent.allProviders(astate.allocator());
    const gpa = rosterGet(m.allocator).arena;

    var r = roster_mod.Roster.init(gpa);
    r.build(agent.io_global, m.environ, defs) catch {
        rosterLock();
        roster_state.built = true;
        roster_state.empty_reason = "could not reach any provider";
        rosterUnlock();
        const msg = "free-auto: could not build the model pool (no provider answered)";
        agent.pushInfo(m, msg);
        return;
    };

    // Se instala SOLO si el global ya existe. Si el usuario no ha dado al
    // `/free-auto`, este worker no tiene por qué dejar un pool detrás.
    if (roster_inited) {
        rosterLock();
        roster_state.len = r.len;
        roster_state.dead_len = 0;
        roster_state.built = true;
        roster_state.empty_reason = r.empty_reason;
        @memcpy(roster_state.items[0..r.len], r.items[0..r.len]);
        roster_state.idx = 0;
        roster_state.cur_raw = 0;
        rosterUnlock();
    }
    const n = r.len;

    if (!freeAutoOn()) return;
    if (n == 0) {
        const why = if (r.empty_reason.len > 0) r.empty_reason else "the pool is empty";
        own(m, "free-auto: {s}", .{why});
        return;
    }
    own(m, "free-auto: {d} free model{s} ready", .{ n, if (n == 1) "" else "s" });
}

/// Lanza el worker que construye el pool. Best-effort: si no se puede lanzar, el
/// modo sigue funcionando con el modelo activo y lo dirá al rotar.
pub fn startRosterBuild(m: *tui.Model) void {
    _ = rosterGet(m.allocator);
    const job = m.allocator.create(RosterJob) catch return;
    job.* = .{ .model = m };
    m.beginWorker();
    const t = std.Thread.spawn(.{}, rosterWorker, .{job}) catch {
        m.endWorker();
        m.allocator.destroy(job);
        const msg = "free-auto: could not start the model listing thread";
        agent.pushInfo(m, msg);
        return;
    };
    t.detach();
}

/// `pushInfoOwned` con un texto propio SIEMPRE.
///
/// Existe porque el fallo es silencioso hasta que la app MUERE: pasar un literal
/// a `pushInfoOwned` deja un puntero a `.rodata` en `pending`, y `Model.deinit`
/// lo libera -> "Invalid free" al salir. Es la misma trampa que los literales de
/// la paleta (ver AGENTS.md, "Un crash al salir por literales"), y ya se ha
/// escrito dos veces en este repo.
///
/// Ademas cubre el `catch` del `allocPrint`: sin memoria hay que callarse, no
/// empujar un literal a una funcion que se supone que toma posesion.
fn own(m: *tui.Model, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(m.allocator, fmt, args) catch {
        agent.pushInfo(m, "free-auto: out of memory");
        return;
    };
    agent.pushInfoOwned(m, msg);
}

/// Cambia el estado del modo. Devuelve `true` si hay que lanzar el worker del
/// pool (es decir: se acaba de encender y no hay lista todavia).
///
/// Va separada de `cmdFreeAuto` por una razon concreta: encender el modo lanza
/// un hilo que habla con la red, y un test que llame a `cmdFreeAuto("on")`
/// deja ese hilo vivo con un `Model` ya liberado. Aqui no hay hilo, asi que el
/// estado SI es comprobable.
pub fn setFreeAuto(m: *tui.Model, want_on: bool) bool {
    rosterLock();
    free_auto_on = want_on;
    // Al apagar se olvida quien estaba muerto: si se vuelve a encender dentro de
    // un rato, los cooldowns viejos ya no aplican y el pool se prueba entero
    // otra vez.
    if (!want_on) roster_state.dead_len = 0;
    const built = roster_inited and roster_state.built;
    const n = if (roster_inited) roster_state.len else 0;
    rosterUnlock();

    if (!want_on) {
        agent.pushInfo(m, "free-auto: off (back to the active model)");
        agent.setStatusWithZo(m, .idle, "free-auto off");
        return false;
    }

    if (built) {
        own(m, "free-auto: on · {d} free model{s} in the pool", .{ n, if (n == 1) "" else "s" });
        agent.setStatusWithZo(m, .done, "free-auto on");
        return false;
    }

    agent.pushInfo(m, "free-auto: on · listing free models of every provider with a key…");
    agent.setStatusWithZo(m, .thinking, "building the free pool");
    return true;
}

/// `/free-auto [on|off|status]`.
pub fn cmdFreeAuto(m: *tui.Model, arg: ?[]const u8) void {
    const a = if (arg) |x| std.mem.trim(u8, x, " \t") else "";

    if (std.mem.eql(u8, a, "status")) {
        // OJO: los literales van por `pushInfo` (que COPIA). Por `pushInfoOwned`
        // (que toma posesion) un literal se acaba liberando en `Model.deinit`, y
        // eso es un "Invalid free" al salir. Que se note: `/free-auto status` con
        // el pool sin construir es justo la rama del literal.
        if (!freeAutoOn()) {
            agent.pushInfo(m, "free-auto: off");
            return;
        }
        const lbl = freeAutoLabel(m.allocator);
        if (lbl.len == 0) {
            agent.pushInfo(m, "free-auto: on · still listing models");
            return;
        }
        own(m, "free-auto: on · {s}", .{lbl});
        return;
    }

    const want_on = if (std.mem.eql(u8, a, "off"))
        false
    else if (a.len > 0 and !std.mem.eql(u8, a, "on")) {
        agent.pushInfo(m, "usage: /free-auto [on|off|status]");
        return;
    } else !freeAutoOn();

    if (setFreeAuto(m, want_on)) startRosterBuild(m);
}

/// Enciende el modo desde el entorno (`ZODE_FREE_AUTO=1`) sin pasar por el
/// comando. Lo llama el arranque de la TUI. Un valor "0"/"off"/"false" cuenta
/// como apagado, que es lo que espera cualquiera que ponga la variable por
/// costumbre.
pub fn initFromEnv(m: *tui.Model, env: ?*const std.process.Environ.Map) void {
    const v = if (env) |e| e.get("ZODE_FREE_AUTO") else null;
    const val = v orelse return;
    const off = std.mem.eql(u8, val, "0") or std.ascii.eqlIgnoreCase(val, "off") or
        std.ascii.eqlIgnoreCase(val, "false");
    if (off) return;
    cmdFreeAuto(m, "on");
}

// ── tests ─────────────────────────────────────────────────────
//
// Todos tocan el global del roster, así que cada uno deja el estado como lo
// encontró. El lock es un SPINLOCK: cogerse dos veces en el mismo hilo cuelga,
// y por eso no hay ni un `defer rosterLock()` con un segundo `rosterLock()`
// dentro (que fue el primer borrador de estos tests).

/// Guarda el estado del global y lo devuelve al final.
const Saved = struct {
    on: bool,
    inited: bool,
    state: roster_mod.Roster,

    fn save() Saved {
        rosterLock();
        defer rosterUnlock();
        return .{ .on = free_auto_on, .inited = roster_inited, .state = roster_state };
    }

    fn restore(self: Saved) void {
        rosterLock();
        free_auto_on = self.on;
        roster_inited = self.inited;
        roster_state = self.state;
        rosterUnlock();
    }
};

test "freeAutoLabel: apagado devuelve vacío (el status bar no se ensucia)" {
    const saved = Saved.save();
    defer saved.restore();

    rosterLock();
    free_auto_on = false;
    rosterUnlock();

    try std.testing.expectEqualStrings("", freeAutoLabel(std.testing.allocator));
}

test "freeAutoLabel: encendido y construido dice dónde está" {
    const saved = Saved.save();
    defer saved.restore();

    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();

    var fake = roster_mod.Roster.init(arena);
    fake.built = true;
    fake.len = 2;
    fake.items[0] = .{ .provider_id = "groq", .model_id = "llama-3.3-70b" };
    fake.items[1] = .{ .provider_id = "openrouter", .model_id = "qwen3:free" };

    rosterLock();
    free_auto_on = true;
    roster_inited = true;
    roster_state = fake;
    rosterUnlock();

    const label = freeAutoLabel(arena);
    try std.testing.expect(std.mem.indexOf(u8, label, "free-auto 1/2") != null);
    try std.testing.expect(std.mem.indexOf(u8, label, "groq/llama-3.3-70b") != null);
}

test "freeAutoLabel: encendido y con el pool vacío dice POR QUÉ" {
    // El caso que hace útil el modo: no hay free porque no hay key, y eso hay que
    // decirlo. Un "free-auto" a secas en el status no informa de nada.
    const saved = Saved.save();
    defer saved.restore();

    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();

    var empty = roster_mod.Roster.init(arena);
    empty.built = true;
    empty.empty_reason = "no provider has an API key (ctrl+a to connect one)";

    rosterLock();
    free_auto_on = true;
    roster_inited = true;
    roster_state = empty;
    rosterUnlock();

    const label = freeAutoLabel(arena);
    try std.testing.expect(std.mem.indexOf(u8, label, "no provider has an API key") != null);
    try std.testing.expect(std.mem.indexOf(u8, label, "ctrl+a") != null);
}

test "cmdFreeAuto: on/off alterna, `status` no cambia nada, basura avisa" {
    const saved = Saved.save();
    defer saved.restore();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    rosterLock();
    free_auto_on = false;
    rosterUnlock();

    // OJO: se usa `setFreeAuto` y NO `cmdFreeAuto("on")`, porque este ultimo
    // lanza el worker del pool (un hilo que habla con la red) y el test lo
    // dejaria vivo con el `Model` ya liberado. Lo que se prueba aqui es el
    // estado, que es lo que importa.
    _ = setFreeAuto(&m, true);
    try std.testing.expect(freeAutoOn());

    cmdFreeAuto(&m, "status");
    try std.testing.expect(freeAutoOn()); // `status` no toca nada

    _ = setFreeAuto(&m, false);
    try std.testing.expect(!freeAutoOn());

    // Un argumento raro NO es un "on" silencioso: eso sería la peor forma de
    // fallar en un modo que cambia de modelo por debajo.
    cmdFreeAuto(&m, "maybe");
    try std.testing.expect(!freeAutoOn());
}

test "setFreeAuto: pide construir el pool solo cuando no hay lista" {
    // El `bool` de retorno decide si se lanza el worker. Si dijera que si con el
    // pool ya construido, cada `/free-auto on` re-listaria N providers.
    const saved = Saved.save();
    defer saved.restore();

    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    // Sin construir: hay que lanzar el worker.
    rosterLock();
    roster_inited = false;
    free_auto_on = false;
    rosterUnlock();
    try std.testing.expect(setFreeAuto(&m, true));

    // Construido: NO hay que lanzar nada.
    var fake = roster_mod.Roster.init(arena);
    fake.built = true;
    fake.len = 3;
    rosterLock();
    roster_inited = true;
    roster_state = fake;
    rosterUnlock();
    try std.testing.expect(!setFreeAuto(&m, false));
    try std.testing.expect(!setFreeAuto(&m, true));
}

test "apagar limpia los cooldowns" {
    // Si no se limpian, encender y apagar en el mismo minuto deja el pool medio
    // muerto y el modo parece roto.
    const saved = Saved.save();
    defer saved.restore();

    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();

    var fake = roster_mod.Roster.init(arena);
    fake.built = true;
    fake.len = 2;
    fake.items[0] = .{ .provider_id = "groq", .model_id = "a" };
    fake.items[1] = .{ .provider_id = "groq", .model_id = "b" };

    rosterLock();
    free_auto_on = true;
    roster_inited = true;
    roster_state = fake;
    rosterUnlock();

    fake.noteDead(0, 0, .rate_limited, "429");
    rosterLock();
    roster_state.dead_len = fake.dead_len;
    rosterUnlock();
    try std.testing.expectEqual(@as(u8, 1), roster_state.dead_len);

    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    cmdFreeAuto(&m, "off");
    try std.testing.expectEqual(@as(u8, 0), roster_state.dead_len);
}
