const std = @import("std");
const tui = @import("tui.zig");
const agent = @import("agent.zig");
const cache_stats = @import("cache_stats.zig");
const compaction = @import("compaction.zig");
const goal_mod = @import("lib/goal.zig");
const providers = @import("lib/providers.zig");
const chat = @import("chat.zig");
const mascot = @import("lib/mascot.zig");

/// The `/…` commands and the two tables `/help` prints.
///
/// ## Why `submit` is NOT here
///
/// `agent.zig` keeps `submit`, which is the one function that decides whether a
/// line of input is a command or a chat. It has to be the caller, because a chat
/// starts a worker and a command runs here on the UI thread, and because it is
/// what the TUI calls. Everything below it is local work that has no reason to
/// live next to the agent loop.
///
/// The edge only goes one way: this file imports `agent.zig` for the shared
/// helpers (`agent.pushInfo*`, `agent.applyModel`, the cache numbers) and `agent.zig` calls
/// into here. A file that both imported the other would be a cycle, and the way
/// out of that is not a `usingnamespace`, it is deciding which side owns the
/// entry point.
/// `/help`: commands (with their shortcut) and then the bare shortcuts.
///
/// Two blocks because they answer two different questions: "what can I type"
/// and "what can I press". Before this there was only the first one, and only
/// without the shortcut column, so half the keybindings were written down
/// nowhere — you find them by hitting Ctrl+P and hoping.
pub fn cmdHelp(m: *tui.Model) void {
    const gpa = m.allocator;
    agent.pushInfoOwned(m, gpa.dupe(u8, "commands") catch return);
    for (commands) |c| {
        const line = if (c.key_hint) |h|
            std.fmt.allocPrint(gpa, "{s: <14} {s}  ({s})", .{ c.key, c.desc, h }) catch continue
        else
            std.fmt.allocPrint(gpa, "{s: <14} {s}", .{ c.key, c.desc }) catch continue;
        agent.pushInfoOwned(m, line);
    }

    agent.pushInfoOwned(m, gpa.dupe(u8, "shortcuts") catch return);
    for (shortcuts) |s| {
        const line = std.fmt.allocPrint(gpa, "{s: <18} {s}", .{ s.key, s.desc }) catch continue;
        agent.pushInfoOwned(m, line);
    }
}

/// `/allowlist`: which tools are in "always allow".
/// The allowlist lives in `~/.config/zode/permissions.json` and there was no
/// way to see it: if a tool stopped asking and you did not know why, the only
/// way was to open the file by hand. It also says whether `/agent.yolo` is on, which
/// is the other way of "don't ask me".
pub fn cmdAllowlist(m: *tui.Model) void {
    var line_buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&line_buf);
    w.writeAll("mode: ") catch {};
    w.writeAll(agent.permModeName()) catch {};
    w.writeAll("  \u{b7} always allowed: ") catch {};
    var n: usize = 0;
    for (agent.always_lens, 0..) |l, i| {
        if (l == 0) continue;
        if (n > 0) w.writeAll(" \u{b7} ") catch {};
        w.writeAll(agent.always_names[i][0..l]) catch {};
        n += 1;
    }
    if (n == 0) w.writeAll("(none)") catch {};
    // The bash command prefixes: the other half of selective
    // permissions, the commands that run without a dialog.
    var np: usize = 0;
    w.writeAll("  \u{b7} bash: ") catch {};
    for (agent.bash_pattern_lens, 0..) |l, i| {
        if (l == 0) continue;
        if (np > 0) w.writeAll(" \u{b7} ") catch {};
        w.writeAll(agent.bash_pattern_bufs[i][0..l]) catch {};
        np += 1;
    }
    if (np == 0) w.writeAll("(none)") catch {};
    const msg = std.fmt.allocPrint(
        m.allocator,
        "{s}",
        .{w.buffered()},
    ) catch return;
    agent.pushInfoOwned(m, msg);
}

