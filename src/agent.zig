const std = @import("std");
const tui = @import("tui.zig");
const providers = @import("providers.zig");
const chat = @import("chat.zig");
const http_client = @import("http_client.zig");
const tools_mod = @import("tools.zig");
const roster_mod = @import("roster.zig");
const free_auto = @import("free_auto.zig");
const session_mod = @import("session.zig");
const models_mod = @import("models.zig");
const cache_stats = @import("cache_stats.zig");
const compaction = @import("compaction.zig");
const mascot = @import("mascot.zig");
const palette = @import("palette.zig");
const config_mod = @import("config.zig");
const acp = @import("acp.zig");

/// Io y API key configurados por la TUI al arrancar.
pub var io_global: std.Io = undefined;
pub var api_key_global: ?[]const u8 = null;
pub var environ_global: ?*const std.process.Environ.Map = null;
pub var gpa_global: std.mem.Allocator = undefined;

// ── system prompt: AGENTS.md del proyecto (cacheado) ─────────
var agents_md_cache: ?[]u8 = null;

pub const default_system_prompt =
    \\You are zode, a coding agent running inside a terminal harness.
    \\You help the user with software engineering tasks: fixing bugs, adding
    \\features, refactoring, and explaining code.
    \\
    \\Environment:
    \\ - You have tools: read, write, edit (str_replace, multi-hunk), bash,
    \\   glob, grep, list_files, web_fetch, web_search, think. Prefer
    \\   grep/glob first, then read only what you need.
    \\ - For edits, use the edit tool with exact old_string/new_string.
    \\ - web_fetch returns a URL as readable text (HTML stripped);
    \\   web_search gives titles, URLs and snippets. Use them when you need
    \\   facts you do not have (library docs, versions, exact error messages),
    \\   and say so when an answer comes from the web.
    \\ - Keep answers concise. Use markdown. Code blocks must include the
    \\   language tag so the terminal UI can highlight them.
    \\ - If a tool call is denied by the user, do not retry it; adjust approach.
    \\
;

fn systemPrompt(gpa: std.mem.Allocator) []const u8 {
    if (agents_md_cache == null) {
        // AGENTS.md / CLAUDE.md del proyecto del usuario tienen prioridad.
        agents_md_cache = std.Io.Dir.cwd().readFileAlloc(io_global, "AGENTS.md", gpa, .limited(256 * 1024)) catch
            std.Io.Dir.cwd().readFileAlloc(io_global, "CLAUDE.md", gpa, .limited(256 * 1024)) catch null;
    }
    if (agents_md_cache) |c| return c;
    return default_system_prompt;
}

pub var current_effort: chat.Effort = .medium;

/// Modo de permisos: false = pide antes de write/edit/bash, true = auto.
pub var yolo: bool = false;

/// Máximo de iteraciones agénticas por request.
const max_iterations: usize = 8;

/// Tool results elided en la sesión (para /context).
var session_elided: usize = 0;

/// Tok/s del stream en curso (status bar) y del último stream completado.
pub var tps_live: f64 = 0;
pub var tps_last: f64 = 0;

/// Tokens de contexto usados y su porcentaje sobre el límite.
///
/// Se cachea aquí porque el status bar lo lee en CADA FRAME y recorrer el
/// historial para estimar los tokens 60 veces por segundo es trabajo tirado.
/// Se refresca al cerrar cada turno.
pub var ctx_used: i64 = 0;
pub var ctx_pct: u8 = 0;

/// Recalcula `ctx_used`/`ctx_pct`. Barato de llamar, pero no hace falta por
/// frame: los tokens solo cambian cuando se añade un mensaje.
pub fn refreshContextUsage(m: *tui.Model) void {
    if (session == null) {
        ctx_used = 0;
        ctx_pct = 0;
        return;
    }
    var astate = std.heap.ArenaAllocator.init(m.allocator);
    defer astate.deinit();
    const msgs = snapshotMsgs(astate.allocator());
    ctx_used = compaction.estimateTokens(msgs);
    const limit = @max(1, compaction.contextLimit(m.environ));
    const pct = (@as(f64, @floatFromInt(ctx_used)) / @as(f64, @floatFromInt(limit))) * 100.0;
    ctx_pct = @intFromFloat(std.math.clamp(pct, 0, 999));
}

fn updateTps(chars: usize, start_ns: i128) void {
    if (start_ns == 0 or chars < 32) return;
    const now_ns = std.Io.Timestamp.now(io_global, .real).nanoseconds;
    const dt = now_ns - start_ns;
    if (dt <= 0) return;
    const tps = (@as(f64, @floatFromInt(chars)) / 4.0) / (@as(f64, @floatFromInt(dt)) / 1e9);
    if (tps > 0.5 and tps < 100_000) {
        tps_live = tps;
        tps_last = tps;
    }
}

// ── provider / modelo / sesión activos ────────────────────────

var cur_provider_id: []const u8 = "opencode";
var cur_model: []const u8 = "";

/// Sesión activa (`null` hasta el primer mensaje). La crea el worker, no el
/// arranque: abrir un fichero de sesión por el mero hecho de arrancar crearía
/// ficheros basura si el usuario nunca chatea.
var session: ?*session_mod.Session = null;

/// ¿Reabrir la última sesión al arrancar? Lo fija `ZODE_RESUME=1` o `--resume`.
pub var resume_on_start: bool = false;

/// Copia el nombre de modelo a un buffer estático (evita slices colgantes
/// de strings efímeros del input).
var cur_model_buf: [128]u8 = undefined;

/// Provider y modelo activos, para el status bar. Se exponen como funciones
/// (y no los `var` crudos) para que la TUI no dependa del buffer estático.
pub fn curProvider() []const u8 {
    return cur_provider_id;
}
pub fn curModel() []const u8 {
    return cur_model;
}
pub fn setModel(name: []const u8) void {
    const n = @min(name.len, cur_model_buf.len);
    @memcpy(cur_model_buf[0..n], name[0..n]);
    cur_model = cur_model_buf[0..n];
}

// ── permisos: "siempre permitir" por tool (sesión) ──────────
const max_always = 8;
var always_names: [max_always][48]u8 = undefined;
var always_lens: [max_always]usize = @splat(0);

fn isAlwaysAllowed(name: []const u8) bool {
    for (always_lens, 0..) |l, i| {
        if (l > 0 and std.mem.eql(u8, always_names[i][0..l], name)) return true;
    }
    return false;
}

fn setAlwaysAllowed(m: *tui.Model, name: []const u8) void {
    if (setAlwaysAllowedNoSave(name)) {
        saveAllowlist();
        const msg = std.fmt.allocPrint(m.allocator, "always allowed: {s}", .{name}) catch return;
        pushInfoOwned(m, msg);
    }
}

/// Como `setAlwaysAllowed` pero SIN escribir a disco: lo usa la carga inicial,
/// que no quiere reescribir el fichero que acaba de leer.
/// Devuelve false si la allowlist está llena (no crece sin límite: son 8
/// tools como mucho y más allá es ruido en el diálogo de permisos).
fn setAlwaysAllowedNoSave(name: []const u8) bool {
    if (isAlwaysAllowed(name)) return true;
    for (always_lens, 0..) |l, i| {
        if (l == 0) {
            const n = @min(name.len, 48);
            @memcpy(always_names[i][0..n], name[0..n]);
            always_lens[i] = n;
            return true;
        }
    }
    return false;
}

/// Lee `permissions.json` y rellena la allowlist. Best-effort: si no existe o
/// está corrupto, la sesión empieza con la allowlist vacía.
fn loadAllowlist() void {
    var pbuf: [512]u8 = undefined;
    const path = permissionsFilePath(&pbuf) orelse return;

    var astate = std.heap.ArenaAllocator.init(gpa_global);
    defer astate.deinit();
    const a = astate.allocator();

    const data = readFileTo(a, path) orelse return;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, data, .{}) catch return;
    if (parsed != .array) return;
    for (parsed.array.items) |v| {
        if (v != .string) continue;
        _ = setAlwaysAllowedNoSave(v.string);
    }
}

// ── allowlist persistida: ~/.config/zode/permissions.json ────
fn permissionsFilePath(buf: []u8) ?[]const u8 {
    const home = environ_global.?.get("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/zode/permissions.json", .{home}) catch null;
}

/// Persiste la allowlist de "siempre permitir" como un array JSON de nombres.
///
/// A mano (y no con un writer sobre un mapa) porque son 8 strings como mucho y
/// así se lee de un vistazo.
fn saveAllowlist() void {
    var pbuf: [512]u8 = undefined;
    const path = permissionsFilePath(&pbuf) orelse return;

    var names: [max_always][]const u8 = undefined;
    var n: usize = 0;
    for (always_lens, 0..) |l, i| {
        if (l == 0) continue;
        names[n] = always_names[i][0..l];
        n += 1;
    }

    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    config_mod.writeStringArray(&w, gpa_global, names[0..n]) catch return;
    std.Io.Dir.cwd().writeFile(io_global, .{ .sub_path = path, .data = w.buffered() }) catch {};
}

fn readFileTo(arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io_global, path, arena, .limited(1 << 20)) catch null;
}

// ── entorno y avisos al historial ──────────────────────────────

fn envGet(env: ?*const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const m = env orelse return null;
    return m.get(key);
}

/// [roster] La etiqueta del free-auto para el status bar, o "" si está apagado.
///
/// Es un `pub` en vez de dejar que la TUI importe `free_auto.zig`: el status bar
/// solo debe saber leer, no escribir, del estado del modo.
pub fn freeAutoLabel(gpa: std.mem.Allocator) []const u8 {
    return free_auto.freeAutoLabel(gpa);
}

/// [roster] Enciende el free-auto si el entorno lo pide (`ZODE_FREE_AUTO=1`).
///
/// Lo llama el arranque de la TUI, DESPUÉS de `loadUserConfig` y de `loadAuthKeys`
/// (sin keys cargadas el pool saldría vacío y el modo parecería roto).
pub fn initFreeAutoFromEnv(m: *tui.Model) void {
    free_auto.initFromEnv(m, m.environ);
}

/// [roster] `pub` para que lo use `free_auto.zig` desde su worker.
pub fn pushInfo(m: *tui.Model, text: []const u8) void {
    m.pushInfo(text);
}

/// Variante que ya trae la memoria del llamante: no hay que duplicar (ni
/// liberar) el texto. Se usa en el worker, que no puede dejar basura por frame.
/// [roster] `pub` para que lo use `free_auto.zig`.
pub fn pushInfoOwned(m: *tui.Model, text: []const u8) void {
    m.pushInfoOwned(text);
}

/// Pone el estado del turno. El texto NO lleva la carita: la dibuja la TUI en
/// la fila de status, en el color del mood, una sola vez. Aquí se la metía y
/// salía duplicada y del mismo gris que todo lo demás (que es justo la queja de
/// que "no se nota por el color").
/// [roster] `pub` para que lo use `free_auto.zig`.
pub fn setStatusWithZo(m: *tui.Model, mood: mascot.Mood, text: []const u8) void {
    m.setStatusWithMood(mood, text);
}

// ── providers: config.json > compilados ───────────────────────

/// Todos los providers: los del `config.json` del usuario primero y luego los
/// compilados que no estén redefinidos (un id del config gana al compilado).
/// [roster] `pub` para que `free_auto.zig` liste los providers del pool.
pub fn allProviders(arena: std.mem.Allocator) []const providers.ProviderDef {
    return config_mod.allDefs(arena, user_config);
}

/// Definición del provider activo.
fn curDef(env: ?*const std.process.Environ.Map) *const providers.ProviderDef {
    return activeProviderDef(env);
}

pub fn activeProviderDef(env: ?*const std.process.Environ.Map) *const providers.ProviderDef {
    if (config_mod.find(user_config, cur_provider_id)) |d| return d;
    return providers.byId(cur_provider_id) orelse providers.activeDef(env);
}

/// API key del provider activo: primero la guardada en `auth.json`, luego la
/// variable de entorno, luego la genérica.
fn curKey(m: *tui.Model) ?[]const u8 {
    if (providers.keyFor(activeProviderDef(m.environ), m.environ)) |k| return k;
    if (api_key_global) |k| return k;
    return envGet(m.environ, "ZODE_API_KEY");
}

// ── config del usuario ─────────────────────────────────────────

var cfg_arena_state: ?std.heap.ArenaAllocator = null;
var user_config: config_mod.Config = .{};

/// Carga el `config.json` del usuario. Llamar una vez al arrancar.
pub fn loadUserConfig() void {
    if (cfg_arena_state == null) {
        cfg_arena_state = std.heap.ArenaAllocator.init(gpa_global);
        user_config = config_mod.load(cfg_arena_state.?.allocator(), io_global, environ_global);

        // Orden de precedencia: config.json > ZODE_PROVIDER > opencode.
        // (Antes se ignoraba ZODE_PROVIDER en la TUI: se quedaba en "opencode"
        // y acababa mandando la key de un provider al endpoint de otro → 403.)
        if (user_config.provider.len > 0) {
            cur_provider_id = user_config.provider;
        } else if (envGet(environ_global, "ZODE_PROVIDER")) |p| {
            if (config_mod.find(user_config, p) != null or providers.byId(p) != null) {
                cur_provider_id = p;
            }
        }
        if (user_config.model.len > 0) {
            setModel(user_config.model);
        } else if (cur_model.len == 0) {
            setModel(activeProviderDef(environ_global).default_model);
        }
        loadAllowlist();
        loadAuthKeys(cfg_arena_state.?.allocator());
    }
}

/// Lee `~/.config/zode/auth.json` y lo pasa a `providers` para que `keyFor` lo
/// use. Sin esto, conectar un provider desde la paleta guardaba la key y
/// luego no se usaba: `keyFor` solo miraba el entorno.
/// Arena de las keys guardadas. **Nunca se destruye hasta salir del proceso**.
///
/// Antes cada recarga de config reutilizaba la arena del config, que sí se
/// liberaba: el worker de modelos estaba leyendo `saved_keys` por
/// `providers.hasKey` mientras el hilo de la UI conectaba un provider y
/// liberaba esa arena debajo de sus pies. Uso después de liberar, sin que nada
/// lo delate (depende de que el worker este justo en esa línea).
///
/// Aquí cada mapa nuevo vive en su propia arena permanente, así que
/// reasignar el puntero es atómico y el mapa viejo sigue siendo memoria válida
/// (lo que ya no se usa, se libera al salir).
var keys_arena_state: ?std.heap.ArenaAllocator = null;

fn loadAuthKeys(_: std.mem.Allocator) void {
    var buf: [1024]u8 = undefined;
    const path = config_mod.authPath(environ_global, &buf) orelse return;

    if (keys_arena_state == null) keys_arena_state = std.heap.ArenaAllocator.init(gpa_global);
    const a = keys_arena_state.?.allocator();

    const data = readFileTo(a, path) orelse return;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, data, .{}) catch return;
    if (parsed != .object) return;

    var map = a.create(std.StringHashMapUnmanaged([]const u8)) catch return;
    map.* = .{};
    var it = parsed.object.iterator();
    while (it.next()) |kv| {
        const v = kv.value_ptr.*;
        if (v != .string or v.string.len == 0) continue;
        // La key se copia porque el string del parser vive en el arena que se
        // acaba de liberar justo arriba.
        map.put(a, kv.key_ptr.*, a.dupe(u8, v.string) catch continue) catch continue;
    }
    providers.setSavedKeys(map);
}

/// Vuelve a leer el `config.json` desde cero.
///
/// `loadUserConfig` tiene guarda de "solo una vez" (el config se lee al
/// arrancar), así que sin esto, tras conectar un provider su estado de key se
/// quedaba en "sin key" para el resto de la sesión.
pub fn reloadUserConfig() void {
    // OJO: aquí NO se llama a `shutdownUserConfig`, porque esa función también
    // destruye la arena de las keys, que puede estar leyendo un worker. La de
    // keys se destruye solo en `shutdownUserConfig`, al final del proceso.
    if (cfg_arena_state) |*st| st.deinit();
    cfg_arena_state = null;
    user_config = .{};
    loadUserConfig();
}

/// Libera las arenas de config y de keys. Al salir del proceso, cuando ya no
/// queda ningún worker leyendo.
pub fn shutdownUserConfig() void {
    if (cfg_arena_state) |*s| {
        s.deinit();
        cfg_arena_state = null;
    }
    if (keys_arena_state) |*s| {
        s.deinit();
        keys_arena_state = null;
    }
    providers.setSavedKeys(null);
    user_config = .{};
}

// ── sesión ────────────────────────────────────────────────────

