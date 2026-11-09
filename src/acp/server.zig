//! ACP stdio server: zode acts as an Agent Client Protocol agent.
//!
//! Transport: JSON-RPC 2.0 over stdio, one UTF-8 message per line (NDJSON).
//! stdout is protocol-only; diagnostics go to stderr.
//!
//! Efficiency/correctness notes:
//! - The main thread only reads stdin and dispatches messages. `session/prompt`
//!   runs on a worker thread so the main loop can receive agent->client responses
//!   (e.g. session/request_permission) while a turn is in progress.
//! - Streaming text chunks are emitted with a direct JSON writer (no
//!   `std.json.Stringify.valueAlloc` per delta) to reduce allocation/syscall overhead.
//! - Stdout writes are serialized with a mutex; each NDJSON message is flushed as a line.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const protocol = @import("protocol.zig");
const chat = @import("../chat.zig");
const http_client = @import("../lib/http_client.zig");
const providers = @import("../lib/providers.zig");
const tools_mod = @import("../tools_root.zig");
const session_mod = @import("../session.zig");
const agent = @import("../agent.zig");
const bgproc = @import("../bgproc.zig");
const taskstore = @import("../lib/taskstore.zig");
const permrules = @import("../lib/permrules.zig");
const compaction_mod = @import("../compaction.zig");
const taskloop = @import("../lib/taskloop.zig");
const models_mod = @import("../lib/models.zig");
const cache_stats = @import("../cache_stats.zig");
const mentions_mod = @import("../lib/mentions.zig");
const plan_mod = @import("../lib/plan.zig");
const lsp_manager = @import("../lsp/manager.zig");
const mcp_manager = @import("../mcp/manager.zig");
const sleep_mod = @import("../lib/sleep.zig");

