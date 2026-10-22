//! The MCP client: one server, one pipe, one request at a time.
//!
//! The transport is behind a vtable, like the LSP client's, and for the same
//! reason: the interesting failures (a server that answers the wrong id, one
//! that sends a request of its own, one that dies mid-call, one that never
//! answers) are all protocol failures, and none of them needs a server to be
//! installed to be tested.
//!
//! ## The framing
//!
//! MCP's stdio transport is **newline-delimited JSON**. Not the LSP framing
//! (`Content-Length` headers): the two protocols speak the same JSON-RPC
//! dialect and frame it differently, and a server that gets the wrong framing
//! answers nothing at all. One message per line, and a message never contains
//! a raw newline.

const std = @import("std");
const protocol = @import("protocol.zig");

/// A byte pipe with a deadline.
pub const Transport = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        writeAll: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void,
        /// Reads up to `buf.len` bytes, waiting at most `timeout_ms` for one.
        /// Returns 0 at end of stream.
        readSome: *const fn (ctx: *anyopaque, buf: []u8, timeout_ms: i64) anyerror!usize,
        close: *const fn (ctx: *anyopaque) void,
        /// Kills the server WITHOUT releasing anything.
        kill: *const fn (ctx: *anyopaque) void,
    };

    pub fn writeAll(self: Transport, bytes: []const u8) anyerror!void {
        return self.vtable.writeAll(self.ctx, bytes);
    }
    pub fn readSome(self: Transport, buf: []u8, timeout_ms: i64) anyerror!usize {
        return self.vtable.readSome(self.ctx, buf, timeout_ms);
    }
    pub fn close(self: Transport) void {
        return self.vtable.close(self.ctx);
    }
    pub fn kill(self: Transport) void {
        return self.vtable.kill(self.ctx);
    }
};

/// The error a server can answer with, as a Zig error.
pub const Error = error{
    /// The server's pipe closed.
    ServerClosed,
    /// The server did not answer in time.
    Timeout,
    /// The answer was not JSON.
    BadJson,
    /// The answer was not a JSON-RPC object.
    BadMessage,
    /// The server answered with a JSON-RPC `error`.
    ServerError,
    /// The server answered with something else entirely.
    UnexpectedAnswer,
};

