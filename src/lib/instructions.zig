//! Hierarchical instruction files for the system prompt.
//!
//! A project can inherit rules from its parents and from the user's own config,
//! and keep machine-local notes in `CLAUDE.local.md`. Before this module zode
//! read ONE file from cwd/project root and `/init` wrote a `CLAUDE.local.md`
//! that nothing ever loaded — a file that looked authoritative and had no
//! effect at all.
//!
//! Priority (highest first): local, cwd, project root, then parent directories
//! from nearest to furthest, then the user-level file. The same path is never
//! included twice, so `cwd == project_root` cannot duplicate the rules.
const std = @import("std");
const agentsdoc = @import("agentsdoc.zig");

pub const max_files: usize = 16;

/// Builds the ordered list of instruction paths that exist. All I/O goes
/// through `io`; `start_dir` may be relative (".") or a real path.
pub fn collect(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: ?*const std.process.Environ.Map,
    start_dir: []const u8,
    project_root: ?[]const u8,
) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |p| gpa.free(p);
        out.deinit(gpa);
    }

    const dirs = try directories(gpa, io, start_dir, project_root);
    defer {
        for (dirs) |d| gpa.free(d);
        gpa.free(dirs);
    }

    // 1. Machine-local notes, in the nearest two directories.
    for (dirs) |d| {
        _ = try tryAdd(gpa, io, &out, d, "CLAUDE.local.md");
    }
    // 2. Project rules: AGENTS.md wins over CLAUDE.md in the same directory.
    for (dirs) |d| {
        if (!(try tryAdd(gpa, io, &out, d, "AGENTS.md"))) {
            _ = try tryAdd(gpa, io, &out, d, "CLAUDE.md");
        }
    }
    // 3. User-level rules, so a person's preferences follow them across repos.
    if (env) |e| {
        const base = e.get("XDG_CONFIG_HOME") orelse e.get("HOME") orelse "";
        if (base.len > 0) {
            const suffix = if (e.get("XDG_CONFIG_HOME") != null) "/zode/CLAUDE.md" else "/.config/zode/CLAUDE.md";
            const path = try std.fmt.allocPrint(gpa, "{s}{s}", .{ base, suffix });
            if (fileExists(io, path)) {
                try out.append(gpa, path);
            } else {
                gpa.free(path);
            }
        }
    }
    return out.toOwnedSlice(gpa);
}

/// The directories to look in, nearest first and without duplicates.
fn directories(gpa: std.mem.Allocator, io: std.Io, start_dir: []const u8, project_root: ?[]const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |d| gpa.free(d);
        out.deinit(gpa);
    }
    try appendDir(gpa, &out, start_dir);
    if (project_root) |r| try appendDir(gpa, &out, r);

    // Resolve each seed to an absolute path, then walk its parents. A
    // relative "." has no meaningful parent, so resolution failure simply
    // leaves the seed's own directory in the list.
    var i: usize = 0;
    while (i < out.items.len and out.items.len < max_files) : (i += 1) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const len = std.Io.Dir.cwd().realPathFile(io, out.items[i], &buf) catch continue;
        const owned = gpa.dupe(u8, buf[0..len]) catch continue;
        var path = owned;
        while (out.items.len < max_files) {
            const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse break;
            if (slash == 0) break;
            path = path[0..slash];
            try appendDir(gpa, &out, path);
        }
        gpa.free(owned);
    }
    return out.toOwnedSlice(gpa);
}

fn appendDir(gpa: std.mem.Allocator, out: *std.ArrayList([]const u8), dir: []const u8) !void {
    if (dir.len == 0) return;
    for (out.items) |d| {
        if (std.mem.eql(u8, d, dir)) return;
    }
    try out.append(gpa, try gpa.dupe(u8, dir));
}

fn tryAdd(gpa: std.mem.Allocator, io: std.Io, out: *std.ArrayList([]const u8), dir: []const u8, name: []const u8) !bool {
    if (out.items.len >= max_files) return false;
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name });
    if (fileExists(io, path)) {
        try out.append(gpa, path);
        return true;
    }
    gpa.free(path);
    return false;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    return (std.Io.Dir.cwd().statFile(io, path, .{}) catch null) != null;
}

// ── tests ─────────────────────────────────────────────────────

test "instructions: local, nearest and ancestor files are all loaded, once each" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try a.dupe(u8, buf[0..try tmp.dir.realPath(io, &buf)]);
    const sub = try std.fmt.allocPrint(a, "{s}/sub", .{root});
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "project rules" });
    try tmp.dir.writeFile(io, .{ .sub_path = "CLAUDE.local.md", .data = "local rules" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/AGENTS.md", .data = "sub rules" });

    const paths = try collect(a, io, null, sub, root);
    defer {
        for (paths) |p| a.free(p);
        a.free(paths);
    }
    // The temp directory lives under the repo's .zig-cache, so the repo's own
    // AGENTS.md is the fourth (ancestor) path — that IS the hierarchy working.
    try std.testing.expect(paths.len >= 3);
    // Highest priority first: the local notes the old code never read.
    try std.testing.expect(std.mem.endsWith(u8, paths[0], "CLAUDE.local.md"));
    try std.testing.expect(std.mem.indexOf(u8, paths[1], "sub/AGENTS.md") != null or std.mem.endsWith(u8, paths[1], "sub/AGENTS.md"));
    try std.testing.expect(std.mem.endsWith(u8, paths[2], "AGENTS.md"));

    const text = (try loadAll(a, io, null, sub, root)).?;
    for ([_][]const u8{ "local rules", "sub rules", "project rules" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, text, needle) != null);
    }
    // One copy of each rule, not one per directory level.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "project rules"));
}

test "instructions: an ancestor AGENTS.md is inherited, not ignored" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try a.dupe(u8, buf[0..try tmp.dir.realPath(std.testing.io, &buf)]);
    const text = (try loadAll(a, std.testing.io, null, root, root)).?;
    // The temp root is under the repo, whose AGENTS.md must reach the prompt.
    try std.testing.expect(std.mem.indexOf(u8, text, "zode") != null);
}

/// Reads and expands every collected file into one block. Each file gets a
/// heading so the model can tell which rule came from where.
pub fn loadAll(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: ?*const std.process.Environ.Map,
    start_dir: []const u8,
    project_root: ?[]const u8,
) !?[]u8 {
    const paths = try collect(gpa, io, env, start_dir, project_root);
    defer {
        for (paths) |p| gpa.free(p);
        gpa.free(paths);
    }
    if (paths.len == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (paths) |path| {
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(agentsdoc.max_file_bytes)) catch continue;
        defer gpa.free(text);
        if (out.items.len > 0) try out.appendSlice(gpa, "\n\n");
        try out.appendSlice(gpa, "## Instructions from ");
        try out.appendSlice(gpa, path);
        try out.appendSlice(gpa, "\n");
        try out.appendSlice(gpa, text);
    }
    if (out.items.len == 0) {
        out.deinit(gpa);
        return null;
    }
    return try out.toOwnedSlice(gpa);
}
