//! Hook system (Phase 5, Sprint D).
//!
//! Pure config parsing and matching, plus command-hook execution helpers.
//! v1 = command hooks only.
//!
//! Config: `.zode/hooks.json`
//! ```json
//! { "hooks": [
//!   { "event": "PreToolUse", "matcher": "Bash", "if": "Bash(git *)",
//!     "command": "echo hi", "timeout_ms": 5000, "once": false }
//! ]}
//! ```
//!
//! `matcher`: tool name or regex (matched against tool name for tool events;
//! against prompt text for UserPromptSubmit; ignored for Stop when empty).
//! `if`: permission-rule syntax (Phase 6) — `Tool(pattern)` matched against the
//! tool and its subject (command/path). Omitted/empty means always matches.
//! `timeout_ms`: bounds the run (default 5000). `once`: fires at most once.
//!
//! PreToolUse: non-zero exit blocks the tool; stdout/stderr is fed back as the
//! reason/note. Hook output is fed back as a tool result / system note.

const std = @import("std");
const permrules = @import("permrules.zig");
const regex_mod = @import("regex.zig");

pub const Event = enum {
    PreToolUse,
    PostToolUse,
    UserPromptSubmit,
    Stop,
    /// 34.14: fired before a permission dialog / permission decision, so hooks
    /// can allow or deny in headless or automated runs.
    PermissionRequest,

    pub fn parse(s: []const u8) ?Event {
        if (std.ascii.eqlIgnoreCase(s, "PreToolUse") or std.ascii.eqlIgnoreCase(s, "pre_tool_use")) return .PreToolUse;
        if (std.ascii.eqlIgnoreCase(s, "PostToolUse") or std.ascii.eqlIgnoreCase(s, "post_tool_use")) return .PostToolUse;
        if (std.ascii.eqlIgnoreCase(s, "UserPromptSubmit") or std.ascii.eqlIgnoreCase(s, "user_prompt_submit")) return .UserPromptSubmit;
        if (std.ascii.eqlIgnoreCase(s, "Stop") or std.ascii.eqlIgnoreCase(s, "stop")) return .Stop;
        if (std.ascii.eqlIgnoreCase(s, "PermissionRequest") or std.ascii.eqlIgnoreCase(s, "permission_request")) return .PermissionRequest;
        return null;
    }

    pub fn name(self: Event) []const u8 {
        return switch (self) {
            .PreToolUse => "PreToolUse",
            .PostToolUse => "PostToolUse",
            .UserPromptSubmit => "UserPromptSubmit",
            .Stop => "Stop",
            .PermissionRequest => "PermissionRequest",
        };
    }
};

pub const Hook = struct {
    event: Event,
    matcher: []const u8 = "",
    @"if": []const u8 = "",
    command: []const u8,
    timeout_ms: u64 = 5000,
    once: bool = false,
    fired: bool = false,
};

pub const Set = struct {
    hooks: []Hook = &.{},

    pub fn init(hooks: []Hook) Set {
        return .{ .hooks = hooks };
    }

    /// Reset `once` state (e.g., per session start if desired). Hooks loaded
    /// fresh each turn/session typically don't need this.
    pub fn resetOnce(self: *Set) void {
        for (self.hooks) |*h| h.fired = false;
    }
};

pub const MatchCtx = struct {
    event: Event,
    tool: []const u8 = "",
    /// Subject for `if` matching (bash command, file path, or tool args text).
    subject: []const u8 = "",
    /// Prompt text for UserPromptSubmit.
    prompt: []const u8 = "",
};

/// 34.14: hook answer to a permission request (also usable from PreToolUse).
pub const PermissionDecision = enum { allow, deny, ask };

pub const RunResult = struct {
    ran: bool = false,
    blocked: bool = false,
    timed_out: bool = false,
    exit_code: u8 = 0,
    /// Combined/human-readable output (backward compatible). Owned by `gpa`.
    output: []const u8 = "",
    /// 34.6: extra context to inject (PostToolUse/UserPromptSubmit/Stop). Owned.
    additional_context: []const u8 = "",
    /// 34.6: replacement tool input JSON for PreToolUse. Owned.
    updated_input: []const u8 = "",
    /// 34.6/34.14: permission decision from hook output. Not owned.
    permission_decision: ?PermissionDecision = null,
    /// Optional hook message. Owned.
    system_message: []const u8 = "",

    pub fn deinit(self: *RunResult, gpa: std.mem.Allocator) void {
        if (self.output.len > 0) gpa.free(self.output);
        if (self.additional_context.len > 0) gpa.free(self.additional_context);
        if (self.updated_input.len > 0) gpa.free(self.updated_input);
        if (self.system_message.len > 0) gpa.free(self.system_message);
        self.* = .{};
    }
};

