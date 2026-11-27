const std = @import("std");
const tui = @import("app").tui;
const session_mod = @import("../session.zig");
const chat = @import("../chat.zig");
const turn_types = @import("turn_types.zig");
const submodel_mod = @import("submodel.zig");

pub const Target = submodel_mod.Target;
pub const TurnCtx = turn_types.TurnCtx;

/// Providers disagree on the name of "the model ran out of output budget":
/// OpenAI-compatible ones say `length`, Anthropic-family ones `max_tokens`.
/// All of them mean the text in this turn is a HALF sentence, not an answer.
fn isTruncatedFinish(reason: []const u8) bool {
    return std.mem.eql(u8, reason, "length") or
        std.mem.eql(u8, reason, "max_tokens") or
        std.mem.eql(u8, reason, "max_output_tokens");
}

pub const Ops = struct {
    finishTps: *const fn (usize, i128, u32) void,
    recordSessionUsage: *const fn (*tui.Model, chat.Usage, chat.ProviderKind, []const u8) void,
    toolCallsJsonFromCalls: *const fn (std.mem.Allocator, []const TurnCtx.Call) ?[]const u8,
    appendHarnessPrompt: *const fn (*tui.Model, []const u8) void,
    refreshContextUsage: *const fn (*tui.Model) void,
    userWantsImplementation: *const fn ([]const u8) bool,
    filesWrittenCount: *const fn () usize,
    toolsRunCount: *const fn () usize,
    elapsedMs: *const fn (i128) u64,
    setStatusWithZo: *const fn (*tui.Model, tui.StatusKind, []const u8) void,
    execToolCalls: *const fn (*tui.Model, *session_mod.Session, *TurnCtx) anyerror!void,
};

/// Finalize streamed turn: record usage, persist assistant output, handle nudges/continuation.
pub fn run(
    m: *tui.Model,
    gpa: std.mem.Allocator,
    s: *session_mod.Session,
    tstate: *TurnCtx,
    pick: Target,
    user_text: []const u8,
    iteration: usize,
    turn_t0: i128,
    ops: Ops,
) !bool {
    const completion: u32 = @intCast(@max(chat.last_usage.completion, 0));
    ops.finishTps(tstate.chars, tstate.stream_start_ns, completion);
    ops.recordSessionUsage(m, chat.last_usage, pick.kind, pick.model);

    m.streamEnd();

    // Reasoning is its own block, NEVER part of `text`: the wire message (and
    // therefore the cache prefix) must carry it once at most. The stream layer
    // suppresses its old reasoning-only fallback when our callback is wired,
    // so a reasoning model cannot put the same bytes in both places.
    if (tstate.reasoning.items.len > 0) m.pushReasoning(tstate.reasoning.items);
    m.reason_live_chars.store(0, .seq_cst);

    const calls_json = if (tstate.calls.items.len > 0)
        ops.toolCallsJsonFromCalls(gpa, tstate.calls.items)
    else
        null;
    if (tstate.text.items.len > 0 or calls_json != null) {
        s.appendAssistant(tstate.text.items, calls_json) catch {};
    }
    s.flush();

    const finish = if (tstate.finish_len > 0) tstate.finish[0..tstate.finish_len] else "";
    const partial = isTruncatedFinish(finish);
    if (partial) ops.setStatusWithZo(m, .warn, "Interrupted");

    if (tstate.calls.items.len == 0) {
        // A truncated reply used to fall through the nudges (they all require
        // empty or very short text) and be reported as `done`, leaving the
        // user with half a sentence. Continue it instead, at most twice so a
        // provider that always truncates cannot spin the loop forever.
        if (partial and m.truncation_continuations < 2) {
            m.truncation_continuations += 1;
            ops.appendHarnessPrompt(m, "Your last reply was cut off at the output limit. Continue exactly where you stopped and finish it in this same turn; do not repeat what you already wrote.");
            ops.refreshContextUsage(m);
            return true;
        }

        // Empty reply nudge.
        if (tstate.text.items.len == 0) {
            if (m.empty_reply_nudges < 3) {
                m.empty_reply_nudges += 1;
                ops.appendHarnessPrompt(m, "Your last reply had no text and no tool call. Continue the task: call the next tool you need, or give your final answer.");
                ops.refreshContextUsage(m);
                return true;
            }
        }

        // Implementation nudge: asked to implement but wrote no files.
        if (ops.filesWrittenCount() == 0 and ops.userWantsImplementation(user_text)) {
            if (m.implementation_nudges < 3) {
                m.implementation_nudges += 1;
                ops.appendHarnessPrompt(m, "The task asks you to implement something, but no files have been created or modified yet. You have only explored — please continue and implement the complete solution, do not stop after just looking at the files.");
                ops.refreshContextUsage(m);
                return true;
            }
        }

        // Nudge: stopped after one read-only tool with a short stub reply.
        if (iteration <= 1 and ops.filesWrittenCount() == 0 and
            ops.toolsRunCount() >= 1 and ops.toolsRunCount() <= 2 and
            tstate.text.items.len > 0 and tstate.text.items.len < 200)
        {
            if (m.implementation_nudges < 3) {
                m.implementation_nudges += 1;
                ops.appendHarnessPrompt(m, "You stopped after only exploring with a short reply and no file changes. If the task needs more work, keep going: read what you listed and act on it. If you are truly done, give the final answer with what you did and what you did not do.");
                ops.refreshContextUsage(m);
                return true;
            }
        }

        ops.refreshContextUsage(m);
        const turn_ms = ops.elapsedMs(turn_t0);
        var buf: [64]u8 = undefined;
        const done_status = std.mem.print(&buf, "done · {d}.{d}s", .{ turn_ms / 1000, (turn_ms % 1000) / 100 }) catch "done";
        ops.setStatusWithZo(m, .done, done_status);
        return false;
    }

    try ops.execToolCalls(m, s, tstate);
    ops.refreshContextUsage(m);
    return true;
}

test "a reply cut at the output limit is recognised across providers" {
    try std.testing.expect(isTruncatedFinish("length"));
    try std.testing.expect(isTruncatedFinish("max_tokens"));
    try std.testing.expect(isTruncatedFinish("max_output_tokens"));
    try std.testing.expect(!isTruncatedFinish("stop"));
    try std.testing.expect(!isTruncatedFinish("tool_calls"));
    try std.testing.expect(!isTruncatedFinish(""));
}
