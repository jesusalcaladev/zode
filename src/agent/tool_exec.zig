const std = @import("std");
const builtin = @import("builtin");
const tui = @import("../tui.zig");
const session_mod = @import("../session.zig");
const tools_mod = @import("../tools/dispatch.zig");
const permrules = @import("../lib/permrules.zig");
const turn_types = @import("turn_types.zig");

pub const TurnCtx = turn_types.TurnCtx;
pub const ResultBudget = turn_types.ResultBudget;

pub const ParallelResult = struct { ok: usize, denied: usize };

pub fn elapsedMs(io: std.Io, t0: i128) u64 {
    const now = std.Io.Timestamp.now(io, .real).nanoseconds;
    const dt = now - t0;
    if (dt <= 0) return 0;
    return @intCast(@divTrunc(dt, std.time.ns_per_ms));
}

/// Plain nanosleep, NOT `Io.sleep` (AGENTS.md detached-worker trap).
pub fn napMs(ms: u64) void {
    if (builtin.os.tag != .linux) {
        std.Thread.yield() catch {};
        return;
    }
    const ts = std.os.linux.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.os.linux.nanosleep(&ts, null);
}

/// Waits for batch threads on a local counter (not global worker count).
pub fn waitForBatch(pending: *std.atomic.Value(usize), deadline_ms: u64) void {
    var waited: u64 = 0;
    while (pending.load(.seq_cst) > 0 and waited < deadline_ms) : (waited += 5) {
        napMs(5);
    }
}

pub const ParallelOps = struct {
    ctx: *anyopaque,
    toolArgSummary: *const fn (ctx: *anyopaque, name: []const u8, args_json: []const u8, arena: std.mem.Allocator) []const u8,
    toolResultSummary: *const fn (ctx: *anyopaque, name: []const u8, res: []const u8, arena: std.mem.Allocator) []const u8,
    setStatusTooling: *const fn (ctx: *anyopaque, text: []const u8) void,
    execOneCallSerial: *const fn (ctx: *anyopaque, call: TurnCtx.Call, arena: std.mem.Allocator, denied: *usize, budget: *ResultBudget) usize,
    capStoreAppendToolResult: *const fn (ctx: *anyopaque, call_id: []const u8, tool_name: []const u8, result: []const u8, arena: std.mem.Allocator, budget: *ResultBudget) void,
    noteTool: *const fn (ctx: *anyopaque) void,
};

