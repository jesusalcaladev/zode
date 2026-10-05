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
/// ## Semantics: full replacement AND in-place patches
///
/// `items` replaces the whole list, which is what Claude Code does with
/// `TodoWrite` and what models are trained to emit. It stays the base form.
///
/// On top of it, `update`, `remove` and `add` address single steps by their
/// 1-based position. They exist because replacement has a cost that only shows up
/// in a long task: marking step 3 done means resending twelve steps, and a model
/// that resends them can drop one. The original argument for replacement — "with a
/// partial list the server cannot know what was removed" — is about a REMOTE
/// server. This list is in this process. The harness is the one that removes it,
/// so it knows.
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

/// A change to ONE step, addressed by its 1-based position.
///
/// Why this exists when `apply` already replaces the whole list: with only
/// replacement, marking step 3 done means resending all twelve steps, and a model
/// that resends them can drop one. The list lives in this process, in the `Model`,
/// so the argument the doc comment above makes for full replacement — "with a
/// partial list the server cannot know what was removed" — does not apply here.
/// The harness knows exactly what was removed, because it is the one that removed
/// it.
pub const StepUpdate = struct {
    /// 1-based. Zero is rejected rather than clamped: an index of 0 is an off-by-one
    /// in the model's counting, and silently updating step 1 when it meant "none"
    /// is worse than telling it the index was wrong.
    index: u8,
    /// null = leave the text as it is.
    text: ?[]const u8 = null,
    /// null = leave the status as it is.
    status: ?Status = null,
};

/// What a patch did, for the message the model reads and the tests.
pub const PatchResult = struct {
    updated: u8 = 0,
    removed: u8 = 0,
    added: u8 = 0,
    /// Indices the model sent that do not exist. Reported instead of ignored: a
    /// silent no-op reads as "the step was marked done", and the model will not
    /// send it again.
    unknown: u8 = 0,

    pub fn anyChange(self: PatchResult) bool {
        return self.updated > 0 or self.removed > 0 or self.added > 0;
    }
};

/// Applies changes to the CURRENT list, in place.
///
/// The order is fixed and it is the only thing that makes indices unambiguous:
/// removals first, then updates, then additions. So an index in `update` names a
/// step that survived `remove`, and an index in `add` has nothing to do with the
/// positions at all.
///
/// `remove` is applied from the highest index down. Going upwards would shift every
/// later step by one and remove the wrong ones — the bug this order exists to make
/// impossible rather than unlikely.
pub fn applyPatch(
    self: *Plan,
    updates: []const StepUpdate,
    remove: []const u8,
    add: []const Item,
    add_n: u8,
) PatchResult {
    var r = PatchResult{};
    const before_len = self.len;
    const before_done = self.doneCount();

    // ── removals, HIGHEST INDEX FIRST ──
    //
    // The sort is not an optimisation, it is what makes the indices mean what the
    // model thinks they mean. Removing index 1 first shifts every later step down
    // by one, so a `remove: [1, 3]` sent in that order then tries to remove what is
    // now step 2 — the wrong step. The doc comment claimed this order and the code
    // did not do it; a test that removes 1 and 3 and expects "fix it" and
    // "check it" is what caught it.
    //
    // Insertion sort, on a fixed array of at most `max_items` entries: the data is
    // tiny and this is not a place where an allocator should appear.
    var order: [max_items]u8 = undefined;
    var n_ord: usize = 0;
    for (remove) |raw| {
        // Out-of-range indices are counted, not clamped: a `remove: [9]` on a
        // three-step plan is the model miscounting, and clamping it to the last
        // step would delete something it never named.
        if (raw < 1 or raw > self.len) {
            r.unknown += 1;
            continue;
        }
        var j = n_ord;
        while (j > 0 and order[j - 1] < raw) : (j -= 1) order[j] = order[j - 1];
        order[j] = raw;
        n_ord += 1;
    }
    for (order[0..n_ord]) |raw| {
        const i = raw - 1;
        var k = i;
        while (k + 1 < self.len) : (k += 1) self.items[k] = self.items[k + 1];
        self.len -= 1;
        r.removed += 1;
    }

    // ── updates ──
    //
    // An update that changes NOTHING is not counted, so a patch repeated with the
    // same values reports nothing. The replacement path has always done this
    // (`Plan.apply` returns `.same`), and the patch path did not — so a model that
    // sent the same `update` twice got a "plan: 1/2 done" line twice, and a line per
    // tool call that says nothing is the noise the history is not for.
    for (updates) |u| {
        if (u.index < 1 or u.index > self.len) {
            r.unknown += 1;
            continue;
        }
        const i = u.index - 1;
        const was_status = self.items[i].status;
        const was_len = self.items[i].len;
        var was_text: [text_max]u8 = undefined;
        @memcpy(was_text[0..was_len], self.items[i].text[0..was_len]);

        if (u.status) |st| self.items[i].status = st;
        if (u.text) |t| {
            const trimmed = std.mem.trim(u8, t, " \t");
            // An empty reword is not a change, and not a bad index either: the step
            // exists. The STATUS in the same object still lands — the model asked for
            // two things and one of them is fine, and discarding it over a
            // whitespace-only string throws away what it did mean.
            //
            // So the text write is skipped, NOT the whole update: falling through to
            // the comparison below is what lets the status count.
            if (trimmed.len > 0) {
                const cp = @min(trimmed.len, text_max);
                @memcpy(self.items[i].text[0..cp], trimmed[0..cp]);
                self.items[i].len = @intCast(cp);
            }
        }

        const same = self.items[i].status == was_status and
            self.items[i].len == was_len and
            std.mem.eql(u8, self.items[i].text[0..was_len], was_text[0..was_len]);
        if (same) continue;
        r.updated += 1;
    }

    // ── additions ──
    var a: u8 = 0;
    while (a < add_n and self.len < max_items) : (a += 1) {
        self.items[self.len] = add[a];
        self.len += 1;
        r.added += 1;
    }
    // Anything that did not fit is not silently dropped.
    if (add_n > a) r.unknown += add_n - a;

    if (r.anyChange() or self.len != before_len) {
        self.prev_len = before_len;
        self.prev_done = before_done;
    }
    return r;
}

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

