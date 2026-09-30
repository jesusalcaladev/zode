const std = @import("std");
const chat = @import("chat.zig");
const zjsonl = @import("zjsonl.zig");

/// Un mensaje de la conversación. Diseño eficiente:
/// - `content` es el texto plano (lo que entra y sale del LLM).
/// - Para assistant con tool_calls guardamos el JSON crudo del server
///   (`tool_calls_json`): el replay es byte-idéntico sin re-serializar.
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
    /// Mensajes en memoria (propietario).
    messages: std.ArrayList(Message),
    /// File handle abierto en append; null = sesión pura en memoria (tests).
    file: ?std.Io.File = null,
    write_buf: [4096]u8 = undefined,
    compress_buf: [1 << 16]u8 = undefined,
    /// Ruta de la sesión (propietario, para mostrar en TUI).
    path: ?[]const u8 = null,
    fw: ?std.Io.File.Writer = null,

    pub fn init(allocator: std.mem.Allocator) Session {
        return .{
            .allocator = allocator,
            .id = undefined,
            .messages = .empty,
        };
    }

    /// Crea una sesión nueva en disco. Devuelve puntero heap porque el
    /// File.Writer interno referencia el write_buf del propio struct
    /// (moverlo por valor lo rompería).
    pub fn create(allocator: std.mem.Allocator, io: std.Io) !*Session {
        const s = try allocator.create(Session);
        errdefer allocator.destroy(s);
        s.* = Session.init(allocator);
        // id: microsegundos en base32 (sin colisiones entre sesiones)
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
        // Streaming writer: appends al final del fd (sin hole de 0xFF).
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

    /// Añade un mensaje a memoria y lo persiste (1 write lineal).
    pub fn append(self: *Session, role: Message.Role, content: []const u8) !void {
        const copy = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(copy);
        try self.messages.append(self.allocator, .{ .role = role, .content = copy });
        if (self.fw != null) try self.persist(&self.messages.items[self.messages.items.len - 1]);
    }

    /// Añade un mensaje con metadatos de tool_calls (asistente).
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

    /// Añade un tool_result.
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

    /// Serializa y escribe una línea JSONL. Sin pretty-print: 1 línea = 1 mensaje.
    /// El content se comprime con DEFLATE si ahorra >=25% (marker "z").
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
            w.writeAll(tj) catch {}; // JSON crudo del server
        }
        if (m.tool_call_id) |id| {
            w.writeAll(",\"tool_call_id\":\"") catch {};
            writeEscaped(w, id) catch {};
            w.writeAll("\",\"tool_name\":\"") catch {};
            writeEscaped(w, m.tool_name orelse "") catch {};
            w.writeAll("\"") catch {};
        }
        w.writeAll("}\n") catch {};
        w.flush() catch {}; // durable por línea
    }

    /// Reabre una sesión existente: carga el historial y sigue persistiendo.
    /// Estrategia sin APIs de seek: reescribe el historial completo una vez
    /// (truncate) y a partir de ahí append normal. O(session) una sola vez.
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

    /// Ruta de la sesión más reciente (por mtime); null si no hay.
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
                    try w.print("\\u{x:0>4}", .{c}); // JSON-safe para binario comprimido
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

/// Reconstruye una sesión desde un archivo JSONL (para `zode --resume`).
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
    // Arena SOLO para el árbol JSON; los datos devueltos se copian al gpa.
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
        // Re-serializa compacto (solo al cargar).
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

    // Crea sesión real y agrega un mensaje grande (tool output típico).
    var used_path: []const u8 = "";
    {
        const s = try Session.create(alloc, io);
        defer alloc.destroy(s); // LIFO: corre DESPUÉS de deinit
        defer s.deinit();
        used_path = try alloc.dupe(u8, s.path.?);
        const big = "const std = @import(\"std\");\n" ** 100; // ~2.8KB
        try s.appendToolResult("call_1", "read", big);
        try s.append(.user, "hola");
        s.flush();
    }
    defer alloc.free(used_path);

    // Verifica que la línea quedó comprimida: content empieza con marker "z".
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, used_path, alloc, .limited(1 << 20));
    defer alloc.free(raw);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    const first = lines.next().?;
    try std.testing.expect(std.mem.indexOf(u8, first, "\"tool_call_id\":\"call_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"content\":\"z") != null);
    try std.testing.expect(first.len < 1400); // 2.8KB -> comprimido

    // Resume: carga y verifica contenido byte-idéntico.
    const s2 = try Session.resumePath(alloc, io, used_path);
    defer alloc.destroy(s2); // LIFO: corre DESPUÉS de deinit
    defer s2.deinit();
    try std.testing.expectEqual(@as(usize, 2), s2.messages.items.len);
    const expected = "const std = @import(\"std\");\n" ** 100;
    try std.testing.expectEqualStrings(expected, s2.messages.items[0].content);
    try std.testing.expectEqualStrings("hola", s2.messages.items[1].content);

    var dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer dir.close(io);
    dir.deleteFile(io, used_path) catch {};
}
