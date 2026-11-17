/// Discovery of skills, output styles, and agent definitions.
///
/// Caches with mtime/stamp validation to avoid rescanning on every request.
/// Runtime context (io, allocators, project paths) is passed by `agent.zig`.
const std = @import("std");
const agentdefs = @import("../lib/agentdefs.zig");
const skills = @import("../lib/skills.zig");
const skillstore = @import("../lib/skillstore.zig");
const outputstyles = @import("../lib/outputstyles.zig");
const outputstyle_store = @import("../lib/outputstyle_store.zig");

var agent_defs_cache: ?[]agentdefs.Entry = null;

pub fn resetAgentDefs() void {
    agent_defs_cache = null;
}

pub fn ensureAgentDefs(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: ?*const std.process.Environ.Map,
    project_cwd: []const u8,
) []const agentdefs.Entry {
    if (agent_defs_cache) |defs| return defs;

    var roots: std.ArrayList([]u8) = .empty;
    defer roots.deinit(gpa);
    var proj_buf: [std.fs.max_path_bytes]u8 = undefined;
    const proj_path = std.fmt.bufPrint(&proj_buf, "{s}/{s}", .{ project_cwd, agentdefs.project_dir }) catch "";
    if (proj_path.len > 0) {
        if (gpa.dupe(u8, proj_path)) |pc| roots.append(gpa, pc) catch gpa.free(pc) else |_| {}
    }
    if (env) |e| {
        if (e.get("HOME")) |home| {
            if (home.len > 0) {
                var user_buf: [std.fs.max_path_bytes]u8 = undefined;
                const user_path = std.fmt.bufPrint(&user_buf, "{s}/{s}/{s}", .{ home, ".config", agentdefs.user_subdir }) catch "";
                if (user_path.len > 0) {
                    if (gpa.dupe(u8, user_path)) |uc| roots.append(gpa, uc) catch gpa.free(uc) else |_| {}
                }
            }
        }
    }

    var entries: std.ArrayList(agentdefs.Entry) = .empty;
    defer entries.deinit(gpa);
    // `seen` is keyed by NAME. Project roots are first, so a project definition
    // shadows a user one with the same name; within one root a directory shadows
    // a flat file only if it comes first in the iteration (it does — dirs are
    // visited before flat files in `scanRoot`).
    var seen: std.ArrayList([]u8) = .empty;
    defer seen.deinit(gpa);

    for (roots.items) |root| scanRoot(gpa, io, root, project_cwd, &entries, &seen);

    agent_defs_cache = entries.toOwnedSlice(gpa) catch null;
    return agent_defs_cache.?;
}

/// Scans one root for both layouts. The directory layout is visited first so
/// `<name>/AGENT.md` wins over a flat `<name>.md` in the same root.
fn scanRoot(
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    project_cwd: []const u8,
    entries: *std.ArrayList(agentdefs.Entry),
    seen: *std.ArrayList([]u8),
) void {
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);

    // Pass 1: directories containing AGENT.md.
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        addDefinition(gpa, io, root, project_cwd, entry.name, true, entries, seen);
    }
    // Pass 2: flat `<name>.md` files.
    var it2 = dir.iterate();
    while (it2.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const stem = agentdefs.flatStem(entry.name) orelse continue;
        addDefinition(gpa, io, root, project_cwd, stem, false, entries, seen);
    }
}

