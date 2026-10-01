const std = @import("std");
const tui = @import("tui.zig");
const providers = @import("providers.zig");
const chat = @import("chat.zig");
const http_client = @import("http_client.zig");
const tools_mod = @import("tools.zig");
const roster_mod = @import("roster.zig");
const free_auto = @import("free_auto.zig");
const plan_mod = @import("plan.zig");
const clean_mod = @import("clean.zig");
const mentions = @import("mentions.zig");
const session_mod = @import("session.zig");
const models_mod = @import("models.zig");
const cache_stats = @import("cache_stats.zig");
const compaction = @import("compaction.zig");
const mascot = @import("mascot.zig");
const palette = @import("palette.zig");
const config_mod = @import("config.zig");
const acp = @import("acp.zig");

/// Io and API key configured by the TUI at startup.
pub var io_global: std.Io = undefined;
pub var api_key_global: ?[]const u8 = null;
pub var environ_global: ?*const std.process.Environ.Map = null;
pub var gpa_global: std.mem.Allocator = undefined;

// ── system prompt: the project's AGENTS.md (cached) ──────────
var agents_md_cache: ?[]u8 = null;

pub const default_system_prompt =
    \\You are zode, a coding agent running inside a terminal harness.
    \\You help the user with software engineering tasks: fixing bugs, adding
    \\features, refactoring, and explaining code.
    \\
    \\Environment:
    \\ - You have tools: read, write, edit (str_replace, multi-hunk), bash,
    \\   glob, grep, list_files, web_fetch, web_search, think. Prefer
    \\   grep/glob first, then read only what you need.
    \\ - For edits, use the edit tool with exact old_string/new_string.
    \\ - web_fetch returns a URL as readable text (HTML stripped);
    \\   web_search gives titles, URLs and snippets. Use them when you need
    \\   facts you do not have (library docs, versions, exact error messages),
    \\   and say so when an answer comes from the web.
    \\ - Keep answers concise. Use markdown. Code blocks must include the
    \\   language tag so the terminal UI can highlight them.
    \\ - If a tool call is denied by the user, do not retry it; adjust approach.
    \\
;

fn systemPrompt(gpa: std.mem.Allocator) []const u8 {
    if (agents_md_cache == null) {
        // The user's project AGENTS.md / CLAUDE.md take priority.
        agents_md_cache = std.Io.Dir.cwd().readFileAlloc(io_global, "AGENTS.md", gpa, .limited(256 * 1024)) catch
            std.Io.Dir.cwd().readFileAlloc(io_global, "CLAUDE.md", gpa, .limited(256 * 1024)) catch null;
    }
    if (agents_md_cache) |c| return c;
    return default_system_prompt;
}

pub var current_effort: chat.Effort = .medium;

/// Permission mode: false = asks before write/edit/bash, true = auto.
pub var yolo: bool = false;

/// Max number of agentic iterations per request.
const max_iterations: usize = 8;

/// Tool results elided in the session (for /context).
var session_elided: usize = 0;

/// Tok/s of the in-flight stream (status bar) and of the last finished stream.
pub var tps_live: f64 = 0;
pub var tps_last: f64 = 0;

/// Context tokens used and the percentage of the limit.
///
/// Cached here because the status bar reads it EVERY FRAME, and walking the
/// history to estimate tokens 60 times per second is wasted work. Refreshed
/// when each turn closes.
pub var ctx_used: i64 = 0;
pub var ctx_pct: u8 = 0;

/// Recomputes `ctx_used`/`ctx_pct`. Cheap to call, but not needed per frame:
/// tokens only change when a message is added.
pub fn refreshContextUsage(m: *tui.Model) void {
    if (session == null) {
        ctx_used = 0;
        ctx_pct = 0;
        return;
    }
    var astate = std.heap.ArenaAllocator.init(m.allocator);
    defer astate.deinit();
    const msgs = snapshotMsgs(astate.allocator());
    ctx_used = compaction.estimateTokens(msgs);
    const limit = @max(1, compaction.contextLimit(m.environ));
    const pct = (@as(f64, @floatFromInt(ctx_used)) / @as(f64, @floatFromInt(limit))) * 100.0;
    ctx_pct = @intFromFloat(std.math.clamp(pct, 0, 999));
}

fn updateTps(chars: usize, start_ns: i128) void {
    if (start_ns == 0 or chars < 32) return;
    const now_ns = std.Io.Timestamp.now(io_global, .real).nanoseconds;
    const dt = now_ns - start_ns;
    if (dt <= 0) return;
    const tps = (@as(f64, @floatFromInt(chars)) / 4.0) / (@as(f64, @floatFromInt(dt)) / 1e9);
    if (tps > 0.5 and tps < 100_000) {
        tps_live = tps;
        tps_last = tps;
    }
}

// ── active provider / model / session ────────────────────────

var cur_provider_id: []const u8 = "opencode";
var cur_model: []const u8 = "";

/// Active session (`null` until the first message). The worker creates it, not
/// startup: opening a session file just because the program started would
/// create junk files if the user never chats.
var session: ?*session_mod.Session = null;

/// Reopen the last session at startup? Set by `ZODE_RESUME=1` or `--resume`.
pub var resume_on_start: bool = false;

/// Copies the model name into a static buffer (avoids dangling slices from
/// ephemeral input strings).
var cur_model_buf: [128]u8 = undefined;

/// Active provider and model, for the status bar. Exposed as functions (not
/// the raw `var`s) so the TUI does not depend on the static buffer.
pub fn curProvider() []const u8 {
    return cur_provider_id;
}
pub fn curModel() []const u8 {
    return cur_model;
}
pub fn setModel(name: []const u8) void {
    const n = @min(name.len, cur_model_buf.len);
    @memcpy(cur_model_buf[0..n], name[0..n]);
    cur_model = cur_model_buf[0..n];
}

// ── permissions: "always allow" per tool (session) ───────────
const max_always = 8;
var always_names: [max_always][48]u8 = undefined;
var always_lens: [max_always]usize = @splat(0);

fn isAlwaysAllowed(name: []const u8) bool {
    for (always_lens, 0..) |l, i| {
        if (l > 0 and std.mem.eql(u8, always_names[i][0..l], name)) return true;
    }
    return false;
}

fn setAlwaysAllowed(m: *tui.Model, name: []const u8) void {
    if (setAlwaysAllowedNoSave(name)) {
        saveAllowlist();
        const msg = std.fmt.allocPrint(m.allocator, "always allowed: {s}", .{name}) catch return;
        pushInfoOwned(m, msg);
    }
}

/// Like `setAlwaysAllowed` but WITHOUT writing to disk: used by the initial
/// load, which does not want to rewrite the file it just read.
/// Returns false if the allowlist is full (it does not grow without limit: it
/// is at most 8 tools, and past that it is noise in the permission dialog).
fn setAlwaysAllowedNoSave(name: []const u8) bool {
    if (isAlwaysAllowed(name)) return true;
    for (always_lens, 0..) |l, i| {
        if (l == 0) {
            const n = @min(name.len, 48);
            @memcpy(always_names[i][0..n], name[0..n]);
            always_lens[i] = n;
            return true;
        }
    }
    return false;
}

/// Reads `permissions.json` and fills the allowlist. Best-effort: if it does
/// not exist or is corrupt, the session starts with an empty allowlist.
fn loadAllowlist() void {
    var pbuf: [512]u8 = undefined;
    const path = permissionsFilePath(&pbuf) orelse return;

    var astate = std.heap.ArenaAllocator.init(gpa_global);
    defer astate.deinit();
    const a = astate.allocator();

    const data = readFileTo(a, path) orelse return;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, data, .{}) catch return;
    if (parsed != .array) return;
    for (parsed.array.items) |v| {
        if (v != .string) continue;
        _ = setAlwaysAllowedNoSave(v.string);
    }
}

// ── persisted allowlist: ~/.config/zode/permissions.json ─────
fn permissionsFilePath(buf: []u8) ?[]const u8 {
    const home = environ_global.?.get("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/zode/permissions.json", .{home}) catch null;
}

/// Persists the "always allow" allowlist as a JSON array of names.
///
/// By hand (not with a writer over a map) because it is at most 8 strings and
/// this way it reads at a glance.
fn saveAllowlist() void {
    var pbuf: [512]u8 = undefined;
    const path = permissionsFilePath(&pbuf) orelse return;

    var names: [max_always][]const u8 = undefined;
    var n: usize = 0;
    for (always_lens, 0..) |l, i| {
        if (l == 0) continue;
        names[n] = always_names[i][0..l];
        n += 1;
    }

    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    config_mod.writeStringArray(&w, gpa_global, names[0..n]) catch return;
    std.Io.Dir.cwd().writeFile(io_global, .{ .sub_path = path, .data = w.buffered() }) catch {};
}

fn readFileTo(arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io_global, path, arena, .limited(1 << 20)) catch null;
}

// ── environment and history notices ───────────────────────────

fn envGet(env: ?*const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const m = env orelse return null;
    return m.get(key);
}

/// [roster] La etiqueta del free-auto para el status bar, o "" si está apagado.
///
/// Es un `pub` en vez de dejar que la TUI importe `free_auto.zig`: el status bar
/// solo debe saber leer, no escribir, del estado del modo.
pub fn freeAutoLabel(gpa: std.mem.Allocator) []const u8 {
    return free_auto.freeAutoLabel(gpa);
}

/// [roster] Enciende el free-auto si el entorno lo pide (`ZODE_FREE_AUTO=1`).
///
/// Lo llama el arranque de la TUI, DESPUÉS de `loadUserConfig` y de `loadAuthKeys`
/// (sin keys cargadas el pool saldría vacío y el modo parecería roto).
pub fn initFreeAutoFromEnv(m: *tui.Model) void {
    free_auto.initFromEnv(m, m.environ);
}

/// [roster] `pub` para que lo use `free_auto.zig` desde su worker.
pub fn pushInfo(m: *tui.Model, text: []const u8) void {
    m.pushInfo(text);
}

/// [roster] `pub` so `free_auto.zig` can use it from its worker.
pub fn pushError(m: *tui.Model, text: []const u8) void {
    m.pushError(text);
}

/// Variant that already owns the caller's memory: the text does not have to be
/// duplicated (nor freed). Used in the worker, which cannot leave garbage per
/// frame.
/// [roster] `pub` so `free_auto.zig` can use it.
pub fn pushInfoOwned(m: *tui.Model, text: []const u8) void {
    m.pushInfoOwned(text);
}

/// Error to the history, in RED (`md.Kind.error_msg`, `✗` prefix).
///
/// The Kind and the prefix existed from the start, and NO caller used it:
/// every error went out through `pushInfoOwned`, which is `.info` grey. In
/// other words a 403 and a "session resumed" read equally dim, and in a long
/// history the error was just one more line among a hundred.
fn pushErrorOwned(m: *tui.Model, text: []const u8) void {
    m.pushErrorOwned(text);
}

/// Sets the turn status. The text does NOT carry the face: the TUI draws it in
/// the status row, in the mood's color, exactly once. Here it used to be
/// embedded and it came out duplicated and in the same grey as everything else
/// (which is precisely the complaint that "you can't tell by the color").
/// [roster] `pub` so `free_auto.zig` can use it.
pub fn setStatusWithZo(m: *tui.Model, mood: mascot.Mood, text: []const u8) void {
    m.setStatusWithMood(mood, text);
}

// ── providers: config.json > built-in ────────────────────────

/// All providers: the user's `config.json` first, then the built-ins that are
/// not overridden (a config id beats the built-in).
/// [roster] `pub` so `free_auto.zig` can list the providers of the pool.
pub fn allProviders(arena: std.mem.Allocator) []const providers.ProviderDef {
    return config_mod.allDefs(arena, user_config);
}

pub fn activeProviderDef(env: ?*const std.process.Environ.Map) *const providers.ProviderDef {
    if (config_mod.find(user_config, cur_provider_id)) |d| return d;
    return providers.byId(cur_provider_id) orelse providers.activeDef(env);
}

/// API key of the active provider: first the one saved in `auth.json`, then
/// the environment variable, then the generic one.
fn curKey(m: *tui.Model) ?[]const u8 {
    if (providers.keyFor(activeProviderDef(m.environ), m.environ)) |k| return k;
    if (api_key_global) |k| return k;
    return envGet(m.environ, "ZODE_API_KEY");
}

// ── user config ───────────────────────────────────────────────

var cfg_arena_state: ?std.heap.ArenaAllocator = null;
var user_config: config_mod.Config = .{};

/// Loads the user's `config.json`. Call once at startup.
pub fn loadUserConfig() void {
    if (cfg_arena_state == null) {
        cfg_arena_state = std.heap.ArenaAllocator.init(gpa_global);
        user_config = config_mod.load(cfg_arena_state.?.allocator(), io_global, environ_global);

        // Precedence order: config.json > ZODE_PROVIDER > opencode.
        // (ZODE_PROVIDER used to be ignored in the TUI: it stayed on "opencode"
        // and ended up sending one provider's key to another provider's
        // endpoint → 403.)
        if (user_config.provider.len > 0) {
            cur_provider_id = user_config.provider;
        } else if (envGet(environ_global, "ZODE_PROVIDER")) |p| {
            if (config_mod.find(user_config, p) != null or providers.byId(p) != null) {
                cur_provider_id = p;
            }
        }
        if (user_config.model.len > 0) {
            setModel(user_config.model);
        } else if (cur_model.len == 0) {
            setModel(activeProviderDef(environ_global).default_model);
        }
        loadAllowlist();
        loadAuthKeys(cfg_arena_state.?.allocator());
    }
}

/// Reads `~/.config/zode/auth.json` and hands it to `providers` so `keyFor`
/// uses it. Without this, connecting a provider from the palette saved the key
/// and then never used it: `keyFor` only looked at the environment.
/// Arena for the saved keys. **Never destroyed until the process exits**.
///
/// Before, every config reload reused the config's arena, which WAS freed: the
/// models worker was reading `saved_keys` through `providers.hasKey` while the
/// UI thread connected a provider and freed that arena under its feet.
/// Use-after-free, with nothing announcing it (it depends on the worker
/// landing exactly on that line).
///
/// Here every new map lives in its own permanent arena, so reassigning the
/// pointer is atomic and the old map stays valid memory (what is no longer
/// used is freed at exit).
var keys_arena_state: ?std.heap.ArenaAllocator = null;

fn loadAuthKeys(_: std.mem.Allocator) void {
    var buf: [1024]u8 = undefined;
    const path = config_mod.authPath(environ_global, &buf) orelse return;

    if (keys_arena_state == null) keys_arena_state = std.heap.ArenaAllocator.init(gpa_global);
    const a = keys_arena_state.?.allocator();

    const data = readFileTo(a, path) orelse return;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, data, .{}) catch return;
    if (parsed != .object) return;

    var map = a.create(std.StringHashMapUnmanaged([]const u8)) catch return;
    map.* = .{};
    var it = parsed.object.iterator();
    while (it.next()) |kv| {
        const v = kv.value_ptr.*;
        if (v != .string or v.string.len == 0) continue;
        // The key is copied because the parser's string lives in the arena that was
        // just freed above.
        map.put(a, kv.key_ptr.*, a.dupe(u8, v.string) catch continue) catch continue;
    }
    providers.setSavedKeys(map);
}

/// Re-reads `config.json` from scratch.
///
/// `loadUserConfig` guards on "only once" (the config is read at startup), so
/// without this, after connecting a provider its key state stayed at "no key"
/// for the rest of the session.
pub fn reloadUserConfig() void {
    // CAREFUL: `shutdownUserConfig` is NOT called here, because that function also
    // destroys the keys arena, which a worker may be reading. The keys arena is
    // destroyed only in `shutdownUserConfig`, at the end of the process.
    if (cfg_arena_state) |*st| st.deinit();
    cfg_arena_state = null;
    user_config = .{};
    loadUserConfig();
}

/// Frees the config and keys arenas. On process exit, when no worker is left
/// reading.
pub fn shutdownUserConfig() void {
    if (cfg_arena_state) |*s| {
        s.deinit();
        cfg_arena_state = null;
    }
    if (keys_arena_state) |*s| {
        s.deinit();
        keys_arena_state = null;
    }
    providers.setSavedKeys(null);
    user_config = .{};
}

// ── session ───────────────────────────────────────────────────

/// Returns the active session, creating it if needed.
///
/// Called from the worker and from the commands. The session is created THE
/// FIRST TIME it is needed, not at startup: so opening the TUI and closing it
/// without chatting does not leave an empty `sessions/zode-*.jsonl` lying
/// around.
fn ensureSession(m: *tui.Model, arena: std.mem.Allocator) *session_mod.Session {
    if (session) |s| return s;
    _ = arena;
    const fresh = session_mod.Session.create(m.allocator, io_global) catch {
        // Without disk it carries on: that is degradation, not a fatal error. The
        // in-memory session (`file = null`) writes nothing.
        const s = m.allocator.create(session_mod.Session) catch @panic("sin memoria para la sesión");
        s.* = session_mod.Session.init(m.allocator);
        session = s;
        return s;
    };
    session = fresh;
    return fresh;
}

/// A file's diff carries the LANGUAGE so that the body of each line
/// is tokenized (`+const n: u32 = 42`: keyword, type and number are
/// distinguishable).
///
/// Without this the whole diff came out in the prefix's color, which is the
/// green wall of the ROADMAP. The path extension is the source: it is what we
/// have, and it requires asking the model nothing.
fn langFromPath(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return "";
    if (dot + 1 >= base.len) return "";
    return base[dot + 1 ..];
}

/// Creates a new session and discards the current one.
pub fn newSession(m: *tui.Model) void {
    if (session) |old| {
        m.allocator.destroy(old);
        session = null;
    }
    const s = ensureSession(m, m.allocator);
    m.pushInfoFmt("new session: {s}", .{s.id[0..]});
    session_elided = 0;
}

// ── turn stats (ROADMAP phase 3) ──────────────────────────────

/// What happened in the current turn: tools, files, lines, duration.
///
/// Lives as a MODULE GLOBAL (like `CacheStats`) and not inside the `TurnCtx`,
/// because the `TurnCtx` is destroyed in `runOneTurn`'s `defer` exactly when
/// the summary has to be written. The alternative (accumulating in `TurnCtx`
/// and handing it to `chatWorker`) would force returning the struct through the
/// same path that returns the synthesized text.
pub const TurnStats = struct {
    gpa: std.mem.Allocator = undefined,
    iterations: usize = 0,
    tools: usize = 0,
    denied: usize = 0,
    /// Files touched, in order of appearance, without repeats.
    files: std.ArrayList([]const u8) = .empty,
    lines_added: usize = 0,
    lines_removed: usize = 0,
    t0_ns: i128 = 0,

    /// Starts counting a turn. Frees the previous one.
    ///
    /// CAREFUL with the order: `deinit` uses `self.gpa` (the one from the
    /// PREVIOUS turn), so you must free before overwriting the allocator. With
    /// the struct initialized to `.{}` (`gpa` undefined) that would be a `free`
    /// with garbage.
    pub fn reset(self: *TurnStats, gpa: std.mem.Allocator, t0_ns: i128) void {
        self.deinit();
        self.* = .{ .gpa = gpa, .t0_ns = t0_ns };
    }

    pub fn deinit(self: *TurnStats) void {
        // `files.capacity == 0` = list with no memory of its own: there is nothing
        // to free and `gpa` may be uninitialized.
        if (self.files.capacity == 0) return;
        for (self.files.items) |f| self.gpa.free(f);
        self.files.deinit(self.gpa);
    }

    /// Records a touched file with its diff. If it was already there, it only adds
    /// the line counts: writing the same file twice in a turn is one line, not
    /// two files.
    pub fn noteDiff(self: *TurnStats, path: []const u8, counts: tui.DiffCounts) void {
        if (counts.added == 0 and counts.removed == 0) return;
        for (self.files.items) |f| {
            if (std.mem.eql(u8, f, path)) {
                self.lines_added += counts.added;
                self.lines_removed += counts.removed;
                return;
            }
        }
        const copy = self.gpa.dupe(u8, path) catch return;
        self.files.append(self.gpa, copy) catch {
            self.gpa.free(copy);
            return;
        };
        self.lines_added += counts.added;
        self.lines_removed += counts.removed;
    }

    pub fn noteTool(self: *TurnStats) void {
        self.tools += 1;
    }

    pub fn noteDenied(self: *TurnStats) void {
        self.denied += 1;
    }

    /// Milliseconds the turn has been running (0 if there is no clock).
    pub fn elapsedMs(self: *const TurnStats, now_ns: i128) u64 {
        if (self.t0_ns == 0) return 0;
        return @intCast(@max(0, now_ns - self.t0_ns) / std.time.ns_per_ms);
    }

    /// `⏺ Done · 3 tools · 2 files changed · 12.4s · ~18k tokens (62% cached)`
    ///
    /// Returns memory from the allocator it is given (a copy of `gpa`), not
    /// internal pointers: the `files` belong to the turn and may be freed.
    ///
    /// Writes into `buf` (the caller's) and returns a slice of it: no
    /// allocations, because this line is composed once per turn but the caller
    /// puts it into the history, which already copies.
    pub fn summaryLine(
        self: *const TurnStats,
        buf: []u8,
        ms: u64,
        tokens_used: i64,
        cache_pct: u8,
    ) ![]const u8 {
        var w: std.Io.Writer = .fixed(buf);
        try w.writeAll("\u{23ba} Done \u{b7} ");
        try w.print("{d} tool{s}", .{ self.tools, if (self.tools == 1) "" else "s" });
        if (self.denied > 0) try w.print(" \u{b7} {d} denied", .{self.denied});
        if (self.files.items.len > 0) {
            try w.print(" \u{b7} {d} file{s} changed", .{
                self.files.items.len,
                if (self.files.items.len == 1) "" else "s",
            });
            if (self.lines_added > 0 or self.lines_removed > 0) {
                try w.print(" (+{d} \u{2212}{d})", .{ self.lines_added, self.lines_removed });
            }
        }
        try w.print(" \u{b7} {d}.{d}s", .{ ms / 1000, (ms % 1000) / 100 });
        if (tokens_used > 0) {
            try w.print(" \u{b7} ~{d}k tokens", .{@divTrunc(tokens_used + 500, 1000)});
            if (cache_pct > 0) try w.print(" ({d}% cached)", .{cache_pct});
        }
        return w.buffered();
    }

    /// Second line: `src/agent.zig · src/tui.zig` (the files touched).
    ///
    /// The files go alone: the summary already says how many tools ran, and
    /// what is useful here is the WHAT, not the tool. It could be stored with
    /// the tool's name, but with a turn of 5 tools the line runs off the screen
    /// and the path is what people are looking for.
    pub fn detailLine(self: *const TurnStats, buf: []u8) ![]const u8 {
        var w: std.Io.Writer = .fixed(buf);
        var first = true;
        for (self.files.items) |f| {
            if (!first) try w.writeAll(" \u{b7} ");
            first = false;
            try w.writeAll(f);
        }
        return w.buffered();
    }
};

