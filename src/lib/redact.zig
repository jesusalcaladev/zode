const std = @import("std");

/// Replace key-like shapes and known keys in text before persist/log.
/// Pure, no I/O. If no known_keys are given, only shape redaction runs.

pub fn redact(alloc: std.mem.Allocator, text: []const u8, known_keys: []const []const u8) ![]u8 {
    // Fast path: nothing to hide and no shape.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < text.len) {
        // Known key values win first.
        var hit: ?usize = null;
        for (known_keys) |k| {
            if (k.len >= 8 and i + k.len <= text.len and std.mem.eql(u8, text[i .. i + k.len], k)) {
                hit = k.len;
                break;
            }
        }
        if (hit) |len| {
            try out.appendSlice(alloc, "[REDACTED]");
            i += len;
            continue;
        }
        // Bearer shape: "Bearer " + token
        if (i + 7 <= text.len and std.ascii.eqlIgnoreCase(text[i .. i + 7], "Bearer ")) {
            try out.appendSlice(alloc, "Bearer [REDACTED]");
            i += 7;
            while (i < text.len and text[i] != ' ' and text[i] != '\n' and text[i] != '\t' and text[i] != '"') i += 1;
            continue;
        }
        // sk- / sk-ant- shapes
        if (i + 3 <= text.len and (std.mem.startsWith(u8, text[i..], "sk-ant-") or std.mem.startsWith(u8, text[i..], "sk-"))) {
            try out.appendSlice(alloc, "[REDACTED]");
            while (i < text.len and text[i] != ' ' and text[i] != '\n' and text[i] != '\t' and text[i] != '"') i += 1;
            continue;
        }
        // ZODE_*_KEY= , *_TOKEN=
        const rest = text[i..];
        if (std.mem.indexOf(u8, rest, "_KEY=") != null or std.mem.indexOf(u8, rest, "_TOKEN=") != null) {
            // Find the first '=' in a short window ahead
            var j: usize = 0;
            var eq: ?usize = null;
            while (j < rest.len and j < 64) : (j += 1) {
                if (rest[j] == '=') {
                    eq = j;
                    break;
                }
                if (rest[j] == ' ' or rest[j] == '\n') break;
            }
            if (eq) |e| {
                const prefix = rest[0..e];
                // Only if it looks like an env var name (uppercase/underscore)
                var ok = prefix.len > 0 and prefix.len <= 32;
                if (ok) {
                    for (prefix) |c| {
                        if (!(c == '_' or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9'))) {
                            ok = false;
                            break;
                        }
                    }
                }
                if (ok) {
                    try out.appendSlice(alloc, prefix);
                    try out.appendSlice(alloc, "=[REDACTED]");
                    i += e + 1;
                    while (i < text.len and text[i] != ' ' and text[i] != '\n' and text[i] != '\t' and text[i] != '"') i += 1;
                    continue;
                }
            }
        }
        try out.append(alloc, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

test "redact: known key values and common shapes are replaced" {
    const a = std.testing.allocator;
    const keys = [_][]const u8{"sk-test-12345678"};
    const text = "hi sk-test-12345678 and Bearer abc123 and ZODE_API_KEY=xyz done";
    const out = try redact(a, text, &keys);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "sk-test-12345678") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[REDACTED]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "abc123") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "xyz") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "done") != null);
}

test "redact: does not over-redact" {
    const a = std.testing.allocator;
    const text = "monkey-model is fine";
    const out = try redact(a, text, &.{});
    defer a.free(out);
    try std.testing.expectEqualStrings(text, out);
}
