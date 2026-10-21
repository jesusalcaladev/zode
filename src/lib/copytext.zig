//! `/copy`: the text that gets copied, and the words the user reads about it.
//!
//! Pure on purpose: everything here is string work over the session's own
//! history, and every failure this command can have is a failure of THESE
//! functions — an arithmetic nobody can check ("/copy 3: which answer is
//! that?"), a fence parsed wrong, a language tag turned into a path. None of
//! it needs a TUI or the network, so all of it is tested here.
//!
//! The shape of the command comes from the `/copy` of the reference
//! implementation (Claude Code). What is ported is written next to each piece;
//! what is not: `config.copyFullResponse` as a global setting (a session flag
//! is enough), the `w` = write-to-file shortcut (the file is written ALWAYS,
//! so there is nothing left for a second key to do), and the analytics.
//!
//! The rules this module exists to keep honest:
//!
//! - **Newest-first, and only turns that SAID something.** A tool-only turn has
//!   empty text; zode never persists an API error as an assistant message (an
//!   error is a history notice), so "API error" needs no marker here.
//! - **The full response is copied RAW.** Prompt-XML tags are stripped only for
//!   finding code blocks: a `<context>` block with a fenced example inside must
//!   not become a copyable block, but the user's own copy is what the model
//!   actually wrote.
//! - **The refusals say what to do instead.** "invalid" teaches nothing; "Only
//!   3 assistant messages available to copy" is the truth and it is checkable.

const std = @import("std");
const vaxis = @import("vaxis");

const copytext = @This();

/// How far back `/copy` looks (upstream's `MAX_LOOKBACK`). Past this the LIST
/// itself would be the tax; `/copy N` beyond it gets the honest count, not a
/// silent clamp.
pub const max_lookback = 20;

/// Columns of a code block's first line in the picker's label. Measured in
/// CODEPOINTS and not bytes: a cut inside a multi-byte character would put
/// invalid UTF-8 into the picker and onto the wire.
pub const label_max_cols = 60;

/// Bytes a truncated label can need: `label_max_cols` codepoints of up to four
/// bytes plus the ellipsis.
pub const label_buf_len = label_max_cols * 4 + 8;

pub const full_label_prefix = "Full response";
pub const always_label = "Always copy full response";
pub const no_messages_msg = "No assistant message to copy";
pub const cancelled_msg = "Copy cancelled";
pub const preference_msg = "Preference saved: /copy now takes the full response (this session).";
pub const full_filename = "response.md";
pub const always_desc = "skip this picker in the future";

// ── the collection: newest-first, only turns that said something ──────────

/// One session message as the collector cares about it. The session's own
/// `Message` lives in `src/session.zig`, which a `lib/` module cannot import,
/// so the view is this narrow on purpose.
pub const View = struct {
    assistant: bool,
    content: []const u8,
};

/// Up to `max_lookback` assistant texts, index 0 = the newest.
pub fn collectBackward(views: []const View, out: *[max_lookback][]const u8) usize {
    var n: usize = 0;
    var i = views.len;
    while (i > 0 and n < max_lookback) : (i -= 1) {
        const v = views[i - 1];
        if (!v.assistant or v.content.len == 0) continue;
        out[n] = v.content;
        n += 1;
    }
    return n;
}

// ── the arithmetic: /copy N ───────────────────────────────────────────────

pub const Select = union(enum) {
    found: usize,
    no_messages,
    usage,
    too_few: usize,
};

/// `/copy N` reaches back N-1 messages: 1 is the latest, 2 the one before it.
pub fn select(texts: []const []const u8, arg: ?[]const u8) Select {
    if (texts.len == 0) return .no_messages;
    const raw = arg orelse return .{ .found = 0 };
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return .{ .found = 0 };
    const n = std.fmt.parseInt(usize, trimmed, 10) catch return .usage;
    if (n < 1) return .usage;
    if (n > texts.len) return .{ .too_few = texts.len };
    return .{ .found = n - 1 };
}