/// One MCP server.
pub const Client = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    transport: Transport,
    /// The bytes read from the pipe that have not become a message yet.
    in_buf: std.ArrayList(u8) = .empty,
    next_id: i64 = 1,
    /// The revision the server answered with.
    server_version: []const u8 = "",
    /// The server's own name, when it sent one.
    server_name: []const u8 = "",
    request_timeout_ms: i64 = 20_000,
    /// Set when the pipe closed: every later request would fail the same way,
    /// and the manager replaces a dead client instead of handing out one that
    /// answers nothing.
    dead: bool = false,
    /// The last error the server answered with.
    last_error: protocol.Error = .{},

    pub fn create(
        gpa: std.mem.Allocator,
        io: std.Io,
        transport: Transport,
    ) !*Client {
        const self = try gpa.create(Client);
        self.* = .{ .gpa = gpa, .io = io, .transport = transport };
        return self;
    }

    pub fn destroy(self: *Client) void {
        self.transport.close();
        self.in_buf.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Kills the server WITHOUT releasing the client.
    ///
    /// For the exit path: the server must not outlive the app, and a client
    /// that a thread is still inside must not be freed.
    pub fn kill(self: *Client) void {
        self.transport.kill();
    }

    /// The handshake: `initialize`, then the `initialized` notification.
    ///
    /// The notification is not optional. A server that has answered
    /// `initialize` and got no `initialized` waits for the tools it is supposed
    /// to publish, and the symptom is a server that answered the handshake and
    /// then said it had no tools.
    pub fn handshake(self: *Client, arena: std.mem.Allocator) !void {
        const params = try protocol.initializeParams(arena);
        const result = try self.request(arena, protocol.method_initialize, params);

        if (result != .object) return Error.UnexpectedAnswer;
        const obj = result.object;
        if (obj.get("protocolVersion")) |pv| {
            if (pv == .string) self.server_version = pv.string;
        }
        if (obj.get("serverInfo")) |si| {
            if (si == .object) {
                if (si.object.get("name")) |nv| {
                    if (nv == .string) self.server_name = nv.string;
                }
            }
        }

        const note = try protocol.notificationLine(arena, protocol.method_initialized, "{}");
        try self.transport.writeAll(note);
    }

    /// Every tool the server publishes, following the pages.
    ///
    /// The page cap is a stop, not a policy: a server whose `nextCursor` never
    /// ends would otherwise fill the context with tools nobody asked for.
    pub fn listTools(self: *Client, arena: std.mem.Allocator) ![]protocol.Tool {
        var all: std.ArrayList(protocol.Tool) = .empty;
        var cursor: ?[]const u8 = null;
        var pages: usize = 0;
        while (pages < max_pages) : (pages += 1) {
            const params = if (cursor) |c| blk: {
                var aw = std.Io.Writer.Allocating.init(arena);
                try aw.writer.writeAll("{\"cursor\":");
                try protocol.writeJsonString(&aw.writer, c);
                try aw.writer.writeAll("}");
                break :blk aw.toArrayList().items;
            } else "{}";
            const result = try self.request(arena, protocol.method_tools_list, params);
            const page = try protocol.parseToolPage(arena, result);
            try all.appendSlice(arena, page.tools);
            cursor = page.next_cursor;
            if (cursor == null) break;
        }
        return all.items;
    }

    /// Calls one tool.
    pub fn callTool(
        self: *Client,
        arena: std.mem.Allocator,
        name: []const u8,
        arguments_json: []const u8,
    ) !protocol.CallResult {
        const params = try protocol.toolsCallParams(arena, name, arguments_json);
        const result = try self.request(arena, protocol.method_tools_call, params);
        return protocol.parseCallResult(arena, result);
    }

    /// How many pages of tools are followed before giving up.
    pub const max_pages: usize = 20;

    /// Sends a request and waits for ITS answer.
    ///
    /// The wait skips what is not the answer: a notification from the server
    /// (a log line, a tool list that changed) and a request from the server
    /// (which is ANSWERED, because a server waiting for a reply that never
    /// comes is a server waiting forever).
    pub fn request(
        self: *Client,
        arena: std.mem.Allocator,
        method: []const u8,
        params_json: []const u8,
    ) !std.json.Value {
        const id = self.next_id;
        self.next_id += 1;
        const line = try protocol.requestLine(arena, id, method, params_json);
        try self.transport.writeAll(line);

        while (true) {
            const msg = try self.readMessage(arena);
            if (msg.isServerRequest()) {
                try self.answerServerRequest(arena, msg);
                continue;
            }
            if (msg.id == null) continue; // a notification
            if (msg.id.? != id) continue; // an answer to a request we already gave up on
            if (msg.failure) |e| {
                // The server said no. That is information, not a crash: it goes
                // back to the model as text, with the server's own words.
                self.last_error = e;
                return Error.ServerError;
            }
            return msg.result orelse std.json.Value.null;
        }
    }

    /// The last error the server answered with.
    ///
    /// It is a field and not a return value because the ERROR is information:
    /// the server's own words are what the model needs to see ("unknown tool",
    /// "rate limited"), and a Zig error name is not that.
    // (declared with the other fields)

    /// Answers a request the SERVER made.
    ///
    /// zode implements neither `roots/list` nor `sampling/createMessage`, and
    /// the honest answer is "no such method" (`-32601`). Answering with a
    /// null result would tell the server the call worked, and a server that
    /// believes it has roots is a server that will look for files that are not
    /// there.
    fn answerServerRequest(self: *Client, arena: std.mem.Allocator, msg: protocol.Message) !void {
        var aw = std.Io.Writer.Allocating.init(arena);
        try aw.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":{d},\"message\":\"zode does not implement {s}\"}}}}\n", .{
            msg.id.?,
            protocol.method_not_found,
            msg.method orelse "this method",
        });
        self.transport.writeAll(aw.toArrayList().items) catch {};
    }

    /// Reads the next message off the wire.
    fn readMessage(self: *Client, arena: std.mem.Allocator) !protocol.Message {
        while (true) {
            if (try self.takeLine(arena)) |line| {
                return protocol.parseMessage(arena, line) catch Error.BadMessage;
            }
            var buf: [16 * 1024]u8 = undefined;
            const n = self.transport.readSome(&buf, self.request_timeout_ms) catch |e| switch (e) {
                error.Timeout => return Error.Timeout,
                else => return e,
            };
            if (n == 0) {
                self.dead = true;
                return Error.ServerClosed;
            }
            self.in_buf.appendSlice(self.gpa, buf[0..n]) catch return error.OutOfMemory;
        }
    }

    /// Takes one complete line out of the buffer, if there is one.
    fn takeLine(self: *Client, arena: std.mem.Allocator) !?[]const u8 {
        const idx = std.mem.indexOfScalar(u8, self.in_buf.items, '\n') orelse return null;
        const line = self.in_buf.items[0..idx];
        // The bytes are copied: the buffer is reused for the next read, and a
        // line that points into it dies with the next message.
        const copy = try arena.dupe(u8, line);
        const rest = self.in_buf.items.len - (idx + 1);
        std.mem.copyForwards(u8, self.in_buf.items[0..rest], self.in_buf.items[idx + 1 ..]);
        self.in_buf.shrinkRetainingCapacity(rest);
        return copy;
    }
};

