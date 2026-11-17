//! Plugin disk storage (Phase 13.1). The pure rules live in `plugins.zig`;
//! this module owns the filesystem: discover, install from the bundled
//! catalog, remove, and toggle. Project plugins shadow user plugins by name.
//! All writes stay inside `.zode/plugins/` of the project root (or the user
//! config dir for reads), so a plugin name can never escape its directory.

const std = @import("std");
const plugins = @import("plugins.zig");

pub const project_dir = ".zode/plugins";
pub const user_subdir = "zode/plugins";
pub const filename = "plugin.json";
pub const max_manifest = 64 * 1024;
pub const max_installed = 64;

pub const Installed = struct {
    name: []const u8,
    path: []const u8,
    manifest: plugins.Manifest,
    /// "project" or "user" — shown by `/plugin list`.
    source: []const u8,
};

pub fn projectPath(gpa: std.mem.Allocator, project_root: []const u8, name: []const u8) ![]u8 {
    if (!plugins.validName(name)) return error.BadName;
    return std.fmt.allocPrint(gpa, "{s}/{s}/{s}/{s}", .{ project_root, project_dir, name, filename });
}

pub fn userRoot(gpa: std.mem.Allocator, env: ?*const std.process.Environ.Map) !?[]u8 {
    const home = if (env) |e| e.get("HOME") else null;
    if (home == null or home.?.len == 0) return null;
    return @as(?[]u8, try std.fmt.allocPrint(gpa, "{s}/.config/{s}", .{ home.?, user_subdir }));
}

/// Scan one root. Only `<name>/plugin.json` entries are considered; malformed
/// manifests are skipped so one bad plugin cannot hide the others.
pub fn scanRoot(gpa: std.mem.Allocator, io: std.Io, root: []const u8, source: []const u8, out: *std.ArrayList(Installed), cap: usize) void {
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (out.items.len >= cap) return;
        if (entry.kind != .directory or !plugins.validName(entry.name)) continue;
        const rel = std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ root, entry.name, filename }) catch continue;
        defer gpa.free(rel);
        const data = std.Io.Dir.cwd().readFileAlloc(io, rel, gpa, .limited(max_manifest)) catch continue;
        defer gpa.free(data);
        const m = plugins.parse(gpa, data) catch continue;
        // A folder named `review` containing a plugin called `other` is not
        // installed under `other`: keep the on-disk identity honest.
        if (!std.mem.eql(u8, m.name, entry.name)) continue;
        var duplicate = false;
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing.name, m.name)) duplicate = true;
        }
        if (duplicate) continue;
        out.append(gpa, .{
            .name = gpa.dupe(u8, m.name) catch continue,
            .path = gpa.dupe(u8, rel) catch continue,
            .manifest = m,
            .source = source,
        }) catch {};
    }
}

/// Project plugins are added first, so they shadow user plugins of the same
/// name. Returns owned strings; caller frees with `freeInstalled`.
pub fn discover(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, project_root: []const u8) ![]Installed {
    var out: std.ArrayList(Installed) = .empty;
    errdefer freeInstalled(gpa, out.items);
    const proj = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ project_root, project_dir });
    defer gpa.free(proj);
    scanRoot(gpa, io, proj, "project", &out, max_installed);
    if (try userRoot(gpa, env)) |ur| {
        defer gpa.free(ur);
        scanRoot(gpa, io, ur, "user", &out, max_installed);
    }
    return try out.toOwnedSlice(gpa);
}

pub fn freeInstalled(gpa: std.mem.Allocator, items: []const Installed) void {
    for (items) |it| {
        gpa.free(it.name);
        gpa.free(it.path);
    }
    gpa.free(items);
}

/// Install a bundled catalog entry into the project. Refuses to overwrite an
/// existing plugin: use `remove` first so an edit is never silently lost.
pub fn install(gpa: std.mem.Allocator, io: std.Io, project_root: []const u8, name: []const u8) ![]u8 {
    const entry = plugins.findInCatalog(name) orelse return error.UnknownPlugin;
    const path = try projectPath(gpa, project_root, name);
    defer gpa.free(path);
    if (std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_manifest)) catch null) |existing| {
        gpa.free(existing);
        return error.AlreadyInstalled;
    }
    const body = try plugins.catalogManifest(gpa, entry);
    defer gpa.free(body);
    const dir_path = path[0 .. path.len - filename.len - 1];
    try std.Io.Dir.cwd().createDirPath(io, dir_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body });
    return gpa.dupe(u8, path);
}

pub fn remove(gpa: std.mem.Allocator, io: std.Io, project_root: []const u8, name: []const u8) !void {
    if (!plugins.validName(name)) return error.BadName;
    const dir_path = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ project_root, project_dir, name });
    defer gpa.free(dir_path);
    try std.Io.Dir.cwd().deleteTree(io, dir_path);
}

/// Toggle `enabled` in a manifest while preserving every other field.
pub fn setEnabled(gpa: std.mem.Allocator, io: std.Io, path: []const u8, enabled: bool) !void {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_manifest));
    defer gpa.free(data);
    var root = std.json.parseFromSliceLeaky(std.json.Value, gpa, data, .{}) catch return error.BadPlugin;
    if (root != .object) return error.BadPlugin;
    try root.object.put(gpa, "enabled", .{ .bool = enabled });
    const out = try std.json.Stringify.valueAlloc(gpa, root, .{ .whitespace = .indent_1 });
    defer gpa.free(out);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out });
}

test "pluginstore: install, discover and remove a bundled plugin" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try a.dupe(u8, ".");
    _ = root;
    // Use the fixture root that tmpDir gives us, via dir.path resolved by the
    // walker-free helper below (tmpDir exposes a real path through `dir`).
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = path_buf[0..try tmp.dir.realPath(std.testing.io, &path_buf)];
    const installed = try install(a, std.testing.io, cwd, "review-checklist");
    try std.testing.expect(std.mem.endsWith(u8, installed, "review-checklist/plugin.json"));
    try std.testing.expectError(error.AlreadyInstalled, install(a, std.testing.io, cwd, "review-checklist"));

    const list = try discover(a, std.testing.io, null, cwd);
    defer freeInstalled(a, list);
    var found = false;
    for (list) |it| {
        if (std.mem.eql(u8, it.name, "review-checklist")) found = true;
    }
    try std.testing.expect(found);

    try setEnabled(a, std.testing.io, installed, false);
    const list2 = try discover(a, std.testing.io, null, cwd);
    defer freeInstalled(a, list2);
    for (list2) |it| {
        if (std.mem.eql(u8, it.name, "review-checklist")) try std.testing.expect(!it.manifest.enabled);
    }

    try remove(a, std.testing.io, cwd, "review-checklist");
    const list3 = try discover(a, std.testing.io, null, cwd);
    defer freeInstalled(a, list3);
    try std.testing.expectEqual(@as(usize, 0), list3.len);
}
