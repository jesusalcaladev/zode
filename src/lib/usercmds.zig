//! User slash commands: markdown files that become prompts.
//!
//! A command is one file:
//!
//!     .zode/commands/review.md          (this project)
//!     ~/.config/zode/commands/review.md (yours, in every project)
//!
//! with optional frontmatter, the same shape a skill uses:
//!
//!     ---
//!     description: review the diff against the task
//!     ---
//!     Review the uncommitted changes in this repo. Focus on ...
//!
//! `/review the last commit` sends the BODY as the prompt. The arguments go
//! where the template says: every `$ARGUMENTS` is replaced (all occurrences),
//! and a template that never mentions them gets them appended after a blank
//! line — so a one-line command works without knowing the placeholder exists.
//!
//! Two rules taken straight from skills, because they are the same problem:
//!
//! - **Project SHADOWS personal**, it does not merge: `.zode/commands/review.md`
//!   replaces the user's own `review.md` entirely. The project's way of working
//!   beats a global default, and a half-overridden default is worse than none.
//! - **Only the name and the description are kept in memory.** The body is read
//!   at RUN time: the `/` completion asks for the list on every keystroke, and a
//!   file edited while zode is open should take effect without a restart.
//!
//! Everything here is testable without a TUI: `scan` and `render` take the disk
//! as a parameter (tests point them at a temp dir), and `validName`,
//! `descFrom`, `expand` and `expandedLen` are pure.

const std = @import("std");
const skills = @import("skills.zig");

const usercmds = @This();

/// Where they live, relative to the cwd and to `~/.config`.
pub const project_dir = ".zode/commands";
pub const user_subdir = "zode/commands";

/// Above this a file is not a command, it is a document (same order as
/// `skills.max_body`): a 500 KB prompt read on every invocation costs more
/// than the task it was written for.
pub const max_body = 64 * 1024;

/// Past this the LIST itself becomes the tax (same reasoning as the skills
/// listing, which is under a BUDGET now): they stay on disk, they are just
/// not offered.
pub const max_cmds = 48;

pub const max_name = 40;
pub const max_desc = 120;

/// One discovered command. Fixed buffers and no pointers: the list lives in a
/// static array for the whole session, and a slice into a temp would be the
/// dangling-pointer family this repo has hit a dozen times.
pub const Entry = struct {
    name_buf: [max_name]u8 = undefined,
    name_len: u8 = 0,
    /// `/<name>`, ready for `Cmd.key`: the `/` completion compares WITH the
    /// slash, the dispatch token arrives WITHOUT it.
    key_buf: [max_name + 1]u8 = undefined,
    key_len: u8 = 0,
    desc_buf: [max_desc]u8 = undefined,
    desc_len: u16 = 0,
    /// Which root of the scan it came from, so the path can be rebuilt later
    /// without keeping a (possibly long) absolute path per entry.
    root: u8 = 0,

    pub fn name(self: *const Entry) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn key(self: *const Entry) []const u8 {
        return self.key_buf[0..self.key_len];
    }

    pub fn desc(self: *const Entry) []const u8 {
        return self.desc_buf[0..self.desc_len];
    }

    fn set(self: *Entry, base: []const u8, root_index: u8, description: []const u8) void {
        @memcpy(self.name_buf[0..base.len], base);
        self.name_len = @intCast(base.len);
        self.key_buf[0] = '/';
        @memcpy(self.key_buf[1 .. 1 + base.len], base);
        self.key_len = @intCast(base.len + 1);
        self.desc_len = @intCast(clipInto(self.desc_buf[0..], description).len);
        self.root = root_index;
    }
};

/// A file name that can be typed: 1..max_name-1 of letters, digits, `-`, `_`.
///
/// Deliberately narrow — `my.cmd.md` strips to `my.cmd`, and a name with a dot
/// cannot be typed unambiguously after a slash anyway.
pub fn validName(n: []const u8) bool {
    if (n.len == 0 or n.len >= max_name) return false;
    for (n) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

/// The description shown by `/help`, the palette and the completion: the
/// frontmatter's `description`, else the first non-empty line of the body that
/// is not a heading. Clipped on a UTF-8 boundary with `…` — a half codepoint
/// is what makes a status line render as `�`.
pub fn descFrom(text: []const u8, out: []u8) []const u8 {
    const fm = skills.splitFrontmatter(text);
    if (fm) |f| {
        if (f.meta.description.len > 0) return clipInto(out, f.meta.description);
    }
    const body = if (fm) |f| f.body else text;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue; // a heading is structure, not a description
        return clipInto(out, line);
    }
    return out[0..0];
}

