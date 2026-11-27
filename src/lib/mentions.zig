const std = @import("std");
const images = @import("images.zig");
const fuzzy = @import("fuzzy.zig");
const filerange = @import("filerange.zig");

pub const max_files = 4;
pub const file_max = 32 * 1024;
pub const path_max = 200;
pub const scanned_max = 8;

pub const Mention = struct {
    path: [path_max]u8 = undefined,
    len: u8 = 0,
    /// Optional `:40-120` suffix. `pathOf` stays a real file path so existing
    /// callers (images, file watcher) keep working unchanged.
    range: ?filerange.Range = null,

    pub fn pathOf(self: *const Mention) []const u8 { return self.path[0..self.len]; }
};

pub const ScanResult = struct {
    mentions: [scanned_max]Mention,
    /// How many of `mentions` are valid (the rest are uninitialized).
    count: u8 = 0,
    just_at: bool,
};

pub fn scan(text: []const u8) !ScanResult {
    var mentions: [scanned_max]Mention = undefined;
    var just_at: bool = false;
    var n: u8 = 0;
    var i: usize = 0;

    while (i < text.len) {
        if (text[i] != '@') { i += 1; continue; }

        var is_bare_at: bool = false;
        const start = i + 1;
        if (start >= text.len) {
            // '@' at end of text: bare @
            is_bare_at = true;
        } else {
            const c = text[start];
            if (!std.ascii.isAlphanumeric(c) and c != '/' and c != '_' and c != '-' and c != '.') {
                // '@' followed by non-path char: bare @
                is_bare_at = true;
            } else if (i > 0) {
                // '@' not at start: check previous char isn't part of a word
                const prev = text[i - 1];
                if (std.ascii.isAlphanumeric(prev) or prev == '_' or prev == '@' or prev == '.' or prev == '/') {
                    i += 1; continue;
                }
            }
        }

        if (is_bare_at) {
            just_at = true;
            i += 1; continue;
        }

        var j = start;
        while (j < text.len) : (j += 1) {
            const c = text[j];
            if (std.ascii.isAlphanumeric(c) or c >= 0x80 or c == '_' or c == '/' or c == '-' or c == '.') continue;
            // A colon is part of a mention only when it introduces a line
            // number (`@src/a.zig:40-120`), never for a URL's `://`.
            if (c == ':' and j + 1 < text.len and std.ascii.isDigit(text[j + 1])) continue;
            break;
        }
        var end = j;
        while (end > start and (text[end - 1] == '.' or text[end - 1] == ',' or text[end - 1] == ':')) {
            end -= 1;
        }
        if (end <= start) { i += 1; continue; }
        if (end < text.len and text[end] == '@') { i = end + 1; continue; }
        const token = text[start..end];
        var path = token;
        var range: ?filerange.Range = null;
        if (std.mem.lastIndexOfScalar(u8, token, ':')) |colon| {
            if (filerange.parse(token[colon + 1 ..])) |spec| {
                const candidate = token[0..colon];
                if (looksLikePath(candidate)) {
                    path = candidate;
                    range = spec.asRange();
                }
            }
        }
        if (!looksLikePath(path)) { i = end; continue; }
        if (n >= scanned_max) { i = end; continue; }
        var dup = false;
        for (0..n) |prev| {
            const p = &mentions[prev];
            const same_range = if (p.range) |pr|
                if (range) |r| pr.first == r.first and pr.last == r.last else false
            else
                range == null;
            if (same_range and std.mem.eql(u8, p.pathOf(), path)) dup = true;
        }
        if (!dup) {
            if (token.len <= path_max) {
                mentions[n].len = @intCast(path.len);
                @memcpy(mentions[n].path[0..path.len], path);
                mentions[n].range = range;
                n += 1;
            }
        }
        i = end;
    }

    const result = ScanResult{ .mentions = mentions, .count = n, .just_at = just_at };
    return result;
}

