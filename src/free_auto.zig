const std = @import("std");
const agent = @import("agent.zig");
const roster_mod = @import("roster.zig");
const tui = @import("tui.zig");

/// The pool of free models and the wheel that hands turns out among them
/// (`/free-auto`).
///
/// ## Why it lives in a global with a spinlock and not inside `Model`
///
/// A WORKER writes it (the one listing the models of each provider) and two
/// other threads read it: the chat worker, to rotate, and the UI one, to paint
/// the status. It is the same problem as `acp_client`, with the same solution: a
/// spinlock `tryLock` over two-line sections, because `std.atomic.Mutex` is not
/// reentrant and taking the lock with your own hangs the app.
///
/// The difference with the model pool is that here the content CANNOT be invalidated at
/// runtime: the strings are copies from an arena that lives until the teardown,
/// and the AGENTS.md rule is exact: data read from several threads is never
/// freed in runtime.
///
/// ## Why the pool does not wait
///
/// `build` talks to N providers: that is N requests. If it happened on the first
/// failure, the user would watch it "think" exactly when they need something to
/// happen. It is built in a worker when the mode is switched on, and if it is
/// not ready the turn goes on with the active model.
var free_auto_on: bool = false;
var roster_state = roster_mod.Roster{};
var roster_inited = false;
var roster_lock: std.atomic.Mutex = .unlocked;

fn rosterLock() void {
    while (!roster_lock.tryLock()) std.Thread.yield() catch {};
}

fn rosterUnlock() void {
    roster_lock.unlock();
}

/// The `Io` for the clock, if there is one.
///
/// It is `?std.Io` and not `agent.io_global` bare because that one is
/// `undefined` until startup assigns it, and reading the clock from an
/// uninitialized `Io` is jumping through a vtable of garbage: an immediate GPF
/// (and NOT a 0). It is the same trap as `Model.attachIo` with its `io_ready`
/// flag, and the same remedy.
var roster_io: ?std.Io = null;

pub fn attachIo(io: std.Io) void {
    roster_io = io;
}

/// Milliseconds since epoch, for the roster cooldowns.
///
/// No clock returns 0. It is not perfect (the cooldowns do not expire on their
/// own) but it is the failure that CANNOT bring the app down, and it only
/// happens in tests: in production there is always an `Io`.
pub fn nowMs() i128 {
    const io = roster_io orelse return 0;
    return @divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms);
}

/// The global roster, creating it if it is needed.
pub fn rosterGet(gpa: std.mem.Allocator) *roster_mod.Roster {
    if (!roster_inited) {
        roster_state = roster_mod.Roster.init(gpa);
        roster_inited = true;
    }
    return &roster_state;
}

/// Label for the status bar, or "" if the mode is off or not built yet.
///
/// CAREFUL with the contract: the slice it returns belongs to the allocator the
/// caller passes in (the model's), not to the global's. That is what lets it
/// paint without worrying about the global changing between the check and the
/// use, and it is the same reason `sessionInfo` uses `allocPrint` and not a
/// fixed buffer.
pub fn freeAutoLabel(gpa: std.mem.Allocator) []const u8 {
    if (!free_auto_on) return "";
    rosterLock();
    defer rosterUnlock();
    if (!roster_inited) return "";
    return roster_state.statusLabel(gpa);
}

pub fn freeAutoOn() bool {
    rosterLock();
    defer rosterUnlock();
    return free_auto_on;
}

/// How many candidates are in the pool (0 if it is not built). For the chat
/// worker, which needs to know whether rotating is worth it.
pub fn poolSize() u8 {
    rosterLock();
    defer rosterUnlock();
    if (!roster_inited) return 0;
    return roster_state.len;
}

/// The result of switching pair halfway through a turn.
pub const Switch = struct {
    /// The pair being switched to.
    cand: roster_mod.Candidate,
    /// The pair that ran out of quota (for the message).
    prev_provider: []const u8,
    prev_model: []const u8,
    /// Why the previous one died, already with the label ("rate limited: 429 …").
    prev_reason: []const u8,
};

