const std = @import("std");

pub const ProviderDef = struct {
    id: []const u8,
    name: []const u8,
    /// Base para chat completions (…/v1 o equivalente).
    base_url: []const u8,
    /// Endpoint GET de modelos.
    models_url: []const u8,
    /// Variables de entorno con la API key, en orden de preferencia.
    /// La primera no vacía gana; "" = no necesita key.
    key_env: []const []const u8,
    /// Modelo por defecto de este provider.
    default_model: []const u8,
    /// Descripción corta para el picker.
    note: []const u8 = "",
    /// Si el provider expone precios/contexto en /models.
    has_pricing: bool = false,
};

pub const defs = [_]ProviderDef{
    .{
        .id = "opencode",
        .name = "OpenCode",
        .base_url = "https://opencode.ai/inference/openai/v1",
        .models_url = "https://opencode.ai/inference/v1/models",
        .key_env = &.{ "ZODE_OPENCODE_KEY", "ZODE_API_KEY" },
        .default_model = "space-bunny-free",
        .note = "solo space-bunny-free responde: el resto del free tier exige el cliente oficial",
    },
    .{
        .id = "openrouter",
        .name = "OpenRouter",
        .base_url = "https://openrouter.ai/api/v1",
        .models_url = "https://openrouter.ai/api/v1/models",
        .key_env = &.{"ZODE_OPENROUTER_KEY"},
        .default_model = "openrouter/auto",
        .note = "catálogo grande · contexto y precios por modelo",
        .has_pricing = true,
    },
    .{
        .id = "anthropic",
        .name = "Anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .models_url = "https://api.anthropic.com/v1/models",
        .key_env = &.{"ZODE_ANTHROPIC_KEY"},
        .default_model = "claude-sonnet-4-5",
        .note = "Messages API nativa con prompt caching",
    },
    .{
        .id = "openai",
        .name = "OpenAI",
        .base_url = "https://api.openai.com/v1",
        .models_url = "https://api.openai.com/v1/models",
        .key_env = &.{ "ZODE_OPENAI_KEY", "ZODE_API_KEY" },
        .default_model = "gpt-5",
        .note = "usa max_completion_tokens y reasoning_effort",
    },
    .{
        .id = "groq",
        .name = "Groq",
        .base_url = "https://api.groq.com/openai/v1",
        .models_url = "https://api.groq.com/openai/v1/models",
        .key_env = &.{"ZODE_GROQ_KEY"},
        .default_model = "moonshotai/kimi-k2-instruct",
        .note = "muy baja latencia",
    },
    .{
        .id = "deepseek",
        .name = "DeepSeek",
        .base_url = "https://api.deepseek.com/v1",
        .models_url = "https://api.deepseek.com/v1/models",
        .key_env = &.{"ZODE_DEEPSEEK_KEY"},
        .default_model = "deepseek-chat",
        .note = "razonamiento económico",
    },
    .{
        .id = "local",
        .name = "Local (Ollama/LM Studio)",
        .base_url = "http://localhost:11434/v1",
        .models_url = "http://localhost:11434/v1/models",
        .key_env = &.{},
        .default_model = "qwen3-coder",
        .note = "sin key · overrides por config.json",
    },
};

pub fn byId(id: []const u8) ?*const ProviderDef {
    for (&defs) |*d| {
        if (std.mem.eql(u8, d.id, id)) return d;
    }
    return null;
}

pub fn activeDef(env: ?*const std.process.Environ.Map) *const ProviderDef {
    const id = envGet(env, "ZODE_PROVIDER") orelse "opencode";
    return byId(id) orelse &defs[0];
}

/// Las keys guardadas con "Connect an integration", indexadas por provider id.
///
/// Viven en memoria (se cargan de `~/.config/zode/auth.json` al arrancar y se
/// actualizan al guardar) porque `keyFor` se llama en cada request y no puede
/// permitirse leer un fichero del disco cada vez. `setup` la rellena una vez.
var saved_keys: ?*std.StringHashMapUnmanaged([]const u8) = null;

/// Guarda el mapa de keys de `auth.json` (o null si no hay).
pub fn setSavedKeys(map: ?*std.StringHashMapUnmanaged([]const u8)) void {
    saved_keys = map;
}

/// Key guardada por el usuario para este provider (sin mirar el entorno).
pub fn savedKeyFor(id: []const u8) ?[]const u8 {
    const m = saved_keys orelse return null;
    return m.get(id);
}

pub fn keyFor(def: *const ProviderDef, env: ?*const std.process.Environ.Map) ?[]const u8 {
    // 1) La guardada con la paleta: es lo que el usuario acaba de teclear.
    if (savedKeyFor(def.id)) |k| {
        if (k.len > 0) return k;
    }
    // 2) Las variables de entorno: mandan sobre `ZODE_API_KEY` si hay alguna
    //    específica, y permiten seguir funcionando con .env como hasta ahora.
    for (def.key_env) |var_name| {
        if (envGet(env, var_name)) |k| {
            if (k.len > 0) return k;
        }
    }
    return null;
}

/// ¿Tiene key este provider? (para el picker y /providers)
pub fn hasKey(def: *const ProviderDef, env: ?*const std.process.Environ.Map) bool {
    if (def.key_env.len == 0) return true; // no necesita key
    return keyFor(def, env) != null;
}

fn envGet(env: ?*const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const m = env orelse return null;
    return m.get(key);
}

test "keyFor: la key guardada en la paleta gana a la del entorno" {
    // El orden importa: si el entorno ganara, conectar un provider desde la
    // TUI no serviría de nada mientras haya un .env con una key vieja.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const map = try a.create(std.StringHashMapUnmanaged([]const u8));
    map.* = .{};
    try map.put(a, "anthropic", "sk-guardada");

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const block: [:0]const u8 = "ZODE_ANTHROPIC_KEY=sk-entorno\x00";
    try env.putPosixBlock(.{ .slice = &.{block} });

    setSavedKeys(map);
    defer setSavedKeys(null);

    const def = byId("anthropic").?;
    try std.testing.expectEqualStrings("sk-guardada", keyFor(def, &env).?);
    try std.testing.expect(hasKey(def, &env));
}

test "keyFor: sin key guardada cae al entorno" {
    setSavedKeys(null);
    defer setSavedKeys(null);

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const block: [:0]const u8 = "ZODE_ANTHROPIC_KEY=sk-entorno\x00";
    try env.putPosixBlock(.{ .slice = &.{block} });

    const def = byId("anthropic").?;
    try std.testing.expectEqualStrings("sk-entorno", keyFor(def, &env).?);
}

test "keyFor: sin nada devuelve null" {
    setSavedKeys(null);
    defer setSavedKeys(null);
    const def = byId("anthropic").?;
    try std.testing.expect(keyFor(def, null) == null);
    try std.testing.expect(!hasKey(def, null));
}
