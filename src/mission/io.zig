//! Mission contract — the IO half.
//!
//! Persistence, criteria execution, journal and git checkpoints. The decisions
//! stay in `contract.zig`; this module only reads/writes and runs commands.
//! All model-facing text is English. No TUI, no network, no provider calls here.

const std = @import("std");
const mission = @import("contract.zig");
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
    stage: []const u8 = "investigate",
    review_attempts: usize = 0,
    extensions: usize = 0,
    max_extensions: usize = 3,
    chain_index: usize = 0,
    chain_total: usize = 0,
    lease_ms: i64 = 300_000,
    writes: usize = 0,
    max_writes: usize = 0,
    max_wallclock_min: usize = 0,
    last_prompt_at: i64 = 0,
    model_rotation_index: usize = 0,
    review_text: []const u8 = "",
    research_text: []const u8 = "",
    leases: []const mission.lease.Lease = &.{},
    continuous_improvement: bool = true,
    improve_cycles: usize = 0,
    max_improve_cycles: usize = 5,
    min_impact: []const u8 = "medium",
    clean_audit_rounds: usize = 0,
    max_clean_audit_rounds: usize = 2,
    auditor_text: []const u8 = "",
    /// Checkpoint SHA captured before an improvement cycle. Empty when none.
    improve_revert_sha: []const u8 = "",
    /// Green count at that checkpoint; a lower count triggers the revert.
    improve_baseline_green: usize = 0,
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

/// Bounded parallelism for criteria: enough to overlap a few suites without
/// turning a mission into a fork bomb on a small machine.
pub const max_parallel_checks: usize = 3;

fn fnvUpdate(h: u64, bytes: []const u8) u64 {
    var out = h;
    for (bytes) |b| {
        out ^= b;
        out *%= 0x100000001b3;
    }
    return out;
}

const FsStamp = struct {
    path: []const u8,
    size: u64,
    mtime_ns: i96,
};

/// Fingerprint of the workspace (path + size + mtime) plus the criteria
/// signature. A check is a black box — it may read any file in the workspace —
/// so ANY workspace change invalidates the whole suite. `.mission` is skipped:
/// evidence and the cache itself must not invalidate the cache.
fn workspaceFingerprint(gpa: std.mem.Allocator, io: std.Io, root: []const u8, checks: []const mission.Check) !u64 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var stamps = std.ArrayList(FsStamp).empty;
    var stack = std.ArrayList([]const u8).empty;
    try stack.append(a, "");
    while (stack.items.len > 0) {
        const rel = stack.pop().?;
        const full = if (rel.len == 0) try a.dupe(u8, root) else try std.fmt.allocPrint(a, "{s}/{s}", .{ root, rel });
        var sub = dir.openDir(io, full, .{ .iterate = true }) catch continue;
        defer sub.close(io);
        var it = sub.iterate();
        while (it.next(io) catch null) |entry| {
            const child_rel = if (rel.len == 0)
                try a.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(a, "{s}/{s}", .{ rel, entry.name });
            if (entry.kind == .directory) {
                if (!skipDir(entry.name)) try stack.append(a, child_rel);
                continue;
            }
            if (entry.kind != .file) continue;
            const child_full = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, child_rel });
            const st = dir.statFile(io, child_full, .{}) catch continue;
            try stamps.append(a, .{ .path = child_rel, .size = st.size, .mtime_ns = st.mtime.nanoseconds });
        }
    }
    std.mem.sort(FsStamp, stamps.items, {}, struct {
        fn lessThan(_: void, x: FsStamp, y: FsStamp) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.lessThan);

    var h = fnvUpdate(0xcbf29ce484222325, "zode-mission-checks-v1");
    for (stamps.items) |s| {
        h = fnvUpdate(h, s.path);
        h = fnvUpdate(h, std.mem.asBytes(&s.size));
        h = fnvUpdate(h, std.mem.asBytes(&s.mtime_ns));
    }
    for (checks) |c| {
        h = fnvUpdate(h, c.id);
        h = fnvUpdate(h, c.cmd);
        h = fnvUpdate(h, c.expect);
        h = fnvUpdate(h, std.mem.asBytes(&c.timeout_ms));
    }
    return h;
}

const CheckCache = struct {
    fingerprint: u64,
    results: []mission.CheckResult,
};

fn freeCachedResults(gpa: std.mem.Allocator, results: []mission.CheckResult) void {
    for (results) |r| {
        if (r.id.len > 0) gpa.free(r.id);
        if (r.summary.len > 0) gpa.free(r.summary);
    }
    gpa.free(results);
}

fn loadCheckCache(gpa: std.mem.Allocator, io: std.Io, root: []const u8) ?CheckCache {
    const path = pathFor(gpa, root, mission.checks_cache_file) catch return null;
    defer gpa.free(path);
    const data = dir.readFileAlloc(io, path, gpa, .limited(1024 * 1024)) catch return null;
    defer gpa.free(data);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), data, .{}) catch return null;
    if (parsed != .object) return null;
    const fp_s = objStr(parsed.object, "fingerprint") orelse return null;
    const fingerprint = std.fmt.parseInt(u64, fp_s, 10) catch return null;
    const arr_v = parsed.object.get("results") orelse return null;
    if (arr_v != .array) return null;
    var out = std.ArrayList(mission.CheckResult).empty;
    errdefer {
        for (out.items) |r| {
            if (r.id.len > 0) gpa.free(r.id);
            if (r.summary.len > 0) gpa.free(r.summary);
        }
        out.deinit(gpa);
    }
    for (arr_v.array.items) |item| {
        if (item != .object) continue;
        const id = objStr(item.object, "id") orelse continue;
        out.append(gpa, .{
            .id = gpa.dupe(u8, id) catch return null,
            .ok = objBool(item.object, "ok", false),
            .summary = gpa.dupe(u8, objStr(item.object, "summary") orelse "") catch return null,
        }) catch return null;
    }
    return .{ .fingerprint = fingerprint, .results = out.toOwnedSlice(gpa) catch return null };
}

