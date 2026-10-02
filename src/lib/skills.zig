//! Skills: instruction directories the model can pull in ON DEMAND.
//!
//! The design is the whole point, so it is worth stating plainly: **only the name
//! and the description of each skill go into the system prompt. The body is read
//! when the model asks for it, and not before.**
//!
//! The alternative — inlining every skill — is how a project ends up with 40 KB
//! of instructions the model has already learned to skip, on every single
//! request, forever, whether or not the task touches them. On-demand loading is
//! what makes a library of skills affordable instead of a tax. It is the same
//! reasoning as `@file`, and the same as the `todo` tool existing to be cheap.
//!
//! A skill is a directory with a `SKILL.md`:
//!
//! ```
//! .zode/skills/pty-tests/SKILL.md
//! ```
//!
//! with optional frontmatter:
//!
//! ```markdown
//! ---
//! name: pty-tests
//! description: Verify a TUI change in a real pty, not a homemade emulator
//! ---
//!
//! # Verifying a TUI
//! ...the actual instructions...
//! ```
//!
//! `description` is the important field: it is the ONLY thing the model sees
//! before deciding, so it has to say WHEN to use the skill, not what it is. A
//! description that says what the skill is ("notes about pty") makes the model
//! guess; one that says when ("use after any change to tui.zig drawing code")
//! makes it decide correctly.
//!
//! Search order is project-first and it is not a merge: a project skill SHADOWS a
//! user skill with the same name. A project that overrides a global skill is the
//! expected case (this repo documents its own pty rules, which are stricter than
//! anyone's default).

const std = @import("std");

const skills = @This();

/// File that holds a skill.
pub const filename = "SKILL.md";

/// Directories, in order. The first one that has a skill wins for that name.
pub const project_dir = ".zode/skills";
/// The cross-agent convention, so a skill written for another harness works here
/// without being copied. It is scanned right after `project_dir` and BEFORE the
/// user's own: a project's shared skill beats a personal one, same as `.zode`.
pub const agents_dir = ".agents/skills";
pub const user_subdir = "zode/skills";

/// Above this a skill is not a skill, it is a document. A 500 KB SKILL.md inlined
/// on demand costs more than the task it was supposed to help with.
pub const max_body = 64 * 1024;

/// Bodies longer than this are cut, and the cut is ANNOUNCED in the tool result:
/// a model reading half a skill does not know it is reading half a skill, and
/// will confidently follow instructions that stopped mid-sentence.
pub const max_inline = 32 * 1024;

/// Skills in the prompt. Past this the LIST itself becomes the tax, so the ones
/// that do not fit are not listed at all (they are still loadable by name).
pub const max_listed = 40;

/// One skill's frontmatter.
pub const Meta = struct {
    name: []const u8 = "",
    description: []const u8 = "",
};

/// Splits the frontmatter from the body.
///
/// `null` when there is no frontmatter, which is legal: a skill can be just a
/// markdown file. Returns slices into `text`.
///
/// The parser is hand-written and DELIBERATELY narrow: `key: value` lines, one
/// `---`-fenced block at the top, `#` comments inside it. It does not do YAML.
/// A real YAML parser is 600 lines and a whole set of ways to be surprised by a
/// tab, and the only two keys that matter here are two strings.
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
        // `+ 1` for the newline, and it has to be CLAMPED: when the closing `---`
        // is the last line and the file has no trailing newline, `nl` is 0 and
        // `i` walks one past the end. `rest[i..]` with `i > len` is a panic, not
        // an empty slice — and a `SKILL.md` that ends right at the fence is
        // completely normal to write. (Found by the fixture tests, which is what
        // they are for: the pure tests all had a trailing newline.)
        i = @min(i + nl + 1, rest.len);
        const t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, t, "---")) {
            return .{ .meta = meta, .body = std.mem.trimStart(u8, rest[i..], " \t\r\n") };
        }
        if (t.len == 0 or t[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, t, ':') orelse continue;
        const key = std.mem.trim(u8, t[0..colon], " \t");
        var val = std.mem.trim(u8, t[colon + 1 ..], " \t");
        // Quotes are optional and stripped when present: people write both and
        // the value has to come out the same.
        if (val.len >= 2 and ((val[0] == '"' and val[val.len - 1] == '"') or
            (val[0] == '\'' and val[val.len - 1] == '\'')))
        {
            val = val[1 .. val.len - 1];
        }
        if (std.mem.eql(u8, key, "name")) {
            meta.name = val;
        } else if (std.mem.eql(u8, key, "description")) {
            meta.description = val;
        }
    }
    return null; // unterminated frontmatter
}

/// A valid name: lowercase letters, digits, `-`, `_`. It ends up in a tool call
/// and in a path, so anything else is a footgun.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    }
    return true;
}

