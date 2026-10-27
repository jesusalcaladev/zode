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
/// Recent MESSAGES kept verbatim (never elided/summarized).
///
/// It counts messages, not turns, and that is worth knowing: one assistant turn
/// with tools is 1 assistant message plus N tool messages, so a window of 8 can
/// be as little as ONE tool round. That is the real ceiling of a long session, and
/// it is why it is configurable: with a 200k window you can afford to keep more
/// verbatim and elide less.
///
/// `ZODE_RECENT_WINDOW` overrides it.
pub const recent_window: usize = 8;

pub fn recentWindow(env: ?*const std.process.Environ.Map) usize {
    const m = env orelse return recent_window;
    const s = m.get("ZODE_RECENT_WINDOW") orelse return recent_window;
    const n = std.fmt.parseInt(usize, s, 10) catch return recent_window;
    return @max(2, @min(n, 200));
}

pub fn contextLimit(env: ?*const std.process.Environ.Map) i64 {
    return contextLimitFor(env, 0);
}

/// Where the limit came from, so `/context` can say it.
///
/// **It has to agree with `contextLimitFor`, in the SAME order**, and it did not
/// the first time: this checked the model first and that checked the env first,
/// so `/context` answered "the model's own context window" while the number on
/// screen was the env var's. The two are twenty lines apart and the only thing
/// that catches that is a test that compares them, which is why there is one.
///
/// A budget the user cannot trace is a budget they cannot trust: with a fixed
/// 128k it was indistinguishable from "the model has 128k" and from "zode is
/// broken", and the three look the same on screen.
pub const LimitSource = enum { model, env, default_ };

pub fn limitSource(env: ?*const std.process.Environ.Map, model_ctx: u32) LimitSource {
    if (env) |m| {
        if (m.get("ZODE_CONTEXT_LIMIT")) |s| {
            if (std.fmt.parseInt(i64, s, 10)) |_| return .env else |_| {}
        }
    }
    if (model_ctx > 0) return .model;
    return .default_;
}

/// The context window: `ZODE_CONTEXT_LIMIT`, then what the MODEL says it has,
/// then 128k.
///
/// `ZODE_CONTEXT_LIMIT` comes FIRST, and that order is the point: somebody who
/// sets it knows something the catalogue does not — a gateway that truncates, a
/// provider whose published window is not what your account gets. That is the
/// entire reason the variable exists, so putting the model's number ahead of it
/// would make the override useless in the only case it is for.
///
/// The model's own number was the missing input. It was parsed all along
/// (`models.zig` fills `context_length`, `roster.zig` already carries it for the
/// free pool) and the budget ignored it in favour of a constant, so a 1M model
/// compacted at 102k: tier 1 eliding and tier 2 asking an LLM to summarize
/// thousands of tokens early, over and over, for nothing.
pub fn contextLimitFor(env: ?*const std.process.Environ.Map, model_ctx: u32) i64 {
    if (env) |m| {
        if (m.get("ZODE_CONTEXT_LIMIT")) |s| {
            return std.fmt.parseInt(i64, s, 10) catch default_context_limit;
        }
    }
    if (model_ctx > 0) return @intCast(model_ctx);
    return default_context_limit;
}

/// Rough token estimate: ~4 chars/token for code+English mix, plus ~4 tokens
/// of JSON overhead per message. Good enough for budgeting (±15%).
pub fn estimateTokens(msgs: []const chat.ChatMessage) i64 {
    var total: i64 = 0;
    for (msgs) |m| {
        total += messageTokens(m);
    }
    return total;
}

fn messageTokens(m: chat.ChatMessage) i64 {
    var total: i64 = @intCast(m.content.len / 4 + 4);
    if (m.tool_calls_json) |tj| total += @intCast(tj.len / 4 + 8);
    return total;
}

/// How much of the context window compaction aims to stay under.
pub const target_pct: i64 = 80;

