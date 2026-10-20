/// Renders a SCRIPTED scene of the TUI and prints it as ANSI-colored text.
///
/// Why this exists
/// ---------------
/// A design rewrite without a way to LOOK at the result is a rewrite done
/// blind, and the two checks that exist do not cover it:
///
///   - `tui.drawTest` reads the Surface and compares strings, which proves a
///     row contains a word and says nothing about whether the frame is
///     composed, whether two rows collide, or whether a border has a shadow.
///   - `tools/pty_smoke.py` drives the real binary in a real pty, which sees
///     the truth about vaxis, but it is timing-dependent, it needs a key, and
///     it can only look at ONE moment of a turn.
///
/// This is the third thing: deterministic, no TTY, no network, no key, and it
/// renders the REAL `drawFn` on the REAL `Model` with real content. It is what
/// a design decision gets judged against, and it is the same content the tests
/// assert on, so a change that looks wrong here is wrong in the test too.
///
/// It lives in `src/` and not `src/bin/` for the reason `check_probe.zig` and
/// `roster_probe.zig` do: a module rooted in `src/bin/` cannot import files
/// above it, and this needs `tui.zig`.
///
/// Usage: `zig build ui-frame -- [scene] [width] [height]`
/// Scenes: welcome · turn · tools · bash · diff · ask · perm · palette ·
///         plan · long · all
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui = @import("tui.zig");
const sleepz = @import("lib/sleep.zig");
const plan_mod = @import("lib/plan.zig");
const palette = @import("palette.zig");

const Scene = struct {
    name: []const u8,
    fill: *const fn (m: *tui.Model) void,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    var scene_name: []const u8 = "all";
    var w: u16 = 100;
    var h: u16 = 34;
    var positional: usize = 0;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--flat")) {
            flat = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--layout")) {
            layout_dump = true;
            continue;
        }
        switch (positional) {
            0 => scene_name = a,
            1 => w = std.fmt.parseInt(u16, a, 10) catch w,
            2 => h = std.fmt.parseInt(u16, a, 10) catch h,
            else => {},
        }
        positional += 1;
    }

    var out_buf: [1 << 16]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &out_buf);
    const wtr = &fw.interface;

    const scenes = [_]Scene{
        .{ .name = "welcome", .fill = sceneWelcome },
        .{ .name = "turn", .fill = sceneTurn },
        .{ .name = "tools", .fill = sceneTools },
        .{ .name = "running", .fill = sceneRunning },
        .{ .name = "bash", .fill = sceneBash },
        .{ .name = "diff", .fill = sceneDiff },
        .{ .name = "ask", .fill = sceneAsk },
        .{ .name = "perm", .fill = scenePerm },
        .{ .name = "palette", .fill = scenePalette },
        .{ .name = "plan", .fill = scenePlan },
        .{ .name = "long", .fill = sceneLong },
    };

    const all = std.mem.eql(u8, scene_name, "all");
    var ran: usize = 0;
    for (scenes) |sc| {
        if (!all and !std.mem.eql(u8, scene_name, sc.name)) continue;
        ran += 1;
        try render(wtr, gpa, io, sc, w, h);
    }
    if (ran == 0) {
        try wtr.print("no scene named '{s}'. Try: ", .{scene_name});
        for (scenes) |sc| try wtr.print("{s} ", .{sc.name});
        try wtr.print("all\n", .{});
        try wtr.flush();
        return;
    }
    try wtr.flush();
}

// ── the printer ────────────────────────────────────────────────

fn render(wtr: *std.Io.Writer, gpa: std.mem.Allocator, io: std.Io, sc: Scene, width: u16, height: u16) !void {
    var m = tui.Model.init(gpa);
    defer m.deinit();
    // `attachIo` first: without it `io_ready` is false and every elapsed clock
    // on screen reads 0. The `running` scene exists precisely to see that
    // number move, and a scene that rendered it as 0.0s proved nothing about
    // whether the clock advances.
    m.attachIo(io);
    // The model name the footer shows. Without it the footer's right half is
    // EMPTY, and a scene that renders the design without the half that carries
    // the session's numbers is a scene of a different design.
    tui.setStatusModel(&m, "kimi-k2.6");
    sc.fill(&m);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = try tui.drawTest(&m, arena, width, height);

    if (layout_dump) try dumpLayout(wtr, &m);

    try wtr.print("\x1b[1m┌─ scene: {s}  ({d}×{d})", .{ sc.name, width, height });
    var pad: usize = sc.name.len + 10;
    while (pad < @as(usize, width)) : (pad += 1) try wtr.writeAll("─");
    try wtr.print("┐\x1b[0m\n", .{});

    var row: u16 = 0;
    while (row < height) : (row += 1) {
        try wtr.print("\x1b[1m│\x1b[0m", .{});
        var col: u16 = 0;
        var last: vaxis.Style = .{};
        var painted = false;
        while (col < width) {
            const cell = s.readCell(col, row);
            const g = cell.char.grapheme;
            const w = cell.char.width;
            if (g.len == 0) {
                col += 1;
                continue;
            }
            if (!painted or !std.meta.eql(last, cell.style)) {
                try wtr.writeAll(sgr(cell.style));
                last = cell.style;
                painted = true;
            }
            try wtr.writeAll(g);
            col += @max(1, w);
        }
        try wtr.writeAll("\x1b[0m\x1b[1m│\x1b[0m\n");
    }
    try wtr.print("\x1b[1m└", .{});
    var pad2: usize = sc.name.len + 10;
    while (pad2 < @as(usize, width)) : (pad2 += 1) try wtr.writeAll("─");
    try wtr.print("┘\x1b[0m\n\n", .{});
}

