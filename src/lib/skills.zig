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
//! when_to_use: After any change to tui.zig drawing code
//! argument_hint: Optional path to review
//! allowed_tools: ["read", "grep"]
//! model: ""
//! effort: low
//! context: inline
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
const textcap = @import("textcap.zig");

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

// ── the listing under a budget ─────────────────────────────────

/// The listing's share of the context window, in PERCENT.
///
/// The listing is the part of the prompt that grows with the PROJECT: every
/// skill anybody adds is one more line in every request, forever. A fixed cap
/// does not scale with that — 40 is a lot for a project with five skills and not
/// enough for one with four hundred — and it says nothing about the model the
/// request is going to. A percentage of the window scales with both.
pub const budget_percent = 1;

/// The most an entry's DESCRIPTION contributes to the listing, in columns.
///
/// A description is written for a human, and a long one is a paragraph, not a
/// label. Past this the listing stops being scannable: the model reads the
/// first entry and skips the rest, which is the failure the cap exists to
/// prevent.
pub const max_desc_chars = 250;

/// Chars per token, the same rough factor `compaction.estimateTokens` uses.
///
/// The budget is a share of the CONTEXT, which is counted in tokens, and the
/// listing is measured in characters. This is the conversion, and it is the
/// same 4 the rest of the harness uses on purpose: two factors that disagree
/// would be two budgets for the same thing.
pub const chars_per_token = 4;

/// The most the budget can be, in characters, whatever the window says.
///
/// 1% of a 1M-token window is 40 KB of listing, and a listing that big is a
/// tax, not a list. The cap is what keeps the section inside the buffer the
/// prompt is composed into.
pub const max_budget_chars = 8 * 1024;

/// The most entries the plan can hold.
///
/// Not a budget: a bound on the ARRAY the planner uses, so the plan fits in a
/// stack buffer. A project with more skills than this has a listing that is
/// over the budget anyway, and the ones that do not fit are named in the note.
pub const max_listed_entries = 512;

/// The listing's budget, in CHARACTERS, for a context window of `context_tokens`.
///
/// 1% of a 128k window is 1280 tokens, which is 5120 characters: about thirty
/// entries with a description, or a hundred names.
pub fn budgetCharsFor(context_tokens: i64) usize {
    if (context_tokens <= 0) return 0;
    // The percentage is a PERCENTAGE: 1% of 128k is 1280 tokens, not 128000.
    // The multiplication is checked because a context window is a number that
    // came from a file, and an overflow in a budget is a panic in a prompt.
    const scaled = std.math.mul(i64, context_tokens, budget_percent) catch return max_budget_chars;
    const tokens = @divTrunc(scaled, 100);
    if (tokens <= 0) return 0;
    const chars = std.math.mul(i64, tokens, chars_per_token) catch return max_budget_chars;
    const capped = @min(chars, @as(i64, max_budget_chars));
    return @intCast(capped);
}

/// Skill execution context.
pub const Context = enum {
    inline_mode,
    fork,
};

/// One skill's frontmatter (rich version for Phase 1+).
pub const Meta = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    when_to_use: []const u8 = "",
    argument_hint: []const u8 = "",
    allowed_tools: []const u8 = "",
    model: []const u8 = "",
    effort: []const u8 = "",
    /// The project paths this skill applies to, as a JSON array of prefixes
    /// (e.g. `["src/", "packages/web/"]`). Empty means the skill applies to
    /// every project. A non-empty list means the skill is only listed when the
    /// current project root starts with one of the prefixes.
    paths: []const u8 = "",
    context: Context = .inline_mode,
};

/// Splits the frontmatter from the body.
///
/// `null` when there is no frontmatter, which is legal: a skill can be just a
/// markdown file. Returns slices into `text`.
///
/// The parser is hand-written and DELIBERATELY narrow: `key: value` lines, one
/// `---`-fenced block at the top, `#` comments inside it. It does not do YAML.
/// A real YAML parser is 600 lines and a whole set of ways to be surprised by a
/// tab, and the only keys that matter here are the known strings.
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
        // Known frontmatter keys
        if (std.mem.eql(u8, key, "name")) {
            meta.name = val;
        } else if (std.mem.eql(u8, key, "description")) {
            meta.description = val;
        } else if (std.mem.eql(u8, key, "when_to_use")) {
            meta.when_to_use = val;
        } else if (std.mem.eql(u8, key, "argument_hint")) {
            meta.argument_hint = val;
        } else if (std.mem.eql(u8, key, "allowed_tools")) {
            meta.allowed_tools = val;
        } else if (std.mem.eql(u8, key, "model")) {
            meta.model = val;
        } else if (std.mem.eql(u8, key, "effort")) {
            meta.effort = val;
        } else if (std.mem.eql(u8, key, "paths")) {
            meta.paths = val;
        } else if (std.mem.eql(u8, key, "context")) {
            if (std.mem.eql(u8, val, "fork")) {
                meta.context = .fork;
            } else {
                meta.context = .inline_mode;
            }
        }
        // Unknown keys are silently ignored — the parser stays narrow
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

