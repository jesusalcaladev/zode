//! ACP (Agent Client Protocol v1) client over stdio, to talk to `opencode acp`
//! without going through its terminal.
//!
//! ## What this is
//!
//! `opencode acp` is an ACP AGENT: the client launches it as a child process and
//! speaks newline-delimited JSON-RPC to it over stdin/stdout. It is not the TUI
//! (that has no API) but the very same opencode engine, and it brings what we
//! care about: sessions, text and tool call streaming, permission requests and
//! token usage. See <https://opencode.ai/v2/docs/cli/acp/>.
//!
//! This is the real "trick behind the scenes": zode does not send keystrokes to
//! opencode's terminal, zode talks to opencode.
//!
//! ## Decisions that are not obvious
//!
//! - **The child process is global and lives across turns.** The session (and
//!   its context) lives in the process, not in zode: if one were created per
//!   turn, every prompt would be a new session with no memory. It is started
//!   lazily the first time and then reused.
//! - **`Client` is heap allocated and NEVER copied by value.** The
//!   `Io.File.Reader` keeps a pointer to its buffer, which lives INSIDE the
//!   struct: moving it leaves the pointer dangling (same bug as the
//!   `File.Writer` in `session.zig`).
//! - **Lines are read by hand, without `takeDelimiter`.** `takeDelimiter`
//!   returns `error.StreamTooLong` if the line does not fit in the reader's
//!   buffer, and a `tool_call_update` carrying a 300 KB dump blows it up. Here
//!   it accumulates in an `ArrayList` that grows, with no artificial limit.
//! - **The child's stderr = `.ignore`.** It is a child inside a TUI: if it
//!   wrote to our terminal the banner and the history would fill up with logs.
//!   To debug it, this is `opencode --print-logs acp`.
//! - **We announce MINIMAL client capabilities** (no `fs`, no `terminal`):
//!   opencode runs its own tools, it does not need us to lend it ours, and
//!   this way no request arrives that we cannot answer. Even so, anything we
//!   cannot do is answered with "method not found": otherwise the turn never
//!   ends.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const config = @import("config.zig");

/// Protocol version we speak.
pub const protocol_version = 1;

/// The agent identifies itself with this in the `initialize`.
pub const client_name = "zode";
pub const client_version = "0.3";

/// Default command. Can be changed with `ZODE_ACP_CMD` (space separated words)
/// to try another ACP agent.
pub const default_argv = [_][]const u8{ "opencode", "acp" };

/// JSON-RPC "method not found", for what we do not know how to do.
const code_method_not_found = -32601;

/// A nap of `ms` milliseconds WITHOUT touching the shared `Io`.
///
/// See the `waitTurn` comment: `Io.sleep` hijacks the event loop and freezes
/// the TUI. `nanosleep` is a syscall and disturbs nobody.
///
/// It is `pub` because the agent also uses it while waiting for the connection
/// thread to finish.
pub fn nap(ms: u64) void {
    if (builtin.os.tag != .linux) return;
    const ts = std.os.linux.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.os.linux.nanosleep(&ts, null);
}

/// Is `path` an executable file?
///
/// `std.posix` does not expose `faccessat` in 0.16 and `Io.Dir.access` needs an
/// `Io` (which we do not have here: `resolveArgv` runs before the caller's one
/// is at hand). We call libc's `access(2)`, which is exactly the same thing and
/// adds no dependency: `std.c` is part of the std.
fn isExecutable(io: Io, path: []const u8) bool {
    // NOTE: `std.c.access` is NOT used: that ties the binary to libc, and zode
    // is libc-free on purpose (it allows a musl target). We look at the
    // executable bit of the mode, which is what `X_OK` checks, and additionally
    // that it is a regular file: a DIRECTORY named after the binary has the x
    // bit set and is not usable.
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    if (st.kind == .directory) return false;
    // `permissions` is a `mode_t` enum: the three executable bits (owner, group,
    // other) are 0o111, same as in `X_OK`.
    const mode: u32 = @intCast(@intFromEnum(st.permissions));
    return mode & 0o111 != 0;
}

/// Fills `out` with the argv and `argv[0]` resolved to an ABSOLUTE path, and
/// returns the slice. If it cannot be resolved, returns `argv` as is (so that
/// it is `spawn` that fails with its own error).
///
/// `std.process.spawn` looks it up in the `Io`'s PATH, which need not be zode's
/// environment: with a hand-made `Threaded` it fails with `FileNotFound` even
/// though the binary is in the shell's PATH (that happened with the probe).
/// Here we look it up in the `PATH` of the map the caller passes us and run an
/// absolute path, which `spawn` does not need to look up.
///
/// `out` and `path_buf` are caller buffers because what is returned are slices
/// into them: returning them from here would be a pointer to this function's
/// stack.
fn resolveArgv(
    io: Io,
    env: ?*const std.process.Environ.Map,
    argv: []const []const u8,
    out: [][]const u8,
    path_buf: []u8,
) []const []const u8 {
    if (argv.len == 0 or argv.len > out.len) return argv;
    // With a '/' it is already a path: `spawn` runs it as is.
    if (std.mem.indexOfScalar(u8, argv[0], '/') != null) return argv;
    const map = env orelse return argv;
    const path_s = map.get("PATH") orelse return argv;

    var it = std.mem.splitScalar(u8, path_s, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fmt.bufPrint(path_buf, "{s}/{s}", .{ dir, argv[0] }) catch continue;
        // It has to be EXECUTABLE, not merely to exist: a directory named after
        // the binary does not do. `std.posix` does not expose `faccessat`, so we
        // use libc's `access(2)` via `std.c`, which on Linux is the same thing.
        if (!isExecutable(io, full)) continue;

        @memcpy(out[0..argv.len], argv);
        out[0] = full;
        return out[0..argv.len];
    }
    return argv;
}

