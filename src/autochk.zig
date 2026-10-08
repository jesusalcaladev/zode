//! The automatic typecheck, and the exit gate that sits on top of it.
//!
//! ## Why this is its own file
//!
//! It is a struct with no `Model` in it, and it always was — and it lived in a 6 000-line
//! `agent.zig` anyway, for the same reason a lot of things here live in one file: it grew
//! where its first caller was. Moving it out is only possible because the whole thing is
//! already Model-free, and that is worth saying out loud: **this is the seam that was
//! already there.** The pieces that read a `Model` — the tool dispatcher, the UI, the
//! session — cannot move, and pretending otherwise is how a "split the big file" turns
//! into an import cycle.
//!
//! ## Why it is not a cage
//!
//! The gate refuses a turn three ways: the build is red, the code is unchecked, or nobody
//! read the diff. Two things it deliberately does NOT do:
//!
//! - **Refuse a turn it cannot verify.** No known command for this project means the gate
//!   says "not verified" and lets the turn go. A harness that never ends a turn on a
//!   project it does not recognise is worse than one that is honest.
//! - **Block on a slow build.** The wait is a cap, and a check that outruns it is a
//!   REFUSAL that tells the model to poll the job, not a freeze of the user's session.

const std = @import("std");
const bgproc = @import("bgproc.zig");
const check_tool = @import("tools/check.zig");
const bg_tool = @import("tools/bg.zig");
const typecheck_mod = @import("lib/typecheck.zig");
const exitgate = @import("lib/exitgate.zig");
const review_mod = @import("lib/review.zig");
const sleep_mod = @import("lib/sleep.zig");
const env_mod = @import("lib/env.zig");

/// How long a turn waits for a check that is already running.
///
/// Not a guess about how long a build takes: a build longer than this is a build the
/// user is watching, and the job keeps running for the next turn to read. What must not
/// happen is ending a turn about code whose only compile check is still in flight.
pub const auto_check_wait_ms: u32 = 4000;

/// How many automatic checks one turn may start on its own.
///
/// 2, not 1: the shape of a task is "edit, read the errors, fix, edit, read the errors",
/// and with 1 the second fix is never checked. Not 3, because a turn that needs three
/// builds is a turn where the model is guessing.
///
/// This is NOT the gate's budget. The gate's is `exitgate.Gate.max_forced`, and sharing
/// the two would mean a turn that spent both editing arrives at the gate unable to check
/// at all — the one moment it must be able to.
pub const auto_check_per_turn: u32 = 2;

/// Counts non-empty lines. A diagnostic line is one line, and a build that fails in 40
/// places has a 41st error that is noise.
fn countDiagLines(s: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |l| if (std.mem.trim(u8, l, " \t\r").len != 0) {
        n += 1;
    };
    return n;
}

/// Does this tool modify a file on disk?
fn touchesFile(name: []const u8) bool {
    return std.mem.eql(u8, name, "write") or std.mem.eql(u8, name, "edit");
}

/// The one probe of the session, for whether there is a diff to review.
var git_repo_probe: ?bool = null;

fn isGitRepo(io: std.Io) bool {
    const r = bg_tool.runForeground(std.heap.page_allocator, io, "git rev-parse --is-inside-work-tree", 5, 64) catch return false;
    return r.term != null and std.mem.indexOf(u8, r.stdout, "true") != null;
}

/// Gives an `AutoCheck` the environment its flags are read from.
///
/// It is a FUNCTION and not a field assignment at each of the two construction sites
/// because forgetting it is silent and total: `AutoCheck.env` defaults to null, null
/// means "no environment", and null means the DEFAULT for every flag — so a harness
/// where nobody assigned it has `ZODE_AUTO_CHECK=0` working perfectly and nobody able
/// to turn it ON, with no error anywhere.
pub fn attachEnv(ac: *AutoCheck, env: ?*const std.process.Environ.Map) void {
    ac.env = env;
}

/// `isGitRepo`, asked once and remembered.
///
/// `null` is "not asked yet", which is different from `false` ("asked, and there is no
/// repository here"). A gate that re-asked on every iteration of a 60-iteration turn
/// would spawn sixty processes to learn one bit about the directory.
fn gitRepoCached(io: std.Io) bool {
    if (git_repo_probe) |known| return known;
    const answer = isGitRepo(io);
    git_repo_probe = answer;
    return answer;
}

