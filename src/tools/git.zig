/// `git_status`, `git_diff` and `git_log`.
///
/// **Why these exist at all**, since `bash` can run `git`: three reasons, and the
/// first two are about the agent's own budget rather than about convenience.
///
/// 1. **A whole turn per query.** `bash` is one tool call, and the agent loop
///    counts iterations. `git status` before an edit, `git diff` after, `git log`
///    to see who touched a function, is three iterations — and the loop's limit
///    is 12. Asking the repository what state it is in is not what the iterations
///    are for.
/// 2. **Raw text the model has to parse.** `git status` without `--porcelain` is
///    English prose with colour codes; `--stat` is a table the model has to read
///    by eye. The machine formats are already there and are never what a human
///    should be reading.
/// 3. **The diff goes through the same colouriser.** The unified diff this
///    returns is parsed by the same code that paints `write`/`edit` diffs, so a
///    change from `git` looks like a change from a tool.
///
/// **The rule that shapes the whole file: no argument reaches git.**
///
/// A `git` tool with a free-form `command` (or `args`, or a `--` passthrough) is
/// `bash` wearing a hat, and strictly worse: it is a new injection surface with a
/// new set of escaping rules, plus a second thing to keep correct. Here the argv
/// is assembled here, with the only variable parts being numbers this file
/// clamps. `git rm -rf` is not reachable, and `bash` is still there for the cases
/// that genuinely need one — `git commit`, `git checkout`, `git stash`, hooks.
///
/// What is NOT here, on purpose: `git_log`'s `path` filter. It would need to be
/// a free-form argument (and `--` handling, and `:(exclude)` magic), and `bash`
/// covers it. Keeping this file at "three things a model asks for constantly"
/// is worth more than making it general.
const std = @import("std");
const common = @import("common.zig");
const bg_tool = @import("bg.zig");
const markdown = @import("../lib/markdown.zig");

/// Upper bound on the diff we are willing to put in a context.
///
/// `max_tool_output` is the same 16 KB every other tool gets, and `git diff` on
/// a real change crosses it easily — a lockfile is 40 000 lines. The output is
/// cut at a line boundary and says how much is missing, because "here is the
/// first 16 KB of a diff" without saying so reads as "this is the diff".
pub var diff_limit: usize = 10 * 1024 * 1024;

/// What we let git produce BEFORE we start cutting.
///
/// Separate from `diff_limit` on purpose, and the reason is history. `runForeground`
/// used to return `error.StreamTooLong` past its limit, and that error escaped to the
/// model as "the result was longer than the cap, narrow the request" — which is
/// `describeError`'s generic text for a `grep`. For a diff it is wrong in a way that
/// matters: the tool's own description promises a truncated diff with a note, and
/// instead of that it
/// arrived as an error with no diff at all. So git gets a bigger pipe and this
/// tool does the cutting, which is the only place that knows what a line of a
/// diff is.
pub var diff_capture: usize = 50 * 1024 * 1024;

/// Read `ZODE_MAX_TOOL_OUTPUT` and install it as both `diff_limit` and
/// `diff_capture` (scaled). Safe to call once at startup.
pub fn initDiffLimit(env: ?*const std.process.Environ.Map) void {
    const raw = if (env) |e| e.get("ZODE_MAX_TOOL_OUTPUT") else null;
    const val = raw orelse return;
    if (val.len == 0) return;

    var digits: usize = 0;
    while (digits < val.len and std.ascii.isDigit(val[digits])) : (digits += 1) {}

    const num_str = val[0..digits];
    const suffix = std.mem.trim(u8, val[digits..], " ");

    const n = std.fmt.parseInt(usize, num_str, 10) catch return;

    var mult: usize = 1;
    if (suffix.len > 0) {
        const s = std.ascii.toLower(suffix[0]);
        if (s == 'k') mult = 1024
        else if (s == 'm') mult = 1024 * 1024
        else if (s == 'g') mult = 1024 * 1024 * 1024
        else return;
    }

    var wanted = n * mult;
    const hard_cap = 200 * 1024 * 1024;
    if (wanted > hard_cap) wanted = hard_cap;
    diff_limit = wanted;
    diff_capture = wanted * 5;
    if (diff_capture > hard_cap) diff_capture = hard_cap;
}

/// The mode of the file the commit message is written to.

/// The mode of the file the commit message is written to.
///
/// 0600: the message is the model's own words about the user's code, and /tmp is
/// readable by everybody on the machine. It is set on the OPEN file, so there is
/// no window in which the file exists at 0644.
const commit_file_mode: std.Io.File.Permissions = @enumFromInt(0o600);

/// The flags every git command in this file gets.
///
/// ## `--no-optional-locks`
///
/// `git status` REFRESHES THE INDEX, and refreshing takes `.git/index.lock`.
/// If another process holds that lock — the user running a `git add` in
/// another terminal, an editor, another agent — git WAITS for it. The tool's
/// timeout is 10 s, so the model got a timeout and spent an iteration on a
/// repository that was perfectly fine. This flag says "do not take the lock",
/// and it is the difference between "the status of this repo" and "the status of
/// this repo while nobody else is typing".
///
/// ## `-c core.quotepath=false`
///
/// With the default (`true`), git ESCAPES the non-ASCII and special characters
/// of a path in octal and quotes it: `?? "caf\303\251.txt"`. The model cannot
/// open that path, so it reads a file and fails, or believes the repository has
/// a file with a strange name in it. With the flag the path comes out as it is
/// on disk.
const git_flags = "--no-optional-locks -c core.quotepath=false";

