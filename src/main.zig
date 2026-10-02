const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const tui = @import("tui.zig");
const http_client = @import("http_client.zig");
const models = @import("models.zig");
const models_mod = models;
const provider = @import("provider.zig");
const providers = @import("providers.zig");
const tools_mod = @import("tools.zig");
const cache_stats = @import("cache_stats.zig");
const chat = @import("chat.zig");
const agent = @import("agent.zig");
const free_auto = @import("free_auto.zig");
const compaction_mod = @import("compaction.zig");
const mascot = @import("mascot.zig");
const bgproc = @import("bgproc.zig");
const skills = @import("skills.zig");
const ask = @import("ask.zig");

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
    // The `arena`, not the `gpa`: this text lives as long as the conversation
    // does, and the arena dies at the end of the run. With `gpa` it was a leak
    // per process (the DebugAllocator says so on exit, which is how it showed up).
    try msgs.append(arena, .{ .role = "system", .content = headlessSystemPrompt(arena, env) });
    // `@file` mentions work in headless too: the TUI expands them in
    // `runOneTurn` (`withMentions`), but this runner sent the raw text, so
    // `zode --chat "explain @src/foo.zig"` made the model answer "I don't have
    // the file". Expanded HERE, on the session's own text, because the headless
    // runner has no per-iteration arena like `runOneTurn` has.
    const mentions_mod = @import("mentions.zig");
    const expanded = mentions_mod.expand(arena, io, text) catch
        mentions_mod.Expansion{ .text = text, .files = 0, .missing = 0 };
    try msgs.append(arena, .{ .role = "user", .content = expanded.text });

    // The headless runner gets a background registry too, so `run_in_background`
    // works there instead of erroring out. The registry is freed on exit, which
    // also kills anything still running: a `zode --chat` that exits with an
    // orphaned build writing to a closed pipe is worse than waiting.
    var bg = bgproc.Registry{};
    defer bg.deinit(io, gpa);

    const model_name = envGet(env, "ZODE_MODEL") orelse def.default_model;

    // El effort sale del MODELO, no de un `.medium` fijo: si `ZODE_EFFORT` no
    // esta, se pide el default de la escalera que tenga ese modelo. Y lo que
    // llega de la variable se ajusta a esa escalera, para que
    // `ZODE_EFFORT=xhigh` contra un `gemini-2.5` no mande un nivel que no
    // existe.
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
            const comp = compaction_mod.elideTier(arena, msgs.items, compaction_mod.budgetTokens(env)) catch
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
        const body = chat.buildBodyMessages(body_buf, model_name, msgs.items, effort_pref, tools_mod.toolsJson(), kind) catch return error.BodyTooBig;

        const Cb = struct {
            fn onDelta(_: ?*anyopaque, delta: []const u8) void {
                models.dbg("{s}", .{delta});
            }
        };

        const result = chat.streamChatCtx(gpa, &http, url, key, @constCast(body), .{
            .userdata = null,
            .onDelta = Cb.onDelta,
        }, kind) catch |err| {
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
            if (elided_total > 0) models.dbg(" · {d} tool results elided", .{elided_total});
            models.dbg("\n", .{});
            return 0; // final answer
        }

        // Runs the tools (headless = yolo) and feeds the results back.
        const tc_json = try result.ctx.toolCallsJson(arena);
        try msgs.append(arena, .{ .role = "assistant", .content = "", .tool_calls_json = tc_json });
        for (result.ctx.parts.items) |*p| {
            models.dbg("\n[tool {s}] {s}\n", .{ p.name.items, p.args.items });
            const res = execHeadless(io, &bg, p.name.items, p.args.items, arena) catch |err| {
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
    name: []const u8,
    args: []const u8,
    arena: std.mem.Allocator,
) ![]const u8 {
    return tools_mod.execute(io, name, args, arena, bg);
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

    // [roster] Free-auto: si el entorno lo pide, el pool de modelos free se
    // construye en un worker (no bloquea el arranque) y el status bar lo enseña
    // en cuanto esté. Va DESPUÉS de `loadUserConfig`, porque sin la config del
    // usuario el pool no vería sus providers.
    agent.initFreeAutoFromEnv(&model);

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
                "zode — harness de código\n\n" ++
                    "  (sin args)   TUI estilo Claude Code\n" ++
                    "  --models     lista los modelos del provider\n" ++
                    "  --chat TXT   envía un mensaje (streaming)\n" ++
                    "  --resume     reanuda la última sesión\n" ++
                    "  --help       esta ayuda\n",
                .{},
            );
            return 0;
        }
        std.debug.print("flag desconocida: {s}\n", .{arg0});
        return 1;
    }

    return runTui(init);
}