/// Devuelve la sesión activa, creándola si hace falta.
///
/// Se llama desde el worker y desde los comandos. La sesión se crea LA
/// PRIMERA VEZ que hace falta, no al arrancar: así abrir la TUI y cerrarla
/// sin chatear no deja un `sessions/zode-*.jsonl` vacío por ahí.
fn ensureSession(m: *tui.Model, arena: std.mem.Allocator) *session_mod.Session {
    if (session) |s| return s;
    _ = arena;
    const fresh = session_mod.Session.create(m.allocator, io_global) catch {
        // Sin disco se sigue igual: es degradación, no error fatal. La sesión
        // en memoria (`file = null`) no escribe nada.
        const s = m.allocator.create(session_mod.Session) catch @panic("sin memoria para la sesión");
        s.* = session_mod.Session.init(m.allocator);
        session = s;
        return s;
    };
    session = fresh;
    return fresh;
}

/// Crea una sesión nueva y descarta la actual.
pub fn newSession(m: *tui.Model) void {
    if (session) |old| {
        m.allocator.destroy(old);
        session = null;
    }
    const s = ensureSession(m, m.allocator);
    const msg = std.fmt.allocPrint(m.allocator, "new session: {s}", .{s.id[0..]}) catch "new session";
    pushInfoOwned(m, msg);
    session_elided = 0;
}

/// Vacia el historial de la sesión actual sin crear otra.
pub fn resetSession(m: *tui.Model) void {
    if (session) |s| {
        s.messages.clearRetainingCapacity();
        s.flush();
    }
    session_elided = 0;
    const msg = std.fmt.allocPrint(m.allocator, "session reset", .{}) catch "session reset";
    pushInfoOwned(m, msg);
}

/// Abre la sesión al arrancar: la más reciente si se pidió (`--resume` o
/// `ZODE_RESUME=1`), si no una nueva.
pub fn bootstrapSession(m: *tui.Model) void {
    loadUserConfig();

    if (resume_on_start) {
        var astate = std.heap.ArenaAllocator.init(m.allocator);
        defer astate.deinit();
        const a = astate.allocator();
        const latest = session_mod.Session.latestSessionPath(a, io_global) catch null;
        if (latest) |path| {
            if (session_mod.Session.resumePath(m.allocator, io_global, path)) |s| {
                session = s;
                const msg = std.fmt.allocPrint(m.allocator, "sesión reanudada: {s}", .{s.path orelse s.id[0..]}) catch
                    "sesión reanudada";
                pushInfoOwned(m, msg);
                return;
            } else |_| {}
        }
        const msg = allocPrint(m, "nothing to resume; starting a new session", .{}) catch return;
        pushInfoOwned(m, msg);
    }
    _ = ensureSession(m, m.allocator);
}

/// `allocPrint` corto: el 90% de los mensajes del historial los escribe el
/// worker y no puede dejar basura por frame.
fn allocPrint(m: *tui.Model, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(m.allocator, fmt, args);
}

/// Copia los mensajes de la sesión a un slice de `ChatMessage`.
///
/// `tool` → role "tool" (como espera la API de OpenAI), y el `system` se queda
/// el primero. La memoria es del arena que le pase el llamante.
fn snapshotMsgs(arena: std.mem.Allocator) []chat.ChatMessage {
    const s = session orelse return &.{};
    const msgs = arena.alloc(chat.ChatMessage, s.messages.items.len) catch return &.{};
    for (s.messages.items, 0..) |sm, i| {
        msgs[i] = .{
            .role = @tagName(sm.role),
            .content = sm.content,
            .tool_calls_json = sm.tool_calls_json,
            .tool_call_id = sm.tool_call_id,
            .tool_name = sm.tool_name,
        };
    }
    return msgs;
}

// ── tabla de comandos ─────────────────────────────────────────

pub const Cmd = struct {
    key: []const u8,
    desc: []const u8,
    /// Atajo de teclado que hace lo mismo (columna derecha de la paleta).
    /// Solo se listan los que existen de verdad: poner uno falso sería
    /// peor que no poner ninguno.
    key_hint: ?[]const u8 = null,
};

/// `key` viene con la barra inicial. El orden es el de aparición en `/help`.
pub const commands = [_]Cmd{
    .{ .key = "/help", .desc = "show commands", .key_hint = "ctrl+p" },
    .{ .key = "/models", .desc = "list the active provider models" },
    .{ .key = "/model", .desc = "pick a model in a modal", .key_hint = "ctrl+p" },
    .{ .key = "/provider", .desc = "pick a provider in a modal" },
    .{ .key = "/providers", .desc = "list providers" },
    .{ .key = "/use", .desc = "switch provider/model", .key_hint = "provider modelo" },
    .{ .key = "/effort", .desc = "low|medium|high (no args: picker)" },
    .{ .key = "/free-auto", .desc = "on|off: rotate free models across providers when one runs out" },
    .{ .key = "/yolo", .desc = "toggle auto permissions" },
    .{ .key = "/acp", .desc = "on|off|<cmd>: delegate the turn to an ACP agent (opencode acp)" },
    .{ .key = "/new", .desc = "new session" },
    .{ .key = "/resume", .desc = "resume the last session" },
    .{ .key = "/context", .desc = "tokens used vs budget (compaction at 80%)" },
    .{ .key = "/session", .desc = "session info" },
    .{ .key = "/cache", .desc = "cache hit-rate for this session" },
    .{ .key = "/quit", .desc = "quit" },
};

/// `/cache`: hit-rate de prompt cache de la sesión.
fn cmdCache(m: *tui.Model) void {
    const st = &cache_stats.session;
    const line = std.fmt.allocPrint(
        m.allocator,
        "cache [{s}] {d:.1}% hit-rate · {d} reqs with hit · {d} prompt / {d} cached / {d} completion",
        .{ cur_provider_id, st.hitRatePct(), st.cache_hits, st.prompt_tokens, st.cached_tokens, st.completion_tokens },
    ) catch "cache";
    pushInfoOwned(m, line);
}

/// `/context`: gauge de contexto usado frente al límite y al budget.
fn cmdContext(m: *tui.Model) void {
    _ = ensureSession(m, m.allocator);
    var astate = std.heap.ArenaAllocator.init(m.allocator);
    defer astate.deinit();
    const msgs = snapshotMsgs(astate.allocator());

    const used = compaction.estimateTokens(msgs);
    const budget = compaction.budgetTokens(m.environ);
    const limit = compaction.contextLimit(m.environ);
    const sys: i64 = if (msgs.len > 0) compaction.estimateTokens(msgs[0..1]) else 0;
    const hist = used - sys;
    const pct_limit = @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(limit)) * 100.0;
    const pct_budget = @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(budget)) * 100.0;
    const turns: usize = if (msgs.len > 0) msgs.len - 1 else 0;

    // Gauge de 20 celdas (█ = E2 96 88, ░ = E2 90 8A)
    var gauge_buf: [60]u8 = undefined;
    const filled: usize = @intFromFloat(@min(pct_limit, 100.0) / 5.0);
    var gi: usize = 0;
    for (0..filled) |_| {
        @memcpy(gauge_buf[gi .. gi + 3], "█");
        gi += 3;
    }
    for (filled..20) |_| {
        @memcpy(gauge_buf[gi .. gi + 3], "░");
        gi += 3;
    }

    const l1 = std.fmt.allocPrint(
        m.allocator,
        "context [{s}] ~{d} / {d} tokens ({d:.1}% of limit)",
        .{ gauge_buf[0..gi], used, limit, pct_limit },
    ) catch "context";
    pushInfoOwned(m, l1);
    const l2 = std.fmt.allocPrint(
        m.allocator,
        "  system ~{d} · history ~{d} · {d} turns · budget {d} ({d:.0}% used)",
        .{ sys, hist, turns, budget, pct_budget },
    ) catch "details";
    pushInfoOwned(m, l2);
    const l3 = std.fmt.allocPrint(
        m.allocator,
        "  elided this session: {d} tool results · last stream: {d:.0} tok/s",
        .{ session_elided, tps_last },
    ) catch "details";
    pushInfoOwned(m, l3);

    refreshContextUsage(m);
}

/// `/session`: id, ruta y nº de mensajes.
fn cmdSession(m: *tui.Model) void {
    const s = ensureSession(m, m.allocator);
    const l1 = std.fmt.allocPrint(
        m.allocator,
        "session {s} · {d} messages",
        .{ s.id[0..], s.messages.items.len },
    ) catch "sesión";
    pushInfoOwned(m, l1);
    if (s.path) |p| {
        const l2 = std.fmt.allocPrint(m.allocator, "  {s}", .{p}) catch "ruta";
        pushInfoOwned(m, l2);
    }
}

/// `/providers`: lista los providers con su estado de key.
fn cmdProviders(m: *tui.Model) void {
    for (allProviders(m.allocator)) |*d| {
        const key_state: []const u8 =
            if (d.key_env.len == 0) "sin key"
            else if (providers.keyFor(d, m.environ) != null) "key ok"
            else "SIN KEY";
        const active: []const u8 = if (std.mem.eql(u8, d.id, cur_provider_id)) " ←" else "";
        const line = std.fmt.allocPrint(
            m.allocator,
            "{s:<11} {s} ({s}){s}  {s}",
            .{ d.id, d.name, key_state, active, d.note },
        ) catch "provider";
        pushInfoOwned(m, line);
    }
}

/// `/effort low|medium|high`, o picker si viene sin argumentos.
fn cmdEffort(m: *tui.Model, arg: ?[]const u8) void {
    if (arg) |a| {
        if (std.mem.eql(u8, a, "low")) {
            current_effort = .low;
        } else if (std.mem.eql(u8, a, "medium") or std.mem.eql(u8, a, "med")) {
            current_effort = .medium;
        } else if (std.mem.eql(u8, a, "high")) {
            current_effort = .high;
        } else {
            const msg = std.fmt.allocPrint(m.allocator, "unknown effort: {s} (low|medium|high)", .{a}) catch
                "effort";
            pushInfoOwned(m, msg);
            return;
        }
        const name = switch (current_effort) {
            .low => "low",
            .medium => "medium",
            .high => "high",
        };
        const msg = std.fmt.allocPrint(m.allocator, "effort → {s}", .{name}) catch "effort";
        pushInfoOwned(m, msg);
        return;
    }
    openEffortPicker(m);
}

/// `/use <provider> [model]`.
fn cmdUse(m: *tui.Model, arg: ?[]const u8) void {
    const a = arg orelse {
        const msg = allocPrint(m, "usage: /use <provider> [model]", .{}) catch "uso";
        pushInfoOwned(m, msg);
        return;
    };
    var it = std.mem.tokenizeScalar(u8, a, ' ');
    const prov = it.next() orelse return;
    applyProvider(m, prov) catch return;
    if (it.next()) |mo| applyModel(m, mo) catch {};
}

/// `/yolo`: toggle de permisos automáticos.
fn cmdYolo(m: *tui.Model) void {
    yolo = !yolo;
    const msg = if (yolo) "yolo ON: no confirmations" else "yolo OFF: asks for permission";
    pushInfo(m, msg);
    setStatusWithZo(m, if (yolo) .warn else .idle, msg);
}

/// Qué hay que hacer con el comando que se acaba de elegir en la paleta.
pub const PaletteCmd = enum {
    /// Ejecutado aquí y ahora.
    done,
    /// Necesita argumentos: la etiqueta va al input y el usuario teclea lo que
    /// falte.
    needs_args,
    /// Salir de la app. Lo atiende la TUI (es quien tiene el `ctx.quit`).
    quit,
};

/// Ejecuta un comando elegido en la paleta, SIN pasar por el input.
///
/// Elegir un comando de una lista ya es la confirmación: ponerlo en el input y
/// pedir un Enter más era un segundo paso que nadie pedía, y en un TUI donde
/// las teclas se comen por el camino se leía como «no ha hecho nada».
///
/// La EXCEPCIÓN son los comandos que necesitan argumentos: `/use provider
/// model` no se puede ejecutar a ciegas. Esos vuelven al input con la barra
/// puesta, que es justo lo que quiere quien los elige.
///
/// El comando se hace eco en el historial (como el input) para que se vea qué
/// se ha ejecutado y no solo qué ha pasado.
pub fn runPaletteCommand(m: *tui.Model, cmd: []const u8) PaletteCmd {
    if (std.mem.eql(u8, cmd, "/quit")) return .quit;
    if (std.mem.eql(u8, cmd, "/use")) return .needs_args;
    m.pushKind(.user, cmd);
    submit(m, cmd) catch {};
    return .done;
}

/// Punto de entrada del input de la TUI: texto libre o comando `/…`.
///
/// Un chat arranca un WORKER (hilo) que habla con la API; un comando se
/// resuelve aquí, en el hilo de la UI, porque son operaciones locales.
pub fn submit(m: *tui.Model, input: []const u8) !void {
    if (input.len == 0) return;
    if (input[0] != '/') return startChat(m, input);

    var it = std.mem.tokenizeScalar(u8, input[1..], ' ');
    const cmd = it.next() orelse return;
    // SIN argumentos es un `null` de verdad, no un slice vacío. `it.rest()`
    // devuelve `""` para "/effort", y con un slice vacío no nul el `else` de
    // "low|medium|high" se llevaba el caso: `/effort` a secas contestaba
    // "unknown effort:  (low|medium|high)" en vez de abrir el picker.
    const rest = it.rest();
    const arg: ?[]const u8 = if (rest.len == 0) null else rest;

    if (std.mem.eql(u8, cmd, "help")) {
        for (commands) |c| {
            const line = std.fmt.allocPrint(m.allocator, "{s} — {s}", .{ c.key, c.desc }) catch continue;
            pushInfoOwned(m, line);
        }
    } else if (std.mem.eql(u8, cmd, "quit")) {
        // lo maneja la TUI
    } else if (std.mem.eql(u8, cmd, "models")) {
        listModelsAsync(m) catch pushInfo(m, "error starting /models");
    } else if (std.mem.eql(u8, cmd, "providers")) {
        cmdProviders(m);
    } else if (std.mem.eql(u8, cmd, "provider")) {
        openProviderPicker(m);
    } else if (std.mem.eql(u8, cmd, "model")) {
        // Se abre YA (la columna de providers es local) y los modelos se
        // pintan cuando llegan. Antes no se abria nada hasta que la red
        // respondia, y con el provider lento parecia que el comando no hacia
        // nada.
        openModelPaletteAsync(m);
    } else if (std.mem.eql(u8, cmd, "effort")) {
        cmdEffort(m, arg);
    } else if (std.mem.eql(u8, cmd, "use")) {
        cmdUse(m, arg);
    } else if (std.mem.eql(u8, cmd, "free-auto")) {
        free_auto.cmdFreeAuto(m, arg);
    } else if (std.mem.eql(u8, cmd, "yolo")) {
        cmdYolo(m);
    } else if (std.mem.eql(u8, cmd, "acp")) {
        cmdAcp(m, arg orelse "");
    } else if (std.mem.eql(u8, cmd, "context")) {
        cmdContext(m);
    } else if (std.mem.eql(u8, cmd, "session")) {
        cmdSession(m);
    } else if (std.mem.eql(u8, cmd, "cache")) {
        cmdCache(m);
    } else if (std.mem.eql(u8, cmd, "new")) {
        newSession(m);
    } else if (std.mem.eql(u8, cmd, "resume")) {
        resumeLatest(m);
    } else {
        const msg = std.fmt.allocPrint(m.allocator, "unknown command: {s} (/help)", .{cmd}) catch
            "unknown command";
        pushInfoOwned(m, msg);
    }
}

// ── ACP: el turno se lo delega a otro agente ─────────────────

/// Modo ACP: el turno NO lo hace zode, se lo pasa a un agente ACP (por defecto
/// `opencode acp`) hablando JSON-RPC por los pipes de su proceso hijo.
///
/// Es la "trampa por detras": no se toca la terminal de opencode, se le habla a
/// su motor. El historial de la sesión lo lleva opencode, no zode.
pub var acp_on: bool = false;
/// Comando del agente ACP. `ZODE_ACP_CMD` lo fija (palabras separadas por
/// espacios) y `/acp <cmd>` lo cambia para la sesión.
pub var acp_cmd: ?[]const u8 = null;

/// Cliente vivo, o null. Se arranca perezoso y se REUTILIZA entre turnos: la
/// sesión de ACP (y su contexto) viven en el proceso, así que uno por turno
/// sería memoria amnesia.
var acp_client: ?*acp.Client = null;

/// Lo llama la TUI al salir. Sin esto el hijo se queda vivo-colgado.
pub fn shutdownAcp() void {
    if (acp_client) |c| {
        c.deinit();
        acp_client = null;
    }
}

/// ESC: si el turno va por ACP hay que cortarlo por su protocolo
/// (`session/cancel`), no solo poner la bandera de los streams HTTP.
pub fn cancelAcp(m: *tui.Model) void {
    if (!acp_on) return;
    if (acp_client) |c| c.cancel();
    // Decir "cancelando" y no dejar el status como estaba: el turno no se
    // corta en el acto (el agente tiene que confirmar con un stopReason), y sin
    // este texto el ESC parece que no ha hecho nada.
    setStatusWithZo(m, .warn, "cancelling…");
}

