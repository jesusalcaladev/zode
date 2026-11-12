const std = @import("std");

/// Substring match, case-insensitive, without allocating.
pub fn containsNoCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var k: usize = 0;
        while (k < needle.len and
            std.ascii.toLower(haystack[i + k]) == std.ascii.toLower(needle[k])) k += 1;
        if (k == needle.len) return true;
    }
    return false;
}

/// Provider gate/quota message detection (substring, case-insensitive).
pub fn isGateMessage(detail: []const u8) bool {
    return containsNoCase(detail, "within opencode") or
        containsNoCase(detail, "access is disabled") or
        containsNoCase(detail, "not available for your") or
        containsNoCase(detail, "only be used from within") or
        containsNoCase(detail, "agentic harness") or
        containsNoCase(detail, "not available on this account");
}

test "containsNoCase and isGateMessage" {
    const t = std.testing;
    try t.expect(containsNoCase("Hello World", "world"));
    try t.expect(!containsNoCase("Hello", "world"));
    try t.expect(isGateMessage("Access is disabled for your account"));
    try t.expect(!isGateMessage("rate limit exceeded"));
}