/// The most aggressive setting that still makes sense, and why it is a clamp.
///
/// At 0% every request is over budget, so tier 2 fires on EVERY turn: one extra
/// request per turn, forever, to summarize a conversation that is not long. That
/// is the exact waste the "summarize once per session" rule exists to avoid, and a
/// knob that can reach it is not a knob. At 100% nothing is compacted until the
/// provider answers 400 for a too-long request, which is the failure the budget
/// exists to prevent — and the failure you cannot see coming.
pub const min_target_pct: i64 = 10;
pub const max_target_pct: i64 = 95;

pub fn targetPct(env: ?*const std.process.Environ.Map) i64 {
    const m = env orelse return target_pct;
    const s = m.get("ZODE_COMPACT_PCT") orelse return target_pct;
    const n = std.fmt.parseInt(i64, s, 10) catch return target_pct;
    return @max(min_target_pct, @min(n, max_target_pct));
}

/// What automatic compaction is allowed to do.
///
/// The two tiers are not interchangeable and the difference is invisible on screen:
/// tier 1 replaces OLD tool results with a marker (no network, no tokens, and the
/// session file still has everything), while tier 2 asks a model to summarize the
/// old turns (a request, tokens, and a summary that can quietly drop the one detail
/// the model needed). Between "never" and "always, fully" there are three
/// defensible positions, and which one is right depends on what the user is doing:
/// a long read-only session wants `elide`, a coding session wants `full`, and
/// someone who would rather see the provider complain wants `off`.
///
/// `ZODE_COMPACT` = `off` | `elide` | `full` (the default).
pub const Mode = enum { off, elide, full };

pub fn mode(env: ?*const std.process.Environ.Map) Mode {
    const m = env orelse return .full;
    const s = m.get("ZODE_COMPACT") orelse return .full;
    if (std.ascii.eqlIgnoreCase(s, "off") or std.ascii.eqlIgnoreCase(s, "never") or
        std.ascii.eqlIgnoreCase(s, "false") or std.ascii.eqlIgnoreCase(s, "0")) return .off;
    if (std.ascii.eqlIgnoreCase(s, "elide") or std.ascii.eqlIgnoreCase(s, "tier1") or
        std.ascii.eqlIgnoreCase(s, "free")) return .elide;
    return .full;
}

/// The mode that is actually in force: what `/compact` set, else `ZODE_COMPACT`.
///
/// The override is a parameter instead of a module global so the decision is
/// testable with no Model and no environment, and so there is exactly ONE place
/// that answers "what will compaction do" — with three definitions of it (the env,
/// the override and the caller's assumption) every one of them drifts.
pub fn effectiveMode(env: ?*const std.process.Environ.Map, override: ?Mode) Mode {
    return override orelse mode(env);
}

/// One line for `/context` and `/help`: what a given mode actually does.
///
/// It takes the mode and NOT the environment, because the caller knows which mode
/// is in force (it may be a `/compact` override) and reading the env again here is
/// how `/compact off` came to answer "elide, then summarize": the two disagreed and
/// the more reassuring of the two won. The string is about the MODE.
pub fn describe(m: Mode) []const u8 {
    return switch (m) {
        .off => "never: nothing is elided and nothing is summarized, and the request may be rejected for being too long",
        .elide => "elide old tool results only: free, no request, no summary",
        .full => "elide old tool results, then summarize the old turns (one extra request)",
    };
}

/// The compaction budget: `ZODE_COMPACT_PCT`% of the limit.
pub fn budgetTokens(env: ?*const std.process.Environ.Map) i64 {
    return budgetFor(env, 0);
}

pub fn budgetFor(env: ?*const std.process.Environ.Map, model_ctx: u32) i64 {
    return @divTrunc(contextLimitFor(env, model_ctx) * targetPct(env), 100);
}

