//! Durable mission memory (pure). Distills the raw journal into a bounded text
//! that is injected into every model request. No IO, no model, no TUI.

const std = @import("std");

pub const budget: usize = 4000;
const worth = "decid|approach|discard|blocker|blocked|verified|commit|erosion|fatal|failed|retry|handoff|migrat|constraint|must not|owner";

pub const Distilled = struct {
    memory: []const u8,
    summary: []const u8,
};

fn stripStamp(line: []const u8) []const u8 {
    var s = std.mem.trim(u8, line, " \t\r\n");
    if (s.len > 2 and s[0] == '[') {
        if (std.mem.indexOfScalar(u8, s, ']')) |end| s = std.mem.trim(u8, s[end + 1 ..], " \t");
    }
    return s;
}

fn containsCi(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var same = true;
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(c)) {
                same = false;
                break;
            }
        }
        if (same) return true;
    }
    return false;
}

fn hasWorth(text: []const u8) bool {
    var it = std.mem.splitScalar(u8, worth, '|');
    while (it.next()) |needle| {
        if (containsCi(text, needle)) return true;
    }
    return false;
}

pub fn distill(gpa: std.mem.Allocator, journal: []const u8, memory: []const u8, max_chars: usize) !Distilled {
    var kept = std.ArrayList([]const u8).empty;
    defer kept.deinit(gpa);
    var seen = std.StringHashMap(void).init(gpa);
    defer seen.deinit();

    var m_lines = std.mem.splitScalar(u8, memory, '\n');
    while (m_lines.next()) |raw| {
        const line = stripStamp(raw);
        if (line.len == 0 or line[0] == '#') continue;
        const result = try seen.getOrPut(line);
        if (result.found_existing) continue;
        try kept.append(gpa, line);
    }

    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(gpa);
    var j_lines = std.mem.splitScalar(u8, journal, '\n');
    while (j_lines.next()) |raw| {
        const line = stripStamp(raw);
        if (line.len == 0 or line[0] == '#') continue;
        try lines.append(gpa, line);
    }
    var i = lines.items.len;
    while (i > 0) {
        i -= 1;
        const line = lines.items[i];
        if (!hasWorth(line)) continue;
        if (seen.contains(line)) continue;
        try seen.put(line, {});
        try kept.insert(gpa, 0, line);
        var total: usize = 0;
        for (kept.items) |k| total += k.len + 1;
        if (total > max_chars) {
            _ = kept.orderedRemove(0);
            break;
        }
    }

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    for (kept.items, 0..) |line, idx| {
        if (idx > 0) try out.append(gpa, '\n');
        try out.appendSlice(gpa, line);
    }
    const text = out.items[0..@min(out.items.len, max_chars)];
    const preview_end = @min(text.len, 300);
    const summary = try std.fmt.allocPrint(gpa, "Memory entries: {d} · {s}", .{ kept.items.len, text[0..preview_end] });
    return .{ .memory = try gpa.dupe(u8, text), .summary = summary };
}

test "memory: distilled output never exceeds its character budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var journal = std.ArrayList(u8).empty;
    for (0..40) |i| {
        const line = try std.fmt.allocPrint(a, "[2026-01-01] decision: rebuild step {d} passed with 3 green checks\n", .{i});
        try journal.appendSlice(a, line);
    }
    const out = try distill(a, journal.items, "", 240);
    try std.testing.expect(out.memory.len <= 240);
    try std.testing.expect(out.summary.len > 0);
}

test "memory: distill keeps decisions and drops the rest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const journal = "[t1] looked at the tree\n[t2] decided to keep the contract host-agnostic\n[t3] decided to keep the contract host-agnostic\n[t4] blocker: lease expired\n";
    const out = try distill(a, journal, "", 4000);
    try std.testing.expect(std.mem.indexOf(u8, out.memory, "host-agnostic") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.memory, "looked at the tree") == null);
    const count = std.mem.count(u8, out.memory, "host-agnostic");
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expect(out.memory.len <= 4000);
}
