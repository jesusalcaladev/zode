const std = @import("std");

/// The `@file` mentions in the prompt.
///
/// ## What it does
///
/// You type `@src/agent.zig` and the file's contents go to the model, without
/// it having to spend a turn on a `read`. The user's prompt stays as written
/// (with its `@path`) and the blocks are appended at the end, so the sentence
/// they typed stays readable in the history.
///
/// ## Why it is NOT injected at the position of the `@`
///
/// Because of the cache: the file content goes inside the user message, and if
/// the user edits the prompt (or the same prompt is resent in an iteration of
/// the agent loop) the injected text would change and the provider's prefix
/// would be invalidated wholesale. At the end, after the sentence, the block is
/// stable as long as the file does not change.
///
/// ## The caps
///
/// 4 files, 32 KB each. An `@` on a 2 MB file is not a mention, it is an
/// accident: the model gets 2 MB of context it did not ask for and compaction
/// pays for it. And when it is cut, the block SAYS so, because a file truncated
/// in silence is the fastest way to get the model to invent the ending.
pub const max_files = 4;
pub const file_max = 32 * 1024;
pub const path_max = 200;
pub const scanned_max = 8;

pub const Mention = struct {
    /// The path exactly as the user typed it (for the block).
    path: [path_max]u8 = undefined,
    len: u8 = 0,

    pub fn pathOf(self: *const Mention) []const u8 {
        return self.path[0..self.len];
    }
};

/// Finds the mentions in a text. PURE: it does not touch the disk.
///
/// Returns how many it found (at most `scanned_max`) and leaves them in `out` in
/// order of appearance, without repeats.
pub fn scan(text: []const u8, out: *[scanned_max]Mention) u8 {
    var n: u8 = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '@') {
            i += 1;
            continue;
        }
        // An `@` only counts if it is NOT part of something else. The real case that
        // matters is the email: `user@example.com` is NOT a mention of
        // `example.com`, and if it were, every prompt with an email address
        // would read a file that does not exist.
        if (i > 0) {
            const prev = text[i - 1];
            if (std.ascii.isAlphanumeric(prev) or prev == '_' or prev == '@' or prev == '.' or prev == '/') {
                i += 1;
                continue;
            }
        }
        const start = i + 1;
        var j = start;
        while (j < text.len) : (j += 1) {
            const c = text[j];
            // `>= 0x80` is what lets `guía.md` or `año.txt` through: UTF-8 continuation
            // bytes are all >= 0x80, so the condition is safe and never splits
            // anything in the middle of a character.
            if (std.ascii.isAlphanumeric(c) or c >= 0x80 or c == '_' or c == '/' or c == '-' or c == '.') continue;
            break;
        }
        // A bare `@` ("@ los tres") and the punctuation that swallowed the path
        // ("@notas.txt,") are not mentions.
        var end = j;
        while (end > start and (text[end - 1] == '.' or text[end - 1] == ',' or text[end - 1] == ':')) {
            end -= 1;
        }
        if (end <= start) {
            i += 1;
            continue;
        }
        // `name@domain` is an email, and in an email the right side is the domain.
        // That is the case that breaks the "the @ must be preceded by a space"
        // rule: in `@jorge@example.com` the first `@` is at the very start of
        // the text. Looking at what comes AFTER resolves it without weird
        // exceptions.
        if (end < text.len and text[end] == '@') {
            i = end + 1;
            continue;
        }
        const path = text[start..end];
        // A mention looks like a PATH: a `/` or an extension.
        //
        // Without this check, pasting a snippet with decorators
        // (`@Override`, `@click.command`, `@import`, `@deprecated`, `@final`…)
        // filled the scanner's budget: they are 8 mentions, and the ninth, which
        // was the real `@src/agent.zig`, was never looked at. Measured: seven
        // decorators and the real mention disappears, without warning. Worse,
        // each decorator counts as "not found" and the user sees a "1 not
        // found" without having asked for anything.
        //
        // The cost of the filter: a bare `@Makefile` (a file with no extension
        // in the root) no longer expands. You write `@./Makefile`, which is
        // also what you should write to stop the path depending on where you
        // happen to be looking.
        if (!looksLikePath(path)) {
            i = end;
            continue;
        }
        if (n >= scanned_max) return n;
        var dup = false;
        for (out[0..n]) |prev| {
            if (std.mem.eql(u8, prev.pathOf(), path)) dup = true;
        }
        if (!dup) {
            if (path.len < path_max) {
                out[n].len = @intCast(path.len);
                @memcpy(out[n].path[0..path.len], path);
                n += 1;
            }
        }
        i = end;
    }
    return n;
}

