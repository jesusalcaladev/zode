//! GitHub REST API types and response parsing helpers.
const std = @import("std");

pub fn parseErrorMessage(arena: std.mem.Allocator, body: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0) return "(empty response)";
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, trimmed, .{}) catch return trimmed;
    if (parsed != .object) return trimmed;
    if (parsed.object.get("message")) |m| {
        if (m == .string and m.string.len > 0) return m.string;
    }
    if (parsed.object.get("error")) |e| {
        if (e == .string and e.string.len > 0) return e.string;
    }
    return trimmed;
}

pub fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    if (v == .string) return v.string;
    return null;
}

pub fn getInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

pub fn getBool(obj: std.json.ObjectMap, key: []const u8) bool {
    const v = obj.get(key) orelse return false;
    return switch (v) {
        .bool => |b| b,
        else => false,
    };
}

pub const Repo = struct {
    full_name: []const u8 = "",
    html_url: []const u8 = "",
    default_branch: []const u8 = "",
    private: bool = false,
    description: []const u8 = "",
};

pub fn parseRepo(obj: std.json.ObjectMap) Repo {
    return .{
        .full_name = getStr(obj, "full_name") orelse "",
        .html_url = getStr(obj, "html_url") orelse "",
        .default_branch = getStr(obj, "default_branch") orelse "",
        .private = getBool(obj, "private"),
        .description = getStr(obj, "description") orelse "",
    };
}

pub const User = struct {
    login: []const u8 = "",
    html_url: []const u8 = "",
    name: []const u8 = "",
};

pub fn parseUser(obj: std.json.ObjectMap) User {
    return .{
        .login = getStr(obj, "login") orelse "",
        .html_url = getStr(obj, "html_url") orelse "",
        .name = getStr(obj, "name") orelse "",
    };
}

pub const PullRequest = struct {
    number: i64 = 0,
    title: []const u8 = "",
    state: []const u8 = "",
    draft: bool = false,
    html_url: []const u8 = "",
    head_ref: []const u8 = "",
    head_sha: []const u8 = "",
    base_ref: []const u8 = "",
    user_login: []const u8 = "",
    mergeable_state: []const u8 = "",
    merged: bool = false,
    body: []const u8 = "",
};

pub fn parsePullRequest(obj: std.json.ObjectMap) PullRequest {
    var pr: PullRequest = .{
        .number = getInt(obj, "number") orelse 0,
        .title = getStr(obj, "title") orelse "",
        .state = getStr(obj, "state") orelse "",
        .draft = getBool(obj, "draft"),
        .html_url = getStr(obj, "html_url") orelse "",
        .mergeable_state = getStr(obj, "mergeable_state") orelse "",
        .merged = getBool(obj, "merged"),
        .body = getStr(obj, "body") orelse "",
    };
    if (obj.get("head")) |h| if (h == .object) {
        pr.head_ref = getStr(h.object, "ref") orelse pr.head_ref;
        pr.head_sha = getStr(h.object, "sha") orelse pr.head_sha;
    };
    if (obj.get("base")) |b| if (b == .object) {
        pr.base_ref = getStr(b.object, "ref") orelse pr.base_ref;
    };
    if (obj.get("user")) |u| if (u == .object) {
        pr.user_login = getStr(u.object, "login") orelse pr.user_login;
    };
    return pr;
}

pub const Issue = struct {
    number: i64 = 0,
    title: []const u8 = "",
    state: []const u8 = "",
    html_url: []const u8 = "",
    user_login: []const u8 = "",
    body: []const u8 = "",
};

pub fn parseIssue(obj: std.json.ObjectMap) Issue {
    var issue: Issue = .{
        .number = getInt(obj, "number") orelse 0,
        .title = getStr(obj, "title") orelse "",
        .state = getStr(obj, "state") orelse "",
        .html_url = getStr(obj, "html_url") orelse "",
        .body = getStr(obj, "body") orelse "",
    };
    if (obj.get("user")) |u| if (u == .object) {
        issue.user_login = getStr(u.object, "login") orelse issue.user_login;
    };
    return issue;
}

test "parseRepo: basic fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        "{\"full_name\":\"acme/widgets\",\"html_url\":\"https://github.com/acme/widgets\",\"default_branch\":\"main\",\"private\":true}",
        .{});
    const r = parseRepo(v.object);
    try std.testing.expectEqualStrings("acme/widgets", r.full_name);
    try std.testing.expectEqualStrings("main", r.default_branch);
    try std.testing.expect(r.private);
}

test "parsePullRequest: nested head/base/user and partial" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        "{\"number\":42,\"title\":\"Add feature\",\"state\":\"open\",\"draft\":false,\"html_url\":\"https://x/pr/42\",\"head\":{\"ref\":\"feat\",\"sha\":\"abc123\"},\"base\":{\"ref\":\"main\"},\"user\":{\"login\":\"alice\"},\"mergeable_state\":\"clean\"}",
        .{});
    const pr = parsePullRequest(v.object);
    try std.testing.expectEqual(@as(i64, 42), pr.number);
    try std.testing.expectEqualStrings("feat", pr.head_ref);
    try std.testing.expectEqualStrings("abc123", pr.head_sha);
    try std.testing.expectEqualStrings("main", pr.base_ref);
    try std.testing.expectEqualStrings("alice", pr.user_login);
    try std.testing.expectEqualStrings("clean", pr.mergeable_state);
    const v2 = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"number\":7}", .{});
    const pr2 = parsePullRequest(v2.object);
    try std.testing.expectEqual(@as(i64, 7), pr2.number);
    try std.testing.expectEqualStrings("", pr2.title);
}

test "parseErrorMessage: extracts message/error or falls back" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const msg = parseErrorMessage(arena, "{\"message\":\"Bad credentials\",\"documentation_url\":\"x\"}");
    try std.testing.expectEqualStrings("Bad credentials", msg);
    const msg2 = parseErrorMessage(arena, "{\"error\":\"oops\"}");
    try std.testing.expectEqualStrings("oops", msg2);
    const msg3 = parseErrorMessage(arena, "  plain error  ");
    try std.testing.expectEqualStrings("plain error", msg3);
    const msg4 = parseErrorMessage(arena, "   ");
    try std.testing.expectEqualStrings("(empty response)", msg4);
}
