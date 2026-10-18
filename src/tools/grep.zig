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

    // 1) ripgrep: fast, respects .gitignore, `--hidden` for dotfiles and
    //    `--follow` for symlinked directories. Exit 1 means "no matches" and
    //    ENDS the chain: rg is authoritative when it is there, and falling
    //    through to a dumber tool would resurface the ignored files it just
    //    refused to show.
    const rg_globs = try buildRgGlobs(args, arena);
    if (nativeGrepRg(arena, io, pattern, subdir, args, context_args, rg_globs)) |out| return out;

    // 2) git grep: the next best inside a repository, and it ignores the same
    //    ignored files. No `rev-parse` to ask whether this IS a repository:
    //    outside one git grep exits 128, `nativeGrep` returns null and the
    //    chain continues — the same cost as the check, one subprocess instead
    //    of two. `--untracked` keeps untracked files visible (that is what rg
    //    searches too); gitignored files stay out of both.
    if (nativeGrepGitGrep(arena, io, pattern, subdir, args, context_args)) |out| return out;

    // 3) the system's grep -rn. No .gitignore here, which is why it is third
    //    and not first: it is the one that would walk .zig-cache.
    if (nativeGrepSystem(arena, io, pattern, subdir, args, context_args)) |out| return out;

    // 4) our own engine: the only one that cannot be missing.
    return fallbackGrep(io, pattern, subdir, args, arena);
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

/// Run ripgrep with the given arguments.
fn nativeGrepRg(arena: std.mem.Allocator, io: std.Io, pattern: []const u8, subdir: []const u8, args: Args, context_args: []const []const u8, globs: []const []const u8) ?[]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.heap.page_allocator);
    argv.append(std.heap.page_allocator, "rg") catch return null;
    argv.append(std.heap.page_allocator, "--no-heading") catch return null;
    argv.append(std.heap.page_allocator, "-n") catch return null;
    argv.append(std.heap.page_allocator, "-S") catch return null;
    argv.append(std.heap.page_allocator, "--hidden") catch return null;
    argv.append(std.heap.page_allocator, "--follow") catch return null;
    argv.append(std.heap.page_allocator, "--max-columns") catch return null;
    argv.append(std.heap.page_allocator, "500") catch return null;
    for (context_args) |ca| argv.append(std.heap.page_allocator, ca) catch return null;
    for (globs) |g| {
        argv.append(std.heap.page_allocator, "-g") catch return null;
        argv.append(std.heap.page_allocator, g) catch return null;
    }
    if (args.output_mode == .files_with_matches) {
        argv.append(std.heap.page_allocator, "-l") catch return null;
    } else if (args.output_mode == .count) {
        argv.append(std.heap.page_allocator, "-c") catch return null;
    } else {
        argv.append(std.heap.page_allocator, "--max-count") catch return null;
        argv.append(std.heap.page_allocator, std.fmt.allocPrint(std.heap.page_allocator, "{}", .{args.head_limit}) catch "80") catch return null;
    }
    argv.append(std.heap.page_allocator, "--") catch return null;
    argv.append(std.heap.page_allocator, pattern) catch return null;
    argv.append(std.heap.page_allocator, subdir) catch return null;
    return nativeGrep(arena, io, argv.items);
}

/// Run git grep with the given arguments.
fn nativeGrepGitGrep(arena: std.mem.Allocator, io: std.Io, pattern: []const u8, subdir: []const u8, args: Args, context_args: []const []const u8) ?[]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.heap.page_allocator);
    argv.append(std.heap.page_allocator, "git") catch return null;
    argv.append(std.heap.page_allocator, "grep") catch return null;
    argv.append(std.heap.page_allocator, "-n") catch return null;
    argv.append(std.heap.page_allocator, "-I") catch return null;
    for (context_args) |ca| argv.append(std.heap.page_allocator, ca) catch return null;
    if (args.output_mode == .files_with_matches) {
        argv.append(std.heap.page_allocator, "-l") catch return null;
    } else if (args.output_mode == .count) {
        argv.append(std.heap.page_allocator, "-c") catch return null;
    } else {
        argv.append(std.heap.page_allocator, "--max-count") catch return null;
        argv.append(std.heap.page_allocator, std.fmt.allocPrint(std.heap.page_allocator, "{}", .{args.head_limit}) catch "40") catch return null;
    }
    argv.append(std.heap.page_allocator, "--untracked") catch return null;
    argv.append(std.heap.page_allocator, "--") catch return null;
    argv.append(std.heap.page_allocator, pattern) catch return null;
    argv.append(std.heap.page_allocator, subdir) catch return null;
    return nativeGrep(arena, io, argv.items);
}

/// Run system grep with the given arguments.
fn nativeGrepSystem(arena: std.mem.Allocator, io: std.Io, pattern: []const u8, subdir: []const u8, args: Args, context_args: []const []const u8) ?[]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.heap.page_allocator);
    argv.append(std.heap.page_allocator, "grep") catch return null;
    argv.append(std.heap.page_allocator, "-rn") catch return null;
    for (context_args) |ca| argv.append(std.heap.page_allocator, ca) catch return null;
    if (args.output_mode == .files_with_matches) {
        argv.append(std.heap.page_allocator, "-l") catch return null;
    } else if (args.output_mode == .count) {
        argv.append(std.heap.page_allocator, "-c") catch return null;
    } else {
        argv.append(std.heap.page_allocator, "-m") catch return null;
        argv.append(std.heap.page_allocator, std.fmt.allocPrint(std.heap.page_allocator, "{}", .{args.head_limit}) catch "5") catch return null;
    }
    argv.append(std.heap.page_allocator, "--include=*") catch return null;
    argv.append(std.heap.page_allocator, "--") catch return null;
    argv.append(std.heap.page_allocator, pattern) catch return null;
    argv.append(std.heap.page_allocator, subdir) catch return null;
    return nativeGrep(arena, io, argv.items);
}

/// Runs a native grep binary; null if the binary does not exist.
pub fn nativeGrep(arena: std.mem.Allocator, io: std.Io, argv: []const []const u8) ?[]const u8 {
    const result = std.process.run(arena, io, .{
        .argv = argv,
        .stdout_limit = .limited(common.max_tool_output),
        .stderr_limit = .limited(2048),
        .reserve_amount = 4096,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } },
    }) catch return null;
    // rg exit 1 = no matches; exit 127/2 = bad binary/usage → try the next one
    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => return null,
    };
    if (code == 0 and result.stdout.len > 0) {
        // Truncate to head_limit lines to not burn tokens
        return truncateLines(arena, result.stdout, 80);
    }
    if (code == 1) {
        return "no matches";
    }
    return null;
}

pub fn truncateLines(arena: std.mem.Allocator, data: []const u8, max_lines: usize) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (count >= max_lines) {
            out.appendSlice(arena, "... (truncated)\n") catch {};
            break;
        }
        out.appendSlice(arena, line) catch {};
        out.appendSlice(arena, "\n") catch {};
        count += 1;
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