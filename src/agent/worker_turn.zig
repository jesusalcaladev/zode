const tui = @import("../tui.zig");
const agent_types = @import("types.zig");

pub const ChatJob = agent_types.ChatJob;

pub const Ops = struct {
    pipelineApplies: *const fn (*tui.Model, []const u8) bool,
    runPipeline: *const fn (*tui.Model, []const u8) void,
    runCodeReview: *const fn (*tui.Model, []const u8) void,
    runNormalTurn: *const fn (*tui.Model, []const u8) void,
};

/// Dispatches a worker turn by explicit mode, with auto-pipeline fallback for normal turns.
pub fn run(m: *tui.Model, user_text: []const u8, mode: ChatJob.Mode, ops: Ops) void {
    if (mode == .pipeline) {
        ops.runPipeline(m, user_text);
        return;
    }
    if (mode == .review) {
        ops.runCodeReview(m, user_text);
        return;
    }
    if (ops.pipelineApplies(m, user_text)) {
        ops.runPipeline(m, user_text);
        return;
    }
    ops.runNormalTurn(m, user_text);
}
