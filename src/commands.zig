const std = @import("std");
const tui = @import("tui.zig");
const agent = @import("agent.zig");
const cache_stats = @import("cache_stats.zig");
const compaction = @import("compaction.zig");
const goal_mod = @import("lib/goal.zig");
const providers = @import("lib/providers.zig");
const config_mod = @import("config.zig");
const chat = @import("chat.zig");
const filesview = @import("lib/filesview.zig");
const readcache = @import("lib/readcache.zig");
const init_mod = @import("lib/init.zig");
const cost_mod = @import("lib/cost.zig");
const modelcache_mod = @import("lib/modelcache.zig");
const session_mod = @import("session.zig");
const sessionindex = @import("lib/sessionindex.zig");
const sessionpath = @import("lib/sessionpath.zig");
const build_options = @import("build_options");
const permrules = @import("lib/permrules.zig");
const hooks_mod = @import("lib/hooks.zig");
const md = @import("lib/markdown.zig");
const gitcmds = @import("lib/gitcmds.zig");
const selfupdate = @import("lib/selfupdate.zig");
const theme = @import("lib/theme.zig");
const clean_mod = @import("lib/clean.zig");
const copytext = @import("lib/copytext.zig");
const clipboard = @import("clipboard.zig");
const bgproc = @import("bgproc.zig");
const github_lib = @import("lib/github.zig");
const subagent_mod = @import("lib/subagent.zig");
const mcp_manager = @import("mcp/manager.zig");
const sandbox_mod = @import("lib/sandbox.zig");

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

/// `/permissions`: permission mode, rules, and allowlist (35.11 panel).
///
/// Shows why a call asked/was refused, which rules exist, and where to edit
/// them. The rule engine is Phase 6; the dialog explanation is 33.21.
/// Subcommands: `reload` re-reads rules from disk.
pub fn cmdPermissions(m: *tui.Model, arg: ?[]const u8) void {
    const gpa = m.allocator;
    if (arg) |a| {
        const sub = std.mem.trim(u8, a, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(sub, "reload")) {
            agent.loadPermRules();
            agent.loadAllowlist();
            agent.pushInfoOwned(m, gpa.dupe(u8, "permissions: reloaded rules and allowlist from disk") catch return);
            // fall through to show current state
        } else if (sub.len > 7 and std.ascii.eqlIgnoreCase(sub[0..4], "add ")) {
            const rule_text = std.mem.trim(u8, sub[4..], " \t\r\n");
            var arena_state = std.heap.ArenaAllocator.init(gpa);
            defer arena_state.deinit();
            const aa = arena_state.allocator();
            const rule = permrules.parseRule(rule_text, .user, aa) orelse {
                agent.pushInfoFmt(m, "permissions add: invalid rule `{s}` (expected: Tool(pattern) allow|deny|ask|dontAsk)", .{rule_text});
                return;
            };
            if ((rule.action == .allow or rule.action == .dontAsk) and permrules.isDangerousPattern(rule.tool, rule.pattern)) {
                agent.pushInfoFmt(m, "permissions add: refused dangerous broad allow `{s}` — use a narrower pattern (e.g. Bash(git *)) or deny/ask", .{rule.text});
                return;
            }
            // Add to in-memory rules (local-strength view isn't needed; save as user
            // and reload so precedence/ordering is consistent) and persist.
            if (agent.savePermRule(rule)) {
                agent.loadPermRules();
                agent.pushInfoFmt(m, "permissions add: saved user rule `{s}`", .{rule.text});
            } else {
                agent.pushInfoFmt(m, "permissions add: could not save rule `{s}` (check user permissions file path)", .{rule.text});
            }
            // fall through to show current state
        } else if (sub.len > 0) {
            agent.pushInfoFmt(m, "permissions: unknown subcommand `{s}` (use: /permissions | /permissions reload | /permissions add <Tool(pattern) action>)", .{sub});
            return;
        }
    }
    const set = agent.permRuleSet();

    agent.pushInfoFmt(m, "permissions  ·  mode: {s}", .{agent.permModeName()});
    agent.pushInfoOwned(m, gpa.dupe(u8, "  engine: Phase 6 Tool(pattern) rules + pathsafe dangerous-path protection (34.1)") catch return);

    agent.pushInfoOwned(m, gpa.dupe(u8, "") catch return);
    agent.pushInfoOwned(m, gpa.dupe(u8, "rules  ·  Tool(pattern) action  ·  allow | deny | ask | dontAsk") catch return);
    agent.pushInfoOwned(m, gpa.dupe(u8, "  sources: local > project > user > policy  ·  deny beats any allow  ·  last rule in a file wins") catch return);
    if (set.rules.len == 0) {
        agent.pushInfoOwned(m, gpa.dupe(u8, "  (no loaded rules; built-in pathsafe/policy checks and legacy allowlist still apply)") catch return);
    } else {
        for (set.rules, 0..) |r, i| {
            var tag_buf: [64]u8 = undefined;
            var tag_w: std.Io.Writer = .fixed(&tag_buf);
            if (permrules.isDangerousRuleText(r.text)) tag_w.writeAll("  [dangerous]") catch {};
            if (permrules.shadowedRule(set.rules, i)) tag_w.writeAll("  [shadowed]") catch {};
            const line = std.fmt.allocPrint(
                gpa,
                "  {s: <8} {s}{s}",
                .{ r.source.name(), r.text, tag_w.buffered() },
            ) catch continue;
            agent.pushInfoOwned(m, line);
        }
    }

    agent.pushInfoOwned(m, gpa.dupe(u8, "") catch return);
    agent.pushInfoOwned(m, gpa.dupe(u8, "legacy allowlist  ·  persisted standing approvals (user permissions file)") catch return);
    var abuf: [512]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&abuf);
    aw.writeAll("  tools: ") catch {};
    var an: usize = 0;
    for (agent.always_lens, 0..) |l, i| {
        if (l == 0) continue;
        if (an > 0) aw.writeAll(", ") catch {};
        aw.writeAll(agent.always_names[i][0..l]) catch {};
        an += 1;
    }
    if (an == 0) aw.writeAll("(none)") catch {};
    aw.writeAll("  ·  bash prefixes: ") catch {};
    var bn: usize = 0;
    for (agent.bash_pattern_lens, 0..) |l, i| {
        if (l == 0) continue;
        if (bn > 0) aw.writeAll(", ") catch {};
        aw.writeAll(agent.bash_pattern_bufs[i][0..l]) catch {};
        bn += 1;
    }
    if (bn == 0) aw.writeAll("(none)") catch {};
    agent.pushInfoOwned(m, gpa.dupe(u8, aw.buffered()) catch return);
    agent.pushInfoOwned(m, gpa.dupe(u8, "") catch return);
    var prbuf: [640]u8 = undefined;
    const project_path = agent.resolvedProjectRulesPath(&prbuf);
    const project_exists = if (m.io_ready) blk: {
        _ = std.Io.Dir.cwd().statFile(agent.io_global, project_path, .{}) catch break :blk false;
        break :blk true;
    } else false;
    var upbuf: [512]u8 = undefined;
    const user_path = agent.permissionsFilePath(&upbuf);
    const user_exists = if (m.io_ready) if (user_path) |p| blk: {
        _ = std.Io.Dir.cwd().statFile(agent.io_global, p, .{}) catch break :blk false;
        break :blk true;
    } else false else false;
    agent.pushInfoOwned(m, gpa.dupe(u8, "loaded from (effective paths, resolved like the loader):") catch return);
    const files = std.fmt.allocPrint(
        gpa,
        "  project: {s} ({s})  ·  user: {s} ({s})",
        .{
            project_path,
            if (!m.io_ready) "unknown" else if (project_exists) "exists" else "missing",
            user_path orelse "~/.config/zode/permissions.json",
            if (user_path == null) "unknown path" else if (!m.io_ready) "unknown" else if (user_exists) "exists" else "missing",
        },
    ) catch return;
    agent.pushInfoOwned(m, files);
    agent.pushInfoOwned(m, gpa.dupe(u8, "  edit: add Tool(pattern) allow|deny|ask lines/objects under \"rules\"; legacy \"tools\"/\"bash\" arrays still work") catch return);
    agent.pushInfoOwned(m, gpa.dupe(u8, "  commands: /permissions reload  ·  /permissions add <Tool(pattern) allow|deny|ask>  ·  edit JSON files directly for full control") catch return);
}

/// `/hooks`: loaded hooks and the hooks file (35.11 panel).
///
/// Hooks are Phase 5 (command hooks). Shows what is loaded; editing is done in
/// `.zode/hooks.json`. Subcommand: `reload` re-reads hooks from disk.
pub fn cmdHooks(m: *tui.Model, arg: ?[]const u8) void {
    const gpa = m.allocator;
    if (arg) |a| {
        const sub = std.mem.trim(u8, a, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(sub, "reload")) {
            agent.loadHooks();
            agent.pushInfoOwned(m, gpa.dupe(u8, "hooks: reloaded from disk") catch return);
            // fall through to show current state
        } else if (sub.len > 0) {
            agent.pushInfoFmt(m, "hooks: unknown subcommand `{s}` (use: /hooks | /hooks reload)", .{sub});
            return;
        }
    }
    const set = agent.hooks_set;
    agent.pushInfoOwned(m, gpa.dupe(u8, "hooks  ·  Phase 5 command hooks (PreToolUse, PostToolUse, UserPromptSubmit, Stop, PermissionRequest)") catch return);
    var hpbuf: [640]u8 = undefined;
    const hooks_path = agent.resolvedProjectHooksPath(&hpbuf);
    const file_exists = if (m.io_ready) blk: {
        _ = std.Io.Dir.cwd().statFile(agent.io_global, hooks_path, .{}) catch break :blk false;
        break :blk true;
    } else false;
    const file_line = std.fmt.allocPrint(gpa, "  loaded from (effective project path): {s} ({s}; loaded on startup/reload)", .{ hooks_path, if (!m.io_ready) "unknown" else if (file_exists) "exists" else "missing" }) catch return;
    agent.pushInfoOwned(m, file_line);
    if (set.hooks.len == 0) {
        agent.pushInfoOwned(m, gpa.dupe(u8, "  (no hooks loaded)") catch return);
    } else {
        const count = std.fmt.allocPrint(gpa, "  loaded: {d}", .{set.hooks.len}) catch return;
        agent.pushInfoOwned(m, count);
        for (set.hooks) |h| {
            const matcher = if (h.matcher.len > 0) h.matcher else "*";
            const cond = if (h.@"if".len > 0) h.@"if" else "-";
            const once = if (h.once) " once" else "";
            const line = std.fmt.allocPrint(
                gpa,
                "  {s}  matcher={s}  if={s}  timeout={d}ms{s}  cmd={s}",
                .{ h.event.name(), matcher, cond, h.timeout_ms, once, h.command },
            ) catch continue;
            agent.pushInfoOwned(m, line);
        }
    }
    agent.pushInfoOwned(m, gpa.dupe(u8, "  contract: PreToolUse can block/update input; PostToolUse/UserPromptSubmit add context; PermissionRequest can allow/deny/ask (JSON stdout contract supported)") catch return);
    agent.pushInfoOwned(m, gpa.dupe(u8, "  commands: /hooks reload  ·  edit .zode/hooks.json directly for full control") catch return);
}

/// `/agents`: subagent definitions/status (35.11 panel).
///
/// Agent definitions on disk (Phase 9) and built-in roles (Phase 26) are not
/// implemented; this panel is honest and shows current subagent behavior.
pub fn cmdAgents(m: *tui.Model) void {
    const gpa = m.allocator;
    agent.pushInfoOwned(m, gpa.dupe(u8, "agents  ·  subagent/task configuration") catch return);
    agent.pushInfoOwned(m, gpa.dupe(u8, "  current: task subagent (general-purpose), depth 1, effort low, 24k budget, restricted/read-oriented tool set, no conversation history") catch return);
    agent.pushInfoOwned(m, gpa.dupe(u8, "  parallel cap: ZODE_TASK_PARALLEL (default 3; see env/config)") catch return);
    agent.pushInfoOwned(m, gpa.dupe(u8, "  definitions on disk (Phase 9): not implemented") catch return);
    agent.pushInfoOwned(m, gpa.dupe(u8, "  built-in roles explore/plan/verify (Phase 26): not implemented") catch return);
    agent.pushInfoOwned(m, gpa.dupe(u8, "  team mode (Phase 20): not implemented") catch return);
    agent.pushInfoOwned(m, gpa.dupe(u8, "  note: interactive agent editing is not implemented") catch return);
}

