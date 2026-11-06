const std = @import("std");

/// Allowlist env for child processes: strips *_KEY/*_TOKEN/*_SECRET/ZODE_*.
/// Children inherit only safe vars.

pub fn isSecretName(name: []const u8) bool {
    const suffixes = [_][]const u8{ "_KEY", "_TOKEN", "_SECRET", "_PASSWORD", "_API_KEY" };
    for (suffixes) |s| {
        if (std.mem.endsWith(u8, name, s)) return true;
    }
    if (std.mem.startsWith(u8, name, "ZODE_")) return true;
    if (std.mem.startsWith(u8, name, "AWS_")) return true;
    if (std.mem.startsWith(u8, name, "GH_")) return true;
    if (std.mem.startsWith(u8, name, "OPENAI_")) return true;
    if (std.mem.startsWith(u8, name, "ANTHROPIC_")) return true;
    return false;
}

pub fn isAllowedName(name: []const u8) bool {
    // Explicit allowlist of safe vars
    const allowed = [_][]const u8{
        "PATH", "HOME", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "TMPDIR",
        "USER", "LOGNAME", "SHELL", "PWD", "OLDPWD", "TZ",
    };
    for (allowed) |a| {
        if (std.mem.eql(u8, name, a)) return true;
    }
    if (std.mem.startsWith(u8, name, "LC_")) return true;
    return false;
}

pub fn buildChildEnv(alloc: std.mem.Allocator, parent: std.process.Environ.Map) !std.process.Environ.Map {
    var out: std.process.Environ.Map = .init(alloc);
    var it = parent.iterator();
    while (it.next()) |kv| {
        if (isSecretName(kv.key_ptr.*)) continue;
        if (!isAllowedName(kv.key_ptr.*)) continue;
        try out.put(kv.key_ptr.*, kv.value_ptr.*);
    }
    return out;
}

const t = std.testing;

test "secret names are stripped, safe names kept" {
    var parent: std.process.Environ.Map = .init(t.allocator);
    defer parent.deinit();
    try parent.put("PATH", "/usr/bin");
    try parent.put("ZODE_API_KEY", "secret");
    try parent.put("GH_TOKEN", "secret");
    try parent.put("MY_KEY", "secret");
    try parent.put("HOME", "/home/u");
    var child = try buildChildEnv(t.allocator, parent);
    defer child.deinit();
    try t.expect(child.get("PATH") != null);
    try t.expect(child.get("HOME") != null);
    try t.expect(child.get("ZODE_API_KEY") == null);
    try t.expect(child.get("GH_TOKEN") == null);
    try t.expect(child.get("MY_KEY") == null);
}

test "secret detection covers common shapes" {
    try t.expect(isSecretName("ZODE_API_KEY"));
    try t.expect(isSecretName("OPENAI_API_KEY"));
    try t.expect(isSecretName("AWS_SECRET_ACCESS_KEY"));
    try t.expect(isSecretName("GH_TOKEN"));
    try t.expect(!isSecretName("PATH"));
    try t.expect(!isSecretName("HOME"));
}
