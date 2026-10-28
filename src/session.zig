/// 0600, because a session is a transcript of everything you did.
///
/// It is not a secret store — nothing in it is encrypted — but it holds file contents
/// the agent read, command output, and whatever you pasted, and it is written into the
/// PROJECT DIRECTORY, which on a shared machine or a laptop with several accounts is
/// world-readable by default. Measured before this: `sessions/*.jsonl` came out
/// `-rw-r--r--`.
///
/// The directory gets 0700 for the same reason: a 0755 directory leaks the NAMES of
/// every session you have had, and with the files at 0644 those names were enough to
/// read all of them.
///
/// `auth.json` was already written 0600 (`config.zig`), so the principle was already in
/// the repo and this one file was simply outside it.
const session_mode: std.Io.File.Permissions = @enumFromInt(0o600);
const sessions_dir_mode: std.Io.File.Permissions = @enumFromInt(0o700);

/// Base directory for session files (default "sessions", override with setSessionsDir).
///
/// `setSessionsDir` COPIES into a static buffer: the string comes from an arena that
/// dies, and the pointer must stay valid. The buffer is sized for max_path_bytes.
pub var sessions_dir: []const u8 = "sessions";
var sessions_dir_buf: [std.fs.max_path_bytes]u8 = undefined;

pub fn setSessionsDir(dir: []const u8) void {
    if (dir.len > sessions_dir_buf.len) return;
    @memcpy(sessions_dir_buf[0..dir.len], dir);
    sessions_dir = sessions_dir_buf[0..dir.len];
}

const std = @import("std");
const sessionindex = @import("lib/sessionindex.zig");

