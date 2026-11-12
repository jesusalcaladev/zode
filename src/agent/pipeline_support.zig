const std = @import("std");
const pipeline_mod = @import("../lib/pipeline.zig");
const testplan_mod = @import("../lib/testplan.zig");
const testguard_mod = @import("../lib/testguard.zig");
const filesearch = @import("../lib/filesearch.zig");
const tui = @import("../tui.zig");
const subagent_mod = @import("../lib/subagent.zig");

pub const SuiteResult = struct {
    passed: bool,
    /// The last few KB of combined stdout+stderr, for the repair prompt.
    tail: []const u8,
};

/// The harness runs the test suite itself. The model never grades its own work.
pub fn runTestSuite(
    arena: std.mem.Allocator,
    io: std.Io,
    plan: testplan_mod.Plan,
) SuiteResult {
    const result = std.process.run(arena, io, .{
        .argv = plan.argv,
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(15 * 60), .clock = .awake } },
    }) catch |err| {
        const msg = std.fmt.allocPrint(arena, "the test command could not start: {t}", .{err}) catch "";
        return .{ .passed = false, .tail = msg };
    };
    const full = arena.alloc(u8, result.stdout.len + result.stderr.len + 1) catch
        return .{ .passed = false, .tail = "(out of memory)" };
    @memcpy(full[0..result.stdout.len], result.stdout);
    full[result.stdout.len] = '\n';
    @memcpy(full[result.stdout.len + 1 ..][0..result.stderr.len], result.stderr);
    const tail_len = @min(full.len, 3000);
    return .{ .passed = result.term.success(), .tail = full[full.len - tail_len ..] };
}

/// `git diff HEAD`, capped for the reviewer's prompt. Empty outside a repo.
pub fn gitDiffHEAD(arena: std.mem.Allocator, io: std.Io) []const u8 {
    const result = std.process.run(arena, io, .{
        .argv = &.{ "git", "diff", "HEAD" },
        .stdout_limit = .limited(pipeline_mod.review_diff_cap * 2),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } },
    }) catch return "";
    const diff = result.stdout;
    if (diff.len <= pipeline_mod.review_diff_cap) return diff;
    const n = pipeline_mod.review_diff_cap;
    const buf = arena.alloc(u8, n + 64) catch return diff[0..n];
    @memcpy(buf[0..n], diff[0..n]);
    const tail = std.fmt.bufPrint(buf[n..], "\n[diff truncated at {d} KB — ask for specific files]\n", .{n / 1024}) catch "";
    return buf[0 .. n + tail.len];
}

/// `git status --short`, capped. Tells the reviewer which files are new.
pub fn gitStatusShort(arena: std.mem.Allocator, io: std.Io) []const u8 {
    const result = std.process.run(arena, io, .{
        .argv = &.{ "git", "status", "--short" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    }) catch return "";
    return result.stdout;
}

/// Artifacts directory for this run: `.zode/pipeline/<unix>-<pid>`.
pub fn pipelineRunDir(buf: []u8, io: std.Io) ?[]const u8 {
    const ts = std.Io.Timestamp.now(io, .real).toSeconds();
    const pid: usize = @intCast(std.os.linux.getpid());
    var id_buf: [64]u8 = undefined;
    const id = pipeline_mod.runIdBuf(&id_buf, ts, pid);
    return std.fmt.bufPrint(buf, ".zode/pipeline/{s}", .{id}) catch null;
}

/// Best-effort write of one artifact. Never fails the run.
pub fn writeArtifact(io: std.Io, run_dir: []const u8, name: []const u8, data: []const u8) void {
    std.Io.Dir.cwd().createDirPath(io, run_dir) catch return;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ run_dir, name }) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch {};
}

/// Case-insensitive substring (ASCII).
pub fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return i;
    }
    return null;
}

/// Whether this task likely needs external/world investigation.
pub fn needsInvestigation(task_text: []const u8, evidence: []const u8) bool {
    const external_signals = [_][]const u8{
        "install",    "instal",    "dependenc", "dependencia", "dependency",
        "api",        "package",   "library",   "npm",         "pip",
        "cargo add",  "go get",    "import",    "crate",       "endpoint",
        "web_search", "web_fetch", "http",      "url",
    };
    for (external_signals) |s| {
        if (indexOfIgnoreCase(task_text, s) != null) return true;
    }
    const unknown_signals = [_][]const u8{
        "UNKNOWNS:", "unverified", "could not verify", "not sure",
        "GUESS",
    };
    for (unknown_signals) |s| {
        if (indexOfIgnoreCase(evidence, s) != null) return true;
    }
    return false;
}

