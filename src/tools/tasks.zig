/// The five task-graph tools: create, get, list, update, stop.
///
/// They are thin on purpose. Every rule about what a task list MEANS (an edge
/// written from either side, a completion that is refused while a prerequisite is
/// open, an id that is never reused) lives in `lib/taskstore.zig`, where it is pure
/// and tested with no tool, no session and no TUI in the way. What is here is the
/// translation: JSON in, one honest sentence out.
///
/// ## Why the result text is the real interface
///
/// A model that has to call `task_list` after every change to find out what
/// happened pays a round trip per edit. So each mutation reports the STATE it
/// produced, in the smallest number of words that answers the next question:
///
/// - `#3 created …` — the id, because that is the thing every later call needs.
/// - `#1 completed. #4 no longer waits on anything.` — the consequences. This is the
///   line that makes a dependency graph worth having: the model does not have to
///   re-derive what its own change unblocked.
/// - a refusal names the task that is in the way (`still waiting on #2`), because
///   "blocked" alone is a state and not an instruction.
///
/// `save` is reported IN the same sentence rather than as an error: the list in
/// memory is correct for the rest of the turn, and losing that because a checkpoint
/// file could not be written would be the tool lying about work it did.
const std = @import("std");
const common = @import("common.zig");
const taskstore = @import("../lib/taskstore.zig");

/// The statuses `task_update` accepts, including the spelling models arrive with
/// from elsewhere. `deleted` is not a status here — it is the removal, and it is
/// accepted as an alias so the model that sends it gets what it meant instead of a
/// lesson about this harness's vocabulary.
const accepted_statuses = "pending, in_progress, completed, deleted";

fn parseStatus(s: []const u8) ?taskstore.Status {
    if (std.mem.eql(u8, s, "deleted") or std.mem.eql(u8, s, "removed")) return null;
    return std.meta.stringToEnum(taskstore.Status, s);
}

fn isRemoval(s: []const u8) bool {
    return std.mem.eql(u8, s, "deleted") or std.mem.eql(u8, s, "removed");
}

fn requireId(obj: std.json.ObjectMap, arena: std.mem.Allocator) !u32 {
    _ = arena;
    const raw = common.getInt(obj, "id") orelse common.getInt(obj, "task_id") orelse return error.MissingTaskId;
    if (raw <= 0) return error.UnknownTask;
    if (raw > std.math.maxInt(u32)) return error.UnknownTask;
    return @intCast(raw);
}

/// A list of ids from either `key`. A non-integer inside it is refused rather than
/// dropped: a dependency silently missing from a chain is a task that looks ready
/// when it is not.
fn getIdList(arena: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]const u32 {
    const v = obj.get(key) orelse return &.{};
    if (v == .null) return &.{};
    var out: std.ArrayList(u32) = .empty;
    switch (v) {
        .integer => |i| {
            if (i <= 0 or i > std.math.maxInt(u32)) return error.UnknownTask;
            try out.append(arena, @intCast(i));
        },
        .array => |arr| {
            for (arr.items) |item| {
                if (item != .integer) return error.BadIds;
                if (item.integer <= 0 or item.integer > std.math.maxInt(u32)) return error.UnknownTask;
                try out.append(arena, @intCast(item.integer));
            }
        },
        else => return error.BadIds,
    }
    return out.items;
}

/// The ids that were waiting on `id` and have no open blocker left.
fn writeUnblocked(w: *std.Io.Writer, st: *taskstore.Store, id: u32) void {
    var any = false;
    for (st.items.items) |*t| {
        if (t.id == id or !t.isOpen()) continue;
        var waits = false;
        for (t.blocked_by.items) |b| {
            if (b == id) waits = true;
        }
        if (!waits) continue;
        if (st.hasOpenBlocker(t.id)) continue;
        if (!any) {
            w.writeAll(" ") catch {};
            any = true;
        } else w.writeAll(", ") catch {};
        w.print("#{d}", .{t.id}) catch {};
    }
    if (any) w.writeAll(" no longer wait on anything.") catch {};
}

fn writeSaveNote(w: *std.Io.Writer, io: std.Io, st: *taskstore.Store) void {
    st.save(io) catch |err| {
        w.print(" [the list could not be saved: {t}. It is correct for this turn; the file will be written again on the next change.]", .{err}) catch {};
    };
}

