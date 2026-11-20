/// Project permission rules (`.zode/permissions.json`) and hooks (`.zode/hooks.json`).
///
/// Loads/parses config into caller-owned arenas/sets. `agent.zig` owns the
/// runtime globals and public API; this module holds resolution and parsing logic.
const std = @import("std");
const permrules = @import("../lib/permrules.zig");
const hooks_mod = @import("../lib/hooks.zig");

pub const project_rules_file = ".zode/permissions.json";
pub const project_hooks_file = ".zode/hooks.json";

pub fn resolvedProjectRulesPath(buf: []u8, project_root: ?[]const u8) []const u8 {
    if (project_root) |root| {
        return std.mem.print(buf, "{s}/{s}", .{ root, project_rules_file }) catch project_rules_file;
    }
    return project_rules_file;
}

pub fn resolvedProjectHooksPath(buf: []u8, project_root: ?[]const u8) []const u8 {
    if (project_root) |root| {
        return std.mem.print(buf, "{s}/{s}", .{ root, project_hooks_file }) catch project_hooks_file;
    }
    return project_hooks_file;
}

fn readFileToWith(io: std.Io, arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch null;
}

/// Loads rules from project/user files into the given arena and writes `out`.
pub fn loadPermRulesInto(
    out: *permrules.Set,
    arena: std.mem.Allocator,
    io: std.Io,
    project_path: ?[]const u8,
    user_path: ?[]const u8,
) void {
    var all: std.ArrayList(permrules.Rule) = .empty;

    if (project_path) |path| {
        if (readFileToWith(io, arena, path)) |data| {
            if (std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{})) |parsed| {
                for (permrules.parseJson(parsed, .project, arena)) |r| all.append(arena, r) catch {};
            } else |_| {}
        }
    }

    if (user_path) |path| {
        if (readFileToWith(io, arena, path)) |data| {
            if (std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{})) |parsed| {
                for (permrules.parseJson(parsed, .user, arena)) |r| all.append(arena, r) catch {};
            } else |_| {}
        }
    }

    out.* = .{ .rules = all.items };
}

pub fn loadHooksAt(out: *hooks_mod.Set, arena: std.mem.Allocator, io: std.Io, path: []const u8) void {
    out.* = .{};
    if (readFileToWith(io, arena, path)) |data| {
        out.* = hooks_mod.parseConfig(arena, data);
    }
}

/// Loads USER hooks first, then PROJECT hooks. A project hook with the same
/// event+matcher+condition replaces the user one, so a repo can override a
/// personal automation without deleting it. Malformed files are skipped, never
/// fatal — a broken hook must not stop the agent from starting.
pub fn loadHooksMerged(
    out: *hooks_mod.Set,
    arena: std.mem.Allocator,
    io: std.Io,
    user_path: ?[]const u8,
    project_path: []const u8,
) void {
    var all: std.ArrayList(hooks_mod.Hook) = .empty;
    if (user_path) |path| {
        if (readFileToWith(io, arena, path)) |data| {
            const set = hooks_mod.parseConfig(arena, data);
            for (set.hooks) |h| all.append(arena, h) catch {};
        }
    }
    if (readFileToWith(io, arena, project_path)) |data| {
        const set = hooks_mod.parseConfig(arena, data);
        for (set.hooks) |h| {
            var i: usize = 0;
            while (i < all.items.len) : (i += 1) {
                const e = all.items[i];
                if (e.event == h.event and std.mem.eql(u8, e.matcher, h.matcher) and
                    std.mem.eql(u8, e.@"if", h.@"if"))
                {
                    _ = all.orderedRemove(i);
                    break;
                }
            }
            all.append(arena, h) catch {};
        }
    }
    out.* = .{ .hooks = all.items };
}

test "loadHooksMerged: project overrides user on the same event, others survive" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const user = "{\"hooks\":[{\"event\":\"Stop\",\"command\":\"echo user\"},{\"event\":\"SessionStart\",\"command\":\"echo user-start\"}]}";
    const project = "{\"hooks\":[{\"event\":\"Stop\",\"command\":\"echo project\"}]}";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "user.json", .data = user });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project.json", .data = project });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try a.dupe(u8, buf[0..try tmp.dir.realPath(std.testing.io, &buf)]);
    const up = try std.fmt.allocPrint(a, "{s}/user.json", .{dir});
    const pp = try std.fmt.allocPrint(a, "{s}/project.json", .{dir});

    var set: hooks_mod.Set = .{};
    loadHooksMerged(&set, a, std.testing.io, up, pp);
    try std.testing.expectEqual(@as(usize, 2), set.hooks.len);
    var saw_project = false;
    var saw_user_start = false;
    for (set.hooks) |h| {
        if (std.mem.eql(u8, h.command, "echo project")) saw_project = true;
        if (std.mem.eql(u8, h.command, "echo user-start")) saw_user_start = true;
        try std.testing.expect(!std.mem.eql(u8, h.command, "echo user"));
    }
    try std.testing.expect(saw_project);
    try std.testing.expect(saw_user_start);
}

pub fn hooksPathForProjectPermissions(pp: []const u8, buf: []u8) ?[]const u8 {
    const dir = std.fs.path.dirname(pp) orelse ".";
    return std.mem.print(buf, "{s}/{s}", .{ dir, "hooks.json" }) catch null;
}