/// Skill source for shadowing precedence.
pub const Source = enum {
    project,
    agents,
    user,
    bundled,
};

/// One skill as discovered on disk (or bundled).
pub const Entry = struct {
    /// Valid name, unique across the search path (project shadows user).
    name: []const u8 = "",
    description: []const u8 = "",
    /// Full path of the `SKILL.md`. Owned by the loader.
    path: []const u8 = "",
    /// Full body of the skill (loaded on demand). Owned by the loader when present.
    body: ?[]const u8 = null,
    /// Where this skill came from (for display and precedence).
    source: Source = .project,
    /// Execution context (inline or fork).
    context: Context = .inline_mode,
    /// Detailed "when to use" for the listing.
    when_to_use: []const u8 = "",
    /// The skill's declared `allowed_tools` (JSON array of tool names). A forked
    /// skill may only use these, and only if they are read-only: a skill cannot
    /// escalate beyond the subagent's read-only set. Empty = the default set.
    allowed_tools: []const u8 = "",
    /// The skill's declared model, or empty to use the default subagent target.
    model: []const u8 = "",
    /// The skill's declared effort, or empty to use `low`.
    effort: []const u8 = "",
    /// See `Meta.paths`: the project paths this skill applies to. Carried into
    /// the entry so the caller can filter which skills are listed.
    paths: []const u8 = "",
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

/// The header of the section: what a skill is and what the listing is.
///
/// It is the price of having a list at all, it is the same on every request (so
/// the provider's cache keeps it), and it is NOT part of the budget: the budget
/// buys ENTRIES. A header with no list under it is a shape that costs sixty
/// tokens per request to say nothing, so what gets cut is the list, never the
/// sentence that explains it.
const header_text =
    \\
    \\Skills — folders of instructions you can load. The list is only names and
    \\when to use them; the instructions cost tokens, so load ONE when the
    \\description matches the task, and load none if none do.
    \\
;

/// How much of an entry goes into the listing.
const Detail = enum(u8) {
    /// Nothing: the entry was left out.
    dropped = 0,
    /// The name and the description.
    full = 1,
    /// The name only.
    names_only = 2,
};

/// What the listing does with each entry.
///
/// It is a PLAN and not a rendering: the renderer and the planner must agree on
/// what fits, and two implementations of "what fits" is how a listing ends up
/// over its own budget.
const Plan = struct {
    level: [max_listed_entries]Detail = @splat(.dropped),
    /// How many entries are listed.
    listed: usize = 0,
    /// How many are not, and the note that says so.
    omitted: usize = 0,
    note_text: [96]u8 = undefined,
    note_len: usize = 0,
};

/// A rendered entry line. Big enough for a name, a capped description and a
/// capped "when to use": 64 + 250 + 250 columns, and a column is at most four
/// bytes.
const line_scratch = 4096;
/// The clipped text. `textcap.clipInto` needs `cols * 4 + 8`.
const clip_scratch = 1024;
/// The note ("… and N more").
const note_scratch = 96;

/// The paragraph the system prompt carries, under a budget.
///
/// `budget_chars` is the room the ENTRIES have; the header is on top of it (see
/// `header_text`). The ladder when it does not fit is, in order:
///
/// 1. every entry with its description (the normal case, and the bytes are the
///    same as before this was budgeted, so the provider's cache keeps them),
/// 2. the bundled entries keep their description and the rest degrade to their
///    NAME — the bundled ones are ours and are the ones the model is most
///    likely to want,
/// 3. everything degrades to its name,
/// 4. entries are left out, from the end, and the note says how many.
///
/// The cap of `max_desc_chars` does NOT apply to a bundled entry: those
/// descriptions are ours and truncating them would hide the one thing the model
/// has to read to decide.
pub fn skillAppliesHere(entry: Entry, project_root: ?[]const u8) bool {
    // An empty `paths` means the skill applies to every project.
    if (entry.paths.len == 0) return true;
    // Not inside a git repository: a path-conditional skill cannot be
    // confirmed to apply, so it does not.
    const root = project_root orelse return false;

    // `paths` is a JSON array of path prefixes, e.g. `["src/", "packages/web/"]`.
    const arena = std.heap.page_allocator;
    const doc = std.json.parseFromSliceLeaky(std.json.Value, arena, entry.paths, .{}) catch return false;
    if (doc != .array) return false;
    for (doc.array.items) |v| {
        if (v != .string) continue;
        const prefix = v.string;
        if (prefix.len == 0) continue;
        // Strip a trailing slash: "src/" becomes "src".
        const stripped = if (prefix[prefix.len - 1] == '/') prefix[0..prefix.len - 1] else prefix;
        // The skill applies when the project root IS the prefix, or ends with
        // "/<prefix>" (e.g. root "/home/user/proj/src" matches prefix "src/").
        if (std.mem.eql(u8, root, stripped)) return true;
        if (root.len > stripped.len and root[root.len - stripped.len - 1] == '/' and
            std.mem.eql(u8, root[root.len - stripped.len ..], stripped))
        {
            return true;
        }
    }
    return false;
}

test "skillAppliesHere: empty paths applies everywhere" {
    const e = skills.Entry{ .paths = "" };
    try std.testing.expect(skillAppliesHere(e, "/home/user/proj"));
    try std.testing.expect(skillAppliesHere(e, null));
}

test "skillAppliesHere: non-empty paths with no project root does not apply" {
    const e = skills.Entry{ .paths = "[\"src/\"]" };
    try std.testing.expect(!skillAppliesHere(e, null));
}

test "skillAppliesHere: project root under a trailing-slash prefix applies" {
    const e = skills.Entry{ .paths = "[\"src/\", \"packages/web/\"]" };
    try std.testing.expect(skillAppliesHere(e, "/home/user/proj/src"));
    try std.testing.expect(skillAppliesHere(e, "/home/user/proj/packages/web"));
    try std.testing.expect(!skillAppliesHere(e, "/home/user/proj/lib"));
}

test "skillAppliesHere: project root exactly matching a prefix applies" {
    const e = skills.Entry{ .paths = "[\"/home/user/proj\"]" };
    try std.testing.expect(skillAppliesHere(e, "/home/user/proj"));
    try std.testing.expect(!skillAppliesHere(e, "/home/user/proj2"));
}

test "skillAppliesHere: malformed paths JSON does not apply" {
    const e = skills.Entry{ .paths = "[\"src/\"," };
    try std.testing.expect(!skillAppliesHere(e, "/home/user/proj/src"));
}

pub fn systemPromptSection(entries: []const Entry, budget_chars: usize, out: []u8) []const u8 {
    if (entries.len == 0) return "";
    const plan = planListing(entries, budget_chars);

    var w: std.Io.Writer = .fixed(out);
    w.writeAll(header_text) catch {};

    var line: [line_scratch]u8 = undefined;
    var clip: [clip_scratch]u8 = undefined;
    const n = @min(entries.len, max_listed_entries);
    for (entries[0..n], 0..) |e, i| {
        switch (plan.level[i]) {
            .dropped => continue,
            .full => w.writeAll(renderLine(e, .full, &line, &clip)) catch {},
            .names_only => w.writeAll(renderLine(e, .names_only, &line, &clip)) catch {},
        }
    }
    if (plan.note_len > 0) w.writeAll(plan.note_text[0..plan.note_len]) catch {};
    return w.buffered();
}

/// Decides what each entry gets and what is left out.
fn planListing(entries: []const Entry, budget: usize) Plan {
    var p: Plan = .{};
    const n = @min(entries.len, max_listed_entries);

    var line: [line_scratch]u8 = undefined;
    var clip: [clip_scratch]u8 = undefined;
    var note: [note_scratch]u8 = undefined;

    // What each entry costs, at each detail.
    var full_total: usize = 0;
    var names_total: usize = 0;
    var mixed_total: usize = 0;
    for (entries[0..n]) |e| {
        const fl = renderLine(e, .full, &line, &clip).len;
        const nl = renderLine(e, .names_only, &line, &clip).len;
        full_total += fl;
        names_total += nl;
        // The mixed ladder: the bundled ones keep their description.
        mixed_total += if (e.source == .bundled) fl else nl;
    }

    // The entries past the array bound are out whatever happens, so the note is
    // already owed.
    const out_of_bounds = entries.len - n;

    // 1. Everything, in full. The bytes are the same as before the budget
    //    existed, which is what keeps the provider's cache warm.
    if (full_total + noteCost(out_of_bounds, &note) <= budget) {
        for (entries[0..n], 0..) |_, i| p.level[i] = .full;
        p.listed = n;
        p.omitted = out_of_bounds;
        setNote(&p, &note);
        return p;
    }

    // 2. The bundled ones keep their description; the rest degrade to names.
    if (mixed_total + noteCost(out_of_bounds, &note) <= budget) {
        for (entries[0..n], 0..) |e, i| {
            p.level[i] = if (e.source == .bundled) .full else .names_only;
        }
        p.listed = n;
        p.omitted = out_of_bounds;
        setNote(&p, &note);
        return p;
    }

    // 3. Everything degrades to its name.
    if (names_total + noteCost(out_of_bounds, &note) <= budget) {
        for (entries[0..n], 0..) |_, i| p.level[i] = .names_only;
        p.listed = n;
        p.omitted = out_of_bounds;
        setNote(&p, &note);
        return p;
    }

    // 4. Names do not fit either: entries are left out, from the end, and the
    //    note says how many. The non-bundled ones go first: a bundled skill is
    //    ours and is the one the model is most likely to want.
    for (entries[0..n], 0..) |_, i| p.level[i] = .names_only;
    var kept = n;
    var kept_total = names_total;
    var i = n;
    while (i > 0) {
        i -= 1;
        const e = entries[i];
        if (e.source == .bundled) continue;
        kept_total -= renderLine(e, .names_only, &line, &clip).len;
        p.level[i] = .dropped;
        kept -= 1;
        if (kept_total + noteCost(entries.len - kept, &note) <= budget) break;
    }
    // And if the bundled ones alone do not fit, they go too.
    if (kept_total + noteCost(entries.len - kept, &note) > budget) {
        i = n;
        while (i > 0) {
            i -= 1;
            const e = entries[i];
            if (e.source != .bundled) continue;
            kept_total -= renderLine(e, .names_only, &line, &clip).len;
            p.level[i] = .dropped;
            kept -= 1;
            if (kept_total + noteCost(entries.len - kept, &note) <= budget) break;
        }
    }
    p.listed = kept;
    p.omitted = entries.len - kept;
    setNote(&p, &note);
    return p;
}

/// One entry, rendered. `line` receives the result, `clip` is the scratch for a
/// clipped description.
fn renderLine(e: Entry, detail: Detail, line: []u8, clip: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(line);
    switch (detail) {
        .dropped => {},
        .names_only => {
            w.print("- {s}", .{e.name}) catch {};
        },
        .full => {
            w.print("- {s}: ", .{e.name}) catch {};
            if (e.source == .bundled) {
                // NEVER truncated: the bundled descriptions are ours, and
                // truncating them hides the one thing the model has to read to
                // decide whether to load the skill.
                w.writeAll(e.description) catch {};
                if (e.when_to_use.len > 0) w.print(" — {s}", .{e.when_to_use}) catch {};
            } else {
                const d = textcap.clipInto(descriptionFor(e.description), max_desc_chars, clip);
                w.writeAll(d) catch {};
                if (e.when_to_use.len > 0) {
                    const wu = textcap.clipInto(e.when_to_use, max_desc_chars, clip);
                    w.print(" — {s}", .{wu}) catch {};
                }
            }
        },
    }
    w.writeAll("\n") catch {};
    return w.buffered();
}

/// What an entry says when it has no description of its own.
fn descriptionFor(description: []const u8) []const u8 {
    if (description.len > 0) return description;
    return "(no description — read it before trusting it)";
}

/// The note that says how many entries were left out.
fn noteText(omitted: usize, out: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(out);
    w.print("- … and {d} more, loadable by name with the `skill` tool\n", .{omitted}) catch {};
    return w.buffered();
}

/// What the note costs: nothing when there is nothing to say.
fn noteCost(omitted: usize, out: []u8) usize {
    if (omitted == 0) return 0;
    return noteText(omitted, out).len;
}

/// Puts the note in the plan.
fn setNote(p: *Plan, scratch: []u8) void {
    if (p.omitted == 0) {
        p.note_len = 0;
        return;
    }
    const t = noteText(p.omitted, scratch);
    @memcpy(p.note_text[0..t.len], t);
    p.note_len = t.len;
}

test "splitFrontmatter: separates meta and body" {
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

test "splitFrontmatter: quotes, comments and CRLF" {
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

test "splitFrontmatter: rich frontmatter fields" {
    const text =
        \\---
        \\name: test-skill
        \\description: Test skill
        \\when_to_use: When testing things
        \\argument_hint: Optional test name
        \\allowed_tools: ["read", "bash"]
        \\model: custom-model
        \\effort: high
        \\context: fork
        \\---
        \\body
    ;
    const r = skills.splitFrontmatter(text) orelse return error.NoFrontmatter;
    try std.testing.expectEqualStrings("test-skill", r.meta.name);
    try std.testing.expectEqualStrings("Test skill", r.meta.description);
    try std.testing.expectEqualStrings("When testing things", r.meta.when_to_use);
    try std.testing.expectEqualStrings("Optional test name", r.meta.argument_hint);
    try std.testing.expectEqualStrings("[\"read\", \"bash\"]", r.meta.allowed_tools);
    try std.testing.expectEqualStrings("custom-model", r.meta.model);
    try std.testing.expectEqualStrings("high", r.meta.effort);
    try std.testing.expect(r.meta.context == .fork);
}

test "splitFrontmatter: without frontmatter it is null, and the whole body is the body" {
    try std.testing.expect(skills.splitFrontmatter("# just markdown\n\ntext") == null);
    // A `---` that is not at the start of a line is a horizontal rule.
    try std.testing.expect(skills.splitFrontmatter("texto --- mas texto") == null);
    // Unclosed frontmatter is also null (meta is not invented).
    try std.testing.expect(skills.splitFrontmatter("---\nname: x\nsin cerrar") == null);
}

test "splitFrontmatter: real CRLF" {
    const text = "---\r\nname: crlf\r\ndescription: windows\r\n---\r\nbody\r\n";
    const r = skills.splitFrontmatter(text) orelse return error.NoFrontmatter;
    try std.testing.expectEqualStrings("crlf", r.meta.name);
    try std.testing.expectEqualStrings("windows", r.meta.description);
}

test "validName: what can go into a path and into a tool call" {
    try std.testing.expect(skills.validName("pty-tests"));
    try std.testing.expect(skills.validName("skill_2"));
    try std.testing.expect(!skills.validName(""));
    try std.testing.expect(!skills.validName("../escape"));
    try std.testing.expect(!skills.validName("with space"));
    try std.testing.expect(!skills.validName("with/slash"));
    try std.testing.expect(!skills.validName("a" ** 65));
}

test "nameFor: the directory wins when the frontmatter is unusable" {
    try std.testing.expectEqualStrings("pty-tests", skills.nameFor(.{ .name = "pty-tests" }, "other"));
    // A name with a slash is worse than none: the tool call would fail and the
    // model has no way to discover the good name.
    try std.testing.expectEqualStrings("dir", skills.nameFor(.{ .name = "bad/name" }, "dir"));
    try std.testing.expectEqualStrings("dir", skills.nameFor(.{}, "dir"));
}

test "formatSkill: the body goes framed, not loose" {
    var buf: [4096]u8 = undefined;
    const out = skills.formatSkill("pty", "use after any tui change", "# Instructions\n", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "=== skill: pty ===") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "use when: use after any tui change") != null);
    // And it says explicitly that these instructions rule now.
    try std.testing.expect(std.mem.indexOf(u8, out, "they win") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "# Instructions") != null);
}

