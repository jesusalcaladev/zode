//! Skills: discovery and loading (facade).
//! Implementation lives in `skills/store.zig`; this path is kept stable for importers.

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
