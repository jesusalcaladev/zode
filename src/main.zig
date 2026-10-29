const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const tui = @import("tui.zig");
const http_client = @import("lib/http_client.zig");
const models = @import("lib/models.zig");
const modelcache = @import("lib/modelcache.zig");
const models_mod = models;
const provider = @import("lib/provider.zig");
const providers = @import("lib/providers.zig");
const tools_mod = @import("tools_root.zig");
const cache_stats = @import("cache_stats.zig");
const chat = @import("chat.zig");
const agent = @import("agent.zig");
const free_auto = @import("free_auto.zig");
const compaction_mod = @import("compaction.zig");
const bgproc = @import("bgproc.zig");
const images_mod = @import("lib/images.zig");
const plan_mod = @import("lib/plan.zig");
const taskstore = @import("lib/taskstore.zig");
const kittyKeyboardPush = @import("lib/termseq.zig").kittyKeyboardPush;
const kittyKeyboardPop = @import("lib/termseq.zig").kittyKeyboardPop;
const skills = @import("lib/skills.zig");
const ask = @import("lib/ask.zig");
const lsp_manager = @import("lsp/manager.zig");
const mcp_manager = @import("mcp/manager.zig");
const theme = @import("lib/theme.zig");

fn envGet(map: ?*const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const m = map orelse return null;
    return m.get(key);
}

/// Headless mode: zode --models
fn runModels(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map) !u8 {
    models.dbg_io = io; // for diagnostics
    // The configuration FIRST, and this is the bug this call fixes.
    //
    // `--models` used to be dispatched BEFORE `loadUserConfig`, which is why it always
    // described opencode: `activeProviderDef` reads `cur_provider_id`, a module global
    // that `loadUserConfig` is what sets, and nothing had set it yet. Measured with
    // `ZODE_PROVIDER=openrouter` and a real key: it printed opencode's catalogue, from
    // its own cache, and said nothing about openrouter at all.
    //
    // `--models` is the command you run when a provider is not working. A diagnostic
    // that cannot name the provider you configured is not a diagnostic, and the two bugs
    // stacked: it read the wrong provider AND only `ZODE_API_KEY` for the key.
    //
    // It needs the `Io` and the environment assigned first, because `loadUserConfig`
    // reads config.json through both. The marks are not there because `--models` is a
    // diagnostic command and its startup time is not what anybody is measuring.
    agent.io_global = io;
    agent.environ_global = env;
    agent.gpa_global = gpa;
    // Per-tool output caps from the environment (ZODE_MAX_TOOL_OUTPUT).
    agent.loadUserConfig();
    defer agent.shutdownUserConfig();
    tools_mod.initMaxToolOutput(env);
    tools_mod.initDiffLimit(env);
    tools_mod.initGrepCapture(env);

    var http = http_client.Http.init(gpa, io);
    defer http.deinit();

    // THE ACTIVE PROVIDER, and not `provider.Config.load(env)`.
    //
    // This used to read the opencode URLs straight out of the environment and the key
    // out of `ZODE_API_KEY`, so `--models` could only ever describe the opencode
    // catalogue. Measured while testing a fresh OpenRouter key: with
    // `ZODE_PROVIDER=openrouter` and `ZODE_OPENROUTER_KEY` set, it printed opencode's
    // models and said nothing about why the real provider was failing.
    //
    // Which is the worst possible place for the bug: `--models` is the command you run
    // WHEN a provider is not working, and it was structurally incapable of reporting
    // anything about a provider other than one. It is the same class as the headless
    // prompt missing the routing table and the automatic typecheck existing only in the
    // TUI — a second, lesser implementation of a thing the TUI already gets right.
    //
    // So it goes through the same two functions the TUI and `--chat` use, which is what
    // makes it right by construction rather than by remembering to add the next provider.
    const def = agent.activeProviderDef(env);
    // `def.models_url` and not `cfg.urlModels(buf)`: the provider table owns its own URL
    // and the buffer was only ever there because the opencode defaults came from a
    // helper that needed somewhere to put them.
    const url = def.models_url;
    const key = providers.keyFor(def, env);

    // No catalogue endpoint (`models_url = ""`): `--models` is the command you
    // run to see a list, and there is no list to fetch. What the provider
    // DOCUMENTS is still what a person is after, so it is printed — labelled as
    // what it is, because a suggestion that looks like a fetched catalogue is
    // how a retired id gets picked a year from now.
    if (url.len == 0) {
        if (def.suggested_models.len == 0) {
            std.debug.print(
                "{s} publishes no model catalog: pick the model by hand (`/use {s} <model>` or ZODE_MODEL).\n",
                .{ def.id, def.id },
            );
            return 1;
        }
        var ids_buf: [4096]u8 = undefined;
        var ids_out = std.Io.File.stdout().writer(io, &ids_buf);
        for (def.suggested_models) |id| {
            try ids_out.interface.print("{s}\tdocumented\n", .{id});
        }
        try ids_out.interface.flush();
        std.debug.print(
            "{d} ids · {s} publishes no /models endpoint, so this is the documented list (a suggestion, not a catalog)\n",
            .{ def.suggested_models.len, def.id },
        );
        return 0;
    }

    // `--models` is the worst case for a cold network: 772 KB and a 400-800 ms round
    // trip, for a list that changes once a month. It reads the cache first, prints, and
    // refreshes only if there is nothing saved (or the save is ancient). A machine with
    // no network still gets an answer.
    var astate = std.heap.ArenaAllocator.init(gpa);
    defer astate.deinit();
    const arena = astate.allocator();

    var printed = false;
    // The cache key is the PROVIDER, not the URL: two providers can publish the same
    // catalogue URL and one of them changing its models must not invalidate the other.
    // The cache key is the provider's REAL id now, not whatever the environment says.
    // They were the same when both meant opencode and they diverge the moment a user
    // sets `ZODE_PROVIDER` without a config.json: the fetch went to opencode and the
    // cache entry was filed under the other name, so the next run could not find it.
    const pid = def.id;
    if (modelcache.read(io, env, arena, pid, url)) |e| {
        if (e.models.len > 0) {
            var out_buf: [4096]u8 = undefined;
            var out = std.Io.File.stdout().writer(io, &out_buf);
            for (e.models) |m| {
                try out.interface.print("{s}\t{s}\n", .{ m.id, m.owned_by });
            }
            try out.interface.flush();
            const free = blk: {
                var n: usize = 0;
                for (e.models) |m| {
                    if (m.is_free) n += 1;
                }
                break :blk n;
            };
            std.debug.print("{d} modelos ({d} free) — lista guardada, {s}\n", .{
                e.models.len,
                free,
                if (ageIsStale(io, e.fetched_at)) "obsoleta, se actualiza" else "actual",
            });
            printed = true;
        }
    }
    if (printed) return 0;

    var list = models.listModels(gpa, &http, url, providers.authWithKey(def.key_style, key)) catch |err| {
        std.debug.print("error: {t}\n", .{err});
        return 1;
    };
    defer list.deinit(gpa);
    modelcache.write(io, env, pid, url, list.items);

    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &out_buf);
    for (list.items) |m| {
        try out.interface.print("{s}\t{s}\n", .{ m.id, m.owned_by });
    }
    try out.interface.flush();
    std.debug.print("{d} modelos ({d} free)\n", .{ list.items.len, list.free_count });
    return 0;
}

