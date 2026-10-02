const std = @import("std");
const http_client = @import("lib/http_client.zig");
const acp = @import("acp.zig");

/// Io set up by the TUI/CLI at startup.
///
/// CAREFUL: it is NO LONGER used for sleeping (see `sleepMs`): `Io.sleep` from
/// a worker takes the TUI's event loop down with it. It stays here for the rest
/// of the HTTP layer.
pub var io_global: std.Io = undefined;

/// How hard the model should think.
///
/// It is an enum of LEVELS and nothing else: the output ceiling lives in
/// `outputCeiling` and the thinking budget in `thinkingBudget`. It used to be an
/// `enum(u32)` whose VALUE was `max_tokens` (low=4096, xhigh=49152), which
/// welded two unrelated decisions together and produced two real bugs:
///
///  - "more effort" silently also meant "shorter answers". Asking for xhigh
///    thinking gave the model a 49152-token ceiling but anything above `high`
///    was squashed to `"high"` on the wire, so the extra room bought nothing
///    and the model still could not think longer.
///  - A model that supports MORE than our top level (Gemini's `minimal`,
///    OpenAI's `none`, OpenRouter's `xhigh`) had no way to be asked for it,
///    because the enum had no such member. `maxEffortFor` is how a model that
///    supports more gets used instead of clamped.
pub const Effort = enum {
    /// Spend nothing on reasoning. OpenAI o-series and gpt-5 take it; a model
    /// that does not will simply get the closest level it does accept.
    none,
    /// The cheapest level that is still "some" reasoning. Gemini 2.5 and
    /// OpenAI's newer reasoning models call it `minimal`.
    minimal,
    low,
    medium,
    high,
    /// Above `high`. Only some models take it (OpenAI gpt-5.1+, OpenRouter).
    xhigh,

    pub fn parse(s: []const u8) ?Effort {
        const eq = std.ascii.eqlIgnoreCase;
        if (eq(s, "none") or eq(s, "off")) return .none;
        if (eq(s, "minimal")) return .minimal;
        if (eq(s, "low")) return .low;
        if (eq(s, "medium") or eq(s, "med")) return .medium;
        if (eq(s, "high")) return .high;
        if (eq(s, "xhigh") or eq(s, "max")) return .xhigh;
        return null;
    }

    pub fn label(self: Effort) []const u8 {
        return @tagName(self);
    }

    /// What to ask for when this model does not take the level we want: the
    /// nearest one BELOW it. Never above, because overshooting is what 400s.
    pub fn degrade(self: Effort) Effort {
        return switch (self) {
            .none => .none,
            .minimal => .minimal,
            .low => .low,
            .medium => .low,
            .high => .medium,
            .xhigh => .high,
        };
    }

    /// Ceiling for the WHOLE response, thinking included. Generous on purpose:
    /// it is a safety limit against a runaway, not a length target, and the old
    /// version made "low effort" mean "4096 tokens total", which cut a
    /// tool-using answer in half.
    pub fn outputCeiling(self: Effort) u32 {
        return switch (self) {
            .none => 16384,
            .minimal => 16384,
            .low => 32768,
            .medium => 32768,
            .high => 65536,
            .xhigh => 65536,
        };
    }

    /// `thinking.budget_tokens` for Anthropic. Must stay STRICTLY below
    /// `outputCeiling` or the API answers 400, which is why
    /// `thinkingBudgetFor` re-clamps instead of trusting the caller.
    pub fn thinkingBudget(self: Effort) u32 {
        return switch (self) {
            .none => 0,
            .minimal => 1024,
            .low => 4096,
            .medium => 8192,
            .high => 16384,
            .xhigh => 24576,
        };
    }
};

/// Provider wire format for chat: OpenAI-compat (chat/completions) or native
/// Anthropic (Messages API with cache_control for prompt caching).
pub const ProviderKind = enum { openai, anthropic };

/// Maps the provider id to its wire format.
pub fn kindForProvider(provider_id: []const u8) ProviderKind {
    if (std.mem.eql(u8, provider_id, "anthropic")) return .anthropic;
    return .openai;
}

/// Model families that change the shape of the request beyond the wire format:
/// knowing whether it is OpenAI or Anthropic is not enough.
pub const Family = enum {
    generic_openai,
    /// o-series / gpt-5: they want `max_completion_tokens`, reject
    /// `temperature`, and take `reasoning_effort`.
    openai_reasoning,
    /// Anthropic with extended thinking: `max_tokens` must be greater than the
    /// reasoning budget.
    anthropic_thinking,
    anthropic,

    pub fn parse(s: []const u8) ?Family {
        if (std.mem.eql(u8, s, "openai_reasoning")) return .openai_reasoning;
        if (std.mem.eql(u8, s, "anthropic_thinking")) return .anthropic_thinking;
        if (std.mem.eql(u8, s, "anthropic")) return .anthropic;
        if (std.mem.eql(u8, s, "openai") or std.mem.eql(u8, s, "generic")) return .generic_openai;
        return null;
    }
};

/// Detects the family from the model name. A heuristic, not a table: it covers
/// the usual OpenAI prefixes and OpenCode's gates.
pub fn familyForModel(model: []const u8) Family {
    if (startsWithAny(model, &.{
        "o1", "o3", "o4", "gpt-5", "gpt5", "o1-", "o3-", "o4-", "gpt-5-",
    })) return .openai_reasoning;
    return .generic_openai;
}

/// Which effort levels a model actually accepts.
///
/// This is the piece that was missing, and its absence is bug 3 in one line:
/// every model got the same three-and-a-bit levels, so "some models support more"
/// was true and unreachable.
///
/// **Esta tabla se verifico contra las docs, no contra lo que parece reasonable.**
/// La primera version la escribi de memoria y era FALSA en tres sitios, que es
/// exactamente el modo de fallo que un test de este repo no caza: los tests
/// comparan el JSON que genera zode contra el JSON que el propio codigo de zode
/// dice que deberia generar. Si los dos estan equivocados, el test pasa. Lo que
/// hace falta es mirar la documentacion del proveedor, y:
///
///   - `xhigh` NO existe en `gpt-5.1`. Solo en `gpt-5.1-codex-max` (verificado:
///     la matriz de niveles de OpenAI lista none/low/medium/high para 5.1, y
///     anade xhigh solo para codex-max). Habia puesto `xhigh` para todo 5.1,
///     o sea un 400 en cuanto alguien escribiera `/effort xhigh`.
///   - `minimal` NO existe en los GPT-5 anteriores a 5.1, ni en `gemini-2.5-*`.
///     Es de 5.1 en adelante y de certainos Gemini 3.
///   - Gemini llama al campo `thinking_level`, no `reasoning_effort`. Por el
///     camino OpenAI-compatible (`/v1beta/openai/`, y OpenRouter) se mapea, que
///     es por lo que se manda el nombre de OpenAI. Los VALORES son los de Gemini.
///
/// El resto del criterio es el de siempre: un nivel que el modelo no conoce es un
/// 400, y un 400 a mitad de un turno es invisible. Ante la duda, **degradar**.
pub const EffortSupport = enum {
    /// No `reasoning_effort` at all. Do not send the field: a model with no such
    /// knob answers 400, and a model that ignores it costs only the setting.
    none,
    /// `low | medium | high`. The floor that o1/o3/o4 and every GPT-5 before 5.1
    /// accept, and the only ladder Gemini 2.5 accepts.
    basic,
    /// `basic` plus `none`. GPT-5.1 and later.
    gpt51,
    /// `basic` plus `none` and `xhigh`. ONLY the codex-max models; verified
    /// against OpenAI's own matrix, which does not list xhigh for plain 5.1.
    codex_max,
    /// `minimal | low | medium | high`. The Gemini 3 flash family. NOT every
    /// Gemini: `gemini-2.5-*` is `basic`, and `gemini-3-pro-preview` takes only
    /// `low`/`high`, which is why it is not in here.
    gemini3_minimal,
    /// `low | high`. Documented for `gemini-3-pro-preview` (and
    /// `gemini-3.1-pro-preview`), which is the one family WITHOUT `medium`.
    ///
    /// Existe por el motivo que importa: es el unico caso donde el default "de
    /// en medio" NO puede ser `medium`. Sin esta fila, un modelo sin `medium`
    /// receberia `medium` por ser el escalon central de una escalera inventada.
    no_medium,
};

pub fn effortSupport(model: []const u8) EffortSupport {
    // The most specific first, and by SUBSTRING: the ids arrive with four shapes
    // (`gpt-5`, `openai/gpt-5`, `anthropic/claude-sonnet-4-5`, `google/gemini-3`).
    //
    // `codex-max` has to come before `gpt-5.1`, because `gpt-5.1-codex-max`
    // contains `gpt-5.1` and would otherwise be demoted to the 5.1 ladder.
    if (containsAny(model, &.{ "codex-max", "codex_max" })) return .codex_max;
    if (containsAny(model, &.{ "gpt-5.1", "gpt5.1" })) return .gpt51;
    if (containsAny(model, &.{ "gemini-3.5", "gemini-3.6", "gemini-3-flash", "gemini-3.7", "gemini-3.8" })) return .gemini3_minimal;
    // Los pro de Gemini 3 no admiten `medium` (docs: low y high). Es el unico
    // modelo conocido sin el escalon de en medio, asi que tiene su propia fila
    // en vez de caer en `basic` y recibir un `medium` que no existe.
    if (containsAny(model, &.{ "gemini-3-pro", "gemini-3.1-pro" })) return .no_medium;
    // Everything else with a knob: the basic ladder. Gemini 2.5 and the odd
    // `gemini-3-pro-preview` are here on purpose — `basic` is a subset of what
    // they take, and `medium` is the only level that could surprise us (it is
    // documented as unsupported on 3-pro-preview), so that one degrades high.
    if (containsAny(model, &.{ "gemini" })) return .basic;
    if (containsAny(model, &.{ "gpt-5", "gpt5", "o3", "o4", "o1" })) return .basic;
    return .none;
}

/// The level to actually put on the wire, given what the model accepts.
///
/// `degrade` is the whole point: asking for xhigh on a model with four levels
/// has to arrive as `high`, and asking for `none` on a model with no `none` has
/// to arrive as `low` (spending nothing is `minimal` at worst). Returning a
/// level the model does not know is an instant 400, and there is no way to
/// discover the vocabulary from the id, so the table above is the contract.
pub fn effortFor(model: []const u8, want: Effort) ?Effort {
    return switch (effortSupport(model)) {
        .none => null,
        // `minimal` NO esta en esta escalera: mandarlo a un GPT-5 de antes de
        // 5.1 es un 400. `none` tampoco, y "no pensar" cae a `low`, que es lo
        // mas barato que el modelo sabe hacer.
        .basic => switch (want) {
            .none, .minimal, .low => .low,
            .medium => .medium,
            .high, .xhigh => .high,
        },
        .gpt51 => switch (want) {
            .none => .none,
            .minimal => .minimal,
            .low => .low,
            .medium => .medium,
            .high, .xhigh => .high,
        },
        .codex_max => want,
        // Gemini no tiene `none`: el piso es `minimal`.
        .gemini3_minimal => switch (want) {
            .none, .minimal => .minimal,
            .low => .low,
            .medium => .medium,
            .high, .xhigh => .high,
        },
        // Sin `medium`: degradar hacia `low` (el nivel pedido es mas de lo que el
        // modelo sabe hacer, y `low` es el mas cercano por debajo).
        .no_medium => switch (want) {
            .none, .minimal, .low, .medium => .low,
            .high, .xhigh => .high,
        },
    };
}

