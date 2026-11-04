//! The task pipeline: classification, budgets and report parsing.
//!
//! ## What this is
//!
//! zode can run a non-trivial task as a strictly ordered pipeline instead of
//! one free-running loop:
//!
//!     Explorer → Investigator? → Implementer → Tester? → verify
//!             → Code-Review → (one repair) → summary
//!
//! This file owns the PURE parts of that pipeline — what a "code task" is,
//! whether the task says to omit tests, how to read the review's verdict —
//! with no I/O, no Model and no network, so they are testable without standing
//! anything up. The runner lives in `agent.zig` and is the only place that
//! touches the world.
//!
//! ## The one asymmetry that matters
//!
//! The pipeline is started by the HARNESS, not negotiated with the model, and
//! nothing inside a stage can call ahead to another stage. The sequence is a
//! state machine in code; the model works inside one stage at a time and never
//! gets the say-so to skip a stage.

const std = @import("std");

/// How strict the automatic mode is.
///
///   auto   — trigger on a task-intent with a code signal (see `classify`).
///   off    — never start the pipeline implicitly. `/pipeline` still works.
///   always — start the pipeline for every top-level turn (except slash
///            commands and `!` lines, which never reach the classifier).
pub const Mode = enum { off, auto, always };

/// Read the mode from `ZODE_PIPELINE`. Unknown values are `auto` — turning the
/// safety net off has to be deliberate.
pub fn modeFrom(raw: ?[]const u8) Mode {
    const v = raw orelse return .auto;
    if (std.ascii.eqlIgnoreCase(v, "off")) return .off;
    if (std.ascii.eqlIgnoreCase(v, "auto")) return .auto;
    if (std.ascii.eqlIgnoreCase(v, "always")) return .always;
    return .auto;
}

/// The result of looking at a user prompt before the turn starts.
pub const Verdict = struct {
    /// Run the pipeline for this prompt.
    wants_pipeline: bool = false,
    /// The task explicitly says to skip the Tester stage (and its verify pass).
    omit_tests: bool = false,
    /// The task explicitly says to skip the Code-Review stage.
    omit_review: bool = false,
    /// One word for logs: which signal fired ("path+intent", "install", "always").
    reason: []const u8 = "",
};

/// Case-insensitive substring with the index it was found at (or null).
/// ASCII only: the trigger words are all ASCII.
fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// Case-insensitive substring with word boundaries on both sides, unless the
/// pattern itself starts/ends inside a word by construction.
fn containsWordIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    var rest = haystack;
    while (indexOfIgnoreCase(rest, needle)) |idx| {
        const before_ok = idx == 0 or !isWordByte(rest[idx - 1]);
        const after = idx + needle.len;
        const after_ok = after >= rest.len or !isWordByte(rest[after]);
        if (before_ok and after_ok) return true;
        rest = rest[idx + 1 ..];
    }
    return false;
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c);
}

/// The change verbs that make a prompt a code TASK. Deliberately bilingual:
/// this project is written in English and driven in Spanish, and both have to
/// hit the heuristic.
const change_intents = [_][]const u8{
    "implement",  "implementation", "implementa", "implementar",
    "fix",        "corrige",       "corregir",   "arregla",   "arreglar",
    "bug",        "refactor",      "refactoring",
    "migrate",    "migra",         "migracion",
    "port",       "retarget",      "rewrite",    "reimplement",
    "add",        "crea",          "create",     "nueva",     "nuevo",
    "feature",    "wire",          "integra",    "integrate", "integración",
    "corrije",    "repara",
};

/// A path-like signal: any of these substrings means the prompt names a file
/// or a config root somewhere in the task.
const path_signals = [_][]const u8{
    ".zig",   ".zon",   ".go",   ".ts", ".tsx", ".js",  ".jsx",
    ".rs",    ".py",    ".c",    ".h",  ".cc",  ".cpp", ".cxx",
    ".toml",  ".json",  ".yaml", ".yml",
    "src/",   "build.zig",  "package.json",  "Cargo.toml",  "go.mod",
    "pyproject.toml",  "mix.exs",  "pom.xml",   "build.gradle",
    "AGENTS.md",
};

/// A dependency-install signal. These alone are enough to warrant the full
/// pipeline: installing is exactly where invented package names and phantom
/// APIs cost the most time.
const install_signals = [_][]const u8{
    "install",      "instal",      "dependency",   "dependenc", "dependencia",
    "dependencies", "setup",       "npm install",  "pip install", "cargo add",
    "go get",       "bun add",     "yarn add",     "installing",
};

fn anyContains(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (indexOfIgnoreCase(haystack, n) != null) return true;
    }
    return false;
}