/// Is a saved list old enough that a refresh is urgent?
///
/// Urgent and not "unusable": `--models` prints it either way, because a month-old
/// list of ids is far more useful than an error. This only decides whether to say so.
///
/// It takes the `io` and does NOT read `agent.io_global`: `--models` runs before
/// `main` assigns that global, and reading a clock through an `Io` that was never
/// attached is a jump through a garbage vtable — a segfault, which is exactly what the
/// first version did. Measured: 203 ms then a core dump, every time.
fn ageIsStale(io: std.Io, fetched_at: i64) bool {
    if (fetched_at <= 0) return true;
    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    if (now <= fetched_at) return false;
    const hours = @divTrunc(now - fetched_at, 3600);
    return hours >= modelcache.max_age_hours;
}

/// Headless mode: zode --chat "text"
/// Headless agent: like the TUI but without UI (yolo ON, prints to stderr).
fn runChat(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, text: []const u8) !u8 {
    var http = http_client.Http.init(gpa, io);
    defer http.deinit();

    agent.io_global = io;
    agent.gpa_global = gpa;
    agent.environ_global = env;
    agent.api_key_global = envGet(env, "ZODE_API_KEY");
    // Per-tool output caps from the environment (ZODE_MAX_TOOL_OUTPUT).
    tools_mod.initMaxToolOutput(env);
    tools_mod.initDiffLimit(env);
    tools_mod.initGrepCapture(env);
    // The language servers. Started LAZILY (a server is spawned when a file of
    // its language is asked about) but the manager has to exist before the
    // config is read, because the config is what says which servers there are.
    lsp_manager.init(gpa, io, env);
    defer lsp_manager.shutdown();
    // The MCP servers: same reason, same laziness.
    mcp_manager.init(gpa, io, env);
    defer mcp_manager.shutdown();
    agent.initProjectInfo(io, env); // cwd + repo root, before any prompt is composed
    // The same session directory the TUI resolves: one project, one history.
    // Without this `--chat` wrote `./sessions` (the compiled-in default) while
    // the TUI wrote `<state>/sessions/<hash>`, so each side could not see the
    // other's sessions in `/session`.
    agent.resolveSessionsDirIn(gpa, env);
    chat.io_global = io;
    free_auto.attachIo(io); // el reloj de los cooldowns del free-auto
    models.dbg_io = io;
    defer agent.shutdownUserConfig();
    defer agent.shutdownBuffers(); // the 1 MiB body buffer (see `bodyBuf`)
    agent.loadUserConfig();

    const def = agent.activeProviderDef(env);
    const kind = chat.kindForProvider(def.id);
    var url_buf: [1024]u8 = undefined;
    const url = if (kind == .anthropic)
        std.fmt.bufPrint(&url_buf, "{s}/messages", .{def.base_url}) catch def.base_url
    else
        std.fmt.bufPrint(&url_buf, "{s}/chat/completions", .{def.base_url}) catch def.base_url;
    const key = providers.keyFor(def, env);

    // Build extra headers for OpenRouter (HTTP-Referer and X-OpenRouter-Title)
    var extra_hdrs_buf: [2]http_client.Http.ExtraHeader = undefined;
    var extra_hdrs_len: usize = 0;
    if (std.mem.eql(u8, def.id, "openrouter")) {
        extra_hdrs_buf[extra_hdrs_len] = .{ .name = "HTTP-Referer", .value = "https://github.com/jesusalcala/zode" };
        extra_hdrs_len += 1;
        extra_hdrs_buf[extra_hdrs_len] = .{ .name = "X-OpenRouter-Title", .value = "zode" };
        extra_hdrs_len += 1;
    }
    const extra_headers = extra_hdrs_buf[0..extra_hdrs_len];

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var msgs: std.ArrayList(chat.ChatMessage) = .empty;
    // Images a `read` left behind: on the wire for ONE request and then gone, the
    // same rule as the TUI.
    var pending_images: images_mod.Pending = .{};
    // The automatic typecheck's state for a run that has no `Model` to keep it in.
    var auto_check: agent.AutoCheck = .{};
    agent.attachAutoCheckEnv(&auto_check, env);
    // The plan, on the stack. There is no `Model` here and no screen, so this is
    // where the steps go: printed, so a run in a script shows the same progress a
    // TUI session would.
    var plan: plan_mod.Plan = .init();
    // The `arena`, not the `gpa`: this text lives as long as the conversation
    // does, and the arena dies at the end of the run. With `gpa` it was a leak
    // per process (the DebugAllocator says so on exit, which is how it showed up).
    try msgs.append(arena, .{ .role = "system", .content = try headlessSystemPrompt(arena, env) });
    // `@file` mentions work in headless too: the TUI expands them in
    // `runOneTurn` (`withMentions`), but this runner sent the raw text, so
    // `zode --chat "explain @src/foo.zig"` made the model answer "I don't have
    // the file". Expanded HERE, on the session's own text, because the headless
    // runner has no per-iteration arena like `runOneTurn` has.
    const mentions_mod = @import("lib/mentions.zig");
    const expanded = mentions_mod.expand(io, text) catch
        mentions_mod.Expansion{ .text = text, .files = 0, .missing = 0 };
    try msgs.append(arena, .{ .role = "user", .content = expanded.text });

    // The headless runner gets a background registry too, so `run_in_background`
    // works there instead of erroring out. The registry is freed on exit, which
    // also kills anything still running: a `zode --chat` that exits with an
    // orphaned build writing to a closed pipe is worse than waiting.
    var bg = bgproc.Registry{};
    // The task graph of a headless run: real for the run, memory only.
    //
    // This runner has no session file (`--chat` is one run in one process), so there
    // is nothing for the list to survive in. The tools still work, and the graph is
    // what `task_list` reads back inside the run — which is the whole point of a task
    // list during a turn. Nothing is written, so nothing can be half-written either.
    var tasks = taskstore.Store{ .gpa = gpa };
    defer bg.deinit(io, gpa);

    // The headless model gets ASKED for too. Without this, `--chat` against a
    // provider with no `default_model` would send `"model": ""` and the server
    // error would say nothing about why. And if the catalog cannot be read, it
    // says so and exits with code 1 without having spent a turn.
    var model_name: []const u8 = "";
    if (envGet(env, "ZODE_MODEL")) |mm| {
        if (mm.len > 0) model_name = mm;
    }
    if (model_name.len == 0) model_name = agent.userModel();
    if (model_name.len == 0) {
        // The headless model gets asked for too. Without this, `--chat` against
        // a provider with no `default_model` would send `"model": ""` and the
        // server error would say nothing about why.
        model_name = agent.resolveModelHeadless(gpa, &http, env) catch |err| {
            // Two different problems, two different sentences: a provider that
            // publishes no catalogue at all (empty `models_url`) is not a broken
            // network, and "could not read" would send the reader to fix the
            // wrong thing.
            if (def.models_url.len == 0) {
                std.debug.print("error: {s} publishes no model catalog: there is no /models endpoint to ask.\n", .{def.id});
                if (def.suggested_models.len > 0) {
                    std.debug.print("       the ids it documents:", .{});
                    for (def.suggested_models) |id| std.debug.print(" {s}", .{id});
                    std.debug.print("\n", .{});
                }
            } else {
                std.debug.print("error: could not read {s}'s model catalog ({t}).\n", .{ def.id, err });
            }
            std.debug.print("       set ZODE_MODEL=<id> or add a model to ~/.config/zode/config.json.\n", .{});
            return error.NoModel;
        };
        std.debug.print("model: {s} (first free in the catalog; ZODE_MODEL to override)\n", .{model_name});
    }

    // Here and not earlier: `model_name` is empty until the block above has run,
    // and a check on an empty model is a check that never fires — which is what
    // the first version of this did, in the one path (`--chat`) where a warning
    // has no UI to be missed in.
    if (models.isRouter(model_name)) {
        std.debug.print(
            "warn: {s} is a ROUTER. It picks a different upstream per request, they do not share a prompt cache, and it measured 0% cached against 98% for a fixed model with an identical prefix. Every request is billed in full, including the 11 KB of tool schema. Pick a model with /model or ZODE_MODEL: `model:free` is a MODEL that happens to be free.\n",
            .{model_name},
        );
    }

    // The effort comes FROM THE MODEL, not from a fixed `.medium`: with no
    // `ZODE_EFFORT` it asks for the default of that model's own ladder. And what
    // arrives from the variable is clamped to that same ladder, so that
    // `ZODE_EFFORT=xhigh` against a `gemini-2.5` does not send a level that does
    // not exist.
    const effort_pref: chat.Effort = chat.clampEffort(
        model_name,
        if (envGet(env, "ZODE_EFFORT")) |e|
            chat.Effort.parse(e) orelse chat.defaultEffort(model_name)
        else
            chat.defaultEffort(model_name),
    );

    const body_buf = try gpa.alloc(u8, 256 * 1024);
    defer gpa.free(body_buf);

    models.dbg_io = io;

    // `agent.iterationLimit()` and NOT a literal 6.
    //
    // The TUI allows 12 and `ZODE_MAX_ITER` moves it; the headless runner had 6
    // hardcoded, so `--chat` gave up on a real task while the same task in the same
    // repository finished in the TUI — with no error and no explanation, just
    // "iteration limit" at the end. Measured on a six-step task: eight tool calls
    // and the answer never arrived.
    //
    // Same root cause as the headless prompt: the headless path is a second, lesser
    // implementation of the same agent, and every place it diverges is a place
    // where `--chat` is quietly worse than the TUI.
    const iter_limit = agent.iterationLimit();
    var iteration: usize = 0;
    var elided_total: usize = 0;
    while (iteration < iter_limit) : (iteration += 1) {
        // Context under budget: elide old tool dumps (a wire view).
        {
            // The same policy as the TUI, through the same two functions. This call
            // site is the headless runner, and it used to be a third definition of
            // "what compaction does": `off` here was ignored, so `--chat` compacted
            // whatever the user had switched off.
            const cmode = compaction_mod.effectiveMode(env, null);
            const comp = if (cmode == .off)
                compaction_mod.nothingElided(msgs.items)
            else
                compaction_mod.elideTier(arena, msgs.items, compaction_mod.budgetFor(env, agent.curModelContext()), env, cmode) catch
                    compaction_mod.nothingElided(msgs.items);
            if (comp.elided > 0) elided_total += comp.elided;
            var cur: []chat.ChatMessage = try arena.dupe(chat.ChatMessage, comp.msgs);

            // Tier 2: summarize the old stretch with the LLM if eliding was not enough.
            if (comp.needs_summary and comp.summary_upto > 0) {
                const upto = @min(comp.summary_upto, cur.len);
                const starts_sys = cur.len > 0 and std.mem.eql(u8, cur[0].role, "system");
                const sum_from: usize = if (starts_sys) 1 else 0;
                if (upto > sum_from) {
                    models.dbg("[compaction] summarizing old turns…\n", .{});
                    if (agent.summarizeTurns(
                        gpa,
                        &http,
                        url,
                        key,
                        kind,
                        model_name,
                        effort_pref,
                        cur[sum_from..upto],
                        arena,
                        extra_headers,
                        agent.outputCapFor(def, env),
                    )) |s| {
                        const note = try std.fmt.allocPrint(
                            arena,
                            "[earlier conversation summarized to fit the context budget]\n{s}",
                            .{s},
                        );
                        var nm: std.ArrayList(chat.ChatMessage) = .empty;
                        try nm.appendSlice(arena, cur[0..sum_from]);
                        try nm.append(arena, .{ .role = "user", .content = note });
                        try nm.appendSlice(arena, cur[upto..]);
                        cur = nm.items;
                        models.dbg("[compaction] old turns summarized\n", .{});
                    }
                }
            }

            msgs.clearRetainingCapacity();
            try msgs.appendSlice(arena, cur);
        }
        // The images go on the wire for THIS request and are then gone. Consumed
        // once: the same screenshot in four consecutive requests is four times the
        // tokens for information the model already has.
        var wire = msgs.items;
        defer pending_images.clear(gpa);
        if (!pending_images.isEmpty()) {
            const note = images_mod.wireNote(arena, &pending_images) catch "";
            if (note.len > 0) {
                const with = arena.alloc(chat.ChatMessage, msgs.items.len + 1) catch msgs.items;
                @memcpy(with[0..msgs.items.len], msgs.items);
                with[msgs.items.len] = .{ .role = "user", .content = note, .images = pending_images.images[0..pending_images.len] };
                wire = with;
            }
        }
        const body = chat.buildBodyMessagesCapped(body_buf, model_name, wire, effort_pref, tools_mod.toolsJson(), kind, agent.outputCapFor(def, env)) catch return error.BodyTooBig;

        const Cb = struct {
            fn onDelta(_: ?*anyopaque, delta: []const u8) void {
                models.dbg("{s}", .{delta});
            }
        };

        const result = chat.streamChatCtx(gpa, &http, url, key, @constCast(body), .{
            .userdata = null,
            .onDelta = Cb.onDelta,
        }, kind, true, extra_headers) catch |err| {
            // The server's reason, for EVERY error and not only for a 5xx.
            //
            // A 401 is the case this matters most in and the one that used to
            // print only `AuthFailed`: OpenRouter answers a dead key with
            // `{"error":{"message":"User not found."}}` and an expired one with
            // `API key expired`, and those two send you to different places
            // (rotate the key / get a new one) while `AuthFailed` sends you to
            // neither. The TUI has shown it since June; this runner did not.
            const why = chat.lastErrorBody();
            if (why.len > 0) {
                models.dbg("\n[error] {t}: {s}\n", .{ err, why });
            } else {
                models.dbg("\n[error] {t}\n", .{err});
            }
            return 1;
        };
        defer result.ctx.destroy();
        cache_stats.session.recordFor(chat.last_usage, kind);

        if (result.ctx.parts.items.len == 0) {
            // THE EXIT GATE, and it is here rather than after the loop for the same
            // reason it is there in the TUI: a run that has produced its final answer is
            // exactly the moment a red build has to stop it, and after the loop the
            // answer has already been printed.
            //
            // `--chat` used to end the run on a final answer with the automatic check
            // still in flight, and then wait for it at the very bottom and PRINT the
            // errors as a footnote of a run it had already called finished. A user
            // scripting this saw a clean exit and a red build.
            if (auto_check.exitGate(&bg, gpa, io)) |refusal| {
                defer gpa.free(refusal);
                models.dbg("\n[not done] {s}\n", .{refusal});
                // The model needs the diagnostics, not just the refusal: it is the only
                // thing that can act on them, and the nudge is what makes it act.
                if (auto_check.noteSlice().len > 0) {
                    try msgs.append(arena, .{ .role = "user", .content = auto_check.noteSlice() });
                }
                try msgs.append(arena, .{
                    .role = "user",
                    .content = "The harness will not end this run yet: the code you wrote does not have a passing check behind it. Fix the problems above and carry on.",
                });
                // The iterations left are counted by the `while` above, so this costs a
                // turn and says so.
                continue;
            }
            // Gate passed: the user's stop hook can now claim the turn.
            // The gate ran first (above), so they never both claim the turn.
            if (auto_check.stopHookCheck("turn_end", gpa)) |refusal| {
                models.dbg("\n[not done] {s}\n", .{refusal});
                try msgs.append(arena, .{
                    .role = "user",
                    .content = "The harness will not end this run yet: a stop hook is in force. Resolve it and end the run, or remove the hook.",
                });
                continue;
            }
            const s = &cache_stats.session;
            models.dbg("\n[cache] {d:.1}% hit-rate · {d} prompt / {d} cached tokens", .{ s.hitRatePct(), s.prompt_tokens, s.cached_tokens });
            // WHY, because a rate with no cause is not actionable, and this is
            // the path a script or a first run actually uses.
            //
            // Measured 2026-10-04 with an identical 3.5k prefix: `openrouter/free`
            // answers 3583 / 3273 / 3381 and serves 0% (it is a router, and routers
            // do not share a prompt cache with each other), while a fixed model
            // answers 3611 / 3613 / 3613 and serves 98%.
            switch (s.verdict()) {
                .routing => models.dbg(
                    "\n[cache] the model is a ROUTER: the prompt count went DOWN {d} time(s) with nothing removed from the conversation, so a different tokenizer counted the same thing. Routers do not share a prompt cache, so no prefix arrangement can make one hit. Pick a model, not a router (`model:free` is a MODEL that happens to be free — measured 98% cached).",
                    .{s.prompt_shrinks},
                ),
                .provider_uncached => models.dbg(
                    "\n[cache] the prefix is fine (the count only went up) and this provider does not cache at all. A fixed model on openrouter reaches 98%.",
                    .{},
                ),
                else => {},
            }
            if (elided_total > 0) models.dbg(" · {d} tool results elided", .{elided_total});
            models.dbg("\n", .{});
            // What the harness actually proved about the code this run wrote, in the
            // word that is true of it — "typechecked", never "verified". A script that
            // prints "done" over a typecheck claims a test run nobody did, and the person
            // reading the CI log is the one who stops looking.
            printProofLine(&auto_check, gpa);
            return 0; // final answer
        }

        // Runs the tools (headless = yolo) and feeds the results back.
        const tc_json = try result.ctx.toolCallsJson(arena);
        try msgs.append(arena, .{ .role = "assistant", .content = "", .tool_calls_json = tc_json });
        for (result.ctx.parts.items) |*p| {
            models.dbg("\n[tool {s}] {s}\n", .{ p.name.items, p.args.items });
            const res = execHeadless(io, &bg, &tasks, &pending_images, p.name.items, p.args.items, arena) catch |err| {
                try msgs.append(arena, .{
                    .role = "tool",
                    .content = try std.fmt.allocPrint(arena, "error: {t}", .{err}),
                    .tool_call_id = try arena.dupe(u8, p.id.items),
                });
                continue;
            };
            models.dbg("[result] {s}\n", .{res[0..@min(res.len, 200)]});
            try msgs.append(arena, .{
                .role = "tool",
                .content = res,
                .tool_call_id = try arena.dupe(u8, p.id.items),
            });
            // The AUTOMATIC typecheck, started here for the same reason the TUI
            // starts it: an edit to code is followed by a compiler run without the
            // model asking, because the model finds out it broke something one
            // iteration too late otherwise. It lives in `execToolCalls` for the TUI
            // and it used to exist ONLY there — so `--chat`, the runner every pty
            // test and measurement drives, edited code and never compiled it.
            //
            // `noteWrite` then `afterTool`, not `afterTool` with the arguments, because
            // the gate's write counter has to count calls that WROTE. The line above
            // this one is the `catch` for a failed call, so anything that gets here
            // succeeded; before, a failed `write` still started a check of the old
            // contents and counted towards the exit gate.
            const wrote = auto_check.noteWrite(p.name.items, p.args.items);
            auto_check.afterTool(&bg, io, wrote);

            // The plan, applied. It used to be a `Model` field and `applyPlanCall`
            // only ran in the TUI's path, so a `todo` call here answered **"plan
            // recorded"** and recorded nothing: the model reached for the tool, the
            // tool reported success, and nothing anywhere changed.
            if (std.mem.eql(u8, p.name.items, "todo")) {
                if (agent.applyPlanTo(&plan, p.args.items, arena)) |line| {
                    models.dbg("[plan] {s}\n", .{line});
                    if (plan.allDone()) models.dbg("[plan] every step is done\n", .{});
                }
            }
        }

        // Whatever the automatic check found, before the next request goes out. It
        // goes in as a `user` message after the `tool` results, which is a shape
        // every provider accepts — the alternative, a `tool_result` with no call id,
        // is not a thing.
        if (auto_check.autoCheckWait(&bg)) |note| {
            try msgs.append(arena, .{ .role = "user", .content = note });
            models.dbg("[auto-check] {s}\n", .{note});
        }
    }
    // The automatic typecheck, waited for at the END of the run.
    //
    // Measured: with the result only read at the start of the next iteration, a run
    // that ended right after the edit collected nothing — the `zig build` it had
    // started was still running — so the feature produced nothing on exactly the
    // turns it exists for. This is the one moment blocking is free: the run is over
    // and the answer is about to be printed.
    if (auto_check.autoCheckWait(&bg)) |note| {
        models.dbg("\n[auto-check] {s}\n", .{note});
    }
    printProofLine(&auto_check, gpa);

    // UNFINISHED, and the first word, for the same reason the TUI says it that way:
    // a run that reached its ceiling ran out of room, which is not the same thing as
    // the task being finished, and the one thing a user of a script must not be left
    // guessing is which of the two it is. The exit code is 0 because nothing crashed;
    // the sentence is what tells the truth.
    if (auto_check.gate.wroteCode()) {
        models.dbg(
            "\nUNFINISHED: {d} iterations and the code has no passing check behind it. {d} file write(s) with nothing green covering them.\n",
            .{ iter_limit, auto_check.gate.unverified() },
        );
    }
    models.dbg("\n[iteration limit reached after {d} iterations]\n", .{iter_limit});
    return 0;
}

