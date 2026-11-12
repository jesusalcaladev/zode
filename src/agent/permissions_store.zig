/// Stateless permission allowlist matching helpers.
///
/// Storage remains in `agent.zig` for now (API/compatibility); this module
/// extracts pure-ish decision logic so it can be tested and reused while the
/// monolith is split.
const std = @import("std");

pub fn isAlwaysAllowed(
    names: anytype,
    lens: anytype,
    name: []const u8,
) bool {
    for (lens, 0..) |l, i| {
        if (l > 0 and std.mem.eql(u8, names[i][0..l], name)) return true;
    }
    return false;
}

pub fn isBashPattern(pats: anytype, lens: anytype, pat: []const u8) bool {
    for (lens, 0..) |l, i| {
        if (l > 0 and std.mem.eql(u8, pats[i][0..l], pat)) return true;
    }
    return false;
}

/// Adds a bash command prefix. Returns false if refused (too long or full).
pub fn addBashPatternNoSave(
    pats: anytype,
    lens: anytype,
    pat: []const u8,
    max_len: usize,
) bool {
    if (isBashPattern(pats, lens, pat)) return true;
    if (pat.len == 0 or pat.len > max_len) return false;
    for (lens, 0..) |l, i| {
        if (l == 0) {
            @memcpy(pats[i][0..pat.len], pat);
            lens[i] = pat.len;
            return true;
        }
    }
    return false;
}

/// Adds a tool name to the always-allowed list.
pub fn setAlwaysAllowedNoSave(
    names: anytype,
    lens: anytype,
    name: []const u8,
    max_name_len: usize,
) bool {
    if (isAlwaysAllowed(names, lens, name)) return true;
    for (lens, 0..) |l, i| {
        if (l == 0) {
            const n = @min(name.len, max_name_len);
            @memcpy(names[i][0..n], name[0..n]);
            lens[i] = n;
            return true;
        }
    }
    return false;
}

/// Matches a persisted bash prefix at a token boundary; rejects chaining/redirects.
pub fn bashPatternAllowed(pats: anytype, lens: anytype, command: []const u8) bool {
    const cmd = std.mem.trim(u8, command, " \t\r\n");
    for (lens, 0..) |l, i| {
        if (l == 0 or l > cmd.len) continue;
        if (!std.mem.eql(u8, cmd[0..l], pats[i][0..l])) continue;
        if (l != cmd.len and cmd[l] != ' ' and cmd[l] != '\t') continue;
        const rest = cmd[l..];
        if (rest.len > 0 and std.mem.indexOfAny(u8, rest, ";|&<>`$\n") != null) continue;
        return true;
    }
    return false;
}

test "isAlwaysAllowed and setAlwaysAllowedNoSave" {
    var names: [8][48]u8 = undefined;
    var lens: [8]usize = @splat(0);
    try std.testing.expect(setAlwaysAllowedNoSave(&names, &lens, "write", 48));
    try std.testing.expect(isAlwaysAllowed(&names, &lens, "write"));
    try std.testing.expect(!isAlwaysAllowed(&names, &lens, "bash"));
}

test "bashPatternAllowed token boundary and chaining" {
    var pats: [16][160]u8 = undefined;
    var lens: [16]usize = @splat(0);
    try std.testing.expect(addBashPatternNoSave(&pats, &lens, "git status", 160));
    try std.testing.expect(bashPatternAllowed(&pats, &lens, "git status"));
    try std.testing.expect(bashPatternAllowed(&pats, &lens, "git status --short"));
    try std.testing.expect(!bashPatternAllowed(&pats, &lens, "git statusx"));
    try std.testing.expect(!bashPatternAllowed(&pats, &lens, "git status && rm -rf /"));
}