pub const Compacted = struct {
    msgs: []chat.ChatMessage,
    /// How many tool results were elided (tier 1).
    elided: usize = 0,
    /// Indices (into the ORIGINAL `msgs`) of the tool results tier 1 replaced with
    /// a marker.
    ///
    /// The read cache NEEDS this: it remembers which message each file's content
    /// went into, and if that message is replaced by "tool result elided" the model
    /// no longer has the file. Without this handover it would answer "unchanged,
    /// it is in your context" about content that is not there, which is the worst
    /// thing a cache can do to an agent.
    elided_at: []const usize = &.{},
    /// True if tier 2 (LLM summary) is still needed to reach budget.
    needs_summary: bool = false,
    /// Slice of msgs[0..summary_upto] that tier 2 should summarize
    /// (excluding the system message at index 0).
    summary_upto: usize = 0,
};

/// Tier 1: elide old tool results until under budget (or nothing left to
/// elide). Newest `recent_window` messages are never touched.
pub fn elideTier(
    arena: std.mem.Allocator,
    msgs: []const chat.ChatMessage,
    budget: i64,
    env: ?*const std.process.Environ.Map,
    compaction_mode: Mode,
) !Compacted {
    const out = try arena.alloc(chat.ChatMessage, msgs.len);
    @memcpy(out, msgs);

    var elided: usize = 0;
    var elided_at: std.ArrayList(usize) = .empty;
    // Elide from oldest to newest, skipping system (0) and the recent window.
    // The SAME number decides both what is protected and what gets summarized:
    // with two different numbers the summary could cover messages tier 1 had just
    // protected, and the summary would be built from already-elided text.
    const window = recentWindow(env);
    const protect_from: usize = if (out.len > window) out.len - window else 0;

    var estimated = estimateTokens(out);
    var i: usize = 1; // skip system
    while (i < protect_from) : (i += 1) {
        if (estimated <= budget) break;
        const m = &out[i];
        if (!std.mem.eql(u8, m.role, "tool")) continue;
        if (m.content.len < 256) continue; // not worth it
        const before = messageTokens(m.*);
        const marker = try std.fmt.allocPrint(
            arena,
            "[tool result elided: {d} bytes — re-run the tool if you need it]",
            .{m.content.len},
        );
        m.content = marker;
        estimated -= before - messageTokens(m.*);
        elided += 1;
        try elided_at.append(arena, i);
    }

    var res = Compacted{ .msgs = out, .elided = elided, .elided_at = elided_at.items };
    // `needs_summary` is what ASKS for the second tier, so this is where the mode
    // decides it — and the decision is not the caller's, because the caller has two
    // call sites that would each have to remember. A mode of `elide` still returns
    // the elided view (it is free and it is what keeps the prefix cacheable); it
    // just never spends a request to go further.
    if (estimated > budget and compaction_mode == .full) {
        res.needs_summary = true;
        // Suggest summarizing everything after system and before the window.
        res.summary_upto = protect_from;
    }
    return res;
}

/// Tier 1 as a no-op, for `ZODE_COMPACT=off`.
///
/// A separate function rather than a branch at the call site because there are two
/// call sites (the turn and the subagent) and "off" has to mean the same thing in
/// both: no eliding, no summary, and `needs_summary` false so nothing downstream
/// asks for one.
pub fn nothingElided(msgs: []chat.ChatMessage) Compacted {
    return .{ .msgs = msgs };
}

const summary_input_limit: usize = 16 * 1024;
const summary_message_limit: usize = 2 * 1024;
const summary_header =
    \\Summarize this portion of a coding session for a future agent in compact bullets (under 250 words).
    \\Preserve the user's goal, decisions, exact file paths, useful tool findings, and unfinished work.
    \\Separate confirmed facts from uncertainty. Do not invent missing details.
    \\Assistant tool calls may be included as JSON.
    \\
    \\CONVERSATION:
    \\
;
const summary_omitted = "\n[older middle messages omitted to fit the summary budget]\n";

const SummaryPart = struct {
    content_len: usize,
    calls_len: usize,
};

fn safePrefixLen(text: []const u8, limit: usize) usize {
    var end = @min(text.len, limit);
    while (end > 0 and end < text.len and (text[end] & 0xC0) == 0x80) end -= 1;
    return end;
}

