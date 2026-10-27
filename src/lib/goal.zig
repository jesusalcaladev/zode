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
    /// How many times a `blocked` was sent back for want of evidence.
    ///
    /// Separate from `checkpoints` because it answers a different question: that one
    /// counts "you did not declare", this one counts "you declared giving up without
    /// having tried". A shared counter would make a turn that refused a shrug look
    /// like a turn that had to be nagged, which are opposite problems.
    blocked_refusals: u8 = 0,

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
/// What the harness says when the soft budget runs out.
///
/// ## Why this does not say STOP
///
/// The first version opened with "STOP AND REPORT. You have used the iteration budget
/// for this turn. Do not start new work." and closed with "If you are neither, say so in
/// your answer and the harness will give you more iterations."
///
/// Both halves were wrong, and measurably so. Over five real task runs the same model
/// that does this work well under a different harness finished zero of them, and this
/// prompt is the reason:
///
/// - It told the model to STOP at iteration 12 with the work half done. A model that
///   obeys writes a summary instead of finishing; a model that does not obey burns the
///   next 48 iterations ignoring an instruction. Neither finishes the task. That is a
///   coin flip the harness is flipping with the user's work.
/// - The escape was "say so in your answer", which requires the harness to READ PROSE.
///   It does not and it cannot: the only machine-readable ending is the `goal` call. So
///   the prompt offered a door made of a material the harness cannot handle.
///
/// The harness does not need the model to tell it whether the work is finished. It has
/// the plan, with its open steps counted, and the verification that failed. So this
/// names what is still open and keeps going. The verdict stays available, but as what it
/// actually is: the way out when the work really cannot be finished here, not the price
/// of admission for continuing.
///
/// The numbers are in it because they are the cheapest lever there is: a model with room
/// to spare polishes the objective, and a model with four iterations left finishes.
pub fn checkpointPrompt(
    gpa: std.mem.Allocator,
    soft_cap: usize,
    left: usize,
    open_steps: usize,
) ![]const u8 {
    _ = soft_cap;
    const steps = try openStepsLine(gpa, open_steps);
    defer gpa.free(steps);
    return std.fmt.allocPrint(gpa,
        \\Keep going. This is a speed bump, not the end of the turn, and there are {d} more
        \\iterations after this one.
        \\
        \\Still open in your plan: {s}
        \\
        \\That is the work: finish it now. Do not write a summary of what you did, because an
        \\unfinished task does not become a finished one by being described.
        \\
        \\If a test or a build is failing, fix that before anything else. Unverified work is
        \\not work.
        \\
        \\Only when the objective is genuinely reached, or genuinely cannot be reached here,
        \\call `goal`:
        \\  {{"status":"met",     "summary":"what you finished, and the evidence"}}
        \\  {{"status":"blocked", "summary":"why it cannot be done here", "what_would_unblock":"the one thing that would change the answer"}}
    , .{ left, steps });
}

/// "Keep going" only works if it says what to keep going ON, and the harness already
/// knows: the plan counts its own open steps. Asking the model would be asking it for
/// something this process can read off its own state, which is the whole point of the
/// change — the harness stops asking the model to grade its own homework.
fn openStepsLine(gpa: std.mem.Allocator, open_steps: usize) ![]const u8 {
    return switch (open_steps) {
        0 => gpa.dupe(u8, "none, which means the objective is not met or not verified: find out which before you declare it."),
        1 => gpa.dupe(u8, "1 step. Finish that one before anything else."),
        else => std.fmt.allocPrint(gpa, "{d} steps. Work down them in order.", .{open_steps}),
    };
}

