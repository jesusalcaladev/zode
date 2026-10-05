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

    /// The prompt count of the previous request, to compare the next one against.
    ///
    /// ## The obvious signal that does NOT work, and why
    ///
    /// It looks like the diagnosis should be "the count drifted from the first
    /// request". It is not, and the real agent found it: on a task that read three
    /// files with a FIXED model the count went 3611 -> 66946, and a drift-based
    /// verdict called it a router. It was not a router. **The prompt count grows
    /// with the conversation** — every iteration appends tool results — so
    /// drift measures how much was said, not which tokenizer counted it.
    ///
    /// What a router actually does is count the SAME conversation differently
    /// twice. So the signal is a count that goes **DOWN** when nothing was removed.
    ///
    /// Measured 2026-10-04, identical 3.5k prefix, same message list:
    ///
    /// ```
    /// openrouter/free          3583  3273  3381   <- down, then up: a router
    /// qwen/qwen3.8-27b:free   3611  3613  3613   <- only up: a model
    /// ```
    prev_prompt: i64 = 0,
    /// Requests whose prompt count was SMALLER than the previous one, with NO
    /// compaction to explain it.
    ///
    /// Compaction replaces old turns with a summary, so a decrease is legitimate
    /// there and it is the only legitimate cause. Rather than guess with a
    /// threshold — one shrink was already a router in the measured data
    /// (3583 / 3273 / 3381), and two would hide it — the caller that KNOWS it
    /// compacted says so through `markCompacted()`, and what is left over is the
    /// fingerprint.
    ///
    /// This is the same shape as `quotaVerdict(err, detail)`: the decision needs
    /// a fact the number does not carry, so it is passed in instead of inferred.
    prompt_shrinks: usize = 0,
    /// Request index of the last compaction, so the next shrink can be excused.
    compacted_at: usize = 0,
    /// Shrinks that compaction has not accounted for.
    unexplained_shrinks: usize = 0,

    /// Called when tier-2 compaction rewrote the history.
    pub fn markCompacted(self: *CacheStats) void {
        self.compacted_at = self.requests;
    }

    pub fn record(self: *CacheStats, usage: chat.Usage) void {
        if (usage.prompt == 0 and usage.completion == 0) return;
        // Captured BEFORE the increment: this is how many requests had already
        // happened, and "did compaction run since the last one" is exactly
        // `compacted_at >= before`. Getting this wrong counted every legitimate
        // post-compaction shrink as a router.
        const before = self.requests;
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
        const p: i64 = @intCast(usage.prompt);
        if (self.prev_prompt != 0 and p < self.prev_prompt) {
            self.prompt_shrinks += 1;
            // Compaction rewrites the history BEFORE the next body is composed, so
            // it explains this shrink if it ran after the previous request.
            if (self.compacted_at >= before) {} else self.unexplained_shrinks += 1;
        }
        self.prev_prompt = p;
    }

    /// What the evidence says about the cache, in words the `/cache` line prints.
    ///
    /// It is a diagnosis and not a verdict, and it leans on the one signal that
    /// cannot be faked: **`cached_tokens > 0` proves it is not a router**, because
    /// routers cannot share a cache with each other. Everything else is a
    /// corroboration.
    pub const Verdict = enum { unknown, healthy, routing, provider_uncached };

    pub fn verdict(self: *const CacheStats) Verdict {
        if (self.requests < 2) return .unknown;
        // A cache hit happened, so the prefix is stable AND being served. This is
        // the definitive answer: routers cannot share a prompt cache, so one hit
        // rules a router out whatever the counts did.
        if (self.cached_tokens > 0) return .healthy;
        // The count went DOWN with nothing removed. That is a different tokenizer
        // counting the same conversation, which is a different upstream, which is
        // a router.
        if (self.unexplained_shrinks >= 1) return .routing;
        // Three requests, a count that only ever went up, and nothing cached: the
        // prefix is not the problem, so this provider does not cache. Measured on
        // cohere/north-mini-code:free, which answers 0 every time.
        if (self.requests >= 3) return .provider_uncached;
        // One request that did not hit: the normal state of every session, and
        // specifically the normal state of a healthy one.
        return .unknown;
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

test "verdict: the signal is a prompt count that goes DOWN, not one that drifts" {
    // The first version compared each count against the FIRST one and called a
    // big difference a router. The real agent found it: a FIXED model reading
    // three files went 3611 -> 66946 and was called a router. The prompt count
    // grows with the conversation; drift measures how much was said, not which
    // tokenizer counted it.
    //
    // What a router does is count the SAME conversation differently twice.
    var routed: CacheStats = .{};
    routed.record(.{ .prompt = 3583 });
    routed.record(.{ .prompt = 3273 }); // DOWN: a smaller tokenizer upstream
    routed.record(.{ .prompt = 3381 });
    try std.testing.expectEqual(CacheStats.Verdict.routing, routed.verdict());
    // ONE shrink, not two: the measured sequence has exactly one, and a threshold
    // of two would have hidden the router it came from.
    try std.testing.expectEqual(@as(usize, 1), routed.prompt_shrinks);
    try std.testing.expectEqual(@as(usize, 1), routed.unexplained_shrinks);

    // The healthy version: identical 3.5k prefix, same model, 98% cached.
    var fixed: CacheStats = .{};
    fixed.record(.{ .prompt = 3611 });
    fixed.record(.{ .prompt = 3613, .cached = 3584 });
    fixed.record(.{ .prompt = 3613, .cached = 3584 });
    try std.testing.expectEqual(CacheStats.Verdict.healthy, fixed.verdict());
    try std.testing.expectEqual(@as(usize, 0), fixed.prompt_shrinks);
}

test "verdict: a REAL growing conversation is healthy, and the verdict must say so" {
    // This is the case that broke the first version, written out with the numbers
    // the real run produced: three files read, one fixed model, 66946 prompt
    // tokens in total and 33792 of them served from cache.
    var s2: CacheStats = .{};
    s2.record(.{ .prompt = 3474 });
    s2.record(.{ .prompt = 12000, .cached = 3300 });
    s2.record(.{ .prompt = 33900, .cached = 17000 });
    s2.record(.{ .prompt = 66946, .cached = 33000 });
    try std.testing.expectEqual(CacheStats.Verdict.healthy, s2.verdict());
    // The count went up by 63 000 tokens and it is still perfectly healthy.
    try std.testing.expectEqual(@as(usize, 0), s2.prompt_shrinks);
}

test "verdict: a stable, never-shrinking prefix with no cache is the PROVIDER, not the prefix" {
    // `cohere/north-mini-code:free` measured exactly this: the count only ever
    // went up and it answered 0 cached every time.
    var uncached: CacheStats = .{};
    uncached.record(.{ .prompt = 3029 });
    uncached.record(.{ .prompt = 3031 });
    uncached.record(.{ .prompt = 3032 });
    try std.testing.expectEqual(CacheStats.Verdict.provider_uncached, uncached.verdict());
    try std.testing.expectEqual(@as(usize, 0), uncached.prompt_shrinks);
}

test "verdict does not accuse anything on the first request" {
    // 0% cached on request one is the normal state of every session, and calling
    // it a failure is how a diagnostic becomes noise that gets ignored.
    var s2: CacheStats = .{};
    s2.record(.{ .prompt = 3600, .completion = 100 });
    try std.testing.expectEqual(CacheStats.Verdict.unknown, s2.verdict());

    // Two requests and still nothing cached: not enough to accuse a provider
    // either. Three is where it becomes a conclusion.
    s2.record(.{ .prompt = 3605, .completion = 100 });
    try std.testing.expectEqual(CacheStats.Verdict.unknown, s2.verdict());
    s2.record(.{ .prompt = 3610, .completion = 100 });
    try std.testing.expectEqual(CacheStats.Verdict.provider_uncached, s2.verdict());
}

test "a shrink that compaction explained is NOT a router" {
    // Compaction replaces old turns with a summary, so the prompt count CAN go
    // down, and a threshold on the raw count cannot tell that from a router. So
    // the caller that knows it compacted says so, and only what is left over is
    // the fingerprint.
    var s2: CacheStats = .{};
    s2.record(.{ .prompt = 40000 });
    s2.markCompacted();
    s2.record(.{ .prompt = 12000 }); // explained
    s2.record(.{ .prompt = 13000 });
    try std.testing.expectEqual(@as(usize, 1), s2.prompt_shrinks);
    try std.testing.expectEqual(@as(usize, 0), s2.unexplained_shrinks);
    try std.testing.expectEqual(CacheStats.Verdict.provider_uncached, s2.verdict());

    // A shrink with nothing having compacted is the other thing. It has to be
    // STRICTLY smaller: recording the same count twice is not a shrink, which is
    // what the first version of this test did and it passed for the wrong reason.
    s2.record(.{ .prompt = 12000 });
    try std.testing.expectEqual(@as(usize, 2), s2.prompt_shrinks);
    try std.testing.expectEqual(@as(usize, 1), s2.unexplained_shrinks);
    try std.testing.expectEqual(CacheStats.Verdict.routing, s2.verdict());
}

test "one cache hit rules a router out whatever the counts did" {
    // The strongest signal available, and it is a negative one that needs no
    // threshold: routers do not share a prompt cache, so a hit cannot happen on
    // one. A shrink with a hit is a compaction, not a router.
    var s2: CacheStats = .{};
    s2.record(.{ .prompt = 40000, .cached = 33000 });
    s2.markCompacted();
    s2.record(.{ .prompt = 12000, .cached = 9000 });
    s2.record(.{ .prompt = 13000, .cached = 9500 });
    try std.testing.expectEqual(@as(usize, 1), s2.prompt_shrinks);
    try std.testing.expectEqual(CacheStats.Verdict.healthy, s2.verdict());
}
