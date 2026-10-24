const std = @import("std");
const common = @import("common.zig");
const list_files_tool = @import("list_files.zig");

// ── grep: rg > git grep (in a repo) > grep -rn > internal fallback ──────
//
// There is NO "which binary exists?" probe: `nativeGrep` already returns
// null for a binary that cannot run, which is exactly what the chain needs to
// move on to the next step. A probe would be a first subprocess paid to avoid
// a fallback that is itself one, plus a process-wide cache — and grep is one
// of the PARALLEL-SAFE tools, so that cache would be written from several
// threads at once, and its `run` result was never freed.
//
// Every argv ends with `--` before the pattern: the pattern comes from the
// model, and a pattern starting with "-" is otherwise read as an option. rg,
// git grep and GNU grep were each checked to accept the separator.

/// Parsed arguments for the grep tool.
pub const Args = struct {
    pattern: []const u8,
    subdir: []const u8 = ".",
    context: usize = 0,
    context_before: usize = 0,
    context_after: usize = 0,
    glob: ?[]const u8 = null,
    type: ?[]const u8 = null,
    output_mode: OutputMode = .content,
    head_limit: usize = 80,
    /// The page of results to show: the first `offset` lines are skipped.
    ///
    /// It exists because `head_limit` used to be a lie — a cut with nothing to
    /// page to is a cut the model can only answer by running the same search
    /// again.
    offset: usize = 0,

    pub const OutputMode = enum { content, files_with_matches, count };
};

pub fn parseArgs(obj: std.json.ObjectMap, arena: std.mem.Allocator) !Args {
    const pattern = common.getStr(obj, "pattern") orelse return error.MissingPattern;
    if (pattern.len == 0) return error.BadGlobArg;

    var args: Args = .{ .pattern = pattern };

    if (common.getStr(obj, "subdir")) |raw| {
        const s = normalizeSubdir(raw);
        if (s.len == 0) return error.BadGlobArg;
        args.subdir = s;
    }

    if (obj.get("context")) |v| {
        switch (v) {
            .integer => |n| {
                if (n < 0) return error.BadGlobArg;
                args.context = @intCast(n);
            },
            else => return error.BadGlobArg,
        }
    }

    if (obj.get("context_before")) |v| {
        switch (v) {
            .integer => |n| {
                if (n < 0) return error.BadGlobArg;
                args.context_before = @intCast(n);
            },
            else => return error.BadGlobArg,
        }
    }

    if (obj.get("context_after")) |v| {
        switch (v) {
            .integer => |n| {
                if (n < 0) return error.BadGlobArg;
                args.context_after = @intCast(n);
            },
            else => return error.BadGlobArg,
        }
    }

    if (common.getStr(obj, "glob")) |g| {
        args.glob = g;
    }

    if (common.getStr(obj, "type")) |t| {
        // Validate type against known types
        const valid_types = [_][]const u8{
            "zig", "js", "ts", "py", "rs", "go", "java", "cpp", "c", "h", "hpp",
            "rb", "php", "sh", "sql", "md", "json", "yaml", "yml", "toml",
            "html", "css", "scss", "less", "xml",
        };
        // Lowercase the input for comparison (need mutable copy)
        const t_lower = try arena.dupe(u8, t);
        for (t_lower) |*c| c.* = std.ascii.toLower(c.*);
        var valid = false;
        for (valid_types) |vt| {
            if (std.mem.eql(u8, t_lower, vt)) {
                valid = true;
                break;
            }
        }
        if (!valid) return error.InvalidArgument;
        args.type = t;
    }

    if (common.getStr(obj, "output_mode")) |om| {
        if (std.mem.eql(u8, om, "content")) {
            args.output_mode = .content;
        } else if (std.mem.eql(u8, om, "files_with_matches")) {
            args.output_mode = .files_with_matches;
        } else if (std.mem.eql(u8, om, "count")) {
            args.output_mode = .count;
        } else {
            return error.BadGlobArg;
        }
    }

    if (obj.get("head_limit")) |v| {
        switch (v) {
            .integer => |n| {
                if (n < 1) return error.BadGlobArg;
                args.head_limit = @intCast(n);
            },
            else => return error.BadGlobArg,
        }
    }

    if (obj.get("offset")) |v| {
        switch (v) {
            .integer => |n| {
                if (n < 0) return error.BadGlobArg;
                args.offset = @intCast(n);
            },
            else => return error.BadGlobArg,
        }
    }

    return args;
}

