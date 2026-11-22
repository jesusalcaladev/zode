//! Mission chaining (pure): roadmap parsing, EXTEND decisions, budget growth.

const std = @import("std");

pub const Item = struct { id: []const u8, title: []const u8, done: bool };
pub const StopReason = enum { budget, turns, writes, deadline, blocked, other };
pub const Decision = enum { work, extend, stop };

pub fn parseRoadmap(gpa: std.mem.Allocator, text: []const u8) ![]Item {
    var out = std.ArrayList(Item).empty;
    errdefer out.deinit(gpa);
    var index: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "- [")) continue;
        if (line.len < 6 or line[4] != ']') continue;
        index += 1;
        var body = std.mem.trim(u8, line[5..], " \t");
        var id_buf: [64]u8 = undefined;
        var id: []const u8 = undefined;
        if (std.mem.startsWith(u8, body, "id:")) {
            const rest = std.mem.trim(u8, body[3..], " \t");
            const colon = std.mem.indexOfAny(u8, rest, ":|-") orelse 0;
            const candidate = std.mem.trim(u8, rest[0..colon], " \t");
            if (candidate.len > 0 and candidate.len < id_buf.len) {
                @memcpy(id_buf[0..candidate.len], candidate);
                id = try gpa.dupe(u8, id_buf[0..candidate.len]);
                body = std.mem.trim(u8, rest[colon + 1 ..], " \t");
            } else {
                id = try std.fmt.allocPrint(gpa, "item-{d}", .{index});
            }
        } else {
            id = try std.fmt.allocPrint(gpa, "item-{d}", .{index});
        }
        try out.append(gpa, .{
            .id = id,
            .title = try gpa.dupe(u8, body),
            .done = line[3] == 'x' or line[3] == 'X',
        });
    }
    return out.toOwnedSlice(gpa);
}

pub fn nextItem(items: []const Item) ?Item {
    for (items) |item| if (!item.done) return item;
    return null;
}

pub fn chainDecision(reason: StopReason, extend_requested: bool, extensions: usize, max_extensions: usize) Decision {
    if (reason == .blocked) return .stop;
    if (extend_requested and extensions < max_extensions and reason != .other) return .extend;
    return .stop;
}

pub const Budget = struct {
    max_turns: usize = 16,
    max_wallclock_min: usize = 0,
    max_writes: usize = 0,
};

pub fn applyExtension(budget: Budget) Budget {
    return .{
        .max_turns = budget.max_turns + 8,
        .max_wallclock_min = if (budget.max_wallclock_min > 0) budget.max_wallclock_min + 30 else 0,
        .max_writes = if (budget.max_writes > 0) budget.max_writes + 50 else 0,
    };
}

test "chain: roadmap parsing and next item" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const items = try parseRoadmap(a, "# Roadmap\n- [x] id: one: done thing\n- [ ] id: two: pending thing\n");
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expect(items[0].done);
    const next = nextItem(items).?;
    try std.testing.expectEqualStrings("two", next.id);
}

test "chain: EXTEND is bounded and never unblocks a blocked mission" {
    try std.testing.expectEqual(Decision.extend, chainDecision(.turns, true, 0, 3));
    try std.testing.expectEqual(Decision.stop, chainDecision(.turns, true, 3, 3));
    try std.testing.expectEqual(Decision.stop, chainDecision(.blocked, true, 0, 3));
    const grown = applyExtension(.{ .max_turns = 16, .max_wallclock_min = 30, .max_writes = 100 });
    try std.testing.expect(grown.max_turns > 16);
    try std.testing.expect(grown.max_writes > 100);
}
