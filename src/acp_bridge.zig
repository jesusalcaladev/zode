const std = @import("std");
const tui = @import("tui.zig");
const agent = @import("agent.zig");
const acp = @import("acp.zig");
const palette = @import("palette.zig");

/// The turn, delegated to another agent over ACP.
///
/// It is its own file because it is a MODE, not a feature: with `/acp` on, zode
/// does not run the agent loop at all — it spawns `opencode acp` and speaks
/// JSON-RPC over its pipes. Everything here is the plumbing for that: the child
/// process, the handshake, the permission dialog mapped onto the one that already
/// exists, and the cancellation that has to go through the protocol.
///
/// It talks to `agent.zig` (for the agent.session, the status line and the text sinks)
/// and `agent.zig` calls in here (to start, cancel and shut the mode down). The
/// edge goes one way: the alternative is a cycle, and the way out of that is
/// deciding that the HTTP turn belongs to agent.zig and this one does not.

// ── ACP: the turn is delegated to another agent ───────────────

/// ACP mode: zode does NOT do the turn, it hands it to an ACP agent (by default
/// `opencode acp`) speaking JSON-RPC over the pipes of its child process.
///
/// It is the "trick behind the scenes": opencode's terminal is not poked, its
/// engine is talked to. The agent.session history is opencode's, not zode's.
pub var acp_on: bool = false;
/// ACP agent command. `ZODE_ACP_CMD` sets it (words separated by spaces) and
/// `/acp <cmd>` changes it for the agent.session.
pub var acp_cmd: ?[]const u8 = null;

/// Live client, or null. Started lazily and REUSED across turns: the ACP
/// agent.session (and its context) live in the process, so one per turn would be
/// amnesia memory.
var acp_client: ?*acp.Client = null;

/// Called by the TUI on exit. Without this the child stays hung alive.
pub fn shutdownAcp() void {
    if (acp_client) |c| {
        c.deinit();
        acp_client = null;
    }
}

/// ESC: if the turn goes through ACP it has to be cut through its protocol
/// (`agent.session/cancel`), not just by setting the flag of the HTTP streams.
pub fn cancelAcp(m: *tui.Model) void {
    if (!acp_on) return;
    if (acp_client) |c| c.cancel();
    // Say "cancelling" instead of leaving the status as it was: the turn does
    // not stop on the spot (the agent has to confirm with a stopReason), and
    // without this text ESC looks like it did nothing.
    agent.setStatusWithZo(m, .warn, "cancelling…");
}

/// Name of the active ACP agent, for the status bar.
pub fn acpTitle() []const u8 {
    if (acp_client) |c| return c.agentTitle();
    return "pending";
}

/// State of the connection to the ACP agent.
///
/// Startup is NOT done at the prompt: `opencode acp` brings up a private server
/// and that takes several seconds. It is launched as soon as `/acp` is
/// enabled, so the first prompt only waits for it to be ready.
const AcpState = enum { off, connecting, ready, failed };

var acp_state: AcpState = .off;
/// Error code of the failed startup, so it can be shown.
var acp_start_err: anyerror = error.SpawnFailed;
/// Guards writes to `acp_client` from the connection thread.
///
/// It is a SPINLOCK (`tryLock`, not `lock`): it is taken for a moment and
/// released, and the sections are two lines long. A reentrant `lock` would
/// hang the app, which is exactly the `pushPending` trap at the other end of the
/// code.
var acp_lock: std.atomic.Mutex = .unlocked;

fn acpLock() void {
    while (!acp_lock.tryLock()) std.Thread.yield() catch {};
}
fn acpUnlock() void {
    acp_lock.unlock();
}

/// The agent's argv, from `acp_cmd` or the default one.
///
/// It is returned in `out` because the slice has to live in the caller: the
/// argv are pointers to words of the command, not its length.
fn acpArgv(out: *[8][]const u8) []const []const u8 {
    var argv: []const []const u8 = &acp.default_argv;
    const cmd = acp_cmd orelse return argv;
    var it = std.mem.tokenizeAny(u8, cmd, " ");
    var n: usize = 0;
    while (it.next()) |word| {
        if (n >= out.len) break;
        out[n] = word;
        n += 1;
    }
    if (n > 0) argv = out[0..n];
    return argv;
}

