const std = @import("std");

/// Cache statistics across the whole session, provider-agnostic.
/// Reads chat.last_usage after each stream and accumulates.
pub const CacheStats = struct {
    prompt_tokens: i64 = 0,
    cached_tokens: i64 = 0,
    completion_tokens: i64 = 0,
    requests: usize = 0,
    /// Requests where at least 1 token was served from cache.
    cache_hits: usize = 0,
    /// Tokens the provider WROTE into its cache (Anthropic's
    /// `cache_creation_input_tokens`). OpenAI does not report it and always 0.
    ///
    /// Reads and writes are the two halves of the cost and only one of them was
    /// visible: a prefix that gets re-written every turn has a perfectly good
    /// hit-rate on the turns where it is read and still bills the whole prefix
    /// again on the turns where it is not. This is the number that shows it.
    cache_write_tokens: i64 = 0,
    /// Requests that wrote to the cache at all.
    cache_writes: usize = 0,

    /// The prompt count of the FIRST request, and the spread of the ones after.
    ///
    /// This is the diagnosis, and it is better than a list of model ids because
    /// it does not need to know which ids are routers: it watches the evidence.
    ///
    /// The prefix does not change during a turn — the system prompt and the tool
    /// schema are the same bytes — so a FIXED model counts them identically every
    /// time. A ROUTER does not: it picks a different upstream per request, the
    /// upstream tokenizes differently, and the count drifts by hundreds. Measured
    /// on 2026-10-04 with an identical 3.5k prefix:
    ///
    /// ```
    /// openrouter/free          3583  3273  3381     <- a router, and 0% cached
    /// qwen/qwen3.8-27b:free   3611  3613  3613     <- a model, and 98% cached
    /// ```
    ///
    /// `first_prompt` is 0 until the first request, so "not enough data yet" and
    /// "perfectly stable" are different states and not confused.
    first_prompt: i64 = 0,
    /// How much the later counts differ from the first one, in tokens.
    prompt_drift: i64 = 0,

    pub fn record(self: *CacheStats, usage: chat.Usage) void {
        if (usage.prompt == 0 and usage.completion == 0) return;
        self.requests += 1;
        self.prompt_tokens += usage.prompt;
        self.completion_tokens += usage.completion;
        if (usage.cached > 0) {
            self.cache_hits += 1;
            self.cached_tokens += usage.cached;
        }
        if (usage.cache_write > 0) {
            self.cache_writes += 1;
            self.cache_write_tokens += usage.cache_write;
        }
        if (self.first_prompt == 0) {
            self.first_prompt = usage.prompt;
        } else {
            // `@abs` on a signed `i64` is the fix, not a cast: `usage.prompt` can
            // arrive as `u64` from a provider and the subtraction must not wrap.
            const d: i64 = @as(i64, @intCast(usage.prompt)) - self.first_prompt;
            const ad: i64 = if (d < 0) -d else d;
            if (ad > self.prompt_drift) self.prompt_drift = ad;
        }
    }

    /// What the evidence says about the cache, in words the `/cache` line prints.
    ///
    /// It is a diagnosis and not a verdict: `unknown` until there is more than one
    /// request to compare, because "0% cached on the first request" is the NORMAL
    /// state of a healthy session and reporting it as a failure would be a lie.
    pub const Verdict = enum { unknown, stable_prefix, routing, provider_uncached, ok };

    pub fn verdict(self: *const CacheStats) Verdict {
        if (self.requests < 2) return .unknown;
        // A drift of a few tokens is just the conversation growing. A drift of
        // hundreds on a prefix that is supposed to be identical is a router.
        if (self.prompt_drift > 64) return .routing;
        // Stable prefix, and still nothing served from cache: the prefix is not
        // the problem, so the provider is not caching at all (measured on
        // cohere/north-mini-code:free, which returns 0 every time).
        if (self.prompt_drift <= 64 and self.cached_tokens == 0 and self.requests >= 3) {
            return .provider_uncached;
        }
        if (self.cached_tokens > 0) return .ok;
        return .stable_prefix;
    }

    /// Percentage of prompt tokens served from cache (0-100).
    pub fn hitRatePct(self: *const CacheStats) f64 {
        if (self.prompt_tokens == 0) return 0;
        return 100.0 * @as(f64, @floatFromInt(self.cached_tokens)) /
            @as(f64, @floatFromInt(self.prompt_tokens));
    }

    /// Writes per request. Anything above ~0.5 over a long session means the
    /// prefix is not stable: something in it changes every turn and the whole
    /// thing is re-cached each time.
    pub fn writesPerRequest(self: *const CacheStats) f64 {
        if (self.requests == 0) return 0;
        return @as(f64, @floatFromInt(self.cache_writes)) /
            @as(f64, @floatFromInt(self.requests));
    }

    pub fn reset(self: *CacheStats) void {
        self.* = .{};
    }
};

const chat = @import("chat.zig");

