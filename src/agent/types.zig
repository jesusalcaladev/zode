/// Core agent orchestration types shared across `agent.zig` submodules.
///
/// Kept small and stable: this is a boundary module to reduce `agent.zig`
/// monolith size without changing runtime behavior.
const tui = @import("../tui.zig");
const taskloop = @import("../lib/taskloop.zig");

pub const TurnOutcome = struct {
    iterations: usize,
    capped: bool,
    reason: taskloop.StopReason = .done,
};

pub const ChatJob = struct {
    model: *tui.Model,
    text: []const u8,
    /// What the worker runs: the free-running loop (normal), the staged
    /// task pipeline (/pipeline, or the automatic classifier), or a read-only
    /// code review (/code-review).
    mode: Mode = .normal,
    /// Phase 31.2: command-scoped bash allow rules for prompt substitution and
    /// bash tool calls during this turn (e.g. /commit, /pr). Static slice.
    bash_allow_rules: []const []const u8 = &.{},
    /// Phase 31.1: expand `` !`cmd` `` / fenced `!` substitutions in the prompt
    /// before the turn (using bash_allow_rules + permission checks).
    expand_cmdsubst: bool = false,

    pub const Mode = enum { normal, pipeline, review };
};
