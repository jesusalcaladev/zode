//! Pure geometry for mouse text selection with edge auto-scroll.
//!
//! The TUI keeps the selected endpoints as SCREEN points because that is what
//! the last painted frame maps to bytes. When the view scrolls during a drag,
//! the text under the pointer has to keep moving with the document: the anchor
//! shifts by the content movement, while the live end stays on the screen edge
//! under the pointer.

pub const Point = struct {
    row: u16,
    col: u16,
};

/// Negative = scroll toward older text (pointer near the top edge), positive
/// = toward newer text (pointer near the bottom edge), 0 = no auto-scroll.
/// Magnitude is the number of rows per tick: the closer to the very edge, the
/// faster the scroll, so pushing further up actually moves further.
pub fn edgeDirection(row: u16, rows: u16, margin: u16) i8 {
    if (rows <= 1 or margin == 0) return 0;
    const band = @min(margin, rows - 1);
    if (row < band) return -@as(i8, @intCast(band - row));
    if (row >= rows - band) return @as(i8, @intCast(row - (rows - band) + 1));
    return 0;
}

/// `move` is how far the CONTENT moved on screen: positive means the document
/// moved UP by `move` rows (the reader scrolled toward newer text), so a point
/// anchored to text moves UP by the same amount. Negative moves it down.
pub fn shift(point: Point, move: i64, rows: u16) Point {
    var next = @as(i64, point.row) - move;
    if (next < 0) next = 0;
    if (rows > 0 and next >= @as(i64, rows)) next = @as(i64, rows) - 1;
    return .{ .row = @intCast(next), .col = point.col };
}

test "edge direction speeds up closer to the viewport edge" {
    const t = @import("std").testing;
    try t.expectEqual(@as(i8, -2), edgeDirection(0, 20, 2));
    try t.expectEqual(@as(i8, -1), edgeDirection(1, 20, 2));
    try t.expectEqual(@as(i8, 0), edgeDirection(2, 20, 2));
    try t.expectEqual(@as(i8, 2), edgeDirection(19, 20, 2));
    try t.expectEqual(@as(i8, 1), edgeDirection(18, 20, 2));
    try t.expectEqual(@as(i8, 0), edgeDirection(17, 20, 2));
    try t.expectEqual(@as(i8, 0), edgeDirection(5, 0, 2));
    try t.expectEqual(@as(i8, 0), edgeDirection(0, 1, 2));
}

test "a selection anchor follows the document when the view scrolls" {
    const t = @import("std").testing;
    // Reader scrolls down one line: the document moves up, so text at row 10
    // is now at row 9.
    try t.expectEqual(@as(u16, 9), shift(.{ .row = 10, .col = 4 }, 1, 20).row);
    // Reader scrolls up one line: the document moves down.
    try t.expectEqual(@as(u16, 11), shift(.{ .row = 10, .col = 4 }, -1, 20).row);
    // Never wrap around when the anchor scrolls out of the viewport.
    try t.expectEqual(@as(u16, 0), shift(.{ .row = 0, .col = 4 }, 1, 20).row);
    try t.expectEqual(@as(u16, 19), shift(.{ .row = 19, .col = 4 }, -1, 20).row);
    try t.expectEqual(@as(u16, 7), shift(.{ .row = 9, .col = 12 }, 2, 8).row);
}