/// May the harness accept this verdict, given what the turn actually did?
///
/// ## Why `blocked` needs this and `met` does not
///
/// `blocked` is the exit hatch that makes the whole goal feature safe: an unbounded
/// loop that can also STOP is a loop you can leave running, and it only means
/// something if the stop is justified. `what_would_unblock` was the first half of that
/// justification and it is not enough, because a field is something the model FILLS
/// IN — "the network is down" is as easy to invent as "here is the key", and both are
/// accepted with the same confidence.
///
/// So the second half is something the harness can read off its own state: **did the
/// turn actually try?** A verdict of `blocked` on the very first response, with no tool
/// ever run, is not a blocker — it is a shrug with a JSON body. Nothing was read, no
/// command was run, no file was looked at, so there is no evidence for any claim about
/// what is impossible.
///
/// ## Why only ONCE, and why only with zero tools
///
/// Two failure modes on the other side, both real:
///
/// - **Infinite.** If the refusal were absolute, a turn on a genuinely impossible task
///   would run to the ceiling every time, and a task that cannot be done here is
///   exactly the case `blocked` exists for. So it is refused once and then honoured:
///   the model has been told, it has had its chance to go and do something, and a
///   second `blocked` after it has run tools is a real one.
/// - **Punishing a careful model.** The bar is deliberately `tools == 0`, not "few
///   tools". A model that read twelve files before concluding it needs a credential
///   has earned its `blocked`; a model that asked on iteration one has not. Anything
///   stricter punishes exactly the careful behaviour we want.
///
/// And `met` is never subject to it: "there was nothing to do here" is a real answer,
/// and the harness has no evidence to weigh against it either way. That asymmetry is
/// the point — the check exists to stop a false BLOCKER, not to grade the model.
pub fn verdictCredible(g: *const Goal, tools_run: usize) bool {
    if (g.status != .blocked) return true;
    if (g.blocked_refusals > 0) return true;
    return tools_run > 0;
}

/// The sentence the harness sends back when a `blocked` has no evidence behind it.
///
/// It is written as an instruction and not as a refusal, because the model's way out
/// has to stay open: it can go and try, and then the same verdict is accepted.
pub fn blockedRetryText(gpa: std.mem.Allocator) ![]u8 {
    return gpa.dupe(u8,
        \\Your `blocked` was not accepted: this turn has not run a single tool, so
        \\there is no evidence for the claim. Nothing was read, nothing was executed,
        \\nothing was looked at. Go and do the obvious first thing — read the file,
        \\run the command, search for the answer — and if it is still impossible,
        \\call `goal` with status blocked again and it will be accepted.
    );
}

// The PROMPT half of the same refusal.
//
// `blockedRetryText` goes to the user (the history, as an error row) and this
// one goes to the model (the next turn's `user` message). They were ONE
// buffer, which meant two owners: `pushErrorOwned` takes ownership and so
// does the turn loop's `owned`, and freeing it through either one left the
// other pointing at released memory — a use-after-free in the draw, and a
// double free at teardown. Two buffers, one refusal.
pub fn blockedRetryPrompt() []const u8 {
    return
    \\That `blocked` was not accepted because this turn has not run a single
    \\tool yet, so there is no evidence for it. Do the obvious first thing now:
    \\read the file, run the command, search for the answer. If it is genuinely
    \\still impossible, call `goal` again with status blocked and
    \\what_would_unblock, and that one will be accepted.
    ;
}

test "a `blocked` with nothing behind it is sent back once, then accepted" {
    // The failure this pins: `what_would_unblock` is a field the model FILLS IN, so
    // "the network is down" was as acceptable as "here is the key", and a model that
    // gave up on iteration one got the same calm exit as one that spent a turn proving
    // it. The exit hatch has to be earned by SOMETHING the harness can read itself.
    //
    // The harness can read exactly one thing here — whether any tool ran — and that is
    // deliberately the whole bar. Anything stricter would punish the careful model that
    // read twelve files before concluding it needed a credential, which is the
    // behaviour we want, and would let a model that read one file declare anything.
    var g: Goal = .{};
    g.status = .blocked;

    // Nothing was tried. A shrug.
    try std_test.expect(!verdictCredible(&g, 0));

    // One tool is enough. Not "three tools", not "a verification": the claim being
    // tested is "did you look before you said it is impossible", and one read answers
    // that.
    try std_test.expect(verdictCredible(&g, 1));
}

test "the refusal happens ONCE, because a blocked that cannot be declared is a cage" {
    // The other failure mode, and the one that matters more: an absolute rule here
    // turns every genuinely impossible task into a turn that runs to the ceiling. That
    // is the exact task `blocked` exists for.
    var g: Goal = .{};
    g.status = .blocked;

    try std_test.expect(!verdictCredible(&g, 0));
    g.blocked_refusals = 1;
    // Same state, same zero tools: accepted now. The model was told, it had its chance
    // to go and do something, and arguing about it is how a loop stops being a loop.
    try std_test.expect(verdictCredible(&g, 0));
}

test "`met` is never sent back for want of evidence" {
    // The asymmetry is the point, and it is deliberate. The check exists to catch a
    // FALSE BLOCKER — a claim of impossibility with nothing behind it. "There was
    // nothing to do here" is not a claim about the world that can be checked, and the
    // harness has no evidence to weigh against it either way.
    //
    // Making `met` subject to the same rule would mean grading how many tools a model
    // used before saying a task needed none, which is not a thing the harness knows.
    var g: Goal = .{};
    g.status = .met;
    try std_test.expect(verdictCredible(&g, 0));

    g.status = .none;
    try std_test.expect(verdictCredible(&g, 0));
}

