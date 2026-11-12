const std = @import("std");
const tools_mod = @import("../tools/dispatch.zig");
const cmdsafety = @import("../lib/cmdsafety.zig");
const agent_perms = @import("perms.zig");

pub fn isWriteTool(name: []const u8) bool {
    return agent_perms.isEditTool(name) or
        std.mem.eql(u8, name, "bash") or
        std.mem.eql(u8, name, "git_add") or
        std.mem.eql(u8, name, "git_commit") or
        std.mem.eql(u8, name, "git_stash") or
        std.mem.eql(u8, name, "git_branch");
}

pub fn callReadsOnly(name: []const u8, args_json: []const u8, arena: std.mem.Allocator) bool {
    if (!std.mem.eql(u8, name, "bash")) return false;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch return false;
    if (parsed != .object) return false;
    const cmd = parsed.object.get("command") orelse return false;
    if (cmd != .string) return false;
    return cmdsafety.isReadOnly(cmd.string, arena);
}

pub fn callIsWrite(name: []const u8, args_json: []const u8, arena: std.mem.Allocator) bool {
    if (std.mem.eql(u8, name, "batch")) return tools_mod.callWrites(name, args_json, arena);
    if (std.mem.eql(u8, name, "mcp")) return tools_mod.callWrites(name, args_json, arena);
    if (std.mem.eql(u8, name, "github")) return tools_mod.callWrites(name, args_json, arena);
    if (std.mem.eql(u8, name, "memory")) return tools_mod.callWrites(name, args_json, arena);
    return isWriteTool(name);
}

pub const read_only_text =
    "PLAN MODE is on: you may read, but write/edit/bash/rename and the git mutations (add/commit/stash/branch) did not run. " ++
    "Read-only bash commands (git status, git diff, rg, ls, cat) still run and do not ask. " ++
    "Do NOT retry the blocked one. Read what you need and write the IMPLEMENTATION PLAN with the `todo` tool, " ++
    "then end your turn — the user will be asked to approve it and zode will switch itself out of plan mode. " ++
    "For anything you need to know first, use `ask` — or say so in one line — the user can turn plan mode off with shift+tab.";

pub const BashGate = union(enum) {
    ok,
    forbidden: []const u8,
};

pub fn shouldBlockReadOnly(read_only_mode: bool, name: []const u8, args_json: []const u8, arena: std.mem.Allocator) bool {
    if (!read_only_mode) return false;
    const reads_only = callReadsOnly(name, args_json, arena);
    if (reads_only) return false;
    return callIsWrite(name, args_json, arena);
}

/// Refuse commands that require an interactive TTY the harness cannot provide.
pub fn checkBashForbidden(args_json: []const u8, arena: std.mem.Allocator) BashGate {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch return .ok;
    if (parsed != .object) return .ok;
    const cmdv = parsed.object.get("command") orelse return .ok;
    if (cmdv != .string) return .ok;
    const f = cmdsafety.classify(cmdv.string, arena);
    if (f.verdict != .forbidden) return .ok;
    if (f.why.len > 0) {
        const msg = std.fmt.allocPrint(
            arena,
            "refused: {s}\ncommand: {s}",
            .{ f.why, f.fragment },
        ) catch "refused: this command requires an interactive TTY the harness does not have.";
        return .{ .forbidden = msg };
    }
    return .{ .forbidden = "refused: this command requires an interactive TTY the harness does not have." };
}

pub fn startedBackground(res: []const u8) bool {
    return std.mem.startsWith(u8, res, "started in the background as job ");
}

/// Tools that touch a file for undo snapshot purposes.
pub fn touchesFile(name: []const u8) bool {
    return std.mem.eql(u8, name, "write") or
        std.mem.eql(u8, name, "edit") or
        std.mem.eql(u8, name, "notebook_edit");
}

/// Enrich a bash permission dialog detail with the command risk reason, if any.
pub fn enrichBashPermissionDetail(detail: []const u8, command_arg: []const u8, arena: std.mem.Allocator) []const u8 {
    const why = cmdsafety.classify(command_arg, arena).why;
    if (why.len == 0) return detail;
    var both: [640]u8 = undefined;
    return std.fmt.bufPrint(&both, "{s} — {s}", .{ detail, why }) catch detail;
}