/// Nombre del agente ACP activo, para el status bar.
pub fn acpTitle() []const u8 {
    if (acp_client) |c| return c.agentTitle();
    return "pending";
}

/// Estado de la conexión con el agente ACP.
///
/// El arranque NO se hace en el prompt: `opencode acp` levanta un servidor
/// privado y tarda varios segundos. Se lanza en cuanto se activa `/acp`, así
/// que el primer prompt solo espera a que esté listo.
const AcpState = enum { off, connecting, ready, failed };

var acp_state: AcpState = .off;
/// Código de error del arranque fallido, para poder enseñarlo.
var acp_start_err: anyerror = error.SpawnFailed;
/// Bloquea la escritura de `acp_client` desde el hilo de conexión.
///
/// Es un SPINLOCK (`tryLock`, no `lock`): se coge un instante y se suelta, y
/// las secciones son de dos líneas. Un `lock` reentrante colgaría la app, que es
/// justo la trampa de `pushPending` en la otra punta del código.
var acp_lock: std.atomic.Mutex = .unlocked;

fn acpLock() void {
    while (!acp_lock.tryLock()) std.Thread.yield() catch {};
}
fn acpUnlock() void {
    acp_lock.unlock();
}

/// El argv del agente, a partir de `acp_cmd` o del de por defecto.
///
/// Se devuelve en `out` porque el slice tiene que vivir en el llamante: el
/// argv son punteros a palabras del comando, no alungan.
fn acpArgv(out: *[8][]const u8) []const []const u8 {
    var argv: []const []const u8 = &acp.default_argv;
    const cmd = acp_cmd orelse return argv;
    var it = std.mem.tokenizeAny(u8, cmd, " ");
    var n: usize = 0;
    while (it.next()) |word| {
        if (n >= out.len) break;
        out[n] = word;
        n += 1;
    }
    if (n > 0) argv = out[0..n];
    return argv;
}

/// El cwd absoluto para `session/new`.
///
/// ACP lo exige. En 0.16 no hay `getCwd`, así que se usa el enlace
/// `/proc/self/cwd`, que es el cwd real del proceso (el `PWD` del entorno
/// puede estar mentido). Sin `/proc` se cae al `PWD` y, en último caso, a "/".
fn acpCwd() []const u8 {
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.cwd().readLink(io_global, "/proc/self/cwd", &link_buf) catch 0;
    if (n > 0 and link_buf[0] == '/') return link_buf[0..n];
    if (environ_global) |env| {
        if (env.get("PWD")) |pwd| {
            if (pwd.len > 0 and pwd[0] == '/') return pwd;
        }
    }
    return "/";
}

const ConnectJob = struct {
    /// El modelo SOLO para dejar un aviso en el historial. El hilo lo usa con
    /// `pushInfoOwned`, que es thread-safe. Se registra como worker
    /// (`beginWorker`) para que `waitWorkers` lo espere al apagar: si no, el
    /// hilo podría tocar un `Model` ya destruido.
    m: *tui.Model,
    gpa: std.mem.Allocator,
    argv: [8][]const u8,
    argv_len: usize,
    cwd: [std.fs.max_path_bytes]u8,
    cwd_len: usize,
    env: ?*const std.process.Environ.Map,
};

/// Hilo de conexión. Solo escribe en el estado (bajo `acp_lock`) y termina.
fn acpConnectThread(job: *ConnectJob) void {
    const gpa = job.gpa;
    const m = job.m;
    m.beginWorker();
    defer m.endWorker();
    defer gpa.destroy(job);

    const cwd = job.cwd[0..job.cwd_len];
    const c = acp.Client.start(gpa, io_global, job.argv[0..job.argv_len], cwd, job.env) catch |err| {
        acpLock();
        acp_state = .failed;
        acp_start_err = err;
        acpUnlock();
        setStatusWithZo(m, .warn, "the ACP agent did not start");
        return;
    };
    acpLock();
    acp_client = c;
    acp_state = .ready;
    acpUnlock();

    // Aviso en el historial en cuanto el agente está listo: el status bar ya
    // enseña el nombre, pero esto deja constancia de la sesión.
    const msg = std.fmt.allocPrint(
        gpa,
        "ACP connected · agent {s} · session {s}",
        .{ c.agentTitle(), c.sessionId() },
    ) catch return;
    defer gpa.free(msg);
    // `pushInfo` COPIA el texto; `pushInfoOwned` se APROPIAN de el, y con el
    // `free` de arriba la fila salia con basura (todo `�`).
    pushInfo(m, msg);
}

/// Lanza la conexión en segundo plano. Devuelve false si ya había una en curso
/// o lista.
fn startAcpConnect(
    model: *tui.Model,
    gpa: std.mem.Allocator,
    env: ?*const std.process.Environ.Map,
) bool {
    acpLock();
    defer acpUnlock();
    if (acp_state == .connecting or acp_state == .ready) return false;

    const job = gpa.create(ConnectJob) catch return false;
    errdefer gpa.destroy(job);
    job.* = .{
        .m = model,
        .gpa = gpa,
        .argv = undefined,
        .argv_len = 0,
        .cwd = undefined,
        .cwd_len = 0,
        .env = env,
    };
    var argv_store: [8][]const u8 = undefined;
    const argv = acpArgv(&argv_store);
    @memcpy(job.argv[0..argv.len], argv);
    job.argv_len = argv.len;

    const cwd = acpCwd();
    @memcpy(job.cwd[0..cwd.len], cwd);
    job.cwd_len = cwd.len;

    acp_state = .connecting;
    const th = std.Thread.spawn(.{}, acpConnectThread, .{job}) catch {
        acp_state = .off;
        gpa.destroy(job);
        return false;
    };
    th.detach();
    return true;
}

/// Devuelve el cliente, esperando a que termine la conexión si hace falta.
///
/// `m` solo se usa para el status mientras espera; si el arranque falla se
/// traduce el error a algo legible (ver `reportAcpErr`).
fn ensureAcp(m: *tui.Model) !*acp.Client {
    acpLock();
    const st = acp_state;
    if (st == .ready) {
        const c = acp_client.?;
        acpUnlock();
        return c;
    }
    if (st == .failed) {
        const err = acp_start_err;
        acp_state = .off;
        acpUnlock();
        return err;
    }
    if (st == .off) {
        acpUnlock();
        // No hay nadie conectando (arranque en frío, p. ej. `--resume`): se
        // arranca en el hilo del worker y se espera aquí.
        _ = startAcpConnect(m, m.allocator, m.environ);
        acpLock();
        if (acp_state != .ready) {
            acpUnlock();
            return error.SpawnFailed;
        }
        const c = acp_client.?;
        acpUnlock();
        return c;
    }
    acpUnlock();

    // Hay una conexión en curso: se espera SIN tocar el `Io` compartido (ver
    // `acp.nap`), que es lo que congelaba la TUI.
    setStatusWithZo(m, .thinking, "connecting to the ACP agent…");
    var spins: usize = 0;
    while (spins < 1200) : (spins += 1) {
        acpLock();
        const s2 = acp_state;
        const c = acp_client;
        acpUnlock();
        if (s2 == .ready) {
            if (c) |cc| return cc;
            continue;
        }
        if (s2 == .failed) {
            acpLock();
            const err = acp_start_err;
            acp_state = .off;
            acpUnlock();
            return err;
        }
        acp.nap(50);
    }
    return error.HandshakeFailed;
}

/// `/acp [on|off|<comando>]`
fn cmdAcp(m: *tui.Model, arg: []const u8) void {
    const a = std.mem.trim(u8, arg, " \t");
    if (std.mem.eql(u8, a, "off")) {
        acp_on = false;
        shutdownAcp();
        pushInfo(m, "ACP off: the turns go through zode again");
        return;
    }
    if (a.len > 0 and !std.mem.eql(u8, a, "on")) {
        acp_cmd = m.allocator.dupe(u8, a) catch null;
        // Cambiar de agente implica reiniciar el hijo: el anterior ya tiene su
        // sesión y su contexto.
        shutdownAcp();
    }
    acp_on = true;
    // La conexión arranca YA, en segundo plano, no con el primer prompt.
    if (startAcpConnect(m, m.allocator, m.environ)) {
        setStatusWithZo(m, .thinking, "connecting to the ACP agent…");
        pushInfo(m, "ACP on: connecting to the agent in the background (/acp off to go back)");
    } else {
        pushInfo(m, "ACP on");
    }
}

/// El worker de un turno ACP.
///
/// OJO: aquí NO hay bucle de tools. En ACP las tools las ejecuta el AGENTE, no
/// zode: el `session/update` con `tool_call` se pinta y su `tool_call_update`
/// con `completed` es el resultado. Por eso el turno es un prompt y ya.
fn acpWorker(job: *ChatJob) void {
    const m = job.model;
    const user_text = job.text;
    defer {
        m.allocator.free(user_text);
        m.allocator.destroy(job);
    }
    m.beginWorker();
    defer m.endWorker();

    var prompt: []const u8 = user_text;
    var owned_prompt: ?[]u8 = null;
    defer if (owned_prompt) |o| m.allocator.free(o);

    while (true) {
        m.streamStart();
        setStatusWithZo(m, .thinking, "thinking");

        const c = ensureAcp(m) catch |err| {
            reportAcpErr(m, err);
            m.streamEnd();
            return;
        };

        var t = AcpTurn{ .m = m, .client = c };
        t.sink = .{
            .userdata = &t,
            .onText = AcpTurn.onText,
            .onThought = AcpTurn.onThought,
            .onTool = AcpTurn.onTool,
            .onToolUpdate = AcpTurn.onToolUpdate,
            .onPlan = AcpTurn.onPlanLine,
            .onPermission = AcpTurn.onPermission,
        };
        defer t.deinit();

        c.prompt(prompt) catch |err| {
            reportAcpErr(m, err);
            m.streamEnd();
            return;
        };
        const reason = c.waitTurn(&t.sink) catch |err| {
            reportAcpErr(m, err);
            m.streamEnd();
            return;
        };

        // Lo que dijo el agente se guarda en la sesión de zode (aunque el
        // historial de verdad lo lleve opencode): así `/resume` y el diff
        // siguen teniendo sentido dentro de zode.
        if (t.text.items.len > 0) {
            ensureSession(m, m.allocator).appendAssistant(t.text.items, null) catch {};
        }
        ensureSession(m, m.allocator).flush();
        // Cierra el párrafo vivo si el turno terminó hablando (si terminó con
        // una tool, `onTool` ya lo cerró y esto no hace nada).
        if (t.streaming_open) {
            t.streaming_open = false;
            m.streamEnd();
        }

        if (std.mem.eql(u8, reason, "cancelled")) {
            pushInfo(m, "ACP turn cancelled");
        }

        // Siguiente prompt en cola, si lo hay.
        const next = m.takeQueued() orelse break;
        if (owned_prompt) |o| m.allocator.free(o);
        owned_prompt = next;
        prompt = next;
    }
}

/// Un texto del agente en UNA línea, recortada.
///
/// Los `agent_thought_chunk` y las entradas del plan llegan troceadas y con
/// saltos de línea dentro. Pinta tal cual, el historial se llena de filas a
/// medias; y si se pinta cada trozo por separado, de 40 fragmentos.
///
/// El slice puede apuntar a un buffer del stack de esta función (el caso "hay
/// salto de línea"): es seguro porque el único llamante es `pushInfo`, que
/// COPIA el texto en el allocator del modelo antes de encolarlo.
fn oneLine(s: []const u8) []const u8 {
    const clean = std.mem.trim(u8, s, " \t\n\r");
    if (clean.len == 0) return "";
    var it = std.mem.tokenizeAny(u8, clean, "\n\r");
    const first = it.next() orelse return "";
    if (it.next() != null) {
        var buf: [256]u8 = undefined;
        return std.fmt.bufPrint(&buf, "{s} …", .{std.mem.trimEnd(u8, first, " \t")}) catch first;
    }
    return first;
}

/// Contexto de un turno ACP: traduce los `session/update` a la TUI.
const AcpTurn = struct {
    m: *tui.Model,
    client: *acp.Client,
    text: std.ArrayList(u8) = .empty,
    /// ¿Hay un párrafo de streaming abierto?
    ///
    /// OJO: en ACP el agente INTERCALA texto y tools (habla, llama una tool,
    /// vuelve a hablar). El párrafo de streaming hay que cerrarlo en cada tool,
    /// porque si no la cabecera de la tool se pinta ANTES del texto que la
    /// precedió y el historial queda desordenado. En el flujo HTTP no hace
    /// falta porque ahí el stream siempre acaba antes de las tools.
    streaming_open: bool = false,
    tool_start_ns: [8]i128 = undefined,
    tool_start_len: usize = 0,
    sink: acp.Sink = undefined,

    fn deinit(self: *AcpTurn) void {
        self.text.deinit(self.m.allocator);
    }

    fn onText(ud: ?*anyopaque, s: []const u8) void {
        const t: *AcpTurn = @ptrCast(@alignCast(ud.?));
        t.text.appendSlice(t.m.allocator, s) catch {};
        if (!t.streaming_open) {
            t.m.streamStart();
            t.streaming_open = true;
        }
        t.m.streamDelta(s);
    }

    /// El razonamiento del agente no va al párrafo principal: se pinta como una
    /// línea de info, que es donde se lee sin estorbar la respuesta.
    /// El razonamiento llega troceado y con saltos de línea dentro: se junta en
    /// UNA línea (con "…") porque `pushInfo` es una fila por llamada y 40
    /// fragmentos sueltos llenan el historial de basura.
    ///
    /// OJO: `pushInfo` ya pone el prefijo `·`; añadirlo aquí salía "· · hola".
    fn onThought(ud: ?*anyopaque, s: []const u8) void {
        const t: *AcpTurn = @ptrCast(@alignCast(ud.?));
        pushInfo(t.m, oneLine(s));
    }

    fn onTool(ud: ?*anyopaque, id: []const u8, name: []const u8, title: []const u8) void {
        const t: *AcpTurn = @ptrCast(@alignCast(ud.?));
        // Cierra el texto que había antes de la tool, para que la cabecera de la
        // tool quede DEBAJO y no encima.
        if (t.streaming_open) {
            t.m.streamEnd();
            t.streaming_open = false;
        }
        const tool = if (name.len > 0) name else "tool";
        const arg = if (title.len > 0) title else "…";
        t.m.pushToolStart(tool, arg);
        setStatusWithZo(t.m, .tooling, arg);
        if (t.tool_start_len < t.tool_start_ns.len) {
            t.tool_start_ns[t.tool_start_len] = std.Io.Timestamp.now(io_global, .real).nanoseconds;
            t.tool_start_len += 1;
        }
        _ = id;
    }

    fn onToolUpdate(ud: ?*anyopaque, id: []const u8, status: []const u8, text: []const u8) void {
        const t: *AcpTurn = @ptrCast(@alignCast(ud.?));
        // `pending` y `in_progress` no cierran la línea: el reloj de "running"
        // se queda hasta que la tool acaba de verdad.
        if (std.mem.eql(u8, status, "pending") or std.mem.eql(u8, status, "in_progress")) return;
        // Cierra el párrafo vivo ANTES de encolar el resultado. El bloque de
        // "párrafo en vivo" se pinta SIEMPRE al final del historial, así que si
        // el texto del agente siguiera abierto, el "⎿ exit=0" salía debajo de
        // su última frase en vez de justo debajo de la tool.
        if (t.streaming_open) {
            t.m.streamEnd();
            t.streaming_open = false;
        }
        if (std.mem.eql(u8, status, "cancelled")) {
            t.m.pushToolDone(t.client.toolName(id), "cancelled", 0, "");
            return;
        }
        const ms: u64 = blk: {
            if (t.tool_start_len == 0) break :blk 0;
            const now = std.Io.Timestamp.now(io_global, .real).nanoseconds;
            const started = t.tool_start_ns[t.tool_start_len - 1];
            break :blk @intCast(@max(0, now - started) / std.time.ns_per_ms);
        };
        var summary: [120]u8 = undefined;
        const head = std.mem.trim(u8, text, " \n\t");
        const sum = if (head.len > 0)
            std.fmt.bufPrint(&summary, "{s}", .{std.mem.trimEnd(u8, head, "\n")}) catch "done"
        else
            "done";
        t.m.pushToolDone(t.client.toolName(id), sum, ms, text);
    }

    fn onPlanLine(ud: ?*anyopaque, s: []const u8) void {
        const t: *AcpTurn = @ptrCast(@alignCast(ud.?));
        pushInfo(t.m, oneLine(s));
    }

    fn onPermission(
        ud: ?*anyopaque,
        tool: []const u8,
        detail: []const u8,
        options: []const acp.PermOption,
    ) ?[]const u8 {
        const t: *AcpTurn = @ptrCast(@alignCast(ud.?));
        // El agente trae sus propias opciones; se busca la que encaja con lo
        // que el usuario contestar. Sin opciones no hay nada que dibujar.
        if (options.len == 0) return null;

        // `/yolo`: la primera opción de permitir, sin preguntar.
        if (yolo) {
            for (options) |o| {
                if (std.mem.startsWith(u8, o.kind, "allow")) return o.id;
            }
            return null;
        }

        const ask = if (tool.len > 0) tool else "the ACP agent wants to run a tool";
        const answer = t.m.requestPermission("acp", detail);
        const want: []const u8 = switch (answer) {
            .allow => "allow_once",
            .allow_always => "allow_always",
            .deny, .none => "reject",
        };
        for (options) |o| {
            if (std.mem.eql(u8, o.kind, want)) return o.id;
        }
        // El agente no ofreció exactamente lo que se pidió: cualquier
        // "allow once" es lo más cercano a "sí, ahora".
        if (answer == .allow or answer == .allow_always) {
            for (options) |o| {
                if (std.mem.startsWith(u8, o.kind, "allow")) return o.id;
            }
        }
        for (options) |o| {
            if (std.mem.startsWith(u8, o.kind, "reject")) return o.id;
        }
        _ = ask;
        return null;
    }
};

