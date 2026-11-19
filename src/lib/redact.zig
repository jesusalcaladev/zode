const std = @import("std");

/// Replace key-like shapes and known keys in text before persist/log.
/// Pure, no I/O. If no known_keys are given, only shape redaction runs.

pub fn redact(alloc: std.mem.Allocator, text: []const u8, known_keys: []const []const u8) ![]u8 {
    // Fast path: almost every persisted message contains NO secret. Instead of
    // building a full copy and letting the caller free it, write nothing until
    // the FIRST redaction happens, then copy the pending raw span plus the
    // replacement. Unchanged text is returned as the SAME slice — every caller
    // already checks `scrubbed.ptr != content.ptr` before freeing, so this is
    // compatible and saves one 1 MB alloc+copy per large tool result.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var pending: usize = 0;
    var changed = false;

    // The env-marker search used to re-scan the ENTIRE remaining slice at
    // every byte: O(n^2) on any ordinary large message, reachable from
    // Session.append for every tool result. Track the NEXT marker position
    // instead and only re-scan once the cursor passes it — total O(n).
    var next_key: ?usize = std.mem.indexOf(u8, text, "_KEY=");
    var next_token: ?usize = std.mem.indexOf(u8, text, "_TOKEN=");
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
            if (!changed) {
                try out.ensureTotalCapacity(alloc, text.len);
                changed = true;
            }
            try out.appendSlice(alloc, text[pending..i]);
            try out.appendSlice(alloc, "[REDACTED]");
            i += len;
            pending = i;
            continue;
        }
        // Bearer shape: "Bearer " + token
        if (i + 7 <= text.len and std.ascii.eqlIgnoreCase(text[i .. i + 7], "Bearer ")) {
            if (!changed) {
                try out.ensureTotalCapacity(alloc, text.len);
                changed = true;
            }
            try out.appendSlice(alloc, text[pending..i]);
            try out.appendSlice(alloc, "Bearer [REDACTED]");
            i += 7;
            while (i < text.len and text[i] != ' ' and text[i] != '\n' and text[i] != '\t' and text[i] != '"') i += 1;
            pending = i;
            continue;
        }
        // sk- / sk-ant- shapes
        if (i + 3 <= text.len and (std.mem.startsWith(u8, text[i..], "sk-ant-") or std.mem.startsWith(u8, text[i..], "sk-"))) {
            if (!changed) {
                try out.ensureTotalCapacity(alloc, text.len);
                changed = true;
            }
            try out.appendSlice(alloc, text[pending..i]);
            try out.appendSlice(alloc, "[REDACTED]");
            while (i < text.len and text[i] != ' ' and text[i] != '\n' and text[i] != '\t' and text[i] != '"') i += 1;
            pending = i;
            continue;
        }
        // ZODE_*_KEY= , *_TOKEN=
        if (next_key != null and next_key.? < i) next_key = std.mem.indexOfPos(u8, text, i, "_KEY=");
        if (next_token != null and next_token.? < i) next_token = std.mem.indexOfPos(u8, text, i, "_TOKEN=");
        const rest = text[i..];
        if (next_key != null or next_token != null) {
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
                    if (!changed) {
                        try out.ensureTotalCapacity(alloc, text.len);
                        changed = true;
                    }
                    try out.appendSlice(alloc, text[pending..i]);
                    try out.appendSlice(alloc, prefix);
                    try out.appendSlice(alloc, "=[REDACTED]");
                    i += e + 1;
                    while (i < text.len and text[i] != ' ' and text[i] != '\n' and text[i] != '\t' and text[i] != '"') i += 1;
                    pending = i;
                    continue;
                }
            }
        }
        i += 1;
    }
    if (!changed) return @constCast(text);
    try out.appendSlice(alloc, text[pending..]);
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
    // Nothing to hide: redact hands back the ORIGINAL slice, so there is no
    // allocation to free (and freeing a string literal would crash the gpa).
    try std.testing.expect(out.ptr == text.ptr);
    try std.testing.expectEqualStrings(text, out);
}

test "redact: a large message without env markers is handled in one pass" {
    const a = std.testing.allocator;
    // 100 KB of ordinary text used to cost ~10^10 byte comparisons because
    // every position re-scanned the rest for _KEY=/_TOKEN=.
    var big = std.ArrayList(u8).empty;
    defer big.deinit(a);
    for (0..100) |_| try big.appendSlice(a, "ordinary prose without any secret markers 0123456789\n");
    const result = try redact(a, big.items, &.{});
    try std.testing.expect(result.ptr == big.items.ptr);
    try std.testing.expectEqual(big.items.len, result.len);
    try std.testing.expectEqualStrings(big.items, result);
}

test "redact: many env markers are all replaced correctly" {
    const a = std.testing.allocator;
    const src = "ZODE_FOO_KEY=secret1 middle ZODE_BAR_TOKEN=secret2 tail ZODE_BAZ_KEY=secret3";
    const result = try redact(a, src, &.{});
    defer a.free(result);
    try std.testing.expectEqualStrings(
        "ZODE_FOO_KEY=[REDACTED] middle ZODE_BAR_TOKEN=[REDACTED] tail ZODE_BAZ_KEY=[REDACTED]",
        result,
    );
    try std.testing.expect(std.mem.indexOf(u8, result, "secret") == null);
}
