//! The structured task list: work items with an identity, a status, an owner and
//! dependencies.
//!
//! ## Why this exists next to `todo`
//!
//! `todo` is what the HUMAN watches: an ordered list of steps, no identity, and it
//! exists to be read. This is what the AGENT coordinates on: every item has an id
//! that survives an edit, a status that says who is on it, and edges that say what
//! cannot start yet. A twelve-step plan is a plan; "task 7 is blocked by task 3" is
//! a fact about the work, and a list without ids cannot express it.
//!
//! They are not two views of one thing and merging them would lose both: the plan is
//! rewritten top to bottom every time the model re-reads its own steps (that is what
//! makes it a good on-screen list), and a task list that gets rewritten loses the
//! identity the edges are made of.
//!
//! ## The one invariant worth the whole file
//!
//! **`blocked_by` is DERIVED, never typed twice.** `link(A, B)` writes `B` into
//! `A.blocks` and `A` into `B.blocked_by`, in one call, and nothing else may write
//! either list. Two views of one edge cannot disagree, so `task_list` can be built
//! from either side and a question like "what is waiting on this?" is answered by a
//! list that was maintained by the machine rather than by two hand-written updates
//! that a model can send one of.
//!
//! That is also why completing a blocker "unblocks" without any code that unblocks
//! anything: the edge stays, and what a reader is shown is the edge to a task that is
//! still OPEN. There is no derived state to repair because nothing is derived twice.
//!
//! ## Persistence
//!
//! One JSON file next to the session it belongs to (`sessions/zode-<id>.tasks.json`,
//! see `pathForSession`). It is written 0600 for the same reason the session is: it
//! is a transcript of what someone was working on, and `createFile` takes no mode, so
//! the mode is set on the OPEN file (never `create` + `chmod`, which leaves a window
//! where the list exists world-readable).
//!
//! The shape the roadmap drew was `sessions/<id>/tasks.json`, a DIRECTORY per session.
//! One flat file is better for the same reason `/clean` exists: most sessions have no
//! task list at all, and a directory per session is 58 empty directories that another
//! tool then has to know how to walk. Same prefix as the session, so `resume` and
//! `/clean` keep matching by name and nothing has to learn a second layout.
//!
//! A file that cannot be read is NOT fatal and is NOT silent: the store starts empty
//! and raises `fresh_after_corrupt`, which every tool result carries until the next
//! write. A list that quietly came back empty is how a model re-does work it had
//! already tracked.
const std = @import("std");

pub const Status = enum {
    pending,
    in_progress,
    completed,

    pub fn name(self: Status) []const u8 {
        return switch (self) {
            .pending => "pending",
            .in_progress => "in_progress",
            .completed => "completed",
        };
    }

    /// An unknown word is `pending`, not an error: the step is not wrong, it is
    /// mislabelled, and refusing the whole file over a status the harness itself
    /// renamed would lose work that was written correctly.
    pub fn parse(s: []const u8) Status {
        return std.meta.stringToEnum(Status, s) orelse .pending;
    }
};

/// The owner a single-agent session uses when it starts a task. See `setStatus`.
pub const default_owner: []const u8 = "main";

pub const max_tasks: usize = 64;
pub const max_subject: usize = 160;
pub const max_description: usize = 4000;

/// 0600 on the open file. Same reasoning as `session_mode`.
pub const file_mode: std.Io.File.Permissions = @enumFromInt(0o600);

pub const Task = struct {
    id: u32,
    subject: []const u8,
    description: []const u8 = "",
    status: Status = .pending,
    owner: ?[]const u8 = null,
    /// Ids this task must finish before.
    blocks: std.ArrayList(u32) = .empty,
    /// Ids that must finish before this one. Maintained ONLY by `link`.
    blocked_by: std.ArrayList(u32) = .empty,

    pub fn isOpen(self: *const Task) bool {
        return self.status != .completed;
    }
};

fn freeTask(gpa: std.mem.Allocator, t: *Task) void {
    gpa.free(t.subject);
    gpa.free(t.description);
    if (t.owner) |o| gpa.free(o);
    t.blocks.deinit(gpa);
    t.blocked_by.deinit(gpa);
    t.* = undefined;
}

/// Adds `v` if it is not there. Returns whether it was added, so a caller with a
/// second allocation to make can undo this one if that fails.
fn addUnique(gpa: std.mem.Allocator, list: *std.ArrayList(u32), v: u32) !bool {
    for (list.items) |x| if (x == v) return false;
    try list.append(gpa, v);
    return true;
}

