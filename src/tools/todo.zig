const std = @import("std");
const plan_mod = @import("../lib/plan.zig");

/// Applies the list and returns what has to be told to the model.
///
/// CAREFUL about memory ownership: what comes out of here goes into the
/// `tool_result` of the history (which is long-lived) and into the on-screen
/// plan. The text is a copy in `arena`, never a slice of `Item`'s fixed buffers,
/// because the next call overwrites those.
pub fn toolTodo(obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    var items: [plan_mod.max_items]plan_mod.Item = undefined;
    // `fromValue` and not `parseItems`: the JSON is already parsed (`execute`
    // does it for every tool), and re-parsing 4 KB to pull out 20 strings is
    // throwing work away.
    const parsed = plan_mod.fromValue(.{ .object = obj }, &items) catch |err| switch (err) {
        error.TooManyItems => return error.TooManyPlanItems,
        error.BadPlan => return error.BadPlan,
    };
    if (parsed.len == 0) return error.EmptyPlan;
    return std.fmt.allocPrint(arena, "plan recorded ({d} step{s}). Keep it updated as you go.", .{
        parsed.len,
        if (parsed.len == 1) "" else "s",
    });
}
