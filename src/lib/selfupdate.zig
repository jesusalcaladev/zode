//! Self-update: check GitHub releases and replace the running binary.
//!
//! Two things matter here and both are about what the user sees:
//!
//! 1. **The check is free on almost every start.** The answer is cached ON DISK
//!    (`~/.cache/zode/update.json`) for six hours, so a normal launch reads
//!    about sixty bytes instead of opening TLS to GitHub. It used to be two
//!    module globals, which only saved a request inside ONE process: every
//!    `zode` start did a full HTTPS round trip, and that is the most expensive
//!    thing the app did before drawing a frame.
//! 2. **A new version is SAID, not installed behind the user's back.** The old
//!    `autoUpdate` downloaded the asset and `mv`'d it over the running binary
//!    mid-session, logged it with `std.log` (invisible under the TUI, and where
//!    it was visible it was noise) and the process went on being the OLD build
//!    with no message anywhere. Now the check only NOTIFIES — `v0.2.0 is
//!    available (minor) · /update` — and `/update` is what installs. The
//!    automatic install still exists behind `ZODE_AUTO_UPDATE=1`, because
//!    removing a behaviour somebody relies on is not an improvement.
//!
//! The install is checked before it replaces anything: the downloaded binary is
//! RUN (`--version`) and only then renamed into place. That is the check that
//! would have caught the broken 0.1.0 asset (built with the CI runner's CPU,
//! SHA-NI, SIGILL on an older one) instead of installing it.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// Injected at build time (see `build.zig`): `v0.2.0` for a release, `dev` for
/// a local build.
pub const current_version: []const u8 = @import("build_options").version;

/// GitHub repository.
pub const repo: []const u8 = "jesusalcaladev/zode";

const api = "https://api.github.com/repos/" ++ repo;

/// A release is not a hot thing. Six hours is short enough that a release
/// published in the morning is offered the same day and long enough that the
/// network is touched twice a day at most.
pub const ttl_secs: i64 = 6 * 60 * 60;

/// How far behind the local build is.
pub const Kind = enum {
    major,
    minor,
    patch,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .major => "major",
            .minor => "minor",
            .patch => "patch",
        };
    }
};

pub const Version = struct {
    major: u64 = 0,
    minor: u64 = 0,
    patch: u64 = 0,
    /// `""` when the tag has no `-suffix`. Semver: a prerelease sorts BELOW
    /// the release it precedes, so `v1.0.0-rc1` is older than `v1.0.0`.
    pre: []const u8 = "",

    pub fn parse(text: []const u8) ?Version {
        var v = std.mem.trim(u8, text, " \t\r\n");
        if (v.len > 1 and (v[0] == 'v' or v[0] == 'V')) v = v[1..];
        if (v.len == 0) return null;

        var out: Version = .{};
        var core = v;
        if (std.mem.indexOfScalar(u8, v, '-')) |i| {
            core = v[0..i];
            out.pre = v[i + 1 ..];
        }
        // Build metadata is not part of precedence.
        if (std.mem.indexOfScalar(u8, out.pre, '+')) |i| out.pre = out.pre[0..i];

        var it = std.mem.splitScalar(u8, core, '.');
        const nums = [_]*u64{ &out.major, &out.minor, &out.patch };
        var i: usize = 0;
        while (it.next()) |part| {
            if (i >= nums.len) break;
            if (part.len == 0) return null;
            nums[i].* = std.fmt.parseInt(u64, part, 10) catch return null;
            i += 1;
        }
        // `1` and `1.2` are valid spellings of a version; `garbage` is not.
        if (i == 0) return null;
        return out;
    }

    /// Semver precedence.
    pub fn order(a: Version, b: Version) std.math.Order {
        if (a.major != b.major) return numOrder(a.major, b.major);
        if (a.minor != b.minor) return numOrder(a.minor, b.minor);
        if (a.patch != b.patch) return numOrder(a.patch, b.patch);
        if (a.pre.len == 0 and b.pre.len > 0) return .gt;
        if (a.pre.len > 0 and b.pre.len == 0) return .lt;
        return std.mem.order(u8, a.pre, b.pre);
    }
};

