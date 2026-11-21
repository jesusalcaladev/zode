//! Skills: discovery and loading (facade).
//! Implementation lives in `skills/store.zig`; this path is kept stable for importers.

const std = @import("std");

const store = @import("skills/store.zig");

pub const Loader = store.Loader;
pub const max_scan = store.max_scan;
pub const max_roots = store.max_roots;
pub const Stamp = store.Stamp;
pub const stamp_path_max = store.stamp_path_max;
pub const stampPath = store.stampPath;

test {
    _ = store;
}

test "facade: skillstore re-exports a usable scanner bound" {
    try std.testing.expect(max_scan > 0);
    try std.testing.expect(max_roots > 0);
}
