const std = @import("std");
const common = @import("common.zig");
const write_tool = @import("write.zig");
const notebook_mod = @import("notebook.zig");
const readcache = @import("../lib/readcache.zig");
const pathsafe = @import("../lib/pathsafe.zig");

/// Line numbers past this are not worth caching precisely. Nothing real gets
/// there, and the point of the cap is to keep the arithmetic in `usize` until the
/// very last step, not to be right about a 4-million-line generated file.
pub const read_line_cap: u32 = 1 << 22;

/// How many files one `paths` call may carry.
///
/// 8, and the number is about the CONTEXT not the I/O: 8 files of 2000 lines is
/// already most of a small model's window, and a call that answers "here are 40
/// files, 12 of them are truncated" is worse than two calls that each arrive
/// whole.
pub const max_paths = 8;

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
    // `paths` FIRST, because it changes the shape of everything else: one call
    // with N files is ONE round trip instead of N.
    //
    // It is not a convenience. Each round trip is a full model request, and on a
    // free tier (this account has `total_credits: 0`, measured 2026-10-04) each
    // one is also a chance to be 429'd and to spend 500ms + 1s + 2s of backoff
    // before it gives up. "Read these three files and compare them" is the single
    // most common shape of a real task and it was costing three requests where
    // one would do.
    if (obj.get("paths")) |pv| {
        if (pv != .array or pv.array.items.len == 0) {
            return "error: `paths` must be a non-empty array of file paths. Send `path` for a single file.";
        }
        if (pv.array.items.len > max_paths) {
            return std.fmt.allocPrint(
                arena,
                "error: {d} paths is over the cap of {d}. Read them in two calls — one call for the ones you want compared, one for the rest.",
                .{ pv.array.items.len, max_paths },
            );
        }
        // PDF page ranges are not supported for multi-file reads yet
        const pdf_page_start: usize = if (common.getInt(obj, "pdf_page_start")) |p| (if (p > 0) @intCast(p) else 1) else 0;
        const pdf_page_end: usize = if (common.getInt(obj, "pdf_page_end")) |p| (if (p > 0) @intCast(p) else 0) else 0;
        if (pdf_page_start > 0 or pdf_page_end > 0) {
            return "error: `pdf_page_start` and `pdf_page_end` are only supported for single-file reads with `path`.";
        }
        var out: std.ArrayList(u8) = .empty;
        // The header names every file and how big it is, so a model that reads
        // only the first two still knows what it did not read.
        try out.print(arena, "read {d} file(s):\n", .{pv.array.items.len});
        for (pv.array.items) |item| {
            const p = if (item == .string) item.string else return "error: `paths` must hold strings, not objects.";
            try out.print(arena, "\n--- {s} ---\n", .{p});
            // Each file goes through the SAME cache path, and a failure on one
            // does not lose the others: the model gets four files and one error,
            // not nothing.
            // The SAME function the single-file path uses, called directly with
            // the path. Building a synthetic `ObjectMap` per file was the first
            // version and it does not work: in Zig 0.16 `ObjectMap` is an
            // `ArrayHashMap` and needs an allocator to hold even one key.
            const one = readOne(io, p, 1, 2000, false, 0, 0, arena, cache) catch |err| {
                try out.appendSlice(arena, std.fmt.allocPrint(arena, "could not read: {t}", .{err}) catch "could not read");
                continue;
            };
            try out.appendSlice(arena, one);
        }
        return out.items;
    }

    const path = common.getStr(obj, "path") orelse return error.MissingPath;
    const offset: usize = if (common.getInt(obj, "offset")) |o| (if (o > 0) @intCast(o) else 1) else 1;
    const default_limit: usize = 2000;
    const limit: usize = if (common.getInt(obj, "limit")) |l| (if (l > 0) @intCast(l) else default_limit) else default_limit;
    // The escape hatch, and it is NOT optional. A cache that says "you already
    // have this" when it is wrong leaves the model with no way to get the file
    // back, and it cannot argue its way out of a tool result. One boolean in the
    // schema is cheaper than a turn lost.
    const force = common.getBool(obj, "force");
    // PDF page range support (1-indexed, inclusive)
    const pdf_page_start: usize = if (common.getInt(obj, "pdf_page_start")) |p| (if (p > 0) @intCast(p) else 0) else 0;
    const pdf_page_end: usize = if (common.getInt(obj, "pdf_page_end")) |p| (if (p > 0) @intCast(p) else 0) else 0;
    return readOne(io, path, offset, limit, force, pdf_page_start, pdf_page_end, arena, cache);
}