/// Normalize subdir (copied from glob.zig for consistency).
fn normalizeSubdir(raw: []const u8) []const u8 {
    var s = raw;
    while (s.len > 1 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    if (s.len > 2 and s[0] == '.' and s[1] == '/') s = s[2..];
    if (std.mem.eql(u8, s, "./")) s = ".";
    return s;
}

/// Build the glob/type filter for ripgrep.
fn buildRgGlobs(args: Args, arena: std.mem.Allocator) ![]const []const u8 {
    var globs: std.ArrayList([]const u8) = .empty;
    defer globs.deinit(arena);

    if (args.glob) |g| {
        try globs.append(arena, g);
    }
    if (args.type) |t| {
        const type_glob = try mapTypeToGlob(arena, t);
        try globs.append(arena, type_glob);
    }
    if (globs.items.len == 0) return &.{};
    return globs.items;
}

/// Map file type to glob pattern.
fn mapTypeToGlob(arena: std.mem.Allocator, file_type: []const u8) ![]const u8 {
    // Common file type extensions
    const lower = try arena.dupe(u8, file_type);
    for (lower) |*c| c.* = std.ascii.toLower(c.*);
    if (std.mem.eql(u8, lower, "zig")) {
        return "*.zig";
    } else if (std.mem.eql(u8, lower, "js")) {
        return "*.js";
    } else if (std.mem.eql(u8, lower, "ts")) {
        return "*.ts";
    } else if (std.mem.eql(u8, lower, "py")) {
        return "*.py";
    } else if (std.mem.eql(u8, lower, "rs")) {
        return "*.rs";
    } else if (std.mem.eql(u8, lower, "go")) {
        return "*.go";
    } else if (std.mem.eql(u8, lower, "java")) {
        return "*.java";
    } else if (std.mem.eql(u8, lower, "cpp")) {
        return "*.cpp";
    } else if (std.mem.eql(u8, lower, "c")) {
        return "*.c";
    } else if (std.mem.eql(u8, lower, "h")) {
        return "*.h";
    } else if (std.mem.eql(u8, lower, "hpp")) {
        return "*.hpp";
    } else if (std.mem.eql(u8, lower, "rb")) {
        return "*.rb";
    } else if (std.mem.eql(u8, lower, "php")) {
        return "*.php";
    } else if (std.mem.eql(u8, lower, "sh")) {
        return "*.sh";
    } else if (std.mem.eql(u8, lower, "sql")) {
        return "*.sql";
    } else if (std.mem.eql(u8, lower, "md")) {
        return "*.md";
    } else if (std.mem.eql(u8, lower, "json")) {
        return "*.json";
    } else if (std.mem.eql(u8, lower, "yaml")) {
        return "*.yaml";
    } else if (std.mem.eql(u8, lower, "yml")) {
        return "*.yml";
    } else if (std.mem.eql(u8, lower, "toml")) {
        return "*.toml";
    } else if (std.mem.eql(u8, lower, "html")) {
        return "*.html";
    } else if (std.mem.eql(u8, lower, "css")) {
        return "*.css";
    } else if (std.mem.eql(u8, lower, "scss")) {
        return "*.scss";
    } else if (std.mem.eql(u8, lower, "less")) {
        return "*.less";
    } else if (std.mem.eql(u8, lower, "xml")) {
        return "*.xml";
    } else {
        return error.InvalidArgument;
    }
}

pub fn toolGrep(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const args = try parseArgs(obj, arena);
    const pattern = args.pattern;
    const subdir = args.subdir;

    // Build context args for native greps
    const context_args = buildContextArgs(args);

    // 1) ripgrep: fast, respects .gitignore, `--hidden` for dotfiles. Exit 1
    //    means "no matches" and ENDS the chain: rg is authoritative when it is
    //    there, and falling through to a dumber tool would resurface the
    //    ignored files it just refused to show.
    //
    //    The chain now moves on for ONE reason only: ripgrep is not installed.
    //    "The answer did not fit" and "the pattern was rejected" are ANSWERS,
    //    and they are returned as such — see `Native` for why that used to be
    //    the difference between a right answer and a different one.
    const rg_globs = try buildRgGlobs(args, arena);
    switch (nativeGrepRg(arena, io, pattern, subdir, args, context_args, rg_globs)) {
        .output => |o| return o,
        .missing => {},
        .bad_pattern => |m| return m,
        .too_large => |m| return m,
    }

    // 2) git grep: the next best inside a repository, and it ignores the same
    //    ignored files. No `rev-parse` to ask whether this IS a repository:
    //    outside one git grep exits 128, `nativeGrep` says `missing` and the
    //    chain continues — the same cost as the check, one subprocess instead
    //    of two. `--untracked` keeps untracked files visible (that is what rg
    //    searches too); gitignored files stay out of both.
    switch (nativeGrepGitGrep(arena, io, pattern, subdir, args, context_args)) {
        .output => |o| return fromEngine(arena, o, "git grep"),
        .missing => {},
        .bad_pattern => |m| return m,
        .too_large => |m| return m,
    }

    // 3) the system's grep -rn. No .gitignore here, which is why it is third
    //    and not first: it is the one that would walk .zig-cache.
    switch (nativeGrepSystem(arena, io, pattern, subdir, args, context_args)) {
        .output => |o| return fromEngine(arena, o, "the system grep"),
        .missing => {},
        .bad_pattern => |m| return m,
        .too_large => |m| return m,
    }

    // 4) our own engine: the only one that cannot be missing.
    const out = try fallbackGrep(io, pattern, subdir, args, arena);
    return fromEngine(arena, out, "zode's own engine");
}

/// Says which engine produced the answer, when it was not the expected one.
///
/// The engines do not speak the same regex dialect and they do not know the
/// same filters: ripgrep uses Rust regex and honours `.gitignore`; `git grep`
/// and the system grep use POSIX ERE and have no `.gitignore`; zode's own
/// engine is a small subset with no `{n,m}`, no groups and no `(?i)`, and it
/// ignores `glob`, `type` and `output_mode`.
///
/// An answer from a different engine is a DIFFERENT answer, and the model has
/// no way to tell. So it is said, in one line, above the answer.
///
/// The chain only reaches here when ripgrep was NOT installed, so the line is
/// always true when it is printed.
fn fromEngine(arena: std.mem.Allocator, out: []const u8, engine: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, "(ripgrep is not installed here, so this search was done with {s}; its regex dialect and its file filters are not the same)\n{s}", .{ engine, out }) catch out;
}

