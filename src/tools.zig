const std = @import("std");
const http = @import("http_client.zig");
const web = @import("web.zig");

pub const max_tool_output = 16 * 1024; // output budget per tool

pub const ToolDef = struct {
    name: []const u8,
    desc: []const u8,
};

pub const defs = [_]ToolDef{
    .{ .name = "read", .desc = "Read a file with line offsets and smart truncation" },
    .{ .name = "write", .desc = "Create or overwrite a file" },
    .{ .name = "edit", .desc = "Exact str_replace editing, single or multi-hunk" },
    .{ .name = "bash", .desc = "Run a shell command with timeout" },
    .{ .name = "glob", .desc = "Find files matching a glob pattern" },
    .{ .name = "grep", .desc = "Search file contents with regex" },
    .{ .name = "list_files", .desc = "List a directory (cheap structure overview)" },
    .{ .name = "web_fetch", .desc = "Fetch a URL and return it as readable text (HTML stripped)" },
    .{ .name = "web_search", .desc = "Search the web: titles, URLs and snippets" },
    .{ .name = "think", .desc = "Private scratchpad to reason before acting (no side effects)" },
};

/// Declares the tools to the LLM (OpenAI format). Static: 0 allocs per request.
pub fn toolsJson() []const u8 {
    return
    \\[
    \\{"type":"function","function":{"name":"read","description":"Read a file from disk. Optionally read a specific line range with offset/limit.","parameters":{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer","description":"1-indexed start line"},"limit":{"type":"integer"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"write","description":"Create or overwrite a file with the given content.","parameters":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}}},
    \\{"type":"function","function":{"name":"edit","description":"Exact string replacement in a file. Single hunk via old_string/new_string, or several at once via edits:[{old_string,new_string},...] (applied in order, all validated first). old_string must appear exactly once unless allow_multiple is true.","parameters":{"type":"object","properties":{"path":{"type":"string"},"old_string":{"type":"string"},"new_string":{"type":"string"},"edits":{"type":"array","items":{"type":"object","properties":{"old_string":{"type":"string"},"new_string":{"type":"string"}},"required":["old_string","new_string"]}},"allow_multiple":{"type":"boolean"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"bash","description":"Run a shell command and get combined stdout+stderr (truncated).","parameters":{"type":"object","properties":{"command":{"type":"string"},"timeout_seconds":{"type":"integer"}},"required":["command"]}}},
    \\{"type":"function","function":{"name":"glob","description":"Find files matching a glob pattern like src/**/*.zig.","parameters":{"type":"object","properties":{"pattern":{"type":"string"}},"required":["pattern"]}}},
    \\{"type":"function","function":{"name":"grep","description":"Search file contents with a regex. Returns path:line:text matches.","parameters":{"type":"object","properties":{"pattern":{"type":"string"},"subdir":{"type":"string"}},"required":["pattern"]}}},
    \\{"type":"function","function":{"name":"list_files","description":"List files and directories directly inside a path (non-recursive, cheap).","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"web_fetch","description":"Fetch an http(s) URL and return the content as readable text (HTML tags, scripts and styles are stripped, entities decoded). Use it to read documentation, a release page or any URL the user mentions. A non-2xx answer returns the status plus the body, so you can see what the site said. Truncated to a byte budget; ask for a deeper offset if the text is cut.","parameters":{"type":"object","properties":{"url":{"type":"string"},"max_bytes":{"type":"integer","description":"bytes of text to keep (default 16000, max 200000)"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"web_search","description":"Search the web and get titles, URLs and snippets. Use it when you need something you do not know yet (docs, versions, error messages), then web_fetch the promising URLs.","parameters":{"type":"object","properties":{"query":{"type":"string"},"max_results":{"type":"integer","description":"1..20, default 8"}},"required":["query"]}}},
    \\{"type":"function","function":{"name":"think","description":"Think privately step by step before acting. Use for planning and complex reasoning. No side effects.","parameters":{"type":"object","properties":{"thought":{"type":"string"}},"required":["thought"]}}}
    \\]
    ;
}

/// Does this tool need to ask the user before running it?
///
/// `web_fetch` and `web_search` do NOT ask: they are reads, they write nothing, and
/// a dialog for every internet query turns the agent loop into an interrogation.
/// Same criterion as `read` or `grep`.
pub fn needsPermission(name: []const u8) bool {
    return !(std.mem.eql(u8, name, "read") or
        std.mem.eql(u8, name, "glob") or
        std.mem.eql(u8, name, "grep") or
        std.mem.eql(u8, name, "list_files") or
        std.mem.eql(u8, name, "web_fetch") or
        std.mem.eql(u8, name, "web_search") or
        std.mem.eql(u8, name, "think"));
}

/// Runs a tool with JSON args. Returns the (truncated) result —
/// `arena` memory, valid until the arena is freed.
pub fn execute(io: std.Io, name: []const u8, args_json: []const u8, arena: std.mem.Allocator) ![]const u8 {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{});
    if (parsed != .object) return error.BadArgs;
    const obj = parsed.object;

    if (std.mem.eql(u8, name, "read")) {
        return toolRead(io, obj, arena);
    } else if (std.mem.eql(u8, name, "write")) {
        return toolWrite(io, obj, arena);
    } else if (std.mem.eql(u8, name, "edit")) {
        return toolEdit(io, obj, arena);
    } else if (std.mem.eql(u8, name, "bash")) {
        return toolBash(io, obj, arena);
    } else if (std.mem.eql(u8, name, "glob")) {
        return toolGlob(io, obj, arena);
    } else if (std.mem.eql(u8, name, "grep")) {
        return toolGrep(io, obj, arena);
    } else if (std.mem.eql(u8, name, "list_files")) {
        return toolListFiles(io, obj, arena);
    } else if (std.mem.eql(u8, name, "web_fetch")) {
        return toolWebFetch(io, obj, arena);
    } else if (std.mem.eql(u8, name, "web_search")) {
        return toolWebSearch(io, obj, arena);
    } else if (std.mem.eql(u8, name, "think")) {
        return toolThink(obj, arena);
    }
    return error.UnknownTool;
}

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn getInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    if (v != .integer) return null;
    return v.integer;
}

// ── read ─────────────────────────────────────────────────────
fn toolRead(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const path = getStr(obj, "path") orelse return error.MissingPath;
    const offset: usize = if (getInt(obj, "offset")) |o| (if (o > 0) @intCast(o) else 1) else 1;
    const default_limit: usize = 2000;
    const limit: usize = if (getInt(obj, "limit")) |l| (if (l > 0) @intCast(l) else default_limit) else default_limit;

    var dir = std.Io.Dir.cwd();
    const data = dir.readFileAlloc(io, path, arena, .limited(8 * 1024 * 1024)) catch |err| {
        return std.fmt.allocPrint(arena, "error reading {s}: {t}", .{ path, err });
    };

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
        out.print(arena, "{d: >6}│ {s}\n", .{ line_no, shown }) catch break;
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

// ── write ────────────────────────────────────────────────────
fn toolWrite(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const path = getStr(obj, "path") orelse return error.MissingPath;
    const content = getStr(obj, "content") orelse return error.MissingContent;

    var dir = std.Io.Dir.cwd();
    dir.writeFile(io, .{
        .sub_path = path,
        .data = content,
    }) catch |err| {
        return std.fmt.allocPrint(arena, "error writing {s}: {t}", .{ path, err });
    };
    // The result is NOT just "wrote X (N bytes)": it carries a PREVIEW of what
    // was written. A tool result that says only "ok" makes you open the file to
    // find out whether the model wrote what you asked for, and in an agent loop
    // that check is exactly the step you skip.
    //
    // The preview is part of the tool result (what the MODEL sees to decide
    // whether it worked), not a UI decoration, so it survives to the session
    // file and to `/resume`. It is capped so a 400-line file does not turn into
    // 400 lines of tool result (which would then be elided by the compaction
    // tier and cost a whole extra request).
    var out: std.ArrayList(u8) = .empty;
    // A file ending in `\n` has N lines, not N+1: counting the newline as a
    // separator would report one more line than there is (and the "N more
    // lines" below would be off by one too). Same rule as `splitLines`.
    const total = lineCount(content);
    out.appendSlice(arena, try std.fmt.allocPrint(
        arena,
        "wrote {s} ({d} bytes, {d} lines)",
        .{ path, content.len, total },
    )) catch return std.fmt.allocPrint(arena, "wrote {s}", .{path});

    const max_preview = 12;
    out.appendSlice(arena, "\n--- preview ---") catch return out.items;
    var lines = std.mem.splitScalar(u8, content, '\n');
    var shown: usize = 0;
    while (lines.next()) |l| {
        if (shown >= max_preview) break;
        out.append(arena, '\n') catch return out.items;
        out.appendSlice(arena, l) catch return out.items;
        shown += 1;
    }
    if (total > shown) {
        out.appendSlice(arena, try std.fmt.allocPrint(
            arena,
            "\n\u{2026} {d} more lines",
            .{total - shown},
        )) catch {};
    }
    return out.items;
}

/// Lines in `text`, ignoring the final newline: "a\nb\n" is 2 lines, not 3.
///
/// `std.mem.splitScalar` would report the empty string after the last `\n` as a
/// line, and every count derived from it (the header, the "N more lines") would
/// be one too high.
fn lineCount(text: []const u8) usize {
    if (text.len == 0) return 0;
    const n = std.mem.count(u8, text, "\n");
    return if (std.mem.endsWith(u8, text, "\n")) n else n + 1;
}

// ── edit: single hunk (compat) or multi-hunk via `edits: [...]` ─
fn toolEdit(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const path = getStr(obj, "path") orelse return error.MissingPath;

    // Collect hunks: `edits: [{old_string,new_string},...]` or a single pair.
    var hunks: std.ArrayList(Hunk) = .empty;
    if (obj.get("edits")) |edits_v| {
        if (edits_v != .array or edits_v.array.items.len == 0) return error.BadArgs;
        for (edits_v.array.items) |ev| {
            if (ev != .object) return error.BadArgs;
            const old_s = getStr(ev.object, "old_string") orelse return error.MissingOldString;
            const new_s = getStr(ev.object, "new_string") orelse return error.MissingNewString;
            try hunks.append(arena, .{ .old = old_s, .new = new_s });
        }
    } else {
        const old_s = getStr(obj, "old_string") orelse return error.MissingOldString;
        const new_s = getStr(obj, "new_string") orelse return error.MissingNewString;
        const allow_multiple = if (obj.get("allow_multiple")) |v| (v == .bool and v.bool) else false;
        try hunks.append(arena, .{ .old = old_s, .new = new_s, .allow_multiple = allow_multiple });
    }

    if (hunks.items.len > max_hunks) return error.TooManyHunks;

    var dir = std.Io.Dir.cwd();
    const data = try dir.readFileAlloc(io, path, arena, .limited(32 * 1024 * 1024));

    // Validate every hunk against the ORIGINAL text (transaction).
    for (hunks.items) |*h| {
        if (h.old.len == 0) return std.fmt.allocPrint(arena, "error: empty old_string (use write for new files)", .{});
        var count: usize = 0;
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, data, pos, h.old)) |idx| {
            count += 1;
            pos = idx + h.old.len;
            if (count > 1 and !h.allow_multiple) break;
        }
        if (count == 0) {
            return std.fmt.allocPrint(arena, "error: old_string not found in {s}: \"{s}\"", .{ path, h.old[0..@min(h.old.len, 80)] });
        }
        if (count > 1 and !h.allow_multiple) {
            return std.fmt.allocPrint(arena, "error: old_string appears {d} times in {s}; be more specific or use allow_multiple", .{ count, path });
        }
        h.occurrences = count;
    }

    // Apply in order (the output of one hunk is the input of the next).
    var out: []const u8 = data;
    var total: usize = 0;
    for (hunks.items) |h| {
        out = try allocReplace(arena, out, h.old, h.new);
        total += if (h.allow_multiple) h.occurrences else 1;
    }

    var f = try dir.createFile(io, path, .{ .truncate = true });
    {
        var buf: [4096]u8 = undefined;
        var w = f.writer(io, &buf);
        try w.interface.writeAll(out);
        try w.interface.flush();
        f.close(io);
    }
    return std.fmt.allocPrint(arena, "edited {s}: {d} hunk(s), {d} replacement(s)", .{ path, hunks.items.len, total });
}

const max_hunks = 16;

const Hunk = struct {
    old: []const u8,
    new: []const u8,
    allow_multiple: bool = false,
    occurrences: usize = 0,
};

fn allocReplace(a: std.mem.Allocator, data: []const u8, old: []const u8, new: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, data, pos, old)) |idx| {
        try out.appendSlice(a, data[pos..idx]);
        try out.appendSlice(a, new);
        pos = idx + old.len;
    }
    try out.appendSlice(a, data[pos..]);
    return out.items;
}

// ── bash ─────────────────────────────────────────────────────
fn toolBash(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const command = getStr(obj, "command") orelse return error.MissingCommand;
    const timeout_s: u64 = if (getInt(obj, "timeout_seconds")) |t| (if (t > 0) @intCast(t) else 30) else 30;

    const argv = [_][]const u8{ "/bin/sh", "-c", command };
    const result = std.process.run(arena, io, .{
        .argv = &argv,
        .stdout_limit = .limited(max_tool_output),
        .stderr_limit = .limited(max_tool_output),
        .reserve_amount = 4096,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(@intCast(timeout_s)), .clock = .awake } },
    }) catch |err| {
        return std.fmt.allocPrint(arena, "error running: {t}", .{err});
    };

    var out: std.ArrayList(u8) = .empty;
    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        .signal => |sig| blk: {
            out.print(arena, "(señal {d}) ", .{sig}) catch {};
            break :blk @as(u8, @truncate(128 + @intFromEnum(sig)));
        },
        else => 255,
    };
    try out.print(arena, "exit={d}\n", .{exit_code});
    if (result.stdout.len > 0) {
        try out.appendSlice(arena, "--- stdout ---\n");
        try out.appendSlice(arena, result.stdout[0..@min(result.stdout.len, max_tool_output)]);
        try out.appendSlice(arena, "\n");
    }
    if (result.stderr.len > 0) {
        try out.appendSlice(arena, "--- stderr ---\n");
        try out.appendSlice(arena, result.stderr[0..@min(result.stderr.len, max_tool_output)]);
        try out.appendSlice(arena, "\n");
    }
    return out.items;
}

