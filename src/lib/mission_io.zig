//! Mission contract — the IO half.
//!
//! Persistence, criteria execution, journal and git checkpoints. The decisions
//! stay in `lib/mission.zig`; this module only reads/writes and runs commands.
//! All model-facing text is English. No TUI, no network, no provider calls here.

const std = @import("std");
const mission = @import("mission");
const dir = std.Io.Dir.cwd();

// Local copies so this module owns a single file namespace: importing the
// repo's shared helpers here would make the same source file belong to two
// modules when the test binary also imports them.
fn writeString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (c < 0x20) {
            try w.print("\\u{x:0>4}", .{c});
        } else {
            try w.writeByte(c);
        },
    };
    try w.writeByte('"');
}

fn writeAtomic(io: std.Io, path: []const u8, data: []const u8) !void {
    var tmp = try dir.createFileAtomic(io, path, .{ .replace = true });
    defer tmp.deinit(io);
    var buf: [8192]u8 = undefined;
    var fw = tmp.file.writer(io, &buf);
    try fw.interface.writeAll(data);
    try fw.interface.flush();
    try tmp.file.sync(io);
    try tmp.replace(io);
}

pub const TestHash = struct {
    path: []const u8,
    hash: u64,
};

pub const State = struct {
    status: mission.Status = .running,
    turn: usize = 0,
    max_turns: usize = 16,
    failures: usize = 0,
    max_failures: usize = 3,
    cost_usd: f64 = 0,
    budget_usd: f64 = 5,
    best_green: usize = 0,
    tasks_done: usize = 0,
    strategy_tier: u8 = 1,
    verdict_blocked: bool = false,
    last_commit: []const u8 = "",
    test_hashes: []const TestHash = &.{},
};

fn pathFor(gpa: std.mem.Allocator, root: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ root, mission.dir_name, name });
}

fn exists(io: std.Io, path: []const u8) bool {
    _ = dir.statFile(io, path, .{}) catch return false;
    return true;
}

fn fnv1a64(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

fn isTestFile(rel: []const u8) bool {
    const name = std.fs.path.basename(rel);
    if (std.mem.indexOf(u8, name, ".test.") != null or std.mem.indexOf(u8, name, ".spec.") != null) return true;
    if (std.mem.startsWith(u8, name, "test_") and std.mem.endsWith(u8, name, ".py")) return true;
    if (std.mem.indexOf(u8, rel, "/tests/") != null or std.mem.startsWith(u8, rel, "tests/")) {
        return std.mem.endsWith(u8, name, ".zig") or std.mem.endsWith(u8, name, ".py") or std.mem.endsWith(u8, name, ".js") or std.mem.endsWith(u8, name, ".ts");
    }
    return false;
}

fn skipDir(name: []const u8) bool {
    const names = [_][]const u8{ ".git", ".mission", "node_modules", "zig-cache", ".zig-cache", "zig-out", "dist", "build" };
    for (names) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

/// Hash every test file under `root`. Adding a test is fine; editing or
/// deleting an existing one is refused by `checkTestIntegrity`.
pub fn hashTests(gpa: std.mem.Allocator, io: std.Io, root: []const u8) ![]TestHash {
    var out = std.ArrayList(TestHash).empty;
    errdefer out.deinit(gpa);
    var stack = std.ArrayList([]const u8).empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, try gpa.dupe(u8, ""));
    while (stack.items.len > 0) {
        const rel = stack.pop().?;
        const full = if (rel.len == 0) try gpa.dupe(u8, root) else try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, rel });
        defer gpa.free(full);
        var sub = dir.openDir(io, full, .{ .iterate = true }) catch continue;
        defer sub.close(io);
        var it = sub.iterate();
        while (it.next(io) catch null) |entry| {
            const child_rel = if (rel.len == 0)
                try gpa.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel, entry.name });
            if (entry.kind == .directory) {
                if (!skipDir(entry.name)) try stack.append(gpa, child_rel) else gpa.free(child_rel);
                continue;
            }
            if (entry.kind != .file or !isTestFile(child_rel)) {
                gpa.free(child_rel);
                continue;
            }
            const child_full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, child_rel });
            defer gpa.free(child_full);
            const bytes = dir.readFileAlloc(io, child_full, gpa, .limited(16 * 1024 * 1024)) catch {
                gpa.free(child_rel);
                continue;
            };
            defer gpa.free(bytes);
            try out.append(gpa, .{ .path = child_rel, .hash = fnv1a64(bytes) });
        }
    }
    std.mem.sort(TestHash, out.items, {}, struct {
        fn lessThan(_: void, a: TestHash, b: TestHash) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);
    return out.toOwnedSlice(gpa);
}