/// Kills the current pair and returns the next live one, or null if none is left.
///
/// It returns THE PREVIOUS one too, and not just the new one, because the message
/// to the user has to be able to name both ("quota gone on groq/x → openrouter/y").
/// With the roster alone (`rotate`) you have to remember the index from before,
/// which is exactly the datum that is lost the moment it moves.
pub fn switchTo(gpa: std.mem.Allocator, why: roster_mod.Why, detail: []const u8) ?Switch {
    const r = rosterGet(gpa);
    const prev_idx = r.cur_raw;
    const prev = r.currentCandidate() orelse return null;
    const next = r.rotate(nowMs(), why, detail) orelse return null;
    return .{
        .cand = r.items[next],
        .prev_provider = prev.provider_id,
        .prev_model = prev.model_id,
        .prev_reason = r.deadReason(prev_idx),
    };
}

// ── bridge for the `agent.zig` tests ─────────────────────────────
//
// `pickTarget` lives in agent.zig (because it needs the active provider) and the
// state of the mode lives here. The tests of one need to touch the other's, and
// doing that with a bare `free_auto_on` from the other file does not compile (it is
// private). These three are the bridge, and they are the reason this exists instead
// of a brute force `pub var`: they force the state to be restored.

pub const StateSnapshot = struct {
    on: bool,
    inited: bool,
    state: roster_mod.Roster,
};

pub fn stateSave() StateSnapshot {
    rosterLock();
    defer rosterUnlock();
    return .{ .on = free_auto_on, .inited = roster_inited, .state = roster_state };
}

pub fn stateRestore(s: StateSnapshot) void {
    rosterLock();
    free_auto_on = s.on;
    roster_inited = s.inited;
    roster_state = s.state;
    rosterUnlock();
}

pub fn stateSet(on: bool, inited: bool, state: roster_mod.Roster) void {
    rosterLock();
    free_auto_on = on;
    roster_inited = inited;
    roster_state = state;
    rosterUnlock();
}

/// Job of the worker that builds the pool.
const RosterJob = struct {
    model: *tui.Model,
};

/// Builds the pool in the background.
///
/// The `defs` (compiled providers plus the ones from `config.json`) come out of an
/// arena that dies when the worker ends, and that is why `Roster.build` DUPLICATES
/// everything it needs from the provider: the candidate ids are copies from the
/// roster arena, not from the def.
fn rosterWorker(job: *RosterJob) void {
    const m = job.model;
    defer {
        m.allocator.destroy(job);
        m.endWorker();
    }

    var astate = std.heap.ArenaAllocator.init(m.allocator);
    defer astate.deinit();
    const defs = agent.allProviders(astate.allocator());
    const gpa = rosterGet(m.allocator).arena;

    var r = roster_mod.Roster.init(gpa);
    r.build(agent.io_global, m.environ, defs) catch {
        rosterLock();
        roster_state.built = true;
        roster_state.empty_reason = "could not reach any provider";
        rosterUnlock();
        const msg = "free-auto: could not build the model pool (no provider answered)";
        agent.pushInfo(m, msg);
        return;
    };

    // It is installed ONLY if the global already exists. If the user has not pressed
    // `/free-auto`, this worker has no business leaving a pool behind.
    if (roster_inited) {
        rosterLock();
        roster_state.len = r.len;
        roster_state.dead_len = 0;
        roster_state.built = true;
        roster_state.empty_reason = r.empty_reason;
        @memcpy(roster_state.items[0..r.len], r.items[0..r.len]);
        roster_state.idx = 0;
        roster_state.cur_raw = 0;
        rosterUnlock();
    }
    const n = r.len;

    if (!freeAutoOn()) return;
    if (n == 0) {
        const why = if (r.empty_reason.len > 0) r.empty_reason else "the pool is empty";
        own(m, "free-auto: {s}", .{why});
        return;
    }
    own(m, "free-auto: {d} free model{s} ready", .{ n, if (n == 1) "" else "s" });
}

