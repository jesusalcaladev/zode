//! Headless (`--chat`) agent runner, split out of main.zig (Phase 42.9).
//! Same agent, same prompts and same tools as the TUI — only the renderer is
//! a terminal-less stdout/stderr sink. Everything here is reachable from
//! `main.zig` through the two public entry points.

const std = @import("std");
const http_client = @import("lib/http_client.zig");
const models = @import("lib/models.zig");
const models_mod = models;
const modelcache = @import("lib/modelcache.zig");
const provider = @import("lib/provider.zig");
const providers = @import("lib/providers.zig");
const tools_mod = @import("tools_root.zig");
const cache_stats = @import("cache_stats.zig");
const chat = @import("chat.zig");
const agent = @import("agent.zig");
const free_auto = @import("free_auto.zig");
const compaction_mod = @import("compaction.zig");
const taskloop = @import("lib/taskloop.zig");
const bgproc = @import("bgproc.zig");
const images_mod = @import("lib/images.zig");
const plan_mod = @import("lib/plan.zig");
const taskstore = @import("lib/taskstore.zig");
const team_mod = @import("lib/team.zig");
const usermessage_mod = @import("lib/usermessage.zig");
const jsonschema_mod = @import("lib/jsonschema.zig");
const structured_run = @import("lib/structured_run.zig");
const hooks_mod = @import("lib/hooks.zig");
const permrules = @import("lib/permrules.zig");
const pathsafe = @import("lib/pathsafe.zig");
const cmdsafety = @import("lib/cmdsafety.zig");
const ask = @import("lib/ask.zig");
const lsp_manager = @import("lsp/manager.zig");
const mcp_manager = @import("mcp/manager.zig");

fn envGet(map: ?*const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const m = map orelse return null;
    return m.get(key);
}