/// `/mcp`: MCP server configuration and status (35.13 panel, partial).
/// Shows configured servers without forcing connections; tools are discovered on demand.
pub fn cmdMcp(m: *tui.Model) void {
    const gpa = m.allocator;
    agent.pushInfoOwned(m, gpa.dupe(u8, "mcp  ·  MCP server configuration and status") catch return);
    agent.pushInfoFmt(m, "  manager: {s}", .{if (mcp_manager.isReady()) "ready" else "not initialized"});
    const servers = mcp_manager.configuredServers();
    if (servers.len == 0) {
        agent.pushInfo(m, "  servers: none configured (add `mcp_servers` in ~/.config/zode/config.json)");
    } else {
        agent.pushInfoFmt(m, "  servers: {d} configured", .{servers.len});
        for (servers) |s| {
            const cmd = if (s.command.len > 0) s.command[0] else "(no command)";
            agent.pushInfoFmt(m, "    - {s}  ({s}, {d} arg{s}, {d} env)", .{
                s.name,
                cmd,
                if (s.command.len > 1) s.command.len - 1 else 0,
                if (s.command.len == 2) "" else "s",
                s.env.len,
            });
        }
        agent.pushInfo(m, "  note: tool catalogs are discovered lazily on use (use the `mcp` tool to search/list/call)");
    }
}

/// `/sandbox`: sandbox availability for flagged bash commands (35.13 panel, partial).
pub fn cmdSandbox(m: *tui.Model) void {
    const path = agent.envGet(m.environ, "PATH");
    const kind = sandbox_mod.detect(agent.io_global, std.Io.Dir.cwd(), path);
    agent.pushInfoOwned(m, m.allocator.dupe(u8, "sandbox  ·  availability for flagged bash commands") catch return);
    switch (kind) {
        .none => {
            agent.pushInfo(m, "  detected: none (install bubblewrap `bwrap` or `firejail` to enable sandboxed runs)");
        },
        else => {
            agent.pushInfoFmt(m, "  detected: {s} ({s})", .{ kind.name(), sandbox_mod.binary(kind) });
            agent.pushInfo(m, "  behavior: optional sandboxed execution offered for flagged bash commands (project writable, rest read-only; no network isolation)");
        },
    }
    agent.pushInfo(m, "  note: sandbox is opt-in per command when offered by the permission dialog (not applied to every command)");
}

/// `/vim`: toggle vim keybindings for the input editor (35.13 / Phase 13).
pub fn cmdVim(m: *tui.Model) void {
    m.vim_mode = !m.vim_mode;
    m.vim_normal = false;
    m.vim_pending = 0;
    if (m.vim_mode) {
        // Start in insert mode to avoid surprising users mid-typing.
        agent.pushInfo(m, "vim mode: on (insert). Esc -> normal, i/a/... -> insert. /vim to disable.");
    } else {
        agent.pushInfo(m, "vim mode: off");
    }
}

