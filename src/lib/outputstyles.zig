//! Output styles: instruction blocks the model can opt into with `/style`.
//!
//! Only the name and description of each style go into the system prompt.
//! The style block is injected at the END of the composed prompt, after every
//! other block. A style's body is loaded on demand.
//!
//! An output style is a directory with an `OUTPUT_STYLE.md`:
//!
//! ```text
//! .zode/output-styles/explanatory/OUTPUT_STYLE.md
//! ```
//!
//! with optional frontmatter:
//!
//! ```markdown
//! ---
//! name: explanatory
//! description: Explain every step before taking it
//! keep_coding_instructions: true
//! ---
//! # Explaining Style
//! ...the actual style instructions...
//! ```
//!
//! `keep_coding_instructions` controls whether the harness's own coding rules
//! (the "How to work" section of the base prompt) are kept alongside the style.
//! When `false`, the style replaces them entirely.
//!
//! Search order is project-first and it is not a merge: a project style shadows
//! a user style with the same name. Bundled styles ship with the binary and can
//! be shadowed by either.

const std = @import("std");

const outputstyles = @This();

/// File that holds a style.
pub const filename = "OUTPUT_STYLE.md";

/// Directories, in order. The first one that has a style wins for that name.
pub const project_dir = ".zode/output-styles";
pub const user_subdir = "zode/output-styles";

/// Above this a style is not a style, it is a document.
pub const max_body = 64 * 1024;

/// Styles in the prompt. Past this the LIST itself becomes the tax.
pub const max_listed = 40;

/// One style's frontmatter.
pub const Meta = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    /// Whether the harness's coding rules stay alongside this style. When
    /// false, the style replaces them entirely.
    keep_coding_instructions: bool = true,
};

/// Splits the frontmatter from the body.
///
/// `null` when there is no frontmatter, which is legal: a style can be just a
/// markdown file. Returns slices into `text`.
///
/// The parser is hand-written and DELIBERATELY narrow: `key: value` lines, one
/// `---`-fenced block at the top, `#` comments inside it. It does not do YAML.
pub fn splitFrontmatter(text: []const u8) ?struct { meta: Meta, body: []const u8 } {
    const trimmed = std.mem.trimStart(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "---")) return null;
    const after = trimmed[3..];
    // The fence has to be at the start of a line: a `---` inside prose is a
    // horizontal rule, not a frontmatter opener.
    if (after.len > 0 and after[0] != '\n' and after[0] != '\r') return null;

    var rest = after;
    if (std.mem.startsWith(u8, rest, "\r\n")) rest = rest[2..] else if (rest.len > 0 and rest[0] == '\n') rest = rest[1..];

    var meta = Meta{};
    var i: usize = 0;
    while (i < rest.len) {
        const nl = std.mem.indexOfScalar(u8, rest[i..], '\n') orelse rest.len - i;
        const line = rest[i .. i + nl];
        i = @min(i + nl + 1, rest.len);
        const t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, t, "---")) {
            return .{ .meta = meta, .body = std.mem.trimStart(u8, rest[i..], " \t\r\n") };
        }
        if (t.len == 0 or t[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, t, ':') orelse continue;
        const key = std.mem.trim(u8, t[0..colon], " \t");
        var val = std.mem.trim(u8, t[colon + 1 ..], " \t");
        if (val.len >= 2 and ((val[0] == '"' and val[val.len - 1] == '"') or
            (val[0] == '\'' and val[val.len - 1] == '\'')))
        {
            val = val[1 .. val.len - 1];
        }
        if (std.mem.eql(u8, key, "name")) {
            meta.name = val;
        } else if (std.mem.eql(u8, key, "description")) {
            meta.description = val;
        } else if (std.mem.eql(u8, key, "keep_coding_instructions")) {
            meta.keep_coding_instructions = std.ascii.eqlIgnoreCase(val, "true");
        }
    }
    return null; // unterminated frontmatter
}

/// A valid name: lowercase letters, digits, `-`, `_`.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        if (!((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-' or c == '_')) return false;
    }
    return true;
}

/// The name to use when the frontmatter does not give one: the DIRECTORY name.
pub fn nameFor(meta: Meta, dir_name: []const u8) []const u8 {
    if (meta.name.len > 0 and validName(meta.name)) return meta.name;
    return dir_name;
}

/// Style source for shadowing precedence.
pub const Source = enum {
    project,
    user,
    bundled,
};

/// One style as discovered on disk (or bundled).
pub const Entry = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    path: []const u8 = "",
    body: ?[]const u8 = null,
    source: Source = .project,
    keep_coding_instructions: bool = true,
};

/// Text for a selected style: the body, framed so the model knows what it has.
pub fn formatStyle(
    name: []const u8,
    description: []const u8,
    body: []const u8,
    out: []u8,
) []const u8 {
    var w: std.Io.Writer = .fixed(out);
    w.print("=== output style: {s} ===\n", .{name}) catch {};
    if (description.len > 0) w.print("use when: {s}\n", .{description}) catch {};
    w.writeAll("\n") catch {};
    const t = std.mem.trim(u8, body, " \t\r\n");
    w.writeAll(t) catch {};
    return w.buffered();
}

/// The paragraph the system prompt carries when NO style is selected.
pub fn systemPromptSection(entries: []const Entry, out: []u8) []const u8 {
    if (entries.len == 0) return "";
    var w: std.Io.Writer = .fixed(out);
    w.writeAll(
        \\
        \\Output styles — instruction blocks you can select with `/style <name>`.
        \\Only names and descriptions are listed; the body is loaded when selected.
        \\
    ) catch {};
    const n = @min(entries.len, max_listed);
    for (entries[0..n]) |e| {
        const d = if (e.description.len > 0) e.description else "(no description — read it before trusting it)";
        w.print("- {s}: {s}\n", .{ e.name, d }) catch {};
    }
    if (entries.len > n) {
        w.print("- … and {d} more, selectable by name with `/style`\n", .{entries.len - n}) catch {};
    }
    return w.buffered();
}

