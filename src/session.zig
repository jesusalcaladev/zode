const std = @import("std");
const chat = @import("chat.zig");
const zjsonl = @import("zjsonl.zig");

/// A conversation message. Efficient design:
/// - `content` is the plain text (what goes in and out of the LLM).
/// - For an assistant with tool_calls we store the raw JSON from the server
///   (`tool_calls_json`): the replay is byte-identical without re-serializing.
pub const Message = struct {
    role: Role,
    content: []const u8,
    tool_calls_json: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,

    pub const Role = enum { system, user, assistant, tool };
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    io: std.Io = undefined,
    id: [8]u8,
    /// Messages in memory (owned).
    messages: std.ArrayList(Message),
    /// File handle opened in append mode; null = session purely in memory (tests).
    file: ?std.Io.File = null,
    write_buf: [4096]u8 = undefined,
    compress_buf: [1 << 16]u8 = undefined,
    /// Session path (owned, to show in the TUI).
    path: ?[]const u8 = null,
    fw: ?std.Io.File.Writer = null,

    pub fn init(allocator: std.mem.Allocator) Session {
        return .{
            .allocator = allocator,
            .id = undefined,
            .messages = .empty,
        };
    }

    /// Creates a new session on disk. Returns a heap pointer because the internal
    /// File.Writer references the write_buf of the struct itself (moving it by
    /// value would break it).
    pub fn create(allocator: std.mem.Allocator, io: std.Io) !*Session {
        const s = try allocator.create(Session);
        errdefer allocator.destroy(s);
        s.* = Session.init(allocator);
        // id: microseconds in base32 (no collisions between sessions)
        const now = std.Io.Timestamp.now(io, .real);
        const ts: u64 = @intCast(@divTrunc(now.nanoseconds, 1000));
        const names = "0123456789abcdefghjkmnpqrstvwxyz";
        var i: usize = 0;
        var v = ts;
        while (i < 8) : (i += 1) {
            s.id[i] = names[@intCast(v & 31)];
            v >>= 5;
        }

        s.path = try sessionPath(allocator, &s.id);

        var dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
        defer dir.close(io);
        try dir.createDirPath(io, "sessions");
        const file = try dir.createFile(io, s.path.?, .{ .truncate = false });
        s.file = file;
        s.io = io;
        // Streaming writer: appends at the end of the fd (no 0xFF hole).
        s.fw = std.Io.File.Writer.initStreaming(file, io, &s.write_buf);
        return s;
    }

    pub fn deinit(self: *Session) void {
        if (self.fw != null) self.fw.?.interface.flush() catch {};
        if (self.file) |f| f.close(self.io);
        for (self.messages.items) |m| {
            self.allocator.free(m.content);
            if (m.tool_calls_json) |t| self.allocator.free(t);
            if (m.tool_call_id) |t| self.allocator.free(t);
            if (m.tool_name) |t| self.allocator.free(t);
        }
        self.messages.deinit(self.allocator);
        if (self.path) |p| self.allocator.free(p);
    }

    /// Adds a message to memory and persists it (1 linear write).
    pub fn append(self: *Session, role: Message.Role, content: []const u8) !void {
        const copy = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(copy);
        try self.messages.append(self.allocator, .{ .role = role, .content = copy });
        if (self.fw != null) try self.persist(&self.messages.items[self.messages.items.len - 1]);
    }

    /// Replaces the content of the existing `system` message, or appends one if
    /// there is none.
    ///
    /// It exists because the system prompt now DEPENDS on things that change
    /// during a session (read-only mode on/off, a skill that appeared on disk).
    /// Appending a second `system` would be the exact bug the agent loop had
    /// before: two system messages on the wire, one at the end, and providers
    /// reject or misread that.
    ///
    /// Returns true if it wrote. The JSONL on disk keeps the FIRST system
    /// message: the file is the record of the session, and rewriting it would
    /// mean rewriting an append-only log. So `/resume` brings back the original
    /// prompt and the first request of the resumed session fixes it.
    pub fn replaceSystem(self: *Session, content: []const u8) !bool {
        for (self.messages.items) |*m| {
            if (m.role != .system) continue;
            const copy = try self.allocator.dupe(u8, content);
            errdefer self.allocator.free(copy);
            self.allocator.free(m.content);
            m.content = copy;
            m.tool_calls_json = null;
            return true;
        }
        try self.append(.system, content);
        return true;
    }

    /// Adds a message with tool_calls metadata (assistant).
    pub fn appendAssistant(
        self: *Session,
        content: []const u8,
        tool_calls_json: ?[]const u8,
    ) !void {
        const copy = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(copy);
        var tj: ?[]const u8 = null;
        if (tool_calls_json) |j| {
            tj = try self.allocator.dupe(u8, j);
        }
        errdefer if (tj) |t| self.allocator.free(t);
        try self.messages.append(self.allocator, .{
            .role = .assistant,
            .content = copy,
            .tool_calls_json = tj,
        });
        if (self.fw != null) try self.persist(&self.messages.items[self.messages.items.len - 1]);
    }

    /// Adds a tool_result.
    pub fn appendToolResult(
        self: *Session,
        tool_call_id: []const u8,
        tool_name: []const u8,
        content: []const u8,
    ) !void {
        const copy = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(copy);
        const id = try self.allocator.dupe(u8, tool_call_id);
        errdefer self.allocator.free(id);
        const name = try self.allocator.dupe(u8, tool_name);
        errdefer self.allocator.free(name);
        try self.messages.append(self.allocator, .{
            .role = .tool,
            .content = copy,
            .tool_call_id = id,
            .tool_name = name,
        });
        if (self.fw != null) try self.persist(&self.messages.items[self.messages.items.len - 1]);
    }

    /// Serializes and writes one JSONL line. No pretty-print: 1 line = 1 message.
    /// The content is DEFLATE-compressed if it saves >=25% (marker "z").
    fn persist(self: *Session, m: *const Message) !void {
        if (self.fw == null) return;
        const w = &self.fw.?.interface;
        w.writeAll("{\"role\":\"") catch {};
        w.writeAll(@tagName(m.role)) catch {};
        w.writeAll("\",\"content\":\"") catch {};
        if (zjsonl.compressLine(&self.compress_buf, m.content)) |cline| {
            writeEscaped(w, cline) catch {};
        } else {
            writeEscaped(w, m.content) catch {};
        }
        w.writeAll("\"") catch {};
        if (m.tool_calls_json) |tj| {
            w.writeAll(",\"tool_calls\":") catch {};
            w.writeAll(tj) catch {}; // raw JSON from the server
        }
        if (m.tool_call_id) |id| {
            w.writeAll(",\"tool_call_id\":\"") catch {};
            writeEscaped(w, id) catch {};
            w.writeAll("\",\"tool_name\":\"") catch {};
            writeEscaped(w, m.tool_name orelse "") catch {};
            w.writeAll("\"") catch {};
        }
        w.writeAll("}\n") catch {};
        w.flush() catch {}; // durable per line
    }

    /// Reopens an existing session: loads the history and keeps persisting.
    /// Strategy without seek APIs: rewrite the whole history once (truncate)
    /// and from there on a normal append. O(session) exactly once.
    pub fn resumePath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !*Session {
        const s = try allocator.create(Session);
        errdefer allocator.destroy(s);
        s.* = try load(allocator, io, path);
        s.io = io;
        var dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
        defer dir.close(io);
        const file = try dir.createFile(io, path, .{ .truncate = true });
        s.file = file;
        s.fw = std.Io.File.Writer.initStreaming(file, io, &s.write_buf);
        for (s.messages.items) |*m| {
            try s.persist(m);
        }
        try s.fw.?.interface.flush();
        return s;
    }

    /// Path of the most recent session (by mtime); null if there is none.
    pub fn latestSessionPath(arena: std.mem.Allocator, io: std.Io) !?[]const u8 {
        var dir = std.Io.Dir.cwd().openDir(io, "sessions", .{}) catch return null;
        defer dir.close(io);

        var it = dir.iterate();
        var best_path: ?[]const u8 = null;
        var best_mtime: i64 = std.math.minInt(i64);
        while (it.next(io) catch null) |e| {
            if (e.kind != .file) continue;
            if (!std.mem.endsWith(u8, e.name, ".jsonl")) continue;
            const full = try std.fmt.allocPrint(arena, "sessions/{s}", .{e.name});
            const st = dir.statFile(io, e.name, .{}) catch continue;
            const mtime_s = st.mtime.toSeconds();
            if (mtime_s > best_mtime) {
                best_mtime = mtime_s;
                best_path = full;
            }
        }
        return best_path;
    }

    pub fn flush(self: *Session) void {
        if (self.fw != null) self.fw.?.interface.flush() catch {};
    }
};

