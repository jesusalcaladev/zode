//! The clipboard, in three rungs.
//!
//! `/copy` has to put a text in the user's clipboard, and there is no single
//! way that works everywhere:
//!
//! 1. A NATIVE tool (`wl-copy`, `xclip`, `xsel`, `pbcopy`): the system
//!    clipboard, with no terminal involved. It is the most reliable, so it is
//!    the first choice when the tool is there.
//! 2. tmux's own buffer (`tmux load-buffer`): reachable with the paste prefix
//!    and, with `-w`, forwarded to the outer terminal when it speaks OSC 52.
//! 3. OSC 52 (`ESC ] 52 ; c ; <base64> ESC \`): the terminal itself. It is
//!    the LAST rung because it depends on the terminal's settings, and a
//!    terminal that does not implement it PRINTS the sequence as text.
//!
//! ## The decision is made BEFORE the copy runs
//!
//! The plan is computed first (a probe of the PATH), and the copy then walks
//! the rungs in order until one of them accepts the process. That is what lets
//! the message name the rung that was used: "copied!" in the dark is not a
//! confirmation, it is a hope.
//!
//! ## The child is NOT waited for
//!
//! `xclip` stays alive as the owner of the selection (that is how it works:
//! the process that owns the clipboard is the one serving it), so waiting for
//! it would hang zode forever — and at exit it would add the `waitWorkers`
//! budget to every session that ever copied something. The child is left for
//! the OS, and zode goes on.
//!
//! The text goes in through the PIPE, never through the command line: an
//! answer can be 200 KB, and a command line is also a place where a `$` or a
//! backtick would be an injection.

const std = @import("std");

pub const Method = enum {
    native,
    tmux,
    osc52,

    /// How the message names it. The OSC 52 one says "best effort" because it
    /// is: the terminal may ignore it, and it may print it.
    pub fn phrase(self: Method) []const u8 {
        return switch (self) {
            .native => "the system clipboard",
            .tmux => "tmux's paste buffer",
            .osc52 => "OSC 52 (best effort — your terminal may ignore it)",
        };
    }
};

pub const Decision = struct {
    method: Method,
    /// The program that does the copy, for the message. Empty for OSC 52.
    tool: []const u8 = "",
};

/// The native tools, in the order they are tried.
///
/// Wayland first (it is the one that has to be there on a modern desktop),
/// then the two X11 ones, then macOS. A tool that is not installed is simply
/// not in the plan.
pub const native_tools = [_][]const u8{ "wl-copy", "xclip", "xsel", "pbcopy" };

/// "Is this program available?" — a parameter, so the plan can be tested
/// without a PATH and without a filesystem.
pub const Probe = struct {
    ctx: ?*const anyopaque = null,
    func: *const fn (?*const anyopaque, []const u8) bool,

    pub fn call(self: Probe, tool: []const u8) bool {
        return self.func(self.ctx, tool);
    }
};

/// The rungs, in the order they will be tried.
pub const Plan = struct {
    /// The native tools that are there, in order. A fixed array: there are
    /// four candidates and the plan lives for one copy, so there is nothing
    /// here that needs an allocator.
    native: [native_tools.len][]const u8 = undefined,
    native_len: usize = 0,
    /// Is tmux's buffer available?
    tmux: bool = false,

    /// The native tools that are there.
    pub fn nativeTools(self: *const Plan) []const []const u8 {
        return self.native[0..self.native_len];
    }

    /// The first rung that will be tried. It is what the message names when
    /// the copy goes through without asking anything.
    pub fn first(self: Plan) Decision {
        if (self.native_len > 0) return .{ .method = .native, .tool = self.native[0] };
        if (self.tmux) return .{ .method = .tmux, .tool = "tmux" };
        return .{ .method = .osc52 };
    }
};

/// The plan, from the environment and a probe. PURE: nothing is spawned and
/// nothing is read; the probe is what touches the filesystem.
pub fn plan(env: ?*const std.process.Environ.Map, probe: Probe) Plan {
    var p: Plan = .{};
    for (native_tools) |tool| {
        if (!probe.call(tool)) continue;
        if (p.native_len >= p.native.len) break;
        p.native[p.native_len] = tool;
        p.native_len += 1;
    }
    if (env) |e| {
        // `$TMUX` is set by tmux itself in every pane it creates.
        if (e.get("TMUX")) |v| {
            if (v.len > 0 and probe.call("tmux")) p.tmux = true;
        }
    }
    return p;
}