pub const Error = error{
    /// The command could not be launched (there is no `opencode` in the PATH).
    SpawnFailed,
    /// The agent did not answer the `initialize` or the `session/new`.
    HandshakeFailed,
    /// A prompt was sent with no session.
    NoSession,
    /// The child closed halfway through a turn.
    AgentDied,
} || std.mem.Allocator.Error || Io.Cancelable;

/// A permission option offered by the agent.
pub const PermOption = struct {
    id: []const u8,
    name: []const u8,
    /// `allow_once` | `allow_always` | `reject_once` | `reject_always`.
    kind: []const u8,
};

/// Where the turn's events go. Everything defaults to a no-op so that a test
/// can declare only what it cares about.
pub const Sink = struct {
    userdata: ?*anyopaque = null,
    onText: *const fn (?*anyopaque, []const u8) void = noopText,
    onThought: *const fn (?*anyopaque, []const u8) void = noopText,
    /// New tool: draw its header.
    onTool: *const fn (?*anyopaque, id: []const u8, name: []const u8, title: []const u8) void = noopTool,
    /// The tool changes state (`in_progress`/`completed`/`failed`).
    onToolUpdate: *const fn (?*anyopaque, id: []const u8, status: []const u8, text: []const u8) void = noopToolUpdate,
    /// A line of the agent's plan.
    onPlan: *const fn (?*anyopaque, []const u8) void = noopText,
    /// Permission request: returns the chosen `optionId` or null to cancel.
    /// It is called from the worker thread, so it may block (zode's permission
    /// dialog already blocks the worker by design).
    onPermission: ?*const fn (?*anyopaque, tool: []const u8, detail: []const u8, options: []const PermOption) ?[]const u8 = null,
};

fn noopText(_: ?*anyopaque, _: []const u8) void {}
fn noopTool(_: ?*anyopaque, _: []const u8, _: []const u8, _: []const u8) void {}
fn noopToolUpdate(_: ?*anyopaque, _: []const u8, _: []const u8, _: []const u8) void {}

/// A tool remembered by its id: ACP sends the id in the updates, not the name,
/// and without this the `pushToolDone` would go out not knowing which tool
/// closed.
const ToolMemo = struct {
    id: [64]u8 = undefined,
    id_len: usize = 0,
    name: [48]u8 = undefined,
    name_len: usize = 0,

    fn eqlId(self: ToolMemo, id: []const u8) bool {
        return self.id_len == id.len and std.mem.eql(u8, self.id[0..self.id_len], id);
    }
};

/// Which response we are waiting for from the child.
const Wait = enum { none, init, new_session, prompt };