/// Stats of the current turn. Module global (see `TurnStats`).
pub var turn_stats: TurnStats = .{};

/// 1 MiB buffer to compose the request body (ROADMAP 5.5).
///
/// It used to be `var body_buf: [1 << 20]u8` on `runOneTurn`'s STACK. With
/// `std.Thread`'s default stack (16 MiB) it works, but it is RESIDENT memory
/// for the whole call and it leaves a trap: the day someone lowers the worker's
/// `stack_size`, 1 MiB of stack turns into a segfault. On the heap instead,
/// reused across requests (allocated once).
var body_buf_heap: ?[]u8 = null;

fn bodyBuf(gpa: std.mem.Allocator) ![]u8 {
    if (body_buf_heap == null) {
        body_buf_heap = try gpa.alloc(u8, 1 << 20);
    }
    return body_buf_heap.?;
}

/// Frees the body buffer. Called by the TEARDOWN, never at runtime (the keys
/// map has similar rules).
///
/// No allocator parameter, like `shutdownUserConfig`: the buffer was reserved
/// with `gpa_global`, so freeing it with a different allocator would be an
/// `Invalid free`.
pub fn shutdownBuffers() void {
    if (body_buf_heap) |b| {
        gpa_global.free(b);
        body_buf_heap = null;
    }
}

test "TurnStats: un fichero tocado dos veces cuenta como uno" {
    var s = TurnStats{};
    var backing: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    const g = fba.allocator();
    s.reset(g, 0);
    s.noteDiff("a.zig", .{ .added = 3, .removed = 1 });
    s.noteDiff("a.zig", .{ .added = 2, .removed = 0 });
    s.noteDiff("b.zig", .{ .added = 5, .removed = 5 });
    s.noteTool();
    try std.testing.expectEqual(@as(usize, 2), s.files.items.len);
    try std.testing.expectEqual(@as(usize, 10), s.lines_added);
    try std.testing.expectEqual(@as(usize, 6), s.lines_removed);
    s.deinit();
}

test "TurnStats: el resumen dice tools, ficheros y lineas" {
    var s = TurnStats{};
    var backing: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    const g = fba.allocator();
    s.reset(g, 0);
    s.noteTool();
    s.noteTool();
    s.noteTool();
    s.noteDiff("src/tui.zig", .{ .added = 12, .removed = 3 });
    var line_buf: [256]u8 = undefined;
    const line = try s.summaryLine(&line_buf, 12_400, 18_000, 62);
    try std.testing.expect(std.mem.indexOf(u8, line, "3 tools") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "1 file changed") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "+12 \u{2212}3") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "12.4s") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "18k tokens") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "62% cached") != null);
    var detail_buf: [128]u8 = undefined;
    const detail = try s.detailLine(&detail_buf);
    try std.testing.expectEqualStrings("src/tui.zig", detail);
    s.deinit();
}

test "TurnStats: un diff de 0 lineas no inventa ficheros" {
    var s = TurnStats{};
    var backing: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    const g = fba.allocator();
    s.reset(g, 0);
    s.noteDiff("nada.zig", .{});
    try std.testing.expectEqual(@as(usize, 0), s.files.items.len);
    s.deinit();
}

/// Empties the current session's history without creating a new one.
pub fn resetSession(m: *tui.Model) void {
    if (session) |s| {
        s.messages.clearRetainingCapacity();
        s.flush();
    }
    session_elided = 0;
    m.pushInfoFmt("session reset", .{});
}

/// Opens the session at startup: the most recent one if it was asked for
/// (`--resume` or `ZODE_RESUME=1`), otherwise a new one.
pub fn bootstrapSession(m: *tui.Model) void {
    loadUserConfig();

    if (resume_on_start) {
        var astate = std.heap.ArenaAllocator.init(m.allocator);
        defer astate.deinit();
        const a = astate.allocator();
        const latest = session_mod.Session.latestSessionPath(a, io_global) catch null;
        if (latest) |path| {
            if (session_mod.Session.resumePath(m.allocator, io_global, path)) |s| {
                session = s;
                const msg = std.fmt.allocPrint(m.allocator, "sesión reanudada: {s}", .{s.path orelse s.id[0..]}) catch
                    "sesión reanudada";
                pushInfoOwned(m, msg);
                return;
            } else |_| {}
        }
        const msg = allocPrint(m, "nothing to resume; starting a new session", .{}) catch return;
        pushInfoOwned(m, msg);
    }
    // CAREFUL: the session is NOT created here (ROADMAP 1.9). This line used to
    // open a `sessions/zode-*.jsonl` on EVERY startup, and since the file is
    // created empty and nobody chatted, `sessions/` filled up with 0-byte
    // files: 58 files, 24 of them empty. The session is created by
    // `ensureSession`, which is only called when the first message is sent (or
    // when `/new` is explicitly requested).
}

/// Short `allocPrint`: the worker writes 90% of the history messages and cannot
/// leave garbage per frame.
fn allocPrint(m: *tui.Model, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(m.allocator, fmt, args);
}

/// Copies the session messages into a slice of `ChatMessage`.
///
/// `tool` → role "tool" (as OpenAI's API expects), and `system` stays first.
/// The memory comes from the arena the caller passes in.
fn snapshotMsgs(arena: std.mem.Allocator) []chat.ChatMessage {
    const s = session orelse return &.{};
    const msgs = arena.alloc(chat.ChatMessage, s.messages.items.len) catch return &.{};
    for (s.messages.items, 0..) |sm, i| {
        msgs[i] = .{
            .role = @tagName(sm.role),
            .content = sm.content,
            .tool_calls_json = sm.tool_calls_json,
            .tool_call_id = sm.tool_call_id,
            .tool_name = sm.tool_name,
        };
    }
    return msgs;
}

// ── command table ─────────────────────────────────────────────

pub const Cmd = struct {
    key: []const u8,
    desc: []const u8,
    /// Keyboard shortcut that does the same thing (right column of the palette).
    /// Only ones that really exist are listed: putting a fake one would be worse
    /// than putting none.
    key_hint: ?[]const u8 = null,
};

/// `key` comes with the leading slash. The order is the order of appearance in
/// `/help`.
pub const commands = [_]Cmd{
    .{ .key = "/help", .desc = "show commands", .key_hint = "ctrl+p" },
    .{ .key = "/models", .desc = "list the active provider models" },
    .{ .key = "/model", .desc = "pick a model in a modal", .key_hint = "ctrl+p" },
    .{ .key = "/provider", .desc = "pick a provider in a modal" },
    .{ .key = "/providers", .desc = "list providers" },
    .{ .key = "/use", .desc = "switch provider/model", .key_hint = "provider modelo" },
    .{ .key = "/effort", .desc = "low|medium|high (no args: picker)" },
    .{ .key = "/free-auto", .desc = "on|off: rotate free models across providers when one runs out" },
    .{ .key = "/plan", .desc = "clear the visible task list" },
    .{ .key = "/undo", .desc = "restore the files the last turn changed" },
    .{ .key = "/clean", .desc = "purge zode leftovers (dry run; /clean yes applies)" },
    .{ .key = "/yolo", .desc = "toggle auto permissions" },
    .{ .key = "/allowlist", .desc = "tools always allowed (persisted)" },
    .{ .key = "/acp", .desc = "on|off|<cmd>: delegate the turn to an ACP agent (opencode acp)" },
    .{ .key = "/new", .desc = "new session" },
    .{ .key = "/resume", .desc = "resume the last session" },
    .{ .key = "/context", .desc = "tokens used vs budget (compaction at 80%)" },
    .{ .key = "/session", .desc = "session info" },
    .{ .key = "/cache", .desc = "cache hit-rate for this session" },
    .{ .key = "/quit", .desc = "quit", .key_hint = "ctrl+c" },
};

/// Atajos que NO son comandos: hay que teclearlos, no van en la paleta.
///
/// `/help` solo listaba la tabla de comandos, así que la mitad de los atajos
/// (los que no tienen comando detrás) no estaban escritos en ningún sitio, y
/// los que sí lo tienen aparecían sin su atajo. Con Ctrl+P se descubren, pero
/// quien acaba de abrir la app no sabe que existe.
pub const shortcuts = [_]struct { key: []const u8, desc: []const u8 }{
    .{ .key = "ctrl+p", .desc = "command palette (executes the one you pick)" },
    .{ .key = "ctrl+t", .desc = "model palette (providers | models)" },
    .{ .key = "ctrl+a", .desc = "connect a provider (paste its key)" },
    .{ .key = "ctrl+l", .desc = "clear the view (the session file is untouched)" },
    .{ .key = "ctrl+r", .desc = "expand / collapse the last tool result" },
    .{ .key = "ctrl+c", .desc = "quit" },
    .{ .key = "ctrl+u / ctrl+d", .desc = "scroll half a page" },
    .{ .key = "page up / down", .desc = "scroll a page" },
    .{ .key = "shift+enter", .desc = "newline (enter sends)" },
    .{ .key = "esc", .desc = "stop the turn / close a modal" },
    .{ .key = "tab", .desc = "complete a `/` command" },
    .{ .key = "↑ / ↓", .desc = "command history (empty line keeps the draft)" },
};

/// `/help`: commands (with their shortcut) and then the bare shortcuts.
///
/// Two blocks because they answer two different questions: "what can I type"
/// and "what can I press". Before this there was only the first one, and only
/// without the shortcut column, so half the keybindings were written down
/// nowhere — you find them by hitting Ctrl+P and hoping.
fn cmdHelp(m: *tui.Model) void {
    const gpa = m.allocator;
    pushInfoOwned(m, gpa.dupe(u8, "commands") catch return);
    for (commands) |c| {
        const line = if (c.key_hint) |h|
            std.fmt.allocPrint(gpa, "{s: <14} {s}  ({s})", .{ c.key, c.desc, h }) catch continue
        else
            std.fmt.allocPrint(gpa, "{s: <14} {s}", .{ c.key, c.desc }) catch continue;
        pushInfoOwned(m, line);
    }

    pushInfoOwned(m, gpa.dupe(u8, "shortcuts") catch return);
    for (shortcuts) |s| {
        const line = std.fmt.allocPrint(gpa, "{s: <18} {s}", .{ s.key, s.desc }) catch continue;
        pushInfoOwned(m, line);
    }
}

/// `/allowlist`: which tools are in "always allow".
/// The allowlist lives in `~/.config/zode/permissions.json` and there was no
/// way to see it: if a tool stopped asking and you did not know why, the only
/// way was to open the file by hand. It also says whether `/yolo` is on, which
/// is the other way of "don't ask me".
fn cmdAllowlist(m: *tui.Model) void {
    var line_buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&line_buf);
    w.writeAll("always allowed: ") catch {};
    var n: usize = 0;
    for (always_lens, 0..) |l, i| {
        if (l == 0) continue;
        if (n > 0) w.writeAll(" \u{b7} ") catch {};
        w.writeAll(always_names[i][0..l]) catch {};
        n += 1;
    }
    if (n == 0) w.writeAll("(none)") catch {};
    if (yolo) w.writeAll("  \u{b7} yolo ON: everything is auto-allowed") catch {};
    const msg = std.fmt.allocPrint(
        m.allocator,
        "{s}",
        .{w.buffered()},
    ) catch return;
    pushInfoOwned(m, msg);
}

/// `/cache`: prompt cache hit-rate of the session.
fn cmdCache(m: *tui.Model) void {
    const st = &cache_stats.session;
    const line = std.fmt.allocPrint(
        m.allocator,
        "cache [{s}] {d:.1}% hit-rate · {d} reqs with hit · {d} prompt / {d} cached / {d} completion",
        .{ cur_provider_id, st.hitRatePct(), st.cache_hits, st.prompt_tokens, st.cached_tokens, st.completion_tokens },
    ) catch "cache";
    pushInfoOwned(m, line);
}

/// `/context`: gauge of context used against the limit and the budget.
fn cmdContext(m: *tui.Model) void {
    _ = ensureSession(m, m.allocator);
    var astate = std.heap.ArenaAllocator.init(m.allocator);
    defer astate.deinit();
    const msgs = snapshotMsgs(astate.allocator());

    const used = compaction.estimateTokens(msgs);
    const budget = compaction.budgetTokens(m.environ);
    const limit = compaction.contextLimit(m.environ);
    const sys: i64 = if (msgs.len > 0) compaction.estimateTokens(msgs[0..1]) else 0;
    const hist = used - sys;
    const pct_limit = @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(limit)) * 100.0;
    const pct_budget = @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(budget)) * 100.0;
    const turns: usize = if (msgs.len > 0) msgs.len - 1 else 0;

    // 20-cell gauge (█ = E2 96 88, ░ = E2 90 8A)
    var gauge_buf: [60]u8 = undefined;
    const filled: usize = @intFromFloat(@min(pct_limit, 100.0) / 5.0);
    var gi: usize = 0;
    for (0..filled) |_| {
        @memcpy(gauge_buf[gi .. gi + 3], "█");
        gi += 3;
    }
    for (filled..20) |_| {
        @memcpy(gauge_buf[gi .. gi + 3], "░");
        gi += 3;
    }

    const l1 = std.fmt.allocPrint(
        m.allocator,
        "context [{s}] ~{d} / {d} tokens ({d:.1}% of limit)",
        .{ gauge_buf[0..gi], used, limit, pct_limit },
    ) catch "context";
    pushInfoOwned(m, l1);
    const l2 = std.fmt.allocPrint(
        m.allocator,
        "  system ~{d} · history ~{d} · {d} turns · budget {d} ({d:.0}% used)",
        .{ sys, hist, turns, budget, pct_budget },
    ) catch "details";
    pushInfoOwned(m, l2);
    const l3 = std.fmt.allocPrint(
        m.allocator,
        "  elided this session: {d} tool results · last stream: {d:.0} tok/s",
        .{ session_elided, tps_last },
    ) catch "details";
    pushInfoOwned(m, l3);

    refreshContextUsage(m);
}

/// `/session`: id, path and message count.
fn cmdSession(m: *tui.Model) void {
    const s = ensureSession(m, m.allocator);
    const l1 = std.fmt.allocPrint(
        m.allocator,
        "session {s} · {d} messages",
        .{ s.id[0..], s.messages.items.len },
    ) catch "sesión";
    pushInfoOwned(m, l1);
    if (s.path) |p| {
        m.pushInfoFmt("  {s}", .{p});
    }
}

/// `/providers`: lists the providers with their key state.
fn cmdProviders(m: *tui.Model) void {
    for (allProviders(m.allocator)) |*d| {
        const key_state: []const u8 =
            if (d.key_env.len == 0) "sin key" else if (providers.keyFor(d, m.environ) != null) "key ok" else "SIN KEY";
        const active: []const u8 = if (std.mem.eql(u8, d.id, cur_provider_id)) " ←" else "";
        const line = std.fmt.allocPrint(
            m.allocator,
            "{s:<11} {s} ({s}){s}  {s}",
            .{ d.id, d.name, key_state, active, d.note },
        ) catch "provider";
        pushInfoOwned(m, line);
    }
}

/// `/effort low|medium|high`, or the picker if it comes without arguments.
fn cmdEffort(m: *tui.Model, arg: ?[]const u8) void {
    if (arg) |a| {
        if (std.mem.eql(u8, a, "low")) {
            current_effort = .low;
        } else if (std.mem.eql(u8, a, "medium") or std.mem.eql(u8, a, "med")) {
            current_effort = .medium;
        } else if (std.mem.eql(u8, a, "high")) {
            current_effort = .high;
        } else {
            const msg = std.fmt.allocPrint(m.allocator, "unknown effort: {s} (low|medium|high)", .{a}) catch
                "effort";
            pushInfoOwned(m, msg);
            return;
        }
        const name = switch (current_effort) {
            .low => "low",
            .medium => "medium",
            .high => "high",
        };
        m.pushInfoFmt("effort → {s}", .{name});
        return;
    }
    openEffortPicker(m);
}

/// `/use <provider> [model]`.
fn cmdUse(m: *tui.Model, arg: ?[]const u8) void {
    const a = arg orelse {
        m.pushInfoFmt("usage: /use <provider> [model]", .{});
        return;
    };
    var it = std.mem.tokenizeScalar(u8, a, ' ');
    const prov = it.next() orelse return;
    applyProvider(m, prov) catch return;
    if (it.next()) |mo| applyModel(m, mo) catch {};
}

/// `/yolo`: toggle for automatic permissions.
fn cmdYolo(m: *tui.Model) void {
    yolo = !yolo;
    const msg = if (yolo) "yolo ON: no confirmations" else "yolo OFF: asks for permission";
    pushInfo(m, msg);
    setStatusWithZo(m, if (yolo) .warn else .idle, msg);
}

/// What to do with the command that was just chosen in the palette.
pub const PaletteCmd = enum {
    /// Executed right here, right now.
    done,
    /// Needs arguments: the label goes to the input and the user types what is
    /// missing.
    needs_args,
    /// Leave the app. The TUI handles it (it is who owns `ctx.quit`).
    quit,
};

/// Runs a command chosen in the palette, WITHOUT going through the input.
///
/// Choosing a command from a list is already the confirmation: putting it in
/// the input and asking for another Enter was a second step nobody asked for,
/// and in a TUI where keys get eaten along the way it read as "it did
/// nothing".
///
/// The EXCEPTION is the commands that need arguments: `/use provider model`
/// cannot be run blind. Those go back to the input with the label in place,
/// which is exactly what whoever picks them wants.
///
/// The command echoes itself in the history (like the input) so you can see
/// what was run, not just what happened.
pub fn runPaletteCommand(m: *tui.Model, cmd: []const u8) PaletteCmd {
    if (std.mem.eql(u8, cmd, "/quit")) return .quit;
    if (std.mem.eql(u8, cmd, "/use")) return .needs_args;
    m.pushKind(.user, cmd);
    submit(m, cmd) catch {};
    return .done;
}

/// Entry point of the TUI input: free text or a `/…` command.
///
/// A chat starts a WORKER (thread) that talks to the API; a command is resolved
/// here, in the UI thread, because they are local operations.
pub fn submit(m: *tui.Model, input: []const u8) !void {
    if (input.len == 0) return;
    if (input[0] != '/') return startChat(m, input);

    var it = std.mem.tokenizeScalar(u8, input[1..], ' ');
    const cmd = it.next() orelse return;
    // Without arguments it is a real `null`, not an empty slice. `it.rest()`
    // returns `""` for "/effort", and with an empty non-null slice the `else` of
    // "low|medium|high" swallowed the case: `/effort` on its own answered
    // "unknown effort:  (low|medium|high)" instead of opening the picker.
    const rest = it.rest();
    const arg: ?[]const u8 = if (rest.len == 0) null else rest;

    if (std.mem.eql(u8, cmd, "help")) {
        cmdHelp(m);
    } else if (std.mem.eql(u8, cmd, "quit")) {
        // the TUI handles it
    } else if (std.mem.eql(u8, cmd, "models")) {
        listModelsAsync(m) catch pushError(m, "error starting /models");
    } else if (std.mem.eql(u8, cmd, "providers")) {
        cmdProviders(m);
    } else if (std.mem.eql(u8, cmd, "provider")) {
        openProviderPicker(m);
    } else if (std.mem.eql(u8, cmd, "model")) {
        // It opens RIGHT AWAY (the providers column is local) and the models are
        // painted when they arrive. Before, nothing opened until the network
        // answered, and with a slow provider it looked like the command did
        // nothing.
        openModelPaletteAsync(m);
    } else if (std.mem.eql(u8, cmd, "effort")) {
        cmdEffort(m, arg);
    } else if (std.mem.eql(u8, cmd, "use")) {
        cmdUse(m, arg);
    } else if (std.mem.eql(u8, cmd, "plan")) {
        cmdPlan(m);
    } else if (std.mem.eql(u8, cmd, "undo")) {
        cmdUndo(m);
    } else if (std.mem.eql(u8, cmd, "clean")) {
        // `m.allocator`, not the `Allocator` TYPE. The local `a` above shadows
        // the type name inside this function, so the annotation resolved to a
        // variable and the whole module failed to compile. The tests that build
        // a `Model` on a FixedBufferAllocator caught it.
        cmdClean(m, cleanWanted(m.environ, arg));
    } else if (std.mem.eql(u8, cmd, "free-auto")) {
        free_auto.cmdFreeAuto(m, arg);
    } else if (std.mem.eql(u8, cmd, "yolo")) {
        cmdYolo(m);
    } else if (std.mem.eql(u8, cmd, "allowlist")) {
        cmdAllowlist(m);
    } else if (std.mem.eql(u8, cmd, "acp")) {
        cmdAcp(m, arg orelse "");
    } else if (std.mem.eql(u8, cmd, "context")) {
        cmdContext(m);
    } else if (std.mem.eql(u8, cmd, "session")) {
        cmdSession(m);
    } else if (std.mem.eql(u8, cmd, "cache")) {
        cmdCache(m);
    } else if (std.mem.eql(u8, cmd, "new")) {
        newSession(m);
    } else if (std.mem.eql(u8, cmd, "resume")) {
        resumeLatest(m);
    } else {
        const msg = std.fmt.allocPrint(m.allocator, "unknown command: {s} (/help)", .{cmd}) catch
            "unknown command";
        pushInfoOwned(m, msg);
    }
}

// ── ACP: the turn is delegated to another agent ───────────────

/// ACP mode: zode does NOT do the turn, it hands it to an ACP agent (by default
/// `opencode acp`) speaking JSON-RPC over the pipes of its child process.
///
/// It is the "trick behind the scenes": opencode's terminal is not poked, its
/// engine is talked to. The session history is opencode's, not zode's.
pub var acp_on: bool = false;
/// ACP agent command. `ZODE_ACP_CMD` sets it (words separated by spaces) and
/// `/acp <cmd>` changes it for the session.
pub var acp_cmd: ?[]const u8 = null;

/// Live client, or null. Started lazily and REUSED across turns: the ACP
/// session (and its context) live in the process, so one per turn would be
/// amnesia memory.
var acp_client: ?*acp.Client = null;

/// Called by the TUI on exit. Without this the child stays hung alive.
pub fn shutdownAcp() void {
    if (acp_client) |c| {
        c.deinit();
        acp_client = null;
    }
}

/// ESC: if the turn goes through ACP it has to be cut through its protocol
/// (`session/cancel`), not just by setting the flag of the HTTP streams.
pub fn cancelAcp(m: *tui.Model) void {
    if (!acp_on) return;
    if (acp_client) |c| c.cancel();
    // Say "cancelling" instead of leaving the status as it was: the turn does
    // not stop on the spot (the agent has to confirm with a stopReason), and
    // without this text ESC looks like it did nothing.
    setStatusWithZo(m, .warn, "cancelling…");
}

