const std = @import("std");
const tui = @import("tui.zig");
const agent = @import("agent.zig");
const cache_stats = @import("cache_stats.zig");
const compaction = @import("compaction.zig");
const goal_mod = @import("lib/goal.zig");
const providers = @import("lib/providers.zig");
const chat = @import("chat.zig");
const filesview = @import("lib/filesview.zig");
const readcache = @import("lib/readcache.zig");
const init_mod = @import("lib/init.zig");
const cost_mod = @import("lib/cost.zig");
const modelcache_mod = @import("lib/modelcache.zig");

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
fn pushCommandList(m: *tui.Model, palette_visible: bool) void {
    const gpa = m.allocator;
    for (commands) |c| {
        if (c.palette_visible != palette_visible) continue;
        const line = if (c.key_hint) |h|
            std.fmt.allocPrint(gpa, "{s: <14} {s}  ({s})", .{ c.key, c.desc, h }) catch continue
        else
            std.fmt.allocPrint(gpa, "{s: <14} {s}", .{ c.key, c.desc }) catch continue;
        agent.pushInfoOwned(m, line);
    }
}

pub fn cmdHelp(m: *tui.Model) void {
    const gpa = m.allocator;
    agent.pushInfoOwned(m, gpa.dupe(u8, "commands") catch return);
    pushCommandList(m, true);
    agent.pushInfoOwned(m, gpa.dupe(u8, "advanced · type these commands directly") catch return);
    pushCommandList(m, false);

    // The user's own commands, refreshed so a file written a minute ago shows
    // up. They get their own block because they answer a different question:
    // not "what does zode do" but "what did I add".
    agent.refreshUserCommandsModel(m);
    const uc = agent.userCommands();
    if (uc.len > 0) {
        agent.pushInfoOwned(m, gpa.dupe(u8, "your commands (.zode/commands · ~/.config/zode/commands)") catch return);
        var i: usize = 0;
        while (i < uc.len) : (i += 1) {
            if (agent.userCommandInfo(i)) |info| {
                const origin = if (info.root == 0) "proj" else "user";
                const line = std.fmt.allocPrint(gpa, "{s: <14} {s: <10} {s}", .{ info.key, origin, info.desc }) catch continue;
                agent.pushInfoOwned(m, line);
            } else {
                const c = uc[i];
                const line = std.fmt.allocPrint(gpa, "{s: <14} {s}", .{ c.key, c.desc }) catch continue;
                agent.pushInfoOwned(m, line);
            }
        }
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

/// `/permissions`: the RULES (Phase 6) and where they live.
///
/// The rules are the answer to "why did it ask / why did it refuse", and
/// there is no other way to find out: a rule that lives in a file the user
/// wrote and never sees again is a rule that surprises them.
pub fn cmdPermissions(m: *tui.Model) void {
    const gpa = m.allocator;
    const set = agent.permRuleSet();

    agent.pushInfoOwned(m, gpa.dupe(u8, "rules  ·  Tool(pattern) action  ·  allow | deny | ask") catch return);

    if (set.rules.len == 0) {
        agent.pushInfoOwned(m, gpa.dupe(u8, "  (none)") catch return);
    } else {
        for (set.rules) |r| {
            const line = std.fmt.allocPrint(
                gpa,
                "  {s: <8} {s}",
                .{ r.source.name(), r.text },
            ) catch continue;
            agent.pushInfoOwned(m, line);
        }
    }

    // The two files, and the order they win in. The order IS the rule: a
    // project rule beats a user rule, and a DENY beats any allow.
    agent.pushInfoOwned(m, gpa.dupe(u8, "") catch return);
    const files = std.fmt.allocPrint(
        gpa,
        "files  ·  {s} (project)  ·  ~/.config/zode/permissions.json (user)",
        .{agent.project_rules_file},
    ) catch return;
    agent.pushInfoOwned(m, files);
    agent.pushInfoOwned(
        m,
        gpa.dupe(u8, "order  ·  project > user  ·  a deny beats any allow  ·  the last rule of a file wins") catch return,
    );
}

/// `/cache`: prompt cache hit-rate of the session.
pub fn cmdCache(m: *tui.Model) void {
    const st = &cache_stats.session;
    agent.pushInfoFmt(
        m,
        // WRITES are in the line because they are the expensive half: a high
        // hit-rate with a write on EVERY request means the prefix is being
        // rebuilt each turn, and no hit-rate alone can reveal that.
        "session cache · {d:.1}% hit-rate · {d} requests with hits · {d} input / {d} cached / {d} written · {d} output tokens",
        .{ st.hitRatePct(), st.cache_hits, st.prompt_tokens, st.cached_tokens, st.cache_write_tokens, st.completion_tokens },
    );

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

/// `/usage`: provider-reported token totals for the active session.
pub fn cmdUsage(m: *tui.Model) void {
    const st = agent.cacheSessionStats();
    if (st.requests == 0) {
        agent.pushInfo(
            m,
            "Usage · no provider-reported token data yet. `/context` shows the current estimate.",
        );
        return;
    }

    const input = @max(st.prompt_tokens, 0);
    const output = @max(st.completion_tokens, 0);
    const total = input +| output;
    const cached = @min(@max(st.cached_tokens, 0), input);
    const uncached = input - cached;
    const requests: i64 = @intCast(st.requests);
    var input_buf: [32]u8 = undefined;
    var output_buf: [32]u8 = undefined;
    var total_buf: [32]u8 = undefined;
    var cached_buf: [32]u8 = undefined;
    var uncached_buf: [32]u8 = undefined;
    var writes_buf: [32]u8 = undefined;
    var avg_in_buf: [32]u8 = undefined;
    var avg_out_buf: [32]u8 = undefined;
    const msg = std.fmt.allocPrint(
        m.allocator,
        "Usage · {d} metered requests · {s} total tokens\n" ++
            "  Input {s} · output {s} · average/request {s} in / {s} out\n" ++
            "  Cache reads {s} ({d:.1}%) · cache writes {s} · uncached input {s}",
        .{
            st.requests,
            formatTokenCount(&total_buf, total),
            formatTokenCount(&input_buf, input),
            formatTokenCount(&output_buf, output),
            formatTokenCount(&avg_in_buf, @divTrunc(input, requests)),
            formatTokenCount(&avg_out_buf, @divTrunc(output, requests)),
            formatTokenCount(&cached_buf, cached),
            st.hitRatePct(),
            formatTokenCount(&writes_buf, @max(st.cache_write_tokens, 0)),
            formatTokenCount(&uncached_buf, uncached),
        },
    ) catch return;
    agent.pushInfoOwned(m, msg);
}

fn formatTokenCount(buf: []u8, value: i64) []const u8 {
    // The grouping lives in `lib/cost.zig` now that `/cost` writes the same
    // numbers: two renderings of a token count in two commands is how one of them
    // ends up with a format the other does not have.
    return cost_mod.groupDigits(buf, value);
}

/// `/cost`: what this session has spent, per model, in dollars.
///
/// ## Why per model and not one total
///
/// A session talks to several models: `free-auto` rotates when a pool model runs
/// out of quota, the cheap router falls back to the user's own, and `/submodel`
/// sends subagents somewhere else on purpose. One total multiplied by one price
/// would be a number about a model that did not answer.
///
/// ## The prices come from the CACHED catalogue
///
/// Not from the network and not from a table in the binary: the provider
/// publishes the price and `modelcache.zig` already has it on disk. A model nobody
/// prices is `price unknown`, and the total says it is a floor — `$0.00` for a
/// model with no published price is a bill that reads as free.
pub fn cmdCost(m: *tui.Model) void {
    const st = agent.cacheSessionStats();
    if (st.requests == 0) {
        agent.pushInfo(
            m,
            "cost \u{b7} no provider-reported usage yet: a turn has to finish before there are tokens to price.",
        );
        return;
    }

    var arena_state = std.heap.ArenaAllocator.init(m.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const tr = &cost_mod.session;
    var rows: std.ArrayList(cost_mod.Row) = .empty;
    var i: usize = 0;
    while (i < tr.len) : (i += 1) {
        const e = &tr.entries[i];
        rows.append(a, .{
            .model = e.text(),
            .prompt = e.prompt_tokens,
            .completion = e.completion_tokens,
            .price = priceForModel(m, a, e.text()),
        }) catch break;
    }
    // What did not fit the table is one row and not a silence: a token count that
    // disappears is a bill that is wrong.
    if (tr.spill_requests > 0) {
        rows.append(a, .{
            .model = "other models",
            .prompt = tr.spill_prompt,
            .completion = tr.spill_completion,
            .price = null,
        }) catch {};
    }

    const text = cost_mod.report(m.allocator, rows.items, st.requests, st.prompt_tokens) catch {
        m.pushError("could not build the cost report");
        return;
    };
    agent.pushInfoOwned(m, text);
}

/// The published price of ONE model, from the cached catalogue of a provider that
/// has a key.
///
/// Null means "nobody publishes a price for it", which the report renders as
/// `price unknown`. A free model is a price of zero and NOT an unknown one: those
/// two answers send the reader to different places.
///
/// The catalogue is read here and not held: `/cost` is typed by hand, so a handful
/// of small file reads is cheaper than a cache with a lifetime to get wrong.
fn priceForModel(m: *tui.Model, a: std.mem.Allocator, model_id: []const u8) ?cost_mod.Price {
    // A `Model` built by a test has no `Io`, and reading a file through one is a
    // jump through a garbage vtable, not an error.
    if (!m.io_ready) return null;

    var defs_arena_state = std.heap.ArenaAllocator.init(a);
    defer defs_arena_state.deinit();
    for (agent.allProviders(defs_arena_state.allocator())) |*d| {
        if (!providers.hasKey(d, m.environ)) continue;
        var cache_arena = std.heap.ArenaAllocator.init(a);
        defer cache_arena.deinit();
        const entry = modelcache_mod.read(m.io, m.environ, cache_arena.allocator(), d.id, d.models_url) orelse continue;
        // The DECISION (free / unpriced / priced) lives in `lib/cost.zig` with the
        // rest of the money, so it is tested without a catalogue on disk.
        switch (cost_mod.priceOf(entry.models, model_id)) {
            .missing => continue,
            .found => |price| return price,
        }
    }
    return null;
}

test "formatTokenCount groups digits from the right" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0", formatTokenCount(&buf, 0));
    try std.testing.expectEqualStrings("999", formatTokenCount(&buf, 999));
    try std.testing.expectEqualStrings("1,000", formatTokenCount(&buf, 1_000));
    try std.testing.expectEqualStrings("12,345", formatTokenCount(&buf, 12_345));
    try std.testing.expectEqualStrings("1,234,567", formatTokenCount(&buf, 1_234_567));
}

test "cost command prices what it can and says what it cannot" {
    agent.cacheSessionStatsForTest().* = .{};
    defer agent.cacheSessionStatsForTest().* = .{};
    cost_mod.session.reset();
    defer cost_mod.session.reset();

    agent.cacheSessionStatsForTest().record(.{ .prompt = 12_345, .cached = 0, .completion = 678 });
    cost_mod.session.record("kimi-k2.6", 12_345, 678);

    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    cmdCost(&m);

    const text = try pendingText(&m, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "kimi-k2.6") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "12,345 in") != null);
    // A test `Model` has no `Io`, so no catalogue was read. A price that could not
    // be read is NOT a price of zero, and the report has to say so.
    try std.testing.expect(std.mem.indexOf(u8, text, "no total") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "$0.00") == null);
}

