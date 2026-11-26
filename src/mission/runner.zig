//! Mission runner — part of the zode core, dispatched by `zode mission`.
//!
//!   zode mission plan "<objective>"       create .mission/ with executable checks
//!   zode mission status <workspace>       show state, checks and next task
//!   zode mission check <workspace>        run the checks and write evidence
//!   zode mission run <workspace>          supervise until complete or stopped
//!
//! The agent command comes from ZODE_MISSION_AGENT (default: `zode --chat`).
//! ZODE_MISSION_WORKERS (default 1) enables parallel worker prompts in waves.
//! Same on-disk contract as the OpenCode plugin: `docs/missions-zode.md`.

const std = @import("std");
const mission = @import("contract.zig");
const mission_io = @import("io.zig");
const instructions = @import("../lib/instructions.zig");

const dir = std.Io.Dir.cwd();

fn nap(ms: u64) void {
    const ts = std.os.linux.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.os.linux.nanosleep(&ts, null);
}

const plan_prompt_fmt =
    \\You are the planner of an autonomous coding harness. Convert the objective into an executable JSON plan.
    \\Output ONLY one JSON object, no markdown, no explanation.
    \\SHAPE: {{"objective":"...","checks":[{{"id":"short_id","cmd":"shell command","expect":"exit0 | contains:text","timeout_ms":30000}}],"tasks":[{{"id":1,"subject":"short imperative","files":["relative/path"],"verify":"check_id","blocked_by":[]}}]}}
    \\RULES: 1..10 checks; commands finish under 30s and are safe; 1..12 tasks with sequential ids; verify MUST name a check id; disjoint files for parallel tasks; no destructive commands.
    \\OBJECTIVE: {s}
;

fn usage() void {
    std.debug.print(
        \\usage: zode mission <command> [args]
        \\  plan <objective>     create a mission workspace under ./missions/
        \\  status <workspace>   print the durable state
        \\  check <workspace>    run criteria and write evidence
        \\  run <workspace>      drive the agent until the criteria are green
        \\
    , .{});
}

fn envGet(map: ?*const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const m = map orelse return null;
    return m.get(key);
}

/// Project rules (CLAUDE.local.md, AGENTS.md/CLAUDE.md hierarchy, user file)
/// are injected into every mission prompt. The runner used to ignore them,
/// even though the interactive agent loads them — a mission could widen its
/// own rules without ever seeing the repo's. Bounded at 12 KB so the context
/// cannot push the criteria out of a small model window.
fn loadProjectInstructions(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, root: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const paths = try instructions.collect(a, io, env, root, null);
    var entries = std.ArrayList(mission_io.InstructionEntry).empty;
    defer entries.deinit(a);
    for (paths) |path| {
        const text = dir.readFileAlloc(io, path, a, .limited(64 * 1024)) catch continue;
        try entries.append(a, .{ .path = path, .text = text });
    }
    return mission_io.composeInstructions(gpa, entries.items, 12 * 1024);
}

fn buildContext(gpa: std.mem.Allocator, project_instructions: []const u8, facts_text: []const u8) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ project_instructions, facts_text });
}

const RoleModels = struct {
    fast: ?[]const u8 = null,
    overrides: []mission_io.RoleModel = &.{},

    /// Explicit `role=model` first, then the fast model for read-only roles,
    /// then the lead/worker model for implementers.
    fn modelFor(self: RoleModels, role: []const u8, lead: ?[]const u8) ?[]const u8 {
        if (mission_io.roleModelOverride(self.overrides, role)) |m| return m;
        if (mission_io.isReadOnlyRole(role)) return self.fast orelse lead;
        return lead;
    }
};

fn joinArgs(gpa: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    for (args, 0..) |a, i| {
        if (i > 0) try out.append(gpa, ' ');
        try out.appendSlice(gpa, a);
    }
    return out.toOwnedSlice(gpa);
}

fn slugify(gpa: std.mem.Allocator, objective: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    var it = std.mem.tokenizeAny(u8, objective, " \t\r\n,:;()[]{}\"'`./-_");
    var words: usize = 0;
    while (it.next()) |word| : (words += 1) {
        if (words >= 4) break;
        if (out.items.len > 0) try out.append(gpa, '-');
        for (word) |c| {
            try out.append(gpa, std.ascii.toLower(c));
        }
    }
    if (out.items.len == 0) try out.appendSlice(gpa, "mission");
    return out.toOwnedSlice(gpa);
}

