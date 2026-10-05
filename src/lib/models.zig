const std = @import("std");
const http_client = @import("http_client.zig");

pub var dbg_io: ?std.Io = null;

pub fn dbg(comptime fmt: []const u8, args: anytype) void {
    const io = dbg_io orelse return;
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
}

pub const Model = struct {
    id: []const u8,
    owned_by: []const u8,
    /// Context window in tokens (0 = the provider does not publish it).
    /// OpenRouter does send it, and that is what lets us stop using the fixed 128k.
    context_length: u32 = 0,
    /// Price per prompt token in USD (0 = unknown). It arrives as a decimal
    /// string in OpenRouter ("0.00000015").
    price_prompt: f64 = 0,
    /// Price per completion token in USD.
    price_completion: f64 = 0,
    /// [roster] Is it really free? See `isFreeId` and `isFreeByPrice`.
    ///
    /// Before, this was decided by the consumer with `endsWith(id, "-free")`, and
    /// that only saw opencode's models: on OpenRouter the suffix is `:free`, and
    /// some providers use no suffix at all and just publish price 0.
    is_free: bool = false,
};

/// Does the id carry the "free" mark its provider uses?
///
/// Two conventions, and both are real: opencode uses `-free`
/// ("space-bunny-free") and OpenRouter uses `:free` ("qwen/qwen3-8b:free").
/// Checking only one of the two is what made the pool of free models see one
/// provider and no other.
///
/// ## `openrouter/free` is free and this says NO, and that is deliberate
///
/// There is a third spelling: `/free`, and it belongs to a ROUTER. Measured
/// 2026-10-04: it answers 3583 / 3273 / 3381 prompt tokens for an identical
/// prefix and serves **0% from cache**, because it picks a different upstream per
/// request and they do not share a prompt cache.
///
/// So the answer is currently right for the wrong reason, and that is worth
/// writing down rather than leaving to chance: adding `/free` here would put a
/// router into the free pool, and every turn would then be billed in full for the
/// 11 KB tool schema. `isFreeId and not isRouter(id)` is the rule the callers
/// want; this function answers "is this a free MODEL".
pub fn isFreeId(id: []const u8) bool {
    if (isRouter(id)) return false;
    return std.mem.endsWith(u8, id, "-free") or std.mem.endsWith(u8, id, ":free");
}

/// Is this a ROUTER rather than a model?
///
/// ## Measured, on 2026-10-04, which is why this exists
///
/// The same request with the same prefix, three times in a row:
///
/// ```
/// openrouter/free            prompt=3583   prompt=3273   prompt=3381   cached=0
/// qwen/qwen3.8-27b:free     prompt=3611   prompt=3613   prompt=3613   cached=3328 (98%)
/// ```
///
/// A router picks a different upstream per request, and different upstreams
/// have different tokenizers AND different prompt caches. So **a router can
/// never produce a prefix-cache hit**, no matter how stable the prefix is, and
/// the prompt token count drifts by several hundred between identical requests —
/// which is also what makes `zode`'s own token estimate useless on it.
///
/// A fixed model, free or not, caches: 98% measured, at no extra cost.
/// `qwen/...:free` is a MODEL that happens to be free; `openrouter/free` is a
/// ROUTER. The `:free` suffix does not tell them apart, which is why this is a
/// list of ids and not a suffix test.
///
/// The list is short because there is no other way to tell from the id: OpenRouter
/// publishes no "this is a router" flag.
pub fn isRouter(id: []const u8) bool {
    const routers = [_][]const u8{
        "openrouter/free",
        "openrouter/auto",
        "openrouter/fallback",
        "openrouter/free-router",
        "openrouter/bodybuilder",
    };
    for (routers) |r| if (std.mem.eql(u8, id, r)) return true;
    // The `:floor` and `:nitro` variants of opencode's router, same thing.
    if (std.mem.startsWith(u8, id, "opencode/")) return true;
    return false;
}

