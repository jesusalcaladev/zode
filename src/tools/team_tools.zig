//! Thin tool layer for Phase 20 team mode: the four tools the model calls,
//! over the pure `lib/team.zig` store. Same shape as `tools/tasks.zig`.

const std = @import("std");
const team_mod = @import("../lib/team.zig");
const common = @import("common.zig");

pub fn toolTeamCreate(team: ?*team_mod.Team, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const store = team orelse return error.NoTeam;
    const name = common.getStr(obj, "name") orelse return error.InvalidName;
    try store.create(name);
    return std.fmt.allocPrint(arena,
        "team \"{s}\" created (Team equals TaskList). Teammates start read-only; use `send_message` to talk to them and `task_create` to fill the shared list.",
        .{name},
    );
}

pub fn toolTeamDelete(io: std.Io, team: ?*team_mod.Team, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    _ = io;
    _ = obj;
    const store = team orelse return error.NoTeam;
    try store.requestShutdown();
    const n = store.members.items.len;
    const out = try std.fmt.allocPrint(arena,
        "team \"{s}\" shutdown requested for {d} teammate(s). They acknowledge once each; the harness sweeps any that do not answer on exit.",
        .{ store.name, n },
    );
    // The roster is cleared only after the acknowledgement sweep (Phase 20
    // shutdown flow); here we mark it and return the message. A second call
    // is a named error until the team is reset on exit.
    return out;
}

pub fn toolSendMessage(team: ?*team_mod.Team, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const store = team orelse return error.NoTeam;
    const to = common.getStr(obj, "to") orelse return error.UnknownTeammate;
    const message = common.getStr(obj, "message") orelse return error.EmptyMessage;
    const reached = try store.send("lead", to, message);
    if (std.mem.eql(u8, to, "*")) {
        return std.fmt.allocPrint(arena,
            "broadcast to {d} teammate(s) (explicitly expensive: one delivery each).", .{reached});
    }
    return std.fmt.allocPrint(arena, "message delivered to {s}.", .{to});
}

pub fn toolTeamStatus(team: ?*team_mod.Team, arena: std.mem.Allocator) ![]const u8 {
    const store = team orelse return error.NoTeam;
    return store.summary(arena);
}

test "team tools: create, message by name/broadcast and status" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var store = team_mod.Team.init(a);
    defer store.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"name\":\"builders\"}", .{});
    defer parsed.deinit();
    const r1 = try toolTeamCreate(&store, parsed.value.object, a);
    try std.testing.expect(std.mem.indexOf(u8, r1, "builders") != null);
    try store.add("alice", false);
    try store.add("bob", false);

    var p2 = try std.json.parseFromSlice(std.json.Value, a, "{\"to\":\"alice\",\"message\":\"hi\"}", .{});
    defer p2.deinit();
    const r2 = try toolSendMessage(&store, p2.value.object, a);
    try std.testing.expect(std.mem.indexOf(u8, r2, "alice") != null);

    var p3 = try std.json.parseFromSlice(std.json.Value, a, "{\"to\":\"*\",\"message\":\"all\"}", .{});
    defer p3.deinit();
    const r3 = try toolSendMessage(&store, p3.value.object, a);
    try std.testing.expect(std.mem.indexOf(u8, r3, "2") != null);

    const status = try toolTeamStatus(&store, a);
    try std.testing.expect(std.mem.indexOf(u8, status, "builders") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "alice") != null);
}