// ── glob ─────────────────────────────────────────────────────
fn toolGlob(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const pattern = getStr(obj, "pattern") orelse return error.MissingPattern;

    var out: std.ArrayList(u8) = .empty;
    var count: usize = 0;
    const max_results = 200;

    var walker = try walkZig(io, arena, ".");
    defer walker.deinit();

    while (walker.next()) |entry_path| {
        defer arena.free(entry_path);
        if (count >= max_results) {
            out.appendSlice(arena, "… (more results omitted)\n") catch {};
            break;
        }
        if (globMatch(pattern, entry_path)) {
            out.print(arena, "{s}\n", .{entry_path}) catch {};
            count += 1;
        }
    }
    if (count == 0) return std.fmt.allocPrint(arena, "no matches: {s}", .{pattern});
    return out.items;
}

// ── grep: native rg > native grep > internal fallback ────────
fn toolGrep(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const pattern = getStr(obj, "pattern") orelse return error.MissingPattern;
    const subdir = getStr(obj, "subdir") orelse ".";

    // 1) ripgrep (the best: fast, respects .gitignore)
    const rg_argv = [_][]const u8{ "rg", "--no-heading", "-n", "--max-count", "5", "--max-columns", "300", pattern, subdir };
    if (nativeGrep(arena, io, &rg_argv)) |out| return out;

    // 2) the system's grep -rn
    const grep_argv = [_][]const u8{ "grep", "-rn", "--include=*", "-m", "5", pattern, subdir };
    if (nativeGrep(arena, io, &grep_argv)) |out| return out;

    // 3) fallback: internal regex engine
    return fallbackGrep(io, pattern, subdir, arena);
}