/// The sentence for a refusal, written into `buf`; empty for `.found`.
///
/// Every branch says what to DO: "use 1 for the latest", "you have only 3".
/// A refusal the user cannot act on is a dead end, and "invalid" is one.
pub fn formatRefusal(buf: []u8, sel: Select, arg: ?[]const u8) []const u8 {
    return switch (sel) {
        .found => "",
        .no_messages => no_messages_msg,
        .usage => std.fmt.bufPrint(
            buf,
            "Usage: /copy [N] where N is 1 (latest), 2, 3, \u{2026} Got: {s}",
            .{std.mem.trim(u8, arg orelse "", " \t\r\n")},
        ) catch "Usage: /copy [N] where N is 1 (latest), 2, 3, \u{2026}",
        .too_few => |avail| std.fmt.bufPrint(
            buf,
            "Only {d} assistant {s} available to copy",
            .{ avail, if (avail == 1) "message" else "messages" },
        ) catch "Only one assistant message is available to copy",
    };
}

// ── prompt-XML tags ───────────────────────────────────────────────────────

/// The prompt-XML blocks the reference implementation strips before looking for
/// code: a `<context>` block with a fenced example inside would otherwise be a
/// fake code block.
const stripped_tags = [_][]const u8{ "commit_analysis", "context", "function_analysis", "pr_analysis" };

/// `text` minus every `<tag>…</tag>` of `stripped_tags` (and the newline after
/// the closing tag, same as the regex). An unterminated tag is left alone: the
/// regex needs both ends, and so do we.
pub fn stripPromptXmlTags(arena: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    outer: while (i < text.len) {
        inline for (stripped_tags) |tag| {
            const open = "<" ++ tag ++ ">";
            if (startsWithAt(text, i, open)) {
                const close = "</" ++ tag ++ ">";
                if (std.mem.indexOfPos(u8, text, i + open.len, close)) |end| {
                    var skip = end + close.len;
                    if (skip < text.len and text[skip] == '\n') skip += 1;
                    i = skip;
                    continue :outer;
                }
            }
        }
        try out.append(arena, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

fn startsWithAt(text: []const u8, at: usize, prefix: []const u8) bool {
    if (at + prefix.len > text.len) return false;
    return std.mem.eql(u8, text[at .. at + prefix.len], prefix);
}

// ── fenced code blocks ────────────────────────────────────────────────────

pub const Block = struct {
    lang: []const u8,
    code: []const u8,
};

/// The ``` blocks of `text`, in order.
///
/// `text` is expected to be STRIPPED first (see `stripPromptXmlTags`): the
/// composition is the caller's decision and it is tested as one in
/// `commands.zig`. A closing fence must carry no info string (CommonMark's
/// rule), so a ```c INSIDE a block is code, not the end of it.
pub fn extractCodeBlocks(arena: std.mem.Allocator, text: []const u8) ![]Block {
    var blocks: std.ArrayList(Block) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
        if (isFence(text[i..line_end])) {
            const info = std.mem.trim(u8, fenceInfo(text[i..line_end]), " \t\r");
            const lang_end = for (info, 0..) |c, k| {
                if (std.ascii.isWhitespace(c)) break k;
            } else info.len;
            const body_start = if (line_end < text.len) line_end + 1 else text.len;
            const close = findFenceEnd(text, body_start);
            var code = text[body_start..close.offset];
            // One trailing newline belongs to the fence, not to the code.
            if (code.len > 0 and code[code.len - 1] == '\n') code = code[0 .. code.len - 1];
            try blocks.append(arena, .{ .lang = info[0..lang_end], .code = code });
            i = if (close.next) |n| n else text.len;
        } else {
            i = if (line_end < text.len) line_end + 1 else text.len;
        }
    }
    return blocks.toOwnedSlice(arena);
}

fn isFence(line: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trim(u8, line, " \t\r"), "```");
}

fn fenceInfo(line: []const u8) []const u8 {
    const t = std.mem.trim(u8, line, " \t\r");
    return t["```".len..];
}

const FenceEnd = struct {
    offset: usize,
    next: ?usize,
};

/// Where the block opened at `from` ends: the offset of its closing fence (or
/// the end of the text) and the offset of the line after that fence.
fn findFenceEnd(text: []const u8, from: usize) FenceEnd {
    var j = from;
    while (j < text.len) {
        const le = std.mem.indexOfScalarPos(u8, text, j, '\n') orelse text.len;
        const line = text[j..le];
        if (isFence(line) and std.mem.trim(u8, fenceInfo(line), " \t\r").len == 0) {
            return .{ .offset = j, .next = if (le < text.len) le + 1 else null };
        }
        if (le >= text.len) break;
        j = le + 1;
    }
    return .{ .offset = text.len, .next = null };
}

// ── labels, filenames, counts ─────────────────────────────────────────────

/// The file a copied block lands as. The language tag IS model output and a
/// path is a filesystem: every character that is not a letter or a digit is
/// stripped (`../../etc/passwd` becomes `.etcpasswd`, never a path), and an
/// empty or `plaintext` result is `.txt`.
pub fn fileExtension(lang: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    for (lang) |c| {
        if (!std.ascii.isAlphanumeric(c)) continue;
        if (n + 1 >= buf.len) break;
        buf[1 + n] = c;
        n += 1;
    }
    if (n == 0) return ".txt";
    if (std.mem.eql(u8, buf[1 .. 1 + n], "plaintext")) return ".txt";
    buf[0] = '.';
    return buf[0 .. 1 + n];
}

/// `copy<ext>` — the name for a picked block (upstream's own).
pub fn filenameForBlock(lang: []const u8, buf: []u8) []const u8 {
    var ext_buf: [40]u8 = undefined;
    const ext = fileExtension(lang, &ext_buf);
    if (buf.len < 8) return "copy.txt";
    const n = @min(ext.len, buf.len - 4);
    @memcpy(buf[0..4], "copy");
    @memcpy(buf[4 .. 4 + n], ext[0..n]);
    return buf[0 .. 4 + n];
}

/// The first line of `text` (a `\r\n` ending is not part of it).
pub fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return std.mem.trimEnd(u8, text[0..end], "\r");
}

