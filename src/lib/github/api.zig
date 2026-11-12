//! Minimal GitHub REST API client.
const std = @import("std");
const types = @import("types.zig");

pub const default_api_base = "https://api.github.com";
pub const api_version = "2022-11-28";

pub const Method = enum { GET, POST, PATCH, PUT, DELETE };

pub const Response = struct {
    status: u16,
    body: []u8,
    rate_remaining: ?i64 = null,
    retry_after: ?u16 = null,
    next_link: ?[]const u8 = null,
};

pub const Auth = struct {
    token: ?[]const u8 = null,
    source: []const u8 = "none",
};

fn authJsonPath(env: ?*const std.process.Environ.Map, buf: []u8) ?[]const u8 {
    const m = env orelse return null;
    const home = m.get("HOME") orelse return null;
    if (home.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}/.config/zode/auth.json", .{home}) catch null;
}

pub fn resolveToken(arena: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, host: []const u8) Auth {
    if (env) |e| {
        inline for ([_][]const u8{ "GITHUB_TOKEN", "GH_TOKEN" }) |name| {
            if (e.get(name)) |v| {
                const t = std.mem.trim(u8, v, " \t\r\n");
                if (t.len > 0) return .{ .token = arena.dupe(u8, t) catch null, .source = name };
            }
        }
    }
    var path_buf: [1024]u8 = undefined;
    const path = authJsonPath(env, &path_buf) orelse return .{};
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch return .{};
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{}) catch return .{};
    if (parsed != .object) return .{};
    const host_key = std.fmt.allocPrint(arena, "github:{s}", .{host}) catch null;
    const candidates = [_]?[]const u8{ host_key, "github", "github.com" };
    for (candidates) |ck_opt| {
        const ck = ck_opt orelse continue;
        if (parsed.object.get(ck)) |v| {
            if (v == .string) {
                const t = std.mem.trim(u8, v.string, " \t\r\n");
                if (t.len > 0) return .{ .token = arena.dupe(u8, t) catch null, .source = "auth.json" };
            }
        }
    }
    return .{};
}

pub fn isDotCom(host: []const u8) bool {
    return std.ascii.eqlIgnoreCase(host, "github.com");
}

pub fn apiBaseForHost(arena: std.mem.Allocator, host: []const u8) []const u8 {
    if (isDotCom(host)) return default_api_base;
    return std.fmt.allocPrint(arena, "https://{s}/api/v3", .{host}) catch default_api_base;
}

pub fn buildUrl(arena: std.mem.Allocator, api_base: []const u8, path: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://")) return arena.dupe(u8, path);
    const base = std.mem.trimEnd(u8, api_base, "/");
    if (path.len == 0) return arena.dupe(u8, base);
    if (path[0] == '/') return std.fmt.allocPrint(arena, "{s}{s}", .{ base, path });
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ base, path });
}

fn toHttpMethod(m: Method) std.http.Method {
    return switch (m) {
        .GET => .GET,
        .POST => .POST,
        .PATCH => .PATCH,
        .PUT => .PUT,
        .DELETE => .DELETE,
    };
}

pub fn request(arena: std.mem.Allocator, io: std.Io, method: Method, url: []const u8, token: ?[]const u8, body: ?[]const u8) !Response {
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    var auth_buf: [1024]u8 = undefined;
    @memset(&auth_buf, 0);
    defer @memset(&auth_buf, 0);
    var headers: [8]std.http.Header = undefined;
    var hlen: usize = 0;
    headers[hlen] = .{ .name = "accept", .value = "application/vnd.github+json" };
    hlen += 1;
    headers[hlen] = .{ .name = "x-github-api-version", .value = api_version };
    hlen += 1;
    headers[hlen] = .{ .name = "user-agent", .value = "zode" };
    hlen += 1;
    if (token) |t| {
        const auth_val = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{t}) catch null;
        if (auth_val) |av| {
            headers[hlen] = .{ .name = "authorization", .value = av };
            hlen += 1;
        }
    }
    if (body != null) {
        headers[hlen] = .{ .name = "content-type", .value = "application/json" };
        hlen += 1;
    }
    var req = try client.request(toHttpMethod(method), uri, .{
        .extra_headers = headers[0..hlen],
        .redirect_behavior = @enumFromInt(3),
        .headers = .{ .accept_encoding = .omit },
    });
    defer req.deinit();
    if (body) |b| {
        const mut = try arena.dupe(u8, b);
        try req.sendBodyComplete(mut);
    } else {
        try req.sendBodiless();
    }
    var redirect_buf: [8192]u8 = undefined;
    var resp = try req.receiveHead(&redirect_buf);
    const status: u16 = @intFromEnum(resp.head.status);
    const rate_remaining = parseIntHeader(resp.head, "x-ratelimit-remaining");
    const retry_after = parseRetryAfter(resp.head);
    const next_link = parseLinkNext(arena, resp.head);
    var transfer_buf: [64 * 1024]u8 = undefined;
    const reader = resp.reader(&transfer_buf);
    const resp_body = try reader.allocRemaining(arena, .limited(10 * 1024 * 1024));
    return .{
        .status = status,
        .body = resp_body,
        .rate_remaining = rate_remaining,
        .retry_after = retry_after,
        .next_link = next_link,
    };
}

