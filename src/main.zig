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
const compaction_mod = @import("compaction.zig");
const mascot = @import("mascot.zig");

fn envGet(map: ?*const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const m = map orelse return null;
    return m.get(key);
}

/// Modo headless: zode --models
fn runModels(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map) !u8 {
    models.dbg_io = io; // para diagnósticos
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

/// Modo headless: zode --chat "texto"
/// Headless agent: como la TUI pero sin UI (yolo ON, imprime a stderr).
fn runChat(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, text: []const u8) !u8 {
    var http = http_client.Http.init(gpa, io);
    defer http.deinit();

    agent.io_global = io;
    agent.gpa_global = gpa;
    agent.environ_global = env;
    agent.api_key_global = envGet(env, "ZODE_API_KEY");
    chat.io_global = io;
    models.dbg_io = io;
    defer agent.shutdownUserConfig();
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
    try msgs.append(arena, .{ .role = "system", .content = agent.default_system_prompt });
    try msgs.append(arena, .{ .role = "user", .content = text });

    const effort: chat.Effort = if (envGet(env, "ZODE_EFFORT")) |e| (chat.Effort.parse(e) orelse .medium) else .medium;
    const model_name = envGet(env, "ZODE_MODEL") orelse def.default_model;

    const body_buf = try gpa.alloc(u8, 256 * 1024);
    defer gpa.free(body_buf);

    models.dbg_io = io;

    var iteration: usize = 0;
    var elided_total: usize = 0;
    while (iteration < 6) : (iteration += 1) {
        // Contexto bajo budget: elide tool dumps viejos (vista del wire).
        {
            const comp = compaction_mod.elideTier(arena, msgs.items, compaction_mod.budgetTokens(env)) catch
                compaction_mod.Compacted{ .msgs = msgs.items };
            if (comp.elided > 0) elided_total += comp.elided;
            var cur: []chat.ChatMessage = try arena.dupe(chat.ChatMessage, comp.msgs);

            // Tier 2: resumir el tramo viejo con LLM si la elision no alcanzó.
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
                        effort,
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
        const body = chat.buildBodyMessages(body_buf, model_name, msgs.items, effort, tools_mod.toolsJson(), kind) catch return error.BodyTooBig;

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
            return 0; // respuesta final
        }

        // Ejecuta tools (headless = yolo) y alimenta los resultados.
        const tc_json = try result.ctx.toolCallsJson(arena);
        try msgs.append(arena, .{ .role = "assistant", .content = "", .tool_calls_json = tc_json });
        for (result.ctx.parts.items) |*p| {
            models.dbg("\n[tool {s}] {s}\n", .{ p.name.items, p.args.items });
            const res = tools_mod.execute(io, p.name.items, p.args.items, arena) catch |err| {
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

/// Modo TUI: zode (sin args)
fn runTui(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    // 64 KiB en vez de 1 MB (5.4 del ROADMAP): el buffer de la TTY es memoria
    // PERMANENTE (vive todo el proceso) y 1 MB se paga el 99% del tiempo sin
    // escribirse. Con un stream de tokens por chunk llega de sobra.
    const tty_buffer = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(tty_buffer);

    var app = try vxfw.App.init(io, gpa, init.environ_map, tty_buffer);
    defer app.deinit();

    var model = tui.Model.init(gpa);
    defer model.deinit();
    model.environ = init.environ_map;
    model.attachIo(io); // para el reloj de la franja de actividad
    model.attach();

    agent.io_global = io;
    // Sin esto los diagnósticos de `models.dbg` (status + body del servidor)
    // no salen en la TUI: solo se ve un "models: HTTP error at <url>" sin más,
    // que no dice si fue un 401, un 403 o un 404.
    models_mod.dbg_io = io;
    agent.api_key_global = envGet(init.environ_map, "ZODE_API_KEY");
    agent.environ_global = init.environ_map;
    agent.gpa_global = init.gpa;
    chat.io_global = io;
    agent.resume_on_start = std.mem.eql(u8, envGet(init.environ_map, "ZODE_RESUME") orelse "", "1");
    defer agent.shutdownUserConfig();
    agent.loadUserConfig();
    agent.bootstrapSession(&model);

    // Cabecera de bienvenida: arte del búho, línea de Zo y pistas. Va en el
    // Kind `.banner` (azul de marca) en vez de `.info` (gris), y la carita de
    // Zo con el color de su mood.
    model.pushHeader(.idle);

    try app.run(model.widget(), .{});

    // Los workers se lanzan con `detach`: nadie los une. Antes de que corran los
    // `defer` (que destruyen el modelo, la app y el `Io`) hay que esperarlos, o
    // un worker que sigue dentro de `io.async` usa memoria liberada y la app
    // peta con un segfault al salir.
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
