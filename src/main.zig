const std = @import("std");
const builtin = @import("builtin");
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
const spawnenv_mod = @import("lib/spawnenv.zig");
const env_mod = @import("lib/env.zig");
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
const diag_mod = @import("lib/diag.zig");
const hooks_mod = @import("lib/hooks.zig");
const permrules = @import("lib/permrules.zig");
const pathsafe = @import("lib/pathsafe.zig");
const cmdsafety = @import("lib/cmdsafety.zig");
const kittyKeyboardPush = @import("lib/termseq.zig").kittyKeyboardPush;
const kittyKeyboardPop = @import("lib/termseq.zig").kittyKeyboardPop;
const termseq = @import("lib/termseq.zig");
const skills = @import("lib/skills.zig");
const ask = @import("lib/ask.zig");
const lsp_manager = @import("lsp/manager.zig");
const mcp_manager = @import("mcp/manager.zig");
const theme = @import("lib/theme.zig");
const lang_icons = @import("lib/lang_icons.zig");
const keybinds = @import("lib/keybinds.zig");
const acp_server = @import("acp/server.zig");
const headless = @import("headless.zig");
const mission_runner = @import("mission/runner.zig");

var child_env_static: std.process.Environ.Map = undefined;
var child_env_live: bool = false;

// ── crash handling ─────────────────────────────────────────────────────
//
// A panic used to mean: the process died, the terminal was left in the
// alternate screen with the mouse captured and raw/keyboard flags still
// active, and the shell typed garbage on the next keypress. `Cannot print
// stack trace: stack tracing is disabled` was printed on top of that, which
// is the state the user reported and the one screenshots cannot explain.
//
// `std.options.allow_stack_tracing` is what actually toggles the traces in
// Zig: it defaults to `!builtin.strip_debug_info`, and zode ships stripped,
// so the trace was always "disabled" and the release binary could never say
// WHERE it died. Stripping the binary does not stop the unwinder from
// running — it stops the SOURCE mapping — so enabling it costs bytes and
// still reports the frames (as addresses, or as lines when a Debug build is
// what crashed, see `zig build debug`).
//
// The panic handler cannot use `Io`, an allocator or any of this process's
// own bookkeeping: the thing that just crashed is usually what touched that
// state. It talks to the terminal and to a file with raw syscalls, in the
// same shape `agent.quitFast` uses for the clean-exit path, and through the
// same `termseq.restore_all` byte string.

/// Enables stack-trace capture in Release builds. Stripping the binary still
/// prevents symbolization, but the unwinder runs and the frames are printed.
///
/// `enable_segfault_handler` is set EXPLICITLY because its default is
/// `runtime_safety`: a ReleaseFast build (and any build with safety off) had no
/// handler at all, so a bad pointer took the process down without a word.
pub const std_options: std.Options = .{
    .allow_stack_tracing = true,
    .enable_segfault_handler = true,
};

/// Root panic handler: give the terminal back, leave a crash log, then defer
/// to the default handler (which prints the message and aborts).
pub const panic = std.debug.FullPanic(zodePanic);

/// A real SIGSEGV (or SIGILL/SIGBUS/SIGFPE) never reaches `zodePanic`: the
/// signal handler is a separate path. The default one prints to stderr and
/// exits, which leaves the terminal in raw mode over the alternate screen —
/// the shell then echoes every key as garbage, and there is no trace of what
/// died. This override does the same two things the panic path does.
pub const debug = struct {
    pub fn handleSegfault(addr: ?usize, name: []const u8, ctx: ?std.debug.CpuContextPtr) noreturn {
        if (builtin.os.tag == .linux) {
            restoreTerminalForCrash();
            var msg_buf: [256]u8 = undefined;
            const msg = std.mem.print(&msg_buf, "{s} at address 0x{x}", .{ name, addr orelse 0 }) catch name;
            // The faulting instruction is the frame worth keeping. Everything
            // else is printed by the default handler below. `CpuContext` does
            // not spell the register the same way on every architecture; the
            // `getPc` helper is the portable door.
            var pc: ?usize = null;
            if (ctx) |c| {
                if (@hasDecl(@TypeOf(c.*), "getPc")) pc = c.getPc();
            }
            writeSegfaultLog(msg, pc);
        }
        std.debug.defaultHandleSegfault(addr, name, ctx);
    }
};

/// Fixed path on purpose: panic time is not a moment to build directories or
/// consult an environment map.
const crash_log_path = "/tmp/zode-crash.log";

fn zodePanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    if (builtin.os.tag == .linux) {
        restoreTerminalForCrash();
        writeCrashLog(msg, first_trace_addr);
    }
    std.debug.defaultPanic(msg, first_trace_addr);
}