/// Build context arguments for native greps.
fn buildContextArgs(args: Args) []const []const u8 {
    var ctx_args: std.ArrayList([]const u8) = .empty;
    if (args.context > 0) {
        ctx_args.append(std.heap.page_allocator, "-C") catch {};
        ctx_args.append(std.heap.page_allocator, std.fmt.allocPrint(std.heap.page_allocator, "{}", .{args.context}) catch "0") catch {};
    } else {
        if (args.context_before > 0) {
            ctx_args.append(std.heap.page_allocator, "-B") catch {};
            ctx_args.append(std.heap.page_allocator, std.fmt.allocPrint(std.heap.page_allocator, "{}", .{args.context_before}) catch "0") catch {};
        }
        if (args.context_after > 0) {
            ctx_args.append(std.heap.page_allocator, "-A") catch {};
            ctx_args.append(std.heap.page_allocator, std.fmt.allocPrint(std.heap.page_allocator, "{}", .{args.context_after}) catch "0") catch {};
        }
    }
    return ctx_args.items;
}

/// What one native engine produced.
///
/// ## Why this is a union and not a `?[]const u8`
///
/// The old signature was `?[]const u8`, and `null` had to carry THREE different
/// meanings at once:
///
/// - the binary is not installed → try the next engine;
/// - the binary ran and the output did not fit the 16 KB capture → the whole
///   chain restarted and the answer came from the internal engine, whose regex
///   dialect is different, which knows no `glob`, no `type` and no `output_mode`;
/// - the binary ran and the PATTERN was invalid → the same: an answer from
///   another dialect, silently.
///
/// The model cannot tell a different answer from the same answer, so every one
/// of those was a lie of omission. `missing` is the ONLY case that moves on.
/// The other two are ANSWERS, and they say what happened.
const Native = union(enum) {
    /// The engine answered. This is what it printed.
    output: []const u8,
    /// The engine is not installed, or could not be started.
    missing,
    /// The engine answered and the PATTERN was what it rejected.
    bad_pattern: []const u8,
    /// The engine answered but its output did not fit the capture limit.
    too_large: []const u8,
};

