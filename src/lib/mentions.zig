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
        if (i == 0) {
            is_bare_at = true;
        } else {
            const prev = text[i - 1];
            if (std.ascii.isAlphanumeric(prev) or prev == '_' or prev == '@' or prev == '.' or prev == '/') {
                i += 1; continue;
            }
            const start = i + 1;
            if (start >= text.len) {
                is_bare_at = true;
            } else {
                const c = text[start];
                if (!std.ascii.isAlphanumeric(c) and c != '/' and c != '_' and c != '-' and c != '.') {
                    is_bare_at = true;
                }
            }
        }

        if (is_bare_at) {
            just_at = true;
            i += 1; continue;
        }

        const start = i + 1;
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
            if (path.len < path_max) {
                mentions[n].len = @intCast(path.len);
                @memcpy(mentions[n].path[0..path.len], path);
                n += 1;
            }
        }
        i = end;
    }

    const result = ScanResult{ .mentions = mentions, .just_at = just_at };
    return result;
}

fn looksLikePath(token: []const u8) bool {
    if (std.mem.indexOfScalar(u8, token, '/') != null) return true;
    const dot = std.mem.lastIndexOfScalar(u8, token, '.') orelse return false;
    return dot > 0 and dot + 1 < token.len;
}

pub const Expansion = struct {
    text: []const u8,
    files: u8,
    missing: u8,
};

pub fn highlightMatch(label: []const u8, positions: []const u32, n: usize) []const u8 {
    if (n == 0 or positions.len == 0) return label;
    var result: [256]u8 = undefined;
    var ri: usize = 0;
    var pi: usize = 0;
    var li: usize = 0;
    while (li < label.len and pi < n) {
        const pos = positions[pi];
        if (pos < li) { pi += 1; continue; }
        if (pos > label.len) break;
        if (pos > li) {
            const copy = label[li..pos];
            if (ri + copy.len > result.len) break;
            @memcpy(result[ri .. ri + copy.len], copy);
            ri += copy.len;
        }
        const match_end = @min(positions[pi + 1 - 1] + 1, label.len + 1);
        const match_len = match_end - pos;
        if (ri + match_len + 4 > result.len) break;
        result[ri] = '*';
        ri += 1;
        @memcpy(result[ri .. ri + match_len], label[pos .. pos + match_len]);
        ri += match_len;
        result[ri] = '*';
        ri += 1;
        li = pos + match_len;
        pi += 1;
    }
    if (li < label.len) {
        const copy = label[li..];
        if (ri + copy.len > result.len) {
            @memcpy(result[ri ..], copy[0..result.len - ri - 4]); 
            ri = result.len;
        } else {
            @memcpy(result[ri .. ri + copy.len], copy);
            ri += copy.len;
        }
    }
    if (ri > 0) return result[0..ri];
    return label;
}

pub fn expand(io: std.Io, text: []const u8) !Expansion {
    const scan_result = try scan(text);

    var loaded_paths: [max_files][32]u8 = undefined;
    var loaded_path_count: usize = 0;
    var loaded_count: u8 = 0;

    const max_to_load = if (scan_result.mentions.len < max_files) scan_result.mentions.len else max_files;

    var file_storage: [max_files][file_max]u8 = undefined;
    var file_texts: [max_files][]const u8 = undefined;
    var missing_count: u8 = 0;

    var handle_count: usize = 0;

    for (0..max_to_load) |i| {
        const mention = scan_result.mentions[i];
        const path = mention.pathOf();

        var already_loaded = false;
        for (0..loaded_path_count) |idx| {
            if (std.mem.eql(u8, loaded_paths[idx][0..], path)) {
                already_loaded = true;
                break;
            }
        }

        if (already_loaded) { continue; }

        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch {
            missing_count += 1;
            continue;
        };

        var buf: [file_max]u8 = undefined;
        const n = file.readPositionalAll(io, buf[0..], 0) catch {
            missing_count += 1;
            continue;
        };

        if (handle_count < max_files) {
            @memcpy(file_storage[handle_count][0..], buf[0..n]);
            file_texts[handle_count] = file_storage[handle_count][0..n];
        }

        if (loaded_path_count < max_files) {
            @memcpy(loaded_paths[loaded_path_count][0..path.len], path);
            loaded_path_count += 1;
        }

        handle_count += 1;
        loaded_count += 1;
    }

    var result: [256]u8 = undefined;
    var ri: usize = 0;
    var li: usize = 0;
    var mention_idx: usize = 0;
    var file_idx: usize = 0;

    while (li < text.len) {
        if (mention_idx < scan_result.mentions.len) {
            const mention_path = scan_result.mentions[mention_idx].pathOf();
            if (li + mention_path.len <= text.len and
                std.mem.eql(u8, text[li..li + mention_path.len], mention_path)) {
                var found_file = false;
                for (0..handle_count) |fidx| {
                    if (fidx == mention_idx) {
                        const file_content = file_texts[fidx];
                        const file_len = file_content.len;

                        if (ri + file_len > result.len) {
                            @memcpy(result[ri ..], file_content[0..result.len - ri - 4]); 
                            ri = result.len;
                        } else {
                            @memcpy(result[ri .. ri + file_len], file_content);
                            ri += file_len;
                        }

                        li += mention_path.len;
                        mention_idx += 1;
                        file_idx += 1;
                        found_file = true;
                        break;
                    }
                }
                if (!found_file) {
                    li += mention_path.len;
                    mention_idx += 1;
                    continue;
                }
                continue;
            }
        }

        if (ri < result.len) {
            result[ri] = text[li];
            ri += 1;
        }
        li += 1;
    }

    const result_len = @min(ri, result.len - 4);
    if (result_len > 0) return Expansion{ .text = result[0..result_len], .files = loaded_count, .missing = missing_count };
    return Expansion{ .text = result[0..0], .files = loaded_count, .missing = missing_count };
}