fn removeValue(list: *std.ArrayList(u32), v: u32) void {
    for (list.items, 0..) |x, i| {
        if (x == v) {
            _ = list.orderedRemove(i);
            return;
        }
    }
}

pub const Store = struct {
    /// `page_allocator` and NOT `undefined`. `bgproc` learned this the hard way: a
    /// default of `undefined` frees through a garbage vtable and the failure shows up
    /// as a general protection fault in a test that merely built the struct. An
    /// allocator that is merely wrong cannot fault.
    gpa: std.mem.Allocator = std.heap.page_allocator,
    items: std.ArrayList(Task) = .empty,
    next_id: u32 = 1,
    /// Where the list persists. Empty means memory-only (which is what a headless run
    /// with no session, and a test, want).
    path: []const u8 = "",
    /// The saved list existed and could not be read, and the list was started fresh.
    /// Carried into every result until the next successful write.
    fresh_after_corrupt: bool = false,

    pub fn deinit(self: *Store) void {
        self.clearItems();
        // `clearRetainingCapacity` keeps the capacity on purpose (a store that is
        // emptied by `/new` should not reallocate on the next task), so the buffer
        // has to be released here or the store leaks one allocation per lifetime.
        self.items.deinit(self.gpa);
        if (self.path.len > 0) self.gpa.free(self.path);
        self.path = "";
    }

    fn clearItems(self: *Store) void {
        for (self.items.items) |*t| freeTask(self.gpa, t);
        // `clearRetainingCapacity` memsets the slots, which is harmless ONLY because
        // everything owned was already released above. Keeping a slice of `items`
        // across this call is the documented way to corrupt a session; nothing here
        // does.
        self.items.clearRetainingCapacity();
        self.next_id = 1;
    }

    pub fn count(self: *const Store) usize {
        return self.items.items.len;
    }

    pub fn indexOf(self: *const Store, id: u32) ?usize {
        for (self.items.items, 0..) |t, i| if (t.id == id) return i;
        return null;
    }

    pub fn get(self: *const Store, id: u32) ?*const Task {
        const i = self.indexOf(id) orelse return null;
        return &self.items.items[i];
    }

    pub fn create(self: *Store, subject: []const u8, description: []const u8) !u32 {
        const subj = std.mem.trim(u8, subject, " \t\r\n");
        if (subj.len == 0) return error.EmptySubject;
        if (subj.len > max_subject) return error.SubjectTooLong;
        const desc = std.mem.trim(u8, description, " \t\r\n");
        if (desc.len > max_description) return error.DescriptionTooLong;
        if (self.items.items.len >= max_tasks) return error.TooManyTasks;

        const s_copy = try self.gpa.dupe(u8, subj);
        errdefer self.gpa.free(s_copy);
        const d_copy = try self.gpa.dupe(u8, desc);
        errdefer self.gpa.free(d_copy);

        const id = self.next_id;
        try self.items.append(self.gpa, .{ .id = id, .subject = s_copy, .description = d_copy });
        // A counter, never a slot: an id that is freed and reused would make a stale
        // reference land on a different task, which is the worst way for a
        // dependency to be wrong.
        self.next_id += 1;
        return id;
    }

    pub fn setStatus(self: *Store, id: u32, status: Status) !void {
        const i = self.indexOf(id) orelse return error.UnknownTask;
        // "Who is working on this" must never be ambiguous. In a single-agent session
        // the answer is trivially the agent, and the model can say so in one word
        // (`owner: "main"`) — what is refused is the case where nobody looked at the
        // question, because that is the state a team cannot recover from.
        if (status == .in_progress and self.items.items[i].owner == null) return error.OwnerRequired;
        // A task cannot be called done while what it WAITS ON is still open: that is
        // the one completion that produces a half-finished chain nobody notices.
        //
        // It is deliberately NOT the other direction (refusing to complete a task
        // whose dependents are open): completing a blocker is the whole point of a
        // dependency, and it is what unblocks the list in the same update. The
        // roadmap's sentence for this rule reads "cannot complete while it blocks an
        // open one", and that direction cannot be true together with its own second
        // half — "completing a blocker unblocks the list" has to be an ALLOWED
        // completion. This is the reading that makes both halves true at once.
        if (status == .completed) {
            for (self.items.items[i].blocked_by.items) |b| {
                if (self.indexOf(b)) |j| {
                    if (self.items.items[j].isOpen()) return error.BlockedByOpen;
                }
            }
        }
        self.items.items[i].status = status;
    }

    /// `null` or an empty string clears the owner.
    pub fn setOwner(self: *Store, id: u32, owner: ?[]const u8) !void {
        const i = self.indexOf(id) orelse return error.UnknownTask;
        const clean = std.mem.trim(u8, owner orelse "", " \t\r\n");
        const copy: ?[]const u8 = if (clean.len == 0) null else try self.gpa.dupe(u8, clean);
        if (self.items.items[i].owner) |old| self.gpa.free(old);
        self.items.items[i].owner = copy;
    }

    pub fn setSubject(self: *Store, id: u32, subject: []const u8) !void {
        const i = self.indexOf(id) orelse return error.UnknownTask;
        const clean = std.mem.trim(u8, subject, " \t\r\n");
        if (clean.len == 0) return error.EmptySubject;
        if (clean.len > max_subject) return error.SubjectTooLong;
        const copy = try self.gpa.dupe(u8, clean);
        self.gpa.free(self.items.items[i].subject);
        self.items.items[i].subject = copy;
    }

    pub fn setDescription(self: *Store, id: u32, description: []const u8) !void {
        const i = self.indexOf(id) orelse return error.UnknownTask;
        const clean = std.mem.trim(u8, description, " \t\r\n");
        if (clean.len > max_description) return error.DescriptionTooLong;
        const copy = try self.gpa.dupe(u8, clean);
        self.gpa.free(self.items.items[i].description);
        self.items.items[i].description = copy;
    }

    /// The ONLY writer of either edge list: `from` blocks `to`.
    pub fn link(self: *Store, from: u32, to: u32) !void {
        if (from == to) return error.SelfEdge;
        const i = self.indexOf(from) orelse return error.UnknownTask;
        const j = self.indexOf(to) orelse return error.UnknownTask;
        const added = try addUnique(self.gpa, &self.items.items[i].blocks, to);
        errdefer if (added) removeValue(&self.items.items[i].blocks, to);
        _ = try addUnique(self.gpa, &self.items.items[j].blocked_by, from);
    }

    pub fn remove(self: *Store, id: u32) !void {
        const i = self.indexOf(id) orelse return error.UnknownTask;
        freeTask(self.gpa, &self.items.items[i]);
        _ = self.items.orderedRemove(i);
        // Every edge that pointed at it goes with it. A dangling id in a dependency
        // list is a task that can never be unblocked.
        for (self.items.items) |*t| {
            removeValue(&t.blocks, id);
            removeValue(&t.blocked_by, id);
        }
    }

    // ── rendering ──────────────────────────────────────────────
    //
    // The text IS the interface here: a task list the model cannot read in one pass
    // is a task list it will not use. Every line earns its place, and an empty list
    // says how to fix it instead of printing a table header over nothing.

    fn corruptNote(self: *const Store, w: *std.Io.Writer) !void {
        if (!self.fresh_after_corrupt) return;
        try w.writeAll("[the saved task list could not be read and was started fresh; it will be rewritten by the next change]\n");
    }

    fn writeRefs(self: *const Store, w: *std.Io.Writer, ids: []const u32) !void {
        var first = true;
        for (ids) |id| {
            if (self.get(id)) |t| {
                if (!t.isOpen()) continue;
            }
            if (!first) try w.writeAll(", ");
            try w.print("#{d}", .{id});
            first = false;
        }
    }

    fn blockedByList(self: *const Store, w: *std.Io.Writer, t: *const Task) !void {
        var any = false;
        for (t.blocked_by.items) |id| {
            if (self.get(id)) |b| {
                if (!b.isOpen()) continue;
            }
            if (any) try w.writeAll(", ");
            try w.print("#{d}", .{id});
            any = true;
        }
        if (!any) try w.writeAll("nothing");
    }

    /// The `task_list` result: one line per task, ids ascending, and the counts the
    /// model needs to see at a glance.
    ///
    /// `arena`, and the parameter is the whole contract: what comes back is NOT an
    /// exact-length allocation (the writer grows its buffer), so a caller that frees
    /// it by hand frees the wrong length. An arena makes that a non-question.
    pub fn summary(self: *const Store, arena: std.mem.Allocator) ![]const u8 {
        var out = std.Io.Writer.Allocating.init(arena);
        const w = &out.writer;
        try self.corruptNote(w);
        if (self.items.items.len == 0) {
            try w.writeAll("no tasks yet. Use task_create to add the first one.");
            return out.written();
        }

        var pending: usize = 0;
        var in_progress: usize = 0;
        var completed: usize = 0;
        var blocked: usize = 0;
        for (self.items.items) |t| {
            switch (t.status) {
                .pending => pending += 1,
                .in_progress => in_progress += 1,
                .completed => completed += 1,
            }
            if (t.isOpen()) {
                var has_open_blocker = false;
                for (t.blocked_by.items) |id| {
                    if (self.get(id)) |b| {
                        if (b.isOpen()) has_open_blocker = true;
                    }
                }
                if (has_open_blocker) blocked += 1;
            }
        }
        try w.print("{d} task{s} · {d} pending · {d} in progress · {d} completed", .{
            self.items.items.len,
            if (self.items.items.len == 1) "" else "s",
            pending,
            in_progress,
            completed,
        });
        if (blocked > 0) try w.print(" · {d} blocked", .{blocked});
        try w.writeAll("\n");

        for (self.items.items) |t| {
            try w.print("#{d} [{s}] ", .{ t.id, t.status.name() });
            if (t.owner) |o| {
                try w.print("{s} — ", .{o});
            } else {
                try w.writeAll("(unassigned) — ");
            }
            try w.writeAll(t.subject);
            if (t.isOpen()) {
                var any = false;
                for (t.blocked_by.items) |id| {
                    if (self.get(id)) |b| {
                        if (!b.isOpen()) continue;
                    }
                    if (!any) {
                        try w.writeAll(" (waiting on ");
                        any = true;
                    } else try w.writeAll(", ");
                    try w.print("#{d}", .{id});
                }
                if (any) try w.writeAll(")");
            }
            try w.writeAll("\n");
        }
        return out.written();
    }

    /// The `task_get` result: everything about one task, including the edges both
    /// ways, because that is the question a dependency is asked.
    pub fn details(self: *const Store, arena: std.mem.Allocator, id: u32) ![]const u8 {
        const t = self.get(id) orelse return error.UnknownTask;
        var out = std.Io.Writer.Allocating.init(arena);
        const w = &out.writer;
        try w.print("#{d} {s}\n", .{ t.id, t.subject });
        try w.print("status: {s}\n", .{t.status.name()});
        if (t.owner) |o| {
            try w.print("owner: {s}\n", .{o});
        } else {
            try w.writeAll("owner: (unassigned)\n");
        }
        if (t.blocked_by.items.len > 0) {
            try w.writeAll("waiting on: ");
            try self.blockedByList(w, t);
            try w.writeAll("\n");
        }
        if (t.blocks.items.len > 0) {
            try w.writeAll("blocks: ");
            try self.writeRefs(w, t.blocks.items);
            const only_closed = blk: {
                for (t.blocks.items) |b| {
                    if (self.get(b)) |x| {
                        if (x.isOpen()) break :blk false;
                    }
                }
                break :blk true;
            };
            if (only_closed) try w.writeAll(" (all of them completed)");
            try w.writeAll("\n");
        }
        if (t.description.len > 0) {
            try w.writeAll("description:\n");
            try w.writeAll(t.description);
            try w.writeAll("\n");
        }
        return out.written();
    }

    /// Is anything this task waits on still open? Allocation-free, because it is
    /// asked inside a loop that renders another task's consequences.
    pub fn hasOpenBlocker(self: *const Store, id: u32) bool {
        const t = self.get(id) orelse return false;
        for (t.blocked_by.items) |b| {
            if (self.get(b)) |blocker| {
                if (blocker.isOpen()) return true;
            }
        }
        return false;
    }

    /// The ids this task is still waiting on, so a refusal can name them in the
    /// budget the caller owns.
    pub fn openBlockers(self: *const Store, id: u32, arena: std.mem.Allocator) !?[]const u8 {
        const t = self.get(id) orelse return error.UnknownTask;
        if (t.blocked_by.items.len == 0) return null;
        var out = std.Io.Writer.Allocating.init(arena);
        const w = &out.writer;
        try self.blockedByList(w, t);
        const text = out.written();
        if (std.mem.eql(u8, text, "nothing")) return null;
        return text;
    }

    // ── persistence ────────────────────────────────────────────

    const file_version: i64 = 1;

    /// The exact-length slice, NOT `written()`: this one is freed with the store's own
    /// allocator (`save` does), and freeing a slice shorter than the allocation is an
    /// `Invalid free` — the length has to be the one that was allocated.
    pub fn toJson(self: *const Store, arena: std.mem.Allocator) ![]u8 {
        var out = std.Io.Writer.Allocating.init(arena);
        defer out.deinit();
        const w = &out.writer;
        try w.print("{{\"version\":{d},\"next_id\":{d},\"tasks\":[", .{ file_version, self.next_id });
        for (self.items.items, 0..) |t, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("{{\"id\":{d},\"subject\":", .{t.id});
            try writeJsonString(w, t.subject);
            try w.writeAll(",\"description\":");
            try writeJsonString(w, t.description);
            try w.print(",\"status\":\"{s}\",\"owner\":", .{t.status.name()});
            if (t.owner) |o| {
                try writeJsonString(w, o);
            } else try w.writeAll("null");
            try w.writeAll(",\"blocks\":[");
            for (t.blocks.items, 0..) |b, k| {
                if (k > 0) try w.writeAll(",");
                try w.print("{d}", .{b});
            }
            try w.writeAll("],\"blocked_by\":[");
            for (t.blocked_by.items, 0..) |b, k| {
                if (k > 0) try w.writeAll(",");
                try w.print("{d}", .{b});
            }
            try w.writeAll("]}");
        }            try w.writeAll("]}\n");
        return out.toOwnedSlice();
    }

    pub fn fromJson(self: *Store, text: []const u8) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch
            return error.BadTaskFile;
        if (v != .object) return error.BadTaskFile;
        const obj = v.object;

        if (obj.get("version")) |ver| {
            if (ver != .integer or ver.integer != file_version) return error.BadTaskFile;
        }
        const tasks_v = obj.get("tasks") orelse return error.BadTaskFile;
        if (tasks_v != .array) return error.BadTaskFile;
        if (tasks_v.array.items.len > max_tasks) return error.BadTaskFile;

        // Everything is validated BEFORE the first item is written, so a file with a
        // broken entry at the end does not leave half a list behind — which is what a
        // refusal is supposed to prevent.
        for (tasks_v.array.items) |item| {
            if (item != .object) return error.BadTaskFile;
            const o = item.object;
            const id_v = o.get("id") orelse return error.BadTaskFile;
            if (id_v != .integer or id_v.integer <= 0) return error.BadTaskFile;
            const subj_v = o.get("subject") orelse return error.BadTaskFile;
            if (subj_v != .string or subj_v.string.len == 0) return error.BadTaskFile;
            if (o.get("description")) |d| {
                if (d != .string) return error.BadTaskFile;
            }
            if (o.get("owner")) |ow| {
                if (ow != .string and ow != .null) return error.BadTaskFile;
            }
            inline for (.{ "blocks", "blocked_by" }) |key| {
                if (o.get(key)) |arr| {
                    if (arr != .array) return error.BadTaskFile;
                    for (arr.array.items) |x| {
                        if (x != .integer or x.integer <= 0) return error.BadTaskFile;
                    }
                }
            }
        }

        self.clearItems();
        var max_id: u32 = 0;
        for (tasks_v.array.items) |item| {
            const o = item.object;
            const id: u32 = @intCast(o.get("id").?.integer);
            const desc = if (o.get("description")) |d| d.string else "";
            const new_id = try self.create(o.get("subject").?.string, desc);
            if (new_id != id) return error.BadTaskFile;
            const t = &self.items.items[self.items.items.len - 1];
            if (o.get("status")) |st| {
                if (st == .string) t.status = Status.parse(st.string);
            }
            if (o.get("owner")) |ow| {
                if (ow == .string) try self.setOwner(id, ow.string);
            }
            inline for (.{ .{ "blocks", "blocks" }, .{ "blocked_by", "blocked_by" } }) |pair| {
                if (o.get(pair[0])) |arr| {
                    for (arr.array.items) |x| {
                        const other: u32 = @intCast(x.integer);
                        if (comptime std.mem.eql(u8, pair[1], "blocks")) {
                            // `link` writes BOTH sides; the file already has both, so
                            // the second write is a no-op by construction (addUnique)
                            // and can never disagree with the first.
                            if (self.indexOf(other)) |_| try self.link(id, other);
                        } else {
                            if (self.indexOf(other)) |_| try self.link(other, id);
                        }
                    }
                }
            }
            if (id > max_id) max_id = id;
        }
        if (obj.get("next_id")) |n| {
            if (n == .integer and n.integer > 0) {
                const stored: u32 = @intCast(n.integer);
                if (stored > max_id + 1) self.next_id = stored;
            }
        }
    }

    /// Points the store at a session's file and loads it. Idempotent: calling it on
    /// every tool call is the point, because the session can change under it (`/new`,
    /// `--resume`) and a list bound to the previous session would be silently wrong.
    pub fn bind(self: *Store, io: std.Io, path: []const u8) void {
        if (self.path.len > 0 and std.mem.eql(u8, self.path, path)) return;
        self.clearItems();
        self.fresh_after_corrupt = false;
        if (self.path.len > 0) self.gpa.free(self.path);
        self.path = self.gpa.dupe(u8, path) catch "";
        if (self.path.len == 0) return;

        var dir = std.Io.Dir.cwd().openDir(io, ".", .{}) catch return;
        defer dir.close(io);
        const data = dir.readFileAlloc(io, self.path, self.gpa, .limited(1 << 20)) catch |err| {
            if (err != error.FileNotFound) self.fresh_after_corrupt = true;
            return;
        };
        defer self.gpa.free(data);
        self.fromJson(data) catch {
            self.clearItems();
            self.fresh_after_corrupt = true;
        };
    }

    /// Best-effort by design: the caller reports a failure, and the list in memory is
    /// still correct for the rest of the turn. A task list is derived state; the
    /// transcript of the conversation is what must not be lost.
    pub fn save(self: *Store, io: std.Io) !void {
        if (self.path.len == 0) return;
        const json = try self.toJson(self.gpa);
        defer self.gpa.free(json);

        var dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
        defer dir.close(io);
        const file = try dir.createFile(io, self.path, .{ .truncate = true });
        file.setPermissions(io, file_mode) catch {};
        defer file.close(io);
        try file.writeStreamingAll(io, json);
        self.fresh_after_corrupt = false;
    }
};

