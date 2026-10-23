/// Self-update mechanism for zode binary
///
/// Checks GitHub releases for newer versions and downloads/replaces the binary.
/// Uses semantic versioning (major.minor.patch) to determine if update is needed.

const std = @import("std");
const posix = std.posix;

/// Current version - injected at build time via build.zig
pub const current_version: []const u8 = @import("build_options").version;

/// GitHub repository
pub const repo: []const u8 = "jesusalcaladev/zode";

/// Binary name
pub const binary_name: []const u8 = "zode";

/// GitHub API base URL
const github_api: []const u8 = "https://api.github.com/repos/" ++ repo;

/// Release check interval: 24 hours
const check_interval_ns: i96 = 24 * 60 * 60 * 1_000_000_000;

/// Cached last check time and latest version
var last_check_ns: i96 = 0;
var cached_latest_version: ?[]const u8 = null;

/// Version comparison result
pub const VersionCmp = enum { older, equal, newer };

/// Parse semantic version string (v?major.minor.patch[-suffix])
fn parseVersion(ver: []const u8) !struct { major: u64, minor: u64, patch: u64 } {
    var v = ver;
    if (v.len > 0 and v[0] == 'v') v = v[1..];

    var parts = std.mem.splitScalar(u8, v, '.');
    var iter = &parts;

    var major: u64 = 0;
    var minor: u64 = 0;
    var patch: u64 = 0;

    if (iter.next()) |part| {
        major = try std.fmt.parseInt(u64, part, 10);
    }
    if (iter.next()) |part| {
        minor = try std.fmt.parseInt(u64, part, 10);
    }
    if (iter.next()) |part| {
        // Handle patch with optional suffix (e.g., "5-beta")
        var patch_parts = std.mem.splitScalar(u8, part, '-');
        const patch_part = patch_parts.next().?;
        patch = try std.fmt.parseInt(u64, patch_part, 10);
    }

    return .{ .major = major, .minor = minor, .patch = patch };
}

/// Compare two version strings
pub fn compareVersions(a: []const u8, b: []const u8) !VersionCmp {
    const va = try parseVersion(a);
    const vb = try parseVersion(b);

    if (va.major != vb.major) return if (va.major > vb.major) .newer else .older;
    if (va.minor != vb.minor) return if (va.minor > vb.minor) .newer else .older;
    if (va.patch != vb.patch) return if (va.patch > vb.patch) .newer else .older;
    return .equal;
}

/// Check if an update is available (with caching)
pub fn checkForUpdate(io: std.Io, arena: std.mem.Allocator) !?[]const u8 {
    const now = std.Io.Timestamp.now(io, .real).toNanoseconds();

    // Return cached result if within interval
    if (cached_latest_version != null and now - last_check_ns < check_interval_ns) {
        const cmp = try compareVersions(cached_latest_version.?, current_version);
        if (cmp == .newer) return cached_latest_version;
        return null;
    }

    // Fetch latest release
    var http = std.http.Client{
        .allocator = arena,
        .io = io,
    };
    defer http.deinit();

    const url = github_api ++ "/releases/latest";
    const uri = std.Uri.parse(url) catch return null;

    var req = try http.request(.GET, uri, .{ .headers = .{ .accept_encoding = .omit } });
    defer req.deinit();
    try req.sendBodiless();

    var redirect_buf: [8192]u8 = undefined;
    const response = try req.receiveHead(&redirect_buf);
    if (response.head.status != .ok) return null;

    var transfer_buf: [64 * 1024]u8 = undefined;
    var response_mut = response;
    const reader = response_mut.reader(&transfer_buf);
    const body = reader.allocRemaining(arena, .limited(1024 * 1024)) catch return null;
    defer arena.free(body);

    // Parse JSON for tag_name
    const json = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return null;
    const tag_name = json.object.get("tag_name").?.string;

    // Cache result
    last_check_ns = now;
    cached_latest_version = try arena.dupe(u8, tag_name);

    const cmp = try compareVersions(tag_name, current_version);
    if (cmp == .newer) return tag_name;
    return null;
}