fn writeEscaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c}); // JSON-safe for compressed binary
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
}

fn sessionPath(allocator: std.mem.Allocator, id: *const [8]u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "sessions/zode-{s}.jsonl", .{id});
}

/// Rebuilds a session from a JSONL file (for `zode --resume`).
pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Session {
    var s = Session.init(allocator);
    s.io = io;
    s.path = try allocator.dupe(u8, path);

    var dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer dir.close(io);
    const data = try dir.readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const m = parseLine(allocator, line) catch continue;
        try s.messages.append(allocator, m);
    }
    return s;
}

fn parseLine(gpa: std.mem.Allocator, line: []const u8) !Message {
    // Arena ONLY for the JSON tree; the returned data is copied into the gpa.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
    if (parsed != .object) return error.Bad;
    const obj = parsed.object;
    const role_str = obj.get("role") orelse return error.Bad;
    if (role_str != .string) return error.Bad;
    const role: Message.Role = std.meta.stringToEnum(Message.Role, role_str.string) orelse return error.Bad;

    var content: []const u8 = "";
    if (obj.get("content")) |c| {
        if (c == .string) {
            if (zjsonl.isCompressed(c.string)) {
                content = zjsonl.decompressInto(gpa, c.string, 64 * 1024 * 1024) catch
                    try gpa.dupe(u8, c.string);
            } else {
                content = try gpa.dupe(u8, c.string);
            }
        }
    }
    var tcj: ?[]const u8 = null;
    if (obj.get("tool_calls")) |tc| {
        // Re-serialize compactly (only on load).
        tcj = try std.json.Stringify.valueAlloc(gpa, tc, .{});
    }
    var tcid: ?[]const u8 = null;
    var tname: ?[]const u8 = null;
    if (obj.get("tool_call_id")) |v| {
        if (v == .string) tcid = try gpa.dupe(u8, v.string);
    }
    if (obj.get("tool_name")) |v| {
        if (v == .string) tname = try gpa.dupe(u8, v.string);
    }
    return .{ .role = role, .content = content, .tool_calls_json = tcj, .tool_call_id = tcid, .tool_name = tname };
}