fn callAgentCapture(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, command: []const u8, prompt: []const u8) ?[]const u8 {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(gpa);
    var it = std.mem.tokenizeScalar(u8, command, ' ');
    while (it.next()) |part| argv.append(gpa, part) catch return null;
    argv.append(gpa, prompt) catch return null;
    const result = std.process.run(gpa, io, .{
        .argv = argv.items,
        .environ_map = env,
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return null;
    defer gpa.free(result.stderr);
    if (switch (result.term) {
        .exited => |code| code != 0,
        else => true,
    }) {
        gpa.free(result.stdout);
        return null;
    }
    return result.stdout;
}

fn planWithModel(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, objective: []const u8) ?mission.Plan {
    const command = envGet(env, "ZODE_MISSION_AGENT") orelse "zode --chat";
    const prompt = std.fmt.allocPrint(gpa, plan_prompt_fmt, .{objective}) catch return null;
    defer gpa.free(prompt);
    const raw = callAgentCapture(gpa, io, env, command, prompt) orelse return null;
    defer gpa.free(raw);
    const start = std.mem.indexOfScalar(u8, raw, '{') orelse return null;
    const end = std.mem.lastIndexOfScalar(u8, raw, '}') orelse return null;
    if (end <= start) return null;
    return mission.planFromJson(gpa, raw[start .. end + 1]) catch null;
}

fn cmdPlan(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, objective: []const u8) !u8 {
    if (objective.len < 3) {
        std.debug.print("an objective of at least 3 characters is required\n", .{});
        return 2;
    }
    const slug = try slugify(gpa, objective);
    defer gpa.free(slug);
    const secs = std.Io.Timestamp.now(io, .real).toSeconds();
    const root = try std.fmt.allocPrint(gpa, "./missions/{s}-{d}", .{ slug, @as(u64, @intCast(@max(0, secs))) });
    defer gpa.free(root);
    const heuristic = try mission.planFromObjective(gpa, objective);
    var plan = heuristic;
    var source: []const u8 = "heuristic";
    if (envGet(env, "ZODE_MISSION_PLANNER") != null) {
        if (planWithModel(gpa, io, env, objective)) |model_plan| {
            plan = model_plan;
            source = "model";
        } else {
            std.debug.print("model planner unavailable; using heuristic plan\n", .{});
        }
    }
    try mission_io.writePlanFiles(gpa, io, root, plan);
    std.debug.print("mission created: {s} (plan: {s})\n  checks: {d}\n  tasks: {d}\nnext: zode mission run {s}\n", .{
        root, source, plan.checks.len, plan.tasks.len, root,
    });
    return 0;
}

fn printStatus(gpa: std.mem.Allocator, io: std.Io, root: []const u8) !u8 {
    const state = try mission_io.loadState(gpa, io, root);
    const tasks = try mission_io.loadTasks(gpa, io, root);
    defer gpa.free(tasks);
    const results = try mission_io.loadCriteria(gpa, io, root);
    defer gpa.free(results);
    const dashboard = try mission_io.renderStatus(gpa, state, tasks.len, results.len);
    defer gpa.free(dashboard);
    std.debug.print("Mission: {s}\n{s}", .{ root, dashboard });
    for (tasks) |t| {
        std.debug.print("  #{d} [{s}] {s}\n", .{ t.id, t.status.name(), t.subject });
    }
    for (results) |c| std.debug.print("  check {s}: {s}\n", .{ c.id, c.cmd });
    return 0;
}

fn cmdCheck(gpa: std.mem.Allocator, io: std.Io, root: []const u8) !u8 {
    const checks = try mission_io.loadCriteria(gpa, io, root);
    defer gpa.free(checks);
    if (checks.len == 0) {
        std.debug.print("no checks in {s}/{s}\n", .{ root, mission.criteria_file });
        return 2;
    }
    const results = try mission_io.runChecks(gpa, io, root, checks);
    defer mission_io.freeCheckResults(gpa, results);
    var green: usize = 0;
    for (results) |r| {
        if (r.ok) green += 1;
        std.debug.print("{s} {s}: {s}\n", .{ if (r.ok) "PASS" else "FAIL", r.id, r.summary });
    }
    std.debug.print("{d}/{d} checks green\n", .{ green, results.len });
    return if (mission.allGreen(results)) 0 else 1;
}

fn agentArgv(gpa: std.mem.Allocator, agent_command: []const u8, prompt: []const u8) ![]const []const u8 {
    var argv = std.ArrayList([]const u8).empty;
    errdefer argv.deinit(gpa);
    var it = std.mem.tokenizeScalar(u8, agent_command, ' ');
    while (it.next()) |part| try argv.append(gpa, part);
    try argv.append(gpa, prompt);
    return argv.toOwnedSlice(gpa);
}

fn callAgent(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, root: []const u8, prompt: []const u8, command: []const u8, model: ?[]const u8) bool {
    const argv = agentArgv(gpa, command, prompt) catch return false;
    defer gpa.free(argv);
    var child_env = std.process.Environ.Map.init(gpa);
    defer child_env.deinit();
    if (env) |parent| {
        var it = parent.iterator();
        while (it.next()) |kv| {
            child_env.put(kv.key_ptr.*, kv.value_ptr.*) catch return false;
        }
    }
    if (model) |m| child_env.put("ZODE_MODEL", m) catch return false;
    const result = std.process.run(gpa, io, .{
        .argv = argv,
        .cwd = .{ .path = root },
        .environ_map = &child_env,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch {
        std.debug.print("agent command failed: {s}\n", .{command});
        return false;
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.stdout.len > 0) std.debug.print("{s}", .{result.stdout});
    if (result.stderr.len > 0) std.debug.print("{s}", .{result.stderr});
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn writeWorkerPrompts(gpa: std.mem.Allocator, io: std.Io, root: []const u8, tasks: []const mission.Task, wave: mission.Wave, context: []const u8) ![]const []const u8 {
    var prompts = std.ArrayList([]const u8).empty;
    errdefer prompts.deinit(gpa);
    const prompts_dir = try std.fmt.allocPrint(gpa, "{s}/{s}/prompts", .{ root, mission.dir_name });
    defer gpa.free(prompts_dir);
    try dir.createDirPath(io, prompts_dir);
    for (wave.ids) |id| {
        for (tasks) |task| {
            if (task.id != id) continue;
            const path = try std.fmt.allocPrint(gpa, "{s}/task-{d}.txt", .{ prompts_dir, id });
            const text = try std.fmt.allocPrint(gpa,
                "{s}[MISSION WORKER] Workspace: {s}\nTask #{d}: {s}\nDo only this task. Use zode's write/edit tools. Do not run the global checks; the lead verifies them. When finished, create a note with mission_task_done in your final answer. The harness writes .mission/prompts/task-{d}.done when your process exits.\n",
                .{ context, root, task.id, task.subject, task.id });
            try dir.writeFile(io, .{ .sub_path = path, .data = text });
            try prompts.append(gpa, path);
            break;
        }
    }
    return prompts.toOwnedSlice(gpa);
}

const WorkerCtx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    env: ?*const std.process.Environ.Map,
    root: []const u8,
    command: []const u8,
    prompt_path: []const u8,
    marker_path: []const u8,
    model: ?[]const u8,
    ok: bool = false,

    fn run(self: *WorkerCtx) void {
        const text = std.Io.Dir.cwd().readFileAlloc(self.io, self.prompt_path, self.gpa, .limited(1024 * 1024)) catch return;
        defer self.gpa.free(text);
        self.ok = callAgent(self.gpa, self.io, self.env, self.root, text, self.command, self.model);
        dir.writeFile(self.io, .{ .sub_path = self.marker_path, .data = if (self.ok) "done\n" else "failed\n" }) catch {};
    }
};

/// One thread per worker, one explicit completion marker per task. The old
/// `sh -c 'for p ...; do (...) & done; wait'` had no way to tell which task
/// failed — the lead only saw the aggregate exit of a shell.
fn callWorkers(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, root: []const u8, tasks: []const mission.Task, wave: mission.Wave, model: ?[]const u8, context: []const u8) void {
    const paths = writeWorkerPrompts(gpa, io, root, tasks, wave, context) catch return;
    defer gpa.free(paths);
    const command = envGet(env, "ZODE_MISSION_AGENT") orelse "zode --chat";
    const ctxs = gpa.alloc(WorkerCtx, paths.len) catch return;
    defer gpa.free(ctxs);
    for (paths, ctxs) |prompt_path, *ctx| {
        const dot = std.mem.lastIndexOfScalar(u8, prompt_path, '.') orelse prompt_path.len;
        const marker_path = std.fmt.allocPrint(gpa, "{s}.done", .{prompt_path[0..dot]}) catch return;
        ctx.* = .{
            .gpa = gpa, .io = io, .env = env, .root = root, .command = command,
            .prompt_path = prompt_path, .marker_path = marker_path, .model = model,
        };
    }
    defer for (ctxs) |ctx| gpa.free(ctx.marker_path);

    const threads = gpa.alloc(?std.Thread, ctxs.len) catch return;
    defer gpa.free(threads);
    @memset(threads, null);
    for (ctxs, threads) |*ctx, *slot| {
        slot.* = std.Thread.spawn(.{}, WorkerCtx.run, .{ctx}) catch null;
        if (slot.* == null) WorkerCtx.run(ctx);
    }
    for (threads) |slot| if (slot) |thread| thread.join();

    for (ctxs) |ctx| {
        if (ctx.ok) continue;
        const note = std.fmt.allocPrint(gpa, "worker failed: {s}", .{std.fs.path.basename(ctx.prompt_path)}) catch continue;
        defer gpa.free(note);
        mission_io.appendJournal(gpa, io, root, note) catch {};
    }
}

fn objectiveFrom(text: []const u8) []const u8 {
    var body = text;
    if (std.mem.startsWith(u8, body, "---")) {
        if (std.mem.indexOfPos(u8, body, 4, "---")) |end| body = body[end + 3 ..];
    }
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len > 0 and t[0] != '#') return t;
    }
    return "Autonomous mission";
}

fn jsonQuote(gpa: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        else => try out.append(gpa, c),
    };
    try out.append(gpa, '"');
    return out.toOwnedSlice(gpa);
}

fn jsonChecks(gpa: std.mem.Allocator, checks: []const mission.Check) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{\"version\":1,\"checks\":[");
    for (checks, 0..) |c, i| {
        if (i > 0) try out.append(gpa, ',');
        const id = try jsonQuote(gpa, c.id);
        defer gpa.free(id);
        const cmd = try jsonQuote(gpa, c.cmd);
        defer gpa.free(cmd);
        const expect = try jsonQuote(gpa, c.expect);
        defer gpa.free(expect);
        const part = try std.fmt.allocPrint(gpa, "{{\"id\":{s},\"cmd\":{s},\"expect\":{s},\"timeout_ms\":{d}}}", .{ id, cmd, expect, c.timeout_ms });
        defer gpa.free(part);
        try out.appendSlice(gpa, part);
    }
    try out.appendSlice(gpa, "]}");
    return out.toOwnedSlice(gpa);
}