pub const Client = struct {
    gpa: std.mem.Allocator,
    io: Io,
    child: std.process.Child,
    stdin: Io.File,

    /// Reader's buffer. The `Reader` keeps a pointer to THIS array, so the
    /// struct cannot be moved (see the note further up).
    out_buf: [64 * 1024]u8 = undefined,
    reader: Io.File.Reader,

    /// Line in progress. It can grow without limit (see the note further up).
    line: std.ArrayList(u8) = .empty,
    /// Buffer to serialize a message before sending it.
    send_buf: [128 * 1024]u8 = undefined,

    next_id: i64 = 1,
    wait_id: i64 = 0,
    waiting: Wait = .none,

    session: [128]u8 = undefined,
    session_len: usize = 0,
    agent_name: [64]u8 = undefined,
    agent_name_len: usize = 0,
    stop_reason: [32]u8 = undefined,
    stop_len: usize = 0,
    /// Last `error.message` the agent sent, so we can show it.
    last_error: [256]u8 = undefined,
    last_error_len: usize = 0,

    /// Writing to stdin needs a lock (Zig's `Mutex` is not reentrant and here it
    /// is taken only once per write).
    wlock: std.atomic.Mutex = .unlocked,

    /// The UI asked to cut the turn short. `cancel()` sets it from the draw
    /// thread; the worker reads and honours it, and it is the only one writing.
    cancel_requested: std.atomic.Value(bool) = .init(false),
    cancel_sent: bool = false,
    would_block_count: usize = 0,

    tools: [64]ToolMemo = undefined,
    tools_len: usize = 0,

    pub fn sessionId(self: *const Client) []const u8 {
        return self.session[0..self.session_len];
    }

    pub fn agentTitle(self: *const Client) []const u8 {
        if (self.agent_name_len == 0) return "acp";
        return self.agent_name[0..self.agent_name_len];
    }

    pub fn stopReason(self: *const Client) []const u8 {
        return self.stop_reason[0..self.stop_len];
    }

    /// The last error the agent sent (empty if there was none).
    pub fn lastError(self: *const Client) []const u8 {
        return self.last_error[0..self.last_error_len];
    }

    pub fn toolName(self: *const Client, id: []const u8) []const u8 {
        // CAREFUL: with `for (self.tools[0..len]) |memo|` the `memo` is a COPY of
        // the struct, and `memo.name[0..n]` points at that stack copy: on leaving
        // the loop the slice dangles and returns garbage. That is why the index.
        for (self.tools[0..self.tools_len], 0..) |*memo, i| {
            if (memo.eqlId(id)) return self.tools[i].name[0..memo.name_len];
        }
        return "";
    }

    // ── startup ───────────────────────────────────────────────

    /// Launches the agent, does `initialize` and opens a session in `cwd`.
    ///
    /// `argv_override` is the result of splitting `ZODE_ACP_CMD`; if it is null
    /// `default_argv` is used. `env` is used to resolve the executable through
    /// the PATH (see `resolveArgv`).
    pub fn start(
        gpa: std.mem.Allocator,
        io: Io,
        argv_override: ?[]const []const u8,
        cwd: []const u8,
        env: ?*const std.process.Environ.Map,
    ) !*Client {
        const argv = argv_override orelse &default_argv;
        const self = try gpa.create(Client);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .child = undefined,
            .stdin = undefined,
            .reader = undefined,
        };
        errdefer self.line.deinit(gpa);

        // The `Io` resolves the PATH with ITS environment, which is not always
        // zode's (a test `Threaded`, for example, has none). With an argv[0]
        // without a '/', `spawn` gives FileNotFound even though the binary is
        // right there. We resolve it here against the map the caller gives us.
        // The two buffers are `start`'s stack buffers ON PURPOSE: `resolveArgv`
        // returns slices pointing at them, and `spawn` consumes them before
        // `start` returns.
        var resolved_argv: [8][]const u8 = undefined;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const argv_final = resolveArgv(io, env, argv, &resolved_argv, &path_buf);

        self.child = std.process.spawn(io, .{
            .argv = argv_final,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch return error.SpawnFailed;
        // If something fails later, the child must not be left orphaned.
        errdefer self.child.kill(io);

        self.stdin = self.child.stdin.?;
        // The read pipe goes into NON-BLOCKING on purpose: the `pump` loop
        // sleeps between messages instead of blocking, and thus it can look at
        // the cancel flag and send `session/cancel` even while the agent is
        // silent. A blocking read would leave the worker waiting until the
        // agent spoke, which is exactly when being able to cut short matters.
        //
        // CAREFUL: setting `flags.nonblocking = true` on the `File` does NOT
        // put the descriptor in O_NONBLOCK. That field is only consulted on the
        // Windows path; on POSIX `read()` goes out as-is, and with a blocking
        // fd it blocks forever (which is what was happening: the turn hung on
        // the second read). You have to do the `fcntl` for real.
        var out_file = self.child.stdout.?;
        out_file.flags.nonblocking = true;
        if (builtin.os.tag == .linux) {
            // `fcntl` returns the raw result: errors come back encoded as huge
            // values, so "it worked" means "it fits in 32 bits". (The other way
            // round than a return error: a good GETFL is a SMALL number, 0x44000
            // or so.)
            const fl = std.os.linux.fcntl(out_file.handle, std.posix.F.GETFL, 0);
            if (fl <= std.math.maxInt(u32)) {
                const want = fl | (1 << @bitOffsetOf(std.os.linux.O, "NONBLOCK"));
                _ = std.os.linux.fcntl(out_file.handle, std.posix.F.SETFL, want);
            }
        }
        self.reader = out_file.readerStreaming(io, &self.out_buf);

        try self.sendInitialize();
        try self.awaitHandshake(.init);
        try self.sendNewSession(cwd);
        try self.awaitHandshake(.new_session);
        if (self.session_len == 0) return error.HandshakeFailed;
        return self;
    }

    pub fn deinit(self: *Client) void {
        self.child.kill(self.io);
        self.line.deinit(self.gpa);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    // ── sending ───────────────────────────────────────────────

    fn write(self: *Client, bytes: []const u8) !void {
        // `std.atomic.Mutex` is a SPINLOCK (it has no `lock`), and it cannot be
        // reentered. Here it is only taken for a short write, so waiting with
        // `yield` is enough.
        while (!self.wlock.tryLock()) std.Thread.yield() catch {};
        defer self.wlock.unlock();
        try self.stdin.writeStreamingAll(self.io, bytes);
    }

    fn takeId(self: *Client) i64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn sendInitialize(self: *Client) !void {
        self.wait_id = self.takeId();
        self.waiting = .init;
        var w = Io.Writer.fixed(&self.send_buf);
        try w.print(
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"initialize\",\"params\":{{" ++
                "\"protocolVersion\":{d},\"clientCapabilities\":{{}}," ++
                "\"clientInfo\":{{\"name\":\"{s}\",\"version\":\"{s}\"}}}}}}\n",
            .{ self.wait_id, protocol_version, client_name, client_version },
        );
        try self.write(w.buffered());
    }

    fn sendNewSession(self: *Client, cwd: []const u8) !void {
        self.wait_id = self.takeId();
        self.waiting = .new_session;
        var w = Io.Writer.fixed(&self.send_buf);
        try w.print(
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"session/new\",\"params\":{{\"cwd\":",
            .{self.wait_id},
        );
        try config.writeJsonString(&w, undefined, cwd);
        try w.writeAll(",\"mcpServers\":[]}}\n");
        try self.write(w.buffered());
    }

    /// Asks to cut the turn short. Can be called from ANY thread (the UI does it
    /// with ESC) and does NOT touch the `Io`: it only sets a flag.
    ///
    /// CAREFUL: the `session/cancel` is NOT written here directly. Writing to
    /// the pipe from another thread while the worker is blocked reading with the
    /// SAME `Io` breaks it: the child dies and the turn ends with AgentDied
    /// without ever having cancelled anything. Zig's `Io` is not meant to be
    /// used by two threads at once. The worker writes it, since it is the
    /// owner, upon seeing the flag (see `pump`).
    pub fn cancel(self: *Client) void {
        self.cancel_requested.store(true, .seq_cst);
    }

    fn sendCancel(self: *Client) void {
        if (self.session_len == 0) return;
        var buf: [256]u8 = undefined;
        var w = Io.Writer.fixed(&buf);
        w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"session/cancel\",\"params\":{\"sessionId\":") catch return;
        config.writeJsonString(&w, undefined, self.sessionId()) catch return;
        w.writeAll("}}\n") catch return;
        self.cancel_sent = true;
        self.write(w.buffered()) catch {};
    }

    // ── prompt ────────────────────────────────────────────────

    /// Sends a text prompt to the agent. The events come out through the `sink`
    /// of `waitTurn`.
    pub fn prompt(self: *Client, text: []const u8) !void {
        if (self.session_len == 0) return error.NoSession;
        self.wait_id = self.takeId();
        self.waiting = .prompt;
        self.stop_len = 0;

        var w = Io.Writer.fixed(&self.send_buf);
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"session/prompt\",\"params\":{{\"sessionId\":", .{self.wait_id});
        try config.writeJsonString(&w, undefined, self.sessionId());
        try w.writeAll(",\"prompt\":[{\"type\":\"text\",\"text\":");
        try config.writeJsonString(&w, undefined, text);
        try w.writeAll("}]}}\n");
        try self.write(w.buffered());
    }

    /// Reads and dispatches until the turn ends. Returns the `stopReason`.
    ///
    /// The child's output pipe is in NON-BLOCKING, so the loop sleeps a moment
    /// between reads. That is what lets the UI cancel the turn without writing
    /// to the `Io` from another thread (see `cancel`).
    pub fn waitTurn(self: *Client, sink: *const Sink) ![]const u8 {
        while (self.waiting == .prompt) {
            if (self.cancel_requested.load(.seq_cst) and !self.cancel_sent) self.sendCancel();
            const got = try self.pump(sink);
            if (got == .line) continue;
            if (got == .would_block) {
                // 10 ms: every chunk the agent writes can sit in the pipe for
                // up to one poll, so this number IS the streaming latency
                // floor. 30 ms was chosen "because it is imperceptible", but
                // it stacks with the agent's own buffering and made the stream
                // feel sluggish; 10 ms costs three wakeups per frame and the
                // spinner ticks at 40 ms, so nobody notices the CPU.
                //
                // CAREFUL: `nap` (nanosleep), not `io.sleep`. This process has
                // a SINGLE `Io` shared between the worker and the UI thread,
                // and `Io.sleep` takes the `Io`'s event loop with it: the
                // sleeping worker stopped firing the spinner's `tick` and the
                // TUI froze with the clock stuck (exactly what you see on
                // screen). With `nanosleep` it is a bare syscall that does not
                // touch the `Io`.
                nap(10);
                continue;
            }
            return error.AgentDied; // the child closed
        }
        return self.stopReason();
    }

    // ── reading ───────────────────────────────────────────────

    /// What happened when reading a message from the child.
    pub const Pump = enum { line, would_block, eof };

    /// Reads messages until the response we are waiting for arrives.
    /// `sink` can be null during the handshake (there is nothing to show yet).
    pub fn pump(self: *Client, sink: ?*const Sink) !Pump {
        const got = switch (try self.readLine()) {
            .would_block => return .would_block,
            .eof => return .eof,
            .line => |l| l,
        };
        // `defer`, and not a `clear` at the end: there are SEVERAL intermediate
        // `return .line` (empty line, invalid JSON, notification), and with the
        // clear only at the end `self.line` kept the previous text. The next
        // line came out GLUED to the previous one, the parse failed, and the
        // loop ate its own queue: a total hang after the very first message.
        //
        // CAREFUL: the `defer` runs when EXITING pump, after the callbacks,
        // which is exactly when the text stops being needed.
        defer self.line.clearRetainingCapacity();
        var line = got;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0) return .line;

        var astate = std.heap.ArenaAllocator.init(self.gpa);
        defer astate.deinit();
        const arena = astate.allocator();

        const val = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch return .line;
        if (val != .object) return .line;
        const root = val.object;

        const id = intOf(root.get("id"));

        if (root.get("method")) |mv| {
            const method = strOf(mv);
            // A request from the agent towards us (permissions, fs, terminal).
            if (id) |req_id| {
                try self.handleRequest(req_id, method, root, sink);
            } else {
                try self.handleNotification(method, root, sink);
            }
            return .line;
        }

        // A response to something of ours.
        //
        // CAREFUL: `root.get("method") orelse return true` does NOT work here.
        // Responses carry NO `method`, so that `orelse` swallowed the whole
        // `initialize` and the handshake stayed forever waiting for a response
        // that had already arrived (and without painting anything, which is
        // what makes a deadlock like that so hard to spot).
        if (id) |resp_id| {
            if (resp_id != self.wait_id) return .line;
            if (root.get("error")) |e| {
                // The server's message is the only useful thing: "HTTP 500" says
                // nothing, "model not found" does.
                var buf: [512]u8 = undefined;
                const msg = blk: {
                    const m = strField(e.object, "message");
                    if (m.len == 0) break :blk "";
                    break :blk std.fmt.bufPrint(&buf, "{s}", .{m}) catch "";
                };
                self.last_error_len = 0;
                if (msg.len > 0) {
                    const n = @min(msg.len, self.last_error.len);
                    @memcpy(self.last_error[0..n], msg[0..n]);
                    self.last_error_len = n;
                }
                self.waiting = .none;
                return error.AgentDied;
            }
            if (root.get("result")) |res| {
                self.takeResult(resp_id, res);
            } else {
                self.waiting = .none;
            }
        }
        return .line;
    }

    /// Waits for the handshake response. The pipe is NON-blocking, so between
    /// messages we have to sleep a little. With a cap: if the agent does not
    /// answer in ~2 min, a clear error is better than a hang.
    fn awaitHandshake(self: *Client, kind: Wait) !void {
        var spins: usize = 0;
        while (self.waiting == kind) {
            spins += 1;
            if (spins > 4000) return error.HandshakeFailed;
            switch (try self.pump(null)) {
                .line => {},
                .would_block => nap(30),
                .eof => return error.HandshakeFailed,
            }
        }
    }

    fn takeResult(self: *Client, id: i64, res: std.json.Value) void {
        if (id != self.wait_id) return;
        if (res != .object) {
            self.waiting = .none;
            return;
        }
        switch (self.waiting) {
            .init => {
                // The `initialize` is the only response with `agentInfo`: it tells
                // us the agent's name, which is what is shown in the status bar.
                if (res.object.get("agentInfo")) |ai| {
                    if (ai == .object) {
                        const nm = strField(ai.object, "name");
                        const n = @min(nm.len, self.agent_name.len);
                        @memcpy(self.agent_name[0..n], nm[0..n]);
                        self.agent_name_len = n;
                    }
                }
            },
            .new_session => {
                const s = strField(res.object, "sessionId");
                if (s.len > 0) {
                    const n = @min(s.len, self.session.len);
                    @memcpy(self.session[0..n], s[0..n]);
                    self.session_len = n;
                }
            },
            .prompt => {
                const r = strField(res.object, "stopReason");
                const n = @min(r.len, self.stop_reason.len);
                @memcpy(self.stop_reason[0..n], r[0..n]);
                self.stop_len = n;
            },
            else => {},
        }
        self.waiting = .none;
    }

    fn handleNotification(self: *Client, method: []const u8, root: std.json.ObjectMap, sink: ?*const Sink) !void {
        if (!std.mem.eql(u8, method, "session/update")) return;
        const s = sink orelse return;
        const params = root.get("params") orelse return;
        const upd = params.object.get("update") orelse return;
        const kind = strOf(upd.object.get("sessionUpdate") orelse return);

        if (std.mem.eql(u8, kind, "agent_message_chunk")) {
            if (textOf(upd.object.get("content") orelse return)) |t| s.onText(s.userdata, t);
        } else if (std.mem.eql(u8, kind, "agent_thought_chunk")) {
            if (textOf(upd.object.get("content") orelse return)) |t| s.onThought(s.userdata, t);
        } else if (std.mem.eql(u8, kind, "tool_call")) {
            const id = strOf(upd.object.get("toolCallId") orelse return);
            const name = strField(upd.object, "name");
            const title = strField(upd.object, "title");
            self.rememberTool(id, name);
            s.onTool(s.userdata, id, name, title);
        } else if (std.mem.eql(u8, kind, "tool_call_update")) {
            const id = strOf(upd.object.get("toolCallId") orelse return);
            const status = strField(upd.object, "status");
            var buf: [4096]u8 = undefined;
            s.onToolUpdate(s.userdata, id, status, updateText(upd.object, &buf));
        } else if (std.mem.eql(u8, kind, "plan")) {
            const entries = upd.object.get("entries") orelse return;
            if (entries != .array) return;
            for (entries.array.items) |e| {
                const c = strField(e.object, "content");
                if (c.len > 0) {
                    if (c.len > 0) s.onPlan(s.userdata, c);
                }
            }
        }
    }

    fn handleRequest(self: *Client, id: i64, method: []const u8, root: std.json.ObjectMap, sink: ?*const Sink) !void {
        if (std.mem.eql(u8, method, "session/request_permission")) {
            try self.handlePermission(id, root, sink);
            return;
        }
        // `fs/*`, `terminal/*`, `elicitation/*`…: we do not announce them, but
        // if they arrive we have to answer something or the turn never ends.
        var w = Io.Writer.fixed(&self.send_buf);
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":{d},\"message\":", .{
            id,
            code_method_not_found,
        });
        try config.writeJsonString(&w, undefined, method);
        try w.writeAll("}}}\n");
        try self.write(w.buffered());
    }

    fn handlePermission(self: *Client, id: i64, root: std.json.ObjectMap, sink: ?*const Sink) !void {
        const params = root.get("params") orelse return self.respondCancelled(id);
        const pobj = params.object;
        const tc = pobj.get("toolCall");
        const tool: []const u8 = if (tc) |v| strField(v.object, "title") else "";
        const detail: []const u8 = if (tc) |v| rawInputText(v.object.get("rawInput") orelse return self.respondCancelled(id)) else "";

        var opts: [8]PermOption = undefined;
        var n: usize = 0;
        if (pobj.get("options")) |o| {
            if (o == .array) {
                for (o.array.items) |item| {
                    if (n >= opts.len) break;
                    opts[n] = .{
                        .id = strField(item.object, "optionId"),
                        .name = strField(item.object, "name"),
                        .kind = strField(item.object, "kind"),
                    };
                    n += 1;
                }
            }
        }
        const list = opts[0..n];

        const cb = if (sink) |s| s.onPermission else null;
        if (cb) |f| {
            if (f(sink.?.userdata, tool, detail, list)) |choice| {
                return self.respondSelected(id, choice);
            }
            return self.respondCancelled(id);
        }
        // Nobody to ask (tests, or a turn with no UI): the first "allow" option
        // is the reasonable thing, and if there is none, cancel.
        for (list) |o| {
            if (std.mem.startsWith(u8, o.kind, "allow")) return self.respondSelected(id, o.id);
        }
        return self.respondCancelled(id);
    }

    fn respondSelected(self: *Client, id: i64, option_id: []const u8) !void {
        var w = Io.Writer.fixed(&self.send_buf);
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"outcome\":{{\"outcome\":\"selected\",\"optionId\":", .{id});
        try config.writeJsonString(&w, undefined, option_id);
        try w.writeAll("}}}}}\n");
        try self.write(w.buffered());
    }

    fn respondCancelled(self: *Client, id: i64) !void {
        var w = Io.Writer.fixed(&self.send_buf);
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"outcome\":{{\"outcome\":\"cancelled\"}}}}}}\n", .{id});
        try self.write(w.buffered());
    }

    fn rememberTool(self: *Client, id: []const u8, name: []const u8) void {
        for (self.tools[0..self.tools_len]) |memo| {
            if (memo.eqlId(id)) return; // we already know it
        }
        if (self.tools_len >= self.tools.len) return;
        var memo = &self.tools[self.tools_len];
        const ni = @min(id.len, memo.id.len);
        @memcpy(memo.id[0..ni], id[0..ni]);
        memo.id_len = ni;
        const nn = @min(name.len, memo.name.len);
        @memcpy(memo.name[0..nn], name[0..nn]);
        memo.name_len = nn;
        self.tools_len += 1;
    }

    /// Result of trying to read a line from the child.
    pub const Line = union(enum) {
        /// Complete line, in `self.line.items` (valid until the next pump).
        line: []const u8,
        /// No data RIGHT NOW. This is the normal case between heartbeats.
        would_block,
        /// The child closed the pipe.
        eof,
    };

    /// A line from the child, accumulated by hand.
    ///
    /// The Reader's `readLine` does not do: it gives `error.StreamTooLong` if
    /// the line does not fit in its buffer, and here the lines are tool updates
    /// that can carry a whole dump. The buffer is read by hand and grown.
    ///
    /// The pipe is in NON-BLOCKING (see `start`): if there is no data we return
    /// `would_block` so the caller can sleep and look at the cancel flag. A
    /// blocking read would leave the worker stuck and ESC could not do anything
    /// until the agent spoke again.
    ///
    /// CAREFUL: `self.line` is NOT cleared on entry. A partial line stays
    /// accumulated across calls, and the one that clears it (once reading it
    /// finishes) is `pump`. If it were cleared here, a `would_block` in the
    /// middle of a line would lose what was read and the line would never be
    /// closed.
    fn readLine(self: *Client) !Line {
        while (true) {
            const r = &self.reader.interface;
            const rest = r.buffer[r.seek..r.end];
            if (std.mem.indexOfScalar(u8, rest, '\n')) |i| {
                try self.line.appendSlice(self.gpa, rest[0..i]);
                r.toss(i + 1);
                return .{ .line = self.line.items };
            }
            try self.line.appendSlice(self.gpa, rest);
            r.toss(rest.len);
            const before = r.end;
            r.fillMore() catch |err| switch (err) {
                // The file `Reader` SWALLOWS the `WouldBlock` and turns it into
                // `ReadFailed`, leaving the real error in `self.reader.err` (the
                // inner `Io.Reader`'s `err` is a different thing). That is why we
                // do not look at the error it returns, but at the one it stored.
                error.ReadFailed => {
                    if (self.reader.err != null and self.reader.err.? == error.WouldBlock) {
                        return .would_block;
                    }
                    return err;
                },
                else => return err,
            };
            if (r.end == before) {
                // EOF: whatever is left without a newline is returned as is.
                if (self.line.items.len == 0) return .eof;
                return .{ .line = self.line.items };
            }
        }
    }
};