fn logStderr(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

pub fn run(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map) !u8 {
    // stdout is reserved for ACP protocol. All runtime diagnostics must go to stderr.
    agent.io_global = io;
    agent.gpa_global = gpa;
    agent.environ_global = env;
    agent.api_key_global = if (env) |e| e.get("ZODE_API_KEY") else null;
    tools_mod.initMaxToolOutput(env);
    tools_mod.initDiffLimit(env);
    tools_mod.initGrepCapture(env);
    lsp_manager.init(gpa, io, env);
    defer lsp_manager.shutdown();
    mcp_manager.init(gpa, io, env);
    defer mcp_manager.shutdown();
    agent.initProjectInfo(io, env);
    agent.resolveSessionsDirIn(gpa, env);
    chat.io_global = io;
    models_mod.dbg_io = io;
    agent.loadUserConfig();
    agent.loadPermRules();
    defer agent.shutdownUserConfig();
    defer agent.shutdownBuffers();

    var server = Server.init(gpa, io, env);
    defer server.deinit();
    return server.loop() catch |err| {
        logStderr("zode acp: fatal {t}\n", .{err});
        return 1;
    };
}

const SessionState = struct {
    id: []u8,
    cwd: []u8,
    zode_session: ?*session_mod.Session = null, // heap-owned, stable address
    msgs: std.ArrayList(chat.ChatMessage) = .empty,
    arena_state: std.heap.ArenaAllocator,
    auto_check: agent.AutoCheck = .{},
    plan: plan_mod.Plan = .init(),
    bg: bgproc.Registry = .{},
    tasks: taskstore.Store,
    busy: bool = false,
    cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn deinit(self: *SessionState, gpa: std.mem.Allocator, io: std.Io) void {
        self.bg.deinit(io, gpa);
        if (self.zode_session) |s| {
            s.deinit();
            gpa.destroy(s);
        }
        self.arena_state.deinit();
        gpa.free(self.id);
        gpa.free(self.cwd);
    }
};

const PendingPermission = struct {
    id: protocol.RequestId,
    id_storage: [64]u8 = undefined,
    id_storage_len: u8 = 0,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    outcome: Outcome = .cancelled,
    option_id: ?[]u8 = null,

    const Outcome = enum { selected, cancelled };

    fn idRef(self: *const PendingPermission) protocol.RequestId {
        return switch (self.id) {
            .string => .{ .string = self.id_storage[0..self.id_storage_len] },
            else => self.id,
        };
    }

    fn deinit(self: *PendingPermission, gpa: std.mem.Allocator) void {
        if (self.option_id) |s| gpa.free(s);
    }
};

const PromptJob = struct {
    server: *Server,
    session: *SessionState,
    request_id: protocol.RequestId,
    request_id_storage: [64]u8 = undefined,
    request_id_len: u8 = 0,
    prompt_text: []u8, // owned
};

const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    env: ?*const std.process.Environ.Map,
    write_mu: std.atomic.Mutex = .unlocked,
    next_req_id: std.atomic.Value(i64) = std.atomic.Value(i64).init(1),
    sessions: std.StringHashMapUnmanaged(*SessionState) = .empty,
    sessions_mu: std.atomic.Mutex = .unlocked,
    pending: std.ArrayListUnmanaged(*PendingPermission) = .empty,
    pending_mu: std.atomic.Mutex = .unlocked,
    initialized: bool = false,

    fn init(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map) Server {
        return .{ .gpa = gpa, .io = io, .env = env };
    }

    fn deinit(self: *Server) void {
        var it = self.sessions.iterator();
        while (it.next()) |kv| {
            kv.value_ptr.*.deinit(self.gpa, self.io);
            self.gpa.destroy(kv.value_ptr.*);
        }
        self.sessions.deinit(self.gpa);
        for (self.pending.items) |p| {
            p.deinit(self.gpa);
            self.gpa.destroy(p);
        }
        self.pending.deinit(self.gpa);
    }

    fn lockWrite(self: *Server) void {
        while (!self.write_mu.tryLock()) {
            std.Thread.yield() catch {};
        }
    }
    fn unlockWrite(self: *Server) void {
        self.write_mu.unlock();
    }

    fn sendRaw(self: *Server, bytes: []const u8) void {
        self.lockWrite();
        defer self.unlockWrite();
        const out = std.Io.File.stdout();
        var buf: [16 * 1024]u8 = undefined;
        var fw = out.writer(self.io, &buf);
        fw.interface.writeAll(bytes) catch return;
        fw.interface.flush() catch {};
    }

    fn sendResponse(self: *Server, arena: std.mem.Allocator, id: protocol.RequestId, result: anytype) void {
        const result_json = std.json.Stringify.valueAlloc(arena, result, .{}) catch |err| {
            logStderr("zode acp: sendResponse stringify failed: {t}\n", .{err});
            return;
        };
        const line = protocol.writeResponse(arena, id, result_json) catch |err| {
            logStderr("zode acp: sendResponse encode failed: {t}\n", .{err});
            return;
        };
        self.sendRaw(line);
    }

    fn sendError(self: *Server, arena: std.mem.Allocator, id: protocol.RequestId, code: i64, message: []const u8) void {
        const line = protocol.writeError(arena, id, code, message) catch return;
        self.sendRaw(line);
    }

    fn sendNotification(self: *Server, arena: std.mem.Allocator, method: []const u8, params: anytype) void {
        const params_json = std.json.Stringify.valueAlloc(arena, params, .{}) catch return;
        const line = protocol.writeNotification(arena, method, params_json) catch return;
        self.sendRaw(line);
    }

    /// Efficient streaming chunk: writes JSON directly (no per-delta valueAlloc of the whole envelope).
    fn sendMessageChunk(self: *Server, session_id: []const u8, kind: []const u8, text: []const u8) void {
        // Fast path for common small/medium deltas using a stack buffer; fall back to heap for very large chunks.
        var stack: [8192]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&stack);
        if (writeMessageChunkLine(fba.allocator(), session_id, kind, text)) |line| {
            self.sendRaw(line);
            return;
        } else |_| {}
        // Heap fallback
        const heap_line = writeMessageChunkLine(self.gpa, session_id, kind, text) catch return;
        defer self.gpa.free(heap_line);
        self.sendRaw(heap_line);
    }

    fn nextReqId(self: *Server) protocol.RequestId {
        const id = self.next_req_id.fetchAdd(1, .monotonic);
        return .{ .integer = id };
    }

    fn loop(self: *Server) !u8 {
        if (builtin.os.tag == .windows) return error.UnsupportedPlatform;
        const stdin_handle = std.Io.File.stdin().handle;
        var read_buf: [64 * 1024]u8 = undefined;
        var line_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer line_buf.deinit(self.gpa);

        while (true) {
            const n = std.posix.read(stdin_handle, &read_buf) catch |err| switch (err) {
                error.WouldBlock => {
                    std.Thread.yield() catch {};
                    continue;
                },
                else => 0,
            };
            if (n == 0) return 0;
            try line_buf.appendSlice(self.gpa, read_buf[0..n]);
            while (std.mem.indexOfScalar(u8, line_buf.items, '\n')) |nl| {
                const line = std.mem.trimEnd(u8, line_buf.items[0..nl], "\r");
                self.handleLine(line);
                const rest_len = line_buf.items.len - (nl + 1);
                if (rest_len > 0) std.mem.copyForwards(u8, line_buf.items[0..rest_len], line_buf.items[nl + 1 ..]);
                line_buf.shrinkRetainingCapacity(rest_len);
            }
            if (line_buf.items.len > 16 * 1024 * 1024) return error.MessageTooLarge;
        }
    }

    fn handleLine(self: *Server, line: []const u8) void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const msg = protocol.parseLine(arena, line) catch |err| {
            if (err == error.Empty) return;
            const out = protocol.writeError(arena, .null_id, protocol.ErrorCode.parse_error, "Parse error") catch return;
            self.sendRaw(out);
            return;
        };
        if (msg.isResponse()) {
            self.handleResponse(msg);
            return;
        }
        if (msg.isRequest()) {
            self.handleRequest(arena, msg);
            return;
        }
        if (msg.isNotification()) {
            self.handleNotification(msg);
        }
    }

    fn handleResponse(self: *Server, msg: protocol.Incoming) void {
        const id = msg.id orelse return;
        while (!self.pending_mu.tryLock()) {
            std.Thread.yield() catch {};
        }
        defer self.pending_mu.unlock();
        for (self.pending.items) |p| {
            if (!p.idRef().eql(id)) continue;
            if (msg.has_error) {
                p.outcome = .cancelled;
            } else if (msg.result) |res| {
                if (res == .object) {
                    if (res.object.get("outcome")) |ov| {
                        if (ov == .object) {
                            if (ov.object.get("outcome")) |k| {
                                if (k == .string and std.mem.eql(u8, k.string, "selected")) {
                                    p.outcome = .selected;
                                    if (ov.object.get("optionId")) |oid| {
                                        if (oid == .string) p.option_id = self.gpa.dupe(u8, oid.string) catch null;
                                    }
                                } else {
                                    p.outcome = .cancelled;
                                }
                            }
                        } else if (ov == .string and std.mem.eql(u8, ov.string, "cancelled")) {
                            p.outcome = .cancelled;
                        }
                    }
                }
            }
            p.done.store(true, .release);
            return;
        }
    }

    fn handleNotification(self: *Server, msg: protocol.Incoming) void {
        const method = msg.method orelse return;
        if (std.mem.eql(u8, method, "session/cancel")) {
            if (protocol.paramStr(msg.params, "sessionId")) |sid| {
                if (self.getSession(sid)) |ss| ss.cancel_requested.store(true, .release);
                chat.cancel_current.store(true, .release);
            }
            return;
        }
        if (std.mem.eql(u8, method, "$/cancel_request")) {
            chat.cancel_current.store(true, .release);
        }
    }

    fn handleRequest(self: *Server, arena: std.mem.Allocator, msg: protocol.Incoming) void {
        const id = msg.id orelse return;
        const method = msg.method orelse return;
        if (std.mem.eql(u8, method, "initialize")) return self.handleInitialize(arena, id);
        if (!self.initialized) return self.sendError(arena, id, protocol.ErrorCode.invalid_request, "Not initialized");
        if (std.mem.eql(u8, method, "authenticate")) return self.sendResponse(arena, id, .{});
        if (std.mem.eql(u8, method, "session/new")) return self.handleSessionNew(arena, id, msg.params);
        if (std.mem.eql(u8, method, "session/load")) return self.handleSessionLoad(arena, id, msg.params);
        if (std.mem.eql(u8, method, "session/resume")) return self.handleSessionResume(arena, id, msg.params);
        if (std.mem.eql(u8, method, "session/list")) return self.handleSessionList(arena, id);
        if (std.mem.eql(u8, method, "session/prompt")) return self.handleSessionPrompt(arena, id, msg.params);
        if (std.mem.eql(u8, method, "session/close")) return self.handleSessionClose(arena, id, msg.params);
        if (std.mem.eql(u8, method, "session/delete")) return self.handleSessionDelete(arena, id, msg.params);
        self.sendError(arena, id, protocol.ErrorCode.method_not_found, "Method not found");
    }

    fn handleInitialize(self: *Server, arena: std.mem.Allocator, id: protocol.RequestId) void {
        self.initialized = true;
        self.sendResponse(arena, id, .{
            .protocolVersion = protocol.protocol_version,
            .agentCapabilities = .{
                .loadSession = true,
                .promptCapabilities = .{ .image = false, .audio = false, .embeddedContext = true },
                .mcpCapabilities = .{ .http = false, .sse = false },
                .sessionCapabilities = .{
                    .@"resume" = .{},
                    .list = .{},
                    .close = .{},
                    .delete = .{},
                },
            },
            .agentInfo = .{ .name = "zode", .title = "zode", .version = build_options.version },
            .authMethods = &[_]u8{},
        });
    }

    fn getSession(self: *Server, id: []const u8) ?*SessionState {
        while (!self.sessions_mu.tryLock()) {
            std.Thread.yield() catch {};
        }
        defer self.sessions_mu.unlock();
        return self.sessions.get(id);
    }

    fn putSession(self: *Server, ss: *SessionState) !void {
        while (!self.sessions_mu.tryLock()) {
            std.Thread.yield() catch {};
        }
        defer self.sessions_mu.unlock();
        try self.sessions.put(self.gpa, ss.id, ss);
    }

    fn removeSession(self: *Server, id: []const u8) ?*SessionState {
        while (!self.sessions_mu.tryLock()) {
            std.Thread.yield() catch {};
        }
        defer self.sessions_mu.unlock();
        if (self.sessions.fetchRemove(id)) |kv| return kv.value;
        return null;
    }

    fn makeSessionState(self: *Server, session_id: []const u8, cwd: []const u8) !*SessionState {
        const ss = try self.gpa.create(SessionState);
        ss.* = .{
            .id = try self.gpa.dupe(u8, session_id),
            .cwd = try self.gpa.dupe(u8, cwd),
            .arena_state = std.heap.ArenaAllocator.init(self.gpa),
            .tasks = .{ .gpa = self.gpa },
        };
        agent.attachAutoCheckEnv(&ss.auto_check, self.env);
        const sys = agent.buildSystemPromptFor(ss.arena_state.allocator(), self.env) catch "You are zode, a coding agent.";
        ss.msgs.append(ss.arena_state.allocator(), .{ .role = "system", .content = sys }) catch {};
        return ss;
    }

    fn reopenLoadedSession(self: *Server, zs: *session_mod.Session) void {
        // load() returns a Session with no append writer. For ACP continued prompts,
        // open the file for append so new turns persist. Safe because zs is heap-owned.
        if (zs.path == null) return;
        var dir = std.Io.Dir.cwd().openDir(self.io, ".", .{}) catch return;
        defer dir.close(self.io);
        const file = dir.createFile(self.io, zs.path.?, .{ .truncate = false }) catch return;
        file.setPermissions(self.io, session_mod.session_mode) catch {};
        zs.file = file;
        zs.io = self.io;
        zs.fw = std.Io.File.Writer.initStreaming(file, self.io, &zs.write_buf);
    }

    fn resolveSessionPath(self: *Server, arena: std.mem.Allocator, session_id: []const u8) ?[]const u8 {
        _ = self;
        if (std.mem.indexOfScalar(u8, session_id, '/') != null or std.mem.endsWith(u8, session_id, ".jsonl")) {
            return arena.dupe(u8, session_id) catch null;
        }
        return std.fmt.allocPrint(arena, "{s}/zode-{s}.jsonl", .{ session_mod.sessions_dir, session_id }) catch null;
    }

    fn setCwdBestEffort(self: *Server, cwd: []const u8) void {
        // Single-process global project info; best-effort for MVP.
        agent.setProjectInfoForTest(self.io, cwd);
        agent.loadPermRules();
    }

    fn handleSessionNew(self: *Server, arena: std.mem.Allocator, id: protocol.RequestId, params: ?std.json.Value) void {
        const cwd = protocol.paramStr(params, "cwd") orelse {
            return self.sendError(arena, id, protocol.ErrorCode.invalid_params, "cwd is required");
        };
        self.setCwdBestEffort(cwd);
        const zs = session_mod.Session.create(self.gpa, self.io) catch {
            return self.sendError(arena, id, protocol.ErrorCode.internal_error, "Could not create session");
        };
        const ss = self.makeSessionState(&zs.id, cwd) catch {
            zs.deinit(); self.gpa.destroy(zs);
            return self.sendError(arena, id, protocol.ErrorCode.internal_error, "Out of memory");
        };
        ss.zode_session = zs;
        self.putSession(ss) catch {
            ss.deinit(self.gpa, self.io); self.gpa.destroy(ss);
            return self.sendError(arena, id, protocol.ErrorCode.internal_error, "Out of memory");
        };
        self.sendResponse(arena, id, .{ .sessionId = ss.id, .modes = null, .configOptions = null });
    }

    fn handleSessionLoad(self: *Server, arena: std.mem.Allocator, id: protocol.RequestId, params: ?std.json.Value) void {
        const session_id = protocol.paramStr(params, "sessionId") orelse {
            return self.sendError(arena, id, protocol.ErrorCode.invalid_params, "sessionId is required");
        };
        const cwd = protocol.paramStr(params, "cwd") orelse {
            return self.sendError(arena, id, protocol.ErrorCode.invalid_params, "cwd is required");
        };
        self.setCwdBestEffort(cwd);
        const path = self.resolveSessionPath(arena, session_id) orelse {
            return self.sendError(arena, id, protocol.ErrorCode.internal_error, "Out of memory");
        };
        const loaded = session_mod.load(self.gpa, self.io, path) catch {
            return self.sendError(arena, id, protocol.ErrorCode.resource_not_found, "Session not found");
        };
        for (loaded.messages.items) |m| {
            switch (m.role) {
                .user => self.sendMessageChunk(&loaded.id, "user_message_chunk", m.content),
                .assistant => if (m.content.len > 0) self.sendMessageChunk(&loaded.id, "agent_message_chunk", m.content),
                .tool, .system => {},
            }
        }
        const zs = self.gpa.create(session_mod.Session) catch {
            var tmp = loaded; tmp.deinit();
            return self.sendError(arena, id, protocol.ErrorCode.internal_error, "Out of memory");
        };
        zs.* = loaded;
        self.reopenLoadedSession(zs);
        const ss = self.makeSessionState(&zs.id, cwd) catch {
            zs.deinit(); self.gpa.destroy(zs);
            return self.sendError(arena, id, protocol.ErrorCode.internal_error, "Out of memory");
        };
        for (zs.messages.items) |m| {
            if (m.role == .system) continue;
            const role: []const u8 = switch (m.role) {
                .user => "user",
                .assistant => "assistant",
                .tool => "tool",
                .system => "system",
            };
            ss.msgs.append(ss.arena_state.allocator(), .{
                .role = role,
                .content = m.content,
                .tool_calls_json = m.tool_calls_json,
                .tool_call_id = m.tool_call_id,
                .tool_name = m.tool_name,
            }) catch {};
        }
        ss.zode_session = zs;
        self.putSession(ss) catch {
            ss.deinit(self.gpa, self.io); self.gpa.destroy(ss);
            return self.sendError(arena, id, protocol.ErrorCode.internal_error, "Out of memory");
        };
        self.sendResponse(arena, id, .{ .modes = null, .configOptions = null });
    }

    fn handleSessionResume(self: *Server, arena: std.mem.Allocator, id: protocol.RequestId, params: ?std.json.Value) void {
        self.handleSessionResumeOrLoad(arena, id, params, false);
    }

    fn handleSessionResumeOrLoad(self: *Server, arena: std.mem.Allocator, id: protocol.RequestId, params: ?std.json.Value, replay: bool) void {
        const session_id = protocol.paramStr(params, "sessionId") orelse {
            return self.sendError(arena, id, protocol.ErrorCode.invalid_params, "sessionId is required");
        };
        const cwd = protocol.paramStr(params, "cwd") orelse {
            return self.sendError(arena, id, protocol.ErrorCode.invalid_params, "cwd is required");
        };
        self.setCwdBestEffort(cwd);
        const path = self.resolveSessionPath(arena, session_id) orelse {
            return self.sendError(arena, id, protocol.ErrorCode.internal_error, "Out of memory");
        };
        const loaded = session_mod.load(self.gpa, self.io, path) catch {
            return self.sendError(arena, id, protocol.ErrorCode.resource_not_found, "Session not found");
        };
        if (replay) {
            for (loaded.messages.items) |m| {
                switch (m.role) {
                    .user => self.sendMessageChunk(&loaded.id, "user_message_chunk", m.content),
                    .assistant => if (m.content.len > 0) self.sendMessageChunk(&loaded.id, "agent_message_chunk", m.content),
                    .tool, .system => {},
                }
            }
        }
        const zs = self.gpa.create(session_mod.Session) catch {
            var tmp = loaded; tmp.deinit();
            return self.sendError(arena, id, protocol.ErrorCode.internal_error, "Out of memory");
        };
        zs.* = loaded;
        self.reopenLoadedSession(zs);
        const ss = self.makeSessionState(&zs.id, cwd) catch {
            zs.deinit(); self.gpa.destroy(zs);
            return self.sendError(arena, id, protocol.ErrorCode.internal_error, "Out of memory");
        };
        for (zs.messages.items) |m| {
            if (m.role == .system) continue;
            ss.msgs.append(ss.arena_state.allocator(), .{
                .role = switch (m.role) { .user => "user", .assistant => "assistant", .tool => "tool", .system => "system" },
                .content = m.content,
                .tool_calls_json = m.tool_calls_json,
                .tool_call_id = m.tool_call_id,
                .tool_name = m.tool_name,
            }) catch {};
        }
        ss.zode_session = zs;
        self.putSession(ss) catch {
            ss.deinit(self.gpa, self.io); self.gpa.destroy(ss);
            return self.sendError(arena, id, protocol.ErrorCode.internal_error, "Out of memory");
        };
        self.sendResponse(arena, id, .{ .modes = null, .configOptions = null });
    }

    fn handleSessionList(self: *Server, arena: std.mem.Allocator, id: protocol.RequestId) void {
        const entries = session_mod.list(arena, self.io, session_mod.sessions_dir) catch &.{};
        const Item = struct { sessionId: []const u8, cwd: ?[]const u8 = null, title: ?[]const u8 = null, updatedAt: ?[]const u8 = null };
        var out: std.ArrayListUnmanaged(Item) = .empty;
        for (entries) |e| {
            const sid = if (std.mem.startsWith(u8, e.id, "zode-")) e.id["zode-".len..] else e.id;
            out.append(arena, .{
                .sessionId = sid,
                .cwd = if (agent.project_info.cwd_len > 0) agent.project_info.cwd() else null,
                .title = blk: {
                    if (e.name.len > 0) break :blk e.name;
                    if (e.preview.len > 0) break :blk e.preview;
                    break :blk null;
                },
                .updatedAt = null,
            }) catch {};
        }
        self.sendResponse(arena, id, .{ .sessions = out.items, .nextCursor = null });
    }

    fn handleSessionClose(self: *Server, arena: std.mem.Allocator, id: protocol.RequestId, params: ?std.json.Value) void {
        const session_id = protocol.paramStr(params, "sessionId") orelse {
            return self.sendError(arena, id, protocol.ErrorCode.invalid_params, "sessionId is required");
        };
        if (self.removeSession(session_id)) |ss| {
            ss.cancel_requested.store(true, .release);
            ss.deinit(self.gpa, self.io);
            self.gpa.destroy(ss);
        }
        self.sendResponse(arena, id, .{});
    }

    fn handleSessionDelete(self: *Server, arena: std.mem.Allocator, id: protocol.RequestId, params: ?std.json.Value) void {
        const session_id = protocol.paramStr(params, "sessionId") orelse {
            return self.sendError(arena, id, protocol.ErrorCode.invalid_params, "sessionId is required");
        };
        if (self.removeSession(session_id)) |ss| {
            ss.cancel_requested.store(true, .release);
            ss.deinit(self.gpa, self.io);
            self.gpa.destroy(ss);
        }
        if (self.resolveSessionPath(arena, session_id)) |path| {
            std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
            inline for (.{ ".meta.json", ".caps.json", ".compact.json" }) |suf| {
                var sbuf: [std.fs.max_path_bytes]u8 = undefined;
                if (std.fmt.bufPrint(&sbuf, "{s}{s}", .{ path, suf })) |sp| {
                    std.Io.Dir.cwd().deleteFile(self.io, sp) catch {};
                } else |_| {}
            }
        }
        self.sendResponse(arena, id, .{});
    }

    fn extractPromptText(arena: std.mem.Allocator, params: ?std.json.Value) ![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        const p = params orelse return "";
        if (p != .object) return "";
        const prompt_v = p.object.get("prompt") orelse return "";
        if (prompt_v != .array) return "";
        for (prompt_v.array.items) |block| {
            if (block != .object) continue;
            const tval = block.object.get("type") orelse continue;
            if (tval != .string) continue;
            if (std.mem.eql(u8, tval.string, "text")) {
                if (block.object.get("text")) |tv| if (tv == .string) {
                    if (out.items.len > 0) try out.appendSlice(arena, "\n");
                    try out.appendSlice(arena, tv.string);
                };
            } else if (std.mem.eql(u8, tval.string, "resource_link")) {
                if (block.object.get("uri")) |uv| if (uv == .string) {
                    if (out.items.len > 0) try out.appendSlice(arena, "\n");
                    try out.appendSlice(arena, uv.string);
                };
            } else if (std.mem.eql(u8, tval.string, "resource")) {
                if (block.object.get("resource")) |rv| if (rv == .object) {
                    if (rv.object.get("text")) |tv| {
                        if (tv == .string) {
                            if (out.items.len > 0) try out.appendSlice(arena, "\n");
                            try out.appendSlice(arena, tv.string);
                        }
                    } else if (rv.object.get("uri")) |uv| if (uv == .string) {
                        if (out.items.len > 0) try out.appendSlice(arena, "\n");
                        try out.appendSlice(arena, uv.string);
                    };
                };
            }
        }
        return out.items;
    }

    fn handleSessionPrompt(self: *Server, arena: std.mem.Allocator, id: protocol.RequestId, params: ?std.json.Value) void {
        const session_id = protocol.paramStr(params, "sessionId") orelse {
            return self.sendError(arena, id, protocol.ErrorCode.invalid_params, "sessionId is required");
        };
        // Copy prompt text before spawning (request arena is freed when this handler returns).
        const prompt_text_src = extractPromptText(arena, params) catch {
            return self.sendError(arena, id, protocol.ErrorCode.invalid_params, "Invalid prompt");
        };
        const prompt_text = self.gpa.dupe(u8, prompt_text_src) catch {
            return self.sendError(arena, id, protocol.ErrorCode.internal_error, "Out of memory");
        };
        errdefer self.gpa.free(prompt_text);

        // Find session and mark busy atomically enough for single-session prompt serialization.
        while (!self.sessions_mu.tryLock()) {
            std.Thread.yield() catch {};
        }
        const ss = self.sessions.get(session_id) orelse {
            self.sessions_mu.unlock();
            self.gpa.free(prompt_text);
            return self.sendError(arena, id, protocol.ErrorCode.resource_not_found, "Session not found");
        };
        if (ss.busy) {
            self.sessions_mu.unlock();
            self.gpa.free(prompt_text);
            return self.sendError(arena, id, protocol.ErrorCode.invalid_request, "Session busy");
        }
        ss.busy = true;
        ss.cancel_requested.store(false, .release);
        self.sessions_mu.unlock();

        chat.cancel_current.store(false, .release);

        const job = self.gpa.create(PromptJob) catch {
            ss.busy = false;
            self.gpa.free(prompt_text);
            return self.sendError(arena, id, protocol.ErrorCode.internal_error, "Out of memory");
        };
        job.* = .{ .server = self, .session = ss, .request_id = id, .prompt_text = prompt_text };
        // Preserve string request ids across thread boundary.
        switch (id) {
            .string => |s| {
                const n: u8 = @intCast(@min(s.len, job.request_id_storage.len));
                @memcpy(job.request_id_storage[0..n], s[0..n]);
                job.request_id_len = n;
                job.request_id = .{ .string = job.request_id_storage[0..n] };
            },
            else => {},
        }

        const t = std.Thread.spawn(.{}, promptThreadMain, .{job}) catch {
            ss.busy = false;
            self.gpa.free(prompt_text);
            self.gpa.destroy(job);
            return self.sendError(arena, id, protocol.ErrorCode.internal_error, "Could not start prompt turn");
        };
        t.detach();
        // Response is sent by the turn thread when complete.
    }

    fn promptThreadMain(job: *PromptJob) void {
        const self = job.server;
        const ss = job.session;
        defer {
            ss.busy = false;
            self.gpa.free(job.prompt_text);
            self.gpa.destroy(job);
        }

        const stop_reason = self.runPromptTurn(ss, job.prompt_text);
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        self.sendResponse(arena_state.allocator(), job.request_id, .{ .stopReason = stop_reason });
    }

    fn sendToolCall(self: *Server, arena: std.mem.Allocator, session_id: []const u8, tool_call_id: []const u8, name: []const u8, kind: []const u8, status: []const u8) void {
        self.sendNotification(arena, "session/update", .{
            .sessionId = session_id,
            .update = .{
                .sessionUpdate = "tool_call",
                .toolCallId = tool_call_id,
                .title = name,
                .name = name,
                .kind = kind,
                .status = status,
            },
        });
    }

    fn sendToolCallUpdate(self: *Server, arena: std.mem.Allocator, session_id: []const u8, tool_call_id: []const u8, status: []const u8, content_text: ?[]const u8) void {
        if (content_text) |ct| {
            const Content = struct {
                type: []const u8 = "content",
                content: struct { type: []const u8 = "text", text: []const u8 },
            };
            var content_arr = [_]Content{.{ .content = .{ .text = ct } }};
            self.sendNotification(arena, "session/update", .{
                .sessionId = session_id,
                .update = .{
                    .sessionUpdate = "tool_call_update",
                    .toolCallId = tool_call_id,
                    .status = status,
                    .content = content_arr[0..],
                },
            });
        } else {
            self.sendNotification(arena, "session/update", .{
                .sessionId = session_id,
                .update = .{
                    .sessionUpdate = "tool_call_update",
                    .toolCallId = tool_call_id,
                    .status = status,
                },
            });
        }
    }

    fn runPromptTurn(self: *Server, ss: *SessionState, prompt_text: []const u8) []const u8 {
        var http = http_client.Http.init(self.gpa, self.io);
        defer http.deinit();
        const turn_arena = ss.arena_state.allocator();

        self.setCwdBestEffort(ss.cwd);

        const def = agent.activeProviderDef(self.env);
        const kind = chat.kindForProvider(def.id);
        var url_buf: [1024]u8 = undefined;
        const url = if (kind == .anthropic)
            std.fmt.bufPrint(&url_buf, "{s}/messages", .{def.base_url}) catch def.base_url
        else
            std.fmt.bufPrint(&url_buf, "{s}/chat/completions", .{def.base_url}) catch def.base_url;
        const key = providers.keyFor(def, self.env);
        var model_name: []const u8 = if (self.env) |e| (e.get("ZODE_MODEL") orelse "") else "";
        if (model_name.len == 0) model_name = agent.userModel();
        if (model_name.len == 0) model_name = def.default_model;
        if (model_name.len == 0) {
            self.sendMessageChunk(ss.id, "agent_message_chunk", "No model configured. Set ZODE_MODEL or configure a default model.");
            return "end_turn";
        }
        var effort_pref = chat.defaultEffort(model_name);
        if (self.env) |e| if (e.get("ZODE_EFFORT")) |ev| {
            effort_pref = chat.Effort.parse(ev) orelse effort_pref;
        };
        effort_pref = chat.clampEffort(model_name, effort_pref);
        var extra_hdrs_buf: [2]http_client.Http.ExtraHeader = undefined;
        var extra_len: usize = 0;
        if (std.mem.eql(u8, def.id, "openrouter")) {
            extra_hdrs_buf[extra_len] = .{ .name = "HTTP-Referer", .value = "https://github.com/jesusalcala/zode" };
            extra_len += 1;
            extra_hdrs_buf[extra_len] = .{ .name = "X-OpenRouter-Title", .value = "zode" };
            extra_len += 1;
        }
        const extra_headers = extra_hdrs_buf[0..extra_len];

        const expanded = mentions_mod.expand(turn_arena, self.io, prompt_text) catch mentions_mod.Expansion{ .text = prompt_text, .files = 0, .missing = 0 };
        ss.msgs.append(turn_arena, .{ .role = "user", .content = expanded.text }) catch {};
        if (ss.zode_session) |zs| zs.append(.user, expanded.text) catch {};

        var policy = taskloop.Policy.init(agent.iterationLimit(), agent.loopBudgetFor(self.env).hard);
        var iteration: usize = 0;
        var last_mark: ?agent.LoopMark = null;
        var body_buf: [256 * 1024]u8 = undefined;

        while (policy.budget.allows(iteration)) : (iteration += 1) {
            if (ss.cancel_requested.load(.acquire) or chat.cancel_current.load(.acquire)) return "cancelled";
            if (iteration > 0) {
                const mark = agent.loopMarkFromGate(ss.auto_check.gate.writes, ss.plan.doneCount(), ss.auto_check.gate.verified_writes);
                const changed = if (last_mark) |lm| !std.meta.eql(lm, mark) else true;
                policy.note(iteration, changed);
                last_mark = mark;
                switch (policy.decide(iteration)) {
                    .work => {},
                    .checkpoint => ss.msgs.append(turn_arena, .{
                        .role = "user",
                        .content = std.fmt.allocPrint(turn_arena, "Checkpoint: {d} iterations used. Keep going and finish what is open.\n", .{iteration}) catch continue,
                    }) catch {},
                    .stop => return "max_turn_requests",
                }
            }

            const cmode = compaction_mod.effectiveMode(self.env, null);
            const comp = if (cmode == .off)
                compaction_mod.nothingElided(ss.msgs.items)
            else
                compaction_mod.elideTier(turn_arena, ss.msgs.items, compaction_mod.budgetFor(self.env, agent.curModelContext()), self.env, agent.curModelContext(), cmode) catch compaction_mod.nothingElided(ss.msgs.items);
            const wire = turn_arena.dupe(chat.ChatMessage, comp.msgs) catch ss.msgs.items;

            const body = chat.buildBodyMessagesCapped(&body_buf, model_name, wire, effort_pref, tools_mod.toolsJson(), kind, agent.outputCapFor(def, self.env)) catch {
                self.sendMessageChunk(ss.id, "agent_message_chunk", "Request too large.");
                return "refusal";
            };

            const Ctx = struct {
                server: *Server,
                session_id: []const u8,
                fn onDelta(ctx: ?*anyopaque, delta: []const u8) void {
                    const c: *@This() = @ptrCast(@alignCast(ctx.?));
                    c.server.sendMessageChunk(c.session_id, "agent_message_chunk", delta);
                }
            };
            var cb_ctx = Ctx{ .server = self, .session_id = ss.id };
            const result = chat.streamChatCtx(self.gpa, &http, url, key, @constCast(body), .{
                .userdata = &cb_ctx,
                .onDelta = Ctx.onDelta,
            }, kind, true, extra_headers) catch |err| {
                const why = chat.lastErrorBody();
                const msg = if (why.len > 0)
                    std.fmt.allocPrint(turn_arena, "Error: {t}: {s}", .{ err, why }) catch "Provider error"
                else
                    std.fmt.allocPrint(turn_arena, "Error: {t}", .{err}) catch "Provider error";
                self.sendMessageChunk(ss.id, "agent_message_chunk", msg);
                return "end_turn";
            };
            defer result.ctx.destroy();
            cache_stats.session.recordFor(chat.last_usage, kind);
            if (ss.cancel_requested.load(.acquire) or chat.cancel_current.load(.acquire)) return "cancelled";

            if (result.ctx.parts.items.len == 0) {
                if (ss.auto_check.exitGate(&ss.bg, self.gpa, self.io)) |refusal| {
                    defer self.gpa.free(refusal);
                    self.sendMessageChunk(ss.id, "agent_message_chunk", refusal);
                    ss.msgs.append(turn_arena, .{ .role = "user", .content = "The harness will not end this run yet: fix the reported issues and continue." }) catch {};
                    continue;
                }
                if (ss.zode_session) |zs| zs.appendAssistant("", null) catch {};
                return "end_turn";
            }

            const tc_json = result.ctx.toolCallsJson(turn_arena) catch "[]";
            ss.msgs.append(turn_arena, .{ .role = "assistant", .content = "", .tool_calls_json = tc_json }) catch {};
            if (ss.zode_session) |zs| zs.appendAssistant("", tc_json) catch {};

            // Load rules once per model response/tool batch (cwd-scoped globals are best-effort).
            agent.loadPermRules();
            const rules = agent.permRuleSet();

            for (result.ctx.parts.items) |*p| {
                const tool_call_id = turn_arena.dupe(u8, p.id.items) catch "call";
                const tool_name = p.name.items;
                const tool_args = if (p.args.items.len == 0) "{}" else p.args.items;
                self.sendToolCall(turn_arena, ss.id, tool_call_id, tool_name, acpToolKind(tool_name), "pending");

                const allowed = self.checkToolPermission(turn_arena, ss, tool_name, tool_args, tool_call_id, rules);
                if (ss.cancel_requested.load(.acquire) or chat.cancel_current.load(.acquire)) return "cancelled";
                if (!allowed) {
                    self.sendToolCallUpdate(turn_arena, ss.id, tool_call_id, "failed", "Permission denied");
                    ss.msgs.append(turn_arena, .{ .role = "tool", .content = "denied: permission required", .tool_call_id = tool_call_id, .tool_name = tool_name }) catch {};
                    if (ss.zode_session) |zs| zs.appendToolResult(tool_call_id, tool_name, "denied: permission required") catch {};
                    continue;
                }

                self.sendToolCallUpdate(turn_arena, ss.id, tool_call_id, "in_progress", null);
                const res = self.execToolAcp(turn_arena, ss, tool_name, tool_args, rules) catch |err| blk: {
                    break :blk std.fmt.allocPrint(turn_arena, "error: {t}", .{err}) catch "error";
                };
                self.sendToolCallUpdate(turn_arena, ss.id, tool_call_id, "completed", res);
                ss.msgs.append(turn_arena, .{ .role = "tool", .content = res, .tool_call_id = tool_call_id, .tool_name = tool_name }) catch {};
                if (ss.zode_session) |zs| zs.appendToolResult(tool_call_id, tool_name, res) catch {};
                const wrote = ss.auto_check.noteWrite(tool_name, tool_args);
                ss.auto_check.afterTool(&ss.bg, self.io, wrote);
                if (std.mem.eql(u8, tool_name, "todo")) _ = agent.applyPlanTo(&ss.plan, tool_args, turn_arena);
            }
            if (ss.auto_check.autoCheckWait(&ss.bg, self.io)) |note| {
                ss.msgs.append(turn_arena, .{ .role = "user", .content = note }) catch {};
            }
        }

        ss.msgs.append(turn_arena, .{ .role = "user", .content = "The iteration budget is exhausted. Tools are disabled for this reply. Summarize what was done and what remains." }) catch {};
        if (chat.buildBodyMessagesCapped(&body_buf, model_name, ss.msgs.items, effort_pref, "", kind, agent.outputCapFor(def, self.env))) |sm_body| {
            const Ctx = struct {
                server: *Server, session_id: []const u8,
                fn onDelta(ctx: ?*anyopaque, delta: []const u8) void {
                    const c: *@This() = @ptrCast(@alignCast(ctx.?));
                    c.server.sendMessageChunk(c.session_id, "agent_message_chunk", delta);
                }
            };
            var cb_ctx = Ctx{ .server = self, .session_id = ss.id };
            if (chat.streamChatCtx(self.gpa, &http, url, key, @constCast(sm_body), .{ .userdata = &cb_ctx, .onDelta = Ctx.onDelta }, kind, true, extra_headers)) |res2| {
                res2.ctx.destroy();
            } else |_| {}
        } else |_| {}
        return "max_turn_requests";
    }

    fn execToolAcp(self: *Server, arena: std.mem.Allocator, ss: *SessionState, name: []const u8, args: []const u8, rules: permrules.Set) ![]const u8 {
        return tools_mod.executeWith(self.io, name, args, arena, &ss.bg, null, &ss.tasks, rules);
    }

    fn checkToolPermission(self: *Server, arena: std.mem.Allocator, ss: *SessionState, tool_name: []const u8, args_json: []const u8, tool_call_id: []const u8, rules: permrules.Set) bool {
        if (!tools_mod.needsPermission(tool_name)) return true;
        const subjects = tools_mod.callSubjects(tool_name, args_json, arena);
        if (permrules.decide(rules.rules, tool_name, subjects)) |d| {
            if (d.action == .allow) return true;
            if (d.action == .deny) return false;
        }
        return self.requestPermissionAcp(arena, ss, tool_name, tool_call_id, subjects);
    }

    fn requestPermissionAcp(self: *Server, arena: std.mem.Allocator, ss: *SessionState, tool_name: []const u8, tool_call_id: []const u8, subjects: []const []const u8) bool {
        const rid = self.nextReqId();
        const pending = self.gpa.create(PendingPermission) catch return false;
        pending.* = .{ .id = rid };
        switch (rid) {
            .string => |s| {
                const n: u8 = @intCast(@min(s.len, pending.id_storage.len));
                @memcpy(pending.id_storage[0..n], s[0..n]);
                pending.id_storage_len = n;
                pending.id = .{ .string = pending.id_storage[0..n] };
            },
            else => {},
        }
        while (!self.pending_mu.tryLock()) {
            std.Thread.yield() catch {};
        }
        self.pending.append(self.gpa, pending) catch {
            self.pending_mu.unlock();
            pending.deinit(self.gpa); self.gpa.destroy(pending);
            return false;
        };
        self.pending_mu.unlock();
        defer {
            while (!self.pending_mu.tryLock()) {
                std.Thread.yield() catch {};
            }
            for (self.pending.items, 0..) |p, i| {
                if (p == pending) { _ = self.pending.swapRemove(i); break; }
            }
            self.pending_mu.unlock();
            pending.deinit(self.gpa);
            self.gpa.destroy(pending);
        }

        const Option = struct { optionId: []const u8, name: []const u8, kind: []const u8 };
        const opts = [_]Option{
            .{ .optionId = "allow-once", .name = "Allow once", .kind = "allow_once" },
            .{ .optionId = "allow-always", .name = "Allow always", .kind = "allow_always" },
            .{ .optionId = "reject-once", .name = "Reject once", .kind = "reject_once" },
            .{ .optionId = "reject-always", .name = "Reject always", .kind = "reject_always" },
        };
        self.sendToolCallUpdate(arena, ss.id, tool_call_id, "pending", null);
        const params_json = std.json.Stringify.valueAlloc(arena, .{
            .sessionId = ss.id,
            .toolCall = .{
                .toolCallId = tool_call_id,
                .title = tool_name,
                .name = tool_name,
                .kind = acpToolKind(tool_name),
                .status = "pending",
            },
            .options = &opts,
        }, .{}) catch return false;
        const line = protocol.writeRequest(arena, rid, "session/request_permission", params_json) catch return false;
        self.sendRaw(line);

        while (!pending.done.load(.acquire)) {
            if (ss.cancel_requested.load(.acquire) or chat.cancel_current.load(.acquire)) return false;
            sleep_mod.nap(5);
        }
        if (pending.outcome != .selected) return false;
        const oid = pending.option_id orelse return false;
        if (std.mem.eql(u8, oid, "allow-once")) return true;
        if (std.mem.eql(u8, oid, "allow-always")) {
            persistAlways(tool_name, subjects, .allow);
            // Refresh rules so subsequent tool calls in this turn see the new rule.
            agent.loadPermRules();
            return true;
        }
        if (std.mem.eql(u8, oid, "reject-always")) {
            persistAlways(tool_name, subjects, .deny);
            agent.loadPermRules();
            return false;
        }
        return false; // reject-once
    }
};