/// The end-of-turn proof line, printed for the headless runner.
///
/// The same sentence the TUI pushes into its history, from the same function, because
/// a script's output and a terminal's history are the same report with two different
/// renderers — and the first version of the gate made them disagree: `--chat` printed
/// "finished" and put the errors underneath as a footnote.
fn printProofLine(ac: *const agent.AutoCheck, gpa: std.mem.Allocator) void {
    if (!ac.gate.wroteCode()) return;
    const line = ac.proofLine(gpa) orelse return;
    defer gpa.free(line);
    models.dbg("\n{s}\n", .{line});
}

/// The headless system prompt: the default one plus the ask guidance, and the
/// skills section when the project has any.
///
/// Built per run and freed by the caller (a `const` string literal cannot carry
/// the skill list, which depends on what is on disk). `ask.guidance` goes in even
/// though the headless runner refuses `ask`: the guidance is about WHEN to
/// consider a question, and `task` returns "the user has to decide X" to the main
/// agent, which is the same decision arriving through a different door.
/// Returns gpa-owned memory. The caller frees it (the `arena` of the run owns it
/// for the whole process, which is the simplest correct owner here).
fn headlessSystemPrompt(a: std.mem.Allocator, env: ?*const std.process.Environ.Map) ![]u8 {
    // `buildSystemPromptFor` and NOT a composition of its own. This function used
    // to build `base + ask + skills + location` and leave out `tool_routing_prompt`
    // and `verification_prompt`, which made `--chat` — the runner every pty test
    // and every measurement in this repo drives — an agent with no routing rules at
    // all. It reached for `bash zig build` where `check` exists and for
    // `bash curl` where `web_search` exists, and none of that was visible from the
    // TUI, where the same rules do work.
    //
    // Two prompts for one agent is not a configuration, it is a second definition
    // of how the harness wants to be used. There is one now.
    //
    // `ask.guidance` is inside it, and the runner still refuses `ask`: the guidance
    // is about WHEN to consider a question, and `task` returns "the user has to
    // decide X" to the main agent, which is the same decision through another door.
    return try agent.buildSystemPromptFor(a, env);
}
/// `tools_mod.execute` plus the background registry.
///
/// A thin wrapper and not a change to the signature of `execute`: the registry
/// lives in the `Model` in the TUI, and a headless run has none, so it is passed
/// as a parameter that only the caller knows about.
fn execHeadless(
    io: std.Io,
    bg: *bgproc.Registry,
    tasks: *taskstore.Store,
    images: *images_mod.Pending,
    name: []const u8,
    args: []const u8,
    arena: std.mem.Allocator,
) ![]const u8 {
    // `read` on a picture goes the same way as in the TUI, through the SAME
    // function. The first version of the image feature only existed in the TUI's
    // loop, and `zode --chat` — the runner every pty test drives — happily
    // returned raw PNG bytes with no error anywhere.
    if (std.mem.eql(u8, name, "read")) {
        if (agent.prepareImageFor(arena, io, images, agent.curAnswering(), args)) |res| {
            return res;
        }
    }
    // NO read cache in the headless runner: it is one turn, one context, and the
    // cache would only be able to help within it. The headless agent is also where
    // a "you already have this" answer is most confusing to debug, because there
    // is no session on screen to compare against.
    return tools_mod.executeWith(io, name, args, arena, bg, null, tasks);
}

