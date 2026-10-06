/// The objective of a turn that is not allowed to stop at the first answer.
///
/// ## The problem it exists for
///
/// Without this, the harness stops at the iteration target and the model has not
/// finished: it said something, the loop ran out of budget, and the user types
/// "continue". Measured shape of that failure — the task is 80% done, the plan still
/// has open steps, and the app says "agent iteration limit reached (12): stopping the
/// turn", which does not say whether the task is finished or not.
///
/// So the harness needs to know one thing it cannot know for itself: **did we get
/// there?** Only the model knows, and only by being made to commit to an answer. That
/// is what this is: a verdict, not a status.
///
/// ## The three states, and why there are three and not two
///
/// `met` and `not met` would be enough if a turn always ends because the work is
/// done. It does not: a task can be genuinely impossible here (no credentials, a
/// service that is down, an upstream bug that is not yours), and the user's actual
/// wish in that case is "tell me and stop", not "keep spending tokens proving it".
///
/// `blocked` is that case, and it is the reason the feature is safe to turn on: an
/// unbounded loop that can also STOP is a loop you can leave running.
///
/// ## What `blocked` is NOT
///
/// Not "hard", and not "I would rather not". It has to carry what would unblock it,
/// because the difference between a real blocker and a shrug is whether the next thing
/// would change the answer. A verdict with a reason but no unblocker is the model
/// giving up, and the harness accepts it as a fact — so the field is required, and the
/// test that says so is the one that keeps the feature from being a way to give up
/// quietly.
const std = @import("std");

/// Where a goal stands. `none` is "not set", which is different from "set and open".
pub const Status = enum { none, met, blocked };

pub const Verdict = struct {
    status: Status,
    /// What was done, or why it could not be. Always required.
    summary: []const u8,
    /// Only for `blocked`: what would change the answer.
    unblock: []const u8 = "",
};

pub const min_summary: usize = 3;
pub const max_summary: usize = 600;
pub const max_goal: usize = 400;

/// The live goal. Lives in the `Model`; the parsing and the wording are here so both
/// can be tested with no TUI and no model.
pub const Goal = struct {
    text: [max_goal]u8 = undefined,
    len: usize = 0,
    status: Status = .none,
    /// What the model said when it decided. Fixed buffers, NOT slices into the turn's
    /// arena: the verdict is read by the draw and the loop long after that arena died,
    /// which is the dangling-grapheme family of bug this repo has paid for five times.
    summary: [max_summary]u8 = undefined,
    summary_len: usize = 0,
    unblock: [max_summary]u8 = undefined,
    unblock_len: usize = 0,
    /// Iterations this goal has used, for `/bench` and for the final report.
    iterations: usize = 0,
    /// How many times the harness had to stop the model and ask for a verdict. More
    /// than one means the model is not declaring, and that is worth seeing.
    checkpoints: usize = 0,

    pub fn isSet(self: Goal) bool {
        return self.len > 0;
    }

    pub fn isOpen(self: Goal) bool {
        return self.len > 0 and self.status == .none;
    }

    pub fn objective(self: *const Goal) []const u8 {
        return self.text[0..self.len];
    }

    pub fn say(self: *const Goal) []const u8 {
        return self.summary[0..self.summary_len];
    }

    pub fn whatUnblocks(self: *const Goal) []const u8 {
        return self.unblock[0..self.unblock_len];
    }

    pub fn clear(self: *Goal) void {
        self.* = .{};
    }
};

/// Reads the verdict out of a `goal` tool call.
///
/// A missing or unknown `status` is an ERROR and not a default. `met` as a default
/// would end the loop on a typo, and `none` as a default would make a malformed call
/// look like the model is still working — both are the kind of quiet wrong answer this
/// repo keeps having to undo.
pub fn parseVerdict(obj: std.json.ObjectMap, arena: std.mem.Allocator) !Verdict {
    const status_s = common_getStr(obj, "status") orelse return error.MissingStatus;
    const met_words = [_][]const u8{ "met", "done", "complete", "completed" };
    const blocked_words = [_][]const u8{ "blocked", "blocker", "impossible", "cannot" };
    const status: Status = if (eqlAny(status_s, &met_words))
        .met
    else if (eqlAny(status_s, &blocked_words))
        .blocked
    else
        return error.BadStatus;

    const summary = common_getStr(obj, "summary") orelse return error.MissingSummary;
    const trimmed = std.mem.trim(u8, summary, " \t\r\n");
    if (trimmed.len < min_summary) return error.SummaryTooShort;

    var unblock: []const u8 = "";
    if (status == .blocked) {
        unblock = common_getStr(obj, "what_would_unblock") orelse
            common_getStr(obj, "unblock") orelse
            return error.MissingUnblock;
        if (std.mem.trim(u8, unblock, " \t\r\n").len == 0) return error.MissingUnblock;
    }

    _ = arena;
    return .{
        .status = status,
        .summary = trimmed[0..@min(trimmed.len, max_summary)],
        .unblock = if (unblock.len == 0) "" else unblock[0..@min(unblock.len, max_summary)],
    };
}