/// `/add-dir <path>`: add an additional directory for this session (35.13).
/// Lists added directories when called without arguments.
pub fn cmdAddDir(m: *tui.Model, arg: ?[]const u8) void {
    const gpa = m.allocator;
    const trimmed = if (arg) |a| std.mem.trim(u8, a, " \t\r\n") else "";
    if (trimmed.len == 0) {
        if (m.extra_dirs.items.len == 0) {
            agent.pushInfo(m, "no additional directories added. usage: /add-dir <path>");
            return;
        }
        agent.pushInfoOwned(m, gpa.dupe(u8, "additional directories:") catch return);
        for (m.extra_dirs.items) |d| {
            agent.pushInfoFmt(m, "  - {s}", .{d});
        }
        return;
    }
    // Avoid duplicates.
    for (m.extra_dirs.items) |d| {
        if (std.mem.eql(u8, d, trimmed)) {
            agent.pushInfoFmt(m, "already added: {s}", .{trimmed});
            return;
        }
    }
    const copy = gpa.dupe(u8, trimmed) catch {
        agent.pushError(m, "could not add directory");
        return;
    };
    m.extra_dirs.append(gpa, copy) catch {
        gpa.free(copy);
        agent.pushError(m, "could not add directory");
        return;
    };
    agent.pushInfoFmt(m, "added directory: {s}", .{trimmed});
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

test "usage command shows the usage panel with token info" {
    agent.cacheSessionStatsForTest().* = .{};
    defer agent.cacheSessionStatsForTest().* = .{};
    agent.cacheSessionStatsForTest().record(.{ .prompt = 12_345, .cached = 10_000, .completion = 678 });

    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    cmdUsage(&m);

    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(std.testing.allocator);
    for (m.pending.items) |item| try all.appendSlice(std.testing.allocator, item.text);
    // The usage panel: version header, request totals, token breakdown.
    try std.testing.expect(std.mem.indexOf(u8, all.items, "usage") != null);
    try std.testing.expect(std.mem.indexOf(u8, all.items, "12,345") != null); // input tokens
    try std.testing.expect(std.mem.indexOf(u8, all.items, "678") != null); // output tokens
    try std.testing.expect(std.mem.indexOf(u8, all.items, "10,000") != null); // cache reads
    try std.testing.expect(std.mem.indexOf(u8, all.items, "requests") != null);
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

    if (std.ascii.eqlIgnoreCase(arg, "now")) {
        const s = agent.session orelse {
            agent.pushInfoOwned(m, "no active session: nothing to compact. Start a chat first.");
            return;
        };
        var astate = std.heap.ArenaAllocator.init(m.allocator);
        defer astate.deinit();
        const arena = astate.allocator();
        const msgs = agent.snapshotMsgs(arena);
        if (msgs.len == 0) {
            agent.pushInfoOwned(m, "session is empty: nothing to compact.");
            return;
        }
        const budget = compaction.budgetFor(m.environ, agent.curModelContext());
        const chosen_mode = if (m.compact_mode == null) compaction.mode(m.environ) else m.compact_mode.?;
        const comp: compaction.Compacted = compaction.elideTier(arena, msgs, budget, m.environ, agent.curModelContext(), chosen_mode) catch compaction.nothingElided(msgs);
        if (comp.elided == 0 and !comp.needs_summary) {
            agent.pushInfoOwned(m, std.fmt.allocPrint(m.allocator, "already under budget (est. {d} tokens vs budget {d}). Nothing to compact.", .{ compaction.estimateTokens(msgs), budget }) catch "compaction");
            return;
        }
        var applied: usize = 0;
        for (comp.elided_at) |idx| {
            if (idx >= s.messages.items.len) continue;
            const mm = &s.messages.items[idx];
            const new_text = comp.msgs[idx].content;
            if (std.mem.eql(u8, mm.content, new_text)) continue;
            const owned = s.allocator.dupe(u8, new_text) catch continue;
            s.allocator.free(mm.content);
            mm.content = owned;
            mm.tool_calls_json = null;
            applied += 1;
        }
        agent.session_elided = comp.elided;
        agent.pushInfoOwned(m, std.fmt.allocPrint(m.allocator, "compacted now: {d} result(s) elided (applied {d}), est. {d} tokens -> budget {d}.", .{ comp.elided, applied, compaction.estimateTokens(comp.msgs), budget }) catch "compaction");
        if (comp.needs_summary) {
            agent.pushInfoOwned(m, "after tier-1 elision still over budget: tier-2 (LLM summary) will run on the next turn.");
        }
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
            "unknown compaction mode '{s}': use off | elide | full | now | default (off = never compact, elide = free tier only, full = also summarize)",
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
/// Draws a horizontal progress bar: 20 cells wide, █ = filled, ░ = empty.
/// `pct` is 0..100. Returns the rendered bytes (no trailing newline).
fn renderProgressBar(pct: u8, out: []u8) []const u8 {
    const filled: usize = @min(@as(usize, 20), @as(usize, @intFromFloat(@as(f64, @floatFromInt(pct)) / 5.0)));
    var gi: usize = 0;
    var i: usize = 0;
    while (i < filled) : (i += 1) {
        if (gi + 3 > out.len) break;
        @memcpy(out[gi .. gi + 3], "█");
        gi += 3;
    }
    while (i < 20) : (i += 1) {
        if (gi + 3 > out.len) break;
        @memcpy(out[gi .. gi + 3], "░");
        gi += 3;
    }
    return out[0..gi];
}

/// `/status`: model, effort, style, permissions, key, and compaction with a
/// visual context gauge. The command you run to see "where am I right now".
pub fn cmdStatus(m: *tui.Model) void {
    const gpa = m.allocator;
    const cur_model = agent.curModel();
    const ctx = agent.curModelContext();
    const effort_label = chat.Effort.label(agent.current_effort);
    const style = if (agent.current_style) |s| s else "none";
    const perm = agent.permModeName();
    const key_state = if (agent.api_key_global) |_| "set" else "not set";
    const eff = compaction.effectiveMode(m.environ, m.compact_mode);
    const limit = compaction.contextLimitFor(m.environ, ctx);
    const budget = compaction.budgetFor(m.environ, ctx);
    const pct = compaction.targetPct(m.environ);

    var astate = std.heap.ArenaAllocator.init(m.allocator);
    defer astate.deinit();
    const msgs = agent.snapshotMsgs(astate.allocator());
    const used = compaction.estimateTokens(msgs);
    const pct_used: f64 = @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(@max(1, limit))) * 100.0;
    var gauge_buf: [64]u8 = undefined;
    const bar = renderProgressBar(@intFromFloat(@min(@as(f64, 100.0), @max(@as(f64, 0.0), pct_used))), &gauge_buf);

    agent.pushInfoOwned(m, std.fmt.allocPrint(gpa, "status  ·  zode {s}", .{build_options.version}) catch return);
    agent.pushInfoOwned(m, std.fmt.allocPrint(gpa, "  model:    {s}  (ctx {d})", .{ cur_model, ctx }) catch return);
    agent.pushInfoOwned(m, std.fmt.allocPrint(gpa, "  effort:   {s}  ·  style: {s}  ·  view: {s}", .{ effort_label, style, m.view_mode.name() }) catch return);
    agent.pushInfoOwned(m, std.fmt.allocPrint(gpa, "  perms:    {s}  ·  api key: {s}", .{ perm, key_state }) catch return);
    agent.pushInfoOwned(m, std.fmt.allocPrint(gpa, "  compact:  {s}  ·  limit {d}  ·  budget {d} ({d}%)", .{ @tagName(eff), limit, budget, pct }) catch return);
    agent.pushInfoOwned(m, std.fmt.allocPrint(gpa, "  context:  [{s}] ~{d}/{d} ({d:.1}% of limit)", .{ bar, used, limit, pct_used }) catch return);
    agent.pushInfoOwned(m, "");
}

/// `/config`: configuration that is actually in effect — env vars, compaction
/// thresholds, model source, limits. The command you run to verify "why is zode
/// using this number?".
pub fn cmdConfig(m: *tui.Model) void {
    const gpa = m.allocator;
    const ctx = agent.curModelContext();
    const limit = compaction.contextLimitFor(m.environ, ctx);
    const budget = compaction.budgetFor(m.environ, ctx);
    const pct = compaction.targetPct(m.environ);
    const eff = compaction.effectiveMode(m.environ, m.compact_mode);
    const bg_pct = compaction.bgPct(m.environ, ctx);
    const hot_pct = compaction.hotPct(m.environ, ctx);
    const src = compaction.limitSource(m.environ, ctx);

    agent.pushInfoOwned(m, std.fmt.allocPrint(gpa, "config  ·  zode {s}", .{build_options.version}) catch return);
    agent.pushInfoOwned(m, std.fmt.allocPrint(gpa, "  limit source:  {s}", .{
        switch (src) {
            .model => "the model's own context window",
            .env => "ZODE_CONTEXT_LIMIT",
            .default_ => "the 128k default",
        },
    }) catch return);
    agent.pushInfoOwned(m, std.fmt.allocPrint(gpa, "  limit:         {d} tokens", .{limit}) catch return);
    agent.pushInfoOwned(m, std.fmt.allocPrint(gpa, "  budget:        {d} tokens ({d}% of limit)", .{ budget, pct }) catch return);
    agent.pushInfoOwned(m, std.fmt.allocPrint(gpa, "  compact:       {s}  ({s})", .{
        @tagName(eff),
        if (m.compact_mode == null) "from ZODE_COMPACT" else "overridden with /compact",
    }) catch return);
    agent.pushInfoOwned(m, std.fmt.allocPrint(gpa, "  warm (bg):     {d}%  (ZODE_COMPACT_BG_PCT)", .{bg_pct}) catch return);
    agent.pushInfoOwned(m, std.fmt.allocPrint(gpa, "  hot (sync):    {d}%  (ZODE_COMPACT_HOT_PCT)", .{hot_pct}) catch return);
    agent.pushInfoOwned(m, std.fmt.allocPrint(gpa, "  recent window: {d} messages  (ZODE_RECENT_WINDOW)", .{compaction.recentWindow(m.environ)}) catch return);
    agent.pushInfoOwned(m, "");
}

/// `/usage`: unified pretty panel (tokens + cache + cost chord).
pub fn cmdUsage(m: *tui.Model) void {
    const gpa = m.allocator;
    const st = agent.cacheSessionStats();
    const input = @max(st.prompt_tokens, 0);
    const output = @max(st.completion_tokens, 0);
    const total = input +| output;
    const cached = @min(@max(st.cached_tokens, 0), input);
    const requests: i64 = @intCast(st.requests);
    const hit = st.hitRatePct();
    const bar = usageBar(hit);
    var total_buf: [32]u8 = undefined;
    var input_buf: [32]u8 = undefined;
    var output_buf: [32]u8 = undefined;
    var cached_buf: [32]u8 = undefined;

    agent.pushInfoOwned(m, std.fmt.allocPrint(gpa, "usage  ·  zode {s}", .{build_options.version}) catch return);
    agent.pushInfoOwned(m, std.fmt.allocPrint(gpa, "  requests:  {d}", .{requests}) catch return);
    agent.pushInfoOwned(m, std.fmt.allocPrint(gpa, "  tokens:    {s} total  (input {s}, output {s})", .{
        formatTokenCount(&total_buf, total),
        formatTokenCount(&input_buf, input),
        formatTokenCount(&output_buf, output),
    }) catch return);
    agent.pushInfoOwned(m, std.fmt.allocPrint(gpa, "  cache:     {s}  {s}  {d:.1}%", .{
        formatTokenCount(&cached_buf, cached),
        bar,
        hit,
    }) catch return);
    if (m.reads.stats.hits > 0 or m.reads.stats.misses > 0) {
        agent.pushInfoOwned(m, std.fmt.allocPrint(gpa, "  read:      {d} re-reads avoided  ·  ~{d} KB", .{
            m.reads.stats.hits,
            m.reads.stats.saved / 1024,
        }) catch return);
    }
    agent.pushInfoOwned(m, std.fmt.allocPrint(gpa, "  elided:    {d} tool results", .{agent.session_elided}) catch return);
    agent.pushInfoOwned(m, gpa.dupe(u8, "  next:      /cost per-model  ·  /cache verdict") catch return);
    agent.pushInfoOwned(m, "");
}

fn usageBar(pct: f64) []const u8 {
    if (pct >= 80) return "▓▓▓▓▓";
    if (pct >= 40) return "▓▓▓░░";
    if (pct > 0) return "▓░░░░";
    return "░░░░░";
}

/// `/goal` on its own would have to invent a task, and a prompt like "make the package
/// weigh under 10 KB" alone is not yet a task — it is a goal.
///
/// With `clear` it drops one.
///
/// With NO argument it reports, because a goal you cannot see is a goal you cannot
/// tell the model apart from: "why did it stop" is unanswerable unless the objective is
/// on screen with its state.
/// `/doctor`: one-screen diagnosis of why zode is behaving the way it is.
/// Mode, yolo, read-only, api key, sessions, compaction state — everything
/// that explains "why did zode do that?".
pub fn cmdDoctor(m: *tui.Model) void {
    const gpa = m.allocator;
    const eff = compaction.effectiveMode(m.environ, m.compact_mode);
    const budget = compaction.budgetFor(m.environ, agent.curModelContext());
    const pct = compaction.targetPct(m.environ);

    agent.pushInfoOwned(m, std.fmt.allocPrint(gpa, "doctor  ·  zode {s}", .{build_options.version}) catch return);
    agent.pushInfoOwned(m, std.fmt.allocPrint(gpa, "  mode:      {s}", .{agent.permModeName()}) catch return);
    agent.pushInfoOwned(m, std.fmt.allocPrint(gpa, "  compact:   {s} at {d}% (budget {d} tokens)", .{
        @tagName(eff), pct, budget,
    }) catch return);
    agent.pushInfoOwned(m, std.fmt.allocPrint(gpa, "  flags:     yolo={s}  ·  read-only={s}  ·  accept-edits={s}", .{
        if (agent.yolo) "on" else "off",
        if (agent.read_only) "on" else "off",
        if (agent.accept_edits) "on" else "off",
    }) catch return);
    agent.pushInfoOwned(m, std.fmt.allocPrint(gpa, "  api key:   {s} (value never printed)", .{
        if (agent.api_key_global) |_| "set" else "not set",
    }) catch return);
    agent.pushInfoOwned(m, std.fmt.allocPrint(gpa, "  motion:    {s}  ·  view: {s}  ·  ticks={d}  ·  mascot repaints={d}", .{
        if (m.no_animation) "none" else if (m.reduced_motion) "reduced" else "full",
        m.view_mode.name(),
        m.motion_tick_count,
        m.mascot_motion_repaints,
    }) catch return);
    agent.pushInfoOwned(m, std.fmt.allocPrint(gpa, "  sessions:  dir={s}/  ·  elided this session={d}", .{
        session_mod.sessions_dir,
        agent.session_elided,
    }) catch return);
    agent.pushInfoOwned(m, "");
}

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

// Vocabulary bridge: `allow_rules` here are turn-scoped bash allow patterns
// (zode `Bash(cmd *)` / spec-compatible `Bash(cmd:*)`; external specs may call
// these "always-allow command rules" / `alwaysAllowRules.command`). They map to
// `agent.turn_bash_allow_rules` for this turn only — not persisted `perm_rules`.
fn startGitPromptCommand(m: *tui.Model, prompt: []const u8, allow_rules: []const []const u8, extra: ?[]const u8) void {
    if (m.isBusy()) {
        m.pushError("wait for the current turn to finish before running this command");
        return;
    }
    var full = prompt;
    var owned: ?[]u8 = null;
    defer if (owned) |p| m.allocator.free(p);
    if (extra) |e| {
        const trimmed = std.mem.trim(u8, e, " \t\r\n");
        if (trimmed.len > 0) {
            owned = std.fmt.allocPrint(m.allocator, "{s}\n\n## User request\n{s}\n", .{ prompt, trimmed }) catch null;
            if (owned) |p| full = p;
        }
    }
    agent.startChatWithCmdRules(m, full, allow_rules) catch |err| {
        m.pushErrorFmt("could not start command: {t}", .{err});
    };
}

/// Phase 31: create a commit with verified git context and a scoped allowlist.
pub fn cmdCommit(m: *tui.Model, arg: ?[]const u8) void {
    startGitPromptCommand(m, gitcmds.commit_prompt, &gitcmds.commit_allow_rules, arg);
}

/// Phase 31: create/update a PR with merge-base diff and idempotent gh flow.
pub fn cmdPr(m: *tui.Model, arg: ?[]const u8) void {
    startGitPromptCommand(m, gitcmds.pr_prompt, &gitcmds.pr_allow_rules, arg);
}

/// Phase 31.2 naming: commit-push-PR workflow (uses PR allowlist asymmetry).
pub fn cmdCommitPushPr(m: *tui.Model, arg: ?[]const u8) void {
    startGitPromptCommand(m, gitcmds.pr_prompt, &gitcmds.pr_allow_rules, arg);
}

/// Phase 35.4: review current changes with verified git context.
pub fn cmdReview(m: *tui.Model, arg: ?[]const u8) void {
    startGitPromptCommand(m, gitcmds.review_prompt, &gitcmds.review_allow_rules, arg);
}

/// Phase 35.4: security-focused review of current changes.
pub fn cmdSecurityReview(m: *tui.Model, arg: ?[]const u8) void {
    startGitPromptCommand(m, gitcmds.security_review_prompt, &gitcmds.security_review_allow_rules, arg);
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
    // The facts block is context too, and it is the part compaction cannot
    // elide: it is re-attached verbatim. Showing the count (and the blockers
    // separately) is how a user knows why the model believes something.
    const facts_now = m.factsCopy();
    if (!facts_now.isEmpty()) {
        const lf = std.fmt.allocPrint(
            m.allocator,
            "  facts: {d} verified ({d} blocker{s}) · attached after the cached prefix, dropped when a source changes",
            .{ facts_now.len, facts_now.countKind(.blocker), if (facts_now.countKind(.blocker) == 1) "" else "s" },
        ) catch "facts";
        agent.pushInfoOwned(m, lf);
    }
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

    // Price/usage: what this session has spent, per model, shown next to the
    // token gauge. `/cost` owns the detailed per-model table; this is the
    // compact summary that fits in the context dashboard (34.16).
    const tr = &cost_mod.session;
    if (tr.len > 0) {
        const a = astate.allocator();
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
        const st = agent.cacheSessionStats();
        if (cost_mod.costSummaryText(m.allocator, rows.items, st.requests, st.prompt_tokens)) |text| {
            agent.pushInfoOwned(m, text);
        } else |err| {
            m.pushErrorFmt("could not build the cost summary: {s}", .{@errorName(err)});
        }
    }

    agent.refreshContextUsage(m);
}

/// `/session`: open a modal picker of this project's sessions, newest first.
/// Enter resumes; F2 renames (sets the custom title that wins in the list).
/// Only sessions that belong to THIS project are shown (29.6): sessions
/// from other projects never leak into this project's list.
pub fn cmdSession(m: *tui.Model) void {
    if (!m.io_ready) {
        agent.pushInfo(m, "session: I/O not ready");
        return;
    }
    const gpa = m.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const project_root = agent.project_info.root() orelse agent.project_info.cwd();

    const all_sessions = sessionindex.scan(arena, agent.io_global, session_mod.sessions_dir);

    // Filter: only sessions that belong to this project (29.6).
    var owned_count: usize = 0;
    for (all_sessions) |s| {
        if (sessionpath.sessionBelongsToProject(arena, agent.io_global, agent.environ_global, project_root, s.path)) {
            owned_count += 1;
        }
    }

    if (owned_count == 0) {
        agent.pushInfo(m, "no sessions in this project yet");
        return;
    }

    // Free any entries left from a previous picker open.
    for (m.session_picker_entries.items) |e| {
        gpa.free(e.path);
        if (e.name.len > 0) gpa.free(e.name);
        if (e.model.len > 0) gpa.free(e.model);
        if (e.custom_title.len > 0) gpa.free(e.custom_title);
        if (e.ai_title.len > 0) gpa.free(e.ai_title);
        if (e.first_prompt.len > 0) gpa.free(e.first_prompt);
        if (e.last_prompt.len > 0) gpa.free(e.last_prompt);
        if (e.agent_name.len > 0) gpa.free(e.agent_name);
    }
    m.session_picker_entries.deinit(gpa);
    m.session_picker_entries = .empty;

    // Free any paths left from a previous picker open. The strings are owned
    // by the picker (pickerRefilter rebuilds them), so free each one; a bare
    // deinit leaked on every /session open.
    for (m.session_picker_paths.items) |p| gpa.free(p);
    m.session_picker_paths.deinit(gpa);
    m.session_picker_paths = .empty;

    const owned = gpa.alloc(sessionindex.Entry, owned_count) catch {
        agent.pushInfo(m, "cannot open session picker");
        return;
    };
    defer gpa.free(owned);

    var idx: usize = 0;
    for (all_sessions) |s| {
        if (sessionpath.sessionBelongsToProject(arena, agent.io_global, agent.environ_global, project_root, s.path)) {
            // Deep-copy the entry into gpa-owned strings (arena dies after cmdSession).
            const e = sessionindex.Entry{
                .path = gpa.dupe(u8, s.path) catch "",
                .name = gpa.dupe(u8, s.name) catch "",
                .model = gpa.dupe(u8, s.model) catch "",
                .custom_title = gpa.dupe(u8, s.custom_title) catch "",
                .ai_title = gpa.dupe(u8, s.ai_title) catch "",
                .created_at = s.created_at,
                .first_prompt = gpa.dupe(u8, s.first_prompt) catch "",
                .last_prompt = gpa.dupe(u8, s.last_prompt) catch "",
                .agent_name = gpa.dupe(u8, s.agent_name) catch "",
                .size_bytes = s.size_bytes,
            };
            if (e.path.len == 0) continue;
            _ = m.session_picker_entries.append(gpa, e) catch {};
            if (idx >= owned_count) {
                gpa.free(e.path);
                if (e.name.len > 0) gpa.free(e.name);
                if (e.model.len > 0) gpa.free(e.model);
                if (e.custom_title.len > 0) gpa.free(e.custom_title);
                if (e.ai_title.len > 0) gpa.free(e.ai_title);
                if (e.first_prompt.len > 0) gpa.free(e.first_prompt);
                if (e.last_prompt.len > 0) gpa.free(e.last_prompt);
                if (e.agent_name.len > 0) gpa.free(e.agent_name);
                continue;
            }
            owned[idx] = e;
            idx += 1;
        }
    }

    const owned_len = idx;

    const items = gpa.alloc(tui.PickerItem, owned_len) catch {
        agent.pushInfo(m, "cannot open session picker");
        return;
    };

    const now = std.Io.Timestamp.now(agent.io_global, .real).toSeconds();
    var buf: [64]u8 = undefined;
    for (owned[0..owned_len], 0..) |s, i| {
        const session_id = std.fs.path.basename(s.path);
        const title = s.title(session_id);
        const age = sessionindex.ageLabel(now, s.created_at, &buf);
        const is_cur = if (agent.session) |sess| sess.path != null and std.mem.eql(u8, s.path, sess.path.?) else false;
        const label_full = if (is_cur)
            (std.fmt.allocPrint(gpa, "{s}  (current)", .{title}) catch gpa.dupe(u8, title) catch "")
        else
            (gpa.dupe(u8, title) catch "");
        // 29.3/35.3: <relative time> · <size> · #tag (branch/count when available).
        var dbuf: [32]u8 = undefined;
        const size = if (s.size_bytes > 0) std.fmt.bufPrint(&dbuf, "{d} KB", .{s.size_bytes / 1024}) catch "" else "";
        const desc = if (s.tag.len > 0 and size.len > 0)
            (std.fmt.allocPrint(gpa, "{s} · {s} · #{s}", .{ age, size, s.tag }) catch gpa.dupe(u8, age) catch "")
        else if (s.tag.len > 0)
            (std.fmt.allocPrint(gpa, "{s} · #{s}", .{ age, s.tag }) catch gpa.dupe(u8, age) catch "")
        else if (size.len > 0)
            (std.fmt.allocPrint(gpa, "{s} · {s}", .{ age, size }) catch gpa.dupe(u8, age) catch "")
        else
            (gpa.dupe(u8, age) catch "");
        items[i] = .{ .label = label_full, .desc = desc };
    }

    var tbuf: [64]u8 = undefined;
    const ptitle = std.fmt.bufPrint(&tbuf, "Resume ({d} sessions)", .{owned_len}) catch "Resume";
    // openPickerIdxRename copies the title into the model's fixed buffer.
    m.openPickerIdxRename(
        tui.sessions_picker_tag,
        ptitle,
        items,
        agent.onSessionPick,
        null,
        agent.onSessionRename,
    );
}

/// `/rename <name>`: set a custom title and/or tag for the current session.
/// Forms: `/rename <title>`, `/rename #tag`, `/rename <title> #tag`.
/// Custom title wins over AI titles/session IDs in the session list; tag is
/// shown as `#tag` in the session picker. Persisted to the Meta sidecar.
pub fn cmdRename(m: *tui.Model, arg: ?[]const u8) void {
    const name = arg orelse {
        agent.pushInfo(m, "usage: /rename <title> | /rename #tag | /rename <title> #tag");
        return;
    };
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed.len == 0) {
        agent.pushInfo(m, "rename: empty name");
        return;
    }

    var new_title: ?[]const u8 = null;
    var new_tag: ?[]const u8 = null;
    if (trimmed[0] == '#' and std.mem.indexOfAny(u8, trimmed, " \t\r\n") == null) {
        // Tag-only: `/rename #tag` (or `#` to clear).
        const t = std.mem.trim(u8, trimmed[1..], " \t\r\n");
        new_tag = t;
    } else if (std.mem.lastIndexOfScalar(u8, trimmed, '#')) |hash| blk: {
        if (hash > 0 and (trimmed[hash - 1] == ' ' or trimmed[hash - 1] == '\t')) {
            const t = std.mem.trim(u8, trimmed[hash + 1 ..], " \t\r\n");
            if (t.len > 0 and std.mem.indexOfAny(u8, t, " \t\r\n") == null) {
                new_title = std.mem.trim(u8, trimmed[0..hash], " \t\r\n");
                new_tag = t;
                break :blk;
            }
        }
        new_title = trimmed;
    } else {
        new_title = trimmed;
    }

    if (new_title) |t| {
        if (t.len == 0) {
            agent.pushInfo(m, "rename: empty title");
            return;
        }
        if (t.len > 64) {
            agent.pushInfo(m, "rename: title too long (max 64 chars)");
            return;
        }
    }
    if (new_tag) |t| {
        if (t.len > 32) {
            agent.pushInfo(m, "rename: tag too long (max 32 chars)");
            return;
        }
    }

    const s = agent.session orelse {
        agent.pushInfo(m, "no session to rename");
        return;
    };

    if (new_title) |t| {
        if (s.custom_title.len > 0) s.allocator.free(s.custom_title);
        s.custom_title = s.allocator.dupe(u8, t) catch {
            agent.pushInfo(m, "rename: out of memory");
            return;
        };
    }
    if (new_tag) |t| {
        if (s.tag.len > 0) s.allocator.free(s.tag);
        s.tag = if (t.len == 0) "" else (s.allocator.dupe(u8, t) catch {
            agent.pushInfo(m, "rename: out of memory");
            return;
        });
    }

    if (!m.io_ready) {
        agent.pushInfo(m, "renamed (I/O not ready to save)");
        return;
    }

    var arena_state = std.heap.ArenaAllocator.init(s.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const path = s.path orelse {
        agent.pushInfo(m, "rename: session has no path");
        return;
    };
    const meta = sessionindex.readMeta(arena, agent.io_global, path);
    sessionindex.writeMeta(agent.io_global, arena, path, .{
        .name = meta.name,
        .model = meta.model,
        .created_at = meta.created_at,
        .custom_title = s.custom_title,
        .ai_title = meta.ai_title,
        .tag = s.tag,
    }) catch |err| {
        agent.pushInfoFmt(m, "rename: could not save: {s}", .{@errorName(err)});
        return;
    };

    if (new_title != null and new_tag != null) {
        if (s.tag.len > 0)
            agent.pushInfoFmt(m, "renamed to \"{s}\" #{s}", .{ s.custom_title, s.tag })
        else
            agent.pushInfoFmt(m, "renamed to \"{s}\"", .{s.custom_title});
    } else if (new_title != null) {
        agent.pushInfoFmt(m, "renamed to \"{s}\"", .{s.custom_title});
    } else if (s.tag.len > 0) {
        agent.pushInfoFmt(m, "session tag set to #{s}", .{s.tag});
    } else {
        agent.pushInfo(m, "session tag cleared");
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
            var idx: [readcache.max_entries_physical]usize = undefined;
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
        report.addSection("Changed files (this session)") catch {};
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
    // Turn-scoped honest net diff summary (real baseline->after stats).
    m.pushTurnFileSummary();
}

fn runGitCapture(arena: std.mem.Allocator, argv: []const []const u8, limit: usize) ?[]const u8 {
    const r = std.process.run(arena, agent.io_global, .{
        .argv = argv,
        .stdout_limit = .limited(limit),
        .stderr_limit = .limited(64 * 1024),
        .reserve_amount = 4096,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(20), .clock = .awake } },
    }) catch return null;
    return switch (r.term) {
        .exited => |code| if (code == 0) r.stdout else blk: {
            if (std.mem.indexOf(u8, r.stderr, "not a git repository") != null or
                std.mem.indexOf(u8, r.stdout, "not a git repository") != null)
                break :blk null;
            // git diff can exit 1 in some cases (e.g. --exit-code not used) but
            // usually 0; if it produced output, show it.
            break :blk if (r.stdout.len > 0) r.stdout else null;
        },
        else => null,
    };
}

/// `/diff [next|prev]`: uncommitted changes and the current turn's changed-file
/// diff, or navigate between diff blocks in the timeline.
/// `/inspect [context|git|session]`: read-only workbench inspector (Phase 5).
/// Presentation layer over shared runtime state; never invents state/stats.
pub fn cmdInspect(m: *tui.Model, arg: ?[]const u8) void {
    const gpa = m.allocator;
    const a = std.mem.trim(u8, arg orelse "", " \t\r\n");
    if (std.ascii.eqlIgnoreCase(a, "git")) {
        cmdGit(m, null);
        return;
    }
    if (std.ascii.eqlIgnoreCase(a, "context")) {
        cmdContext(m);
        return;
    }
    if (std.ascii.eqlIgnoreCase(a, "session")) {
        if (agent.session) |s| {
            const id = if (s.path) |p| std.fs.path.basename(p) else "(no path)";
            agent.pushInfoFmt(m, "Inspect  ·  Session  {s}", .{id});
            if (s.custom_title.len > 0) agent.pushInfoFmt(m, "  Title  {s}", .{s.custom_title});
            agent.pushInfoFmt(m, "  Messages  {d}", .{s.messages.items.len});
            agent.pushInfo(m, "  Details  /session, /resume, /rename");
        } else {
            agent.pushInfo(m, "Inspect  ·  Session  none active (/session, /resume)");
        }
        return;
    }
    if (a.len > 0) {
        agent.pushInfo(m, "usage: /inspect | /inspect context|git|session");
        return;
    }

    // Unified workbench overview (runtime-truth only).
    agent.pushInfoOwned(m, std.fmt.allocPrint(gpa, "Inspect  ·  Workbench overview  (zode {s})", .{build_options.version}) catch return);
    const motion: []const u8 = if (m.no_animation) "none" else if (m.reduced_motion) "reduced" else "full";
    agent.pushInfoFmt(m, "  Model  {s}  ·  Perms  {s}  ·  Motion  {s}  ·  View  {s}", .{ agent.curModel(), agent.permModeName(), motion, m.view_mode.name() });

    // Context (honest estimate, same basis as /context).
    _ = agent.ensureSession(m, gpa);
    var astate = std.heap.ArenaAllocator.init(gpa);
    defer astate.deinit();
    const msgs = agent.snapshotMsgs(astate.allocator());
    const used = compaction.estimateTokens(msgs);
    const limit = compaction.contextLimitFor(m.environ, agent.curModelContext());
    const budget = compaction.budgetFor(m.environ, agent.curModelContext());
    const pct = if (limit > 0) @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(limit)) * 100.0 else 0.0;
    agent.pushInfoFmt(m, "  Context  ~{d}/{d} tokens ({d:.1}%)  ·  budget {d}  ·  {d} turn(s)", .{
        used, limit, pct, budget, if (msgs.len > 0) msgs.len - 1 else 0,
    });

    // Git (best-effort, read-only).
    if (m.io_ready) {
        var garena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer garena.deinit();
        const ga = garena.allocator();
        const branch = runGitCapture(ga, &.{ "git", "--no-optional-locks", "rev-parse", "--abbrev-ref", "HEAD" }, 4096);
        const st = runGitCapture(ga, &.{ "git", "--no-optional-locks", "-c", "core.quotepath=false", "status", "--short" }, 64 * 1024);
        if (branch) |b| {
            const bt = std.mem.trim(u8, b, " \t\r\n");
            var changes: usize = 0;
            if (st) |s| {
                const stt = std.mem.trim(u8, s, " \t\r\n");
                if (stt.len > 0) {
                    var it = std.mem.splitScalar(u8, stt, '\n');
                    while (it.next()) |_| changes += 1;
                }
            }
            if (changes == 0)
                agent.pushInfoFmt(m, "  Git  {s}  ·  clean", .{bt})
            else
                agent.pushInfoFmt(m, "  Git  {s}  ·  {d} changed path(s)", .{ bt, changes });
        } else {
            agent.pushInfo(m, "  Git  not a repository (or git unavailable)");
        }
    } else {
        agent.pushInfo(m, "  Git  (I/O not ready)");
    }

    // Session/file focus (honest).
    if (agent.session) |s| {
        const id = if (s.path) |p| std.fs.path.basename(p) else "(active)";
        agent.pushInfoFmt(m, "  Session  {s}", .{id});
    }
    if (m.lastChangedFile()) |p| agent.pushInfoFmt(m, "  File  last changed  {s}", .{p});

    switch (m.view_mode) {
        .review => agent.pushInfo(m, "  Details  /diff /hunk /files /file /code-review /git  ·  /context /status /session"),
        .flow => agent.pushInfo(m, "  Details  /context /status /session  ·  /git /diff /files"),
        .focus => agent.pushInfo(m, "  Details  /status /context /session (focus view; runtime state unchanged)"),
        .normal => agent.pushInfo(m, "  Details  /context /status /config /usage /cache /doctor /git /diff /files /session"),
    }
}