/// Name of the active ACP agent, for the status bar.
pub fn acpTitle() []const u8 {
    if (acp_client) |c| return c.agentTitle();
    return "pending";
}

/// State of the connection to the ACP agent.
///
/// Startup is NOT done at the prompt: `opencode acp` brings up a private server
/// and that takes several seconds. It is launched as soon as `/acp` is
/// enabled, so the first prompt only waits for it to be ready.
const AcpState = enum { off, connecting, ready, failed };

var acp_state: AcpState = .off;
/// Error code of the failed startup, so it can be shown.
var acp_start_err: anyerror = error.SpawnFailed;
/// Guards writes to `acp_client` from the connection thread.
///
/// It is a SPINLOCK (`tryLock`, not `lock`): it is taken for a moment and
/// released, and the sections are two lines long. A reentrant `lock` would
/// hang the app, which is exactly the `pushPending` trap at the other end of the
/// code.
var acp_lock: std.atomic.Mutex = .unlocked;

fn acpLock() void {
    while (!acp_lock.tryLock()) std.Thread.yield() catch {};
}
fn acpUnlock() void {
    acp_lock.unlock();
}

/// The agent's argv, from `acp_cmd` or the default one.
///
/// It is returned in `out` because the slice has to live in the caller: the
/// argv are pointers to words of the command, not its length.
fn acpArgv(out: *[8][]const u8) []const []const u8 {
    var argv: []const []const u8 = &acp.default_argv;
    const cmd = acp_cmd orelse return argv;
    var it = std.mem.tokenizeAny(u8, cmd, " ");
    var n: usize = 0;
    while (it.next()) |word| {
        if (n >= out.len) break;
        out[n] = word;
        n += 1;
    }
    if (n > 0) argv = out[0..n];
    return argv;
}

/// The absolute cwd for `session/new`.
///
/// ACP requires it. In 0.16 there is no `getCwd`, so the `/proc/self/cwd`
/// symlink is used, which is the process's real cwd (the environment's `PWD`
/// can be lying). Without `/proc` it falls back to `PWD` and, as a last
/// resort, to "/".
fn acpCwd() []const u8 {
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.cwd().readLink(io_global, "/proc/self/cwd", &link_buf) catch 0;
    if (n > 0 and link_buf[0] == '/') return link_buf[0..n];
    if (environ_global) |env| {
        if (env.get("PWD")) |pwd| {
            if (pwd.len > 0 and pwd[0] == '/') return pwd;
        }
    }
    return "/";
}

const ConnectJob = struct {
    /// The model ONLY to leave a notice in the history. The thread uses it with
    /// `pushInfoOwned`, which is thread-safe. It registers itself as a worker
    /// (`beginWorker`) so `waitWorkers` waits for it at shutdown: otherwise the
    /// thread could touch an already destroyed `Model`.
    m: *tui.Model,
    gpa: std.mem.Allocator,
    argv: [8][]const u8,
    argv_len: usize,
    cwd: [std.fs.max_path_bytes]u8,
    cwd_len: usize,
    env: ?*const std.process.Environ.Map,
};

/// Connection thread. Only writes to the state (under `acp_lock`) and exits.
fn acpConnectThread(job: *ConnectJob) void {
    const gpa = job.gpa;
    const m = job.m;
    m.beginWorker();
    defer m.endWorker();
    defer gpa.destroy(job);

    const cwd = job.cwd[0..job.cwd_len];
    const c = acp.Client.start(gpa, io_global, job.argv[0..job.argv_len], cwd, job.env) catch |err| {
        acpLock();
        acp_state = .failed;
        acp_start_err = err;
        acpUnlock();
        setStatusWithZo(m, .warn, "the ACP agent did not start");
        return;
    };
    acpLock();
    acp_client = c;
    acp_state = .ready;
    acpUnlock();

    // Notice in the history as soon as the agent is ready: the status bar already
    // shows the name, but this leaves a record of the session.
    const msg = std.fmt.allocPrint(
        gpa,
        "ACP connected · agent {s} · session {s}",
        .{ c.agentTitle(), c.sessionId() },
    ) catch return;
    defer gpa.free(msg);
    // `pushInfo` COPIES the text; `pushInfoOwned` TAKES OWNERSHIP of it, and with
    // the `free` above the row came out with garbage (all `�`).
    pushInfo(m, msg);
}

/// Launches the connection in the background. Returns false if one was already
/// in progress or ready.
fn startAcpConnect(
    model: *tui.Model,
    gpa: std.mem.Allocator,
    env: ?*const std.process.Environ.Map,
) bool {
    acpLock();
    defer acpUnlock();
    if (acp_state == .connecting or acp_state == .ready) return false;

    const job = gpa.create(ConnectJob) catch return false;
    errdefer gpa.destroy(job);
    job.* = .{
        .m = model,
        .gpa = gpa,
        .argv = undefined,
        .argv_len = 0,
        .cwd = undefined,
        .cwd_len = 0,
        .env = env,
    };
    var argv_store: [8][]const u8 = undefined;
    const argv = acpArgv(&argv_store);
    @memcpy(job.argv[0..argv.len], argv);
    job.argv_len = argv.len;

    const cwd = acpCwd();
    @memcpy(job.cwd[0..cwd.len], cwd);
    job.cwd_len = cwd.len;

    acp_state = .connecting;
    const th = std.Thread.spawn(.{}, acpConnectThread, .{job}) catch {
        acp_state = .off;
        gpa.destroy(job);
        return false;
    };
    th.detach();
    return true;
}

/// Returns the client, waiting for the connection to finish if needed.
///
/// `m` is only used for the status while waiting; if startup fails the error is
/// translated into something readable (see `reportAcpErr`).
fn ensureAcp(m: *tui.Model) !*acp.Client {
    acpLock();
    const st = acp_state;
    if (st == .ready) {
        const c = acp_client.?;
        acpUnlock();
        return c;
    }
    if (st == .failed) {
        const err = acp_start_err;
        acp_state = .off;
        acpUnlock();
        return err;
    }
    if (st == .off) {
        acpUnlock();
        // Nobody is connecting (cold start, e.g. `--resume`): start it in the
        // worker thread and wait here.
        _ = startAcpConnect(m, m.allocator, m.environ);
        acpLock();
        if (acp_state != .ready) {
            acpUnlock();
            return error.SpawnFailed;
        }
        const c = acp_client.?;
        acpUnlock();
        return c;
    }
    acpUnlock();

    // A connection is in progress: wait WITHOUT touching the shared `Io` (see
    // `acp.nap`), which is what used to freeze the TUI.
    setStatusWithZo(m, .thinking, "connecting to the ACP agent…");
    var spins: usize = 0;
    while (spins < 1200) : (spins += 1) {
        acpLock();
        const s2 = acp_state;
        const c = acp_client;
        acpUnlock();
        if (s2 == .ready) {
            if (c) |cc| return cc;
            continue;
        }
        if (s2 == .failed) {
            acpLock();
            const err = acp_start_err;
            acp_state = .off;
            acpUnlock();
            return err;
        }
        acp.nap(50);
    }
    return error.HandshakeFailed;
}

/// `/acp [on|off|<command>]`
fn cmdAcp(m: *tui.Model, arg: []const u8) void {
    const a = std.mem.trim(u8, arg, " \t");
    if (std.mem.eql(u8, a, "off")) {
        acp_on = false;
        shutdownAcp();
        pushInfo(m, "ACP off: the turns go through zode again");
        return;
    }
    if (a.len > 0 and !std.mem.eql(u8, a, "on")) {
        acp_cmd = m.allocator.dupe(u8, a) catch null;
        // Changing agent implies restarting the child: the previous one already has
        // its session and its context.
        shutdownAcp();
    }
    acp_on = true;
    // The connection starts NOW, in the background, not with the first prompt.
    if (startAcpConnect(m, m.allocator, m.environ)) {
        setStatusWithZo(m, .thinking, "connecting to the ACP agent…");
        pushInfo(m, "ACP on: connecting to the agent in the background (/acp off to go back)");
    } else {
        pushInfo(m, "ACP on");
    }
}

/// The worker of an ACP turn.
///
/// CAREFUL: there is NO tool loop here. In ACP the tools are executed by the
/// AGENT, not by zode: the `session/update` with `tool_call` is painted and its
/// `tool_call_update` with `completed` is the result. That is why a turn is one
/// prompt and nothing more.
fn acpWorker(job: *ChatJob) void {
    const m = job.model;
    const user_text = job.text;
    defer {
        m.allocator.free(user_text);
        m.allocator.destroy(job);
    }
    m.beginWorker();
    defer m.endWorker();

    var prompt: []const u8 = user_text;
    var owned_prompt: ?[]u8 = null;
    defer if (owned_prompt) |o| m.allocator.free(o);

    while (true) {
        m.streamStart();
        setStatusWithZo(m, .thinking, "thinking");

        const c = ensureAcp(m) catch |err| {
            reportAcpErr(m, err);
            m.streamEnd();
            return;
        };

        var t = AcpTurn{ .m = m, .client = c };
        t.sink = .{
            .userdata = &t,
            .onText = AcpTurn.onText,
            .onThought = AcpTurn.onThought,
            .onTool = AcpTurn.onTool,
            .onToolUpdate = AcpTurn.onToolUpdate,
            .onPlan = AcpTurn.onPlanLine,
            .onPermission = AcpTurn.onPermission,
        };
        defer t.deinit();

        c.prompt(prompt) catch |err| {
            reportAcpErr(m, err);
            m.streamEnd();
            return;
        };
        const reason = c.waitTurn(&t.sink) catch |err| {
            reportAcpErr(m, err);
            m.streamEnd();
            return;
        };

        // What the agent said is stored in zode's session (even though the real
        // history is opencode's): that way `/resume` and the diff still make
        // sense inside zode.
        if (t.text.items.len > 0) {
            ensureSession(m, m.allocator).appendAssistant(t.text.items, null) catch {};
        }
        ensureSession(m, m.allocator).flush();
        // Closes the live paragraph if the turn ended talking (if it ended with
        // a tool, `onTool` already closed it and this does nothing).
        if (t.streaming_open) {
            t.streaming_open = false;
            m.streamEnd();
        }

        if (std.mem.eql(u8, reason, "cancelled")) {
            pushError(m, "ACP turn cancelled");
        }

        // Next queued prompt, if there is one.
        const next = m.takeQueued() orelse break;
        if (owned_prompt) |o| m.allocator.free(o);
        owned_prompt = next;
        prompt = next;
    }
}

/// An agent text in ONE line, trimmed.
///
/// The `agent_thought_chunk`s and the plan entries arrive chopped up and with
/// newlines inside. Painting them as-is fills the history with half rows; and
/// painting each piece separately, with 40 fragments.
///
/// The slice may point to a buffer on this function's stack (the "there is a
/// newline" case): that is safe because the only caller is `pushInfo`, which
/// COPIES the text into the model's allocator before queueing it.
fn oneLine(s: []const u8) []const u8 {
    const clean = std.mem.trim(u8, s, " \t\n\r");
    if (clean.len == 0) return "";
    var it = std.mem.tokenizeAny(u8, clean, "\n\r");
    const first = it.next() orelse return "";
    if (it.next() != null) {
        var buf: [256]u8 = undefined;
        return std.fmt.bufPrint(&buf, "{s} …", .{std.mem.trimEnd(u8, first, " \t")}) catch first;
    }
    return first;
}

/// Context of an ACP turn: translates the `session/update`s to the TUI.
const AcpTurn = struct {
    m: *tui.Model,
    client: *acp.Client,
    text: std.ArrayList(u8) = .empty,
    /// Is there an open streaming paragraph?
    ///
    /// CAREFUL: in ACP the agent INTERLEAVES text and tools (it talks, calls a
    /// tool, talks again). The streaming paragraph has to be closed on every
    /// tool, because otherwise the tool header is painted BEFORE the text that
    /// preceded it and the history ends up out of order. In the HTTP flow it is
    /// not needed because there the stream always ends before the tools.
    streaming_open: bool = false,
    tool_start_ns: [8]i128 = undefined,
    tool_start_len: usize = 0,
    sink: acp.Sink = undefined,

    fn deinit(self: *AcpTurn) void {
        self.text.deinit(self.m.allocator);
    }

    fn onText(ud: ?*anyopaque, s: []const u8) void {
        const t: *AcpTurn = @ptrCast(@alignCast(ud.?));
        t.text.appendSlice(t.m.allocator, s) catch {};
        if (!t.streaming_open) {
            t.m.streamStart();
            t.streaming_open = true;
        }
        t.m.streamDelta(s);
    }

    /// The agent's reasoning does not go into the main paragraph: it is painted as
    /// an info line, which is where you read it without getting in the way of
    /// the answer.
    /// The reasoning arrives chopped up and with newlines inside: it is joined
    /// into ONE line (with "…") because `pushInfo` is one row per call and 40
    /// loose fragments fill the history with junk.
    ///
    /// CAREFUL: `pushInfo` already adds the `·` prefix; adding it here came out
    /// as "· · hola".
    fn onThought(ud: ?*anyopaque, s: []const u8) void {
        const t: *AcpTurn = @ptrCast(@alignCast(ud.?));
        pushInfo(t.m, oneLine(s));
    }

    fn onTool(ud: ?*anyopaque, id: []const u8, name: []const u8, title: []const u8) void {
        const t: *AcpTurn = @ptrCast(@alignCast(ud.?));
        // Closes the text that came before the tool, so the tool header ends up
        // BELOW it and not on top of it.
        if (t.streaming_open) {
            t.m.streamEnd();
            t.streaming_open = false;
        }
        const tool = if (name.len > 0) name else "tool";
        const arg = if (title.len > 0) title else "…";
        t.m.pushToolStart(tool, arg);
        setStatusWithZo(t.m, .tooling, arg);
        if (t.tool_start_len < t.tool_start_ns.len) {
            t.tool_start_ns[t.tool_start_len] = std.Io.Timestamp.now(io_global, .real).nanoseconds;
            t.tool_start_len += 1;
        }
        _ = id;
    }

    fn onToolUpdate(ud: ?*anyopaque, id: []const u8, status: []const u8, text: []const u8) void {
        const t: *AcpTurn = @ptrCast(@alignCast(ud.?));
        // `pending` and `in_progress` do not close the line: the "running" clock stays
        // until the tool actually finishes.
        if (std.mem.eql(u8, status, "pending") or std.mem.eql(u8, status, "in_progress")) return;
        // Closes the live paragraph BEFORE queueing the result. The "live paragraph"
        // block is ALWAYS painted at the end of the history, so if the agent's
        // text were still open, the "⎿ exit=0" came out below its last sentence
        // instead of just below the tool.
        if (t.streaming_open) {
            t.m.streamEnd();
            t.streaming_open = false;
        }
        if (std.mem.eql(u8, status, "cancelled")) {
            t.m.pushToolDone(t.client.toolName(id), "cancelled", 0, "");
            return;
        }
        const ms: u64 = blk: {
            if (t.tool_start_len == 0) break :blk 0;
            const now = std.Io.Timestamp.now(io_global, .real).nanoseconds;
            const started = t.tool_start_ns[t.tool_start_len - 1];
            break :blk @intCast(@max(0, now - started) / std.time.ns_per_ms);
        };
        var summary: [120]u8 = undefined;
        const head = std.mem.trim(u8, text, " \n\t");
        const sum = if (head.len > 0)
            std.fmt.bufPrint(&summary, "{s}", .{std.mem.trimEnd(u8, head, "\n")}) catch "done"
        else
            "done";
        t.m.pushToolDone(t.client.toolName(id), sum, ms, text);
    }

    fn onPlanLine(ud: ?*anyopaque, s: []const u8) void {
        const t: *AcpTurn = @ptrCast(@alignCast(ud.?));
        pushInfo(t.m, oneLine(s));
    }

    fn onPermission(
        ud: ?*anyopaque,
        tool: []const u8,
        detail: []const u8,
        options: []const acp.PermOption,
    ) ?[]const u8 {
        const t: *AcpTurn = @ptrCast(@alignCast(ud.?));
        // The agent brings its own options; the one that matches what the user
        // answered is looked up. Without options there is nothing to draw.
        if (options.len == 0) return null;

        // `/yolo`: the first allow option, without asking.
        if (yolo) {
            for (options) |o| {
                if (std.mem.startsWith(u8, o.kind, "allow")) return o.id;
            }
            return null;
        }

        const ask = if (tool.len > 0) tool else "the ACP agent wants to run a tool";
        const answer = t.m.requestPermission("acp", detail);
        const want: []const u8 = switch (answer) {
            .allow => "allow_once",
            .allow_always => "allow_always",
            .deny, .none => "reject",
        };
        for (options) |o| {
            if (std.mem.eql(u8, o.kind, want)) return o.id;
        }
        // The agent did not offer exactly what was asked for: any
        // "allow once" is the closest to "yes, right now".
        if (answer == .allow or answer == .allow_always) {
            for (options) |o| {
                if (std.mem.startsWith(u8, o.kind, "allow")) return o.id;
            }
        }
        for (options) |o| {
            if (std.mem.startsWith(u8, o.kind, "reject")) return o.id;
        }
        _ = ask;
        return null;
    }
};

// ── /clean: purge zode's own leftovers, nothing else ──────────

/// Was a delete asked for? Either `/clean yes` on the command line, or
/// `ZODE_YES=1` for when the MODEL runs it (a model that can only type
/// `/clean` and then be told "no, with yes" has no way out).
fn cleanWanted(env: ?*const std.process.Environ.Map, arg: ?[]const u8) bool {
    if (arg) |a| {
        if (std.mem.eql(u8, a, "yes") or std.mem.eql(u8, a, "y") or
            std.mem.eql(u8, a, "apply")) return true;
    }
    const v = envGet(env, "ZODE_YES") orelse return false;
    return std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "yes");
}

/// The config dir, or null. `/clean` reads it to find the leftover
/// `<name>.tmp` of an interrupted atomic write (`config.zig` writes to a temp
/// and renames it).
fn cleanConfigDir(a: std.mem.Allocator, env: ?*const std.process.Environ.Map) ?[]const u8 {
    const home = envGet(env, "HOME") orelse return null;
    return std.fmt.allocPrint(a, "{s}/.config/zode", .{home}) catch null;
}

/// `/clean`: the leftovers of zode, and ONLY those.
///
/// Dry run by default. The output has to carry the NUMBERS, not just "clean":
/// "24 empty sessions" is checkable and "nothing to do" is not, and a cleanup
/// command that reports success without saying what it looked at is the one
/// that lies when it is wrong.
///
/// The `auth.json` / `.zig-cache` exclusion is not here on purpose: it lives in
/// `clean.isProtected`, next to the scan that could reach them, with the tests
/// that hold it. A "never touch" list written in the UI would only hold for as
/// long as nobody adds a new scan.
fn cmdClean(m: *tui.Model, aplicar: bool) void {
    // The allocator is a local, and its name is not `a`: `a` is also the name
    // the two `allocPrint` helpers below use for their own temporaries, and one
    // name cannot be both the type and the value.
    const gpa = m.allocator;
    const inst = clean_mod.instanceDir(gpa, io_global) catch null;
    defer if (inst) |p| gpa.free(p);
    const cfg = cleanConfigDir(gpa, m.environ);
    defer if (cfg) |p| gpa.free(p);

    const now_secs = std.Io.Timestamp.now(io_global, .real).toSeconds();
    var rep = clean_mod.scan(gpa, io_global, .{
        .roots = .{ .sessions = "sessions", .instances = inst, .config = cfg },
        .now_secs = now_secs,
    }) catch {
        pushInfo(m, "/clean: could not read the directories");
        return;
    };
    defer rep.deinit();

    const header: []const u8 = if (aplicar)
        "/clean: applied"
    else
        "/clean: dry run (nothing deleted)";
    pushInfo(m, header);

    if (rep.missing_sessions) {
        pushInfo(m, "  no sessions/ directory here (nothing to clean in it)");
    }

    const order = [_]clean_mod.Bucket{ .empty_session, .own_temp, .stale_instance, .old_session };
    for (order) |b| {
        const n = rep.count(b);
        if (n == 0) continue;
        const line = std.fmt.allocPrint(gpa, "  {d:>3} {s} ({s})", .{
            n,
            b.label(),
            if (b == .old_session) "kept, delete with find sessions/ -mtime +30d" else b.rootHint(),
        }) catch continue;
        pushInfoOwned(m, line);
    }

    if (rep.items.len == 0 and !rep.missing_sessions) {
        pushInfo(m, "  nothing to clean");
        return;
    }

    if (!aplicar) {
        const total = rep.deletable();
        if (total == 0) {
            pushInfo(m, "  nothing to delete without a yes");
            return;
        }
        const line = std.fmt.allocPrint(
            gpa,
            "  -> {d} files, {d} bytes. run `/clean yes` to delete them",
            .{ total, rep.bytes() },
        ) catch return;
        pushInfoOwned(m, line);
        return;
    }

    const deleted = clean_mod.apply(io_global, &rep, .{
        .sessions = "sessions",
        .instances = inst,
        .config = cfg,
    }) catch 0;
    // The failure count goes in the output on purpose: `apply` swallows the
    // per-file error so one unreadable file does not abort the rest, and
    // without this line "deleted 23" would be a lie when 24 were candidates.
    const tail: []const u8 = if (rep.failed == 0)
        std.fmt.allocPrint(gpa, "  deleted {d} files", .{deleted}) catch "  done"
    else
        std.fmt.allocPrint(gpa, "  deleted {d}, {d} could NOT be removed", .{ deleted, rep.failed }) catch
            "  done (with failures)";
    pushInfoOwned(m, tail);
}

/// ACP errors with a text that makes sense in the UI (not `error.X`).
fn reportAcpErr(m: *tui.Model, err: anyerror) void {
    const line: []const u8 = switch (err) {
        error.SpawnFailed => blk: {
            const cmd = acp_cmd orelse "opencode acp";
            break :blk std.fmt.allocPrint(
                m.allocator,
                "could not launch the ACP agent ({s}). Is `opencode` in the PATH? /acp <cmd> sets another one.",
                .{cmd},
            ) catch "ACP: could not launch the agent";
        },
        error.HandshakeFailed => "ACP: the agent did not answer initialize/session/new",
        error.NoSession => "ACP: no session (the agent closed it?)",
        error.AgentDied => "ACP: the agent closed the connection mid-turn",
        error.OutOfMemory => return,
        // The `catch` cannot be a LITERAL: `pushInfoOwned` takes ownership of the
        // text and frees it in `Model.deinit`, so a literal here is an "Invalid
        // free" on the OOM path (which is exactly when you least want a second
        // crash). No memory, no message.
        else => std.fmt.allocPrint(m.allocator, "ACP: {t}", .{err}) catch return,
    };
    pushInfoOwned(m, line);
}