/// TUI mode: zode (no args)
/// Startup breakdown, printed to stderr when `ZODE_DBG_BOOT` is set.
///
/// It exists because "the launch takes 56 ms" does not say WHICH 56 ms, and the two
/// halves behave completely differently: the work in this function is ours and can be
/// moved, while `vxfw.App.run`'s terminal query is inside vaxis and cannot be touched
/// from here (ROADMAP patch 5.9 — patching the dependency cache is worse than no
/// patch). Without the split, a regression in our startup and a terminal that takes a
/// second to answer look identical on screen.
///
/// **Its own state, not the agent's globals.** The first mark is inside `runTui`
/// BEFORE `agent.environ_global` and `agent.gpa_global` are assigned, and a probe
/// that reads a global that is still `undefined` does not print nothing: it prints
/// garbage or jumps through a null vtable. The first version did exactly that and
/// showed nothing at all, which is indistinguishable from "the marks do not fire".
fn runTui(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    agent.bootStart(io, init.environ_map);

    // What the terminal can do, BEFORE a single cell is painted.
    //
    // vaxis does not ask the terminal whether it speaks truecolor (its own
    // `COLORTERM` sniffing is commented out in the library) and it does not
    // convert rgb→256 either: it writes `38;2;r;g;b` whatever the terminal
    // answered. So a terminal that does not speak truecolor got a byte
    // sequence it does not understand. The app asks the environment instead,
    // which is where every terminal documents the answer.
    theme.caps = theme.detectCaps(init.environ_map);

    // 64 KiB instead of 1 MB (5.4 of the ROADMAP): the TTY buffer is PERMANENT
    // memory (it lives for the whole process) and 1 MB is paid for 99% of the
    // time without being written. With a token stream chunk by chunk it is plenty.
    const tty_buffer = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(tty_buffer);

    var app = try vxfw.App.init(io, gpa, init.environ_map, tty_buffer);
    defer app.deinit();
    // Registered AFTER `defer app.deinit()` so it runs BEFORE it: the thread writes
    // into `app.vx`, and the error path of `App.run` frees the App while it might
    // still be counting.
    agent.startTermQueryCap(&app.vx, init.environ_map);
    defer agent.stopTermQueryCap();
    // ── the keyboard mode ──
    //
    // `CSI > 1 u` (kitty "disambiguate") is what makes the terminal SEND
    // `CSI 13;2u` for Shift+Enter. Without it, no terminal reports a modified
    // Enter at all: every one of them sends a bare `\r`, so "Shift+Enter inserts
    // a newline" — which `tui.editorKey` has always implemented — was code that
    // could never be reached. The key was never woken up.
    //
    // `CSI < u` restores it, and it is registered AFTER so it runs BEFORE the
    // `defer`s that free the writer underneath it.
    kittyKeyboardPush(app.tty.writer());
    defer kittyKeyboardPop(app.tty.writer());
    agent.bootMark("vxfw.App.init");

    var model = tui.Model.init(gpa);
    defer model.deinit();
    model.environ = init.environ_map;
    agent.status_model_target = &model;
    model.attachIo(io); // for the activity strip clock
    model.attach();

    agent.io_global = io;
    // Without this the `models.dbg` diagnostics (status + server body) do not
    // show up in the TUI: you only see "models: HTTP error at <url>" and
    // nothing else, which does not say whether it was a 401, a 403 or a 404.
    models_mod.dbg_io = io;
    agent.api_key_global = envGet(init.environ_map, "ZODE_API_KEY");
    agent.environ_global = init.environ_map;
    agent.gpa_global = init.gpa;
    // Per-tool output caps from the environment (ZODE_MAX_TOOL_OUTPUT).
    tools_mod.initMaxToolOutput(init.environ_map);
    tools_mod.initDiffLimit(init.environ_map);
    tools_mod.initGrepCapture(init.environ_map);
    // The language servers, before the config is read: the config says which
    // servers there are, and the manager is what asks for them.
    //
    // Nothing is spawned here. A server is started when a file of its language
    // is asked about, so a session that never uses `lsp` never pays for one.
    lsp_manager.init(init.gpa, io, init.environ_map);
    defer lsp_manager.shutdown();
    // The MCP servers, for the same reason and with the same laziness: the
    // manager has to exist before the config is read (the config says which
    // servers there are) and nothing is spawned until a server is asked about.
    mcp_manager.init(init.gpa, io, init.environ_map);
    defer mcp_manager.shutdown();
    // The automatic typecheck reads `ZODE_AUTO_CHECK` off its OWN environment field,
    // not off the module global, so this is not optional: without it the flag silently
    // reads as "no environment" and every setting takes its default.
    agent.attachAutoCheckEnv(&model.auto_check, init.environ_map);
    // Before `bootstrapSession` and before anything composes a prompt: the AGENTS.md
    // and the skills roots are both derived from it.
    agent.initProjectInfo(io, init.environ_map);
    agent.bootMark("initProjectInfo");
    free_auto.attachIo(io);
    chat.io_global = io;
    chat.dbgInitEnv(init.environ_map);
    // Same for the model catalog, whose diagnostics also land on the terminal.
    models_mod.dbgInitEnv(init.environ_map);
    // `ZODE_RESUME=1` turns the resume ON. It does NOT turn it OFF: the
    // `--resume` FLAG has already set it by the time we get here (main
    // dispatches it before calling `runTui`), and this line used to
    // overwrite it with the environment's answer — so `zode --resume`
    // silently started a NEW session and said "nothing to resume; starting a
    // new session", which is exactly what the flag asks it not to do.
    agent.resume_on_start = agent.shouldResume(agent.resume_on_start, init.environ_map);
    defer agent.shutdownUserConfig();
    defer agent.shutdownBuffers(); // the 1 MiB body buffer (see `bodyBuf`)
    agent.loadUserConfig();
    agent.bootMark("loadUserConfig");
    agent.bootstrapSession(&model);
    agent.bootMark("bootstrapSession");

    // Welcome header: just the wordmark, in the `.banner` Kind (brand blue)
    // instead of `.info` (grey).
    model.pushHeader(.idle);

    // [roster] Free-auto: if the environment asks for it, the pool of free models
    // is built in a worker (it does not block startup) and the status bar shows
    // it as soon as it is there. It runs AFTER `loadUserConfig`, because without
    // the user's config the pool would not see their providers.
    agent.initFreeAutoFromEnv(&model);
    agent.bootMark("initFreeAutoFromEnv");
    // User slash commands: scanned once here so the `/` completion knows them
    // from the first keystroke (later refreshes: /help, the palette, an
    // unknown /name — the moments that already do I/O).
    agent.refreshUserCommandsModel(&model);
    agent.bootMark("userCommands");
    agent.initCheapRouterFromEnv(model.environ);
    // The status row is `provider/model`, and the model's name only exists in
    // the provider's catalogue: without this, the row says `opencode` for the
    // whole of a session's first minute — the moment the user is deciding
    // whether the app knows what it is doing. Silently warms the catalogue into
    // the cache (`resolveStatusModel` reads it from there); no history line, no
    // status change, so the hero is not interrupted.
    tui.resolveStatusModel(&model);
    if (model.status_model_len == 0) {
        agent.catalogWarmupAsync(&model) catch {};
    }

    // Self-update check: a worker, its own `Io`, and an answer cached on disk for
    // six hours — so a normal start reads ~60 bytes instead of opening TLS to
    // GitHub. When a newer release exists it is SAID in the history
    // (`v0.2.0 is available (minor) · /update`) instead of the binary being
    // replaced behind the user's back, which is what `autoUpdate` used to do
    // while the running process went on being the old build.
    agent.startUpdateCheck(&model);

    agent.bootMark("app.run start");

    // WHY WE ARE LEAVING, ALWAYS, ON STDERR.
    //
    // Measured over five real task runs: the process ended, mid-turn, with the work
    // done and no verdict declared — and the log said NOTHING. No panic, no error, no
    // message. `tmux` reports the session gone, `capture-pane` says the server is not
    // running, and stderr has one `info(vaxis)` line in it. Five runs produced zero
    // information about why, and the first four hours of diagnosis went on hypotheses
    // (frame arena, segment cache, a garbage grapheme length, memory growth) because
    // there was nothing to read.
    //
    // A program that vanishes without a word is a bug in the program, not only in
    // whatever made it vanish. The cost is two lines and it is paid only at exit.
    //
    // `ZODE_EXIT_TRACE=1` to see it; without it, only when something went wrong, which
    // is the case that needs it. A clean exit has always been silent and must stay so:
    // a message on every ctrl+c would be noise the user learns to ignore, and the one
    // time they need to read it is the time it is missing.
    const exit_trace = envGet(init.environ_map, "ZODE_EXIT_TRACE") != null;

    app.run(model.widget(), .{}) catch |err| {
        // This is the branch that matters most and it used to be `try`, which printed
        // the error and nothing else: no clue about which turn, which tool, how much was
        // in flight, or how much memory the process was holding at the moment it gave
        // up. Every one of those is a question the next bug will ask.
        std.debug.print(
            \\zode: the TUI stopped with `{t}`.
            \\  busy: {s} · streaming: {s} · queue: {d}
            \\  history: {d} paragraphs · plan: {d}/{d} done
            \\  workers in flight: {d}
            \\
        , .{
            err,
            if (model.workingPublic()) "yes" else "no",
            if (model.streaming) "yes" else "no",
            model.queuedCount(),
            model.paras.items.len,
            model.plan.doneCount(),
            model.plan.items.len,
            model.workers.load(.monotonic),
        });
        return err;
    };
    if (exit_trace) std.debug.print("zode: the TUI returned normally; quitting.\n", .{});

    // Out through `quitFast`, not through the defers.
    //
    // Workers are spawned with `detach`, so nobody joins them, and waiting for them
    // before the defers run was what kept a worker inside `io.async` from touching
    // freed memory. But it cost 767 ms with a turn in flight and 1.47 s with a
    // background job, because `waitWorkers` counts spins rather than milliseconds.
    //
    // `quitFast` gets the same safety without the wait: it kills the children, asks
    // the workers to stop, writes the session's last append, and then EXITS without
    // running a single defer — so nothing is freed and there is nothing for a late
    // worker to touch. Measured 18 ms idle, and the numbers for the busy cases are in
    // its own doc comment.
    agent.quitFast(&model, io);
}