fn writeBlockedByNote(w: *std.Io.Writer, st: *taskstore.Store, id: u32) void {
    var any = false;
    for (st.items.items) |*t| {
        if (t.id != id) continue;
        for (t.blocked_by.items) |b| {
            const blocker = st.get(b) orelse continue;
            if (!blocker.isOpen()) continue;
            if (!any) {
                w.writeAll(" waiting on: ") catch {};
                any = true;
            } else w.writeAll(", ") catch {};
            w.print("#{d}", .{b}) catch {};
        }
    }
    if (any) w.writeAll(".") catch {};
}

// ── the tools ───────────────────────────────────────────────────

pub fn toolTaskCreate(
    io: std.Io,
    store: ?*taskstore.Store,
    obj: std.json.ObjectMap,
    arena: std.mem.Allocator,
) ![]const u8 {
    const st = store orelse return error.NoTaskStore;
    const subject = common.getStr(obj, "subject") orelse common.getStr(obj, "title") orelse return error.EmptySubject;
    const description = common.getStr(obj, "description") orelse "";

    // The edges are resolved BEFORE the task exists, because a create that has to be
    // rolled back is a create that hands out an id for a task nobody can find.
    const blocks = try getIdList(arena, obj, "blocks");

    const id = try st.create(subject, description);

    var out = std.Io.Writer.Allocating.init(arena);
    const w = &out.writer;
    try w.print("#{d} created (pending, unassigned): {s}", .{ id, st.get(id).?.subject });
    if (blocks.len > 0) {
        for (blocks) |b| {
            _ = st.link(id, b) catch |err| switch (err) {
                error.UnknownTask => {
                    try w.print(" [{d} does not exist, so that edge was not made]", .{b});
                    continue;
                },
                else => return err,
            };
        }
        try w.print("; blocks ", .{});
        for (blocks, 0..) |b, i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("#{d}", .{b});
        }
        try w.writeAll(".");
    }
    try w.writeAll(" Claim it with task_update (status in_progress, owner main) when you start it.");
    writeSaveNote(w, io, st);
    return out.written();
}

pub fn toolTaskGet(store: ?*taskstore.Store, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const st = store orelse return error.NoTaskStore;
    const id = try requireId(obj, arena);
    return st.details(arena, id);
}

pub fn toolTaskList(store: ?*taskstore.Store, arena: std.mem.Allocator) ![]const u8 {
    const st = store orelse return error.NoTaskStore;
    return st.summary(arena);
}

pub fn toolTaskUpdate(
    io: std.Io,
    store: ?*taskstore.Store,
    obj: std.json.ObjectMap,
    arena: std.mem.Allocator,
) ![]const u8 {
    const st = store orelse return error.NoTaskStore;
    const id = try requireId(obj, arena);
    const subject = common.getStr(obj, "subject");
    const description = common.getStr(obj, "description");
    const owner = common.getStr(obj, "owner");
    const blocks = try getIdList(arena, obj, "add_blocks");
    const blocked_by = try getIdList(arena, obj, "add_blocked_by");
    const status_text = common.getStr(obj, "status");

    // An alias, not a second way of doing things: `status: deleted` arrives from
    // models trained on another harness, and it means exactly what `task_stop` does.
    if (status_text) |s| {
        if (isRemoval(s)) return toolTaskStop(io, st, obj, arena);
    }
    var status: ?taskstore.Status = null;
    if (status_text) |s| {
        status = parseStatus(s) orelse return error.BadStatus;
    }

    // ── validate everything, then apply ──
    //
    // A partial update is worse than a refusal: the model sends three changes, reads
    // an error, and cannot tell which of the three happened. So every id is resolved
    // and every impossible edge is rejected BEFORE the first field is written.
    if (st.get(id) == null) return error.UnknownTask;
    for (blocks) |b| {
        if (b == id) return error.SelfEdge;
        if (st.get(b) == null) return error.UnknownTask;
    }
    for (blocked_by) |b| {
        if (b == id) return error.SelfEdge;
        if (st.get(b) == null) return error.UnknownTask;
    }
    if (subject != null) {
        const clean = std.mem.trim(u8, subject.?, " \t\r\n");
        if (clean.len == 0) return error.EmptySubject;
        if (clean.len > taskstore.max_subject) return error.SubjectTooLong;
    }
    if (description) |d| {
        if (d.len > taskstore.max_description) return error.DescriptionTooLong;
    }

    var out = std.Io.Writer.Allocating.init(arena);
    const w = &out.writer;
    try w.print("#{d}", .{id});
    var wrote_any = false;

    if (subject) |s| {
        try st.setSubject(id, s);
        try w.print(" subject now \"{s}\"", .{st.get(id).?.subject});
        wrote_any = true;
    }
    if (description) |d| {
        try st.setDescription(id, d);
        try w.writeAll(" description updated");
        wrote_any = true;
    }
    if (owner) |o| {
        try st.setOwner(id, o);
        if (st.get(id).?.owner) |now| {
            try w.print(" owner {s}", .{now});
        } else try w.writeAll(" owner cleared");
        wrote_any = true;
    }
    for (blocks) |b| {
        try st.link(id, b);
        try w.print(" blocks #{d}", .{b});
        wrote_any = true;
    }
    for (blocked_by) |b| {
        try st.link(b, id);
        try w.print(" waits on #{d}", .{b});
        wrote_any = true;
    }

    if (status) |s| {
        st.setStatus(id, s) catch |err| {
            // The refusal keeps the sentence the model needs: which task is in the way.
            if (err == error.OwnerRequired) {
                try w.print(" — cannot start it with no owner: send owner (\"{s}\" for your own work) in the same call.", .{taskstore.default_owner});
                writeSaveNote(w, io, st);
                return out.written();
            }
            if (err == error.BlockedByOpen) {
                try w.writeAll(" — not completed:");
                writeBlockedByNote(w, st, id);
                try w.writeAll(" Those have to be done first (or removed with task_stop).");
                writeSaveNote(w, io, st);
                return out.written();
            }
            return err;
        };
        try w.print(" status {s}", .{s.name()});
        wrote_any = true;
        if (s == .completed) writeUnblocked(w, st, id);
    }

    if (!wrote_any) try w.writeAll(" — nothing to change: send status, subject, description, owner, add_blocks or add_blocked_by.");
    writeSaveNote(w, io, st);
    return out.written();
}