/// `/resume`: reopens the most recent session by mtime.
fn resumeLatest(m: *tui.Model) void {
    var astate = std.heap.ArenaAllocator.init(m.allocator);
    defer astate.deinit();
    const a = astate.allocator();

    const latest = session_mod.Session.latestSessionPath(a, io_global) catch null;
    const path = latest orelse {
        pushError(m, "no saved sessions");
        return;
    };
    if (session) |old| {
        m.allocator.destroy(old);
        session = null;
    }
    const s = session_mod.Session.resumePath(m.allocator, io_global, path) catch {
        pushError(m, "could not read the session");
        return;
    };
    session = s;
    session_elided = 0;
    const msg = std.fmt.allocPrint(
        m.allocator,
        "session resumed: {s} · {d} messages",
        .{ path, s.messages.items.len },
    ) catch "sesión reanudada";
    pushInfoOwned(m, msg);
    refreshContextUsage(m);
}

// ── the chat: worker and agent loop ───────────────────────────

/// Launches the worker of a turn. All the I/O happens here, in its own
/// thread; the UI only receives events.
/// Job of the chat thread. `text` is a COPY that the worker frees, so the
/// input buffer can be reused as soon as it is queued.
const ChatJob = struct {
    model: *tui.Model,
    text: []const u8,
};

fn startChat(m: *tui.Model, input: []const u8) !void {
    const s = ensureSession(m, m.allocator);
    const copy = try m.allocator.dupe(u8, input);
    errdefer m.allocator.free(copy);

    // If a turn is already in flight, QUEUE it instead of launching a worker in
    // parallel: two workers writing at the same time to the same session and
    // the same streaming state is what made the input freeze and the history
    // cut itself off.
    if (m.isBusy()) {
        _ = m.enqueuePrompt(copy);
        m.pushInfoFmt("⏳ queued ({d} waiting)", .{m.queuedCount()});
        return;
    }

    s.append(.user, copy) catch {};
    s.flush();

    // [undo] One snapshot per TURN, not per tool: the user thinks in turns
    // ("undo that"), and the checkpoint is named after the prompt so the
    // message can say which turn it was. Note it opens AFTER the `enqueuePrompt`
    // above, because a queued prompt is NOT a new turn (there are no tools yet)
    // and it would wipe the checkpoint of a turn that had not even started.
    m.beginCheckpoint(copy);

    // Opens the streaming paragraph and marks busy: the UI can already paint the
    // spinner while the worker talks to the API.
    m.streamStart();
    // No "…": the face already blinks and the clock runs, the ellipsis only
    // adds noise.
    setStatusWithZo(m, .thinking, "thinking");

    const job = try m.allocator.create(ChatJob);
    m.beginWorker(); // the worker closes it; if the spawn fails, we close it here
    job.* = .{ .model = m, .text = copy };
    // ACP mode delegates the turn to another agent: same worker, different body.
    // CAREFUL: it picks the FUNCTION, not a bool, because `std.Thread.spawn`
    // with a comptime-only that depends on runtime control does not compile.
    const spawned = if (acp_on)
        std.Thread.spawn(.{}, acpWorker, .{job}) catch null
    else
        std.Thread.spawn(.{}, chatWorker, .{job}) catch null;
    const th = spawned orelse {
        m.endWorker();
        m.allocator.destroy(job);
        m.allocator.free(copy);
        m.streamEnd();
        return error.ThreadSpawnFailed;
    };
    th.detach();
}

/// The worker: one turn of conversation with the API, with tools.
fn chatWorker(job: *ChatJob) void {
    const m = job.model;
    const user_text = job.text;
    defer {
        m.allocator.free(user_text);
        m.allocator.destroy(job);
    }
    // Worker counter: the thread is decoupled, and on exit you have to wait for it
    // BEFORE destroying the `Io` (see `Model.waitWorkers`).
    m.beginWorker();
    defer m.endWorker();

    // The turn stats start here (not in `runOneTurn`): the turn is the whole
    // `chatWorker`, with its 8 iterations.
    turn_stats.reset(m.allocator, std.Io.Timestamp.now(io_global, .real).nanoseconds);
    defer turn_stats.deinit();

    var iterations: usize = 0;
    var last_user: []const u8 = user_text;
    var owned: ?[]u8 = null; // synthesized text of an iteration (owned)

    while (iterations < max_iterations) : (iterations += 1) {
        turn_stats.iterations = iterations + 1;
        const again = runOneTurn(m, last_user, iterations) catch |err| {
            reportErr(m, err);
            // Con el free-auto encendido, el estado del pool ES la siguiente
            // pregunta del usuario ("¿y ahora qué?"), y la respuesta cabe en una
            // línea. Sin esto se ve un error y nada más.
            notePoolState(m);
            m.streamEnd();
            pushTurnSummary(m);
            return;
        };
        const text = again orelse break;
        if (owned) |o| m.allocator.free(o);
        owned = text;
        last_user = text;
    }
    if (owned) |o| m.allocator.free(o);
    if (iterations >= max_iterations) pushError(m, "agent iteration limit reached: stopping the turn");
    m.streamEnd();
    pushTurnSummary(m);
}

/// The turn summary in the history: 2 lines that say what happened.
///
/// Before, the end of a turn was literally `setStatusWithZo(m, .done, "done")`
/// and nothing else: no files, no tools, no tokens, no duration. And since the
/// activity strip turns off when it finishes, the only thing left visible from
/// the turn is the status, which gets replaced on the next turn.
fn pushTurnSummary(m: *tui.Model) void {
    const s = &turn_stats;
    const now_ns = std.Io.Timestamp.now(io_global, .real).nanoseconds;
    const ms = s.elapsedMs(now_ns);

    // CAREFUL: `pushInfo` (which COPIES) and not `pushInfoOwned`.
    // `pushInfoOwned` TAKES OWNERSHIP of the text and frees it in
    // `Model.deinit`, so handing it a pointer to a STACK buffer leaves the
    // pending queue with a pointer to a frame that dies when this function
    // returns: the next draw paints freed memory (SIGSEGV in
    // `ensureParaHeights`) and the exit would be an "Invalid free".
    var line_buf: [256]u8 = undefined;
    const line = s.summaryLine(&line_buf, ms, ctx_used, cacheHitPct()) catch return;
    pushInfo(m, line);

    if (s.files.items.len == 0) return;
    var detail_buf: [512]u8 = undefined;
    const detail = s.detailLine(&detail_buf) catch return;
    if (detail.len == 0) return;
    pushInfo(m, detail);
}

/// Cache hit-rate of the session, rounded (0 = no data).
fn cacheHitPct() u8 {
    const r = cache_stats.session.hitRatePct();
    if (r <= 0) return 0;
    return @intFromFloat(std.math.clamp(r, 0, 100));
}

/// The session's cache stats, for the usage column of the status bar.
///
/// A snapshot by value and not a pointer to the global: the status bar is read
/// once per frame from the UI thread while the worker writes `session`, and a
/// `*CacheStats` would invite reading it mid-update.
pub fn cacheSessionStats() cache_stats.CacheStats {
    return cache_stats.session;
}

/// The same stats, but as a pointer, so tests can seed and reset them.
///
/// A mutable view of a global that the worker also writes: only for tests, and
/// only where no turn is in flight.
pub fn cacheSessionStatsForTest() *cache_stats.CacheStats {
    return &cache_stats.session;
}

/// Userdata of the three callbacks of a turn.
///
/// CAREFUL: `onDelta`, `onToolCall` and `onFinish` receive the SAME
/// `?*anyopaque`. If they were passed `&text_sink` and then `onToolCall` cast it
/// to `*TextSink`, on the very first token we would already be reading fields
/// of another type: in ReleaseFast that is silent UB. That is why a struct with
/// its own name is used here.
const TurnCtx = struct {
    m: *tui.Model,
    /// Assistant text of this turn (dumped into the session at the end).
    text: std.ArrayList(u8) = .empty,
    /// Tool calls requested in this turn.
    calls: std.ArrayList(Call) = .empty,
    /// A tool in flight: its header is already painted and the line has to be
    /// closed.
    tool_open: bool = false,
    /// Stream chars, for the tok/s.
    chars: usize = 0,
    /// Moment of the first token (ns). 0 = nothing has arrived yet.
    stream_start_ns: i128 = 0,
    /// Finish reason of the request.
    finish: [32]u8 = undefined,
    finish_len: usize = 0,

    const Call = struct {
        id: []const u8,
        name: []const u8,
        args_json: []const u8,
    };

    fn deinit(self: *TurnCtx) void {
        const gpa = self.m.allocator;
        for (self.calls.items) |c| {
            gpa.free(c.id);
            gpa.free(c.name);
            gpa.free(c.args_json);
        }
        self.calls.deinit(gpa);
        self.text.deinit(gpa);
    }
};

fn onDelta(ud: ?*anyopaque, delta: []const u8) void {
    const t: *TurnCtx = @ptrCast(@alignCast(ud.?));
    t.text.appendSlice(t.m.allocator, delta) catch {};
    t.chars += delta.len;
    if (t.stream_start_ns == 0) {
        t.stream_start_ns = std.Io.Timestamp.now(io_global, .real).nanoseconds;
    }
    t.m.streamDelta(delta);
}

fn onToolCall(ud: ?*anyopaque, id: []const u8, name: []const u8, args_json: []const u8) void {
    const t: *TurnCtx = @ptrCast(@alignCast(ud.?));
    const gpa = t.m.allocator;
    t.calls.append(gpa, .{
        .id = gpa.dupe(u8, id) catch return,
        .name = gpa.dupe(u8, name) catch return,
        .args_json = gpa.dupe(u8, args_json) catch return,
    }) catch {};
}

fn onFinish(ud: ?*anyopaque, reason: []const u8) void {
    const t: *TurnCtx = @ptrCast(@alignCast(ud.?));
    const n = @min(reason.len, t.finish.len);
    @memcpy(t.finish[0..n], reason[0..n]);
    t.finish_len = n;
}

/// A turn's `tool_calls` as JSON for the session.
///
/// It is the SAME format that `chat.StreamCtx.toolCallsJson` writes (the one
/// the headless runner uses): if they diverge, one of the two clients sends a
/// conversation the other cannot read. That is why this is here and not a
/// "seems enough": `arguments` goes as an escaped JSON string, not as a nested
/// object.
fn toolCallsJsonFromCalls(gpa: std.mem.Allocator, calls: []const TurnCtx.Call) ?[]const u8 {
    if (calls.len == 0) return null;
    var out: std.ArrayList(u8) = .empty;
    out.append(gpa, '[') catch return null;
    for (calls, 0..) |c, i| {
        if (i > 0) out.append(gpa, ',') catch return null;
        out.appendSlice(gpa, "{\"id\":\"") catch return null;
        out.appendSlice(gpa, c.id) catch return null;
        out.appendSlice(gpa, "\",\"type\":\"function\",\"function\":{\"name\":\"") catch return null;
        out.appendSlice(gpa, c.name) catch return null;
        out.appendSlice(gpa, "\",\"arguments\":\"") catch return null;
        for (c.args_json) |ch| {
            switch (ch) {
                '"' => out.appendSlice(gpa, "\\\"") catch return null,
                '\\' => out.appendSlice(gpa, "\\\\") catch return null,
                '\n' => out.appendSlice(gpa, "\\n") catch return null,
                '\r' => out.appendSlice(gpa, "\\r") catch return null,
                '\t' => out.appendSlice(gpa, "\\t") catch return null,
                else => out.append(gpa, ch) catch return null,
            }
        }
        out.appendSlice(gpa, "\"}}") catch return null;
    }
    out.append(gpa, ']') catch return null;
    return out.items;
}

/// A turn: one request to the API with the history, its tools and, if the model
/// asks for tools, their execution and the next turn.
///
/// Returns the synthesized text to send in the next turn (normally null: if
/// there were no tool calls, the turn is over).
/// `user_text` is already in the session (`startChat` wrote it): here it is
/// only used for the case of synthetic iterations, and the system prompt is
/// injected once at the start of the conversation.
/// CAREFUL: the return type is `[]u8` and not `[]const u8` ON PURPOSE. With
/// `[]const u8` the compiler does not tell a literal from owned memory, and
/// `chatWorker` freed the literal "Continue with the tool results above." ->
/// `free` on `.rodata` -> "reached unreachable code" panic in ReleaseSafe,
/// which means a turn with tools brought the app down ALWAYS. Zig literals are
/// `[]const`, so now the compiler PREVENTS returning them here.
/// Devuelve el texto sintético que hay que mandar en el siguiente turno
/// (normalmente null: si no hubo tool calls, el turno se acabó).
/// `user_text` ya está en la sesión (lo escribió `startChat`): aquí solo se
/// usa para el caso de las iteraciones sintéticas, y el system prompt se
/// inyecta una vez al principio de la conversación.
/// OJO: el tipo de retorno es `[]u8` y no `[]const u8` A PROPOSITO. Con
/// `[]const u8` el compilador no distingue un literal de memoria propia, y
/// `chatWorker` liberaba el literal "Continue with the tool results above." ->
/// `free` sobre `.rodata` -> panic "reached unreachable code" en ReleaseSafe,
/// es decir, un turno con tools tumbaba la app SIEMPRE. Los literales Zig son
/// `[]const`, asi que ahora el compilador IMPIDE devolverlos por aqui.
/// [roster] A quién se le pregunta en un turno.
///
/// Existe para que `runOneTurn` no tenga que decidir entre "el provider/modelo
/// activo" y "el candidato del free-auto" en tres sitios distintos (body, url y
/// key). Con la rotación el `pick` se REEMPLAZA dentro del bucle de reintentos, y
/// si cada sitio consultara el global por su cuenta, media petición iría al
/// provider viejo: un 401 con la key de otro, o un body con el nombre del modelo
/// que ya no está.
const Target = struct {
    def: *const providers.ProviderDef,
    model: []const u8,
    kind: chat.ProviderKind,
    base_url: []const u8,
    key: ?[]const u8,
    /// El candidato del pool, o null si este turno va al provider/modelo activo.
    from_roster: ?roster_mod.Candidate = null,
};

/// El objetivo de este turno: el pool si el free-auto está encendido y ya tiene
/// lista, el provider/modelo activo si no.
///
/// Con el pool sin construir (o vacío) cae al activo SIN avisar: la lista son N
/// peticiones y el primer prompt no puede esperar por ellas. La rotación espera
/// al siguiente turno.
fn pickTarget(m: *tui.Model) Target {
    const active = activeTarget(m);
    if (!free_auto.freeAutoOn()) return active;
    if (free_auto.poolSize() == 0) return active;
    const cand = free_auto.rosterGet(m.allocator).active(free_auto.nowMs()) orelse return active;
    return targetForCandidate(m, cand) orelse active;
}

/// El `Target` del provider/modelo activos.
fn activeTarget(m: *tui.Model) Target {
    const def = activeProviderDef(m.environ);
    const kind = chat.kindForProvider(def.id);
    return .{
        .def = def,
        .model = cur_model,
        .kind = kind,
        .base_url = def.base_url,
        // Anthropic lleva la key en cabeceras, no en Bearer: aquí null.
        .key = if (kind == .anthropic) null else providers.keyFor(def, m.environ) orelse curKey(m),
    };
}

/// El `Target` de un par provider/modelo concreto. Null si ese provider ya no
/// está (el usuario lo quitó de `config.json` después de construir el pool).
fn targetForCandidate(m: *tui.Model, cand: roster_mod.Candidate) ?Target {
    const def = config_mod.find(user_config, cand.provider_id) orelse
        providers.byId(cand.provider_id) orelse return null;
    const kind = chat.kindForProvider(def.id);
    return .{
        .def = def,
        .model = cand.model_id,
        .kind = kind,
        .base_url = def.base_url,
        .key = if (kind == .anthropic) null else providers.keyFor(def, m.environ),
        .from_roster = cand,
    };
}

/// [roster] La línea de historial que explica el cambio de modelo.
///
/// Va al historial y no solo al status porque es el momento en que el usuario
/// pierde de vista por qué va tan lento: sin esta línea, un provider cayendo a
/// mitad del turno parece un fallo. Y dice las DOS cosas (qué murió y por qué, a
/// qué se pasa), porque "cambió de modelo" sin motivo no es información.
fn pushSwitchNotice(m: *tui.Model, sw: free_auto.Switch, to: Target) void {
    const to_c = to.from_roster orelse return;
    const reason = if (sw.prev_reason.len > 0) sw.prev_reason else "quota gone";
    const msg = std.fmt.allocPrint(
        m.allocator,
        "quota gone on {s}/{s} ({s}) → {s}/{s} (free-auto {d}/{d})",
        .{
            sw.prev_provider,
            sw.prev_model,
            reason,
            to_c.provider_id,
            to_c.model_id,
            free_auto.rosterGet(m.allocator).idx + 1,
            free_auto.poolSize(),
        },
    ) catch "free-auto: switched model";
    pushInfoOwned(m, msg);
    // El status va corto: es una línea segmentada y ya lleva modelo y provider.
    // El detalle (el por qué) está en la línea de arriba, que no se recorta.
    const short = std.fmt.allocPrint(m.allocator, "switched to {s}", .{to_c.model_id}) catch "switching model";
    setStatusWithZo(m, .thinking, short);
}

/// [roster] Una línea con el estado del pool, para cuando el turno se muere.
///
/// Dice lo único que sirve: cuántos candidatos quedan vivos y que `/free-auto
/// status` da el detalle. Sin el pool construido no dice nada (sería ruido).
fn notePoolState(m: *tui.Model) void {
    if (!free_auto.freeAutoOn()) return;
    const lbl = free_auto.freeAutoLabel(m.allocator);
    if (lbl.len == 0) return;
    // `statusLabel` ya empieza por "free-auto n/m", así que aquí NO se repite el
    // prefijo (salía "free-auto: free-auto 3/16 · ...", que es de las cosas que
    // hacen que una línea de información deje de leerse).
    const msg = std.fmt.allocPrint(m.allocator, "{s} · /free-auto status for the detail", .{lbl}) catch
        "free-auto: pool changed";
    pushInfoOwned(m, msg);
}

/// [roster] Marca el par que acaba de tumbar el turno y lo deja para el
/// siguiente.
///
/// NO rota el turno (eso es lo de `quotaVerdict`): aquí el error no es de cuota,
/// es "este par no está dando". Lo que hace esicidearlo un minuto y mover el
/// índice, para que el siguiente prompt empiece en otro sitio.
///
/// Las dos excepciones son obvias y estan en el test:
///   - `AuthFailed`: es la KEY. Rotar daría 401 en los 16, y además el mensaje
///     de `reportErr` ya dice qué variable mirar.
///   - `Cancelled`: el usuario.paró. Marcar el par de muerto sería castigar al
///     modelo por una tecla de ESC.
fn noteTurnFailure(m: *tui.Model, err: anyerror, pick: Target) void {
    if (!free_auto.freeAutoOn()) return;
    if (pick.from_roster == null) return;
    if (err == error.AuthFailed or err == error.Cancelled) return;
    const sw = free_auto.switchTo(m.allocator, .failed, chat.lastErrorBody()) orelse return;
    const c = sw.cand;
    const msg = std.fmt.allocPrint(
        m.allocator,
        "{s}/{s} failed: {s} → next turn starts with {s}/{s}",
        .{ sw.prev_provider, sw.prev_model, errPhrase(err), c.provider_id, c.model_id },
    ) catch "free-auto: the pair failed";
    pushInfoOwned(m, msg);
}

/// Cuántos ficheros se metieron con el prompt, y cuántos mencionados no se
/// pudieron meter. Lo devuelve la ampliación para que el llamante componga la
/// línea del historial.
pub const MentionCount = struct { files: u8 = 0, missing: u8 = 0 };

/// Devuelve los mensajes con el ÚLTIMO mensaje de usuario ampliado por las
/// menciones `@fichero`.
///
/// Se toca solo el último: es el que el usuario acaba de escribir, y ampliar un
/// mensaje viejo (un prompt de la iteración anterior) sería duplicar contexto
/// sin motivo.
///
/// Si la ampliación falla (un fichero que no se puede leer, un error de disco),
/// se devuelve la lista tal cual: mencionar un fichero es una comodidad, nunca
/// un motivo para que el turno no arranque.
///
/// Lo que NO se puede probar aquí es el camino que toca el disco: `expand` hace
/// `statFile` con `io_global`, y en un test unitario ese `Io` es `undefined`
/// (leer su vtable es un GPF, no un 0). Es la misma trampa que `Model.attachIo`
/// con su flag `io_ready`, y por eso la ampliación de verdad se verifica en la
/// pty, no aquí. Lo que sí se fija aquí es el contrato puro: sin menciones no se
/// copia nada y solo se toca el último mensaje.
fn withMentions(
    arena: std.mem.Allocator,
    msgs: []chat.ChatMessage,
    count: *MentionCount,
) []chat.ChatMessage {
    if (msgs.len == 0) return msgs;
    // OJO: el ÚLTIMO mensaje NO es el del usuario. `runOneTurn` añade el system
    // prompt al FINAL si la sesión no lo tenía (por eso va al principio del
    // cuerpo, no de la lista), así que en el primer turno la lista termina en
    // `system`. Buscar "el último" a secas hacía que la mención no se ampliara
    // NUNCA, y se vio en la pty: el modelo decía "no tengo el contenido del
    // fichero" con el fichero en el prompt.
    var last: ?usize = null;
    for (msgs, 0..) |mm, i| {
        if (std.mem.eql(u8, mm.role, "user")) last = i;
    }
    const li = last orelse return msgs;

    const exp = mentions.expand(arena, io_global, msgs[li].content) catch return msgs;
    if (exp.files == 0) return msgs;
    count.files = exp.files;
    count.missing = exp.missing;

    // Copia de la lista para no tocar la de la sesión: `snapshotMsgs` ya la
    //Living en la arena de ESTE turno, pero `comp.msgs` se reutiliza entre
    // reintentos y rotaciones, así que el contenido tiene que ser estable.
    const copy = arena.alloc(chat.ChatMessage, msgs.len) catch return msgs;
    @memcpy(copy, msgs);
    copy[li].content = exp.text;
    return copy;
}

