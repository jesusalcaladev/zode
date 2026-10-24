const std = @import("std");
const http_client = @import("lib/http_client.zig");
const sleep = @import("lib/sleep.zig");

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
    /// The same rung as `xhigh` under the name Z.AI uses for its top level
    /// (`reasoning_effort: "max"`, which is also its default).
    ///
    /// It is a member of its own and not `xhigh` renamed because the WORD is the
    /// contract: a model that only knows `max` answers 400 to `xhigh`, and the
    /// other way around. No ladder in `effortSupport` offers it yet, so asking
    /// for it lands on the model's top rung and `"max"` never reaches a provider
    /// that did not ask for it.
    max,

    pub fn parse(s: []const u8) ?Effort {
        const eq = std.ascii.eqlIgnoreCase;
        if (eq(s, "none") or eq(s, "off")) return .none;
        if (eq(s, "minimal")) return .minimal;
        if (eq(s, "low")) return .low;
        if (eq(s, "medium") or eq(s, "med")) return .medium;
        if (eq(s, "high")) return .high;
        if (eq(s, "xhigh")) return .xhigh;
        if (eq(s, "max")) return .max;
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
            .max => .xhigh,
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
            .max => 65536,
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
            .max => 24576,
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
/// **This table was verified against the docs, not against what looks reasonable.**
/// The first version was written from memory and was WRONG in three places,
/// which is exactly the failure mode no test in this repo catches: the tests
/// compare the JSON that zode generates against the JSON that zode's own code
/// says it should generate. If both are wrong, the test passes. What is needed
/// is to read the provider's documentation, and:
///
///   - `xhigh` does NOT exist in `gpt-5.1`. Only in `gpt-5.1-codex-max` (verified:
///     OpenAI's effort matrix lists none/low/medium/high for 5.1, and adds xhigh
///     only for codex-max). I had put `xhigh` for all of 5.1, i.e. a 400 the
///     moment somebody typed `/effort xhigh`.
///   - `minimal` does NOT exist in the GPT-5s before 5.1, nor in `gemini-2.5-*`.
///     It is 5.1 onwards, and certain Gemini 3 models.
///   - Gemini calls the field `thinking_level`, not `reasoning_effort`. Over the
///     OpenAI-compatible path (`/v1beta/openai/`, and OpenRouter) it is mapped,
///     which is why OpenAI's name is the one we send. The VALUES, on the other
///     hand, are Gemini's.
///
/// The rest of the criterion is the usual one: a level the model does not know is
/// a 400, and a 400 in the middle of a turn is invisible. When in doubt,
/// **degrade**.
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
    /// It exists for the reason that matters: it is the only case where the
    /// "middle" default CANNOT be `medium`. Without this row, a model with no
    /// `medium` would receive `medium` for being the middle rung of a ladder
    /// that nobody looked up.
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
    // The Gemini 3 pro models do not take `medium` (docs: low and high). It is
    // the only known model without the middle rung, so it gets its own row
    // instead of falling into `basic` and receiving a `medium` that is not there.
    if (containsAny(model, &.{ "gemini-3-pro", "gemini-3.1-pro" })) return .no_medium;
    // Everything else with a knob: the basic ladder. Gemini 2.5 and the odd
    // `gemini-3-pro-preview` are here on purpose — `basic` is a subset of what
    // they take, and `medium` is the only level that could surprise us (it is
    // documented as unsupported on 3-pro-preview), so that one degrades high.
    if (containsAny(model, &.{"gemini"})) return .basic;
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
        // `minimal` is NOT on this ladder: sending it to a GPT-5 older than 5.1
        // is a 400. Neither is `none`, and "do not think" falls to `low`, which
        // is the cheapest thing the model knows how to do.
        .basic => switch (want) {
            .none, .minimal, .low => .low,
            .medium => .medium,
            .high, .xhigh, .max => .high,
        },
        .gpt51 => switch (want) {
            .none => .none,
            .minimal => .minimal,
            .low => .low,
            .medium => .medium,
            .high, .xhigh, .max => .high,
        },
        // OpenAI's vocabulary tops at `xhigh`: sending it the word `max` is a
        // 400, so the wish for "more than high" lands on the rung it does have.
        .codex_max => switch (want) {
            .max => .xhigh,
            else => want,
        },
        // Gemini has no `none`: its floor is `minimal`.
        .gemini3_minimal => switch (want) {
            .none, .minimal => .minimal,
            .low => .low,
            .medium => .medium,
            .high, .xhigh, .max => .high,
        },
        // No `medium`: degrade towards `low` (the requested level is more than
        // the model can do, and `low` is the nearest one below it).
        .no_medium => switch (want) {
            .none, .minimal, .low, .medium => .low,
            .high, .xhigh, .max => .high,
        },
    };
}

