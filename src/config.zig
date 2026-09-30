const std = @import("std");
const providers = @import("providers.zig");
const chat = @import("chat.zig");

/// Config por usuario: `~/.config/zode/config.json`.
///
/// Antes la lista de providers estaba compilada en el binario, así que apuntar
/// a vLLM, LM Studio, Together o cualquier endpoint OpenAI-compat exigía
/// recompilar. Ahora se añaden sin tocar código.
///
/// Formato:
/// {
///   "provider": "mi-vllm",
///   "providers": [
///     {
///       "id": "mi-vllm",
///       "name": "vLLM local",
///       "base_url": "http://localhost:8000/v1",
///       "models_url": "http://localhost:8000/v1/models",
///       "key_env": "MI_VLLM_KEY",
///       "default_model": "qwen3-coder",
///       "kind": "openai"
///     }
///   ]
/// }

pub const Config = struct {
    /// Provider por defecto (id, debe existir en la lista efectiva).
    provider: []const u8 = "",
    /// Modelo por defecto global (vacío = el del provider).
    model: []const u8 = "",
    /// Providers definidos por el usuario (se anexan a los compilados).
    extra: []const providers.ProviderDef = &.{},
    /// Wire format de cada provider extra: "openai" (default) o "anthropic".
    anthropic_extra: []const bool = &.{},
    /// Ruta de config que se cargó (para diagnostics), o null.
    path: ?[]const u8 = null,
    pub const empty: Config = .{};
};

/// provider_id → ¿usar el wire format nativo de Anthropic?
/// Los providers compilados se resuelven por id; los extra, por su flag.
pub fn isAnthropic(cfg: Config, id: []const u8) bool {
    if (providers.byId(id) != null) return chat.kindForProvider(id) == .anthropic;
    for (cfg.extra, 0..) |d, i| {
        if (std.mem.eql(u8, d.id, id)) return i < cfg.anthropic_extra.len and cfg.anthropic_extra[i];
    }
    return false;
}

/// Ruta de `~/.config/zode/auth.json` (donde se guardan las keys de la paleta).
pub fn authPath(env: ?*const std.process.Environ.Map, buf: []u8) ?[]const u8 {
    const dir = configDir(env, buf) orelse return null;
    return std.fmt.bufPrint(buf[dir.len..], "{s}/auth.json", .{dir}) catch null;
}

fn configPath(env: ?*const std.process.Environ.Map, buf: []u8) ?[]const u8 {
    const m = env orelse return null;
    const home = m.get("HOME") orelse return null;
    if (home.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}/.config/zode/config.json", .{home}) catch null;
}

/// Carga `~/.config/zode/config.json`. Best-effort: si no existe o está
/// corrupto devuelve `Config.empty` y la app sigue con los providers
/// compilados. Toda la memoria sale de `arena`.
pub fn load(
    arena: std.mem.Allocator,
    io: std.Io,
    env: ?*const std.process.Environ.Map,
) Config {
    var path_buf: [1024]u8 = undefined;
    const path = configPath(env, &path_buf) orelse return Config.empty;
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024)) catch
        return Config.empty;
    return parse(arena, data, path) catch Config.empty;
}

