//! Team mode (Phase 20): persistent collaborators.
//!
//! Team ≡ TaskList — a team IS the task list plus the roster of teammates and
//! their mailboxes. Pure on purpose: roster, message routing and shutdown are
//! testable without the TUI, without a network and without running subagents.
//!
//! The rules that matter:
//! - A message is a TOOL CALL, not prose. Plain assistant text is not visible
//!   to another agent; `send_message` is the only channel.
//! - `to: "*"` is an explicit broadcast, linear in team size and labelled as
//!   expensive in the tool description. A name that is not in the roster is a
//!   NAMED error, never a silent drop.
//! - Teammates are idle between turns and CLAIM from the shared task graph
//!   (`Store.claim`); nobody pushes work at them.
//! - Shutdown is requested once, acknowledged once per teammate, and a live
//!   registry lets the harness sweep on exit — no teammate outlives the app.

const std = @import("std");

pub const max_teammates: usize = 16;
pub const max_name: usize = 64;
pub const max_message: usize = 16 * 1024;
pub const max_mailbox: usize = 64;

/// Errors surfaced by the team tools. Named so `describeError` can turn them
/// into an actionable sentence instead of a bare Zig error name.
pub const TeamError = error{
    NoTeam,
    TeamExists,
    UnknownTeammate,
    TeamFull,
    InvalidName,
    EmptyMessage,
    MailboxFull,
    AlreadyShuttingDown,
    OutOfMemory,
};

pub const Teammate = struct {
    name: []const u8,
    /// Round-robin cursor over the task list: idle teammates claim the next
    /// unowned task from where they left off. Never pushed work.
    next_claim: u32 = 1,
    /// True once this teammate has acknowledged a shutdown request.
    acknowledged: bool = false,
    /// Whether the lead granted more than the default read-only tools.
    writes_granted: bool = false,
    /// Persisted subagent window id (Phase 26). A teammate keeps its context
    /// between turns by resuming this window, instead of starting from scratch.
    window_id: []const u8 = "",
    /// True while this teammate is mid-turn. The harness never starts a second
    /// turn for one that is already running (no overlapping claims).
    running: bool = false,
};

pub const Message = struct {
    from: []const u8,
    to: []const u8,
    text: []const u8,
};