/// The width in COLUMNS of a text, measured the way the terminal measures it.
///
/// A CJK character is TWO columns and a combining mark is zero, so counting
/// codepoints would say a 60-column label is 60 when it is 100 — and the row
/// would be cut in the middle of the text the user is trying to recognise.
pub fn displayWidth(text: []const u8) usize {
    return vaxis.gwidth.gwidth(text, .unicode);
}

/// The first line of `text` cut to `max_cols` COLUMNS with an ellipsis, into
/// `buf`. A line that already fits is returned as-is (no copy).
pub fn truncateToCols(text: []const u8, max_cols: usize, buf: []u8) []const u8 {
    const line = firstLine(text);
    if (max_cols == 0) return "";
    if (displayWidth(line) <= max_cols) return line;
    const target = max_cols - 1; // one column for the ellipsis
    // By GRAPHEME, not by codepoint: a cut in the middle of a cluster (a
    // flag, an emoji with a variation selector) is a broken label.
    var it = vaxis.unicode.graphemeIterator(line);
    var width: usize = 0;
    var end: usize = 0;
    while (it.next()) |g| {
        const w = displayWidth(g.bytes(line));
        if (width + w > target) break;
        width += w;
        end = g.start + g.len;
    }
    const keep = @min(end, buf.len -| 3);
    @memcpy(buf[0..keep], line[0..keep]);
    const ell = "\u{2026}";
    const e = @min(ell.len, buf.len - keep);
    @memcpy(buf[keep .. keep + e], ell[0..e]);
    return buf[0 .. keep + e];
}

fn codepointLen(text: []const u8) usize {
    var n: usize = 0;
    var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (it.nextCodepoint()) |_| n += 1;
    return n;
}

/// Characters (codepoints): the number a human counts. Bytes would call a CJK
/// answer twice as long as it reads.
pub fn countChars(text: []const u8) usize {
    _ = std.unicode.Utf8View.init(text) catch return text.len; // invalid UTF-8: bytes is the honest fallback
    return codepointLen(text);
}

