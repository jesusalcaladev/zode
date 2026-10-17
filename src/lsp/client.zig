//! The LSP request state machine: one server, one pipe, one request at a time.
//!
//! The transport is behind a vtable on purpose. A real server is a child
//! process (`process.zig`), and testing this file with one would mean requiring
//! `zls` on the machine that runs the tests. With a fake transport the whole
//! lifecycle — the `initialize` handshake, `didOpen`/`didChange`, matching a
//! response by id while ignoring notifications, replying to a server's own
//! request, and timing out — is exercised deterministically, no binary needed.
//!
//! What the server is TOLD is also decided here, and only here: the wire format
//! of `initialize`, `didOpen` and `didChange` is built in this file and pinned
//! by tests, because a field name typo is a server that answers nothing.

const std = @import("std");
const protocol = @import("protocol.zig");
const sleep = @import("../lib/sleep.zig");

/// Files bigger than this are not sent. A language server that is handed a 40 MB
/// generated file spends the next minute indexing it, and the model asked for a
/// definition, not a build.
pub const max_doc_bytes = 8 * 1024 * 1024;

/// The largest frame accepted from a server, a guard against a runaway message.
pub const max_frame_bytes = 64 * 1024 * 1024;

/// A thin, swappable byte pipe.
pub const Transport = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        writeAll: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void,
        /// Reads up to `buf.len`. Waits at most `timeout_ms` (a large value means
        /// "as long as it takes"). Returns 0 on end of stream.
        readSome: *const fn (ctx: *anyopaque, buf: []u8, timeout_ms: i64) anyerror!usize,
        close: *const fn (ctx: *anyopaque) void,
    };

    pub fn writeAll(self: Transport, bytes: []const u8) !void {
        return self.vtable.writeAll(self.ctx, bytes);
    }
    pub fn readSome(self: Transport, buf: []u8, timeout_ms: i64) !usize {
        return self.vtable.readSome(self.ctx, buf, timeout_ms);
    }
    pub fn close(self: Transport) void {
        self.vtable.close(self.ctx);
    }
};

/// A JSON-RPC error the server returned. `code == -32801` is "content modified",
/// the one error worth retrying (the server changed its mind mid-edit).
pub const Fail = struct { code: i64 = 0, message: []const u8 = "" };

/// Either the `result` of a response or the `error` in it.
pub const Response = union(enum) {
    ok: std.json.Value,
    err: Fail,
};

const Doc = struct { version: i64, hash: u64 };

