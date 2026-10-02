//! Session numbers for `/bench`: the data you need BEFORE raising the iteration
//! limit or optimizing anything.
//!
//! Why this file exists at all: `max_iterations` was 8, nobody knew how often a
//! turn actually hit it, and "raise it to 20" was a guess. With the counter, the
//! decision has a number in it. It is also the fastest way to see a regression:
//! TTFT is the difference between "the model is slow" and "we made the request
//! badly", and the average is what says which one moved.
//!
//! Pure and allocation-free on the recording side (fixed arrays, no growth),
//! because it is written from the worker on every turn and read from the draw.
//! The only allocation is the composed text, which belongs to the caller.

const std = @import("std");

/// TTFT samples kept for the percentile. 64 covers a long session; past that the
/// average still moves and the tail stops mattering.
pub const max_samples = 64;

pub const Stats = @This();

turns: usize = 0,
/// Turns that ended because the loop ran out of iterations.
turns_capped: usize = 0,
iterations: usize = 0,
tool_calls: usize = 0,
asks: usize = 0,
subagents: usize = 0,
bg_jobs: usize = 0,
/// Wall time of the turns, in ms.
turn_ms: u64 = 0,
ttft: [max_samples]u64 = undefined,
ttft_len: usize = 0,
ttft_dropped: usize = 0,
/// Reads the file cache answered without sending the body. It is here and not
/// only in `/context` because this is the number that says whether the cache
/// EARNS its keep: a read cache with zero hits is code that only adds risk.
read_hits: usize = 0,

pub fn reset(self: *Stats) void {
    self.* = .{};
}

/// Records one turn. `ttft_ms` is 0 when nothing streamed.
pub fn noteTurn(self: *Stats, iterations: usize, ms: u64, ttft_ms: u64, capped: bool) void {
    self.turns += 1;
    self.iterations += iterations;
    self.turn_ms += ms;
    if (capped) self.turns_capped += 1;
    self.noteTtft(ttft_ms);
}

fn noteTtft(self: *Stats, ttft_ms: u64) void {
    if (ttft_ms == 0) return;
    if (self.ttft_len < max_samples) {
        self.ttft[self.ttft_len] = ttft_ms;
        self.ttft_len += 1;
    } else {
        // Ring the oldest out. A p95 over the LAST 64 samples is the p95 that
        // describes how it feels now; a p95 over the whole session is the p95
        // of a machine that was busy compiling something else an hour ago.
        std.mem.copyForwards(u64, self.ttft[0 .. max_samples - 1], self.ttft[1..max_samples]);
        self.ttft[max_samples - 1] = ttft_ms;
        self.ttft_dropped += 1;
    }
}

pub fn avgTtft(self: *const Stats) u64 {
    if (self.ttft_len == 0) return 0;
    var sum: u64 = 0;
    for (self.ttft[0..self.ttft_len]) |v| sum += v;
    return sum / self.ttft_len;
}

/// p50 and p95 of the samples, sorted in `scratch` (caller-provided, ≥
/// `max_samples`).
pub fn percentiles(self: *const Stats, scratch: []u64) struct { p50: u64, p95: u64 } {
    if (self.ttft_len == 0) return .{ .p50 = 0, .p95 = 0 };
    const n = @min(self.ttft_len, scratch.len);
    @memcpy(scratch[0..n], self.ttft[0..n]);
    std.mem.sort(u64, scratch[0..n], {}, std.sort.asc(u64));
    return .{
        .p50 = scratch[(n - 1) / 2],
        .p95 = scratch[@min(n - 1, (n * 95) / 100)],
    };
}

pub fn avgTurnMs(self: *const Stats) u64 {
    if (self.turns == 0) return 0;
    return self.turn_ms / self.turns;
}

pub fn avgIterations(self: *const Stats) f64 {
    if (self.turns == 0) return 0;
    return @as(f64, @floatFromInt(self.iterations)) / @as(f64, @floatFromInt(self.turns));
}

/// Fraction of turns that ran out of iterations, as a percentage. This is THE
/// number for deciding whether `max_iterations` is too low: if it is 0, raising
/// it costs nothing; if it is 40, the limit is what is ending your tasks.
pub fn cappedPct(self: *const Stats) u8 {
    if (self.turns == 0) return 0;
    return @intFromFloat(@as(f64, @floatFromInt(self.turns_capped)) /
        @as(f64, @floatFromInt(self.turns)) * 100.0);
}