/// Write all of `bytes` to `fd`. Nothing to retry into, nothing to buffer: if
/// the write fails the crash message in the terminal still carries the news.
fn linuxWriteAll(fd: std.posix.fd_t, bytes: []const u8) void {
    if (builtin.os.tag != .linux) return;
    const linux = std.os.linux;
    var off: usize = 0;
    while (off < bytes.len) {
        const n = linux.write(fd, bytes.ptr + off, bytes.len - off);
        switch (linux.errno(n)) {
            .SUCCESS => off += n,
            .INTR => continue,
            else => return,
        }
    }
}

/// The terminal back into its NORMAL state. This is the half of the crash
/// that the user actually sees: without it the shell prompt never returns
/// and every key afterwards is raw input to a dead program.
fn restoreTerminalForCrash() void {
    if (builtin.os.tag != .linux) return;
    const fd = std.posix.openat(std.posix.AT.FDCWD, "/dev/tty", .{ .ACCMODE = .RDWR }, 0) catch return;
    defer _ = std.os.linux.close(fd);
    linuxWriteAll(fd, termseq.restore_all);
    // Escape sequences cannot undo raw mode: termios carries it.
    const termios = std.posix.tcgetattr(fd) catch return;
    var copy = termios;
    copy.lflag.ECHO = true;
    copy.lflag.ICANON = true;
    copy.lflag.ISIG = true;
    copy.oflag.OPOST = true;
    copy.iflag.ICRNL = true;
    copy.iflag.IXON = true;
    _ = std.posix.tcsetattr(fd, .FLUSH, copy) catch {};
}

/// Opens the crash log for appending, or says why not by returning null. Panic
/// time is not a moment to build directories: the path is fixed.
fn openCrashLog() ?std.posix.fd_t {
    if (builtin.os.tag != .linux) return null;
    // NOFOLLOW closes the symlink hole: a predictable path in a world-writable
    // directory must not be a way to append to somebody else's file. Panic
    // time is raw-syscall territory — no allocator, no Io, no fstat wrapper.
    return std.posix.openat(std.posix.AT.FDCWD, crash_log_path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
        .NOFOLLOW = true,
    }, 0o600) catch null;
}

fn writeCrashHeader(fd: std.posix.fd_t, msg: []const u8) void {
    linuxWriteAll(fd, "zode crash\n");
    var line_buf: [128]u8 = undefined;
    if (std.mem.print(&line_buf, "version: {s}\n", .{@import("build_options").version})) |s| {
        linuxWriteAll(fd, s);
    } else |_| {}
    linuxWriteAll(fd, "pid: ");
    if (std.mem.print(&line_buf, "{d}\n", .{std.os.linux.getpid()})) |s| {
        linuxWriteAll(fd, s);
    } else |_| {}
    linuxWriteAll(fd, "message: ");
    linuxWriteAll(fd, msg);
    linuxWriteAll(fd, "\n");
}

fn writeCrashFooter(fd: std.posix.fd_t) void {
    linuxWriteAll(fd, "----------------------------------------\n");
}

/// Leave `/tmp/zode-crash.log` with the failure and the frames it could
/// collect, for whoever picks the machine up afterwards. Appends.
fn writeCrashLog(msg: []const u8, first_trace_addr: ?usize) void {
    const fd = openCrashLog() orelse return;
    defer _ = std.os.linux.close(fd);
    writeCrashHeader(fd, msg);

    var line_buf: [128]u8 = undefined;
    var addrs: [96]usize = undefined;
    const trace = std.debug.captureCurrentStackTrace(.{
        .first_address = first_trace_addr orelse @returnAddress(),
        .allow_unsafe_unwind = true,
    }, &addrs);
    if (trace.return_addresses.len > 0) {
        linuxWriteAll(fd, "frames:\n");
        for (trace.return_addresses) |addr| {
            if (std.mem.print(&line_buf, "0x{x}\n", .{addr})) |s| {
                linuxWriteAll(fd, s);
            } else |_| {}
        }
    } else {
        linuxWriteAll(fd, "frames: (unwinding failed)\n");
    }
    writeCrashFooter(fd);
}