/// Copies `s` into `out`; when it does not fit, it is cut on a codepoint
/// boundary and marked with a 3-byte `…` (reserved BEFORE the cut, so neither
/// the marker overflows the buffer nor the cut splits a character).
fn clipInto(out: []u8, s: []const u8) []const u8 {
    if (s.len <= out.len) {
        @memcpy(out[0..s.len], s);
        return out[0..s.len];
    }
    const limit = if (out.len >= 4) out.len - 3 else out.len;
    var cut = limit;
    // Back off while `s[cut]` is a CONTINUATION byte (10xxxxxx): that means the
    // limit landed inside a character, and the prefix is only whole at its
    // start. Stopping ON a lead byte is correct — the character starts there
    // and the prefix does not include it.
    while (cut > 0 and (s[cut] & 0xC0) == 0x80) cut -= 1;
    @memcpy(out[0..cut], s[0..cut]);
    if (out.len >= 4) {
        @memcpy(out[cut .. cut + 3], "…");
        return out[0 .. cut + 3];
    }
    return out[0..cut];
}

/// How many bytes `expand` writes for this (body, args).
pub fn expandedLen(body: []const u8, args: []const u8) usize {
    const slots = countArgSlots(body);
    if (slots > 0) {
        // Every `$ARGUMENTS` (11 bytes) becomes `args.len` bytes.
        return body.len - slots * "$ARGUMENTS".len + slots * args.len;
    }
    if (args.len > 0) return body.len + 2 + args.len;
    return body.len;
}

/// Writes the expanded prompt into `out` and returns the written prefix.
/// `null` when `out` is too small — size it with `expandedLen` first.
/// `?[]u8` and not `?[]const u8`: it is a view of the caller's own buffer, and
/// `render` returns it as the prompt it owns — const would need a cast there.
///
/// `$ARGUMENTS` with no arguments substitutes the empty string: the template
/// asked for them and there are none, and that is the only reading that keeps
/// `expandedLen` exact.
pub fn expand(body: []const u8, args: []const u8, out: []u8) ?[]u8 {
    const need = expandedLen(body, args);
    if (out.len < need) return null;

    if (countArgSlots(body) > 0) {
        var w: usize = 0;
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, body, i, "$ARGUMENTS")) |at| {
            @memcpy(out[w .. w + (at - i)], body[i..at]);
            w += at - i;
            @memcpy(out[w .. w + args.len], args);
            w += args.len;
            i = at + "$ARGUMENTS".len;
        }
        @memcpy(out[w .. w + (body.len - i)], body[i..]);
        w += body.len - i;
        return out[0..w];
    }
    if (args.len > 0) {
        @memcpy(out[0..body.len], body);
        out[body.len] = '\n';
        out[body.len + 1] = '\n';
        @memcpy(out[body.len + 2 ..][0..args.len], args);
        return out[0 .. body.len + 2 + args.len];
    }
    @memcpy(out[0..body.len], body);
    return out[0..body.len];
}

fn countArgSlots(body: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, body, i, "$ARGUMENTS")) |at| {
        n += 1;
        i = at + "$ARGUMENTS".len;
    }
    return n;
}

/// The prompt a file describes, expanded with what the user typed after the
/// command. Owned by the caller — `[]u8`, so a literal cannot be returned by
/// mistake (the ownership-in-the-signature rule).
///
/// `null` covers the three ways this ends without a prompt: the file is gone,
/// it is over `max_body` (`readFileAlloc(.limited(n))` refuses instead of
/// clipping, which is what keeps a 500 KB paste from becoming a prompt), or
/// there is no memory for the expansion.
pub fn render(gpa: std.mem.Allocator, io: std.Io, path: []const u8, args: []const u8) ?[]u8 {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_body)) catch return null;
    defer gpa.free(text);
    const fm = skills.splitFrontmatter(text);
    const body = if (fm) |f| f.body else text;
    const out = gpa.alloc(u8, expandedLen(body, args)) catch return null;
    return expand(body, args, out) orelse {
        gpa.free(out);
        return null;
    };
}