/// Launches the worker that builds the pool. Best-effort: if it cannot be launched,
/// the mode keeps working with the active model and says so when it rotates.
pub fn startRosterBuild(m: *tui.Model) void {
    _ = rosterGet(m.allocator);
    const job = m.allocator.create(RosterJob) catch return;
    job.* = .{ .model = m };
    m.beginWorker();
    const t = std.Thread.spawn(.{}, rosterWorker, .{job}) catch {
        m.endWorker();
        m.allocator.destroy(job);
        const msg = "free-auto: could not start the model listing thread";
        agent.pushInfo(m, msg);
        return;
    };
    t.detach();
}

/// `pushInfoOwned` with an owned text, ALWAYS.
///
/// It exists because the failure is silent until the app DIES: passing a literal
/// to `pushInfoOwned` leaves a pointer to `.rodata` in `pending`, and `Model.deinit`
/// frees it -> "Invalid free" on exit. It is the same trap as the palette literals
/// (see AGENTS.md, "A crash on exit over literals"), and it has already been
/// written twice in this repo.
///
/// It also covers the `catch` of the `allocPrint`: with no memory you have to stay
/// quiet, not push a literal into a function that is supposed to take ownership.
fn own(m: *tui.Model, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(m.allocator, fmt, args) catch {
        agent.pushInfo(m, "free-auto: out of memory");
        return;
    };
    agent.pushInfoOwned(m, msg);
}

/// Changes the state of the mode. Returns `true` if the pool worker has to be
/// launched (that is: it was just switched on and there is no list yet).
///
/// It is separate from `cmdFreeAuto` for a concrete reason: switching the mode on
/// launches a thread that talks to the network, and a test that calls
/// `cmdFreeAuto("on")` leaves that thread alive with an already freed `Model`. Here
/// there is no thread, so the state IS checkable.
/// Re-lists the pool, keeping the mode ON.
///
/// Separate from `cmdFreeAuto` because "on" there means TOGGLE (it is the same
/// command with no argument), so calling it to refresh would switch the mode off.
/// The pool is built from "the providers that have a key right now", and that
/// set changes when the user connects one: without this, the rotation keeps
/// offering the models of the providers that existed at startup, which is not
/// what "every provider" means.
pub fn rebuildPool(m: *tui.Model) void {
    if (!freeAutoOn()) return;
    rosterLock();
    if (roster_inited) roster_state.built = false; // forces `setFreeAuto` to rebuild
    const had_dead = if (roster_inited) roster_state.dead_len > 0 else false;
    rosterUnlock();
    // Dead entries were decided against a pool that no longer exists.
    if (had_dead) {
        rosterLock();
        if (roster_inited) roster_state.dead_len = 0;
        rosterUnlock();
    }
    _ = setFreeAuto(m, true);
}

pub fn setFreeAuto(m: *tui.Model, want_on: bool) bool {
    rosterLock();
    free_auto_on = want_on;
    // Switching it off forgets who was dead: if it is switched on again within a
    // while, the old cooldowns no longer apply and the whole pool is tried
    // again.
    if (!want_on) roster_state.dead_len = 0;
    const built = roster_inited and roster_state.built;
    const n = if (roster_inited) roster_state.len else 0;
    rosterUnlock();

    if (!want_on) {
        agent.pushInfo(m, "free-auto: off (back to the active model)");
        agent.setStatusWithZo(m, .idle, "free-auto off");
        return false;
    }

    if (built) {
        own(m, "free-auto: on · {d} free model{s} in the pool", .{ n, if (n == 1) "" else "s" });
        agent.setStatusWithZo(m, .done, "free-auto on");
        return false;
    }

    agent.pushInfo(m, "free-auto: on · listing free models of every provider with a key…");
    agent.setStatusWithZo(m, .thinking, "building the free pool");
    return true;
}

