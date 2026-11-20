//! Unified diff analysis and rendering helpers (facade).
//! Implementation lives in `diff/view.zig`; this path is kept stable for importers.

const std = @import("std");

const impl = @import("diff/view.zig");

pub const LineKind = impl.LineKind;
pub const Line = impl.Line;
pub const Options = impl.Options;
pub const analyze = impl.analyze;
pub const digits = impl.digits;

test {
    _ = impl;
}

test "diffview facade: the re-exported gutter helper computes digits" {
    try std.testing.expectEqual(@as(usize, 1), digits(0));
    try std.testing.expectEqual(@as(usize, 2), digits(42));
    try std.testing.expectEqual(@as(usize, 5), digits(12345));
}