/// The `/bench` report. Composed into `out` by the caller.
pub fn report(self: *const Stats, out: []u8, max_iter: usize, hit_pct: u8) ![]const u8 {
    var scratch: [max_samples]u64 = undefined;
    const pc = self.percentiles(&scratch);
    // The "older samples dropped" tail is a VARIABLE string, so it is composed
    // into its own buffer: `comptimePrint` only takes comptime arguments and
    // `self.ttft_dropped` is not one. Composing it separately keeps the big
    // literal below free of format gymnastics.
    var tail: [64]u8 = undefined;
    const dropped_tail: []const u8 = if (self.ttft_dropped > 0)
        std.fmt.bufPrint(&tail, " (+{d} older samples dropped)", .{self.ttft_dropped}) catch ""
    else
        "";

    var w: std.Io.Writer = .fixed(out);
    // `catch` and NOT `try`: a buffer too small for the whole report has to come
    // back as the part that FIT, not as an error. The report is a diagnostic and
    // an error from it is a diagnostic that says nothing.
    w.print(
        \\bench · {d} turn{s} · {d}.{d}s avg
        \\iterations {d:.1} avg (limit {d}) · {d}% hit the limit
        \\first token {d}ms avg · p50 {d}ms · p95 {d}ms{s}
        \\tools {d} · asks {d} · subagents {d} · bg jobs {d}
        \\cache hit {d}% · read cache: {d} re-reads avoided
        \\
    , .{
        self.turns,
        if (self.turns == 1) @as([]const u8, "") else @as([]const u8, "s"),
        self.avgTurnMs() / 1000,
        (self.avgTurnMs() % 1000) / 100,
        self.avgIterations(),
        max_iter,
        self.cappedPct(),
        self.avgTtft(),
        pc.p50,
        pc.p95,
        dropped_tail,
        self.tool_calls,
        self.asks,
        self.subagents,
        self.bg_jobs,
        hit_pct,
        self.read_hits,
    }) catch {};
    return w.buffered();
}

const bench = @This();

test "reset deja todo a cero" {
    var s = Stats{};
    s.noteTurn(3, 1200, 400, false);
    s.tool_calls = 5;
    s.reset();
    try std.testing.expectEqual(@as(usize, 0), s.turns);
    try std.testing.expectEqual(@as(usize, 0), s.tool_calls);
    try std.testing.expectEqual(@as(u64, 0), s.avgTtft());
}

test "noteTurn: promedios y contador de topes" {
    var s = Stats{};
    s.noteTurn(2, 1000, 300, false);
    s.noteTurn(4, 3000, 500, true);
    try std.testing.expectEqual(@as(usize, 2), s.turns);
    try std.testing.expectEqual(@as(usize, 6), s.iterations);
    try std.testing.expectEqual(@as(u64, 2000), s.avgTurnMs());
    try std.testing.expectEqual(@as(u64, 400), s.avgTtft());
    try std.testing.expectEqual(@as(u8, 50), s.cappedPct());
}

test "noteTtft: sin muestras no hay NaN ni division por cero" {
    var s = Stats{};
    try std.testing.expectEqual(@as(u64, 0), s.avgTtft());
    try std.testing.expectEqual(@as(u64, 0), s.percentiles(&.{}).p95);
    // Un turno sin stream (todo error, por ejemplo) NO cuenta como TTFT 0: un
    // cero aqui hundiria la media y haria parecer que la red va bien.
    s.noteTurn(1, 500, 0, false);
    try std.testing.expectEqual(@as(u64, 0), s.avgTtft());
}

test "percentiles ordena sin pisar el array del caller" {
    var s = Stats{};
    var i: usize = 0;
    // Inserted descending: 1000, 900, ... 100. After `percentiles` the array
    // must STILL be in insertion order (it is the record of what happened) while
    // the percentiles come out of a COPY.
    while (i < 10) : (i += 1) s.noteTtft(100 * (10 - i));
    try std.testing.expectEqual(@as(u64, 1000), s.ttft[0]);
    try std.testing.expectEqual(@as(u64, 100), s.ttft[9]);
    var scratch: [max_samples]u64 = undefined;
    const pc = s.percentiles(&scratch);
    try std.testing.expectEqual(@as(u64, 1000), s.ttft[0]);
    try std.testing.expectEqual(@as(u64, 500), pc.p50);
    try std.testing.expectEqual(@as(u64, 1000), pc.p95);
}

test "el anillo de TTFT conserva los ULTIMOS, no los primeros" {
    var s = Stats{};
    var i: usize = 0;
    while (i < max_samples) : (i += 1) s.noteTtft(1000);
    s.noteTtft(10); // el mas reciente
    try std.testing.expectEqual(@as(usize, max_samples), s.ttft_len);
    try std.testing.expectEqual(@as(u64, 10), s.ttft[max_samples - 1]);
    try std.testing.expectEqual(@as(u64, 1000), s.ttft[0]);
    try std.testing.expectEqual(@as(usize, 1), s.ttft_dropped);
}

test "report: sale una linea legible y no revienta con el buffer dado" {
    var s = Stats{};
    s.noteTurn(5, 8000, 900, false);
    s.tool_calls = 12;
    s.asks = 2;
    // Buffer pequeno a proposito: el `report` tiene que recortar sin panic, que
    // es lo que pasaria si imprimiera en un buffer de la UI asumiendo que cabe.
    var tiny: [64]u8 = undefined;
    const t = s.report(&tiny, 12, 80) catch unreachable;
    try std.testing.expect(t.len <= tiny.len);
    try std.testing.expect(t.len > 0);

    var big: [1024]u8 = undefined;
    const full = try s.report(&big, 12, 80);
    try std.testing.expect(std.mem.indexOf(u8, full, "first token 900ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, full, "limit 12") != null);
    try std.testing.expect(std.mem.indexOf(u8, full, "asks 2") != null);
}

test "report con cero turnos no inventa datos" {
    var s = Stats{};
    var buf: [512]u8 = undefined;
    const t = try s.report(&buf, 8, 0);
    try std.testing.expect(std.mem.indexOf(u8, t, "0 turns") != null);
}
