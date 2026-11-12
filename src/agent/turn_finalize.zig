const std = @import("std");
const tui = @import("../tui.zig");
const session_mod = @import("../session.zig");
const chat = @import("../chat.zig");
const turn_types = @import("turn_types.zig");
const submodel_mod = @import("submodel.zig");

pub const Target = submodel_mod.Target;
pub const TurnCtx = turn_types.TurnCtx;

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

    const calls_json = if (tstate.calls.items.len > 0)
        ops.toolCallsJsonFromCalls(gpa, tstate.calls.items)
    else
        null;
    if (tstate.text.items.len > 0 or calls_json != null) {
        s.appendAssistant(tstate.text.items, calls_json) catch {};
    }
    s.flush();

    const partial = tstate.finish_len > 0 and
        std.mem.eql(u8, tstate.finish[0..tstate.finish_len], "length");
    if (partial) ops.setStatusWithZo(m, .warn, "interrupted");

    if (tstate.calls.items.len == 0) {
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
        const done_status = std.fmt.bufPrint(&buf, "done · {d}.{d}s", .{ turn_ms / 1000, (turn_ms % 1000) / 100 }) catch "done";
        ops.setStatusWithZo(m, .done, done_status);
        return false;
    }

    try ops.execToolCalls(m, s, tstate);
    ops.refreshContextUsage(m);
    return true;
}
