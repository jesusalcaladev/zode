/// Pure helpers for turn/context metrics.
const std = @import("std");

/// Which number means "how much context": the provider's own count when there
/// is one, the estimate when there is not.
pub fn ctxTokens(real: i64, estimate: i64) i64 {
    return if (real > 0) real else estimate;
}

/// Tokens per second of a stream that produced `tokens` in `dt_ns`.
/// Returns 0 for invalid windows or absurd rates.
pub fn tpsOf(tokens: f64, dt_ns: i128) f64 {
    if (dt_ns <= 0 or tokens <= 0) return 0;
    const tps = tokens / (@as(f64, @floatFromInt(dt_ns)) / 1e9);
    if (tps <= 0.5 or tps >= 100_000) return 0;
    return tps;
}

/// Approximate token count from character count (~4 chars/token).
pub fn estTokens(chars: usize) f64 {
    return @as(f64, @floatFromInt(chars)) / 4.0;
}

test "ctxTokens prefers real count" {
    try std.testing.expectEqual(@as(i64, 42), ctxTokens(42, 100));
    try std.testing.expectEqual(@as(i64, 100), ctxTokens(0, 100));
}

test "tpsOf bounds" {
    try std.testing.expectEqual(@as(f64, 0), tpsOf(0, 1_000_000_000));
    try std.testing.expectEqual(@as(f64, 0), tpsOf(10, 0));
    try std.testing.expect(tpsOf(100, 1_000_000_000) > 0);
}

pub fn contextPct(used: i64, limit: u32) u8 {
    const lim: f64 = @floatFromInt(@max(@as(u32, 1), limit));
    const pct = (@as(f64, @floatFromInt(used)) / lim) * 100.0;
    return @intFromFloat(std.math.clamp(pct, 0.0, 255.0));
}

test "contextPct clamps" {
    try std.testing.expectEqual(@as(u8, 0), contextPct(0, 100));
    try std.testing.expectEqual(@as(u8, 50), contextPct(50, 100));
    try std.testing.expectEqual(@as(u8, 200), contextPct(200, 100));
}

pub const ContextUsage = struct { used: i64, pct: u8, real: bool };

pub fn contextUsage(real: i64, estimate: i64, limit: u32) ContextUsage {
    const used = ctxTokens(real, estimate);
    return .{
        .used = used,
        .pct = contextPct(used, limit),
        .real = real > 0,
    };
}

test "contextUsage prefers real" {
    const u = contextUsage(1200, 5000, 10000);
    try std.testing.expectEqual(@as(i64, 1200), u.used);
    try std.testing.expect(u.real);
}