/// How much a native engine may print before we stop caring.
///
/// This is NOT the tool's budget: `head_limit` (in LINES) is that, and it is
/// applied after the capture. The capture is the safety net for a search that
/// matches a million lines.
///
/// It has to be much bigger than the budget, and the reason is mechanical:
/// `std.process.run` DISCARDS the output when the limit is exceeded
/// (`error.StreamTooLong`). The old limit was 16 KB — the same size as the
/// tool budget — so every search with a big answer lost it and fell through to
/// a different engine.
pub var grep_capture: usize = 10 * 1024 * 1024;

/// Read `ZODE_MAX_TOOL_OUTPUT` and install it as `grep_capture`. Safe to call
/// once at startup.
pub fn initGrepCapture(env: ?*const std.process.Environ.Map) void {
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
    const hard_cap = 100 * 1024 * 1024;
    if (wanted > hard_cap) wanted = hard_cap;
    grep_capture = wanted;
}

/// The directories that are never searched, as ripgrep globs.

/// Read `ZODE_MAX_TOOL_OUTPUT` and install it as `grep_capture`. Safe to call
/// once at startup.
/// The directories that are never searched, as ripgrep globs.
///
/// `--hidden` makes ripgrep look inside dot-directories, and `.git` is one of
/// them: without this, a search for "commit" matched `.git/HEAD`,
/// `.git/logs/HEAD` and the sample hooks, which are noise and false positives.
/// The other five are the same idea for the other version control systems.
const vcs_exclude_globs = [_][]const u8{ "!.git", "!.svn", "!.hg", "!.bzr", "!.jj", "!.sl" };

/// Run ripgrep with the given arguments.
fn nativeGrepRg(arena: std.mem.Allocator, io: std.Io, pattern: []const u8, subdir: []const u8, args: Args, context_args: []const []const u8, globs: []const []const u8) Native {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.heap.page_allocator);
    argv.append(std.heap.page_allocator, "rg") catch return .missing;
    argv.append(std.heap.page_allocator, "--no-heading") catch return .missing;
    argv.append(std.heap.page_allocator, "-n") catch return .missing;
    argv.append(std.heap.page_allocator, "-S") catch return .missing;
    argv.append(std.heap.page_allocator, "--hidden") catch return .missing;
    argv.append(std.heap.page_allocator, "--max-columns") catch return .missing;
    argv.append(std.heap.page_allocator, "500") catch return .missing;
    // `--follow` is gone: it makes ripgrep follow symlinks out of the project
    // and can walk a cycle. The other search tools in this repo walk the tree
    // themselves and do not follow them either.
    for (vcs_exclude_globs) |v| {
        argv.append(std.heap.page_allocator, "--glob") catch return .missing;
        argv.append(std.heap.page_allocator, v) catch return .missing;
    }
    for (context_args) |ca| argv.append(std.heap.page_allocator, ca) catch return .missing;
    for (globs) |g| {
        argv.append(std.heap.page_allocator, "-g") catch return .missing;
        argv.append(std.heap.page_allocator, g) catch return .missing;
    }
    if (args.output_mode == .files_with_matches) {
        argv.append(std.heap.page_allocator, "-l") catch return .missing;
    } else if (args.output_mode == .count) {
        argv.append(std.heap.page_allocator, "-c") catch return .missing;
    }
    // No `--max-count`: in ripgrep that is a limit PER FILE, so it is not the
    // limit the model asked for (`head_limit` is global, and it is applied to
    // the captured output below).
    argv.append(std.heap.page_allocator, "--") catch return .missing;
    argv.append(std.heap.page_allocator, pattern) catch return .missing;
    argv.append(std.heap.page_allocator, subdir) catch return .missing;
    return nativeGrep(arena, io, argv.items, args.offset, args.head_limit);
}