/// The first bytes of the goal note, so it can be found again and replaced.
pub const goal_note_marker = "\u{1}ZODE-GOAL\u{1}";
const chat = @import("chat.zig");
const cache_stats = @import("cache_stats.zig");
const zjsonl = @import("lib/zjsonl.zig");

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
    /// Provider-reported usage for this session, persisted as metadata records
    /// in the JSONL and never sent back to the model.
    usage_stats: cache_stats.CacheStats = .{},
    /// The skill listing has been attached to this session's prompt (once per
    /// session, at the end, outside the cacheable system prefix). Reset on
    /// config reload; not persisted to disk.
    skills_sent: bool = false,
    /// Custom title from /rename. Never overwritten by the AI. Persisted via
    /// sessionindex Meta sidecar.
    custom_title: []const u8 = "",
    /// AI-generated title (turn 3). Safe to regenerate. Persisted via
    /// sessionindex Meta sidecar.
    ai_title: []const u8 = "",

    /// Next index for a stored tool result (`sessions/<id>/tool-results/<n>.txt`).
    /// Per session: each session id gets its own tool-results directory, so a
    /// counter starting at zero never collides within a session.
    tool_result_next: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Session {
        return .{
            .allocator = allocator,
            .id = undefined,
            .messages = .empty,
        };
    }

    /// Reset the per-session "skills already attached" flag so the next turn
    /// re-sends the listing. Called on config reload.
    pub fn resetSkillsSent(self: *Session) void {
        self.skills_sent = false;
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
        // `sessions_dir` and not the literal "sessions": it is the BASE for
        // `sessionPath` below, so creating the literal while the file goes to
        // `<state>/projects/<hash>/sessions` left the new session in a directory
        // that did not exist — the first turn of the first session after the
        // state-dir move failed with "could not open the session file".
        if (std.fs.path.isAbsolute(sessions_dir)) {
            // An absolute path does not resolve against `dir`; the state dir is
            // almost always absolute.
            try std.Io.Dir.cwd().createDirPath(io, sessions_dir);
        } else {
            _ = try dir.createDirPathStatus(io, sessions_dir, sessions_dir_mode);
        }
        const file = try dir.createFile(io, s.path.?, .{ .truncate = false });
        // `createFile` takes no mode: POSIX gives 0666 & ~umask, which is 0644 on a
        // default umask. The mode is set on the open file, so there is no window in
        // which the transcript exists at 0644 — which a `create` + `chmod` would have.
        file.setPermissions(io, session_mode) catch {};
        s.file = file;
        s.io = io;
        // Streaming writer: appends at the end of the fd (no 0xFF hole).
        s.fw = std.Io.File.Writer.initStreaming(file, io, &s.write_buf);
        // Persist the empty Meta sidecar so titles can be added later (Phase 30.1).
        // custom_title and ai_title start empty; they are filled by /rename and
        // the turn-3 AI title upgrade respectively.
        sessionindex.writeMeta(io, allocator, s.path.?, .{
            .name = "",
            .model = "",
            .created_at = @intCast(@divTrunc(now.nanoseconds, 1_000_000_000)),
            .custom_title = "",
            .ai_title = "",
        }) catch {};
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
        if (self.custom_title.len > 0) self.allocator.free(self.custom_title);
        if (self.ai_title.len > 0) self.allocator.free(self.ai_title);
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

    /// Appends a SECOND system message, at the end, and removes the previous one.
    ///
    /// Separate from `replaceSystem` because the two have opposite cache behaviour.
    /// `replaceSystem` rewrites message 0, which is the FIRST thing on the wire and
    /// therefore invalidates the whole prefix after it — every tool schema, every
    /// message, every turn. That is the right trade for a prompt that changes once at
    /// startup.
    ///
    /// The goal changes WITHIN a turn, and it is small, so it goes at the END: the
    /// cache is read up to the first byte that differs, so the tools+system+history
    /// prefix keeps hitting across every iteration of the run and only this last
    /// message is new. It also replaces any previous goal note, because a turn that
    /// declares `met` must not leave "keep working towards it" in the next request.
    pub fn setGoalNote(self: *Session, note: ?[]const u8) !void {
        // Drop a previous one. Found by MARKER, not by index: the list is append-only
        // and the note may not be the last message.
        var i: usize = 0;
        while (i < self.messages.items.len) : (i += 1) {
            const m = self.messages.items[i];
            if (m.role != .system) continue;
            if (!std.mem.startsWith(u8, m.content, goal_note_marker)) continue;
            const owned = m.content;
            _ = self.messages.orderedRemove(i);
            self.allocator.free(owned);
            i -= 1;
        }
        const n = note orelse return;
        try self.append(.system, n);
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
        // Load titles from the Meta sidecar (Phase 30.1).
        const meta = sessionindex.readMeta(allocator, io, path);
        if (meta.custom_title.len > 0) {
            const copy = try allocator.dupe(u8, meta.custom_title);
            s.custom_title = copy;
        }
        if (meta.ai_title.len > 0) {
            const copy = try allocator.dupe(u8, meta.ai_title);
            s.ai_title = copy;
        }
        var dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
        defer dir.close(io);
        const file = try dir.createFile(io, path, .{ .truncate = true });
        // Resuming TRUNCATES and rewrites, so the file is recreated: its mode has to be
        // set again, or a session that was 0600 goes back to 0644 on the next resume.
        file.setPermissions(io, session_mode) catch {};
        s.file = file;
        s.fw = std.Io.File.Writer.initStreaming(file, io, &s.write_buf);
        for (s.messages.items) |*m| {
            try s.persist(m);
        }
        if (s.usage_stats.requests > 0) try s.persistUsageSnapshot();
        try s.fw.?.interface.flush();
        return s;
    }

    /// Path of the most recent session (by mtime); null if there is none.
    pub fn latestSessionPath(arena: std.mem.Allocator, io: std.Io) !?[]const u8 {
        return latestSessionPathIn(arena, io, sessions_dir);
    }

    /// The most recent `.jsonl` inside `dir_path`, as a path relative to the
    /// cwd. Split from `latestSessionPath` so a test can point it at a temp
    /// directory instead of the real `sessions/` (hijacking the repo's sessions
    /// would redirect whoever resumes next to a fixture).
    ///
    /// `.iterate = true` is MANDATORY here: without it the directory opens
    /// fine but its cursor cannot be read, `next()` fails on the first call,
    /// the loop ends with nothing and the function reports "no sessions" —
    /// which is how `--resume`, `ZODE_RESUME=1` and `/resume` all answered
    /// "nothing to resume" over a sessions/ full of files, in every release
    /// build (a missing flag only panics in debug, so nothing else saw it).
    pub fn latestSessionPathIn(arena: std.mem.Allocator, io: std.Io, dir_path: []const u8) !?[]const u8 {
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return null;
        defer dir.close(io);

        var it = dir.iterate();
        var best_path: ?[]const u8 = null;
        var best_mtime: i64 = std.math.minInt(i64);
        while (it.next(io) catch null) |e| {
            if (e.kind != .file) continue;
            if (!std.mem.endsWith(u8, e.name, ".jsonl")) continue;
            const full = try std.fs.path.join(arena, &.{ dir_path, e.name });
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

    /// Save a compact cumulative snapshot outside the conversation messages.
    /// Rewriting a session on resume keeps only the latest snapshot.
    pub fn appendUsageSnapshot(self: *Session, stats: cache_stats.CacheStats) !void {
        self.usage_stats = stats;
        try self.persistUsageSnapshot();
    }

    fn persistUsageSnapshot(self: *Session) !void {
        const file_writer = &(self.fw orelse return).interface;
        const json = try std.json.Stringify.valueAlloc(
            self.allocator,
            .{ .event = "usage", .stats = self.usage_stats },
            .{},
        );
        defer self.allocator.free(json);
        try file_writer.writeAll(json);
        try file_writer.writeByte('\n');
        try file_writer.flush();
    }
};

/// One row of `/sessions`.
///
/// `path` is the identity: it is what `--resume` reopens. `name` is what the user
/// called it (empty when they never did), `preview` is the first user message, and
/// the rest is what the filesystem already knows.
///
/// There is no message count on purpose: counting means reading every session to
/// the end, and a `/sessions` that takes a second on a machine with 300 of them is a
/// command people stop typing. `bytes` is a fact `stat` gives for free.
pub const Entry = struct {
    /// Full path (or relative to the cwd) of the `.jsonl`.
    path: []const u8,
    /// File stem: `zode-<id>`.
    id: []const u8,
    /// User-given name; empty when unnamed.
    name: []const u8,
    /// The model the session mostly ran on (from the sidecar); empty when unknown.
    model: []const u8,
    /// First line of the first user message, trimmed and safely cut.
    preview: []const u8,
    /// From the sidecar, or the file's mtime when it has none.
    created_at: i64,
    /// The file's mtime: what "recent" means here.
    last_active: i64,
    bytes: u64,

    /// What the picker shows on the left: the name the user chose, else the first
    /// thing they typed, else the file name. Never empty, so a row is clickable.
    pub fn label(self: Entry) []const u8 {
        if (self.name.len > 0) return self.name;
        if (self.preview.len > 0) return self.preview;
        return self.id;
    }
};

/// Everything in `dir_path` that is a session, most recent first.
///
/// A missing directory is an empty list: `/sessions` before the first session and
/// `/sessions` on a machine whose state dir was just wiped are the same answer.
pub fn list(arena: std.mem.Allocator, io: std.Io, dir_path: []const u8) ![]Entry {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch
        return &.{};
    defer dir.close(io);

    // One buffer for every file's head, instead of one per file: the head is only
    // needed to find the first user message.
    const head = try arena.alloc(u8, 64 * 1024);

    var out: std.ArrayList(Entry) = .empty;
    errdefer out.deinit(arena);

    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .file) continue;
        if (!std.mem.endsWith(u8, e.name, ".jsonl")) continue;
        const st = dir.statFile(io, e.name, .{}) catch continue;

        const path = try std.fs.path.join(arena, &.{ dir_path, e.name });
        const meta = sessionindex.readMeta(arena, io, path);

        var entry = Entry{
            .path = path,
            .id = e.name[0 .. e.name.len - ".jsonl".len],
            .name = meta.name,
            .model = meta.model,
            .preview = "",
            .created_at = if (meta.created_at > 0) meta.created_at else st.mtime.toSeconds(),
            .last_active = st.mtime.toSeconds(),
            .bytes = st.size,
        };
        // Only when it can be the LABEL: a named session already shows the
        // user's own words, and reading 64 KB of every named file to fill a
        // field nobody will see is what makes a 300-session list slow.
        entry.preview = if (entry.name.len > 0) "" else previewOf(arena, io, path, head);
        try out.append(arena, entry);
    }

    const items = try out.toOwnedSlice(arena);
    sortEntriesRecent(items);
    return items;
}

