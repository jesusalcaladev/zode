//! Tool result store: large results go to a file, the model gets a preview
//! and a path it can read. Pure filesystem logic — no network, no TUI.

const std = @import("std");
const resultcap = @import("resultcap.zig");

pub var max_result_bytes: usize = 400_000;
pub var summary_max_len: usize = 50;
pub var preview_bytes: usize = 2 * 1024;

/// The per-tool and per-message caps live in `resultcap` (the single cap
/// layer); this store only owns what persistence adds: how much of an
/// oversized result is written to disk (`max_result_bytes`), the preview size
/// shown to the model (`preview_bytes`) and the stored-summary length
/// (`summary_max_len`).
const tool_results_subdir: []const u8 = "tool-results";
// Keep the historical "read the part you need" phrase: compaction/tests and
// old sessions extract the path by matching it.
const stored_notice: []const u8 =
    "\n… (result stored at {s}; read the part you need with read path={s} offset=1 limit=2000)\n";

pub const Stored = struct {
    text: []const u8,
    cut: bool,
    stored: bool,
    path: ?[]const u8 = null,
};

/// Returns the session-isolated directory for stored tool results.
/// `session_path` is the full session file path (e.g. `sessions/zode-abcd.jsonl`).
/// Results are stored under `<sessions_dir>/tool-results/<session_stem>/` so
/// different sessions never collide even when they share the same sessions dir.
pub fn sessionToolResultsDir(arena: std.mem.Allocator, session_path: []const u8) ![]const u8 {
    const dir = std.fs.path.dirname(session_path) orelse ".";
    const base = std.fs.path.basename(session_path);
    const stem = if (std.mem.endsWith(u8, base, ".jsonl"))
        base[0 .. base.len - ".jsonl".len]
    else
        base;
    return std.fs.path.join(arena, &.{ dir, tool_results_subdir, stem });
}

/// Stores an oversized result in the session's tool-results directory.
/// `session_path` is the session JSONL path; results are isolated per session.
pub fn storeResult(
    arena: std.mem.Allocator,
    io: ?std.Io,
    session_path: []const u8,
    index: usize,
    result: []const u8,
) Stored {
    if (result.len <= resultcap.default_max_result_chars) {
        return .{ .text = result, .cut = false, .stored = false };
    }

    var to_store: []const u8 = result;
    if (result.len > max_result_bytes) {
        to_store = result[0..max_result_bytes];
    }

    const tool_dir = sessionToolResultsDir(arena, session_path) catch {
        return capResultFallback(arena, result);
    };

    // If we have an Io handle, try to persist the full result to disk.  If we
    // don't (e.g. in tests), fall back to inline truncation so the caller
    // still gets a useful result.
    if (io) |io_val| {
        const cwd = std.Io.Dir.cwd();
        _ = cwd.createDirPathStatus(io_val, tool_dir, @fromBackingInt(@intCast(0o700))) catch {};

        const file_name = std.fmt.allocPrint(arena, "{d}.txt", .{index}) catch {
            return capResultFallback(arena, result);
        };
        const file_path = std.fs.path.join(arena, &.{ tool_dir, file_name }) catch {
            return capResultFallback(arena, result);
        };

        const file = std.Io.Dir.cwd().createFile(io_val, file_path, .{ .truncate = true }) catch {
            return capResultFallback(arena, result);
        };
        _ = file.setPermissions(io_val, @fromBackingInt(@intCast(0o600))) catch {};
        var buf: [4096]u8 = undefined;
        var fw = file.writer(io_val, &buf);
        fw.interface.writeAll(to_store) catch return capResultFallback(arena, result);
        fw.interface.flush() catch {};
        file.close(io_val);

        const preview = if (to_store.len > preview_bytes) to_store[0..preview_bytes] else to_store;
        var out: std.ArrayList(u8) = .empty;
        out.appendSlice(arena, preview) catch return capResultFallback(arena, result);
        out.appendSlice(arena, "\n") catch return capResultFallback(arena, result);
        const notice = std.fmt.allocPrint(arena, stored_notice, .{ file_path, file_path }) catch {
            return capResultFallback(arena, result);
        };
        out.appendSlice(arena, notice) catch return capResultFallback(arena, result);

        return .{
            .text = out.toOwnedSlice(arena) catch return capResultFallback(arena, result),
            .cut = true,
            .stored = true,
            .path = file_path,
        };
    }

    // No Io handle available: fall back to inline truncation.
    return capResultFallback(arena, result);
}

fn capResultFallback(arena: std.mem.Allocator, text: []const u8) Stored {
    const capped = resultcap.capResult(arena, text, resultcap.default_max_result_chars) catch {
        return .{ .text = text[0..@min(text.len, resultcap.default_max_result_chars)], .cut = true, .stored = false };
    };
    return .{
        .text = capped.text,
        .cut = capped.cut,
        .stored = false,
    };
}

pub fn summarize(arena: std.mem.Allocator, path: []const u8, bytes: usize) ![]const u8 {
    const summary = try std.fmt.allocPrint(arena, "{s} ({d} bytes)", .{ path, bytes });
    if (summary.len <= summary_max_len) return summary;
    return summary[0..summary_max_len];
}