/// Does `text` tell the harness to skip the Tester? "omit tests" and its many
/// dialects; searched as plain substrings, case-insensitively.
const omit_tests_signals = [_][]const u8{
    "omit test",    "skip test",    "no test",       "omitir test",
    "omite test",   "sin test",     "sin pruebas",   "no tests",
    "no testing",   "desactiva test", "disable test", "sin tests",
    "sin testeo",   "omit tests",   "omitir pruebas",
};

const omit_review_signals = [_][]const u8{
    "omit review",  "skip review",  "no review",     "sin review",
    "omitir review", "sin revisión", "omitir revisión",
};

/// Look at a user prompt. The pipeline fires only with the requested rigor:
/// a change intent is necessary, and it must be matched by either a path
/// signal (the task names a file) or an install signal (it names a package to
/// set up). Everything else is a normal turn.
pub fn classify(text: []const u8) Verdict {
    var v: Verdict = .{};
    v.omit_tests = anyContains(text, &omit_tests_signals);
    v.omit_review = anyContains(text, &omit_review_signals);

    const has_intent = containsWordIgnoreCaseAny(text, &change_intents);
    const has_path = anyContains(text, &path_signals);
    const has_install = anyContains(text, &install_signals);
    // An install task is a task: the model that invents a package name or
    // flags a registry it knows nothing about costs the most time. It fires
    // on its own.
    if (has_install) {
        v.wants_pipeline = true;
        v.reason = "install";
        return v;
    }
    if (has_intent and has_path) {
        v.wants_pipeline = true;
        v.reason = "intent+path";
        return v;
    }
    return v;
}

/// `containsWordIgnoreCase` over a list.
fn containsWordIgnoreCaseAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (containsWordIgnoreCase(haystack, n)) return true;
    }
    return false;
}

/// The pipeline stages, for logs and the status row.
pub const Stage = enum { explorer, investigator, implementer, tester, verify, reviewer, done };

/// One-line name for a stage, used in `pushInfo` notes and the artifacts
/// directory layout.
pub fn stageName(s: Stage) []const u8 {
    return switch (s) {
        .explorer => "explorer",
        .investigator => "investigator",
        .implementer => "implementer",
        .tester => "tester",
        .verify => "verify",
        .reviewer => "reviewer",
        .done => "done",
    };
}

/// Artifacts are written under `.zode/pipeline/<run-id>/`. The run id is
/// `<unix-seconds>-<pid>`, which is unique enough for one working tree and is
/// sortable in listings.
pub fn runIdBuf(buf: []u8, unix_seconds: i64, pid: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{d}-{d}", .{ unix_seconds, pid }) catch "0-0";
}

/// How many repair passes the tester/verifier pair may ask for, past the
/// initial implementation. Bounded, like every other self-repair budget.
pub const max_repair_cycles: u8 = 2;

/// How many bytes of the git diff are embedded in the reviewer's prompt.
/// The reviewer has read tools and can page through files; the embedded diff
/// is its map, not its whole meal.
pub const review_diff_cap: usize = 24 * 1024;

// ── review report parsing ───────────────────────────────────────────────

/// The parsed verdict of a Code-Review report.
pub const ReviewCounts = struct {
    high: u32 = 0,
    medium: u32 = 0,
    low: u32 = 0,
    /// Any line we recognised as a finding was seen. "Report was produced" is
    /// a different fact from "report was valid".
    found_any: bool = false,
    /// True when nothing was found at all (or findings are only notes/low).
    clean: bool = true,
};

/// The reviewer is INSTRUCTED to emit one line per finding:
///
///     SEVERITY: high|medium|low — <file>:<line> — <what> — <why>
///
/// and to end with a line `SEVERITY: none` when there is nothing to say. This
/// parser counts the severity lines, tolerates prose around them and treats a
/// missing `SEVERITY: none` as unknown-but-probably-clean ONLY when there were
/// no high/medium findings. Case-insensitive on the marker, never on the rest.
pub fn parseReviewReport(text: []const u8) ReviewCounts {
    var out: ReviewCounts = .{};
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (indexOfIgnoreCase(line, "severity:")) |idx| {
            line = std.mem.trim(u8, line[idx + "severity:".len ..], " \t");
            if (indexOfIgnoreCase(line, "high") != null) {
                out.high += 1;
                out.found_any = true;
            } else if (indexOfIgnoreCase(line, "medium") != null) {
                out.medium += 1;
                out.found_any = true;
            } else if (indexOfIgnoreCase(line, "low") != null) {
                out.low += 1;
                out.found_any = true;
            } else if (indexOfIgnoreCase(line, "none") != null) {
                out.found_any = true;
            }
            continue;
        }
        // Fallback for a reviewer that ignores the format entirely: count
        // lines that start with "high|medium|low:" or "HIGH -". It is not the
        // contract, it is a safety net, and it only ever over-counts low.
        if (line.len > 5 and indexOfIgnoreCase(line, "critical") != null and
            indexOfIgnoreCase(line, "issue") == null)
        {
            // "critical" alone is too vague to count; do not attribute.
        }
    }
    out.clean = out.high == 0 and out.medium == 0;
    return out;
}

