//! Mission contract — the pure half of the autonomous supervisor port.
//!
//! A mission is a set of executable checks plus a task graph. The model proposes
//! work and verdicts; the HARNESS owns completion. Everything in this file is
//! decided from data only: no filesystem, no model, no TUI, no network. The IO
//! half lives in `io.zig` and the headless driver in `runner.zig`.
//!
//! Same contract as the OpenCode plugin (`opencode-mission`), so a mission
//! directory can move between the two harnesses without a format translation.

const std = @import("std");

pub const io = @import("io.zig");
pub const memory = @import("memory.zig");
pub const roles = @import("roles.zig");
pub const chain = @import("chain.zig");
pub const lease = @import("lease.zig");
pub const improve = @import("improve.zig");

pub const dir_name = ".mission";
pub const mission_file = "mission.md";
pub const criteria_file = "criteria.json";
pub const tasks_file = "tasks.json";
pub const state_file = "state.json";
pub const journal_file = "journal.md";
pub const stop_file = "STOP";
pub const extend_file = "EXTEND";
pub const evidence_dir = "evidence";
pub const checks_cache_file = "checks-cache.json";
pub const charter_file = "charter.md";
pub const memory_file = "memory.md";
pub const summary_file = "summary.md";
pub const progress_file = "progress.json";
pub const roadmap_file = "roadmap.md";
pub const improvements_file = "improvements.md";
pub const reports_dir = "reports";

pub const Status = enum {
    running,
    complete,
    blocked,
    aborted,

    pub fn name(self: Status) []const u8 {
        return switch (self) {
            .running => "running",
            .complete => "complete",
            .blocked => "blocked",
            .aborted => "aborted",
        };
    }
};

pub const TaskStatus = enum {
    pending,
    in_progress,
    completed,

    pub fn name(self: TaskStatus) []const u8 {
        return switch (self) {
            .pending => "pending",
            .in_progress => "in_progress",
            .completed => "completed",
        };
    }
};

pub const StopReason = enum {
    stop_file,
    budget,
    turns,
    deadline,
    blocked,
    failures,
    writes,
    review_high,
    test_erosion,

    pub fn name(self: StopReason) []const u8 {
        return switch (self) {
            .stop_file => "stop-file",
            .budget => "budget",
            .turns => "max-turns",
            .deadline => "deadline",
            .blocked => "blocked",
            .failures => "repeated-execution-failure",
            .writes => "write-ceiling",
            .review_high => "review-high",
            .test_erosion => "test-erosion",
        };
    }
};

pub const Decision = union(enum) {
    work,
    complete,
    stop: StopReason,
};

pub const Check = struct {
    id: []const u8,
    cmd: []const u8,
    expect: []const u8 = "exit0",
    timeout_ms: u32 = 30000,
};

pub const CheckResult = struct {
    id: []const u8,
    ok: bool,
    summary: []const u8 = "",
};

pub const Task = struct {
    id: u32,
    subject: []const u8,
    files: []const []const u8 = &.{},
    verify: []const u8 = "",
    blocked_by: []const u32 = &.{},
    status: TaskStatus = .pending,
};

pub const Plan = struct {
    objective: []const u8,
    checks: []Check,
    tasks: []Task,
};

pub const DecideArgs = struct {
    status: Status,
    stop_file: bool = false,
    turn: usize = 0,
    max_turns: usize = 16,
    cost_usd: f64 = 0,
    budget_usd: f64 = 5,
    deadline_exceeded: bool = false,
    failures: usize = 0,
    max_failures: usize = 3,
    writes: usize = 0,
    max_writes: usize = 0,
    verdict_blocked: bool = false,
    all_checks_green: bool = false,
    all_tasks_done: bool = false,
};