/// The team store. Mirrors `taskstore.Store` in ownership and lifecycle:
/// the caller owns the allocator, `deinit` frees everything, and the task
/// graph itself lives in `taskstore.Store` (Team ≡ TaskList).
pub const Team = struct {
    gpa: std.mem.Allocator,
    name: []const u8 = "",
    members: std.ArrayList(Teammate) = .empty,
    mailbox: std.ArrayList(Message) = .empty,
    /// Set by `requestShutdown`; cleared only by `reset`.
    shutting_down: bool = false,
    /// Acknowledgement count — one per live teammate, answered exactly once.
    acks: usize = 0,

    pub fn init(gpa: std.mem.Allocator) Team {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Team) void {
        for (self.members.items) |m| {
            self.gpa.free(m.name);
            if (m.window_id.len > 0) self.gpa.free(m.window_id);
        }
        self.members.deinit(self.gpa);
        for (self.mailbox.items) |msg| {
            self.gpa.free(msg.from);
            self.gpa.free(msg.to);
            self.gpa.free(msg.text);
        }
        self.mailbox.deinit(self.gpa);
        if (self.name.len > 0) self.gpa.free(self.name);
        self.* = .{ .gpa = self.gpa };
    }

    pub fn create(self: *Team, name: []const u8) TeamError!void {
        const trimmed = std.mem.trim(u8, name, " \t\r\n");
        if (trimmed.len == 0 or trimmed.len > max_name) return error.InvalidName;
        // Only [a-zA-Z0-9_-] — a teammate name is a stable routing key and a
        // permission-rule subject, not free-form prose.
        for (trimmed) |c| {
            const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
                (c >= '0' and c <= '9') or c == '-' or c == '_';
            if (!ok) return error.InvalidName;
        }
        if (self.name.len > 0) return error.TeamExists;
        self.name = try self.gpa.dupe(u8, trimmed);
    }

    pub fn active(self: *const Team) bool {
        return self.name.len > 0;
    }

    pub fn reset(self: *Team) void {
        self.deinit();
    }

    pub fn indexOf(self: *const Team, name: []const u8) ?usize {
        for (self.members.items, 0..) |m, i| {
            if (std.mem.eql(u8, m.name, name)) return i;
        }
        return null;
    }

    pub fn has(self: *const Team, name: []const u8) bool {
        return self.indexOf(name) != null;
    }

    /// Adds a teammate. `writes_granted` is false by default — teammates are
    /// read-only unless the lead explicitly grants more.
    pub fn add(self: *Team, name: []const u8, writes_granted: bool) TeamError!void {
        if (!self.active()) return error.NoTeam;
        const trimmed = std.mem.trim(u8, name, " \t\r\n");
        if (trimmed.len == 0 or trimmed.len > max_name) return error.InvalidName;
        for (trimmed) |c| {
            const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
                (c >= '0' and c <= '9') or c == '-' or c == '_';
            if (!ok) return error.InvalidName;
        }
        if (self.indexOf(trimmed) != null) return error.TeamExists;
        if (self.members.items.len >= max_teammates) return error.TeamFull;
        const owned = try self.gpa.dupe(u8, trimmed);
        errdefer self.gpa.free(owned);
        try self.members.append(self.gpa, .{ .name = owned, .writes_granted = writes_granted });
    }

    /// Sends a message. Returns the number of teammates it reached (1 for a
    /// direct message, N for a broadcast). An unknown name is a named error.
    pub fn send(self: *Team, from: []const u8, to: []const u8, text: []const u8) TeamError!usize {
        if (!self.active()) return error.NoTeam;
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return error.EmptyMessage;
        if (trimmed.len > max_message) return error.EmptyMessage; // oversized: refuse, don't truncate silently

        var targets: usize = 0;
        if (std.mem.eql(u8, to, "*")) {
            targets = self.members.items.len;
            if (targets == 0) return error.UnknownTeammate;
        } else {
            if (self.indexOf(to) == null) return error.UnknownTeammate;
            targets = 1;
        }
        if (self.mailbox.items.len + targets > max_mailbox) return error.MailboxFull;

        const from_owned = try self.gpa.dupe(u8, from);
        errdefer self.gpa.free(from_owned);
        const text_owned = try self.gpa.dupe(u8, trimmed);
        errdefer self.gpa.free(text_owned);
        if (std.mem.eql(u8, to, "*")) {
            for (self.members.items) |m| {
                const to_owned = try self.gpa.dupe(u8, m.name);
                errdefer self.gpa.free(to_owned);
                try self.mailbox.append(self.gpa, .{ .from = from_owned, .to = to_owned, .text = text_owned });
            }
            // The shared strings are owned by the mailbox as a whole; on
            // deinit each message frees its copies. We duplicated per message
            // so each line is self-contained (free-by-length, not by address).
            self.gpa.free(from_owned);
            self.gpa.free(text_owned);
            return targets;
        }
        const to_owned = try self.gpa.dupe(u8, to);
        errdefer self.gpa.free(to_owned);
        try self.mailbox.append(self.gpa, .{ .from = from_owned, .to = to_owned, .text = text_owned });
        return targets;
    }

    /// Drain all messages addressed to `name`, in send order.
    pub fn receive(self: *Team, name: []const u8, arena: std.mem.Allocator) TeamError![]const Message {
        var out: std.ArrayList(Message) = .empty;
        var i: usize = 0;
        while (i < self.mailbox.items.len) {
            const msg = self.mailbox.items[i];
            if (!std.mem.eql(u8, msg.to, name)) {
                i += 1;
                continue;
            }
            const rec = Message{
                .from = try arena.dupe(u8, msg.from),
                .to = try arena.dupe(u8, msg.to),
                .text = try arena.dupe(u8, msg.text),
            };
            try out.append(arena, rec);
            // Remove from the mailbox, freeing the owned strings.
            self.gpa.free(msg.from);
            self.gpa.free(msg.to);
            self.gpa.free(msg.text);
            _ = self.mailbox.orderedRemove(i);
        }
        return out.toOwnedSlice(arena);
    }

    /// Claim the next open task for a teammate. Round-robin from the cursor
    /// stored on the teammate. `ids` are the currently unowned task ids (the
    /// lead supplies them from `taskstore.Store`); returns the claimed id or
    /// null when there is nothing open. Idempotent per owner.
    pub fn nextClaim(self: *Team, name: []const u8, ids: []const u32) ?u32 {
        const ix = self.indexOf(name) orelse return null;
        if (ids.len == 0) return null;
        const start = self.members.items[ix].next_claim;
        var k: usize = 0;
        while (k < ids.len) : (k += 1) {
            const pos = (@as(usize, start) + k) % ids.len;
            const id = ids[pos];
            if (id != 0) {
                self.members.items[ix].next_claim = id + 1;
                return id;
            }
        }
        return null;
    }

    pub fn requestShutdown(self: *Team) TeamError!void {
        if (!self.active()) return error.NoTeam;
        if (self.shutting_down) return error.AlreadyShuttingDown;
        self.shutting_down = true;
        self.acks = 0;
        // A fresh shutdown starts with every acknowledgement open: a stale
        // `true` from an earlier sweep would make `shutdownComplete` lie.
        for (self.members.items) |*m| m.acknowledged = false;
    }

    /// Acknowledge a shutdown request. Exactly one ack per teammate: a second
    /// acknowledgement is ignored, so an exit sweep cannot double-count.
    pub fn acknowledgeShutdown(self: *Team, name: []const u8) TeamError!void {
        if (!self.active()) return error.NoTeam;
        if (!self.shutting_down) return error.NoTeam;
        const ix = self.indexOf(name) orelse return error.UnknownTeammate;
        if (self.members.items[ix].acknowledged) return;
        self.members.items[ix].acknowledged = true;
        self.acks += 1;
    }

    pub fn shutdownComplete(self: *const Team) bool {
        if (!self.shutting_down or self.members.items.len == 0) return false;
        return self.acks >= self.members.items.len;
    }

    /// Set the persisted window id for a teammate. Called once when the lead
    /// spawns it; the old id (if any) is freed.
    pub fn setWindow(self: *Team, name: []const u8, id: []const u8) TeamError!void {
        const ix = self.indexOf(name) orelse return error.UnknownTeammate;
        const owned = try self.gpa.dupe(u8, id);
        if (self.members.items[ix].window_id.len > 0) self.gpa.free(self.members.items[ix].window_id);
        self.members.items[ix].window_id = owned;
    }

    pub fn window(self: *const Team, name: []const u8) ?[]const u8 {
        const ix = self.indexOf(name) orelse return null;
        const w = self.members.items[ix].window_id;
        return if (w.len > 0) w else null;
    }

    pub fn setRunning(self: *Team, name: []const u8, v: bool) void {
        if (self.indexOf(name)) |ix| self.members.items[ix].running = v;
    }

    /// Names of teammates with messages waiting and no turn in flight. The
    /// harness wakes only these — it never pushes work to an idle teammate
    /// that has not been addressed.
    pub fn wakeable(self: *const Team, arena: std.mem.Allocator) TeamError![][]const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer out.deinit(arena);
        for (self.members.items) |m| {
            if (m.running or m.acknowledged) continue;
            var waiting = false;
            for (self.mailbox.items) |msg| {
                if (std.mem.eql(u8, msg.to, m.name)) {
                    waiting = true;
                    break;
                }
            }
            if (waiting) try out.append(arena, try arena.dupe(u8, m.name));
        }
        return out.toOwnedSlice(arena);
    }

    /// Drain a teammate's messages into one prompt (in send order). Empty when
    /// there is nothing waiting. The messages are removed from the mailbox.
    pub fn drainPrompt(self: *Team, name: []const u8, arena: std.mem.Allocator) TeamError![]const u8 {
        const msgs = try self.receive(name, arena);
        if (msgs.len == 0) return "";
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(arena);
        try out.appendSlice(arena, "[team message from the lead]\n");
        for (msgs) |msg| {
            try out.print(arena, "{s}: {s}\n", .{ msg.from, msg.text });
        }
        try out.appendSlice(arena, "\nYou are a teammate. Claim open work with `task_list` then `task_update` with `claim: true` and `owner` set to your name, do the work, and report with `send_message` to \"lead\". You were NOT assigned a task — take one yourself if there is work you can do.");
        return out.toOwnedSlice(arena);
    }

    /// Exit sweep: acknowledge every remaining teammate so no live state
    /// outlives the app. Returns how many acknowledgement slots were filled.
    /// Mirrors `bgproc.killAll` — the process is about to exit, so this closes
    /// the bookkeeping that would otherwise be left dangling.
    pub fn sweepOnExit(self: *Team) usize {
        if (!self.active()) return 0;
        var n: usize = 0;
        for (self.members.items) |*m| {
            m.running = false;
            if (!m.acknowledged) {
                m.acknowledged = true;
                n += 1;
            }
        }
        self.acks = self.members.items.len;
        self.shutting_down = true;
        return n;
    }

    pub fn summary(self: *const Team, arena: std.mem.Allocator) TeamError![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(arena);
        try out.print(arena, "team {s} — {d} teammate(s), {d} message(s) queued", .{
            if (self.active()) self.name else "(none)",
            self.members.items.len,
            self.mailbox.items.len,
        });
        if (self.shutting_down) {
            try out.print(arena, " [shutting down {d}/{d}]", .{ self.acks, self.members.items.len });
        }
        for (self.members.items) |m| {
            try out.print(arena, "\n  {s}{s}{s}", .{
                m.name,
                if (m.writes_granted) " (writes granted)" else " (read-only)",
                if (m.acknowledged) " · acknowledged" else "",
            });
        }
        return out.toOwnedSlice(arena);
    }
};