/// The `reasoning_effort` STRING for a model that has the field.
///
/// The NAME is OpenAI's on purpose even for Gemini: Gemini llama al campo
/// `thinking_level`, pero por el camino OpenAI-compatible (que es por donde
/// habla zode, via OpenRouter o `/v1beta/openai/`) se mapea desde
/// `reasoning_effort`. Los VALORES, en cambio, son los de Gemini.
///
/// Y elLevels se escribe "x-high" en ningun sitio: la palabra es `xhigh`.
pub fn reasoningEffortString(model: []const u8, want: Effort) ?[]const u8 {
    const e = effortFor(model, want) orelse return null;
    return switch (e) {
        .none => "none",
        .minimal => "minimal",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
    };
}

/// The TOP effort a model accepts, for the `/effort` picker and the status bar.
///
/// Without this the picker offers levels the current model cannot take, and the
/// user finds out by getting a 400 — which is the worst way to learn that your
/// model has four rungs and you have five.
pub fn maxEffortFor(model: []const u8) Effort {
    return switch (effortSupport(model)) {
        .none, .basic, .gpt51, .gemini3_minimal, .no_medium => .high,
        .codex_max => .xhigh,
    };
}

/// Every level the picker should offer for a model, cheapest first.
///
/// It is `effortFor`'s image: offering a level here that `effortFor` would
/// silently degrade is offering a knob that does nothing, and offering one it
/// cannot represent at all is offering a 400.
pub fn effortLevels(model: []const u8) []const Effort {
    return switch (effortSupport(model)) {
        .none => &.{ .low, .medium, .high },
        .basic => &.{ .low, .medium, .high },
        .gpt51 => &.{ .none, .minimal, .low, .medium, .high },
        .codex_max => &.{ .none, .minimal, .low, .medium, .high, .xhigh },
        .gemini3_minimal => &.{ .minimal, .low, .medium, .high },
        .no_medium => &.{ .low, .high },
    };
}

/// Where a model's ladder SITS, so a default can be chosen without hardcoding a
/// level that the model might not have.
///
/// It is the index into `effortLevels`, and NOT a level: `basic` has three
/// rungs and `codex_max` six, and "the middle" of those is `low` and `high`
/// respectively. Any function that returns "the model's default" and then clamps
/// it is fine, but one that assumes `medium` exists is not — that assumption is
/// exactly what made the old fixed `.medium` wrong for Gemini 3 Pro.
fn ladderMid(model: []const u8) ?Effort {
    const lv = effortLevels(model);
    if (lv.len == 0) return null;
    return lv[lv.len / 2];
}

/// The effort a model gets when the user has NOT chosen one.
///
/// Deliberately the middle of whatever the model offers, not a constant:
/// `medium` is not on every ladder (Gemini 3 Pro takes only `low`/`high`), and
/// a default that a model does not have is a request that 400s on the very first
/// turn of a session where the user never touched `/effort`.
pub fn defaultEffort(model: []const u8) Effort {
    return ladderMid(model) orelse .medium;
}

/// The level that will ACTUALLY go on the wire, given a preference.
///
/// This is the function the request path should call, and the reason it exists
/// is that `effortFor` returns an OPTIONAL: `null` means "this model has no
/// knob at all", which is not an error, it just means the effort setting does
/// not apply. Collapsing that here means nobody has to remember it, which is the
/// whole point of doing it automatically.
pub fn effectiveEffort(model: []const u8, want: Effort) Effort {
    return effortFor(model, want) orelse defaultEffort(model);
}

/// Snap a preference to the TOP of a model's ladder.
///
/// Used when the model CHANGES: an `xhigh` chosen on `codex-max` has to become
/// `high` on `gemini-2.5`, not sit there degrading silently on every request
/// (the user would see `xhigh` in the status bar and `high` on the wire, and
/// have no way to tell that those are different things).
pub fn clampEffort(model: []const u8, want: Effort) Effort {
    const top = maxEffortFor(model);
    if (@intFromEnum(want) > @intFromEnum(top)) return top;
    return want;
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (std.mem.indexOf(u8, haystack, n) != null) return true;
    }
    return false;
}

fn startsWithAny(haystack: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, haystack, p)) return true;
    }
    return false;
}

/// Reference to a history message, for the wire format.
pub const ChatMessage = struct {
    role: []const u8, // "system" | "user" | "assistant" | "tool"
    content: []const u8,
    tool_calls_json: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
};

pub const Callbacks = struct {
    userdata: ?*anyopaque = null,
    /// Text fragment from the assistant.
    onDelta: *const fn (?*anyopaque, []const u8) void = defaultOnDelta,
    /// Complete tool call (id + name + arguments already assembled).
    onToolCall: ?*const fn (?*anyopaque, id: []const u8, name: []const u8, args_json: []const u8) void = null,
    /// finish_reason ("stop", "tool_calls", ...).
    onFinish: ?*const fn (?*anyopaque, reason: []const u8) void = null,

    fn defaultOnDelta(_: ?*anyopaque, _: []const u8) void {}
};

/// Pulls the text of `"message":"..."` out of a server error JSON and leaves it
/// in `last_error_buf`.
///
/// Hand-written instead of `std.json` because this body is read exactly when we
/// are about to return an error: parsing it here could only fail again. If the
/// JSON carries no `message` (or is not JSON), the caller falls back to
/// "HTTP nnn".
fn setServerMessage(body: []const u8) void {
    last_error_len = 0;
    const key = "\"message\"";
    const at = std.mem.indexOf(u8, body, key) orelse return;
    var i = at + key.len;
    while (i < body.len and (body[i] == ' ' or body[i] == ':')) i += 1;
    if (i >= body.len or body[i] != '"') return;
    i += 1;

    var n: usize = 0;
    while (i < body.len and body[i] != '"') : (i += 1) {
        // Only the backslash and the quote are unescaped: a nested \uXXXX is
        // not worth it, and this is error text, not content.
        if (body[i] == '\\' and i + 1 < body.len) i += 1;
        if (n + 1 >= last_error_buf.len) break;
        last_error_buf[n] = body[i];
        n += 1;
    }
    if (n == 0) return;
    last_error_len = n;
}

/// Last bytes of the body when the server rejects the request (for diagnostics).
pub var last_error_buf: [512]u8 = undefined;
pub var last_error_len: usize = 0;

// ── ZODE_DBG_ERR: volcar la respuesta del server ──────────────
//
// `ZODE_DBG_ERR=1` imprime a stderr el status y los primeros bytes de CADA
// respuesta (buena o mala). Existe por una razón concreta: el mensaje de error
// que se ve en la TUI sale de `"message":"..."` del body, y cuando el body no
// tiene ese campo (o viene troceado) lo que se muestra es "HTTP 403" y no hay
// por dónde tirar. Con esto se lee lo que contestó de verdad.
//
// Se lee UNA vez al arrancar (`dbgInitEnv`): el `Io` no expone el entorno, y
// leerlo por cada respuesta sería una lookup por request.
pub var dbg_err_flag: bool = false;

pub fn dbgInitEnv(env: ?*const std.process.Environ.Map) void {
    const v = if (env) |e| e.get("ZODE_DBG_ERR") else null;
    dbg_err_flag = if (v) |x| x.len > 0 and x[0] != '0' else false;
}

fn dbg_err() bool {
    return dbg_err_flag;
}

pub fn lastErrorBody() []const u8 {
    return last_error_buf[0..last_error_len];
}

/// Set to true by the UI (ESC) to abort the stream in flight. Atomic: the TUI
/// thread writes it and the request worker reads it.
pub var cancel_current = std.atomic.Value(bool).init(false);

/// Was a cancellation requested? Polled by the SSE loop.
pub fn cancelled() bool {
    return cancel_current.load(.seq_cst);
}

/// Clears the flag when a new request starts.
pub fn clearCancel() void {
    cancel_current.store(false, .seq_cst);
}

/// Token usage of the last completed stream (provider-agnostic):
/// OpenAI style (prompt_tokens_details.cached_tokens) and Anthropic style
/// (cache_read_input_tokens) both normalized here.
pub const Usage = struct {
    prompt: i64 = 0,
    cached: i64 = 0,
    completion: i64 = 0,
};
pub var last_usage: Usage = .{};

// ── layer 1: internal stream events ──────────────────────────
const Event = union(enum) {
    delta: []const u8,
    /// Tool call fragment (indexed, arrives incrementally).
    tool_frag: struct {
        index: usize,
        id: ?[]const u8,
        name: ?[]const u8,
        args: ?[]const u8,
    },
    finish: []const u8,
    err: []const u8,
    usage: Usage,
};

