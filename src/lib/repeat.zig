//! Compile-time repetition, for test data.
//!
//! Not to be confused with `repeat_guard.zig`, which implements the runtime tool-call
//! repetition guard (loop detection). This module is purely comptime test-data
//! construction.
//!
//! Zig 0.17 removed the array multiplication operator (`"x" ** 5000`), and the
//! tests that build long synthetic content need something in its place. `rep`
//! is that something: it runs entirely at comptime, so the result is a plain
//! array whose length is known to the compiler — which is what `++`, `@as`, and
//! a struct field of type `[]const u8` all want.
//!
//! Two forms, and the difference is the `&`:
//!  - `&rep("x", 5000)` where a SLICE is wanted (a message's content, a format
//!    argument, an element of a slice array).
//!  - `rep("x", 5) ++ "tail"` where the bytes are CONCATENATED at comptime: `++`
//!    takes arrays, so no `&`.
const std = @import("std");

pub fn rep(comptime s: []const u8, comptime n: usize) [s.len * n]u8 {
    @setEvalBranchQuota(100_000);
    var out: [s.len * n]u8 = undefined;
    if (out.len == 0) return out;
    @memcpy(out[0..s.len], s);
    // DOUBLE the filled prefix, not append one copy at a time. The alternative —
    // `for (0..n)` — is one comptime branch per repetition, and the tests ask for
    // 200 KB of filler (`rep("y", 200 * 1024)` in `checkpoint.zig`), which is
    // 204 800 interpreted iterations. `zig build test` sat pinned at one core for
    // twenty minutes without writing a single cache object; the doubled copy is 18
    // iterations for the same string, and it stays exact because every length here
    // is a whole multiple of `s.len`.
    var filled: usize = s.len;
    while (filled < out.len) {
        const chunk = @min(filled, out.len - filled);
        @memcpy(out[filled..][0..chunk], out[0..chunk]);
        filled += chunk;
    }
    return out;
}

test "rep: the string, n times, at comptime" {
    try std.testing.expectEqualStrings("ababab", &rep("ab", 3));
    try std.testing.expectEqual(@as(usize, 0), (&rep("x", 0)).len);
    const multi = "héllo ";
    try std.testing.expectEqualStrings(multi ++ multi, &rep(multi, 2));
    // The length is comptime-known, which is the whole reason this exists.
    const arr: [10]u8 = rep("01", 5);
    try std.testing.expectEqual(@as(usize, 10), arr.len);
    // A doubled copy is only exact when every length is a whole multiple of the
    // repeated string, so the odd sizes are the ones that would break it.
    try std.testing.expectEqualStrings("xyxyxyx", &rep("xy", 3) ++ "x");
    const big = rep("y", 200 * 1024);
    try std.testing.expectEqual(@as(usize, 204_800), big.len);
    try std.testing.expectEqualStrings("yyy", big[1000..][0..3]);
}