/// One HTTPS request, and exit.
///
/// This exists for the UPDATER, and the reason is a real crash: `--version`
/// proves the binary starts and does NOT prove it can do TLS. The 0.1.0 asset
/// was built with the CI runner's CPU, answered `--version` perfectly, and
/// trapped with SIGILL inside the TLS handshake seconds after its first frame.
/// So `/update` runs the downloaded file with this flag before it replaces the
/// binary that works.
///
/// The exit code is deliberately 0 for every UNCLEAN outcome (a network error,
/// an unreachable host): the network is not the binary's fault and must not
/// veto an update. Only a FAULT is a verdict, and the caller reads that from
/// the process term (a signal), not from here.
pub fn runSelftest(init: std.process.Init) u8 {
    var threaded: std.Io.Threaded = .init(init.gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client: std.http.Client = .{ .allocator = init.gpa, .io = io };
    defer client.deinit();

    const uri = std.Uri.parse("https://api.github.com/") catch return 0;
    var req = client.request(.GET, uri, .{ .headers = .{
        .accept_encoding = .omit,
        .user_agent = .{ .override = "zode-selftest" },
    } }) catch return 0;
    defer req.deinit();
    req.sendBodiless() catch return 0;

    var redirect_buf: [8192]u8 = undefined;
    _ = req.receiveHead(&redirect_buf) catch return 0;
    return 0;
}

pub fn main(init: std.process.Init) !u8 {
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next(); // argv[0]
    const first = it.next();

    if (first) |arg0| {
        if (std.mem.eql(u8, arg0, "--resume")) {
            agent.resume_on_start = true;
            return runTui(init);
        }
        if (std.mem.eql(u8, arg0, "--models")) {
            return runModels(init.gpa, init.io, init.environ_map);
        }
        if (std.mem.eql(u8, arg0, "--chat")) {
            const text = it.next() orelse {
                models.dbg("uso: zode --chat \"texto\"\n", .{});
                return 1;
            };
            return runChat(init.gpa, init.io, init.environ_map, text);
        }
        if (std.mem.eql(u8, arg0, "--selftest")) {
            return runSelftest(init);
        }
        if (std.mem.eql(u8, arg0, "--version")) {
            const version = @import("build_options").version;
            var buf: [128]u8 = undefined;
            var out = std.Io.File.stdout().writer(init.io, &buf);
            try out.interface.print("zode {s}\n", .{version});
            try out.interface.flush();
            return 0;
        }
        if (std.mem.eql(u8, arg0, "--help")) {
            std.debug.print(
                "zode — code agent harness\n\n" ++
                    "  (no args)    full TUI\n" ++
                    "  --models     list the models of the provider\n" ++
                    "  --chat TXT   send a message (streaming)\n" ++
                    "  --resume     resume the last session\n" ++
                    "  --version    show version\n" ++
                    "  --selftest   internal: one HTTPS request, for the updater\n" ++
                    "  --help       this help\n",
                .{},
            );
            return 0;
        }
        std.debug.print("unknown flag: {s}\n", .{arg0});
        return 1;
    }

    return runTui(init);
}
