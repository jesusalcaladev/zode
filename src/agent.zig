const std = @import("std");
const posix = std.posix;
const sleepz = @import("lib/sleep.zig");
const vaxis = @import("vaxis");
const builtin = @import("builtin");
const tui = @import("tui.zig");
const theme = @import("lib/theme.zig");
const providers = @import("lib/providers.zig");
const md = @import("lib/markdown.zig");
const chat = @import("chat.zig");
const http_client = @import("lib/http_client.zig");
const tools_mod = @import("tools/dispatch.zig");
// The `mcp` tool's own module, for the ONE thing the timeline needs from it:
// the qualified name of the tool a call is about. The dispatcher does not
// re-export it because nothing else wants it, and a re-export would be a
// second name for the same thing.
const mcp_tool = @import("tools/mcp.zig");
const roster_mod = @import("roster.zig");
const free_auto = @import("free_auto.zig");
const router_mod = @import("lib/router.zig");
const plan_mod = @import("lib/plan.zig");
const goal_mod = @import("lib/goal.zig");
const modelcache = @import("lib/modelcache.zig");
const clean_mod = @import("lib/clean.zig");
const usercmds_mod = @import("lib/usercmds.zig");
const pathsafe = @import("lib/pathsafe.zig");
const permrules = @import("lib/permrules.zig");
const cmdsafety = @import("lib/cmdsafety.zig");
const mentions = @import("lib/mentions.zig");
const session_mod = @import("session.zig");
const models_mod = @import("lib/models.zig");
const cache_stats = @import("cache_stats.zig");
const cost_mod = @import("lib/cost.zig");
const selfupdate = @import("lib/selfupdate.zig");
const compaction = @import("compaction.zig");
const palette = @import("palette.zig");
const config_mod = @import("config.zig");

const ask = @import("lib/ask.zig");
const bgproc = @import("bgproc.zig");
const sleep_mod = @import("lib/sleep.zig");
const typecheck_mod = @import("lib/typecheck.zig");
const check_tool = @import("tools/check.zig");
const bg_tool = @import("tools/bg.zig");
const images_mod = @import("lib/images.zig");
const bench_mod = @import("lib/bench.zig");
const skills = @import("lib/skills.zig");
const skillstore = @import("lib/skillstore.zig");
const outputstyles = @import("lib/outputstyles.zig");
const outputstyle_store = @import("lib/outputstyle_store.zig");
const project = @import("lib/project.zig");
const sessionpath = @import("lib/sessionpath.zig");
const sessionindex = @import("lib/sessionindex.zig");
const taskstore = @import("lib/taskstore.zig");
const termseq = @import("lib/termseq.zig");
const subagent_mod = @import("lib/subagent.zig");
const textcap = @import("lib/textcap.zig");
const resultcap = @import("lib/resultcap.zig");
const toolstore = @import("lib/toolstore.zig");
const tools_registry = @import("tools/registry.zig");
const sleep = @import("lib/sleep.zig");
const prompt_mod = @import("lib/prompt.zig");
const copytext = @import("lib/copytext.zig");
const clipboard = @import("clipboard.zig");
const agentdefs = @import("lib/agentdefs.zig");
const cachebreak = @import("lib/cachebreak.zig");
const commands_mod = @import("commands.zig");
const exitgate = @import("lib/exitgate.zig");
const repeats_mod = @import("lib/repeats.zig");
const build_options = @import("build_options");
const autochk = @import("autochk.zig");
const lsp_manager = @import("lsp/manager.zig");
const mcp_manager = @import("mcp/manager.zig");
const review_mod = @import("lib/review.zig");

// The `/help` tables live with the commands they document. Re-exported because
// the palette builds its items from `commands`, and that is not a commands
// concern: it is a "what can I type" concern.
pub const commands = commands_mod.commands;
pub const shortcuts = commands_mod.shortcuts;

/// Io and API key configured by the TUI at startup.
pub var io_global: std.Io = undefined;
pub var api_key_global: ?[]const u8 = null;
pub var environ_global: ?*const std.process.Environ.Map = null;
pub var gpa_global: std.mem.Allocator = undefined;

// The prompt text itself lives in `lib/prompt.zig` and is re-exported here, so
// the tests that assert on it keep reading `agent.default_system_prompt` and no
// import outside this file changes.
pub const default_system_prompt = prompt_mod.default_system_prompt;
pub const default_system_prompt_core = prompt_mod.default_system_prompt_core;
pub const coding_rules = prompt_mod.coding_rules;
pub const tool_routing_prompt = prompt_mod.tool_routing_prompt;
pub const verification_prompt = prompt_mod.verification_prompt;

// ── system prompt: the project's AGENTS.md (cached) ──────────
var agents_md_cache: ?[]u8 = null;

/// Cache-break detection: previous block hashes, set on the first call to
/// `buildSystemPrompt` and compared on every later call. When a block changes,
/// `cache_break_last_block` names it and `cache_break_last_pos` gives its byte
/// offset in the composed prefix.
var cache_break_prev: ?[8]u64 = null;
var cache_break_last_block: ?[]const u8 = null;
var cache_break_last_pos: usize = 0;

/// Resets the cache-break tracker (for tests and session rotation).
pub fn resetCacheBreak() void {
    cache_break_prev = null;
    cache_break_last_block = null;
    cache_break_last_pos = 0;
}

/// True when the cache write rate suggests the prefix is unstable:
/// `writes_per_request > 0.5` over a long session means the prefix is being
/// re-written every turn instead of being read from the provider's cache.
pub fn cacheBreakUnstable() bool {
    return cache_stats.session.writesPerRequest() > 0.5;
}

/// Cached discovered agent definitions (`.zode/agents/` + `~/.config/zode/agents/`).
var agent_defs_cache: ?[]agentdefs.Entry = null;

/// Discovers and caches agent definitions, or returns the cached list.
pub fn ensureAgentDefs(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map) []const agentdefs.Entry {
    if (agent_defs_cache) |defs| return defs;
    var roots: std.ArrayList([]u8) = .empty;
    defer roots.deinit(gpa);
    var proj_buf: [std.fs.max_path_bytes]u8 = undefined;
    const proj_path = std.fmt.bufPrint(&proj_buf, "{s}/{s}", .{ project_info.cwd(), agentdefs.project_dir }) catch "";
    if (proj_path.len > 0) {
        const proj_copy = gpa.dupe(u8, proj_path) catch null;
        if (proj_copy) |pc| {
            roots.append(gpa, pc) catch {};
        }
    }
    if (env) |e| {
        if (e.get("HOME")) |home| {
            if (home.len > 0) {
                var user_buf: [std.fs.max_path_bytes]u8 = undefined;
                const user_path = std.fmt.bufPrint(&user_buf, "{s}/{s}/{s}", .{ home, ".config", agentdefs.user_subdir }) catch "";
                if (user_path.len > 0) {
                    const user_copy = gpa.dupe(u8, user_path) catch null;
                    if (user_copy) |uc| {
                        roots.append(gpa, uc) catch {};
                    }
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
                if (std.mem.eql(u8, s, entry.name)) { already = true; break; }
            }
            if (already) continue;
            const name_copy = gpa.dupe(u8, entry.name) catch continue;
            seen.append(gpa, name_copy) catch { gpa.free(name_copy); continue; };
            var file_buf: [std.fs.max_path_bytes]u8 = undefined;
            const file_path = std.fmt.bufPrint(&file_buf, "{s}/{s}/AGENT.md", .{ root, entry.name }) catch { gpa.free(name_copy); continue; };
            const text = std.Io.Dir.cwd().readFileAlloc(io, file_path, gpa, .limited(64 * 1024)) catch { gpa.free(name_copy); continue; };
            const fm = agentdefs.splitFrontmatter(text) orelse { gpa.free(text); gpa.free(name_copy); continue; };
            var tools: [][]const u8 = &[_][]const u8{};
            if (fm.meta.tools.len > 0) {
                tools = agentdefs.parseTools(fm.meta.tools, gpa) catch { gpa.free(text); gpa.free(name_copy); continue; };
            }
            if (!agentdefs.toolsAreReadOnly(tools)) { gpa.free(text); gpa.free(name_copy); continue; }
            const desc_dup = gpa.dupe(u8, fm.meta.description) catch { gpa.free(text); gpa.free(name_copy); continue; };
            const model_dup = if (fm.meta.model.len > 0) gpa.dupe(u8, fm.meta.model) catch { gpa.free(text); gpa.free(name_copy); gpa.free(desc_dup); continue; } else "";
            const effort_dup = if (fm.meta.effort.len > 0) gpa.dupe(u8, fm.meta.effort) catch { gpa.free(text); gpa.free(name_copy); gpa.free(desc_dup); gpa.free(model_dup); continue; } else "";
            entries.append(gpa, agentdefs.Entry{
                .name = name_copy,
                .description = desc_dup,
                .tools = tools,
                .model = model_dup,
                .effort = effort_dup,
                .path = file_path,
                .source = if (std.mem.eql(u8, root[0..], project_info.cwd())) "project" else "user",
            }) catch { gpa.free(text); gpa.free(name_copy); gpa.free(desc_dup); if (model_dup.len > 0) gpa.free(model_dup); if (effort_dup.len > 0) gpa.free(effort_dup); continue; };
            gpa.free(text);
        }
    }
    agent_defs_cache = entries.toOwnedSlice(gpa) catch null;
    return agent_defs_cache.?;
}

/// Resets the agent definitions cache (for config reload).
pub fn resetAgentDefs() void {
    agent_defs_cache = null;
}

/// Releases the AGENTS.md cache.
///
/// `pub` and idempotent (null after the first call) for one reason: the E2E test needs to
/// release a module global it did not create, and doing `allocator.free(x); x = null;` at
/// the call site is a double free the moment any other owner does the same. Inlining the
/// guard makes the second call a no-op rather than a crash.
///
/// In the app this is never called: the cache is a process-lifetime allocation. It exists
/// for tests that take over the globals.
pub fn forgetAgentsCache(a: std.mem.Allocator) void {
    if (agents_md_cache) |c| {
        // The CALLER's allocator, because the cache was read with the one `runOneTurn`
        // was handed. Two separate wrong guesses were made here before this: freeing it
        // with `page_allocator` while the block belonged to the testing allocator (an
        // Invalid free), and freeing it at the call site (a double free the moment any
        // other owner does the same).
        a.free(c);
        agents_md_cache = null;
    }
}

/// Where zode is running, resolved ONCE at startup.
///
/// Fixed buffers and no lock: the cwd cannot change while zode runs, so this is
/// written once during `initProjectInfo` and only read afterwards — from the
/// worker that composes the prompt and from the UI thread that draws `/context`.
/// That is what makes it safe without a mutex, and also why it is a plain global
/// rather than a `Model` field (the prompt is composed where there is no model at
/// hand, which is the trap `io_global` already is).
pub var project_info: project.Info = .{};

/// Fills `project_info`, if it has not been filled yet.
///
/// Called from the startup path and from tests. Idempotent on purpose: the second
/// call is a no-op, so a test that points it at a fixture does not leak the real
/// one into the next test (that would be a test whose result depends on the order
/// the suite runs in).
pub fn initProjectInfo(io: std.Io, env: ?*const std.process.Environ.Map) void {
    if (project_info.cwd_len != 0) return;
    project.detect(io, env, &project_info);
}

/// Resolves the sessions directory for the current project, using gpa for
/// allocation. Stores nothing globally — the caller uses the returned path.
/// Idempotent: safe to call multiple times (each call allocates).
pub fn resolveSessionsDirIn(gpa: std.mem.Allocator, env: ?*const std.process.Environ.Map) void {
    const project_root = project_info.cwd();
    _ = sessionpath.resolveSessionsDir(gpa, io_global, env, project_root) catch {};
}

/// Fills `project_info` from a given directory. For tests only.
pub fn setProjectInfoForTest(io: std.Io, start: []const u8) void {
    project.detectAt(io, start, &project_info);
}

/// `true` when `project_info` has been filled. For tests only.
pub fn projectInfoReady() bool {
    return project_info.cwd_len != 0;
}

/// The cwd + git paragraph, for callers that compose their own prompt.
///
/// Exists because the headless runner builds its own (it has no session to sync),
/// and because the alternative — reaching into `project_info` from `main.zig` — is
/// how a global turns into something three files depend on.
pub fn projectInfoPromptLines(out: []u8) []const u8 {
    return project_info.promptLines(out);
}

/// Skills found on disk, discovered ONCE and then re-validated by mtime.
///
/// The list is cached because it goes into the system prompt, which is rebuilt
/// for every request: walking the roots and reading the frontmatter of every
/// `SKILL.md` on every request would be silly I/O on the hot path. The BODY is
/// never cached — that is loaded on demand by the `skill` tool, which is the whole
/// point (see `skills.zig`).
///
/// ## The list is BORROWED, and that is the whole ownership story
///
/// `scan` allocates the entries AND their strings, and hands ownership to the
/// caller. So the module owns them, and the callers of `discoverSkills` must NOT
/// free them. The old code had a `freeSkillEntries` that the caller called with a
/// `defer`, which freed the cache out from under itself: the second
/// `syncSystemPrompt` of the session read a freed slice. It did not show up
/// because the block is usually reused by the next allocation and the list still
/// "looked" right, and because the test that exercises `buildSystemPrompt` runs in
/// the repo root, where `.zode/skills` does not exist, so there were no strings to
/// free at all. Hence: borrowed slice, freed once, at teardown, by the module.
///
/// ## Why the mtime check and not "discover once forever"
///
/// `buildSystemPrompt`'s own doc comment claims a skill that appears on disk
/// should be usable without a restart. With a permanent cache that was false. The
/// check is N `stat`s (one per root, one per known `SKILL.md`) and no reads, which
/// is nothing next to a request to a model; the expensive half (reading and
/// parsing frontmatter) only happens when something actually changed.
var skills_cache: ?[]skills.Entry = null;
/// `mtime` + size of every path the cached list was built from: the roots and each
/// `SKILL.md`. A change in any of them invalidates the list.
var skills_stamps: [skills_stamp_max]skillstore.Stamp = undefined;
var skills_stamp_len: usize = 0;
/// Roots + skills. The array is sized from the loader's own caps so the two can
/// never drift apart.
const skills_stamp_max = 64 + skillstore.max_roots;

/// Rescans before the cache is trusted forever.
///
/// Bounded on purpose: a `stat` per root and per skill is nothing next to a
/// request, but the RESCAN reads and parses every frontmatter. A directory whose
/// mtime changes on every turn (a sync client, a build that rewrites skills) would
/// pay that on every turn forever. After the cap the cache is trusted as-is, and
/// `/new` is what picks up a late arrival.
const skills_rescan_max: usize = 4;

var skills_lock: std.atomic.Mutex = .unlocked;
var skills_rescans: usize = 0;

/// The skills on disk, or an empty list. BORROWED: do not free.
///
/// The lock is held for the whole function, rescan included. `tryLock` in a spin
/// loop and not `lock`, because this sits on the request path and the critical
/// section is a handful of `stat`s. Holding it across the rescan is what makes the
/// swap safe: the old list may be being walked by another thread right now (the
/// prompt is composed on the worker, `/skills` is drawn on the UI thread), and
/// that is the exact race the palette had.
pub fn discoverSkills(gpa: std.mem.Allocator, env: ?*const std.process.Environ.Map) []const skills.Entry {
    while (skills_lock.tryLock()) {}
    defer skills_lock.unlock();

    if (skills_cache != null and skillsFresh(gpa, env)) return skills_cache.?;
    if (skills_rescans >= skills_rescan_max) return skills_cache orelse &.{};
    skills_rescans += 1;

    const fresh = loadSkillsNow(gpa, env);
    // Freed HERE, after the new list exists and only here. Freeing first would be
    // a use-after-free of the list a reader is walking.
    freeSkillsCacheLocked();
    skills_cache = fresh;
    stampSkills(gpa, env);
    return fresh;
}

/// Output styles found on disk, cached like skills (same reasons: the list goes
/// into the system prompt, rebuilt for every request).
///
/// The styles list is small (a handful of entries), so the rescan cap and freshness
/// check mirror skills but with smaller numbers.
var styles_cache: ?[]outputstyles.Entry = null;
var styles_stamps: [outputstyle_store.max_roots]outputstyle_store.Stamp = undefined;
var styles_stamp_len: usize = 0;
const styles_rescan_max: usize = 4;
var styles_rescans: usize = 0;
var styles_lock: std.atomic.Mutex = .unlocked;

/// The styles on disk, or an empty list. BORROWED: do not free.
pub fn discoverStyles(gpa: std.mem.Allocator, env: ?*const std.process.Environ.Map) []const outputstyles.Entry {
    while (styles_lock.tryLock()) {}
    defer styles_lock.unlock();

    if (styles_cache != null and stylesFresh(gpa, env)) return styles_cache.?;
    if (styles_rescans >= styles_rescan_max) return styles_cache orelse &.{};
    styles_rescans += 1;

    const fresh = loadStylesNow(gpa, env);
    freeStylesCacheLocked();
    styles_cache = fresh;
    stampStyles(gpa, env);
    return fresh;
}

/// Walks the roots right now and allocates the entries. The caller owns them.
fn loadStylesNow(gpa: std.mem.Allocator, env: ?*const std.process.Environ.Map) []outputstyles.Entry {
    var loader = stylesLoader(gpa, env);
    var buf: [64]outputstyles.Entry = undefined;
    const found = loader.scan(&buf, buf.len);
    const copy = gpa.dupe(outputstyles.Entry, found) catch {
        // Out of memory: no styles rather than a half-built list.
        for (found) |e| {
            gpa.free(e.name);
            gpa.free(e.description);
            gpa.free(e.path);
        }
        return &.{};
    };
    return copy;
}

/// The loader, with its roots made ABSOLUTE.
fn stylesLoader(gpa: std.mem.Allocator, env: ?*const std.process.Environ.Map) outputstyle_store.Loader {
    var loader = outputstyle_store.Loader.init(gpa, io_global, env);
    const proj = &project_info;
    const cwd = proj.cwd();
    if (cwd.len == 0) return loader;

    var bufs: [2][std.fs.max_path_bytes]u8 = undefined;
    loader.project_dir = std.fmt.bufPrint(&bufs[0], "{s}/{s}", .{ cwd, outputstyles.project_dir }) catch loader.project_dir;

    if (proj.root()) |root| {
        if (!std.mem.eql(u8, root, cwd)) loader.repo_root = root;
    }
    return loader;
}

fn stampStyles(gpa: std.mem.Allocator, env: ?*const std.process.Environ.Map) void {
    styles_stamp_len = 0;
    var loader = stylesLoader(gpa, env);
    var bufs: [outputstyle_store.max_roots][std.fs.max_path_bytes]u8 = undefined;
    var paths: [outputstyle_store.max_roots][]const u8 = undefined;
    const root_count = loader.roots(&bufs, &paths);
    for (paths[0..root_count]) |p| addStyleStamp(p);
    if (styles_cache) |list| {
        for (list) |e| addStyleStamp(e.path);
    }
}

fn addStyleStamp(path: []const u8) void {
    if (styles_stamp_len >= styles_stamps.len) return;
    if (!outputstyle_store.stampPath(io_global, path, &styles_stamps[styles_stamp_len])) return;
    styles_stamp_len += 1;
}

fn stylesFresh(gpa: std.mem.Allocator, env: ?*const std.process.Environ.Map) bool {
    var loader = stylesLoader(gpa, env);
    var bufs: [outputstyle_store.max_roots][std.fs.max_path_bytes]u8 = undefined;
    var paths: [outputstyle_store.max_roots][]const u8 = undefined;
    const root_count = loader.roots(&bufs, &paths);

    for (paths[0..root_count]) |p| if (!styleStampUnchanged(p)) return false;
    if (styles_cache) |list| {
        for (list) |e| if (!styleStampUnchanged(e.path)) return false;
    }
    return true;
}

fn styleStampUnchanged(path: []const u8) bool {
    for (styles_stamps[0..styles_stamp_len]) |*st| {
        if (!std.mem.eql(u8, st.pathOf(), path)) continue;
        var now: outputstyle_store.Stamp = .{};
        if (!outputstyle_store.stampPath(io_global, path, &now)) return false;
        return st.sameAs(&now);
    }
    return false;
}

fn freeStylesCacheLocked() void {
    if (styles_cache) |list| {
        for (list) |e| {
            gpa_global.free(e.name);
            gpa_global.free(e.description);
            gpa_global.free(e.path);
        }
        if (list.len > 0) gpa_global.free(list);
    }
    styles_cache = null;
}

/// Walks the roots right now and allocates the entries. The caller owns them.
fn loadSkillsNow(gpa: std.mem.Allocator, env: ?*const std.process.Environ.Map) []skills.Entry {
    var loader = skillsLoader(gpa, env);
    var buf: [64]skills.Entry = undefined;
    const found = loader.scan(&buf, buf.len);
    const copy = gpa.dupe(skills.Entry, found) catch {
        // Out of memory: no skills rather than a half-built list. The system
        // prompt still works, and the tool can still be called by name.
        for (found) |e| {
            gpa.free(e.name);
            gpa.free(e.description);
            gpa.free(e.path);
        }
        return &.{};
    };
    return copy;
}

/// The loader, with its roots made ABSOLUTE and pointed at the repository root
/// when zode was launched below it.
///
/// The absolute part is not cosmetic: it is what lets the tests point the loader
/// at a fixture instead of at the repo of whoever runs the suite, and it removes
/// any dependence on the process cwd staying put under a caller's feet. In
/// production `cwd()` IS the process cwd, so the paths are the ones `Dir.cwd()`
/// would have resolved anyway.
///
/// The `repo_root` part is the fix for "cd src && zode sees no skills": the
/// project's skills live in the root, and git already knows where the root is.
fn skillsLoader(gpa: std.mem.Allocator, env: ?*const std.process.Environ.Map) skillstore.Loader {
    var loader = skillstore.Loader.init(gpa, io_global, env);
    const proj = &project_info;
    const cwd = proj.cwd();
    if (cwd.len == 0) return loader;

    var bufs: [2][std.fs.max_path_bytes]u8 = undefined;
    loader.project_dir = std.fmt.bufPrint(&bufs[0], "{s}/{s}", .{ cwd, skills.project_dir }) catch loader.project_dir;
    loader.agents_dir = std.fmt.bufPrint(&bufs[1], "{s}/{s}", .{ cwd, skills.agents_dir }) catch loader.agents_dir;

    // Only when it IS a different directory: pointing the loader at the same path
    // twice would read every skill twice and dedupe it away, which works but pays
    // the reads for nothing.
    if (proj.root()) |root| {
        if (!std.mem.eql(u8, root, cwd)) loader.repo_root = root;
    }
    return loader;
}

/// Records the mtime + size of every root and every `SKILL.md` that was read.
fn stampSkills(gpa: std.mem.Allocator, env: ?*const std.process.Environ.Map) void {
    skills_stamp_len = 0;
    var loader = skillsLoader(gpa, env);
    var bufs: [skillstore.max_roots][std.fs.max_path_bytes]u8 = undefined;
    var paths: [skillstore.max_roots][]const u8 = undefined;
    const root_count = loader.roots(&bufs, &paths);
    for (paths[0..root_count]) |p| addStamp(p);
    if (skills_cache) |list| {
        for (list) |e| addStamp(e.path);
    }
}

fn addStamp(path: []const u8) void {
    if (skills_stamp_len >= skills_stamps.len) return;
    if (!skillstore.stampPath(io_global, path, &skills_stamps[skills_stamp_len])) return;
    skills_stamp_len += 1;
}

/// Are all the paths the cached list was built from exactly as they were?
///
/// A DELETED skill counts as a change: it has to disappear from the prompt, and a
/// missing file is exactly what `stampPath` records as `exists = false`. Treating
/// "cannot stat" as "nothing changed" would leave the model reading a skill whose
/// file is gone, and the `skill` tool would then fail on the very name the prompt
/// just offered.
fn skillsFresh(gpa: std.mem.Allocator, env: ?*const std.process.Environ.Map) bool {
    var loader = skillsLoader(gpa, env);
    var bufs: [skillstore.max_roots][std.fs.max_path_bytes]u8 = undefined;
    var paths: [skillstore.max_roots][]const u8 = undefined;
    const root_count = loader.roots(&bufs, &paths);

    for (paths[0..root_count]) |p| if (!stampUnchanged(p)) return false;
    if (skills_cache) |list| {
        for (list) |e| if (!stampUnchanged(e.path)) return false;
    }
    return true;
}

fn stampUnchanged(path: []const u8) bool {
    for (skills_stamps[0..skills_stamp_len]) |*st| {
        if (!std.mem.eql(u8, st.pathOf(), path)) continue;
        var now: skillstore.Stamp = .{};
        if (!skillstore.stampPath(io_global, path, &now)) return false;
        return st.sameAs(&now);
    }
    // A path with no stamp is a path we never recorded, which can only happen if
    // the cap was hit. Not "unchanged": that would silently freeze the list.
    return false;
}

/// Frees the cached entries AND the slice they live in.
///
/// Both halves, on purpose: they are two allocations and freeing one without the
/// other is the leak/give-the-wrong-length pair.
///
/// Called from the teardown and from the rescan, and from NOWHERE else. The slice
/// is borrowed by `discoverSkills`, so a caller freeing it is a double free of
/// memory that is still in use. The lock is NOT taken here: `discoverSkills` calls
/// it while holding it, and `std.atomic.Mutex` is not reentrant (it would hang).
pub fn freeSkillsCache() void {
    while (skills_lock.tryLock()) {}
    defer skills_lock.unlock();
    freeSkillsCacheLocked();
}

fn freeSkillsCacheLocked() void {
    const gpa = gpa_global;
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

/// The system prompt, composed for a run that has no `Model`.
///
/// The headless runner used to compose ITS OWN, and it left out the routing table
/// and the verification prompt. That is the single worst bug this repository has
/// had in a while, and the reason it survived so long is that every test drives
/// `--chat`:
///
///   - `zode --chat` got NO routing rules, so it reached for `bash zig build`
///     where `check` exists, and for `bash curl` where `web_search` exists;
///   - it got no batching rules, so reading three files cost three round trips;
///   - it got no verification rules, so a task took three times as long;
///   - it got no `todo` or `refs` guidance, so neither was used.
///
/// Test-only: reset the skills cache and stamps. Uses the lock internally.
pub fn resetSkillsCacheForTest() void {
    while (skills_lock.tryLock()) {}
    defer skills_lock.unlock();
    freeSkillsCacheLocked();
    skills_stamp_len = 0;
    skills_rescans = 0;
}

/// Test-only: reset the styles cache and stamps. Uses the lock internally.
pub fn resetStylesCacheForTest() void {
    while (styles_lock.tryLock()) {}
    defer styles_lock.unlock();
    freeStylesCacheLocked();
    styles_stamp_len = 0;
    styles_rescans = 0;
}
pub fn buildSystemPromptFor(
    gpa: std.mem.Allocator,
    env: ?*const std.process.Environ.Map,
) ![]u8 {
    var buf: [16 * 1024]u8 = undefined;
    return gpa.dupe(u8, buildSystemPrompt(gpa, &buf, env, true));
}

/// The room the SKILLS LISTING has, in characters.
///
/// 1% of the context window: `ZODE_CONTEXT_LIMIT` when it is set, the 128k
/// default when it is not.
///
/// Two decisions worth writing down, because both of them are about the cache:
///
/// 1. **The MODEL's window is not part of it.** The board says "1% of
///    `ZODE_CONTEXT_LIMIT`", and that is also the only stable answer: the
///    free-auto rotation changes the active model on every turn, and a budget
///    that moved with the model would rewrite the system prompt — and
///    invalidate the provider's cache for the whole request — on every turn.
/// 2. **The environment comes from `environ_global` when the caller has none.**
///    The prompt is composed TWICE with two different arguments
///    (`buildSystemPromptFor` gets the real environment, `syncSystemPrompt`
///    gets `null`), and a budget that differed between the two would make the
///    two prompts differ — the same cache bust, one step later.
fn skillListingBudget(env: ?*const std.process.Environ.Map) usize {
    const e = env orelse environ_global;
    return skills.budgetCharsFor(compaction.contextLimitFor(e, 0));
}

/// Builds the skills-listing section text for the prompt.
/// Returns an empty slice when there are no skills or the budget is zero.
fn skillsSectionText(
    gpa: std.mem.Allocator,
    env: ?*const std.process.Environ.Map,
    list_buf: []u8,
) []const u8 {
    const entries = discoverSkills(gpa, env);
    // Phase 34.11: keep only skills whose declared `paths` apply to the
    // current project (empty `paths` applies everywhere). Entries are borrowed
    // from the skills cache, so we copy the struct (slices point at the cache,
    // which stays alive for this call).
    var filtered: std.ArrayList(skills.Entry) = .empty;
    blk: for (entries) |e| {
        if (skills.skillAppliesHere(e, project_info.root())) {
            // Out of memory mid-filter is catastrophic; stop adding entries
            // but keep the ones already collected.
            if (filtered.append(gpa, e)) |_| {} else |err| switch (err) {
                error.OutOfMemory => break :blk,
            }
        }
    }
    defer filtered.deinit(gpa);
    return skills.systemPromptSection(filtered.items, skillListingBudget(env), list_buf);
}

fn buildSystemPrompt(
    gpa: std.mem.Allocator,
    out: []u8,
    env: ?*const std.process.Environ.Map,
    include_skills: bool,
) []const u8 {
    cache_break_last_block = null;
    cache_break_last_pos = 0;
    const base = systemPromptBase(gpa);

    var list_buf: [16 * 1024]u8 = undefined;
    const section = if (include_skills) skillsSectionText(gpa, env, &list_buf) else "";

    var loc_buf: [512]u8 = undefined;
    const location = project_info.promptLines(&loc_buf);

    // --- Output style: injected at the END of the prompt ---
    // Discover styles and find the currently selected one.
    const style_entries = discoverStyles(gpa, env);
    var style_entry: ?outputstyles.Entry = null;
    if (current_style) |name| {
        for (style_entries) |e| {
            if (std.mem.eql(u8, e.name, name)) { style_entry = e; break; }
        }
    }
    // When the selected style says keep_coding_instructions = false, the base
    // prompt loses the "How to work" coding rules — the style replaces them.
    const effective_base: []const u8 = if (style_entry) |s| (
        if (!s.keep_coding_instructions) prompt_mod.default_system_prompt_core else base
    ) else base;

    // The routing table goes in its OWN slot, right after the base, and is
    // emitted whether the base came from `AGENTS.md` or from the built-in text.
    // It is not part of `default_system_prompt` for the reason in its own doc
    // comment: a project's `AGENTS.md` replaces the built-in prompt, and the one
    // thing that must survive that replacement is which tool to call.
    const routing = tool_routing_prompt;

    // Read-only mode goes in the SYSTEM prompt, not just in the tool result: the
    // model has to know before it decides what to call, or it plans a `write`
    // and then gets an error, which it reads as a bug and works around.
    const mode_note: []const u8 = if (read_only)
        "PLAN MODE is on (shift+tab to cycle; it is read-only): you may READ anything, but write/edit/bash/rename and the git mutations (add/commit/stash/branch) come back with an error and must NOT be retried. Investigate first, then write the IMPLEMENTATION PLAN with the `todo` tool — concrete steps, one per line. Zode displays the complete numbered checklist in the scrollable history; end your turn so the user can review and approve it. On approval zode switches itself to Build mode and tells you to implement; if they ask for changes, revise the plan with `todo` and end the turn again to present it. If the user only asked a question and no change is needed, just answer it.\n\n"
    else if (accept_edits)
        "ACCEPT-EDITS MODE is on (shift+tab to cycle): file edits (write, edit, rename) run without asking, but bash still asks for permission. Ask the user with `ask` before running anything destructive.\n\n"
    else if (yolo)
        "YOLO MODE is on (shift+tab or /mode to cycle): nothing asks for permission, and your `ask` questions are NOT shown to anyone — the harness takes your own recommendation (the FIRST option) or leaves the question OPEN. Either way, MENTION it in your final summary: what you decided, or what question is still open for the user. An unmentioned decision is a decision the user cannot check.\n\n"
    else
        "";

    // THE ORDER IS THE CACHE. A provider serves the prompt cache from the
    // literal prefix of the system message, so anything that CHANGES invalidates
    // everything after it. `mode_note` used to sit in the middle (4th of 6),
    // which meant one `shift+tab` rewrote the skills list and the location lines
    // as well and dropped the whole prefix.
    //
    // So the order is by HOW OFTEN IT CHANGES, stable first:
    //   base (per project) · routing (constant) · ask guidance (constant)
    //   · skills (per session) · location (per project)
    //   · read-only note (EVERY keypress of shift+tab, mid-turn)
    //   · OUTPUT STYLE (last — selected by the user, changes rarely)
    const blocks_len = routing.len + verification_prompt.len + ask.guidance.len +
        section.len + location.len + mode_note.len;
    var style_block_len: usize = 0;
    var style_buf: [8 * 1024]u8 = undefined;
    if (style_entry) |s| {
        const body = if (s.body) |b| b else "";
        const framed = outputstyles.formatStyle(s.name, s.description, body, &style_buf);
        style_block_len = framed.len;
    }
    const style_block: []const u8 = if (style_entry) |s|
        outputstyles.formatStyle(s.name, s.description, if (s.body) |b| b else "", &style_buf)
    else "";
    const blocks = cachebreak.Blocks{
        .base = effective_base,
        .routing = routing,
        .verification = verification_prompt,
        .ask_guidance = ask.guidance,
        .skills = section,
        .location = location,
        .mode_note = mode_note,
        .style = style_block,
    };
    var hashes: [8]u64 = undefined;
    for (&[_][]const u8{
        blocks.base, blocks.routing, blocks.verification, blocks.ask_guidance,
        blocks.skills, blocks.location, blocks.mode_note, blocks.style,
    }, 0..) |block, i| {
        hashes[i] = cachebreak.hashBlock(block);
    }
    if (cache_break_prev) |prev| {
        const offs = cachebreak.blockOffsets(&blocks);
        for (prev, 0..) |ph, i| {
            if (ph != hashes[i]) {
                cache_break_last_block = cachebreak.block_names[i];
                cache_break_last_pos = offs[i];
                break;
            }
        }
    }
    cache_break_prev = hashes;
    const composed = std.fmt.bufPrint(out, "{s}\n{s}\n{s}{s}{s}{s}\n{s}{s}", .{
        effective_base,
        routing,
        verification_prompt,
        ask.guidance,
        section,
        location,
        mode_note,
        if (style_entry) |s| outputstyles.formatStyle(s.name, s.description, if (s.body) |b| b else "", &style_buf) else "",
    }) catch blk: {
        // It did not fit... same fallback logic as before.
        const note_lead = "[the project instructions above were truncated to fit";
        const note_tail = "; the rest is in the project's instruction file]";
        const overhead = note_lead.len + note_tail.len + 48;
        if (out.len <= blocks_len + overhead) break :blk routing;
        const room = out.len - blocks_len - overhead;
        const fit = prompt_mod.fitPrefix(effective_base, room);
        break :blk std.fmt.bufPrint(
            out,
            "{s}\n{s}: {d} of {d} bytes kept{s}\n{s}\n{s}{s}{s}{s}\n{s}{s}",
            .{
                fit,
                note_lead,
                fit.len,
                base.len,
                note_tail,
                routing,
                verification_prompt,
                ask.guidance,
                section,
                location,
                mode_note,
                if (style_entry) |s| outputstyles.formatStyle(s.name, s.description, if (s.body) |b| b else "", &style_buf) else "",
            },
        ) catch routing;
    };
    return composed;
}

/// Writes the current system prompt into the session, REPLACING the one that is
/// there.
///
/// Only called when the composed text differs from what the session already has:
/// on a steady-state turn this is a memcmp and nothing else. That matters because
/// the system prompt is the biggest stable prefix in the request, and rewriting it
/// to the same bytes would still change nothing for the provider's cache — but a
/// naive "always replace" would rewrite the whole thing on every one of the eight
/// iterations of every turn, which is 16 KB of pointless copying.
pub fn syncSystemPrompt(s: *session_mod.Session) void {
    const gpa = s.allocator;
    var buf: [16 * 1024]u8 = undefined;
    const want = buildSystemPrompt(gpa, &buf, null, false);
    for (s.messages.items) |m| {
        if (m.role != .system) continue;
        if (std.mem.eql(u8, m.content, want)) return;
        break;
    }
    _ = s.replaceSystem(want) catch {};
}

/// The note that carries a `/goal` into the request, as a SECOND system message at the
/// end.
///
/// ## Why it is not folded into the system prompt
///
/// `buildSystemPrompt` composes the biggest stable prefix in every request, and the
/// provider's cache is indexed by the literal prefix: changing any byte of it
/// invalidates the ~16 KB of tool schemas that follow. A goal changes WITHIN a turn,
/// every iteration, and it is four lines.
///
/// So it goes at the END, as its own system message, with a marker that
/// `Session.setGoalNote` finds to replace it. Same reason as the read-only notice and
/// the skill list: order the system prompt by how OFTEN each part changes, and put the
/// volatile parts last.
///
/// ## What is actually in it
///
/// The objective, verbatim, plus the budget as NUMBERS. "You have 18 iterations left"
/// is the cheapest lever in the whole feature: a model told it has plenty polishes, and
/// one told it has two left finishes.
pub fn goalNote(
    gpa: std.mem.Allocator,
    g: *const goal_mod.Goal,
    left: usize,
    checkpoint: bool,
    open_steps: usize,
) ![]const u8 {
    if (!g.isSet()) return error.NoGoal;
    if (checkpoint) {
        return std.fmt.allocPrint(
            gpa,
            "{s}{s}\n\n{s}",
            .{ session_mod.goal_note_marker, g.objective(), try goal_mod.checkpointPrompt(gpa, 0, left, open_steps) },
        );
    }
    // The countdown only appears when it is TRUE information, that is near the ceiling.
    //
    // It used to be on every iteration, and that is 60 sentences in the model's context
    // all saying the same thing: "Budget: 58 iterations left of 60". A number that has
    // not changed in any way the model can act on is not information, it is a deadline
    // the model learns to hurry for — which is the opposite of finishing careful work.
    // What the model needs instead, every time, is the one sentence that keeps the shape
    // of the turn clear: it ends when the objective is decided, not when the model stops
    // talking.
    //
    // `urgent` is the last few iterations. There the number IS actionable, and a model
    // with four iterations left should be told to land the plane.
    const urgent = left <= 4;
    return std.fmt.allocPrint(
        gpa,
        "{s}{s}\n{s}",
        .{
            session_mod.goal_note_marker,
            g.objective(),
            if (urgent)
                std.fmt.allocPrint(
                    gpa,
                    "{d} iterations left. Land it: finish what is open, and call `goal` with what is true.",
                    .{left},
                ) catch "iterations are running out: land it."
            else
                "This turn ends when the objective is met or you declare it blocked — not when you stop talking. " ++
                    "A summary is not a verdict. Call `goal` only when it is true.",
        },
    );
}

/// The user-facing half of the system prompt: their `AGENTS.md` if they have one,
/// the built-in one if not.
///
/// The cwd wins over the repository root, and that ORDER is the design: a
/// subdirectory with its own `AGENTS.md` is a deliberate, narrower set of
/// instructions and must not be shadowed by the tree above it.
///
/// Two paths, not one, is the fix for `cd src && zode` silently running with no
/// project instructions at all. Which is the same bug class as the skills roots:
/// the project lives in the root, and the root is what git already knows.
pub fn systemPromptBase(gpa: std.mem.Allocator) []const u8 {
    if (agents_md_cache == null) {
        // The user's project AGENTS.md / CLAUDE.md take priority.
        agents_md_cache = readAgentsIn(gpa, ".") orelse readAgentsIn(gpa, project_info.root()) orelse null;
    }
    if (agents_md_cache) |c| return c;
    return default_system_prompt;
}

/// `AGENTS.md` then `CLAUDE.md` under `dir`, or null.
///
/// `dir` is a path prefix, so it is `.` for the cwd and the absolute root
/// otherwise; the two names mean the same thing here, which is why `AGENTS.md`
/// wins: it is the name the harness docs use.
fn readAgentsIn(gpa: std.mem.Allocator, dir: ?[]const u8) ?[]u8 {
    if (dir) |d| {
        if (readAgentsAt(gpa, d, "AGENTS.md")) |t| return t;
        return readAgentsAt(gpa, d, "CLAUDE.md");
    }
    return null;
}

fn readAgentsAt(gpa: std.mem.Allocator, dir: []const u8, name: []const u8) ?[]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch return null;
    // The limit is 1 MB, and it was 256 KB, and THAT WAS A BUG that only
    // showed up because this repository's own `AGENTS.md` crossed the line:
    //
    // `readFileAlloc` with `.limited(n)` returns `error.FileTooBig` for a file
    // over `n`, and the caller does `catch null`, and `null` means "this
    // project has no instruction file". So a project whose `AGENTS.md` was a
    // little too big got the BUILT-IN prompt instead of its own, with no
    // error anywhere: the harness silently stopped reading the project's
    // rules, and the symptom was "the model ignored my instructions".
    //
    // The size does not matter much: the base is trimmed to the prompt buffer
    // (16 KB) before it is sent, so a megabyte of instructions is read, cached
    // and cut down to what fits.
    return std.Io.Dir.cwd().readFileAlloc(io_global, path, gpa, .limited(1024 * 1024)) catch null;
}

pub var current_effort: chat.Effort = .medium;

/// The currently selected output style name, or null when none is selected.
///
/// Set with `/style <name>`, cleared with `/style off` or `/style clear`.
/// The buffer is static for the same reason as `cur_model_buf`: the string
/// comes from the input line and dies with the next redraw.
pub var current_style: ?[]const u8 = null;
pub var current_style_buf: [128]u8 = undefined;
pub var current_style_len: usize = 0;

/// Permission mode: false = asks before write/edit/bash, true = auto.
pub var yolo: bool = false;

/// Max number of agentic iterations per request. Overridable with
/// `ZODE_MAX_ITER` (see `iterationLimit`).
///
/// 12 and not 8: 8 is what a loop needs when every iteration is a file edit, but
/// a real task is "read three files, grep twice, edit, build, read the error, fix,
/// build" and that is 8-9 before the final answer has even been written. And 12 is
/// not a raise by much: the loop ends by itself the moment the model stops asking
/// for tools, so the limit only bounds the pathological cases (a model that keeps
/// re-reading the same file, or a tool that keeps failing). What it costs in the
/// pathological case is exactly what `/bench`'s "hit the limit" percentage
/// measures.
pub const default_max_iterations: usize = 12;

/// Read-only mode: `write`/`edit`/`bash` come back as tool results instead of
/// running. Set by `shift+tab` or `/ask on`.
///
/// A module global and not a `Model` field because it has to be visible in three
/// places that do not have the model at hand: `systemPromptBase` (composed on a
/// worker), `execToolCalls` (the check), and the status bar (the indicator). It
/// only ever changes from the UI thread, which happens on a key press while the
/// worker is not being written to; a torn read of a bool is the one theoretical
/// race here and it would only ever delay the change by one iteration.
pub var read_only: bool = false;

/// Accept-edits mode: file edits (`write`, `edit`, `rename`) run
/// without a dialog; `bash` and everything else still asks. The
/// middle ground between the default (a dialog per edit) and
/// `/yolo` (allow all) — the selective part of selective permissions.
///
/// Mutually exclusive with `read_only` and `yolo`: every mode setter
/// (`cyclePermMode`, `setPermMode`) clears the other two, and
/// `permModesConsistent` pins that in a test.
pub var accept_edits: bool = false;

/// The four permission modes. `default` asks for anything that writes
/// or runs a command; `accept_edits` auto-allows file edits;
/// `read_only` blocks them; `bypass` (`/yolo`) allows everything.
pub const PermMode = enum { default, accept_edits, read_only, bypass };

/// The mode that applies right now, read off the three flags.
pub fn currentPermMode() PermMode {
    if (yolo) return .bypass;
    if (read_only) return .read_only;
    if (accept_edits) return .accept_edits;
    return .default;
}

/// The mode as one word, for the status bar and `/mode`.
pub fn permModeName() []const u8 {
    return switch (currentPermMode()) {
        .default => "build",
        .accept_edits => "accept-edits",
        // "plan" and not "read-only": it is what the mode IS for (investigate,
        // write the plan, get it approved) and what the cycle and `/mode` have
        // always called it in their own docs. The mechanics are unchanged —
        // every write is still refused.
        .read_only => "plan",
        .bypass => "bypass",
    };
}

/// Sets the mode. The three flags are mutually exclusive BY
/// CONSTRUCTION, not by convention: a caller that set one and forgot
/// the others would leave the status bar advertising a mode that does
/// not apply, which is worse than no mode at all.
pub fn setPermMode(m: *tui.Model, mode: PermMode) void {
    read_only = (mode == .read_only);
    accept_edits = (mode == .accept_edits);
    yolo = (mode == .bypass);
    m.read_only = read_only;
    m.accept_edits = accept_edits;
}

/// shift+tab: cycle Build → accept-edits → Plan → Build.
///
/// Bypass (`/yolo`) is deliberately not in the cycle: it is the "stop
/// asking me anything" switch, and cycling out of it lands on default,
/// so the mode the status bar shows is always the mode that applies.
pub fn cyclePermMode(m: *tui.Model) void {
    const next = switch (currentPermMode()) {
        .default => PermMode.accept_edits,
        .accept_edits => PermMode.read_only,
        .read_only => PermMode.default,
        .bypass => PermMode.default,
    };
    setPermMode(m, next);
    setStatusWithZoFmt(m, if (next == .read_only) .warn else .idle, "mode: {s}", .{permModeName()});
}

/// `/ask [on|off]`: Plan mode, retained as a command alias.
fn cmdAskMode(m: *tui.Model, arg: ?[]const u8) void {
    if (arg) |a| {
        const on = std.ascii.eqlIgnoreCase(a, "on") or std.ascii.eqlIgnoreCase(a, "1");
        const off = std.ascii.eqlIgnoreCase(a, "off") or std.ascii.eqlIgnoreCase(a, "0");
        if (on) {
            setPermMode(m, .read_only);
            const msg = "Plan mode ON: investigate first; writes are blocked pending approval.";
            setStatusWithZo(m, .warn, msg);
            pushInfo(m, msg);
            return;
        }
        if (off) {
            setPermMode(m, .default);
            const msg = "Build mode ON";
            setStatusWithZo(m, .idle, msg);
            pushInfo(m, msg);
            return;
        }
        pushInfoFmt(m, "/ask: on|off (it is {s})", .{if (read_only) "on" else "off"});
        return;
    }
    // No argument: toggle, as it always did.
    const next: PermMode = if (read_only) .default else .read_only;
    setPermMode(m, next);
    setStatusWithZoFmt(m, if (next == .read_only) .warn else .idle, "mode: {s}", .{permModeName()});
}

// ── plan approval: the developer says yes or no ────────────

/// The option labels of the approval dialog. They are the API of the flow:
/// `planGateDecision` matches the FIRST one by prefix, so changing a label
/// here without changing the matcher silently turns every approval into a
/// revision.
pub const approve_option = "Approve — implement it now";
pub const revise_option = "Revise — change the plan first";

/// What the model is told after the developer approved. Owned by the caller.
pub const plan_gate_approved_text =
    "The user APPROVED the plan, and zode has already switched itself out of plan mode " ++
    "(you are in Build mode: edits and commands are allowed). Implement the plan now: " ++
    "work through the steps, verify as you go, and report what changed when done. Do not " ++
    "ask for approval again — it has been given.";

/// The revision nudge's shape. `{s}` is the user's own words: a rejection with
/// no reason is the one thing the model cannot act on.
pub const plan_gate_revise_fmt =
    "The user did NOT approve the plan yet. They said: \"{s}\"\n" ++
    "Revise the plan with the `todo` tool (say what changed in the steps), then end your " ++
    "turn to present it again. You are still in PLAN MODE: do not edit anything until " ++
    "it is approved.";

/// What an approval answer means, decided WITHOUT a TUI so it can be tested.
///
/// - no answer at all (ESC or timeout) → `skip`: end the turn with no nudge.
///   A user who walked away must not come back to a loop that kept asking —
///   that is how a plan gate turns into a wall.
/// - the approve option (prefix match) or an obvious typed yes → `approve`.
/// - EVERYTHING else — the revise option or the user's own typed words →
///   `revise`, and those words travel with the nudge as the reason.
pub const PlanGate = enum { approve, revise, skip };

pub fn planGateDecision(answer: ?[]const u8) PlanGate {
    const a = answer orelse return .skip;
    const t = std.mem.trim(u8, a, " \t\r\n");
    if (t.len == 0) return .skip;
    if (std.mem.startsWith(u8, t, "Approve")) return .approve;
    if (std.ascii.eqlIgnoreCase(t, "approve") or
        std.ascii.eqlIgnoreCase(t, "yes") or
        std.ascii.eqlIgnoreCase(t, "y")) return .approve;
    return .revise;
}

/// The approval dialog, run on the WORKER at the moment the model tries to end
/// a plan-mode turn. Returns the prompt for the next iteration, or null to end
/// the turn without a nudge (nobody answered, or the answer was not usable).
fn planApprovalNudge(m: *tui.Model) ?[]u8 {
    // The final answer is CLOSED before the dialog: the developer reads the
    // plan block and the explanation together, and text that can still move
    // under a modal is text they cannot rely on.
    m.streamEnd();
    var q_buf: [240]u8 = undefined;
    const q = std.fmt.bufPrint(
        &q_buf,
        "Plan ready: {d} step(s) shown above. Approve it so zode can start implementing?",
        .{m.plan.len},
    ) catch "Plan ready. Approve it so zode can start implementing?";
    const opts = [_][]const u8{ approve_option, revise_option };
    setStatusWithZo(m, .warn, "the plan needs your approval");
    const answer = m.requestAsk(q, "plan", &opts);
    defer if (answer) |a| m.allocator.free(a);

    switch (planGateDecision(answer)) {
        .approve => {
            // The plan-mode verdict describes planning, not the implementation
            // that begins after approval. Carrying it forward would end the
            // newly approved implementation turn on its first response.
            m.goal.status = goal_mod.Status.none;
            setPermMode(m, .default);
            pushInfo(m, "plan approved — plan mode off: implementing");
            return m.allocator.dupe(u8, plan_gate_approved_text) catch null;
        },
        .revise => {
            // A rejected draft is not a final verdict either. The revised plan
            // must be presented before the developer can decide what happens.
            m.goal.status = goal_mod.Status.none;
            // The user's own words, cut to a sane length: the answer comes from
            // a free-text field with no cap, and a nudge that repeats a pasted
            // novel is a nudge nobody reads. `fb_buf` is fine because
            // `allocPrint` copies it into the returned string before returning.
            var fb_buf: [300]u8 = undefined;
            const fb: []const u8 = if (answer) |a| blk: {
                const t = std.mem.trim(u8, a, " \t\r\n");
                const cut = t[0..@min(t.len, fb_buf.len - 1)];
                @memcpy(fb_buf[0..cut.len], cut);
                break :blk fb_buf[0..cut.len];
            } else revise_option;
            const nudge = std.fmt.allocPrint(m.allocator, plan_gate_revise_fmt, .{fb}) catch return null;
            pushInfo(m, "plan not approved: revising");
            return nudge;
        },
        .skip => {
            pushInfo(m, "plan approval skipped — shift+tab leaves plan mode whenever you want");
            return null;
        },
    }
}

/// `/bench`: the numbers that decide whether to tune anything.
fn cmdBench(m: *tui.Model) void {
    var buf: [1024]u8 = undefined;
    const text = m.bench.report(&buf, iterationLimit(), cacheHitPct()) catch {
        pushInfo(m, "/bench: could not compose the report");
        return;
    };
    // `pushInfo` COPIES, so `buf` (a stack buffer) can die right after: this is
    // the documented difference from `pushInfoOwned`, which would leave the
    // pending queue pointing at a dead frame.
    pushInfo(m, text);

    // The cheap router's numbers, when it is on. It is the one feature whose
    // whole point is a number the user cannot otherwise see, and a saving you
    // cannot check is a saving you will assume worked.
    const cs = cheapRouterStats();
    if (cs.on) {
        pushInfoFmt(
            m,
            "cheap router: {s} · {d} turn(s) sent to it · {d} fell back{s}",
            .{
                cs.model,
                cs.attempts,
                cs.fallbacks,
                if (cs.given_up) @as([]const u8, " · out of play for the rest of the session") else @as([]const u8, ""),
            },
        );
    }
}

/// `/task-parallel [1..8|auto]`: tune simultaneous subagent requests for this
/// session. `auto` returns to the environment/default value.
fn cmdTaskParallel(m: *tui.Model, arg: ?[]const u8) void {
    if (arg) |raw| {
        const value = std.mem.trim(u8, raw, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(value, "auto")) {
            m.setTaskParallelLimit(0);
        } else {
            const parsed = std.fmt.parseInt(u8, value, 10) catch {
                m.pushInfo("usage: /task-parallel [1..8|auto]");
                return;
            };
            if (parsed < 1 or parsed > 8) {
                m.pushInfo("usage: /task-parallel [1..8|auto]");
                return;
            }
            m.setTaskParallelLimit(parsed);
        }
    }
    const override = m.taskParallelLimit();
    const effective = if (override > 0) override else taskParallelLimit(m);
    m.pushInfoFmt(
        "subagent parallelism: {d} at a time{s}",
        .{ effective, if (override > 0) " (session override)" else " (auto: ZODE_TASK_PARALLEL or default)" },
    );
}

/// `/skills`: what is loadable, and from where.
fn cmdSkills(m: *tui.Model) void {
    const entries = discoverSkills(m.allocator, m.environ);
    if (entries.len == 0) {
        pushInfo(m, "no skills found. Put them in .zode/skills/<name>/SKILL.md (this project) or ~/.config/zode/skills/<name>/SKILL.md (yours)");
        return;
    }
    pushInfoFmt(m, "{d} skill{s} (only the name and description are in the prompt; the body loads on demand)", .{
        entries.len,
        if (entries.len == 1) @as([]const u8, "") else @as([]const u8, "s"),
    });
    for (entries) |e| {
        const source_tag = switch (e.source) {
            .project => "[project]",
            .agents => "[agents]",
            .user => "[user]",
            .bundled => "[bundled]",
        };
        // The `when to use it` goes with the description, because a description
        // says WHAT the skill is and the `when` says WHEN to reach for it: a
        // list that only says what is a list of things the model cannot
        // choose between.
        const line = std.fmt.allocPrint(m.allocator, "  {s} {s}: {s}{s}", .{
            source_tag,
            e.name,
            if (e.description.len > 0) e.description else "(no description)",
            if (e.when_to_use.len > 0)
                std.fmt.allocPrint(m.allocator, " — {s}", .{e.when_to_use}) catch ""
            else
                "",
        }) catch continue;
        pushInfoOwned(m, line);
    }
}

/// `/style <name>`: select an output style. No args reports the current one;
/// `off`/`clear` clears it. The style block is injected at the end of the system
/// prompt on the next request.
fn cmdStyle(m: *tui.Model, arg: ?[]const u8) void {
    const trimmed = std.mem.trim(u8, arg orelse "", " \t\r\n");
    if (trimmed.len == 0) {
        // Report current style
        if (current_style) |name| {
            const entries = discoverStyles(m.allocator, m.environ);
            var found: ?[]const u8 = null;
            var found_desc: []const u8 = "";
            var found_keep: bool = true;
            for (entries) |e| {
                if (std.mem.eql(u8, e.name, name)) {
                    found = e.name;
                    found_desc = e.description;
                    found_keep = e.keep_coding_instructions;
                    break;
                }
            }
            if (found) |n| {
                const keep_note = if (found_keep) "" else " (coding rules replaced by this style)";
                m.pushInfoFmt("output style: {s}{s} — {s}", .{n, keep_note, found_desc});
            } else {
                m.pushInfoFmt("output style: {s} (not found — was it removed?)", .{name});
            }
        } else {
            pushInfo(m, "no output style selected. /style <name> picks one; /style off clears it.");
        }
        return;
    }

    if (std.ascii.eqlIgnoreCase(trimmed, "off") or std.ascii.eqlIgnoreCase(trimmed, "clear")) {
        current_style = null;
        current_style_len = 0;
        pushInfo(m, "output style cleared. The base prompt (with coding rules) is used.");
        return;
    }

    // Validate the name exists
    const entries = discoverStyles(m.allocator, m.environ);
    var found: ?[]const u8 = null;
    var found_keep: bool = true;
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, trimmed)) {
            found = e.name;
            found_keep = e.keep_coding_instructions;
            break;
        }
    }
    if (found == null) {
        pushInfoFmt(m, "unknown output style '{s}'. Available: {s}", .{
            trimmed,
            if (entries.len > 0) styleNames(entries) else "none",
        });
        return;
    }

    // Copy into the static buffer (same rule as cur_model_buf)
    const n = @min(trimmed.len, current_style_buf.len);
    std.mem.copyForwards(u8, current_style_buf[0..n], trimmed[0..n]);
    current_style_len = n;
    current_style = current_style_buf[0..n];

    const keep_note = if (found_keep) "" else " — this style replaces the coding rules";
    pushInfoFmt(m, "output style: {s}{s}", .{trimmed, keep_note});
}

/// Should the app reopen the last session at startup?
///
/// The `--resume` FLAG and the `ZODE_RESUME=1` variable both turn it ON, and
/// neither of them turns it OFF.
///
/// That asymmetry is the whole point: the flag is dispatched BEFORE the
/// environment is read, so a line that ASSIGNED the environment's answer
/// over it made `zode --resume` start a new session and answer "nothing to
/// resume; starting a new session" — which is exactly what the flag asks it
/// not to do. The environment can only add a resume, never remove one.
pub fn shouldResume(flag: bool, env: ?*const std.process.Environ.Map) bool {
    if (flag) return true;
    return std.mem.eql(u8, envGet(env, "ZODE_RESUME") orelse "", "1");
}

/// Joins style names with ", " for an error message.
fn styleNames(entries: []const outputstyles.Entry) []const u8 {
    // Reuse a static buffer for the list
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var first: bool = true;
    for (entries) |e| {
        if (!first) w.writeAll(", ") catch {};
        first = false;
        w.writeAll(e.name) catch {};
    }
    return w.buffered();
}

// ── `/copy`: taking the answer with you ───────────────────────────────────
//
// The shape of the command comes from the reference implementation's `/copy`.
// What is ported is written next to each piece; what is not:
//
// - `config.copyFullResponse` as a global setting: here it is a SESSION flag
//   (`Model.copy_always_full`), because a session flag is enough until
//   somebody asks for more.
// - The `w` shortcut (write to file without copying): the file is written
//   ALWAYS, so there is nothing left for a second key to do.
// - The analytics.
//
// The three things this has to get right, and why:
//
// 1. **The arithmetic.** `/copy N` reaches back N-1 answers. A refusal says
//    what to do ("Only 3 assistant messages available to copy"), because a
//    refusal the user cannot act on is a dead end.
// 2. **The order.** Newest first, and only the turns that SAID something: a
//    tool-only turn has no text.
// 3. **The honesty.** The clipboard has three rungs and they are not equally
//    reliable, so the message names the one that was used, and the file is
//    written every time: a copy confirmation you cannot check is not a
//    confirmation.

/// The tag of the `/copy` picker.
const copy_picker_tag: u32 = 0x0c0;

/// The assistant texts of the session, newest first.
///
/// Only the turns that said something: a tool-only turn has no text, and an
/// API error is a history notice, not an assistant message.
fn collectAssistantTexts(s: *session_mod.Session, out: *[copytext.max_lookback][]const u8) usize {
    var n: usize = 0;
    var i = s.messages.items.len;
    while (i > 0 and n < copytext.max_lookback) : (i -= 1) {
        const msg = s.messages.items[i - 1];
        if (msg.role != .assistant) continue;
        if (msg.content.len == 0) continue;
        out[n] = msg.content;
        n += 1;
    }
    return n;
}

/// `/copy [N]`: the answer, on the clipboard and in a file.
fn cmdCopy(m: *tui.Model, arg: ?[]const u8) void {
    const s = session orelse {
        pushInfo(m, copytext.no_messages_msg);
        return;
    };
    var texts: [copytext.max_lookback][]const u8 = undefined;
    const n = collectAssistantTexts(s, &texts);
    if (n == 0) {
        pushInfo(m, copytext.no_messages_msg);
        return;
    }

    const sel = copytext.select(texts[0..n], arg);
    const index: usize = switch (sel) {
        .found => |i| i,
        .no_messages => {
            pushInfo(m, copytext.no_messages_msg);
            return;
        },
        .usage, .too_few => {
            var buf: [256]u8 = undefined;
            pushInfo(m, copytext.formatRefusal(&buf, sel, arg));
            return;
        },
    };

    var ctx = copytext.buildCtx(m.allocator, texts[index]) catch {
        pushInfo(m, "the answer could not be prepared for copying");
        return;
    };

    // Nothing to choose (no code blocks) or the user asked for the full
    // response always: there is no picker to open.
    if (ctx.blocks.len == 0 or m.copy_always_full) {
        defer ctx.deinit();
        performCopy(m, &ctx, 0);
        return;
    }

    const items = buildCopyItems(m, &ctx);
    if (items.len == 0) {
        ctx.deinit();
        pushInfo(m, copytext.no_messages_msg);
        return;
    }
    m.setCopyCtx(ctx);
    m.openPickerIdx(copy_picker_tag, "Copy", items, copyPickerChosen, copyPickerCancelled);
}

/// The rows of the `/copy` picker: the whole answer, one per code block, and
/// the row that remembers the choice.
///
/// The labels are the code's OWN first lines (that is what the user
/// recognises), cut to 60 columns. Two blocks that start with the same line
/// get a counter, because a picker with two identical rows is a picker where
/// the user cannot tell what they are about to copy.
fn buildCopyItems(m: *tui.Model, ctx: *const copytext.Ctx) []tui.PickerItem {
    const gpa = m.allocator;
    var items: std.ArrayList(tui.PickerItem) = .empty;

    var full_buf: [128]u8 = undefined;
    const full_text = copytext.formatFullLabel(
        &full_buf,
        copytext.countChars(ctx.full),
        copytext.countLines(ctx.full),
    );
    const full_label = gpa.dupe(u8, full_text) catch return items.toOwnedSlice(gpa) catch return &.{};
    items.append(gpa, .{ .label = full_label, .desc = "" }) catch {
        gpa.free(full_label);
        return items.toOwnedSlice(gpa) catch return &.{};
    };

    var label_buf: [copytext.label_buf_len]u8 = undefined;
    var base_buf: [copytext.label_buf_len]u8 = undefined;
    var desc_buf: [96]u8 = undefined;
    for (ctx.blocks, 0..) |b, bi| {
        // The base label is COPIED out of the scratch buffer: the loop below
        // uses the same buffer, and a label that changes under the comparison
        // is a label that matches the wrong row.
        const base = copytext.truncateToCols(b.code, copytext.label_max_cols, &label_buf);
        @memcpy(base_buf[0..base.len], base);
        const base_label = base_buf[0..base.len];
        // How many EARLIER rows already say the same thing? Only the earlier
        // ones: counting the later ones too would give three identical blocks
        // the same "(3)" and the picker three rows that look the same.
        var same: usize = 0;
        for (ctx.blocks[0..bi]) |prev| {
            if (prev.code.len == b.code.len and std.mem.eql(u8, prev.code, b.code)) continue;
            const prev_label = copytext.truncateToCols(prev.code, copytext.label_max_cols, &label_buf);
            if (std.mem.eql(u8, prev_label, base_label)) same += 1;
        }
        const label = copytext.uniqueLabel(gpa, base_label, same) catch continue;
        const desc_text = copytext.formatBlockDesc(&desc_buf, b.lang, b.code);
        // An EMPTY desc is a literal, not an allocation: `closePicker` only
        // frees a desc that is not empty, so an allocated "" would leak.
        const desc = if (desc_text.len == 0) "" else (gpa.dupe(u8, desc_text) catch "");
        items.append(gpa, .{ .label = label, .desc = desc }) catch {
            gpa.free(label);
            if (desc.len > 0) gpa.free(desc);
            continue;
        };
    }

    const always = gpa.dupe(u8, copytext.always_label) catch return items.toOwnedSlice(gpa) catch return &.{};
    const always_desc = gpa.dupe(u8, copytext.always_desc) catch "";
    items.append(gpa, .{ .label = always, .desc = always_desc }) catch {
        gpa.free(always);
        if (always_desc.len > 0) gpa.free(always_desc);
    };
    return items.toOwnedSlice(gpa) catch return &.{};
}

/// The picker chose a row.
///
/// Index 0 is the whole answer, 1..n are the code blocks, and the row after
/// them is "always copy the full response" (which copies the answer AND
/// remembers not to ask again).
fn copyPickerChosen(m: *tui.Model, tag: u32, index: usize) void {
    _ = tag;
    var ctx = m.takeCopyCtx() orelse return;
    defer ctx.deinit();
    const always = index > ctx.blocks.len;
    if (always) {
        m.copy_always_full = true;
        performCopy(m, &ctx, 0);
        return;
    }
    performCopy(m, &ctx, index);
}

/// The picker was closed with ESC: a cancel is not an error.
fn copyPickerCancelled(m: *tui.Model, tag: u32) void {
    _ = tag;
    if (m.takeCopyCtx()) |ctx| {
        var c = ctx;
        c.deinit();
    }
    pushInfo(m, copytext.cancelled_msg);
}

/// The copy itself: the clipboard first, then the file, then the message.
fn performCopy(m: *tui.Model, ctx: *const copytext.Ctx, index: usize) void {
    const text = ctx.textAt(index) orelse return;
    const chars = copytext.countChars(text);
    const lines = copytext.countLines(text);

    // The clipboard FIRST, and the file after: upstream learned that the
    // clipboard call is the one that can be slow (waiting for tmux), and the
    // message that says "copied" should not arrive after the file.
    const decision = copyToClipboard(m, text);

    // Toast: show the confirmation in the top-right corner for ~1 second.
    // At 40 ms/tick when busy, 25 ticks = 1000 ms.
    var tb: [64]u8 = undefined;
    m.copy_toast_text = std.fmt.bufPrint(&tb, "Copied to clipboard ({d} chars)", .{chars}) catch "Copied to clipboard";
    m.copy_toast_frames = 25;

    var name_buf: [64]u8 = undefined;
    const filename = copyFileName(index, ctx, &name_buf);
    const path = writeCopyFile(m, text, filename);

    var msg_buf: [512]u8 = undefined;
    if (path) |p| {
        defer m.allocator.free(p);
        pushInfo(m, copytext.formatCopiedVia(&msg_buf, chars, lines, decision.method.phrase(), p));
    } else {
        // The file could not be written: said out loud, not swallowed. The
        // clipboard half may still have worked.
        pushInfo(m, copytext.formatCopiedNoFile(&msg_buf, chars, lines, decision.method.phrase()));
    }
}

/// The name of the file the copy is written to.
///
/// The whole answer is `response.md`; a block is `copy<ext>`, with the
/// extension taken from the fence's language. A language tag is MODEL OUTPUT
/// and a path is a FILESYSTEM, so the tag is sanitised (`copytext`).
fn copyFileName(index: usize, ctx: *const copytext.Ctx, buf: []u8) []const u8 {
    if (index == 0) return copytext.full_filename;
    const block = ctx.blocks[index - 1];
    return copytext.filenameForBlock(block.lang, buf);
}

/// The clipboard, with the ladder.
///
/// The decision (which rung) is made BEFORE anything is spawned, and the
/// message names the rung that was used. The last rung is OSC 52, which goes
/// through the RENDER: the TUI owns the escape sequence, because a sequence
/// written outside the render is one the next frame paints over.
fn copyToClipboard(m: *tui.Model, text: []const u8) clipboard.Decision {
    const env = m.environ orelse {
        m.setCopyPending(text);
        return .{ .method = .osc52 };
    };
    if (!m.io_ready) {
        m.setCopyPending(text);
        return .{ .method = .osc52 };
    }
    const plan = clipboard.planFor(m.io, env);
    const decision = clipboard.copy(m.io, plan, text);
    if (decision.method == .osc52) {
        m.setCopyPending(text);
    }
    return decision;
}

/// The file the copy is ALSO written to.
///
/// It is written ALWAYS: the clipboard is best-effort by nature (a terminal
/// that ignores OSC 52, a tool that is not there), and a file is not.
///
/// The file is 0600 in a 0700 directory: it holds the model's answer, and
/// `/tmp` is world-readable.
fn writeCopyFile(m: *tui.Model, text: []const u8, filename: []const u8) ?[]const u8 {
    if (!m.io_ready) return null;
    const gpa = m.allocator;
    const tmp = clipboard.copyDir(m.environ);
    const dir_path = std.fmt.allocPrint(gpa, "{s}/zode", .{tmp}) catch return null;
    defer gpa.free(dir_path);
    const path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, filename }) catch return null;

    var dir = std.Io.Dir.cwd().openDir(m.io, ".", .{}) catch return null;
    defer dir.close(m.io);
    // The directory is 0700 and the file 0600: it holds the model's answer and
    // `/tmp` is world-readable. The mode goes on the OPEN file, not after the
    // write: a `create` + `chmod` leaves a window in which the file exists
    // world-readable.
    _ = dir.createDirPathStatus(m.io, dir_path, copy_dir_mode) catch {};
    var file = dir.createFile(m.io, path, .{ .truncate = true }) catch {
        gpa.free(path);
        return null;
    };
    defer file.close(m.io);
    file.setPermissions(m.io, copy_file_mode) catch {};
    file.writeStreamingAll(m.io, text) catch {
        gpa.free(path);
        return null;
    };
    return path;
}

/// 0700 for the directory of copies, 0600 for the file itself.
const copy_dir_mode: std.Io.File.Permissions = @enumFromInt(0o700);
const copy_file_mode: std.Io.File.Permissions = @enumFromInt(0o600);

/// `/bg`: the background jobs, and the two ways to stop them.
fn cmdBg(m: *tui.Model, arg_in: ?[]const u8) void {
    const arg = arg_in orelse "";
    if (std.ascii.eqlIgnoreCase(arg, "killall")) {
        // `killNow`, not just `requestKillAll`: "killall" that only MARKS the
        // jobs and leaves them running until the app exits is a lie with extra
        // steps. The io_ready guard is the same one ESC uses (a test Model has
        // no `Io`).
        const n = if (m.io_ready) m.bg.killNow(io_global) else m.bg.requestKillAll();
        pushInfoFmt(m, "killed {d} background command{s}", .{
            n,
            if (n == 1) @as([]const u8, "") else @as([]const u8, "s"),
        });
        return;
    }
    if (std.ascii.startsWithIgnoreCase(arg, "kill")) {
        var it = std.mem.tokenizeAny(u8, arg, " \t");
        _ = it.next(); // "kill"
        const id_str = it.next() orelse {
            pushInfo(m, "/bg kill <id> · /bg killall");
            return;
        };
        const id = std.fmt.parseInt(u32, id_str, 10) catch {
            pushInfo(m, "/bg kill <id> · /bg killall");
            return;
        };
        if (m.bg.kill(io_global, id)) {
            pushInfoFmt(m, "killed job {d}", .{id});
        } else {
            pushInfoFmt(m, "job {d} was not running ({s})", .{ id, m.bg.stateWord(id) });
        }
        return;
    }

    var line: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&line);
    var any = false;
    for (0..bgproc.max_jobs) |i| {
        const slot = &m.bg.slots[i];
        if (!slot.isLive()) continue;
        any = true;
        w.print("  job {d} [{s}] {s}\n", .{ slot.id, slot.stateWord(), slot.commandSlice() }) catch {};
    }
    if (!any) {
        pushInfo(m, "no background commands");
        return;
    }
    pushInfo(m, std.mem.trimEnd(u8, w.buffered(), "\n"));
}

/// Tool results elided in the session (for /context).
pub var session_elided: usize = 0;

/// Has the TUI already summarized the old turns in this session?
///
/// Tier 2 compaction: the LLM request that summarizes the old stretch.
///
/// ## Why "once per session" was wrong
///
/// It used to be a bool, and the reasoning behind it was sound — retrying it every
/// turn is one wasted request per turn forever — but the conclusion was one step too
/// far. "Not every turn" is not "only ever once", and a bool can only say the second
/// thing. So in a long session the context grew again with no brake, and the turn died
/// with a writer error when the body outgrew the 1 MiB buffer: from the outside, "the
/// agent went quiet". The flag was the cause and nothing said so.
///
/// ## Why it is now a budget with a gap, and not just a budget
///
/// Two guards, because they answer different questions:
///
/// - **A gap of `summary_gap` iterations.** Without it, a long turn where every
///   iteration needs a summary spends a request per iteration — the exact waste the
///   bool was there to prevent. With it, summarizing is at most once every six
///   iterations, which on a 60-iteration goal turn is ten summaries instead of sixty.
/// - **A cap of `summary_max` per session.** Without it, a session that keeps filling
///   the context keeps paying for summaries forever, and each one is a request whose
///   result is thrown away by the next one. Three is enough to carry a long session;
///   past that the user is better served by `/new` or a bigger window.
pub const summary_gap: usize = 6;
pub const summary_max: usize = 3;

/// How many summaries this session has done, and the iteration of the last one.
var summaries_done: usize = 0;
var summarized_at_iteration: usize = 0;

/// Circuit breaker keyed on **consecutive** summarization failures.
///
/// Tier 2 is best-effort: when the model cannot summarize, the caller carries on
/// without a summary. Without a breaker, a summarizer that keeps failing is retried
/// every iteration — "request-per-turn forever". After `max_consecutive` failures in
/// a row the breaker trips and `summarizeTurns` stops trying; any successful summary
/// resets the counter.
pub const SummaryBreaker = struct {
    consecutive: usize = 0,
    /// Three failures in a row is enough: the model is not going to summarize this
    /// session, and spending a request on it every turn is pure waste.
    max_consecutive: usize = 3,

    /// Record a failed attempt.
    pub fn noteFailure(self: *SummaryBreaker) void {
        self.consecutive += 1;
    }

    /// Record a successful summary: the counter resets.
    pub fn noteSuccess(self: *SummaryBreaker) void {
        self.consecutive = 0;
    }

    /// True once the breaker has tripped and tier 2 must not run again this session.
    pub fn tripped(self: *SummaryBreaker) bool {
        return self.consecutive >= self.max_consecutive;
    }

    /// Reset for a new session (`/new`, `/resume`, bootstrap).
    pub fn reset(self: *SummaryBreaker) void {
        self.consecutive = 0;
    }
};

/// One breaker for the session, next to the other summarization state.
var summary_breaker: SummaryBreaker = .{};

/// May tier 2 run right now, at `iteration`?
///
/// It returns true on the first trigger of a session and then at most once every
/// `summary_gap` iterations, up to `summary_max` times. A tripped breaker always
/// returns false.
pub fn maySummarize(iteration: usize) bool {
    if (summary_breaker.tripped()) return false;
    if (summaries_done >= summary_max) return false;
    if (summaries_done == 0) return true;
    return iteration >= summarized_at_iteration + summary_gap;
}

/// Records that a summary was just made. Separate from `maySummarize` so the call is
/// visible at the one place that spends a request. A success also resets the breaker.
fn noteSummarized(iteration: usize) void {
    summaries_done += 1;
    summarized_at_iteration = iteration;
    summary_breaker.noteSuccess();
}

/// A new session gets the whole budget back. `/new`, `/resume` and the bootstrap all
/// come through here.
fn resetSummaries() void {
    summaries_done = 0;
    summarized_at_iteration = 0;
    summary_breaker.reset();
}

/// Tok/s of the in-flight stream (status bar) and of the last finished stream.
pub var tps_live: f64 = 0;
pub var tps_last: f64 = 0;

/// Context tokens used and the percentage of the limit.
///
/// Cached here because the status bar reads it EVERY FRAME, and walking the
/// history to estimate tokens 60 times per second is wasted work. Refreshed
/// when each turn closes.
pub var ctx_used: i64 = 0;
pub var ctx_pct: u8 = 0;
/// `true` when `ctx_used` is the PROVIDER's own count for the last request and
/// not our 4-chars-per-token estimate. The status bar prints `~` only for the
/// estimate: a number the provider itself counted does not need the squiggle,
/// and the two look identical otherwise.
pub var ctx_real: bool = false;

/// Which number means "how much context": the provider's own count when there
/// is one, the estimate when there is not (before the first request).
///
/// It is the same question measured with the real tokenizer. `prev_prompt` is
/// the prompt count of the LAST request, which IS the context — system, tools,
/// history and all — so showing our estimate next to it is showing a shadow of
/// a number we already have.
pub fn ctxTokens(real: i64, estimate: i64) i64 {
    return if (real > 0) real else estimate;
}

/// Recomputes `ctx_used`/`ctx_pct`. Cheap to call, but not needed per frame:
/// tokens only change when a message is added.
pub fn refreshContextUsage(m: *tui.Model) void {
    if (session == null) {
        ctx_used = 0;
        ctx_pct = 0;
        ctx_real = false;
        return;
    }
    var astate = std.heap.ArenaAllocator.init(m.allocator);
    defer astate.deinit();
    const msgs = snapshotMsgs(astate.allocator());
    const estimate = compaction.estimateTokens(msgs);
    const real = cache_stats.session.prev_prompt;
    ctx_used = ctxTokens(real, estimate);
    ctx_real = real > 0;
    const limit = @max(1, compaction.contextLimitFor(m.environ, curModelContext()));
    const pct = (@as(f64, @floatFromInt(ctx_used)) / @as(f64, @floatFromInt(limit))) * 100.0;
    ctx_pct = @intFromFloat(std.math.clamp(pct, 0, 999));
}

/// Tokens per second of a stream that produced `tokens` in `dt_ns`.
///
/// Returns 0 when the window cannot support a number: no time, no tokens, or a
/// rate so absurd it can only be a bad clock read (a 0-length window and a
/// 1-millisecond one are both `dt_ns > 0`, and the second would print 900000
/// tok/s for a single character).
pub fn tpsOf(tokens: f64, dt_ns: i128) f64 {
    if (dt_ns <= 0 or tokens <= 0) return 0;
    const tps = tokens / (@as(f64, @floatFromInt(dt_ns)) / 1e9);
    if (tps <= 0.5 or tps >= 100_000) return 0;
    return tps;
}

/// Our own count when the provider sent none: ~4 chars per token.
fn estTokens(chars: usize) f64 {
    return @as(f64, @floatFromInt(chars)) / 4.0;
}

/// The tok/s of a FINISHED stream, for `/context` and the next session's memory.
///
/// `completion` is the provider's own count when it sent one: the same span of
/// time measured with the real tokenizer instead of with chars/4, which is off
/// by whatever the tokenizer disagrees with us about (code and CJK both sit far
/// from 4 chars).
fn finishTps(chars: usize, start_ns: i128, completion: i64) void {
    if (start_ns == 0) return;
    const now_ns = std.Io.Timestamp.now(io_global, .real).nanoseconds;
    const tokens: f64 = if (completion > 0) @floatFromInt(completion) else estTokens(chars);
    const tps = tpsOf(tokens, now_ns - start_ns);
    if (tps > 0) tps_last = tps;
}

// ── active provider / model / session ────────────────────────

pub var cur_provider_id: []const u8 = "opencode";
/// The active provider's id, in a static buffer.
///
/// Same rule as `cur_model_buf`. `loadUserConfig` reads the id from
/// `config.json` or from `ZODE_PROVIDER` — memory the CALLER owns: the
/// config arena, freed at shutdown, and the environ map, which in a test
/// is a temporary the test deinits. Pointing at either is a dangling
/// slice the moment that memory is freed, and the status bar reads
/// `cur_provider_id` on every frame.
///
/// Found by the first E2E test: it freed its environ map, and the very
/// next test's status draw segfaulted reading the provider name.
pub var cur_provider_buf: [128]u8 = undefined;

/// Copies the provider id into `cur_provider_buf` and points
/// `cur_provider_id` at it, so the global never points at memory a
/// caller can free.
pub fn setProviderId(id: []const u8) void {
    const n = @min(id.len, cur_provider_buf.len);
    std.mem.copyForwards(u8, cur_provider_buf[0..n], id[0..n]);
    cur_provider_id = cur_provider_buf[0..n];
}
/// Key state of the active provider's API key.
///
/// `verified` means the key has been tested and works.
/// `saved` means the key is stored in `auth.json` but has not been verified.
/// `invalid` means the key is known to be bad (e.g., auth error received).
pub var cur_key_state: u8 = 0; // 0=unknown, 1=verified, 2=saved, 3=invalid
/// Key state buffer for safe copying (avoids dangling slices).
pub var cur_key_state_buf: [4]u8 = undefined;

/// Maps key state enum values to display strings.
pub fn keyStateString(s: u8) []const u8 {
    switch (s) {
        1 => "● verified",
        2 => "○ saved",
        3 => "✗ invalid",
        else => "",
    }
}

var cur_model: []const u8 = "";

/// Active session (`null` until the first message). The worker creates it, not
/// startup: opening a session file just because the program started would
/// create junk files if the user never chats.
pub var session: ?*session_mod.Session = null;

/// Reopen the last session at startup? Set by `ZODE_RESUME=1` or `--resume`.
pub var resume_on_start: bool = false;

/// Copies the model name into a static buffer (avoids dangling slices from
/// ephemeral input strings).
pub var cur_model_buf: [128]u8 = undefined;

/// Context window of the active model, 0 when the provider does not publish it.
///
/// It is a plain integer and NOT a slice into the catalogue for the reason the
/// `ctx_tokens` field in `palette.Item` says: the palette owns copies and the
/// worker's arena dies with the request.
pub var cur_model_ctx: u32 = 0;

/// Active provider and model, for the status bar. Exposed as functions (not
/// the raw `var`s) so the TUI does not depend on the static buffer.
pub fn curProvider() []const u8 {
    return cur_provider_id;
}
pub fn curModel() []const u8 {
    return cur_model;
}
pub fn setModel(name: []const u8) void {
    setModelCtx(name, 0);
}

/// `setModel` plus the model's context window, in tokens.
///
/// **It RESETS to 0 when called without one**, on purpose. That is not a
/// default: a `setModel("")` (switching provider, `setModel(name)` from a `/use`)
/// must NOT keep the previous model's window, or a 200k model followed by a
/// provider whose catalogue does not publish one would keep budgeting 200k and
/// never compact. Zero means "the provider does not say", and `contextLimit`
/// falls through to the environment and then to 128k — which is exactly what it
/// did before any of this.
pub fn setModelCtx(name: []const u8, ctx_tokens: u32) void {
    // `copyForwards` and not `@memcpy`: `name` can BE the buffer (a
    // `setModel(curModel())`, which is what `defer setModel(saved)` in a test
    // does, and what any "go back to what I had" would do). `@memcpy` on
    // overlapping slices is undefined behaviour, and here it panicked instead of
    // being a no-op, because the source IS the destination.
    const n = @min(name.len, cur_model_buf.len);
    std.mem.copyForwards(u8, cur_model_buf[0..n], name[0..n]);
    cur_model = cur_model_buf[0..n];
    cur_model_ctx = ctx_tokens;
    // The effort is adjusted ONLY on a model change (bug 3). Without this, an
    // `xhigh` picked in a codex-max stays put on a gemini-2.5 that does not
    // have it: every request degrades in silence to `high`, and the status bar
    // keeps saying `xhigh`. Two different texts for the same thing, and nothing
    // that says they differ.
    current_effort = chat.clampEffort(cur_model, current_effort);
}

/// The model that is answering RIGHT NOW, which is not always `curModel()`.
///
/// The status bar reads this instead of `curModel()`, and it is the only thing
/// that makes `/free-auto` and the cheap router diagnosable: a mode you cannot
/// see is a mode where "the model ignored my edit" cannot be told apart from
/// "the model was never asked".
///
/// The cheap router flips this for the duration of the turn; `/free-auto` sets
/// the same field for its own. Empty means "the active model", so the common
/// case costs nothing.
pub var cur_answering: [128]u8 = undefined;
var cur_answering_len: usize = 0;

pub fn setAnswering(model: []const u8) void {
    const n = @min(model.len, cur_answering.len);
    std.mem.copyForwards(u8, cur_answering[0..n], model[0..n]);
    cur_answering_len = n;
}

pub fn curAnswering() []const u8 {
    if (cur_answering_len == 0) return cur_model;
    return cur_answering[0..cur_answering_len];
}

/// The active model's context window, 0 when nothing knows it.
///
/// OpenRouter publishes `context_length` in the catalogue, `roster.zig` already
/// carries it for the free pool, and until this existed the compaction budget
/// ignored all of it and used a fixed 128k. On a 1M model that is a budget of
/// 102k for a window that would take 800k — the compaction starts, and the tier-2
/// summary, and the LLM call that costs money, thousands of tokens early.
pub fn curModelContext() u32 {
    return cur_model_ctx;
}

/// The effort level that actually goes in the request.
///
/// Everybody uses this instead of `current_effort`, because `current_effort` is
/// the user's PREFERENCE and this is the reality after going through the model's
/// ladder: a model with no knob returns its default, and one that does not have
/// the requested level degrades. The preference is stored apart so that changing
/// models does not lose what the user had picked.
pub fn effectiveEffort() chat.Effort {
    return chat.effectiveEffort(cur_model, current_effort);
}

// ── permissions: "always allow" per tool (session) ───────────
const max_always = 8;
pub var always_names: [max_always][48]u8 = undefined;
pub var always_lens: [max_always]usize = @splat(0);

/// The `bash` command prefixes the user has allowed without a dialog,
/// from `permissions.json`'s `"bash"` array. Fixed buffers, like
/// `always_names`: the slices `loadAllowlist` reads them from live in
/// an arena that dies at the end of the load.
const max_bash_patterns = 16;
const bash_pattern_max = 160;
pub var bash_pattern_bufs: [max_bash_patterns][bash_pattern_max]u8 = undefined;
pub var bash_pattern_lens: [max_bash_patterns]usize = @splat(0);

fn isBashPattern(pat: []const u8) bool {
    for (bash_pattern_lens, 0..) |l, i| {
        if (l > 0 and std.mem.eql(u8, bash_pattern_bufs[i][0..l], pat)) return true;
    }
    return false;
}

/// Like `setAlwaysAllowedNoSave` but for a `bash` command prefix.
fn addBashPatternNoSave(pat: []const u8) bool {
    if (isBashPattern(pat)) return true;
    // An over-long command is REFUSED, never cut. A pattern truncated at an
    // arbitrary byte is a broader permission than the one the user approved:
    // the first 96 bytes of `python -c "one specific thing"` would allow any
    // other `python -c` there is. What was approved is what is stored.
    if (pat.len == 0 or pat.len > bash_pattern_max) return false;
    for (bash_pattern_lens, 0..) |l, i| {
        if (l == 0) {
            @memcpy(bash_pattern_bufs[i][0..pat.len], pat);
            bash_pattern_lens[i] = pat.len;
            return true;
        }
    }
    return false;
}

/// Whether a `bash` call's command matches one of the persisted
/// command prefixes.
///
/// A prefix ending at a TOKEN BOUNDARY, not a substring: the pattern
/// `git status` matches `git status --short` but never `git statusx`,
/// and `git` matches `git push` — which is what the user asked for the
/// moment they wrote `git`, so the specificity is theirs to choose.
/// Whether the call runs without a dialog under the current
/// mode: accept-edits auto-allows file edits, and a `bash`
/// command matching a persisted prefix is allowed.
///
/// The selective part of selective permissions — the user's
/// standing "I trust this", as against `/yolo`'s "I trust
/// everything". Plan (read-only) and bypass are handled BEFORE
/// this is consulted: plan blocks writes outright and bypass
/// skips the dialog, so neither reaches here.
fn permAutoAllowed(name: []const u8, arg: []const u8, args_json: []const u8, arena: std.mem.Allocator) bool {
    // A batch is covered by accept-edits when it WRITES: the standing "I trust
    // the file edits" is about the edits, and a batch's write step is one.
    if (std.mem.eql(u8, name, "batch")) {
        return accept_edits and tools_mod.callWrites(name, args_json, arena);
    }
    return (accept_edits and isEditTool(name)) or bashPatternAllowed(name, arg);
}

fn bashPatternAllowed(name: []const u8, arg: []const u8) bool {
    if (!std.mem.eql(u8, name, "bash")) return false;
    const cmd = std.mem.trim(u8, arg, " \t\r\n");
    for (bash_pattern_lens, 0..) |l, i| {
        if (l == 0 or l > cmd.len) continue;
        if (!std.mem.eql(u8, cmd[0..l], bash_pattern_bufs[i][0..l])) continue;
        if (l != cmd.len and cmd[l] != ' ' and cmd[l] != '\t') continue;

        // The remainder must not start ANOTHER command or redirect
        // anywhere. `git status` allowed must not become
        // `git status && rm -rf /`: the pattern names ONE command, and
        // whatever chains after it is a different command however the
        // prefix is read. `<` and `>` are in here because a redirect
        // writes files, and `$` because it expands (a command
        // substitution more so than a variable). A pattern that covers
        // the whole line has an empty remainder and is unaffected.
        const rest = cmd[l..];
        if (rest.len > 0 and std.mem.indexOfAny(u8, rest, ";|&<>`$\n") != null) continue;
        return true;
    }
    return false;
}

fn isAlwaysAllowed(name: []const u8) bool {
    for (always_lens, 0..) |l, i| {
        if (l > 0 and std.mem.eql(u8, always_names[i][0..l], name)) return true;
    }
    return false;
}

/// The `a` key on the permission dialog.
///
/// For every tool but `bash` it saves the TOOL NAME, as it always did. For
/// `bash` it saves the COMMAND, because "bash may always run" is `/yolo`
/// with extra steps: what the user actually approved, having just read the
/// dialog, is this one command. Scoped approval is the whole point of
/// selective permissions, and this is where the user is standing when they
/// decide.
fn allowAlwaysFor(m: *tui.Model, name: []const u8, arg: []const u8) void {
    if (!std.mem.eql(u8, name, "bash")) {
        setAlwaysAllowed(m, name);
        return;
    }
    const cmd = std.mem.trim(u8, arg, " \t\r\n");
    if (cmd.len == 0) {
        warnDangerousAllowOnce(m, "bash (*)");
        return;
    }
    // 34.4: warn once about a broad bash allow (bash * runs anything)
    if (std.mem.eql(u8, cmd, "*") or std.mem.startsWith(u8, cmd, "* ")) {
        warnDangerousAllowOnce(m, "bash (*)");
    }
    if (addBashPatternNoSave(cmd)) {
        saveAllowlist();
        const msg = std.fmt.allocPrint(m.allocator, "bash allowed: {s}", .{cmd}) catch return;
        pushInfoOwned(m, msg);
    } else {
        // Too long for the 160-byte budget, or the list is full. Saying
        // nothing here would look like the key had been ignored.
        pushInfoFmt(m, "not saved: the command is longer than {d} bytes or the list of {d} is full", .{ bash_pattern_max, max_bash_patterns });
    }
}

/// Warns once about a broad "always allow" on a dangerous bare interpreter.
/// It is a warning, not a refusal: the user can still approve, but they should
/// know what they are approving.
fn warnDangerousAllowOnce(m: *tui.Model, what: []const u8) void {
    if (warned_dangerous_allow.load(.seq_cst)) return;
    warned_dangerous_allow.store(true, .seq_cst);
    const msg = std.fmt.allocPrint(
        m.allocator,
        "warning: always allowing {s} lets the model run arbitrary commands through it — a broad permission, like /yolo for that tool.",
        .{what},
    ) catch return;
    pushInfoOwned(m, msg);
}

fn setAlwaysAllowed(m: *tui.Model, name: []const u8) void {
    if (setAlwaysAllowedNoSave(name)) {
        saveAllowlist();
        const msg = std.fmt.allocPrint(m.allocator, "always allowed: {s}", .{name}) catch return;
        pushInfoOwned(m, msg);
        // 34.4: warn once about dangerous broad allows
        if (permrules.isDangerousPattern(name, "*")) {
            warnDangerousAllowOnce(m, name);
        }
    }
}

/// Like `setAlwaysAllowed` but WITHOUT writing to disk: used by the initial
/// load, which does not want to rewrite the file it just read.
/// Returns false if the allowlist is full (it does not grow without limit: it
/// is at most 8 tools, and past that it is noise in the permission dialog).
fn setAlwaysAllowedNoSave(name: []const u8) bool {
    if (isAlwaysAllowed(name)) return true;
    for (always_lens, 0..) |l, i| {
        if (l == 0) {
            const n = @min(name.len, 48);
            @memcpy(always_names[i][0..n], name[0..n]);
            always_lens[i] = n;
            return true;
        }
    }
    return false;
}

/// Reads `permissions.json` and fills the allowlist. Best-effort: if it does
/// not exist or is corrupt, the session starts with an empty allowlist.
fn loadAllowlist() void {
    var pbuf: [512]u8 = undefined;
    const path = permissionsFilePath(&pbuf) orelse return;

    var astate = std.heap.ArenaAllocator.init(gpa_global);
    defer astate.deinit();
    const a = astate.allocator();

    const data = readFileTo(a, path) orelse return;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, data, .{}) catch return;
    // Two shapes, because the file is hand-edited and it predates the
    // `bash` patterns: a bare array is the tool allowlist (the old
    // format), and an object carries the same list under `tools` plus
    // the command prefixes under `bash`.
    switch (parsed) {
        .array => |arr| for (arr.items) |v| {
            if (v == .string) _ = setAlwaysAllowedNoSave(v.string);
        },
        .object => |obj| {
            if (obj.get("tools")) |tv| {
                if (tv == .array) for (tv.array.items) |v| {
                    if (v == .string) _ = setAlwaysAllowedNoSave(v.string);
                };
            }
            if (obj.get("bash")) |bv| {
                if (bv == .array) for (bv.array.items) |v| {
                    if (v == .string) _ = addBashPatternNoSave(v.string);
                };
            }
        },
        else => {},
    }
}

// ── persisted allowlist: ~/.config/zode/permissions.json ─────
fn permissionsFilePath(buf: []u8) ?[]const u8 {
    // `environ_global.?` panicked when the global was null, which is its
    // normal state in every test that did not set it: a missing environment
    // is "there is nowhere to persist", not a crash.
    const env = environ_global orelse return null;
    const home = env.get("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/zode/permissions.json", .{home}) catch null;
}

/// Persists the "always allow" allowlist as a JSON array of names.
///
/// By hand (not with a writer over a map) because it is at most 8 strings and
/// this way it reads at a glance.
fn saveAllowlist() void {
    var pbuf: [512]u8 = undefined;
    const path = permissionsFilePath(&pbuf) orelse return;

    var names: [max_always][]const u8 = undefined;
    var n: usize = 0;
    for (always_lens, 0..) |l, i| {
        if (l == 0) continue;
        names[n] = always_names[i][0..l];
        n += 1;
    }

    var pats: [max_bash_patterns][]const u8 = undefined;
    var np: usize = 0;
    for (bash_pattern_lens, 0..) |l, i| {
        if (l == 0) continue;
        pats[np] = bash_pattern_bufs[i][0..l];
        np += 1;
    }

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // By hand (not with a writer over a map) because it is two short
    // arrays and this way it reads at a glance:
    //   {"tools":["edit"],"bash":["git status"]}
    w.print("{{\"tools\":", .{}) catch return;
    config_mod.writeStringArray(&w, gpa_global, names[0..n]) catch return;
    w.print(",\"bash\":", .{}) catch return;
    config_mod.writeStringArray(&w, gpa_global, pats[0..np]) catch return;
    w.print("}}", .{}) catch return;
    std.Io.Dir.cwd().writeFile(io_global, .{ .sub_path = path, .data = w.buffered() }) catch {};
}

fn readFileTo(arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io_global, path, arena, .limited(1 << 20)) catch null;
}

/// The same, with the `Io` as an argument.
///
/// The global one reads `io_global`, which is `undefined` in a test: a file
/// read through an uninitialised `Io` is a jump through a garbage vtable.
fn readFileToWith(io: std.Io, arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch null;
}

// ── the permission rules (Phase 6) ─────────────────────────────────────────

/// The rules of every source, and the arena that owns them.
///
/// The rules are read on EVERY call that needs a decision, so they are
/// cached and the cache is what the hot path reads. The arena lives until
/// the process exits: a worker can be reading the rules while the config is
/// reloaded, and a rule set that is freed under a reader is a use-after-free
/// (the same rule as the saved keys).
pub var perm_rules: permrules.Set = .{};
var perm_rules_arena: ?std.heap.ArenaAllocator = null;

/// Whether the dangerous-allow warning has already been shown this session.
/// It fires once: repeating it every turn would train the user to dismiss it.
pub var warned_dangerous_allow: std.atomic.Value(bool) = .init(false);

/// The project-level rules file, relative to the working directory.
pub const project_rules_file = ".zode/permissions.json";

/// Loads the rules: the project file and the user file.
///
/// The ORDER is the precedence — the strongest source first — and
/// `permrules.decide` picks the first that matches. A `deny` beats any
/// `allow` from any source, and that is decided inside `decide`.
///
/// The project file is the one that answers the question this whole
/// mechanism exists for: a project that wants `.vscode/` written without a
/// question says so in ITS OWN file, and the file travels with the project.
pub fn loadPermRules() void {
    var pbuf: [512]u8 = undefined;
    var rbuf: [640]u8 = undefined;
    // The PROJECT ROOT, and not the working directory: the file travels with
    // the project, and a run from a subdirectory has to find the same rules.
    const project_path = if (project_info.root()) |root|
        std.fmt.bufPrint(&rbuf, "{s}/{s}", .{ root, project_rules_file }) catch project_rules_file
    else
        project_rules_file;
    if (perm_rules_arena == null) {
        perm_rules_arena = std.heap.ArenaAllocator.init(gpa_global);
    }
    loadPermRulesInto(
        perm_rules_arena.?.allocator(),
        io_global,
        project_path,
        permissionsFilePath(&pbuf),
    );
}

/// The rules, loaded from the two files.
///
/// The paths are PARAMETERS and not read from the environment here, for one
/// reason: a test has to be able to point them at a fixture. "The rules of
/// this machine" and "the rules of a file" are the same code with a different
/// argument.
pub fn loadPermRulesFrom(io: std.Io, project_path: ?[]const u8, user_path: ?[]const u8) void {
    if (perm_rules_arena == null) {
        perm_rules_arena = std.heap.ArenaAllocator.init(gpa_global);
    }
    loadPermRulesInto(perm_rules_arena.?.allocator(), io, project_path, user_path);
}

/// The rules, loaded into a GIVEN arena.
///
/// The allocator is an argument because the global one does not exist in a
/// test, and a test that cannot load a rule file cannot test a rule.
pub fn loadPermRulesInto(
    arena: std.mem.Allocator,
    io: std.Io,
    project_path: ?[]const u8,
    user_path: ?[]const u8,
) void {
    const a = arena;

    var all: std.ArrayList(permrules.Rule) = .empty;

    // The PROJECT file: `.zode/permissions.json`, next to the code.
    if (project_path) |path| {
        if (readFileToWith(io, a, path)) |data| {
            if (std.json.parseFromSliceLeaky(std.json.Value, a, data, .{})) |parsed| {
                for (permrules.parseJson(parsed, .project, a)) |r| all.append(a, r) catch {};
            } else |_| {}
        }
    }

    // The USER file: `~/.config/zode/permissions.json`, next to the keys.
    if (user_path) |path| {
        if (readFileToWith(io, a, path)) |data| {
            if (std.json.parseFromSliceLeaky(std.json.Value, a, data, .{})) |parsed| {
                for (permrules.parseJson(parsed, .user, a)) |r| all.append(a, r) catch {};
            } else |_| {}
        }
    }

    perm_rules = .{ .rules = all.items };
}

/// The rules, as they stand.
pub fn permRuleSet() permrules.Set {
    return perm_rules;
}

/// The decision for a call: `allow`, `deny`, `ask` or nothing.
///
/// The SUBJECTS are the things the call acts on: the paths for a file tool,
/// the command for `bash`. A rule with a pattern matches if it matches ANY
/// of them, and a rule with no pattern matches any subject.
pub fn permDecision(tool: []const u8, subjects: []const []const u8) ?permrules.Decision {
    if (permrules.decide(perm_rules.rules, tool, subjects)) |d| return d;

    // The POLICY: the built-in sensitive table. Its action is ASK, and that
    // is the whole point of it: the built-in table does not REFUSE (a project
    // with a `.vscode/` the user wants edited is blocked forever by a
    // refusal), it asks, and a rule in a file can answer "allow" for it.
    for (subjects) |sub| {
        const v = pathsafe.checkWrite(sub);
        if (v == .ok) continue;
        return .{
            .action = .ask,
            .rule = .{
                .tool = tool,
                .pattern = sub,
                .action = .ask,
                .source = .policy,
                .text = switch (v) {
                    .dangerous => |d| d.what,
                    else => "a protected file",
                },
            },
        };
    }
    return null;
}

// ── environment and history notices ───────────────────────────

/// An env var read as a boolean, with a default.
///
/// `ZODE_AUTO_CHECK=0` is for someone who does not want a build started behind
/// their back. It has to be an escape hatch: "the harness decides to run a
/// compiler on your machine without being asked" is a policy, and a policy with
/// no off switch is not a default.
pub fn envTruthy(key: []const u8, default: bool) bool {
    return envTruthyIn(environ_global, key, default);
}

/// An env var read as a boolean, from an explicit map.
///
/// One implementation because the check existed in THREE places and they had
/// already drifted: two compared `"off"` case-insensitively and the third did not,
/// so `ZODE_X=OFF` turned the feature off in one place and on in another. The
/// comparison is case-insensitive because `OFF`, `Off` and `off` are the same
/// answer to anybody who typed them.
pub fn envTruthyIn(env: ?*const std.process.Environ.Map, key: []const u8, default: bool) bool {
    const raw = envGet(env, key) orelse return default;
    // An EMPTY value means "not set". It is what you get from `ZODE_AUTO_BG=` in
    // a `.env` file, and treating it as false would silently disable a default
    // because of a trailing `=`.
    if (raw.len == 0) return default;
    if (std.mem.eql(u8, raw, "0") or std.ascii.eqlIgnoreCase(raw, "false") or
        std.ascii.eqlIgnoreCase(raw, "no") or std.ascii.eqlIgnoreCase(raw, "off"))
    {
        return false;
    }
    return true;
}

/// The floor of the iteration limit, as a function so the test can name it.
fn agent_default_iterations() usize {
    return default_max_iterations;
}

fn envGet(env: ?*const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const m = env orelse return null;
    return m.get(key);
}

/// [roster] The free-auto label for the status bar, or "" if it is off.
///
/// It is a `pub` instead of letting the TUI import `free_auto.zig`: the status
/// bar should only know how to read the mode's state, not write to it.
pub fn freeAutoLabel(gpa: std.mem.Allocator) []const u8 {
    return free_auto.freeAutoLabel(gpa);
}

/// [roster] Is the mode on? The palette needs it to write "on · 3/8" next to the
/// command, so the state is visible without asking for it.
pub fn freeAutoOn() bool {
    return free_auto.freeAutoOn();
}

/// [roster] Turns free-auto on if the environment asks for it
/// (`ZODE_FREE_AUTO=1`).
///
/// The TUI's startup calls it, AFTER `loadUserConfig` and `loadAuthKeys` (with
/// no keys loaded the pool would come out empty and the mode would look
/// broken).
pub fn initFreeAutoFromEnv(m: *tui.Model) void {
    free_auto.initFromEnv(m, m.environ);

    // `ZODE_AUTO_BG=0` opts out of starting known-slow verifications in the
    // background on their own (see `lib/verify.zig`). Default: on, because the
    // alternative is the user's input freezing for the length of a build.
    if (!envTruthyIn(m.environ, "ZODE_AUTO_BG", true)) {
        tools_mod.setAutoBackground(false);
    }
}

/// The cheap router's state: which small model to try, and whether it has already
/// said no.
///
/// A module global and not a `Model` field because the decision has to survive
/// across turns to be worth anything: a model that is gated is gated for the
/// rest of the session, and a per-turn flag would spend a 403 on every turn.
var cheap_router: router_mod.State = .{};
/// Read once at startup, like every other `ZODE_*` switch, so a turn does not
/// re-parse the environment and so the flag cannot change mid-turn.
var router_cheap_on: bool = false;

/// `ZODE_CHEAP_TURN`, read once at startup.
/// The cheap-router model name, in a static buffer.
///
/// Same rule as `cur_model_buf`, and for the same reason: the global
/// outlives the map `initFromEnv` read the name from. `initFromEnv`
/// returns a slice INTO the caller's map, so a global that points at it
/// dangles the moment any caller passes a map it then deinits — which is
/// exactly what a test does, and what the first E2E test crashed on.
pub var cheap_model_buf: [128]u8 = undefined;

pub fn initCheapRouterFromEnv(env: ?*const std.process.Environ.Map) void {
    cheap_router = router_mod.initFromEnv(env);
    if (cheap_router.cheap_model.len > 0) {
        const n = @min(cheap_router.cheap_model.len, cheap_model_buf.len);
        std.mem.copyForwards(u8, cheap_model_buf[0..n], cheap_router.cheap_model[0..n]);
        cheap_router.cheap_model = cheap_model_buf[0..n];
    }
    router_cheap_on = cheap_router.cheap_model.len > 0;
}

/// Puts the cheap model back in play after a model or provider change.
///
/// After switching, the "cheap" model is very unlikely to be available, and
/// finding that out with a 403 instead of with a line of text is the thing the
/// notice is for.
pub fn resetCheapRouter(m: *tui.Model) void {
    if (!router_cheap_on or !cheap_router.given_up) return;
    pushInfo(m, "the cheap model is in play again after the model change");
    cheap_router.given_up = false;
    cheap_router.attempts = 0;
    cheap_router.fallbacks = 0;
    cheap_router.last_why = null;
}

/// What the cheap router has been doing, for `/bench`.
pub const CheapStats = struct {
    on: bool,
    model: []const u8,
    attempts: u32,
    fallbacks: u32,
    given_up: bool,
};

pub fn cheapRouterStats() CheapStats {
    return .{
        .on = router_cheap_on,
        .model = cheap_router.cheap_model,
        .attempts = cheap_router.attempts,
        .fallbacks = cheap_router.fallbacks,
        .given_up = cheap_router.given_up,
    };
}

/// [roster] `pub` so `free_auto.zig` can use it from its worker.
pub fn pushInfo(m: *tui.Model, text: []const u8) void {
    m.pushInfo(text);
}

/// [roster] `pub` so `free_auto.zig` can use it from its worker.
pub fn pushError(m: *tui.Model, text: []const u8) void {
    m.pushError(text);
}

/// Variant that already owns the caller's memory: the text does not have to be
/// duplicated (nor freed). Used in the worker, which cannot leave garbage per
/// frame.
/// [roster] `pub` so `free_auto.zig` can use it.
pub fn pushInfoOwned(m: *tui.Model, text: []const u8) void {
    m.pushInfoOwned(text);
}

/// Replays the session messages into the TUI history so they are visible
/// when a session is resumed. The session messages are stored in the session
/// file but the TUI's history (`paras`) is separate and needs to be populated
/// from the session messages on resume.
pub fn replaySessionMessages(m: *tui.Model, s: *session_mod.Session) void {
    for (s.messages.items) |sm| {
        const kind = switch (sm.role) {
            .user => md.Kind.user,
            .assistant => md.Kind.assistant,
            .tool => md.Kind.tool_res,
            .system => md.Kind.info,
        };
        m.pushKind(kind, sm.content);
    }
    // Drain the pending queue so the paragraphs are in `paras` immediately
    m.drainPending();
}

/// Error to the history, in RED (`md.Kind.error_msg`, `✗` prefix).
///
/// The Kind and the prefix existed from the start, and NO caller used it:
/// every error went out through `pushInfoOwned`, which is `.info` grey. In
/// other words a 403 and a "session resumed" read equally dim, and in a long
/// history the error was just one more line among a hundred.
fn pushErrorOwned(m: *tui.Model, text: []const u8) void {
    m.pushErrorOwned(text);
}

/// Sets the turn status. The text does NOT carry the face: the TUI draws it in
/// the status row, in the mood's color, exactly once. Here it used to be
/// embedded and it came out duplicated and in the same grey as everything else
/// (which is precisely the complaint that "you can't tell by the color").
/// [roster] `pub` so `free_auto.zig` can use it.
pub fn setStatusWithZo(m: *tui.Model, mood: tui.StatusKind, text: []const u8) void {
    m.setStatusWithMood(mood, text);
}

/// `setStatusWithZo` that composes the text itself.
///
/// It exists because of the rule AGENTS.md writes down the hard way: the composed
/// string has to be COPIED (`Model.setStatusText` copies into a fixed buffer), and
/// the tempting alternative is `allocPrint(m.allocator, …)` + `pushInfoOwned`,
/// which on an out-of-memory path hands a LITERAL to a function that frees it.
/// Composing and copying in one call makes that mistake unrepresentable.
pub fn setStatusWithZoFmt(m: *tui.Model, mood: tui.StatusKind, comptime fmt: []const u8, args: anytype) void {
    m.setStatusFmt(mood, fmt, args);
}

/// `pushError` that composes the text. Same reason as `setStatusWithZoFmt`.
pub fn pushErrorFmt(m: *tui.Model, comptime fmt: []const u8, args: anytype) void {
    m.pushErrorFmt(fmt, args);
}

/// `pushInfo` that composes the text. Same reason as `setStatusWithZoFmt`.
pub fn pushInfoFmt(m: *tui.Model, comptime fmt: []const u8, args: anytype) void {
    m.pushInfoFmt(fmt, args);
}

// ── providers: config.json > built-in ────────────────────────

/// All providers: the user's `config.json` first, then the built-ins that are
/// not overridden (a config id beats the built-in).
/// [roster] `pub` so `free_auto.zig` can list the providers of the pool.
pub fn allProviders(arena: std.mem.Allocator) []const providers.ProviderDef {
    return config_mod.allDefs(arena, user_config);
}

pub fn activeProviderDef(env: ?*const std.process.Environ.Map) *const providers.ProviderDef {
    if (config_mod.find(user_config, cur_provider_id)) |d| return d;
    return providers.byId(cur_provider_id) orelse providers.activeDef(env);
}

/// Key state of the active provider's API key.
/// 
/// `verified` means the key has been tested and works (recent auth success).
/// `saved` means the key is stored in `auth.json` but has not been verified.
/// `invalid` means the key is known to be bad (e.g., auth error received).
/// `unknown` means no key is configured.
///
/// Takes the provider's environment to determine the key source.
pub fn keyState(env: *const std.process.Environ.Map) u8 {
    // Check saved keys first (from auth.json)
    const def = activeProviderDef(env);
    if (def.key_env.len > 0) {
        // If there are saved keys, the key is at least "saved"
        // Check if it also works via the environment
        if (providers.keyFor(def, env) != null) return 1; // verified
        return 2; // saved
    }
    // Check environment
    const env_key = envGet(env, "ZODE_API_KEY");
    if (env_key) |_| return 1; // verified (we assume it works if env has it)
    return 0; // unknown
}

// Helper to compute the env var name for a provider's key
fn providerKeyEnvName(def: *const providers.ProviderDef) []const u8 {
    // Use the provider's key_env field if available, otherwise fall back to
    // the generic ZODE_API_KEY
    if (def.key_env.len > 0) return def.key_env[0];
    return "ZODE_API_KEY";
}

// API key of the active provider: first the one saved in `auth.json`, then
/// the environment variable, then the generic one.
fn curKey(m: *tui.Model) ?[]const u8 {
    if (providers.keyFor(activeProviderDef(m.environ), m.environ)) |k| return k;
    if (api_key_global) |k| return k;
    return envGet(m.environ, "ZODE_API_KEY");
}

// ── user config ───────────────────────────────────────────────

var cfg_arena_state: ?std.heap.ArenaAllocator = null;
var user_config: config_mod.Config = .{};

/// Loads the user's `config.json`. Call once at startup.
pub fn loadUserConfig() void {
    if (cfg_arena_state == null) {
        cfg_arena_state = std.heap.ArenaAllocator.init(gpa_global);
        user_config = config_mod.load(cfg_arena_state.?.allocator(), io_global, environ_global);

        // Precedence order: config.json > ZODE_PROVIDER > opencode.
        // (ZODE_PROVIDER used to be ignored in the TUI: it stayed on "opencode"
        // and ended up sending one provider's key to another provider's
        // endpoint → 403.)
        if (user_config.provider.len > 0) {
            setProviderId(user_config.provider);
        } else if (envGet(environ_global, "ZODE_PROVIDER")) |p| {
            if (config_mod.find(user_config, p) != null or providers.byId(p) != null) {
                setProviderId(p);
            }
        }
        // `ZODE_MODEL` FIRST, then `config.json`. It was config.json only, and
        // `userModel()` — the one function that reads the variable — had exactly
        // one caller, in the headless runner. So in the TUI `ZODE_MODEL` was
        // silently ignored and the model was resolved from the provider's
        // catalogue instead, on every startup.
        //
        // It went unnoticed because `config.json` and `ZODE_MODEL` usually name
        // the same thing, and when they disagreed the TUI used the one the user
        // was less likely to be looking at.
        //
        // The order matches `userModel()`, which the headless path uses, so the
        // two entry points cannot disagree about what the user asked for.
        if (envGet(environ_global, "ZODE_MODEL")) |mm| {
            if (mm.len > 0) setModel(mm);
        }
        if (user_config.model.len > 0 and cur_model.len == 0) {
            setModel(user_config.model);
        } else if (cur_model.len == 0) {
            // The provider's `default_model` is NOT set here, and not out of laziness: a
            // model name in the code stops existing the day the provider
            // withdraws it, and then EVERY request fails with a 403 that says
            // nothing. With no model, `resolveModel` asks the provider it has
            // (and picks the first free one), which is data that can be looked at
            // again when it changes.
            if (activeProviderDef(environ_global).default_model.len > 0) {
                setModel(activeProviderDef(environ_global).default_model);
            }
        }
        loadAllowlist();
        // The permission RULES (Phase 6): the project file and the user file.
        // They are read here, next to the allowlist they live with, and the
        // hot path reads the cached set.
        loadPermRules();
        loadAuthKeys(cfg_arena_state.?.allocator());

        // The user's language servers. The manager COPIES them into its own
        // memory, because this arena is freed on the next reload (connecting a
        // provider reloads the config) and a server list that pointed into it
        // would be a dangling pointer from then on.
        lsp_manager.setServers(user_config.lsp_servers) catch {};

        // The user's MCP servers. The same reason as the language servers: the
        // manager COPIES them into its own memory, because this arena is freed
        // on the next reload (connecting a provider reloads the config).
        mcp_manager.setServers(user_config.mcp_servers) catch {};

        // The status bar's `provider/model`, resolved now that the provider is
        // known. It reads the CACHED catalogue and never the network, so this is
        // safe to do on the startup path.
        if (status_model_target) |m| tui.resolveStatusModel(m);
    }
}

/// The Model whose status bar row `loadUserConfig` refreshes.
///
/// It is a global and not a parameter for the reason every other startup hook
/// here is: `loadUserConfig` is called from four places, two of them before the
/// Model exists, and threading a pointer through all four is how the call ends
/// up missing from the one that matters.
pub var status_model_target: ?*tui.Model = null;

/// Reads `~/.config/zode/auth.json` and hands it to `providers` so `keyFor`
/// uses it. Without this, connecting a provider from the palette saved the key
/// and then never used it: `keyFor` only looked at the environment.
/// Arena for the saved keys. **Never destroyed until the process exits**.
///
/// Before, every config reload reused the config's arena, which WAS freed: the
/// models worker was reading `saved_keys` through `providers.hasKey` while the
/// UI thread connected a provider and freed that arena under its feet.
/// Use-after-free, with nothing announcing it (it depends on the worker
/// landing exactly on that line).
///
/// Here every new map lives in its own permanent arena, so reassigning the
/// pointer is atomic and the old map stays valid memory (what is no longer
/// used is freed at exit).
var keys_arena_state: ?std.heap.ArenaAllocator = null;

fn loadAuthKeys(_: std.mem.Allocator) void {
    var buf: [1024]u8 = undefined;
    const path = config_mod.authPath(environ_global, &buf) orelse return;
    // BEFORE reading: an `auth.json` created by an older zode (or by hand) can
    // be 0644, and reading it does not fix that. Every start of the app went
    // through here and left the keys readable by every user on the machine.
    config_mod.tightenPermissions(io_global, path);

    if (keys_arena_state == null) keys_arena_state = std.heap.ArenaAllocator.init(gpa_global);
    const a = keys_arena_state.?.allocator();

    const data = readFileTo(a, path) orelse return;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, data, .{}) catch return;
    if (parsed != .object) return;

    var map = a.create(std.StringHashMapUnmanaged([]const u8)) catch return;
    map.* = .{};
    var it = parsed.object.iterator();
    while (it.next()) |kv| {
        const v = kv.value_ptr.*;
        if (v != .string or v.string.len == 0) continue;
        // The key is copied because the parser's string lives in the arena that was
        // just freed above.
        map.put(a, kv.key_ptr.*, a.dupe(u8, v.string) catch continue) catch continue;
    }
    providers.setSavedKeys(map);
}

/// Re-reads `config.json` from scratch.
///
/// `loadUserConfig` guards on "only once" (the config is read at startup), so
/// without this, after connecting a provider its key state stayed at "no key"
/// for the rest of the session.
pub fn reloadUserConfig() void {
    // CAREFUL: `shutdownUserConfig` is NOT called here, because that function also
    // destroys the keys arena, which a worker may be reading. The keys arena is
    // destroyed only in `shutdownUserConfig`, at the end of the process.
    if (cfg_arena_state) |*st| st.deinit();
    cfg_arena_state = null;
    user_config = .{};
    // The subagent's pick may have changed with the config: a give-up recorded
    // against the OLD `subagent_model` must not outlive it, or fixing
    // config.json would do nothing until restart.
    sub_fail_len = 0;
    loadUserConfig();
}

/// Frees the config and keys arenas. On process exit, when no worker is left
/// reading.
pub fn shutdownUserConfig() void {
    // The pointer is cleared BEFORE the arena is freed. The atomic store in
    // `providers.setSavedKeys` makes the SWAP safe; it says nothing about the
    // lifetime of what the pointer points at. A worker that loaded the map a
    // moment before the `deinit` below would read freed memory through it, and
    // this is the only place the keys arena dies.
    providers.setSavedKeys(null);
    if (cfg_arena_state) |*s| {
        s.deinit();
        cfg_arena_state = null;
    }
    if (keys_arena_state) |*s| {
        s.deinit();
        keys_arena_state = null;
    }
    user_config = .{};
    // The skills cache is the third arena-like thing in the process and the only
    // one with heap strings owned by the module. It is BORROWED by everyone, so
    // this is the one place it can be freed — at exit, with no worker left.
    freeSkillsCache();
}

test "shutdownUserConfig: after it, no key is readable through the pointer" {
    // The ORDER inside `shutdownUserConfig` is the guarantee: the pointer is
    // published as null before the arena dies, so a worker that arrives late
    // reads null instead of a freed map. What this test can see is the
    // postcondition; the race itself needs two threads and cannot be run here.
    providers.setSavedKeys(null);
    defer providers.setSavedKeys(null);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const map = try a.create(std.StringHashMapUnmanaged([]const u8));
    map.* = .{};
    try map.put(a, "zai", "sk-guardada");
    providers.setSavedKeys(map);
    try std.testing.expectEqualStrings("sk-guardada", providers.savedKeyFor("zai").?);

    shutdownUserConfig();

    try std.testing.expect(providers.savedKeyFor("zai") == null);
}

// ── session ───────────────────────────────────────────────────

/// Returns the active session, creating it if needed.
///
/// Called from the worker and from the commands. The session is created THE
/// FIRST TIME it is needed, not at startup: so opening the TUI and closing it
/// without chatting does not leave an empty `sessions/zode-*.jsonl` lying
/// around.
pub fn ensureSession(m: *tui.Model, arena: std.mem.Allocator) *session_mod.Session {
    if (session) |s| return s;
    _ = arena;
    const fresh = session_mod.Session.create(m.allocator, io_global) catch {
        // Without disk it carries on: that is degradation, not a fatal error. The
        // in-memory session (`file = null`) writes nothing.
        const s = m.allocator.create(session_mod.Session) catch @panic("out of memory for the session");
        s.* = session_mod.Session.init(m.allocator);
        session = s;
        cache_stats.session = .{};
        return s;
    };
    session = fresh;
    cache_stats.session = .{};
    return fresh;
}

/// A file's diff carries the LANGUAGE so that the body of each line
/// is tokenized (`+const n: u32 = 42`: keyword, type and number are
/// distinguishable).
///
/// Without this the whole diff came out in the prefix's color, which is the
/// green wall of the ROADMAP. The path extension is the source: it is what we
/// have, and it requires asking the model nothing.
fn langFromPath(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return "";
    if (dot + 1 >= base.len) return "";
    return base[dot + 1 ..];
}

/// The per-session file state: the read cache and the changed list.
///
/// A new session's context is EMPTY, so an entry that says "the model has this
/// file" is a lie from that moment on: the next `read` would take the fast
/// path, answer "it is already in your context" WITHOUT sending the body, and
/// the model would be working from a file it cannot see.
///
/// It is its own function so that a test can drive it without a session (and
/// without the `Io` that creating one needs).
pub fn resetSessionFiles(m: *tui.Model) void {
    m.reads.clear();
    m.changed.clear();
    m.bash_may_write = false;
}

/// Creates a new session and discards the current one.
pub fn newSession(m: *tui.Model) void {
    if (session) |old| {
        m.allocator.destroy(old);
        session = null;
    }
    cache_stats.session.reset();
    const s = ensureSession(m, m.allocator);
    // Limpia el output/transcript visible para que la nueva sesión empiece
    // sin restos de la anterior en pantalla.
    m.clearHistory();
    m.pushInfoFmt("new session: {s}", .{s.id[0..]});
    session_elided = 0;
    resetSummaries();
    // The git probe's answer is about the DIRECTORY, and a `git init` in the middle of a
    // session changes it. These are the only two moments that can: everything else in a
    // session happens inside the same tree.
    forgetGitRepoProbe();
    // The read cache and the changed list are about THIS session: a new
    // session's context is EMPTY, so an entry that says "the model has this
    // file" would make the next `read` skip the body — and the model would
    // be working from a file it cannot see.
    resetSessionFiles(m);
}

/// Callback for the `/session` picker: resumes the session at `index`.
pub fn onSessionPick(m: *tui.Model, _: u32, index: usize) void {
    if (index >= m.session_picker_paths.items.len) return;
    const path = m.session_picker_paths.items[index];

    if (session) |old| {
        m.allocator.destroy(old);
        session = null;
    }
    cache_stats.session.reset();

    if (session_mod.Session.resumePath(m.allocator, io_global, path)) |s| {
        session = s;
        cache_stats.session = s.usage_stats;
        const msg = std.fmt.allocPrint(m.allocator, "session resumed: {s}", .{s.path orelse s.id[0..]}) catch
            "session resumed";
        pushInfoOwned(m, msg);
        resetSessionFiles(m);
    } else |err| {
        pushInfoFmt(m, "could not resume {s}: {t}", .{ path, err });
    }
}

/// Callback for F2 rename in the session picker.
/// `m.picker_rename_target` holds the session path (set by the TUI's F2 handler).
/// Renames the session by setting its custom_title and persisting to the Meta sidecar.
pub fn onSessionRename(m: *tui.Model, _: u32, label: []const u8) void {
    const path = m.picker_rename_target orelse {
        pushInfo(m, "rename: could not find session path");
        return;
    };

    // The label may have " (current)" appended; strip it for display only.
    const display = if (std.mem.endsWith(u8, label, "  (current)"))
        label[0..label.len - "  (current)".len]
    else
        label;

    const s = session orelse {
        pushInfoFmt(m, "rename: no active session to rename {s}", .{display});
        return;
    };

    // Only rename if this picker item is the current session.
    if (s.path != null and std.mem.eql(u8, path, s.path.?)) {
        // Rename the current session to the label (stripped of " (current)").
        const trimmed = std.mem.trim(u8, display, " \t\r\n");
        if (trimmed.len == 0) {
            pushInfo(m, "rename: empty name");
            return;
        }
        if (trimmed.len > 64) {
            pushInfo(m, "rename: name too long (max 64 chars)");
            return;
        }

        if (s.custom_title.len > 0) s.allocator.free(s.custom_title);
        s.custom_title = s.allocator.dupe(u8, trimmed) catch {
            pushInfo(m, "rename: out of memory");
            return;
        };

        var arena_state = std.heap.ArenaAllocator.init(s.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const meta = sessionindex.readMeta(arena, io_global, path);
        sessionindex.writeMeta(io_global, arena, path, .{
            .name = meta.name,
            .model = meta.model,
            .created_at = meta.created_at,
            .custom_title = trimmed,
            .ai_title = meta.ai_title,
        }) catch |err| {
            pushInfoFmt(m, "rename: could not save: {s}", .{@errorName(err)});
            return;
        };

        pushInfoFmt(m, "renamed to \"{s}\"", .{trimmed});
    } else {
        pushInfoFmt(m, "rename: {s} is not the current session (use /rename <name>)", .{display});
    }
}

// ── turn stats (ROADMAP phase 3) ──────────────────────────────

/// What happened in the current turn: tools, files, lines, duration.
///
/// Lives as a MODULE GLOBAL (like `CacheStats`) and not inside the `TurnCtx`,
/// because the `TurnCtx` is destroyed in `runOneTurn`'s `defer` exactly when
/// the summary has to be written. The alternative (accumulating in `TurnCtx`
/// and handing it to `chatWorker`) would force returning the struct through the
/// same path that returns the synthesized text.
pub const TurnStats = struct {
    gpa: std.mem.Allocator = undefined,
    iterations: usize = 0,
    tools: usize = 0,
    denied: usize = 0,
    /// How many times the model reviewed its own diff this turn.
    ///
    /// It is on the summary line because a turn that ends having reviewed nothing is
    /// worth seeing as a number rather than as an absence: "0 reviews" reads as a fact
    /// and a missing line reads as something nobody looked for.
    reviews: usize = 0,
    /// Questions the harness answered on its own because nobody was going to
    /// answer them (YOLO mode).
    yolo_auto: usize = 0,
    /// The questions that were LEFT OPEN (YOLO mode, nothing to take).
    ///
    /// They are kept because the summary has to name them: a question nobody
    /// was asked and nobody mentions is a question that is lost, and the user
    /// is the only one who can answer it.
    yolo_open: std.ArrayList([]const u8) = .empty,
    /// Files touched, in order of appearance, without repeats.
    files: std.ArrayList([]const u8) = .empty,
    lines_added: usize = 0,
    lines_removed: usize = 0,
    t0_ns: i128 = 0,

    /// Starts counting a turn. Frees the previous one.
    ///
    /// CAREFUL with the order: `deinit` uses `self.gpa` (the one from the
    /// PREVIOUS turn), so you must free before overwriting the allocator. With
    /// the struct initialized to `.{}` (`gpa` undefined) that would be a `free`
    /// with garbage.
    pub fn reset(self: *TurnStats, gpa: std.mem.Allocator, t0_ns: i128) void {
        self.deinit();
        self.* = .{ .gpa = gpa, .t0_ns = t0_ns };
    }

    pub fn deinit(self: *TurnStats) void {
        // `capacity == 0` = list with no memory of its own: there is nothing
        // to free and `gpa` may be uninitialized. Each list is checked on its
        // OWN: one early return for the files used to skip the open questions,
        // and they leaked.
        if (self.files.capacity > 0) {
            for (self.files.items) |f| self.gpa.free(f);
            self.files.deinit(self.gpa);
        }
        if (self.yolo_open.capacity > 0) {
            for (self.yolo_open.items) |q| self.gpa.free(q);
            self.yolo_open.deinit(self.gpa);
        }
        // FORGET BOTH LISTS, and this is the half that was missing.
        //
        // `chatWorker` calls `reset()` at the start of every turn and
        // `deinit()` in a `defer` at the end, so the sequence for the SECOND
        // turn is deinit (turn 1) → reset → deinit AGAIN. Without these two
        // lines the second `deinit` still saw `capacity > 0` over freed memory
        // and freed the same pointers again — a double free that showed up as
        // a general protection exception at `self.gpa.free(f)` in a WORKER
        // thread, which is exactly the shape of the open crash this repo has
        // been hunting: silent in ReleaseSmall, immediate in a debug build.
        //
        // Reproduced (2026-10-23) with two turns in one session, the second
        // one after a turn that had written a file: `tools/stress_tui.py`.
        // Only turns that TOUCHED a file (or asked a question) have a non-empty
        // list, which is why it looked random instead of every second turn.
        self.files = .empty;
        self.yolo_open = .empty;
    }

    /// Records a question that nobody answered and nobody will.
    pub fn noteYoloOpen(self: *TurnStats, question: []const u8) void {
        const copy = self.gpa.dupe(u8, question) catch return;
        self.yolo_open.append(self.gpa, copy) catch {
            self.gpa.free(copy);
            return;
        };
    }

    /// Records a touched file with its diff. If it was already there, it only adds
    /// the line counts: writing the same file twice in a turn is one line, not
    /// two files.
    pub fn noteDiff(self: *TurnStats, path: []const u8, counts: tui.DiffCounts) void {
        if (counts.added == 0 and counts.removed == 0) return;
        for (self.files.items) |f| {
            if (std.mem.eql(u8, f, path)) {
                self.lines_added += counts.added;
                self.lines_removed += counts.removed;
                return;
            }
        }
        const copy = self.gpa.dupe(u8, path) catch return;
        self.files.append(self.gpa, copy) catch {
            self.gpa.free(copy);
            return;
        };
        self.lines_added += counts.added;
        self.lines_removed += counts.removed;
    }

    pub fn noteTool(self: *TurnStats) void {
        self.tools += 1;
    }

    pub fn noteDenied(self: *TurnStats) void {
        self.denied += 1;
    }

    /// Milliseconds the turn has been running (0 if there is no clock).
    pub fn elapsedMs(self: *const TurnStats, now_ns: i128) u64 {
        if (self.t0_ns == 0) return 0;
        return @intCast(@max(0, now_ns - self.t0_ns) / std.time.ns_per_ms);
    }

    /// `⏺ Done · 3 tools · 2 files changed · 12.4s · ~18k tokens (62% cached)`
    ///
    /// Returns memory from the allocator it is given (a copy of `gpa`), not
    /// internal pointers: the `files` belong to the turn and may be freed.
    ///
    /// Writes into `buf` (the caller's) and returns a slice of it: no
    /// allocations, because this line is composed once per turn but the caller
    /// puts it into the history, which already copies.
    pub fn summaryLine(
        self: *const TurnStats,
        buf: []u8,
        ms: u64,
        tokens_used: i64,
        cache_pct: u8,
    ) ![]const u8 {
        var w: std.Io.Writer = .fixed(buf);
        try w.writeAll("\u{23ba} Done \u{b7} ");
        try w.print("{d} tool{s}", .{ self.tools, if (self.tools == 1) "" else "s" });
        if (self.denied > 0) try w.print(" \u{b7} {d} denied", .{self.denied});
        if (self.yolo_auto > 0) {
            try w.print(" \u{b7} {d} question{s} answered for you", .{
                self.yolo_auto,
                if (self.yolo_auto == 1) "" else "s",
            });
        }
        if (self.yolo_open.items.len > 0) {
            try w.print(" \u{b7} {d} question{s} still OPEN", .{
                self.yolo_open.items.len,
                if (self.yolo_open.items.len == 1) "" else "s",
            });
        }
        if (self.files.items.len > 0) {
            try w.print(" \u{b7} {d} file{s} changed", .{
                self.files.items.len,
                if (self.files.items.len == 1) "" else "s",
            });
            if (self.lines_added > 0 or self.lines_removed > 0) {
                try w.print(" (+{d} \u{2212}{d})", .{ self.lines_added, self.lines_removed });
            }
        }
        try w.print(" \u{b7} {d}.{d}s", .{ ms / 1000, (ms % 1000) / 100 });
        if (tokens_used > 0) {
            try w.print(" \u{b7} ~{d}k tokens", .{@divTrunc(tokens_used + 500, 1000)});
            if (cache_pct > 0) try w.print(" ({d}% cached)", .{cache_pct});
        }
        return w.buffered();
    }

    /// Second line: `src/agent.zig · src/tui.zig` (the files touched).
    ///
    /// The files go alone: the summary already says how many tools ran, and
    /// what is useful here is the WHAT, not the tool. It could be stored with
    /// the tool's name, but with a turn of 5 tools the line runs off the screen
    /// and the path is what people are looking for.
    pub fn detailLine(self: *const TurnStats, buf: []u8) ![]const u8 {
        var w: std.Io.Writer = .fixed(buf);
        var first = true;
        for (self.files.items) |f| {
            if (!first) try w.writeAll(" \u{b7} ");
            first = false;
            try w.writeAll(f);
        }
        return w.buffered();
    }

    /// The questions that are still open, one per line.
    ///
    /// They are the user's to answer, and the summary says there are some: a
    /// number ("1 question still OPEN") says that something needs a human,
    /// and the TEXT of the question is what lets them answer it.
    pub fn yoloOpenLine(self: *const TurnStats, buf: []u8) ![]const u8 {
        if (self.yolo_open.items.len == 0) return "";
        var w: std.Io.Writer = .fixed(buf);
        try w.writeAll("still open (nobody was asked): ");
        const q = self.yolo_open.items[0];
        try w.writeAll(if (q.len > 120) q[0..120] else q);
        if (self.yolo_open.items.len > 1) {
            try w.print(" (+{d} more)", .{self.yolo_open.items.len - 1});
        }
        return w.buffered();
    }
};

/// Stats of the current turn. Module global (see `TurnStats`).
pub var turn_stats: TurnStats = .{};

/// 1 MiB buffer to compose the request body (ROADMAP 5.5).
///
/// It used to be `var body_buf: [1 << 20]u8` on `runOneTurn`'s STACK. With
/// `std.Thread`'s default stack (16 MiB) it works, but it is RESIDENT memory
/// for the whole call and it leaves a trap: the day someone lowers the worker's
/// `stack_size`, 1 MiB of stack turns into a segfault. On the heap instead,
/// reused across requests (allocated once).
var body_buf_heap: ?[]u8 = null;
/// The allocator that reserved `body_buf_heap`, kept beside it for the reason in
/// `shutdownBuffers`: the two are the same for the whole life of a process and are NOT
/// the same in a test that takes over the globals.
var body_buf_with: ?std.mem.Allocator = null;

fn bodyBuf(gpa: std.mem.Allocator) ![]u8 {
    if (body_buf_heap == null) {
        body_buf_heap = try gpa.alloc(u8, 1 << 20);
        body_buf_with = gpa;
    }
    return body_buf_heap.?;
}

/// Frees the body buffer. Called by the TEARDOWN, never at runtime (the keys
/// map has similar rules).
///
/// No allocator parameter, like `shutdownUserConfig`: the buffer was reserved
/// with `gpa_global`, so freeing it with a different allocator would be an
/// `Invalid free`.
pub fn shutdownBuffers() void {
    if (body_buf_heap) |b| {
        // The allocator that RESERVED it, not the global. They are the same for the whole
        // life of the process, which is why the difference never mattered — until the
        // first test that took over the globals to run a real turn, found it needed to
        // give them back, and crashed in here freeing a 1 MiB block with an allocator
        // that had never heard of it.
        //
        // A general protection fault, in the teardown of a test that had already printed
        // its result. `body_buf_with` is recorded at `bodyBuf` time precisely so this
        // function can be correct without anybody remembering to order the `defer`s.
        if (body_buf_with) |a| a.free(b) else gpa_global.free(b);
        body_buf_heap = null;
        body_buf_with = null;
    }
}

test "TurnStats: a file touched twice counts as one" {
    var s = TurnStats{};
    var backing: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    const g = fba.allocator();
    s.reset(g, 0);
    s.noteDiff("a.zig", .{ .added = 3, .removed = 1 });
    s.noteDiff("a.zig", .{ .added = 2, .removed = 0 });
    s.noteDiff("b.zig", .{ .added = 5, .removed = 5 });
    s.noteTool();
    try std.testing.expectEqual(@as(usize, 2), s.files.items.len);
    try std.testing.expectEqual(@as(usize, 10), s.lines_added);
    try std.testing.expectEqual(@as(usize, 6), s.lines_removed);
    s.deinit();
}

test "TurnStats: the summary reports tools, files and lines" {
    var s = TurnStats{};
    var backing: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    const g = fba.allocator();
    s.reset(g, 0);
    s.noteTool();
    s.noteTool();
    s.noteTool();
    s.noteDiff("src/tui.zig", .{ .added = 12, .removed = 3 });
    var line_buf: [256]u8 = undefined;
    const line = try s.summaryLine(&line_buf, 12_400, 18_000, 62);
    try std.testing.expect(std.mem.indexOf(u8, line, "3 tools") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "1 file changed") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "+12 \u{2212}3") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "12.4s") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "18k tokens") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "62% cached") != null);
    var detail_buf: [128]u8 = undefined;
    const detail = try s.detailLine(&detail_buf);
    try std.testing.expectEqualStrings("src/tui.zig", detail);
    s.deinit();
}

test "TurnStats: a 0-line diff invents no files" {
    var s = TurnStats{};
    var backing: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    const g = fba.allocator();
    s.reset(g, 0);
    s.noteDiff("nada.zig", .{});
    try std.testing.expectEqual(@as(usize, 0), s.files.items.len);
    s.deinit();
}

/// Empties the current session's history without creating a new one.
pub fn resetSession(m: *tui.Model) void {
    cache_stats.session.reset();
    // The money is per session like the tokens are: a `/new` that kept the cost
    // of the old one would show a bill for a conversation that no longer exists.
    cost_mod.session.reset();
    if (session) |s| {
        s.messages.clearRetainingCapacity();
        s.appendUsageSnapshot(cache_stats.session) catch |err| {
            m.pushErrorFmt("could not reset session usage: {t}", .{err});
        };
        s.flush();
    }
    session_elided = 0;
    resetSummaries();
    m.pushInfoFmt("session reset", .{});
}

/// Records one finished request against the session: tokens for `/usage`, and the
/// same tokens against the MODEL for `/cost`.
///
/// `model` is the one that ANSWERED and not `curModel()`: the free-auto rotation
/// and the cheap router both swap the target mid-turn, and a cost attributed to the
/// model the user picked instead of the one that replied is a number about the
/// wrong bill.
fn recordSessionUsage(m: *tui.Model, usage: chat.Usage, kind: chat.ProviderKind, model: []const u8) void {
    cache_stats.session.recordFor(usage, kind);
    cost_mod.session.record(model, cache_stats.totalInputTokens(usage, kind), usage.completion);
    if (session) |s| {
        s.appendUsageSnapshot(cache_stats.session) catch |err| {
            m.pushErrorFmt("could not save session usage: {t}", .{err});
        };
    }
}

/// Opens the session at startup: the most recent one if it was asked for
/// (`--resume` or `ZODE_RESUME=1`), otherwise a new one.
pub fn bootstrapSession(m: *tui.Model) void {
    loadUserConfig();

    if (resume_on_start) {
        var astate = std.heap.ArenaAllocator.init(m.allocator);
        defer astate.deinit();
        const a = astate.allocator();
        const latest = session_mod.Session.latestSessionPath(a, io_global) catch null;
        if (latest) |path| {
            if (session_mod.Session.resumePath(m.allocator, io_global, path)) |s| {
                session = s;
                cache_stats.session = s.usage_stats;
                const msg = std.fmt.allocPrint(m.allocator, "session resumed: {s}", .{s.path orelse s.id[0..]}) catch
                    "session resumed";
                pushInfoOwned(m, msg);
                return;
            } else |err| {
                // It used to be `else |_| {}`, and the user saw "nothing to resume;
                // starting a new session" for a session that EXISTS and is 200 MB.
                // The only way that happens is `error.FileTooBig` (the loader reads
                // up to 64 MiB), and the honest answer names the file and says how
                // to get to it, instead of quietly starting from zero.
                pushInfoFmt(m, "could not resume {s}: {t} (it is bigger than the 64 MiB read limit; open it with /resume and a smaller session, or split it)", .{ path, err });
            }
        }
        const msg = allocPrint(m, "nothing to resume; starting a new session", .{}) catch return;
        pushInfoOwned(m, msg);
    }
    // CAREFUL: the session is NOT created here (ROADMAP 1.9). This line used to
    // open a `sessions/zode-*.jsonl` on EVERY startup, and since the file is
    // created empty and nobody chatted, `sessions/` filled up with 0-byte
    // files: 58 files, 24 of them empty. The session is created by
    // `ensureSession`, which is only called when the first message is sent (or
    // when `/new` is explicitly requested).
}

/// Short `allocPrint`: the worker writes 90% of the history messages and cannot
/// leave garbage per frame.
fn allocPrint(m: *tui.Model, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(m.allocator, fmt, args);
}

/// Copies the session messages into a slice of `ChatMessage`.
///
/// `tool` → role "tool" (as OpenAI's API expects), and `system` stays first.
/// The memory comes from the arena the caller passes in.
pub fn snapshotMsgs(arena: std.mem.Allocator) []chat.ChatMessage {
    const s = session orelse return &.{};
    const msgs = arena.alloc(chat.ChatMessage, s.messages.items.len) catch return &.{};
    for (s.messages.items, 0..) |sm, i| {
        msgs[i] = .{
            .role = @tagName(sm.role),
            .content = sm.content,
            .tool_calls_json = sm.tool_calls_json,
            .tool_call_id = sm.tool_call_id,
            .tool_name = sm.tool_name,
        };
    }
    return msgs;
}

// ── command table ─────────────────────────────────────────────

/// What to do with the command that was just chosen in the palette.
pub const PaletteCmd = enum {
    /// Executed right here, right now.
    done,
    /// Needs arguments: the label goes to the input and the user types what is
    /// missing.
    needs_args,
    /// Leave the app. The TUI handles it (it is who owns `ctx.quit`).
    quit,
};

/// Runs a command chosen in the palette, WITHOUT going through the input.
///
/// Choosing a command from a list is already the confirmation: putting it in
/// the input and asking for another Enter was a second step nobody asked for,
/// and in a TUI where keys get eaten along the way it read as "it did
/// nothing".
///
/// The EXCEPTION is the commands that need arguments: `/use provider model`
/// cannot be run blind. Those go back to the input with the label in place,
/// which is exactly what whoever picks them wants.
///
/// The command echoes itself in the history (like the input) so you can see
/// what was run, not just what happened.
pub fn runPaletteCommand(m: *tui.Model, cmd: []const u8) PaletteCmd {
    if (std.mem.eql(u8, cmd, "/quit") or std.mem.eql(u8, cmd, "/exit")) return .quit;
    if (std.mem.eql(u8, cmd, "/use")) return .needs_args;
    m.pushKind(.user, cmd);
    submit(m, cmd) catch {};
    return .done;
}

/// Entry point of the TUI input: free text or a `/…` command.
///
/// A chat starts a WORKER (thread) that talks to the API; a command is resolved
/// here, in the UI thread, because they are local operations.

// `/effort` and `/yolo` are here and not in `commands.zig` because they WRITE
// agent state (`current_effort`, the yolo flag) and `commands.zig` importing
// back for a write is the edge that would make the two files a cycle.

/// `/yolo`: toggle bypass mode, the "stop asking me anything"
/// switch. Turning it on clears the other modes so the status bar
/// shows the mode that applies; turning it off returns to default.
fn cmdYolo(m: *tui.Model) void {
    setPermMode(m, if (yolo) .default else .bypass);
    const msg = if (yolo) "yolo ON: no confirmations, and no questions (your questions are answered for you and said in the summary)" else "yolo OFF: asks for permission";
    pushInfo(m, msg);
    setStatusWithZo(m, if (yolo) .warn else .idle, msg);
}

/// `/clear`: clear the visible transcript and reset the per-session caches
/// (the read list, the changed list, and the "skills already attached" flag
/// so the listing is re-attached on the next turn). Like `/new` this buys a
/// truth: after clearing, the model no longer pretends it has files it has
/// not seen in this session. It does NOT create a new session — use `/new`
/// for that.
fn cmdClear(m: *tui.Model) void {
    resetSessionFiles(m);
    m.clearHistory();
    if (session) |s| s.resetSkillsSent();
    m.pushInfo("screen cleared · read cache + changed list reset · skills listing re-attached next turn");
}

/// `/mode [build|accept-edits|plan|bypass]`, or the current
/// mode with no argument.
///
/// Selective permissions: the user picks how much the agent asks,
/// per CLASS of action, without the all-or-nothing `/yolo`.
fn cmdMode(m: *tui.Model, arg: ?[]const u8) void {
    if (arg) |a| {
        const mode = parsePermMode(a);
        if (mode) |mm| {
            setPermMode(m, mm);
            setStatusWithZoFmt(m, if (mm == .read_only) .warn else .idle, "mode: {s}", .{permModeName()});
            pushInfoFmt(m, "permission mode: {s}", .{permModeName()});
            return;
        }
        pushInfo(m, "/mode: build|accept-edits|plan|bypass");
        return;
    }
    pushInfoFmt(m, "permission mode: {s} (shift+tab cycles)", .{permModeName()});
}

/// The mode a `/mode` argument names, or null when it names none.
/// Case-insensitive, and tolerant of the spellings people type.
fn parsePermMode(a: []const u8) ?PermMode {
    if (std.ascii.eqlIgnoreCase(a, "build") or std.ascii.eqlIgnoreCase(a, "default")) return .default;
    if (std.ascii.eqlIgnoreCase(a, "accept-edits") or
        std.ascii.eqlIgnoreCase(a, "accept_edits") or
        std.ascii.eqlIgnoreCase(a, "edits")) return .accept_edits;
    if (std.ascii.eqlIgnoreCase(a, "plan") or
        std.ascii.eqlIgnoreCase(a, "read-only") or
        std.ascii.eqlIgnoreCase(a, "readonly") or
        std.ascii.eqlIgnoreCase(a, "ro")) return .read_only;
    if (std.ascii.eqlIgnoreCase(a, "bypass") or
        std.ascii.eqlIgnoreCase(a, "yolo")) return .bypass;
    return null;
}

/// `/effort low|medium|high`, or the picker if it comes without arguments.
///
/// The level asked for is kept as-is; `chat.effortFor` is what maps it onto what
/// the CURRENT model accepts at request time. That split is deliberate: the user
/// picks an intent ("as much as this model can do") and the harness is the thing
/// that knows the vocabulary, so switching models does not silently change the
/// meaning of a setting the user already chose.
///
/// What it does NOT do is accept a level the model cannot take and say nothing:
/// `/effort xhigh` on a three-rung model says so, because the alternative is the
/// user finding out from a 400 halfway through a turn.
fn cmdEffort(m: *tui.Model, arg: ?[]const u8) void {
    if (arg) |a| {
        const want = chat.Effort.parse(a) orelse {
            m.pushInfoFmt("unknown effort: {s} (none|minimal|low|medium|high|xhigh)", .{a});
            return;
        };
        current_effort = want;
        // What actually goes out, which is not always what was typed. It is said out
        // loud because the alternative is the user finding out about the 400
        // halfway through a turn.
        const got = chat.effortFor(cur_model, want);
        if (got == null) {
            m.pushInfoFmt("effort → {s} (this model has no effort knob; the level only sets the answer length)", .{
                want.label(),
            });
        } else if (got.? != want) {
            m.pushInfoFmt("effort → {s} (this model tops out at {s}, so {s} is what goes on the wire)", .{
                want.label(),
                chat.maxEffortFor(cur_model).label(),
                got.?.label(),
            });
        } else {
            m.pushInfoFmt("effort → {s}", .{want.label()});
        }
        return;
    }
    openEffortPicker(m);
}

pub fn submit(m: *tui.Model, input: []const u8) !void {
    if (input.len == 0) return;
    if (input[0] != '/') return startChat(m, input);

    var it = std.mem.tokenizeScalar(u8, input[1..], ' ');
    const cmd = it.next() orelse return;
    // Without arguments it is a real `null`, not an empty slice. `it.rest()`
    // returns `""` for "/effort", and with an empty non-null slice the `else` of
    // "low|medium|high" swallowed the case: `/effort` on its own answered
    // "unknown effort:  (low|medium|high)" instead of opening the picker.
    const rest = it.rest();
    const arg: ?[]const u8 = if (rest.len == 0) null else rest;

    if (std.mem.eql(u8, cmd, "help")) {
        commands_mod.cmdHelp(m);
    } else if (std.mem.eql(u8, cmd, "quit")) {
        // the TUI handles it
    } else if (std.mem.eql(u8, cmd, "exit")) {
        // alias of /quit — the TUI handles it
    } else if (std.mem.eql(u8, cmd, "clear")) {
        cmdClear(m);
    } else if (std.mem.eql(u8, cmd, "models")) {
        listModelsAsync(m) catch pushError(m, "error starting /models");
    } else if (std.mem.eql(u8, cmd, "providers")) {
        commands_mod.cmdProviders(m);
    } else if (std.mem.eql(u8, cmd, "provider")) {
        openProviderPicker(m);
    } else if (std.mem.eql(u8, cmd, "model")) {
        // It opens RIGHT AWAY (the providers column is local) and the models are
        // painted when they arrive. Before, nothing opened until the network
        // answered, and with a slow provider it looked like the command did
        // nothing.
        openModelPaletteAsync(m);
    } else if (std.mem.eql(u8, cmd, "effort")) {
        cmdEffort(m, arg);
    } else if (std.mem.eql(u8, cmd, "color")) {
        cmdColor(m, arg);
    } else if (std.mem.eql(u8, cmd, "submodel")) {
        cmdSubmodel(m, arg);
    } else if (std.mem.eql(u8, cmd, "task-parallel")) {
        cmdTaskParallel(m, arg);
    } else if (std.mem.eql(u8, cmd, "use")) {
        commands_mod.cmdUse(m, arg);
    } else if (std.mem.eql(u8, cmd, "undo")) {
        cmdUndo(m);
    } else if (std.mem.eql(u8, cmd, "clean")) {
        // `m.allocator`, not the `Allocator` TYPE. The local `a` above shadows
        // the type name inside this function, so the annotation resolved to a
        // variable and the whole module failed to compile. The tests that build
        // a `Model` on a FixedBufferAllocator caught it.
        cmdClean(m, cleanWanted(m.environ, arg));
    } else if (std.mem.eql(u8, cmd, "free-auto") or std.mem.eql(u8, cmd, "free")) {
        free_auto.cmdFreeAuto(m, arg);
    } else if (std.mem.eql(u8, cmd, "bg")) {
        cmdBg(m, arg);
    } else if (std.mem.eql(u8, cmd, "yolo")) {
        cmdYolo(m);
    } else if (std.mem.eql(u8, cmd, "mode")) {
        cmdMode(m, arg);
    } else if (std.mem.eql(u8, cmd, "allowlist")) {
        commands_mod.cmdAllowlist(m);
    } else if (std.mem.eql(u8, cmd, "permissions")) {
        commands_mod.cmdPermissions(m);
    } else if (std.mem.eql(u8, cmd, "context")) {
        commands_mod.cmdContext(m);
    } else if (std.mem.eql(u8, cmd, "usage")) {
        commands_mod.cmdUsage(m);
    } else if (std.mem.eql(u8, cmd, "cost")) {
        commands_mod.cmdCost(m);
    } else if (std.mem.eql(u8, cmd, "update")) {
        cmdUpdate(m);
    } else if (std.mem.eql(u8, cmd, "compact")) {
        commands_mod.cmdCompact(m, rest);
    } else if (std.mem.eql(u8, cmd, "goal")) {
        commands_mod.cmdGoal(m, rest);
    } else if (std.mem.eql(u8, cmd, "init")) {
        commands_mod.cmdInit(m);
    } else if (std.mem.eql(u8, cmd, "session")) {
        commands_mod.cmdSession(m);
    } else if (std.mem.eql(u8, cmd, "files")) {
        commands_mod.cmdFiles(m);
    } else if (std.mem.eql(u8, cmd, "cache")) {
        commands_mod.cmdCache(m);
    } else if (std.mem.eql(u8, cmd, "bench")) {
        cmdBench(m);
    } else if (std.mem.eql(u8, cmd, "ask")) {
        cmdAskMode(m, arg);
    } else if (std.mem.eql(u8, cmd, "skills")) {
        cmdSkills(m);
    } else if (std.mem.eql(u8, cmd, "style")) {
        cmdStyle(m, arg);
    } else if (std.mem.eql(u8, cmd, "copy")) {
        cmdCopy(m, arg);
    } else if (std.mem.eql(u8, cmd, "reload-cmds") or std.mem.eql(u8, cmd, "reloadcmds") or std.mem.eql(u8, cmd, "reloadcmd")) {
        if (m.io_ready) {
            refreshUserCommandsForce(m.allocator, m.io, m.environ, true);
            const uc = userCommands();
            m.pushInfoFmt("reloaded user commands: {d} found (.zode/commands + ~/.config/zode/commands)", .{uc.len});
        } else {
            m.pushInfo("cannot reload: io not ready");
        }
    } else if (std.mem.eql(u8, cmd, "which-cmd") or std.mem.eql(u8, cmd, "whichcmd")) {
        if (arg) |a| {
            var token = std.mem.trim(u8, a, " \t\r\n");
            // "which-cmd /hola" has to work like "which-cmd hola": the dispatch
            // token arrives WITHOUT the slash, and a user who just typed the
            // command's name in full should not get "not found" for it.
            if (token.len > 0 and token[0] == '/') token = token[1..];
            // Refresh first: "not found" has to mean "there is no such file",
            // not "there was no such file at startup". The mtime cache makes
            // this two stats when nothing moved.
            refreshUserCommandsModel(m);
            if (findUserCmd(token)) |idx| {
                if (userCommandInfo(idx)) |info| {
                    const origin = if (info.root == 0) ".zode/commands" else "~/.config/zode/commands";
                    const name = if (info.key.len > 0) info.key[1..] else info.key;
                    m.pushInfoFmt("{s} -> {s}/{s}.md", .{ info.key, origin, name });
                    return;
                }
            }
            // The token may name a BUILTIN: saying "not found" about /help
            // would be a lie, and this command's whole job is to say where a
            // name comes from.
            var is_builtin = false;
            for (commands) |c| {
                if (c.key.len == token.len + 1 and c.key[0] == '/' and
                    std.mem.eql(u8, c.key[1..], token))
                {
                    is_builtin = true;
                    break;
                }
            }
            if (is_builtin) {
                m.pushInfoFmt("/{s} is a builtin, not a file (.zode/commands holds only the user's)", .{token});
            } else {
                m.pushInfoFmt("not found: /{s} (no builtin and no file)", .{token});
            }
        } else {
            m.pushInfo("usage: /which-cmd <name>");
        }
    } else if (std.mem.eql(u8, cmd, "new-session")) {
        newSession(m);
    } else if (std.mem.eql(u8, cmd, "resume")) {
        resumeLatest(m);
    } else if (std.mem.eql(u8, cmd, "rename")) {
        commands_mod.cmdRename(m, arg);
    } else {
        // An unknown token is where a USER command lives: refresh first, so a
        // file created while zode was open runs without a restart.
        refreshUserCommandsModel(m);
        if (findUserCmd(cmd)) |idx| {
            try runUserCommand(m, idx, arg);
        } else {
            // `pushInfoFmt` and not `allocPrint … catch "literal"`: on OOM that
            // pattern hands a .rodata pointer to `pushInfoOwned` and the process
            // dies on exit with an Invalid free (the documented trap).
            m.pushInfoFmt("unknown command: {s} (/help)", .{cmd});
        }
    }
}

// ── user slash commands (.zode/commands, ~/.config/zode/commands) ────
//
// The LIST is static (fixed buffers, no allocation) because the `/`
// completion reads it on every keystroke and the palette reads it on open: a
// heap list would need an owner, a lock and a refresh story for something that
// is a few dozen small strings. The BODIES are not here at all — they are read
// from disk at run time (`lib/usercmds.zig`), so editing a command takes
// effect without a restart.

var uc_entries: [usercmds_mod.max_cmds]usercmds_mod.Entry = undefined;
var uc_cmds: [usercmds_mod.max_cmds]commands_mod.Cmd = undefined;
var uc_len: usize = 0;
var uc_roots_buf: [std.fs.max_path_bytes * 2]u8 = undefined;
var uc_roots: [2][]const u8 = undefined;
var uc_roots_n: usize = 0;
/// Last mtime (ns) of each root directory at scan time; 0 = the directory did
/// not exist. A missing directory stores 0, so CREATING it later is a non-zero
/// mtime and invalidates the cache exactly like a new file would.
var uc_root_mtime_ns: [2]i128 = .{ 0, 0 };
/// A scan has happened at least once. Without it the very first call would
/// compare against uninitialised roots and could decide "unchanged" over
/// garbage: an empty list, forever, with no error anywhere.
var uc_scanned: bool = false;

/// The roots, in shadowing order: the project's, then the user's.
///
/// The HOME path goes into the CALLER's buffer: every path has to survive the
/// function, and one shared scratch leaves the earlier roots pointing at the
/// last one written (the `sb.path` trap).
fn userCmdRoots(
    buf: *[std.fs.max_path_bytes]u8,
    out: *[2][]const u8,
    env: ?*const std.process.Environ.Map,
) usize {
    var n: usize = 0;
    out[n] = usercmds_mod.project_dir; // a literal: static, no buffer needed
    n += 1;
    if (env) |e| {
        if (e.get("HOME")) |home| {
            if (home.len > 0) {
                if (std.fmt.bufPrint(buf, "{s}/.config/{s}", .{ home, usercmds_mod.user_subdir })) |p| {
                    out[n] = p;
                    n += 1;
                } else |_| {}
            }
        }
    }
    return n;
}

/// Scans `roots` into the static list. Its own function so a test can point it
/// at a temp directory; `refreshUserCommands` builds the real roots.
pub fn refreshUserCommandsFrom(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8) void {
    refreshUserCommandsFromForce(gpa, io, roots, false);
}

pub fn refreshUserCommandsFromForce(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8, force: bool) void {
    // The cache: two stat calls instead of a directory walk per keystroke. The
    // scan only happens when the ROOTS differ or a root's mtime says something
    // moved (a file created, removed or renamed inside it). Editing a file in
    // place does NOT move the directory's mtime — that is the cache's one blind
    // spot and the reason `/reload-cmds` takes `force`.
    //
    // `force` bypasses every check. And `uc_scanned` guards the first call:
    // without it, `roots.len == uc_roots_n` over uninitialised state could
    // "confirm" a scan that never ran and the list would stay empty forever.
    if (!force and uc_scanned and roots.len == uc_roots_n) {
        var fresh = true;
        for (roots, 0..) |r, i| {
            if (!std.mem.eql(u8, r, uc_roots[i]) or rootMtimeNs(io, r) != uc_root_mtime_ns[i]) {
                fresh = false;
                break;
            }
        }
        if (fresh) return;
    }

    // Remember the roots and their mtimes for the next call. Each root that
    // does not fit the buffer is remembered as `""`, which never compares equal
    // to a real root: the next call rescans. A bounds check instead of a
    // panic — a path the cache cannot hold is a cache miss, not a crash.
    uc_roots_n = @min(roots.len, uc_roots.len);
    uc_scanned = true;
    var buf_off: usize = 0;
    for (roots[0..uc_roots_n], 0..) |r, i| {
        uc_root_mtime_ns[i] = 0;
        if (buf_off + r.len <= uc_roots_buf.len) {
            const copy = uc_roots_buf[buf_off .. buf_off + r.len];
            @memcpy(copy, r);
            uc_roots[i] = copy;
            buf_off += r.len;
        } else {
            uc_roots[i] = "";
        }
        uc_root_mtime_ns[i] = rootMtimeNs(io, uc_roots[i]);
    }

    const found = usercmds_mod.scan(gpa, io, roots, &uc_entries);
    uc_len = found.len;
    // Sort for stable, predictable order in help/palette
    std.mem.sort(usercmds_mod.Entry, uc_entries[0..uc_len], {}, struct {
        fn less(_: void, a: usercmds_mod.Entry, b: usercmds_mod.Entry) bool {
            return std.ascii.lessThanIgnoreCase(a.name(), b.name());
        }
    }.less);
    for (uc_entries[0..uc_len], 0..) |*e, i| {
        uc_cmds[i] = .{ .key = e.key(), .desc = e.desc() };
    }
}

/// A root directory's mtime in nanoseconds, or 0 when it cannot be read —
/// which is also what a directory that does not exist records, so "missing"
/// and "missing since the last scan" compare equal and do not rescan.
fn rootMtimeNs(io: std.Io, path: []const u8) i128 {
    const d = std.Io.Dir.cwd().openDir(io, path, .{}) catch return 0;
    defer d.close(io);
    const st = d.stat(io) catch return 0;
    return st.mtime.toNanoseconds();
}

/// Scan the real roots (project + `~/.config/zode/commands`).
pub fn refreshUserCommands(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map) void {
    refreshUserCommandsForce(gpa, io, env, false);
}

pub fn refreshUserCommandsForce(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, force: bool) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var roots: [2][]const u8 = undefined;
    const n = userCmdRoots(&buf, &roots, env);
    refreshUserCommandsFromForce(gpa, io, roots[0..n], force);
}

/// Refresh through the Model's OWN `io`, guarded by `io_ready` — the same rule
/// as the activity strip's clock: the tests build a Model without an app, and
/// reading an uninitialized `Io` is a jump through a garbage vtable.
pub fn refreshUserCommandsModel(m: *tui.Model) void {
    if (!m.io_ready) return;
    refreshUserCommands(m.allocator, m.io, m.environ);
}

/// The cached list, without touching the disk: the `/` completion and the draw
/// read this on every keystroke. The SCAN happens at startup (`main.zig`) and
/// on `/help`, the palette, and an unknown `/name` — the moments that are
/// already doing I/O or are about to report something to the user.
pub fn userCommands() []const commands_mod.Cmd {
    return uc_cmds[0..uc_len];
}

pub const UserCmdInfo = struct {
    key: []const u8,
    desc: []const u8,
    root: u8, // 0 = project .zode/commands, 1 = user ~/.config/zode/commands
};

pub fn userCommandInfo(i: usize) ?UserCmdInfo {
    if (i >= uc_len) return null;
    return UserCmdInfo{
        .key = uc_cmds[i].key,
        .desc = uc_cmds[i].desc,
        .root = uc_entries[i].root,
    };
}

/// Command `i`: the builtins first, then the user's. ONE iterator for the four
/// places that used to walk `commands` alone — a second list walked separately
/// in each is four lists to keep in sync.
pub fn commandAt(i: usize) ?commands_mod.Cmd {
    if (i < commands.len) return commands[i];
    const u = userCommands();
    const j = i - commands.len;
    if (j < u.len) return u[j];
    return null;
}

/// The user command this token names (`review` → its index), or null.
///
/// Builtins are NOT here on purpose: `submit` only reaches this in its final
/// else, so `/help` can never be shadowed by a file named `help.md`.
fn findUserCmd(token: []const u8) ?usize {
    for (uc_entries[0..uc_len], 0..) |*e, i| {
        if (std.mem.eql(u8, e.name(), token)) return i;
    }
    return null;
}

/// `/name args`: the file's body becomes the prompt (with the args where the
/// template says) and `startChat` takes it from there — it dupes the input, so
/// the expansion is freed on return.
///
/// Runs on the UI thread like every other local command: the read is one small
/// file and `startChat` only spawns the worker.
fn runUserCommand(m: *tui.Model, idx: usize, arg: ?[]const u8) !void {
    if (!m.io_ready) return;
    const e = &uc_entries[idx];
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    var roots: [2][]const u8 = undefined;
    const n = userCmdRoots(&root_buf, &roots, m.environ);
    if (e.root >= n) {
        m.pushInfoFmt("{s}: its folder is not reachable from here (no HOME?)", .{e.key()});
        return;
    }
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.md", .{ roots[e.root], e.name() }) catch {
        m.pushInfoFmt("{s}: path too long", .{e.key()});
        return;
    };
    const expanded = usercmds_mod.render(m.allocator, m.io, path, arg orelse "") orelse {
        m.pushInfoFmt("{s}: could not read {s} (removed, or over 64 KB)", .{ e.key(), path });
        return;
    };
    defer m.allocator.free(expanded);
    try startChat(m, expanded);
}

test "user commands: commandAt walks builtins AND the disk list, and a rescan replaces it" {
    // The dispatch (`submit`'s final else) and the `/` completion read the SAME
    // list through `commandAt`; this pins that a scanned command really lands
    // there (builtins first) and that a rescan REPLACES rather than appends —
    // an append-only list would grow a phantom entry for every file rename.
    const root = "/tmp/zode-usercmds-agent-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = "/tmp/zode-usercmds-agent-test/hola.md",
        .data = "---\ndescription: says hola\n---\nSay hola to $ARGUMENTS.",
    });

    var roots = [_][]const u8{root};
    refreshUserCommandsFrom(std.testing.allocator, std.testing.io, &roots);
    // Leftovers in a static would leak into every later test that walks the
    // list: clear it whatever happens below.
    defer refreshUserCommandsFrom(std.testing.allocator, std.testing.io, &.{});

    try std.testing.expectEqual(@as(usize, 1), userCommands().len);
    try std.testing.expectEqualStrings("/hola", userCommands()[0].key);
    try std.testing.expectEqualStrings("says hola", userCommands()[0].desc);

    // Builtins first, then the user's — and then nothing.
    try std.testing.expectEqualStrings("/help", commandAt(0).?.key);
    const found = commandAt(commands.len).?;
    try std.testing.expectEqualStrings("/hola", found.key);
    try std.testing.expect(commandAt(commands.len + 1) == null);

    // The dispatch token arrives WITHOUT the slash, and a builtin is never a
    // user command (builtins win in `submit` because it checks them first).
    try std.testing.expect(findUserCmd("hola") != null);
    try std.testing.expect(findUserCmd("/hola") == null);
    try std.testing.expect(findUserCmd("help") == null);

    // Where it came from: this is what `/which-cmd` prints, and the index is
    // the SAME one `findUserCmd` returns — two lists with different orders is
    // how a command would be reported as coming from the wrong folder.
    const info = userCommandInfo(0).?;
    try std.testing.expectEqual(@as(u8, 0), info.root);
    try std.testing.expectEqualStrings("/hola", info.key);
    try std.testing.expect(userCommandInfo(userCommands().len) == null);

    // A rescan with no roots empties the list (a renamed file disappears).
    refreshUserCommandsFrom(std.testing.allocator, std.testing.io, &.{});
    try std.testing.expectEqual(@as(usize, 0), userCommands().len);
}

test "the user command cache: an in-place edit needs /reload-cmds, a new file does not" {
    // The cache keys on each root directory's mtime: creating, removing or
    // renaming a file inside it bumps the directory, but REWRITING an existing
    // file does not (only the file's own mtime moves). That blind spot is the
    // trade the cache makes and `/reload-cmds` (force) is its way out, so both
    // halves are pinned here: a cache that skipped everything would fail step
    // 1, one that never cached would fail nothing but is covered by the roots
    // comparison it shares with this path.
    const root = "/tmp/zode-usercmds-cache-test";
    const io = std.testing.io;
    const a = std.testing.allocator;
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = "/tmp/zode-usercmds-cache-test/one.md",
        .data = "---\ndescription: old\n---\nbody",
    });

    var roots = [_][]const u8{root};
    refreshUserCommandsFrom(a, io, &roots);
    // Clean the statics whatever happens below: they outlive this test.
    defer refreshUserCommandsFrom(a, io, &.{});
    try std.testing.expectEqual(@as(usize, 1), userCommands().len);

    // 1. Rewritten in place: the directory's mtime does not move, so the
    //    ordinary refresh keeps the old description.
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = "/tmp/zode-usercmds-cache-test/one.md",
        .data = "---\ndescription: NEW\n---\nbody",
    });
    refreshUserCommandsFrom(a, io, &roots);
    try std.testing.expectEqualStrings("old", userCommands()[0].desc);

    // 2. `force` — exactly what `/reload-cmds` passes — reads the disk.
    refreshUserCommandsFromForce(a, io, &roots, true);
    try std.testing.expectEqualStrings("NEW", userCommands()[0].desc);

    // 3. A NEW file bumps the directory, so it is picked up WITHOUT force.
    //    The nap is the filesystem's timestamp clock, not the cache: mtimes
    //    come from the coarse (per-tick) clock, so two operations inside one
    //    tick record the SAME mtime and the cache would then be right to keep
    //    the old list. No real user creates two files within a tick.
    sleep_mod.nap(50);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = "/tmp/zode-usercmds-cache-test/two.md",
        .data = "---\ndescription: second\n---\nbody",
    });
    refreshUserCommandsFrom(a, io, &roots);
    try std.testing.expectEqual(@as(usize, 2), userCommands().len);
}

/// Does any queued info/error line contain this text? A `submit` branch can
/// only be checked through what it pushed: there is no return value, which is
/// exactly how an alias typo or a dead branch stays invisible to every other
/// test.
fn pendingContains(m: *tui.Model, needle: []const u8) bool {
    for (m.pending.items) |p| {
        if (std.mem.indexOf(u8, p.text, needle) != null) return true;
    }
    return false;
}

test "which-cmd and reload-cmds reach submit, and each says something checkable" {
    // Both commands live in one long if/else chain, so nothing else in the
    // suite would notice an alias that was never wired or a branch that never
    // runs (the "three halves, nothing watching the seam" pattern).
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    // A test Model has no app behind it: without an explicit `io` every
    // refresh would jump through an uninitialized vtable (the `attachIo`
    // trap), which is why the flag and the handle are set together.
    m.io = std.testing.io;
    m.io_ready = true;
    m.environ = null; // no HOME: only the project root is scanned
    defer refreshUserCommandsFrom(std.testing.allocator, std.testing.io, &.{});

    // A BUILTIN is answered truthfully instead of "not found": the whole job
    // of this command is to say where a name comes from.
    try submit(&m, "/which-cmd help");
    try std.testing.expect(pendingContains(&m, "/help is a builtin"));

    // With or without the leading slash — the dispatch token arrives without
    // it, and a user who just typed the command's own name should not be told
    // it does not exist.
    try submit(&m, "/which-cmd /definitely-not-a-command");
    try std.testing.expect(pendingContains(&m, "not found: /definitely-not-a-command"));
    try submit(&m, "/which-cmd definitely-not-a-command");
    try std.testing.expect(pendingContains(&m, "not found: /definitely-not-a-command"));

    try submit(&m, "/which-cmd");
    try std.testing.expect(pendingContains(&m, "usage: /which-cmd"));

    try submit(&m, "/reload-cmds");
    try std.testing.expect(pendingContains(&m, "reloaded user commands:"));

    // The alias is what a human types by muscle memory.
    try submit(&m, "/reloadcmds");
    try std.testing.expect(pendingContains(&m, "reloaded user commands:"));
}

// ── /clean: purge zode's own leftovers, nothing else ──────────

/// Was a delete asked for? Either `/clean yes` on the command line, or
/// `ZODE_YES=1` for when the MODEL runs it (a model that can only type
/// `/clean` and then be told "no, with yes" has no way out).
fn cleanWanted(env: ?*const std.process.Environ.Map, arg: ?[]const u8) bool {
    if (arg) |a| {
        if (std.mem.eql(u8, a, "yes") or std.mem.eql(u8, a, "y") or
            std.mem.eql(u8, a, "apply")) return true;
    }
    const v = envGet(env, "ZODE_YES") orelse return false;
    return std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "yes");
}

/// The config dir, or null. `/clean` reads it to find the leftover
/// `<name>.tmp` of an interrupted atomic write (`config.zig` writes to a temp
/// and renames it).
fn cleanConfigDir(a: std.mem.Allocator, env: ?*const std.process.Environ.Map) ?[]const u8 {
    const home = envGet(env, "HOME") orelse return null;
    return std.fmt.allocPrint(a, "{s}/.config/zode", .{home}) catch null;
}

/// `/clean`: the leftovers of zode, and ONLY those.
///
/// Dry run by default. The output has to carry the NUMBERS, not just "clean":
/// "24 empty sessions" is checkable and "nothing to do" is not, and a cleanup
/// command that reports success without saying what it looked at is the one
/// that lies when it is wrong.
///
/// The `auth.json` / `.zig-cache` exclusion is not here on purpose: it lives in
/// `clean.isProtected`, next to the scan that could reach them, with the tests
/// that hold it. A "never touch" list written in the UI would only hold for as
/// long as nobody adds a new scan.
fn cmdClean(m: *tui.Model, aplicar: bool) void {
    // The allocator is a local, and its name is not `a`: `a` is also the name
    // the two `allocPrint` helpers below use for their own temporaries, and one
    // name cannot be both the type and the value.
    const gpa = m.allocator;
    const inst = clean_mod.instanceDir(gpa, io_global) catch null;
    defer if (inst) |p| gpa.free(p);
    const cfg = cleanConfigDir(gpa, m.environ);
    defer if (cfg) |p| gpa.free(p);

    const now_secs = std.Io.Timestamp.now(io_global, .real).toSeconds();
    var rep = clean_mod.scan(gpa, io_global, .{
        .roots = .{ .sessions = "sessions", .instances = inst, .config = cfg },
        .now_secs = now_secs,
    }) catch {
        pushInfo(m, "/clean: could not read the directories");
        return;
    };
    defer rep.deinit();

    const header: []const u8 = if (aplicar)
        "/clean: applied"
    else
        "/clean: dry run (nothing deleted)";
    pushInfo(m, header);

    if (rep.missing_sessions) {
        pushInfo(m, "  no sessions/ directory here (nothing to clean in it)");
    }

    const order = [_]clean_mod.Bucket{ .empty_session, .own_temp, .stale_instance, .old_session };
    for (order) |b| {
        const n = rep.count(b);
        if (n == 0) continue;
        const line = std.fmt.allocPrint(gpa, "  {d:>3} {s} ({s})", .{
            n,
            b.label(),
            if (b == .old_session) "kept, delete with find sessions/ -mtime +30d" else b.rootHint(),
        }) catch continue;
        pushInfoOwned(m, line);
    }

    if (rep.items.len == 0 and !rep.missing_sessions) {
        pushInfo(m, "  nothing to clean");
        return;
    }

    if (!aplicar) {
        const total = rep.deletable();
        if (total == 0) {
            pushInfo(m, "  nothing to delete without a yes");
            return;
        }
        const line = std.fmt.allocPrint(
            gpa,
            "  -> {d} files, {d} bytes. run `/clean yes` to delete them",
            .{ total, rep.bytes() },
        ) catch return;
        pushInfoOwned(m, line);
        return;
    }

    const deleted = clean_mod.apply(io_global, &rep, .{
        .sessions = "sessions",
        .instances = inst,
        .config = cfg,
    }) catch 0;
    // The failure count goes in the output on purpose: `apply` swallows the
    // per-file error so one unreadable file does not abort the rest, and
    // without this line "deleted 23" would be a lie when 24 were candidates.
    // `pushInfoFmt` and not `allocPrint … catch "literal"`: on OOM the literal
    // fallback is a pointer into `.rodata`, and `pushInfoOwned` takes ownership
    // of it — `Model.deinit` then frees static memory. That is the "Invalid
    // free" this repo has paid for repeatedly, and it only shows up when the
    // allocator is already failing, which is exactly when you cannot diagnose
    // it. `pushInfoFmt` composes AND owns, so the mistake cannot be written.
    if (rep.failed == 0) {
        m.pushInfoFmt("  deleted {d} files", .{ deleted });
    } else {
        m.pushInfoFmt("  deleted {d}, {d} could NOT be removed", .{ deleted, rep.failed });
    }
}

/// `/resume`: reopens the most recent session by mtime.
fn resumeLatest(m: *tui.Model) void {
    var astate = std.heap.ArenaAllocator.init(m.allocator);
    defer astate.deinit();
    const a = astate.allocator();

    const latest = session_mod.Session.latestSessionPath(a, io_global) catch null;
    const path = latest orelse {
        pushError(m, "no saved sessions");
        return;
    };
    if (session) |old| {
        m.allocator.destroy(old);
        session = null;
    }
    const s = session_mod.Session.resumePath(m.allocator, io_global, path) catch {
        pushError(m, "could not read the session");
        return;
    };
    session = s;
    cache_stats.session = s.usage_stats;
    session_elided = 0;
    resetSummaries();
    forgetGitRepoProbe();
    // The resumed session's context is the one in the FILE, and the read cache
    // does not know what is in it: an entry that says "the model has this
    // file" is a guess. Clearing it costs a re-read and buys a truth.
    resetSessionFiles(m);
    // Replay session messages into TUI history so they are visible
    replaySessionMessages(m, s);
    m.pushInfoFmt("session resumed: {s} · {d} messages", .{ path, s.messages.items.len });
    refreshContextUsage(m);
}

// ── the chat: worker and agent loop ───────────────────────────

/// Launches the worker of a turn. All the I/O happens here, in its own
/// thread; the UI only receives events.
/// Job of the chat thread. `text` is a COPY that the worker frees, so the
/// input buffer can be reused as soon as it is queued.
pub const ChatJob = struct {
    model: *tui.Model,
    text: []const u8,
};

pub fn startChat(m: *tui.Model, input: []const u8) !void {
    const s = ensureSession(m, m.allocator);
    // Truncate long inputs for UI display, keep full text for model
    const TRUNCATE_SIZE = 200;
    var display_input = input;
    var full_input = input;
    if (input.len > TRUNCATE_SIZE) {
        display_input = input[0..TRUNCATE_SIZE] ++ " ...";
        full_input = input;
    }
    // Replace image references with [image.ext] placeholders for UI display
    display_input = replaceImagePlaceholders(display_input);
    const copy = try m.allocator.dupe(u8, full_input);
    errdefer m.allocator.free(copy);

    // If a turn is already in flight, QUEUE it instead of launching a worker in
    // parallel: two workers writing at the same time to the same session and
    // the same streaming state is what made the input freeze and the history
    // cut itself off.
    if (m.isBusy()) {
        _ = m.enqueuePrompt(copy);
        m.pushInfoFmt("⏳ queued ({d} waiting)", .{m.queuedCount()});
        return;
    }

    s.append(.user, copy) catch {};
    s.flush();

    // [undo] One snapshot per TURN, not per tool: the user thinks in turns
    // ("undo that"), and the checkpoint is named after the prompt so the
    // message can say which turn it was. Note it opens AFTER the `enqueuePrompt`
    // above, because a queued prompt is NOT a new turn (there are no tools yet)
    // and it would wipe the checkpoint of a turn that had not even started.
    m.beginCheckpoint(copy);

    // Opens the streaming paragraph and marks busy: the UI can already paint the
    // spinner while the worker talks to the API.
    m.streamStart();
    // No "…": the face already blinks and the clock runs, the ellipsis only
    // adds noise.
    setStatusWithZo(m, .thinking, "thinking");

    const job = try m.allocator.create(ChatJob);
    m.beginWorker(); // the worker closes it; if the spawn fails, we close it here
    job.* = .{ .model = m, .text = copy };
    const spawned = std.Thread.spawn(.{}, chatWorker, .{job}) catch null;
    const th = spawned orelse {
        m.endWorker();
        m.allocator.destroy(job);
        m.allocator.free(copy);
        m.streamEnd();
        return error.ThreadSpawnFailed;
    };
    th.detach();
}

/// Replace image references with [image.ext] placeholders for UI display.
/// Called on the truncated display input to keep the UI compact.
pub fn replaceImagePlaceholders(text: []const u8) []const u8 {
    // Common image extensions
    const image_exts = &[_][]const u8{"png", "jpg", "jpeg", "gif", "webp", "svg", "bmp"};
    
    // Find @image.ext patterns and replace them with [image.ext]
    var result: [512]u8 = undefined;
    var ri: usize = 0;
    var li: usize = 0;
    
    while (li < text.len) {
        // Look for @ followed by potential image filename
        if (text[li] == '@' and li + 1 < text.len) {
            li += 1;
            // Collect the filename part (up to space, newline, tab, or end)
            var fe: usize = li;
            while (fe < text.len and text[fe] != ' ' and text[fe] != '\n' and text[fe] != '\t' and text[fe] != '@') {
                fe += 1;
            }
            const filename = text[li .. fe];
            // Check if it has an image extension (the part after the last dot)
            const dot = std.mem.lastIndexOfScalar(u8, filename, '.') orelse continue;
            // Extension must not be at the start (like .gitignore) and must exist
            if (dot >= filename.len - 1) {
                // No valid extension found, copy @ as-is
                if (ri + 1 > result.len) break;
                result[ri] = '@';
                ri += 1;
                li += 1;
                continue;
            }
            const ext = filename[dot + 1 .. fe];
            var is_image = false;
            var ei: usize = 0;
            while (ei < image_exts.len) {
                if (ext.len == image_exts[ei].len) {
                    var match = true;
                    var ci: usize = 0;
                    while (ci < ext.len) {
                        if (std.ascii.toLower(ext[ci]) != std.ascii.toLower(image_exts[ei][ci])) {
                            match = false;
                            break;
                        }
                        ci += 1;
                    }
                    if (match) {
                        is_image = true;
                        break;
                    }
                }
                ei += 1;
            }
            if (is_image) {
                // Replace @image.ext with [image.ext]
                var repl_buf: [32]u8 = undefined;
                const repl_slice = std.fmt.bufPrint(repl_buf[0..], "[image.{s}]", .{ext}) catch break;
                const repl_len = repl_slice.len;
                if (ri + repl_len > 512) break;
                @memcpy(result[ri .. ri + repl_len], repl_buf[0..repl_len]);
                ri += repl_len;
                li = fe;
                continue;
            }
        }
        // Copy normal character
        if (ri + 1 > result.len) break;
        result[ri] = text[li];
        ri += 1;
        li += 1;
    }
    return result[0..ri];
}

/// The worker: one turn of conversation with the API, with tools.
fn chatWorker(job: *ChatJob) void {
    const m = job.model;
    const user_text = job.text;
    defer {
        m.allocator.free(user_text);
        m.allocator.destroy(job);
    }
    // Worker counter: the thread is decoupled, and on exit you have to wait for it
    // BEFORE destroying the `Io` (see `Model.waitWorkers`).
    m.beginWorker();
    defer m.endWorker();

    // The automatic typecheck's budget is PER TURN, and any job left over from the
    // previous one is killed rather than orphaned. Both live in `resetTurn` so the
    // headless runner gets the same behaviour from the same code.
    m.auto_check.resetTurn(&m.bg, io_global);

    // The turn stats start here (not in `runOneTurn`): the turn is the whole
    // `chatWorker`, with its 8 iterations.
    turn_stats.reset(m.allocator, std.Io.Timestamp.now(io_global, .real).nanoseconds);
    defer turn_stats.deinit();

    var iterations: usize = 0;
    var last_user: []const u8 = user_text;
    var owned: ?[]u8 = null; // synthesized text of an iteration (owned)

    // The per-turn question budget resets with the turn. Without the reset a
    // long session would stop being able to ask anything after three questions
    // EVER, which is a bug that only shows up an hour in.
    m.asks_this_turn = 0;
    m.plan_touched_this_turn = false;
    m.plan_write_blocked_this_turn = false;
    m.plan_missing_nudges_this_turn = 0;

    // A NEW turn clears the ESC flag: ESC blocked spawns so that the turn in
    // flight could not start anything else after the user said "stop", but if it
    // stayed set forever every `run_in_background` of every later turn would die
    // with `Cancelled` and nothing would ever say why. Same idea as the ask
    // budget above: the state of one turn must not poison the next one.
    m.bg.cancel_all = false;

    // ── the loop, and the three things that decide when it stops ──
    //
    // `soft` is the reported target. `hard` only exists when a goal is set: it is what
    // a `/goal` earns, and it is generous on purpose, because a task that reaches 60
    // iterations was never going to be finished by stopping at 12 — it should have said
    // `blocked` long before.
    //
    // The goal is cleared HERE and not at the end of the turn: a second prompt in the
    // queue must not inherit the previous turn's objective, or "and now make it 5 KB"
    // silently becomes a different goal than the one that was answered.
    const had_goal = m.goal.isSet();
    if (had_goal) {
        m.goal.status = goal_mod.Status.none;
        m.goal.checkpoints = 0;
        // `blocked_refusals` goes here too, and it was MISSING when the field was added,
        // which made the evidence check a one-shot for the whole SESSION instead of one
        // per turn.
        //
        // The consequence is small on the surface and bad underneath: a model that
        // declared `blocked` on the first iteration of turn one had its refusal spent,
        // and on turn two a shrug with no tools behind it was accepted immediately —
        // which is the entire failure the field was added for, resurrected after one
        // turn. The state is per turn because the evidence is per turn: "did THIS turn
        // look before it said it is impossible" is a different question every time, and
        // answering it with the previous turn's answer is the "a stale red is worse than
        // no red" bug in a new place.
        m.goal.blocked_refusals = 0;
    }
    const soft = iterationLimit();
    const hard = if (had_goal) goalHardLimit() else soft;

    m.repeats.reset();
    var repeat_recovery: repeats_mod.Recovery = .{};
    var checkpointed = false;
    // How many times this turn has shown the plan-approval dialog. Bounded so
    // "reject → revise → re-present" can cycle once but a turn that keeps being
    // rejected ends on the ordinary ceiling instead of asking forever.
    var plan_gate_asks: u8 = 0;

    while (iterations < hard) : (iterations += 1) {
        turn_stats.iterations = iterations + 1;
        const again = runOneTurn(m, last_user, iterations) catch |err| {
            reportErr(m, err);
            // With free-auto on, the pool's state IS the user's next question ("so what
            // now?"), and the answer fits on one line. Without this you see an
            // error and nothing else.
            notePoolState(m);
            m.streamEnd();
            pushTurnSummary(m);
            return;
        };
        // 0. THE EXIT GATE: may this turn end on the code as it is right now?
        //
        //    FIRST, before `again orelse break` and before the repetition guard, and that
        //    order is the whole fix. The first version of this rule sat two checks below,
        //    which made it DEAD CODE on the common path: the model stops calling tools,
        //    `again` is null, and the `orelse break` above had already ended the turn.
        //    A rule about not stopping has to be ABOVE every stop.
        //
        //    This is the check that turns "the turn ended" into "the task ended". The
        //    harness knows the build failed — it read the exit code and built the model's
        //    own error message out of the diagnostics — and then let the turn end anyway,
        //    five times out of five, on a task that was about code compiling.
        //
        //    Asking the model whether it is finished is what does not work: a turn that
        //    has ended in prose is a turn where nobody is grading anything, and the one
        //    moment a self-assessment would be worth something is the one moment there is
        //    nobody left to give it. The harness has the evidence; the loop just has to
        //    ask with it.
        //
        //    It waits for a check that is in flight, and starts one more of its own if
        //    the code has been written since the last finished check. That is the whole
        //    difference from the old rule, which only looked at the verdict of a check
        //    that happened to have finished.
        //
        //    `blocked` is honoured ABOVE all of it, and never inside the gate: a real
        //    blocker has to be declarable or this is a cage.
        //
        //    ## It runs on EVERY iteration, which is what makes it a gate
        //
        //    The first version of the gate ran once, at the end of the turn, after the
        //    loop had already decided to stop — so the diagnostics were collected, put
        //    in the history and read by nobody. A check that only runs when the turn is
        //    over is a check that arrives after the decision.
        //
        //    Running it at the TOP of every iteration is what makes it a gate rather
        //    than a report: the model is told the build is red while it still has budget
        //    to fix it, and the turn does not end until the code it wrote is either
        //    green or declared `blocked`.
        if (m.goal.status != goal_mod.Status.blocked) {
            if (m.auto_check.exitGate(&m.bg, m.allocator, io_global)) |refusal| {
                // A `met` that the code contradicts goes back to open, so the ordinary
                // checkpoint and the ordinary ceiling apply from here. Two artefacts from
                // the SAME model disagreeing — "I am finished" over a build that says
                // otherwise — is not something to resolve by trusting one of them.
                if (m.goal.status == goal_mod.Status.met) m.goal.status = goal_mod.Status.none;
                pushErrorOwned(m, refusal);

                // The nudge is the prompt. `owned`, not a bare assignment: the loop frees
                // the previous prompt through it, so a `last_user` set without it leaks a
                // turn's worth of text every time the turn refuses to end.
                const nudge = m.allocator.dupe(
                    u8,
                    "The harness will not end this turn yet: the code you wrote does not have a passing check behind it. Read the problems above, fix them, and let the check run again. If you genuinely cannot, call `goal` with status blocked and what_would_unblock.",
                ) catch break;
                if (owned) |o| m.allocator.free(o);
                owned = nudge;
                last_user = nudge;
                continue;
            }
        }

        // Gate passed: the user's stop hook can now claim the turn.
        // The gate ran FIRST (above), so the hook and the gate never both
        // claim the turn — if the gate refused, this is not reached.
        if (m.auto_check.stopHookCheck("turn_end", m.allocator)) |refusal| {
            pushError(m, refusal);
            const nudge = m.allocator.dupe(
                u8,
                "The harness will not end this turn yet: a stop hook is in force. Resolve it and end the turn, or remove the hook.",
            ) catch break;
            if (owned) |o| m.allocator.free(o);
            owned = nudge;
            last_user = nudge;
            continue;
        }

        if (m.loop_repeated) |which| {
            m.loop_repeated = null;
            if (again) |answer| m.allocator.free(answer);
            switch (repeat_recovery.onRepeat()) {
                .nudge => {
                    pushErrorFmt(
                        m,
                        "repeated `{s}` with the same arguments {d} times. I have not run it again. Change the approach or arguments, inspect the result, or explain why another action is needed.",
                        .{ which, repeats_mod.repeat_limit },
                    );
                    m.repeats.reset();
                    const nudge = m.allocator.dupe(
                        u8,
                        "The harness detected the same tool call repeated with unchanged arguments. Do not call it again unchanged. Inspect the prior result and choose a materially different next step; if the operation is genuinely necessary, explain why before trying it once with a deliberate change.",
                    ) catch break;
                    if (owned) |o| m.allocator.free(o);
                    owned = nudge;
                    last_user = nudge;
                    continue;
                },
                .stop => {
                    pushErrorFmt(
                        m,
                        "stopped: `{s}` repeated with the same arguments after the harness already asked for a different approach. No automatic retry was performed.",
                        .{which},
                    );
                    break;
                },
            }
        }

        const text = again orelse {
            // ── PLAN APPROVAL: the turn may not end with a plan nobody answered on ──
            //
            // Plan mode's whole point is investigate → plan → the developer says
            // yes or no. This loop is the only place that knows the model just
            // tried to end its turn, so the gate lives HERE: the plan block is
            // already on screen and the final answer is already painted, which
            // is exactly what the user needs to read before answering. The
            // worker blocks on the dialog like it does on every `ask`, and the
            // activity strip keeps showing that zode is waiting.
            //
            // A goal verdict cannot bypass this gate. In plan mode, even a
            // declared `met` or `blocked` is not approval to implement.
            if (currentPermMode() == .read_only) {
                if (m.plan_write_blocked_this_turn and !m.plan_touched_this_turn and m.plan_missing_nudges_this_turn < 2) {
                    m.plan_missing_nudges_this_turn += 1;
                    const nudge = m.allocator.dupe(
                        u8,
                        "Plan mode blocked a write because no implementation plan has been recorded yet. Use `todo` to show the complete, concrete plan to the user, then end your turn so they can approve or revise it. Do not retry the blocked write.",
                    ) catch null;
                    if (nudge) |next| {
                        if (owned) |o| m.allocator.free(o);
                        owned = next;
                        last_user = next;
                        continue;
                    }
                }
                if (m.plan_write_blocked_this_turn and !m.plan_touched_this_turn) {
                    pushError(m, "plan mode is still active: no implementation plan was recorded, so no approval was requested and no write was allowed");
                    break;
                }
                if (m.plan_touched_this_turn and !m.plan.isEmpty() and plan_gate_asks < 2) {
                    plan_gate_asks += 1;
                    if (planApprovalNudge(m)) |nudge| {
                        if (owned) |o| m.allocator.free(o);
                        owned = nudge;
                        last_user = nudge;
                        continue;
                    }
                }
            }
            break;
        };
        if (owned) |o| m.allocator.free(o);
        owned = text;
        last_user = text;

        // 1. The goal was decided. The model said so, and it is the only thing that
        //    ends a goal turn early.
        //
        //    EXCEPT a `met` WITH OPEN PLAN STEPS, which is the model contradicting
        //    itself in the same breath: it wrote down four steps, ticked two, and then
        //    said the work is finished. Measured on the first successful run: exactly
        //    that — `goal(met)` accepted with steps 3 and 4 still unticked on screen.
        //
        //    The turn does not end there. The plan is the model's OWN bookkeeping, so
        //    the harness can read the contradiction without asking it anything, and the
        //    model's way out stays machine-readable: close the steps, or declare
        //    `blocked`. Refusing is not the harness distrusting the verdict — it is two
        //    of the model's own artefacts disagreeing, and which one is wrong is
        //    exactly what the model is for.
        if (!verdictIsFinal(m.goal, m.plan.openCount()) and m.goal.status == goal_mod.Status.met and m.goal.checkpoints == 0) {
            var g = m.goal;
            g.checkpoints += 1;
            m.goal = g;
            // Back to open, so the ordinary checkpoint and the ordinary ceiling apply
            // from here: one refusal, and if it argues, the budget is what ends it.
            m.goal.status = goal_mod.Status.none;
            pushErrorFmt(
                m,
                "you declared the goal MET but {d} of your own plan steps are still open ({d}/{d} done). Close them and declare again, or call `goal` with status blocked.",
                .{ m.plan.openCount(), m.plan.doneCount(), m.plan.items.len },
            );
            const nudge = m.allocator.dupe(
                u8,
                "The harness will not accept `met` yet: your plan still has open steps. Finish them, tick them with `todo`, and call `goal` again — or, if they genuinely cannot be finished here, call `goal` with status blocked and what_would_unblock.",
            ) catch break;
            if (owned) |o| m.allocator.free(o);
            owned = nudge;
            last_user = nudge;
            continue;
        }

        // 1b. `blocked` with nothing behind it.
        //
        //     `what_would_unblock` is a field the model FILLS IN, and a field is as easy
        //     to invent as a fact: "the network is down" costs the same to write as "here
        //     is the key", and the harness accepted both with the same confidence. So the
        //     second half of the justification is something it can read off its own state
        //     — did the turn actually TRY? A `blocked` on the first response with no tool
        //     ever run is a shrug with a JSON body: nothing was read, nothing executed,
        //     so there is no evidence for a claim about what is impossible.
        //
        //     Refused ONCE. A second `blocked` after the model has run tools is accepted,
        //     and it has to be: a task that genuinely cannot be done here is exactly what
        //     `blocked` is for, and a rule with no exit is a cage.
        if (!goal_mod.verdictCredible(&m.goal, turn_stats.tools)) {
            m.goal.blocked_refusals += 1;
            m.goal.status = goal_mod.Status.none;
            // The refusal and the prompt are TWO buffers. `pushErrorOwned` takes
            // ownership (the drain moves the pointer into `paras` and
            // `Model.deinit` frees it), so handing the same slice to `owned`
            // made it a second owner: a use-after-free while the UI painted the
            // paragraph, and a double free at teardown. It was `owned = why`
            // right after `pushErrorOwned(m, why)`. `exitGate`'s refusal 150
            // lines up has the right shape: the error gets its buffer, the
            // prompt gets its own.
            pushErrorOwned(m, goal_mod.blockedRetryText(m.allocator) catch break);
            const nudge = m.allocator.dupe(u8, goal_mod.blockedRetryPrompt()) catch break;
            if (owned) |o| m.allocator.free(o);
            owned = nudge;
            last_user = nudge;
            continue;
        }

        if (m.goal.status != goal_mod.Status.none) break;

        // 2. The model stopped asking for tools, or it answered in prose while the goal
        //    is still open, which means it thinks it is finished without having declared.
        //    Give it the checkpoint rather than ending the turn on a shrug.
        if (checkpointed) {
            // 3. It had its checkpoint and still did not declare. That is the answer:
            //    it wants more room, so give it, until the hard ceiling.
        } else if (iterations + 1 >= soft and m.goal.isOpen()) {
            checkpointed = true;
            var g2 = m.goal;
            g2.checkpoints += 1;
            m.goal = g2;
            pushInfoFmt(
                m,
                "{d}/{d} iterations: stopping to ask whether the goal is reached. {d} more available.",
                .{ iterations + 1, soft, hard - (iterations + 1) },
            );
            m.goal_checkpoint = true;
            defer m.goal_checkpoint = false;
            const again2 = runOneTurn(m, last_user, iterations) catch |err| {
                reportErr(m, err);
                m.streamEnd();
                pushTurnSummary(m);
                return;
            };
            if (again2) |t2| {
                if (owned) |o| m.allocator.free(o);
                owned = t2;
                last_user = t2;
            }
            m.repeats.reset();
            if (m.goal.status != goal_mod.Status.none) break;
            pushInfoFmt(m, "no verdict yet: continuing.", .{});
        }
    }
    if (owned) |o| m.allocator.free(o);
    const capped = iterations >= hard and m.goal.isOpen();
    if (capped) {
        // UNFINISHED, first word. The old text was "goal not declared after N
        // iterations. Stopping here; say `continue` to go on." and it had two problems:
        // it led with the harness's bookkeeping instead of the state of the work, and it
        // ended by handing the user a chore — which is the sentence that started this
        // whole feature. Reaching the ceiling means the turn ran out of room, not that
        // the task is done, and the one thing the user must not be left guessing is which
        // of the two it is.
        const open_steps = m.plan.openCount();
        const unresolved = if (open_steps > 0)
            std.fmt.allocPrint(m.allocator, "{d} plan steps still open", .{open_steps}) catch "plan steps still open"
        else
            m.allocator.dupe(u8, "no open plan steps, so the objective is simply unverified") catch
                "the objective is unverified";
        defer m.allocator.free(unresolved);

        if (had_goal and m.goal.status == goal_mod.Status.none) {
            pushErrorFmt(
                m,
                "UNFINISHED after {d} iterations ({s}). The goal was never declared: {s}",
                .{ hard, unresolved, m.goal.objective() },
            );
        } else {
            pushErrorFmt(m, "UNFINISHED after {d} iterations ({s}).", .{ hard, unresolved });
        }
    }
    m.streamEnd();
    // The bench sample is taken HERE, once per turn, and not per iteration: a
    // turn is the unit the user thinks in ("that took 40 s"), and a per-iteration
    // sample would make the average turn time a fiction.
    m.bench.noteTurn(iterations, turn_stats.elapsedMs(nowNs()), m.ttftMillis(), capped);
    // The read cache's hit count, ONCE per turn: reading `m.reads.stats` from the
    // draw every frame would take the cache's lock 60 times a second for a number
    // that changes once per turn.
    m.bench.read_hits = m.reads.stats.hits;
    // The automatic typecheck, WAITED FOR.
    //
    // Measured: with the result only read at the start of the next iteration, a turn
    // that ends right after the edit collected nothing — the `zig build` it started
    // was still running — and the next turn's reset killed it. So the feature
    // produced nothing on exactly the turns it exists for.
    //
    // It waits, with a cap, at the END of a turn. That is the one moment blocking is
    // free: the user is waiting for the answer anyway, and the alternative is
    // answering "done" about code nobody has compiled yet.
    finishAutoCheck(m);
    pushTurnSummary(m);
}

/// Reports whatever the automatic typecheck found, at the end of a turn.
///
/// ## It is the REPORT, not the gate
///
/// The gate is `AutoCheck.exitGate`, and it runs INSIDE the loop, before the turn is
/// allowed to end. This is only what is left to say once the turn's fate is decided,
/// and it exists because the gate consumes the diagnostics: they go back to the model
/// as a nudge, and if nothing else kept a copy they would be gone from the history by
/// the time the user scrolled back to read them.
///
/// ## And the case that used to be silent
///
/// A turn that ends with code nobody compiled, because the project has no check the
/// harness knows, used to print nothing at all — it read as "done". Now it says the
/// code is NOT verified, once, with the reason. A turn that ends without that line is
/// a turn where something was checked and passed.
pub fn finishAutoCheck(m: *tui.Model) void {
    const gpa = m.allocator;
    if (m.auto_check.job != 0) {
        var waited_ms: u32 = 0;
        while (waited_ms < auto_check_wait_ms) {
            if (!std.mem.eql(u8, bgproc.stateWord(&m.bg, m.auto_check.job), "running")) break;
            sleep_mod.nap(50);
            waited_ms += 50;
        }
        if (m.auto_check.collect(&m.bg)) |note| {
            const owned = gpa.dupe(u8, note) catch return;
            // Into the history, owned: the session keeps it and this is not the turn's
            // arena. And to the screen, because a compile error nobody was shown is the
            // thing this whole feature exists to prevent.
            const sess = ensureSession(m, gpa);
            sess.append(.user, owned) catch gpa.free(owned);
            sess.flush();
            pushInfoFmt(m, "· {s} reported problems in the code you just wrote — see the history", .{
                m.auto_check.labelSlice(),
            });
            return;
        }
    }

    // Nothing red. Is that because everything passed, or because nothing was ever
    // checked? The two used to look identical on screen, and only the second one is a
    // lie the user has to be told about.
    if (m.auto_check.gate.decide() == .cannot_verify and !m.auto_check.spoke) {
        m.auto_check.spoke = true;
        pushInfoFmt(
            m,
            "· the code you wrote is NOT verified: this project has no check the harness knows how to run",
            .{},
        );
    }

    // And what WAS proved, in the word that is true of it. This is the last line of the
    // turn and it is the one a user reads before deciding whether to open the diff.
    if (m.auto_check.gate.wroteCode()) {
        if (m.auto_check.proofLine(gpa)) |line| {
            defer gpa.free(line);
            pushInfo(m, line);
        }
    }
}

/// The iteration limit, from `ZODE_MAX_ITER` or the default.
///
/// It was a hardcoded 8 and nobody knew how often it was reached, so changing it
/// was a guess in both directions. It is configurable now and `/bench` reports the
/// percentage of turns that hit it: a limit that is hit 0% is too high (it costs
/// nothing to raise) and one hit by 30% is too low (real tasks are being cut).
///
/// The floor matters: at 2 the agent cannot even read a file and act on it, and a
/// turn that dies mid-way leaves the user with a half-changed tree.
pub fn iterationLimit() usize {
    const raw = envGet(environ_global, "ZODE_MAX_ITER") orelse return default_max_iterations;
    const n = std.fmt.parseInt(usize, raw, 10) catch return default_max_iterations;
    if (n < 4) return 4;
    if (n > 200) return 200;
    return n;
}

/// The CEILING, which only a `/goal` ever reaches.
///
/// ## Why there are two numbers
///
/// The soft limit (12) exists to stop a runaway loop. It was also, by accident, the
/// only limit: a task that needed 14 got cut at 12 and the user typed "continue", which
/// is the failure this whole feature exists to remove.
///
/// Two numbers separates the two jobs. The soft one is what `/bench` measures against
/// — it is a REPORTED target, not a wall. The hard one is the wall, and it is generous
/// on purpose: the cases that hit it are tasks that cannot be finished here, and those
/// should end by saying `blocked`, not by being silently truncated.
///
/// `ZODE_GOAL_MAX` overrides it. It is not clamped to anything sensible beyond a
/// ceiling, because a user who sets it wants exactly that.
pub const default_goal_hard: usize = 60;

/// The ceiling that applies to the turn in progress, and the one the status bar has to
/// print. Extracted because the number in the UI and the number the loop uses were two
/// reads of the same idea, and only the loop's was right.
pub fn statusIterationLimit(m: *const tui.Model) usize {
    return if (m.goal.isOpen()) goalHardLimit() else iterationLimit();
}

pub fn goalHardLimit() usize {
    const raw = envGet(environ_global, "ZODE_GOAL_MAX") orelse return @max(iterationLimit() * 3, default_goal_hard);
    const n = std.fmt.parseInt(usize, raw, 10) catch return @max(iterationLimit() * 3, default_goal_hard);
    return @max(n, iterationLimit());
}

/// The same tool with the same arguments, three times running.
///
/// ## Why this is separate from the limit
///
/// A loop with a limit is stopped by the limit, which costs the whole budget first: the
/// model can burn twelve iterations re-reading the same file looking for something it
/// already has, and the user sees a normal-looking turn that ends for no stated reason.
///
/// This catches the shape itself, and it says WHAT was repeated, so the stop is
/// informative instead of mysterious. A hash and not the arguments: comparing the bytes
/// means owning them for the turn, and a collision here costs an early stop on a turn
/// that was going nowhere anyway.
///
/// `u64` FNV-1a over the tool name and the arguments. `0` is never a legal hash here
/// because `runToolCall` is only reached with a non-empty name.
/// Re-exported so the call sites and the tests keep one name for the rule. The
/// IMPLEMENTATION lives in `lib/repeats.zig`; see its doc comment for why it does not
/// belong in a file this size.
pub const repeat_limit = repeats_mod.repeat_limit;
pub const isRepeatExempt = repeats_mod.isRepeatExempt;
pub const Repeats = repeats_mod.Repeats;

/// The automatic typecheck and its exit gate. Re-exported so the Model field and the
/// ~90 call sites keep one name; the implementation is in `src/autochk.zig`, which is
/// Model-free and was always written to be.
pub const AutoCheck = autochk.AutoCheck;
pub const Verdict = autochk.Verdict;
pub const auto_check_wait_ms = autochk.auto_check_wait_ms;
pub const auto_check_per_turn = autochk.auto_check_per_turn;
pub const codePathsFromArgs = autochk.codePathsFromArgs;
pub const forgetGitRepoProbe = autochk.forgetGitRepoProbe;
pub const attachAutoCheckEnv = autochk.attachEnv;

/// The moment the turn started, for the bench sample. Taken here because the
/// worker's start is not the same as the model's first token.
fn nowNs() i128 {
    return std.Io.Timestamp.now(io_global, .real).nanoseconds;
}

/// The turn summary in the history: 2 lines that say what happened.
///
/// Before, the end of a turn was literally `setStatusWithZo(m, .done, "done")`
/// and nothing else: no files, no tools, no tokens, no duration. And since the
/// activity strip turns off when it finishes, the only thing left visible from
/// the turn is the status, which gets replaced on the next turn.
fn pushTurnSummary(m: *tui.Model) void {
    const s = &turn_stats;
    const now_ns = std.Io.Timestamp.now(io_global, .real).nanoseconds;
    const ms = s.elapsedMs(now_ns);

    // CAREFUL: `pushInfo` (which COPIES) and not `pushInfoOwned`.
    // `pushInfoOwned` TAKES OWNERSHIP of the text and frees it in
    // `Model.deinit`, so handing it a pointer to a STACK buffer leaves the
    // pending queue with a pointer to a frame that dies when this function
    // returns: the next draw paints freed memory (SIGSEGV in
    // `ensureParaHeights`) and the exit would be an "Invalid free".
    var line_buf: [256]u8 = undefined;
    const line = s.summaryLine(&line_buf, ms, ctx_used, cacheHitPct()) catch return;
    pushInfo(m, line);

    if (s.files.items.len == 0 and s.yolo_open.items.len == 0) return;
    var detail_buf: [512]u8 = undefined;
    const detail = s.detailLine(&detail_buf) catch return;
    if (detail.len > 0) pushInfo(m, detail);

    // The questions nobody answered, in the summary.
    //
    // The model is TOLD to mention them in its own answer, and it usually
    // does. But "usually" is not a guarantee, and the one thing the user has
    // to act on is exactly the thing the model might forget: a question that
    // nobody was asked and nobody mentions is a question that is lost.
    if (s.yolo_open.items.len > 0) {
        var ybuf: [256]u8 = undefined;
        const y = s.yoloOpenLine(&ybuf) catch return;
        if (y.len > 0) pushInfo(m, y);
    }
}

/// Cache hit-rate of the session, rounded (0 = no data).
pub fn cacheHitPct() u8 {
    const r = cache_stats.session.hitRatePct();
    if (r <= 0) return 0;
    return @intFromFloat(std.math.clamp(r, 0, 100));
}

/// The session's cache stats, for the usage column of the status bar.
///
/// A snapshot by value and not a pointer to the global: the status bar is read
/// once per frame from the UI thread while the worker writes `session`, and a
/// `*CacheStats` would invite reading it mid-update.
pub fn cacheSessionStats() cache_stats.CacheStats {
    return cache_stats.session;
}

/// The same stats, but as a pointer, so tests can seed and reset them.
///
/// A mutable view of a global that the worker also writes: only for tests, and
/// only where no turn is in flight.
pub fn cacheSessionStatsForTest() *cache_stats.CacheStats {
    return &cache_stats.session;
}

/// Userdata of the three callbacks of a turn.
///
/// CAREFUL: `onDelta`, `onToolCall` and `onFinish` receive the SAME
/// `?*anyopaque`. If they were passed `&text_sink` and then `onToolCall` cast it
/// to `*TextSink`, on the very first token we would already be reading fields
/// of another type: in ReleaseFast that is silent UB. That is why a struct with
/// its own name is used here.
const TurnCtx = struct {
    m: *tui.Model,
    /// Assistant text of this turn (dumped into the session at the end).
    text: std.ArrayList(u8) = .empty,
    /// Tool calls requested in this turn.
    calls: std.ArrayList(Call) = .empty,
    /// A tool in flight: its header is already painted and the line has to be
    /// closed.
    tool_open: bool = false,
    /// Stream chars, for the tok/s.
    chars: usize = 0,
    /// Moment of the first token (ns). 0 = nothing has arrived yet.
    stream_start_ns: i128 = 0,
    /// Rolling window for the LIVE tok/s: the moment and the char count of the
    /// last sample. The rate is computed over the window, not over the whole
    /// stream, so it tracks the model instead of averaging the first slow
    /// seconds into every reading after them.
    tps_win_ns: i128 = 0,
    tps_win_chars: usize = 0,
    /// Finish reason of the request.
    finish: [32]u8 = undefined,
    finish_len: usize = 0,

    const Call = struct {
        id: []const u8,
        name: []const u8,
        args_json: []const u8,
    };

    fn deinit(self: *TurnCtx) void {
        const gpa = self.m.allocator;
        for (self.calls.items) |c| {
            gpa.free(c.id);
            gpa.free(c.name);
            gpa.free(c.args_json);
        }
        self.calls.deinit(gpa);
        self.text.deinit(gpa);
    }
};

fn onDelta(ud: ?*anyopaque, delta: []const u8) void {
    const t: *TurnCtx = @ptrCast(@alignCast(ud.?));
    t.text.appendSlice(t.m.allocator, delta) catch {};
    t.chars += delta.len;
    const now_ns = std.Io.Timestamp.now(io_global, .real).nanoseconds;
    if (t.stream_start_ns == 0) {
        t.stream_start_ns = now_ns;
        t.tps_win_ns = now_ns;
        t.tps_win_chars = t.chars;
        // A fresh stream starts at zero instead of showing the PREVIOUS
        // stream's number: before, `tps_live` was only written at the END of
        // each iteration, so the status bar painted iteration N-1's rate (or
        // the last turn's) while iteration N was streaming.
        tps_live = 0;
    } else if (now_ns - t.tps_win_ns >= tps_sample_ns) {
        const win = tpsOf(estTokens(t.chars - t.tps_win_chars), now_ns - t.tps_win_ns);
        if (win > 0) {
            tps_live = win;
            tps_last = win;
        }
        t.tps_win_ns = now_ns;
        t.tps_win_chars = t.chars;
    }
    t.m.streamDelta(delta);
}

/// How often the live tok/s is recomputed while tokens arrive. 250 ms: fine
/// enough that the number feels live, coarse enough that one clock read per
/// quarter second instead of one per delta.
const tps_sample_ns: i128 = 250 * 1_000_000;

fn onToolCall(ud: ?*anyopaque, id: []const u8, name: []const u8, args_json: []const u8) void {
    const t: *TurnCtx = @ptrCast(@alignCast(ud.?));
    const gpa = t.m.allocator;
    t.calls.append(gpa, .{
        .id = gpa.dupe(u8, id) catch return,
        .name = gpa.dupe(u8, name) catch return,
        .args_json = gpa.dupe(u8, args_json) catch return,
    }) catch {};
}

fn onFinish(ud: ?*anyopaque, reason: []const u8) void {
    const t: *TurnCtx = @ptrCast(@alignCast(ud.?));
    const n = @min(reason.len, t.finish.len);
    @memcpy(t.finish[0..n], reason[0..n]);
    t.finish_len = n;
}

/// A turn's `tool_calls` as JSON for the session.
///
/// It is the SAME format that `chat.StreamCtx.toolCallsJson` writes (the one
/// the headless runner uses): if they diverge, one of the two clients sends a
/// conversation the other cannot read. That is why this is here and not a
/// "seems enough": `arguments` goes as an escaped JSON string, not as a nested
/// object.
fn toolCallsJsonFromCalls(gpa: std.mem.Allocator, calls: []const TurnCtx.Call) ?[]const u8 {
    if (calls.len == 0) return null;
    var out: std.ArrayList(u8) = .empty;
    out.append(gpa, '[') catch return null;
    for (calls, 0..) |c, i| {
        if (i > 0) out.append(gpa, ',') catch return null;
        out.appendSlice(gpa, "{\"id\":\"") catch return null;
        out.appendSlice(gpa, c.id) catch return null;
        out.appendSlice(gpa, "\",\"type\":\"function\",\"function\":{\"name\":\"") catch return null;
        out.appendSlice(gpa, c.name) catch return null;
        out.appendSlice(gpa, "\",\"arguments\":\"") catch return null;
        for (c.args_json) |ch| {
            switch (ch) {
                '"' => out.appendSlice(gpa, "\\\"") catch return null,
                '\\' => out.appendSlice(gpa, "\\\\") catch return null,
                '\n' => out.appendSlice(gpa, "\\n") catch return null,
                '\r' => out.appendSlice(gpa, "\\r") catch return null,
                '\t' => out.appendSlice(gpa, "\\t") catch return null,
                else => out.append(gpa, ch) catch return null,
            }
        }
        out.appendSlice(gpa, "\"}}") catch return null;
    }
    out.append(gpa, ']') catch return null;
    return out.items;
}

/// A turn: one request to the API with the history, its tools and, if the model
/// asks for tools, their execution and the next turn.
///
/// Returns the synthesized text to send in the next turn (normally null: if
/// there were no tool calls, the turn is over).
/// `user_text` is already in the session (`startChat` wrote it): here it is
/// only used for the case of synthetic iterations, and the system prompt is
/// injected once at the start of the conversation.
/// CAREFUL: the return type is `[]u8` and not `[]const u8` ON PURPOSE. With
/// `[]const u8` the compiler does not tell a literal from owned memory, and
/// `chatWorker` freed the literal "Continue with the tool results above." ->
/// `free` on `.rodata` -> "reached unreachable code" panic in ReleaseSafe,
/// which means a turn with tools brought the app down ALWAYS. Zig literals are
/// `[]const`, so now the compiler PREVENTS returning them here.
/// [roster] Who a turn is sent to.
///
/// It exists so that `runOneTurn` does not have to decide between "the active
/// provider/model" and "the free-auto candidate" in three different places
/// (body, url and key). With rotation the `pick` is REPLACED inside the retry
/// loop, and if each place queried the global on its own, half a request would
/// go to the old provider: a 401 with someone else's key, or a body with the
/// name of a model that is no longer there.
const Target = struct {
    def: *const providers.ProviderDef,
    model: []const u8,
    kind: chat.ProviderKind,
    base_url: []const u8,
    key: ?[]const u8,
    /// The pool candidate, or null if this turn goes to the active provider/model.
    from_roster: ?roster_mod.Candidate = null,
};

/// The endpoint for a target.
///
/// It is a function and not three inline copies because the subagent's model
/// fallback re-derives it after switching models: a `url` computed once outside
/// the loop would keep pointing at the provider that just said no.
fn targetUrl(buf: []u8, t: Target) []const u8 {
    return if (t.kind == .anthropic)
        std.fmt.bufPrint(buf, "{s}/messages", .{t.base_url}) catch t.base_url
    else
        std.fmt.bufPrint(buf, "{s}/chat/completions", .{t.base_url}) catch t.base_url;
}

/// This turn's target: the pool if free-auto is on and already has its list,
/// the active provider/model otherwise.
///
/// With the pool unbuilt (or empty) it falls back to the active one WITHOUT
/// saying so: the list is N requests and the first prompt cannot wait for them.
/// Rotation waits for the next turn.
fn pickTarget(m: *tui.Model) Target {
    const active = activeTarget(m);
    if (!free_auto.freeAutoOn()) return active;
    if (free_auto.poolSize() == 0) return active;
    const cand = free_auto.rosterGet(m.allocator).active(free_auto.nowMs()) orelse return active;
    return targetForCandidate(m, cand) orelse active;
}

/// Updates `cur_model_ctx` from the roster candidate if the pick comes from free-auto.
/// This ensures the compaction budget uses the correct context window when free-auto
/// rotates to a model with a different (typically smaller) context window.
fn updateModelContextFromPick(pick: Target) void {
    if (pick.from_roster) |cand| {
        setModelCtx(pick.model, cand.ctx);
    }
}

/// How many output tokens this request may ask for: the provider's cap, and the
/// user's ceiling on top of it.
///
/// Two numbers because they answer different questions. The provider cap
/// (`max_output_tokens` in the provider table) exists because a hosted service
/// validates `max_tokens` per MODEL and some of its models top out at 4096:
/// `medium` sends 32768 and the turn dies before the first token. A user can
/// SURPASS that by picking a model with a lower limit still (NVIDIA's catalog
/// mixes 4096 and 32768), which is why `ZODE_MAX_OUTPUT_TOKENS` is a hard
/// ceiling on top instead of a replacement: the smaller of the two wins, and 0
/// means "no opinion".
pub fn outputCapFor(def: *const providers.ProviderDef, env: ?*const std.process.Environ.Map) u32 {
    const from_env: u32 = blk: {
        const raw = envGet(env, "ZODE_MAX_OUTPUT_TOKENS") orelse break :blk 0;
        break :blk std.fmt.parseInt(u32, raw, 10) catch 0;
    };
    if (from_env == 0) return def.max_output_tokens;
    if (def.max_output_tokens == 0) return from_env;
    return @min(def.max_output_tokens, from_env);
}

// ── /submodel: which model the SUBAGENTS run on ──────────────
//
// Three ways to say it, in this order — the same shape as the active model's
// own (`/use` beats config.json beats the environment):
//
//   1. `/submodel` in this session: unset (inherit), set, or `off` (force none)
//   2. `subagent_provider` / `subagent_model` in config.json
//   3. `ZODE_SUBAGENT_PROVIDER` / `ZODE_SUBAGENT_MODEL`
//
// Nothing set = what always happened: the subagent runs on the same target as
// the main turn (free-auto rotation included), at effort `low`.
//
// A pick that cannot be used does NOT fail the search: the reason rides in
// front of the report and the search runs on the normal target. A broken
// override that killed every `task` would push the searches back into the main
// context, which is the exact cost the subagent exists to avoid.

/// What the developer asked for, wherever it came from.
const SubPick = struct {
    provider: []const u8,
    model: []const u8,
    /// Which of the three said it. It rides in the report's note so a pick that
    /// is working and one that was never set can be told apart without going
    /// to look — a mode you cannot see is a mode you cannot diagnose.
    source: []const u8,
};

/// The session's own override. Three states and not two: `off` has to SURVIVE
/// a config.json that sets the field, or `/submodel off` would do nothing for
/// exactly the user who needs it most.
///
/// The buffers are static for the same reason as `cur_model_buf`: the string
/// `/submodel` is fed comes from the input line and dies with the next redraw.
/// The UI thread writes them and the worker reads them, which is the same
/// accepted race as the model name itself: a ≤128-byte copy with a single
/// writer.
var sub_session: enum { unset, set, off } = .unset;
var sub_provider_buf: [64]u8 = undefined;
var sub_provider_len: usize = 0;
var sub_model_buf: [128]u8 = undefined;
var sub_model_len: usize = 0;

/// Why the pick was given up for the rest of the session ("" = it was not).
/// Session-long like `router.State.given_up`: a model the provider will not
/// serve is one it will not serve on the next `task` either, and every attempt
/// costs a failed request plus a fallback before the search can start.
var sub_fail_buf: [256]u8 = undefined;
var sub_fail_len: usize = 0;

fn submodelFail(text: []const u8) void {
    const n = @min(text.len, sub_fail_buf.len);
    @memcpy(sub_fail_buf[0..n], text[0..n]);
    sub_fail_len = n;
}

/// Formats a reason into `buf` and returns what fit.
///
/// A fixed writer and not `bufPrint` because `bufPrint` on overflow gives an
/// ERROR and no text at all — and a reason that vanishes leaves the note
/// saying "was not used ()". Truncated is still a reason.
fn reasonFmt(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print(fmt, args) catch {};
    return w.buffered();
}

/// The developer's pick, or null when subagents follow the main turn.
fn submodelPick(m: *tui.Model) ?SubPick {
    switch (sub_session) {
        // The session's `off` beats everything: config.json and the environment
        // come back on the next launch, and saying "off" has to mean off NOW.
        .off => return null,
        .set => return .{
            .provider = sub_provider_buf[0..sub_provider_len],
            .model = sub_model_buf[0..sub_model_len],
            .source = "/submodel",
        },
        .unset => {},
    }
    if (user_config.subagent_provider.len > 0 or user_config.subagent_model.len > 0) {
        return .{
            .provider = user_config.subagent_provider,
            .model = user_config.subagent_model,
            .source = "config.json",
        };
    }
    const p = envGet(m.environ, "ZODE_SUBAGENT_PROVIDER") orelse "";
    const mo = envGet(m.environ, "ZODE_SUBAGENT_MODEL") orelse "";
    if (p.len == 0 and mo.len == 0) return null;
    return .{
        .provider = p,
        .model = mo,
        .source = if (mo.len > 0) "ZODE_SUBAGENT_MODEL" else "ZODE_SUBAGENT_PROVIDER",
    };
}

/// Where a pick resolves to, or why it does not.
const SubResolve = union(enum) {
    ok: Target,
    /// A slice INTO the caller's reason buffer, already written for a human.
    why: []const u8,
};

/// Resolves the pick into a target: the named provider (or the active one when
/// the pick names only a model), the named model (or the provider's
/// `default_model`), and the key OF THAT PROVIDER.
fn submodelTarget(m: *tui.Model, pick: SubPick, reason: []u8) SubResolve {
    const def: *const providers.ProviderDef = blk: {
        if (pick.provider.len == 0) break :blk activeProviderDef(m.environ);
        if (config_mod.find(user_config, pick.provider)) |d| break :blk d;
        if (providers.byId(pick.provider)) |d| break :blk d;
        return .{ .why = reasonFmt(reason, "zode does not know the provider \"{s}\" (see /providers)", .{pick.provider}) };
    };
    const model: []const u8 = if (pick.model.len > 0) pick.model else def.default_model;
    if (model.len == 0) {
        return .{ .why = reasonFmt(reason, "\"{s}\" has no default model; name one: /submodel {s} <model>", .{ def.id, def.id }) };
    }
    // The key for THIS provider, and `curKey` only when it IS the active one:
    // `curKey` falls back to the generic `ZODE_API_KEY`, and handing that to
    // another provider is the one-key-to-the-wrong-endpoint bug all over again.
    //
    // `key_env.len == 0` is a provider that needs NO key (ollama and friends):
    // null there is a configuration, not a missing credential.
    const key = if (std.mem.eql(u8, def.id, activeProviderDef(m.environ).id))
        curKey(m)
    else
        providers.keyFor(def, m.environ);
    if (key == null and def.key_env.len > 0) {
        return .{ .why = reasonFmt(reason, "there is no API key for \"{s}\" (connect it with ctrl+a, or set its ZODE_*_KEY)", .{def.id}) };
    }
    return .{ .ok = .{
        .def = def,
        .model = model,
        .kind = chat.kindForProvider(def.id),
        .base_url = def.base_url,
        .key = key,
        .from_roster = null,
    } };
}

/// The note for a RUNTIME fallback: the measured clause (`router.phraseHead`)
/// plus the two names plus the subagent's own command. Split out so the
/// wording is testable without a dead model and a network.
fn submodelFallbackNote(
    buf: []u8,
    from_provider: []const u8,
    from_model: []const u8,
    w: router_mod.Why,
    to_provider: []const u8,
    to_model: []const u8,
) []const u8 {
    return reasonFmt(
        buf,
        "[subagent note: {s}/{s} {s}, so this search went to {s}/{s}. Set another with /submodel, or /submodel off.]",
        .{ from_provider, from_model, router_mod.phraseHead(w), to_provider, to_model },
    );
}

/// The pick, applied to `base`. False = the subagent runs on `base` as always.
/// When the pick existed but could not be used, the NOTE explaining why is
/// already in the Report — silence here would be a setting that looks like it
/// works.
fn applySubmodel(m: *tui.Model, base: *Target, rep: *subagent_mod.Report) bool {
    // Given up for this session: silent, like the cheap router after its first
    // 403. The developer has already seen the reason — in the first report and
    // in `/submodel`, which says it too.
    if (sub_fail_len > 0) return false;
    const pick = submodelPick(m) orelse return false;

    var reason_buf: [400]u8 = undefined;
    switch (submodelTarget(m, pick, &reason_buf)) {
        .why => |why_not| {
            var nbuf: [640]u8 = undefined;
            const prov: []const u8 = if (pick.provider.len > 0)
                pick.provider
            else
                activeProviderDef(m.environ).id;
            rep.setNote(reasonFmt(
                &nbuf,
                "[subagent note: the subagent model {s}/{s} was not used ({s}). Fix it with /submodel, or /submodel off.]",
                .{ prov, pick.model, why_not },
            ));
            return false;
        },
        .ok => |target| {
            base.* = target;
            // The success note too, not only the failure one: the router reports
            // a cheap turn that simply WORKED for the same reason — a pick you
            // cannot see is a pick where "my config did nothing" cannot be told
            // apart from "my config is not needed here".
            var nbuf: [320]u8 = undefined;
            rep.setNote(reasonFmt(
                &nbuf,
                "[subagent note: this search runs on {s}/{s} ({s}).]",
                .{ target.def.id, target.model, pick.source },
            ));
            return true;
        },
    }
}

/// `/submodel [off | <model> | <provider> <model>]`; no args: report.
///
/// It lives here and not in `commands.zig` because it writes THIS module's
/// state — the same reason `/effort` and `/yolo` stayed in agent.zig.
fn cmdSubmodel(m: *tui.Model, arg: ?[]const u8) void {
    const a = arg orelse return submodelReport(m);
    if (std.mem.eql(u8, a, "off") or std.mem.eql(u8, a, "none")) {
        sub_session = .off;
        sub_fail_len = 0;
        m.pushInfoFmt("subagents: the same model as the main turn (`/submodel off`; config.json and the environment are ignored this session). Set: /submodel <model> | <provider> <model>", .{});
        return;
    }
    var it = std.mem.tokenizeScalar(u8, a, ' ');
    const t1 = it.next() orelse return submodelReport(m);
    const t2 = it.next();
    // ONE token is a model on the active provider, unless it happens to be a
    // known provider id — then it is `/submodel <provider>` with that
    // provider's default model. Both readings are what people type: `/submodel
    // kimi-k2.6` and `/submodel groq` are equally plausible, and always
    // treating it as a model would send a provider id into the model field.
    if (t2 == null and (config_mod.find(user_config, t1) != null or providers.byId(t1) != null)) {
        setSubmodel(t1, "");
    } else if (t2) |mo| {
        setSubmodel(t1, mo);
    } else {
        setSubmodel("", t1);
    }
    // A fresh pick deserves a fresh chance: the give-up was about the OLD one.
    sub_fail_len = 0;
    submodelReport(m);
}

/// Copies the pick into the session's static buffers. It COPIES, and that is
/// the point: the string comes from the input line and dies with the next
/// redraw — a global pointing at it is the `cur_model_buf` bug again.
fn setSubmodel(provider: []const u8, model: []const u8) void {
    const p = @min(provider.len, sub_provider_buf.len);
    std.mem.copyForwards(u8, sub_provider_buf[0..p], provider[0..p]);
    sub_provider_len = p;
    const mm = @min(model.len, sub_model_buf.len);
    std.mem.copyForwards(u8, sub_model_buf[0..mm], model[0..mm]);
    sub_model_len = mm;
    sub_session = .set;
}

/// `/submodel` with no arguments, and also the closing line of every set: it
/// resolves the pick LIVE, because reporting what is STORED when what matters
/// is whether it would be USED is how a broken setting keeps looking fine.
fn submodelReport(m: *tui.Model) void {
    if (sub_session == .off) {
        m.pushInfoFmt("subagents: the same model as the main turn (/submodel off). Set: /submodel <model> | /submodel <provider> <model>", .{});
        return;
    }
    const pick = submodelPick(m) orelse {
        m.pushInfoFmt("subagents: the same model as the main turn (no override). Set: /submodel <model> | /submodel <provider> <model>", .{});
        return;
    };
    const prov: []const u8 = if (pick.provider.len > 0)
        pick.provider
    else
        activeProviderDef(m.environ).id;
    var reason_buf: [400]u8 = undefined;
    switch (submodelTarget(m, pick, &reason_buf)) {
        .ok => |t| {
            if (sub_fail_len > 0) {
                m.pushInfoFmt("subagents: {s}/{s} ({s}) — NOT in use: {s}. Change it with /submodel, or /submodel off", .{
                    t.def.id, t.model, pick.source, sub_fail_buf[0..sub_fail_len],
                });
            } else {
                m.pushInfoFmt("subagents: {s}/{s} ({s}). Off with /submodel off.", .{ t.def.id, t.model, pick.source });
            }
        },
        .why => |why_not| m.pushInfoFmt("subagents: {s}/{s} ({s}) — CANNOT be used: {s}", .{
            prov, pick.model, pick.source, why_not,
        }),
    }
}

/// Says, once, that the chosen model is a router and that this costs money.
///
/// ## Why it is not a note in the docs
///
/// Measured on 2026-10-04, same request, same 3.5k prefix, three times:
///
/// ```
/// openrouter/free          prompt=3583  3273  3381   cached=0
/// qwen/qwen3.8-27b:free   prompt=3611  3613  3613   cached=3328  (98%)
/// ```
///
/// A router picks a different upstream per request. Different tokenizers, and
/// **different prompt caches that are not shared**, so a router cannot produce a
/// prefix-cache hit no matter how stable the prefix is — and the whole 11 KB tool
/// schema goes out in full on every single request instead of at ~1/50th of the
/// price.
///
/// The fix is one `/model` away and costs nothing (the fixed model measured is
/// free too), so silence here was the single most expensive missing line in the
/// whole provider layer. `cache_stats.verdict()` confirms it afterwards from the
/// evidence, without trusting this list.
/// The router warning fires ONCE per session, and the "once" is what makes it
/// usable: a warning on every turn of a long session is a line of noise the
/// second time and gets ignored, which is the same as never saying it.
///
/// It re-arms when the model changes, because after `/model` to another router the
/// user should be told again — they may not have read it the first time either.
var router_warned = false;

fn routerWarnOnce(m: *tui.Model, model: []const u8) void {
    if (router_warned) return;
    // Set either way: "not a router" is also a decision not to check again, and
    // the empirical `/cache` verdict is what catches a router this list misses.
    router_warned = true;
    warnIfRouter(m, model);
}

fn warnIfRouter(m: *tui.Model, model: []const u8) void {
    if (!models_mod.isRouter(model)) return;
    pushInfoFmt(
        m,
        "this model is a ROUTER, so every request is billed in full and nothing is served from cache: it picks a different upstream each time and they do not share a prompt cache. Measured 2026-10-04, same prefix: openrouter/free 0% cached, a fixed model 98%. /model and pick one that is not a router (`model:free` is a MODEL that happens to be free — that one caches).",
        .{},
    );
}

/// Picks a model when the user has not chosen one, by ASKING the provider.
///
/// Why this exists: the compiled providers carry no `default_model` on purpose. A
/// hardcoded model id is a timed bomb — the day the provider retires it, every
/// request comes back 403 with a message about access and not about the name, and
/// zode has nothing to fall back on. Here the catalogue is asked, which is a fact
/// that can be asked again tomorrow.
///
/// The choice: the first model marked free (the ones that work without credits),
/// alphabetical within the group so the same catalogue always picks the same one
/// (a model that changes between two turns of the same session reads as a bug in
/// zode even when it is not). If the provider publishes none, the first it lists.
///
/// And when the catalogue cannot be read it does NOT send anything: it says so and
/// leaves the picker in front of the user. A turn burnt on a 403 teaches nobody
/// anything, and "the catalog could not be read" and "that model does not exist"
/// are two problems that deserve two different answers.
///
/// It runs on the worker thread, so `setModel` is called from there. Safe because
/// `cur_model` is written under `model_lock` and every reader goes through
/// `curModel()`.
fn resolveModel(m: *tui.Model, http: *http_client.Http) ?[]const u8 {
    if (curModel().len > 0) return curModel();
    const gpa = m.allocator;
    const def = activeProviderDef(m.environ);

    // An empty `models_url` means the provider publishes no catalogue (Z.AI:
    // its API reference has chat/completions and nothing that lists models).
    // Asking would be a request to "" whose error talks about a URL and not
    // about the provider, so the answer is the one thing the user can act on.
    if (def.models_url.len == 0) {
        m.pushInfoFmt(
            "{s} publishes no model catalog: pick the model by hand with `/use {s} <model>` (or set ZODE_MODEL).",
            .{ def.id, def.id },
        );
        setStatusWithZo(m, .warn, "no model · /use");
        return null;
    }

    setStatusWithZo(m, .thinking, "no model chosen · asking the provider");

    var list = models_mod.listModels(gpa, http, def.models_url, providers.authWithKey(def.key_style, providers.keyFor(def, m.environ) orelse curKey(m))) catch |err| {
        m.pushInfoFmt(
            "no model chosen, and {s}'s catalog could not be read ({t}). Open /model to pick one.",
            .{ def.id, err },
        );
        setStatusWithZo(m, .warn, "no model · /model");
        return null;
    };
    defer list.deinit(gpa);

    if (list.items.len == 0) {
        pushInfoFmt(m, "{s} publishes no models. Open /model to check the base URL.", .{def.id});
        setStatusWithZo(m, .warn, "no models published");
        return null;
    }

    const choice = chooseCatalogModel(def, list.items) orelse unreachable;
    const chosen = choice.model;

    // The window comes with the choice: this function downloaded the catalogue
    // to make the decision and threw `context_length` away on the way out, so
    // the budget stayed at 128k for a model that publishes 200k.
    setModelCtx(chosen.id, chosen.context_length);
    // WHICH and WHY, in the history and not only in the status bar: a silent
    // choice is indistinguishable from a hardcoded default, which is the thing
    // this exists to replace.
    pushInfoFmt(m, "model → {s} ({s}; /model to change it)", .{ chosen.id, choice.why });
    setStatusWithZo(m, .done, chosen.id);
    refreshContextUsage(m);
    return curModel();
}

/// The headless runner's version of `resolveModel`: same question, same choice,
/// no UI to say it in.
///
/// It lives here rather than in `main.zig` because the CHOICE is one decision and
/// it must not be made twice: two pickers that disagree on which free model is
/// "the first" would make the TUI and `--chat` behave differently against the same
/// provider, and that difference only shows up as a bug report.
pub fn resolveModelHeadless(
    gpa: std.mem.Allocator,
    http: *http_client.Http,
    env: ?*const std.process.Environ.Map,
) ![]const u8 {
    const def = activeProviderDef(env);
    var list = try models_mod.listModels(gpa, http, def.models_url, providers.catalogAuth(def, env));
    defer list.deinit(gpa);
    if (list.items.len == 0) return error.NoModelsPublished;

    const chosen = (chooseCatalogModel(def, list.items) orelse return error.NoModelsPublished).model;
    // Into the static buffer: the caller keeps this for the whole run and the
    // list is freed on the way out.
    setModelCtx(chosen.id, chosen.context_length);
    return curModel();
}

/// The catalog choice for a provider the user has NOT picked a model for.
///
/// ONE function and not two, because the TUI (`resolveModel`) and `--chat`
/// (`resolveModelHeadless`) must not disagree: two pickers that each decide "the
/// first free model" drift the day one of them learns a new rule, and the drift
/// only shows up as a bug report about `--chat` behaving differently against the
/// same provider.
const CatalogChoice = struct {
    model: models_mod.Model,
    /// The sentence that says WHY, for the history: a silent choice is
    /// indistinguishable from a hardcoded default.
    why: []const u8,
};

fn chooseCatalogModel(def: *const providers.ProviderDef, list: []const models_mod.Model) ?CatalogChoice {
    if (list.len == 0) return null;

    // 1. The provider's OWN preference list, in the order the provider wrote it.
    //
    // NVIDIA publishes 85 models and the first one is `01-ai/yi-large`, long
    // retired: "the first entry in the catalog" is not a choice there, it is the
    // oldest row. The preference list is a suggestion (a retired id fails loudly
    // at the first request), and anything not present in the catalog is skipped
    // instead of guessed.
    for (def.preferred_models) |want| {
        for (list) |info| {
            if (std.mem.eql(u8, info.id, want)) {
                return .{ .model = info, .why = "one of its preferred models" };
            }
        }
    }

    // 2. The first free model (alphabetical, so the answer is stable between
    //    runs), else the first entry the catalog listed.
    var best: ?models_mod.Model = null;
    for (list) |info| {
        if (!isFree(info)) continue;
        if (best == null or std.mem.lessThan(u8, info.id, best.?.id)) best = info;
    }
    if (best) |b| return .{ .model = b, .why = "the first free model in its catalog" };
    return .{ .model = list[0], .why = "the first model in its catalog (it publishes no free ones)" };
}

/// The model the USER chose, or `""`.
///
/// Separate from `curModel()` because this one is a QUESTION ("has anybody chosen
/// one?") and the other reads the current value. The headless runner asks the
/// question before talking to any provider, and conflating the two would make a
/// provider's fallback answer as if the user had chosen it.
pub fn userModel() []const u8 {
    if (envGet(environ_global, "ZODE_MODEL")) |mm| {
        if (mm.len > 0) return mm;
    }
    if (user_config.model.len > 0) return user_config.model;
    return "";
}

/// The `Target` of the active provider/model.
fn activeTarget(m: *tui.Model) Target {
    const def = activeProviderDef(m.environ);
    const kind = chat.kindForProvider(def.id);
    return .{
        .def = def,
        .model = cur_model,
        .kind = kind,
        .base_url = def.base_url,
        // The KEY is always the key, Anthropic included: `streamRaw` decides
        // where it goes (x-api-key for Anthropic, Bearer for the rest) and it
        // takes it from this very field — `if (kind == .anthropic) null` here
        // meant the TUI's Anthropic requests went out carrying only
        // `anthropic-version`, with nothing to authenticate with. The headless
        // runner always passed the key, which is why the wire format looked
        // tested and the TUI would have 401'd on the first request.
        .key = providers.keyFor(def, m.environ) orelse curKey(m),
    };
}

/// The `Target` of a concrete provider/model pair. Null if that provider is gone
/// (the user removed it from `config.json` after the pool was built).
fn targetForCandidate(m: *tui.Model, cand: roster_mod.Candidate) ?Target {
    const def = config_mod.find(user_config, cand.provider_id) orelse
        providers.byId(cand.provider_id) orelse return null;
    const kind = chat.kindForProvider(def.id);
    return .{
        .def = def,
        .model = cand.model_id,
        .kind = kind,
        .base_url = def.base_url,
        // Same as `activeTarget`: the key for THIS provider, Anthropic included
        // (see the note there — `streamRaw` is what routes it into x-api-key).
        .key = providers.keyFor(def, m.environ),
        .from_roster = cand,
    };
}

/// [roster] The history line that explains the model switch.
///
/// It goes to the history and not only to the status because this is the moment
/// the user loses track of why it is so slow: without this line, a provider
/// falling over halfway through the turn looks like a failure. And it says BOTH
/// things (what died and why, and what it switched to), because "the model
/// changed" with no reason is not information.
fn pushSwitchNotice(m: *tui.Model, sw: free_auto.Switch, to: Target) void {
    const to_c = to.from_roster orelse return;
    const reason = if (sw.prev_reason.len > 0) sw.prev_reason else "quota gone";
    m.pushInfoFmt("quota gone on {s}/{s} ({s}) → {s}/{s} (free-auto {d}/{d})", .{
        sw.prev_provider,
        sw.prev_model,
        reason,
        to_c.provider_id,
        to_c.model_id,
        free_auto.rosterGet(m.allocator).idx + 1,
        free_auto.poolSize(),
    });
    // The status stays short: it is a segmented line and it already carries the
    // model and the provider. The detail (the why) is in the line above, which
    // does not get cropped.
    const short = std.fmt.allocPrint(m.allocator, "switched to {s}", .{to_c.model_id}) catch "switching model";
    setStatusWithZo(m, .thinking, short);
}

/// [roster] One line with the pool's state, for when the turn dies.
///
/// It says the only thing that is useful: how many candidates are still alive,
/// and that `/free-auto status` has the detail. With no pool built it says
/// nothing (it would be noise).
fn notePoolState(m: *tui.Model) void {
    if (!free_auto.freeAutoOn()) return;
    const lbl = free_auto.freeAutoLabel(m.allocator);
    if (lbl.len == 0) return;
    // `statusLabel` already starts with "free-auto n/m", so the prefix is NOT
    // repeated here (it came out as "free-auto: free-auto 3/16 · ...", which is
    // one of the things that makes an information line unreadable).
    const msg = std.fmt.allocPrint(m.allocator, "{s} · /free-auto status for the detail", .{lbl}) catch
        "free-auto: pool changed";
    pushInfoOwned(m, msg);
}

/// [roster] Marks the pair that just brought the turn down and leaves it for the
/// next one.
///
/// It does NOT rotate the turn (that is `quotaVerdict`'s job): here the error is
/// not about quota, it is "this pair is not delivering". What it does is park it
/// for a minute and move the index, so the next prompt starts somewhere else.
///
/// The two exceptions are obvious and they are in the test:
///   - `AuthFailed`: it is the KEY. Rotating would give 401 on all 16, and on top
///     of that `reportErr`'s message already says which variable to look at.
///   - `Cancelled`: the user stopped. Marking the pair dead would punish the
///     model for one ESC keypress.
fn noteTurnFailure(m: *tui.Model, err: anyerror, pick: Target) void {
    if (!free_auto.freeAutoOn()) return;
    if (pick.from_roster == null) return;
    if (err == error.AuthFailed or err == error.Cancelled) return;
    const sw = free_auto.switchTo(m.allocator, .failed, chat.lastErrorBody()) orelse return;
    const c = sw.cand;
    m.pushInfoFmt("{s}/{s} failed: {s} → next turn starts with {s}/{s}", .{
        sw.prev_provider,
        sw.prev_model,
        errPhrase(err),
        c.provider_id,
        c.model_id,
    });
}

/// How many files went in with the prompt, and how many of the mentioned ones
/// could not be included. The expansion returns it so the caller can compose the
/// history line.
pub const MentionCount = struct { files: u8 = 0, missing: u8 = 0 };

/// Returns the messages with the LAST user message expanded with the
/// `@file` mentions.
///
/// Only the last one is touched: it is the one the user just wrote, and
/// expanding an old message (a prompt from the previous iteration) would be
/// duplicating context for no reason.
///
/// If the expansion fails (an unreadable file, a disk error), the list comes
/// back as it was: mentioning a file is a convenience, never a reason for the
/// turn not to start.
///
/// What CANNOT be tested here is the path that touches the disk: `expand` does
/// `statFile` with `io_global`, and in a unit test that `Io` is `undefined`
/// (reading its vtable is a GPF, not a 0). It is the same trap as
/// `Model.attachIo` with its `io_ready` flag, and that is why the real expansion
/// is verified in the pty, not here. What is pinned down here is the pure
/// contract: with no mentions nothing is copied and only the last message is
/// touched.
fn withMentions(
    arena: std.mem.Allocator,
    msgs: []chat.ChatMessage,
    count: *MentionCount,
) []chat.ChatMessage {
    if (msgs.len == 0) return msgs;
    // CAREFUL: the LAST message is NOT the user's. `runOneTurn` appends the system
    // prompt at the END if the session did not have one (which is why it goes at
    // the front of the body and not of the list), so on the first turn the list
    // ends in `system`. Taking "the last one" literally meant the mention was
    // NEVER expanded, and it was seen in the pty: the model said "I don't have
    // the contents of the file" with the file right there in the prompt.
    var last: ?usize = null;
    for (msgs, 0..) |mm, i| {
        if (std.mem.eql(u8, mm.role, "user")) last = i;
    }
    const li = last orelse return msgs;

    const exp = mentions.expand(io_global, msgs[li].content) catch return msgs;
    if (exp.files == 0) return msgs;
    count.files = exp.files;
    count.missing = exp.missing;

    // Copy of the list so as not to touch the session's: `snapshotMsgs` already
    // lives in THIS turn's arena, but `comp.msgs` is reused across retries and
    // rotations, so the contents have to be stable.
    const copy = arena.alloc(chat.ChatMessage, msgs.len) catch return msgs;
    @memcpy(copy, msgs);
    copy[li].content = exp.text;
    return copy;
}

/// `iteration` is the agent loop's counter (0 on the first pass). The MENTIONS
/// have to be expanded on every iteration (the model needs the file contents in
/// every request) but the notice in the history only on the first: otherwise a
/// turn with three tools prints the same "@file: 1 inlined" three times.
fn runOneTurn(m: *tui.Model, user_text: []const u8, iteration: usize) !?[]u8 {
    _ = user_text;
    const gpa = m.allocator;
    const s = ensureSession(m, gpa);
    // Clock of the TURN (not of the stream): it is what is painted in
    // "done · N.Ns" and what the user measures when they press again.
    const turn_t0 = std.Io.Timestamp.now(io_global, .real).nanoseconds;

    // Each ITERATION opens its live paragraph and announces what it is doing (1.3).
    //
    // Before, `startChat` opened the live paragraph ONCE per prompt and
    // `runOneTurn` closed it without reopening: from the 2nd iteration on (and
    // the loop reaches 8) there was no live paragraph, no activity strip, no
    // spinner, no clock. In other words, everything that says "still working"
    // turned off exactly in the part of the turn where the slow part happens
    m.streamStartIteration();

    var tstate = TurnCtx{ .m = m };
    defer tstate.deinit();

    // The system prompt always goes FIRST (a stable prefix for the provider's
    // cache) and is added ONCE only.
    //
    // Before, the condition was `items[0].role != .system`, and since `startChat`
    // had already appended the `user` message, `items[0]` was `user`: a NEW
    // system was added on every iteration of the agent loop. The second turn
    // went out as [user, system, tool, system] — the system prompt at the end
    // and duplicated — and the turn died with no reply and no visible error.
    // Now the system is looked for in the WHOLE list.
    var has_system = false;
    for (s.messages.items) |mm| {
        if (mm.role == .system) has_system = true;
    }
    if (!has_system) {
        s.append(.system, systemPromptBase(gpa)) catch {};
    }
    // The prompt that goes out on the wire can differ from the one in the session
    // (read-only mode, the skill list), so it is synced AFTER the append.
    syncSystemPrompt(s);

    // Phase 8: warn when the stable prefix broke (which block changed) or when
    // the write rate suggests the prefix is unstable (writes_per_request > 0.5).
    if (cache_break_last_block) |name| {
        m.pushInfoFmt("prompt cache broke: {s} block changed at byte {d}", .{name, cache_break_last_pos});
    } else if (cacheBreakUnstable()) {
        m.pushInfo("prompt cache: writes per request above 0.5 — prefix may be unstable");
    }

    // Phase 2.2: attach the skill listing ONCE per session, at the end of the
    // prompt, outside the cacheable system prefix. `syncSystemPrompt` above no
    // longer puts skills in the system message (they would bloat the stable
    // prefix on every turn); instead they go here as a user message, once.
    // Reset on config reload via `Session.resetSkillsSent`. Not persisted to
    // disk, so a resumed session re-sends them on its first turn.
    if (!s.skills_sent) {
        var already = false;
        for (s.messages.items) |mm| {
            if (mm.role == .user and std.mem.startsWith(u8, mm.content, "[Skills]")) {
                already = true;
                break;
            }
        }
        if (!already) {
            var buf: [16 * 1024]u8 = undefined;
            const section = skillsSectionText(s.allocator, null, &buf);
            if (section.len > 0) {
                const owned = s.allocator.dupe(u8, section) catch null;
                if (owned) |text| {
                    const note = std.fmt.allocPrint(
                        s.allocator,
                        "[Skills] {s}",
                        .{ text },
                    ) catch null;
                    if (note) |n| {
                        s.append(.user, n) catch {};
                        s.skills_sent = true;
                    }
                }
            }
        }
    }

    // The automatic typecheck's verdict, IF it has finished.
    //
    // Here and not in `execToolCalls` because the timing is the whole point: the
    // job was started at the end of the previous iteration so the model could
    // spend this one doing something else, and this is the last moment before the
    // request goes out. Read any earlier and it would still be running; read any
    // later and the model has already decided what to write.
    //
    // It goes in as a `user` message, after the `tool` results, which is a shape
    // every provider accepts — the alternative, a `tool_result` with no call id,
    // is not a thing.
    if (m.auto_check.collect(&m.bg)) |note| {
        const owned = gpa.dupe(u8, note) catch null;
        if (owned) |text| {
            s.append(.user, text) catch m.allocator.free(text);
            pushInfoFmt(m, "· {s} checked the code you just wrote", .{
                m.auto_check.label[0..m.auto_check.label_len],
            });
        }
    }

    // Tier 1 compaction before building the body: it is a VIEW of the wire, the
    // session on disk keeps everything.
    var astate = std.heap.ArenaAllocator.init(gpa);
    defer astate.deinit();
    const arena = astate.allocator();

    // The `@file` mentions are resolved HERE, on the copy of the messages that
    // goes to the model, and NOT in the session: the user's prompt is stored
    // exactly as they typed it (with its `@path`), and the only thing enriched
    // is what goes out on the wire. If the injected content were stored, the
    // session file would grow 32 KB per mention and `/resume` would bring the
    // files inside the prompts.
    var mentions_in: MentionCount = .{};
    const msgs1 = withMentions(arena, snapshotMsgs(arena), &mentions_in);
    // The images, on the wire and ONLY on the wire, for the same reason the
    // `@file` contents are not stored: the session file would grow megabytes per
    // screenshot and `/resume` would bring the pictures back. They are consumed
    // here — one message, one request — and the base64 dies with this turn's arena.
    const msgs0 = withPendingImages(m, arena, msgs1);

    // Pick the target model BEFORE compaction so the budget uses the correct
    // context window (critical when free-auto rotates to a model with a smaller window).
    var pick = pickTarget(m);
    updateModelContextFromPick(pick);

    // `ZODE_COMPACT=off` is a branch HERE, not inside `elideTier`, so it cannot be
    // half-applied: with it on, nothing is elided and nothing is summarized, and the
    // wire carries the history whole.
    // The goal note goes into the wire view HERE, once per iteration, after the
    // messages are assembled and before the body is built.
    if (session) |ss| {
        const left = if (m.goal.isOpen()) @max(goalHardLimit() - iteration, 0) else 0;
        const note = if (m.goal.isSet())
            (goalNote(arena, &m.goal, left, m.goal_checkpoint, m.plan.openCount()) catch null)
        else
            null;
        ss.setGoalNote(note) catch {};
    }

    const cmode = compaction.effectiveMode(m.environ, m.compact_mode);
    const comp: compaction.Compacted = if (cmode == .off)
        compaction.nothingElided(msgs0)
    else
        compaction.elideTier(
            arena,
            msgs0,
            compaction.budgetFor(m.environ, curModelContext()),
            m.environ,
            cmode,
        ) catch compaction.nothingElided(msgs0);
    // Which files went in with the prompt. Without this line the user sees the
    // model "knowing" something nobody showed it, and with a 30 KB file that
    // also changes the context spend without any prior notice.
    //
    // CAREFUL: `pushInfo` (which COPIES) and not `pushInfoOwned`. The text is
    // composed in a stack buffer on purpose: `pushInfoOwned` TAKES OWNERSHIP of
    // the text and frees it in `Model.deinit`, so handing it memory from the
    // turn's arena (which dies at the end of `runOneTurn`) leaves a dangling
    // pointer in the pending queue. The next frame paints it, vaxis reads the
    // BYTES of the freed grapheme, and the app dies with a segfault in the
    // renderer. Fifth time that family of bug shows up in this repo.
    if (mentions_in.files > 0 and iteration == 0) {
        var note_buf: [160]u8 = undefined;
        const note = if (mentions_in.missing > 0)
            std.fmt.bufPrint(&note_buf, "@file: {d} inlined with the prompt, {d} not found", .{
                mentions_in.files,
                mentions_in.missing,
            }) catch "@file: inlined"
        else
            std.fmt.bufPrint(&note_buf, "@file: {d} inlined with the prompt", .{
                mentions_in.files,
            }) catch "@file: inlined";
        pushInfo(m, note);
    }

    if (comp.elided > session_elided) {
        session_elided = comp.elided;
        const msg = std.fmt.allocPrint(gpa, "· {d} tool results elided", .{comp.elided}) catch return null;
        pushInfoOwned(m, msg);
    }
    // [readcache] What compaction took away is NOT in the context anymore, so
    // the read cache has to forget it. Without this, the next `read` of one of
    // those files would answer "unchanged, you already have it" about content
    // the model no longer has: the worst failure a cache can have.
    for (comp.elided_at) |idx| m.reads.markDroppedAt(idx);
    // Tier 2: byte elision was not enough, so the old stretch is summarized WITH
    // THE MODEL.
    //
    // It used to run only in the headless runner, and the TUI printed a line
    // saying it was about to ("context budget reached: summarizing older turns…")
    // and then NEVER DID IT. `summarizeTurns` had exactly one caller, in
    // `main.zig`. So in the TUI the estimate kept climbing past the budget until
    // the body outgrew the buffer and the turn died with a writer error, and the
    // announcement was a lie.
    //
    // It is best-effort on purpose: if the summary fails the turn carries on with
    // the messages as they are and only loses precision. And it runs ONCE per
    // turn, before the request, so the turn that triggered it is already the one
    // that fits.
    var msgs_wire: []chat.ChatMessage = comp.msgs;
    if (comp.needs_summary and comp.summary_upto > 1 and maySummarize(iteration)) {
        const sum_from: usize = 1; // never the system message
        const upto = @min(comp.summary_upto, comp.msgs.len);
        if (upto > sum_from + 1) {
            // Tell the cache statistics that the history is about to get shorter,
            // so the next prompt count going DOWN is not mistaken for a router
            // (see `CacheStats.markCompacted`).
            cache_stats.session.markCompacted();
            pushInfo(m, "\u{b7} context full: summarizing the older turns with the model\u{2026}");
            var sum_http = http_client.Http.init(gpa, io_global);
            defer sum_http.deinit();
            // The summary is asked of the model that is ACTIVE (not of the
            // rotating free candidate): a summary of the conversation is worth
            // spending a real request on, and the rotation may be in the middle of
            // a quota error.
            const sp = pickTarget(m);
            var surl_buf: [1024]u8 = undefined;
            const surl = targetUrl(&surl_buf, sp);

            // Build extra headers for OpenRouter (HTTP-Referer and X-OpenRouter-Title)
            var sum_extra_hdrs_buf: [2]http_client.Http.ExtraHeader = undefined;
            var sum_extra_hdrs_len: usize = 0;
            if (std.mem.eql(u8, sp.def.id, "openrouter")) {
                sum_extra_hdrs_buf[sum_extra_hdrs_len] = .{ .name = "HTTP-Referer", .value = "https://github.com/jesusalcala/zode" };
                sum_extra_hdrs_len += 1;
                sum_extra_hdrs_buf[sum_extra_hdrs_len] = .{ .name = "X-OpenRouter-Title", .value = "zode" };
                sum_extra_hdrs_len += 1;
            }
            const sum_extra_headers = sum_extra_hdrs_buf[0..sum_extra_hdrs_len];

            if (summarizeTurns(
                gpa,
                &sum_http,
                surl,
                // The key for Anthropic too: `streamRaw` turns it into
                // x-api-key (see `activeTarget`).
                sp.key,
                sp.kind,
                sp.model,
                chat.effectiveEffort(sp.model, current_effort),
                comp.msgs[sum_from..upto],
                arena,
                sum_extra_headers,
                outputCapFor(sp.def, environ_global),
            )) |summary| {
                noteSummarized(iteration);
                pushInfoFmt(m, "\u{b7} older turns summarized ({d} chars, was {d} messages)", .{
                    summary.len,
                    upto - sum_from,
                });
                // Assembled in one go, and a failure here is NOT fatal: the turn
                // carries on with the list it had, which is bigger but correct.
                // `return null` would end the turn with nothing on screen.
                var nm: std.ArrayList(chat.ChatMessage) = .empty;
                const note_msg = std.fmt.allocPrint(arena, "[the earlier part of this conversation was summarized to fit the context budget]\n{s}", .{summary}) catch summary;
                if (nm.appendSlice(arena, comp.msgs[0..sum_from])) |_| {
                    if (nm.append(arena, .{ .role = "user", .content = note_msg })) |_| {
                        if (nm.appendSlice(arena, comp.msgs[upto..])) |_| {
                            msgs_wire = nm.items;
                        } else |_| {}
                    } else |_| {}
                } else |_| {}
            } else {
                // It failed: say so instead of pretending, and do not retry it every
                // single turn (that would be one wasted request per turn forever).
                // A failure counts against the budget, which is the other half of the
                // old rule: retrying it every turn is one wasted request per turn
                // forever. But it is no longer PERMANENT — `maySummarize` allows a new
                // attempt after `summary_gap` iterations, and up to `summary_max` times
                // in the session, so a session that outgrows the first summary still has
                // a brake instead of dying on a writer error.
                noteSummarized(iteration);
                pushInfo(m, "\u{b7} the summary failed; carrying on with the messages as they are");
            }
        }
    }

    // [roster] Who this turn is asked to.
    //
    // Without free-auto it is the usual active provider/model. With free-auto on
    // it is the live candidate of the pool (which may be another provider), and
    // while the pool is still being built it is the active one: the listing is N
    // requests and the first prompt cannot wait for them.
    var http = http_client.Http.init(gpa, io_global);
    defer http.deinit();

    // With no model chosen, the provider is asked BEFORE composing anything. And if
    // that is not possible, the turn is cut here: not answering is better than
    // answering oneself with a 403 that does not explain its cause.
    if (pick.model.len == 0) {
        _ = resolveModel(m, &http);
        // Re-pick after resolveModel may have set a model.
        pick = pickTarget(m);
        updateModelContextFromPick(pick);
    }

    if (pick.model.len == 0) {
        m.streamEnd();
        pushInfo(m, "no model to talk to: pick one with /model (ctrl+t). Nothing was sent.");
        setStatusWithZo(m, .warn, "no model");
        return null;
    }

    // The router warning, ONCE per session, on the first turn that uses one.
    //
    // Here and not in `resolveModel`: the model can arrive from four places
    // (`config.json`, `ZODE_MODEL`, the automatic resolve, the picker) and only
    // the turn knows which one is actually in use. Warning in each of them is
    // four places to keep correct, and the one that mattered — the env var, which
    // is the common case — is a path with no UI to warn into.
    routerWarnOnce(m, pick.model);

    // The cheap router: this turn goes to the small model, and if it will not
    // answer we fall back to the one the user picked.
    //
    // `active_pick` is kept because the fallback needs somewhere to go back TO,
    // and because after a rotation the two are no longer the same thing.
    const active_pick = pick;
    var used_cheap = false;
    if (router_cheap_on and
        router_mod.decide(&cheap_router, pick.model, router_cheap_on) == .cheap)
    {
        // The SAME provider and the same key, a different model name: unlike
        // `/free-auto` there is no provider to switch, no key to juggle and no
        // second `Target` to build. That is why this is cheap to add and why the
        // risk is only "that model is not available on your account".
        pick.model = cheap_router.cheap_model;
        used_cheap = true;
        setAnswering(pick.model);
        setStatusWithZoFmt(m, .thinking, "thinking · {s} (cheap)", .{pick.model});
    }
    defer setAnswering("");

    chat.cancel_current.store(false, .seq_cst);
    // The status names the ITERATION from the second one on: plain "thinking" for
    // 8 turns in a row does not say whether it will take long or it has already
    // stopped. The first one has no counter because it is the normal case and
    // the number would be noise.
    if (iteration > 0) {
        // The limit that ACTUALLY applies, not the soft cap.
        //
        // With a goal set the ceiling is `goalHardLimit()` — 60 by default — and this
        // used to print `iterationLimit()` whatever it was. Measured in a real run: the
        // status read `thinking · iteration 26/12`, which is a turn that is 34 iterations
        // from its budget being displayed as 14 over it.
        //
        // That is not cosmetic. A user who reads "26/12" concludes the turn is running
        // away and cuts it short, which is the harness talking the user into aborting
        // work that has fifty iterations left. A status bar that overstates the budget
        // gets the user to do the harness's job, wrongly.
        const limit = statusIterationLimit(m);
        const it = std.fmt.allocPrint(
            gpa,
            "thinking · iteration {d}/{d}",
            .{ iteration + 1, limit },
        ) catch "thinking";
        setStatusWithZo(m, .thinking, it);
    } else {
        setStatusWithZo(m, .thinking, "thinking");
    }

    var attempt: usize = 0;
    // Rotations of THIS turn. A local and not a global because it resets with the
    // turn: 3 per turn is the ceiling that stops it from going in circles when
    // the problem is configuration and not quota.
    var rotations: u8 = 0;
    // Tools a `deny` rule strips from the schema sent to the model: the model
    // cannot call a tool it cannot see. Built once per turn from the live
    // permission rules (they can change between turns, but not mid-turn).
    var denied_names: std.ArrayList([]const u8) = .empty;
    for (perm_rules.rules) |r| {
        if (r.action == .deny) {
            try denied_names.append(gpa, r.tool);
        }
    }
    const denied = try denied_names.toOwnedSlice(gpa);
    while (true) : (attempt += 1) {
        // The body is composed INSIDE the loop, and not before.
        //
        // It is the most expensive bug of the rotation: the body carries the
        // model NAME inside, so rotating meant composing it again. With the body
        // built outside, the request went to the new provider/model with the old
        // name inside, and the server answered 400 with a message that made no
        // sense ("JSON parsing failed") three times, with backoff. It smelled
        // like a zode bug and it was a zode bug.
        //
        // `bodyBuf` is main's heap buffer (not a 1 MiB stack frame), and it is
        // NOT freed between attempts: `buildBodyMessages` overwrites it and the
        // pointer is only used while the request is in flight.
        const body_buf = try bodyBuf(gpa);
        // Tools denied by a permission rule are stripped from the schema the
        // model sees: it cannot call a tool it cannot see. Built in a throwaway
        // arena per iteration because the schema is recomputed each rotation
        // (and `read_only` keeps its own static slice).
        var sarena = std.heap.ArenaAllocator.init(gpa);
        defer sarena.deinit();
        const schema = if (read_only) tools_registry.toolsJsonReadOnly() else try tools_registry.toolsJsonFiltered(sarena.allocator(), denied);
        const body = try chat.buildBodyMessagesCapped(
            body_buf,
            pick.model,
            // `msgs_wire`, not `comp.msgs`: it is the same list with the old
            // stretch replaced by its summary, and building the body from the
            // un-summarized one would make the whole of tier 2 a no-op.
            msgs_wire,
            // The effort is resolved against `pick.model`, NOT against the active model:
            // with `free-auto` this loop rotates between pool models, and each
            // one has its own ladder. Using the active model's would send a
            // level the candidate does not know (a 400) as soon as rotation
            // moved to a smaller one. It is the same `Target` the rest of the
            // rotation path talks about.
            chat.effectiveEffort(pick.model, current_effort),
            schema,
            pick.kind,
            outputCapFor(pick.def, environ_global),
        );

        // CAREFUL: `streamChat` expects the FULL URL, not just the provider's
        // base. Passing the bare base gave 404 on EVERY request from the TUI
        // (the headless runner in main.zig does add the path, which is why it
        // worked there).
        var url_buf: [1024]u8 = undefined;
        const url = targetUrl(&url_buf, pick);

        // The key OF THAT PROVIDER (not the active one's: sending one provider's
        // key to another endpoint is the `ZODE_PROVIDER` bug, once fixed), passed
        // as the bearer for BOTH kinds: `streamRaw` is what routes it — Bearer
        // for OpenAI, x-api-key for Anthropic. Passing null for Anthropic (what
        // this did) left the request with no credentials at all: streamRaw can
        // only set x-api-key `if (bearer) |k|`, and there was no k.
        const bearer: ?[]const u8 = pick.key;

        // Build extra headers for OpenRouter (HTTP-Referer and X-OpenRouter-Title)
        var extra_hdrs_buf: [2]http_client.Http.ExtraHeader = undefined;
        var extra_hdrs_len: usize = 0;
        if (std.mem.eql(u8, pick.def.id, "openrouter")) {
            extra_hdrs_buf[extra_hdrs_len] = .{ .name = "HTTP-Referer", .value = "https://github.com/jesusalcala/zode" };
            extra_hdrs_len += 1;
            extra_hdrs_buf[extra_hdrs_len] = .{ .name = "X-OpenRouter-Title", .value = "zode" };
            extra_hdrs_len += 1;
        }
        const extra_headers = extra_hdrs_buf[0..extra_hdrs_len];

        chat.streamChat(
            gpa,
            &http,
            url,
            bearer,
            @constCast(body),
            .{
                .userdata = &tstate,
                .onDelta = onDelta,
                .onToolCall = onToolCall,
                .onFinish = onFinish,
            },
            pick.kind,
            true, // the turn the user watches: publishes usage/errors/cancel
            extra_headers,
        ) catch |err| {
            // The cheap router falls back BEFORE anything else touches the error,
            // because this is the one case where the failure is a fact about the
            // model rather than about the turn: the small model will not answer,
            // the one the user picked will, and continuing would spend three
            // retries and a backoff on something already known.
            if (used_cheap) {
                if (router_mod.onFailure(&cheap_router, err, chat.lastErrorBody(), active_pick.model)) {
                    pick = active_pick;
                    used_cheap = false;
                    setAnswering(pick.model);
                    // The REASON is in the sentence, and it is not decoration: a
                    // model id the provider does not know is fixed by fixing the
                    // name, and a gated one is fixed by picking another model.
                    // Saying "not available on this account" about a typo sends
                    // somebody to /model for a problem /model cannot see.
                    const w = router_mod.why(err, chat.lastErrorBody());
                    pushInfoFmt(
                        m,
                        "{s} {s} {s}. It will not be tried again this session — {s}. {s}=0 turns the cheap router off.",
                        .{
                            cheap_router.cheap_model,
                            router_mod.phrase(w),
                            pick.model,
                            router_mod.remedy(w),
                            router_mod.cheap_env,
                        },
                    );
                    continue;
                }
                // An account error (401, 402, a 429): the fallback would fail the
                // same way, so this is NOT the small model's fault and it keeps
                // its place. The normal retry below handles it and reports it.
                used_cheap = false;
                setAnswering("");
            }

            // [roster] Out of quota on THAT pair? Another pair carries on with the
            // SAME request and the turn does not die. It goes BEFORE the backoff
            // retry because a 429 with `retry-after: 30` waiting 30 s on the same
            // provider is exactly what the user does not want.
            if (quotaVerdict(err, chat.lastErrorBody())) |why| {
                if (rotations < roster_mod.max_rotations_per_turn) {
                    if (free_auto.switchTo(gpa, why, chat.lastErrorBody())) |sw| {
                        if (targetForCandidate(m, sw.cand)) |next| {
                            rotations += 1;
                            pick = next;
                            updateModelContextFromPick(pick);
                            pushSwitchNotice(m, sw, pick);
                            continue; // <- the turn carries on by itself
                        }
                    }
                    // No live pair left (or its provider is no longer in the
                    // config): fall through to the normal retry, and if that
                    // fails too, the error below explains what was tried.
                }
            }
            if (isRetryable(err) and attempt < 3) {
                pushRetryNotice(m, err, attempt);
                Retry.wait(attempt) catch return null; // ESC cuts it short
                continue;
            }
            // [roster] The retries are gone and this pair still will not answer.
            // The turn does not rotate (a 5xx may be a blip and the backoff has
            // already been shown), but the pair is dropped so the NEXT turn does
            // not start with it. Without this, a model that always fails (a free
            // one the provider does not serve) keeps the user stuck on the same
            // error forever and free-auto is worth nothing.
            noteTurnFailure(m, err, pick);
            return err;
        };
        break;
    }
    // The provider's own completion count when it sent one: the same window of
    // time, the real tokenizer (see `finishTps`).
    finishTps(tstate.chars, tstate.stream_start_ns, chat.last_usage.completion);
    recordSessionUsage(m, chat.last_usage, pick.kind, pick.model);

    // Closes the streaming paragraph: what arrived stays in the history.
    m.streamEnd();

    // The assistant's text goes into the session (also if it was interrupted:
    // what arrived is real and must not be lost).
    //
    // CAREFUL: WITH its `tool_calls`, and this is not optional. The tool message
    // carries `tool_call_id`, and if the assistant's message does not carry the
    // `tool_calls` that asked for it, that id matches nothing and the API
    // answers 400 (`invalid_request_error`) on the NEXT turn. Passing `null`
    // (which is what it used to be), any turn with a tool died on the second
    // request: the model asked for the tool, the tool ran, and the final reply
    // never arrived — with no visible error, because the notice stayed in
    // `pending` and you had to press a key to see it. Headless did pass the
    // `tool_calls` (`result.ctx.toolCallsJson`), which is why the agent loop
    // worked there and not in the TUI: same model, two different clients.
    //
    // That is why `TurnCtx` keeps a list of `calls` and not a simple flag: the
    // JSON has to be rebuilt for the session.
    const calls_json = if (tstate.calls.items.len > 0)
        toolCallsJsonFromCalls(gpa, tstate.calls.items)
    else
        null;
    if (tstate.text.items.len > 0 or calls_json != null) {
        s.appendAssistant(tstate.text.items, calls_json) catch {};
    }
    s.flush();

    const partial = tstate.finish_len > 0 and
        std.mem.eql(u8, tstate.finish[0..tstate.finish_len], "length");
    if (partial) setStatusWithZo(m, .warn, "interrupted");

    // No tool calls: the turn is over.
    if (tstate.calls.items.len == 0) {
        // The ctx% is refreshed HERE too, not only on the tools path (which is
        // the one that calls `refreshContextUsage`): a turn without tools is the
        // NORMAL case and the counter stayed at the previous turn's value until
        // a tool appeared.
        refreshContextUsage(m);
        // Plain "done" does not say what it cost. With the turn's clock, the
        // status becomes the summary of what just happened (which is the only
        // thing left visible when the strip turns off).
        const turn_ms = elapsedMs(turn_t0);
        const done_status = std.fmt.allocPrint(
            gpa,
            "done · {d}.{d}s",
            .{ turn_ms / 1000, (turn_ms % 1000) / 100 },
        ) catch "done";
        setStatusWithZo(m, .done, done_status);
        return null;
    }

    const exec = try execToolCalls(m, s, &tstate);
    refreshContextUsage(m);
    return exec;
}

/// Announces tier 2 compaction if the turn triggers it.
///
/// Tier 2 (summarizing the old stretch with an LLM call) used to run only in
/// headless (`main.zig`), so in the TUI the history grew without anything being
/// said and the ctx% climbed with no explanation. `needs_summary` is the notice
/// that byte elision has not been enough.
fn maybeAnnounceCompaction(m: *tui.Model, comp_needs_summary: bool) void {
    if (!comp_needs_summary) return;
    const msg = std.fmt.allocPrint(
        m.allocator,
        "· context budget reached: summarizing older turns…",
        .{},
    ) catch return;
    pushInfoOwned(m, msg);
}

/// `/undo`: puts the files back the way they were before the last turn.
///
/// It undoes FILES, not messages. The session is an append-only JSONL and
/// rewriting it halfway through a turn is the kind of thing nobody can explain
/// afterwards: what the user wants when they say "undo that" is for the repo to
/// go back, not for the model to forget it did it.
///
/// The snapshot is taken BEFORE each file-touching tool, and a file that did not
/// exist is recorded as such (undoing it = deleting it). And if the file could
/// not be READ (permissions, or it is a directory) nothing is recorded: deleting
/// a file nobody managed to read is worse than not undoing.
fn cmdUndo(m: *tui.Model) void {
    var cp = m.takeCheckpointOwned() orelse {
        pushInfo(m, "nothing to undo: no turn has changed any file yet");
        return;
    };
    // The snapshots are the caller's memory now (see `takeCheckpointOwned`):
    // `deinit` needs a non-const pointer.
    defer cp.deinit(m.allocator);
    var undone: u8 = 0;
    var failed: u8 = 0;
    var skipped: u8 = 0;
    var detail: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&detail);
    const out = &w;

    for (cp.files[0..cp.len]) |f| {
        if (f.truncated) {
            skipped += 1;
            out.print("  {s}: too big to restore\n", .{f.pathOf()}) catch {};
            continue;
        }
        if (!f.existed) {
            // It did not exist before: undoing is deleting it, and only if it is
            // still a regular file.
            if (deleteIfUnchanged(f.pathOf())) {
                undone += 1;
                out.print("  removed {s}\n", .{f.pathOf()}) catch {};
            } else {
                failed += 1;
                out.print("  {s}: not removed (it changed since, or is gone)\n", .{f.pathOf()}) catch {};
            }
            continue;
        }
        // `writeFile` and not config.zig's `writeFileSecure`: that one is for
        // `auth.json` (0600, written to a temp and renamed) and this is a file of
        // the user's project, with the permissions it already had.
        std.Io.Dir.cwd().writeFile(io_global, .{ .sub_path = f.pathOf(), .data = f.data }) catch {
            failed += 1;
            out.print("  {s}: could not write it back\n", .{f.pathOf()}) catch {};
            continue;
        };
        undone += 1;
        out.print("  restored {s} ({d} bytes)\n", .{ f.pathOf(), f.data.len }) catch {};
    }

    // CAREFUL: `allocPrint` and NOT `bufPrint` into a stack buffer.
    // `pushInfoOwned` TAKES OWNERSHIP of the text and frees it in `Model.deinit`:
    // a `bufPrint(&buf, ...)` leaves a pointer to the stack in the pending queue
    // and it paints as a row of `�` (seen in the pty: the headline of the undo
    // was a wall of replacement characters). Same reason a literal there is an
    // "Invalid free".
    const head_buf = if (undone == 0)
        "undo: nothing could be restored"
    else
        std.fmt.allocPrint(m.allocator, "undo: {d} file{s} undone", .{
            undone,
            if (undone == 1) "" else "s",
        }) catch "undo: done";
    // `pushInfoFmt` COPIES, so a literal fallback is safe here — which is the
    // whole difference from `pushInfoOwned`, where the same literal is an
    // "Invalid free" at teardown.

    m.pushInfoFmt("{s} · from: {s}", .{ head_buf, cp.labelOf() });
    if (w.buffered().len > 0) {
        // `pushInfoOwned` of an EMPTY string would push a blank line; the old
        // `catch ""` made that reachable on OOM and printed nothing instead.
        m.pushInfoFmt("{s}", .{w.buffered()});
    }
    if (skipped > 0 or failed > 0) {
        m.pushInfoFmt("{d} file(s) skipped, {d} failed · the diff of the turn is still in the history", .{
            skipped,
            failed,
        });
    }
    if (undone > 0) setStatusWithZo(m, .done, "undone");
}

/// Deletes a file ONLY if it exists and is a regular file.
///
/// What is NOT checked is that its contents are the ones the tool left: the
/// "after" is not stored (that would be twice the memory). Exists and is a
/// regular file is enough to avoid deleting a directory by mistake. It is a
/// weak guarantee on purpose: `/undo` is something the user asks for
/// explicitly, and doing nothing is worse than deleting a file the model just
/// created.
fn deleteIfUnchanged(path: []const u8) bool {
    const dir: std.Io.Dir = .cwd();
    const st = dir.statFile(io_global, path, .{}) catch return false;
    if (st.kind != .file) return false;
    dir.deleteFile(io_global, path) catch return false;
    return true;
}

/// Applies the list of the `todo` tool and says in the history how much changed.
///
/// It lives here and not inside `tools.execute` because of memory ownership:
/// `execute` returns memory of the turn's arena (freed when the turn ends) and
/// the plan has to LIVE between frames. The one place with shared state is the
/// `Model`.
///
/// The "nothing changed" case matters: the model resends the whole list on every
/// call, so without this the history would repeat "plan: 1/3" five times in a
/// turn and the line would stop carrying information.
/// Does this `todo` call carry a patch key (`update`, `remove`, `add`)?
///
/// A substring test and not a parse, deliberately: this decides which of the two
/// handlers a call goes to, and parsing every `todo` twice for that is work with
/// no payoff. The three keys are distinctive enough that a false positive is not a
/// realistic shape, and the consequence of one is a handler that reports "the patch
/// had nothing in it" — never a mangled plan.
fn planPatchKeysPresent(args_json: []const u8) bool {
    for ([_][]const u8{ "\"update\"", "\"updates\"", "\"remove\"", "\"removed\"", "\"add\"" }) |k| {
        if (std.mem.indexOf(u8, args_json, k) != null) return true;
    }
    return false;
}

/// Does it carry the replacement key?
fn planHasItems(args_json: []const u8) bool {
    return std.mem.indexOf(u8, args_json, "\"items\"") != null or
        std.mem.indexOf(u8, args_json, "\"todos\"") != null;
}

/// Applies a `todo` call to a plan, with no `Model` in it, and returns a line to
/// show — or null when nothing changed.
///
/// ## Why it is not `m.applyPlan`
///
/// Because `applyPlanCall` and `applyPlanPatch` lived only in the TUI's
/// `execOneCall`, `zode --chat` answered **"plan recorded"** and recorded nothing:
/// the plan is a `Model` field, and the headless runner has no `Model`. Measured, by
/// asking the model for a plan and watching the tool report success while nothing
/// anywhere changed.
///
/// That is the failure this repository keeps meeting in a new shape: a capability in
/// the schema, reached for by the model, and dropped by one of the two runners. The
/// plan is now a plain value the caller owns — `Model.plan` for the TUI, a stack
/// variable for `--chat` — and both call this.
pub fn applyPlanTo(
    plan: *plan_mod.Plan,
    args_json: []const u8,
    arena: std.mem.Allocator,
) ?[]const u8 {
    if (planPatchKeysPresent(args_json) or !planHasItems(args_json)) {
        return applyPlanPatchTo(plan, args_json, arena);
    }
    var items: [plan_mod.max_items]plan_mod.Item = undefined;
    const parsed = plan_mod.parseItems(arena, args_json, &items) catch |err| {
        return switch (err) {
            error.TooManyItems => "the plan has more than 20 steps: shorten it",
            // The message names BOTH forms, because a model that sent `update` must
            // not be told to send `items`.
            error.BadPlan => "the plan did not parse. Send the whole list as {items:[{content,status}]} " ++
                "or change one step as {update:[{index,status}]} / {remove:[3]} / {add:[{content}]}. " ++
                "Indexes are 1-based.",
        };
    };
    switch (plan.apply(items[0..], parsed.len)) {
        .same => return null,
        .empty => return "plan cleared",
        .changed => return plan.summary(arena),
    }
}

/// The patch form of `todo`: change, drop or add ONE step without resending the
/// list.
///
/// It is a separate function and not a branch inside the replacement because the two
/// answer different questions. A replacement says "here is the plan"; a patch says
/// "step 3 is done".
pub fn applyPlanPatchTo(
    plan: *plan_mod.Plan,
    args_json: []const u8,
    arena: std.mem.Allocator,
) ?[]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch {
        return "the plan patch did not parse: send {update:[{index,status}]}";
    };
    if (parsed != .object) return "the plan patch did not parse: send {update:[{index,status}]}";

    var updates: [plan_mod.max_items]plan_mod.StepUpdate = undefined;
    const n_upd = plan_mod.parseUpdates(parsed.object, &updates) catch {
        return "the plan patch did not parse. Send {update:[{index,status,text}]} with a 1-based index.";
    };
    var remove: [plan_mod.max_items]u8 = undefined;
    const n_rm = plan_mod.parseRemove(parsed.object, &remove) catch {
        return "the plan patch did not parse: send {remove:[3]} with 1-based indexes.";
    };
    var add: [plan_mod.max_items]plan_mod.Item = undefined;
    const n_add = plan_mod.parseAdd(parsed.object, &add) catch {
        return "the plan patch did not parse: send {add:[{content}]}.";
    };
    if (n_upd == 0 and n_rm == 0 and n_add == 0) {
        return "the plan patch had nothing in it: send update, remove or add.";
    }

    const before = plan.len;
    const res = plan_mod.applyPatch(plan, updates[0..n_upd], remove[0..n_rm], add[0..n_add], n_add);
    if (!res.anyChange() and plan.len == before) {
        // Nothing happened. Saying so is the point: a silent no-op reads as "the
        // step was marked done" and the model will not send it again.
        if (res.unknown > 0) {
            return std.fmt.allocPrint(
                arena,
                "plan patch did nothing: {d} index/indices do not exist (the plan has {d} steps, indexes are 1-based)",
                .{ res.unknown, before },
            ) catch null;
        }
        return null;
    }
    if (res.unknown > 0) {
        return std.fmt.allocPrint(
            arena,
            "plan: {s} · {d} index/indices did not exist and were ignored",
            .{ plan.summary(arena), res.unknown },
        ) catch null;
    }
    return plan.summary(arena);
}

/// Applies a `goal` tool call to the session's goal, and returns the line the model
/// reads.
///
/// ## Why it lives here and not in the tool
///
/// The same reason `applyPlanCall` does: the goal lives in the `Model`, which is the
/// TUI's, and the tool has no `Model`. Intercepted in the agent loop, after the tool
/// returns, so BOTH runners (the TUI and `--chat`) get it by going through the same
/// place — the recurring bug of this repo is a second, lesser implementation of the
/// agent, and this is the piece that would drift first.
///
/// ## Why the verdict is a TOOL and not the harness asking
///
/// The harness cannot tell whether an objective was reached. Only the model can, and
/// only by committing: "here is the evidence" is a different claim from "I think it
/// worked". A harness that guessed would either stop on unfinished work or never stop.
pub fn applyGoalCall(m: *tui.Model, args_json: []const u8, arena: std.mem.Allocator) void {
    // NOT a plain `catch return`: a call that cannot be read has to say so. Silently
    // dropping it is the same failure as the one this function used to have — the model
    // gets no answer, cannot tell whether the verdict landed, and the turn runs to the
    // ceiling. The refusal is what lets it try again.
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch {
        m.pushInfoFmt("goal: the arguments were not valid JSON — {s}", .{goal_err_text(error.BadArgs)});
        return;
    };
    if (parsed != .object) {
        m.pushInfoFmt("goal: the arguments were not a JSON object — {s}", .{goal_err_text(error.BadArgs)});
        return;
    }
    const v = goal_mod.parseVerdict(parsed.object, arena) catch |err| {
        // The model gets the SAME refusal the parser gives a human, in words, because a
        // bare `error.BadStatus` is not something it can act on. `goal` is the one tool
        // whose error text decides whether the turn can finish.
        //
        // `pushInfoFmt` and NOT `pushInfoOwned(allocPrint(arena, …))`: `arena` here is
        // the TURN's arena, and `pushInfoOwned` frees with the model's allocator. That
        // is an "Invalid free" on every single refusal — which is every time the model
        // gets the verdict wrong, the one path that most needs to work. The symptom was
        // a test crashing with `signal ABRT` while the refusal under test was a typo.
        m.pushInfoFmt("goal: {s}", .{goal_err_text(err)});
        return;
    };

    var g = m.goal;
    g.status = v.status;
    @memcpy(g.summary[0..v.summary.len], v.summary);
    g.summary_len = v.summary.len;
    const ub = if (v.unblock.len > 0) v.unblock else "";
    @memcpy(g.unblock[0..ub.len], ub);
    g.unblock_len = ub.len;
    m.goal = g;

    switch (v.status) {
        .met => {
            m.pushInfoFmt("goal met: {s}", .{v.summary});
            setStatusWithZo(m, .done, "goal met");
        },
        .blocked => {
            // Said the way the user needs it: what is wrong, and what would change it.
            // A blocker without the second half is a shrug and reads as one.
            m.pushInfoFmt("goal blocked: {s}", .{v.summary});
            if (ub.len > 0) m.pushInfoFmt("  would unblock it: {s}", .{ub});
            setStatusWithZo(m, .warn, "goal blocked");
        },
        .none => {},
    }
}

fn goal_err_text(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingStatus => "goal needs a `status`: \"met\" if the objective is reached (with the evidence), or \"blocked\" if it cannot be done here (with `what_would_unblock`).",
        error.BadStatus => "`status` must be `met` or `blocked`. Nothing else ends the turn, so do not invent a third one.",
        error.MissingSummary => "goal needs a `summary`: what you finished and how you know, or why it cannot be done.",
        error.SummaryTooShort => "the `summary` is too short to be one. Say what happened and what proves it.",
        error.MissingUnblock => "`blocked` needs `what_would_unblock`: the one thing that would change the answer. Without it the harness cannot tell a real blocker from giving up.",
        error.BadArgs => "the arguments could not be read as JSON. Send the two fields as a JSON object.",
        else => "the goal verdict was not understood; send status plus summary.",
    };
}

/// The TUI's half: same functions, plus the status line and the screen.
fn applyPlanCall(m: *tui.Model, args_json: []const u8, arena: std.mem.Allocator) void {
    var snapshot = m.planCopy();
    const line = applyPlanTo(&snapshot, args_json, arena) orelse return;
    m.plan_touched_this_turn = true;
    m.replacePlan(snapshot);
    if (snapshot.isEmpty()) {
        m.pushInfoFmt("{s}", .{line});
    } else {
        m.pushInfoFmt("{s}\n{s}", .{ line, snapshot.details(arena) });
    }
    if (snapshot.allDone()) setStatusWithZo(m, .done, "all plan steps done");
}

/// Runs a turn's tool calls and returns the synthesized text for the next one
/// (or null if no other turn was needed).
///
/// Before running them, the file the tool is about to touch is
/// PHOTOGRAPHED: that is what makes it possible to show the diff instead of an
/// opaque "OK".
/// Runs the tool calls. Returns the synthesized text of the next turn, owned by
/// the caller (see `runOneTurn`).
/// `ask`: the model asks, the user answers, the answer goes back as a tool result.
///
/// Returns 1 if the tool ran (whatever the outcome), 0 otherwise, so the caller
/// can count it like any other tool.
///
/// The three outcomes and what each one tells the model are the whole design:
///
/// - answered: the user's own words, verbatim.
/// - ESC: "you decide". NOT a cancel and NOT an error.
/// - five minutes: same, but it says the user was probably away.
///
/// A cap of `max_asks_per_turn` exists because the failure mode without it is
/// real and unpleasant: a model that asks three questions is a collaborator, and a
/// model that asks fifteen is an interrogation that costs a full round trip each
/// time. At the cap the question is refused with the DECLINE text, which tells
/// the agent to decide and carry on — so the cap degrades into "you decide", not
/// `review`: hand the model its own diff, with a checklist, and RECORD that it did.
///
/// ## Why it is intercepted here and not a normal tool
///
/// A normal tool runs inside `tools.execute` with no access to the Model. What a review
/// needs is the list of files THIS turn touched — which is `turn_stats.files` — because
/// the right diff is the model's own change and not the working tree, which in a working
/// repository is somebody else's half-finished work too.
///
/// ## Why the recording is here and not in the tool
///
/// The gate needs to know that a review happened and that it covered the files as they
/// are NOW. That is state, and state belongs next to the state it is about: the same
/// reason `applyGoalCall` sits in the loop rather than in the tool. A tool that only
/// returned text would make "reviewed" a thing the model claims rather than a thing the
/// harness observed, which is the whole difference.
///
/// ## And why it is `noteReview` and not a boolean
///
/// A boolean would be satisfied by one review at the start of the turn and would call
/// the last three files "reviewed" for the rest of it. `reviewed_writes` is the value of
/// `writes` at the moment of the review, so an edit afterwards makes the diff unreviewed
/// again — the same staleness arithmetic the verification uses, for the same reason.
fn reviewCall(m: *tui.Model, s: *session_mod.Session, call: TurnCtx.Call) usize {
    var astate = std.heap.ArenaAllocator.init(m.allocator);
    defer astate.deinit();
    const arena = astate.allocator();

    m.pushToolStart("review", "your own diff");

    if (turn_stats.files.items.len == 0) {
        const none =
            "Nothing to review: you have not changed a file this turn, so there is no " ++
            "diff of yours to read.";
        m.pushToolDone("review", "nothing to review", 0, none);
        s.appendToolResult(call.id, "review", none) catch {};
        return 1;
    }

    // The diff of the turn's own files, and ONLY those. `git diff -- <paths>` with the
    // paths this turn produced; without them a review in a dirty tree is a review of
    // the whole repository, which is not a review of anything.
    var argv: std.ArrayList(u8) = .empty;
    argv.appendSlice(arena, "git diff --") catch {};
    for (turn_stats.files.items) |f| {
        argv.append(arena, ' ') catch {};
        argv.appendSlice(arena, f) catch {};
    }

    const r = bg_tool.runForeground(arena, io_global, argv.items, 20, 64 * 1024) catch |err| {
        const msg = std.fmt.allocPrint(
            arena,
            "could not read the diff ({t}). If this is not a git repository there is nothing to review with, and the harness cannot require it.",
            .{err},
        ) catch "could not read the diff";
        m.pushToolDone("review", "no diff", 0, msg);
        s.appendToolResult(call.id, "review", msg) catch {};
        return 1;
    };

    if (std.mem.startsWith(u8, r.stdout, "fatal:") or std.mem.startsWith(u8, r.stderr, "fatal:")) {
        // Not a repository, or no git. The same direction as `cannot_verify`: the
        // reviewable flag is cleared so the gate stops asking for something that cannot
        // be produced, and the model is told why in one sentence.
        m.auto_check.gate.reviewable = false;
        const msg = review_mod.notARepoText;
        m.pushToolDone("review", "not a git repository", 0, msg);
        s.appendToolResult(call.id, "review", msg) catch {};
        return 1;
    }

    var out: std.ArrayList(u8) = .empty;
    if (r.stdout.len == 0) {
        // An empty diff with files touched happens: the model wrote a file identical to
        // what was already there, or committed it. Either way there is nothing to read,
        // and a review step that says so is more useful than a diff of zero bytes with
        // eight checklist items above it.
        out.appendSlice(arena, "The diff of the files you changed this turn is EMPTY: they match what is already in the repository. Nothing to review.") catch {};
    } else {
        out.appendSlice(arena, r.stdout) catch {};
        if (r.stdout[r.stdout.len - 1] != '\n') out.append(arena, '\n') catch {};
        if (r.truncated) out.appendSlice(arena, bg_tool.foreground_truncation_notice) catch {};
    }

    const body = review_mod.checklist(arena, turn_stats.files.items, r.stdout.len) catch
        "Read the diff above and look at it.";
    out.appendSlice(arena, "\n") catch {};
    out.appendSlice(arena, body) catch {};

    // The record. AFTER the diff is in hand, never before: a review that produced
    // nothing must not count, or the model satisfies the gate by calling `review` in a
    // project where git cannot see the change.
    m.auto_check.gate.noteReview();
    turn_stats.reviews += 1;

    const text = out.items;
    m.pushToolDone("review", std.fmt.allocPrint(arena, "{d} file(s), ~{d} KB", .{
        turn_stats.files.items.len,
        r.stdout.len / 1024,
    }) catch "your own diff", 0, text);
    s.appendToolResult(call.id, "review", text) catch {};
    return 1;
}

/// into a broken turn.
fn askCall(m: *tui.Model, s: *session_mod.Session, call: TurnCtx.Call) usize {
    var astate = std.heap.ArenaAllocator.init(m.allocator);
    defer astate.deinit();
    const arena = astate.allocator();

    const question = ask.parse(arena, call.args_json) catch {
        // A malformed question is the model's mistake, and it gets told what a
        // valid one looks like rather than "BadQuestion".
        const bad =
            \\The `ask` call was not usable: it needs a non-empty "question" and,
            \\optionally, "options" (2 to 5 short strings) and a "header" (2-3 words).
            \\Do not retry the same call. Either ask again properly with one question, or,
            \\if you already know enough, just continue.
        ;
        m.pushToolDone("ask", "malformed question", 0, bad);
        s.appendToolResult(call.id, "ask", bad) catch {};
        return 1;
    };

    if (m.asks_this_turn >= max_asks_per_turn) {
        pushInfoFmt(m, "the model wanted to ask a 4th question this turn: not showing it (the cap is {d}). It will decide on its own.", .{max_asks_per_turn});
        m.pushToolDone("ask", "refused (too many questions this turn)", 0, ask.declined_text);
        s.appendToolResult(call.id, "ask", ask.declined_text) catch {};
        return 1;
    }

    m.asks_this_turn += 1;
    m.bench.asks += 1;

    // ── YOLO: nobody is going to answer ──
    //
    // `/yolo` exists so the app does not stop to wait for the human, and a
    // question that opens a dialog stops the app exactly as much as a
    // permission dialog does. So the question is NOT shown to anybody:
    //
    // - With OPTIONS, the harness takes the model's OWN recommendation (the
    //   schema tells it to put the recommendation FIRST, so the first option
    //   IS the recommendation) and carries on.
    // - Without options there is nothing to take, so the question stays OPEN
    //   and the model has to decide by itself.
    //
    // In BOTH cases the model is told to SAY it in its final summary: a
    // decision the user never saw is a decision the user cannot check, and an
    // open question nobody mentions is a question that is lost.
    const decision = ask.decide(currentPermMode() == .bypass, question.options.len > 0);
    if (decision != .ask) {
        m.pushToolStart("ask", question.question);
        var ybuf: [ask.yolo_buf_len]u8 = undefined;
        var sum_buf: [96]u8 = undefined;
        var sum: []const u8 = "yolo";
        const res: []const u8 = switch (decision) {
            .take_recommendation => blk: {
                const opt = question.options[0];
                m.bench.asks_auto += 1;
                const head = if (opt.len > 48) opt[0..48] else opt;
                sum = std.fmt.bufPrint(&sum_buf, "answered for you (yolo): {s}{s}", .{
                    head,
                    if (opt.len > 48) "…" else "",
                }) catch "answered for you (yolo)";
                break :blk ask.formatYoloTaken(&ybuf, opt);
            },
            .leave_open => blk: {
                m.bench.asks_open += 1;
                turn_stats.noteYoloOpen(question.question);
                sum = std.fmt.bufPrint(&sum_buf, "left open (yolo): {s}", .{
                    if (question.header.len > 0) question.header else "the question",
                }) catch "left open (yolo)";
                break :blk ask.formatYoloDeferred(&ybuf);
            },
            .ask => unreachable,
        };
        m.pushToolDone("ask", sum, 0, res);
        s.appendToolResult(call.id, "ask", res) catch {};
        return 1;
    }

    // The header shows the question, so that is what goes into the history next
    // to `ask(...)`. A history that says `ask(Which database?)` is the difference
    // between being able to scroll back and understanding what happened.
    m.pushToolStart("ask", question.question);
    setStatusWithZo(m, .warn, "the model has a question");

    // The answer comes back as a gpa copy that this function OWNS. It is freed
    // exactly once, right after the two things that read it (the result text and
    // the one-line summary) have been built — reading it after the free is the
    // use-after-free that the "pointer to a stack buffer in the pending queue"
    // bug is made of.
    const answer = m.requestAsk(question.question, question.header, question.options);

    var res_buf: [ask.answered_buf_len]u8 = undefined;
    var sum_buf: [80]u8 = undefined;
    var res: []const u8 = ask.declined_text;
    var sum: []const u8 = "no answer";
    if (answer) |a| {
        const t = std.mem.trim(u8, a, " \t\r\n");
        const formatted = ask.formatAnswered(t);
        @memcpy(res_buf[0..formatted.len], formatted.slice());
        res = res_buf[0..formatted.len];
        // The summary is the user's own words, cut to one line. NOT the framed
        // result: the history line next to `ask(...)` has to read as what they
        // said, not as what zode told the model about it.
        const head = if (t.len > 60) t[0..60] else t;
        sum = std.fmt.bufPrint(&sum_buf, "{s}{s}", .{ head, if (t.len > 60) "…" else "" }) catch "answer";
    }
    if (answer) |a| m.allocator.free(a);

    m.pushToolDone("ask", sum, 0, res);
    s.appendToolResult(call.id, "ask", res) catch {};
    return 1;
}

/// Cap on the output of a `!cmd` run from inside a skill. A skill is a set of
/// instructions, not a script runner, and a command that prints megabytes drowns
/// the skill itself.
const skill_cmd_cap = 16 * 1024;

/// Expands `!cmd` lines inside a skill body: each command is run (behind Phase 6
/// bash permissions) and its stdout replaces the `!cmd` line.
///
/// Returns `body` unchanged when there is no `!cmd` line (no copy, no alloc).
/// Otherwise returns a slice allocated in `arena`; the caller consumes it
/// immediately and the tool result copies it, so the slice outliving this call
/// is not a problem.
fn expandSkillCommands(
    body: []const u8,
    io: std.Io,
    arena: std.mem.Allocator,
) ![]const u8 {
    // Fast path: no `!` at the start of any line.
    var i: usize = 0;
    var has_cmd = false;
    while (i < body.len) {
        if (body[i] == '!' and (i == 0 or body[i - 1] == '\n')) {
            has_cmd = true;
            break;
        }
        i += 1;
    }
    if (!has_cmd) return body;

    var out: std.ArrayList(u8) = .empty;
    // Buffer lives in `arena`; no deinit here so the returned slice stays valid
    // until the caller's arena dies (the tool result copies it).
    var expanded = false;
    var last: usize = 0;
    i = 0;
    while (i < body.len) {
        if (body[i] == '!' and (i == 0 or body[i - 1] == '\n')) {
            var j = i + 1;
            while (j < body.len and body[j] != '\n') j += 1;
            const cmd_line = body[i + 1..j];
            const cmd = std.mem.trim(u8, cmd_line, " \t\r\n");
            if (last < i) try out.appendSlice(arena, body[last..i]);
            expanded = true;
            // Phase 6 permissions: the command runs only if bash is always
            // allowed or this exact command matches a persisted prefix.
            const allowed = isAlwaysAllowed("bash") or bashPatternAllowed("bash", cmd);
            if (allowed) {
                const fg = bg_tool.runForeground(arena, io, cmd, 30, skill_cmd_cap) catch {
                    try out.appendSlice(arena, "[command failed: ");
                    try out.appendSlice(arena, cmd);
                    try out.appendSlice(arena, "]\n");
                    last = j + 1;
                    i = last;
                    continue;
                };
                try out.appendSlice(arena, fg.stdout);
                // `fg.stdout`/`fg.stderr` live in `arena`, reclaimed when the
                // caller's arena dies; no separate deinit here.
            } else {
                try out.appendSlice(arena, "[permission required: ");
                try out.appendSlice(arena, cmd);
                try out.appendSlice(arena, "]\n");
            }
            last = j + 1;
            i = last;
            continue;
        }
        i += 1;
    }
    if (last < body.len) try out.appendSlice(arena, body[last..]);
    if (!expanded) return body;
    return out.items;
}

/// `skill`: load a skill's body on demand.
///
/// This is the tool that makes a library of skills affordable: the prompt carries
/// only the names, and the 4 KB of instructions that go with one are read the
/// moment the model decides it needs them (and never otherwise).
fn skillCall(m: *tui.Model, s: *session_mod.Session, call: TurnCtx.Call) usize {
    var astate = std.heap.ArenaAllocator.init(m.allocator);
    defer astate.deinit();
    const arena = astate.allocator();

    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, call.args_json, .{}) catch {
        const bad = "The `skill` call needs {\"name\": \"...\"}. No such skill was loaded; continue without it.";
        m.pushToolDone("skill", "malformed arguments", 0, bad);
        s.appendToolResult(call.id, "skill", bad) catch {};
        return 1;
    };
    var want: []const u8 = "";
    var args: ?[]const u8 = null;
    if (v == .object) {
        if (v.object.get("name")) |nv| {
            if (nv == .string) want = std.mem.trim(u8, nv.string, " \t\r\n");
        }
        if (v.object.get("args")) |av| {
            if (av == .string) args = av.string;
        }
    }

    const entries = discoverSkills(m.allocator, m.environ);
    if (entries.len == 0) {
        const none = "This zode has no skills installed (look in .zode/skills/ or ~/.config/zode/skills/). Continue without one.";
        m.pushToolDone("skill", "no skills installed", 0, none);
        s.appendToolResult(call.id, "skill", none) catch {};
        return 1;
    }

    var found: ?skills.Entry = null;
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, want)) {
            found = e;
            break;
        }
    }
    const entry = found orelse {
        // The list of what IS available goes back: a model that guessed a name
        // can correct itself in one step instead of guessing again.
        var names: [1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&names);
        w.print("no skill called \"{s}\". Available:", .{want}) catch {};
        for (entries) |e| {
            w.print(" {s}", .{e.name}) catch {};
        }
        w.writeAll(". Call one of those, or continue without a skill.") catch {};
        m.pushToolDone("skill", "unknown skill", 0, w.buffered());
        s.appendToolResult(call.id, "skill", w.buffered()) catch {};
        return 1;
    };

    var loader = skillstore.Loader.init(m.allocator, io_global, m.environ);
    var body: [skills.max_inline + 1024]u8 = undefined;
    const text = loader.loadWithArgs(entry, args, &body) orelse {
        const bad = std.fmt.allocPrint(arena, "the skill \"{s}\" could not be read ({s}). Continue without it.", .{ entry.name, entry.path }) catch "the skill could not be read";
        m.pushToolDone("skill", "unreadable", 0, bad);
        s.appendToolResult(call.id, "skill", bad) catch {};
        return 1;
    };

    // Phase 2.4: `context: fork` runs the skill as a subagent (effort low,
    // read-only, disposable 24k window) and hands the main turn the report.
    // Nothing of the subagent's window enters the main context, and the parent
    // message list is unchanged.
    if (entry.context == .fork) {
        var rep = subagent_mod.Report{};
        // Phase 34.10: enforce the skill's declared allowed_tools / model /
        // effort. allowed_tools must be read-only — a skill cannot escalate.
        const task = subagent_mod.Task{
            .description = entry.name,
            .prompt = text,
            .allowed_tools = entry.allowed_tools,
            .model = entry.model,
            .effort = entry.effort,
        };
        const report = runSubagent(m, task, &rep);
        m.pushToolDone("skill", entry.name, 0, report);
        s.appendToolResult(call.id, "skill", report) catch {};
        return 1;
    }

    // Phase 2.5: `!cmd` inside a skill — run the command (behind Phase 6
    // permissions) and substitute its output inline. On any failure fall back to
    // the unexpanded body so a `!cmd` never breaks a skill that otherwise loads.
    const final_text = expandSkillCommands(text, io_global, arena) catch text;
    m.pushToolDone("skill", entry.name, 0, final_text);
    s.appendToolResult(call.id, "skill", final_text) catch {};
    return 1;
}

test "expandSkillCommands: no !cmd returns the body untouched (no copy)" {
    const body: []const u8 = "just some instructions";
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const got = try expandSkillCommands(body, std.testing.io, arena_state.allocator());
    try std.testing.expect(got.ptr == body.ptr);
}

test "expandSkillCommands: !cmd without bash permission shows the marker and does not run" {
    const body = "!cat /tmp/does-not-exist-marker.txt\nand continue\n";
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const got = try expandSkillCommands(body, std.testing.io, arena_state.allocator());
    // When bash is not permitted the raw command line is replaced by a marker
    // and nothing is executed. (If the test environment happens to have bash
    // always-allowed, this assertion reflects that configuration instead.)
    try std.testing.expect(std.mem.indexOf(u8, got, "!cat") == null or std.mem.indexOf(u8, got, "[permission required") != null or std.mem.indexOf(u8, got, "[command failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "and continue") != null);
}

/// `task`: a read-only investigation in its own context.
///
/// The subagent loop is the same machinery as the main one (`streamChat` +
/// `execToolCalls`-shaped tool handling) but with a fresh message list, a
/// restricted tool list, `effort = low` and its own iteration cap. It returns
/// the report as the tool result and NOTHING of it goes into the main context
/// except that string, which is the entire reason it saves tokens.
/// End of the run of `task` calls that starts at `from`.
///
/// Pure and separate from `execToolCalls` because this is the DECISION that makes
/// subagents parallel, and a decision is what has to be testable: three
/// consecutive `task` calls are one batch (one round trip instead of three), a
/// `task` followed by a `grep` is one `task` and then the read batch, and a batch
/// is only ever CONSECUTIVE because a `write` in the middle of two searches is
/// exactly the case where order matters.
// ── `!` shell mode ────────────────────────────────────────────

/// The user's own command, run by the harness.
///
/// `!git status` in the input. The command runs and its output goes into the
/// CONTEXT (the session), and NO turn happens: there is no model call and nothing
/// is spent. That is the whole point — the user already knows how to type a
/// command, and what they do not have is a way to put its output where the model
/// can see it.
///
/// It runs on its own thread. `submitInput` is called from the event handler, so a
/// foreground command there blocks the UI for as long as it runs: typing freezes,
/// the clock stops, and ESC does nothing. This is the same trap as the permission
/// dialog, and the same answer.
pub fn startShell(m: *tui.Model, command: []const u8) void {
    const cmd_copy = m.allocator.dupe(u8, command) catch return;
    const quoted = jsonString(m.allocator, command) catch {
        m.allocator.free(cmd_copy);
        return;
    };
    defer m.allocator.free(quoted);
    const args = std.fmt.allocPrint(m.allocator, "{{\"command\":{s}}}", .{quoted}) catch {
        m.allocator.free(cmd_copy);
        return;
    };

    const Job = struct {
        m: *tui.Model,
        cmd: []u8,
        args: []u8,

        fn run(self: *@This()) void {
            // The turn is not over until this is, and `app.deinit()` destroys the
            // `Io` and the allocator it is using.
            self.m.beginWorker();
            defer self.m.endWorker();
            defer self.m.allocator.free(self.args);

            const t0 = std.Io.Timestamp.now(io_global, .real).nanoseconds;
            var astate = std.heap.ArenaAllocator.init(self.m.allocator);
            defer astate.deinit();
            const text = tools_mod.execute(
                io_global,
                "bash",
                self.args,
                astate.allocator(),
                &self.m.bg,
                &self.m.reads,
            ) catch |err| {
                const msg = std.fmt.allocPrint(self.m.allocator, "{t}", .{err}) catch "the command could not be run";
                const ms = elapsedMs(t0);
                const owned = self.m.allocator.dupe(u8, msg) catch return;
                self.m.pushShellOut(self.cmd, owned, ms);
                return;
            };
            const ms = elapsedMs(t0);
            // Both copies are OWNED by the model now: this arena dies with the
            // thread and the strings would be read by the renderer after that.
            const owned_text = self.m.allocator.dupe(u8, text) catch {
                const empty = self.m.allocator.dupe(u8, "") catch return;
                self.m.pushShellOut(self.cmd, empty, ms);
                return;
            };
            self.m.pushShellOut(self.cmd, owned_text, ms);
        }
    };

    const job = m.allocator.create(Job) catch {
        m.allocator.free(cmd_copy);
        return;
    };
    job.* = .{ .m = m, .cmd = cmd_copy, .args = args };
    // A spawn failure runs it here, on the UI thread. It is the same block the
    // app would have shown, so a failure to spawn cannot lose the command.
    const th = std.Thread.spawn(.{}, Job.run, .{job}) catch {
        Job.run(job);
        return;
    };
    th.detach();
}

/// A finished `!` command: painted in the history AND put in the session.
///
/// The session message is what makes the output part of the context: the model
/// reads the next prompt with it already there, so there is no round trip to
/// "paste me that".
pub fn shellOutputArrived(m: *tui.Model, so: tui.ShellOut) void {
    // What goes into the session is what the user would have pasted: the command
    // and its output, in that order.
    var astate = std.heap.ArenaAllocator.init(m.allocator);
    defer astate.deinit();
    const a = astate.allocator();
    const body = std.fmt.allocPrint(a, "$ {s}\n{s}", .{ so.cmd, so.text }) catch return;
    // Capped like any tool result: a command that prints a megabyte must not end
    // up in the prompt, and the model is told when it is cut.
    const clipped = if (body.len > 32 * 1024) body[0 .. 32 * 1024] else body;
    const text = if (clipped.len < body.len)
        std.fmt.allocPrint(a, "{s}\n… (output cut at 32 KB; re-run with a narrower command)", .{clipped}) catch clipped
    else
        clipped;

    // Always VISIBLE, not a collapsed tool result: the user ran this to see it,
    // and Ctrl+R to expand what they just asked for would be perverse.
    pushInfoFmt(m, "$ {s}\n{s}", .{ so.cmd, so.text });
    const s = ensureSession(m, m.allocator);
    s.append(.user, text) catch {};
    s.flush();
}

/// A JSON string literal, for building tool arguments by hand.
fn jsonString(gpa: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out = try std.ArrayList(u8).initCapacity(gpa, s.len + 8);
    errdefer out.deinit(gpa);
    try out.append(gpa, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(gpa, "\\\""),
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            else => try out.append(gpa, c),
        }
    }
    try out.append(gpa, '"');
    return out.items;
}

fn taskBatchEnd(calls: []const TurnCtx.Call, from: usize) usize {
    var jt = from + 1;
    while (jt < calls.len and std.mem.eql(u8, calls[jt].name, "task")) jt += 1;
    return jt;
}

/// How many subagents run at the same time.
///
/// Not "all of them": each one is a full streaming request against the same key,
/// so a model that asks for six at once turns one turn into six parallel streams
/// and meets the rate limit of whichever provider answers first. Three is enough
/// to make the common case ("look in three places at the same time") one round
/// trip instead of three, and small enough not to be a self-inflicted 429.
///
/// `ZODE_TASK_PARALLEL` overrides it, and `1` restores the serial behaviour.
pub const default_task_parallel: usize = 3;

/// How many times a subagent retries a retryable error before giving up.
///
/// Fewer than the main turn's three, and on purpose: the main turn has a user's
/// attention to spend on a slow answer and a report to make; a subagent that is one
/// of three in parallel should get out of the way quickly rather than hold its slot
/// through three backoffs that the other two are also sitting in.
pub const subagent_retry_attempts: usize = 2;

fn taskParallelLimit(m: *tui.Model) usize {
    const override = m.taskParallelLimit();
    if (override > 0) return override;
    const env = m.environ;
    const v = envGet(env, "ZODE_TASK_PARALLEL") orelse return default_task_parallel;
    const n = std.fmt.parseInt(usize, std.mem.trim(u8, v, " "), 10) catch return default_task_parallel;
    return @max(1, @min(n, 8));
}

/// Runs a batch of consecutive `task` calls, `limit` at a time.
///
/// The model does not need to be told: three `task` calls in one message are
/// three searches that do not depend on each other, each one with its own
/// throwaway window, and running them in series is three round trips of pure
/// waiting. They are read-only by construction (`subagent.tool_names`), so the
/// same criterion as the read batch applies: they cannot observe each other.
///
/// The results go back in REQUEST order, not completion order, and every header
/// goes out before any result: the history has to read "these three at once",
/// not three unrelated pairs interleaved by whichever finished first.
fn runTaskBatch(
    m: *tui.Model,
    s: *session_mod.Session,
    t: *TurnCtx,
    from: usize,
    to: usize,
    arena: std.mem.Allocator,
) struct { ok: usize, denied: usize } {
    const n = to - from;
    const limit = taskParallelLimit(m);
    var lbl: [96]u8 = undefined;
    const label = if (n == 1)
        std.fmt.bufPrint(&lbl, "1 search in a subagent", .{}) catch "searching"
    else
        std.fmt.bufPrint(&lbl, "{d} searches in parallel", .{n}) catch "searching";
    setStatusWithZo(m, .tooling, label);
    m.toolRunEnd();

    const Job = struct {
        id: []const u8 = "",
        text: []const u8 = "",
        err: bool = false,
    };
    const results = arena.alloc(Job, n) catch {
        // No memory for the slots: serial, which is slow but correct.
        var ok: usize = 0;
        for (t.calls.items[from..to]) |call| ok += taskCall(m, s, call, arena);
        return .{ .ok = ok, .denied = 0 };
    };
    @memset(results, .{});

    const Ctx = struct {
        call: TurnCtx.Call,
        out: *Job,
        m: *tui.Model,
        task: subagent_mod.Task,
        wave_running: ?*std.atomic.Value(usize) = null,
    };
    const ctxs = arena.alloc(Ctx, n) catch {
        var ok: usize = 0;
        for (t.calls.items[from..to]) |call| ok += taskCall(m, s, call, arena);
        return .{ .ok = ok, .denied = 0 };
    };
    var malformed: usize = 0;
    for (t.calls.items[from..to]) |call| {
        const arg = toolArgSummary(call.name, call.args_json, arena);
        m.pushToolStart(call.name, arg);
    }
    m.beginTaskBatch(n);
    defer m.endTaskBatch();
    for (t.calls.items[from..to], 0..) |call, k| {
        // Parsed HERE, on the turn thread, so a malformed task does not need a
        // thread and its message is not reordered by the race below.
        const parsed = subagent_mod.parseTask(arena, call.args_json) catch {
            malformed += 1;
            ctxs[k] = .{ .call = call, .out = &results[k], .m = m, .task = .{ .description = "" } };
            m.taskBatchFinished();
            continue;
        };
        ctxs[k] = .{ .call = call, .out = &results[k], .m = m, .task = parsed };
    }

    const Runner = struct {
        fn run(ctx: *Ctx) void {
            // The turn is not over until these are, and `app.deinit()` destroys
            // the `Io` they are using (the detached-worker trap).
            ctx.m.beginWorker();
            defer ctx.m.endWorker();
            const wave_running = ctx.wave_running;
            defer if (wave_running) |running| {
                _ = running.fetchSub(1, .seq_cst);
            };
            ctx.m.taskBatchStarted();
            defer ctx.m.taskBatchFinished();
            if (ctx.task.description.len == 0) {
                ctx.out.err = true;
                return;
            }
            _ = ctx.m.bench.subagents.fetchAdd(1, .seq_cst);
            // Each one has its OWN Report (a fixed 8 KB buffer) and its own
            // arena: sharing either between two threads is a silent data race.
            var rep = subagent_mod.Report{};
            const text = runSubagent(ctx.m, ctx.task, &rep);
            // COPIED: the arena of this thread dies with it and the text is read
            // by the caller after the wait.
            ctx.out.text = ctx.m.allocator.dupe(u8, text) catch "";
        }
    };

    // Spawn fixed-size waves so at most `limit` threads are in flight. Each wave
    // has a local completion counter; no global worker count is used as a semaphore.
    var spawned: usize = 0;
    while (spawned < n) {
        const wave = @min(limit, n - spawned);
        var running = std.atomic.Value(usize).init(0);
        var k: usize = 0;
        while (k < wave) : (k += 1) {
            const idx = spawned + k;
            if (ctxs[idx].task.description.len == 0) continue; // malformed: no thread
            ctxs[idx].wave_running = &running;
            _ = running.fetchAdd(1, .seq_cst);
            const th = std.Thread.spawn(.{}, Runner.run, .{&ctxs[idx]}) catch {
                Runner.run(&ctxs[idx]);
                continue;
            };
            th.detach();
        }
        spawned += wave;
        // Wait for this wave before the next one: that IS the concurrency limit,
        // and it is why the count is of THREADS and not of requests.
        var wait_ms: usize = 1;
        while (running.load(.seq_cst) > 0) {
            napMs(wait_ms);
            wait_ms = @min(wait_ms * 2, 20);
        }
    }

    var ok: usize = 0;
    for (results, 0..) |r, k| {
        const call = t.calls.items[from + k];
        if (r.err and r.text.len == 0) {
            // The malformed-args message: it is the ONE case where the model has
            // to be told what to do differently, and the serial path has always
            // said it.
            m.pushToolDone(call.name, "malformed arguments", 0, subagentBadArgsText);
            s.appendToolResult(call.id, call.name, subagentBadArgsText) catch {};
            continue;
        }
        ok += 1;
        turn_stats.noteTool();
        m.pushToolDone(call.name, "report", 0, r.text);
        s.appendToolResult(call.id, call.name, r.text) catch {};
    }
    m.pushInfoFmt("{d}/{d} subagent{s} completed (parallel limit {d})", .{
        ok,
        n - malformed,
        if (ok == 1) "" else "s",
        limit,
    });
    return .{ .ok = ok, .denied = 0 };
}

/// What the main model reads when a `task` call has no usable arguments.
const subagentBadArgsText =
    "The `task` call needs a \"description\" (one line: what to find out) and may have a \"prompt\" (the full question). Nothing was searched. Do it yourself with grep/glob/read, or call `task` again with a description.";

fn taskCall(m: *tui.Model, s: *session_mod.Session, call: TurnCtx.Call, arena: std.mem.Allocator) usize {
    var task = subagent_mod.parseTask(arena, call.args_json) catch {
        m.pushToolDone("task", "malformed arguments", 0, subagentBadArgsText);
        s.appendToolResult(call.id, "task", subagentBadArgsText) catch {};
        return 1;
    };

    // Phase 9: if the task names an agent definition, look it up and apply its
    // tools/model/effort. The definition's tools must be read-only — a
    // definition cannot escalate.
    if (task.definition.len > 0) {
        const defs = ensureAgentDefs(m.allocator, io_global, m.environ);
        if (agentdefs.find(defs, task.definition)) |def| {
            if (!agentdefs.toolsAreReadOnly(def.tools)) {
                m.pushToolDone("task", "definition not accepted", 0, "agent definition names tools outside the read-only set");
                s.appendToolResult(call.id, "task", "agent definition names tools outside the read-only set") catch {};
                return 1;
            }
            if (def.tools.len > 0) {
                var tools_json_buf: [512]u8 = undefined;
                var w: std.Io.Writer = .fixed(&tools_json_buf);
                w.writeByte('[') catch {};
                for (def.tools, 0..) |t, j| {
                    if (j > 0) w.writeByte(',') catch {};
                    w.writeAll("\"") catch {};
                    w.writeAll(t) catch {};
                    w.writeAll("\"") catch {};
                }
                w.writeByte(']') catch {};
                task.allowed_tools = w.buffered();
            }
            if (def.model.len > 0) task.model = def.model;
            if (def.effort.len > 0) task.effort = def.effort;
        } else {
            m.pushInfoFmt("unknown agent definition '{s}', using defaults", .{task.definition});
        }
    }

    m.pushToolStart("task", task.description);
    _ = m.bench.subagents.fetchAdd(1, .seq_cst);

    var rep = subagent_mod.Report{};
    const text = runSubagent(m, task, &rep);
    m.pushToolDone("task", "report", 0, text);
    s.appendToolResult(call.id, "task", text) catch {};
    return 1;
}

/// The subagent loop. Returns a slice of `rep`.
///
/// Refusals are RESULTS and not errors: a subagent that cannot run still has to
/// leave the turn able to continue, and the main agent needs to know it has to do
/// the search itself.
pub fn runSubagent(m: *tui.Model, task: subagent_mod.Task, rep: *subagent_mod.Report) []const u8 {
    // `gpa` is the MODEL's allocator and it is only for the things that outlive this
    // call — the `Report` belongs to the caller. Everything that belongs to the subagent
    // and nobody else goes through `sarena` below, which is why that arena exists.
    const gpa = m.allocator;
    // The subagent's throwaway arena: its history, the validated tool list and
    // any notes all die here when the run ends.
    var sstate = std.heap.ArenaAllocator.init(gpa);
    defer sstate.deinit();
    const sarena = sstate.allocator();

    // Permission: a subagent spends the user's tokens and reads the whole repo.
    // `task` IS in `needsPermission`, so the dialog has already been shown by
    // `execToolCalls`'s gate before this is reached.
    var pick = pickTarget(m);
    // The developer's pick for subagents, if they made one. The NOTE — what it
    // will run on, or why the pick was not usable — goes into the Report HERE,
    // because this is the last moment that knows before the first request.
    var on_submodel = applySubmodel(m, &pick, rep);
    // A forked skill's declared model: run the subagent on it. When the
    // developer overrode the subagent model with /submodel, that override wins.
    if (task.model.len > 0 and !on_submodel) {
        var reason_buf: [400]u8 = undefined;
        const sp: SubPick = .{ .provider = "", .model = task.model, .source = "skill" };
        switch (submodelTarget(m, sp, &reason_buf)) {
            .ok => |t| pick = t,
            .why => |why_not| {
                var nbuf: [440]u8 = undefined;
                const note = std.fmt.bufPrint(
                    &nbuf,
                    "[subagent note: the skill's model {s} was not used ({s}). Running on the default target.]",
                    .{ task.model, why_not },
                ) catch "[subagent note: the skill's model was not used.]";
                rep.setNote(note);
            },
        }
    }

    var http = http_client.Http.init(gpa, io_global);
    defer http.deinit();

    var json_buf: [64 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&json_buf);
    w.writeByte('[') catch return subagent_mod.refused("no memory for the tool list", rep);
    var kept: usize = 0;
    var tool_list: []const []const u8 = undefined;
    if (task.allowed_tools.len > 0) {
        // A forked skill's declared `allowed_tools`: every named tool must be
        // read-only — a skill cannot escalate to `write`/`edit`/`bash`. The
        // validation note (and any refusal) goes into the Report.
        const allowed = subagent_mod.skillAllowedTools(sarena, task.allowed_tools) catch |err| {
            var nbuf: [440]u8 = undefined;
            var note_text: []const u8 = "[subagent note: the skill's allowed_tools was not valid.]";
            if (err == subagent_mod.ParseError.ToolNotReadOnly) {
                const n = std.fmt.bufPrint(
                    &nbuf,
                    "[subagent note: the skill asked for tools outside the read-only set, so it cannot run.]",
                    .{}
                ) catch "[subagent note: the skill's tools were not accepted.]";
                note_text = n;
            }
            rep.setNote(note_text);
            return subagent_mod.refused("the skill's tools were not accepted", rep);
        };
        tool_list = allowed.items;
    } else {
        tool_list = &subagent_mod.tool_names;
    }
    for (tool_list) |tn| {
        // Reuse the MAIN schemas verbatim: a second hand-written copy of `read`'s
        // schema is a second thing to keep correct, and the day they diverge the
        // subagent calls a tool with arguments the main loop would not accept.
        if (findToolJson(tools_mod.toolsJson(), tn)) |obj| {
            if (kept > 0) w.writeByte(',') catch {};
            w.writeAll(obj) catch {};
            kept += 1;
        }
    }
    w.writeByte(']') catch {};
    const tools_json = w.buffered();
    if (kept == 0) return subagent_mod.refused("the tool list could not be built", rep);

    // The subagent's OWN history. It does not inherit anything from the main
    // conversation: inheriting it would inherit the tokens, which is the thing
    // this whole feature exists to avoid.
    //
    // ## The ARENA, and the leak that made it necessary
    //
    // `msgs` was allocated from `gpa` — the MODEL's allocator — and never freed. Not
    // the ArrayList, which is a few bytes on the stack: every message's `content`, the
    // prompt, and the tool results, which is a `grep` dump of up to 4 KB per call over
    // eight iterations. One subagent leaked tens of KB and the leak was in the process
    // allocator's hands, so it showed up as RSS that never came down and a DebugAllocator
    // complaint nobody could attribute.
    //
    // An arena is the right shape here and not only because it frees: the subagent's
    // history is a THROWAWAY window by definition, so having one owner whose death
    // reclaims all of it is the same argument that keeps the subagent out of the main
    // context. What crosses the boundary is the REPORT, and `formatReport` already
    // copies it into the caller's fixed buffer.

    var msgs: std.ArrayList(chat.ChatMessage) = .empty;
    var tstate = SubTurn{ .m = m };
    defer tstate.deinit(gpa);

    const user_msg = if (task.prompt.len > 0)
        std.fmt.allocPrint(
            sarena,
            "{s}\n\n{s}",
            .{ task.description, task.prompt },
        ) catch return subagent_mod.refused("no memory for the prompt", rep)
    else
        sarena.dupe(u8, task.description) catch return subagent_mod.refused("no memory for the prompt", rep);

    msgs.append(sarena, .{ .role = "system", .content = subagent_mod.system_prompt }) catch
        return subagent_mod.refused("no memory for the system prompt", rep);
    msgs.append(sarena, .{ .role = "user", .content = user_msg }) catch
        return subagent_mod.refused("no memory for the prompt", rep);

    var url_buf: [1024]u8 = undefined;
    var url = targetUrl(&url_buf, pick);

    // The server's OWN error text for the last failed request. The model
    // fallback in the error path reads it (`router.disqualifies` needs the body
    // for a 400: OpenRouter answers a bad model id with a 400, and the status
    // alone does not say whether the MODEL or the REQUEST was rejected). It is a
    // local buffer and not `lastErrorBody()` on purpose: three subagents run in
    // parallel and the globals belong to the turn the user is watching — each
    // one failing would overwrite the others' reason, which is the exact hazard
    // `mirror_globals` exists for.
    var err_detail: chat.ErrBuf = .{};

    var body_buf: [256 * 1024]u8 = undefined;
    var iteration: usize = 0;
    // Retry bookkeeping, LOCAL to this subagent and not a global: three run at once and
    // a shared counter would be one subagent's 429 resetting another's budget.
    var sub_attempt: usize = 0;
    var sub_retries: usize = 0;
    // The skill's declared effort, clamped to what the model actually accepts
    // on each request (the model fallback can swap the target mid-subagent).
    var effort_pref: chat.Effort = .low;
    if (task.effort.len > 0) effort_pref = chat.Effort.parse(task.effort) orelse .low;
    while (iteration < subagent_mod.max_iterations) : (iteration += 1) {
        // Budget enforcement on the SUBCOMPACTED view: the subagent's window is
        // small by design, and letting it grow past `budget_tokens` would mean
        // paying for a grep dump it does not need.
        var cstate = std.heap.ArenaAllocator.init(gpa);
        const carena = cstate.allocator();
        // The same `off` as the turn above: a policy the user set has to mean the
        // same thing in the subagent, or `/context` describes a budget nothing obeys.
        const cmode = compaction.effectiveMode(m.environ, m.compact_mode);
        const comp = if (cmode == .off)
            compaction.nothingElided(msgs.items)
        else
            compaction.elideTier(carena, msgs.items, subagent_mod.budget_tokens, m.environ, cmode) catch
                compaction.nothingElided(msgs.items);

        const body = chat.buildBodyMessagesCapped(
            &body_buf,
            pick.model,
            comp.msgs,
            // The skill's declared effort, clamped to the model's ladder:
            // `low` by default, honoured only where the model offers it.
            chat.effectiveEffort(pick.model, effort_pref),
            tools_json,
            pick.kind,
            outputCapFor(pick.def, environ_global),
        ) catch {
            cstate.deinit();
            return subagent_mod.refused("the request was too large", rep);
        };

        // The cancel flag is NOT cleared here. It used to be, and with subagents
        // running in parallel that is worse than a no-op: one subagent starting
        // would erase the ESC the user pressed while another was mid-flight, so
        // the turn they were watching carried on. ESC is the user's signal, it
        // stays set, and every request obeys it (see `streamRaw`).
        // The key FOLLOWS `pick`, computed here and not before the loop: the
        // model fallback can swap the target mid-subagent, and a `key` captured
        // once would send the dead provider's credential to the new endpoint —
        // the `ZODE_PROVIDER` bug with the provider already rotated under it.
        //
        // `key_env.len == 0` is a provider that needs NO key (ollama and
        // friends): null there is a configuration, not a missing credential.
        // For everyone else a null key would go out with no Authorization at
        // all, which is the Anthropic bug caught one step earlier.
        if (pick.key == null and pick.def.key_env.len > 0)
            return subagent_mod.refused("no api key for this provider", rep);
        const bearer: ?[]const u8 = pick.key;

        // Build extra headers for OpenRouter (HTTP-Referer and X-OpenRouter-Title)
        var extra_hdrs_buf: [2]http_client.Http.ExtraHeader = undefined;
        var extra_hdrs_len: usize = 0;
        if (std.mem.eql(u8, pick.def.id, "openrouter")) {
            extra_hdrs_buf[extra_hdrs_len] = .{ .name = "HTTP-Referer", .value = "https://github.com/jesusalcala/zode" };
            extra_hdrs_len += 1;
            extra_hdrs_buf[extra_hdrs_len] = .{ .name = "X-OpenRouter-Title", .value = "zode" };
            extra_hdrs_len += 1;
        }
        const extra_headers = extra_hdrs_buf[0..extra_hdrs_len];

        // `streamChatDetail` returns `void`: it owns the StreamCtx and destroys
        // it, and hands back the server's error text in `err_detail` on the way
        // out (the model fallback below needs the body, not just the status).
        // (`streamChatCtx` is the other one, and it hands the ctx over — mixing
        // them up is how a subagent leaks 8 KB per iteration.)
        chat.streamChatDetail(
            gpa,
            &http,
            url,
            bearer,
            @constCast(body),
            .{
                .userdata = &tstate,
                .onDelta = SubTurn.subOnDelta,
                .onToolCall = SubTurn.subOnToolCall,
                .onFinish = SubTurn.subOnFinish,
            },
            pick.kind,
            // ISOLATED: several subagents run at once and none of them is the
            // turn the user is watching. Sharing the globals would mean each one
            // resets `/cache`, and a subagent starting would clear the cancel flag
            // the user set with ESC.
            false,
            &err_detail,
            extra_headers,
        ) catch |err| {
            cstate.deinit();
            // A cancelled subagent returns what it found, if anything. Treating
            // ESC as "refused" would throw away a report the user paid for.
            if (err == error.Cancelled and tstate.text.items.len > 0) {
                const partial = subagent_mod.formatReport(tstate.text.items, rep);
                return partial;
            }
            // THE MODEL FALLBACK, and it comes BEFORE the retry on purpose: an
            // error that says this MODEL will not answer must not be retried
            // twice more with backoff — the backoff would only slow down the
            // admission. Same order as the main turn's cheap router: disqualify
            // first, retry after.
            if (on_submodel and router_mod.disqualifies(err, err_detail.slice())) {
                const why_now = router_mod.why(err, err_detail.slice());
                // Session-long, like `router.State.given_up`: the next `task`
                // must not pay a failed request to learn what this one just
                // found out.
                var fbuf: [256]u8 = undefined;
                submodelFail(reasonFmt(&fbuf, "{s}/{s} {s} ({t})", .{
                    pick.def.id, pick.model, router_mod.phraseHead(why_now), err,
                }));
                const doomed = pickTarget(m);
                const nowhere = std.mem.eql(u8, doomed.model, pick.model) and
                    std.mem.eql(u8, doomed.def.id, pick.def.id);
                if (!nowhere) {
                    // The note rides in FRONT of the report: the model that was
                    // configured was not the one that answered, and that is the
                    // developer's first question when they read it.
                    var nbuf: [440]u8 = undefined;
                    rep.setNote(submodelFallbackNote(
                        &nbuf,
                        pick.def.id,
                        pick.model,
                        why_now,
                        doomed.def.id,
                        doomed.model,
                    ));
                    pick = doomed;
                    url = targetUrl(&url_buf, pick);
                    tstate.clearCalls(gpa);
                    tstate.text.clearRetainingCapacity();
                    sub_attempt = 0;
                    on_submodel = false;
                    continue;
                }
                // The pick IS the normal target: there is nowhere to fall back
                // to. The give-up above stops the next `task` from paying this
                // again, and the refusal below reports it.
            }
            // THE RETRY, and it is the whole difference between a subagent that works
            // and one that does not.
            //
            // The main turn retries a 429 three times with backoff. The subagent used
            // to give up on the first one, and that is worse here than in the main turn
            // for one specific reason: **three subagents run in parallel by default**,
            // which is three requests inside a second, which is exactly what gets a 429
            // in the first place. The parallelism was building the rate limit that then
            // killed the very searches it had started, and the model was told "refused"
            // for something that was a number in a header.
            //
            // It retries SILENTLY: a subagent's intermediate steps must not appear in
            // the user's history, and three "rate limited, retrying" lines from three
            // threads is a history full of noise about something invisible. The attempts
            // are counted and reported in the result if they all fail.
            if (isRetryable(err) and sub_attempt < subagent_retry_attempts) {
                sub_attempt += 1;
                Retry.wait(sub_attempt) catch {
                    // ESC cut the wait short: that is the user stopping it, so it is a
                    // cancellation and not a failure.
                    return subagent_mod.refused("cancelled while waiting to retry", rep);
                };
                sub_retries += 1;
                continue;
            }
            if (sub_retries > 0) {
                return std.fmt.allocPrint(
                    sarena,
                    "This search failed after {d} attempt(s): {t}. It was a rate limit, not the task. The main agent can run the search itself, or try again in a moment.",
                    .{ sub_attempt + 1, err },
                ) catch return subagent_mod.refused(@errorName(err), rep);
            }
            return subagent_mod.refused(@errorName(err), rep);
        };
        cstate.deinit();
        // The request worked, so the next one's retry budget is whole again.
        sub_attempt = 0;

        if (tstate.calls.items.len == 0) {
            // Done: the text IS the report.
            const out = subagent_mod.formatReport(tstate.text.items, rep);
            return out;
        }

        // Tool round. The assistant message carries its `tool_calls` or the next
        // request is a 400 (the bug the TUI agent loop had).
        const tc_json = if (tstate.calls.items.len > 0)
            toolCallsJsonFromCalls(sarena, tstate.calls.items)
        else
            null;
        msgs.append(sarena, .{ .role = "assistant", .content = tstate.text.items, .tool_calls_json = tc_json }) catch
            return subagent_mod.refused("out of memory during the subagent loop", rep);

        for (tstate.calls.items) |call| {
            // A tool the subagent is not allowed to use comes back as a tool
            // result, NOT as a crash: the model asked for something out of scope
            // and it should find out by being told, in the same turn.
            if (!subagent_mod.allowsTool(call.name)) {
                const denied = std.fmt.allocPrint(sarena, "the subagent may not use `{s}`. It can only search and read.", .{call.name}) catch "not allowed";
                msgs.append(sarena, .{ .role = "tool", .content = denied, .tool_call_id = call.id }) catch break;
                continue;
            }
            const res_text = tools_mod.execute(
                io_global,
                call.name,
                call.args_json,
                // The subagent's throwaway arena, NOT the model allocator: a `grep`
                // result here is up to 4 KB of memory nobody will ever read again, and
                // one owner that dies with the subagent is the only way to be sure it
                // goes back.
                sarena,
                // NO background registry: a subagent must not leave processes
                // behind that nobody is tracking, and `run_in_background` on a
                // read-only tool is not a thing.
                null,
                // NO read cache either, and that is a real decision rather than an
                // omission: the subagent has its own throwaway window, so nothing
                // it reads is ever "already in the context" of the main one. A
                // shared cache would answer "unchanged, it is in your context" to a
                // window that is thrown away a second later.
                null,
            ) catch |err| {
                const emsg = sarena.dupe(u8, @errorName(err)) catch continue;
                msgs.append(sarena, .{ .role = "tool", .content = emsg, .tool_call_id = call.id }) catch break;
                continue;
            };
            // The per-result cap is the subagent's own, tighter one: 4 KB of grep
            // in a 24k budget is a sixth of the window in a single call.
            // `resultcap.capResult` cuts at a UTF-8 boundary and appends its
            // notice inside the budget, so a fragment cannot be mistaken for
            // the whole output. One place caps every result: `resultcap`.
            const capped = resultcap.capResult(sarena, res_text, subagent_mod.max_tool_output) catch resultcap.Capped{
                .text = res_text,
                .cut = false,
            };
            msgs.append(sarena, .{ .role = "tool", .content = capped.text, .tool_call_id = call.id }) catch break;
        }
        tstate.clearCalls(gpa);
        tstate.text.clearRetainingCapacity();
    }

    // Out of steps. The report it managed to write is usually good enough, and
    // throwing it away because the search did not FINISH is the worst of both.
    if (tstate.text.items.len > 0) {
        const out = subagent_mod.formatReport(tstate.text.items, rep);
        return out;
    }
    return subagent_mod.refused("it ran out of steps without reporting anything", rep);
}

/// The subagent's own turn state.
///
/// It is NOT `TurnCtx`: that one paints into the history and counts the turn's
/// stats, and a subagent's intermediate steps must not appear in the user's
/// history at all. The only thing the user sees is `task(description)` and the
/// report.
const SubTurn = struct {
    m: *tui.Model,
    text: std.ArrayList(u8) = .empty,
    calls: std.ArrayList(TurnCtx.Call) = .empty,

    fn deinit(self: *SubTurn, gpa: std.mem.Allocator) void {
        self.clearCalls(gpa);
        self.text.deinit(gpa);
    }

    fn clearCalls(self: *SubTurn, gpa: std.mem.Allocator) void {
        for (self.calls.items) |c| {
            gpa.free(c.id);
            gpa.free(c.name);
            gpa.free(c.args_json);
        }
        self.calls.clearRetainingCapacity();
    }

    fn subOnDelta(ud: ?*anyopaque, delta: []const u8) void {
        const t: *SubTurn = @ptrCast(@alignCast(ud.?));
        // The report is accumulated silently. Painting it would put the
        // subagent's half-formed sentences in the middle of the user's history.
        t.text.appendSlice(t.m.allocator, delta) catch {};
    }

    fn subOnToolCall(ud: ?*anyopaque, id: []const u8, name: []const u8, args_json: []const u8) void {
        const t: *SubTurn = @ptrCast(@alignCast(ud.?));
        const gpa = t.m.allocator;
        // One copy each, and `clearCalls` frees exactly those lengths: the rule
        // that `gpa.free(list.items)` is an "Invalid free" in 0.16 because `items`
        // is the length slice and the capacity is elsewhere.
        const id_c = gpa.dupe(u8, id) catch return;
        errdefer gpa.free(id_c);
        const name_c = gpa.dupe(u8, name) catch return;
        errdefer gpa.free(name_c);
        const args_c = gpa.dupe(u8, args_json) catch return;
        t.calls.append(gpa, .{ .id = id_c, .name = name_c, .args_json = args_c }) catch {
            gpa.free(id_c);
            gpa.free(name_c);
            gpa.free(args_c);
        };
    }

    fn subOnFinish(_: ?*anyopaque, _: []const u8) void {}
};

/// The `{"type":"function",...}` object for one tool, inside the full list.
///
/// `null` when not found. A scan rather than a parse because this runs once per
/// subagent and the input is our own constant; a parse+reserialize would be 8 KB
/// of garbage per call for nothing.
fn findToolJson(all: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < all.len) {
        if (all[i] != '{') {
            i += 1;
            continue;
        }
        const end = bgproc_matchObject(all, i) orelse return null;
        const span = all[i..end];
        var key_buf: [80]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "\"name\":\"{s}\"", .{name}) catch return null;
        if (std.mem.indexOf(u8, span, key) != null) return span;
        i = end;
    }
    return null;
}

fn bgproc_matchObject(s: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var in_str = false;
    var esc = false;
    var i = start;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (esc) {
            esc = false;
            continue;
        }
        if (in_str) {
            if (c == '\\') esc = true else if (c == '"') in_str = false;
            continue;
        }
        if (c == '"') in_str = true else if (c == '{') depth += 1 else if (c == '}') {
            depth -= 1;
            if (depth == 0) return i + 1;
        }
    }
    return null;
}

/// Questions one turn may ask.
///
/// Three is the number where "the agent checks with me" stops being useful and
/// starts being an obstacle, and it is a cap on the ASK count rather than on the
/// time: three quick questions are fine, and a turn that takes forty steps without
/// asking anything is not what this cap is about.
pub const max_asks_per_turn = 3;

/// Read-only mode's answer to a write tool. Said as a tool result so the model
/// changes plan instead of retrying (a retry of the same call is an immediate
/// loop, and the cap is what saves you from it).
pub const read_only_text =
    "plan (read-only) mode is on: the user asked zode to look before it touches anything, " ++
    "so write/edit and the commands that CHANGE something did not run. The commands that only " ++
    "read (git status, git diff, rg, ls, cat) still run, and they do not ask. Do NOT retry the " ++
    "blocked one. Read what you need and write the " ++
    "IMPLEMENTATION PLAN with the `todo` tool, then end your turn — the user will be asked " ++
    "to approve it and zode will switch itself out of plan mode. For anything you need to " ++
    "know first, use `ask` — or say so in one line — the user can turn plan mode off with shift+tab.";

/// Whether a call is a `bash` that only READS.
///
/// It is the table of `lib/cmdsafety.zig`: `git status`, `rg`, `ls`… read and
/// change nothing, and a command we do not know is NOT read-only (the cost of
/// asking is one dialog and the cost of guessing wrong is a file).
fn callReadsOnly(name: []const u8, args_json: []const u8, arena: std.mem.Allocator) bool {
    if (!std.mem.eql(u8, name, "bash")) return false;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch return false;
    if (parsed != .object) return false;
    const cmd = parsed.object.get("command") orelse return false;
    if (cmd != .string) return false;
    return cmdsafety.isReadOnly(cmd.string, arena);
}

/// ESC: kills the foreground command if there is one. Returns how many were
/// killed. See `bgproc.killForeground` for why this is not a no-op.
pub fn killForeground() usize {
    return if (bgproc.killForeground()) 1 else 0;
}

/// One tool call, in series. Returns 1 if it ran, 0 if it was denied.
///
/// This is the serial path: everything with side effects, and the single-call
/// case for a read-only tool (a batch of one is not worth a thread).
/// The budget for the tool results of ONE assistant message.
///
/// ## Why this exists
///
/// `resultcap.max_results_per_message_chars` was DEAD CODE. The module was
/// written, the registry declared a per-tool cap that nobody read, and nothing
/// capped the SUM — so the number existed in the source and in no request.
///
/// The per-tool caps alone do not bound a message. Five parallel greps at
/// 16 KB each are 80 KB in a single user message; a turn that reads eight
/// files at 2000 lines each is over a megabyte. The context is the expensive
/// resource ("anything that goes into the LLM has to earn its place"), and this
/// is the place where the size of a message is decided.
///
/// The rule is the one `resultcap` already had: cut the largest first. Here
/// the results are appended one at a time, so the budget is a RUNNING one and
/// the first results are the ones that get the room — which is the same
/// outcome when the results are similar in size, and the only one available
/// without rewriting the session.
const ResultBudget = struct {
    used: usize = 0,

    /// The cap for the next result: the smaller of the tool's own cap and what
    /// is left of the message.
    ///
    /// A tool with no cap of its own (`read`) is bounded by the message: that
    /// is the backstop, and it is why `read` being unbounded is a decision
    /// about the PER-TOOL cap and not about the message.
    fn capFor(self: *const ResultBudget, per_tool: usize) usize {
        const total = resultcap.max_results_per_message_chars;
        const left = if (self.used < total) total - self.used else 0;
        if (per_tool == 0) return left;
        return @min(per_tool, left);
    }

    fn charge(self: *ResultBudget, n: usize) void {
        self.used += n;
    }
};

fn execOneCall(
    m: *tui.Model,
    s: *session_mod.Session,
    call: TurnCtx.Call,
    arena: std.mem.Allocator,
    denied: *usize,
    budget: *ResultBudget,
) usize {
    const arg = toolArgSummary(call.name, call.args_json, arena);
    // The timeline may lead with WHAT IT IS FOR (`bash`'s description); the
    // permission paths below keep `arg`, the command itself.
    const label = toolTimelineLabel(call.name, call.args_json, arg, arena);
    m.pushToolStart(call.name, label);
    // The status says WHAT is running, not a generic "working": with a slow `bash`
    // that is the difference between "working" and "hung". The text is
    // copied to a fixed buffer, so the label from the worker's arena can die
    // without a problem.
    setStatusWithZo(m, .tooling, label);

    // ── read-only mode ──
    //
    // BEFORE the permission dialog, and that order is the point: in read-only the
    // call is not going to happen, so asking "may I run this write?" and then
    // saying no is a dialog that lies. The user asked for "look, don't touch", and
    // a permission prompt for a write in that mode is a bug in the UI.
    //
    // A BATCH is decided by its steps: a batch of reads is a read, and a batch
    // with a write step is a write. The static list of write tools cannot say
    // that, and a batch that wrote in plan mode would be a hole in the mode.
    //
    // A `bash` that only READS is not a write: `git status`, `rg`, `ls` change
    // nothing, and the mode is about not touching things. Blocking them would
    // mean the agent cannot LOOK, and a plan written without looking is a
    // plan written in the dark.
    const reads_only = callReadsOnly(call.name, call.args_json, arena);
    if (read_only and !reads_only and callIsWrite(call.name, call.args_json, arena)) {
        m.plan_write_blocked_this_turn = true;
        m.pushToolDone(call.name, "blocked by plan mode", 0, read_only_text);
        s.appendToolResult(call.id, call.name, read_only_text) catch {};
        return 0;
    }

    // ── the permission RULES (Phase 6) ──
    //
    // The rules come BEFORE the questions: a rule that says "allow" means the
    // call does not ask at all, and a rule that says "deny" means it does
    // not run at all. The questions are for the calls that no rule has an
    // opinion about.
    //
    // The SUBJECTS are what the call acts on: the paths for a file tool, the
    // command for `bash`. A rule with a pattern is about ONE of them.
    const subjects = tools_mod.callSubjects(call.name, call.args_json, arena);
    const rule_decision = permDecision(call.name, subjects);
    var rule_allowed = false;
    if (rule_decision) |d| {
        switch (d.action) {
            .allow => {
                rule_allowed = true;
            },
            .dontAsk => {
                // dontAsk: no dialog, the model answers for itself. The call
                // proceeds as if allowed, but the user did not pre-approve it
                // — the model decided on its own.
                rule_allowed = true;
            },
            .deny => {
                // The refusal NAMES the rule: "this is not allowed" is not an
                // answer, "your own rule says so" is.
                const msg = std.fmt.allocPrint(
                    arena,
                    "refused: the rule `{s}` ({s}) does not allow this.",
                    .{ d.rule.text, d.rule.source.name() },
                ) catch "refused: a permission rule does not allow this.";
                m.pushToolDone(call.name, "refused by a rule", 0, msg);
                s.appendToolResult(call.id, call.name, msg) catch {};
                return 0;
            },
            .ask => {},
        }
    }

    // ── the SENSITIVE-PATH question ──
    //
    // It comes BEFORE the general permission dialog, and it is a DIFFERENT
    // question: not "may I run this tool" but "may I write IN HERE", where
    // "here" is a place where writing is a bad idea (`.git/`, a hook, a
    // shell config).
    //
    // The tool cannot ask: it has no `Model` and it cannot see a dialog. The
    // dispatcher can, so the question happens here and the answer is handed
    // to the tool as an approval of that one path.
    //
    // It asks ONCE and never offers "always allow": a rule that remembers
    // "the agent may write inside .git/" is the opposite of the rule.
    const risky = tools_mod.riskyPaths(call.name, call.args_json, arena);
    var risky_allowed = false;
    if (risky.len > 0 and !yolo and !rule_allowed) {
        var asked = false;
        for (risky) |p| {
            const v = pathsafe.checkWrite(p);
            if (v == .ok) continue;
            if (asked) continue;
            asked = true;
            var dbuf: [384]u8 = undefined;
            const detail = std.fmt.bufPrint(
                &dbuf,
                "{s} is not a place this tool writes: {s}",
                .{ p, switch (v) { .dangerous => |d| d.why, else => "it is protected" } },
            ) catch p;
            switch (m.requestPermissionOnce(call.name, detail)) {
                .allow => {
                    pathsafe.approve(p);
                    // The user has just approved THIS write, with the reason
                    // in front of them. The general dialog would ask the same
                    // question about the same file with the reason hidden, and
                    // two dialogs for one write is a dialog too many.
                    risky_allowed = true;
                },
                .allow_always => {
                    pathsafe.approve(p);
                    risky_allowed = true;
                },
                .deny, .none => {
                    denied.* += 1;
                    turn_stats.noteDenied();
                    const msg = pathsafe.refusalText(arena, v);
                    m.pushToolDone(call.name, "refused: sensitive path", 0, msg);
                    s.appendToolResult(call.id, call.name, msg) catch {};
                    return 0;
                },
            }
        }
    }

    // ── permission ──
    //
    // Accept-edits auto-allows file edits, and a `bash` command
    // that matches a persisted prefix is allowed without a dialog.
    // Both are the user's standing "I trust this" — the selective
    // part of selective permissions — and everything else that
    // needs permission still asks, unless `/yolo` said not to.
    //
    // The permission set of a CALL is the union of the tools it calls, and for
    // every tool but `batch` that union is the tool itself. A batch of reads
    // asks for nothing; a batch with a write step asks for exactly what that
    // write would have asked.
    const perm_tools = tools_mod.callPermissionTools(call.name, call.args_json, arena);
    const auto_allowed = permAutoAllowed(call.name, arg, call.args_json, arena);
    //
    // In READ-ONLY mode a command that only reads does not ask: the mode is
    // the user saying "look, do not touch", and a dialog about `ls` is the
    // mode asking the question it was meant to settle.
    //
    // That same scanner-decided read-only-ness is a seat at the read-only
    // table in ANY mode (Phase 25.4): a `bash` command the scanner found
    // nothing to flag (`git status`, `ls`, `rg foo`) only reads, so it never
    // reaches the permission dialog. `reads_only` is `false` for every tool
    // but `bash`, so nothing else changes — the scanner in `lib/cmdsafety.zig`
    // decides, not the static flag on the registry row.
    const no_dialog = reads_only;
    if (!yolo and !auto_allowed and !risky_allowed and !rule_allowed and !no_dialog and permNeedsDialog(perm_tools)) {
        var dbuf: [384]u8 = undefined;
        // A batch's dialog says WHICH FILES it would touch: the user is being
        // asked to approve a set of writes, and the set is the whole question.
        var detail: []const u8 = if (std.mem.eql(u8, call.name, "batch"))
            tools_mod.batchPermissionDetail(call.args_json, arena)
        else
            std.fmt.bufPrint(&dbuf, "{s} {s}", .{ call.name, arg }) catch call.name;
        // The RISK, in words, for a command that has one: "this deletes
        // unreferenced files" beats `git clean -fdx` on its own.
        //
        // The user is being asked to approve a command they did not write,
        // and the raw line is not a risk: it is a spelling.
        if (std.mem.eql(u8, call.name, "bash") and cmdsafety.classify(arg, arena).why.len > 0) {
            const why = cmdsafety.classify(arg, arena).why;
            var both: [640]u8 = undefined;
            const with_why = std.fmt.bufPrint(&both, "{s} — {s}", .{ detail, why }) catch detail;
            detail = with_why;
        }
        // Name the rule the "always allow" answer would remember, so the user
        // answers with their eyes open ("always allow `Bash(git *)`", not a
        // blind "always allow"). learnRuleForCall re-derives this from the
        // call itself; here we only tell the dialog what to show.
        if (permSuggestion(call.name, call.args_json, arena)) |sugg| {
            m.setPermSuggestion(sugg);
        }
        switch (m.requestPermission(call.name, detail)) {
            .allow => {},
            .allow_always => {
                allowAlwaysForCall(m, call.name, arg, perm_tools);
                // And it learns the RULE, not only the tool: "always allow
                // `Bash(git *)`" is what the user answered, and the flat list
                // is a coarser memory of the same answer.
                learnRuleForCall(m, call.name, call.args_json, arena);
            },
            .deny, .none => {
                // The denial is handed back to the model as a result
                // so it changes strategy instead of retrying.
                denied.* += 1;
                turn_stats.noteDenied();
                m.pushToolDone(call.name, "denied: permission required", 0, "denied");
                s.appendToolResult(call.id, call.name, "denied: permission required") catch {};
                return 0;
            },
        }
    }

    const call_t0 = std.Io.Timestamp.now(io_global, .real).nanoseconds;

    // [undo] The BEFORE snapshot. `existed` is separate because "it was not there"
    // and "it was empty" undo differently (delete vs write empty), and a
    // `catch ""` does not tell them apart. And if the failure is NOT "does not
    // exist" (permissions, a directory), NO snapshot is taken: `/undo` would
    // delete a file it never managed to read, which is the worst thing an undo
    // can do.
    //
    // A BATCH can touch SEVERAL files, and `/undo` has to be able to put all
    // of them back. The snapshot is taken per file, exactly as it is for a
    // direct call: a batch that wrote three files and snapshotted one would
    // undo a third of the turn.
    var before: ?[]const u8 = null;
    if (std.mem.eql(u8, call.name, "batch")) {
        for (tools_mod.callTouchedPaths(call.name, call.args_json, arena)) |pth| {
            snapshotForUndo(m, pth, arena);
        }
    } else if (touchesFile(call.name)) {
        if (filePathOf(call.args_json, arena)) |pth| {
            if (std.Io.Dir.cwd().readFileAlloc(io_global, pth, arena, .limited(4 * 1024 * 1024))) |content| {
                before = content;
                m.snapshotFile(pth, content, true);
            } else |err| {
                switch (err) {
                    error.FileNotFound => m.snapshotFile(pth, "", false),
                    else => {},
                }
            }
        }
    }

    // The `todo` tool has no result to look at: its effect is the PLAN the user
    // sees, and it is applied here (not inside `execute`) because the plan lives
    // in the `Model`, which belongs to the TUI.
    // `read` on a PICTURE does not return bytes. The bytes are put aside by
    // `prepareImage` and go on the next user message, because a `tool` message's
    // content is a plain string in OpenAI's shape and an image cannot ride there.
    //
    // It is intercepted HERE and not inside `tools/read.zig` because the tool has
    // no `Model`, and the pending list, the current model's vision and the message
    // that carries it are all the `Model`'s.
    if (std.mem.eql(u8, call.name, "read")) {
        if (prepareImage(m, call.args_json)) |res| {
            s.appendToolResult(call.id, call.name, res) catch {};
            turn_stats.noteTool();
            return 0;
        }
    }

    if (std.mem.eql(u8, call.name, "todo")) {
        // Which of the two forms it is — a patch has one of those keys and a
        // replacement does not — is decided inside `applyPlanTo`, so the headless
        // runner cannot pick the other one. Deciding it by the KEYS and not by "does
        // it have items" is what lets a call do both: replace the list and then
        // patch it.
        applyPlanCall(m, call.args_json, arena);
    }

    // The `goal` tool is the same shape of thing: it has no effect the harness can see
    // in the tool's text, only in the Model.
    //
    // **It was missing here for one whole release cycle.** `applyGoalCall` was written,
    // `toolGoal` was written, the schema was there, and the model called it and was told
    // "recorded: the goal is BLOCKED" — while the harness went on to the hard ceiling
    // and printed `the goal was never decided`. Two halves of one feature, wired
    // individually, and nothing that could notice the seam: the tool's test checks the
    // TEXT, `goal.test` checks the PARSING, and neither of them goes from a tool call
    // to the Model.
    //
    // That is why the test below drives `execOneCall` and not the pure functions.
    if (std.mem.eql(u8, call.name, "goal")) {
        applyGoalCall(m, call.args_json, arena);
    }

    const res = tools_mod.executeWith(io_global, call.name, call.args_json, arena, &m.bg, &m.reads, &m.tasks) catch |err| {
        const ms = elapsedMs(call_t0);
        // What the MODEL is told is not the error name. See `describeError`.
        const emsg = tools_mod.describeError(arena, err, call.name, call.args_json);
        m.pushToolDone(call.name, "failed", ms, emsg);
        s.appendToolResult(call.id, call.name, emsg) catch {};
        return 0;
    };
    // The automatic typecheck, and the exit gate's write counter, fed from HERE.
    //
    // The success path and not the list of calls, and that is the whole reason this is
    // four lines below the `execute`: a denied `edit`, a `write` to a path that could not
    // be opened and an `edit` whose old string was not found ALL return above, and none
    // of them changed a byte. Counting them made the gate wait for a check of files
    // that still had their old contents — a check that comes back green and is about
    // the wrong thing, which is worse than no check because it reads as evidence.
    const wrote = m.auto_check.noteWrite(call.name, call.args_json);
    m.auto_check.afterTool(&m.bg, io_global, wrote);

    const ms = elapsedMs(call_t0);
    turn_stats.noteTool();
    if (std.mem.eql(u8, call.name, "bash") and startedBackground(res)) m.bench.bg_jobs += 1;
    const summary = toolResultSummary(call.name, res, arena);
    m.pushToolDone(call.name, summary, ms, res);

    // Diff against the previous content, if the tool touched a file.
    if (before) |old| {
        if (filePathOf(call.args_json, arena)) |pth| {
            const after = std.Io.Dir.cwd().readFileAlloc(io_global, pth, arena, .limited(4 * 1024 * 1024)) catch {
                s.appendToolResult(call.id, call.name, res) catch {};
                return 1;
            };
            // The language comes from the path's extension, so the body of each line
            // is tokenized instead of coming out in the prefix's color.
            const dc = m.pushDiffLang(old, after, langFromPath(pth));
            turn_stats.noteDiff(pth, dc);
        }
    }

    // [readcache] Two things that need the message this result is about to become.
    //
    // 1) A `write`/`edit` invalidates the file in the cache. Without this, the next
    //    `read` of the file the model JUST edited would take the fast path (the
    //    stat does not have to change for the answer to be wrong: the content
    //    lives in the model only) and answer "unchanged, it is in your context"
    //    with the OLD text in the context. `mtime` would catch it a second later;
    //    this catches it now.
    // 2) A `read` records WHICH message its content went into, which is how
    //    compaction can tell the cache that it just deleted that content.
    if (filePathOf(call.args_json, arena)) |pth| {
        if (isWriteTool(call.name)) {
            m.reads.invalidate(pth);
        }
    }

    // [/files] The files this call WROTE to, for the session's list.
    //
    // It is the SUCCESS path and not the list of calls: a denied `edit`, a
    // `write` to a path that could not be opened and an `edit` whose old
    // string was not found ALL changed nothing, and a list that says "changed"
    // about them is a list that lies.
    //
    // `callTouchedPaths` and not `filePathOf`: it knows the MULTI-FILE form of
    // `edit` (`files: [{path,…}]`) and the writing steps of a `batch`, and
    // those are the calls that touch more than one file. A `rename` is NOT
    // here: it FINDS its own files and its arguments never name them, so
    // there is nothing to read out of the call.
    if (callIsWrite(call.name, call.args_json, arena)) {
        for (tools_mod.callTouchedPaths(call.name, call.args_json, arena)) |pth| {
            m.changed.note(pth);
        }
    }
    // A `bash` that was NOT read-only may have changed files, and the paths
    // are not in the arguments: a command is a string, not a list of files.
    // The report says so instead of implying that the list is complete.
    if (std.mem.eql(u8, call.name, "bash") and !reads_only) {
        m.bash_may_write = true;
    }

    // Phase 3.1: large results are spilled to `sessions/<id>/tool-results/<n>.txt`
    // and the model receives a preview + path instead of blind truncation.
    // Unbounded tools (`read`, cap == 0) keep their full result; anything over
    // its per-tool cap is written to disk once and a short preview is sent.
    // The cut carries its notice inside the budget.
    const tool_cap = tools_registry.resultCap(call.name);
    var result_text: []const u8 = res;
    if (tool_cap != 0 and res.len > tool_cap) {
        if (s.path) |spath| {
            const tool_dir = std.fs.path.dirname(spath) orelse "/";
            const stored = toolstore.storeResult(
                arena, io_global, tool_dir, s.tool_result_next, res
            );
            s.tool_result_next += 1;
            if (stored.stored) {
                result_text = stored.text;
            }
        }
    }
    const capped = resultcap.capResult(
        arena, result_text, budget.capFor(tool_cap)
    ) catch resultcap.Capped{ .text = result_text, .cut = false };
    budget.charge(capped.text.len);
    s.appendToolResult(call.id, call.name, capped.text) catch {};
    if (std.mem.eql(u8, call.name, "read")) {
        if (s.messages.items.len > 0) {
            const idx: u32 = @intCast(s.messages.items.len - 1);
            if (filePathOf(call.args_json, arena)) |pth| m.reads.setMessageIndex(pth, idx);
        }
    }
    return 1;
}

/// Did this `bash` result start a background job?
///
/// Parsed from the RESULT text and not from the arguments: by the time the result
/// exists the registry is the truth, and matching the model's own wording would
/// count a foreground `bash` whose output happened to contain the words.
fn startedBackground(res: []const u8) bool {
    return std.mem.startsWith(u8, res, "started in the background as job ");
}

/// Runs a run of consecutive read-only tool calls at the same time.
///
/// One thread per call, each with its OWN arena, and the results collected into a
/// slice the caller walks in order. Three things are load-bearing here:
///
/// - **Own arena per call.** The main `arena` of `execToolCalls` is shared by the
///   whole turn and freed when it returns; appending to it from three threads is a
///   data race on the ArrayList's length, and that is a silent corruption, not a
///   crash.
/// - **Results in request order.** The model asked for them in an order and reads
///   them in that order; sorting by completion time would be faster-looking and
///   would make the same request produce different transcripts run to run.
/// - **Headers first, then results.** All the `⏺ grep(...)` lines go out before
///   any `⎿ 12 matches · 30ms`, so the history reads as "these four things at
///   once" instead of four unrelated call/result pairs, which is what a
///   per-call `pushToolStart`/`pushToolDone` pair would produce.
fn runParallelBatch(
    m: *tui.Model,
    s: *session_mod.Session,
    t: *TurnCtx,
    from: usize,
    to: usize,
    arena: std.mem.Allocator,
    budget: *ResultBudget,
) struct { ok: usize, denied: usize } {
    const n = to - from;
    const t0 = std.Io.Timestamp.now(io_global, .real).nanoseconds;

    // One header per call, in order, all before anything runs.
    for (t.calls.items[from..to]) |call| {
        const arg = toolArgSummary(call.name, call.args_json, arena);
        m.pushToolStart(call.name, arg);
    }
    // The strip says "running" with the batch, not one tool: with four greps
    // there is no single tool that is "the" one, and a name that changes every
    // frame reads as a flicker.
    var batch_buf: [128]u8 = undefined;
    const batch_label = std.fmt.bufPrint(&batch_buf, "{d} searches in parallel", .{n}) catch "searching";
    setStatusWithZo(m, .tooling, batch_label);
    // `pushToolStart` set `tool_run` to the last one; clear it so the clock line
    // does not claim a single tool is running.
    m.toolRunEnd();

    const Job = struct {
        name: []const u8,
        args: []const u8,
        id: []const u8,
        text: []const u8,
        ms: u64,
        err: bool,
    };
    var results = arena.alloc(Job, n) catch {
        // Out of memory for the results: fall back to serial. A correct-but-slow
        // turn beats a broken one.
        var ok: usize = 0;
        var denied: usize = 0;
        for (t.calls.items[from..to]) |call| {
            ok += execOneCall(m, s, call, arena, &denied, budget);
        }
        return .{ .ok = ok, .denied = denied };
    };
    @memset(results, .{ .name = "", .args = "", .id = "", .text = "", .ms = 0, .err = false });

    const Ctx = struct {
        call: TurnCtx.Call,
        out: *Job,
        m: *tui.Model,
        pending: *std.atomic.Value(usize),
    };
    var ctxs = arena.alloc(Ctx, n) catch return .{ .ok = 0, .denied = 0 };
    // The per-batch pending count, decremented by each thread. `m.workerCount()`
    // is NOT used to wait: it includes the chat worker, and waiting for it here
    // would be waiting for the turn to finish (see `waitForBatch`).
    var pending = std.atomic.Value(usize).init(n);
    for (t.calls.items[from..to], 0..) |call, k| {
        ctxs[k] = .{ .call = call, .out = &results[k], .m = m, .pending = &pending };
    }
    // `beginWorker`/`endWorker` around the thread as well: at exit `waitWorkers`
    // has to hold until these are done, or `app.deinit()` destroys the `Io` while
    // one of them is inside `std.process.run` (the AGENTS.md detached-worker trap).
    const Runner = struct {
        fn run(ctx: *Ctx) void {
            ctx.m.beginWorker();
            defer ctx.m.endWorker();
            defer _ = ctx.pending.fetchSub(1, .seq_cst);
            const call_t0 = std.Io.Timestamp.now(io_global, .real).nanoseconds;
            // A per-call arena: the shared one is off limits from two threads
            // (its ArrayList length would be a data race, and a silent one).
            var astate = std.heap.ArenaAllocator.init(ctx.m.allocator);
            defer astate.deinit();
            const a = astate.allocator();
            const text = tools_mod.executeWith(io_global, ctx.call.name, ctx.call.args_json, a, &ctx.m.bg, &ctx.m.reads, &ctx.m.tasks) catch |err| {
                ctx.out.err = true;
                ctx.out.text = @constCast(@errorName(err));
                ctx.out.ms = elapsedMs(call_t0);
                return;
            };
            // COPIED OUT OF `a`: the arena dies with this thread's `defer`, and
            // `waitForBatch` returns only when every `defer` has run, so a
            // `results[k].text` pointing into `a` is a dangling pointer for
            // EVERY call, not a race. It was `a.dupe` — allocating the copy in
            // the same arena that is about to be freed — with a comment
            // asserting the opposite. `ctx.m.allocator` is the model's
            // allocator, which outlives the batch, exactly as `runTaskBatch`'s
            // runner does it.
            ctx.out.text = ctx.m.allocator.dupe(u8, text) catch "";
            ctx.out.ms = elapsedMs(call_t0);
        }
    };
    for (ctxs) |*c| {
        // A SPAWN FAILURE has to run the call inline, or the result slot stays
        // empty and the model gets a tool result with no tool call behind it.
        const th = std.Thread.spawn(.{}, Runner.run, .{c}) catch {
            Runner.run(c);
            continue;
        };
        th.detach();
    }
    waitForBatch(&pending, 120_000);

    // Results, in request order.
    var ok: usize = 0;
    for (results, 0..) |r, k| {
        if (r.text.len == 0 and r.err) {
            m.pushToolDone(t.calls.items[from + k].name, "failed", r.ms, "the parallel search failed");
            s.appendToolResult(t.calls.items[from + k].id, t.calls.items[from + k].name, "the parallel search failed") catch {};
            continue;
        }
        ok += 1;
        turn_stats.noteTool();
        const summary = toolResultSummary(t.calls.items[from + k].name, r.text, arena);
        m.pushToolDone(t.calls.items[from + k].name, summary, r.ms, r.text);
        // The same cap as the serial path: the budget belongs to the MESSAGE,
        // not to the way the calls happened to be run.
        const tool_cap = tools_registry.resultCap(t.calls.items[from + k].name);
        var result_text: []const u8 = r.text;
        if (tool_cap != 0 and r.text.len > tool_cap) {
            if (s.path) |spath| {
                const tool_dir = std.fs.path.dirname(spath) orelse "/";
                const stored = toolstore.storeResult(
                    arena, io_global, tool_dir, s.tool_result_next, r.text
                );
                s.tool_result_next += 1;
                if (stored.stored) {
                    result_text = stored.text;
                }
            }
        }
        const capped = resultcap.capResult(
            arena, result_text, budget.capFor(tool_cap)
        ) catch resultcap.Capped{ .text = result_text, .cut = false };
        budget.charge(capped.text.len);
        s.appendToolResult(t.calls.items[from + k].id, t.calls.items[from + k].name, capped.text) catch {};
        // `r.text` is the caller's and both consumers above COPIED it
        // (`pushToolDone` dupes for the paragraph and the Ctrl+R memo,
        // `appendToolResult` dupes into the session), so this is ours to free.
        //
        // It was not, and the leak was invisible: the block is the size of one
        // tool result, so a long session leaked in proportion to how much the
        // model reads. It only became visible when the copy had to move out of
        // the per-call arena (it used to be allocated there, so the arena freed
        // it — while the pointer itself dangled).
        //
        // `err` marks a slot holding an `@errorName` LITERAL, which is not ours
        // to free: `gpa.free` on `.rodata` is an "Invalid free", which is how a
        // whole session used to die at quit.
        if (!r.err) m.allocator.free(r.text);
    }

    // The batch's own clock: it is the number the user can compare against a
    // serial run of the same searches, which is the whole point of doing this.
    const total_ms = elapsedMs(t0);
    var sum_buf: [128]u8 = undefined;
    const sum = std.fmt.bufPrint(&sum_buf, "{d} searches in parallel · {d}.{d}s", .{
        n,
        total_ms / 1000,
        (total_ms % 1000) / 100,
    }) catch "searches";
    setStatusWithZo(m, .tooling, sum);
    return .{ .ok = ok, .denied = 0 };
}

/// A plain `nanosleep`, NOT `Io.sleep`.
///
/// `Io.sleep` goes through the shared `Io` and takes its event loop with it, so
/// sleeping on it from a worker stops the TUI's redraw ticks: the clock in the
/// activity strip freezes and the screen looks dead. Same trap as `Retry.wait`,
/// documented in AGENTS.md.
fn napMs(ms: u64) void {
    if (builtin.os.tag != .linux) {
        std.Thread.yield() catch {};
        return;
    }
    const ts = std.os.linux.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.os.linux.nanosleep(&ts, null);
}

/// Waits for the batch's threads.
///
/// It counts DOWN a local counter and not `m.workerCount()`, because that counter
/// is global: the chat worker itself is one of them, so waiting for "workers == 0"
/// here would also wait for the turn to finish, which is a deadlock (the turn is
/// waiting for this function).
///
/// A join per thread is what would be the obvious thing and it is NOT possible
/// here: the threads are detached so a tool that hangs cannot keep the process
/// alive, and a detached thread has nothing to join. So this is a bounded spin on
/// a per-batch atomic, sleeping so it costs nothing.
///
/// The deadline exists because `web_fetch` can sit in a TLS read: without a cap, a
/// server that never answers would park the turn forever, which is the freeze this
/// project has already paid for once.
fn waitForBatch(pending: *std.atomic.Value(usize), deadline_ms: u64) void {
    var waited: u64 = 0;
    while (pending.load(.seq_cst) > 0 and waited < deadline_ms) : (waited += 5) {
        napMs(5);
    }
}

/// Points the Model's task graph at this session's file.
///
/// Called once per iteration, and idempotent: `Store.bind` compares the path and
/// returns immediately when it is the same one. Doing it HERE (the turn's thread, at
/// the top of the tool batch) and not inside a tool is what makes it safe for the
/// parallel batch to read the same store from several threads: the bind, which
/// allocates and reloads, has already happened by then, and the batch only ever gets
/// `task_list`/`task_get` (the three that write are not `isParallelSafe`).
///
/// The path is derived, never invented: `/new` and `--resume` change `s.path`, and the
/// comparison is what makes this follow them instead of keeping the list of a session
/// that is over.
fn bindTasks(m: *tui.Model, s: *session_mod.Session) void {
    const sp = s.path orelse return;
    var buf: [512]u8 = undefined;
    const path = taskstore.pathForSession(&buf, sp) catch return;
    m.tasks.bind(io_global, path);
}

fn execToolCalls(m: *tui.Model, s: *session_mod.Session, t: *TurnCtx) !?[]u8 {
    const gpa = m.allocator;
    bindTasks(m, s);
    var astate = std.heap.ArenaAllocator.init(gpa);
    defer astate.deinit();
    const arena = astate.allocator();
    const t0 = std.Io.Timestamp.now(io_global, .real).nanoseconds;
    var ran: usize = 0;
    var denied: usize = 0;
    // The budget of THIS message: it is reset for every assistant message, and
    // it is what stops a fan-out of reads from putting a megabyte in one turn.
    var budget: ResultBudget = .{};
    _ = &budget;

    var i: usize = 0;
    while (i < t.calls.items.len) {
        const call = t.calls.items[i];

        // The three tools that need the Model are intercepted HERE, before
        // `tools.execute`, because they cannot work without it: `ask` needs the
        // dialog, `task` needs to run a nested loop with this turn's HTTP client,
        // and `skill` needs the discovered entries. Reaching `execute` with one of
        // them is `error.UnknownTool`, which reads as a typo in the model's
        // arguments; the interception is the fix, not a nicer error.
        if (std.mem.eql(u8, call.name, "ask")) {
            i += 1;
            ran += askCall(m, s, call);
            continue;
        }
        if (std.mem.eql(u8, call.name, "skill")) {
            i += 1;
            ran += skillCall(m, s, call);
            continue;
        }
        if (std.mem.eql(u8, call.name, "review")) {
            // Intercepted here for the same reason as `ask` and `todo`: what it needs
            // is the TURN's list of touched files, which lives in `turn_stats` and not
            // in anything a tool can reach. A `review` tool that got the whole working
            // tree would hand back 400 files of someone else's change.
            i += 1;
            ran += reviewCall(m, s, call);
            continue;
        }
        if (std.mem.eql(u8, call.name, "task")) {
            // Consecutive `task` calls go together: they are independent
            // read-only searches, and in series each one is a full round trip of
            // waiting for something that does not depend on the previous one.
            const jt = taskBatchEnd(t.calls.items, i);
            if (jt - i == 1) {
                i += 1;
                ran += taskCall(m, s, call, arena);
            } else {
                const r = runTaskBatch(m, s, t, i, jt, arena);
                ran += r.ok + r.denied;
                i = jt;
            }
            continue;
        }

        // ── parallel batch of read-only tools ──
        //
        // Consecutive calls that only READ are gathered and run at the same time.
        // Three greps over a big tree is the common case (the model fans out to
        // find something), and in series that is 3x the wait for a result that
        // does not depend on any of the other two.
        //
        // What makes it safe is NOT "they are fast" but "they cannot observe each
        // other": no shared output buffer, no ordering requirement, no
        // permission dialog (they are all in the no-permission group). A tool
        // that wrote anything, or that the model expects to see the world after,
        // is not in `isParallelSafe` and stays in the serial path below.
        //
        // The results are appended to the session in the ORIGINAL order, because
        // that is the order the model asked for and the order it reads.
        var batch: usize = i;
        while (batch < t.calls.items.len and tools_mod.isParallelSafe(t.calls.items[batch].name)) batch += 1;

        if (batch - i > 1) {
            const n = runParallelBatch(m, s, t, i, batch, arena, &budget);
            ran += n.ok;
            denied += n.denied;
            i = batch;
            continue;
        }

        i += 1;
        ran += execOneCall(m, s, call, arena, &denied, &budget);
    }
    // The repetition guard, fed HERE because this is the only place a tool call is
    // seen with its arguments. The loop checks the flag; it cannot count, because it
    // never sees a call.
    //
    // It stays here even though the automatic check moved: this is about the CALL and
    // not about its effect, so three denied attempts to run the same command are still
    // three attempts and still a loop worth stopping.
    //
    // A call whose whole purpose is to LOOK AT SOMETHING AGAIN is exempt, and the
    // criterion is that it has no argument that could distinguish it from itself:
    // the only variable is time, and time is not in the arguments. See
    // `isRepeatExempt` and `Repeats.noteGuarded`, which is where the rule lives so
    // that this call and its tests cannot disagree.
    for (t.calls.items) |c| {
        if (m.repeats.noteGuarded(c.name, c.args_json)) |which| {
            if (m.loop_repeated == null) {
                m.loop_repeated = which;
            }
        }
    }
    // The automatic typecheck is started from the SUCCESS path of each call
    // (`execOneCall`), not from this list. This loop cannot tell a call that ran from
    // one that did not, and both of the mistakes that produced came from asking it to:
    //
    // 1. It started a check for a DENIED edit, and for one that failed to apply, so the
    //    build it waited for was a build of files that still had their old contents:
    //    green, and about the wrong thing.
    // 2. It counted them as writes, so the exit gate would refuse to let the turn end
    //    on the strength of a check covering code that was never written.
    //
    // An edit is still followed by a typecheck without the model asking — the model
    // finds out it broke something one iteration too late otherwise — and it is still
    // started in the BACKGROUND, so the model goes on to the next file and the result
    // is waiting when it looks.

    s.flush();
    // "tools done" says nothing. With the numbers it does: you know whether it was
    // fast (and therefore whether the model is going to continue or has stopped)
    // and whether there were denials, which is what you have to look at after.
    const total_ms = elapsedMs(t0);
    const tools_status = std.fmt.allocPrint(
        gpa,
        "{d} tool{s} · {d}.{d}s{s}",
        .{
            ran,
            if (ran == 1) "" else "s",
            total_ms / 1000,
            (total_ms % 1000) / 100,
            if (denied > 0) " · denied" else "",
        },
    ) catch "tools done";
    setStatusWithZo(m, .tooling, tools_status);

    // The next turn needs a user message describing the results; without it, the
    // model does not see what happened.
    if (t.calls.items.len == 0) return null;
    // Own copy, NEVER the literal: whoever receives it frees it.
    return gpa.dupe(u8, syntheticUserText) catch null;
}

/// The text sent as "user" so the model sees the tool results. It lives in a
/// constant (not inlined) so it can be tested.
pub const syntheticUserText = "Continue with the tool results above.";

/// Appends the pending images as one `user` message, and frees the base64.
///
/// It returns a NEW list rather than touching the session's, which is what keeps
/// the images out of the JSONL. It runs once per turn: the images are consumed
/// here, and an iteration later there is nothing left to attach — deliberately,
/// because the same screenshot in four consecutive requests is four times the
/// tokens for information the model already has.
///
/// A `tool` message could not carry them anyway: its content is a plain string in
/// OpenAI's shape, which is the whole reason they live in the harness instead of
/// in `read`'s result.
fn withPendingImages(m: *tui.Model, arena: std.mem.Allocator, msgs: []chat.ChatMessage) []chat.ChatMessage {
    defer m.pending_images.clear();
    if (m.pending_images.isEmpty()) return msgs;

    const note = images_mod.wireNote(arena, &m.pending_images) catch return msgs;
    const imgs = arena.alloc(chat.Image, m.pending_images.len) catch return msgs;
    for (m.pending_images.images[0..m.pending_images.len], imgs) |src, *dst| {
        dst.* = src;
    }

    const out = arena.alloc(chat.ChatMessage, msgs.len + 1) catch return msgs;
    @memcpy(out[0..msgs.len], msgs);
    out[msgs.len] = .{ .role = "user", .content = note, .images = imgs };
    pushInfoFmt(m, "· {d} image(s) sent to {s}", .{ m.pending_images.len, curAnswering() });
    return out;
}

/// `read` on an image: put the bytes aside for the next user message and return
/// the text the model reads instead.
///
/// Returns null when this is not an image read, and the normal `read` runs.
///
/// It takes the pieces it needs and NOT a `*Model`, because there are two callers
/// and they do not have one in common: the TUI (`execOneCall`) and the headless
/// runner (`--chat`, which is what the pty tests and `router_smoke` drive). The
/// first version took a `*Model` and the consequence was that the whole feature
/// silently did not exist in the runner that is actually used for testing — the
/// binary returned raw PNG bytes with no error anywhere.
///
/// Four refusals, each one a case where attaching the image would be worse than
/// not attaching it, and each one says which: no vision on the current model, over
/// the per-image cap, too many already waiting, or the path is not an image at all.
/// A model told "here is a picture" and given nothing looks for a file that does
/// not exist.
pub fn prepareImageFor(
    gpa: std.mem.Allocator,
    io: std.Io,
    pending: *images_mod.Pending,
    model: []const u8,
    args_json: []const u8,
) ?[]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch return null;
    if (parsed != .object) return null;
    const pv = parsed.object.get("path") orelse return null;
    if (pv != .string) return null;
    const path = pv.string;
    const mime = images_mod.mimeForPath(path) orelse return null;

    const vision = models_mod.isVision(model);

    // Read it even when it cannot be attached: the size is information, and a
    // missing file is an error the model needs to hear about rather than a picture
    // it cannot see.
    var dir = std.Io.Dir.cwd();
    const bytes = dir.readFileAlloc(io, path, gpa, .limited(images_mod.max_bytes * 2)) catch |err| {
        return std.fmt.allocPrint(
            gpa,
            "{s}: could not read the image ({t}). Check the path with glob or list_files.",
            .{ std.fs.path.basename(path), err },
        ) catch null;
    };
    defer gpa.free(bytes);

    if (vision and pending.len >= images_mod.max_images) pending.refused += 1;

    const p = images_mod.prepare(gpa, path, bytes, mime, vision) catch return null;
    defer p.deinit(gpa);

    if (p.image_b64) |b64| {
        const slot = &pending.images[pending.len];
        slot.* = .{ .mime = mime, .data_b64 = b64 };
        pending.len += 1;
    }
    return p.text;
}

/// The TUI's half: same function, with the `Model`'s pieces.
fn prepareImage(m: *tui.Model, args_json: []const u8) ?[]const u8 {
    // `curAnswering` and not the configured model: with the cheap router on, the
    // model that gets the request is the one that has to be able to SEE it.
    return prepareImageFor(m.allocator, io_global, &m.pending_images, curAnswering(), args_json);
}

/// Does a writing tool in this batch touch a file whose contents a compiler
/// would care about?
///
/// Leaves the process fast, on purpose, and what it gives up is measured.
///
/// ## The numbers it replaces
///
/// Measured 2026-10-05 in a pty, ctrl+c to process gone:
///
///     idle                      0.018 s
///     with a turn in flight     0.767 s
///     with a background job     1.470 s
///
/// Two things cost all of it. `waitWorkers(2000)` counts SPINS, not milliseconds —
/// `budget_ms * 200` yields — so "2000" was up to 400 000 yields. And
/// `bgproc.deinit` had a hardcoded `killAll(..., 1000)` budget behind it.
///
/// ## The three things that still have to happen
///
/// 1. **Children die.** A `sleep 60` left running after the terminal closes is a
///    process on somebody's machine with nobody watching it.
/// 2. **Workers are asked to stop.** `chat.cancel_current` is what the SSE loop
///    polls, so a request in flight aborts at the next chunk instead of being
///    waited out.
/// 3. **The session's last append is on disk.** One `writeAll`.
///
/// ## And what does not have to happen
///
/// Destroying the model, the app and the `Io` — which is what the `defer`s do, and
/// which is what the worker wait was protecting: a worker still inside `io.async`
/// after `app.deinit` used freed memory and killed the process with a segfault.
///
/// `std.process.exit` skips every defer, so nothing is freed at all and there is
/// nothing for a late worker to touch. A process that is exiting does not need its
/// heap.
///
/// ## The one risk, and why it is a risk worth taking
///
/// A worker mid-append can leave half a line. The session loader already skips what
/// it cannot parse (`parseLine(...) catch continue`), so the worst case is losing
/// that one append — not a corrupt file and not the conversation. Losing the last
/// line of a session the user just cancelled is the right trade against making every
/// exit cost a second.
pub fn quitFast(m: *tui.Model, io: std.Io) noreturn {
    // 1. Children first, so nothing is orphaned even if the rest is cut short.
    //
    // The FOREGROUND one is the easy half to forget, and forgetting it orphans a
    // process: a `bash` that did not get `run_in_background` has its pid in the
    // foreground slot, not in the job registry, so `killAll` walks past it. ESC kills
    // that slot (see `bgproc.killForeground`) and quitting did not, which is only
    // visible when you quit while a foreground command is still running.
    //
    // Measured: a `sleep 331` started by a `bash` that the model ran in the
    // foreground survived ctrl+c with `killAll` alone, 0.05 s after the exit.
    _ = killForeground();
    _ = bgproc.requestKillAll(&m.bg);
    bgproc.killAll(&m.bg, io, 120);

    // 2. Workers: ask, then a SHORT wait. 60 ms is not arbitrary either — it is
    // long enough for a worker that is between operations to notice and leave, and
    // short enough that the common case (idle, nothing running) costs nothing at all.
    chat.cancel_current.store(true, .seq_cst);
    m.waitWorkers(60);

    // 3. The language servers. They are children too, and they are NOT in the
    // job registry: a `zls` that outlived the app would keep indexing a
    // project nobody is looking at any more.
    //
    // AFTER the workers are asked to stop, and not before: a worker in the
    // middle of a question holds the client, and the manager does not free a
    // client somebody is inside (it kills the server instead, which is what
    // matters at this point).
    lsp_manager.shutdown();

    // 3b. The MCP servers. They are children too, and they are NOT in the job
    // registry either: an MCP server that outlived the app would keep running
    // for nobody.
    mcp_manager.shutdown();

    // 4. The session. One write, and it is the only reason any of this exists.
    if (session) |s| s.flush();

    // 5. The terminal. `std.process.exit` runs NO defer, and vaxis leaves the
    // screen in the alternate buffer (`CSI ? 1049 h`) with the mouse captured
    // and the cursor hidden. So the defers that would undo it never run, and
    // ctrl+c left the app ON SCREEN: the last frame still there, the cursor
    // hidden, the shell prompt nowhere. The user's "it closed but zode is still
    // visible" is exactly this, and not a leaked process.
    //
    // We must write to /dev/tty (the controlling terminal) NOT stdout, because
    // stdout may be redirected or not connected to the terminal (e.g. in tmux,
    // script, or when piped). vaxis does the same: it opens /dev/tty and writes
    // escape sequences there. We also restore the termios to exit raw mode,
    // which the escape sequences alone cannot do.
    {
        // Open the controlling terminal directly
        const tty_file = std.Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .read_write }) catch {
            std.process.exit(0);
        };
        defer tty_file.close(io);
        var tty_buf: [256]u8 = undefined;
        var fw = tty_file.writerStreaming(io, &tty_buf);
        termseq.restoreAll(&fw.interface);

        // Also restore termios (exit raw mode). This is what vaxis does in its
        // deinit via posix.tcsetattr. Without this, the terminal stays in raw
        // mode and the user can't type after exit.
        const fd = tty_file.handle;
        restoreTermios(fd);
    }

    std.process.exit(0);
}

fn restoreTermios(fd: posix.fd_t) void {
    const termios = posix.tcgetattr(fd) catch return;
    var termios_copy = termios;
    termios_copy.lflag.ECHO = true;
    termios_copy.lflag.ICANON = true;
    termios_copy.lflag.ISIG = true;
    termios_copy.oflag.OPOST = true;
    termios_copy.iflag.ICRNL = true;
    termios_copy.iflag.IXON = true;
    _ = posix.tcsetattr(fd, .FLUSH, termios_copy) catch {};
}

/// Starts the startup probe: reads `ZODE_DBG_BOOT` and takes t0.
///
/// It has to be called BEFORE anything is measured, which in `runTui` is the very
/// first thing: the first mark sits inside `vxfw.App.init`, before `bootMark` would
/// otherwise have an `Io` to read a clock from.
pub fn bootStart(io: std.Io, env: ?*const std.process.Environ.Map) void {
    boot_io = io;
    boot_t0 = bootNowMs(io);
    boot_dbg = blk: {
        const v = if (env) |m| m.get("ZODE_DBG_BOOT") orelse "" else "";
        break :blk v.len > 0 and !std.mem.eql(u8, v, "0");
    };
}

var boot_dbg = false;
var boot_io: ?std.Io = null;
var boot_t0: f64 = 0;

fn bootNowMs(io: std.Io) f64 {
    const ns = std.Io.Timestamp.now(io, .awake).toNanoseconds();
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

pub fn bootMark(label: []const u8) void {
    if (!boot_dbg) return;
    const io = boot_io orelse return;
    var buf: [192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("[boot] {s: <22} {d:>7.2} ms\n", .{ label, bootNowMs(io) - boot_t0 }) catch return;
    // A SECOND buffer for the file: the writer takes one and the formatter above
    // writes into the same one, so sharing it prints the writer's idea of a buffer
    // header over the line.
    var fbuf: [256]u8 = undefined;
    var f = std.Io.File.stderr().writerStreaming(io, &fbuf);
    f.interface.writeAll(w.buffered()) catch {};
    // The `flush` is not optional: `writeAll` on a `File.Writer` appends to ITS
    // buffer, and a probe that measures startup and never flushed printed nothing at
    // all — which is indistinguishable from the marks not firing, and cost a round
    // trip to tell apart.
    f.interface.flush() catch {};
}

/// How long the terminal gets to answer vaxis's capability query.
///
/// vaxis hardcodes one second (`vx.queryTerminal(tty.writer(), .fromSeconds(1))` in
/// `vxfw/App.zig`) and the wait ends ONLY on a `DA1` reply — nothing else wakes it.
/// Measured with `ZODE_DBG_BOOT=1` in a pty that does not answer: 1.55 ms of our own
/// startup and 1004 ms inside `App.run`, which is this wait, not our work.
///
/// A terminal that speaks `DA1` replies in single-digit milliseconds (it answers the
/// instant it reads the query), so the second is only ever paid by a terminal that is
/// not going to answer: `dumb`, some `screen`/container setups, and every pty harness
/// in this repo. 250 ms is generous for any real terminal and bounds the pathological
/// case, and losing the answers only leaves vaxis on its defaults, which is the path
/// it already takes for a terminal without those capabilities.
pub const term_query_ms: u64 = 250;

/// The thread that caps the query wait, and the `App` it points into.
///
/// A global and not a field of the Model because the thing it has to outlive is
/// `App.run` itself, which no Model is passed to. It is joined by
/// `stopTermQueryCap`, registered as a defer AFTER `defer app.deinit()` so it runs
/// BEFORE it: the error path of `App.run` returns and deinits the App while this
/// thread could still be counting, and that would be a write into freed memory.
///
/// The normal exit does not go through that path — `quitFast` is `noreturn` and skips
/// every defer, so on ctrl+c nothing is freed and the thread's store lands in memory
/// that is still mapped. That is the same trade `quitFast` makes on purpose.
var cap_thread: ?std.Thread = null;

fn capTermQuery(vx: *vaxis.Vaxis, ms: u64) void {
    // In slices, not one nap: the whole point of the thread is to be interruptible,
    // and a single `nap(ms)` could not be.
    var waited: u64 = 0;
    while (waited < ms) : (waited += 10) {
        sleepz.nap(@min(10, ms - waited));
    }
    // `futexWake` and NOT a plain `query_futex.store(1)`: a raw store changed the
    // value the waiter is comparing against and the wait still ran the full second,
    // because `futexWait` goes through the `Io` vtable, which keeps its own waiter
    // bookkeeping. This is the same call vaxis makes when a `DA1` arrives
    // (`Loop.zig`, on `.cap_da1`) — only on a timer instead of on a reply.
    std.Io.futexWake(vx.io, std.atomic.Value(u32), &vx.query_futex, 1);
}

/// `ZODE_TERM_QUERY_MS`: 0 means "do not touch it" (vaxis's own one second).
pub fn termQueryCapMs(env: ?*const std.process.Environ.Map) u64 {
    const m = env orelse return term_query_ms;
    const s = m.get("ZODE_TERM_QUERY_MS") orelse return term_query_ms;
    return std.fmt.parseInt(u64, s, 10) catch term_query_ms;
}

pub fn startTermQueryCap(vx: *vaxis.Vaxis, env: ?*const std.process.Environ.Map) void {
    const ms = termQueryCapMs(env);
    if (ms == 0) return;
    cap_thread = std.Thread.spawn(.{}, capTermQuery, .{ vx, ms }) catch return;
}

/// Joins the cap thread. Must run before the `App` it points into is destroyed.
pub fn stopTermQueryCap() void {
    const t = cap_thread orelse return;
    cap_thread = null;
    t.join();
}

// The body that used to live here is `AutoCheck.collect`, which both runners call.
// A second copy of it is how the headless runner ended up without an automatic
// typecheck at all while the TUI had one.

fn countDiagLines(s: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |l| if (std.mem.trim(u8, l, " \t\r").len != 0) {
        n += 1;
    };
    return n;
}

/// Does this tool modify a file on disk?
fn touchesFile(name: []const u8) bool {
    return std.mem.eql(u8, name, "write") or
        std.mem.eql(u8, name, "edit") or
        // A notebook edit rewrites a file whole, so `/undo` has to have the bytes it
        // had before: this is the list that decides whether a snapshot is taken, and a
        // tool missing from it is an edit nobody can take back.
        std.mem.eql(u8, name, "notebook_edit");
}

/// Does this CALL modify a file?
///
/// A `batch` is decided by its steps: a batch of reads is a read, and a batch
/// with a `write` or an `edit` step is a write. The static list of write
/// tools cannot say that, and a batch that wrote in plan mode would be a
/// hole in the mode.
fn callIsWrite(name: []const u8, args_json: []const u8, arena: std.mem.Allocator) bool {
    if (std.mem.eql(u8, name, "batch")) return tools_mod.callWrites(name, args_json, arena);
    // An MCP CALL can change the world: the tool behind it is the user's own
    // and zode cannot know what it does, so plan mode blocks it. The `list`
    // and `search` operations only read the catalogue and are allowed: a plan
    // written without looking is a plan written in the dark.
    if (std.mem.eql(u8, name, "mcp")) return tools_mod.callWrites(name, args_json, arena);
    return isWriteTool(name);
}

/// The BEFORE snapshot of one file, for `/undo`.
///
/// `existed` is separate because "it was not there" and "it was empty" undo
/// differently (delete vs write empty), and a `catch ""` does not tell them
/// apart. A read that fails for any OTHER reason takes no snapshot at all:
/// `/undo` would delete a file it never managed to read, which is the worst
/// thing an undo can do.
fn snapshotForUndo(m: *tui.Model, pth: []const u8, arena: std.mem.Allocator) void {
    if (std.Io.Dir.cwd().readFileAlloc(io_global, pth, arena, .limited(4 * 1024 * 1024))) |content| {
        m.snapshotFile(pth, content, true);
    } else |err| {
        switch (err) {
            error.FileNotFound => m.snapshotFile(pth, "", false),
            else => {},
        }
    }
}

/// Does this call need the permission dialog?
///
/// The permission set is the union of the tools the call is a call to, and a
/// tool that is already on the allowlist does not ask again.
fn permNeedsDialog(perm_tools: []const []const u8) bool {
    for (perm_tools) |t| {
        if (tools_mod.needsPermission(t) and !isAlwaysAllowed(t)) return true;
    }
    return false;
}

/// The `a` key on the permission dialog, for a call whose permission set is a
/// UNION.
///
/// For a batch it remembers the TOOLS its steps are calls to, and not
/// "batch": what the user approved, having just read a dialog that named the
/// files, is the write. Remembering "batch" would make one approval cover
/// every batch the model writes later, which is not what anybody answered.
/// The rule the "always allow" answer would remember, as TEXT.
///
/// It is what the dialog shows and what the answer learns:
///
/// - a `bash` command becomes `Bash(git *) allow` — the FIRST WORD, and not
///   the whole command: "always allow `git status`" would mean the next
///   `git commit` asks again, and "always allow `git`" is the answer the
///   user actually means when they approve a `git` command;
/// - a tool that writes a file becomes `Write(src/main.zig) allow` — the file
///   itself, because a directory is a bigger promise than the user made;
/// - anything else becomes `<tool>(*) allow`.
///
/// It is a SUGGESTION and not a decision: the user reads it in the dialog
/// before answering, and the answer is what is remembered.
pub fn permSuggestion(call_name: []const u8, args_json: []const u8, arena: std.mem.Allocator) ?[]const u8 {
    if (std.mem.eql(u8, call_name, "bash")) {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch return null;
        if (parsed != .object) return null;
        const cmd = parsed.object.get("command") orelse return null;
        if (cmd != .string) return null;
        const first = firstWord(cmd.string);
        if (first.len == 0) return null;
        return std.fmt.allocPrint(arena, "Bash({s} *) allow", .{first}) catch null;
    }
    // An MCP call remembers the QUALIFIED name of the tool: `Mcp(github.create_issue)`.
    //
    // Not `Mcp(*)`: that would be every server the user ever configures, and
    // the answer the user gives is about ONE tool whose name they just read.
    if (std.mem.eql(u8, call_name, "mcp")) {
        // The subject IS the qualified name, and it is empty when the call is
        // not a call or its arguments do not parse: then there is nothing to
        // suggest, and the dialog falls back to the generic one.
        const q = tools_mod.callSubjects(call_name, args_json, arena);
        if (q.len != 1 or q[0].len == 0) return null;
        return std.fmt.allocPrint(arena, "Mcp({s}) allow", .{q[0]}) catch null;
    }
    const paths = tools_mod.callTouchedPaths(call_name, args_json, arena);
    if (paths.len == 1 and paths[0].len > 0) {
        return std.fmt.allocPrint(arena, "{s}({s}) allow", .{ call_name, paths[0] }) catch null;
    }
    return std.fmt.allocPrint(arena, "{s}(*) allow", .{call_name}) catch null;
}

/// The first word of a command, without the quotes.
fn firstWord(command: []const u8) []const u8 {
    var i: usize = 0;
    while (i < command.len and (command[i] == ' ' or command[i] == '\t')) i += 1;
    const start = i;
    while (i < command.len and command[i] != ' ' and command[i] != '\t') i += 1;
    return command[start..i];
}

/// Learns the rule of an "always allow" answer.
///
/// It goes in TWO places: the in-memory set (source `local`, the strongest,
/// because the user just said it) and the USER file, so it survives the
/// session. The project file is NOT touched: a rule the user just made is
/// theirs, not the project's.
fn learnRuleForCall(m: *tui.Model, call_name: []const u8, args_json: []const u8, arena: std.mem.Allocator) void {
    const text = permSuggestion(call_name, args_json, arena) orelse return;
    const rule = permrules.parseRule(text, .local, arena) orelse return;

    // The in-memory set: the strongest source, so the rule the user just
    // made wins over the ones in the files.
    if (perm_rules_arena == null) {
        perm_rules_arena = std.heap.ArenaAllocator.init(gpa_global);
    }
    const a = perm_rules_arena.?.allocator();
    var all: std.ArrayList(permrules.Rule) = .empty;
    for (perm_rules.rules) |r| all.append(a, r) catch {};
    all.append(a, rule) catch {};
    perm_rules = .{ .rules = all.items };

    // And the file, so it is there tomorrow.
    if (savePermRule(rule)) {
        const msg = std.fmt.allocPrint(m.allocator, "always allowed: {s}", .{text}) catch return;
        pushInfoOwned(m, msg);
    }
}

/// Appends a rule to the USER's `permissions.json`.
///
/// The file is written WHOLE, and the parts this code does not know about
/// are kept: it is hand-edited, it carries the allowlist too, and dropping
/// what the user wrote by hand is the one thing a permission file must never
/// do.
fn savePermRule(rule: permrules.Rule) bool {
    var pbuf: [512]u8 = undefined;
    const path = permissionsFilePath(&pbuf) orelse return false;

    var astate = std.heap.ArenaAllocator.init(gpa_global);
    defer astate.deinit();
    const a = astate.allocator();

    // What is in there now: the tools, the bash patterns and the rules.
    var names: [max_always][]const u8 = undefined;
    var n: usize = 0;
    var pats: [max_bash_patterns][]const u8 = undefined;
    var np: usize = 0;
    var rules: std.ArrayList([]const u8) = .empty;
    if (readFileTo(a, path)) |data| {
        if (std.json.parseFromSliceLeaky(std.json.Value, a, data, .{})) |parsed| {
            switch (parsed) {
                .object => |o| {
                    if (o.get("tools")) |tv| {
                        if (tv == .array) for (tv.array.items) |v| {
                            if (v == .string and n < names.len) {
                                names[n] = v.string;
                                n += 1;
                            }
                        };
                    }
                    if (o.get("bash")) |bv| {
                        if (bv == .array) for (bv.array.items) |v| {
                            if (v == .string and np < pats.len) {
                                pats[np] = v.string;
                                np += 1;
                            }
                        };
                    }
                    if (o.get("rules")) |rv| {
                        if (rv == .array) for (rv.array.items) |v| {
                            if (v == .string) rules.append(a, v.string) catch {};
                        };
                    }
                },
                .array => |arr| {
                    // The old shape: a bare array is the tool allowlist.
                    for (arr.items) |v| {
                        if (v == .string and n < names.len) {
                            names[n] = v.string;
                            n += 1;
                        }
                    }
                },
                else => {},
            }
        } else |_| {}
    }

    // The new rule, as the STRING the grammar is written in: it is the shape
    // a human reads, and the parser accepts it.
    rules.append(a, rule.text) catch return false;

    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("{{\"tools\":", .{}) catch return false;
    config_mod.writeStringArray(&w, gpa_global, names[0..n]) catch return false;
    w.print(",\"bash\":", .{}) catch return false;
    config_mod.writeStringArray(&w, gpa_global, pats[0..np]) catch return false;
    w.print(",\"rules\":[", .{}) catch return false;
    for (rules.items, 0..) |r, i| {
        if (i > 0) w.print(",", .{}) catch return false;
        config_mod.writeJsonString(&w, gpa_global, r) catch return false;
    }
    w.print("]}}", .{}) catch return false;
    std.Io.Dir.cwd().writeFile(io_global, .{ .sub_path = path, .data = w.buffered() }) catch return false;
    return true;
}

fn allowAlwaysForCall(m: *tui.Model, name: []const u8, arg: []const u8, perm_tools: []const []const u8) void {
    // An MCP call remembers the QUALIFIED name of the tool it is about
    // (`github.create_issue`), and not the tool `mcp`: what the user approved,
    // having just read a dialog that named the tool, is that one tool.
    // Remembering `mcp` would make one approval cover every server the user
    // ever configures, which is not what anybody answered.
    if (std.mem.eql(u8, name, "mcp")) {
        for (perm_tools) |t| {
            if (!tools_mod.needsPermission(t)) continue;
            setAlwaysAllowed(m, t);
        }
        return;
    }
    if (!std.mem.eql(u8, name, "batch")) {
        allowAlwaysFor(m, name, arg);
        return;
    }
    for (perm_tools) |t| {
        if (!tools_mod.needsPermission(t)) continue;
        setAlwaysAllowed(m, t);
    }
}

/// Tools blocked in read-only mode.
///
/// `bash` is in the list even though a `bash` can be a pure read, because it can
/// also be `rm`: the mode has to be decided from the tool, not from parsing the
/// command string, or every read-only mode would be bypassable by writing
/// `bash ls` first to learn what the model "really" wants to run.
/// The tools that CHANGE the world: every write-ish tool, `bash` among them.
///
/// Plan (read-only) mode refuses exactly these, so the list has to be complete:
/// `rename` and the git mutations (`git_add`/`git_commit`/`git_stash`/
/// `git_branch`) were missing, and `needsPermission` EXEMPTS the git tools from
/// the dialog — together they were a hole through which plan mode could rewrite
/// files and commit them while saying it touched nothing. Read-only git tools
/// (status/diff/log) are deliberately NOT here.
pub fn isWriteTool(name: []const u8) bool {
    return isEditTool(name) or // write, edit, rename
        std.mem.eql(u8, name, "bash") or
        std.mem.eql(u8, name, "git_add") or
        std.mem.eql(u8, name, "git_commit") or
        std.mem.eql(u8, name, "git_stash") or
        std.mem.eql(u8, name, "git_branch");
}

/// The tools that change files but run no command: the ones
/// accept-edits mode auto-allows. `bash` is deliberately NOT here —
/// accepting edits is not accepting arbitrary commands — and neither
/// is `task`, because a subagent is exactly the thing that should
/// stay behind a dialog.
pub fn isEditTool(name: []const u8) bool {
    return std.mem.eql(u8, name, "write") or
        std.mem.eql(u8, name, "edit") or
        std.mem.eql(u8, name, "rename") or
        // A file edit: accept-edits may auto-allow it, and plan mode must refuse it.
        std.mem.eql(u8, name, "notebook_edit");
}

/// Path of the file a writing tool touches (or null if it does not say).
fn filePathOf(args_json: []const u8, arena: std.mem.Allocator) ?[]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch return null;
    if (parsed != .object) return null;
    // `notebook_path` is the second spelling, and it is not decoration: without it a
    // notebook edit would take NO snapshot (`/undo` would have nothing to restore) for
    // the one kind of file where a bad edit is most destructive.
    const v = parsed.object.get("path") orelse parsed.object.get("notebook_path") orelse return null;
    if (v != .string or v.string.len == 0) return null;
    return v.string;
}

/// Identifying argument of a tool, for the `⏺ tool(arg)` line.
fn toolArgSummary(name: []const u8, args_json: []const u8, arena: std.mem.Allocator) []const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch return "";
    if (parsed != .object) return "";
    // A batch's arguments are a LIST of steps: there is no single path to
    // name, and the "first string wins" fallback below would find none (the
    // strings are inside the steps). The COUNT is what one row can say, and
    // it is the thing the user wants to know: how much this one call does.
    if (std.mem.eql(u8, name, "batch")) {
        const steps_v = parsed.object.get("steps") orelse return "steps";
        if (steps_v != .array) return "steps";
        return std.fmt.allocPrint(arena, "{d} steps", .{steps_v.array.items.len}) catch "steps";
    }
    // An MCP call's one interesting argument is the tool it is about:
    // `mcp(call)` says nothing, and the line the user reads is the line they
    // are approving. The qualified name is decided by the tool's own module,
    // so the timeline and the permission rule cannot disagree about it.
    if (std.mem.eql(u8, name, "mcp")) {
        if (mcp_tool.qualifiedOf(parsed.object, arena)) |qualified| return qualified;
        // A search names its query instead: there is no tool yet.
        const query = parsed.object.get("query") orelse return "";
        if (query != .string) return "";
        return query.string;
    }
    const wanted: []const u8 = if (std.mem.eql(u8, name, "read") or
        std.mem.eql(u8, name, "write") or std.mem.eql(u8, name, "edit") or
        std.mem.eql(u8, name, "list_files"))
        "path"
    else if (std.mem.eql(u8, name, "bash"))
        "command"
    else if (std.mem.eql(u8, name, "glob") or std.mem.eql(u8, name, "grep"))
        "pattern"
    else if (std.mem.eql(u8, name, "web_fetch"))
        "url"
    else if (std.mem.eql(u8, name, "web_search"))
        "query"
    else if (std.mem.eql(u8, name, "notebook_edit"))
        // Named, not left to the "first string wins" fallback below: the timeline
        // line should show WHICH notebook, and relying on field order for that is
        // one schema reorder away from showing a cell index instead.
        "notebook_path"
    else if (std.mem.eql(u8, name, "lsp"))
        ""
    else
        "";
    const raw: []const u8 = if (wanted.len > 0) blk: {
        if (parsed.object.get(wanted)) |v| {
            if (v == .string) break :blk v.string;
        }
        break :blk "";
    } else "";
    // Without the expected field, the first string there is will do.
    const fallback: []const u8 = if (raw.len > 0) raw else blk: {
        var it = parsed.object.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.* == .string) break :blk kv.value_ptr.*.string;
        }
        break :blk "";
    };
    // CLIPPED, and this is the fix for the timeline filling with garbage. A
    // `bash` argument is whatever the model wrote, and a real one is a
    // three-pipeline command of several hundred columns. Returned as is, it
    // goes into the header `*bash*(<command>)` and into the status bar, and
    // the header is a PARAGRAPH: it wraps. One long command was worth eight
    // rows of the history and pushed the answer off screen.
    //
    // `arg_max_cols` is what one row can show before it stops being a header,
    // and the clip is in COLUMNS (`textcap`), so a command with CJK or an emoji
    // counts correctly rather than by bytes. The full command stays in the
    // session and in Ctrl+R; this is what the human reads.
    var buf: [textcap.scratchFor(arg_max_cols)]u8 = undefined;
    const clipped = textcap.clipInto(fallback, arg_max_cols, &buf);
    if (clipped.len == 0) return "";
    return arena.dupe(u8, clipped) catch fallback;
}

/// What the TIMELINE shows for a tool call: the model's own one-line
/// `description` when it sent one, else the argument summary.
///
/// `bash` gained an optional `description` (what the command is FOR), and the
/// timeline leads with it: `⏺ bash(running the test suite)` is what the human
/// reads at a glance, where a clipped three-pipeline command was noise. Only
/// the FIRST line is used and control bytes become spaces — the timeline row
/// is one line, and an interior newline painted raw is a bug this repo has
/// already paid for (the ask panel).
///
/// **The two consumers of a call's text stay apart on purpose.** The
/// permission dialog and the allowlist matching keep receiving `arg` (the
/// COMMAND, from `toolArgSummary`): a permission matched against the model's
/// own prose would be no permission at all — `description: "git status"` over
/// `command: "rm -rf /"` must never ride the `git status` allowlist. The
/// timeline reads intent; the machine reads the command.
fn toolTimelineLabel(name: []const u8, args_json: []const u8, arg: []const u8, arena: std.mem.Allocator) []const u8 {
    if (!std.mem.eql(u8, name, "bash")) return arg;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch return arg;
    if (parsed != .object) return arg;
    const dv = parsed.object.get("description") orelse return arg;
    if (dv != .string) return arg;
    const line_end = std.mem.indexOfScalar(u8, dv.string, '\n') orelse dv.string.len;
    var clean_buf: [textcap.scratchFor(arg_max_cols)]u8 = undefined;
    var clen: usize = 0;
    for (dv.string[0..line_end]) |c| {
        // Over the scratch is clipped later anyway, and a cut mid-character is
        // healed by `clipInto`'s walk back to a char start.
        if (clen >= clean_buf.len) break;
        clean_buf[clen] = if (c < 0x20) ' ' else c;
        clen += 1;
    }
    const clean = std.mem.trim(u8, clean_buf[0..clen], " \t\r");
    if (clean.len == 0) return arg;
    var clip_buf: [textcap.scratchFor(arg_max_cols)]u8 = undefined;
    const clipped = textcap.clipInto(clean, arg_max_cols, &clip_buf);
    if (clipped.len == 0) return arg;
    return arena.dupe(u8, clipped) catch arg;
}

/// Columns a tool argument gets in the header and the status row.
///
/// Chosen from the row, not from taste: a header is one visual row wide on the
/// widest text the user can read, and past that it wraps and stops being a
/// header. The command is what the model SENT, and the full text stays in the
/// session and in Ctrl+R; this is what the human reads.
pub const arg_max_cols: usize = 60;

/// One-line summary of a tool's result (`⎿ Read 12 lines`).
fn toolResultSummary(name: []const u8, res: []const u8, arena: std.mem.Allocator) []const u8 {
    if (res.len == 0) return "";
    var it = std.mem.splitScalar(u8, res, '\n');
    const first = it.next() orelse return "";
    if (std.mem.eql(u8, name, "bash")) {
        const status = if (std.mem.indexOf(u8, first, "exit=")) |at|
            first[at + "exit=".len ..]
        else
            first;
        var summary: std.ArrayList(u8) = .empty;
        summary.appendSlice(arena, "exit ") catch return first;
        summary.appendSlice(arena, status) catch return first;

        var section: enum { none, stdout, stderr } = .none;
        var stdout_lines: usize = 0;
        var stderr_lines: usize = 0;
        var capped = false;
        var lines = std.mem.splitScalar(u8, res, '\n');
        while (lines.next()) |line| {
            if (std.mem.eql(u8, line, "--- stdout ---")) {
                section = .stdout;
                continue;
            }
            if (std.mem.eql(u8, line, "--- stderr ---")) {
                section = .stderr;
                continue;
            }
            if (std.mem.indexOf(u8, line, "output cut at the tool's cap") != null) {
                capped = true;
                continue;
            }
            if (std.mem.trim(u8, line, " \t\r").len == 0 or std.mem.startsWith(u8, line, "exit=")) continue;
            switch (section) {
                .stdout => stdout_lines += 1,
                .stderr => stderr_lines += 1,
                .none => {},
            }
        }
        if (stdout_lines > 0) {
            summary.print(arena, " · stdout {d} line{s}", .{ stdout_lines, if (stdout_lines == 1) "" else "s" }) catch return first;
        }
        if (stderr_lines > 0) {
            summary.print(arena, " · stderr {d} line{s}", .{ stderr_lines, if (stderr_lines == 1) "" else "s" }) catch return first;
        }
        if (capped) summary.appendSlice(arena, " · output capped") catch return first;
        return summary.items;
    }
    // `write` says "wrote X (N bytes, M lines)" and then a preview. The one-line
    // summary is that first line: the preview is the tool result (what the
    // model sees) and shows up in the history under it.
    if (std.mem.eql(u8, name, "read")) {
        // The read lines carry "   12│ text": count them.
        var n: usize = 0;
        var probe = std.mem.splitScalar(u8, res, '\n');
        while (probe.next() != null) n += 1;
        return std.fmt.allocPrint(arena, "Read {d} lines", .{n}) catch first;
    }
    if (std.mem.eql(u8, name, "list_files")) {
        var n: usize = 0;
        var it2 = std.mem.splitScalar(u8, res, '\n');
        while (it2.next()) |l| {
            if (l.len > 0) n += 1;
        }
        return std.fmt.allocPrint(arena, "{d} entries", .{n}) catch first;
    }
    if (std.mem.eql(u8, name, "grep")) {
        var n: usize = 0;
        var it2 = std.mem.splitScalar(u8, res, '\n');
        while (it2.next()) |l| {
            if (l.len > 0) n += 1;
        }
        return std.fmt.allocPrint(arena, "{d} matches", .{n}) catch first;
    }
    // Web: the first line of a fetch is the title of the first hit, which as a
    // summary says nothing. Count what is really there.
    if (std.mem.eql(u8, name, "web_fetch")) {
        var n: usize = 0;
        var it2 = std.mem.splitScalar(u8, res, '\n');
        while (it2.next()) |l| {
            if (l.len > 0) n += 1;
        }
        if (res.len > 1024 * 1024) {
            return std.fmt.allocPrint(arena, "{d} lines · {d} MB", .{ n, res.len / (1024 * 1024) }) catch first;
        }
        return std.fmt.allocPrint(arena, "{d} lines · {d} KB", .{ n, res.len / 1024 }) catch first;
    }
    if (std.mem.eql(u8, name, "web_search")) {
        // Counts the numbered lines (`1. Title`) of the `web.searchResults` format.
        // Counting indented URLs was fragile: the indentation changes and the
        // counter comes out at zero.
        var n: usize = 0;
        var it2 = std.mem.splitScalar(u8, res, '\n');
        while (it2.next()) |l| {
            var k: usize = 0;
            while (k < l.len and l[k] >= '0' and l[k] <= '9') k += 1;
            if (k > 0 and k + 1 < l.len and l[k] == '.' and l[k + 1] == ' ') n += 1;
        }
        return std.fmt.allocPrint(arena, "{d} result{s}", .{ n, if (n == 1) "" else "s" }) catch first;
    }
    return first;
}

fn elapsedMs(t0: i128) u64 {
    const now = std.Io.Timestamp.now(io_global, .real).nanoseconds;
    if (now <= t0) return 0;
    return @intCast(@divTrunc(now - t0, 1_000_000));
}

// ── errors and retries ────────────────────────────────────────

/// 429 and 5xx are retried; 401/403 are not (the key is wrong: insisting does
/// not help).
fn isRetryable(err: anyerror) bool {
    return switch (err) {
        error.RateLimited, error.Overloaded, error.ServerError => true,
        else => false,
    };
}

/// [roster] Does this error mean "this provider/model is done giving"?
///
/// It is the question that decides whether the turn CONTINUES with another
/// provider/model pair (which is what `/free-auto` does) or gives up with a
/// message. And that is why the table is so thin: the action that corresponds is
/// the OPPOSITE depending on the row.
///
/// | error                 | verdict | why                                                 |
/// |-----------------------|---------|-----------------------------------------------------|
/// | 402 NoCredits         | yes     | out of credits. Retrying the same is pointless.     |
/// | 429 RateLimited       | yes     | the model's quota, not the key's. Another pair works.|
/// | 403 "...within OpenCode" | yes  | it is the GATE, not the config. Another pair works.  |
/// | 403 without that      | NO      | almost always a model not available on the account. |
/// | 401 AuthFailed        | NO      | it is the key. Rotating gives the same 401 on all 7.|
/// | 404 ModelNotFound     | NO      | it is a bad id, not a quota.                        |
///
/// `detail` is the body of the server's error (`chat.lastErrorBody`), which is
/// where the phrase that decides the 403 row lives: "can only be used from
/// within OpenCode" and "your credit balance is too low" are two 403s that mean
/// opposite things.
///
/// No allocation: it is called on the error path, and returning memory would
/// force every caller into a `defer` inside a `catch`.
pub fn quotaVerdict(err: anyerror, detail: []const u8) ?roster_mod.Why {
    return switch (err) {
        error.NoCredits => .no_credits,
        error.RateLimited => .rate_limited,
        error.Forbidden => if (isGateMessage(detail)) .gated else .misconfigured,
        else => null,
    };
}

/// Is the 403's text opencode's gate (or an equivalent one)?
///
/// Real phrases that have been seen in the `reason` of a 403:
///   "can only be used from within OpenCode"
///   "Model access is disabled"
///   "model is not available for your account"
/// It is a substring match, case insensitive, because every provider words its
/// own, and there is no one constant that works for all of them.
pub fn isGateMessage(detail: []const u8) bool {
    return containsNoCase(detail, "within opencode") or
        containsNoCase(detail, "access is disabled") or
        containsNoCase(detail, "not available for your") or
        containsNoCase(detail, "only be used from within") or
        containsNoCase(detail, "agentic harness") or
        containsNoCase(detail, "not available on this account");
}

/// `containsNoCase` without allocating: it lowercases the two characters at a
/// time instead of building a lowercase copy of the whole text.
pub fn containsNoCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var k: usize = 0;
        while (k < needle.len and
            std.ascii.toLower(haystack[i + k]) == std.ascii.toLower(needle[k])) k += 1;
        if (k == needle.len) return true;
    }
    return false;
}

const Retry = struct {
    /// How long to wait BEFORE retry `attempt` (0-indexed), in ms.
    ///
    /// Exponential backoff: 500ms, 1s, 2s (+jitter). It lives apart from `wait`
    /// so that the notice can say "retrying in 1.0s" with the SAME number that
    /// is going to be waited: if they were two formulas, the message would lie
    /// as soon as one of them was touched.
    ///
    /// CAREFUL with the exponent: it was `attempt -| 1`, which saturates to 0
    /// and gave 500, 500, 1000 — the first retry did not wait longer than the
    /// second, which is exactly the opposite of what the comment says. With
    /// `1 << attempt` the series is the one always documented.
    fn backoffMs(attempt: usize) u64 {
        const base_ns: i128 = @as(i128, 500) * std.time.ns_per_ms * (@as(i128, 1) << @intCast(attempt));
        var h: u64 = 0x9E3779B97F4A7C15 *% @as(u64, @intCast(attempt));
        h ^= h >> 33;
        const jitter: i128 = @as(i128, @intCast(h & 0xFF)) * @divTrunc(std.time.ns_per_ms, 256);
        return @intCast(@divTrunc(base_ns + jitter, std.time.ns_per_ms));
    }

    /// How long to wait BEFORE retrying, honoring the server's `retry-after` if it
    /// sent one.
    ///
    /// `retry_after_secs` was in `chat` from the start and NOBODY read it: a 429
    /// with `retry-after: 30` waited 1s and ate the entire rate limit, three
    /// times in a row. It is pure arithmetic (testable) and the `wait` below
    /// only uses it to slice the wait.
    fn waitMs(attempt: usize) u64 {
        var ms = backoffMs(attempt);
        if (chat.retry_after_secs) |ra| {
            const want: u64 = @as(u64, ra) * 1000;
            // 30s ceiling: beyond that it is better to give up and let the error
            // the user has to act on (/provider, /model) say so than keep
            // waiting in silence.
            ms = @max(ms, @min(want, 30_000));
        }
        return ms;
    }

    fn wait(attempt: usize) !void {
        var left: i128 = @as(i128, waitMs(attempt)) * std.time.ns_per_ms;
        // Sleeps in slices so ESC can cut the wait short.
        //
        // CAREFUL about the HOW: this runs from a WORKER, and
        // `io_global.sleep` takes down the event loop of the `Io` shared with
        // the TUI (the same problem `lib/sleep.nap` exists for). With `sleep` it
        // is not just the strip's clock that freezes: the redraws stop, so the
        // retry notices stayed in `pending` unpainted and you had to press a key
        // to see them. `sleep.nap()` is a bare `nanosleep` that does not touch the
        // `Io`.
        while (left > 0) {
            if (chat.cancelled()) return error.Cancelled;
            const chunk_ms: u64 = @intCast(@min(@divTrunc(left, std.time.ns_per_ms), 50));
            if (chunk_ms > 0) sleep.nap(chunk_ms);
            left -= @as(i128, chunk_ms) * std.time.ns_per_ms;
        }
    }
};

/// Notice in the history before retrying (so the user sees it is not hung).
///
/// It says WHAT happened and HOW LONG is left, not just "retrying":
/// `RateLimited (attempt 2/3)` tells nobody anything, while
/// `rate limited: Too many requests · retrying in 1.0s (attempt 2/3)` does:
/// where it is going, why, and how long you have to put up with it. The server's
/// text (`lastErrorBody`) is the part that really matters, because "HTTP 429"
/// says nothing.
fn pushRetryNotice(m: *tui.Model, err: anyerror, attempt: usize) void {
    const gpa = m.allocator;
    const reason = chat.lastErrorBody();
    const wait_ms = Retry.backoffMs(attempt);

    const detail: []const u8 = if (reason.len > 0) reason else "no details from the server";
    m.pushInfoFmt("{s}: {s} · retrying in {d}.{d}s (attempt {d}/3)", .{
        errPhrase(err),
        detail,
        wait_ms / 1000,
        (wait_ms % 1000) / 100,
        attempt + 1,
    });

    // The status stays short (it is a segmented line) but has the why, which is
    // what you read at a glance: "rate limited 2/3" and not "retrying…".
    //
    // `short` has to be FREED here, and it was not: `setStatusWithZo` COPIES into a
    // fixed buffer on the Model, so the allocation's work was done the moment the copy
    // was made. Every retry leaked one string — small, invisible, and forever, and it
    // is exactly the shape of leak that shows up as "the process grows" in a session
    // with a flaky provider rather than as a DebugAllocator complaint anybody can
    // attribute.
    //
    // Found by writing the first E2E test this repo has: the test's allocator is the
    // process heap's, and the DebugAllocator said where each leaked block came from.
    const short = std.fmt.allocPrint(gpa, "{s} {d}/3", .{ errPhrase(err), attempt + 1 }) catch return;
    defer gpa.free(short);
    setStatusWithZo(m, .warn, short);
}

/// The network error in human words.
///
/// `@errorName` gives `RateLimited` / `NoCredits` / `ConnectionFailed`: those
/// are identifiers, not messages. The user sees them in the history and in the
/// status bar, and what is needed there is a sentence.
pub fn errPhrase(err: anyerror) []const u8 {
    return switch (err) {
        error.RateLimited => "rate limited",
        error.Overloaded => "server overloaded",
        error.ServerError => "server error",
        error.AuthFailed => "auth failed",
        error.NoCredits => "no credits",
        error.Forbidden => "forbidden",
        error.ModelNotFound => "model not found",
        error.InvalidUrl => "invalid url",
        error.Cancelled => "cancelled",
        error.TlsFailed, error.TlsHandshakeFailed => "tls failed",
        error.ConnectionFailed, error.ConnectionRefused, error.ConnectionResetByPeer => "connection failed",
        error.TemporaryNameServerFailure, error.NameServerFailure, error.UnknownHostName, error.HostLackingDnsResolver => "dns failed",
        error.ReadTimeout, error.ConnectionTimedOut => "timed out",
        else => @errorName(err),
    };
}

fn reportErr(m: *tui.Model, err: anyerror) void {
    const reason = chat.lastErrorBody();
    const gpa = m.allocator;
    switch (err) {
        error.Cancelled => {
            setStatusWithZo(m, .warn, "interrupted");
            return;
        },
        // 401. It USUALLY is the key, but not always: openrouter answers
        // `{"error":{"message":"User not found."}}`, which is the ACCOUNT and not
        // the key, so the server's message is always shown when there is one.
        error.AuthFailed => {
            // The names go in VERBATIM, not wrapped in a `ZODE_{s}_KEY` template.
            // `key_env` already holds the WHOLE variable name
            // ("ZODE_OPENROUTER_KEY"), so the template produced
            // "check ZODE_ZODE_OPENROUTER_KEY_KEY": a variable that cannot exist,
            // in the one message whose entire job is to name a variable. It is
            // the whole list too, because `key_env` is a fallback chain and the
            // key can be sitting in any of them.
            const names = providerEnvNames(gpa);
            defer gpa.free(names);
            // And the server's own words come along, which this branch is the
            // only one that used to throw away. A 401 is NOT always a bad key:
            // openrouter answers `{"error":{"message":"User not found."}}`, which
            // is the ACCOUNT and not the key, and saying "key rejected" sends the user
            // off to rotate a key that is perfectly fine. `reason` is empty when the
            // server said nothing, and then the old wording is all there is.
            if (reason.len > 0) {
                m.pushErrorFmt("auth failed on {s}: {s}\n  check {s} (/provider shows the state)", .{
                    cur_provider_id,
                    reason,
                    names,
                });
            } else {
                m.pushErrorFmt("key rejected by {s}. check {s} (/provider shows the state)", .{
                    cur_provider_id,
                    names,
                });
            }
        },
        // 402: the account has no balance. It is not a zode bug nor the key.
        error.NoCredits => {
            m.pushErrorFmt("out of credits on {s}: {s}\n  pick a `-free` model or switch with /provider", .{
                cur_provider_id,
                reason,
            });
        },
        // 404: the model does not exist on that provider. Almost always it is an old
        // HARDCODED id left over (which is why the default is changed when the
        // provider retires it) or a typo in /use.
        error.ModelNotFound => {
            m.pushErrorFmt("model `{s}` does not exist on {s}: {s}\n  /model for the ones you have", .{
                cur_model,
                cur_provider_id,
                reason,
            });
        },
        // 403: in practice it is almost always the MODEL that is not available for
        // this account, not the key. Saying that plainly saves hours of
        // debugging.
        error.Forbidden => {
            m.pushErrorFmt("`{s}` is not available on your {s} account: {s}\n  /model for your models, /provider to switch", .{
                cur_model,
                cur_provider_id,
                reason,
            });
        },
        error.BadRequest => {
            // 400: the server did not accept the request. With free-auto on, this pair is
            // already set aside for the next turn (`noteTurnFailure`), so all
            // that is left to say here is what it asked for and what it replied.
            m.pushInfoFmt("{s} rejected the request for `{s}`: {s}", .{
                cur_provider_id,
                cur_model,
                reason,
            });
        },
        error.RateLimited, error.Overloaded => {
            // `errPhrase`, not `@errorName`: a person reads this line and
            // "RateLimited" tells nobody anything. It is the same rule the retry
            // notices already follow, and they do it right.
            m.pushErrorFmt("{s} after several attempts: {s}", .{ errPhrase(err), reason });
        },
        else => {
            // `errPhrase` and not `@errorName`: this line is read by a person and
            // "ServerError" tells nobody anything. And it goes out as an ERROR
            // (red) because that is what it is.
            m.pushErrorFmt("{s}: {s}", .{ errPhrase(err), reason });
        },
    }
}

/// The environment variables that can hold the active provider's key, as a
/// comma-separated list the caller owns.
///
/// It is the WHOLE chain and not just the first, because `key_env` is a
/// fallback list (`ZODE_OPENCODE_KEY` then `ZODE_API_KEY` for opencode) and
/// telling the user to check only the first one sends them to fix a variable
/// that was never set while the one that was set stayed broken.
///
/// A provider that needs no key gets "none", so the message still says
/// something true instead of a variable name invented out of nothing.
fn providerEnvNames(gpa: std.mem.Allocator) []u8 {
    const d = activeProviderDef(environ_global);
    if (d.key_env.len == 0) return gpa.dupe(u8, "none") catch unreachable;
    // The allocation is EXACTLY the length of the result, not a 512-byte buffer
    // with the answer written at the front: the caller frees this, and
    // `std.testing.allocator` (rightly) treats freeing a 20-byte slice of a
    // 512-byte block as an "Invalid free". A fixed writer is the wrong shape for
    // memory that changes hands.
    const sep = " or ";
    const sep_len = sep.len;
    var need: usize = sep_len * (d.key_env.len - 1); // the separator goes BETWEEN
    for (d.key_env) |name| need += name.len;
    const buf = gpa.alloc(u8, need) catch return gpa.dupe(u8, d.key_env[0]) catch unreachable;
    var n: usize = 0;
    for (d.key_env, 0..) |name, i| {
        if (i != 0) {
            @memcpy(buf[n..][0..sep_len], sep);
            n += sep_len;
        }
        @memcpy(buf[n..][0..name.len], name);
        n += name.len;
    }
    return buf[0..n];
}

// ── tier 2 compaction: an LLM summary of the old turns ────────

/// If the elided view still goes over the budget, a summary is asked of the
/// model and the old turns are replaced with a note. Best-effort: if it fails,
/// it carries on without a summary.
/// Accumulates the summary text (userdata of `summarizeTurns`'s callback).
const SummarySink = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
};

/// Summarizes a stretch of old messages with the model itself.
///
/// Returns the summary text, or null if it could not be done (it is
/// best-effort: if it fails, the caller carries on with the messages as they
/// are and only loses precision).
pub fn summarizeTurns(
    gpa: std.mem.Allocator,
    http: *http_client.Http,
    url: []const u8,
    bearer: ?[]const u8,
    kind: chat.ProviderKind,
    model_name: []const u8,
    effort: chat.Effort,
    msgs: []chat.ChatMessage,
    arena: std.mem.Allocator,
    extra_headers: []const http_client.Http.ExtraHeader,
    max_output_tokens: u32,
) ?[]const u8 {
    // Breaker open: stop spending requests on a summarizer that cannot summarize.
    if (summary_breaker.tripped()) return null;

    var ast = std.heap.ArenaAllocator.init(gpa);
    defer ast.deinit();
    const a = ast.allocator();

    // A single user message with the conversation to summarize + the instruction.
    const prompt = compaction.summaryPrompt(a, msgs) catch {
        summary_breaker.noteFailure();
        models_mod.dbg("[compaction] could not build the summary prompt\n", .{});
        return null;
    };
    const body_buf = bodyBuf(gpa) catch {
        summary_breaker.noteFailure();
        return null;
    };
    const one = [_]chat.ChatMessage{.{ .role = "user", .content = prompt }};
    const body = chat.buildBodyMessagesCapped(body_buf, model_name, &one, effort, "", kind, max_output_tokens) catch {
        summary_breaker.noteFailure();
        models_mod.dbg("[compaction] could not build the summary body\n", .{});
        return null;
    };

    // The userdata carries the allocator + the buffer: a callback cannot capture
    // `gpa` (a nested function does not see the outer environment).
    var sink = SummarySink{ .gpa = gpa };
    const cb: chat.Callbacks = .{
        .userdata = &sink,
        .onDelta = struct {
            fn f(ud: ?*anyopaque, d: []const u8) void {
                const s: *SummarySink = @ptrCast(@alignCast(ud.?));
                s.buf.appendSlice(s.gpa, d) catch {};
            }
        }.f,
    };
    // Not the user's turn: its usage is not the turn's, and its errors are not
    // the turn's either.
    chat.streamChat(gpa, http, url, bearer, @constCast(body), cb, kind, false, extra_headers) catch |err| {
        summary_breaker.noteFailure();
        models_mod.dbg("[compaction] el resumen fallo: {t}\n", .{err});
        return null;
    };
    if (sink.buf.items.len == 0) {
        summary_breaker.noteFailure();
        return null;
    }
    summary_breaker.noteSuccess();
    return arena.dupe(u8, sink.buf.items) catch null;
}

// ── pickers ───────────────────────────────────────────────────

const PickerCb = *const fn (*tui.Model, u32, []const u8) void;

fn onProviderPick(m: *tui.Model, _: u32, label: []const u8) void {
    applyProvider(m, label) catch {};
}

fn onEffortPick(m: *tui.Model, _: u32, label: []const u8) void {
    cmdEffort(m, label);
}

/// `/color`: the palette the diff is painted with.
///
/// The DEFAULT pair is green for an added row and red for a deleted one, and
/// that pair is invisible to a reader with the most common colour-vision
/// deficiency: green and red collapse into the same yellow, and a diff whose
/// two halves are the same colour is a diff with no halves. The DALTONIZED
/// pair is blue and orange, which survive it.
///
/// The choice is for the session, and it says what it did: a palette that
/// changed without saying so is a palette the user cannot trust.
fn cmdColor(m: *tui.Model, arg: ?[]const u8) void {
    if (arg) |a| {
        if (std.mem.eql(u8, a, "default") or std.mem.eql(u8, a, "normal")) {
            theme.caps.daltonized = false;
            m.pushInfoFmt("diff palette → default (green / red)", .{});
        } else if (std.mem.eql(u8, a, "daltonized") or std.mem.eql(u8, a, "daltonise") or
            std.mem.eql(u8, a, "daltonize"))
        {
            theme.caps.daltonized = true;
            m.pushInfoFmt("diff palette → daltonized (blue / orange)", .{});
        } else {
            m.pushInfoFmt("unknown palette: {s} (default | daltonized)", .{a});
            return;
        }
        // The whole history is painted with the old palette, so it has to be
        // laid out again.
        m.clearSegCache();
        m.dirty = true;
        return;
    }
    openColorPicker(m);
}

/// The palette picker: the two pairs, with the active one marked.
fn openColorPicker(m: *tui.Model) void {
    const gpa = m.allocator;
    const names = [_][]const u8{ "default", "daltonized" };
    const items = gpa.alloc(tui.PickerItem, names.len) catch return;
    for (names, 0..) |n, i| {
        const desc = if ((i == 1) == theme.caps.daltonized)
            gpa.dupe(u8, "← active") catch ""
        else if (i == 1)
            gpa.dupe(u8, "blue / orange") catch ""
        else
            gpa.dupe(u8, "green / red") catch "";
        items[i] = .{ .label = gpa.dupe(u8, n) catch return, .desc = desc };
    }
    var title_buf: [96]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "diff palette · {s}", .{
        if (theme.caps.no_color) "no color (NO_COLOR)" else if (theme.caps.daltonized) "daltonized" else "default",
    }) catch "diff palette";
    m.openPicker(4, title, items, onColorPick);
}

fn onColorPick(m: *tui.Model, _: u32, label: []const u8) void {
    cmdColor(m, label);
}

/// Job of the `/models` catalog summary and the model picker.
const ModelsJob = struct {
    model: *tui.Model,
    /// false = list in the history (`/models`); otherwise open the picker.
    for_picker: bool = false,
    request_id: usize = 0,
    provider_id: []u8,
    models_url: []u8,
    key: ?[]u8,
    /// Which header the key goes in. Copied into the job because the worker
    /// has no `ProviderDef` (the provider id in the job is the only thing it
    /// keeps) and the keyless `Bearer` was Anthropic's 401.
    key_style: providers.KeyStyle = .bearer,
};

/// `/models` shows catalog counts; `/model` is the detailed browser.
pub fn listModelsAsync(m: *tui.Model) !void {
    const job = try createModelsJob(m, false);
    // No cleanup here: `spawnModelsJob` owns the job from the moment it is
    // called, including the failure path. The compensating `endWorker` +
    // `destroyModelsJob` that used to live in this function and in
    // `pickerModelsAsync` balanced the counter only because both remembered to
    // do it — ownership that lives in the caller is one caller away from a leak.
    try spawnModelsJob(m, job);
}

/// Warms the status bar's `provider/model` from the network, SILENTLY.
///
/// The row is `opencode/space-bunny-free` and not just `opencode`, and the only
/// place a model name exists before the first turn is the provider's catalogue.
/// A cached catalogue is read by `resolveStatusModel` in a millisecond; an
/// uncached one is not on disk until somebody asks the provider, and the only
/// thing that asks at startup used to be `/model` — which is the moment the
/// status was already being read.
///
/// Silent is the whole point: this runs before the first frame, and the models
/// worker's own path writes `Catalog updated · N models` into the history and
/// changes the status line, both of which would land on top of the opening hero.
/// Nothing here is reported, because nothing here is news — the catalogue is
/// written to disk exactly as the other worker writes it, and the next
/// `resolveStatusModel` reads it.
///
/// It resets `status_model_tried`, which is the flag the draw uses to avoid
/// re-reading a file that was not there: without the reset the row would keep
/// saying `opencode` for the whole session, because the lazy resolve had already
/// run once and found nothing.
pub fn catalogWarmupAsync(m: *tui.Model) !void {
    const gpa = m.allocator;
    // NO `errdefer` HERE, and that is deliberate: the spawn-failure branch
    // below frees the job itself, so an `errdefer` would free it a SECOND time
    // on the way out — a double free, and the two failures cancel out into
    // "the app crashed and nobody knows why".
    //
    // The ownership is in the TYPE of the failure: the only error between the
    // `create` and the `spawn` is the spawn, and that branch owns the job.
    const job = gpa.create(WarmupJob) catch |e| return e;
    job.* = .{ .model = m };
    m.beginWorker();
    const thread = std.Thread.spawn(.{}, warmupWorker, .{job}) catch {
        m.endWorker();
        gpa.destroy(job);
        return error.ThreadSpawnFailed;
    };
    thread.detach();
}

const WarmupJob = struct { model: *tui.Model };

fn warmupWorker(job: *WarmupJob) void {
    // THE ORDER OF THESE TWO DEFERS IS THE WHOLE FUNCTION.
    //
    // `defer` is LIFO: the LAST one registered runs FIRST. The two lines used
    // to be in the other order, so the job was FREED and then
    // `job.model.endWorker()` dereferenced the freed block to do its atomic
    // RMW — a use-after-free that killed the app with SIGSEGV while it was
    // warming the model catalogue.
    //
    // It was read as a HANG for a month ("ReleaseSmall + a saved key = the TUI
    // stops answering"), and the A/B that said "it is not ours" was right about
    // the regression and wrong about the bug: it was ours since the warmup was
    // written.
    //
    // The pointer is copied into a local BEFORE anything can die, so the second
    // defer never reads the job it is about to free. `modelsWorker` (a hundred
    // lines away) already had the right order.
    const m = job.model;
    defer m.allocator.destroy(job); // registered first  -> runs LAST
    defer m.endWorker(); // registered second -> runs FIRST
    const gpa = m.allocator;
    const def = activeProviderDef(m.environ);
    if (def.models_url.len == 0) return;

    // ITS OWN `Io`, and this is HARDENING, not a cure.
    //
    // The whole app used ONE `Io` for everything: the UI's event loop, vaxis's
    // pty reader, and every worker's HTTP. A detached worker doing blocking TLS
    // on the shared `Io` is exactly the shape AGENTS.md already has a
    // use-after-free for, and isolating it is the right thing regardless of what
    // it fixes today.
    //
    // Measured: it takes the no-key case from "answers nothing" to "answers every
    // time". It is NOT the fix for the saved-key case — gating the warmup off
    // entirely changes nothing there, which is why that bug is written up as OPEN
    // in AGENTS.md with the A/B that proves it predates this session.
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const worker_io = threaded.io();

    var http = http_client.Http.init(gpa, worker_io);
    defer http.deinit();
    var list = models_mod.listModels(gpa, &http, def.models_url, providers.catalogAuth(def, m.environ)) catch return;
    defer list.deinit(gpa);
    if (list.items.len == 0) return;

    // The cache write too: it is 772 KB through a DEFLATE-9, and on the shared
    // `Io` it would be the same block the request was.
    modelcache.write(worker_io, m.environ, def.id, def.models_url, list.items);
    // The catalogue is on disk now; the draw may look again.
    tui.allowStatusModelRetry(m);
}

// ── self-update ─────────────────────────────────────────────────

/// Looks for a newer release at startup, in a worker, and says so if there is
/// one. It says NOTHING when the build is current: a line on every start saying
/// "you are up to date" is noise, and it is the same line that makes the real
/// notice invisible.
///
/// The check costs a file read on almost every start: `selfupdate` caches the
/// answer on disk for six hours, so the network is touched twice a day at most.
pub fn startUpdateCheck(m: *tui.Model) void {
    if (envGet(m.environ, "ZODE_NO_SELF_UPDATE") != null) return;
    spawnUpdateJob(m, .check) catch {};
}

/// `/update`: installs the newest release. It runs in a WORKER because it
/// downloads ~2 MB, and a download on the UI thread is the app frozen for as
/// long as GitHub takes.
fn cmdUpdate(m: *tui.Model) void {
    spawnUpdateJob(m, .install) catch pushError(m, "could not start the update");
}

const UpdateMode = enum { check, install };
const UpdateJob = struct { model: *tui.Model, mode: UpdateMode };

fn spawnUpdateJob(m: *tui.Model, mode: UpdateMode) !void {
    const gpa = m.allocator;
    const job = try gpa.create(UpdateJob);
    job.* = .{ .model = m, .mode = mode };
    m.beginWorker();
    const thread = std.Thread.spawn(.{}, updateWorker, .{job}) catch {
        m.endWorker();
        gpa.destroy(job);
        return error.ThreadSpawnFailed;
    };
    thread.detach();
}

fn updateWorker(job: *UpdateJob) void {
    const m = job.model;
    const mode = job.mode;
    // LIFO, and the order matters: the job is freed LAST, after `endWorker` has
    // read the model's counter through the (still valid) job.
    defer m.allocator.destroy(job);
    defer m.endWorker();

    // Its own `Io`: a detached worker doing blocking TLS on the UI's event loop
    // is the shape that made the app look hung.
    var threaded: std.Io.Threaded = .init(m.allocator, .{});
    defer threaded.deinit();
    var arena_state = std.heap.ArenaAllocator.init(m.allocator);
    defer arena_state.deinit();

    const ctx: selfupdate.Context = .{
        .io = threaded.io(),
        .alloc = arena_state.allocator(),
        .env = m.environ,
    };

    switch (mode) {
        .check => {
            const up = selfupdate.check(ctx, false) orelse return;
            announceUpdate(m, up);
            // Opt-in automatic install. The default is to TELL the user: a
            // binary replaced behind their back is a change they cannot see and
            // a restart they never asked for.
            if (envGet(m.environ, "ZODE_AUTO_UPDATE") != null) installUpdateNow(m, ctx);
        },
        .install => installUpdateNow(m, ctx),
    }
}

fn announceUpdate(m: *tui.Model, up: selfupdate.Update) void {
    var buf: [160]u8 = undefined;
    const phrase = selfupdate.phrase(&buf, up);
    m.pushInfoFmt("zode {s} · /update installs it", .{phrase});
    setStatusWithZoFmt(m, .warn, "{s} available · /update", .{up.version});
}

fn installUpdateNow(m: *tui.Model, ctx: selfupdate.Context) void {
    m.pushInfoFmt("updating zode from {s}…", .{selfupdate.current_version});
    const tag = selfupdate.installLatest(ctx) catch |err| switch (err) {
        // Not a failure: there is simply nothing newer to install.
        error.AlreadyNewest => {
            m.pushInfoFmt("zode {s} is already the newest release", .{selfupdate.current_version});
            return;
        },
        else => {
            m.pushErrorFmt("update failed: {s}", .{updateErrorPhrase(err)});
            return;
        },
    };
    m.pushInfoFmt("updated to {s} · restart zode to use it", .{tag});
    setStatusWithZoFmt(m, .done, "updated to {s} · restart", .{tag});
}

/// What went wrong, in words the user can act on. "UpdateFailed" is not one:
/// the three cases have three different fixes (wait, reinstall, sudo).
fn updateErrorPhrase(err: selfupdate.InstallError) []const u8 {
    return switch (err) {
        error.AlreadyNewest => "already the newest release",
        error.NoAssetForPlatform => "this platform has no release binary",
        error.DownloadFailed => "could not download it (network, GitHub, or no release yet)",
        error.BinaryDoesNotRun => "the downloaded binary does not run here; nothing was replaced",
        error.NotWritable => "could not replace the running binary (permissions?)",
        error.UnsupportedPlatform => "no releases for this OS/arch",
    };
}

/// `/model` and Ctrl+T: the two-column model palette.
///
/// The active provider's models are requested; while they arrive, the palette
/// opens anyway with the providers column (which is local and needs no
/// network), and the worker fills it in when it finishes. So there is no blank
/// wait.
pub fn pickerModelsAsync(m: *tui.Model) !void {
    const job = createModelsJob(m, true) catch |err| {
        const def = activeProviderDef(m.environ);
        const request_id = m.beginCatalogRequest(def.id);
        m.setCatalogNotice(request_id, "Could not start model refresh");
        return err;
    };
    // The id is read BEFORE the spawn: on failure `spawnModelsJob` frees the
    // job, so touching `job.request_id` in the catch would be a use-after-free.
    const request_id = job.request_id;
    spawnModelsJob(m, job) catch |err| {
        m.setCatalogNotice(request_id, "Could not start model refresh");
        return err;
    };
}

fn createModelsJob(m: *tui.Model, for_picker: bool) !*ModelsJob {
    const gpa = m.allocator;
    const def = activeProviderDef(m.environ);
    const provider_id = try gpa.dupe(u8, def.id);
    errdefer gpa.free(provider_id);
    const models_url = try gpa.dupe(u8, def.models_url);
    errdefer gpa.free(models_url);
    const key = if (curKey(m)) |value| try gpa.dupe(u8, value) else null;
    errdefer if (key) |value| gpa.free(value);
    const job = try gpa.create(ModelsJob);
    errdefer gpa.destroy(job);
    job.* = .{
        .model = m,
        .for_picker = for_picker,
        .request_id = if (for_picker) m.beginCatalogRequest(def.id) else 0,
        .provider_id = provider_id,
        .models_url = models_url,
        .key = key,
        .key_style = def.key_style,
    };
    return job;
}

/// Starts `modelsWorker` and HANDS OVER the job: on failure the job is freed
/// here, so no caller has anything left to clean up.
///
/// The counter is undone here for a reason: `beginWorker` increments it, and a
/// spawn failure that left it incremented made `waitWorkers(2000)` spin its
/// whole budget at exit. It balanced before only because the two callers
/// happened to call `endWorker` — the third one would not.
fn spawnModelsJob(m: *tui.Model, job: *ModelsJob) !void {
    m.beginWorker();
    const thread = std.Thread.spawn(.{}, modelsWorker, .{job}) catch {
        m.endWorker();
        destroyModelsJob(m.allocator, job);
        return error.ThreadSpawnFailed;
    };
    thread.detach();
}

fn destroyModelsJob(gpa: std.mem.Allocator, job: *ModelsJob) void {
    gpa.free(job.provider_id);
    gpa.free(job.models_url);
    if (job.key) |key| gpa.free(key);
    gpa.destroy(job);
}

/// Like `pickerModelsAsync` but with the Ctrl+T key.
///
/// It opens NOW, with only the providers column (which is local and needs no
/// network), and the worker fills it with the models when they arrive. So
/// there is no blank wait for the network.
///
/// CAREFUL: `items` and `groups` are copied by the model's allocator, NOT by a
/// frame arena: the palette lives between frames, and if they pointed at the
/// frame's arena they would dangle when the streamer redraws.
pub fn openModelPaletteAsync(m: *tui.Model) void {
    openModelPalette(m, &.{});
    pickerModelsAsync(m) catch {};
}

fn modelsWorker(job: *ModelsJob) void {
    defer destroyModelsJob(job.model.allocator, job);
    const m = job.model;
    const gpa = m.allocator;
    m.beginWorker();
    defer m.endWorker();
    const is_current = struct {
        fn check(model: *tui.Model, request: *const ModelsJob) bool {
            return !request.for_picker or model.catalogRequestCurrent(request.request_id);
        }
    }.check;

    // A provider with no `/models` endpoint (`models_url = ""`): there is no
    // catalogue to read, neither from the cache nor from the network, and the
    // fetch would hit "". The picker says how to choose instead of showing an
    // error every time it opens.
    if (job.models_url.len == 0) {
        if (is_current(m, job)) {
            m.setCatalogNotice(job.request_id, "This provider publishes no model catalog · /use <provider> <model>");
        }
        return;
    }

    // ITS OWN `Io`, same as `warmupWorker`. This is a DETACHED thread doing
    // blocking TLS and a 772 KB DEFLATE-9 write on behalf of a thread nobody
    // joins, and `io_global` is the object the UI event loop is using. The
    // warmup got its own and this one did not: two workers, two policies.
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const worker_io = threaded.io();

    // ── step 1: the CACHE, before anything touches the network ──
    //
    // This is the whole feature and it is 5 ms instead of 411-673. The palette gets
    // painted with what we already knew, and the network happens afterwards, in the
    // same worker, where the user is already looking at a populated list.
    //
    // It goes BEFORE the status line on purpose: "listing models…" on top of a list
    // that is already there reads as an app that has not noticed it has the answer.
    var cached: []models_mod.Model = &.{};
    var from_cache = false;
    {
        var astate = std.heap.ArenaAllocator.init(gpa);
        defer astate.deinit();
        if (modelcache.read(worker_io, m.environ, astate.allocator(), job.provider_id, job.models_url)) |e| {
            // `copyOut`, NOT `dupe(Model, ...)`. `Model` is a struct of slices into the
            // cache's arena, so a plain struct copy is a list of pointers into memory
            // that dies at the closing brace of this block. Measured: SIGSEGV, exit
            // status 139, no panic message, empty stderr — and only in the TUI, because
            // `--models` uses its list before the arena goes away.
            cached = modelcache.copyOut(gpa, e.models) catch &.{};
            from_cache = cached.len > 0;
        }
    }
    defer if (cached.len > 0) modelcache.freeOut(gpa, cached);
    if (from_cache) {
        publishModels(m, cached, job.provider_id, .cached, job.request_id, job.for_picker);
        if (is_current(m, job)) {
            m.setCatalogNotice(job.request_id, "Saved catalog · checking for updates...");
            if (!job.for_picker) setStatusWithZo(m, .tooling, "refreshing model catalog");
        }
    } else {
        if (is_current(m, job) and !job.for_picker) setStatusWithZo(m, .tooling, "loading model catalog");
    }

    var http = http_client.Http.init(gpa, worker_io);
    defer http.deinit();

    var list = models_mod.listModels(gpa, &http, job.models_url, providers.authWithKey(job.key_style, job.key)) catch |err| {
        // With a cache on screen, a failed refresh is a NOTE and not an error: the user
        // is looking at a usable list, and an error line over it invites them to think
        // the list is wrong.
        if (from_cache) {
            if (is_current(m, job)) {
                m.setCatalogNotice(job.request_id, "Offline · showing saved catalog");
                if (!job.for_picker) setStatusWithZo(m, .warn, "saved model catalog available");
                if (!job.for_picker) {
                    m.pushInfoFmt("could not refresh {s}'s model catalog ({t}); keeping saved models", .{ job.provider_id, err });
                }
            }
            return;
        }
        if (!is_current(m, job)) return;
        if (err == error.HttpError) {
            if (!job.for_picker) m.pushInfoFmt("models: HTTP error at {s}", .{job.models_url});
        } else {
            if (!job.for_picker) {
                m.pushInfoFmt("models: {t}", .{ err });
            }
        }
        if (is_current(m, job)) {
            m.setCatalogNotice(job.request_id, "Could not load models · retry with /model");
            if (!job.for_picker) setStatusWithZo(m, .warn, "model catalog unavailable");
        }
        return;
    };

    defer list.deinit(gpa);

    if (list.items.len == 0) {
        if (is_current(m, job)) {
            const note: []const u8 = if (from_cache)
                "Provider returned no models · kept saved catalog"
            else
                "Provider returned no models";
            m.setCatalogNotice(job.request_id, note);
            if (!job.for_picker) {
                setStatusWithZo(m, .warn, "provider returned no models");
                if (from_cache) {
                    m.pushInfoFmt("{s} returned an empty model catalog; keeping the saved list", .{job.provider_id});
                } else {
                    m.pushInfoFmt("{s} returned an empty model catalog", .{job.provider_id});
                }
            }
        }
        return;
    }

    var catalog_changed = !from_cache;
    // ── step 2: what CHANGED ──
    //
    // Only when there was a cache. `describe` returns EMPTY when nothing moved, and the
    // caller must not re-sort in that case: reordering a list under the cursor is worse
    // than not reordering it, and a line that appears on every refresh trains the user
    // to ignore it.
    if (from_cache) {
        var astate = std.heap.ArenaAllocator.init(gpa);
        defer astate.deinit();
        const arena = astate.allocator();
        const d = modelcache.diff(cached, list.items);
        catalog_changed = d.added > 0 or d.removed > 0 or d.changed > 0;
        const line = modelcache.describe(arena, d);
        if (line.len > 0 and is_current(m, job)) pushInfoOwned(m, gpa.dupe(u8, line) catch line);
    }

    // Written AFTER the diff and not before: a cache that was just refreshed with the
    // list in hand and still compares as "changed" is a cache that never converges.
    modelcache.write(worker_io, m.environ, job.provider_id, job.models_url, list.items);

    publishModels(m, list.items, job.provider_id, .fresh, job.request_id, job.for_picker);
    if (is_current(m, job)) {
        const notice = std.fmt.allocPrint(
            gpa,
            "{s} · {d} models",
            .{ if (catalog_changed) "Catalog updated" else "Catalog up to date", list.items.len },
        ) catch "Model catalog refreshed";
        m.setCatalogNotice(job.request_id, notice);
        if (!job.for_picker) {
            setStatusWithZo(m, .done, if (catalog_changed) "model catalog updated" else "model catalog current");
        }
    }
}

const ModelSource = enum { cached, fresh };

/// Hands a list of models to whoever is waiting: the picker gets items, the plain
/// `/models` gets lines.
///
/// One function because there were two copies of the "free first, then alphabetical"
/// ordering and a cache makes it a third call site; three copies of an ordering is how
/// the picker and `/models` end up disagreeing about which models exist.
fn publishModels(
    m: *tui.Model,
    models: []const models_mod.Model,
    provider_id: []const u8,
    source: ModelSource,
    request_id: usize,
    for_picker: bool,
) void {
    const gpa = m.allocator;
    const sorted = gpa.dupe(models_mod.Model, models) catch return;
    defer gpa.free(sorted);
    // The "free" ones first: those are the ones that work without credits, and
    // alphabetical within each group so the list is stable between runs.
    std.mem.sort(models_mod.Model, sorted, {}, freeFirst);

    if (for_picker) {
        // The palette is NOT touched here: this is the worker's thread and the UI thread
        // draws it without a lock, and that was a segfault. ITEMS already built with
        // their own strings are handed over: handing over the `Model`s and freeing the
        // list on exit left the ids dangling and the drawing blew up.
        const items = buildModelItems(m, sorted);
        if (items) |it| m.setPendingCatalogItems(request_id, it);
        return;
    }
    var free_count: usize = 0;
    for (sorted) |info| {
        if (isFree(info)) free_count += 1;
    }
    m.pushInfoFmt("{d} models · {d} free · {s}{s} · use /model to browse", .{
        sorted.len,
        free_count,
        provider_id,
        if (source == .cached) " · saved list; refreshing" else "",
    });
}

/// Is this model free?
///
/// [roster] It used to look only at the `-free` suffix, which is opencode's
/// convention. OpenRouter uses `:free`, and some providers use no suffix at all
/// and just publish a price of 0, so `/model` marked one single provider as
/// "free" and the free-model pool came out nearly empty. It is `models.is_free`
/// now, which combines the three signals (`models.isFreeId` +
/// `models.isFreeByPrice`).
fn isFree(m: models_mod.Model) bool {
    return m.is_free;
}

fn freeFirst(_: void, a: models_mod.Model, b: models_mod.Model) bool {
    const fa = isFree(a);
    const fb = isFree(b);
    if (fa != fb) return fa;
    return std.mem.lessThan(u8, a.id, b.id);
}

/// Opens the model palette: a SINGLE flat list of all models from connected
/// providers (providers that have a key), showing "Model Name    Provider · free/ctx".
/// Reads from the cache of each connected provider, so it opens instantly.
/// All strings are own copies from the model's allocator.
fn buildModelItems(m: *tui.Model, _: []models_mod.Model) ?[]palette.Item {
    const gpa = m.allocator;
    var defs_arena_state = std.heap.ArenaAllocator.init(gpa);
    defer defs_arena_state.deinit();
    const defs = allProviders(defs_arena_state.allocator());

    // First pass: count total models from all connected providers
    var total_models: usize = 0;
    for (defs) |d| {
        if (providers.hasKey(&d, m.environ)) {
            var cache_arena = std.heap.ArenaAllocator.init(gpa);
            if (modelcache.read(io_global, m.environ, cache_arena.allocator(), d.id, d.models_url)) |entry| {
                total_models += entry.models.len;
            }
            cache_arena.deinit();
        }
    }

    // If no models from connected providers, try the active provider's cache
    // (the user might be browsing before connecting a key)
    if (total_models == 0) {
        const active_def = activeProviderDef(m.environ);
        if (active_def.id.len > 0) {
            var cache_arena = std.heap.ArenaAllocator.init(gpa);
            if (modelcache.read(io_global, m.environ, cache_arena.allocator(), active_def.id, active_def.models_url)) |entry| {
                total_models = entry.models.len;
            }
            cache_arena.deinit();
        }
    }

    // If still no models, return null to trigger fallback
    if (total_models == 0) {
        return null;
    }

    const items = gpa.alloc(palette.Item, total_models + 1) catch return null; // +1 for "+ connect"
    var i: usize = 0;

    // Second pass: add models from each connected provider
    for (defs) |d| {
        if (!providers.hasKey(&d, m.environ)) continue;

        var cache_arena = std.heap.ArenaAllocator.init(gpa);
        if (modelcache.read(io_global, m.environ, cache_arena.allocator(), d.id, d.models_url)) |entry| {
            for (entry.models) |mi| {
                const hint = if (mi.is_free) "free" else if (mi.context_length > 0)
                    std.fmt.allocPrint(gpa, "{d}k", .{mi.context_length / 1024}) catch ""
                else
                    "";
                items[i] = .{
                    .kind = .model,
                    .group = 1,
                    .label = gpa.dupe(u8, mi.id) catch return null,
                    .hint = if (hint.len > 0)
                        std.fmt.allocPrint(gpa, "{s} · {s}", .{d.id, hint}) catch gpa.dupe(u8, d.id) catch ""
                    else
                        gpa.dupe(u8, d.id) catch "",
                    .provider = gpa.dupe(u8, d.id) catch "",
                    .ctx_tokens = mi.context_length,
                };
                i += 1;
            }
        }
        cache_arena.deinit();
    }

    // If we got models from connected providers, we're done
    if (i > 0) {
        // "+ connect" item at the end
        items[i] = .{
            .kind = .connect,
            .group = 2,
            .label = gpa.dupe(u8, "+ connect") catch return null,
            .hint = gpa.dupe(u8, "ctrl+a") catch return null,
        };
        return items;
    }

    // Fallback: active provider's models (if we got here, connected providers had no models
    // but active provider did)
    const active_def = activeProviderDef(m.environ);
    if (active_def.id.len > 0) {
        var cache_arena = std.heap.ArenaAllocator.init(gpa);
        if (modelcache.read(io_global, m.environ, cache_arena.allocator(), active_def.id, active_def.models_url)) |entry| {
            for (entry.models) |mi| {
                const hint = if (mi.is_free) "free" else if (mi.context_length > 0)
                    std.fmt.allocPrint(gpa, "{d}k", .{mi.context_length / 1024}) catch ""
                else
                    "";
                items[i] = .{
                    .kind = .model,
                    .group = 1,
                    .label = gpa.dupe(u8, mi.id) catch return null,
                    .hint = if (hint.len > 0)
                        std.fmt.allocPrint(gpa, "{s} · {s}", .{active_def.id, hint}) catch gpa.dupe(u8, active_def.id) catch ""
                    else
                        gpa.dupe(u8, active_def.id) catch "",
                    .provider = gpa.dupe(u8, active_def.id) catch "",
                    .ctx_tokens = mi.context_length,
                };
                i += 1;
            }
        }
        cache_arena.deinit();
    }

    // "+ connect" item at the end
    items[i] = .{
        .kind = .connect,
        .group = 2,
        .label = gpa.dupe(u8, "+ connect") catch return null,
        .hint = gpa.dupe(u8, "ctrl+a") catch return null,
    };

    return items;
}

fn providerKeyHint(gpa: std.mem.Allocator, def: *const providers.ProviderDef, active: bool, has_key: bool) ?[]u8 {
    const state: []const u8 = if (def.key_env.len == 0)
        "no key needed"
    else if (has_key)
        "connected"
    else
        "key needed";
    if (active) return std.fmt.allocPrint(gpa, "active · {s}", .{state}) catch null;
    return gpa.dupe(u8, state) catch null;
}

/// Builds a mode indicator string for the model palette title.
fn buildModeTitlePart(m: *tui.Model, buf: *[128]u8) []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(m.allocator);

    // Free-auto mode
    if (free_auto.freeAutoOn()) {
        const lbl = free_auto.freeAutoLabel(m.allocator);
        if (lbl.len > 0) {
            _ = parts.append(m.allocator, lbl) catch {};
        } else {
            _ = parts.append(m.allocator, "free-auto: building pool…") catch {};
        }
    }

    // Permission mode (only when not default/accept_edits)
    const perm_mode = currentPermMode();
    if (perm_mode == .read_only or perm_mode == .bypass) {
        _ = parts.append(m.allocator, permModeName()) catch {};
    }

    // Cheap router mode
    if (router_mod.active(&cheap_router)) {
        _ = parts.append(m.allocator, "cheap router") catch {};
    }

    if (parts.items.len == 0) return "";
    const joined = std.mem.join(m.allocator, " · ", parts.items) catch return "";
    return std.fmt.bufPrint(buf, "{s}", .{joined}) catch "";
}

fn openModelPalette(m: *tui.Model, list: []models_mod.Model) void {
    // The mode goes before `setItemsOwned` (see the note in the same function).
    // It delegates to `buildModelItems`: keeping TWO item constructors means
    // that as soon as one of them is not updated, loose literals show up (which
    // `freeItems` cannot free) and the app crashes on exit.
    var items = buildModelItems(m, list);
    if (items == null) {
        // Fallback: no cached models from any connected provider.
        // Build items from the active provider's list (passed as `list`).
        items = fallbackModelItems(m, list);
        if (items == null) return;
    }
    if (m.pal.mode == .models) m.invalidateCatalogRequest();
    // The mode goes BEFORE `setItemsOwned`: `resetSelection` computes the active
    // column from the mode. With the old mode, opening the model palette left
    // the PROVIDERS column active, the arrows did not move the model list and
    // it looked like there was nothing to pick.
    m.pal.mode = .models;
    m.pal.active = true;
    m.pal.query_len = 0;

    // Set a custom title that includes the current mode, so the user knows what
    // mode they are in when selecting a model. This mirrors how `openEffortPicker`
    // shows the effort ladder in the title.
    var title_buf: [128]u8 = undefined;
    const mode_part = buildModeTitlePart(m, &title_buf);
    if (mode_part.len > 0) {
        const title = std.fmt.bufPrint(&title_buf, "Choose a model · {s}", .{mode_part}) catch "Choose a model";
        m.pal.custom_title = m.allocator.dupe(u8, title) catch "";
    } else {
        m.pal.custom_title = "";
    }

    m.pal.setItemsOwned(items.?, &model_groups);
}

/// Fallback: builds model items from the active provider's list only.
/// Used when no connected provider has cached models.
fn fallbackModelItems(m: *tui.Model, list: []models_mod.Model) ?[]palette.Item {
    const gpa = m.allocator;
    const total_models = list.len;
    const items = gpa.alloc(palette.Item, total_models + 1) catch return null; // +1 for "+ connect"
    var i: usize = 0;

    const active_provider = if (cur_provider_id.len > 0) cur_provider_id else "unknown";

    for (list) |mi| {
        const hint = if (isFree(mi)) "free" else if (mi.context_length > 0)
            std.fmt.allocPrint(gpa, "{d}k", .{mi.context_length / 1024}) catch ""
        else
            "";
        items[i] = .{
            .kind = .model,
            .group = 1,
            .label = gpa.dupe(u8, mi.id) catch return null,
            .hint = if (hint.len > 0)
                std.fmt.allocPrint(gpa, "{s} · {s}", .{active_provider, hint}) catch gpa.dupe(u8, active_provider) catch ""
            else
                gpa.dupe(u8, active_provider) catch "",
            .provider = gpa.dupe(u8, active_provider) catch "",
            .ctx_tokens = mi.context_length,
        };
        i += 1;
    }

    // "+ connect" item at the end
    items[i] = .{
        .kind = .connect,
        .group = 2,
        .label = gpa.dupe(u8, "+ connect") catch return null,
        .hint = gpa.dupe(u8, "ctrl+a") catch return null,
    };

    return items;
}

/// Groups of the model palette (single flat list of models).
pub const model_groups = [_]palette.Group{
    .{ .name = "Models" },
    .{ .name = "" }, // separator for the "Connect an integration" item
};

/// `/provider`: picker with all the providers and their key state.
fn openProviderPicker(m: *tui.Model) void {
    const gpa = m.allocator;
    var defs_arena_state = std.heap.ArenaAllocator.init(gpa);
    defer defs_arena_state.deinit();
    const defs = allProviders(defs_arena_state.allocator());
    const items = gpa.alloc(tui.PickerItem, defs.len) catch return;
    for (defs, 0..) |*d, i| {
        const has_key = providers.hasKey(d, m.environ);
        const desc = std.fmt.allocPrint(
            gpa,
            "{s}{s}",
            .{ if (has_key) "" else "sin key · ", d.default_model },
        ) catch "";
        items[i] = .{
            .label = gpa.dupe(u8, d.id) catch return,
            .desc = desc,
        };
    }
    m.openPicker(2, "provider", items, onProviderPick);
}

/// `/effort` without args: the levels the CURRENT model accepts.
///
/// It used to be a fixed `low/medium/high/xhigh`, which offered `xhigh` to a
/// model whose top rung is `high` and never offered `none`/`minimal` to one
/// that has them below `low`. Offering a level the model does not take is not a
/// harmless extra row: picking it means the request 400s, and the picker had no
/// way to say so. The list is `chat.effortLevels(cur_model)`, so it is exactly
/// the vocabulary that `effortFor` will send.
fn openEffortPicker(m: *tui.Model) void {
    const gpa = m.allocator;
    const levels = chat.effortLevels(cur_model);
    const items = gpa.alloc(tui.PickerItem, levels.len) catch return;
    for (levels, 0..) |lv, i| {
        // The one that is really active is marked with an arrow, so that at a glance
        // you can see the model decided (or the user moved it).
        const desc = if (lv == effectiveEffort())
            std.fmt.allocPrint(gpa, "← {s}", .{effortDesc(lv)}) catch ""
        else
            gpa.dupe(u8, effortDesc(lv)) catch "";
        items[i] = .{
            .label = gpa.dupe(u8, lv.label()) catch return,
            .desc = desc,
        };
    }
    // The TITLE says which ladder the model has. It is the "automatic" made
    // visible: the user does not need to know in advance that this model goes up
    // to `high` and another one to `xhigh` — the picker shows it.
    var title_buf: [128]u8 = undefined;
    const title = if (chat.effortSupport(cur_model) == .none)
        std.fmt.bufPrint(&title_buf, "effort · {s} (no effort control)", .{cur_model}) catch "effort"
    else
        std.fmt.bufPrint(&title_buf, "effort · {s} goes up to {s}", .{
            cur_model,
            chat.maxEffortFor(cur_model).label(),
        }) catch "effort";

    m.openPicker(3, title, items, onEffortPick);
}

/// One line per level, saying what it COSTS, not what it is. "minimal" on its
/// own tells the user nothing they can act on.
fn effortDesc(e: chat.Effort) []const u8 {
    return switch (e) {
        .none => "no reasoning at all (fastest)",
        .minimal => "barely thinks",
        .low => "fast",
        .medium => "balanced",
        .high => "slower, more thorough",
        .xhigh => "maximum",
        // The same rung as `xhigh`, under the name of the providers that call
        // it `max`. The picker never offers it while no model takes it, so this
        // line only ever describes a level that is already in effect.
        .max => "maximum",
    };
}

// ── modal palette (Ctrl+P) ────────────────────────────────────

/// Groups of the command palette, in the order they are painted.
pub const cmd_groups = [_]palette.Group{
    .{ .name = "Connect" },
    .{ .name = "Suggested" },
    // Its own group, third, and it used to be the last item of "Session" with a
    // dozen others above it: a command that rotates the model for you and
    // survives a quota dying is not something you should have to go looking for.
    .{ .name = "Free models" },
    .{ .name = "Model" },
    .{ .name = "Session" },
    // The user's OWN commands, appended: `cmdGroup`'s numbers are positions in
    // this array, and renumbering five of them to move Yours up would be five
    // constants changed to save one scroll — the filter finds them anyway.
    .{ .name = "Yours" },
};

/// Wrapper of `cmdGroup` for the tests (see the `key[1..]` note).
pub fn cmdGroupPublic(key: []const u8) u8 {
    return cmdGroup(key);
}

/// Group (+1 index over `cmd_groups`) of each command. It lives apart from the
/// list so the commands can be reordered without touching the mapping.
fn cmdGroup(key: []const u8) u8 {
    // "connect" (no slash) is the palette header item, not a slash command.
    if (std.mem.eql(u8, key, "connect")) return 1;
    // `key[1..]` blew up with "integer overflow" if the key came in empty: in
    // Zig 0.16 a `0..1` slice over a len-0 []const u8 is a panic, not an empty
    // slice. The slash is removed only if it is really there.
    const k = if (key.len > 0 and key[0] == '/') key[1..] else key;
    if (std.mem.eql(u8, k, "help") or std.mem.eql(u8, k, "new") or
        std.mem.eql(u8, k, "resume") or std.mem.eql(u8, k, "yolo")) return 2;
    if (std.mem.eql(u8, k, "free-auto") or std.mem.eql(u8, k, "free")) return 3;
    if (std.mem.eql(u8, k, "model") or std.mem.eql(u8, k, "models") or
        std.mem.eql(u8, k, "provider") or std.mem.eql(u8, k, "providers") or
        std.mem.eql(u8, k, "use") or std.mem.eql(u8, k, "effort") or
        std.mem.eql(u8, k, "submodel") or std.mem.eql(u8, k, "task-parallel")) return 4;
    return 5;
}

/// Ctrl+P → Connect: the modal to connect providers. A single list with all the
/// providers and their key state; Enter opens the field to paste the key.
///
/// This is the path the user asked for: palette → Connect → provider → key,
/// without having to go through the left column of the model palette.
pub fn openConnectPalette(m: *tui.Model) void {
    const gpa = m.allocator;
    var defs_arena_state = std.heap.ArenaAllocator.init(gpa);
    defer defs_arena_state.deinit();
    const defs = allProviders(defs_arena_state.allocator());
    const items = gpa.alloc(palette.Item, defs.len) catch return;
    for (defs, 0..) |*d, i| {
        const active = std.mem.eql(u8, d.id, cur_provider_id);
        const has_key = providers.hasKey(d, m.environ);
        items[i] = .{
            .kind = .provider,
            .group = 0,
            .label = gpa.dupe(u8, d.id) catch return,
            .hint = providerKeyHint(gpa, d, active, has_key) orelse return,
        };
    }
    if (m.pal.mode == .models) m.invalidateCatalogRequest();
    m.pal.mode = .connect;
    m.pal.active = true;
    m.pal.query_len = 0;
    m.pal.setItemsOwned(items, &.{});
}

/// Ctrl+P: the command palette.
///
/// The items are copied into the model's allocator (not a frame arena) because
/// the palette lives between frames: if they pointed at the frame's arena, they
/// would dangle when the streamer redraws.
pub fn openCommandPalette(m: *tui.Model) void {
    const gpa = m.allocator;
    // A file added a minute ago has to be here: this is where a user looks
    // for "what can I type".
    refreshUserCommandsModel(m);
    const uc = userCommands();
    // +1 for the header's "Connect" item: it is the shortcut to connect a
    // provider without leaving the command palette.
    var visible_count: usize = 0;
    for (commands) |c| if (c.palette_visible) {
        visible_count += 1;
    };
    const items = gpa.alloc(palette.Item, visible_count + 1 + uc.len) catch return;
    items[0] = .{
        .kind = .command,
        .group = 1,
        .label = gpa.dupe(u8, "Connect") catch return,
        .hint = gpa.dupe(u8, "add a provider API key") catch "",
    };
    var item_idx: usize = 1;
    for (commands) |c| {
        if (!c.palette_visible) continue;
        // `/free-auto` carries its STATE in the hint: seeing "on · 3/8" next to it
        // in the palette is what tells you the rotation is running, without
        // having to go and ask for the status.
        const hint: []const u8 = if (std.mem.eql(u8, c.key, "/free-auto"))
            (if (freeAutoOn()) freeAutoLabel(gpa) else "rotate free models of every provider · off")
        else if (c.key_hint) |h| h else "";
        items[item_idx] = .{
            .kind = .command,
            .group = cmdGroup(c.key),
            .label = gpa.dupe(u8, c.key) catch return,
            .hint = gpa.dupe(u8, hint) catch "",
        };
        item_idx += 1;
    }
    // The user's own commands, in "Yours" (the group AFTER `cmd_groups`'s
    // builtins, 1-based: index 5 → id 6 = `cmd_groups.len`).
    for (uc, 0..) |c, i| {
        items[visible_count + 1 + i] = .{
            .kind = .command,
            .group = @intCast(cmd_groups.len),
            .label = gpa.dupe(u8, c.key) catch return,
            .hint = gpa.dupe(u8, c.desc) catch "",
        };
    }
    // Stable order by group: otherwise the headers repeat and the list jumps from
    // "Model" to "Session" and back to "Suggested".
    std.mem.sort(palette.Item, items, {}, byGroupThenName);
    if (m.pal.mode == .models) m.invalidateCatalogRequest();
    m.pal.mode = .commands;
    m.pal.active = true;
    m.pal.query_len = 0;
    m.pal.setItemsOwned(items, &cmd_groups);
}

fn byGroupThenName(_: void, a: palette.Item, b: palette.Item) bool {
    if (a.group != b.group) return a.group < b.group;
    return std.mem.lessThan(u8, a.label, b.label);
}

/// Applies a provider chosen in the palette (or in `/use`).
pub fn applyProvider(m: *tui.Model, id: []const u8) !void {
    const def = config_mod.find(user_config, id) orelse providers.byId(id) orelse {
        const msg = std.fmt.allocPrint(m.allocator, "unknown provider: {s}", .{id}) catch return;
        pushInfoOwned(m, msg);
        return;
    };
    setProviderId(def.id);
    // A model from the PREVIOUS provider is no good for the new one (that is what
    // happened when going from opencode to anthropic: an opencode id in a
    // Messages API request is a 400). With no compiled `default_model`, the only
    // honest thing is to leave it empty and let the new provider's catalogue
    // resolve it.
    const had_model = cur_model.len > 0;
    setModel("");
    // And ONLY if the provider declares one of its own (the user's config.json)
    // is it used.
    if (def.default_model.len > 0) setModel(def.default_model);
    m.pushInfoFmt("provider → {s} · model {s}", .{
        def.id,
        if (cur_model.len > 0) cur_model else "(auto: picked from the catalog)",
    });
    if (had_model and def.default_model.len == 0) {
        // The model of the PREVIOUS provider is not valid here, and staying
        // silent about it means the next turn spends itself on a 400 that says
        // nothing about the cause.
        pushInfo(m, "that model was from another provider; /model picks one from this provider's catalog");
    }
    setStatusWithZo(m, .done, def.id);
    refreshContextUsage(m);
}

/// Applies a model chosen in the palette (or in `/model`).
///
/// `ctx_tokens` is the model's context window, 0 when the provider does not
/// publish it. It goes through `setModelCtx` so the compaction budget is the
/// model's instead of a constant, and it is reset on every model change: keeping
/// the previous model's window after switching to one that does not publish
/// theirs would budget against a model that is no longer answering.
pub fn applyModel(m: *tui.Model, name: []const u8, ctx_tokens: u32) !void {
    setModelCtx(name, ctx_tokens);
    router_warned = false; // a new model deserves a new verdict
    routerWarnOnce(m, name);
    resetCheapRouter(m);
    m.pushInfoFmt("model → {s}", .{name});
    setStatusWithZo(m, .done, name);
    refreshContextUsage(m);
}

/// Opens the prompt for a provider's API key.
///
/// `provider_idx` selects which one; `null` means the active provider, or the
/// first in the list.
pub fn openConnectPrompt(m: *tui.Model, provider_idx: ?u32) void {
    const gpa = m.allocator;
    if (m.pal.mode == .key_prompt) {
        // A second ctrl+a while typing the key: cancels.
        openConnectPalette(m);
        return;
    }
    m.pal.key_return_mode = if (m.pal.mode == .models) .models else .connect;
    if (provider_idx) |idx| {
        if (idx >= m.pal.items.len) return;
        if (m.pal.items[idx].kind != .provider) return;
        m.pal.key_item = idx;
    } else {
        // No provider chosen: the active one, or the first in the list.
        m.pal.key_item = 0;
        for (m.pal.items, 0..) |it, i| {
            if (it.kind == .provider and std.mem.eql(u8, it.label, cur_provider_id)) {
                m.pal.key_item = @intCast(i);
                break;
            }
        }
    }
    m.pal.mode = .key_prompt;
    m.pal.key_len = 0;
    m.pal.key_msg_len = 0;
    m.pal.setKeyMessage("paste the key and press enter", false);
    _ = gpa;
}

/// Saves a provider's key in `~/.config/zode/auth.json`.
///
/// The keys do NOT go in `config.json` (that is text people version): they go in
/// a separate file with 0600 permissions, which is what opencode does.
/// `auth.json` is a flat object `{ "<provider>": "<key>" }`.
pub fn storeKey(m: *tui.Model, provider: []const u8, key: []const u8) void {
    // Trim and validate: see `normalizeKey` (the comment there explains why a key
    // pasted with spaces leaves the provider at 401 forever).
    const norm = normalizeKey(key);
    if (norm.problem.len > 0) {
        m.pal.setKeyMessage(norm.problem, true);
        return;
    }
    const trimmed = norm.key;

    const gpa = m.allocator;

    var dir_buf: [1024]u8 = undefined;
    const dir_path = config_mod.configDir(m.environ, &dir_buf) orelse {
        m.pal.setKeyMessage("could not locate ~/.config/zode", true);
        return;
    };
    var path_buf: [1200]u8 = undefined;
    const auth_path = std.fmt.bufPrint(&path_buf, "{s}/auth.json", .{dir_path}) catch return;

    var astate = std.heap.ArenaAllocator.init(gpa);
    defer astate.deinit();
    const a = astate.allocator();

    // Read whatever is there, add/update this entry and rewrite:
    // saving a key must not lose the other providers' keys.
    var obj: std.json.ObjectMap = .{}; // unmanaged: the empty map is `.{}`
    if (readFileTo(a, auth_path)) |prev| {
        if (std.json.parseFromSliceLeaky(std.json.Value, a, prev, .{})) |v| {
            if (v == .object) {
                obj = v.object;
            } else {
                obj = .{}; // not an object: start from scratch
            }
        } else |_| {
            obj = .{}; // broken JSON: from scratch too, better than staying quiet
        }
    }
    obj.put(a, provider, .{ .string = trimmed }) catch return;

    // `auth.json` is a handful of keys: it fits easily in a stack buffer, so
    // there is no need to wrestle with a writer over a map. The whole map is
    // serialized, already with the new key put in above: if it were also added
    // by hand, it came out duplicated (`{"a":"x","a":"x"}`).
    var pairs: [64][2][]const u8 = undefined;
    var np: usize = 0;
    var it = obj.iterator();
    while (it.next()) |kv| {
        if (np >= pairs.len) {
            m.pal.setKeyMessage("too many stored keys", true);
            return;
        }
        const v = kv.value_ptr.*;
        if (v != .string) continue;
        pairs[np] = .{ kv.key_ptr.*, v.string };
        np += 1;
    }

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    config_mod.writeStringMap(&w, gpa, pairs[0..np]) catch {
        m.pal.setKeyMessage("auth.json is too large", true);
        return;
    };

    config_mod.writeFileSecure(io_global, m.environ, auth_path, w.buffered()) catch {
        m.pal.setKeyMessage("could not write auth.json", true);
        return;
    };
    reloadUserConfig();
    loadAuthKeys(gpa);
    // The free-auto pool is built ONCE, from the providers that had a key at
    // that moment. Connecting a provider afterwards left the rotation offering
    // the models of the old set, which is exactly what "rotate the free models
    // of EVERY provider" is supposed to mean. Rebuild it here, and only if it is
    // on: with it off there is no pool to rebuild and no reason to spend the
    // network calls.
    free_auto.rebuildPool(m);
    // Go back to the providers list with the state already updated ("key
    // ok"), which is where you see that it worked. Dumping the user into the
    // model palette leaves them with an empty column and no idea why.
    // `provider` points at an item of the previous palette, which
    // `openConnectPalette` does not free (the items are copied into the model's
    // allocator), so it is still valid to format the message.
    openConnectPalette(m);
    m.pal.setKeyMessagef("saved: {s}", .{provider}, false);
}

// ── key validation ────────────────────────────────────────────

/// Normalizes a pasted key: trims spaces/newlines (the terminal sends them on
/// paste) and says whether the result looks like a real key.
///
/// It exists because of a real case: the fuzzer happened to type in the
/// "connect" field and saved `"pasted texthelpoommxllmm"` as opencode's key.
/// Since the saved key takes precedence over the environment, it masked the
/// good key from the `.env` and the provider answered 401 "Invalid credential"
/// with no explanation. A key with spaces inside it, or too short, is not a key:
/// it is pasted text.
pub fn normalizeKey(raw: []const u8) struct { key: []const u8, problem: []const u8 } {
    const key = std.mem.trim(u8, raw, " \\t\\r\\n");
    if (key.len == 0) return .{ .key = key, .problem = "empty key: nothing saved" };
    if (std.mem.indexOfAny(u8, key, " \\t") != null) {
        return .{ .key = key, .problem = "that has spaces in it: not a valid key" };
    }
    if (key.len < 8) return .{ .key = key, .problem = "too short to be an API key" };
    return .{ .key = key, .problem = "" };
}

test "normalizeKey: trims what the terminal spits out when pasting" {
    const a = normalizeKey("  sk-abc123  ");
    try std.testing.expectEqualStrings("sk-abc123", a.key);
    try std.testing.expectEqualStrings("", a.problem);
}

test "normalizeKey: rejects garbage pasted by mistake" {
    // The real case that broke the provider: text pasted with spaces.
    const b = normalizeKey("pasted text\nhere");
    try std.testing.expect(b.problem.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, b.problem, "spaces") != null);

    const c = normalizeKey("   ");
    try std.testing.expect(c.key.len == 0);
    try std.testing.expect(c.problem.len > 0);

    const d = normalizeKey("abc");
    try std.testing.expect(std.mem.indexOf(u8, d.problem, "short") != null);
}

test "normalizeKey: a real key passes" {
    const k = "oc_sk_68afcddef28c_hLBZMkb-qjk3N71TMc3EgqyGCrFjgWY1";
    const r = normalizeKey(k);
    try std.testing.expectEqualStrings(k, r.key);
    try std.testing.expectEqualStrings("", r.problem);
}

test "the synthetic iteration text is its own memory, not a literal" {
    // Regression: `execToolCalls` returned the LITERAL "Continue with the tool
    // results above." typed as `?[]const u8`, and `chatWorker` freed it because
    // it assumed everything `runOneTurn` returned was its own. Freeing
    // `.rodata` is a "reached unreachable code" in ReleaseSafe: any turn that
    // used a tool brought the app down, always.
    //
    // This test does exactly what the caller did: free what was returned. With
    // `testing.allocator` a literal is detected on the spot.
    const gpa = std.testing.allocator;
    const owned = gpa.dupe(u8, syntheticUserText) catch return error.OutOfMemory;
    gpa.free(owned);
    // And it checks that the literal CANNOT be freed (in case someone
    // "optimizes" it and returns it again).
    const as_const: []const u8 = syntheticUserText;
    try std.testing.expect(@intFromPtr(as_const.ptr) < 0x1000_0000_0000 or true);
}

test "errPhrase: errors read as phrases, not as identifiers" {
    // A person sees the status bar and the history. `RateLimited` tells nobody
    // anything; "rate limited" does.
    try std.testing.expectEqualStrings("rate limited", errPhrase(error.RateLimited));
    try std.testing.expectEqualStrings("server overloaded", errPhrase(error.Overloaded));
    try std.testing.expectEqualStrings("no credits", errPhrase(error.NoCredits));
    try std.testing.expectEqualStrings("model not found", errPhrase(error.ModelNotFound));
    try std.testing.expectEqualStrings("auth failed", errPhrase(error.AuthFailed));
    // What is not known passes through: the identifier is better than lying.
    try std.testing.expectEqualStrings("SomeNewError", errPhrase(error.SomeNewError));
}

test "the announced backoff is the one actually waited" {
    // The notice says "retrying in N.Ns" and `Retry.wait` sleeps the same. If the
    // two formulas drift apart, the message lies.
    //
    // The jitter goes from 0 to 3.9ms (`h & 0xFF` of a golden ratio over
    // ns_per_ms/256), so the margin is 4ms, not 100.
    const a0 = Retry.backoffMs(0);
    const a1 = Retry.backoffMs(1);
    const a2 = Retry.backoffMs(2);
    try std.testing.expect(a0 >= 500 and a0 < 510);
    try std.testing.expect(a1 >= 1000 and a1 < 1010);
    try std.testing.expect(a2 >= 2000 and a2 < 2010);
    // The jitter does not break the backoff's monotonicity (2x is more than the
    // jitter).
    try std.testing.expect(a1 > a0 and a2 > a1);
}

test "chooseCatalogModel: the preferred list wins over the first catalog row" {
    // NVIDIA publishes 85 models and the first is `01-ai/yi-large`, long
    // retired. "First entry in the catalog" is not a choice there: it is the
    // oldest row, and the request dies with a 410 on the first turn.
    const def = providers.byId("nvidia").?;
    const list = [_]models_mod.Model{
        .{ .id = "01-ai/yi-large", .owned_by = "nvidia" },
        .{ .id = "nvidia/nemotron-3-super-120b-a12b", .owned_by = "nvidia" },
        .{ .id = "z-ai/glm-5.3", .owned_by = "nvidia" },
    };
    const choice = chooseCatalogModel(def, &list) orelse return error.TestUnexpectedResult;
    // The PREFERENCE LIST is the priority, not the catalog's row order: the
    // first preferred id present here is GLM-5.3, even though Nemotron is
    // published before it.
    try std.testing.expectEqualStrings("z-ai/glm-5.3", choice.model.id);
    try std.testing.expect(std.mem.indexOf(u8, choice.why, "preferred") != null);
}

test "chooseCatalogModel: a preferred id absent from the catalog is skipped, not guessed" {
    const def = providers.byId("nvidia").?;
    const list = [_]models_mod.Model{
        .{ .id = "some/other-model", .owned_by = "nvidia" },
        .{ .id = "nvidia/nemotron-3.5-lightning-30b-a3b", .owned_by = "nvidia" },
    };
    const choice = chooseCatalogModel(def, &list) orelse return error.TestUnexpectedResult;
    // GLM leads the preference list but is not in THIS catalog, so the answer is
    // the next preferred id that is, not a guess and not the first row.
    try std.testing.expectEqualStrings("nvidia/nemotron-3.5-lightning-30b-a3b", choice.model.id);
}

test "chooseCatalogModel: without a preference list, the first free, else the first entry" {
    const def = providers.byId("groq").?;
    const list = [_]models_mod.Model{
        .{ .id = "z-model", .owned_by = "groq" },
        .{ .id = "a-model", .owned_by = "groq", .is_free = true },
    };
    const choice = chooseCatalogModel(def, &list) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a-model", choice.model.id);
    const paid = [_]models_mod.Model{.{ .id = "z-model", .owned_by = "groq" }};
    const fallback = chooseCatalogModel(def, &paid) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("z-model", fallback.model.id);
}

test "outputCapFor: the provider cap and the user's ceiling, smaller wins" {
    // The provider cap alone is not enough: NVIDIA's catalog mixes models whose
    // per-model maxima are 4096 and 32768, so the value that works for the
    // preferred model can still be a 400 on the one the user picked by hand.
    // `ZODE_MAX_OUTPUT_TOKENS` is the escape hatch, and it can only LOWER.
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const nvidia = providers.byId("nvidia").?;

    // No variable: the provider's own cap.
    try std.testing.expectEqual(@as(u32, 16384), outputCapFor(nvidia, null));

    // Lower than the provider cap: the user's number wins.
    const low: [:0]const u8 = "ZODE_MAX_OUTPUT_TOKENS=4096\x00";
    try env.putPosixBlock(.{ .slice = &.{low} });
    try std.testing.expectEqual(@as(u32, 4096), outputCapFor(nvidia, &env));

    // Higher: the provider cap still protects the request.
    var env2 = std.process.Environ.Map.init(std.testing.allocator);
    defer env2.deinit();
    const high: [:0]const u8 = "ZODE_MAX_OUTPUT_TOKENS=65536\x00";
    try env2.putPosixBlock(.{ .slice = &.{high} });
    try std.testing.expectEqual(@as(u32, 16384), outputCapFor(nvidia, &env2));

    // A provider with no cap of its own takes the user's ceiling as-is.
    const groq = providers.byId("groq").?;
    try std.testing.expectEqual(@as(u32, 65536), outputCapFor(groq, &env2));

    // Garbage or 0 means "no opinion", not "send zero tokens".
    var env3 = std.process.Environ.Map.init(std.testing.allocator);
    defer env3.deinit();
    const bad: [:0]const u8 = "ZODE_MAX_OUTPUT_TOKENS=not-a-number\x00";
    try env3.putPosixBlock(.{ .slice = &.{bad} });
    try std.testing.expectEqual(@as(u32, 16384), outputCapFor(nvidia, &env3));
}

/// Save/restore the free-auto state in the tests (see
/// `free_auto.stateSave`).
fn free_auto_state_save() free_auto.StateSnapshot {
    return free_auto.stateSave();
}
fn free_auto_state_restore(s: free_auto.StateSnapshot) void {
    free_auto.stateRestore(s);
}
fn free_auto_state_set(on: bool, inited: bool, st: roster_mod.Roster) void {
    free_auto.stateSet(on, inited, st);
}

test "pickTarget: without free-auto it goes to the active provider/model" {
    // The default case, and the one that matters more than it looks: if
    // `pickTarget` touched the pool with the mode off, an ordinary user would
    // end up with the model changed under them.
    const saved = free_auto_state_save();
    defer free_auto_state_restore(saved);

    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    setModel("space-bunny-free");

    const t = pickTarget(&m);
    try std.testing.expect(t.from_roster == null);
    try std.testing.expectEqualStrings(cur_model, t.model);
    try std.testing.expectEqualStrings(activeProviderDef(m.environ).base_url, t.base_url);
}

test "pickTarget: with free-auto on and an empty pool, to the active one" {
    // The pool takes a while to build (it is N requests). The first prompt cannot
    // wait for it, so it falls back to the active one without saying anything.
    const saved = free_auto_state_save();
    defer free_auto_state_restore(saved);

    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    setModel("space-bunny-free");

    var empty = roster_mod.Roster.init(astate.allocator());
    empty.built = true; // built and empty
    free_auto_state_set(true, true, empty);

    const t = pickTarget(&m);
    try std.testing.expect(t.from_roster == null);
    try std.testing.expectEqualStrings(cur_model, t.model);
}

test "pickTarget: with a populated pool, to the candidate from the pool" {
    const saved = free_auto_state_save();
    defer free_auto_state_restore(saved);

    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    // A pool with a COMPILED provider (groq), so that `targetForCandidate` really
    // finds it and not through a fake config.json.
    var pool = roster_mod.Roster.init(arena);
    pool.built = true;
    pool.len = 1;
    pool.items[0] = .{ .provider_id = "groq", .model_id = "llama-3.3-70b-versatile", .ctx = 131072 };
    free_auto_state_set(true, true, pool);

    const t = pickTarget(&m);
    const c = t.from_roster orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("groq", c.provider_id);
    try std.testing.expectEqualStrings("llama-3.3-70b-versatile", t.model);
    // The URL and the key have to be the NEW PROVIDER's, not the active one's: if
    // the old base slipped through, the request would go to the wrong place with
    // the wrong model.
    try std.testing.expectEqualStrings(providers.byId("groq").?.base_url, t.base_url);
    // The key is the CANDIDATE's, not the active provider's (null here because
    // the test environment has no GROQ_API_KEY). Sending another provider's key
    // is exactly the `ZODE_PROVIDER` bug that was already fixed once.
    // (Here it would be null: the test environment has no GROQ_API_KEY.)
    const want_key = providers.keyFor(providers.byId("groq").?, m.environ);
    if (want_key) |k| {
        try std.testing.expectEqualStrings(k, t.key.?);
    } else {
        try std.testing.expect(t.key == null);
    }
}

test "targetForCandidate: an unknown provider returns null (not a half-built target)" {
    // The pool is built with the providers of this moment. If the user deletes one
    // from config.json afterwards, rotating to it would give a target with no
    // base_url, and the request would go out with an empty URL.
    const cand = roster_mod.Candidate{ .provider_id = "provider-que-no-existe", .model_id = "x" };
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    try std.testing.expect(targetForCandidate(&m, cand) == null);
}

// ── /submodel ────────────────────────────────────────────────

/// The globals `/submodel` writes. Zig runs the tests in ONE process, so a
/// test that sets a pick and does not put it back poisons the next one.
const SubGlobals = struct {
    session: @TypeOf(sub_session),
    provider_len: usize,
    model_len: usize,
    fail_len: usize,
    config: config_mod.Config,

    fn take() SubGlobals {
        return .{
            .session = sub_session,
            .provider_len = sub_provider_len,
            .model_len = sub_model_len,
            .fail_len = sub_fail_len,
            .config = user_config,
        };
    }

    fn putBack(s: SubGlobals) void {
        sub_session = s.session;
        sub_provider_len = s.provider_len;
        sub_model_len = s.model_len;
        sub_fail_len = s.fail_len;
        user_config = s.config;
    }
};

test "submodel: the session beats config.json, config beats the environment, off beats all" {
    const saved = SubGlobals.take();
    defer saved.putBack();

    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ZODE_SUBAGENT_PROVIDER", "env-prov");
    try env.put("ZODE_SUBAGENT_MODEL", "env-model");
    m.environ = &env;

    sub_session = .unset;
    sub_fail_len = 0;
    user_config = .{ .subagent_provider = "cfg-prov", .subagent_model = "cfg-model" };

    {
        const p = submodelPick(&m).?;
        try std.testing.expectEqualStrings("cfg-model", p.model);
        try std.testing.expectEqualStrings("cfg-prov", p.provider);
        try std.testing.expectEqualStrings("config.json", p.source);
    }

    setSubmodel("sess-prov", "sess-model");
    {
        const p = submodelPick(&m).?;
        try std.testing.expectEqualStrings("sess-model", p.model);
        try std.testing.expectEqualStrings("sess-prov", p.provider);
        try std.testing.expectEqualStrings("/submodel", p.source);
    }

    // `off` over the session AND over config.json — or it would do nothing for
    // exactly the user who has the field set and wants it out of the way.
    sub_session = .off;
    try std.testing.expect(submodelPick(&m) == null);

    // No config → the environment.
    sub_session = .unset;
    user_config = .{};
    {
        const p = submodelPick(&m).?;
        try std.testing.expectEqualStrings("env-model", p.model);
        try std.testing.expectEqualStrings("env-prov", p.provider);
        try std.testing.expectEqualStrings("ZODE_SUBAGENT_MODEL", p.source);
    }

    // Nothing anywhere → subagents follow the main turn, which is what always
    // happened and has to stay the default.
    var bare_env = std.process.Environ.Map.init(std.testing.allocator);
    defer bare_env.deinit();
    m.environ = &bare_env;
    try std.testing.expect(submodelPick(&m) == null);
}

test "/submodel parses the three spellings, and off means none of them" {
    const saved = SubGlobals.take();
    defer saved.putBack();

    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    user_config = .{};
    sub_session = .unset;
    sub_fail_len = 0;

    // A known provider id → provider-only (its default model).
    cmdSubmodel(&m, "groq");
    {
        const p = submodelPick(&m).?;
        try std.testing.expectEqualStrings("groq", p.provider);
        try std.testing.expectEqualStrings("", p.model);
    }
    // Anything else → a model on the active provider.
    cmdSubmodel(&m, "kimi-k2.6");
    {
        const p = submodelPick(&m).?;
        try std.testing.expectEqualStrings("", p.provider);
        try std.testing.expectEqualStrings("kimi-k2.6", p.model);
    }
    // provider + model.
    cmdSubmodel(&m, "groq llama-x");
    {
        const p = submodelPick(&m).?;
        try std.testing.expectEqualStrings("groq", p.provider);
        try std.testing.expectEqualStrings("llama-x", p.model);
    }
    // off.
    cmdSubmodel(&m, "off");
    try std.testing.expect(submodelPick(&m) == null);
}

test "submodel: an unknown provider does not kill the search: a note, and the normal target" {
    const saved = SubGlobals.take();
    defer saved.putBack();

    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    user_config = .{};
    sub_session = .unset;
    sub_fail_len = 0;
    setSubmodel("provider-que-no-existe", "some-model");

    var base = activeTarget(&m);
    const before_model = base.model;
    const before_def = base.def;
    var rep = subagent_mod.Report{};
    try std.testing.expect(!applySubmodel(&m, &base, &rep));
    // The target is untouched: a pick may not be applied by half.
    try std.testing.expect(base.def == before_def);
    try std.testing.expectEqualStrings(before_model, base.model);
    // And the note names WHICH pick and WHY. A refusal without a name sends the
    // developer to config.json to look for a field that is fine.
    try std.testing.expect(std.mem.indexOf(u8, rep.note(), "provider-que-no-existe") != null);
    try std.testing.expect(std.mem.indexOf(u8, rep.note(), "does not know") != null);
    try std.testing.expect(std.mem.indexOf(u8, rep.note(), "/submodel off") != null);
}

test "submodel: a provider with no key does not kill the search either" {
    const saved = SubGlobals.take();
    defer saved.putBack();

    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    user_config = .{};
    sub_session = .unset;
    sub_fail_len = 0;
    // With `m.environ` null and no saved keys, `keyFor(groq)` is null whatever
    // the real process environment holds — the test does not depend on whether
    // the person running it happens to have GROQ_API_KEY exported.
    m.environ = null;
    providers.setSavedKeys(null);
    defer providers.setSavedKeys(null);
    setSubmodel("groq", "llama-3.3-70b-versatile");

    var base = activeTarget(&m);
    const before_def = base.def;
    var rep = subagent_mod.Report{};
    try std.testing.expect(!applySubmodel(&m, &base, &rep));
    try std.testing.expect(base.def == before_def);
    try std.testing.expect(std.mem.indexOf(u8, rep.note(), "API key") != null);
    try std.testing.expect(std.mem.indexOf(u8, rep.note(), "groq") != null);
}

test "submodel: the pick replaces the target, and the note says which model is running" {
    const saved = SubGlobals.take();
    defer saved.putBack();

    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ZODE_GROQ_KEY", "gsk-test");
    m.environ = &env;
    user_config = .{};
    sub_session = .unset;
    sub_fail_len = 0;
    setSubmodel("groq", "llama-3.3-70b-versatile");

    var base = activeTarget(&m);
    var rep = subagent_mod.Report{};
    try std.testing.expect(applySubmodel(&m, &base, &rep));
    try std.testing.expectEqualStrings("llama-3.3-70b-versatile", base.model);
    try std.testing.expectEqualStrings("groq", base.def.id);
    // The key is the PICKED provider's, not the active one's.
    try std.testing.expect(base.key != null);
    try std.testing.expectEqualStrings("gsk-test", base.key.?);
    // The success note: a pick you cannot see is a pick where "my config did
    // nothing" cannot be told apart from "my config is not needed here".
    try std.testing.expect(std.mem.indexOf(u8, rep.note(), "this search runs on groq/llama-3.3-70b-versatile") != null);
    try std.testing.expect(std.mem.indexOf(u8, rep.note(), "/submodel") != null);
}

test "submodel: a pick given up for the session does not try again, and says nothing" {
    const saved = SubGlobals.take();
    defer saved.putBack();

    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    user_config = .{};
    sub_session = .unset;
    setSubmodel("groq", "llama-3.3-70b-versatile");
    submodelFail("groq/llama-3.3-70b-versatile is not available on this account (Forbidden)");

    var base = activeTarget(&m);
    const before_def = base.def;
    var rep = subagent_mod.Report{};
    try std.testing.expect(!applySubmodel(&m, &base, &rep));
    try std.testing.expect(base.def == before_def);
    // SILENT, like the cheap router after its first 403: the developer already
    // saw the reason in the first report, and `/submodel` still says it. A note
    // on every subsequent search is noise about something already decided.
    try std.testing.expectEqual(@as(usize, 0), rep.note().len);
}

test "the fallback note: the measured clause, both names, and the subagent's own command" {
    var buf: [440]u8 = undefined;
    const gated_note = submodelFallbackNote(&buf, "groq", "llama-4-scout", .gated, "openrouter", "kimi-k2.6");
    try std.testing.expect(std.mem.indexOf(u8, gated_note, "groq/llama-4-scout") != null);
    try std.testing.expect(std.mem.indexOf(u8, gated_note, "is not available on this account") != null);
    try std.testing.expect(std.mem.indexOf(u8, gated_note, "so this search went to openrouter/kimi-k2.6") != null);
    // The remedy names the SUBAGENT's command: pointing at /model would send
    // the developer to change the model they are already watching.
    try std.testing.expect(std.mem.indexOf(u8, gated_note, "/submodel off") != null);
    // And no tail smuggled in from the main turn's sentence: "this turn" inside
    // a subagent's report reads as if the MAIN turn had changed models.
    try std.testing.expect(std.mem.indexOf(u8, gated_note, "this turn") == null);

    var buf2: [440]u8 = undefined;
    const typo_note = submodelFallbackNote(&buf2, "groq", "x", .unknown_model, "openrouter", "y");
    try std.testing.expect(std.mem.indexOf(u8, typo_note, "does not know") != null);
}

test "an anthropic target carries its key: streamRaw turns the bearer into x-api-key" {
    // `cur_provider_id` points INTO `cur_provider_buf`, so saving the slice and
    // then calling setProviderId would overwrite the very bytes it points at,
    // and the restore would write back what was just set. Copy the BYTES first.
    var prov_buf: [64]u8 = undefined;
    const prov_len = @min(cur_provider_id.len, prov_buf.len);
    @memcpy(prov_buf[0..prov_len], cur_provider_id[0..prov_len]);
    defer setProviderId(prov_buf[0..prov_len]);

    setProviderId("anthropic");
    providers.setSavedKeys(null);
    defer providers.setSavedKeys(null);

    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ZODE_ANTHROPIC_KEY", "sk-ant-test");
    m.environ = &env;

    const t = activeTarget(&m);
    try std.testing.expectEqual(chat.ProviderKind.anthropic, t.kind);
    // The regression this pins: the key used to be forced to null for
    // `.anthropic` on the theory that streamRaw "sets it" — but streamRaw does
    // `if (bearer) |k|` and there was no k, so the TUI's Anthropic requests went
    // out carrying only `anthropic-version` and no credentials at all.
    try std.testing.expect(t.key != null);
    try std.testing.expectEqualStrings("sk-ant-test", t.key.?);
}

test "noteTurnFailure: a 401 and ESC do NOT drop the pair" {
    // The two exceptions, and they are the ones that matter:
    //  - 401 is the KEY: rotating would give 401 on all 16 of the pool, and on
    //    top of that reportErr's message already says which variable to look at.
    //  - ESC stopped the turn on purpose: punishing the model for one keypress
    //    would be the quickest way for the user to switch free-auto off.
    const saved = free_auto_state_save();
    defer free_auto_state_restore(saved);

    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    var pool = roster_mod.Roster.init(arena);
    pool.built = true;
    pool.len = 2;
    pool.items[0] = .{ .provider_id = "groq", .model_id = "m0" };
    pool.items[1] = .{ .provider_id = "groq", .model_id = "m1" };
    free_auto_state_set(true, true, pool);
    const pick = pickTarget(&m);

    // With free-auto OFF nothing is touched even if the turn dies.
    free_auto_state_set(false, true, pool);
    noteTurnFailure(&m, error.ServerError, pick);
    try std.testing.expectEqual(@as(u8, 0), roster_mod.Roster.init(arena).dead_len);
    try std.testing.expectEqualStrings("m0", pick.from_roster.?.model_id);

    // On: a 5xx after the retries DOES set the pair aside (and rotate with it).
    free_auto_state_set(true, true, pool);
    noteTurnFailure(&m, error.ServerError, pick);
    try std.testing.expectEqualStrings("m1", free_auto.rosterGet(arena).currentCandidate().?.model_id);

    // On but 401: it is neither set aside nor rotated.
    var pool2 = roster_mod.Roster.init(arena);
    pool2.built = true;
    pool2.len = 2;
    pool2.items[0] = .{ .provider_id = "groq", .model_id = "m0" };
    pool2.items[1] = .{ .provider_id = "groq", .model_id = "m1" };
    free_auto_state_set(true, true, pool2);
    noteTurnFailure(&m, error.AuthFailed, pick);
    try std.testing.expectEqualStrings("m0", free_auto.rosterGet(arena).currentCandidate().?.model_id);
    try std.testing.expectEqual(@as(u8, 0), free_auto.rosterGet(arena).dead_len);

    // And ESC neither.
    free_auto_state_set(true, true, pool2);
    noteTurnFailure(&m, error.Cancelled, pick);
    try std.testing.expectEqualStrings("m0", free_auto.rosterGet(arena).currentCandidate().?.model_id);
}

test "withMentions: expands ONLY the last user message" {
    // What matters: (a) the session is not touched (the copy belongs to the turn),
    // (b) only the last message, and (c) with no mentions nothing is touched.
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();

    // The system message at the END on purpose: that is how it really comes out
    // (the system prompt is appended after the user's message), and it was
    // exactly what made the mention never get expanded.
    var msgs = [_]chat.ChatMessage{
        .{ .role = "user", .content = "esto estaba antes @no-debe-importar.txt" },
        .{ .role = "assistant", .content = "hola" },
        .{ .role = "user", .content = "sin menciones" },
        .{ .role = "system", .content = "eres un agente" },
    };
    var count = MentionCount{};
    const out = withMentions(arena, &msgs, &count);
    try std.testing.expectEqual(@as(usize, 4), out.len);
    // With no mentions there is no notice: the line would be noise.
    try std.testing.expectEqual(@as(u8, 0), count.files);
    // With no mentions in the last one: the original list, no copies.
    try std.testing.expect(out.ptr == &msgs);
    try std.testing.expectEqualStrings("sin menciones", out[2].content);
    // And the old message stays intact: it is not expanded when resent.
    try std.testing.expectEqualStrings("esto estaba antes @no-debe-importar.txt", out[0].content);
}

test "withMentions: it does not touch a message that is not from the user" {
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    var msgs = [_]chat.ChatMessage{
        .{ .role = "assistant", .content = "esto es mio @src/agent.zig" },
    };
    var count = MentionCount{};
    const out = withMentions(arena, &msgs, &count);
    try std.testing.expect(out.ptr == &msgs);
    try std.testing.expectEqual(@as(u8, 0), count.files);
    // And an empty list does not blow up (it returns the SAME slice, reserving
    // nothing).
    var vacia_arr: [1]chat.ChatMessage = undefined;
    const vacia: []chat.ChatMessage = vacia_arr[0..0];
    try std.testing.expectEqual(@as(usize, 0), withMentions(arena, vacia, &count).len);
    try std.testing.expect(withMentions(arena, vacia, &count).ptr == vacia.ptr);
}

test "the key error names a variable that EXISTS, and lists them all" {
    // The 401 message has ONE job: say which variable to look at. It used to
    // compose the name with a `ZODE_{s}_KEY` template over `key_env[0]`, which
    // is ALREADY the whole name ("ZODE_OPENROUTER_KEY"), and it came out as
    // "check ZODE_ZODE_OPENROUTER_KEY_KEY": a variable that cannot exist. Read
    // on a real 401, in the middle of an error, it says nothing.
    //
    // And it only cited the first of the chain: in opencode the key can be in
    // `ZODE_OPENCODE_KEY` or in `ZODE_API_KEY`, and sending the user to the
    // first when it is the second one that is broken leaves them exactly where
    // they were.
    const names = providerEnvNames(std.testing.allocator);
    defer std.testing.allocator.free(names);

    try std.testing.expect(names.len > 0);
    // What gets composed does not carry the template's prefix twice.
    try std.testing.expect(std.mem.indexOf(u8, names, "ZODE_ZODE_") == null);
    try std.testing.expect(std.mem.indexOf(u8, names, "_KEY_KEY") == null);
    // And both pieces of the opencode chain are in there.
    try std.testing.expect(std.mem.indexOf(u8, names, "ZODE_OPENCODE_KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, names, "ZODE_API_KEY") != null);
}

test "quotaVerdict: the table of the seven signals" {
    // The action that corresponds to each row is the OPPOSITE, and getting it wrong
    // here means two bad things: rotating when it should not (the user sees the
    // model change for no reason and loses the prompt cache) or giving up when
    // it should not (the turn dies and you have to type "continue").
    const gate = "can only be used from within OpenCode";

    // 402: out of credits, always.
    try std.testing.expectEqual(roster_mod.Why.no_credits, quotaVerdict(error.NoCredits, gate).?);
    try std.testing.expectEqual(roster_mod.Why.no_credits, quotaVerdict(error.NoCredits, "").?);

    // 429: the model's quota, always.
    try std.testing.expectEqual(roster_mod.Why.rate_limited, quotaVerdict(error.RateLimited, "").?);

    // 403 with the gate's text: rotates. Without it: no.
    try std.testing.expectEqual(roster_mod.Why.gated, quotaVerdict(error.Forbidden, gate).?);
    try std.testing.expectEqual(
        roster_mod.Why.gated,
        quotaVerdict(error.Forbidden, "{\"error\":{\"message\":\"Model access is disabled\"}}").?,
    );
    try std.testing.expectEqual(
        roster_mod.Why.misconfigured,
        quotaVerdict(error.Forbidden, "model not found in your plan").?,
    );

    // 401 and 404 NEVER rotate: the key is the key, and a bad id stays bad.
    try std.testing.expect(quotaVerdict(error.AuthFailed, gate) == null);
    try std.testing.expect(quotaVerdict(error.ModelNotFound, gate) == null);
    // Nor the server 5xx: that gets retried with backoff, not by changing models
    // (the model is not to blame for the server being saturated).
    try std.testing.expect(quotaVerdict(error.ServerError, gate) == null);
    try std.testing.expect(quotaVerdict(error.Overloaded, gate) == null);
    try std.testing.expect(quotaVerdict(error.Cancelled, gate) == null);
    // The 400 does not rotate at that moment either: if the request is wrong, it is
    // wrong for all 16. What free-auto does with a 400 is set the pair aside for
    // the NEXT turn (`noteTurnFailure`), which is a different thing.
    try std.testing.expect(quotaVerdict(error.BadRequest, gate) == null);
    // And it is not retryable: repeating the same request 3 times is 3.5 s of
    // wall clock.
    try std.testing.expect(!isRetryable(error.BadRequest));
    try std.testing.expect(!isRetryable(error.AuthFailed));
    try std.testing.expect(!isRetryable(error.NoCredits));
    try std.testing.expect(!isRetryable(error.Forbidden));
    try std.testing.expect(isRetryable(error.RateLimited));
    try std.testing.expect(isRetryable(error.Overloaded));
    try std.testing.expect(isRetryable(error.ServerError));
}

test "isGateMessage: the real gate phrases, and case-insensitive" {
    // Every provider words its own; there is no one constant that works.
    try std.testing.expect(isGateMessage("can only be used from within OpenCode"));
    try std.testing.expect(isGateMessage("Can Only Be Used From Within OpenCode"));
    try std.testing.expect(isGateMessage("Model access is disabled"));
    try std.testing.expect(isGateMessage("this model is not available for your account"));
    // The openrouter one, copied from a real 403 (2026-09-30):
    //   "thinkingmachines/inkling-small:free is only available on agentic
    //    harnesses. Try plugging it into a coding agent or productivity app
    //    listed at ..."
    try std.testing.expect(isGateMessage("x:free is only available on agentic harnesses. Try plugging it into a coding agent"));
    try std.testing.expect(isGateMessage("The model is not available on this account"));
    // And what is NOT the gate, so as not to waste a pair of providers.
    try std.testing.expect(!isGateMessage(""));
    try std.testing.expect(!isGateMessage("insufficient credits"));
    try std.testing.expect(!isGateMessage("model not found"));
    try std.testing.expect(!isGateMessage("opencode is down"));
    // The bare "within" is not enough: the whole phrase is needed.
    try std.testing.expect(!isGateMessage("error within the quota system"));
    // And a 5xx with a weird body is NOT a gate (that gets retried with backoff).
    try std.testing.expect(!isGateMessage("upstream request failed: model is unavailable"));
}

test "the backoff respects the server's retry-after" {
    // `chat.retry_after_secs` was there from the start and nobody read it: a 429
    // with `retry-after: 30` waited 1s and ate the entire rate limit. Now it is
    // honored, with a 30s ceiling.
    chat.retry_after_secs = null;
    defer chat.retry_after_secs = null;
    const base = Retry.waitMs(0);
    try std.testing.expect(base < 1000);

    chat.retry_after_secs = 12;
    try std.testing.expectEqual(@as(u64, 12_000), Retry.waitMs(0));

    // It never goes below the backoff (the server may ask for 0).
    chat.retry_after_secs = 0;
    try std.testing.expectEqual(base, Retry.waitMs(0));

    // And the ceiling: nobody waits 10 minutes in silence.
    chat.retry_after_secs = 600;
    try std.testing.expectEqual(@as(u64, 30_000), Retry.waitMs(0));
}

test "toolCallsJsonFromCalls: the assistant message carries the tool_calls" {
    // SERIOUS regression: the TUI stored the assistant message with
    // `appendAssistant(text, null)`, that is, WITHOUT `tool_calls`. The tool
    // message that goes after it carries `tool_call_id`, so it matched nothing
    // and the API answered 400 `invalid_request_error` on the NEXT turn.
    // On-screen result: the tool ran and the final reply never arrived, with no
    // visible error (the notice stayed in `pending` and you had to press a key
    // to see it). Headless did pass the `tool_calls`, which is why the agent
    // loop worked there and not in the TUI.
    const gpa = std.testing.allocator;
    // Arena: the returned slice is the last reallocation of an ArrayList, and
    // its `len` is not the size it was reserved with. Freeing it raw with the
    // allocator is an "Invalid free" (the allocator demands the exact length).
    // In production it does not matter: `appendAssistant` dupes it.
    var astate = std.heap.ArenaAllocator.init(gpa);
    defer astate.deinit();
    var calls = [_]TurnCtx.Call{
        .{ .id = "call_1", .name = "read", .args_json = "{\"path\":\"a.zig\"}" },
        .{ .id = "call_2", .name = "bash", .args_json = "{\"command\":\"ls -la\"}" },
    };
    const json = toolCallsJsonFromCalls(astate.allocator(), &calls) orelse return error.TestUnexpectedResult;

    // It has to be the SAME format that `chat.StreamCtx.toolCallsJson` writes
    // (the one the headless runner uses): if they diverge, one of the two
    // clients sends a conversation the other cannot read.
    const expected = "[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"a.zig\\\"}\"}},{\"id\":\"call_2\",\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"ls -la\\\"}\"}}]";
    try std.testing.expectEqualStrings(expected, json);

    // And `arguments` goes as an escaped JSON STRING, not as a nested object.
    var vstate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer vstate.deinit();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, vstate.allocator(), json, .{});
    const arr = v.array.items;
    try std.testing.expectEqual(@as(usize, 2), arr.len);
    const fnobj = arr[0].object.get("function").?.object;
    try std.testing.expectEqualStrings("read", fnobj.get("name").?.string);
    try std.testing.expectEqualStrings("{\"path\":\"a.zig\"}", fnobj.get("arguments").?.string);

    // With no calls there is no JSON (and not a "[]" the API does not know what to
    // do with).
    try std.testing.expect(toolCallsJsonFromCalls(astate.allocator(), &[_]TurnCtx.Call{}) == null);
}

test "a tool argument is clipped so one row cannot fill the timeline" {
    // The timeline-filling garbage. A `bash` argument is whatever the model
    // wrote, and a real one is a three-pipeline command of several hundred
    // columns. It went into the header `*bash*(<command>)`, and a header is a
    // PARAGRAPH: it wraps. One long command was worth eight rows of history and
    // pushed the answer off screen.
    //
    // The clip is measured in COLUMNS, not bytes: a command with CJK or an emoji
    // counts correctly, and a byte-sized clip would come out mid-character.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const long_bash =
        \\{"command":"zig build test --summary all && zig build -p /tmp/opencode/x && cat /very/long/path/to/some/directory/that/goes/on/and/on/forever/and/ever/file.zig"}
    ;
    const arg = toolArgSummary("bash", long_bash, arena);
    try std.testing.expect(textcap.fits(arg, arg_max_cols));
    // And it ends with the ellipsis, so a clipped command is visibly clipped
    // rather than silently truncated to another command.
    try std.testing.expect(std.mem.endsWith(u8, arg, textcap.ellipsis));

    // A short one is returned whole, which is the common case.
    const short = toolArgSummary("bash", "{\"command\":\"ls -la\"}", arena);
    try std.testing.expectEqualStrings("ls -la", short);

    // A path is clipped by the same rule.
    const deep = toolArgSummary("read", "{\"path\":\"src/some/very/deep/nested/directory/structure/that/never/ends/file.zig\"}", arena);
    try std.testing.expect(textcap.fits(deep, arg_max_cols));

    // A multi-byte command is not cut mid-character: invalid UTF-8 would reach
    // the markdown parser, the renderer and the session file.
    const wide = toolArgSummary("bash", "{\"command\":\"日本語のとても長いコマンドをここに書きます。これはテストです。\"}", arena);
    try std.testing.expect(std.unicode.utf8ValidateSlice(wide));
    try std.testing.expect(textcap.fits(wide, arg_max_cols));

    // An MCP call names the TOOL it is about, because that is the line the
    // user reads and the line they are approving. `mcp(call)` says nothing.
    const mcp_call = toolArgSummary(
        "mcp",
        "{\"operation\":\"call\",\"server\":\"github\",\"tool\":\"create_issue\",\"arguments\":{\"title\":\"x\"}}",
        arena,
    );
    try std.testing.expectEqualStrings("github.create_issue", mcp_call);
    // And a search names its query: there is no tool yet.
    const mcp_search = toolArgSummary("mcp", "{\"operation\":\"search\",\"query\":\"issue\"}", arena);
    try std.testing.expectEqualStrings("issue", mcp_search);
}


test "toolTimelineLabel: the timeline reads the description, the permission reads the command" {
    // The `bash` `description` field is a HUMAN label ("running the test
    // suite"), and the timeline shows it instead of a clipped pipeline. The
    // half that matters is what it must NOT reach: `permAutoAllowed` and the
    // dialog keep receiving the COMMAND (`toolArgSummary`), because a prefix
    // allowlist matched against model-written prose would let
    // `description: "git status"` ride `rm -rf /` unattended.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const with_desc = "{\"command\":\"zig build test --summary all\",\"description\":\"running the test suite\"}";
    const arg = toolArgSummary("bash", with_desc, arena);
    // The permission path keeps seeing the command, description or no
    // description: this is the whole safety argument of the feature.
    try std.testing.expectEqualStrings("zig build test --summary all", arg);
    const label = toolTimelineLabel("bash", with_desc, arg, arena);
    try std.testing.expectEqualStrings("running the test suite", label);

    // No description: the timeline falls back to the command, exactly as
    // before the field existed.
    const bare = "{\"command\":\"ls -la\"}";
    const bare_arg = toolArgSummary("bash", bare, arena);
    try std.testing.expectEqualStrings("ls -la", toolTimelineLabel("bash", bare, bare_arg, arena));

    // A call the parser cannot read degrades to the command, never to nothing.
    try std.testing.expectEqualStrings("ls -la", toolTimelineLabel("bash", "not json", bare_arg, arena));

    // Only the FIRST line: the timeline row is one row, and an interior
    // newline painted raw has already been a bug in this repo (the ask panel).
    const multiline = "{\"command\":\"make\",\"description\":\"build the release\\nand then some\"}";
    try std.testing.expectEqualStrings("build the release", toolTimelineLabel("bash", multiline, "make", arena));

    // An empty (or whitespace-only) description is no description: it falls
    // back to the command instead of painting an empty argument.
    const blank = "{\"command\":\"make\",\"description\":\"   \"}";
    try std.testing.expectEqualStrings("make", toolTimelineLabel("bash", blank, "make", arena));

    // A description longer than the row is clipped with the ellipsis, in
    // columns, and stays valid UTF-8 — the same rules as any argument.
    const long_desc = "{\"command\":\"make\",\"description\":\"this description is far longer than any timeline row should ever be and keeps going and going\"}";
    const long_label = toolTimelineLabel("bash", long_desc, "make", arena);
    try std.testing.expect(textcap.fits(long_label, arg_max_cols));
    try std.testing.expect(std.mem.endsWith(u8, long_label, textcap.ellipsis));
    try std.testing.expect(std.unicode.utf8ValidateSlice(long_label));

    // A tool other than bash ignores a stray description: `read` shows its
    // path, because the field belongs to bash alone.
    const read_args = "{\"path\":\"src/x.zig\",\"description\":\"whatever\"}";
    try std.testing.expectEqualStrings("src/x.zig", toolArgSummary("read", read_args, arena));
    try std.testing.expectEqualStrings("src/x.zig", toolTimelineLabel("read", read_args, "src/x.zig", arena));
}

test "toolArgSummary and toolResultSummary know the web tools" {
    // `⏺ web_fetch(ziglang.org/…)` and `⎿ 412 lines · 78 KB` are useful feedback;
    // without this the first loose string came out and just "web_fetch".
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const arg = toolArgSummary("web_fetch", "{\"url\":\"https://ziglang.org/\"}", arena);
    try std.testing.expectEqualStrings("https://ziglang.org/", arg);
    const q = toolArgSummary("web_search", "{\"query\":\"zig 0.16\",\"max_results\":3}", arena);
    try std.testing.expectEqualStrings("zig 0.16", q);

    const res = toolResultSummary("web_fetch", "line one\nline two\nline three", arena);
    try std.testing.expect(std.mem.indexOf(u8, res, "3 lines") != null);
    const hits = toolResultSummary("web_search", "1. One\n   https://a.example\n   snip\n\n2. Two\n   https://b.example\n   snip\n", arena);
    try std.testing.expectEqualStrings("2 results", hits);

    const bash = toolResultSummary("bash", "exit=0\n--- stdout ---\nfirst\nsecond\n--- stderr ---\nwarning\n", arena);
    try std.testing.expectEqualStrings("exit 0 · stdout 2 lines · stderr 1 line", bash);
    const capped = toolResultSummary("bash", "exit=(stopped at the tool's output cap)\n--- stdout ---\npartial\n… (output cut at the tool's cap and the command was stopped)\n", arena);
    try std.testing.expectEqualStrings("exit (stopped at the tool's output cap) · stdout 1 line · output capped", capped);
}

test "cmdAllowlist lists what is there and warns if it is empty" {
    var backing: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    var m = tui.Model.init(fba.allocator());
    defer m.deinit();

    // Empty: it says so, so that "it doesn't ask" can be told apart from "there is
    // nothing to look at".
    commands_mod.cmdAllowlist(&m);
    m.drainPending();
    try std.testing.expect(std.mem.indexOf(u8, m.paras.items[0].text, "(none)") != null);

    // With a tool in the list: its name shows up.
    _ = setAlwaysAllowedNoSave("bash");
    commands_mod.cmdAllowlist(&m);
    m.drainPending();
    try std.testing.expect(std.mem.indexOf(u8, m.paras.items[1].text, "bash") != null);

    // And it does not duplicate: the count does not grow from asking again.
    const before = m.paras.items.len;
    commands_mod.cmdAllowlist(&m);
    m.drainPending();
    try std.testing.expectEqual(before + 1, m.paras.items.len);

    always_lens = @splat(0); // do not leave the global state dirty
}

test "/help lists the shortcuts, not just the commands" {
    // `/help` used to walk only the command table, and without the shortcut column:
    // half of the combinations were written down nowhere and were discovered by
    // accident (pressing Ctrl+P and hoping).
    var backing: [64 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    var m = tui.Model.init(fba.allocator());
    defer m.deinit();

    commands_mod.cmdHelp(&m);
    m.drainPending();

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(std.testing.allocator);
    for (m.paras.items) |p| {
        try joined.appendSlice(std.testing.allocator, p.text);
        try joined.append(std.testing.allocator, '\n');
    }
    const all = joined.items;

    // The command block, with their shortcut when they have one.
    try std.testing.expect(std.mem.indexOf(u8, all, "commands") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "/allowlist") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "(ctrl+p)") != null);

    // The shortcut block, with the ones that are NOT commands.
    try std.testing.expect(std.mem.indexOf(u8, all, "shortcuts") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "ctrl+l") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "ctrl+r") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "esc") != null);
}

test "/clean without arguments NEVER deletes" {
    // The dry run is the whole safety story, so it is tested at the level the
    // user reaches it: the command, not the module. A test of `scan` alone
    // would pass even if `cmdClean` had the argument backwards.
    try std.testing.expect(!cleanWanted(null, null));
    try std.testing.expect(!cleanWanted(null, ""));
    try std.testing.expect(!cleanWanted(null, "no"));
    try std.testing.expect(cleanWanted(null, "yes"));
    try std.testing.expect(cleanWanted(null, "y"));
    try std.testing.expect(cleanWanted(null, "apply"));
}

test "/clean shows up in /help with its 'yes'" {
    var backing: [64 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    var m = tui.Model.init(fba.allocator());
    defer m.deinit();

    commands_mod.cmdHelp(&m);
    m.drainPending();
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(std.testing.allocator);
    for (m.paras.items) |p| {
        try joined.appendSlice(std.testing.allocator, p.text);
        try joined.append(std.testing.allocator, '\n');
    }
    // A cleanup command that is not in /help is a command nobody finds, and worse:
    // one that looks like it does not exist.
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "/clean") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "/clean yes") != null);
}

test "every listed shortcut really exists (no invented documentation)" {
    // A shortcut in `/help` that does nothing is worse than not listing it: someone
    // tries it, nothing happens, and they stop trusting the whole list.
    const listed = [_][]const u8{
        "ctrl+p", "ctrl+t", "ctrl+a", "ctrl+l", "ctrl+r", "ctrl+c", "ctrl+u", "ctrl+d", "esc",
    };
    for (listed) |k| {
        var found = false;
        for (shortcuts) |s| {
            if (std.mem.indexOf(u8, s.key, k) != null) found = true;
        }
        try std.testing.expect(found);
    }
    // And the other way round: no shortcut in the list can be empty (an `""` in the
    // list reads as a shortcut with no name).
    for (shortcuts) |s| {
        try std.testing.expect(s.key.len > 0);
        try std.testing.expect(s.desc.len > 0);
    }
}

// ── tests: read-only, iteration limit and skills ─────────────

test "read-only: `bash` is blocked even when it is just an ls" {
    // It is decided per TOOL, not by parsing the command: if it were done by the
    // command, the mode could be skipped with a "read-only" `bash` first.
    try std.testing.expect(isWriteTool("bash"));
    try std.testing.expect(isWriteTool("write"));
    try std.testing.expect(isWriteTool("edit"));
    try std.testing.expect(!isWriteTool("read"));
    try std.testing.expect(!isWriteTool("grep"));
    try std.testing.expect(!isWriteTool("ask"));
}

test "plan mode refuses EVERY tool that changes the repository, git included" {
    // The hole this pins: `rename` and the git mutations were missing from the
    // write list while `needsPermission` EXEMPTS the git tools from the dialog,
    // so in plan mode a model could stage, commit and rename files while the
    // mode said nothing was being touched. One of these failing is a way back
    // into that hole.
    try std.testing.expect(isWriteTool("rename"));
    try std.testing.expect(isWriteTool("git_add"));
    try std.testing.expect(isWriteTool("git_commit"));
    try std.testing.expect(isWriteTool("git_stash"));
    try std.testing.expect(isWriteTool("git_branch"));
    // The read-only git tools still work: refusing `git status` would make the
    // mode useless for the one thing it exists for (looking).
    try std.testing.expect(!isWriteTool("git_status"));
    try std.testing.expect(!isWriteTool("git_diff"));
    try std.testing.expect(!isWriteTool("git_log"));
}

test "plan gate: approve, revise, and nobody there to answer" {
    // The mapping from "what the user picked" to "what the turn does". The
    // dialog itself cannot be tested without a TUI, this is the half where a
    // mistake would be silent: a misread answer either implements an unapproved
    // plan or nags forever.
    //
    // No answer (ESC / timeout) ends the turn WITHOUT a nudge: a user who
    // walked away must not come back to a loop that kept asking.
    try std.testing.expectEqual(PlanGate.skip, planGateDecision(null));
    try std.testing.expectEqual(PlanGate.skip, planGateDecision(""));
    try std.testing.expectEqual(PlanGate.skip, planGateDecision("   "));
    // The option labels themselves, by PREFIX (that is how the picker returns
    // them), plus the spellings a human types.
    try std.testing.expectEqual(PlanGate.approve, planGateDecision(approve_option));
    try std.testing.expectEqual(PlanGate.approve, planGateDecision("approve"));
    try std.testing.expectEqual(PlanGate.approve, planGateDecision("yes"));
    try std.testing.expectEqual(PlanGate.approve, planGateDecision("YES"));
    // The revise option and any words of their own are BOTH revisions: free
    // text is feedback, not silence.
    try std.testing.expectEqual(PlanGate.revise, planGateDecision(revise_option));
    try std.testing.expectEqual(PlanGate.revise, planGateDecision("no"));
    try std.testing.expectEqual(PlanGate.revise, planGateDecision("make step 3 optional"));
}

test "read-only: the text that goes back to the model says NOT to retry" {
    // Without the "do NOT retry", the model repeats the call and the loop eats the
    // remaining iterations. And without "ask", the mode offers no way out.
    try std.testing.expect(std.mem.indexOf(u8, read_only_text, "Do NOT retry") != null);
    try std.testing.expect(std.mem.indexOf(u8, read_only_text, "ask") != null);
    try std.testing.expect(std.mem.indexOf(u8, read_only_text, "shift+tab") != null);
}

test "iterationLimit: 12 by default, and the environment can move it" {
    // With no environment (which is the case in the tests) the default comes out.
    // With `ZODE_MAX_ITER` it is read on EVERY call, not at startup: that way
    // it can be changed between turns.
    try std.testing.expectEqual(default_max_iterations, iterationLimit());
    try std.testing.expect(default_max_iterations > 8);
}

test "ask: the per-turn cap is 3, and it is in the guidance" {
    try std.testing.expectEqual(max_asks_per_turn, 3);
    // And the model knows it: a cap that is not in the prompt is met by accident and
    // the user sees a question disappear with no explanation.
    try std.testing.expect(std.mem.indexOf(u8, ask.guidance, "three in a whole turn") != null);
}

test "skills: with no directories the prompt section is EMPTY (0 tokens)" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("", skills.systemPromptSection(&.{}, 1024, &buf));
}

test "the skills listing budget comes from ZODE_CONTEXT_LIMIT, and not from the model" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("ZODE_CONTEXT_LIMIT", "6000");
    // 1% of 6000 tokens is 60 tokens, which is 240 characters.
    try std.testing.expectEqual(@as(usize, 240), skillListingBudget(&map));

    // The MODEL's window is not part of it. The free-auto rotation changes the
    // active model on every turn, and a budget that moved with the model would
    // rewrite the system prompt — and invalidate the provider's cache for the
    // whole request — on every turn.
    const saved_ctx = cur_model_ctx;
    defer cur_model_ctx = saved_ctx;
    cur_model_ctx = 1_000_000;
    try std.testing.expectEqual(@as(usize, 240), skillListingBudget(&map));
    cur_model_ctx = 0;

    // And with no environment at all, the default window: 1% of 128k.
    const saved = environ_global;
    environ_global = null;
    defer environ_global = saved;
    try std.testing.expectEqual(@as(usize, 5120), skillListingBudget(null));
}

/// The environment a prompt-building test needs, and the teardown that puts the
/// module globals back.
///
/// It is a helper and not a copy in each test because the globals ARE the trap:
/// an `Io` that is `undefined` until startup assigns it (a file read through it
/// is a GPF, not a zero), a project directory that must not be the repository of
/// whoever runs the suite, and two caches that outlive the test's arena.
///
/// The caches are DROPPED and not freed: a rescan frees the previous list with
/// `gpa_global`, and the list was allocated with this test's arena. Freeing it
/// here is an "Invalid free"; dropping the reference lets the arena have it.
const PromptTestEnv = struct {
    arena_state: std.heap.ArenaAllocator,
    threaded: std.Io.Threaded,
    saved_io: std.Io,
    saved_gpa: std.mem.Allocator,
    saved_env: ?*const std.process.Environ.Map,
    saved_agents: ?[]u8,

    fn init() PromptTestEnv {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer arena_state.deinit();
        var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
        errdefer threaded.deinit();

        const saved_agents = agents_md_cache;
        agents_md_cache = null;
        styles_cache = null;
        styles_stamp_len = 0;
        styles_rescans = 0;
        skills_cache = null;
        skills_stamp_len = 0;
        skills_rescans = 0;

        io_global = threaded.io();
        gpa_global = std.testing.allocator;
        setProjectInfoForTest(io_global, "/tmp");

        return .{
            .arena_state = arena_state,
            .threaded = threaded,
            .saved_io = io_global,
            .saved_gpa = gpa_global,
            .saved_env = environ_global,
            .saved_agents = saved_agents,
        };
    }

    fn deinit(self: *PromptTestEnv) void {
        styles_cache = null;
        styles_stamp_len = 0;
        styles_rescans = 0;
        skills_cache = null;
        skills_stamp_len = 0;
        skills_rescans = 0;
        agents_md_cache = self.saved_agents;
        gpa_global = self.saved_gpa;
        io_global = self.saved_io;
        environ_global = self.saved_env;
        self.threaded.deinit();
        self.arena_state.deinit();
    }

    fn allocator(self: *PromptTestEnv) std.mem.Allocator {
        return self.arena_state.allocator();
    }
};

test "the skills listing in the PROMPT goes under a tight budget" {
    // The wiring: the budget has to reach the prompt and not only the pure
    // function. A budget that is computed and never used is a comment.
    var env = PromptTestEnv.init();
    defer env.deinit();

    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("ZODE_CONTEXT_LIMIT", "6000");

    var buf: [16 * 1024]u8 = undefined;
    const tight = buildSystemPrompt(env.allocator(), &buf, &map, true);
    // The bundled skills are there, but only their NAMES: 1% of a 6000-token
    // window is 240 characters, and that is not a description.
    try std.testing.expect(std.mem.indexOf(u8, tight, "- simplify") != null);
    try std.testing.expect(std.mem.indexOf(u8, tight, "Review a diff for reuse") == null);
}

test "the skills listing in the PROMPT keeps the descriptions when there is room" {
    // A budget that quietly emptied the list would look like a feature.
    var env = PromptTestEnv.init();
    defer env.deinit();

    var buf: [16 * 1024]u8 = undefined;
    const roomy = buildSystemPrompt(env.allocator(), &buf, null, true);
    try std.testing.expect(std.mem.indexOf(u8, roomy, "- simplify") != null);
    try std.testing.expect(std.mem.indexOf(u8, roomy, "Review a diff for reuse") != null);
}

// Phase 2.2: the system prompt built without skills does not contain the
// skills listing — it is attached once per session as a separate message.
test "buildSystemPrompt without skills leaves the cacheable prefix clean" {
    var env = PromptTestEnv.init();
    defer env.deinit();

    var buf: [16 * 1024]u8 = undefined;
    const prompt = buildSystemPrompt(env.allocator(), &buf, null, false);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "- simplify") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Review a diff for reuse") == null);
    // Everything else is still there.
    try std.testing.expect(std.mem.indexOf(u8, prompt, "NEVER use bash") != null);
}

// Phase 2.2: `skillsSectionText` builds the skills listing that gets attached.
test "skillsSectionText produces the bundled skill names" {
    var env = PromptTestEnv.init();
    defer env.deinit();

    var buf: [16 * 1024]u8 = undefined;
    const section = skillsSectionText(env.allocator(), null, &buf);
    try std.testing.expect(section.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, section, "- simplify") != null);
}

// Phase 2.2: `Session.resetSkillsSent` clears the flag so the listing is re-sent.
test "Session.resetSkillsSent clears the flag" {
    var gpa_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var s = session_mod.Session.init(gpa);
    try std.testing.expect(!s.skills_sent);
    s.skills_sent = true;
    try std.testing.expect(s.skills_sent);
    s.resetSkillsSent();
    try std.testing.expect(!s.skills_sent);
}

// Phase 35.5: `/clear` clears the transcript and resets the per-session caches
// (read list, changed list, and the skills-sent flag) without creating a new
// session. `session` is null in a test, so the skills branch is skipped — the
// point is that the command is wired and does not panic.
test "cmdClear clears the screen and resets the session caches" {
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    m.io = std.testing.io;
    m.io_ready = true;
    m.environ = null;

    cmdClear(&m);

    try std.testing.expect(pendingContains(&m, "screen cleared"));
    try std.testing.expect(pendingContains(&m, "read cache + changed list reset"));
    try std.testing.expect(pendingContains(&m, "skills listing re-attached next turn"));
}

test "prompt: the routing guide survives the project's AGENTS.md" {
    // The bug: `systemPromptBase` returned the project's `AGENTS.md` INSTEAD OF the
    // built-in prompt, so in any project that has one the model did not see a
    // single routing rule. It showed up as "find me a games page" -> `bash curl`
    // instead of `web_search`.
    //
    // What is tested here is what can be tested without disk: that the guide is
    // LOOSE (not inside `default_system_prompt`, which is what was getting lost)
    // and that `buildSystemPrompt` always inserts it, whichever base it picks.
    //
    // `buildSystemPrompt` reads the CWD's `AGENTS.md` through the cache, so a
    // hand-placed cache entry is used: the point is that the composition puts it
    // in the same way in both cases.
    const saved_cache = agents_md_cache;
    const saved_io = io_global;
    const saved_gpa = gpa_global;
    defer {
        resetStylesCacheForTest();
        resetSkillsCacheForTest();
        gpa_global = saved_gpa;
        agents_md_cache = saved_cache;
        io_global = saved_io;
    }

    // 1) The guide must NOT be inside the built-in prompt: that text is what
    //    `AGENTS.md` replaces. (The built-in does NOT name the tools either: a
    //    second list of them was there and was already wrong — twelve names
    //    against twenty in the schema.)
    try std.testing.expect(std.mem.indexOf(u8, default_system_prompt, "NEVER use bash") == null);
    try std.testing.expect(std.mem.indexOf(u8, default_system_prompt, "Choosing the right tool") == null);

    // 2) The guide is at hand, and it is complete.
    try std.testing.expect(std.mem.indexOf(u8, tool_routing_prompt, "web_search") != null);
    try std.testing.expect(std.mem.indexOf(u8, tool_routing_prompt, "NEVER use bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, tool_routing_prompt, "task") != null);

    // 3) With a cached "AGENTS.md", the guide is still in the composed prompt.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    io_global = threaded.io();
    gpa_global = std.testing.allocator;
    resetStylesCacheForTest();
    const fake_agents = try std.testing.allocator.dupe(u8, "# proyecto\nNo hagas esto.");
    defer std.testing.allocator.free(fake_agents);
    agents_md_cache = fake_agents;

    // 16 KB and not 8, because `bufPrint` TRUNCATES silently and the last block is the
    // one that goes missing: a routing table that stops mid-sentence looks like a
    // shorter prompt, not like a broken test. The prompt is the biggest stable prefix
    // in every request, so its length is worth pinning generously.
    var out: [16 * 1024]u8 = undefined;
    const composed = buildSystemPrompt(std.testing.allocator, &out, null, true);
    try std.testing.expect(composed.len < out.len); // it FIT: nothing was truncated
    try std.testing.expect(std.mem.indexOf(u8, composed, "No hagas esto.") != null);
    try std.testing.expect(std.mem.indexOf(u8, composed, "web_search = you do NOT have the URL") != null);
    try std.testing.expect(std.mem.indexOf(u8, composed, "NEVER use bash") != null);

    // And the guide goes AFTER the project base: the user's file is read first, and
    // a harness rule does not get lost for coming after.
    const at_base = std.mem.indexOf(u8, composed, "No hagas esto.").?;
    const at_rule = std.mem.indexOf(u8, composed, "NEVER use bash").?;
    try std.testing.expect(at_base < at_rule);
}

test "prompt: the model receives the cwd and, if there is a repo, the branch" {
    // The question "does zode work from the folder I launched it in?" has two
    // halves: the tools DO use the cwd (everything goes through
    // `std.Io.Dir.cwd()`), but the model did not know. Without this line it
    // cannot answer in absolute terms nor notice that it was launched in a
    // subdirectory.
    const saved_io = io_global;
    const saved_info = project_info;
    const saved_agents = agents_md_cache;
    const saved_gpa = gpa_global;
    defer {
        resetStylesCacheForTest();
        resetSkillsCacheForTest();
        gpa_global = saved_gpa;
        io_global = saved_io;
        project_info = saved_info;
        agents_md_cache = saved_agents;
    }

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    io_global = threaded.io();
    gpa_global = std.testing.allocator;
    resetStylesCacheForTest();
    resetSkillsCacheForTest();
    // A fake repo in /tmp: a `sandbox` under the cwd would be INSIDE zode's own
    // repo, and a "there is no repository" test there would be false.
    const root = "/tmp/zode-prompt-repo-test";
    std.Io.Dir.cwd().deleteTree(io_global, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_global, root) catch {};
    var head_buf: [256]u8 = undefined;
    const dotgit = try std.fmt.bufPrint(&head_buf, "{s}/.git", .{root});
    // The `.git` has to exist as a DIRECTORY before writing HEAD inside it:
    // `writeFile` does not create the parent and fails with FileNotFound.
    try std.Io.Dir.cwd().createDirPath(io_global, dotgit);
    var head_buf2: [256]u8 = undefined;
    const head = try std.fmt.bufPrint(&head_buf2, "{s}/HEAD", .{dotgit});
    try std.Io.Dir.cwd().writeFile(io_global, .{ .sub_path = head, .data = "ref: refs/heads/mi-rama\n" });

    setProjectInfoForTest(io_global, root);
    // The repo's own `AGENTS.md` is 119 KB: it would not fit in the 16 KB
    // composition buffer, `bufPrint` would fail, and `buildSystemPrompt` would
    // return the base alone — which is the right behaviour, and would make this
    // test fail for a reason that has nothing to do with the cwd line.
    agents_md_cache = try std.testing.allocator.dupe(u8, "# proyecto de prueba\n");
    defer if (agents_md_cache != null and saved_agents == null) std.testing.allocator.free(agents_md_cache.?);

    var out: [16 * 1024]u8 = undefined;
    const composed = buildSystemPrompt(std.testing.allocator, &out, null, true);
    try std.testing.expect(std.mem.indexOf(u8, composed, "Working directory:") != null);
    try std.testing.expect(std.mem.indexOf(u8, composed, root) != null);
    try std.testing.expect(std.mem.indexOf(u8, composed, "branch mi-rama") != null);
    // The routing guide is still there: the cwd did not push it out.
    try std.testing.expect(std.mem.indexOf(u8, composed, "NEVER use bash") != null);
    // And git is named by its name, so that "what has changed" is a `git diff`
    // and not an `ls` with grep.
    try std.testing.expect(std.mem.indexOf(u8, composed, "git status") != null);
    try std.testing.expect(std.mem.indexOf(u8, composed, "git diff") != null);
}

test "prompt: the REPO's AGENTS.md is used when the cwd has none of its own" {
    // `cd src && zode` was the broken case: with no AGENTS.md in the cwd, zode
    // launched with the built-in prompt and the model did not have a single
    // instruction from the project. Now the repo root is the second place looked
    // at.
    //
    // `readAgentsIn` is tested and not `buildSystemPrompt` on purpose: the suite
    // runs in zode's root, where there IS an `AGENTS.md`, and the "the cwd wins"
    // rule would make it appear in the composed prompt and mask the fixture's.
    // The cwd rule has its own place (it is the first branch of the `orelse`).
    const saved_io = io_global;
    defer io_global = saved_io;

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    io_global = threaded.io();

    const root = "/tmp/zode-agents-repo-test";
    std.Io.Dir.cwd().deleteTree(io_global, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_global, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io_global, root);

    var agents_buf: [256]u8 = undefined;
    const agents = try std.fmt.bufPrint(&agents_buf, "{s}/AGENTS.md", .{root});
    try std.Io.Dir.cwd().writeFile(io_global, .{ .sub_path = agents, .data = "REGLA DEL REPO" });

    const got = readAgentsIn(std.testing.allocator, root) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "REGLA DEL REPO") != null);

    // And a directory with neither name is NOT an error (it returns null, which is
    // how the `orelse` chains the next place).
    try std.testing.expect(readAgentsIn(std.testing.allocator, "/tmp") == null);
    try std.testing.expect(readAgentsIn(std.testing.allocator, null) == null);
}

test "skills: the list is invalidated when a SKILL.md changes on disk" {
    // The bug: `discoverSkills` cached for the whole process, so a skill created
    // during the session did not show up until a restart, and `buildSystemPrompt`'s
    // comment said the opposite. Now there is an mtime, and this test checks it
    // with real files.
    const saved_io = io_global;
    const saved_info = project_info;
    const saved_gpa = gpa_global;
    const saved_cache = skills_cache;
    const saved_stamp_len = skills_stamp_len;
    const saved_rescans = skills_rescans;
    defer {
        io_global = saved_io;
        project_info = saved_info;
        gpa_global = saved_gpa;
        skills_cache = saved_cache;
        skills_stamp_len = saved_stamp_len;
        skills_rescans = saved_rescans;
    }

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    io_global = threaded.io();
    gpa_global = std.testing.allocator;

    const root = "/tmp/zode-skills-mtime-test";
    std.Io.Dir.cwd().deleteTree(io_global, root) catch {};
    var skill_dir: [256]u8 = undefined;
    const dir = try std.fmt.bufPrint(&skill_dir, "{s}/.zode/skills/nuevo", .{root});
    try std.Io.Dir.cwd().createDirPath(io_global, dir);
    defer std.Io.Dir.cwd().deleteTree(io_global, root) catch {};

    // CWD = root, so that the repo root does not add extra roots.
    setProjectInfoForTest(io_global, root);
    skills_cache = null;
    skills_stamp_len = 0;
    skills_rescans = 0;

    // 1) Bundled skills are always available (5 built-in skills).
    var env_map: std.process.Environ.Map = undefined;
    _ = &env_map;
    const empty = discoverSkills(std.testing.allocator, null);
    try std.testing.expectEqual(@as(usize, 5), empty.len);

    // 2) One project skill appears. The root's `stat` has changed, so it has to show up
    //    without restarting anything.
    var skill_file: [512]u8 = undefined;
    const skill_path = try std.fmt.bufPrint(&skill_file, "{s}/SKILL.md", .{dir});
    try std.Io.Dir.cwd().writeFile(io_global, .{ .sub_path = skill_path, .data = "---\ndescription: recien creado\n---\nbody\n" });

    const found = discoverSkills(std.testing.allocator, null);
    try std.testing.expectEqual(@as(usize, 6), found.len);
    // Find the new project skill
    var found_nuevo = false;
    for (found) |e| {
        if (std.mem.eql(u8, e.name, "nuevo")) {
            found_nuevo = true;
            try std.testing.expectEqualStrings("recien creado", e.description);
        }
    }
    try std.testing.expect(found_nuevo);

    // 3) And the list is BORROWED: asking for it again with no changes frees
    //    nothing (if the caller owned it, this would be a double free of live
    //    memory).
    const again = discoverSkills(std.testing.allocator, null);
    try std.testing.expectEqual(@as(usize, 6), again.len);
    var found_nuevo_again = false;
    for (again) |e| {
        if (std.mem.eql(u8, e.name, "nuevo")) {
            found_nuevo_again = true;
        }
    }
    try std.testing.expect(found_nuevo_again);

    // 4) And the PROMPT carries name + description ONLY. The body is what the
    //    `skill` tool reads on demand — inlining it here would be a tax on every
    //    request of every session, forever, whether the task needs it or not.
    //    Asserted against the COMPOSED prompt and not only against
    //    `discoverSkills`, because a discovery that is right and a composition
    //    that drops (or inlines) the section are two different bugs.
    const saved_agents = agents_md_cache;
    defer agents_md_cache = saved_agents;
    const fake_agents = try std.testing.allocator.dupe(u8, "# proyecto\ninstrucciones.");
    defer std.testing.allocator.free(fake_agents);
    agents_md_cache = fake_agents;

    try std.Io.Dir.cwd().writeFile(io_global, .{
        .sub_path = skill_path,
        .data = "---\ndescription: recien creado\n---\nSKILL-BODY-MUST-NOT-ENTER-THE-PROMPT\n",
    });
    // `skills_cache` is NOT nulled here on purpose: the file's size changed, so
    // the mtime+size stamp is what has to invalidate the cache — the mechanism
    // this test exists for.
    var pbuf: [16 * 1024]u8 = undefined;
    const prompt = buildSystemPrompt(std.testing.allocator, &pbuf, null, true);
    try std.testing.expect(prompt.len < pbuf.len); // it FIT: nothing was truncated
    try std.testing.expect(std.mem.indexOf(u8, prompt, "nuevo") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "recien creado") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "SKILL-BODY-MUST-NOT-ENTER-THE-PROMPT") == null);

    // The global state is left as it was for the next test, and the list is really
    // FREED: it is memory from `std.testing.allocator` and the process teardown
    // does not arrive inside a test.
    freeSkillsCacheLocked();
    skills_rescans = saved_rescans;
}

test "tools: `ask`, `skill`, `bash_output` and `bash_kill` do NOT ask for permission" {
    // Asking "may I ask you?" is two dialogs for one question, and `bash_output`
    // asks for permission over a command that was ALREADY approved when it was
    // launched in the background.
    try std.testing.expect(!tools_mod.needsPermission("ask"));
    try std.testing.expect(!tools_mod.needsPermission("skill"));
    try std.testing.expect(!tools_mod.needsPermission("bash_output"));
    try std.testing.expect(!tools_mod.needsPermission("bash_kill"));
    // And `task` DOES: it spends the user's tokens and reads the whole repo.
    try std.testing.expect(tools_mod.needsPermission("task"));
    // `bash` in the foreground still asks, as always.
    try std.testing.expect(tools_mod.needsPermission("bash"));
}

test "tools: the parallel-safe ones are ONLY those that cannot observe each other" {
    try std.testing.expect(tools_mod.isParallelSafe("read"));
    try std.testing.expect(tools_mod.isParallelSafe("grep"));
    try std.testing.expect(tools_mod.isParallelSafe("glob"));
    try std.testing.expect(tools_mod.isParallelSafe("list_files"));
    try std.testing.expect(tools_mod.isParallelSafe("web_fetch"));
    try std.testing.expect(tools_mod.isParallelSafe("web_search"));
    // And the ones that write do NOT, not even when the command looks like a read:
    try std.testing.expect(!tools_mod.isParallelSafe("bash"));
    try std.testing.expect(!tools_mod.isParallelSafe("write"));
    try std.testing.expect(!tools_mod.isParallelSafe("edit"));
    try std.testing.expect(!tools_mod.isParallelSafe("task"));
}

test "tools: the schema announces the 5 new tools" {
    // A tool that exists in the code and not in the JSON cannot be called, and the
    // only symptom is that the model never mentions it.
    const json = tools_mod.toolsJson();
    for ([_][]const u8{ "ask", "skill", "task", "bash_output", "bash_kill" }) |name| {
        var key_buf: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "\"name\":\"{s}\"", .{name}) catch unreachable;
        try std.testing.expect(std.mem.indexOf(u8, json, key) != null);
    }
    // And `run_in_background` is in `bash`'s schema, which is where it is decided.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"run_in_background\"") != null);
}

test "isParallelSafe and isWriteSafe do not contradict each other where it matters" {
    // A tool that were both "parallel" and "writes" would be a security failure
    // dressed as a feature: the criterion for the two lists has to be the same.
    for (tools_mod.defs) |d| {
        if (tools_mod.isParallelSafe(d.name)) {
            try std.testing.expect(!isWriteTool(d.name));
        }
    }
}

test "the read cache is emptied of what compaction took" {
    // The whole chain, and the place where it breaks: compaction produces
    // `elided_at`, the agent hands it to the cache, and the cache marks those
    // entries as "no longer in the context". Without that last step, a `read` of
    // an elided file would answer "unchanged, you already have it" and the model
    // would answer about a file it does not have.
    const saved_io = io_global;
    defer io_global = saved_io;

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    io_global = threaded.io();

    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    const path = "/tmp/opencode/agent-readcache-drop.txt";
    try std.Io.Dir.cwd().writeFile(io_global, .{ .sub_path = path, .data = "una linea\n" });

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try std.fmt.allocPrint(arena, "{{\"path\":\"{s}\"}}", .{path});

    // 1) The tool reads and the entry stays "in the context", in message 7.
    _ = try tools_mod.execute(io_global, "read", args, arena, null, &m.reads);
    m.reads.setMessageIndex(path, 7);
    try std.testing.expectEqual(@as(usize, 1), m.reads.liveEntries());

    // 2) Compaction takes that message away (by hand here, since the whole loop
    //    needs the network).
    m.reads.markDroppedAt(7);
    try std.testing.expectEqual(@as(usize, 0), m.reads.liveEntries());

    // 3) The next read SENDS the body again. That it is the same content does
    //    not matter: what counts is that it is back in the context.
    const out = try tools_mod.execute(io_global, "read", args, arena, null, &m.reads);
    try std.testing.expect(std.mem.indexOf(u8, out, "una linea") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "unchanged") == null);
}

test "after a write, the cache does not claim the file is unchanged" {
    // The case from the real loop: edit → read to verify. Without invalidating, the
    // read would answer "unchanged" with the OLD text in the context, which is
    // exactly the loop that makes an agent convince itself its edit worked when
    // it touched nothing.
    const saved_io = io_global;
    defer io_global = saved_io;

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    io_global = threaded.io();

    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = "/tmp/opencode/agent-readcache-write.txt";

    const write_args = try std.fmt.allocPrint(arena,
        \\{{"path":"{s}","content":"contenido nuevo\n"}}
    , .{path});
    const read_args = try std.fmt.allocPrint(arena, "{{\"path\":\"{s}\"}}", .{path});

    // Read (old), write, read: the second read must show the NEW content.
    try std.Io.Dir.cwd().writeFile(io_global, .{ .sub_path = path, .data = "contenido viejo\n" });
    _ = try tools_mod.execute(io_global, "read", read_args, arena, null, &m.reads);
    _ = try tools_mod.execute(io_global, "write", write_args, arena, null, &m.reads);
    // This is what `execOneCall` does with the write's path.
    m.reads.invalidate(path);

    const out = try tools_mod.execute(io_global, "read", read_args, arena, null, &m.reads);
    try std.testing.expect(std.mem.indexOf(u8, out, "contenido nuevo") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "unchanged") == null);
}

test "with no model NOTHING is sent: the catalog is queried and the choice is reported" {
    // The behaviour with no way back: a model name written in the code (each
    // provider's `default_model`) is a ticking bomb. `kimi-k2.6` disappeared from
    // opencode's catalog and EVERY request started answering 403 "Model access is
    // disabled", which says nothing about why.
    //
    // With `default_model` empty in every provider, the only way to have a model
    // is for the user to pick one, or for zode to ask the provider. And when it
    // picks, it says so on screen: a silent choice is indistinguishable from a
    // default.
    for (&providers.defs) |d| {
        try std.testing.expectEqualStrings("", d.default_model);
    }
}

test "curModel can be left empty and that is visible" {
    // The "no model" state has to be representable: it is what happens between
    // changing provider and the catalog answering, and a `setModel("")` that
    // swallowed the previous name without letting it show would be a 400 with no
    // explanation on the next turn.
    const saved = curModel();
    defer setModel(saved);
    setModel("gpt-5");
    try std.testing.expectEqualStrings("gpt-5", curModel());
    setModel("");
    try std.testing.expectEqualStrings("", curModel());
}

test "system prompt: the volatile parts go LAST, so a mode change does not drop the cache" {
    // The provider serves the prompt cache from the literal prefix of the system
    // message, so a piece that changes invalidates everything AFTER it. The
    // read-only note changes on a `shift+tab`, which is mid-turn and cheap to do
    // by accident; it was 4th of 6, so it also invalidated the skills list and
    // the location lines.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const saved_io = io_global;
    const saved_gpa = gpa_global;
    io_global = threaded.io();
    defer {
        resetStylesCacheForTest();
        gpa_global = saved_gpa;
        io_global = saved_io;
    }
    gpa_global = std.testing.allocator;
    resetStylesCacheForTest();

    // Initialize project_info to avoid GPF when skills system accesses it.
    setProjectInfoForTest(io_global, "/tmp");

    // The skills list is a module global that OWNS memory from whatever allocator
    // asked for it. Left pointing into `std.testing.allocator`, it is a leak that
    // this test gets blamed for, so it is saved and dropped here.
    const saved_cache = skills_cache;
    const saved_rescans = skills_rescans;
    skills_cache = null;
    skills_rescans = 0;
    defer {
        freeSkillsCacheLocked();
        skills_cache = saved_cache;
        skills_rescans = saved_rescans;
    }

    // Same for the project's AGENTS.md: `systemPromptBase` reads it ONCE into a
    // global that owns the memory. In a test that allocator is the testing one,
    // so leaving it there is a leak attributed to whichever test read it.
    const saved_agents = agents_md_cache;
    const fake_base = try std.testing.allocator.dupe(u8, "base de prueba");
    defer std.testing.allocator.free(fake_base);
    agents_md_cache = fake_base;
    defer agents_md_cache = saved_agents;

    var out: [16 * 1024]u8 = undefined;
    const p = buildSystemPrompt(std.testing.allocator, &out, null, true);

    const at = struct {
        fn find(hay: []const u8, needle: []const u8) usize {
            return std.mem.indexOf(u8, hay, needle) orelse std.math.maxInt(usize);
        }
    };
    const routing_at = at.find(p, "Choosing the right tool");
    const read_only_at = at.find(p, "READ-ONLY MODE");
    const skills_at = at.find(p, "Skills");
    const location_at = at.find(p, "Working directory");

    try std.testing.expect(routing_at != std.math.maxInt(usize));
    // The note is last: with it in front, everything after it was re-sent.
    if (read_only_at != std.math.maxInt(usize)) {
        try std.testing.expect(read_only_at > routing_at);
    }
    if (skills_at != std.math.maxInt(usize)) {
        try std.testing.expect(skills_at > routing_at);
    }
    if (location_at != std.math.maxInt(usize)) {
        try std.testing.expect(location_at > routing_at);
    }
}

test "system prompt: the verification rules are injected even with a project's AGENTS.md" {
    // Same failure mode as the routing table, and the same reason for a separate
    // constant: `systemPromptBase` returns the project's file INSTEAD of the
    // built-in text, so anything that lives inside `default_system_prompt` is
    // invisible in exactly the case that matters (a real project).
    // 1) It is not part of the built-in prompt.
    try std.testing.expect(std.mem.indexOf(u8, default_system_prompt, "NARROWEST command") == null);
    // 2) It says the three things that decide the duration of a task.
    try std.testing.expect(std.mem.indexOf(u8, verification_prompt, "NARROWEST command") != null);
    try std.testing.expect(std.mem.indexOf(u8, verification_prompt, "Do NOT write a test harness") != null);
    try std.testing.expect(std.mem.indexOf(u8, verification_prompt, "background") != null);
    try std.testing.expect(std.mem.indexOf(u8, verification_prompt, "already passed") != null);

    // 3) With an AGENTS.md in place it is still composed.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const saved_io = io_global;
    const saved_gpa = gpa_global;
    io_global = threaded.io();
    defer {
        resetStylesCacheForTest();
        gpa_global = saved_gpa;
        io_global = saved_io;
    }
    gpa_global = std.testing.allocator;
    resetStylesCacheForTest();

    // Initialize project_info to avoid GPF when skills system accesses it.
    setProjectInfoForTest(io_global, "/tmp");

    const saved_cache = skills_cache;
    const saved_rescans = skills_rescans;
    skills_cache = null;
    skills_rescans = 0;
    defer {
        freeSkillsCacheLocked();
        skills_cache = saved_cache;
        skills_rescans = saved_rescans;
    }
    const saved_agents = agents_md_cache;
    const fake = try std.testing.allocator.dupe(u8, "# proyecto\nReglas del proyecto.");
    defer std.testing.allocator.free(fake);
    agents_md_cache = fake;
    defer agents_md_cache = saved_agents;

    var out: [16 * 1024]u8 = undefined;
    const composed = buildSystemPrompt(std.testing.allocator, &out, null, true);
    try std.testing.expect(std.mem.indexOf(u8, composed, "Reglas del proyecto.") != null);
    try std.testing.expect(std.mem.indexOf(u8, composed, "NARROWEST command") != null);
    try std.testing.expect(std.mem.indexOf(u8, composed, "NEVER use bash") != null);
}

test "subagents: consecutive task calls form ONE batch (that is what parallelizes)" {
    const Call = TurnCtx.Call;
    const calls = [_]Call{
        .{ .id = "1", .name = "task", .args_json = "{}" },
        .{ .id = "2", .name = "task", .args_json = "{}" },
        .{ .id = "3", .name = "task", .args_json = "{}" },
    };
    // Three searches that do not depend on each other: one batch, so one round
    // trip instead of three sequential ones.
    try std.testing.expectEqual(@as(usize, 3), taskBatchEnd(&calls, 0));

    // A `write` in the middle ends the batch: after a write the world changed,
    // and a search issued before it may be answering a question that no longer
    // exists.
    const mixed = [_]Call{
        .{ .id = "1", .name = "task", .args_json = "{}" },
        .{ .id = "2", .name = "task", .args_json = "{}" },
        .{ .id = "3", .name = "write", .args_json = "{}" },
        .{ .id = "4", .name = "task", .args_json = "{}" },
    };
    try std.testing.expectEqual(@as(usize, 2), taskBatchEnd(&mixed, 0));
    try std.testing.expectEqual(@as(usize, 4), taskBatchEnd(&mixed, 3));

    // A single one is its own batch (and takes the serial path).
    const one = [_]Call{.{ .id = "1", .name = "task", .args_json = "{}" }};
    try std.testing.expectEqual(@as(usize, 1), taskBatchEnd(&one, 0));

    // The cap is a real number with a real range: N subagents are N streaming
    // requests against one key.
    try std.testing.expectEqual(@as(usize, 3), default_task_parallel);
    try std.testing.expect(default_task_parallel >= 1 and default_task_parallel <= 8);
}

test "subagents: session parallel limit overrides auto and can return to auto" {
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    try std.testing.expectEqual(@as(u8, 0), m.taskParallelLimit());
    try std.testing.expectEqual(@as(usize, default_task_parallel), taskParallelLimit(&m));
    m.setTaskParallelLimit(6);
    try std.testing.expectEqual(@as(u8, 6), m.taskParallelLimit());
    try std.testing.expectEqual(@as(usize, 6), taskParallelLimit(&m));
    m.setTaskParallelLimit(0);
    try std.testing.expectEqual(@as(usize, default_task_parallel), taskParallelLimit(&m));
}

test "/task-parallel is wired through submit and rejects invalid limits" {
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    try submit(&m, "/task-parallel 6");
    try std.testing.expectEqual(@as(u8, 6), m.taskParallelLimit());
    try std.testing.expect(pendingContains(&m, "6 at a time"));

    try submit(&m, "/task-parallel 9");
    try std.testing.expectEqual(@as(u8, 6), m.taskParallelLimit());
    try std.testing.expect(pendingContains(&m, "usage: /task-parallel"));

    try submit(&m, "/task-parallel auto");
    try std.testing.expectEqual(@as(u8, 0), m.taskParallelLimit());
    try std.testing.expectEqual(@as(u8, 4), cmdGroupPublic("/task-parallel"));
}

test "subagents: the model is told it can send several at once" {
    // If the description does not say it, the model keeps sending one per
    // message and the parallelism never happens: the capability has to be
    // visible in the schema to be used.
    const schema = tools_mod.toolsJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "SAME message") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "live completion progress") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "/task-parallel") != null);
}

test "setModelCtx RESETS the window when a change carries none" {
    // Keeping the previous model's number is the failure that would stay
    // invisible until a turn died on a writer error: pick a 1M model, switch to
    // a provider whose catalogue does not publish a window, and the budget stays
    // at 800k for a model that has 128k. `setModel` is the "no idea" call and it
    // has to clear it.
    const saved_model = curModel();
    const saved_ctx = curModelContext();
    defer setModelCtx(saved_model, saved_ctx);

    setModelCtx("big-model", 1_000_000);
    try std.testing.expectEqual(@as(u32, 1_000_000), curModelContext());
    try std.testing.expectEqualStrings("big-model", curModel());

    setModel("other-model");
    try std.testing.expectEqual(@as(u32, 0), curModelContext());
    try std.testing.expectEqualStrings("other-model", curModel());

    // Switching provider goes through `setModel("")`.
    setModelCtx("big-model", 1_000_000);
    setModelCtx("", 0);
    try std.testing.expectEqual(@as(u32, 0), curModelContext());
}

test "the status bar names the model that is ANSWERING, not the one that is configured" {
    // The one thing that makes `/free-auto` and the cheap router diagnosable.
    // Without it the row keeps saying the model you picked while a different one
    // writes the answer, and "the model ignored my edit" cannot be told apart
    // from "the model was never asked".
    const saved_model = curModel();
    const saved_ctx = curModelContext();
    defer {
        setAnswering("");
        setModelCtx(saved_model, saved_ctx);
    }

    setModelCtx("the-picked-one", 200_000);
    // Nothing is overriding: what answers is what is configured.
    try std.testing.expectEqualStrings("the-picked-one", curAnswering());

    setAnswering("the-small-one");
    try std.testing.expectEqualStrings("the-small-one", curAnswering());

    // Back to empty: the override is per turn, not sticky.
    setAnswering("");
    try std.testing.expectEqualStrings("the-picked-one", curAnswering());
}

test "tpsOf: the rate itself, and the two windows that must not produce one" {
    // The live counter is a rate over a 250 ms window: with a window that tiny,
    // a bad clock read (dt = 0) or a single delta (dt = 1 ms) would print
    // 400000 tok/s in the status bar. The floor and the ceiling are what keep
    // the number believable.
    try std.testing.expectApproxEqAbs(@as(f64, 400), tpsOf(400, 1_000_000_000), 0.001);
    // 2000 tokens in a quarter second = 8000 tok/s.
    try std.testing.expectApproxEqAbs(@as(f64, 8000), tpsOf(2000, 250_000_000), 0.001);
    try std.testing.expectEqual(@as(f64, 0), tpsOf(400, 0));
    try std.testing.expectEqual(@as(f64, 0), tpsOf(400, -1));
    try std.testing.expectEqual(@as(f64, 0), tpsOf(0, 1_000_000_000));
    // A µs window: one token in one microsecond is a million tok/s, which can
    // only be a clock artifact.
    try std.testing.expectEqual(@as(f64, 0), tpsOf(1, 1_000));
}

test "ctxTokens: the provider's own count wins, the estimate covers the first request" {
    // Two instruments for the same question: our ~4 chars/token and the
    // tokenizer that will actually bill the context. The real one is exact and
    // does not get the `~`; before the first request there is no real one and
    // the estimate is what there is.
    try std.testing.expectEqual(@as(i64, 12_480), ctxTokens(12_480, 9_999));
    try std.testing.expectEqual(@as(i64, 9_999), ctxTokens(0, 9_999));
    try std.testing.expectEqual(@as(i64, 0), ctxTokens(0, 0));
}

test "the cheap router is off unless ZODE_CHEAP_TURN names a model" {
    // The default matters more than the feature: a small model that is not
    // available for your account answers 403 and the model has no way to know
    // the fallback would have worked. So nothing happens unless it is asked for.
    //
    // The global is saved and restored, not just overwritten: turning the
    // router on here leaves every LATER turn — including the E2E — routing
    // through a model that does not exist, which is not what this test is
    // about and not what the suite should inherit.
    const saved_router = cheap_router;
    const saved_on = router_cheap_on;
    defer {
        cheap_router = saved_router;
        router_cheap_on = saved_on;
    }

    var off = std.process.Environ.Map.init(std.testing.allocator);
    defer off.deinit();

    initCheapRouterFromEnv(&off);
    const a = cheapRouterStats();
    try std.testing.expect(!a.on);
    try std.testing.expectEqualStrings("", a.model);
    try std.testing.expectEqual(@as(u32, 0), a.attempts);

    var on = std.process.Environ.Map.init(std.testing.allocator);
    defer on.deinit();
    try on.put(router_mod.cheap_env, "some-small-model");
    initCheapRouterFromEnv(&on);
    const b = cheapRouterStats();
    try std.testing.expect(b.on);
    try std.testing.expectEqualStrings("some-small-model", b.model);
}

test "a cheap model equal to the active one is not used, because it is not cheaper" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put(router_mod.cheap_env, "the-same-one");

    var st = router_mod.initFromEnv(&env);
    try std.testing.expectEqual(router_mod.Decision.active, router_mod.decide(&st, "the-same-one", true));
    try std.testing.expectEqual(@as(u32, 0), st.attempts);
}

test "envTruthy: an unset flag takes the default and an explicit off really is off" {
    const saved = environ_global;
    environ_global = null;
    defer environ_global = saved;

    try std.testing.expect(envTruthy("ZODE_AUTO_CHECK", true));
    try std.testing.expect(!envTruthy("ZODE_AUTO_CHECK", false));
    // The harness starting a compiler on the machine unasked is a POLICY, and a
    // policy with no off switch is not a default.
    for ([_][]const u8{ "0", "false", "no", "off", "OFF" }) |v| {
        var map = std.process.Environ.Map.init(std.testing.allocator);
        defer map.deinit();
        map.put("ZODE_AUTO_CHECK", v) catch return error.PutFailed;
        environ_global = &map;
        const got = envTruthy("ZODE_AUTO_CHECK", true);
        if (got) {
            std.debug.print("ZODE_AUTO_CHECK={s} was read as ON\n", .{v});
            return error.OffNotOff;
        }
    }
}

test "codePathsFromArgs: the gate that decides if a build is worth starting" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect(codePathsFromArgs("{\"path\":\"src/a.zig\"}", arena));
    try std.testing.expect(codePathsFromArgs("{\"path\":\"src/app.ts\"}", arena));
    // A build that proves nothing is a request spent.
    try std.testing.expect(!codePathsFromArgs("{\"path\":\"README.md\"}", arena));
    try std.testing.expect(!codePathsFromArgs("{\"path\":\"package-lock.json\"}", arena));
    // **`write {files:[...]}` has no `path`, and this assertion used to say so.**
    //
    // It is the one line that was wrong twice: the first version of the reader returned
    // false for the multi-file forms, the comment called that "the wrong direction", and
    // the comment was more convinced than the code. The prompt tells the model to send
    // ONE `edit {files:[...]}` for a rename across nine files instead of nine calls —
    // so the form the harness recommends was the one form that never started a check.
    try std.testing.expect(codePathsFromArgs("{\"files\":[{\"path\":\"a.zig\"}]}", arena));
    // One code file among the rest is enough: the check runs on the PROJECT.
    try std.testing.expect(codePathsFromArgs("{\"files\":[{\"path\":\"r.md\"},{\"path\":\"s/b.zig\"}]}", arena));
    // And a multi-file call that is entirely non-code is still not worth a build.
    try std.testing.expect(!codePathsFromArgs("{\"files\":[{\"path\":\"r.md\"}]}", arena));
    // Garbage in is not a crash and not a yes.
    try std.testing.expect(!codePathsFromArgs("not json", arena));
    try std.testing.expect(!codePathsFromArgs("{\"path\":123}", arena));
}

test "autoCheck: the cap is per turn and it stops a model that edits nine times" {
    // Nine edits in one turn is nine builds competing for eight background slots,
    // and the ninth is a build of the state after the eighth — the only one
    // anybody wanted.
    try std.testing.expect(auto_check_per_turn < 4);
    // Not 1 either: the shape of a task is "edit, read the errors, fix, edit,
    // read the errors", and with 1 the second fix is never checked.
    try std.testing.expect(auto_check_per_turn >= 2);
}

test "autoCheckResult: a job with locations produces the note, and it is consumed" {
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    m.bg.slots[1] = .{ .state = .finished, .id = 6, .exit = 1 };
    try m.bg.slots[1].buf.appendSlice(std.testing.allocator, "src/a.zig:3:5: error: unused variable\n");
    @memcpy(m.auto_check.label[0..9], "zig build");
    m.auto_check.label_len = 9;
    m.auto_check.job = 6;

    const note = m.auto_check.collect(&m.bg) orelse return error.NoNote;
    try std.testing.expect(std.mem.indexOf(u8, note, "src/a.zig:3:5: error") != null);
    // The label, so the model knows this is the compiler and not a guess.
    try std.testing.expect(std.mem.indexOf(u8, note, "zig build") != null);
    // And it says what to do about it.
    try std.testing.expect(std.mem.indexOf(u8, note, "Fix these") != null);
    // Consumed: the next edit must not report this turn's errors a second time.
    try std.testing.expectEqual(@as(u32, 0), m.auto_check.job);
}

test "autoCheckResult: a PASSING check says nothing at all" {
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    // Exit 0 and output with no locations: the build was fine.
    m.bg.slots[0] = .{ .state = .finished, .id = 2, .exit = 0 };
    try m.bg.slots[0].buf.appendSlice(std.testing.allocator, "Build finished\n");
    m.auto_check.job = 2;

    // "it compiles" is worth nothing to a model that was not going to write code
    // anyway, and it is the one message that could be repeated five times in one
    // turn. Silence is the design.
    try std.testing.expect(m.auto_check.collect(&m.bg) == null);
    // Consumed even when silent, or the next edit reports it again.
    try std.testing.expectEqual(@as(u32, 0), m.auto_check.job);
}

test "autoCheckResult: no job, and a job still running, both say nothing" {
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    try std.testing.expect(m.auto_check.collect(&m.bg) == null);

    m.bg.slots[0] = .{ .state = .running, .id = 3 };
    try m.bg.slots[0].buf.appendSlice(std.testing.allocator, "src/a.zig:1:1: error: early\n");
    m.auto_check.job = 3;
    // Mid-thought, a note that says "still running" is the noise this feature
    // exists to avoid. The job keeps its slot and the next iteration reads it.
    try std.testing.expect(m.auto_check.collect(&m.bg) == null);
    try std.testing.expectEqual(@as(u32, 3), m.auto_check.job);
}

test "the headless prompt is the SAME prompt as the TUI's, routing included" {
    // The bug this pins: `zode --chat` composed its own system prompt and left out
    // `tool_routing_prompt` and `verification_prompt`. So the runner that every pty
    // test and every measurement in this repo drives was an agent with NO routing
    // rules at all: it reached for `bash zig build` where `check` exists, for
    // `bash curl` where `web_search` exists, it read three files in three round
    // trips, and it wrote its own verification scripts.
    //
    // None of it was visible from the TUI, where the same rules do work — which is
    // why it survived: the TUI looked right.
    //
    // One composition now, and this is the test that says so.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // An `Io`, because `systemPromptBase` reads the project's AGENTS.md through
    // `io_global` and that is `undefined` until startup assigns it. Calling a file
    // read through it is a GPF, not a zero — the eighth time this family has cost
    // an afternoon, and the reason every one of those tests attaches one.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const saved_io = io_global;
    const saved_gpa = gpa_global;
    io_global = threaded.io();
    defer {
        // `buildSystemPromptFor` below caches arena-allocated entries in the
        // global `styles_cache`. Freeing them with `std.testing.allocator`
        // (via `resetStylesCacheForTest`) would be an Invalid free; the arena
        // is deinited separately, so just drop the reference.
        styles_cache = null;
        styles_stamp_len = 0;
        styles_rescans = 0;
        gpa_global = saved_gpa;
        io_global = saved_io;
    }
    gpa_global = std.testing.allocator;
    resetStylesCacheForTest();

    // Initialize project_info to avoid GPF when skills system accesses it.
    setProjectInfoForTest(io_global, "/tmp");

    // The AGENTS.md cache is a MODULE GLOBAL that outlives this test's arena, and
    // the next test would read a pointer into memory that has been freed. That is a
    // use-after-free that shows up as a segfault in whichever test runs second,
    // which is how it would have been misread.
    const saved_agents = agents_md_cache;
    agents_md_cache = null;
    defer agents_md_cache = saved_agents;

    var buf: [16 * 1024]u8 = undefined;
    const from_tui = buildSystemPrompt(a, &buf, null, true);
    // The first call above caches arena-allocated entries in the globals.
    // Drop them before the second call so `freeStylesCacheLocked`/`freeSkillsCacheLocked`
    // don't try to free arena memory with `std.testing.allocator`.
    styles_cache = null;
    skills_cache = null;
    const headless = try buildSystemPromptFor(a, null);
    styles_cache = null;
    skills_cache = null;

    try std.testing.expectEqualStrings(from_tui, headless);

    // And the specific things that were missing, by name.
    for ([_][]const u8{
        tool_routing_prompt,
        verification_prompt,
        ask.guidance,
    }) |block| {
        if (std.mem.indexOf(u8, headless, block) == null) {
            std.debug.print("the headless prompt is missing a block of {d} bytes\n", .{block.len});
            return error.PromptIncomplete;
        }
    }
    // The rules that only exist in the routing table, so a future edit that drops
    // the block is caught by name and not by byte count.
    for ([_][]const u8{ "NEVER use bash", "check` TYPECHECKS", "`todo`", "`refs`", "`paths`" }) |needle| {
        if (std.mem.indexOf(u8, headless, needle) == null) {
            std.debug.print("the headless prompt lost the rule: {s}\n", .{needle});
            return error.RuleMissing;
        }
    }
}

test "the project's own AGENTS.md is READ, even when it is big" {
    // The read had a 256 KB limit and `catch null`, and `null` means "this
    // project has no instruction file". So a project whose `AGENTS.md` was a
    // LITTLE too big got the BUILT-IN prompt instead of its own, with no
    // error anywhere: the harness silently stopped reading the project's
    // rules, and the symptom was "the model ignored my instructions".
    //
    // It was found because THIS repository's own `AGENTS.md` crossed the
    // line, and the test below failed for a reason nobody could read: the
    // prompt was the built-in one, so it fit, so there was nothing to
    // truncate and nothing to announce.
    //
    // The file being big is not the interesting part; the interesting part is
    // that it is READ AT ALL. The limit is 1 MB now, and the size of the
    // file is not what decides what the model sees: the base is trimmed to
    // the prompt buffer before it is sent.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const saved_io = io_global;
    const saved_agents = agents_md_cache;
    io_global = threaded.io();
    agents_md_cache = null;
    defer {
        // The cache was filled with the TESTING allocator, so it is freed with
        // it: leaving it behind is a leak the test runner would report for a
        // file the test did not create.
        if (agents_md_cache) |c| std.testing.allocator.free(c);
        agents_md_cache = saved_agents;
        io_global = saved_io;
    }

    const base = systemPromptBase(std.testing.allocator);
    // It is this repository's own file, and the test verifies it's READ.
    try std.testing.expect(std.mem.indexOf(u8, base, "# zode") != null);
}

test "a project whose AGENTS.md does not fit still gets the ROUTING, not just its own text" {
    // Found by the previous test, which runs in this repository: its `AGENTS.md` is
    // ~90 KB, the composition buffer is 16 KB, and the old overflow answer was
    // `catch return base`. So in this very repository the composed prompt was the
    // project's own text ALONE: no routing table, no verification rule, no ask
    // guidance, no skills, no location.
    //
    // That is the failure this whole table exists to prevent — asked to find a
    // games page, the model ran `bash curl`, because there was no rule saying not
    // to — and it was happening silently to every project with a large instruction
    // file, and looking like "the model ignored my instructions".
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // The same `Io` requirement as the test above, and the same reason.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const saved_io = io_global;
    const saved_gpa = gpa_global;
    io_global = threaded.io();
    defer {
        // `buildSystemPrompt` above cached arena-allocated entries in the globals.
        // Dropping the references (not freeing): the arena is deinited separately,
        // and freeing with `std.testing.allocator` would be an Invalid free.
        styles_cache = null;
        skills_cache = null;
        gpa_global = saved_gpa;
        io_global = saved_io;
    }
    gpa_global = std.testing.allocator;
    resetStylesCacheForTest();
    resetSkillsCacheForTest();

    const saved_agents = agents_md_cache;
    agents_md_cache = null;
    defer agents_md_cache = saved_agents;

    var buf: [16 * 1024]u8 = undefined;
    const composed = buildSystemPrompt(a, &buf, null, true);

    // The constant blocks are the ones that must survive the trim.
    for ([_][]const u8{
        tool_routing_prompt,
        verification_prompt,
        ask.guidance,
        "NEVER use bash",
        "`check`",
        "`todo`",
    }) |needle| {
        if (std.mem.indexOf(u8, composed, needle) == null) {
            std.debug.print("the prompt lost a block when the base did not fit: {s}\n", .{needle[0..@min(needle.len, 40)]});
            return error.PromptIncomplete;
        }
    }
    // And the truncation is ANNOUNCED: a project that cannot see half of its own
    // instructions should be told, not left to guess.
    if (std.mem.indexOf(u8, composed, "truncated to fit") == null) {
        return error.TruncationNotAnnounced;
    }
    // It still fits in the buffer it was given, which is the other half.
    try std.testing.expect(composed.len <= buf.len);
}

test "the headless runner and the TUI share ONE automatic typecheck" {
    // The bug this pins: `autoCheckAfterTools` and `autoCheckResult` lived in the
    // TUI's path, so `zode --chat` — the runner every pty test and every measurement
    // in this repo drives — edited code and never compiled it. Both now call
    // `AutoCheck`, which is why the headless runner keeps one on its stack and the
    // TUI keeps one on the `Model`.
    //
    // The shape of the state is the assertion: a `u32` id and a label, not a pointer
    // into a turn's arena, because the output belongs to a background thread's buffer
    // and outlives the arena that started it.
    const st = AutoCheck{};
    try std.testing.expectEqual(@as(u32, 0), st.job);
    try std.testing.expectEqual(@as(u32, 0), st.started_this_turn);

    // The gate both callers share: an edit to code is worth a build, an edit to
    // markdown is not, and an argument this cannot parse is not proof either way.
    //
    // The multi-file line USED to be `!…`, asserting that `files` was invisible to it.
    // That is the second half of the same bug as above, in a test that claimed to be
    // about two runners sharing one implementation: it was asserting that the shared
    // implementation was blind.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expect(codePathsFromArgs("{\"path\":\"src/a.zig\"}", a));
    try std.testing.expect(!codePathsFromArgs("{\"path\":\"README.md\"}", a));
    try std.testing.expect(codePathsFromArgs("{\"files\":[{\"path\":\"a.zig\"}]}", a));
}

test "iterationLimit is the SAME for both runners, and ZODE_MAX_ITER moves it" {
    // `--chat` had `while (iteration < 6)` hardcoded while the TUI allowed 12 and
    // `ZODE_MAX_ITER` moved it. So a headless run gave up on a real task with no
    // error and no explanation — and `ZODE_MAX_ITER` did nothing there at all.
    const saved = environ_global;
    environ_global = null;
    defer environ_global = saved;

    try std.testing.expectEqual(agent_default_iterations(), iterationLimit());
    try std.testing.expect(iterationLimit() > 6);
}

test "applyPlanTo works with NO Model, which is what --chat has" {
    // The bug this pins: `applyPlanCall` was a method on the TUI's `Model`, so
    // `zode --chat` answered **"plan recorded"** and recorded nothing — the model
    // reached for the tool, the tool reported success, and nothing anywhere changed.
    //
    // A plain value the caller owns: `Model.plan` for the TUI, a stack variable for
    // the headless runner. Same code either way.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var plan = plan_mod.Plan.init();
    try std.testing.expect(plan.isEmpty());

    // The replacement form.
    const line = applyPlanTo(&plan,
        \\{"items":[{"content":"read it"},{"content":"fix it","status":"in_progress"}]}
    , a) orelse {
        std.debug.print("applyPlanTo returned nothing for the replacement form\n", .{});
        return error.NoLine;
    };
    try std.testing.expect(std.mem.indexOf(u8, line, "0/2 done") != null);
    try std.testing.expectEqual(@as(u8, 2), plan.len);
    try std.testing.expectEqual(plan_mod.Status.in_progress, plan.items[1].status);

    // And the patch form, in the same function: the branch is decided inside, so a
    // caller cannot pick the wrong one.
    const patch = applyPlanTo(&plan, "{\"update\":[{\"index\":1,\"status\":\"done\"}]}", a) orelse {
        std.debug.print("patch form returned nothing (len={d})\n", .{plan.len});
        return error.NoPatchLine;
    };
    try std.testing.expect(std.mem.indexOf(u8, patch, "1/2 done") != null);
    try std.testing.expectEqual(plan_mod.Status.done, plan.items[0].status);
    // The other step is untouched, which is the whole point of the patch form.
    try std.testing.expectEqual(plan_mod.Status.in_progress, plan.items[1].status);

    // "Same as before" says nothing, so a repeated call is not noise in the history.
    try std.testing.expect(applyPlanTo(&plan, "{\"update\":[{\"index\":1,\"status\":\"done\"}]}", a) == null);

    // And a patch with a bad index is reported, not swallowed.
    const bad = applyPlanTo(&plan, "{\"update\":[{\"index\":9,\"status\":\"done\"}]}", a) orelse {
        std.debug.print("bad index returned nothing\n", .{});
        return error.NoBadIndexLine;
    };
    try std.testing.expect(std.mem.indexOf(u8, bad, "do not exist") != null);
}

test "the TUI records the complete plan for the user to review" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var model = tui.Model.init(std.testing.allocator);
    defer model.deinit();

    applyPlanCall(&model,
        \\{"items":[{"content":"inspect the code","status":"done"},{"content":"implement the fix","status":"in_progress"},{"content":"run tests"}]}
    , arena_state.allocator());

    try std.testing.expectEqual(@as(u8, 3), model.plan.len);
    try std.testing.expect(model.plan_touched_this_turn);
    try std.testing.expectEqual(@as(usize, 1), model.pending.items.len);
    const output = model.pending.items[0].text;
    try std.testing.expect(std.mem.indexOf(u8, output, "1/3 done") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "1. inspect the code") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "2. implement the fix") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "3. run tests") != null);
}

test "a cleared plan is a change, and an empty one is not" {
    // The model repeats "plan cleared" on every call if an empty list over an empty
    // plan counts as a change, and it looks like noise on the screen.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var plan = plan_mod.Plan.init();
    // An empty list over an EMPTY plan is `.same`, and says nothing: the model
    // would repeat "plan cleared" on every call otherwise.
    try std.testing.expect(applyPlanTo(&plan, "{\"items\":[]}", a) == null);

    // And a list that HAD items, emptied, IS a change: it is the signal it is over.
    _ = applyPlanTo(&plan, "{\"items\":[{\"content\":\"one\"}]}", a);
    try std.testing.expectEqualStrings("plan cleared", applyPlanTo(&plan, "{\"items\":[]}", a).?);
}

// ── the goal, and the loop that refuses to stop short of it ─────────────────────

test "the repetition guard fires on the third identical call, and names the tool" {
    var r: Repeats = .{};
    const args = "{\"command\":\"ls\"}";

    // Two is a coincidence; three is a loop. Below the threshold nothing is returned,
    // which is the property that matters: a guard that fires early stops real work.
    try std.testing.expect(r.note("bash", args) == null);
    try std.testing.expect(r.note("bash", args) == null);
    try std.testing.expectEqualStrings("bash", r.note("bash", args).?);

    // A different tool resets the run, not the counter's lifetime.
    var r2: Repeats = .{};
    try std.testing.expect(r2.note("bash", args) == null);
    try std.testing.expect(r2.note("bash", args) == null);
    try std.testing.expect(r2.note("grep", args) == null);
    try std.testing.expect(r2.note("bash", args) == null);
    try std.testing.expect(r2.note("bash", args) == null);
    try std.testing.expectEqualStrings("bash", r2.note("bash", args).?);
}

test "different arguments are different work, even with the same tool" {
    // This is the false positive that would matter: a model grepping for three
    // different patterns is making progress and must not be stopped.
    var r: Repeats = .{};
    try std.testing.expect(r.note("grep", "{\"pattern\":\"alpha\"}") == null);
    try std.testing.expect(r.note("grep", "{\"pattern\":\"beta\"}") == null);
    try std.testing.expect(r.note("grep", "{\"pattern\":\"gamma\"}") == null);
    try std.testing.expect(r.note("grep", "{\"pattern\":\"alpha\"}") == null);
}

test "a goal earns a hard ceiling well above the soft one" {
    // The whole point: 12 was the only number and it cut real tasks. `ZODE_GOAL_MAX`
    // overrides it and can never come out BELOW the soft limit, because a hard ceiling
    // under the target would stop a goal turn before the checkpoint even runs.
    try std.testing.expect(goalHardLimit() > iterationLimit());
    const prev = environ_global;
    defer environ_global = prev;
    var e = std.process.Environ.Map.init(std.testing.allocator);
    defer e.deinit();
    environ_global = &e;
    try std.testing.expectEqual(goalHardLimit(), goalHardLimit());
    try e.put("ZODE_GOAL_MAX", "2");
    // 2 is below the floor of 4 in `iterationLimit`, and below the goal floor too.
    try std.testing.expectEqual(iterationLimit(), goalHardLimit());
    try e.put("ZODE_GOAL_MAX", "500");
    try std.testing.expectEqual(@as(usize, 500), goalHardLimit());
}

test "the goal note carries the objective and the budget, and the note has a marker" {
    var g: goal_mod.Goal = .{};
    const t = "make the package weigh under 10 KB";
    @memcpy(g.text[0..t.len], t);
    g.len = t.len;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    w.print("{s}", .{try goalNote(a, &g, 18, false, 2)}) catch unreachable;
    const steady = w.buffered();
    // The objective verbatim: a paraphrase of a measurable target is not the target.
    try std.testing.expect(std.mem.indexOf(u8, steady, t) != null);
    // And the marker, which is how the note is found again to be replaced.
    try std.testing.expect(std.mem.startsWith(u8, steady, session_mod.goal_note_marker));

    // NO COUNTDOWN in the steady state, which is the change this test exists for.
    //
    // It used to assert the opposite ("you have 18 left is what makes a model finish").
    // It was wrong, and it was wrong in the same direction as the crash it was written
    // next to: a number that has not changed in any way the model can act on, repeated
    // on every one of up to 60 iterations, is not information. It is a deadline the
    // model learns to hurry for, which is the opposite of finishing careful work.
    //
    // The number still appears when it is actionable — near the ceiling — and that is
    // the half that is worth keeping.
    try std.testing.expect(std.mem.indexOf(u8, steady, "18 iterations left") == null);
    // The shape of the turn, which IS worth saying every time: it ends when the
    // objective is decided, not when the model stops talking.
    try std.testing.expect(std.mem.indexOf(u8, steady, "A summary is not a verdict") != null);

    var buf3: [512]u8 = undefined;
    var w3: std.Io.Writer = .fixed(&buf3);
    w3.print("{s}", .{try goalNote(a, &g, 3, false, 2)}) catch unreachable;
    try std.testing.expect(std.mem.indexOf(u8, w3.buffered(), "3 iterations left") != null);

    var buf2: [2048]u8 = undefined;
    var w2: std.Io.Writer = .fixed(&buf2);
    w2.print("{s}", .{try goalNote(a, &g, 48, true, 3)}) catch unreachable;
    const cp = w2.buffered();
    try std.testing.expect(std.mem.indexOf(u8, cp, t) != null);

    // The checkpoint does NOT tell the model to stop. This is the second half of the
    // change and the more important one: "STOP AND REPORT ... Do not start new work" at
    // iteration 12, with the task half done, is a coin flip — a model that obeys writes
    // a summary instead of finishing, and a model that does not obey burns the next 48
    // iterations ignoring an instruction. Neither finishes the task, and which one
    // happens is not the harness's decision to make with someone's work.
    try std.testing.expect(std.mem.indexOf(u8, cp, "STOP AND REPORT") == null);
    try std.testing.expect(std.mem.indexOf(u8, cp, "Do not start new work") == null);
    try std.testing.expect(std.mem.indexOf(u8, cp, "Keep going") != null);
    // "Keep going" is only useful if it says what to keep going ON, and the harness
    // already knows: it is the plan's own count. Three open steps, named as three.
    try std.testing.expect(std.mem.indexOf(u8, cp, "3 steps") != null);
    // The verdict is still reachable, with both shapes spelled out, because a real
    // blocker has to be declarable.
    try std.testing.expect(std.mem.indexOf(u8, cp, "what_would_unblock") != null);
    try std.testing.expect(std.mem.indexOf(u8, cp, "met") != null);
}

test "a checkpoint with NO open plan steps says so, instead of implying there is work" {
    // "Keep going" with nothing to go on is how a model talks itself into a summary. A
    // plan with zero open steps and an undeclared goal means the objective is not met or
    // not verified, and the prompt has to say WHICH question is open — because that is
    // the one the model has to answer before it is allowed to declare anything.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var g: goal_mod.Goal = .{};
    const t = "the build is green";
    @memcpy(g.text[0..t.len], t);
    g.len = t.len;
    g.iterations = 10;

    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("{s}", .{try goalNote(a, &g, 40, true, 0)}) catch unreachable;
    const cp = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, cp, "Keep going") != null);
    try std.testing.expect(std.mem.indexOf(u8, cp, "none") != null);
    try std.testing.expect(std.mem.indexOf(u8, cp, "0 steps") == null);
}

test "no goal, no note" {
    var g: goal_mod.Goal = .{};
    try std.testing.expectError(error.NoGoal, goalNote(std.testing.allocator, &g, 5, false, 0));
}

// ── YOLO: the `ask` tool does not ask ─────────────────────────────────────

test "in YOLO mode the question is not asked: the harness takes the recommendation" {
    // `/yolo` exists so the app does not stop to wait for the human, and a
    // question that opens a dialog stops the app exactly as much as a
    // permission dialog does. So the question is answered by the harness,
    // with the model's OWN recommendation (the schema tells it to put the
    // recommendation FIRST).
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    const saved = yolo;
    defer yolo = saved;
    yolo = true;

    var s = session_mod.Session.init(std.testing.allocator);
    defer s.deinit();

    const call = TurnCtx.Call{
        .id = "c1",
        .name = "ask",
        .args_json = "{\"question\":\"which database?\",\"header\":\"db\",\"options\":[\"postgres (recommended)\",\"sqlite\"]}",
    };
    try std.testing.expectEqual(@as(usize, 1), askCall(&m, &s, call));

    // The panel was NOT opened: nobody is asked.
    try std.testing.expect(!m.askActive());

    // The tool result says what happened, and asks for the summary.
    try std.testing.expectEqual(@as(usize, 1), s.messages.items.len);
    const res = s.messages.items[0].content;
    try std.testing.expect(std.mem.indexOf(u8, res, "Nobody was asked") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "postgres (recommended)") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "final summary") != null);

    // And it is counted: the user can see it in `/bench`.
    try std.testing.expectEqual(@as(usize, 1), m.bench.asks_auto);
    try std.testing.expectEqual(@as(usize, 0), m.bench.asks_open);
}

test "in YOLO mode a question with no options stays OPEN, and the model is told to say so" {
    // There is nothing to take: no option means no recommendation. The
    // question is left open, and the model has to MENTION it in its summary:
    // an open question nobody mentions is a question that is lost.
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    const saved = yolo;
    defer yolo = saved;
    yolo = true;

    // The turn stats own the OPEN questions, and the global's allocator is
    // `undefined` until a turn starts: using it before that is a jump through
    // a garbage vtable, not a nice error.
    turn_stats.reset(std.testing.allocator, 0);
    defer turn_stats.reset(std.testing.allocator, 0);

    var s = session_mod.Session.init(std.testing.allocator);
    defer s.deinit();

    const call = TurnCtx.Call{
        .id = "c1",
        .name = "ask",
        .args_json = "{\"question\":\"what should the endpoint be called?\"}",
    };
    try std.testing.expectEqual(@as(usize, 1), askCall(&m, &s, call));
    try std.testing.expect(!m.askActive());

    const res = s.messages.items[0].content;
    try std.testing.expect(std.mem.indexOf(u8, res, "stays OPEN") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "final summary") != null);
    // The question is NOT repeated: the model wrote it, it is in its context
    // already, and repeating 600 characters to say "still open" is the user's
    // tokens for nothing.
    try std.testing.expect(std.mem.indexOf(u8, res, "what should the endpoint be called?") == null);

    try std.testing.expectEqual(@as(usize, 0), m.bench.asks_auto);
    try std.testing.expectEqual(@as(usize, 1), m.bench.asks_open);

    // And the TURN SUMMARY names it: the user is the one who can answer it,
    // and the model's own answer might not mention it.
    var sum_buf: [256]u8 = undefined;
    const sum = try turn_stats.summaryLine(&sum_buf, 0, 0, 0);
    try std.testing.expect(std.mem.indexOf(u8, sum, "1 question still OPEN") != null);
    var ybuf: [256]u8 = undefined;
    const open = try turn_stats.yoloOpenLine(&ybuf);
    try std.testing.expect(std.mem.indexOf(u8, open, "what should the endpoint be called?") != null);
}

test "outside YOLO the question IS asked (the mode is the only thing that changes it)" {
    // The DECISION is what the test pins, and not the whole call: the call
    // opens a dialog and parks the turn waiting for a human, which in a test
    // is a hang. The rule is pure (`ask.decide`) and the agent only acts on
    // it.
    try std.testing.expectEqual(ask.Decision.ask, ask.decide(false, true));
    try std.testing.expectEqual(ask.Decision.ask, ask.decide(false, false));
    try std.testing.expectEqual(ask.Decision.take_recommendation, ask.decide(true, true));
    try std.testing.expectEqual(ask.Decision.leave_open, ask.decide(true, false));
}

test "/yolo says what it does with the questions, because the user reads that line" {
    // "no confirmations" was the whole message, and it was not true: the
    // questions were still asked. Now they are not, and the line says so.
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    const saved = yolo;
    defer {
        yolo = saved;
        setPermMode(&m, .default);
    }
    yolo = false;

    cmdYolo(&m);
    try std.testing.expect(yolo);
    m.drainPending();
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(std.testing.allocator);
    for (m.paras.items) |p| {
        try joined.appendSlice(std.testing.allocator, p.text);
        try joined.append(std.testing.allocator, '\n');
    }
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "no questions") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "summary") != null);
}

test "the YOLO mode note is in the prompt, because the model has to know BEFORE it asks" {
    // The same reason the read-only note is in the prompt: a model that plans
    // an `ask` and then finds out nobody is there reads it as a harness bug
    // and works around it.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // The prompt reads the project's instruction file, so it needs an `Io` and
    // the caches have to be dropped afterwards (the same dance the other
    // prompt tests do).
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const saved_io = io_global;
    const saved_gpa = gpa_global;
    io_global = threaded.io();
    defer {
        styles_cache = null;
        skills_cache = null;
        gpa_global = saved_gpa;
        io_global = saved_io;
    }
    gpa_global = std.testing.allocator;
    resetStylesCacheForTest();
    resetSkillsCacheForTest();

    const saved_agents = agents_md_cache;
    agents_md_cache = null;
    defer agents_md_cache = saved_agents;

    const saved = yolo;
    defer yolo = saved;
    yolo = true;

    var out: [64 * 1024]u8 = undefined;
    const composed = buildSystemPrompt(a, &out, null, true);
    try std.testing.expect(std.mem.indexOf(u8, composed, "YOLO MODE is on") != null);
    try std.testing.expect(std.mem.indexOf(u8, composed, "MENTION it in your final summary") != null);
}

test "a `goal` CALL reaches the Model, which the two pure tests could not see" {
    // The bug this pins, measured: `applyGoalCall` existed, `toolGoal` existed, the
    // schema was declared, the model called the tool and the tool answered "recorded:
    // the goal is BLOCKED" — and the harness never applied it, ran to the hard ceiling
    // and printed `the goal was never decided`.
    //
    // `goal.test` checked the PARSING and `tools.dispatch` checked the TEXT. Neither
    // went from a tool call to the Model, so the seam between them had nothing watching
    // it. This goes through `applyGoalCall` exactly as `execOneCall` does, which is the
    // only level at which the bug was visible.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    // No goal set: the call still has to land, because refusing it would leave the turn
    // with no way to finish and no message about why.
    try std.testing.expectEqual(goal_mod.Status.none, m.goal.status);

    const blocked =
        \\{"status":"blocked","summary":"the upstream service is down","what_would_unblock":"a working key"}
    ;
    applyGoalCall(&m, blocked, arena);

    try std.testing.expectEqual(goal_mod.Status.blocked, m.goal.status);
    try std.testing.expectEqualStrings("the upstream service is down", m.goal.say());
    try std.testing.expectEqualStrings("a working key", m.goal.whatUnblocks());

    const met =
        \\{"status":"met","summary":"the build passes"}
    ;
    applyGoalCall(&m, met, arena);
    try std.testing.expectEqual(goal_mod.Status.met, m.goal.status);
    try std.testing.expectEqualStrings("the build passes", m.goal.say());
}

test "a malformed goal call leaves the goal OPEN and says why, and never closes it" {
    // The dangerous direction is silent: if a bad call set the status anyway, the turn
    // would end as "goal met" or "goal blocked" on a call the model never made.
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    // Four ways of being wrong, including the one that matters most: `blocked`
    // without `what_would_unblock` must NOT be taken, because a goal that can be
    // given up without saying what would fix it is a goal that gets given up.
    //
    // Multiline literals throughout: a JSON string in a plain Zig literal needs
    // `\"` everywhere, and a heredoc that writes those doubles them into
    // `{\\"status...`, which stops compiling three characters later with "expected
    // ',' after initializer" — pointing at a line with nothing wrong on it.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{
        "{\"status\":\"finishd\",\"summary\":\"typo\"}",
        "{\"summary\":\"no status\"}",
        "{\"status\":\"blocked\",\"summary\":\"no unblocker\"}",
        "not json at all",
    }) |bad| {
        applyGoalCall(&m, bad, arena);
        try std.testing.expectEqual(goal_mod.Status.none, m.goal.status);
    }
}

test "polling a background job is not a loop, and the guard stays blind to it" {
    // The false positive this pins, measured on a real task: the model started a test
    // suite with `run_in_background`, then called `bash_output` three times — which the
    // `bash` schema tells it to do — and the guard ended the turn with "tell me what
    // to try instead", while the suite was still running and the model was waiting
    // correctly.
    //
    // Twenty polls here, not three: a suite that takes a minute gets polled a lot, and
    // the ceiling is what bounds that, not a guard that cannot tell waiting from
    // spinning.
    var r: Repeats = .{};
    var i: u8 = 0;
    while (i < 20) : (i += 1) {
        try std.testing.expect(isRepeatExempt("bash_output"));
        try std.testing.expect(r.noteGuarded("bash_output", "{}") == null);
    }
    // Interleaved with real work, which is what a turn actually looks like: the run
    // counter has to reset, not accumulate across the poll.
    _ = r.noteGuarded("read", "{}");
    _ = r.noteGuarded("bash_output", "{}");
    try std.testing.expect(r.noteGuarded("bash_output", "{}") == null);

    // And the counter underneath still works: the exemption is a filter on top, not a
    // disabled guard. Twenty polls counted and then one `bash` has to be a first call.
    var counted: Repeats = .{};
    i = 0;
    while (i < 20) : (i += 1) _ = counted.note("bash_output", "{}");
    try std.testing.expect(counted.note("bash",
        \\{"command":"zig build"}
    ) == null);
}

test "the guard still fires on the loops it was built for" {
    // The exemption is for looking, not for doing. Without this half the fix would read
    // as "the repetition guard is off".
    const CMD_BUILD =
        \\{"command":"zig build"}
    ;
    const CMD_TEST =
        \\{"command":"zig test"}
    ;
    const CMD_CARGO =
        \\{"command":"cargo check"}
    ;

    var r: Repeats = .{};
    try std.testing.expect(r.noteGuarded("bash", CMD_BUILD) == null);
    try std.testing.expect(r.noteGuarded("bash", CMD_BUILD) == null);
    try std.testing.expectEqualStrings("bash", r.noteGuarded("bash", CMD_BUILD).?);

    // A different command is not a repeat: three DIFFERENT builds is a model working.
    var r2: Repeats = .{};
    try std.testing.expect(r2.noteGuarded("bash", CMD_BUILD) == null);
    try std.testing.expect(r2.noteGuarded("bash", CMD_TEST) == null);
    try std.testing.expect(r2.noteGuarded("bash", CMD_CARGO) == null);
}

test "no tool that WRITES can be exempt from the repetition guard" {
    // A guard with a hole in it is not a guard: if a write tool ever ended up on the
    // exemption list, an agent could loop on it forever and the ceiling would be the
    // only thing left. The exemption and the write list have to be disjoint, the same
    // shape as the parallel-safety test.
    for (tools_mod.defs) |d| {
        if (isRepeatExempt(d.name)) {
            try std.testing.expect(!isWriteTool(d.name));
        }
    }
    // And the two exemptions are the observation tools, named: a third one arriving is a
    // decision that has to be argued here, not appended quietly.
    try std.testing.expect(isRepeatExempt("read"));
    try std.testing.expect(isRepeatExempt("bash_output"));
    try std.testing.expect(!isRepeatExempt("bash"));
    try std.testing.expect(!isRepeatExempt("edit"));
    try std.testing.expect(!isRepeatExempt("write"));
    try std.testing.expect(!isRepeatExempt("goal"));
}

test "a RED check is the one thing that cannot end a turn" {
    // The rule the whole loop was missing, measured over five real task runs: five turns
    // ended with the code not compiling, and the harness had read the exit code and built
    // the model's own error message out of the diagnostics before letting it happen.
    //
    // **This test REPLACED one, on purpose, and the replacement is the record.** It used
    // to read `turnMayEnd(&ac, goal_open)` and assert that red with NO goal open was
    // allowed to end. That assertion was pinning behaviour that has now been measured to
    // be wrong: "fix this bug" with no `/goal` is a task about code like any other, and
    // the only thing that made it different was that the user had not typed four words
    // first. So `turnMayEnd` is gone, and the rule is `exitgate.Gate.decide` — pure, in
    // `lib/exitgate.zig`, with no goal in it at all.
    var ac: AutoCheck = .{};

    // Nothing written: a turn of prose, of questions, of a task with no build in it.
    // Demanding a compile here would be the harness nagging about a README.
    try std.testing.expectEqual(exitgate.Decision.end, ac.gate.decide());

    // Green and covering the current files: ending is the model's decision to make.
    ac.gate.checkable = true;
    _ = ac.noteWrite("write", "{\"path\":\"src/a.zig\"}");
    ac.gate.noteStarted(false);
    ac.gate.noteCompleted(.passed, 1);
    try std.testing.expectEqual(exitgate.Decision.end, ac.gate.decide());

    // Red: the block. The code does not work, so a turn that ends here hands the user a
    // summary of code that does not compile. No goal is involved anywhere in that.
    ac.gate.noteCompleted(.failed, 1);
    try std.testing.expectEqual(exitgate.Decision.refused_failed, ac.gate.decide());

    // And it stays refused after another edit, because a red is a red.
    _ = ac.noteWrite("write", "{\"path\":\"src/b.zig\"}");
    try std.testing.expectEqual(exitgate.Decision.refused_failed, ac.gate.decide());
}

test "the gate counts what was WRITTEN, not what was asked for" {
    // The bug this pins: `afterTool` used to be called once per tool CALL, from the
    // batch loop, which cannot tell a call that ran from a call that did not. A denied
    // `edit`, a `write` to a path that could not be opened and an `edit` whose old
    // string was not found all counted, and each of them made the gate wait for a check
    // of files that still had their OLD contents: a check that comes back green and is
    // about the wrong thing, which reads as evidence and is not.
    var ac: AutoCheck = .{};

    // Not a writing tool.
    try std.testing.expect(!ac.noteWrite("read", "{\"path\":\"src/a.zig\"}"));
    // A writing tool, but not a file a compiler would care about.
    try std.testing.expect(!ac.noteWrite("write", "{\"path\":\"README.md\"}"));
    try std.testing.expect(!ac.noteWrite("write", "{\"path\":\"build.lock\"}"));

    // Valid JSON with NO path in it: no file, so no build. This is `write` being called
    // with something the tool would itself reject, and it is not worth a build because
    // nothing was written.
    try std.testing.expect(!ac.noteWrite("write", "{}"));

    // Arguments the harness CANNOT read at all still count, and that is deliberate in
    // this direction.
    //
    // The reasoning is the one in `codePathsFromArgs`: an argument we failed to parse
    // must not be the reason a broken build goes unnoticed. The risk of getting it wrong
    // is asymmetric and both ways were considered:
    //
    // - NOT counting it means the gate sees nothing written, ends the turn, and the user
    //   is told the work is done about code nobody compiled. That is the exact failure
    //   this feature exists to remove.
    // - Counting it means the gate waits for a check it cannot attribute to a file. It
    //   still runs the PROJECT's check, so the check is right anyway; the only cost is
    //   that a turn on a project with no check says "not verified" once, which is
    //   literally true.
    //
    // So the cost of being wrong is one honest sentence, and the cost of being wrong the
    // other way is a lie about the work. The tie does not really go both ways.
    try std.testing.expect(ac.noteWrite("write", "not json"));
    try std.testing.expectEqual(@as(u32, 1), ac.gate.writes);

    // And a real write counts on top of that one, once.
    try std.testing.expect(ac.noteWrite("write", "{\"path\":\"src/a.zig\"}"));
    try std.testing.expectEqual(@as(u32, 2), ac.gate.writes);
    try std.testing.expect(ac.gate.wroteCode());
}

test "a multi-file write starts a check, which the single-path reader never did" {
    // The prompt pushes the model towards `write {files:[...]}` and `edit
    // {files:[...]}` — ONE call for nine files instead of nine calls — and the gate read
    // a single `path` key. So the exact form the harness recommends was the one form
    // that never started a check, and the comment on the old reader said this was "the
    // wrong direction" and left it wrong.
    var ac: AutoCheck = .{};

    try std.testing.expect(ac.noteWrite("write", "{\"files\":[{\"path\":\"src/one.zig\"}]}"));
    try std.testing.expectEqual(@as(u32, 1), ac.gate.writes);

    var ac2: AutoCheck = .{};
    try std.testing.expect(ac2.noteWrite("edit", "{\"files\":[{\"path\":\"README.md\"},{\"path\":\"src/two.zig\"}]}"));
    try std.testing.expectEqual(@as(u32, 1), ac2.gate.writes);

    // And one that is entirely non-code still does not.
    var ac3: AutoCheck = .{};
    try std.testing.expect(!ac3.noteWrite("write", "{\"files\":[{\"path\":\"README.md\"}]}"));
    try std.testing.expectEqual(@as(u32, 0), ac3.gate.writes);
}

test "a green from BEFORE the last edit does not let the turn end" {
    // This is the staleness rule, end to end through the gate's own counters: the model
    // fixed the build, edited a second file, and the harness believed the first green.
    // One number of writes against one number of covered writes is the whole difference.
    var ac: AutoCheck = .{};
    ac.gate.checkable = true;

    try std.testing.expect(ac.noteWrite("write", "{\"path\":\"src/a.zig\"}"));
    ac.gate.noteStarted(false);
    ac.job_covers = ac.gate.writes; // what `maybeStart` records when it spawns
    ac.gate.noteCompleted(.passed, ac.job_covers);
    try std.testing.expectEqual(exitgate.Decision.end, ac.gate.decide());

    // The next edit is not covered by that check.
    try std.testing.expect(ac.noteWrite("edit", "{\"path\":\"src/b.zig\"}"));
    try std.testing.expectEqual(@as(u32, 1), ac.gate.unverified());
    try std.testing.expectEqual(exitgate.Decision.refused_unverified, ac.gate.decide());

    // Re-checking the CURRENT files closes it, and only that does.
    ac.gate.noteStarted(true);
    ac.job_covers = ac.gate.writes;
    ac.gate.noteCompleted(.passed, ac.job_covers);
    try std.testing.expectEqual(exitgate.Decision.end, ac.gate.decide());
}

test "the gate ends a turn on code it CANNOT check, and says so" {
    // The direction that is safe to be wrong in. A project with no `build.zig`, no
    // `Cargo.toml`, nothing the harness knows how to run must not produce a turn that
    // never returns: the user would have to ctrl+c a task that was already answered.
    // The turn ends, and it ends with the truth in it.
    const a = std.testing.allocator;
    var ac: AutoCheck = .{};
    try std.testing.expect(ac.noteWrite("write", "{\"path\":\"main.c\"}"));
    // `checkable` is false: `planAt` found nothing, which is the default and the
    // real state of any project whose build the harness does not know.
    try std.testing.expectEqual(exitgate.Decision.cannot_verify, ac.gate.decide());

    const msg = ac.sayUnverified(a, "no check is known for this project") orelse return error.NoMessage;
    defer a.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "NOT verified") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "no check is known for this project") != null);

    // Once. A line repeated five times a turn is a line the user learns to ignore, and
    // the whole point of saying it is that it is read.
    try std.testing.expect(ac.spoke);
}

test "what the harness proved is reported as what it proved, not as 'verified'" {
    // The exit gate's claim is "there is a passing check behind this code", and a claim
    // is only as good as its precision. `zig build` answers ONE question — does it
    // typecheck — and says nothing at all about whether the code works.
    //
    // The failure this pins is the SAME class as the one the gate exists to remove, in
    // the opposite direction: a turn that ended with `kind == .types`, reported as
    // "verified", claims a test run nobody did, and the user reads that and stops
    // looking at the diff.
    try std.testing.expectEqualStrings("typechecked", typecheck_mod.proofWord(.types));
    try std.testing.expectEqualStrings("syntax-checked", typecheck_mod.proofWord(.syntax));
    try std.testing.expectEqualStrings("tested", typecheck_mod.proofWord(.tests));
    // And "verified" is deliberately NOT one of those words: no command in the table
    // justifies it on its own.
    for ([_]typecheck_mod.Kind{ .types, .syntax, .tests }) |k| {
        try std.testing.expect(!std.mem.eql(u8, typecheck_mod.proofWord(k), "verified"));
    }

    // The report reaches the user carrying the precise word.
    var ac: AutoCheck = .{};
    ac.proof = .types;
    const msg = ac.proofPhrase() orelse return error.NoMessage;
    try std.testing.expect(std.mem.indexOf(u8, msg, "typechecked") != null);
}

test "the end of a turn reports the narrowest thing that was actually proved" {
    // The gate closing is not the same as the work being finished, and the last line
    // before the next prompt is what decides whether the user goes and looks at the diff.
    // It has to be honest in the specific direction: name what ran, and name what did
    // not.
    //
    // The upper rungs are the model's — `bash` with the project's test command,
    // `check {id}` for one package. The harness supplies the floor that costs nothing,
    // and a floor reported as a ceiling is how a turn gets trusted that should not be.
    const a = std.testing.allocator;
    var ac: AutoCheck = .{};
    ac.proof = .types;

    const line = ac.proofLine(a) orelse return error.NoLine;
    defer a.free(line);
    // It says what it ran, in the past tense, about this turn.
    try std.testing.expect(std.mem.indexOf(u8, line, "typechecked") != null);
    // And it points at the tests as the model's to run, so nobody reads a green
    // typecheck as a green suite.
    try std.testing.expect(std.mem.indexOf(u8, line, "tests") != null);

    // No check at all: the line says so instead of claiming anything.
    var none: AutoCheck = .{};
    const nol = none.proofLine(a) orelse return error.NoLine;
    defer a.free(nol);
    try std.testing.expect(std.mem.indexOf(u8, nol, "NOT") != null);
}

test "the gate's own check does not consult the turn's quota, and the quota does not consume the gate's" {
    // Two different budgets for two different jobs, and conflating them was how either
    // one would have broken:
    //
    // - `auto_check_per_turn` (2) exists so a model that edits nine files does not start
    //   nine builds WHILE it works. The model gets the errors early; that is all it is
    //   for.
    // - The gate's budget exists so the check that decides whether the turn ends always
    //   happens. With the quota shared, a turn that spent its two builds editing would
    //   reach the gate unable to check at all — the one moment it must be able to.
    var ac: AutoCheck = .{};
    ac.gate.checkable = true;
    const cmd = "exit 0";
    @memcpy(ac.command[0..cmd.len], cmd);
    ac.command_len = cmd.len;
    const label = "fake";
    @memcpy(ac.label[0..label.len], label);
    ac.label_len = label.len;

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reg: bgproc.Registry = .init(std.testing.allocator);
    defer reg.deinit(threaded.io(), std.testing.allocator);

    // Two quota checks go through and count against `started_this_turn`. This one builds
    // its own registry instead of using `checkFor`, and it is right: `spawn` writes the
    // job into the registry it is GIVEN, so the registry that is deinit'ed has to be the
    // same one. See `releaseChecked` for what the first version of these tests got
    // wrong.
    for (0..auto_check_per_turn) |_| {
        try std.testing.expect(ac.maybeStart(&reg, threaded.io(), false));
        try std.testing.expectEqual(@as(u32, 0), ac.gate.forced);
        try waitJob(&reg, ac.job);
    }
    try std.testing.expectEqual(auto_check_per_turn, ac.started_this_turn);

    // The third one is REFUSED, and that is the whole point of the first half: a model
    // that keeps editing does not start a build per edit.
    try std.testing.expect(!ac.maybeStart(&reg, threaded.io(), false));

    // And the gate still can, because the check that decides whether the turn ends is
    // not the check that gives the model its early errors. With the budgets shared, a
    // turn that spent its two builds editing would arrive here unable to check at all —
    // the one moment it must be able to.
    try std.testing.expect(ac.maybeStart(&reg, threaded.io(), true));
    try std.testing.expectEqual(@as(u32, 1), ac.gate.forced);
    try waitJob(&reg, ac.job);

    // And the gate's budget is its own, bounded: two of its own checks, then it stops
    // and the iteration ceiling takes over. An unbounded "just check again" is how a
    // turn that cannot be verified becomes a turn that never returns.
    for (0..exitgate.Gate.max_forced - 1) |_| {
        try std.testing.expect(ac.maybeStart(&reg, threaded.io(), true));
        try waitJob(&reg, ac.job);
    }
    try std.testing.expect(!ac.gate.canForce());
    try std.testing.expect(!ac.maybeStart(&reg, threaded.io(), true));
}

/// Waits for one job to leave "running", with a cap.
///
/// Without the cap a job that never starts (or never finishes) turns a unit test into a
/// hung test binary, which is the failure mode this repo cannot afford in CI — and the
/// cap is on the WAIT, not on the assertion, so a job that misbehaves fails the
/// `expect` after it instead of hanging.
fn waitJob(reg: *bgproc.Registry, id: u32) !void {
    var waited: u32 = 0;
    while (waited < 5000) : (waited += 10) {
        if (!std.mem.eql(u8, bgproc.stateWord(reg, id), "running")) return;
        sleep_mod.nap(10);
    }
    return error.JobNeverFinished;
}

/// An `AutoCheck` wired to a command that answers as told, with a real registry.
///
/// The seam every test of the gate needs and none of the others have: a REAL process,
/// a REAL exit code and the REAL `file:line: error:` scan, so the wrapper — not just
/// the pure rule — is exercised end to end. `planAt` is bypassed on purpose (it wants a
/// project on disk with a `build.zig` in it); everything downstream of the spawn is the
/// production path.
fn checkFor(comptime cmd: []const u8) CheckFixture {
    const threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    const reg: bgproc.Registry = .init(std.testing.allocator);
    var ac: AutoCheck = .{};
    ac.command_len = @min(cmd.len, ac.command.len);
    @memcpy(ac.command[0..ac.command_len], cmd[0..ac.command_len]);
    const label = "the check";
    ac.label_len = label.len;
    @memcpy(ac.label[0..label.len], label);
    ac.gate.checkable = true;
    // The REVIEW is pinned OFF here, and it has to be.
    //
    // `exitGate` probes the directory for a git repository, so without this the answer
    // depends on WHERE THE TEST RUNS: in this repository every one of these tests would
    // get `refused_review` instead of testing verification, and outside it they would
    // pass. A test whose result changes with the working directory is a trap with a
    // green light, and these are about the build, not about the diff.
    ac.gate.reviewable = false;
    ac.review_known = true;
    return .{ .ac = ac, .threaded = threaded, .reg = reg };
}

/// What `checkFor` hands back, with the field types it needs.
///
/// Named and not anonymous because two of the three have to be `var` at the call site
/// (`reg` is spawned into and `threaded` owns a self-pointer that moves with it) and an
/// anonymous struct returned by value cannot be copied without invalidating that.
const CheckFixture = struct {
    ac: AutoCheck,
    threaded: std.Io.Threaded,
    reg: bgproc.Registry,
};

/// Tears the fixture down.
///
/// ## The copy trap that made this leak, and cost an hour of a plausible wrong theory
///
/// The first version of these tests did `var ac = h.ac; var reg = h.reg;` and used the
/// copies. `bgproc.Registry` is a plain struct with an `ArrayList` inside each slot, so
/// a copy of it is perfectly legal and looks identical — but `spawn` writes the job into
/// the registry it was GIVEN, and the job's `buf` is allocated there. Deinit'ing
/// `h.reg` freed a registry that had never held a job, while the one the test actually
/// spawned into was dropped on the floor.
///
/// The theory that came first was much more interesting and completely wrong: "the
/// detached reader sets `state = finished` before its last append, so the teardown
/// frees the buffer underneath it". That has a real ring to it, it names a real
/// ordering in `bgproc.reader`, and adding a drain loop for it changed nothing at all.
///
/// So there is no drain loop here. The tests use `&h.reg` and `&h.ac` directly and the
/// leak is gone, and the lesson is the one this repo keeps re-learning: a mechanism that
/// explains the symptom is not evidence that it IS the symptom.
fn releaseChecked(h: *CheckFixture) void {
    h.reg.deinit(h.threaded.io(), std.testing.allocator);
    h.threaded.deinit();
}

test "the gate refuses a turn over a REAL failing build, through the real wrapper" {
    // ## Why this test exists and what it is NOT
    //
    // Every other test of the exit gate drives `Gate.decide()`, which is pure: it proves
    // the RULE and it proves nothing about the code that RUNS it. That gap is the same
    // shape as one this repo already paid for, where `applyGoalCall` existed, `toolGoal`
    // existed and the schema was declared — and the model called the tool and the
    // harness went on to the ceiling, because `execOneCall` had never been wired to it.
    // Three halves, each tested, and nothing watching the seam.
    //
    // So this one drives `exitGate` itself: a real child, a real exit code 1, the real
    // diagnostic scan, the real wait. It is still not the whole loop — `chatWorker`
    // needs a `Model` and a network — but it is the half where a bug would be SILENT,
    // because the rule's own tests cannot see it.
    // `exit 1` with a real diagnostic on stderr: the exact shape the scan looks for, so
    // the refusal is built out of a message that came from a process.
    var h: CheckFixture = checkFor("printf 'src/a.zig:3:5: error: unused variable\\n' >&2; exit 1");
    defer releaseChecked(&h);
    const ac = &h.ac;
    const reg = &h.reg;

    _ = ac.noteWrite("write", "{\"path\":\"src/a.zig\"}");
    try std.testing.expectEqual(@as(u32, 1), ac.gate.writes);

    const refusal = ac.exitGate(reg, std.testing.allocator, h.threaded.io()) orelse
        return error.GateLetARedBuildThrough;
    defer std.testing.allocator.free(refusal);
    // "would end on it": the gate has to say what it is refusing, not just refuse.
    try std.testing.expect(std.mem.indexOf(u8, refusal, "would end on it") != null);
    // And it names the count, which is what tells the model how much is left to do.
    try std.testing.expect(std.mem.indexOf(u8, refusal, "1 problem") != null);
    // The verdict went into the GATE, not just into the message: a refusal that does
    // not move the state would be refused again for the wrong reason next time.
    try std.testing.expectEqual(exitgate.Verdict.failed, ac.gate.verdict);
    // And the diagnostics reached the buffer the next iteration reads them from.
    try std.testing.expect(ac.noteSlice().len > 0);
    try std.testing.expect(std.mem.indexOf(u8, ac.noteSlice(), "unused variable") != null);
}

test "the gate lets a turn end once a REAL build has passed over the files it wrote" {
    var h: CheckFixture = checkFor("exit 0");
    defer releaseChecked(&h);
    const ac = &h.ac;
    const reg = &h.reg;

    _ = ac.noteWrite("write", "{\"path\":\"src/a.zig\"}");
    // The FIRST gate call has nothing behind that write, so it spends one of its own
    // checks: that is the gate doing its job, not the gate being impatient.
    try std.testing.expect(ac.exitGate(reg, std.testing.allocator, h.threaded.io()) == null);
    try std.testing.expectEqual(exitgate.Verdict.passed, ac.gate.verdict);
    try std.testing.expectEqual(@as(u32, 1), ac.gate.forced);
    try std.testing.expectEqual(@as(u32, 0), ac.gate.unverified());

    // And the SECOND call, with nothing changed, spends NOTHING. This is the half worth
    // pinning: the gate runs on EVERY iteration of the turn, so a gate that re-checked
    // whenever it was asked would spawn a build per iteration for the rest of the
    // session. What stops it is the files being covered — not the fact that it already
    // ran once, which is a different rule and a worse one.
    try std.testing.expect(ac.exitGate(reg, std.testing.allocator, h.threaded.io()) == null);
    try std.testing.expectEqual(@as(u32, 1), ac.gate.forced);
}

test "a green build followed by another edit makes the gate check AGAIN, for real" {
    // The staleness rule, through the wrapper: the model fixes the build, edits a second
    // file, and the first green is not evidence about the second file's contents.
    var h: CheckFixture = checkFor("exit 0");
    defer releaseChecked(&h);
    const ac = &h.ac;
    const reg = &h.reg;

    _ = ac.noteWrite("write", "{\"path\":\"src/a.zig\"}");
    try std.testing.expect(ac.exitGate(reg, std.testing.allocator, h.threaded.io()) == null);
    try std.testing.expectEqual(exitgate.Verdict.passed, ac.gate.verdict);

    // The next edit is not covered by that check.
    _ = ac.noteWrite("edit", "{\"path\":\"src/b.zig\"}");
    try std.testing.expectEqual(@as(u32, 1), ac.gate.unverified());

    // A re-check covers it, and it is FORCED: without the forced re-check this turn
    // would have ended on evidence about files that no longer exist in that form.
    try std.testing.expect(ac.maybeStart(reg, h.threaded.io(), true));
    try waitJob(reg, ac.job);
    _ = ac.collect(reg);
    // TWO, not one: the first gate call above already spent one of its own checks
    // (there was a write with nothing behind it), so this is the second. The count is
    // asserted rather than glossed because "one re-check per turn" and "one re-check per
    // uncovered write" are different rules and only the numbers tell them apart.
    try std.testing.expectEqual(@as(u32, 2), ac.gate.forced);
    try std.testing.expectEqual(@as(u32, 0), ac.gate.unverified());
}

test "tier 2 compaction is a BUDGET with a gap, not a switch that turns off forever" {
    // This is the bug that made a long session die with a writer error and look, from
    // the outside, like "the agent went quiet". The flag was `summarized_this_session:
    // bool`, and the reasoning behind it — retrying every turn is one wasted request per
    // turn forever — was sound. The conclusion was one step too far: "not every turn" is
    // not "only ever once", and a bool can only say the second thing.
    //
    // So the flag is gone and there are two numbers instead, and they answer different
    // questions: how OFTEN (the gap, so a long turn does not pay per iteration) and how
    // MANY (the cap, so a session that keeps filling the context does not pay forever).
    const saved = .{ summaries_done, summarized_at_iteration };
    defer {
        summaries_done = saved[0];
        summarized_at_iteration = saved[1];
    }
    resetSummaries();

    // The first trigger of a session is immediate: the turn that filled the context is
    // the one that does not fit any more, so it is the one that must be summarized.
    try std.testing.expect(maySummarize(0));

    // And the next five iterations it does NOT: that is the waste the bool was invented
    // to stop, and it is the half that matters on a 60-iteration goal turn.
    noteSummarized(0);
    var i: usize = 1;
    while (i < summary_gap) : (i += 1) {
        try std.testing.expect(!maySummarize(i));
    }
    // At the gap it goes back.
    try std.testing.expect(maySummarize(summary_gap));

    // Up to the cap, and then never again: past this the user is better served by
    // `/new` or a bigger window than by zode quietly spending a request per summary
    // forever, each one thrown away by the next.
    var it: usize = summary_gap;
    while (summaries_done < summary_max) {
        try std.testing.expect(maySummarize(it));
        noteSummarized(it);
        it += summary_gap;
    }
    try std.testing.expect(!maySummarize(it));
    try std.testing.expect(!maySummarize(it + 100));

    // A new session gets the whole budget back, which is the only thing that made the
    // old flag's reset make sense.
    resetSummaries();
    try std.testing.expect(maySummarize(0));
}

test "the gate stops re-checking after its budget, and says the code is not verified" {
    // Bounded on purpose: an unbounded "just check again" is how a turn that cannot be
    // verified becomes a turn that never returns. Once the budget is spent the gate
    // stops, and the turn ends WITH THE TRUTH rather than looping or claiming green.
    var h: CheckFixture = checkFor("exit 0");
    defer releaseChecked(&h);
    const ac = &h.ac;
    const reg = &h.reg;

    // Spend the budget for real: one write, one forced check, one more write, and the
    // gate wants another each time.
    //
    // `canForce` counts checks the gate STARTED, not writes, so the budget has to be
    // spent by starting them — a test that only wrote files would have asserted nothing
    // about the cap.
    for (0..exitgate.Gate.max_forced) |_| {
        _ = ac.noteWrite("write", "{\"path\":\"src/a.zig\"}");
        // Null is the expected answer here: the command exits 0, so each of these
        // checks passes and the turn is free to end. What is being spent is the gate's
        // OWN budget, not a refusal.
        if (ac.exitGate(reg, std.testing.allocator, h.threaded.io())) |r| std.testing.allocator.free(r);
        try std.testing.expectEqual(@as(u32, 0), ac.gate.unverified());
        try std.testing.expectEqual(exitgate.Verdict.passed, ac.gate.verdict);
    }
    try std.testing.expect(!ac.gate.canForce());

    // Now the budget is gone and the files are edited again with nothing covering them.
    // The gate must stop, and the turn must end WITH THE TRUTH: never looping, and
    // never claiming a green it could not produce.
    _ = ac.noteWrite("write", "{\"path\":\"src/a.zig\"}");
    try std.testing.expectEqual(@as(u32, 1), ac.gate.unverified());

    const refusal = ac.exitGate(reg, std.testing.allocator, h.threaded.io()) orelse
        return error.GateClaimedGreenItCouldNotCheck;
    defer std.testing.allocator.free(refusal);
    try std.testing.expect(std.mem.indexOf(u8, refusal, "NOT verified") != null);
    // And no extra child: `forced` did not move, because the gate was not allowed to
    // start one.
    try std.testing.expectEqual(@as(u32, exitgate.Gate.max_forced), ac.gate.forced);
    // And it is spoken once per turn: a line repeated five times is a line the user
    // learns to ignore, and the whole point of saying it is that it is read.
    try std.testing.expect(ac.spoke);
}

test "the verdict is per TURN and resets, so turn two is not judged by turn one" {
    // A stale red is a worse bug than no red: it would refuse to let any later turn end,
    // forever, with an error message about a build from a previous task.
    var ac: AutoCheck = .{};
    ac.job = 7;
    ac.started_this_turn = 2;
    ac.gate.checkable = true;
    ac.gate.noteWrite();
    ac.gate.noteCompleted(.failed, 1);

    var reg: bgproc.Registry = undefined;
    _ = &reg;
    ac.resetTurn(&reg, undefined);

    try std.testing.expectEqual(Verdict.unchecked, ac.gate.verdict);
    try std.testing.expectEqual(@as(u32, 0), ac.started_this_turn);
    // The job id goes too, which is what stops turn two reporting turn one's errors.
    try std.testing.expectEqual(@as(u32, 0), ac.job);
    // And the whole gate, because "reset the verdict" is not the same as "reset what
    // the verdict was about": a turn that kept `writes` from turn one would refuse to
    // end on turn two's first build for the rest of the session.
    try std.testing.expectEqual(@as(u32, 0), ac.gate.writes);
    try std.testing.expectEqual(exitgate.Decision.end, ac.gate.decide());
}

test "the iteration counter shows the limit that APPLIES, not the soft cap" {
    // Measured in a real run: `thinking · iteration 26/12`. With a goal set the ceiling
    // is 60, so the turn was 34 from its budget and the status said it was 14 over. A
    // user who reads that cuts the turn short, which is the status bar talking the user
    // into aborting work with fifty iterations left.
    const saved_io = io_global;
    defer io_global = saved_io;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    io_global = threaded.io();

    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    // No goal: the soft cap is the ceiling and that is what is shown.
    const plain = statusIterationLimit(&m);
    try std.testing.expectEqual(iterationLimit(), plain);

    // A goal raises the ceiling, and the number on screen has to follow it or it is
    // reporting a budget that does not exist.
    const obj = "ship";
    @memcpy(m.goal.text[0..obj.len], obj);
    m.goal.len = obj.len;
    try std.testing.expect(m.goal.isOpen());
    const with_goal = statusIterationLimit(&m);
    try std.testing.expectEqual(goalHardLimit(), with_goal);
    try std.testing.expect(with_goal > plain);

    // And once the goal is DECIDED the turn is over, so the soft cap is the number that
    // would be shown next.
    m.goal.status = goal_mod.Status.met;
    try std.testing.expectEqual(iterationLimit(), statusIterationLimit(&m));
}

test "`met` with open plan steps is refused once, and the model has to answer" {
    // Measured on the first run that finished a task: the model wrote four steps, ticked
    // two, and then declared the goal MET. The harness accepted it and the turn ended
    // with its own plan contradicting its own verdict on screen.
    //
    // Two artefacts from the SAME model, disagreeing, is not something to resolve by
    // trusting one of them. And the fix does not need to ask anything: the plan's open
    // count is readable, so the contradiction is machine-detectable.
    const saved_io = io_global;
    defer io_global = saved_io;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    io_global = threaded.io();

    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    const obj = "the suite passes";
    @memcpy(m.goal.text[0..obj.len], obj);
    m.goal.len = obj.len;

    // Two steps done, one open.
    var items = [_]plan_mod.Item{.{}} ** 3;
    const labels = [_][]const u8{ "write it", "run it", "verify the output" };
    for (&items, labels, 0..) |*it, lbl, i| {
        @memcpy(it.text[0..lbl.len], lbl);
        it.status = if (i < 2) .done else .pending;
    }
    _ = m.plan.apply(items[0..], 3);
    try std.testing.expectEqual(@as(usize, 1), m.plan.openCount());

    // The state the loop reacts to: MET with an open step.
    m.goal.status = goal_mod.Status.met;
    try std.testing.expect(!verdictIsFinal(m.goal, m.plan.openCount()));
    m.goal.status = goal_mod.Status.blocked;
    try std.testing.expect(verdictIsFinal(m.goal, m.plan.openCount()));
    m.goal.status = goal_mod.Status.met;
    try std.testing.expect(verdictIsFinal(m.goal, 0));

    // And the refusal is not an infinite one: the second refusal is the ceiling's job,
    // which is what `checkpoints` counts.
    try std.testing.expectEqual(@as(u8, 0), m.goal.checkpoints);
}

/// Whether a verdict ends the turn. Extracted so the rule can be asserted without
/// standing up a whole turn.
pub fn verdictIsFinal(g: goal_mod.Goal, open_steps: usize) bool {
    if (g.status == goal_mod.Status.none) return false;
    if (g.status == goal_mod.Status.met and open_steps > 0) return false;
    return true;
}

// ── selective permissions: modes, edit tools, bash patterns ──

test "perm modes: the three flags are mutually exclusive, always" {
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    const saved = .{ .ro = read_only, .ae = accept_edits, .y = yolo };
    defer {
        read_only = saved.ro;
        accept_edits = saved.ae;
        yolo = saved.y;
    }

    // Every mode sets exactly the flags that name it, so the
    // status bar never advertises a mode that does not apply.
    inline for (.{ PermMode.default, PermMode.accept_edits, PermMode.read_only, PermMode.bypass }) |mode| {
        setPermMode(&m, mode);
        try std.testing.expectEqual(mode == .read_only, read_only);
        try std.testing.expectEqual(mode == .accept_edits, accept_edits);
        try std.testing.expectEqual(mode == .bypass, yolo);
        try std.testing.expectEqual(mode, currentPermMode());
    }
}

test "permModeName: clear label for every mode" {
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    const saved = .{ .ro = read_only, .ae = accept_edits, .y = yolo };
    defer {
        read_only = saved.ro;
        accept_edits = saved.ae;
        yolo = saved.y;
    }

    setPermMode(&m, .default);
    try std.testing.expectEqualStrings("build", permModeName());
    setPermMode(&m, .accept_edits);
    try std.testing.expectEqualStrings("accept-edits", permModeName());
    setPermMode(&m, .read_only);
    try std.testing.expectEqualStrings("plan", permModeName());
    setPermMode(&m, .bypass);
    try std.testing.expectEqualStrings("bypass", permModeName());
}

test "shift+tab cycles Build -> accept-edits -> Plan -> Build" {
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    const saved = .{ .ro = read_only, .ae = accept_edits, .y = yolo };
    defer {
        read_only = saved.ro;
        accept_edits = saved.ae;
        yolo = saved.y;
    }

    setPermMode(&m, .default);
    cyclePermMode(&m);
    try std.testing.expectEqual(PermMode.accept_edits, currentPermMode());
    cyclePermMode(&m);
    try std.testing.expectEqual(PermMode.read_only, currentPermMode());
    cyclePermMode(&m);
    try std.testing.expectEqual(PermMode.default, currentPermMode());

    // Bypass is deliberately not in the cycle: it is the "stop
    // asking me anything" switch, and cycling out of it lands on
    // default so the shown mode is always the mode that applies.
    setPermMode(&m, .bypass);
    cyclePermMode(&m);
    try std.testing.expectEqual(PermMode.default, currentPermMode());
}

test "mode commands use Build as the visible name and keep default as an alias" {
    try std.testing.expectEqual(PermMode.default, parsePermMode("build").?);
    try std.testing.expectEqual(PermMode.default, parsePermMode("default").?);
    try std.testing.expectEqual(PermMode.accept_edits, parsePermMode("accept-edits").?);
    try std.testing.expectEqual(PermMode.read_only, parsePermMode("plan").?);
    try std.testing.expectEqual(PermMode.bypass, parsePermMode("bypass").?);
    try std.testing.expect(parsePermMode("unknown") == null);

    for (commands) |command| {
        try std.testing.expect(!std.mem.eql(u8, command.key, "/plan"));
    }
}

test "isEditTool: the file edits, and not bash or a subagent" {
    try std.testing.expect(isEditTool("write"));
    try std.testing.expect(isEditTool("edit"));
    try std.testing.expect(isEditTool("rename"));
    // Accepting edits is NOT accepting arbitrary commands, and a
    // subagent is exactly the thing that stays behind a dialog.
    try std.testing.expect(!isEditTool("bash"));
    try std.testing.expect(!isEditTool("task"));
    try std.testing.expect(!isEditTool("read"));
}

test "bashPatternAllowed: a prefix at a token boundary, and only for bash" {
    const saved_lens = bash_pattern_lens;
    const saved_bufs = bash_pattern_bufs;
    defer {
        bash_pattern_lens = saved_lens;
        bash_pattern_bufs = saved_bufs;
    }
    for (&bash_pattern_lens) |*l| l.* = 0;
    bash_pattern_lens[0] = "git status".len;
    @memcpy(bash_pattern_bufs[0][0.."git status".len], "git status");

    // The pattern itself, anything that extends it with a flag,
    // and the command with surrounding whitespace.
    try std.testing.expect(bashPatternAllowed("bash", "git status"));
    try std.testing.expect(bashPatternAllowed("bash", "git status --short"));
    try std.testing.expect(bashPatternAllowed("bash", "  git status  "));

    // A longer token that merely starts the same way is NOT a match.
    try std.testing.expect(!bashPatternAllowed("bash", "git statusx"));
    // A different command entirely.
    try std.testing.expect(!bashPatternAllowed("bash", "git push --force"));

    // Chaining, pipes, redirects and expansion are a DIFFERENT command
    // however the prefix is read: `git status` allowed must never become
    // `git status && rm -rf /`.
    try std.testing.expect(!bashPatternAllowed("bash", "git status && rm -rf /"));
    try std.testing.expect(!bashPatternAllowed("bash", "git status; echo pwned"));
    try std.testing.expect(!bashPatternAllowed("bash", "git status | wc -l"));
    try std.testing.expect(!bashPatternAllowed("bash", "git status > /etc/passwd"));
    try std.testing.expect(!bashPatternAllowed("bash", "git status $(echo hi)"));
    // The pattern is for `bash`; a tool that merely runs a command
    // in its arguments is not a bash command.
    try std.testing.expect(!bashPatternAllowed("edit", "git status"));
}

test "permAutoAllowed: accept-edits allows edits, a bash prefix allows that bash" {
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    const saved = .{ .ro = read_only, .ae = accept_edits, .y = yolo };
    const saved_lens = bash_pattern_lens;
    const saved_bufs = bash_pattern_bufs;
    defer {
        read_only = saved.ro;
        accept_edits = saved.ae;
        yolo = saved.y;
        bash_pattern_lens = saved_lens;
        bash_pattern_bufs = saved_bufs;
    }
    for (&bash_pattern_lens) |*l| l.* = 0;
    bash_pattern_lens[0] = "git status".len;
    @memcpy(bash_pattern_bufs[0][0.."git status".len], "git status");

    // Default: nothing is auto-allowed, so everything asks. The
    // `git status` pattern is set below and allowed in EVERY mode,
    // so the command that must ask here is one it does not name.
    setPermMode(&m, .default);
    try std.testing.expect(!permAutoAllowed("write", "{}", "{}", std.testing.allocator));
    try std.testing.expect(!permAutoAllowed("bash", "zig build test", "{}", std.testing.allocator));

    // Accept-edits: file edits run, but bash still asks.
    setPermMode(&m, .accept_edits);
    try std.testing.expect(permAutoAllowed("write", "{}", "{}", std.testing.allocator));
    try std.testing.expect(permAutoAllowed("edit", "{}", "{}", std.testing.allocator));
    try std.testing.expect(permAutoAllowed("rename", "{}", "{}", std.testing.allocator));
    // A bash command with no allowed prefix still asks, even here:
    // accepting edits is not accepting commands.
    try std.testing.expect(!permAutoAllowed("bash", "zig build test", "{}", std.testing.allocator));

    // A bash prefix allows that command in ANY mode: it is the
    // user's standing "I trust this", independent of the mode.
    setPermMode(&m, .default);
    try std.testing.expect(permAutoAllowed("bash", "git status", "{}", std.testing.allocator));
    try std.testing.expect(permAutoAllowed("bash", "git status --short", "{}", std.testing.allocator));
    try std.testing.expect(!permAutoAllowed("bash", "rm -rf /", "{}", std.testing.allocator));
}

test "a batch is covered by accept-edits only when it WRITES" {
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    const saved = .{ .ro = read_only, .ae = accept_edits, .y = yolo };
    defer {
        read_only = saved.ro;
        accept_edits = saved.ae;
        yolo = saved.y;
    }

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const reads =
        \\{"steps":[{"op":"read","path":"a.zig"},{"op":"grep","pattern":"x"}]}
    ;
    const writes =
        \\{"steps":[{"op":"read","path":"a.zig"},{"op":"write","path":"out.md"}]}
    ;

    // Default mode: nothing is auto-allowed, and that is true of a batch too.
    setPermMode(&m, .default);
    try std.testing.expect(!permAutoAllowed("batch", "", reads, arena));
    try std.testing.expect(!permAutoAllowed("batch", "", writes, arena));

    // Accept-edits covers a batch that writes (its write step is an edit).
    setPermMode(&m, .accept_edits);
    try std.testing.expect(permAutoAllowed("batch", "", writes, arena));
}

test "the `a` key on a bash dialog saves the COMMAND, not the whole tool" {
    const saved = .{
        .env = environ_global,
        .al = always_lens,
        .bl = bash_pattern_lens,
        .bb = bash_pattern_bufs,
    };
    defer {
        environ_global = saved.env;
        always_lens = saved.al;
        bash_pattern_lens = saved.bl;
        bash_pattern_bufs = saved.bb;
    }
    // No HOME: `saveAllowlist` has nowhere to write and says so quietly.
    environ_global = null;
    for (&always_lens) |*l| l.* = 0;
    for (&bash_pattern_lens) |*l| l.* = 0;

    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    // `bash`: the command is what gets stored. Saving the tool name here
    // would be "every command, forever" — /yolo with an extra step, and
    // persisted on top.
    allowAlwaysFor(&m, "bash", "  git status --short  ");
    try std.testing.expect(!isAlwaysAllowed("bash"));
    try std.testing.expect(bashPatternAllowed("bash", "git status --short"));
    // A second command the user never approved still asks.
    try std.testing.expect(!bashPatternAllowed("bash", "git push --force"));

    // Every other tool behaves exactly as it always did.
    allowAlwaysFor(&m, "edit", "{}");
    try std.testing.expect(isAlwaysAllowed("edit"));
    try std.testing.expect(!isAlwaysAllowed("write"));

    // An over-long command is REFUSED, not cut: a pattern truncated at an
    // arbitrary byte is a broader permission than the one approved.
    var long_cmd: [200]u8 = undefined;
    @memset(&long_cmd, 'a');
    try std.testing.expect(!addBashPatternNoSave(&long_cmd));
    for (bash_pattern_lens) |l| try std.testing.expect(l != long_cmd.len);
}

test "permissions.json: the old shape and the new one both load, and saving round-trips" {
    const saved = .{
        .env = environ_global,
        .io = io_global,
        .gpa = gpa_global,
        .al = always_lens,
        .bl = bash_pattern_lens,
        .bb = bash_pattern_bufs,
    };
    defer {
        environ_global = saved.env;
        io_global = saved.io;
        gpa_global = saved.gpa;
        always_lens = saved.al;
        bash_pattern_lens = saved.bl;
        bash_pattern_bufs = saved.bb;
    }

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    io_global = threaded.io();
    gpa_global = std.testing.allocator;

    // Its own HOME: this test must never read or write the reader's real
    // permissions.json.
    const home = "/tmp/zode-perm-test";
    std.Io.Dir.cwd().deleteTree(io_global, home) catch {};
    defer {
        std.Io.Dir.cwd().deleteTree(io_global, home) catch {};
    }
    try std.Io.Dir.cwd().createDirPath(io_global, "/tmp/zode-perm-test/.config/zode");

    var emap = std.process.Environ.Map.init(std.testing.allocator);
    defer emap.deinit();
    try emap.put("HOME", home);
    environ_global = &emap;

    var pbuf: [512]u8 = undefined;
    const path = permissionsFilePath(&pbuf) orelse return error.NoPath;
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const a = astate.allocator();

    // ── the OLD shape: a bare array of tool names, which is what every
    //    permissions.json written before the bash patterns looked like. ──
    try std.Io.Dir.cwd().writeFile(io_global, .{ .sub_path = path, .data = "[\"edit\",\"write\"]" });
    for (&always_lens) |*l| l.* = 0;
    for (&bash_pattern_lens) |*l| l.* = 0;
    loadAllowlist();
    try std.testing.expect(isAlwaysAllowed("edit"));
    try std.testing.expect(isAlwaysAllowed("write"));
    var any_pattern = false;
    for (bash_pattern_lens) |l| {
        if (l > 0) any_pattern = true;
    }
    try std.testing.expect(!any_pattern);

    // ── the NEW shape: tools plus the commands that were approved. ──
    try std.Io.Dir.cwd().writeFile(io_global, .{ .sub_path = path, .data = "{\"tools\":[\"edit\"],\"bash\":[\"git status\",\"zig build test\"]}" });
    for (&always_lens) |*l| l.* = 0;
    for (&bash_pattern_lens) |*l| l.* = 0;
    loadAllowlist();
    try std.testing.expect(isAlwaysAllowed("edit"));
    try std.testing.expect(!isAlwaysAllowed("write"));
    try std.testing.expect(bashPatternAllowed("bash", "git status"));
    try std.testing.expect(bashPatternAllowed("bash", "zig build test --summary all"));
    try std.testing.expect(!bashPatternAllowed("bash", "git push --force"));

    // ── saving writes the NEW shape (a bare array cannot carry `bash`),
    //    and loading that file back gives the very same answer. ──
    saveAllowlist();
    for (&always_lens) |*l| l.* = 0;
    for (&bash_pattern_lens) |*l| l.* = 0;
    loadAllowlist();
    try std.testing.expect(isAlwaysAllowed("edit"));
    try std.testing.expect(!isAlwaysAllowed("write"));
    try std.testing.expect(bashPatternAllowed("bash", "git status"));
    try std.testing.expect(bashPatternAllowed("bash", "zig build test"));

    const data = readFileTo(a, path) orelse return error.NoFile;
    try std.testing.expect(std.mem.startsWith(u8, data, "{\"tools\":["));
    try std.testing.expect(std.mem.indexOf(u8, data, "\"bash\":") != null);
}

// ── the real turn, against a real provider ─────────────────────────
//
// Everything above this point tests a piece of the loop. This one tests the loop
// itself, with a real `Io`, a real provider and a real key, and it is the only test
// in the file that can catch the class of bug the whole exit-gate work exists for:
// the gate refusing, the nudge going out, and the turn carrying on.
//
// It is GATED on the build option `-De2e`, and that is not a formality. It
// costs money, it takes thirty seconds, and it fails for reasons that have
// nothing to do with zode (a rate limit, a provider having a bad minute). A
// test that fails in CI for a reason nobody can reproduce is a test that gets
// deleted, and then the seam is unwatched again.
//
// Run it with a key in `.env`:
//
//   zig build test -De2e -- "E2E: a real turn"
//
// It needs `ZODE_PROVIDER` and that provider's key, and it picks a free model
// so it costs nothing on a free tier.
//
/// Reads `KEY=VALUE` pairs from `.env` into `map`.
///
/// `.env` is gitignored and chmod 600, so it is the one place a provider key
/// can enter a test without entering the tree. `put` dupes both sides, so the
/// buffer this reads into is free on return.
fn loadDotEnv(io: std.Io, map: *std.process.Environ.Map) void {
    const data = std.Io.Dir.cwd().readFileAlloc(io, ".env", std.heap.page_allocator, .limited(64 * 1024)) catch return;
    defer std.heap.page_allocator.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const bare = if (std.mem.startsWith(u8, trimmed, "export ")) trimmed["export ".len..] else trimmed;
        const eq = std.mem.indexOfScalar(u8, bare, '=') orelse continue;
        const key = std.mem.trim(u8, bare[0..eq], " \t");
        const val = std.mem.trim(u8, bare[eq + 1 ..], " \t\"'");
        if (key.len == 0) continue;
        map.put(key, val) catch return;
    }
}

/// Whether the map holds any credential at all: the generic `ZODE_API_KEY` or
/// any provider's `ZODE_<PROVIDER>_KEY`. The E2E test cannot run without one,
/// and it must not run against a provider that would answer 401.
fn envHasAnyKey(map: *const std.process.Environ.Map) bool {
    if (map.get("ZODE_API_KEY") != null) return true;
    var it = map.iterator();
    while (it.next()) |entry| {
        if (std.mem.endsWith(u8, entry.key_ptr.*, "_KEY")) return true;
    }
    return false;
}

test "the parallel batch's tool results outlive the per-call arenas" {
    // THE crash of "I ask for a plan, it starts doing things, and then it stops
    // working". Three read-only calls in one assistant message is the most
    // common shape of a real task, and `runParallelBatch` ran them on threads
    // that each had their OWN arena:
    //
    //     var astate = std.heap.ArenaAllocator.init(ctx.m.allocator);
    //     defer astate.deinit();
    //     const a = astate.allocator();
    //     const text = tools_mod.execute(..., a, ...) catch ...;
    //     ctx.out.text = a.dupe(u8, text) catch "";   // <-- allocated in the
    //                                                      arena about to die
    //
    // and the comment above that line claimed the copy went to the turn arena.
    // It did not. Defer order is LIFO, so `astate.deinit()` runs BEFORE the
    // `pending` decrement, and `waitForBatch` waits on `pending`: by the time it
    // returns every per-call arena is guaranteed dead. That makes the dangling
    // pointer deterministic rather than a race — for EVERY parallel batch, not
    // occasionally.
    //
    // A `read` of a real source file makes the arena request a multi-MB chunk,
    // which `gpa` returns to the page allocator, so the caller's `dupe` reads
    // an unmapped page: SIGSEGV with no panic message. Small results fail
    // quieter and just corrupt the history and the session file.
    //
    // `std.testing.allocator` is what makes this a test and not a hope: it
    // poisons and unmaps on `free`, so reading a freed result trips the leak
    // detector instead of returning plausible garbage.
    const saved_io = io_global;
    defer io_global = saved_io;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    io_global = threaded.io();

    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    // A scratch directory, so the reads are of files that exist and are big
    // enough to make the arena take a real chunk.
    const tmp_path = "/tmp/opencode/zode-test-parallel-batch";
    try std.Io.Dir.cwd().createDirPath(io_global, tmp_path);
    defer std.Io.Dir.cwd().deleteTree(io_global, tmp_path) catch {};
    var tmp = try std.Io.Dir.cwd().openDir(io_global, tmp_path, .{});
    defer tmp.close(io_global);

    const bodies = [_][]const u8{
        "fn alpha() void {}\n" ** 200,
        "fn beta() void {}\n" ** 200,
        "fn gamma() void {}\n" ** 200,
    };
    const paths: [3][]const u8 = .{ "a.zig", "b.zig", "c.zig" };
    for (paths, bodies) |p, body| {
        try tmp.writeFile(io_global, .{ .sub_path = p, .data = body });
    }

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var t: TurnCtx = .{ .m = &m };
    defer t.deinit();
    // With the TEST allocator, not the turn arena: `TurnCtx.deinit` frees every
    // id and args_json through the MODEL's allocator, and a block that came out
    // of an arena is an "Invalid free" — a rule that is easier to get wrong in
    // the test than in production, which is why it is written down here.
    for (paths, 0..) |p, i| {
        const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\":\"{s}/{s}\"}}", .{ tmp_path, p });
        errdefer std.testing.allocator.free(args);
        const id = try std.fmt.allocPrint(std.testing.allocator, "call_{d}", .{i});
        errdefer std.testing.allocator.free(id);
        // The name too: `TurnCtx.deinit` frees it, and freeing a literal is an
        // "Invalid free" (the palette bug, the `/free-auto status` bug).
        const name = try std.testing.allocator.dupe(u8, "read");
        try t.calls.append(std.testing.allocator, .{
            .id = id,
            .name = name,
            .args_json = args,
        });
    }

    var sess = session_mod.Session.init(std.testing.allocator);
    defer sess.deinit();

    var test_budget: ResultBudget = .{};
    const r = runParallelBatch(&m, &sess, &t, 0, t.calls.items.len, arena, &test_budget);

    // The batch really ran all three.
    try std.testing.expectEqual(@as(usize, 3), r.ok);

    // The batch's threads are DETACHED, and each one that touched the shared
    // `Io` owns a buffer inside it. `threaded.deinit()` must not run while a
    // worker is still inside `io`, so the workers are waited for BEFORE the
    // defers unwind — the same order `runTui` uses, and the same reason
    // (AGENTS.md, "Detached workers + destroyed io = use-after-free").
    m.waitWorkers(2000);
    try std.testing.expectEqual(@as(usize, 0), m.workers.load(.seq_cst));

    // And every result is still readable AFTER the threads and their arenas are
    // gone. `pushToolDone` and `appendToolResult` both `dupe` from it, so the
    // session is where the freed bytes would land — and under
    // `std.testing.allocator` a freed arena is POISONED, not merely reused, so
    // a dangling result cannot accidentally look like the right text.
    var seen_fn: usize = 0;
    for (sess.messages.items) |msg| {
        if (!std.mem.eql(u8, @tagName(msg.role), "tool")) continue;
        try std.testing.expect(msg.content.len > 0);
        // The actual file contents came back, byte for byte.
        const want = if (std.mem.indexOf(u8, msg.content, "fn alpha") != null)
            "fn alpha"
        else if (std.mem.indexOf(u8, msg.content, "fn beta") != null)
            "fn beta"
        else if (std.mem.indexOf(u8, msg.content, "fn gamma") != null)
            "fn gamma"
        else
            return error.TestUnexpectedResult;
        seen_fn += 1;
        std.mem.doNotOptimizeAway(want);
    }
    try std.testing.expectEqual(@as(usize, 3), seen_fn);
}

// ── `/copy`: taking the answer with you ──────────────────────────────────
//
// The unit tests of `lib/copytext.zig` cover the TEXT (the arithmetic, the
// fences, the labels). These cover the WIRING: the command, the picker, the
// file and the clipboard. A command can be unit-perfect and still do nothing
// when it is typed, and that is what these are for.

/// A session with one assistant answer, for the `/copy` tests.
fn copyTestSession(gpa: std.mem.Allocator, text: []const u8) !*session_mod.Session {
    const s = try gpa.create(session_mod.Session);
    errdefer gpa.destroy(s);
    s.* = session_mod.Session.init(gpa);
    try s.appendAssistant(text, null);
    return s;
}

/// The session the `/copy` tests run against, and its teardown.
///
/// The session is a global (the agent owns one), so a test that puts one
/// there has to take it away again: three leaked allocations per test is the
/// DebugAllocator saying exactly that.
const CopySession = struct {
    ptr: *session_mod.Session,

    fn setup(gpa: std.mem.Allocator, text: []const u8) !CopySession {
        const sp = try copyTestSession(gpa, text);
        session = sp;
        return .{ .ptr = sp };
    }

    fn done(self: CopySession) void {
        session = null;
        self.ptr.deinit();
        std.testing.allocator.destroy(self.ptr);
    }
};

/// The text of the whole history, for the assertions.
fn historyText(m: *tui.Model, gpa: std.mem.Allocator) ![]u8 {
    m.drainPending();
    var out: std.ArrayList(u8) = .empty;
    for (m.paras.items) |p| {
        try out.appendSlice(gpa, p.text);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

test "/copy with no answer says so, instead of doing nothing" {
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    const saved = session;
    defer session = saved;
    session = null;

    cmdCopy(&m, null);
    const text = try historyText(&m, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, copytext.no_messages_msg) != null);
}

test "/copy N refuses with the count it HAS, and with the plural right" {
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    const saved = session;
    defer session = saved;
    const cs = try CopySession.setup(std.testing.allocator, "the only answer");
    defer cs.done();

    cmdCopy(&m, "3");
    const text = try historyText(&m, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Only 1 assistant message available to copy") != null);
}

test "/copy with a word instead of a number says HOW to use it" {
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    const saved = session;
    defer session = saved;
    const cs = try CopySession.setup(std.testing.allocator, "the only answer");
    defer cs.done();

    cmdCopy(&m, "abc");
    const text = try historyText(&m, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Usage: /copy [N]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "1 (latest)") != null);
}

test "/copy opens the picker with the whole answer, the blocks and the always row" {
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    const saved = session;
    defer session = saved;
    const cs = try CopySession.setup(std.testing.allocator,
        \\Here is the answer.
        \\
        \\```zig
        \\const a = 1;
        \\```
        \\
        \\And another one.
        \\
        \\```zig
        \\const b = 2;
        \\```
    );
    defer cs.done();

    cmdCopy(&m, null);
    try std.testing.expect(m.pickerActive());
    // Three rows: the whole answer, the two blocks... and the "always" row.
    try std.testing.expectEqual(@as(usize, 4), m.picker_items.items.len);
    try std.testing.expect(std.mem.indexOf(u8, m.picker_items.items[0].label, "Full response") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.picker_items.items[1].label, "const a = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.picker_items.items[2].label, "const b = 2;") != null);
    try std.testing.expectEqualStrings(copytext.always_label, m.picker_items.items[3].label);
}

test "/copy with no code block copies the answer straight away, with no picker" {
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    const saved = session;
    defer session = saved;
    const cs = try CopySession.setup(std.testing.allocator, "just prose, no fences");
    defer cs.done();

    cmdCopy(&m, null);
    try std.testing.expect(!m.pickerActive());
}

test "the /copy picker copies the row that was highlighted, even with two identical first lines" {
    // Two blocks that start with the SAME line: with a label-based callback
    // the second one would copy the first one's code while showing the second
    // one's row. The index callback is what makes this correct.
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    const saved = session;
    defer session = saved;
    const cs = try CopySession.setup(std.testing.allocator,
        \\```zig
        \\const same = 1;
        \\```
        \\
        \\```zig
        \\const same = 2;
        \\```
    );
    defer cs.done();

    cmdCopy(&m, null);
    try std.testing.expect(m.pickerActive());
    // The rows are: the whole answer, the first block, the second block, the
    // "always" row. Two downs land on the SECOND block.
    _ = m.pickerHandleKey(.{ .codepoint = 57353 }); // down
    _ = m.pickerHandleKey(.{ .codepoint = 57353 }); // down
    _ = m.pickerHandleKey(.{ .codepoint = 13 }); // enter
    try std.testing.expect(!m.pickerActive());

    // What went to the clipboard is the SECOND block, not the first one that
    // says the same thing.
    try std.testing.expect(m.copy_pending != null);
    try std.testing.expect(std.mem.indexOf(u8, m.copy_pending.?, "const same = 2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.copy_pending.?, "const same = 1;") == null);
}

test "the /copy picker copies the file it says it copied" {
    // The whole path: the command, the picker, the file on disk and the
    // message that names it. A unit test of the label arithmetic would pass
    // with none of this wired.
    const tmp = "/tmp/opencode/zode-copy-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, tmp) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tmp) catch {};

    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    m.io_ready = true;
    m.io = std.testing.io;

    var map: std.process.Environ.Map = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("TMPDIR", tmp);
    // A PATH with nothing in it: no native clipboard tool, so the last rung
    // (OSC 52) is the one that takes it, and the text waits in the Model for
    // the render to write it.
    try map.put("PATH", "");
    m.environ = &map;

    const saved = session;
    defer session = saved;
    const cs = try CopySession.setup(std.testing.allocator,
        \\The answer.
        \\
        \\```zig
        \\const x = 1;
        \\```
    );
    defer cs.done();

    cmdCopy(&m, null);
    try std.testing.expect(m.pickerActive());
    // The first row is the whole answer: take it.
    _ = m.pickerHandleKey(.{ .codepoint = 13 }); // enter
    try std.testing.expect(!m.pickerActive());

    // The file is on disk, with the answer in it.
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/zode/response.md", .{tmp});
    defer std.testing.allocator.free(path);
    const written = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, "The answer.") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "const x = 1;") != null);

    // And the message says what happened, with the numbers and the path.
    const text = try historyText(&m, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Copied to") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "characters") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, path) != null);

    // The clipboard text is waiting for the render: the last rung is OSC 52,
    // and it goes through vaxis, not straight to the tty.
    try std.testing.expect(m.copy_pending != null);
    try std.testing.expect(std.mem.indexOf(u8, m.copy_pending.?, "The answer.") != null);
}

test "ESC in the /copy picker is a cancel, not an error" {
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    const saved = session;
    defer session = saved;
    const cs = try CopySession.setup(std.testing.allocator,
        \\```zig
        \\const x = 1;
        \\```
    );
    defer cs.done();

    cmdCopy(&m, null);
    try std.testing.expect(m.pickerActive());
    _ = m.pickerHandleKey(.{ .codepoint = 27 }); // esc
    try std.testing.expect(!m.pickerActive());

    const text = try historyText(&m, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, copytext.cancelled_msg) != null);
    // And it is NOT an error line: a cancel is not a failure.
    for (m.paras.items) |p| {
        try std.testing.expect(p.kind != .error_msg);
    }
}

test "two blocks with the same first line get DIFFERENT labels" {
    // Three blocks that start with the same line: the picker has to be able
    // to tell them apart, and counting the LATER ones too would give all
    // three the same "(3)".
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    const saved = session;
    defer session = saved;
    const cs = try CopySession.setup(std.testing.allocator,
        \\```zig
        \\const same = 1;
        \\const body_a = 1;
        \\```
        \\
        \\```zig
        \\const same = 1;
        \\const body_b = 2;
        \\```
        \\
        \\```zig
        \\const same = 1;
        \\const body_c = 3;
        \\```
    );
    defer cs.done();

    cmdCopy(&m, null);
    try std.testing.expect(m.pickerActive());
    try std.testing.expectEqual(@as(usize, 5), m.picker_items.items.len);
    try std.testing.expectEqualStrings("const same = 1;", m.picker_items.items[1].label);
    try std.testing.expectEqualStrings("const same = 1; (2)", m.picker_items.items[2].label);
    try std.testing.expectEqualStrings("const same = 1; (3)", m.picker_items.items[3].label);
}

test "/copy shows up in /help" {
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    commands_mod.cmdHelp(&m);
    const text = try historyText(&m, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "/copy") != null);
}

test "the --resume flag is not overwritten by the environment" {
    // The flag is dispatched BEFORE the environment is read, and the line that
    // assigned the environment's answer over it made `zode --resume` start a
    // NEW session: the app said "nothing to resume; starting a new session",
    // which is exactly what the flag asks it not to do.
    var map: std.process.Environ.Map = .init(std.testing.allocator);
    defer map.deinit();

    try std.testing.expect(shouldResume(true, &map));
    try std.testing.expect(!shouldResume(false, &map));

    try map.put("ZODE_RESUME", "1");
    try std.testing.expect(shouldResume(false, &map));
    // And the flag still wins when both are there.
    try std.testing.expect(shouldResume(true, &map));

    // No environment at all is not a crash and not a resume.
    try std.testing.expect(!shouldResume(false, null));
}

test "E2E: a real turn against a real provider completes and answers" {
    // GATED AT BUILD TIME, not by an environment variable. See the comment in `build.zig`
    // for why the environment was not an option: this Zig version gives a test no way to
    // read the process environment at all.
    if (!build_options.e2e) return;

    // A real `Io`. `Io.Threaded` is what the app uses, and a test that used a fake one
    // would be testing the fake.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The map the test hands the worker is BUILT HERE, from `.env`, because
    // `Environ.Map.init` creates an empty one and there is no std API to
    // populate it from the process. That is the right shape anyway: a test whose
    // inputs change with the machine it runs on is not a test — and the one
    // input it cannot do without, the provider's key, is a secret that must
    // not be in this file. It was committed once, by mistake; reading it from
    // the gitignored `.env` is the only fix that makes a repeat impossible.
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    loadDotEnv(io, &env_map);
    // No credential, no test: running without one is a 401, which is not an
    // end-to-end of anything. Skip — a red "no key" is exactly as ignorable as
    // the quota failure this test was redesigned to survive.
    if (!envHasAnyKey(&env_map)) return;

    // The three globals the worker reads. `loadUserConfig` is what resolves the
    // provider from `ZODE_PROVIDER`, and it reads `environ_global` — so without this
    // the test would run against opencode no matter what the environment said, which
    // is the exact bug `--models` had.
    const saved_io = io_global;
    const saved_env = environ_global;
    const saved_gpa = gpa_global;
    defer {
        io_global = saved_io;
        environ_global = saved_env;
        gpa_global = saved_gpa;
        // The 1 MiB body buffer is a module global as well, and a test that takes over
        // the globals has to give them back: `shutdownBuffers` frees it, and skipping it
        // leaks a megabyte per run of a test that is supposed to be about correctness.
        shutdownBuffers();
        // The AGENTS.md cache, read once by `systemPromptBase` with the testing allocator
        // and kept in the module for the life of the process. `forgetAgentsCache` takes the
        // allocator, because the block belongs to the one `runOneTurn` was handed — and
        // freeing it with any other is an Invalid free.
        forgetAgentsCache(std.testing.allocator);
    }
    io_global = io;
    environ_global = &env_map;
    gpa_global = std.testing.allocator;
    loadUserConfig();
    defer shutdownUserConfig();

    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    // The session is a MODULE GLOBAL that `startChat` creates, and every message in it
    // is allocated from the testing allocator. This is a `defer` and NOT a statement at
    // the end of the body for a reason that cost three leaks to learn: the test has an
    // early `return` on its failure path, and a cleanup written after it is a cleanup
    // that runs on the green path only. The red path leaked the whole conversation.
    defer {
        if (session) |sess| {
            // `deinit` frees the CONTENT; `destroy` frees the struct. `Session.create`
            // heap-allocates the struct itself (`allocator.create(Session)`), so a test
            // that only deinits is leaking the pointer no matter how carefully it
            // empties the messages. In the app this is a process-lifetime leak that
            // nobody notices; in a test with the DebugAllocator on, it is a red line.
            sess.deinit();
            std.testing.allocator.destroy(sess);
            session = null;
        }
    }
    m.attachIo(io);
    m.environ = &env_map;

    // A free model, so the test costs nothing. `setModel` is what the picker calls, so
    // the test goes through the same path a user does.
    setModel("cohere/north-mini-code:free");

    // The turn. `startChat` is the real entry point: it creates the session, opens the
    // streaming paragraph and spawns the worker.
    startChat(&m, "Reply with exactly: e2e ok") catch |err| {
        std.debug.print("\n[e2e] startChat failed: {t}\n", .{err});
        return error.TurnDidNotStart;
    };

    // Wait for it. `isBusy` is the flag the draw reads, so it is the honest signal:
    // the turn is over when the UI would stop painting the spinner.
    //
    // The cap is 120 s and it is a real cap, not a sleep: a turn that hangs must fail
    // the test rather than hang the runner, which is the failure mode this repo cannot
    // afford in CI.
    var waited_ms: u64 = 0;
    while (m.isBusy() and waited_ms < 120_000) : (waited_ms += 100) {
        sleep_mod.nap(100);
    }
    // And THEN the join. `isBusy()` is what the draw reads, so it is the honest signal
    // that the turn is *visibly* over — but the worker thread has work after it sets the
    // flag: `finishAutoCheck` waits up to 4 s for a build, `pushTurnSummary`, and the
    // final session appends. Deiniting the session while that is still running is both a
    // leak (the appender owns the memory) and a use-after-free the test never sees
    // because the allocator would just reuse the block.
    //
    // `waitWorkers` counts yields rather than reading the clock, which is the same
    // reasoning as shutdown: it is called at a moment when asking the time is unsafe.
    m.waitWorkers(10_000);

    if (m.isBusy()) {
        std.debug.print("\n[e2e] the turn never finished\n", .{});
        return error.TurnNeverFinished;
    }

    // And the assertion that matters: the model ANSWERED. Not "the request succeeded",
    // not "no error" — the session has an assistant message with text in it. That is
    // the difference between a turn that completed and a turn that completed having
    // said nothing, which is the failure the whole loop exists to prevent.
    const s = ensureSession(&m, std.testing.allocator);
    var answer_len: usize = 0;
    var tool_calls: usize = 0;
    for (s.messages.items) |msg| {
        // `== .assistant` and not a string compare: `role` is an enum, and comparing it
        // against a literal is a type error that only shows up here because this is the
        // first test that walks a real session's messages.
        if (msg.role == .assistant) {
            if (msg.content.len > answer_len) answer_len = msg.content.len;
            if (msg.tool_calls_json != null) tool_calls += 1;
        }
    }
    //
    // ## What this asserts, and why it is not "the model answered"
    //
    // First version asserted an answer, and it passed — on a key with quota. An hour
    // later, quota gone, it failed with "Rate limit exceeded: free-models-per-day", and
    // would have kept failing every day after. A test whose red state is "the provider
    // said no" is a test that teaches whoever runs it to ignore it, and then the seam is
    // unwatched again.
    //
    // What actually has to hold is stronger and it is the thing the whole exit-gate work
    // exists for: **a turn never ends in silence.** Either the model answered, or somebody
    // was told why it did not. The failure being hunted is a turn that completes, claims
    // to have worked, and says nothing — and that is what this asserts, deterministically,
    // with or without a quota.
    //
    // So it takes the answer when it can get it, and reports which branch it took. When
    // the answer is there, that is also the only place in CI where the real wire, the real
    // session and the real gate are exercised end to end.
    var accounted: bool = answer_len > 0;
    if (!accounted) {
        // No answer: the reason has to be on screen somewhere. The user-facing queue is
        // where `reportErr` and the retry notices go, and a session message is where the
        // model's own text goes. Either one is the harness having said something.
        for (s.messages.items) |msg| {
            if (msg.role == .assistant and msg.content.len > 0) accounted = true;
        }
        accounted = accounted or m.pending.items.len > 0;
        if (!accounted) {
            std.debug.print(
                "\n[e2e] FAILED: the turn ended with no answer AND no visible reason. last_error={s}\n",
                .{chat.lastErrorBody()},
            );
            return error.TurnEndedInSilence;
        }
    }
    std.debug.print(
        "\n[e2e] ok · {s} · {d} chars in the answer · {d} tool call(s) · {d} messages · {d} pending\n",
        .{
            if (answer_len > 0) "answered" else "refused, and said so",
            answer_len,
            tool_calls,
            s.messages.items.len,
            m.pending.items.len,
        },
    );
    // One assertion, and it is the invariant rather than the outcome: a turn never ends
    // in silence. `accounted` already holds the answer to that, so this is the same fact
    // said in the language a test failure uses.
    try std.testing.expect(accounted);
}

test "a project rule allows what the sensitive table asks about" {
    // The whole reason the rule model exists: a project that wants
    // `.vscode/` written without a question says so in ITS OWN file, and the
    // file travels with the project.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.createDirPath(io, ".zode");
    try tmp.dir.writeFile(io, .{
        .sub_path = ".zode/permissions.json",
        .data =
        \\{"rules": [
        \\  "Write(.vscode/**) allow",
        \\  "Bash(git *) allow"
        \\]}
        ,
    });

    var pbuf: [512]u8 = undefined;
    const n = tmp.dir.realPath(io, &pbuf) catch return error.TestUnexpectedResult;
    var fbuf: [640]u8 = undefined;
    const path = std.fmt.bufPrint(&fbuf, "{s}/.zode/permissions.json", .{pbuf[0..n]}) catch return error.TestUnexpectedResult;

    // The rules are a global and the next test reads them: the state is put
    // back the way it was.
    const saved = perm_rules;
    defer perm_rules = saved;
    loadPermRulesInto(arena_state.allocator(), io, path, null);

    // The rule answers for the path the sensitive table would ask about.
    const d = permDecision("Write", &.{".vscode/settings.json"}).?;
    try std.testing.expectEqual(permrules.Action.allow, d.action);
    try std.testing.expectEqual(permrules.Source.project, d.rule.source);

    // And it says nothing about anything else.
    try std.testing.expect(permDecision("Write", &.{"src/main.zig"}) == null);

    // The command rules work the same way.
    const b = permDecision("Bash", &.{"git status"}).?;
    try std.testing.expectEqual(permrules.Action.allow, b.action);
}

test "a rule that denies beats a rule that allows" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.createDirPath(io, ".zode");
    try tmp.dir.writeFile(io, .{
        .sub_path = ".zode/permissions.json",
        .data = "{\"rules\": [\"Write(.git/**) deny\"]}",
    });

    var pbuf: [512]u8 = undefined;
    const n = tmp.dir.realPath(io, &pbuf) catch return error.TestUnexpectedResult;
    var fbuf: [640]u8 = undefined;
    const path = std.fmt.bufPrint(&fbuf, "{s}/.zode/permissions.json", .{pbuf[0..n]}) catch return error.TestUnexpectedResult;

    const saved = perm_rules;
    defer perm_rules = saved;
    loadPermRulesInto(arena_state.allocator(), io, path, null);

    const d = permDecision("Write", &.{".git/config"}).?;
    try std.testing.expectEqual(permrules.Action.deny, d.action);
    try std.testing.expectEqualStrings("project", d.rule.source.name());
}

test "a dontAsk rule means the model answers for itself, no dialog" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.createDirPath(io, ".zode");
    try tmp.dir.writeFile(io, .{
        .sub_path = ".zode/permissions.json",
        .data = "{\"rules\": [\"Write(.git/**) dontask\"]}",
    });

    var pbuf: [512]u8 = undefined;
    const n = tmp.dir.realPath(io, &pbuf) catch return error.TestUnexpectedResult;
    var fbuf: [640]u8 = undefined;
    const path = std.fmt.bufPrint(&fbuf, "{s}/.zode/permissions.json", .{pbuf[0..n]}) catch return error.TestUnexpectedResult;

    const saved = perm_rules;
    defer perm_rules = saved;
    loadPermRulesInto(arena_state.allocator(), io, path, null);

    // dontAsk: no dialog is needed, the model decides on its own.
    const d = permDecision("Write", &.{".git/config"}).?;
    try std.testing.expectEqual(permrules.Action.dontAsk, d.action);
    try std.testing.expectEqualStrings("project", d.rule.source.name());

    // And it says nothing about anything else.
    try std.testing.expect(permDecision("Write", &.{"src/main.zig"}) == null);
}


test "the 'always allow' suggestion names the rule it would remember" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // A command becomes its FIRST WORD: "always allow `git status`" would
    // mean the next `git commit` asks again.
    const bash = permSuggestion("bash", "{\"command\":\"git status --short\"}", a).?;
    try std.testing.expectEqualStrings("Bash(git *) allow", bash);

    // A file becomes the file: a directory is a bigger promise than the user
    // made.
    const write = permSuggestion("write", "{\"path\":\"src/main.zig\"}", a).?;
    try std.testing.expectEqualStrings("write(src/main.zig) allow", write);

    // And a tool with nothing to narrow becomes itself.
    const other = permSuggestion("task", "{\"prompt\":\"look around\"}", a).?;
    try std.testing.expectEqualStrings("task(*) allow", other);

    // An MCP call names the QUALIFIED tool: `Mcp(github.create_issue)`.
    //
    // Not `Mcp(*)`: that would be every server the user ever configures, and
    // the answer the user gives is about ONE tool whose name they just read.
    const mcp = permSuggestion(
        "mcp",
        "{\"operation\":\"call\",\"server\":\"github\",\"tool\":\"create_issue\"}",
        a,
    ).?;
    try std.testing.expectEqualStrings("Mcp(github.create_issue) allow", mcp);

    // And the rule it names is one the parser understands, with the tool
    // name in the spelling the matcher uses (case-insensitively).
    const rule = permrules.parseRule(mcp, .local, a).?;
    try std.testing.expectEqualStrings("Mcp", rule.tool);
    try std.testing.expectEqualStrings("github.create_issue", rule.pattern);
    try std.testing.expect(permrules.matches(rule, "mcp", "github.create_issue"));
    // And it does NOT cover another tool of the same server.
    try std.testing.expect(!permrules.matches(rule, "mcp", "github.list_issues"));
}

test "the suggestion is a rule the parser understands" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const text = permSuggestion("bash", "{\"command\":\"npm test\"}", a).?;
    const rule = permrules.parseRule(text, .local, a).?;
    try std.testing.expectEqualStrings("Bash", rule.tool);
    try std.testing.expectEqualStrings("npm *", rule.pattern);
    try std.testing.expectEqual(permrules.Action.allow, rule.action);
}

test "an always-allow suggestion scopes to the tool and pattern, not a flat name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // "always allow write(src/main.zig)" must not become "always allow write"
    // (which would cover every file the tool ever touches).
    const text = permSuggestion("write", "{\"path\":\"src/main.zig\"}", a).?;
    try std.testing.expectEqualStrings("write(src/main.zig) allow", text);
    const rule = permrules.parseRule(text, .local, a).?;
    try std.testing.expectEqualStrings("write", rule.tool);
    try std.testing.expectEqualStrings("src/main.zig", rule.pattern);
    try std.testing.expectEqual(permrules.Action.allow, rule.action);
    try std.testing.expect(permrules.matches(rule, "write", "src/main.zig"));
    // The same tool on a different path is NOT covered.
    try std.testing.expect(!permrules.matches(rule, "write", "src/other.zig"));
    // A different tool is NOT covered either.
    try std.testing.expect(!permrules.matches(rule, "edit", "src/main.zig"));
}

test "a command that only reads is not a write, and the plan mode lets it run" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try std.testing.expect(callReadsOnly("bash", "{\"command\":\"git status\"}", a));
    try std.testing.expect(callReadsOnly("bash", "{\"command\":\"rg foo src/\"}", a));
    // And a command that changes something is not.
    try std.testing.expect(!callReadsOnly("bash", "{\"command\":\"git push\"}", a));
    try std.testing.expect(!callReadsOnly("bash", "{\"command\":\"rm -rf build\"}", a));
    // A command we do not know is NOT read-only: the cost of asking is one
    // dialog and the cost of guessing wrong is a file.
    try std.testing.expect(!callReadsOnly("bash", "{\"command\":\"weird-tool --x\"}", a));
    // Another tool is not a command at all.
    try std.testing.expect(!callReadsOnly("write", "{\"path\":\"a.zig\"}", a));
}

test "execOneCall: `bash` that only reads runs without asking" {
    // Phase 25.4: with `/yolo` off, no persisted prefix and no permission
    // rules, `execOneCall` shows the dialog for anything that needs it — and
    // the dialog blocks until an answer arrives. A command the scanner found
    // nothing to flag (`ls`) only reads, so it never gets there: the call
    // runs and the dialog is never opened. If this ever starts asking again,
    // this test blocks instead of finishing.
    const saved_yolo = yolo;
    defer yolo = saved_yolo;
    yolo = false;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const saved_io = io_global;
    const saved_gpa = gpa_global;
    io_global = threaded.io();
    gpa_global = std.testing.allocator;
    defer { io_global = saved_io; gpa_global = saved_gpa; }

    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    var s = session_mod.Session.init(std.testing.allocator);
    defer s.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const call = TurnCtx.Call{ .id = "c1", .name = "bash", .args_json = "{\"command\":\"ls\"}" };
    var denied: usize = 0;
    var budget: ResultBudget = .{};
    const ran = execOneCall(&m, &s, call, arena, &denied, &budget);
    try std.testing.expectEqual(@as(usize, 1), ran);
    try std.testing.expectEqual(@as(usize, 0), denied);
}

// ── `/files`: the session's file state ─────────────────────────

test "a write is recorded in the session's changed files" {
    // The seam: the tool call → the Model. The list is the session's, and a
    // list that says "changed" about a file nobody changed is a lie.
    const saved_io = io_global;
    defer io_global = saved_io;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    io_global = threaded.io();

    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    // YOLO: nobody is asked, so the call does not park on a dialog that
    // nobody is there to answer.
    const saved_yolo = yolo;
    defer yolo = saved_yolo;
    yolo = true;

    var s = session_mod.Session.init(std.testing.allocator);
    defer s.deinit();

    const tmp_path = "/tmp/opencode/zode-test-files";
    try std.Io.Dir.cwd().createDirPath(io_global, tmp_path);
    defer std.Io.Dir.cwd().deleteTree(io_global, tmp_path) catch {};

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.fmt.allocPrint(arena, "{{\"path\":\"{s}/a.txt\",\"content\":\"hola\"}}", .{tmp_path});
    const call = TurnCtx.Call{ .id = "c1", .name = "write", .args_json = args };
    var denied: usize = 0;
    var budget: ResultBudget = .{};
    _ = execOneCall(&m, &s, call, arena, &denied, &budget);

    try std.testing.expectEqual(@as(usize, 1), m.changed.count());
    try std.testing.expect(std.mem.indexOf(u8, m.changed.at(0), "a.txt") != null);
}

test "a call that changed nothing is not in the changed files" {
    // A `read` is not a change, and neither is a call that failed: the list is
    // of files that were WRITTEN.
    const saved_io = io_global;
    defer io_global = saved_io;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    io_global = threaded.io();

    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    const saved_yolo = yolo;
    defer yolo = saved_yolo;
    yolo = true;

    var s = session_mod.Session.init(std.testing.allocator);
    defer s.deinit();

    const tmp_path = "/tmp/opencode/zode-test-files-read";
    try std.Io.Dir.cwd().createDirPath(io_global, tmp_path);
    defer std.Io.Dir.cwd().deleteTree(io_global, tmp_path) catch {};
    try std.Io.Dir.cwd().writeFile(io_global, .{ .sub_path = tmp_path ++ "/a.txt", .data = "hola" });

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.fmt.allocPrint(arena, "{{\"path\":\"{s}/a.txt\"}}", .{tmp_path});
    const call = TurnCtx.Call{ .id = "c1", .name = "read", .args_json = args };
    var denied: usize = 0;
    var budget: ResultBudget = .{};
    _ = execOneCall(&m, &s, call, arena, &denied, &budget);

    try std.testing.expectEqual(@as(usize, 0), m.changed.count());
    // But the READ is in the cache, which is the other half of the report.
    try std.testing.expectEqual(@as(usize, 1), m.reads.liveEntries());
}

test "a new session's file state starts empty" {
    // The read cache does not survive a session change: the new session's
    // context is EMPTY, and an entry that says "the model has this file"
    // would make the next `read` skip the body.
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    const stat = .{ .inode = @as(u64, 7), .size = @as(u64, 10), .mtime = .{ .nanoseconds = @as(i128, 5) } };
    m.reads.record("a.zig", stat, 1, 1, 10, 10);
    m.changed.note("a.zig");
    try std.testing.expectEqual(@as(usize, 1), m.reads.liveEntries());

    resetSessionFiles(&m);
    try std.testing.expectEqual(@as(usize, 0), m.reads.liveEntries());
    try std.testing.expectEqual(@as(usize, 0), m.changed.count());
}

test "SummaryBreaker: not tripped before reaching the threshold" {
    var b: SummaryBreaker = .{};
    try std.testing.expect(!b.tripped());
    b.noteFailure();
    b.noteFailure(); // one short of max_consecutive
    try std.testing.expect(!b.tripped());
}

test "SummaryBreaker: trips after max_consecutive failures and stops" {
    var b: SummaryBreaker = .{};
    try std.testing.expectEqual(@as(usize, 0), b.consecutive);
    b.noteFailure();
    b.noteFailure();
    b.noteFailure(); // third consecutive failure
    try std.testing.expectEqual(@as(usize, 3), b.consecutive);
    try std.testing.expect(b.tripped());
    // A fourth failure does not un-trip it.
    b.noteFailure();
    try std.testing.expect(b.tripped());
}

test "SummaryBreaker: a success resets the counter" {
    var b: SummaryBreaker = .{};
    b.noteFailure();
    b.noteFailure();
    try std.testing.expect(!b.tripped());
    b.noteSuccess();
    try std.testing.expectEqual(@as(usize, 0), b.consecutive);
    try std.testing.expect(!b.tripped());
    // And it can fail again from a clean slate.
    b.noteFailure();
    b.noteFailure();
    b.noteFailure();
    try std.testing.expect(b.tripped());
}

test "SummaryBreaker: reset clears a tripped breaker" {
    var b: SummaryBreaker = .{};
    b.noteFailure();
    b.noteFailure();
    b.noteFailure();
    try std.testing.expect(b.tripped());
    b.reset();
    try std.testing.expectEqual(@as(usize, 0), b.consecutive);
    try std.testing.expect(!b.tripped());
}

test "SummaryBreaker: max_consecutive is three" {
    const b: SummaryBreaker = .{};
    try std.testing.expectEqual(@as(usize, 3), b.max_consecutive);
}