/// `sessions/zode-<id>.jsonl` -> `sessions/zode-<id>.tasks.json`.
///
/// Pure and separate because it is the only thing that ties the list to a session,
/// and a wrong guess here reads someone else's tasks (or nobody's) with no error.
/// It writes into the CALLER's buffer: the caller is an agent that binds on every
/// turn and has no reason to allocate to learn a path it derives from one it already
/// has. `error.NoSpaceLeft` means the buffer was too small, never a truncated path.
pub fn pathForSession(buf: []u8, session_path: []const u8) ![]const u8 {
    const stem = if (std.mem.endsWith(u8, session_path, ".jsonl"))
        session_path[0 .. session_path.len - ".jsonl".len]
    else if (std.mem.endsWith(u8, session_path, ".json"))
        session_path[0 .. session_path.len - ".json".len]
    else
        session_path;
    return std.fmt.bufPrint(buf, "{s}.tasks.json", .{stem});
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeAll("\"");
    var start: usize = 0;
    for (s, 0..) |c, i| {
        const esc: ?[]const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => null,
        };
        const e = esc orelse continue;
        if (i > start) try w.writeAll(s[start..i]);
        try w.writeAll(e);
        start = i + 1;
    }
    if (start < s.len) try w.writeAll(s[start..]);
    try w.writeAll("\"");
}

