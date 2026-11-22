//! Headless mission runner — the executable half of the zode port.
//!
//!   zode-mission plan "<objective>"       create .mission/ with executable checks
//!   zode-mission status <workspace>       show state, checks and next task
//!   zode-mission check <workspace>        run the checks and write evidence
//!   zode-mission run <workspace>          supervise until complete or stopped
//!
//! The agent command comes from ZODE_MISSION_AGENT (default: `zode --chat`).
//! ZODE_MISSION_WORKERS (default 1) enables parallel worker prompts in waves.
//! Same on-disk contract as the OpenCode plugin: `docs/missions-zode.md`.

const std = @import("std");
const mission = @import("mission");
const mission_io = @import("mission_io");

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
        \\usage: zode-mission <command> [args]
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
    std.debug.print("mission created: {s} (plan: {s})\n  checks: {d}\n  tasks: {d}\nnext: zode-mission run {s}\n", .{
        root, source, plan.checks.len, plan.tasks.len, root,
    });
    return 0;
}

fn printStatus(gpa: std.mem.Allocator, io: std.Io, root: []const u8) !u8 {
    const state = try mission_io.loadState(gpa, io, root);
    const tasks = try mission_io.loadTasks(gpa, io, root);
    const results = try mission_io.loadCriteria(gpa, io, root);
    const green = state.best_green;
    std.debug.print(
        "Mission: {s}\nStatus: {s} · turn {d}/{d} · failures {d}/{d}\nChecks: {d} green · tasks: {d}/{d} done\nStrategy tier: {d}\n",
        .{ root, state.status.name(), state.turn, state.max_turns, state.failures, state.max_failures, green, state.tasks_done, tasks.len, state.strategy_tier },
    );
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
    defer gpa.free(results);
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

fn callAgent(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, root: []const u8, prompt: []const u8, model: ?[]const u8) bool {
    const command = envGet(env, "ZODE_MISSION_AGENT") orelse "zode --chat";
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

fn writeWorkerPrompts(gpa: std.mem.Allocator, io: std.Io, root: []const u8, tasks: []const mission.Task, wave: mission.Wave) ![]const []const u8 {
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
                "[MISSION WORKER] Workspace: {s}\nTask #{d}: {s}\nDo only this task. Use zode's write/edit tools. Do not run the global checks; the lead verifies them. When finished, create a note with mission_task_done in your final answer.\n",
                .{ root, task.id, task.subject });
            try dir.writeFile(io, .{ .sub_path = path, .data = text });
            try prompts.append(gpa, path);
            break;
        }
    }
    return prompts.toOwnedSlice(gpa);
}

fn callWorkers(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, root: []const u8, tasks: []const mission.Task, wave: mission.Wave, model: ?[]const u8) void {
    const paths = writeWorkerPrompts(gpa, io, root, tasks, wave) catch return;
    defer gpa.free(paths);
    const command = envGet(env, "ZODE_MISSION_AGENT") orelse "zode --chat";
    var script = std.ArrayList(u8).empty;
    defer script.deinit(gpa);
    if (model) |m| {
        const prefix = std.fmt.allocPrint(gpa, "export ZODE_MODEL='{s}'; ", .{m}) catch return;
        defer gpa.free(prefix);
        script.appendSlice(gpa, prefix) catch return;
    }
    script.appendSlice(gpa, "for p in") catch return;
    for (paths) |p| {
        const piece = std.fmt.allocPrint(gpa, " '{s}'", .{p}) catch return;
        defer gpa.free(piece);
        script.appendSlice(gpa, piece) catch return;
    }
    const tail = std.fmt.allocPrint(gpa, "; do ({s} \"$(cat \"$p\")\" >/dev/null 2>&1) & done; wait\n", .{command}) catch return;
    defer gpa.free(tail);
    script.appendSlice(gpa, tail) catch return;
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "/bin/sh", "-c", script.items },
        .cwd = .{ .path = root },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    }) catch return;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
}

fn cmdRun(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, root: []const u8) !u8 {
    var state = try mission_io.loadState(gpa, io, root);
    const worker_count_raw = envGet(env, "ZODE_MISSION_WORKERS") orelse "1";
    const workers = std.fmt.parseInt(usize, worker_count_raw, 10) catch 1;
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
        const current_hashes = try mission_io.hashTests(gpa, io, root);
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

        const checks = try mission_io.loadCriteria(gpa, io, root);
        defer gpa.free(checks);
        const tasks = try mission_io.loadTasks(gpa, io, root);
        defer gpa.free(tasks);
        const results = try mission_io.runChecks(gpa, io, root, checks);
        defer gpa.free(results);

        if (mission.applyTaskResults(tasks, results)) try mission_io.saveTasks(gpa, io, root, tasks);
        const green = mission.countGreen(results);
        const all_done = mission.allDone(tasks);
        state.turn += 1;
        const progress = green > state.best_green or (all_done and state.tasks_done < tasks.len);
        state.best_green = @max(state.best_green, green);
        if (all_done) state.tasks_done = tasks.len;
        state.strategy_tier = mission.nextStrategy(state.strategy_tier, progress);

        const decision = mission.decide(.{
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

        switch (decision) {
            .complete => {
                state.status = .complete;
                try mission_io.saveState(gpa, io, root, state);
                std.debug.print("MISSION COMPLETE: {s}\n", .{root});
                return 0;
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
        if (try mission_io.gitCommit(gpa, io, root, commit_msg)) {
            std.debug.print("checkpoint committed\n", .{});
        }

        if (workers > 1 and state.strategy_tier <= 2) {
            const waves = try mission.wavesFor(gpa, tasks, workers);
            defer gpa.free(waves);
            if (waves.len > 0) {
                try mission_io.appendJournal(gpa, io, root, "dispatching parallel workers");
                for (waves) |wave| callWorkers(gpa, io, env, root, tasks, wave, if (models.items.len > 0) models.items[model_index] else null);
            }
        }

        var prompt = std.ArrayList(u8).empty;
        defer prompt.deinit(gpa);
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
        const model = if (models.items.len > 0) models.items[model_index] else null;
        const ok = callAgent(gpa, io, env, root, prompt.items, model);
        if (ok) {
            state.failures = 0;
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

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next();
    const command = it.next() orelse {
        usage();
        std.process.exit(2);
    };
    var code: u8 = 0;
    if (std.mem.eql(u8, command, "plan")) {
        var objective = std.ArrayList(u8).empty;
        defer objective.deinit(gpa);
        while (it.next()) |part| {
            if (objective.items.len > 0) try objective.append(gpa, ' ');
            try objective.appendSlice(gpa, part);
        }
        code = try cmdPlan(gpa, io, init.environ_map, objective.items);
    } else if (std.mem.eql(u8, command, "status")) {
        const root = it.next() orelse ". ";
        code = try printStatus(gpa, io, std.mem.trim(u8, root, " "));
    } else if (std.mem.eql(u8, command, "check")) {
        const root = it.next() orelse ".";
        code = try cmdCheck(gpa, io, root);
    } else if (std.mem.eql(u8, command, "run")) {
        const root = it.next() orelse ".";
        code = try cmdRun(gpa, io, init.environ_map, root);
    } else {
        usage();
        code = 2;
    }
    std.process.exit(code);
}