/// The files whose presence means the repository is in the MIDDLE of something.
///
/// While one of these exists, the tree contains changes that nobody made
/// here: a merge brought in another branch, a rebase rewrote history, a
/// cherry-pick applied a commit. A diff of that tree, presented as "your
/// changes", is a lie the model then acts on — it starts "fixing" code it
/// never touched.
///
/// The files are in the git DIRECTORY, and finding it is one `rev-parse`; the
/// checks themselves are six `stat` calls and no fork.
const transient_marks = [_]struct { file: []const u8, what: []const u8 }{
    .{ .file = "MERGE_HEAD", .what = "a merge" },
    .{ .file = "REBASE_HEAD", .what = "a rebase" },
    .{ .file = "CHERRY_PICK_HEAD", .what = "a cherry-pick" },
    .{ .file = "REVERT_HEAD", .what = "a revert" },
    .{ .file = "rebase-merge", .what = "a rebase" },
    .{ .file = "rebase-apply", .what = "a rebase" },
};

/// What the repository is in the middle of, or null when it is not.
pub fn transientState(io: std.Io, arena: std.mem.Allocator) ?[]const u8 {
    const r = std.process.run(arena, io, .{
        .argv = &.{ "git", "rev-parse", "--git-dir" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(2048),
        .reserve_amount = 1024,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    }) catch return null;
    const code: u8 = switch (r.term) {
        .exited => |c| c,
        else => return null,
    };
    if (code != 0) return null;
    const dir = std.mem.trim(u8, r.stdout, " \t\r\n");
    if (dir.len == 0) return null;
    return transientStateIn(io, arena, dir);
}

/// The same question, about a git directory this caller already has.
///
/// Split from `transientState` so it can be asked about a fixture: the six
/// checks are `stat` calls, and the only thing that needs a repository is
/// finding the directory in the first place.
pub fn transientStateIn(io: std.Io, arena: std.mem.Allocator, dir: []const u8) ?[]const u8 {
    for (transient_marks) |m| {
        const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, m.file }) catch return null;
        _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch continue;
        return m.what;
    }
    return null;
}

/// The note that says the changes below are not necessarily the agent's.
fn transientNote(arena: std.mem.Allocator, what: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, "note: {s} is in progress in this repository, so the changes below include what it brought in and not only what was edited here.\n", .{what}) catch
        "note: an operation is in progress, so these changes may not be the ones made here.\n";
}

/// The names that are almost never meant to be committed.
///
/// It is not a safety feature — the commit still happens if the user says so.
/// It is a sentence, at the moment the model staged the file, naming the file
/// that should not be there. A model that stages a whole tree (`git_add` with
/// no paths) does it without reading the list, and `.env` goes in.
fn looksSecret(name: []const u8) bool {
    const base = std.fs.path.basename(name);
    const secrets = [_][]const u8{
        ".env",
        ".env.local",
        ".env.production",
        "credentials",
        "credentials.json",
        "secrets.json",
        "secrets.yaml",
        "secrets.yml",
        "id_rsa",
        "id_ed25519",
        ".npmrc",
        ".pypirc",
        ".netrc",
        ".htpasswd",
    };
    for (secrets) |s| {
        if (std.mem.eql(u8, base, s)) return true;
    }
    // Extensions: a private key or a certificate.
    for ([_][]const u8{ ".pem", ".key", ".p12", ".pfx", ".jks", ".keystore" }) |ext| {
        if (std.mem.endsWith(u8, base, ext)) return true;
    }
    // A name that STARTS with .env and continues: .env.production.local
    if (std.mem.startsWith(u8, base, ".env.")) return true;
    return false;
}


/// Cuts at a line boundary and says how much is not there.
///
/// A diff cut mid-hunk is worse than no diff: the model reads a `+` line with
/// no context and edits the wrong thing. And cutting without saying so reads as
/// "that is the whole change", which is the failure the note exists to prevent.
fn appendTruncated(arena: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8, total: usize) !void {
    var cut: usize = diff_limit;
    if (cut > text.len) cut = text.len;
    // Never end on a line that is only half a diff line.
    if (std.mem.lastIndexOfScalar(u8, text[0..cut], '\n')) |nl| cut = nl + 1;
    try out.appendSlice(arena, text[0..cut]);
    try out.print(arena, "\n(cut here: the diff is {d} KB and the budget is {d} KB. {d} KB is not shown. Use `bash` with `git diff -- <path>` for one file at a time.)", .{ total / 1024, diff_limit / 1024, (total - cut) / 1024 });
}

/// `git status --porcelain=v1 -b`: one line per change, machine format, plus the
/// branch and upstream in the header.
///
/// `--porcelain=v1` is chosen over `--porcelain=v2` on purpose: v2 is the better
/// format for a tool and v1 is what the model has seen in training far more
/// often, and it fits in a context where the model is going to be reading it
/// rather than a program parsing it.
pub fn toolGitStatus(io: std.Io, arena: std.mem.Allocator) ![]const u8 {
    const r = try bg_tool.runForeground(arena, io, "git " ++ git_flags ++ " status --porcelain=v1 -b", 10, diff_limit);
    // git did not answer: saying "the tree is clean" here would be a lie.
    if (gitFailed(arena, r, "status")) |msg| return msg;

    if (r.stdout.len == 0) {
        return "working tree clean: nothing staged, nothing modified, no untracked files.";
    }

    var out: std.ArrayList(u8) = .empty;
    if (transientState(io, arena)) |what| try out.appendSlice(arena, transientNote(arena, what));
    try out.appendSlice(arena, "git status (XY = staged/worktree, ?? = untracked):\n");
    try out.appendSlice(arena, r.stdout);
    if (r.stdout.len > 0 and r.stdout[r.stdout.len - 1] != '\n') try out.append(arena, '\n');
    // A working tree with thousands of entries does not fit, and a status that stops
    // mid-list is worse than no status: the model reads it as the whole picture and
    // concludes it knows every file that changed.
    if (r.truncated) try out.appendSlice(arena, bg_tool.foreground_truncation_notice);

    // `git status` says nothing about SIZE, and "3 files changed" versus "300
    // files changed" is the difference between a review and a `git reset`. It is
    // one more subprocess and it is what tells the model whether it is looking at
    // its own change or at someone else's.
    const s = try bg_tool.runForeground(arena, io, "git " ++ git_flags ++ " diff --shortstat", 10, 4096);
    if (s.term != null and s.term.?.exited == 0 and s.stdout.len > 0) {
        try out.appendSlice(arena, "\nunstaged: ");
        try out.appendSlice(arena, std.mem.trim(u8, s.stdout, " \t\r\n"));
    }
    const st = try bg_tool.runForeground(arena, io, "git " ++ git_flags ++ " diff --cached --shortstat", 10, 4096);
    if (st.term != null and st.term.?.exited == 0 and st.stdout.len > 0) {
        try out.appendSlice(arena, "staged: ");
        try out.appendSlice(arena, std.mem.trim(u8, st.stdout, " \t\r\n"));
    }
    return out.items;
}