/// Adds one definition if its name has not been claimed yet. Owns every string
/// it puts into `entries`; frees everything on any refusal.
fn addDefinition(
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    project_cwd: []const u8,
    name: []const u8,
    is_dir: bool,
    entries: *std.ArrayList(agentdefs.Entry),
    seen: *std.ArrayList([]u8),
) void {
    if (!agentdefs.validName(name)) return;
    for (seen.items) |s| {
        if (std.mem.eql(u8, s, name)) return;
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file_path = if (is_dir)
        std.fmt.bufPrint(&path_buf, "{s}/{s}/AGENT.md", .{ root, name }) catch return
    else
        std.fmt.bufPrint(&path_buf, "{s}/{s}.md", .{ root, name }) catch return;
    const text = std.Io.Dir.cwd().readFileAlloc(io, file_path, gpa, .limited(64 * 1024)) catch return;
    defer gpa.free(text);

    const fm = agentdefs.splitFrontmatter(text) orelse return;
    // The frontmatter `name`, when present, is authoritative for routing; the
    // directory/file stem is the fallback. A mismatch is tolerated (the body
    // still loads) but the frontmatter name wins.
    const def_name = if (agentdefs.validName(fm.meta.name)) fm.meta.name else name;
    for (seen.items) |s| {
        if (std.mem.eql(u8, s, def_name)) return;
    }

    var tools: [][]const u8 = &[_][]const u8{};
    if (fm.meta.tools.len > 0) {
        tools = agentdefs.parseTools(fm.meta.tools, gpa) catch return;
    }
    if (!agentdefs.toolsAreReadOnly(tools)) {
        gpa.free(tools);
        return;
    }

    const name_copy = gpa.dupe(u8, def_name) catch return;
    errdefer gpa.free(name_copy);
    const path_copy = gpa.dupe(u8, file_path) catch return;
    errdefer gpa.free(path_copy);
    const desc = gpa.dupe(u8, fm.meta.description) catch return;
    errdefer gpa.free(desc);
    const model = if (fm.meta.model.len > 0) gpa.dupe(u8, fm.meta.model) catch "" else "";
    const effort = if (fm.meta.effort.len > 0) gpa.dupe(u8, fm.meta.effort) catch "" else "";

    seen.append(gpa, name_copy) catch return;
    entries.append(gpa, .{
        .name = name_copy,
        .description = desc,
        .tools = tools,
        .model = model,
        .effort = effort,
        .path = path_copy,
        .source = if (project_cwd.len > 0 and std.mem.startsWith(u8, root, project_cwd)) "project" else "user",
    }) catch {
        _ = seen.pop();
        gpa.free(name_copy);
        gpa.free(path_copy);
        gpa.free(desc);
        if (model.len > 0) gpa.free(model);
        if (effort.len > 0) gpa.free(effort);
        gpa.free(tools);
    };
}

// ── skills ────────────────────────────────────────────────────────────────
pub var skills_cache: ?[]skills.Entry = null;
var skills_cache_gpa: std.mem.Allocator = std.heap.page_allocator;
var skills_stamps: [skills_stamp_max]skillstore.Stamp = undefined;
pub var skills_stamp_len: usize = 0;
const skills_stamp_max = 64 + skillstore.max_roots;
const skills_rescan_max: usize = 4;
var skills_lock: std.atomic.Mutex = .unlocked;
pub var skills_rescans: usize = 0;

pub fn discoverSkills(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: ?*const std.process.Environ.Map,
    cache_gpa: std.mem.Allocator,
    project_cwd: []const u8,
    project_root: ?[]const u8,
) []const skills.Entry {
    while (skills_lock.tryLock()) {}
    defer skills_lock.unlock();

    if (skills_cache != null and skillsFresh(io, env, project_cwd, project_root)) return skills_cache.?;
    if (skills_rescans >= skills_rescan_max) return skills_cache orelse &.{};
    skills_rescans += 1;

    const fresh = loadSkillsNow(std.heap.page_allocator, io, env, project_cwd, project_root);
    if (gpa.vtable == cache_gpa.vtable and gpa.ptr == cache_gpa.ptr) {
        freeSkillsCacheLocked();
        skills_cache = fresh;
        skills_cache_gpa = std.heap.page_allocator;
    }
    stampSkills(io, env, project_cwd, project_root);
    return fresh;
}

fn loadSkillsNow(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: ?*const std.process.Environ.Map,
    project_cwd: []const u8,
    project_root: ?[]const u8,
) []skills.Entry {
    var loader = skillsLoader(gpa, io, env, project_cwd, project_root);
    var buf: [64]skills.Entry = undefined;
    const found = loader.scan(&buf, buf.len);
    const copy = gpa.dupe(skills.Entry, found) catch {
        for (found) |e| {
            gpa.free(e.name);
            gpa.free(e.description);
            gpa.free(e.path);
        }
        return &.{};
    };
    return copy;
}

/// Scratch buffers for the Loaders built by `skillsLoader`/`stylesLoader`.
///
/// These MUST NOT be stack locals: a Loader returned by value holds slices into
/// them, and a stack slot is dead (and reused by the caller's next `bufPrint`)
/// the moment the function returns — the exact overlap that produced
/// `@memcpy arguments alias`. Static buffers outlive the Loader; both callers
/// hold their module lock (`skills_lock` / `styles_lock`) while using them.
var loader_path_bufs: [4][std.fs.max_path_bytes]u8 = undefined;

fn skillsLoader(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: ?*const std.process.Environ.Map,
    project_cwd: []const u8,
    project_root: ?[]const u8,
) skillstore.Loader {
    var loader = skillstore.Loader.init(gpa, io, env);
    if (project_cwd.len == 0) return loader;
    loader.project_dir = std.fmt.bufPrint(&loader_path_bufs[0], "{s}/{s}", .{ project_cwd, skills.project_dir }) catch loader.project_dir;
    loader.agents_dir = std.fmt.bufPrint(&loader_path_bufs[1], "{s}/{s}", .{ project_cwd, skills.agents_dir }) catch loader.agents_dir;
    if (project_root) |root| {
        if (!std.mem.eql(u8, root, project_cwd)) loader.repo_root = root;
    }
    return loader;
}

fn stampSkills(io: std.Io, env: ?*const std.process.Environ.Map, project_cwd: []const u8, project_root: ?[]const u8) void {
    skills_stamp_len = 0;
    var loader = skillsLoader(std.heap.page_allocator, io, env, project_cwd, project_root);
    var bufs: [skillstore.max_roots][std.fs.max_path_bytes]u8 = undefined;
    var paths: [skillstore.max_roots][]const u8 = undefined;
    const root_count = loader.roots(&bufs, &paths);
    for (paths[0..root_count]) |p| addStamp(io, p);
    if (skills_cache) |list| {
        for (list) |e| addStamp(io, e.path);
    }
}

fn addStamp(io: std.Io, path: []const u8) void {
    if (skills_stamp_len >= skills_stamps.len) return;
    if (!skillstore.stampPath(io, path, &skills_stamps[skills_stamp_len])) return;
    skills_stamp_len += 1;
}

fn skillsFresh(io: std.Io, env: ?*const std.process.Environ.Map, project_cwd: []const u8, project_root: ?[]const u8) bool {
    var loader = skillsLoader(std.heap.page_allocator, io, env, project_cwd, project_root);
    var bufs: [skillstore.max_roots][std.fs.max_path_bytes]u8 = undefined;
    var paths: [skillstore.max_roots][]const u8 = undefined;
    const root_count = loader.roots(&bufs, &paths);
    for (paths[0..root_count]) |p| if (!stampUnchanged(io, p)) return false;
    if (skills_cache) |list| {
        for (list) |e| if (!stampUnchanged(io, e.path)) return false;
    }
    return true;
}

fn stampUnchanged(io: std.Io, path: []const u8) bool {
    for (skills_stamps[0..skills_stamp_len]) |*st| {
        if (!std.mem.eql(u8, st.pathOf(), path)) continue;
        var now: skillstore.Stamp = .{};
        if (!skillstore.stampPath(io, path, &now)) return false;
        return st.sameAs(&now);
    }
    return false;
}

pub fn freeSkillsCache() void {
    while (skills_lock.tryLock()) {}
    defer skills_lock.unlock();
    freeSkillsCacheLocked();
}

pub fn freeSkillsCacheLocked() void {
    const gpa = skills_cache_gpa;
    if (skills_cache) |list| {
        for (list) |e| {
            gpa.free(e.name);
            gpa.free(e.description);
            gpa.free(e.path);
            if (e.when_to_use.len > 0) gpa.free(e.when_to_use);
            if (e.allowed_tools.len > 0) gpa.free(e.allowed_tools);
            if (e.model.len > 0) gpa.free(e.model);
            if (e.effort.len > 0) gpa.free(e.effort);
        }
        if (list.len > 0) gpa.free(list);
        skills_cache = null;
    }
    skills_stamp_len = 0;
}

pub fn resetSkillsCacheForTest() void {
    while (skills_lock.tryLock()) {}
    defer skills_lock.unlock();
    skills_cache = null;
    skills_cache_gpa = std.heap.page_allocator;
    skills_stamp_len = 0;
    skills_rescans = 0;
}

// ── output styles ─────────────────────────────────────────────────────────
pub var styles_cache: ?[]outputstyles.Entry = null;
var styles_cache_gpa: std.mem.Allocator = std.heap.page_allocator;
var styles_stamps: [outputstyle_store.max_roots]outputstyle_store.Stamp = undefined;
pub var styles_stamp_len: usize = 0;
const styles_rescan_max: usize = 4;
pub var styles_rescans: usize = 0;
var styles_lock: std.atomic.Mutex = .unlocked;

pub fn discoverStyles(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: ?*const std.process.Environ.Map,
    cache_gpa: std.mem.Allocator,
    project_cwd: []const u8,
    project_root: ?[]const u8,
) []const outputstyles.Entry {
    while (styles_lock.tryLock()) {}
    defer styles_lock.unlock();

    if (styles_cache != null and stylesFresh(io, env, project_cwd, project_root)) return styles_cache.?;
    if (styles_rescans >= styles_rescan_max) return styles_cache orelse &.{};
    styles_rescans += 1;

    const fresh = loadStylesNow(std.heap.page_allocator, io, env, project_cwd, project_root);
    if (gpa.vtable == cache_gpa.vtable and gpa.ptr == cache_gpa.ptr) {
        freeStylesCacheLocked();
        styles_cache = fresh;
        styles_cache_gpa = std.heap.page_allocator;
    }
    stampStyles(io, env, project_cwd, project_root);
    return fresh;
}

fn loadStylesNow(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: ?*const std.process.Environ.Map,
    project_cwd: []const u8,
    project_root: ?[]const u8,
) []outputstyles.Entry {
    var loader = stylesLoader(gpa, io, env, project_cwd, project_root);
    var buf: [64]outputstyles.Entry = undefined;
    const found = loader.scan(&buf, buf.len);
    const copy = gpa.dupe(outputstyles.Entry, found) catch {
        for (found) |e| {
            gpa.free(e.name);
            gpa.free(e.description);
            gpa.free(e.path);
        }
        return &.{};
    };
    return copy;
}

fn stylesLoader(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: ?*const std.process.Environ.Map,
    project_cwd: []const u8,
    project_root: ?[]const u8,
) outputstyle_store.Loader {
    var loader = outputstyle_store.Loader.init(gpa, io, env);
    if (project_cwd.len == 0) return loader;
    loader.project_dir = std.fmt.bufPrint(&loader_path_bufs[2], "{s}/{s}", .{ project_cwd, outputstyles.project_dir }) catch loader.project_dir;
    if (project_root) |root| {
        if (!std.mem.eql(u8, root, project_cwd)) loader.repo_root = root;
    }
    return loader;
}

fn stampStyles(io: std.Io, env: ?*const std.process.Environ.Map, project_cwd: []const u8, project_root: ?[]const u8) void {
    styles_stamp_len = 0;
    var loader = stylesLoader(std.heap.page_allocator, io, env, project_cwd, project_root);
    var bufs: [outputstyle_store.max_roots][std.fs.max_path_bytes]u8 = undefined;
    var paths: [outputstyle_store.max_roots][]const u8 = undefined;
    const root_count = loader.roots(&bufs, &paths);
    for (paths[0..root_count]) |p| addStyleStamp(io, p);
    if (styles_cache) |list| {
        for (list) |e| addStyleStamp(io, e.path);
    }
}

fn addStyleStamp(io: std.Io, path: []const u8) void {
    if (styles_stamp_len >= styles_stamps.len) return;
    if (!outputstyle_store.stampPath(io, path, &styles_stamps[styles_stamp_len])) return;
    styles_stamp_len += 1;
}

fn stylesFresh(io: std.Io, env: ?*const std.process.Environ.Map, project_cwd: []const u8, project_root: ?[]const u8) bool {
    var loader = stylesLoader(std.heap.page_allocator, io, env, project_cwd, project_root);
    var bufs: [outputstyle_store.max_roots][std.fs.max_path_bytes]u8 = undefined;
    var paths: [outputstyle_store.max_roots][]const u8 = undefined;
    const root_count = loader.roots(&bufs, &paths);
    for (paths[0..root_count]) |p| if (!styleStampUnchanged(io, p)) return false;
    if (styles_cache) |list| {
        for (list) |e| if (!styleStampUnchanged(io, e.path)) return false;
    }
    return true;
}

fn styleStampUnchanged(io: std.Io, path: []const u8) bool {
    for (styles_stamps[0..styles_stamp_len]) |*st| {
        if (!std.mem.eql(u8, st.pathOf(), path)) continue;
        var now: outputstyle_store.Stamp = .{};
        if (!outputstyle_store.stampPath(io, path, &now)) return false;
        return st.sameAs(&now);
    }
    return false;
}

fn freeStylesCacheLocked() void {
    const gpa = styles_cache_gpa;
    if (styles_cache) |list| {
        for (list) |e| {
            gpa.free(e.name);
            gpa.free(e.description);
            gpa.free(e.path);
        }
        if (list.len > 0) gpa.free(list);
    }
    styles_cache = null;
}

pub fn resetStylesCacheForTest() void {
    while (styles_lock.tryLock()) {}
    defer styles_lock.unlock();
    styles_cache = null;
    styles_cache_gpa = std.heap.page_allocator;
    styles_stamp_len = 0;
    styles_rescans = 0;
}

// ── Phase 36 / crash fix: Loader paths must outlive the returning frame ────

test "discovery: loader paths survive the function that built them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = "/tmp/zode-loader-path-test";
    const root: ?[]const u8 = null;

    // Build a skills loader and a styles loader, then FORCE the old stack
    // region to be overwritten by other bufPrint calls. If the paths were
    // stack locals (the bug: `@memcpy arguments alias`), they now read as
    // garbage; with static scratch buffers they stay intact.
    const sk = skillsLoader(a, std.testing.io, null, cwd, root);
    const st = stylesLoader(a, std.testing.io, null, cwd, root);
    try std.testing.expect(std.mem.startsWith(u8, sk.project_dir, cwd));
    try std.testing.expect(std.mem.startsWith(u8, st.project_dir, cwd));

    var churn: [4][std.fs.max_path_bytes]u8 = undefined;
    for (0..64) |i| {
        _ = std.fmt.bufPrint(&churn[i % 4], "churn-{d}-{s}", .{ i, cwd }) catch {};
    }
    try std.testing.expect(std.mem.startsWith(u8, sk.project_dir, cwd));
    try std.testing.expect(std.mem.startsWith(u8, st.project_dir, cwd));
    try std.testing.expect(std.mem.indexOf(u8, sk.project_dir, ".zode/skills") != null);
    try std.testing.expect(std.mem.indexOf(u8, st.project_dir, ".zode/output-styles") != null);
}