/// `update` / `remove` / `add`: the keys that make a `todo` call a PATCH.
pub fn parseUpdates(obj: std.json.ObjectMap, out: *[max_items]StepUpdate) !u8 {
    const v = obj.get("update") orelse obj.get("updates") orelse return 0;
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadPlan,
    };
    if (arr.items.len > max_items) return error.TooManyPlanItems;
    var n: u8 = 0;
    for (arr.items) |e| {
        if (e != .object) return error.BadPlan;
        const iv = e.object.get("index") orelse e.object.get("step") orelse return error.BadPlan;
        const idx = asIndex(iv) orelse return error.BadPlan;

        var u = StepUpdate{ .index = idx };
        if (e.object.get("status")) |sv| {
            if (sv != .string) return error.BadPlan;
            // An unknown status is a MISLABELLED step, not a broken call: leaving the
            // status alone still applies the text change in the same object, and
            // failing the whole patch over one word throws away the rest.
            u.status = Status.parse(sv.string);
        }
        if (e.object.get("text") orelse e.object.get("content")) |tv| {
            if (tv != .string) return error.BadPlan;
            u.text = tv.string;
        }
        out[n] = u;
        n += 1;
    }
    return n;
}

/// `remove: [3, 5]`
pub fn parseRemove(obj: std.json.ObjectMap, out: *[max_items]u8) !u8 {
    const v = obj.get("remove") orelse obj.get("removed") orelse return 0;
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadPlan,
    };
    if (arr.items.len > max_items) return error.TooManyPlanItems;
    var n: u8 = 0;
    for (arr.items) |e| {
        out[n] = asIndex(e) orelse return error.BadPlan;
        n += 1;
    }
    return n;
}

