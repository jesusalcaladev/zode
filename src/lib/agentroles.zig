//! Built-in subagent roles and per-role agent memory (Phase 26).
//!
//! Pure on purpose: role selection, prompt composition, memory path logic and
//! window serialization helpers are testable without a network, without the
//! TUI, and without running a subagent loop.

const std = @import("std");

/// Built-in role names, chosen by the `task` tool's `role` argument.
pub const Role = enum {
    explore,
    plan,
    verify,

    pub fn fromName(role_name: []const u8) ?Role {
        if (role_name.len == 0) return null;
        return std.meta.stringToEnum(Role, role_name);
    }

    pub fn name(self: Role) []const u8 {
        return switch (self) {
            .explore => "explore",
            .plan => "plan",
            .verify => "verify",
        };
    }
};

/// Role-specific system prompt, appended after the base subagent contract.
/// The base prompt (`subagent.system_prompt`) already states read-only/search
/// behavior and report format; role prompts specialize the job.
pub const explore_prompt =
    \\Role: explore.
    \\- Your job is broad, parallel-friendly search: find where things live, how they connect, and what matters for the question.
    \\- Report paths and line numbers. Never propose or make edits.
    \\- Prefer grep/glob to reading whole files; read only the lines that answer the question.
    \\- End with a short report: findings, the files/lines that back them up, and anything you did not find.
;

pub const plan_prompt =
    \\Role: plan.
    \\- You are a read-only architect. Explore what exists, then produce an ordered implementation plan.
    \\- Do not write or edit code. Your deliverable is the plan, grounded in the code you read.
    \\- The plan must be concrete: ordered steps, the files/areas each step touches, risks or unknowns, and what to verify.
    \\- End with the ordered plan and the paths/lines that informed it.
;

pub const verify_prompt =
    \\Role: verify.
    \\- Your job is to try to break the change: run it, exercise it, and find the 20% the first 80% hides.
    \\- Be adversarial and evidence-based: look for regressions, edge cases, missing checks, and claims not backed by results.
    \\- Work from the harness's OWN checklist (the review items you were given), never from a checklist you invent.
    \\- Report what you checked, what failed or looks risky (with paths/lines), what you could not verify, and why.
    \\- "I could not break it" is only useful with what you actually tried.
    \\
    \\REPORT PROTOCOL — each finding goes through three states, as words only (never icons):
    \\  found    — you spotted something worth checking (a candidate).
    \\  verified — you confirmed it by running/exercising it; give the evidence.
    \\  refuted  — you tried and it did NOT hold up; say what disproved it.
    \\Emit one line per finding in the exact form: "found: ...", "verified: ...", "refuted: ...".
    \\The harness counts these lines; a finding you merely suspect is `found`, not `verified`.
    \\An empty finding list is fine — say what you tried. Do not invent counts.
;

/// Returns the role-specific prompt, or empty for the default (no role).
pub fn promptFor(role: ?Role) []const u8 {
    const r = role orelse return "";
    return switch (r) {
        .explore => explore_prompt,
        .plan => plan_prompt,
        .verify => verify_prompt,
    };
}

/// The tool names a role may use. Roles cannot escalate beyond what the caller
/// is allowed; callers must ensure the final set is a subset of caller-allowed tools.
/// - explore/plan: read-only search tools (never edits).
/// - verify: read-only tools plus execution tools to run/exercise changes.
pub fn baseToolsFor(role: Role) []const []const u8 {
    return switch (role) {
        .explore, .plan => &.{
            "read", "grep", "glob", "list_files", "web_fetch", "web_search", "lsp",
        },
        .verify => &.{
            "read", "grep", "glob", "list_files", "web_fetch", "web_search", "lsp",
            "bash", "check", "git_status", "git_diff", "git_log",
        },
    };
}

/// Teammate tool set (Phase 20): the read-only search tools plus the task
/// graph reads/writes needed to claim work and the message channel. No `bash`,
/// no `write`/`edit` by default — a teammate starts read-only.
pub const teammate_tool_names = [_][]const u8{
    "read", "grep", "glob", "list_files", "web_fetch", "web_search", "lsp",
    "task_list", "task_get", "task_update", "send_message", "team_status",
};