/// The SGR sequence for a style, with truecolor when the terminal has it.
///
/// `--flat` drops every escape and prints the plain text instead: the scenes
/// are then diffable and greppable, which is what a test or a code review
/// wants.
///
/// The `.default` cases are NOT decoration. `Color` is a union, so reading
/// `.rgb` off a `.default` is a jump into a payload that is not there — the
/// first version of this printed `38;2;0;0;0` for every unstyled cell, which
/// paints BLACK on a black terminal: a frame that looked like it was mostly
/// empty.
fn sgr(st: vaxis.Style) []const u8 {
    if (flat) return "";
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    const add = struct {
        fn f(b: []u8, at: usize, comptime fmt: []const u8, args: anytype) usize {
            return at + (std.fmt.bufPrint(b[at..], fmt, args) catch return at).len;
        }
    }.f;
    n = add(&buf, n, "\x1b[0", .{});
    if (st.bold) n = add(&buf, n, ";1", .{});
    if (st.italic) n = add(&buf, n, ";3", .{});
    if (st.ul_style != .off) n = add(&buf, n, ";4", .{});
    if (st.dim) n = add(&buf, n, ";2", .{});
    switch (st.fg) {
        .default => {},
        .rgb => |c| n = add(&buf, n, ";38;2;{d};{d};{d}", .{ c[0], c[1], c[2] }),
        else => |i| n = add(&buf, n, ";38;5;{d}", .{i.index}),
    }
    switch (st.bg) {
        .default => {},
        .rgb => |c| n = add(&buf, n, ";48;2;{d};{d};{d}", .{ c[0], c[1], c[2] }),
        else => |i| n = add(&buf, n, ";48;5;{d}", .{i.index}),
    }
    n = add(&buf, n, "m", .{});
    return buf[0..n];
}

var flat: bool = false;
var layout_dump: bool = false;

/// Prints the layout numbers the frame was painted with.
///
/// A rendering bug is almost never a bug in the painting: it is a disagreement
/// between what the layout decided and what the painter believes, and neither
/// of them is visible from the pixels. This is how the disagreement is seen.
fn dumpLayout(wtr: *std.Io.Writer, m: *tui.Model) !void {
    try wtr.print(
        "\x1b[2m  layout: hist_rows={d} first={d} last={d} max_offset={d} cache_lo={d} live_h={d} paras={d} cache={d}\n",
        .{
            m.hist_rows, m.first_visible, m.max_offset, m.max_offset,
            m.cache_lo,  m.live_h,       m.paras.items.len, m.seg_cache.items.len,
        },
    );
    for (m.seg_cache.items, 0..) |c, i| {
        // `cells` can be EMPTY: a separator row is a `PLine` with no cells.
        const head: []const u8 = if (c.lines.len > 0 and c.lines[0].cells.len > 0)
            c.lines[0].cells[0].text
        else
            "";
        try wtr.print(
            "\x1b[2m    cache[{d}] para={d} h={d} first={s}\x1b[0m\n",
            .{ i, c.para_idx, c.height, head },
        );
    }
    try wtr.print("\x1b[2m  paras:\x1b[0m", .{});
    for (m.paras.items, 0..) |p, i| {
        const t = if (p.text.len > 26) p.text[0..26] else p.text;
        try wtr.print("\x1b[2m {d}:{s}({d}) {s}\x1b[0m", .{ i, @tagName(p.kind), p.known_lines, t });
    }
    try wtr.print("\n", .{});
}

// ── scenes ─────────────────────────────────────────────────────
//
// They use the SAME public API the agent uses (`pushToolStart`,
// `pushToolDone`, `streamStart`, `requestAsk`…), not the internals. A scene
// that reached into `paras` directly would render a frame the app can never
// produce, and it would keep rendering fine after the real path broke.

fn sceneWelcome(m: *tui.Model) void {
    m.pushHeader(.idle);
}