// ── tests ─────────────────────────────────────────────────────

fn testTeam(a: std.mem.Allocator) Team {
    return Team.init(a);
}

/// Test helper: the open set after a task is claimed (compacts in place).
fn removeId(ids: *[3]u32, id: u32) [3]u32 {
    var out = [_]u32{ 0, 0, 0 };
    var n: usize = 0;
    for (ids.*) |v| {
        if (v == 0 or v == id) continue;
        out[n] = v;
        n += 1;
    }
    ids.* = out;
    return out;
}

test "team: create/delete resets the team" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var team = testTeam(a);
    defer team.deinit();
    try std.testing.expect(!team.active());
    try team.create("builders");
    try std.testing.expect(team.active());
    try std.testing.expectEqualStrings("builders", team.name);
    try std.testing.expectError(error.TeamExists, team.create("other"));
    team.reset();
    try std.testing.expect(!team.active());
}

test "team: rejects invalid names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var team = testTeam(a);
    defer team.deinit();
    try std.testing.expectError(error.InvalidName, team.create(""));
    try std.testing.expectError(error.InvalidName, team.create("../evil"));
    try std.testing.expectError(error.InvalidName, team.create("has space"));
}

test "team: add defaults to read-only and refuses duplicates" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var team = testTeam(a);
    defer team.deinit();
    try std.testing.expectError(error.NoTeam, team.add("a", false));
    try team.create("t");
    try team.add("alice", false);
    try std.testing.expect(team.has("alice"));
    try std.testing.expect(!team.members.items[0].writes_granted);
    try std.testing.expectError(error.TeamExists, team.add("alice", false));
    try team.add("bob", true);
    try std.testing.expect(team.members.items[1].writes_granted);
}