/// `/free-auto [on|off|status]`.
pub fn cmdFreeAuto(m: *tui.Model, arg: ?[]const u8) void {
    const a = if (arg) |x| std.mem.trim(u8, x, " \t") else "";

    if (std.mem.eql(u8, a, "status")) {
        // CAREFUL: the literals go through `pushInfo` (which COPIES). Through
        // `pushInfoOwned` (which takes ownership) a literal ends up being freed
        // in `Model.deinit`, and that is an "Invalid free" on exit. Worth stressing:
        // `/free-auto status` with the pool unbuilt is exactly the literal branch.
        if (!freeAutoOn()) {
            agent.pushInfo(m, "free-auto: off");
            return;
        }
        const lbl = freeAutoLabel(m.allocator);
        if (lbl.len == 0) {
            agent.pushInfo(m, "free-auto: on · still listing models");
            return;
        }
        own(m, "free-auto: on · {s}", .{lbl});
        return;
    }

    const want_on = if (std.mem.eql(u8, a, "off"))
        false
    else if (a.len > 0 and !std.mem.eql(u8, a, "on")) {
        agent.pushInfo(m, "usage: /free-auto [on|off|status]");
        return;
    } else !freeAutoOn();

    if (setFreeAuto(m, want_on)) startRosterBuild(m);
}

/// Switches the mode on from the environment (`ZODE_FREE_AUTO=1`) without going
/// through the command. The TUI startup calls it. A value of "0"/"off"/"false"
/// counts as off, which is what anyone who sets the variable out of habit
/// expects.
pub fn initFromEnv(m: *tui.Model, env: ?*const std.process.Environ.Map) void {
    const v = if (env) |e| e.get("ZODE_FREE_AUTO") else null;
    const val = v orelse return;
    const off = std.mem.eql(u8, val, "0") or std.ascii.eqlIgnoreCase(val, "off") or
        std.ascii.eqlIgnoreCase(val, "false");
    if (off) return;
    cmdFreeAuto(m, "on");
}

// ── tests ─────────────────────────────────────────────────────
//
// They all touch the roster global, so each one leaves the state the way it
// found it. The lock is a SPINLOCK: taking it twice in the same thread hangs, and
// that is why there is not a single `defer rosterLock()` with a second `rosterLock()`
// inside it (which was the first draft of these tests).

/// Saves the global state and gives it back at the end.
const Saved = struct {
    on: bool,
    inited: bool,
    state: roster_mod.Roster,

    fn save() Saved {
        rosterLock();
        defer rosterUnlock();
        return .{ .on = free_auto_on, .inited = roster_inited, .state = roster_state };
    }

    fn restore(self: Saved) void {
        rosterLock();
        free_auto_on = self.on;
        roster_inited = self.inited;
        roster_state = self.state;
        rosterUnlock();
    }
};

test "freeAutoLabel: off returns empty (the status bar stays clean)" {
    const saved = Saved.save();
    defer saved.restore();

    rosterLock();
    free_auto_on = false;
    rosterUnlock();

    try std.testing.expectEqualStrings("", freeAutoLabel(std.testing.allocator));
}

test "freeAutoLabel: on and built says where it is" {
    const saved = Saved.save();
    defer saved.restore();

    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();

    var fake = roster_mod.Roster.init(arena);
    fake.built = true;
    fake.len = 2;
    fake.items[0] = .{ .provider_id = "groq", .model_id = "llama-3.3-70b" };
    fake.items[1] = .{ .provider_id = "openrouter", .model_id = "qwen3:free" };

    rosterLock();
    free_auto_on = true;
    roster_inited = true;
    roster_state = fake;
    rosterUnlock();

    const label = freeAutoLabel(arena);
    try std.testing.expect(std.mem.indexOf(u8, label, "free-auto 1/2") != null);
    try std.testing.expect(std.mem.indexOf(u8, label, "groq/llama-3.3-70b") != null);
}