/// Run git grep with the given arguments.
fn nativeGrepGitGrep(arena: std.mem.Allocator, io: std.Io, pattern: []const u8, subdir: []const u8, args: Args, context_args: []const []const u8) Native {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.heap.page_allocator);
    argv.append(std.heap.page_allocator, "git") catch return .missing;
    argv.append(std.heap.page_allocator, "grep") catch return .missing;
    argv.append(std.heap.page_allocator, "-n") catch return .missing;
    argv.append(std.heap.page_allocator, "-I") catch return .missing;
    for (context_args) |ca| argv.append(std.heap.page_allocator, ca) catch return .missing;
    if (args.output_mode == .files_with_matches) {
        argv.append(std.heap.page_allocator, "-l") catch return .missing;
    } else if (args.output_mode == .count) {
        argv.append(std.heap.page_allocator, "-c") catch return .missing;
    }
    argv.append(std.heap.page_allocator, "--untracked") catch return .missing;
    argv.append(std.heap.page_allocator, "--") catch return .missing;
    argv.append(std.heap.page_allocator, pattern) catch return .missing;
    argv.append(std.heap.page_allocator, subdir) catch return .missing;
    return nativeGrep(arena, io, argv.items, args.offset, args.head_limit);
}

/// Run system grep with the given arguments.
fn nativeGrepSystem(arena: std.mem.Allocator, io: std.Io, pattern: []const u8, subdir: []const u8, args: Args, context_args: []const []const u8) Native {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.heap.page_allocator);
    argv.append(std.heap.page_allocator, "grep") catch return .missing;
    argv.append(std.heap.page_allocator, "-rn") catch return .missing;
    // `-E`: without it the system grep is in POSIX BASIC mode, where `+`, `?`
    // and `{n,m}` are LITERALS. The same pattern then means two different
    // things depending on which binary is on the machine — measured here:
    // `rg "a+"` matches `aaa` and `abc`, `grep -rn "a+"` matches only `a+`.
    argv.append(std.heap.page_allocator, "-E") catch return .missing;
    // `-I`: a binary file is not a text file, and its bytes are not lines.
    argv.append(std.heap.page_allocator, "-I") catch return .missing;
    for (context_args) |ca| argv.append(std.heap.page_allocator, ca) catch return .missing;
    if (args.output_mode == .files_with_matches) {
        argv.append(std.heap.page_allocator, "-l") catch return .missing;
    } else if (args.output_mode == .count) {
        argv.append(std.heap.page_allocator, "-c") catch return .missing;
    }
    argv.append(std.heap.page_allocator, "--") catch return .missing;
    argv.append(std.heap.page_allocator, pattern) catch return .missing;
    argv.append(std.heap.page_allocator, subdir) catch return .missing;
    return nativeGrep(arena, io, argv.items, args.offset, args.head_limit);
}