fn jsonTasks(gpa: std.mem.Allocator, tasks: []const mission.Task) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{\"version\":1,\"tasks\":[");
    for (tasks, 0..) |t, i| {
        if (i > 0) try out.append(gpa, ',');
        const subject = try jsonQuote(gpa, t.subject);
        defer gpa.free(subject);
        const verify = try jsonQuote(gpa, t.verify);
        defer gpa.free(verify);
        const head = try std.fmt.allocPrint(gpa, "{{\"id\":{d},\"subject\":{s},\"verify\":{s},\"files\":[", .{ t.id, subject, verify });
        defer gpa.free(head);
        try out.appendSlice(gpa, head);
        for (t.files, 0..) |f, j| {
            if (j > 0) try out.append(gpa, ',');
            const q = try jsonQuote(gpa, f);
            defer gpa.free(q);
            try out.appendSlice(gpa, q);
        }
        try out.appendSlice(gpa, "],\"blocked_by\":[");
        for (t.blocked_by, 0..) |d, j| {
            if (j > 0) try out.append(gpa, ',');
            const dep = try std.fmt.allocPrint(gpa, "{d}", .{d});
            defer gpa.free(dep);
            try out.appendSlice(gpa, dep);
        }
        const tail = try std.fmt.allocPrint(gpa, "],\"status\":\"{s}\"}}", .{@tagName(t.status)});
        defer gpa.free(tail);
        try out.appendSlice(gpa, tail);
    }
    try out.appendSlice(gpa, "]}");
    return out.toOwnedSlice(gpa);
}

