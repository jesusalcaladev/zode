//! Bundled skills: skills compiled into the binary via @embedFile.
//!
//! This module provides the 5 built-in skills so they work out of the box
//! without any filesystem setup. They are appended AFTER on-disk skills
//! (project/user/agents) so on-disk skills can shadow them.

const std = @import("std");
const skills = @import("core.zig");

/// Substitutes `$ARGUMENTS`, `$1`, `$2`, ... (positional) and `$name` (named)
/// in `body`, writing the result into `out`.
///
/// `args` is the raw string the model passed to the `skill` call. Tokens are
/// split on whitespace; a token `name=value` becomes a named argument and
/// everything else is positional (`$1`, `$2`, ... in order). `$ARGUMENTS` is
/// the whole trimmed string. A placeholder that names an argument that was not
/// provided is left as-is in the body. When the body has no placeholder the
/// original slice is returned untouched (no copy, no allocation).
///
/// All argument values are slices into `args`, so nothing is allocated here;
/// the caller owns `out`.
pub fn substituteArguments(
    body: []const u8,
    args: []const u8,
    out: []u8,
) []const u8 {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");

    var positionals: [16][]const u8 = undefined;
    var positional_count: usize = 0;
    var named: [16]NamedArg = undefined;
    var named_count: usize = 0;
    {
        var rest = trimmed;
        while (rest.len > 0) {
            rest = std.mem.trimStart(u8, rest, " \t\r\n");
            if (rest.len == 0) break;
            var end: usize = 0;
            while (end < rest.len and rest[end] != ' ' and rest[end] != '\t' and rest[end] != '\r' and rest[end] != '\n') end += 1;
            const token = rest[0..end];
            rest = rest[end..];
            const eq = std.mem.indexOfScalar(u8, token, '=');
            if (eq) |e| {
                if (e > 0) {
                    const name = token[0..e];
                    if (isArgName(name) and named_count < named.len) {
                        named[named_count] = .{ .name = name, .value = token[e + 1..] };
                        named_count += 1;
                        continue;
                    }
                }
            }
            if (positional_count < positionals.len) {
                positionals[positional_count] = token;
                positional_count += 1;
            }
        }
    }

    const ctx = Ctx{
        .trimmed = trimmed,
        .positionals = positionals[0..positional_count],
        .positional_count = positional_count,
        .named = named[0..named_count],
        .named_count = named_count,
    };

    var w: std.Io.Writer = .fixed(out);
    var last: usize = 0;
    var i: usize = 0;
    var changed: bool = false;
    while (i < body.len) {
        if (body[i] == '$') {
            const sub = placeholderValue(ctx, body[i + 1..]);
            if (sub) |s| {
                if (i > last) w.writeAll(body[last..i]) catch return body;
                w.writeAll(s.value) catch return body;
                last = i + 1 + s.len;
                i = last;
                changed = true;
                continue;
            }
        }
        i += 1;
    }
    if (!changed) return body;
    if (body.len > last) w.writeAll(body[last..]) catch return body;
    return w.buffered();
}

/// One named argument parsed from the `args` string.
const NamedArg = struct {
    name: []const u8,
    value: []const u8,
};

/// One `$...` placeholder: its length in `body` (including the `$`) and the
/// value to substitute.
const Placeholder = struct { len: usize, value: []const u8 };

const Ctx = struct {
    trimmed: []const u8,
    positionals: []const []const u8,
    positional_count: usize,
    named: []const NamedArg,
    named_count: usize,
};

fn placeholderValue(ctx: Ctx, after: []const u8) ?Placeholder {
    if (after.len == 0) return null;
    // $ARGUMENTS -> the whole trimmed argument string.
    if (std.mem.startsWith(u8, after, "ARGUMENTS")) {
        return .{ .len = 9, .value = ctx.trimmed };
    }
    // $N -> Nth positional argument (1-indexed).
    if (after[0] >= '1' and after[0] <= '9') {
        var n: usize = 0;
        var j: usize = 0;
        while (j < after.len and after[j] >= '0' and after[j] <= '9') {
            n = n * 10 + @as(usize, @intCast(after[j] - '0'));
            j += 1;
        }
        if (j > 0 and n >= 1 and n <= ctx.positional_count) {
            return .{ .len = j, .value = ctx.positionals[n - 1] };
        }
        return null;
    }
    // $name -> named argument.
    if ((after[0] >= 'a' and after[0] <= 'z') or (after[0] >= 'A' and after[0] <= 'Z') or after[0] == '_') {
        var j: usize = 0;
        while (j < after.len and (std.ascii.isAlphanumeric(after[j]) or after[j] == '_')) j += 1;
        if (j > 0) {
            const name = after[0..j];
            for (ctx.named[0..ctx.named_count]) |ne| {
                if (std.mem.eql(u8, ne.name, name)) {
                    return .{ .len = j, .value = ne.value };
                }
            }
        }
        return null;
    }
    return null;
}

