//! Canonical, capitalized output labels for tool results.
//!
//! Every tool used to invent its own separators: `exit=`, `--- stdout ---`,
//! `(empty)`, `d name`. This module owns the vocabulary so the model sees one
//! shape wherever the result came from. Labels are Title Case, ASCII, and
//! carry no ANSI: the TUI applies semantic roles when painting.
//!
//! Machine-parsable tokens (`exit=N`) stay in the text: the harness and the
//! smoke scripts grep them, and hiding them would be a silent contract break.

const std = @import("std");

pub const Label = enum {
    exit,
    stdout,
    stderr,
    files,
    note,
    cache,
    truncated,
    command,
};

pub fn title(label: Label) []const u8 {
    return switch (label) {
        .exit => "Exit",
        .stdout => "Stdout",
        .stderr => "Stderr",
        .files => "Files",
        .note => "Note",
        .cache => "Cache",
        .truncated => "Truncated",
        .command => "Command",
    };
}

/// `Files · path` — a section header with its subject on the same line.
pub fn header(w: *std.Io.Writer, label: Label, subject: []const u8) !void {
    try w.print("{s} · {s}\n", .{ title(label), subject });
}

/// `Exit: 2 (exit=2)` — readable first, machine token preserved.
pub fn exitCode(w: *std.Io.Writer, code: u8) !void {
    try w.print("{s}: {d} (exit={d})\n", .{ title(.exit), code, code });
}

pub fn stoppedAtCap(w: *std.Io.Writer) !void {
    try w.writeAll("Exit: stopped at the tool's output cap (exit=(stopped at the tool's output cap))\n");
}

pub fn section(w: *std.Io.Writer, label: Label) !void {
    try w.print("{s}\n", .{title(label)});
}

pub fn fileRow(w: *std.Io.Writer, is_dir: bool, name: []const u8) !void {
    try w.print("{s}  {s}\n", .{ if (is_dir) "DIR " else "FILE", name });
}

pub fn emptyDir(w: *std.Io.Writer, path: []const u8) !void {
    try w.print("No entries in {s}\n", .{path});
}

pub fn truncated(w: *std.Io.Writer, shown: usize, total: usize) !void {
    try w.print("{s} · showing {d} of {d} entries\n", .{ title(.truncated), shown, total });
}

pub fn note(w: *std.Io.Writer, text: []const u8) !void {
    try w.print("{s}  {s}\n", .{ title(.note), text });
}

test "tooloutput: labels are Title Case and exit keeps its machine token" {
    const t = std.testing;
    try t.expectEqualStrings("Stdout", title(.stdout));
    try t.expectEqualStrings("Truncated", title(.truncated));

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try exitCode(&w, 2);
    try t.expectEqualStrings("Exit: 2 (exit=2)\n", w.buffered());
}

test "tooloutput: directory rows align and an empty dir says so" {
    const t = std.testing;
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try header(&w, .files, "src");
    try fileRow(&w, true, "lib");
    try fileRow(&w, false, "main.zig");
    try truncated(&w, 500, 734);
    try t.expectEqualStrings(
        "Files · src\nDIR   lib\nFILE  main.zig\nTruncated · showing 500 of 734 entries\n",
        w.buffered(),
    );

    var empty_buf: [128]u8 = undefined;
    var ew: std.Io.Writer = .fixed(&empty_buf);
    try emptyDir(&ew, ".");
    try t.expectEqualStrings("No entries in .\n", ew.buffered());
}
