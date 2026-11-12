/// Plan approval gate: the developer says yes or no to a plan-mode draft.
///
/// Pure decision logic lives here (testable without TUI). The dialog/UI flow
/// stays in `agent.zig` because it needs `tui.Model` and mode changes.

const std = @import("std");

pub const approve_option = "Approve — implement it now";
pub const revise_option = "Revise — change the plan first";

/// What the model is told after the developer approved. Owned by the caller.
pub const approved_text =
    "The user APPROVED the plan, and zode has already switched itself out of plan mode " ++
    "(you are in Build mode: edits and commands are allowed). Implement the plan now: " ++
    "follow the plan's objective, approach, and guardrails; work through the steps in order, " ++
    "apply each step's how/verify notes, verify as you go, and report what changed, what was " ++
    "verified, and any risks. Do not ask for approval again — it has been given.";

/// The revision nudge's shape. `{s}` is the user's own words: a rejection with
/// no reason is the one thing the model cannot act on.
pub const revise_fmt =
    "The user did NOT approve the plan yet. They said: \"{s}\"\n" ++
    "Revise the plan with the `todo` tool (update objective/approach/guardrails and the steps " ++
    "so it is concrete: what will be done, how, and what must not break), then end your turn " ++
    "to present it again. You are still in PLAN MODE: do not edit anything until it is approved.";

/// What an approval answer means, decided WITHOUT a TUI so it can be tested.
///
/// - no answer at all (ESC or timeout) → `skip`: end the turn with no nudge.
///   A user who walked away must not come back to a loop that kept asking —
///   that is how a plan gate turns into a wall.
/// - the approve option (prefix match) or an obvious typed yes → `approve`.
/// - EVERYTHING else — the revise option or the user's own typed words →
///   `revise`, and those words travel with the nudge as the reason.
pub const Decision = enum { approve, revise, skip };

pub fn decide(answer: ?[]const u8) Decision {
    const a = answer orelse return .skip;
    const t = std.mem.trim(u8, a, " \t\r\n");
    if (t.len == 0) return .skip;
    if (std.mem.startsWith(u8, t, "Approve")) return .approve;
    if (std.ascii.eqlIgnoreCase(t, "approve") or
        std.ascii.eqlIgnoreCase(t, "yes") or
        std.ascii.eqlIgnoreCase(t, "y")) return .approve;
    return .revise;
}

test "planGateDecision: approve option and yes" {
    try std.testing.expectEqual(Decision.approve, decide("Approve — implement it now"));
    try std.testing.expectEqual(Decision.approve, decide("approve"));
    try std.testing.expectEqual(Decision.approve, decide("yes"));
    try std.testing.expectEqual(Decision.approve, decide("Y"));
}

test "planGateDecision: skip on empty/timeout" {
    try std.testing.expectEqual(Decision.skip, decide(null));
    try std.testing.expectEqual(Decision.skip, decide(""));
    try std.testing.expectEqual(Decision.skip, decide("   "));
}

test "planGateDecision: revise on other answers" {
    try std.testing.expectEqual(Decision.revise, decide("Revise — change the plan first"));
    try std.testing.expectEqual(Decision.revise, decide("add tests first"));
}