fn saveCheckCache(gpa: std.mem.Allocator, io: std.Io, root: []const u8, fingerprint: u64, results: []const mission.CheckResult) void {
    const meta = pathFor(gpa, root, mission.dir_name) catch return;
    defer gpa.free(meta);
    dir.createDirPath(io, meta) catch return;
    const path = pathFor(gpa, root, mission.checks_cache_file) catch return;
    defer gpa.free(path);

    var buf: [256 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("{{\"version\":1,\"fingerprint\":\"{d}\",\"results\":[", .{fingerprint}) catch return;
    for (results, 0..) |r, i| {
        if (i > 0) w.writeByte(',') catch return;
        w.writeAll("{\"id\":") catch return;
        writeString(&w, r.id) catch return;
        w.writeAll(",\"ok\":") catch return;
        w.writeAll(if (r.ok) "true" else "false") catch return;
        w.writeAll(",\"summary\":") catch return;
        writeString(&w, r.summary) catch return;
        w.writeByte('}') catch return;
    }
    w.writeAll("]}\n") catch return;
    writeAtomic(io, path, w.buffered()) catch {};
}

fn cacheMatches(results: []const mission.CheckResult, checks: []const mission.Check) bool {
    if (results.len != checks.len) return false;
    for (results, checks) |r, c| {
        if (!std.mem.eql(u8, r.id, c.id)) return false;
    }
    return true;
}

/// Callers own the result slice AND its strings.
pub fn freeCheckResults(gpa: std.mem.Allocator, results: []mission.CheckResult) void {
    freeCachedResults(gpa, results);
}

// ── Durable facts and project instructions ────────────────────────────────
//
// The plugin's `mission_fact` is structured and survives compaction; zode's
// mission runner kept only distilled prose. These facts are HARNESS-confirmed
// (check verdicts, review outcome, task completion), never model assertions.

pub const FactKind = enum { check, task, review, state };

pub const Fact = struct {
    kind: FactKind,
    subject: []const u8,
    text: []const u8,
};

pub const facts_file = "facts.json";
pub const max_facts: usize = 64;

fn oneLine(gpa: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    for (text) |c| {
        if (c == '\n' or c == '\r' or c == '\t') {
            try out.append(gpa, ' ');
        } else {
            try out.append(gpa, c);
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Adds or replaces a fact by (kind, subject). Evicts the oldest at the cap.
/// Returns true when the store changed.
pub fn putFact(gpa: std.mem.Allocator, facts: *std.ArrayList(Fact), kind: FactKind, subject: []const u8, text: []const u8) !bool {
    const clean_subject = std.mem.trim(u8, subject, " \t\r\n");
    if (clean_subject.len == 0) return false;
    const clean_text = try oneLine(gpa, std.mem.trim(u8, text, " \t\r\n"));
    defer gpa.free(clean_text);
    if (clean_text.len == 0) return false;
    const short_text = clean_text[0..@min(clean_text.len, 240)];
    const short_subject = clean_subject[0..@min(clean_subject.len, 80)];

    for (facts.items) |*f| {
        if (f.kind == kind and std.mem.eql(u8, f.subject, short_subject)) {
            if (std.mem.eql(u8, f.text, short_text)) return false;
            gpa.free(f.text);
            f.text = try gpa.dupe(u8, short_text);
            return true;
        }
    }
    if (facts.items.len >= max_facts) {
        const oldest = facts.orderedRemove(0);
        gpa.free(oldest.subject);
        gpa.free(oldest.text);
    }
    try facts.append(gpa, .{
        .kind = kind,
        .subject = try gpa.dupe(u8, short_subject),
        .text = try gpa.dupe(u8, short_text),
    });
    return true;
}

/// Plain-text progress and cost dashboard for `mission status`. Deterministic
/// and terminal-safe: ASCII only, no colour, no ANSI, no invented numbers.
pub fn renderStatus(gpa: std.mem.Allocator, state: State, task_count: usize, check_count: usize) ![]const u8 {
    const checks_total = @max(check_count, 1);
    const green = @min(state.best_green, checks_total);
    const done = @min(state.tasks_done, @max(task_count, 1));
    const width: usize = 20;
    const check_filled = green * width / checks_total;
    const task_filled = done * width / @max(task_count, 1);
    const budget_pct = if (state.budget_usd > 0) @min(@as(u64, @intFromFloat(state.cost_usd / state.budget_usd * 100)), 100) else 0;

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    const head = try std.fmt.allocPrint(gpa,
        "Status: {s} · turn {d}/{d} · stage {s} · tier {d}\nChecks: [",
        .{ state.status.name(), state.turn, state.max_turns, state.stage, state.strategy_tier });
    defer gpa.free(head);
    try out.appendSlice(gpa, head);
    for (0..width) |i| try out.append(gpa, if (i < check_filled) '=' else '-');
    const mid = try std.fmt.allocPrint(gpa, "] {d}/{d} green\nTasks:  [", .{ green, check_count });
    defer gpa.free(mid);
    try out.appendSlice(gpa, mid);
    for (0..width) |i| try out.append(gpa, if (i < task_filled) '=' else '-');
    const tail = try std.fmt.allocPrint(gpa,
        "] {d}/{d} done\nCost:   ${d:.2} / ${d:.2} ({d}%)\n" ++
            "Improvement: cycle {d}/{d} · clean audits {d}/{d} · failures {d}/{d}\n",
        .{
            done, task_count, state.cost_usd, state.budget_usd, budget_pct,
            state.improve_cycles, state.max_improve_cycles, state.clean_audit_rounds,
            state.max_clean_audit_rounds, state.failures, state.max_failures,
        });
    defer gpa.free(tail);
    try out.appendSlice(gpa, tail);
    return out.toOwnedSlice(gpa);
}

pub fn putCheckFact(gpa: std.mem.Allocator, facts: *std.ArrayList(Fact), id: []const u8, ok: bool, summary: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const subject = try std.fmt.allocPrint(a, "check:{s}", .{id});
    const text = if (ok) "PASS" else try std.fmt.allocPrint(a, "FAIL: {s}", .{summary});
    _ = try putFact(gpa, facts, .check, subject, text);
}

pub fn freeFacts(gpa: std.mem.Allocator, facts: []Fact) void {
    for (facts) |f| {
        gpa.free(f.subject);
        gpa.free(f.text);
    }
    gpa.free(facts);
}

/// Stable, bounded prompt block. Deterministic order: the order facts were
/// recorded, newest last. No fact beyond `budget` bytes is emitted.
pub fn renderFacts(gpa: std.mem.Allocator, facts: []const Fact, budget: usize) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    if (facts.len == 0) return out.toOwnedSlice(gpa);
    try out.appendSlice(gpa, "[MISSION FACTS]\n");
    for (facts) |f| {
        var line_buf: [420]u8 = undefined;
        const line = std.mem.print(&line_buf, "- {s} {s}: {s}\n", .{ @tagName(f.kind), f.subject, f.text }) catch break;
        if (out.items.len + line.len > budget) break;
        try out.appendSlice(gpa, line);
    }
    return out.toOwnedSlice(gpa);
}

pub fn loadFacts(gpa: std.mem.Allocator, io: std.Io, root: []const u8) ![]Fact {
    const path = try pathFor(gpa, root, facts_file);
    defer gpa.free(path);
    const data = dir.readFileAlloc(io, path, gpa, .limited(1024 * 1024)) catch return &.{};
    defer gpa.free(data);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), data, .{}) catch return &.{};
    if (parsed != .object) return &.{};
    const arr_v = parsed.object.get("facts") orelse return &.{};
    if (arr_v != .array) return &.{};
    var out = std.ArrayList(Fact).empty;
    errdefer {
        freeFacts(gpa, out.items);
    }
    for (arr_v.array.items) |item| {
        if (item != .object) continue;
        const kind_s = objStr(item.object, "kind") orelse continue;
        const kind = std.meta.stringToEnum(FactKind, kind_s) orelse continue;
        const subject = objStr(item.object, "subject") orelse continue;
        const text = objStr(item.object, "text") orelse continue;
        try out.append(gpa, .{
            .kind = kind,
            .subject = try gpa.dupe(u8, subject),
            .text = try gpa.dupe(u8, text),
        });
    }
    return out.toOwnedSlice(gpa);
}

pub fn saveFacts(gpa: std.mem.Allocator, io: std.Io, root: []const u8, facts: []const Fact) !void {
    const meta = pathFor(gpa, root, mission.dir_name) catch return;
    defer gpa.free(meta);
    try dir.createDirPath(io, meta);
    const path = pathFor(gpa, root, facts_file) catch return;
    defer gpa.free(path);
    var buf: [64 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeAll("{\"version\":1,\"facts\":[");
    for (facts, 0..) |f, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"kind\":");
        try writeString(&w, @tagName(f.kind));
        try w.writeAll(",\"subject\":");
        try writeString(&w, f.subject);
        try w.writeAll(",\"text\":");
        try writeString(&w, f.text);
        try w.writeByte('}');
    }
    try w.writeAll("]}\n");
    try writeAtomic(io, path, w.buffered());
}