pub fn runParallelBatch(
    m: *tui.Model,
    s: *session_mod.Session,
    t: *TurnCtx,
    from: usize,
    to: usize,
    arena: std.mem.Allocator,
    budget: *ResultBudget,
    io: std.Io,
    perm_rules: permrules.Set,
    ops: ParallelOps,
) ParallelResult {
    const n = to - from;
    const t0 = std.Io.Timestamp.now(io, .real).nanoseconds;

    for (t.calls.items[from..to]) |call| {
        const arg = ops.toolArgSummary(ops.ctx, call.name, call.args_json, arena);
        m.pushToolStart(call.name, arg);
    }
    var batch_buf: [128]u8 = undefined;
    const batch_label = std.fmt.bufPrint(&batch_buf, "{d} searches in parallel", .{n}) catch "searching";
    ops.setStatusTooling(ops.ctx, batch_label);
    m.toolRunEnd();

    const Job = struct {
        name: []const u8,
        args: []const u8,
        id: []const u8,
        text: []const u8,
        ms: u64,
        err: bool,
    };
    var results = arena.alloc(Job, n) catch {
        var ok: usize = 0;
        var denied: usize = 0;
        for (t.calls.items[from..to]) |call| {
            ok += ops.execOneCallSerial(ops.ctx, call, arena, &denied, budget);
        }
        return .{ .ok = ok, .denied = denied };
    };
    @memset(results, .{ .name = "", .args = "", .id = "", .text = "", .ms = 0, .err = false });

    const Ctx = struct {
        call: TurnCtx.Call,
        out: *Job,
        m: *tui.Model,
        pending: *std.atomic.Value(usize),
        io: std.Io,
        perm_rules: permrules.Set,
    };
    var ctxs = arena.alloc(Ctx, n) catch return .{ .ok = 0, .denied = 0 };
    var pending = std.atomic.Value(usize).init(n);
    for (t.calls.items[from..to], 0..) |call, k| {
        ctxs[k] = .{ .call = call, .out = &results[k], .m = m, .pending = &pending, .io = io, .perm_rules = perm_rules };
    }
    const Runner = struct {
        fn run(ctx: *Ctx) void {
            ctx.m.beginWorker();
            defer ctx.m.endWorker();
            defer _ = ctx.pending.fetchSub(1, .seq_cst);
            const call_t0 = std.Io.Timestamp.now(ctx.io, .real).nanoseconds;
            var astate = std.heap.ArenaAllocator.init(ctx.m.allocator);
            defer astate.deinit();
            const a = astate.allocator();
            const text = tools_mod.executeWith(ctx.io, ctx.call.name, ctx.call.args_json, a, &ctx.m.bg, &ctx.m.reads, &ctx.m.tasks, ctx.perm_rules) catch |err| {
                ctx.out.err = true;
                ctx.out.text = @constCast(@errorName(err));
                ctx.out.ms = elapsedMs(ctx.io, call_t0);
                return;
            };
            ctx.out.text = ctx.m.allocator.dupe(u8, text) catch "";
            ctx.out.ms = elapsedMs(ctx.io, call_t0);
        }
    };
    for (ctxs) |*c| {
        const th = std.Thread.spawn(.{}, Runner.run, .{c}) catch {
            Runner.run(c);
            continue;
        };
        th.detach();
    }
    waitForBatch(&pending, 120_000);

    var ok: usize = 0;
    for (results, 0..) |r, k| {
        const call = t.calls.items[from + k];
        if (r.text.len == 0 and r.err) {
            m.pushToolDone(call.name, "failed", r.ms, "the parallel search failed");
            s.appendToolResult(call.id, call.name, "the parallel search failed") catch {};
            continue;
        }
        ok += 1;
        ops.noteTool(ops.ctx);
        const summary = ops.toolResultSummary(ops.ctx, call.name, r.text, arena);
        m.pushToolDone(call.name, summary, r.ms, r.text);
        ops.capStoreAppendToolResult(ops.ctx, call.id, call.name, r.text, arena, budget);
        if (!r.err) m.allocator.free(r.text);
    }

    const total_ms = elapsedMs(io, t0);
    var sum_buf: [128]u8 = undefined;
    const sum = std.fmt.bufPrint(&sum_buf, "{d} searches in parallel · {d}.{d}s", .{
        n,
        total_ms / 1000,
        (total_ms % 1000) / 100,
    }) catch "searches";
    ops.setStatusTooling(ops.ctx, sum);
    return .{ .ok = ok, .denied = 0 };
}

const taskstore = @import("../lib/taskstore.zig");

pub fn taskBatchEnd(calls: []const TurnCtx.Call, from: usize) usize {
    var jt = from + 1;
    while (jt < calls.len and std.mem.eql(u8, calls[jt].name, "task")) jt += 1;
    return jt;
}

pub fn bindTasks(io: std.Io, m: *tui.Model, s: *session_mod.Session) void {
    const sp = s.path orelse return;
    var buf: [512]u8 = undefined;
    const path = taskstore.pathForSession(&buf, sp) catch return;
    m.tasks.bind(io, path);
}

