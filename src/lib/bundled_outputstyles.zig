//! Output styles: bundled/embedded styles (facade).
//! Implementation lives in `outputstyle/bundled.zig`; this path is kept stable for importers.

const bundled = @import("outputstyle/bundled.zig");

pub const BundledStyle = bundled.BundledStyle;
pub const bundled_styles = bundled.bundled_styles;
pub const getBundled = bundled.getBundled;
pub const substituteArguments = bundled.substituteArguments;

test {
    _ = bundled;
}