fn atomicText(gpa: std.mem.Allocator, io: std.Io, root: []const u8, name: []const u8, text: []const u8) !void {
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ root, mission.dir_name, name });
    defer gpa.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
}

fn readReport(gpa: std.mem.Allocator, io: std.Io, root: []const u8, role: []const u8) ?[]const u8 {
    const path = std.fmt.allocPrint(gpa, "{s}/{s}/{s}/{s}.txt", .{ root, mission.dir_name, mission.reports_dir, role }) catch return null;
    defer gpa.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 * 1024)) catch null;
}

fn callRole(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, root: []const u8, role: []const u8, prompt: []const u8, context: []const u8, model: ?[]const u8) ?[]const u8 {
    const report_path = std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ mission.dir_name, mission.reports_dir, role }) catch return null;
    defer gpa.free(report_path);
    const full_prompt = std.fmt.allocPrint(gpa,
        "{s}{s}\n\nWrite your final report to the file `{s}.txt` in the mission directory using your write tool. Keep it short and include SEVERITY lines when reviewing.",
        .{ context, prompt, report_path },
    ) catch return null;
    defer gpa.free(full_prompt);
    _ = callAgent(gpa, io, env, root, full_prompt, envGet(env, "ZODE_MISSION_AGENT") orelse "zode --chat", model);
    return readReport(gpa, io, root, role);
}

fn distillMemory(gpa: std.mem.Allocator, io: std.Io, root: []const u8, state: *mission_io.State) !void {
    if (state.turn == 0 or state.turn % 4 != 0) return;
    const journal = try mission_io.readJournal(gpa, io, root);
    defer gpa.free(journal);
    const memory = try mission_io.readMemory(gpa, io, root);
    defer gpa.free(memory);
    const out = try mission.memory.distill(gpa, journal, memory, mission.memory.budget);
    try mission_io.writeMemory(gpa, io, root, out.memory);
    try mission_io.writeSummary(gpa, io, root, out.summary);
    const note = try std.fmt.allocPrint(gpa, "memory compacted: {s}", .{out.summary});
    defer gpa.free(note);
    try mission_io.appendJournal(gpa, io, root, note);
}

fn chainNext(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, root: []const u8, state: *mission_io.State) !bool {
    _ = env;
    const text = try mission_io.readRoadmap(gpa, io, root);
    defer gpa.free(text);
    const items = try mission.chain.parseRoadmap(gpa, text);
    if (items.len == 0) return false;
    const item = mission.chain.nextItem(items) orelse {
        try mission_io.appendJournal(gpa, io, root, "chain exhausted: all roadmap items done");
        return false;
    };
    const plan = try mission.planFromObjective(gpa, item.title);
    const checks_json = try jsonChecks(gpa, plan.checks);
    defer gpa.free(checks_json);
    const tasks_json = try jsonTasks(gpa, plan.tasks);
    defer gpa.free(tasks_json);
    try atomicText(gpa, io, root, mission.criteria_file, checks_json);
    try atomicText(gpa, io, root, mission.tasks_file, tasks_json);
    state.* = .{
        .status = .running,
        .max_turns = state.max_turns,
        .budget_usd = state.budget_usd,
        .max_failures = state.max_failures,
        .max_extensions = state.max_extensions,
        .max_wallclock_min = state.max_wallclock_min,
        .max_writes = state.max_writes,
        .lease_ms = state.lease_ms,
        .chain_index = state.chain_index + 1,
        .chain_total = items.len,
        .stage = "investigate",
        .strategy_tier = 1,
    };
    try mission_io.saveState(gpa, io, root, state.*);
    const note = try std.fmt.allocPrint(gpa, "chain: starting mission {d}/{d} — {s}", .{ state.chain_index, state.chain_total, item.title });
    defer gpa.free(note);
    try mission_io.appendJournal(gpa, io, root, note);
    return true;
}

/// If an improvement cycle made the suite less green than its baseline, undo
/// exactly the checkpoint it created. The baseline SHA is never reverted.
fn rollbackIfRegressed(gpa: std.mem.Allocator, io: std.Io, root: []const u8, state: *mission_io.State, green: usize) !void {
    if (state.improve_revert_sha.len == 0 or green >= state.improve_baseline_green) return;
    const head = mission_io.gitHead(gpa, io, root);
    defer if (head) |sha| gpa.free(sha);
    if (head) |sha| {
        if (!std.mem.eql(u8, sha, state.improve_revert_sha)) {
            const reverted = mission_io.gitRevert(gpa, io, root, sha);
            const note = try std.fmt.allocPrint(gpa,
                "improvement rollback {s}: green {d} below baseline {d}",
                .{ if (reverted) "succeeded" else "failed", green, state.improve_baseline_green });
            defer gpa.free(note);
            try mission_io.appendJournal(gpa, io, root, note);
        }
    }
    gpa.free(state.improve_revert_sha);
    state.improve_revert_sha = "";
    state.improve_baseline_green = 0;
    try mission_io.saveState(gpa, io, root, state.*);
}