/// Forgets the probe, so a `git init` in the middle of a session is picked up.
pub fn forgetGitRepoProbe() void {
    git_repo_probe = null;
}

/// The automatic typecheck's state, with no `Model` in it.
///
/// It is a struct and not three fields on `Model` because there are TWO runners:
/// the TUI and `--chat`, and the automatic check used to exist only in the first
/// one — so the runner every pty test and every measurement in this repo drives
/// edited code and never compiled it. Same root cause as the headless prompt
/// having no routing rules: a second, lesser implementation of the same agent,
/// and every place it diverges is a place where `--chat` is quietly worse.
///
/// One implementation, two owners. The TUI keeps it on the `Model`; the headless
/// runner keeps it on the stack.
/// The gate that decides whether an edit is worth a build at all: does any path in
/// these arguments belong to a file a compiler would care about?
///
/// ## Why it walks the multi-file forms
///
/// It used to read a single `path` key, and `write {files:[...]}` / `edit
/// {files:[...]}` have none — so the multi-file calls, which are the ones the prompt
/// pushes the model towards ("ONE call for nine files, not nine calls"), were exactly
/// the ones that never started a check. The comment on the old version said this was
/// "the wrong direction" and left it wrong.
///
/// It is the wrong direction because an argument the harness cannot read must not be
/// the reason a broken build goes unnoticed. Now every path in either form counts, and
/// ONE of them being code is enough: the check runs on the PROJECT, not on the file.
///
/// ## Deliberately optimistic
///
/// An unknown extension still triggers a check (`worthChecking` says what it says),
/// because "we do not know what this file is" is not "this changed no code".
pub fn codePathsFromArgs(args_json: []const u8, arena: std.mem.Allocator) bool {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch return false;
    if (parsed != .object) return false;
    return pathsWorthChecking(parsed.object);
}

/// Is this edit worth a build at all? The optimistic reading.
///
/// `codePathsFromArgs` is the strict one and answers false for arguments it cannot
/// read; this one answers true for them, and the difference is the whole asymmetry
/// argument in `noteWrite`'s doc: not knowing what the file is is not the same as the
/// file not being code, and the price of guessing wrong is one honest "not verified"
/// line against the price of the other guess, which is a turn that announces finished
/// work over code nobody compiled.
///
/// It only ever says MORE yes than the strict one, never less: it delegates, so a path
/// the strict reader proved was a README is still not worth a build here.
fn worthATurn(args_json: []const u8, arena: std.mem.Allocator) bool {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch return true;
    if (parsed != .object) return true;
    return pathsWorthChecking(parsed.object);
}

fn pathsWorthChecking(obj: std.json.ObjectMap) bool {
    if (obj.get("path")) |v| {
        if (v == .string and typecheck_mod.worthChecking(v.string)) return true;
    }
    // `files` is an array of objects, each with its own `path`.
    if (obj.get("files")) |fv| {
        if (fv == .array) {
            for (fv.array.items) |entry| {
                if (entry != .object) continue;
                if (entry.object.get("path")) |v| {
                    if (v == .string and typecheck_mod.worthChecking(v.string)) return true;
                }
            }
        }
    }
    return false;
}