test "formatSkill: a truncated skill SAYS so" {
    var body: [40_000]u8 = @splat('x');
    var buf: [40_000]u8 = undefined;
    const out = skills.formatSkill("big", "", &body, &buf);
    try std.testing.expect(out.len <= buf.len);
    try std.testing.expect(std.mem.indexOf(u8, out, "you are reading part of it") != null);
}

test "systemPromptSection: with no skills there is no section (0 tokens per request)" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("", skills.systemPromptSection(&.{}, 1024, &buf));
}

test "systemPromptSection: lists name + when to use it" {
    const entries = [_]skills.Entry{
        .{ .name = "pty-tests", .description = "after any tui drawing change" },
        .{ .name = "no-desc", .description = "" },
    };
    var buf: [2048]u8 = undefined;
    const s = skills.systemPromptSection(&entries, 1024, &buf);
    try std.testing.expect(std.mem.indexOf(u8, s, "- pty-tests: after any tui drawing change") != null);
    // A skill with no description is listed anyway, marked: hiding it makes it
    // unusable and the author does not even find out.
    try std.testing.expect(std.mem.indexOf(u8, s, "no-desc: (no description") != null);
    // And it does NOT carry the body: that is the entire point of the design.
    try std.testing.expect(std.mem.indexOf(u8, s, "load ONE") != null);
}