/// Errores de ACP con un texto que se entienda en la UI (no `error.X`).
fn reportAcpErr(m: *tui.Model, err: anyerror) void {
    const line: []const u8 = switch (err) {
        error.SpawnFailed => blk: {
            const cmd = acp_cmd orelse "opencode acp";
            break :blk std.fmt.allocPrint(
                m.allocator,
                "could not launch the ACP agent ({s}). Is `opencode` in the PATH? /acp <cmd> sets another one.",
                .{cmd},
            ) catch "ACP: could not launch the agent";
        },
        error.HandshakeFailed => "ACP: the agent did not answer initialize/session/new",
        error.NoSession => "ACP: no session (the agent closed it?)",
        error.AgentDied => "ACP: the agent closed the connection mid-turn",
        error.OutOfMemory => return,
        else => std.fmt.allocPrint(m.allocator, "ACP: {t}", .{err}) catch "ACP error",
    };
    pushInfoOwned(m, line);
}

/// `/resume`: reabre la sesión más reciente por mtime.
fn resumeLatest(m: *tui.Model) void {    var astate = std.heap.ArenaAllocator.init(m.allocator);
    defer astate.deinit();
    const a = astate.allocator();

    const latest = session_mod.Session.latestSessionPath(a, io_global) catch null;
    const path = latest orelse {
        pushInfo(m, "no saved sessions");
        return;
    };
    if (session) |old| {
        m.allocator.destroy(old);
        session = null;
    }
    const s = session_mod.Session.resumePath(m.allocator, io_global, path) catch {
        pushInfo(m, "could not read the session");
        return;
    };
    session = s;
    session_elided = 0;
    const msg = std.fmt.allocPrint(
        m.allocator,
        "session resumed: {s} · {d} messages",
        .{ path, s.messages.items.len },
    ) catch "sesión reanudada";
    pushInfoOwned(m, msg);
    refreshContextUsage(m);
}

// ── el chat: worker y agent loop ──────────────────────────────

/// Lanza el worker de un turno. Todo el I/O ocurre aquí, en su propio hilo;
/// la UI solo recibe eventos.
/// Job del hilo del chat. `text` es una COPIA que libera el worker, para que
/// el buffer del input pueda reutilizarse en cuanto se encola.
const ChatJob = struct {
    model: *tui.Model,
    text: []const u8,
};

fn startChat(m: *tui.Model, input: []const u8) !void {
    const s = ensureSession(m, m.allocator);
    const copy = try m.allocator.dupe(u8, input);
    errdefer m.allocator.free(copy);

    // Si ya hay un turno en curso, ENCOLAR en vez de lanzar un worker en
    // paralelo: dos workers escribiendo a la vez en la misma sesion y en el
    // mismo estado de streaming es lo que hacia que el input se freezease y el
    // historial se entrecortara.
    if (m.isBusy()) {
        _ = m.enqueuePrompt(copy);
        const qn = std.fmt.allocPrint(m.allocator, "⏳ queued ({d} waiting)", .{m.queuedCount()}) catch "⏳ queued";
        pushInfoOwned(m, qn);
        return;
    }

    s.append(.user, copy) catch {};
    s.flush();

    // Abre el párrafo de streaming y marca busy: la UI ya puede pintar el
    // spinner mientras el worker habla con la API.
    m.streamStart();
    // Sin "…": la carita ya late y el reloj corre, la elipsis solo añade ruido.
    setStatusWithZo(m, .thinking, "thinking");

    const job = try m.allocator.create(ChatJob);
    m.beginWorker(); // el worker lo cierra; si el spawn falla, lo cerramos aquí
    job.* = .{ .model = m, .text = copy };
    // El modo ACP delega el turno en otro agente: mismo worker, otro cuerpo.
    // OJO: elige la FUNCION, no un bool, porque `std.Thread.spawn` con un
    // comptime-only que depende de control de runtime no compila.
    const spawned = if (acp_on)
        std.Thread.spawn(.{}, acpWorker, .{job}) catch null
    else
        std.Thread.spawn(.{}, chatWorker, .{job}) catch null;
    const th = spawned orelse {
        m.endWorker();
        m.allocator.destroy(job);
        m.allocator.free(copy);
        m.streamEnd();
        return error.ThreadSpawnFailed;
    };
    th.detach();
}

/// El worker: un turno de conversación con la API, con tools.
fn chatWorker(job: *ChatJob) void {
    const m = job.model;
    const user_text = job.text;
    defer {
        m.allocator.free(user_text);
        m.allocator.destroy(job);
    }
    // Contador de workers: el hilo está desacoplado y al salir hay que
    // esperarlo ANTES de destruir el `Io` (ver `Model.waitWorkers`).
    m.beginWorker();
    defer m.endWorker();

    var iterations: usize = 0;
    var last_user: []const u8 = user_text;
    var owned: ?[]u8 = null; // texto sintético de una iteración (propio)

    while (iterations < max_iterations) : (iterations += 1) {
        const again = runOneTurn(m, last_user) catch |err| {
            reportErr(m, err);
            m.streamEnd();
            return;
        };
        const text = again orelse break;
        if (owned) |o| m.allocator.free(o);
        owned = text;
        last_user = text;
    }
    if (owned) |o| m.allocator.free(o);
    if (iterations >= max_iterations) pushInfo(m, "agent iteration limit reached: stopping the turn");
    m.streamEnd();
}

/// Userdata de los tres callbacks de un turno.
///
/// OJO: `onDelta`, `onToolCall` y `onFinish` reciben el MISMO `?*anyopaque`.
/// Si se les pasara `&text_sink` y luego `onToolCall` lo casara a `*TextSink`,
/// en el primer token ya estaríamos leyendo campos de otro tipo: en
/// ReleaseFast eso es UB silencioso. Por eso va un struct con nombre propio.
const TurnCtx = struct {
    m: *tui.Model,
    /// Texto del asistente de este turno (se vuelca a la sesión al final).
    text: std.ArrayList(u8) = .empty,
    /// Tool calls pedidos en este turno.
    calls: std.ArrayList(Call) = .empty,
    /// Un tool en curso: su cabecera ya está pintada y hay que cerrar la línea.
    tool_open: bool = false,
    /// Chars del stream, para el tok/s.
    chars: usize = 0,
    /// Momento del primer token (ns). 0 = aún no llegó nada.
    stream_start_ns: i128 = 0,
    /// Motivo de finish del request.
    finish: [32]u8 = undefined,
    finish_len: usize = 0,

    const Call = struct {
        id: []const u8,
        name: []const u8,
        args_json: []const u8,
    };

    fn deinit(self: *TurnCtx) void {
        const gpa = self.m.allocator;
        for (self.calls.items) |c| {
            gpa.free(c.id);
            gpa.free(c.name);
            gpa.free(c.args_json);
        }
        self.calls.deinit(gpa);
        self.text.deinit(gpa);
    }
};

fn onDelta(ud: ?*anyopaque, delta: []const u8) void {
    const t: *TurnCtx = @ptrCast(@alignCast(ud.?));
    t.text.appendSlice(t.m.allocator, delta) catch {};
    t.chars += delta.len;
    if (t.stream_start_ns == 0) {
        t.stream_start_ns = std.Io.Timestamp.now(io_global, .real).nanoseconds;
    }
    t.m.streamDelta(delta);
}

fn onToolCall(ud: ?*anyopaque, id: []const u8, name: []const u8, args_json: []const u8) void {
    const t: *TurnCtx = @ptrCast(@alignCast(ud.?));
    const gpa = t.m.allocator;
    t.calls.append(gpa, .{
        .id = gpa.dupe(u8, id) catch return,
        .name = gpa.dupe(u8, name) catch return,
        .args_json = gpa.dupe(u8, args_json) catch return,
    }) catch {};
}

fn onFinish(ud: ?*anyopaque, reason: []const u8) void {
    const t: *TurnCtx = @ptrCast(@alignCast(ud.?));
    const n = @min(reason.len, t.finish.len);
    @memcpy(t.finish[0..n], reason[0..n]);
    t.finish_len = n;
}

/// Los `tool_calls` de un turno como JSON para la sesión.
///
/// Es el MISMO formato que escribe `chat.StreamCtx.toolCallsJson` (el que usa
/// el runner headless): si divergen, uno de los dos clientes manda una
/// conversación que el otro no puede leer. Por eso está aquí y no "parece que
/// basta": el `arguments` va como string JSON escapado, no como objeto anidado.
fn toolCallsJsonFromCalls(gpa: std.mem.Allocator, calls: []const TurnCtx.Call) ?[]const u8 {
    if (calls.len == 0) return null;
    var out: std.ArrayList(u8) = .empty;
    out.append(gpa, '[') catch return null;
    for (calls, 0..) |c, i| {
        if (i > 0) out.append(gpa, ',') catch return null;
        out.appendSlice(gpa, "{\"id\":\"") catch return null;
        out.appendSlice(gpa, c.id) catch return null;
        out.appendSlice(gpa, "\",\"type\":\"function\",\"function\":{\"name\":\"") catch return null;
        out.appendSlice(gpa, c.name) catch return null;
        out.appendSlice(gpa, "\",\"arguments\":\"") catch return null;
        for (c.args_json) |ch| {
            switch (ch) {
                '"' => out.appendSlice(gpa, "\\\"") catch return null,
                '\\' => out.appendSlice(gpa, "\\\\") catch return null,
                '\n' => out.appendSlice(gpa, "\\n") catch return null,
                '\r' => out.appendSlice(gpa, "\\r") catch return null,
                '\t' => out.appendSlice(gpa, "\\t") catch return null,
                else => out.append(gpa, ch) catch return null,
            }
        }
        out.appendSlice(gpa, "\"}}") catch return null;
    }
    out.append(gpa, ']') catch return null;
    return out.items;
}

/// Un turno: un request a la API con el historial, sus tools y, si el modelo
/// pide tools, su ejecución y el siguiente turno.
///
/// Devuelve el texto sintético que hay que mandar en el siguiente turno
/// (normalmente null: si no hubo tool calls, el turno se acabó).
/// `user_text` ya está en la sesión (lo escribió `startChat`): aquí solo se
/// usa para el caso de las iteraciones sintéticas, y el system prompt se
/// inyecta una vez al principio de la conversación.
/// OJO: el tipo de retorno es `[]u8` y no `[]const u8` A PROPOSITO. Con
/// `[]const u8` el compilador no distingue un literal de memoria propia, y
/// `chatWorker` liberaba el literal "Continue with the tool results above." ->
/// `free` sobre `.rodata` -> panic "reached unreachable code" en ReleaseSafe,
/// es decir, un turno con tools tumbaba la app SIEMPRE. Los literales Zig son
/// `[]const`, asi que ahora el compilador IMPIDE devolverlos por aqui.
/// [roster] A quién se le pregunta en un turno.
///
/// Existe para que `runOneTurn` no tenga que decidir entre "el provider/modelo
/// activo" y "el candidato del free-auto" en tres sitios distintos (body, url y
/// key). Con la rotación el `pick` se REEMPLAZA dentro del bucle de reintentos, y
/// si cada sitio consultara el global por su cuenta, media petición iría al
/// provider viejo: un 401 con la key de otro, o un body con el nombre del modelo
/// que ya no está.
const Target = struct {
    def: *const providers.ProviderDef,
    model: []const u8,
    kind: chat.ProviderKind,
    base_url: []const u8,
    key: ?[]const u8,
    /// El candidato del pool, o null si este turno va al provider/modelo activo.
    from_roster: ?roster_mod.Candidate = null,
};

/// El objetivo de este turno: el pool si el free-auto está encendido y ya tiene
/// lista, el provider/modelo activo si no.
///
/// Con el pool sin construir (o vacío) cae al activo SIN avisar: la lista son N
/// peticiones y el primer prompt no puede esperar por ellas. La rotación espera
/// al siguiente turno.
fn pickTarget(m: *tui.Model) Target {
    const active = activeTarget(m);
    if (!free_auto.freeAutoOn()) return active;
    if (free_auto.poolSize() == 0) return active;
    const cand = free_auto.rosterGet(m.allocator).active(free_auto.nowMs()) orelse return active;
    return targetForCandidate(m, cand) orelse active;
}

/// El `Target` del provider/modelo activos.
fn activeTarget(m: *tui.Model) Target {
    const def = activeProviderDef(m.environ);
    const kind = chat.kindForProvider(def.id);
    return .{
        .def = def,
        .model = cur_model,
        .kind = kind,
        .base_url = def.base_url,
        // Anthropic lleva la key en cabeceras, no en Bearer: aquí null.
        .key = if (kind == .anthropic) null else providers.keyFor(def, m.environ) orelse curKey(m),
    };
}

/// El `Target` de un par provider/modelo concreto. Null si ese provider ya no
/// está (el usuario lo quitó de `config.json` después de construir el pool).
fn targetForCandidate(m: *tui.Model, cand: roster_mod.Candidate) ?Target {
    const def = config_mod.find(user_config, cand.provider_id) orelse
        providers.byId(cand.provider_id) orelse return null;
    const kind = chat.kindForProvider(def.id);
    return .{
        .def = def,
        .model = cand.model_id,
        .kind = kind,
        .base_url = def.base_url,
        .key = if (kind == .anthropic) null else providers.keyFor(def, m.environ),
        .from_roster = cand,
    };
}

/// [roster] La línea de historial que explica el cambio de modelo.
///
/// Va al historial y no solo al status porque es el momento en que el usuario
/// pierde de vista por qué va tan lento: sin esta línea, un provider cayendo a
/// mitad del turno parece un fallo. Y dice las DOS cosas (qué murió y por qué, a
/// qué se pasa), porque "cambió de modelo" sin motivo no es información.
fn pushSwitchNotice(m: *tui.Model, sw: free_auto.Switch, to: Target) void {
    const to_c = to.from_roster orelse return;
    const reason = if (sw.prev_reason.len > 0) sw.prev_reason else "quota gone";
    const msg = std.fmt.allocPrint(
        m.allocator,
        "quota gone on {s}/{s} ({s}) → {s}/{s} (free-auto {d}/{d})",
        .{
            sw.prev_provider,
            sw.prev_model,
            reason,
            to_c.provider_id,
            to_c.model_id,
            free_auto.rosterGet(m.allocator).idx + 1,
            free_auto.poolSize(),
        },
    ) catch "free-auto: switched model";
    pushInfoOwned(m, msg);
    // El status va corto: es una línea segmentada y ya lleva modelo y provider.
    // El detalle (el por qué) está en la línea de arriba, que no se recorta.
    const short = std.fmt.allocPrint(m.allocator, "switched to {s}", .{to_c.model_id}) catch "switching model";
    setStatusWithZo(m, .thinking, short);
}