/// Most recent first; ties broken by path so the order is total (and a list does not
/// reshuffle between two runs on files with the same second).
pub fn sortEntriesRecent(items: []Entry) void {
    std.mem.sort(Entry, items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            if (a.last_active != b.last_active) return a.last_active > b.last_active;
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);
}

/// The first user message of a session, on one line and cut to a readable width.
///
/// It reads the HEAD of the file and not the whole of it: the system prompt is the
/// first line and the first user message is right after it, so a transcript of 40 MB
/// costs the same as one of 4 KB. A session with no user message answers "" and the
/// caller falls back to the id.
fn previewOf(arena: std.mem.Allocator, io: std.Io, path: []const u8, head: []u8) []const u8 {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return "";
    defer file.close(io);
    const n = file.readPositionalAll(io, head, 0) catch return "";

    // A line can be cut by the buffer's end; it is then unparseable and skipped,
    // which is correct: we are looking for the FIRST complete user message.
    var lines = std.mem.splitScalar(u8, head[0..n], '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const m = parseLine(arena, line) catch continue;
        if (m.role != .user) continue;
        return firstLineCut(arena, m.content, 96);
    }
    return "";
}

/// One line, trimmed, at most `max_bytes` bytes and never inside a UTF-8 sequence.
fn firstLineCut(arena: std.mem.Allocator, text: []const u8, max_bytes: usize) []const u8 {
    const nl = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const line = text[0..nl];
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len <= max_bytes) return arena.dupe(u8, trimmed) catch "";
    // Cut at byte boundary, then walk back to UTF-8 boundary.
    var cut = trimmed[0..max_bytes];
    while (cut.len > 0 and (cut[cut.len - 1] & 0xC0) == 0x80) {
        cut = cut[0..cut.len - 1];
    }
    return arena.dupe(u8, cut) catch "";
}