/// Download and install update
pub fn installUpdate(io: std.Io, arena: std.mem.Allocator, version: []const u8) !void {
    const platform = try detectPlatform();
    const asset_name = try std.fmt.allocPrint(arena, "{s}-{s}", .{ binary_name, platform });

    // Fetch release assets
    var http = std.http.Client{
        .allocator = arena,
        .io = io,
    };
    defer http.deinit();

    const url = try std.fmt.allocPrint(arena, "{s}/releases/tags/{s}", .{ github_api, version });
    const uri = std.Uri.parse(url) catch return;
    var request = try http.request(.GET, uri, .{ .headers = .{ .accept_encoding = .omit } });
    defer request.deinit();
    try request.sendBodiless();

    var redirect_buf: [8192]u8 = undefined;
    const response = try request.receiveHead(&redirect_buf);
    if (response.head.status != .ok) return;

    var transfer_buf: [64 * 1024]u8 = undefined;
    var response_mut = response;
    const reader = response_mut.reader(&transfer_buf);
    const body = reader.allocRemaining(arena, .limited(1024 * 1024)) catch return;
    defer arena.free(body);

    const json = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return;

    // Find matching asset
    const assets = json.object.get("assets").?.array.items;
    var download_url: ?[]const u8 = null;

    for (assets) |asset| {
        const name = asset.object.get("name").?.string;
        if (std.mem.eql(u8, name, asset_name)) {
            download_url = asset.object.get("browser_download_url").?.string;
            break;
        }
    }

    if (download_url == null) return;

    // Download binary
    const dl_uri = std.Uri.parse(download_url.?) catch return;
    var dl_request = try http.request(.GET, dl_uri, .{ .headers = .{ .accept_encoding = .omit } });
    defer dl_request.deinit();
    try dl_request.sendBodiless();

    var dl_redirect_buf: [8192]u8 = undefined;
    const dl_response = try dl_request.receiveHead(&dl_redirect_buf);
    if (dl_response.head.status != .ok) return;

    var dl_transfer_buf: [64 * 1024]u8 = undefined;
    var dl_response_mut = dl_response;
    const dl_reader = dl_response_mut.reader(&dl_transfer_buf);
    const binary_data = dl_reader.allocRemaining(arena, .limited(50 * 1024 * 1024)) catch return;
    defer arena.free(binary_data);

    // Get current binary path
    const current_path = try getCurrentBinaryPath(arena);

    // Atomic replace: write to temp, then rename
    const tmp_path = try std.fmt.allocPrint(arena, "{s}.new", .{current_path});
    defer arena.free(tmp_path);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = binary_data });

    // Make executable using portable std.fs.chmod (works on all architectures)
    const cwd = std.fs.cwd();
    try cwd.chmod(tmp_path, 0o755);

    // Replace current binary using portable std.fs.rename
    try cwd.rename(tmp_path, current_path);
}

/// Detect current platform string
fn detectPlatform() ![]const u8 {
    const builtin = @import("builtin");
    const os = switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "macos",
        .windows => "windows",
        else => return error.UnsupportedOS,
    };

    const arch = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => return error.UnsupportedArch,
    };

    return try std.fmt.allocPrint(std.heap.page_allocator, "{s}-{s}", .{os, arch});
}

/// Get path of currently running binary
fn getCurrentBinaryPath(arena: std.mem.Allocator) ![]const u8 {
    const builtin = @import("builtin");
    // Try /proc/self/exe first (Linux)
    if (builtin.os.tag == .linux) {
        var buf: [4096]u8 = undefined;
        const n = @import("std").os.linux.readlink("/proc/self/exe", &buf, buf.len);
        if (n > 0) {
            return try arena.dupe(u8, buf[0..n]);
        }
    }

    // Fallback: use argv[0] and resolve
    // This is a simplification; in reality we'd use the init args
    return try arena.dupe(u8, binary_name);
}

/// Check and auto-update if new version available (non-blocking)
/// Returns the new version if updated, null otherwise
pub fn autoUpdate(io: std.Io, arena: std.mem.Allocator) !?[]const u8 {
    const update = try checkForUpdate(io, arena) orelse return null;
    log_info("New version available: {s}", .{update});
    installUpdate(io, arena, update) catch |err| {
        log_warn("Failed to install update: {s}", .{@errorName(err)});
        return null;
    };
    log_success("Updated to {s}", .{update});
    return update;
}

/// Logging helpers
fn log_info(fmt: []const u8, args: anytype) void {
    std.log.info("[selfupdate] {s} {any}", .{fmt, args});
}

fn log_success(fmt: []const u8, args: anytype) void {
    std.log.info("[selfupdate] {s} {any}", .{fmt, args});
}

fn log_warn(fmt: []const u8, args: anytype) void {
    std.log.warn("[selfupdate] {s} {any}", .{fmt, args});
}

// ── Tests ────────────────────────────────────────────────────────

test "parseVersion: basic semver" {
    const v = try parseVersion("v1.2.3");
    try std.testing.expectEqual(@as(u64, 1), v.major);
    try std.testing.expectEqual(@as(u64, 2), v.minor);
    try std.testing.expectEqual(@as(u64, 3), v.patch);
}

test "parseVersion: without v prefix" {
    const v = try parseVersion("2.10.5");
    try std.testing.expectEqual(@as(u64, 2), v.major);
    try std.testing.expectEqual(@as(u64, 10), v.minor);
    try std.testing.expectEqual(@as(u64, 5), v.patch);
}

test "parseVersion: with suffix" {
    const v = try parseVersion("1.0.0-beta");
    try std.testing.expectEqual(@as(u64, 1), v.major);
    try std.testing.expectEqual(@as(u64, 0), v.minor);
    try std.testing.expectEqual(@as(u64, 0), v.patch);
}

test "compareVersions: major difference" {
    try std.testing.expectEqual(.newer, try compareVersions("2.0.0", "1.9.9"));
    try std.testing.expectEqual(.older, try compareVersions("1.0.0", "2.0.0"));
}

test "compareVersions: minor difference" {
    try std.testing.expectEqual(.newer, try compareVersions("1.5.0", "1.4.9"));
    try std.testing.expectEqual(.older, try compareVersions("1.3.0", "1.4.0"));
}

test "compareVersions: patch difference" {
    try std.testing.expectEqual(.newer, try compareVersions("1.2.5", "1.2.3"));
    try std.testing.expectEqual(.older, try compareVersions("1.2.1", "1.2.2"));
}

test "compareVersions: equal" {
    try std.testing.expectEqual(.equal, try compareVersions("1.2.3", "1.2.3"));
    try std.testing.expectEqual(.equal, try compareVersions("v1.2.3", "1.2.3"));
}