fn summaryPart(m: chat.ChatMessage) SummaryPart {
    const calls = m.tool_calls_json orelse return .{
        .content_len = safePrefixLen(m.content, summary_message_limit),
        .calls_len = 0,
    };
    const calls_reserve = @min(calls.len, 512);
    const content_len = safePrefixLen(m.content, summary_message_limit - calls_reserve);
    const calls_len = safePrefixLen(calls, summary_message_limit - content_len);
    return .{ .content_len = content_len, .calls_len = calls_len };
}

fn summaryRecordBytes(m: chat.ChatMessage) usize {
    const part = summaryPart(m);
    return "[".len + m.role.len + "] ".len + part.content_len + "\n".len +
        (if (m.tool_calls_json != null) "tool_calls: ".len + part.calls_len + "\n".len else 0) +
        (if (part.content_len < m.content.len) " [content clipped]".len else 0) +
        (if (m.tool_calls_json) |calls| if (part.calls_len < calls.len) " [tool calls clipped]".len else 0 else 0);
}

fn appendSummaryRecord(out: *std.ArrayList(u8), arena: std.mem.Allocator, m: chat.ChatMessage) !void {
    const part = summaryPart(m);
    try out.appendSlice(arena, "[");
    try out.appendSlice(arena, m.role);
    try out.appendSlice(arena, "] ");
    try out.appendSlice(arena, m.content[0..part.content_len]);
    if (part.content_len < m.content.len) try out.appendSlice(arena, " [content clipped]");
    try out.append(arena, '\n');
    if (m.tool_calls_json) |calls| {
        try out.appendSlice(arena, "tool_calls: ");
        try out.appendSlice(arena, calls[0..part.calls_len]);
        if (part.calls_len < calls.len) try out.appendSlice(arena, " [tool calls clipped]");
        try out.append(arena, '\n');
    }
}

/// Builds a bounded summary prompt, preserving the start and newest messages.
pub fn summaryPrompt(arena: std.mem.Allocator, msgs: []const chat.ChatMessage) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, summary_header);
    const prefix_end = @min(msgs.len, 2);
    var used = summary_header.len;
    for (msgs[0..prefix_end]) |m| used += summaryRecordBytes(m);

    var suffix_start = msgs.len;
    if (msgs.len > prefix_end) {
        used += summary_omitted.len;
        while (suffix_start > prefix_end) {
            const record_bytes = summaryRecordBytes(msgs[suffix_start - 1]);
            if (record_bytes > summary_input_limit - used) break;
            used += record_bytes;
            suffix_start -= 1;
        }
    }

    for (msgs[0..prefix_end]) |m| try appendSummaryRecord(&out, arena, m);
    if (suffix_start > prefix_end) {
        try out.appendSlice(arena, summary_omitted);
        for (msgs[suffix_start..]) |m| try appendSummaryRecord(&out, arena, m);
    }

    return out.items;
}

test "summaryPrompt includes the roles and truncates long messages" {
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
    try std.testing.expect(p.len <= summary_input_limit);
    try std.testing.expect(std.mem.indexOf(u8, p, "[content clipped]") != null);
}

test "summaryPrompt is globally bounded and keeps the task start and latest work" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const msgs = try arena.alloc(chat.ChatMessage, 40);
    msgs[0] = .{ .role = "user", .content = "original task goal" };
    for (1..39) |i| {
        msgs[i] = .{ .role = "tool", .content = "x" ** 5000 };
    }
    msgs[39] = .{
        .role = "assistant",
        .content = "pending final verification",
        .tool_calls_json = "{\"name\":\"check\"}",
    };

    const prompt = try summaryPrompt(arena, msgs);
    try std.testing.expect(prompt.len <= summary_input_limit);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "original task goal") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "pending final verification") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "tool_calls: {\"name\":\"check\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "messages omitted") != null);
}

