const std = @import("std");
const tui = @import("../tui.zig");
const pipeline_mod = @import("../lib/pipeline.zig");

/// Per-turn harness budget reset (shared by normal and pipeline turns).
pub fn resetTurnBudget(m: *tui.Model, io: std.Io) void {
    m.auto_check.resetTurn(&m.bg, io);
    m.asks_this_turn = 0;
    m.plan_touched_this_turn = false;
    m.plan_write_blocked_this_turn = false;
    m.plan_missing_nudges_this_turn = 0;
    m.bg.cancel_all = false;
}

/// Whether the staged pipeline should run for this prompt.
pub fn pipelineApplies(pipeline_env: ?[]const u8, user_text: []const u8) bool {
    const mode = pipeline_mod.modeFrom(pipeline_env);
    return switch (mode) {
        .off => false,
        .always => true,
        .auto => pipeline_mod.classify(user_text).wants_pipeline,
    };
}

/// Drains finished/killed background task notifications and emits harness/UI
/// notifications through callbacks.
pub fn drainBackgroundTaskNotifications(
    comptime Model: type,
    m: *Model,
    arena: std.mem.Allocator,
    appendHarnessPrompt: *const fn (*Model, []const u8) void,
    pushInfo: *const fn (*Model, u32, []const u8) void, // (m, id, status_word)
) void {
    const done = m.bg.drainCompletions(arena);
    for (done) |c| {
        const status = switch (c.state) {
            .killed => "killed",
            .finished => if (c.exit != null and c.exit.? == 0) "finished (exit 0)" else "finished (failed)",
            else => "finished",
        };
        const exit_part = if (c.exit) |e|
            std.fmt.allocPrint(arena, " exit={d}", .{e}) catch ""
        else
            "";
        const path_part = if (c.output_path) |p|
            std.fmt.allocPrint(arena, " Output file: {s}. Use `bash_output` with id {d} to read any unread output (incremental).", .{ p, c.id }) catch
                std.fmt.allocPrint(arena, " Use `bash_output` with id {d} to read output.", .{c.id}) catch ""
        else
            std.fmt.allocPrint(arena, " Use `bash_output` with id {d} to read output.", .{c.id}) catch "";
        const msg = std.fmt.allocPrint(
            m.allocator,
            "[background task finished] job {d} ({s}) {s}{s}.{s}",
            .{ c.id, c.command, status, exit_part, path_part },
        ) catch continue;
        defer m.allocator.free(msg);
        appendHarnessPrompt(m, msg);
        pushInfo(m, c.id, if (c.state == .killed) "killed" else "finished");
    }
}