/// Lines the way every editor counts them (a trailing newline does not add
/// one; an empty text is one empty line).
pub fn countLines(text: []const u8) usize {
    var n: usize = 1;
    for (text) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

/// A row label the picker MATCHES on, so two blocks that begin with the same
/// line must not produce two identical rows: without the counter the pick
/// would copy the first one's code and look like it copied the second's.
pub fn uniqueLabel(arena: std.mem.Allocator, base: []const u8, dup_index: usize) ![]u8 {
    if (dup_index == 0) return arena.dupe(u8, base);
    return std.fmt.allocPrint(arena, "{s} ({d})", .{ base, dup_index + 1 });
}

// ── the picker's context ─────────────────────────────────────────────────

/// What a `/copy` needs while the picker is open, OWNED.
///
/// The full text is copied RAW: the prompt-XML tags are stripped only to FIND
/// the code blocks, because a `<context>` block with a fenced example inside
/// would otherwise become a "copyable block" the user never wrote. What the
/// model actually said is what goes to the clipboard.
pub const Ctx = struct {
    gpa: std.mem.Allocator,
    /// The whole answer, as it was written.
    full: []u8,
    /// The code blocks of the answer.
    blocks: []Block,

    pub fn deinit(self: *Ctx) void {
        self.gpa.free(self.full);
        for (self.blocks) |b| {
            self.gpa.free(b.lang);
            self.gpa.free(b.code);
        }
        self.gpa.free(self.blocks);
    }

    /// The text of the entry `index`: 0 is the whole answer, 1..n are the
    /// blocks. Null for anything else.
    pub fn textAt(self: *const Ctx, index: usize) ?[]const u8 {
        if (index == 0) return self.full;
        if (index <= self.blocks.len) return self.blocks[index - 1].code;
        return null;
    }
};

/// Builds the context: the raw text, and the blocks found in the STRIPPED
/// text.
pub fn buildCtx(gpa: std.mem.Allocator, text: []const u8) !Ctx {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const stripped = try stripPromptXmlTags(arena, text);
    const found = try extractCodeBlocks(arena, stripped);

    const blocks = try gpa.alloc(Block, found.len);
    errdefer gpa.free(blocks);
    var made: usize = 0;
    errdefer {
        for (blocks[0..made]) |b| {
            gpa.free(b.lang);
            gpa.free(b.code);
        }
    }
    for (found, 0..) |b, i| {
        blocks[i] = .{
            .lang = try gpa.dupe(u8, b.lang),
            .code = try gpa.dupe(u8, b.code),
        };
        made += 1;
    }
    return .{ .gpa = gpa, .full = try gpa.dupe(u8, text), .blocks = blocks };
}

// ── the sentences the user reads ──────────────────────────────────────────

pub fn formatFullLabel(buf: []u8, chars: usize, lines: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{s} ({d} characters, {d} lines)", .{ full_label_prefix, chars, lines }) catch full_label_prefix;
}

/// The picker's description for a block: `zig, 40 lines` / `40 lines` / `zig`
/// / empty — the same parts upstream joins, in the same order.
pub fn formatBlockDesc(buf: []u8, lang: []const u8, code: []const u8) []const u8 {
    const lines = countLines(code);
    if (lang.len == 0 and lines <= 1) return "";
    if (lang.len == 0) return std.fmt.bufPrint(buf, "{d} lines", .{lines}) catch "";
    if (lines <= 1) return std.fmt.bufPrint(buf, "{s}", .{lang}) catch "";
    return std.fmt.bufPrint(buf, "{s}, {d} lines", .{ lang, lines }) catch "";
}

/// "Copied to clipboard (8123 characters, 214 lines) — also written to …".
/// The file is named with its numbers because the clipboard half is
/// best-effort (OSC 52 is genuinely best-effort) and a copy confirmation you
/// cannot check is not a confirmation.
pub fn formatCopied(buf: []u8, chars: usize, lines: usize, path: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "Copied to clipboard ({d} characters, {d} lines) \u{2014} also written to {s}", .{ chars, lines, path }) catch
        "Copied to clipboard";
}

pub fn formatCopiedBare(buf: []u8, chars: usize, lines: usize) []const u8 {
    return std.fmt.bufPrint(buf, "Copied to clipboard ({d} characters, {d} lines)", .{ chars, lines }) catch
        "Copied to clipboard";
}

pub fn formatWritten(buf: []u8, chars: usize, lines: usize, path: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "Written to {s} ({d} characters, {d} lines)", .{ path, chars, lines }) catch "Written to a file";
}

/// The message of a copy whose FILE could not be written.
///
/// The clipboard half may still have worked, so the message says what DID
/// happen and what did not: a failed write is shown, not swallowed.
pub fn formatCopiedNoFile(buf: []u8, chars: usize, lines: usize, method: []const u8) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "Copied to {s} ({d} characters, {d} lines) \u{2014} the file could not be written",
        .{ method, chars, lines },
    ) catch "Copied";
}

/// The message of a copy that worked, with the numbers AND the path.
///
/// The method is named because a copy confirmation you cannot check is not a
/// confirmation: OSC 52 is best-effort (the terminal may ignore it, or print
/// it), and a native tool is not the same thing as a terminal's own buffer.
pub fn formatCopiedVia(buf: []u8, chars: usize, lines: usize, method: []const u8, path: []const u8) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "Copied to {s} ({d} characters, {d} lines) \u{2014} also written to {s}",
        .{ method, chars, lines, path },
    ) catch "Copied";
}