/// Rename a session by writing the new name to its sidecar.
/// Both of these take the SESSION path and let `sessionindex` derive the
/// sidecar: the first version derived it here and passed the sidecar in, and
/// `writeMeta` derived it AGAIN, so the name was written to
/// `zode-1.meta.meta.json` and the list never saw it.
pub fn setSessionName(io: std.Io, arena: std.mem.Allocator, path: []const u8, name: []const u8) !void {
    var meta = sessionindex.readMeta(arena, io, path);
    meta.name = try arena.dupe(u8, name);
    try sessionindex.writeMeta(io, arena, path, meta);
}

/// Set the model in the session's sidecar.
pub fn setSessionModel(io: std.Io, arena: std.mem.Allocator, path: []const u8, model: []const u8) !void {
    var meta = sessionindex.readMeta(arena, io, path);
    meta.model = try arena.dupe(u8, model);
    try sessionindex.writeMeta(io, arena, path, meta);
}

/// Frees a list of entries (their path/name/model/preview are in the arena).
pub fn freeEntries(arena: std.mem.Allocator, entries: []Entry) void {
    // Entries are arena-allocated, nothing to free individually.
    _ = arena;
    _ = entries;
}

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
    return std.fmt.allocPrint(allocator, "{s}{c}zode-{s}.jsonl", .{ sessions_dir, std.fs.path.sep, id });
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
        if (parseUsageSnapshot(allocator, line)) |stats| {
            s.usage_stats = stats;
            continue;
        }
        const m = parseLine(allocator, line) catch continue;
        try s.messages.append(allocator, m);
    }
    return s;
}

fn parseUsageSnapshot(gpa: std.mem.Allocator, line: []const u8) ?cache_stats.CacheStats {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch return null;
    if (parsed != .object) return null;
    const event = parsed.object.get("event") orelse return null;
    const stats_value = parsed.object.get("stats") orelse return null;
    if (event != .string or !std.mem.eql(u8, event.string, "usage") or stats_value != .object) return null;
    const obj = stats_value.object;
    return .{
        .prompt_tokens = getI64(obj, "prompt_tokens") orelse return null,
        .cached_tokens = getI64(obj, "cached_tokens") orelse return null,
        .completion_tokens = getI64(obj, "completion_tokens") orelse return null,
        .requests = getUsize(obj, "requests") orelse return null,
        .cache_hits = getUsize(obj, "cache_hits") orelse return null,
        .cache_write_tokens = getI64(obj, "cache_write_tokens") orelse return null,
        .cache_writes = getUsize(obj, "cache_writes") orelse return null,
        .prev_prompt = getI64(obj, "prev_prompt") orelse return null,
        .prompt_shrinks = getUsize(obj, "prompt_shrinks") orelse return null,
        .compacted_at = getUsize(obj, "compacted_at") orelse return null,
        .unexplained_shrinks = getUsize(obj, "unexplained_shrinks") orelse return null,
    };
}