/// `add: [{content, status}]` — steps discovered while working.
///
/// A single step may arrive without the array, because a model that discovers one
/// more step writes `add: "text"` about as often as `add: [{…}]`.
pub fn parseAdd(obj: std.json.ObjectMap, out: *[max_items]Item) !u8 {
    const v = obj.get("add") orelse return 0;
    switch (v) {
        .array => |a| {
            if (a.items.len > max_items) return error.TooManyPlanItems;
            var n: u8 = 0;
            for (a.items) |e| {
                out[n] = try itemFromValue(e);
                n += 1;
            }
            return n;
        },
        .object => |o| {
            out[0] = try itemFromValue(.{ .object = o });
            return 1;
        },
        .string => |str| {
            out[0] = try itemFromContent(str, .pending);
            return 1;
        },
        else => return error.BadPlan,
    }
}

fn itemFromValue(v: std.json.Value) !Item {
    if (v != .object) return error.BadPlan;
    const c = v.object.get("content") orelse v.object.get("text") orelse
        v.object.get("task") orelse return error.BadPlan;
    if (c != .string) return error.BadPlan;
    // An unknown status is a MISLABELLED step, not a broken call: it falls back to
    // pending, which is what `fromValue` does for the same reason.
    const st = if (v.object.get("status")) |sv| blk: {
        if (sv != .string) break :blk .pending;
        break :blk Status.parse(sv.string) orelse .pending;
    } else .pending;
    return itemFromContent(c.string, st);
}

fn itemFromContent(text: []const u8, st: Status) !Item {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return error.BadPlan;
    var it = Item{ .status = st };
    const cp = @min(trimmed.len, text_max);
    @memcpy(it.text[0..cp], trimmed[0..cp]);
    it.len = @intCast(cp);
    return it;
}

/// A JSON index, accepting the string form.
fn asIndex(v: std.json.Value) ?u8 {
    const raw: i64 = switch (v) {
        .integer => |i| i,
        // `"3"` is a real thing models send, and rejecting it costs a retry of a
        // call that was understood perfectly well.
        .string => |s| std.fmt.parseInt(i64, std.mem.trim(u8, s, " \\t"), 10) catch return null,
        else => return null,
    };
    if (raw < 0 or raw > 255) return null;
    return @intCast(raw);
}

// ── patch tests ────────────────────────────────────────────────

/// A plan with three steps, for the patch tests.
fn planOf3() Plan {
    var p = Plan.init();
    var items: [3]Item = undefined;
    const texts = [_][]const u8{ "read the code", "fix it", "check it" };
    for (texts, 0..) |t, i| {
        @memcpy(items[i].text[0..t.len], t);
        items[i].len = @intCast(t.len);
        items[i].status = .pending;
    }
    _ = p.apply(items[0..], 3);
    return p;
}

test "applyPatch: marking ONE step done does not touch the others" {
    // The whole reason this exists. With only replacement, marking step 2 done
    // means resending three steps, and a model that resends them can drop one.
    var p = planOf3();
    const ups = [_]StepUpdate{.{ .index = 2, .status = .done }};
    const r = applyPatch(&p, &ups, &.{}, &.{}, 0);

    try std.testing.expectEqual(@as(u8, 1), r.updated);
    try std.testing.expectEqual(@as(u8, 3), p.len);
    try std.testing.expectEqualStrings("read the code", p.items[0].textOf());
    try std.testing.expectEqualStrings("fix it", p.items[1].textOf());
    try std.testing.expectEqual(Status.done, p.items[1].status);
    try std.testing.expectEqualStrings("check it", p.items[2].textOf());
    // And the untouched ones are still pending, which is the half that used to go
    // wrong when a model resends the list and reclassifies everything.
    try std.testing.expectEqual(Status.pending, p.items[0].status);
    try std.testing.expectEqual(Status.pending, p.items[2].status);
}

