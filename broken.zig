const std = @import("std");
pub fn greet(name: []const u8) []const u8 {
    var unused_one: u32 = 7;
    return std.fmt.allocPrint(std.heap.page_allocator, "hi {s}", .{name}) catch "hi";
}