fn looksLikePath(token: []const u8) bool {
    if (std.mem.indexOfScalar(u8, token, '/') != null) return true;
    const dot = std.mem.lastIndexOfScalar(u8, token, '.') orelse return false;
    return dot > 0 and dot + 1 < token.len;
}

pub const Expansion = struct {
    /// Owned by the caller-provided allocator (arena for the turn). The old
    /// version returned a slice of a 256-byte stack buffer, so every caller
    /// held a dangling pointer the moment `expand` returned.
    text: []const u8,
    files: u8,
    missing: u8,
};

pub const expansion_cap = 256 * 1024;
/// A selected range is capped harder than a whole-file mention: it is a
/// deliberate cursor into a file, not a dump of it.
pub const range_cap = 16 * 1024;

/// Emits only the selected lines, numbered with real 1-based line numbers.
/// The model can then refer to `path:line` without re-reading the whole file.
fn appendRange(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    path: []const u8,
    r: filerange.Range,
    content: []const u8,
) !void {
    var head_buf: [path_max + 96]u8 = undefined;
    const head = std.fmt.bufPrint(&head_buf, "[file: {s}, lines {d}-{d} of {d}]\n", .{
        path, r.first, r.last, filerange.lineCount(content),
    }) catch return;
    try out.appendSlice(alloc, head);

    var num_buf: [64]u8 = undefined;
    var it = std.mem.splitScalar(u8, content, '\n');
    var n: usize = 1;
    while (it.next()) |raw| : (n += 1) {
        if (n < r.first) continue;
        if (n > r.last) break;
        const line = std.mem.trimEnd(u8, raw, "\r");
        const prefix = std.fmt.bufPrint(&num_buf, "{d: >4} | ", .{n}) catch continue;
        if (out.items.len + prefix.len + line.len + 1 > expansion_cap or
            out.items.len + prefix.len + line.len + 1 > range_cap + head.len)
        {
            try out.appendSlice(alloc, "... [range truncated] ...\n");
            return;
        }
        try out.appendSlice(alloc, prefix);
        try out.appendSlice(alloc, line);
        try out.append(alloc, '\n');
    }
}

pub fn expand(alloc: std.mem.Allocator, io: std.Io, text: []const u8) !Expansion {
    const scan_result = try scan(text);

    var loaded_contents: std.ArrayList([]u8) = .empty;
    defer loaded_contents.deinit(alloc);
    var loaded_idx_for_mention: [128]u8 = undefined;
    // 255 = no content (missing or over cap). `scanned_max` is 8, so 128 is headroom.
    for (0..128) |i| loaded_idx_for_mention[i] = 255;
    var missing_count: u8 = 0;

    const max_to_load = @min(@as(usize, scan_result.count), @as(usize, max_files));
    for (0..max_to_load) |i| {
        const path = scan_result.mentions[i].pathOf();
        // An image mention is NOT inlined as bytes. The harness stages it as an
        // attachment (see `agent.stageImageMentions`); inlining 32 KB of a PNG here
        // produced binary garbage in the prompt and a 400 on some providers.
        if (images.mimeForPath(path) != null) continue;
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch {
            missing_count += 1;
            continue;
        };
        defer file.close(io);
        var buf = try alloc.alloc(u8, file_max);
        defer alloc.free(buf);
        const n = file.readPositionalAll(io, buf, 0) catch {
            missing_count += 1;
            continue;
        };
        const owned = try alloc.dupe(u8, buf[0..n]);
        const idx: u8 = @intCast(loaded_contents.items.len);
        try loaded_contents.append(alloc, owned);
        loaded_idx_for_mention[i] = idx;
    }
    defer for (loaded_contents.items) |c| alloc.free(c);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var li: usize = 0;
    var mention_idx: usize = 0;
    while (li < text.len) {
        if (mention_idx < scan_result.count) {
            const mention = &scan_result.mentions[mention_idx];
            const mention_path = mention.pathOf();
            var token_buf: [path_max + 64]u8 = undefined;
            const token: []const u8 = if (mention.range) |r|
                filerange.format(&token_buf, mention_path, r) catch mention_path
            else
                mention_path;
            if (li + token.len <= text.len and
                std.mem.eql(u8, text[li .. li + token.len], token))
            {
                if (mention_idx < loaded_idx_for_mention.len and
                    loaded_idx_for_mention[mention_idx] != 255)
                {
                    const content = loaded_contents.items[loaded_idx_for_mention[mention_idx]];
                    if (mention.range) |r| {
                        try appendRange(alloc, &out, mention_path, r, content);
                    } else if (out.items.len + content.len <= expansion_cap) {
                        try out.appendSlice(alloc, content);
                    } else {
                        const marker = "\n... [mention truncated] ...";
                        const room = expansion_cap -| out.items.len;
                        const content_room = room -| marker.len;
                        try out.appendSlice(alloc, content[0..@min(content_room, content.len)]);
                        try out.appendSlice(alloc, marker);
                    }
                }
                li += token.len;
                mention_idx += 1;
                continue;
            }
        }
        if (out.items.len < expansion_cap) try out.append(alloc, text[li]);
        li += 1;
    }

    var loaded_count: u8 = @intCast(loaded_contents.items.len);
    if (loaded_count > max_files) loaded_count = max_files;
    return Expansion{ .text = try out.toOwnedSlice(alloc), .files = loaded_count, .missing = missing_count };
}