// ── tests ────────────────────────────────────────────────────────

const testing = std.testing;

fn newStore() Store {
    return Store{ .gpa = testing.allocator };
}

test "taskstore: create, list and get round trip with ascending ids" {
    var st = newStore();
    defer st.deinit();

    const a = try st.create("Fix the parser", "the crash on an empty line");
    const b = try st.create("Add tests", "");
    try testing.expectEqual(@as(u32, 1), a);
    try testing.expectEqual(@as(u32, 2), b);

    const t = st.get(a).?;
    try testing.expectEqual(Status.pending, t.status);
    try testing.expectEqual(@as(?[]const u8, null), t.owner);
    try testing.expectEqualStrings("the crash on an empty line", t.description);

    // The render functions take an arena (see `summary`), so the test does too.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const summary = try st.summary(arena_state.allocator());
    try testing.expect(std.mem.indexOf(u8, summary, "2 tasks") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "#1 [pending] (unassigned) — Fix the parser") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "#2 [pending] (unassigned) — Add tests") != null);
}

test "taskstore: an empty subject is refused, and a long one names the cap" {
    var st = newStore();
    defer st.deinit();
    try testing.expectError(error.EmptySubject, st.create("   ", "x"));
    var big: [max_subject + 1]u8 = undefined;
    @memset(&big, 'x');
    try testing.expectError(error.SubjectTooLong, st.create(&big, ""));
    try testing.expectEqual(@as(usize, 0), st.count());
}