fn parseIntHeader(head: anytype, name: []const u8) ?i64 {
    var it = head.iterateHeaders();
    while (it.next()) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, name)) continue;
        return std.fmt.parseInt(i64, std.mem.trim(u8, h.value, " \t"), 10) catch null;
    }
    return null;
}

fn parseRetryAfter(head: anytype) ?u16 {
    var it = head.iterateHeaders();
    while (it.next()) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "retry-after")) continue;
        return std.fmt.parseInt(u16, std.mem.trim(u8, h.value, " \t"), 10) catch null;
    }
    return null;
}

fn parseLinkNext(arena: std.mem.Allocator, head: anytype) ?[]const u8 {
    var it = head.iterateHeaders();
    while (it.next()) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "link")) continue;
        return parseLinkNextFromValue(arena, h.value);
    }
    return null;
}

pub fn parseLinkNextFromValue(arena: std.mem.Allocator, link_value: []const u8) ?[]const u8 {
    var parts = std.mem.splitSequence(u8, link_value, ",");
    while (parts.next()) |part| {
        const seg = std.mem.trim(u8, part, " \t");
        if (std.mem.indexOf(u8, seg, "rel=\"next\"") == null) continue;
        const lt = std.mem.indexOfScalar(u8, seg, '<') orelse continue;
        const gt = std.mem.indexOfScalarPos(u8, seg, lt + 1, '>') orelse continue;
        if (gt <= lt + 1) continue;
        return arena.dupe(u8, seg[lt + 1 .. gt]) catch null;
    }
    return null;
}

pub fn errorMessage(arena: std.mem.Allocator, resp: Response, token_present: bool) []const u8 {
    const body_msg = types.parseErrorMessage(arena, resp.body);
    return switch (resp.status) {
        401 => if (token_present)
            std.fmt.allocPrint(arena, "GitHub authentication failed (401): {s}. The token may be invalid, expired, or missing required scopes.", .{body_msg}) catch "GitHub authentication failed (401)."
        else
            "GitHub authentication required (401): no token configured. Set GITHUB_TOKEN or GH_TOKEN, or save a token in ~/.config/zode/auth.json as \"github\", \"github.com\", or \"github:<host>\".",
        403 => blk: {
            if (resp.rate_remaining != null and resp.rate_remaining.? == 0) {
                if (resp.retry_after) |ra| {
                    break :blk std.fmt.allocPrint(arena, "GitHub API rate limit reached (403): {s}. Retry after {d}s.", .{ body_msg, ra }) catch "GitHub API rate limit reached (403).";
                }
                break :blk std.fmt.allocPrint(arena, "GitHub API rate limit reached (403): {s}. Try again later.", .{body_msg}) catch "GitHub API rate limit reached (403).";
            }
            if (resp.retry_after) |ra| {
                break :blk std.fmt.allocPrint(arena, "GitHub API temporarily blocked (403): {s}. Retry after {d}s.", .{ body_msg, ra }) catch "GitHub API temporarily blocked (403).";
            }
            break :blk std.fmt.allocPrint(arena, "GitHub access forbidden (403): {s}. The token may lack required scopes, SSO authorization, or access to this resource.", .{body_msg}) catch "GitHub access forbidden (403).";
        },
        404 => std.fmt.allocPrint(arena, "GitHub resource not found (404): {s}. Check owner/repo/number, host, and token access.", .{body_msg}) catch "GitHub resource not found (404).",
        422 => std.fmt.allocPrint(arena, "GitHub request rejected (422): {s}. Check required fields and current repository/PR state.", .{body_msg}) catch "GitHub request rejected (422).",
        429 => blk: {
            if (resp.retry_after) |ra| {
                break :blk std.fmt.allocPrint(arena, "GitHub rate limited (429): {s}. Retry after {d}s.", .{ body_msg, ra }) catch "GitHub rate limited (429).";
            }
            break :blk std.fmt.allocPrint(arena, "GitHub rate limited (429): {s}. Try again later.", .{body_msg}) catch "GitHub rate limited (429).";
        },
        else => if (resp.status >= 500)
            std.fmt.allocPrint(arena, "GitHub server error ({d}): {s}. Try again later.", .{ resp.status, body_msg }) catch "GitHub server error."
        else
            std.fmt.allocPrint(arena, "GitHub API error ({d}): {s}.", .{ resp.status, body_msg }) catch "GitHub API error.",
    };
}