/// How many lines a diff added and removed.
pub const DiffCounts = struct { plus: usize = 0, minus: usize = 0 };

/// Counts the insertions and deletions of a unified diff.
///
/// ## Why this is a function
///
/// Because the number is what the model acts on, and it was wrong. The counting
/// ran BEFORE the `---`/`+++` headers were skipped, so every file touched
/// reported one insertion and one deletion that were not there — a file with 22
/// lines added was reported as `+23 −1` — and a brand new file (`--- /dev/null`)
/// was reported as a deletion.
///
/// The headers are skipped here too, and in the same order, so the count and
/// the printed diff agree.
pub fn countDiffChanges(text: []const u8) DiffCounts {
    var c: DiffCounts = .{};
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "diff --git ")) continue;
        if (std.mem.startsWith(u8, line, "index ")) continue;
        if (std.mem.startsWith(u8, line, "new file mode")) continue;
        if (std.mem.startsWith(u8, line, "deleted file mode")) continue;
        if (std.mem.startsWith(u8, line, "similarity index")) continue;
        if (std.mem.startsWith(u8, line, "rename from")) continue;
        if (std.mem.startsWith(u8, line, "rename to")) continue;
        if (std.mem.startsWith(u8, line, "--- ")) continue;
        if (std.mem.startsWith(u8, line, "+++ ")) continue;
        if (line.len > 0 and (line[0] == '+' or line[0] == '-')) {
            if (line[0] == '+') c.plus += 1 else c.minus += 1;
        }
    }
    return c;
}

/// `git diff`, with the file headers kept separate from the hunks.
///
/// The header is rewritten to `path · +N −M` instead of `diff --git a/x b/x`,
/// because the count is the thing the model acts on and in `diff` form it has to
/// count the `+` lines itself.
pub fn toolGitDiff(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    // `--` with an empty pathspec means "everything", and it is what stops a
    // path that starts with `-` from being read as an option.
    const cmd = if (common.getBool(obj, "staged"))
        "git " ++ git_flags ++ " diff --no-color -U3 --cached"
    else
        "git " ++ git_flags ++ " diff --no-color -U3";

    // `runForeground` no longer fails past its cap: it truncates and sets
    // `truncated`. This tool's own cut is at `diff_limit`, which is the SMALLER of
    // the two, so the `r.stdout.len > diff_limit` branch below handles both — and the
    // arm for `error.StreamTooLong` that used to be here is now unreachable, which is
    // how a message stops being true without anybody noticing.
    const r = try bg_tool.runForeground(arena, io, cmd, 20, diff_capture);
    if (gitFailed(arena, r, "diff")) |msg| return msg;
    if (r.stdout.len == 0) {
        return if (common.getBool(obj, "staged"))
            "no staged changes: the index matches HEAD."
        else
            "no unstaged changes: the working tree matches the index.";
    }

    var out: std.ArrayList(u8) = .empty;
    if (transientState(io, arena)) |what| try out.appendSlice(arena, transientNote(arena, what));
    try out.appendSlice(arena, "diff");
    if (common.getBool(obj, "staged")) try out.appendSlice(arena, " (staged)");
    try out.appendSlice(arena, ":\n");

    // The counts come from the WHOLE diff, not from the part that is printed.
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, r.stdout, '\n');
    while (it.next()) |line| lines.append(arena, line) catch break;

    for (lines.items) |line| {
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            try out.appendSlice(arena, "\n");
            try out.appendSlice(arena, describeFileHeader(arena, line));
            try out.append(arena, '\n');
            continue;
        }
        // `index`, `new file mode`, `similarity index` and `---`/`+++` are all
        // either redundant or noise: the header above already says the path, and
        // `---`/`+++` are a second copy of it with a/ and b/ prefixes.
        if (std.mem.startsWith(u8, line, "index ")) continue;
        if (std.mem.startsWith(u8, line, "new file mode")) continue;
        if (std.mem.startsWith(u8, line, "deleted file mode")) continue;
        if (std.mem.startsWith(u8, line, "similarity index")) continue;
        if (std.mem.startsWith(u8, line, "rename from") or
            std.mem.startsWith(u8, line, "rename to")) continue;
        if (std.mem.startsWith(u8, line, "--- ")) continue;
        if (std.mem.startsWith(u8, line, "+++ ")) continue;
        try out.appendSlice(arena, line);
        try out.append(arena, '\n');
    }

    const counts = countDiffChanges(r.stdout);
    if (r.stdout.len > diff_limit) {
        // Rebuild from the truncated source: the loop above already copied
        // everything, so the clean thing is to redo it on the cut text and let
        // the helper own the note.
        var cut: std.ArrayList(u8) = .empty;
        try appendTruncated(arena, &cut, r.stdout, r.stdout.len);
        // The summary still comes from the WHOLE diff. The counts are the one
        // thing that tells the model how big the change is, and they are
        // exactly what the cut throws away: a truncated diff that loses its
        // summary reads as a small change.
        try cut.print(arena, "\n{d} file(s) changed, +{d} −{d}", .{ countFiles(r.stdout), counts.plus, counts.minus });
        return cut.items;
    }
    try out.print(arena, "\n{d} file(s) changed, +{d} −{d}", .{ countFiles(r.stdout), counts.plus, counts.minus });
    return out.items;
}

