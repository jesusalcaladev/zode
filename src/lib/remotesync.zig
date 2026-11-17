//! Remote session IO (Phase 13.2). Thin layer over the shared HTTP client:
//! fetch the index, pull a session's bytes, push a local file, and plan a
//! sync. The pure decisions are in `remote.zig`; this file only moves bytes
//! and validates every id before it touches the filesystem.

const std = @import("std");
const remote = @import("remote.zig");
const http_client = @import("http_client.zig");

pub const SyncResult = struct {
    pulled: usize = 0,
    pushed: usize = 0,
    skipped: usize = 0,
};

fn bearer(cfg: remote.Config) ?[]const u8 {
    return cfg.token;
}

/// GET {url}/sessions -> parsed index. A non-2xx is a named error so the
/// command can say what the server answered without leaking the token.
pub fn fetchIndex(gpa: std.mem.Allocator, io: std.Io, cfg: remote.Config) ![]remote.SessionRef {
    if (!cfg.valid()) return error.BadRemoteUrl;
    const url = try cfg.endpoint(gpa, null);
    defer gpa.free(url);
    var http = http_client.Http.init(gpa, io);
    defer http.deinit();
    const res = try http.get(url, bearer(cfg));
    defer gpa.free(res.body);
    if (res.status < 200 or res.status >= 300) return error.RemoteRejected;
    return remote.parseIndex(gpa, res.body);
}

pub fn fetchSession(gpa: std.mem.Allocator, io: std.Io, cfg: remote.Config, id: []const u8) ![]u8 {
    if (!remote.validSessionId(id)) return error.BadSessionId;
    const url = try cfg.endpoint(gpa, id);
    defer gpa.free(url);
    var http = http_client.Http.init(gpa, io);
    defer http.deinit();
    const res = try http.get(url, bearer(cfg));
    if (res.status < 200 or res.status >= 300) {
        gpa.free(res.body);
        return error.RemoteRejected;
    }
    return res.body;
}

pub fn uploadSession(gpa: std.mem.Allocator, io: std.Io, cfg: remote.Config, id: []const u8, data: []const u8) !u16 {
    if (!remote.validSessionId(id)) return error.BadSessionId;
    const url = try cfg.endpoint(gpa, id);
    defer gpa.free(url);
    const body = try gpa.dupe(u8, data); // sendBodyComplete needs a mutable slice
    defer gpa.free(body);
    var http = http_client.Http.init(gpa, io);
    defer http.deinit();
    const res = try http.put(url, bearer(cfg), body);
    defer gpa.free(res.body);
    return res.status;
}

/// List the ids of local `zode-*.jsonl` files in a sessions directory.
pub fn localIds(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |id| gpa.free(id);
        out.deinit(gpa);
    }
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return try out.toOwnedSlice(gpa);
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "zode-") or !std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const id = entry.name["zode-".len .. entry.name.len - ".jsonl".len];
        if (!remote.validSessionId(id)) continue;
        try out.append(gpa, try gpa.dupe(u8, id));
    }
    return try out.toOwnedSlice(gpa);
}

pub fn freeIds(gpa: std.mem.Allocator, ids: []const []const u8) void {
    for (ids) |id| gpa.free(id);
    gpa.free(ids);
}

pub fn sessionPath(gpa: std.mem.Allocator, dir_path: []const u8, id: []const u8) ![]u8 {
    if (!remote.validSessionId(id)) return error.BadSessionId;
    return std.fmt.allocPrint(gpa, "{s}/zode-{s}.jsonl", .{ dir_path, id });
}

pub fn writeSession(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8, id: []const u8, data: []const u8) !void {
    const path = try sessionPath(gpa, dir_path, id);
    defer gpa.free(path);
    // A session is the whole conversation: an interrupted pull must not leave
    // a half-written file. Write a private temp file, then rename atomically.
    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = data, .flags = .{ .permissions = @fromBackingInt(@intCast(0o600)) } });
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    try std.Io.Dir.rename(.cwd(), tmp, .cwd(), path, io);
}

pub fn readSession(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8, id: []const u8) ![]u8 {
    const path = try sessionPath(gpa, dir_path, id);
    defer gpa.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024));
}

/// Apply a plan. Local files are never overwritten by a pull unless the
/// policy says `prefer_remote`; pushes never delete local data.
pub fn applyPlan(
    gpa: std.mem.Allocator,
    io: std.Io,
    cfg: remote.Config,
    dir_path: []const u8,
    items: []const remote.PlanItem,
) !SyncResult {
    var result: SyncResult = .{};
    for (items) |item| {
        switch (item.action) {
            .skip => result.skipped += 1,
            .pull => {
                const data = fetchSession(gpa, io, cfg, item.id) catch continue;
                defer gpa.free(data);
                writeSession(gpa, io, dir_path, item.id, data) catch continue;
                result.pulled += 1;
            },
            .push => {
                const data = readSession(gpa, io, dir_path, item.id) catch continue;
                defer gpa.free(data);
                const status = uploadSession(gpa, io, cfg, item.id, data) catch continue;
                if (status >= 200 and status < 300) result.pushed += 1 else result.skipped += 1;
            },
        }
    }
    return result;
}

test "remotesync: local session ids are listed and ids cannot escape" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "zode-abc12345.jsonl", .data = "line\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "not-a-session.txt", .data = "x" });
    const ids = try localIds(std.testing.allocator, std.testing.io, root);
    defer freeIds(std.testing.allocator, ids);
    try std.testing.expectEqual(@as(usize, 1), ids.len);
    try std.testing.expectEqualStrings("abc12345", ids[0]);
    try std.testing.expectError(error.BadSessionId, sessionPath(std.testing.allocator, root, "../escape"));
}
