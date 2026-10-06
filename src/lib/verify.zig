const std = @import("std");

/// Classifies a `bash` command by HOW LONG IT IS GOING TO TAKE, and whether it
/// is a verification at all.
///
/// It exists because of the complaint that started this: harnesses that write
/// their own verification scripts, run the whole suite after every edit, and take
/// forever to finish a task that was one line. The mechanism was already there
/// (`run_in_background`) but it depended on the model remembering to use it, and a
/// model that forgets costs the user thirty seconds of frozen input per turn.
///
/// So the harness decides, not the model: a command that matches a known slow
/// verification is started in the background and the model is told to keep working
/// and poll with `bash_output`. That is the difference between a tool call that
/// takes 40 seconds and one that takes 40 milliseconds.
///
/// Pure and without I/O on purpose: this is a table, and a table is testable.
pub const Kind = enum {
    /// Fast: it returns in well under a second. Runs in the foreground.
    quick,
    /// A verification that is known to be slow (a full build, a test suite, a
    /// fuzzer, a pty harness). Goes to the background unless the caller opted out.
    slow_verify,
    /// Something else that could be slow (an install, a server, a `watch`).
    /// Left to the model's judgement: guessing wrong here is worse than being
    /// slow, because a backgrounded `git commit` is a job nobody is polling.
    unknown,
};

const rule = struct {
    /// A substring of the command line.
    needle: []const u8,
    kind: Kind,
    /// Only counts when the command STARTS with this (after `&&`, `;`, `|`),
    /// which is what keeps `echo "run the tests"` from being a test run.
    at_start: bool = true,
};

