//! Compact, read-only mission status for the TUI footer.
//!
//! The TUI must never read a live file on the paint path. `load` runs once at
//! startup (from the app's `Io`), copies a few scalars into a small `Info`, and
//! `compact` renders one ASCII line with no colour or ANSI. The footer paints
//! that cached string with the dim `theme.line` role.
//!
//! Only harness-owned state is read: `.mission/state.json`, `criteria.json`
//! and `tasks.json`. No inference from rendered UI strings.

const std = @import("std");
const dir = std.Io.Dir.cwd();

pub const Info = struct {
    status: []const u8 = "running",
    turn: usize = 0,
    max_turns: usize = 0,
    checks_green: usize = 0,
    checks: usize = 0,
    tasks_done: usize = 0,
    tasks: usize = 0,

    pub fn hasData(self: Info) bool {
        return self.checks > 0 or self.tasks > 0;
    }
};

fn objStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn objInt(obj: std.json.ObjectMap, key: []const u8) usize {
    const v = obj.get(key) orelse return 0;
    return switch (v) {
        .integer => if (v.integer > 0) @intCast(v.integer) else 0,
        .float => if (v.float > 0) @intFromFloat(v.float) else 0,
        .number_string => std.fmt.parseInt(usize, v.number_string, 10) catch 0,
        else => 0,
    };
}

fn readJson(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ?std.json.Parsed(std.json.Value) {
    const data = dir.readFileAlloc(io, path, gpa, .limited(1024 * 1024)) catch return null;
    defer gpa.free(data);
    return std.json.parseFromSlice(std.json.Value, gpa, data, .{}) catch null;
}

fn arrayLen(root: std.json.Value, key: []const u8) usize {
    if (root != .object) return 0;
    const v = root.object.get(key) orelse return 0;
    return if (v == .array) v.array.items.len else 0;
}

/// Loads a mission under `root` (a workspace containing `.mission/`).
/// Missing or malformed files are not an error: there is simply no status.
pub fn load(gpa: std.mem.Allocator, io: std.Io, root: []const u8) ?Info {
    const state_path = std.fmt.allocPrint(gpa, "{s}/.mission/state.json", .{root}) catch return null;
    defer gpa.free(state_path);
    var state = readJson(gpa, io, state_path) orelse return null;
    defer state.deinit();
    if (state.value != .object) return null;

    const criteria_path = std.fmt.allocPrint(gpa, "{s}/.mission/criteria.json", .{root}) catch return null;
    defer gpa.free(criteria_path);
    var criteria = readJson(gpa, io, criteria_path);
    defer if (criteria) |*c| c.deinit();

    const tasks_path = std.fmt.allocPrint(gpa, "{s}/.mission/tasks.json", .{root}) catch return null;
    defer gpa.free(tasks_path);
    var tasks = readJson(gpa, io, tasks_path);
    defer if (tasks) |*t| t.deinit();

    return .{
        .status = objStr(state.value.object, "status") orelse "running",
        .turn = objInt(state.value.object, "turn"),
        .max_turns = objInt(state.value.object, "max_turns"),
        .checks_green = objInt(state.value.object, "best_green"),
        .checks = if (criteria) |c| arrayLen(c.value, "checks") else 0,
        .tasks_done = objInt(state.value.object, "tasks_done"),
        .tasks = if (tasks) |t| arrayLen(t.value, "tasks") else 0,
    };
}

/// One short, terminal-safe line. No ETA: zode does not record per-turn timing.
pub fn compact(gpa: std.mem.Allocator, info: Info) ![]const u8 {
    return std.fmt.allocPrint(gpa, "mission {d}/{d} checks · {d}/{d} tasks", .{
        @min(info.checks_green, info.checks), info.checks,
        @min(info.tasks_done, info.tasks), info.tasks,
    });
}

test "missionstatus: compact line is bounded and clamps stale counters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const line = try compact(a, .{ .checks_green = 9, .checks = 4, .tasks_done = 5, .tasks = 2 });
    try std.testing.expectEqualStrings("mission 4/4 checks · 2/2 tasks", line);
    const empty = try compact(a, .{});
    try std.testing.expectEqualStrings("mission 0/0 checks · 0/0 tasks", empty);
}

test "missionstatus: load reads harness state from a mission workspace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = "/tmp/zode-missionstatus-test";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const meta = try std.fmt.allocPrint(a, "{s}/.mission", .{root});
    try std.Io.Dir.cwd().createDirPath(io, meta);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/state.json", .{meta}), .data = "{\"status\":\"running\",\"turn\":3,\"max_turns\":16,\"best_green\":2,\"tasks_done\":1}" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/criteria.json", .{meta}), .data = "{\"checks\":[{}, {}, {}, {}]}" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/tasks.json", .{meta}), .data = "{\"tasks\":[{}, {}]}" });

    const info = load(a, io, root) orelse return error.MissingStatus;
    try std.testing.expectEqualStrings("running", info.status);
    try std.testing.expectEqual(@as(usize, 3), info.turn);
    try std.testing.expectEqual(@as(usize, 4), info.checks);
    try std.testing.expectEqual(@as(usize, 2), info.checks_green);
    try std.testing.expectEqual(@as(usize, 2), info.tasks);
    try std.testing.expect(info.hasData());
}