// ── tests ────────────────────────────────────────────────────────────────

const t = std.testing;

/// A scripted server: the bytes it answers with, and what it was asked.
const Fake = struct {
    gpa: std.mem.Allocator,
    answers: []const []const u8,
    /// The answer being served.
    idx: usize = 0,
    /// How much of it has been served already.
    off: usize = 0,
    written: std.ArrayList(u8) = .empty,
    /// When the scripted answers run out: end of stream (0) or a timeout.
    eof: bool = false,

    fn transport(self: *Fake) Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = Transport.VTable{
        .writeAll = writeAll,
        .readSome = readSome,
        .close = close,
        .kill = kill,
    };

    fn writeAll(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        try self.written.appendSlice(self.gpa, bytes);
    }
    fn readSome(ctx: *anyopaque, buf: []u8, timeout_ms: i64) anyerror!usize {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        _ = timeout_ms;
        if (self.idx >= self.answers.len) {
            if (self.eof) return 0;
            return error.Timeout;
        }
        const answer = self.answers[self.idx];
        // The index of the answer and the offset INSIDE it are two different
        // numbers. With one counter, the second answer was the third BYTE of
        // the first one, and every test with more than one scripted answer
        // failed for a reason that had nothing to do with the client.
        const n = @min(buf.len, answer.len - self.off);
        @memcpy(buf[0..n], answer[self.off..][0..n]);
        self.off += n;
        if (self.off >= answer.len) {
            self.idx += 1;
            self.off = 0;
        }
        return n;
    }
    fn close(ctx: *anyopaque) void {
        _ = ctx;
    }
    fn kill(ctx: *anyopaque) void {
        _ = ctx;
    }

    fn deinit(self: *Fake) void {
        self.written.deinit(self.gpa);
    }
};

test "the handshake sends initialize and then the initialized notification" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var fake = Fake{ .gpa = t.allocator, .answers = &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"serverInfo\":{\"name\":\"fake\"}}}\n",
    } };
    defer fake.deinit();

    const c = try Client.create(t.allocator, std.testing.io, fake.transport());
    defer c.destroy();

    try c.handshake(a);
    try t.expectEqualStrings("2025-06-18", c.server_version);
    try t.expectEqualStrings("fake", c.server_name);
    // The notification came AFTER the answer, and it is a notification.
    try t.expect(std.mem.indexOf(u8, fake.written.items, "\"method\":\"initialize\"") != null);
    try t.expect(std.mem.indexOf(u8, fake.written.items, "\"method\":\"notifications/initialized\"") != null);
    // And the notification has no id.
    const note_at = std.mem.indexOf(u8, fake.written.items, "notifications/initialized").?;
    const note = fake.written.items[note_at..];
    try t.expect(std.mem.indexOf(u8, note, "\"id\"") == null);
}