/// Runs a native grep binary; null if the binary does not exist.
fn nativeGrep(arena: std.mem.Allocator, io: std.Io, argv: []const []const u8) ?[]const u8 {
    const result = std.process.run(arena, io, .{
        .argv = argv,
        .stdout_limit = .limited(max_tool_output),
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

fn truncateLines(arena: std.mem.Allocator, data: []const u8, max_lines: usize) []const u8 {
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
fn fallbackGrep(io: std.Io, pattern: []const u8, subdir: []const u8, arena: std.mem.Allocator) ![]const u8 {
    const regex = @import("regex.zig").Regex.compile(pattern);

    var out: std.ArrayList(u8) = .empty;
    var matches: usize = 0;
    const max_matches = 150;

    var walker = try walkZig(io, arena, subdir);
    defer walker.deinit();

    while (walker.next()) |entry_path| {
        defer arena.free(entry_path);
        if (matches >= max_matches) {
            out.appendSlice(arena, "… (more matches omitted)\n") catch {};
            break;
        }
        if (!looksLikeText(entry_path)) continue;
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

// ── list_files: plain directory listing (cheap) ──────────────
fn toolListFiles(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const path = getStr(obj, "path") orelse ".";
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        return std.fmt.allocPrint(arena, "error opening {s}: {t}", .{ path, err });
    };
    defer dir.close(io);

    var out: std.ArrayList(u8) = .empty;
    var count: usize = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.name.len > 0 and e.name[0] == '.') continue; // hidden
        const tag: []const u8 = switch (e.kind) {
            .directory => "d",
            .file => "f",
            else => "?",
        };
        out.print(arena, "{s} {s}\n", .{ tag, e.name }) catch {};
        count += 1;
        if (count >= 500) {
            out.appendSlice(arena, "… (truncated)\n") catch {};
            break;
        }
    }
    if (count == 0) return std.fmt.allocPrint(arena, "(empty) {s}", .{path});
    return out.items;
}

// ── web: read the internet (no permissions: reads only) ──────

/// Hard cap on a web response. 200 KB of text is plenty to read a doc and
/// keeps an endless page (a listing of 50 000 links) from blowing up the turn's
/// context.
const web_hard_cap = 200 * 1024;

fn browserHeaders() [3]http.Http.ExtraHeader {
    return .{
        .{ .name = "user-agent", .value = web.user_agent },
        .{ .name = "accept", .value = "text/html,application/json,text/plain;q=0.9,*/*;q=0.8" },
        // CAREFUL: you cannot leave `accept-encoding` out and trust things. `std.http`
        // sets `accept_encoding = .omit` (meaning "don't send the header"), and without
        // it GitHub and friends reply gzip: the model eats 16 KB of unreadable bytes
        // and has no idea what the page says. We ask for `identity`
        // explicitly, which is the only way to say "uncompressed" with
        // std, which does not decompress transparently.
        .{ .name = "accept-encoding", .value = "identity" },
    };
}

/// Did the body come compressed? (zstd, gzip, brotli…)
///
/// Safety net for when a server ignores `accept-encoding: identity`:
/// a message saying "it came compressed" is infinitely better than 16 KB of
/// binary that the model reads as text.
fn looksCompressed(body: []const u8) ?[]const u8 {
    if (body.len < 2) return null;
    // gzip 1f 8b, zstd 28 b5 2f fd, brotli (no fixed magic: many sites serve it
    // without a recognizable header, and it is detected by invalid UTF-8 below).
    if (body[0] == 0x1f and body[1] == 0x8b) return "gzip";
    if (body[0] == 0x28 and body[1] == 0xb5 and body.len >= 4 and body[2] == 0x2f and body[3] == 0xfd) return "zstd";
    // Generic binary: many NULs or stray control bytes.
    var ctrl: usize = 0;
    const probe = body[0..@min(body.len, 512)];
    for (probe) |b| {
        if (b < 0x09 or (b > 0x0d and b < 0x20)) ctrl += 1;
    }
    if (probe.len > 32 and ctrl * 4 > probe.len) return "binary";
    return null;
}

/// `web_fetch`: GET a URL and return the content as readable text.
///
/// The body ALWAYS goes through `web.htmlToText` when it looks like HTML, because
/// spending context on 300 KB of tags is throwing it away. JSON or plain text
/// pass through untouched.
fn toolWebFetch(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const url = getStr(obj, "url") orelse
        return "error: web_fetch needs a `url` (http:// or https://)";
    const trimmed = std.mem.trim(u8, url, " \t\r\n");
    if (!isHttpUrl(trimmed)) {
        return std.fmt.allocPrint(arena, "error: only http:// and https:// URLs can be fetched, got: {s}", .{trimmed});
    }

    var max_bytes: usize = max_tool_output;
    if (getInt(obj, "max_bytes")) |mb| {
        if (mb > 0) max_bytes = @min(@as(usize, @intCast(mb)), web_hard_cap);
    }

    var h = http.Http.init(arena, io);
    defer h.deinit();

    const res = h.getWithHeaders(trimmed, &browserHeaders()) catch |err| {
        return std.fmt.allocPrint(arena, "error fetching {s}: {t}", .{ trimmed, err });
    };
    defer h.freeBody(res.body);

    const body = res.body;
    // A compressed body is not text: saying so is infinitely better than
    // returning binary and letting the model read it as if it were words.
    if (looksCompressed(body)) |kind| {
        return std.fmt.allocPrint(arena, "{s} answered with {s}-encoded content that zode cannot decode. Try a different URL (a .json or .txt endpoint usually works).", .{ trimmed, kind });
    }
    // A 4xx/5xx is information too: return the status and whatever the
    // server said, which is where the real reason is ("Model access is disabled").
    if (res.status < 200 or res.status >= 300) {
        return std.fmt.allocPrint(arena, "HTTP {d} {s}\n{s}", .{
            res.status,
            trimmed,
            body[0..@min(body.len, 2000)],
        });
    }

    const is_html = looksLikeHtml(body);
    const text = if (is_html) web.htmlToText(arena, body) else body;

    if (text.len == 0) return "(empty body)";

    // CAREFUL: the result is COPIED into memory owned by the arena. Returning a slice
    // of the HTTP buffer is a time bomb: the `defer freeBody` above
    // releases it when this function returns, and the ArenaAllocator REUSES
    // that memory in the next allocation (the one from `client.deinit`'s pool, the
    // buffer's own growth…). The caller read `0xAA` where the JSON
    // should have been. It goes through the truncation and the short path, and only with
    // an arena: that is why it never showed up in the network tests.
    var out: std.ArrayList(u8) = .empty;
    if (text.len <= max_bytes) {
        out.appendSlice(arena, text) catch return "out of memory building the answer";
    } else {
        // Cut at a line boundary: cutting in the middle of a word leaves
        // garbage that the model keeps thinking is the end of the
        // document.
        var cut = max_bytes;
        while (cut > 0 and text[cut] != '\n') cut -= 1;
        if (cut < max_bytes / 2) cut = max_bytes; // page with no line breaks: hard cut
        out.appendSlice(arena, text[0..cut]) catch return "out of memory building the answer";
        out.print(arena, "\n\n… (truncated at {d} of {d} bytes; ask for the rest with a deeper request)", .{ cut, text.len }) catch {};
    }
    return out.items;
}

/// `web_search`: DuckDuckGo results (`html/` endpoint, no API key).
///
/// It is a scrape, and it will break the day they change one of the HTML classes.
/// When that happens, the error says so (with the alternative) instead of returning an
/// empty list, which the model would interpret as "there are no results".
fn toolWebSearch(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const query = getStr(obj, "query") orelse
        return "error: web_search needs a `query`";
    const q = std.mem.trim(u8, query, " \t\r\n");
    if (q.len == 0) return "error: empty query";

    var max_results: usize = 8;
    if (getInt(obj, "max_results")) |mr| {
        if (mr > 0) max_results = @min(@as(usize, @intCast(mr)), 20);
    }

    // DDG's `html/` endpoint is the one that asks for neither JS nor a key. The query goes
    // percent-encoded with `std.Uri`'s encoder (by hand people forget the `&` and
    // the `+`, and the search reaches the server in pieces).
    var url_buf: [1024]u8 = undefined;
    var uw: std.Io.Writer = .fixed(&url_buf);
    uw.writeAll("https://html.duckduckgo.com/html/?q=") catch return "error: query too long";
    // CAREFUL: `std.Uri.Writer` is NOT `pub` in 0.16, so the query component
    // encoder cannot be used from here. We percent-encode by
    // hand, which for a query is four characters.
    percentEncodeQuery(q, &uw) catch return "error: query too long";
    const url = uw.buffered();

    var h = http.Http.init(arena, io);
    defer h.deinit();

    const res = h.getWithHeaders(url, &browserHeaders()) catch |err| {
        return std.fmt.allocPrint(arena, "error searching \"{s}\": {t}", .{ q, err });
    };
    defer h.freeBody(res.body);

    if (res.status < 200 or res.status >= 300) {
        return std.fmt.allocPrint(arena, "HTTP {d} from the search engine for \"{s}\"", .{ res.status, q });
    }

    const results = web.searchResults(arena, res.body, max_results);
    if (results.len == 0) {
        return std.fmt.allocPrint(arena, "no results parsed for \"{s}\" (the search engine changed its HTML; try web_fetch on the page directly, or rephrase)", .{q});
    }
    return results;
}

/// Percent-encoding of a query string, by hand.
///
/// `std.Uri.Writer` (which does know how) is not `pub` in 0.16, and `std.Uri`
/// only exposes the encoder internally. There are four reserved characters and it is one
/// line; what matters is that `&` and `+` are accounted for: without them, "zod & mcp"
/// reaches the server as two different searches.
fn percentEncodeQuery(raw: []const u8, w: *std.Io.Writer) !void {
    for (raw) |c| {
        const safe = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~';
        if (safe) {
            try w.writeByte(c);
        } else if (c == ' ') {
            try w.writeByte('+');
        } else {
            try w.print("%{X:0>2}", .{c});
        }
    }
}

fn isHttpUrl(url: []const u8) bool {
    if (std.mem.startsWith(u8, url, "http://")) return true;
    if (std.mem.startsWith(u8, url, "https://")) return true;
    return false;
}

/// Is the body HTML?
///
/// It is deduced from the body and NOT from `content-type`: that header lives in
/// `receiveHead`'s redirect buffer, which dies when the request returns (see the note in
/// `http_client.JsonResult`). A server can also send `text/plain` with
/// HTML inside, or the other way round, so the header was not to be trusted either.
///
/// It looks at the start of the document for `<!doctype html`, `<html`, `<head` or
/// `<body`, which is where any template puts them, and rejects what starts
/// with `{` or `[` (JSON) or with `#!` (a gist's shebang).
fn looksLikeHtml(body: []const u8) bool {
    const head = body[0..@min(body.len, 1024)];
    if (head.len == 0) return false;
    if (head[0] == '{' or head[0] == '[') return false;
    const trimmed = std.mem.trimStart(u8, head, " \t\r\n\u{feff}");
    if (std.mem.startsWith(u8, trimmed, "#!")) return false;
    return std.ascii.indexOfIgnoreCase(trimmed, "<!doctype html") != null or
        std.ascii.indexOfIgnoreCase(trimmed, "<html") != null or
        std.ascii.indexOfIgnoreCase(trimmed, "<head") != null or
        std.ascii.indexOfIgnoreCase(trimmed, "<body") != null;
}

// ── think: scratchpad with no side effects (planning) ────────
fn toolThink(obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const thought = getStr(obj, "thought") orelse return error.MissingPath;
    return std.fmt.allocPrint(arena, "noted ({d} chars). Continue with your plan.", .{thought.len});
}

fn looksLikeText(path: []const u8) bool {
    const skip_dirs = [_][]const u8{ ".zig-cache/", "zig-out/", ".git/", "node_modules/" };
    for (skip_dirs) |d| {
        if (std.mem.indexOf(u8, path, d) != null) return false;
    }
    return true;
}

// ── recursive walker skipping binary/vendored dirs ───────────
const Walker = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    stack: std.ArrayList([]const u8),
    current_dir: ?std.Io.Dir = null,
    current_iter: ?std.Io.Dir.Iterator = null,
    current_base: []const u8 = "",

    fn deinit(self: *Walker) void {
        for (self.stack.items) |p| self.arena.free(p);
        self.stack.deinit(self.arena);
    }

    /// Returns the path of the next file (caller frees with arena.free)
    fn next(self: *Walker) ?[]const u8 {
        while (true) {
            if (self.current_dir == null) {
                const next_dir = self.stack.pop() orelse return null;
                self.current_base = next_dir;
                self.current_dir = std.Io.Dir.cwd().openDir(self.io, next_dir, .{ .iterate = true }) catch {
                    self.arena.free(next_dir);
                    continue;
                };
                self.current_iter = self.current_dir.?.iterate();
                continue;
            }
            // Next entry of the current dir
            const entry = self.current_iter.?.next(self.io) catch null;
            if (entry) |e| {
                const full = if (std.mem.eql(u8, self.current_base, "."))
                    (self.arena.dupe(u8, e.name) catch continue)
                else
                    (std.fmt.allocPrint(self.arena, "{s}/{s}", .{ self.current_base, e.name }) catch continue);
                switch (e.kind) {
                    .directory => {
                        if (isSkippable(e.name)) {
                            self.arena.free(full);
                            continue;
                        }
                        self.stack.append(self.arena, full) catch self.arena.free(full);
                    },
                    .file => return full,
                    else => {
                        self.arena.free(full);
                        continue;
                    },
                }
            } else {
                // Dir exhausted
                if (self.current_base.len > 0) self.arena.free(self.current_base);
                self.current_dir.?.close(self.io);
                self.current_dir = null;
                self.current_iter = null;
            }
        }
    }

    fn isSkippable(name: []const u8) bool {
        const skip = [_][]const u8{ ".git", "node_modules", ".zig-cache", "zig-out", ".cache", "target", "dist", "build" };
        for (skip) |s| {
            if (std.mem.eql(u8, name, s)) return true;
        }
        return name.len > 0 and name[0] == '.';
    }
};

fn walkZig(io: std.Io, arena: std.mem.Allocator, root: []const u8) !Walker {
    var w = Walker{
        .io = io,
        .arena = arena,
        .stack = .empty,
    };
    const root_copy = try arena.dupe(u8, root);
    try w.stack.append(arena, root_copy);
    return w;
}

// ── recursive glob matcher ( *, **, ? ) ──────────────────────
fn globMatch(pattern: []const u8, path: []const u8) bool {
    return globHere(pattern, path);
}

fn globHere(p: []const u8, s: []const u8) bool {
    if (p.len == 0) return s.len == 0;

    // '**' = anything, including '/'
    if (p.len >= 2 and p[0] == '*' and p[1] == '*') {
        var rest = p[2..];
        if (rest.len > 0 and rest[0] == '/') rest = rest[1..];
        // ** consumes 0 chars:
        if (globHere(rest, s)) return true;
        // ** consumes 1 char and keeps going:
        if (s.len > 0) return globHere(p, s[1..]);
        return false;
    }

    // '*' = anything except '/'
    if (p[0] == '*') {
        var i: usize = 0;
        while (i <= s.len) : (i += 1) {
            if (globHere(p[1..], s[i..])) return true;
            if (i < s.len and s[i] == '/') return false;
        }
        return false;
    }

    // '?' = one char (not '/')
    if (p[0] == '?') {
        if (s.len == 0 or s[0] == '/') return false;
        return globHere(p[1..], s[1..]);
    }

    if (s.len == 0 or p[0] != s[0]) return false;
    return globHere(p[1..], s[1..]);
}

// ── tests ────────────────────────────────────────────────────
test "glob matcher" {
    try std.testing.expect(globMatch("*.zig", "main.zig"));
    try std.testing.expect(globMatch("**/*.zig", "src/deep/x.zig"));
    try std.testing.expect(globMatch("src/*.zig", "src/main.zig"));
    try std.testing.expect(!globMatch("src/*.zig", "src/deep/x.zig"));
    try std.testing.expect(globMatch("a?c", "abc"));
    try std.testing.expect(globMatch("**", "x/y/z"));
}

test "needsPermission" {
    try std.testing.expect(!needsPermission("read"));
    try std.testing.expect(needsPermission("write"));
    try std.testing.expect(needsPermission("bash"));
}

test "list_files lista este src" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try execute(std.testing.io, "list_files", "{\"path\":\"src\"}", arena_state.allocator());
    try std.testing.expect(std.mem.indexOf(u8, out, "f main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "f tools.zig") != null);
}

test "think devuelve OK sin efectos" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try execute(std.testing.io, "think", "{\"thought\":\"plan: read file first\"}", arena_state.allocator());
    try std.testing.expect(std.mem.indexOf(u8, out, "noted") != null);
}

test "toolsJson es JSON válido y tiene una entrada por tool" {
    const arena = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena);
    defer arena_state.deinit();
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), toolsJson(), .{}) catch {
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(v == .array);
    // The count comes from `defs`, not from a hand-written number: adding a tool
    // without declaring it in the JSON (or the other way round) fails here instead of leaving
    // the model with a tool that does not exist.
    try std.testing.expectEqual(defs.len, v.array.items.len);
    for (v.array.items) |item| {
        const fname = item.object.get("function").?.object.get("name").?.string;
        var found = false;
        for (defs) |d| {
            if (std.mem.eql(u8, d.name, fname)) found = true;
        }
        try std.testing.expect(found);
    }
}

