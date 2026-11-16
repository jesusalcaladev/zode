//! Structured-output run verdict (Phase 22). Pure on purpose: the exit-code
//! decision and the headless-only directive are testable without a model, a
//! network or an actual `--chat` invocation.
//!
//! The contract: in `--schema` mode the model MUST call `structured_output`
//! exactly once. Satisfied → exit 0 (the JSON was already printed to stdout).
//! Ended without the call → non-zero with a reason on stderr, so CI fails
//! loudly instead of parsing a prose apology.

const std = @import("std");

pub const exit_satisfied: u8 = 0;
pub const exit_missing: u8 = 2;
pub const exit_invalid: u8 = 3;

pub const Outcome = struct { satisfied: bool = false };

pub fn exitCode(outcome: Outcome) u8 {
    return if (outcome.satisfied) exit_satisfied else exit_missing;
}

/// The directive appended ONLY to the headless system prompt in --schema
/// mode. In the TUI this returns "" — the schema never enters an interactive
/// prompt (a human is reading).
pub fn directive(schema_mode: bool) []const u8 {
    return if (schema_mode)
        "STRUCTURED OUTPUT MODE: you MUST call `structured_output` exactly once, as your LAST action, with an object matching the caller's JSON schema. Do not answer in prose — the script reads only that object. If validation fails, fix the named field and call it again."
    else
        "";
}

/// The tool schema offered in --schema mode, injected into the headless
/// tools array. Empty in the TUI — so `structured_output` does not appear to
/// a human at all.
pub fn toolSchema(schema_mode: bool) []const u8 {
    return if (schema_mode)
        "{\"type\":\"function\",\"function\":{\"name\":\"structured_output\",\"description\":\"The final validated object matching the caller's schema\",\"parameters\":{\"type\":\"object\",\"properties\":{\"object\":{\"type\":\"object\"}},\"required\":[\"object\"]}}}"
    else
        "";
}

/// Append a tool entry to a tools JSON array (strip the trailing `]`, add a
/// comma if needed, insert the entry, re-close). Pure string work; the caller
/// owns the returned slice. Used by `runChat` to build the schema-mode tools.
pub fn withTool(gpa: std.mem.Allocator, base_tools: []const u8, extra: []const u8) ![]const u8 {
    if (extra.len == 0) return gpa.dupe(u8, base_tools);
    const trimmed = std.mem.trimEnd(u8, base_tools, " \t\r\n");
    if (trimmed.len == 0 or trimmed[trimmed.len - 1] != ']') return gpa.dupe(u8, base_tools);
    const inner = trimmed[0 .. trimmed.len - 1];
    const has_items = inner.len > 1; // "[]" → no items
    return std.fmt.allocPrint(gpa, "{s}{s}{s}]", .{
        inner,
        if (has_items) "," else "",
        extra,
    });
}

test "structured_run: exit code reflects whether the tool was called" {
    try std.testing.expectEqual(@as(u8, 0), exitCode(.{ .satisfied = true }));
    try std.testing.expectEqual(@as(u8, 2), exitCode(.{}));
    try std.testing.expect(exit_missing != 0);
}

test "structured_run: directive and tool schema are absent outside schema mode" {
    try std.testing.expectEqualStrings("", directive(false));
    try std.testing.expectEqualStrings("", toolSchema(false));
    try std.testing.expect(std.mem.indexOf(u8, directive(true), "structured_output") != null);
    try std.testing.expect(std.mem.indexOf(u8, toolSchema(true), "structured_output") != null);
}

test "structured_run: withTool injects the tool into a tools array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = "[{\"type\":\"function\",\"function\":{\"name\":\"read\"}}]";
    const got = try withTool(a, base, "{\"extra\":true}");
    try std.testing.expect(std.mem.indexOf(u8, got, "\"extra\":true") != null);
    try std.testing.expect(got[got.len - 1] == ']');

    const empty = try withTool(a, "[]", "{\"extra\":true}");
    try std.testing.expectEqualStrings("[{\"extra\":true}]", empty);
}