/// Internal dispatch: turns stream JSON into Events and calls `dispatch`.
fn dispatchEvents(gpa: std.mem.Allocator, payload: []const u8, userdata: ?*anyopaque, dispatch: *const fn (?*anyopaque, Event) void) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, payload, .{});
    if (parsed != .object) return error.BadPayload;

    if (parsed.object.get("error")) |e| {
        var msg: []const u8 = "server error";
        if (e == .object) {
            if (e.object.get("message")) |m| {
                if (m == .string) msg = m.string;
            }
        }
        const n = @min(msg.len, last_error_buf.len);
        @memcpy(last_error_buf[0..n], msg[0..n]);
        last_error_len = n;
        dispatch(userdata, .{ .err = msg });
        return error.ServerError;
    }

    // usage (arrives in the final chunk, sometimes without choices)
    if (parsed.object.get("usage")) |u| {
        if (u == .object) {
            var usage = Usage{};
            if (u.object.get("prompt_tokens")) |v| {
                if (v == .integer) usage.prompt = v.integer;
            }
            if (u.object.get("completion_tokens")) |v| {
                if (v == .integer) usage.completion = v.integer;
            }
            // OpenAI style
            if (u.object.get("prompt_tokens_details")) |d| {
                if (d == .object) {
                    if (d.object.get("cached_tokens")) |v| {
                        if (v == .integer) usage.cached = v.integer;
                    }
                }
            }
            // Anthropic style
            if (u.object.get("cache_read_input_tokens")) |v| {
                if (v == .integer and usage.cached == 0) usage.cached = v.integer;
            }
            if (usage.prompt > 0 or usage.completion > 0) {
                dispatch(userdata, .{ .usage = usage });
            }
        }
    }

    // ── Anthropic Messages API (typed events) ───────────────────
    if (parsed.object.get("type")) |tv| {
        if (tv == .string) {
            const ty = tv.string;

            if (std.mem.eql(u8, ty, "message_start")) {
                if (parsed.object.get("message")) |m| {
                    if (m == .object) {
                        if (m.object.get("usage")) |u| {
                            if (u == .object) {
                                var usage = Usage{};
                                if (u.object.get("input_tokens")) |v| {
                                    if (v == .integer) usage.prompt = v.integer;
                                }
                                if (u.object.get("cache_read_input_tokens")) |v| {
                                    if (v == .integer) usage.cached = v.integer;
                                }
                                if (usage.prompt > 0 or usage.cached > 0) {
                                    dispatch(userdata, .{ .usage = usage });
                                }
                            }
                        }
                    }
                }
                return;
            }

            if (std.mem.eql(u8, ty, "content_block_start")) {
                if (parsed.object.get("content_block")) |cb| {
                    if (cb == .object) {
                        const bt = cb.object.get("type") orelse return;
                        if (bt == .string and std.mem.eql(u8, bt.string, "tool_use")) {
                            var index: usize = 0;
                            if (parsed.object.get("index")) |ix| {
                                if (ix == .integer and ix.integer >= 0) index = @intCast(ix.integer);
                            }
                            var id: ?[]const u8 = null;
                            var name: ?[]const u8 = null;
                            if (cb.object.get("id")) |v| {
                                if (v == .string) id = v.string;
                            }
                            if (cb.object.get("name")) |v| {
                                if (v == .string) name = v.string;
                            }
                            dispatch(userdata, .{ .tool_frag = .{ .index = index, .id = id, .name = name, .args = null } });
                        }
                    }
                }
                return;
            }

            if (std.mem.eql(u8, ty, "content_block_delta")) {
                const d = parsed.object.get("delta") orelse return;
                if (d != .object) return;
                const dt = d.object.get("type") orelse return;
                if (dt != .string) return;
                var index: usize = 0;
                if (parsed.object.get("index")) |ix| {
                    if (ix == .integer and ix.integer >= 0) index = @intCast(ix.integer);
                }
                if (std.mem.eql(u8, dt.string, "text_delta")) {
                    if (d.object.get("text")) |v| {
                        if (v == .string and v.string.len > 0) dispatch(userdata, .{ .delta = v.string });
                    }
                    return;
                }
                if (std.mem.eql(u8, dt.string, "input_json_delta")) {
                    if (d.object.get("partial_json")) |v| {
                        if (v == .string and v.string.len > 0) {
                            dispatch(userdata, .{ .tool_frag = .{ .index = index, .id = null, .name = null, .args = v.string } });
                        }
                    }
                    return;
                }
                return; // thinking_delta, signature_delta, etc.
            }

            if (std.mem.eql(u8, ty, "message_delta")) {
                if (parsed.object.get("usage")) |u| {
                    if (u == .object) {
                        if (u.object.get("output_tokens")) |v| {
                            if (v == .integer) dispatch(userdata, .{ .usage = .{ .completion = v.integer } });
                        }
                    }
                }
                if (parsed.object.get("delta")) |d| {
                    if (d == .object) {
                        if (d.object.get("stop_reason")) |sr| {
                            if (sr == .string and sr.string.len > 0) {
                                const reason: []const u8 =
                                    if (std.mem.eql(u8, sr.string, "tool_use")) "tool_calls" else sr.string;
                                dispatch(userdata, .{ .finish = reason });
                            }
                        }
                    }
                }
                return;
            }

            // message_stop, ping, content_block_stop: nothing to do.
            return;
        }
    }

    const choices = parsed.object.get("choices") orelse return;
    if (choices != .array or choices.array.items.len == 0) return;
    const choice = choices.array.items[0];
    if (choice != .object) return;

    if (choice.object.get("finish_reason")) |fr| {
        if (fr == .string and fr.string.len > 0) {
            dispatch(userdata, .{ .finish = fr.string });
        }
    }

    const delta = choice.object.get("delta") orelse return;
    if (delta != .object) return;

    if (delta.object.get("tool_calls")) |tcs| {
        if (tcs == .array) {
            for (tcs.array.items) |tc| {
                if (tc != .object) continue;
                var index: usize = 0;
                var id: ?[]const u8 = null;
                var name: ?[]const u8 = null;
                var args: ?[]const u8 = null;
                if (tc.object.get("index")) |ix| {
                    if (ix == .integer and ix.integer >= 0) index = @intCast(ix.integer);
                }
                if (tc.object.get("id")) |v| {
                    if (v == .string and v.string.len > 0) id = v.string;
                }
                if (tc.object.get("function")) |f| {
                    if (f == .object) {
                        if (f.object.get("name")) |v| {
                            if (v == .string and v.string.len > 0) name = v.string;
                        }
                        if (f.object.get("arguments")) |v| {
                            if (v == .string) args = v.string;
                        }
                    }
                }
                dispatch(userdata, .{ .tool_frag = .{ .index = index, .id = id, .name = name, .args = args } });
            }
        }
    }

    const content = delta.object.get("content") orelse return;
    if (content != .string) return;
    if (content.string.len == 0) return;
    dispatch(userdata, .{ .delta = content.string });
}

// ── layer 2: StreamCtx (tool_call accumulation, de-dup) ───────
pub const StreamCtx = struct {
    gpa: std.mem.Allocator,
    user: Callbacks,
    kind: ProviderKind = .openai,
    parts: std.ArrayList(Part) = .empty,
    finish_count: usize = 0,
    /// Buffer for the SSE line in progress (gpa-owned).
    line_buf: std.ArrayList(u8) = .empty,
    /// A `data:` event has already been seen in full.
    saw_done: bool = false,
    /// The request was cut short with ESC: there is partial text, and it is kept.
    partial: bool = false,
    /// First bytes of the response body. On a 200 that is the SSE preamble
    /// (never read), but on a 4xx/5xx it is the server's error JSON, which is
    /// the only thing that explains the failure ("Insufficient account funds",
    /// "Model access is disabled"). Without this the user only saw "HTTP 403".
    raw: [512]u8 = undefined,
    raw_len: usize = 0,

    const Part = struct {
        index: usize,
        id: std.ArrayList(u8) = .empty,
        name: std.ArrayList(u8) = .empty,
        args: std.ArrayList(u8) = .empty,
        emitted: bool = false,
    };

    /// Stores the first bytes of the body (see the `raw` field).
    pub fn noteRaw(self: *StreamCtx, chunk: []const u8) void {
        if (self.raw_len >= self.raw.len) return;
        const n = @min(chunk.len, self.raw.len - self.raw_len);
        @memcpy(self.raw[self.raw_len..][0..n], chunk[0..n]);
        self.raw_len += n;
    }

    /// Frees the buffers AND destroys the struct: it is called `destroy` and not
    /// `deinit` on purpose, because it takes `self` down with it and a
    /// `defer ctx.destroy()` on a stack-allocated StreamCtx blows up with
    /// "Invalid free". Only used with the ones coming out of `gpa.create`.
    pub fn destroy(self: *StreamCtx) void {
        for (self.parts.items) |*p| {
            p.id.deinit(self.gpa);
            p.name.deinit(self.gpa);
            p.args.deinit(self.gpa);
        }
        self.parts.deinit(self.gpa);
        self.line_buf.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Consumes a chunk from the socket. Accumulates into `line_buf` and
    /// dispatches every `data:` event as soon as its line is complete: that is
    /// how the text reaches the UI token by token instead of at the end.
    pub fn feed(self: *StreamCtx, chunk: []const u8) !void {
        self.noteRaw(chunk);
        for (chunk) |c| {
            if (self.saw_done) return;
            if (c != '\n') {
                self.line_buf.append(self.gpa, c) catch continue;
                continue;
            }
            // CAREFUL: `clearRetainingCapacity` does `@memset(items, undefined)`,
            // so the line must be consumed BEFORE clearing the buffer.
            try self.handleLine(self.line_buf.items);
            self.line_buf.clearRetainingCapacity();
        }
    }

    /// End of the stream: the last line may come without a '\n'.
    pub fn finish(self: *StreamCtx) !void {
        if (self.line_buf.items.len > 0) {
            try self.handleLine(self.line_buf.items);
            self.line_buf.clearRetainingCapacity();
        }
    }

    fn handleLine(self: *StreamCtx, raw: []const u8) !void {
        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (line.len == 0) return;
        if (!std.mem.startsWith(u8, line, "data:")) return; // event:, id:, :
        const payload = std.mem.trim(u8, line[5..], " ");
        if (payload.len == 0) return;
        if (std.mem.eql(u8, payload, "[DONE]")) {
            self.saw_done = true;
            return;
        }
        dispatchEvents(self.gpa, payload, self, StreamCtx.dispatch) catch |err| switch (err) {
            error.ServerError => return error.ServerError,
            else => {}, // malformed chunk: skip it and keep going
        };
    }

    fn partFor(self: *StreamCtx, index: usize) !*Part {
        for (self.parts.items) |*p| {
            if (p.index == index) return p;
        }
        try self.parts.append(self.gpa, .{ .index = index });
        return &self.parts.items[self.parts.items.len - 1];
    }

    /// Returned slices stay valid until the next streamChatCtx.
    pub fn toolCallsJson(self: *StreamCtx, arena: std.mem.Allocator) ![]const u8 {
        if (self.parts.items.len == 0) return "";
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(arena, "[");
        for (self.parts.items, 0..) |*p, i| {
            if (i > 0) try out.appendSlice(arena, ",");
            try out.appendSlice(arena, "{\"id\":\"");
            try out.appendSlice(arena, p.id.items);
            try out.appendSlice(arena, "\",\"type\":\"function\",\"function\":{\"name\":\"");
            try out.appendSlice(arena, p.name.items);
            try out.appendSlice(arena, "\",\"arguments\":\"");
            // `arguments` is already valid JSON → escape it as a string to nest it.
            for (p.args.items) |c| {
                switch (c) {
                    '"' => try out.appendSlice(arena, "\\\""),
                    '\\' => try out.appendSlice(arena, "\\\\"),
                    '\n' => try out.appendSlice(arena, "\\n"),
                    '\r' => try out.appendSlice(arena, "\\r"),
                    '\t' => try out.appendSlice(arena, "\\t"),
                    else => try out.append(arena, c),
                }
            }
            try out.appendSlice(arena, "\"}}");
        }
        try out.appendSlice(arena, "]");
        return out.items;
    }

    fn dispatch(ud: ?*anyopaque, ev: Event) void {
        const self: *StreamCtx = @ptrCast(@alignCast(ud.?));
        switch (ev) {
            .usage => |u| {
                // Per-field merge: Anthropic splits usage between
                // message_start (input) and message_delta (output).
                if (u.prompt > 0) last_usage.prompt = u.prompt;
                if (u.cached > 0) last_usage.cached = u.cached;
                if (u.completion > 0) last_usage.completion = u.completion;
            },
            .delta => |d| self.user.onDelta(self.user.userdata, d),
            .finish => |r| {
                self.finish_count += 1;
                // Only the first finish matters; servers sometimes
                // send finish on every trailing chunk.
                if (self.finish_count == 1) {
                    if (self.user.onFinish) |f| f(self.user.userdata, r);
                }
            },
            .tool_frag => |frag| {
                const p = self.partFor(frag.index) catch return;
                if (frag.id) |v| {
                    if (p.id.items.len == 0) p.id.appendSlice(self.gpa, v) catch {};
                }
                if (frag.name) |v| {
                    if (p.name.items.len == 0) p.name.appendSlice(self.gpa, v) catch {};
                }
                if (frag.args) |v| {
                    p.args.appendSlice(self.gpa, v) catch {};
                }
                self.tryEmitTool(p);
            },
            .err => |msg| {
                // An error embedded in a 200 chunk (some gateways do that).
                if (self.user.onFinish) |f| f(self.user.userdata, msg);
            },
        }
    }

    /// Emits the tool call as soon as its arguments are valid JSON.
    ///
    /// The historical trigger was "the last byte is `}`", which hung the agent
    /// loop if the stream was cut before the closing byte or the model returned
    /// empty arguments. Now it is additionally forced in `finish`.
    fn tryEmitTool(self: *StreamCtx, p: *Part) void {
        if (p.emitted) return;
        if (p.id.items.len == 0 or p.name.items.len == 0) return;
        if (p.args.items.len == 0) return;

        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), p.args.items, .{});
        if (parsed) |_| {
            p.emitted = true;
            if (self.user.onToolCall) |f| {
                f(self.user.userdata, p.id.items, p.name.items, p.args.items);
            }
        } else |_| {}
    }

    /// Recovers tool calls that never made it to being emitted (cut stream).
    /// The ones that do have executable args are emitted now; the rest are dropped.
    fn flushPendingTools(self: *StreamCtx) void {
        for (self.parts.items) |*p| {
            if (p.emitted) continue;
            if (p.id.items.len == 0 or p.name.items.len == 0) continue;
            if (p.args.items.len == 0) {
                // A tool without arguments is legal: treat it as an empty object.
                p.args.appendSlice(self.gpa, "{}") catch continue;
            }
            self.tryEmitTool(p);
        }
    }
};