/// The name to use when the frontmatter does not give one: the DIRECTORY name.
///
/// The directory name is the reliable identity (it is what shadows, what the tool
/// call passes and what the path says). The frontmatter `name` is the pretty
/// label; when it disagrees with the directory, the directory wins, because a
/// tool call for a name that is not on disk returns "unknown skill" and the model
/// has no way to recover.
pub fn nameFor(meta: Meta, dir_name: []const u8) []const u8 {
    if (meta.name.len > 0 and validName(meta.name)) return meta.name;
    return dir_name;
}

/// One skill as discovered on disk.
pub const Entry = struct {
    /// Valid name, unique across the search path (project shadows user).
    name: []const u8 = "",
    description: []const u8 = "",
    /// Full path of the `SKILL.md`. Owned by the loader.
    path: []const u8 = "",
};

/// Text for the `skill` tool: the body, framed so the model knows what it has.
///
/// The framing is not decoration. Without it the model reads a markdown file with
/// no indication that it is now operating under those instructions, and the most
/// common outcome is that it treats them as reference material and does what it
/// was going to do anyway.
pub fn formatSkill(name: []const u8, description: []const u8, body: []const u8, out: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(out);
    w.print("=== skill: {s} ===\n", .{name}) catch {};
    if (description.len > 0) w.print("use when: {s}\n", .{description}) catch {};
    w.writeAll("\nYou are now following this skill's instructions. If they conflict with what you were told before, they win — that is why they were loaded.\n\n") catch {};
    const t = std.mem.trim(u8, body, " \t\r\n");
    if (t.len <= max_inline) {
        w.writeAll(t) catch {};
    } else {
        w.writeAll(t[0..max_inline]) catch {};
        w.print("\n\n… (skill cut at {d} of {d} bytes: you are reading part of it. If the instructions you need are past this point, say so instead of guessing.)", .{ max_inline, t.len }) catch {};
    }
    return w.buffered();
}

/// The paragraph the system prompt carries.
///
/// Empty when there are no skills: an empty "## Skills" heading with nothing
/// under it is 4 tokens per request forever for no information.
pub fn systemPromptSection(entries: []const Entry, out: []u8) []const u8 {
    if (entries.len == 0) return "";
    var w: std.Io.Writer = .fixed(out);
    w.writeAll(
        \\
        \\Skills — folders of instructions you can load. The list is only names and
        \\when to use them; the instructions cost tokens, so load ONE when the
        \\description matches the task, and load none if none do.
        \\
    ) catch {};
    const n = @min(entries.len, max_listed);
    for (entries[0..n]) |e| {
        const d = if (e.description.len > 0) e.description else "(no description — read it before trusting it)";
        w.print("- {s}: {s}\n", .{ e.name, d }) catch {};
    }
    if (entries.len > n) {
        w.print("- … and {d} more, loadable by name with the `skill` tool\n", .{entries.len - n}) catch {};
    }
    return w.buffered();
}

test "splitFrontmatter: separa meta y cuerpo" {
    const text =
        \\---
        \\name: pty-tests
        \\description: Verify a TUI change in a real pty
        \\---
        \\
        \\# Verifying
        \\body here
    ;
    const r = skills.splitFrontmatter(text) orelse return error.NoFrontmatter;
    try std.testing.expectEqualStrings("pty-tests", r.meta.name);
    try std.testing.expectEqualStrings("Verify a TUI change in a real pty", r.meta.description);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "# Verifying") != null);
    // The body keeps its markdown headings and blank lines: it is markdown that
    // gets handed to the model as-is, so the parser must not reflow it. What
    // matters is that the FRONTMATTER is gone and the heading came through.
    try std.testing.expect(std.mem.startsWith(u8, r.body, "# Verifying"));
    try std.testing.expect(std.mem.indexOf(u8, r.body, "---") == null);
    const body_trimmed = std.mem.trim(u8, r.body, " \t\r\n");
    try std.testing.expectEqualStrings("# Verifying\nbody here", body_trimmed);
}

test "splitFrontmatter: comillas, comentarios y CRLF" {
    const text =
        \\---
        \\# a comment
        \\name: "quoted-name"
        \\description: 'single quoted'
        \\extra: ignored
        \\---
        \\body
    ;
    const r = skills.splitFrontmatter(text) orelse return error.NoFrontmatter;
    try std.testing.expectEqualStrings("quoted-name", r.meta.name);
    try std.testing.expectEqualStrings("single quoted", r.meta.description);
}

test "splitFrontmatter: sin frontmatter es null, y el cuerpo entero es el cuerpo" {
    try std.testing.expect(skills.splitFrontmatter("# just markdown\n\ntext") == null);
    // Un `---` que no esta al principio de linea es una regla horizontal.
    try std.testing.expect(skills.splitFrontmatter("texto --- mas texto") == null);
    // Frontmatter sin cerrar tambien es null (no se inventa meta).
    try std.testing.expect(skills.splitFrontmatter("---\nname: x\nsin cerrar") == null);
}