test "summaryPrompt truncates only at UTF-8 boundaries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const content = try std.mem.concat(arena, u8, &.{ "a" ** 2047, "é", "tail" });
    const msgs = [_]chat.ChatMessage{.{ .role = "user", .content = content }};
    const prompt = try summaryPrompt(arena, &msgs);
    try std.testing.expect(std.unicode.utf8ValidateSlice(prompt));
}

test "estimate tokens" {
    const msgs = [_]chat.ChatMessage{
        .{ .role = "system", .content = "x" ** 400 }, // 104
        .{ .role = "user", .content = "hello" }, // 5
    };
    const t = estimateTokens(&msgs);
    try std.testing.expect(t > 100 and t < 130);
}

test "elide shrinks the tool dumps but protects the recent ones" {
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
    const res = try elideTier(arena, msgs, @divTrunc(before, 4), null, .full); // very low budget
    try std.testing.expect(res.elided > 0);
    try std.testing.expect(estimateTokens(res.msgs) < before);
    try std.testing.expectEqual(estimateTokens(res.msgs) > @divTrunc(before, 4), res.needs_summary);

    // The last ones (recent_window) were NOT elided. With an assistant(odd)/tool(even)
    // alternation, the last even index (len-2) is a tool.
    const last_tool = res.msgs[res.msgs.len - 2];
    try std.testing.expectEqualStrings(big_tool, last_tool.content);
    // and index len-1 (assistant) is never touched.
    try std.testing.expectEqualStrings("thinking", res.msgs[res.msgs.len - 1].content);
}

test "no summary needed when eliding is enough" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const big_tool = "a" ** 4000;
    var msgs = try arena.alloc(chat.ChatMessage, 12);
    msgs[0] = .{ .role = "system", .content = "sys" };
    for (1..12) |i| {
        msgs[i] = .{ .role = "tool", .content = big_tool, .tool_call_id = "c" };
    }
    const res = try elideTier(arena, msgs, 9000, null, .full);
    try std.testing.expect(!res.needs_summary);
    try std.testing.expect(estimateTokens(res.msgs) <= 9000);
    try std.testing.expect(res.elided > 0);
}

test "elideTier says WHICH messages it took, not only how many" {
    // The reason: the read cache remembers WHICH message the content of each file
    // ended up in, and without knowing which messages were elided it would keep
    // saying "you already have that" about text the model no longer has. A count
    // is not enough.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var msgs: std.ArrayList(chat.ChatMessage) = .empty;
    try msgs.append(arena, .{ .role = "system", .content = "system" });
    // assistant/tool alternating like in the rest of the tests, with big
    // results (the ones under 256 bytes are not elided, by design).
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        try msgs.append(arena, .{ .role = "assistant", .content = "a" });
        try msgs.append(arena, .{ .role = "tool", .content = "x" ** 4000 });
    }

    const res = try elideTier(arena, msgs.items, 1000, null, .full);
    try std.testing.expect(res.elided > 0);
    try std.testing.expectEqual(res.elided, res.elided_at.len);

    // The indices are into the ORIGINALS (which is what the message is in the
    // session), not into the trimmed copy, and they all have role "tool".
    for (res.elided_at) |idx| {
        try std.testing.expect(idx < msgs.items.len);
        try std.testing.expectEqualStrings("tool", msgs.items[idx].role);
    }
}

test "elideTier reports nothing when it elides nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const msgs = [_]chat.ChatMessage{
        .{ .role = "system", .content = "system" },
        .{ .role = "user", .content = "hola" },
    };
    const res = try elideTier(arena, &msgs, 1_000_000, null, .full);
    try std.testing.expectEqual(@as(usize, 0), res.elided);
    try std.testing.expectEqual(@as(usize, 0), res.elided_at.len);
}