/// Walks every root in order and fills `out`; an earlier root SHADOWS a later
/// one with the same name (project first is the caller's contract, same as
/// skills). Returns the slice that was filled, up to `out.len`.
///
/// The caller OWNS `out` (a static array or a stack one). Nothing here
/// allocates beyond the per-file read used for the description, which is freed
/// before the next iteration.
pub fn scan(
    gpa: std.mem.Allocator,
    io: std.Io,
    roots: []const []const u8,
    out: []Entry,
) []Entry {
    var n: usize = 0;
    // One path buffer, reused per file: it is used IMMEDIATELY for the read and
    // never stored — a stored slice here would point at the last path written
    // (the `sb.path` trap).
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;

    for (roots, 0..) |dir_path, ri| {
        if (dir_path.len == 0) continue;
        var d = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
        defer d.close(io);

        var it = d.iterate();
        while (it.next(io) catch null) |ent| {
            if (n >= out.len) return out[0..n];
            // Commands are FILES. A directory named `review.md` is not one;
            // `.sym_link` is accepted so a command can live in a dotfiles repo.
            if (ent.kind != .file and ent.kind != .sym_link) continue;
            const dot = std.mem.lastIndexOf(u8, ent.name, ".md") orelse continue;
            if (dot == 0 or dot + 3 != ent.name.len) continue;
            const base = ent.name[0..dot];
            if (base.len == 0 or base[0] == '.') continue; // skip dotfiles
            if (!validName(base)) continue;
            // README is documentation, not a runnable command.
            if (std.ascii.eqlIgnoreCase(base, "README")) continue;
            if (alreadyIn(out[0..n], base)) continue; // the first root wins

            const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, ent.name }) catch continue;
            const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_body)) catch |err| {
                if (err == error.FileTooBig) {
                    // Listed WITH the reason instead of hidden: a command that
                    // silently does not exist is one the user debugs forever,
                    // and running it says the same "over 64 KB".
                    out[n].set(base, @intCast(ri), "(over 64 KB: too big to load)");
                    n += 1;
                }
                continue;
            };
            defer gpa.free(text);

            var desc_buf: [max_desc]u8 = undefined;
            const desc = descFrom(text, &desc_buf);
            out[n].set(base, @intCast(ri), desc);
            n += 1;
        }
    }
    return out[0..n];
}

fn alreadyIn(list: []const Entry, base: []const u8) bool {
    for (list) |e| {
        if (std.mem.eql(u8, e.name(), base)) return true;
    }
    return false;
}

// ── tests ────────────────────────────────────────────────────────────

// The temp helpers follow skillstore's: fixtures under a seeded dir of the
// CWD, deleted after — writing into the REAL `.zode/commands` of whoever runs
// the suite would leave junk in their repo, and a test that writes into
// `~/.config` is the mistake the June fuzzer made with `auth.json`.
fn tmpRoot(out: []u8) ![]const u8 {
    return std.fmt.bufPrint(out, ".zode-cmds-test-{d}", .{std.testing.random_seed});
}

fn writeFixture(root: []const u8, rel: []const u8, body: []const u8) !void {
    var buf: [512]u8 = undefined;
    const full = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ root, rel });
    if (std.fs.path.dirname(full)) |dir| {
        try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    }
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = full, .data = body });
}

test "validName: what can be typed after a slash, and what cannot" {
    try std.testing.expect(validName("review"));
    try std.testing.expect(validName("review-pr_2"));
    try std.testing.expect(validName("A9"));
    try std.testing.expect(!validName(""));
    try std.testing.expect(!validName("with space"));
    try std.testing.expect(!validName("my.cmd"));
    try std.testing.expect(!validName("a/b"));
    // Exactly max_name is one too many: the key adds a slash on top.
    var too_long: [max_name]u8 = undefined;
    @memset(&too_long, 'a');
    try std.testing.expect(!validName(&too_long));
    try std.testing.expect(validName(too_long[0 .. max_name - 1]));
}

test "descFrom: frontmatter wins, then the first real line (never a heading)" {
    var out: [max_desc]u8 = undefined;
    const with_fm = descFrom(
        "---\ndescription: when to use it\n---\n# Title\nbody line",
        &out,
    );
    try std.testing.expectEqualStrings("when to use it", with_fm);

    var out2: [max_desc]u8 = undefined;
    const no_fm = descFrom("# Title\n\nThe first real line.\nsecond", &out2);
    try std.testing.expectEqualStrings("The first real line.", no_fm);

    var out3: [max_desc]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), descFrom("\n# only a heading\n", &out3).len);
}

test "descFrom: a long description is clipped on a codepoint boundary with an ellipsis" {
    // "á" is 2 bytes (C3 A1). With an odd buffer the raw cut WOULD land
    // between its bytes, so the clip has to walk back to the character start.
    var out: [11]u8 = undefined; // room for 8 bytes of text + the 3-byte marker
    const s = "áááááááá"; // 16 bytes of valid UTF-8
    const got = descFrom(s, &out);
    try std.testing.expect(std.unicode.utf8ValidateSlice(got));
    try std.testing.expectEqual(@as(usize, 11), got.len);
    try std.testing.expectEqualStrings("…", got[got.len - 3 ..]);
}