pub const AutoCheck = struct {
    /// The environment these flags are read from.
    ///
    /// A FIELD and not a read of `agent.environ_global`, which is what it used to do:
    /// `AutoCheck` was written to be testable without a `Model` and it was — but it still
    /// reached for a module global twice, so "testable" meant "works right until the
    /// global is uninitialised". Owning the environment is what makes it a value.
    env: ?*const std.process.Environ.Map = null,
    /// The job id, or 0 when there is none. An id and a re-read of the registry is
    /// the whole contract: the output belongs to a background thread's buffer, so it
    /// cannot be a pointer into a turn's arena.
    job: u32 = 0,
    /// THE RULE, as data. Pure and in `lib/exitgate.zig` so it can be asserted with no
    /// TUI and no network; this struct is only the machinery that feeds it.
    ///
    /// It replaced a field here called `last_verdict` that the loop read as
    /// `goal_open and last_verdict == .failed`. That rule was right about red and
    /// wrong about three other things, and each of them was a measured failure:
    /// a red check could not end a turn that had no `/goal` set (which is a plain
    /// "fix this bug", a task about code like any other); a green check from BEFORE the
    /// last edit counted as evidence about the current files; and a check that could not
    /// be run was indistinguishable from a check that had not been started.
    gate: exitgate.Gate = .{},
    /// The command it is running, for the message the model reads. A fixed buffer,
    /// because it outlives the arena that composed it.
    label: [64]u8 = @splat(0),
    label_len: usize = 0,
    /// The command to run, kept so the gate can check at the END of a turn without
    /// walking the project directory again. Fixed buffer, same reason as `label`.
    command: [160]u8 = @splat(0),
    command_len: usize = 0,
    /// How many have been started this turn, so a model that edits nine files in a
    /// row does not start nine builds.
    started_this_turn: u32 = 0,
    /// `gate.writes` when the running job was started: what that check is actually
    /// looking at. Everything written after this is uncovered, and that is what makes a
    /// green stale instead of current.
    job_covers: u32 = 0,
    /// The result of the last completed check, as text for the model.
    ///
    /// A fixed buffer and not an arena slice, because it is read AFTER the arena that
    /// composed it is gone: the gate reads it at the end of the turn, `runOneTurn`
    /// reads it at the start of the next iteration, and `finishAutoCheck` reads it after
    /// both. Ownership in the struct is what makes all three of those safe.
    note: [4096]u8 = @splat(0),
    note_len: usize = 0,
    /// How many problems that check found, for the one-line report.
    problems: usize = 0,
    /// What the finished check actually PROVED.
    ///
    /// `nothing` and not `types`, so that a default-constructed `AutoCheck` claims
    /// nothing: a harness that cannot say what it proved must not say "typechecked"
    /// either. See `typecheck.Plan.kind` for why the distinction is carried at all.
    proof: typecheck_mod.Kind = .nothing,
    /// Whether the REVIEWABLE question has already been answered this turn.
    ///
    /// Separate from `gate.reviewable` because that one is a bool that starts false, and
    /// false means two different things there: "asked, and there is no repository here"
    /// and "not asked yet". A caller that wants to PIN the answer — the tests, which
    /// must not change meaning with the directory they run in — has no way to say which
    /// of the two it means, and a test that gets a different answer inside a git
    /// repository than outside it is a trap with a green light.
    review_known: bool = false,
    /// The gate already said out loud that the code is not verified this turn.
    ///
    /// Once, because a line repeated five times a turn is a line the user learns to
    /// ignore, and the whole point of saying it is that it is read.
    spoke: bool = false,

    /// Per turn. Resetting it here and not per iteration is the difference between
    /// "two builds per turn" and "two builds per iteration for the rest of the
    /// session".
    pub fn resetTurn(self: *AutoCheck, reg: *bgproc.Registry, io: std.Io) void {
        _ = io;
        // `reviewable` is NOT probed here.
        //
        // It was, and it was wrong twice. A `git rev-parse` per TURN is a subprocess to
        // learn a fact about the DIRECTORY, which cannot change from inside a turn; and
        // putting it in `resetTurn` made the probe run against whatever `Io` the caller
        // had — including `undefined`, which is what the tests pass, so the test crashed
        // with a general protection fault instead of failing an assertion.
        //
        // So the probe is LAZY and CACHED, in `gitRepoCached`: the first gate call that
        // needs the answer pays for it and every later one reads the cached bool. The
        // cache is reset by `/new` and by `--resume`, which are the only two moments the
        // directory can have become a repository while zode was running.
        self.started_this_turn = 0;
        self.gate.reset();
        self.problems = 0;
        self.spoke = false;
        self.review_known = false;
        self.note_len = 0;
        self.job_covers = 0;
        self.label_len = 0;
        self.command_len = 0;
        // `proof` too. It is the claim the end-of-turn report makes about code THIS turn
        // wrote, and a turn that inherits the previous turn's green is reporting a
        // build that finished before the first edit of this one.
        self.proof = .nothing;
        // The running job is NOT killed.
        //
        // It was, and that made the whole feature useless most of the time. A
        // `zig build` takes seconds; the turn usually ends before it does, so
        // killing it here threw away the one piece of information the feature
        // exists to produce — whether the code the model just wrote compiles. The
        // reason it was killed was "a build from an abandoned turn keeps burning a
        // core", which is true of a job nobody will ever read and false of a 15 s
        // build the next turn is about to read.
        //
        // ESC is the thing that stops a build nobody is waiting for, and it already
        // does (`bgproc.requestKillAll`). A turn boundary is not that.
        _ = reg;
        self.job = 0;
    }

    /// A writing tool SUCCEEDED on code a compiler would care about.
    ///
    /// The counter is the input to the exit gate, so what counts and what does not is
    /// the whole question. Two decisions here, both of them deliberate:
    ///
    /// - Only files `worthChecking` counts. `zig fmt`, a README, a lockfile: a build
    ///   after any of them proves nothing and costs the model an iteration of waiting.
    /// - It is called from the SUCCESS path of the tool, not from the list of calls.
    ///   Before, every call was counted, including a denied one and one that failed to
    ///   apply: both wrote nothing, so both made the gate wait for a check of files
    ///   that still have their old contents — a check that would be green and mean
    ///   nothing at all.
    pub fn noteWrite(self: *AutoCheck, name: []const u8, args_json: []const u8) bool {
        if (!env_mod.truthyIn(self.env, "ZODE_AUTO_CHECK", true)) return false;
        if (!touchesFile(name)) return false;

        // Its own arena, and NOT the caller's. The only thing allocated is one parsed
        // JSON tree of a few hundred bytes, and it is the difference between a function
        // that cannot leak and one where the next caller passes `std.testing.allocator`
        // and 42 allocations show up in a test that has nothing else wrong with it.
        var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        if (!worthATurn(args_json, a)) return false;

        self.gate.noteWrite();
        return true;
    }

    /// Start the project's typecheck, unless one is already running or the turn has
    /// spent its quota. Returns whether a job was started.
    ///
    /// `forced` is the gate's own check at the end of a turn and does NOT consult
    /// `auto_check_per_turn`: that quota exists so a model that edits nine files does
    /// not start nine builds during the turn, and the gate's whole job is to be sure
    /// before it lets the turn end. Conflating them was how the quota would have
    /// blocked the one check that decides the turn.
    pub fn maybeStart(
        self: *AutoCheck,
        reg: *bgproc.Registry,
        io: std.Io,
        forced: bool,
    ) bool {
        if (!env_mod.truthyIn(self.env, "ZODE_AUTO_CHECK", true)) return false;
        if (self.job != 0 and std.mem.eql(u8, bgproc.stateWord(reg, self.job), "running")) return false;
        if (forced) {
            if (!self.gate.canForce()) return false;
        } else if (self.started_this_turn >= auto_check_per_turn) return false;

        if (self.command_len == 0) {
            const plan = check_tool.planAt(io, ".") orelse return false;
            const c = @min(plan.command.len, self.command.len);
            @memcpy(self.command[0..c], plan.command[0..c]);
            self.command_len = c;
            const l = @min(plan.label.len, self.label.len);
            @memcpy(self.label[0..l], plan.label[0..l]);
            self.label_len = l;
            // What this command will have PROVED when it finishes. Recorded with the
            // command so the end-of-turn report cannot claim more than ran.
            self.proof = plan.kind;
        }
        self.gate.checkable = true;

        const id = bgproc.spawn(reg, io, self.command[0..self.command_len]) catch return false;
        self.job = id;
        self.started_this_turn += 1;
        // What this check will be looking at. Writes after this are NOT covered by it,
        // which is the whole point of recording the number here.
        self.job_covers = self.gate.writes;
        self.gate.noteStarted(forced);
        return true;
    }

    /// A writing tool succeeded: count it and, if the turn has budget, start a check.
    ///
    /// `afterTool` used to do both jobs from the list of calls, which is why it also
    /// counted the ones that wrote nothing. Now the counting is `noteWrite`, called
    /// from the success path, and this is only the "maybe start" half.
    pub fn afterTool(
        self: *AutoCheck,
        reg: *bgproc.Registry,
        io: std.Io,
        counted: bool,
    ) void {
        if (!counted) return;
        _ = self.maybeStart(reg, io, false);
    }

    /// Waits (briefly) for the check and then collects it, for a caller that is
    /// about to finish.
    ///
    /// Measured: with the result only read at the START of the next iteration, a
    /// turn that ended right after the edit collected nothing — the `zig build` it
    /// had started was still running — and the next turn's reset killed it. So the
    /// feature produced nothing on exactly the turns it exists for, which is worse
    /// than not having it: the model would say "done" about code nobody compiled.
    ///
    /// The cap is not a guess about how long a build takes: a build longer than this
    /// is a build the user is watching, the job keeps running, and the next turn
    /// reads it. What must not happen is answering about code whose only compile
    /// check is still in flight.
    pub fn autoCheckWait(self: *AutoCheck, reg: *bgproc.Registry) ?[]const u8 {
        if (self.job == 0) return null;
        var waited_ms: u32 = 0;
        while (waited_ms < auto_check_wait_ms) {
            if (!std.mem.eql(u8, bgproc.stateWord(reg, self.job), "running")) break;
            sleep_mod.nap(50);
            waited_ms += 50;
        }
        return self.collect(reg);
    }

    /// The result, if it is ready, as text for the model. Null while it runs.
    ///
    /// It only reports when there IS something wrong. A passing check produces
    /// nothing at all, on purpose: "it compiles" is worth nothing to a model that
    /// was not going to write code anyway, and it is the one message that could be
    /// repeated five times a turn.
    ///
    /// ## What it does to the GATE, and that is the point
    ///
    /// Every exit updates `gate` with the verdict AND with how many writes the check
    /// was looking at. Without the second number a green is a green forever, and a
    /// model that fixed the build and then edited a second file gets believed.
    pub fn collect(self: *AutoCheck, reg: *bgproc.Registry) ?[]const u8 {
        const id = self.job;
        if (id == 0) return null;
        if (std.mem.eql(u8, bgproc.stateWord(reg, id), "running")) return null;

        var out = bgproc.Output{};
        // No header: it is zode's own `[zig build] finished exit=1` line, and a scan
        // for `file:line: error:` finds the whole command inside it.
        const text = bgproc.readNoHeader(reg, &out, id) catch return null;
        // Consumed either way: a job that has been read is done, and leaving the id
        // set would make the NEXT edit report the previous turn's errors.
        self.job = 0;
        const covers = self.job_covers;

        var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_state.deinit();
        const diags = typecheck_mod.extractDiagnostics(arena_state.allocator(), text, 12) catch "";
        if (diags.len == 0) {
            // A check that FAILED and produced no `file:line: error:` is a failure,
            // not a pass. Measured: a `build.zig` that panics prints a source
            // location and a `thread N panic:` line, the scan finds nothing, and
            // silence here would leave the model editing a project whose build does
            // not even run.
            const failed = out.exit != null and out.exit.? != 0;
            if (!failed) {
                self.gate.noteCompleted(.passed, covers);
                self.problems = 0;
                return null;
            }
            self.gate.noteCompleted(.failed, covers);
            self.problems = 1;
            const tail = text[if (text.len > 1500) text.len - 1500 else 0..];
            return self.remember(std.fmt.allocPrint(
                std.heap.page_allocator,
                "[{s} FAILED with exit {d} and reported no type error]\n{s}\nThat usually means the build itself could not run \u{2014} a broken build script, a missing dependency or a panic. Do not treat this as a passing build.",
                .{ self.label[0..self.label_len], out.exit.?, tail },
            ) catch return null);
        }

        self.gate.noteCompleted(.failed, covers);
        self.problems = countDiagLines(diags);
        return self.remember(std.fmt.allocPrint(
            std.heap.page_allocator,
            "[{s} found {d} problem(s) in the code you just wrote]\n{s}\nThis is the project's own compiler, not a guess. Fix these before writing more.",
            .{ self.label[0..self.label_len], self.problems, diags },
        ) catch return null);
    }

    /// Copies a composed note into the struct and returns a slice of IT.
    ///
    /// The copy is what makes the return value safe to read late: the caller that
    /// wants to put the note in the history is not the function that has the arena.
    fn remember(self: *AutoCheck, owned: []const u8) []const u8 {
        const n = @min(owned.len, self.note.len);
        @memcpy(self.note[0..n], owned[0..n]);
        self.note_len = n;
        std.heap.page_allocator.free(owned);
        return self.note[0..n];
    }

    /// The one-line reason, for a message that goes on screen.
    pub fn labelSlice(self: *const AutoCheck) []const u8 {
        return self.label[0..self.label_len];
    }

    /// What the last finished check proved, in the word that is actually true of it.
    pub fn proofPhrase(self: *const AutoCheck) ?[]const u8 {
        return switch (self.proof) {
            .nothing => null,
            else => typecheck_mod.proofWord(self.proof),
        };
    }

    /// The end-of-turn line: what the harness ran, and what it did not.
    ///
    /// ## Why it exists, given the gate already said something
    ///
    /// The gate's refusal is a sentence for the MODEL ("fix these, or declare
    /// `blocked`"). This one is for the USER, and it lands when the turn ends, which is
    /// the last thing on screen before the next prompt. That is the moment a user decides
    /// whether to go and read the diff — so it has to say what was actually proven.
    ///
    /// The wrong version of this line is the one that says "done" or "verified". The
    /// harness ran a typecheck; the tests are the model's to run and it may or may not
    /// have. Claiming the suite on its behalf is the same class of error as announcing
    /// finished work over a red build, and it is easier to miss because it is the
    /// cheerful one.
    pub fn proofLine(self: *const AutoCheck, gpa: std.mem.Allocator) ?[]u8 {
        return switch (self.proof) {
            // The word that matters is "NOT", and it comes first. A user who reads
            // "nothing was checked" as a footnote and "code is NOT verified" as a
            // headline is reading two different reports, and the headline is the one
            // they act on.
            .nothing => std.fmt.allocPrint(
                gpa,
                "· NOT verified: this turn's code has no check behind it ({s}) — this project has no typecheck the harness knows how to run",
                .{typecheck_mod.proofWord(.nothing)},
            ) catch null,
            .types => std.fmt.allocPrint(
                gpa,
                "· {s} {s} the code you just wrote. That is the compiler, not the tests — the project's test suite is the model's to run.",
                .{ typecheck_mod.proofWord(.types), self.labelSlice() },
            ) catch null,
            .syntax => std.fmt.allocPrint(
                gpa,
                "· {s} {s}: the files parse. That is all this language's default check can tell you, and it is not a typecheck.",
                .{ typecheck_mod.proofWord(.syntax), self.labelSlice() },
            ) catch null,
            .tests => std.fmt.allocPrint(
                gpa,
                "· {s} {s} and its tests passed.",
                .{ typecheck_mod.proofWord(.tests), self.labelSlice() },
            ) catch null,
        };
    }

    pub fn noteSlice(self: *const AutoCheck) []const u8 {
        return self.note[0..self.note_len];
    }

    /// THE EXIT GATE, as a wrapper over the pure rule.
    ///
    /// `lib/exitgate.zig` says WHAT may end a turn; this says how the harness goes and
    /// finds out: it waits for a check that is in flight, collects it, and — if the
    /// code is still unverified — starts ONE more check of its own and waits again.
    ///
    /// It returns null when the turn may end, or a `gpa`-owned message saying why it
    /// may not. One message, built once, used by both runners: `--chat` and the TUI
    /// were two lesser copies of this decision and every place they differed was a
    /// place where the headless agent quietly finished a task with a red build.
    ///
    /// Why it waits HERE and not at the end of the turn
    ///
    /// `finishAutoCheck` did wait, and it did it after the loop had already decided to
    /// end. That ordering is the bug this function replaces: the diagnostics were
    /// collected, put in the history and read by nobody. The model was told "done"
    /// about code that did not compile, and the one iteration that could have fixed it
    /// had already been spent.
    ///
    /// ## Why a check that outruns the cap does not hold the turn
    ///
    /// A build longer than the cap is a build the user is watching, and it keeps
    /// running for the next turn to read. Blocking here would be the harness deciding
    /// that a slow compile is worth more than the user's session. So the verdict is
    /// "still running", it says so out loud, and the turn goes.
    pub fn exitGate(
        self: *AutoCheck,
        reg: *bgproc.Registry,
        gpa: std.mem.Allocator,
        io: std.Io,
    ) ?[]u8 {
        // The one probe of the session, here and not in `resetTurn`: see the note on
        // `gitRepoCached`. It only runs when the turn has actually written something,
        // which is the first moment the question is worth a subprocess.
        if (!self.review_known and self.gate.wroteCode()) {
            self.review_known = true;
            self.gate.reviewable = gitRepoCached(io);
        }
        switch (self.decideNow(reg, io)) {
            .end => return null,
            .cannot_verify => return self.sayUnverified(gpa, "no check is known for this project"),
            .still_running => return std.fmt.allocPrint(
                gpa,
                "Your turn cannot end yet: {s} is STILL RUNNING as job {d} and its verdict is unknown. Poll it with `bash_output` (that is what it is for) and carry on working while it goes. Do not end the turn on an unknown verdict.",
                .{ self.labelSlice(), self.job },
            ) catch null,
            // The code compiles and nobody has read the diff. It is the LAST refusal on
            // purpose: a red build is worth more than an unread diff, so by the time the
            // gate gets here the build is already accounted for.
            .refused_review => return review_mod.missingText(gpa, self.gate.unreviewed()) catch null,
            .refused_failed => return std.fmt.allocPrint(
                gpa,
                "not done: the last {s} was RED and this turn would end on code that does not build. Fix the problems, or declare `blocked` with what would unblock it.",
                .{self.labelSlice()},
            ) catch null,
            .refused_unverified => {
                // One more check of the CURRENT files, because the only way to turn an
                // unchecked green into a checked one is to look at what is there now.
                if (!self.maybeStart(reg, io, true)) {
                    return self.sayUnverified(gpa, "no check is known for this project");
                }
                switch (self.decideNow(reg, io)) {
                    .end => return null,
                    .cannot_verify => return self.sayUnverified(gpa, "no check is known for this project"),
                    .still_running => return std.fmt.allocPrint(
                        gpa,
                        "Your turn cannot end yet: {s} is STILL RUNNING as job {d} and its verdict is unknown. Poll it with `bash_output` and carry on working while it goes.",
                        .{ self.labelSlice(), self.job },
                    ) catch null,
                    .refused_review => return review_mod.missingText(gpa, self.gate.unreviewed()) catch null,
                    .refused_failed => return std.fmt.allocPrint(
                        gpa,
                        "not done: {s} found {d} problem(s) in the code you just wrote and this turn would end on it. Fix them, or declare `blocked`.",
                        .{ self.labelSlice(), self.problems },
                    ) catch null,
                    .refused_unverified => return self.sayUnverified(
                        gpa,
                        "the code you wrote is still not covered by a finished check",
                    ),
                }
            },
        }
    }

    /// Wait for what is in flight, collect it, and ask the pure rule.
    fn decideNow(self: *AutoCheck, reg: *bgproc.Registry, io: std.Io) exitgate.Decision {
        _ = io;
        if (self.job != 0) {
            var waited_ms: u32 = 0;
            while (waited_ms < auto_check_wait_ms) {
                if (!std.mem.eql(u8, bgproc.stateWord(reg, self.job), "running")) break;
                sleep_mod.nap(50);
                waited_ms += 50;
            }
            _ = self.collect(reg);
        }
        const d = self.gate.decide();
        // A check still in flight at the cap is neither red nor green: it is unknown.
        //
        // It used to end the turn on that, with one line saying so, and that was the hole
        // this whole feature has had since the beginning: a project whose build takes
        // 45 s NEVER gets verified, because every turn gives up at 4 s. The turn ends
        // with "not verified" on code that was 41 seconds from being green, and the
        // model has learned that the gate is a formality it can wait out.
        //
        // Now it is a REFUSAL instead, and the model does the waiting: `bash_output` on
        // the job, which is the one thing it is good at, while the iteration budget
        // carries the turn. What this deliberately does NOT do is block the thread —
        // the cap is still a cap, because a slow compile must not freeze the user's
        // session, and it is the MODEL that has to decide whether to wait or to say the
        // turn is unverified.
        if (self.job != 0 and self.gate.running and d == .refused_unverified) return .still_running;
        return d;
    }

    /// The "this is NOT verified" line, ONCE per turn.
    ///
    /// Returns null only if the allocation failed, and the caller treats that as "the
    /// turn may end": the alternative to a line is not a crash, it is a turn that ends
    /// without the warning, which is exactly where this function was already.
    /// `pub` and not `fn` only so a test in this module can call it directly: it is
    /// the wording of a refusal, and "the refusal says what to do" is a property of
    /// the text that a test should be able to read without standing up a whole turn.
    pub fn sayUnverified(self: *AutoCheck, gpa: std.mem.Allocator, why: []const u8) ?[]u8 {
        if (self.spoke) {
            return std.fmt.allocPrint(
                gpa,
                "the code you wrote is still NOT verified ({s}). Say so when you report.",
                .{why},
            ) catch null;
        }
        self.spoke = true;
        return std.fmt.allocPrint(
            gpa,
            "the code you wrote is NOT verified: {s}. Say that in your answer instead of implying it works.",
            .{why},
        ) catch null;
    }
};