test "las tools de web no piden permiso (son lecturas)" {
    // Asking for confirmation on every internet query turns the agent loop into
    // an interrogation. Same criterion as read/grep.
    try std.testing.expect(!needsPermission("web_fetch"));
    try std.testing.expect(!needsPermission("web_search"));
    try std.testing.expect(needsPermission("write"));
}

test "web_fetch y web_search aparecen en el JSON con su descripción" {
    try std.testing.expect(std.mem.indexOf(u8, toolsJson(), "\"web_fetch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, toolsJson(), "\"web_search\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, toolsJson(), "html.duckduckgo.com") == null); // the endpoint lives in the code, not in the prompt
}

test "web_fetch rechaza lo que no es http(s) sin tocar la red" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try execute(std.testing.io, "web_fetch", "{\"url\":\"file:///etc/passwd\"}", arena_state.allocator());
    try std.testing.expect(std.mem.indexOf(u8, out, "only http:// and https://") != null);
}

test "web_fetch sin url lo dice" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try execute(std.testing.io, "web_fetch", "{}", arena_state.allocator());
    try std.testing.expect(std.mem.indexOf(u8, out, "needs a `url`") != null);
}

test "web_search sin query lo dice" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try execute(std.testing.io, "web_search", "{}", arena_state.allocator());
    try std.testing.expect(std.mem.indexOf(u8, out, "needs a `query`") != null);
}