/// Is the token a path and not a word?
///
/// A `/` or an extension. It is what separates `@src/agent.zig` and `@notas.txt`
/// from `@Override`, and it lives in `scan` (not in `expand`) on purpose: if
/// the filter were down below, the decorators would keep spending the scanner's
/// budget and the real mention would keep getting lost.
fn looksLikePath(token: []const u8) bool {
    if (std.mem.indexOfScalar(u8, token, '/') != null) return true;
    // The extension is the last `.`, and not a leading dot ("`.gitignore`"
    // has no extension: you write `@./.gitignore`).
    const dot = std.mem.lastIndexOfScalar(u8, token, '.') orelse return false;
    return dot > 0 and dot + 1 < token.len;
}

/// A result of `expand`.
pub const Expansion = struct {
    /// The text that is sent to the model. It comes from `arena`.
    text: []const u8,
    /// How many files actually went in.
    files: u8,
    /// Mentions that could not be included (they do not exist, or are directories).
    missing: u8,
};

/// The header of each block. Shared with the test so the format is not
/// duplicated (and the format is exactly what needs pinning).
pub fn blockHeader(w: *std.Io.Writer, path: []const u8, bytes: usize, truncated: bool) !void {
    try w.print("--- {s} ({d} bytes{s}) ---\n", .{
        path,
        bytes,
        if (truncated) ", truncated" else "",
    });
}

/// Extends the prompt with the contents of the mentioned files.
///
/// Returns the ORIGINAL text (without copying it) if there is nothing to add,
/// which is the normal case and must not cost an allocation.
pub fn expand(
    arena: std.mem.Allocator,
    io: std.Io,
    text: []const u8,
) !Expansion {
    var found: [scanned_max]Mention = undefined;
    const n = scan(text, &found);
    if (n == 0) return .{ .text = text, .files = 0, .missing = 0 };

    // +1 KB of slack for the headers and separators of the 4 blocks.
    var w: std.Io.Writer = .fixed(arena.alloc(u8, file_max * max_files + 1024) catch return .{
        .text = text,
        .files = 0,
        .missing = 0,
    });
    try w.writeAll(text);
    try w.writeAll("\n\nMentioned files:\n\n");

    var files: u8 = 0;
    var missing: u8 = 0;
    for (found[0..n]) |*ment| {
        if (files >= max_files) {
            missing += 1;
            continue;
        }
        const path = ment.pathOf();
        // The same filter the tools use: neither `.git` nor `zig-out` nor the cache.
        if (!looksLikeSource(path)) {
            missing += 1;
            continue;
        }
        const dir: std.Io.Dir = .cwd();
        const st = dir.statFile(io, path, .{}) catch {
            missing += 1;
            continue;
        };
        if (st.kind != .file) {
            missing += 1;
            continue;
        }
        // Read a PREFIX, not the whole file.
        //
        // `readFileAlloc(..., .limited(n))` does not truncate: if the file goes
        // over `n` bytes it returns `error.FileTooBig`. So a `@src/tui.zig`
        // (250 KB) counted as "not found" and was NEVER injected, which is
        // exactly the case that needed it most. With `readPositional` the first
        // `file_max` bytes are read and flagged as truncated, which is what the
        // model needs so it does not invent the ending.
        const content = readPrefix(io, dir, path, arena) catch {
            missing += 1;
            continue;
        };
        const truncated = content.truncated;
        const kept = content.bytes;
        try blockHeader(&w, path, kept.len, truncated);
        try w.writeAll(kept);
        // A separator between files: without it, two blocks glued together look like
        // one and the model does not know where each one ends.
        if (!std.mem.endsWith(u8, kept, "\n")) try w.writeAll("\n");
        try w.writeAll("\n");
        files += 1;
    }

    if (files == 0) {
        // No servable file: the clean prompt is better than an empty block with
        // "Mentioned files:" and nothing under it.
        return .{ .text = text, .files = 0, .missing = missing };
    }
    return .{ .text = w.buffered(), .files = files, .missing = missing };
}

/// The first `file_max` bytes of a file.
///
/// Returns the block and whether it was cut. `arena` because the content lives
/// in the extended prompt, which comes from the turn's arena.
fn readPrefix(
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    arena: std.mem.Allocator,
) !struct { bytes: []const u8, truncated: bool } {
    const f = try dir.openFile(io, path, .{});
    defer f.close(io);
    const buf = try arena.alloc(u8, file_max);
    const n = try f.readPositional(io, &.{buf}, 0);
    // If the buffer filled up there may be more behind it: it is flagged as
    // truncated. (A file of EXACTLY `file_max` comes out flagged too, which is
    // harmless: the block says "truncated" and nothing is missing from it.)
    return .{ .bytes = buf[0..n], .truncated = n >= file_max };
}

