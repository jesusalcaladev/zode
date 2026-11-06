const std = @import("std");
const fuzzy = @import("fuzzy.zig");

pub const max_files = 4;
pub const file_max = 32 * 1024;
pub const path_max = 200;
pub const scanned_max = 8;

pub const Mention = struct {
    path: [path_max]u8 = undefined,
    len: u8 = 0,
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
            break;
        }
        var end = j;
        while (end > start and (text[end - 1] == '.' or text[end - 1] == ',' or text[end - 1] == ':')) {
            end -= 1;
        }
        if (end <= start) { i += 1; continue; }
        if (end < text.len and text[end] == '@') { i = end + 1; continue; }
        const path = text[start..end];
        if (!looksLikePath(path)) { i = end; continue; }
        if (n >= scanned_max) { i = end; continue; }
        var dup = false;
        for (0..n) |prev| {
            if (std.mem.eql(u8, mentions[prev].path[0..mentions[prev].len], path)) dup = true;
        }
        if (!dup) {
            if (path.len <= path_max) {
                mentions[n].len = @intCast(path.len);
                @memcpy(mentions[n].path[0..path.len], path);
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
            const mention_path = scan_result.mentions[mention_idx].pathOf();
            if (li + mention_path.len <= text.len and
                std.mem.eql(u8, text[li .. li + mention_path.len], mention_path))
            {
                if (mention_idx < loaded_idx_for_mention.len and
                    loaded_idx_for_mention[mention_idx] != 255)
                {
                    const content = loaded_contents.items[loaded_idx_for_mention[mention_idx]];
                    if (out.items.len + content.len <= expansion_cap) {
                        try out.appendSlice(alloc, content);
                    } else {
                        const marker = "\n... [mention truncated] ...";
                        const room = expansion_cap -| out.items.len;
                        const content_room = room -| marker.len;
                        try out.appendSlice(alloc, content[0..@min(content_room, content.len)]);
                        try out.appendSlice(alloc, marker);
                    }
                }
                li += mention_path.len;
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