// ── Model per role ─────────────────────────────────────────────────────────
//
// Read-only roles (investigator, reviewer, auditor, tester) can use a cheaper
// model; implementers keep the lead model. `role=model` overrides win.

pub const RoleModel = struct {
    role: []const u8,
    model: []const u8,
};

pub fn parseRoleModels(gpa: std.mem.Allocator, raw: []const u8) ![]RoleModel {
    var out = std.ArrayList(RoleModel).empty;
    errdefer out.deinit(gpa);
    var it = std.mem.tokenizeScalar(u8, raw, ',');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const role = std.mem.trim(u8, pair[0..eq], " \t");
        const model = std.mem.trim(u8, pair[eq + 1 ..], " \t");
        if (role.len == 0 or model.len == 0) continue;
        try out.append(gpa, .{
            .role = try gpa.dupe(u8, role),
            .model = try gpa.dupe(u8, model),
        });
    }
    return out.toOwnedSlice(gpa);
}

pub fn freeRoleModels(gpa: std.mem.Allocator, entries: []RoleModel) void {
    for (entries) |e| {
        gpa.free(e.role);
        gpa.free(e.model);
    }
    gpa.free(entries);
}

/// Explicit overrides are matched case-insensitively; the last one wins.
pub fn roleModelOverride(entries: []const RoleModel, role: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (entries) |e| {
        if (std.ascii.eqlIgnoreCase(e.role, role)) found = e.model;
    }
    return found;
}

pub fn isReadOnlyRole(role: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(role, "implementer") or std.ascii.eqlIgnoreCase(role, "worker")) return false;
    return true;
}

pub const InstructionEntry = struct {
    path: []const u8,
    text: []const u8,
};

/// Joins the project's instruction files into one bounded prompt block.
/// `entries` arrive highest priority first; a truncated file is still shown
/// with its path so the agent knows the rest was omitted.
pub fn composeInstructions(gpa: std.mem.Allocator, entries: []const InstructionEntry, budget: usize) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    if (entries.len == 0) return out.toOwnedSlice(gpa);
    try out.appendSlice(gpa, "[PROJECT INSTRUCTIONS]\n");
    for (entries) |entry| {
        if (out.items.len >= budget) break;
        var head_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
        const head = std.mem.print(&head_buf, "--- {s} ---\n", .{entry.path}) catch break;
        if (out.items.len + head.len >= budget) break;
        try out.appendSlice(gpa, head);
        const room = budget - out.items.len;
        const slice = entry.text[0..@min(entry.text.len, room)];
        try out.appendSlice(gpa, slice);
        if (slice.len < entry.text.len) try out.appendSlice(gpa, "\n[truncated]\n");
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

const CheckJob = struct {
    check: mission.Check,
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    result: mission.CheckResult,

    fn run(self: *CheckJob) void {
        const gpa = self.gpa;
        const timeout_ms: i64 = @intCast(@min(self.check.timeout_ms, 600000));
        const result = std.process.run(gpa, self.io, .{
            .argv = &.{ "/bin/sh", "-c", self.check.cmd },
            .cwd = .{ .path = self.root },
            .stdout_limit = .limited(64 * 1024),
            .stderr_limit = .limited(64 * 1024),
            .timeout = .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } },
        }) catch {
            self.result = .{
                .id = gpa.dupe(u8, self.check.id) catch "",
                .ok = false,
                .summary = gpa.dupe(u8, "spawn failed") catch "",
            };
            return;
        };
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);

        const code = exitCode(result.term);
        const ok = mission.evaluateExpect(self.check.expect, code, result.stdout);
        const summary = std.mem.trim(u8, result.stdout, " \t\r\n");
        const head = summary[0..@min(summary.len, 200)];

        var evidence_buf: [512]u8 = undefined;
        const evidence_path = std.fmt.bufPrint(&evidence_buf, "{s}/{s}/{s}.txt", .{ self.root, mission.dir_name, self.check.id }) catch "";
        if (evidence_path.len > 0) {
            const data = std.fmt.allocPrint(gpa,
                "[check] {s}\n[cmd] {s}\n[exit] {d}\n[expect] {s}\n[ok] {s}\n\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n",
                .{ self.check.id, self.check.cmd, code, self.check.expect, if (ok) "true" else "false", result.stdout, result.stderr }) catch "";
            defer if (data.len > 0) gpa.free(data);
            if (data.len > 0) writeAtomic(self.io, evidence_path, data) catch {};
        }
        self.result = .{
            .id = gpa.dupe(u8, self.check.id) catch "",
            .ok = ok,
            .summary = gpa.dupe(u8, if (head.len > 0) head else "exit") catch "",
        };
    }
};

