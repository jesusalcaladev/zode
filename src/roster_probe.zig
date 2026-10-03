const std = @import("std");

// It LIVES in `src/` and not in `src/bin/` (where the other probes are) for a
// concrete reason: its module path is the root directory, and with the probe in
// `src/bin/` the neighbouring `@import("agent.zig")` falls outside the module
// ("import of file outside module path"). And they cannot be declared as build
// modules because a file cannot be the root of two modules and `providers.zig`
// already is one of `agent`. The probe picks them up by path; the only thing
// build.zig declares is `vaxis`, which really does come from a package.
const agent = @import("agent.zig");
const free_auto = @import("free_auto.zig");
const providers = @import("lib/providers.zig");
const roster = @import("roster.zig");
const models = @import("lib/models.zig");
const http_client = @import("lib/http_client.zig");

/// The free-auto probe: which providers hold a key, which free models they
/// publish, and how the pool looks with the order the wheel is going to use.
///
/// It is not a test (it talks to the network) but it is the way to answer the
/// question that matters: "do I actually have a plan B?". With a single opencode
/// key the answer is no, and that has to be seen, not assumed.
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

    // 1) providers: key, catalog, and how many free ones.
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

    // 2) the pool, already with the order the wheel is going to use.
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
        // And what the user has to do if they only have opencode: the pool would
        // fill up with models that answer 403 from here.
        var gated: usize = 0;
        for (r.items[0..r.len]) |c| {
            if (c.gated_opencode) gated += 1;
        }
        if (gated == r.len) {
            try out.print("\n  CAREFUL: all of them are opencode. Its -free models answer 403\n", .{});
            try out.print("  outside the official client, so free-auto has no plan B here.\n", .{});
            try out.print("  Add a key for openrouter or groq (ctrl+a) and it will.\n", .{});
        }
    }

    var fbuf: [64 * 1024]u8 = undefined;
    var f = std.Io.File.stdout().writer(io, &fbuf);
    try f.interface.writeAll(w.buffered());
    try f.interface.flush();
}
