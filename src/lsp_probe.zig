const std = @import("std");
const manager = @import("lsp/manager.zig");
const format = @import("lsp/format.zig");
const protocol = @import("lsp/protocol.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.Io.Dir.cwd().createDirPath(io, "/tmp/opencode/lspprobe");
    const dir = try std.Io.Dir.cwd().openDir(io, "/tmp/opencode/lspprobe", .{});
    const src =
        \\static int add(int a, int b) { return a + b; }
        \\int main(void) { return add(1, 2); }
    ;
    try dir.writeFile(io, .{ .sub_path = "hello.c", .data = src });
    const abs = try dir.realPathFileAlloc(io, "hello.c", a);
    std.debug.print("file: {s}\n", .{abs});

    manager.init(init.gpa, io, init.environ_map);
    defer manager.shutdown();

    var err_text: manager.ErrText = .{};
    const c = (manager.use(abs, &err_text) catch {
        std.debug.print("use failed: {s}\n", .{err_text.slice()});
        return;
    }) orelse {
        std.debug.print("no server (null)\n", .{});
        return;
    };
    defer manager.done(c);

    const uri = try c.ensureOpen(a, abs);
    std.debug.print("uri: {s}\n", .{uri});

    const timeout = manager.requestTimeoutMs();

    {
        var aw = std.Io.Writer.Allocating.init(a);
        try aw.writer.writeAll("{\"textDocument\":{\"uri\":");
        try protocol.writeJsonString(&aw.writer, uri);
        try aw.writer.writeAll("}}");
        const resp = try c.request(a, "textDocument/documentSymbol", aw.toArrayList().items, timeout);
        switch (resp) {
            .ok => |v| {
                const ctx = format.Ctx{ .arena = a, .root = manager.workspaceRoot(), .current_uri = uri };
                std.debug.print("--- documentSymbol ---\n{s}\n", .{try format.render(ctx, .documentSymbol, v)});
            },
            .err => |e| std.debug.print("documentSymbol error {d}: {s}\n", .{ e.code, e.message }),
        }
    }

    const call_off = std.mem.indexOf(u8, src, "add(1").?;
    const call_pos = protocol.byteOffsetToPosition(src, call_off);
    std.debug.print("call at {d}:{d}\n", .{ call_pos.line + 1, call_pos.character + 1 });

    try roundTrip(a, c, uri, timeout, "textDocument/definition", call_pos, .goToDefinition);
    try roundTrip(a, c, uri, timeout, "textDocument/hover", call_pos, .hover);
    try roundTrip(a, c, uri, timeout, "textDocument/references", call_pos, .findReferences);
}

fn roundTrip(
    a: std.mem.Allocator,
    c: anytype,
    uri: []const u8,
    timeout: i64,
    method: []const u8,
    pos: protocol.Position,
    op: protocol.Operation,
) !void {
    var aw = std.Io.Writer.Allocating.init(a);
    try aw.writer.writeAll("{\"textDocument\":{\"uri\":");
    try protocol.writeJsonString(&aw.writer, uri);
    try aw.writer.writeAll("},\"position\":{\"line\":");
    try aw.writer.print("{d}", .{pos.line});
    try aw.writer.writeAll(",\"character\":");
    try aw.writer.print("{d}", .{pos.character});
    try aw.writer.writeAll("}");
    if (std.mem.endsWith(u8, method, "references"))
        try aw.writer.writeAll(",\"context\":{\"includeDeclaration\":true}");
    try aw.writer.writeAll("}");
    const resp = try c.request(a, method, aw.toArrayList().items, timeout);
    switch (resp) {
        .ok => |v| {
            const ctx = format.Ctx{ .arena = a, .root = manager.workspaceRoot(), .current_uri = uri };
            std.debug.print("--- {s} ---\n{s}\n", .{ method, try format.render(ctx, op, v) });
        },
        .err => |e| std.debug.print("{s} error {d}: {s}\n", .{ method, e.code, e.message }),
    }
}
