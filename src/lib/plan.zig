const std = @import("std");

/// The task list the model writes for itself (`todo`) and that the user sees
/// ON SCREEN.
///
/// ## Why a tool and not a block of text
///
/// The model already had `think` to plan with, and with that the answer of a
/// 20-tool-call agent is a wall of text where you cannot tell what is left.
/// What this is after is being able to answer "how much is left and what is it
/// on?" at ANY moment by reading one row, with no Ask Mode.
///
/// ## Semantics: full replacement, not a patch
///
/// Every call sends the WHOLE list. That is what Claude Code does with
/// `TodoWrite` and it is not arbitrary: patching differs per model, and with a
/// partial list the server cannot know what was removed. With a full list,
/// "drop step 3" is "send 4 steps without the 3rd".
///
/// ## Why a fixed array
///
/// It lives in the `Model`, which the UI reads every frame and the worker
/// writes from another thread. An `ArrayList` with a lock already forces you to
/// take the lock just to paint; an array of 20 entries makes the draw a loop
/// with no allocation. The ceiling is 20 steps: a longer plan is not a plan,
/// it is a document.
pub const max_items = 20;
pub const text_max = 120;

pub const Status = enum {
    pending,
    in_progress,
    done,

    pub fn parse(s: []const u8) ?Status {
        if (std.mem.eql(u8, s, "pending")) return .pending;
        if (std.mem.eql(u8, s, "in_progress") or std.mem.eql(u8, s, "in-progress")) return .in_progress;
        if (std.mem.eql(u8, s, "done") or std.mem.eql(u8, s, "completed")) return .done;
        return null;
    }

    pub fn glyph(self: Status) []const u8 {
        return switch (self) {
            .pending => "☐",
            .in_progress => "◐",
            .done => "☑",
        };
    }
};

pub const Item = struct {
    text: [text_max]u8 = undefined,
    len: u8 = 0,
    status: Status = .pending,

    pub fn textOf(self: *const Item) []const u8 {
        return self.text[0..self.len];
    }
};

/// The list. No allocator: the texts are fixed-size buffers.
pub const Plan = struct {
    items: [max_items]Item = undefined,
    len: u8 = 0,
    /// What it had before the last call. To be able to say "2/4 → 3/4"
    /// and to detect that the model changed nothing.
    prev_done: u8 = 0,
    prev_len: u8 = 0,

    pub fn init() Plan {
        return .{};
    }

    pub fn isEmpty(self: *const Plan) bool {
        return self.len == 0;
    }

    pub fn doneCount(self: *const Plan) u8 {
        var n: u8 = 0;
        for (self.items[0..self.len]) |it| {
            if (it.status == .done) n += 1;
        }
        return n;
    }

    /// The step in flight, or the first pending one if none was marked.
    ///
    /// Used to decide which one is highlighted. And it has a criterion that is
    /// not obvious: if there is NOTHING `in_progress` but pending steps are
    /// left, the first pending one is highlighted. The model often does not
    /// mark the step in flight (it does not need to), and having nothing
    /// highlighted makes the plan look dead.
    pub fn currentIndex(self: *const Plan) ?u8 {
        for (self.items[0..self.len], 0..) |it, i| {
            if (it.status == .in_progress) return @intCast(i);
        }
        for (self.items[0..self.len], 0..) |it, i| {
            if (it.status == .pending) return @intCast(i);
        }
        return null;
    }

    pub fn allDone(self: *const Plan) bool {
        if (self.len == 0) return false;
        return self.doneCount() == self.len;
    }

    /// Empties the list. Used by `/new` and by the session restart: a plan from
    /// the previous session has nothing to do with this one.
    pub fn clear(self: *Plan) void {
        self.len = 0;
        self.prev_len = 0;
        self.prev_done = 0;
    }

    /// Applies a new list. Returns a code for the history message: the caller
    /// decides whether it says anything (a "no change" per tool call is noise).
    pub const Applied = enum { changed, same, empty };

    pub fn apply(self: *Plan, new_items: []const Item, n: u8) Applied {
        // The list rules: it is compared BEFORE touching anything so that "same as
        // before" can be said with no history and no allocations.
        var same = n == self.len;
        if (same) {
            for (new_items[0..n], self.items[0..self.len]) |a, b| {
                if (a.status != b.status or !std.mem.eql(u8, a.textOf(), b.textOf())) {
                    same = false;
                    break;
                }
            }
        }
        // An empty list over an empty plan is NOT a change (the model would repeat
        // "plan cleared" on every call), but emptying a plan that HAD items IS
        // one: it is the signal that it is over.
        if (n == 0 and self.len == 0) return .same;
        if (same) return .same;

        self.prev_len = self.len;
        self.prev_done = self.doneCount();
        // CAREFUL: the index is local on purpose. The first version wrote
        // `self.items[self.len] = it` inside the loop, and since `self.len` is
        // only updated at the end, EVERY iteration landed in slot 0: at the end
        // the plan was one step repeated. And because `Item.text` is a
        // fixed-size buffer, the plan was drawn with garbage instead of text.
        var i: u8 = 0;
        while (i < n) : (i += 1) self.items[i] = new_items[i];
        self.len = n;
        return if (n == 0) .empty else .changed;
    }

    /// A one-line summary for the history and for the status.
    ///
    /// `arena` because it is an `allocPrint`: the text lives as long as the turn.
    pub fn summary(self: *const Plan, arena: std.mem.Allocator) []const u8 {
        if (self.len == 0) return "plan cleared";
        const d = self.doneCount();
        if (self.allDone()) {
            return std.fmt.allocPrint(arena, "plan: {d}/{d} done · all steps finished", .{ self.len, self.len }) catch "plan done";
        }
        return std.fmt.allocPrint(arena, "plan: {d}/{d} done · next: {s}", .{
            d,
            self.len,
            if (self.currentIndex()) |i| self.items[i].textOf() else "",
        }) catch "plan updated";
    }
};

