//! The single result-cap layer.
//!
//! One place for every cap a tool result can hit:
//!   - per-tool cap (`default_max_result_chars`; `read` is unbounded)
//!   - aggregate budget across all results of one assistant message
//!     (`max_results_per_message_chars`)
//!
//! A cut always carries its notice INSIDE the budget: kept text plus the notice
//! never exceed the cap, and the cut never lands in the middle of a UTF-8
//! sequence. Nothing here touches the network or the terminal — pure logic, so
//! it can be tested without a TUI. Phase 3 wires the per-tool `max_result_chars`
//! into the tools and plugs in the "persist instead of truncate" hook.

const std = @import("std");

/// Default per-tool cap, in bytes (like the rest of the result caps, e.g. the
/// 16 KB foreground cap). `read` is unbounded.
pub const default_max_result_chars: usize = 50_000;
/// Aggregate budget for all tool results in a single assistant message.
pub const max_results_per_message_chars: usize = 200_000;

/// The notice appended to a cut result. It counts toward the budget.
pub const cut_notice: []const u8 =
    "\n… (result cut at the tool's cap — re-run it narrower to get the rest)\n";

/// The outcome of capping one result.
pub const Capped = struct {
    /// The (possibly shortened) text. Its byte length is ≤ the cap.
    text: []const u8,
    /// True when `text` was cut.
    cut: bool,
};

/// Caps `text` to `max_chars` bytes. When it does not fit, the tail is replaced
/// by `cut_notice` so that kept + notice ≤ max_chars, and the cut never splits
/// a UTF-8 sequence.
///
/// Returns the original slice (no copy) when it already fits.
pub fn capResult(
    arena: std.mem.Allocator,
    text: []const u8,
    max_chars: usize,
) !Capped {
    if (text.len <= max_chars) return .{ .text = text, .cut = false };
    // Not even the notice fits: return what little of the notice we can.
    if (max_chars <= cut_notice.len) {
        return .{ .text = cut_notice[0..max_chars], .cut = true };
    }
    const budget = max_chars - cut_notice.len;
    const cut = validPrefixBytes(text, budget);
    const buf = try arena.alloc(u8, cut + cut_notice.len);
    @memcpy(buf[0..cut], text[0..cut]);
    @memcpy(buf[cut..], cut_notice);
    return .{ .text = buf[0 .. cut + cut_notice.len], .cut = true };
}

/// The largest `n ≤ max_bytes` such that `text[0..n]` is valid UTF-8.
/// Never includes a dangling leading byte or a continuation byte without its
/// lead, so the result is always valid UTF-8.
fn validPrefixBytes(text: []const u8, max_bytes: usize) usize {
    var n: usize = 0;
    while (n < text.len) {
        if (n >= max_bytes) break;
        const seq = std.unicode.utf8ByteSequenceLength(text[n]) catch break;
        if (seq == 0) break;
        if (n + seq > max_bytes) break;
        if (!std.unicode.utf8ValidateSlice(text[n .. n + seq])) break;
        n += seq;
    }
    return n;
}

/// Caps every result at `per_tool_max` and, if the total still exceeds
/// `aggregate_max`, trims the largest results first — repeatedly — until the
/// sum fits. Each cut keeps its notice inside its own (new, smaller) budget.
///
/// Results keep their original order. Returns an arena-allocated slice.
pub fn capAggregate(
    arena: std.mem.Allocator,
    results: []const []const u8,
    per_tool_max: usize,
    aggregate_max: usize,
) ![]Capped {
    var capped: std.ArrayList(Capped) = .empty;
    for (results) |r| {
        try capped.append(arena, try capResult(arena, r, per_tool_max));
    }
    var total: usize = 0;
    for (capped.items) |c| total += c.text.len;
    if (total <= aggregate_max) return capped.toOwnedSlice(arena);

    // Trim the largest result, then recompute, until the sum fits. Trimming the
    // current largest first is exactly what the aggregate rule asks for.
    while (total > aggregate_max) {
        var best: ?usize = null;
        var best_len: usize = 0;
        for (capped.items, 0..) |c, i| {
            if (c.text.len > best_len and c.text.len > cut_notice.len) {
                best_len = c.text.len;
                best = i;
            }
        }
        if (best == null) break; // nothing left to give
        const i = best.?;
        const cur = capped.items[i].text.len;
        const others = total - cur;
        const new_max = if (aggregate_max > others) aggregate_max - others else 0;
        const trimmed = try capResult(arena, capped.items[i].text, new_max);
        total = others + trimmed.text.len;
        capped.items[i] = trimmed;
    }
    return capped.toOwnedSlice(arena);
}

test "capResult: under the cap is untouched and not cut" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const c = try capResult(arena, "hello world", 100);
    try std.testing.expectEqualStrings("hello world", c.text);
    try std.testing.expect(!c.cut);
}

test "capResult: exactly at the boundary is untouched" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const c = try capResult(arena, "1234567890", 10);
    try std.testing.expectEqualStrings("1234567890", c.text);
    try std.testing.expect(!c.cut);
    try std.testing.expectEqual(c.text.len, 10);
}

