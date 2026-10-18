//! Bundled skills: skills compiled into the binary via @embedFile.
//!
//! This module provides the 5 built-in skills so they work out of the box
//! without any filesystem setup. They are appended AFTER on-disk skills
//! (project/user/agents) so on-disk skills can shadow them.

const std = @import("std");
const skills = @import("skills.zig");

/// Simple $ARGUMENTS substitution helper.
pub fn substituteArguments(body: []const u8, args: []const u8, out: []u8) []const u8 {
    const needle = "$ARGUMENTS";
    const idx = std.mem.indexOf(u8, body, needle) orelse return body;
    var w: std.Io.Writer = .fixed(out);
    w.writeAll(body[0..idx]) catch return body;
    w.writeAll(args) catch return body;
    w.writeAll(body[idx + needle.len..]) catch return body;
    return w.buffered();
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
        .description = "Review a diff for reuse and duplication; suggest extractions that simplify the code",
        .when_to_use = "After a write or edit that adds more than 50 lines, or when the model feels the code is getting repetitive",
        .argument_hint = "Optional path to the file to review (defaults to the last edited file)",
        .allowed_tools = "[\"read\", \"grep\", \"glob\"]",
        .model = "",
        .effort = "low",
        .context = .inline_mode,
        .body = @embedFile("../skills/simplify.md"),
    },
    .{
        .name = "verify",
        .description = "Find the narrowest command that would break if the code was wrong; run it and report",
        .when_to_use = "After any edit that claims to fix a bug or add a feature; before declaring a task done",
        .argument_hint = "Optional path or test name to verify (defaults to the project's standard check)",
        .allowed_tools = "[\"bash\", \"read\", \"grep\", \"glob\", \"check\"]",
        .model = "",
        .effort = "low",
        .context = .inline_mode,
        .body = @embedFile("../skills/verify.md"),
    },
    .{
        .name = "skillify",
        .description = "Turn a repeated task into a reusable SKILL.md with frontmatter and clear instructions",
        .when_to_use = "When you notice the model (or yourself) repeating the same multi-step process 3+ times",
        .argument_hint = "A short name for the new skill (lowercase, hyphens only)",
        .allowed_tools = "[\"write\", \"read\", \"glob\", \"grep\"]",
        .model = "",
        .effort = "low",
        .context = .inline_mode,
        .body = @embedFile("../skills/skillify.md"),
    },
    .{
        .name = "debug",
        .description = "Reproduce a failure, isolate the cause, and fix it — backgrounding long runs",
        .when_to_use = "When a test fails, a build breaks, or the model encounters an error it cannot explain",
        .argument_hint = "Optional error message or test name to investigate",
        .allowed_tools = "[\"bash\", \"read\", \"grep\", \"glob\", \"check\", \"bash_output\", \"bash_kill\"]",
        .model = "",
        .effort = "medium",
        .context = .fork,
        .body = @embedFile("../skills/debug.md"),
    },
    .{
        .name = "goal",
        .description = "Split a high-level objective into a driven todo list with checkpoints and verification",
        .when_to_use = "At the start of any multi-step task, or when the model is losing track of the objective",
        .argument_hint = "Optional objective text (defaults to the current /goal if set)",
        .allowed_tools = "[\"todo\", \"read\", \"grep\", \"glob\", \"bash\", \"task_create\", \"task_list\"]",
        .model = "",
        .effort = "low",
        .context = .inline_mode,
        .body = @embedFile("../skills/goal.md"),
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
pub fn bundledEntries(gpa: std.mem.Allocator) ![]skills.Entry {
    var entries = std.ArrayList(skills.Entry).empty;
    try entries.ensureTotalCapacity(gpa, bundled_skills.len);

    for (bundled_skills) |s| {
        var path_buf: [128]u8 = undefined;
        const path_str = std.fmt.bufPrint(path_buf[0..], "bundled://{s}", .{s.name}) catch return error.OutOfMemory;
        const path = gpa.dupe(u8, path_str) catch return error.OutOfMemory;
        const entry = skills.Entry{
            .name = s.name,
            .description = s.description,
            .path = path,
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
    }
}