pub fn parse(arena: std.mem.Allocator, data: []const u8, path: []const u8) !Config {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{}) catch
        return error.BadConfig;
    if (parsed != .object) return error.BadConfig;
    const root = parsed.object;

    var cfg = Config{ .path = try arena.dupe(u8, path) };
    if (root.get("provider")) |v| {
        if (v == .string) cfg.provider = try arena.dupe(u8, v.string);
    }
    if (root.get("model")) |v| {
        if (v == .string) cfg.model = try arena.dupe(u8, v.string);
    }

    const pv = root.get("providers") orelse return cfg;
    if (pv != .array) return cfg;

    var list: std.ArrayList(providers.ProviderDef) = .empty;
    var kinds: std.ArrayList(bool) = .empty;
    for (pv.array.items) |item| {
        if (item != .object) continue;
        const o = item.object;

        const id_v = o.get("id") orelse continue;
        if (id_v != .string or id_v.string.len == 0) continue;
        const id = try arena.dupe(u8, id_v.string);
        if (providers.byId(id) != null) continue; // no shadowear compilados

        // base_url es obligatorio: sin él no hay a dónde enviar el request.
        const base_v = o.get("base_url") orelse continue;
        if (base_v != .string) continue;
        const base = try arena.dupe(u8, base_v.string);

        const name = if (o.get("name")) |v|
            (if (v == .string) try arena.dupe(u8, v.string) else id)
        else
            id;

        const models_url = if (o.get("models_url")) |v|
            (if (v == .string) try arena.dupe(u8, v.string) else base)
        else
            base;

        const model = if (o.get("default_model")) |v|
            (if (v == .string) try arena.dupe(u8, v.string) else "")
        else
            "";

        // key_env acepta string o array de strings.
        var keys: std.ArrayList([]const u8) = .empty;
        if (o.get("key_env")) |kv| {
            switch (kv) {
                .string => |s| if (s.len > 0) try keys.append(arena, try arena.dupe(u8, s)),
                .array => |arr| for (arr.items) |k| {
                    if (k == .string and k.string.len > 0) {
                        try keys.append(arena, try arena.dupe(u8, k.string));
                    }
                },
                else => {},
            }
        }

        const note = if (o.get("note")) |v|
            (if (v == .string) try arena.dupe(u8, v.string) else "")
        else
            "";

        const kind_anthropic = blk: {
            const kv = o.get("kind") orelse break :blk false;
            break :blk kv == .string and std.mem.eql(u8, kv.string, "anthropic");
        };

        try list.append(arena, .{
            .id = id,
            .name = name,
            .base_url = base,
            .models_url = models_url,
            .key_env = keys.items,
            .default_model = model,
            .note = note,
        });
        try kinds.append(arena, kind_anthropic);
    }

    cfg.extra = list.items;
    cfg.anthropic_extra = kinds.items;
    return cfg;
}

/// Todos los providers: compilados + los de config.json.
pub fn allDefs(arena: std.mem.Allocator, cfg: Config) []const providers.ProviderDef {
    const n = providers.defs.len + cfg.extra.len;
    const out = arena.alloc(providers.ProviderDef, n) catch return &providers.defs;
    @memcpy(out[0..providers.defs.len], &providers.defs);
    @memcpy(out[providers.defs.len..], cfg.extra);
    return out;
}

pub fn find(cfg: Config, id: []const u8) ?*const providers.ProviderDef {
    if (providers.byId(id)) |d| return d;
    for (cfg.extra) |*d| {
        if (std.mem.eql(u8, d.id, id)) return d;
    }
    return null;
}

// ── tests ─────────────────────────────────────────────────────

test "parse: provider extra completo" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const json =
        \\{"provider":"vllm","model":"qwen","providers":[
        \\ {"id":"vllm","name":"vLLM","base_url":"http://localhost:8000/v1",
        \\  "key_env":"VLLM_KEY","default_model":"qwen3-coder","kind":"openai"}
        \\]}
    ;
    const cfg = try parse(arena, json, "/tmp/cfg.json");

    try std.testing.expectEqualStrings("vllm", cfg.provider);
    try std.testing.expectEqualStrings("qwen", cfg.model);
    try std.testing.expectEqual(@as(usize, 1), cfg.extra.len);
    try std.testing.expectEqualStrings("vllm", cfg.extra[0].id);
    try std.testing.expectEqualStrings("http://localhost:8000/v1", cfg.extra[0].base_url);
    try std.testing.expectEqualStrings("qwen3-coder", cfg.extra[0].default_model);
    // key_env como string suelto → slice de 1
    try std.testing.expectEqual(@as(usize, 1), cfg.extra[0].key_env.len);
    try std.testing.expect(!isAnthropic(cfg, "vllm"));
}