fn numOrder(a: u64, b: u64) std.math.Order {
    return if (a < b) .lt else if (a > b) .gt else .eq;
}

/// Which digit moved between the local build and the release, or null when the
/// local build has no semver to compare against (a `dev` build).
pub fn kindBetween(current: []const u8, latest: []const u8) ?Kind {
    const a = Version.parse(current) orelse return null;
    const b = Version.parse(latest) orelse return null;
    if (b.major != a.major) return .major;
    if (b.minor != a.minor) return .minor;
    if (b.patch != a.patch) return .patch;
    return null;
}

pub const Update = struct {
    /// The release tag, e.g. `v0.2.0`. Owned by the allocator given to `check`.
    version: []const u8,
    /// `null` for a local (`dev`) build: there is no number to be behind.
    kind: ?Kind,
    /// The answer came from the disk cache: no request was made.
    from_cache: bool,
};

/// Everything a check or an install needs. Passing it explicitly keeps the hot
/// path free of module globals (the tests build it with a fake environment and
/// no `Io` global).
pub const Context = struct {
    io: Io,
    alloc: std.mem.Allocator,
    env: ?*const std.process.Environ.Map,
};

/// Where the check's answer is remembered.
///
/// The CACHE and not `~/.config/zode`: this is derived data that can be deleted
/// at any moment, and a config directory that grows files nobody wrote is a
/// config directory nobody trusts.
pub fn cachePath(env: ?*const std.process.Environ.Map, buf: []u8) ?[]const u8 {
    const m = env orelse return null;
    if (m.get("XDG_CACHE_HOME")) |c| {
        if (c.len > 0) return std.fmt.bufPrint(buf, "{s}/zode/update.json", .{c}) catch null;
    }
    const home = m.get("HOME") orelse return null;
    if (home.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}/.cache/zode/update.json", .{home}) catch null;
}

const CacheEntry = struct {
    checked_at: i64 = 0,
    latest: []const u8 = "",
};

fn loadCache(ctx: Context) ?CacheEntry {
    var path_buf: [1024]u8 = undefined;
    const path = cachePath(ctx.env, &path_buf) orelse return null;
    const body = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.alloc, .limited(4096)) catch return null;
    // The body is allocated in the caller's arena and is not freed: it lives as
    // long as the answer it carries.
    return std.json.parseFromSliceLeaky(CacheEntry, ctx.alloc, body, .{ .ignore_unknown_fields = true }) catch null;
}

fn saveCache(ctx: Context, tag: []const u8, now: i64) void {
    var path_buf: [1024]u8 = undefined;
    const path = cachePath(ctx.env, &path_buf) orelse return;
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(ctx.io, dir) catch {};
    }
    var body_buf: [512]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "{{\"checked_at\":{d},\"latest\":\"{s}\"}}", .{ now, tag }) catch return;
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = body }) catch {};
}

/// One release, from ONE request: the tag and the URL of the asset this machine
/// needs. `/releases/latest` carries the asset list, so asking again for the tag
/// (to then find the asset in a second response) was a round trip nobody wanted.
const Release = struct {
    tag: []const u8,
    asset_url: ?[]const u8,
};

fn fetchRelease(ctx: Context) ?Release {
    var client: std.http.Client = .{ .allocator = ctx.alloc, .io = ctx.io };
    defer client.deinit();

    const uri = std.Uri.parse(api ++ "/releases/latest") catch return null;
    var req = client.request(.GET, uri, .{ .headers = .{
        // std does not decompress transparently: asking for the identity
        // encoding is the difference between JSON and 4 KB of gzip bytes.
        .accept_encoding = .omit,
        // GitHub's API answers 403 to a client with no user agent.
        .user_agent = .{ .override = "zode/" ++ current_version },
    } }) catch return null;
    defer req.deinit();
    req.sendBodiless() catch return null;

    var redirect_buf: [8192]u8 = undefined;
    const response = req.receiveHead(&redirect_buf) catch return null;
    if (response.head.status != .ok) return null;

    var transfer_buf: [16 * 1024]u8 = undefined;
    var response_mut = response;
    const reader = response_mut.reader(&transfer_buf);
    const body = reader.allocRemaining(ctx.alloc, .limited(2 * 1024 * 1024)) catch return null;

    const json = std.json.parseFromSliceLeaky(std.json.Value, ctx.alloc, body, .{}) catch return null;
    if (json != .object) return null;
    const tag = json.object.get("tag_name") orelse return null;
    if (tag != .string or tag.string.len == 0) return null;

    return .{ .tag = tag.string, .asset_url = assetUrlIn(json, ctx.alloc) };
}

