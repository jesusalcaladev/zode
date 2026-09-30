const std = @import("std");
const chat = @import("chat.zig");

/// Context management: keep the wire view under budget so the stable prefix
/// (system + tools + early turns) stays cacheable and requests don't explode.
///
/// Two tiers, applied in order until under budget:
///  1. Elide OLD tool results: replace content with a marker. Free (no LLM)
///     and usually enough — tool dumps are the bulk of the tokens.
///  2. LLM-summarize the oldest turns into one assistant note (caller does
///     the network call; this module computes what to summarize).
///
/// IMPORTANT: this is a VIEW for the wire only. The session JSONL keeps the
/// full history, so resume/replay never loses data.
pub const default_context_limit: i64 = 128_000;
pub const target_pct: i64 = 80;
/// Recent turns kept verbatim (never elided/summarized).
pub const recent_window: usize = 8;

pub fn contextLimit(env: ?*const std.process.Environ.Map) i64 {
    const m = env orelse return default_context_limit;
    const s = m.get("ZODE_CONTEXT_LIMIT") orelse return default_context_limit;
    return std.fmt.parseInt(i64, s, 10) catch default_context_limit;
}

/// Rough token estimate: ~4 chars/token for code+English mix, plus ~4 tokens
/// of JSON overhead per message. Good enough for budgeting (±15%).
pub fn estimateTokens(msgs: []const chat.ChatMessage) i64 {
    var total: i64 = 0;
    for (msgs) |m| {
        total += @intCast(m.content.len / 4 + 4);
        if (m.tool_calls_json) |tj| total += @intCast(tj.len / 4 + 8);
    }
    return total;
}

pub fn budgetTokens(env: ?*const std.process.Environ.Map) i64 {
    return @divTrunc(contextLimit(env) * target_pct, 100);
}

pub const Compacted = struct {
    msgs: []chat.ChatMessage,
    /// How many tool results were elided (tier 1).
    elided: usize = 0,
    /// True if tier 2 (LLM summary) is still needed to reach budget.
    needs_summary: bool = false,
    /// Slice of msgs[0..summary_upto] that tier 2 should summarize
    /// (excluding the system message at index 0).
    summary_upto: usize = 0,
};

/// Tier 1: elide old tool results until under budget (or nothing left to
/// elide). Newest `recent_window` messages are never touched.
pub fn elideTier(arena: std.mem.Allocator, msgs: []const chat.ChatMessage, budget: i64) !Compacted {
    const out = try arena.alloc(chat.ChatMessage, msgs.len);
    @memcpy(out, msgs);

    var elided: usize = 0;
    // Elide from oldest to newest, skipping system (0) and the recent window.
    const protect_from: usize = if (out.len > recent_window) out.len - recent_window else 0;

    var i: usize = 1; // skip system
    while (i < protect_from) : (i += 1) {
        if (estimateTokens(out) <= budget) break;
        const m = &out[i];
        if (!std.mem.eql(u8, m.role, "tool")) continue;
        if (m.content.len < 256) continue; // not worth it
        const marker = try std.fmt.allocPrint(
            arena,
            "[tool result elided: {d} bytes — re-run the tool if you need it]",
            .{m.content.len},
        );
        m.content = marker;
        elided += 1;
    }

    var res = Compacted{ .msgs = out, .elided = elided };
    if (estimateTokens(out) > budget) {
        res.needs_summary = true;
        // Suggest summarizing everything after system and before the window.
        res.summary_upto = protect_from;
    }
    return res;
}

/// Builds the summarize prompt for tier 2 (caller sends it to the LLM).
pub fn summaryPrompt(arena: std.mem.Allocator, msgs: []const chat.ChatMessage) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena,
        \\Summarize this portion of a coding session for a future agent.
        \\Focus on: user goals, decisions made, files touched (paths), tool
        \\results that still matter, and pending work. Be terse (under 300
        \\words). Output only the summary.
        \\
        \\CONVERSATION:
        \\
    );
    for (msgs) |m| {
        try out.appendSlice(arena, "[");
        try out.appendSlice(arena, m.role);
        try out.appendSlice(arena, "] ");
        try out.appendSlice(arena, m.content[0..@min(m.content.len, 2000)]);
        try out.appendSlice(arena, "\n");
    }
    return out.items;
}

test "summaryPrompt incluye roles y trunca mensajes largos" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const msgs = [_]chat.ChatMessage{
        .{ .role = "user", .content = "hola" },
        .{ .role = "tool", .content = "x" ** 5000 },
    };
    const p = try summaryPrompt(arena, &msgs);
    try std.testing.expect(std.mem.indexOf(u8, p, "[user] hola") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "[tool] ") != null);
    // Every message is truncated to 2000 chars.
    try std.testing.expect(p.len < 6000);
}

test "estimate tokens" {
    const msgs = [_]chat.ChatMessage{
        .{ .role = "system", .content = "x" ** 400 }, // 104
        .{ .role = "user", .content = "hello" }, // 5
    };
    const t = estimateTokens(&msgs);
    try std.testing.expect(t > 100 and t < 130);
}

test "elide reduce tool dumps pero protege recientes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const big_tool = "a" ** 4000;
    var msgs = try arena.alloc(chat.ChatMessage, 12);
    msgs[0] = .{ .role = "system", .content = "sys" };
    for (1..12) |i| {
        if (i % 2 == 1) {
            msgs[i] = .{ .role = "assistant", .content = "thinking" };
        } else {
            msgs[i] = .{ .role = "tool", .content = big_tool, .tool_call_id = "c" };
        }
    }

    const before = estimateTokens(msgs);
    const res = try elideTier(arena, msgs, @divTrunc(before, 4)); // very low budget
    try std.testing.expect(res.elided > 0);
    try std.testing.expect(estimateTokens(res.msgs) < before);

    // The last ones (recent_window) were NOT elided. With an assistant(odd)/tool(even)
    // alternation, the last even index (len-2) is a tool.
    const last_tool = res.msgs[res.msgs.len - 2];
    try std.testing.expectEqualStrings(big_tool, last_tool.content);
    // and index len-1 (assistant) is never touched.
    try std.testing.expectEqualStrings("thinking", res.msgs[res.msgs.len - 1].content);
}

test "sin necesidad de summary si elide alcanza" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const big_tool = "a" ** 4000;
    var msgs = try arena.alloc(chat.ChatMessage, 12);
    msgs[0] = .{ .role = "system", .content = "sys" };
    for (1..12) |i| {
        msgs[i] = .{ .role = "tool", .content = big_tool, .tool_call_id = "c" };
    }
    const res = try elideTier(arena, msgs, 9000);
    try std.testing.expect(!res.needs_summary);
    try std.testing.expect(res.elided > 0);
}