/// The table.
///
/// Ordered: the first match wins, so the specific patterns come before the broad
/// ones (`npm test` before `npm`).
const rules = [_]rule{
    // ── Zig ──
    .{ .needle = "zig build", .kind = .slow_verify },
    .{ .needle = "zig test", .kind = .slow_verify },
    // `zig fmt` REWRITES files, so it is not in the read-only set, but it is
    // fast: seconds, not minutes.
    .{ .needle = "zig fmt", .kind = .quick },
    // ── package managers / build tools ──
    .{ .needle = "npm test", .kind = .slow_verify },
    .{ .needle = "npm run build", .kind = .slow_verify },
    .{ .needle = "npm ci", .kind = .slow_verify },
    .{ .needle = "npm install", .kind = .slow_verify },
    .{ .needle = "pnpm test", .kind = .slow_verify },
    .{ .needle = "pnpm build", .kind = .slow_verify },
    .{ .needle = "yarn test", .kind = .slow_verify },
    .{ .needle = "yarn build", .kind = .slow_verify },
    .{ .needle = "bun test", .kind = .slow_verify },
    .{ .needle = "cargo test", .kind = .slow_verify },
    .{ .needle = "cargo build", .kind = .slow_verify },
    .{ .needle = "cargo check", .kind = .quick },
    .{ .needle = "cargo clippy", .kind = .slow_verify },
    .{ .needle = "go test", .kind = .slow_verify },
    .{ .needle = "go build", .kind = .slow_verify },
    .{ .needle = "go vet", .kind = .quick },
    .{ .needle = "mvn test", .kind = .slow_verify },
    .{ .needle = "gradle test", .kind = .slow_verify },
    .{ .needle = "gradle build", .kind = .slow_verify },
    .{ .needle = "make test", .kind = .slow_verify },
    .{ .needle = "make check", .kind = .slow_verify },
    .{ .needle = "make build", .kind = .slow_verify },
    .{ .needle = "make", .kind = .slow_verify, .at_start = false },
    // `just` and `task` are the same idea as make with two words of config, and every
    // repository that uses one has its whole test suite behind it.
    //
    //
    // The trailing space is LOAD-BEARING and it took two tries to get right, in
    // opposite directions:
    //
    //   - `at_start = false` needs a NON-word byte AFTER the needle, so `"just "` never
    //     fired at all (the `t` of `test` is a word byte) and `./scripts/` never fired
    //     for the same reason. A rule that reads right and matches nothing.
    //   - `at_start = true` has no such check, so a bare `"just"` fired on `just-file.md`
    //     and on anything else starting with those four letters.
    //
    // So: `at_start` AND a trailing space. The space is the word boundary, and
    // `at_start` is what stops "just" matching inside another word. The cost is that a
    // bare `just` (no recipe) stays in the foreground, which is the safe direction to
    // be wrong in.
    .{ .needle = "just ", .kind = .slow_verify, .at_start = true },
    .{ .needle = "justfile", .kind = .slow_verify, .at_start = false },
    .{ .needle = "task ", .kind = .slow_verify, .at_start = true },
    // ── elixir / ruby / dotnet / bazel ──
    .{ .needle = "mix test", .kind = .slow_verify },
    .{ .needle = "mix compile", .kind = .slow_verify },
    .{ .needle = "mix deps.get", .kind = .unknown },
    .{ .needle = "bundle exec rspec", .kind = .slow_verify },
    .{ .needle = "bundle exec rake", .kind = .slow_verify },
    .{ .needle = "rspec", .kind = .slow_verify },
    .{ .needle = "dotnet test", .kind = .slow_verify },
    .{ .needle = "dotnet build", .kind = .slow_verify },
    .{ .needle = "bazel test", .kind = .slow_verify },
    .{ .needle = "bazel build", .kind = .slow_verify },
    // ── a repository's OWN script, which is what most of them use ──
    //
    // `./scripts/ci.sh`, `./test.sh`, `bin/test`: no keyword to match, so the rule is
    // on the SHAPE. It is deliberately narrow — a file that merely starts with "test"
    // is not a test run — and it is `at_start = false` so `cd x && ./scripts/ci.sh`
    // still matches through the wrapper handling.
    // NO trailing slash. `containsAtWord` needs a non-word byte AFTER the needle, and
    // the `/` in `./scripts/` is followed by `c` — so the rule with the slash never
    // fires on anything. `.`, `/`, `-` and `_` are boundaries here on purpose (that is
    // what makes `fuzz` match `fuzz.py`), and a needle has to respect it.
    .{ .needle = "./scripts", .kind = .slow_verify, .at_start = false },
    .{ .needle = "./test.sh", .kind = .slow_verify },
    .{ .needle = "./run-tests", .kind = .slow_verify },
    .{ .needle = "bin/test", .kind = .slow_verify, .at_start = false },
    // ── python ──
    .{ .needle = "pytest", .kind = .slow_verify },
    .{ .needle = "python -m pytest", .kind = .slow_verify },
    .{ .needle = "python3 -m pytest", .kind = .slow_verify },
    .{ .needle = "python3 -m unittest", .kind = .slow_verify },
    .{ .needle = "unittest", .kind = .slow_verify },
    .{ .needle = "tox", .kind = .slow_verify },
    .{ .needle = "mypy", .kind = .slow_verify },
    .{ .needle = "ruff", .kind = .quick },
    // ── rust / c / c++ ──
    .{ .needle = "cargo-nextest", .kind = .slow_verify },
    .{ .needle = "ctest", .kind = .slow_verify },
    .{ .needle = "meson test", .kind = .slow_verify },
    .{ .needle = "ninja", .kind = .slow_verify },
    .{ .needle = "make -j", .kind = .slow_verify },
    // ── js / ts ──
    .{ .needle = "jest", .kind = .slow_verify },
    .{ .needle = "vitest", .kind = .slow_verify },
    .{ .needle = "playwright", .kind = .slow_verify },
    .{ .needle = "cypress", .kind = .slow_verify },
    .{ .needle = "tsc -b", .kind = .slow_verify },
    .{ .needle = "tsc --build", .kind = .slow_verify },
    .{ .needle = "webpack", .kind = .slow_verify },
    .{ .needle = "vite build", .kind = .slow_verify },
    .{ .needle = "next build", .kind = .slow_verify },
    // ── the harnesses themselves ──
    //
    // A fuzzer or a pty script IS a verification and it is the slowest thing
    // anyone writes. It goes to the background like everything else, which is the
    // point: writing one is fine, blocking the session on one is not.
    .{ .needle = "fuzz", .kind = .slow_verify, .at_start = false },
    .{ .needle = "smoke.py", .kind = .slow_verify, .at_start = false },
    .{ .needle = "smoke_test", .kind = .slow_verify, .at_start = false },
    .{ .needle = "esc_kill_pty", .kind = .slow_verify, .at_start = false },
    // ── installs and servers: slow, but not verifications ──
    .{ .needle = "pip install", .kind = .unknown },
    .{ .needle = "uv sync", .kind = .unknown },
    .{ .needle = "docker build", .kind = .unknown },
    .{ .needle = "docker compose up", .kind = .unknown },
    // ── things that are quick no matter how they look ──
    .{ .needle = "git status", .kind = .quick },
    .{ .needle = "git diff", .kind = .quick },
    .{ .needle = "git log", .kind = .quick },
    .{ .needle = "ls", .kind = .quick },
    .{ .needle = "cat", .kind = .quick },
};