pub const StreamResult = struct {
    ctx: *StreamCtx,
    /// True if the request was cut short with ESC (there is partial text).
    partial: bool = false,
};

/// Stream with tool_call accumulation. The caller does `result.ctx.destroy()`.
pub fn streamChatCtx(
    gpa: std.mem.Allocator,
    http: *http_client.Http,
    url: []const u8,
    bearer: ?[]const u8,
    body: []u8,
    user_cb: Callbacks,
    kind: ProviderKind,
) !StreamResult {
    const ctx = try gpa.create(StreamCtx);
    ctx.* = .{ .gpa = gpa, .user = user_cb, .kind = kind };
    // CAREFUL: the error path must call `destroy` (NOT `deinit`): the ctx may
    // already have `parts` (accumulated tool calls) and `line_buf` allocated.
    // `destroy` is the one that frees them; a plain `gpa.destroy(ctx)` without
    // it leaked both on every 429/5xx.
    errdefer ctx.destroy();
    try streamRaw(gpa, http, url, bearer, body, ctx);
    return .{ .ctx = ctx, .partial = ctx.partial };
}

fn streamRaw(
    gpa: std.mem.Allocator,
    http: *http_client.Http,
    url: []const u8,
    bearer: ?[]const u8,
    body: []u8,
    ctx: *StreamCtx,
) !void {
    _ = gpa; // the parser lives in the ctx (line_buf)
    last_usage = .{}; // fresh per request: do not carry over fields from the previous turn
    clearCancel();

    const Hdr = http_client.Http.ExtraHeader;
    var hdrs_buf: [2]Hdr = undefined;
    var n: usize = 0;
    // Anthropic does not use Bearer: x-api-key + API version.
    var auth: ?[]const u8 = bearer;
    if (ctx.kind == .anthropic) {
        if (bearer) |k| {
            hdrs_buf[n] = .{ .name = "x-api-key", .value = k };
            n += 1;
        }
        hdrs_buf[n] = .{ .name = "anthropic-version", .value = "2023-06-01" };
        n += 1;
        auth = null;
    }

    const Feed = struct {
        fn onChunk(ud: ?*anyopaque, chunk: []const u8) anyerror!void {
            if (cancelled()) return error.Cancelled; // ESC cuts the connection
            const c = @as(*StreamCtx, @ptrCast(@alignCast(ud.?)));
            c.feed(chunk) catch |err| switch (err) {
                error.ServerError => return error.ServerError,
            };
        }
    };

    const res = http.streamPost(url, auth, body, hdrs_buf[0..n], Feed.onChunk, ctx) catch |err| {
        if (err == error.Cancelled) {
            ctx.partial = true; // the text received up to the ESC is kept
            return;
        }
        return err;
    };

    if (res.status != 200) {
        if (dbg_err()) {
            std.debug.print("[DBG] status={d} raw={s}\n", .{ res.status, ctx.raw[0..@min(ctx.raw_len, 240)] });
        }
        if (res.retry_after) |ra| retry_after_secs = ra;
        // Each status gets its own error because the ACTION to take differs,
        // and "HTTP 403" says nothing:
        //   400  bad request    -> do not retry (repeating it does not fix it)
        //   401  invalid key    -> do not retry, check the key
        //   402  no credits     -> do not retry (it used to retry 3 times!)
        //   403  access denied  -> almost always the MODEL, not the key
        //   429/503 transient   -> retry
        const err: anyerror = switch (res.status) {
            429 => error.RateLimited,
            503 => error.Overloaded,
            401 => error.AuthFailed,
            402 => error.NoCredits,
            403 => error.Forbidden,
            // 404 almost always means "this model does not exist (or your
            // account does not have it)". Retrying 3 times is waiting for
            // nothing.
            404 => error.ModelNotFound,
            // 400: the REQUEST is wrong. Retrying the same thing 3 times is
            // 3.5 s of clock and a turn that looks hung. With free-auto on,
            // `noteTurnFailure` drops that pair so the next turn starts
            // somewhere else.
            400 => error.BadRequest,
            else => error.ServerError,
        };
        // The server's message is what actually explains the failure; it is
        // pulled out of its JSON ("message":"...") and if there is none the
        // status is left as-is.
        last_error_len = 0;
        setServerMessage(ctx.raw[0..ctx.raw_len]);
        if (last_error_len == 0) {
            const fb = std.fmt.bufPrint(&last_error_buf, "HTTP {d}", .{res.status}) catch return err;
            last_error_len = fb.len;
        }
        return err;
    }
    if (dbg_err()) std.debug.print("[DBG] 200 raw={s}\n", .{ctx.raw[0..@min(ctx.raw_len, 240)]});
    retry_after_secs = null;
    if (res.retry_after) |ra| retry_after_secs = ra;
    ctx.finish() catch |err| switch (err) {
        error.ServerError => return error.ServerError,
    };
    // A tool call that arrives half-formed at the end of the stream was never
    // emitted and hung the agent loop: force the emission of the valid ones.
    ctx.flushPendingTools();
}

/// Last `retry-after` seen on an error response (seconds).
pub var retry_after_secs: ?u16 = null;

/// Sleeps `ms` milliseconds. Returns early if ESC is pressed.
///
/// ## Why `nanosleep` and not `Io.sleep`
///
/// This runs in the WORKER, and `Io.sleep` takes the event loop of the `Io`
/// that the TUI shares in the same event thread away with it: during the backoff
/// the redraws stop, the clock in the activity strip freezes and the notices stay
/// in `pending` unpainted. It is the same problem ACP solved with `nap()` and
/// the same solution: a real syscall, without touching the `Io`.
///
/// Sleeps in 50 ms slices so ESC can cut the wait short.
pub fn sleepMs(ms_arg: u64) void {
    if (ms_arg == 0) return;
    // Ceiling: never sleep half a minute in one go.
    var left: u64 = @min(ms_arg, 30_000);
    while (left > 0) {
        if (cancel_current.load(.seq_cst)) return;
        const chunk = @min(left, 50);
        acp.nap(chunk);
        left -= chunk;
    }
}

/// xorshift for the backoff jitter (no thread-safe global state needed: only
/// the worker that is already serializing its requests uses it).
var rng_state: u64 = 0x9E3779B97F4A7C15;

/// Processes a whole SSE body in one go (tests and socketless paths).
/// Uses the same incremental parser as the real stream, feeding it whole.
pub fn scanSse(gpa: std.mem.Allocator, sse_body: []const u8, ctx: *StreamCtx) !void {
    _ = gpa;
    ctx.line_buf.clearRetainingCapacity();
    // A malformed SSE does not bring the parse down; only a server error
    // (a payload with `{"error":...}`) is fatal.
    ctx.feed(sse_body) catch |err| switch (err) {
        error.ServerError => return error.ServerError,
    };
    ctx.finish() catch |err| switch (err) {
        error.ServerError => return error.ServerError,
    };
    ctx.flushPendingTools();
}

/// Simple stream without tool_calls (CLI, tests). The caller frees `ctx`.
pub fn streamChat(
    gpa: std.mem.Allocator,
    http: *http_client.Http,
    url: []const u8,
    bearer: ?[]const u8,
    body: []u8,
    cb: Callbacks,
    kind: ProviderKind,
) !void {
    const ctx = try gpa.create(StreamCtx);
    ctx.* = .{ .gpa = gpa, .user = cb, .kind = kind };
    defer ctx.destroy(); // frees parts and destroys the struct
    try streamRaw(gpa, http, url, bearer, body, ctx);
}

// ── body builders ────────────────────────────────────────────

/// Body with the full history (multi-turn + tools), depending on the provider.
pub fn buildBodyMessages(
    buf: []u8,
    model: []const u8,
    messages: []const ChatMessage,
    effort: Effort,
    tools_json: []const u8,
    kind: ProviderKind,
) ![]u8 {
    return switch (kind) {
        .openai => buildBodyOpenAI(buf, model, messages, effort, tools_json),
        .anthropic => buildBodyAnthropic(buf, model, messages, effort, tools_json),
    };
}

/// OpenAI format (chat/completions). No alloc deps.
fn buildBodyOpenAI(
    buf: []u8,
    model: []const u8,
    messages: []const ChatMessage,
    effort: Effort,
    tools_json: []const u8,
) ![]u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.writeAll("{\"model\":\"");
    try jsonEscape(&w, model);
    try w.writeAll("\",\"messages\":[");
    for (messages, 0..) |m, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"role\":\"");
        try w.writeAll(m.role);
        try w.writeAll("\",");
        if (std.mem.eql(u8, m.role, "tool")) {
            try w.writeAll("\"tool_call_id\":\"");
            try jsonEscape(&w, m.tool_call_id orelse "");
            try w.writeAll("\",\"content\":\"");
        } else {
            try w.writeAll("\"content\":\"");
        }
        try jsonEscape(&w, m.content);
        try w.writeAll("\"");
        if (m.tool_calls_json) |tj| {
            if (tj.len > 0) {
                try w.writeAll(",\"tool_calls\":");
                try w.writeAll(tj);
            }
        }
        try w.writeAll("}");
    }
    try w.writeAll("],\"stream\":true,\"stream_options\":{\"include_usage\":true}");

    // `reasoning_effort` goes out whenever the MODEL takes it, not only for the
    // o-series: Gemini, DeepSeek's thinking models and OpenRouter's front door
    // all read the same field name, and every one of them has levels our enum
    // did not used to have. `familyForModel` decides the `max_tokens` FIELD NAME
    // (below), which is a different question from "does this model think".
    if (reasoningEffortString(model, effort)) |tok| {
        try w.writeAll(",\"reasoning_effort\":\"");
        try w.writeAll(tok);
        try w.writeAll("\"");
    }

    // OpenAI's o-series / gpt-5 reject `max_tokens` (they want
    // `max_completion_tokens`) and do not accept `temperature`. Sending the
    // wrong field is an instant 400, so branch by family.
    const fam = familyForModel(model);
    switch (fam) {
        .openai_reasoning => {
            try w.writeAll(",\"max_completion_tokens\":");
            try w.print("{d}", .{effort.outputCeiling()});
        },
        else => {
            try w.writeAll(",\"max_tokens\":");
            try w.print("{d}", .{effort.outputCeiling()});
        },
    }

    // tools FIRST after messages? No: tools goes outside messages (root level),
    // and its stable position in the JSON helps the provider's prefix caching.
    if (tools_json.len > 0) {
        try w.writeAll(",\"tools\":");
        try w.writeAll(tools_json);
    }
    try w.writeAll("}");
    return w.buffered();
}

/// Compat: single message (headless CLI).
pub fn buildBody(buf: []u8, model: []const u8, user_text: []const u8, effort: Effort) ![]u8 {
    const msgs = [_]ChatMessage{.{ .role = "user", .content = user_text }};
    return buildBodyMessages(buf, model, &msgs, effort, "", .openai);
}