/// `/cache`: prompt cache hit-rate of the session.
pub fn cmdCache(m: *tui.Model) void {
    const st = &cache_stats.session;
    const line = std.fmt.allocPrint(
        m.allocator,
        // WRITES are in the line because they are the expensive half: a high
        // hit-rate with a write on EVERY request means the prefix is being
        // rebuilt each turn, and no hit-rate alone can reveal that.
        "cache [{s}] {d:.1}% hit-rate · {d} reqs with hit · {d} prompt / {d} cached / {d} written · {d} completion",
        .{ agent.cur_provider_id, st.hitRatePct(), st.cache_hits, st.prompt_tokens, st.cached_tokens, st.cache_write_tokens, st.completion_tokens },
    ) catch "cache";
    agent.pushInfoOwned(m, line);

    // WHY, because a rate with no cause is not actionable. The number alone was
    // 0.0% on a perfectly healthy setup for weeks.
    //
    // The evidence is the prompt count going DOWN: a conversation only grows, so a
    // smaller count for the same conversation means a different tokenizer, which
    // means a different upstream, which means a router. It is NOT the count
    // growing: a real run went 3611 -> 66946 on a FIXED model while reading three
    // files, and calling that a router was the first version's bug.
    switch (st.verdict()) {
        .unknown => m.pushInfoFmt(
            "not enough requests to say anything yet ({d} so far). The first request of a turn never hits and the prompt count grows with the conversation: neither is a problem.",
            .{st.requests},
        ),
        .healthy => m.pushInfoFmt(
            "healthy: {d} request(s), {d} served from cache, and the prompt count only ever went up ({d} shrink(s)).",
            .{ st.requests, st.cached_tokens, st.prompt_shrinks },
        ),
        .provider_uncached => m.pushInfoFmt(
            "the prompt count only goes up ({d} shrink(s)), so the prefix is fine, and this provider is not serving any of it from cache after {d} requests. Measured on cohere/north-mini-code:free, which answers 0 every time; a fixed model on openrouter reaches 98%.",
            .{ st.unexplained_shrinks, st.requests },
        ),
        .routing => m.pushInfoFmt(
            "THE MODEL IS A ROUTER: the prompt count went DOWN {d} time(s) with nothing removed from the conversation. Measured 2026-10-04, same prefix three times: openrouter/free 3583/3273/3381 (0% cached), a fixed model 3611/3613/3613 (98%). Routers do not share a prompt cache, so no prefix arrangement can make one hit. /model and pick a model, not a router.",
            .{st.prompt_shrinks},
        ),
    }
}

/// `/compact [off|elide|full|default]`: what automatic compaction is allowed to do.
///
/// With no argument it REPORTS, which is the point: a policy nobody can see is a
/// policy nobody can trust, and "why did it summarize that" has to have an answer
/// that does not involve reading the source.
///
/// `default` clears the override and goes back to `ZODE_COMPACT`, because an
/// override that cannot be cleared is a value somebody set once and forgot.
pub fn cmdCompact(m: *tui.Model, arg: []const u8) void {
    if (arg.len == 0) {
        const eff = compaction.effectiveMode(m.environ, m.compact_mode);
        const pct = compaction.targetPct(m.environ);
        const from_env = if (m.compact_mode == null) "from ZODE_COMPACT" else "overridden here";
        const line = std.fmt.allocPrint(
            m.allocator,
            "compaction: {s} · threshold {d}% ({s}) · limit {d} → budget {d} tokens",
            .{ @tagName(eff), pct, from_env, compaction.contextLimitFor(m.environ, agent.curModelContext()), compaction.budgetFor(m.environ, agent.curModelContext()) },
        ) catch "compaction";
        agent.pushInfoOwned(m, line);
        const detail = std.fmt.allocPrint(
            m.allocator,
            // The RANGE, not the value: this printed `ZODE_COMPACT_PCT=10%` next to
            // "threshold 42%", because 10 is the clamp's floor, and two numbers that
            // both look like the setting are worse than none.
            "  {s} · ZODE_COMPACT_PCT accepts {d}..{d} · ZODE_COMPACT=off|elide|full",
            .{ compaction.describe(eff), compaction.min_target_pct, compaction.max_target_pct },
        ) catch "compaction";
        agent.pushInfoOwned(m, detail);
        return;
    }

    if (std.ascii.eqlIgnoreCase(arg, "default") or std.ascii.eqlIgnoreCase(arg, "env")) {
        m.compact_mode = null;
        const eff = compaction.effectiveMode(m.environ, null);
        const line = std.fmt.allocPrint(m.allocator, "compaction: following ZODE_COMPACT again ({s})", .{@tagName(eff)}) catch "compaction";
        agent.pushInfoOwned(m, line);
        return;
    }

    // The SAME parser as the env var, so a typo is answered the same way in both
    // places: with what it does and what it would have to be, not with "unknown".
    const chosen: compaction.Mode = blk: {
        if (std.ascii.eqlIgnoreCase(arg, "off") or std.ascii.eqlIgnoreCase(arg, "never")) break :blk .off;
        if (std.ascii.eqlIgnoreCase(arg, "elide") or std.ascii.eqlIgnoreCase(arg, "tier1")) break :blk .elide;
        if (std.ascii.eqlIgnoreCase(arg, "full") or std.ascii.eqlIgnoreCase(arg, "on")) break :blk .full;
        const line = std.fmt.allocPrint(
            m.allocator,
            "unknown compaction mode '{s}': use off | elide | full | default (off = never compact, elide = free tier only, full = also summarize)",
            .{arg},
        ) catch "unknown compaction mode";
        agent.pushInfoOwned(m, line);
        return;
    };
    m.compact_mode = chosen;
    const line = std.fmt.allocPrint(
        m.allocator,
        "compaction: {s} ({s})",
        .{ @tagName(chosen), compaction.describe(chosen) },
    ) catch "compaction";
    agent.pushInfoOwned(m, line);
}