/// The download URL of this platform's asset inside a release object.
fn assetUrlIn(json: std.json.Value, alloc: std.mem.Allocator) ?[]const u8 {
    const platform = platformName() orelse return null;
    const want = std.fmt.allocPrint(alloc, "zode-{s}", .{platform}) catch return null;

    const assets = json.object.get("assets") orelse return null;
    if (assets != .array) return null;
    for (assets.array.items) |item| {
        if (item != .object) continue;
        const name = item.object.get("name") orelse continue;
        if (name != .string or !std.mem.eql(u8, name.string, want)) continue;
        const dl = item.object.get("browser_download_url") orelse return null;
        if (dl != .string) return null;
        return dl.string;
    }
    return null;
}

/// Is there a newer release than the one running?
///
/// `force` skips the disk cache and asks GitHub. Both paths return `null` when
/// the local build is up to date, and the caller says nothing in that case: a
/// line telling the user "you are on the newest version" on every start is
/// noise, and it is the same sentence that makes the real notice invisible.
pub fn check(ctx: Context, force: bool) ?Update {
    const now = Io.Timestamp.now(ctx.io, .real).toSeconds();
    const cached = loadCache(ctx);

    if (!force) {
        if (cached) |c| {
            if (c.latest.len > 0 and now - c.checked_at < ttl_secs) {
                if (c.latest.len == 0) return null;
                const newer = blk: {
                    const cur = Version.parse(current_version) orelse break :blk c.latest.len > 0;
                    const lat = Version.parse(c.latest) orelse break :blk false;
                    break :blk Version.order(lat, cur) == .gt;
                };
                if (!newer) return null;
                return .{ .version = c.latest, .kind = kindBetween(current_version, c.latest), .from_cache = true };
            }
        }
    }

    const release = fetchRelease(ctx) orelse {
        // A network blip must not hide an update we already know about.
        if (cached) |c| {
            if (c.latest.len > 0 and newerThan(c.latest, current_version)) {
                return .{ .version = c.latest, .kind = kindBetween(current_version, c.latest), .from_cache = true };
            }
        }
        return null;
    };
    saveCache(ctx, release.tag, now);

    if (!newerThan(release.tag, current_version)) return null;
    return .{ .version = release.tag, .kind = kindBetween(current_version, release.tag), .from_cache = false };
}

fn newerThan(latest: []const u8, current: []const u8) bool {
    const cur = Version.parse(current) orelse return false;
    const lat = Version.parse(latest) orelse return false;
    return Version.order(lat, cur) == .gt;
}

/// `linux-x86_64` and friends: the suffix of the release asset and of the
/// platform the running binary was built for.
pub fn platformName() ?[]const u8 {
    const os = switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "macos",
        else => return null,
    };
    const arch = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => return null,
    };
    return os ++ "-" ++ arch;
}

pub const InstallError = error{
    /// The release is not newer than the running build: `/update` moves
    /// forward only. Downgrading is how a working binary becomes the broken
    /// asset of an older release, and nobody typing `/update` asked for that.
    AlreadyNewest,
    NoAssetForPlatform,
    DownloadFailed,
    BinaryDoesNotRun,
    NotWritable,
    UnsupportedPlatform,
};