pub const explorer_prompt =
    "You are the EXPLORER stage of a strict pipeline. You map the territory and produce a concrete implementation brief; you do not change anything.\n" ++
    "Task: {s}\n\n" ++
    "Find: the files and symbols that matter for this task, the existing tests that cover them, the project's conventions for code like this, the likely touch-points and the risks. Use read, grep, glob, list_files — and nothing else.\n" ++
    "Reply with a compact report of at most 1000 words with these sections, in this order:\n" ++
    "OBJECTIVE: what this task must achieve and how success will be known (observable outcome/tests/checks).\n" ++
    "SCOPE: files/symbols this task touches, one line each with WHY.\n" ++
    "TESTS: which existing tests exercise those paths, or NONE. What verification should run.\n" ++
    "CONVENTIONS: the local style the change must match (naming, error handling, tests).\n" ++
    "APPROACH: how to implement it (strategy, key changes, order/dependencies).\n" ++
    "GUARDRAILS: what must not change or regress, and constraints to respect.\n" ++
    "PLAN: concrete steps, one line each: <what> | how: <file/symbol/command> | verify: <test/check>.\n" ++
    "RISKS: what can break and where.\n" ++
    "UNKNOWNS: what you could not determine. If you used a guess, say GUESS explicitly.\n";

pub const investigator_prompt =
    "You are the INVESTIGATOR stage of a strict pipeline. You verify claims about the outside world; you never invent.\n" ++
    "Task: {s}\n\n" ++
    "Explorer's findings:\n{s}\n\n" ++
    "Use web_fetch / web_search (and anything local: installed packages, --help, the dependency's own source if present) to verify what the task or the findings leave uncertain: API names, versions, flags, package names, breaking changes.\n" ++
    "Rules: every claim carries a source (URL or local path). If you cannot verify it, mark it UNVERIFIED — never fill the gap. Call out constraints/guardrails that affect the implementation approach.\n" ++
    "Reply with at most 800 words:\n" ++
    "VERIFIED: <claim> — <source> (one line each)\n" ++
    "UNVERIFIED: <claim> (one line each)\n" ++
    "GUARDRAILS: constraints or risks the implementation must respect, based on evidence.\n" ++
    "RECOMMENDATION: the one approach the evidence supports, with why.\n";

pub const tester_prompt =
    "You are the TESTER stage of a strict pipeline. You write the tests the change needs — you do not fix production code.\n" ++
    "Task: {s}\n\n" ++
    "Evidence and implementation brief:\n{s}\n\n" ++
    "Rules:\n" ++
    "- Add tests for the NEW or CHANGED behavior only, aligned with the task's OBJECTIVE/GUARDRAILS and acceptance criteria in the evidence. Do not reorganize existing tests.\n" ++
    "- NEVER modify or delete an existing test. The harness re-hashes the baseline and the pipeline stops if you touch one.\n" ++
    "- Prefer the project's existing test style (in Zig: top-level test \"...\" blocks in the same file).\n" ++
    "- If the implementation is broken, do NOT fix it: finish your part and report FAILING tests and why. The Implementer fixes the code.\n" ++
    "- If the tests already cover it, add nothing and say so.\n" ++
    "Reply with at most 450 words: what you added, which objective/guardrail each test covers, and the result you expect.\n";

pub const implementer_seed =
    "[Pipeline evidence] This task comes with a pre-researched map and implementation brief from zode's pipeline. Use it; do not re-derive what it already found.\n" ++
    "Task: {s}\n\n" ++
    "## Evidence\n{s}\n\n" ++
    "## Investigator notes\n{s}\n\n" ++
    "Implementation rules:\n" ++
    "- Start by calling `todo` to record a concrete implementation plan from the evidence: include objective, approach, and guardrails, and break work into actionable steps with how (file/symbol/command) and verify (test/check/result). Keep exactly one step in_progress and update it as you go.\n" ++
    "- Follow the OBJECTIVE, APPROACH, GUARDRAILS, and PLAN in the evidence. The map is a starting point, not a boundary: if it missed something, go find it, but do not violate guardrails.\n" ++
    "- Verify each meaningful change (tests/checks) before moving on. Never weaken or delete an existing test — add tests or fix code, or call `goal` blocked with what_would_unblock.\n" ++
    "- When done, report what changed, what was verified (commands/results), and any remaining risks against the guardrails.\n";

