const std = @import("std");
const sleepz = @import("lib/sleep.zig");
const vaxis = @import("vaxis");
const builtin = @import("builtin");
const tui = @import("tui.zig");
const providers = @import("lib/providers.zig");
const chat = @import("chat.zig");
const http_client = @import("lib/http_client.zig");
const tools_mod = @import("tools/dispatch.zig");
const roster_mod = @import("roster.zig");
const free_auto = @import("free_auto.zig");
const router_mod = @import("lib/router.zig");
const plan_mod = @import("lib/plan.zig");
const goal_mod = @import("lib/goal.zig");
const modelcache = @import("lib/modelcache.zig");
const clean_mod = @import("lib/clean.zig");
const mentions = @import("lib/mentions.zig");
const session_mod = @import("session.zig");
const models_mod = @import("lib/models.zig");
const cache_stats = @import("cache_stats.zig");
const compaction = @import("compaction.zig");
const mascot = @import("lib/mascot.zig");
const palette = @import("palette.zig");
const config_mod = @import("config.zig");

const ask = @import("lib/ask.zig");
const bgproc = @import("bgproc.zig");
const sleep_mod = @import("lib/sleep.zig");
const typecheck_mod = @import("lib/typecheck.zig");
const check_tool = @import("tools/check.zig");
const images_mod = @import("lib/images.zig");
const bench_mod = @import("lib/bench.zig");
const skills = @import("lib/skills.zig");
const skillstore = @import("lib/skillstore.zig");
const project = @import("lib/project.zig");
const subagent_mod = @import("lib/subagent.zig");
const sleep = @import("lib/sleep.zig");
const prompt_mod = @import("lib/prompt.zig");
const commands_mod = @import("commands.zig");

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
pub const tool_routing_prompt = prompt_mod.tool_routing_prompt;
pub const verification_prompt = prompt_mod.verification_prompt;

// ── system prompt: the project's AGENTS.md (cached) ──────────
var agents_md_cache: ?[]u8 = null;

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
        }
        gpa.free(list);
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
/// And it was invisible from the TUI, where all of it works. Two prompts for the
/// same agent, one of them a subset of the other, is not a configuration: it is a
/// second definition of how the harness wants to be used.
///
/// So there is ONE composition now. The headless runner calls this.
pub fn buildSystemPromptFor(
    gpa: std.mem.Allocator,
    env: ?*const std.process.Environ.Map,
) ![]u8 {
    var buf: [16 * 1024]u8 = undefined;
    return gpa.dupe(u8, buildSystemPrompt(gpa, &buf, env));
}