/// `path · +N −M` out of a `diff --git a/x b/x` line.
pub fn describeFileHeader(arena: std.mem.Allocator, line: []const u8) []const u8 {
    const rest = line["diff --git ".len..];
    // Split on " b/" — the first path is a/..., the second is b/... and a path
    // containing " b/" is possible but far less likely than the split being
    // wrong on a weird one, and git quotes paths with spaces in the header.
    var path = rest;
    if (std.mem.indexOf(u8, rest, " b/")) |i| path = rest[0..i];
    if (std.mem.startsWith(u8, path, "a/")) path = path[2..];
    return std.fmt.allocPrint(arena, "{s}", .{path}) catch line;
}

pub fn countFiles(stdout: []const u8) usize {
    var n: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, stdout, pos, "diff --git ")) |i| {
        n += 1;
        pos = i + 1;
    }
    return n;
}

/// How many commits `git_log` should ask for.
///
/// A pure function for one reason: the clamp is the whole safety argument of
/// this file and it was untestable while it was two lines inline in `toolGitLog`,
/// where the only way to exercise it was to spawn git. A tool whose only defence
/// is "the number is clamped, trust me" needs that clamp to be a value you can
/// ask about.
pub fn logLimit(obj: std.json.ObjectMap) usize {
    var n: usize = 20;
    if (common.getInt(obj, "limit")) |l| {
        if (l > 0) n = @min(@as(usize, @intCast(l)), 200);
    }
    return n;
}

/// `git log --oneline`, most recent first.
pub fn toolGitLog(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const n = logLimit(obj);
    var cmd_buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&cmd_buf);
    // `-n` is clamped above and formatted here, so there is no injection surface:
    // the number cannot come out as anything but digits.
    w.print("git " ++ git_flags ++ " log --no-color --oneline -n {d}", .{n}) catch return "error: could not build the command";
    const r = try bg_tool.runForeground(arena, io, w.buffered(), 15, diff_limit);
    if (gitFailed(arena, r, "log")) |msg| return msg;
    if (r.stdout.len == 0) return "no commits yet: this repository has no history.";
    // A history longer than the cap is NORMAL and there is more of it, so the cut
    // has to say so. Without the notice `git_log` on a busy repository looks like a
    // complete answer and the model concludes the repository has 16 KB of history.
    if (!r.truncated) return r.stdout;
    return std.fmt.allocPrint(arena, "{s}{s}", .{ r.stdout, bg_tool.foreground_truncation_notice }) catch r.stdout;
}

fn isNotARepo(r: bg_tool.Foreground) bool {
    // We stopped it at the cap: no verdict, and in particular not the 128 that would
    // say "not a repository". The caller's own `truncated` branch says what happened.
    const t = r.term orelse return false;
    if (t.exited == 0) return false;
    return std.mem.indexOf(u8, r.stderr, "not a git repository") != null;
}

/// What git said when it did NOT answer, or answered with a failure.
///
/// ## Why this function exists
///
/// It exists because of a specific lie. `git status --porcelain=v1 -b` in a
/// repository ALWAYS prints the `## branch` header, so an EMPTY stdout means git
/// did not answer at all: it is not installed, the directory is not a repository,
/// or git refused ("dubious ownership" on a repo owned by another user, a
/// corrupted repo, a lock it could not take). The old code read "empty stdout"
/// as "the tree is clean" and told the model the working tree was clean when
/// nothing had been checked.
///
/// The same shape applies to the other two: `git diff` with empty output means
/// "no changes" and `git log` with empty output means "no history" — but only
/// when git EXITED ZERO. A failure and an empty result look identical from
/// outside, and only one of them is a fact about the tree.
///
/// The rule this encodes: **the tool says UNKNOWN when it does not know.** A
/// turn that plans on "the tree is clean" and finds out it was never checked
/// costs an iteration; a turn that plans on UNKNOWN asks again.
///
/// Returns null when git succeeded.
fn gitFailed(arena: std.mem.Allocator, r: bg_tool.Foreground, what: []const u8) ?[]const u8 {
    const t = r.term orelse return null; // stopped at the cap: no verdict at all
    if (t.exited == 0) return null;
    if (std.mem.indexOf(u8, r.stderr, "not a git repository") != null) return notARepo();
    // An empty repository is not a failure: `git log` exits 128 with this exact
    // sentence, and the honest answer is "there is no history", not "git failed".
    if (std.mem.indexOf(u8, r.stderr, "does not have any commits yet") != null) {
        return "no commits yet: this repository has no history.";
    }
    if (std.mem.indexOf(u8, r.stderr, "command not found") != null or
        std.mem.indexOf(u8, r.stderr, "git: not found") != null)
    {
        return "git is not installed, or it is not on the PATH of the shell this tool runs. Nothing was checked: the state of the tree is UNKNOWN.";
    }
    const e = std.mem.trim(u8, r.stderr, " \t\r\n");
    if (e.len == 0) {
        return std.fmt.allocPrint(arena, "git {s} failed with exit code {d} and said nothing of its own. The state of the tree is UNKNOWN: it was NOT checked.", .{ what, t.exited }) catch
            "git failed; the state of the tree is UNKNOWN.";
    }
    return std.fmt.allocPrint(arena, "git {s} failed (exit {d}): {s}\nThe state of the tree is UNKNOWN: it was NOT checked.", .{ what, t.exited, e[0..@min(e.len, 600)] }) catch
        "git failed; the state of the tree is UNKNOWN.";
}