// ── tests ─────────────────────────────────────────────────────

test "scan: finds the mentions in order" {
    const result = try scan("revisa @src/agent.zig y luego @src/tui.zig");
    try std.testing.expectEqual(@as(u8, 2), result.count);
    try std.testing.expectEqualStrings("src/agent.zig", result.mentions[0].pathOf());
    try std.testing.expectEqualStrings("src/tui.zig", result.mentions[1].pathOf());
    try std.testing.expect(result.just_at == false);
}

test "scan: an email address is NOT a mention" {
    const result = try scan("mándaselo a jorge@example.com");
    try std.testing.expectEqual(@as(u8, 0), result.count);
    try std.testing.expect(result.just_at == false);
}

test "scan: @ at start of text is bare @" {
    const result = try scan("@");
    try std.testing.expect(result.just_at == true);
    try std.testing.expectEqual(@as(u8, 0), result.count);
}

test "scan: @ followed by text is NOT bare @" {
    const result = try scan("@a.txt");
    try std.testing.expect(result.just_at == false);
    try std.testing.expectEqual(@as(u8, 1), result.count);
    try std.testing.expectEqualStrings("a.txt", result.mentions[0].pathOf());
}

test "scan: trailing punctuation does not eat the path" {
    const result = try scan("mira @notas.txt, y @docs/guía.md.");
    try std.testing.expectEqual(@as(u8, 2), result.count);
    try std.testing.expectEqualStrings("notas.txt", result.mentions[0].pathOf());
    try std.testing.expectEqualStrings("docs/guía.md", result.mentions[1].pathOf());
    try std.testing.expect(result.just_at == false);
}

test "scan: bare @ at end of text" {
    const result = try scan("hola @");
    try std.testing.expect(result.just_at == true);
    try std.testing.expectEqual(@as(u8, 0), result.count);
}

test "scan: decorators do NOT spend the budget" {
    const result = try scan("revisa esto @Override @deprecated @staticmethod @final @pure @param @import y mira @src/agent.zig");
    try std.testing.expectEqual(@as(u8, 1), result.count);
    try std.testing.expectEqualStrings("src/agent.zig", result.mentions[0].pathOf());
    try std.testing.expect(result.just_at == false);
}

test "looksLikePath: a path or an extension; a bare word is not" {
    try std.testing.expect(looksLikePath("src/agent.zig"));
    try std.testing.expect(looksLikePath("notas.txt"));
    try std.testing.expect(looksLikePath("a/b/c"));
    try std.testing.expect(looksLikePath("guía.md"));
    try std.testing.expect(!looksLikePath("Override"));
    try std.testing.expect(!looksLikePath("import"));
    try std.testing.expect(!looksLikePath("deprecated"));
    try std.testing.expect(!looksLikePath(".gitignore"));
    try std.testing.expect(!looksLikePath("Makefile"));
}