/// The signal handler's log entry. It deliberately does NOT unwind: walking the
/// stack from inside a signal handler is exactly the kind of read that can fault
/// again, and a second SIGSEGV in the handler has nowhere left to go. The
/// faulting program counter is the one frame that matters, and the default
/// handler prints the full trace to the terminal right after this returns.
fn writeSegfaultLog(msg: []const u8, pc: ?usize) void {
    const fd = openCrashLog() orelse return;
    defer _ = std.os.linux.close(fd);
    writeCrashHeader(fd, msg);
    var line_buf: [128]u8 = undefined;
    if (pc) |addr| {
        if (std.mem.print(&line_buf, "pc: 0x{x}\n", .{addr})) |s| {
            linuxWriteAll(fd, s);
        } else |_| {}
    } else {
        linuxWriteAll(fd, "pc: (not reported by this platform)\n");
    }
    linuxWriteAll(fd, "frames: (printed by the default handler; not unwound in a signal)\n");
    writeCrashFooter(fd);
}

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
    http_client.Http.initDefaultTimeout(env);
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
                "{s} publishes no model catalog: pick the model by hand (ZODE_MODEL, or /model in the TUI).\n",
                .{def.id},
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

    // The cache key is the PROVIDER, not the URL: two providers can publish the
    // same catalogue URL and one changing its models must not invalidate the
    // other. Use the provider's REAL id, not whatever the environment says.
    const pid = def.id;
    const cached: ?modelcache.Entry = if (modelcache.read(io, env, arena, pid, url)) |e|
        if (e.models.len > 0) e else null
    else
        null;

    if (cached) |e| {
        if (!headless.ageIsStale(io, e.fetched_at)) {
            try printModelCatalog(io, e.models, "");
            return 0;
        }
    }

    // Stale or missing: refresh. The old code returned as soon as it had
    // printed ANY cached list, so it said "stale, refresh due" on every run
    // and never actually refreshed — the cache stayed old forever and every
    // `--models` paid the full network round trip.
    var list = models.listModels(gpa, &http, url, providers.authWithKey(def.key_style, key)) catch |err| {
        if (cached) |e| {
            try printModelCatalog(io, e.models, " (saved catalog, refresh failed)");
            std.debug.print("refresh failed: {t}\n", .{err});
            return 0; // offline: the stale list is better than no answer
        }
        std.debug.print("error: {t}\n", .{err});
        return 1;
    };
    defer list.deinit(gpa);
    modelcache.write(io, env, pid, url, list.items);
    try printModelCatalog(io, list.items, "");
    return 0;
}