fn improveCycle(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, root: []const u8, state: *mission_io.State, context: []const u8, green: usize, auditor_model: ?[]const u8) !bool {
    if (!state.continuous_improvement) return false;
    if (state.auditor_text.len == 0) {
        const report = callRole(gpa, io, env, root, "auditor",
            "[MISSION AUDITOR] Read the workspace. Emit FINDING: impact=high|medium|low risk=low|medium|high files=a.zig,b.zig description. Write NO FINDINGS if nothing valuable.", context, auditor_model) orelse "NO FINDINGS";
        state.auditor_text = try gpa.dupe(u8, report);
        try mission_io.saveState(gpa, io, root, state.*);
        try mission_io.appendJournal(gpa, io, root, "improvement audit dispatched");
        return true;
    }

    const findings = mission.improve.parseFindings(gpa, state.auditor_text) catch &.{};
    const action = mission.improve.decide(.{
        .findings = findings,
        .min_impact = state.min_impact,
        .improve_cycles = state.improve_cycles,
        .max_cycles = state.max_improve_cycles,
        .clean_rounds = state.clean_audit_rounds,
        .max_clean_rounds = state.max_clean_audit_rounds,
        .stop_file = mission_io.stopRequested(gpa, io, root),
        .out_of_budget = state.budget_usd > 0 and state.cost_usd >= state.budget_usd,
    });

    switch (action) {
        .stop => |reason| {
            const note = try std.fmt.allocPrint(gpa, "continuous improvement stopping: {s}", .{reason});
            defer gpa.free(note);
            try mission_io.appendJournal(gpa, io, root, note);
            state.continuous_improvement = false;
            try mission_io.saveState(gpa, io, root, state.*);
            return false;
        },
        .audit => {
            state.clean_audit_rounds += 1;
            state.auditor_text = "";
            try mission_io.saveState(gpa, io, root, state.*);
            const note = try std.fmt.allocPrint(gpa, "audit without valuable findings ({d}/{d})", .{ state.clean_audit_rounds, state.max_clean_audit_rounds });
            defer gpa.free(note);
            try mission_io.appendJournal(gpa, io, root, note);
            return true;
        },
        .implement => |finding| {
            const tasks = try mission_io.loadTasks(gpa, io, root);
            const id: u32 = @intCast(tasks.len + 1);
            var files = std.ArrayList([]const u8).empty;
            try files.appendSlice(gpa, finding.files);
            const task = mission.Task{
                .id = id,
                .subject = finding.text[0..@min(finding.text.len, 120)],
                .files = try files.toOwnedSlice(gpa),
                .verify = "",
            };
            var next_tasks = std.ArrayList(mission.Task).empty;
            try next_tasks.appendSlice(gpa, tasks);
            try next_tasks.append(gpa, task);
            try mission_io.saveTasks(gpa, io, root, next_tasks.items);

            var leases = std.ArrayList(mission.lease.Lease).empty;
            try leases.appendSlice(gpa, state.leases);
            try leases.append(gpa, .{ .id = id, .subject = task.subject, .verify = "" });
            state.leases = try leases.toOwnedSlice(gpa);
            state.improve_cycles += 1;
            state.clean_audit_rounds = 0;
            state.auditor_text = "";
            state.stage = "implement";
            gpa.free(state.improve_revert_sha);
            state.improve_revert_sha = mission_io.gitHead(gpa, io, root) orelse "";
            state.improve_baseline_green = green;
            try mission_io.saveState(gpa, io, root, state.*);

            const line = try std.fmt.allocPrint(gpa, "- [ ] id: imp-{d} | impact: {s} | risk: {s} | files: {any} | {s}\n", .{
                id, finding.impact, finding.risk, finding.files, finding.text[0..@min(finding.text.len, 120)],
            });
            defer gpa.free(line);
            const backlog = try mission_io.readImprovements(gpa, io, root);
            defer gpa.free(backlog);
            try mission_io.writeImprovements(gpa, io, root, try std.fmt.allocPrint(gpa, "{s}{s}", .{ backlog, line }));
            const note = try std.fmt.allocPrint(gpa, "improvement cycle {d}: #{d}", .{ state.improve_cycles, id });
            defer gpa.free(note);
            try mission_io.appendJournal(gpa, io, root, note);
            return true;
        },
    }
}