/// Whether `hook` matches `ctx`. Does not consider `once`/fired state.
pub fn matches(hook: Hook, ctx: MatchCtx) bool {
    if (hook.event != ctx.event) return false;

    // matcher: tool name or regex
    if (hook.matcher.len > 0) {
        const target = switch (ctx.event) {
            .PreToolUse, .PostToolUse, .PermissionRequest => ctx.tool,
            .UserPromptSubmit => ctx.prompt,
            .Stop => ctx.prompt,
        };
        if (!matchMatcher(hook.matcher, target)) return false;
    }

    // if: permission-rule syntax
    if (hook.@"if".len > 0) {
        if (!matchIf(hook.@"if", ctx.tool, ctx.subject)) return false;
    }

    return true;
}

fn matchMatcher(matcher: []const u8, target: []const u8) bool {
    // Exact tool/name match first (fast path, case-sensitive like tool names).
    if (std.mem.eql(u8, matcher, target)) return true;
    if (std.ascii.eqlIgnoreCase(matcher, target)) return true;
    // Regex match.
    const re = regex_mod.Regex.compile(matcher);
    return re.matches(target);
}

fn matchIf(cond: []const u8, tool: []const u8, subject: []const u8) bool {
    const trimmed = std.mem.trim(u8, cond, " \t\r\n");
    if (trimmed.len == 0) return true;
    // Permission-rule syntax: Tool(pattern) [action] — action ignored for `if`,
    // we only care whether the rule matches.
    if (permrules.parseRuleText(trimmed)) |r| {
        const tool_name = if (tool.len > 0) tool else r.tool;
        if (!std.mem.eql(u8, r.tool, "*") and !std.ascii.eqlIgnoreCase(r.tool, tool_name)) return false;
        return permrules.matchesPattern(r.pattern, subject);
    }
    // Fallback: treat as a glob/pattern against subject, or tool name.
    if (subject.len > 0) return permrules.matchesPattern(trimmed, subject);
    if (tool.len > 0) return permrules.matchesPattern(trimmed, tool);
    return true;
}

/// Fire matching hooks for `ctx`. Mutates `once` state. `gpa` owns output strings.
pub fn fire(
    gpa: std.mem.Allocator,
    set: *Set,
    ctx: MatchCtx,
    io: ?std.Io,
) ![]RunResult {
    var out: std.ArrayList(RunResult) = .empty;
    errdefer {
        for (out.items) |*r| r.deinit(gpa);
        out.deinit(gpa);
    }
    for (set.hooks) |*h| {
        if (h.once and h.fired) continue;
        if (!matches(h.*, ctx)) continue;
        h.fired = true;
        const rr = runCommand(gpa, h.*, ctx, io);
        try out.append(gpa, rr);
        // PreToolUse: first blocking hook stops further hooks? Spec says
        // "a non-zero exit on PreToolUse blocks the tool" - run all and let
        // caller see if any blocked; caller can decide. We record it.
    }
    return out.toOwnedSlice(gpa);
}

pub fn freeResults(gpa: std.mem.Allocator, results: []const RunResult) void {
    const mut: []RunResult = @constCast(results);
    for (mut) |*r| r.deinit(gpa);
    gpa.free(mut);
}

/// Aggregate: did any PreToolUse hook block, and what's the combined note?
pub fn blockedReason(gpa: std.mem.Allocator, results: []const RunResult, event: Event) !?[]const u8 {
    if (event != .PreToolUse) return null;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var blocked = false;
    for (results) |r| {
        if (!r.ran) continue;
        const is_block = r.timed_out or r.exit_code != 0 or r.blocked or r.permission_decision == .deny;
        if (is_block) {
            blocked = true;
            if (buf.items.len > 0) try buf.appendSlice(gpa, "\n");
            if (r.timed_out) {
                try buf.appendSlice(gpa, "hook timed out");
            } else if (r.permission_decision == .deny and r.exit_code == 0) {
                try buf.appendSlice(gpa, "hook denied by permissionDecision");
            } else {
                try buf.print(gpa, "hook exited with code {d}", .{r.exit_code});
            }
            const reason = if (r.system_message.len > 0) r.system_message else r.output;
            if (reason.len > 0) {
                try buf.appendSlice(gpa, ": ");
                const lim = @min(reason.len, 4096);
                try buf.appendSlice(gpa, reason[0..lim]);
            }
        }
    }
    if (!blocked) {
        buf.deinit(gpa);
        return null;
    }
    return try buf.toOwnedSlice(gpa);
}