/// The `reasoning_effort` STRING for a model that has the field.
///
/// The NAME is OpenAI's on purpose even for Gemini: Gemini calls the field
/// `thinking_level`, but over the OpenAI-compatible path (which is how zode
/// talks, via OpenRouter or `/v1beta/openai/`) it is mapped from
/// `reasoning_effort`. The VALUES, on the other hand, are Gemini's.
///
/// And the level is written "x-high" nowhere: the word is `xhigh`.
pub fn reasoningEffortString(model: []const u8, want: Effort) ?[]const u8 {
    const e = effortFor(model, want) orelse return null;
    return switch (e) {
        .none => "none",
        .minimal => "minimal",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
        .max => "max",
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
/// An image on the wire, as OpenAI-compatible `image_url` wants it.
///
/// `data_b64` is the base64 WITHOUT the `data:` prefix, and the serializer builds
/// the prefix. It is stored that way so the same buffer is what the encoder
/// produced, with no second copy of a megabyte of base64.
pub const Image = struct {
    mime: []const u8,
    data_b64: []const u8,
};

/// An image that has not been encoded yet, which is how `read` leaves it.
pub const ImageRef = struct {
    mime: []const u8,
    /// The bytes as read from disk.
    bytes: []const u8,
};

pub const ChatMessage = struct {
    role: []const u8, // "system" | "user" | "assistant" | "tool"
    content: []const u8,
    tool_calls_json: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    /// Images that go WITH this message, as content blocks.
    ///
    /// Only a `user` message may carry them, and that is a property of the
    /// protocol, not a choice: a `tool` message's content is a plain string in
    /// OpenAI's shape, so an image a tool "read" cannot ride along there. That is
    /// why `read` on a picture leaves the bytes in the harness and the harness puts
    /// them on the NEXT user message, which is also where the model's attention is.
    images: []const Image = &.{},

    pub fn isMultimodal(self: ChatMessage) bool {
        return self.images.len > 0 and !std.mem.eql(u8, self.role, "tool");
    }
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
/// The server's own explanation of a failure, kept per REQUEST.
///
/// It used to be two module globals (`last_error_buf`, `last_error_len`). That is
/// fine for one request at a time and wrong the moment two run at once, which is
/// what a parallel subagent is: two failures interleaving into one buffer means
/// each request reports the OTHER one's error.
pub const ErrBuf = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const ErrBuf) []const u8 {
        return self.buf[0..self.len];
    }
};

fn setServerMessageInto(out: *ErrBuf, body: []const u8) void {
    out.len = 0;
    setServerMessageRaw(out, body);
}

/// Stores an already-extracted message. Not the same as `setServerMessageInto`,
/// which PARSES the `"message"` key out of a JSON body.
fn storeErrText(out: *ErrBuf, msg: []const u8) void {
    out.len = 0;
    const n = @min(msg.len, out.buf.len);
    @memcpy(out.buf[0..n], msg[0..n]);
    out.len = n;
}

fn setServerMessage(body: []const u8) void {
    setServerMessageRaw(&main_err, body);
}

/// The main turn's error buffer: what `lastErrorBody()` reads.
pub var main_err: ErrBuf = .{};

fn setServerMessageRaw(out: *ErrBuf, body: []const u8) void {
    out.len = 0;
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
        if (n + 1 >= out.buf.len) break;
        out.buf[n] = body[i];
        n += 1;
    }
    if (n == 0) return;
    out.len = n;
}

/// How many bytes of the last error message are valid.
pub fn lastErrorLen() usize {
    return main_err.len;
}

/// The capacity of the error buffer, for the tests that check it does not overrun.
pub fn lastErrorCap() usize {
    return main_err.buf.len;
}

// ── ZODE_DBG_ERR: dump the server response ────────────────────
//
// `ZODE_DBG_ERR=1` prints to stderr the status and the first bytes of EVERY
// response (good or bad). It exists for one concrete reason: the error message
// shown in the TUI comes from `"message":"..."` in the body, and when the body
// has no such field (or arrives chunked) all that is displayed is "HTTP 403"
// with nothing to pull on. With this you read what the server actually said.
//
// It is read ONCE at startup (`dbgInitEnv`): the `Io` does not expose the
// environment, and reading it per response would be a lookup per request.
pub var dbg_err_flag: bool = false;

pub fn dbgInitEnv(env: ?*const std.process.Environ.Map) void {
    const v = if (env) |e| e.get("ZODE_DBG_ERR") else null;
    dbg_err_flag = if (v) |x| x.len > 0 and x[0] != '0' else false;
}

fn dbg_err() bool {
    return dbg_err_flag;
}