pub const ToolCallsOps = struct {
    ctx: *anyopaque,
    askCall: *const fn (*anyopaque, *tui.Model, *session_mod.Session, TurnCtx.Call, std.mem.Allocator, *ResultBudget) usize,
    skillCall: *const fn (*anyopaque, *tui.Model, *session_mod.Session, TurnCtx.Call, std.mem.Allocator, *ResultBudget) usize,
    reviewCall: *const fn (*anyopaque, *tui.Model, *session_mod.Session, TurnCtx.Call, std.mem.Allocator, *ResultBudget) usize,
    memoryCall: *const fn (*anyopaque, *tui.Model, *session_mod.Session, TurnCtx.Call, std.mem.Allocator, *ResultBudget) usize,
    taskCall: *const fn (*anyopaque, *tui.Model, *session_mod.Session, TurnCtx.Call, std.mem.Allocator, *ResultBudget) usize,
    runTaskBatch: *const fn (*anyopaque, *tui.Model, *session_mod.Session, *TurnCtx, usize, usize, std.mem.Allocator, *ResultBudget) ParallelResult,
    execOneCall: *const fn (*anyopaque, *tui.Model, *session_mod.Session, TurnCtx.Call, std.mem.Allocator, *usize, *ResultBudget) usize,
    parallel: ParallelOps,
    perm_rules: permrules.Set,
};

pub fn execToolCalls(
    m: *tui.Model,
    s: *session_mod.Session,
    t: *TurnCtx,
    io: std.Io,
    ops: ToolCallsOps,
) !void {
    const gpa = m.allocator;
    bindTasks(io, m, s);
    var astate = std.heap.ArenaAllocator.init(gpa);
    defer astate.deinit();
    const arena = astate.allocator();
    const t0 = std.Io.Timestamp.now(io, .real).nanoseconds;
    var ran: usize = 0;
    var denied: usize = 0;
    var budget: ResultBudget = .{};

    var i: usize = 0;
    while (i < t.calls.items.len) {
        const call = t.calls.items[i];

        if (std.mem.eql(u8, call.name, "ask")) {
            i += 1;
            ran += ops.askCall(ops.ctx, m, s, call, arena, &budget);
            continue;
        }
        if (std.mem.eql(u8, call.name, "skill")) {
            i += 1;
            ran += ops.skillCall(ops.ctx, m, s, call, arena, &budget);
            continue;
        }
        if (std.mem.eql(u8, call.name, "review")) {
            i += 1;
            ran += ops.reviewCall(ops.ctx, m, s, call, arena, &budget);
            continue;
        }
        if (std.mem.eql(u8, call.name, "memory")) {
            i += 1;
            ran += ops.memoryCall(ops.ctx, m, s, call, arena, &budget);
            continue;
        }
        if (std.mem.eql(u8, call.name, "task")) {
            const jt = taskBatchEnd(t.calls.items, i);
            if (jt - i == 1) {
                i += 1;
                ran += ops.taskCall(ops.ctx, m, s, call, arena, &budget);
            } else {
                const r = ops.runTaskBatch(ops.ctx, m, s, t, i, jt, arena, &budget);
                ran += r.ok + r.denied;
                i = jt;
            }
            continue;
        }

        var batch: usize = i;
        while (batch < t.calls.items.len and tools_mod.isParallelSafe(t.calls.items[batch].name)) batch += 1;

        if (batch - i > 1) {
            const n = runParallelBatch(m, s, t, i, batch, arena, &budget, io, ops.perm_rules, ops.parallel);
            ran += n.ok;
            denied += n.denied;
            i = batch;
            continue;
        }

        i += 1;
        ran += ops.execOneCall(ops.ctx, m, s, call, arena, &denied, &budget);
    }

    // Repetition/no-progress guards (operates on model state).
    for (t.calls.items) |c| {
        if (m.repeats.noteGuarded(c.name, c.args_json)) |which| {
            if (m.loop_repeated == null) m.loop_repeated = which;
        }
        if (std.mem.eql(u8, c.name, "read")) {
            if (m.repeats.noteRead(c.args_json)) |which| {
                if (m.loop_repeated == null) m.loop_repeated = which;
            }
        } else if (std.mem.eql(u8, c.name, "write") or std.mem.eql(u8, c.name, "edit") or std.mem.eql(u8, c.name, "notebook_edit")) {
            m.repeats.noteWrite();
        }
    }

    s.flush();
    const total_ms = elapsedMs(io, t0);
    const tools_status = std.fmt.allocPrint(
        gpa,
        "{d} tool{s} · {d}.{d}s{s}",
        .{
            ran,
            if (ran == 1) "" else "s",
            total_ms / 1000,
            (total_ms % 1000) / 100,
            if (denied > 0) " · denied" else "",
        },
    ) catch "tools done";
    ops.parallel.setStatusTooling(ops.ctx, tools_status);
}