/// Anthropic Messages API format:
///  - system and tools go at root level, with `cache_control` breakpoints
///    (Claude Code style prompt caching: the stable prefix —tools+system+
///    history— is served from the server's cache between turns).
///  - assistant.tool_calls (OpenAI format) → `tool_use` blocks.
///  - runs of role=tool messages → ONE user message with `tool_result` blocks.
fn buildBodyAnthropic(
    buf: []u8,
    model: []const u8,
    messages: []const ChatMessage,
    effort: Effort,
    tools_json: []const u8,
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var w: std.Io.Writer = .fixed(buf);
    try w.writeAll("{\"model\":\"");
    try jsonEscape(&w, model);
    // Anthropic REQUIRES max_tokens (it has no default). On top of that, with
    // extended thinking the reasoning budget is separate and has to be SMALLER
    // than max_tokens, otherwise the server answers 400.
    //
    // `thinkingBudget` can return a value that is NOT below the ceiling (a huge
    // budget on a small ceiling), so the clamp lives HERE and not in the caller:
    // this is the one place that knows the two numbers go out in the same
    // request, and a 400 here is invisible until a turn dies mid-stream.
    const ceiling = effort.outputCeiling();
    const want_budget = effort.thinkingBudget();
    const think_budget: u32 = if (want_budget == 0) 0 else @min(want_budget, ceiling -| 1);
    try w.print("\",\"max_tokens\":{d},\"stream\":true", .{ceiling});
    if (think_budget > 0) {
        try w.print(",\"thinking\":{{\"type\":\"enabled\",\"budget_tokens\":{d}}}", .{think_budget});
    }

    // tools: {type,function:{name,description,parameters}} → {name,description,input_schema}
    if (tools_json.len > 0) {
        const pt = std.json.parseFromSliceLeaky(std.json.Value, arena, tools_json, .{}) catch null;
        if (pt) |pv| {
            if (pv == .array and pv.array.items.len > 0) {
                try w.writeAll(",\"tools\":[");
                var emitted: usize = 0;
                for (pv.array.items, 0..) |t, ti| {
                    if (t != .object) continue;
                    // OpenAI format: {type:function, function:{name,...}}.
                    // Also accepts the flat shape {name, description, parameters}.
                    var name_v: ?std.json.Value = t.object.get("name");
                    var desc_v: ?std.json.Value = t.object.get("description");
                    var params_v: ?std.json.Value = t.object.get("parameters");
                    if (t.object.get("function")) |f| {
                        if (f == .object) {
                            if (name_v == null) name_v = f.object.get("name");
                            if (desc_v == null) desc_v = f.object.get("description");
                            if (params_v == null) params_v = f.object.get("parameters");
                        }
                    }
                    const name = name_v orelse continue;
                    if (name != .string) continue;
                    if (emitted > 0) try w.writeAll(",");
                    emitted += 1;
                    try w.writeAll("{\"name\":\"");
                    try jsonEscape(&w, name.string);
                    try w.writeAll("\",\"description\":\"");
                    if (desc_v) |d| {
                        if (d == .string) try jsonEscape(&w, d.string);
                    }
                    try w.writeAll("\",\"input_schema\":");
                    if (params_v) |p| {
                        try writeJsonValue(&w, p);
                    } else {
                        try w.writeAll("{\"type\":\"object\"}");
                    }
                    // Breakpoint on the LAST tool: tools+system are stable, so
                    // that whole prefix stays cached between turns.
                    if (ti == pv.array.items.len - 1) {
                        try w.writeAll(",\"cache_control\":{\"type\":\"ephemeral\"}");
                    }
                    try w.writeAll("}");
                }
                try w.writeAll("]");
            }
        }
    }

    var start: usize = 0;
    if (messages.len > 0 and std.mem.eql(u8, messages[0].role, "system")) {
        try w.writeAll(",\"system\":[{\"type\":\"text\",\"text\":\"");
        try jsonEscape(&w, messages[0].content);
        try w.writeAll("\",\"cache_control\":{\"type\":\"ephemeral\"}}]");
        start = 1;
    }

    try w.writeAll(",\"messages\":[");
    var first = true;
    var i = start;
    while (i < messages.len) {
        const m = messages[i];
        const has_tc = m.tool_calls_json != null and m.tool_calls_json.?.len > 0;
        if (m.content.len == 0 and !has_tc and !std.mem.eql(u8, m.role, "tool")) {
            i += 1;
            continue; // Anthropic rejects empty content
        }

        if (std.mem.eql(u8, m.role, "tool")) {
            // Run of consecutive results → ONE user message with tool_result.
            if (!first) try w.writeAll(",");
            first = false;
            try w.writeAll("{\"role\":\"user\",\"content\":[");
            var fb = true;
            while (i < messages.len and std.mem.eql(u8, messages[i].role, "tool")) : (i += 1) {
                if (!fb) try w.writeAll(",");
                fb = false;
                try w.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":\"");
                try jsonEscape(&w, messages[i].tool_call_id orelse "");
                try w.writeAll("\",\"content\":\"");
                try jsonEscape(&w, messages[i].content);
                try w.writeAll("\"");
                // Breakpoint at the end of the history: the next turn reuses
                // the WHOLE prefix from cache (tools+system+messages).
                if (i == messages.len - 1) try w.writeAll(",\"cache_control\":{\"type\":\"ephemeral\"}");
                try w.writeAll("}");
            }
            try w.writeAll("]}");
            continue;
        }

        if (!first) try w.writeAll(",");
        first = false;
        try w.writeAll("{\"role\":\"");
        try w.writeAll(m.role); // "user" | "assistant" (system only at index 0)
        try w.writeAll("\",\"content\":");

        if (has_tc) {
            try w.writeAll("[");
            var wrote_text = false;
            if (m.content.len > 0) {
                try w.writeAll("{\"type\":\"text\",\"text\":\"");
                try jsonEscape(&w, m.content);
                try w.writeAll("\"}");
                wrote_text = true;
            }
            const pcs = std.json.parseFromSliceLeaky(std.json.Value, arena, m.tool_calls_json.?, .{}) catch null;
            if (pcs) |pv| {
                if (pv == .array) {
                    for (pv.array.items, 0..) |tc, ti| {
                        if (tc != .object) continue;
                        const fnv = tc.object.get("function") orelse continue;
                        if (fnv != .object) continue;
                        const idv = tc.object.get("id");
                        const namev = fnv.object.get("name");
                        if (idv == null or idv.? != .string) continue;
                        if (namev == null or namev.? != .string) continue;
                        if (wrote_text) try w.writeAll(",");
                        wrote_text = true;
                        try w.writeAll("{\"type\":\"tool_use\",\"id\":\"");
                        try jsonEscape(&w, idv.?.string);
                        try w.writeAll("\",\"name\":\"");
                        try jsonEscape(&w, namev.?.string);
                        try w.writeAll("\",\"input\":");
                        var input_written = false;
                        if (fnv.object.get("arguments")) |av| {
                            if (av == .string) {
                                const obj = std.json.parseFromSliceLeaky(std.json.Value, arena, av.string, .{}) catch null;
                                if (obj) |ov| {
                                    if (ov == .object) {
                                        try writeJsonValue(&w, ov);
                                        input_written = true;
                                    }
                                }
                            }
                        }
                        if (!input_written) try w.writeAll("{}");
                        if (ti == pv.array.items.len - 1 and i == messages.len - 1) {
                            try w.writeAll(",\"cache_control\":{\"type\":\"ephemeral\"}");
                        }
                        try w.writeAll("}");
                    }
                }
            }
            if (!wrote_text) {
                try w.writeAll("{\"type\":\"text\",\"text\":\"\"}");
            }
            try w.writeAll("]");
        } else if (i == messages.len - 1) {
            // Last message: block form, to anchor the cache breakpoint.
            try w.writeAll("[{\"type\":\"text\",\"text\":\"");
            try jsonEscape(&w, m.content);
            try w.writeAll("\",\"cache_control\":{\"type\":\"ephemeral\"}}]");
        } else {
            try w.writeAll("\"");
            try jsonEscape(&w, m.content);
            try w.writeAll("\"");
        }
        try w.writeAll("}");
        i += 1;
    }
    try w.writeAll("]}");
    return w.buffered();
}

/// Serializes std.json.Value to compact JSON (own subset, without depending on
/// std's stringify API).
fn writeJsonValue(w: *std.Io.Writer, v: std.json.Value) !void {
    switch (v) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |n| try w.print("{d}", .{n}),
        .float => |f| try w.print("{d}", .{f}),
        .number_string, .string => |s| {
            try w.writeByte('"');
            try jsonEscape(w, s);
            try w.writeByte('"');
        },
        .array => |a| {
            try w.writeAll("[");
            for (a.items, 0..) |item, ai| {
                if (ai > 0) try w.writeAll(",");
                try writeJsonValue(w, item);
            }
            try w.writeAll("]");
        },
        .object => |o| {
            try w.writeAll("{");
            var it = o.iterator();
            var first = true;
            while (it.next()) |e| {
                if (!first) try w.writeAll(",");
                first = false;
                try w.writeByte('"');
                try jsonEscape(w, e.key_ptr.*);
                try w.writeAll("\":");
                try writeJsonValue(w, e.value_ptr.*);
            }
            try w.writeAll("}");
        },
    }
}

fn jsonEscape(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
}

// ── hermetic tests ───────────────────────────────────────────
test "scanSse junta deltas y termina en [DONE]" {
    const sse =
        "data: {\"choices\":[{\"delta\":{\"content\":\"Hola \"}}]}\n" ++
        "\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"mundo\"}}]}\n" ++
        "\n" ++
        "data: [DONE]\n" ++
        "\n";

    const Collector = struct {
        text: std.ArrayList(u8) = .empty,
        fn onDelta(ud: ?*anyopaque, delta: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            self.text.appendSlice(std.testing.allocator, delta) catch {};
        }
    };
    var col = Collector{};
    defer col.text.deinit(std.testing.allocator);

    const ctx = try std.testing.allocator.create(StreamCtx);
    ctx.* = .{
        .gpa = std.testing.allocator,
        .user = .{ .userdata = &col, .onDelta = Collector.onDelta },
    };
    defer ctx.destroy();

    try scanSse(std.testing.allocator, sse, ctx);
    try std.testing.expectEqualStrings("Hola mundo", col.text.items);
}

test "tool_call fragmentado se acumula y emite una vez" {
    const Collector = struct {
        calls: usize = 0,
        last_name: []const u8 = "",
        last_args: []const u8 = "",
        fn onToolCall(ud: ?*anyopaque, id: []const u8, name: []const u8, args: []const u8) void {
            _ = id;
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            self.calls += 1;
            self.last_name = name;
            self.last_args = args;
        }
        fn onDelta(_: ?*anyopaque, _: []const u8) void {}
    };
    var col = Collector{};

    const ctx = try std.testing.allocator.create(StreamCtx);
    ctx.* = .{
        .gpa = std.testing.allocator,
        .user = .{ .userdata = &col, .onDelta = Collector.onDelta, .onToolCall = Collector.onToolCall },
    };
    defer ctx.destroy();

    // Fragments: id+name first, args in 3 pieces (with a brace inside a
    // string, to check that the parse is not confused).
    const sse =
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"grep\",\"arguments\":\"\"}}]}}]}\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"pattern\\\":\\\"a{b\\\"\"}}]}}]}\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\",\\\"x\\\":\\\"}\\\"\"}}]}}]}\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"}\"}}]}}]}\n" ++
        "data: [DONE]\n\n";

    // complete args: {"pattern":"a{b","x":"}"}
    try scanSse(std.testing.allocator, sse, ctx);

    try std.testing.expectEqual(@as(usize, 1), col.calls);
    try std.testing.expectEqualStrings("grep", col.last_name);
    try std.testing.expectEqualStrings("{\"pattern\":\"a{b\",\"x\":\"}\"}", col.last_args);
}

test "detecta error del server" {
    const ctx = try std.testing.allocator.create(StreamCtx);
    ctx.* = .{ .gpa = std.testing.allocator, .user = .{} };
    defer ctx.destroy();
    try std.testing.expectError(
        error.ServerError,
        scanSse(std.testing.allocator, "data: {\"error\":{\"type\":\"x\",\"message\":\"no\"}}\n\n", ctx),
    );
    try std.testing.expectEqualStrings("no", lastErrorBody());
}