/// Collect non-blocking output/context as a system/tool note (34.6).
pub fn notesText(gpa: std.mem.Allocator, results: []const RunResult) !?[]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    for (results) |r| {
        if (!r.ran) continue;
        if (r.blocked or r.timed_out or r.exit_code != 0 or r.permission_decision == .deny) continue;
        // Prefer explicit additionalContext (34.6), fall back to plain output.
        const text = if (r.additional_context.len > 0) r.additional_context else r.output;
        if (text.len == 0) continue;
        if (buf.items.len > 0) try buf.appendSlice(gpa, "\n");
        const lim = @min(text.len, 8192);
        try buf.appendSlice(gpa, text[0..lim]);
    }
    if (buf.items.len == 0) {
        buf.deinit(gpa);
        return null;
    }
    return try buf.toOwnedSlice(gpa);
}

/// 34.6/34.14: first definitive permission decision from hook results.
pub fn permissionDecision(results: []const RunResult) ?PermissionDecision {
    for (results) |r| {
        if (!r.ran) continue;
        if (r.permission_decision) |d| return d;
    }
    return null;
}

/// 34.6: last updated_input from PreToolUse hook results (later hooks win).
pub fn updatedInput(results: []const RunResult) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (results) |r| {
        if (!r.ran) continue;
        if (r.updated_input.len > 0) found = r.updated_input;
    }
    return found;
}

fn runCommand(gpa: std.mem.Allocator, hook: Hook, ctx: MatchCtx, io: ?std.Io) RunResult {
    const io_val = io orelse return .{ .ran = false };
    _ = ctx;
    // Run via `sh -c` so hooks are shell commands (v1).
    const timeout_ms: u64 = if (hook.timeout_ms == 0) 5000 else hook.timeout_ms;
    const timeout_s: u64 = @max(@as(u64, 1), (timeout_ms + 999) / 1000);
    const argv = [_][]const u8{ "sh", "-c", hook.command };
    const result = std.process.run(gpa, io_val, .{
        .argv = &argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .reserve_amount = 4096,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(@intCast(timeout_s)), .clock = .awake } },
    }) catch |err| {
        const msg = std.fmt.allocPrint(gpa, "hook failed to start: {t}", .{err}) catch dupe(gpa, "hook failed to start");
        return .{ .ran = true, .blocked = true, .exit_code = 127, .output = msg };
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    // Combine stdout+stderr for feedback (backward compatible plain-text use).
    var out: std.ArrayList(u8) = .empty;
    if (result.stdout.len > 0) out.appendSlice(gpa, result.stdout) catch {};
    if (result.stderr.len > 0) {
        if (out.items.len > 0) out.append(gpa, '\n') catch {};
        out.appendSlice(gpa, result.stderr) catch {};
    }
    const output = out.toOwnedSlice(gpa) catch dupe(gpa, "");
    const timed_out = result.term != .exited;
    const code: u8 = switch (result.term) {
        .exited => |c| @intCast(@min(c, 255)),
        else => 1,
    };
    var rr = RunResult{
        .ran = true,
        .blocked = timed_out or code != 0,
        .timed_out = timed_out,
        .exit_code = code,
        .output = output,
    };
    // 34.6: parse JSON contract from stdout when present (non-zero exit can
    // still carry structured denial/notes; stdout is the contract channel).
    parseContract(gpa, result.stdout, &rr);
    return rr;
}

fn parseContract(gpa: std.mem.Allocator, stdout: []const u8, rr: *RunResult) void {
    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '{') return;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, trimmed, .{}) catch return;
    if (parsed != .object) return;
    applyContractObject(gpa, parsed.object, rr);
    if (parsed.object.get("hookSpecificOutput")) |hso| {
        if (hso == .object) applyContractObject(gpa, hso.object, rr);
    }
}