// ── tests ─────────────────────────────────────────────────────────────────

fn expectFound(sel: Select, want: usize) !void {
    switch (sel) {
        .found => |i| try std.testing.expectEqual(want, i),
        else => return error.TestUnexpectedResult,
    }
}

test "collectBackward: newest first, skipping roles and empty turns" {
    const views = [_]View{
        .{ .assistant = false, .content = "question" },
        .{ .assistant = true, .content = "" }, // tool-only turn: nothing to copy
        .{ .assistant = true, .content = "older answer" },
        .{ .assistant = false, .content = "tool result" },
        .{ .assistant = true, .content = "newest answer" },
    };
    var out: [max_lookback][]const u8 = undefined;
    const n = collectBackward(&views, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("newest answer", out[0]);
    try std.testing.expectEqualStrings("older answer", out[1]);
}

test "collectBackward: caps at max_lookback, newest first" {
    var texts: [max_lookback + 5][8]u8 = undefined;
    var views: [max_lookback + 5]View = undefined;
    for (&views, 0..) |*v, i| {
        const s = std.fmt.bufPrint(&texts[i], "a{d}", .{i}) catch unreachable;
        v.* = .{ .assistant = true, .content = s };
    }
    var out: [max_lookback][]const u8 = undefined;
    const n = collectBackward(&views, &out);
    try std.testing.expectEqual(max_lookback, n);
    try std.testing.expectEqualStrings("a24", out[0]); // the newest 20, starting at the front
    try std.testing.expectEqualStrings("a5", out[max_lookback - 1]);
}

test "select: /copy N arithmetic and the honest refusals" {
    const texts = [_][]const u8{ "newest", "middle", "oldest" };
    try expectFound(select(&texts, null), 0);
    try expectFound(select(&texts, "1"), 0);
    try expectFound(select(&texts, " 2 "), 1);
    try expectFound(select(&texts, "3"), 2);
    try std.testing.expect(select(&texts, "0") == .usage);
    try std.testing.expect(select(&texts, "abc") == .usage);
    try std.testing.expect(select(&texts, "2 extra") == .usage);
    switch (select(&texts, "4")) {
        .too_few => |avail| try std.testing.expectEqual(@as(usize, 3), avail),
        else => return error.TestUnexpectedResult,
    }

    const none = [_][]const u8{};
    try std.testing.expect(select(&none, null) == .no_messages);
    try std.testing.expect(select(&none, "1") == .no_messages);
}

test "formatRefusal: every refusal says what to do, and the plural is right" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("", formatRefusal(&buf, .{ .found = 0 }, null));
    try std.testing.expectEqualStrings(no_messages_msg, formatRefusal(&buf, .no_messages, null));

    const usage = formatRefusal(&buf, .usage, "abc");
    try std.testing.expect(std.mem.indexOf(u8, usage, "Usage: /copy [N]") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "abc") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "1 (latest)") != null);

    const one = formatRefusal(&buf, .{ .too_few = 1 }, "3");
    try std.testing.expectEqualStrings("Only 1 assistant message available to copy", one);
    const three = formatRefusal(&buf, .{ .too_few = 3 }, "9");
    try std.testing.expectEqualStrings("Only 3 assistant messages available to copy", three);
}

test "stripPromptXmlTags: the four blocks go, the rest is untouched" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const text =
        \\before
        \\<context>fake
        \\```zig
        \\const fake = 1;
        \\```
        \\</context>
        \\after
    ;
    const out = try stripPromptXmlTags(a.allocator(), text);
    try std.testing.expect(std.mem.indexOf(u8, out, "<context>") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "const fake") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "after") != null);
    // The tag AND the newline after it are eaten (the upstream regex removes
    // the block plus one optional newline), so what is left is one line
    // break, not two.
    try std.testing.expect(std.mem.indexOf(u8, out, "before\nafter") != null);

    // A `<` that is not a stripped tag is text, and an unterminated tag stays.
    const plain = try stripPromptXmlTags(a.allocator(), "a < b and <context>never closed");
    try std.testing.expectEqualStrings("a < b and <context>never closed", plain);
}