/// Download the newest release and replace the running binary with it. Returns
/// the tag that was installed.
///
/// The order is what makes this safe: download → write a temp file NEXT TO the
/// target (same filesystem, so the rename is atomic) → RUN it → rename over. A
/// binary that does not run on this machine never replaces the one that does.
pub fn installLatest(ctx: Context) InstallError![]const u8 {
    const release = fetchRelease(ctx) orelse return error.DownloadFailed;
    // A `dev` build has no number to compare, and updating it to a release is a
    // decision the user just made by typing the command.
    if (Version.parse(current_version) != null and !newerThan(release.tag, current_version)) {
        return error.AlreadyNewest;
    }
    const download_url = release.asset_url orelse return error.NoAssetForPlatform;

    const data = download(ctx, download_url) orelse return error.DownloadFailed;

    const exe = std.process.executablePathAlloc(ctx.io, ctx.alloc) catch return error.NotWritable;
    const tmp = std.fmt.allocPrint(ctx.alloc, "{s}.new", .{exe}) catch return error.NotWritable;

    // 0755 from the start: a temp file that is not executable cannot be run,
    // and the run is the check.
    std.Io.Dir.cwd().writeFile(ctx.io, .{
        .sub_path = tmp,
        .data = data,
        .flags = .{ .permissions = @enumFromInt(0o755) },
    }) catch return error.NotWritable;

    if (!runs(ctx, tmp)) {
        std.Io.Dir.cwd().deleteFile(ctx.io, tmp) catch {};
        return error.BinaryDoesNotRun;
    }

    // Atomic: on POSIX the running executable keeps its inode, so the process
    // in flight is untouched and the next start is the new build.
    std.Io.Dir.renameAbsolute(tmp, exe, ctx.io) catch {
        std.Io.Dir.cwd().deleteFile(ctx.io, tmp) catch {};
        return error.NotWritable;
    };
    saveCache(ctx, release.tag, Io.Timestamp.now(ctx.io, .real).toSeconds());
    return release.tag;
}

/// Does the downloaded file run here?
///
/// Two probes, because they prove different things:
///
/// - `--version` proves the binary STARTS. Its exit code is the verdict.
/// - `--selftest` proves it can complete a TLS handshake, which is where a
///   build made for another CPU dies (the 0.1.0 asset trapped with SIGILL
///   inside the handshake, seconds in, while `--version` answered normally).
///   Only a SIGNAL is a verdict here: an older binary does not know the flag
///   and exits 1, and a network error is the network's fault. Neither should
///   veto an update.
///
/// An asset built before `--selftest` existed is not protected by the second
/// probe — nothing can be, for a binary that does not have the test in it. That
/// half is the CI gate's job (`-Dcpu=baseline` + the mnemonic scan).
fn runs(ctx: Context, path: []const u8) bool {
    const version = std.process.run(ctx.alloc, ctx.io, .{
        .argv = &.{ path, "--version" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(20), .clock = .awake } },
    }) catch return false;
    switch (version.term) {
        .exited => |code| if (code != 0) return false,
        else => return false,
    }

    const self = std.process.run(ctx.alloc, ctx.io, .{
        .argv = &.{ path, "--selftest" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(20), .clock = .awake } },
    }) catch return true; // no verdict (timeout, spawn failure): do not veto

    return switch (self.term) {
        .exited => |code| code == 0 or
            // An asset from before `--selftest` existed answers `unknown flag`.
            // Nothing can verify a binary that does not carry the test, and
            // that transition half is what the CI gate is for.
            std.mem.indexOf(u8, self.stderr, "unknown flag") != null,
        // A fault is the answer this probe exists to catch.
        else => false,
    };
}

fn download(ctx: Context, url: []const u8) ?[]const u8 {
    var client: std.http.Client = .{ .allocator = ctx.alloc, .io = ctx.io };
    defer client.deinit();

    const uri = std.Uri.parse(url) catch return null;
    var req = client.request(.GET, uri, .{ .headers = .{
        .accept_encoding = .omit,
        .user_agent = .{ .override = "zode/" ++ current_version },
    } }) catch return null;
    defer req.deinit();
    req.sendBodiless() catch return null;

    var redirect_buf: [8192]u8 = undefined;
    const response = req.receiveHead(&redirect_buf) catch return null;
    if (response.head.status != .ok) return null;

    var transfer_buf: [64 * 1024]u8 = undefined;
    var response_mut = response;
    const reader = response_mut.reader(&transfer_buf);
    return reader.allocRemaining(ctx.alloc, .limited(64 * 1024 * 1024)) catch null;
}