/// What the parse returns: the list and how many steps there are.
pub const Result = struct {
    items: [max_items]Item,
    len: u8,
};

pub const ParseError = error{ BadPlan, TooManyItems };

/// Parses the `todo` list out of the JSON.
///
/// The `arena` is only for `std.json`'s tree (the strings of the result are
/// copied into `Item`'s fixed buffers before returning, and the parse does not
/// deserialize... actually: `parseFromSliceLeaky` does not need to
/// deserialize). With a FIXED 16 KB buffer this would fail on a 20-step plan
/// with long texts, and the model would see "I did not understand the plan"
/// for no reason, so the caller passes a real allocator.
pub fn parseItems(arena: std.mem.Allocator, args_json: []const u8, out: *[max_items]Item) ParseError!Result {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch
        return error.BadPlan;
    return fromValue(parsed, out);
}

/// The same, but from already-parsed JSON.
///
/// It exists because whoever holds the `ObjectMap` (the tool, which already
/// parsed the args for the rest of the tools) should not have to parse 2 KB of
/// JSON again just to get 20 strings out.
pub fn fromValue(value: std.json.Value, out: *[max_items]Item) ParseError!Result {
    if (value != .object) return error.BadPlan;
    const maybe = value.object.get("items") orelse value.object.get("todos") orelse
        return error.BadPlan;
    const arr = switch (maybe) {
        .array => |a| a,
        else => return error.BadPlan,
    };
    if (arr.items.len > max_items) return error.TooManyItems;

    var n: u8 = 0;
    for (arr.items) |v| {
        if (v != .object) return error.BadPlan;
        const cmaybe = v.object.get("content") orelse v.object.get("text") orelse
            v.object.get("task") orelse return error.BadPlan;
        const content = switch (cmaybe) {
            .string => |s| s,
            else => return error.BadPlan,
        };
        // An unknown status falls back to `pending` instead of failing: the step is
        // not wrong, it is mislabelled, and throwing the error would force a
        // retry of the call.
        const st: Status = if (v.object.get("status")) |sv| blk: {
            if (sv != .string) break :blk .pending;
            break :blk Status.parse(sv.string) orelse .pending;
        } else .pending;

        const trimmed = std.mem.trim(u8, content, " \t");
        if (trimmed.len == 0) return error.BadPlan;
        var it = Item{ .status = st };
        const cp = @min(trimmed.len, text_max);
        @memcpy(it.text[0..cp], trimmed[0..cp]);
        it.len = @intCast(cp);
        out[n] = it;
        n += 1;
    }
    return .{ .items = out.*, .len = n };
}

// ── tests ─────────────────────────────────────────────────────

test "Status.parse accepts what models actually write" {
    // Models do not invent a vocabulary: they write "in-progress" and "completed"
    // as often as "in_progress" and "done", with hyphens and underscores
    // because the tool's JSON is written by hand.
    try std.testing.expectEqual(Status.pending, Status.parse("pending").?);
    try std.testing.expectEqual(Status.in_progress, Status.parse("in_progress").?);
    try std.testing.expectEqual(Status.in_progress, Status.parse("in-progress").?);
    try std.testing.expectEqual(Status.done, Status.parse("done").?);
    try std.testing.expectEqual(Status.done, Status.parse("completed").?);
    // And what it does not know: null, not a panic and not a silent pending.
    try std.testing.expect(Status.parse("en curso") == null);
    try std.testing.expect(Status.parse("") == null);
}