/// The probe that looks for the program in the PATH.
///
/// It checks that the file EXISTS and is EXECUTABLE: a `wl-copy` that is not
/// executable is a `wl-copy` that cannot be run, and the copy would fail on
/// the rung that was supposed to be the reliable one.
const PathFinder = struct {
    io: std.Io,
    env: *const std.process.Environ.Map,
};

fn pathExists(ctx: ?*const anyopaque, tool: []const u8) bool {
    const finder: *const PathFinder = @ptrCast(@alignCast(ctx orelse return false));
    const path = finder.env.get("PATH") orelse return false;
    var it = std.mem.splitScalar(u8, path, ':');
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, tool }) catch continue;
        const st = std.Io.Dir.cwd().statFile(finder.io, full, .{}) catch continue;
        if (st.kind != .file and st.kind != .sym_link) continue;
        if (comptime std.Io.File.Permissions.has_executable_bit) {
            // A file that cannot be executed is not a tool: the copy would
            // fail on the rung that was supposed to be the reliable one.
            if (st.permissions.toMode() & 0o111 == 0) continue;
        }
        return true;
    }
    return false;
}

/// The plan for the REAL environment: the PATH of the process.
pub fn planFor(io: std.Io, env: *const std.process.Environ.Map) Plan {
    var finder: PathFinder = .{ .io = io, .env = env };
    return plan(env, .{ .ctx = @ptrCast(&finder), .func = pathExists });
}

/// The copy itself: walks the rungs and returns the one that took the text.
///
/// It returns `.osc52` when nothing else worked: that is not a failure, it is
/// the last rung, and the caller emits the escape sequence through the
/// render.
pub fn copy(io: std.Io, p: Plan, text: []const u8) Decision {
    for (p.nativeTools()) |tool| {
        if (spawnTool(io, tool, text, .{})) return .{ .method = .native, .tool = tool };
    }
    if (p.tmux) {
        if (spawnTool(io, "tmux", text, .{
            .extra = &.{ "load-buffer", "-w", "-" },
        })) return .{ .method = .tmux, .tool = "tmux" };
    }
    return .{ .method = .osc52 };
}

const SpawnExtras = struct {
    /// The arguments AFTER the program name.
    extra: []const []const u8 = &.{},
};