/// `/goal [text|clear]`: the objective of this turn, which the turn may not stop
/// short of.
///
/// With text it sets the objective and sends nothing: the next thing you type is the
/// task, and it is worked with the objective attached. That ordering is deliberate.
/// `/goal` on its own would have to invent a task, and a prompt like "make the package
/// weigh under 10 KB" alone is not yet a task — it is a goal.
///
/// With `clear` it drops one.
///
/// With NO argument it reports, because a goal you cannot see is a goal you cannot
/// tell the model apart from: "why did it stop" is unanswerable unless the objective is
/// on screen with its state.
pub fn cmdGoal(m: *tui.Model, arg: []const u8) void {
    const trimmed = std.mem.trim(u8, arg, " \t\r\n");

    if (trimmed.len == 0) {
        if (!m.goal.isSet()) {
            agent.pushInfoOwned(m, "no goal set. /goal <objective> gives the next turn something it may not stop short of.");
            return;
        }
        const state = switch (m.goal.status) {
            .none => "open",
            .met => "MET",
            .blocked => "BLOCKED",
        };
        const l1 = std.fmt.allocPrint(m.allocator, "goal ({s}): {s}", .{ state, m.goal.objective() }) catch "goal";
        agent.pushInfoOwned(m, l1);
        if (m.goal.summary_len > 0) {
            const l2 = std.fmt.allocPrint(m.allocator, "  {s}", .{m.goal.say()}) catch "goal";
            agent.pushInfoOwned(m, l2);
        }
        if (m.goal.unblock_len > 0) {
            const l3 = std.fmt.allocPrint(m.allocator, "  would unblock it: {s}", .{m.goal.whatUnblocks()}) catch "goal";
            agent.pushInfoOwned(m, l3);
        }
        const l4 = std.fmt.allocPrint(
            m.allocator,
            "  budget: {d} soft, {d} hard ({d} checkpoints asked) · /goal clear to drop it",
            .{ agent.iterationLimit(), agent.goalHardLimit(), m.goal.checkpoints },
        ) catch "goal";
        agent.pushInfoOwned(m, l4);
        return;
    }

    if (std.ascii.eqlIgnoreCase(trimmed, "clear") or std.ascii.eqlIgnoreCase(trimmed, "off")) {
        const was = m.goal.objective();
        m.goal.clear();
        m.goal_checkpoint = false;
        m.loop_repeated = null;
        // The note is removed from the wire too, or the next request still carries
        // "keep working towards it" with nothing behind it.
        if (agent.session) |ss| ss.setGoalNote(null) catch {};
        if (was.len > 0) {
            const line = std.fmt.allocPrint(m.allocator, "goal cleared ({d} checkpoints, {d} iterations)", .{ m.goal.checkpoints, m.goal.iterations }) catch "goal cleared";
            agent.pushInfoOwned(m, line);
        } else {
            agent.pushInfoOwned(m, "no goal was set");
        }
        return;
    }

    var g = goal_mod.Goal{};
    const n = @min(trimmed.len, g.text.len);
    @memcpy(g.text[0..n], trimmed[0..n]);
    g.len = n;
    m.goal = g;
    m.goal.status = goal_mod.Status.none;
    const line = std.fmt.allocPrint(
        m.allocator,
        "goal set: {s}\n  the turn may use {d} iterations instead of {d}, and will be asked at {d} whether it is met or blocked. Now type the task.",
        .{ trimmed, agent.goalHardLimit(), agent.iterationLimit(), agent.iterationLimit() },
    ) catch "goal";
    agent.pushInfoOwned(m, line);
}