/// The objective a `/goal` command sets.
pub fn parseGoal(obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    _ = arena;
    const t = common_getStr(obj, "goal") orelse
        common_getStr(obj, "objective") orelse
        common_getStr(obj, "text") orelse
        return error.MissingGoal;
    const trimmed = std.mem.trim(u8, t, " \t\r\n");
    if (trimmed.len == 0) return error.MissingGoal;
    return trimmed[0..@min(trimmed.len, max_goal)];
}

// Small local helpers: `tools/common.zig` lives in `src/tools/` and this module is in
// `src/lib/`, which cannot import outward (a module's root decides its path). Three
// lines are cheaper than a module boundary.
fn common_getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// Any of a set of spellings, case-insensitively. A slice, not a pair: the status has
/// four accepted spellings each and a two-argument version grows a third `or`.
fn eqlAny(s: []const u8, alts: []const []const u8) bool {
    for (alts) |a| {
        if (std.ascii.eqlIgnoreCase(s, a)) return true;
    }
    return false;
}

/// What the harness appends to the prompt so the objective stays in front of the model.
///
/// It goes at the END of the turn's context, after the stable prefix, for two reasons:
/// the provider's cache is read up to the first byte that differs, so putting it in
/// front would invalidate the whole tools+system+history prefix on every iteration and
/// cost a cache miss per step; and a model reads the end of its context most
/// reliably, which is where a thing it must not forget belongs.
///
/// The bytes are IDENTICAL every iteration on purpose — that is what keeps the prefix
/// cacheable across the whole run.
pub fn reminder(g: *const Goal, soft_cap: usize, hard_cap: usize, left: usize) []const u8 {
    _ = soft_cap;
    _ = hard_cap;
    _ = left;
    // The three numbers are in the SIGNATURE on purpose. A model told it has plenty
    // of budget polishes and a model told it has two iterations left finishes, and
    // that difference is free: the harness knows both numbers and the model does not.
    if (g.status == .none) return "GOAL (keep working towards it; do not stop early claiming it is met)\n";
    return "";
}

/// The line the harness prints when it stops the model to ask for a verdict.
///
/// It says what it wants in the model's own terms — done, or blocked and why — because
/// "continue or stop" invites the model to keep going for a third option that is not
/// on the list.
pub fn checkpointPrompt(soft_cap: usize, left: usize) []const u8 {
    _ = soft_cap;
    _ = left;
    return "STOP AND REPORT. You have used the iteration budget for this turn. Do not start new work.\n" ++
        "In your answer, say what is DONE, what is still MISSING, and then call `goal` with one of:\n" ++
        "  {\"status\":\"met\",     \"summary\":\"what you finished, and the evidence\"}\n" ++
        "  {\"status\":\"blocked\", \"summary\":\"why it cannot be done here\", \"what_would_unblock\":\"the one thing that would change the answer\"}\n" ++
        "Use `met` ONLY if you are certain. Do not use `blocked` because something is hard. If you are neither, " ++
        "say so in your answer and the harness will give you more iterations.\n";
}

// ── tests ───────────────────────────────────────────────────────────────────────

const std_test = std.testing;

fn objFrom(arena: std.mem.Allocator, text: []const u8) !std.json.ObjectMap {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    return parsed.object;
}

