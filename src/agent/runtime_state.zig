const std = @import("std");
const turn_metrics = @import("../lib/turn_metrics.zig");
const chat = @import("../chat.zig");
const agent_perms = @import("perms.zig");

pub const TpsResult = struct {
    tps: f64,
    valid: bool,
};

pub fn computeFinishTps(io: std.Io, start_ns: i128, chars: usize, completion: i64) TpsResult {
    if (start_ns == 0) return .{ .tps = 0, .valid = false };
    const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    const tokens: f64 = if (completion > 0) @floatFromInt(completion) else turn_metrics.estTokens(chars);
    const tps = turn_metrics.tpsOf(tokens, now_ns - start_ns);
    return .{ .tps = tps, .valid = tps > 0 };
}

pub fn applyFinishTps(io: std.Io, start_ns: i128, chars: usize, completion: i64, tps_last: *f64) void {
    const r = computeFinishTps(io, start_ns, chars, completion);
    if (r.valid) tps_last.* = r.tps;
}

/// Live TPS window update (used by streaming delta handler).
pub const TpsWindow = struct { win_ns: i128, win_chars: usize, tps_live: f64, tps_last: f64 };

pub fn updateTpsWindow(
    now_ns: i128,
    stream_start_ns: i128,
    chars: usize,
    win_ns: i128,
    win_chars: usize,
    tps_live: f64,
    tps_last: f64,
    sample_ns: i128,
) struct { stream_started: bool, win_ns: i128, win_chars: usize, tps_live: f64, tps_last: f64 } {
    if (stream_start_ns == 0) {
        return .{ .stream_started = true, .win_ns = now_ns, .win_chars = chars, .tps_live = 0, .tps_last = tps_last };
    }
    if (now_ns - win_ns >= sample_ns) {
        const win = turn_metrics.tpsOf(turn_metrics.estTokens(chars - win_chars), now_ns - win_ns);
        if (win > 0) return .{ .stream_started = false, .win_ns = now_ns, .win_chars = chars, .tps_live = win, .tps_last = win };
        return .{ .stream_started = false, .win_ns = now_ns, .win_chars = chars, .tps_live = tps_live, .tps_last = tps_last };
    }
    return .{ .stream_started = false, .win_ns = win_ns, .win_chars = win_chars, .tps_live = tps_live, .tps_last = tps_last };
}

pub fn clearContextUsage(ctx_used: *i64, ctx_pct: *u8, ctx_real: *bool) void {
    ctx_used.* = 0;
    ctx_pct.* = 0;
    ctx_real.* = false;
}

pub fn applyContextUsage(
    real: i64,
    estimate: i64,
    limit: u32,
    ctx_used: *i64,
    ctx_pct: *u8,
    ctx_real: *bool,
) void {
    const u = turn_metrics.contextUsage(real, estimate, limit);
    ctx_used.* = u.used;
    ctx_pct.* = u.pct;
    ctx_real.* = u.real;
}

pub fn iterationSource(override_set: bool, model_requested: bool) []const u8 {
    if (override_set) return "your /iter";
    if (model_requested) return "the model's estimate";
    return "ZODE_MAX_ITER / default";
}

pub fn effectiveEffortFor(model: []const u8, effort: chat.Effort) chat.Effort {
    return chat.effectiveEffort(model, effort);
}

pub const keyStateString = agent_perms.keyStateString;

test "computeFinishTps rejects missing start" {
    const r = computeFinishTps(std.testing.io, 0, 100, 10);
    try std.testing.expect(!r.valid);
}

test "iterationSource" {
    const t = std.testing;
    try t.expectEqualStrings("your /iter", iterationSource(true, false));
    try t.expectEqualStrings("the model's estimate", iterationSource(false, true));
    try t.expectEqualStrings("ZODE_MAX_ITER / default", iterationSource(false, false));
}

test "clearContextUsage" {
    var used: i64 = 42;
    var pct: u8 = 10;
    var real = true;
    clearContextUsage(&used, &pct, &real);
    try std.testing.expectEqual(@as(i64, 0), used);
    try std.testing.expectEqual(@as(u8, 0), pct);
    try std.testing.expect(!real);
}