test "buildBody escapa JSON y fija max_tokens" {
    var buf: [512]u8 = undefined;
    const body = try buildBody(&buf, "m1", "linea\ncon \"quotes\"", .medium);
    try std.testing.expectEqualStrings(
        "{\"model\":\"m1\",\"messages\":[{\"role\":\"user\",\"content\":\"linea\\ncon \\\"quotes\\\"\"}],\"stream\":true,\"stream_options\":{\"include_usage\":true},\"max_tokens\":32768}",
        body,
    );
}

test "buildBodyMessages con tool result y tools" {
    var buf: [1024]u8 = undefined;
    const msgs = [_]ChatMessage{
        .{ .role = "user", .content = "lee a.zig" },
        .{ .role = "assistant", .content = "", .tool_calls_json = "[{\"id\":\"c1\",\"type\":\"function\",\"function\":{\"name\":\"read\",\"arguments\":\"{}\"}}]" },
        .{ .role = "tool", .content = "ok", .tool_call_id = "c1" },
    };
    const body = try buildBodyMessages(&buf, "m", &msgs, .low, "[{\"type\":\"function\",\"function\":{\"name\":\"read\"}}]", .openai);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_call_id\":\"c1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":32768") != null);
}

test "scanSse parsea eventos Anthropic (delta, tool_use y usage)" {
    const Collector = struct {
        text: std.ArrayList(u8) = .empty,
        calls: usize = 0,
        last_name: []const u8 = "",
        last_args: []const u8 = "",
        fn onDelta(ud: ?*anyopaque, delta: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            self.text.appendSlice(std.testing.allocator, delta) catch {};
        }
        fn onToolCall(ud: ?*anyopaque, id: []const u8, name: []const u8, args: []const u8) void {
            _ = id;
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            self.calls += 1;
            self.last_name = name;
            self.last_args = args;
        }
    };
    var col = Collector{};
    defer col.text.deinit(std.testing.allocator);

    last_usage = .{};

    const ctx = try std.testing.allocator.create(StreamCtx);
    ctx.* = .{
        .gpa = std.testing.allocator,
        .user = .{ .userdata = &col, .onDelta = Collector.onDelta, .onToolCall = Collector.onToolCall },
    };
    defer ctx.destroy();

    const sse =
        "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":120,\"cache_read_input_tokens\":100}}}\n\n" ++
        "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"grep\"}}\n\n" ++
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"pattern\\\":\"}}\n\n" ++
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\"x\\\"}\"}}\n\n" ++
        "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":42}}\n\n" ++
        "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n";

    try scanSse(std.testing.allocator, sse, ctx);

    try std.testing.expectEqual(@as(usize, 1), col.calls);
    try std.testing.expectEqualStrings("grep", col.last_name);
    try std.testing.expectEqualStrings("{\"pattern\":\"x\"}", col.last_args);
    try std.testing.expectEqual(@as(i64, 120), last_usage.prompt);
    try std.testing.expectEqual(@as(i64, 100), last_usage.cached);
    try std.testing.expectEqual(@as(i64, 42), last_usage.completion);
}

test "buildBodyAnthropic convierte tool_calls/results y ancla cache_control" {
    var buf: [2048]u8 = undefined;
    const msgs = [_]ChatMessage{
        .{ .role = "system", .content = "be terse" },
        .{ .role = "user", .content = "busca foo" },
        .{ .role = "assistant", .content = "", .tool_calls_json = "[{\"id\":\"c1\",\"type\":\"function\",\"function\":{\"name\":\"grep\",\"arguments\":\"{\\\"pattern\\\":\\\"foo\\\"}\"}}]" },
        .{ .role = "tool", .content = "src/a.zig:1:foo", .tool_call_id = "c1" },
    };
    const tools = "[{\"type\":\"function\",\"function\":{\"name\":\"read\",\"description\":\"d\",\"parameters\":{\"type\":\"object\"}}}]";
    const body = try buildBodyMessages(&buf, "claude-test", &msgs, .low, tools, .anthropic);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"input_schema\":{\"type\":\"object\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"tool_use\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_use_id\":\"c1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"input\":{\"pattern\":\"foo\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"system\":[{\"type\":\"text\",\"text\":\"be terse\"") != null);
    // El techo es el de `.low` (32768), no su presupuesto de pensamiento (4096):
    // son dos numeros distintos y confundirlos era media parte del bug 3.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":32768") != null);
    // The role "tool" does not exist in Anthropic: they go as tool_result in user.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"tool\"") == null);
    // 3 breakpoints: system, last tool and last message.
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, body, "\"cache_control\":{\"type\":\"ephemeral\"}"));
}

test "feed: un evento partido a mitad de línea se entrega entero" {
    const Collector = struct {
        text: std.ArrayList(u8) = .empty,
        fn onDelta(ud: ?*anyopaque, delta: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            self.text.appendSlice(std.testing.allocator, delta) catch {};
        }
    };
    var col = Collector{};
    defer col.text.deinit(std.testing.allocator);

    const ctx = try std.testing.allocator.create(StreamCtx);
    ctx.* = .{
        .gpa = std.testing.allocator,
        .user = .{ .userdata = &col, .onDelta = Collector.onDelta },
    };
    defer ctx.destroy();

    // A single event, split into 5 arbitrary pieces (in the middle of a line
    // and between the `\n` and the next `data:`).
    const full = "data: {\"choices\":[{\"delta\":{\"content\":\"Hola mundo\"}}]}\n\ndata: [DONE]\n\n";
    const cuts = [_]usize{ 7, 23, 51, 52, full.len };
    var prev: usize = 0;
    for (cuts) |cut| {
        try ctx.feed(full[prev..cut]);
        prev = cut;
    }
    try ctx.finish();
    try std.testing.expectEqualStrings("Hola mundo", col.text.items);
}

test "feed: un payload partido a mitad de UTF-8 no se corrompe" {
    const Collector = struct {
        text: std.ArrayList(u8) = .empty,
        fn onDelta(ud: ?*anyopaque, delta: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            self.text.appendSlice(std.testing.allocator, delta) catch {};
        }
    };
    var col = Collector{};
    defer col.text.deinit(std.testing.allocator);

    const ctx = try std.testing.allocator.create(StreamCtx);
    ctx.* = .{
        .gpa = std.testing.allocator,
        .user = .{ .userdata = &col, .onDelta = Collector.onDelta },
    };
    defer ctx.destroy();

    // "ñ" is 2 bytes and "✓" is 3: the cuts land inside those bytes.
    const full = "data: {\"choices\":[{\"delta\":{\"content\":\"a\u{00f1}\u{2713}b\"}}]}\n\n";
    for (full, 0..) |_, i| {
        try ctx.feed(full[i .. i + 1]); // one byte per chunk, the worst case
    }
    try ctx.finish();
    try std.testing.expectEqualStrings("a\u{00f1}\u{2713}b", col.text.items);
}

test "feed: un tool call cortado a mitad de args se emite al finish" {
    // Regression: with the old trigger ("last byte == '}'") a stream cut
    // before the closing byte hung the agent loop forever.
    const Collector = struct {
        calls: usize = 0,
        last_name: []const u8 = "",
        last_args: []const u8 = "",
        fn onToolCall(ud: ?*anyopaque, _: []const u8, name: []const u8, args: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            self.calls += 1;
            self.last_name = name;
            self.last_args = args;
        }
        fn onDelta(_: ?*anyopaque, _: []const u8) void {}
    };
    var col = Collector{};

    const ctx = try std.testing.allocator.create(StreamCtx);
    ctx.* = .{
        .gpa = std.testing.allocator,
        .user = .{ .userdata = &col, .onToolCall = Collector.onToolCall },
    };
    defer ctx.destroy();

    // Args that do NOT end in '}' (the connection cuts right after).
    const sse =
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"a.txt\\\"}\"}}]}}]}\n\n";
    try scanSse(std.testing.allocator, sse, ctx);

    try std.testing.expectEqual(@as(usize, 1), col.calls);
    try std.testing.expectEqualStrings("read", col.last_name);
    try std.testing.expectEqualStrings("{\"path\":\"a.txt\"}", col.last_args);
}

test "feed: un tool sin argumentos se trata como objeto vacío" {
    const Collector = struct {
        calls: usize = 0,
        last_args: []const u8 = "",
        fn onToolCall(ud: ?*anyopaque, _: []const u8, _: []const u8, args: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            self.calls += 1;
            self.last_args = args;
        }
        fn onDelta(_: ?*anyopaque, _: []const u8) void {}
    };
    var col = Collector{};

    const ctx = try std.testing.allocator.create(StreamCtx);
    ctx.* = .{
        .gpa = std.testing.allocator,
        .user = .{ .userdata = &col, .onToolCall = Collector.onToolCall },
    };
    defer ctx.destroy();

    // `list_files` without arguments: the server sends "arguments":"".
    const sse =
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"list_files\",\"arguments\":\"\"}}]}}]}\n\n";
    try scanSse(std.testing.allocator, sse, ctx);

    try std.testing.expectEqual(@as(usize, 1), col.calls);
    try std.testing.expectEqualStrings("{}", col.last_args);
}

test "buildBodyOpenAI: o-series usa max_completion_tokens + reasoning_effort" {
    var buf: [64 * 1024]u8 = undefined;
    const msgs = [_]ChatMessage{.{ .role = "user", .content = "hi" }};

    // gpt-5: `max_tokens` gives a 400 in OpenAI's API.
    const body = try buildBodyMessages(&buf, "gpt-5", &msgs, .medium, "", .openai);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_completion_tokens\":32768") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"medium\"") != null);
    // Reasoning models do not accept temperature.
    try std.testing.expect(std.mem.indexOf(u8, body, "temperature") == null);

    // o3 also enters through the reasoning branch.
    const o3 = try buildBodyMessages(&buf, "o3-mini", &msgs, .high, "", .openai);
    try std.testing.expect(std.mem.indexOf(u8, o3, "\"max_completion_tokens\":65536") != null);
    try std.testing.expect(std.mem.indexOf(u8, o3, "\"reasoning_effort\":\"high\"") != null);

    // xhigh asked on a model that tops out at high goes out AS high: an unknown
    // level is an instant 400, and which models know the word is not knowable
    // from the id, hence `effortSupport`.
    const xh = try buildBodyMessages(&buf, "gpt-5", &msgs, .xhigh, "", .openai);
    try std.testing.expect(std.mem.indexOf(u8, xh, "\"reasoning_effort\":\"high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, xh, "\"max_completion_tokens\":65536") != null);

    // Y en un modelo que SI lo toma, sale xhigh de verdad. Antes no habia forma de
    // llegar aqui. OJO: `gpt-5.1` a secas NO lo toma (xhigh es solo de codex-max),
    // y mandarselo seria un 400: la primera version de esta tabla lo decia al
    // reves y el test lo daba por bueno.
    const xh2 = try buildBodyMessages(&buf, "gpt-5.1-codex-max", &msgs, .xhigh, "", .openai);
    try std.testing.expect(std.mem.indexOf(u8, xh2, "\"reasoning_effort\":\"xhigh\"") != null);

    // Y `gpt-5.1` a secas degrada xhigh a high, que es lo que hacen las docs.
    const xh3 = try buildBodyMessages(&buf, "gpt-5.1", &msgs, .xhigh, "", .openai);
    try std.testing.expect(std.mem.indexOf(u8, xh3, "\"reasoning_effort\":\"high\"") != null);
}

test "buildBodyOpenAI: modelo normal conserva max_tokens" {
    var buf: [64 * 1024]u8 = undefined;
    const msgs = [_]ChatMessage{.{ .role = "user", .content = "hi" }};

    const body = try buildBodyMessages(&buf, "kimi-k2.6", &msgs, .low, "", .openai);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":32768") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "max_completion_tokens") == null);
    // Un modelo SIN la palanca no recibe el campo: mandarselo es un 400.
    try std.testing.expect(std.mem.indexOf(u8, body, "reasoning_effort") == null);
}

