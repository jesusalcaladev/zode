// TEMPORARY: raw LSP session with clangd, logging every byte both ways.
const std = @import("std");
const client = @import("lsp/client.zig");
const process = @import("lsp/process.zig");
const protocol = @import("lsp/protocol.zig");

const Logging = struct {
    inner: client.Transport,
    tag: []const u8,

    fn transport(self: *Logging) client.Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable = client.Transport.VTable{
        .writeAll = writeAll,
        .readSome = readSome,
        .close = close,
    };
    fn writeAll(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *Logging = @ptrCast(@alignCast(ctx));
        std.debug.print("[{s}] >>> {s}\n", .{ self.tag, bytes });
        return self.inner.writeAll(bytes);
    }
    fn readSome(ctx: *anyopaque, buf: []u8, timeout_ms: i64) anyerror!usize {
        const self: *Logging = @ptrCast(@alignCast(ctx));
        const n = try self.inner.readSome(buf, timeout_ms);
        std.debug.print("[{s}] <<< {s}\n", .{ self.tag, buf[0..n] });
        return n;
    }
    fn close(ctx: *anyopaque) void {
        const self: *Logging = @ptrCast(@alignCast(ctx));
        self.inner.close();
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try std.Io.Dir.cwd().createDirPath(io, "/tmp/opencode/lspraw");
    const dir = try std.Io.Dir.cwd().openDir(io, "/tmp/opencode/lspraw", .{});
    const src =
        \\static int add(int a, int b) { return a + b; }
        \\int main(void) { return add(1, 2); }
    ;
    try dir.writeFile(io, .{ .sub_path = "hello.c", .data = src });
    const abs = try dir.realPathFileAlloc(io, "hello.c", a);

    const inner = try process.spawn(init.gpa, io, &.{"clangd", "--log=error"});
    const lg = try init.gpa.create(Logging);
    lg.* = .{ .inner = inner, .tag = "lsp" };
    const c = try client.Client.create(init.gpa, io, lg.transport(), "c", try protocol.pathToUri(a, "/tmp/opencode/lspraw"));
    defer c.destroy();

    c.init_timeout_ms = 30000;
    c.request_timeout_ms = 20000;

    try c.handshake(a);
    std.debug.print("== handshake done ==\n", .{});
    const uri = try c.ensureOpen(a, abs);
    std.debug.print("== open {s} ==\n", .{uri});

    const resp = try c.request(a, "textDocument/documentSymbol", try std.fmt.allocPrint(a, "{{\"textDocument\":{{\"uri\":\"{s}\"}}}}", .{uri}), 20000);
    switch (resp) {
        .ok => |v| std.debug.print("== documentSymbol OK ({} items)\n", .{if (v == .array) v.array.items.len else 0}),
        .err => |e| std.debug.print("== documentSymbol ERR {d}: {s}\n", .{ e.code, e.message }),
    }

    const resp2 = try c.request(a, "textDocument/definition", try std.fmt.allocPrint(a, "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":1,\"character\":24}}}}", .{uri}), 20000);
    switch (resp2) {
        .ok => |v| std.debug.print("== definition OK: {}\n", .{v}),
        .err => |e| std.debug.print("== definition ERR {d}: {s}\n", .{ e.code, e.message }),
    }

}
