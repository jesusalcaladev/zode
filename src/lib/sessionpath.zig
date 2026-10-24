//! Cross-platform session storage paths.
//!
//! Precedence:
//! 1. `ZODE_SESSIONS_DIR` (explicit override)
//! 2. `<project>/sessions` (legacy, for backward compatibility with `--resume`)
//! 3. `<state>/sessions/<hash>` (XDG on Linux/macOS, AppData on Windows)

const std = @import("std");

/// The project's sessions directory name (legacy, relative to project root).
pub const legacy_sessions_dir: []const u8 = "sessions";

/// Directory permissions: owner-only.
pub const sessions_dir_mode: std.Io.File.Permissions = @enumFromInt(0o700);

/// Session file permissions: owner-only.
pub const session_mode: std.Io.File.Permissions = @enumFromInt(0o600);

/// OS tag for pure, testable path logic.
pub const OsTag = enum { linux, macos, windows };

/// Returns the state directory for the current OS (Linux: XDG_STATE_HOME, macOS: ~/Library/Application Support, Windows: %LOCALAPPDATA%).
pub fn stateDir(arena: std.mem.Allocator, env: std.process.Environ.Map) ![]u8 {
    return stateDirFor(.linux, arena, env);
}

/// Pure, parameterized by OS tag so Linux/macOS/Windows rules are testable on Linux.
pub fn stateDirFor(os: OsTag, arena: std.mem.Allocator, env: std.process.Environ.Map) ![]u8 {
    switch (os) {
        .linux => {
            // $XDG_STATE_HOME/zode, or ~/.local/state/zode
            if (env.get("XDG_STATE_HOME")) |xdg| {
                return std.fs.path.join(arena, &.{ xdg, "zode" });
            }
            if (env.get("HOME")) |home| {
                return std.fs.path.join(arena, &.{ home, ".local", "state", "zode" });
            }
            return error.NoStateDir;
        },
        .macos => {
            // ~/Library/Application Support/zode
            if (env.get("HOME")) |home| {
                return std.fs.path.join(arena, &.{ home, "Library", "Application Support", "zode" });
            }
            return error.NoStateDir;
        },
        .windows => {
            // %LOCALAPPDATA%\zode
            if (env.get("LOCALAPPDATA")) |appdata| {
                return std.fs.path.join(arena, &.{ appdata, "zode" });
            }
            return error.NoStateDir;
        },
    }
}

/// Computes a SHA-256 hash of the project root path, returns first 16 hex chars.
pub fn projectHash(arena: std.mem.Allocator, project_root: []const u8) ![]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha256.hash(project_root, &hash);
    const hex_len = 16 * 2;
    var out = try arena.alloc(u8, hex_len);
    for (0..16) |i| {
        std.fmt.bufPrint(out[i * 2 .. i * 2 + 2], "{x:0>2}", .{hash[i]}) catch unreachable;
    }
    return out;
}

/// Returns the legacy project-local sessions directory (`<project>/sessions`).
pub fn projectSessionsDir(arena: std.mem.Allocator, project_root: []const u8) ![]u8 {
    return std.fs.path.join(arena, &.{ project_root, legacy_sessions_dir });
}

/// Returns the index file path (`<state>/index.json`).
pub fn indexPath(arena: std.mem.Allocator, state_dir: []const u8) ![]u8 {
    return std.fs.path.join(arena, &.{ state_dir, "index.json" });
}

/// Resolves the sessions directory with precedence:
/// 1. ZODE_SESSIONS_DIR
/// 2. Existing `<project>/sessions` (legacy)
/// 3. `<state>/sessions/<hash>`
pub fn resolveSessionsDir(
    arena: std.mem.Allocator,
    io: std.Io,
    env: std.process.Environ.Map,
    project_root: []const u8,
) ![]u8 {
    // 1. Explicit override
    if (env.get("ZODE_SESSIONS_DIR")) |override| {
        return arena.dupe(u8, override);
    }

    // 2. Legacy project-local sessions dir (if it exists)
    const legacy = try projectSessionsDir(arena, project_root);
    const st = io.cwd().statFile(io, legacy, .{});
    if (st) |s| {
        if (s.kind == .directory) {
            return legacy;
        }
    }

    // 3. XDG/state dir with project hash
    const state = try stateDir(arena, env);
    const sessions_base = try std.fs.path.join(arena, &.{ state, "sessions" });
    // Ensure the base exists
    _ = try io.cwd().createDirPathStatus(io, sessions_base, sessions_dir_mode);
    const hash = try projectHash(arena, project_root);
    return std.fs.path.join(arena, &.{ sessions_base, hash });
}

/// Joins path components with the platform separator.
pub fn joinSep(arena: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    return std.fs.path.join(arena, parts);
}

// ── tests ─────────────────────────────────────────────────────

const t = std.testing;

test "projectHash: stable and 16 hex chars" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const h1 = try projectHash(arena, "/home/user/project");
    try t.expectEqual(32, h1.len);
    try t.expect(std.mem.eql(u8, h1, try projectHash(arena, "/home/user/project")));
}

test "projectHash: different paths produce different hashes" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const h1 = try projectHash(arena, "/home/user/project");
    const h2 = try projectHash(arena, "/home/user/other");
    try t.expect(!std.mem.eql(u8, h1, h2));
}

test "stateDirFor: Linux uses XDG_STATE_HOME" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env_map = std.process.Environ.Map.init(arena);
    defer env_map.deinit();
    try env_map.put("XDG_STATE_HOME", "/custom/state");
    try env_map.put("HOME", "/home/user");

    const dir = try stateDirFor(.linux, arena, env_map);
    try t.expectEqualStrings("/custom/state/zode", dir);
}

test "stateDirFor: Linux falls back to ~/.local/state/zode" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env_map = std.process.Environ.Map.init(arena);
    defer env_map.deinit();
    try env_map.put("HOME", "/home/user");

    const dir = try stateDirFor(.linux, arena, env_map);
    try t.expectEqualStrings("/home/user/.local/state/zode", dir);
}

test "stateDirFor: macOS uses ~/Library/Application Support" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env_map = std.process.Environ.Map.init(arena);
    defer env_map.deinit();
    try env_map.put("HOME", "/Users/user");

    const dir = try stateDirFor(.macos, arena, env_map);
    try t.expectEqualStrings("/Users/user/Library/Application Support/zode", dir);
}

test "stateDirFor: Windows uses %LOCALAPPDATA%" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env_map = std.process.Environ.Map.init(arena);
    defer env_map.deinit();
    try env_map.put("LOCALAPPDATA", "C:\\Users\\user\\AppData\\Local");

    const dir = try stateDirFor(.windows, arena, env_map);
    try t.expectEqualStrings("C:\\Users\\user\\AppData\\Local\\zode", dir);
}

test "resolveSessionsDir: precedence works" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env_map = std.process.Environ.Map.init(arena);
    defer env_map.deinit();
    try env_map.put("HOME", "/home/user");
    try env_map.put("ZODE_SESSIONS_DIR", "/explicit/sessions");

    const io = std.io.getStdOut().io();
    const dir = try resolveSessionsDir(arena, io, env_map, "/home/user/project");
    try t.expectEqualStrings("/explicit/sessions", dir);
}