/// The outcome of the test-verify stage for the summary line.
pub const VerifyResult = enum {
    passed,
    failed,
    /// The harness could not detect a test command for this project.
    not_detectable,
    /// The user's task said "omit tests".
    skipped,
};

/// The word for the summary line, mirroring the project's tone rule: the
/// harness reports what it RAN, never what it assumed.
pub fn verifyWord(r: VerifyResult) []const u8 {
    return switch (r) {
        .passed => "tests pass",
        .failed => "tests still failing",
        .not_detectable => "no test command known for this project",
        .skipped => "tests omitted at the task's request",
    };
}

// ── tests ─────────────────────────────────────────────────────

const t = std.testing;

test "modeFrom: default and unknown are auto, off and always work" {
    try t.expectEqual(Mode.auto, modeFrom(null));
    try t.expectEqual(Mode.auto, modeFrom("something-else"));
    try t.expectEqual(Mode.auto, modeFrom("AUTO"));
    try t.expectEqual(Mode.off, modeFrom("off"));
    try t.expectEqual(Mode.off, modeFrom("Off"));
    try t.expectEqual(Mode.always, modeFrom("always"));
}

test "classify: a code task with a path fires the pipeline" {
    const v = classify("implement the retry logic in src/agent.zig");
    try t.expect(v.wants_pipeline);
    try t.expectEqualStrings("intent+path", v.reason);
    try t.expect(!v.omit_tests);
}

test "classify: a code task without a path or install signal does not fire" {
    try t.expect(!classify("fix the logic").wants_pipeline);
    try t.expect(!classify("arregla esto").wants_pipeline);
}

test "classify: an install task fires even with no file in the prompt" {
    const v = classify("install the lodash package");
    try t.expect(v.wants_pipeline);
    try t.expectEqualStrings("install", v.reason);
    try t.expect(classify("npm install lodash").wants_pipeline);
}

test "classify: Spanish and English change intents both hit" {
    try t.expect(classify("corrige el bug en src/main.zig").wants_pipeline);
    try t.expect(classify("arreglar src/main.zig").wants_pipeline);
    try t.expect(classify("migrate the parser to src/lib/ast.zig").wants_pipeline);
}

test "classify: a path alone is not enough, and an intent alone is not either" {
    try t.expect(!classify("src/main.zig").wants_pipeline);
    try t.expect(!classify("rewrite everything").wants_pipeline);
}

test "classify: 'important' is not the word 'port'" {
    try t.expect(!classify("this is important").wants_pipeline);
}

test "classify: omit tests is respected" {
    const v = classify("implement parse.zig, and omit tests please");
    try t.expect(v.omit_tests);
    try t.expect(v.wants_pipeline);
}

test "classify: omit review is respected" {
    const v = classify("fix src/main.zig and skip review");
    try t.expect(v.omit_review);
}

test "parseReviewReport: counts high/medium/low" {
    const report =
        "notes first\n" ++
        "SEVERITY: high — src/a.zig:10 — drops the mutex — deadlock risk\n" ++
        "SEVERITY: medium — src/b.zig:3 — duplicated logic — drift\n" ++
        "SEVERITY: low — src/c.zig:99 — long function — extract it\n" ++
        "SEVERITY: none — summary\n";
    const c = parseReviewReport(report);
    try t.expectEqual(@as(u32, 1), c.high);
    try t.expectEqual(@as(u32, 1), c.medium);
    try t.expectEqual(@as(u32, 1), c.low);
    try t.expect(!c.clean);
    try t.expect(c.found_any);
}

test "parseReviewReport: SEVERITY none means clean" {
    const c = parseReviewReport("everything checked out\nSEVERITY: none\n");
    try t.expectEqual(@as(u32, 0), c.high);
    try t.expect(c.clean);
    try t.expect(c.found_any);
}

test "parseReviewReport: an empty report is clean but NOT known" {
    const c = parseReviewReport("");
    try t.expectEqual(@as(u32, 0), c.high);
    try t.expect(!c.found_any);
}

test "containsWordIgnoreCase: boundaries on both sides" {
    try t.expect(containsWordIgnoreCase("add tests to src/x.zig", "add"));
    try t.expect(!containsWordIgnoreCase("address the issue", "add"));
    try t.expect(containsWordIgnoreCase("Fix the bug", "fix"));
    try t.expect(!containsWordIgnoreCase("suffix the bug", "fix"));
}