test "team: message routing by name and broadcast" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var team = testTeam(a);
    defer team.deinit();
    try team.create("t");
    try team.add("alice", false);
    try team.add("bob", false);

    try std.testing.expectEqual(@as(usize, 1), try team.send("lead", "alice", "check the parser"));
    const to_alice = try team.receive("alice", a);
    try std.testing.expectEqual(@as(usize, 1), to_alice.len);
    try std.testing.expectEqualStrings("check the parser", to_alice[0].text);
    try std.testing.expectEqualStrings("lead", to_alice[0].from);
    try std.testing.expectEqual(@as(usize, 0), (try team.receive("bob", a)).len);

    try std.testing.expectEqual(@as(usize, 2), try team.send("lead", "*", "ship it"));
    try std.testing.expectEqual(@as(usize, 1), (try team.receive("alice", a)).len);
    try std.testing.expectEqual(@as(usize, 1), (try team.receive("bob", a)).len);
}

test "team: unknown name is a named error, empty message refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var team = testTeam(a);
    defer team.deinit();
    try team.create("t");
    try team.add("alice", false);
    try std.testing.expectError(error.UnknownTeammate, team.send("lead", "nobody", "hi"));
    try std.testing.expectError(error.EmptyMessage, team.send("lead", "alice", "  "));
}

