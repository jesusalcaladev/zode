const std = @import("std");

pub fn copyToBuf(buf: []u8, value: []const u8) []const u8 {
    // copyForwards (not @memcpy): source can alias destination.
    const n = @min(value.len, buf.len);
    std.mem.copyForwards(u8, buf[0..n], value[0..n]);
    return buf[0..n];
}

pub fn setAnsweringBuf(buf: []u8, model: []const u8) usize {
    const n = @min(model.len, buf.len);
    std.mem.copyForwards(u8, buf[0..n], model[0..n]);
    return n;
}
