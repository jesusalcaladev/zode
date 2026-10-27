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
    /// How the provider wants its key when it LISTS its catalogue.
    ///
    /// Not cosmetic, and not the chat path (`chat.streamRaw` builds its own
    /// headers). `models.listModels` used to send `Authorization: Bearer` and
    /// nothing else, and Anthropic has no Bearer at all: its catalogue answers
    /// 401 `invalid x-api-key`, which `resolveModel` reports as "the catalog
    /// could not be read". Anthropic therefore had no pickable models and the
    /// only way to use it was to type the name by hand.
    key_style: KeyStyle = .bearer,
    /// The model ids the provider DOCUMENTS, for the providers that publish no
    /// `/models` endpoint (their `models_url` is empty, so there is nothing to
    /// fetch and the picker would be an empty box).
    ///
    /// This is NOT `default_model` and it is not a guess about which one to use:
    /// zode still refuses to pick by itself and the choice stays with the user.
    /// It is the list the picker SHOWS, so the user can point at one instead of
    /// typing its name. It will age — that is why it is only ever a suggestion
    /// and never written to the catalogue cache (a retired id fails loudly at
    /// the first request instead of silently becoming the session's model).
    suggested_models: []const []const u8 = &.{},
    /// Hard cap on max_tokens/max_completion_tokens sent to this provider.
    /// 0 = no provider-specific cap (use effort's outputCeiling).
    /// NVIDIA NIM documents per-model maxima as low as 4096; 16384 is a safe
    /// default that covers Nemotron/DeepSeek/Kimi/GLM without hitting the
    /// legacy models' limits.
    max_output_tokens: u32 = 0,
    /// Preferred model IDs, in order. Used by resolveModel when the catalogue
    /// contains them. Empty = no preference (first free / first model).
    preferred_models: []const []const u8 = &.{},
};

pub const KeyStyle = enum { bearer, x_api_key };

/// The credentials one request to a catalogue needs. A value produced by
/// `authWithKey` / `catalogAuth`, so no caller has to remember which provider
/// uses which header.
pub const CatalogAuth = struct {
    bearer: ?[]const u8 = null,
    x_api_key: ?[]const u8 = null,
};

pub fn authWithKey(style: KeyStyle, key: ?[]const u8) CatalogAuth {
    return switch (style) {
        .bearer => .{ .bearer = key },
        .x_api_key => .{ .x_api_key = key },
    };
}

