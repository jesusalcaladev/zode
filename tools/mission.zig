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

fn cmdPlan(gpa: std.mem.Allocator, io: std.Io, objective: []const u8) !u8 {
    if (objective.len < 3) {
        std.debug.print("an objective of at least 3 characters is required\n", .{});
        return 2;
    }
    const slug = try slugify(gpa, objective);
    defer gpa.free(slug);
    const secs = std.Io.Timestamp.now(io, .real).toSeconds();
    const root = try std.fmt.allocPrint(gpa, "./missions/{s}-{d}", .{ slug, @as(u64, @intCast(@max(0, secs))) });
    defer gpa.free(root);
    const plan = try mission.planFromObjective(gpa, objective);
    try mission_io.writePlanFiles(gpa, io, root, plan);
    std.debug.print("mission created: {s}\n  checks: {d}\n  tasks: {d}\nnext: zode-mission run {s}\n", .{
        root, plan.checks.len, plan.tasks.len, root,
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

fn callAgent(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, root: []const u8, prompt: []const u8) void {
    const command = envGet(env, "ZODE_MISSION_AGENT") orelse "zode --chat";
    const argv = agentArgv(gpa, command, prompt) catch return;
    defer gpa.free(argv);
    const result = std.process.run(gpa, io, .{
        .argv = argv,
        .cwd = .{ .path = root },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch {
        std.debug.print("agent command failed: {s}\n", .{command});
        return;
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.stdout.len > 0) std.debug.print("{s}", .{result.stdout});
    if (result.stderr.len > 0) std.debug.print("{s}", .{result.stderr});
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

fn callWorkers(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, root: []const u8, tasks: []const mission.Task, wave: mission.Wave) void {
    const paths = writeWorkerPrompts(gpa, io, root, tasks, wave) catch return;
    defer gpa.free(paths);
    const command = envGet(env, "ZODE_MISSION_AGENT") orelse "zode --chat";
    var script = std.ArrayList(u8).empty;
    defer script.deinit(gpa);
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

    while (state.status == .running) {
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
                for (waves) |wave| callWorkers(gpa, io, env, root, tasks, wave);
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
        try mission_io.saveState(gpa, io, root, state);
        callAgent(gpa, io, env, root, prompt.items);
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
        code = try cmdPlan(gpa, io, objective.items);
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