pub fn teammateAllowsTool(tool: []const u8, writes_granted: bool) bool {
    for (teammate_tool_names) |t| {
        if (std.mem.eql(u8, t, tool)) return true;
    }
    if (writes_granted and (std.mem.eql(u8, tool, "write") or std.mem.eql(u8, tool, "edit"))) return true;
    return false;
}

/// Returns true when `tool` is permitted for a built-in role run (beyond the
/// default read-only subagent set). Roles still cannot escalate beyond caller
/// allowances; this only defines the role's requested capability.
pub fn roleAllowsTool(role: Role, tool: []const u8) bool {
    for (baseToolsFor(role)) |t| {
        if (std.mem.eql(u8, t, tool)) return true;
    }
    return false;
}

/// True if every tool requested by a role is within `caller_allowed`.
/// If `caller_allowed` is empty, it means "no extra restriction provided".
pub fn roleSubsetOfCaller(role: Role, caller_allowed: []const []const u8) bool {
    if (caller_allowed.len == 0) return true;
    for (baseToolsFor(role)) |t| {
        var ok = false;
        for (caller_allowed) |c| {
            if (std.mem.eql(u8, t, c)) {
                ok = true;
                break;
            }
        }
        if (!ok) return false;
    }
    return true;
}

/// Per-project, per-role memory directory: `<project>/.zode/agent-memory/<role>/`.
/// Memory is consulted explicitly (read on start, append lessons), never inlined
/// into the system prompt.
pub fn memoryDir(buf: []u8, project_cwd: []const u8, role: Role) ?[]const u8 {
    if (project_cwd.len == 0) return null;
    return std.mem.print(buf, "{s}/.zode/agent-memory/{s}", .{ project_cwd, role.name() }) catch null;
}

/// Path to the role's lessons file inside the memory directory.
pub fn lessonsPath(buf: []u8, project_cwd: []const u8, role: Role) ?[]const u8 {
    if (project_cwd.len == 0) return null;
    return std.mem.print(buf, "{s}/.zode/agent-memory/{s}/lessons.md", .{ project_cwd, role.name() }) catch null;
}

/// Reads role memory (lessons) if present. Returns empty slice when missing or
/// unreadable; memory being empty costs nothing.
pub fn readMemory(io: std.Io, gpa: std.mem.Allocator, project_cwd: []const u8, role: Role) []u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = lessonsPath(&path_buf, project_cwd, role) orelse return &.{};
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch return &.{};
    return data;
}

/// Appends a lesson to the role's memory, creating the directory/file as needed.
/// Best-effort: failures are ignored (memory must never break a subagent run).
pub fn appendMemory(io: std.Io, project_cwd: []const u8, role: Role, lesson: []const u8) void {
    if (lesson.len == 0) return;
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = memoryDir(&dir_buf, project_cwd, role) orelse return;
    std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = lessonsPath(&path_buf, project_cwd, role) orelse return;

    // Append by read+write to stay compatible with simple Io APIs.
    var existing: []u8 = &.{};
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    existing = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch &.{};

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(arena);
    if (existing.len > 0) {
        out.appendSlice(arena, existing) catch return;
        if (existing[existing.len - 1] != '\n') out.append(arena, '\n') catch return;
    }
    out.appendSlice(arena, "- ") catch return;
    out.appendSlice(arena, lesson) catch return;
    if (lesson[lesson.len - 1] != '\n') out.append(arena, '\n') catch return;

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items }) catch {};
}

/// Compose the memory preface placed in the subagent's initial user content.
/// It is part of consulted context for this run, not inlined into the system prompt.
/// Returns empty when there is no memory.
pub fn memoryPreface(arena: std.mem.Allocator, mem: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, mem, " \t\r\n");
    if (trimmed.len == 0) return "";
    return std.fmt.allocPrint(
        arena,
        "[agent memory for this role; lessons from earlier runs — use if relevant, do not repeat them verbatim]\n{s}\n\n",
        .{trimmed},
    ) catch "";
}

// ── subagent window persistence (resume/fork) ─────────────────