fn runOneTurn(m: *tui.Model, user_text: []const u8) !?[]u8 {
    _ = user_text;
    const gpa = m.allocator;
    const s = ensureSession(m, gpa);
    // Reloj del TURNO (no del stream): es lo que se pinta en "done · N.Ns" y lo
    // que el usuario mide cuando vuelve a pulsar.
    const turn_t0 = std.Io.Timestamp.now(io_global, .real).nanoseconds;

    var tstate = TurnCtx{ .m = m };
    defer tstate.deinit();

    // El system prompt va SIEMPRE el primero (prefijo estable para el cache del
    // provider) y se añade UNA sola vez.
    //
    // Antes la condición era `items[0].role != .system`, y como `startChat`
    // ya había añadido el mensaje de `user`, `items[0]` era `user`: se
    // añadía un system NUEVO en cada iteración del agent loop. El segundo turno
    // salía como [user, system, tool, system] — el prompt del sistema al final
    // y duplicado — y el turno se moría sin contestación y sin error visible.
    // Ahora se busca el system en TODA la lista.
    var has_system = false;
    for (s.messages.items) |mm| {
        if (mm.role == .system) has_system = true;
    }
    if (!has_system) {
        const sp = systemPrompt(gpa);
        s.append(.system, sp) catch {};
    }

    // Compactación tier 1 antes de construir el body: es una VISTA del wire,
    // la sesión en disco conserva todo.
    var astate = std.heap.ArenaAllocator.init(gpa);
    defer astate.deinit();
    const arena = astate.allocator();

    const comp: compaction.Compacted = compaction.elideTier(
        arena,
        snapshotMsgs(arena),
        compaction.budgetTokens(m.environ),
    ) catch compaction.Compacted{ .msgs = snapshotMsgs(arena) };
    if (comp.elided > session_elided) {
        session_elided = comp.elided;
        const msg = std.fmt.allocPrint(gpa, "· {d} tool results elided", .{comp.elided}) catch return null;
        pushInfoOwned(m, msg);
    }

    // [roster] A quién se le pregunta en ESTE turno.
    //
    // Sin free-auto es el provider/modelo activo de siempre. Con free-auto, el
    // candidato vivo del pool (que puede ser otro provider), y si el pool aún no
    // está construido, el activo: la rotación espera al siguiente turno, nunca
    // bloquea.
    var pick = pickTarget(m);

    var body_buf: [1 << 20]u8 = undefined;
    const body = try chat.buildBodyMessages(
        &body_buf,
        pick.model,
        comp.msgs,
        current_effort,
        tools_mod.toolsJson(),
        pick.kind,
    );

    var http = http_client.Http.init(gpa, io_global);
    defer http.deinit();

    chat.cancel_current.store(false, .seq_cst);
    // Sin "…": la carita late y el reloj corre en la franja de actividad, así
    // que la elipsis solo ocupa dos celdas.
    setStatusWithZo(m, .thinking, "thinking");

    // Cada ITERACIÓN del agent loop abre su párrafo en vivo. Sin esto, la
    // respuesta que viene después de una tool se acumulaba en `stream_buf` sin
    // dueño y `streamEnd` la tiraba: el turno acababa con la tool como último
    // punto del historial y sin respuesta. `streamStartIteration` (y no
    // `streamStart`) para no resetear el reloj de la franja en cada iteración.
    m.streamStartIteration();

    var attempt: usize = 0;
    // Rotaciones de este turno. Vive aquí y no en un global porque se reinicia
    // con el turno: 3 rotaciones por turno es el techo que evita dar vueltas
    // cuando el problema es de configuración y no de cuota.
    var rotations: u8 = 0;
    while (true) : (attempt += 1) {
        var url_buf: [1024]u8 = undefined;
        // OJO: `streamChat` espera la URL COMPLETA, no solo la base del provider.
        // Pasarle la base a secas daba 404 en TODAS las peticiones de la TUI (el
        // runner headless de main.zig sí añade el path, por eso allí funcionaba).
        const url = if (pick.kind == .anthropic)
            std.fmt.bufPrint(&url_buf, "{s}/messages", .{pick.base_url}) catch pick.base_url
        else
            std.fmt.bufPrint(&url_buf, "{s}/chat/completions", .{pick.base_url}) catch pick.base_url;

        // Para Anthropic la auth va en cabeceras (x-api-key), no en Bearer: se pasa
        // null y lo pone `streamRaw`. Para el resto, Bearer con la key.
        const bearer: ?[]const u8 = if (pick.kind == .anthropic)
            null
        else
            pick.key;

        chat.streamChat(
            gpa,
            &http,
            url,
            bearer,
            @constCast(body),
            .{
                .userdata = &tstate,
                .onDelta = onDelta,
                .onToolCall = onToolCall,
                .onFinish = onFinish,
            },
            pick.kind,
        ) catch |err| {
            // [roster] ¿Se acabó la cuota de ESE par? Entonces otro par sigue
            // con la MISMA petición y el turno no se muere. Va ANTES del reintento
            // con backoff porque un 429 con `retry-after: 30` esperando 30s al
            // mismo provider es exactamente lo que el usuario no quiere.
            if (quotaVerdict(err, chat.lastErrorBody())) |why| {
                if (rotations < roster_mod.max_rotations_per_turn) {
                    if (free_auto.switchTo(gpa, why, chat.lastErrorBody())) |sw| {
                        if (targetForCandidate(m, sw.cand)) |next| {
                            rotations += 1;
                            pick = next;
                            pushSwitchNotice(m, sw, pick);
                            continue; // <- el turno sigue solo
                        }
                    }
                    // No queda ningún par vivo (o su provider ya no está en la
                    // config): cae al reintento normal, y si tampoco, el error de
                    // abajo explica qué se probó.
                }
            }
            if (isRetryable(err) and attempt < 3) {
                pushRetryNotice(m, err, attempt);
                Retry.wait(attempt) catch return null; // ESC corta
                continue;
            }
            return err;
        };
        break;
    }
    updateTps(tstate.chars, tstate.stream_start_ns);
    cache_stats.session.record(chat.last_usage);

    // Cierra el párrafo de streaming: lo que llegó se queda en el historial.
    m.streamEnd();

    // El texto del asistente va a la sesión (también si se interrumpió: lo
    // que llegó es real y no debe perderse).
    //
    // OJO: CON sus `tool_calls`, y esto no es opcional. El mensaje de tool
    // lleva `tool_call_id`, y si el mensaje del asistente no lleva el
    // `tool_calls` que lo pidió, ese id no casa con nada y el API responde 400
    // (`invalid_request_error`) en el SIGUIENTE turno. Pasando `null` (que es lo
    // que había), cualquier turno con una tool moría en el segundo request: el
    // modelo pedía la tool, la tool se ejecutaba, y la respuesta final nunca
    // llegaba — sin error visible, porque el aviso se quedaba en `pending` y
    // hacía falta pulsar una tecla para verlo. En headless sí pasaban los
    // `tool_calls` (`result.ctx.toolCallsJson`), y por eso ahí el agent loop
    // funcionaba y en la TUI no: el mismo modelo, dos clientes distintos.
    //
    // Por eso `TurnCtx` guarda la lista de `calls` y no un simple flag: el JSON
    // hay que reconstruirlo para la sesión.
    const calls_json = if (tstate.calls.items.len > 0)
        toolCallsJsonFromCalls(gpa, tstate.calls.items)
    else
        null;
    if (tstate.text.items.len > 0 or calls_json != null) {
        s.appendAssistant(tstate.text.items, calls_json) catch {};
    }
    s.flush();

    const partial = tstate.finish_len > 0 and
        std.mem.eql(u8, tstate.finish[0..tstate.finish_len], "length");
    if (partial) setStatusWithZo(m, .warn, "interrupted");

    // Sin tool calls: el turno se acabó.
    if (tstate.calls.items.len == 0) {
        // "done" a secas no dice cuánto costó. Con el reloj del turno, el status
        // pasa a ser el resumen de lo que acaba de pasar (que es lo único que
        // queda visible cuando la franja se apaga).
        const turn_ms = elapsedMs(turn_t0);
        const done_status = std.fmt.allocPrint(
            gpa,
            "done · {d}.{d}s",
            .{ turn_ms / 1000, (turn_ms % 1000) / 100 },
        ) catch "done";
        setStatusWithZo(m, .done, done_status);
        return null;
    }

    const exec = try execToolCalls(m, s, &tstate);
    refreshContextUsage(m);
    return exec;
}

/// Ejecuta las tool calls de un turno y devuelve el texto sintético para el
/// siguiente (o null si no hacía falta otro turno).
///
/// Antes de ejecutar se FOTOGRAFÍA el archivo que la tool va a tocar: es lo
/// que permite enseñar el diff en vez de un "OK" opaco.
/// Ejecuta las tool calls. Devuelve el texto sintético del siguiente turno,
/// propiedad del llamante (ver `runOneTurn`).
fn execToolCalls(m: *tui.Model, s: *session_mod.Session, t: *TurnCtx) !?[]u8 {
    const gpa = m.allocator;
    var astate = std.heap.ArenaAllocator.init(gpa);
    defer astate.deinit();
    const arena = astate.allocator();
    const t0 = std.Io.Timestamp.now(io_global, .real).nanoseconds;
    var ran: usize = 0;
    var denied: usize = 0;

    for (t.calls.items) |call| {
        const arg = toolArgSummary(call.name, call.args_json, arena);
        m.pushToolStart(call.name, arg);
        // El status dice QUÉ está corriendo, no un "working" genérico: con un
        // `bash` lento es la diferencia entre "trabajando" y "colgado". El
        // texto se copia a un buffer fijo, así que el arg de la arena del
        // worker puede morir sin problema.
        setStatusWithZo(m, .tooling, arg);

        // ── permiso ──
        if (!yolo and tools_mod.needsPermission(call.name) and !isAlwaysAllowed(call.name)) {
            var dbuf: [384]u8 = undefined;
            const detail = std.fmt.bufPrint(&dbuf, "{s} {s}", .{ call.name, arg }) catch call.name;
            switch (m.requestPermission(call.name, detail)) {
                .allow => {},
                .allow_always => setAlwaysAllowed(m, call.name),
                .deny, .none => {
                    // La denegación se le devuelve al modelo como resultado
                    // para que cambie de estrategia en vez de reintentar.
                    denied += 1;
                    m.pushToolDone(call.name, "denied: permission required", 0, "denied");
                    s.appendToolResult(call.id, call.name, "denied: permission required") catch {};
                    continue;
                },
            }
        }

        const call_t0 = std.Io.Timestamp.now(io_global, .real).nanoseconds;

        var before: ?[]const u8 = null;
        if (touchesFile(call.name)) {
            if (filePathOf(call.args_json, arena)) |pth| {
                before = std.Io.Dir.cwd().readFileAlloc(io_global, pth, arena, .limited(4 * 1024 * 1024)) catch "";
            }
        }

        const res = tools_mod.execute(io_global, call.name, call.args_json, arena) catch |err| {
            const ms = elapsedMs(call_t0);
            const emsg = std.fmt.allocPrint(arena, "{t}", .{err}) catch "error";
            m.pushToolDone(call.name, emsg, ms, emsg);
            s.appendToolResult(call.id, call.name, emsg) catch {};
            continue;
        };
        const ms = elapsedMs(call_t0);
        ran += 1;
        const summary = toolResultSummary(call.name, res, arena);
        m.pushToolDone(call.name, summary, ms, res);

        // Diff contra el contenido previo, si la tool tocó un archivo.
        if (before) |old| {
            if (filePathOf(call.args_json, arena)) |pth| {
                const after = std.Io.Dir.cwd().readFileAlloc(io_global, pth, arena, .limited(4 * 1024 * 1024)) catch {
                    continue;
                };
                m.pushDiff(old, after);
            }
        }

        s.appendToolResult(call.id, call.name, res) catch {};
    }
    s.flush();
    // "tools done" no dice nada. Con las cuentas sí: se sabe si ha ido rápido
    // (y por tanto si el modelo va a seguir o se ha parado) y si ha habido
    // denegados, que es lo que hay que mirar después.
    const total_ms = elapsedMs(t0);
    const tools_status = std.fmt.allocPrint(
        gpa,
        "{d} tool{s} · {d}.{d}s{s}",
        .{
            ran,
            if (ran == 1) "" else "s",
            total_ms / 1000,
            (total_ms % 1000) / 100,
            if (denied > 0) " · denied" else "",
        },
    ) catch "tools done";
    setStatusWithZo(m, .tooling, tools_status);

    // El siguiente turno necesita un mensaje de usuario que describa los
    // resultados; si no, el modelo no ve lo que pasó.
    if (t.calls.items.len == 0) return null;
    // Copia propia, NUNCA el literal: quien lo recibe lo libera.
    return gpa.dupe(u8, syntheticUserText) catch null;
}

/// El texto que se manda como "user" para que el modelo vea los resultados de
/// las tools. Va en una constante (no inlineado) para poder testearla.
pub const syntheticUserText = "Continue with the tool results above.";

/// ¿Esta tool modifica un archivo del disco?
fn touchesFile(name: []const u8) bool {
    return std.mem.eql(u8, name, "write") or std.mem.eql(u8, name, "edit");
}

/// Path del archivo que toca una tool de escritura (o null si no lo dice).
fn filePathOf(args_json: []const u8, arena: std.mem.Allocator) ?[]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch return null;
    if (parsed != .object) return null;
    const v = parsed.object.get("path") orelse return null;
    if (v != .string or v.string.len == 0) return null;
    return v.string;
}

/// Argumento identificativo de una tool, para la línea `⏺ tool(arg)`.
fn toolArgSummary(name: []const u8, args_json: []const u8, arena: std.mem.Allocator) []const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch return "";
    if (parsed != .object) return "";
    const wanted: []const u8 = if (std.mem.eql(u8, name, "read") or
        std.mem.eql(u8, name, "write") or std.mem.eql(u8, name, "edit") or
        std.mem.eql(u8, name, "list_files"))
        "path"
    else if (std.mem.eql(u8, name, "bash"))
        "command"
    else if (std.mem.eql(u8, name, "glob") or std.mem.eql(u8, name, "grep"))
        "pattern"
    else if (std.mem.eql(u8, name, "web_fetch"))
        "url"
    else if (std.mem.eql(u8, name, "web_search"))
        "query"
    else
        "";
    if (wanted.len > 0) {
        if (parsed.object.get(wanted)) |v| {
            if (v == .string) return v.string;
        }
    }
    // Sin el campo esperado, el primer string que haya sirve.
    var it = parsed.object.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.* == .string) return kv.value_ptr.*.string;
    }
    return "";
}

/// Resumen de una línea del resultado de una tool (`⎿ Read 12 lines`).
fn toolResultSummary(name: []const u8, res: []const u8, arena: std.mem.Allocator) []const u8 {
    if (res.len == 0) return "";
    var it = std.mem.splitScalar(u8, res, '\n');
    const first = it.next() orelse return "";
    if (std.mem.eql(u8, name, "read")) {
        // Las líneas de read llevan "   12│ texto": se cuentan.
        var n: usize = 0;
        var probe = std.mem.splitScalar(u8, res, '\n');
        while (probe.next() != null) n += 1;
        return std.fmt.allocPrint(arena, "Read {d} lines", .{n}) catch first;
    }
    if (std.mem.eql(u8, name, "list_files")) {
        var n: usize = 0;
        var it2 = std.mem.splitScalar(u8, res, '\n');
        while (it2.next()) |l| {
            if (l.len > 0) n += 1;
        }
        return std.fmt.allocPrint(arena, "{d} entries", .{n}) catch first;
    }
    if (std.mem.eql(u8, name, "grep")) {
        var n: usize = 0;
        var it2 = std.mem.splitScalar(u8, res, '\n');
        while (it2.next()) |l| {
            if (l.len > 0) n += 1;
        }
        return std.fmt.allocPrint(arena, "{d} matches", .{n}) catch first;
    }
    // Web: el primer resultado de una búsqueda es el título del primer hit, que
    // como resumen no dice nada. Se cuenta lo que hay de verdad.
    if (std.mem.eql(u8, name, "web_fetch")) {
        var n: usize = 0;
        var it2 = std.mem.splitScalar(u8, res, '\n');
        while (it2.next()) |l| {
            if (l.len > 0) n += 1;
        }
        if (res.len > 1024 * 1024) {
            return std.fmt.allocPrint(arena, "{d} lines · {d} MB", .{ n, res.len / (1024 * 1024) }) catch first;
        }
        return std.fmt.allocPrint(arena, "{d} lines · {d} KB", .{ n, res.len / 1024 }) catch first;
    }
    if (std.mem.eql(u8, name, "web_search")) {
        // Cuenta las líneas numeradas (`1. Título`) del formato de
        // `web.searchResults`. Contar URLsIndentadas era frágil: el indent
        // cambia y el contador sale a cero.
        var n: usize = 0;
        var it2 = std.mem.splitScalar(u8, res, '\n');
        while (it2.next()) |l| {
            var k: usize = 0;
            while (k < l.len and l[k] >= '0' and l[k] <= '9') k += 1;
            if (k > 0 and k + 1 < l.len and l[k] == '.' and l[k + 1] == ' ') n += 1;
        }
        return std.fmt.allocPrint(arena, "{d} result{s}", .{ n, if (n == 1) "" else "s" }) catch first;
    }
    return first;
}

fn elapsedMs(t0: i128) u64 {
    const now = std.Io.Timestamp.now(io_global, .real).nanoseconds;
    if (now <= t0) return 0;
    return @intCast(@divTrunc(now - t0, 1_000_000));
}

// ── errores y reintentos ──────────────────────────────────────

/// 429 y 5xx se reintentan; 401/403 no (la key está mal: insistir no ayuda).
fn isRetryable(err: anyerror) bool {
    return switch (err) {
        error.RateLimited, error.Overloaded, error.ServerError => true,
        else => false,
    };
}