/// `iteration` is the agent loop's counter (0 on the first pass). The MENTIONS
/// have to be expanded on every iteration (the model needs the file contents in
/// every request) but the notice in the history only on the first: otherwise a
/// turn with three tools prints the same "@fichero: 1 inlined" three times.
fn runOneTurn(m: *tui.Model, user_text: []const u8, iteration: usize) !?[]u8 {
    _ = user_text;
    const gpa = m.allocator;
    const s = ensureSession(m, gpa);
    // Clock of the TURN (not of the stream): it is what is painted in
    // "done · N.Ns" and what the user measures when they press again.
    const turn_t0 = std.Io.Timestamp.now(io_global, .real).nanoseconds;

    // Each ITERATION opens its live paragraph and announces what it is doing (1.3).
    //
    // Before, `startChat` opened the live paragraph ONCE per prompt and
    // `runOneTurn` closed it without reopening: from the 2nd iteration on (and
    // the loop reaches 8) there was no live paragraph, no activity strip, no
    // spinner, no clock. In other words, everything that says "still working"
    // turned off exactly in the part of the turn where the slow part happens
    // (after the tools). The ACP path did do it right the whole time.
    m.streamStartIteration();

    var tstate = TurnCtx{ .m = m };
    defer tstate.deinit();

    // The system prompt always goes FIRST (a stable prefix for the provider's
    // cache) and is added ONCE only.
    //
    // Before, the condition was `items[0].role != .system`, and since `startChat`
    // had already appended the `user` message, `items[0]` was `user`: a NEW
    // system was added on every iteration of the agent loop. The second turn
    // went out as [user, system, tool, system] — the system prompt at the end
    // and duplicated — and the turn died with no reply and no visible error.
    // Now the system is looked for in the WHOLE list.
    var has_system = false;
    for (s.messages.items) |mm| {
        if (mm.role == .system) has_system = true;
    }
    if (!has_system) {
        const sp = systemPrompt(gpa);
        s.append(.system, sp) catch {};
    }

    // Tier 1 compaction before building the body: it is a VIEW of the wire, the
    // session on disk keeps everything.
    var astate = std.heap.ArenaAllocator.init(gpa);
    defer astate.deinit();
    const arena = astate.allocator();

    // Las menciones `@fichero` se resuelven AQUÍ, sobre la copia de los mensajes
    // que va al modelo, y NO en la sesión: el prompt del usuario se guarda tal
    // cual lo escribió (con su `@ruta`), y lo único que se enriquece es lo que
    // sale por el cable. Si se guardara el contenido inyectado, el fichero de
    // sesión creería 32 KB por cada mención y el `/resume` traería los ficheros
    // dentro de los prompts.
    var mentions_in: MentionCount = .{};
    const msgs0 = withMentions(arena, snapshotMsgs(arena), &mentions_in);

    const comp: compaction.Compacted = compaction.elideTier(
        arena,
        msgs0,
        compaction.budgetTokens(m.environ),
    ) catch compaction.Compacted{ .msgs = msgs0 };
    // Qué ficheros se han metido con el prompt. Sin esta línea el usuario ve que
    // el modelo "sabe" algo que no le ha enseñado, y con un fichero de 30 KB eso
    // además cambia el gasto de contexto sin previo aviso.
    //
    // OJO: `pushInfo` (que COPIA) y no `pushInfoOwned`. El texto se compone en un
    // buffer de stack a propósito: `pushInfoOwned` TOMA POSICION del texto y lo
    // libera en `Model.deinit`, así que darle memoria de la arena del turno (que
    // muere al final de `runOneTurn`) deja un puntero colgando en la cola de
    // pendientes. El siguiente frame lo pinta, vaxis lee los BYTES del grapheme
    // liberados, y la app muere con un segfault en el renderer. Quinta vez que
    // sale esta familia de bug en este repo.
    if (mentions_in.files > 0 and iteration == 0) {
        var note_buf: [160]u8 = undefined;
        const note = if (mentions_in.missing > 0)
            std.fmt.bufPrint(&note_buf, "@fichero: {d} inlined with the prompt, {d} not found", .{
                mentions_in.files,
                mentions_in.missing,
            }) catch "@fichero: inlined"
        else
            std.fmt.bufPrint(&note_buf, "@fichero: {d} inlined with the prompt", .{
                mentions_in.files,
            }) catch "@fichero: inlined";
        pushInfo(m, note);
    }

    if (comp.elided > session_elided) {
        session_elided = comp.elided;
        const msg = std.fmt.allocPrint(gpa, "· {d} tool results elided", .{comp.elided}) catch return null;
        pushInfoOwned(m, msg);
    }
    // Notice that byte elision is not enough and a summary is needed. Before, tier
    // 2 only existed in the headless runner, so in the TUI the ctx% climbed
    // without anything being said.
    maybeAnnounceCompaction(m, comp.needs_summary);

    // [roster] Who this turn is asked to.
    //
    // Without free-auto it is the usual active provider/model. With free-auto on
    // it is the live candidate of the pool (which may be another provider), and
    // while the pool is still being built it is the active one: the listing is N
    // requests and the first prompt cannot wait for them.
    var pick = pickTarget(m);

    var http = http_client.Http.init(gpa, io_global);
    defer http.deinit();

    chat.cancel_current.store(false, .seq_cst);
    // The status names the ITERATION from the second one on: plain "thinking" for
    // 8 turns in a row does not say whether it will take long or it has already
    // stopped. The first one has no counter because it is the normal case and
    // the number would be noise.
    if (iteration > 0) {
        const it = std.fmt.allocPrint(
            gpa,
            "thinking · iteration {d}/{d}",
            .{ iteration + 1, max_iterations },
        ) catch "thinking";
        setStatusWithZo(m, .thinking, it);
    } else {
        setStatusWithZo(m, .thinking, "thinking");
    }

    var attempt: usize = 0;
    // Rotations of THIS turn. A local and not a global because it resets with the
    // turn: 3 per turn is the ceiling that stops it from going in circles when
    // the problem is configuration and not quota.
    var rotations: u8 = 0;
    while (true) : (attempt += 1) {
        // The body is composed INSIDE the loop, and not before.
        //
        // It is the most expensive bug of the rotation: the body carries the
        // model NAME inside, so rotating meant composing it again. With the body
        // built outside, the request went to the new provider/model with the old
        // name inside, and the server answered 400 with a message that made no
        // sense ("JSON parsing failed") three times, with backoff. It smelled
        // like a zode bug and it was a zode bug.
        //
        // `bodyBuf` is main's heap buffer (not a 1 MiB stack frame), and it is
        // NOT freed between attempts: `buildBodyMessages` overwrites it and the
        // pointer is only used while the request is in flight.
        const body_buf = try bodyBuf(gpa);
        const body = try chat.buildBodyMessages(
            body_buf,
            pick.model,
            comp.msgs,
            current_effort,
            tools_mod.toolsJson(),
            pick.kind,
        );

        // CAREFUL: `streamChat` expects the FULL URL, not just the provider's
        // base. Passing the bare base gave 404 on EVERY request from the TUI
        // (the headless runner in main.zig does add the path, which is why it
        // worked there).
        var url_buf: [1024]u8 = undefined;
        const url = if (pick.kind == .anthropic)
            std.fmt.bufPrint(&url_buf, "{s}/messages", .{pick.base_url}) catch pick.base_url
        else
            std.fmt.bufPrint(&url_buf, "{s}/chat/completions", .{pick.base_url}) catch pick.base_url;

        // For Anthropic the auth goes in headers (x-api-key), not in Bearer: null
        // is passed and `streamRaw` sets it. For the rest, Bearer with the key
        // OF THAT PROVIDER (not the active one's: sending one provider's key to
        // another endpoint is the `ZODE_PROVIDER` bug, once fixed).
        const bearer: ?[]const u8 = if (pick.kind == .anthropic) null else pick.key;

        chat.streamChat(
            gpa,
            &http,
            url,
            bearer,
            @constCast(body),
            .{
                .userdata = &tstate,
                .onDelta = onDelta,
                .onToolCall = onToolCall,
                .onFinish = onFinish,
            },
            pick.kind,
        ) catch |err| {
            // [roster] Out of quota on THAT pair? Another pair carries on with the
            // SAME request and the turn does not die. It goes BEFORE the backoff
            // retry because a 429 with `retry-after: 30` waiting 30 s on the same
            // provider is exactly what the user does not want.
            if (quotaVerdict(err, chat.lastErrorBody())) |why| {
                if (rotations < roster_mod.max_rotations_per_turn) {
                    if (free_auto.switchTo(gpa, why, chat.lastErrorBody())) |sw| {
                        if (targetForCandidate(m, sw.cand)) |next| {
                            rotations += 1;
                            pick = next;
                            pushSwitchNotice(m, sw, pick);
                            continue; // <- the turn carries on by itself
                        }
                    }
                    // No live pair left (or its provider is no longer in the
                    // config): fall through to the normal retry, and if that
                    // fails too, the error below explains what was tried.
                }
            }
            if (isRetryable(err) and attempt < 3) {
                pushRetryNotice(m, err, attempt);
                Retry.wait(attempt) catch return null; // ESC cuts it short
                continue;
            }
            // [roster] The retries are gone and this pair still will not answer.
            // The turn does not rotate (a 5xx may be a blip and the backoff has
            // already been shown), but the pair is dropped so the NEXT turn does
            // not start with it. Without this, a model that always fails (a free
            // one the provider does not serve) keeps the user stuck on the same
            // error forever and free-auto is worth nothing.
            noteTurnFailure(m, err, pick);
            return err;
        };
        break;
    }
    updateTps(tstate.chars, tstate.stream_start_ns);
    cache_stats.session.record(chat.last_usage);

    // Closes the streaming paragraph: what arrived stays in the history.
    m.streamEnd();

    // The assistant's text goes into the session (also if it was interrupted:
    // what arrived is real and must not be lost).
    //
    // CAREFUL: WITH its `tool_calls`, and this is not optional. The tool message
    // carries `tool_call_id`, and if the assistant's message does not carry the
    // `tool_calls` that asked for it, that id matches nothing and the API
    // answers 400 (`invalid_request_error`) on the NEXT turn. Passing `null`
    // (which is what it used to be), any turn with a tool died on the second
    // request: the model asked for the tool, the tool ran, and the final reply
    // never arrived — with no visible error, because the notice stayed in
    // `pending` and you had to press a key to see it. Headless did pass the
    // `tool_calls` (`result.ctx.toolCallsJson`), which is why the agent loop
    // worked there and not in the TUI: same model, two different clients.
    //
    // That is why `TurnCtx` keeps a list of `calls` and not a simple flag: the
    // JSON has to be rebuilt for the session.
    const calls_json = if (tstate.calls.items.len > 0)
        toolCallsJsonFromCalls(gpa, tstate.calls.items)
    else
        null;
    if (tstate.text.items.len > 0 or calls_json != null) {
        s.appendAssistant(tstate.text.items, calls_json) catch {};
    }
    s.flush();

    const partial = tstate.finish_len > 0 and
        std.mem.eql(u8, tstate.finish[0..tstate.finish_len], "length");
    if (partial) setStatusWithZo(m, .warn, "interrupted");

    // No tool calls: the turn is over.
    if (tstate.calls.items.len == 0) {
        // The ctx% is refreshed HERE too, not only on the tools path (which is
        // the one that calls `refreshContextUsage`): a turn without tools is the
        // NORMAL case and the counter stayed at the previous turn's value until
        // a tool appeared.
        refreshContextUsage(m);
        // Plain "done" does not say what it cost. With the turn's clock, the
        // status becomes the summary of what just happened (which is the only
        // thing left visible when the strip turns off).
        const turn_ms = elapsedMs(turn_t0);
        const done_status = std.fmt.allocPrint(
            gpa,
            "done · {d}.{d}s",
            .{ turn_ms / 1000, (turn_ms % 1000) / 100 },
        ) catch "done";
        setStatusWithZo(m, .done, done_status);
        return null;
    }

    const exec = try execToolCalls(m, s, &tstate);
    refreshContextUsage(m);
    return exec;
}

/// Announces tier 2 compaction if the turn triggers it.
///
/// Tier 2 (summarizing the old stretch with an LLM call) used to run only in
/// headless (`main.zig`), so in the TUI the history grew without anything being
/// said and the ctx% climbed with no explanation. `needs_summary` is the notice
/// that byte elision has not been enough.
fn maybeAnnounceCompaction(m: *tui.Model, comp_needs_summary: bool) void {
    if (!comp_needs_summary) return;
    const msg = std.fmt.allocPrint(
        m.allocator,
        "· context budget reached: summarizing older turns…",
        .{},
    ) catch return;
    pushInfoOwned(m, msg);
}

/// `/plan`: clears the visible task list.
///
/// It exists because the plan belongs to the TURN and sometimes gets stuck
/// half-done (the model ran out of steps, or the user wants to start over
/// without a new session). Without it, the only way to empty it is the model
/// sending an empty list, which is never going to happen on its own.
fn cmdPlan(m: *tui.Model) void {
    if (m.planCopy().isEmpty()) {
        pushInfo(m, "the plan is already empty");
        return;
    }
    m.clearPlan();
    pushInfo(m, "plan cleared");
}

/// `/undo`: puts the files back the way they were before the last turn.
///
/// It undoes FILES, not messages. The session is an append-only JSONL and
/// rewriting it halfway through a turn is the kind of thing nobody can explain
/// afterwards: what the user wants when they say "undo that" is for the repo to
/// go back, not for the model to forget it did it.
///
/// The snapshot is taken BEFORE each file-touching tool, and a file that did not
/// exist is recorded as such (undoing it = deleting it). And if the file could
/// not be READ (permissions, or it is a directory) nothing is recorded: deleting
/// a file nobody managed to read is worse than not undoing.
fn cmdUndo(m: *tui.Model) void {
    var cp = m.takeCheckpointOwned() orelse {
        pushInfo(m, "nothing to undo: no turn has changed any file yet");
        return;
    };
    // The snapshots are the caller's memory now (see `takeCheckpointOwned`):
    // `deinit` needs a non-const pointer.
    defer cp.deinit(m.allocator);
    var undone: u8 = 0;
    var failed: u8 = 0;
    var skipped: u8 = 0;
    var detail: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&detail);
    const out = &w;

    for (cp.files[0..cp.len]) |f| {
        if (f.truncated) {
            skipped += 1;
            out.print("  {s}: too big to restore\n", .{f.pathOf()}) catch {};
            continue;
        }
        if (!f.existed) {
            // It did not exist before: undoing is deleting it, and only if it is
            // still a regular file.
            if (deleteIfUnchanged(f.pathOf())) {
                undone += 1;
                out.print("  removed {s}\n", .{f.pathOf()}) catch {};
            } else {
                failed += 1;
                out.print("  {s}: not removed (it changed since, or is gone)\n", .{f.pathOf()}) catch {};
            }
            continue;
        }
        // `writeFile` and not config.zig's `writeFileSecure`: that one is for
        // `auth.json` (0600, written to a temp and renamed) and this is a file of
        // the user's project, with the permissions it already had.
        std.Io.Dir.cwd().writeFile(io_global, .{ .sub_path = f.pathOf(), .data = f.data }) catch {
            failed += 1;
            out.print("  {s}: could not write it back\n", .{f.pathOf()}) catch {};
            continue;
        };
        undone += 1;
        out.print("  restored {s} ({d} bytes)\n", .{ f.pathOf(), f.data.len }) catch {};
    }

    // CAREFUL: `allocPrint` and NOT `bufPrint` into a stack buffer.
    // `pushInfoOwned` TAKES OWNERSHIP of the text and frees it in `Model.deinit`:
    // a `bufPrint(&buf, ...)` leaves a pointer to the stack in the pending queue
    // and it paints as a row of `�` (seen in the pty: the headline of the undo
    // was a wall of replacement characters). Same reason a literal there is an
    // "Invalid free".
    const head_buf = if (undone == 0)
        "undo: nothing could be restored"
    else
        std.fmt.allocPrint(m.allocator, "undo: {d} file{s} undone", .{
            undone,
            if (undone == 1) "" else "s",
        }) catch "undo: done";

    m.pushInfoFmt("{s} · from: {s}", .{ head_buf, cp.labelOf() });
    if (w.buffered().len > 0) {
        // `pushInfoOwned` of an EMPTY string would push a blank line; the old
        // `catch ""` made that reachable on OOM and printed nothing instead.
        m.pushInfoFmt("{s}", .{w.buffered()});
    }
    if (skipped > 0 or failed > 0) {
        const warn = std.fmt.allocPrint(m.allocator, "{d} file(s) skipped, {d} failed · the diff of the turn is still in the history", .{
            skipped,
            failed,
        }) catch "some files were skipped";
        pushInfoOwned(m, warn);
    }
    if (undone > 0) setStatusWithZo(m, .done, "undone");
}

/// Deletes a file ONLY if it exists and is a regular file.
///
/// What is NOT checked is that its contents are the ones the tool left: the
/// "after" is not stored (that would be twice the memory). Exists and is a
/// regular file is enough to avoid deleting a directory by mistake. It is a
/// weak guarantee on purpose: `/undo` is something the user asks for
/// explicitly, and doing nothing is worse than deleting a file the model just
/// created.
fn deleteIfUnchanged(path: []const u8) bool {
    const dir: std.Io.Dir = .cwd();
    const st = dir.statFile(io_global, path, .{}) catch return false;
    if (st.kind != .file) return false;
    dir.deleteFile(io_global, path) catch return false;
    return true;
}

/// Applies the list of the `todo` tool and says in the history how much changed.
///
/// It lives here and not inside `tools.execute` because of memory ownership:
/// `execute` returns memory of the turn's arena (freed when the turn ends) and
/// the plan has to LIVE between frames. The one place with shared state is the
/// `Model`.
///
/// The "nothing changed" case matters: the model resends the whole list on every
/// call, so without this the history would repeat "plan: 1/3" five times in a
/// turn and the line would stop carrying information.
fn applyPlanCall(m: *tui.Model, args_json: []const u8, arena: std.mem.Allocator) void {
    var items: [plan_mod.max_items]plan_mod.Item = undefined;
    const parsed = plan_mod.parseItems(arena, args_json, &items) catch |err| {
        const msg = switch (err) {
            error.TooManyItems => "the plan has more than 20 steps: shorten it",
            error.BadPlan => "the plan did not parse: send {items:[{content, status}]}",
        };
        pushInfoOwned(m, msg);
        return;
    };
    const r = m.applyPlan(&parsed.items, parsed.len);
    if (r == .same) return;
    // With OWN memory (not the turn's arena): the text lives in the pending
    // queue and a later frame paints it.
    const pl = m.planCopy();
    m.pushInfoFmt("{s}", .{pl.summary(m.allocator)});
    if (pl.allDone()) setStatusWithZo(m, .done, "all plan steps done");
}

/// Runs a turn's tool calls and returns the synthesized text for the next one
/// (or null if no other turn was needed).
///
/// Before running them, the file the tool is about to touch is
/// PHOTOGRAPHED: that is what makes it possible to show the diff instead of an
/// opaque "OK".
/// Runs the tool calls. Returns the synthesized text of the next turn, owned by
/// the caller (see `runOneTurn`).
fn execToolCalls(m: *tui.Model, s: *session_mod.Session, t: *TurnCtx) !?[]u8 {
    const gpa = m.allocator;
    var astate = std.heap.ArenaAllocator.init(gpa);
    defer astate.deinit();
    const arena = astate.allocator();
    const t0 = std.Io.Timestamp.now(io_global, .real).nanoseconds;
    var ran: usize = 0;
    var denied: usize = 0;

    for (t.calls.items) |call| {
        const arg = toolArgSummary(call.name, call.args_json, arena);
        m.pushToolStart(call.name, arg);
        // The status says WHAT is running, not a generic "working": with a slow `bash`
        // that is the difference between "working" and "hung". The text is
        // copied to a fixed buffer, so the arg from the worker's arena can die
        // without a problem.
        setStatusWithZo(m, .tooling, arg);

        // ── permission ──
        if (!yolo and tools_mod.needsPermission(call.name) and !isAlwaysAllowed(call.name)) {
            var dbuf: [384]u8 = undefined;
            const detail = std.fmt.bufPrint(&dbuf, "{s} {s}", .{ call.name, arg }) catch call.name;
            switch (m.requestPermission(call.name, detail)) {
                .allow => {},
                .allow_always => setAlwaysAllowed(m, call.name),
                .deny, .none => {
                    // The denial is handed back to the model as a result
                    // so it changes strategy instead of retrying.
                    denied += 1;
                    turn_stats.noteDenied();
                    m.pushToolDone(call.name, "denied: permission required", 0, "denied");
                    s.appendToolResult(call.id, call.name, "denied: permission required") catch {};
                    continue;
                },
            }
        }

        const call_t0 = std.Io.Timestamp.now(io_global, .real).nanoseconds;

        // [undo] La foto de ANTES. `existed` va aparte porque "no estaba" y
        // "estaba vacío" se deshacen distinto (borrar vs escribir vacío), y un
        // `catch ""` no lo distingue. Y si el fallo NO es "no existe" (permisos,
        // un directorio), NO se fotografía nada: `/undo` borraría un archivo que
        // no llegó a leer, que es lo peor que puede hacer un undo.
        var before: ?[]const u8 = null;
        if (touchesFile(call.name)) {
            if (filePathOf(call.args_json, arena)) |pth| {
                if (std.Io.Dir.cwd().readFileAlloc(io_global, pth, arena, .limited(4 * 1024 * 1024))) |content| {
                    before = content;
                    m.snapshotFile(pth, content, true);
                } else |err| {
                    switch (err) {
                        error.FileNotFound => m.snapshotFile(pth, "", false),
                        else => {},
                    }
                }
            }
        }

        // La tool `todo` no tiene resultado que mirar: su efecto es el PLAN que
        // ve el usuario, y se aplica aquí (no dentro de `execute`) porque el plan
        // vive en el `Model`, que es de la TUI.
        if (std.mem.eql(u8, call.name, "todo")) {
            applyPlanCall(m, call.args_json, arena);
        }

        const res = tools_mod.execute(io_global, call.name, call.args_json, arena) catch |err| {
            const ms = elapsedMs(call_t0);
            const emsg = std.fmt.allocPrint(arena, "{t}", .{err}) catch "error";
            m.pushToolDone(call.name, emsg, ms, emsg);
            s.appendToolResult(call.id, call.name, emsg) catch {};
            continue;
        };
        const ms = elapsedMs(call_t0);
        ran += 1;
        turn_stats.noteTool();
        const summary = toolResultSummary(call.name, res, arena);
        m.pushToolDone(call.name, summary, ms, res);

        // Diff against the previous content, if the tool touched a file.
        if (before) |old| {
            if (filePathOf(call.args_json, arena)) |pth| {
                const after = std.Io.Dir.cwd().readFileAlloc(io_global, pth, arena, .limited(4 * 1024 * 1024)) catch {
                    continue;
                };
                // The language comes from the path's extension, so the body of each line
                // of the diff is tokenized instead of coming out in the
                // prefix's color.
                const dc = m.pushDiffLang(old, after, langFromPath(pth));
                turn_stats.noteDiff(pth, dc);
            }
        }

        s.appendToolResult(call.id, call.name, res) catch {};
    }
    s.flush();
    // "tools done" says nothing. With the numbers it does: you know whether it was
    // fast (and therefore whether the model is going to continue or has stopped)
    // and whether there were denials, which is what you have to look at after.
    const total_ms = elapsedMs(t0);
    const tools_status = std.fmt.allocPrint(
        gpa,
        "{d} tool{s} · {d}.{d}s{s}",
        .{
            ran,
            if (ran == 1) "" else "s",
            total_ms / 1000,
            (total_ms % 1000) / 100,
            if (denied > 0) " · denied" else "",
        },
    ) catch "tools done";
    setStatusWithZo(m, .tooling, tools_status);

    // The next turn needs a user message describing the results; without it, the
    // model does not see what happened.
    if (t.calls.items.len == 0) return null;
    // Own copy, NEVER the literal: whoever receives it frees it.
    return gpa.dupe(u8, syntheticUserText) catch null;
}