fn notARepo() []const u8 {
    return "this directory is not a git repository. Nothing was run. If the project is not under git, `git_status`/`git_diff`/`git_log` do not apply to it and `bash` is the way to ask about files.";
}

// ── the writing half ─────────────────────────────────────────────────────────────
//
// Why it is here at all: `git_status`, `git_diff` and `git_log` only READ, so anything
// that changes the repository went through `bash` — two permission dialogs and a shell
// string for "make a branch and commit this", and on a tree with unrelated work in it
// the model could not isolate its own change at all.
//
// ## Why every argv is a FIXED list and never a format string
//
// A branch name, a commit message and a path all come from the model, and all three end
// up in a command line. With `allocPrint("{s}", .{name})` a name of
// `--upload-pack=touch /tmp/x` is an ARGUMENT to `git checkout` and not a branch. With
// a fixed argv and no shell, it is simply a branch name git will refuse, which is the
// failure mode you want.
//
// That is the same rule `check` follows, and the reason it is written down here: this
// is the file where a shortcut would be most tempting.

/// The argv for `git_branch`: the words AFTER `git`, which `runGit` prepends
/// with the flags every git command here gets.
///
/// It is returned BY VALUE, and that is not a style choice: the first version
/// returned `&.{ "git", "switch", name }`, and with a runtime `name` that is a
/// pointer to a temporary that dies when the function returns. The test that
/// read it segfaulted at address 0x3.
pub const BranchArgv = struct {
    words: [4][]const u8 = .{ "", "", "", "" },
    len: usize = 0,

    pub fn slice(self: *const BranchArgv) []const []const u8 {
        return self.words[0..self.len];
    }
};

/// The argv for `git_branch`, as a pure function.
///
/// ## Why this is a function and not four lines inline
///
/// The bug it fixes was a SHAPE bug. The old code built a fixed four-word
/// argv and padded the `switch` case with an EMPTY argument, so it ran
/// `git switch '' <name>`, which git refuses: switching to an existing branch
/// NEVER worked, and the model was shown git's stderr.
///
/// The shape is the argument. `checkout -b NAME` is three words plus the
/// name; `switch NAME` is one plus the name; and there is no way to pad one
/// into the other without inventing an argument git has to reject.
///
/// Returns null for an action that is neither.
pub fn branchArgv(action: []const u8, name: []const u8) ?BranchArgv {
    if (std.mem.eql(u8, action, "create")) {
        return .{ .words = .{ "checkout", "-b", name, "" }, .len = 3 };
    }
    if (std.mem.eql(u8, action, "switch")) {
        return .{ .words = .{ "switch", name, "", "" }, .len = 2 };
    }
    return null;
}

/// Branches: list, create, switch. `name` is validated, never interpolated into a
/// shell.
pub fn toolGitBranch(
    io: std.Io,
    arena: std.mem.Allocator,
    action: []const u8,
    name: []const u8,
) ![]const u8 {
    if (std.mem.eql(u8, action, "list")) {
        const r = try bg_tool.runForeground(arena, io, "git " ++ git_flags ++ " branch --format='%(refname:short)'", 10, diff_limit);
        if (gitFailed(arena, r, "branch")) |msg| return msg;
        return if (r.stdout.len == 0) "no branches beyond the default yet." else r.stdout;
    }

    const argv = branchArgv(action, name) orelse
        return "git_branch needs `action`: list | create | switch";

    if (!validRefName(name)) {
        return std.fmt.allocPrint(
            arena,
            "`{s}` is not a usable branch name. A branch name cannot start with a dash, and it cannot contain a space, a colon, a `~`, a `^`, a `?`, a `*`, a `[`, a backslash or any of the control characters. Pick another name.",
            .{name},
        );
    }

    const r = runGit(arena, io, argv.slice()) catch |err| return err;
    if (!ok(r)) return explain(arena, r, name);
    const verb: []const u8 = if (std.mem.eql(u8, action, "create")) "created and switched to" else "switched to";
    return std.fmt.allocPrint(arena, "{s} `{s}`", .{ verb, name });
}

/// A branch name that git will accept, checked here so the model gets a sentence
/// instead of git's.
///
/// The dash rule is not cosmetic: it is the one that keeps a name from being read as an
/// OPTION by git itself, which is the only injection surface in this file.
pub fn validRefName(name: []const u8) bool {
    if (name.len == 0 or name.len > 200) return false;
    if (name[0] == '-' or name[0] == '/') return false;
    if (std.mem.endsWith(u8, name, ".lock")) return false;
    for (name) |c| {
        if (c < 0x20 or c == 0x7f) return false;
        switch (c) {
            ' ', ':', '~', '^', '?', '*', '[', '\\', '@' => return false,
            else => {},
        }
    }
    return true;
}

