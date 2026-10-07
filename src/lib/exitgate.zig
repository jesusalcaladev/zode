//! The exit gate: the one rule that decides whether a turn may end on CODE.
//!
//! ## Why this module exists
//!
//! Measured over five real task runs: the same model that codes well under another
//! harness finished **none** of them, and every time the code was left not compiling.
//! The harness had the evidence the whole time — it read the exit code and built the
//! model's own error message out of the diagnostics — and then let the turn end.
//!
//! So the missing piece was never "tell the model to verify harder". The prompt block
//! `verification_prompt` already says it. The missing piece is a rule in the LOOP that
//! holds the evidence it already has, and this file is that rule, with no I/O in it.
//!
//! ## Why it is pure, and why that is the point
//!
//! Two runners exist (`zode` and `zode --chat`) and every rule that lives in one of
//! them drifts from the other: the headless prompt used to miss the routing table, and
//! the automatic typecheck used to exist only in the TUI — the runner every test in
//! this repo drives. A rule with no I/O can be written down once and asserted with no
//! TUI, no network and no terminal, so it cannot drift without a red test.
//!
//! ## What it is NOT
//!
//! It is not a judge of code quality, and it cannot be: the harness knows whether a
//! compiler accepted the files and nothing else. Whether a change is well written, well
//! named and worth reviewing is the model's judgement with the user's eyes on it. This
//! module answers exactly one question — **is the code in a state nobody has to be
//! embarrassed by** — and it answers it with a compiler, not with an opinion.

const std = @import("std");

/// What the last completed verification said.
pub const Verdict = enum { unchecked, passed, failed };

/// What the gate concluded.
pub const Decision = enum {
    /// Nothing blocks the turn.
    end,
    /// The last check was RED. Never cage-worthy, never overridable by the budget.
    refused_failed,
    /// Code was written and NO completed check covers it: unchecked, or a green from
    /// before the last edit. Both are the same failure — the evidence is stale.
    refused_unverified,
    /// Code was written and there is no way to check it (no command known for this
    /// project, or the one that exists could not be run).
    ///
    /// This does NOT hold the turn. A harness that refuses to end a turn it cannot
    /// verify is a harness that runs to the ceiling on every project it does not know,
    /// and a user who cannot finish a turn is worse off than one who was told the
    /// truth. It says it and it lets the turn go.
    cannot_verify,
    /// A check is in flight and outran the wait.
    ///
    /// It exists here and NOT in `decide`'s logic because it is not a property of the
    /// code: it is a property of a CLOCK. A build that takes longer than the wait is a
    /// build the user is watching, and blocking the turn on it would mean deciding that
    /// a slow compile matters more than the user's session. So the answer is: say the
    /// check is still running, and let the turn go — the job stays alive and the next
    /// turn reads it.
    still_running,
};

/// The state of the code as far as the harness knows it.
///
/// Every field is per TURN and reset by `reset`: a stale red would otherwise refuse to
/// let any later turn end, forever, with a message about a build from another task.
pub const Gate = struct {
    /// How many checks the GATE may start past the turn's quota.
    ///
    /// Bounded, because the gate's whole job is to be sure before it ends a turn, and
    /// an unbounded "just check again" is how a turn that cannot be verified becomes a
    /// turn that never returns. Two is enough: one to check what was just written, one
    /// to re-check after the model fixed it. The iteration ceiling is the backstop past
    /// this and it exists anyway.
    pub const max_forced: u32 = 2;

    /// Successful writes to code a compiler would care about, this turn.
    ///
    /// Counted from calls that SUCCEEDED. A denied or failed `edit` wrote nothing, and
    /// counting it would make the gate wait for a check of a file that still has its
    /// old contents — a check that would be green and mean nothing.
    writes: u32 = 0,
    /// How many of `writes` the newest COMPLETED check was looking at.
    ///
    /// A number and not a bool because "a green check exists" is not the question: a
    /// green check from BEFORE the last edit is not evidence about the current files.
    /// `verified_writes` is the value of `writes` at the moment that check started, so
    /// an edit made afterwards leaves the difference non-zero and the evidence stale.
    verified_writes: u32 = 0,
    verdict: Verdict = .unchecked,
    /// A verification command is known for this project.
    checkable: bool = false,
    /// A check is in flight.
    running: bool = false,
    /// Checks the GATE started, past the per-turn quota.
    forced: u32 = 0,

    pub fn reset(self: *Gate) void {
        self.* = .{};
    }

    /// A writing tool changed code.
    pub fn noteWrite(self: *Gate) void {
        self.writes += 1;
    }

    /// A check was started. `forced` is the gate's, not the quota's.
    pub fn noteStarted(self: *Gate, forced: bool) void {
        self.running = true;
        if (forced) self.forced += 1;
    }

    /// A check finished, and `covers` is how many writes it was actually looking at.
    ///
    /// `covers` is smaller than `writes` when the model edited while the check ran,
    /// which is the normal shape of a turn: the check is then a fact about an older
    /// state of the files and the gate keeps asking for the current one.
    pub fn noteCompleted(self: *Gate, v: Verdict, covers: u32) void {
        self.running = false;
        self.verdict = v;
        self.verified_writes = covers;
    }

    /// Writes no completed check covers.
    pub fn unverified(self: Gate) u32 {
        return if (self.writes > self.verified_writes) self.writes - self.verified_writes else 0;
    }

    pub fn wroteCode(self: Gate) bool {
        return self.writes > 0;
    }

    /// May the gate start one more check of its own?
    pub fn canForce(self: Gate) bool {
        return self.forced < max_forced;
    }

    /// THE RULE. Everything else in this feature exists to feed this function.
    ///
    /// The order is the whole thing, and each branch answers a different question:
    ///
    /// 1. **Was any code written?** No → the turn is prose, a question, or a README.
    ///    Demanding a compile there is the harness nagging about work that has none.
    /// 2. **Can this project be checked at all?** No → say so, do not cage. This is
    ///    the direction that is safe to be wrong in: a turn that ends with an honest
    ///    "not verified" costs one line, and a turn that never ends costs the user the
    ///    whole task.
    /// 3. **Was the last check RED?** → refuse. Not "usually", not "unless the budget
    ///    is over": the code does not compile, and the ceiling's job is to say
    ///    UNFINISHED, not to wave broken code through.
    /// 4. **Does a completed check cover the current files?** No → refuse, because a
    ///    green from before the last edit is the failure this repo measured: a model
    ///    that fixed the build, edited again, and was believed.
    ///
    /// The model always has the way out: `goal` with `blocked`. It is honoured ABOVE
    /// this rule by the caller, never inside it — a loop that cannot be stopped is not
    /// a safe loop with an exit hatch, it is a cage.
    pub fn decide(self: Gate) Decision {
        if (!self.wroteCode()) return .end;
        if (!self.checkable) return .cannot_verify;
        if (self.verdict == .failed) return .refused_failed;
        if (self.unverified() > 0) return .refused_unverified;
        return .end;
    }
};