fn sceneTurn(m: *tui.Model) void {
    m.pushHeader(.idle);
    m.pushKind(.user, "reescribe el theme y dime qué contrasta mal");
    m.pushToolStart("Read", "src/lib/theme.zig");
    m.toolRunEnd();
    m.pushToolDone("Read", "Read 60 lines", 3, "src/lib/theme.zig\n  60 lines\n");
    m.streamStart();
    m.streamDelta("El problema real: `brand_faint` esta en 1.9:1 y lo usas ");
    m.streamDelta("para texto, no solo para hairlines.\n\n");
    m.streamDelta("- Cambia la rampa por una de cuatro niveles.\n");
    m.streamDelta("- Cada color lleva su test de contraste.\n");
    m.streamDelta("\nEs el unico cambio que hace falta:\n\n");
    m.streamDelta("```zig\npub const ink = fg(0xf2f2f2); // 18:1\npub const line = fg(0x2e2e2e); // 1.6:1\n```\n");
    m.streamEnd();
}

fn sceneRunning(m: *tui.Model) void {
    // A tool that is STILL RUNNING: no `toolRunEnd`, no `streamEnd`, so the draw
    // takes the live-paragraph branch and the strip's clock path. This is the
    // state the user was reporting as indistinguishable from a freeze.
    m.pushHeader(.idle);
    m.pushKind(.user, "corre los tests");
    m.pushToolStart("Bash", "zig build test --summary all && ls -la src/lib");
    // Hold it open long enough for the clock to read something. `sleepMs` is
    // the bare `nanosleep`: going through the shared `Io` from here would take
    // its event loop with it, and a design harness that hangs is worse than no
    // design harness.
    sleepz.nap(1200);
}

fn sceneTools(m: *tui.Model) void {
    m.pushHeader(.idle);
    m.pushKind(.user, "lee los tres ficheros y mira los tests");
    m.pushToolStart("Grep", "brand_faint");
    m.toolRunEnd();
    m.pushToolDone("Grep", "Grep  14 matches", 9, "x");
    m.pushToolStart("Read", "src/tui.zig");
    m.toolRunEnd();
    m.pushToolDone("Read", "Read 10407 lines", 12, "x");
    m.pushError("grep: brand_faint: matched 14 lines in 3 files");
}

fn sceneBash(m: *tui.Model) void {
    m.pushHeader(.idle);
    m.pushKind(.user, "corre los tests");
    m.pushToolStart("Bash", "zig build test --summary all");
    m.toolRunEnd();
    m.pushToolDone(
        "Bash",
        "Bash",
        12400,
        "Compiling 62 files...\n" ++
            "build.zig:1:19: warning: unused variable\n" ++
            "run test 854 pass, 1 skip, 4 fail (859 total)\n",
    );
}

fn sceneDiff(m: *tui.Model) void {
    m.pushHeader(.idle);
    m.pushKind(.user, "arregla el contraste");
    const before =
        \\pub const brand_faint: Style = .{ .fg = .{ .rgb = .{ 0x3b, 0x42, 0x61 } } };
        \\pub const rule: Style = brand_faint;
        \\pub const hint: Style = .{ .fg = .{ .index = 8 } };
        \\
    ;
    const after =
        \\pub const ink: Style = .{ .fg = .{ .rgb = .{ 0xf2, 0xf2, 0xf2 } } };
        \\pub const ink_line: Style = .{ .fg = .{ .rgb = .{ 0x2e, 0x2e, 0x2e } } };
        \\pub const hint: Style = .{ .fg = .{ .rgb = .{ 0x7a, 0x7a, 0x7a } } };
        \\pub const contrastOk: bool = contrast(ink, ink_line) >= 4.5;
        \\
    ;
    m.pushToolStart("Edit", "src/lib/theme.zig");
    m.toolRunEnd();
    _ = m.pushDiffLang(before, after, "zig");
    m.pushToolDone("Edit", "Edit  src/lib/theme.zig", 7, "x");
    m.pushInfoFmt("{d} tool results elided", .{3});
}

fn sceneAsk(m: *tui.Model) void {
    m.pushHeader(.idle);
    m.pushKind(.user, "instala las dependencias");
    m.streamStart();
    m.streamDelta("Necesito tu decision antes de seguir.\n");
    m.streamEnd();
    // Set ask state directly (like scenePerm) to avoid blocking on waitAskAnswer
    // Inline freeAskStringsLocked:
    if (m.ask_question) |q| m.allocator.free(q);
    if (m.ask_header) |h| m.allocator.free(h);
    for (m.ask_options.items) |o| m.allocator.free(o);
    m.ask_options.clearRetainingCapacity();
    m.ask_question = null;
    m.ask_header = null;
    const q = "Arranco los tests con tu API key, o un build que no la necesita?";
    const h = "zode necesita tu decision";
    m.ask_question = m.allocator.dupe(u8, q) catch null;
    m.ask_header = m.allocator.dupe(u8, h) catch null;
    const opts = [_][]const u8{
        "Arrancar los tests con la key del entorno",
        "Solo el build, sin key",
        "Los dos en paralelo",
        "escribir mi propia respuesta",
    };
    for (opts) |o| {
        m.ask_options.append(m.allocator, m.allocator.dupe(u8, o) catch "") catch {};
    }
    m.ask_answer = null;
    m.ask_typing = false;
    m.ask_active = true;
    m.ask_started_ns = 0;
    m.ask_sel = 0;
    m.requestRedraw();
    m.dirty = true;
}