pub fn checkTestIntegrity(baseline: []const TestHash, current: []const TestHash) ?[]const u8 {
    if (baseline.len == 0) return null;
    for (baseline) |before| {
        var found = false;
        for (current) |now| {
            if (std.mem.eql(u8, before.path, now.path)) {
                found = true;
                if (before.hash != now.hash) return before.path;
                break;
            }
        }
        if (!found) return before.path;
    }
    return null;
}

fn objStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn objInt(obj: std.json.ObjectMap, key: []const u8, fallback: i64) i64 {
    const v = obj.get(key) orelse return fallback;
    return switch (v) {
        .integer => v.integer,
        .float => @intFromFloat(v.float),
        .number_string => std.fmt.parseInt(i64, v.number_string, 10) catch fallback,
        else => fallback,
    };
}

fn objFloat(obj: std.json.ObjectMap, key: []const u8, fallback: f64) f64 {
    const v = obj.get(key) orelse return fallback;
    return switch (v) {
        .float => v.float,
        .integer => @floatFromInt(v.integer),
        .number_string => std.fmt.parseFloat(f64, v.number_string) catch fallback,
        else => fallback,
    };
}

fn objBool(obj: std.json.ObjectMap, key: []const u8, fallback: bool) bool {
    const v = obj.get(key) orelse return fallback;
    return if (v == .bool) v.bool else fallback;
}

fn parseStatus(s: []const u8) mission.Status {
    if (std.mem.eql(u8, s, "complete")) return .complete;
    if (std.mem.eql(u8, s, "blocked")) return .blocked;
    if (std.mem.eql(u8, s, "aborted")) return .aborted;
    return .running;
}

fn writeJson(gpa: std.mem.Allocator, io: std.Io, path: []const u8, comptime fmt: []const u8, args: anytype) !void {
    var buf: [64 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.print(fmt, args);
    try writeAtomic(io,path, w.buffered());
    _ = gpa;
}

pub fn writePlanFiles(gpa: std.mem.Allocator, io: std.Io, root: []const u8, plan: mission.Plan) !void {
    const meta_dir = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, mission.dir_name });
    defer gpa.free(meta_dir);
    try dir.createDirPath(io, meta_dir);
    const evidence = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ meta_dir, mission.evidence_dir });
    defer gpa.free(evidence);
    try dir.createDirPath(io, evidence);

    const mission_path = try pathFor(gpa, root, mission.mission_file);
    defer gpa.free(mission_path);
    if (!exists(io, mission_path)) {
        try writeAtomic(io,mission_path, try std.fmt.allocPrint(gpa,
            "---\nid: mission\nmax_turns: 16\nbudget_usd: 5\n---\n{s}\n", .{plan.objective}));
    }

    const criteria_path = try pathFor(gpa, root, mission.criteria_file);
    defer gpa.free(criteria_path);
    if (!exists(io, criteria_path)) {
        var buf: [64 * 1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try w.writeAll("{\"version\":1,\"checks\":[");
        for (plan.checks, 0..) |c, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"id\":");
            try writeString(&w, c.id);
            try w.writeAll(",\"cmd\":");
            try writeString(&w, c.cmd);
            try w.writeAll(",\"expect\":");
            try writeString(&w, c.expect);
            try w.print(",\"timeout_ms\":{d}}}", .{c.timeout_ms});
        }
        try w.writeAll("]}");
        try writeAtomic(io,criteria_path, w.buffered());
    }

    const tasks_path = try pathFor(gpa, root, mission.tasks_file);
    defer gpa.free(tasks_path);
    if (!exists(io, tasks_path)) {
        var buf: [64 * 1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try w.writeAll("{\"version\":1,\"tasks\":[");
        for (plan.tasks, 0..) |t, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("{{\"id\":{d},\"subject\":", .{t.id});
            try writeString(&w, t.subject);
            try w.writeAll(",\"files\":[");
            for (t.files, 0..) |f, j| {
                if (j > 0) try w.writeByte(',');
                try writeString(&w, f);
            }
            try w.writeAll("],\"verify\":");
            try writeString(&w, t.verify);
            try w.writeAll(",\"blocked_by\":[");
            for (t.blocked_by, 0..) |dep, j| {
                if (j > 0) try w.writeByte(',');
                try w.print("{d}", .{dep});
            }
            try w.writeAll("],\"status\":\"pending\"}");
        }
        try w.writeAll("]}");
        try writeAtomic(io,tasks_path, w.buffered());
    }

    const state_path = try pathFor(gpa, root, mission.state_file);
    defer gpa.free(state_path);
    if (!exists(io, state_path)) try saveState(gpa, io, root, .{});

    const journal_path = try pathFor(gpa, root, mission.journal_file);
    defer gpa.free(journal_path);
    if (!exists(io, journal_path)) try writeAtomic(io,journal_path, "# Journal\n\n");
}