/// `/view [normal|focus|flow|review]`: workbench presentation mode (Phase 5).
/// Presentation layer only; does not change runtime/permission/tool behavior.
pub fn cmdView(m: *tui.Model, arg: ?[]const u8) void {
    const a = std.mem.trim(u8, arg orelse "", " \t\r\n");
    if (a.len == 0) {
        agent.pushInfoFmt(m, "View mode: {s}  ·  {s}", .{ m.view_mode.name(), m.view_mode.desc() });
        agent.pushInfo(m, "  usage: /view normal|focus|flow|review");
        return;
    }
    const mode: tui.ViewMode = if (std.ascii.eqlIgnoreCase(a, "normal") or std.ascii.eqlIgnoreCase(a, "off"))
        .normal
    else if (std.ascii.eqlIgnoreCase(a, "focus"))
        .focus
    else if (std.ascii.eqlIgnoreCase(a, "flow"))
        .flow
    else if (std.ascii.eqlIgnoreCase(a, "review"))
        .review
    else {
        agent.pushInfo(m, "usage: /view normal|focus|flow|review");
        return;
    };
    m.view_mode = mode;
    m.redraw_requested.store(true, .seq_cst);
    agent.pushInfoFmt(m, "View mode: {s}  ·  {s}", .{ mode.name(), mode.desc() });
}

