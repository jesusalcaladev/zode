const std = @import("std");

/// OS keychain fallback for provider keys. Pure Zig, no libc: tries
/// `secret-tool` (libsecret) on Linux; falls back to auth.json (0600).

pub fn available(io: std.Io) bool {
    if (std.Io.Dir.cwd().statFile(io, "/usr/bin/secret-tool", .{})) |st| {
        _ = st;
        return true;
    } else |_| {}
    if (std.Io.Dir.cwd().statFile(io, "/usr/local/bin/secret-tool", .{})) |st| {
        _ = st;
        return true;
    } else |_| {}
    return false;
}

pub fn lookup(alloc: std.mem.Allocator, io: std.Io, provider: []const u8) ?[]u8 {
    if (!available(io)) return null;
    const label = std.fmt.allocPrint(alloc, "zode/{s}", .{provider}) catch return null;
    defer alloc.free(label);
    const argv = [_][]const u8{ "secret-tool", "lookup", "application", "zode", "user", label };
    const res = std.process.run(alloc, io, .{
        .argv = &argv,
        .stdout_limit = .limited(8192),
        .stderr_limit = .limited(8192),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } },
    }) catch return null;
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    if (res.term != .exited) return null;
    if (res.term.exited != 0) return null;
    const out = std.mem.trim(u8, res.stdout, " \t\r\n");
    if (out.len == 0) return null;
    return alloc.dupe(u8, out) catch null;
}

pub fn store(alloc: std.mem.Allocator, io: std.Io, provider: []const u8, key: []const u8) bool {
    if (!available(io)) return false;
    const label = std.fmt.allocPrint(alloc, "zode/{s}", .{provider}) catch return false;
    defer alloc.free(label);
    const argv = [_][]const u8{ "secret-tool", "store", "--label", label, "application", "zode", "user", label };
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;

    var ok = false;
    if (child.stdin) |in| {
        var buf: [4096]u8 = undefined;
        var w = in.writer(io, &buf);
        w.interface.writeAll(key) catch {};
        w.interface.flush() catch {};
        in.close(io);
        child.stdin = null;
    }
    const term = child.wait(io) catch return false;
    ok = term == .exited and term.exited == 0;
    return ok;
}

test "keychain: lookup returns null without secret-tool" {
    const a = std.testing.allocator;
    const k = lookup(a, std.testing.io, "test");
    if (k) |s| a.free(s);
}