fn getI64(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return if (value == .integer) value.integer else null;
}

fn getUsize(obj: std.json.ObjectMap, key: []const u8) ?usize {
    const value = getI64(obj, key) orelse return null;
    if (value < 0) return null;
    return std.math.cast(usize, value);
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

test "session append + persist in memory" {
    var s = Session.init(std.testing.allocator);
    defer s.deinit();
    try s.append(.user, "hola \"mundo\"\nlinea2");
    try s.appendAssistant("respuesta", "[{\"id\":\"c1\",\"type\":\"function\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"a.zig\\\"}\"}}]");
    try s.appendToolResult("c1", "read", "contenido");
    try std.testing.expectEqual(@as(usize, 3), s.messages.items.len);
    try std.testing.expectEqualStrings("hola \"mundo\"\nlinea2", s.messages.items[0].content);
}

test "round trip: session compressed on disk" {
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
        var stats: cache_stats.CacheStats = .{};
        stats.record(.{ .prompt = 1200, .cached = 800, .completion = 250 });
        try s.appendUsageSnapshot(stats);
        s.flush();
    }
    defer alloc.free(used_path);
    defer std.Io.Dir.cwd().deleteFile(io, used_path) catch {};

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
    try std.testing.expectEqual(@as(usize, 2), s2.messages.items.len);
    try std.testing.expectEqual(@as(usize, 1), s2.usage_stats.requests);
    try std.testing.expectEqual(@as(i64, 1200), s2.usage_stats.prompt_tokens);
    try std.testing.expectEqual(@as(i64, 800), s2.usage_stats.cached_tokens);
}

test "latestSessionPath: finds a .jsonl in the directory (the iterate flag)" {
    // The regression this pins: the directory was opened WITHOUT
    // `.iterate = true`, so `next()` failed on the first call, the loop ended
    // empty and the function answered "no sessions" — which is how `--resume`,
    // `ZODE_RESUME=1` and `/resume` all said "nothing to resume" over a
    // sessions/ full of files in every release build. Here it answers with the
    // file, or the bug is back.
    const io = std.testing.io;
    const root = "/tmp/zode-latest-session-test";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = "/tmp/zode-latest-session-test/zode-fixture.jsonl",
        .data = "{\"role\":\"user\",\"content\":\"x\"}\n",
    });
    // Not a session file: ignored rather than resumed.
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = "/tmp/zode-latest-session-test/notes.txt",
        .data = "x",
    });

    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const found = try Session.latestSessionPathIn(astate.allocator(), io, root);
    try std.testing.expect(found != null);
    try std.testing.expect(std.mem.endsWith(u8, found.?, "/zode-fixture.jsonl"));

    // An empty directory is null, not a panic and not the first name it saw.
    const empty = "/tmp/zode-latest-session-test-empty";
    std.Io.Dir.cwd().deleteTree(io, empty) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, empty) catch {};
    try std.Io.Dir.cwd().createDirPath(io, empty);
    try std.testing.expect(try Session.latestSessionPathIn(astate.allocator(), io, empty) == null);
}

test "create: an ABSOLUTE sessions_dir is created, and the file lands inside it" {
    // The state dir move (`sessionpath`): `create` used to `createDirPath` the
    // literal "sessions" while writing the file to `sessions_dir`, so the first
    // session of a project without a legacy dir failed with "file not found" —
    // or worse, wrote into a `sessions/` inside the repository. An absolute path
    // does not resolve against the cwd dir handle, which is the other half.
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const root = try std.fmt.allocPrint(a, "/tmp/zode-session-create-{d}/nested", .{std.testing.random_seed});
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    setSessionsDir(root);
    defer setSessionsDir("sessions");

    const s = try Session.create(std.testing.allocator, io);
    defer {
        s.deinit();
        std.testing.allocator.destroy(s);
    }

    const path = s.path orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.startsWith(u8, path, root));
    try std.testing.expect(std.mem.endsWith(u8, path, ".jsonl"));
    const st = try std.Io.Dir.cwd().statFile(io, path, .{});
    try std.testing.expectEqual(std.Io.File.Kind.file, st.kind);
    // The repo-relative dir was NOT created as a side effect.
    try std.testing.expect(!std.mem.startsWith(u8, path, "sessions/"));
}