/// `/github`: GitHub integration status and context (local, read-only).
/// Shows resolved repo/host, auth token source (never the token), and how to
/// use the native `github` tool for remote operations.
pub fn cmdGithub(m: *tui.Model, arg: ?[]const u8) void {
    const a = std.mem.trim(u8, arg orelse "", " \t\r\n");
    if (a.len > 0 and !std.ascii.eqlIgnoreCase(a, "status") and !std.ascii.eqlIgnoreCase(a, "help")) {
        agent.pushInfo(m, "usage: /github [status|help]");
        return;
    }

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const remote = if (m.io_ready) github_lib.context.resolve(arena, agent.io_global) else null;
    const host: []const u8 = if (remote) |r| r.host else "github.com";
    const auth = github_lib.api.resolveToken(arena, agent.io_global, agent.environ_global, host);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(m.allocator);
    out.appendSlice(m.allocator, "GitHub integration (native, local status)\n") catch return;
    if (remote) |r| {
        out.print(m.allocator, "  repo     {s}/{s}\n", .{ r.owner, r.repo }) catch return;
        out.print(m.allocator, "  host     {s}\n", .{r.host}) catch return;
        if (r.url.len > 0) out.print(m.allocator, "  remote   {s}\n", .{r.url}) catch return;
    } else {
        out.appendSlice(m.allocator, "  repo     unresolved from git remotes\n") catch return;
        out.print(m.allocator, "  host     {s} (default)\n", .{host}) catch return;
    }
    if (m.io_ready) {
        if (github_lib.context.currentBranch(arena, agent.io_global)) |b| {
            out.print(m.allocator, "  branch   {s}\n", .{b}) catch return;
        }
    }
    out.print(m.allocator, "  auth     {s} (source: {s})\n", .{ if (auth.token != null) "configured" else "not configured", auth.source }) catch return;
    if (auth.token == null) {
        out.appendSlice(m.allocator, "  hint     set GITHUB_TOKEN or GH_TOKEN, or store token in ~/.config/zode/auth.json as \"github\" / \"github:<host>\"\n") catch return;
    } else {
        out.appendSlice(m.allocator, "  note     token value is never shown; verify with `github` op `whoami`\n") catch return;
    }
    out.appendSlice(m.allocator, "  tool     `github` (structured gateway, native-first for supported remote ops)\n") catch return;
    out.appendSlice(m.allocator, "  reads    auth_status, whoami, repo, pr_list, pr_view, pr_checks, issue_list, issue_view, actions_runs\n") catch return;
    out.appendSlice(m.allocator, "  writes   pr_create, pr_update, pr_comment, issue_create, issue_comment (permission per op)\n") catch return;
    out.appendSlice(m.allocator, "  flows    /pr and /commit-push-pr prefer native `github` ops; `gh`/CLI fallback when needed\n") catch return;
    if (std.ascii.eqlIgnoreCase(a, "help")) {
        out.appendSlice(m.allocator, "  examples github auth_status | github repo | github pr_list state=open | github pr_view number=123\n") catch return;
    }

    const owned = m.allocator.dupe(u8, std.mem.trimEnd(u8, out.items, "\n")) catch return;
    agent.pushInfoOwned(m, owned);
}

/// `/git`: read-only Git overview (Phase 5 foundation). No destructive actions.
pub fn cmdGit(m: *tui.Model, arg: ?[]const u8) void {
    const a = std.mem.trim(u8, arg orelse "", " \t\r\n");
    if (a.len > 0) {
        agent.pushInfo(m, "usage: /git (read-only overview: branch, status, recent commits)");
        return;
    }
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const branch = runGitCapture(arena, &.{ "git", "--no-optional-locks", "rev-parse", "--abbrev-ref", "HEAD" }, 4096);
    const status = runGitCapture(arena, &.{ "git", "--no-optional-locks", "-c", "core.quotepath=false", "status", "--short" }, 64 * 1024);
    const log = runGitCapture(arena, &.{ "git", "--no-optional-locks", "log", "--oneline", "-n", "5", "--decorate" }, 16 * 1024);

    if (branch == null and status == null and log == null) {
        agent.pushInfo(m, "Git: not a repository (or git is not available)");
        return;
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(m.allocator);
    out.appendSlice(m.allocator, "Git  ·  read-only overview\n") catch return;
    if (branch) |b| {
        const bt = std.mem.trim(u8, b, " \t\r\n");
        out.print(m.allocator, "  Branch  {s}\n", .{bt}) catch return;
    }
    if (status) |s| {
        const st = std.mem.trim(u8, s, " \t\r\n");
        if (st.len == 0) {
            out.appendSlice(m.allocator, "  Status  working tree clean\n") catch return;
        } else {
            out.appendSlice(m.allocator, "  Status\n") catch return;
            var lines: usize = 0;
            var it = std.mem.splitScalar(u8, st, '\n');
            while (it.next()) |line| {
                if (lines >= 40) {
                    out.appendSlice(m.allocator, "    … (more changes; use /diff)\n") catch break;
                    break;
                }
                out.print(m.allocator, "    {s}\n", .{line}) catch break;
                lines += 1;
            }
        }
    }
    if (log) |l| {
        const lt = std.mem.trim(u8, l, " \t\r\n");
        if (lt.len > 0) {
            out.appendSlice(m.allocator, "  Recent\n") catch return;
            var it = std.mem.splitScalar(u8, lt, '\n');
            while (it.next()) |line| {
                out.print(m.allocator, "    {s}\n", .{line}) catch break;
            }
        }
    }
    out.appendSlice(m.allocator, "  Actions  /diff (changes), /code-review (read-only analysis). No destructive git actions.") catch {};
    const owned = m.allocator.dupe(u8, std.mem.trimEnd(u8, out.items, "\n")) catch return;
    agent.pushInfoOwned(m, owned);
}

pub fn cmdDiff(m: *tui.Model, arg: ?[]const u8) void {
    const a = std.mem.trim(u8, arg orelse "", " \t\r\n");
    if (std.mem.eql(u8, a, "next") or std.mem.eql(u8, a, "n")) {
        _ = m.navigateDiff(1);
        return;
    }
    if (std.mem.eql(u8, a, "prev") or std.mem.eql(u8, a, "p") or std.mem.eql(u8, a, "previous")) {
        _ = m.navigateDiff(-1);
        return;
    }
    if (a.len > 0) {
        agent.pushInfo(m, "usage: /diff | /diff next|prev");
        return;
    }
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const status = runGitCapture(arena, &.{ "git", "--no-optional-locks", "-c", "core.quotepath=false", "status", "--short", "--branch" }, 64 * 1024) orelse {
        agent.pushInfo(m, "diff: not a git repository (or git is not available)");
        return;
    };

    var header: std.ArrayList(u8) = .empty;
    defer header.deinit(m.allocator);
    header.appendSlice(m.allocator, "diff · uncommitted changes") catch return;
    const st = std.mem.trim(u8, status, " \t\r\n");
    if (st.len > 0) {
        header.append(m.allocator, '\n') catch return;
        header.appendSlice(m.allocator, st) catch return;
    } else {
        header.appendSlice(m.allocator, "\nworking tree clean (nothing staged or modified).") catch return;
    }
    const header_owned = m.allocator.dupe(u8, header.items) catch return;
    agent.pushInfoOwned(m, header_owned);

    if (runGitCapture(arena, &.{ "git", "--no-optional-locks", "-c", "core.quotepath=false", "diff", "--no-color", "-U3", "HEAD" }, 512 * 1024)) |diff| {
        const trimmed = std.mem.trim(u8, diff, " \t\r\n");
        if (trimmed.len > 0) {
            agent.pushInfo(m, "uncommitted (vs HEAD):");
            m.pushKind(md.Kind.diff, trimmed);
        }
    }

    const turn_files = agent.turn_stats.files.items;
    if (turn_files.len > 0) {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(arena);
        argv.appendSlice(arena, &.{ "git", "--no-optional-locks", "-c", "core.quotepath=false", "diff", "--no-color", "-U3", "HEAD", "--" }) catch {};
        for (turn_files) |f| argv.append(arena, f) catch {};
        if (runGitCapture(arena, argv.items, 512 * 1024)) |tdiff| {
            const ttrim = std.mem.trim(u8, tdiff, " \t\r\n");
            if (ttrim.len > 0) {
                agent.pushInfoFmt(m, "files  ·  this turn vs HEAD  ·  {d} file(s)", .{turn_files.len});
                m.pushKind(md.Kind.diff, ttrim);
            } else {
                agent.pushInfoFmt(m, "files  ·  this turn  ·  {d} file(s) touched, diff vs HEAD is empty", .{turn_files.len});
            }
        }
    }
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
    .{ .key = "ctrl+v", .desc = "attach the clipboard image to your next message" },
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
    .{ .key = "/model", .desc = "pick a model in a modal", .key_hint = "ctrl+p" },
    .{ .key = "/provider", .desc = "pick a provider in a modal" },
    .{ .key = "/providers", .desc = "list providers" },
    .{ .key = "/effort", .desc = "none|minimal|low|medium|high|xhigh (no args: picker)" },
    .{ .key = "/diff-color", .desc = "the diff palette: default | daltonized (alias: /color, no args: picker)" },
    .{ .key = "/submodel", .desc = "which model the SUBAGENTS use (no args: report | <model> | <provider> <model> | off)" },
    .{ .key = "/task-parallel", .desc = "simultaneous subagent limit: 1..8 | auto", .key_hint = "1..8 | auto", .palette_visible = false },
    .{ .key = "/reload-cmds", .desc = "reload user commands from disk", .palette_visible = false },
    .{ .key = "/which-cmd", .desc = "show where a user command comes from", .key_hint = "name", .palette_visible = false },
    .{ .key = "/free-auto", .desc = "rotate the FREE models of every provider you have a key for, and keep going when one runs out" },
    .{ .key = "/goal", .desc = "set the objective the turn may not stop short of", .key_hint = "<objetivo> | clear" },
    .{ .key = "/init", .desc = "analyse the codebase and write AGENTS.md" },
    .{ .key = "/commit", .desc = "create a git commit with verified context (scoped git allowlist)", .key_hint = "[instructions]" },
    .{ .key = "/pr", .desc = "create or update a PR with merge-base diff (idempotent, scoped allowlist)", .key_hint = "[instructions]" },
    .{ .key = "/commit-push-pr", .desc = "commit + push + PR workflow (PR allowlist; alias of /pr flow)", .key_hint = "[instructions]" },
    .{ .key = "/review", .desc = "review current changes with verified git context (read-only)", .key_hint = "[focus]" },
    .{ .key = "/security-review", .desc = "security-focused review of current changes (read-only)", .key_hint = "[focus]" },
    .{ .key = "/iter", .desc = "iteration budget: /iter [n] (min 8, max 200) or /iter to show current" },
    .{ .key = "/undo", .desc = "restore the files the last turn changed" },
    .{ .key = "/rewind", .desc = "undo the last N turns' file changes: /rewind | /rewind N", .key_hint = "N" },
    .{ .key = "/rewind", .desc = "undo the last N turns' file changes: /rewind | /rewind N", .key_hint = "N" },
    .{ .key = "/clean", .desc = "purge zode leftovers (dry run; /clean yes applies)", .palette_visible = false },
    .{ .key = "/yolo", .desc = "bypass: allow everything, ask nothing (your questions are answered for you and said in the summary)" },
    .{ .key = "/mode", .desc = "set work mode: build | accept-edits | plan | bypass" },
    .{ .key = "/allowlist", .desc = "always-allowed tools + bash (persisted)" },
    .{ .key = "/permissions", .desc = "permission rules, mode, allowlist, and file status (panel; /permissions reload)" },
    .{ .key = "/hooks", .desc = "loaded command hooks and file status (panel; /hooks reload)" },
    .{ .key = "/agents", .desc = "subagent/task status and definitions (panel)" },
    .{ .key = "/mcp", .desc = "MCP server configuration and status (panel)" },
    .{ .key = "/sandbox", .desc = "sandbox availability for flagged bash commands (panel)" },
    .{ .key = "/add-dir", .desc = "add/list additional directories for this session: /add-dir [path]", .key_hint = "[path]" },
    .{ .key = "/vim", .desc = "toggle vim keybindings for the input editor" },
    .{ .key = "/bg", .desc = "background commands: list | kill <id> | killall", .palette_visible = false },
    .{ .key = "/new-session", .desc = "new session" },
    .{ .key = "/branch", .desc = "fork the current session into a new branch", .key_hint = "[title]" },
    .{ .key = "/resume", .desc = "resume the last session" },
    .{ .key = "/context", .desc = "tokens used vs budget, and what compaction will do" },
    .{ .key = "/inspect", .desc = "workbench inspector (runtime-truth): overview | context|git|session", .key_hint = "context|git|session", .palette_visible = true },
    .{ .key = "/view", .desc = "workbench view mode (presentation only): normal|focus|flow|review", .key_hint = "normal|focus|flow|review", .palette_visible = true },
    .{ .key = "/doctor", .desc = "diagnosis: model, effort, style, permissions, key, compaction, sessions" },
    .{ .key = "/config", .desc = "effective configuration: limits, budgets, compact thresholds, recent window" },
    .{ .key = "/status", .desc = "session status: model, effort, perms, compaction, context gauge", .key_hint = "context gauge" },
    .{ .key = "/usage", .desc = "session input/output tokens, cache, and request totals", .key_hint = "session totals" },
    .{ .key = "/cost", .desc = "what this session has cost, per model (USD, from the catalogue's prices)" },
    .{ .key = "/update", .desc = "install the newest release (says when one is available)" },
    .{ .key = "/compact", .desc = "off|elide|full|now: automatic compaction (no args: report, now = compact immediately)", .key_hint = "off|elide|full|now" },
    .{ .key = "/bench", .desc = "session numbers: turns, iterations, first-token times", .palette_visible = false },
    .{ .key = "/pipeline", .desc = "the staged pipeline for a task: evidence → implement → tester → verify → review", .key_hint = "<task>" },
    .{ .key = "/code-review", .desc = "read-only review of the changes: /code-review (diff) | /code-review <paths>", .key_hint = "[paths]" },
    .{ .key = "/session", .desc = "the sessions of this project, newest first (enter opens one)" },
    .{ .key = "/rename", .desc = "set session title and/or tag: /rename <title> | /rename #tag | /rename <title> #tag" },
    .{ .key = "/files", .desc = "the files the model has read, and the ones it changed" },
    .{ .key = "/file", .desc = "changed file intelligence: /file | list|show | next|prev | copy|open", .key_hint = "list|next|prev|copy|open" },
    .{ .key = "/diff", .desc = "uncommitted changes and this turn's changed-file diff" },
    .{ .key = "/git", .desc = "read-only Git overview (branch, status, recent commits)", .palette_visible = true },
    .{ .key = "/github", .desc = "GitHub integration status: repo/auth context and native `github` tool ops", .palette_visible = true },
    .{ .key = "/hunk", .desc = "navigate hunks in the last diff: /hunk next|prev (also alt+] / alt+[)", .key_hint = "next|prev" },
    .{ .key = "/cache", .desc = "cache hit-rate for this session", .palette_visible = false },
    .{ .key = "/ask", .desc = "on|off: enable Plan mode (Shift+Tab also cycles modes)" },
    .{ .key = "/skills", .desc = "list the loadable skills" },
    .{ .key = "/style", .desc = "select an output style: default|explanatory|learning (no args: report | off)" },
    .{ .key = "/dots", .desc = "on|off: prompt rail dots (click a dot to jump back to that prompt)" },
    .{ .key = "/copy", .desc = "copy an answer to the clipboard: /copy (the last one) | /copy N (N answers back)", .key_hint = "N" },
    .{ .key = "/btw", .desc = "side question (subagent, answer appended, not a turn)", .key_hint = "<question>" },
    .{ .key = "/quit", .desc = "quit", .key_hint = "ctrl+c" },
    .{ .key = "/clear", .desc = "clear the screen and reset the session caches (read list, changed list, skills)" },
    .{ .key = "/exit", .desc = "alias of /quit" },
    .{ .key = "/version", .desc = "show the running zode version" },
    .{ .key = "/release-notes", .desc = "show release notes for the running version (from CHANGELOG.md)" },
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
    try std.testing.expect(std.mem.indexOf(u8, text, "Nothing read or written") != null);
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

test "/update is offered in the palette, not hidden behind its name" {
    // A command the user cannot find is a command that does not exist: the
    // notice says "/update installs it", so the palette has to agree.
    var found = false;
    for (commands) |c| {
        if (!std.mem.eql(u8, c.key, "/update")) continue;
        found = true;
        try std.testing.expect(c.palette_visible);
        try std.testing.expect(std.mem.indexOf(u8, c.desc, "newest release") != null);
    }
    try std.testing.expect(found);
}

test "/doctor is in the command table" {
    var found = false;
    for (commands) |c| {
        if (!std.mem.eql(u8, c.key, "/doctor")) continue;
        found = true;
        try std.testing.expect(c.palette_visible);
        try std.testing.expect(std.mem.indexOf(u8, c.desc, "diagnosis") != null);
    }
    try std.testing.expect(found);
}

test "cmdDoctor runs without crashing and names itself" {
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    cmdDoctor(&m);

    const text = try pendingText(&m, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "doctor") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "mode:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "yolo") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "compact:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "sessions") != null);
}