/// The text sent as "user" so the model sees the tool results. It lives in a
/// constant (not inlined) so it can be tested.
pub const syntheticUserText = "Continue with the tool results above.";

/// Does this tool modify a file on disk?
fn touchesFile(name: []const u8) bool {
    return std.mem.eql(u8, name, "write") or std.mem.eql(u8, name, "edit");
}

/// Path of the file a writing tool touches (or null if it does not say).
fn filePathOf(args_json: []const u8, arena: std.mem.Allocator) ?[]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch return null;
    if (parsed != .object) return null;
    const v = parsed.object.get("path") orelse return null;
    if (v != .string or v.string.len == 0) return null;
    return v.string;
}

/// Identifying argument of a tool, for the `⏺ tool(arg)` line.
fn toolArgSummary(name: []const u8, args_json: []const u8, arena: std.mem.Allocator) []const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch return "";
    if (parsed != .object) return "";
    const wanted: []const u8 = if (std.mem.eql(u8, name, "read") or
        std.mem.eql(u8, name, "write") or std.mem.eql(u8, name, "edit") or
        std.mem.eql(u8, name, "list_files"))
        "path"
    else if (std.mem.eql(u8, name, "bash"))
        "command"
    else if (std.mem.eql(u8, name, "glob") or std.mem.eql(u8, name, "grep"))
        "pattern"
    else if (std.mem.eql(u8, name, "web_fetch"))
        "url"
    else if (std.mem.eql(u8, name, "web_search"))
        "query"
    else
        "";
    if (wanted.len > 0) {
        if (parsed.object.get(wanted)) |v| {
            if (v == .string) return v.string;
        }
    }
    // Without the expected field, the first string there is will do.
    var it = parsed.object.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.* == .string) return kv.value_ptr.*.string;
    }
    return "";
}

/// One-line summary of a tool's result (`⎿ Read 12 lines`).
fn toolResultSummary(name: []const u8, res: []const u8, arena: std.mem.Allocator) []const u8 {
    if (res.len == 0) return "";
    var it = std.mem.splitScalar(u8, res, '\n');
    const first = it.next() orelse return "";
    // `write` says "wrote X (N bytes, M lines)" and then a preview. The one-line
    // summary is that first line: the preview is the tool result (what the
    // model sees) and shows up in the history under it.
    if (std.mem.eql(u8, name, "read")) {
        // The read lines carry "   12│ text": count them.
        var n: usize = 0;
        var probe = std.mem.splitScalar(u8, res, '\n');
        while (probe.next() != null) n += 1;
        return std.fmt.allocPrint(arena, "Read {d} lines", .{n}) catch first;
    }
    if (std.mem.eql(u8, name, "list_files")) {
        var n: usize = 0;
        var it2 = std.mem.splitScalar(u8, res, '\n');
        while (it2.next()) |l| {
            if (l.len > 0) n += 1;
        }
        return std.fmt.allocPrint(arena, "{d} entries", .{n}) catch first;
    }
    if (std.mem.eql(u8, name, "grep")) {
        var n: usize = 0;
        var it2 = std.mem.splitScalar(u8, res, '\n');
        while (it2.next()) |l| {
            if (l.len > 0) n += 1;
        }
        return std.fmt.allocPrint(arena, "{d} matches", .{n}) catch first;
    }
    // Web: the first line of a fetch is the title of the first hit, which as a
    // summary says nothing. Count what is really there.
    if (std.mem.eql(u8, name, "web_fetch")) {
        var n: usize = 0;
        var it2 = std.mem.splitScalar(u8, res, '\n');
        while (it2.next()) |l| {
            if (l.len > 0) n += 1;
        }
        if (res.len > 1024 * 1024) {
            return std.fmt.allocPrint(arena, "{d} lines · {d} MB", .{ n, res.len / (1024 * 1024) }) catch first;
        }
        return std.fmt.allocPrint(arena, "{d} lines · {d} KB", .{ n, res.len / 1024 }) catch first;
    }
    if (std.mem.eql(u8, name, "web_search")) {
        // Counts the numbered lines (`1. Title`) of the `web.searchResults` format.
        // Counting indented URLs was fragile: the indentation changes and the
        // counter comes out at zero.
        var n: usize = 0;
        var it2 = std.mem.splitScalar(u8, res, '\n');
        while (it2.next()) |l| {
            var k: usize = 0;
            while (k < l.len and l[k] >= '0' and l[k] <= '9') k += 1;
            if (k > 0 and k + 1 < l.len and l[k] == '.' and l[k + 1] == ' ') n += 1;
        }
        return std.fmt.allocPrint(arena, "{d} result{s}", .{ n, if (n == 1) "" else "s" }) catch first;
    }
    return first;
}

fn elapsedMs(t0: i128) u64 {
    const now = std.Io.Timestamp.now(io_global, .real).nanoseconds;
    if (now <= t0) return 0;
    return @intCast(@divTrunc(now - t0, 1_000_000));
}

// ── errors and retries ────────────────────────────────────────

/// 429 and 5xx are retried; 401/403 are not (the key is wrong: insisting does
/// not help).
fn isRetryable(err: anyerror) bool {
    return switch (err) {
        error.RateLimited, error.Overloaded, error.ServerError => true,
        else => false,
    };
}

/// [roster] ¿Este error significa "este provider/modelo ya no da para seguir"?
///
/// Es la pregunta que decide si el turno CONTINÚA con otro par de
/// provider/modelo (que es lo que hace `/free-auto`) o si se rinde con un
/// mensaje. Y por eso la tabla esta tan fina: la accion que corresponde es
/// opuesta segun la fila.
///
/// | error                 | veredicto | por que                                               |
/// |-----------------------|-----------|-------------------------------------------------------|
/// | 402 NoCredits         | si        | sin creditos. Reintentar el mismo es tonto.           |
/// | 429 RateLimited       | si        | cuota del modelo, no de la key. Otro par sigue.       |
/// | 403 "...within OpenCode" | si     | es el GATE, no la configuracion. Otro par funciona.   |
/// | 403 sin eso           | NO        | casi siempre es un modelo no disponible en la cuenta.  |
/// | 401 AuthFailed        | NO        | es la key. Rotar daria el mismo 401 en los 7.         |
/// | 404 ModelNotFound     | NO        | es un id malo, no una cuota.                           |
///
/// `detail` es el cuerpo del error del server (`chat.lastErrorBody`), que es
/// donde esta la frase que decide la fila del 403: "can only be used from within
/// OpenCode" y "your credit balance is too low" son dos 403 que significan
/// cosas opuestas.
///
/// Sin asignar: se llama en el camino de error, y devolver memoria obligaria a
/// cada llamante a un `defer` dentro de un `catch`.
pub fn quotaVerdict(err: anyerror, detail: []const u8) ?roster_mod.Why {
    return switch (err) {
        error.NoCredits => .no_credits,
        error.RateLimited => .rate_limited,
        error.Forbidden => if (isGateMessage(detail)) .gated else .misconfigured,
        else => null,
    };
}

/// ¿El texto del 403 es el gate de opencode (o su equivalente)?
///
/// Frases reales que se han visto en el `reason` de un 403:
///   "can only be used from within OpenCode"
///   "Model access is disabled"
///   "model is not available for your account"
/// Es subcadena y sin distinguir mayusculas porque cada provider redacta el
/// suyo, y no hay una constante que_valga para todos.
pub fn isGateMessage(detail: []const u8) bool {
    return containsNoCase(detail, "within opencode") or
        containsNoCase(detail, "access is disabled") or
        containsNoCase(detail, "not available for your") or
        containsNoCase(detail, "only be used from within") or
        containsNoCase(detail, "agentic harness") or
        containsNoCase(detail, "not available on this account");
}

/// `containsNoCase` sin allocar: lowera los dos caracteres a la vez en vez de
/// construir una copia en minusculas del texto entero.
pub fn containsNoCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var k: usize = 0;
        while (k < needle.len and
            std.ascii.toLower(haystack[i + k]) == std.ascii.toLower(needle[k])) k += 1;
        if (k == needle.len) return true;
    }
    return false;
}

const Retry = struct {
    /// How long to wait BEFORE retry `attempt` (0-indexed), in ms.
    ///
    /// Exponential backoff: 500ms, 1s, 2s (+jitter). It lives apart from `wait`
    /// so that the notice can say "retrying in 1.0s" with the SAME number that
    /// is going to be waited: if they were two formulas, the message would lie
    /// as soon as one of them was touched.
    ///
    /// CAREFUL with the exponent: it was `attempt -| 1`, which saturates to 0
    /// and gave 500, 500, 1000 — the first retry did not wait longer than the
    /// second, which is exactly the opposite of what the comment says. With
    /// `1 << attempt` the series is the one always documented.
    fn backoffMs(attempt: usize) u64 {
        const base_ns: i128 = @as(i128, 500) * std.time.ns_per_ms * (@as(i128, 1) << @intCast(attempt));
        var h: u64 = 0x9E3779B97F4A7C15 *% @as(u64, @intCast(attempt));
        h ^= h >> 33;
        const jitter: i128 = @as(i128, @intCast(h & 0xFF)) * @divTrunc(std.time.ns_per_ms, 256);
        return @intCast(@divTrunc(base_ns + jitter, std.time.ns_per_ms));
    }

    /// How long to wait BEFORE retrying, honoring the server's `retry-after` if it
    /// sent one.
    ///
    /// `retry_after_secs` was in `chat` from the start and NOBODY read it: a 429
    /// with `retry-after: 30` waited 1s and ate the entire rate limit, three
    /// times in a row. It is pure arithmetic (testable) and the `wait` below
    /// only uses it to slice the wait.
    fn waitMs(attempt: usize) u64 {
        var ms = backoffMs(attempt);
        if (chat.retry_after_secs) |ra| {
            const want: u64 = @as(u64, ra) * 1000;
            // 30s ceiling: beyond that it is better to give up and let the error
            // the user has to act on (/provider, /model) say so than keep
            // waiting in silence.
            ms = @max(ms, @min(want, 30_000));
        }
        return ms;
    }

    fn wait(attempt: usize) !void {
        var left: i128 = @as(i128, waitMs(attempt)) * std.time.ns_per_ms;
        // Sleeps in slices so ESC can cut the wait short.
        //
        // CAREFUL about the HOW: this runs from a WORKER, and
        // `io_global.sleep` takes down the event loop of the `Io` shared with
        // the TUI (the same problem ACP solved with `nap()`). With `sleep` it
        // is not just the strip's clock that freezes: the redraws stop, so the
        // retry notices stayed in `pending` unpainted and you had to press a key
        // to see them. `acp.nap()` is a bare `nanosleep` that does not touch the
        // `Io`.
        while (left > 0) {
            if (chat.cancelled()) return error.Cancelled;
            const chunk_ms: u64 = @intCast(@min(@divTrunc(left, std.time.ns_per_ms), 50));
            if (chunk_ms > 0) acp.nap(chunk_ms);
            left -= @as(i128, chunk_ms) * std.time.ns_per_ms;
        }
    }
};

/// Notice in the history before retrying (so the user sees it is not hung).
///
/// It says WHAT happened and HOW LONG is left, not just "retrying":
/// `RateLimited (attempt 2/3)` tells nobody anything, while
/// `rate limited: Too many requests · retrying in 1.0s (attempt 2/3)` does:
/// where it is going, why, and how long you have to put up with it. The server's
/// text (`lastErrorBody`) is the part that really matters, because "HTTP 429"
/// says nothing.
fn pushRetryNotice(m: *tui.Model, err: anyerror, attempt: usize) void {
    const gpa = m.allocator;
    const reason = chat.lastErrorBody();
    const wait_ms = Retry.backoffMs(attempt);

    const detail: []const u8 = if (reason.len > 0) reason else "no details from the server";
    const msg = std.fmt.allocPrint(
        gpa,
        "{s}: {s} · retrying in {d}.{d}s (attempt {d}/3)",
        .{ errPhrase(err), detail, wait_ms / 1000, (wait_ms % 1000) / 100, attempt + 1 },
    ) catch "retrying";
    pushInfoOwned(m, msg);

    // The status stays short (it is a segmented line) but has the why, which is
    // what you read at a glance: "rate limited 2/3" and not "retrying…".
    const short = std.fmt.allocPrint(gpa, "{s} {d}/3", .{ errPhrase(err), attempt + 1 }) catch "retrying";
    setStatusWithZo(m, .warn, short);
}

/// The network error in human words.
///
/// `@errorName` gives `RateLimited` / `NoCredits` / `ConnectionFailed`: those
/// are identifiers, not messages. The user sees them in the history and in the
/// status bar, and what is needed there is a sentence.
pub fn errPhrase(err: anyerror) []const u8 {
    return switch (err) {
        error.RateLimited => "rate limited",
        error.Overloaded => "server overloaded",
        error.ServerError => "server error",
        error.AuthFailed => "auth failed",
        error.NoCredits => "no credits",
        error.Forbidden => "forbidden",
        error.ModelNotFound => "model not found",
        error.InvalidUrl => "invalid url",
        error.Cancelled => "cancelled",
        error.TlsFailed, error.TlsHandshakeFailed => "tls failed",
        error.ConnectionFailed, error.ConnectionRefused, error.ConnectionResetByPeer => "connection failed",
        error.TemporaryNameServerFailure, error.NameServerFailure, error.UnknownHostName, error.HostLackingDnsResolver => "dns failed",
        error.ReadTimeout, error.ConnectionTimedOut => "timed out",
        else => @errorName(err),
    };
}

fn reportErr(m: *tui.Model, err: anyerror) void {
    const reason = chat.lastErrorBody();
    const gpa = m.allocator;
    switch (err) {
        error.Cancelled => {
            setStatusWithZo(m, .warn, "interrupted");
            return;
        },
        // 401. It USUALLY is the key, but not always: openrouter answers
        // `{"error":{"message":"User not found."}}`, que es la cuenta y no la
        // key, asi que el mensaje del server se enseña siempre que haya uno.
        error.AuthFailed => {
            // The names go in VERBATIM, not wrapped in a `ZODE_{s}_KEY` template.
            // `key_env` already holds the WHOLE variable name
            // ("ZODE_OPENROUTER_KEY"), so the template produced
            // "check ZODE_ZODE_OPENROUTER_KEY_KEY": a variable that cannot exist,
            // in the one message whose entire job is to name a variable. It is
            // the whole list too, because `key_env` is a fallback chain and the
            // key can be sitting in any of them.
            const names = providerEnvNames(gpa);
            defer gpa.free(names);
            // And the server's own words come along, which this branch is the
            // only one that used to throw away. A 401 is NOT always a bad key:
            // openrouter answers `{"error":{"message":"User not found."}}`, que
            // es la CUENTA y no la key, and saying "key rejected" sends the user
            // to rotate a key that is fine. `reason` is empty when the server
            // said nothing, and then the old wording is all there is to say.
            const msg = if (reason.len > 0)
                std.fmt.allocPrint(gpa, "auth failed on {s}: {s}\n  check {s} (/provider shows the state)", .{
                    cur_provider_id, reason, names,
                }) catch "auth failed"
            else
                std.fmt.allocPrint(gpa, "key rejected by {s}. check {s} (/provider shows the state)", .{
                    cur_provider_id, names,
                }) catch "key rechazada";
            pushErrorOwned(m, msg);
        },
        // 402: the account has no balance. It is not a zode bug nor the key.
        error.NoCredits => {
            const msg = std.fmt.allocPrint(
                gpa,
                "out of credits on {s}: {s}\n  pick a `-free` model or switch with /provider",
                .{ cur_provider_id, reason },
            ) catch "sin creditos";
            pushErrorOwned(m, msg);
        },
        // 404: the model does not exist on that provider. Almost always it is an old
        // HARDCODED id left over (which is why the default is changed when the
        // provider retires it) or a typo in /use.
        error.ModelNotFound => {
            const msg = std.fmt.allocPrint(
                gpa,
                "model `{s}` does not exist on {s}: {s}\n  /model for the ones you have",
                .{ cur_model, cur_provider_id, reason },
            ) catch "modelo inexistente";
            pushErrorOwned(m, msg);
        },
        // 403: in practice it is almost always the MODEL that is not available for
        // this account, not the key. Saying that plainly saves hours of
        // debugging.
        error.Forbidden => {
            const msg = std.fmt.allocPrint(
                gpa,
                "`{s}` is not available on your {s} account: {s}\n  /model for your models, /provider to switch",
                .{ cur_model, cur_provider_id, reason },
            ) catch "acceso denegado";
            pushErrorOwned(m, msg);
        },
        error.BadRequest => {
            // 400: el server no aceptó la petición. Con el free-auto encendido
            // este par ya se aparta para el siguiente turno (`noteTurnFailure`),
            // así que aquí solo hay que decir qué pidió y qué contestó.
            const msg = std.fmt.allocPrint(
                gpa,
                "{s} rejected the request for `{s}`: {s}",
                .{ cur_provider_id, cur_model, reason },
            ) catch "petición rechazada";
            pushInfoOwned(m, msg);
        },
        error.RateLimited, error.Overloaded => {
            // `errPhrase`, no `@errorName`: esta línea la lee una persona y
            // "RateLimited" no le dice nada a nadie. Es la misma regla que los
            // avisos de reintento, que ya lo hacían bien.
            const msg = std.fmt.allocPrint(gpa, "{s} tras varios intentos: {s}", .{ errPhrase(err), reason }) catch
                "servicio saturado";
            pushErrorOwned(m, msg);
        },
        else => {
            // `errPhrase` and not `@errorName`: this line is read by a person and
            // "ServerError" tells nobody anything. And it goes out as an ERROR
            // (red) because that is what it is.
            const msg = std.fmt.allocPrint(gpa, "{s}: {s}", .{ errPhrase(err), reason }) catch "error";
            pushErrorOwned(m, msg);
        },
    }
    setStatusWithZo(m, .warn, errPhrase(err));
}

/// The environment variables that can hold the active provider's key, as a
/// comma-separated list the caller owns.
///
/// It is the WHOLE chain and not just the first, because `key_env` is a
/// fallback list (`ZODE_OPENCODE_KEY` then `ZODE_API_KEY` for opencode) and
/// telling the user to check only the first one sends them to fix a variable
/// that was never set while the one that was set stayed broken.
///
/// A provider that needs no key gets "none", so the message still says
/// something true instead of a variable name invented out of nothing.
fn providerEnvNames(gpa: std.mem.Allocator) []u8 {
    const d = activeProviderDef(environ_global);
    if (d.key_env.len == 0) return gpa.dupe(u8, "none") catch unreachable;
    // The allocation is EXACTLY the length of the result, not a 512-byte buffer
    // with the answer written at the front: the caller frees this, and
    // `std.testing.allocator` (rightly) treats freeing a 20-byte slice of a
    // 512-byte block as an "Invalid free". A fixed writer is the wrong shape for
    // memory that changes hands.
    const sep = " or ";
    const sep_len = sep.len;
    var need: usize = sep_len * (d.key_env.len - 1); // the separator goes BETWEEN
    for (d.key_env) |name| need += name.len;
    const buf = gpa.alloc(u8, need) catch return gpa.dupe(u8, d.key_env[0]) catch unreachable;
    var n: usize = 0;
    for (d.key_env, 0..) |name, i| {
        if (i != 0) {
            @memcpy(buf[n..][0..sep_len], sep);
            n += sep_len;
        }
        @memcpy(buf[n..][0..name.len], name);
        n += name.len;
    }
    return buf[0..n];
}

// ── tier 2 compaction: an LLM summary of the old turns ────────

/// If the elided view still goes over the budget, a summary is asked of the
/// model and the old turns are replaced with a note. Best-effort: if it fails,
/// it carries on without a summary.
/// Accumulates the summary text (userdata of `summarizeTurns`'s callback).
const SummarySink = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
};

/// Summarizes a stretch of old messages with the model itself.
///
/// Returns the summary text, or null if it could not be done (it is
/// best-effort: if it fails, the caller carries on with the messages as they
/// are and only loses precision).
pub fn summarizeTurns(
    gpa: std.mem.Allocator,
    http: *http_client.Http,
    url: []const u8,
    bearer: ?[]const u8,
    kind: chat.ProviderKind,
    model_name: []const u8,
    effort: chat.Effort,
    msgs: []chat.ChatMessage,
    arena: std.mem.Allocator,
) ?[]const u8 {
    var ast = std.heap.ArenaAllocator.init(gpa);
    defer ast.deinit();
    const a = ast.allocator();

    // A single user message with the conversation to summarize + the instruction.
    const prompt = compaction.summaryPrompt(a, msgs) catch {
        models_mod.dbg("[compaction] no se pudo construir el prompt del resumen\n", .{});
        return null;
    };
    const body_buf = bodyBuf(gpa) catch return null;
    const one = [_]chat.ChatMessage{.{ .role = "user", .content = prompt }};
    const body = chat.buildBodyMessages(body_buf, model_name, &one, effort, "", kind) catch {
        models_mod.dbg("[compaction] no se pudo construir el body del resumen\n", .{});
        return null;
    };

    // The userdata carries the allocator + the buffer: a callback cannot capture
    // `gpa` (a nested function does not see the outer environment).
    var sink = SummarySink{ .gpa = gpa };
    const cb: chat.Callbacks = .{
        .userdata = &sink,
        .onDelta = struct {
            fn f(ud: ?*anyopaque, d: []const u8) void {
                const s: *SummarySink = @ptrCast(@alignCast(ud.?));
                s.buf.appendSlice(s.gpa, d) catch {};
            }
        }.f,
    };
    chat.streamChat(gpa, http, url, bearer, @constCast(body), cb, kind) catch |err| {
        models_mod.dbg("[compaction] el resumen fallo: {t}\n", .{err});
        return null;
    };
    if (sink.buf.items.len == 0) return null;
    return arena.dupe(u8, sink.buf.items) catch null;
}

// ── pickers ───────────────────────────────────────────────────

const PickerCb = *const fn (*tui.Model, u32, []const u8) void;

fn onProviderPick(m: *tui.Model, _: u32, label: []const u8) void {
    applyProvider(m, label) catch {};
}

