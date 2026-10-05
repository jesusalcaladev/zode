/// `todo`: the plan the model writes for itself, and that the user sees on screen.
///
/// Two forms in one call, because the model needs both:
///
/// - `items` — the WHOLE list, which replaces whatever was there. This is what
///   models are trained to emit and it is the right form for "here is the plan".
/// - `update` / `remove` / `add` — single steps addressed by 1-based position. This
///   is the right form for "step 3 is done", and replacement is a bad way to say it:
///   a twelve-step plan means resending twelve steps to change one, and a model that
///   resends them can drop one on the way.
///
/// The parsing lives in `lib/plan.zig` (`parseUpdates`, `parseRemove`, `parseAdd`)
/// and NOT here, because `agent.applyPlanPatch` needs the same three to mutate the
/// `Model`'s plan. Two copies of a parser is two definitions of "1-based", and they
/// drift.
///
/// CAREFUL about memory ownership: what comes out of here goes into the
/// `tool_result` of the history (which is long-lived) and into the on-screen plan.
/// The text is a copy in `arena`, never a slice of `Item`'s fixed buffers, because
/// the next call overwrites those.
const std = @import("std");
const plan_mod = @import("../lib/plan.zig");

pub fn toolTodo(obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    var items: [plan_mod.max_items]plan_mod.Item = undefined;
    var updates: [plan_mod.max_items]plan_mod.StepUpdate = undefined;
    var remove: [plan_mod.max_items]u8 = undefined;
    var add: [plan_mod.max_items]plan_mod.Item = undefined;

    // The parsers validate the whole shape even when this function only needs the
    // counts, so a malformed patch fails HERE with a proper error instead of
    // reaching `applyPatch` half-parsed.
    const n_upd = plan_mod.parseUpdates(obj, &updates) catch |err| return mapErr(err);
    const n_rm = plan_mod.parseRemove(obj, &remove) catch |err| return mapErr(err);
    const n_add = plan_mod.parseAdd(obj, &add) catch |err| return mapErr(err);

    const has_items = obj.get("items") != null or obj.get("todos") != null;
    if (!has_items and n_upd == 0 and n_rm == 0 and n_add == 0) return error.EmptyPlan;

    var text = std.Io.Writer.Allocating.init(arena);
    const w = &text.writer;

    if (has_items) {
        // `fromValue` and not `parseItems`: the JSON is already parsed (`execute`
        // does it for every tool), and re-parsing 4 KB to pull out 20 strings is
        // throwing work away.
        const r = plan_mod.fromValue(.{ .object = obj }, &items) catch |err| return mapErr(err);
        if (r.len == 0) return error.EmptyPlan;
        try w.print("plan recorded ({d} step{s}).", .{ r.len, if (r.len == 1) "" else "s" });
    }
    if (n_upd + n_rm + n_add > 0) {
        try w.writeAll(" Applied to the plan above");
        if (n_upd > 0) try w.print(" ({d} step{s} changed)", .{ n_upd, if (n_upd == 1) "" else "s" });
        if (n_rm > 0) try w.print(" ({d} removed)", .{n_rm});
        if (n_add > 0) try w.print(" ({d} added)", .{n_add});
        try w.writeAll(".");
    }
    try w.writeAll(" Keep it updated as you go: mark a step done as it happens, not at the end.");
    return text.written();
}

fn mapErr(err: anyerror) anyerror {
    return switch (err) {
        error.TooManyPlanItems, error.TooManyItems => error.TooManyPlanItems,
        error.BadPlan => error.BadPlan,
        else => err,
    };
}