test "recentWindow is configurable and bounded" {
    // The window counts MESSAGES, and one assistant turn with tools is 1 + N
    // messages, so the default of 8 can be a single tool round. Somebody with a
    // big window wants to keep more verbatim.
    try std.testing.expectEqual(@as(usize, 8), recentWindow(null));

    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("ZODE_RECENT_WINDOW", "24");
    try std.testing.expectEqual(@as(usize, 24), recentWindow(&map));

    // Nonsense in, default out: a bad environment variable must not elide the
    // whole history.
    try map.put("ZODE_RECENT_WINDOW", "muchos");
    try std.testing.expectEqual(@as(usize, 8), recentWindow(&map));
    // And it cannot be set to something absurd in either direction.
    try map.put("ZODE_RECENT_WINDOW", "0");
    try std.testing.expect(recentWindow(&map) >= 2);
    try map.put("ZODE_RECENT_WINDOW", "100000");
    try std.testing.expect(recentWindow(&map) <= 200);
}

test "a wider window protects more of the tail verbatim" {
    // The point of the knob: the same history with a wider window keeps more
    // recent messages out of the elider.
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    var msgs: std.ArrayList(chat.ChatMessage) = .empty;
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        try msgs.append(arena, .{
            .role = "tool",
            .content = "x" ** 400,
        });
    }

    const narrow = try elideTier(arena, msgs.items, 1000, null, .full);
    var wide_env = std.process.Environ.Map.init(std.testing.allocator);
    defer wide_env.deinit();
    try wide_env.put("ZODE_RECENT_WINDOW", "30");
    const wide = try elideTier(arena, msgs.items, 1000, &wide_env, .full);

    // A wider window protects more, so FEWER messages are elided.
    try std.testing.expect(wide.elided < narrow.elided);
    try std.testing.expect(narrow.summary_upto > wide.summary_upto);
}

test "the context limit is the model's own window, not the 128k constant" {
    // The bug: `context_length` was parsed in `models.zig` and carried by
    // `roster.zig`, and the budget used a constant. A 1M model compacted at 102k,
    // which means tier 1 eliding and tier 2 asking an LLM to summarize thousands
    // of tokens early, over and over, for nothing.
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    // No env var set: the model's number is what there is.
    try std.testing.expectEqual(@as(i64, 128_000), contextLimitFor(&env, 0));
    try std.testing.expectEqual(@as(i64, 200_000), contextLimitFor(&env, 200_000));
    try std.testing.expectEqual(@as(i64, 1_000_000), contextLimitFor(&env, 1_000_000));

    // And the budget follows at 80%.
    try std.testing.expectEqual(@as(i64, 160_000), budgetFor(&env, 200_000));
    try std.testing.expectEqual(@as(i64, 800_000), budgetFor(&env, 1_000_000));
}

test "ZODE_CONTEXT_LIMIT still overrides the model's number" {
    // It is an OVERRIDE and that order is the point: somebody who sets it knows
    // something the catalogue does not — a gateway that truncates, or an account
    // whose real window is not the published one. If the model's number came
    // first, the variable would be useless in the only case it exists for.
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ZODE_CONTEXT_LIMIT", "6000");

    try std.testing.expectEqual(@as(i64, 6000), contextLimitFor(&env, 0));
    try std.testing.expectEqual(@as(i64, 6000), contextLimitFor(&env, 1_000_000));
    try std.testing.expectEqual(@as(i64, 4800), budgetFor(&env, 1_000_000));
}

test "with no model and no env var the limit is EXACTLY what it was before" {
    // The regression this could have caused: every other path must be the old
    // constant. A change in the budget is invisible until a long turn dies on a
    // writer error, and this is the line that proves nothing moved.
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectEqual(@as(i64, 128_000), contextLimitFor(&env, 0));
    try std.testing.expectEqual(@as(i64, 102_400), budgetFor(&env, 0));
    // And with no environment at all either.
    try std.testing.expectEqual(@as(i64, 128_000), contextLimitFor(null, 0));
    // A model number with no env to override it is still the model's number:
    // "no env var" is not the same as "nothing to say about the window".
    try std.testing.expectEqual(@as(i64, 200_000), contextLimitFor(null, 200_000));
}