/// Runs a native grep binary and says what happened.
pub fn nativeGrep(arena: std.mem.Allocator, io: std.Io, argv: []const []const u8, offset: usize, head_limit: usize) Native {
    const result = std.process.run(arena, io, .{
        .argv = argv,
        .stdout_limit = .limited(grep_capture),
        .stderr_limit = .limited(8 * 1024),
        .reserve_amount = 4096,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } },
    }) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        error.StreamTooLong => return .{ .too_large = "the search printed more than 1 MB and was stopped. Narrow it: a `glob`, a `type` or a smaller `subdir`." },
        else => return .missing,
    };
    // rg exit 1 = no matches; exit 127 = the binary is not there; exit 2 = the
    // PATTERN or the options are wrong. Only the first one is an answer.
    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => return .{ .too_large = "the search was stopped before it finished." },
    };
    if (code == 1) return .{ .output = "no matches" };
    if (code == 127) return .missing;
    if (code == 2) {
        const e = std.mem.trim(u8, result.stderr, " \t\r\n");
        const detail = if (e.len > 0) e[0..@min(e.len, 300)] else "the pattern was rejected";
        return .{ .bad_pattern = std.fmt.allocPrint(arena, "the search engine rejected the pattern: {s}", .{detail}) catch "the search engine rejected the pattern." };
    }
    if (code != 0) {
        const e = std.mem.trim(u8, result.stderr, " \t\r\n");
        const detail = if (e.len > 0) e[0..@min(e.len, 300)] else "no message";
        return .{ .too_large = std.fmt.allocPrint(arena, "the search failed (exit {d}): {s}", .{ code, detail }) catch "the search failed." };
    }
    if (result.stdout.len == 0) return .{ .output = "no matches" };
    return .{ .output = truncateLines(arena, result.stdout, offset, head_limit) };
}

/// Cuts at a line boundary and says how much is not there.
///
/// The notice is the point of the function. A cut that does not say so reads as
/// "this is everything", and the model then believes the search found 80 hits
/// when it found 8000 — and, with nothing to page to, it repeats the same
/// search and pays for it twice.
///
/// `offset` is the page the caller is on: the first `offset` lines are skipped
/// and the notice names the NEXT page, so the model can walk the results
/// instead of re-running the search.
pub fn truncateLines(arena: std.mem.Allocator, data: []const u8, offset: usize, max_lines: usize) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var count: usize = 0;
    var skipped: usize = 0;
    var index: usize = 0;
    // The trailing newline is not a line. `splitScalar` yields an empty
    // segment for it, and counting that as a hidden line made the notice say
    // "81 more lines not shown" for a 100-line answer cut at 20.
    const body = if (data.len > 0 and data[data.len - 1] == '\n') data[0 .. data.len - 1] else data;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (index < offset) {
            index += 1;
            skipped += 1;
            continue;
        }
        if (count >= max_lines) {
            skipped += 1;
            continue;
        }
        out.appendSlice(arena, line) catch {};
        out.appendSlice(arena, "\n") catch {};
        count += 1;
        index += 1;
    }
    if (skipped > 0) {
        out.print(arena, "... ({d} more lines not shown; pass offset={d} to continue)\n", .{ skipped, offset + count }) catch {};
    }
    return out.items;
}

/// Pure-Zig fallback for when there is neither rg nor grep (rare on dev boxes).
pub fn fallbackGrep(io: std.Io, pattern: []const u8, subdir: []const u8, _args: Args, arena: std.mem.Allocator) ![]const u8 {
    _ = _args;
    const regex = @import("../lib/regex.zig").Regex.compile(pattern);

    var out: std.ArrayList(u8) = .empty;
    var matches: usize = 0;
    const max_matches = 150;

    var walker = try common.walkZig(io, arena, subdir);
    defer walker.deinit();

    while (walker.next()) |entry_path| {
        defer arena.free(entry_path);
        if (matches >= max_matches) {
            out.appendSlice(arena, "... (more matches omitted)\n") catch {};
            break;
        }
        if (!list_files_tool.looksLikeText(entry_path)) continue;
        const data = std.Io.Dir.cwd().readFileAlloc(io, entry_path, arena, .limited(2 * 1024 * 1024)) catch continue;
        defer arena.free(data);

        var line_no: usize = 0;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            line_no += 1;
            if (regex.matches(line)) {
                out.print(arena, "{s}:{d}: {s}\n", .{ entry_path, line_no, line[0..@min(line.len, 300)] }) catch {};
                matches += 1;
                if (matches >= max_matches) break;
            }
        }
    }
    if (matches == 0) return std.fmt.allocPrint(arena, "no matches: {s}", .{pattern});
    return out.items;
}