test "extractCodeBlocks: langs, no lang, prose around, unterminated" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const text =
        \\intro
        \\
        \\```zig
        \\const x = 1;
        \\const y = 2;
        \\```
        \\middle
        \\```
        \\plain fence
        \\```
        \\```rust title=x
        \\fn main() {}
    ;
    const blocks = try extractCodeBlocks(a.allocator(), text);
    try std.testing.expectEqual(@as(usize, 3), blocks.len);
    try std.testing.expectEqualStrings("zig", blocks[0].lang);
    try std.testing.expectEqualStrings("const x = 1;\nconst y = 2;", blocks[0].code);
    try std.testing.expectEqualStrings("", blocks[1].lang);
    try std.testing.expectEqualStrings("plain fence", blocks[1].code);
    // The info string is cut at the first whitespace, and the unterminated
    // block runs to the end of the text instead of being dropped.
    try std.testing.expectEqualStrings("rust", blocks[2].lang);
    try std.testing.expectEqualStrings("fn main() {}", blocks[2].code);
}

test "extractCodeBlocks: a fence with an INFO STRING inside a block is code" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const text =
        \\```markdown
        \\like this:
        \\```zig
        \\const inner = 1;
        \\```
        \\done
        \\```
    ;
    const blocks = try extractCodeBlocks(a.allocator(), text);
    // The closing fence of a block carries NO info string (CommonMark's
    // rule, and the one `marked` follows), so "```zig" inside the block is
    // code and the plain "```" closes it.
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqualStrings("markdown", blocks[0].lang);
    try std.testing.expect(std.mem.indexOf(u8, blocks[0].code, "const inner = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, blocks[0].code, "like this:") != null);
    // And the rest of the text is another block: the last fence opens one
    // that is never closed.
    try std.testing.expectEqualStrings("", blocks[1].lang);
}

test "fileExtension: sanitised, and plaintext or empty is .txt" {
    var buf: [48]u8 = undefined;
    try std.testing.expectEqualStrings(".zig", fileExtension("zig", &buf));
    // `c++` sanitises to `c`: the upstream's regex keeps the letters and the
    // digits and drops everything else, so the `+`s are NOT turned into `p`s.
    // A language tag is model output and a path is a filesystem, and `..`
    // must never survive into one.
    try std.testing.expectEqualStrings(".c", fileExtension("c++", &buf));
    try std.testing.expectEqualStrings(".txt", fileExtension("plaintext", &buf));
    try std.testing.expectEqualStrings(".txt", fileExtension("", &buf));
    try std.testing.expectEqualStrings(".etcpasswd", fileExtension("../../etc/passwd", &buf));

    var fbuf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("copy.zig", filenameForBlock("zig", &fbuf));
    try std.testing.expectEqualStrings("copy.txt", filenameForBlock("", &fbuf));
}

test "truncateToCols: 60 COLUMNS, measured the way the terminal measures them" {
    var buf: [label_buf_len]u8 = undefined;
    // Short comes back as itself (the SAME slice, no copy).
    const short = truncateToCols("const x = 1;\nconst y = 2;", 60, &buf);
    try std.testing.expectEqualStrings("const x = 1;", short);

    var long_line: [200]u8 = @splat('a');
    const cut = truncateToCols(&long_line, 60, &buf);
    try std.testing.expectEqual(@as(usize, 60), displayWidth(cut));
    try std.testing.expect(std.mem.endsWith(u8, cut, "\u{2026}"));
    try std.testing.expectEqual(@as(usize, 59), codepointLen(cut[0 .. cut.len - "\u{2026}".len]));

    // A CJK character is TWO columns: ten columns of CJK are five characters,
    // and counting codepoints would say ten and cut the label in half. The
    // ellipsis takes one column of the budget, so four characters (eight
    // columns) plus the ellipsis is what fits in ten.
    var cjk: [400]u8 = undefined;
    var w: std.Io.Writer = .fixed(&cjk);
    var k: usize = 0;
    while (k < 40) : (k += 1) w.writeAll("\u{754c}") catch {};
    const cjk_cut = truncateToCols(w.buffered(), 10, &buf);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cjk_cut));
    try std.testing.expect(displayWidth(cjk_cut) <= 10);
    try std.testing.expect(std.mem.endsWith(u8, cjk_cut, "\u{2026}"));
    // Four characters and the ellipsis: five codepoints, not ten.
    try std.testing.expectEqual(@as(usize, 5), codepointLen(cjk_cut));
}