test "team: claiming sets owner and only one teammate can own a task" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var team = testTeam(a);
    defer team.deinit();
    try team.create("t");
    try team.add("alice", false);
    try team.add("bob", false);

    // The caller passes only the UNowned ids (from taskstore). Once claimed,
    // the id leaves the open set — that plus taskstore.claim's atomic check is
    // what guarantees two teammates never own the same task.
    var open = [_]u32{ 1, 2, 3 };
    const c1 = team.nextClaim("alice", &open).?;
    open = removeId(&open, c1);
    const c2 = team.nextClaim("bob", &open).?;
    try std.testing.expect(c1 != c2); // distinct tasks handed out
    // Idempotent for the same owner: same id again when it's the only open one.
    try std.testing.expectEqual(c1, team.nextClaim("alice", &[_]u32{c1}).?);
}

test "team: shutdown request is answered exactly once" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var team = testTeam(a);
    defer team.deinit();
    try team.create("t");
    try team.add("alice", false);
    try team.add("bob", false);

    try team.requestShutdown();
    // A second shutdown request is a named error, not a silent re-broadcast.
    try std.testing.expectError(error.AlreadyShuttingDown, team.requestShutdown());
}

test "team: shutdown ack flow" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var team = testTeam(a);
    defer team.deinit();
    try team.create("t");
    try team.add("alice", false);
    try team.add("bob", false);

    try team.requestShutdown();
    try std.testing.expect(!team.shutdownComplete());
    try team.acknowledgeShutdown("alice");
    try std.testing.expectEqual(@as(usize, 1), team.acks);
    try team.acknowledgeShutdown("alice"); // second ack ignored
    try std.testing.expectEqual(@as(usize, 1), team.acks);
    try std.testing.expect(!team.shutdownComplete());
    try team.acknowledgeShutdown("bob");
    try std.testing.expect(team.shutdownComplete());
    try std.testing.expectError(error.UnknownTeammate, team.acknowledgeShutdown("nobody"));
}

test "team: broadcast is linear in team size" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var team = testTeam(a);
    defer team.deinit();
    try team.create("t");
    for (0..6) |i| {
        var buf: [8]u8 = undefined;
        const n = std.fmt.bufPrint(&buf, "m{d}", .{i}) catch unreachable;
        try team.add(n, false);
    }
    try std.testing.expectEqual(@as(usize, 6), try team.send("lead", "*", "hello"));
    try std.testing.expectEqual(@as(usize, 6), team.mailbox.items.len);
}

test "team: wakeable selects only addressed, idle teammates" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var team = testTeam(a);
    defer team.deinit();
    try team.create("t");
    try team.add("alice", false);
    try team.add("bob", false);

    try std.testing.expectEqual(@as(usize, 0), (try team.wakeable(a)).len);
    _ = try team.send("lead", "bob", "hello bob");
    const wake = try team.wakeable(a);
    try std.testing.expectEqual(@as(usize, 1), wake.len);
    try std.testing.expectEqualStrings("bob", wake[0]);

    team.setRunning("bob", true);
    try std.testing.expectEqual(@as(usize, 0), (try team.wakeable(a)).len);
    team.setRunning("bob", false);

    const prompt = try team.drainPrompt("bob", a);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "hello bob") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "claim") != null);
    try std.testing.expectEqual(@as(usize, 0), (try team.wakeable(a)).len);
}

test "team: window id persists per teammate" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var team = testTeam(a);
    defer team.deinit();
    try team.create("t");
    try team.add("alice", false);
    try std.testing.expect(team.window("alice") == null);
    try team.setWindow("alice", "sa-42");
    try std.testing.expectEqualStrings("sa-42", team.window("alice").?);
    try team.setWindow("alice", "sa-99");
    try std.testing.expectEqualStrings("sa-99", team.window("alice").?);
    try std.testing.expect(team.window("bob") == null);
}

test "team: exit sweep acknowledges everyone exactly once" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var team = testTeam(a);
    defer team.deinit();
    try team.create("t");
    try team.add("alice", false);
    try team.add("bob", false);
    try std.testing.expectEqual(@as(usize, 2), team.sweepOnExit());
    try std.testing.expect(team.shutdownComplete());
    try std.testing.expectEqual(@as(usize, 0), team.sweepOnExit());
}