test "limitSource agrees with contextLimitFor, which is the whole point of it" {
    // It did not, the first time: this checked the model before the env var and
    // that checked the env var first, so `/context` named a source that was not
    // the one that produced the number. A test that only checked each function
    // on its own passed both.
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    // `Environ.Map` has no `remove`, and it needs a non-const map to be
    // deinit'ed, so "no override" is `null` rather than an emptied map.
    const cases = [_]struct { env: ?*const std.process.Environ.Map, ctx: u32 }{
        .{ .env = null, .ctx = 0 },
        .{ .env = null, .ctx = 200_000 },
        .{ .env = &env, .ctx = 0 },
        .{ .env = &env, .ctx = 200_000 },
    };
    for (cases) |c| {
        try env.put("ZODE_CONTEXT_LIMIT", "6000");
        const limit = contextLimitFor(c.env, c.ctx);
        const src = limitSource(c.env, c.ctx);
        // Each source implies its own limit, and nothing else.
        switch (src) {
            .model => try std.testing.expectEqual(@as(i64, 200_000), limit),
            .env => try std.testing.expectEqual(@as(i64, 6000), limit),
            .default_ => try std.testing.expectEqual(@as(i64, 128_000), limit),
        }
    }
}

test "a provider that publishes a 0 window does not turn the limit into 0" {
    // The catalogue only fills `context_length` when the provider sends it. Zero
    // means "does not say", and taking it literally would make the budget 0 and
    // compact the entire history on the first message.
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectEqual(@as(i64, 128_000), contextLimitFor(&env, 0));
    try std.testing.expectEqual(@as(i64, 102_400), budgetFor(&env, 0));
}

test "limitSource says which of the three it was, because the number is automatic" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectEqual(LimitSource.default_, limitSource(&env, 0));
    try std.testing.expectEqual(LimitSource.model, limitSource(&env, 200_000));

    try env.put("ZODE_CONTEXT_LIMIT", "6000");
    try std.testing.expectEqual(LimitSource.env, limitSource(&env, 0));
    // And the env var wins, so it is what /context must name.
    try std.testing.expectEqual(LimitSource.env, limitSource(&env, 200_000));

    // A var that does not parse is not an override: it falls through to the
    // model, and /context must not claim the env when it ignored it.
    try env.put("ZODE_CONTEXT_LIMIT", "not a number");
    try std.testing.expectEqual(LimitSource.model, limitSource(&env, 200_000));
    try std.testing.expectEqual(LimitSource.default_, limitSource(&env, 0));
}

test "ZODE_COMPACT_PCT sets the threshold, and the clamps hold" {
    const E = std.process.Environ.Map;
    var e = E.init(std.testing.allocator);
    defer e.deinit();
    try e.put("ZODE_CONTEXT_LIMIT", "100000");

    // The default is the constant, not a literal written twice. With the env in
    // hand, so the 100k above is the limit that is actually read.
    try std.testing.expectEqual(target_pct, targetPct(null));
    try std.testing.expectEqual(@divTrunc(100000 * target_pct, 100), budgetFor(&e, 0));

    // 0% would make tier 2 fire on EVERY turn (one wasted request per turn
    // forever) and 100% would never compact at all: both are clamped, not obeyed.
    try e.put("ZODE_COMPACT_PCT", "50");
    try std.testing.expectEqual(@as(i64, 50), targetPct(&e));
    try std.testing.expectEqual(@as(i64, 50_000), budgetFor(&e, 0));

    try e.put("ZODE_COMPACT_PCT", "0");
    try std.testing.expectEqual(min_target_pct, targetPct(&e));
    try e.put("ZODE_COMPACT_PCT", "100");
    try std.testing.expectEqual(max_target_pct, targetPct(&e));
    try e.put("ZODE_COMPACT_PCT", "-40");
    try std.testing.expectEqual(min_target_pct, targetPct(&e));
    // Junk falls back to the default rather than to 0: a typo must not turn
    // compaction into something that runs every turn.
    try e.put("ZODE_COMPACT_PCT", "banana");
    try std.testing.expectEqual(target_pct, targetPct(&e));
}