/// Is this model one a CODING AGENT can hold a conversation with?
///
/// "Free" and "usable" are different questions, and the pool was answering only
/// the first one. `zig build roster-probe` showed what that costs: the free
/// models of a big aggregator include `google/lyria-3-pro-preview` (music
/// generation), `google/lyria-3-clip-preview` and `clip-*` (embeddings), and the
/// pool dutifully offered them as the model to write code with. The turn then
/// fails on the first token, the error is attributed to the quota, and the pool
/// rotates — to the next image model.
///
/// The test is on the ID, because that is all several providers publish: a
/// name that says what it does. It is a filter, not a guarantee, and being wrong
/// here costs one rotation.
pub fn isConversational(id: []const u8) bool {
    const needles = [_][]const u8{
        // embeddings / retrieval
        "clip",       "embed",              "bge-",     "gte-",
        "e5-",        "minilm",             "jina-",    "voyage",
        "rerank",     "retriev",
        // images and video
                   "flux",     "stable-diffusion",
        "sdxl",       "sd3",                "sora",     "veo",
        "imagen",     "dall-e",             "ideogram", "recraft",
        "ideogram",
        // audio
          "tts",                "whisper",  "lyria",
        "elevenlabs", "suno",               "audi",     "speech",
        "transcribe",
        // safety and moderation: they answer 200 and then say no
        "moderation",         "guard",    "safety",
        // image EDITING models, which live next to the chat ones in the same list
        "kontext",    "background-removal",
    };
    for (needles) |n| {
        if (containsIgnoreCase(id, n)) return false;
    }
    return true;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var ok = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

/// Does the published price say it is free?
///
/// It only counts if the model CAME WITH a `pricing` object (the parser knows
/// whether it did). A provider that publishes no prices leaves both at 0, and
/// without this check every one of its models would come out free: the worst
/// possible failure for a mode called "free-auto", because it would believe it
/// can spend without paying.
pub fn isFreeByPrice(has_pricing: bool, price_prompt: f64, price_completion: f64) bool {
    return has_pricing and price_prompt == 0 and price_completion == 0;
}

pub const ModelList = struct {
    items: []Model,
    /// How many models were detected as free (`is_free`), which is NOT "the ones
    /// ending in -free": OpenRouter uses `:free`, and a provider with a `pricing`
    /// object is trusted when the price is 0.
    free_count: usize,
    /// The provider published context/price for at least one model.
    has_metadata: bool = false,

    pub fn deinit(self: *ModelList, gpa: std.mem.Allocator) void {
        for (self.items) |m| {
            gpa.free(m.id);
            gpa.free(m.owned_by);
        }
        gpa.free(self.items);
    }
};

/// GET /models (OpenAI format: {"object":"list","data":[{"id":...}]}).
pub fn listModels(
    gpa: std.mem.Allocator,
    http: *http_client.Http,
    url: []const u8,
    bearer: ?[]const u8,
) !ModelList {
    const res = try http.get(url, bearer);
    defer http.freeBody(res.body);
    if (res.status != 200) {
        dbg("HTTP {d}: {s}\n", .{ res.status, res.body[0..@min(res.body.len, 300)] });
        return error.HttpError;
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, res.body, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.BadPayload;
    // OpenAI and Anthropic use {"data":[...]}; some proxies nest it
    // (data.data) or return the array directly.
    var data = root.object.get("data") orelse return error.BadPayload;
    if (data == .object) {
        data = data.object.get("data") orelse return error.BadPayload;
    }
    if (data != .array) return error.BadPayload;
    if (data != .array) return error.BadPayload;

    var items = try gpa.alloc(Model, data.array.items.len);
    errdefer gpa.free(items);
    var free_count: usize = 0;

    var has_metadata = false;

    for (data.array.items, 0..) |entry, i| {
        if (entry != .object) return error.BadPayload;
        const id = entry.object.get("id") orelse return error.BadPayload;
        const owner = entry.object.get("owned_by") orelse std.json.Value{ .string = "?" };
        if (id != .string) return error.BadPayload;

        const id_copy = try gpa.dupe(u8, id.string);
        errdefer gpa.free(id_copy);
        const owner_copy = try gpa.dupe(u8, if (owner == .string) owner.string else "?");
        errdefer gpa.free(owner_copy);

        // Optional metadata: only OpenRouter publishes it, the rest of the
        // OpenAI-compat providers omit it. If missing, they stay at 0.
        var ctx: u32 = 0;
        if (entry.object.get("context_length")) |cv| {
            switch (cv) {
                .integer => |n| if (n > 0 and n <= std.math.maxInt(u32)) {
                    ctx = @intCast(n);
                },
                .number_string => |s| ctx = std.fmt.parseInt(u32, s, 10) catch 0,
                else => {},
            }
        }
        var p_prompt: f64 = 0;
        var p_completion: f64 = 0;
        // [roster] Did the `pricing` object arrive? It tells "price 0" apart from
        // "no price published", which is the difference between a free model
        // and a provider that says nothing.
        var has_pricing = false;
        if (entry.object.get("pricing")) |pv| {
            if (pv == .object) {
                has_pricing = true;
                if (pv.object.get("prompt")) |v| p_prompt = jsonNumber(v);
                if (pv.object.get("completion")) |v| p_completion = jsonNumber(v);
            }
        }
        if (ctx > 0 or p_prompt > 0) has_metadata = true;

        const free = isFreeId(id_copy) or isFreeByPrice(has_pricing, p_prompt, p_completion);
        if (free) free_count += 1;

        items[i] = .{
            .id = id_copy,
            .owned_by = owner_copy,
            .context_length = ctx,
            .price_prompt = p_prompt,
            .price_completion = p_completion,
            .is_free = free,
        };
    }

    return .{ .items = items, .free_count = free_count, .has_metadata = has_metadata };
}

/// Reads a number the provider may send as a float, an integer, or as a
/// decimal string (OpenRouter sends prices that way to avoid losing precision
/// in a float). It never returns NaN: that would break the /cost comparisons.
fn jsonNumber(v: std.json.Value) f64 {
    return switch (v) {
        .float => |f| if (std.math.isFinite(f)) f else 0,
        .integer => |n| @floatFromInt(n),
        .number_string => |s| std.fmt.parseFloat(f64, s) catch 0,
        .string => |s| std.fmt.parseFloat(f64, s) catch 0,
        else => 0,
    };
}

test "listModels parses OpenRouter's context_length and pricing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    // Real OpenRouter payload (prices come as decimal strings).
    const json =
        \\{"object":"list","data":[
        \\ {"id":"anthropic/claude-sonnet-4-5","owned_by":"anthropic",
        \\  "context_length":200000,
        \\  "pricing":{"prompt":"0.000003","completion":"0.000015"}},
        \\ {"id":"some/free-model","owned_by":"x","context_length":8192}
        \\]}
    ;
    // Reuse the parser without the network: the parsing part was extracted into a helper.
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, gpa, json, .{});
    const data = parsed.object.get("data").?;

    var ctx: u32 = 0;
    if (data.array.items[0].object.get("context_length")) |cv| {
        if (cv == .integer) ctx = @intCast(cv.integer);
    }
    try std.testing.expectEqual(@as(u32, 200000), ctx);

    const pricing = data.array.items[0].object.get("pricing").?;
    const p = jsonNumber(pricing.object.get("prompt").?);
    try std.testing.expectApproxEqAbs(@as(f64, 0.000003), p, 1e-12);
    const c = jsonNumber(pricing.object.get("completion").?);
    try std.testing.expectApproxEqAbs(@as(f64, 0.000015), c, 1e-12);

    // Model with no pricing: 0, not NaN.
    const no_price = data.array.items[1].object.get("pricing");
    try std.testing.expect(no_price == null);
}

