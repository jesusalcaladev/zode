//! Where zode's user config lives (Phase 42.6).
//!
//! One XDG-aware helper instead of four hand-built `HOME/.config/zode` paths.
//! Precedence: `XDG_CONFIG_HOME/zode`, then `HOME/.config/zode`. Pure string
//! work over an injected env map — no filesystem, no IO.

const std = @import("std");

pub fn dir(env: ?*const std.process.Environ.Map, buf: []u8) ?[]const u8 {
    const m = env orelse return null;
    if (m.get("XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len > 0) return std.mem.print(buf, "{s}/zode", .{xdg}) catch null;
    }
    const home = m.get("HOME") orelse return null;
    if (home.len == 0) return null;
    return std.mem.print(buf, "{s}/.config/zode", .{home}) catch null;
}

test "configdir: XDG_CONFIG_HOME wins, HOME is the fallback" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    var buf: [512]u8 = undefined;
    try env.put("HOME", "/home/x");
    try std.testing.expectEqualStrings("/home/x/.config/zode", dir(&env, &buf).?);
    try env.put("XDG_CONFIG_HOME", "/var/conf");
    try std.testing.expectEqualStrings("/var/conf/zode", dir(&env, &buf).?);
    try std.testing.expect(dir(null, &buf) == null);
}