test "the cost command prices a model from the provider's cached catalogue" {
    // The glue the two pure halves cannot cover: a HOME with the catalogue file
    // `modelcache.write` leaves behind, a provider with a key, and a report that
    // has to come out with real money in it.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".config/zode/models");
    try tmp.dir.writeFile(io, .{
        .sub_path = ".config/zode/models/opencode.json",
        .data =
        \\{"version":1,"url":"https://opencode.ai/inference/v1/models","fetched_at":0,"models":[
        \\ {"id":"kimi-k2.6","ctx":128000,"free":false,"by":"opencode","pp":0.000001,"pc":0.000002},
        \\ {"id":"space-bunny-free","ctx":32000,"free":true,"by":"opencode","pp":0,"pc":0}
        \\]}
        ,
    });
    var pbuf: [512]u8 = undefined;
    const np = tmp.dir.realPath(io, &pbuf) catch return error.TestUnexpectedResult;

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", pbuf[0..np]);
    try env.put("ZODE_API_KEY", "test-key");

    agent.cacheSessionStatsForTest().* = .{};
    defer agent.cacheSessionStatsForTest().* = .{};
    cost_mod.session.reset();
    defer cost_mod.session.reset();
    agent.cacheSessionStatsForTest().record(.{ .prompt = 1_000_000, .completion = 500_000 });
    cost_mod.session.record("kimi-k2.6", 1_000_000, 500_000);
    cost_mod.session.record("space-bunny-free", 2_000, 100);

    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    m.environ = &env;
    m.attachIo(io);
    cmdCost(&m);

    const text = try pendingText(&m, std.testing.allocator);
    defer std.testing.allocator.free(text);
    // 1M prompt tokens at $1/M + 500k completion at $2/M = $2.00.
    try std.testing.expect(std.mem.indexOf(u8, text, "$2.00") != null);
    // The free model is a PRICE of zero, not an unknown one.
    try std.testing.expect(std.mem.indexOf(u8, text, "$0.00") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "price unknown") == null);
}