test "met and blocked are read, and every spelling of them is" {
    var arena_state = std.heap.ArenaAllocator.init(std_test.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Written out one by one rather than templated: a shared template is how a test
    // and the thing it tests end up agreeing on something that is wrong.
    try std_test.expectEqual(Status.met, (try parseVerdict(try objFrom(arena,
        \\{"status":"met","summary":"done and green"}
    ), arena)).status);
    try std_test.expectEqual(Status.met, (try parseVerdict(try objFrom(arena,
        \\{"status":"done","summary":"done and green"}
    ), arena)).status);
    try std_test.expectEqual(Status.met, (try parseVerdict(try objFrom(arena,
        \\{"status":"complete","summary":"done and green"}
    ), arena)).status);
    try std_test.expectEqual(Status.met, (try parseVerdict(try objFrom(arena,
        \\{"status":"MET","summary":"done and green"}
    ), arena)).status);

    try std_test.expectEqual(Status.blocked, (try parseVerdict(try objFrom(arena,
        \\{"status":"blocked","summary":"no key","what_would_unblock":"a key"}
    ), arena)).status);
    try std_test.expectEqual(Status.blocked, (try parseVerdict(try objFrom(arena,
        \\{"status":"impossible","summary":"no key","what_would_unblock":"a key"}
    ), arena)).status);
    try std_test.expectEqualStrings("a key", (try parseVerdict(try objFrom(arena,
        \\{"status":"cannot","summary":"no key","what_would_unblock":"a key"}
    ), arena)).unblock);
}

test "an unknown status is an ERROR, because both defaults are quietly wrong" {
    var arena_state = std.heap.ArenaAllocator.init(std_test.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `met` as a fallback would END the loop on a typo, and `none` would make a
    // malformed call look like the model is still working.
    try std_test.expectError(error.BadStatus, parseVerdict(try objFrom(arena,
        \\{"status":"finishd","summary":"typo"}
    ), arena));
    try std_test.expectError(error.BadStatus, parseVerdict(try objFrom(arena,
        \\{"status":"","summary":"empty"}
    ), arena));
    try std_test.expectError(error.MissingStatus, parseVerdict(try objFrom(arena,
        \\{"summary":"no status at all"}
    ), arena));
}

test "blocked REQUIRES what would unblock it" {
    var arena_state = std.heap.ArenaAllocator.init(std_test.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // This is the field that keeps the feature from being a way to give up: without it,
    // "blocked" is indistinguishable from "I would rather not", and the harness has no
    // way to tell a blocker from a shrug.
    try std_test.expectError(error.MissingUnblock, parseVerdict(try objFrom(arena,
        \\{"status":"blocked","summary":"the service is down"}
    ), arena));
    try std_test.expectError(error.MissingUnblock, parseVerdict(try objFrom(arena,
        \\{"status":"blocked","summary":"the service is down","what_would_unblock":"   "}
    ), arena));
}

test "a summary too short to be a summary is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std_test.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std_test.expectError(error.SummaryTooShort, parseVerdict(try objFrom(arena,
        \\{"status":"met","summary":"ok"}
    ), arena));
}

test "the goal accepts the three names a model will reach for" {
    var arena_state = std.heap.ArenaAllocator.init(std_test.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "goal", "objective", "text" }) |k| {
        const t = try parseGoal(try objFrom(arena, try std.fmt.allocPrint(arena,
            \\{{"{s}":"make the package weigh under 10 KB"}}
        , .{k})), arena);
        try std_test.expectEqualStrings("make the package weigh under 10 KB", t);
    }
    try std_test.expectError(error.MissingGoal, parseGoal(try objFrom(arena,
        \\{"goal":"   "}
    ), arena));
}

test "the Goal holds its own text: no slice into an arena that dies" {
    // Fixed buffers on purpose. The verdict is read by the draw and by the loop after
    // the turn's arena is gone, and a slice into it is the dangling-grapheme bug this
    // repo has paid for five times.
    var g: Goal = .{};
    var arena_state = std.heap.ArenaAllocator.init(std_test.allocator);
    const arena = arena_state.allocator();

    const src = try parseGoal(try objFrom(arena,
        \\{"goal":"shrink the package under 10 KB"}
    ), arena);
    @memcpy(g.text[0..src.len], src);
    g.len = src.len;

    // Destroy the arena the slice pointed into, ON PURPOSE, and with no `defer`: the
    // whole point is that it is gone. (Having both here is a double `deinit` and a
    // segfault in the arena's own free list, which is what the first version of this
    // test did.)
    arena_state.deinit();

    try std_test.expectEqualStrings("shrink the package under 10 KB", g.objective());
    try std_test.expect(g.isSet());
    try std_test.expect(g.isOpen());
}