pub const verify_repair_prompt =
    "[Pipeline verification] The test suite does not pass. Fix the CODE to satisfy the task objective and guardrails — never weaken the tests or expectations.\n" ++
    "Command: {s}\n\n" ++
    "Output (the last part of it):\n{s}\n\n" ++
    "If a test asserts the OLD behavior and the task changed the behavior on purpose, the test must be UPDATED — but say that out loud in your answer and name the test. If you cannot make it pass without touching tests, call `goal` with status blocked and what_would_unblock.\n";

pub const review_repair_prompt =
    "[Pipeline review] The reviewer found high-severity problems in your diff. Fix the CODE while preserving the task objective and guardrails; do not touch the tests.\n\n" ++
    "{s}\n";

pub const reviewer_prompt =
    "You are the CODE-REVIEW stage of a strict pipeline. You are the skeptical senior engineer; you do not write code.\n" ++
    "Task: {s}\n\n" ++
    "Implementation brief/evidence:\n{s}\n\n" ++
    "Diff:\n{s}\n\n" ++
    "New/changed files (untracked or staged):\n{s}\n\n" ++
    "Review against the task OBJECTIVE, APPROACH, GUARDRAILS, and PLAN: did the change achieve the objective, respect guardrails, and include appropriate verification?\n" ++
    "Report findings as lines, one per finding:\n" ++
    "SEVERITY: high|medium|low — <file>:<line> — <what is wrong> — <why it matters>\n" ++
    "End with `SEVERITY: none` if there is nothing to report.\n" ++
    "Judge: correctness, error handling, edge cases, races, security, tests that assert nothing, dead code, missed guardrails, and clarity. Do not comment on style the project already has — formatting and naming that match the file are not findings.\n";

pub const review_files_prompt =
    "You are the CODE-REVIEW role of zode's pipeline. You are the skeptical senior engineer; you do not write code.\n" ++
    "Review these files. Read whatever you need through the tools.\n\n" ++
    "{s}\n\n" ++
    "Report findings as lines, one per finding:\n" ++
    "SEVERITY: high|medium|low — <file>:<line> — <what is wrong> — <why it matters>\n" ++
    "End with `SEVERITY: none` if there is nothing to report.\n" ++
    "Judge: correctness, error handling, edge cases, races, security, tests that assert nothing, dead code, and clarity. Do not comment on style the project already has.\n";


pub const Snapshot = struct {
    /// Path as reported by the walker (`/`-separated).
    path: []const u8,
    /// Test entries from BEFORE the stages run.
    tests: []const testguard_mod.Entry,
};

/// Scan every tracked `.zig` file under `.` for inline tests. The snapshot
/// is by value in the arena: the text each file had before anything ran.
pub fn snapshotZigTests(arena: std.mem.Allocator, io: std.Io) ![]Snapshot {
    var paths = std.ArrayList([]const u8).empty;
    var root = std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true }) catch return error.NoRoot;
    defer root.close(io);
    var walker = root.walk(arena) catch return error.NoRoot;
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        switch (e.kind) {
            .directory => {
                if (filesearch.skipDir(e.basename)) walker.leave(io);
            },
            .file => {
                if (!std.mem.endsWith(u8, e.path, ".zig")) continue;
                try paths.append(arena, try arena.dupe(u8, e.path));
            },
            else => {},
        }
    }

    var out = std.ArrayList(Snapshot).empty;
    for (paths.items) |p| {
        const text = std.Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(4 * 1024 * 1024)) catch continue;
        const tests = testguard_mod.scan(arena, text) catch continue;
        try out.append(arena, .{ .path = p, .tests = tests });
    }
    return out.toOwnedSlice(arena);
}

pub const Violation = struct {
    path: []const u8,
    missing: []const []const u8,
    changed: []const []const u8,
};

