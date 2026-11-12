//! Resolve GitHub remote context from a local git repository.
const std = @import("std");

pub const Remote = struct {
    owner: []const u8,
    repo: []const u8,
    host: []const u8,
    url: []const u8,
};

pub fn parseRemoteUrl(url_in: []const u8) ?Remote {
    const url = std.mem.trim(u8, url_in, " \t\r\n");
    if (url.len == 0) return null;
    if (std.mem.indexOf(u8, url, "://")) |scheme_end| {
        const after_scheme = url[scheme_end + 3 ..];
        const host_start_rel = if (std.mem.lastIndexOfScalar(u8, after_scheme, '@')) |at| at + 1 else 0;
        const after_hostinfo = after_scheme[host_start_rel..];
        const slash = std.mem.indexOfScalar(u8, after_hostinfo, '/') orelse return null;
        const host_port = after_hostinfo[0..slash];
        const host = stripPort(host_port);
        if (host.len == 0) return null;
        const path = after_hostinfo[slash + 1 ..];
        return parseOwnerRepoPath(host, path, url);
    }
    if (std.mem.indexOfScalar(u8, url, ':')) |colon| {
        if (std.mem.indexOfScalar(u8, url[0..colon], '/')) |_| return null;
        const left = url[0..colon];
        const path = url[colon + 1 ..];
        if (path.len == 0) return null;
        const host = if (std.mem.lastIndexOfScalar(u8, left, '@')) |at| left[at + 1 ..] else left;
        const host_trim = stripPort(std.mem.trim(u8, host, " \t"));
        if (host_trim.len == 0 or std.mem.indexOfScalar(u8, host_trim, ' ') != null) return null;
        return parseOwnerRepoPath(host_trim, path, url);
    }
    return null;
}

fn stripPort(host_port: []const u8) []const u8 {
    if (host_port.len == 0) return host_port;
    if (host_port[0] == '[') {
        if (std.mem.indexOfScalar(u8, host_port, ']')) |rb| return host_port[1..rb];
        return host_port;
    }
    const first = std.mem.indexOfScalar(u8, host_port, ':') orelse return host_port;
    const last = std.mem.lastIndexOfScalar(u8, host_port, ':').?;
    if (first != last) return host_port;
    return host_port[0..first];
}

fn parseOwnerRepoPath(host: []const u8, path_in: []const u8, original: []const u8) ?Remote {
    var path = std.mem.trim(u8, path_in, "/");
    if (std.mem.endsWith(u8, path, ".git")) path = path[0 .. path.len - 4];
    const slash1 = std.mem.indexOfScalar(u8, path, '/') orelse return null;
    const owner = path[0..slash1];
    if (owner.len == 0) return null;
    const rest = path[slash1 + 1 ..];
    if (rest.len == 0) return null;
    const slash2 = std.mem.indexOfScalar(u8, rest, '/');
    const repo = if (slash2) |i| rest[0..i] else rest;
    if (repo.len == 0) return null;
    return .{ .owner = owner, .repo = repo, .host = host, .url = original };
}

fn gitOut(arena: std.mem.Allocator, io: std.Io, argv: []const []const u8, limit: usize) ?[]const u8 {
    const r = std.process.run(arena, io, .{
        .argv = argv,
        .stdout_limit = .limited(limit),
        .stderr_limit = .limited(4096),
        .reserve_amount = 1024,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    }) catch return null;
    const code: u8 = switch (r.term) {
        .exited => |c| c,
        else => return null,
    };
    if (code != 0) return null;
    const t = std.mem.trim(u8, r.stdout, " \t\r\n");
    if (t.len == 0) return null;
    return t;
}

pub fn remoteUrl(arena: std.mem.Allocator, io: std.Io, name: []const u8) ?[]const u8 {
    return gitOut(arena, io, &.{ "git", "remote", "get-url", name }, 4096);
}

pub fn remoteNames(arena: std.mem.Allocator, io: std.Io) ?[]const []const u8 {
    const out = gitOut(arena, io, &.{ "git", "remote" }, 16 * 1024) orelse return null;
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r\n");
        if (t.len == 0) continue;
        list.append(arena, t) catch return null;
    }
    if (list.items.len == 0) return null;
    return list.items;
}

pub fn currentBranch(arena: std.mem.Allocator, io: std.Io) ?[]const u8 {
    const b = gitOut(arena, io, &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" }, 1024) orelse return null;
    if (std.mem.eql(u8, b, "HEAD")) return null;
    return b;
}

pub fn resolve(arena: std.mem.Allocator, io: std.Io) ?Remote {
    const preferred = [_][]const u8{ "origin", "upstream" };
    for (preferred) |name| {
        if (remoteUrl(arena, io, name)) |u| {
            if (parseRemoteUrl(u)) |r| return r;
        }
    }
    const names = remoteNames(arena, io) orelse return null;
    for (names) |name| {
        if (remoteUrl(arena, io, name)) |u| {
            if (parseRemoteUrl(u)) |r| return r;
        }
    }
    return null;
}

test "parseRemoteUrl: https with .git" {
    const r = parseRemoteUrl("https://github.com/jesusalcaladev/zode.git").?;
    try std.testing.expectEqualStrings("github.com", r.host);
    try std.testing.expectEqualStrings("jesusalcaladev", r.owner);
    try std.testing.expectEqualStrings("zode", r.repo);
}

test "parseRemoteUrl: https without .git and with trailing slash" {
    const r = parseRemoteUrl("https://github.com/acme/widgets/").?;
    try std.testing.expectEqualStrings("acme", r.owner);
    try std.testing.expectEqualStrings("widgets", r.repo);
}

test "parseRemoteUrl: ssh scp-like" {
    const r = parseRemoteUrl("git@github.com:acme/widgets.git").?;
    try std.testing.expectEqualStrings("github.com", r.host);
    try std.testing.expectEqualStrings("acme", r.owner);
    try std.testing.expectEqualStrings("widgets", r.repo);
}

test "parseRemoteUrl: ssh:// with userinfo and port" {
    const r = parseRemoteUrl("ssh://git@ghe.example.com:2222/team/repo.git").?;
    try std.testing.expectEqualStrings("ghe.example.com", r.host);
    try std.testing.expectEqualStrings("team", r.owner);
    try std.testing.expectEqualStrings("repo", r.repo);
}

test "parseRemoteUrl: https enterprise host" {
    const r = parseRemoteUrl("https://git.corp.internal/org/service").?;
    try std.testing.expectEqualStrings("git.corp.internal", r.host);
    try std.testing.expectEqualStrings("org", r.owner);
    try std.testing.expectEqualStrings("service", r.repo);
}

test "parseRemoteUrl: rejects invalid" {
    try std.testing.expect(parseRemoteUrl("") == null);
    try std.testing.expect(parseRemoteUrl("not-a-remote") == null);
    try std.testing.expect(parseRemoteUrl("https://github.com/onlyowner") == null);
    try std.testing.expect(parseRemoteUrl("https://github.com/") == null);
}

test "stripPort: host and host:port" {
    try std.testing.expectEqualStrings("github.com", stripPort("github.com"));
    try std.testing.expectEqualStrings("github.com", stripPort("github.com:443"));
    try std.testing.expectEqualStrings("::1", stripPort("[::1]:22"));
}
