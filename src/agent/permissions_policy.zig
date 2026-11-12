/// Composed automatic permission policy (no TUI dialog).
///
/// Decides whether a tool call can run without prompting under the current
/// mode and allowlists. Explicit per-tool "always allow" session grants are
/// handled by the dialog/call path, not here (matches existing behavior).
const std = @import("std");
const agent_perms = @import("perms.zig");
const permissions_store = @import("permissions_store.zig");
const tools_mod = @import("../tools/dispatch.zig");
const cmdsubst = @import("../lib/cmdsubst.zig");

const max_bash_patterns = 16;
const bash_pattern_max = 160;

pub fn permAutoAllowed(
    accept_edits: bool,
    turn_bash_allow_rules: []const []const u8,
    bash_pattern_bufs: *const [max_bash_patterns][bash_pattern_max]u8,
    bash_pattern_lens: *const [max_bash_patterns]usize,
    name: []const u8,
    arg: []const u8,
    args_json: []const u8,
    arena: std.mem.Allocator,
) bool {
    if (std.mem.eql(u8, name, "batch")) {
        return accept_edits and tools_mod.callWrites(name, args_json, arena);
    }
    if (accept_edits and agent_perms.isEditTool(name)) return true;
    if (!std.mem.eql(u8, name, "bash")) return false;

    const cmd = agent_perms.bashCommandOf(args_json, arena);
    const command = if (cmd.len > 0) cmd else arg;
    if (permissions_store.bashPatternAllowed(bash_pattern_bufs, bash_pattern_lens, command)) return true;
    if (turn_bash_allow_rules.len == 0) return false;
    return cmdsubst.matchesAllowRules(command, turn_bash_allow_rules);
}