fn isArgNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isArgName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| if (!isArgNameChar(c)) return false;
    return true;
}

pub const BundledSkill = struct {
    name: []const u8,
    description: []const u8,
    when_to_use: []const u8,
    argument_hint: []const u8,
    allowed_tools: []const u8,
    model: []const u8,
    effort: []const u8,
    context: skills.Context,
    body: []const u8,
};

/// All bundled skills, in order.
pub const bundled_skills: []const BundledSkill = &[_]BundledSkill{
    .{
        .name = "simplify",
        .description = "Review recent or targeted code for safe simplifications: reduce duplication and complexity without changing behavior",
        .when_to_use = "After a non-trivial write/edit, when code feels repetitive or hard to follow, or when asked to clean up a file or diff",
        .argument_hint = "Optional file path, directory, or scope to review (defaults to recently changed/mentioned code)",
        .allowed_tools = "[\"read\", \"grep\", \"glob\", \"bash\"]",
        .model = "",
        .effort = "low",
        .context = .inline_mode,
        .body = @embedFile("../../skills/simplify.md"),
    },
    .{
        .name = "verify",
        .description = "Find and run the narrowest verification that would fail if the recent change is wrong, then report evidence",
        .when_to_use = "After any edit that claims to fix a bug or add a feature, after risky refactors, or before declaring work done",
        .argument_hint = "Optional file path, test name/filter, command, or change summary to verify",
        .allowed_tools = "[\"bash\", \"read\", \"grep\", \"glob\", \"check\"]",
        .model = "",
        .effort = "low",
        .context = .inline_mode,
        .body = @embedFile("../../skills/verify.md"),
    },
    .{
        .name = "skillify",
        .description = "Turn a repeated, stable workflow into a reusable zode SKILL.md with clear trigger criteria and correct frontmatter",
        .when_to_use = "When the same multi-step process has appeared 3+ times and can be described with clear when-to-use criteria",
        .argument_hint = "Optional skill name and/or a short description of the workflow to capture",
        .allowed_tools = "[\"write\", \"read\", \"glob\", \"grep\", \"bash\"]",
        .model = "",
        .effort = "low",
        .context = .inline_mode,
        .body = @embedFile("../../skills/skillify.md"),
    },
    .{
        .name = "debug",
        .description = "Reproduce a failure, isolate the root cause from evidence, apply a minimal fix, and verify the result",
        .when_to_use = "When a test fails, a build/typecheck breaks, a command errors, or behavior is wrong and the cause is not obvious",
        .argument_hint = "Optional error message, failing test name, file path, or command to investigate",
        .allowed_tools = "[\"bash\", \"read\", \"grep\", \"glob\", \"check\", \"bash_output\", \"bash_kill\", \"edit\", \"write\"]",
        .model = "",
        .effort = "medium",
        .context = .inline_mode,
        .body = @embedFile("../../skills/debug.md"),
    },
    .{
        .name = "goal",
        .description = "Split a high-level objective into a concrete todo plan and drive it step by step with verification checkpoints",
        .when_to_use = "At the start of any multi-step task, when the objective is ambiguous, or when work has lost track of what done means",
        .argument_hint = "Optional objective text (if empty, use the current request or active /goal)",
        .allowed_tools = "[\"todo\", \"read\", \"grep\", \"glob\", \"bash\", \"check\", \"ask\", \"task_create\", \"task_list\"]",
        .model = "",
        .effort = "low",
        .context = .inline_mode,
        .body = @embedFile("../../skills/goal.md"),
    },
};