/// `/context`: gauge of context used against the limit and the budget.
pub fn cmdContext(m: *tui.Model) void {
    _ = agent.ensureSession(m, m.allocator);
    var astate = std.heap.ArenaAllocator.init(m.allocator);
    defer astate.deinit();
    const msgs = agent.snapshotMsgs(astate.allocator());

    const used = compaction.estimateTokens(msgs);
    const budget = compaction.budgetFor(m.environ, agent.curModelContext());
    const limit = compaction.contextLimitFor(m.environ, agent.curModelContext());
    const sys: i64 = if (msgs.len > 0) compaction.estimateTokens(msgs[0..1]) else 0;
    const hist = used - sys;
    const pct_limit = @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(limit)) * 100.0;
    const pct_budget = @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(budget)) * 100.0;
    const turns: usize = if (msgs.len > 0) msgs.len - 1 else 0;

    // 20-cell gauge (█ = E2 96 88, ░ = E2 90 8A)
    var gauge_buf: [60]u8 = undefined;
    const filled: usize = @intFromFloat(@min(pct_limit, 100.0) / 5.0);
    var gi: usize = 0;
    for (0..filled) |_| {
        @memcpy(gauge_buf[gi .. gi + 3], "█");
        gi += 3;
    }
    for (filled..20) |_| {
        @memcpy(gauge_buf[gi .. gi + 3], "░");
        gi += 3;
    }

    const l1 = std.fmt.allocPrint(
        m.allocator,
        "context [{s}] ~{d} / {d} tokens ({d:.1}% of limit)",
        .{ gauge_buf[0..gi], used, limit, pct_limit },
    ) catch "context";
    agent.pushInfoOwned(m, l1);
    const l2 = std.fmt.allocPrint(
        m.allocator,
        "  system ~{d} · history ~{d} · {d} turns · budget {d} ({d:.0}% used)",
        .{ sys, hist, turns, budget, pct_budget },
    ) catch "details";
    agent.pushInfoOwned(m, l2);
    // WHERE the limit came from, because the number is now an automatic: with a
    // fixed 128k you could not tell "the model has 128k" from "zode is budgeting
    // 128k for a 1M model" from "the catalogue was never downloaded", and all
    // three look the same on the same line.
    const src = compaction.limitSource(m.environ, agent.curModelContext());
    // What the PROVIDER counted on the last request, next to our estimate.
    // They answer the same question with different instruments: `used` above is
    // ~4 chars per token, `prev_prompt` is the tokenizer that will actually bill
    // this context. When they disagree by more than a few percent, the estimate
    // is what the compaction budget is about to be judged against, and saying so
    // is the difference between "the number is wrong" and "the number is an
    // estimate".
    const provider_count = agent.cacheSessionStats().prev_prompt;
    const l3 = std.fmt.allocPrint(
        m.allocator,
        "  limit from: {s} · elided this session: {d} tool results · last stream: {d:.0} tok/s",
        .{ switch (src) {
            .model => "the model's own context window",
            .env => "ZODE_CONTEXT_LIMIT",
            .default_ => "the 128k default (this provider does not publish a window; /model from a catalogue that has one)",
        }, agent.session_elided, agent.tps_last },
    ) catch "details";
    agent.pushInfoOwned(m, l3);
    if (provider_count > 0) {
        const l3c = std.fmt.allocPrint(
            m.allocator,
            "  last request: {d} tokens counted by the provider (our estimate: {d})",
            .{ provider_count, used },
        ) catch "details";
        agent.pushInfoOwned(m, l3c);
    }
    // WHAT WILL HAPPEN at the threshold, which is a different question from how much
    // is used: "80% of the limit" does not say whether crossing it costs a request.
    const l3b = std.fmt.allocPrint(
        m.allocator,
        "  compaction: {s} at {d}% of the limit ({s})",
        .{
            @tagName(compaction.effectiveMode(m.environ, m.compact_mode)),
            compaction.targetPct(m.environ),
            if (m.compact_mode == null) "ZODE_COMPACT" else "overridden with /compact",
        },
    ) catch "compaction";
    agent.pushInfoOwned(m, l3b);

    // WHERE THE MEMORY IS, in bytes.
    //
    // Not decoration: "6 MB" is a startup number, and the one that decides whether
    // a long session is usable is whether it grows. `tools/ram_probe.py` measures
    // the slope with a real model answering (measured 2026-10-05: 7.96 MB at
    // startup, 12.32 MB after 8 turns, +48 KB/turn and flattening); this says
    // where the bytes are, so a slope can be attributed instead of guessed at.
    //
    // The hot/cold split is the interesting part: `pruneCold` compresses the
    // paragraphs outside the scroll window, so a long session's scrollback is
    // mostly base64. If `cold` ever stops growing, the compression stopped
    // running, and that is the bug to look for.
    const ram = m.ramReport();
    const lram = std.fmt.allocPrint(
        m.allocator,
        "  memory: {d} MB RSS · {d} KB scrollback ({d} hot · {d} compressed) · {d} KB segment cache ({d} entries) · {d} files cached",
        .{
            @as(f64, @floatFromInt(ram.rss_kb)) / 1024.0,
            ram.scrollbackBytes() / 1024,
            ram.hot_bytes / 1024,
            ram.cold_bytes / 1024,
            ram.cache_arena_bytes / 1024,
            ram.cache_entries,
            ram.read_cache_entries,
        },
    ) catch "details";
    agent.pushInfoOwned(m, lram);

    // The read cache, in tokens saved rather than in hits: "it worked" is a number
    // the user can compare against the size of the files they are working with.
    if (m.reads.stats.hits > 0 or m.reads.stats.misses > 0) {
        const l4 = std.fmt.allocPrint(
            m.allocator,
            "  read cache: {d} re-reads avoided · ~{d} KB not re-sent ({d} files still in context)",
            .{ m.reads.stats.hits, m.reads.stats.saved / 1024, m.reads.liveEntries() },
        ) catch "details";
        agent.pushInfoOwned(m, l4);
    }

    // Where the tools are actually reading and writing. It is here and not only in
    // the prompt because the USER needs it too: "why did it edit that file?" is
    // answered by the cwd, and without it the answer is a guess.
    var loc_buf: [std.fs.max_path_bytes]u8 = undefined;
    const loc = agent.project_info.oneLine(&loc_buf);
    if (loc.len > 0) agent.pushInfoFmt(m, "  {s}", .{loc});

    agent.refreshContextUsage(m);
}