/// Stage everything, or the paths given, and say what is now staged.
pub fn toolGitAdd(io: std.Io, arena: std.mem.Allocator, paths: []const []const u8) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, "add");
    const everything = paths.len == 0;
    if (everything) {
        try argv.append(arena, "-A");
    } else {
        for (paths) |p| {
            if (std.mem.eql(u8, p, "-A") or p.len > 0 and p[0] == '-') {
                return "a path cannot start with a dash: it would be read as an option to git. Use `./name` if the file starts with one.";
            }
            // `--` before the paths: a path that starts with `-` is already
            // refused above, and `--` also stops git from reading a path that
            // begins with `:` as its own pathspec MAGIC (`:(glob)`, `:/`).
            try argv.append(arena, p);
        }
        try argv.append(arena, "--");
    }
    const r = runGit(arena, io, argv.items) catch |err| return err;
    if (!ok(r)) return explain(arena, r, "add");

    const st = try bg_tool.runForeground(arena, io, "git " ++ git_flags ++ " diff --cached --shortstat", 10, 4096);
    const tail = if (st.stdout.len > 0) std.mem.trim(u8, st.stdout, " \t\r\n") else "";

    // The list of what is staged, and a word about the ones that should not be.
    const names = try bg_tool.runForeground(arena, io, "git " ++ git_flags ++ " diff --cached --name-only", 10, 16 * 1024);
    var secret: ?[]const u8 = null;
    if (names.term != null and names.term.?.exited == 0) {
        var it = std.mem.splitScalar(u8, names.stdout, '\n');
        while (it.next()) |n| {
            const t = std.mem.trim(u8, n, " \t\r\n");
            if (t.len == 0) continue;
            if (looksSecret(t)) {
                secret = t;
                break;
            }
        }
    }

    var out: std.ArrayList(u8) = .empty;
    if (everything) {
        // Staging everything is staging the user's OTHER work too, and the
        // model does not read the list. Saying so is the difference between a
        // tool and a guess.
        try out.appendSlice(arena, "staged EVERYTHING that changed in the tree — every modified, added and deleted file, including work that is not yours.\n");
    } else {
        try out.appendSlice(arena, "staged");
    }
    if (tail.len > 0) {
        try out.appendSlice(arena, ": ");
        try out.appendSlice(arena, tail);
        try out.append(arena, '\n');
    } else {
        try out.appendSlice(arena, "nothing: there were no changes to stage.\n");
    }
    if (secret) |s| {
        try out.print(arena, "WARNING: `{s}` is staged. That name usually means a secret (a key, a token, a password file). Unstage it with `git restore --staged {s}` before committing.\n", .{ s, s });
    }
    return out.items;
}

/// Commit what is staged. The message goes in a FILE, not on the command line.
///
/// `git commit -m "<model's text>"` would be an argv entry and could contain anything;
/// writing it to a temp file and passing `-F` keeps it out of the argv entirely, and it
/// is the shape git's own documentation recommends for anything long.
pub fn toolGitCommit(
    io: std.Io,
    arena: std.mem.Allocator,
    message: []const u8,
) ![]const u8 {
    const msg = std.mem.trim(u8, message, " \t\r\n");
    if (msg.len == 0) return "a commit needs a message. One line of what changed and why is enough.";
    if (msg.len > 4096) return "the commit message is over 4096 characters; the first paragraph is what git shows.";

    // The message goes to a FILE that only this user can read.
    //
    // Three things about it, and each one was a bug:
    //
    // 1. The old path was `/tmp/opencode/…`, a directory nobody creates: on a
    //    normal machine `git_commit` failed with "could not write the commit
    //    message to a temporary file" and the model never got a commit.
    // 2. `createFile` with `exclusive` fails if the path already exists, which
    //    is what stops a pre-created symlink in /tmp from turning "write the
    //    commit message" into "write a file somewhere else".
    // 3. The mode is set on the OPEN file, so there is no window in which the
    //    model's own words exist at 0644 — which a `create` + `chmod` would have.
    var path_buf: [256]u8 = undefined;
    const path = writeCommitMessage(io, &path_buf, msg) catch |err| {
        return std.fmt.allocPrint(arena, "could not write the commit message to a temporary file ({t})", .{err}) catch
            "could not write the commit message to a temporary file";
    };
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var argv: [3][]const u8 = .{ "commit", "-F", path };
    const r = runGit(arena, io, &argv) catch |err| return err;
    if (!ok(r)) {
        if (std.mem.indexOf(u8, r.stderr, "nothing to commit") != null) {
            return "nothing to commit: the tree has no staged changes. `git_add` first, or edit something.";
        }
        return explain(arena, r, "commit");
    }
    const head = r.stdout;
    const line = std.mem.indexOfScalar(u8, head, '\n') orelse head.len;
    return std.fmt.allocPrint(arena, "committed: {s}", .{std.mem.trim(u8, head[0..line], " \t\r\n")});
}

/// Writes the commit message to a file only this user can read, and returns its
/// path.
///
/// The path is a slice of `path_buf`, so the CALLER owns the buffer: a slice
/// into a local of this function would be dead by the time the caller used it,
/// which is the oldest bug in this repo's book.
///
/// `/tmp` and not a directory of ours: the old path was `/tmp/opencode/…`, and
/// that directory is created by the HARNESS, not by zode. On a user's machine
/// it does not exist, `git_commit` failed with "could not write the commit
/// message to a temporary file", and the model never got a commit.
pub fn writeCommitMessage(io: std.Io, path_buf: []u8, msg: []const u8) ![]const u8 {
    const path = try std.fmt.bufPrint(path_buf, "/tmp/zode-commit-{d}.txt", .{std.Io.Timestamp.now(io, .real).toNanoseconds()});
    var f = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .exclusive = true });
    defer f.close(io);
    f.setPermissions(io, commit_file_mode) catch {};
    try f.writeStreamingAll(io, msg);
    return path;
}

/// The argv for `git_stash`, as a pure function.
///
/// `push` carries `--include-untracked` and it is the reason this is a
/// function: without it, `git stash push` leaves the files that were never
/// tracked IN THE TREE, and the message "the changes are stashed" was a lie
/// about them. They never left, and a later `pop` did not bring them back.
pub fn stashArgv(action: []const u8) []const []const u8 {
    if (std.mem.eql(u8, action, "pop")) return &.{ "stash", "pop" };
    if (std.mem.eql(u8, action, "list")) return &.{ "stash", "list" };
    return &.{ "stash", "push", "--include-untracked" };
}

/// Put the current changes aside and get them back with `git stash pop`.
pub fn toolGitStash(io: std.Io, arena: std.mem.Allocator, action: []const u8) ![]const u8 {
    const argv = stashArgv(action);
    const verb: []const u8 = argv[1];
    const r = runGit(arena, io, argv) catch |err| return err;
    if (!ok(r)) return explain(arena, r, verb);
    return switch (verb[0]) {
        'p' => "stash pop: the changes are back in the tree.",
        'l' => if (r.stdout.len == 0) "no stashes." else r.stdout,
        else => "changes stashed, including the files that were not tracked. `git_stash pop` brings them back.",
    };
}