pub fn loadCriteria(gpa: std.mem.Allocator, io: std.Io, root: []const u8) ![]mission.Check {
    const path = try pathFor(gpa, root, mission.criteria_file);
    defer gpa.free(path);
    const data = dir.readFileAlloc(io, path, gpa, .limited(1024 * 1024)) catch return &.{};
    defer gpa.free(data);
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, gpa, data, .{}) catch return &.{};
    if (parsed != .object) return &.{};
    const arr_v = parsed.object.get("checks") orelse return &.{};
    if (arr_v != .array) return &.{};
    var out = std.ArrayList(mission.Check).empty;
    errdefer out.deinit(gpa);
    for (arr_v.array.items) |item| {
        if (item != .object) continue;
        const id = objStr(item.object, "id") orelse continue;
        const cmd = objStr(item.object, "cmd") orelse continue;
        if (id.len == 0 or cmd.len == 0) continue;
        try out.append(gpa, .{
            .id = try gpa.dupe(u8, id),
            .cmd = try gpa.dupe(u8, cmd),
            .expect = try gpa.dupe(u8, objStr(item.object, "expect") orelse "exit0"),
            .timeout_ms = @intCast(@max(1000, @min(600000, objInt(item.object, "timeout_ms", 30000)))),
        });
    }
    return out.toOwnedSlice(gpa);
}

pub fn loadTasks(gpa: std.mem.Allocator, io: std.Io, root: []const u8) ![]mission.Task {
    const path = try pathFor(gpa, root, mission.tasks_file);
    defer gpa.free(path);
    const data = dir.readFileAlloc(io, path, gpa, .limited(4 * 1024 * 1024)) catch return &.{};
    defer gpa.free(data);
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, gpa, data, .{}) catch return &.{};
    if (parsed != .object) return &.{};
    const arr_v = parsed.object.get("tasks") orelse return &.{};
    if (arr_v != .array) return &.{};
    var out = std.ArrayList(mission.Task).empty;
    errdefer out.deinit(gpa);
    for (arr_v.array.items) |item| {
        if (item != .object) continue;
        const subject = objStr(item.object, "subject") orelse continue;
        var files = std.ArrayList([]const u8).empty;
        if (item.object.get("files")) |fv| {
            if (fv == .array) {
                for (fv.array.items) |f| {
                    if (f == .string) try files.append(gpa, try gpa.dupe(u8, f.string));
                }
            }
        }
        var deps = std.ArrayList(u32).empty;
        if (item.object.get("blocked_by")) |bv| {
            if (bv == .array) {
                for (bv.array.items) |d| {
                    if (d == .integer and d.integer > 0) try deps.append(gpa, @intCast(d.integer));
                }
            }
        }
        const status_s = objStr(item.object, "status") orelse "pending";
        const status: mission.TaskStatus = if (std.mem.eql(u8, status_s, "completed"))
            .completed
        else if (std.mem.eql(u8, status_s, "in_progress"))
            .in_progress
        else
            .pending;
        try out.append(gpa, .{
            .id = @intCast(@max(1, objInt(item.object, "id", 1))),
            .subject = try gpa.dupe(u8, subject),
            .files = try files.toOwnedSlice(gpa),
            .verify = try gpa.dupe(u8, objStr(item.object, "verify") orelse ""),
            .blocked_by = try deps.toOwnedSlice(gpa),
            .status = status,
        });
    }
    return out.toOwnedSlice(gpa);
}