/// `/session`: id, path and message count.
pub fn cmdSession(m: *tui.Model) void {
    const s = agent.ensureSession(m, m.allocator);
    const l1 = std.fmt.allocPrint(
        m.allocator,
        "session {s} · {d} messages",
        .{ s.id[0..], s.messages.items.len },
    ) catch "session";
    agent.pushInfoOwned(m, l1);
    if (s.path) |p| {
        m.pushInfoFmt("  {s}", .{p});
    }
}

/// `/providers`: lists the providers with their key state.
pub fn cmdProviders(m: *tui.Model) void {
    for (agent.allProviders(m.allocator)) |*d| {
        const key_state: []const u8 =
            if (d.key_env.len == 0) "sin key" else if (providers.keyFor(d, m.environ) != null) "key ok" else "SIN KEY";
        const active: []const u8 = if (std.mem.eql(u8, d.id, agent.cur_provider_id)) " ←" else "";
        const line = std.fmt.allocPrint(
            m.allocator,
            "{s:<11} {s} ({s}){s}  {s}",
            .{ d.id, d.name, key_state, active, d.note },
        ) catch "provider";
        agent.pushInfoOwned(m, line);
    }
}

/// `/use <provider> [model]`.
pub fn cmdUse(m: *tui.Model, arg: ?[]const u8) void {
    const a = arg orelse {
        m.pushInfoFmt("usage: /use <provider> [model]", .{});
        return;
    };
    var it = std.mem.tokenizeScalar(u8, a, ' ');
    const prov = it.next() orelse return;
    agent.applyProvider(m, prov) catch return;
    // 0: `/use <provider> <model>` types a name, it does not come from the
    // catalogue, so there is no window to carry. It resets to the fallback, which
    // is the honest answer for a model nobody has looked up yet.
    if (it.next()) |mo| agent.applyModel(m, mo, 0) catch {};
}