/// Directory holding saved subagent windows for a session:
/// `<dir-of-session-file>/subagents/`.
pub fn subagentsDir(buf: []u8, session_path: []const u8) ?[]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, session_path, '/') orelse return null;
    const dir = session_path[0..slash];
    return std.mem.print(buf, "{s}/subagents", .{dir}) catch null;
}

/// Path of a saved subagent window: `<subagentsDir>/<id>.jsonl`.
pub fn windowPath(buf: []u8, session_path: []const u8, id: []const u8) ?[]const u8 {
    if (!isValidId(id)) return null;
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = subagentsDir(&dir_buf, session_path) orelse return null;
    return std.mem.print(buf, "{s}/{s}.jsonl", .{ dir, id }) catch null;
}

/// A valid subagent session id: short, filesystem-safe.
pub fn isValidId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!ok) return false;
    }
    return true;
}

/// Generates a short id from a counter into `buf`.
pub fn newId(buf: []u8, counter: u64) []const u8 {
    return std.mem.print(buf, "sa-{x}", .{counter}) catch "sa-0";
}

/// One window message (used for serialization and parsing).
pub const WindowMsg = struct { role: []const u8, content: []const u8 };

/// Serialize a chat history window to JSONL (one {"role","content"} per line).
/// Minimal escaping for content; tool messages are stored as role/content only
/// (enough to resume reasoning context).
pub fn serializeWindow(arena: std.mem.Allocator, msgs: []const WindowMsg) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (msgs) |m| {
        try out.appendSlice(arena, "{\"role\":");
        try appendJsonString(&out, arena, m.role);
        try out.appendSlice(arena, ",\"content\":");
        try appendJsonString(&out, arena, m.content);
        try out.appendSlice(arena, "}\n");
    }
    return out.toOwnedSlice(arena);
}

fn appendJsonString(out: *std.ArrayList(u8), arena: std.mem.Allocator, s: []const u8) !void {
    try out.append(arena, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(arena, "\\\""),
            '\\' => try out.appendSlice(arena, "\\\\"),
            '\n' => try out.appendSlice(arena, "\\n"),
            '\r' => try out.appendSlice(arena, "\\r"),
            '\t' => try out.appendSlice(arena, "\\t"),
            else => {
                if (c < 0x20) {
                    var esc: [6]u8 = undefined;
                    const e = std.mem.print(&esc, "\\u{x:0>4}", .{c}) catch "\\u0000";
                    try out.appendSlice(arena, e);
                } else {
                    try out.append(arena, c);
                }
            },
        }
    }
    try out.append(arena, '"');
}

/// A parsed window message.
pub const SavedMsg = WindowMsg;

/// Parse a saved window (JSONL). Malformed lines are skipped.
pub fn parseWindow(arena: std.mem.Allocator, data: []const u8) ![]SavedMsg {
    var list: std.ArrayList(SavedMsg) = .empty;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, t, .{}) catch continue;
        if (v != .object) continue;
        const role_v = v.object.get("role") orelse continue;
        const content_v = v.object.get("content") orelse continue;
        if (role_v != .string or content_v != .string) continue;
        list.append(arena, .{ .role = role_v.string, .content = content_v.string }) catch {};
    }
    return list.toOwnedSlice(arena);
}

/// Save a window to disk (best-effort).
pub fn saveWindow(io: std.Io, session_path: []const u8, id: []const u8, data: []const u8) void {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = subagentsDir(&dir_buf, session_path) orelse return;
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = windowPath(&path_buf, session_path, id) orelse return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch {};
}

/// Load a saved window (null if missing/unreadable).
pub fn loadWindow(io: std.Io, arena: std.mem.Allocator, session_path: []const u8, id: []const u8) ?[]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = windowPath(&path_buf, session_path, id) orelse return null;
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(2 * 1024 * 1024)) catch null;
}

// ── tests ─────────────────────────────────────────────────────

test "agentroles: role selection by name" {
    try std.testing.expectEqual(Role.explore, Role.fromName("explore").?);
    try std.testing.expectEqual(Role.plan, Role.fromName("plan").?);
    try std.testing.expectEqual(Role.verify, Role.fromName("verify").?);
    try std.testing.expect(Role.fromName("unknown") == null);
    try std.testing.expect(Role.fromName("") == null);
}