test "splitFrontmatter: separates meta and body" {
    const text =
        \\---
        \\name: explanatory
        \\description: Explain every step before taking it
        \\keep_coding_instructions: true
        \\---
        \\
        \\# Explaining Style
        \\body here
    ;
    const r = outputstyles.splitFrontmatter(text) orelse return error.NoFrontmatter;
    try std.testing.expectEqualStrings("explanatory", r.meta.name);
    try std.testing.expectEqualStrings("Explain every step before taking it", r.meta.description);
    try std.testing.expect(r.meta.keep_coding_instructions == true);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "# Explaining Style") != null);
    try std.testing.expect(std.mem.startsWith(u8, r.body, "# Explaining Style"));
    try std.testing.expect(std.mem.indexOf(u8, r.body, "---") == null);
}

test "splitFrontmatter: keep_coding_instructions false" {
    const text =
        \\---
        \\name: minimalist
        \\description: Just do it, no lecturing
        \\keep_coding_instructions: false
        \\---
        \\
        \\# Minimalist
        \\Do the thing.
    ;
    const r = outputstyles.splitFrontmatter(text) orelse return error.NoFrontmatter;
    try std.testing.expectEqualStrings("minimalist", r.meta.name);
    try std.testing.expect(r.meta.keep_coding_instructions == false);
}

test "splitFrontmatter: quotes, comments and CRLF" {
    const text =
        \\---
        \\# a comment
        \\name: "quoted-name"
        \\description: 'single quoted'
        \\keep_coding_instructions: false
        \\extra: ignored
        \\---
        \\body
    ;
    const r = outputstyles.splitFrontmatter(text) orelse return error.NoFrontmatter;
    try std.testing.expectEqualStrings("quoted-name", r.meta.name);
    try std.testing.expectEqualStrings("single quoted", r.meta.description);
    try std.testing.expect(r.meta.keep_coding_instructions == false);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "body") != null);
}

test "splitFrontmatter: a file that ENDS at the fence does not blow up" {
    const no_newline = "---\nname: x\ndescription: y\n---";
    const r = outputstyles.splitFrontmatter(no_newline) orelse return error.NoFrontmatter;
    try std.testing.expectEqualStrings("x", r.meta.name);
    try std.testing.expectEqualStrings("y", r.meta.description);
    try std.testing.expect(r.meta.keep_coding_instructions == true); // default
}

test "splitFrontmatter: no frontmatter returns null" {
    const r = outputstyles.splitFrontmatter("just a markdown file\nno fence here");
    try std.testing.expect(r == null);
}

test "validName: accepts lowercase digits dash underscore" {
    try std.testing.expect(outputstyles.validName("explanatory"));
    try std.testing.expect(outputstyles.validName("my-style_2"));
    try std.testing.expect(!outputstyles.validName(""));
    try std.testing.expect(!outputstyles.validName("UpperCase"));
    try std.testing.expect(!outputstyles.validName("has space"));
    try std.testing.expect(!outputstyles.validName("has/slash"));
}

test "nameFor: valid frontmatter name wins over directory name" {
    const meta = outputstyles.Meta{ .name = "front-name", .description = "", .keep_coding_instructions = true };
    try std.testing.expect(std.mem.eql(u8, outputstyles.nameFor(meta, "dir-name"), "front-name"));
}

test "nameFor: valid frontmatter name is used" {
    const meta = outputstyles.Meta{ .name = "front-name", .description = "", .keep_coding_instructions = true };
    try std.testing.expect(std.mem.eql(u8, outputstyles.nameFor(meta, "invalid name!"), "front-name"));
}

test "formatStyle: frames the body" {
    var buf: [256]u8 = undefined;
    const out = outputstyles.formatStyle("explanatory", "Explain steps", "# Hello\nbody text", &buf);
    try std.testing.expect(std.mem.startsWith(u8, out, "=== output style: explanatory ==="));
    try std.testing.expect(std.mem.indexOf(u8, out, "use when: Explain steps") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "# Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "body text") != null);
}

test "systemPromptSection: empty list returns empty string" {
    var buf: [64]u8 = undefined;
    const empty: []const outputstyles.Entry = &[_]outputstyles.Entry{};
    const out = outputstyles.systemPromptSection(empty, &buf);
    try std.testing.expect(out.len == 0);
}

test "systemPromptSection: lists styles" {
    var buf: [512]u8 = undefined;
    const entries = [_]outputstyles.Entry{
        .{ .name = "default", .description = "Standard behavior" },
        .{ .name = "explanatory", .description = "Explain every step" },
    };
    const out = outputstyles.systemPromptSection(&entries, &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "- default: Standard behavior") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "- explanatory: Explain every step") != null);
}

test "systemPromptSection: truncates past max_listed" {
    var entries: [45]outputstyles.Entry = undefined;
    var names: [45][]const u8 = undefined;
    var count: usize = 0;
    for (0..45) |i| {
        const name = std.fmt.allocPrint(std.testing.allocator, "style-{d}", .{i}) catch continue;
        names[count] = name;
        entries[count] = .{ .name = name, .description = "desc {d}" };
        count += 1;
    }
    var buf: [2048]u8 = undefined;
    const out = outputstyles.systemPromptSection(entries[0..count], &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "… and 5 more") != null);
    for (names[0..count]) |name| {
        std.testing.allocator.free(name);
    }
}