const std = @import("std");

// VIVE EN `src/` y no en `src/bin/` (donde están las otras sondas) por una razón
// concreta: su module path es el directorio de la raíz, y con la sonda en
// `src/bin/` los `@import("agent.zig")` de al lado se salen del módulo
// ("import of file outside module path"). Y no se pueden declarar como módulos
// del build porque un fichero no puede ser raíz de dos módulos y `providers.zig`
// ya lo es de `agent`. La sonda los coge por ruta; lo único que build.zig
// declara es `vaxis`, que sí viene de un paquete.
const agent = @import("agent.zig");
const free_auto = @import("free_auto.zig");
const providers = @import("providers.zig");
const roster = @import("roster.zig");
const models = @import("models.zig");
const http_client = @import("http_client.zig");

/// Sonda del free-auto: qué providers tienen key, qué modelos free publican, y
/// cómo queda el pool con el orden que la rueda va a usar.
///
/// No es un test (habla con la red) pero es la forma de responder a la pregunta
/// que importa: "¿tengo de verdad algún plan B?". Con una sola key de opencode la
/// respuesta es que no, y eso hay que verlo, no suponerlo.
///
///     zig build roster-probe
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    agent.io_global = io;
    agent.gpa_global = gpa;
    agent.environ_global = init.environ_map;
    agent.api_key_global = init.environ_map.get("ZODE_API_KEY");
    free_auto.attachIo(io);
    agent.loadUserConfig();
    defer agent.shutdownUserConfig();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var wbuf: [64 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&wbuf);
    const out = &w;

    const defs = agent.allProviders(arena);

    // 1) providers: key, catálogo y cuántos free.
    try out.print("providers\n", .{});
    var http = http_client.Http.init(arena, io);
    defer http.deinit();
    var with_key: usize = 0;
    for (defs) |*d| {
        const key = providers.keyFor(d, init.environ_map);
        var list = models.listModels(arena, &http, d.models_url, key) catch |err| {
            try out.print("  {s:<12} key={s:<3} LIST FAILED ({t})\n", .{
                d.id,
                if (key != null) "yes" else "no",
                err,
            });
            continue;
        };
        defer list.deinit(arena);
        if (key != null) with_key += 1;
        try out.print("  {s:<12} key={s:<3} models={d: >4} free={d: >3} pricing={s}\n", .{
            d.id,
            if (key != null) "yes" else "no",
            list.items.len,
            list.free_count,
            if (list.has_metadata) "yes" else "no",
        });
    }
    try out.print("\n  {d} provider(s) with a key\n", .{with_key});

    // 2) el pool, ya con el orden que la rueda va a usar.
    var r = roster.Roster.init(arena);
    try r.build(io, init.environ_map, defs);
    try out.print("\npool: {d} candidate(s)\n", .{r.len});
    for (r.items[0..r.len], 0..) |c, i| {
        try out.print("  {d}. {s}/{s}  ctx={d: >7}  gated={s}\n", .{
            i + 1,
            c.provider_id,
            c.model_id,
            c.ctx,
            if (c.gated_opencode) "yes (403 outside the official client)" else "no",
        });
    }
    if (r.isEmpty()) {
        try out.print("  EMPTY: {s}\n", .{r.empty_reason});
    } else {
        try out.print("  first in line: {s}\n", .{r.statusLabel(arena)});
        // Y lo que el usuario tiene que hacer si solo tiene opencode: el pool
        // se llenaría de modelos que dan 403 desde aquí.
        var gated: usize = 0;
        for (r.items[0..r.len]) |c| {
            if (c.gated_opencode) gated += 1;
        }
        if (gated == r.len) {
            try out.print("\n  OJO: all of them are opencode. Its -free models answer 403\n", .{});
            try out.print("  outside the official client, so free-auto has no plan B here.\n", .{});
            try out.print("  Add a key for openrouter or groq (ctrl+a) and it will.\n", .{});
        }
    }

    var fbuf: [64 * 1024]u8 = undefined;
    var f = std.Io.File.stdout().writer(io, &fbuf);
    try f.interface.writeAll(w.buffered());
    try f.interface.flush();
}