/// The sentence the TUI shows. It lives here, next to the numbers it is about,
/// so the notice, `/update` and the tests cannot say three different things.
pub fn phrase(buf: []u8, up: Update) []const u8 {
    const kind = if (up.kind) |k| k.label() else "new";
    return std.fmt.bufPrint(buf, "{s} is available ({s})", .{ up.version, kind }) catch return "an update is available";
}

// ── tests ────────────────────────────────────────────────────────

test "parseVersion: semver with and without the v" {
    const a = Version.parse("v1.2.3").?;
    try std.testing.expectEqual(@as(u64, 1), a.major);
    try std.testing.expectEqual(@as(u64, 2), a.minor);
    try std.testing.expectEqual(@as(u64, 3), a.patch);
    const b = Version.parse("2.10.5").?;
    try std.testing.expectEqual(@as(u64, 10), b.minor);
}

test "parseVersion: a dev build is not a version" {
    // The whole point: a local build must not be compared against a release as
    // if `dev` were 0.0.0, or every start would offer to "update" 0.0.0.
    try std.testing.expect(Version.parse("dev") == null);
    try std.testing.expect(Version.parse("") == null);
    try std.testing.expect(Version.parse("garbage") == null);
}

test "parseVersion: prerelease and build metadata" {
    const v = Version.parse("1.0.0-beta.1+build.5").?;
    try std.testing.expectEqualStrings("beta.1", v.pre);
}

test "compareVersions: each digit, and prerelease sorts below the release" {
    try std.testing.expectEqual(.gt, Version.order(Version.parse("2.0.0").?, Version.parse("1.9.9").?));
    try std.testing.expectEqual(.gt, Version.order(Version.parse("1.5.0").?, Version.parse("1.4.9").?));
    try std.testing.expectEqual(.gt, Version.order(Version.parse("1.2.5").?, Version.parse("1.2.3").?));
    try std.testing.expectEqual(.eq, Version.order(Version.parse("v1.2.3").?, Version.parse("1.2.3").?));
    try std.testing.expectEqual(.lt, Version.order(Version.parse("1.0.0-rc1").?, Version.parse("1.0.0").?));
    try std.testing.expectEqual(.lt, Version.order(Version.parse("1.0.0").?, Version.parse("1.0.1").?));
}

test "kindBetween: says which digit moved" {
    try std.testing.expectEqual(Kind.major, kindBetween("v1.4.2", "v2.0.0").?);
    try std.testing.expectEqual(Kind.minor, kindBetween("v1.4.2", "v1.5.0").?);
    try std.testing.expectEqual(Kind.patch, kindBetween("v1.4.2", "v1.4.3").?);
    try std.testing.expect(kindBetween("v1.4.2", "v1.4.2") == null);
}

test "a dev build has no kind, but the release is still named" {
    const up: Update = .{ .version = "v0.2.0", .kind = kindBetween("dev", "v0.2.0"), .from_cache = false };
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("v0.2.0 is available (new)", phrase(&buf, up));
    try std.testing.expectEqualStrings("v0.2.1 is available (patch)", phrase(&buf, .{
        .version = "v0.2.1",
        .kind = kindBetween("v0.2.0", "v0.2.1"),
        .from_cache = false,
    }));
}

test "the cache path follows XDG_CACHE_HOME, then HOME" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/x");

    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/home/x/.cache/zode/update.json", cachePath(&env, &buf).?);

    try env.put("XDG_CACHE_HOME", "/var/cache/x");
    try std.testing.expectEqualStrings("/var/cache/x/zode/update.json", cachePath(&env, &buf).?);

    try std.testing.expect(cachePath(null, &buf) == null);
}
