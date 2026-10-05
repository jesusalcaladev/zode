const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const tui = @import("tui.zig");
const http_client = @import("lib/http_client.zig");
const models = @import("lib/models.zig");
const models_mod = models;
const provider = @import("lib/provider.zig");
const providers = @import("lib/providers.zig");
const tools_mod = @import("tools/dispatch.zig");
const cache_stats = @import("cache_stats.zig");
const chat = @import("chat.zig");
const agent = @import("agent.zig");
const free_auto = @import("free_auto.zig");
const compaction_mod = @import("compaction.zig");
const mascot = @import("lib/mascot.zig");
const bgproc = @import("bgproc.zig");
const images_mod = @import("lib/images.zig");
const skills = @import("lib/skills.zig");
const ask = @import("lib/ask.zig");

fn envGet(map: ?*const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const m = map orelse return null;
    return m.get(key);
}

/// Headless mode: zode --models
fn runModels(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map) !u8 {
    models.dbg_io = io; // for diagnostics
    var http = http_client.Http.init(gpa, io);
    defer http.deinit();

    const cfg = provider.Config.load(env);
    var url_buf: [1024]u8 = undefined;
    const url = cfg.urlModels(&url_buf);
    const key = envGet(env, "ZODE_API_KEY");

    var list = models.listModels(gpa, &http, url, key) catch |err| {
        std.debug.print("error: {t}\n", .{err});
        return 1;
    };
    defer list.deinit(gpa);

    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &out_buf);
    for (list.items) |m| {
        try out.interface.print("{s}\t{s}\n", .{ m.id, m.owned_by });
    }
    try out.interface.flush();
    std.debug.print("{d} modelos ({d} free)\n", .{ list.items.len, list.free_count });
    return 0;
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
    agent.initProjectInfo(io, env); // cwd + repo root, before any prompt is composed
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

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var msgs: std.ArrayList(chat.ChatMessage) = .empty;
    // Images a `read` left behind: on the wire for ONE request and then gone, the
    // same rule as the TUI.
    var pending_images: images_mod.Pending = .{};
    // The `arena`, not the `gpa`: this text lives as long as the conversation
    // does, and the arena dies at the end of the run. With `gpa` it was a leak
    // per process (the DebugAllocator says so on exit, which is how it showed up).
    try msgs.append(arena, .{ .role = "system", .content = headlessSystemPrompt(arena, env) });
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
            std.debug.print("error: could not read {s}'s model catalog ({t}).\n", .{ def.id, err });
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

    var iteration: usize = 0;
    var elided_total: usize = 0;
    while (iteration < 6) : (iteration += 1) {
        // Context under budget: elide old tool dumps (a wire view).
        {
            const comp = compaction_mod.elideTier(arena, msgs.items, compaction_mod.budgetFor(env, agent.curModelContext()), env) catch
                compaction_mod.Compacted{ .msgs = msgs.items };
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
        defer pending_images.clear();
        if (!pending_images.isEmpty()) {
            const note = images_mod.wireNote(arena, &pending_images) catch "";
            if (note.len > 0) {
                const with = arena.alloc(chat.ChatMessage, msgs.items.len + 1) catch msgs.items;
                @memcpy(with[0..msgs.items.len], msgs.items);
                with[msgs.items.len] = .{ .role = "user", .content = note, .images = pending_images.images[0..pending_images.len] };
                wire = with;
            }
        }
        const body = chat.buildBodyMessages(body_buf, model_name, wire, effort_pref, tools_mod.toolsJson(), kind) catch return error.BodyTooBig;

        const Cb = struct {
            fn onDelta(_: ?*anyopaque, delta: []const u8) void {
                models.dbg("{s}", .{delta});
            }
        };

        const result = chat.streamChatCtx(gpa, &http, url, key, @constCast(body), .{
            .userdata = null,
            .onDelta = Cb.onDelta,
        }, kind, true) catch |err| {
            if (err == error.ServerError) {
                models.dbg("\n[error server] {s}\n", .{chat.lastErrorBody()});
            } else {
                models.dbg("\n[error] {t}\n", .{err});
            }
            return 1;
        };
        defer result.ctx.destroy();
        cache_stats.session.record(chat.last_usage);

        if (result.ctx.parts.items.len == 0) {
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
            return 0; // final answer
        }

        // Runs the tools (headless = yolo) and feeds the results back.
        const tc_json = try result.ctx.toolCallsJson(arena);
        try msgs.append(arena, .{ .role = "assistant", .content = "", .tool_calls_json = tc_json });
        for (result.ctx.parts.items) |*p| {
            models.dbg("\n[tool {s}] {s}\n", .{ p.name.items, p.args.items });
            const res = execHeadless(io, &bg, &pending_images, p.name.items, p.args.items, arena) catch |err| {
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
        }
    }
    models.dbg("\n[iteration limit]\n", .{});
    return 0;
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
fn headlessSystemPrompt(a: std.mem.Allocator, env: ?*const std.process.Environ.Map) []u8 {
    // BORROWED, like everywhere else: `discoverSkills` owns the list, and the headless
    // runner has no teardown of its own to free it in.
    const entries = agent.discoverSkills(a, env);
    var list_buf: [8 * 1024]u8 = undefined;
    const section = skills.systemPromptSection(entries, &list_buf);

    var loc_buf: [512]u8 = undefined;
    const location = agent.projectInfoPromptLines(&loc_buf);

    var sp_buf: [16 * 1024]u8 = undefined;
    const sp = std.fmt.bufPrint(
        &sp_buf,
        "{s}\n{s}\n{s}{s}",
        .{ agent.default_system_prompt, ask.guidance, section, location },
    ) catch return a.dupe(u8, agent.default_system_prompt) catch "";
    return a.dupe(u8, sp) catch a.dupe(u8, agent.default_system_prompt) catch "";
}

/// `tools_mod.execute` plus the background registry.
///
/// A thin wrapper and not a change to the signature of `execute`: the registry
/// lives in the `Model` in the TUI, and a headless run has none, so it is passed
/// as a parameter that only the caller knows about.
fn execHeadless(
    io: std.Io,
    bg: *bgproc.Registry,
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
    return tools_mod.execute(io, name, args, arena, bg, null);
}

/// TUI mode: zode (no args)
fn runTui(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    // 64 KiB instead of 1 MB (5.4 of the ROADMAP): the TTY buffer is PERMANENT
    // memory (it lives for the whole process) and 1 MB is paid for 99% of the
    // time without being written. With a token stream chunk by chunk it is plenty.
    const tty_buffer = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(tty_buffer);

    var app = try vxfw.App.init(io, gpa, init.environ_map, tty_buffer);
    defer app.deinit();

    var model = tui.Model.init(gpa);
    defer model.deinit();
    model.environ = init.environ_map;
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
    // Before `bootstrapSession` and before anything composes a prompt: the AGENTS.md
    // and the skills roots are both derived from it.
    agent.initProjectInfo(io, init.environ_map);
    free_auto.attachIo(io);
    chat.io_global = io;
    chat.dbgInitEnv(init.environ_map);
    agent.resume_on_start = std.mem.eql(u8, envGet(init.environ_map, "ZODE_RESUME") orelse "", "1");
    defer agent.shutdownUserConfig();
    defer agent.shutdownBuffers(); // the 1 MiB body buffer (see `bodyBuf`)
    agent.loadUserConfig();
    agent.bootstrapSession(&model);

    // Welcome header: just the wordmark, in the `.banner` Kind (brand blue)
    // instead of `.info` (grey).
    model.pushHeader(.idle);

    // [roster] Free-auto: if the environment asks for it, the pool of free models
    // is built in a worker (it does not block startup) and the status bar shows
    // it as soon as it is there. It runs AFTER `loadUserConfig`, because without
    // the user's config the pool would not see their providers.
    agent.initFreeAutoFromEnv(&model);
    agent.initCheapRouterFromEnv(model.environ);

    try app.run(model.widget(), .{});

    // Workers are spawned with `detach`: nobody joins them. They must be waited for
    // before the `defer`s run (they destroy the model, the app and the `Io`), or
    // a worker still inside `io.async` uses freed memory and the app dies with a
    // segfault on exit.
    model.waitWorkers(2000);
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
        if (std.mem.eql(u8, arg0, "--help")) {
            std.debug.print(
                "zode — code agent harness\n\n" ++
                    "  (no args)    Claude Code style TUI\n" ++
                    "  --models     list the models of the provider\n" ++
                    "  --chat TXT   send a message (streaming)\n" ++
                    "  --resume     resume the last session\n" ++
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
