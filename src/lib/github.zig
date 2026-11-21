//! GitHub integration namespace (pure/lib helpers).
const std = @import("std");
pub const context = @import("github/context.zig");
pub const types = @import("github/types.zig");
pub const api = @import("github/api.zig");

test {
    @import("std").testing.refAllDecls(@This());
}

test "facade: github context parses an https remote without shelling out" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const r = context.parseRemoteUrl(arena_state.allocator(), "https://github.com/jesusalcaladev/zode.git") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("jesusalcaladev", r.owner);
    try std.testing.expectEqualStrings("zode", r.repo);
}
