const std = @import("std");
const common = @import("common.zig");

// ── think: scratchpad with no side effects (planning) ────────
pub fn toolThink(obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const thought = common.getStr(obj, "thought") orelse return error.MissingPath;
    return std.fmt.allocPrint(arena, "noted ({d} chars). Continue with your plan.", .{thought.len});
}