/// Runs git with a FIXED argv, plus the flags every git command here gets.
///
/// The argv is a list of WORDS and the model's text is a value in a known
/// position of it, never a fragment of a command line. The flags are part of
/// the same list for the same reason: `--no-optional-locks` and
/// `core.quotepath=false` are not options of the model, they are properties of
/// every call this file makes.
fn runGit(arena: std.mem.Allocator, io: std.Io, args: []const []const u8) !bg_tool.Foreground {
    // `runForeground` only takes a shell string, so the argv is joined with a quoting
    // that cannot be escaped: each argument is single-quoted and any `'` inside is
    // closed, escaped and reopened. It is the one place in this file where a model's
    // text becomes part of a command, and it is quoted rather than trusted.
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, "git");
    try argv.append(arena, "--no-optional-locks");
    try argv.append(arena, "-c");
    try argv.append(arena, "core.quotepath=false");
    for (args) |a| try argv.append(arena, a);

    var text = std.Io.Writer.Allocating.init(arena);
    const w = &text.writer;
    for (argv.items, 0..) |a, i| {
        if (i > 0) w.writeAll(" ") catch {};
        w.writeByte('\'') catch {};
        for (a) |c| {
            // Close the quote, emit an escaped quote, reopen. The only sequence that
            // cannot be broken from inside single quotes.
            if (c == '\'') w.writeAll("'\\''") catch {} else w.writeByte(c) catch {};
        }
        w.writeByte('\'') catch {};
    }
    return bg_tool.runForeground(arena, io, text.written(), 20, diff_limit);
}

fn ok(r: bg_tool.Foreground) bool {
    const t = r.term orelse return false;
    return t.exited == 0;
}

/// git's stderr, trimmed, with the two cases that are about the MODEL and not the repo.
fn explain(arena: std.mem.Allocator, r: bg_tool.Foreground, what: []const u8) []const u8 {
    if (std.mem.indexOf(u8, r.stderr, "not a git repository") != null) {
        return "this directory is not a git repository, so that was not run. If the project is not under git, `bash` is the way to ask about files.";
    }
    if (std.mem.indexOf(u8, r.stderr, "Please tell me who you are") != null) {
        return "git has no author configured, and it refuses to commit without one. Run `git config user.email` and `git config user.name` yourself — it is a decision about who is committing, not something to guess.";
    }
    if (std.mem.indexOf(u8, r.stderr, "would be overwritten") != null) {
        return "git refused because unstaged changes in the tree would be lost by that switch. `git_stash` first, then switch, then `git_stash pop`.";
    }
    const e = std.mem.trim(u8, r.stderr, " \t\r\n");
    if (e.len == 0) {
        return std.fmt.allocPrint(arena, "git {s} failed with no message of its own", .{what}) catch "git failed";
    }
    return std.fmt.allocPrint(arena, "git {s} said: {s}", .{ what, e[0..@min(e.len, 600)] }) catch "git failed";
}

// ── tests ──────────────────────────────────────────────────────────────────────
//
// This file had NO tests at all, which is why four bugs in it survived: the
// argv that could not switch a branch, the "the tree is clean" answer to a
// git that had failed, the diff counts that were inflated by two per file, and
// the commit message written to a directory nobody creates.
//
// The tools themselves run `git` in the CURRENT directory, so they cannot be
// exercised in a fixture repository without moving the process. What CAN be
// exercised is the part that decides: the argv, the counting, the failure
// verdict and the file that is written. Those are the parts that were wrong.


test "git: a failing git is NOT a clean tree" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // What git says when it refuses to touch a repository owned by somebody
    // else. The old code read the empty stdout as "nothing changed".
    const r: bg_tool.Foreground = .{
        .stdout = @constCast(""),
        .stderr = @constCast("fatal: detected dubious ownership in repository at '/tmp/x'"),
        .term = .{ .exited = 128 },
    };
    const msg = gitFailed(arena, r, "status");
    try std.testing.expect(msg != null);
    try std.testing.expect(std.mem.indexOf(u8, msg.?, "UNKNOWN") != null);
    // The words that used to be there, and that are a lie in this case.
    try std.testing.expect(std.mem.indexOf(u8, msg.?, "clean") == null);
}

test "git: a git that succeeded is not a failure" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const r: bg_tool.Foreground = .{
        .stdout = @constCast("## main\n M a.txt\n"),
        .stderr = @constCast(""),
        .term = .{ .exited = 0 },
    };
    try std.testing.expect(gitFailed(arena, r, "status") == null);
}

test "git: a repository with no commits is not a failure" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `git log` exits 128 in an empty repository and says this.
    const r: bg_tool.Foreground = .{
        .stdout = @constCast(""),
        .stderr = @constCast("fatal: your current branch 'main' does not have any commits yet"),
        .term = .{ .exited = 128 },
    };
    const msg = gitFailed(arena, r, "log");
    try std.testing.expect(msg != null);
    try std.testing.expect(std.mem.indexOf(u8, msg.?, "no commits yet") != null);
}

test "git: git not installed is named as that" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const r: bg_tool.Foreground = .{
        .stdout = @constCast(""),
        .stderr = @constCast("sh: 1: git: not found"),
        .term = .{ .exited = 127 },
    };
    const msg = gitFailed(arena, r, "status");
    try std.testing.expect(msg != null);
    try std.testing.expect(std.mem.indexOf(u8, msg.?, "not installed") != null);
}

