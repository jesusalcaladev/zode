const std = @import("std");
const repeat = @import("repeat.zig");

/// Adds a "z" prefix marker to each JSONL line. Compressed payloads use
/// Zig's std.compress.flate (raw DEFLATE, level 9). Repeated JSONL content
/// (roles, keys, file dumps) typically shrinks 90-97%.
pub const marker = "z";

pub fn isCompressed(line: []const u8) bool {
    return line.len > marker.len and line[0] == marker[0];
}

/// Compress `payload` into a caller-provided buffer. Returns the
/// "z{...}" line slice (a view into `buf`), or null if compression
/// didn't help (short or incompressible payload).
pub fn compressLine(buf: []u8, payload: []const u8) ?[]const u8 {
    const window = std.compress.flate.max_window_len;
    const window_buf = std.heap.page_allocator.alloc(u8, window) catch return null;
    defer std.heap.page_allocator.free(window_buf);

    var out = std.Io.Writer.Allocating.initCapacity(std.heap.page_allocator, 4096) catch return null;
    defer out.deinit();

    return compressLineWith(buf, payload, window_buf, &out);
}

/// Same as `compressLine`, but with caller-owned DEFLATE window and output
/// writer. `Session` reuses both across messages: a fresh 64 KB window and a
/// fresh allocating writer per large persisted line was measurable churn in
/// sessions with many big tool results.
pub fn compressLineWith(buf: []u8, payload: []const u8, window_buf: []u8, out: *std.Io.Writer.Allocating) ?[]const u8 {
    if (payload.len < min_compress_len) return null;
    if (buf.len < payload.len / 4) return null; // not enough room
    if (window_buf.len < std.compress.flate.max_window_len) return null;
    out.clearRetainingCapacity();
    // Compress.init asserts the output buffer has room. A retained writer that
    // started from init() (capacity 0) has none until it is grown once.
    out.ensureUnusedCapacity(4096) catch return null;

    var comp = std.compress.flate.Compress.init(&out.writer, window_buf, .raw, .best) catch return null;
    comp.writer.writeAll(payload) catch return null;
    comp.finish() catch return null;

    const compressed = out.written();
    // Only accept if it actually saves >= 25% (accounting base64 +33%).
    if (compressed.len == 0 or compressed.len * 4 / 3 > payload.len * 3 / 4) return null;

    // base64: pure ASCII, JSON-safe and byte-exact when decoded.
    const enc = std.base64.standard.Encoder;
    const b64_len = enc.calcSize(compressed.len);
    if (1 + b64_len > buf.len) return null;
    buf[0] = marker[0];
    _ = enc.encode(buf[1 .. 1 + b64_len], compressed);
    return buf[0 .. 1 + b64_len];
}

/// Decompresses a "z" content value back into a caller-owned buffer.
pub fn decompressInto(alloc: std.mem.Allocator, line: []const u8, max_out: usize) ![]u8 {
    std.debug.assert(isCompressed(line));
    const b64 = line[1..];

    const dec64 = std.base64.standard.Decoder;
    const bin_len = dec64.calcSizeForSlice(b64) catch return error.BadCompressedLine;
    const bin = try alloc.alloc(u8, bin_len);
    defer alloc.free(bin);
    dec64.decode(bin, b64) catch return error.BadCompressedLine;

    var in_reader: std.Io.Reader = .fixed(bin);
    const window = std.compress.flate.max_window_len;
    const window_buf = try alloc.alloc(u8, window);
    defer alloc.free(window_buf);

    var dec = std.compress.flate.Decompress.init(&in_reader, .raw, window_buf);
    const max: std.Io.Limit = .limited(max_out);
    return dec.reader.allocRemaining(alloc, max) catch return error.BadCompressedLine;
}

/// Minimum payload worth compressing (bytes). Below this, JSON wins.
pub const min_compress_len = 512;

test "round trip compresses and decompresses" {
    const alloc = std.testing.allocator;
    const payload =
        "{\"role\":\"tool\",\"tool_call_id\":\"call_1\",\"content\":\"" ++
        repeat.rep("const std = @import(\"std\");\n", 40) ++
        "\"}";
    var buf: [8192]u8 = undefined;
    const line = compressLine(&buf, payload) orelse return error.TestUnexpectedResult;
    try std.testing.expect(isCompressed(line));

    const back = try decompressInto(alloc, line, 1 << 20);
    defer alloc.free(back);
    try std.testing.expectEqualStrings(payload, back);
    try std.testing.expect(line.len < payload.len / 4); // >= 75% saved
}

test "a short payload is not compressed" {
    var buf: [8192]u8 = undefined;
    try std.testing.expect(compressLine(&buf, "{\"short\":1}") == null);
}

test "compressLineWith: the same window and writer work across many payloads" {
    // Session reuses one DEFLATE window and one allocating writer for every
    // persisted line. A stale byte from the previous payload or a writer that
    // did not reset would corrupt the next line silently (it is base64, so a
    // bad decode only fails on resume).
    const a = std.testing.allocator;
    const window = try a.alloc(u8, std.compress.flate.max_window_len);
    defer a.free(window);
    var out = std.Io.Writer.Allocating.init(a);
    defer out.deinit();

    var buf: [1 << 16]u8 = undefined;
    const payloads = [_][]const u8{
        &repeat.rep("alpha", 400),
        &repeat.rep("beta", 300),
        &repeat.rep("gamma", 500),
    };
    for (payloads, 0..) |payload, i| {
        const line = compressLineWith(&buf, payload, window, &out) orelse return error.TestExpectedNotNull;
        const text = try decompressInto(a, line, 1 << 16);
        defer a.free(text);
        try std.testing.expectEqualStrings(payload, text);
        _ = i;
    }
}