/// One file, with the cache. Split out so `paths` reuses it without building a
/// synthetic `ObjectMap` per file.
fn readOne(
    io: std.Io,
    path: []const u8,
    offset: usize,
    limit: usize,
    force: bool,
    pdf_page_start: usize,
    pdf_page_end: usize,
    arena: std.mem.Allocator,
    cache: ?*readcache.Cache,
) ![]const u8 {
    // A file whose CONTENT is a secret is not read.
    //
    // `read` never asks for permission (it is `read_only = true`), so this is
    // the ONLY place a refusal can happen: without it the model reads
    // `~/.ssh/id_rsa` or `~/.config/zode/auth.json` and sends the bytes to the
    // model provider, and the user sees nothing on screen at all.
    //
    // The list is short and unambiguous (a private key, a credentials file).
    // A `.env` inside the project is NOT in it: that is a project file the
    // user may well want the agent to look at, and a rule that blocks the
    // ordinary case is a rule that gets switched off.
    const secret = pathsafe.checkRead(path);
    if (secret != .ok) return pathsafe.refusalText(arena, secret);

    var dir = std.Io.Dir.cwd();

    // A NOTEBOOK is read as an outline, not as its JSON.
    //
    // The raw file is thousands of lines of escaped strings, and the one thing the
    // model needs from it — which index each cell is — is a position it would have to
    // count by hand. The outline prints those indices, the cell type, its size and its
    // first line, which is what a cell is identified by.
    //
    // It degrades rather than blocks: a `.ipynb` that does not parse is still a file
    // someone may want to look at, so the failure falls through to the ordinary read,
    // which is where the real error (no such file, not readable) is reported.
    if (std.mem.endsWith(u8, path, ".ipynb")) {
        if (notebook_mod.outline(io, path, arena)) |text| {
            return text;
        } else |_| {}
    }

    // PDF page range support
    if (std.mem.endsWith(u8, path, ".pdf") and (pdf_page_start > 0 or pdf_page_end > 0)) {
        return readPdfPages(io, path, pdf_page_start, pdf_page_end, arena);
    }

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

/// Read specific pages from a PDF file using pdftotext.
fn readPdfPages(
    io: std.Io,
    path: []const u8,
    page_start: usize,
    page_end: usize,
    arena: std.mem.Allocator,
) ![]const u8 {
    // Use pdftotext to extract text from PDF pages
    // pdftotext -f <first_page> -l <last_page> <pdf_file> -
    const end_page = if (page_end > 0) page_end else page_start;
    
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.heap.page_allocator);
    try argv.append(std.heap.page_allocator, "pdftotext");
    try argv.append(std.heap.page_allocator, "-f");
    try argv.append(std.heap.page_allocator, try std.fmt.allocPrint(std.heap.page_allocator, "{}", .{page_start}));
    try argv.append(std.heap.page_allocator, "-l");
    try argv.append(std.heap.page_allocator, try std.fmt.allocPrint(std.heap.page_allocator, "{}", .{end_page}));
    try argv.append(std.heap.page_allocator, path);
    try argv.append(std.heap.page_allocator, "-"); // output to stdout

    const result = std.process.run(arena, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(2048),
        .reserve_amount = 4096,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } },
    }) catch |err| {
        return std.fmt.allocPrint(arena,
            "{s}: could not read PDF (pdftotext not available or failed: {t}). Install poppler-utils to read PDFs.",
            .{ std.fs.path.basename(path), err }) catch "could not read PDF";
    };

    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => return std.fmt.allocPrint(arena,
            "{s}: pdftotext failed to run", .{ std.fs.path.basename(path) }) catch "pdftotext failed",
    };

    if (code != 0) {
        const err_msg = if (result.stderr.len > 0) result.stderr else "unknown error";
        return std.fmt.allocPrint(arena,
            "{s}: pdftotext exited with code {d}: {s}",
            .{ std.fs.path.basename(path), code, err_msg }) catch "pdftotext error";
    }

    if (result.stdout.len == 0) {
        return std.fmt.allocPrint(arena,
            "{s}: no text extracted from pages {d}-{d}",
            .{ std.fs.path.basename(path), page_start, end_page }) catch "no text extracted";
    }

    // Format the output with page markers
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "PDF: {s} (pages {d}-{d})\n\n", .{ std.fs.path.basename(path), page_start, end_page });
    try out.appendSlice(arena, result.stdout);
    return out.items;
}