pub fn lastErrorBody() []const u8 {
    return main_err.slice();
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
    /// Tokens WRITTEN into the provider's cache on this request (Anthropic's
    /// `cache_creation_input_tokens`).
    ///
    /// It is the number that decides whether a prefix is well placed. A hit-rate
    /// can be beautiful while this is enormous, and that combination means the
    /// prefix is being re-written every turn: the expensive direction. With only
    /// reads visible, `/cache` could not tell a healthy session from one that
    /// re-caches 16 KB of tools on every single request.
    cache_write: i64 = 0,
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
        // Into the ctx of the request that failed, not into a global: two
        // concurrent requests must not overwrite each other's explanation.
        //
        // CAREFUL: `msg` is the message ALREADY extracted, not a JSON body, so it
        // is stored as-is. Handing it to `setServerMessage` (which looks for the
        // `"message"` key) silently stored nothing, and the user saw an empty
        // error where there was one.
        if (userdata) |u| {
            const self: *StreamCtx = @ptrCast(@alignCast(u));
            storeErrText(&self.err, msg);
            if (self.mirror_globals) main_err = self.err;
        } else {
            storeErrText(&main_err, msg);
        }
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
            if (u.object.get("cache_creation_input_tokens")) |v| {
                if (v == .integer) usage.cache_write = v.integer;
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
                                if (u.object.get("cache_creation_input_tokens")) |v| {
                                    if (v == .integer) usage.cache_write = v.integer;
                                }
                                if (u.object.get("cache_creation_input_tokens")) |v| {
                                    if (v == .integer) usage.cache_write = v.integer;
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

    /// THIS request's usage, and this request's error text.
    ///
    /// Both used to be module globals (`last_usage`, `last_error_buf`). That is
    /// correct for one request at a time and wrong the moment two run at once,
    /// which is what a parallel subagent is: two requests interleaving into one
    /// `Usage` make `/cache` a work of fiction, and two failures interleaving into
    /// one buffer make each report the OTHER one's error.
    ///
    /// `mirror_globals` says whether this request is ALSO the main turn, which is
    /// the only one whose numbers anybody reads.
    usage: Usage = .{},
    err: ErrBuf = .{},
    retry_after: ?u16 = null,
    /// True for the turn the user is watching: it publishes to the module globals
    /// and clears the cancel flag on entry. A subagent does neither (see
    /// `streamRaw`).
    mirror_globals: bool = true,

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
                if (u.prompt > 0) self.usage.prompt = u.prompt;
                if (u.cached > 0) self.usage.cached = u.cached;
                if (u.completion > 0) self.usage.completion = u.completion;
                if (u.cache_write > 0) self.usage.cache_write = u.cache_write;
                if (self.mirror_globals) last_usage = self.usage;
                if (u.cache_write > 0) last_usage.cache_write = u.cache_write;
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
    /// They are all emitted, INCLUDING the ones whose arguments are not valid JSON:
    /// a dropped call is invisible to the model and unfixable from its side.
    fn flushPendingTools(self: *StreamCtx) void {
        for (self.parts.items) |*p| {
            if (p.emitted) continue;
            if (p.id.items.len == 0 or p.name.items.len == 0) continue;
            if (p.args.items.len == 0) {
                // A tool without arguments is legal: treat it as an empty object.
                p.args.appendSlice(self.gpa, "{}") catch continue;
            }
            // EMITTED EVEN IF THE ARGSUMENTS ARE NOT VALID JSON.
            //
            // Its own doc said "the rest are dropped", and that is what happened:
            // a stream cut mid-arguments produced no tool call at all, so the turn
            // ended as if the model had only sent prose. The model got no result,
            // no error and no history line, and its next move was to guess again
            // from nothing.
            //
            // Emitting it hands the failure to the executor, which reports it with
            // `describeError`: the model is told the arguments did not parse AND
            // what it actually sent, which is the one thing it can act on.
            p.emitted = true;
            if (self.user.onToolCall) |f| {
                f(self.user.userdata, p.id.items, p.name.items, p.args.items);
            }
        }
    }
};

pub const StreamResult = struct {
    ctx: *StreamCtx,
    /// True if the request was cut short with ESC (there is partial text).
    partial: bool = false,
};

/// Stream with tool_call accumulation. The caller does `result.ctx.destroy()`.
/// `mirror_globals` is TRUE for the turn the user is watching and FALSE for a
/// subagent: see the `StreamCtx.mirror_globals` doc. It is a parameter and not a
/// global because a subagent running in parallel with the main turn is exactly
/// the case where the globals are wrong.
pub fn streamChatCtx(
    gpa: std.mem.Allocator,
    http: *http_client.Http,
    url: []const u8,
    bearer: ?[]const u8,
    body: []u8,
    user_cb: Callbacks,
    kind: ProviderKind,
    mirror_globals: bool,
    extra_headers: []const http_client.Http.ExtraHeader,
) !StreamResult {
    const ctx = try gpa.create(StreamCtx);
    ctx.* = .{ .gpa = gpa, .user = user_cb, .kind = kind, .mirror_globals = mirror_globals };
    // CAREFUL: the error path must call `destroy` (NOT `deinit`): the ctx may
    // already have `parts` (accumulated tool calls) and `line_buf` allocated.
    // `destroy` is the one that frees them; a plain `gpa.destroy(ctx)` without
    // it leaked both on every 429/5xx.
    errdefer ctx.destroy();
    try streamRaw(gpa, http, url, bearer, body, ctx, extra_headers);
    return .{ .ctx = ctx, .partial = ctx.partial };
}

fn streamRaw(
    gpa: std.mem.Allocator,
    http: *http_client.Http,
    url: []const u8,
    bearer: ?[]const u8,
    body: []u8,
    ctx: *StreamCtx,
    extra_headers: []const http_client.Http.ExtraHeader,
) !void {
    _ = gpa; // the parser lives in the ctx (line_buf)
    // Fresh per request: do not carry over fields from the previous turn.
    ctx.usage = .{};
    ctx.err = .{};
    ctx.retry_after = null;
    // ...and only the MAIN turn publishes that to the module globals. Two things
    // here used to be global and are a parallel-subagent hazard:
    //
    //  - `last_usage`: two requests interleaving into one Usage make `/cache` a
    //    work of fiction.
    //  - `clearCancel()`: a subagent starting would CLEAR the flag the user set
    //    with ESC, so the turn the user was watching would carry on and the
    //    subagent would never see the cancel. ESC stays global (it is the user's
    //    signal and everybody obeys it); only the clearing is per-turn.
    if (ctx.mirror_globals) {
        last_usage = .{};
        clearCancel();
    }

    const Hdr = http_client.Http.ExtraHeader;
    // Capacity: 2 for Anthropic (x-api-key, anthropic-version) + extra_headers
    var hdrs_buf: [8]Hdr = undefined;
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
    // Append any extra headers (e.g., OpenRouter's HTTP-Referer, X-OpenRouter-Title)
    for (extra_headers) |h| {
        if (n >= hdrs_buf.len) break;
        hdrs_buf[n] = h;
        n += 1;
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
        if (res.retry_after) |ra| {
            ctx.retry_after = ra;
            if (ctx.mirror_globals) retry_after_secs = ra;
        }
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
        ctx.err.len = 0;
        setServerMessageInto(&ctx.err, ctx.raw[0..ctx.raw_len]);
        if (ctx.mirror_globals) main_err = ctx.err;
        if (ctx.err.len == 0) {
            const fb = std.fmt.bufPrint(&ctx.err.buf, "HTTP {d}", .{res.status}) catch return err;
            ctx.err.len = fb.len;
            if (ctx.mirror_globals) main_err = ctx.err;
        }
        return err;
    }
    if (dbg_err()) std.debug.print("[DBG] 200 raw={s}\n", .{ctx.raw[0..@min(ctx.raw_len, 240)]});
    ctx.retry_after = res.retry_after;
    if (ctx.mirror_globals) retry_after_secs = ctx.retry_after;
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
/// in `pending` unpainted. It is the same problem `lib/sleep.nap` solves and
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
        sleep.nap(chunk);
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
    mirror_globals: bool,
    extra_headers: []const http_client.Http.ExtraHeader,
) !void {
    const ctx = try gpa.create(StreamCtx);
    ctx.* = .{ .gpa = gpa, .user = cb, .kind = kind, .mirror_globals = mirror_globals };
    defer ctx.destroy(); // frees parts and destroys the struct
    try streamRaw(gpa, http, url, bearer, body, ctx, extra_headers);
}

/// `streamChat`, but the server's own error text comes back in a buffer the
/// CALLER owns instead of dying with the ctx.
///
/// The subagent's model fallback needs it: `router.disqualifies` reads the body
/// because OpenRouter answers a bad model id with HTTP 400 and the status alone
/// does not say whether the MODEL or the REQUEST was rejected. The main turn
/// reads the same text from `lastErrorBody()` — it publishes to the globals — and
/// a subagent must not publish: three run in parallel and each failure would
/// overwrite the others' reason, which is the exact hazard `mirror_globals`
/// exists for. So the reason travels out in a caller-owned `ErrBuf`, a value
/// copy of `ctx.err` made while the ctx is still alive.
pub fn streamChatDetail(
    gpa: std.mem.Allocator,
    http: *http_client.Http,
    url: []const u8,
    bearer: ?[]const u8,
    body: []u8,
    cb: Callbacks,
    kind: ProviderKind,
    mirror_globals: bool,
    err_out: *ErrBuf,
    extra_headers: []const http_client.Http.ExtraHeader,
) !void {
    const ctx = try gpa.create(StreamCtx);
    ctx.* = .{ .gpa = gpa, .user = cb, .kind = kind, .mirror_globals = mirror_globals };
    defer ctx.destroy();
    streamRaw(gpa, http, url, bearer, body, ctx, extra_headers) catch |err| {
        err_out.* = ctx.err; // ErrBuf is a fixed-size struct: nothing to free here
        return err;
    };
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

    // TOOLS BEFORE MESSAGES, and the order is load-bearing.
    //
    // OpenAI's prompt cache is keyed on the LITERAL PREFIX of the request body,
    // and the prefix stops being useful at the first byte that changes. The
    // tools block is ~16 KB of schema that never changes; the messages array
    // changes with every turn. With tools AFTER messages (where it was), the
    // cache prefix could only ever reach the system message: the tools were past
    // the conversation, so they fell outside the cached region on EVERY request.
    // Putting them first makes the static part of the request the beginning of
    // the request, which is the only part the cache can ever see.
    // Closes the model string, which `jsonEscape` left open.
    try w.writeAll("\"");
    if (tools_json.len > 0) {
        try w.writeAll(",\"tools\":");
        try w.writeAll(tools_json);
    }
    try w.writeAll(",\"messages\":[");
    for (messages, 0..) |m, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"role\":\"");
        try w.writeAll(m.role);
        try w.writeAll("\",");
        if (std.mem.eql(u8, m.role, "tool")) {
            try w.writeAll("\"tool_call_id\":\"");
            try jsonEscape(&w, m.tool_call_id orelse "");
            try w.writeAll("\",\"content\":\"");
            try jsonEscape(&w, m.content);
            try w.writeAll("\"");
        } else if (m.isMultimodal()) {
            // The ONE place the content shape changes: an array of blocks, with the
            // text first and the images after. Everything else in this file writes
            // a quoted string, so a message that happens to have an image on it is
            // the single place where a missing brace would be invisible in review.
            try w.writeAll("\"content\":[{\"type\":\"text\",\"text\":\"");
            try jsonEscape(&w, m.content);
            try w.writeAll("\"}");
            for (m.images) |img| {
                try w.writeAll(",{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
                try w.writeAll(img.mime);
                try w.writeAll(";base64,");
                try w.writeAll(img.data_b64);
                try w.writeAll("\"}}");
            }
            try w.writeAll("]");
        } else {
            try w.writeAll("\"content\":\"");
            try jsonEscape(&w, m.content);
            try w.writeAll("\"");
        }
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

    // (tools went out BEFORE messages, on purpose: see the top of this function.
    // Keeping them here as well would send the schema twice.)
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
///    (prompt caching as other harnesses do it: the stable prefix —tools+system+
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
                // Two breakpoints here, not one, and the second one is the
                // ROLLING one. With a single breakpoint on the last message, the
                // prefix from `system` to the end has to be re-written on every
                // turn, because it changed: the cache is read at the breakpoints,
                // not continuously. Anchoring one a message earlier leaves the
                // older half of the history sitting at a breakpoint that the next
                // turn still hits, so the provider READS it and only writes the
                // newest segment.
                if (i + 1 >= messages.len - 1) try w.writeAll(",\"cache_control\":{\"type\":\"ephemeral\"}");
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
                        // The rolling pair again (see the tool_result branch):
                        // the last tool_use of the last message, and of the one
                        // before it.
                        if (ti == pv.array.items.len - 1 and i + 1 >= messages.len - 1) {
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
        } else if (i + 1 >= messages.len - 1) {
            // Last message (and the one before it): block form, to anchor the two
            // rolling cache breakpoints.
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
test "scanSse joins deltas and ends on [DONE]" {
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

test "a fragmented tool_call accumulates and is emitted once" {
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

test "detects a server error" {
    const ctx = try std.testing.allocator.create(StreamCtx);
    ctx.* = .{ .gpa = std.testing.allocator, .user = .{} };
    defer ctx.destroy();
    try std.testing.expectError(
        error.ServerError,
        scanSse(std.testing.allocator, "data: {\"error\":{\"type\":\"x\",\"message\":\"no\"}}\n\n", ctx),
    );
    try std.testing.expectEqualStrings("no", lastErrorBody());
}

test "buildBody escapes JSON and sets max_tokens" {
    var buf: [512]u8 = undefined;
    const body = try buildBody(&buf, "m1", "linea\ncon \"quotes\"", .medium);
    try std.testing.expectEqualStrings(
        "{\"model\":\"m1\",\"messages\":[{\"role\":\"user\",\"content\":\"linea\\ncon \\\"quotes\\\"\"}],\"stream\":true,\"stream_options\":{\"include_usage\":true},\"max_tokens\":32768}",
        body,
    );
}

test "buildBodyMessages with a tool result and tools" {
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

test "scanSse parses Anthropic events (delta, tool_use and usage)" {
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

test "buildBodyAnthropic converts tool_calls/results and anchors cache_control" {
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
    // The ceiling is `.low`'s (32768), not its thinking budget (4096): they are
    // two different numbers, and confusing them was half of bug 3.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":32768") != null);
    // The role "tool" does not exist in Anthropic: they go as tool_result in user.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"tool\"") == null);
    // 4 breakpoints, which is Anthropic's ceiling: the last tool, the system
    // block, and the ROLLING pair on the last two messages.
    //
    // The rolling one is the whole point. With a single breakpoint at the end,
    // every turn changes the region between the system breakpoint and the end, so
    // the whole history is re-WRITTEN each turn. With one a message earlier, the
    // older half sits at a breakpoint the next request still reaches: it is read,
    // and only the newest segment is written.
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, body, "\"cache_control\":{\"type\":\"ephemeral\"}"));
}

test "feed: an event split mid-line is delivered whole" {
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

test "feed: a payload split mid-UTF-8 is not corrupted" {
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

test "feed: a tool call cut mid-args is emitted at finish" {
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

test "feed: a tool without arguments is treated as an empty object" {
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

test "buildBodyOpenAI: o-series uses max_completion_tokens + reasoning_effort" {
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

    // And on a model that DOES take it, xhigh goes out for real. Before there
    // was no way to get here. CAREFUL: plain `gpt-5.1` does NOT take it (xhigh
    // is codex-max only), and sending it would be a 400: the first version of
    // this table said the opposite and the test took it as good.
    const xh2 = try buildBodyMessages(&buf, "gpt-5.1-codex-max", &msgs, .xhigh, "", .openai);
    try std.testing.expect(std.mem.indexOf(u8, xh2, "\"reasoning_effort\":\"xhigh\"") != null);

    // And plain `gpt-5.1` degrades xhigh to high, which is what the docs say.
    const xh3 = try buildBodyMessages(&buf, "gpt-5.1", &msgs, .xhigh, "", .openai);
    try std.testing.expect(std.mem.indexOf(u8, xh3, "\"reasoning_effort\":\"high\"") != null);
}

test "max is its own level, and no model is told a word it does not know" {
    // Z.AI's top rung is called `max` (and is its default); OpenAI's is `xhigh`.
    // They are the same rung, and the WORD is the contract: a model that only
    // knows `max` 400s on `xhigh` and the other way around. `max` exists as a
    // level so a family that speaks it can ask for it; until one does, the wish
    // lands on the top rung of the model that is running.
    try std.testing.expectEqual(Effort.max, Effort.parse("max").?);
    try std.testing.expectEqual(Effort.xhigh, Effort.parse("xhigh").?);

    var buf: [64 * 1024]u8 = undefined;
    const msgs = [_]ChatMessage{.{ .role = "user", .content = "hi" }};

    // codex-max is the one model with `xhigh`; it has no `max`.
    const cm = try buildBodyMessages(&buf, "gpt-5.1-codex-max", &msgs, .max, "", .openai);
    try std.testing.expect(std.mem.indexOf(u8, cm, "\"reasoning_effort\":\"xhigh\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cm, "\"reasoning_effort\":\"max\"") == null);

    // Every other ladder degrades it to `high`.
    const p51 = try buildBodyMessages(&buf, "gpt-5.1", &msgs, .max, "", .openai);
    try std.testing.expect(std.mem.indexOf(u8, p51, "\"reasoning_effort\":\"high\"") != null);

    const basic = try buildBodyMessages(&buf, "o3-mini", &msgs, .max, "", .openai);
    try std.testing.expect(std.mem.indexOf(u8, basic, "\"reasoning_effort\":\"high\"") != null);

    // A model with no knob at all still gets no field.
    const none = try buildBodyMessages(&buf, "kimi-k2.6", &msgs, .max, "", .openai);
    try std.testing.expect(std.mem.indexOf(u8, none, "reasoning_effort") == null);

    // The ceiling `max` asks for is the top one, so a turn that thinks this
    // hard is not cut off by a 32k limit.
    try std.testing.expectEqual(@as(u32, 65536), Effort.max.outputCeiling());
    try std.testing.expectEqual(Effort.xhigh, Effort.max.degrade());
    try std.testing.expectEqual(Effort.xhigh, clampEffort("gpt-5.1-codex-max", .max));
}

test "buildBodyOpenAI: a normal model keeps max_tokens" {
    var buf: [64 * 1024]u8 = undefined;
    const msgs = [_]ChatMessage{.{ .role = "user", .content = "hi" }};

    const body = try buildBodyMessages(&buf, "kimi-k2.6", &msgs, .low, "", .openai);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":32768") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "max_completion_tokens") == null);
    // A model WITHOUT the knob does not get the field: sending it is a 400.
    try std.testing.expect(std.mem.indexOf(u8, body, "reasoning_effort") == null);
}

test "buildBodyOpenAI: a model with more levels gets them (Gemini, gpt-5.1)" {
    // Bug 3: "some models support more" was true and there was no way to profit
    // from it. Now the field goes out whenever the model has it, and with the
    // level THAT model understands.
    var buf: [64 * 1024]u8 = undefined;
    const msgs = [_]ChatMessage{.{ .role = "user", .content = "hi" }};

    // Gemini 3 calls its first rung `minimal` and has no `none`: asking for "no
    // thinking" arrives as `minimal`, which is the closest thing that exists.
    const g_min = try buildBodyMessages(&buf, "gemini-3.5-flash", &msgs, .minimal, "", .openai);
    try std.testing.expect(std.mem.indexOf(u8, g_min, "\"reasoning_effort\":\"minimal\"") != null);

    const g_none = try buildBodyMessages(&buf, "gemini-3.5-flash", &msgs, .none, "", .openai);
    try std.testing.expect(std.mem.indexOf(u8, g_none, "\"reasoning_effort\":\"minimal\"") != null);

    // And xhigh on Gemini degrades to high (its ceiling), not to something invented.
    const g_x = try buildBodyMessages(&buf, "gemini-3.5-flash", &msgs, .xhigh, "", .openai);
    try std.testing.expect(std.mem.indexOf(u8, g_x, "\"reasoning_effort\":\"high\"") != null);

    // Gemini 2.5 does NOT have `minimal` (docs: low/medium/high), so asking for
    // it degrades to `low` instead of sending a level that does not exist.
    const g25 = try buildBodyMessages(&buf, "gemini-2.5-pro", &msgs, .minimal, "", .openai);
    try std.testing.expect(std.mem.indexOf(u8, g25, "\"reasoning_effort\":\"low\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, g25, "minimal") == null);

    // A real `none`, on a model that has it. Before, the enum did not even have
    // that level.
    const o_none = try buildBodyMessages(&buf, "gpt-5.1", &msgs, .none, "", .openai);
    try std.testing.expect(std.mem.indexOf(u8, o_none, "\"reasoning_effort\":\"none\"") != null);
}

test "effortSupport: each model ladder comes from the DOCS, not from intuition" {
    // This table was corrected after checking it against OpenAI's effort matrix
    // and Google's `thinking_level` table. All three failures were invented:
    //
    //   - `xhigh` does NOT exist in `gpt-5.1` (codex-max only). Sending it = 400.
    //   - `minimal` does NOT exist in GPT-5s before 5.1, nor in gemini-2.5.
    //   - gemini-2.5 has no `minimal` and gemini-3-pro-preview has no `medium`.
    try std.testing.expectEqual(EffortSupport.none, effortSupport("kimi-k2.6"));
    try std.testing.expectEqual(EffortSupport.codex_max, effortSupport("gpt-5.1-codex-max"));
    // `codex-max` has to win over `gpt-5.1` in the order, not the other way round.
    try std.testing.expectEqual(EffortSupport.gpt51, effortSupport("gpt-5.1"));
    // A GPT-5 older than 5.1: the basic ladder, with no `minimal` nor `none`.
    try std.testing.expectEqual(EffortSupport.basic, effortSupport("gpt-5"));
    try std.testing.expectEqual(EffortSupport.basic, effortSupport("o3-mini"));
    try std.testing.expectEqual(EffortSupport.basic, effortSupport("o1"));
    // Gemini 2.5 is `basic` (docs: low/medium/high), and the 3.5+ go up to minimal.
    try std.testing.expectEqual(EffortSupport.basic, effortSupport("gemini-2.5-pro"));
    try std.testing.expectEqual(EffortSupport.gemini3_minimal, effortSupport("gemini-3.5-flash"));

    // The ids arrive with a provider prefix (`openai/gpt-5.1`), so the lookup is
    // by SUBSTRING and not by prefix.
    try std.testing.expectEqual(EffortSupport.gpt51, effortSupport("openai/gpt-5.1"));
    try std.testing.expectEqual(EffortSupport.gemini3_minimal, effortSupport("google/gemini-3.6-flash"));

    // A model with no knob gets NO level: `effortFor` says null and the body is
    // left without the field.
    try std.testing.expectEqual(@as(?Effort, null), effortFor("kimi-k2.6", .high));

    // And the picker's ceiling is the model's, not ours.
    try std.testing.expectEqual(Effort.xhigh, maxEffortFor("gpt-5.1-codex-max"));
    try std.testing.expectEqual(Effort.high, maxEffortFor("gpt-5.1"));
    try std.testing.expectEqual(Effort.high, maxEffortFor("gpt-5"));
    try std.testing.expectEqual(Effort.high, maxEffortFor("gemini-2.5-pro"));
}

test "effortFor: NEVER asks for a level the model does not document" {
    // This is the invariant that really matters, and it is the one the first
    // version broke on three models. It walks the WHOLE model x level
    // combination and demands that what comes out is a level that model accepts.
    //
    // The "accepted" list is hand-written from the docs. It is code, not a truth
    // derived from the table above: if the two were derived from each other, the
    // test would pass with both wrong (which is exactly how the three failures
    // slipped in).
    const Cases = struct {
        model: []const u8,
        /// The levels the DOCS say it accepts.
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
                // No knob: sending nothing is fine. But if the model was in the
                // table WITH a ladder, it cannot have disappeared.
                try std.testing.expectEqual(EffortSupport.none, effortSupport(c.model));
                continue;
            }
            var accepted = false;
            for (c.ok) |k| {
                if (k == got.?) accepted = true;
            }
            if (!accepted) {
                std.debug.print(
                    "\\n  {s}: asked for {s} and got {s}, which is not in its docs\\n",
                    .{ c.model, want.label(), got.?.label() },
                );
            }
            try std.testing.expect(accepted);
        }
    }
}

test "effortLevels (the picker) and effortFor (the wire) do not contradict" {
    // A level the picker offers and `effortFor` cannot represent is a 400
    // waiting for the user to press it; one that degrades silently is a button
    // that does nothing. Both are signs of a broken picker.
    const models = [_][]const u8{
        "kimi-k2.6",         "gpt-5",          "o3-mini",          "gpt-5.1",
        "gpt-5.1-codex-max", "gemini-2.5-pro", "gemini-3.5-flash",
    };
    for (models) |m| {
        for (effortLevels(m)) |lv| {
            const got = effortFor(m, lv);
            if (got == null) continue;
            // What is offered has to go out EXACTLY, not as a degraded version.
            try std.testing.expectEqual(lv, got.?);
        }
    }
}

test "automatic effort: the default comes from the model ladder, not a fixed `medium`" {
    // The default was `.medium` for EVERYTHING, and `medium` is not on every
    // model's ladder. The default is the MIDDLE rung of the ladder that model
    // has, which is the only thing that can be said without knowing every model
    // from memory.
    const models = [_][]const u8{
        "kimi-k2.6",         "gpt-5",          "gpt-5.1",
        "gpt-5.1-codex-max", "gemini-2.5-pro", "gemini-3.5-flash",
    };
    for (models) |m| {
        const d = defaultEffort(m);
        // It has to be a level the model really ACCEPTS...
        const lv = effortLevels(m);
        var on_ladder = false;
        for (lv) |k| {
            if (k == d) on_ladder = true;
        }
        try std.testing.expect(on_ladder);
        // ...and it has to be representable: not crashing is not enough.
        _ = effortFor(m, d);
    }

    // The index is what decides (the MIDDLE rung), and it is pinned case by case
    // because the enum is ORDERED but the ladders do not have to be the same
    // length:
    //   3 levels (low/medium/high)       -> index 1 -> medium
    //   5 levels (none..high)            -> index 2 -> low
    //   6 levels (none..xhigh)           -> index 3 -> medium
    //   2 levels (low/high)              -> index 1 -> high   <-- no `medium`
    //   none..high (5)         -> index 2 -> low
    //   none..xhigh (6)        -> index 3 -> medium
    try std.testing.expectEqual(Effort.medium, defaultEffort("gemini-2.5-pro"));
    try std.testing.expectEqual(Effort.medium, defaultEffort("gpt-5"));
    try std.testing.expectEqual(Effort.low, defaultEffort("gpt-5.1"));
    try std.testing.expectEqual(Effort.medium, defaultEffort("gpt-5.1-codex-max"));

    // And the case that really proves the point: a model WITHOUT `medium`.
    // If the default were the literal `.medium`, this would receive a level that
    // does not exist, and the first turn of a new session (where the user never
    // touched `/effort`) would eat a 400.
    try std.testing.expectEqual(Effort.high, defaultEffort("gemini-3-pro-preview"));
    try std.testing.expectEqual(@as(?Effort, .low), effortFor("gemini-3-pro-preview", .medium));
}

test "clampEffort: changing model lowers the step that no longer exists" {
    // The `xhigh` chosen on a codex-max has to stop existing when switching to a
    // gemini-2.5, not sit there degrading silently (the status bar would say
    // `xhigh` and the wire would carry `high`, which are two different things
    // with no hint that they are).
    try std.testing.expectEqual(Effort.high, clampEffort("gemini-2.5-pro", .xhigh));
    try std.testing.expectEqual(Effort.xhigh, clampEffort("gpt-5.1-codex-max", .xhigh));
    // And something the model DOES have is left alone.
    try std.testing.expectEqual(Effort.low, clampEffort("gpt-5", .low));
    try std.testing.expectEqual(Effort.none, clampEffort("gpt-5.1", .none));

    // And the clamp is IDEMPOTENT and never RAISES a level (going above the
    // ceiling is the 400).
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

test "effectiveEffort: never returns null (a model with no knob uses its default)" {
    // Why this function exists: `effortFor` returns `?Effort` and `null` means
    // "this model has no knob", which is NOT an error but does force every caller
    // to remember it. It is collapsed here, so the request path does not have to
    // know anything.
    // No knob: falls back to the default, which is the middle of `low/medium/high`.
    try std.testing.expectEqual(Effort.medium, effectiveEffort("kimi-k2.6", .high));
    try std.testing.expectEqual(Effort.medium, effectiveEffort("gpt-5", .medium));
    try std.testing.expectEqual(Effort.high, effectiveEffort("gpt-5.1", .xhigh));
    try std.testing.expectEqual(Effort.xhigh, effectiveEffort("gpt-5.1-codex-max", .xhigh));
    // And what comes out has to be something the model accepts.
    const m = "gemini-2.5-pro";
    const e = effectiveEffort(m, .xhigh);
    var ok = false;
    for (effortLevels(m)) |k| {
        if (k == e) ok = true;
    }
    try std.testing.expect(ok);
}

test "buildBodyAnthropic: thinking with budget lower than max_tokens" {
    var buf: [64 * 1024]u8 = undefined;
    const msgs = [_]ChatMessage{.{ .role = "user", .content = "hi" }};

    // effort=high → ceiling 65536 > budget 16384: thinking enabled.
    const high = try buildBodyMessages(&buf, "claude-sonnet-4-5", &msgs, .high, "", .anthropic);
    try std.testing.expect(std.mem.indexOf(u8, high, "\"max_tokens\":65536") != null);
    try std.testing.expect(std.mem.indexOf(u8, high, "\"budget_tokens\":16384") != null);

    // effort=medium → ceiling 32768 > budget 8192: thinking enabled too.
    const med = try buildBodyMessages(&buf, "claude-sonnet-4-5", &msgs, .medium, "", .anthropic);
    try std.testing.expect(std.mem.indexOf(u8, med, "\"budget_tokens\":8192") != null);

    // effort=low → ceiling 32768 > budget 4096. Before, `low` was a ceiling of
    // 4096 with a budget of 2048: twice less room for the answer than for the
    // thinking, and an answer with tools got cut in half.
    const low = try buildBodyMessages(&buf, "claude-sonnet-4-5", &msgs, .low, "", .anthropic);
    try std.testing.expect(std.mem.indexOf(u8, low, "\"budget_tokens\":4096") != null);

    // effort=none → no thinking at all (budget 0 = the block is not sent).
    const none = try buildBodyMessages(&buf, "claude-sonnet-4-5", &msgs, .none, "", .anthropic);
    try std.testing.expect(std.mem.indexOf(u8, none, "\"thinking\"") == null);

    // And xhigh really raises the budget (24576), which before was squashed to 16384.
    const xh = try buildBodyMessages(&buf, "claude-sonnet-4-5", &msgs, .xhigh, "", .anthropic);
    try std.testing.expect(std.mem.indexOf(u8, xh, "\"budget_tokens\":24576") != null);

    // The thinking budget can never equal max_tokens: Anthropic
    // requires budget_tokens < max_tokens.
    try std.testing.expect(!hasBadThinkingBudget(high));
    try std.testing.expect(!hasBadThinkingBudget(med));
    try std.testing.expect(!hasBadThinkingBudget(low));
}

test "familyForModel detects reasoning only in o-series/gpt-5" {
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

test "feed: an SSE line bigger than any buffer is reassembled" {
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

test "StreamCtx.destroy does not leak with parts and line_buf populated" {
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

test "setServerMessage: pulls the message out of the error JSON" {
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

test "setServerMessage: survives garbage without overflowing" {
    // Without "message" (odd JSON), empty, unopened quote, and a huge
    // string: under no circumstances may it overrun the buffer or leave junk.
    setServerMessage("");
    try std.testing.expectEqual(@as(usize, 0), lastErrorLen());
    setServerMessage("<html>502 Bad Gateway</html>");
    try std.testing.expectEqual(@as(usize, 0), lastErrorLen());
    setServerMessage("{\"message\": 42}");
    try std.testing.expectEqual(@as(usize, 0), lastErrorLen());

    const huge = "{\"message\":\"" ++ "x" ** 900 ++ "\"}";
    setServerMessage(huge);
    try std.testing.expect(lastErrorLen() > 0 and lastErrorLen() < lastErrorCap());
}

test "setServerMessage: unescapes quote and backslash" {
    setServerMessage("{\"message\":\"say \\\"hi\\\" \\\\o/\"}");
    try std.testing.expectEqualStrings("say \"hi\" \\o/", lastErrorBody());
}

test "noteRaw: keeps only the first bytes, without overflowing" {
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

test "402 and 403 have their own error (they are not retried)" {
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

test "buildBodyOpenAI: the tools schema comes BEFORE the messages" {
    // It is the whole cache. OpenAI keys the prompt cache on the literal prefix
    // of the body, so with tools after the messages array the ~16 KB of static
    // schema sat past the part that changes every turn, and was therefore never
    // inside the cached region. First means "cached", and the order of a JSON
    // object is the only thing that decides it.
    var buf: [64 * 1024]u8 = undefined;
    const body = try buildBodyMessages(&buf, "m", &[_]ChatMessage{
        .{ .role = "system", .content = "eres zode" },
        .{ .role = "user", .content = "hola" },
    }, .medium, "[{\"type\":\"function\"}]", .openai);
    const tools_at = std.mem.indexOf(u8, body, "\"tools\"") orelse return error.TestUnexpectedResult;
    const msgs_at = std.mem.indexOf(u8, body, "\"messages\"") orelse return error.TestUnexpectedResult;
    try std.testing.expect(tools_at < msgs_at);
    // And it is sent exactly once.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "\"tools\""));
    // The body is still valid JSON with both halves in it.
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a.allocator(), body, .{});
    try std.testing.expect(v.object.get("tools") != null);
    try std.testing.expect(v.object.get("messages") != null);
}

test "an image turns content into an ARRAY of blocks, and only for a user message" {
    // The one place the content shape is not a quoted string, which is exactly why
    // it needs a test: a missing brace here is invisible in review and the whole
    // request 400s.
    const with_img = [_]ChatMessage{
        .{ .role = "user", .content = "look at this" },
    };
    var msgs = with_img;
    msgs[0].images = &[_]Image{
        .{ .mime = "image/png", .data_b64 = "AAAA" },
        .{ .mime = "image/jpeg", .data_b64 = "BBBB" },
    };

    var buf: [8192]u8 = undefined;
    const body = try buildBodyOpenAI(buf[0..], "m", &msgs, .medium, "");
    try std.testing.expect(std.mem.indexOf(u8, body,
        \\{"role":"user","content":[{"type":"text","text":"look at this"},{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}},{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,BBBB"}}]}
    ) != null);
}

test "a tool message NEVER becomes multimodal, whatever images it is given" {
    // OpenAI's shape for a tool result is a string. Sending an array there is a
    // 400, and it would be a 400 the model cannot explain — which is why the
    // harness attaches images to a user message instead.
    var msgs = [_]ChatMessage{
        .{ .role = "tool", .content = "an image", .tool_call_id = "c1" },
    };
    msgs[0].images = &[_]Image{.{ .mime = "image/png", .data_b64 = "AAAA" }};

    var buf: [8192]u8 = undefined;
    const body = try buildBodyOpenAI(buf[0..], "m", &msgs, .medium, "");
    try std.testing.expect(std.mem.indexOf(u8, body, "content") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "an image") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "image_url") == null);
}

test "a user message with no images is byte-for-byte what it was" {
    // The array shape must not leak into ordinary messages: it is a different
    // content type and a provider is within its rights to treat it differently.
    const msgs = [_]ChatMessage{
        .{ .role = "user", .content = "plain text" },
    };
    var buf: [8192]u8 = undefined;
    const body = try buildBodyOpenAI(buf[0..], "m", &msgs, .medium, "");
    try std.testing.expect(std.mem.indexOf(u8, body, "content") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "plain text") != null);
    // The array shape did not leak in.
    try std.testing.expect(std.mem.indexOf(u8, body, "[{\"type\"") == null);
}
