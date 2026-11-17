//! Remote sessions (Phase 13.2). Pure config, index parsing and sync planning.
//! The `remote` tool owns the HTTP and filesystem IO; everything that can be
//! decided without a network is here and tested.
//!
//! Contract: a remote is any HTTP endpoint that serves
//!   GET  {url}/sessions                    -> [{"id": "...", "size": N, "updated": "..."}]
//!   GET  {url}/sessions/{id}               -> raw .jsonl bytes
//!   PUT  {url}/sessions/{id}               -> raw .jsonl bytes
//! An optional bearer token authenticates all three. The token never appears
//! in a finding, log line or error message — only in the request header.

const std = @import("std");

pub const Config = struct {
    url: []const u8 = "",
    token: ?[]const u8 = null,
    enabled: bool = false,

    pub fn fromEnv(env: ?*const std.process.Environ.Map) Config {
        const m = env orelse return .{};
        const url = m.get("ZODE_REMOTE_URL") orelse return .{};
        if (url.len == 0) return .{};
        return .{
            .url = std.mem.trimEnd(u8, url, "/"),
            .token = m.get("ZODE_REMOTE_TOKEN"),
            .enabled = true,
        };
    }

    pub fn endpoint(self: Config, gpa: std.mem.Allocator, id: ?[]const u8) ![]u8 {
        if (id) |name| {
            return std.fmt.allocPrint(gpa, "{s}/sessions/{s}", .{ self.url, name });
        }
        return std.fmt.allocPrint(gpa, "{s}/sessions", .{self.url});
    }

    pub fn valid(self: Config) bool {
        return validateUrl(self.url);
    }
};

/// Only plain http(s) URLs are accepted. Rejects embedded credentials and
/// whitespace so a typo in the env cannot turn into an odd request.
pub fn validateUrl(url: []const u8) bool {
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) return false;
    if (std.mem.indexOfScalar(u8, url, '@') != null) return false;
    for (url) |c| {
        if (std.ascii.isWhitespace(c) or std.ascii.isControl(c)) return false;
    }
    const scheme_end = std.mem.indexOf(u8, url, "://").? + 3;
    return scheme_end < url.len;
}

pub const SessionRef = struct {
    id: []const u8,
    size: u64 = 0,
    updated: []const u8 = "",
};

/// Parse the JSON index. A malformed entry is skipped, not fatal: one bad
/// session must not hide the rest of the list.
pub fn parseIndex(gpa: std.mem.Allocator, body: []const u8) ![]SessionRef {
    var out: std.ArrayList(SessionRef) = .empty;
    errdefer out.deinit(gpa);
    const value = std.json.parseFromSliceLeaky(std.json.Value, gpa, body, .{}) catch return try out.toOwnedSlice(gpa);
    if (value != .array) return try out.toOwnedSlice(gpa);
    for (value.array.items) |item| {
        if (item != .object) continue;
        const id_v = item.object.get("id") orelse continue;
        if (id_v != .string or id_v.string.len == 0) continue;
        var size: u64 = 0;
        if (item.object.get("size")) |v| {
            if (v == .integer and v.integer >= 0) size = @intCast(v.integer);
        }
        var updated: []const u8 = "";
        if (item.object.get("updated")) |v| {
            if (v == .string) updated = v.string;
        }
        try out.append(gpa, .{ .id = id_v.string, .size = size, .updated = updated });
    }
    return try out.toOwnedSlice(gpa);
}

/// A remote id becomes a local filename, so it must not contain a path
/// separator, a dot or any control byte. Local zode ids are 8 base32 chars;
/// remote servers may use any safe token, so allow a slightly wider alphabet.
pub fn validSessionId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    }
    return true;
}

pub const ConflictPolicy = enum { skip, prefer_local, prefer_remote };

pub const Action = enum { pull, push, skip };

pub const PlanItem = struct {
    id: []const u8,
    action: Action,
};

fn contains(ids: []const []const u8, id: []const u8) bool {
    for (ids) |x| if (std.mem.eql(u8, x, id)) return true;
    return false;
}