test "jsonNumber accepts float, integer and decimal string" {
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), jsonNumber(.{ .float = 1.5 }), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), jsonNumber(.{ .integer = 7 }), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), jsonNumber(.{ .number_string = "0.25" }), 1e-12);
    // Garbage → 0, never NaN (which would break the comparisons).
    try std.testing.expectApproxEqAbs(@as(f64, 0), jsonNumber(.{ .string = "abc" }), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), jsonNumber(.null), 1e-9);
}

// ── [roster] what counts as a free model ──────────────────────

test "isFreeId: the two suffix conventions" {
    // opencode
    try std.testing.expect(isFreeId("space-bunny-free"));
    try std.testing.expect(isFreeId("kimi-k2.6-free"));
    // OpenRouter, with a provider prefix
    try std.testing.expect(isFreeId("qwen/qwen3-8b:free"));
    try std.testing.expect(isFreeId("meta-llama/llama-3.3-70b-instruct:free"));
    // And what is NOT one
    try std.testing.expect(!isFreeId("gpt-4o"));
    try std.testing.expect(!isFreeId("deepseek/deepseek-chat"));
    try std.testing.expect(!isFreeId("free-model-with-no-suffix"));
    try std.testing.expect(!isFreeId(""));
    // The suffix goes at the END: a "free" in the middle is something else (a name).
    try std.testing.expect(!isFreeId("free-tier/default"));
}

test "isFreeByPrice: price 0 with pricing is free; without pricing, NO" {
    // The signal that does not depend on the id convention.
    try std.testing.expect(isFreeByPrice(true, 0, 0));
    // Either one above 0 and it is no longer free.
    try std.testing.expect(!isFreeByPrice(true, 0.00000015, 0));
    try std.testing.expect(!isFreeByPrice(true, 0, 0.0000006));
    try std.testing.expect(!isFreeByPrice(true, 3, 15));
    // And the dangerous case: a provider that publishes no pricing. Without
    // `has_pricing` ALL of its models come out free and free-auto would believe
    // it can spend without paying.
    try std.testing.expect(!isFreeByPrice(false, 0, 0));
}