// ── JSON helpers ─────────────────────────────────────────────

/// Text field of an object, or "" if it is absent / not a string.
///
/// CAREFUL: `obj.get(k) orelse ""` does NOT compile, because `orelse` returns a
/// `json.Value` and "" is a `[]const u8`. Hence this helper.
fn strField(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    const v = obj.get(key) orelse return "";
    return strOf(v);
}

fn strOf(v: std.json.Value) []const u8 {
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

fn intOf(v: ?std.json.Value) ?i64 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

/// Text of a `ContentBlock`, or null if it is not text.
fn textOf(v: std.json.Value) ?[]const u8 {
    if (v != .object) return null;
    if (!std.mem.eql(u8, strOf(v.object.get("type") orelse return null), "text")) return null;
    return strOf(v.object.get("text") orelse return null);
}

/// `rawInput` is `unknown`: if it is an object with `command`/`file_path` pull
/// that out, if it is a string use it as is, and otherwise nothing.
fn rawInputText(v: std.json.Value) []const u8 {
    switch (v) {
        .string => |s| return s,
        .object => |o| {
            for ([_][]const u8{ "command", "file_path", "path", "pattern" }) |k| {
                const found = strField(o, k);
                if (found.len > 0) return found;
            }
            return "";
        },
        else => return "",
    }
}

/// The text of a tool update: first the normal `content` and, if there is
/// none, the `rawOutput`.
fn updateText(upd: std.json.ObjectMap, buf: []u8) []const u8 {
    if (upd.get("content")) |c| {
        if (c == .array) {
            var w = Io.Writer.fixed(buf);
            for (c.array.items) |item| {
                const inner = if (item == .object and
                    std.mem.eql(u8, strField(item.object, "type"), "content"))
                    item.object.get("content")
                else
                    item;
                const t = if (inner) |v| textOf(v) else null;
                if (t) |txt| {
                    if (w.buffered().len > 0) w.writeAll("\n") catch break;
                    w.writeAll(txt) catch break;
                }
            }
            if (w.buffered().len > 0) return w.buffered();
        }
    }
    if (upd.get("rawOutput")) |ro| {
        if (textOf(ro)) |t| return t;
    }
    return "";
}

// ── tests ────────────────────────────────────────────────────

const testing = std.testing;

/// Feeds a line through the SAME path as the real client, with no child
/// process: that is what makes it possible to test the parsing with captured
/// updates.
fn feedLine(c: *Client, sink: *const Sink, line: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const val = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
    try c.handleNotification(strOf(val.object.get("method") orelse return), val.object, sink);
}

fn testClient() Client {
    return .{ .gpa = testing.allocator, .io = undefined, .child = undefined, .stdin = undefined, .reader = undefined };
}

test "los chunks de texto llegan al sink en orden" {
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    const Ctx = struct {
        fn onText(ud: ?*anyopaque, text: []const u8) void {
            const l: *std.ArrayList(u8) = @ptrCast(@alignCast(ud.?));
            l.appendSlice(testing.allocator, text) catch {};
        }
    };
    var c = testClient();
    defer c.line.deinit(testing.allocator);
    const sink = Sink{ .userdata = &got, .onText = Ctx.onText };
    try feedLine(&c, &sink,
        \\{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hola "}}}}
    );
    try feedLine(&c, &sink,
        \\{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"mundo"}}}}
    );
    try testing.expectEqualStrings("hola mundo", got.items);
}