pub const Client = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    transport: Transport,
    /// The `initialize` root. Owned.
    root_uri: []const u8,
    /// The language id sent in `didOpen`; a static string from the server table.
    language_id: []const u8,
    in_buf: std.ArrayList(u8) = .empty,
    next_id: i64 = 1,
    init_timeout_ms: i64 = 30_000,
    request_timeout_ms: i64 = 15_000,
    /// Documents sent to this server: uri -> version + content hash.
    docs: std.StringHashMapUnmanaged(Doc) = .empty,
    lock: std.atomic.Mutex = .unlocked,
    /// The last `initialize` failure, for the manager's message. Fixed buffer, so
    /// it survives the arena that carried the response.
    init_fail: Fail = .{},
    init_fail_buf: [512]u8 = undefined,

    /// Heap-allocated and never copied: `Transport.ctx` points into it and the
    /// `docs` map keeps pointers of its own.
    pub fn create(
        gpa: std.mem.Allocator,
        io: std.Io,
        transport: Transport,
        language_id: []const u8,
        root_uri: []const u8,
    ) !*Client {
        const self = try gpa.create(Client);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .transport = transport,
            .language_id = language_id,
            .root_uri = try gpa.dupe(u8, root_uri),
        };
        return self;
    }

    pub fn destroy(self: *Client) void {
        self.transport.close();
        var it = self.docs.iterator();
        while (it.next()) |e| self.gpa.free(e.key_ptr.*);
        self.docs.deinit(self.gpa);
        self.in_buf.deinit(self.gpa);
        self.gpa.free(self.root_uri);
        self.gpa.destroy(self);
    }

    /// Takes the per-client lock. One request at a time per server, because a
    /// JSON-RPC id is matched against whatever is on the wire: two threads
    /// reading the same pipe interleave and each takes the other's response.
    ///
    /// The wait backs off to a short sleep instead of spinning: the holder is
    /// waiting on a language server, which can take seconds, and a spin for that
    /// long burns a core on a machine that is already compiling.
    pub fn acquire(self: *Client) void {
        var spins: u32 = 0;
        while (!self.lock.tryLock()) {
            spins += 1;
            if (spins > 1000) {
                sleep.nap(@min(spins / 100, 20));
            } else {
                std.Thread.yield() catch {};
            }
        }
    }
    pub fn release(self: *Client) void {
        self.lock.unlock();
    }

    fn nowNs(self: *Client) i64 {
        return @intCast(std.Io.Timestamp.now(self.io, .real).nanoseconds);
    }

    /// Runs the `initialize` handshake and the `initialized` notification.
    pub fn handshake(self: *Client, arena: std.mem.Allocator) !void {
        var aw = std.Io.Writer.Allocating.init(arena);
        try aw.writer.writeAll("{\"processId\":null,\"clientInfo\":{\"name\":\"zode\",\"version\":\"1.0\"},\"rootUri\":");
        try protocol.writeJsonString(&aw.writer, self.root_uri);
        try aw.writer.writeAll(
            ",\"capabilities\":{\"textDocument\":{\"definition\":{},\"references\":{},\"hover\":{\"contentFormat\":[\"markdown\",\"plaintext\"]},\"documentSymbol\":{\"hierarchicalDocumentSymbolSupport\":true},\"implementation\":{},\"callHierarchy\":{}},\"workspace\":{\"symbol\":{}}},\"workspaceFolders\":[{\"uri\":",
        );
        try protocol.writeJsonString(&aw.writer, self.root_uri);
        try aw.writer.writeAll(",\"name\":\"workspace\"}]}");
        const params = aw.toArrayList().items;

        const resp = try self.request(arena, "initialize", params, self.init_timeout_ms);
        switch (resp) {
            .err => |e| {
                self.init_fail = .{ .code = e.code };
                const n = @min(e.message.len, self.init_fail_buf.len);
                @memcpy(self.init_fail_buf[0..n], e.message[0..n]);
                self.init_fail.message = self.init_fail_buf[0..n];
                return error.InitializeFailed;
            },
            .ok => {},
        }
        try self.notify(arena, "initialized", "{}");
    }

    /// Sends the current text of `abs_path` if the server does not have it yet or
    /// has a stale copy, and returns its URI.
    ///
    /// The reference client opens a document once and never updates it, which is
    /// how a language server ends up answering about a version of the file the
    /// agent already edited. The content hash makes the common case (nothing
    /// changed since the last query) cost nothing on the wire while never
    /// leaving the server stale.
    pub fn ensureOpen(self: *Client, arena: std.mem.Allocator, abs_path: []const u8) ![]const u8 {
        const uri = try protocol.pathToUri(arena, abs_path);
        const text = std.Io.Dir.cwd().readFileAlloc(self.io, abs_path, arena, .limited(max_doc_bytes)) catch |e| switch (e) {
            error.StreamTooLong => return error.FileTooBig,
            else => return error.FileReadFailed,
        };
        const h = std.hash.Wyhash.hash(0, text);
        if (self.docs.getPtr(uri)) |d| {
            if (d.hash == h) return uri;
            const v = d.version + 1;
            try self.sendDidChange(arena, uri, v, text);
            d.version = v;
            d.hash = h;
            return uri;
        }
        try self.sendDidOpen(arena, uri, 1, text);
        const key = try self.gpa.dupe(u8, uri);
        errdefer self.gpa.free(key);
        try self.docs.put(self.gpa, key, .{ .version = 1, .hash = h });
        return uri;
    }

    fn sendDidOpen(self: *Client, arena: std.mem.Allocator, uri: []const u8, version: i64, text: []const u8) !void {
        var aw = std.Io.Writer.Allocating.init(arena);
        try aw.writer.writeAll("{\"textDocument\":{\"uri\":");
        try protocol.writeJsonString(&aw.writer, uri);
        try aw.writer.writeAll(",\"languageId\":");
        try protocol.writeJsonString(&aw.writer, self.language_id);
        try aw.writer.print(",\"version\":{d},\"text\":", .{version});
        try protocol.writeJsonString(&aw.writer, text);
        try aw.writer.writeAll("}}");
        try self.notify(arena, "textDocument/didOpen", aw.toArrayList().items);
    }

    fn sendDidChange(self: *Client, arena: std.mem.Allocator, uri: []const u8, version: i64, text: []const u8) !void {
        var aw = std.Io.Writer.Allocating.init(arena);
        try aw.writer.writeAll("{\"textDocument\":{\"uri\":");
        try protocol.writeJsonString(&aw.writer, uri);
        try aw.writer.print(",\"version\":{d}}},\"contentChanges\":[{{\"text\":", .{version});
        try protocol.writeJsonString(&aw.writer, text);
        try aw.writer.writeAll("}]}");
        try self.notify(arena, "textDocument/didChange", aw.toArrayList().items);
    }

    /// A request that waits for its response. `response` is the JSON-RPC error
    /// (code + message) rather than a Zig error, so the caller can decide whether
    /// `-32801` is worth a retry.
    pub fn request(self: *Client, arena: std.mem.Allocator, method: []const u8, params_json: []const u8, timeout_ms: i64) !Response {
        const id = self.next_id;
        self.next_id += 1;
        var aw = std.Io.Writer.Allocating.init(arena);
        try aw.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, params_json });
        try self.sendFrame(arena, aw.toArrayList().items);
        return self.awaitResponse(arena, id, timeout_ms);
    }

    pub fn notify(self: *Client, arena: std.mem.Allocator, method: []const u8, params_json: []const u8) !void {
        var aw = std.Io.Writer.Allocating.init(arena);
        try aw.writer.print("{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}", .{ method, params_json });
        try self.sendFrame(arena, aw.toArrayList().items);
    }

    fn sendFrame(self: *Client, arena: std.mem.Allocator, body: []const u8) !void {
        const framed = try protocol.frame(arena, body);
        try self.transport.writeAll(framed);
    }

    fn awaitResponse(self: *Client, arena: std.mem.Allocator, id: i64, timeout_ms: i64) !Response {
        const deadline = self.deadlineNs(timeout_ms);
        while (true) {
            const msg = try self.readMessage(arena, deadline);
            const obj = switch (msg) {
                .object => |o| o,
                else => continue,
            };
            const idv = obj.get("id") orelse continue;
            const has_method = obj.get("method") != null;
            if (has_method) {
                // A request FROM the server (progress creation, configuration).
                // Answering with a null result keeps a server that waits for it
                // from hanging on our silence.
                if (idv == .integer) {
                    var aw = std.Io.Writer.Allocating.init(arena);
                    try aw.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{idv.integer});
                    try self.sendFrame(arena, aw.toArrayList().items);
                }
                continue;
            }
            if (idv != .integer or idv.integer != id) continue;
            if (obj.get("error")) |e| {
                const eobj = switch (e) {
                    .object => |o| o,
                    else => continue,
                };
                const code = if (eobj.get("code")) |c| (if (c == .integer) c.integer else 0) else 0;
                const message = if (eobj.get("message")) |m| (if (m == .string) m.string else "") else "";
                return .{ .err = .{ .code = code, .message = message } };
            }
            return .{ .ok = obj.get("result") orelse .null };
        }
    }

    fn deadlineNs(self: *Client, timeout_ms: i64) i64 {
        if (timeout_ms <= 0) return 0;
        return self.nowNs() + timeout_ms * std.time.ns_per_ms;
    }

    /// Reads one complete JSON message, waiting until `deadline` (0 = forever).
    fn readMessage(self: *Client, arena: std.mem.Allocator, deadline: i64) !std.json.Value {
        while (true) {
            if (try self.extract(arena)) |v| return v;
            var tmp: [16 * 1024]u8 = undefined;
            const n = self.transport.readSome(&tmp, self.remainingMs(deadline)) catch |e| switch (e) {
                error.Timeout => return error.Timeout,
                else => return e,
            };
            if (n == 0) return error.ServerClosed;
            try self.in_buf.appendSlice(self.gpa, tmp[0..n]);
            if (self.in_buf.items.len > max_frame_bytes) return error.MessageTooLarge;
        }
    }

    fn remainingMs(self: *Client, deadline: i64) i64 {
        if (deadline <= 0) return 24 * 60 * 60 * 1000;
        const d = deadline - self.nowNs();
        if (d <= 0) return 0;
        return @divTrunc(d, std.time.ns_per_ms) + 1;
    }

    /// Parses one framed message out of `in_buf`, consuming its bytes. Returns
    /// null when the buffer does not hold a full frame yet.
    fn extract(self: *Client, arena: std.mem.Allocator) !?std.json.Value {
        const buf = self.in_buf.items;
        const hdr_end = protocol.headerEnd(buf) orelse return null;
        const len = protocol.contentLength(buf[0..hdr_end]) orelse return error.BadHeader;
        if (len > max_frame_bytes) return error.MessageTooLarge;
        if (buf.len < hdr_end + len) return null;
        const body = buf[hdr_end .. hdr_end + len];
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return error.BadJson;
        const consumed = hdr_end + len;
        const rest = buf.len - consumed;
        std.mem.copyForwards(u8, buf[0..rest], buf[consumed..]);
        self.in_buf.shrinkRetainingCapacity(rest);
        return v;
    }
};