/// What the harness decided about one command.
pub const Verdict = struct {
    kind: Kind,
    /// The rule that fired, for the message the model reads. Empty when nothing
    /// matched.
    matched: []const u8 = "",
};

pub fn classify(command: []const u8) Verdict {
    if (std.mem.trim(u8, command, " \t\n").len == 0) return .{ .kind = .quick };
    for (rules) |r| {
        if (r.at_start) {
            if (commandStartsWith(command, r.needle)) return .{ .kind = r.kind, .matched = r.needle };
        } else {
            if (containsAtWord(command, r.needle)) return .{ .kind = r.kind, .matched = r.needle };
        }
    }
    return .{ .kind = .unknown };
}

/// Does the command, ignoring leading `cd`/`env`/`sudo` and any separators,
/// begin with `needle`?
///
/// The separators matter because the real shape of a model's command is
/// `cd /tmp/x && zig build test`. Without them the classifier would miss the one
/// case it exists for.
fn commandStartsWith(command: []const u8, needle: []const u8) bool {
    var rest = std.mem.trim(u8, command, " \t\n");
    while (true) {
        // Skip the wrappers a command arrives wrapped in.
        const prefixes = [_][]const u8{
            "env ",        "sudo ",       "nice ",  "time ",     "command ",
            "npx ",        "pnpm dlx ",   "bunx ",  "yarn dlx ", "uv run ",
            "poetry run ", "pipenv run ", "xargs ",
        };
        var skipped = false;
        for (prefixes) |p| {
            if (std.mem.startsWith(u8, rest, p)) {
                rest = std.mem.trim(u8, rest[p.len..], " \t\n");
                skipped = true;
                break;
            }
        }
        if (skipped) continue;
        // `VAR=1 cmd` and `cd dir && cmd`.
        if (isEnvAssignment(rest)) {
            const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse return false;
            rest = std.mem.trim(u8, rest[sp + 1 ..], " \t\n");
            continue;
        }
        if (std.mem.startsWith(u8, rest, "cd ")) {
            const sep = std.mem.indexOfAny(u8, rest, ";&|") orelse return false;
            // ALL the separators: `&&` is two of them, and leaving the second one
            // in place meant `cd x && zig build` never matched anything.
            var j = sep;
            while (j < rest.len and (rest[j] == ';' or rest[j] == '&' or rest[j] == '|')) j += 1;
            rest = std.mem.trim(u8, rest[j..], " \t\n");
            continue;
        }
        break;
    }
    return std.mem.startsWith(u8, rest, needle);
}

fn isEnvAssignment(s: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, s, '=') orelse return false;
    if (eq == 0) return false;
    for (s[0..eq]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    // `a=b` with nothing after it is not a command.
    return std.mem.indexOfScalarPos(u8, s, eq + 1, ' ') != null;
}

/// `needle` appearing in the command as a WHOLE word.
///
/// "Whole word" is the whole reason this function exists: with a plain substring
/// search, `maketar -xf foo.tar` matched the rule `make` and a fast tarball
/// extraction was classified as a build.
fn containsAtWord(command: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    var i: usize = 0;
    while (i + needle.len <= command.len) : (i += 1) {
        if (!std.mem.eql(u8, command[i .. i + needle.len], needle)) continue;
        const before_ok = i == 0 or !isWordByte(command[i - 1]);
        const after_at = i + needle.len;
        const after_ok = after_at >= command.len or !isWordByte(command[after_at]);
        if (before_ok and after_ok) return true;
    }
    return false;
}

