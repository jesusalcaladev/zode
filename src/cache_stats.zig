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