// ── tests: a scripted transport, no process ──────────────────────────────

const Fake = struct {
    gpa: std.mem.Allocator,
    responses: []const u8,
    pos: usize = 0,
    written: std.ArrayList(u8) = .empty,

    fn transport(self: *Fake) Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = Transport.VTable{
        .writeAll = writeAll,
        .readSome = readSome,
        .close = close,
    };

    fn writeAll(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        try self.written.appendSlice(self.gpa, bytes);
    }
    fn readSome(ctx: *anyopaque, buf: []u8, timeout_ms: i64) anyerror!usize {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        _ = timeout_ms;
        if (self.pos >= self.responses.len) return error.Timeout;
        const n = @min(buf.len, self.responses.len - self.pos);
        @memcpy(buf[0..n], self.responses[self.pos .. self.pos + n]);
        self.pos += n;
        return n;
    }
    fn close(ctx: *anyopaque) void {
        _ = ctx;
    }

    fn deinit(self: *Fake) void {
        self.written.deinit(self.gpa);
    }
};

fn frameAll(arena: std.mem.Allocator, msgs: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (msgs) |m| {
        try out.appendSlice(arena, try protocol.frame(arena, m));
    }
    return out.items;
}

test "client: initialize handshake and a definition round trip" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const responses = try frameAll(arena, &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{}}}",
        // A notification in between must be skipped, not mistaken for a response.
        "{\"jsonrpc\":\"2.0\",\"method\":\"window/logMessage\",\"params\":{\"type\":3,\"message\":\"hi\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":[{\"uri\":\"file:///a.zig\",\"range\":{\"start\":{\"line\":0,\"character\":0}}}]}",
    });
    var fake = Fake{ .gpa = std.testing.allocator, .responses = responses };
    defer fake.deinit();

    const c = try Client.create(std.testing.allocator, std.testing.io, fake.transport(), "zig", "file:///proj");
    defer c.destroy();

    try c.handshake(arena);
    // The `initialized` notification follows the response.
    try std.testing.expect(std.mem.indexOf(u8, fake.written.items, "\"method\":\"initialized\"") != null);

    const resp = try c.request(arena, "textDocument/definition", "{\"position\":{\"line\":0,\"character\":0}}", 1000);
    try std.testing.expect(resp == .ok);
    try std.testing.expect(resp.ok == .array);
}