fn isWordByte(c: u8) bool {
    // ONLY letters and digits are word characters here. `.`, `/`, `-` and `_` are
    // boundaries on purpose: with `.` inside the word, the rule `fuzz` did not
    // match `fuzz.py`; with `_` inside it, the rule `smoke.py` did not match
    // `pty_smoke.py`. Both are exactly the cases this table exists to catch.
    return std.ascii.isAlphanumeric(c);
}

// ── tests ─────────────────────────────────────────────────────

test "classify: the slow verifications a model actually types" {
    const slow = [_][]const u8{
        "zig build test",
        "zig build",
        "cd /home/x/proyecto && zig build test",
        "npm test",
        "npm run build",
        "cargo test --all",
        "cargo clippy -- -D warnings",
        "pytest -q",
        "python3 -m pytest tests/",
        "go test ./...",
        "make test",
        "CI=1 npm test",
        "sudo zig build",
        "env FOO=1 zig build test",
        "python3 tools/fuzz.py 2000",
        "python3 tools/pty_smoke.py",
        "python3 tools/esc_kill_pty.py",
        "npx playwright test",
        "tsc -b",
    };
    for (slow) |cmd| {
        const v = classify(cmd);
        try std.testing.expectEqual(Kind.slow_verify, v.kind);
        try std.testing.expect(v.matched.len > 0);
    }
}

test "classify: the quick things stay in the foreground" {
    // The whole point is that this does NOT become a background job nobody polls.
    const quick = [_][]const u8{
        "zig fmt --check",
        "git status --short",
        "git diff -- src/tui.zig",
        "ls -la",
        "cat src/main.zig",
        "cargo check",
        "ruff check .",
        "",
    };
    for (quick) |cmd| {
        try std.testing.expectEqual(Kind.quick, classify(cmd).kind);
    }
}

test "classify: an unknown command is left to the model" {
    // Guessing wrong here is worse than being slow: a backgrounded `git commit`
    // is a job nobody polls, and the turn ends without its result.
    const unknown = [_][]const u8{
        "git commit -m 'x'",
        "docker build -t app .",
        "python3 -m http.server 8000",
        "echo 'run the tests when you can'",
        "grep -rn foo src",
    };
    for (unknown) |cmd| {
        try std.testing.expectEqual(Kind.unknown, classify(cmd).kind);
    }
}

test "classify: a table entry that is a SUBSTRING of a word is not a match" {
    // `maketar` must not be a build just because it contains "make".
    try std.testing.expectEqual(Kind.unknown, classify("maketar -xf foo.tar").kind);
    // And `zig fmt` is not `zig build`.
    try std.testing.expectEqual(Kind.quick, classify("zig fmt src/main.zig").kind);
}

test "classify: the FIRST matching rule wins, so the specific ones come first" {
    // `zig build` is a full build and `zig fmt` is not; both start with "zig", so
    // the table order is what decides and it is pinned here.
    try std.testing.expectEqualStrings("zig build", classify("zig build test").matched);
    try std.testing.expectEqualStrings("cargo check", classify("cargo check").matched);
}

test "the rules the other tests assume, checked one by one" {
    // Written out rather than in a loop so a failure names WHICH rule is wrong. The
    // version in a loop said "expected .slow_verify, found .unknown" and pointed at
    // nothing.
    try std.testing.expectEqual(Kind.slow_verify, classify("mix test").kind);
    try std.testing.expectEqual(Kind.slow_verify, classify("dotnet build").kind);
    try std.testing.expectEqual(Kind.slow_verify, classify("just test").kind);
    try std.testing.expectEqual(Kind.slow_verify, classify("./test.sh").kind);
    try std.testing.expectEqual(Kind.slow_verify, classify("bin/test").kind);
    try std.testing.expectEqual(Kind.slow_verify, classify("./scripts/ci.sh").kind);
    try std.testing.expectEqual(Kind.slow_verify, classify("cd /tmp/x && ./scripts/ci.sh").kind);
    // NOT slow_verify, which is the claim: a file that happens to be called `test.txt`
    // is a read, and sending reads to the background would steal the session on them.
    // It lands on `.quick` because of the `cat` rule, which is the better answer.
    try std.testing.expect(classify("cat test.txt").kind != Kind.slow_verify);
    try std.testing.expect(classify("just-file.md").kind != Kind.slow_verify);
}