pub fn toolTaskStop(
    io: std.Io,
    store: ?*taskstore.Store,
    obj: std.json.ObjectMap,
    arena: std.mem.Allocator,
) ![]const u8 {
    const st = store orelse return error.NoTaskStore;
    const id = try requireId(obj, arena);
    const reason = common.getStr(obj, "reason");
    const was = st.get(id) orelse return error.UnknownTask;
    // COPIED OUT BEFORE the removal, and the copy is not a nicety: `was` points into
    // the store's list and `remove` frees the task it points at, so reading the
    // subject afterwards is a use-after-free that shows up as a segfault while
    // printing a sentence about a task nobody has any more.
    const subject = try arena.dupe(u8, was.subject);
    const status_was = was.status;

    // The edges, read BEFORE they go. Collected as ids and not as a count: knowing
    // that one task was waiting is worth less than knowing which one, and the whole
    // reason to remove a task is what it does to the ones around it.
    var waiters: std.ArrayList(u32) = .empty;
    var waited_on: std.ArrayList(u32) = .empty;
    for (st.items.items) |*t| {
        if (t.id == id) {
            for (t.blocked_by.items) |b| try waited_on.append(arena, b);
            continue;
        }
        // A task whose `blocked_by` names this one is waiting on it.
        for (t.blocked_by.items) |b| {
            if (b == id) try waiters.append(arena, t.id);
        }
    }

    try st.remove(id);

    var out = std.Io.Writer.Allocating.init(arena);
    const w = &out.writer;
    try w.print("#{d} removed ({s}): {s}.", .{ id, status_was.name(), subject });
    if (reason) |r| {
        try w.print(" Reason: {s}", .{r});
    }
    if (waiters.items.len > 0) {
        try w.writeAll(" No longer waiting on it: ");
        for (waiters.items, 0..) |other, k| {
            if (k > 0) try w.writeAll(", ");
            try w.print("#{d}", .{other});
        }
        try w.writeAll(".");
    } else {
        try w.writeAll(" Nothing was waiting on it.");
    }
    if (waited_on.items.len > 0) {
        try w.writeAll(" It was itself waiting on ");
        for (waited_on.items, 0..) |other, k| {
            if (k > 0) try w.writeAll(", ");
            try w.print("#{d}", .{other});
        }
        try w.writeAll(", which are untouched.");
    }
    writeSaveNote(w, io, st);
    return out.written();
}

// ── tests ────────────────────────────────────────────────────────

const testing = std.testing;

fn args(arena: std.mem.Allocator, comptime fmt: []const u8, a: anytype) !std.json.ObjectMap {
    const text = try std.fmt.allocPrint(arena, fmt, a);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    return v.object;
}

