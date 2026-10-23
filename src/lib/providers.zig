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
        .note = "the free tier requires the official client: /model or /free-auto",
    },
    .{
        .id = "openrouter",
        .name = "OpenRouter",
        .base_url = "https://openrouter.ai/api/v1",
        .models_url = "https://openrouter.ai/api/v1/models",
        .key_env = &.{"ZODE_OPENROUTER_KEY"},
        .note = "big catalogue · context and prices per model",
        .has_pricing = true,
    },
    .{
        .id = "anthropic",
        .name = "Anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .models_url = "https://api.anthropic.com/v1/models",
        .key_env = &.{"ZODE_ANTHROPIC_KEY"},
        .note = "native Messages API with prompt caching",
    },
    .{
        .id = "openai",
        .name = "OpenAI",
        .base_url = "https://api.openai.com/v1",
        .models_url = "https://api.openai.com/v1/models",
        .key_env = &.{ "ZODE_OPENAI_KEY", "ZODE_API_KEY" },
        .note = "uses max_completion_tokens and reasoning_effort",
    },
    .{
        .id = "groq",
        .name = "Groq",
        .base_url = "https://api.groq.com/openai/v1",
        .models_url = "https://api.groq.com/openai/v1/models",
        .key_env = &.{"ZODE_GROQ_KEY"},
        .note = "very low latency",
    },
    .{
        .id = "deepseek",
        .name = "DeepSeek",
        .base_url = "https://api.deepseek.com/v1",
        .models_url = "https://api.deepseek.com/v1/models",
        .key_env = &.{"ZODE_DEEPSEEK_KEY"},
        .note = "cheap reasoning",
    },
    .{
        .id = "local",
        .name = "Local (Ollama/LM Studio)",
        .base_url = "http://localhost:11434/v1",
        .models_url = "http://localhost:11434/v1/models",
        .key_env = &.{},
        .note = "no key · overrides via config.json",
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
/// ATOMIC because multiple threads (UI + workers) read it concurrently with
/// the initial write in `loadAuthKeys`. In ReleaseSmall the compiler can
/// otherwise cache the null value in a register and never see the update.
var saved_keys: std.atomic.Value(?*std.StringHashMapUnmanaged([]const u8)) = .init(null);

/// Stores the key map from `auth.json` (or null if there is none).
pub fn setSavedKeys(map: ?*std.StringHashMapUnmanaged([]const u8)) void {
    saved_keys.store(map, .release);
}

/// Key stored by the user for this provider (without looking at the env).
pub fn savedKeyFor(id: []const u8) ?[]const u8 {
    const m = saved_keys.load(.acquire) orelse return null;
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

test "keyFor: the key saved from the palette beats the one from the environment" {
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

test "keyFor: with no saved key it falls back to the environment" {
    setSavedKeys(null);
    defer setSavedKeys(null);

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const block: [:0]const u8 = "ZODE_ANTHROPIC_KEY=sk-entorno\x00";
    try env.putPosixBlock(.{ .slice = &.{block} });

    const def = byId("anthropic").?;
    try std.testing.expectEqualStrings("sk-entorno", keyFor(def, &env).?);
}

test "keyFor: with nothing it returns null" {
    setSavedKeys(null);
    defer setSavedKeys(null);
    const def = byId("anthropic").?;
    try std.testing.expect(keyFor(def, null) == null);
    try std.testing.expect(!hasKey(def, null));
}

test "no built-in provider ships with a default model" {
    // The reason the field exists and is EMPTY in all of them: a model name
    // written in the code is a clockwork time bomb. When the provider retires it
    // (which is what happened with `kimi-k2.6`, and left EVERY request at a 403
    // with no explanation), zode has nowhere to look: it can only ask the
    // provider. With the field empty, it asks.
    //
    // A user provider CAN bring one (it is in their config.json, which the
    // owner can change whenever they want); the compiled ones cannot.
    for (&defs) |d| {
        if (d.default_model.len != 0) {
            std.debug.print("provider {s} has default_model = \"{s}\"\n", .{ d.id, d.default_model });
            return error.TestUnexpectedResult;
        }
    }
}
