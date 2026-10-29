//! Bundled output styles: instruction blocks compiled into the binary.
//!
//! This module provides the 3 built-in styles so they work out of the box
//! without any filesystem setup. They are appended AFTER on-disk styles
//! (project/user) so on-disk styles can shadow them.

const std = @import("std");
const styles = @import("outputstyles.zig");

/// One bundled style's data.
pub const BundledStyle = struct {
    name: []const u8,
    description: []const u8,
    keep_coding_instructions: bool,
    body: []const u8,
};

/// All bundled styles, in order.
pub const bundled_styles: []const BundledStyle = &[_]BundledStyle{
    .{
        .name = "default",
        .description = "Standard zode behavior — concise, direct, code-first",
        .keep_coding_instructions = true,
        .body = @embedFile("output_styles/default.md"),
    },
    .{
        .name = "explanatory",
        .description = "Explain every step before taking it; show your reasoning",
        .keep_coding_instructions = true,
        .body = @embedFile("output_styles/explanatory.md"),
    },
    .{
        .name = "learning",
        .description = "Teach as you work — explain concepts and trade-offs along the way",
        .keep_coding_instructions = true,
        .body = @embedFile("output_styles/learning.md"),
    },
};

/// Returns the bundled style with the given name, or null.
pub fn getBundled(name: []const u8) ?BundledStyle {
    for (bundled_styles) |s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

/// Simple $ARGUMENTS substitution helper.
pub fn substituteArguments(body: []const u8, args: []const u8, out: []u8) []const u8 {
    const needle = "$ARGUMENTS";
    const idx = std.mem.indexOf(u8, body, needle) orelse return body;
    var w: std.Io.Writer = .fixed(out);
    w.writeAll(body[0..idx]) catch return body;
    w.writeAll(args) catch return body;
    w.writeAll(body[idx + needle.len..]) catch return body;
    return w.buffered();
}

test "bundled styles are embedded and accessible" {
    try std.testing.expect(bundled_styles.len == 3);
    for (bundled_styles) |s| {
        try std.testing.expect(s.name.len > 0);
        try std.testing.expect(s.description.len > 0);
        try std.testing.expect(s.body.len > 0);
    }
}

test "getBundled: finds by name" {
    try std.testing.expect(getBundled("default") != null);
    try std.testing.expect(getBundled("explanatory") != null);
    try std.testing.expect(getBundled("learning") != null);
    try std.testing.expect(getBundled("nonexistent") == null);
}