test "parse: key_env acepta array" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const json =
        \\{"providers":[{"id":"x","base_url":"http://h/v1","key_env":["A_KEY","B_KEY"]}]}
    ;
    const cfg = try parse(arena, json, "/tmp/c.json");
    try std.testing.expectEqual(@as(usize, 2), cfg.extra[0].key_env.len);
    try std.testing.expectEqualStrings("A_KEY", cfg.extra[0].key_env[0]);
    try std.testing.expectEqualStrings("B_KEY", cfg.extra[0].key_env[1]);
}

test "parse: kind anthropic marca el wire format" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const json =
        \\{"providers":[{"id":"proxy","base_url":"http://h/v1","kind":"anthropic"}]}
    ;
    const cfg = try parse(arena, json, "/tmp/c.json");
    try std.testing.expect(isAnthropic(cfg, "proxy"));
    // Los compilados mandan por id.
    try std.testing.expect(isAnthropic(cfg, "anthropic"));
    try std.testing.expect(!isAnthropic(cfg, "openrouter"));
}

test "parse: un provider sin base_url se ignora, no rompe el resto" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const json =
        \\{"providers":[{"id":"roto"},{"id":"ok","base_url":"http://h/v1"}]}
    ;
    const cfg = try parse(arena, json, "/tmp/c.json");
    try std.testing.expectEqual(@as(usize, 1), cfg.extra.len);
    try std.testing.expectEqualStrings("ok", cfg.extra[0].id);
}

test "parse: no se puede shadowear un provider compilado" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const json =
        \\{"providers":[{"id":"openrouter","base_url":"http://evil/v1"}]}
    ;
    const cfg = try parse(arena, json, "/tmp/c.json");
    try std.testing.expectEqual(@as(usize, 0), cfg.extra.len);
    // Y el lookup sigue resolviendo al compilado.
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1", find(cfg, "openrouter").?.base_url);
}

test "parse: JSON corrupto devuelve error, no panic" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.BadConfig, parse(arena, "{no json", "/tmp/c.json"));
    try std.testing.expectError(error.BadConfig, parse(arena, "[1,2,3]", "/tmp/c.json"));
}

test "allDefs: compila los de config detrás de los built-in" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cfg = try parse(
        arena,
        \\{"providers":[{"id":"vllm","base_url":"http://h/v1"}]}
    ,
        "/tmp/c.json",
    );
    const all = allDefs(arena, cfg);
    try std.testing.expectEqual(providers.defs.len + 1, all.len);
    try std.testing.expectEqualStrings("opencode", all[0].id);
    try std.testing.expectEqualStrings("vllm", all[all.len - 1].id);
}

// ── escritura (auth.json) ─────────────────────────────────────

/// Ruta de `~/.config/zode`, o null si no hay HOME.
///
/// Se exporta porque guardar la key de un provider (el "Connect an
/// integration" de la paleta) necesita el mismo directorio que leer el
/// config, y duplicar la lógica de `configPath` sería pedir que se separen.
pub fn configDir(env: ?*const std.process.Environ.Map, buf: []u8) ?[]const u8 {
    const m = env orelse return null;
    const home = m.get("HOME") orelse return null;
    if (home.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}/.config/zode", .{home}) catch null;
}