test "taskstore: the list has a ceiling and it is a named error" {
    var st = newStore();
    defer st.deinit();
    var i: usize = 0;
    while (i < max_tasks) : (i += 1) {
        _ = try st.create("task", "");
    }
    try testing.expectError(error.TooManyTasks, st.create("one more", ""));
}

test "taskstore: in_progress without an owner is refused, with one it sticks" {
    var st = newStore();
    defer st.deinit();
    const id = try st.create("Wire it", "");
    try testing.expectError(error.OwnerRequired, st.setStatus(id, .in_progress));
    try testing.expectEqual(Status.pending, st.get(id).?.status);
    try st.setOwner(id, default_owner);
    try st.setStatus(id, .in_progress);
    try testing.expectEqual(Status.in_progress, st.get(id).?.status);
    // Clearing the owner does not undo the status: the task stays owned by nobody
    // and in progress, which is a state `task_list` shows as it is.
    try st.setOwner(id, "");
    try testing.expectEqual(@as(?[]const u8, null), st.get(id).?.owner);
}

test "taskstore: a task cannot be completed while what it waits on is open" {
    var st = newStore();
    defer st.deinit();
    const a = try st.create("A", "");
    const b = try st.create("B", "");
    // B waits on A.
    try st.link(a, b);
    try testing.expectError(error.BlockedByOpen, st.setStatus(b, .completed));

    // Completing the BLOCKER is allowed and is what frees the dependent — the
    // direction that makes a dependency chain finishable at all.
    try st.setStatus(a, .completed);
    try st.setStatus(b, .completed);
    try testing.expectEqual(Status.completed, st.get(b).?.status);
}