test "systemPromptSection: includes when_to_use in listing" {
    const entries = [_]skills.Entry{
        .{ .name = "test-skill", .description = "Test skill", .when_to_use = "when testing" },
    };
    var buf: [2048]u8 = undefined;
    const s = skills.systemPromptSection(&entries, 1024, &buf);
    try std.testing.expect(std.mem.indexOf(u8, s, "test-skill: Test skill — when testing") != null);
}

test "systemPromptSection: under a budget the bytes are the same as before it existed" {
    // The listing lives in the CACHED prefix of every request, so a budget that
    // changed its FORMAT would invalidate the provider's cache on every turn.
    // This pins the exact bytes: the header, then "- name: description".
    const entries = [_]skills.Entry{
        .{ .name = "pty-tests", .description = "after any tui drawing change" },
    };
    var buf: [2048]u8 = undefined;
    const s = skills.systemPromptSection(&entries, 4096, &buf);
    const want =
        "\nSkills — folders of instructions you can load. The list is only names and\n" ++
        "when to use them; the instructions cost tokens, so load ONE when the\n" ++
        "description matches the task, and load none if none do.\n" ++
        "- pty-tests: after any tui drawing change\n";
    try std.testing.expectEqualStrings(want, s);
}

test "systemPromptSection: the budget caps the size of the listing" {
    // Real distinct names, because two skills with the same name would be one
    // skill with a shadowing bug and the test would pass for the wrong reason.
    // The names live in an ARRAY, not in a buffer declared inside the loop: a
    // `var nb` in the body is the same stack slot on every iteration, so every
    // entry would end up pointing at the LAST name.
    var names: [50][8]u8 = undefined;
    var entries: [50]skills.Entry = undefined;
    for (&entries, 0..) |*e, i| {
        const name = std.fmt.bufPrint(&names[i], "skill{d}", .{i}) catch "s";
        e.* = .{ .name = name, .description = "a description that is not short at all" };
    }
    var buf: [16 * 1024]u8 = undefined;
    const budget = 400;
    const s = skills.systemPromptSection(&entries, budget, &buf);
    // The ENTRIES fit in the budget. The header is the price of having a list
    // and is not part of it.
    const header_len = std.mem.indexOf(u8, s, "- skill0").?;
    try std.testing.expect(s.len - header_len <= budget);
    // And it says how many were left out, because a list that is cut without
    // saying so reads as "these are all of them".
    try std.testing.expect(std.mem.indexOf(u8, s, "loadable by name") != null);
}

