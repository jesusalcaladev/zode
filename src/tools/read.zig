const std = @import("std");
const common = @import("common.zig");
const write_tool = @import("write.zig");
const readcache = @import("../lib/readcache.zig");

/// Line numbers past this are not worth caching precisely. Nothing real gets
/// there, and the point of the cap is to keep the arithmetic in `usize` until the
/// very last step, not to be right about a 4-million-line generated file.
pub const read_line_cap: u32 = 1 << 22;

/// `read`, with the cache.
///
/// The shape is: ask the cache with a `stat` first (cheap, no read at all), and
/// only read the bytes when it cannot answer. Three outcomes, and the order
/// matters because each one is cheaper and more certain than the next:
///
/// 1. same inode+mtime+size AND those lines were already sent → the content is
///    in the model's context, so say so in five lines instead of sending it;
/// 2. the cache has seen the file but the stat moved → read it and compare the
///    HASH, because a moved mtime does not mean changed content (`git checkout`,
///    `cp -p`) and an unchanged mtime does not mean unchanged content (same
///    second, same length);
/// 3. otherwise send the body as always.
pub fn toolRead(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator, cache: ?*readcache.Cache) ![]const u8 {
    const path = common.getStr(obj, "path") orelse return error.MissingPath;
    const offset: usize = if (common.getInt(obj, "offset")) |o| (if (o > 0) @intCast(o) else 1) else 1;
    const default_limit: usize = 2000;
    const limit: usize = if (common.getInt(obj, "limit")) |l| (if (l > 0) @intCast(l) else default_limit) else default_limit;
    // The escape hatch, and it is NOT optional. A cache that says "you already
    // have this" when it is wrong leaves the model with no way to get the file
    // back, and it cannot argue its way out of a tool result. One boolean in the
    // schema is cheaper than a turn lost.
    const force = common.getBool(obj, "force");

    var dir = std.Io.Dir.cwd();
    const first_line: u32 = @intCast(@min(offset, read_line_cap));
    const last_line: u32 = @intCast(@min(offset + limit, read_line_cap));

    if (cache) |c| {
        if (!force) {
            if (dir.statFile(io, path, .{})) |st| {
                switch (c.check(path, st, first_line, last_line)) {
                    .already_sent => |sent| return unchangedNote(arena, path, sent.lines),
                    .read_then_decide => |prev| {
                        const data = try readAll(arena, io, path);
                        const hash = readcache.hashBytes(data);
                        const lines: u32 = @intCast(@min(write_tool.lineCount(data), read_line_cap));
                        // Same bytes, different timestamp: the model DOES have
                        // these lines, they are the ones it read before, and only
                        // the stat is stale. So refresh it and answer short.
                        //
                        // `covers` is part of the condition and NOT an
                        // afterthought: the cache is per RANGE. Same content with
                        // a wider request ("I had read lines 1-2, now give me the
                        // whole file") has to send the whole file, and answering
                        // "unchanged" there is a lie about lines the model never
                        // got. The test that pins it is the read-cache one about
                        // a range that was never read.
                        if (prev.in_context and prev.hash == hash and c.coversRangeOf(path, first_line, last_line)) {
                            const saved: usize = @intCast(@min(data.len, readcache.max_saved));
                            c.confirmUnchanged(path, st, first_line, last_line, saved);
                            return unchangedNote(arena, path, lines);
                        }
                        const out = try formatBody(arena, path, data, offset, limit);
                        c.record(path, st, hash, first_line, last_line, lines);
                        return out;
                    },
                }
            } else |_| {
                // No `stat`: no fast path. The read below produces the real error,
                // which says more than a cache miss would.
            }
        }
    }

    const data = try readAll(arena, io, path);
    return formatBody(arena, path, data, offset, limit);
}

pub fn readAll(arena: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    var dir = std.Io.Dir.cwd();
    return dir.readFileAlloc(io, path, arena, .limited(8 * 1024 * 1024)) catch |err| {
        return std.fmt.allocPrint(arena, "error reading {s}: {t}", .{ path, err });
    };
}

/// The answer when the file is already in the context.
///
/// It says three things, and each one is there because of a specific way this
/// goes wrong without it: that the content is STILL THERE (so the model does not
/// re-read it out of anxiety), that it can get it back anyway (`force`), and what
/// it is being told NO rather than handed nothing.
pub fn unchangedNote(arena: std.mem.Allocator, path: []const u8, lines: u32) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\unchanged: {s} — {d} lines, byte-identical to the content already in your
        \\context, so it is not repeated here. It is still above you in this
        \\conversation: quote from it, or read it again with {{"force": true}} if you
        \\genuinely need the text again.
    , .{ path, lines });
}

/// The body, numbered, with the truncation notice.
///
/// `path` is only for the error string the caller may return; the body itself
/// says nothing about the file, because the header above it in the history
/// already says it.
pub fn formatBody(arena: std.mem.Allocator, path: []const u8, data: []const u8, offset: usize, limit: usize) ![]const u8 {
    _ = path;
    var out: std.ArrayList(u8) = .empty;
    var line_no: usize = 1;
    var lines_shown: usize = 0;
    var truncated = false;

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        defer line_no += 1;
        if (line_no < offset) continue;
        if (lines_shown >= limit) {
            truncated = true;
            break;
        }
        // Truncate huge (minified) lines to 2000 chars.
        const shown = line[0..@min(line.len, 2000)];
        out.print(arena, "{d: >6}| {s}\n", .{ line_no, shown }) catch break;
        lines_shown += 1;
    }
    if (truncated) {
        out.print(arena, "… (more lines; raise `offset` to {d} to continue)\n", .{line_no}) catch {};
    }
    if (out.items.len == 0) {
        out.appendSlice(arena, "(empty file)") catch {};
    }
    return out.items;
}