test "scan: does not repeat the same file" {
    const result = try scan("@a.txt y otra vez @a.txt y @b.txt");
    try std.testing.expectEqual(@as(u8, 2), result.count);
    try std.testing.expectEqualStrings("a.txt", result.mentions[0].pathOf());
    try std.testing.expectEqualStrings("b.txt", result.mentions[1].pathOf());
    try std.testing.expect(result.just_at == false);
}

test "scan: a mention inside parentheses or quotes counts too" {
    const result = try scan("(mira @src/a.zig) y \"@src/b.zig\"");
    try std.testing.expectEqual(@as(u8, 2), result.count);
    try std.testing.expect(result.just_at == false);
}

test "highlightMatch: contiguous substring wins over scattered" {
    var buf: [64]u32 = undefined;
    const n = fuzzy.highlightPositions("a-xbc", "bc", &buf).?;
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u32, 3), buf[0]);
    try std.testing.expectEqual(@as(u32, 4), buf[1]);
}

test "highlightMatch: prefix wins over substring" {
    var buf: [64]u32 = undefined;
    const n = fuzzy.highlightPositions("sonnet", "son", &buf).?;
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(u32, 0), buf[0]);
    try std.testing.expectEqual(@as(u32, 1), buf[1]);
    try std.testing.expectEqual(@as(u32, 2), buf[2]);
}

test "looksLikePath: an image filename is a mention path" {
    try std.testing.expect(looksLikePath("shot.png"));
    try std.testing.expect(looksLikePath("dir/photo.jpg"));
    try std.testing.expect(!looksLikePath("hello"));
}

test "scan: a line range keeps a real path and a separate range" {
    const result = try scan("mira @src/a.zig:40-120 y @b.txt:7");
    try std.testing.expectEqual(@as(u8, 2), result.count);
    try std.testing.expectEqualStrings("src/a.zig", result.mentions[0].pathOf());
    try std.testing.expectEqual(@as(usize, 40), result.mentions[0].range.?.first);
    try std.testing.expectEqual(@as(usize, 120), result.mentions[0].range.?.last);
    try std.testing.expectEqualStrings("b.txt", result.mentions[1].pathOf());
    try std.testing.expectEqual(@as(usize, 7), result.mentions[1].range.?.first);
    try std.testing.expectEqual(@as(usize, 7), result.mentions[1].range.?.last);
}

test "scan: a colon that is not a line number does not split the path" {
    const result = try scan("mira @http://example.com/x y @a.zig:12");
    try std.testing.expectEqual(@as(u8, 1), result.count);
    try std.testing.expectEqualStrings("a.zig", result.mentions[0].pathOf());
    try std.testing.expectEqual(@as(usize, 12), result.mentions[0].range.?.first);
}

test "scan: two ranges of the same file are both kept" {
    const result = try scan("@a.zig:1-5 y @a.zig:10-15");
    try std.testing.expectEqual(@as(u8, 2), result.count);
    try std.testing.expectEqual(@as(usize, 1), result.mentions[0].range.?.first);
    try std.testing.expectEqual(@as(usize, 10), result.mentions[1].range.?.first);
}

test "expand: a ranged mention inlines only the selected numbered lines" {
    const path = "zode-mentions-range-test.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    for (1..13) |n| try body.print(std.testing.allocator, "line {d}\n", .{n});
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = body.items });

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const expanded = try expand(arena_state.allocator(), std.testing.io, "revisa @" ++ path ++ ":3-5");
    try std.testing.expectEqual(@as(u8, 1), expanded.files);
    try std.testing.expect(std.mem.indexOf(u8, expanded.text, "lines 3-5 of 12") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded.text, "   3 | line 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded.text, "   5 | line 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded.text, "line 6") == null);
    try std.testing.expect(std.mem.indexOf(u8, expanded.text, "line 1\n") == null);
}