test "taskstore: an edge set from either side reads the same from both" {
    var st = newStore();
    defer st.deinit();
    const a = try st.create("A", "");
    const b = try st.create("B", "");
    try st.link(a, b);

    try testing.expectEqualSlices(u32, &.{b}, st.get(a).?.blocks.items);
    try testing.expectEqualSlices(u32, &.{a}, st.get(b).?.blocked_by.items);

    // Linking twice is not two edges: the model resending a dependency it already
    // sent must not build a list that reads "waiting on #1, #1".
    try st.link(a, b);
    try testing.expectEqual(@as(usize, 1), st.get(a).?.blocks.items.len);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const detail = try st.details(arena_state.allocator(), b);
    try testing.expect(std.mem.indexOf(u8, detail, "waiting on: #1") != null);
}

test "taskstore: a self edge and an unknown id are refused" {
    var st = newStore();
    defer st.deinit();
    const a = try st.create("A", "");
    try testing.expectError(error.SelfEdge, st.link(a, a));
    try testing.expectError(error.UnknownTask, st.link(a, 99));
    try testing.expectError(error.UnknownTask, st.link(99, a));
    try testing.expectError(error.UnknownTask, st.setStatus(99, .completed));
    try testing.expectEqual(@as(usize, 0), st.get(a).?.blocks.items.len);
}