test "expand: $ARGUMENTS everywhere, appended when never mentioned, exact length" {
    var buf: [256]u8 = undefined;

    const a = expand("Do X: $ARGUMENTS and again $ARGUMENTS", "it", &buf).?;
    try std.testing.expectEqualStrings("Do X: it and again it", a);
    try std.testing.expectEqual(a.len, expandedLen("Do X: $ARGUMENTS and again $ARGUMENTS", "it"));

    const b = expand("Plain body", "the args", &buf).?;
    try std.testing.expectEqualStrings("Plain body\n\nthe args", b);
    try std.testing.expectEqual(b.len, expandedLen("Plain body", "the args"));

    // No args: the placeholder substitutes the empty string (exact, not padded).
    const c = expand("Ask: $ARGUMENTS", "", &buf).?;
    try std.testing.expectEqualStrings("Ask: ", c);
    try std.testing.expectEqual(c.len, expandedLen("Ask: ", ""));

    // An undersized buffer is refused, not overrun.
    var tiny: [3]u8 = undefined;
    try std.testing.expect(expand("Plain body", "the args", &tiny) == null);
}

test "render: frontmatter stripped, args expanded, caller owns the result" {
    var root_buf: [256]u8 = undefined;
    const root = try tmpRoot(&root_buf);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try writeFixture(root, "review.md",
        \\---
        \\description: review the diff
        \\---
        \\Review $ARGUMENTS against the task.
    );

    // std.testing.allocator as the REAL allocator (not an arena): the render
    // result is gpa-owned, and the leak check on that exact pair is the point.
    var path_buf: [320]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/review.md", .{root});
    const got = render(std.testing.allocator, std.testing.io, path, "the last commit") orelse
        return error.TestUnexpectedResult;
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("Review the last commit against the task.", got);
}

test "render: a missing file is null, not an empty prompt" {
    try std.testing.expect(render(
        std.testing.allocator,
        std.testing.io,
        ".zode-cmds-test-definitely-missing/nope.md",
        "",
    ) == null);
}

test "scan: finds the commands, project first, and the non-files are not commands" {
    var root_buf: [256]u8 = undefined;
    const root = try tmpRoot(&root_buf);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try writeFixture(root, "proj/review.md",
        \\---
        \\description: the project's review
        \\---
        \\body
    );
    try writeFixture(root, "home/tidy.md", "Straight body line\nmore");
    try writeFixture(root, "home/review.md",
        \\---
        \\description: the user's own review (must be shadowed)
        \\---
        \\body
    );
    // Not commands: a directory named `review.md`, a file with another
    // extension, a name that cannot be typed, and a loose README.
    try writeFixture(root, "proj/dir.md/inside.md", "x");
    try writeFixture(root, "proj/notes.txt", "x");
    try writeFixture(root, "proj/with space.md", "x");
    try writeFixture(root, "proj/README.md", "# just a readme");

    // Separate buffers for root and each root path: every path has to survive
    // the loop, and one shared scratch would leave them all pointing at the
    // last one written (the `sb.path` trap this repo has already paid for).
    var proj_buf: [300]u8 = undefined;
    const proj = try std.fmt.bufPrint(&proj_buf, "{s}/proj", .{root});
    var home_buf: [300]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buf, "{s}/home", .{root});
    var roots = [_][]const u8{ proj, home };

    var entries: [8]Entry = undefined;
    const found = scan(std.testing.allocator, std.testing.io, &roots, &entries);

    try std.testing.expectEqual(@as(usize, 2), found.len);
    // Project first: `review` is the PROJECT's, and `tidy` comes after.
    try std.testing.expectEqualStrings("review", found[0].name());
    try std.testing.expectEqualStrings("/review", found[0].key());
    try std.testing.expectEqualStrings("the project's review", found[0].desc());
    try std.testing.expectEqual(@as(u8, 0), found[0].root);
    try std.testing.expectEqualStrings("tidy", found[1].name());
    try std.testing.expectEqualStrings("Straight body line", found[1].desc());
    try std.testing.expectEqual(@as(u8, 1), found[1].root);
}

test "scan: the cap stops the list instead of overflowing it" {
    var root_buf: [256]u8 = undefined;
    const root = try tmpRoot(&root_buf);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try writeFixture(root, "one/a.md", "a");
    try writeFixture(root, "one/b.md", "b");

    var one_buf: [300]u8 = undefined;
    const one = try std.fmt.bufPrint(&one_buf, "{s}/one", .{root});
    var roots = [_][]const u8{one};

    var entries: [1]Entry = undefined;
    const found = scan(std.testing.allocator, std.testing.io, &roots, &entries);
    try std.testing.expectEqual(@as(usize, 1), found.len);
}