/// Shortcuts that are NOT commands: they have to be typed, they are not in the
/// palette.
///
/// `/help` used to list only the command table, so half of the shortcuts (the
/// ones with no command behind them) were written down nowhere, and the ones
/// that did have one showed up without their shortcut. Ctrl+P surfaces them, but
/// whoever just opened the app does not know it exists.
pub const shortcuts = [_]struct { key: []const u8, desc: []const u8 }{
    .{ .key = "ctrl+p", .desc = "command palette (executes the one you pick)" },
    .{ .key = "ctrl+t", .desc = "model palette (providers | models)" },
    .{ .key = "ctrl+a", .desc = "connect a provider (paste its key)" },
    .{ .key = "ctrl+l", .desc = "clear the view (the session file is untouched)" },
    .{ .key = "ctrl+r", .desc = "expand / collapse the last tool result or diff" },
    .{ .key = "ctrl+c", .desc = "quit" },
    .{ .key = "ctrl+u / ctrl+d", .desc = "scroll half a page" },
    .{ .key = "page up / down", .desc = "scroll a page" },
    .{ .key = "shift+enter", .desc = "newline (enter sends)" },
    .{ .key = "shift+tab", .desc = "read-only mode: no writes, the agent asks you" },
    .{ .key = "esc", .desc = "stop the turn, kill a running command, or answer a question with \"you decide\"" },
    .{ .key = "tab", .desc = "complete a `/` command" },
    .{ .key = "↑ / ↓", .desc = "command history (empty line keeps the draft)" },
};

/// `key` comes with the leading slash. The order is the order of appearance in
/// `/help`.
pub const commands = [_]Cmd{
    .{ .key = "/help", .desc = "show commands", .key_hint = "ctrl+p" },
    .{ .key = "/models", .desc = "list the active provider models" },
    .{ .key = "/model", .desc = "pick a model in a modal", .key_hint = "ctrl+p" },
    .{ .key = "/provider", .desc = "pick a provider in a modal" },
    .{ .key = "/providers", .desc = "list providers" },
    .{ .key = "/use", .desc = "switch provider/model", .key_hint = "provider modelo" },
    .{ .key = "/effort", .desc = "none|minimal|low|medium|high|xhigh (no args: picker)" },
    .{ .key = "/submodel", .desc = "which model the SUBAGENTS use (no args: report | <model> | <provider> <model> | off)" },
    .{ .key = "/free-auto", .desc = "rotate the FREE models of every provider you have a key for, and keep going when one runs out" },
    .{ .key = "/plan", .desc = "clear the visible task list" },
    .{ .key = "/goal", .desc = "set the objective the turn may not stop short of", .key_hint = "<objetivo> | clear" },
    .{ .key = "/undo", .desc = "restore the files the last turn changed" },
    .{ .key = "/clean", .desc = "purge zode leftovers (dry run; /clean yes applies)" },
    .{ .key = "/yolo", .desc = "bypass: allow everything, ask nothing" },
    .{ .key = "/mode", .desc = "permission mode: default | accept-edits | read-only | bypass" },
    .{ .key = "/allowlist", .desc = "always-allowed tools + bash (persisted)" },
    .{ .key = "/bg", .desc = "background commands: list | kill <id> | killall" },
    .{ .key = "/new", .desc = "new session" },
    .{ .key = "/resume", .desc = "resume the last session" },
    .{ .key = "/context", .desc = "tokens used vs budget, and what compaction will do" },
    .{ .key = "/compact", .desc = "off|elide|full: automatic compaction (no args: report)", .key_hint = "off|elide|full" },
    .{ .key = "/bench", .desc = "session numbers: turns, iterations, first-token times" },
    .{ .key = "/session", .desc = "session info" },
    .{ .key = "/cache", .desc = "cache hit-rate for this session" },
    .{ .key = "/ask", .desc = "on|off: read-only mode (shift+tab); the agent investigates and asks" },
    .{ .key = "/skills", .desc = "list the loadable skills" },
    .{ .key = "/quit", .desc = "quit", .key_hint = "ctrl+c" },
};

pub const Cmd = struct {
    key: []const u8,
    desc: []const u8,
    /// Keyboard shortcut that does the same thing (right column of the palette).
    /// Only ones that really exist are listed: putting a fake one would be worse
    /// than putting none.
    key_hint: ?[]const u8 = null,
};
