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
pub fn toolGrep(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const pattern = common.getStr(obj, "pattern") orelse return error.MissingPattern;
    const subdir = common.getStr(obj, "subdir") orelse ".";

    // 1) ripgrep: fast, respects .gitignore, `--hidden` for dotfiles and
    //    `--follow` for symlinked directories. Exit 1 means "no matches" and
    //    ENDS the chain: rg is authoritative when it is there, and falling
    //    through to a dumber tool would resurface the ignored files it just
    //    refused to show.
    const rg_argv = [_][]const u8{ "rg", "--no-heading", "-n", "-S", "--hidden", "--follow", "--max-count", "12", "--max-columns", "500", "--", pattern, subdir };
    if (nativeGrep(arena, io, &rg_argv)) |out| return out;

    // 2) git grep: the next best inside a repository, and it ignores the same
    //    ignored files. No `rev-parse` to ask whether this IS a repository:
    //    outside one git grep exits 128, `nativeGrep` returns null and the
    //    chain continues — the same cost as the check, one subprocess instead
    //    of two. `--untracked` keeps untracked files visible (that is what rg
    //    searches too); gitignored files stay out of both.
    const gg_argv = [_][]const u8{ "git", "grep", "-n", "-I", "--max-count", "40", "--untracked", "--", pattern, subdir };
    if (nativeGrep(arena, io, &gg_argv)) |out| return out;

    // 3) the system's grep -rn. No .gitignore here, which is why it is third
    //    and not first: it is the one that would walk .zig-cache.
    const grep_argv = [_][]const u8{ "grep", "-rn", "--include=*", "-m", "5", "--", pattern, subdir };
    if (nativeGrep(arena, io, &grep_argv)) |out| return out;

    // 4) our own engine: the only one that cannot be missing.
    return fallbackGrep(io, pattern, subdir, arena);
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
        // Truncate to ~80 lines to not burn tokens
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
            out.appendSlice(arena, "… (truncated)\n") catch {};
            break;
        }
        out.appendSlice(arena, line) catch {};
        out.appendSlice(arena, "\n") catch {};
        count += 1;
    }
    return out.items;
}

/// Pure-Zig fallback for when there is neither rg nor grep (rare on dev boxes).
pub fn fallbackGrep(io: std.Io, pattern: []const u8, subdir: []const u8, arena: std.mem.Allocator) ![]const u8 {
    const regex = @import("../lib/regex.zig").Regex.compile(pattern);

    var out: std.ArrayList(u8) = .empty;
    var matches: usize = 0;
    const max_matches = 150;

    var walker = try common.walkZig(io, arena, subdir);
    defer walker.deinit();

    while (walker.next()) |entry_path| {
        defer arena.free(entry_path);
        if (matches >= max_matches) {
            out.appendSlice(arena, "… (more matches omitted)\n") catch {};
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
