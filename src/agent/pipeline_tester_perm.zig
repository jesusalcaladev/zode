const std = @import("std");
const tui = @import("../tui.zig");
const permrules = @import("../lib/permrules.zig");
const tools_mod = @import("../tools/dispatch.zig");
const tool_exec_perm = @import("tool_exec_perm.zig");
const pathsafe = @import("../lib/pathsafe.zig");

pub const Ops = struct {
    yolo: *const fn () bool,
    toolArgSummary: *const fn ([]const u8, []const u8, std.mem.Allocator) []const u8,
    permDecision: *const fn ([]const u8, []const []const u8) ?permrules.Decision,
    permAutoAllowed: *const fn ([]const u8, []const u8, []const u8, std.mem.Allocator) bool,
};

pub const PipelineRuleCheck = struct {
    rule_allowed: bool = false,
    rule_text: []const u8 = "",
    deny_msg: ?[]const u8 = null,
};

pub fn resolvePipelinePermRule(
    ops: Ops,
    call_name: []const u8,
    args_json: []const u8,
    arena: std.mem.Allocator,
) PipelineRuleCheck {
    const subjects = tools_mod.callSubjects(call_name, args_json, arena);
    var out = PipelineRuleCheck{};
    if (ops.permDecision(call_name, subjects)) |d| {
        switch (d.action) {
            .deny => {
                out.deny_msg = tool_exec_perm.formatRuleDenyMessage(d.rule.text, d.rule.source.name(), arena);
            },
            .allow, .dontAsk => out.rule_allowed = true,
            .ask => out.rule_text = d.rule.text,
        }
    }
    return out;
}

pub fn pipelineCheckSensitivePaths(
    m: *tui.Model,
    arena: std.mem.Allocator,
    call_name: []const u8,
    args_json: []const u8,
    rule_allowed: bool,
) ?[]const u8 {
    if (rule_allowed) return null;
    const risky = tools_mod.riskyPaths(call_name, args_json, arena);
    for (risky) |p| {
        const v = pathsafe.checkWrite(p);
        if (v == .ok) continue;
        const detail = std.fmt.allocPrint(
            arena,
            "{s} is not a place this tool writes (tester — pipeline)",
            .{p},
        ) catch p;
        switch (m.requestPermissionOnce(call_name, detail)) {
            .allow, .allow_always => pathsafe.approve(p),
            else => return "denied: the user refused this write.",
        }
    }
    return null;
}

pub fn pipelineWriteGate(
    m: *tui.Model,
    arena: std.mem.Allocator,
    call_name: []const u8,
    args_json: []const u8,
    ops: Ops,
) ?[]const u8 {
    if (ops.yolo()) return null;

    const arg = ops.toolArgSummary(call_name, args_json, arena);

    const rule = resolvePipelinePermRule(ops, call_name, args_json, arena);
    if (rule.deny_msg) |msg| return msg;
    const rule_allowed = rule.rule_allowed;
    const rule_text = rule.rule_text;

    if (pipelineCheckSensitivePaths(m, arena, call_name, args_json, rule_allowed)) |refusal| return refusal;

    const auto_allowed = ops.permAutoAllowed(call_name, arg, args_json, arena);
    if (rule_allowed or auto_allowed) return null;
    var dbuf: [384]u8 = undefined;
    const detail = std.fmt.bufPrint(&dbuf, "tester: {s} {s}", .{ call_name, arg }) catch call_name;
    var with_rule: [512]u8 = undefined;
    const full = if (rule_text.len > 0)
        std.fmt.bufPrint(&with_rule, "{s} — your rule `{s}` matches", .{ detail, rule_text }) catch detail
    else
        detail;
    return switch (m.requestPermission(call_name, full)) {
        .allow, .allow_always => null,
        else => "denied: the user refused this write.",
    };
}