test "taskstore: completing a blocker unblocks what waited on it, with no repair step" {
    var st = newStore();
    defer st.deinit();
    const a = try st.create("A", "");
    const b = try st.create("B", "");
    try st.link(a, b);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const summary_open = try st.summary(arena);
    try testing.expect(std.mem.indexOf(u8, summary_open, "1 blocked") != null);
    try testing.expect(std.mem.indexOf(u8, summary_open, "waiting on #1") != null);

    try st.setStatus(a, .completed);

    const summary_done = try st.summary(arena);
    // The edge is still in the file; what changed is that #1 is no longer OPEN, and
    // that is the definition of unblocked. No code had to rewrite the list.
    try testing.expect(std.mem.indexOf(u8, summary_done, "waiting on") == null);
    try testing.expect(std.mem.indexOf(u8, summary_done, "1 blocked") == null);
    try testing.expectEqual(@as(usize, 1), st.get(b).?.blocked_by.items.len);
    try testing.expectEqual(@as(?[]const u8, null), try st.openBlockers(b, arena));
}

test "taskstore: removing a task clears every edge that pointed at it" {
    var st = newStore();
    defer st.deinit();
    const a = try st.create("A", "");
    const b = try st.create("B", "");
    const c = try st.create("C", "");
    try st.link(a, b);
    try st.link(b, c);

    try st.remove(b);
    try testing.expectEqual(@as(?*const Task, null), st.get(b));
    try testing.expectEqual(@as(usize, 0), st.get(a).?.blocks.items.len);
    try testing.expectEqual(@as(usize, 0), st.get(c).?.blocked_by.items.len);
    // And the id is not reused.
    const d = try st.create("D", "");
    try testing.expectEqual(@as(u32, 4), d);
}

test "taskstore: the JSON round trip is byte-stable and keeps the edges" {
    var st = newStore();
    defer st.deinit();
    const a = try st.create("A", "line one\nline two \"quoted\"");
    const b = try st.create("B", "");
    try st.setOwner(a, "main");
    try st.setStatus(a, .in_progress);
    try st.link(a, b);

    const json = try st.toJson(testing.allocator);
    defer testing.allocator.free(json);

    var st2 = newStore();
    defer st2.deinit();
    try st2.fromJson(json);

    const json2 = try st2.toJson(testing.allocator);
    defer testing.allocator.free(json2);
    try testing.expectEqualStrings(json, json2);
    try testing.expectEqual(Status.in_progress, st2.get(a).?.status);
    try testing.expectEqualStrings("main", st2.get(a).?.owner.?);
    try testing.expectEqualSlices(u32, &.{b}, st2.get(a).?.blocks.items);
    try testing.expectEqualSlices(u32, &.{a}, st2.get(b).?.blocked_by.items);
    // next_id survives, so an id is never handed out twice across a restart. That is
    // what makes a `waiting on #1` written yesterday still mean task 1 today.
    const c = try st2.create("C", "");
    try testing.expectEqual(@as(u32, 3), c);
}