test "applyPatch: removals go from the highest index down" {
    // Four steps, and the two removed are sent in ASCENDING order: 1 then 3.
    //
    // This is the case the order exists for. Removing 1 first shifts every later
    // step down by one, so the next index — 3 — now names what was step 4, and the
    // model never asked for it to go anywhere. The first version of this function
    // did exactly that while its comment claimed otherwise; the comment was right
    // and the code was not.
    var p = Plan.init();
    var items: [4]Item = undefined;
    const texts = [_][]const u8{ "one", "two", "three", "four" };
    for (texts, 0..) |t, i| {
        @memcpy(items[i].text[0..t.len], t);
        items[i].len = @intCast(t.len);
        items[i].status = .pending;
    }
    _ = p.apply(items[0..], 4);
    try std.testing.expectEqual(@as(u8, 4), p.len);

    const rm = [_]u8{ 1, 3 };
    const r = applyPatch(&p, &.{}, &rm, &.{}, 0);
    try std.testing.expectEqual(@as(u8, 2), r.removed);
    try std.testing.expectEqual(@as(u8, 0), r.unknown);
    try std.testing.expectEqual(@as(u8, 2), p.len);
    // Steps 2 and 4 survive, IN THAT ORDER. With the ascending removal it would be
    // "two" and "four" too by luck, so the third assertion is what pins it: only
    // two steps are left, and neither is "one" or "three".
    try std.testing.expectEqualStrings("two", p.items[0].textOf());
    try std.testing.expectEqualStrings("four", p.items[1].textOf());
}

test "applyPatch: a remove index out of range is counted, never clamped" {
    var p = planOf3();
    // `remove: [9]` on a three-step plan is the model miscounting. Clamping it to
    // the last step would delete something it never named, which is the one
    // outcome a user cannot undo by looking at the plan.
    const rm = [_]u8{9};
    const r = applyPatch(&p, &.{}, &rm, &.{}, 0);
    try std.testing.expectEqual(@as(u8, 0), r.removed);
    try std.testing.expectEqual(@as(u8, 1), r.unknown);
    try std.testing.expectEqual(@as(u8, 3), p.len);
    try std.testing.expectEqualStrings("check it", p.items[2].textOf());
}

test "applyPatch: an index that does not exist is COUNTED, not silently ignored" {
    // A silent no-op reads as "the step was marked done", and the model will not
    // send it again — so the plan and the model disagree with no way to find out.
    var p = planOf3();
    const ups = [_]StepUpdate{
        .{ .index = 1, .status = .done },
        .{ .index = 9, .status = .done },
        .{ .index = 0, .status = .done },
    };
    const r = applyPatch(&p, &ups, &.{}, &.{}, 0);
    try std.testing.expectEqual(@as(u8, 1), r.updated);
    try std.testing.expectEqual(@as(u8, 2), r.unknown);
    // Index 0 is rejected rather than clamped: an off-by-one in the model's
    // counting, and silently marking step 1 when it meant "none" is worse than
    // saying the index was wrong. The valid update still landed.
    try std.testing.expectEqual(Status.done, p.items[0].status);
    try std.testing.expectEqual(Status.pending, p.items[1].status);
}

test "applyPatch: reword a step without changing its status" {
    var p = planOf3();
    const ups = [_]StepUpdate{.{ .index = 1, .status = .in_progress }};
    _ = applyPatch(&p, &ups, &.{}, &.{}, 0);
    const rew = [_]StepUpdate{.{ .index = 1, .text = "read the WHOLE file, not the excerpt" }};
    const r = applyPatch(&p, &rew, &.{}, &.{}, 0);
    try std.testing.expectEqual(@as(u8, 1), r.updated);
    try std.testing.expectEqualStrings("read the WHOLE file, not the excerpt", p.items[0].textOf());
    // The status survived, because the patch did not mention it.
    try std.testing.expectEqual(Status.in_progress, p.items[0].status);
}

test "applyPatch: add appends, and what does not fit is reported" {
    var p = planOf3();
    var add: [max_items]Item = undefined;
    add[0] = try itemFromContent("write the test", .pending);
    const r = applyPatch(&p, &.{}, &.{}, add[0..1], 1);
    try std.testing.expectEqual(@as(u8, 1), r.added);
    try std.testing.expectEqual(@as(u8, 4), p.len);
    try std.testing.expectEqualStrings("write the test", p.items[3].textOf());

    // A full plan rejects the extra step AND says so.
    var full = planOf3();
    full.len = max_items;
    const r2 = applyPatch(&full, &.{}, &.{}, add[0..1], 1);
    try std.testing.expectEqual(@as(u8, 0), r2.added);
    try std.testing.expectEqual(@as(u8, 1), r2.unknown);
    try std.testing.expectEqual(max_items, full.len);
}

