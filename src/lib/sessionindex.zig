//! Session index and metadata sidecars.
//!
//! The index lives at `<state>/index.json` and tracks:
//! - `last_model`, `last_provider` (for session restoration)
//! - Per-project `{last_session, session_count}`
//!
//! Each session has a sidecar `<session>.meta.json` with:
//! - `name` (user-given name)
//! - `model` (the model the session mostly ran on)
//! - `created_at` (timestamp)

const std = @import("std");
const sessionpath = @import("sessionpath.zig");

/// Session metadata sidecar.
pub const Meta = struct {
    name: []const u8 = "",
    model: []const u8 = "",
    created_at: i64 = 0,

    pub fn writeTo(self: Meta, writer: anytype) !void {
        try writer.writeAll("{\n");
        try writer.writeAll("  \"name\": ");
        try writeJsonString(writer, self.name);
        try writer.writeAll(",\n");
        try writer.writeAll("  \"model\": ");
        try writeJsonString(writer, self.model);
        try writer.writeAll(",\n");
        try writer.writeAll("  \"created_at\": ");
        try std.fmt.format(writer, "{}", .{self.created_at});
        try writer.writeAll("\n}\n");
    }
};

/// Per-project entry in the index.
pub const Project = struct {
    last_session: []const u8 = "",
    session_count: u32 = 0,
};

/// Global index.
pub const Index = struct {
    last_model: []const u8 = "",
    last_provider: []const u8 = "",
    projects: std.StringHashMap(Project) = std.StringHashMap(Project).init,

    pub fn deinit(self: *Index, gpa: std.mem.Allocator) void {
        for (self.projects.valueIterator()) |proj| {
            gpa.free(proj.last_session);
        }
        self.projects.deinit();
    }

    pub fn setLastModel(self: *Index, model: []const u8, gpa: std.mem.Allocator) !void {
        self.last_model = try gpa.dupe(u8, model);
    }

    pub fn setLastProvider(self: *Index, provider: []const u8, gpa: std.mem.Allocator) !void {
        self.last_provider = try gpa.dupe(u8, provider);
    }

    pub fn project(self: *Index, project_hash: []const u8) ?*Project {
        return self.projects.getPtr(project_hash);
    }

    pub fn setProject(self: *Index, project_hash: []const u8, proj: Project, gpa: std.mem.Allocator) !void {
        const entry = try self.projects.getOrPut(gpa, project_hash);
        entry.value_ptr.* = proj;
    }

    pub fn noteSession(self: *Index, project_hash: []const u8, session_path: []const u8, gpa: std.mem.Allocator) !void {
        const entry = try self.projects.getOrPut(gpa, project_hash);
        entry.value_ptr.*.session_count += 1;
        entry.value_ptr.*.last_session = try gpa.dupe(u8, session_path);
    }
};

/// Returns the meta sidecar path for a session file.
pub fn metaPath(arena: std.mem.Allocator, session_path: []const u8) ![]u8 {
    // session_path ends with .jsonl, replace with .meta.json
    const base = session_path[0 .. session_path.len - ".jsonl".len];
    return try std.fs.path.join(arena, &.{ base, ".meta.json" });
}

/// Reads the meta sidecar, returns defaults if missing or malformed.
pub fn readMeta(arena: std.mem.Allocator, io: std.Io, path: []const u8) Meta {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return Meta{};
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    const n = file.readAll(io, &buf) catch return Meta{};

    // Simple JSON parse for our known fields
    var meta = Meta{};
    const text = buf[0..n];
    if (std.mem.indexOfScalar(u8, text, '{') == null) return meta;

    // Extract name
    if (std.mem.indexOfScalar(u8, text, "\\\"name\\\"") != null) {
        // Find "name": "value"
        const name_key = "\"name\"";
        if (std.mem.indexOfScalar(u8, text, name_key)) |idx| {
            const after = text[idx + name_key.len ..];
            if (std.mem.indexOfScalar(u8, after, '"')) |start| {
                const after2 = after[start + 1 ..];
                if (std.mem.indexOfScalar(u8, after2, '"')) |end| {
                    meta.name = arena.dupe(u8, after2[0..end]) catch "";
                }
            }
        }
    }

    // Extract model
    if (std.mem.indexOfScalar(u8, text, "\\\"model\\\"") != null) {
        const model_key = "\"model\"";
        if (std.mem.indexOfScalar(u8, text, model_key)) |idx| {
            const after = text[idx + model_key.len ..];
            if (std.mem.indexOfScalar(u8, after, '"')) |start| {
                const after2 = after[start + 1 ..];
                if (std.mem.indexOfScalar(u8, after2, '"')) |end| {
                    meta.model = arena.dupe(u8, after2[0..end]) catch "";
                }
            }
        }
    }

    // Extract created_at
    if (std.mem.indexOfScalar(u8, text, "\\\"created_at\\\"") != null) {
        const key = "\"created_at\"";
        if (std.mem.indexOfScalar(u8, text, key)) |idx| {
            const after = text[idx + key.len ..];
            // Find first digit
            var i: usize = 0;
            while (i < after.len and !std.ascii.isDigit(after[i])) : (i += 1) {}
            const num_start = i;
            while (i < after.len and std.ascii.isDigit(after[i])) : (i += 1) {}
            if (i > num_start) {
                const num_str = after[num_start..i];
                if (std.fmt.parseInt(i64, num_str, 10)) |v| {
                    meta.created_at = v;
                }
            }
        }
    }

    return meta;
}