pub fn saveTasks(gpa: std.mem.Allocator, io: std.Io, root: []const u8, tasks: []const mission.Task) !void {
    const path = try pathFor(gpa, root, mission.tasks_file);
    defer gpa.free(path);
    var buf: [128 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeAll("{\"version\":1,\"tasks\":[");
    for (tasks, 0..) |t, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"id\":{d},\"subject\":", .{t.id});
        try writeString(&w, t.subject);
        try w.writeAll(",\"files\":[");
        for (t.files, 0..) |f, j| {
            if (j > 0) try w.writeByte(',');
            try writeString(&w, f);
        }
        try w.writeAll("],\"verify\":");
        try writeString(&w, t.verify);
        try w.writeAll(",\"blocked_by\":[");
        for (t.blocked_by, 0..) |dep, j| {
            if (j > 0) try w.writeByte(',');
            try w.print("{d}", .{dep});
        }
        try w.print("],\"status\":\"{s}\"}}", .{t.status.name()});
    }
    try w.writeAll("]}");
    try writeAtomic(io,path, w.buffered());
}

pub fn loadState(gpa: std.mem.Allocator, io: std.Io, root: []const u8) !State {
    const path = try pathFor(gpa, root, mission.state_file);
    defer gpa.free(path);
    const data = dir.readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch return .{};
    defer gpa.free(data);
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, gpa, data, .{}) catch return .{};
    if (parsed != .object) return .{};
    const o = parsed.object;
    const status_s = objStr(o, "status") orelse "running";
    const commit = objStr(o, "last_commit") orelse "";
    var hashes = std.ArrayList(TestHash).empty;
    errdefer hashes.deinit(gpa);
    if (o.get("test_hashes")) |hv| {
        if (hv == .array) {
            for (hv.array.items) |item| {
                if (item != .object) continue;
                const p = objStr(item.object, "path") orelse continue;
                const h_s = objStr(item.object, "hash") orelse continue;
                const h = std.fmt.parseInt(u64, h_s, 10) catch continue;
                try hashes.append(gpa, .{ .path = try gpa.dupe(u8, p), .hash = h });
            }
        }
    }
    return .{
        .status = parseStatus(status_s),
        .turn = @intCast(@max(0, objInt(o, "turn", 0))),
        .max_turns = @intCast(@max(1, objInt(o, "max_turns", 16))),
        .failures = @intCast(@max(0, objInt(o, "failures", 0))),
        .max_failures = @intCast(@max(1, objInt(o, "max_failures", 3))),
        .cost_usd = objFloat(o, "cost_usd", 0),
        .budget_usd = objFloat(o, "budget_usd", 5),
        .best_green = @intCast(@max(0, objInt(o, "best_green", 0))),
        .tasks_done = @intCast(@max(0, objInt(o, "tasks_done", 0))),
        .strategy_tier = @intCast(@max(1, @min(3, objInt(o, "strategy_tier", 1)))),
        .verdict_blocked = objBool(o, "verdict_blocked", false),
        .last_commit = try gpa.dupe(u8, commit),
        .test_hashes = try hashes.toOwnedSlice(gpa),
    };
}