/// Global session stats.
pub var session: CacheStats = .{};

test "hit rate math" {
    var s = CacheStats{};
    s.record(.{ .prompt = 1000, .cached = 900, .completion = 100 });
    s.record(.{ .prompt = 1000, .cached = 0, .completion = 50 });
    try std.testing.expectEqual(@as(usize, 2), s.requests);
    try std.testing.expectEqual(@as(usize, 1), s.cache_hits);
    try std.testing.expectApproxEqAbs(@as(f64, 45.0), s.hitRatePct(), 0.01);
}

test "cache writes are counted apart from reads" {
    // Anthropic reports both halves of the cost. Counting only reads made a
    // prefix that was re-written every single turn look like a healthy session.
    var s = CacheStats{};
    // Turn 1: the prefix is written (no read).
    s.record(.{ .prompt = 4000, .cached = 0, .cache_write = 4000, .completion = 100 });
    // Turn 2: read, nothing written. This is what we want.
    s.record(.{ .prompt = 4100, .cached = 4000, .cache_write = 0, .completion = 50 });
    try std.testing.expectEqual(@as(usize, 1), s.cache_writes);
    try std.testing.expectEqual(@as(i64, 4000), s.cache_write_tokens);
    try std.testing.expectEqual(@as(usize, 1), s.cache_hits);

    // And a prefix that is re-written every turn: every request writes.
    var bad = CacheStats{};
    var i: usize = 0;
    while (i < 10) : (i += 1) bad.record(.{ .prompt = 4000, .cache_write = 4000, .completion = 10 });
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), bad.writesPerRequest(), 0.001);
}

test "verdict: a router is told apart from a fixed model by the EVIDENCE, not by a list" {
    // This is the whole reason `verdict` exists. `/cache` said 0.0% for weeks with
    // no way to tell a broken setup from a router, and the only thing that
    // distinguishes them is that a router's prompt count moves.
    var fixed: CacheStats = .{};

    // A healthy session: the first request writes the cache and never hits (that
    // is NORMAL, not a failure), and every later one reads it.
    fixed.record(.{ .prompt = 3611, .completion = 10 });
    try std.testing.expectEqual(CacheStats.Verdict.unknown, fixed.verdict());
    fixed.record(.{ .prompt = 3613, .completion = 20, .cached = 3584 });
    try std.testing.expectEqual(CacheStats.Verdict.ok, fixed.verdict());
    fixed.record(.{ .prompt = 3613, .completion = 20, .cached = 3584 });
    try std.testing.expectEqual(CacheStats.Verdict.ok, fixed.verdict());
    // The drift is 2 tokens: the conversation grew. Nothing to see.
    try std.testing.expectEqual(@as(i64, 2), fixed.prompt_drift);

    // The measured router: identical prefix, drifting counts, never a hit.
    var routed: CacheStats = .{};
    routed.record(.{ .prompt = 3583, .completion = 10 });
    routed.record(.{ .prompt = 3273, .completion = 10 });
    routed.record(.{ .prompt = 3381, .completion = 10 });
    try std.testing.expectEqual(CacheStats.Verdict.routing, routed.verdict());
    try std.testing.expectEqual(@as(i64, 310), routed.prompt_drift);

    // A stable prefix that is still not cached: the provider does not cache.
    // `cohere/north-mini-code:free` measured exactly this.
    var uncached: CacheStats = .{};
    uncached.record(.{ .prompt = 3029, .completion = 10 });
    uncached.record(.{ .prompt = 3031, .completion = 10 });
    uncached.record(.{ .prompt = 3032, .completion = 10 });
    try std.testing.expectEqual(CacheStats.Verdict.provider_uncached, uncached.verdict());
}

test "verdict does not call a healthy first request a failure" {
    // "0% cached on the first request" is the normal state of every session, and
    // reporting it as a failure is how a diagnostic becomes noise that gets
    // ignored.
    var s: CacheStats = .{};
    s.record(.{ .prompt = 3600, .completion = 100 });
    try std.testing.expectEqual(CacheStats.Verdict.unknown, s.verdict());

    // Two stable requests with no cache yet: stable, and worth a note but not an
    // accusation.
    s.record(.{ .prompt = 3605, .completion = 100 });
    try std.testing.expectEqual(CacheStats.Verdict.stable_prefix, s.verdict());
}

test "the drift tracks the WORST movement, not the last one" {
    // A single big excursion is the evidence. Averaging it away is what would
    // make this diagnostic useless on a router that happens to land twice on the
    // same upstream.
    var s: CacheStats = .{};
    s.record(.{ .prompt = 3600 });
    s.record(.{ .prompt = 3400 }); // the excursion
    s.record(.{ .prompt = 3600 }); // and back again
    try std.testing.expectEqual(@as(i64, 200), s.prompt_drift);
    try std.testing.expectEqual(CacheStats.Verdict.routing, s.verdict());
}
