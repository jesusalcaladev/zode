//! Continuous improvement decisions (pure). Same contract as the OpenCode plugin.

const std = @import("std");

pub const Finding = struct {
    impact: []const u8,
    risk: []const u8,
    files: []const []const u8,
    text: []const u8,
};

pub const Action = union(enum) {
    audit,
    implement: Finding,
    stop: []const u8,
};

pub const Input = struct {
    findings: []const Finding = &.{},
    min_impact: []const u8 = "medium",
    improve_cycles: usize = 0,
    max_cycles: usize = 5,
    clean_rounds: usize = 0,
    max_clean_rounds: usize = 2,
    stop_file: bool = false,
    out_of_budget: bool = false,
};

fn rank(impact: []const u8) u8 {
    if (std.mem.eql(u8, impact, "high")) return 3;
    if (std.mem.eql(u8, impact, "medium")) return 2;
    return 1;
}

fn value(f: Finding) i32 {
    const risk_penalty: i32 = if (std.mem.eql(u8, f.risk, "high")) 3 else if (std.mem.eql(u8, f.risk, "medium")) 1 else 0;
    return @as(i32, rank(f.impact)) * 10 - risk_penalty;
}

pub fn parseFindings(gpa: std.mem.Allocator, text: []const u8) ![]Finding {
    var out = std.ArrayList(Finding).empty;
    errdefer out.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const at = std.mem.indexOf(u8, raw, "FINDING:") orelse std.mem.indexOf(u8, raw, "finding:") orelse continue;
        const body = std.mem.trim(u8, raw[at + 8 ..], " \t\r");
        var impact: []const u8 = "low";
        var risk: []const u8 = "low";
        var files_text: []const u8 = "";
        if (std.mem.indexOf(u8, body, "impact=")) |p| {
            const rest = body[p + 7 ..];
            const end = std.mem.indexOfAny(u8, rest, " \t,") orelse rest.len;
            impact = rest[0..end];
        }
        if (std.mem.indexOf(u8, body, "risk=")) |p| {
            const rest = body[p + 5 ..];
            const end = std.mem.indexOfAny(u8, rest, " \t,") orelse rest.len;
            risk = rest[0..end];
        }
        if (std.mem.indexOf(u8, body, "files=")) |p| {
            const rest = body[p + 6 ..];
            const end = std.mem.indexOfAny(u8, rest, " \t;") orelse rest.len;
            files_text = rest[0..end];
        }
        var files = std.ArrayList([]const u8).empty;
        var fit = std.mem.tokenizeAny(u8, files_text, ",|");
        while (fit.next()) |f| try files.append(gpa, try gpa.dupe(u8, f));
        if (rank(impact) == 1) continue;
        try out.append(gpa, .{
            .impact = try gpa.dupe(u8, impact),
            .risk = try gpa.dupe(u8, risk),
            .files = try files.toOwnedSlice(gpa),
            .text = try gpa.dupe(u8, body),
        });
    }
    std.mem.sort(Finding, out.items, {}, struct {
        fn less(_: void, a: Finding, b: Finding) bool {
            return value(b) < value(a);
        }
    }.less);
    return out.toOwnedSlice(gpa);
}

pub fn decide(input: Input) Action {
    if (input.stop_file) return .{ .stop = "stop-file" };
    if (input.out_of_budget) return .{ .stop = "budget" };
    if (input.improve_cycles >= input.max_cycles) return .{ .stop = "improve-cycle-limit" };
    if (input.clean_rounds >= input.max_clean_rounds) return .{ .stop = "no-high-value-improvements" };
    for (input.findings) |f| {
        if (rank(f.impact) >= rank(input.min_impact) and !std.mem.eql(u8, f.risk, "high")) return .{ .implement = f };
    }
    return .audit;
}

test "improve: findings are parsed and ranked above the threshold" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "FINDING: impact=high risk=low files=a.zig,b.zig add a guard\nFINDING: impact=low risk=low files=c.zig style";
    const findings = try parseFindings(a, text);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(@as(usize, 2), findings[0].files.len);
    const action = decide(.{ .findings = findings });
    try std.testing.expectEqual(@as(std.meta.Tag(Action), .implement), std.meta.activeTag(action));
}

test "improve: stops on threshold, cycles and budget" {
    try std.testing.expectEqualStrings("no-high-value-improvements", decide(.{ .clean_rounds = 2 }).stop);
    try std.testing.expectEqualStrings("improve-cycle-limit", decide(.{ .improve_cycles = 5 }).stop);
    try std.testing.expectEqualStrings("budget", decide(.{ .out_of_budget = true }).stop);
    try std.testing.expectEqual(@as(std.meta.Tag(Action), .audit), std.meta.activeTag(decide(.{})));
}
