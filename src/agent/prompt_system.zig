/// System prompt composition and prompt-related caches extracted from `agent.zig`.
const std = @import("std");
const goal_mod = @import("../lib/goal.zig");
const session_mod = @import("../session.zig");
const agentsdoc = @import("../lib/agentsdoc.zig");
const instructions = @import("../lib/instructions.zig");
const cache_stats = @import("../cache_stats.zig");
const prompt_mod = @import("../lib/prompt.zig");
const cachebreak = @import("../lib/cachebreak.zig");
const compaction = @import("../compaction.zig");
const skills = @import("../lib/skills.zig");
const plugins_mod = @import("../lib/plugins.zig");
const pluginstore = @import("../lib/pluginstore.zig");
const outputstyles = @import("../lib/outputstyles.zig");
const ask = @import("../lib/ask.zig");
const discovery = @import("discovery.zig");

pub const default_system_prompt = prompt_mod.default_system_prompt;
pub const default_system_prompt_core = prompt_mod.default_system_prompt_core;
pub const coding_rules = prompt_mod.coding_rules;
pub const tool_routing_prompt = prompt_mod.tool_routing_prompt;
pub const verification_prompt = prompt_mod.verification_prompt;

pub var agents_md_cache: ?[]u8 = null;
/// 50.8: caller-supplied instructions appended to the system prompt. NEVER
/// read from the project directory — that would let a repo change its own
/// rules without the user seeing them. Set only by the CLI flag.
var append_prompt: []const u8 = "";
var append_full_cache: ?[]u8 = null;

pub fn setAppendSystemPrompt(a: std.mem.Allocator, text: []const u8) void {
    if (append_full_cache) |c| a.free(c);
    append_full_cache = null;
    append_prompt = text;
}
var cache_break_prev: ?[8]u64 = null;
var cache_break_last_block: ?[]const u8 = null;
var cache_break_last_pos: usize = 0;

/// Phase 8: a bounded history of prefix breaks, so `/cache` can answer not
/// only "what broke" but "how many times". Fixed-size, no allocator — a break
/// is rare and the last 8 are more than enough to explain a bad hit-rate.
pub const Break = struct { block: []const u8, pos: usize };
pub const max_breaks: usize = 8;
var cache_break_history: [max_breaks]Break = undefined;
var cache_break_count: usize = 0;

pub fn resetCacheBreak() void {
    cache_break_prev = null;
    cache_break_last_block = null;
    cache_break_last_pos = 0;
    cache_break_count = 0;
}

pub fn cacheBreakUnstable() bool {
    return cache_stats.session.writesPerRequest() > 0.5;
}

pub fn cacheBreakLastBlock() ?[]const u8 { return cache_break_last_block; }
pub fn cacheBreakLastPos() usize { return cache_break_last_pos; }
pub fn cacheBreakPrev() ?[8]u64 { return cache_break_prev; }
pub fn breakCount() usize { return cache_break_count; }
pub fn breakAt(i: usize) ?Break {
    return if (i < cache_break_count) cache_break_history[i] else null;
}
pub fn setCacheBreakPrev(prev: [8]u64) void { cache_break_prev = prev; }
pub fn clearCacheBreakLast() void {
    cache_break_last_block = null;
    cache_break_last_pos = 0;
}
pub fn noteCacheBreak(block: ?[]const u8, pos: usize) void {
    cache_break_last_block = block;
    cache_break_last_pos = pos;
    if (block) |b| {
        if (cache_break_count < max_breaks) {
            cache_break_history[cache_break_count] = .{ .block = b, .pos = pos };
            cache_break_count += 1;
        }
    }
}

pub fn forgetAgentsCache(a: std.mem.Allocator) void {
    if (agents_md_cache) |c| {
        a.free(c);
        agents_md_cache = null;
    }
}

pub fn systemPromptBase(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, project_root: ?[]const u8) []const u8 {
    if (agents_md_cache == null) {
        agents_md_cache = instructions.loadAll(gpa, io, env, ".", project_root) catch null;
    }
    const base = if (agents_md_cache) |c| c else prompt_mod.default_system_prompt;
    if (append_prompt.len == 0) return base;
    if (append_full_cache == null) {
        append_full_cache = std.fmt.allocPrint(gpa, "{s}\n\n## Additional instructions\n{s}", .{
            base,
            append_prompt,
        }) catch null;
    }
    return append_full_cache orelse base;
}

pub fn readAgentsIn(gpa: std.mem.Allocator, io: std.Io, dir: ?[]const u8) ?[]u8 {
    if (dir) |d| {
        if (readAgentsAt(gpa, io, d, "AGENTS.md")) |t| return t;
        return readAgentsAt(gpa, io, d, "CLAUDE.md");
    }
    return null;
}

fn readAgentsAt(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8) ?[]u8 {
    return agentsdoc.readExpandedAt(gpa, io, dir, name);
}

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

pub const BuildCtx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cache_gpa: std.mem.Allocator,
    env: ?*const std.process.Environ.Map,
    env_fallback: ?*const std.process.Environ.Map,
    project_cwd: []const u8,
    project_root: ?[]const u8,
    location: []const u8,
    read_only: bool,
    accept_edits: bool,
    yolo: bool,
    current_style: ?[]const u8,
};