/// Why a read failed, in words the model can act on.
///
/// It used to be `error reading {s}: {t}`, so the model received the literal
/// string `FileNotFound` — a Zig identifier that says nothing about what to do.
/// The three that actually happen here are a wrong path, a directory and a
/// permission, and each one has a different next step.
fn readError(arena: std.mem.Allocator, path: []const u8, err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => std.fmt.allocPrint(
            arena,
            "{s} does not exist. Check it with `glob` or `list_files` first: a path that is not there cannot be read, and guessing variants of it costs a round trip.",
            .{path},
        ) catch "the file does not exist",
        error.IsDir => std.fmt.allocPrint(
            arena,
            "{s} is a directory, not a file. Use `list_files` on it, or `read` a file inside it.",
            .{path},
        ) catch "that path is a directory",
        error.AccessDenied => std.fmt.allocPrint(
            arena,
            "{s} is there but this process cannot read it. It is probably outside the project or not yours.",
            .{path},
        ) catch "the file is not readable",
        else => std.fmt.allocPrint(arena, "could not read {s}: {t}", .{ path, err }) catch "could not read",
    };
}

pub fn readAll(arena: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    var dir = std.Io.Dir.cwd();
    return dir.readFileAlloc(io, path, arena, .limited(8 * 1024 * 1024)) catch |err| {
        return readError(arena, path, err);
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

// ─── tests ────────────────────────────────────────────────────────────

fn parseReadArgs(a: std.mem.Allocator, json: []const u8) !struct {
    path: ?[]const u8,
    offset: usize,
    limit: usize,
    force: bool,
    pdf_page_start: usize,
    pdf_page_end: usize,
} {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    const obj = v.object;
    const path = common.getStr(obj, "path");
    const offset: usize = if (common.getInt(obj, "offset")) |o| (if (o > 0) @intCast(o) else 1) else 1;
    const default_limit: usize = 2000;
    const limit: usize = if (common.getInt(obj, "limit")) |l| (if (l > 0) @intCast(l) else default_limit) else default_limit;
    const force = common.getBool(obj, "force");
    const pdf_page_start: usize = if (common.getInt(obj, "pdf_page_start")) |p| (if (p > 0) @intCast(p) else 0) else 0;
    const pdf_page_end: usize = if (common.getInt(obj, "pdf_page_end")) |p| (if (p > 0) @intCast(p) else 0) else 0;
    return .{ .path = path, .offset = offset, .limit = limit, .force = force, .pdf_page_start = pdf_page_start, .pdf_page_end = pdf_page_end };
}

test "read args: pdf_page_start and pdf_page_end are parsed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = try parseReadArgs(arena_state.allocator(), "{\"path\":\"doc.pdf\",\"pdf_page_start\":5,\"pdf_page_end\":10}");
    try std.testing.expectEqualStrings("doc.pdf", a.path.?);
    try std.testing.expectEqual(@as(usize, 5), a.pdf_page_start);
    try std.testing.expectEqual(@as(usize, 10), a.pdf_page_end);
}

test "read args: pdf_page_start alone defaults pdf_page_end to same" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = try parseReadArgs(arena_state.allocator(), "{\"path\":\"doc.pdf\",\"pdf_page_start\":3}");
    try std.testing.expectEqual(@as(usize, 3), a.pdf_page_start);
    try std.testing.expectEqual(@as(usize, 0), a.pdf_page_end);
}

test "read args: pdf_page_end alone is parsed (start defaults to 0)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = try parseReadArgs(arena_state.allocator(), "{\"path\":\"doc.pdf\",\"pdf_page_end\":7}");
    try std.testing.expectEqual(@as(usize, 0), a.pdf_page_start);
    try std.testing.expectEqual(@as(usize, 7), a.pdf_page_end);
}

test "read args: negative pdf_page_start is treated as 0" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = try parseReadArgs(arena_state.allocator(), "{\"path\":\"doc.pdf\",\"pdf_page_start\":-1}");
    try std.testing.expectEqual(@as(usize, 0), a.pdf_page_start);
}

test "read args: zero pdf_page_start is treated as 0" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = try parseReadArgs(arena_state.allocator(), "{\"path\":\"doc.pdf\",\"pdf_page_start\":0}");
    try std.testing.expectEqual(@as(usize, 0), a.pdf_page_start);
}
