const std = @import("std");

/// The tool dispatcher, exposed as a module rooted at `src/`.
///
/// ## Why this file exists
///
/// `zig build tool-test` declares a module named `tools` for `tool_test.zig`, and
/// a module's root file DECIDES ITS MODULE PATH: the path is the directory the
/// root lives in. The tool files live in `src/tools/` but reach `bgproc`,
/// `readcache`, `regex` and `verify`, which live in `src/` and `src/lib/`.
///
/// A Zig module cannot import outside its own root's directory, so a module
/// rooted in `src/tools/` could not reach `src/bgproc.zig`. Rooting it here, at
/// `src/`, makes the module path `src/` and those imports legal — from inside
/// `src/tools/` they are written WITHOUT `../` (`@import("bgproc.zig")` resolves
/// against the module path `src/`, not against the importing file).
///
/// It only re-exports the dispatcher, so the binary keeps importing a module
/// named `tools` and nothing in `src/tools/` has to change shape.
const tools = @import("tools/dispatch.zig");

pub const defs = tools.defs;
pub const isParallelSafe = tools.isParallelSafe;
pub const toolsJson = tools.toolsJson;
pub const needsPermission = tools.needsPermission;
pub const execute = tools.execute;
pub const describeError = tools.describeError;
pub const setAutoBackground = tools.setAutoBackground;
pub const max_tool_output = tools.max_tool_output;

test {
    try std.testing.expect(tools.defs.len > 0);
    try std.testing.expect(isParallelSafe("read"));
}