pub fn saveState(gpa: std.mem.Allocator, io: std.Io, root: []const u8, state: State) !void {
    const path = try pathFor(gpa, root, mission.state_file);
    defer gpa.free(path);
    var buf: [128 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.print(
        "{{\"version\":1,\"status\":\"{s}\",\"turn\":{d},\"max_turns\":{d},\"failures\":{d},\"max_failures\":{d},\"cost_usd\":{d},\"budget_usd\":{d},\"best_green\":{d},\"tasks_done\":{d},\"strategy_tier\":{d},\"verdict_blocked\":{s},\"last_commit\":",
        .{
            state.status.name(), state.turn, state.max_turns, state.failures, state.max_failures,
            state.cost_usd, state.budget_usd, state.best_green, state.tasks_done, state.strategy_tier,
            if (state.verdict_blocked) "true" else "false",
        },
    );
    try writeString(&w, state.last_commit);
    try w.writeAll(",\"test_hashes\":[");
    for (state.test_hashes, 0..) |h, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"path\":");
        try writeString(&w, h.path);
        try w.print(",\"hash\":\"{d}\"}}", .{h.hash});
    }
    try w.writeAll("]}\n");
    try writeAtomic(io, path, w.buffered());
}

pub fn appendJournal(gpa: std.mem.Allocator, io: std.Io, root: []const u8, line: []const u8) !void {
    const path = try pathFor(gpa, root, mission.journal_file);
    defer gpa.free(path);
    const old = dir.readFileAlloc(io, path, gpa, .limited(1024 * 1024)) catch "";
    defer if (old.len > 0) gpa.free(old);
    const text = try std.fmt.allocPrint(gpa, "{s}{s}\n", .{ old, line });
    defer gpa.free(text);
    try writeAtomic(io,path, text);
}

pub fn stopRequested(gpa: std.mem.Allocator, io: std.Io, root: []const u8) bool {
    const path = pathFor(gpa, root, mission.stop_file) catch return false;
    defer gpa.free(path);
    return exists(io, path);
}

fn exitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| @intCast(@min(code, 255)),
        else => 124,
    };
}

pub fn runChecks(gpa: std.mem.Allocator, io: std.Io, root: []const u8, checks: []const mission.Check) ![]mission.CheckResult {
    var out = std.ArrayList(mission.CheckResult).empty;
    errdefer out.deinit(gpa);
    var evidence_buf: [512]u8 = undefined;
    for (checks) |check| {
        const timeout_ms: i64 = @intCast(@min(check.timeout_ms, 600000));
        const result = std.process.run(gpa, io, .{
            .argv = &.{ "/bin/sh", "-c", check.cmd },
            .cwd = .{ .path = root },
            .stdout_limit = .limited(64 * 1024),
            .stderr_limit = .limited(64 * 1024),
            .timeout = .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } },
        }) catch {
            try out.append(gpa, .{ .id = check.id, .ok = false, .summary = "spawn failed" });
            continue;
        };
        defer gpa.free(result.stderr);
        const code = exitCode(result.term);
        const ok = mission.evaluateExpect(check.expect, code, result.stdout);
        const summary = std.mem.trim(u8, result.stdout, " \t\r\n");
        const evidence_path = std.fmt.bufPrint(&evidence_buf, "{s}/{s}/{s}.txt", .{ root, mission.dir_name, check.id }) catch "";
        if (evidence_path.len > 0) {
            const data = std.fmt.allocPrint(gpa,
                "[check] {s}\n[cmd] {s}\n[exit] {d}\n[expect] {s}\n[ok] {s}\n\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n",
                .{ check.id, check.cmd, code, check.expect, if (ok) "true" else "false", result.stdout, result.stderr }) catch "";
            defer if (data.len > 0) gpa.free(data);
            if (data.len > 0) writeAtomic(io,evidence_path, data) catch {};
        }
        try out.append(gpa, .{
            .id = check.id,
            .ok = ok,
            .summary = try gpa.dupe(u8, if (summary.len > 0) summary[0..@min(summary.len, 200)] else "exit"),
        });
        gpa.free(result.stdout);
    }
    return out.toOwnedSlice(gpa);
}