/// True when `path` is `prefix` itself or lives under it. Both are relative
/// workspace paths; a file prefix matches only that file.
pub fn pathUnder(path: []const u8, prefix: []const u8) bool {
    var p = prefix;
    while (std.mem.startsWith(u8, p, "./")) p = p[2..];
    var path_p = path;
    while (std.mem.startsWith(u8, path_p, "./")) path_p = path_p[2..];
    if (p.len == 0) return true;
    if (std.mem.eql(u8, path_p, p)) return true;
    if (std.mem.endsWith(u8, p, "/")) return std.mem.startsWith(u8, path_p, p);
    return std.mem.startsWith(u8, path_p, p) and path_p.len > p.len and path_p[p.len] == '/';
}

fn ownedBy(path: []const u8, owned: []const []const u8) bool {
    for (owned) |prefix| if (pathUnder(path, prefix)) return true;
    return false;
}

/// Hash every test file under `root`. Adding a test is fine; editing or
/// deleting an existing one is refused by `checkTestIntegrity`.
pub fn hashTests(gpa: std.mem.Allocator, io: std.Io, root: []const u8) ![]TestHash {
    return hashTestsFor(gpa, io, root, &.{});
}

/// Same as `hashTests`, but only for files owned by a task. An empty `owned`
/// set means every test file, which keeps the baseline strict for missions
/// whose tasks do not declare files.
pub fn hashTestsFor(gpa: std.mem.Allocator, io: std.Io, root: []const u8, owned: []const []const u8) ![]TestHash {
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
            if (entry.kind != .file or !isTestFile(child_rel) or (owned.len > 0 and !ownedBy(child_rel, owned))) {
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
    var leases = std.ArrayList(mission.lease.Lease).empty;
    errdefer leases.deinit(gpa);
    if (o.get("leases")) |lv| {
        if (lv == .array) {
            for (lv.array.items) |item| {
                if (item != .object) continue;
                const subject = objStr(item.object, "subject") orelse continue;
                const id_v = objInt(item.object, "id", 0);
                if (id_v <= 0) continue;
                const status_s_l = objStr(item.object, "status") orelse "pending";
                const status_l: mission.lease.Status = if (std.mem.eql(u8, status_s_l, "in_progress")) .in_progress else if (std.mem.eql(u8, status_s_l, "completed")) .completed else if (std.mem.eql(u8, status_s_l, "failed")) .failed else .pending;
                try leases.append(gpa, .{
                    .id = @intCast(id_v),
                    .subject = try gpa.dupe(u8, subject),
                    .status = status_l,
                    .owner = try gpa.dupe(u8, objStr(item.object, "owner") orelse ""),
                    .attempts = @intCast(@max(0, objInt(item.object, "attempts", 0))),
                    .lease_until = objInt(item.object, "lease_until", 0),
                    .last_error = try gpa.dupe(u8, objStr(item.object, "last_error") orelse ""),
                    .verify = try gpa.dupe(u8, objStr(item.object, "verify") orelse ""),
                });
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
        .stage = try gpa.dupe(u8, objStr(o, "stage") orelse "investigate"),
        .review_attempts = @intCast(@max(0, objInt(o, "review_attempts", 0))),
        .extensions = @intCast(@max(0, objInt(o, "extensions", 0))),
        .max_extensions = @intCast(@max(1, objInt(o, "max_extensions", 3))),
        .chain_index = @intCast(@max(0, objInt(o, "chain_index", 0))),
        .chain_total = @intCast(@max(0, objInt(o, "chain_total", 0))),
        .lease_ms = @max(1000, objInt(o, "lease_ms", 300_000)),
        .writes = @intCast(@max(0, objInt(o, "writes", 0))),
        .max_writes = @intCast(@max(0, objInt(o, "max_writes", 0))),
        .max_wallclock_min = @intCast(@max(0, objInt(o, "max_wallclock_min", 0))),
        .last_prompt_at = objInt(o, "last_prompt_at", 0),
        .model_rotation_index = @intCast(@max(0, objInt(o, "model_rotation_index", 0))),
        .review_text = try gpa.dupe(u8, objStr(o, "review_text") orelse ""),
        .research_text = try gpa.dupe(u8, objStr(o, "research_text") orelse ""),
        .leases = try leases.toOwnedSlice(gpa),
        .continuous_improvement = objBool(o, "continuous_improvement", true),
        .improve_cycles = @intCast(@max(0, objInt(o, "improve_cycles", 0))),
        .max_improve_cycles = @intCast(@max(1, objInt(o, "max_improve_cycles", 5))),
        .min_impact = try gpa.dupe(u8, objStr(o, "min_impact") orelse "medium"),
        .clean_audit_rounds = @intCast(@max(0, objInt(o, "clean_audit_rounds", 0))),
        .max_clean_audit_rounds = @intCast(@max(1, objInt(o, "max_clean_audit_rounds", 2))),
        .auditor_text = try gpa.dupe(u8, objStr(o, "auditor_text") orelse ""),
        .improve_revert_sha = try gpa.dupe(u8, objStr(o, "improve_revert_sha") orelse ""),
        .improve_baseline_green = @intCast(@max(0, objInt(o, "improve_baseline_green", 0))),
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
    try w.writeAll("],\"stage\":");
    try writeString(&w, state.stage);
    try w.print(",\"review_attempts\":{d},\"extensions\":{d},\"max_extensions\":{d},\"chain_index\":{d},\"chain_total\":{d},\"lease_ms\":{d},\"writes\":{d},\"max_writes\":{d},\"max_wallclock_min\":{d},\"last_prompt_at\":{d},\"model_rotation_index\":{d},\"review_text\":", .{
        state.review_attempts, state.extensions, state.max_extensions, state.chain_index, state.chain_total,
        state.lease_ms, state.writes, state.max_writes, state.max_wallclock_min, state.last_prompt_at, state.model_rotation_index,
    });
    try writeString(&w, state.review_text);
    try w.writeAll(",\"research_text\":");
    try writeString(&w, state.research_text);
    try w.writeAll(",\"leases\":[");
    for (state.leases, 0..) |l, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"id\":{d},\"subject\":", .{l.id});
        try writeString(&w, l.subject);
        try w.print(",\"status\":\"{s}\",\"owner\":", .{@tagName(l.status)});
        try writeString(&w, l.owner);
        try w.print(",\"attempts\":{d},\"lease_until\":{d},\"last_error\":", .{ l.attempts, l.lease_until });
        try writeString(&w, l.last_error);
        try w.writeAll(",\"verify\":");
        try writeString(&w, l.verify);
        try w.writeByte('}');
    }
    try w.writeAll("],\"continuous_improvement\":");
    try w.writeAll(if (state.continuous_improvement) "true" else "false");
    try w.print(",\"improve_cycles\":{d},\"max_improve_cycles\":{d},\"min_impact\":", .{ state.improve_cycles, state.max_improve_cycles });
    try writeString(&w, state.min_impact);
    try w.print(",\"clean_audit_rounds\":{d},\"max_clean_audit_rounds\":{d},\"auditor_text\":", .{ state.clean_audit_rounds, state.max_clean_audit_rounds });
    try writeString(&w, state.auditor_text);
    try w.writeAll(",\"improve_revert_sha\":");
    try writeString(&w, state.improve_revert_sha);
    try w.print(",\"improve_baseline_green\":{d}", .{state.improve_baseline_green});
    try w.writeAll("}\n");
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

fn readNamed(gpa: std.mem.Allocator, io: std.Io, root: []const u8, name: []const u8) ![]const u8 {
    const path = try pathFor(gpa, root, name);
    defer gpa.free(path);
    return dir.readFileAlloc(io, path, gpa, .limited(4 * 1024 * 1024)) catch gpa.dupe(u8, "");
}

fn writeNamed(gpa: std.mem.Allocator, io: std.Io, root: []const u8, name: []const u8, text: []const u8) !void {
    const path = try pathFor(gpa, root, name);
    defer gpa.free(path);
    try writeAtomic(io, path, text);
}

pub fn readJournal(gpa: std.mem.Allocator, io: std.Io, root: []const u8) ![]const u8 {
    return readNamed(gpa, io, root, mission.journal_file);
}
pub fn readMemory(gpa: std.mem.Allocator, io: std.Io, root: []const u8) ![]const u8 {
    return readNamed(gpa, io, root, mission.memory_file);
}
pub fn writeMemory(gpa: std.mem.Allocator, io: std.Io, root: []const u8, text: []const u8) !void {
    try writeNamed(gpa, io, root, mission.memory_file, text);
}
pub fn readSummary(gpa: std.mem.Allocator, io: std.Io, root: []const u8) ![]const u8 {
    return readNamed(gpa, io, root, mission.summary_file);
}
pub fn writeSummary(gpa: std.mem.Allocator, io: std.Io, root: []const u8, text: []const u8) !void {
    try writeNamed(gpa, io, root, mission.summary_file, text);
}
pub fn readImprovements(gpa: std.mem.Allocator, io: std.Io, root: []const u8) ![]const u8 {
    return readNamed(gpa, io, root, mission.improvements_file);
}
pub fn writeImprovements(gpa: std.mem.Allocator, io: std.Io, root: []const u8, text: []const u8) !void {
    try writeNamed(gpa, io, root, mission.improvements_file, text);
}
pub fn readRoadmap(gpa: std.mem.Allocator, io: std.Io, root: []const u8) ![]const u8 {
    return readNamed(gpa, io, root, mission.roadmap_file);
}
pub fn writeRoadmap(gpa: std.mem.Allocator, io: std.Io, root: []const u8, text: []const u8) !void {
    try writeNamed(gpa, io, root, mission.roadmap_file, text);
}
pub fn extendRequested(gpa: std.mem.Allocator, io: std.Io, root: []const u8) bool {
    const path = pathFor(gpa, root, mission.extend_file) catch return false;
    defer gpa.free(path);
    return exists(io, path);
}
pub fn consumeExtend(gpa: std.mem.Allocator, io: std.Io, root: []const u8) bool {
    const path = pathFor(gpa, root, mission.extend_file) catch return false;
    defer gpa.free(path);
    if (!exists(io, path)) return false;
    dir.deleteFile(io, path) catch return false;
    return true;
}
pub fn ensureV2Files(gpa: std.mem.Allocator, io: std.Io, root: []const u8) !void {
    const meta = pathFor(gpa, root, mission.dir_name) catch return;
    defer gpa.free(meta);
    try dir.createDirPath(io, meta);
    const names = [_][]const u8{ mission.charter_file, mission.memory_file, mission.summary_file, mission.roadmap_file, mission.improvements_file };
    for (names) |name| {
        const path = try pathFor(gpa, root, name);
        defer gpa.free(path);
        if (!exists(io, path)) {
            const text = if (std.mem.eql(u8, name, mission.roadmap_file)) "# Roadmap\n\n" else if (std.mem.eql(u8, name, mission.improvements_file)) "# Improvements\n\n" else if (std.mem.eql(u8, name, mission.charter_file)) "# Charter\n\nCompletion is defined by criteria.json.\n" else "";
            try writeAtomic(io, path, text);
        }
    }
}

fn exitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| @intCast(@min(code, 255)),
        else => 124,
    };
}

/// Runs the criteria in batches of at most `max_parallel_checks`, then caches
/// the verdicts under `.mission/checks-cache.json`. An unchanged workspace and
/// criteria signature reuse the cached verdicts without spawning a shell.
/// `gpa` must be thread-safe (the runner passes `Init.gpa`; tests pass
/// `std.testing.allocator`). Caller owns the slice and its strings: see
/// `freeCheckResults`.
pub fn runChecks(gpa: std.mem.Allocator, io: std.Io, root: []const u8, checks: []const mission.Check) ![]mission.CheckResult {
    if (checks.len == 0) return &.{};
    const fingerprint = try workspaceFingerprint(gpa, io, root, checks);

    if (loadCheckCache(gpa, io, root)) |cache| {
        defer freeCachedResults(gpa, cache.results);
        if (cache.fingerprint == fingerprint and cacheMatches(cache.results, checks)) {
            var hit = try gpa.alloc(mission.CheckResult, cache.results.len);
            var filled: usize = 0;
            errdefer {
                for (hit[0..filled]) |r| {
                    gpa.free(r.id);
                    gpa.free(r.summary);
                }
                gpa.free(hit);
            }
            for (cache.results, 0..) |r, i| {
                const id = try gpa.dupe(u8, r.id);
                errdefer gpa.free(id);
                const summary = try gpa.dupe(u8, r.summary);
                hit[i] = .{ .id = id, .ok = r.ok, .summary = summary };
                filled += 1;
            }
            return hit;
        }
    }

    const jobs = try gpa.alloc(CheckJob, checks.len);
    defer gpa.free(jobs);
    for (checks, jobs) |check, *job| {
        job.* = .{ .check = check, .gpa = gpa, .io = io, .root = root, .result = .{ .id = "", .ok = false } };
    }
    var results_owned = false;
    errdefer if (!results_owned) {
        for (jobs) |job| {
            if (job.result.id.len > 0) gpa.free(job.result.id);
            if (job.result.summary.len > 0) gpa.free(job.result.summary);
        }
    };

    var next: usize = 0;
    while (next < jobs.len) {
        const n = @min(max_parallel_checks, jobs.len - next);
        var threads = @as([max_parallel_checks]?std.Thread, @splat(null));
        for (0..n) |k| {
            const job = &jobs[next + k];
            threads[k] = std.Thread.spawn(.{}, CheckJob.run, .{job}) catch null;
            if (threads[k] == null) CheckJob.run(job);
        }
        for (threads[0..n]) |maybe_thread| {
            if (maybe_thread) |thread| thread.join();
        }
        next += n;
    }

    var out = try gpa.alloc(mission.CheckResult, jobs.len);
    results_owned = true;
    for (jobs, 0..) |job, i| out[i] = job.result;
    saveCheckCache(gpa, io, root, fingerprint, out);
    return out;
}

pub fn gitCommit(gpa: std.mem.Allocator, io: std.Io, root: []const u8, message: []const u8, paths: []const []const u8) !bool {
    // Never `git add -A`: a mission must not commit unrelated user changes.
    if (paths.len == 0) return false;
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "git");
    try argv.append(gpa, "add");
    try argv.append(gpa, "--");
    try argv.appendSlice(gpa, paths);
    const add = std.process.run(gpa, io, .{
        .argv = argv.items,
        .cwd = .{ .path = root },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return false;
    defer gpa.free(add.stdout);
    defer gpa.free(add.stderr);
    if (exitCode(add.term) != 0) return false;

    const commit = std.process.run(gpa, io, .{
        .argv = &.{ "git", "-c", "user.name=zode", "-c", "user.email=zode@local", "commit", "--no-gpg-sign", "-m", message },
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

/// HEAD at this moment, owned by the caller. Null when the workspace is not
/// a git repository or has no commit yet.
pub fn gitHead(gpa: std.mem.Allocator, io: std.Io, root: []const u8) ?[]const u8 {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "git", "rev-parse", "HEAD" },
        .cwd = .{ .path = root },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return null;
    defer gpa.free(result.stderr);
    if (exitCode(result.term) != 0) {
        gpa.free(result.stdout);
        return null;
    }
    const sha = std.mem.trim(u8, result.stdout, " \t\r\n");
    const owned = if (sha.len > 0) gpa.dupe(u8, sha) catch null else null;
    gpa.free(result.stdout);
    return owned;
}

/// Undoes exactly one checkpoint commit. Never touches unrelated work: a
/// failed revert is reported to the journal instead of forcing a reset.
pub fn gitRevert(gpa: std.mem.Allocator, io: std.Io, root: []const u8, sha: []const u8) bool {
    if (sha.len == 0) return false;
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "git", "-c", "user.name=zode", "-c", "user.email=zode@local", "revert", "--no-edit", sha },
        .cwd = .{ .path = root },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return false;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return exitCode(result.term) == 0;
}

fn testRoot(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "/tmp/zode-mission-{s}", .{name});
}

fn cleanRoot(io: std.Io, root: []const u8) void {
    dir.deleteTree(io, root) catch {};
}

fn runGit(gpa: std.mem.Allocator, io: std.Io, root: []const u8, argv: []const []const u8) !void {
    const result = try std.process.run(gpa, io, .{
        .argv = argv,
        .cwd = .{ .path = root },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (exitCode(result.term) != 0) return error.GitFailed;
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
    var first = State{ .turn = 4, .status = .blocked, .max_turns = 9, .cost_usd = 1.25, .test_hashes = &hashes };
    try saveState(a, io, root, first);
    const loaded = try loadState(a, io, root);
    try std.testing.expectEqual(@as(usize, 1), loaded.test_hashes.len);
    try std.testing.expectEqual(@as(u64, 17_192_427_771_940_152_780), loaded.test_hashes[0].hash);
    try std.testing.expectEqual(@as(usize, 4), loaded.turn);
    try std.testing.expectEqual(mission.Status.blocked, loaded.status);
    try std.testing.expectEqual(@as(usize, 9), loaded.max_turns);
    try std.testing.expect(@abs(loaded.cost_usd - 1.25) < 0.0001);

    first.improve_revert_sha = "0123456789abcdef";
    first.improve_baseline_green = 3;
    try saveState(a, io, root, first);
    const reloaded = try loadState(a, io, root);
    try std.testing.expectEqualStrings("0123456789abcdef", reloaded.improve_revert_sha);
    try std.testing.expectEqual(@as(usize, 3), reloaded.improve_baseline_green);
}

test "mission_io: a checkpoint revert undoes an improvement, not the baseline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try testRoot(a, "revert");
    defer cleanRoot(io, root);
    try dir.createDirPath(io, root);
    try runGit(a, io, root, &.{ "git", "init", "-q" });

    const file = try std.fmt.allocPrint(a, "{s}/note.txt", .{root});
    try dir.writeFile(io, .{ .sub_path = file, .data = "baseline\n" });
    try runGit(a, io, root, &.{ "git", "add", "note.txt" });
    try runGit(a, io, root, &.{ "git", "-c", "user.name=zode", "-c", "user.email=zode@local", "commit", "-q", "-m", "base" });
    const baseline = gitHead(a, io, root) orelse return error.NoHead;

    try dir.writeFile(io, .{ .sub_path = file, .data = "improved\n" });
    try std.testing.expect(try gitCommit(a, io, root, "mission: improvement", &.{"note.txt"}));
    const current = gitHead(a, io, root) orelse return error.NoHead;
    try std.testing.expect(!std.mem.eql(u8, baseline, current));
    try std.testing.expect(try gitRevert(a, io, root, current));

    const restored = try dir.readFileAlloc(io, file, a, .limited(1024));
    try std.testing.expectEqualStrings("baseline\n", restored);
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

test "mission_io: pathUnder matches files and directories but not siblings" {
    try std.testing.expect(pathUnder("src/foo.test.zig", "src"));
    try std.testing.expect(pathUnder("src/foo.test.zig", "./src/"));
    try std.testing.expect(pathUnder("src/foo.test.zig", "src/foo.test.zig"));
    try std.testing.expect(!pathUnder("src/other.test.zig", "src/foo.test.zig"));
    try std.testing.expect(!pathUnder("other/foo.test.zig", "src"));
    try std.testing.expect(!pathUnder("srcx/foo.test.zig", "src"));
}

test "mission_io: scoped hashing ignores tests outside task-owned paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try testRoot(a, "scoped-hash");
    defer cleanRoot(io, root);

    const owned = try std.fmt.allocPrint(a, "{s}/src/owned.test.zig", .{root});
    const foreign = try std.fmt.allocPrint(a, "{s}/other/foreign.test.zig", .{root});
    for ([_][]const u8{ owned, foreign }) |path| {
        const slash = std.mem.lastIndexOfScalar(u8, path, '/').?;
        try dir.createDirPath(io, path[0..slash]);
        try dir.writeFile(io, .{ .sub_path = path, .data = "test {}\n" });
    }

    const scoped = try hashTestsFor(a, io, root, &.{"src"});
    defer a.free(scoped);
    try std.testing.expectEqual(@as(usize, 1), scoped.len);
    try std.testing.expectEqualStrings("src/owned.test.zig", scoped[0].path);

    const all = try hashTestsFor(a, io, root, &.{});
    defer a.free(all);
    try std.testing.expectEqual(@as(usize, 2), all.len);
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
    const results = try runChecks(std.testing.allocator, io, root, &checks);
    defer freeCheckResults(std.testing.allocator, results);
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expect(results[0].ok);
    try std.testing.expect(!results[1].ok);
}

fn countLines(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !usize {
    const data = try dir.readFileAlloc(io, path, gpa, .limited(1024 * 1024));
    defer gpa.free(data);
    var n: usize = 0;
    for (data) |c| if (c == '\n') {
        n += 1;
    };
    return n;
}

test "mission_io: checks run in parallel up to the concurrency bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try testRoot(a, "parallel");
    defer cleanRoot(io, root);
    try dir.createDirPath(io, root);
    const meta = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, mission.dir_name });
    try dir.createDirPath(io, meta);

    // Deterministic barrier: every check appends a line, then waits until all
    // three lines exist. A serial runner cannot satisfy it and all checks time
    // out; a parallel runner passes in one tick.
    const marks = "/tmp/zode-mission-parallel-marks";
    defer dir.deleteFile(io, marks) catch {};
    try dir.writeFile(io, .{ .sub_path = marks, .data = "" });
    const barrier = try std.fmt.allocPrint(a,
        "i=0; while [ \"$(wc -l < {s})\" -lt 3 ]; do i=$((i+1)); [ \"$i\" -ge 40 ] && exit 1; sleep 0.05; done",
        .{marks});

    const checks = [_]mission.Check{
        .{ .id = "a", .cmd = try std.fmt.allocPrint(a, "echo a >> {s}; {s}", .{ marks, barrier }), .timeout_ms = 5000 },
        .{ .id = "b", .cmd = try std.fmt.allocPrint(a, "echo b >> {s}; {s}", .{ marks, barrier }), .timeout_ms = 5000 },
        .{ .id = "c", .cmd = try std.fmt.allocPrint(a, "echo c >> {s}; {s}", .{ marks, barrier }), .timeout_ms = 5000 },
    };
    const results = try runChecks(std.testing.allocator, io, root, &checks);
    defer freeCheckResults(std.testing.allocator, results);
    try std.testing.expectEqual(@as(usize, 3), results.len);
    for (results) |r| try std.testing.expect(r.ok);
}

test "mission_io: unchanged checks are cached until the workspace or criteria change" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try testRoot(a, "cache");
    defer cleanRoot(io, root);
    try dir.createDirPath(io, root);
    const meta = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, mission.dir_name });
    try dir.createDirPath(io, meta);

    // The counter lives OUTSIDE the workspace so the checks themselves do not
    // invalidate the fingerprint; it only records how often a shell ran.
    const counter = "/tmp/zode-mission-cache-counter";
    defer dir.deleteFile(io, counter) catch {};
    try dir.writeFile(io, .{ .sub_path = counter, .data = "" });

    var checks = [_]mission.Check{
        .{ .id = "pass", .cmd = try std.fmt.allocPrint(a, "echo x >> {s}", .{counter}) },
        .{ .id = "fail", .cmd = try std.fmt.allocPrint(a, "echo y >> {s}; exit 1", .{counter}) },
    };

    const first = try runChecks(std.testing.allocator, io, root, &checks);
    defer freeCheckResults(std.testing.allocator, first);
    try std.testing.expect(first[0].ok);
    try std.testing.expect(!first[1].ok);
    try std.testing.expectEqual(@as(usize, 2), try countLines(std.testing.allocator, io, counter));

    const cache_path = try pathFor(a, root, mission.checks_cache_file);
    try std.testing.expect(exists(io, cache_path));

    const second = try runChecks(std.testing.allocator, io, root, &checks);
    defer freeCheckResults(std.testing.allocator, second);
    try std.testing.expectEqual(@as(usize, 2), second.len);
    try std.testing.expect(second[0].ok);
    try std.testing.expect(!second[1].ok);
    try std.testing.expectEqual(@as(usize, 2), try countLines(std.testing.allocator, io, counter));

    const source = try std.fmt.allocPrint(a, "{s}/source.txt", .{root});
    try dir.writeFile(io, .{ .sub_path = source, .data = "changed\n" });
    const third = try runChecks(std.testing.allocator, io, root, &checks);
    defer freeCheckResults(std.testing.allocator, third);
    try std.testing.expectEqual(@as(usize, 4), try countLines(std.testing.allocator, io, counter));

    checks[0].cmd = try std.fmt.allocPrint(a, "echo x >> {s}; true", .{counter});
    const fourth = try runChecks(std.testing.allocator, io, root, &checks);
    defer freeCheckResults(std.testing.allocator, fourth);
    try std.testing.expectEqual(@as(usize, 6), try countLines(std.testing.allocator, io, counter));
}

