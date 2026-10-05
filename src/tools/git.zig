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
/// Separate from `diff_limit` on purpose. `runForeground` returns
/// `error.StreamTooLong` when the subprocess writes more than its limit, and
/// that error used to escape to the model as "the result was longer than the
/// cap, narrow the request" — which is `describeError`'s generic text for a
/// `grep`. For a diff it is wrong in a way that matters: the tool's own
/// description promises a truncated diff with a note, and instead of that it
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

    // `git status` says nothing about SIZE, and "3 files changed" versus "300
    // files changed" is the difference between a review and a `git reset`. It is
    // one more subprocess and it is what tells the model whether it is looking at
    // its own change or at someone else's.
    const s = try bg_tool.runForeground(arena, io, "git diff --shortstat", 10, 4096);
    if (s.term.exited == 0 and s.stdout.len > 0) {
        try out.appendSlice(arena, "\nunstaged: ");
        try out.appendSlice(arena, std.mem.trim(u8, s.stdout, " \t\r\n"));
    }
    const st = try bg_tool.runForeground(arena, io, "git diff --cached --shortstat", 10, 4096);
    if (st.term.exited == 0 and st.stdout.len > 0) {
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

    const r = bg_tool.runForeground(arena, io, cmd, 20, diff_capture) catch |err| switch (err) {
        // Even the wide pipe was not enough (a diff over 256 KB). Say it in this
        // tool's voice, because "narrow the request" does not tell the model
        // that a single file would fit where the whole tree does not.
        error.StreamTooLong => return "the diff is bigger than 256 KB, which is more than this tool captures. Use `bash` with `git diff --stat` to see which files are in it, then `git diff -- <path>` for the one you need.",
        else => |e| return e,
    };
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
    return r.stdout;
}

fn isNotARepo(r: std.process.RunResult) bool {
    if (r.term.exited == 0) return false;
    return std.mem.indexOf(u8, r.stderr, "not a git repository") != null;
}

fn notARepo() []const u8 {
    return "this directory is not a git repository. Nothing was run. If the project is not under git, `git_status`/`git_diff`/`git_log` do not apply to it and `bash` is the way to ask about files.";
}
