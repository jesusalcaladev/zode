//! Skills: bundled/embedded skills (facade).
//! Implementation lives in `skills/bundled.zig`; this path is kept stable for importers.

const std = @import("std");

const bundled = @import("skills/bundled.zig");

pub const substituteArguments = bundled.substituteArguments;
pub const BundledSkill = bundled.BundledSkill;
pub const bundled_skills = bundled.bundled_skills;
pub const getBundled = bundled.getBundled;
pub const bundledEntries = bundled.bundledEntries;
pub const formatBundledSkill = bundled.formatBundledSkill;

test {
    _ = bundled;
}

test "facade: bundled skills are present and named" {
    try std.testing.expect(bundled_skills.len > 0);
    try std.testing.expect(bundled_skills[0].name.len > 0);
}