test "buildBodyOpenAI: un modelo con mas niveles los recibe (Gemini, gpt-5.1)" {
    // El bug 3: "hay modelos que soportan mas" era verdad y no habia forma de
    // aprovecharla. Ahora el campo sale siempre que el modelo lo tenga, y con el
    // nivel que ESE modelo entiende.
    var buf: [64 * 1024]u8 = undefined;
    const msgs = [_]ChatMessage{.{ .role = "user", .content = "hi" }};

    // Gemini 3 llama `minimal` a su primer escalon y no tiene `none`: pedir "no
    // pensar" llega como `minimal`, que es lo mas cerca que existe.
    const g_min = try buildBodyMessages(&buf, "gemini-3.5-flash", &msgs, .minimal, "", .openai);
    try std.testing.expect(std.mem.indexOf(u8, g_min, "\"reasoning_effort\":\"minimal\"") != null);

    const g_none = try buildBodyMessages(&buf, "gemini-3.5-flash", &msgs, .none, "", .openai);
    try std.testing.expect(std.mem.indexOf(u8, g_none, "\"reasoning_effort\":\"minimal\"") != null);

    // Y xhigh en Gemini degrada a high (su techo), no a algo inventado.
    const g_x = try buildBodyMessages(&buf, "gemini-3.5-flash", &msgs, .xhigh, "", .openai);
    try std.testing.expect(std.mem.indexOf(u8, g_x, "\"reasoning_effort\":\"high\"") != null);

    // Gemini 2.5 NO tiene `minimal` (docs: low/medium/high), asi que pedirlo
    // degrada a `low` en vez de mandar un nivel que no existe.
    const g25 = try buildBodyMessages(&buf, "gemini-2.5-pro", &msgs, .minimal, "", .openai);
    try std.testing.expect(std.mem.indexOf(u8, g25, "\"reasoning_effort\":\"low\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, g25, "minimal") == null);

    // `none` de verdad, en un modelo que lo tiene. Antes el enum ni siquiera
    // tenia ese nivel.
    const o_none = try buildBodyMessages(&buf, "gpt-5.1", &msgs, .none, "", .openai);
    try std.testing.expect(std.mem.indexOf(u8, o_none, "\"reasoning_effort\":\"none\"") != null);
}

test "effortSupport: la escalera de cada modelo sale de las DOCS, no de la intuicion" {
    // Esta tabla se corrigio tras verificar contra la matriz de niveles de
    // OpenAI y la tabla de `thinking_level` de Google. Los tres fallos eran
    // inventados:
    //
    //   - `xhigh` NO existe en `gpt-5.1` (solo en codex-max). Mandarlo = 400.
    //   - `minimal` NO existe en GPT-5 previos a 5.1, ni en gemini-2.5.
    //   - gemini-2.5 no tiene `minimal` y gemini-3-pro-preview no tiene `medium`.
    try std.testing.expectEqual(EffortSupport.none, effortSupport("kimi-k2.6"));
    try std.testing.expectEqual(EffortSupport.codex_max, effortSupport("gpt-5.1-codex-max"));
    // `codex-max` tiene que ganarle a `gpt-5.1` en el orden, no al reves.
    try std.testing.expectEqual(EffortSupport.gpt51, effortSupport("gpt-5.1"));
    // Un GPT-5 de antes de 5.1: la escalera basica, sin `minimal` ni `none`.
    try std.testing.expectEqual(EffortSupport.basic, effortSupport("gpt-5"));
    try std.testing.expectEqual(EffortSupport.basic, effortSupport("o3-mini"));
    try std.testing.expectEqual(EffortSupport.basic, effortSupport("o1"));
    // Gemini 2.5 es `basic` (docs: low/medium/high), y los 3.5+Suben a minimal.
    try std.testing.expectEqual(EffortSupport.basic, effortSupport("gemini-2.5-pro"));
    try std.testing.expectEqual(EffortSupport.gemini3_minimal, effortSupport("gemini-3.5-flash"));

    // Los ids llegan con prefijo de proveedor (`openai/gpt-5.1`), asi que la
    // busqueda es por SUBSTRING y no por prefijo.
    try std.testing.expectEqual(EffortSupport.gpt51, effortSupport("openai/gpt-5.1"));
    try std.testing.expectEqual(EffortSupport.gemini3_minimal, effortSupport("google/gemini-3.6-flash"));

    // Un modelo sin la palanca NO recibe nivel: `effortFor` dice null y el body
    // se queda sin el campo.
    try std.testing.expectEqual(@as(?Effort, null), effortFor("kimi-k2.6", .high));

    // Y el techo del picker es el del modelo, no el nuestro.
    try std.testing.expectEqual(Effort.xhigh, maxEffortFor("gpt-5.1-codex-max"));
    try std.testing.expectEqual(Effort.high, maxEffortFor("gpt-5.1"));
    try std.testing.expectEqual(Effort.high, maxEffortFor("gpt-5"));
    try std.testing.expectEqual(Effort.high, maxEffortFor("gemini-2.5-pro"));
}

test "effortFor: NUNCA pide un nivel que el modelo no documenta" {
    // Este es el invariante que de verdad importa, y es el que la primera version
    // incumplia en tres modelos. Se recorre TODA la combinacion de modelo x
    // nivel y se exige que lo que sale sea un nivel que ese modelo acepte.
    //
    // La lista de "aceptados" esta escrita a mano de las docs. Es codigo, no una
    // verdad que salga de la tabla de arriba: si las dos se derivaran la una de
    // la otra, el test pasaria con las dos equivocadas (que es exactamente como
    // se colaron los tres fallos).
    const Cases = struct {
        model: []const u8,
        /// Los niveles que las DOCS dicen que acepta.
        ok: []const Effort,
    };
    const cases = [_]Cases{
        .{ .model = "kimi-k2.6", .ok = &.{} },
        .{ .model = "gpt-5", .ok = &.{ .low, .medium, .high } },
        .{ .model = "o3-mini", .ok = &.{ .low, .medium, .high } },
        .{ .model = "gpt-5.1", .ok = &.{ .none, .minimal, .low, .medium, .high } },
        .{ .model = "gpt-5.1-codex-max", .ok = &.{ .none, .minimal, .low, .medium, .high, .xhigh } },
        .{ .model = "gemini-2.5-pro", .ok = &.{ .low, .medium, .high } },
        .{ .model = "gemini-3.5-flash", .ok = &.{ .minimal, .low, .medium, .high } },
    };
    const all = [_]Effort{ .none, .minimal, .low, .medium, .high, .xhigh };

    for (cases) |c| {
        for (all) |want| {
            const got = effortFor(c.model, want);
            if (got == null) {
                // Sin palanca: esta bien no mandar nada. Pero si el modelo
                // estaba en la tabla con escalera, no puede desaparecer.
                try std.testing.expectEqual(EffortSupport.none, effortSupport(c.model));
                continue;
            }
            var accepted = false;
            for (c.ok) |k| {
                if (k == got.?) accepted = true;
            }
            if (!accepted) {
                std.debug.print(
                    "\\n  {s}: pidió {s} y salió {s}, que no está en sus docs\\n",
                    .{ c.model, want.label(), got.?.label() },
                );
            }
            try std.testing.expect(accepted);
        }
    }
}

test "effortLevels (el picker) y effortFor (el cable) no se contradicen" {
    // Un nivel que el picker ofrece y `effortFor` no puede representar es un
    // 400 esperando a que el usuario lo pulse; uno que degrada en silencio es un
    // boton que no hace nada. Las dos cosas son senales  de un picker roto.
    const models = [_][]const u8{
        "kimi-k2.6",       "gpt-5",         "o3-mini",        "gpt-5.1",
        "gpt-5.1-codex-max", "gemini-2.5-pro", "gemini-3.5-flash",
    };
    for (models) |m| {
        for (effortLevels(m)) |lv| {
            const got = effortFor(m, lv);
            if (got == null) continue;
            // Lo que se ofrece tiene que salir EXACTO, no una version degradada.
            try std.testing.expectEqual(lv, got.?);
        }
    }
}

test "effort automatico: el default sale de la escalera del modelo, no de un `medium` fijo" {
    // El default era `.medium` para TODO, y `medium` no esta en la escalera de
    // todos los modelos. El default es el escalon de EN MEDIO de la escalera que
    // tenga ese modelo, que es lo unico que se puede decir sin conocer cada
    // modelo de memoria.
    const models = [_][]const u8{
        "kimi-k2.6",         "gpt-5",          "gpt-5.1",
        "gpt-5.1-codex-max", "gemini-2.5-pro", "gemini-3.5-flash",
    };
    for (models) |m| {
        const d = defaultEffort(m);
        // Tiene que ser un nivel que el modelo ACEPTE de verdad...
        const lv = effortLevels(m);
        var on_ladder = false;
        for (lv) |k| {
            if (k == d) on_ladder = true;
        }
        try std.testing.expect(on_ladder);
        // ...y tiene que ser representable: no vale con que no reviente.
        _ = effortFor(m, d);
    }

    // El indice es lo que decide (el escalon de EN MEDIO), y se pinea caso por
    // caso porque el enum esta ORDENADO pero las escaleras no tienen por que
    // tener la misma longitud:
    //   3 niveles (low/medium/high)      -> indice 1 -> medium
    //   5 niveles (none..high)           -> indice 2 -> low
    //   6 niveles (none..xhigh)          -> indice 3 -> medium
    //   2 niveles (low/high)             -> indice 1 -> high   <-- sin `medium`
    //   none..high (5)         -> indice 2 -> low
    //   none..xhigh (6)        -> indice 3 -> medium
    try std.testing.expectEqual(Effort.medium, defaultEffort("gemini-2.5-pro"));
    try std.testing.expectEqual(Effort.medium, defaultEffort("gpt-5"));
    try std.testing.expectEqual(Effort.low, defaultEffort("gpt-5.1"));
    try std.testing.expectEqual(Effort.medium, defaultEffort("gpt-5.1-codex-max"));

    // Y el caso que de verdad demuestra el punto: un modelo SIN `medium`.
    // Si el default fuese el literal `.medium`, aqui recibiria un nivel que no
    // existe, y el primer turno de una sesion nueva (donde el usuario no ha
    // tocado `/effort`) se comeria un 400.
    try std.testing.expectEqual(Effort.high, defaultEffort("gemini-3-pro-preview"));
    try std.testing.expectEqual(@as(?Effort, .low), effortFor("gemini-3-pro-preview", .medium));
}

test "clampEffort: cambiar de modelo baja el peldano que ya no existe" {
    // El `xhigh` que se eligio en un codex-max tiene que dejar de existir al
    // cambiar a un gemini-2.5, no quedarse puesto degradandose en silencio (el
    // status bar diria `xhigh` y el cable llevaria `high`, que son dos cosas
    // distintas sin ninguna pista de que lo sean).
    try std.testing.expectEqual(Effort.high, clampEffort("gemini-2.5-pro", .xhigh));
    try std.testing.expectEqual(Effort.xhigh, clampEffort("gpt-5.1-codex-max", .xhigh));
    // Y algo que el modelo SI tiene no se toca.
    try std.testing.expectEqual(Effort.low, clampEffort("gpt-5", .low));
    try std.testing.expectEqual(Effort.none, clampEffort("gpt-5.1", .none));

    // Y el clamp es IDEMPOTENTE y nunca SUBE un nivel (subir por encima del
    // techo es el 400).
    const models = [_][]const u8{ "kimi-k2.6", "gpt-5", "gpt-5.1", "gpt-5.1-codex-max", "gemini-2.5-pro" };
    for (models) |m| {
        for ([_]Effort{ .none, .minimal, .low, .medium, .high, .xhigh }) |lv| {
            const once = clampEffort(m, lv);
            const twice = clampEffort(m, once);
            try std.testing.expectEqual(once, twice);
            try std.testing.expect(@intFromEnum(once) <= @intFromEnum(lv));
        }
    }
}

test "effectiveEffort: nunca devuelve null (un modelo sin palanca usa su default)" {
    // La razon de que esta funcion exista: `effortFor` devuelve `?Effort` y
    // `null` significa "este modelo no tiene la palanca", que NO es un error
    // pero obliga a que cada llamante se acuerde. Aqui se colapsa, y el camino
    // del request no tiene que saber nada.
    // Sin palanca: cae al default, que es el medio de `low/medium/high`.
    try std.testing.expectEqual(Effort.medium, effectiveEffort("kimi-k2.6", .high));
    try std.testing.expectEqual(Effort.medium, effectiveEffort("gpt-5", .medium));
    try std.testing.expectEqual(Effort.high, effectiveEffort("gpt-5.1", .xhigh));
    try std.testing.expectEqual(Effort.xhigh, effectiveEffort("gpt-5.1-codex-max", .xhigh));
    // Y lo que sale tiene que ser algo que el modelo acepta.
    const m = "gemini-2.5-pro";
    const e = effectiveEffort(m, .xhigh);
    var ok = false;
    for (effortLevels(m)) |k| {
        if (k == e) ok = true;
    }
    try std.testing.expect(ok);
}

test "buildBodyAnthropic: thinking con budget menor que max_tokens" {
    var buf: [64 * 1024]u8 = undefined;
    const msgs = [_]ChatMessage{.{ .role = "user", .content = "hi" }};

    // effort=high → techo 65536 > budget 16384: thinking enabled.
    const high = try buildBodyMessages(&buf, "claude-sonnet-4-5", &msgs, .high, "", .anthropic);
    try std.testing.expect(std.mem.indexOf(u8, high, "\"max_tokens\":65536") != null);
    try std.testing.expect(std.mem.indexOf(u8, high, "\"budget_tokens\":16384") != null);

    // effort=medium → techo 32768 > budget 8192: thinking enabled too.
    const med = try buildBodyMessages(&buf, "claude-sonnet-4-5", &msgs, .medium, "", .anthropic);
    try std.testing.expect(std.mem.indexOf(u8, med, "\"budget_tokens\":8192") != null);

    // effort=low → techo 32768 > budget 4096. Antes `low` era un techo de 4096
    // con un budget de 2048: dos veces menos sitio para la respuesta que para
    // pensar, y una respuesta con tools se cortaba a la mitad.
    const low = try buildBodyMessages(&buf, "claude-sonnet-4-5", &msgs, .low, "", .anthropic);
    try std.testing.expect(std.mem.indexOf(u8, low, "\"budget_tokens\":4096") != null);

    // effort=none → sin thinking en absoluto (budget 0 = no se manda el bloque).
    const none = try buildBodyMessages(&buf, "claude-sonnet-4-5", &msgs, .none, "", .anthropic);
    try std.testing.expect(std.mem.indexOf(u8, none, "\"thinking\"") == null);

    // Y xhigh sube el budget de verdad (24576), que antes se aplastaba a 16384.
    const xh = try buildBodyMessages(&buf, "claude-sonnet-4-5", &msgs, .xhigh, "", .anthropic);
    try std.testing.expect(std.mem.indexOf(u8, xh, "\"budget_tokens\":24576") != null);

    // The thinking budget can never equal max_tokens: Anthropic
    // requires budget_tokens < max_tokens.
    try std.testing.expect(!hasBadThinkingBudget(high));
    try std.testing.expect(!hasBadThinkingBudget(med));
    try std.testing.expect(!hasBadThinkingBudget(low));
}

test "familyForModel detecta razonamiento solo en o-series/gpt-5" {
    try std.testing.expectEqual(Family.openai_reasoning, familyForModel("gpt-5"));
    try std.testing.expectEqual(Family.openai_reasoning, familyForModel("gpt-5-mini"));
    try std.testing.expectEqual(Family.openai_reasoning, familyForModel("o3"));
    try std.testing.expectEqual(Family.openai_reasoning, familyForModel("o4-mini"));
    try std.testing.expectEqual(Family.generic_openai, familyForModel("gpt-4o"));
    try std.testing.expectEqual(Family.generic_openai, familyForModel("kimi-k2.6"));
    try std.testing.expectEqual(Family.generic_openai, familyForModel("claude-sonnet-4-5"));
}

/// Test helper: does the body have a thinking budget >= max_tokens?
/// Anthropic rejects that combination, so this is a safety net.
fn hasBadThinkingBudget(body: []const u8) bool {
    const ti = std.mem.indexOf(u8, body, "\"thinking\"") orelse return false;
    const bt = std.mem.indexOfScalarPos(u8, body, ti, '{') orelse return false;
    const bpos = std.mem.indexOfPos(u8, body, bt, "budget_tokens\":") orelse return false;
    const budget = std.fmt.parseInt(u32, std.mem.trim(u8, body[bpos + 14 ..], "}"), 10) catch return false;
    const mpos = std.mem.indexOf(u8, body, "\"max_tokens\":") orelse return false;
    const max_tok = std.fmt.parseInt(u32, std.mem.trim(u8, body[mpos + 13 ..], ","), 10) catch return false;
    return budget >= max_tok;
}

test "feed: una línea SSE más grande que cualquier buffer se reensambla" {
    // Regression: `takeDelimiter` failed with StreamTooLong if the line did not
    // fit in the transfer buffer and the stream died halfway through. The
    // parser has to be able to reassemble it from many pieces.
    const Collector = struct {
        text: std.ArrayList(u8) = .empty,
        fn onDelta(ud: ?*anyopaque, delta: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            self.text.appendSlice(std.testing.allocator, delta) catch {};
        }
    };
    var col = Collector{};
    defer col.text.deinit(std.testing.allocator);

    const ctx = try std.testing.allocator.create(StreamCtx);
    ctx.* = .{
        .gpa = std.testing.allocator,
        .user = .{ .userdata = &col, .onDelta = Collector.onDelta },
    };
    defer ctx.destroy();

    // ~200 KB payload spread over 8 KB chunks: in practice that is what happens
    // when the model returns a huge tool call or a long fragment.
    const payload_len: usize = 200_000;
    const prefix = "data: {\"choices\":[{\"delta\":{\"content\":\"";
    const suffix = "\"}}]}\n\ndata: [DONE]\n\n";

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const total = prefix.len + payload_len + suffix.len;
    const line = try arena.alloc(u8, total);
    @memcpy(line[0..prefix.len], prefix);
    @memset(line[prefix.len .. prefix.len + payload_len], 'x');
    @memcpy(line[prefix.len + payload_len ..], suffix);

    // Aggressive chopping, not respecting line boundaries.
    var off: usize = 0;
    while (off < line.len) {
        const n = @min(8192, line.len - off);
        try ctx.feed(line[off .. off + n]);
        off += n;
    }
    try ctx.finish();

    try std.testing.expectEqual(payload_len, col.text.items.len);
    try std.testing.expectEqual(@as(u8, 'x'), col.text.items[0]);
    try std.testing.expectEqual(@as(u8, 'x'), col.text.items[payload_len - 1]);
}

test "StreamCtx.destroy no fuga con parts y line_buf poblados" {
    // The error path of `streamChatCtx` must call `destroy` (NOT `deinit`),
    // because by the time a request fails the ctx already has accumulated tool
    // calls and a line buffer. `destroy` is what frees them; without it they
    // leaked.
    const ctx = try std.testing.allocator.create(StreamCtx);
    ctx.* = .{
        .gpa = std.testing.allocator,
        .user = .{},
        .line_buf = .empty,
    };
    // Simulates real work: a half-finished tool call and a half-finished SSE line.
    try ctx.line_buf.appendSlice(std.testing.allocator, "data: {\"a\":1}");
    const p = try ctx.partFor(0);
    try p.id.appendSlice(std.testing.allocator, "call_1");
    try p.name.appendSlice(std.testing.allocator, "read");
    try p.args.appendSlice(std.testing.allocator, "{\"path\":\"x\"}");
    try p.args.append(std.testing.allocator, '}');

    // `streamChatCtx` calls this in its `errdefer`; the test allocator
    // fails if anything is left unfreed.
    ctx.destroy();
}

test "setServerMessage: saca el message del JSON de error" {
    // It is what turns a useless "HTTP 403" into "Model access is disabled".
    setServerMessage(
        \\{"error":{"type":"server_error","message":"Upstream request failed: Model access is disabled"}}
    );
    try std.testing.expectEqualStrings("Upstream request failed: Model access is disabled", lastErrorBody());

    setServerMessage(
        \\{"error":{"type":"server_error","message":"Upstream request failed: Insufficient account funds"}}
    );
    try std.testing.expectEqualStrings("Upstream request failed: Insufficient account funds", lastErrorBody());
}

test "setServerMessage: aguanta basura sin desbordar" {
    // Without "message" (odd JSON), empty, unopened quote, and a huge
    // string: under no circumstances may it overrun the buffer or leave junk.
    setServerMessage("");
    try std.testing.expectEqual(@as(usize, 0), last_error_len);
    setServerMessage("<html>502 Bad Gateway</html>");
    try std.testing.expectEqual(@as(usize, 0), last_error_len);
    setServerMessage("{\"message\": 42}");
    try std.testing.expectEqual(@as(usize, 0), last_error_len);

    const huge = "{\"message\":\"" ++ "x" ** 900 ++ "\"}";
    setServerMessage(huge);
    try std.testing.expect(last_error_len > 0 and last_error_len < last_error_buf.len);
}

test "setServerMessage: desescapa comilla y barra" {
    setServerMessage("{\"message\":\"say \\\"hi\\\" \\\\o/\"}");
    try std.testing.expectEqualStrings("say \"hi\" \\o/", lastErrorBody());
}

test "noteRaw: guarda solo los primeros bytes, sin desbordar" {
    // The buffer is 512: it serves the short error JSON, and if the body is
    // huge (an error HTML from a proxy) it is cut without blowing anything up.
    // CAREFUL: `destroy` takes the struct with it, so it has to live on the
    // heap (that is why it is asked with `gpa.create` and not as a local).
    const ctx = try std.testing.allocator.create(StreamCtx);
    ctx.* = .{ .gpa = std.testing.allocator, .user = .{} };
    ctx.noteRaw("hola");
    ctx.noteRaw(" mundo");
    try std.testing.expectEqualStrings("hola mundo", ctx.raw[0..ctx.raw_len]);
    try std.testing.expect(!ctx.saw_done);
    ctx.destroy();
}

test "los 402 y 403 tienen error propio (no se reintentan)" {
    // 402 without credits used to be retried 3 times as if it were a 5xx: three
    // backoff waits for an error that is not going to fix itself.
    try std.testing.expect(!isRetryableTest(error.NoCredits));
    try std.testing.expect(!isRetryableTest(error.Forbidden));
    try std.testing.expect(!isRetryableTest(error.AuthFailed));
    try std.testing.expect(isRetryableTest(error.RateLimited));
    try std.testing.expect(isRetryableTest(error.Overloaded));
}

/// Mirror of `agent.isRetryable`'s decision, so it can be tested without
/// depending on the agent module (which imports the whole TUI).
fn isRetryableTest(err: anyerror) bool {
    return switch (err) {
        error.RateLimited, error.Overloaded, error.ServerError => true,
        else => false,
    };
}