fn printModelCatalog(io: std.Io, list: []const models.Model, note: []const u8) !void {
    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &out_buf);
    for (list) |m| {
        try out.interface.print("{s}\t{s}\n", .{ m.id, m.owned_by });
    }
    try out.interface.flush();
    var free: usize = 0;
    for (list) |m| {
        if (m.is_free) free += 1;
    }
    std.debug.print("{d} models ({d} free){s}\n", .{ list.len, free, note });
}

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
    model.nerd_icons = lang_icons.nerdIconsEnabled(init.environ_map);
    agent.status_model_target = &model;
    // Scrubbed child env: bash/bg tools inherit only safe vars, never keys.
    if (spawnenv_mod.buildChildEnv(gpa, init.environ_map.*)) |ce| {
        child_env_static = ce;
        child_env_live = true;
        model.bg.child_env = &child_env_static;
    } else |_| {}
    model.attachIo(io); // for the activity strip clock
    model.loadPromptHistory(); // ↑ still works after a restart
    model.attach();

    agent.io_global = io;
    // No core dumps with secrets: keys arena + palette buffers + environ
    // would otherwise land in a systemd-coredump. Suid-dumpable off.
    //
    // `ZODE_CORE_DUMP=1` lifts it for the crash you are hunting: with it the
    // whole heap — `auth.json`, tokens, palette text — is on disk under
    // /var/lib/systemd/coredump, so it is opt-in and not the default. The
    // rlimit has to be lifted too, or an `ulimit -c 0` from the caller's
    // environment silently swallows the core again.
    if (env_mod.truthyIn(init.environ_map, "ZODE_CORE_DUMP", false)) {
        if (std.posix.getrlimit(.CORE)) |lim| {
            if (lim.cur != lim.max) {
                _ = std.posix.setrlimit(.CORE, .{ .cur = lim.max, .max = lim.max }) catch {};
            }
        } else |_| {}
    } else {
        if (builtin.os.tag == .linux) _ = std.posix.prctl(.SET_DUMPABLE, .{@as(usize, 0)}) catch {};
    }
    // Without this the `models.dbg` diagnostics (status + server body) do not
    // show up in the TUI: you only see "models: HTTP error at <url>" and
    // nothing else, which does not say whether it was a 401, a 403 or a 404.
    models_mod.dbg_io = io;
    agent.api_key_global = envGet(init.environ_map, "ZODE_API_KEY");
    agent.environ_global = init.environ_map;
    agent.gpa_global = init.gpa;
    // Per-tool output caps from the environment (ZODE_MAX_TOOL_OUTPUT).
    tools_mod.initMaxToolOutput(init.environ_map);
    http_client.Http.initDefaultTimeout(init.environ_map);
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
    // Where THIS project's sessions live, before any session is created or
    // resumed: without it the TUI wrote to the relative default while `/session`
    // decided ownership against the absolute resolved dir, so the picker came up
    // empty on a project with sessions on disk.
    agent.resolveSessionsDirIn(init.gpa, init.environ_map);
    agent.bootMark("resolveSessionsDir");
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
    // Phase 13.3: the user's keybinding map is loaded once at startup, from
    // the same config.json the Settings screen persists. A malformed entry is
    // skipped by the pure parser; the defaults stay in force for that key.
    if (agent.user_config.keybindings) |kb| {
        const parsed = keybinds.parseJsonObject(model.allocator, .{ .object = kb }) catch &.{};
        model.keybindings = parsed;
    }
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

    // The crash-test flag decides whether the TUI dies inside its first draw
    // (alt screen active) instead of starting clean. See `Model.crash_test`.
    model.crash_test = envGet(init.environ_map, "ZODE_CRASH_TEST") != null;

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
/// Phase 37: `--diag` — one-shot internal snapshot for scripts/CI. Prints
/// the same /proc memory numbers as the TUI's /diag, to stdout, and returns 0.
pub fn runDiag(init: std.process.Init) u8 {
    const s = diag_mod.sample(init.io);
    var buf: [512]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buf);
    out.interface.print(
        "zode diag · pid {d} · rss {d:.1} MiB · size {d:.1} MiB · peak {d:.1} MiB\n",
        .{
            if (builtin.os.tag == .linux) std.os.linux.getpid() else 0,
            s.residentMiB(),
            @as(f64, @floatFromInt(s.vm_size_kb)) / 1024.0,
            @as(f64, @floatFromInt(s.vm_peak_kb)) / 1024.0,
        },
    ) catch return 1;
    out.interface.flush() catch return 1;
    return 0;
}

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
    var first = it.next();
    // 50.8: a caller-supplied system prompt suffix. It is process-wide and
    // never read from the project, so a repo cannot widen its own instructions.
    if (first) |arg0| {
        if (std.mem.eql(u8, arg0, "--append-system-prompt")) {
            const text = it.next() orelse {
                std.debug.print("error: --append-system-prompt needs a text argument.\n", .{});
                return 1;
            };
            agent.setAppendSystemPrompt(init.gpa, text);
            first = it.next();
        }
    }

    if (first) |arg0| {
        if (std.mem.eql(u8, arg0, "--resume")) {
            agent.resume_on_start = true;
            return runTui(init);
        }
        if (std.mem.eql(u8, arg0, "--models")) {
            return runModels(init.gpa, init.io, init.environ_map);
        }
        if (std.mem.eql(u8, arg0, "mission")) {
            var mission_args = std.ArrayList([]const u8).empty;
            defer mission_args.deinit(init.gpa);
            while (it.next()) |tok| try mission_args.append(init.gpa, tok);
            return mission_runner.run(init.gpa, init.io, init.environ_map, mission_args.items);
        }
        if (std.mem.eql(u8, arg0, "acp") or std.mem.eql(u8, arg0, "--acp")) {
            return acp_server.run(init.gpa, init.io, init.environ_map);
        }
        if (std.mem.eql(u8, arg0, "--chat")) {
            // Phase 22: `--chat --schema <file> "text"` — the caller supplies a
            // JSON schema; the model must call structured_output with a
            // matching object. `--chat "text"` keeps the plain mode.
            var schema_data: ?[]const u8 = null;
            var text: ?[]const u8 = null;
            while (it.next()) |tok| {
                if (std.mem.eql(u8, tok, "--schema")) {
                    const path = it.next() orelse {
                        std.debug.print("error: --schema needs a path to a JSON schema file.\n", .{});
                        return 1;
                    };
                    schema_data = std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(1024 * 1024)) catch |err| {
                        std.debug.print("error: could not read schema file {s}: {t}\n", .{ path, err });
                        return 1;
                    };
                } else {
                    text = tok;
                    break;
                }
            }
            const prompt_text = text orelse {
                std.debug.print("usage: zode --chat [--schema <file>] \"text\"\n", .{});
                return 1;
            };
            return headless.runChat(init.gpa, init.io, init.environ_map, prompt_text, schema_data);
        }
        if (std.mem.eql(u8, arg0, "--diag")) {
            return runDiag(init);
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
                    "  acp, --acp   run Agent Client Protocol (ACP) agent over stdio\n" ++
                    "  --models     list the models of the provider\n" ++
                    "  mission      autonomous missions (plan|status|check|run|stop|resume)\n" ++
                    "  --chat TXT   send a message (streaming)\n" ++
                    "  --chat --schema FILE TXT   schema mode: the model must call structured_output with a matching object (JSON on stdout, non-zero if missing)\n" ++
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