/// THE RULE. Terminal states are decided here, never by the model. The order
/// matters: a kill switch and an explicit blocked verdict are honoured before
/// the "work is done" branch, so a mission can always be stopped.
pub fn decide(args: DecideArgs) Decision {
    if (args.stop_file) return .{ .stop = .stop_file };
    if (args.status != .running) return .{ .stop = .stop_file };
    if (args.deadline_exceeded) return .{ .stop = .deadline };
    if (args.budget_usd > 0 and args.cost_usd >= args.budget_usd) return .{ .stop = .budget };
    if (args.turn >= args.max_turns) return .{ .stop = .turns };
    if (args.max_writes > 0 and args.writes >= args.max_writes) return .{ .stop = .writes };
    if (args.failures >= args.max_failures) return .{ .stop = .failures };
    if (args.verdict_blocked) return .{ .stop = .blocked };
    if (args.all_checks_green and args.all_tasks_done) return .complete;
    return .work;
}

/// `exit0` (the default) or `contains:<text>` (exit 0 AND substring in stdout).
pub fn evaluateExpect(expect: []const u8, exit_code: u8, stdout: []const u8) bool {
    if (std.mem.startsWith(u8, expect, "contains:") and expect.len > 9) {
        return exit_code == 0 and std.mem.indexOf(u8, stdout, expect[9..]) != null;
    }
    return exit_code == 0;
}

pub fn allGreen(results: []const CheckResult) bool {
    if (results.len == 0) return false;
    for (results) |r| if (!r.ok) return false;
    return true;
}

pub fn countGreen(results: []const CheckResult) usize {
    var n: usize = 0;
    for (results) |r| if (r.ok) {
        n += 1;
    };
    return n;
}

pub fn allDone(tasks: []const Task) bool {
    for (tasks) |t| if (t.status != .completed) return false;
    return true;
}

/// A task with a `verify` check becomes completed when that check is green AND
/// every dependency is already completed. Iterate to a fixed point so chains
/// (1 -> 2 -> 3) settle in one pass.
pub fn applyTaskResults(tasks: []Task, results: []const CheckResult) bool {
    var changed = false;
    var pass: usize = 0;
    while (pass <= tasks.len) : (pass += 1) {
        var changed_this_pass = false;
        for (tasks) |*task| {
            if (task.status == .completed) continue;
            if (task.verify.len > 0) {
                var verified = false;
                for (results) |r| {
                    if (std.mem.eql(u8, r.id, task.verify) and r.ok) {
                        verified = true;
                        break;
                    }
                }
                if (!verified) continue;
            }
            var blocked = false;
            for (task.blocked_by) |dep| {
                for (tasks) |other| {
                    if (other.id == dep and other.status != .completed) blocked = true;
                }
            }
            if (blocked) continue;
            task.status = .completed;
            changed = true;
            changed_this_pass = true;
        }
        if (!changed_this_pass) break;
    }
    return changed;
}

pub fn nextStrategy(tier: u8, progress_made: bool) u8 {
    return if (progress_made) @max(1, tier - 1) else @min(3, tier + 1);
}

pub const Wave = struct {
    /// Task ids that can run in this wave.
    ids: []const u32,
};