test "mission_io: durable facts replace by subject and survive a JSON round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try testRoot(a, "facts");
    defer cleanRoot(io, root);
    try dir.createDirPath(io, root);
    const meta = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, mission.dir_name });
    try dir.createDirPath(io, meta);

    var facts = std.ArrayList(Fact).empty;
    defer {
        for (facts.items) |f| {
            a.free(f.subject);
            a.free(f.text);
        }
        facts.deinit(a);
    }
    try std.testing.expect(try putFact(a, &facts, .check, "build", "FAIL: exit 1"));
    try std.testing.expect(!try putFact(a, &facts, .check, "build", "FAIL: exit 1"));
    try std.testing.expect(try putFact(a, &facts, .check, "build", "PASS"));
    try std.testing.expectEqual(@as(usize, 1), facts.items.len);
    try std.testing.expectEqualStrings("PASS", facts.items[0].text);
    try std.testing.expect(try putFact(a, &facts, .review, "stage", "SEVERITY: low"));

    try saveFacts(a, io, root, facts.items);
    const loaded = try loadFacts(a, io, root);
    defer freeFacts(a, loaded);
    try std.testing.expectEqual(@as(usize, 2), loaded.len);
    try std.testing.expectEqual(FactKind.check, loaded[0].kind);
    try std.testing.expectEqualStrings("build", loaded[0].subject);
    try std.testing.expectEqualStrings("PASS", loaded[0].text);
    try std.testing.expectEqual(FactKind.review, loaded[1].kind);

    const rendered = try renderFacts(a, loaded, 4096);
    defer a.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[MISSION FACTS]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "check build: PASS") != null);
}