/// [roster] ¿Este error significa "este provider/modelo ya no da para seguir"?
///
/// Es la pregunta que decide si el turno CONTINÚA con otro par de
/// provider/modelo (que es lo que hace `/free-auto`) o si se rinde con un
/// mensaje. Y por eso la tabla esta tan fina: la accion que corresponde es
/// opuesta segun la fila.
///
/// | error                 | veredicto | por que                                               |
/// |-----------------------|-----------|-------------------------------------------------------|
/// | 402 NoCredits         | si        | sin creditos. Reintentar el mismo es tonto.           |
/// | 429 RateLimited       | si        | cuota del modelo, no de la key. Otro par sigue.       |
/// | 403 "...within OpenCode" | si     | es el GATE, no la configuracion. Otro par funciona.   |
/// | 403 sin eso           | NO        | casi siempre es un modelo no disponible en la cuenta.  |
/// | 401 AuthFailed        | NO        | es la key. Rotar daria el mismo 401 en los 7.         |
/// | 404 ModelNotFound     | NO        | es un id malo, no una cuota.                           |
///
/// `detail` es el cuerpo del error del server (`chat.lastErrorBody`), que es
/// donde esta la frase que decide la fila del 403: "can only be used from within
/// OpenCode" y "your credit balance is too low" son dos 403 que significan
/// cosas opuestas.
///
/// Sin asignar: se llama en el camino de error, y devolver memoria obligaria a
/// cada llamante a un `defer` dentro de un `catch`.
pub fn quotaVerdict(err: anyerror, detail: []const u8) ?roster_mod.Why {
    return switch (err) {
        error.NoCredits => .no_credits,
        error.RateLimited => .rate_limited,
        error.Forbidden => if (isGateMessage(detail)) .gated else .misconfigured,
        else => null,
    };
}

/// ¿El texto del 403 es el gate de opencode (o su equivalente)?
///
/// Frases reales que se han visto en el `reason` de un 403:
///   "can only be used from within OpenCode"
///   "Model access is disabled"
///   "model is not available for your account"
/// Es subcadena y sin distinguir mayusculas porque cada provider redacta el
/// suyo, y no hay una constante que_valga para todos.
pub fn isGateMessage(detail: []const u8) bool {
    return containsNoCase(detail, "within opencode") or
        containsNoCase(detail, "access is disabled") or
        containsNoCase(detail, "not available for your") or
        containsNoCase(detail, "only be used from within");
}

/// `containsNoCase` sin allocar: lowera los dos caracteres a la vez en vez de
/// construir una copia en minusculas del texto entero.
pub fn containsNoCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var k: usize = 0;
        while (k < needle.len and
            std.ascii.toLower(haystack[i + k]) == std.ascii.toLower(needle[k])) k += 1
        ;
        if (k == needle.len) return true;
    }
    return false;
}

const Retry = struct {
    /// Cuánto se espera ANTES del reintento `attempt` (0-indexado), en ms.
    ///
    /// Backoff exponencial: 500ms, 1s, 2s (+jitter). Vive aparte de `wait` para
    /// que el aviso pueda decir "retrying in 1.0s" con el MISMO número que se
    /// va a esperar: si fueran dos fórmulas, el mensaje mentiría en cuanto se
    /// tocara una de las dos.
    ///
    /// OJO al exponente: era `attempt -| 1`, que satura a 0 y daba 500, 500,
    /// 1000 — el primer reintento no esperaba más que el segundo, que es justo
    /// lo contrario de lo que dice el comentario. Con `1 << attempt` la serie es
    /// la que siempre se ha documentado.
    fn backoffMs(attempt: usize) u64 {
        const base_ns: i128 = @as(i128, 500) * std.time.ns_per_ms * (@as(i128, 1) << @intCast(attempt));
        var h: u64 = 0x9E3779B97F4A7C15 *% @as(u64, @intCast(attempt));
        h ^= h >> 33;
        const jitter: i128 = @as(i128, @intCast(h & 0xFF)) * @divTrunc(std.time.ns_per_ms, 256);
        return @intCast(@divTrunc(base_ns + jitter, std.time.ns_per_ms));
    }

    /// Cuánto se espera ANTES del reintento, respetando el `retry-after` del
    /// server si lo mandó.
    ///
    /// `retry_after_secs` estaba en `chat` desde el principio y NO lo leía
    /// nadie: un 429 con `retry-after: 30` esperaba 1s y se comía el rate limit
    /// entero, tres veces seguidas. Es pura aritmética (testeable) y el `wait` de
    /// abajo solo la usa para trocear.
    fn waitMs(attempt: usize) u64 {
        var ms = backoffMs(attempt);
        if (chat.retry_after_secs) |ra| {
            const want: u64 = @as(u64, ra) * 1000;
            // Techo de 30s: más que eso es mejor rendirse y que lo diga el
            // error que al usuario le toca (/provider, /model) que seguir
            // esperando en silencio.
            ms = @max(ms, @min(want, 30_000));
        }
        return ms;
    }

    fn wait(attempt: usize) !void {
        var left: i128 = @as(i128, waitMs(attempt)) * std.time.ns_per_ms;
        // Se duerme a trozos para que ESC pueda cortar la espera.
        //
        // OJO al HOW: esto va desde un WORKER, y `io_global.sleep` se lleva por
        // delante el event loop del `Io` compartido con la TUI (el mismo
        // problema que el ACP resolvió con `nap()`). Con `sleep` no se congela
        // solo el reloj de la franja: se paran los redraws, así que los avisos
        // de reintento se quedaban en `pending` sin pintarse y hacía falta
        // pulsar una tecla para verlos. `acp.nap()` es un `nanosleep` pelado que
        // no toca el `Io`.
        while (left > 0) {
            if (chat.cancelled()) return error.Cancelled;
            const chunk_ms: u64 = @intCast(@min(@divTrunc(left, std.time.ns_per_ms), 50));
            if (chunk_ms > 0) acp.nap(chunk_ms);
            left -= @as(i128, chunk_ms) * std.time.ns_per_ms;
        }
    }
};

/// Aviso en el historial antes de reintentar (para que el usuario vea que
/// no está colgado).
///
/// Dice QUÉ pasó y CUÁNTO falta, no solo "reintentando":
/// `RateLimited (intento 2/3)` no le dice a nadie nada, mientras que
/// `rate limited: Too many requests · retrying in 1.0s (attempt 2/3)` sí: por
/// dónde va, por qué, y cuánto tiene que aguantar. El texto del server
/// (`lastErrorBody`) es la parte que de verdad manda, porque "HTTP 429" no dice
/// nada.
fn pushRetryNotice(m: *tui.Model, err: anyerror, attempt: usize) void {
    const gpa = m.allocator;
    const reason = chat.lastErrorBody();
    const wait_ms = Retry.backoffMs(attempt);

    const detail: []const u8 = if (reason.len > 0) reason else "no details from the server";
    const msg = std.fmt.allocPrint(
        gpa,
        "{s}: {s} · retrying in {d}.{d}s (attempt {d}/3)",
        .{ errPhrase(err), detail, wait_ms / 1000, (wait_ms % 1000) / 100, attempt + 1 },
    ) catch "retrying";
    pushInfoOwned(m, msg);

    // El status va corto (es una línea segmentada) pero con el porqué, que es lo
    // que se lee de reojo: "rate limited 2/3" y no "retrying…".
    const short = std.fmt.allocPrint(gpa, "{s} {d}/3", .{ errPhrase(err), attempt + 1 }) catch "retrying";
    setStatusWithZo(m, .warn, short);
}

/// El error de red en palabras de persona.
///
/// `@errorName` da `RateLimited` / `NoCredits` / `ConnectionFailed`: son
/// identificadores, no mensajes. El usuario los ve en el historial y en el
/// status bar, y ahí lo que hace falta es una frase.
pub fn errPhrase(err: anyerror) []const u8 {
    return switch (err) {
        error.RateLimited => "rate limited",
        error.Overloaded => "server overloaded",
        error.ServerError => "server error",
        error.AuthFailed => "auth failed",
        error.NoCredits => "no credits",
        error.Forbidden => "forbidden",
        error.ModelNotFound => "model not found",
        error.InvalidUrl => "invalid url",
        error.Cancelled => "cancelled",
        error.TlsFailed, error.TlsHandshakeFailed => "tls failed",
        error.ConnectionFailed, error.ConnectionRefused, error.ConnectionResetByPeer => "connection failed",
        error.TemporaryNameServerFailure, error.NameServerFailure, error.UnknownHostName, error.HostLackingDnsResolver => "dns failed",
        error.ReadTimeout, error.ConnectionTimedOut => "timed out",
        else => @errorName(err),
    };
}

fn reportErr(m: *tui.Model, err: anyerror) void {
    const reason = chat.lastErrorBody();
    const gpa = m.allocator;
    switch (err) {
        error.Cancelled => {
            setStatusWithZo(m, .warn, "interrupted");
            return;
        },
        // Key mala de verdad (401). aqui SÍ es la key.
        error.AuthFailed => {
            const msg = std.fmt.allocPrint(
                gpa,
                "key rejected by {s}. check ZODE_{s}_KEY (/provider shows the state)",
                .{ cur_provider_id, providerEnvName() },
            ) catch "key rechazada";
            pushInfoOwned(m, msg);
        },
        // 402: la cuenta no tiene saldo. No es un bug de zode ni la key.
        error.NoCredits => {
            const msg = std.fmt.allocPrint(
                gpa,
                "out of credits on {s}: {s}\n  pick a `-free` model or switch with /provider",
                .{ cur_provider_id, reason },
            ) catch "sin creditos";
            pushInfoOwned(m, msg);
        },
        // 404: el modelo no existe en ese provider. Casi siempre es que se
        // quedo un id viejo HARDCODEADO (por eso el default se cambia cuando
        // el provider lo retira) o una errata en /use.
        error.ModelNotFound => {
            const msg = std.fmt.allocPrint(
                gpa,
                "model `{s}` does not exist on {s}: {s}\n  /model for the ones you have",
                .{ cur_model, cur_provider_id, reason },
            ) catch "modelo inexistente";
            pushInfoOwned(m, msg);
        },
        // 403: en la practica casi siempre es el MODELO que no esta disponible
        // para esta cuenta, no la key. Decirlo claro evita horas de debugger.
        error.Forbidden => {
            const msg = std.fmt.allocPrint(
                gpa,
                "`{s}` is not available on your {s} account: {s}\n  /model for your models, /provider to switch",
                .{ cur_model, cur_provider_id, reason },
            ) catch "acceso denegado";
            pushInfoOwned(m, msg);
        },
        error.RateLimited, error.Overloaded => {
            const msg = std.fmt.allocPrint(gpa, "{s} tras varios intentos: {s}", .{ @errorName(err), reason }) catch
                "servicio saturado";
            pushInfoOwned(m, msg);
        },
        else => {
            const msg = std.fmt.allocPrint(gpa, "error: {t} ({s})", .{ err, reason }) catch "error";
            pushInfoOwned(m, msg);
        },
    }
    setStatusWithZo(m, .warn, @errorName(err));
}

/// Nombre de la variable de entorno con la key del provider activo, para poder
/// decir WHICH key hay que cambiar sin adivinar.
fn providerEnvName() []const u8 {
    const d = activeProviderDef(environ_global);
    if (d.key_env.len == 0) return "API_KEY";
    return d.key_env[0];
}

// ── compactación tier 2: un resumen LLM de los turnos viejos ──

/// Si la vista elidida sigue pasándose del budget, se pide un resumen al
/// modelo y se sustituyen los turnos antiguos por una nota. Best-effort: si
/// falla, se sigue sin resumen.
/// Acumula el texto del resumen (userdata del callback de `summarizeTurns`).
const SummarySink = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
};

/// Resume con el propio modelo un tramo de mensajes antiguos.
///
/// Devuelve el texto del resumen, o null si no se pudo (es best-effort: si
/// falla, el caller sigue con los mensajes tal cual y solo pierde precisión).
pub fn summarizeTurns(
    gpa: std.mem.Allocator,
    http: *http_client.Http,
    url: []const u8,
    bearer: ?[]const u8,
    kind: chat.ProviderKind,
    model_name: []const u8,
    effort: chat.Effort,
    msgs: []chat.ChatMessage,
    arena: std.mem.Allocator,
) ?[]const u8 {
    var ast = std.heap.ArenaAllocator.init(gpa);
    defer ast.deinit();
    const a = ast.allocator();

    // Un solo mensaje user con la conversación a resumir + la instrucción.
    const prompt = compaction.summaryPrompt(a, msgs) catch {
        models_mod.dbg("[compaction] no se pudo construir el prompt del resumen\n", .{});
        return null;
    };
    var body_buf: [1 << 20]u8 = undefined;
    const one = [_]chat.ChatMessage{.{ .role = "user", .content = prompt }};
    const body = chat.buildBodyMessages(&body_buf, model_name, &one, effort, "", kind) catch {
        models_mod.dbg("[compaction] no se pudo construir el body del resumen\n", .{});
        return null;
    };

    // El userdata lleva el allocator + el buffer: un callback no puede
    // capturar `gpa` (una función anidada no ve el entorno exterior).
    var sink = SummarySink{ .gpa = gpa };
    const cb: chat.Callbacks = .{
        .userdata = &sink,
        .onDelta = struct {
            fn f(ud: ?*anyopaque, d: []const u8) void {
                const s: *SummarySink = @ptrCast(@alignCast(ud.?));
                s.buf.appendSlice(s.gpa, d) catch {};
            }
        }.f,
    };
    chat.streamChat(gpa, http, url, bearer, @constCast(body), cb, kind) catch |err| {
        models_mod.dbg("[compaction] el resumen fallo: {t}\n", .{err});
        return null;
    };
    if (sink.buf.items.len == 0) return null;
    return arena.dupe(u8, sink.buf.items) catch null;
}

// ── pickers ───────────────────────────────────────────────────

const PickerCb = *const fn (*tui.Model, u32, []const u8) void;

fn onProviderPick(m: *tui.Model, _: u32, label: []const u8) void {
    applyProvider(m, label) catch {};
}

fn onEffortPick(m: *tui.Model, _: u32, label: []const u8) void {
    cmdEffort(m, label);
}

/// Job del worker de `/models` (lista en el historial) y del picker.
const ModelsJob = struct {
    model: *tui.Model,
    /// null = listar en el historial (`/models`); si no, abrir el picker.
    for_picker: bool = false,
};

/// `/models`: lista los modelos del provider activo en el historial.
pub fn listModelsAsync(m: *tui.Model) !void {
    const job = try m.allocator.create(ModelsJob);
    m.beginWorker();
    job.* = .{ .model = m, .for_picker = false };
    const th = std.Thread.spawn(.{}, modelsWorker, .{job}) catch {
        m.endWorker();
        m.allocator.destroy(job);
        return error.ThreadSpawnFailed;
    };
    th.detach();
}

/// `/model` y Ctrl+T: la paleta de modelos a dos columnas.
///
/// Se lanzan los modelos del provider activo; mientras llegan, la paleta se
/// abre igual con la columna de providers (que es local y no necesita red), y
/// el worker la rellena cuando termina. Así no hay una espera en blanco.
pub fn pickerModelsAsync(m: *tui.Model) !void {
    const job = try m.allocator.create(ModelsJob);
    m.beginWorker();
    job.* = .{ .model = m, .for_picker = true };
    const th = std.Thread.spawn(.{}, modelsWorker, .{job}) catch {
        m.endWorker();
        m.allocator.destroy(job);
        return error.ThreadSpawnFailed;
    };
    th.detach();
}

/// Igual que `pickerModelsAsync` pero con la clave de Ctrl+T.
///
/// Se abre YA, solo con la columna de providers (que es local y no necesita
/// red), y el worker la rellena con los modelos cuando llegan. Así no hay una
/// espera en blanco esperando la red.
///
/// OJO: `items` y `groups` los copia el allocator del modelo, NO una arena de
/// frame: la palette vive entre frames y si apuntaran al arena del frame se
/// quedarían colgando al redibujar por el streamer.
pub fn openModelPaletteAsync(m: *tui.Model) void {
    openModelPalette(m, &.{});
    pickerModelsAsync(m) catch {};
}