test "ZODE_COMPACT picks the mode, and the default is full" {
    const E = std.process.Environ.Map;
    var e = E.init(std.testing.allocator);
    defer e.deinit();

    try std.testing.expectEqual(Mode.full, mode(null));
    for ([_][]const u8{ "off", "OFF", "never", "false", "0" }) |v| {
        try e.put("ZODE_COMPACT", v);
        try std.testing.expectEqual(Mode.off, mode(&e));
    }
    for ([_][]const u8{ "elide", "tier1", "free" }) |v| {
        try e.put("ZODE_COMPACT", v);
        try std.testing.expectEqual(Mode.elide, mode(&e));
    }
    // Anything else is `full`, on purpose: a typo must not silently DISABLE
    // compaction, which is the direction that costs tokens until the request 400s.
    for ([_][]const u8{ "full", "on", "yes", "banana", "" }) |v| {
        try e.put("ZODE_COMPACT", v);
        try std.testing.expectEqual(Mode.full, mode(&e));
    }
}

test "describe talks about the MODE, so an override cannot be described as the env's" {
    // The three strings, one per mode: they have to differ, because a caller that
    // printed the wrong one is what made `/compact off` claim it would still
    // summarize.
    const off = describe(.off);
    const elide = describe(.elide);
    const full = describe(.full);
    try std.testing.expect(!std.mem.eql(u8, off, elide));
    try std.testing.expect(!std.mem.eql(u8, elide, full));
    try std.testing.expect(!std.mem.eql(u8, off, full));
    // What each one PROMISES, not which words it uses: `off` says it will not
    // summarize (it has to say so, so the word is there and the promise is not) and
    // `full` is the only one that admits to spending a request.
    try std.testing.expect(std.mem.indexOf(u8, off, "extra request") == null);
    try std.testing.expect(std.mem.indexOf(u8, elide, "extra request") == null);
    try std.testing.expect(std.mem.indexOf(u8, full, "extra request") != null);
}

test "the /compact override wins over the env, and null goes back to it" {
    const E = std.process.Environ.Map;
    var e = E.init(std.testing.allocator);
    defer e.deinit();
    try e.put("ZODE_COMPACT", "off");

    try std.testing.expectEqual(Mode.off, effectiveMode(&e, null));
    // An override is what `/compact` sets, and it has to win: the whole point is to
    // change the policy of a session whose env said otherwise.
    try std.testing.expectEqual(Mode.elide, effectiveMode(&e, .elide));
    try std.testing.expectEqual(Mode.full, effectiveMode(&e, .full));
    // And clearing it (null) goes back to the env, not to a remembered value.
    try std.testing.expectEqual(Mode.off, effectiveMode(&e, null));
}

test "elide mode still elides (it is free) but never asks for a summary" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // MORE than `recent_window` messages, and that is not a detail: `elideTier`
    // protects the newest `recent_window` and never touches them, so with 4 messages
    // and a window of 8 `protect_from` is 0 and the loop below it never runs. A test
    // with a short list does not check that eliding works, it checks that it correctly
    // does nothing.
    const fat = "x" ** 4000;
    var list: [12]chat.ChatMessage = undefined;
    list[0] = .{ .role = "system", .content = "sys" };
    for (1..12) |i| {
        list[i] = if (i <= 3)
            .{ .role = "tool", .content = fat }
        else
            .{ .role = "user", .content = "recent turn" };
    }

    // A budget LOW enough that eliding alone is not enough: with a budget the elided
    // markers already fit in, `needs_summary` is false for `full` too and the test
    // would be comparing two identical results and calling it a pass.
    const full = try elideTier(arena, &list, 50, null, .full);
    const elide = try elideTier(arena, &list, 50, null, .elide);

    // Both tiers elide: tier 1 costs no request, so `elide` does not throw it away.
    try std.testing.expect(full.elided > 0);
    try std.testing.expectEqual(full.elided, elide.elided);
    // And the only difference is the request that `elide` refuses to spend.
    try std.testing.expect(full.needs_summary);
    try std.testing.expect(!elide.needs_summary);
}
