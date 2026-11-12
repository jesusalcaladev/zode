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
        if (gpa.dupe(u8, proj_path)) |pc| {
            roots.append(gpa, pc) catch gpa.free(pc);
        } else |_| {}
    }
    if (env) |e| {
        if (e.get("HOME")) |home| {
            if (home.len > 0) {
                var user_buf: [std.fs.max_path_bytes]u8 = undefined;
                const user_path = std.fmt.bufPrint(&user_buf, "{s}/{s}/{s}", .{ home, ".config", agentdefs.user_subdir }) catch "";
                if (user_path.len > 0) {
                    if (gpa.dupe(u8, user_path)) |uc| {
                        roots.append(gpa, uc) catch gpa.free(uc);
                    } else |_| {}
                }
            }
        }
    }
    var entries: std.ArrayList(agentdefs.Entry) = .empty;
    defer entries.deinit(gpa);
    var seen: std.ArrayList([]u8) = .empty;
    defer seen.deinit(gpa);
    for (roots.items) |root| {
        var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            var already = false;
            for (seen.items) |s| {
                if (std.mem.eql(u8, s, entry.name)) {
                    already = true;
                    break;
                }
            }
            if (already) continue;
            const name_copy = gpa.dupe(u8, entry.name) catch continue;
            seen.append(gpa, name_copy) catch {
                gpa.free(name_copy);
                continue;
            };
            var file_buf: [std.fs.max_path_bytes]u8 = undefined;
            const file_path = std.fmt.bufPrint(&file_buf, "{s}/{s}/AGENT.md", .{ root, entry.name }) catch {
                gpa.free(name_copy);
                continue;
            };
            const text = std.Io.Dir.cwd().readFileAlloc(io, file_path, gpa, .limited(64 * 1024)) catch {
                gpa.free(name_copy);
                continue;
            };
            const fm = agentdefs.splitFrontmatter(text) orelse {
                gpa.free(text);
                gpa.free(name_copy);
                continue;
            };
            var tools: [][]const u8 = &[_][]const u8{};
            if (fm.meta.tools.len > 0) {
                tools = agentdefs.parseTools(fm.meta.tools, gpa) catch {
                    gpa.free(text);
                    gpa.free(name_copy);
                    continue;
                };
            }
            if (!agentdefs.toolsAreReadOnly(tools)) {
                gpa.free(text);
                gpa.free(name_copy);
                continue;
            }
            const desc_dup = gpa.dupe(u8, fm.meta.description) catch {
                gpa.free(text);
                gpa.free(name_copy);
                continue;
            };
            const model_dup = if (fm.meta.model.len > 0) gpa.dupe(u8, fm.meta.model) catch {
                gpa.free(text);
                gpa.free(name_copy);
                gpa.free(desc_dup);
                continue;
            } else "";
            const effort_dup = if (fm.meta.effort.len > 0) gpa.dupe(u8, fm.meta.effort) catch {
                gpa.free(text);
                gpa.free(name_copy);
                gpa.free(desc_dup);
                gpa.free(model_dup);
                continue;
            } else "";
            entries.append(gpa, agentdefs.Entry{
                .name = name_copy,
                .description = desc_dup,
                .tools = tools,
                .model = model_dup,
                .effort = effort_dup,
                .path = file_path,
                .source = if (std.mem.startsWith(u8, root, project_cwd) and project_cwd.len > 0) "project" else "user",
            }) catch {
                gpa.free(text);
                gpa.free(name_copy);
                gpa.free(desc_dup);
                if (model_dup.len > 0) gpa.free(model_dup);
                if (effort_dup.len > 0) gpa.free(effort_dup);
                continue;
            };
            gpa.free(text);
        }
    }
    agent_defs_cache = entries.toOwnedSlice(gpa) catch null;
    return agent_defs_cache.?;
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

fn skillsLoader(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: ?*const std.process.Environ.Map,
    project_cwd: []const u8,
    project_root: ?[]const u8,
) skillstore.Loader {
    var loader = skillstore.Loader.init(gpa, io, env);
    if (project_cwd.len == 0) return loader;
    var bufs: [2][std.fs.max_path_bytes]u8 = undefined;
    loader.project_dir = std.fmt.bufPrint(&bufs[0], "{s}/{s}", .{ project_cwd, skills.project_dir }) catch loader.project_dir;
    loader.agents_dir = std.fmt.bufPrint(&bufs[1], "{s}/{s}", .{ project_cwd, skills.agents_dir }) catch loader.agents_dir;
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
    var bufs: [2][std.fs.max_path_bytes]u8 = undefined;
    loader.project_dir = std.fmt.bufPrint(&bufs[0], "{s}/{s}", .{ project_cwd, outputstyles.project_dir }) catch loader.project_dir;
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