test "freeAutoLabel: on with an empty pool says WHY" {
    // The case that makes the mode useful: there are no free models because there
    // is no key, and that has to be said. A bare "free-auto" in the status says nothing.
    const saved = Saved.save();
    defer saved.restore();

    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();

    var empty = roster_mod.Roster.init(arena);
    empty.built = true;
    empty.empty_reason = "no provider has an API key (ctrl+a to connect one)";

    rosterLock();
    free_auto_on = true;
    roster_inited = true;
    roster_state = empty;
    rosterUnlock();

    const label = freeAutoLabel(arena);
    try std.testing.expect(std.mem.indexOf(u8, label, "no provider has an API key") != null);
    try std.testing.expect(std.mem.indexOf(u8, label, "ctrl+a") != null);
}

test "cmdFreeAuto: on/off toggles, `status` changes nothing, junk warns" {
    const saved = Saved.save();
    defer saved.restore();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    rosterLock();
    free_auto_on = false;
    rosterUnlock();

    // CAREFUL: `setFreeAuto` is used and NOT `cmdFreeAuto("on")`, because the latter
    // launches the pool worker (a thread that talks to the network) and the test
    // would leave it alive with the `Model` already freed. What is tested here is
    // the state, which is what matters.
    _ = setFreeAuto(&m, true);
    try std.testing.expect(freeAutoOn());

    cmdFreeAuto(&m, "status");
    try std.testing.expect(freeAutoOn()); // `status` no toca nada

    _ = setFreeAuto(&m, false);
    try std.testing.expect(!freeAutoOn());

    // A weird argument is NOT a silent "on": that would be the worst possible way
    // to fail in a mode that switches models under the hood.
    cmdFreeAuto(&m, "maybe");
    try std.testing.expect(!freeAutoOn());
}

test "setFreeAuto: asks to build the pool only when there is no list" {
    // The return `bool` decides whether the worker is launched. If it said yes
    // with the pool already built, every `/free-auto on` would re-list N providers.
    const saved = Saved.save();
    defer saved.restore();

    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();

    // Not built: the worker has to be launched.
    rosterLock();
    roster_inited = false;
    free_auto_on = false;
    rosterUnlock();
    try std.testing.expect(setFreeAuto(&m, true));

    // Built: nothing has to be launched.
    var fake = roster_mod.Roster.init(arena);
    fake.built = true;
    fake.len = 3;
    rosterLock();
    roster_inited = true;
    roster_state = fake;
    rosterUnlock();
    try std.testing.expect(!setFreeAuto(&m, false));
    try std.testing.expect(!setFreeAuto(&m, true));
}

test "turning it off clears the cooldowns" {
    // Without clearing them, switching it on and off inside the same minute leaves
    // the pool half dead and the mode looks broken.
    const saved = Saved.save();
    defer saved.restore();

    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();

    var fake = roster_mod.Roster.init(arena);
    fake.built = true;
    fake.len = 2;
    fake.items[0] = .{ .provider_id = "groq", .model_id = "a" };
    fake.items[1] = .{ .provider_id = "groq", .model_id = "b" };

    rosterLock();
    free_auto_on = true;
    roster_inited = true;
    roster_state = fake;
    rosterUnlock();

    fake.noteDead(0, 0, .rate_limited, "429");
    rosterLock();
    roster_state.dead_len = fake.dead_len;
    rosterUnlock();
    try std.testing.expectEqual(@as(u8, 1), roster_state.dead_len);

    var m = tui.Model.init(std.testing.allocator);
    defer m.deinit();
    cmdFreeAuto(&m, "off");
    try std.testing.expectEqual(@as(u8, 0), roster_state.dead_len);
}