test "session append + persist en memoria" {
    var s = Session.init(std.testing.allocator);
    defer s.deinit();
    try s.append(.user, "hola \"mundo\"\nlinea2");
    try s.appendAssistant("respuesta", "[{\"id\":\"c1\",\"type\":\"function\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"a.zig\\\"}\"}}]");
    try s.appendToolResult("c1", "read", "contenido");
    try std.testing.expectEqual(@as(usize, 3), s.messages.items.len);
    try std.testing.expectEqualStrings("hola \"mundo\"\nlinea2", s.messages.items[0].content);
}

test "round trip: sesion comprimida en disco" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // Create a real session and add a big message (typical tool output).
    var used_path: []const u8 = "";
    {
        const s = try Session.create(alloc, io);
        defer alloc.destroy(s); // LIFO: runs AFTER deinit
        defer s.deinit();
        used_path = try alloc.dupe(u8, s.path.?);
        const big = "const std = @import(\"std\");\n" ** 100; // ~2.8KB
        try s.appendToolResult("call_1", "read", big);
        try s.append(.user, "hola");
        s.flush();
    }
    defer alloc.free(used_path);

    // Verify the line came out compressed: content starts with the "z" marker.
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, used_path, alloc, .limited(1 << 20));
    defer alloc.free(raw);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    const first = lines.next().?;
    try std.testing.expect(std.mem.indexOf(u8, first, "\"tool_call_id\":\"call_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"content\":\"z") != null);
    try std.testing.expect(first.len < 1400); // 2.8KB -> compressed

    // Resume: load and verify byte-identical content.
    const s2 = try Session.resumePath(alloc, io, used_path);
    defer alloc.destroy(s2); // LIFO: runs AFTER deinit
    defer s2.deinit();
    try std.testing.expectEqual(@as(usize, 2), s2.messages.items.len);
    const expected = "const std = @import(\"std\");\n" ** 100;
    try std.testing.expectEqualStrings(expected, s2.messages.items[0].content);
    try std.testing.expectEqualStrings("hola", s2.messages.items[1].content);

    var dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer dir.close(io);
    dir.deleteFile(io, used_path) catch {};
}