test "parseUpdates: 1-based, a string index, and a missing index" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var out: [max_items]StepUpdate = undefined;

    const v = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"update":[{"index":2,"status":"done"},{"index":"3","text":"new"},{"step":1}]}
    , .{});
    const n = try parseUpdates(v.object, &out);
    try std.testing.expectEqual(@as(u8, 3), n);
    try std.testing.expectEqual(@as(u8, 2), out[0].index);
    try std.testing.expectEqual(Status.done, out[0].status.?);
    // `"3"` is a real thing models send, and rejecting it costs a retry of a call
    // that was understood perfectly well.
    try std.testing.expectEqual(@as(u8, 3), out[1].index);
    try std.testing.expectEqualStrings("new", out[1].text.?);
    try std.testing.expect(out[1].status == null); // not mentioned: leave it alone
    // `step` is the other name for it.
    try std.testing.expectEqual(@as(u8, 1), out[2].index);

    // No index at all is a broken call, not a silent no-op.
    const bad = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"update":[{"status":"done"}]}
    , .{});
    try std.testing.expectError(error.BadPlan, parseUpdates(bad.object, &out));
}

test "parseUpdates: an unknown status leaves the step's status alone and keeps the text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var out: [max_items]StepUpdate = undefined;

    // Failing the whole patch over one misspelled word throws away the reword that
    // was in the same object, which is the part the model actually cared about.
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"update":[{"index":1,"status":"finished","text":"the new wording"}]}
    , .{});
    const n = try parseUpdates(v.object, &out);
    try std.testing.expectEqual(@as(u8, 1), n);
    try std.testing.expect(out[0].status == null);
    try std.testing.expectEqualStrings("the new wording", out[0].text.?);
}

test "parseAdd: an array, one object, and one bare string" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var out: [max_items]Item = undefined;

    const arr = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"add":[{"content":"one"},{"content":"two","status":"in_progress"}]}
    , .{});
    try std.testing.expectEqual(@as(u8, 2), try parseAdd(arr.object, &out));
    try std.testing.expectEqualStrings("one", out[0].textOf());
    try std.testing.expectEqual(Status.in_progress, out[1].status);

    const one = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"add":{"content":"solo"}}
    , .{});
    try std.testing.expectEqual(@as(u8, 1), try parseAdd(one.object, &out));
    try std.testing.expectEqualStrings("solo", out[0].textOf());

    // A model that discovers one extra step writes the bare string about as often
    // as the array.
    const bare = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"add":"and check the docs"}
    , .{});
    try std.testing.expectEqual(@as(u8, 1), try parseAdd(bare.object, &out));
    try std.testing.expectEqualStrings("and check the docs", out[0].textOf());
}

test "applyPatch: a patch that changes nothing is not counted, and says nothing" {
    // The replacement path has always detected "same"; the patch path did not, so a
    // model that sent the same `update` twice got a "plan: 1/2 done" line twice. A
    // line per tool call that says nothing is exactly the noise the history is not
    // for.
    var p = planOf3();
    const ups = [_]StepUpdate{.{ .index = 1, .status = .done }};
    const first = applyPatch(&p, &ups, &.{}, &.{}, 0);
    try std.testing.expectEqual(@as(u8, 1), first.updated);

    const again = applyPatch(&p, &ups, &.{}, &.{}, 0);
    try std.testing.expectEqual(@as(u8, 0), again.updated);
    try std.testing.expect(!again.anyChange());
    // And the step is still done: the second patch was a no-op, not an undo.
    try std.testing.expectEqual(Status.done, p.items[0].status);
}

test "applyPatch: an empty reword is ignored, and a status in the same object still lands" {
    var p = planOf3();
    // Whitespace-only text is not a new wording, and it must not blank the step.
    const ups = [_]StepUpdate{.{ .index = 2, .status = .in_progress, .text = "   " }};
    const r = applyPatch(&p, &ups, &.{}, &.{}, 0);
    try std.testing.expectEqual(Status.in_progress, p.items[1].status);
    try std.testing.expectEqualStrings("fix it", p.items[1].textOf());
    try std.testing.expectEqual(@as(u8, 1), r.updated);
    // And the index was NOT counted as unknown: the step exists, the text was empty.
    try std.testing.expectEqual(@as(u8, 0), r.unknown);
}
