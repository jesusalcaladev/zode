const std = @import("std");
const common = @import("common.zig");
const list_files_tool = @import("list_files.zig");

// ── grep: native rg > native grep > internal fallback ────────
pub fn toolGrep(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const pattern = common.getStr(obj, "pattern") orelse return error.MissingPattern;
    const subdir = common.getStr(obj, "subdir") orelse ".";

    // 1) ripgrep (the best: fast, respects .gitignore)
    // Smart case: case-insensitive if all lowercase, sensitive if has uppercase
    const rg_argv = [_][]const u8{ "rg", "--no-heading", "-n", "-S", "--hidden", "--max-count", "10", "--max-columns", "400", pattern, subdir };
    if (nativeGrep(arena, io, &rg_argv)) |out| return out;

    // 2) the system's grep -rn
    const grep_argv = [_][]const u8{ "grep", "-rn", "--include=*", "-m", "5", pattern, subdir };
    if (nativeGrep(arena, io, &grep_argv)) |out| return out;

    // 3) fallback: internal regex engine
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