test "systemPromptSection: a tight budget degrades the others and keeps the bundled ones" {
    const entries = [_]skills.Entry{
        .{ .name = "project-one", .description = "a long description that will not fit" },
        .{ .name = "project-two", .description = "another long description that will not fit" },
        .{ .name = "bundled-one", .description = "the bundled description, in full", .source = .bundled },
    };
    var buf: [4096]u8 = undefined;
    // Enough for the names and the bundled description, and nothing more.
    const s = skills.systemPromptSection(&entries, 120, &buf);
    try std.testing.expect(std.mem.indexOf(u8, s, "the bundled description, in full") != null);
    // The others degrade to their NAME: they are still loadable, and the model
    // can ask for them by name.
    try std.testing.expect(std.mem.indexOf(u8, s, "- project-one\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "- project-two\n") != null);
    // And the degraded ones do NOT carry their description.
    try std.testing.expect(std.mem.indexOf(u8, s, "a long description that will not fit") == null);
}

test "systemPromptSection: a bundled description is never truncated by the per-entry cap" {
    // The cap is for the descriptions people write; the bundled ones are ours,
    // and truncating them hides the one thing the model has to read to decide.
    var desc: [600]u8 = undefined;
    @memset(&desc, 'x');
    const entries = [_]skills.Entry{
        .{ .name = "bundled-one", .description = &desc, .source = .bundled },
        .{ .name = "written-one", .description = &desc },
    };
    var buf: [4096]u8 = undefined;
    const s = skills.systemPromptSection(&entries, 4096, &buf);
    const bundled_at = std.mem.indexOf(u8, s, "- bundled-one: ").?;
    const written_at = std.mem.indexOf(u8, s, "- written-one: ").?;
    // The bundled one carries all 600 characters.
    try std.testing.expect(s[bundled_at..written_at].len >= 600);
    // The written one carries the cap (250) and says it was cut.
    const written = s[written_at..];
    try std.testing.expect(std.mem.indexOf(u8, written, textcap.ellipsis) != null);
    try std.testing.expect(written.len < 600);
}

test "systemPromptSection: the per-entry cap is 250 characters" {
    var desc: [400]u8 = undefined;
    @memset(&desc, 'y');
    const entries = [_]skills.Entry{.{ .name = "one", .description = &desc }};
    var buf: [4096]u8 = undefined;
    const s = skills.systemPromptSection(&entries, 4096, &buf);
    const at = std.mem.indexOf(u8, s, "- one: ").?;
    const body = s[at + "- one: ".len ..];
    // 250 columns of text plus the ellipsis (the ellipsis is INSIDE the cap).
    try std.testing.expectEqual(@as(usize, 250), textcap.columnCount(std.mem.trimEnd(u8, body, "\n")));
}

test "systemPromptSection: with no room at all the section is the header and the note" {
    const entries = [_]skills.Entry{
        .{ .name = "one", .description = "d" },
        .{ .name = "two", .description = "d" },
    };
    var buf: [4096]u8 = undefined;
    const s = skills.systemPromptSection(&entries, 0, &buf);
    // The header is never dropped: a listing with no explanation is a shape
    // that costs sixty tokens per request to say nothing.
    try std.testing.expect(std.mem.indexOf(u8, s, "load ONE") != null);
    // And the model is told there are more than it can see.
    try std.testing.expect(std.mem.indexOf(u8, s, "and 2 more") != null);
    // But not a single entry.
    try std.testing.expect(std.mem.indexOf(u8, s, "- one") == null);
}

test "budgetCharsFor: one percent of the window, and the cap" {
    // 128k tokens is the default window: 1% is 1280 tokens, which is ~5 KB.
    try std.testing.expectEqual(@as(usize, 5120), skills.budgetCharsFor(128_000));
    // A small window gets a small budget.
    try std.testing.expectEqual(@as(usize, 240), skills.budgetCharsFor(6_000));
    // And a huge one is capped: a listing that big is a tax, not a list.
    try std.testing.expectEqual(skills.max_budget_chars, skills.budgetCharsFor(10_000_000));
    // No window, no budget.
    try std.testing.expectEqual(@as(usize, 0), skills.budgetCharsFor(0));
    // And a window that would overflow the arithmetic is the cap, not a panic.
    try std.testing.expectEqual(skills.max_budget_chars, skills.budgetCharsFor(std.math.maxInt(i64)));
}

test "splitFrontmatter: a file that ENDS at the fence does not blow up" {
    // The bug the `skillstore` tests found: if the last line is the closing `---`
    // and there is no final newline, the index goes one position past and
    // `rest[i..]` is a PANIC, not an empty slice. And a SKILL.md that ends at
    // the fence is the most normal thing in the world.
    const no_newline = "---\nname: x\ndescription: y\n---";
    const r = skills.splitFrontmatter(no_newline) orelse return error.NoFrontmatter;
    try std.testing.expectEqualStrings("x", r.meta.name);
    try std.testing.expectEqualStrings("y", r.meta.description);
    try std.testing.expectEqualStrings("", r.body);

    // And with a newline, which was the previous case, it is the same.
    const with_newline = "---\nname: x\n---\nbody\n";
    const r2 = skills.splitFrontmatter(with_newline) orelse return error.NoFrontmatter;
    try std.testing.expectEqualStrings("body", std.mem.trim(u8, r2.body, " \t\r\n"));
}