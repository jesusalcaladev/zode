//! Project memory: filesystem store (facade).
//! Implementation lives in `memory/store.zig`; this path is kept stable for importers.

const std = @import("std");

const store = @import("memory/store.zig");

pub const project_dir = store.project_dir;
pub const entries_dir = store.entries_dir;
pub const pending_dir = store.pending_dir;
pub const Store = store.Store;

test {
    _ = store;
}

test "memory_store facade: the pending directory name is stable" {
    try std.testing.expect(pending_dir.len > 0);
}