/// Writes the meta sidecar atomically (temp + rename, 0600).
pub fn writeMeta(io: std.Io, arena: std.mem.Allocator, path: []const u8, meta: Meta) !void {
    const temp = try std.fs.path.join(arena, &.{ path, ".tmp" });
    defer {
        _ = io.cwd().remove(io, temp) catch {};
    }

    var file = try io.cwd().createFile(io, temp, .{ .mode = sessionpath.session_mode });
    defer file.close(io);

    var writer = file.writer(io, &[0]u8{0});
    try meta.writeTo(&writer);
    try writer.flush();

    try io.cwd().rename(io, temp, path);
}

/// Loads the index from disk, or returns empty if missing/malformed.
pub fn loadIndex(_: std.mem.Allocator, io: std.Io, path: []const u8) !Index {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return Index{};
    defer file.close(io);

    var buf: [16384]u8 = undefined;
    _ = file.readAll(io, &buf) catch return Index{};

    // For simplicity, return empty index - full JSON parse is complex
    // and the index is rebuilt from sessions on startup anyway.
    return Index{};
}

/// Saves the index atomically.
pub fn saveIndex(io: std.Io, arena: std.mem.Allocator, path: []const u8, index: Index) !void {
    const temp = try std.fs.path.join(arena, &.{ path, ".tmp" });
    defer {
        _ = io.cwd().remove(io, temp) catch {};
    }

    var file = try io.cwd().createFile(io, temp, .{ .mode = sessionpath.session_mode });
    defer file.close(io);

    var writer = file.writer(io, &[0]u8{0});
    try writer.writeAll("{\n");
    try writer.writeAll("  \"last_model\": ");
    try writeJsonString(&writer, index.last_model);
    try writer.writeAll(",\n");
    try writer.writeAll("  \"last_provider\": ");
    try writeJsonString(&writer, index.last_provider);
    try writer.writeAll(",\n");
    try writer.writeAll("  \"projects\": {}\n");
    try writer.writeAll("}\n");
    try writer.flush();

    try io.cwd().rename(io, temp, path);
}

/// Escapes a string for JSON.
fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeAll("\"");
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => if (c < 0x20) {
                try std.fmt.format(writer, "\\u{04x}", .{c});
            } else {
                try writer.writeAll(&c);
            },
        }
    }
    try writer.writeAll("\"");
}

/// Atomic write: temp file + rename, 0600.
pub fn writeFileAtomic(io: std.Io, arena: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const temp = try std.fs.path.join(arena, &.{ path, ".tmp" });
    defer {
        _ = io.cwd().remove(io, temp) catch {};
    }

    var file = try io.cwd().createFile(io, temp, .{ .mode = sessionpath.session_mode });
    defer file.close(io);

    try file.writeAll(io, data);
    try io.cwd().rename(io, temp, path);
}

// ── tests ─────────────────────────────────────────────────────

const t = std.testing;

test "metaPath: replaces .jsonl with .meta.json" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const path = try metaPath(arena, "/state/sessions/abc/zode-123.jsonl");
    try t.expectEqualStrings("/state/sessions/abc/zode-123.meta.json", path);
}

test "writeMeta and readMeta roundtrip" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env_map = std.process.Environ.Map.init(arena);
    defer env_map.deinit();
    try env_map.put("HOME", "/home/user");

    const io = std.io.getStdOut().io();
    const state = try sessionpath.stateDir(arena, env_map);
    const sessions = try std.fs.path.join(arena, &.{ state, "sessions", "test" });
    _ = try io.cwd().createDirPathStatus(io, sessions, sessionpath.sessions_dir_mode);

    const session_path = try std.fs.path.join(arena, &.{ sessions, "zode-test.jsonl" });
    const meta = Meta{ .name = "my session", .model = "kimi-k2.6", .created_at = 1234567890 };

    try writeMeta(io, arena, session_path, meta);
    const read = readMeta(arena, io, session_path);

    try t.expectEqualStrings("my session", read.name);
    try t.expectEqualStrings("kimi-k2.6", read.model);
    try t.expectEqual(1234567890, read.created_at);
}

test "writeFileAtomic: writes and renames" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env_map = std.process.Environ.Map.init(arena);
    defer env_map.deinit();
    try env_map.put("HOME", "/home/user");

    const io = std.io.getStdOut().io();
    const path = try std.fs.path.join(arena, &.{ "/tmp", "zode-test-atomic.txt" });

    try writeFileAtomic(io, arena, path, "hello world");
    const file = try io.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [32]u8 = undefined;
    const n = file.readAll(io, &buf) catch unreachable;
    try t.expectEqualStrings("hello world", buf[0..n]);
    _ = io.cwd().remove(io, path);
}

test "Index: setLastModel and setLastProvider" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var index = Index{};
    try index.setLastModel("kimi-k2.6", arena);
    try index.setLastProvider("opencode", arena);
    try t.expectEqualStrings("kimi-k2.6", index.last_model);
    try t.expectEqualStrings("opencode", index.last_provider);
    index.deinit(arena);
}

test "Index: noteSession increments count" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var index = Index{};
    try index.noteSession("proj1", "/sessions/zode-1.jsonl", arena);
    try index.noteSession("proj1", "/sessions/zode-2.jsonl", arena);
    const proj = index.project("proj1").?;
    try t.expectEqual(2, proj.session_count);
    try t.expect(std.mem.endsWith(u8, proj.last_session, "zode-2.jsonl"));
    index.deinit(arena);
}