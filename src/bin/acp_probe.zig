const std = @import("std");
const acp = @import("acp");

pub fn main(init: std.process.Init) !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cwd = blk: {
        var buf: [4096]u8 = undefined;
        const n = std.Io.Dir.cwd().readLink(io, "/proc/self/cwd", &buf) catch 0;
        break :blk if (n > 0) buf[0..n] else "/";
    };
    std.debug.print("cwd = {s}\n", .{cwd});

    // `ZODE_ACP_CMD` points the probe at another agent (or at the fake one the
    // tests use) without recompiling: "opencode acp", "my-agent --stdio"...
    var argv_words: [8][]const u8 = undefined;
    var argv: ?[]const []const u8 = null;
    if (init.environ_map.get("ZODE_ACP_CMD")) |cmd| {
        var it = std.mem.tokenizeAny(u8, cmd, " ");
        var n: usize = 0;
        while (it.next()) |w| {
            if (n >= argv_words.len) break;
            argv_words[n] = w;
            n += 1;
        }
        argv = argv_words[0..n];
    }

    std.debug.print("lanzando {s}...\n", .{if (argv) |a| a[0] else "opencode acp"});
    const c = acp.Client.start(gpa, io, argv, cwd, init.environ_map) catch |err| {
        std.debug.print("NO SE PUDO LANZAR: {t}\n", .{err});
        return err;
    };
    defer c.deinit();
    std.debug.print("agente = {s} · sesion = {s}\n", .{ c.agentTitle(), c.sessionId() });

    const Ctx = struct {
        fn onText(_: ?*anyopaque, s: []const u8) void {
            std.debug.print("[texto] {s}", .{s});
        }
        fn onThought(_: ?*anyopaque, s: []const u8) void {
            std.debug.print("[razon] {s}\n", .{s});
        }
        fn onTool(_: ?*anyopaque, id: []const u8, name: []const u8, title: []const u8) void {
            std.debug.print("[tool {s}] {s} — {s}\n", .{ id, name, title });
        }
        fn onUpd(_: ?*anyopaque, id: []const u8, status: []const u8, text: []const u8) void {
            std.debug.print("[tool {s} {s}] {s}\n", .{ id, status, text });
        }
        fn onPlan(_: ?*anyopaque, s: []const u8) void {
            std.debug.print("[plan] {s}\n", .{s});
        }
    };
    const sink = acp.Sink{
        .onText = Ctx.onText,
        .onThought = Ctx.onThought,
        .onTool = Ctx.onTool,
        .onToolUpdate = Ctx.onUpd,
        .onPlan = Ctx.onPlan,
        .onPermission = struct {
            fn ask(_: ?*anyopaque, tool: []const u8, detail: []const u8, opts: []const acp.PermOption) ?[]const u8 {
                std.debug.print("[PERMISO] {s} {s}\n", .{ tool, detail });
                for (opts) |o| std.debug.print("   - {s} ({s})\n", .{ o.name, o.kind });
                // The first allow option is granted, the way /yolo does.
                for (opts) |o| {
                    if (std.mem.startsWith(u8, o.kind, "allow")) return o.id;
                }
                return null;
            }
        }.ask,
    };

    // `main` receives `std.process.Init` in 0.16 (see AGENTS.md): the args
    // come through `init.minimal.args`; `std.process.argsAlloc` is gone.
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next(); // the program name
    const question = it.next() orelse "di hola en una frase";
    std.debug.print("prompt: {s}\n\n", .{question});

    try c.prompt(question);
    // `CANCEL=1` asks for the cut at 2 s from ANOTHER thread, which is exactly
    // what the TUI does with ESC: the UI sets the flag and the worker (which
    // owns the `Io`) is the one that writes the `session/cancel`.
    if (init.environ_map.get("CANCEL") != null) {
        const T = struct {
            fn go(cc: *acp.Client) void {
                // `std.Thread.sleep` is gone in 0.16: wait with the `Io`.
                var th = std.Io.Threaded.init(std.heap.page_allocator, .{});
                defer th.deinit();
                th.io().sleep(.fromSeconds(2), .awake) catch {};
                std.debug.print("\n[probe] asking to cancel\n", .{});
                cc.cancel();
            }
        };
        const th = try std.Thread.spawn(.{}, T.go, .{c});
        defer th.join();
    }
    const reason = c.waitTurn(&sink) catch |err| {
        std.debug.print("\nERROR: {t} · agent message: \u{00ab}{s}\u{00bb}\n", .{ err, c.lastError() });
        // WITHOUT `defer c.deinit()`: we want the `wait` to learn how the child died
        // en vez de matarlo nosotros y no enterarnos.
        const term = c.child.wait(io) catch |we| {
            std.debug.print("wait err: {t}\n", .{we});
            return;
        };
        std.debug.print("el hijo terminó como: {any}\n", .{term});
        return;
    };
    std.debug.print("\n=== fin del turno: {s} ===\n", .{reason});
}