test "/usage and /doctor are dispatched by submit, not just listed" {
    // A command can be in the table, have a function, and have a test on that
    // function, and still print nothing: `submit` has a branch per command and
    // a missing branch falls to the unknown-command handling. /doctor lived
    // like that — reachable from the palette's table, dead when typed.
    {
        var m = tui.Model.init(std.testing.allocator);
        defer m.deinit();
        try agent.submit(&m, "/usage");
        const text = try pendingText(&m, std.testing.allocator);
        defer std.testing.allocator.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, "usage") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "requests") != null);
    }
    {
        var m = tui.Model.init(std.testing.allocator);
        defer m.deinit();
        try agent.submit(&m, "/doctor");
        const text = try pendingText(&m, std.testing.allocator);
        defer std.testing.allocator.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, "doctor") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "yolo") != null);
    }
}

test "/permissions /hooks /agents panels are registered" {
    inline for ([_][]const u8{ "/permissions", "/hooks", "/agents" }) |cmd| {
        var found = false;
        for (commands) |c| {
            if (std.mem.eql(u8, c.key, cmd)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "/diff, /hunk and /file are registered in the command table" {
    var found_diff = false;
    var found_hunk = false;
    var found_file = false;
    for (commands) |c| {
        if (std.mem.eql(u8, c.key, "/diff")) found_diff = true;
        if (std.mem.eql(u8, c.key, "/hunk")) found_hunk = true;
        if (std.mem.eql(u8, c.key, "/file")) found_file = true;
    }
    try std.testing.expect(found_diff);
    try std.testing.expect(found_hunk);
    try std.testing.expect(found_file);
}

test "/permissions panel is dispatched" {
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    try agent.submit(&m, "/permissions");
    const text = try pendingText(&m, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "permissions") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Tool(pattern)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "deny beats any allow") != null);
}

test "/hooks panel is dispatched" {
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    try agent.submit(&m, "/hooks");
    const text = try pendingText(&m, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "hooks") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "PreToolUse") != null);
}

test "/agents panel is dispatched" {
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    try agent.submit(&m, "/agents");
    const text = try pendingText(&m, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "agents") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Phase 9") != null);
}

/// `/hunk next|prev`: navigate hunks in the last diff (Phase 3).
pub fn cmdHunk(m: *tui.Model, arg: ?[]const u8) void {
    const a = std.mem.trim(u8, arg orelse "", " \t\r\n");
    if (std.mem.eql(u8, a, "next") or std.mem.eql(u8, a, "n") or std.mem.eql(u8, a, "]")) {
        _ = m.navigateLastDiffHunk(1);
        return;
    }
    if (std.mem.eql(u8, a, "prev") or std.mem.eql(u8, a, "p") or std.mem.eql(u8, a, "previous") or std.mem.eql(u8, a, "[")) {
        _ = m.navigateLastDiffHunk(-1);
        return;
    }
    agent.pushInfo(m, "usage: /hunk next|prev (also alt+] / alt+[ on the last diff)");
}

/// `/file [copy|path|next|prev|open]`: last changed file (Phase 2/3, honest structured state).
/// File intelligence focus/actions: navigate changed-file entries, jump to the
/// focused diff, and act on the focused path (copy/open). Runtime-owned state.
pub fn cmdFile(m: *tui.Model, arg: ?[]const u8) void {
    const a = std.mem.trim(u8, arg orelse "", " \t\r\n");
    if (std.mem.eql(u8, a, "next") or std.mem.eql(u8, a, "n")) {
        if (m.navigateFileIntel(1)) return;
        _ = m.navigateDiff(1);
        return;
    }
    if (std.mem.eql(u8, a, "prev") or std.mem.eql(u8, a, "p") or std.mem.eql(u8, a, "previous")) {
        if (m.navigateFileIntel(-1)) return;
        _ = m.navigateDiff(-1);
        return;
    }
    if (std.mem.eql(u8, a, "show") or std.mem.eql(u8, a, "go") or std.mem.eql(u8, a, "current")) {
        if (m.showFocusedFileIntel()) return;
        const path = m.focusedFilePath() orelse m.lastChangedFile() orelse {
            agent.pushInfo(m, "file: no changed files in this session");
            return;
        };
        agent.pushInfoFmt(m, "file: {s}", .{path});
        return;
    }
    if (std.mem.eql(u8, a, "list") or std.mem.eql(u8, a, "ls")) {
        _ = m.pushFileIntelList();
        return;
    }
    const path = m.focusedFilePath() orelse m.lastChangedFile() orelse {
        agent.pushInfo(m, "file: no changed files in this session");
        return;
    };
    if (std.mem.eql(u8, a, "copy") or std.mem.eql(u8, a, "path")) {
        m.setCopyPending(path);
        agent.pushInfoFmt(m, "file: copied path  {s}", .{path});
        return;
    }
    if (std.mem.eql(u8, a, "open") or std.mem.eql(u8, a, "edit")) {
        m.setCopyPending(path);
        agent.pushInfoFmt(m, "file: {s}", .{path});
        agent.pushInfo(m, "open: path copied to clipboard. Run $VISUAL/$EDITOR outside the TUI (in-TUI spawn is deferred).");
        return;
    }
    if (a.len > 0) {
        agent.pushInfo(m, "usage: /file [list|show|next|prev|copy|path|open]");
        return;
    }
    // Show/jump to focused file intelligence entry when available.
    if (m.showFocusedFileIntel()) return;
    agent.pushInfoFmt(m, "file: {s}", .{path});
    agent.pushInfo(m, "actions: /file list|next|prev · /file copy|open · /diff · /hunk next|prev");
}

test "/diff command is dispatched" {
    const saved_io = agent.io_global;
    const saved_turn = agent.turn_stats;
    agent.io_global = std.testing.io;
    agent.turn_stats = .{};
    defer {
        agent.turn_stats = saved_turn;
        agent.io_global = saved_io;
    }

    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    try agent.submit(&m, "/diff");
    const text = try pendingText(&m, std.testing.allocator);
    defer std.testing.allocator.free(text);
    // In a git repo with a working test IO, shows "diff · uncommitted";
    // if process spawning is unavailable under test IO, reports git unavailable.
    try std.testing.expect(std.mem.indexOf(u8, text, "diff") != null);
}

pub fn cmdVersion(m: *tui.Model) void {
    m.pushInfoFmt("zode {s}", .{selfupdate.current_version});
}

/// `/release-notes`: show release notes for the running version.
pub fn cmdReleaseNotes(m: *tui.Model) void {
    const gpa = m.allocator;
    if (!m.io_ready) {
        m.pushInfo("release notes: I/O not ready");
        return;
    }
    const io = agent.io_global;
    const version = selfupdate.current_version;

    const body = std.Io.Dir.cwd().readFileAlloc(io, "CHANGELOG.md", gpa, .limited(1024 * 1024)) catch {
        m.pushInfo("release notes: CHANGELOG.md not found (run from the repo root, or see the project releases)");
        return;
    };
    defer gpa.free(body);

    const section = extractReleaseSection(gpa, body, version) catch {
        m.pushInfoFmt("release notes for {s}: section not found in CHANGELOG.md", .{version});
        return;
    } orelse {
        m.pushInfoFmt("release notes for {s}: section not found in CHANGELOG.md", .{version});
        return;
    };
    defer gpa.free(section);

    m.pushInfoFmt("release notes — zode {s}", .{version});
    var it = std.mem.splitScalar(u8, section, '\n');
    while (it.next()) |line| {
        const l = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
        m.pushInfoOwned(gpa.dupe(u8, l) catch continue);
    }
}

pub fn extractReleaseSection(gpa: std.mem.Allocator, changelog: []const u8, version: []const u8) !?[]u8 {
    var needle_buf: [128]u8 = undefined;
    const is_dev = std.mem.eql(u8, version, "dev") or selfupdate.Version.parse(version) == null;
    const needle = if (is_dev)
        "## [Unreleased]"
    else blk: {
        const v = if (version.len > 0 and (version[0] == 'v' or version[0] == 'V')) version[1..] else version;
        break :blk std.fmt.bufPrint(&needle_buf, "## [{s}]", .{v}) catch return null;
    };

    const start = std.mem.indexOf(u8, changelog, needle) orelse return null;
    var body_start = start;
    if (std.mem.indexOfScalarPos(u8, changelog, start, '\n')) |nl| {
        body_start = nl + 1;
    } else {
        return try gpa.dupe(u8, "");
    }

    var end = changelog.len;
    if (std.mem.indexOfPos(u8, changelog, body_start, "\n## [")) |next| {
        end = next;
    }

    const raw = std.mem.trim(u8, changelog[body_start..end], " \t\r\n");
    if (raw.len == 0) return try gpa.dupe(u8, "(no entries)");
    return try gpa.dupe(u8, raw);
}