// ─── tests ────────────────────────────────────────────────────────────

fn parseJson(a: std.mem.Allocator, json: []const u8) !Args {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    return parseArgs(v.object, a);
}

test "grep args: pattern is required" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.MissingPattern, parseJson(arena_state.allocator(), "{}"));
}

test "grep args: subdir, context, glob, type, output_mode, head_limit are parsed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = try parseJson(arena_state.allocator(),
        "{\"pattern\":\"foo\",\"subdir\":\"src\",\"context\":2,\"context_before\":1,\"context_after\":3,\"glob\":\"*.zig\",\"type\":\"zig\",\"output_mode\":\"files_with_matches\",\"head_limit\":50}");
    try std.testing.expectEqualStrings("src", a.subdir);
    try std.testing.expectEqual(@as(usize, 2), a.context);
    try std.testing.expectEqual(@as(usize, 1), a.context_before);
    try std.testing.expectEqual(@as(usize, 3), a.context_after);
    try std.testing.expectEqualStrings("*.zig", a.glob.?);
    try std.testing.expectEqualStrings("zig", a.type.?);
    try std.testing.expectEqual(Args.OutputMode.files_with_matches, a.output_mode);
    try std.testing.expectEqual(@as(usize, 50), a.head_limit);
}

test "grep args: invalid output_mode is rejected" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.BadGlobArg, parseJson(arena_state.allocator(), "{\"pattern\":\"foo\",\"output_mode\":\"invalid\"}"));
}

test "grep args: negative context is rejected" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.BadGlobArg, parseJson(arena_state.allocator(), "{\"pattern\":\"foo\",\"context\":-1}"));
}

test "grep args: head_limit must be >= 1" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.BadGlobArg, parseJson(arena_state.allocator(), "{\"pattern\":\"foo\",\"head_limit\":0}"));
}

test "grep args: unknown type is rejected" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.InvalidArgument, parseJson(arena_state.allocator(), "{\"pattern\":\"foo\",\"type\":\"unknown_type\"}"));
}

test "grep args: context_before and context_after work independently" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = try parseJson(arena_state.allocator(),
        "{\"pattern\":\"foo\",\"context_before\":2,\"context_after\":5}");
    try std.testing.expectEqual(@as(usize, 2), a.context_before);
    try std.testing.expectEqual(@as(usize, 5), a.context_after);
    try std.testing.expectEqual(@as(usize, 0), a.context);
}

test "grep args: output_mode count is parsed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = try parseJson(arena_state.allocator(),
        "{\"pattern\":\"foo\",\"output_mode\":\"count\"}");
    try std.testing.expectEqual(Args.OutputMode.count, a.output_mode);
}

test "grep args: output_mode content is default" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = try parseJson(arena_state.allocator(),
        "{\"pattern\":\"foo\"}");
    try std.testing.expectEqual(Args.OutputMode.content, a.output_mode);
}

test "grep args: glob filter is parsed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = try parseJson(arena_state.allocator(),
        "{\"pattern\":\"foo\",\"glob\":\"**/*.test.zig\"}");
    try std.testing.expectEqualStrings("**/*.test.zig", a.glob.?);
}

test "grep args: type filter is case-insensitive" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = try parseJson(arena_state.allocator(),
        "{\"pattern\":\"foo\",\"type\":\"ZIG\"}");
    try std.testing.expectEqualStrings("ZIG", a.type.?);
}

test "grep args: head_limit defaults to 80" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = try parseJson(arena_state.allocator(),
        "{\"pattern\":\"foo\"}");
    try std.testing.expectEqual(@as(usize, 80), a.head_limit);
}

test "grep args: subdir normalizes ./ prefix" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = try parseJson(arena_state.allocator(),
        "{\"pattern\":\"foo\",\"subdir\":\"./src/\"}");
    try std.testing.expectEqualStrings("src", a.subdir);
}
// ── tests ──────────────────────────────────────────────────────────────────────
//
// The three that matter here are the ones about a search that produced a LOT:
// the old capture limit was the same 16 KB as the tool budget, and
// `std.process.run` DISCARDS the output when the limit is exceeded. So a
// search with a big answer lost it, the chain moved on, and the model was
// answered by the internal engine: a different regex dialect, no `.gitignore`,
// no `glob`, no `type`, and nothing marking that the answer had changed.

