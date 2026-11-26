//! Role pipeline (pure). Specialized agents share one workspace; the harness
//! owns permissions and stage transitions. No worktrees.

const std = @import("std");

pub const Role = enum { investigator, implementer, tester, reviewer };
pub const Stage = enum { investigate, implement, verify, review, done };
pub const Decision = enum { work, retry, complete, blocked };

pub const MAX_REVIEW_ATTEMPTS: usize = 2;

pub fn canWrite(role: Role) bool {
    return role == .implementer;
}

pub const Review = struct {
    high: usize = 0,
    medium: usize = 0,
    low: usize = 0,
    summary: []const u8 = "",

    pub fn ok(self: Review) bool {
        return self.high == 0;
    }
};

fn indexOfCi(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (haystack.len < needle.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var same = true;
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(c)) {
                same = false;
                break;
            }
        }
        if (same) return i;
    }
    return null;
}

pub fn parseReview(text: []const u8) Review {
    var out = Review{};
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r\n");
        const at = indexOfCi(line, "SEVERITY:") orelse continue;
        const tail = std.mem.trim(u8, line[at + 9 ..], " \t");
        if (std.ascii.startsWithIgnoreCase(tail, "high")) out.high += 1 else if (std.ascii.startsWithIgnoreCase(tail, "medium")) out.medium += 1 else if (std.ascii.startsWithIgnoreCase(tail, "low")) out.low += 1;
    }
    out.summary = text;
    return out;
}

pub const StageResult = struct {
    stage: Stage,
    decision: Decision,
};

pub fn stageFor(stage: Stage, tasks_done: bool, review: Review, review_attempts: usize) StageResult {
    if (stage == .done) return .{ .stage = .done, .decision = .complete };
    if (!tasks_done) return .{ .stage = .implement, .decision = .work };
    if (stage != .review) return .{ .stage = .review, .decision = .work };
    if (review.ok()) return .{ .stage = .done, .decision = .complete };
    if (review_attempts < MAX_REVIEW_ATTEMPTS) return .{ .stage = .implement, .decision = .retry };
    return .{ .stage = .review, .decision = .blocked };
}

test "roles: only implementers write" {
    try std.testing.expect(canWrite(.implementer));
    try std.testing.expect(!canWrite(.investigator));
    try std.testing.expect(!canWrite(.reviewer));
}

test "roles: a high severity review blocks completion" {
    const bad = parseReview("bug\nSEVERITY: high — wrong output\nSEVERITY: low — style");
    try std.testing.expect(!bad.ok());
    try std.testing.expectEqual(@as(usize, 1), bad.high);
    try std.testing.expect(parseReview("SEVERITY: low — fine").ok());
}

test "roles: stage machine requires review and bounds retries" {
    const first = stageFor(.implement, true, .{}, 0);
    try std.testing.expectEqual(Stage.review, first.stage);
    const retry = stageFor(.review, true, parseReview("SEVERITY: high — bug"), 0);
    try std.testing.expectEqual(Decision.retry, retry.decision);
    const blocked = stageFor(.review, true, parseReview("SEVERITY: high — bug"), MAX_REVIEW_ATTEMPTS);
    try std.testing.expectEqual(Decision.blocked, blocked.decision);
    const clean = stageFor(.review, true, parseReview("SEVERITY: low — ok"), 0);
    try std.testing.expectEqual(Decision.complete, clean.decision);
}
