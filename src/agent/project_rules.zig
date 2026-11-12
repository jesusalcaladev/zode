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
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ root, project_rules_file }) catch project_rules_file;
    }
    return project_rules_file;
}

pub fn resolvedProjectHooksPath(buf: []u8, project_root: ?[]const u8) []const u8 {
    if (project_root) |root| {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ root, project_hooks_file }) catch project_hooks_file;
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

pub fn hooksPathForProjectPermissions(pp: []const u8, buf: []u8) ?[]const u8 {
    const dir = std.fs.path.dirname(pp) orelse ".";
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, "hooks.json" }) catch null;
}