test "client: a server request is answered with a null result" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const responses = try frameAll(arena, &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}",
        // The server asks US something first.
        "{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"workspace/configuration\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":7}",
    });
    var fake = Fake{ .gpa = std.testing.allocator, .responses = responses };
    defer fake.deinit();

    const c = try Client.create(std.testing.allocator, std.testing.io, fake.transport(), "zig", "file:///proj");
    defer c.destroy();
    try c.handshake(arena);

    const resp = try c.request(arena, "workspace/symbol", "{\"query\":\"x\"}", 1000);
    try std.testing.expect(resp == .ok);
    try std.testing.expectEqual(@as(i64, 7), resp.ok.integer);
    // The reply to the server's own request carried the server's id.
    try std.testing.expect(std.mem.indexOf(u8, fake.written.items, "{\"jsonrpc\":\"2.0\",\"id\":99,\"result\":null}") != null);
}

test "client: -32801 comes back as an error with its code, not as a crash" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const responses = try frameAll(arena, &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32801,\"message\":\"content modified\"}}",
    });
    var fake = Fake{ .gpa = std.testing.allocator, .responses = responses };
    defer fake.deinit();

    const c = try Client.create(std.testing.allocator, std.testing.io, fake.transport(), "zig", "file:///proj");
    defer c.destroy();
    try c.handshake(arena);

    const resp = try c.request(arena, "textDocument/hover", "{}", 1000);
    try std.testing.expect(resp == .err);
    try std.testing.expectEqual(@as(i64, -32801), resp.err.code);
    try std.testing.expectEqualStrings("content modified", resp.err.message);
}