test "task_create returns the id and the edges it made" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var st = taskstore.Store{ .gpa = testing.allocator };
    defer st.deinit();

    const first = try toolTaskCreate(testing.io, &st, try args(arena, "{{\"subject\":\"Wire it\"}}", .{}), arena);
    try testing.expect(std.mem.indexOf(u8, first, "#1 created") != null);
    // The nudge is in the result because the owner rule is enforced at update time,
    // and finding out then costs a round trip that a sentence here prevents.
    try testing.expect(std.mem.indexOf(u8, first, "owner main") != null);

    // A create that names an edge to a task that does not exist keeps the task and
    // DROPS the edge, saying so: refusing the whole create would throw away work the
    // model did describe correctly.
    const second = try toolTaskCreate(testing.io, &st, try args(arena, "{{\"subject\":\"Then\",\"blocks\":[1,9]}}", .{}), arena);
    try testing.expect(std.mem.indexOf(u8, second, "#2 created") != null);
    try testing.expect(std.mem.indexOf(u8, second, "9 does not exist") != null);
    try testing.expect(std.mem.indexOf(u8, second, "blocks #1") != null);

    // `blocks: [1]` on the NEW task means task 1 cannot start until this one is done,
    // so the edge shows on #1 and not on #2 — which is the direction a wrong
    // implementation gets backwards.
    const list = try toolTaskList(&st, arena);
    try testing.expect(std.mem.indexOf(u8, list, "#1 [pending] (unassigned) — Wire it (waiting on #2)") != null);
}

test "task_create without a subject is refused, and the list stays empty" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var st = taskstore.Store{ .gpa = testing.allocator };
    defer st.deinit();
    try testing.expectError(error.EmptySubject, toolTaskCreate(testing.io, &st, try args(arena, "{{\"description\":\"x\"}}", .{}), arena));
    try testing.expectEqual(@as(usize, 0), st.count());
}

test "task_update applies several fields at once and names what it unblocked" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var st = taskstore.Store{ .gpa = testing.allocator };
    defer st.deinit();
    _ = try st.create("First", "");
    _ = try st.create("Second", "");
    try st.link(1, 2);

    const started = try toolTaskUpdate(testing.io, &st, try args(arena, "{{\"id\":1,\"status\":\"in_progress\",\"owner\":\"main\"}}", .{}), arena);
    try testing.expect(std.mem.indexOf(u8, started, "status in_progress") != null);
    try testing.expect(std.mem.indexOf(u8, started, "owner main") != null);

    const done = try toolTaskUpdate(testing.io, &st, try args(arena, "{{\"id\":1,\"status\":\"completed\"}}", .{}), arena);
    try testing.expect(std.mem.indexOf(u8, done, "status completed") != null);
    // The consequence, in the same sentence: this is what saves the extra task_list.
    try testing.expect(std.mem.indexOf(u8, done, "#2 no longer wait on anything") != null);

    // And from the other side: the dependent can now be completed, which it could
    // not before.
    try st.setOwner(2, "main");
    const second = try toolTaskUpdate(testing.io, &st, try args(arena, "{{\"id\":2,\"status\":\"completed\"}}", .{}), arena);
    try testing.expect(std.mem.indexOf(u8, second, "status completed") != null);
}

test "task_update refuses a completion with the blocker named" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var st = taskstore.Store{ .gpa = testing.allocator };
    defer st.deinit();
    _ = try st.create("Schema first", "");
    _ = try st.create("Then the query", "");
    try st.link(1, 2);

    const refused = try toolTaskUpdate(testing.io, &st, try args(arena, "{{\"id\":2,\"status\":\"completed\"}}", .{}), arena);
    try testing.expect(std.mem.indexOf(u8, refused, "not completed") != null);
    // The instruction, not just the state.
    try testing.expect(std.mem.indexOf(u8, refused, "waiting on: #1") != null);
    try testing.expect(std.mem.indexOf(u8, refused, "removed with task_stop") != null);
    try testing.expectEqual(taskstore.Status.pending, st.get(2).?.status);
}

test "task_update: in_progress with no owner is refused with the fix in the sentence" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var st = taskstore.Store{ .gpa = testing.allocator };
    defer st.deinit();
    _ = try st.create("One", "");
    const out = try toolTaskUpdate(testing.io, &st, try args(arena, "{{\"id\":1,\"status\":\"in_progress\"}}", .{}), arena);
    try testing.expect(std.mem.indexOf(u8, out, "cannot start it with no owner") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"main\"") != null);
}

