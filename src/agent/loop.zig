const std = @import("std");
const session_mod = @import("../session.zig");
const models_mod = @import("../lib/models.zig");
const hooks_mod = @import("../lib/hooks.zig");

pub const harness_pipeline_marker = "[zode-harness:pipeline]";

/// Appends a harness-authored prompt as a `user` message in the session.
/// The wire of every iteration IS the session, so a prompt that is not appended
/// is one the model cannot read.
pub fn appendHarnessPromptToSession(s: *session_mod.Session, text: []const u8) void {
    s.append(.user, text) catch |err| {
        models_mod.dbg("harness prompt: could not be appended to the session ({t})\n", .{err});
    };
}

/// Pipeline-internal prompt: reaches the model (session/wire) but is marked so
/// the TUI can hide it from the visible transcript.
pub fn appendPipelineHarnessPromptToSession(
    s: *session_mod.Session,
    allocator: std.mem.Allocator,
    text: []const u8,
) void {
    const marked = std.fmt.allocPrint(
        allocator,
        "{s}\n{s}",
        .{ harness_pipeline_marker, text },
    ) catch {
        s.append(.user, text) catch |err| {
            models_mod.dbg("pipeline harness prompt: could not be appended ({t})\n", .{err});
        };
        return;
    };
    defer allocator.free(marked);
    s.append(.user, marked) catch |err| {
        models_mod.dbg("pipeline harness prompt: could not be appended ({t})\n", .{err});
    };
}

/// The user line of the turn goes into the session file FIRST.
pub fn appendUserLineToSession(s: *session_mod.Session, user_text: []const u8) void {
    s.append(.user, user_text) catch {};
    s.flush();
}

/// Ops for end-of-turn steps coupled to agent/TUI/runtime state.
pub fn EndTurnOps(comptime Model: type) type {
    return struct {
        finishAutoCheck: *const fn (*Model) void,
        maybeProposeMemories: *const fn (*Model) void,
        pushTurnSummary: *const fn (*Model) void,
    };
}

/// End-of-turn orchestration: Stop hooks, bench/stats snapshot, then delegated
/// finalization steps (auto-check, memory proposals, turn summary).
pub fn endTurn(
    comptime Model: type,
    m: *Model,
    allocator: std.mem.Allocator,
    io: std.Io,
    hooks_set: *hooks_mod.Set,
    turn_iterations: usize,
    elapsed_ms: u64,
    ttft_ms: u64,
    read_hits: usize,
    capped: bool,
    ops: EndTurnOps(Model),
) void {
    {
        const stop_res = hooks_mod.fire(allocator, hooks_set, .{ .event = .Stop }, io) catch &[_]hooks_mod.RunResult{};
        defer if (stop_res.len > 0) hooks_mod.freeResults(allocator, stop_res);
        _ = hooks_mod.notesText(allocator, stop_res) catch null;
    }
    m.bench.noteTurn(turn_iterations, elapsed_ms, ttft_ms, capped);
    m.bench.read_hits = read_hits;
    ops.finishAutoCheck(m);
    ops.maybeProposeMemories(m);
    ops.pushTurnSummary(m);
}

/// Internal pipeline/control prompts that must reach the model via the session
/// wire but must not be rendered in the TUI transcript.
pub fn isHarnessInternalUserMessage(content: []const u8) bool {
    if (std.mem.startsWith(u8, content, harness_pipeline_marker)) return true;
    // Backward compat with sessions written before the marker existed.
    if (std.mem.startsWith(u8, content, "[Pipeline evidence]")) return true;
    if (std.mem.startsWith(u8, content, "[Pipeline verification]")) return true;
    if (std.mem.startsWith(u8, content, "[Pipeline review]")) return true;
    if (std.mem.startsWith(u8, content, "[Pipeline]")) return true;
    return false;
}
