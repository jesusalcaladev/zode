//! Cross-platform session storage paths.
//!
//! WHERE a project's sessions live, in order of precedence:
//!
//! 1. `ZODE_SESSIONS_DIR` — an explicit override, for tests and for anyone who
//!    wants them somewhere else.
//! 2. `<project>/sessions` — the LEGACY location, used only if it already
//!    exists. Every repo that has been used with zode before this module has
//!    one, and `--resume` reads it: moving those sessions out from under the
//!    user would be "my history disappeared" for no benefit.
//! 3. `<state>/sessions/<hash>` — new projects. `<state>` is
//!    `$XDG_STATE_HOME/zode` (or `~/.local/state/zode`) on Linux,
//!    `~/Library/Application Support/zode` on macOS, and `%LOCALAPPDATA%\zode`
//!    on Windows, which is the convention each of those systems has for
//!    "state that is not config and not cache".
//!
//! The hash is of the project ROOT, not of the working directory: two sessions
//! started from different subdirectories of one repo are the same project, and
//! a hash of the cwd would split them into two histories nobody can find.
//!
//! Nothing here creates directories: it answers "where", and a resolver with
//! side effects gets called from places (drawing the status row, listing
//! sessions) that must not write to disk.

const std = @import("std");
const builtin = @import("builtin");

/// Directory name of the legacy, project-local sessions dir.
pub const legacy_sessions_dir: []const u8 = "sessions";

/// Directory permissions: owner-only. The NAMES of every session are in there.
pub const sessions_dir_mode: std.Io.File.Permissions = @enumFromInt(0o700);

/// Session file permissions: owner-only.
pub const session_mode: std.Io.File.Permissions = @enumFromInt(0o600);

/// OS tag: parameterized so the three rules are testable on any one of them.
pub const OsTag = enum { linux, macos, windows };

pub fn currentOs() OsTag {
    return switch (builtin.os.tag) {
        .windows => .windows,
        .macos => .macos,
        else => .linux,
    };
}

/// `<state>/zode` for the OS we are running on.
pub fn stateDir(arena: std.mem.Allocator, env: ?*const std.process.Environ.Map) ![]u8 {
    return stateDirFor(currentOs(), arena, env);
}

/// `<state>/zode` for a given OS. The three systems disagree about where
/// "state that is not config" goes, and the difference is not cosmetic: on
/// Windows there is no `$XDG_STATE_HOME`, and hardcoding a `~/.local/state`
/// would put the sessions in a directory Explorer never shows.
pub fn stateDirFor(os: OsTag, arena: std.mem.Allocator, env: ?*const std.process.Environ.Map) ![]u8 {
    const m = env orelse return error.NoStateDir;
    switch (os) {
        .linux => {
            if (m.get("XDG_STATE_HOME")) |xdg| {
                if (xdg.len > 0) return std.fs.path.join(arena, &.{ xdg, "zode" });
            }
            const home = m.get("HOME") orelse return error.NoStateDir;
            if (home.len == 0) return error.NoStateDir;
            return std.fs.path.join(arena, &.{ home, ".local", "state", "zode" });
        },
        .macos => {
            const home = m.get("HOME") orelse return error.NoStateDir;
            if (home.len == 0) return error.NoStateDir;
            return std.fs.path.join(arena, &.{ home, "Library", "Application Support", "zode" });
        },
        .windows => {
            if (m.get("LOCALAPPDATA")) |appdata| {
                if (appdata.len > 0) return std.fs.path.join(arena, &.{ appdata, "zode" });
            }
            return error.NoStateDir;
        },
    }
}

/// A stable, filesystem-safe name for one project: the first 16 bytes of the
/// SHA-256 of the project root, in hex (32 characters).
///
/// A hash and not the path itself: a path can contain `:`, spaces and 4 KB of
/// directories, and all of that has to survive as a single directory name.
pub fn projectHash(arena: std.mem.Allocator, project_root: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(project_root, &digest, .{});
    var out = try arena.alloc(u8, 32);
    for (digest[0..16], 0..) |b, i| {
        _ = std.fmt.bufPrint(out[i * 2 .. i * 2 + 2], "{x:0>2}", .{b}) catch unreachable;
    }
    return out;
}

/// `<project>/sessions` — the legacy location. It is returned whether or not it
/// exists; `resolveSessionsDir` is the one that decides.
pub fn projectSessionsDir(arena: std.mem.Allocator, project_root: []const u8) ![]u8 {
    return std.fs.path.join(arena, &.{ project_root, legacy_sessions_dir });
}