fn cmdRun(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, root: []const u8) !u8 {
    try mission_io.ensureV2Files(gpa, io, root);
    var state = try mission_io.loadState(gpa, io, root);
    const roadmap = try mission_io.readRoadmap(gpa, io, root);
    defer gpa.free(roadmap);
    const roadmap_items = try mission.chain.parseRoadmap(gpa, roadmap);
    state.chain_total = roadmap_items.len;
    const mission_path = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ root, mission.dir_name, mission.mission_file });
    defer gpa.free(mission_path);
    const mission_text = std.Io.Dir.cwd().readFileAlloc(io, mission_path, gpa, .limited(256 * 1024)) catch "";
    defer if (mission_text.len > 0) gpa.free(mission_text);
    const objective = objectiveFrom(mission_text);
    const project_instructions = try loadProjectInstructions(gpa, io, env, root);
    defer gpa.free(project_instructions);
    const worker_count_raw = envGet(env, "ZODE_MISSION_WORKERS") orelse "1";
    const workers = std.fmt.parseInt(usize, worker_count_raw, 10) catch 1;
    var role_models = RoleModels{ .fast = envGet(env, "ZODE_MISSION_FAST_MODEL") };
    if (envGet(env, "ZODE_MISSION_MODELS_BY_ROLE")) |raw| {
        role_models.overrides = try mission_io.parseRoleModels(gpa, raw);
    }
    defer if (role_models.overrides.len > 0) mission_io.freeRoleModels(gpa, role_models.overrides);
    var models = std.ArrayList([]const u8).empty;
    defer models.deinit(gpa);
    if (envGet(env, "ZODE_MISSION_MODELS")) |raw| {
        var mit = std.mem.tokenizeScalar(u8, raw, ',');
        while (mit.next()) |m| {
            const clean = std.mem.trim(u8, m, " \t");
            if (clean.len > 0) try models.append(gpa, clean);
        }
    }
    var model_index: usize = 0;

    while (state.status == .running) {
        const tasks = try mission_io.loadTasks(gpa, io, root);
        defer gpa.free(tasks);
        var owned_paths = std.ArrayList([]const u8).empty;
        defer owned_paths.deinit(gpa);
        for (tasks) |t| try owned_paths.appendSlice(gpa, t.files);
        const current_hashes = try mission_io.hashTestsFor(gpa, io, root, owned_paths.items);
        defer gpa.free(current_hashes);
        if (state.test_hashes.len == 0) {
            state.test_hashes = try gpa.dupe(mission_io.TestHash, current_hashes);
            try mission_io.saveState(gpa, io, root, state);
        } else {
            if (mission_io.checkTestIntegrity(state.test_hashes, current_hashes)) |eroded| {
                const note = try std.fmt.allocPrint(gpa, "test erosion refused progress: {s}", .{eroded});
                defer gpa.free(note);
                try mission_io.appendJournal(gpa, io, root, note);
                state.status = .aborted;
                try mission_io.saveState(gpa, io, root, state);
                std.debug.print("MISSION STOPPED (test-erosion): {s}\n", .{eroded});
                return 1;
            }
        }

        try distillMemory(gpa, io, root, &state);

        const now_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
        var expired_ids: [64]u32 = undefined;
        const expired_n = mission.lease.expired(state.leases, now_ms, &expired_ids);
        if (expired_n > 0) {
            const mutable_leases = try gpa.dupe(mission.lease.Lease, state.leases);
            state.leases = mutable_leases;
            for (expired_ids[0..expired_n]) |id| {
                _ = mission.lease.fail(mutable_leases, id, "lease expired");
            }
            const current_tasks = try mission_io.loadTasks(gpa, io, root);
            for (current_tasks) |*t| {
                for (expired_ids[0..expired_n]) |id| {
                    if (t.id == id) t.status = .pending;
                }
            }
            try mission_io.saveTasks(gpa, io, root, current_tasks);
            const note = try std.fmt.allocPrint(gpa, "leases expired and reclaimed: {d}", .{expired_n});
            defer gpa.free(note);
            try mission_io.appendJournal(gpa, io, root, note);
        }

        const checks = try mission_io.loadCriteria(gpa, io, root);
        defer gpa.free(checks);
        const results = try mission_io.runChecks(gpa, io, root, checks);
        defer mission_io.freeCheckResults(gpa, results);

        // Harness-confirmed facts: check verdicts and task completion. Stored
        // on disk so they survive compaction and process restarts, then injected
        // into every prompt (lead, workers and roles) through `context`.
        var facts_list = std.ArrayList(mission_io.Fact).empty;
        defer {
            for (facts_list.items) |f| {
                gpa.free(f.subject);
                gpa.free(f.text);
            }
            facts_list.deinit(gpa);
        }
        const stored_facts = try mission_io.loadFacts(gpa, io, root);
        defer mission_io.freeFacts(gpa, stored_facts);
        // Deep copy: appendSlice would share the string pointers and both
        // defers would free them (a real double free on the second turn).
        for (stored_facts) |f| {
            try facts_list.append(gpa, .{
                .kind = f.kind,
                .subject = try gpa.dupe(u8, f.subject),
                .text = try gpa.dupe(u8, f.text),
            });
        }
        for (results) |r| try mission_io.putCheckFact(gpa, &facts_list, r.id, r.ok, r.summary);
        if (mission.allDone(tasks)) _ = try mission_io.putFact(gpa, &facts_list, .task, "tasks", "all tasks completed");
        try mission_io.saveFacts(gpa, io, root, facts_list.items);
        const facts_text = try mission_io.renderFacts(gpa, facts_list.items, 4096);
        defer gpa.free(facts_text);
        const context = try buildContext(gpa, project_instructions, facts_text);
        defer gpa.free(context);

        if (mission.applyTaskResults(tasks, results)) try mission_io.saveTasks(gpa, io, root, tasks);
        const green = mission.countGreen(results);
        const lead_model: ?[]const u8 = if (models.items.len > 0) models.items[model_index] else null;
        try rollbackIfRegressed(gpa, io, root, &state, green);
        const all_done = mission.allDone(tasks);
        state.turn += 1;
        const progress = green > state.best_green or (all_done and state.tasks_done < tasks.len);
        state.best_green = @max(state.best_green, green);
        if (all_done) state.tasks_done = tasks.len;
        state.strategy_tier = mission.nextStrategy(state.strategy_tier, progress);

        var decision = mission.decide(.{
            .status = state.status,
            .stop_file = mission_io.stopRequested(gpa, io, root),
            .turn = state.turn,
            .max_turns = state.max_turns,
            .cost_usd = state.cost_usd,
            .budget_usd = state.budget_usd,
            .failures = state.failures,
            .max_failures = state.max_failures,
            .verdict_blocked = state.verdict_blocked,
            .all_checks_green = mission.allGreen(results),
            .all_tasks_done = all_done,
        });
        const line = try std.fmt.allocPrint(gpa,
            "turn {d}: {d}/{d} checks green, {d}/{d} tasks done → {s}",
            .{ state.turn, green, results.len, state.tasks_done, tasks.len, @tagName(decision) });
        defer gpa.free(line);
        try mission_io.appendJournal(gpa, io, root, line);

        // EXTEND can raise a budget stop, but never a blocked mission.
        if (decision == .stop and mission_io.extendRequested(gpa, io, root) and state.extensions < state.max_extensions) {
            const reason = decision.stop;
            if (reason != .blocked and reason != .review_high) {
                _ = mission_io.consumeExtend(gpa, io, root);
                const budget = mission.chain.applyExtension(.{
                    .max_turns = state.max_turns,
                    .max_wallclock_min = state.max_wallclock_min,
                    .max_writes = state.max_writes,
                });
                state.extensions += 1;
                state.max_turns = budget.max_turns;
                state.max_wallclock_min = budget.max_wallclock_min;
                state.max_writes = budget.max_writes;
                decision = .work;
                const note = try std.fmt.allocPrint(gpa, "budget extended {d}/{d} after {s}", .{ state.extensions, state.max_extensions, @tagName(reason) });
                defer gpa.free(note);
                try mission_io.appendJournal(gpa, io, root, note);
            }
        }

        // Role stages: investigate → implement → verify → review → done.
        // This must also gate an otherwise-green turn: review comes first.
        if (decision == .work or decision == .complete) {
            if (state.strategy_tier >= 2 and state.turn > 4 and green < results.len) {
                const replan_prompt = "OUTPUT ONLY a new JSON mission plan. Change the approach. {\"objective\":\"...\",\"checks\":[{\"id\":\"x\",\"cmd\":\"...\",\"expect\":\"exit0\"}],\"tasks\":[{\"id\":1,\"subject\":\"...\",\"files\":[\"...\"],\"verify\":\"x\"}]}";
                if (callAgentCapture(gpa, io, env, "zode --chat", replan_prompt)) |text| {
                    defer gpa.free(text);
                    if (mission.planFromJson(gpa, text)) |new_plan| {
                        const cj = try jsonChecks(gpa, new_plan.checks);
                        defer gpa.free(cj);
                        const tj = try jsonTasks(gpa, new_plan.tasks);
                        defer gpa.free(tj);
                        try atomicText(gpa, io, root, mission.criteria_file, cj);
                        try atomicText(gpa, io, root, mission.tasks_file, tj);
                        state.strategy_tier = 1;
                        state.best_green = 0;
                        try mission_io.appendJournal(gpa, io, root, "re-plan applied at tier 2; strategy reset");
                    } else |_| {}
                }
            }
            if (std.mem.eql(u8, state.stage, "investigate")) {
                const report = callRole(gpa, io, env, root, "investigator", try std.fmt.allocPrint(gpa, "[MISSION INVESTIGATOR] Objective: {s}\nRead the workspace. Do not edit files.", .{objective}), context, role_models.modelFor("investigator", lead_model));
                if (report) |text| state.research_text = try gpa.dupe(u8, text);
                state.stage = "implement";
                try mission_io.saveState(gpa, io, root, state);
                try mission_io.appendJournal(gpa, io, root, "investigator finished; implementers may now write");
                continue;
            }
            const stage_info = mission.roles.stageFor(
                std.meta.stringToEnum(mission.roles.Stage, state.stage) orelse .implement,
                all_done,
                mission.roles.parseReview(state.review_text),
                state.review_attempts,
            );
            if (stage_info.stage == .review and state.review_text.len == 0) {
                // Two independent reviewers: a single high finding used to
                // reopen work on a false positive. Both reports gate the stage.
                _ = callRole(gpa, io, env, root, "reviewer", try std.fmt.allocPrint(gpa, "[MISSION REVIEWER] Objective: {s}\nReview files and write SEVERITY findings. Do not edit files.", .{objective}), context, role_models.modelFor("reviewer", lead_model));
                _ = callRole(gpa, io, env, root, "reviewer2", try std.fmt.allocPrint(gpa, "[MISSION SECOND REVIEWER] Objective: {s}\nReview the SAME work independently for correctness, regressions and unfinished criteria. Ignore any other review. Write SEVERITY findings. Do not edit files.", .{objective}), context, role_models.modelFor("reviewer2", lead_model));
                const first_review = readReport(gpa, io, root, "reviewer") orelse "SEVERITY: low — no review report produced";
                defer gpa.free(first_review);
                const second_review = readReport(gpa, io, root, "reviewer2") orelse "";
                defer gpa.free(second_review);
                state.review_text = try std.fmt.allocPrint(gpa, "{s}\n[SECOND OPINION]\n{s}", .{ first_review, second_review });
                _ = try mission_io.putFact(gpa, &facts_list, .review, "stage", first_review[0..@min(first_review.len, 240)]);
                try mission_io.saveFacts(gpa, io, root, facts_list.items);
                state.stage = "review";
                try mission_io.saveState(gpa, io, root, state);
                try mission_io.appendJournal(gpa, io, root, "reviewer dispatched; completion held until review is clean");
                continue;
            }
            if (stage_info.decision == .retry) {
                state.review_attempts += 1;
                state.stage = "implement";
                state.review_text = "";
                const current = try mission_io.loadTasks(gpa, io, root);
                for (current) |*t| t.status = .pending;
                try mission_io.saveTasks(gpa, io, root, current);
                const rework_leases = try gpa.dupe(mission.lease.Lease, state.leases);
                for (rework_leases) |*l| {
                    l.status = .pending;
                    l.owner = "";
                    l.lease_until = 0;
                    l.attempts = 0;
                }
                state.leases = rework_leases;
                try mission_io.saveState(gpa, io, root, state);
                const note = try std.fmt.allocPrint(gpa, "review requires rework (attempt {d})", .{state.review_attempts});
                defer gpa.free(note);
                try mission_io.appendJournal(gpa, io, root, note);
                continue;
            }
            if (stage_info.decision == .complete) decision = .complete;
            if (stage_info.decision == .blocked) decision = .{ .stop = .review_high };
        }

        switch (decision) {
            .complete => {
                if (try improveCycle(gpa, io, env, root, &state, context, green, role_models.modelFor("auditor", lead_model))) continue;
                const chained = try chainNext(gpa, io, env, root, &state);
                state.status = if (chained) .running else .complete;
                try mission_io.saveState(gpa, io, root, state);
                if (!chained) {
                    std.debug.print("MISSION COMPLETE: {s}\n", .{root});
                    return 0;
                }
                std.debug.print("MISSION COMPLETE — chaining next roadmap item\n", .{});
                continue;
            },
            .stop => |reason| {
                state.status = if (reason == .blocked) .blocked else .aborted;
                try mission_io.saveState(gpa, io, root, state);
                std.debug.print("MISSION STOPPED ({s}): {s}\n", .{ reason.name(), root });
                return 1;
            },
            .work => {},
        }

        const commit_msg = try std.fmt.allocPrint(gpa, "mission: turn {d} verified progress", .{state.turn});
        defer gpa.free(commit_msg);
        var commit_paths = std.ArrayList([]const u8).empty;
        defer commit_paths.deinit(gpa);
        for (tasks) |t| try commit_paths.appendSlice(gpa, t.files);
        if (try mission_io.gitCommit(gpa, io, root, commit_msg, commit_paths.items)) {
            std.debug.print("checkpoint committed\n", .{});
        }

        if (workers > 1 and state.strategy_tier <= 2) {
            const waves = try mission.wavesFor(gpa, tasks, workers);
            defer gpa.free(waves);
            if (waves.len > 0) {
                const worker_leases = try gpa.dupe(mission.lease.Lease, state.leases);
                state.leases = worker_leases;
                for (waves) |wave| {
                    for (wave.ids) |id| {
                        _ = mission.lease.claim(worker_leases, id, "worker", now_ms, state.lease_ms);
                    }
                }
                try mission_io.appendJournal(gpa, io, root, "dispatching parallel workers");
                for (waves) |wave| callWorkers(gpa, io, env, root, tasks, wave, role_models.modelFor("worker", lead_model), context);
                const after = try mission_io.runChecks(gpa, io, root, checks);
                defer mission_io.freeCheckResults(gpa, after);
                if (mission.allGreen(after)) {
                    for (worker_leases) |*l| {
                        if (l.status == .in_progress) _ = mission.lease.release(worker_leases, l.id, .completed);
                    }
                } else {
                    for (worker_leases) |*l| {
                        if (l.status == .in_progress) _ = mission.lease.fail(worker_leases, l.id, "worker checks still red");
                    }
                }
            }
        }

        var prompt = std.ArrayList(u8).empty;
        defer prompt.deinit(gpa);
        prompt.appendSlice(gpa, context) catch return 1;
        const header = std.fmt.allocPrint(gpa, "[MISSION SUPERVISOR · turn {d}/{d}] Harness re-ran the criteria: {d}/{d} green. Failing: ", .{
            state.turn, state.max_turns, green, results.len,
        }) catch return 1;
        defer gpa.free(header);
        prompt.appendSlice(gpa, header) catch return 1;
        for (results) |r| {
            if (!r.ok) {
                const piece = std.fmt.allocPrint(gpa, "{s} ({s}); ", .{ r.id, r.summary }) catch return 1;
                defer gpa.free(piece);
                prompt.appendSlice(gpa, piece) catch return 1;
            }
        }
        if (state.strategy_tier >= 2) prompt.appendSlice(gpa, "Strategy tier 2: change the approach, do not repeat the same edit. ") catch return 1;
        prompt.appendSlice(gpa, "Keep working until every check is green. Do not declare done; the harness decides completion.") catch return 1;
        const ok = callAgent(gpa, io, env, root, prompt.items, envGet(env, "ZODE_MISSION_AGENT") orelse "zode --chat", lead_model);
        if (ok) {
            state.failures = 0;
            state.writes += 1;
            state.last_prompt_at = std.Io.Timestamp.now(io, .real).toMilliseconds();
        } else {
            state.failures += 1;
            const note = try std.fmt.allocPrint(gpa, "agent turn failed ({d}/{d})", .{ state.failures, state.max_failures });
            defer gpa.free(note);
            try mission_io.appendJournal(gpa, io, root, note);
            if (state.failures >= state.max_failures) {
                state.status = .aborted;
                try mission_io.saveState(gpa, io, root, state);
                std.debug.print("MISSION STOPPED (repeated-execution-failure): {s}\n", .{root});
                return 1;
            }
            if (models.items.len > 0) {
                model_index = (model_index + 1) % models.items.len;
                const rotated = try std.fmt.allocPrint(gpa, "model rotated to {s}", .{models.items[model_index]});
                defer gpa.free(rotated);
                try mission_io.appendJournal(gpa, io, root, rotated);
            }
            const backoff_ms = @min(@as(u64, 2000) << @intCast(@min(state.failures - 1, 4)), 30_000);
            nap(backoff_ms);
            try mission_io.appendJournal(gpa, io, root, "retrying after backoff");
        }
        try mission_io.saveState(gpa, io, root, state);
    }
    try mission_io.saveState(gpa, io, root, state);
    return 0;
}

pub fn run(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, argv: []const []const u8) !u8 {
    if (argv.len == 0) {
        usage();
        return 2;
    }
    const command = argv[0];
    const rest = argv[1..];
    if (std.mem.eql(u8, command, "plan")) {
        var objective = std.ArrayList(u8).empty;
        defer objective.deinit(gpa);
        for (rest) |part| {
            if (objective.items.len > 0) try objective.append(gpa, ' ');
            try objective.appendSlice(gpa, part);
        }
        return cmdPlan(gpa, io, env, objective.items);
    } else if (std.mem.eql(u8, command, "status")) {
        const root = if (rest.len > 0) rest[0] else ".";
        return printStatus(gpa, io, root);
    } else if (std.mem.eql(u8, command, "check")) {
        const root = if (rest.len > 0) rest[0] else ".";
        return cmdCheck(gpa, io, root);
    } else if (std.mem.eql(u8, command, "run")) {
        const root = if (rest.len > 0) rest[0] else ".";
        return cmdRun(gpa, io, env, root);
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help")) {
        usage();
        return 0;
    }
    usage();
    return 2;
}