test "agentroles: unknown role falls back to default prompt (empty)" {
    try std.testing.expectEqualStrings("", promptFor(null));
    try std.testing.expect(promptFor(.explore).len > 0);
    try std.testing.expect(promptFor(.plan).len > 0);
    try std.testing.expect(promptFor(.verify).len > 0);
}

test "agentroles: explore/plan tools are read-only subset" {
    const allowed = [_][]const u8{ "read", "grep", "glob", "list_files", "web_fetch", "web_search", "lsp" };
    inline for (.{ Role.explore, Role.plan }) |r| {
        for (baseToolsFor(r)) |t| {
            var ok = false;
            for (allowed) |a| {
                if (std.mem.eql(u8, t, a)) {
                    ok = true;
                    break;
                }
            }
            try std.testing.expect(ok);
        }
    }
}

test "agentroles: verify role can run/exercise (includes bash/check)" {
    try std.testing.expect(roleAllowsTool(.verify, "bash"));
    try std.testing.expect(roleAllowsTool(.verify, "check"));
    try std.testing.expect(roleAllowsTool(.verify, "read"));
    try std.testing.expect(!roleAllowsTool(.explore, "bash"));
    try std.testing.expect(!roleAllowsTool(.plan, "bash"));
}

test "agentroles: role tool list is subset of caller-allowed set (no escalation)" {
    const caller = [_][]const u8{ "read", "grep", "glob", "list_files", "web_fetch", "web_search", "lsp", "bash", "check", "git_status", "git_diff", "git_log" };
    try std.testing.expect(roleSubsetOfCaller(.verify, &caller));
    const narrow = [_][]const u8{ "read", "grep", "glob", "list_files", "web_fetch", "web_search", "lsp" };
    try std.testing.expect(!roleSubsetOfCaller(.verify, &narrow));
    try std.testing.expect(roleSubsetOfCaller(.explore, &narrow));
}

test "agentroles: memory is not inlined into the prompt" {
    const mem = "remember: check src/tui.zig first";
    const p = promptFor(.explore);
    try std.testing.expect(std.mem.indexOf(u8, p, mem) == null);
    const preface = memoryPreface(std.testing.allocator, mem);
    defer std.testing.allocator.free(preface);
    // preface is consulted context (separately composed), not part of the system prompt
    try std.testing.expect(std.mem.indexOf(u8, preface, mem) != null);
}

test "agentroles: memory preface empty when no memory" {
    try std.testing.expectEqualStrings("", memoryPreface(std.testing.allocator, ""));
    try std.testing.expectEqualStrings("", memoryPreface(std.testing.allocator, "   \n"));
}

test "agentroles: memory dir and lessons path" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/proj/.zode/agent-memory/explore",
        memoryDir(&buf, "/proj", .explore).?,
    );
    try std.testing.expectEqualStrings(
        "/proj/.zode/agent-memory/plan/lessons.md",
        lessonsPath(&buf, "/proj", .plan).?,
    );
}

test "agentroles: subagent id validation" {
    try std.testing.expect(isValidId("sa-abc123"));
    try std.testing.expect(isValidId("explore_1"));
    try std.testing.expect(!isValidId(""));
    try std.testing.expect(!isValidId("../evil"));
    try std.testing.expect(!isValidId("has space"));
}

test "agentroles: window serialize/parse round-trip and fork independence" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const msgs = [_]WindowMsg{
        .{ .role = "system", .content = "sys" },
        .{ .role = "user", .content = "find it" },
        .{ .role = "assistant", .content = "found at a.zig:1" },
    };
    const data = try serializeWindow(arena, &msgs);
    const parsed = try parseWindow(arena, data);
    try std.testing.expectEqual(@as(usize, 3), parsed.len);
    try std.testing.expectEqualStrings("assistant", parsed[2].role);
    try std.testing.expectEqualStrings("found at a.zig:1", parsed[2].content);

    // Fork: copy parsed into a new independent slice and mutate; original unchanged.
    const forked = try arena.dupe(SavedMsg, parsed);
    forked[2] = .{ .role = "assistant", .content = "different" };
    try std.testing.expectEqualStrings("found at a.zig:1", parsed[2].content);
    try std.testing.expectEqualStrings("different", forked[2].content);
}