pub fn skillListingBudget(ctx: BuildCtx) usize {
    const e = ctx.env orelse ctx.env_fallback;
    return skills.budgetCharsFor(compaction.contextLimitFor(e, 0));
}

pub fn skillsSectionText(ctx: BuildCtx, list_buf: []u8) []const u8 {
    const entries = discovery.discoverSkills(ctx.gpa, ctx.io, ctx.env, ctx.cache_gpa, ctx.project_cwd, ctx.project_root);
    var filtered: std.ArrayList(skills.Entry) = .empty;
    blk: for (entries) |e| {
        if (skills.skillAppliesHere(e, ctx.project_root)) {
            if (filtered.append(ctx.gpa, e)) |_| {} else |err| switch (err) {
                error.OutOfMemory => break :blk,
            }
        }
    }
    defer filtered.deinit(ctx.gpa);
    const base = skills.systemPromptSection(filtered.items, skillListingBudget(ctx), list_buf);

    // Phase 13.1: enabled plugins contribute instructions. They are appended
    // to the SAME skills block so the eight-block cache prefix does not move —
    // a plugin install must not invalidate every cached request.
    const installed = pluginstore.discoverCached(ctx.gpa, ctx.io, ctx.env, ctx.project_root orelse ctx.project_cwd) catch &.{};
    // Cached by pluginstore; invalidate() owns the memory.
    if (installed.len == 0) return base;
    var manifests: [pluginstore.max_installed]plugins_mod.Manifest = undefined;
    var n: usize = 0;
    for (installed) |it| {
        if (n >= manifests.len) break;
        manifests[n] = it.manifest;
        n += 1;
    }
    const extra = plugins_mod.renderPromptSection(ctx.gpa, manifests[0..n], 4096) catch return base;
    defer ctx.gpa.free(extra);
    if (extra.len == 0 or base.len + extra.len > list_buf.len) return base;
    @memcpy(list_buf[base.len .. base.len + extra.len], extra);
    return list_buf[0 .. base.len + extra.len];
}

pub fn buildSystemPrompt(ctx: BuildCtx, out: []u8, include_skills: bool) []const u8 {
    clearCacheBreakLast();
    const base = systemPromptBase(ctx.gpa, ctx.io, ctx.env, ctx.project_root);

    var list_buf: [16 * 1024]u8 = undefined;
    const section = if (include_skills) skillsSectionText(ctx, &list_buf) else "";

    const style_entries = discovery.discoverStyles(ctx.gpa, ctx.io, ctx.env, ctx.cache_gpa, ctx.project_cwd, ctx.project_root);
    var style_entry: ?outputstyles.Entry = null;
    if (ctx.current_style) |name| {
        for (style_entries) |e| {
            if (std.mem.eql(u8, e.name, name)) {
                style_entry = e;
                break;
            }
        }
    }
    const effective_base: []const u8 = if (style_entry) |s| (if (!s.keep_coding_instructions) prompt_mod.default_system_prompt_core else base) else base;

    const routing = tool_routing_prompt;
    const mode_note: []const u8 = if (ctx.read_only)
        "PLAN MODE is on (shift+tab to cycle; it is read-only): you may READ anything, but write/edit/bash/rename and the git mutations (add/commit/stash/branch) come back with an error and must NOT be retried. Investigate first, then write the IMPLEMENTATION PLAN with the `todo` tool — concrete steps, one per line. Zode displays the complete numbered checklist in the scrollable history; end your turn so the user can review and approve it. On approval zode switches itself to Build mode and tells you to implement; if they ask for changes, revise the plan with `todo` and end the turn again to present it. If the user only asked a question and no change is needed, just answer it.\n\n"
    else if (ctx.accept_edits)
        "ACCEPT-EDITS MODE is on (shift+tab to cycle): file edits (write, edit, rename) run without asking, but bash still asks for permission. Ask the user with `ask` before running anything destructive.\n\n"
    else if (ctx.yolo)
        "YOLO MODE is on (shift+tab or /mode to cycle): nothing asks for permission, and your `ask` questions are NOT shown to anyone — the harness takes your own recommendation (the FIRST option) or leaves the question OPEN. Either way, MENTION it in your final summary: what you decided, or what question is still open for the user. An unmentioned decision is a decision the user cannot check.\n\n"
    else
        "";

    const blocks_len = routing.len + verification_prompt.len + ask.guidance.len +
        section.len + ctx.location.len + mode_note.len;
    var style_buf: [8 * 1024]u8 = undefined;
    const style_block: []const u8 = if (style_entry) |s|
        outputstyles.formatStyle(s.name, s.description, if (s.body) |b| b else "", &style_buf)
    else
        "";
    const blocks = cachebreak.Blocks{
        .base = effective_base,
        .routing = routing,
        .verification = verification_prompt,
        .ask_guidance = ask.guidance,
        .skills = section,
        .location = ctx.location,
        .mode_note = mode_note,
        .style = style_block,
    };
    var hashes: [8]u64 = undefined;
    for (&[_][]const u8{
        blocks.base,   blocks.routing,  blocks.verification, blocks.ask_guidance,
        blocks.skills, blocks.location, blocks.mode_note,    blocks.style,
    }, 0..) |block, i| {
        hashes[i] = cachebreak.hashBlock(block);
    }
    if (cacheBreakPrev()) |prev| {
        const offs = cachebreak.blockOffsets(&blocks);
        for (prev, 0..) |ph, i| {
            if (ph != hashes[i]) {
                noteCacheBreak(cachebreak.block_names[i], offs[i]);
                break;
            }
        }
    }
    setCacheBreakPrev(hashes);
    const composed = std.mem.print(out, "{s}\n{s}\n{s}{s}{s}{s}\n{s}{s}", .{
        effective_base,
        routing,
        verification_prompt,
        ask.guidance,
        section,
        ctx.location,
        mode_note,
        style_block,
    }) catch blk: {
        const note_lead = "[the project instructions above were truncated to fit";
        const note_tail = "; the rest is in the project's instruction file]";
        const overhead = note_lead.len + note_tail.len + 48;
        if (out.len <= blocks_len + overhead) break :blk routing;
        const room = out.len - blocks_len - overhead;
        const fit = prompt_mod.fitPrefix(effective_base, room);
        break :blk std.mem.print(
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
                ctx.location,
                mode_note,
                style_block,
            },
        ) catch routing;
    };
    return composed;
}