/// Tasks with disjoint `files` and settled dependencies share a wave. Tasks
/// without declared files get a unique key so they can still run in parallel.
pub fn wavesFor(gpa: std.mem.Allocator, tasks: []const Task, max_workers: usize) ![]Wave {
    var pending = std.ArrayList(Task).empty;
    defer pending.deinit(gpa);
    try pending.appendSlice(gpa, tasks);
    var done = std.ArrayList(u32).empty;
    defer done.deinit(gpa);
    var waves = std.ArrayList(Wave).empty;
    errdefer waves.deinit(gpa);
    var guard: usize = 0;

    while (pending.items.len > 0 and guard <= tasks.len) : (guard += 1) {
        var ids = std.ArrayList(u32).empty;
        errdefer ids.deinit(gpa);
        var used = std.ArrayList([]const u8).empty;
        defer used.deinit(gpa);

        for (pending.items) |task| {
            if (ids.items.len >= max_workers) break;
            if (task.status == .completed) continue;
            var deps_settled = true;
            for (task.blocked_by) |dep| {
                var found = false;
                for (done.items) |id| {
                    if (id == dep) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    deps_settled = false;
                    break;
                }
            }
            if (!deps_settled) continue;

            if (task.files.len == 0) {
                // Unique key: an undeclared task cannot conflict by name.
                const key = try std.fmt.allocPrint(gpa, "__task_{d}", .{task.id});
                try used.append(gpa, key);
            } else {
                var conflict = false;
                for (task.files) |file| {
                    for (used.items) |other| {
                        if (std.mem.eql(u8, file, other)) {
                            conflict = true;
                            break;
                        }
                    }
                    if (conflict) break;
                }
                if (conflict) continue;
                try used.appendSlice(gpa, task.files);
            }
            try ids.append(gpa, task.id);
        }

        if (ids.items.len == 0) break;
        const wave_ids = try ids.toOwnedSlice(gpa);
        try waves.append(gpa, .{ .ids = wave_ids });
        for (wave_ids) |wid| try done.append(gpa, wid);
        var i: usize = 0;
        while (i < pending.items.len) {
            var matched = false;
            for (wave_ids) |wid| {
                if (pending.items[i].id == wid) {
                    matched = true;
                    break;
                }
            }
            if (matched) {
                _ = pending.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }
    return waves.toOwnedSlice(gpa);
}

fn safeId(s: []const u8) bool {
    if (s.len == 0 or s.len > 32) return false;
    if (!(std.ascii.isAlphanumeric(s[0]) or s[0] == '_')) return false;
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    }
    return true;
}

fn unsafeCommand(cmd: []const u8) bool {
    const denied = [_][]const u8{ "sudo ", "rm -rf /", "mkfs", "dd if=", "curl ", "wget " };
    for (denied) |needle| {
        if (std.mem.indexOf(u8, cmd, needle) != null) return true;
    }
    return std.mem.indexOf(u8, cmd, "| sh") != null or std.mem.indexOf(u8, cmd, "| bash") != null;
}

/// Model-authored plan -> validated contract. A rejected plan degrades to the
/// heuristic planner; a bad criterion must never become the definition of done.
pub fn planFromJson(gpa: std.mem.Allocator, data: []const u8) !Plan {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, gpa, data, .{}) catch return error.InvalidPlan;
    if (parsed != .object) return error.InvalidPlan;
    const o = parsed.object;

    const cv = o.get("checks") orelse return error.InvalidPlan;
    if (cv != .array or cv.array.items.len == 0 or cv.array.items.len > 10) return error.InvalidPlan;
    var checks = std.ArrayList(Check).empty;
    errdefer checks.deinit(gpa);
    for (cv.array.items) |item| {
        if (item != .object) continue;
        const id_v = item.object.get("id") orelse continue;
        const cmd_v = item.object.get("cmd") orelse continue;
        if (id_v != .string or cmd_v != .string) continue;
        if (!safeId(id_v.string) or cmd_v.string.len == 0 or cmd_v.string.len > 500) continue;
        if (unsafeCommand(cmd_v.string)) continue;
        var expect: []const u8 = "exit0";
        if (item.object.get("expect")) |ev| {
            if (ev == .string and std.mem.startsWith(u8, ev.string, "contains:") and ev.string.len > 9) expect = ev.string;
        }
        var timeout_ms: u32 = 30000;
        if (item.object.get("timeout_ms")) |tv| {
            if (tv == .integer and tv.integer > 0) timeout_ms = @intCast(@min(600000, @as(i64, @max(1000, tv.integer))));
        }
        try checks.append(gpa, .{
            .id = try gpa.dupe(u8, id_v.string),
            .cmd = try gpa.dupe(u8, cmd_v.string),
            .expect = try gpa.dupe(u8, expect),
            .timeout_ms = timeout_ms,
        });
    }
    if (checks.items.len == 0) return error.InvalidPlan;

    var check_ids = std.ArrayList([]const u8).empty;
    defer check_ids.deinit(gpa);
    for (checks.items) |c| try check_ids.append(gpa, c.id);

    const tv = o.get("tasks") orelse return error.InvalidPlan;
    if (tv != .array or tv.array.items.len == 0 or tv.array.items.len > 12) return error.InvalidPlan;
    var tasks = std.ArrayList(Task).empty;
    errdefer tasks.deinit(gpa);
    for (tv.array.items, 0..) |item, index| {
        if (item != .object) continue;
        const subject_v = item.object.get("subject") orelse continue;
        if (subject_v != .string or subject_v.string.len < 3) continue;
        const id: u32 = @intCast(index + 1);
        var files = std.ArrayList([]const u8).empty;
        if (item.object.get("files")) |fv| {
            if (fv == .array) {
                for (fv.array.items) |f| {
                    if (f != .string) continue;
                    const p = std.mem.trim(u8, f.string, " \t");
                    if (p.len == 0 or p.len > 160 or p[0] == '/' or std.mem.indexOf(u8, p, "..") != null) continue;
                    try files.append(gpa, try gpa.dupe(u8, p));
                }
            }
        }
        var deps = std.ArrayList(u32).empty;
        if (item.object.get("blocked_by")) |bv| {
            if (bv == .array) {
                for (bv.array.items) |d| {
                    if (d == .integer and d.integer > 0 and d.integer <= tv.array.items.len and d.integer != id) {
                        try deps.append(gpa, @intCast(d.integer));
                    }
                }
            }
        }
        var verify: []const u8 = "";
        if (item.object.get("verify")) |vv| {
            if (vv == .string) {
                for (check_ids.items) |cid| {
                    if (std.mem.eql(u8, cid, vv.string)) {
                        verify = try gpa.dupe(u8, vv.string);
                        break;
                    }
                }
            }
        }
        if (verify.len == 0) verify = try gpa.dupe(u8, check_ids.items[check_ids.items.len - 1]);
        try tasks.append(gpa, .{
            .id = id,
            .subject = try gpa.dupe(u8, subject_v.string[0..@min(subject_v.string.len, 160)]),
            .files = try files.toOwnedSlice(gpa),
            .verify = verify,
            .blocked_by = try deps.toOwnedSlice(gpa),
        });
    }
    if (tasks.items.len == 0) return error.InvalidPlan;

    var objective: []const u8 = "Autonomous mission";
    if (o.get("objective")) |ov| {
        if (ov == .string and ov.string.len > 2) objective = ov.string;
    }
    return .{
        .objective = try gpa.dupe(u8, objective),
        .checks = try checks.toOwnedSlice(gpa),
        .tasks = try tasks.toOwnedSlice(gpa),
    };
}