fn applyContractObject(gpa: std.mem.Allocator, obj: std.json.ObjectMap, rr: *RunResult) void {
    if (getStr(obj, "additionalContext")) |s| {
        if (rr.additional_context.len == 0) rr.additional_context = dupe(gpa, s);
    }
    if (getStr(obj, "systemMessage")) |s| {
        if (rr.system_message.len == 0) rr.system_message = dupe(gpa, s);
    }
    if (getStr(obj, "permissionDecision")) |s| {
        if (std.ascii.eqlIgnoreCase(s, "allow")) rr.permission_decision = .allow;
        if (std.ascii.eqlIgnoreCase(s, "deny")) rr.permission_decision = .deny;
        if (std.ascii.eqlIgnoreCase(s, "ask")) rr.permission_decision = .ask;
    }
    if (obj.get("updatedInput")) |ui| {
        // PreToolUse: replacement tool args as JSON.
        if (rr.updated_input.len == 0) {
            rr.updated_input = std.json.Stringify.valueAlloc(gpa, ui, .{}) catch "";
        }
    }
    // A structured deny via permissionDecision should block (even if the hook
    // exited 0, the contract is explicit).
    if (rr.permission_decision == .deny) rr.blocked = true;
}

fn dupe(gpa: std.mem.Allocator, s: []const u8) []const u8 {
    return gpa.dupe(u8, s) catch "";
}

/// Parse `.zode/hooks.json` content. Unknown/malformed hooks are skipped.
/// Hooks are owned by `arena`.
pub fn parseConfig(arena: std.mem.Allocator, content: []const u8) Set {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, content, .{}) catch return .{};
    var arr: ?[]const std.json.Value = null;
    switch (parsed) {
        .array => |a| arr = a.items,
        .object => |o| {
            if (o.get("hooks")) |h| {
                if (h == .array) arr = h.array.items;
            }
        },
        else => {},
    }
    const items = arr orelse return .{};
    var out: std.ArrayList(Hook) = .empty;
    for (items) |v| {
        if (parseHook(arena, v)) |h| out.append(arena, h) catch {};
    }
    return .{ .hooks = out.items };
}

fn parseHook(arena: std.mem.Allocator, v: std.json.Value) ?Hook {
    if (v != .object) return null;
    const o = v.object;
    const ev_s = getStr(o, "event") orelse return null;
    const event = Event.parse(ev_s) orelse return null;
    const command = getStr(o, "command") orelse return null;
    if (command.len == 0) return null;
    var h = Hook{
        .event = event,
        .command = dupeArena(arena, command) orelse return null,
    };
    if (getStr(o, "matcher")) |s| h.matcher = dupeArena(arena, s) orelse "";
    if (getStr(o, "if")) |s| h.@"if" = dupeArena(arena, s) orelse "";
    if (o.get("timeout_ms")) |tv| {
        h.timeout_ms = switch (tv) {
            .integer => |i| if (i >= 0) @intCast(i) else 5000,
            .float => |f| if (f >= 0) @intFromFloat(f) else 5000,
            else => 5000,
        };
    }
    if (o.get("once")) |b| {
        h.once = switch (b) {
            .bool => |x| x,
            else => false,
        };
    }
    return h;
}

fn dupeArena(arena: std.mem.Allocator, s: []const u8) ?[]const u8 {
    return arena.dupe(u8, s) catch null;
}

fn getStr(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

// ── tests ──────────────────────────────────────────────────────────────────

const t = std.testing;

test "hooks: config parsing and malformed hooks are skipped" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const content =
        \\{"hooks":[
        \\  {"event":"PreToolUse","matcher":"Bash","command":"echo hi","timeout_ms":1234,"once":true},
        \\  {"event":"Nope","command":"x"},
        \\  {"event":"Stop","command":""},
        \\  {"event":"PostToolUse","matcher":"write","if":"Write(src/*)","command":"true"}
        \\]}
    ;
    const set = parseConfig(a, content);
    try t.expectEqual(@as(usize, 2), set.hooks.len);
    try t.expectEqual(Event.PreToolUse, set.hooks[0].event);
    try t.expectEqualStrings("Bash", set.hooks[0].matcher);
    try t.expectEqualStrings("echo hi", set.hooks[0].command);
    try t.expectEqual(@as(u64, 1234), set.hooks[0].timeout_ms);
    try t.expect(set.hooks[0].once);
    try t.expectEqual(Event.PostToolUse, set.hooks[1].event);
    try t.expectEqualStrings("Write(src/*)", set.hooks[1].@"if");
}