test "percentEncodeQuery escapa lo que rompe una URL" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try percentEncodeQuery("zod & mcp/nuevo+1", &w);
    try std.testing.expectEqualStrings("zod+%26+mcp%2Fnuevo%2B1", w.buffered());
}

// ── network tests (skipped without internet) ─────────────────
//
// These are the only ones that can catch the most expensive class of bug in this
// file: returning a VIEW of the HTTP buffer instead of a copy. With an
// arena, `freeBody` (which sits in a `defer`) releases the memory when the tool
// returns and the ArenaAllocator reuses it in the next allocation; the
// caller read `0xAA` where the JSON should have been. There is no way to reproduce it
// without the network, and without the network the bug sneaks in.

/// `true` if the error is a network error (and the test is skipped) instead of a real failure.
fn isNetError(err: anyerror) bool {
    return switch (err) {
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.HostLackingDnsResolver,
        error.TemporaryNameServerFailure,
        error.NameServerFailure,
        error.UnknownHostName,
        error.ConnectionTimedOut,
        error.NetworkUnreachable,
        error.SocketNotConnected,
        => true,
        else => false,
    };
}

test "web_fetch real: el HTML llega como texto, no como etiquetas" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = execute(std.testing.io, "web_fetch", "{\"url\":\"https://example.com/\"}", arena_state.allocator()) catch |err| {
        if (isNetError(err)) return error.SkipZigTest;
        return err;
    };
    // CAREFUL: example.com changes its text every so often; the test checks the
    // SHAPE (no tags, sentences with spaces) and not the exact sentence. A
    // test that fails because a site changed its copy is worthless.
    try std.testing.expect(out.len > 40);
    // The readable text carries no tags: if the HTTP buffer had been
    // released, fill bytes (`0xAA`) would show up here instead of the sentence.
    try std.testing.expect(std.mem.indexOf(u8, out, "<html") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<div") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "documentation examples") != null);
}