pub fn cmdTaskParallel(m: *tui.Model, arg: ?[]const u8) void {
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
    const effective = if (override > 0) override else agent.taskParallelLimit(m);
    m.pushInfoFmt(
        "subagent parallelism: {d} at a time{s}",
        .{ effective, if (override > 0) " (session override)" else " (auto: ZODE_TASK_PARALLEL or default)" },
    );
}

pub fn cmdAskMode(m: *tui.Model, arg: ?[]const u8) void {
    if (arg) |a| {
        const on = std.ascii.eqlIgnoreCase(a, "on") or std.ascii.eqlIgnoreCase(a, "1");
        const off = std.ascii.eqlIgnoreCase(a, "off") or std.ascii.eqlIgnoreCase(a, "0");
        if (on) {
            agent.setPermMode(m, .read_only);
            agent.pushInfo(m, "Plan mode ON: investigate first; writes are blocked pending approval.");
            return;
        }
        if (off) {
            agent.setPermMode(m, .default);
            agent.pushInfo(m, "Build mode ON");
            return;
        }
        agent.pushInfoFmt(m, "/ask: on|off (it is {s})", .{if (agent.read_only) "on" else "off"});
        return;
    }
    const next: agent.PermMode = if (agent.read_only) .default else .read_only;
    agent.setPermMode(m, next);
    agent.pushInfoFmt(m, "permission mode: {s}", .{agent.permModeName()});
}

pub fn cmdDots(m: *tui.Model, arg: ?[]const u8) void {
    if (arg) |a| {
        const on = std.ascii.eqlIgnoreCase(a, "on") or std.ascii.eqlIgnoreCase(a, "1");
        const off = std.ascii.eqlIgnoreCase(a, "off") or std.ascii.eqlIgnoreCase(a, "0");
        if (on) {
            m.show_prompt_dots = true;
            m.requestRedraw();
            agent.pushInfo(m, "prompt dots: on — click a dot on the right rail to jump to that prompt");
            return;
        }
        if (off) {
            m.show_prompt_dots = false;
            m.prompt_dot_hover = null;
            m.prompt_dot_len = 0;
            m.requestRedraw();
            agent.pushInfo(m, "prompt dots: off");
            return;
        }
        agent.pushInfo(m, "/dots: on|off");
        return;
    }
    m.show_prompt_dots = !m.show_prompt_dots;
    if (!m.show_prompt_dots) {
        m.prompt_dot_hover = null;
        m.prompt_dot_len = 0;
    }
    m.requestRedraw();
    agent.pushInfoFmt(m, "prompt dots: {s}", .{if (m.show_prompt_dots) "on" else "off"});
}

pub fn cmdYolo(m: *tui.Model) void {
    agent.setPermMode(m, if (agent.yolo) .default else .bypass);
    const msg = if (agent.yolo)
        "yolo ON: no confirmations, and no questions (your questions are answered for you and said in the summary)"
    else
        "yolo OFF: asks for permission";
    agent.pushInfo(m, msg);
}

pub fn cmdBench(m: *tui.Model) void {
    var buf: [1024]u8 = undefined;
    const text = m.bench.report(&buf, agent.iterationLimit(), agent.cacheHitPct()) catch {
        agent.pushInfo(m, "/bench: could not compose the report");
        return;
    };
    agent.pushInfo(m, text);

    const cs = agent.cheapRouterStats();
    if (cs.on) {
        agent.pushInfoFmt(
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

pub fn cmdClear(m: *tui.Model) void {
    agent.resetSessionFiles(m);
    m.clearHistory();
    if (agent.session) |s| s.resetSkillsSent();
    m.pushInfo("screen cleared · read cache + changed list reset · skills listing re-attached next turn");
}

/// `/mode [build|accept-edits|plan|bypass]`, or the current mode with no argument.
pub fn cmdMode(m: *tui.Model, arg: ?[]const u8) void {
    if (arg) |a| {
        const mode = agent.parsePermMode(a);
        if (mode) |mm| {
            agent.setPermMode(m, mm);
            agent.pushInfoFmt(m, "permission mode: {s}", .{agent.permModeName()});
            return;
        }
        agent.pushInfo(m, "/mode: build|accept-edits|plan|bypass");
        return;
    }
    agent.pushInfoFmt(m, "permission mode: {s} (shift+tab cycles)", .{agent.permModeName()});
}

/// `/skills`: what is loadable, and from where.
pub fn cmdSkills(m: *tui.Model) void {
    const entries = agent.discoverSkills(m.allocator, m.environ);
    if (entries.len == 0) {
        agent.pushInfo(m, "no skills found. Put them in .zode/skills/<name>/SKILL.md (this project) or ~/.config/zode/skills/<name>/SKILL.md (yours)");
        return;
    }
    agent.pushInfoFmt(m, "{d} skill{s} (only the name and description are in the prompt; the body loads on demand)", .{
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
        const line = std.fmt.allocPrint(m.allocator, "  {s} {s}: {s}{s}", .{
            source_tag,
            e.name,
            if (e.description.len > 0) e.description else "(no description)",
            if (e.when_to_use.len > 0)
                std.fmt.allocPrint(m.allocator, " — {s}", .{e.when_to_use}) catch ""
            else
                "",
        }) catch continue;
        agent.pushInfoOwned(m, line);
    }
}

/// `/style <name>`: select an output style. No args reports the current one;
/// `off`/`clear` clears it. The style block is injected at the end of the system prompt.
pub fn cmdStyle(m: *tui.Model, arg: ?[]const u8) void {
    const trimmed = std.mem.trim(u8, arg orelse "", " \t\r\n");
    if (trimmed.len == 0) {
        if (agent.current_style) |name| {
            const entries = agent.discoverStyles(m.allocator, m.environ);
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
                m.pushInfoFmt("output style: {s}{s} — {s}", .{ n, keep_note, found_desc });
            } else {
                m.pushInfoFmt("output style: {s} (not found — was it removed?)", .{name});
            }
        } else {
            agent.pushInfo(m, "no output style selected. /style <name> picks one; /style off clears it.");
        }
        return;
    }

    if (std.ascii.eqlIgnoreCase(trimmed, "off") or std.ascii.eqlIgnoreCase(trimmed, "clear")) {
        agent.current_style = null;
        agent.current_style_len = 0;
        agent.pushInfo(m, "output style cleared. The base prompt (with coding rules) is used.");
        return;
    }

    const entries = agent.discoverStyles(m.allocator, m.environ);
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
        agent.pushInfoFmt(m, "unknown output style '{s}'. Available: {s}", .{
            trimmed,
            if (entries.len > 0) agent.styleNames(entries) else "none",
        });
        return;
    }

    const n = @min(trimmed.len, agent.current_style_buf.len);
    std.mem.copyForwards(u8, agent.current_style_buf[0..n], trimmed[0..n]);
    agent.current_style_len = n;
    agent.current_style = agent.current_style_buf[0..n];

    const keep_note = if (found_keep) "" else " — this style replaces the coding rules";
    agent.pushInfoFmt(m, "output style: {s}{s}", .{ trimmed, keep_note });
}

pub fn cmdEffort(m: *tui.Model, arg: ?[]const u8) void {
    if (arg) |a| {
        const want = chat.Effort.parse(a) orelse {
            m.pushInfoFmt("unknown effort: {s} (none|minimal|low|medium|high|xhigh)", .{a});
            return;
        };
        agent.current_effort = want;
        const got = chat.effortFor(agent.cur_model, want);
        if (got == null) {
            m.pushInfoFmt("effort → {s} (this model has no effort knob; the level only sets the answer length)", .{
                want.label(),
            });
        } else if (got.? != want) {
            m.pushInfoFmt("effort → {s} (this model tops out at {s}, so {s} is what goes on the wire)", .{
                want.label(),
                chat.maxEffortFor(agent.cur_model).label(),
                got.?.label(),
            });
        } else {
            m.pushInfoFmt("effort → {s}", .{want.label()});
        }
        return;
    }
    agent.openEffortPicker(m);
}

pub fn cmdColor(m: *tui.Model, arg: ?[]const u8) void {
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
        m.clearSegCache();
        m.dirty = true;
        return;
    }
    agent.openColorPicker(m);
}

pub fn cleanWanted(env: ?*const std.process.Environ.Map, arg: ?[]const u8) bool {
    if (arg) |a| {
        if (std.mem.eql(u8, a, "yes") or std.mem.eql(u8, a, "y") or
            std.mem.eql(u8, a, "apply")) return true;
    }
    const v = agent.envGet(env, "ZODE_YES") orelse return false;
    return std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "yes");
}

