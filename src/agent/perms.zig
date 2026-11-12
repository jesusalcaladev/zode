/// Permission modes and pure permission helpers.
///
/// Mutable permission state and TUI-coupled flows remain in `agent.zig`; this
/// module holds types and pure logic so they can be tested in isolation and
/// reused without pulling in the full orchestrator.
const std = @import("std");

/// The four permission modes. `default` asks for anything that writes or runs
/// a command; `accept_edits` auto-allows file edits; `read_only` (Plan mode)
/// blocks them; `bypass` (`/yolo`) allows everything.
pub const Mode = enum { default, accept_edits, read_only, bypass };

/// Derive the active mode from the three mutually exclusive flags.
pub fn modeFromFlags(yolo: bool, read_only: bool, accept_edits: bool) Mode {
    if (yolo) return .bypass;
    if (read_only) return .read_only;
    if (accept_edits) return .accept_edits;
    return .default;
}

/// The mode as one word, for the status bar and `/mode`.
pub fn modeName(mode: Mode) []const u8 {
    return switch (mode) {
        .default => "build",
        .accept_edits => "accept-edits",
        // "plan" and not "read-only": what the mode is for.
        .read_only => "plan",
        .bypass => "bypass",
    };
}

/// Next mode for shift+tab cycling. Bypass is not in the cycle.
pub fn cycleNext(mode: Mode) Mode {
    return switch (mode) {
        .default => .accept_edits,
        .accept_edits => .read_only,
        .read_only => .default,
        .bypass => .default,
    };
}

/// File-editing tools auto-allowed in accept-edits mode.
pub fn isEditTool(name: []const u8) bool {
    return std.mem.eql(u8, name, "write") or
        std.mem.eql(u8, name, "edit") or
        std.mem.eql(u8, name, "rename") or
        std.mem.eql(u8, name, "notebook_edit");
}

/// Maps key state enum values to display strings.
pub fn keyStateString(s: u8) []const u8 {
    return switch (s) {
        1 => "● verified",
        2 => "○ saved",
        3 => "✗ invalid",
        else => "",
    };
}

/// The `command` string from a bash tool's JSON args, or "".
pub fn bashCommandOf(args_json: []const u8, arena: std.mem.Allocator) []const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch return "";
    if (parsed != .object) return "";
    const v = parsed.object.get("command") orelse return "";
    return if (v == .string) v.string else "";
}

test "modeFromFlags and modeName" {
    try std.testing.expectEqual(Mode.default, modeFromFlags(false, false, false));
    try std.testing.expectEqual(Mode.bypass, modeFromFlags(true, false, false));
    try std.testing.expectEqual(Mode.read_only, modeFromFlags(false, true, false));
    try std.testing.expectEqual(Mode.accept_edits, modeFromFlags(false, false, true));
    try std.testing.expectEqualStrings("plan", modeName(.read_only));
    try std.testing.expectEqualStrings("build", modeName(.default));
}

test "cycleNext skips bypass" {
    try std.testing.expectEqual(Mode.accept_edits, cycleNext(.default));
    try std.testing.expectEqual(Mode.read_only, cycleNext(.accept_edits));
    try std.testing.expectEqual(Mode.default, cycleNext(.read_only));
    try std.testing.expectEqual(Mode.default, cycleNext(.bypass));
}

test "isEditTool" {
    try std.testing.expect(isEditTool("write"));
    try std.testing.expect(isEditTool("edit"));
    try std.testing.expect(isEditTool("rename"));
    try std.testing.expect(isEditTool("notebook_edit"));
    try std.testing.expect(!isEditTool("bash"));
    try std.testing.expect(!isEditTool("read"));
}
