/// Persistence for the simple allowlist (`~/.config/zode/permissions.json`).
///
/// Separates path/format logic from `agent.zig` runtime globals and TUI state.
/// IO and global allocators stay with the caller.
const std = @import("std");
const config_mod = @import("../config.zig");

pub fn filePath(buf: []u8, env: ?*const std.process.Environ.Map) ?[]const u8 {
    const e = env orelse return null;
    const home = e.get("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/zode/permissions.json", .{home}) catch null;
}

pub const ParseResult = struct {
    tools: []const []const u8 = &.{},
    bash: []const []const u8 = &.{},
};

/// Parses allowlist data (arena-allocated slices point into/are allocated from arena).
/// Supports legacy array form (tools only) and object form `{tools:[...], bash:[...]}`.
pub fn parse(arena: std.mem.Allocator, data: []const u8) ParseResult {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{}) catch return .{};
    var tools_list: std.ArrayList([]const u8) = .empty;
    var bash_list: std.ArrayList([]const u8) = .empty;
    switch (parsed) {
        .array => |arr| for (arr.items) |v| {
            if (v == .string) tools_list.append(arena, v.string) catch {};
        },
        .object => |obj| {
            if (obj.get("tools")) |tv| {
                if (tv == .array) for (tv.array.items) |v| {
                    if (v == .string) tools_list.append(arena, v.string) catch {};
                };
            }
            if (obj.get("bash")) |bv| {
                if (bv == .array) for (bv.array.items) |v| {
                    if (v == .string) bash_list.append(arena, v.string) catch {};
                };
            }
        },
        else => {},
    }
    return .{
        .tools = tools_list.items,
        .bash = bash_list.items,
    };
}

/// Formats the allowlist as `{"tools":[...],"bash":[...]}` into `buf`.
pub fn format(
    buf: []u8,
    gpa: std.mem.Allocator,
    tool_names: []const []const u8,
    bash_patterns: []const []const u8,
) ?[]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print("{{\"tools\":", .{}) catch return null;
    config_mod.writeStringArray(&w, gpa, tool_names) catch return null;
    w.print(",\"bash\":", .{}) catch return null;
    config_mod.writeStringArray(&w, gpa, bash_patterns) catch return null;
    w.print("}}", .{}) catch return null;
    return w.buffered();
}

test "parse legacy array and object forms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r1 = parse(a, "[\"write\",\"edit\"]");
    try std.testing.expectEqual(@as(usize, 2), r1.tools.len);
    try std.testing.expectEqual(@as(usize, 0), r1.bash.len);
    const r2 = parse(a, "{\"tools\":[\"edit\"],\"bash\":[\"git status\"]}");
    try std.testing.expectEqualStrings("edit", r2.tools[0]);
    try std.testing.expectEqualStrings("git status", r2.bash[0]);
}

test "format round shape" {
    var buf: [512]u8 = undefined;
    const out = format(&buf, std.testing.allocator, &.{"edit"}, &.{"git status"}) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, out, "\"tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"bash\"") != null);
}