test "grep: head_limit is the TOTAL number of lines, not a per-file one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 200 lines, a limit of 10: the old code cut at a literal 80 whatever the
    // model asked for, so `head_limit: 10` returned 80 lines.
    var data: std.ArrayList(u8) = .empty;
    for (0..200) |i| {
        try data.print(arena, "line {d}\n", .{i});
    }
    const out = truncateLines(arena, data.items, 0, 10);
    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |l| {
        if (l.len == 0) continue;
        if (std.mem.startsWith(u8, l, "...")) continue;
        lines += 1;
    }
    try std.testing.expectEqual(@as(usize, 10), lines);
}

test "grep: a cut says how much is missing and how to continue" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var data: std.ArrayList(u8) = .empty;
    for (0..100) |i| try data.print(arena, "line {d}\n", .{i});
    const out = truncateLines(arena, data.items, 0, 20);
    // The number of lines that are NOT there, and the offset that shows them.
    try std.testing.expect(std.mem.indexOf(u8, out, "80 more lines not shown") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "offset=20") != null);
}

test "grep: offset pages through the results" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var data: std.ArrayList(u8) = .empty;
    for (0..100) |i| try data.print(arena, "line {d}\n", .{i});
    const first = truncateLines(arena, data.items, 0, 10);
    const second = truncateLines(arena, data.items, 10, 10);
    try std.testing.expect(std.mem.indexOf(u8, first, "line 0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "line 10\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, second, "line 10\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "line 0\n") == null);
}

test "grep: a search whose answer is bigger than the tool budget is still answered by the same engine" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = "/tmp/opencode/grep-big-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    var body: std.ArrayList(u8) = .empty;
    for (0..3000) |i| try body.print(arena, "needle {d}\n", .{i});
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = dir ++ "/big.txt", .data = body.items });

    const args: Args = .{ .pattern = "needle", .subdir = dir };
    const out = switch (nativeGrepRg(arena, std.testing.io, args.pattern, args.subdir, args, &.{}, &.{})) {
        .missing => return error.SkipZigTest, // no ripgrep on this machine
        .output => |o| o,
        .bad_pattern => |m| {
            std.debug.print("unexpected: {s}\n", .{m});
            return error.TestUnexpectedResult;
        },
        .too_large => |m| {
            // This is the OLD behaviour and it is the bug: the answer was thrown
            // away and the chain answered from a different engine.
            std.debug.print("the answer was discarded: {s}\n", .{m});
            return error.TestUnexpectedResult;
        },
    };

    // 3000 lines of output is about 40 KB: past the old 16 KB capture, which
    // is where the whole chain used to change engine.
    try std.testing.expect(std.mem.indexOf(u8, out, "needle 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "more lines not shown") != null);
}

test "grep: the search does not go inside .git" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = "/tmp/opencode/grep-git-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir ++ "/.git");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = dir ++ "/.git/HEAD", .data = "ref: refs/heads/zedmarker\n" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = dir ++ "/plain.txt", .data = "nothing here\n" });

    const args: Args = .{ .pattern = "zedmarker", .subdir = dir };
    const out = switch (nativeGrepRg(arena, std.testing.io, args.pattern, args.subdir, args, &.{}, &.{})) {
        .missing => return error.SkipZigTest,
        .output => |o| o,
        .bad_pattern => |m| {
            std.debug.print("unexpected: {s}\n", .{m});
            return error.TestUnexpectedResult;
        },
        .too_large => |m| {
            std.debug.print("unexpected: {s}\n", .{m});
            return error.TestUnexpectedResult;
        },
    };
    // `--hidden` makes ripgrep look inside dot-directories, and `.git` is one.
    try std.testing.expect(std.mem.indexOf(u8, out, "zedmarker") == null);
}