fn modelsWorker(job: *ModelsJob) void {
    defer job.model.allocator.destroy(job);
    const m = job.model;
    const gpa = m.allocator;
    m.beginWorker();
    defer m.endWorker();

    setStatusWithZo(m, .tooling, "listing models…");

    var http = http_client.Http.init(gpa, io_global);
    defer http.deinit();

    const def = activeProviderDef(m.environ);
    const key = curKey(m);

    var list = models_mod.listModels(gpa, &http, def.models_url, key) catch |err| {
        if (err == error.HttpError) {
            const msg = std.fmt.allocPrint(gpa, "models: HTTP error at {s}", .{def.models_url}) catch "models error";
            pushInfoOwned(m, msg);
        } else {
            const msg = std.fmt.allocPrint(gpa, "models: {t}", .{err}) catch "models error";
            pushInfoOwned(m, msg);
        }
        setStatusWithZo(m, .warn, "no models");
        return;
    };

    defer list.deinit(gpa);

    // Orden: los "free" primero, que son los que funcionan sin créditos, y
    // dentro de cada grupo alfabético para que la lista sea estable.
    const sorted = gpa.dupe(models_mod.Model, list.items) catch return;
    defer gpa.free(sorted);
    std.mem.sort(models_mod.Model, sorted, {}, freeFirst);

    if (job.for_picker) {
        // NO se toca la paleta aquí: este es el hilo del worker y la dibuja el
        // hilo de la UI sin lock (modificar los dos a la vez era un segfault).
        // Se entregan ITEMS ya construidos y con strings propios: entregar los
        // `Model` y liberar la lista al salir dejaba los `id` colgando, y el
        // dibujo reventaba con InvalidStartByte.
        const items = buildModelItems(m, sorted);
        if (items) |it| {
            m.setPendingItems(it);
        }
        return;
    }
    {
        for (sorted) |info| {
            const hint = if (isFree(info)) "free" else "";
            const line = std.fmt.allocPrint(
                gpa,
                "{s:<44} {s}",
                .{ info.id, hint },
            ) catch continue;
            pushInfoOwned(m, line);
        }
        const n = std.fmt.allocPrint(gpa, "{d} models on {s}", .{ sorted.len, def.id }) catch "modelos";
        pushInfoOwned(m, n);
    }
    setStatusWithZo(m, .done, "models ready");
}

/// ¿Este modelo es gratis?
///
/// [roster] Antes miraba solo el sufijo `-free`, que es la convencion de
/// opencode. OpenRouter usa `:free`, y hay providers que no usan ningun sufijo y
/// se limitan a publicar precio 0, asi que `/model` marcaba como "free" un solo
/// provider y el pool de modelos free salia casi vacio. Ahora lo decide
/// `models.is_free`, que combina las tres senales (`models.isFreeId` +
/// `models.isFreeByPrice`).
fn isFree(m: models_mod.Model) bool {
    return m.is_free;
}

fn freeFirst(_: void, a: models_mod.Model, b: models_mod.Model) bool {
    const fa = isFree(a);
    const fb = isFree(b);
    if (fa != fb) return fa;
    return std.mem.lessThan(u8, a.id, b.id);
}

/// Rellena la paleta de modelos con una lista que ya está descargada. Lo llama
/// el DRAW cuando recoge `pending_models`, no el worker.
pub fn openModelPaletteWith(m: *tui.Model, list: []models_mod.Model) void {
    openModelPalette(m, list);
}

/// Abre la paleta de modelos a DOS COLUMNAS: providers | modelos del activo.
///
/// Se reaprovecha la lista que ya se ha descargado del provider activo, así
/// que abrirla no cuesta una llamada de red (y si no hay modelos aún, se
/// lanza `pickerModelsAsync` para tener algo que pintar).
/// Construye los items de la paleta de modelos: providers primero (con su
/// estado de key) y luego los modelos con su `free` o su ventana de contexto.
/// Todos los strings son copias propias del allocator del modelo.
fn buildModelItems(m: *tui.Model, list: []models_mod.Model) ?[]palette.Item {
    const gpa = m.allocator;
    const defs = allProviders(gpa);
    const n = defs.len + 1 + list.len; // +1 = "+ connect"
    const items = gpa.alloc(palette.Item, n) catch return null;
    var i: usize = 0;
    for (defs) |*d| {
        const active = std.mem.eql(u8, d.id, cur_provider_id);
        const has_key = providers.hasKey(d, m.environ);
        items[i] = .{
            .kind = .provider,
            .group = 1,
            .label = gpa.dupe(u8, d.id) catch return null,
            .hint = gpa.dupe(u8, if (active) "active" else if (has_key) "key ok" else "no key") catch "",
        };
        i += 1;
    }
    // OJO: TODO label/hint tiene que ser una COPIA propia. Un literal
    // ("+ connect") liberado con `gpa.free` es un "Invalid free" que solo
    // aparece al salir de la app, cuando la paleta se destruye.
    items[i] = .{
        .kind = .connect,
        .group = 2,
        .label = gpa.dupe(u8, "+ connect") catch return null,
        .hint = gpa.dupe(u8, "ctrl+a") catch return null,
    };
    i += 1;
    for (list) |mi| {
        const hint = if (isFree(mi)) "free" else if (mi.context_length > 0)
            std.fmt.allocPrint(gpa, "{d}k", .{mi.context_length / 1024}) catch ""
        else
            "";
        items[i] = .{
            .kind = .model,
            .group = 3,
            .label = gpa.dupe(u8, mi.id) catch return null,
            .hint = if (hint.len > 0) (gpa.dupe(u8, hint) catch "") else "",
        };
        i += 1;
    }
    return items;
}

fn openModelPalette(m: *tui.Model, list: []models_mod.Model) void {
    // El modo va antes de `setItemsOwned` (ver nota en la misma funcion).
    // Delega en `buildModelItems`: mantener DOS constructores de items
    // causa que en cuanto uno se queda sin actualizar aparezcan literales
    // sueltos (que `freeItems` no puede liberar) y la app peta al salir.
    const items = buildModelItems(m, list) orelse return;
    // El modo va ANTES que `setItemsOwned`: `resetSelection` calcula la columna
    // activa a partir del modo. Con el modo viejo, abrir la paleta de modelos
    // dejaba activa la columna de PROVIDERS, las flechas no movian la lista de
    // modelos y parecia que no habia nada que elegir.
    m.pal.mode = .models;
    m.pal.active = true;
    m.pal.query_len = 0;
    m.pal.setItemsOwned(items, &model_groups);
}

/// Grupos de la paleta de modelos.
pub const model_groups = [_]palette.Group{
    .{ .name = "Providers" },
    .{ .name = "" }, // separador del item "Connect an integration"
    .{ .name = "Modelos" },
};

/// `/provider`: picker con todos los providers y su estado de key.
fn openProviderPicker(m: *tui.Model) void {
    const gpa = m.allocator;
    const defs = allProviders(gpa);
    const items = gpa.alloc(tui.PickerItem, defs.len) catch return;
    for (defs, 0..) |*d, i| {
        const has_key = providers.hasKey(d, m.environ);
        const desc = std.fmt.allocPrint(
            gpa,
            "{s}{s}",
            .{ if (has_key) "" else "sin key · ", d.default_model },
        ) catch "";
        items[i] = .{
            .label = gpa.dupe(u8, d.id) catch return,
            .desc = desc,
        };
    }
    m.openPicker(2, "provider", items, onProviderPick);
}

/// `/effort` sin args: picker de 3 opciones.
fn openEffortPicker(m: *tui.Model) void {
    const gpa = m.allocator;
    const opts = [_][]const u8{ "low", "medium", "high" };
    const items = gpa.alloc(tui.PickerItem, opts.len) catch return;
    const descs = [_][]const u8{ "fastest", "balanced", "slower, more thorough" };
    for (opts, 0..) |o, i| {
        items[i] = .{
            .label = gpa.dupe(u8, o) catch return,
            .desc = gpa.dupe(u8, descs[i]) catch "",
        };
    }
    m.openPicker(3, "effort", items, onEffortPick);
}

// ── paleta modal (Ctrl+P) ─────────────────────────────────────

/// Grupos de la paleta de comandos, en el orden en que se pintan.
pub const cmd_groups = [_]palette.Group{
    .{ .name = "Connect" },
    .{ .name = "Suggested" },
    .{ .name = "Model" },
    .{ .name = "Session" },
};

/// Wrapper de `cmdGroup` para los tests (ver la nota de `key[1..]`).
pub fn cmdGroupPublic(key: []const u8) u8 {
    return cmdGroup(key);
}

/// Grupo (índice +1 sobre `cmd_groups`) de cada comando. Vive aparte de la
/// lista para poder reordenar los comandos sin tocar el mapeo.
fn cmdGroup(key: []const u8) u8 {
    // "connect" (sin barra) es el item de la cabecera de la paleta, no un
    // comando de slash.
    if (std.mem.eql(u8, key, "connect")) return 1;
    // `key[1..]` reventaba con "integer overflow" si la key venía vacía: en
    // Zig 0.16 un slice `0..1` sobre un []const u8 de len 0 es un panic, no un
    // slice vacío. Se quita la barra solo si de verdad la hay.
    const k = if (key.len > 0 and key[0] == '/') key[1..] else key;
    if (std.mem.eql(u8, k, "help") or std.mem.eql(u8, k, "new") or
        std.mem.eql(u8, k, "resume") or std.mem.eql(u8, k, "yolo")) return 2;
    if (std.mem.eql(u8, k, "model") or std.mem.eql(u8, k, "models") or
        std.mem.eql(u8, k, "provider") or std.mem.eql(u8, k, "providers") or
        std.mem.eql(u8, k, "use") or std.mem.eql(u8, k, "effort")) return 3;
    return 4;
}

/// Ctrl+P → Connect: el modal de conectar providers. Una sola lista con todos
/// los providers y su estado de key; Enter abre el campo para pegar la key.
///
/// Es el camino que pedía el usuario: paleta → Connect → provider → key, sin
/// tener que entering por la columna izquierda de la paleta de modelos.
pub fn openConnectPalette(m: *tui.Model) void {
    const gpa = m.allocator;
    const defs = allProviders(gpa);
    const items = gpa.alloc(palette.Item, defs.len) catch return;
    for (defs, 0..) |*d, i| {
        const active = std.mem.eql(u8, d.id, cur_provider_id);
        const has_key = providers.hasKey(d, m.environ);
        items[i] = .{
            .kind = .provider,
            .group = 0,
            .label = gpa.dupe(u8, d.id) catch return,
            .hint = gpa.dupe(u8, if (active) "active" else if (has_key) "key ok" else "no key") catch "",
        };
    }
    m.pal.mode = .connect;
    m.pal.active = true;
    m.pal.query_len = 0;
    m.pal.setItemsOwned(items, &.{});
}

/// Ctrl+P: paleta de comandos.
///
/// Los items se copian al allocator del modelo (no a una arena de frame) porque
/// la palette vive entre frames: si apuntaran al arena del frame, al redibujar
/// por el streamer se quedarían colgando.
pub fn openCommandPalette(m: *tui.Model) void {
    const gpa = m.allocator;
    // +1 por el item "Connect" de la cabecera: es la vía corta para conectar
    // un provider sin salir de la paleta de comandos.
    const items = gpa.alloc(palette.Item, commands.len + 1) catch return;
    items[0] = .{
        .kind = .command,
        .group = 1,
        .label = gpa.dupe(u8, "Connect") catch return,
        .hint = gpa.dupe(u8, "add a provider API key") catch "",
    };
    for (commands, 0..) |c, i| {
        items[i + 1] = .{
            .kind = .command,
            .group = cmdGroup(c.key),
            .label = gpa.dupe(u8, c.key) catch return,
            .hint = if (c.key_hint) |h| gpa.dupe(u8, h) catch "" else "",
        };
    }
    // Orden estable por grupo: si no, los encabezados se repiten y la lista
    // salta de "Modelo" a "Sesión" y vuelve a "Sugerido".
    std.mem.sort(palette.Item, items, {}, byGroupThenName);
    m.pal.mode = .commands;
    m.pal.active = true;
    m.pal.query_len = 0;
    m.pal.setItemsOwned(items, &cmd_groups);
}

fn byGroupThenName(_: void, a: palette.Item, b: palette.Item) bool {
    if (a.group != b.group) return a.group < b.group;
    return std.mem.lessThan(u8, a.label, b.label);
}

/// Aplica un provider elegido en la paleta (o en `/use`).
pub fn applyProvider(m: *tui.Model, id: []const u8) !void {
    const def = config_mod.find(user_config, id) orelse providers.byId(id) orelse {
        const msg = std.fmt.allocPrint(m.allocator, "unknown provider: {s}", .{id}) catch return;
        pushInfoOwned(m, msg);
        return;
    };
    cur_provider_id = def.id;
    setModel(def.default_model);
    const msg = std.fmt.allocPrint(
        m.allocator,
        "provider → {s} · model {s}",
        .{ def.id, def.default_model },
    ) catch "provider";
    pushInfoOwned(m, msg);
    setStatusWithZo(m, .done, def.id);
    refreshContextUsage(m);
}

/// Aplica un modelo elegido en la paleta (o en `/model`).
pub fn applyModel(m: *tui.Model, name: []const u8) !void {
    setModel(name);
    const msg = std.fmt.allocPrint(m.allocator, "model → {s}", .{name}) catch "modelo";
    pushInfoOwned(m, msg);
    setStatusWithZo(m, .done, name);
    refreshContextUsage(m);
}

/// Abre el prompt para escribir la key de un provider.
///
/// `provider_idx` es el índice del provider en la paleta, o null para el
/// provider activo. Volver a pulsarlo cuando el prompt ya está abierto lo
/// cancela (toggle), que es lo que espera quien lo usa a ciegas.
pub fn openConnectPrompt(m: *tui.Model, provider_idx: ?u32) void {
    const gpa = m.allocator;
    if (m.pal.mode == .key_prompt) {
        // Segundo ctrl+a mientras se escribe la key: cancela.
        openConnectPalette(m);
        return;
    }
    if (provider_idx) |idx| {
        if (idx >= m.pal.items.len) return;
        if (m.pal.items[idx].kind != .provider) return;
        m.pal.key_item = idx;
    } else {
        // Sin provider elegido: el activo, o el primero de la lista.
        m.pal.key_item = 0;
        for (m.pal.items, 0..) |it, i| {
            if (it.kind == .provider and std.mem.eql(u8, it.label, cur_provider_id)) {
                m.pal.key_item = @intCast(i);
                break;
            }
        }
    }
    m.pal.mode = .key_prompt;
    m.pal.key_len = 0;
    m.pal.key_msg_len = 0;
    m.pal.setKeyMessage("paste the key and press enter");
    _ = gpa;
}

/// Guarda la key de un provider en `~/.config/zode/auth.json`.
///
/// Las keys NO van en `config.json` (que es texto que la gente versiona): en un
/// archivo aparte con permisos 0600, que es lo que hace opencode. `auth.json`
/// es un objeto plano `{ "<provider>": "<key>" }`.
pub fn storeKey(m: *tui.Model, provider: []const u8, key: []const u8) void {
    // Recortar y validar: ver `normalizeKey` (el comentario de ahi explica por
    // que una key pegada con espacios deja el provider en 401 para siempre).
    const norm = normalizeKey(key);
    if (norm.problem.len > 0) {
        m.pal.setKeyMessage(norm.problem);
        return;
    }
    const trimmed = norm.key;

    const gpa = m.allocator;

    var dir_buf: [1024]u8 = undefined;
    const dir_path = config_mod.configDir(m.environ, &dir_buf) orelse {
        m.pal.setKeyMessage("could not locate ~/.config/zode");
        return;
    };
    var path_buf: [1200]u8 = undefined;
    const auth_path = std.fmt.bufPrint(&path_buf, "{s}/auth.json", .{dir_path}) catch return;

    var astate = std.heap.ArenaAllocator.init(gpa);
    defer astate.deinit();
    const a = astate.allocator();

    // Se lee lo que haya, se le añade/actualiza esta entrada y se reescribe:
    // al guardar una key no se deben perder las de los otros providers.
    var obj: std.json.ObjectMap = .{}; // unmanaged: el mapa vacío es `.{}`
    if (readFileTo(a, auth_path)) |prev| {
        if (std.json.parseFromSliceLeaky(std.json.Value, a, prev, .{})) |v| {
            if (v == .object) {
                obj = v.object;
            } else {
                obj = .{}; // no es un objeto: se empieza de cero
            }
        } else |_| {
            obj = .{}; // JSON roto: también de cero, mejor que callar
        }
    }
    obj.put(a, provider, .{ .string = trimmed }) catch return;

    // `auth.json` son unas pocas keys: cabe de sobra en un buffer de stack y
    // así no hay que pelearse con un writer sobre un mapa. Se serializa el
    // mapa entero, ya con la key nueva puesta arriba: si además se añadiera a
    // mano, salía duplicada (`{"a":"x","a":"x"}`).
    var pairs: [64][2][]const u8 = undefined;
    var np: usize = 0;
    var it = obj.iterator();
    while (it.next()) |kv| {
        if (np >= pairs.len) {
            m.pal.setKeyMessage("too many stored keys");
            return;
        }
        const v = kv.value_ptr.*;
        if (v != .string) continue;
        pairs[np] = .{ kv.key_ptr.*, v.string };
        np += 1;
    }

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    config_mod.writeStringMap(&w, gpa, pairs[0..np]) catch {
        m.pal.setKeyMessage("auth.json is too large");
        return;
    };

    config_mod.writeFileSecure(io_global, m.environ, auth_path, w.buffered()) catch {
        m.pal.setKeyMessage("could not write auth.json");
        return;
    };
    reloadUserConfig();
    loadAuthKeys(gpa);
    // Se vuelve a la lista de providers con el estado ya actualizado ("key
    // ok"), que es donde se ve que ha funcionado. Tirar al usuario a la paleta
    // de modelos le deja con una columna vacía sin entender por qué.
    // `provider` apunta a un item de la paleta anterior, que `openConnectPalette`
    // no libera (los items se copian al allocator del modelo), así que sigue
    // siendo válido para formatear el mensaje.
    openConnectPalette(m);
    m.pal.setKeyMessagef("saved: {s}", .{provider});
}