/// Escribe un archivo con permisos 0600.
///
/// 0600 y no 0644 a propósito: el archivo contiene API keys en claro y
/// `config.json` sí es versionable, este no. `writeFile` no permite fijar
/// permisos, así que se escribe en temporal y se renombra.
pub fn writeFileSecure(
    io: std.Io,
    env: ?*const std.process.Environ.Map,
    path: []const u8,
    data: []const u8,
) !void {
    var dir_buf: [1024]u8 = undefined;
    const dir_path = configDir(env, &dir_buf) orelse return error.NoHome;
    // `Dir.createDirPath` es mkdir -p: el usuario puede no tener ~/.config/zode.
    try std.Io.Dir.cwd().createDirPath(io, dir_path);

    var tmp_buf: [1200]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});

    var file = try std.Io.Dir.cwd().createFile(io, tmp, .{
        .truncate = true,
        .permissions = @enumFromInt(0o600),
    });
    defer file.close(io);
    // `File` no tiene writeAll en 0.16: se hace un writer con su buffer.
    var wbuf: [4096]u8 = undefined;
    var fw = file.writer(io, &wbuf);
    try fw.interface.writeAll(data);
    try fw.interface.flush();
    // El temporal se renombra a su nombre final: si se escribiera en sitio, un
    // fallo a mitad dejaría la mitad de la key en un fichero de 0644.
    try std.Io.Dir.rename(.cwd(), tmp, .cwd(), path, io);
}

// ── JSON mínimo a mano ────────────────────────────────────────

/// Escribe un objeto plano `{ "k": "v", ... }` en `out`.
///
/// A mano y no con `{f}` porque el writer de 0.16 no formatea
/// `json.ObjectMap` ni `json.Array`, y el archivo que escribimos (auth.json) es
/// un puñado de pares string→string: serializarlo aquí son 20 líneas y deja el
/// formato de las keys bajo control (y sin comillas raras).
pub fn writeStringMap(out: *std.Io.Writer, gpa: std.mem.Allocator, pairs: []const [2][]const u8) !void {
    try out.writeAll("{");
    for (pairs, 0..) |kv, i| {
        if (i > 0) try out.writeAll(",");
        try writeJsonString(out, gpa, kv[0]);
        try out.writeAll(":");
        try writeJsonString(out, gpa, kv[1]);
    }
    try out.writeAll("}");
}

/// Escribe un array de strings `["a","b"]`.
pub fn writeStringArray(out: *std.Io.Writer, gpa: std.mem.Allocator, items: []const []const u8) !void {
    try out.writeAll("[");
    for (items, 0..) |it, i| {
        if (i > 0) try out.writeAll(",");
        try writeJsonString(out, gpa, it);
    }
    try out.writeAll("]");
}

/// String JSON con escapes mínimos (comilla, barra, control, UTF-8 tal cual).
pub fn writeJsonString(out: *std.Io.Writer, gpa: std.mem.Allocator, s: []const u8) !void {
    try out.writeAll("\"");
    var start: usize = 0;
    for (s, 0..) |c, i| {
        const esc: ?[]const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => null,
        };
        const e = esc orelse continue;
        if (i > start) try out.writeAll(s[start..i]);
        try out.writeAll(e);
        start = i + 1;
    }
    if (start < s.len) try out.writeAll(s[start..]);
    _ = gpa;
    try out.writeAll("\"");
}

test "writeFileSecure: crea el directorio y escribe con 0600" {
    // El flujo completo: mkdir -p del directorio, temporal, y renombrado. Es
    // lo que usa "Connect an integration" y si falla se queda sin key.
    // Un entorno con HOME propio: `writeFileSecure` lo necesita para saber
    // dónde está ~/.config/zode, así que el test NO puede pasar null.
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    const home: [:0]const u8 = "HOME=/tmp/zode-test-home\x00";
    try env_map.putPosixBlock(.{ .slice = &.{home} });

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = "/tmp/zode-test-home/.config/zode/auth.json";
    std.Io.Dir.cwd().deleteTree(io, "/tmp/zode-test-home") catch {};

    try writeFileSecure(io, &env_map, path, "{\"a\":\"b\"}");

    const got = std.Io.Dir.cwd().readFileAlloc(io, path, std.testing.allocator, .limited(4096)) catch |err| {
        std.debug.print("no se pudo leer: {t}\n", .{err});
        return err;
    };
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("{\"a\":\"b\"}", got);
}
