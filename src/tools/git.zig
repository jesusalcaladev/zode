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
pub const diff_limit = 16 * 1024;

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
const diff_capture = 256 * 1024;

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
    const r = try bg_tool.runForeground(arena, io, "git status --porcelain=v1 -b", 10, diff_limit);
    if (isNotARepo(r)) return notARepo();

    if (r.stdout.len == 0) {
        return "working tree clean: nothing staged, nothing modified, no untracked files.";
    }

    var out: std.ArrayList(u8) = .empty;
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
    const s = try bg_tool.runForeground(arena, io, "git diff --shortstat", 10, 4096);
    if (s.term != null and s.term.?.exited == 0 and s.stdout.len > 0) {
        try out.appendSlice(arena, "\nunstaged: ");
        try out.appendSlice(arena, std.mem.trim(u8, s.stdout, " \t\r\n"));
    }
    const st = try bg_tool.runForeground(arena, io, "git diff --cached --shortstat", 10, 4096);
    if (st.term != null and st.term.?.exited == 0 and st.stdout.len > 0) {
        try out.appendSlice(arena, "staged: ");
        try out.appendSlice(arena, std.mem.trim(u8, st.stdout, " \t\r\n"));
    }
    return out.items;
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
        "git diff --no-color -U3 --cached"
    else
        "git diff --no-color -U3";

    // `runForeground` no longer fails past its cap: it truncates and sets
    // `truncated`. This tool's own cut is at `diff_limit`, which is the SMALLER of
    // the two, so the `r.stdout.len > diff_limit` branch below handles both — and the
    // arm for `error.StreamTooLong` that used to be here is now unreachable, which is
    // how a message stops being true without anybody noticing.
    const r = try bg_tool.runForeground(arena, io, cmd, 20, diff_capture);
    if (isNotARepo(r)) return notARepo();
    if (r.stdout.len == 0) {
        return if (common.getBool(obj, "staged"))
            "no staged changes: the index matches HEAD."
        else
            "no unstaged changes: the working tree matches the index.";
    }

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "diff");
    if (common.getBool(obj, "staged")) try out.appendSlice(arena, " (staged)");
    try out.appendSlice(arena, ":\n");

    var plus: usize = 0;
    var minus: usize = 0;
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
        if (line.len > 0 and (line[0] == '+' or line[0] == '-')) {
            if (line[0] == '+') plus += 1 else minus += 1;
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

    const summary = try std.fmt.allocPrint(arena, "\n{d} file(s) changed, +{d} −{d}", .{ countFiles(r.stdout), plus, minus });
    try out.appendSlice(arena, summary);
    if (r.stdout.len > diff_limit) {
        // Rebuild from the truncated source: the loop above already copied
        // everything, so the clean thing is to redo it on the cut text and let
        // the helper own the note.
        var cut: std.ArrayList(u8) = .empty;
        try appendTruncated(arena, &cut, r.stdout, r.stdout.len);
        return cut.items;
    }
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
    w.print("git log --no-color --oneline -n {d}", .{n}) catch return "error: could not build the command";
    const r = try bg_tool.runForeground(arena, io, w.buffered(), 15, diff_limit);
    if (isNotARepo(r)) return notARepo();
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

/// Branches: list, create, switch. `name` is validated, never interpolated into a
/// shell.
pub fn toolGitBranch(
    io: std.Io,
    arena: std.mem.Allocator,
    action: []const u8,
    name: []const u8,
) ![]const u8 {
    if (std.mem.eql(u8, action, "list")) {
        const r = try bg_tool.runForeground(arena, io, "git branch --format='%(refname:short)'", 10, diff_limit);
        return if (r.stdout.len == 0) "no branches beyond the default yet." else r.stdout;
    }

    const want = if (std.mem.eql(u8, action, "create")) "checkout" else if (std.mem.eql(u8, action, "switch")) "switch" else return "git_branch needs `action`: list | create | switch";

    if (!validRefName(name)) {
        return std.fmt.allocPrint(
            arena,
            "`{s}` is not a usable branch name. A branch name cannot start with a dash, and it cannot contain a space, a colon, a `~`, a `^`, a `?`, a `*`, a `[`, a backslash or any of the control characters. Pick another name.",
            .{name},
        );
    }

    var argv: [4][]const u8 = .{ "git", want, "-b", "" };
    const b = switch (want[0]) {
        'c' => "-b", // checkout -b CREATES
        else => "",
    };
    argv[2] = b;
    argv[3] = name;
    const r = runGit(arena, io, &argv) catch |err| return err;
    if (!ok(r)) return explain(arena, r, name);
    const verb: []const u8 = if (b.len > 0) "created and switched to" else "switched to";
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
    try argv.append(arena, "git");
    try argv.append(arena, "add");
    if (paths.len == 0) {
        try argv.append(arena, "-A");
    } else {
        for (paths) |p| {
            if (std.mem.eql(u8, p, "-A") or p.len > 0 and p[0] == '-') {
                return "a path cannot start with a dash: it would be read as an option to git. Use `./name` if the file starts with one.";
            }
            try argv.append(arena, p);
        }
    }
    const r = runGit(arena, io, argv.items) catch |err| return err;
    if (!ok(r)) return explain(arena, r, "add");
    const st = try bg_tool.runForeground(arena, io, "git diff --cached --shortstat", 10, 4096);
    const tail = if (st.stdout.len > 0) std.mem.trim(u8, st.stdout, " \t\r\n") else "";
    return std.fmt.allocPrint(arena, "staged{s}\n", .{
        if (tail.len > 0) std.fmt.allocPrint(arena, ": {s}", .{tail}) catch "" else " everything",
    });
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

    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/tmp/opencode/zode-commit-{d}.txt", .{std.Io.Timestamp.now(io, .real).toNanoseconds()}) catch
        return "could not name a temporary file for the commit message";
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = msg }) catch
        return "could not write the commit message to a temporary file";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var argv: [4][]const u8 = .{ "git", "commit", "-F", path };
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

/// Put the current changes aside and get them back with `git stash pop`.
pub fn toolGitStash(io: std.Io, arena: std.mem.Allocator, action: []const u8) ![]const u8 {
    var argv: [3][]const u8 = undefined;
    const verb: []const u8 = if (std.mem.eql(u8, action, "pop")) "pop" else if (std.mem.eql(u8, action, "list")) "list" else "push";
    argv = .{ "git", "stash", verb };
    const r = runGit(arena, io, &argv) catch |err| return err;
    if (!ok(r)) return explain(arena, r, verb);
    return switch (verb[0]) {
        'p' => "stash pop: the changes are back in the tree.",
        'l' => if (r.stdout.len == 0) "no stashes." else r.stdout,
        else => "changes stashed. `git_stash pop` brings them back.",
    };
}

fn runGit(arena: std.mem.Allocator, io: std.Io, argv: []const []const u8) !bg_tool.Foreground {
    // `runForeground` only takes a shell string, so the argv is joined with a quoting
    // that cannot be escaped: each argument is single-quoted and any `'` inside is
    // closed, escaped and reopened. It is the one place in this file where a model's
    // text becomes part of a command, and it is quoted rather than trusted.
    var text = std.Io.Writer.Allocating.init(arena);
    const w = &text.writer;
    for (argv, 0..) |a, i| {
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