/// The absolute cwd for `agent.session/new`.
///
/// ACP requires it. In 0.16 there is no `getCwd`, so the `/proc/self/cwd`
/// symlink is used, which is the process's real cwd (the environment's `PWD`
/// can be lying). Without `/proc` it falls back to `PWD` and, as a last
/// resort, to "/".
fn acpCwd() []const u8 {
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.cwd().readLink(agent.io_global, "/proc/self/cwd", &link_buf) catch 0;
    if (n > 0 and link_buf[0] == '/') return link_buf[0..n];
    if (agent.environ_global) |env| {
        if (env.get("PWD")) |pwd| {
            if (pwd.len > 0 and pwd[0] == '/') return pwd;
        }
    }
    return "/";
}

const ConnectJob = struct {
    /// The model ONLY to leave a notice in the history. The thread uses it with
    /// `agent.pushInfoOwned`, which is thread-safe. It registers itself as a worker
    /// (`beginWorker`) so `waitWorkers` waits for it at shutdown: otherwise the
    /// thread could touch an already destroyed `Model`.
    m: *tui.Model,
    gpa: std.mem.Allocator,
    argv: [8][]const u8,
    argv_len: usize,
    cwd: [std.fs.max_path_bytes]u8,
    cwd_len: usize,
    env: ?*const std.process.Environ.Map,
};

/// Connection thread. Only writes to the state (under `acp_lock`) and exits.
fn acpConnectThread(job: *ConnectJob) void {
    const gpa = job.gpa;
    const m = job.m;
    m.beginWorker();
    defer m.endWorker();
    defer gpa.destroy(job);

    const cwd = job.cwd[0..job.cwd_len];
    const c = acp.Client.start(gpa, agent.io_global, job.argv[0..job.argv_len], cwd, job.env) catch |err| {
        acpLock();
        acp_state = .failed;
        acp_start_err = err;
        acpUnlock();
        agent.setStatusWithZo(m, .warn, "the ACP agent did not start");
        return;
    };
    acpLock();
    acp_client = c;
    acp_state = .ready;
    acpUnlock();

    // Notice in the history as soon as the agent is ready: the status bar already
    // shows the name, but this leaves a record of the agent.session.
    const msg = std.fmt.allocPrint(
        gpa,
        "ACP connected · agent {s} · agent.session {s}",
        .{ c.agentTitle(), c.sessionId() },
    ) catch return;
    defer gpa.free(msg);
    // `agent.pushInfo` COPIES the text; `agent.pushInfoOwned` TAKES OWNERSHIP of it, and with
    // the `free` above the row came out with garbage (all `�`).
    agent.pushInfo(m, msg);
}

/// Launches the connection in the background. Returns false if one was already
/// in progress or ready.
fn startAcpConnect(
    model: *tui.Model,
    gpa: std.mem.Allocator,
    env: ?*const std.process.Environ.Map,
) bool {
    acpLock();
    defer acpUnlock();
    if (acp_state == .connecting or acp_state == .ready) return false;

    const job = gpa.create(ConnectJob) catch return false;
    errdefer gpa.destroy(job);
    job.* = .{
        .m = model,
        .gpa = gpa,
        .argv = undefined,
        .argv_len = 0,
        .cwd = undefined,
        .cwd_len = 0,
        .env = env,
    };
    var argv_store: [8][]const u8 = undefined;
    const argv = acpArgv(&argv_store);
    @memcpy(job.argv[0..argv.len], argv);
    job.argv_len = argv.len;

    const cwd = acpCwd();
    @memcpy(job.cwd[0..cwd.len], cwd);
    job.cwd_len = cwd.len;

    acp_state = .connecting;
    const th = std.Thread.spawn(.{}, acpConnectThread, .{job}) catch {
        acp_state = .off;
        gpa.destroy(job);
        return false;
    };
    th.detach();
    return true;
}

