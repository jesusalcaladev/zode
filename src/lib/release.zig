//! Release/beta flow (Phase 38): version bumps, channel selection and the
//! changelog cut decision. Pure on purpose — everything here is string/version
//! math testable without git, network or a filesystem. The `churn` tool and
//! the self-update check own the IO and call these rules.
//!
//! Channels: `stable` (default) and `beta`. A beta tag (`v0.3.0-beta.1`) is a
//! SemVer prerelease — it sorts BELOW its release, and GitHub keeps
//! `/releases/latest` pointing at the last stable. The self-update check uses
//! `pickLatest()` to honour an explicit beta channel without ever demoting a
//! stable user to a beta by accident.

const std = @import("std");

pub const Channel = enum {
    stable,
    beta,

    pub fn parse(s: []const u8) Channel {
        if (std.ascii.eqlIgnoreCase(s, "beta")) return .beta;
        return .stable;
    }

    pub fn name(self: Channel) []const u8 {
        return switch (self) {
            .stable => "stable",
            .beta => "beta",
        };
    }
};

pub const Bump = enum { major, minor, patch, beta };

/// Given a version and the changes recorded since the last release, decide the
/// next version. Rules (mirroring `.churn/config.json`):
///   breaking/next → major · feature → minor · fix/perf/refactor/docs/chore → patch
///   beta → increment the prerelease number (or start at beta.1)
/// All bumps land on a beta first unless `promote` is true (an explicit stable cut).
pub fn nextVersion(gpa: std.mem.Allocator, current: []const u8, bump: Bump, promote: bool) ![]const u8 {
    var parts = std.mem.splitScalar(u8, stripV(current), '.');
    var major = std.fmt.parseInt(u64, parts.next() orelse "0", 10) catch 0;
    var minor = std.fmt.parseInt(u64, parts.next() orelse "0", 10) catch 0;
    var patch = std.fmt.parseInt(u64, parts.next() orelse "0", 10) catch 0;

    switch (bump) {
        .major => {
            major += 1;
            minor = 0;
            patch = 0;
        },
        .minor => {
            minor += 1;
            patch = 0;
        },
        .patch => patch += 1,
        .beta => {}, // only the prerelease suffix moves
    }

    // A bump that moves the numeric core starts a fresh beta.1; a `.beta`
    // bump keeps the core and only advances the prerelease suffix.
    const pre = if (promote)
        ""
    else if (bump == .beta)
        try nextBeta(gpa, current)
    else
        try gpa.dupe(u8, "beta.1");
    return if (pre.len == 0)
        std.fmt.allocPrint(gpa, "{d}.{d}.{d}", .{ major, minor, patch })
    else
        std.fmt.allocPrint(gpa, "{d}.{d}.{d}-{s}", .{ major, minor, patch, pre });
}

fn stripV(s: []const u8) []const u8 {
    var t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len > 1 and (t[0] == 'v' or t[0] == 'V')) t = t[1..];
    // Keep only the numeric core up to '-' or '+'.
    const end = std.mem.indexOfAny(u8, t, "-+") orelse t.len;
    return t[0..end];
}

/// `beta.N` → `beta.N+1`; no prerelease → `beta.1`; `rc.2` → `beta.1`.
pub fn nextBeta(gpa: std.mem.Allocator, current: []const u8) ![]const u8 {
    const t = std.mem.trim(u8, current, " \t\r\n");
    if (std.mem.indexOfScalar(u8, t, '-')) |dash| {
        const pre = t[dash + 1 ..];
        if (std.mem.startsWith(u8, pre, "beta.")) {
            const rest = pre["beta.".len..];
            const n = std.fmt.parseInt(u64, rest, 10) catch 0;
            return std.fmt.allocPrint(gpa, "beta.{d}", .{n + 1});
        }
    }
    return gpa.dupe(u8, "beta.1");
}

/// Which channel a tag belongs to. Any SemVer prerelease is a beta.
pub fn channelOf(tag: []const u8) Channel {
    const t = std.mem.trim(u8, tag, " \t\r\n");
    const core_end = std.mem.indexOfAny(u8, t, "+") orelse t.len;
    return if (std.mem.indexOfScalar(u8, t[0..core_end], '-') != null) .beta else .stable;
}

/// A beta channel accepts both betas and stable releases; a stable channel
/// never accepts a beta. Ties are impossible (two distinct tags), so this is
/// just "is the candidate allowed for this channel".
pub fn allowed(channel: Channel, candidate_tag: []const u8) bool {
    return switch (channel) {
        .stable => channelOf(candidate_tag) == .stable,
        .beta => true,
    };
}

/// Pick the newest tag visible from a channel, given a list of tags ordered
/// newest-first (as GitHub returns them by creation date). The beta channel
/// prefers the newest prerelease and falls back to a stable tag only when no
/// beta exists; the stable channel rejects prereleases outright. Returns null
/// when nothing qualifies.
pub fn pickLatest(tags: []const []const u8, channel: Channel) ?[]const u8 {
    var fallback: ?[]const u8 = null;
    for (tags) |tag| {
        if (!allowed(channel, tag)) continue;
        if (channel == .beta and channelOf(tag) != .beta) {
            if (fallback == null) fallback = tag;
            continue;
        }
        return tag;
    }
    return fallback;
}

test "release: beta bumps increment the prerelease" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("0.2.1-beta.1", try nextVersion(a, "0.2.0", .patch, false));
    try std.testing.expectEqualStrings("0.2.2-beta.1", try nextVersion(a, "0.2.1-beta.2", .patch, false));
    try std.testing.expectEqualStrings("0.2.1-beta.3", try nextVersion(a, "0.2.1-beta.2", .beta, false));
    try std.testing.expectEqualStrings("0.3.0-beta.1", try nextVersion(a, "0.2.1-beta.2", .minor, false));
}

test "release: a stable promote drops the prerelease" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("0.3.0", try nextVersion(a, "0.3.0-beta.2", .beta, true));
    try std.testing.expectEqualStrings("1.0.0", try nextVersion(a, "0.9.4", .major, true));
}

test "release: channel rules never demote stable to beta" {
    try std.testing.expectEqual(Channel.beta, channelOf("v0.3.0-beta.1"));
    try std.testing.expectEqual(Channel.stable, channelOf("v0.2.0"));
    try std.testing.expect(!allowed(.stable, "v0.3.0-beta.1"));
    try std.testing.expect(allowed(.beta, "v0.3.0-beta.1"));
    try std.testing.expect(allowed(.beta, "v0.2.0"));
}

test "release: pickLatest respects the channel" {
    const tags = [_][]const u8{ "v0.3.0-beta.1", "v0.2.0", "v0.1.9" };
    try std.testing.expectEqualStrings("v0.2.0", pickLatest(&tags, .stable).?);
    try std.testing.expectEqualStrings("v0.3.0-beta.1", pickLatest(&tags, .beta).?);
    try std.testing.expect(pickLatest(&.{"v0.3.0-beta.1"}, .stable) == null);
}

test "release: the beta channel prefers a prerelease over a newer dated stable" {
    // GitHub orders releases by creation date, not semver: the stable tag can
    // appear first even when a beta with a higher core version exists.
    const tags = [_][]const u8{ "v0.2.0", "v0.3.0-beta.1", "v0.2.1-beta.2" };
    try std.testing.expectEqualStrings("v0.3.0-beta.1", pickLatest(&tags, .beta).?);
    const only_stable = [_][]const u8{ "v0.2.0", "v0.1.9" };
    try std.testing.expectEqualStrings("v0.2.0", pickLatest(&only_stable, .beta).?);
}