test "counts: characters are codepoints, lines do not count a trailing newline" {
    try std.testing.expectEqual(@as(usize, 1), countLines(""));
    try std.testing.expectEqual(@as(usize, 1), countLines("one"));
    try std.testing.expectEqual(@as(usize, 2), countLines("one\n"));
    try std.testing.expectEqual(@as(usize, 3), countLines("one\ntwo\nthree"));
    try std.testing.expectEqual(@as(usize, 3), countChars("abc"));
    // 3 characters, 9 bytes: bytes would lie about the length of the answer.
    try std.testing.expectEqual(@as(usize, 3), countChars("\u{754c}a\u{1F600}"));
}

test "formatFullLabel and formatBlockDesc: the picker's own words" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Full response (8123 characters, 214 lines)",
        formatFullLabel(&buf, 8123, 214),
    );
    // The lines are the lines of the CODE, and the upstream counts them the
    // same way (the newlines plus one).
    try std.testing.expectEqualStrings("zig, 3 lines", formatBlockDesc(&buf, "zig", "a\nb\nc"));
    try std.testing.expectEqualStrings("3 lines", formatBlockDesc(&buf, "", "a\nb\nc"));
    try std.testing.expectEqualStrings("zig", formatBlockDesc(&buf, "zig", "one"));
    try std.testing.expectEqualStrings("", formatBlockDesc(&buf, "", "one"));
}

test "uniqueLabel: a repeated first line gets a visible counter" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();
    const first = try uniqueLabel(gpa, "const x = 1;", 0);
    const second = try uniqueLabel(gpa, "const x = 1;", 1);
    try std.testing.expectEqualStrings("const x = 1;", first);
    try std.testing.expectEqualStrings("const x = 1; (2)", second);
}

test "the copied sentences carry the numbers and the path" {
    var buf: [512]u8 = undefined;
    const with_path = formatCopied(&buf, 8123, 214, "/tmp/zode/response.md");
    try std.testing.expect(std.mem.indexOf(u8, with_path, "8123 characters, 214 lines") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_path, "/tmp/zode/response.md") != null);
    const bare = formatCopiedBare(&buf, 10, 2);
    try std.testing.expectEqualStrings("Copied to clipboard (10 characters, 2 lines)", bare);
    const written = formatWritten(&buf, 9, 1, "/tmp/x.md");
    try std.testing.expectEqualStrings("Written to /tmp/x.md (9 characters, 1 lines)", written);
}

test "formatCopiedVia names the method, because a copy you cannot check is not a confirmation" {
    var buf: [512]u8 = undefined;
    const msg = formatCopiedVia(&buf, 8123, 214, "the system clipboard", "/tmp/zode/response.md");
    try std.testing.expect(std.mem.indexOf(u8, msg, "the system clipboard") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "8123 characters, 214 lines") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "/tmp/zode/response.md") != null);
}

test "buildCtx: the raw text is kept and the blocks come from the STRIPPED text" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();

    const text =
        \\before
        \\<context>fake
        \\```zig
        \\const fake = 1;
        \\```
        \\</context>
        \\after
        \\```zig
        \\const real = 2;
        \\```
    ;
    var ctx = try buildCtx(gpa, text);
    defer ctx.deinit();

    // The RAW text is what gets copied: the user's copy is what the model
    // wrote, tags and all.
    try std.testing.expectEqualStrings(text, ctx.full);
    // And the fake block inside `<context>` is NOT one of the blocks.
    try std.testing.expectEqual(@as(usize, 1), ctx.blocks.len);
    try std.testing.expectEqualStrings("zig", ctx.blocks[0].lang);
    try std.testing.expectEqualStrings("const real = 2;", ctx.blocks[0].code);
}

test "buildCtx: textAt maps 0 to the whole answer and 1..n to the blocks" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();

    var ctx = try buildCtx(gpa, "hi\n```zig\nconst x = 1;\n```\n");
    defer ctx.deinit();

    try std.testing.expectEqualStrings("hi\n```zig\nconst x = 1;\n```\n", ctx.textAt(0).?);
    try std.testing.expectEqualStrings("const x = 1;", ctx.textAt(1).?);
    // There is no block 2: a null, not a panic and not the full text.
    try std.testing.expect(ctx.textAt(2) == null);
}