/// Does this path exist and is it a directory?
fn isDir(io: std.Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

/// Where THIS project's sessions live. See the precedence at the top of the
/// file. The returned directory may not exist yet.
pub fn resolveSessionsDir(
    arena: std.mem.Allocator,
    io: std.Io,
    env: ?*const std.process.Environ.Map,
    project_root: []const u8,
) ![]u8 {
    if (env) |m| {
        if (m.get("ZODE_SESSIONS_DIR")) |override| {
            if (override.len > 0) return arena.dupe(u8, override);
        }
    }

    // Legacy first, and only if it is really there: an EMPTY `sessions/` left
    // behind by a stray `mkdir` must not capture every future session.
    const legacy = try projectSessionsDir(arena, project_root);
    if (isDir(io, legacy)) return legacy;

    const state = try stateDir(arena, env);
    const hash = try projectHash(arena, project_root);
    return std.fs.path.join(arena, &.{ state, "sessions", hash });
}

/// `true` if `entry_name` is a session file (`zode-<id>.jsonl`).
///
/// The check is on the name and not on the contents: listing sessions happens
/// on every `/session`, and parsing the first line of every file to answer
/// "is this one of ours" is work that the naming convention already did.
pub fn isSessionFile(entry_name: []const u8) bool {
    return std.mem.startsWith(u8, entry_name, "zode-") and std.mem.endsWith(u8, entry_name, ".jsonl");
}

// ── tests ─────────────────────────────────────────────────────

const t = std.testing;

test "projectHash: stable, 32 hex chars, different per project" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a1 = try projectHash(arena, "/home/user/project");
    const a2 = try projectHash(arena, "/home/user/project");
    const b = try projectHash(arena, "/home/user/other");
    try t.expectEqual(@as(usize, 32), a1.len);
    try t.expectEqualStrings(a1, a2);
    try t.expect(!std.mem.eql(u8, a1, b));
    // Hex only: it has to be a legal directory name on every filesystem.
    for (a1) |c| try t.expect(std.ascii.isHex(c));
}

test "stateDirFor: Linux uses XDG_STATE_HOME before HOME" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("XDG_STATE_HOME", "/custom/state");
    try env.put("HOME", "/home/user");

    try t.expectEqualStrings("/custom/state/zode", try stateDirFor(.linux, arena, &env));

    // An EMPTY XDG_STATE_HOME is the same as not set, not a path of its own.
    env.put("XDG_STATE_HOME", "") catch unreachable;
    try t.expectEqualStrings("/home/user/.local/state/zode", try stateDirFor(.linux, arena, &env));
}

test "stateDirFor: macOS and Windows use their own directories" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var mac = std.process.Environ.Map.init(t.allocator);
    defer mac.deinit();
    try mac.put("HOME", "/Users/user");
    try t.expectEqualStrings(
        "/Users/user/Library/Application Support/zode",
        try stateDirFor(.macos, arena, &mac),
    );

    var win = std.process.Environ.Map.init(t.allocator);
    defer win.deinit();
    try win.put("LOCALAPPDATA", "C:\\Users\\user\\AppData\\Local");
    // `std.fs.path.join` uses the HOST separator, so on Linux this test cannot
    // assert Windows separators. What it CAN assert is the shape: the dir is
    // under LOCALAPPDATA and called zode.
    const win_path = try stateDirFor(.windows, arena, &win);
    try t.expect(std.mem.startsWith(u8, win_path, "C:\\Users\\user\\AppData\\Local"));
    try t.expect(std.mem.endsWith(u8, win_path, "zode"));
}

test "stateDirFor: no environment is an error, not a relative path" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try t.expectError(error.NoStateDir, stateDirFor(.linux, arena, null));
}

test "resolveSessionsDir: the override wins over everything" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/user");
    try env.put("ZODE_SESSIONS_DIR", "/explicit/sessions");

    const dir = try resolveSessionsDir(arena, std.testing.io, &env, "/home/user/project");
    try t.expectEqualStrings("/explicit/sessions", dir);
}

test "resolveSessionsDir: an existing legacy dir is kept, and a new project goes to the state dir" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    // A project that already has `sessions/` (the pre-module layout).
    const old_root = try std.fmt.allocPrint(arena, ".zode-sessionpath-old-{d}", .{t.random_seed});
    defer std.Io.Dir.cwd().deleteTree(io, old_root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(arena, &.{ old_root, "sessions" }));

    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("HOME", try std.fs.path.join(arena, &.{ old_root, "home" }));

    const old_dir = try resolveSessionsDir(arena, io, &env, old_root);
    try t.expect(std.mem.endsWith(u8, old_dir, "sessions"));
    try t.expect(std.mem.startsWith(u8, old_dir, old_root));

    // A project WITHOUT one is not given a `sessions/` inside the repo: it gets
    // `<state>/sessions/<hash>`.
    const new_root = try std.fmt.allocPrint(arena, ".zode-sessionpath-new-{d}", .{t.random_seed});
    defer std.Io.Dir.cwd().deleteTree(io, new_root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, new_root);

    const new_dir = try resolveSessionsDir(arena, io, &env, new_root);
    try t.expect(std.mem.indexOf(u8, new_dir, ".local/state/zode/sessions/") != null);
    try t.expect(std.mem.endsWith(u8, new_dir, try projectHash(arena, new_root)));
}

test "isSessionFile: only zode-<id>.jsonl counts" {
    try t.expect(isSessionFile("zode-2026-10-24T10-00-00.jsonl"));
    try t.expect(!isSessionFile("zode-1.jsonl.tmp"));
    try t.expect(!isSessionFile("zode-1.meta.json"));
    try t.expect(!isSessionFile("other-1.jsonl"));
    try t.expect(!isSessionFile("sessions"));
}
