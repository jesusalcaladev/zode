/// System prompt composition and prompt-related caches extracted from `agent.zig`.
const std = @import("std");
const goal_mod = @import("../lib/goal.zig");
const session_mod = @import("../session.zig");
const agentsdoc = @import("../lib/agentsdoc.zig");
const cache_stats = @import("../cache_stats.zig");
const prompt_mod = @import("../lib/prompt.zig");
const cachebreak = @import("../lib/cachebreak.zig");
const compaction = @import("../compaction.zig");
const skills = @import("../lib/skills.zig");
const outputstyles = @import("../lib/outputstyles.zig");
const ask = @import("../lib/ask.zig");
const discovery = @import("discovery.zig");

pub const default_system_prompt = prompt_mod.default_system_prompt;
pub const default_system_prompt_core = prompt_mod.default_system_prompt_core;
pub const coding_rules = prompt_mod.coding_rules;
pub const tool_routing_prompt = prompt_mod.tool_routing_prompt;
pub const verification_prompt = prompt_mod.verification_prompt;

pub var agents_md_cache: ?[]u8 = null;
var cache_break_prev: ?[8]u64 = null;
var cache_break_last_block: ?[]const u8 = null;
var cache_break_last_pos: usize = 0;

pub fn resetCacheBreak() void {
    cache_break_prev = null;
    cache_break_last_block = null;
    cache_break_last_pos = 0;
}

pub fn cacheBreakUnstable() bool {
    return cache_stats.session.writesPerRequest() > 0.5;
}

pub fn cacheBreakLastBlock() ?[]const u8 { return cache_break_last_block; }
pub fn cacheBreakLastPos() usize { return cache_break_last_pos; }
pub fn cacheBreakPrev() ?[8]u64 { return cache_break_prev; }
pub fn setCacheBreakPrev(prev: [8]u64) void { cache_break_prev = prev; }
pub fn clearCacheBreakLast() void {
    cache_break_last_block = null;
    cache_break_last_pos = 0;
}
pub fn noteCacheBreak(block: ?[]const u8, pos: usize) void {
    cache_break_last_block = block;
    cache_break_last_pos = pos;
}

pub fn forgetAgentsCache(a: std.mem.Allocator) void {
    if (agents_md_cache) |c| {
        a.free(c);
        agents_md_cache = null;
    }
}

pub fn systemPromptBase(gpa: std.mem.Allocator, io: std.Io, project_root: ?[]const u8) []const u8 {
    if (agents_md_cache == null) {
        agents_md_cache = readAgentsIn(gpa, io, ".") orelse readAgentsIn(gpa, io, project_root) orelse null;
    }
    if (agents_md_cache) |c| return c;
    return prompt_mod.default_system_prompt;
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
    return skills.systemPromptSection(filtered.items, skillListingBudget(ctx), list_buf);
}

pub fn buildSystemPrompt(ctx: BuildCtx, out: []u8, include_skills: bool) []const u8 {
    clearCacheBreakLast();
    const base = systemPromptBase(ctx.gpa, ctx.io, ctx.project_root);

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
    const composed = std.fmt.bufPrint(out, "{s}\n{s}\n{s}{s}{s}{s}\n{s}{s}", .{
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