test "capResult: empty input is untouched" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const c = try capResult(arena, "", 10);
    try std.testing.expectEqualStrings("", c.text);
    try std.testing.expect(!c.cut);
}

test "capResult: over the cap cuts and keeps the full notice inside the budget" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: [300]u8 = undefined;
    @memset(buf[0..], 'x');
    const text = buf[0..];
    const c = try capResult(arena, text, 200);
    try std.testing.expect(c.cut);
    try std.testing.expectEqual(c.text.len, 200);
    try std.testing.expect(std.mem.endsWith(u8, c.text, cut_notice));
    try std.testing.expect(std.unicode.utf8ValidateSlice(c.text));
}

test "capResult: never cuts a multi-byte character in half" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // "ab" followed by 40 é's (2 bytes each) = 82 bytes, more than max_chars
    // (3 + cut_notice.len ≈ 74), so a cut is forced right at the start.
    var buf: [100]u8 = undefined;
    buf[0] = 'a';
    buf[1] = 'b';
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        buf[2 + i * 2] = 0xc3;
        buf[3 + i * 2] = 0xa9;
    }
    const text = buf[0..82];
    const max_chars = 3 + cut_notice.len;
    const c = try capResult(arena, text, max_chars);
    try std.testing.expect(c.cut);
    try std.testing.expect(c.text.len <= max_chars);
    try std.testing.expect(std.unicode.utf8ValidateSlice(c.text));
    try std.testing.expect(std.mem.endsWith(u8, c.text, cut_notice));
    // budget = max_chars - cut_notice.len = 3, which fits only "ab": the cut
    // point is at byte 2, never inside the é (0xC3 0xA9).
    try std.testing.expect(std.mem.eql(u8, c.text[0..2], "ab"));
}

test "capResult: a degenerate cap smaller than the notice still cuts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const c = try capResult(arena, "anything at all", 5);
    try std.testing.expect(c.cut);
    try std.testing.expectEqual(c.text.len, 5);
    try std.testing.expect(std.mem.eql(u8, c.text, cut_notice[0..5]));
}

test "capAggregate: under budget leaves every result untouched" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const results = &[_][]const u8{ "short", "a bit longer", "tiny" };
    const out = try capAggregate(arena, results[0..], 100, 1000);
    try std.testing.expectEqual(out.len, 3);
    try std.testing.expectEqualStrings("short", out[0].text);
    try std.testing.expectEqualStrings("a bit longer", out[1].text);
    try std.testing.expectEqualStrings("tiny", out[2].text);
    for (out) |c| try std.testing.expect(!c.cut);
}

test "capAggregate: empty input is an empty slice" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const results = &[_][]const u8{};
    const out = try capAggregate(arena, results[0..], 100, 1000);
    try std.testing.expectEqual(out.len, 0);
}

test "capAggregate: trims the largest first and keeps a full notice inside the trimmed budget" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var a_buf: [150]u8 = undefined;
    var b_buf: [150]u8 = undefined;
    @memset(a_buf[0..], 'A');
    @memset(b_buf[0..], 'B');
    const results = &[_][]const u8{
        a_buf[0..],
        b_buf[0..],
        "CCCCCCCCCC",
    };
    const out = try capAggregate(arena, results[0..], 200, 300);
    try std.testing.expectEqual(out.len, 3);
    var total: usize = 0;
    for (out) |c| total += c.text.len;
    try std.testing.expect(total <= 300);
    try std.testing.expect(out[0].cut);
    try std.testing.expectEqual(out[0].text.len, 140);
    try std.testing.expect(std.mem.endsWith(u8, out[0].text, cut_notice));
    // the smaller results were untouched: largest-first means they survive
    try std.testing.expectEqual(out[1].text.len, 150);
    for (out[1].text) |b| try std.testing.expect(b == 'B');
    try std.testing.expect(!out[1].cut);
    try std.testing.expectEqualStrings("CCCCCCCCCC", out[2].text);
    try std.testing.expect(!out[2].cut);
}

test "capAggregate: trims repeatedly until the sum fits" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var a_buf: [200]u8 = undefined;
    var b_buf: [200]u8 = undefined;
    @memset(a_buf[0..], 'A');
    @memset(b_buf[0..], 'B');
    const results = &[_][]const u8{
        a_buf[0..],
        b_buf[0..],
        "CCCCCCCCCCCCCCCC",
    };
    const out = try capAggregate(arena, results[0..], 200, 250);
    var total: usize = 0;
    for (out) |c| total += c.text.len;
    try std.testing.expect(total <= 250);
    try std.testing.expectEqualStrings("CCCCCCCCCCCCCCCC", out[2].text);
    try std.testing.expect(!out[2].cut);
}

test "capAggregate: a result exactly at the per-tool boundary is not cut" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const results = &[_][]const u8{ "1234567890" };
    const out = try capAggregate(arena, results[0..], 10, 100);
    try std.testing.expectEqual(out.len, 1);
    try std.testing.expectEqualStrings("1234567890", out[0].text);
    try std.testing.expect(!out[0].cut);
}
