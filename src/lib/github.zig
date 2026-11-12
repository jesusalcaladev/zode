//! GitHub integration namespace (pure/lib helpers).
pub const context = @import("github/context.zig");
pub const types = @import("github/types.zig");
pub const api = @import("github/api.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