fn isWordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '-' or c == '.';
}

fn copyToken(gpa: std.mem.Allocator, token: []const u8) ![]const u8 {
    return gpa.dupe(u8, std.mem.trim(u8, token, " \t\r\n,.;:\"'`"));
}

/// Heuristic planner used when no model is available. It derives real checks
/// from the objective (named file + named word) instead of a vacuous command.
pub fn planFromObjective(gpa: std.mem.Allocator, objective: []const u8) !Plan {
    var files = std.ArrayList([]const u8).empty;
    errdefer files.deinit(gpa);
    var words = std.ArrayList([]const u8).empty;
    errdefer words.deinit(gpa);

    var it = std.mem.tokenizeAny(u8, objective, " \t\r\n,:;()[]{}\"'`");
    var expect_word = false;
    while (it.next()) |raw| {
        const token = std.mem.trim(u8, raw, " \t\r\n");
        if (token.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(token, "containing") or std.ascii.eqlIgnoreCase(token, "word") or
            std.ascii.eqlIgnoreCase(token, "exactly") or std.ascii.eqlIgnoreCase(token, "with") or
            std.ascii.eqlIgnoreCase(token, "the"))
        {
            expect_word = true;
            continue;
        }
        if (std.mem.indexOfScalar(u8, token, '.') != null and token.len > 3 and isWordChar(token[0])) {
            try files.append(gpa, try copyToken(gpa, token));
            expect_word = false;
        } else if (expect_word and token.len > 1) {
            try words.append(gpa, try copyToken(gpa, token));
            expect_word = false;
        }
        if (files.items.len >= 8) break;
    }

    var checks = std.ArrayList(Check).empty;
    errdefer checks.deinit(gpa);
    var tasks = std.ArrayList(Task).empty;
    errdefer tasks.deinit(gpa);

    if (files.items.len > 0) {
        for (files.items, 0..) |file, i| {
            const id = try std.fmt.allocPrint(gpa, "file{d}", .{i + 1});
            const cmd = try std.fmt.allocPrint(gpa, "test -f '{s}'", .{file});
            try checks.append(gpa, .{ .id = id, .cmd = cmd });
        }
        for (words.items, 0..) |word, i| {
            const file = files.items[@min(i, files.items.len - 1)];
            const id = try std.fmt.allocPrint(gpa, "content{d}", .{i + 1});
            const cmd = try std.fmt.allocPrint(gpa, "grep -q '{s}' '{s}'", .{ word, file });
            try checks.append(gpa, .{ .id = id, .cmd = cmd });
        }
        for (files.items, 0..) |file, i| {
            const one = [_][]const u8{file};
            const verify = if (words.items.len > 0)
                try std.fmt.allocPrint(gpa, "content{d}", .{@min(i, words.items.len - 1) + 1})
            else
                try std.fmt.allocPrint(gpa, "file{d}", .{i + 1});
            const subject = try std.fmt.allocPrint(gpa, "Create {s}", .{file});
            try tasks.append(gpa, .{
                .id = @intCast(i + 1),
                .subject = subject,
                .files = try gpa.dupe([]const u8, &one),
                .verify = verify,
            });
        }
    } else {
        try checks.append(gpa, .{ .id = "progress", .cmd = "test -n \"$(ls -A | grep -v '^\\.mission$')\"" });
        try tasks.append(gpa, .{ .id = 1, .subject = try gpa.dupe(u8, objective), .verify = "progress" });
    }

    return .{
        .objective = try gpa.dupe(u8, objective),
        .checks = try checks.toOwnedSlice(gpa),
        .tasks = try tasks.toOwnedSlice(gpa),
    };
}