test "cost command says there is nothing to price before the first turn" {
    agent.cacheSessionStatsForTest().* = .{};
    defer agent.cacheSessionStatsForTest().* = .{};

    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    cmdCost(&m);

    const text = try pendingText(&m, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "no provider-reported usage yet") != null);
}

test "usage command reports provider totals and distinguishes estimates" {
    agent.cacheSessionStatsForTest().* = .{};
    defer agent.cacheSessionStatsForTest().* = .{};
    agent.cacheSessionStatsForTest().record(.{ .prompt = 12_345, .cached = 10_000, .completion = 678 });

    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    cmdUsage(&m);

    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(std.testing.allocator);
    for (m.pending.items) |item| try all.appendSlice(std.testing.allocator, item.text);
    try std.testing.expect(std.mem.indexOf(u8, all.items, "Usage · 1 metered requests · 13,023 total tokens") != null);
    try std.testing.expect(std.mem.indexOf(u8, all.items, "Input 12,345 · output 678") != null);
    try std.testing.expect(std.mem.indexOf(u8, all.items, "Cache reads 10,000") != null);
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

/// `/init`: analyse the codebase and write AGENTS.md.
///
/// This runs the initialization prompt (see `lib/init.zig`) which has the model
/// survey the repo, interview the user, and write AGENTS.md + CLAUDE.local.md.
pub fn cmdInit(m: *tui.Model) void {
    if (!m.io_ready) return;
    const prompt = init_mod.prompt(m.allocator) catch {
        m.pushError("could not load init prompt");
        return;
    };
    defer m.allocator.free(prompt);
    agent.startChat(m, prompt) catch |err| {
        m.pushErrorFmt("could not start init: {t}", .{err});
    };
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

/// `/files`: what the model is looking at, and what it changed.
///
/// The question it answers is "what is the model looking at?", which is the
/// question you ask when a turn goes sideways. The data was already there (the
/// read cache) and NOTHING showed it.
///
/// Two lists, because they are two different facts:
///
/// - the files the model has READ, and whether their content is still in the
///   context (a compacted-away read is not, and a model that thinks it has a
///   file it does not have is how an agent quotes something it never saw);
/// - the files the agent WROTE to, this session.
///
/// The read cache is read UNDER ITS OWN LOCK: a worker can be reading a file
/// right now, and the entries are the fixed buffers it writes into.
pub fn cmdFiles(m: *tui.Model) void {
    const gpa = m.allocator;
    var report = filesview.Report.init(gpa);
    defer report.deinit();

    const Collect = struct {
        report: *filesview.Report,

        fn take(self: *@This(), entries: []const readcache.Entry) void {
            if (entries.len == 0) return;
            // Most recent FIRST: "what is the model looking at" is a question
            // about NOW, and the table's own order is the order of insertion.
            var idx: [readcache.max_entries]usize = undefined;
            for (entries, 0..) |_, i| idx[i] = i;
            var i: usize = 1;
            while (i < entries.len) : (i += 1) {
                const key = idx[i];
                var j = i;
                while (j > 0 and entries[idx[j - 1]].used < entries[key].used) : (j -= 1) {
                    idx[j] = idx[j - 1];
                }
                idx[j] = key;
            }
            for (idx[0..entries.len]) |k| {
                const e = entries[k];
                self.report.addRead(e.pathOf(), e.lines, e.in_context) catch return;
            }
        }
    };
    var collect = Collect{ .report = &report };
    m.reads.withAll(&collect, Collect.take);

    // The files the agent changed. The paths are borrowed from the Model's
    // table, which outlives the report.
    if (m.changed.count() > 0) {
        report.addSection("changed") catch {};
        var paths: [filesview.max_changed][]const u8 = undefined;
        const n = m.changed.fill(&paths);
        for (paths[0..n]) |p| {
            report.addChanged(p) catch break;
        }
    }

    const rc = m.reads.statsSnapshot();
    const stats = filesview.Stats{ .hits = rc.hits, .misses = rc.misses, .saved = rc.saved };
    report.bash_may_write = m.bash_may_write;
    const text = report.finish(stats, m.changed.dropped) catch return;
    agent.pushInfoOwned(m, text);
}

/// `/providers`: lists the providers with their key state.
pub fn cmdProviders(m: *tui.Model) void {
    var defs_arena_state = std.heap.ArenaAllocator.init(m.allocator);
    defer defs_arena_state.deinit();
    for (agent.allProviders(defs_arena_state.allocator())) |*d| {
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
    .{ .key = "shift+tab", .desc = "cycle Build → accept-edits → Plan modes" },
    .{ .key = "esc", .desc = "stop the turn, kill a running command, or answer a question with \"you decide\"" },
    .{ .key = "tab", .desc = "complete a `/` command" },
    .{ .key = "↑ / ↓", .desc = "command history (empty line keeps the draft)" },
};

/// `key` comes with the leading slash. The order is the order of appearance in
/// `/help`.
pub const commands = [_]Cmd{
    .{ .key = "/help", .desc = "show commands", .key_hint = "ctrl+p" },
    .{ .key = "/models", .desc = "show catalog counts; use /model to browse" },
    .{ .key = "/model", .desc = "pick a model in a modal", .key_hint = "ctrl+p" },
    .{ .key = "/provider", .desc = "pick a provider in a modal" },
    .{ .key = "/providers", .desc = "list providers" },
    .{ .key = "/use", .desc = "switch provider/model", .key_hint = "provider modelo" },
    .{ .key = "/effort", .desc = "none|minimal|low|medium|high|xhigh (no args: picker)" },
    .{ .key = "/color", .desc = "the diff palette: default | daltonized (no args: picker)" },
    .{ .key = "/submodel", .desc = "which model the SUBAGENTS use (no args: report | <model> | <provider> <model> | off)" },
    .{ .key = "/task-parallel", .desc = "simultaneous subagent limit: 1..8 | auto", .key_hint = "1..8 | auto", .palette_visible = false },
    .{ .key = "/reload-cmds", .desc = "reload user commands from disk", .palette_visible = false },
    .{ .key = "/which-cmd", .desc = "show where a user command comes from", .key_hint = "name", .palette_visible = false },
    .{ .key = "/free-auto", .desc = "rotate the FREE models of every provider you have a key for, and keep going when one runs out" },
    .{ .key = "/goal", .desc = "set the objective the turn may not stop short of", .key_hint = "<objetivo> | clear" },
    .{ .key = "/init", .desc = "analyse the codebase and write AGENTS.md" },
    .{ .key = "/undo", .desc = "restore the files the last turn changed" },
    .{ .key = "/clean", .desc = "purge zode leftovers (dry run; /clean yes applies)", .palette_visible = false },
    .{ .key = "/yolo", .desc = "bypass: allow everything, ask nothing (your questions are answered for you and said in the summary)" },
    .{ .key = "/mode", .desc = "set work mode: build | accept-edits | plan | bypass" },
    .{ .key = "/allowlist", .desc = "always-allowed tools + bash (persisted)" },
    .{ .key = "/permissions", .desc = "the rules: Tool(pattern) allow | deny | ask" },
    .{ .key = "/bg", .desc = "background commands: list | kill <id> | killall", .palette_visible = false },
    .{ .key = "/new", .desc = "new session" },
    .{ .key = "/resume", .desc = "resume the last session" },
    .{ .key = "/context", .desc = "tokens used vs budget, and what compaction will do" },
    .{ .key = "/usage", .desc = "session input/output tokens, cache, and request totals", .key_hint = "session totals" },
    .{ .key = "/cost", .desc = "what this session has cost, per model (USD, from the catalogue's prices)" },
    .{ .key = "/compact", .desc = "off|elide|full: automatic compaction (no args: report)", .key_hint = "off|elide|full" },
    .{ .key = "/bench", .desc = "session numbers: turns, iterations, first-token times", .palette_visible = false },
    .{ .key = "/session", .desc = "session info", .palette_visible = false },
    .{ .key = "/files", .desc = "the files the model has read, and the ones it changed" },
    .{ .key = "/cache", .desc = "cache hit-rate for this session", .palette_visible = false },
    .{ .key = "/ask", .desc = "on|off: enable Plan mode (Shift+Tab also cycles modes)" },
    .{ .key = "/skills", .desc = "list the loadable skills" },
    .{ .key = "/style", .desc = "select an output style: default|explanatory|learning (no args: report | off)" },
    .{ .key = "/copy", .desc = "copy an answer to the clipboard: /copy (the last one) | /copy N (N answers back)", .key_hint = "N" },
    .{ .key = "/quit", .desc = "quit", .key_hint = "ctrl+c" },
};

pub const Cmd = struct {
    key: []const u8,
    desc: []const u8,
    /// Keyboard shortcut that does the same thing (right column of the palette).
    /// Only ones that really exist are listed: putting a fake one would be worse
    /// than putting none.
    key_hint: ?[]const u8 = null,
    /// Keep advanced maintenance and harness controls out of the default
    /// command palette while preserving direct commands and `/help`.
    palette_visible: bool = true,
};

// ── `/files` ──────────────────────────────────────────────────

/// The text the command pushed, as one string.
fn pendingText(m: *tui.Model, gpa: std.mem.Allocator) ![]u8 {
    var all: std.ArrayList(u8) = .empty;
    errdefer all.deinit(gpa);
    for (m.pending.items) |item| try all.appendSlice(gpa, item.text);
    return all.toOwnedSlice(gpa);
}

test "the files command names what the model read and what the agent changed" {
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    const stat = .{ .inode = @as(u64, 7), .size = @as(u64, 100), .mtime = .{ .nanoseconds = @as(i128, 5) } };
    m.reads.record("src/tui.zig", stat, 0xabcd, 1, 100, 3420);
    m.changed.note("src/agent.zig");

    cmdFiles(&m);

    const text = try pendingText(&m, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "src/tui.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "in context") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "src/agent.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "1 read") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "1 changed") != null);
}

test "the files command says when there is nothing, instead of showing an empty list" {
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    cmdFiles(&m);

    const text = try pendingText(&m, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "nothing read or written") != null);
}

test "the files command says a file is NOT in the context when it is not" {
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    const stat = .{ .inode = @as(u64, 7), .size = @as(u64, 100), .mtime = .{ .nanoseconds = @as(i128, 5) } };
    m.reads.record("build.zig", stat, 0xabcd, 1, 100, 88);
    // A write forgets the entry: the model does not have the OLD text any more.
    m.reads.invalidate("build.zig");

    cmdFiles(&m);

    const text = try pendingText(&m, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "build.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "not in context") != null);
}