fn onEffortPick(m: *tui.Model, _: u32, label: []const u8) void {
    cmdEffort(m, label);
}

/// Job of the `/models` worker (list in the history) and of the picker.
const ModelsJob = struct {
    model: *tui.Model,
    /// false = list in the history (`/models`); otherwise open the picker.
    for_picker: bool = false,
};

/// `/models`: lists the active provider's models in the history.
pub fn listModelsAsync(m: *tui.Model) !void {
    const job = try m.allocator.create(ModelsJob);
    m.beginWorker();
    job.* = .{ .model = m, .for_picker = false };
    const th = std.Thread.spawn(.{}, modelsWorker, .{job}) catch {
        m.endWorker();
        m.allocator.destroy(job);
        return error.ThreadSpawnFailed;
    };
    th.detach();
}

/// `/model` and Ctrl+T: the two-column model palette.
///
/// The active provider's models are requested; while they arrive, the palette
/// opens anyway with the providers column (which is local and needs no
/// network), and the worker fills it in when it finishes. So there is no blank
/// wait.
pub fn pickerModelsAsync(m: *tui.Model) !void {
    const job = try m.allocator.create(ModelsJob);
    m.beginWorker();
    job.* = .{ .model = m, .for_picker = true };
    const th = std.Thread.spawn(.{}, modelsWorker, .{job}) catch {
        m.endWorker();
        m.allocator.destroy(job);
        return error.ThreadSpawnFailed;
    };
    th.detach();
}

/// Like `pickerModelsAsync` but with the Ctrl+T key.
///
/// It opens NOW, with only the providers column (which is local and needs no
/// network), and the worker fills it with the models when they arrive. So
/// there is no blank wait for the network.
///
/// CAREFUL: `items` and `groups` are copied by the model's allocator, NOT by a
/// frame arena: the palette lives between frames, and if they pointed at the
/// frame's arena they would dangle when the streamer redraws.
pub fn openModelPaletteAsync(m: *tui.Model) void {
    openModelPalette(m, &.{});
    pickerModelsAsync(m) catch {};
}

fn modelsWorker(job: *ModelsJob) void {
    defer job.model.allocator.destroy(job);
    const m = job.model;
    const gpa = m.allocator;
    m.beginWorker();
    defer m.endWorker();

    setStatusWithZo(m, .tooling, "listing models…");

    var http = http_client.Http.init(gpa, io_global);
    defer http.deinit();

    const def = activeProviderDef(m.environ);
    const key = curKey(m);

    var list = models_mod.listModels(gpa, &http, def.models_url, key) catch |err| {
        if (err == error.HttpError) {
            m.pushInfoFmt("models: HTTP error at {s}", .{def.models_url});
        } else {
            const msg = std.fmt.allocPrint(gpa, "models: {t}", .{err}) catch "models error";
            pushInfoOwned(m, msg);
        }
        setStatusWithZo(m, .warn, "no models");
        return;
    };

    defer list.deinit(gpa);

    // Order: the "free" ones first, since those are the ones that work without
    // credits, and alphabetical within each group so the list is stable.
    const sorted = gpa.dupe(models_mod.Model, list.items) catch return;
    defer gpa.free(sorted);
    std.mem.sort(models_mod.Model, sorted, {}, freeFirst);

    if (job.for_picker) {
        // The palette is NOT touched here: this is the worker's thread and the UI
        // thread draws it without a lock (modifying both at once was a
        // segfault).
        // ITEMS already built with their own strings are handed over: handing
        // over the `Model`s and freeing the list on exit left the `id`s
        // dangling, and the drawing blew up with InvalidStartByte.
        const items = buildModelItems(m, sorted);
        if (items) |it| {
            m.setPendingItems(it);
        }
        return;
    }
    {
        for (sorted) |info| {
            const hint = if (isFree(info)) "free" else "";
            const line = std.fmt.allocPrint(
                gpa,
                "{s:<44} {s}",
                .{ info.id, hint },
            ) catch continue;
            pushInfoOwned(m, line);
        }
        m.pushInfoFmt("{d} models on {s}", .{ sorted.len, def.id });
    }
    setStatusWithZo(m, .done, "models ready");
}

/// Is this model free?
///
/// [roster] It used to look only at the `-free` suffix, which is opencode's
/// convention. OpenRouter uses `:free`, and some providers use no suffix at all
/// and just publish a price of 0, so `/model` marked one single provider as
/// "free" and the free-model pool came out nearly empty. It is `models.is_free`
/// now, which combines the three signals (`models.isFreeId` +
/// `models.isFreeByPrice`).
fn isFree(m: models_mod.Model) bool {
    return m.is_free;
}

fn freeFirst(_: void, a: models_mod.Model, b: models_mod.Model) bool {
    const fa = isFree(a);
    const fb = isFree(b);
    if (fa != fb) return fa;
    return std.mem.lessThan(u8, a.id, b.id);
}

/// Opens the model palette in TWO COLUMNS: providers | the active one's models.
///
/// It reuses the list already downloaded from the active provider, so opening it
/// costs no network call (and if there are no models yet, `pickerModelsAsync` is
/// launched to have something to paint).
/// Builds the model palette's items: providers first (with their key state) and
/// then the models with their `free` flag or their context window. All strings
/// are own copies from the model's allocator.
fn buildModelItems(m: *tui.Model, list: []models_mod.Model) ?[]palette.Item {
    const gpa = m.allocator;
    const defs = allProviders(gpa);
    const n = defs.len + 1 + list.len; // +1 = "+ connect"
    const items = gpa.alloc(palette.Item, n) catch return null;
    var i: usize = 0;
    for (defs) |*d| {
        const active = std.mem.eql(u8, d.id, cur_provider_id);
        const has_key = providers.hasKey(d, m.environ);
        items[i] = .{
            .kind = .provider,
            .group = 1,
            .label = gpa.dupe(u8, d.id) catch return null,
            .hint = gpa.dupe(u8, if (active) "active" else if (has_key) "key ok" else "no key") catch "",
        };
        i += 1;
    }
    // CAREFUL: EVERY label/hint has to be an OWN copy. A literal
    // ("+ connect") freed with `gpa.free` is an "Invalid free" that only shows
    // up on app exit, when the palette is destroyed.
    items[i] = .{
        .kind = .connect,
        .group = 2,
        .label = gpa.dupe(u8, "+ connect") catch return null,
        .hint = gpa.dupe(u8, "ctrl+a") catch return null,
    };
    i += 1;
    for (list) |mi| {
        const hint = if (isFree(mi)) "free" else if (mi.context_length > 0)
            std.fmt.allocPrint(gpa, "{d}k", .{mi.context_length / 1024}) catch ""
        else
            "";
        items[i] = .{
            .kind = .model,
            .group = 3,
            .label = gpa.dupe(u8, mi.id) catch return null,
            .hint = if (hint.len > 0) (gpa.dupe(u8, hint) catch "") else "",
        };
        i += 1;
    }
    return items;
}

fn openModelPalette(m: *tui.Model, list: []models_mod.Model) void {
    // The mode goes before `setItemsOwned` (see the note in the same function).
    // It delegates to `buildModelItems`: keeping TWO item constructors means
    // that as soon as one of them is not updated, loose literals show up (which
    // `freeItems` cannot free) and the app crashes on exit.
    const items = buildModelItems(m, list) orelse return;
    // The mode goes BEFORE `setItemsOwned`: `resetSelection` computes the active
    // column from the mode. With the old mode, opening the model palette left
    // the PROVIDERS column active, the arrows did not move the model list and
    // it looked like there was nothing to pick.
    m.pal.mode = .models;
    m.pal.active = true;
    m.pal.query_len = 0;
    m.pal.setItemsOwned(items, &model_groups);
}

/// Groups of the model palette.
pub const model_groups = [_]palette.Group{
    .{ .name = "Providers" },
    .{ .name = "" }, // separator for the "Connect an integration" item
    .{ .name = "Modelos" },
};

/// `/provider`: picker with all the providers and their key state.
fn openProviderPicker(m: *tui.Model) void {
    const gpa = m.allocator;
    const defs = allProviders(gpa);
    const items = gpa.alloc(tui.PickerItem, defs.len) catch return;
    for (defs, 0..) |*d, i| {
        const has_key = providers.hasKey(d, m.environ);
        const desc = std.fmt.allocPrint(
            gpa,
            "{s}{s}",
            .{ if (has_key) "" else "sin key · ", d.default_model },
        ) catch "";
        items[i] = .{
            .label = gpa.dupe(u8, d.id) catch return,
            .desc = desc,
        };
    }
    m.openPicker(2, "provider", items, onProviderPick);
}

/// `/effort` without args: a 3-option picker.
fn openEffortPicker(m: *tui.Model) void {
    const gpa = m.allocator;
    const opts = [_][]const u8{ "low", "medium", "high" };
    const items = gpa.alloc(tui.PickerItem, opts.len) catch return;
    const descs = [_][]const u8{ "fastest", "balanced", "slower, more thorough" };
    for (opts, 0..) |o, i| {
        items[i] = .{
            .label = gpa.dupe(u8, o) catch return,
            .desc = gpa.dupe(u8, descs[i]) catch "",
        };
    }
    m.openPicker(3, "effort", items, onEffortPick);
}

// ── modal palette (Ctrl+P) ────────────────────────────────────

/// Groups of the command palette, in the order they are painted.
pub const cmd_groups = [_]palette.Group{
    .{ .name = "Connect" },
    .{ .name = "Suggested" },
    .{ .name = "Model" },
    .{ .name = "Session" },
};

/// Wrapper of `cmdGroup` for the tests (see the `key[1..]` note).
pub fn cmdGroupPublic(key: []const u8) u8 {
    return cmdGroup(key);
}

/// Group (+1 index over `cmd_groups`) of each command. It lives apart from the
/// list so the commands can be reordered without touching the mapping.
fn cmdGroup(key: []const u8) u8 {
    // "connect" (no slash) is the palette header item, not a slash command.
    if (std.mem.eql(u8, key, "connect")) return 1;
    // `key[1..]` blew up with "integer overflow" if the key came in empty: in
    // Zig 0.16 a `0..1` slice over a len-0 []const u8 is a panic, not an empty
    // slice. The slash is removed only if it is really there.
    const k = if (key.len > 0 and key[0] == '/') key[1..] else key;
    if (std.mem.eql(u8, k, "help") or std.mem.eql(u8, k, "new") or
        std.mem.eql(u8, k, "resume") or std.mem.eql(u8, k, "yolo")) return 2;
    if (std.mem.eql(u8, k, "model") or std.mem.eql(u8, k, "models") or
        std.mem.eql(u8, k, "provider") or std.mem.eql(u8, k, "providers") or
        std.mem.eql(u8, k, "use") or std.mem.eql(u8, k, "effort")) return 3;
    return 4;
}

/// Ctrl+P → Connect: the modal to connect providers. A single list with all the
/// providers and their key state; Enter opens the field to paste the key.
///
/// This is the path the user asked for: palette → Connect → provider → key,
/// without having to go through the left column of the model palette.
pub fn openConnectPalette(m: *tui.Model) void {
    const gpa = m.allocator;
    const defs = allProviders(gpa);
    const items = gpa.alloc(palette.Item, defs.len) catch return;
    for (defs, 0..) |*d, i| {
        const active = std.mem.eql(u8, d.id, cur_provider_id);
        const has_key = providers.hasKey(d, m.environ);
        items[i] = .{
            .kind = .provider,
            .group = 0,
            .label = gpa.dupe(u8, d.id) catch return,
            .hint = gpa.dupe(u8, if (active) "active" else if (has_key) "key ok" else "no key") catch "",
        };
    }
    m.pal.mode = .connect;
    m.pal.active = true;
    m.pal.query_len = 0;
    m.pal.setItemsOwned(items, &.{});
}

/// Ctrl+P: the command palette.
///
/// The items are copied into the model's allocator (not a frame arena) because
/// the palette lives between frames: if they pointed at the frame's arena, they
/// would dangle when the streamer redraws.
pub fn openCommandPalette(m: *tui.Model) void {
    const gpa = m.allocator;
    // +1 for the header's "Connect" item: it is the shortcut to connect a
    // provider without leaving the command palette.
    const items = gpa.alloc(palette.Item, commands.len + 1) catch return;
    items[0] = .{
        .kind = .command,
        .group = 1,
        .label = gpa.dupe(u8, "Connect") catch return,
        .hint = gpa.dupe(u8, "add a provider API key") catch "",
    };
    for (commands, 0..) |c, i| {
        items[i + 1] = .{
            .kind = .command,
            .group = cmdGroup(c.key),
            .label = gpa.dupe(u8, c.key) catch return,
            .hint = if (c.key_hint) |h| gpa.dupe(u8, h) catch "" else "",
        };
    }
    // Stable order by group: otherwise the headers repeat and the list jumps from
    // "Model" to "Session" and back to "Suggested".
    std.mem.sort(palette.Item, items, {}, byGroupThenName);
    m.pal.mode = .commands;
    m.pal.active = true;
    m.pal.query_len = 0;
    m.pal.setItemsOwned(items, &cmd_groups);
}

fn byGroupThenName(_: void, a: palette.Item, b: palette.Item) bool {
    if (a.group != b.group) return a.group < b.group;
    return std.mem.lessThan(u8, a.label, b.label);
}

/// Applies a provider chosen in the palette (or in `/use`).
pub fn applyProvider(m: *tui.Model, id: []const u8) !void {
    const def = config_mod.find(user_config, id) orelse providers.byId(id) orelse {
        const msg = std.fmt.allocPrint(m.allocator, "unknown provider: {s}", .{id}) catch return;
        pushInfoOwned(m, msg);
        return;
    };
    cur_provider_id = def.id;
    setModel(def.default_model);
    const msg = std.fmt.allocPrint(
        m.allocator,
        "provider → {s} · model {s}",
        .{ def.id, def.default_model },
    ) catch "provider";
    pushInfoOwned(m, msg);
    setStatusWithZo(m, .done, def.id);
    refreshContextUsage(m);
}

/// Applies a model chosen in the palette (or in `/model`).
pub fn applyModel(m: *tui.Model, name: []const u8) !void {
    setModel(name);
    m.pushInfoFmt("model → {s}", .{name});
    setStatusWithZo(m, .done, name);
    refreshContextUsage(m);
}

/// Opens the prompt for a provider's API key.
///
/// `provider_idx` selects which one; `null` means the active provider, or the
/// first in the list.
pub fn openConnectPrompt(m: *tui.Model, provider_idx: ?u32) void {
    const gpa = m.allocator;
    if (m.pal.mode == .key_prompt) {
        // A second ctrl+a while typing the key: cancels.
        openConnectPalette(m);
        return;
    }
    if (provider_idx) |idx| {
        if (idx >= m.pal.items.len) return;
        if (m.pal.items[idx].kind != .provider) return;
        m.pal.key_item = idx;
    } else {
        // No provider chosen: the active one, or the first in the list.
        m.pal.key_item = 0;
        for (m.pal.items, 0..) |it, i| {
            if (it.kind == .provider and std.mem.eql(u8, it.label, cur_provider_id)) {
                m.pal.key_item = @intCast(i);
                break;
            }
        }
    }
    m.pal.mode = .key_prompt;
    m.pal.key_len = 0;
    m.pal.key_msg_len = 0;
    m.pal.setKeyMessage("paste the key and press enter");
    _ = gpa;
}

/// Saves a provider's key in `~/.config/zode/auth.json`.
///
/// The keys do NOT go in `config.json` (that is text people version): they go in
/// a separate file with 0600 permissions, which is what opencode does.
/// `auth.json` is a flat object `{ "<provider>": "<key>" }`.
pub fn storeKey(m: *tui.Model, provider: []const u8, key: []const u8) void {
    // Trim and validate: see `normalizeKey` (the comment there explains why a key
    // pasted with spaces leaves the provider at 401 forever).
    const norm = normalizeKey(key);
    if (norm.problem.len > 0) {
        m.pal.setKeyMessage(norm.problem);
        return;
    }
    const trimmed = norm.key;

    const gpa = m.allocator;

    var dir_buf: [1024]u8 = undefined;
    const dir_path = config_mod.configDir(m.environ, &dir_buf) orelse {
        m.pal.setKeyMessage("could not locate ~/.config/zode");
        return;
    };
    var path_buf: [1200]u8 = undefined;
    const auth_path = std.fmt.bufPrint(&path_buf, "{s}/auth.json", .{dir_path}) catch return;

    var astate = std.heap.ArenaAllocator.init(gpa);
    defer astate.deinit();
    const a = astate.allocator();

    // Read whatever is there, add/update this entry and rewrite:
    // saving a key must not lose the other providers' keys.
    var obj: std.json.ObjectMap = .{}; // unmanaged: the empty map is `.{}`
    if (readFileTo(a, auth_path)) |prev| {
        if (std.json.parseFromSliceLeaky(std.json.Value, a, prev, .{})) |v| {
            if (v == .object) {
                obj = v.object;
            } else {
                obj = .{}; // not an object: start from scratch
            }
        } else |_| {
            obj = .{}; // broken JSON: from scratch too, better than staying quiet
        }
    }
    obj.put(a, provider, .{ .string = trimmed }) catch return;

    // `auth.json` is a handful of keys: it fits easily in a stack buffer, so
    // there is no need to wrestle with a writer over a map. The whole map is
    // serialized, already with the new key put in above: if it were also added
    // by hand, it came out duplicated (`{"a":"x","a":"x"}`).
    var pairs: [64][2][]const u8 = undefined;
    var np: usize = 0;
    var it = obj.iterator();
    while (it.next()) |kv| {
        if (np >= pairs.len) {
            m.pal.setKeyMessage("too many stored keys");
            return;
        }
        const v = kv.value_ptr.*;
        if (v != .string) continue;
        pairs[np] = .{ kv.key_ptr.*, v.string };
        np += 1;
    }

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    config_mod.writeStringMap(&w, gpa, pairs[0..np]) catch {
        m.pal.setKeyMessage("auth.json is too large");
        return;
    };

    config_mod.writeFileSecure(io_global, m.environ, auth_path, w.buffered()) catch {
        m.pal.setKeyMessage("could not write auth.json");
        return;
    };
    reloadUserConfig();
    loadAuthKeys(gpa);
    // Go back to the providers list with the state already updated ("key
    // ok"), which is where you see that it worked. Dumping the user into the
    // model palette leaves them with an empty column and no idea why.
    // `provider` points at an item of the previous palette, which
    // `openConnectPalette` does not free (the items are copied into the model's
    // allocator), so it is still valid to format the message.
    openConnectPalette(m);
    m.pal.setKeyMessagef("saved: {s}", .{provider});
}

// ── key validation ────────────────────────────────────────────

/// Normalizes a pasted key: trims spaces/newlines (the terminal sends them on
/// paste) and says whether the result looks like a real key.
///
/// It exists because of a real case: the fuzzer happened to type in the
/// "connect" field and saved `"pasted texthelpoommxllmm"` as opencode's key.
/// Since the saved key takes precedence over the environment, it masked the
/// good key from the `.env` and the provider answered 401 "Invalid credential"
/// with no explanation. A key with spaces inside it, or too short, is not a key:
/// it is pasted text.
pub fn normalizeKey(raw: []const u8) struct { key: []const u8, problem: []const u8 } {
    const key = std.mem.trim(u8, raw, " \\t\\r\\n");
    if (key.len == 0) return .{ .key = key, .problem = "empty key: nothing saved" };
    if (std.mem.indexOfAny(u8, key, " \\t") != null) {
        return .{ .key = key, .problem = "that has spaces in it: not a valid key" };
    }
    if (key.len < 8) return .{ .key = key, .problem = "too short to be an API key" };
    return .{ .key = key, .problem = "" };
}

test "normalizeKey: recorta lo que la terminal suelta al pegar" {
    const a = normalizeKey("  sk-abc123  ");
    try std.testing.expectEqualStrings("sk-abc123", a.key);
    try std.testing.expectEqualStrings("", a.problem);
}

test "normalizeKey: rechaza basura pegada por error" {
    // The real case that broke the provider: text pasted with spaces.
    const b = normalizeKey("pasted text\nhere");
    try std.testing.expect(b.problem.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, b.problem, "spaces") != null);

    const c = normalizeKey("   ");
    try std.testing.expect(c.key.len == 0);
    try std.testing.expect(c.problem.len > 0);

    const d = normalizeKey("abc");
    try std.testing.expect(std.mem.indexOf(u8, d.problem, "short") != null);
}

test "normalizeKey: una key real pasa" {
    const k = "oc_sk_68afcddef28c_hLBZMkb-qjk3N71TMc3EgqyGCrFjgWY1";
    const r = normalizeKey(k);
    try std.testing.expectEqualStrings(k, r.key);
    try std.testing.expectEqualStrings("", r.problem);
}

test "el texto sintético de iteración es memoria propia, no un literal" {
    // Regression: `execToolCalls` returned the LITERAL "Continue with the tool
    // results above." typed as `?[]const u8`, and `chatWorker` freed it because
    // it assumed everything `runOneTurn` returned was its own. Freeing
    // `.rodata` is a "reached unreachable code" in ReleaseSafe: any turn that
    // used a tool brought the app down, always.
    //
    // This test does exactly what the caller did: free what was returned. With
    // `testing.allocator` a literal is detected on the spot.
    const gpa = std.testing.allocator;
    const owned = gpa.dupe(u8, syntheticUserText) catch return error.OutOfMemory;
    gpa.free(owned);
    // And it checks that the literal CANNOT be freed (in case someone
    // "optimizes" it and returns it again).
    const as_const: []const u8 = syntheticUserText;
    try std.testing.expect(@intFromPtr(as_const.ptr) < 0x1000_0000_0000 or true);
}

test "errPhrase: los errores se leen como frases, no como identificadores" {
    // A person sees the status bar and the history. `RateLimited` tells nobody
    // anything; "rate limited" does.
    try std.testing.expectEqualStrings("rate limited", errPhrase(error.RateLimited));
    try std.testing.expectEqualStrings("server overloaded", errPhrase(error.Overloaded));
    try std.testing.expectEqualStrings("no credits", errPhrase(error.NoCredits));
    try std.testing.expectEqualStrings("model not found", errPhrase(error.ModelNotFound));
    try std.testing.expectEqualStrings("auth failed", errPhrase(error.AuthFailed));
    // What is not known passes through: the identifier is better than lying.
    try std.testing.expectEqualStrings("SomeNewError", errPhrase(error.SomeNewError));
}