test "decide: STOP, blocked and budgets terminate; green work completes" {
    const base = DecideArgs{ .status = .running };
    try std.testing.expectEqual(StopReason.stop_file, decide(.{ .status = .running, .stop_file = true }).stop);
    try std.testing.expectEqual(StopReason.blocked, decide(.{ .status = .running, .verdict_blocked = true }).stop);
    try std.testing.expectEqual(StopReason.budget, decide(.{ .status = .running, .cost_usd = 5 }).stop);
    try std.testing.expectEqual(StopReason.turns, decide(.{ .status = .running, .turn = 16 }).stop);
    try std.testing.expectEqual(StopReason.deadline, decide(.{ .status = .running, .deadline_exceeded = true }).stop);
    try std.testing.expectEqual(StopReason.failures, decide(.{ .status = .running, .failures = 3 }).stop);
    try std.testing.expectEqual(Decision.complete, decide(.{ .status = .running, .all_checks_green = true, .all_tasks_done = true }));
    try std.testing.expectEqual(Decision.work, decide(base));
}

test "evaluateExpect: exit0 and contains" {
    try std.testing.expect(evaluateExpect("exit0", 0, ""));
    try std.testing.expect(!evaluateExpect("exit0", 1, ""));
    try std.testing.expect(evaluateExpect("contains:1.0.0", 0, "v1.0.0\n"));
    try std.testing.expect(!evaluateExpect("contains:1.0.0", 0, "v2.0.0\n"));
    try std.testing.expect(!evaluateExpect("contains:1.0.0", 1, "v1.0.0\n"));
}