test "task_update: a bad argument changes NOTHING" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var st = taskstore.Store{ .gpa = testing.allocator };
    defer st.deinit();
    _ = try st.create("One", "");
    _ = try st.create("Two", "");

    // Two good changes and one impossible edge: the whole call is refused, so the
    // model never has to guess which half landed.
    try testing.expectError(error.UnknownTask, toolTaskUpdate(testing.io, &st, try args(arena, "{{\"id\":1,\"subject\":\"Renamed\",\"owner\":\"main\",\"add_blocks\":[99]}}", .{}), arena));
    try testing.expectEqualStrings("One", st.get(1).?.subject);
    try testing.expectEqual(@as(?[]const u8, null), st.get(1).?.owner);
    try testing.expectEqual(@as(usize, 0), st.get(1).?.blocks.items.len);

    try testing.expectError(error.SelfEdge, toolTaskUpdate(testing.io, &st, try args(arena, "{{\"id\":1,\"add_blocks\":[1]}}", .{}), arena));
    try testing.expectError(error.BadStatus, toolTaskUpdate(testing.io, &st, try args(arena, "{{\"id\":1,\"status\":\"doing\"}}", .{}), arena));
    try testing.expectError(error.BadIds, toolTaskUpdate(testing.io, &st, try args(arena, "{{\"id\":1,\"add_blocks\":[\"x\"]}}", .{}), arena));
    try testing.expectError(error.UnknownTask, toolTaskUpdate(testing.io, &st, try args(arena, "{{\"id\":77,\"status\":\"completed\"}}", .{}), arena));
    // And no task was touched.
    try testing.expectEqual(taskstore.Status.pending, st.get(1).?.status);
}

test "task_update: status deleted is the removal, not a lesson about vocabulary" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var st = taskstore.Store{ .gpa = testing.allocator };
    defer st.deinit();
    _ = try st.create("One", "");
    _ = try st.create("Two", "");
    try st.link(1, 2);
    const out = try toolTaskUpdate(testing.io, &st, try args(arena, "{{\"id\":1,\"status\":\"deleted\"}}", .{}), arena);
    try testing.expect(std.mem.indexOf(u8, out, "#1 removed") != null);
    try testing.expect(std.mem.indexOf(u8, out, "No longer waiting on it: #2.") != null);
    try testing.expectEqual(@as(?*const taskstore.Task, null), st.get(1));
}

test "task_stop removes the task, reports the edges and touches nothing else" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var st = taskstore.Store{ .gpa = testing.allocator };
    defer st.deinit();
    _ = try st.create("Base", "");
    _ = try st.create("Middle", "");
    _ = try st.create("Top", "");
    try st.link(1, 2);
    try st.link(2, 3);

    const out = try toolTaskStop(testing.io, &st, try args(arena, "{{\"id\":2,\"reason\":\"superseded\"}}", .{}), arena);
    try testing.expect(std.mem.indexOf(u8, out, "#2 removed (pending): Middle.") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Reason: superseded") != null);
    // Both directions, by id: who was waiting on it (task 3) and what it was itself
    // waiting on (task 1). A count would not tell the model which edge moved.
    try testing.expect(std.mem.indexOf(u8, out, "No longer waiting on it: #3.") != null);
    try testing.expect(std.mem.indexOf(u8, out, "It was itself waiting on #1, which are untouched.") != null);
    try testing.expectEqual(@as(usize, 2), st.count());
    try testing.expectEqual(@as(usize, 0), st.get(3).?.blocked_by.items.len);
}

test "task tools: with no store they say so instead of pretending" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.NoTaskStore, toolTaskList(null, arena));
    try testing.expectError(error.NoTaskStore, toolTaskGet(null, try args(arena, "{{\"id\":1}}", .{}), arena));
    try testing.expectError(error.NoTaskStore, toolTaskCreate(testing.io, null, try args(arena, "{{\"subject\":\"x\"}}", .{}), arena));
    try testing.expectError(error.NoTaskStore, toolTaskUpdate(testing.io, null, try args(arena, "{{\"id\":1}}", .{}), arena));
    try testing.expectError(error.NoTaskStore, toolTaskStop(testing.io, null, try args(arena, "{{\"id\":1}}", .{}), arena));
}

test "task_list is the whole list in one line per task, and says how to start" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var st = taskstore.Store{ .gpa = testing.allocator };
    defer st.deinit();
    const empty = try toolTaskList(&st, arena);
    try testing.expect(std.mem.indexOf(u8, empty, "task_create") != null);
}