test "hooks: event and matcher matching" {
    const h = Hook{ .event = .PreToolUse, .matcher = "Bash", .command = "true" };
    try t.expect(matches(h, .{ .event = .PreToolUse, .tool = "Bash" }));
    try t.expect(matches(h, .{ .event = .PreToolUse, .tool = "bash" }));
    try t.expect(!matches(h, .{ .event = .PreToolUse, .tool = "write" }));
    try t.expect(!matches(h, .{ .event = .PostToolUse, .tool = "Bash" }));
    const any = Hook{ .event = .Stop, .matcher = "", .command = "true" };
    try t.expect(matches(any, .{ .event = .Stop }));
}

test "hooks: matcher supports regex" {
    const h = Hook{ .event = .PreToolUse, .matcher = "git_.*", .command = "true" };
    try t.expect(matches(h, .{ .event = .PreToolUse, .tool = "git_status" }));
    try t.expect(!matches(h, .{ .event = .PreToolUse, .tool = "write" }));
}

test "hooks: if uses permission-rule syntax" {
    const h = Hook{ .event = .PreToolUse, .matcher = "Bash", .@"if" = "Bash(git *)", .command = "true" };
    try t.expect(matches(h, .{ .event = .PreToolUse, .tool = "Bash", .subject = "git status" }));
    try t.expect(!matches(h, .{ .event = .PreToolUse, .tool = "Bash", .subject = "rm -rf /" }));
    const any_tool = Hook{ .event = .PreToolUse, .@"if" = "*(src/*)", .command = "true" };
    try t.expect(matches(any_tool, .{ .event = .PreToolUse, .tool = "write", .subject = "src/a.zig" }));
    try t.expect(!matches(any_tool, .{ .event = .PreToolUse, .tool = "write", .subject = "README.md" }));
}

test "hooks: once fires at most once" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var hooks_arr = [_]Hook{
        .{ .event = .Stop, .command = "true", .once = true },
    };
    var set = Set.init(&hooks_arr);
    const ctx = MatchCtx{ .event = .Stop };
    try t.expect(matches(set.hooks[0], ctx) and !set.hooks[0].fired);
    set.hooks[0].fired = true;
    try t.expect(set.hooks[0].once and set.hooks[0].fired);
    set.resetOnce();
    try t.expect(!set.hooks[0].fired);
}

test "hooks: parse event names" {
    try t.expectEqual(Event.PreToolUse, Event.parse("PreToolUse").?);
    try t.expectEqual(Event.PostToolUse, Event.parse("post_tool_use").?);
    try t.expectEqual(Event.UserPromptSubmit, Event.parse("UserPromptSubmit").?);
    try t.expectEqual(Event.Stop, Event.parse("stop").?);
    try t.expect(Event.parse("bogus") == null);
}

test "hooks: timeout is parsed and bounded by config" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const content =
        \\{"hooks":[{"event":"Stop","command":"true","timeout_ms":42}]}
    ;
    const set = parseConfig(a, content);
    try t.expectEqual(@as(usize, 1), set.hooks.len);
    try t.expectEqual(@as(u64, 42), set.hooks[0].timeout_ms);
}

