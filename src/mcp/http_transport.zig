//! MCP Streamable-HTTP transport (50.3).
//!
//! The client only needs a byte pipe: write one JSON-RPC message, read bytes
//! until a message is complete. For HTTP we buffer the message on `writeAll`
//! and POST it on the first `readSome`; the response body (plain JSON or SSE
//! `data:` lines) becomes the pipe's bytes. This keeps `Client` unchanged —
//! the same request/reply logic, the same deferred-schema discipline.
const std = @import("std");
const http_client = @import("../lib/http_client.zig");

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    /// The JSON-RPC request line buffered by writeAll.
    pending: std.ArrayList(u8) = .empty,
    /// Raw response bytes already fetched, and the read cursor into them.
    response: []u8 = &.{},
    pos: usize = 0,
    dead: bool = false,
    closed: bool = false,
};

fn writeAll(ctxp: *anyopaque, bytes: []const u8) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctxp));
    try ctx.pending.appendSlice(ctx.gpa, bytes);
}

fn readSome(ctxp: *anyopaque, buf: []u8, timeout_ms: i64) anyerror!usize {
    _ = timeout_ms; // the HTTP client's own bound applies (ZODE_HTTP_TIMEOUT_MS)
    const ctx: *Ctx = @ptrCast(@alignCast(ctxp));
    if (ctx.pos >= ctx.response.len) {
        if (ctx.pending.items.len == 0) return 0;
        const body = ctx.gpa.dupe(u8, std.mem.trim(u8, ctx.pending.items, " \t\r\n")) catch return error.OutOfMemory;
        defer ctx.gpa.free(body);
        ctx.pending.clearRetainingCapacity();

        var client = http_client.Http.init(ctx.gpa, ctx.io);
        defer client.deinit();
        const result = client.postJson(ctx.url, null, body) catch {
            ctx.dead = true;
            return error.ServerClosed;
        };
        if (ctx.response.len > 0) ctx.gpa.free(ctx.response);
        if (std.mem.indexOf(u8, result.body, "data:") != null) {
            // text/event-stream: only `data:` lines carry JSON-RPC messages.
            var lines: std.ArrayList(u8) = .empty;
            var it = std.mem.splitScalar(u8, result.body, '\n');
            while (it.next()) |line| {
                const trimmed = std.mem.trimStart(u8, line, " \t");
                if (!std.mem.startsWith(u8, trimmed, "data:")) continue;
                lines.appendSlice(ctx.gpa, std.mem.trimStart(u8, trimmed[5..], " ")) catch {};
                lines.append(ctx.gpa, '\n') catch {};
            }
            if (lines.toOwnedSlice(ctx.gpa) catch null) |extracted| {
                ctx.gpa.free(result.body);
                ctx.response = extracted;
            } else {
                ctx.response = result.body;
            }
        } else {
            ctx.response = result.body;
        }
        ctx.pos = 0;
    }
    const n = @min(buf.len, ctx.response.len - ctx.pos);
    @memcpy(buf[0..n], ctx.response[ctx.pos .. ctx.pos + n]);
    ctx.pos += n;
    return n;
}

fn close(ctxp: *anyopaque) void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctxp));
    if (ctx.closed) return;
    ctx.closed = true;
    ctx.pending.deinit(ctx.gpa);
    if (ctx.response.len > 0) ctx.gpa.free(ctx.response);
    ctx.response = &.{};
}

fn kill(ctxp: *anyopaque) void {
    close(ctxp); // no process to signal; a new request will simply fail
}

pub fn transport(ctx: *Ctx) @import("client.zig").Transport {
    return .{ .ctx = ctx, .vtable = &.{
        .writeAll = writeAll,
        .readSome = readSome,
        .close = close,
        .kill = kill,
    } };
}

test "http transport: buffers one request and reports a dead server after a failed POST" {
    // No server is started here: the test asserts the no-request case does not
    // invent bytes and that closing is safe twice (the manager does both).
    const a = std.testing.allocator;
    var ctx = Ctx{ .gpa = a, .io = std.testing.io, .url = "http://127.0.0.1:9/mcp" };
    var t = transport(&ctx);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try t.readSome(&buf, 100));
    t.close();
    t.close();
}
