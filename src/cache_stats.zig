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

    pub fn record(self: *CacheStats, usage: chat.Usage) void {
        if (usage.prompt == 0 and usage.completion == 0) return;
        self.requests += 1;
        self.prompt_tokens += usage.prompt;
        self.completion_tokens += usage.completion;
        if (usage.cached > 0) {
            self.cache_hits += 1;
            self.cached_tokens += usage.cached;
        }
    }

    /// Percentage of prompt tokens served from cache (0-100).
    pub fn hitRatePct(self: *const CacheStats) f64 {
        if (self.prompt_tokens == 0) return 0;
        return 100.0 * @as(f64, @floatFromInt(self.cached_tokens)) /
            @as(f64, @floatFromInt(self.prompt_tokens));
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