test "el razonamiento va a su propio callback" {
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    const Ctx = struct {
        fn onThought(ud: ?*anyopaque, text: []const u8) void {
            const l: *std.ArrayList(u8) = @ptrCast(@alignCast(ud.?));
            l.appendSlice(testing.allocator, text) catch {};
        }
    };
    var c = testClient();
    defer c.line.deinit(testing.allocator);
    const sink = Sink{ .userdata = &got, .onThought = Ctx.onThought };
    try feedLine(&c, &sink,
        \\{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"voy a leer el fichero"}}}}
    );
    try testing.expectEqualStrings("voy a leer el fichero", got.items);
}

test "una tool nueva se recuerda por id para poder cerrar su linea" {
    const Ctx = struct {
        fn onTool(ud: ?*anyopaque, id: []const u8, name: []const u8, title: []const u8) void {
            const s: *[]const u8 = @ptrCast(@alignCast(ud.?));
            s.* = std.fmt.allocPrint(testing.allocator, "{s}|{s}|{s}", .{ id, name, title }) catch "";
        }
    };
    var seen: []const u8 = "";
    defer testing.allocator.free(seen);
    const seenp: *[]const u8 = &seen;
    var c = testClient();
    defer c.line.deinit(testing.allocator);
    const sink = Sink{ .userdata = @ptrCast(seenp), .onTool = Ctx.onTool };
    try feedLine(&c, &sink,
        \\{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"tool_call","toolCallId":"c1","name":"bash","title":"sleep 30","kind":"execute","status":"pending"}}}
    );
    try testing.expectEqualStrings("c1|bash|sleep 30", seen);
    // The id is the only thing that comes in the update: without the memo, the
    // `pushToolDone` would not know which tool closed.
    try testing.expectEqualStrings("bash", c.toolName("c1"));
}