// ── tests ────────────────────────────────────────────────────────

const t = std.testing;

test "no code written: the turn is prose, and nothing is required of it" {
    // The direction that is safe to be wrong in. A turn of questions, of an
    // explanation or of a README must end normally — demanding a compiler here is
    // the harness nagging about work that has no code in it.
    var g: Gate = .{};
    try t.expectEqual(Decision.end, g.decide());
    // Even with a check that is somehow red: there is nothing it is about.
    g.verdict = .failed;
    try t.expectEqual(Decision.end, g.decide());
}

test "code written, no check possible: said out loud, but the turn may end" {
    var g: Gate = .{};
    g.noteWrite();
    // `checkable` false is the default: a project with no build.zig, no
    // Cargo.toml, nothing the harness knows how to run.
    try t.expectEqual(Decision.cannot_verify, g.decide());
    // And it is NOT a cage: the refusal states exist for red and for unchecked, and
    // this is neither.
    try t.expectEqual(Verdict.unchecked, g.verdict);
}

test "RED never lets a turn end, with a goal open or not" {
    // This is the rule the whole loop was missing. It is deliberately independent of
    // whether a `/goal` was set: a plain "fix this bug" is a task about code, and it
    // has no less need of a working build than one with an objective attached.
    var g: Gate = .{};
    g.checkable = true;
    g.noteWrite();
    g.noteStarted(false);
    g.noteCompleted(.failed, 1);
    try t.expectEqual(Decision.refused_failed, g.decide());

    // And it stays refused after further edits: a red is a red.
    g.noteWrite();
    try t.expectEqual(Decision.refused_failed, g.decide());
}

test "a GREEN from before the last edit is not evidence about the current files" {
    // The failure this pins, and it is not hypothetical: the model fixed the build,
    // edited a second file, and the harness believed the first green. One number of
    // writes versus one number of covered writes is the whole difference between
    // "verified" and "verified a moment ago".
    var g: Gate = .{};
    g.checkable = true;
    g.noteWrite(); // edit A
    g.noteStarted(false);
    g.noteCompleted(.passed, 1); // green, covering A
    try t.expectEqual(Decision.end, g.decide());

    g.noteWrite(); // edit B, after the check had started
    try t.expectEqual(@as(u32, 1), g.unverified());
    try t.expectEqual(Decision.refused_unverified, g.decide());

    // Re-checking the CURRENT files closes it, and only that does.
    g.noteStarted(true);
    g.noteCompleted(.passed, 2);
    try t.expectEqual(@as(u32, 0), g.unverified());
    try t.expectEqual(Decision.end, g.decide());
}

test "a check that is still running cannot be called green" {
    var g: Gate = .{};
    g.checkable = true;
    g.noteWrite();
    g.noteStarted(false);
    // Running, and nothing completed: the verdict is still `unchecked`, and the
    // files are unverified. The caller waits for this before deciding.
    try t.expectEqual(Decision.refused_unverified, g.decide());
    try t.expect(g.running);
}

test "the gate's own checks are bounded, and the quota is the harness's business" {
    var g: Gate = .{};
    g.checkable = true;
    try t.expect(g.canForce());
    g.noteStarted(true);
    try t.expect(g.canForce());
    g.noteStarted(true);
    // Past `max_forced`: the gate stops checking, and the iteration ceiling takes
    // over from here. An unbounded "just check again" is how a turn that cannot be
    // verified becomes a turn that never returns.
    try t.expect(!g.canForce());
    // A quota check (not the gate's) never counts against that budget.
    var h: Gate = .{};
    for (0..50) |_| h.noteStarted(false);
    try t.expect(h.canForce());
}

test "reset: the next turn is judged by its own code" {
    var g: Gate = .{};
    g.checkable = true;
    g.noteWrite();
    g.noteStarted(true);
    g.noteCompleted(.failed, 1);
    try t.expectEqual(Decision.refused_failed, g.decide());

    g.reset();
    // A stale red is worse than no red: it would refuse to let any later turn end,
    // with a message about a build from another task.
    try t.expectEqual(Verdict.unchecked, g.verdict);
    try t.expectEqual(Decision.end, g.decide());
    try t.expectEqual(@as(u32, 0), g.forced);
}