/// The config dir, or null. `/clean` reads it to find the leftover
/// `<name>.tmp` of an interrupted atomic write (`config.zig` writes to a temp
/// and renames it).
pub fn cleanConfigDir(a: std.mem.Allocator, env: ?*const std.process.Environ.Map) ?[]const u8 {
    const home = agent.envGet(env, "HOME") orelse return null;
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
pub fn cmdClean(m: *tui.Model, aplicar: bool) void {
    // The allocator is a local, and its name is not `a`: `a` is also the name
    // the two `allocPrint` helpers below use for their own temporaries, and one
    // name cannot be both the type and the value.
    const gpa = m.allocator;
    const inst = clean_mod.instanceDir(gpa, agent.io_global) catch null;
    defer if (inst) |p| gpa.free(p);
    const cfg = cleanConfigDir(gpa, m.environ);
    defer if (cfg) |p| gpa.free(p);

    const now_secs = std.Io.Timestamp.now(agent.io_global, .real).toSeconds();
    var rep = clean_mod.scan(gpa, agent.io_global, .{
        .roots = .{ .sessions = "sessions", .instances = inst, .config = cfg },
        .now_secs = now_secs,
    }) catch {
        agent.pushInfo(m, "/clean: could not read the directories");
        return;
    };
    defer rep.deinit();

    const header: []const u8 = if (aplicar)
        "/clean: applied"
    else
        "/clean: dry run (nothing deleted)";
    agent.pushInfo(m, header);

    if (rep.missing_sessions) {
        agent.pushInfo(m, "  no sessions/ directory here (nothing to clean in it)");
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
        agent.pushInfoOwned(m, line);
    }

    if (rep.items.len == 0 and !rep.missing_sessions) {
        agent.pushInfo(m, "  nothing to clean");
        return;
    }

    if (!aplicar) {
        const total = rep.deletable();
        if (total == 0) {
            agent.pushInfo(m, "  nothing to delete without a yes");
            return;
        }
        const line = std.fmt.allocPrint(
            gpa,
            "  -> {d} files, {d} bytes. run `/clean yes` to delete them",
            .{ total, rep.bytes() },
        ) catch return;
        agent.pushInfoOwned(m, line);
        return;
    }

    const deleted = clean_mod.apply(agent.io_global, &rep, .{
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
        m.pushInfoFmt("  deleted {d} files", .{deleted});
    } else {
        m.pushInfoFmt("  deleted {d}, {d} could NOT be removed", .{ deleted, rep.failed });
    }
}

pub fn cmdUndo(m: *tui.Model) void {
    var cp = m.takeCheckpointOwned() orelse {
        agent.pushInfo(m, "nothing to undo: no turn has changed any file yet");
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
        std.Io.Dir.cwd().writeFile(agent.io_global, .{ .sub_path = f.pathOf(), .data = f.data }) catch {
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
    if (undone > 0) agent.setStatusWithZo(m, .done, "undone");
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
    const st = dir.statFile(agent.io_global, path, .{}) catch return false;
    if (st.kind != .file) return false;
    dir.deleteFile(agent.io_global, path) catch return false;
    return true;
}

/// ── /copy ────────────────────────────────────────────────────
const copy_picker_tag: u32 = 0x0c0;

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

/// `/btw <question>`: side question answered by a subagent and appended.
///
/// Spec (TASKS 35.14): one subagent call whose answer is appended, not a turn.
/// Runs in a background thread so it does not block the UI; the result is
/// enqueued as an info block when ready.
pub fn cmdBtw(m: *tui.Model, arg: ?[]const u8) void {
    const question = std.mem.trim(u8, arg orelse "", " \t\r\n");
    if (question.len == 0) {
        agent.pushInfo(m, "usage: /btw <question>");
        return;
    }

    const gpa = m.allocator;
    const owned = gpa.dupe(u8, question) catch {
        agent.pushInfo(m, "btw: could not allocate the question");
        return;
    };

    const Job = struct {
        m: *tui.Model,
        question: []u8,

        fn run(job: *@This()) void {
            const model = job.m;
            const a = model.allocator;
            defer a.destroy(job);
            defer model.endWorker(); // registered second -> runs FIRST
            defer a.free(job.question);

            var rep = subagent_mod.Report{};
            var desc_buf: [160]u8 = undefined;
            const desc = std.fmt.bufPrint(&desc_buf, "btw: {s}", .{clipQuestion(job.question, 120)}) catch "btw side question";
            const task = subagent_mod.Task{
                .description = desc,
                .prompt = job.question,
            };

            // runSubagent expects global IO/API state to be initialized (as in
            // normal TUI use). The returned text points into `rep`.
            const text = agent.runSubagent(model, task, &rep);
            const msg = std.fmt.allocPrint(a, "btw · {s}\n{s}", .{ job.question, text }) catch {
                model.pushInfo("btw: answer ready (could not format)");
                return;
            };
            model.pushInfoOwned(msg);
        }

        fn clipQuestion(q: []const u8, max: usize) []const u8 {
            if (q.len <= max) return q;
            var end = max;
            while (end > 0 and (q[end - 1] & 0xc0) == 0x80) end -= 1;
            if (end == 0) end = @min(max, q.len);
            return q[0..end];
        }
    };

    const job = gpa.create(Job) catch {
        gpa.free(owned);
        agent.pushInfo(m, "btw: could not start the side question");
        return;
    };
    job.* = .{ .m = m, .question = owned };
    m.beginWorker();
    const thread = std.Thread.spawn(.{}, Job.run, .{job}) catch {
        m.endWorker();
        gpa.destroy(job);
        gpa.free(owned);
        agent.pushInfo(m, "btw: could not start the side question");
        return;
    };
    thread.detach();
    agent.pushInfo(m, "btw: asking a side question (running in background)...");
}

/// `/copy [N]`: the answer, on the clipboard and in a file.
pub fn cmdCopy(m: *tui.Model, arg: ?[]const u8) void {
    const s = agent.session orelse {
        agent.pushInfo(m, copytext.no_messages_msg);
        return;
    };
    var texts: [copytext.max_lookback][]const u8 = undefined;
    const n = collectAssistantTexts(s, &texts);
    if (n == 0) {
        agent.pushInfo(m, copytext.no_messages_msg);
        return;
    }

    const sel = copytext.select(texts[0..n], arg);
    const index: usize = switch (sel) {
        .found => |i| i,
        .no_messages => {
            agent.pushInfo(m, copytext.no_messages_msg);
            return;
        },
        .usage, .too_few => {
            var buf: [256]u8 = undefined;
            agent.pushInfo(m, copytext.formatRefusal(&buf, sel, arg));
            return;
        },
    };

    var ctx = copytext.buildCtx(m.allocator, texts[index]) catch {
        agent.pushInfo(m, "the answer could not be prepared for copying");
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
        agent.pushInfo(m, copytext.no_messages_msg);
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
    agent.pushInfo(m, copytext.cancelled_msg);
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
    m.copy_toast_frames = 12;

    var name_buf: [64]u8 = undefined;
    const filename = copyFileName(index, ctx, &name_buf);
    const path = writeCopyFile(m, text, filename);

    var msg_buf: [512]u8 = undefined;
    if (path) |p| {
        defer m.allocator.free(p);
        agent.pushInfo(m, copytext.formatCopiedVia(&msg_buf, chars, lines, decision.method.phrase(), p));
    } else {
        // The file could not be written: said out loud, not swallowed. The
        // clipboard half may still have worked.
        agent.pushInfo(m, copytext.formatCopiedNoFile(&msg_buf, chars, lines, decision.method.phrase()));
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
const copy_dir_mode: std.Io.File.Permissions = @fromBackingInt(@intCast(0o700));
const copy_file_mode: std.Io.File.Permissions = @fromBackingInt(@intCast(0o600));


/// `/bg`: the background jobs, and the two ways to stop them.
pub fn cmdBg(m: *tui.Model, arg_in: ?[]const u8) void {
    const arg = arg_in orelse "";
    if (std.ascii.eqlIgnoreCase(arg, "killall")) {
        const n = if (m.io_ready) m.bg.killNow(agent.io_global) else m.bg.requestKillAll();
        agent.pushInfoFmt(m, "killed {d} background command{s}", .{
            n,
            if (n == 1) @as([]const u8, "") else @as([]const u8, "s"),
        });
        return;
    }
    if (std.ascii.startsWithIgnoreCase(arg, "kill")) {
        var it = std.mem.tokenizeAny(u8, arg, " \t");
        _ = it.next(); // "kill"
        const id_str = it.next() orelse {
            agent.pushInfo(m, "/bg kill <id> · /bg killall");
            return;
        };
        const id = std.fmt.parseInt(u32, id_str, 10) catch {
            agent.pushInfo(m, "/bg kill <id> · /bg killall");
            return;
        };
        if (m.bg.kill(agent.io_global, id)) {
            agent.pushInfoFmt(m, "killed job {d}", .{id});
        } else {
            agent.pushInfoFmt(m, "job {d} was not running ({s})", .{ id, m.bg.stateWord(id) });
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
        agent.pushInfo(m, "no background commands");
        return;
    }
    agent.pushInfo(m, std.mem.trimEnd(u8, w.buffered(), "\n"));
}

// ── self-update ─────────────────────────────────────────────

/// Looks for a newer release at startup, in a worker, and says so if there is
/// one. It says NOTHING when the build is current.
pub fn startUpdateCheck(m: *tui.Model) void {
    if (agent.envGet(m.environ, "ZODE_NO_SELF_UPDATE") != null) return;
    spawnUpdateJob(m, .check) catch {};
}

/// `/update`: installs the newest release.
pub fn cmdUpdate(m: *tui.Model) void {
    spawnUpdateJob(m, .install) catch agent.pushError(m, "could not start the update");
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
    defer m.allocator.destroy(job);
    defer m.endWorker();

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
            if (agent.envGet(m.environ, "ZODE_AUTO_UPDATE") != null) installUpdateNow(m, ctx);
        },
        .install => installUpdateNow(m, ctx),
    }
}

fn announceUpdate(m: *tui.Model, up: selfupdate.Update) void {
    var buf: [160]u8 = undefined;
    const phrase = selfupdate.phrase(&buf, up);
    m.pushInfoFmt("zode {s} · /update installs it", .{phrase});
}

fn installUpdateNow(m: *tui.Model, ctx: selfupdate.Context) void {
    m.pushInfoFmt("updating zode from {s}…", .{selfupdate.current_version});
    const tag = selfupdate.installLatest(ctx) catch |err| switch (err) {
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
}

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

/// Group (+1 index over command groups) of each command key.
pub fn cmdGroup(key: []const u8) u8 {
    if (std.mem.eql(u8, key, "connect")) return 1;
    const k = if (key.len > 0 and key[0] == '/') key[1..] else key;
    if (std.mem.eql(u8, k, "help") or std.mem.eql(u8, k, "new") or
        std.mem.eql(u8, k, "resume") or std.mem.eql(u8, k, "yolo")) return 2;
    if (std.mem.eql(u8, k, "free-auto") or std.mem.eql(u8, k, "free")) return 3;
    if (std.mem.eql(u8, k, "model") or
        std.mem.eql(u8, k, "provider") or std.mem.eql(u8, k, "providers") or
        std.mem.eql(u8, k, "effort") or
        std.mem.eql(u8, k, "submodel") or std.mem.eql(u8, k, "task-parallel")) return 4;
    return 5;
}

/// Public wrapper for tests/external callers.
pub fn cmdGroupPublic(key: []const u8) u8 {
    return cmdGroup(key);
}

/// `/submodel [off | <model> | <provider> <model>]`; no args: report.
pub fn cmdSubmodel(m: *tui.Model, arg: ?[]const u8) void {
    const a = arg orelse return agent.submodelReport(m);
    if (std.mem.eql(u8, a, "off") or std.mem.eql(u8, a, "none")) {
        agent.submodelSetOff();
        m.pushInfoFmt("subagents: the same model as the main turn (`/submodel off`; config.json and the environment are ignored this session). Set: /submodel <model> | <provider> <model>", .{});
        return;
    }
    var it = std.mem.tokenizeScalar(u8, a, ' ');
    const t1 = it.next() orelse return agent.submodelReport(m);
    const t2 = it.next();
    if (t2 == null and (config_mod.find(agent.user_config, t1) != null or providers.byId(t1) != null)) {
        agent.setSubmodel(t1, "");
    } else if (t2) |mo| {
        agent.setSubmodel(t1, mo);
    } else {
        agent.setSubmodel("", t1);
    }
    agent.submodelClearFail();
    agent.submodelReport(m);
}


const runtime_state = @import("agent/runtime_state.zig");

/// `/rewind [N]`: undo the last N turns' file changes (35.12).
/// Without N, lists available checkpoints.
pub fn cmdRewind(m: *tui.Model, arg: ?[]const u8) void {
    const n_turns: usize = if (arg) |a| blk: {
        const t = std.mem.trim(u8, a, " \t\r\n");
        if (t.len == 0) break :blk 0;
        break :blk std.fmt.parseInt(usize, t, 10) catch 0;
    } else 0;

    if (n_turns == 0) {
        const count = m.checkpoints.len;
        if (count == 0) {
            agent.pushInfo(m, "nothing to rewind: no turn has changed any file yet");
            return;
        }
        var buf: [2048]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        w.print("checkpoints (most recent first):\n", .{}) catch {};
        var i: usize = count;
        var shown: usize = 0;
        while (i > 0 and shown < 20) {
            i -= 1;
            const cp = &m.checkpoints.items[i];
            shown += 1;
            w.print("  {d}. {s} ({d} file{s}, {d} undoable)\n", .{
                shown,
                cp.labelOf(),
                cp.fileCount(),
                if (cp.fileCount() == 1) "" else "s",
                cp.undoable(),
            }) catch {};
        }
        w.print("use /rewind N to undo the last N turns", .{}) catch {};
        agent.pushInfo(m, w.buffered());
        return;
    }

    const count = m.checkpoints.len;
    if (count == 0) {
        agent.pushInfo(m, "nothing to rewind: no turn has changed any file yet");
        return;
    }
    if (n_turns > count) {
        agent.pushInfoFmt(m, "rewind: only {d} checkpoint{s} available", .{ count, if (count == 1) "" else "s" });
        return;
    }

    var total_undone: usize = 0;
    var total_failed: usize = 0;
    var total_skipped: usize = 0;
    var k: usize = 0;
    while (k < n_turns) : (k += 1) {
        var cp = m.takeCheckpointOwned() orelse break;
        defer cp.deinit(m.allocator);
        for (cp.files[0..cp.len]) |f| {
            if (f.truncated) {
                total_skipped += 1;
                continue;
            }
            if (!f.existed) {
                if (deleteIfUnchanged(f.pathOf())) {
                    total_undone += 1;
                } else {
                    total_failed += 1;
                }
            } else {
                std.Io.Dir.cwd().writeFile(agent.io_global, .{ .sub_path = f.pathOf(), .data = f.data }) catch {
                    total_failed += 1;
                    continue;
                };
                total_undone += 1;
            }
        }
    }

    if (total_undone == 0) {
        agent.pushInfo(m, "rewind: nothing could be restored");
    } else {
        agent.pushInfoFmt(m, "rewind: restored {d} file change{s} across {d} turn{s}", .{
            total_undone,
            if (total_undone == 1) "" else "s",
            n_turns,
            if (n_turns == 1) "" else "s",
        });
    }
    if (total_skipped > 0 or total_failed > 0) {
        agent.pushInfoFmt(m, "{d} skipped, {d} failed", .{ total_skipped, total_failed });
    }
    if (total_undone > 0) agent.setStatusWithZo(m, .done, "rewound");
}

/// `/iter [n]`: set or show per-session iteration budget.
pub fn cmdIter(m: *tui.Model, arg: ?[]const u8) void {
    if (arg) |raw| {
        const n = std.fmt.parseInt(usize, raw, 10) catch {
            agent.pushInfo(m, "/iter: expected a number (minimum 8)");
            return;
        };
        if (n < 8) {
            agent.pushInfoFmt(m, "/iter: minimum is 8, you asked for {d}", .{n});
            return;
        }
        if (n > 200) {
            agent.pushInfoFmt(m, "/iter: maximum is 200, you asked for {d}", .{n});
            return;
        }
        if (n < 32) {
            agent.pushInfoFmt(m, "/iter: budget set to {d} iterations — low for a long task, fine for a short one", .{n});
        } else {
            agent.pushInfoFmt(m, "/iter: budget set to {d} iterations for this session", .{n});
        }
        agent.iter_limit_override = n;
    } else {
        const cur = agent.iterationLimit();
        const src = runtime_state.iterationSource(agent.iter_limit_override > 0, agent.model_requested_iter > 0);
        agent.pushInfoFmt(m, "/iter: current budget is {d} iterations ({s})", .{ cur, src });
    }
}

test "/btw without a question shows usage" {
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    cmdBtw(&m, null);
    const text = try pendingText(&m, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "usage: /btw") != null);
}