test "el resumen de un tool_call_update sale de content" {
    const Ctx = struct {
        fn onUpd(ud: ?*anyopaque, id: []const u8, status: []const u8, text: []const u8) void {
            const s: *[]const u8 = @ptrCast(@alignCast(ud.?));
            s.* = std.fmt.allocPrint(testing.allocator, "{s}:{s}:{s}", .{ id, status, text }) catch "";
        }
    };
    var seen: []const u8 = "";
    defer testing.allocator.free(seen);
    const seenp: *[]const u8 = &seen;
    var c = testClient();
    defer c.line.deinit(testing.allocator);
    const sink = Sink{ .userdata = @ptrCast(seenp), .onToolUpdate = Ctx.onUpd };
    try feedLine(&c, &sink,
        \\{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"completed","content":[{"type":"content","content":{"type":"text","text":"exit=0"}}]}}}
    );
    try testing.expectEqualStrings("c1:completed:exit=0", seen);
}

test "las entradas del plan salen una a una" {
    const Ctx = struct {
        fn onPlan(ud: ?*anyopaque, text: []const u8) void {
            const l: *std.ArrayList(u8) = @ptrCast(@alignCast(ud.?));
            l.appendSlice(testing.allocator, text) catch {};
            l.appendSlice(testing.allocator, "\n") catch {};
        }
    };
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    var c = testClient();
    defer c.line.deinit(testing.allocator);
    const sink = Sink{ .userdata = &got, .onPlan = Ctx.onPlan };
    try feedLine(&c, &sink,
        \\{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"plan","entries":[{"content":"mirar el test","status":"pending"},{"content":"arreglarlo","status":"pending"}]}}}
    );
    try testing.expectEqualStrings("mirar el test\narreglarlo\n", got.items);
}