test "parseItems: the shape the model sends" {
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    var out: [max_items]Item = undefined;

    const args =
        \\{"items":[
        \\ {"content":"leer el roadmap","status":"done"},
        \\ {"content":"implementar la tool","status":"in_progress"},
        \\ {"content":"escribir el test","status":"pending"}
        \\]}
    ;
    const r = try parseItems(arena, args, &out);
    try std.testing.expectEqual(@as(u8, 3), r.len);
    try std.testing.expectEqualStrings("leer el roadmap", r.items[0].textOf());
    try std.testing.expectEqual(Status.done, r.items[0].status);
    try std.testing.expectEqual(Status.in_progress, r.items[1].status);
    try std.testing.expectEqualStrings("escribir el test", r.items[2].textOf());
}

test "parseItems: accepts `todos`, `text` and `task` as aliases" {
    // REAL variation between models: the same field name changed by the same
    // model between two calls. If only one is accepted, the plan empties with
    // nobody understanding why.
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    var out: [max_items]Item = undefined;

    const a = try parseItems(arena, "{\"todos\":[{\"text\":\"a\"}]}", &out);
    try std.testing.expectEqual(@as(u8, 1), a.len);
    try std.testing.expectEqualStrings("a", a.items[0].textOf());

    const b = try parseItems(arena, "{\"items\":[{\"task\":\"b\"}]}", &out);
    try std.testing.expectEqualStrings("b", b.items[0].textOf());
}

test "parseItems: an unknown status falls back to pending, not to an error" {
    // The rare but real case: the model writes "doing" or "finished". Throwing
    // the error would force a retry of the call, and the step is not wrong: it
    // is mislabelled. It is accepted as pending and the model sees the right
    // list.
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    var out: [max_items]Item = undefined;
    const r = try parseItems(
        astate.allocator(),
        "{\"items\":[{\"content\":\"x\",\"status\":\"finished\"}]}",
        &out,
    );
    try std.testing.expectEqual(Status.pending, r.items[0].status);
}

test "parseItems: what is WRONG is rejected with a reason" {
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const a = astate.allocator();
    var out: [max_items]Item = undefined;

    // CAREFUL: `expectError` does NOT work here. It prints the returned value when
    // the result is NOT the expected error, and that value is an array of
    // `Item` with `undefined` buffers: formatting the enum blows up with
    // "invalid enum value" and the test panics instead of failing with a
    // message. Hence `wantPlanErr`, which only looks at the error.
    try wantPlanErr(a, "no json", &out, error.BadPlan);
    try wantPlanErr(a, "[]", &out, error.BadPlan);
    try wantPlanErr(a, "{}", &out, error.BadPlan);
    try wantPlanErr(a, "{\"items\":\"uno\"}", &out, error.BadPlan);
    // A step with no text: a checkbox with nothing next to it is not a step.
    try wantPlanErr(a, "{\"items\":[{\"content\":\"   \"}]}", &out, error.BadPlan);
    // And more than 20 is an error, not a silent trim: if the model goes over, it
    // has to know that not everything fits. Silent would be worse, because the
    // plan would look short for no reason and the model would not know what was
    // lost.
    var many: [2048]u8 = undefined;
    try wantPlanErr(a, manyItems(21, &many), &out, error.TooManyItems);
    // Exactly 20 fits, and fits whole.
    const r = try parseItems(a, manyItems(20, &many), &out);
    try std.testing.expectEqual(@as(u8, 20), r.len);
    try std.testing.expectEqualStrings("paso 20", r.items[19].textOf());
}

test "Plan.apply: the complete list, and whether anything changed" {
    var p = Plan.init();
    var new: [max_items]Item = undefined;
    // An empty list over an empty plan is not a change: if it were, every call with
    // the empty list would repeat "plan cleared" in the history.
    try std.testing.expectEqual(Plan.Applied.same, p.apply(&new, 0));
    try std.testing.expect(p.isEmpty());

    const a = try two("leer", "escribir", .pending, .in_progress);
    try std.testing.expectEqual(Plan.Applied.changed, p.apply(&a, 2));
    try std.testing.expectEqual(@as(u8, 2), p.len);
    try std.testing.expectEqual(@as(u8, 0), p.doneCount());

    // Repeating the SAME list is not a change: if it were, every tool call would
    // repeat "plan: 0/2" in the history and the message would lose its point.
    try std.testing.expectEqual(Plan.Applied.same, p.apply(&a, 2));

    // Changing a status IS a change, even if the text does not change.
    const b = try two("leer", "escribir", .done, .in_progress);
    try std.testing.expectEqual(Plan.Applied.changed, p.apply(&b, 2));
    try std.testing.expectEqual(@as(u8, 1), p.doneCount());
    // What there was BEFORE the change, which is what allows saying "1/2 -> 2/2"
    // in the history instead of just "2/2".
    try std.testing.expectEqual(@as(u8, 2), p.prev_len);
    try std.testing.expectEqual(@as(u8, 0), p.prev_done);

    // Emptying a plan that had items IS a change: it is the signal of "it's over".
    try std.testing.expectEqual(Plan.Applied.empty, p.apply(&new, 0));
    try std.testing.expect(p.isEmpty());
    try std.testing.expect(!p.allDone()); // an empty plan is not "done"
}