test "git_branch: switch and create are DIFFERENT shapes" {
    // The bug: a fixed four-word argv padded the switch case with an empty
    // argument, so it ran `git switch '' <name>`, which git refuses.
    const sw = branchArgv("switch", "feature").?;
    try std.testing.expectEqual(@as(usize, 2), sw.len);
    try std.testing.expectEqualStrings("switch", sw.words[0]);
    try std.testing.expectEqualStrings("feature", sw.words[1]);

    const cr = branchArgv("create", "feature").?;
    try std.testing.expectEqual(@as(usize, 3), cr.len);
    try std.testing.expectEqualStrings("checkout", cr.words[0]);
    try std.testing.expectEqualStrings("-b", cr.words[1]);
    try std.testing.expectEqualStrings("feature", cr.words[2]);

    // And no empty argument anywhere: that was the thing git rejected.
    for (sw.slice()) |a| try std.testing.expect(a.len > 0);
    for (cr.slice()) |a| try std.testing.expect(a.len > 0);

    try std.testing.expect(branchArgv("delete", "x") == null);
}

test "git diff: the counts do not count the headers" {
    // A file with three added lines and one removed line. The `---` and `+++`
    // headers start with `-` and `+`, so counting before skipping them
    // reported +4 −2 for a change that was +3 −1.
    const diff =
        "diff --git a/x.txt b/x.txt\n" ++
        "index 111..222 100644\n" ++
        "--- a/x.txt\n" ++
        "+++ b/x.txt\n" ++
        "@@ -1,3 +1,5 @@\n" ++
        " keep\n" ++
        "-old\n" ++
        "+new one\n" ++
        "+new two\n" ++
        "+new three\n";
    const c = countDiffChanges(diff);
    try std.testing.expectEqual(@as(usize, 3), c.plus);
    try std.testing.expectEqual(@as(usize, 1), c.minus);
}

test "git diff: a new file is not a deletion" {
    // `--- /dev/null` is how git writes the old side of a new file.
    const diff =
        "diff --git a/new.txt b/new.txt\n" ++
        "new file mode 100644\n" ++
        "--- /dev/null\n" ++
        "+++ b/new.txt\n" ++
        "@@ -0,0 +1,2 @@\n" ++
        "+one\n" ++
        "+two\n";
    const c = countDiffChanges(diff);
    try std.testing.expectEqual(@as(usize, 2), c.plus);
    try std.testing.expectEqual(@as(usize, 0), c.minus);
}

test "the commit message is written where git can read it, and only we can" {
    // The old path was `/tmp/opencode/…`: a directory the HARNESS creates, not
    // zode. On a user's machine it does not exist, and the commit failed with
    // "could not write the commit message to a temporary file".
    var buf: [256]u8 = undefined;
    const path = try writeCommitMessage(std.testing.io, &buf, "a commit message");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("a commit message", data);

    // 0600: the message is the model's own words about the user's code, and
    // /tmp is readable by everybody on the machine.
    const st = try std.Io.Dir.cwd().statFile(std.testing.io, path, .{});
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(@intFromEnum(st.permissions) & 0o777)));
}

test "git: a merge in progress is named" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = "/tmp/opencode/git-transient-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);

    // Nothing in progress: the answer is null, and that is the common case.
    try std.testing.expect(transientStateIn(std.testing.io, arena, dir) == null);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = dir ++ "/MERGE_HEAD", .data = "abc123\n" });
    const what = transientStateIn(std.testing.io, arena, dir);
    try std.testing.expect(what != null);
    try std.testing.expect(std.mem.indexOf(u8, what.?, "merge") != null);
}

test "git stash: push takes the untracked files with it" {
    const push = stashArgv("push");
    try std.testing.expectEqual(@as(usize, 3), push.len);
    try std.testing.expectEqualStrings("--include-untracked", push[2]);

    const pop = stashArgv("pop");
    try std.testing.expectEqual(@as(usize, 2), pop.len);
    try std.testing.expectEqualStrings("pop", pop[1]);
}

test "git: the names that are usually a secret are named" {
    try std.testing.expect(looksSecret(".env"));
    try std.testing.expect(looksSecret("config/.env.production"));
    try std.testing.expect(looksSecret("id_rsa"));
    try std.testing.expect(looksSecret("deploy.pem"));
    try std.testing.expect(looksSecret("credentials.json"));
    try std.testing.expect(!looksSecret("src/main.zig"));
    try std.testing.expect(!looksSecret("environment.zig"));
    try std.testing.expect(!looksSecret(".gitignore"));
}

test "git: the flags make a non-ASCII path usable" {
    // The bug this fixes: with the default `core.quotepath`, git prints
    // `?? "espa\303\241ol.txt"` — a path the model cannot open. The flags
    // every git command in this file now carries turn it into the real name.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = "/tmp/opencode/git-unicode-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    for ([_][]const u8{ "init -q", "config user.email t@t", "config user.name t" }) |cmd| {
        const line = try std.fmt.allocPrint(arena, "git -C {s} {s}", .{ dir, cmd });
        const r = try bg_tool.runForeground(arena, std.testing.io, line, 20, 8192);
        try std.testing.expectEqual(@as(u8, 0), r.term.?.exited);
    }
    const name = "español.txt";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = dir ++ "/" ++ name, .data = "x\n" });

    const with_flags = try bg_tool.runForeground(arena, std.testing.io,
        try std.fmt.allocPrint(arena, "git -C {s} {s} status --porcelain=v1", .{ dir, git_flags }), 20, 8192);
    try std.testing.expectEqual(@as(u8, 0), with_flags.term.?.exited);
    try std.testing.expect(std.mem.indexOf(u8, with_flags.stdout, name) != null);

    // And without them, git escapes it: that is the shape the model used to get.
    const without = try bg_tool.runForeground(arena, std.testing.io,
        try std.fmt.allocPrint(arena, "git -C {s} status --porcelain=v1", .{dir}), 20, 8192);
    try std.testing.expect(std.mem.indexOf(u8, without.stdout, name) == null);
}