/// Re-scan every snapshotted file and report which baseline tests are gone
/// or different. Files created during the pipeline are not in the baseline
/// and are not verified — a new file cannot weaken an old test.
pub fn verifyZigTests(
    arena: std.mem.Allocator,
    io: std.Io,
    snaps: []const Snapshot,
) ![]Violation {
    var out = std.ArrayList(Violation).empty;
    for (snaps) |s| {
        const text = std.Io.Dir.cwd().readFileAlloc(io, s.path, arena, .limited(4 * 1024 * 1024)) catch {
            // The file is GONE: every baseline test in it is missing.
            const names = arena.alloc([]const u8, s.tests.len) catch continue;
            for (s.tests, 0..) |t, i| names[i] = t.name;
            try out.append(arena, .{ .path = s.path, .missing = names, .changed = &.{} });
            continue;
        };
        const rep = testguard_mod.verify(arena, s.tests, text) catch {
            // Malformed Zig after the stage: report every baseline entry as missing.
            const names = arena.alloc([]const u8, s.tests.len) catch continue;
            for (s.tests, 0..) |t, i| names[i] = t.name;
            try out.append(arena, .{ .path = s.path, .missing = names, .changed = &.{} });
            continue;
        };
        if (!rep.ok()) {
            try out.append(arena, .{ .path = s.path, .missing = rep.missing, .changed = rep.changed });
        }
    }
    return out.toOwnedSlice(arena);
}

/// A short, actionable list of what was violated — the model needs file and
/// NAME, not a boolean.
pub fn formatViolations(arena: std.mem.Allocator, violations: []const Violation) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (violations) |v| {
        try out.print(arena, "{s}:\n", .{v.path});
        for (v.missing) |name| {
            try out.print(arena, "  missing test: {s}\n", .{name});
        }
        for (v.changed) |name| {
            try out.print(arena, "  changed test: {s}\n", .{name});
        }
    }
    return out.toOwnedSlice(arena);
}


pub const ReviewPromptBuild = union(enum) {
    prompt: []const u8,
    nothing_to_review,
    compose_failed,
};

pub fn buildDiffReviewPrompt(arena: std.mem.Allocator, io: std.Io) ReviewPromptBuild {
    const diff = gitDiffHEAD(arena, io);
    const status = gitStatusShort(arena, io);
    if (diff.len == 0 and status.len == 0) return .nothing_to_review;
    const task = "Review the current uncommitted changes for correctness, regressions, and missing verification.";
    const brief = "No pipeline evidence (standalone /code-review). Infer intent from the diff; flag unclear intent as a finding when it affects correctness.";
    const prompt = std.fmt.allocPrint(arena, reviewer_prompt, .{ task, brief, diff, status }) catch return .compose_failed;
    return .{ .prompt = prompt };
}

pub fn buildFilesReviewPrompt(arena: std.mem.Allocator, io: std.Io, trimmed_paths: []const u8) ReviewPromptBuild {
    var files: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, trimmed_paths, " \t\r\n");
    while (it.next()) |path| {
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024)) catch {
            files.print(arena, "— {s}: could not read\n", .{path}) catch {};
            continue;
        };
        files.print(arena, "— {s}:\n\n```\n{s}\n```\n\n", .{ path, text }) catch {};
    }
    const embedded = files.toOwnedSlice(arena) catch "";
    const prompt = std.fmt.allocPrint(arena, review_files_prompt, .{embedded}) catch return .compose_failed;
    return .{ .prompt = prompt };
}


/// Write consolidated implementation brief artifact for traceability/handoff.
pub fn writePipelinePlanArtifact(
    io: std.Io,
    arena: std.mem.Allocator,
    run_dir: []const u8,
    task_text: []const u8,
    evidence: []const u8,
    investigator_notes: []const u8,
) void {
    const plan_md = std.fmt.allocPrint(arena,
        "# Pipeline implementation plan\n\n## Task\n{s}\n\n## Evidence (explorer brief)\n{s}\n\n## Investigator notes\n{s}\n",
        .{ task_text, evidence, investigator_notes },
    ) catch null;
    if (plan_md) |pm| writeArtifact(io, run_dir, "plan.md", pm);
}


/// Run one pipeline subagent and write its report as an artifact.
pub fn runPipelineSubagent(
    m: *tui.Model,
    io: std.Io,
    rep: *subagent_mod.Report,
    label: []const u8,
    prompt: []const u8,
    run_dir: []const u8,
    artifact: []const u8,
    run_subagent: *const fn (*tui.Model, subagent_mod.Task, *subagent_mod.Report) []const u8,
) []const u8 {
    const task = subagent_mod.Task{
        .description = label,
        .prompt = prompt,
        .allow_writes = std.mem.eql(u8, label, "tester"),
        .effort = "low",
    };
    const out = run_subagent(m, task, rep);
    writeArtifact(io, run_dir, artifact, out);
    return out;
}