pub fn requestJson(arena: std.mem.Allocator, io: std.Io, method: Method, url: []const u8, token: ?[]const u8, value: anytype) !Response {
    const body = try std.json.Stringify.valueAlloc(arena, value, .{ .emit_null_optional_fields = false });
    return request(arena, io, method, url, token, body);
}

test "buildUrl: joins base and path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("https://api.github.com/repos/x/y", try buildUrl(a, "https://api.github.com/", "/repos/x/y"));
    try std.testing.expectEqualStrings("https://api.github.com/repos/x/y", try buildUrl(a, "https://api.github.com", "repos/x/y"));
    try std.testing.expectEqualStrings("https://api.github.com/repos/x/y?page=2", try buildUrl(a, "https://api.github.com", "https://api.github.com/repos/x/y?page=2"));
}

test "apiBaseForHost: dotcom and enterprise" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings(default_api_base, apiBaseForHost(a, "github.com"));
    try std.testing.expectEqualStrings(default_api_base, apiBaseForHost(a, "GitHub.com"));
    try std.testing.expectEqualStrings("https://ghe.example.com/api/v3", apiBaseForHost(a, "ghe.example.com"));
}

test "errorMessage: 401/403/404/422/429 actionable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const m401 = errorMessage(a, .{ .status = 401, .body = @constCast("{\"message\":\"Bad credentials\"}") }, false);
    try std.testing.expect(std.mem.indexOf(u8, m401, "no token configured") != null);
    try std.testing.expect(std.mem.indexOf(u8, m401, "GITHUB_TOKEN") != null);
    const m403 = errorMessage(a, .{ .status = 403, .body = @constCast("{\"message\":\"API rate limit exceeded\"}"), .rate_remaining = 0, .retry_after = 30 }, true);
    try std.testing.expect(std.mem.indexOf(u8, m403, "rate limit") != null);
    try std.testing.expect(std.mem.indexOf(u8, m403, "30s") != null);
    const m404 = errorMessage(a, .{ .status = 404, .body = @constCast("{\"message\":\"Not Found\"}") }, true);
    try std.testing.expect(std.mem.indexOf(u8, m404, "not found") != null);
    const m422 = errorMessage(a, .{ .status = 422, .body = @constCast("{\"message\":\"Validation Failed\"}") }, true);
    try std.testing.expect(std.mem.indexOf(u8, m422, "422") != null);
    const m429 = errorMessage(a, .{ .status = 429, .body = @constCast("{\"message\":\"slow down\"}"), .retry_after = 12 }, true);
    try std.testing.expect(std.mem.indexOf(u8, m429, "429") != null);
    try std.testing.expect(std.mem.indexOf(u8, m429, "12s") != null);
}

test "parseLinkNextFromValue: extracts next URL" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const next = parseLinkNextFromValue(a, "<https://api.github.com/repos/a/b/issues?page=2>; rel=\"next\", <https://api.github.com/repos/a/b/issues?page=5>; rel=\"last\"");
    try std.testing.expect(next != null);
    try std.testing.expectEqualStrings("https://api.github.com/repos/a/b/issues?page=2", next.?);
    try std.testing.expect(parseLinkNextFromValue(a, "<https://x>; rel=\"prev\"") == null);
}