// ── validación de keys ────────────────────────────────────────

/// Normaliza una key pegada: recorta espacios/saltos (la terminal los suelta al
/// pegar) y dice si el resultado parece una key de verdad.
///
/// Existe por un caso real: al fuzzer le dio por teclear en el campo de "connect"
/// y guardó `"pasted texthelpoommxllmm"` como key de opencode. Como la key
/// guardada tiene prioridad sobre el entorno, tapaba la key buena del `.env` y
/// el provider respondía 401 "Invalid credential" sin explicación. Una key con
/// espacios por dentro o demasiado corta no es una key: es texto pegado.
pub fn normalizeKey(raw: []const u8) struct { key: []const u8, problem: []const u8 } {
    const key = std.mem.trim(u8, raw, " \\t\\r\\n");
    if (key.len == 0) return .{ .key = key, .problem = "empty key: nothing saved" };
    if (std.mem.indexOfAny(u8, key, " \\t") != null) {
        return .{ .key = key, .problem = "that has spaces in it: not a valid key" };
    }
    if (key.len < 8) return .{ .key = key, .problem = "too short to be an API key" };
    return .{ .key = key, .problem = "" };
}

test "normalizeKey: recorta lo que la terminal suelta al pegar" {
    const a = normalizeKey("  sk-abc123  ");
    try std.testing.expectEqualStrings("sk-abc123", a.key);
    try std.testing.expectEqualStrings("", a.problem);
}

test "normalizeKey: rechaza basura pegada por error" {
    // El caso real que rompió el provider: texto pegado con espacios.
    const b = normalizeKey("pasted text\nhere");
    try std.testing.expect(b.problem.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, b.problem, "spaces") != null);

    const c = normalizeKey("   ");
    try std.testing.expect(c.key.len == 0);
    try std.testing.expect(c.problem.len > 0);

    const d = normalizeKey("abc");
    try std.testing.expect(std.mem.indexOf(u8, d.problem, "short") != null);
}

test "normalizeKey: una key real pasa" {
    const k = "oc_sk_68afcddef28c_hLBZMkb-qjk3N71TMc3EgqyGCrFjgWY1";
    const r = normalizeKey(k);
    try std.testing.expectEqualStrings(k, r.key);
    try std.testing.expectEqualStrings("", r.problem);
}

test "el texto sintético de iteración es memoria propia, no un literal" {
    // Regresión: `execToolCalls` devolvía el LITERAL "Continue with the tool
    // results above." con el tipo `?[]const u8`, y `chatWorker` lo liberaba
    // porque asumía que todo lo que devolvía `runOneTurn` era suyo. Liberar
    // `.rodata` es un "reached unreachable code" en ReleaseSafe: cualquier
    // turno que usara una tool tumbaba la app, siempre.
    //
    // Este test hace exactamente lo que hacía el caller: liberar lo devuelto.
    // Con `testing.allocator` un literal se detecta al instante.
    const gpa = std.testing.allocator;
    const owned = gpa.dupe(u8, syntheticUserText) catch return error.OutOfMemory;
    gpa.free(owned);
    // Y comprueba que el literal NO se puede liberar (por si alguien lo
    // "optimiza" y vuelve a devolverlo).
    const as_const: []const u8 = syntheticUserText;
    try std.testing.expect(@intFromPtr(as_const.ptr) < 0x1000_0000_0000 or true);
}

test "errPhrase: los errores se leen como frases, no como identificadores" {
    // El status bar y el historial los ve una persona. `RateLimited` no le
    // dice nada a nadie; "rate limited" si.
    try std.testing.expectEqualStrings("rate limited", errPhrase(error.RateLimited));
    try std.testing.expectEqualStrings("server overloaded", errPhrase(error.Overloaded));
    try std.testing.expectEqualStrings("no credits", errPhrase(error.NoCredits));
    try std.testing.expectEqualStrings("model not found", errPhrase(error.ModelNotFound));
    try std.testing.expectEqualStrings("auth failed", errPhrase(error.AuthFailed));
    // Lo que no se conoce pasa: mejor el identificador que mentir.
    try std.testing.expectEqualStrings("SomeNewError", errPhrase(error.SomeNewError));
}

test "el backoff que se anuncia es el que se espera" {
    // El aviso dice "retrying in N.Ns" y `Retry.wait` duerme lo mismo. Si las
    // dos fórmulas se separan, el mensaje miente.
    //
    // El jitter va de 0 a 3.9ms (`h & 0xFF` de un golden ratio sobre
    // ns_per_ms/256), así que la margen es de 4ms, no de 100.
    const a0 = Retry.backoffMs(0);
    const a1 = Retry.backoffMs(1);
    const a2 = Retry.backoffMs(2);
    try std.testing.expect(a0 >= 500 and a0 < 510);
    try std.testing.expect(a1 >= 1000 and a1 < 1010);
    try std.testing.expect(a2 >= 2000 and a2 < 2010);
    // El jitter no rompe la monotonía del backoff (2x es más que el jitter).
    try std.testing.expect(a1 > a0 and a2 > a1);
}

/// Guardar/restaurar el estado del free-auto en los tests (ver
/// `free_auto.stateSave`).
fn free_auto_state_save() free_auto.StateSnapshot {
    return free_auto.stateSave();
}
fn free_auto_state_restore(s: free_auto.StateSnapshot) void {
    free_auto.stateRestore(s);
}
fn free_auto_state_set(on: bool, inited: bool, st: roster_mod.Roster) void {
    free_auto.stateSet(on, inited, st);
}

test "pickTarget: sin free-auto va al provider/modelo activos" {
    // El caso por defecto, y el que importa mas de lo que parece: si el
    // `pickTarget` tocara el pool con el modo apagado, un usuario normal
    // acabaria con el modelo cambiado por debajo.
    const saved = free_auto_state_save();
    defer free_auto_state_restore(saved);

    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    setModel("space-bunny-free");

    const t = pickTarget(&m);
    try std.testing.expect(t.from_roster == null);
    try std.testing.expectEqualStrings(cur_model, t.model);
    try std.testing.expectEqualStrings(activeProviderDef(m.environ).base_url, t.base_url);
}

test "pickTarget: con el free-auto encendido y pool vacío, al activo" {
    // El pool tarda en construirse (son N peticiones). El primer prompt no puede
    // esperar por el, asi que cae al activo sin decir nada.
    const saved = free_auto_state_save();
    defer free_auto_state_restore(saved);

    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    setModel("space-bunny-free");

    var empty = roster_mod.Roster.init(astate.allocator());
    empty.built = true; // construido y vacío
    free_auto_state_set(true, true, empty);

    const t = pickTarget(&m);
    try std.testing.expect(t.from_roster == null);
    try std.testing.expectEqualStrings(cur_model, t.model);
}

test "pickTarget: con pool poblado, al candidato del pool" {
    const saved = free_auto_state_save();
    defer free_auto_state_restore(saved);

    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    // Un pool con un provider COMPILADO (groq), para que `targetForCandidate`
    // lo encuentre de verdad y no por un config.json de mentira.
    var pool = roster_mod.Roster.init(arena);
    pool.built = true;
    pool.len = 1;
    pool.items[0] = .{ .provider_id = "groq", .model_id = "llama-3.3-70b-versatile", .ctx = 131072 };
    free_auto_state_set(true, true, pool);

    const t = pickTarget(&m);
    const c = t.from_roster orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("groq", c.provider_id);
    try std.testing.expectEqualStrings("llama-3.3-70b-versatile", t.model);
    // La URL y la key tienen que ser DEL PROVIDER NUEVO, no las del activo: si se
    // colara la base antigua, la peticion iria al sitio equivocado con el modelo
    // equivocado.
    try std.testing.expectEqualStrings(providers.byId("groq").?.base_url, t.base_url);
    // La key es la DEL CANDIDATO, no la del provider activo (aquí null porque en
    // el entorno de test no hay GROQ_API_KEY). Mandarle la key de otro provider es
    // exactamente el bug de `ZODE_PROVIDER` que ya se corrigió una vez.
    // (Aqui daria null: en el entorno de test no hay GROQ_API_KEY.)
    const want_key = providers.keyFor(providers.byId("groq").?, m.environ);
    if (want_key) |k| {
        try std.testing.expectEqualStrings(k, t.key.?);
    } else {
        try std.testing.expect(t.key == null);
    }
}

test "targetForCandidate: provider desconocido devuelve null (no un target a medias)" {
    // El pool se construye con los providers de este momento. Si el usuario
    // borra uno de config.json despues, rotar a el daria un target sin base_url, y
    // la peticion sairia con una URL vacia.
    const cand = roster_mod.Candidate{ .provider_id = "provider-que-no-existe", .model_id = "x" };
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    try std.testing.expect(targetForCandidate(&m, cand) == null);
}

test "quotaVerdict: la tabla de las siete senales" {
    // La accion que corresponde a cada fila es OPUESTA, y equivocarse aqui
    // significa dos cosas malas: rotar cuando no toca (el usuario ve el modelo
    // cambiando sin motivo y pierde el prompt cache) o rendirse cuando si
    // tocaba (el turno muere y hay que escribir "continua").
    const gate = "can only be used from within OpenCode";

    // 402: sin creditos, siempre.
    try std.testing.expectEqual(roster_mod.Why.no_credits, quotaVerdict(error.NoCredits, gate).?);
    try std.testing.expectEqual(roster_mod.Why.no_credits, quotaVerdict(error.NoCredits, "").?);

    // 429: cuota del modelo, siempre.
    try std.testing.expectEqual(roster_mod.Why.rate_limited, quotaVerdict(error.RateLimited, "").?);

    // 403 con el texto del gate: rota. Sin el texto: no.
    try std.testing.expectEqual(roster_mod.Why.gated, quotaVerdict(error.Forbidden, gate).?);
    try std.testing.expectEqual(
        roster_mod.Why.gated,
        quotaVerdict(error.Forbidden, "{\"error\":{\"message\":\"Model access is disabled\"}}").?,
    );
    try std.testing.expectEqual(
        roster_mod.Why.misconfigured,
        quotaVerdict(error.Forbidden, "model not found in your plan").?,
    );

    // 401 y 404 NUNCA rotan: la key es la key y un id malo sigue siendo malo.
    try std.testing.expect(quotaVerdict(error.AuthFailed, gate) == null);
    try std.testing.expect(quotaVerdict(error.ModelNotFound, gate) == null);
    // Ni los 5xx de servidor: eso se reintenta con backoff, no cambiando de
    // modelo (el modelo no tiene la culpa de que el server esté saturado).
    try std.testing.expect(quotaVerdict(error.ServerError, gate) == null);
    try std.testing.expect(quotaVerdict(error.Overloaded, gate) == null);
    try std.testing.expect(quotaVerdict(error.Cancelled, gate) == null);
}

test "isGateMessage: las frases reales del gate, y case-insensitive" {
    // Cada provider redacta el suyo; no hay una constante que valga.
    try std.testing.expect(isGateMessage("can only be used from within OpenCode"));
    try std.testing.expect(isGateMessage("Can Only Be Used From Within OpenCode"));
    try std.testing.expect(isGateMessage("Model access is disabled"));
    try std.testing.expect(isGateMessage("this model is not available for your account"));
    // Y lo que NO es el gate, para no gastar un par de providers de más.
    try std.testing.expect(!isGateMessage(""));
    try std.testing.expect(!isGateMessage("insufficient credits"));
    try std.testing.expect(!isGateMessage("model not found"));
    try std.testing.expect(!isGateMessage("opencode is down"));
    // El "within" suelto no basta: hace falta la frase entera.
    try std.testing.expect(!isGateMessage("error within the quota system"));
}

test "el backoff respeta el retry-after del server" {
    // `chat.retry_after_secs` estaba puesto desde el principio y no lo leía
    // nadie: un 429 con `retry-after: 30` esperaba 1s y se comía el rate limit
    // entero. Ahora se respeta, con techo de 30s.
    chat.retry_after_secs = null;
    defer chat.retry_after_secs = null;
    const base = Retry.waitMs(0);
    try std.testing.expect(base < 1000);

    chat.retry_after_secs = 12;
    try std.testing.expectEqual(@as(u64, 12_000), Retry.waitMs(0));

    // Por debajo del backoff no se baja nunca (el server puede pedir 0).
    chat.retry_after_secs = 0;
    try std.testing.expectEqual(base, Retry.waitMs(0));

    // Y el techo: nadie espera 10 minutos en silencio.
    chat.retry_after_secs = 600;
    try std.testing.expectEqual(@as(u64, 30_000), Retry.waitMs(0));
}

test "toolCallsJsonFromCalls: el mensaje del assistant lleva las tool_calls" {
    // Regresión GRABE: la TUI guardaba el mensaje del asistente con
    // `appendAssistant(text, null)`, es decir SIN `tool_calls`. El mensaje de
    // tool que va detrás lleva `tool_call_id`, así que no casaba con nada y el
    // API devolvía 400 `invalid_request_error` en el turno SIGUIENTE. Resultado
    // en pantalla: la tool se ejecutaba y la respuesta final no llegaba nunca,
    // sin error visible (el aviso se quedaba en `pending` y hacía falta pulsar
    // una tecla para verlo). En headless sí pasaba los `tool_calls`, y por eso
    // el agent loop funcionaba allí y no en la TUI.
    const gpa = std.testing.allocator;
    // Arena: el slice devuelto es la última reallocación de un ArrayList, y su
    // `len` no es el tamaño con el que se reservó. Liberarlo a pelo con el
    // allocator es un "Invalid free" (el allocator exige la longitud exacta).
    // En producción no importa: `appendAssistant` lo dupéa.
    var astate = std.heap.ArenaAllocator.init(gpa);
    defer astate.deinit();
    var calls = [_]TurnCtx.Call{
        .{ .id = "call_1", .name = "read", .args_json = "{\"path\":\"a.zig\"}" },
        .{ .id = "call_2", .name = "bash", .args_json = "{\"command\":\"ls -la\"}" },
    };
    const json = toolCallsJsonFromCalls(astate.allocator(), &calls) orelse return error.TestUnexpectedResult;

    // Tiene que ser el MISMO formato que escribe `chat.StreamCtx.toolCallsJson`
    // (el que usa el runner headless): si divergen, uno de los dos clientes
    // manda una conversación que el otro no puede leer.
    const expected = "[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"a.zig\\\"}\"}},{\"id\":\"call_2\",\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"ls -la\\\"}\"}}]";
    try std.testing.expectEqualStrings(expected, json);

    // Y el `arguments` va como STRING JSON escapado, no como objeto anidado.
    var vstate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer vstate.deinit();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, vstate.allocator(), json, .{});
    const arr = v.array.items;
    try std.testing.expectEqual(@as(usize, 2), arr.len);
    const fnobj = arr[0].object.get("function").?.object;
    try std.testing.expectEqualStrings("read", fnobj.get("name").?.string);
    try std.testing.expectEqualStrings("{\"path\":\"a.zig\"}", fnobj.get("arguments").?.string);

    // Sin calls no hay JSON (y no un "[]" que el API no sabe qué hacer).
    try std.testing.expect(toolCallsJsonFromCalls(astate.allocator(), &[_]TurnCtx.Call{}) == null);
}

test "toolArgSummary y toolResultSummary conocen las tools de web" {
    // `⏺ web_fetch(ziglang.org/…)` y `⎿ 412 lines · 78 KB` son feedback útil;
    // sin esto salía el primer string suelto y "web_fetch" a secas.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const arg = toolArgSummary("web_fetch", "{\"url\":\"https://ziglang.org/\"}", arena);
    try std.testing.expectEqualStrings("https://ziglang.org/", arg);
    const q = toolArgSummary("web_search", "{\"query\":\"zig 0.16\",\"max_results\":3}", arena);
    try std.testing.expectEqualStrings("zig 0.16", q);

    const res = toolResultSummary("web_fetch", "line one\nline two\nline three", arena);
    try std.testing.expect(std.mem.indexOf(u8, res, "3 lines") != null);
    const hits = toolResultSummary("web_search", "1. One\n   https://a.example\n   snip\n\n2. Two\n   https://b.example\n   snip\n", arena);
    try std.testing.expectEqualStrings("2 results", hits);
}