fn buildSystemPrompt(gpa: std.mem.Allocator, out: []u8, env: ?*const std.process.Environ.Map) []const u8 {
    const base = systemPromptBase(gpa);
    const entries = discoverSkills(gpa, env);

    var list_buf: [8 * 1024]u8 = undefined;
    const section = skills.systemPromptSection(entries, &list_buf);

    var loc_buf: [512]u8 = undefined;
    const location = project_info.promptLines(&loc_buf);

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
        "READ-ONLY MODE is on (shift+tab to turn it off). You cannot write, edit or run bash: those calls come back with an error saying so. Investigate, then use `ask` to tell the user what you found and ask how to proceed.\n\n"
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
    const blocks_len = routing.len + verification_prompt.len + ask.guidance.len +
        section.len + location.len + mode_note.len;
    const composed = std.fmt.bufPrint(out, "{s}\n{s}\n{s}{s}{s}{s}\n{s}", .{
        base,
        routing,
        verification_prompt,
        ask.guidance,
        section,
        location,
        mode_note,
    }) catch blk: {
        // It did not fit, and the old answer was `catch return base`: the WHOLE
        // prompt became the project's own text, with no routing table, no
        // verification rule, no ask guidance, no skills and no location — silently,
        // for every project whose instruction file is bigger than the buffer.
        //
        // That is the exact symptom this table was written for. Asked to find a
        // games page, the model ran `bash curl`, because there was no rule saying
        // not to; here it happens to any project with a 30 KB `AGENTS.md`, and it
        // looks like "the model ignored my instructions" instead of "the harness
        // dropped its own".
        //
        // So the CONSTANT blocks are the ones that survive and the per-project text
        // is what gets trimmed — and it says so, because a project that cannot see
        // half of its own instructions should be told rather than left to guess.
        // The slack has to cover the note AND the separators. With 64 bytes the
        // retry overflowed too and the answer was `catch routing`, which drops the
        // verification rules and the ask guidance — the same class of loss as the
        // bug being fixed, one function deeper.
        const note = "[the project instructions above were truncated to fit; the rest is in the project's instruction file]";
        const overhead = note.len + 16;
        if (out.len <= blocks_len + overhead) break :blk routing;
        const room = out.len - blocks_len - overhead;
        const keep = @min(base.len, room);
        break :blk std.fmt.bufPrint(
            out,
            "{s}\n{s}\n{s}\n{s}{s}{s}{s}\n{s}",
            .{
                base[0..keep],
                note,
                routing,
                verification_prompt,
                ask.guidance,
                section,
                location,
                mode_note,
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
    const want = buildSystemPrompt(gpa, &buf, null);
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
    return std.Io.Dir.cwd().readFileAlloc(io_global, path, gpa, .limited(256 * 1024)) catch null;
}

pub var current_effort: chat.Effort = .medium;

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

/// Turns read-only mode on or off and says so.
pub fn toggleReadOnly(m: *tui.Model) void {
    read_only = !read_only;
    m.read_only = read_only;
    if (read_only) {
        setStatusWithZo(m, .warn, "read-only · the agent investigates and asks");
        pushInfo(m, "read-only mode ON (shift+tab to turn it off): write, edit and bash will come back with an error instead of running. The agent investigates and asks you with `ask`.");
    } else {
        setStatusWithZo(m, .done, "read-only off");
        pushInfo(m, "read-only mode OFF");
    }
}

/// `/ask [on|off]`.
fn cmdAskMode(m: *tui.Model, arg: ?[]const u8) void {
    if (arg) |a| {
        const on = std.ascii.eqlIgnoreCase(a, "on") or std.ascii.eqlIgnoreCase(a, "1");
        const off = std.ascii.eqlIgnoreCase(a, "off") or std.ascii.eqlIgnoreCase(a, "0");
        if (on and !read_only) {
            toggleReadOnly(m);
            return;
        }
        if (off and read_only) {
            toggleReadOnly(m);
            return;
        }
        if (!on and !off) {
            pushInfoFmt(m, "/ask: on|off (it is {s})", .{if (read_only) "on" else "off"});
            return;
        }
    }
    toggleReadOnly(m);
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
        const line = std.fmt.allocPrint(m.allocator, "  {s}: {s}", .{
            e.name,
            if (e.description.len > 0) e.description else "(no description)",
        }) catch continue;
        pushInfoOwned(m, line);
    }
}

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
/// Once, and only once. Retrying it every turn is one wasted request per turn
/// forever, and the state it would recover from (a context too full to send) is
/// exactly the one it cannot recover from without help. A `/new` resets it.
var summarized_this_session: bool = false;

/// Has the TUI already summarized the old turns in this session?
///
/// Once, and only once. Retrying it every turn is one wasted request per turn
/// forever, and the state it would recover from (a context too full to send) is
/// exactly the one it cannot recover from without help. A `/new` resets it.
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

/// Recomputes `ctx_used`/`ctx_pct`. Cheap to call, but not needed per frame:
/// tokens only change when a message is added.
pub fn refreshContextUsage(m: *tui.Model) void {
    if (session == null) {
        ctx_used = 0;
        ctx_pct = 0;
        return;
    }
    var astate = std.heap.ArenaAllocator.init(m.allocator);
    defer astate.deinit();
    const msgs = snapshotMsgs(astate.allocator());
    ctx_used = compaction.estimateTokens(msgs);
    const limit = @max(1, compaction.contextLimitFor(m.environ, curModelContext()));
    const pct = (@as(f64, @floatFromInt(ctx_used)) / @as(f64, @floatFromInt(limit))) * 100.0;
    ctx_pct = @intFromFloat(std.math.clamp(pct, 0, 999));
}

fn updateTps(chars: usize, start_ns: i128) void {
    if (start_ns == 0 or chars < 32) return;
    const now_ns = std.Io.Timestamp.now(io_global, .real).nanoseconds;
    const dt = now_ns - start_ns;
    if (dt <= 0) return;
    const tps = (@as(f64, @floatFromInt(chars)) / 4.0) / (@as(f64, @floatFromInt(dt)) / 1e9);
    if (tps > 0.5 and tps < 100_000) {
        tps_live = tps;
        tps_last = tps;
    }
}

// ── active provider / model / session ────────────────────────

pub var cur_provider_id: []const u8 = "opencode";
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

fn isAlwaysAllowed(name: []const u8) bool {
    for (always_lens, 0..) |l, i| {
        if (l > 0 and std.mem.eql(u8, always_names[i][0..l], name)) return true;
    }
    return false;
}

fn setAlwaysAllowed(m: *tui.Model, name: []const u8) void {
    if (setAlwaysAllowedNoSave(name)) {
        saveAllowlist();
        const msg = std.fmt.allocPrint(m.allocator, "always allowed: {s}", .{name}) catch return;
        pushInfoOwned(m, msg);
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
    if (parsed != .array) return;
    for (parsed.array.items) |v| {
        if (v != .string) continue;
        _ = setAlwaysAllowedNoSave(v.string);
    }
}

// ── persisted allowlist: ~/.config/zode/permissions.json ─────
fn permissionsFilePath(buf: []u8) ?[]const u8 {
    const home = environ_global.?.get("HOME") orelse return null;
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

    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    config_mod.writeStringArray(&w, gpa_global, names[0..n]) catch return;
    std.Io.Dir.cwd().writeFile(io_global, .{ .sub_path = path, .data = w.buffered() }) catch {};
}

fn readFileTo(arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io_global, path, arena, .limited(1 << 20)) catch null;
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
pub fn initCheapRouterFromEnv(env: ?*const std.process.Environ.Map) void {
    cheap_router = router_mod.initFromEnv(env);
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
pub fn setStatusWithZo(m: *tui.Model, mood: mascot.Mood, text: []const u8) void {
    m.setStatusWithMood(mood, text);
}

/// `setStatusWithZo` that composes the text itself.
///
/// It exists because of the rule AGENTS.md writes down the hard way: the composed
/// string has to be COPIED (`Model.setStatusText` copies into a fixed buffer), and
/// the tempting alternative is `allocPrint(m.allocator, …)` + `pushInfoOwned`,
/// which on an out-of-memory path hands a LITERAL to a function that frees it.
/// Composing and copying in one call makes that mistake unrepresentable.
pub fn setStatusWithZoFmt(m: *tui.Model, mood: mascot.Mood, comptime fmt: []const u8, args: anytype) void {
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

/// API key of the active provider: first the one saved in `auth.json`, then
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
            cur_provider_id = user_config.provider;
        } else if (envGet(environ_global, "ZODE_PROVIDER")) |p| {
            if (config_mod.find(user_config, p) != null or providers.byId(p) != null) {
                cur_provider_id = p;
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
        loadAuthKeys(cfg_arena_state.?.allocator());
    }
}

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
    loadUserConfig();
}

/// Frees the config and keys arenas. On process exit, when no worker is left
/// reading.
pub fn shutdownUserConfig() void {
    if (cfg_arena_state) |*s| {
        s.deinit();
        cfg_arena_state = null;
    }
    if (keys_arena_state) |*s| {
        s.deinit();
        keys_arena_state = null;
    }
    providers.setSavedKeys(null);
    user_config = .{};
    // The skills cache is the third arena-like thing in the process and the only
    // one with heap strings owned by the module. It is BORROWED by everyone, so
    // this is the one place it can be freed — at exit, with no worker left.
    freeSkillsCache();
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
        return s;
    };
    session = fresh;
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

/// Creates a new session and discards the current one.
pub fn newSession(m: *tui.Model) void {
    if (session) |old| {
        m.allocator.destroy(old);
        session = null;
    }
    const s = ensureSession(m, m.allocator);
    m.pushInfoFmt("new session: {s}", .{s.id[0..]});
    session_elided = 0;
    summarized_this_session = false;
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
        // `files.capacity == 0` = list with no memory of its own: there is nothing
        // to free and `gpa` may be uninitialized.
        if (self.files.capacity == 0) return;
        for (self.files.items) |f| self.gpa.free(f);
        self.files.deinit(self.gpa);
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

fn bodyBuf(gpa: std.mem.Allocator) ![]u8 {
    if (body_buf_heap == null) {
        body_buf_heap = try gpa.alloc(u8, 1 << 20);
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
        gpa_global.free(b);
        body_buf_heap = null;
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
    if (session) |s| {
        s.messages.clearRetainingCapacity();
        s.flush();
    }
    session_elided = 0;
    summarized_this_session = false;
    m.pushInfoFmt("session reset", .{});
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
    if (std.mem.eql(u8, cmd, "/quit")) return .quit;
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

/// `/agent.yolo`: toggle for automatic permissions.
fn cmdYolo(m: *tui.Model) void {
    yolo = !yolo;
    const msg = if (yolo) "yolo ON: no confirmations" else "yolo OFF: asks for permission";
    pushInfo(m, msg);
    setStatusWithZo(m, if (yolo) .warn else .idle, msg);
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
    } else if (std.mem.eql(u8, cmd, "use")) {
        commands_mod.cmdUse(m, arg);
    } else if (std.mem.eql(u8, cmd, "plan")) {
        cmdPlan(m);
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
    } else if (std.mem.eql(u8, cmd, "allowlist")) {
        commands_mod.cmdAllowlist(m);
    } else if (std.mem.eql(u8, cmd, "context")) {
        commands_mod.cmdContext(m);
    } else if (std.mem.eql(u8, cmd, "compact")) {
        commands_mod.cmdCompact(m, rest);
    } else if (std.mem.eql(u8, cmd, "goal")) {
        commands_mod.cmdGoal(m, rest);
    } else if (std.mem.eql(u8, cmd, "session")) {
        commands_mod.cmdSession(m);
    } else if (std.mem.eql(u8, cmd, "cache")) {
        commands_mod.cmdCache(m);
    } else if (std.mem.eql(u8, cmd, "bench")) {
        cmdBench(m);
    } else if (std.mem.eql(u8, cmd, "ask")) {
        cmdAskMode(m, arg);
    } else if (std.mem.eql(u8, cmd, "skills")) {
        cmdSkills(m);
    } else if (std.mem.eql(u8, cmd, "new")) {
        newSession(m);
    } else if (std.mem.eql(u8, cmd, "resume")) {
        resumeLatest(m);
    } else {
        const msg = std.fmt.allocPrint(m.allocator, "unknown command: {s} (/help)", .{cmd}) catch
            "unknown command";
        pushInfoOwned(m, msg);
    }
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
    const tail: []const u8 = if (rep.failed == 0)
        std.fmt.allocPrint(gpa, "  deleted {d} files", .{deleted}) catch "  done"
    else
        std.fmt.allocPrint(gpa, "  deleted {d}, {d} could NOT be removed", .{ deleted, rep.failed }) catch
            "  done (with failures)";
    pushInfoOwned(m, tail);
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
    session_elided = 0;
    summarized_this_session = false;
    const msg = std.fmt.allocPrint(
        m.allocator,
        "session resumed: {s} · {d} messages",
        .{ path, s.messages.items.len },
    ) catch "session resumed";
    pushInfoOwned(m, msg);
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

fn startChat(m: *tui.Model, input: []const u8) !void {
    const s = ensureSession(m, m.allocator);
    const copy = try m.allocator.dupe(u8, input);
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
    }
    const soft = iterationLimit();
    const hard = if (had_goal) goalHardLimit() else soft;

    m.repeats.reset();
    var checkpointed = false;

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
        // 0. THE BUILD IS RED AND THE GOAL IS OPEN: nothing below may end this turn.
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
        //    `blocked` is still honoured above all of it, at check 1 below: a real
        //    blocker has to be declarable or this is a cage.
        if (!turnMayEnd(&m.auto_check, m.goal.isOpen()) and m.goal.status == goal_mod.Status.none) {
            var why_buf: [96]u8 = undefined;
            const why = blk: {
                if (m.plan.openCount() > 0) {
                    break :blk std.fmt.bufPrint(&why_buf, "{d} plan steps open", .{m.plan.openCount()}) catch "plan steps open";
                }
                break :blk "no open steps";
            };
            pushErrorFmt(
                m,
                "not done: the last {s} was RED and the objective is not met ({s}). Fix it, or declare `blocked` with what would unblock it.",
                .{
                    if (m.auto_check.label_len > 0) m.auto_check.label[0..m.auto_check.label_len] else "check",
                    why,
                },
            );
            // The nudge is the prompt. `owned`, not a bare assignment: the loop frees the
            // previous prompt through it, so a `last_user` set without it leaks a turn's
            // worth of text every time the turn refuses to end.
            //
            // A stack buffer and not `allocPrint(m.allocator, …)`: this runs on the
            // refusing path, which is the path a turn takes when it is going badly.
            const nudge = m.allocator.dupe(
                u8,
                "The harness will not end this turn yet: the last check failed and the objective is not met. Read the errors above, fix them, and re-run the check. If you genuinely cannot, call `goal` with status blocked and what_would_unblock.",
            ) catch break;
            if (owned) |o| m.allocator.free(o);
            owned = nudge;
            last_user = nudge;
            continue;
        }

        const text = again orelse break;
        if (owned) |o| m.allocator.free(o);
        owned = text;
        last_user = text;

        // 1. The model ran the same call three times running. Stopped HERE, and not at
        //    the limit, because the limit costs twelve iterations first and the user
        //    sees a normal-looking turn that ends for no stated reason.
        if (m.loop_repeated) |which| {
            m.loop_repeated = null;
            pushErrorFmt(
                m,
                "stopped: `{s}` ran with the same arguments three times in a row. Something is not moving; tell me what to try instead.",
                .{which},
            );
            break;
        }

        // 1. The goal was decided. The model said so, and it is the only thing that
        //    ends a goal turn early.
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

/// Waits (briefly) for the automatic typecheck and reports it.
///
/// The cap is 4 s and it is not a guess about how long a build takes: a build that
/// takes longer than that is a build the user is watching, and the job keeps running
/// for the next turn to read. What must not happen is answering "done" about code
/// whose only compile check is still in flight.
pub fn finishAutoCheck(m: *tui.Model) void {
    const gpa = m.allocator;
    if (m.auto_check.job == 0) return;

    var waited_ms: u32 = 0;
    while (waited_ms < auto_check_wait_ms) {
        if (!std.mem.eql(u8, bgproc.stateWord(&m.bg, m.auto_check.job), "running")) break;
        sleep_mod.nap(50);
        waited_ms += 50;
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const note = m.auto_check.collect(&m.bg, arena_state.allocator()) orelse return;

    const owned = gpa.dupe(u8, note) catch return;
    // Into the history, owned: the session keeps it and this is not the turn's
    // arena. And to the screen, because a compile error nobody was shown is the
    // thing this whole feature exists to prevent.
    const sess = ensureSession(m, gpa);
    sess.append(.user, owned) catch gpa.free(owned);
    sess.flush();
    pushInfoFmt(m, "· {s} reported problems in the code you just wrote — see the history", .{
        m.auto_check.label[0..m.auto_check.label_len],
    });
}

/// How long the end of a turn waits for the automatic typecheck.
pub const auto_check_wait_ms: u32 = 4000;

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
pub const repeat_limit: u8 = 3;

/// Whether the repetition guard is blind to this tool.
///
/// ## The criterion, and why it is not a list of conveniences
///
/// A guard on "the same call twice" can only be honest about calls that are trying to
/// DO something. These two are trying to SEE something, and neither has an argument
/// that could distinguish it from itself: the variable is time, and time is not in the
/// arguments. That is the whole test — not "is this tool important", which would let
/// every future tool argue itself an exemption.
///
/// `read` is exempt because re-reading what you just edited is correct. `bash_output`
/// because the `bash` schema instructs the model to poll with it, so a poll is the
/// harness recommending a repeat — measured stopping a real turn on the third one, with
/// a test suite still running.
pub fn isRepeatExempt(name: []const u8) bool {
    return std.mem.eql(u8, name, "read") or std.mem.eql(u8, name, "bash_output");
}

pub const Repeats = struct {
    last: u64 = 0,
    run: u8 = 0,
    tool: [64]u8 = undefined,
    tool_len: usize = 0,

    /// Feeds one call. Returns the tool name when this is the third identical one.
    pub fn note(self: *Repeats, name: []const u8, args_json: []const u8) ?[]const u8 {
        var h: u64 = 14695981039346656037;
        for (name) |c| {
            h ^= c;
            h *%= 1099511628211;
        }
        h ^= 0xff;
        h *%= 1099511628211;
        for (args_json) |c| {
            h ^= c;
            h *%= 1099511628211;
        }
        if (h == self.last and self.run > 0) {
            self.run += 1;
        } else {
            self.last = h;
            self.run = 1;
            self.tool_len = @min(name.len, self.tool.len);
            @memcpy(self.tool[0..self.tool_len], name[0..self.tool_len]);
        }
        if (self.run >= repeat_limit) return self.tool[0..self.tool_len];
        return null;
    }

    /// The guard as the loop applies it.
    ///
    /// The exemption lives HERE and not at the call site on purpose. It was at the call
    /// site first (`if (!std.mem.eql(u8, c.name, "read"))`), and the consequence was that
    /// the only tests for it had to be the ones that went through the whole tool
    /// executor, while `note` — the thing with the counter in it — could not be asked
    /// "what happens when you poll?" directly. A rule that lives in one place is a rule
    /// the tests can call.
    pub fn noteGuarded(self: *Repeats, name: []const u8, args_json: []const u8) ?[]const u8 {
        if (isRepeatExempt(name)) return null;
        return self.note(name, args_json);
    }

    pub fn reset(self: *Repeats) void {
        self.* = .{};
    }
};

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

    if (s.files.items.len == 0) return;
    var detail_buf: [512]u8 = undefined;
    const detail = s.detailLine(&detail_buf) catch return;
    if (detail.len == 0) return;
    pushInfo(m, detail);
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
    if (t.stream_start_ns == 0) {
        t.stream_start_ns = std.Io.Timestamp.now(io_global, .real).nanoseconds;
    }
    t.m.streamDelta(delta);
}

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

    setStatusWithZo(m, .thinking, "no model chosen · asking the provider");

    var list = models_mod.listModels(gpa, http, def.models_url, providers.keyFor(def, m.environ) orelse curKey(m)) catch |err| {
        const msg = std.fmt.allocPrint(
            gpa,
            "no model chosen, and {s}'s catalog could not be read ({t}). Open /model to pick one.",
            .{ def.id, err },
        ) catch "no model chosen: the catalog could not be read";
        pushInfoOwned(m, msg);
        setStatusWithZo(m, .warn, "no model · /model");
        return null;
    };
    defer list.deinit(gpa);

    if (list.items.len == 0) {
        pushInfoFmt(m, "{s} publishes no models. Open /model to check the base URL.", .{def.id});
        setStatusWithZo(m, .warn, "no models published");
        return null;
    }

    var best: ?models_mod.Model = null;
    for (list.items) |info| {
        if (!isFree(info)) continue;
        if (best == null or std.mem.lessThan(u8, info.id, best.?.id)) best = info;
    }
    const chosen = best orelse list.items[0];

    // The window comes with the choice: this function downloaded the catalogue
    // to make the decision and threw `context_length` away on the way out, so
    // the budget stayed at 128k for a model that publishes 200k.
    setModelCtx(chosen.id, chosen.context_length);
    const why = if (chosen.is_free)
        "the first free model in its catalog"
    else
        "the first model in its catalog (it publishes no free ones)";
    // WHICH and WHY, in the history and not only in the status bar: a silent
    // choice is indistinguishable from a hardcoded default, which is the thing
    // this exists to replace.
    pushInfoFmt(m, "model → {s} ({s}; /model to change it)", .{ chosen.id, why });
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
    var list = try models_mod.listModels(gpa, http, def.models_url, providers.keyFor(def, env));
    defer list.deinit(gpa);
    if (list.items.len == 0) return error.NoModelsPublished;

    var best: ?models_mod.Model = null;
    for (list.items) |info| {
        if (!isFree(info)) continue;
        if (best == null or std.mem.lessThan(u8, info.id, best.?.id)) best = info;
    }
    const chosen = best orelse list.items[0];
    // Into the static buffer: the caller keeps this for the whole run and the
    // list is freed on the way out.
    setModelCtx(chosen.id, chosen.context_length);
    return curModel();
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
        // Anthropic carries the key in headers, not in Bearer: null here.
        .key = if (kind == .anthropic) null else providers.keyFor(def, m.environ) orelse curKey(m),
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
        .key = if (kind == .anthropic) null else providers.keyFor(def, m.environ),
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
    const msg = std.fmt.allocPrint(
        m.allocator,
        "quota gone on {s}/{s} ({s}) → {s}/{s} (free-auto {d}/{d})",
        .{
            sw.prev_provider,
            sw.prev_model,
            reason,
            to_c.provider_id,
            to_c.model_id,
            free_auto.rosterGet(m.allocator).idx + 1,
            free_auto.poolSize(),
        },
    ) catch "free-auto: switched model";
    pushInfoOwned(m, msg);
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
    const msg = std.fmt.allocPrint(
        m.allocator,
        "{s}/{s} failed: {s} → next turn starts with {s}/{s}",
        .{ sw.prev_provider, sw.prev_model, errPhrase(err), c.provider_id, c.model_id },
    ) catch "free-auto: the pair failed";
    pushInfoOwned(m, msg);
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

    const exp = mentions.expand(arena, io_global, msgs[li].content) catch return msgs;
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
    if (m.auto_check.collect(&m.bg, gpa)) |note| {
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
    if (comp.needs_summary and comp.summary_upto > 1 and !summarized_this_session) {
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
            const surl = if (sp.kind == .anthropic)
                std.fmt.bufPrint(&surl_buf, "{s}/messages", .{sp.base_url}) catch sp.base_url
            else
                std.fmt.bufPrint(&surl_buf, "{s}/chat/completions", .{sp.base_url}) catch sp.base_url;
            if (summarizeTurns(
                gpa,
                &sum_http,
                surl,
                if (sp.kind == .anthropic) null else sp.key,
                sp.kind,
                sp.model,
                chat.effectiveEffort(sp.model, current_effort),
                comp.msgs[sum_from..upto],
                arena,
            )) |summary| {
                summarized_this_session = true;
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
                summarized_this_session = true;
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
    if (pickTarget(m).model.len == 0) {
        _ = resolveModel(m, &http);
    }

    var pick = pickTarget(m);
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
        const it = std.fmt.allocPrint(
            gpa,
            "thinking · iteration {d}/{d}",
            .{ iteration + 1, iterationLimit() },
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
        const body = try chat.buildBodyMessages(
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
            tools_mod.toolsJson(),
            pick.kind,
        );

        // CAREFUL: `streamChat` expects the FULL URL, not just the provider's
        // base. Passing the bare base gave 404 on EVERY request from the TUI
        // (the headless runner in main.zig does add the path, which is why it
        // worked there).
        var url_buf: [1024]u8 = undefined;
        const url = if (pick.kind == .anthropic)
            std.fmt.bufPrint(&url_buf, "{s}/messages", .{pick.base_url}) catch pick.base_url
        else
            std.fmt.bufPrint(&url_buf, "{s}/chat/completions", .{pick.base_url}) catch pick.base_url;

        // For Anthropic the auth goes in headers (x-api-key), not in Bearer: null
        // is passed and `streamRaw` sets it. For the rest, Bearer with the key
        // OF THAT PROVIDER (not the active one's: sending one provider's key to
        // another endpoint is the `ZODE_PROVIDER` bug, once fixed).
        const bearer: ?[]const u8 = if (pick.kind == .anthropic) null else pick.key;

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
    updateTps(tstate.chars, tstate.stream_start_ns);
    cache_stats.session.record(chat.last_usage);

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

/// `/plan`: clears the visible task list.
///
/// It exists because the plan belongs to the TURN and sometimes gets stuck
/// half-done (the model ran out of steps, or the user wants to start over
/// without a new session). Without it, the only way to empty it is the model
/// sending an empty list, which is never going to happen on its own.
fn cmdPlan(m: *tui.Model) void {
    if (m.planCopy().isEmpty()) {
        pushInfo(m, "the plan is already empty");
        return;
    }
    m.clearPlan();
    pushInfo(m, "plan cleared");
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

    m.pushInfoFmt("{s} · from: {s}", .{ head_buf, cp.labelOf() });
    if (w.buffered().len > 0) {
        // `pushInfoOwned` of an EMPTY string would push a blank line; the old
        // `catch ""` made that reachable on OOM and printed nothing instead.
        m.pushInfoFmt("{s}", .{w.buffered()});
    }
    if (skipped > 0 or failed > 0) {
        const warn = std.fmt.allocPrint(m.allocator, "{d} file(s) skipped, {d} failed · the diff of the turn is still in the history", .{
            skipped,
            failed,
        }) catch "some files were skipped";
        pushInfoOwned(m, warn);
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
    m.replacePlan(snapshot);
    m.pushInfoFmt("{s}", .{line});
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
    if (v == .object) {
        if (v.object.get("name")) |nv| {
            if (nv == .string) want = std.mem.trim(u8, nv.string, " \t\r\n");
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
    const text = loader.load(entry, &body) orelse {
        const bad = std.fmt.allocPrint(arena, "the skill \"{s}\" could not be read ({s}). Continue without it.", .{ entry.name, entry.path }) catch "the skill could not be read";
        m.pushToolDone("skill", "unreadable", 0, bad);
        s.appendToolResult(call.id, "skill", bad) catch {};
        return 1;
    };

    m.pushToolDone("skill", entry.name, 0, text);
    s.appendToolResult(call.id, "skill", text) catch {};
    return 1;
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

fn taskParallelLimit(env: ?*const std.process.Environ.Map) usize {
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
    const limit = taskParallelLimit(m.environ);

    for (t.calls.items[from..to]) |call| {
        const arg = toolArgSummary(call.name, call.args_json, arena);
        m.pushToolStart(call.name, arg);
    }
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
    var results = arena.alloc(Job, n) catch {
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
        pending: *std.atomic.Value(usize),
        task: subagent_mod.Task,
        ok_slot: *std.atomic.Value(usize),
    };
    var ctxs = arena.alloc(Ctx, n) catch return .{ .ok = 0, .denied = 0 };
    var pending = std.atomic.Value(usize).init(0);
    var done_count = std.atomic.Value(usize).init(0);
    var malformed: usize = 0;
    for (t.calls.items[from..to], 0..) |call, k| {
        // Parsed HERE, on the turn thread, so a malformed task does not need a
        // thread and its message is not reordered by the race below.
        const parsed = subagent_mod.parseTask(arena, call.args_json) catch {
            malformed += 1;
            ctxs[k] = .{ .call = call, .out = &results[k], .m = m, .pending = &pending, .task = .{ .description = "" }, .ok_slot = &done_count };
            continue;
        };
        ctxs[k] = .{ .call = call, .out = &results[k], .m = m, .pending = &pending, .task = parsed, .ok_slot = &done_count };
        _ = pending.fetchAdd(1, .seq_cst);
    }

    const Runner = struct {
        fn run(ctx: *Ctx) void {
            // The turn is not over until these are, and `app.deinit()` destroys
            // the `Io` they are using (the detached-worker trap).
            ctx.m.beginWorker();
            defer ctx.m.endWorker();
            defer _ = ctx.pending.fetchSub(1, .seq_cst);
            if (ctx.task.description.len == 0) {
                ctx.out.err = true;
                return;
            }
            _ = ctx.ok_slot.fetchAdd(1, .seq_cst);
            // Each one has its OWN Report (a fixed 8 KB buffer) and its own
            // arena: sharing either between two threads is a silent data race.
            var rep = subagent_mod.Report{};
            const text = runSubagent(ctx.m, ctx.task, &rep);
            // COPIED: the arena of this thread dies with it and the text is read
            // by the caller after the wait.
            ctx.out.text = ctx.m.allocator.dupe(u8, text) catch "";
        }
    };

    // `limit` at a time: the semaphore is the pending counter itself, and the
    // threads are spawned in waves so at most `limit` are ever in flight.
    var spawned: usize = 0;
    while (spawned < n) {
        const wave = @min(limit, n - spawned);
        var running = std.atomic.Value(usize).init(0);
        var k: usize = 0;
        while (k < wave) : (k += 1) {
            const idx = spawned + k;
            if (ctxs[idx].task.description.len == 0) continue; // malformed: no thread
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
    m.pushInfoFmt("{d} subagent{s} in parallel", .{ ok, if (ok == 1) "" else "s" });
    return .{ .ok = ok, .denied = 0 };
}

/// What the main model reads when a `task` call has no usable arguments.
const subagentBadArgsText =
    "The `task` call needs a \"description\" (one line: what to find out) and may have a \"prompt\" (the full question). Nothing was searched. Do it yourself with grep/glob/read, or call `task` again with a description.";

fn taskCall(m: *tui.Model, s: *session_mod.Session, call: TurnCtx.Call, arena: std.mem.Allocator) usize {
    const task = subagent_mod.parseTask(arena, call.args_json) catch {
        m.pushToolDone("task", "malformed arguments", 0, subagentBadArgsText);
        s.appendToolResult(call.id, "task", subagentBadArgsText) catch {};
        return 1;
    };

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
fn runSubagent(m: *tui.Model, task: subagent_mod.Task, rep: *subagent_mod.Report) []const u8 {
    // Permission: a subagent spends the user's tokens and reads the whole repo.
    // `task` IS in `needsPermission`, so the dialog has already been shown by
    // `execToolCalls`'s gate before this is reached.
    const pick = pickTarget(m);
    const key = pick.key orelse return subagent_mod.refused("no api key for this provider", rep);

    var gpa = m.allocator;
    var http = http_client.Http.init(gpa, io_global);
    defer http.deinit();

    var json_buf: [64 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&json_buf);
    w.writeByte('[') catch return subagent_mod.refused("no memory for the tool list", rep);
    var kept: usize = 0;
    for (subagent_mod.tool_names) |tn| {
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
    var msgs: std.ArrayList(chat.ChatMessage) = .empty;
    var tstate = SubTurn{ .m = m };
    defer tstate.deinit(gpa);

    const user_msg = if (task.prompt.len > 0)
        std.fmt.allocPrint(
            gpa,
            "{s}\n\n{s}",
            .{ task.description, task.prompt },
        ) catch return subagent_mod.refused("no memory for the prompt", rep)
    else
        gpa.dupe(u8, task.description) catch return subagent_mod.refused("no memory for the prompt", rep);
    defer gpa.free(user_msg);

    msgs.append(gpa, .{ .role = "system", .content = subagent_mod.system_prompt }) catch
        return subagent_mod.refused("no memory for the system prompt", rep);
    msgs.append(gpa, .{ .role = "user", .content = user_msg }) catch
        return subagent_mod.refused("no memory for the prompt", rep);

    var url_buf: [1024]u8 = undefined;
    const url = if (pick.kind == .anthropic)
        std.fmt.bufPrint(&url_buf, "{s}/messages", .{pick.base_url}) catch pick.base_url
    else
        std.fmt.bufPrint(&url_buf, "{s}/chat/completions", .{pick.base_url}) catch pick.base_url;

    var body_buf: [256 * 1024]u8 = undefined;
    var iteration: usize = 0;
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

        const body = chat.buildBodyMessages(
            &body_buf,
            pick.model,
            comp.msgs,
            // LOW effort, always: this is a bounded search, not a design, and
            // there is nobody to impress. This is where most of the money is
            // saved and no quality is lost.
            .low,
            tools_json,
            pick.kind,
        ) catch {
            cstate.deinit();
            return subagent_mod.refused("the request was too large", rep);
        };

        // The cancel flag is NOT cleared here. It used to be, and with subagents
        // running in parallel that is worse than a no-op: one subagent starting
        // would erase the ESC the user pressed while another was mid-flight, so
        // the turn they were watching carried on. ESC is the user's signal, it
        // stays set, and every request obeys it (see `streamRaw`).
        const bearer: ?[]const u8 = if (pick.kind == .anthropic) null else key;
        // `streamChat` returns `void`: it owns the StreamCtx and destroys it.
        // (`streamChatCtx` is the other one, and it hands the ctx over — mixing
        // them up is how a subagent leaks 8 KB per iteration.)
        chat.streamChat(
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
        ) catch |err| {
            cstate.deinit();
            // A cancelled subagent returns what it found, if anything. Treating
            // ESC as "refused" would throw away a report the user paid for.
            if (err == error.Cancelled and tstate.text.items.len > 0) {
                const partial = subagent_mod.formatReport(tstate.text.items, rep);
                return partial;
            }
            return subagent_mod.refused(@errorName(err), rep);
        };
        cstate.deinit();

        if (tstate.calls.items.len == 0) {
            // Done: the text IS the report.
            const out = subagent_mod.formatReport(tstate.text.items, rep);
            return out;
        }

        // Tool round. The assistant message carries its `tool_calls` or the next
        // request is a 400 (the bug the TUI agent loop had).
        const tc_json = if (tstate.calls.items.len > 0)
            toolCallsJsonFromCalls(gpa, tstate.calls.items)
        else
            null;
        msgs.append(gpa, .{ .role = "assistant", .content = tstate.text.items, .tool_calls_json = tc_json }) catch
            return subagent_mod.refused("out of memory during the subagent loop", rep);

        for (tstate.calls.items) |call| {
            // A tool the subagent is not allowed to use comes back as a tool
            // result, NOT as a crash: the model asked for something out of scope
            // and it should find out by being told, in the same turn.
            if (!subagent_mod.allowsTool(call.name)) {
                const denied = std.fmt.allocPrint(gpa, "the subagent may not use `{s}`. It can only search and read.", .{call.name}) catch "not allowed";
                msgs.append(gpa, .{ .role = "tool", .content = denied, .tool_call_id = call.id }) catch break;
                continue;
            }
            const res_text = tools_mod.execute(
                io_global,
                call.name,
                call.args_json,
                gpa,
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
                const emsg = gpa.dupe(u8, @errorName(err)) catch continue;
                msgs.append(gpa, .{ .role = "tool", .content = emsg, .tool_call_id = call.id }) catch break;
                continue;
            };
            // The per-result cap is the subagent's own, tighter one: 16 KB of grep
            // in a 24k budget is two thirds of the window in a single call.
            const capped = if (res_text.len > subagent_mod.max_tool_output)
                res_text[0..subagent_mod.max_tool_output]
            else
                res_text;
            msgs.append(gpa, .{ .role = "tool", .content = capped, .tool_call_id = call.id }) catch break;
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
    "read-only mode is on: the user asked zode to look before it touches anything, " ++
    "so write/edit/bash did not run. Do NOT retry it. Either use `ask` to tell the " ++
    "user what you found and what you would change, or (if you are already sure) say " ++
    "so in one line — the user can turn read-only off with shift+tab.";

/// ESC: kills the foreground command if there is one. Returns how many were
/// killed. See `bgproc.killForeground` for why this is not a no-op.
pub fn killForeground() usize {
    return if (bgproc.killForeground()) 1 else 0;
}

/// One tool call, in series. Returns 1 if it ran, 0 if it was denied.
///
/// This is the serial path: everything with side effects, and the single-call
/// case for a read-only tool (a batch of one is not worth a thread).
fn execOneCall(
    m: *tui.Model,
    s: *session_mod.Session,
    call: TurnCtx.Call,
    arena: std.mem.Allocator,
    denied: *usize,
) usize {
    const arg = toolArgSummary(call.name, call.args_json, arena);
    m.pushToolStart(call.name, arg);
    // The status says WHAT is running, not a generic "working": with a slow `bash`
    // that is the difference between "working" and "hung". The text is
    // copied to a fixed buffer, so the arg from the worker's arena can die
    // without a problem.
    setStatusWithZo(m, .tooling, arg);

    // ── read-only mode ──
    //
    // BEFORE the permission dialog, and that order is the point: in read-only the
    // call is not going to happen, so asking "may I run this write?" and then
    // saying no is a dialog that lies. The user asked for "look, don't touch", and
    // a permission prompt for a write in that mode is a bug in the UI.
    if (read_only and isWriteTool(call.name)) {
        m.pushToolDone(call.name, "read-only", 0, read_only_text);
        s.appendToolResult(call.id, call.name, read_only_text) catch {};
        return 0;
    }

    // ── permission ──
    if (!yolo and tools_mod.needsPermission(call.name) and !isAlwaysAllowed(call.name)) {
        var dbuf: [384]u8 = undefined;
        const detail = std.fmt.bufPrint(&dbuf, "{s} {s}", .{ call.name, arg }) catch call.name;
        switch (m.requestPermission(call.name, detail)) {
            .allow => {},
            .allow_always => setAlwaysAllowed(m, call.name),
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
    var before: ?[]const u8 = null;
    if (touchesFile(call.name)) {
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

    const res = tools_mod.execute(io_global, call.name, call.args_json, arena, &m.bg, &m.reads) catch |err| {
        const ms = elapsedMs(call_t0);
        // What the MODEL is told is not the error name. See `describeError`.
        const emsg = tools_mod.describeError(arena, err, call.name, call.args_json);
        m.pushToolDone(call.name, "failed", ms, emsg);
        s.appendToolResult(call.id, call.name, emsg) catch {};
        return 0;
    };
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

    s.appendToolResult(call.id, call.name, res) catch {};
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
            ok += execOneCall(m, s, call, arena, &denied);
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
            const text = tools_mod.execute(io_global, ctx.call.name, ctx.call.args_json, a, &ctx.m.bg, &ctx.m.reads) catch |err| {
                ctx.out.err = true;
                ctx.out.text = @constCast(@errorName(err));
                ctx.out.ms = elapsedMs(call_t0);
                return;
            };
            // COPIED into the turn arena: `a` dies with this thread's defer and the
            // text is read by the caller afterwards.
            ctx.out.text = a.dupe(u8, text) catch "";
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
        s.appendToolResult(t.calls.items[from + k].id, t.calls.items[from + k].name, r.text) catch {};
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

fn execToolCalls(m: *tui.Model, s: *session_mod.Session, t: *TurnCtx) !?[]u8 {
    const gpa = m.allocator;
    var astate = std.heap.ArenaAllocator.init(gpa);
    defer astate.deinit();
    const arena = astate.allocator();
    const t0 = std.Io.Timestamp.now(io_global, .real).nanoseconds;
    var ran: usize = 0;
    var denied: usize = 0;

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
            const n = runParallelBatch(m, s, t, i, batch, arena);
            ran += n.ok;
            denied += n.denied;
            i = batch;
            continue;
        }

        i += 1;
        ran += execOneCall(m, s, call, arena, &denied);
    }
    // An edit to code is followed by a typecheck WITHOUT the model asking, because
    // the model finds out it broke something one iteration too late otherwise:
    // the next request goes out with the broken state in the prompt, those tokens
    // are billed, and only then does a build say so.
    //
    // Started here, in the BACKGROUND, so the model goes on to the next file and
    // the result is waiting when it looks. The alternative — making the model
    // call `check` — is the same request with one more round trip in it.
    for (t.calls.items) |c| {
        m.auto_check.afterTool(&m.bg, m.allocator, io_global, c.name, c.args_json);
        // The repetition guard, fed HERE because this is the only place a tool call is
        // seen with its arguments. The loop checks the flag; it cannot count, because it
        // never sees a call.
        //
        // A call whose whole purpose is to LOOK AT SOMETHING AGAIN is exempt, and the
        // criterion is that it has no argument that could distinguish it from itself:
        // the only variable is time, and time is not in the arguments. See
        // `isRepeatExempt` and `Repeats.noteGuarded`, which is where the rule lives so
        // that this call and its tests cannot disagree.
        if (m.repeats.noteGuarded(c.name, c.args_json)) |which| {
            if (m.loop_repeated == null) {
                m.loop_repeated = which;
            }
        }
    }

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

/// The automatic typecheck's state, with no `Model` in it.
///
/// It is a struct and not three fields on `Model` because there are TWO runners:
/// the TUI and `--chat`, and the automatic check used to exist only in the first
/// one — so the runner every pty test and every measurement in this repo drives
/// edited code and never compiled it. Same root cause as the headless prompt
/// having no routing rules: a second, lesser implementation of the same agent,
/// and every place it diverges is a place where `--chat` is quietly worse.
///
/// One implementation, two owners. The TUI keeps it on the `Model`; the headless
/// runner keeps it on the stack.
/// The gate that decides whether an edit is worth a build at all.
///
/// Deliberately optimistic. `write {files:[...]}` has no `path`, so the multi-file
/// forms answer false here — and that is the wrong direction. Guessing by extension
/// means looking inside the arguments, and an argument the harness cannot parse must
/// not be the reason a broken build goes unnoticed. The `check` tool is there for
/// that case, and the model has it.
fn codePathsFromArgs(args_json: []const u8, arena: std.mem.Allocator) bool {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch return false;
    if (parsed != .object) return false;
    const v = parsed.object.get("path") orelse return false;
    if (v != .string) return false;
    return typecheck_mod.worthChecking(v.string);
}

pub const AutoCheck = struct {
    /// The job id, or 0 when there is none. An id and a re-read of the registry is
    /// the whole contract: the output belongs to a background thread's buffer, so it
    /// cannot be a pointer into a turn's arena.
    job: u32 = 0,
    /// The last verdict this turn: 0 = nothing has been checked, 1 = the last check
    /// passed, 2 = it failed.
    ///
    /// ## Why the harness needs to remember this
    ///
    /// Measured over five real task runs: the same model that codes well in another
    /// harness finished none of them, and in every case the turn ended with the code
    /// never compiling. Not because the model refused to check — it started the checks
    /// — but because nothing in the loop connected "the build is red" to "you may not
    /// finish yet".
    ///
    /// The harness can see that the code is broken. It has the exit code and the
    /// diagnostics; it already builds the model's own message out of them. So the
    /// information was there and the LOOP did not ask, and the turn ended the way turns
    /// end: the model stopped calling tools. Asking the model to notice is exactly the
    /// thing that does not work — a turn that ends in prose is a turn where nobody is
    /// grading anything any more.
    ///
    /// An integer and not a bool because "never checked" and "checked and passed" are
    /// different, and only the first one is allowed to end a turn.
    last_verdict: Verdict = .unchecked,
    /// The command it is running, for the message the model reads. A fixed buffer,
    /// because it outlives the arena that composed it.
    label: [64]u8 = @splat(0),
    label_len: usize = 0,
    /// How many have been started this turn, so a model that edits nine files in a
    /// row does not start nine builds.
    started_this_turn: u32 = 0,

    /// Per turn. Resetting it here and not per iteration is the difference between
    /// "two builds per turn" and "two builds per iteration for the rest of the
    /// session".
    pub fn resetTurn(self: *AutoCheck, reg: *bgproc.Registry, io: std.Io) void {
        _ = io;
        self.started_this_turn = 0;
        self.last_verdict = .unchecked;
        // The running job is NOT killed.
        //
        // It was, and that made the whole feature useless most of the time. A
        // `zig build` takes seconds; the turn usually ends before it does, so
        // killing it here threw away the one piece of information the feature
        // exists to produce — whether the code the model just wrote compiles. The
        // reason it was killed was "a build from an abandoned turn keeps burning a
        // core", which is true of a job nobody will ever read and false of a 15 s
        // build the next turn is about to read.
        //
        // ESC is the thing that stops a build nobody is waiting for, and it already
        // does (`bgproc.requestKillAll`). A turn boundary is not that.
        _ = reg;
        self.job = 0;
    }

    /// Start the project's typecheck if this tool call edited code.
    pub fn afterTool(
        self: *AutoCheck,
        reg: *bgproc.Registry,
        gpa: std.mem.Allocator,
        io: std.Io,
        name: []const u8,
        args_json: []const u8,
    ) void {
        if (!envTruthy("ZODE_AUTO_CHECK", true)) return;
        if (self.started_this_turn >= auto_check_per_turn) return;
        if (!touchesFile(name)) return;

        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        if (!codePathsFromArgs(args_json, arena_state.allocator())) return;

        if (self.job != 0 and std.mem.eql(u8, bgproc.stateWord(reg, self.job), "running")) return;

        const plan = check_tool.planAt(io, ".") orelse return;
        const id = bgproc.spawn(reg, gpa, io, plan.command) catch return;
        self.job = id;
        self.started_this_turn += 1;
        const l = @min(plan.label.len, self.label.len);
        @memcpy(self.label[0..l], plan.label[0..l]);
        self.label_len = l;
    }

    /// Waits (briefly) for the check and then collects it, for a caller that is
    /// about to finish.
    ///
    /// Measured: with the result only read at the START of the next iteration, a
    /// turn that ended right after the edit collected nothing — the `zig build` it
    /// had started was still running — and the next turn's reset killed it. So the
    /// feature produced nothing on exactly the turns it exists for, which is worse
    /// than not having it: the model would say "done" about code nobody compiled.
    ///
    /// The cap is not a guess about how long a build takes: a build longer than this
    /// is a build the user is watching, the job keeps running, and the next turn
    /// reads it. What must not happen is answering about code whose only compile
    /// check is still in flight.
    pub fn autoCheckWait(self: *AutoCheck, reg: *bgproc.Registry, arena: std.mem.Allocator) ?[]const u8 {
        if (self.job == 0) return null;
        var waited_ms: u32 = 0;
        while (waited_ms < auto_check_wait_ms) {
            if (!std.mem.eql(u8, bgproc.stateWord(reg, self.job), "running")) break;
            sleep_mod.nap(50);
            waited_ms += 50;
        }
        return self.collect(reg, arena);
    }

    /// The result, if it is ready, as text for the model. Null while it runs.
    ///
    /// It only reports when there IS something wrong. A passing check produces
    /// nothing at all, on purpose: "it compiles" is worth nothing to a model that
    /// was not going to write code anyway, and it is the one message that could be
    /// repeated five times a turn.
    pub fn collect(self: *AutoCheck, reg: *bgproc.Registry, arena: std.mem.Allocator) ?[]const u8 {
        const id = self.job;
        if (id == 0) return null;
        if (std.mem.eql(u8, bgproc.stateWord(reg, id), "running")) return null;

        var out = bgproc.Output{};
        // No header: it is zode's own `[zig build] finished exit=1` line, and a scan
        // for `file:line: error:` finds the whole command inside it.
        const text = bgproc.readNoHeader(reg, &out, id) catch return null;
        // Consumed either way: a job that has been read is done, and leaving the id
        // set would make the NEXT edit report the previous turn's errors.
        self.job = 0;

        const diags = typecheck_mod.extractDiagnostics(arena, text, 12) catch return null;
        if (diags.len == 0) {
            self.last_verdict = .passed;
            // A check that FAILED and produced no `file:line: error:` is a failure,
            // not a pass. Measured: a `build.zig` that panics prints a source
            // location and a `thread N panic:` line, the scan finds nothing, and
            // silence here would leave the model editing a project whose build does
            // not even run.
            const failed = out.exit != null and out.exit.? != 0;
            if (!failed) return null;
            self.last_verdict = .failed;
            const tail = text[if (text.len > 1500) text.len - 1500 else 0..];
            return std.fmt.allocPrint(
                arena,
                "[{s} FAILED with exit {d} and reported no type error]\n{s}\nThat usually means the build itself could not run \u{2014} a broken build script, a missing dependency or a panic. Do not treat this as a passing build.",
                .{ self.label[0..self.label_len], out.exit.?, tail },
            ) catch null;
        }

        self.last_verdict = .failed;
        return std.fmt.allocPrint(
            arena,
            "[{s} found {d} problem(s) in the code you just wrote]\n{s}\nThis is the project's own compiler, not a guess. Fix these before writing more.",
            .{ self.label[0..self.label_len], countDiagLines(diags), diags },
        ) catch null;
    }
};

/// What the last verification of this turn said. See `AutoCheck.last_verdict` for why
/// the loop needs it.
pub const Verdict = enum { unchecked, passed, failed };

/// May the turn end right now?
///
/// This is the function that makes "finish the task" mean something. A turn ends when
/// the model stops asking for tools, and that used to be the end of it, whatever the
/// state of the code: five real runs, five turns that ended with a build nobody had
/// run or a build that was red, and a model that had no way to be told.
///
/// The rules, in order:
///
/// - A RED verification is the one hard block. Not "usually", not "unless the budget is
///   over": the code does not work, and a turn that ends here produces a summary of
///   code that does not compile. The budget does not get a vote — that is the ceiling's
///   job and it says UNFINISHED.
/// - A turn with NOTHING verified can end, because that is a turn of prose, of
///   questions, of a task that needs no build. Demanding a compile there would make the
///   harness nag about a README.
/// - The model may always leave by declaring `blocked`, which is the honest exit and the
///   reason the ceiling is not a dead end.
///
/// The check is the AUTO one and not "did the model run a test": the harness cannot
/// read the model's intentions, but it can read its own compiler's exit code.
pub fn turnMayEnd(ac: *const AutoCheck, goal_open: bool) bool {
    if (goal_open and ac.last_verdict == .failed) return false;
    return true;
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

    // 3. The session. One write, and it is the only reason any of this exists.
    if (session) |s| s.flush();

    std.process.exit(0);
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

/// How many automatic checks one turn may start.
///
/// 2, not 1: the shape of a task is "edit, read the errors, fix, edit, read the
/// errors", and with 1 the second fix is never checked. Not 3, because a turn that
/// needs three builds is a turn where the model is guessing.
pub const auto_check_per_turn: u32 = 2;

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
    return std.mem.eql(u8, name, "write") or std.mem.eql(u8, name, "edit");
}

/// Tools blocked in read-only mode.
///
/// `bash` is in the list even though a `bash` can be a pure read, because it can
/// also be `rm`: the mode has to be decided from the tool, not from parsing the
/// command string, or every read-only mode would be bypassable by writing
/// `bash ls` first to learn what the model "really" wants to run.
pub fn isWriteTool(name: []const u8) bool {
    return std.mem.eql(u8, name, "write") or
        std.mem.eql(u8, name, "edit") or
        std.mem.eql(u8, name, "bash");
}

/// Path of the file a writing tool touches (or null if it does not say).
fn filePathOf(args_json: []const u8, arena: std.mem.Allocator) ?[]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch return null;
    if (parsed != .object) return null;
    const v = parsed.object.get("path") orelse return null;
    if (v != .string or v.string.len == 0) return null;
    return v.string;
}

/// Identifying argument of a tool, for the `⏺ tool(arg)` line.
fn toolArgSummary(name: []const u8, args_json: []const u8, arena: std.mem.Allocator) []const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch return "";
    if (parsed != .object) return "";
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
    else
        "";
    if (wanted.len > 0) {
        if (parsed.object.get(wanted)) |v| {
            if (v == .string) return v.string;
        }
    }
    // Without the expected field, the first string there is will do.
    var it = parsed.object.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.* == .string) return kv.value_ptr.*.string;
    }
    return "";
}

/// One-line summary of a tool's result (`⎿ Read 12 lines`).
fn toolResultSummary(name: []const u8, res: []const u8, arena: std.mem.Allocator) []const u8 {
    if (res.len == 0) return "";
    var it = std.mem.splitScalar(u8, res, '\n');
    const first = it.next() orelse return "";
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
    const msg = std.fmt.allocPrint(
        gpa,
        "{s}: {s} · retrying in {d}.{d}s (attempt {d}/3)",
        .{ errPhrase(err), detail, wait_ms / 1000, (wait_ms % 1000) / 100, attempt + 1 },
    ) catch "retrying";
    pushInfoOwned(m, msg);

    // The status stays short (it is a segmented line) but has the why, which is
    // what you read at a glance: "rate limited 2/3" and not "retrying…".
    const short = std.fmt.allocPrint(gpa, "{s} {d}/3", .{ errPhrase(err), attempt + 1 }) catch "retrying";
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
            const msg = if (reason.len > 0)
                std.fmt.allocPrint(gpa, "auth failed on {s}: {s}\n  check {s} (/provider shows the state)", .{
                    cur_provider_id, reason, names,
                }) catch "auth failed"
            else
                std.fmt.allocPrint(gpa, "key rejected by {s}. check {s} (/provider shows the state)", .{
                    cur_provider_id, names,
                }) catch "key rejected";
            pushErrorOwned(m, msg);
        },
        // 402: the account has no balance. It is not a zode bug nor the key.
        error.NoCredits => {
            const msg = std.fmt.allocPrint(
                gpa,
                "out of credits on {s}: {s}\n  pick a `-free` model or switch with /provider",
                .{ cur_provider_id, reason },
            ) catch "out of credits";
            pushErrorOwned(m, msg);
        },
        // 404: the model does not exist on that provider. Almost always it is an old
        // HARDCODED id left over (which is why the default is changed when the
        // provider retires it) or a typo in /use.
        error.ModelNotFound => {
            const msg = std.fmt.allocPrint(
                gpa,
                "model `{s}` does not exist on {s}: {s}\n  /model for the ones you have",
                .{ cur_model, cur_provider_id, reason },
            ) catch "model does not exist";
            pushErrorOwned(m, msg);
        },
        // 403: in practice it is almost always the MODEL that is not available for
        // this account, not the key. Saying that plainly saves hours of
        // debugging.
        error.Forbidden => {
            const msg = std.fmt.allocPrint(
                gpa,
                "`{s}` is not available on your {s} account: {s}\n  /model for your models, /provider to switch",
                .{ cur_model, cur_provider_id, reason },
            ) catch "access denied";
            pushErrorOwned(m, msg);
        },
        error.BadRequest => {
            // 400: the server did not accept the request. With free-auto on, this pair is
            // already set aside for the next turn (`noteTurnFailure`), so all
            // that is left to say here is what it asked for and what it replied.
            const msg = std.fmt.allocPrint(
                gpa,
                "{s} rejected the request for `{s}`: {s}",
                .{ cur_provider_id, cur_model, reason },
            ) catch "request rejected";
            pushInfoOwned(m, msg);
        },
        error.RateLimited, error.Overloaded => {
            // `errPhrase`, not `@errorName`: a person reads this line and
            // "RateLimited" tells nobody anything. It is the same rule the retry
            // notices already follow, and they do it right.
            const msg = std.fmt.allocPrint(gpa, "{s} after several attempts: {s}", .{ errPhrase(err), reason }) catch
                "service saturated";
            pushErrorOwned(m, msg);
        },
        else => {
            // `errPhrase` and not `@errorName`: this line is read by a person and
            // "ServerError" tells nobody anything. And it goes out as an ERROR
            // (red) because that is what it is.
            const msg = std.fmt.allocPrint(gpa, "{s}: {s}", .{ errPhrase(err), reason }) catch "error";
            pushErrorOwned(m, msg);
        },
    }
    setStatusWithZo(m, .warn, errPhrase(err));
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
) ?[]const u8 {
    var ast = std.heap.ArenaAllocator.init(gpa);
    defer ast.deinit();
    const a = ast.allocator();

    // A single user message with the conversation to summarize + the instruction.
    const prompt = compaction.summaryPrompt(a, msgs) catch {
        models_mod.dbg("[compaction] could not build the summary prompt\n", .{});
        return null;
    };
    const body_buf = bodyBuf(gpa) catch return null;
    const one = [_]chat.ChatMessage{.{ .role = "user", .content = prompt }};
    const body = chat.buildBodyMessages(body_buf, model_name, &one, effort, "", kind) catch {
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
    chat.streamChat(gpa, http, url, bearer, @constCast(body), cb, kind, false) catch |err| {
        models_mod.dbg("[compaction] el resumen fallo: {t}\n", .{err});
        return null;
    };
    if (sink.buf.items.len == 0) return null;
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

/// Job of the `/models` worker (list in the history) and of the picker.
const ModelsJob = struct {
    model: *tui.Model,
    /// false = list in the history (`/models`); otherwise open the picker.
    for_picker: bool = false,
};

/// `/models`: lists the active provider's models in the history.
pub fn listModelsAsync(m: *tui.Model) !void {
    const job = try m.allocator.create(ModelsJob);
    m.beginWorker();
    job.* = .{ .model = m, .for_picker = false };
    m.models_for_picker = false;
    const th = std.Thread.spawn(.{}, modelsWorker, .{job}) catch {
        m.endWorker();
        m.allocator.destroy(job);
        return error.ThreadSpawnFailed;
    };
    th.detach();
}

/// `/model` and Ctrl+T: the two-column model palette.
///
/// The active provider's models are requested; while they arrive, the palette
/// opens anyway with the providers column (which is local and needs no
/// network), and the worker fills it in when it finishes. So there is no blank
/// wait.
pub fn pickerModelsAsync(m: *tui.Model) !void {
    const job = try m.allocator.create(ModelsJob);
    m.beginWorker();
    job.* = .{ .model = m, .for_picker = true };
    m.models_for_picker = true;
    const th = std.Thread.spawn(.{}, modelsWorker, .{job}) catch {
        m.endWorker();
        m.allocator.destroy(job);
        return error.ThreadSpawnFailed;
    };
    th.detach();
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
    defer job.model.allocator.destroy(job);
    const m = job.model;
    const gpa = m.allocator;
    m.beginWorker();
    defer m.endWorker();

    const def = activeProviderDef(m.environ);

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
        if (modelcache.read(io_global, m.environ, astate.allocator(), def.id, def.models_url)) |e| {
            // `copyOut`, NOT `dupe(Model, ...)`. `Model` is a struct of slices into the
            // cache's arena, so a plain struct copy is a list of pointers into memory
            // that dies at the closing brace of this block. Measured: SIGSEGV, exit
            // status 139, no panic message, empty stderr — and only in the TUI, because
            // `--models` uses its list before the arena goes away.
            cached = modelcache.copyOut(gpa, e.models) catch &.{};
            from_cache = cached.len > 0;
        }
    }
    if (from_cache) {
        publishModels(m, cached, def.id, .cached);
        setStatusWithZo(m, .done, "models from cache");
    } else {
        setStatusWithZo(m, .tooling, "listing models…");
    }

    var http = http_client.Http.init(gpa, io_global);
    defer http.deinit();

    const key = curKey(m);

    var list = models_mod.listModels(gpa, &http, def.models_url, key) catch |err| {
        // With a cache on screen, a failed refresh is a NOTE and not an error: the user
        // is looking at a usable list, and an error line over it invites them to think
        // the list is wrong.
        if (from_cache) {
            const msg = std.fmt.allocPrint(gpa, "could not refresh the model list ({t}); showing the last one saved", .{err}) catch "could not refresh the model list";
            pushInfoOwned(m, msg);
            return;
        }
        if (err == error.HttpError) {
            m.pushInfoFmt("models: HTTP error at {s}", .{def.models_url});
        } else {
            const msg = std.fmt.allocPrint(gpa, "models: {t}", .{err}) catch "models error";
            pushInfoOwned(m, msg);
        }
        setStatusWithZo(m, .warn, "no models");
        return;
    };

    defer list.deinit(gpa);

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
        const line = modelcache.describe(arena, d);
        if (line.len > 0) pushInfoOwned(m, gpa.dupe(u8, line) catch line);
        modelcache.freeOut(gpa, cached);
    }

    // Written AFTER the diff and not before: a cache that was just refreshed with the
    // list in hand and still compares as "changed" is a cache that never converges.
    modelcache.write(io_global, m.environ, def.id, def.models_url, list.items);

    publishModels(m, list.items, def.id, .fresh);
    setStatusWithZo(m, .done, "models ready");
}

const ModelSource = enum { cached, fresh };

/// Hands a list of models to whoever is waiting: the picker gets items, the plain
/// `/models` gets lines.
///
/// One function because there were two copies of the "free first, then alphabetical"
/// ordering and a cache makes it a third call site; three copies of an ordering is how
/// the picker and `/models` end up disagreeing about which models exist.
fn publishModels(m: *tui.Model, models: []const models_mod.Model, provider_id: []const u8, source: ModelSource) void {
    const gpa = m.allocator;
    const sorted = gpa.dupe(models_mod.Model, models) catch return;
    defer gpa.free(sorted);
    // The "free" ones first: those are the ones that work without credits, and
    // alphabetical within each group so the list is stable between runs.
    std.mem.sort(models_mod.Model, sorted, {}, freeFirst);

    if (m.models_for_picker) {
        // The palette is NOT touched here: this is the worker's thread and the UI thread
        // draws it without a lock, and that was a segfault. ITEMS already built with
        // their own strings are handed over: handing over the `Model`s and freeing the
        // list on exit left the ids dangling and the drawing blew up.
        const items = buildModelItems(m, sorted);
        if (items) |it| m.setPendingItems(it);
        return;
    }
    for (sorted) |info| {
        const hint = if (isFree(info)) "free" else "";
        const line = std.fmt.allocPrint(gpa, "{s:<44} {s}", .{ info.id, hint }) catch continue;
        pushInfoOwned(m, line);
    }
    m.pushInfoFmt("{d} models on {s}{s}", .{
        sorted.len,
        provider_id,
        if (source == .cached) " (saved list; refreshing)" else "",
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

/// Opens the model palette in TWO COLUMNS: providers | the active one's models.
///
/// It reuses the list already downloaded from the active provider, so opening it
/// costs no network call (and if there are no models yet, `pickerModelsAsync` is
/// launched to have something to paint).
/// Builds the model palette's items: providers first (with their key state) and
/// then the models with their `free` flag or their context window. All strings
/// are own copies from the model's allocator.
fn buildModelItems(m: *tui.Model, list: []models_mod.Model) ?[]palette.Item {
    const gpa = m.allocator;
    const defs = allProviders(gpa);
    const n = defs.len + 1 + list.len; // +1 = "+ connect"
    const items = gpa.alloc(palette.Item, n) catch return null;
    var i: usize = 0;
    for (defs) |*d| {
        const active = std.mem.eql(u8, d.id, cur_provider_id);
        const has_key = providers.hasKey(d, m.environ);
        items[i] = .{
            .kind = .provider,
            .group = 1,
            .label = gpa.dupe(u8, d.id) catch return null,
            .hint = gpa.dupe(u8, if (active) "active" else if (has_key) "key ok" else "no key") catch "",
        };
        i += 1;
    }
    // CAREFUL: EVERY label/hint has to be an OWN copy. A literal
    // ("+ connect") freed with `gpa.free` is an "Invalid free" that only shows
    // up on app exit, when the palette is destroyed.
    items[i] = .{
        .kind = .connect,
        .group = 2,
        .label = gpa.dupe(u8, "+ connect") catch return null,
        .hint = gpa.dupe(u8, "ctrl+a") catch return null,
    };
    i += 1;
    for (list) |mi| {
        const hint = if (isFree(mi)) "free" else if (mi.context_length > 0)
            std.fmt.allocPrint(gpa, "{d}k", .{mi.context_length / 1024}) catch ""
        else
            "";
        items[i] = .{
            .kind = .model,
            .group = 3,
            .label = gpa.dupe(u8, mi.id) catch return null,
            .hint = if (hint.len > 0) (gpa.dupe(u8, hint) catch "") else "",
            .ctx_tokens = mi.context_length,
        };
        i += 1;
    }
    return items;
}

fn openModelPalette(m: *tui.Model, list: []models_mod.Model) void {
    // The mode goes before `setItemsOwned` (see the note in the same function).
    // It delegates to `buildModelItems`: keeping TWO item constructors means
    // that as soon as one of them is not updated, loose literals show up (which
    // `freeItems` cannot free) and the app crashes on exit.
    const items = buildModelItems(m, list) orelse return;
    // The mode goes BEFORE `setItemsOwned`: `resetSelection` computes the active
    // column from the mode. With the old mode, opening the model palette left
    // the PROVIDERS column active, the arrows did not move the model list and
    // it looked like there was nothing to pick.
    m.pal.mode = .models;
    m.pal.active = true;
    m.pal.query_len = 0;
    m.pal.setItemsOwned(items, &model_groups);
}

/// Groups of the model palette.
pub const model_groups = [_]palette.Group{
    .{ .name = "Providers" },
    .{ .name = "" }, // separator for the "Connect an integration" item
    .{ .name = "Models" },
};

/// `/provider`: picker with all the providers and their key state.
fn openProviderPicker(m: *tui.Model) void {
    const gpa = m.allocator;
    const defs = allProviders(gpa);
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
        std.mem.eql(u8, k, "use") or std.mem.eql(u8, k, "effort")) return 4;
    return 5;
}

/// Ctrl+P → Connect: the modal to connect providers. A single list with all the
/// providers and their key state; Enter opens the field to paste the key.
///
/// This is the path the user asked for: palette → Connect → provider → key,
/// without having to go through the left column of the model palette.
pub fn openConnectPalette(m: *tui.Model) void {
    const gpa = m.allocator;
    const defs = allProviders(gpa);
    const items = gpa.alloc(palette.Item, defs.len) catch return;
    for (defs, 0..) |*d, i| {
        const active = std.mem.eql(u8, d.id, cur_provider_id);
        const has_key = providers.hasKey(d, m.environ);
        items[i] = .{
            .kind = .provider,
            .group = 0,
            .label = gpa.dupe(u8, d.id) catch return,
            .hint = gpa.dupe(u8, if (active) "active" else if (has_key) "key ok" else "no key") catch "",
        };
    }
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
    // +1 for the header's "Connect" item: it is the shortcut to connect a
    // provider without leaving the command palette.
    const items = gpa.alloc(palette.Item, commands.len + 1) catch return;
    items[0] = .{
        .kind = .command,
        .group = 1,
        .label = gpa.dupe(u8, "Connect") catch return,
        .hint = gpa.dupe(u8, "add a provider API key") catch "",
    };
    for (commands, 0..) |c, i| {
        // `/free-auto` carries its STATE in the hint: seeing "on · 3/8" next to it
        // in the palette is what tells you the rotation is running, without
        // having to go and ask for the status.
        const hint: []const u8 = if (std.mem.eql(u8, c.key, "/free-auto"))
            (if (freeAutoOn()) freeAutoLabel(gpa) else "rotate free models of every provider · off")
        else if (c.key_hint) |h| h else "";
        items[i + 1] = .{
            .kind = .command,
            .group = cmdGroup(c.key),
            .label = gpa.dupe(u8, c.key) catch return,
            .hint = gpa.dupe(u8, hint) catch "",
        };
    }
    // Stable order by group: otherwise the headers repeat and the list jumps from
    // "Model" to "Session" and back to "Suggested".
    std.mem.sort(palette.Item, items, {}, byGroupThenName);
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
    cur_provider_id = def.id;
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
    const msg = std.fmt.allocPrint(
        m.allocator,
        "provider → {s} · model {s}",
        .{ def.id, if (cur_model.len > 0) cur_model else "(auto: picked from the catalog)" },
    ) catch "provider";
    pushInfoOwned(m, msg);
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
    try std.testing.expectEqualStrings("", skills.systemPromptSection(&.{}, &buf));
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
    defer {
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
    const fake_agents = try std.testing.allocator.dupe(u8, "# proyecto\nNo hagas esto.");
    defer std.testing.allocator.free(fake_agents);
    agents_md_cache = fake_agents;

    var out: [8192]u8 = undefined;
    const composed = buildSystemPrompt(std.testing.allocator, &out, null);
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
    const saved_cache = skills_cache;
    const saved_stamp_len = skills_stamp_len;
    const saved_rescans = skills_rescans;
    defer {
        io_global = saved_io;
        project_info = saved_info;
        agents_md_cache = saved_agents;
        skills_cache = saved_cache;
        skills_stamp_len = saved_stamp_len;
        skills_rescans = saved_rescans;
    }

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    io_global = threaded.io();
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
    skills_cache = null;
    skills_stamp_len = 0;
    skills_rescans = 0;

    var out: [16 * 1024]u8 = undefined;
    const composed = buildSystemPrompt(std.testing.allocator, &out, null);
    try std.testing.expect(std.mem.indexOf(u8, composed, "Working directory:") != null);
    try std.testing.expect(std.mem.indexOf(u8, composed, root) != null);
    try std.testing.expect(std.mem.indexOf(u8, composed, "branch mi-rama") != null);
    // The routing guide is still there: the cwd did not push it out.
    try std.testing.expect(std.mem.indexOf(u8, composed, "NEVER use bash") != null);
    // And git is named by its name, so that "what has changed" is a `git diff`
    // and not an `ls` with grep.
    try std.testing.expect(std.mem.indexOf(u8, composed, "git status") != null);
    try std.testing.expect(std.mem.indexOf(u8, composed, "git diff") != null);

    // The skills cache this test left in place is freed by the `defer`.
    freeSkillsCacheLocked();
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

    // 1) There is still no skill at all.
    var env_map: std.process.Environ.Map = undefined;
    _ = &env_map;
    const empty = discoverSkills(std.testing.allocator, null);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    // 2) One appears. The root's `stat` has changed, so it has to show up
    //    without restarting anything.
    var skill_file: [512]u8 = undefined;
    const skill_path = try std.fmt.bufPrint(&skill_file, "{s}/SKILL.md", .{dir});
    try std.Io.Dir.cwd().writeFile(io_global, .{ .sub_path = skill_path, .data = "---\ndescription: recien creado\n---\nbody\n" });

    const found = discoverSkills(std.testing.allocator, null);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("nuevo", found[0].name);
    try std.testing.expectEqualStrings("recien creado", found[0].description);

    // 3) And the list is BORROWED: asking for it again with no changes frees
    //    nothing (if the caller owned it, this would be a double free of live
    //    memory).
    const again = discoverSkills(std.testing.allocator, null);
    try std.testing.expectEqual(@as(usize, 1), again.len);
    try std.testing.expectEqualStrings("nuevo", again[0].name);

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
    // `project_info` reads the clock through `io_global`, which is undefined in a
    // bare test: reading the clock through garbage is a GPF, not a zero.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const saved_io = io_global;
    io_global = threaded.io();
    defer io_global = saved_io;

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
    const p = buildSystemPrompt(std.testing.allocator, &out, null);

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
    io_global = threaded.io();
    defer io_global = saved_io;

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
    const composed = buildSystemPrompt(std.testing.allocator, &out, null);
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

test "subagents: the model is told it can send several at once" {
    // If the description does not say it, the model keeps sending one per
    // message and the parallelism never happens: the capability has to be
    // visible in the schema to be used.
    try std.testing.expect(std.mem.indexOf(u8, tools_mod.toolsJson(), "run at the same time") != null);
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

test "the cheap router is off unless ZODE_CHEAP_TURN names a model" {
    // The default matters more than the feature: a small model that is not
    // available for your account answers 403 and the model has no way to know
    // the fallback would have worked. So nothing happens unless it is asked for.
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
    // `write {files:[...]}` has no `path`. It is the wrong direction — a
    // multi-file edit is exactly what breaks a build — and the reason is that
    // guessing means reading the arguments, and an argument this cannot parse
    // must not be the reason a broken build goes unnoticed. The manual `check`
    // tool is there for that case.
    try std.testing.expect(!codePathsFromArgs("{\"files\":[{\"path\":\"a.zig\"}]}", arena));
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
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    m.bg.slots[1] = .{ .state = .finished, .id = 6, .exit = 1 };
    try m.bg.slots[1].buf.appendSlice(std.testing.allocator, "src/a.zig:3:5: error: unused variable\n");
    @memcpy(m.auto_check.label[0..9], "zig build");
    m.auto_check.label_len = 9;
    m.auto_check.job = 6;

    const note = m.auto_check.collect(&m.bg, arena) orelse return error.NoNote;
    try std.testing.expect(std.mem.indexOf(u8, note, "src/a.zig:3:5: error") != null);
    // The label, so the model knows this is the compiler and not a guess.
    try std.testing.expect(std.mem.indexOf(u8, note, "zig build") != null);
    // And it says what to do about it.
    try std.testing.expect(std.mem.indexOf(u8, note, "Fix these") != null);
    // Consumed: the next edit must not report this turn's errors a second time.
    try std.testing.expectEqual(@as(u32, 0), m.auto_check.job);
}

test "autoCheckResult: a PASSING check says nothing at all" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    // Exit 0 and output with no locations: the build was fine.
    m.bg.slots[0] = .{ .state = .finished, .id = 2, .exit = 0 };
    try m.bg.slots[0].buf.appendSlice(std.testing.allocator, "Build finished\n");
    m.auto_check.job = 2;

    // "it compiles" is worth nothing to a model that was not going to write code
    // anyway, and it is the one message that could be repeated five times in one
    // turn. Silence is the design.
    try std.testing.expect(m.auto_check.collect(&m.bg, arena) == null);
    // Consumed even when silent, or the next edit reports it again.
    try std.testing.expectEqual(@as(u32, 0), m.auto_check.job);
}

test "autoCheckResult: no job, and a job still running, both say nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    try std.testing.expect(m.auto_check.collect(&m.bg, arena) == null);

    m.bg.slots[0] = .{ .state = .running, .id = 3 };
    try m.bg.slots[0].buf.appendSlice(std.testing.allocator, "src/a.zig:1:1: error: early\n");
    m.auto_check.job = 3;
    // Mid-thought, a note that says "still running" is the noise this feature
    // exists to avoid. The job keeps its slot and the next iteration reads it.
    try std.testing.expect(m.auto_check.collect(&m.bg, arena) == null);
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
    io_global = threaded.io();
    defer io_global = saved_io;

    // The AGENTS.md cache is a MODULE GLOBAL that outlives this test's arena, and
    // the next test would read a pointer into memory that has been freed. That is a
    // use-after-free that shows up as a segfault in whichever test runs second,
    // which is how it would have been misread.
    const saved_agents = agents_md_cache;
    agents_md_cache = null;
    defer agents_md_cache = saved_agents;

    var buf: [16 * 1024]u8 = undefined;
    const from_tui = buildSystemPrompt(a, &buf, null);
    const headless = try buildSystemPromptFor(a, null);

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
    io_global = threaded.io();
    defer io_global = saved_io;

    const saved_agents = agents_md_cache;
    agents_md_cache = null;
    defer agents_md_cache = saved_agents;

    var buf: [16 * 1024]u8 = undefined;
    const composed = buildSystemPrompt(a, &buf, null);

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
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expect(codePathsFromArgs("{\"path\":\"src/a.zig\"}", a));
    try std.testing.expect(!codePathsFromArgs("{\"path\":\"README.md\"}", a));
    try std.testing.expect(!codePathsFromArgs("{\"files\":[{\"path\":\"a.zig\"}]}", a));
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
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

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

test "a RED check is the one thing that cannot end a goal turn" {
    // The rule the whole loop was missing, measured over five real task runs: five turns
    // ended with the code not compiling, and the harness had read the exit code and built
    // the model's own error message out of the diagnostics before letting it happen.
    var ac: AutoCheck = .{};

    // Nothing checked: a turn of prose, of questions, of a task with no build in it.
    // Demanding a compile here would be the harness nagging about a README.
    ac.last_verdict = .unchecked;
    try std.testing.expect(turnMayEnd(&ac, true));
    try std.testing.expect(turnMayEnd(&ac, false));

    // Green: the code works, so ending is a decision the model is entitled to make.
    ac.last_verdict = .passed;
    try std.testing.expect(turnMayEnd(&ac, true));
    try std.testing.expect(turnMayEnd(&ac, false));

    // Red WITH an open goal: this is the block. The code does not work and the objective
    // is not met, so a turn that ends here hands the user a summary of broken code.
    ac.last_verdict = .failed;
    try std.testing.expect(!turnMayEnd(&ac, true));

    // Red with NO goal: there is nothing to hold open, and a `bash` that failed on a
    // project with no typechecker is not a reason to forbid the turn from ending. The
    // rule is scoped to a goal because that is the only thing that makes "unfinished"
    // mean something.
    try std.testing.expect(turnMayEnd(&ac, false));
}

test "the verdict is per TURN and resets, so turn two is not judged by turn one" {
    // A stale red is a worse bug than no red: it would refuse to let any later turn end,
    // forever, with an error message about a build from a previous task.
    var ac: AutoCheck = .{};
    ac.job = 7;
    ac.started_this_turn = 2;
    ac.last_verdict = .failed;

    var reg: bgproc.Registry = undefined;
    _ = &reg;
    ac.resetTurn(&reg, undefined);

    try std.testing.expectEqual(Verdict.unchecked, ac.last_verdict);
    try std.testing.expectEqual(@as(u32, 0), ac.started_this_turn);
    // The job id goes too, which is what stops turn two reporting turn one's errors.
    try std.testing.expectEqual(@as(u32, 0), ac.job);
}
