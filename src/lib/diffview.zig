//! Unified diff analysis and rendering helpers (facade).
//! Implementation lives in `diff/view.zig`; this path is kept stable for importers.

const impl = @import("diff/view.zig");

pub const LineKind = impl.LineKind;
pub const Line = impl.Line;
pub const Options = impl.Options;
pub const analyze = impl.analyze;
pub const digits = impl.digits;

test {
    _ = impl;
}
