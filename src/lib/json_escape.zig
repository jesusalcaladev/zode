//! The ONE JSON string escaper for zode (Phase 42.1).
//!
//! There used to be nine copies with three algorithms. Two of them did not
//! escape control bytes below 0x20, which produces INVALID JSON whenever a
//! file path, a tool result or a message carries one. This module keeps the
//! most complete version — the one the LSP/MCP/ACP protocols used — as the
//! single source of truth. It is pure: a writer and bytes, no allocator, no IO.

const std = @import("std");

/// Escape `s` into `w` WITHOUT the surrounding quotes. Use this for a value
/// that is already inside a string literal the caller opened.
pub fn escape(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x08 => try w.writeAll("\\b"),
        0x0c => try w.writeAll("\\f"),
        else => {
            if (c < 0x20) {
                try w.print("\\u{x:0>4}", .{c});
            } else {
                try w.writeByte(c);
            }
        },
    };
}

/// Write `s` as a complete JSON string, including the surrounding quotes.
pub fn writeString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    try escape(w, s);
    try w.writeByte('"');
}

test "json_escape: control bytes are escaped, not emitted raw" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeString(&w, "a\x01\"\\\n\r\t\x08\x0cb");
    try std.testing.expectEqualStrings(
        "\"a\\u0001\\\"\\\\\\n\\r\\t\\b\\fb\"",
        w.buffered(),
    );
}

test "json_escape: the result parses back to the original bytes" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const original = "line\nwith\x00a control\tand \"quotes\" and \\slash";
    try writeString(&w, original);
    const json = w.buffered();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{});
    try std.testing.expectEqualStrings(original, parsed.string);
}