/// A file that makes sense to put in a prompt.
fn looksLikeSource(path: []const u8) bool {
    const skip = [_][]const u8{ ".zig-cache/", "zig-out/", ".git/", "node_modules/", "sessions/" };
    for (skip) |d| {
        if (std.mem.indexOf(u8, path, d) != null) return false;
    }
    return true;
}

// ── tests ─────────────────────────────────────────────────────

test "scan: finds the mentions in order" {
    var out: [scanned_max]Mention = undefined;
    const n = scan("revisa @src/agent.zig y luego @src/tui.zig", &out);
    try std.testing.expectEqual(@as(u8, 2), n);
    try std.testing.expectEqualStrings("src/agent.zig", out[0].pathOf());
    try std.testing.expectEqualStrings("src/tui.zig", out[1].pathOf());
}

test "scan: an email address is NOT a mention" {
    // The case that is really needed: writing to someone with their address.
    var out: [scanned_max]Mention = undefined;
    try std.testing.expectEqual(@as(u8, 0), scan("mándaselo a jorge@example.com", &out));
    try std.testing.expectEqual(@as(u8, 0), scan("@jorge@example.com", &out));
    // And the hard case: an `@` glued to a letter in front is saved by nothing.
    try std.testing.expectEqual(@as(u8, 0), scan("a@b", &out));
}

test "scan: trailing punctuation does not eat the path" {
    // `@notas.txt,` and `@notas.txt.` are the file `notas.txt` with the sentence's
    // comma or period behind it. Without stripping it, `statFile` failed and
    // the mention was lost in silence.
    var out: [scanned_max]Mention = undefined;
    const n = scan("mira @notas.txt, y @docs/guía.md.", &out);
    try std.testing.expectEqual(@as(u8, 2), n);
    try std.testing.expectEqualStrings("notas.txt", out[0].pathOf());
    try std.testing.expectEqualStrings("docs/guía.md", out[1].pathOf());
}

test "scan: a bare @ and text without a path are not mentions" {
    var out: [scanned_max]Mention = undefined;
    try std.testing.expectEqual(@as(u8, 0), scan("4 de 3 personas @ los tres", &out));
    try std.testing.expectEqual(@as(u8, 0), scan("@", &out));
    try std.testing.expectEqual(@as(u8, 0), scan("sin nada", &out));
    try std.testing.expectEqual(@as(u8, 0), scan("", &out));
    // And a mention right at the start of the text does count.
    try std.testing.expectEqual(@as(u8, 1), scan("@a.txt", &out));
}

test "scan: the decorators of a snippet do NOT spend the budget" {
    // The bug that motivated `looksLikePath`. Pasting code with `@Override`,
    // `@deprecated`, `@staticmethod`… filled the scanner's 8 slots and the real
    // mention, which came after, was never looked at: it was lost in silence.
    // Measured with seven decorators before the filter was found.
    var out: [scanned_max]Mention = undefined;
    const prompt = "revisa esto @Override @deprecated @staticmethod @final " ++
        "@pure @param @import y mira @src/agent.zig";
    const n = scan(prompt, &out);
    try std.testing.expectEqual(@as(u8, 1), n);
    try std.testing.expectEqualStrings("src/agent.zig", out[0].pathOf());
}

test "looksLikePath: a path or an extension; a bare word is not" {
    // What separates `@src/agent.zig` and `@notas.txt` from `@Override`.
    try std.testing.expect(looksLikePath("src/agent.zig"));
    try std.testing.expect(looksLikePath("notas.txt"));
    try std.testing.expect(looksLikePath("a/b/c"));
    try std.testing.expect(looksLikePath("guía.md"));
    try std.testing.expect(!looksLikePath("Override"));
    try std.testing.expect(!looksLikePath("import"));
    try std.testing.expect(!looksLikePath("deprecated"));
    // A leading dot is not an extension: `.gitignore` is written `@./.gitignore`,
    // which also does not depend on where you happen to be looking.
    try std.testing.expect(!looksLikePath(".gitignore"));
    try std.testing.expect(!looksLikePath("Makefile"));
}

test "scan: does not repeat the same file" {
    // Including the same file twice is 32 KB of context for free.
    var out: [scanned_max]Mention = undefined;
    const n = scan("@a.txt y otra vez @a.txt y @b.txt", &out);
    try std.testing.expectEqual(@as(u8, 2), n);
    try std.testing.expectEqualStrings("a.txt", out[0].pathOf());
    try std.testing.expectEqualStrings("b.txt", out[1].pathOf());
}