/// Spawns `tool` with `text` on its standard input.
///
/// The child is NOT waited for (see the note at the top of the file).
fn spawnTool(io: std.Io, tool: []const u8, text: []const u8, extras: SpawnExtras) bool {
    var argv: [5][]const u8 = undefined;
    var n: usize = 0;
    argv[n] = tool;
    n += 1;
    for (extras.extra) |a| {
        if (n >= argv.len) break;
        argv[n] = a;
        n += 1;
    }
    // The X11 tools need to be told WHICH selection they own; Wayland's and
    // macOS's have only one.
    if (std.mem.eql(u8, tool, "xclip")) {
        argv[n] = "-selection";
        n += 1;
        argv[n] = "clipboard";
        n += 1;
    } else if (std.mem.eql(u8, tool, "xsel")) {
        argv[n] = "--clipboard";
        n += 1;
        argv[n] = "--input";
        n += 1;
    }

    var child = std.process.spawn(io, .{
        .argv = argv[0..n],
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;

    if (child.stdin) |in| {
        var buf: [4096]u8 = undefined;
        var w = in.writer(io, &buf);
        w.interface.writeAll(text) catch {};
        w.interface.flush() catch {};
        in.close(io);
        // `stdin` must be null before `wait`/`kill`: they assert it, and the
        // pipe is closed already.
        child.stdin = null;
    }
    return true;
}

/// Where the copy is ALSO written, so there is a file even when the clipboard
/// did not take it.
///
/// `TMPDIR` (or `TMP`) when it is set, `/tmp` otherwise. The slice points at
/// the environment map, so the caller copies it if it keeps it.
pub fn copyDir(env: ?*const std.process.Environ.Map) []const u8 {
    if (env) |e| {
        if (e.get("TMPDIR")) |v| {
            if (v.len > 0) return v;
        }
        if (e.get("TMP")) |v| {
            if (v.len > 0) return v;
        }
    }
    return "/tmp";
}

// ── tests ─────────────────────────────────────────────────────────────────

const t = std.testing;

/// The programs the test probe pretends are installed.
///
/// A global because the probe's context is a raw pointer: it has to point at
/// something that outlives the call, and a parameter's address does not.
var probe_available: []const []const u8 = &.{};

fn probeWith(available: []const []const u8) Probe {
    probe_available = available;
    return .{ .ctx = @ptrCast(&probe_available), .func = probeAvailable };
}

fn probeAvailable(ctx: ?*const anyopaque, tool: []const u8) bool {
    const list: *const []const []const u8 = @ptrCast(@alignCast(ctx orelse return false));
    for (list.*) |a| {
        if (std.mem.eql(u8, a, tool)) return true;
    }
    return false;
}

test "the plan prefers a native tool, and the order is the one that matters" {
    var map: std.process.Environ.Map = .init(t.allocator);
    defer map.deinit();

    // Nothing installed and no tmux: the terminal does it.
    const bare = plan(&map, probeWith(&.{}));
    try t.expectEqual(Method.osc52, bare.first().method);

    // One native tool: that one, and not the terminal.
    const one = plan(&map, probeWith(&.{"xclip"}));
    try t.expectEqual(Method.native, one.first().method);
    try t.expectEqualStrings("xclip", one.first().tool);

    // Two: the FIRST of the list wins, and the list keeps the order of
    // `native_tools` (Wayland before X11 before macOS), not the order the
    // probe happened to answer in.
    const two = plan(&map, probeWith(&.{"pbcopy", "wl-copy"}));
    try t.expectEqualStrings("wl-copy", two.first().tool);
    try t.expectEqual(@as(usize, 2), two.native_len);
}

test "tmux's buffer is the second rung, and only inside tmux" {
    var map: std.process.Environ.Map = .init(t.allocator);
    defer map.deinit();

    // $TMUX unset: tmux is not there, even if the binary is.
    const outside = plan(&map, probeWith(&.{"tmux"}));
    try t.expectEqual(Method.osc52, outside.first().method);

    // $TMUX set and the binary there: the buffer.
    try map.put("TMUX", "/tmp/tmux-1000/default,1234,0");
    const inside = plan(&map, probeWith(&.{"tmux"}));
    try t.expectEqual(Method.tmux, inside.first().method);
    try t.expectEqualStrings("tmux", inside.first().tool);

    // $TMUX set but the binary missing: the terminal.
    const no_bin = plan(&map, probeWith(&.{}));
    try t.expectEqual(Method.osc52, no_bin.first().method);
}

test "an empty $TMUX is not tmux" {
    var map: std.process.Environ.Map = .init(t.allocator);
    defer map.deinit();
    try map.put("TMUX", "");
    const p = plan(&map, probeWith(&.{"tmux"}));
    try t.expectEqual(Method.osc52, p.first().method);
}

test "no environment at all is the last rung, not a crash" {
    const p = plan(null, probeWith(&.{}));
    try t.expectEqual(Method.osc52, p.first().method);
}

test "copyDir: TMPDIR wins, and /tmp is the floor" {
    var map: std.process.Environ.Map = .init(t.allocator);
    defer map.deinit();
    try t.expectEqualStrings("/tmp", copyDir(null));
    try t.expectEqualStrings("/tmp", copyDir(&map));
    try map.put("TMPDIR", "/var/tmp");
    try t.expectEqualStrings("/var/tmp", copyDir(&map));
    // An empty TMPDIR is not a directory.
    try map.put("TMPDIR", "");
    try t.expectEqualStrings("/tmp", copyDir(&map));
}

test "the method says what it did, and OSC 52 says it is best effort" {
    try t.expect(std.mem.indexOf(u8, Method.osc52.phrase(), "best effort") != null);
    try t.expect(std.mem.indexOf(u8, Method.native.phrase(), "clipboard") != null);
    try t.expect(std.mem.indexOf(u8, Method.tmux.phrase(), "tmux") != null);
}