test "the retry text gives an instruction, not a dead end" {
    // A refusal that does not say what to do instead is a dead end with extra steps: the
    // model's only remaining move is to give up, which is the opposite of what the
    // refusal is for.
    const text = try blockedRetryText(std_test.allocator);
    defer std_test.allocator.free(text);
    try std_test.expect(std.mem.indexOf(u8, text, "read the file") != null);
    try std_test.expect(std.mem.indexOf(u8, text, "call `goal` with status blocked again") != null);
    // And it promises the second one lands, so the model can trust the way out.
    try std_test.expect(std.mem.indexOf(u8, text, "it will be accepted") != null);
}

test "the refusal and the prompt are TWO buffers, because there are two owners" {
    // The crash: `blockedRetryText` was ONE allocation handed to BOTH
    // `pushErrorOwned` (which takes ownership — the drain moves the pointer
    // into `paras` and `Model.deinit` frees it) AND the turn loop's `owned`
    // (which frees the previous prompt through it). One buffer, two owners: a
    // use-after-free while the UI painted the paragraph, and a double free at
    // teardown.
    //
    // The two halves say different things to different readers, which is why
    // they cannot be one string again: the text is what the USER sees in the
    // history, the prompt is what the MODEL reads as the next turn's message.
    const text = try blockedRetryText(std_test.allocator);
    defer std_test.allocator.free(text);

    // The prompt is a plain `[]const u8` and NOT heap: it is a static string,
    // so it can never be freed by the loop that owns `owned`. That is the
    // property that makes one owner safe. (`pushInfoOwned` on a literal is the
    // "Invalid free" this repo has paid for repeatedly.)
    const prompt = blockedRetryPrompt();
    try std_test.expect(prompt.len > 0);

    // It is an instruction, and it keeps the way out open.
    try std_test.expect(std.mem.indexOf(u8, prompt, "read the file") != null);
    try std_test.expect(std.mem.indexOf(u8, prompt, "what_would_unblock") != null);
    try std_test.expect(std.mem.indexOf(u8, prompt, "will be accepted") != null);
}

test "the refusal counter is not the checkpoint counter" {
    // They answer opposite questions. `checkpoints` counts "you did not declare";
    // `blocked_refusals` counts "you declared giving up without trying". With one shared
    // counter a turn that caught a shrug would look like a turn that had to be nagged
    // about declaring at all, and `Goal{}.* = .{}` in `clear()` would be the only thing
    // keeping the two apart.
    var g: Goal = .{};
    try std_test.expectEqual(@as(usize, 0), g.checkpoints);
    try std_test.expectEqual(@as(u8, 0), g.blocked_refusals);

    g.blocked_refusals = 1;
    try std_test.expectEqual(@as(usize, 0), g.checkpoints);

    g.clear();
    try std_test.expectEqual(@as(u8, 0), g.blocked_refusals);
}

test "the state the refusal reads is PER TURN, and the turn resets it" {
    // The bug this pins, and it is one I wrote the same day: `blocked_refusals` was added
    // to `Goal`, wired into the loop, and then never reset — while `checkpoints` right
    // next to it WAS. So the evidence check was a one-shot for the whole SESSION.
    //
    // Small on the surface, bad underneath: a model that declared `blocked` on the first
    // iteration of turn one had its single refusal spent, and on turn two a shrug with no
    // tools behind it was accepted immediately. The whole failure the field was added for
    // came back after one turn.
    //
    // The reason it is per turn is the same reason a stale red is worse than no red: the
    // evidence is per turn ("did THIS turn look before it said it is impossible") and
    // answering it with the previous turn's answer is answering a different question.
    var g: Goal = .{};
    g.status = .blocked;
    g.blocked_refusals = 1;
    // Turn one, already refused: accepted (that is the "only once" rule).
    try std_test.expect(verdictCredible(&g, 0));

    // The new turn's reset — the two lines `chatWorker` runs before the loop.
    g.status = .none;
    g.checkpoints = 0;
    g.blocked_refusals = 0;

    // And now the very same shrug is refused again, because it is a new turn's shrug.
    g.status = .blocked;
    try std_test.expect(!verdictCredible(&g, 0));
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