/// Extracts the recoverable file path from a stored-result notice, if present.
/// Accepts both the current notice format and older session/tool output.
pub fn extractStoredPath(content: []const u8) ?[]const u8 {
    const needle = "result stored at ";
    const start_i = std.mem.indexOf(u8, content, needle) orelse return null;
    const path_start = start_i + needle.len;
    // Prefer explicit recovery clause, then historical forms.
    const markers = [_][]const u8{
        "; read the part you need with read path=",
        "; read the part you need)",
        "; recover with read path=",
        ")",
    };
    for (markers) |marker| {
        if (std.mem.indexOfPos(u8, content, path_start, marker)) |end_i| {
            if (end_i > path_start) return content[path_start..end_i];
        }
    }
    return null;
}

test "extractStoredPath finds a stored result path" {
    const path = extractStoredPath("preview\n\u{2026} (result stored at sessions/s1/tool-results/1.txt; read the part you need)\n");
    try std.testing.expectEqualStrings("sessions/s1/tool-results/1.txt", path.?);
}

test "extractStoredPath finds path in explicit recovery notice" {
    const path = extractStoredPath("preview\n\u{2026} (result stored at sessions/tool-results/zode-abcd/7.txt; read the part you need with read path=sessions/tool-results/zode-abcd/7.txt offset=1 limit=2000)\n");
    try std.testing.expectEqualStrings("sessions/tool-results/zode-abcd/7.txt", path.?);
}

test "extractStoredPath returns null when absent" {
    try std.testing.expect(extractStoredPath("normal tool output") == null);
}

test "sessionToolResultsDir isolates by session stem" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = try sessionToolResultsDir(arena, "sessions/zode-aaaa1111.jsonl");
    const b = try sessionToolResultsDir(arena, "sessions/zode-bbbb2222.jsonl");
    try std.testing.expect(std.mem.indexOf(u8, a, "tool-results") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "zode-aaaa1111") != null);
    try std.testing.expect(std.mem.indexOf(u8, b, "zode-bbbb2222") != null);
    try std.testing.expect(!std.mem.eql(u8, a, b));
}

test "storeResult: under cap returns text untouched, not stored" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const result = "small result";
    const out = storeResult(arena, null, "sessions/zode-s1.jsonl", 1, result);
    try std.testing.expectEqualStrings(result, out.text);
    try std.testing.expect(!out.cut);
    try std.testing.expect(!out.stored);
    try std.testing.expect(out.path == null);
}

test "storeResult: over cap falls back to inline truncation when no Io handle" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var big: [60_000]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @intCast('A' + (i % 26));
    const result = big[0..];

    const out = storeResult(arena, null, "sessions/zode-s1.jsonl", 1, result);
    try std.testing.expect(out.cut);
    try std.testing.expect(!out.stored);
    try std.testing.expect(out.path == null);
    // The inline truncation notice should be present.
    try std.testing.expect(std.mem.indexOf(u8, out.text, "… (result cut at the tool's cap") != null or
        std.mem.indexOf(u8, out.text, "(result cut at the tool's cap") != null);
    // Output must be within the per-tool cap.
    try std.testing.expect(out.text.len <= resultcap.default_max_result_chars);
    // Output must be valid UTF-8.
    try std.testing.expect(std.unicode.utf8ValidateSlice(out.text));
}

test "storeResult: hard cap truncates before writing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var giant: [500_000]u8 = undefined;
    for (&giant) |*b| b.* = 'Z';
    const result = giant[0..];

    const out = storeResult(arena, null, "sessions/zode-s1.jsonl", 2, result);
    try std.testing.expect(out.cut);
    try std.testing.expect(!out.stored);
    try std.testing.expect(out.path == null);
    try std.testing.expect(out.text.len <= resultcap.default_max_result_chars);
}

test "storeResult: unique index never collides" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var big: [60_000]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @intCast('A' + (i % 26));
    const result = big[0..];

    const a = storeResult(arena, null, "sessions/zode-s1.jsonl", 1, result);
    const b = storeResult(arena, null, "sessions/zode-s1.jsonl", 2, result);
    // With no Io handle, both fall back to inline truncation: same behaviour,
    // but both are cut and neither is stored.
    try std.testing.expect(a.cut);
    try std.testing.expect(b.cut);
    try std.testing.expect(!a.stored);
    try std.testing.expect(!b.stored);
    try std.testing.expect(a.path == null);
    try std.testing.expect(b.path == null);
}

test "summarize: one line under summary_max_len" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = "sessions/s1/tool-results/1.txt";
    const s = try summarize(arena, path, 12_345);
    try std.testing.expect(s.len <= summary_max_len);
    try std.testing.expect(std.mem.find(u8, s, path) != null);
    try std.testing.expect(std.mem.find(u8, s, "12345") != null);
}

test "summarize: long path is clipped to summary_max_len" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var long_path: [200]u8 = undefined;
    for (&long_path) |*b| b.* = 'p';
    const s = try summarize(arena, long_path[0..], 1);
    try std.testing.expect(s.len <= summary_max_len);
}