/// What the last verification of this turn said. Kept as a name because it is read
/// from the status line and from `/bench`; the rule itself is `exitgate.Decision`.
pub const Verdict = exitgate.Verdict;

// ── tests ────────────────────────────────────────────────────────

const t = std.testing;

test "ZODE_AUTO_CHECK is read from the AutoCheck's OWN environment" {
    // The bug this pins is one this file was born with. `AutoCheck` used to call
    // `envTruthy("ZODE_AUTO_CHECK", …)`, which read the MODULE global — and the module
    // global belongs to the file it moved out of, which is a cycle, so the call became
    // an `env` FIELD instead.
    //
    // And a field nobody assigns is the worst kind of change: `env` defaults to null,
    // null means "no environment", and null means the DEFAULT for every flag. So the
    // harness would have worked perfectly with `ZODE_AUTO_CHECK=0` and been unable to
    // turn it ON, with no error, no warning, and a test suite entirely green.
    //
    // It is asserted here rather than at the two construction sites in `main.zig`,
    // because a test at a construction site only proves someone remembered to run it.
    var map: std.process.Environ.Map = .init(t.allocator);
    defer map.deinit();
    map.put("ZODE_AUTO_CHECK", "0") catch return error.OutOfMemory;

    var ac: AutoCheck = .{};
    // With no environment the flag takes its default, and the default is ON: not
    // counting writes is the dangerous direction.
    try t.expect(ac.noteWrite("write", "{\"path\":\"src/a.zig\"}"));

    var off: AutoCheck = .{};
    attachEnv(&off, &map);
    try t.expect(!off.noteWrite("write", "{\"path\":\"src/a.zig\"}"));
    try t.expectEqual(@as(u32, 0), off.gate.writes);

    // And on again, with the same map changed, proves it is read LIVE and not cached in
    // a way that a second construction could get wrong.
    map.put("ZODE_AUTO_CHECK", "1") catch return error.OutOfMemory;
    var on: AutoCheck = .{};
    attachEnv(&on, &map);
    try t.expect(on.noteWrite("write", "{\"path\":\"src/a.zig\"}"));
}

test "the env is a VALUE, not a reference to somebody else's map" {
    // It is a pointer, so this is about what the type lets you do: `AutoCheck` is a
    // struct that travels (it lives on the Model, and on the stack in `--chat`), and a
    // pointer to a process-wide map is a lifetime nobody has to think about only while
    // the process is alive. Passing the map in means the tests can hand it their own,
    // which is the whole point of the field existing.
    var ac: AutoCheck = .{};
    try t.expect(ac.env == null);
    var map: std.process.Environ.Map = .init(t.allocator);
    defer map.deinit();
    attachEnv(&ac, &map);
    try t.expect(ac.env != null);
}