test "client: a silent server times out instead of hanging forever" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const responses = try frameAll(arena, &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}",
        // Nothing for the second request.
    });
    var fake = Fake{ .gpa = std.testing.allocator, .responses = responses };
    defer fake.deinit();

    const c = try Client.create(std.testing.allocator, std.testing.io, fake.transport(), "zig", "file:///proj");
    defer c.destroy();
    try c.handshake(arena);

    try std.testing.expectError(error.Timeout, c.request(arena, "textDocument/hover", "{}", 50));
}

test "client: ensureOpen sends didOpen, then didChange only when the file changed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.zig", .data = "const a = 1;\n" });
    const abs = try tmp.dir.realPathFileAlloc(std.testing.io, "a.zig", arena);

    const responses = try frameAll(arena, &.{"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}"});
    var fake = Fake{ .gpa = std.testing.allocator, .responses = responses };
    defer fake.deinit();

    const c = try Client.create(std.testing.allocator, std.testing.io, fake.transport(), "zig", "file:///proj");
    defer c.destroy();
    try c.handshake(arena);

    _ = try c.ensureOpen(arena, abs);
    try std.testing.expect(std.mem.indexOf(u8, fake.written.items, "\"method\":\"textDocument/didOpen\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.written.items, "\"languageId\":\"zig\"") != null);

    // Same bytes -> nothing more on the wire.
    const before = fake.written.items.len;
    _ = try c.ensureOpen(arena, abs);
    try std.testing.expectEqual(before, fake.written.items.len);

    // Different bytes -> a full-text didChange with version 2.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.zig", .data = "const a = 2;\n" });
    _ = try c.ensureOpen(arena, abs);
    try std.testing.expect(std.mem.indexOf(u8, fake.written.items[before..], "\"method\":\"textDocument/didChange\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.written.items[before..], "\"version\":2") != null);
}