/// Decide what to do for each session. Local-only -> push, remote-only ->
/// pull, both -> the conflict policy. Order is deterministic: remote order
/// first, then local-only ids in their input order.
pub fn plan(gpa: std.mem.Allocator, local_ids: []const []const u8, remote: []const SessionRef, policy: ConflictPolicy) ![]PlanItem {
    var out: std.ArrayList(PlanItem) = .empty;
    errdefer out.deinit(gpa);
    for (remote) |r| {
        const local = contains(local_ids, r.id);
        const action: Action = if (!local)
            .pull
        else switch (policy) {
            .skip => .skip,
            .prefer_local => .push,
            .prefer_remote => .pull,
        };
        try out.append(gpa, .{ .id = r.id, .action = action });
    }
    for (local_ids) |id| {
        if (!containsRemote(remote, id)) try out.append(gpa, .{ .id = id, .action = .push });
    }
    return try out.toOwnedSlice(gpa);
}

fn containsRemote(remote: []const SessionRef, id: []const u8) bool {
    for (remote) |r| if (std.mem.eql(u8, r.id, id)) return true;
    return false;
}

pub fn actionLabel(a: Action) []const u8 {
    return switch (a) {
        .pull => "pull",
        .push => "push",
        .skip => "skip",
    };
}

test "remote: config reads env and validates the URL" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expect(!Config.fromEnv(&env).enabled);
    try env.put("ZODE_REMOTE_URL", "http://localhost:8080/");
    try env.put("ZODE_REMOTE_TOKEN", "secret");
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const c = Config.fromEnv(&env);
    try std.testing.expect(c.enabled);
    try std.testing.expect(c.valid());
    try std.testing.expectEqualStrings("http://localhost:8080", c.url);
    try std.testing.expectEqualStrings("secret", c.token.?);
    try std.testing.expectEqualStrings("http://localhost:8080/sessions", try c.endpoint(a.allocator(), null));
    try std.testing.expectEqualStrings("http://localhost:8080/sessions/s1", try c.endpoint(a.allocator(), "s1"));
    try std.testing.expect(validateUrl("https://example.com"));
    try std.testing.expect(!validateUrl("ftp://example.com"));
    try std.testing.expect(!validateUrl("http://user:pass@example.com"));
}

test "remote: parse a session index, skipping malformed entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const refs = try parseIndex(a,
        \\ [{"id":"s1","size":42,"updated":"t1"},{"id":""},{"id":"s2"},"junk"]
    );
    try std.testing.expectEqual(@as(usize, 2), refs.len);
    try std.testing.expectEqualStrings("s1", refs[0].id);
    try std.testing.expectEqual(@as(u64, 42), refs[0].size);
    try std.testing.expectEqualStrings("s2", refs[1].id);
}

test "remote: plan pull, push and conflict policies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const local = [_][]const u8{ "a", "b" };
    const refs = [_]SessionRef{
        .{ .id = "b" },
        .{ .id = "c" },
    };
    const skip = try plan(a, &local, &refs, .skip);
    try std.testing.expectEqual(@as(usize, 3), skip.len);
    try std.testing.expectEqual(Action.skip, skip[0].action);
    try std.testing.expectEqual(Action.pull, skip[1].action);
    try std.testing.expectEqual(Action.push, skip[2].action);
    try std.testing.expectEqualStrings("a", skip[2].id);

    const local_wins = try plan(a, &local, &refs, .prefer_local);
    try std.testing.expectEqual(Action.push, local_wins[0].action);
    const remote_wins = try plan(a, &local, &refs, .prefer_remote);
    try std.testing.expectEqual(Action.pull, remote_wins[0].action);
}

test "remote: session ids cannot escape the sessions directory" {
    try std.testing.expect(validSessionId("abc123"));
    try std.testing.expect(validSessionId("zode-id_1"));
    try std.testing.expect(!validSessionId("../../etc/passwd"));
    try std.testing.expect(!validSessionId("a/b"));
    try std.testing.expect(!validSessionId("a.jsonl"));
    try std.testing.expect(!validSessionId(""));
}
