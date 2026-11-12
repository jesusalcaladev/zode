const tui = @import("../tui.zig");
const agent_types = @import("types.zig");

pub const ChatJob = agent_types.ChatJob;

pub const Ops = struct {
    installTurnBashAllowRules: *const fn ([]const []const u8) []const []const u8,
    restoreTurnBashAllowRules: *const fn ([]const []const u8) void,
    expandWorkerCmdSubst: *const fn (*tui.Model, *ChatJob, *[]const u8) bool,
    runWorkerTurn: *const fn (*tui.Model, []const u8, ChatJob.Mode) void,
};

/// Executes one chat job on the worker thread (lifecycle/cleanup owned here).
pub fn run(job: *ChatJob, ops: Ops) void {
    const m = job.model;
    var user_text: []const u8 = job.text;
    defer {
        m.allocator.free(@constCast(user_text));
        m.allocator.destroy(job);
    }

    m.beginWorker();
    defer m.endWorker();

    const prev_turn_rules = ops.installTurnBashAllowRules(job.bash_allow_rules);
    defer ops.restoreTurnBashAllowRules(prev_turn_rules);

    if (!ops.expandWorkerCmdSubst(m, job, &user_text)) return;

    ops.runWorkerTurn(m, user_text, job.mode);
}