/// Returns the bundled skill with the given name, or null.
pub fn getBundled(name: []const u8) ?BundledSkill {
    for (bundled_skills) |s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

/// Returns all bundled skills as Entry structs for the prompt.
///
/// These are appended AFTER on-disk skills so they can be shadowed.
///
/// **Every string is a COPY the caller owns**, and that is not a detail: the
/// loader frees an entry's name, description and "when to use", and a literal
/// freed with the allocator is an "Invalid free" — the kind that only shows up
/// in the teardown of whoever used the list.
pub fn bundledEntries(gpa: std.mem.Allocator) ![]skills.Entry {
    var entries = std.ArrayList(skills.Entry).empty;
    try entries.ensureTotalCapacity(gpa, bundled_skills.len);
    errdefer entries.deinit(gpa);

    for (bundled_skills) |s| {
        var path_buf: [128]u8 = undefined;
        const path_str = std.fmt.bufPrint(path_buf[0..], "bundled://{s}", .{s.name}) catch return error.OutOfMemory;
        const path = gpa.dupe(u8, path_str) catch return error.OutOfMemory;
        errdefer gpa.free(path);
        const name = gpa.dupe(u8, s.name) catch return error.OutOfMemory;
        errdefer gpa.free(name);
        const description = gpa.dupe(u8, s.description) catch return error.OutOfMemory;
        errdefer gpa.free(description);
        const when = gpa.dupe(u8, s.when_to_use) catch return error.OutOfMemory;
        errdefer gpa.free(when);
        const entry = skills.Entry{
            .name = name,
            .description = description,
            .path = path,
            // The source matters: the listing under a budget never truncates a
            // BUNDLED description, and it decides that by the source.
            .source = .bundled,
            .when_to_use = when,
            .context = s.context,
        };
        try entries.append(gpa, entry);
    }

    return entries.toOwnedSlice(gpa);
}

/// Formats a bundled skill's body for the model (with $ARGUMENTS substitution).
pub fn formatBundledSkill(
    skill: BundledSkill,
    args: ?[]const u8,
    out: []u8,
) []const u8 {
    const body = skill.body;

    // Substitute $ARGUMENTS if present
    if (args) |a| {
        const trimmed = std.mem.trim(u8, a, " \t\r\n");
        if (trimmed.len > 0) {
            var buf: [8192]u8 = undefined;
            return substituteArguments(body, trimmed, &buf);
        }
    }

    return skills.formatSkill(skill.name, skill.description, body, out);
}

test "bundled skills are embedded and accessible" {
    try std.testing.expect(bundled_skills.len == 5);
    for (bundled_skills) |s| {
        try std.testing.expect(s.name.len > 0);
        try std.testing.expect(s.description.len > 0);
        try std.testing.expect(s.body.len > 0);
        try std.testing.expect(std.mem.indexOf(u8, s.body, "---") != null); // has frontmatter
    }
}

test "bundledEntries returns valid entries" {
    var gpa_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer gpa_state.deinit();
    const entries = try bundledEntries(gpa_state.allocator());
    defer gpa_state.allocator().free(entries);
    try std.testing.expectEqual(5, entries.len);
    for (entries) |e| {
        try std.testing.expect(e.name.len > 0);
        try std.testing.expect(e.description.len > 0);
        try std.testing.expect(std.mem.startsWith(u8, e.path, "bundled://"));
        // The source is what tells the listing under a budget that this
        // description is OURS and must not be truncated.
        try std.testing.expect(e.source == .bundled);
    }
}

test "substituteArguments: positional $1 and $2" {
    const body = "first: $1 second: $2";
    var out: [256]u8 = undefined;
    const r = substituteArguments(body, "alpha beta", &out);
    try std.testing.expectEqualStrings("first: alpha second: beta", r);
}

test "substituteArguments: named $name via key=value" {
    const body = "path: $name action: $action";
    var out: [256]u8 = undefined;
    const r = substituteArguments(body, "name=src/main.zig action=review", &out);
    try std.testing.expectEqualStrings("path: src/main.zig action: review", r);
}

test "substituteArguments: mixed positional and named" {
    const body = "$1 -> $file";
    var out: [256]u8 = undefined;
    const r = substituteArguments(body, "positional file=target.txt", &out);
    try std.testing.expectEqualStrings("positional -> target.txt", r);
}

test "substituteArguments: $ARGUMENTS still substitutes the whole string" {
    const body = "all: $ARGUMENTS";
    var out: [256]u8 = undefined;
    const r = substituteArguments(body, "hello world", &out);
    try std.testing.expectEqualStrings("all: hello world", r);
}

test "substituteArguments: unknown positional and named stay literal" {
    const body = "missing: $9 and $nope";
    var out: [256]u8 = undefined;
    const r = substituteArguments(body, "one", &out);
    try std.testing.expectEqualStrings("missing: $9 and $nope", r);
}

test "substituteArguments: no placeholder returns the body untouched" {
    const body: []const u8 = "nothing to substitute";
    var out: [64]u8 = undefined;
    const r = substituteArguments(body, "whatever", &out);
    // Sin placeholder no hay copia: se devuelve el mismo slice.
    try std.testing.expect(r.ptr == body.ptr);
}

test "substituteArguments: lone dollar and trailing dollar stay literal" {
    const body = "price $ and $5 and $";
    var out: [256]u8 = undefined;
    const r = substituteArguments(body, "five", &out);
    try std.testing.expectEqualStrings("price $ and $5 and $", r);
}

test "substituteArguments: empty args leaves placeholders literal" {
    const body = "a=$1 b=$name";
    var out: [256]u8 = undefined;
    const r = substituteArguments(body, "", &out);
    try std.testing.expectEqualStrings("a=$1 b=$name", r);
}