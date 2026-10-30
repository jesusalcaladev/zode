const std = @import("std");

pub fn main() !void {
    std.debug.print("change_manager - Zig changeset tool\n", .{});
    std.debug.print("Usage: change_manager <add|version|changelog|release> [args...]\n", .{});
    std.debug.print("  add <type> <scope> <description>\n", .{});
    std.debug.print("  version\n", .{});
    std.debug.print("  changelog\n", .{});
    std.debug.print("  release\n", .{});
    std.debug.print("Types: feature, fix, perf, refactor, docs, chore, beta, next, breaking\n", .{});
}