test "splitFrontmatter: CRLF de verdad" {
    const text = "---\r\nname: crlf\r\ndescription: windows\r\n---\r\nbody\r\n";
    const r = skills.splitFrontmatter(text) orelse return error.NoFrontmatter;
    try std.testing.expectEqualStrings("crlf", r.meta.name);
    try std.testing.expectEqualStrings("windows", r.meta.description);
}

test "validName: lo que se puede meter en un path y en una tool call" {
    try std.testing.expect(skills.validName("pty-tests"));
    try std.testing.expect(skills.validName("skill_2"));
    try std.testing.expect(!skills.validName(""));
    try std.testing.expect(!skills.validName("../escape"));
    try std.testing.expect(!skills.validName("with space"));
    try std.testing.expect(!skills.validName("with/slash"));
    try std.testing.expect(!skills.validName("a" ** 65));
}

test "nameFor: el directorio gana si el frontmatter no sirve" {
    try std.testing.expectEqualStrings("pty-tests", skills.nameFor(.{ .name = "pty-tests" }, "other"));
    // Un name con una barra es peor que ninguno: la tool call fallaria y el
    // modelo no tiene forma de descobrir el nombre bueno.
    try std.testing.expectEqualStrings("dir", skills.nameFor(.{ .name = "bad/name" }, "dir"));
    try std.testing.expectEqualStrings("dir", skills.nameFor(.{}, "dir"));
}

test "formatSkill: el cuerpo va enmarcado, no suelto" {
    var buf: [4096]u8 = undefined;
    const out = skills.formatSkill("pty", "use after any tui change", "# Instructions\n", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "=== skill: pty ===") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "use when: use after any tui change") != null);
    // Y dice explicitamente que ahora mandan estas instrucciones.
    try std.testing.expect(std.mem.indexOf(u8, out, "they win") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "# Instructions") != null);
}

test "formatSkill: un skill cortado lo DICE" {
    var body: [40_000]u8 = @splat('x');
    var buf: [40_000]u8 = undefined;
    const out = skills.formatSkill("big", "", &body, &buf);
    try std.testing.expect(out.len <= buf.len);
    try std.testing.expect(std.mem.indexOf(u8, out, "you are reading part of it") != null);
}

test "systemPromptSection: sin skills no hay seccion (0 tokens por request)" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("", skills.systemPromptSection(&.{}, &buf));
}

test "systemPromptSection: lista nombre + cuando usarla" {
    const entries = [_]skills.Entry{
        .{ .name = "pty-tests", .description = "after any tui drawing change" },
        .{ .name = "no-desc", .description = "" },
    };
    var buf: [2048]u8 = undefined;
    const s = skills.systemPromptSection(&entries, &buf);
    try std.testing.expect(std.mem.indexOf(u8, s, "- pty-tests: after any tui drawing change") != null);
    // Una skill sin descripcion se lista igual, marcada: esconderla la hace
    // inusable y el autor ni se entera.
    try std.testing.expect(std.mem.indexOf(u8, s, "no-desc: (no description") != null);
    // Y NO lleva el cuerpo: ese es el punto entero del diseño.
    try std.testing.expect(std.mem.indexOf(u8, s, "load ONE") != null);
}

test "systemPromptSection: con 50 skills dice cuantas quedan sin listarlas" {
    // Real distinct names, because two skills with the same name would be one
    // skill with a shadowing bug and the test would pass for the wrong reason.
    var entries: [50]skills.Entry = undefined;
    for (&entries, 0..) |*e, i| {
        var nb: [8]u8 = undefined;
        const name = std.fmt.bufPrint(&nb, "skill{d}", .{i}) catch "s";
        e.* = .{ .name = name, .description = "d" };
    }
    var buf: [4096]u8 = undefined;
    const s = skills.systemPromptSection(&entries, &buf);
    try std.testing.expect(s.len <= buf.len);
    try std.testing.expect(std.mem.indexOf(u8, s, "and 10 more") != null);
}

test "splitFrontmatter: un fichero que ACABA en el fence no revienta" {
    // El bug que encontraron los tests de `skillstore`: si la ultima linea es el
    // `---` de cierre y no hay newline final, el indice se pasa una posicion y
    // `rest[i..]` es un PANIC, no un slice vacio. Y un SKILL.md que termina en el
    // fence es lo mas normal del mundo.
    const no_newline = "---\nname: x\ndescription: y\n---";
    const r = skills.splitFrontmatter(no_newline) orelse return error.NoFrontmatter;
    try std.testing.expectEqualStrings("x", r.meta.name);
    try std.testing.expectEqualStrings("y", r.meta.description);
    try std.testing.expectEqualStrings("", r.body);

    // Y con newline, que es el caso de antes, sigue igual.
    const with_newline = "---\nname: x\n---\nbody\n";
    const r2 = skills.splitFrontmatter(with_newline) orelse return error.NoFrontmatter;
    try std.testing.expectEqualStrings("body", std.mem.trim(u8, r2.body, " \t\r\n"));
}