fn scenePerm(m: *tui.Model) void {
    m.pushHeader(.idle);
    m.pushKind(.user, "instala las dependencias");
    m.pushToolStart("Bash", "npm install");
    // In the app the dialog is answered from a second thread; here the same
    // state is set directly, which is exactly what `permView` reads.
    @memcpy(m.perm_tool[0..4], "Bash");
    m.perm_tool_len = 4;
    const detail = "npm install --no-audit --no-fund";
    @memcpy(m.perm_detail[0..detail.len], detail);
    m.perm_detail_len = detail.len;
    m.perm_answer = .none;
}

fn scenePalette(m: *tui.Model) void {
    m.pushHeader(.idle);
    m.pushKind(.user, "/mo");
    m.openPaletteWith(.commands, paletteItems(), paletteGroups());
}

fn scenePlan(m: *tui.Model) void {
    m.pushHeader(.idle);
    m.pushKind(.user, "reescribe el tema");
    m.pushInfo("Voy a tocar el theme y los tests de contraste.");
    var items = [_]plan_mod.Item{.{}} ** 3;
    planItem(&items[0], "New ramp of 4 levels in theme.zig", .pending);
    planItem(&items[1], "Re-theme the syntax colors", .in_progress);
    planItem(&items[2], "Contrast test for every pair", .done);
    _ = m.applyPlan(&items, 3);
}

/// `plan_mod.Item.text` is a FIXED BUFFER, not a slice: assigning a string
/// literal to it is a compile error, which is exactly the guard this repo
/// wanted when the plan was written.
fn planItem(dst: *plan_mod.Item, text: []const u8, status: plan_mod.Status) void {
    @memset(&dst.text, undefined);
    const n = @min(text.len, dst.text.len);
    @memcpy(dst.text[0..n], text[0..n]);
    dst.len = @intCast(n);
    dst.status = status;
}

fn sceneLong(m: *tui.Model) void {
    m.pushHeader(.idle);
    m.pushKind(.user, "dame un resumen del repo");
    m.pushToolStart("Task", "how is the tool split?");
    m.toolRunEnd();
    m.pushToolDone(
        "Task",
        "Task  a code agent in 3 sentences",
        8200,
        "src/tools/ holds one file per tool.",
    );
    m.streamStart();
    m.streamDelta("Los ficheros de `src/tools/` son uno por herramienta.\n\n");
    m.streamDelta("- `dispatch.zig` es el unico que las conoce todas\n");
    m.streamDelta("- `common.zig` tiene lo compartido (`getStr`, `getInt`)\n");
    m.streamDelta("- `bash.zig` es la que tiene la parte que bloquea\n\n");
    m.streamDelta("### Lo que no se divide\n\n");
    m.streamDelta("`agent.zig` es un hub de estado compartido: moverlo exige\n");
    m.streamDelta("reducir el estado primero.\n\n");
    m.streamDelta("> La regla es: un modulo no importa hacia arriba.\n\n");
    m.streamDelta("| modulo | lineas | notas |\n");
    m.streamDelta("|---|---|---|\n");
    m.streamDelta("| `tui.zig` | 10407 | estado + dibujo |\n");
    m.streamDelta("| `agent.zig` | 11868 | el bucle |\n");
    m.streamEnd();
}

fn paletteItems() []const palette.Item {
    return &.{
        .{ .kind = .command, .group = 1, .label = "help", .hint = "ctrl+p" },
        .{ .kind = .command, .group = 1, .label = "context" },
        .{ .kind = .command, .group = 1, .label = "cache" },
        .{ .kind = .command, .group = 1, .label = "bench" },
        .{ .kind = .command, .group = 2, .label = "model", .hint = "ctrl+t" },
        .{ .kind = .command, .group = 2, .label = "provider" },
        .{ .kind = .command, .group = 2, .label = "effort" },
        .{ .kind = .command, .group = 3, .label = "clean" },
        .{ .kind = .command, .group = 3, .label = "resume" },
    };
}

fn paletteGroups() []const palette.Group {
    return &.{
        .{ .name = "Suggested" },
        .{ .name = "Model" },
        .{ .name = "Session" },
    };
}