/// A fake ACP agent for the tests: a `sh` that reads one request per line and
/// answers with JSON-RPC. It is more faithful than a mock because it exercises
/// the pipes, the reader's buffer and the real line framing.
const fake_agent_script =
    \\while IFS= read -r line; do
    \\  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
    \\  case "$line" in
    \\    *'"initialize"'*)
    \\      printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"agentInfo":{"name":"fake-agent"}}}\n' "$id" ;;
    \\    *'"session/new"'*)
    \\      printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"sess_fake"}}\n' "$id" ;;
    \\    *'"session/prompt"'*)
    \\      printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_fake","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hola "}}}}\n'
    \\      printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_fake","update":{"sessionUpdate":"tool_call","toolCallId":"t1","name":"bash","title":"echo","kind":"execute","status":"in_progress"}}}\n'
    \\      printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_fake","update":{"sessionUpdate":"tool_call_update","toolCallId":"t1","status":"completed","content":[{"type":"content","content":{"type":"text","text":"exit=0"}}]}}}\n'
    \\      big=$(head -c 100000 /dev/zero | tr '\0' 'x')
    \\      printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_fake","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"%s"}}}}\n' "$big"
    \\      printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"end_turn"}}\n' "$id" ;;
    \\    *)
    \\      printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"nope"}}\n' "$id" ;;
    \\  esac
    \\done
