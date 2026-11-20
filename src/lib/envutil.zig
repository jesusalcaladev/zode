const std = @import("std");

fn get(env: ?*const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const m = env orelse return null;
    return m.get(key);
}

/// Reads `KEY=VALUE` pairs from `.env` in the current directory into `map`.
/// `.env` is gitignored; `put` dupes both sides so the read buffer can be freed.
pub fn loadDotEnv(io: std.Io, map: *std.process.Environ.Map) void {
    loadDotEnvIn(io, std.Io.Dir.cwd(), map);
}

/// Same, with an explicit directory so the parser can be tested without
/// changing the process cwd (which would race other tests).
pub fn loadDotEnvIn(io: std.Io, dir: std.Io.Dir, map: *std.process.Environ.Map) void {
    const data = dir.readFileAlloc(io, ".env", std.heap.page_allocator, .limited(64 * 1024)) catch return;
    defer std.heap.page_allocator.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const bare = if (std.mem.startsWith(u8, trimmed, "export ")) trimmed["export ".len..] else trimmed;
        const eq = std.mem.indexOfScalar(u8, bare, '=') orelse continue;
        const key = std.mem.trim(u8, bare[0..eq], " \t");
        const val = std.mem.trim(u8, bare[eq + 1 ..], " \t\"'");
        if (key.len == 0) continue;
        map.put(key, val) catch return;
    }
}

/// Whether the map holds any credential at all: generic `ZODE_API_KEY` or any
/// provider `*_KEY`.
pub fn envHasAnyKey(map: *const std.process.Environ.Map) bool {
    if (map.get("ZODE_API_KEY") != null) return true;
    var it = map.iterator();
    while (it.next()) |entry| {
        if (std.mem.endsWith(u8, entry.key_ptr.*, "_KEY")) return true;
    }
    return false;
}

/// Should the app reopen the last session at startup?
/// `--resume` flag or `ZODE_RESUME=1` enables it; env cannot disable the flag.
pub fn shouldResume(flag: bool, env: ?*const std.process.Environ.Map) bool {
    if (flag) return true;
    return std.mem.eql(u8, get(env, "ZODE_RESUME") orelse "", "1");
}


test "envHasAnyKey: a generic key or any provider *_KEY counts, other names do not" {
    const a = std.testing.allocator;
    var empty: std.process.Environ.Map = .init(a);
    defer empty.deinit();
    try std.testing.expect(!envHasAnyKey(&empty));

    try empty.put("ZODE_FREE_AUTO", "1");
    try empty.put("HOME", "/home/u");
    try empty.put("OPENAI_SOMETHING", "x");
    try std.testing.expect(!envHasAnyKey(&empty));

    try empty.put("ANTHROPIC_KEY", "secret");
    try std.testing.expect(envHasAnyKey(&empty));

    var generic: std.process.Environ.Map = .init(a);
    defer generic.deinit();
    try generic.put("ZODE_API_KEY", "secret");
    try std.testing.expect(envHasAnyKey(&generic));
}

test "shouldResume: the --resume flag wins, env only enables" {
    const a = std.testing.allocator;
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();

    // Neither: off.
    try std.testing.expect(!shouldResume(false, &env));
    try std.testing.expect(!shouldResume(false, null));

    // Env enables.
    try env.put("ZODE_RESUME", "1");
    try std.testing.expect(shouldResume(false, &env));
    try env.put("ZODE_RESUME", "0");
    try std.testing.expect(!shouldResume(false, &env));

    // The flag enables even with env explicitly off or absent — the flag
    // cannot be disabled from the environment.
    try std.testing.expect(shouldResume(true, &env));
    try std.testing.expect(shouldResume(true, null));
}


test "loadDotEnvIn: comments, blank lines, export, quotes and empty values" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Under .zig-cache so the suite leaves nothing in the repo root.
    const root = ".zig-cache/envutil-test";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);

    const dotenv =
        "  # a comment\n" ++
        "\n" ++
        "export ZODE_MODEL=kimi-k2.6\n" ++
        "  ZODE_API_KEY = \"secret\"  \n" ++
        "EMPTY=\n" ++
        "NO_EQUALS\n" ++
        "=nokeyn\n" ++
        "ZODE_EFFORT='high'\n";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/.env", .data = dotenv });

    var dir = try std.Io.Dir.cwd().openDir(io, root, .{});
    defer dir.close(io);

    var map: std.process.Environ.Map = .init(std.testing.allocator);
    defer map.deinit();
    loadDotEnvIn(io, dir, &map);

    try std.testing.expectEqualStrings("kimi-k2.6", map.get("ZODE_MODEL").?);
    try std.testing.expectEqualStrings("secret", map.get("ZODE_API_KEY").?);
    try std.testing.expectEqualStrings("", map.get("EMPTY").?);
    try std.testing.expectEqualStrings("high", map.get("ZODE_EFFORT").?);
    try std.testing.expect(map.get("NO_EQUALS") == null);
    try std.testing.expect(map.get("") == null);
    try std.testing.expect(envHasAnyKey(&map));
}