fn writeMessageChunkLine(allocator: std.mem.Allocator, session_id: []const u8, kind: []const u8, text: []const u8) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":");
    try protocol.writeJsonString(w, session_id);
    try w.writeAll(",\"update\":{\"sessionUpdate\":");
    try protocol.writeJsonString(w, kind);
    try w.writeAll(",\"content\":{\"type\":\"text\",\"text\":");
    try protocol.writeJsonString(w, text);
    try w.writeAll("}}}}\n");
    const al = aw.toArrayList();
    // Transfer ownership: do not deinit `aw`'s duplicate view; return the ArrayList's buffer as a slice.
    // The caller owns the allocation (or it's in the provided allocator's arena/buffer).
    return al.items;
}

fn acpToolKind(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "read") or std.mem.eql(u8, name, "glob") or std.mem.eql(u8, name, "grep") or std.mem.eql(u8, name, "list_files") or std.mem.eql(u8, name, "refs")) return "read";
    if (std.mem.eql(u8, name, "write") or std.mem.eql(u8, name, "edit") or std.mem.eql(u8, name, "notebook_edit")) return "edit";
    if (std.mem.eql(u8, name, "rename")) return "move";
    if (std.mem.eql(u8, name, "bash") or std.mem.eql(u8, name, "check") or std.mem.eql(u8, name, "kill")) return "execute";
    if (std.mem.eql(u8, name, "web_fetch") or std.mem.eql(u8, name, "web_search")) return "fetch";
    if (std.mem.eql(u8, name, "think")) return "think";
    if (std.mem.eql(u8, name, "todo") or std.mem.eql(u8, name, "goal")) return "plan";
    return "other";
}

fn persistAlways(tool_name: []const u8, subjects: []const []const u8, action: permrules.Action) void {
    const subject: []const u8 = if (subjects.len > 0) subjects[0] else "*";
    var pat_buf: [512]u8 = undefined;
    const pattern = sanitizePattern(subject, &pat_buf);
    if (action == .allow and permrules.isDangerousPattern(tool_name, pattern)) return;
    var text_buf: [768]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, "{s}({s}) {s}", .{ tool_name, pattern, action.name() }) catch return;
    _ = agent.savePermRule(.{
        .tool = tool_name,
        .pattern = pattern,
        .action = action,
        .source = .user,
        .text = text,
    });
}

fn sanitizePattern(subject: []const u8, buf: []u8) []const u8 {
    const s = std.mem.trim(u8, subject, " \t\r\n");
    if (s.len == 0) return "*";
    var n: usize = 0;
    for (s) |c| {
        if (n + 1 >= buf.len) break;
        if (c == '\n' or c == '\r' or c == 0) continue;
        if (c == ')') {
            if (n + 1 >= buf.len) break;
            buf[n] = '_';
            n += 1;
            continue;
        }
        buf[n] = c;
        n += 1;
    }
    if (n == 0) return "*";
    return buf[0..n];
}