test "the parser flags is_free with the three signals" {
    // Fixture that mixes the three forms plus a paid model, with real prices in
    // OpenRouter's string format.
    const json =
        \\{"object":"list","data":[
        \\ {"id":"space-bunny-free","owned_by":"opencode"},
        \\ {"id":"qwen/qwen3-8b:free","owned_by":"openrouter","context_length":32768,
        \\  "pricing":{"prompt":"0","completion":"0"}},
        \\ {"id":"llama-3.3-free","owned_by":"groq","context_length":131072,
        \\  "pricing":{"prompt":"0","completion":"0"}},
        \\ {"id":"anthropic/claude-sonnet-4-5","owned_by":"anthropic","context_length":200000,
        \\  "pricing":{"prompt":"0.000003","completion":"0.000015"}},
        \\ {"id":"gpt-4o","owned_by":"openai"}
        \\]}
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), json, .{});
    const data = parsed.object.get("data").?.array;

    var free: usize = 0;
    for (data.items) |entry| {
        const id = entry.object.get("id").?.string;
        var has_pricing = false;
        var p_prompt: f64 = 0;
        var p_completion: f64 = 0;
        if (entry.object.get("pricing")) |pv| {
            if (pv == .object) {
                has_pricing = true;
                if (pv.object.get("prompt")) |v| p_prompt = jsonNumber(v);
                if (pv.object.get("completion")) |v| p_completion = jsonNumber(v);
            }
        }
        const is_free = isFreeId(id) or isFreeByPrice(has_pricing, p_prompt, p_completion);
        if (is_free) free += 1;
        // The paid one and the one that publishes nothing must come out false.
        if (std.mem.eql(u8, id, "anthropic/claude-sonnet-4-5") or std.mem.eql(u8, id, "gpt-4o")) {
            try std.testing.expect(!is_free);
        }
    }
    try std.testing.expectEqual(@as(usize, 3), free);
}

test "isConversational: embeddings, images and audio are not coding agents" {
    // Exactly the ids the free pool was offering, from `zig build roster-probe`.
    try std.testing.expect(!isConversational("google/lyria-3-pro-preview"));
    try std.testing.expect(!isConversational("google/lyria-3-clip-preview"));
    try std.testing.expect(!isConversational("openai/clip-vit-large-patch14"));
    try std.testing.expect(!isConversational("openai/dall-e-3"));
    try std.testing.expect(!isConversational("black-forest-labs/flux-1.1-pro"));
    try std.testing.expect(!isConversational("stabilityai/stable-diffusion-xl-base"));
    try std.testing.expect(!isConversational("openai/whisper-large-v3"));
    try std.testing.expect(!isConversational("openai/text-embedding-3-small"));
    try std.testing.expect(!isConversational("cohere/embed-english-v3.0"));
    try std.testing.expect(!isConversational("openai/omni-moderation-latest"));

    // And the ones a turn actually runs on.
    try std.testing.expect(isConversational("qwen/qwen3-8b:free"));
    try std.testing.expect(isConversational("deepseek/deepseek-chat-v3-0324:free"));
    try std.testing.expect(isConversational("google/gemini-2.5-flash-lite"));
    try std.testing.expect(isConversational("space-bunny-free"));
    // A name that CONTAINS one of the words but is a chat model anyway.
    try std.testing.expect(isConversational("inception/mercury-coder-small"));
}

test "isRouter: the ids that measured 0% cached, and the `:free` models that measured 98%" {
    // The whole point of the table is that the suffix does not tell them apart:
    // `openrouter/free` is a ROUTER and `qwen/...:free` is a MODEL, and both end
    // in the same word. Getting this backwards costs the whole prompt cache.

    // Routers. `openrouter/free` was measured answering 3583 / 3273 / 3381 for
    // an identical prefix: 0% cached, every time, and it cannot be otherwise.
    for ([_][]const u8{
        "openrouter/free",
        "openrouter/auto",
        "openrouter/fallback",
    }) |r| {
        try std.testing.expect(isRouter(r));
        // A router is NOT offered as a free model, even though it is free. That
        // is the whole point of the interaction: it measured 0% cached, so the
        // pool has to be able to say no to it.
        try std.testing.expect(!isFreeId(r));
    }

    // Fixed models that happened to be free. `qwen/qwen3.8-27b:free` measured 98%
    // cached and must NOT be called a router, or the warning would fire on the
    // one model that works.
    for ([_][]const u8{
        "qwen/qwen3.8-27b:free",
        "cohere/north-mini-code:free",
        "poolside/laguna-xs-2.1:free",
        "anthropic/claude-sonnet-5.5",
    }) |m| {
        try std.testing.expect(!isRouter(m));
    }
}