pub fn runChat(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, text: []const u8, schema_data: ?[]const u8) !u8 {
    // Phase 22: schema mode is a PROPERTY OF THIS RUN, never of the TUI.
    const schema_mode = schema_data != null;
    var structured_outcome = structured_run.Outcome{};
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
    free_auto.attachIo(io); // the cool-down clock for free-model rotation
    // The TUI initializes these from the env in runTui; the headless runner
    // never did, so every `--chat` error (including the provider's own reason)
    // was swallowed by models.dbg's `if (!dbg_flag) return`. A scripted run
    // that fails has to SAY why.
    chat.dbgInitEnv(env);
    models.dbgInitEnv(env);
    models.dbg_io = io;
    defer agent.shutdownUserConfig();
    defer agent.shutdownBuffers(); // the 1 MiB body buffer (see `bodyBuf`)
    agent.loadUserConfig();

    const def = agent.activeProviderDef(env);
    const kind = chat.kindForProvider(def.id);
    var url_buf: [1024]u8 = undefined;
    const url = if (kind == .anthropic)
        std.mem.print(&url_buf, "{s}/messages", .{def.base_url}) catch def.base_url
    else
        std.mem.print(&url_buf, "{s}/chat/completions", .{def.base_url}) catch def.base_url;
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
    const base_system = try headlessSystemPrompt(arena, env);
    const schema_directive = structured_run.directive(schema_mode);
    const system_content = if (schema_mode)
        try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ base_system, schema_directive })
    else
        base_system;
    try msgs.append(arena, .{ .role = "system", .content = system_content });
    // `@file` mentions work in headless too: the TUI expands them in
    // `runOneTurn` (`withMentions`), but this runner sent the raw text, so
    // `zode --chat "explain @src/foo.zig"` made the model answer "I don't have
    // the file". Expanded HERE, on the session's own text, because the headless
    // runner has no per-iteration arena like `runOneTurn` has.
    const mentions_mod = @import("lib/mentions.zig");
    const expanded = mentions_mod.expand(arena, io, text) catch
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
    // The team (Phase 20) is memory-only for a headless run, like `tasks`.
    var team = team_mod.Team.init(gpa);
    defer team.deinit();
    defer bg.deinit(io, gpa);
    // Permission rules and hooks (Phase 5/6/34): headless is yolo/non-interactive
    // (no permission dialog), but hooks must still be able to allow/deny/audit tool
    // use. Load project `.zode/permissions.json` and `.zode/hooks.json` via the
    // shared agent globals used by the permission/hook helpers.
    agent.loadPermRules();

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

    // `@shot.png` typed in --chat becomes a real attachment. `model_name` is
    // resolved above; `mentions.expand` no longer inlines image bytes as text.
    stageImageMentionsHeadless(arena, io, &pending_images, text, model_name);

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
    // Task-scoped budget ladder, same policy as the TUI.
    var policy = taskloop.Policy.init(agent.iterationLimit(), agent.loopBudgetFor(env).hard);
    var iteration: usize = 0;
    var elided_total: usize = 0;
    var gate_continues: u8 = 0;
    const gate_continue_limit: u8 = 3;
    var last_mark: ?agent.LoopMark = null;
    var reason: taskloop.StopReason = .done;
    while (policy.budget.allows(iteration)) : (iteration += 1) {
        // Task-scoped budget checkpoint: only from iteration 1 on.
        if (iteration > 0) {
            const mark = agent.loopMarkFromGate(
                auto_check.gate.writes,
                plan.doneCount(),
                auto_check.gate.verified_writes,
            );
            const changed = if (last_mark) |lm| !std.meta.eql(lm, mark) else true;
            policy.note(iteration, changed);
            last_mark = mark;
            switch (policy.decide(iteration)) {
                .work => {},
                .checkpoint => {
                    try msgs.append(arena, .{
                        .role = "user",
                        .content = std.fmt.allocPrint(arena,
                            "Checkpoint: {d} iterations used, {d} left before the next one. Keep going and finish what is open; do not restart work that is already done.\n",
                            .{ iteration, policy.budget.soft - iteration },
                        ) catch continue,
                    });
                },
                .stop => |why| {
                    reason = why;
                    break;
                },
            }
        }
        // Context under budget: elide old tool dumps (a wire view).
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
                compaction_mod.elideTier(arena, msgs.items, compaction_mod.budgetFor(env, agent.curModelContext()), env, agent.curModelContext(), cmode) catch
                    compaction_mod.nothingElided(msgs.items);
            if (comp.elided > 0) elided_total += comp.elided;
            var cur: []chat.ChatMessage = try arena.dupe(chat.ChatMessage, comp.msgs);

            // Tier 2: summarize the old stretch with the LLM if eliding was not enough.
            if (comp.needs_summary and comp.summary_upto > 0) {
                const upto = @min(comp.summary_upto, cur.len);
                const starts_sys = cur.len > 0 and std.mem.eql(u8, cur[0].role, "system");
                var sum_from: usize = if (starts_sys) 1 else 0;
                // Never start the summary stretch on a critical message (goal,
                // plan, prior summary): keep those verbatim in the wire.
                while (sum_from < upto and compaction_mod.isCriticalMessage(cur[sum_from])) {
                    sum_from += 1;
                }
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
        // LAST-MOMENT VISION GATE, same as the TUI: the answering model can
        // change after the image was staged (cheap router, /free-auto rotation).
        // A model with no vision gets no bytes — just the typed text.
        if (!pending_images.isEmpty() and !models_mod.isVision(model_name)) {
            pending_images.clear(gpa);
        }
        if (!pending_images.isEmpty()) {
            const note = images_mod.wireNote(arena, &pending_images) catch "";
            if (note.len > 0) {
                const with = arena.alloc(chat.ChatMessage, msgs.items.len + 1) catch msgs.items;
                @memcpy(with[0..msgs.items.len], msgs.items);
                with[msgs.items.len] = .{ .role = "user", .content = note, .images = pending_images.images[0..pending_images.len] };
                wire = with;
            }
        }
        // Phase 22: in --schema mode the model is offered `structured_output`
        // in addition to the normal tools; in the TUI it never appears.
        const tools_json = if (schema_mode)
            try structured_run.withTool(arena, tools_mod.toolsJson(), structured_run.toolSchema(true))
        else
            tools_mod.toolsJson();
        const body = chat.buildBodyMessagesCapped(body_buf, model_name, wire, effort_pref, tools_json, kind, agent.outputCapFor(def, env)) catch return error.BodyTooBig;

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
                if (gate_continues >= gate_continue_limit) {
                    models.dbg(
                        "\nexit gate refused {d} times on a red build; ending this run anyway.\n",
                        .{ gate_continue_limit },
                    );
                    break;
                }
                gate_continues += 1;
                // The model needs the diagnostics, not just the refusal: it is the only
                // thing that can act on them, and the nudge is what makes it act.
                if (auto_check.noteSlice().len > 0) {
                    try msgs.append(arena, .{ .role = "user", .content = auto_check.noteSlice() });
                }
                try msgs.append(arena, .{
                    .role = "user",
                    .content = "The harness will not end this run yet: the code you wrote does not have a passing check behind it. Fix the problems above and carry on.",
                });
                continue;
            }
            // Completion contract: before the run may end naturally, the evidence
            // must allow it.
            const evidence = agent.loopEvidenceFromGate(auto_check.gate, plan);
            if (taskloop.endReason(evidence)) |why| {
                reason = why;
                break;
            }
            if (plan.doneCount() > 0 and plan.openCount() > 0) {
                try msgs.append(arena, .{
                    .role = "user",
                    .content = "Your plan still has open steps. Continue the task and close them, or call `goal` with status blocked and what_would_unblock if they cannot be finished here.",
                });
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
            // Phase 22: in schema mode a prose final answer is NOT a result.
            if (schema_mode and !structured_outcome.satisfied) {
                std.debug.print("error: the run ended without a valid structured_output call.\n", .{});
                return structured_run.exitCode(structured_outcome);
            }
            return structured_run.exitCode(structured_outcome); // final answer
        }

        // Runs the tools (headless = yolo) and feeds the results back.
        const tc_json = try result.ctx.toolCallsJson(arena);
        try msgs.append(arena, .{ .role = "assistant", .content = "", .tool_calls_json = tc_json });
        for (result.ctx.parts.items) |*p| {
            models.dbg("\n[tool {s}] {s}\n", .{ p.name.items, p.args.items });

            // Phase 22: `structured_output` is the final, validated answer.
            // It is NEVER dispatched as a normal tool — validate the model's
            // object against the caller's schema here. A mismatch is a named
            // error the model sees and can fix; success prints the JSON to
            // stdout and marks the run satisfied.
            if (schema_mode and std.mem.eql(u8, p.name.items, "structured_output")) {
                const so_result = try handleStructuredOutput(arena, io, schema_data.?, p.args.items, &msgs, p.id.items);
                if (so_result == .satisfied) {
                    structured_outcome.satisfied = true;
                    // Do not run other tools after the final call this turn.
                    break;
                }
                continue;
            }

            const res = execHeadless(io, &bg, &tasks, &team, &pending_images, p.name.items, p.args.items, arena) catch |err| {
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
        if (auto_check.autoCheckWait(&bg, io)) |note| {
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
    if (auto_check.autoCheckWait(&bg, io)) |note| {
        models.dbg("\n[auto-check] {s}\n", .{note});
    }
    printProofLine(&auto_check, gpa);

    // ── the ceiling: the tools are dead, the answer still has to come ──
    //
    // Reaching the ceiling means the turn ran out of room, not that the task is
    // finished, and the model knows where it stopped better than any harness
    // does. It is asked for one final word with NO tools (the tools field is
    // simply absent from this body), so it can only say what it did and what
    // it left open. Without this, a capped run ended silently with tool calls
    // and no verdict, which is a script waiting for an answer that never
    // came.
    try msgs.append(arena, .{
        .role = "user",
        .content = "The iteration budget for this session is exhausted. Tools are disabled for this reply — no code can be written now. Write a plain summary of at most 10 lines: what was actually done, what remains unfinished or unverified, which files were touched and the single next step. Do not apologize for stopping.",
    });
    const summary_body = chat.buildBodyMessagesCapped(body_buf, model_name, msgs.items, effort_pref, "", kind, agent.outputCapFor(def, env)) catch null;
    if (summary_body) |sm_body| {
        models.dbg("\n--- unfinished work summary (no tools) ---\n", .{});
        const Cb = struct {
            fn onDelta(_: ?*anyopaque, delta: []const u8) void {
                models.dbg("{s}", .{delta});
            }
        };
        if (chat.streamChatCtx(gpa, &http, url, key, @constCast(sm_body), .{
            .userdata = null,
            .onDelta = Cb.onDelta,
        }, kind, true, extra_headers)) |res| {
            res.ctx.destroy();
            models.dbg("\n--- end of summary ---\n", .{});
        } else |err| {
            models.dbg("(the summary call failed: {t})\n", .{err});
        }
    }

    // UNFINISHED, and the first word, for the same reason the TUI says it that way:
    // a run that reached its ceiling ran out of room, which is not the same thing as
    // the task being finished, and the one thing a user of a script must not be left
    // guessing is which of the two it is. The exit code is 0 because nothing crashed;
    // the sentence is what tells the truth.
    if (auto_check.gate.wroteCode()) {
        models.dbg(
            "\nUNFINISHED: {d} iterations and the code has no passing check behind it. {d} file write(s) with nothing green covering them.\n",
            .{ policy.budget.hard, auto_check.gate.unverified() },
        );
    }
    models.dbg("\n[stopped: {s} after {d} iterations]\n", .{ @tagName(reason), iteration });
    // Phase 22: reaching the ceiling (or any non-final exit) in schema mode
    // without a valid structured_output call is a loud failure for CI.
    if (schema_mode and !structured_outcome.satisfied) {
        std.debug.print("error: the run ended ({s}) without a valid structured_output call.\n", .{@tagName(reason)});
        return structured_run.exitCode(structured_outcome);
    }
    return structured_run.exitCode(structured_outcome);
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
/// Headless tool execution (Phase 34.14): yolo/non-interactive (no dialog),
/// but permission rules and hooks (PreToolUse/PostToolUse/PermissionRequest)
/// are enforced so automated hooks can allow/deny/audit in `--chat`.
fn execHeadless(
    io: std.Io,
    bg: *bgproc.Registry,
    tasks: *taskstore.Store,
    team: *team_mod.Team,
    images: *images_mod.Pending,
    name: []const u8,
    args: []const u8,
    arena: std.mem.Allocator,
) ![]const u8 {
    // `read` on a picture goes the same way as in the TUI.
    if (std.mem.eql(u8, name, "read")) {
        if (agent.prepareImageFor(arena, io, images, agent.curAnswering(), args)) |res| {
            return res;
        }
    }

    // Phase 21: `send_user_message` is the DURABLE answer in --chat too. There
    // is no Model here, so print the message to stdout (the script's result)
    // after validating it. Attachments that do not exist are a named error.
    if (std.mem.eql(u8, name, "send_user_message")) {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args, .{}) catch
            return "send_user_message needs a JSON object with a `message`.";
        if (parsed != .object) return "send_user_message needs a JSON object with a `message`.";
        const msg = usermessage_mod.parse(arena, parsed.object) catch |err| {
            return tools_mod.describeError(arena, err, "send_user_message", args);
        };
        if (usermessage_mod.missingAttachment(io, msg)) |bad| {
            return usermessage_mod.missingAttachmentText(arena, bad) catch "an attachment path does not exist.";
        }
        var out_buf: [8192]u8 = undefined;
        var out = std.Io.File.stdout().writer(io, &out_buf);
        out.interface.print("{s}\n", .{msg.text}) catch {};
        out.interface.flush() catch {};
        return std.fmt.allocPrint(arena, "message delivered to the user ({s})", .{msg.status.name()}) catch "message delivered";
    }

    const gpa = agent.gpa_global;
    const subjects = tools_mod.callSubjects(name, args, arena);

    // Bash: refuse commands that require an interactive TTY the harness cannot provide.
    if (std.mem.eql(u8, name, "bash")) {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args, .{}) catch null;
        if (parsed) |pv| {
            if (pv == .object) {
                if (pv.object.get("command")) |cmdv| {
                    if (cmdv == .string) {
                        const f = cmdsafety.classify(cmdv.string, arena);
                        if (f.verdict == .forbidden) {
                            return if (f.why.len > 0)
                                std.fmt.allocPrint(arena, "refused: {s}\ncommand: {s}", .{ f.why, f.fragment })
                            else
                                arena.dupe(u8, "refused: this command requires an interactive TTY the harness does not have.");
                        }
                    }
                }
            }
        }
    }

    // Permission rules (deny/allow/dontAsk/ask). Headless is yolo: we do not
    // prompt, but explicit deny rules must still refuse.
    const rule_decision = agent.permDecision(name, subjects);
    if (rule_decision) |d| {
        switch (d.action) {
            .allow, .dontAsk => {},
            .deny => return std.fmt.allocPrint(
                arena,
                "refused: the rule `{s}` ({s}) does not allow this.",
                .{ d.rule.text, d.rule.source.name() },
            ),
            .ask => {
                // No interactive dialog in headless; let PermissionRequest hooks decide below.
            },
        }
    }

    // Dangerous/sensitive paths: in yolo headless we do not prompt, but honor
    // explicit denials from PermissionRequest hooks when fired.
    const risky = tools_mod.riskyPaths(name, args, arena);

    // PermissionRequest hooks (34.14): fire for headless runs so hooks can
    // allow/deny/audit. If a hook denies, refuse. If it allows (or returns ask
    // in yolo/headless), continue; headless cannot show a dialog.
    {
        var detail_buf: [384]u8 = undefined;
        const arg: []const u8 = if (subjects.len > 0) subjects[0] else "";
        var detail: []const u8 = if (std.mem.eql(u8, name, "batch"))
            tools_mod.batchPermissionDetail(args, arena)
        else
            std.mem.print(&detail_buf, "{s} {s}", .{ name, arg }) catch name;
        if (std.mem.eql(u8, name, "bash") and arg.len > 0) {
            const why = cmdsafety.classify(arg, arena).why;
            if (why.len > 0) detail = std.fmt.allocPrint(arena, "{s} — {s}", .{ detail, why }) catch detail;
        }
        if (risky.len > 0) {
            // Name the first risky path in the hook subject/detail.
            const v = pathsafe.checkWrite(risky[0]);
            if (v != .ok) {
                const w = switch (v) { .dangerous => |d| d.why, else => "" };
                detail = if (w.len > 0)
                    std.fmt.allocPrint(arena, "{s} — risky path {s}: {s}", .{ detail, risky[0], w }) catch detail
                else
                    std.fmt.allocPrint(arena, "{s} — risky path {s}", .{ detail, risky[0] }) catch detail;
            }
        }
        const hook_subj = if (subjects.len > 0) subjects[0] else detail;
        const hook_res = hooks_mod.fire(gpa, &agent.hooks_set, .{
            .event = .PermissionRequest,
            .tool = name,
            .subject = hook_subj,
            .prompt = detail,
        }, io) catch &[_]hooks_mod.RunResult{};
        defer if (hook_res.len > 0) hooks_mod.freeResults(gpa, hook_res);
        if (hooks_mod.permissionDecision(hook_res)) |pd| {
            if (pd == .deny) {
                for (hook_res) |r| {
                    if (!r.ran or r.permission_decision != .deny) continue;
                    const reason = if (r.system_message.len > 0) r.system_message else if (r.additional_context.len > 0) r.additional_context else r.output;
                    if (reason.len > 0) {
                        return std.fmt.allocPrint(arena, "denied by PermissionRequest hook: {s}", .{reason});
                    }
                }
                return arena.dupe(u8, "denied by PermissionRequest hook");
            }
            // allow/ask: continue (headless is yolo/non-interactive).
        }
    }

    // PreToolUse hooks: may block or update tool input.
    var exec_args: []const u8 = args;
    {
        const hook_subj = if (subjects.len > 0) subjects[0] else args;
        const pre_res = hooks_mod.fire(gpa, &agent.hooks_set, .{
            .event = .PreToolUse,
            .tool = name,
            .subject = hook_subj,
            .prompt = args,
        }, io) catch &[_]hooks_mod.RunResult{};
        defer if (pre_res.len > 0) hooks_mod.freeResults(gpa, pre_res);
        if (hooks_mod.blockedReason(gpa, pre_res, .PreToolUse) catch null) |reason| {
            defer gpa.free(reason);
            return std.fmt.allocPrint(arena, "blocked by PreToolUse hook: {s}", .{reason});
        }
        if (hooks_mod.updatedInput(pre_res)) |ui| {
            exec_args = arena.dupe(u8, ui) catch args;
        }
    }

    // Execute the tool.
    var res = try tools_mod.executeTeam(io, name, exec_args, arena, bg, null, tasks, null, team);

    // PostToolUse hooks: append non-blocking notes/context to the tool result.
    {
        const hook_subj = if (subjects.len > 0) subjects[0] else exec_args;
        const post_res = hooks_mod.fire(gpa, &agent.hooks_set, .{
            .event = .PostToolUse,
            .tool = name,
            .subject = hook_subj,
            .prompt = res,
        }, io) catch &[_]hooks_mod.RunResult{};
        defer if (post_res.len > 0) hooks_mod.freeResults(gpa, post_res);
        if (hooks_mod.notesText(gpa, post_res) catch null) |note| {
            defer gpa.free(note);
            res = std.fmt.allocPrint(arena, "{s}\n[hook note] {s}", .{ res, note }) catch res;
        }
    }

    return res;
}


/// True when the cached catalogue is older than its TTL.
pub fn ageIsStale(io: std.Io, fetched_at: i64) bool {
    return modelcache.isStale(io, fetched_at);
}

fn stageImageMentionsHeadless(
    arena: std.mem.Allocator,
    io: std.Io,
    pending: *images_mod.Pending,
    text: []const u8,
    model: []const u8,
) void {
    const mentions_local = @import("lib/mentions.zig");
    const scanned = mentions_local.scan(text) catch return;
    const has_vision = models_mod.isVision(model);
    for (scanned.mentions[0..scanned.count]) |mention| {
        const path = mention.pathOf();
        const mime = images_mod.mimeForPath(path) orelse continue;
        if (pending.len >= images_mod.max_images) break;
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(images_mod.max_bytes)) catch continue;
        var p = images_mod.prepare(arena, path, bytes, mime, has_vision) catch continue;
        defer p.deinit(arena);
        const b64 = p.image_b64 orelse continue;
        p.image_b64 = null;
        const slot = &pending.images[pending.len];
        slot.* = .{ .mime = mime, .data_b64 = b64, .path = arena.dupe(u8, path) catch "" };
        pending.len += 1;
        pending.total_bytes += bytes.len;
        pending.user_attached = true;
    }
}

const StructuredResult = enum { satisfied, retry };

fn handleStructuredOutput(
    arena: std.mem.Allocator,
    io: std.Io,
    schema_text: []const u8,
    args_json: []const u8,
    msgs: *std.ArrayList(chat.ChatMessage),
    call_id: []const u8,
) !StructuredResult {
    const schema = std.json.parseFromSliceLeaky(std.json.Value, arena, schema_text, .{}) catch {
        std.debug.print("error: the caller's JSON schema is malformed.\n", .{});
        return error.BadSchema;
    };
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch {
        try msgs.append(arena, .{
            .role = "tool",
            .content = "structured_output needs a JSON object with an `object` field.",
            .tool_call_id = try arena.dupe(u8, call_id),
        });
        return .retry;
    };
    var obj: std.json.Value = parsed;
    if (parsed == .object) {
        if (parsed.object.get("object")) |inner| obj = inner;
    }

    const verdict = try jsonschema_mod.validate(arena, schema, obj);
    switch (verdict) {
        .fail => |v| {
            const text = try jsonschema_mod.violationText(arena, v);
            try msgs.append(arena, .{ .role = "tool", .content = text, .tool_call_id = try arena.dupe(u8, call_id) });
            return .retry;
        },
        .ok => {},
    }

    // Validated: the JSON is the run's result. Print ONLY the object to stdout
    // so a script can parse it directly (diagnostics go to stderr).
    var out_buf: [64 * 1024]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &out_buf);
    try std.json.Stringify.value(obj, .{}, &out.interface);
    try out.interface.writeAll("\n");
    try out.interface.flush();
    return .satisfied;
}
