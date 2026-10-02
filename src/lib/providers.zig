const std = @import("std");

pub const ProviderDef = struct {
    id: []const u8,
    name: []const u8,
    /// Base for chat completions (…/v1 or equivalent).
    base_url: []const u8,
    /// GET endpoint for models.
    models_url: []const u8,
    /// Environment variables holding the API key, in order of preference.
    /// The first non-empty one wins; "" = needs no key.
    key_env: []const []const u8,
    /// The model to use when the user has NOT chosen one.
    ///
    /// It is a LAST RESORT and not a promise: a name hardcoded here is a bomb
    /// with a timer, because the day a provider retires it, EVERY request starts
    /// failing with a 403 that says nothing about why. So it is only reached after
    /// asking the provider what its catalogue actually contains (see
    /// `agent.resolveModel`), and every provider without one leaves it EMPTY: an
    /// empty field is what makes zode ask instead of guessing.
    ///
    /// It is also not what the status bar shows as "the" model once something has
    /// been chosen, obviously.
    default_model: []const u8 = "",
    /// Short description for the picker.
    note: []const u8 = "",
    /// Whether the provider exposes pricing/context in /models.
    has_pricing: bool = false,
};

pub const defs = [_]ProviderDef{
    .{
        .id = "opencode",
        .name = "OpenCode",
        .base_url = "https://opencode.ai/inference/openai/v1",
        .models_url = "https://opencode.ai/inference/v1/models",
        .key_env = &.{ "ZODE_OPENCODE_KEY", "ZODE_API_KEY" },
        .note = "el free tier exige el cliente oficial: /model o /free-auto",
    },
    .{
        .id = "openrouter",
        .name = "OpenRouter",
        .base_url = "https://openrouter.ai/api/v1",
        .models_url = "https://openrouter.ai/api/v1/models",
        .key_env = &.{"ZODE_OPENROUTER_KEY"},
        .note = "catálogo grande · contexto y precios por modelo",
        .has_pricing = true,
    },
    .{
        .id = "anthropic",
        .name = "Anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .models_url = "https://api.anthropic.com/v1/models",
        .key_env = &.{"ZODE_ANTHROPIC_KEY"},
        .note = "Messages API nativa con prompt caching",
    },
    .{
        .id = "openai",
        .name = "OpenAI",
        .base_url = "https://api.openai.com/v1",
        .models_url = "https://api.openai.com/v1/models",
        .key_env = &.{ "ZODE_OPENAI_KEY", "ZODE_API_KEY" },
        .note = "usa max_completion_tokens y reasoning_effort",
    },
    .{
        .id = "groq",
        .name = "Groq",
        .base_url = "https://api.groq.com/openai/v1",
        .models_url = "https://api.groq.com/openai/v1/models",
        .key_env = &.{"ZODE_GROQ_KEY"},
        .note = "muy baja latencia",
    },
    .{
        .id = "deepseek",
        .name = "DeepSeek",
        .base_url = "https://api.deepseek.com/v1",
        .models_url = "https://api.deepseek.com/v1/models",
        .key_env = &.{"ZODE_DEEPSEEK_KEY"},
        .note = "razonamiento económico",
    },
    .{
        .id = "local",
        .name = "Local (Ollama/LM Studio)",
        .base_url = "http://localhost:11434/v1",
        .models_url = "http://localhost:11434/v1/models",
        .key_env = &.{},
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

/// Keys stored via "Connect an integration", indexed by provider id.
///
/// They live in memory (loaded from `~/.config/zode/auth.json` at startup and
/// updated on save) because `keyFor` runs on every request and cannot afford to
/// read a file from disk each time. `setup` fills it once.
var saved_keys: ?*std.StringHashMapUnmanaged([]const u8) = null;

/// Stores the key map from `auth.json` (or null if there is none).
pub fn setSavedKeys(map: ?*std.StringHashMapUnmanaged([]const u8)) void {
    saved_keys = map;
}

/// Key stored by the user for this provider (without looking at the env).
pub fn savedKeyFor(id: []const u8) ?[]const u8 {
    const m = saved_keys orelse return null;
    return m.get(id);
}

pub fn keyFor(def: *const ProviderDef, env: ?*const std.process.Environ.Map) ?[]const u8 {
    // 1) The one stored via the palette: what the user just typed.
    if (savedKeyFor(def.id)) |k| {
        if (k.len > 0) return k;
    }
    // 2) The environment variables: they beat `ZODE_API_KEY` if there is a
    //    specific one, and keep .env working as it does today.
    for (def.key_env) |var_name| {
        if (envGet(env, var_name)) |k| {
            if (k.len > 0) return k;
        }
    }
    return null;
}

/// Does this provider have a key? (for the picker and /providers)
pub fn hasKey(def: *const ProviderDef, env: ?*const std.process.Environ.Map) bool {
    if (def.key_env.len == 0) return true; // needs no key
    return keyFor(def, env) != null;
}

fn envGet(env: ?*const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const m = env orelse return null;
    return m.get(key);
}

test "keyFor: la key guardada en la paleta gana a la del entorno" {
    // The order matters: if the env won, connecting a provider from the TUI
    // would be useless as long as there is an .env with an old key.
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

test "ningun provider compilado trae un modelo por defecto" {
    // La razon de que el campo exista y este VACIO en todos: un nombre de modelo
    // escrito en el codigo es una bomba de relojería. Cuando el provider lo retira
    // (que es lo que paso con `kimi-k2.6`, y dejo TODAS las peticiones en 403 sin
    // explicacion), zode no tiene ni donde mirar: solo puede preguntarle al
    // provider. Con el campo vacio, pregunta.
    //
    // Un provider de usuario SI puede traer uno (esta en su config.json, que el
    // Dueño puede cambiar cuando quiera); los compilados, no.
    for (&defs) |d| {
        if (d.default_model.len != 0) {
            std.debug.print("provider {s} tiene default_model = \"{s}\"\n", .{ d.id, d.default_model });
            return error.TestUnexpectedResult;
        }
    }
}