const pathsafe = @import("../lib/pathsafe.zig");
const hooks_mod = @import("../lib/hooks.zig");
const cmdsafety = @import("../lib/cmdsafety.zig");
const sandbox_mod = @import("../lib/sandbox.zig");
const toolstore = @import("../lib/toolstore.zig");
const resultcap = @import("../lib/resultcap.zig");
const tools_registry = @import("../tools/registry.zig");
const tool_exec_policy = @import("tool_exec_policy.zig");
const tool_exec_perm = @import("tool_exec_perm.zig");
const tool_exec_preflight = @import("tool_exec_preflight.zig");

pub const ExecState = struct {
    io: std.Io,
    yolo: bool,
    read_only: bool,
    environ: ?*const std.process.Environ.Map,
    perm_rules: permrules.Set,
    hooks_set: *hooks_mod.Set,
    accept_edits: bool,
    // sandbox detection is IO; caller may provide result or we detect via callback
};

pub fn capStoreAppendToolResult(
    s: *session_mod.Session,
    io: std.Io,
    call_id: []const u8,
    tool_name: []const u8,
    result: []const u8,
    arena: std.mem.Allocator,
    budget: *ResultBudget,
) void {
    const tool_cap = tools_registry.resultCap(tool_name);
    var result_text: []const u8 = result;
    if (tool_cap != 0 and result.len > tool_cap) {
        if (s.path) |spath| {
            const stored = toolstore.storeResult(arena, io, spath, s.tool_result_next, result);
            s.tool_result_next += 1;
            if (stored.stored) result_text = stored.text;
        }
    } else if (tool_cap == 0 and result.len > resultcap.default_max_result_chars) {
        if (s.path) |spath| {
            const stored = toolstore.storeResult(arena, io, spath, s.tool_result_next, result);
            s.tool_result_next += 1;
            if (stored.stored) result_text = stored.text;
        }
    }
    const budget_cap = budget.capFor(tool_cap);
    var final_text = result_text;
    if (toolstore.extractStoredPath(result_text)) |_| {
        if (s.result_caps.find(call_id)) |rec| {
            if (!rec.cut) {
                final_text = result_text;
            } else {
                const capped = resultcap.frozenCapResult(&s.result_caps, s.allocator, arena, call_id, result_text, @max(budget_cap, rec.bytes_kept)) catch resultcap.Capped{ .text = result_text, .cut = false };
                final_text = capped.text;
            }
        } else {
            s.result_caps.record(s.allocator, call_id, result_text.len, false) catch {};
            final_text = result_text;
        }
    } else {
        const capped = resultcap.frozenCapResult(&s.result_caps, s.allocator, arena, call_id, result_text, budget_cap) catch resultcap.Capped{ .text = result_text, .cut = false };
        final_text = capped.text;
    }
    budget.charge(final_text.len);
    s.saveCapsSidecar();
    s.appendToolResult(call_id, tool_name, final_text) catch {};
}

pub const PermAnswer = enum { allow, allow_always, allow_sandbox, deny, none };