// ── tests ─────────────────────────────────────────────────────

test "scan: finds the mentions in order" {
    const result = try scan("revisa @src/agent.zig y luego @src/tui.zig");
    try std.testing.expectEqual(@as(u8, 2), result.mentions.len);
    try std.testing.expectEqualStrings("src/agent.zig", result.mentions[0].pathOf());
    try std.testing.expectEqualStrings("src/tui.zig", result.mentions[1].pathOf());
    try std.testing.expect(result.just_at == false);
}

test "scan: an email address is NOT a mention" {
    const result = try scan("mándaselo a jorge@example.com");
    try std.testing.expectEqual(@as(u8, 0), result.mentions.len);
    try std.testing.expect(result.just_at == false);
}

test "scan: @ at start of text is bare @" {
    const result = try scan("@");
    try std.testing.expect(result.just_at == true);
    try std.testing.expectEqual(@as(u8, 0), result.mentions.len);
}

test "scan: @ followed by text is NOT bare @" {
    const result = try scan("@a.txt");
    try std.testing.expect(result.just_at == false);
    try std.testing.expectEqual(@as(u8, 1), result.mentions.len);
    try std.testing.expectEqualStrings("a.txt", result.mentions[0].pathOf());
}

test "scan: trailing punctuation does not eat the path" {
    const result = try scan("mira @notas.txt, y @docs/guía.md.");
    try std.testing.expectEqual(@as(u8, 2), result.mentions.len);
    try std.testing.expectEqualStrings("notas.txt", result.mentions[0].pathOf());
    try std.testing.expectEqualStrings("docs/guía.md", result.mentions[1].pathOf());
    try std.testing.expect(result.just_at == false);
}

test "scan: bare @ at end of text" {
    const result = try scan("hola @");
    try std.testing.expect(result.just_at == true);
    try std.testing.expectEqual(@as(u8, 0), result.mentions.len);
}

test "scan: decorators do NOT spend the budget" {
    const result = try scan("revisa esto @Override @deprecated @staticmethod @final @pure @param @import y mira @src/agent.zig");
    try std.testing.expectEqual(@as(u8, 1), result.mentions.len);
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
    try std.testing.expectEqual(@as(u8, 2), result.mentions.len);
    try std.testing.expectEqualStrings("a.txt", result.mentions[0].pathOf());
    try std.testing.expectEqualStrings("b.txt", result.mentions[1].pathOf());
    try std.testing.expect(result.just_at == false);
}

test "scan: a mention inside parentheses or quotes counts too" {
    const result = try scan("(mira @src/a.zig) y \"@src/b.zig\"");
    try std.testing.expectEqual(@as(u8, 2), result.mentions.len);
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
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(@as(u32, 0), buf[0]);
    try std.testing.expectEqual(@as(u32, 1), buf[1]);
    try std.testing.expectEqual(@as(u32, 2), buf[2]);
}
