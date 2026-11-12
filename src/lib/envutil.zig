const std = @import("std");

pub fn get(env: ?*const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const m = env orelse return null;
    return m.get(key);
}

/// Env var as boolean from an explicit map (case-insensitive falsey values).
pub fn truthyIn(env: ?*const std.process.Environ.Map, key: []const u8, default: bool) bool {
    const raw = get(env, key) orelse return default;
    if (raw.len == 0) return default;
    if (std.mem.eql(u8, raw, "0") or std.ascii.eqlIgnoreCase(raw, "false") or
        std.ascii.eqlIgnoreCase(raw, "no") or std.ascii.eqlIgnoreCase(raw, "off"))
    {
        return false;
    }
    return true;
}

pub fn iterationLimitFor(
    env: ?*const std.process.Environ.Map,
    default_max: usize,
    iter_limit_override: usize,
    model_requested_iter: usize,
) usize {
    var best: usize = default_max;
    const raw = get(env, "ZODE_MAX_ITER") orelse "";
    if (raw.len > 0) {
        const n = std.fmt.parseInt(usize, raw, 10) catch default_max;
        if (n > best) best = n;
    }
    if (iter_limit_override > best) best = iter_limit_override;
    if (model_requested_iter > best) best = model_requested_iter;
    if (best < 8) best = 8;
    return best;
}

test "truthyIn" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try std.testing.expect(truthyIn(&map, "X", true));
    try map.put("X", "0");
    try std.testing.expect(!truthyIn(&map, "X", true));
    try map.put("X", "OFF");
    try std.testing.expect(!truthyIn(&map, "X", true));
    try map.put("X", "1");
    try std.testing.expect(truthyIn(&map, "X", false));
}


/// Reads `KEY=VALUE` pairs from `.env` into `map`.
/// `.env` is gitignored; `put` dupes both sides so the read buffer can be freed.
pub fn loadDotEnv(io: std.Io, map: *std.process.Environ.Map) void {
    const data = std.Io.Dir.cwd().readFileAlloc(io, ".env", std.heap.page_allocator, .limited(64 * 1024)) catch return;
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