pub const ExecOneOps = struct {
    ctx: *anyopaque,
    toolArgSummary: *const fn (*anyopaque, []const u8, []const u8, std.mem.Allocator) []const u8,
    toolTimelineLabel: *const fn (*anyopaque, []const u8, []const u8, []const u8, std.mem.Allocator) []const u8,
    toolResultSummary: *const fn (*anyopaque, []const u8, []const u8, std.mem.Allocator) []const u8,
    setStatusTooling: *const fn (*anyopaque, *tui.Model, []const u8) void,
    pushToolStart: *const fn (*anyopaque, *tui.Model, []const u8, []const u8) void,
    pushToolDone: *const fn (*anyopaque, *tui.Model, []const u8, []const u8, u64, []const u8) void,
    permAutoAllowed: *const fn (*anyopaque, []const u8, []const u8, []const u8, std.mem.Allocator) bool,
    permNeedsDialog: *const fn (*anyopaque, []const []const u8) bool,
    rememberAlwaysAllow: *const fn (*anyopaque, *tui.Model, []const u8, []const u8, []const u8, []const []const u8, std.mem.Allocator) void,
    requestPermission: *const fn (*anyopaque, *tui.Model, []const u8, []const u8) PermAnswer,
    requestPermissionOnce: *const fn (*anyopaque, *tui.Model, []const u8, []const u8) PermAnswer,
    setPermSuggestion: *const fn (*anyopaque, *tui.Model, []const u8) void,
    setPermRule: *const fn (*anyopaque, *tui.Model, []const u8) void,
    setPermSandboxAvailable: *const fn (*anyopaque, *tui.Model, bool) void,
    permSuggestion: *const fn (*anyopaque, []const u8, []const u8, std.mem.Allocator) ?[]const u8,
    sandboxAvailable: *const fn (*anyopaque, []const u8, std.mem.Allocator) bool,
    bashCommandOf: *const fn (*anyopaque, []const u8, std.mem.Allocator) []const u8,
    filePathOf: *const fn (*anyopaque, []const u8, std.mem.Allocator) ?[]const u8,
    snapshotForUndo: *const fn (*anyopaque, *tui.Model, []const u8, std.mem.Allocator) void,
    prepareImage: *const fn (*anyopaque, *tui.Model, []const u8) ?[]const u8,
    applyPlanCall: *const fn (*anyopaque, *tui.Model, []const u8, std.mem.Allocator) void,
    applyGoalCall: *const fn (*anyopaque, *tui.Model, []const u8, std.mem.Allocator) void,
    noteTool: *const fn (*anyopaque) void,
    noteDenied: *const fn (*anyopaque) void,
    noteRead: *const fn (*anyopaque) void,
    pushFileDiffAndNote: *const fn (*anyopaque, *tui.Model, []const u8, []const u8, []const u8) void,
};

pub fn permDecisionWithPolicy(perm_rules: permrules.Set, tool: []const u8, subjects: []const []const u8) ?permrules.Decision {
    if (permrules.decide(perm_rules.rules, tool, subjects)) |d| return d;
    for (subjects) |sub| {
        const v = pathsafe.checkWrite(sub);
        if (v == .ok) continue;
        return .{
            .action = .ask,
            .rule = .{
                .tool = tool,
                .pattern = sub,
                .action = .ask,
                .source = .policy,
                .text = switch (v) {
                    .dangerous => |d| d.what,
                    else => "a protected path",
                },
            },
        };
    }
    return null;
}