pub fn catalogAuth(def: *const ProviderDef, env: ?*const std.process.Environ.Map) CatalogAuth {
    return authWithKey(def.key_style, keyFor(def, env));
}

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
        // x-api-key, and NOT Bearer: verified with curl, `GET /v1/models` with
        // `Authorization: Bearer …` answers 401 `invalid x-api-key`.
        .key_style = .x_api_key,
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
    .{
        .id = "mistral",
        .name = "Mistral",
        .base_url = "https://api.mistral.ai/v1",
        .models_url = "https://api.mistral.ai/v1/models",
        .key_env = &.{"ZODE_MISTRAL_KEY"},
        .note = "fast and capable models",
    },
    .{
        .id = "command-code",
        .name = "CommandCode",
        .base_url = "https://api.commandcode.ai/provider/v1",
        .models_url = "https://api.commandcode.ai/provider/v1/models",
        .key_env = &.{"ZODE_COMMAND_CODE_KEY"},
        .note = "code-focused models",
    },
    .{
        .id = "github-copilot",
        .name = "GitHub Copilot",
        // NOT `/models`: `base_url` is the PREFIX and `/chat/completions` is
        // appended to it, so this used to send every request to
        // `…/models/chat/completions`. The catalogue endpoint needs the suffix;
        // the chat base must not have it.
        .base_url = "https://api.githubcopilot.com",
        .models_url = "https://api.githubcopilot.com/models",
        .key_env = &.{"ZODE_GITHUB_COPILOT_KEY"},
        .note = "code completion and chat · the chat API also wants its own headers",
    },
    .{
        .id = "xai",
        .name = "xAI",
        .base_url = "https://api.x.ai/v1",
        .models_url = "https://api.x.ai/v1/models",
        .key_env = &.{"ZODE_XAI_KEY"},
        .note = "Grok models",
    },
    .{
        .id = "zai",
        .name = "Z.AI",
        // The OpenAI-compatible path. `/api/v1` is their Responses API and
        // `/api/anthropic` their Messages API; zode speaks chat/completions.
        .base_url = "https://api.z.ai/api/paas/v4",
        // EMPTY ON PURPOSE, and verified against their OpenAPI document: the
        // only paths are chat/completions, images, videos, audio, tokenizer,
        // web_search, reader and files. Nothing lists models, so the empty URL
        // says "publishes no catalogue" and the picker falls back to
        // `suggested_models`.
        .models_url = "",
        .key_env = &.{ "ZODE_ZAI_KEY", "ZAI_API_KEY" },
        .note = "GLM · 1M context · no model list: /model shows the documented ids",
        .suggested_models = &.{ "glm-5.3", "glm-5.3-flash", "glm-5.3-flashx", "glm-5.2", "glm-4.7" },
    },
    .{
        .id = "zai-coding",
        .name = "Z.AI Coding Plan",
        // The subscription endpoint: same chat/completions shape, quota instead
        // of per-token billing.
        .base_url = "https://api.z.ai/api/coding/paas/v4",
        .models_url = "",
        // A SEPARATE key from the API one (their guide: the two are managed
        // apart since 2026-10-16). A plan key at the standard endpoint is a 401
        // that says nothing about which key went to which URL, so the two rows
        // exist instead of one row plus a footnote.
        .key_env = &.{"ZODE_ZAI_CODING_KEY"},
        .note = "subscription quota · key is NOT the API key",
        .suggested_models = &.{ "glm-5.3", "glm-5.3-flash", "glm-5.2" },
    },
    .{
        .id = "nvidia",
        .name = "NVIDIA NIM",
        .base_url = "https://integrate.api.nvidia.com/v1",
        .models_url = "https://integrate.api.nvidia.com/v1/models",
        .key_env = &.{ "ZODE_NVIDIA_KEY", "NVIDIA_API_KEY" },
        .note = "hosted NIM · key from build.nvidia.com",
        .max_output_tokens = 16384,
        // ORDER MATTERS: `agent.resolveModel` takes the first id here that the
        // catalog publishes. The list is not a wish list — it is the answer for
        // a user who has not picked anything, and the first element is the model
        // every one of them gets on the first turn.
        //
        // GLM-5.3 leads because it is the one verified end to end against the
        // hosted API (streaming, `stream_options`, tool calls, `reasoning_effort`
        // — all 200). The Nemotron/Kimi/DeepSeek rows stay as fallbacks: they are
        // in the catalog and several accounts can use them, while a catalog
        // entry is not a promise of access (`Function '<uuid>': Not found for
        // account` is what a 404 looks like when it is not).
        .preferred_models = &.{
            "z-ai/glm-5.3",
            "nvidia/nemotron-3-super-120b-a12b",
            "nvidia/nemotron-3.5-lightning-30b-a3b",
            "nvidia/nemotron-3-ultra-550b-a55b",
            "nvidia/nemotron-3.5-bolt-e4b",
            "moonshotai/kimi-k2.6",
            "deepseek-ai/deepseek-v4.1-flash",
            "z-ai/glm-5.3-flash",
        },
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

test "catalogAuth: anthropic authenticates with x-api-key, everyone else with the bearer" {
    // The two styles are not interchangeable. Sending Anthropic a Bearer is a
    // 401 that reads as "no catalogue", which is the bug this field fixes.
    const anthropic = authWithKey(byId("anthropic").?.key_style, "sk-ant-x");
    try std.testing.expect(anthropic.bearer == null);
    try std.testing.expectEqualStrings("sk-ant-x", anthropic.x_api_key.?);

    const openai = authWithKey(byId("openai").?.key_style, "sk-x");
    try std.testing.expect(openai.x_api_key == null);
    try std.testing.expectEqualStrings("sk-x", openai.bearer.?);

    // No key is not an error here: the request goes out and the provider says
    // 401, which is the honest answer for a provider nobody connected.
    const none = authWithKey(.x_api_key, null);
    try std.testing.expect(none.x_api_key == null);
}

test "a provider with no catalog ships the ids the picker can show" {
    // An empty `models_url` with no suggestions is a provider the user can only
    // reach by typing a model name from memory: the picker opens on "+ connect"
    // and nothing else. The two fields go together.
    for (&defs) |d| {
        if (d.models_url.len != 0) continue;
        if (d.suggested_models.len == 0) {
            std.debug.print("provider {s} publishes no catalogue and suggests no models\n", .{d.id});
            return error.TestUnexpectedResult;
        }
        for (d.suggested_models) |id| {
            if (id.len == 0) return error.TestUnexpectedResult;
        }
    }
}

test "no provider's chat base is a models (or chat) endpoint" {
    // `base_url` is a PREFIX: `main.zig`, `agent.zig` and `lib/provider.zig` all
    // append `/chat/completions` to it. A base that already ends in `/models`
    // therefore sends every request to `…/models/chat/completions`, and the
    // failure reads as "the provider is down" — github-copilot shipped like
    // that. HTTPS on port 443 for all of them, so the test is on the PATH only.
    for (&defs) |d| {
        if (std.mem.endsWith(u8, d.base_url, "/models") or
            std.mem.endsWith(u8, d.base_url, "/chat/completions") or
            std.mem.endsWith(u8, d.base_url, "/messages"))
        {
            std.debug.print("provider {s} has base_url = \"{s}\": /chat/completions is appended to it\n", .{ d.id, d.base_url });
            return error.TestUnexpectedResult;
        }
    }
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

test "nvidia provider has correct config" {
    const nvidia = byId("nvidia").?;
    try std.testing.expectEqualStrings("https://integrate.api.nvidia.com/v1", nvidia.base_url);
    try std.testing.expectEqualStrings("https://integrate.api.nvidia.com/v1/models", nvidia.models_url);
    try std.testing.expectEqualStrings("ZODE_NVIDIA_KEY", nvidia.key_env[0]);
    try std.testing.expectEqualStrings("NVIDIA_API_KEY", nvidia.key_env[1]);
    try std.testing.expectEqualStrings("hosted NIM · key from build.nvidia.com", nvidia.note);
    try std.testing.expect(nvidia.max_output_tokens == 16384);
    try std.testing.expect(nvidia.preferred_models.len == 8);
    // The first one is the answer for a user who picked nothing: it has to be a
    // model that was actually verified against the hosted API.
    try std.testing.expect(std.mem.eql(u8, nvidia.preferred_models[0], "z-ai/glm-5.3"));
}
