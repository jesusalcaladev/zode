//! Pure formatter for the nested tool/subagent tree.
//!
//! The TUI never parses rendered strings to recover runtime state
//! (RULES-ZODE-TUI.md): a caller that KNOWS a task has children passes the
//! structured nodes here, and this module only decides how to draw the
//! branches. Nothing is inferred from text, and no state is invented — an
//! empty node list renders an empty string.
const std = @import("std");

pub const Status = enum { running, done, open, info };

pub const Node = struct {
    /// 0 = a task, 1 = a tool inside it, 2 = a nested child, ...
    depth: u8 = 0,
    label: []const u8,
    status: Status = .info,
};

fn marker(status: Status) []const u8 {
    return switch (status) {
        .running => "◐",
        .done => "✓",
        .open => "·",
        .info => " ",
    };
}

/// Renders `nodes` as indented `├─` / `└─` lines. The last child of each level
/// closes the branch with `└─`; earlier siblings keep the `│` guide so a reader
/// can see which task a tool belongs to after several wraps.
pub fn render(arena: std.mem.Allocator, nodes: []const Node) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    for (nodes, 0..) |node, i| {
        if (i > 0) try out.append(arena, '\n');
        var d: usize = 0;
        while (d < node.depth) : (d += 1) try out.appendSlice(arena, "│  ");
        const last = i + 1 == nodes.len or nodes[i + 1].depth < node.depth;
        try out.appendSlice(arena, if (last) "└─ " else "├─ ");
        try out.appendSlice(arena, marker(node.status));
        try out.append(arena, ' ');
        try out.appendSlice(arena, node.label);
    }
    return out.toOwnedSlice(arena);
}

test "treetext: nested nodes get branch guides and a closing corner" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const nodes = [_]Node{
        .{ .depth = 0, .label = "task: review auth", .status = .running },
        .{ .depth = 1, .label = "Read(src/main.zig)", .status = .done },
        .{ .depth = 1, .label = "grep(permission)", .status = .running },
        .{ .depth = 0, .label = "task: tests", .status = .open },
    };
    const text = try render(a, &nodes);
    try std.testing.expectEqualStrings(
        "├─ ◐ task: review auth\n" ++
            "│  ├─ ✓ Read(src/main.zig)\n" ++
            "│  └─ ◐ grep(permission)\n" ++
            "└─ · task: tests",
        text,
    );
}

test "treetext: no nodes means no invented tree" {
    const text = try render(std.testing.allocator, &.{});
    try std.testing.expectEqual(@as(usize, 0), text.len);
}