/// Returns the client, waiting for the connection to finish if needed.
///
/// `m` is only used for the status while waiting; if startup fails the error is
/// translated into something readable (see `reportAcpErr`).
fn ensureAcp(m: *tui.Model) !*acp.Client {
    acpLock();
    const st = acp_state;
    if (st == .ready) {
        const c = acp_client.?;
        acpUnlock();
        return c;
    }
    if (st == .failed) {
        const err = acp_start_err;
        acp_state = .off;
        acpUnlock();
        return err;
    }
    if (st == .off) {
        acpUnlock();
        // Nobody is connecting (cold start, e.g. `--resume`): start it in the
        // worker thread and fall through to the wait loop below.
        //
        // Before, this branch checked the state ONCE right after launching the
        // connect thread: `opencode acp` boots a private server and that takes
        // several seconds, so the state was still `.connecting` and the FIRST
        // prompt died with `SpawnFailed` even though the connection came up a
        // moment later. The user retried and it worked, which reads exactly
        // like "ACP is broken/slow". Waiting here is the same thing `cmdAcp`
        // does in the background, and the wait loop already caps it at ~60 s.
        _ = startAcpConnect(m, m.allocator, m.environ);
        agent.setStatusWithZo(m, .thinking, "connecting to the ACP agent…");
        var cold_spins: usize = 0;
        while (cold_spins < 1200) : (cold_spins += 1) {
            acpLock();
            const s2 = acp_state;
            const c2 = acp_client;
            acpUnlock();
            if (s2 == .ready) {
                if (c2) |cc| return cc;
                continue;
            }
            if (s2 == .failed) {
                acpLock();
                const err = acp_start_err;
                acp_state = .off;
                acpUnlock();
                return err;
            }
            acp.nap(50);
        }
        return error.HandshakeFailed;
    }
    acpUnlock();

    // A connection is in progress: wait WITHOUT touching the shared `Io` (see
    // `acp.nap`), which is what used to freeze the TUI.
    agent.setStatusWithZo(m, .thinking, "connecting to the ACP agent…");
    var spins: usize = 0;
    while (spins < 1200) : (spins += 1) {
        acpLock();
        const s2 = acp_state;
        const c = acp_client;
        acpUnlock();
        if (s2 == .ready) {
            if (c) |cc| return cc;
            continue;
        }
        if (s2 == .failed) {
            acpLock();
            const err = acp_start_err;
            acp_state = .off;
            acpUnlock();
            return err;
        }
        acp.nap(50);
    }
    return error.HandshakeFailed;
}

/// `/acp [on|off|<command>]`
pub fn cmdAcp(m: *tui.Model, arg: []const u8) void {
    const a = std.mem.trim(u8, arg, " \t");
    if (std.mem.eql(u8, a, "off")) {
        acp_on = false;
        shutdownAcp();
        agent.pushInfo(m, "ACP off: the turns go through zode again");
        return;
    }
    if (a.len > 0 and !std.mem.eql(u8, a, "on")) {
        acp_cmd = m.allocator.dupe(u8, a) catch null;
        // Changing agent implies restarting the child: the previous one already has
        // its agent.session and its context.
        shutdownAcp();
    }
    acp_on = true;
    // The connection starts NOW, in the background, not with the first prompt.
    if (startAcpConnect(m, m.allocator, m.environ)) {
        agent.setStatusWithZo(m, .thinking, "connecting to the ACP agent…");
        agent.pushInfo(m, "ACP on: connecting to the agent in the background (/acp off to go back)");
    } else {
        agent.pushInfo(m, "ACP on");
    }
}

/// The worker of an ACP turn.
///
/// CAREFUL: there is NO tool loop here. In ACP the tools are executed by the
/// AGENT, not by zode: the `agent.session/update` with `tool_call` is painted and its
/// `tool_call_update` with `completed` is the result. That is why a turn is one
/// prompt and nothing more.
pub fn acpWorker(job: *agent.ChatJob) void {
    const m = job.model;
    const user_text = job.text;
    defer {
        m.allocator.free(user_text);
        m.allocator.destroy(job);
    }
    m.beginWorker();
    defer m.endWorker();

    var prompt: []const u8 = user_text;
    var owned_prompt: ?[]u8 = null;
    defer if (owned_prompt) |o| m.allocator.free(o);

    while (true) {
        m.streamStart();
        agent.setStatusWithZo(m, .thinking, "thinking");

        const c = ensureAcp(m) catch |err| {
            reportAcpErr(m, err);
            m.streamEnd();
            return;
        };

        var t = AcpTurn{ .m = m, .client = c };
        t.sink = .{
            .userdata = &t,
            .onText = AcpTurn.onText,
            .onThought = AcpTurn.onThought,
            .onTool = AcpTurn.onTool,
            .onToolUpdate = AcpTurn.onToolUpdate,
            .onPlan = AcpTurn.onPlanLine,
            .onPermission = AcpTurn.onPermission,
        };
        defer t.deinit();

        c.prompt(prompt) catch |err| {
            reportAcpErr(m, err);
            m.streamEnd();
            return;
        };
        const reason = c.waitTurn(&t.sink) catch |err| {
            reportAcpErr(m, err);
            m.streamEnd();
            return;
        };

        // What the agent said is stored in zode's agent.session (even though the real
        // history is opencode's): that way `/resume` and the diff still make
        // sense inside zode.
        if (t.text.items.len > 0) {
            agent.ensureSession(m, m.allocator).appendAssistant(t.text.items, null) catch {};
        }
        agent.ensureSession(m, m.allocator).flush();
        // Closes the live paragraph if the turn ended talking (if it ended with
        // a tool, `onTool` already closed it and this does nothing).
        if (t.streaming_open) {
            t.streaming_open = false;
            m.streamEnd();
        }

        if (std.mem.eql(u8, reason, "cancelled")) {
            agent.pushError(m, "ACP turn cancelled");
        }

        // Next queued prompt, if there is one.
        const next = m.takeQueued() orelse break;
        if (owned_prompt) |o| m.allocator.free(o);
        owned_prompt = next;
        prompt = next;
    }
}

