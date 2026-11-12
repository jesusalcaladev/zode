const std = @import("std");
const permrules = @import("../lib/permrules.zig");
const tool_exec_perm = @import("tool_exec_perm.zig");

pub const RulePreflight = struct {
    allowed: bool = false,
    denied_msg: ?[]const u8 = null,
    ask_text: []const u8 = "",
};

pub fn rulePreflight(decision: ?permrules.Decision, arena: std.mem.Allocator) RulePreflight {
    const d = decision orelse return .{};
    return switch (d.action) {
        .allow, .dontAsk => .{ .allowed = true },
        .deny => .{
            .denied_msg = tool_exec_perm.formatRuleDenyMessage(d.rule.text, d.rule.source.name(), arena),
        },
        .ask => .{
            .ask_text = tool_exec_perm.formatRuleAskText(d.rule.text, d.rule.pattern, d.rule.source, arena),
        },
    };
}

pub fn needsPermissionDialog(
    yolo: bool,
    auto_allowed: bool,
    risky_allowed: bool,
    rule_allowed: bool,
    no_dialog: bool,
    perm_needs_dialog: bool,
) bool {
    return !yolo and !auto_allowed and !risky_allowed and !rule_allowed and !no_dialog and perm_needs_dialog;
}