test "agentroles: resume keeps window contents" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const msgs = [_]WindowMsg{
        .{ .role = "user", .content = "step 1" },
        .{ .role = "assistant", .content = "step 2" },
    };
    const data = try serializeWindow(arena, &msgs);
    const resumed = try parseWindow(arena, data);
    try std.testing.expectEqual(@as(usize, 2), resumed.len);
    try std.testing.expectEqualStrings("step 1", resumed[0].content);
    try std.testing.expectEqualStrings("step 2", resumed[1].content);
}
// ── IO tests: memory append/read and window persistence ────────

test "agentroles: appendMemory creates the lessons file and readMemory reads it back" {
    var rel: [std.fs.max_path_bytes]u8 = undefined;
    var abs: [std.fs.max_path_bytes]u8 = undefined;
    const name = try std.mem.printSentinel(&rel, ".zig-cache/zode-agentroles-mem-{d}", .{std.testing.random_seed}, 0);
    std.Io.Dir.cwd().deleteTree(std.testing.io, name) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, name);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, name) catch {};

    var cwdbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.cwd().readLink(std.testing.io, "/proc/self/cwd", &cwdbuf) catch 0;
    const base: []const u8 = if (n > 0 and cwdbuf[0] == '/') cwdbuf[0..n] else ".";
    const root = try std.mem.print(&abs, "{s}/{s}", .{ base, name });

    try std.testing.expectEqualStrings("", readMemory(std.testing.io, std.testing.allocator, root, .explore));

    appendMemory(std.testing.io, root, .explore, "first lesson");
    appendMemory(std.testing.io, root, .explore, "second lesson");

    const mem = readMemory(std.testing.io, std.testing.allocator, root, .explore);
    defer std.testing.allocator.free(mem);
    try std.testing.expect(std.mem.indexOf(u8, mem, "first lesson") != null);
    try std.testing.expect(std.mem.indexOf(u8, mem, "second lesson") != null);
    // Two lessons, two bullets; append (not overwrite).
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, mem, "- "));

    // Memory for another role is independent (no cross-role bleed).
    try std.testing.expectEqualStrings("", readMemory(std.testing.io, std.testing.allocator, root, .plan));
}

test "agentroles: saveWindow/loadWindow round-trip on disk" {
    var rel: [std.fs.max_path_bytes]u8 = undefined;
    var abs: [std.fs.max_path_bytes]u8 = undefined;
    const name = try std.mem.printSentinel(&rel, ".zig-cache/zode-agentroles-win-{d}", .{std.testing.random_seed}, 0);
    std.Io.Dir.cwd().deleteTree(std.testing.io, name) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, name);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, name) catch {};

    var cwdbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.cwd().readLink(std.testing.io, "/proc/self/cwd", &cwdbuf) catch 0;
    const base: []const u8 = if (n > 0 and cwdbuf[0] == '/') cwdbuf[0..n] else ".";
    const root = try std.mem.print(&abs, "{s}/{s}", .{ base, name });
    var sp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const session_path = try std.mem.print(&sp_buf, "{s}/session.jsonl", .{root});

    const msgs = [_]WindowMsg{
        .{ .role = "system", .content = "sys" },
        .{ .role = "user", .content = "question" },
        .{ .role = "assistant", .content = "answer" },
    };
    const data = try serializeWindow(std.testing.allocator, &msgs);
    defer std.testing.allocator.free(data);
    saveWindow(std.testing.io, session_path, "sa-test1", data);

    const loaded = loadWindow(std.testing.io, std.testing.allocator, session_path, "sa-test1");
    try std.testing.expect(loaded != null);
    defer std.testing.allocator.free(loaded.?);
    try std.testing.expectEqualStrings(data, loaded.?);

    // A missing window is null, not an error-shaped empty slice.
    try std.testing.expect(loadWindow(std.testing.io, std.testing.allocator, session_path, "sa-missing") == null);
}