/// An agent text in ONE line, trimmed.
///
/// The `agent_thought_chunk`s and the plan entries arrive chopped up and with
/// newlines inside. Painting them as-is fills the history with half rows; and
/// painting each piece separately, with 40 fragments.
///
/// The slice may point to a buffer on this function's stack (the "there is a
/// newline" case): that is safe because the only caller is `agent.pushInfo`, which
/// COPIES the text into the model's allocator before queueing it.
fn oneLine(s: []const u8) []const u8 {
    const clean = std.mem.trim(u8, s, " \t\n\r");
    if (clean.len == 0) return "";
    var it = std.mem.tokenizeAny(u8, clean, "\n\r");
    const first = it.next() orelse return "";
    if (it.next() != null) {
        var buf: [256]u8 = undefined;
        return std.fmt.bufPrint(&buf, "{s} …", .{std.mem.trimEnd(u8, first, " \t")}) catch first;
    }
    return first;
}

/// Context of an ACP turn: translates the `agent.session/update`s to the TUI.
const AcpTurn = struct {
    m: *tui.Model,
    client: *acp.Client,
    text: std.ArrayList(u8) = .empty,
    /// Is there an open streaming paragraph?
    ///
    /// CAREFUL: in ACP the agent INTERLEAVES text and tools (it talks, calls a
    /// tool, talks again). The streaming paragraph has to be closed on every
    /// tool, because otherwise the tool header is painted BEFORE the text that
    /// preceded it and the history ends up out of order. In the HTTP flow it is
    /// not needed because there the stream always ends before the tools.
    streaming_open: bool = false,
    tool_start_ns: [8]i128 = undefined,
    tool_start_len: usize = 0,
    sink: acp.Sink = undefined,

    fn deinit(self: *AcpTurn) void {
        self.text.deinit(self.m.allocator);
    }

    fn onText(ud: ?*anyopaque, s: []const u8) void {
        const t: *AcpTurn = @ptrCast(@alignCast(ud.?));
        t.text.appendSlice(t.m.allocator, s) catch {};
        if (!t.streaming_open) {
            t.m.streamStart();
            t.streaming_open = true;
        }
        t.m.streamDelta(s);
    }

    /// The agent's reasoning does not go into the main paragraph: it is painted as
    /// an info line, which is where you read it without getting in the way of
    /// the answer.
    /// The reasoning arrives chopped up and with newlines inside: it is joined
    /// into ONE line (with "…") because `agent.pushInfo` is one row per call and 40
    /// loose fragments fill the history with junk.
    ///
    /// CAREFUL: `agent.pushInfo` already adds the `·` prefix; adding it here came out
    /// as "· · hola".
    fn onThought(ud: ?*anyopaque, s: []const u8) void {
        const t: *AcpTurn = @ptrCast(@alignCast(ud.?));
        agent.pushInfo(t.m, oneLine(s));
    }

    fn onTool(ud: ?*anyopaque, id: []const u8, name: []const u8, title: []const u8) void {
        const t: *AcpTurn = @ptrCast(@alignCast(ud.?));
        // Closes the text that came before the tool, so the tool header ends up
        // BELOW it and not on top of it.
        if (t.streaming_open) {
            t.m.streamEnd();
            t.streaming_open = false;
        }
        const tool = if (name.len > 0) name else "tool";
        const arg = if (title.len > 0) title else "…";
        t.m.pushToolStart(tool, arg);
        agent.setStatusWithZo(t.m, .tooling, arg);
        if (t.tool_start_len < t.tool_start_ns.len) {
            t.tool_start_ns[t.tool_start_len] = std.Io.Timestamp.now(agent.io_global, .real).nanoseconds;
            t.tool_start_len += 1;
        }
        _ = id;
    }

    fn onToolUpdate(ud: ?*anyopaque, id: []const u8, status: []const u8, text: []const u8) void {
        const t: *AcpTurn = @ptrCast(@alignCast(ud.?));
        // `pending` and `in_progress` do not close the line: the "running" clock stays
        // until the tool actually finishes.
        if (std.mem.eql(u8, status, "pending") or std.mem.eql(u8, status, "in_progress")) return;
        // Closes the live paragraph BEFORE queueing the result. The "live paragraph"
        // block is ALWAYS painted at the end of the history, so if the agent's
        // text were still open, the "⎿ exit=0" came out below its last sentence
        // instead of just below the tool.
        if (t.streaming_open) {
            t.m.streamEnd();
            t.streaming_open = false;
        }
        if (std.mem.eql(u8, status, "cancelled")) {
            t.m.pushToolDone(t.client.toolName(id), "cancelled", 0, "");
            return;
        }
        const ms: u64 = blk: {
            if (t.tool_start_len == 0) break :blk 0;
            const now = std.Io.Timestamp.now(agent.io_global, .real).nanoseconds;
            const started = t.tool_start_ns[t.tool_start_len - 1];
            break :blk @intCast(@max(0, now - started) / std.time.ns_per_ms);
        };
        var summary: [120]u8 = undefined;
        const head = std.mem.trim(u8, text, " \n\t");
        const sum = if (head.len > 0)
            std.fmt.bufPrint(&summary, "{s}", .{std.mem.trimEnd(u8, head, "\n")}) catch "done"
        else
            "done";
        t.m.pushToolDone(t.client.toolName(id), sum, ms, text);
    }

    fn onPlanLine(ud: ?*anyopaque, s: []const u8) void {
        const t: *AcpTurn = @ptrCast(@alignCast(ud.?));
        agent.pushInfo(t.m, oneLine(s));
    }

    fn onPermission(
        ud: ?*anyopaque,
        tool: []const u8,
        detail: []const u8,
        options: []const acp.PermOption,
    ) ?[]const u8 {
        const t: *AcpTurn = @ptrCast(@alignCast(ud.?));
        // The agent brings its own options; the one that matches what the user
        // answered is looked up. Without options there is nothing to draw.
        if (options.len == 0) return null;

        // `/agent.yolo`: the first allow option, without asking.
        if (agent.yolo) {
            for (options) |o| {
                if (std.mem.startsWith(u8, o.kind, "allow")) return o.id;
            }
            return null;
        }

        const prompt = if (tool.len > 0) tool else "the ACP agent wants to run a tool";
        const answer = t.m.requestPermission("acp", detail);
        const want: []const u8 = switch (answer) {
            .allow => "allow_once",
            .allow_always => "allow_always",
            .deny, .none => "reject",
        };
        for (options) |o| {
            if (std.mem.eql(u8, o.kind, want)) return o.id;
        }
        // The agent did not offer exactly what was asked for: any
        // "allow once" is the closest to "yes, right now".
        if (answer == .allow or answer == .allow_always) {
            for (options) |o| {
                if (std.mem.startsWith(u8, o.kind, "allow")) return o.id;
            }
        }
        for (options) |o| {
            if (std.mem.startsWith(u8, o.kind, "reject")) return o.id;
        }
        _ = prompt;
        return null;
    }
};
fn reportAcpErr(m: *tui.Model, err: anyerror) void {
    const line: []const u8 = switch (err) {
        error.SpawnFailed => blk: {
            const cmd = acp_cmd orelse "opencode acp";
            break :blk std.fmt.allocPrint(
                m.allocator,
                "could not launch the ACP agent ({s}). Is `opencode` in the PATH? /acp <cmd> sets another one.",
                .{cmd},
            ) catch "ACP: could not launch the agent";
        },
        error.HandshakeFailed => "ACP: the agent did not answer initialize/session/new",
        error.NoSession => "ACP: no session (the agent closed it?)",
        error.AgentDied => "ACP: the agent closed the connection mid-turn",
        error.OutOfMemory => return,
        // The `catch` cannot be a LITERAL: `agent.pushInfoOwned` takes ownership of the
        // text and frees it in `Model.deinit`, so a literal here is an "Invalid
        // free" on the OOM path (which is exactly when you least want a second
        // crash). No memory, no message.
        else => std.fmt.allocPrint(m.allocator, "ACP: {t}", .{err}) catch return,
    };
    agent.pushInfoOwned(m, line);
}