test "web_search real: devuelve resultados con URL" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = execute(std.testing.io, "web_search", "{\"query\":\"zig programming language\",\"max_results\":3}", arena_state.allocator()) catch |err| {
        if (isNetError(err)) return error.SkipZigTest;
        return err;
    };
    // If the scraper changes, this fails and warns: that is exactly what it is for.
    try std.testing.expect(std.mem.indexOf(u8, out, "1. ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "http") != null);
}

// ── integration tests with testing.io ──
test "tool read lee este archivo" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const args = "{\"path\":\"src/tools.zig\"}";
    const out = try execute(std.testing.io, "read", args, arena_state.allocator());
    try std.testing.expect(std.mem.indexOf(u8, out, "toolRead") != null);
}

test "glob encuentra zigs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try execute(std.testing.io, "glob", "{\"pattern\":\"src/*.zig\"}", arena_state.allocator());
    try std.testing.expect(std.mem.indexOf(u8, out, "src/main.zig") != null);
}

test "grep nativo encuentra patrón" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = execute(std.testing.io, "grep", "{\"pattern\":\"toolGrep\",\"subdir\":\"src\"}", arena_state.allocator()) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest; // no rg/grep in PATH
        return err;
    };
    try std.testing.expect(std.mem.indexOf(u8, out, "toolGrep") != null);
}

test "write devuelve un PREVIEW del fichero, no un OK opaco" {
    // Un tool result que solo dice "ok" obliga a abrir el fichero para saber si
    // el modelo escribio lo que se le pidio, y en un bucle agéntico ese paso es
    // justo el que se salta uno.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(arena, "{\"path\":\"/tmp/opencode/preview-test.txt\",\"content\":\"");
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        try body.appendSlice(arena, try std.fmt.allocPrint(arena, "linea {d}\\n", .{i}));
    }
    try body.appendSlice(arena, "\"}");

    const out = try execute(std.testing.io, "write", body.items, arena);

    // La cabecera dice qué y cuánto.
    try std.testing.expect(std.mem.indexOf(u8, out, "preview-test.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "30 lines") != null);
    // Y viene el preview.
    try std.testing.expect(std.mem.indexOf(u8, out, "preview") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "linea 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "linea 11") != null);
    // Pero NO el fichero entero: se corta, y se dice cuántas líneas faltan.
    try std.testing.expect(std.mem.indexOf(u8, out, "linea 12\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "more lines") != null);
}