test "taskstore: an unreadable file is refused whole and named, never half-loaded" {
    var st = newStore();
    defer st.deinit();
    // Valid JSON, one broken entry at the END: the point is that nothing from the
    // good part survives, because a half list is a list that lies about the edges.
    const bad =
        "{\"version\":1,\"next_id\":3,\"tasks\":[" ++
        "{\"id\":1,\"subject\":\"A\",\"description\":\"\",\"status\":\"pending\",\"owner\":null,\"blocks\":[2],\"blocked_by\":[]}," ++
        "{\"id\":\"two\",\"subject\":\"B\"}]}";
    try testing.expectError(error.BadTaskFile, st.fromJson(bad));
    try testing.expectEqual(@as(usize, 0), st.count());

    try testing.expectError(error.BadTaskFile, st.fromJson("not json at all"));
    // A version from the future is refused rather than reinterpreted.
    try testing.expectError(error.BadTaskFile, st.fromJson("{\"version\":9,\"tasks\":[]}"));
}

test "taskstore: an unknown status in the file is pending, not corruption" {
    var st = newStore();
    defer st.deinit();
    try st.fromJson("{\"version\":1,\"tasks\":[{\"id\":1,\"subject\":\"A\",\"description\":\"d\",\"status\":\"doing it maybe\",\"owner\":null,\"blocks\":[],\"blocked_by\":[]}]}");
    try testing.expectEqual(@as(usize, 1), st.count());
    try testing.expectEqual(Status.pending, st.get(1).?.status);
    try testing.expectEqualStrings("d", st.get(1).?.description);
}

test "taskstore: pathForSession derives the file from the session it belongs to" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "sessions/zode-ab12cd34.tasks.json",
        try pathForSession(&buf, "sessions/zode-ab12cd34.jsonl"),
    );
    try testing.expectEqualStrings("/tmp/x/s.tasks.json", try pathForSession(&buf, "/tmp/x/s.json"));
    // Anything else gets the suffix appended: a session path this code does not
    // recognise still produces a per-session file rather than sharing one.
    try testing.expectEqualStrings("sessions/weird.tasks.json", try pathForSession(&buf, "sessions/weird"));
    // A buffer too small is an error, not half a path that would read another list.
    var small: [4]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, pathForSession(&small, "sessions/zode-ab12cd34.jsonl"));
}

test "taskstore: save and bind round-trip through a real file, and a broken file starts fresh" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = "/tmp/opencode/taskstore-roundtrip/zode-test.tasks.json";
    _ = std.Io.Dir.cwd().createDirPath(io, "/tmp/opencode/taskstore-roundtrip") catch {};
    std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var st = newStore();
    defer st.deinit();
    st.bind(io, path);
    try testing.expectEqual(@as(usize, 0), st.count());
    const a = try st.create("Persisted", "with a body");
    try st.setOwner(a, default_owner);
    try st.setStatus(a, .in_progress);
    try st.save(io);

    var st2 = newStore();
    defer st2.deinit();
    st2.bind(io, path);
    try testing.expectEqual(@as(usize, 1), st2.count());
    try testing.expectEqualStrings("Persisted", st2.get(a).?.subject);
    try testing.expectEqual(Status.in_progress, st2.get(a).?.status);
    try testing.expect(!st2.fresh_after_corrupt);

    // The mode is 0600: the list is what someone was working on, and a world-readable
    // one is the bug the session file already paid for.
    var dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer dir.close(io);
    const stat = try dir.statFile(io, path, .{});
    try testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(@intFromEnum(stat.permissions) & 0o777)));

    // A file that cannot be parsed leaves the store empty AND says so, because a list
    // that quietly comes back empty is how the same work gets done twice.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "{ this is not json" });
    var st3 = newStore();
    defer st3.deinit();
    st3.bind(io, path);
    try testing.expectEqual(@as(usize, 0), st3.count());
    try testing.expect(st3.fresh_after_corrupt);
    const note = try st3.summary(arena);
    try testing.expect(std.mem.indexOf(u8, note, "could not be read") != null);
    // And the note clears once the list is written again.
    _ = try st3.create("started over", "");
    try st3.save(io);
    try testing.expect(!st3.fresh_after_corrupt);
}