pub fn gitCommit(gpa: std.mem.Allocator, io: std.Io, root: []const u8, message: []const u8) !bool {
    const add = std.process.run(gpa, io, .{
        .argv = &.{ "git", "add", "-A" },
        .cwd = .{ .path = root },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return false;
    defer gpa.free(add.stdout);
    defer gpa.free(add.stderr);
    if (exitCode(add.term) != 0) return false;

    const commit = std.process.run(gpa, io, .{
        .argv = &.{ "git", "commit", "--no-gpg-sign", "-m", message },
        .cwd = .{ .path = root },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return false;
    defer gpa.free(commit.stdout);
    defer gpa.free(commit.stderr);
    if (exitCode(commit.term) == 0) return true;
    // "nothing to commit" is not a failure: the work was already checkpointed.
    return std.mem.indexOf(u8, commit.stdout, "nothing to commit") != null or
        std.mem.indexOf(u8, commit.stderr, "nothing to commit") != null;
}

fn testRoot(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "/tmp/zode-mission-{s}", .{name});
}

fn cleanRoot(io: std.Io, root: []const u8) void {
    dir.deleteTree(io, root) catch {};
}

test "mission_io: heuristic plan round-trips through criteria and tasks files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try testRoot(a, "plan");
    defer cleanRoot(io, root);

    const plan = try mission.planFromObjective(a, "Create alpha.txt containing alpha");
    try writePlanFiles(a, io, root, plan);

    const checks = try loadCriteria(a, io, root);
    try std.testing.expectEqual(@as(usize, 2), checks.len);
    const tasks = try loadTasks(a, io, root);
    try std.testing.expectEqual(@as(usize, 1), tasks.len);
    try std.testing.expectEqualStrings("alpha.txt", tasks[0].files[0]);
}

test "mission_io: state survives a JSON round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try testRoot(a, "state");
    defer cleanRoot(io, root);
    const meta = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, mission.dir_name });
    try dir.createDirPath(io, meta);

    const hashes = [_]TestHash{.{ .path = "cli.test.js", .hash = 17_192_427_771_940_152_780 }};
    const first = State{ .turn = 4, .status = .blocked, .max_turns = 9, .cost_usd = 1.25, .test_hashes = &hashes };
    try saveState(a, io, root, first);
    const loaded = try loadState(a, io, root);
    try std.testing.expectEqual(@as(usize, 1), loaded.test_hashes.len);
    try std.testing.expectEqual(@as(u64, 17_192_427_771_940_152_780), loaded.test_hashes[0].hash);
    try std.testing.expectEqual(@as(usize, 4), loaded.turn);
    try std.testing.expectEqual(mission.Status.blocked, loaded.status);
    try std.testing.expectEqual(@as(usize, 9), loaded.max_turns);
    try std.testing.expect(@abs(loaded.cost_usd - 1.25) < 0.0001);
}

test "mission_io: STOP is detected from disk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try testRoot(a, "stop");
    defer cleanRoot(io, root);

    const meta = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, mission.dir_name });
    try dir.createDirPath(io, meta);
    try std.testing.expect(!stopRequested(a, io, root));
    const stop_path = try pathFor(a, root, mission.stop_file);
    try writeAtomic(io,stop_path, "");
    try std.testing.expect(stopRequested(a, io, root));
}

test "mission_io: test erosion is detected by hash and count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try testRoot(a, "hash-guard");
    defer cleanRoot(io, root);
    try dir.createDirPath(io, root);

    const file = try std.fmt.allocPrint(a, "{s}/cli.test.js", .{root});
    try dir.writeFile(io, .{ .sub_path = file, .data = "test('a', () => {});\n" });
    const baseline = try hashTests(a, io, root);
    try std.testing.expectEqual(@as(usize, 1), baseline.len);
    try std.testing.expectEqual(@as(?[]const u8, null), checkTestIntegrity(baseline, baseline));

    try dir.writeFile(io, .{ .sub_path = file, .data = "test('a', () => {}); // weakened\n" });
    const changed = try hashTests(a, io, root);
    try std.testing.expect(checkTestIntegrity(baseline, changed) != null);
}

test "mission_io: checks run and write evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try testRoot(a, "checks");
    defer cleanRoot(io, root);

    const meta = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, mission.dir_name });
    try dir.createDirPath(io, meta);
    const checks = [_]mission.Check{
        .{ .id = "pass", .cmd = "printf 1.0.0", .expect = "contains:1.0.0" },
        .{ .id = "fail", .cmd = "exit 1", .expect = "exit0" },
    };
    const results = try runChecks(a, io, root, &checks);
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expect(results[0].ok);
    try std.testing.expect(!results[1].ok);
}