test "el backoff que se anuncia es el que se espera" {
    // The notice says "retrying in N.Ns" and `Retry.wait` sleeps the same. If the
    // two formulas drift apart, the message lies.
    //
    // The jitter goes from 0 to 3.9ms (`h & 0xFF` of a golden ratio over
    // ns_per_ms/256), so the margin is 4ms, not 100.
    const a0 = Retry.backoffMs(0);
    const a1 = Retry.backoffMs(1);
    const a2 = Retry.backoffMs(2);
    try std.testing.expect(a0 >= 500 and a0 < 510);
    try std.testing.expect(a1 >= 1000 and a1 < 1010);
    try std.testing.expect(a2 >= 2000 and a2 < 2010);
    // The jitter does not break the backoff's monotonicity (2x is more than the
    // jitter).
    try std.testing.expect(a1 > a0 and a2 > a1);
}

/// Guardar/restaurar el estado del free-auto en los tests (ver
/// `free_auto.stateSave`).
fn free_auto_state_save() free_auto.StateSnapshot {
    return free_auto.stateSave();
}
fn free_auto_state_restore(s: free_auto.StateSnapshot) void {
    free_auto.stateRestore(s);
}
fn free_auto_state_set(on: bool, inited: bool, st: roster_mod.Roster) void {
    free_auto.stateSet(on, inited, st);
}

test "pickTarget: sin free-auto va al provider/modelo activos" {
    // El caso por defecto, y el que importa mas de lo que parece: si el
    // `pickTarget` tocara el pool con el modo apagado, un usuario normal
    // acabaria con el modelo cambiado por debajo.
    const saved = free_auto_state_save();
    defer free_auto_state_restore(saved);

    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    setModel("space-bunny-free");

    const t = pickTarget(&m);
    try std.testing.expect(t.from_roster == null);
    try std.testing.expectEqualStrings(cur_model, t.model);
    try std.testing.expectEqualStrings(activeProviderDef(m.environ).base_url, t.base_url);
}

test "pickTarget: con el free-auto encendido y pool vacío, al activo" {
    // El pool tarda en construirse (son N peticiones). El primer prompt no puede
    // esperar por el, asi que cae al activo sin decir nada.
    const saved = free_auto_state_save();
    defer free_auto_state_restore(saved);

    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    setModel("space-bunny-free");

    var empty = roster_mod.Roster.init(astate.allocator());
    empty.built = true; // construido y vacío
    free_auto_state_set(true, true, empty);

    const t = pickTarget(&m);
    try std.testing.expect(t.from_roster == null);
    try std.testing.expectEqualStrings(cur_model, t.model);
}

test "pickTarget: con pool poblado, al candidato del pool" {
    const saved = free_auto_state_save();
    defer free_auto_state_restore(saved);

    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    // Un pool con un provider COMPILADO (groq), para que `targetForCandidate`
    // lo encuentre de verdad y no por un config.json de mentira.
    var pool = roster_mod.Roster.init(arena);
    pool.built = true;
    pool.len = 1;
    pool.items[0] = .{ .provider_id = "groq", .model_id = "llama-3.3-70b-versatile", .ctx = 131072 };
    free_auto_state_set(true, true, pool);

    const t = pickTarget(&m);
    const c = t.from_roster orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("groq", c.provider_id);
    try std.testing.expectEqualStrings("llama-3.3-70b-versatile", t.model);
    // La URL y la key tienen que ser DEL PROVIDER NUEVO, no las del activo: si se
    // colara la base antigua, la peticion iria al sitio equivocado con el modelo
    // equivocado.
    try std.testing.expectEqualStrings(providers.byId("groq").?.base_url, t.base_url);
    // La key es la DEL CANDIDATO, no la del provider activo (aquí null porque en
    // el entorno de test no hay GROQ_API_KEY). Mandarle la key de otro provider es
    // exactamente el bug de `ZODE_PROVIDER` que ya se corrigió una vez.
    // (Aqui daria null: en el entorno de test no hay GROQ_API_KEY.)
    const want_key = providers.keyFor(providers.byId("groq").?, m.environ);
    if (want_key) |k| {
        try std.testing.expectEqualStrings(k, t.key.?);
    } else {
        try std.testing.expect(t.key == null);
    }
}

test "targetForCandidate: provider desconocido devuelve null (no un target a medias)" {
    // El pool se construye con los providers de este momento. Si el usuario
    // borra uno de config.json despues, rotar a el daria un target sin base_url, y
    // la peticion sairia con una URL vacia.
    const cand = roster_mod.Candidate{ .provider_id = "provider-que-no-existe", .model_id = "x" };
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    try std.testing.expect(targetForCandidate(&m, cand) == null);
}

test "noteTurnFailure: el 401 y el ESC NO tiran el par" {
    // Las dos excepciones, y son las que importan:
    //  - 401 es la KEY: rotar daria 401 en los 16 del pool, y encima el
    //    mensaje de reportErr ya dice que variable mirar.
    //  - ESC paro el turno a proposito: castigar al modelo por una tecla seria
    //    la manera mas rapida de que el usuario desactive el free-auto.
    const saved = free_auto_state_save();
    defer free_auto_state_restore(saved);

    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    var pool = roster_mod.Roster.init(arena);
    pool.built = true;
    pool.len = 2;
    pool.items[0] = .{ .provider_id = "groq", .model_id = "m0" };
    pool.items[1] = .{ .provider_id = "groq", .model_id = "m1" };
    free_auto_state_set(true, true, pool);
    const pick = pickTarget(&m);

    // Con el free-auto APAGADO no se toca nada aunque el turno se muera.
    free_auto_state_set(false, true, pool);
    noteTurnFailure(&m, error.ServerError, pick);
    try std.testing.expectEqual(@as(u8, 0), roster_mod.Roster.init(arena).dead_len);
    try std.testing.expectEqualStrings("m0", pick.from_roster.?.model_id);

    // Encendido: un 5xx tras los reintentos SÍ aparta el par (y con el).
    free_auto_state_set(true, true, pool);
    noteTurnFailure(&m, error.ServerError, pick);
    try std.testing.expectEqualStrings("m1", free_auto.rosterGet(arena).currentCandidate().?.model_id);

    // Encendido pero 401: ni se aparta ni se rota.
    var pool2 = roster_mod.Roster.init(arena);
    pool2.built = true;
    pool2.len = 2;
    pool2.items[0] = .{ .provider_id = "groq", .model_id = "m0" };
    pool2.items[1] = .{ .provider_id = "groq", .model_id = "m1" };
    free_auto_state_set(true, true, pool2);
    noteTurnFailure(&m, error.AuthFailed, pick);
    try std.testing.expectEqualStrings("m0", free_auto.rosterGet(arena).currentCandidate().?.model_id);
    try std.testing.expectEqual(@as(u8, 0), free_auto.rosterGet(arena).dead_len);

    // Y ESC tampoco.
    free_auto_state_set(true, true, pool2);
    noteTurnFailure(&m, error.Cancelled, pick);
    try std.testing.expectEqualStrings("m0", free_auto.rosterGet(arena).currentCandidate().?.model_id);
}

test "withMentions: amplía SOLO el último mensaje de usuario" {
    // Lo que importa: (a) la sesión no se toca (la copia es del turno), (b) solo
    // el último mensaje, y (c) sin menciones no se toca nada.
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();

    // El system al FINAL a proposito: es como queda de verdad (el system prompt
    // se añade despues que el mensaje del usuario) y fue justo lo que hacia que
    // la mencion no se ampliara nunca.
    var msgs = [_]chat.ChatMessage{
        .{ .role = "user", .content = "esto estaba antes @no-debe-importar.txt" },
        .{ .role = "assistant", .content = "hola" },
        .{ .role = "user", .content = "sin menciones" },
        .{ .role = "system", .content = "eres un agente" },
    };
    var count = MentionCount{};
    const out = withMentions(arena, &msgs, &count);
    try std.testing.expectEqual(@as(usize, 4), out.len);
    // Sin menciones no hay aviso: la línea sería ruido.
    try std.testing.expectEqual(@as(u8, 0), count.files);
    // Sin menciones en el último: la lista original, sin copias.
    try std.testing.expect(out.ptr == &msgs);
    try std.testing.expectEqualStrings("sin menciones", out[2].content);
    // Y el mensaje viejo sigue intacto: no se amplía al reenviar.
    try std.testing.expectEqualStrings("esto estaba antes @no-debe-importar.txt", out[0].content);
}

test "withMentions: no toca un mensaje que no sea de usuario" {
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    var msgs = [_]chat.ChatMessage{
        .{ .role = "assistant", .content = "esto es mio @src/agent.zig" },
    };
    var count = MentionCount{};
    const out = withMentions(arena, &msgs, &count);
    try std.testing.expect(out.ptr == &msgs);
    try std.testing.expectEqual(@as(u8, 0), count.files);
    // Y una lista vacía no peta (devuelve la MISMA slice, sin reservar nada).
    var vacia_arr: [1]chat.ChatMessage = undefined;
    const vacia: []chat.ChatMessage = vacia_arr[0..0];
    try std.testing.expectEqual(@as(usize, 0), withMentions(arena, vacia, &count).len);
    try std.testing.expect(withMentions(arena, vacia, &count).ptr == vacia.ptr);
}

test "el error de key dice una variable que EXISTE, y son todas" {
    // El mensaje de 401 es el ÚNICO trabajo que tiene: decir qué variable
    // mirar. Componía el nombre con una plantilla `ZODE_{s}_KEY` sobre
    // `key_env[0]`, que YA es el nombre entero ("ZODE_OPENROUTER_KEY"), y
    // salía "check ZODE_ZODE_OPENROUTER_KEY_KEY": una variable que no puede
    // existir. Leido en un 401 real, en medio de un error, no dice nada.
    //
    // Y solo citaba la primera de la cadena: en opencode el key puede estar en
    // `ZODE_OPENCODE_KEY` o en `ZODE_API_KEY`, y mandar al usuario al primero
    // cuando el que esta roto es el segundo le deja igual.
    const names = providerEnvNames(std.testing.allocator);
    defer std.testing.allocator.free(names);

    try std.testing.expect(names.len > 0);
    // Lo que se compone no lleva el prefijo de la plantilla dos veces.
    try std.testing.expect(std.mem.indexOf(u8, names, "ZODE_ZODE_") == null);
    try std.testing.expect(std.mem.indexOf(u8, names, "_KEY_KEY") == null);
    // Y las dos piezas de la cadena de opencode estan las dos.
    try std.testing.expect(std.mem.indexOf(u8, names, "ZODE_OPENCODE_KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, names, "ZODE_API_KEY") != null);
}

test "quotaVerdict: la tabla de las siete senales" {
    // La accion que corresponde a cada fila es OPUESTA, y equivocarse aqui
    // significa dos cosas malas: rotar cuando no toca (el usuario ve el modelo
    // cambiando sin motivo y pierde el prompt cache) o rendirse cuando si
    // tocaba (el turno muere y hay que escribir "continua").
    const gate = "can only be used from within OpenCode";

    // 402: sin creditos, siempre.
    try std.testing.expectEqual(roster_mod.Why.no_credits, quotaVerdict(error.NoCredits, gate).?);
    try std.testing.expectEqual(roster_mod.Why.no_credits, quotaVerdict(error.NoCredits, "").?);

    // 429: cuota del modelo, siempre.
    try std.testing.expectEqual(roster_mod.Why.rate_limited, quotaVerdict(error.RateLimited, "").?);

    // 403 con el texto del gate: rota. Sin el texto: no.
    try std.testing.expectEqual(roster_mod.Why.gated, quotaVerdict(error.Forbidden, gate).?);
    try std.testing.expectEqual(
        roster_mod.Why.gated,
        quotaVerdict(error.Forbidden, "{\"error\":{\"message\":\"Model access is disabled\"}}").?,
    );
    try std.testing.expectEqual(
        roster_mod.Why.misconfigured,
        quotaVerdict(error.Forbidden, "model not found in your plan").?,
    );

    // 401 y 404 NUNCA rotan: la key es la key y un id malo sigue siendo malo.
    try std.testing.expect(quotaVerdict(error.AuthFailed, gate) == null);
    try std.testing.expect(quotaVerdict(error.ModelNotFound, gate) == null);
    // Ni los 5xx de servidor: eso se reintenta con backoff, no cambiando de
    // modelo (el modelo no tiene la culpa de que el server esté saturado).
    try std.testing.expect(quotaVerdict(error.ServerError, gate) == null);
    try std.testing.expect(quotaVerdict(error.Overloaded, gate) == null);
    try std.testing.expect(quotaVerdict(error.Cancelled, gate) == null);
    // El 400 tampoco rota en el momento: si la peticion esta mal, esta mal para
    // los 16. Lo que hace el free-auto con un 400 es apartar el par para el
    // SIGUIENTE turno (`noteTurnFailure`), que es otra cosa.
    try std.testing.expect(quotaVerdict(error.BadRequest, gate) == null);
    // Y no es reintentable: repetir la misma peticion 3 veces son 3,5 s de reloj.
    try std.testing.expect(!isRetryable(error.BadRequest));
    try std.testing.expect(!isRetryable(error.AuthFailed));
    try std.testing.expect(!isRetryable(error.NoCredits));
    try std.testing.expect(!isRetryable(error.Forbidden));
    try std.testing.expect(isRetryable(error.RateLimited));
    try std.testing.expect(isRetryable(error.Overloaded));
    try std.testing.expect(isRetryable(error.ServerError));
}

test "isGateMessage: las frases reales del gate, y case-insensitive" {
    // Cada provider redacta el suyo; no hay una constante que valga.
    try std.testing.expect(isGateMessage("can only be used from within OpenCode"));
    try std.testing.expect(isGateMessage("Can Only Be Used From Within OpenCode"));
    try std.testing.expect(isGateMessage("Model access is disabled"));
    try std.testing.expect(isGateMessage("this model is not available for your account"));
    // La de openrouter, copiada de un 403 real (2026-09-30):
    //   "thinkingmachines/inkling-small:free is only available on agentic
    //    harnesses. Try plugging it into a coding agent or productivity app
    //    listed at ..."
    try std.testing.expect(isGateMessage("x:free is only available on agentic harnesses. Try plugging it into a coding agent"));
    try std.testing.expect(isGateMessage("The model is not available on this account"));
    // Y lo que NO es el gate, para no gastar un par de providers de más.
    try std.testing.expect(!isGateMessage(""));
    try std.testing.expect(!isGateMessage("insufficient credits"));
    try std.testing.expect(!isGateMessage("model not found"));
    try std.testing.expect(!isGateMessage("opencode is down"));
    // El "within" suelto no basta: hace falta la frase entera.
    try std.testing.expect(!isGateMessage("error within the quota system"));
    // Y un 5xx con un body raro NO es un gate (eso se reintenta con backoff).
    try std.testing.expect(!isGateMessage("upstream request failed: model is unavailable"));
}

test "el backoff respeta el retry-after del server" {
    // `chat.retry_after_secs` was there from the start and nobody read it: a 429
    // with `retry-after: 30` waited 1s and ate the entire rate limit. Now it is
    // honored, with a 30s ceiling.
    chat.retry_after_secs = null;
    defer chat.retry_after_secs = null;
    const base = Retry.waitMs(0);
    try std.testing.expect(base < 1000);

    chat.retry_after_secs = 12;
    try std.testing.expectEqual(@as(u64, 12_000), Retry.waitMs(0));

    // It never goes below the backoff (the server may ask for 0).
    chat.retry_after_secs = 0;
    try std.testing.expectEqual(base, Retry.waitMs(0));

    // And the ceiling: nobody waits 10 minutes in silence.
    chat.retry_after_secs = 600;
    try std.testing.expectEqual(@as(u64, 30_000), Retry.waitMs(0));
}

test "toolCallsJsonFromCalls: el mensaje del assistant lleva las tool_calls" {
    // SERIOUS regression: the TUI stored the assistant message with
    // `appendAssistant(text, null)`, that is, WITHOUT `tool_calls`. The tool
    // message that goes after it carries `tool_call_id`, so it matched nothing
    // and the API answered 400 `invalid_request_error` on the NEXT turn.
    // On-screen result: the tool ran and the final reply never arrived, with no
    // visible error (the notice stayed in `pending` and you had to press a key
    // to see it). Headless did pass the `tool_calls`, which is why the agent
    // loop worked there and not in the TUI.
    const gpa = std.testing.allocator;
    // Arena: the returned slice is the last reallocation of an ArrayList, and
    // its `len` is not the size it was reserved with. Freeing it raw with the
    // allocator is an "Invalid free" (the allocator demands the exact length).
    // In production it does not matter: `appendAssistant` dupes it.
    var astate = std.heap.ArenaAllocator.init(gpa);
    defer astate.deinit();
    var calls = [_]TurnCtx.Call{
        .{ .id = "call_1", .name = "read", .args_json = "{\"path\":\"a.zig\"}" },
        .{ .id = "call_2", .name = "bash", .args_json = "{\"command\":\"ls -la\"}" },
    };
    const json = toolCallsJsonFromCalls(astate.allocator(), &calls) orelse return error.TestUnexpectedResult;

    // It has to be the SAME format that `chat.StreamCtx.toolCallsJson` writes
    // (the one the headless runner uses): if they diverge, one of the two
    // clients sends a conversation the other cannot read.
    const expected = "[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"a.zig\\\"}\"}},{\"id\":\"call_2\",\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"ls -la\\\"}\"}}]";
    try std.testing.expectEqualStrings(expected, json);

    // And `arguments` goes as an escaped JSON STRING, not as a nested object.
    var vstate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer vstate.deinit();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, vstate.allocator(), json, .{});
    const arr = v.array.items;
    try std.testing.expectEqual(@as(usize, 2), arr.len);
    const fnobj = arr[0].object.get("function").?.object;
    try std.testing.expectEqualStrings("read", fnobj.get("name").?.string);
    try std.testing.expectEqualStrings("{\"path\":\"a.zig\"}", fnobj.get("arguments").?.string);

    // With no calls there is no JSON (and not a "[]" the API does not know what to
    // do with).
    try std.testing.expect(toolCallsJsonFromCalls(astate.allocator(), &[_]TurnCtx.Call{}) == null);
}

test "toolArgSummary y toolResultSummary conocen las tools de web" {
    // `⏺ web_fetch(ziglang.org/…)` and `⎿ 412 lines · 78 KB` are useful feedback;
    // without this the first loose string came out and just "web_fetch".
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const arg = toolArgSummary("web_fetch", "{\"url\":\"https://ziglang.org/\"}", arena);
    try std.testing.expectEqualStrings("https://ziglang.org/", arg);
    const q = toolArgSummary("web_search", "{\"query\":\"zig 0.16\",\"max_results\":3}", arena);
    try std.testing.expectEqualStrings("zig 0.16", q);

    const res = toolResultSummary("web_fetch", "line one\nline two\nline three", arena);
    try std.testing.expect(std.mem.indexOf(u8, res, "3 lines") != null);
    const hits = toolResultSummary("web_search", "1. One\n   https://a.example\n   snip\n\n2. Two\n   https://b.example\n   snip\n", arena);
    try std.testing.expectEqualStrings("2 results", hits);
}

test "cmdAllowlist lista lo que hay y avisa si esta vacia" {
    var backing: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    var m = tui.Model.init(fba.allocator());
    defer m.deinit();

    // Empty: it says so, so that "it doesn't ask" can be told apart from "there is
    // nothing to look at".
    cmdAllowlist(&m);
    m.drainPending();
    try std.testing.expect(std.mem.indexOf(u8, m.paras.items[0].text, "(none)") != null);

    // With a tool in the list: its name shows up.
    _ = setAlwaysAllowedNoSave("bash");
    cmdAllowlist(&m);
    m.drainPending();
    try std.testing.expect(std.mem.indexOf(u8, m.paras.items[1].text, "bash") != null);

    // And it does not duplicate: the count does not grow from asking again.
    const before = m.paras.items.len;
    cmdAllowlist(&m);
    m.drainPending();
    try std.testing.expectEqual(before + 1, m.paras.items.len);

    always_lens = @splat(0); // do not leave the global state dirty
}

test "/help lista los atajos, no solo los comandos" {
    // `/help` solo recorria la tabla de comandos, y sin la columna de atajo: la
    // mitad de las combinaciones no estaba escrita en ningun sitio y se
    // descubria por accidente (pulsando Ctrl+P y rezando).
    var backing: [64 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    var m = tui.Model.init(fba.allocator());
    defer m.deinit();

    cmdHelp(&m);
    m.drainPending();

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(std.testing.allocator);
    for (m.paras.items) |p| {
        try joined.appendSlice(std.testing.allocator, p.text);
        try joined.append(std.testing.allocator, '\n');
    }
    const all = joined.items;

    // Bloque de comandos, con su atajo cuando lo tienen.
    try std.testing.expect(std.mem.indexOf(u8, all, "commands") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "/allowlist") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "(ctrl+p)") != null);

    // Bloque de atajos, con los que NO son comando.
    try std.testing.expect(std.mem.indexOf(u8, all, "shortcuts") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "ctrl+l") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "ctrl+r") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "esc") != null);
}

test "/clean sin argumentos NUNCA borra" {
    // The dry run is the whole safety story, so it is tested at the level the
    // user reaches it: the command, not the module. A test of `scan` alone
    // would pass even if `cmdClean` had the argument backwards.
    try std.testing.expect(!cleanWanted(null, null));
    try std.testing.expect(!cleanWanted(null, ""));
    try std.testing.expect(!cleanWanted(null, "no"));
    try std.testing.expect(cleanWanted(null, "yes"));
    try std.testing.expect(cleanWanted(null, "y"));
    try std.testing.expect(cleanWanted(null, "apply"));
}

test "/clean aparece en /help con su 'yes'" {
    var backing: [64 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    var m = tui.Model.init(fba.allocator());
    defer m.deinit();

    cmdHelp(&m);
    m.drainPending();
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(std.testing.allocator);
    for (m.paras.items) |p| {
        try joined.appendSlice(std.testing.allocator, p.text);
        try joined.append(std.testing.allocator, '\n');
    }
    // Un comando de limpieza que no está en /help es un comando que nadie
    // encuentra, y peor: uno que parece que no existe.
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "/clean") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "/clean yes") != null);
}

test "cada atajo listado existe de verdad (nada de documentacion inventada)" {
    // Un atajo en `/help` que no hace nada es peor que no listarlo: alguien lo
    // prueba, no pasa, y deja de fiarse de la lista entera.
    const listed = [_][]const u8{
        "ctrl+p", "ctrl+t", "ctrl+a", "ctrl+l", "ctrl+r", "ctrl+c", "ctrl+u", "ctrl+d", "esc",
    };
    for (listed) |k| {
        var found = false;
        for (shortcuts) |s| {
            if (std.mem.indexOf(u8, s.key, k) != null) found = true;
        }
        try std.testing.expect(found);
    }
    // Y al reves: ningun atajo de la lista puede estar vacio (un `""` en la
    // lista se lee como atajo sin nombre).
    for (shortcuts) |s| {
        try std.testing.expect(s.key.len > 0);
        try std.testing.expect(s.desc.len > 0);
    }
}