test "the tool list is read, and a page is followed" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var fake = Fake{ .gpa = t.allocator, .answers = &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[{\"name\":\"a\"}]}}\n",
    } };
    defer fake.deinit();

    const c = try Client.create(t.allocator, std.testing.io, fake.transport());
    defer c.destroy();

    const tools = try c.listTools(a);
    try t.expectEqual(@as(usize, 1), tools.len);
    try t.expectEqualStrings("a", tools[0].name);
}

test "a call returns the text and the error flag" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var fake = Fake{ .gpa = t.allocator, .answers = &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"42\"}]}}\n",
    } };
    defer fake.deinit();

    const c = try Client.create(t.allocator, std.testing.io, fake.transport());
    defer c.destroy();

    const r = try c.callTool(a, "add", "{\"a\":1}");
    try t.expect(!r.is_error);
    try t.expectEqualStrings("42", r.text);
}

test "a server that answers with an error is an error, with its words kept" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var fake = Fake{ .gpa = t.allocator, .answers = &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32602,\"message\":\"unknown tool\"}}\n",
    } };
    defer fake.deinit();

    const c = try Client.create(t.allocator, std.testing.io, fake.transport());
    defer c.destroy();

    try t.expectError(Error.ServerError, c.callTool(a, "add", "{}"));
    try t.expectEqualStrings("unknown tool", c.last_error.message);
}

test "a notification in the middle of the answer is skipped, not mistaken for it" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var fake = Fake{ .gpa = t.allocator, .answers = &.{
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{\"level\":\"info\"}}\n",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[{\"name\":\"a\"}]}}\n",
    } };
    defer fake.deinit();

    const c = try Client.create(t.allocator, std.testing.io, fake.transport());
    defer c.destroy();

    const tools = try c.listTools(a);
    try t.expectEqual(@as(usize, 1), tools.len);
}

test "a request from the server is answered and does not stall the wait" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var fake = Fake{ .gpa = t.allocator, .answers = &.{
        "{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"roots/list\"}\n",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[]}}\n",
    } };
    defer fake.deinit();

    const c = try Client.create(t.allocator, std.testing.io, fake.transport());
    defer c.destroy();

    _ = try c.listTools(a);
    // The server's request got an answer, and the answer says "no such method"
    // rather than a null result that would lie.
    try t.expect(std.mem.indexOf(u8, fake.written.items, "-32601") != null);
    try t.expect(std.mem.indexOf(u8, fake.written.items, "\"id\":99") != null);
}

test "a dead pipe says so, and the client knows it is dead" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var fake = Fake{ .gpa = t.allocator, .answers = &.{}, .eof = true };
    defer fake.deinit();

    const c = try Client.create(t.allocator, std.testing.io, fake.transport());
    defer c.destroy();

    try t.expectError(Error.ServerClosed, c.listTools(a));
    try t.expect(c.dead);
}

test "a server that never answers times out instead of hanging" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var fake = Fake{ .gpa = t.allocator, .answers = &.{} };
    defer fake.deinit();

    const c = try Client.create(t.allocator, std.testing.io, fake.transport());
    defer c.destroy();
    c.request_timeout_ms = 20;

    try t.expectError(Error.Timeout, c.listTools(a));
}

test "a message split across two reads is still one message" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // The answer arrives in two pieces, and the newline is in the second one.
    var fake = Fake{ .gpa = t.allocator, .answers = &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[{\"na",
        "me\":\"split\"}]}}\n",
    } };
    defer fake.deinit();

    const c = try Client.create(t.allocator, std.testing.io, fake.transport());
    defer c.destroy();

    const tools = try c.listTools(a);
    try t.expectEqual(@as(usize, 1), tools.len);
    try t.expectEqualStrings("split", tools[0].name);
}