;

const fake_agent_argv = [_][]const u8{ "/bin/sh", "-c", fake_agent_script };

/// An agent that heartbeats for a while and HONOURS `session/cancel`.
///
/// The heartbeat is kept SHORT on purpose: a `sh` cannot read from its stdin
/// while it sleeps, so if it waited long it would not see the cancel until it
/// was no longer needed. With 8 ticks it goes back to the read loop and sees it.
const fake_cancel_script =
    \\while IFS= read -r line; do
    \\  case "$line" in
    \\    *'"initialize"'*) printf '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentInfo":{"name":"fake-cancel"}}}\n' ;;
    \\    *'"session/new"'*) printf '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"sess_c"}}\n' ;;
    \\    *'"session/prompt"'*)
    \\      printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_c","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"trabajando"}}}}\n'
    \\      i=0
    \\      while [ $i -lt 8 ]; do
    \\        printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_c","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"."}}}}\n'
    \\        sleep 0.1
    \\        i=$((i+1))
    \\      done ;;
    \\    *EOF*) printf '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}\n' ;;
    \\    *'"session/cancel"'*) printf '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"cancelled"}}\n' ;;
    \\  esac
    \\done
;
const fake_cancel_argv = [_][]const u8{ "/bin/sh", "-c", fake_cancel_script };

test "cancel() corta el turno: el agente recibe session/cancel y responde cancelled" {
    // What ESC really does in the TUI, but without the UI: `cancel()` only
    // sets a flag, and it is the worker (owner of the `Io`) that writes. If
    // `cancel()` wrote from this thread, the `Io` would be used by two threads
    // at once and the turn would die with AgentDied without ever cancelling
    // anything.
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const c = try Client.start(testing.allocator, io, &fake_cancel_argv, "/tmp", null);
    defer c.deinit();

    try c.prompt("haz algo lentisimo");
    c.cancel();

    const sink = Sink{};
    const reason = try c.waitTurn(&sink);
    try testing.expectEqualStrings("cancelled", reason);
}

test "el turno entero pasa por un agente de mentira: handshake, updates y stop" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const c = try Client.start(testing.allocator, io, &fake_agent_argv, "/tmp", null);
    defer c.deinit();
    // The `initialize` keeps the name the agent said.
    try testing.expectEqualStrings("fake-agent", c.agentTitle());
    try testing.expectEqualStrings("sess_fake", c.sessionId());

    const Ctx = struct {
        text: std.ArrayList(u8) = .empty,
        tool: []const u8 = "",
        done: []const u8 = "",
        fn onText(ud: ?*anyopaque, s: []const u8) void {
            const p: *@This() = @ptrCast(@alignCast(ud.?));
            p.text.appendSlice(testing.allocator, s) catch {};
        }
        fn onTool(ud: ?*anyopaque, id: []const u8, name: []const u8, title: []const u8) void {
            const p: *@This() = @ptrCast(@alignCast(ud.?));
            p.tool = std.fmt.allocPrint(testing.allocator, "{s}|{s}|{s}", .{ id, name, title }) catch "";
        }
        fn onUpd(ud: ?*anyopaque, id: []const u8, status: []const u8, text: []const u8) void {
            const p: *@This() = @ptrCast(@alignCast(ud.?));
            p.done = std.fmt.allocPrint(testing.allocator, "{s}|{s}|{s}", .{ id, status, text }) catch "";
        }
    };
    var ctx = Ctx{};
    defer {
        ctx.text.deinit(testing.allocator);
        if (ctx.tool.len > 0) testing.allocator.free(ctx.tool);
        if (ctx.done.len > 0) testing.allocator.free(ctx.done);
    }
    const sink = Sink{ .userdata = &ctx, .onText = Ctx.onText, .onTool = Ctx.onTool, .onToolUpdate = Ctx.onUpd };

    try c.prompt("hola");
    try testing.expectEqualStrings("end_turn", try c.waitTurn(&sink));

    try testing.expect(std.mem.startsWith(u8, ctx.text.items, "hola "));
    // The 100 KB chunk has to arrive WHOLE: std's `readLine` would give
    // StreamTooLong with a line bigger than its 64 KB buffer.
    try testing.expect(ctx.text.items.len > 100_000);
    try testing.expectEqualStrings("t1|bash|echo", ctx.tool);
    try testing.expectEqualStrings("t1|completed|exit=0", ctx.done);
    try testing.expectEqualStrings("bash", c.toolName("t1"));
}