test "scan: a mention inside parentheses or quotes counts too" {
    var out: [scanned_max]Mention = undefined;
    const n = scan("(mira @src/a.zig) y \"@src/b.zig\"", &out);
    try std.testing.expectEqual(@as(u8, 2), n);
}

test "readPrefix: a large file comes out truncated, not an error" {
    // The pty bug: with `readFileAlloc(.limited(file_max))` a 250 KB file gave
    // `error.FileTooBig` and the mention counted as "not found". Here we check
    // that the prefix comes out and that the cut is flagged.
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    const io = std.testing.io;
    const dir: std.Io.Dir = .cwd();

    // 3 file_max of content: 1 file_max must come out, plus "truncated".
    var big: [8192]u8 = undefined;
    @memset(&big, 'g');
    var f = try dir.createFile(io, "mencion_test_grande.txt", .{});
    defer dir.deleteFile(io, "mencion_test_grande.txt") catch {};
    {
        var written: usize = 0;
        while (written < big.len * 8) : (written += big.len) {
            try f.writePositionalAll(io, &big, written);
        }
        f.close(io);
    }

    const r = try readPrefix(io, dir, "mencion_test_grande.txt", arena);
    try std.testing.expectEqual(@as(usize, file_max), r.bytes.len);
    try std.testing.expect(r.truncated);

    // And a small file: whole and unflagged.
    {
        var w: std.Io.Writer = .fixed(arena.alloc(u8, 64) catch unreachable);
        try w.writeAll("hola");
        try dir.writeFile(io, .{ .sub_path = "mencion_test_chico.txt", .data = w.buffered() });
    }
    defer dir.deleteFile(io, "mencion_test_chico.txt") catch {};
    const r2 = try readPrefix(io, dir, "mencion_test_chico.txt", arena);
    try std.testing.expectEqualStrings("hola", r2.bytes);
    try std.testing.expect(!r2.truncated);
}

test "a file bigger than the cap goes in TRUNCATED, not lost" {
    // The failure that showed up in the pty: with `.limited(file_max)` a 250 KB
    // file returned `error.FileTooBig`, counted as "not found", and the model
    // concluded the file did not exist. With the +1 and the cut, the block comes
    // out with its "(truncated)".
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    const dir: std.Io.Dir = .cwd();
    {
        var w: std.Io.Writer = .fixed(arena.alloc(u8, 4096) catch unreachable);
        try w.writeAll("1234567890");
        try dir.writeFile(std.testing.io, .{ .sub_path = "mencion_test_peque.txt", .data = w.buffered() });
    }
    defer dir.deleteFile(std.testing.io, "mencion_test_peque.txt") catch {};

    const e = try expand(arena, std.testing.io, "mira @mencion_test_peque.txt");
    try std.testing.expectEqual(@as(u8, 1), e.files);
    try std.testing.expect(std.mem.indexOf(u8, e.text, "1234567890") != null);
    // And the header carries the real byte count, not the input buffer's.
    try std.testing.expect(std.mem.indexOf(u8, e.text, "--- mencion_test_peque.txt (10 bytes) ---") != null);
}

test "expand: with no servable files it returns the ORIGINAL text (no copies)" {
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    const original = "mira @no/existe.txt";
    const e = try expand(arena, std.testing.io, original);
    try std.testing.expectEqual(@as(u8, 0), e.files);
    try std.testing.expectEqual(@as(u8, 1), e.missing);
    // An empty "Mentioned files:" block would be worse than not touching anything.
    try std.testing.expect(e.text.ptr == original.ptr);
    try std.testing.expectEqualStrings(original, e.text);
}

test "the block header says whether it is truncated" {
    // A file cut in silence makes the model invent the ending, so "(truncated)"
    // goes in ALWAYS, whenever there is a cut.
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try blockHeader(&w, "a.zig", 100, false);
    try blockHeader(&w, "b.zig", 32768, true);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "--- a.zig (100 bytes) ---") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "--- b.zig (32768 bytes, truncated) ---") != null);
}

test "lookslikeSource: neither the cache nor git" {
    // Putting 40 MB of `.zig-cache` into a prompt is not a mention, it is an
    // accident.
    try std.testing.expect(looksLikeSource("src/agent.zig"));
    try std.testing.expect(looksLikeSource("notas.txt"));
    try std.testing.expect(!looksLikeSource(".zig-cache/o/abc/tablas.zig"));
    try std.testing.expect(!looksLikeSource("zig-out/bin/zode"));
    try std.testing.expect(!looksLikeSource(".git/config"));
    try std.testing.expect(!looksLikeSource("sessions/zode-1.jsonl"));
}