pub fn buildSystemPromptFor(ctx: BuildCtx) ![]u8 {
    var buf: [16 * 1024]u8 = undefined;
    return ctx.gpa.dupe(u8, buildSystemPrompt(ctx, &buf, true));
}

pub fn syncSystemPrompt(s: *session_mod.Session, ctx: BuildCtx) void {
    var buf: [16 * 1024]u8 = undefined;
    const want = buildSystemPrompt(ctx, &buf, true);
    for (s.messages.items) |m| {
        if (m.role != .system) continue;
        if (std.mem.eql(u8, m.content, want)) return;
        break;
    }
    _ = s.replaceSystem(want) catch {};
}

// ── Phase 8: cache-break history tests ──────────────────────────

test "append-system-prompt: the caller's text appears once in the base" {
    const a = std.testing.allocator;
    const saved = append_full_cache;
    const saved_text = append_prompt;
    const saved_agents = agents_md_cache;
    defer {
        if (append_full_cache) |c| a.free(c);
        append_full_cache = saved;
        append_prompt = saved_text;
        if (agents_md_cache) |c| a.free(c);
        agents_md_cache = saved_agents;
    }
    setAppendSystemPrompt(a, "Always answer with a checklist.");
    const base = systemPromptBase(a, std.testing.io, null, null);
    try std.testing.expect(std.mem.indexOf(u8, base, "Always answer with a checklist.") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, base, "Always answer with a checklist."));
    // Cached: a second call returns the SAME bytes, not a second append.
    try std.testing.expectEqualStrings(base, systemPromptBase(a, std.testing.io, null, null));
}

test "cachebreak: history records breaks in order and is bounded" {
    resetCacheBreak();
    try std.testing.expectEqual(@as(usize, 0), breakCount());
    noteCacheBreak("skills", 123);
    noteCacheBreak("style", 456);
    try std.testing.expectEqual(@as(usize, 2), breakCount());
    try std.testing.expectEqualStrings("skills", breakAt(0).?.block);
    try std.testing.expectEqual(@as(usize, 123), breakAt(0).?.pos);
    try std.testing.expectEqualStrings("style", breakAt(1).?.block);
    try std.testing.expect(breakAt(2) == null);
    // Bounded: more breaks than the cap keep the first `max_breaks`.
    for (0..max_breaks + 4) |i| {
        noteCacheBreak("base", i);
    }
    try std.testing.expectEqual(@as(usize, max_breaks), breakCount());
    resetCacheBreak();
    try std.testing.expectEqual(@as(usize, 0), breakCount());
}

test "cachebreak: a null block is not recorded (no false break)" {
    resetCacheBreak();
    noteCacheBreak(null, 0);
    try std.testing.expectEqual(@as(usize, 0), breakCount());
    try std.testing.expect(cacheBreakLastBlock() == null);
    resetCacheBreak();
}

test "plugins: an installed plugin contributes its instructions to the skills block" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const installed = try pluginstore.install(a, std.testing.io, root, "review-checklist");
    defer a.free(installed);
    discovery.resetSkillsCacheForTest();

    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    var buf: [64 * 1024]u8 = undefined;
    const ctx = BuildCtx{
        .gpa = a,
        .io = std.testing.io,
        .cache_gpa = a,
        .env = &env,
        .env_fallback = null,
        .project_cwd = root,
        .project_root = root,
        .location = "test",
        .read_only = false,
        .accept_edits = true,
        .yolo = false,
        .current_style = null,
    };
    const section = skillsSectionText(ctx, &buf);
    try std.testing.expect(std.mem.indexOf(u8, section, "SEVERITY: high|medium|low") != null);
    discovery.resetSkillsCacheForTest();
}
