//! Result store: spill large tool outputs to disk, keep a small preview in memory.
//!
//! When a tool result exceeds `large_result_threshold_bytes`, the full text is
//! written to a session file and only a `preview_bytes` head + tail is kept
//! in memory. The model receives a `Ref` instead of the full body.

const std = @import("std");

/// A handle to a stored result, small enough to pass to the model.
pub const Ref = struct {
    path: []const u8,
    total_bytes: usize,
    preview_head: []const u8,
    preview_tail: []const u8,
};

pub const large_result_threshold_bytes: usize = 256 * 1024;
pub const preview_bytes: usize = 16 * 1024;
pub const stored_text_max_bytes: usize = 8 * 1024 * 1024;

pub const Store = struct {
    session_dir: []const u8,
    counter: usize = 0,

    pub fn store(self: *Store, gpa: std.mem.Allocator, io: std.Io, data: []const u8) !?Ref {
        if (data.len <= large_result_threshold_bytes) return null;

        const results_dir = try std.fs.path.join(gpa, &.{ self.session_dir, "results" });
        try io.cwd().createDirPathStatus(io, results_dir, 0o700) catch {};

        self.counter += 1;
        const file_name = try std.fmt.allocPrint(gpa, "result-{d}.zjsonl", .{self.counter});
        defer gpa.free(file_name);
        const file_path = try std.fs.path.join(gpa, &.{ results_dir, file_name });

        const compressed = try compress(gpa, data);
        try io.cwd().writeFile(io, .{ .sub_path = file_path, .data = compressed });

        const head = data[0..@min(data.len, preview_bytes)];
        const tail_start = if (data.len > preview_bytes) data.len - preview_bytes else 0;
        const tail = data[tail_start..];

        return .{
            .path = file_path,
            .total_bytes = data.len,
            .preview_head = head,
            .preview_tail = tail,
        };
    }

};

pub fn readRange(
    gpa: std.mem.Allocator,
    io: std.Io,
    ref: Ref,
    lo: usize,
    hi: usize,
) ![]u8 {
    const file = try io.cwd().openFile(io, ref.path, .{});
    defer file.close(io);

    const clamped_hi = if (hi > ref.total_bytes) ref.total_bytes else hi;
    if (lo >= clamped_hi) return &[_]u8{};

    const data = try readFileAll(io, file);
    defer gpa.free(data);

    const actual_hi = if (hi > data.len) data.len else hi;
    return data[lo..actual_hi];
}

fn compress(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    var compress_stream = std.compress.Deflate.compressStream(
        gpa,
        .{ .level = 9 },
    );
    defer compress_stream.deinit();

    var out: std.ArrayList(u8) = .empty;
    var input = data;
    while (input.len > 0) {
        const written = try compress_stream.write(input) catch |err| switch (err) {
            error.StreamEnd => break,
            else => return err,
        };
        input = input[written..];

        const chunk = try compress_stream.read(gpa) catch |err| switch (err) {
            error.StreamEnd => break,
            else => return err,
        };
        try out.appendSlice(gpa, chunk);
    }

    while (true) {
        const chunk = try compress_stream.read(gpa) catch |err| switch (err) {
            error.StreamEnd => break,
            else => return err,
        };
        if (chunk.len == 0) break;
        try out.appendSlice(gpa, chunk);
    }

    const b64_len = std.encoding.Base64.encodeLength(out.items.len);
    var b64 = try gpa.alloc(u8, 1 + b64_len);
    b64[0] = 'z';
    const written = try std.encoding.Base64.encode(b64[1..], out.items) catch |err| return err;
    return b64[0..1 + written];
}

fn readFileAll(io: std.Io, file: std.Io.File) ![]u8 {
    var buf: [stored_text_max_bytes]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const n = try file.read(io, buf[total..]) catch |err| switch (err) {
            error.Eof => break,
            else => return err,
        };
        if (n == 0) break;
        total += n;
        if (total >= stored_text_max_bytes) break;
    }
    return buf[0..total];
}

test "resultStore: small data returns null" {
    const gpa = std.heap.page_allocator;
    const io = std.io.getStdOut().io();
    const dir = try std.fs.path.join(gpa, &.{ "/tmp", "zode-test-store-small" });

    var s = Store{ .session_dir = dir };
    const data = "small result";
    const ref = try s.store(gpa, io, data);
    try std.testing.expect(ref == null);
}

test "resultStore: large data round-trip" {
    const gpa = std.heap.page_allocator;
    const io = std.io.getStdOut().io();
    const dir = try std.fs.path.join(gpa, &.{ "/tmp", "zode-test-store-large" });
    try io.cwd().createDirPathStatus(io, dir, 0o700) catch {};

    var s = Store{ .session_dir = dir };
    var data: [1000]u8 = undefined;
    for (data, 0..) |*c, i| c.* = @as(u8, @as(usize, i % 26) + 'a');

    const ref = try s.store(gpa, io, &data) catch |err| {
        std.debug.print("store error: {s}\n", .{err});
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(ref != null);
    const r = ref.?;
    try std.testing.expect(r.total_bytes == 1000);
    try std.testing.expect(r.preview_head.len <= preview_bytes);
    try std.testing.expect(r.preview_tail.len <= preview_bytes);

    const middle = try readRange(gpa, io, r, 100, 200);
    try std.testing.expect(middle.len == 100);
    for (middle, 0..) |c, i| {
        try std.testing.expect(c == @as(u8, @as(usize, (100 + i) % 26) + 'a'));
    }
}