test "applyTaskResults settles dependency chains from green checks" {
    const files = [_][]const u8{};
    var tasks = [_]Task{
        .{ .id = 1, .subject = "a", .files = &files, .verify = "a" },
        .{ .id = 2, .subject = "b", .files = &files, .verify = "b", .blocked_by = &.{1} },
        .{ .id = 3, .subject = "c", .files = &files, .verify = "c", .blocked_by = &.{2} },
    };
    const results = [_]CheckResult{
        .{ .id = "a", .ok = true },
        .{ .id = "b", .ok = true },
        .{ .id = "c", .ok = true },
    };
    try std.testing.expect(applyTaskResults(&tasks, &results));
    try std.testing.expectEqual(TaskStatus.completed, tasks[0].status);
    try std.testing.expectEqual(TaskStatus.completed, tasks[1].status);
    try std.testing.expectEqual(TaskStatus.completed, tasks[2].status);
}

test "wavesFor parallelizes disjoint tasks and serializes conflicts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const no_files = [_][]const u8{};
    const a_files = [_][]const u8{"a.js"};
    const b_files = [_][]const u8{"b.js"};
    const tasks = [_]Task{
        .{ .id = 1, .subject = "a", .files = &a_files },
        .{ .id = 2, .subject = "b", .files = &b_files },
        .{ .id = 3, .subject = "c", .files = &a_files },
        .{ .id = 4, .subject = "d", .files = &no_files },
    };
    const waves = try wavesFor(a, &tasks, 2);
    try std.testing.expectEqual(@as(usize, 2), waves.len);
    try std.testing.expectEqual(@as(u32, 1), waves[0].ids[0]);
    try std.testing.expectEqual(@as(u32, 2), waves[0].ids[1]);
    try std.testing.expectEqual(@as(u32, 3), waves[1].ids[0]);
    try std.testing.expectEqual(@as(u32, 4), waves[1].ids[1]);
}

test "planFromObjective derives real file and content checks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plan = try planFromObjective(a, "Create alpha.txt containing alpha and beta.txt containing beta");
    try std.testing.expectEqual(@as(usize, 2), plan.tasks.len);
    try std.testing.expect(std.mem.indexOf(u8, plan.checks[0].cmd, "alpha.txt") != null);
    var found_beta = false;
    for (plan.checks) |c| {
        if (std.mem.indexOf(u8, c.cmd, "beta.txt") != null) found_beta = true;
    }
    try std.testing.expect(found_beta);
}

test "planFromJson validates model plans and rejects unsafe checks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good =
        \\{"objective":"Build a CLI","checks":[{"id":"tests","cmd":"node --test","expect":"exit0"}],"tasks":[{"id":1,"subject":"Write tests","files":["cli.test.js"],"verify":"tests","blocked_by":[]}]}
    ;
    const plan = try planFromJson(a, good);
    try std.testing.expectEqual(@as(usize, 1), plan.checks.len);
    try std.testing.expectEqual(@as(usize, 1), plan.tasks.len);
    try std.testing.expectEqualStrings("tests", plan.tasks[0].verify);

    const bad =
        \\{"checks":[{"id":"x","cmd":"sudo rm -rf /","expect":"exit0"}],"tasks":[{"id":1,"subject":"do it","verify":"x"}]}
    ;
    try std.testing.expectError(error.InvalidPlan, planFromJson(a, bad));
}

test "nextStrategy escalates only without verified progress" {
    try std.testing.expectEqual(@as(u8, 2), nextStrategy(1, false));
    try std.testing.expectEqual(@as(u8, 3), nextStrategy(3, false));
    try std.testing.expectEqual(@as(u8, 2), nextStrategy(3, true));
}