pub fn execOneCall(
    m: *tui.Model,
    s: *session_mod.Session,
    call: TurnCtx.Call,
    arena: std.mem.Allocator,
    denied: *usize,
    budget: *ResultBudget,
    state: ExecState,
    ops: ExecOneOps,
) usize {
    const arg = ops.toolArgSummary(ops.ctx, call.name, call.args_json, arena);
    const label = ops.toolTimelineLabel(ops.ctx, call.name, call.args_json, arg, arena);
    ops.pushToolStart(ops.ctx, m, call.name, label);
    ops.setStatusTooling(ops.ctx, m, label);

    if (std.mem.eql(u8, call.name, "bash")) {
        switch (tool_exec_policy.checkBashForbidden(call.args_json, arena)) {
            .ok => {},
            .forbidden => |msg| {
                ops.pushToolDone(ops.ctx, m, call.name, "refused: interactive command", 0, msg);
                capStoreAppendToolResult(s, state.io, call.id, call.name, msg, arena, budget);
                return 0;
            },
        }
    }

    const reads_only = tool_exec_policy.callReadsOnly(call.name, call.args_json, arena);
    if (tool_exec_policy.shouldBlockReadOnly(state.read_only, call.name, call.args_json, arena)) {
        m.plan_write_blocked_this_turn = true;
        ops.pushToolDone(ops.ctx, m, call.name, "blocked by plan mode", 0, tool_exec_policy.read_only_text);
        capStoreAppendToolResult(s, state.io, call.id, call.name, tool_exec_policy.read_only_text, arena, budget);
        return 0;
    }

    const subjects = tools_mod.callSubjects(call.name, call.args_json, arena);
    const rule_decision = permDecisionWithPolicy(state.perm_rules, call.name, subjects);
    const rp = tool_exec_preflight.rulePreflight(rule_decision, arena);
    if (rp.denied_msg) |msg| {
        ops.pushToolDone(ops.ctx, m, call.name, "refused by a rule", 0, msg);
        capStoreAppendToolResult(s, state.io, call.id, call.name, msg, arena, budget);
        return 0;
    }
    const rule_allowed = rp.allowed;
    const rule_match_text = rp.ask_text;

    const risky = tools_mod.riskyPaths(call.name, call.args_json, arena);
    var risky_allowed = false;
    if (risky.len > 0 and !state.yolo and !rule_allowed) {
        var asked = false;
        for (risky) |p| {
            const v = pathsafe.checkWrite(p);
            if (v == .ok) continue;
            if (asked) continue;
            asked = true;
            var dbuf: [384]u8 = undefined;
            const risky_why = switch (v) { .dangerous => |d| d.why, else => "" };
            const detail = tool_exec_perm.formatRiskyPathDetail(p, risky_why, &dbuf);
            switch (ops.requestPermissionOnce(ops.ctx, m, call.name, detail)) {
                .allow, .allow_sandbox, .allow_always => {
                    pathsafe.approve(p);
                    risky_allowed = true;
                },
                .deny, .none => {
                    denied.* += 1;
                    ops.noteDenied(ops.ctx);
                    const msg = pathsafe.refusalText(arena, v);
                    ops.pushToolDone(ops.ctx, m, call.name, "refused: sensitive path", 0, msg);
                    capStoreAppendToolResult(s, state.io, call.id, call.name, msg, arena, budget);
                    return 0;
                },
            }
        }
    }

    const perm_tools = tools_mod.callPermissionTools(call.name, call.args_json, arena);
    const auto_allowed = ops.permAutoAllowed(ops.ctx, call.name, arg, call.args_json, arena);
    const no_dialog = reads_only;
    var exec_args: []const u8 = call.args_json;
    if (tool_exec_preflight.needsPermissionDialog(state.yolo, auto_allowed, risky_allowed, rule_allowed, no_dialog, ops.permNeedsDialog(ops.ctx, perm_tools))) {
        var dbuf: [384]u8 = undefined;
        var detail: []const u8 = if (std.mem.eql(u8, call.name, "batch"))
            tools_mod.batchPermissionDetail(call.args_json, arena)
        else
            std.fmt.bufPrint(&dbuf, "{s} {s}", .{ call.name, arg }) catch call.name;
        if (std.mem.eql(u8, call.name, "bash")) {
            detail = tool_exec_policy.enrichBashPermissionDetail(detail, arg, arena);
        }
        if (ops.permSuggestion(ops.ctx, call.name, call.args_json, arena)) |sugg| {
            ops.setPermSuggestion(ops.ctx, m, sugg);
        } else {
            ops.setPermSuggestion(ops.ctx, m, "");
        }
        if (rule_match_text.len > 0) ops.setPermRule(ops.ctx, m, rule_match_text) else ops.setPermRule(ops.ctx, m, "");
        if (std.mem.eql(u8, call.name, "bash")) {
            const cmdv = ops.bashCommandOf(ops.ctx, call.args_json, arena);
            if (ops.sandboxAvailable(ops.ctx, cmdv, arena)) ops.setPermSandboxAvailable(ops.ctx, m, true);
        }
        // PermissionRequest hooks
        var hook_perm_answer: ?PermAnswer = null;
        const hook_subj = if (subjects.len > 0) subjects[0] else detail;
        const hook_res = hooks_mod.fire(m.allocator, state.hooks_set, .{ .event = .PermissionRequest, .tool = call.name, .subject = hook_subj, .prompt = detail }, state.io) catch &[_]hooks_mod.RunResult{};
        defer if (hook_res.len > 0) hooks_mod.freeResults(m.allocator, hook_res);
        if (hooks_mod.permissionDecision(hook_res)) |pd| {
            hook_perm_answer = switch (pd) { .allow => .allow, .deny => .deny, .ask => null };
        }
        const perm_answer = hook_perm_answer orelse ops.requestPermission(ops.ctx, m, call.name, detail);
        switch (perm_answer) {
            .allow => {},
            .allow_sandbox => {
                if (std.mem.eql(u8, call.name, "bash")) exec_args = tool_exec_perm.withSandboxArg(arena, call.args_json);
            },
            .allow_always => ops.rememberAlwaysAllow(ops.ctx, m, call.name, arg, call.args_json, perm_tools, arena),
            .deny, .none => {
                denied.* += 1;
                ops.noteDenied(ops.ctx);
                ops.pushToolDone(ops.ctx, m, call.name, "denied: permission required", 0, "denied");
                capStoreAppendToolResult(s, state.io, call.id, call.name, "denied: permission required", arena, budget);
                return 0;
            },
        }
    }

    const call_t0 = std.Io.Timestamp.now(state.io, .real).nanoseconds;
    var before: ?[]const u8 = null;
    if (std.mem.eql(u8, call.name, "batch")) {
        for (tools_mod.callTouchedPaths(call.name, call.args_json, arena)) |pth| ops.snapshotForUndo(ops.ctx, m, pth, arena);
    } else if (tool_exec_policy.touchesFile(call.name)) {
        if (ops.filePathOf(ops.ctx, call.args_json, arena)) |pth| {
            if (std.Io.Dir.cwd().readFileAlloc(state.io, pth, arena, .limited(4 * 1024 * 1024))) |content| {
                before = content;
                m.snapshotFile(pth, content, true);
            } else |err| {
                switch (err) { error.FileNotFound => m.snapshotFile(pth, "", false), else => {} }
            }
        }
    }

    if (std.mem.eql(u8, call.name, "read")) {
        if (ops.prepareImage(ops.ctx, m, call.args_json)) |res| {
            s.appendToolResult(call.id, call.name, res) catch {};
            ops.noteTool(ops.ctx);
            return 0;
        }
    }
    if (std.mem.eql(u8, call.name, "todo")) ops.applyPlanCall(ops.ctx, m, call.args_json, arena);
    if (std.mem.eql(u8, call.name, "goal")) ops.applyGoalCall(ops.ctx, m, call.args_json, arena);

    // PreToolUse hooks
    {
        const hook_subj = if (subjects.len > 0) subjects[0] else "";
        const hook_res = hooks_mod.fire(m.allocator, state.hooks_set, .{ .event = .PreToolUse, .tool = call.name, .subject = hook_subj }, state.io) catch &[_]hooks_mod.RunResult{};
        defer if (hook_res.len > 0) hooks_mod.freeResults(m.allocator, hook_res);
        if (hooks_mod.blockedReason(m.allocator, hook_res, .PreToolUse) catch null) |reason| {
            defer m.allocator.free(reason);
            const ms = elapsedMs(state.io, call_t0);
            ops.pushToolDone(ops.ctx, m, call.name, "blocked by hook", ms, reason);
            capStoreAppendToolResult(s, state.io, call.id, call.name, reason, arena, budget);
            return 0;
        }
        if (hooks_mod.updatedInput(hook_res)) |ui| exec_args = arena.dupe(u8, ui) catch exec_args;
    }

    var res = tools_mod.executeWith(state.io, call.name, exec_args, arena, &m.bg, &m.reads, &m.tasks, state.perm_rules) catch |err| {
        const ms = elapsedMs(state.io, call_t0);
        const emsg = tools_mod.describeError(arena, err, call.name, call.args_json);
        ops.pushToolDone(ops.ctx, m, call.name, "failed", ms, emsg);
        s.appendToolResult(call.id, call.name, emsg) catch {};
        return 0;
    };
    // PostToolUse hooks
    {
        const hook_subj = if (subjects.len > 0) subjects[0] else "";
        const hook_res = hooks_mod.fire(m.allocator, state.hooks_set, .{ .event = .PostToolUse, .tool = call.name, .subject = hook_subj }, state.io) catch &[_]hooks_mod.RunResult{};
        defer if (hook_res.len > 0) hooks_mod.freeResults(m.allocator, hook_res);
        if (hooks_mod.notesText(m.allocator, hook_res) catch null) |note| {
            defer m.allocator.free(note);
            res = std.fmt.allocPrint(arena, "{s}\n\n[hook note]\n{s}", .{ res, note }) catch res;
        }
    }
    const wrote = m.auto_check.noteWrite(call.name, call.args_json);
    m.auto_check.afterTool(&m.bg, state.io, wrote);
    const ms = elapsedMs(state.io, call_t0);
    ops.noteTool(ops.ctx);
    if (TurnStats_isReadOnlyTool(call.name)) ops.noteRead(ops.ctx);
    if (std.mem.eql(u8, call.name, "bash") and startedBackground(res)) m.bench.bg_jobs += 1;
    const summary = ops.toolResultSummary(ops.ctx, call.name, res, arena);
    ops.pushToolDone(ops.ctx, m, call.name, summary, ms, res);
    if (before) |old| {
        if (ops.filePathOf(ops.ctx, call.args_json, arena)) |pth| {
            const after = std.Io.Dir.cwd().readFileAlloc(state.io, pth, arena, .limited(4 * 1024 * 1024)) catch {
                s.appendToolResult(call.id, call.name, res) catch {};
                return 1;
            };
            ops.pushFileDiffAndNote(ops.ctx, m, old, after, pth);
        }
    }
    if (ops.filePathOf(ops.ctx, call.args_json, arena)) |pth| {
        if (tool_exec_policy.isWriteTool(call.name)) {
            m.reads.invalidate(pth);
            _ = m.invalidateFactSource(pth, 0);
            _ = m.invalidateProjectFacts();
        }
    }
    if (tool_exec_policy.callIsWrite(call.name, call.args_json, arena)) {
        for (tools_mod.callTouchedPaths(call.name, call.args_json, arena)) |pth| m.changed.note(pth);
    }
    if (std.mem.eql(u8, call.name, "bash") and !reads_only) m.bash_may_write = true;
    capStoreAppendToolResult(s, state.io, call.id, call.name, res, arena, budget);
    if (std.mem.eql(u8, call.name, "read")) {
        if (s.messages.items.len > 0) {
            const idx: u32 = @intCast(s.messages.items.len - 1);
            if (ops.filePathOf(ops.ctx, call.args_json, arena)) |pth| m.reads.setMessageIndex(pth, idx);
        }
    }
    return 1;
}

fn startedBackground(res: []const u8) bool {
    return tool_exec_policy.startedBackground(res);
}

fn TurnStats_isReadOnlyTool(name: []const u8) bool {
    // mirror TurnStats.isReadOnlyTool used in agent; avoid importing agent.
    return std.mem.eql(u8, name, "read") or std.mem.eql(u8, name, "glob") or std.mem.eql(u8, name, "grep") or std.mem.eql(u8, name, "list") or std.mem.eql(u8, name, "webfetch") or std.mem.eql(u8, name, "websearch") or std.mem.eql(u8, name, "lsp");
}