test "Plan.currentIndex: the step in progress, or the first pending one" {
    var p = Plan.init();
    // Empty: nothing to highlight.
    try std.testing.expect(p.currentIndex() == null);

    const a = try three("a", "b", "c", .done, .pending, .pending);
    try std.testing.expectEqual(Plan.Applied.changed, p.apply(&a, 3));
    // The model marked none: the first pending one is highlighted, because a plan
    // with nothing highlighted looks like a stalled plan.
    try std.testing.expectEqual(@as(u8, 1), p.currentIndex().?);

    const b = try three("a", "b", "c", .done, .pending, .in_progress);
    try std.testing.expectEqual(Plan.Applied.changed, p.apply(&b, 3));
    // Now there is one in flight, and it wins.
    try std.testing.expectEqual(@as(u8, 2), p.currentIndex().?);

    const c = try three("a", "b", "c", .done, .done, .done);
    try std.testing.expectEqual(Plan.Applied.changed, p.apply(&c, 3));
    // All done: there is no current step (the summary says "all steps finished").
    try std.testing.expect(p.currentIndex() == null);
}

test "long text is truncated without overflowing the buffer" {
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    var out: [max_items]Item = undefined;
    var args: [text_max * 2]u8 = undefined;
    var w: std.Io.Writer = .fixed(&args);
    try w.print("{{\"items\":[{{\"content\":\"", .{});
    for (0..text_max * 2 - 32) |_| try w.writeByte('x');
    try w.print("\"}}]}}", .{});

    const r = try parseItems(astate.allocator(), w.buffered(), &out);
    try std.testing.expectEqual(@as(u8, 1), r.len);
    // Cut to `text_max`: in the plan "reading this whole thing on one row" reads
    // as a single line, and the long text is in the turn's history.
    try std.testing.expectEqual(@as(u8, text_max), r.items[0].len);
}

test "the summary says what is missing, not a percentage" {
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    var p = Plan.init();

    const a = try three("leer el roadmap", "implementar", "testear", .done, .in_progress, .pending);
    _ = p.apply(&a, 3);
    const s = p.summary(arena);
    try std.testing.expect(std.mem.indexOf(u8, s, "1/3") != null);
    // The name of the next step: that is what turns the plan into something
    // actionable at a glance.
    try std.testing.expect(std.mem.indexOf(u8, s, "implementar") != null);

    const b = try three("leer el roadmap", "implementar", "testear", .done, .done, .done);
    _ = p.apply(&b, 3);
    try std.testing.expect(std.mem.indexOf(u8, p.summary(arena), "all steps finished") != null);

    p.clear();
    try std.testing.expectEqualStrings("plan cleared", p.summary(arena));
}

// ── test helpers ──────────────────────────────────────────────

/// Like `expectError` but without printing the value on success (here it is an
/// array with uninitialized buffers, which blows up the enum formatting).
fn wantPlanErr(
    arena: std.mem.Allocator,
    json: []const u8,
    out: *[max_items]Item,
    want: ParseError,
) !void {
    if (parseItems(arena, json, out)) |_| {
        std.debug.print("expected {t} but the plan was accepted\n", .{want});
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expectEqual(want, err);
    }
}

fn item(text: []const u8, status: Status) Item {
    var it = Item{ .status = status };
    const cp = @min(text.len, text_max);
    @memcpy(it.text[0..cp], text[0..cp]);
    it.len = @intCast(cp);
    return it;
}

fn two(a: []const u8, b: []const u8, sa: Status, sb: Status) ![max_items]Item {
    var arr: [max_items]Item = undefined;
    arr[0] = item(a, sa);
    arr[1] = item(b, sb);
    return arr;
}

fn three(
    a: []const u8,
    b: []const u8,
    c: []const u8,
    sa: Status,
    sb: Status,
    sc: Status,
) ![max_items]Item {
    var arr: [max_items]Item = undefined;
    arr[0] = item(a, sa);
    arr[1] = item(b, sb);
    arr[2] = item(c, sc);
    return arr;
}

fn manyItems(n: usize, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print("{{\"items\":[", .{}) catch return "";
    for (0..n) |i| {
        w.print("{s}{{\"content\":\"paso {d}\"}}", .{ if (i > 0) "," else "", i + 1 }) catch return "";
    }
    w.print("]}}", .{}) catch return "";
    return w.buffered();
}