test "hooks: integration - command hook runs and PreToolUse non-zero blocks" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // A hook that succeeds: no block.
    var ok_hooks = [_]Hook{.{ .event = .PreToolUse, .matcher = "Bash", .command = "printf ok", .timeout_ms = 5000 }};
    var ok_set = Set.init(&ok_hooks);
    const ok_res = try fire(t.allocator, &ok_set, .{ .event = .PreToolUse, .tool = "Bash", .subject = "echo hi" }, io);
    defer freeResults(t.allocator, ok_res);
    try t.expectEqual(@as(usize, 1), ok_res.len);
    try t.expect(ok_res[0].ran);
    try t.expect(!ok_res[0].blocked);
    const no_reason = try blockedReason(t.allocator, ok_res, .PreToolUse);
    try t.expect(no_reason == null);

    // A hook that fails: blocks PreToolUse with reason.
    var bad_hooks = [_]Hook{.{ .event = .PreToolUse, .matcher = "Bash", .command = "echo nope >&2; exit 7", .timeout_ms = 5000 }};
    var bad_set = Set.init(&bad_hooks);
    const bad_res = try fire(t.allocator, &bad_set, .{ .event = .PreToolUse, .tool = "Bash", .subject = "echo hi" }, io);
    defer freeResults(t.allocator, bad_res);
    try t.expect(bad_res[0].ran);
    try t.expect(bad_res[0].blocked);
    try t.expectEqual(@as(u8, 7), bad_res[0].exit_code);
    const reason = try blockedReason(t.allocator, bad_res, .PreToolUse);
    try t.expect(reason != null);
    defer t.allocator.free(reason.?);
    try t.expect(std.mem.indexOf(u8, reason.?, "nope") != null);

    // PostToolUse non-zero does not "block" in the PreToolUse sense (caller decides);
    // blockedReason only applies to PreToolUse.
    var post_hooks = [_]Hook{.{ .event = .PostToolUse, .matcher = "Bash", .command = "exit 1", .timeout_ms = 5000 }};
    var post_set = Set.init(&post_hooks);
    const post_res = try fire(t.allocator, &post_set, .{ .event = .PostToolUse, .tool = "Bash" }, io);
    defer freeResults(t.allocator, post_res);
    const post_reason = try blockedReason(t.allocator, post_res, .PostToolUse);
    try t.expect(post_reason == null);
    _ = a;
}

test "hooks 34.6: parses additionalContext and updatedInput from JSON stdout" {
    const io = std.testing.io;
    var hooks_arr = [_]Hook{
        .{ .event = .PostToolUse, .matcher = "write", .command = "printf '%s' '{\"additionalContext\":\"remember this\"}'", .timeout_ms = 5000 },
    };
    var set = Set.init(&hooks_arr);
    const res = try fire(t.allocator, &set, .{ .event = .PostToolUse, .tool = "write" }, io);
    defer freeResults(t.allocator, res);
    try t.expectEqual(@as(usize, 1), res.len);
    try t.expect(res[0].ran);
    try t.expectEqualStrings("remember this", res[0].additional_context);
    const note = try notesText(t.allocator, res);
    try t.expect(note != null);
    defer t.allocator.free(note.?);
    try t.expect(std.mem.indexOf(u8, note.?, "remember this") != null);
}

test "hooks 34.6: PreToolUse updatedInput and permissionDecision deny" {
    const io = std.testing.io;
    var upd_hooks = [_]Hook{
        .{ .event = .PreToolUse, .matcher = "bash", .command = "printf '%s' '{\"updatedInput\":{\"command\":\"echo safe\"}}'", .timeout_ms = 5000 },
    };
    var upd_set = Set.init(&upd_hooks);
    const upd = try fire(t.allocator, &upd_set, .{ .event = .PreToolUse, .tool = "bash", .subject = "echo hi" }, io);
    defer freeResults(t.allocator, upd);
    try t.expect(updatedInput(upd) != null);
    try t.expect(std.mem.indexOf(u8, updatedInput(upd).?, "echo safe") != null);

    var deny_hooks = [_]Hook{
        .{ .event = .PreToolUse, .matcher = "bash", .command = "printf '%s' '{\"permissionDecision\":\"deny\",\"systemMessage\":\"no\"}'", .timeout_ms = 5000 },
    };
    var deny_set = Set.init(&deny_hooks);
    const deny = try fire(t.allocator, &deny_set, .{ .event = .PreToolUse, .tool = "bash" }, io);
    defer freeResults(t.allocator, deny);
    try t.expect(deny[0].blocked);
    try t.expectEqual(PermissionDecision.deny, deny[0].permission_decision.?);
    const reason = try blockedReason(t.allocator, deny, .PreToolUse);
    try t.expect(reason != null);
    defer t.allocator.free(reason.?);
    try t.expect(std.mem.indexOf(u8, reason.?, "no") != null);
}

test "hooks 34.14: PermissionRequest event parses and matches" {
    try t.expectEqual(Event.PermissionRequest, Event.parse("PermissionRequest").?);
    try t.expectEqual(Event.PermissionRequest, Event.parse("permission_request").?);
    const h = Hook{ .event = .PermissionRequest, .matcher = "bash", .command = "true" };
    try t.expect(matches(h, .{ .event = .PermissionRequest, .tool = "bash" }));
    try t.expect(!matches(h, .{ .event = .PermissionRequest, .tool = "write" }));
}
