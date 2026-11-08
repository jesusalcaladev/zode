//! Output styles: discovery and loading (facade).
//! Implementation lives in `outputstyle/store.zig`; this path is kept stable for importers.

const store = @import("outputstyle/store.zig");

pub const Loader = store.Loader;
pub const max_scan = store.max_scan;
pub const max_roots = store.max_roots;
pub const stamp_path_max = store.stamp_path_max;
pub const Stamp = store.Stamp;
pub const stampPath = store.stampPath;
pub const deinitEntries = store.deinitEntries;

test {
    _ = store;
}
