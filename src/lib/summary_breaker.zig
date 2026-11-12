/// Circuit breaker for consecutive summarization (tier-2 compaction) failures.
///
/// Tier 2 is best-effort: when the model cannot summarize, the caller carries on
/// without a summary. Without a breaker, a summarizer that keeps failing is
/// retried every iteration. After `max_consecutive` failures in a row the
/// breaker trips and summarization stops trying; any successful summary resets
/// the counter.
const std = @import("std");

pub const SummaryBreaker = struct {
    consecutive: usize = 0,
    /// Three failures in a row is enough: the model is not going to summarize
    /// this session, and spending a request on it every turn is pure waste.
    max_consecutive: usize = 3,

    /// Record a failed attempt.
    pub fn noteFailure(self: *SummaryBreaker) void {
        self.consecutive += 1;
    }

    /// Record a successful summary: the counter resets.
    pub fn noteSuccess(self: *SummaryBreaker) void {
        self.consecutive = 0;
    }

    /// True once the breaker has tripped and tier 2 must not run again this session.
    pub fn tripped(self: *SummaryBreaker) bool {
        return self.consecutive >= self.max_consecutive;
    }

    /// Reset for a new session (`/new`, `/resume`, bootstrap).
    pub fn reset(self: *SummaryBreaker) void {
        self.consecutive = 0;
    }
};

test "not tripped before reaching the threshold" {
    var b: SummaryBreaker = .{};
    try std.testing.expect(!b.tripped());
    b.noteFailure();
    b.noteFailure();
    try std.testing.expect(!b.tripped());
}

test "trips after max_consecutive failures and stops" {
    var b: SummaryBreaker = .{};
    b.noteFailure();
    b.noteFailure();
    b.noteFailure();
    try std.testing.expectEqual(@as(usize, 3), b.consecutive);
    try std.testing.expect(b.tripped());
    b.noteFailure();
    try std.testing.expect(b.tripped());
}

test "a success resets the counter" {
    var b: SummaryBreaker = .{};
    b.noteFailure();
    b.noteFailure();
    b.noteSuccess();
    try std.testing.expect(!b.tripped());
    try std.testing.expectEqual(@as(usize, 0), b.consecutive);
}

test "reset clears a tripped breaker" {
    var b: SummaryBreaker = .{};
    b.noteFailure();
    b.noteFailure();
    b.noteFailure();
    try std.testing.expect(b.tripped());
    b.reset();
    try std.testing.expect(!b.tripped());
}