test "mission_io: status dashboard shows bounded progress and cost" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try renderStatus(a, .{
        .status = .running, .turn = 4, .max_turns = 16, .stage = "implement",
        .best_green = 3, .tasks_done = 1, .cost_usd = 1.25, .budget_usd = 5,
    }, 2, 4);
    try std.testing.expect(std.mem.indexOf(u8, text, "Status: running · turn 4/16") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "] 3/4 green") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "] 1/2 done") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Cost:   $1.25 / $5.00 (25%)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Improvement: cycle 0/5") != null);
}

test "mission_io: model-per-role overrides parse and match case-insensitively" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = try parseRoleModels(a, " reviewer =fast-1 ,IMPLEMENTER=big-1, broken, =invalid, reviewer=fast-2 ");
    defer freeRoleModels(a, entries);
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("fast-2", roleModelOverride(entries, "Reviewer").?);
    try std.testing.expectEqualStrings("big-1", roleModelOverride(entries, "implementer").?);
    try std.testing.expect(roleModelOverride(entries, "auditor") == null);
    try std.testing.expect(isReadOnlyRole("reviewer"));
    try std.testing.expect(isReadOnlyRole("AUDITOR"));
    try std.testing.expect(!isReadOnlyRole("implementer"));
    try std.testing.expect(!isReadOnlyRole("worker"));
}

test "mission_io: instruction files are composed in order and capped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const full = try composeInstructions(a, &.{
        .{ .path = "AGENTS.md", .text = "first rule\n" },
        .{ .path = "CLAUDE.md", .text = "second rule\n" },
    }, 4096);
    defer a.free(full);
    try std.testing.expect(std.mem.indexOf(u8, full, "[PROJECT INSTRUCTIONS]") != null);
    try std.testing.expect(std.mem.indexOf(u8, full, "--- AGENTS.md ---\nfirst rule") != null);
    try std.testing.expect(std.mem.indexOf(u8, full, "--- CLAUDE.md ---\nsecond rule") != null);

    const capped = try composeInstructions(a, &.{
        .{ .path = "AGENTS.md", .text = "0123456789" },
        .{ .path = "CLAUDE.md", .text = "should not appear" },
    }, 24);
    defer a.free(capped);
    try std.testing.expect(std.mem.indexOf(u8, capped, "AGENTS.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, capped, "should not appear") == null);
}
