/// The `goal` tool: how the model tells the harness whether the objective is reached.
///
/// ## Why the model has to be the one to decide
///
/// The harness knows how many iterations it has spent. It does not know whether the
/// package weighs under 10 KB, whether the test passes, or whether the thing it was
/// asked for exists. Only the model can see the evidence, and only by committing to a
/// claim — which is a different act from writing a paragraph that sounds finished.
///
/// A harness that guessed would either stop on unfinished work or never stop. So this
/// is a tool with two answers and both of them are checked:
///
/// - `met` with the summary. Ends the turn, and the summary is what the user reads.
/// - `blocked` with `what_would_unblock`. Ends the turn, CALMLY, and the second field
///   is required.
///
/// ## Why `what_would_unblock` is required and not optional
///
/// Without it, `blocked` is indistinguishable from "I would rather not", and the
/// harness has no way to tell a real blocker from a shrug — so it would accept giving
/// up as a fact. The field is the whole safety of the feature: an unbounded loop that
/// can also STOP is a loop you can leave running, and it only means something if the
/// stop is justified.
///
/// ## Why it needs no `Model`
///
/// The verdict is applied by `agent.applyGoalCall`, in the loop, for the same reason
/// `todo` is: the state lives in the Model. All this does is say what it read, so the
/// model sees the effect of its own call and knows the turn will end.
const std = @import("std");
const common = @import("common.zig");
const goal_lib = @import("../lib/goal.zig");

pub fn toolGoal(obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const v = goal_lib.parseVerdict(obj, arena) catch |err| switch (err) {
        error.MissingStatus => return "goal needs a `status`: `met` or `blocked`.",
        // A PLAIN string, not `allocPrint`: the JSON examples in it are full of braces
        // and a format string reads every one of them as a placeholder, which does not
        // compile and is a miserable thing to debug.
        error.BadStatus => return "`status` must be `met` or `blocked`, and nothing else ends the turn, so " ++
            "there is no third option to invent. Send one of these two shapes: " ++
            "{\"status\":\"met\",\"summary\":\"what you finished and how you know\"} or " ++
            "{\"status\":\"blocked\",\"summary\":\"why not\",\"what_would_unblock\":\"the one thing that would change it\"}",
        error.MissingSummary => return "goal needs a `summary`: what you finished and how you know, or why it cannot be done here.",
        error.SummaryTooShort => return "the `summary` is too short to be one. Say what happened and what proves it.",
        error.MissingUnblock => return "`blocked` needs `what_would_unblock`: the one thing that would change the answer. Without it there is no difference between a real blocker and giving up, and the harness cannot tell them apart.",
    };

    return switch (v.status) {
        .met => std.fmt.allocPrint(
            arena,
            "recorded: the goal is MET. The turn ends here. Summary: {s}",
            .{v.summary},
        ),
        .blocked => std.fmt.allocPrint(
            arena,
            "recorded: the goal is BLOCKED. The turn ends here and stops spending iterations. Reason: {s}\\nWould unblock it: {s}",
            .{ v.summary, v.unblock },
        ),
        .none => "nothing recorded.",
    };
}
