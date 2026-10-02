//! Background processes: `bash` with `run_in_background`.
//!
//! Why this exists and why it is not a nicety: a `zig build test` takes 30 s, and
//! while the worker sits inside `std.process.run` it CANNOT do anything else. It
//! cannot read a file to understand why the build failed, cannot grep an error
//! message, cannot answer the next question. The turn is parked on a process that
//! produces nothing until it dies. That is the single largest avoidable latency
//! in the whole agent loop, and it is also a quality problem: the interesting
//! reasoning ("which of these 40 errors is mine?") all happens AFTER the wait
//! instead of during it.
//!
//! So the job starts, returns an id IMMEDIATELY, and the agent keeps working.
//! `bash_output` is incremental: it returns only what appeared since the last
//! call, which is what makes polling cheap and what keeps the output out of the
//! context (the whole point of the project is not paying for tokens twice).
//!
//! One thread per job, and it is a DELIBERATE leak-free design:
//!
//! - The registry is a fixed array in the `Model` (no allocator, no lock on the
//!   list itself): `bgproc.Registry` is a plain struct the TUI already owns.
//! - Each job has ONE slot with its own mutex and its own growable buffer. The
//!   reading thread appends; `bash_output` copies out under the same mutex.
//! - A job that is `reaped` is not freed by the thread; the registry slot is
//!   released when the model deinits (or when a new job reuses it). Freeing from
//!   the reader thread would race with `bash_output` reading the same buffer.

const std = @import("std");
const builtin = @import("builtin");

pub const Registry = @This();

/// Jobs at the same time. Each one is a thread and a pipe pair, so this is not
/// free: 8 is already more than a person can keep track of.
pub const max_jobs = 8;

/// Output kept per job. A build that prints 2 MB of warnings is not worth 2 MB of
/// RAM and is not worth sending to a model either: past this the buffer stops
/// growing and says so ONCE, because "truncated" repeated 40 times is the same
/// noise as never saying it.
pub const max_output = 64 * 1024;

/// A job's output hit `max_output`.
pub const truncation_notice = "\n… (output truncated; the job keeps running and you can keep polling for the exit status)\n";

/// Lifecycle of a job.
pub const State = enum {
    /// Spawned, still running.
    running,
    /// Finished; `exit` holds the code.
    finished,
    /// Killed with `bash_kill` or by ESC.
    killed,
    /// The slot is free again.
    free,
};

/// What the reading thread needs. File-level (not a local) because the thread
/// function takes a `*ReaderCtx` and a local type would not name it.
const ReaderCtx = struct {
    reg: *Registry,
    id: u32,
    gpa: std.mem.Allocator,
    io: std.Io,
    /// The reader thread's OWN copy of the child. `wait()` mutates it and
    /// `kill()` zeroes its `id`, so it cannot be shared with the registry slot.
    child: std.process.Child = undefined,
};

pub const Job = struct {
    /// `null` when the slot is free.
    state: State = .free,
    /// Stable across the job's life: this is what the model holds and what it
    /// passes back to `bash_output`. It is a counter, not a pointer, so a freed
    /// slot's memory can never make id 3 point at job 5.
    id: u32 = 0,
    /// Own copy of the command, for `bash_output`'s header. gpa.
    command: ?[]u8 = null,
    /// What the job printed. Own mutex: the reader thread appends while the
    /// worker (or the UI) reads.
    mutex: std.atomic.Mutex = .unlocked,
    buf: std.ArrayList(u8) = .empty,
    /// Bytes read and then DISCARDED because of the cap. With this the model can
    /// be told how much it is not seeing, instead of assuming it saw everything.
    dropped: usize = 0,
    /// Bytes already handed to `bash_output` (the read cursor).
    cursor: usize = 0,
    /// Set when the buffer hit the cap.
    truncated: bool = false,
    /// Exit code, valid in `finished`/`killed`.
    exit: ?u8 = null,
    /// The child, for `kill`. Only touched from the UI thread / on exit.
    child: ?std.process.Child = null,
    /// The child's pid, captured at spawn.
    ///
    /// It exists because `child.id` is NOT stable: the reader thread calls `wait()`
    /// on its own copy of the `Child` and the pid is recycled the moment the child
    /// is reaped, at which point `getpgid` on it is `error.CHILD` — a PANIC in Zig
    /// 0.16, not a value. So the pid that `killTree` needs is kept here, where the
    /// reaper cannot invalidate it.
    pgid: std.posix.pid_t = 0,
    /// Set by `killAll` (ESC) so a job that has not been reaped yet dies too.
    kill_requested: bool = false,

    pub fn isLive(self: *const Job) bool {
        return self.state != .free;
    }

    /// One word: `running`, `ok`, `failed`, `killed`, `gone`.
    ///
    /// On the JOB and not only on the registry: `/bg` prints one line per slot and
    /// the draw wants the same word for the status column. Two implementations of
    /// "is this job fine" is how `ok` and `exit=0` end up disagreeing on screen.
    pub fn stateWord(self: *const Job) []const u8 {
        return switch (self.state) {
            .running => "running",
            .finished => if (self.exit != null and self.exit.? == 0) "ok" else "failed",
            .killed => "killed",
            .free => "gone",
        };
    }

    /// Frees the job's own memory. `gpa` must be the one that allocated `command`
    /// and `buf`, which is the Model's.
    fn deinit(self: *Job, gpa: std.mem.Allocator) void {
        if (self.command) |c| gpa.free(c);
        self.buf.deinit(gpa);
        self.* = .{};
    }
};

slots: [max_jobs]Job = @splat(.{}),
next_id: u32 = 1,
/// Set by ESC. Consumed by `spawn`.
cancel_all: bool = false,

/// The raw id of a running job (for the UI: "which command is that?").
pub fn commandOf(self: *Registry, id: u32) ?[]const u8 {
    for (&self.slots) |*j| {
        if (j.isLive() and j.id == id) return j.command;
    }
    return null;
}

pub fn liveCount(self: *Registry) usize {
    var n: usize = 0;
    for (&self.slots) |*j| {
        if (j.isLive()) n += 1;
    }
    return n;
}

/// Sum of `state == .running`, for the status bar.
pub fn runningCount(self: *Registry) usize {
    var n: usize = 0;
    for (&self.slots) |*j| {
        if (j.state == .running) n += 1;
    }
    return n;
}

/// Text for the status bar, or `""` when there is nothing backgrounded.
pub fn statusLine(self: *Registry, out: []u8) []const u8 {
    var n: usize = 0;
    for (&self.slots) |*j| {
        if (j.state == .running) n += 1;
    }
    if (n == 0) return "";
    return std.fmt.bufPrint(out, "{d} bg", .{n}) catch "";
}

fn lockSlot(j: *Job) void {
    while (!j.mutex.tryLock()) std.Thread.yield() catch {};
}
fn unlockSlot(j: *Job) void {
    j.mutex.unlock();
}

/// Appends, respecting the cap. Caller holds the lock.
///
/// The cap reserves room for `truncation_notice` from the START. Without that
/// reservation the notice could never be written: by the time the buffer is full
/// — which is exactly when you find out it is full — there is no space left for
/// it, so the one message that says "you are not seeing all of this" is the one
/// that gets dropped. The user is then told the exit status is exact and reads
/// nothing else, with no idea that 300 KB went past.
fn appendLocked(j: *Job, gpa: std.mem.Allocator, bytes: []const u8) void {
    if (bytes.len == 0) return;
    const cap = max_output - truncation_notice.len;
    const room = if (j.buf.items.len < cap) cap - j.buf.items.len else 0;
    if (room == 0) {
        j.dropped += bytes.len;
        if (!j.truncated) {
            j.truncated = true;
            j.buf.appendSlice(gpa, truncation_notice) catch {};
        }
        return;
    }
    const take = @min(room, bytes.len);
    j.buf.appendSlice(gpa, bytes[0..take]) catch {
        j.dropped += bytes.len;
        return;
    };
    if (take < bytes.len) {
        j.dropped += bytes.len - take;
        if (!j.truncated) {
            j.truncated = true;
            j.buf.appendSlice(gpa, truncation_notice) catch {};
        }
    }
}

/// What one call to `bash_output` returns, composed into the caller's buffer.
///
/// Incremental BY DESIGN: the second call must not repeat the first one's bytes,
/// or a polling agent re-pays for the same output on every poll and the context
/// fills with duplicates. The exit status and the "still running" note are NOT
/// incremental (they have to be in every answer) but they are short.
pub const Output = struct {
    buf: [max_output + 512]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Output) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Reads the new output of a job and advances the cursor.
///
/// Writes into `out` (a caller-owned buffer) and returns a slice OF IT. Not a
/// local struct returned by value: a `[]const u8` pointing at this function's own
/// stack dies the moment it returns, and the caller (the agent loop) hands it to
/// the session writer. That is the `&[_]u8{c}` bug again, and it is the reason
/// the signature takes the buffer.
pub fn read(reg: *Registry, out: *Output, id: u32) ![]const u8 {
    for (&reg.slots) |*j| {
        if (!j.isLive() or j.id != id) continue;

        lockSlot(j);
        defer unlockSlot(j);

        // With a `job` that finished, the caller has to be told even if there is
        // no new output: "exit=0" is the answer to "did it pass?", which is the
        // whole reason the agent is polling.
        const finished = j.state != .running;
        const from = j.cursor;
        const avail = j.buf.items.len;
        if (from >= avail and !finished) return error.NoNewOutput;

        var w: std.Io.Writer = .fixed(&out.buf);
        const cmd = j.command orelse "";

        if (finished and j.exit != null) {
            w.print("[{s}] finished exit={d}\n", .{ cmd, j.exit.? }) catch {};
        } else if (finished) {
            w.print("[{s}] finished\n", .{cmd}) catch {};
        } else {
            w.print("[{s}] still running ({d} bytes so far)\n", .{ cmd, avail }) catch {};
        }

        if (from < avail) {
            w.writeAll(j.buf.items[from..avail]) catch {};
            j.cursor = avail;
        }
        if (j.dropped > 0) {
            w.print("\n({d} bytes of output dropped by the {d} KB cap; the exit status is still exact)\n", .{
                j.dropped, max_output / 1024,
            }) catch {};
        }
        if (w.buffered().len == 0) w.writeAll("(no new output yet)\n") catch {};
        out.len = w.buffered().len;
        return out.slice();
    }
    return error.UnknownJob;
}

/// The state of a job as ONE short word, for the header.
pub fn stateWord(reg: *Registry, id: u32) []const u8 {
    for (&reg.slots) |*j| {
        if (j.isLive() and j.id == id) return j.stateWord();
    }
    return "gone";
}

/// The command of the job the FOREGROUND tool is running right now, if any.
///
/// This is the ESC-kills-the-child piece and it needs the registry because a
/// foreground `bash` (the normal one) does not go through `spawn`: it goes
/// through `std.process.run`, which owns the child in ITS stack frame and gives
/// nobody a handle. So the foreground tool registers here too — only the pid —
/// and ESC kills that pid. Without it, ESC set a flag that the `run` never looks
/// at and the command ran to the end of its timeout.
var foreground: std.atomic.Value(std.posix.pid_t) = .init(0);

/// Publishes the pid of the command a foreground tool is waiting on.
pub fn setForeground(pid: std.posix.pid_t) void {
    foreground.store(pid, .seq_cst);
}

pub fn clearForeground() void {
    foreground.store(0, .seq_cst);
}

/// Kills the foreground command, if any. Returns true if there was one.
///
/// `kill(-pid, SIGKILL)`: the NEGATIVE pid, so the signal goes to the process
/// GROUP. A `sh -c "a && b"` is a shell with children, and killing only the shell
/// leaves the child (`zig`, `npm`, a test binary) running and holding the CPU —
/// which is exactly the "ESC did nothing" symptom, one level down.
pub fn killForeground() bool {
    const pid = foreground.load(.seq_cst);
    if (pid <= 0) return false;
    clearForeground();
    // `SIGKILL` and not `SIGTERM`: the user pressed ESC to stop it NOW, and a
    // build that ignores SIGTERM (or takes three seconds to notice) keeps burning
    // the core for those three seconds.
    std.posix.kill(-pid, std.posix.SIG.KILL) catch {
        // No process group (or already gone): fall back to the pid itself.
        std.posix.kill(pid, std.posix.SIG.KILL) catch return true;
    };
    return true;
}

/// ESC pressed while jobs are running: marks every live job and kills its child
/// in one pass. This is what the UI's ESC calls — `requestKillAll` alone only
/// MARKS the jobs, and the kill only happened at app exit, so a background build
/// kept burning CPU for the rest of the session after ESC ("ESC did nothing",
/// one level down).
///
/// Runs on the UI thread, which is the one allowed to call `Child.kill` (two
/// threads on the same `Child` is the race `acp.zig` documents). The reader
/// thread needs nothing special: the killed process closes its pipes, `fill`
/// hits EndOfStream, `wait` returns a signal term and the slot lands in
/// `.killed` on its own.
pub fn killNow(reg: *Registry, io: std.Io) usize {
    var n: usize = 0;
    for (&reg.slots) |*j| {
        if (j.state == .running) {
            j.kill_requested = true;
            killTree(j, io);
            n += 1;
        }
    }
    // Also blocks the spawns the STILL RUNNING turn may attempt in its next
    // iteration: ESC means "stop", and "stop" covers the tool calls that come
    // after it. Cleared at the start of the NEXT turn (see `chatWorker`).
    reg.cancel_all = true;
    return n;
}

/// Marks every live job for death (ESC).
///
/// Only MARKS them: the actual kill is `killAll`/`killNow`, which run on the
/// thread that can safely touch the child. Setting the flag from the UI thread
/// and killing from the same call keeps `Child.kill` off two threads at once,
/// which is how `acp.zig` notes you must not do it.
pub fn requestKillAll(reg: *Registry) usize {
    var n: usize = 0;
    for (&reg.slots) |*j| {
        if (j.state == .running) {
            j.kill_requested = true;
            n += 1;
        }
    }
    reg.cancel_all = true;
    return n;
}

/// Kills everything and waits for the readers (bounded, at exit).
///
/// `io` is optional and NOT dereferenced when there is nothing to kill. That is
/// what lets the tests build a `Registry`, deinit it and never have an `Io`: a
/// test Model has `io == undefined`, and calling a vtable on it is a jump into
/// garbage. Checking the slots FIRST is the whole point — the alternative (kill
/// then check) reads the child unconditionally.
pub fn killAll(reg: *Registry, io: ?std.Io, budget_ms: u64) void {
    var live: usize = 0;
    for (&reg.slots) |*j| {
        if (j.state != .running) continue;
        live += 1;
        j.kill_requested = true;
    }
    if (live == 0) return;
    const real_io = io orelse return;
    for (&reg.slots) |*j| {
        if (j.state == .running) {
            killTree(j, real_io);
        }
    }
    // The reader threads end when the pipes hit EOF, which the kill brings. They
    // are detached, so this is a bounded WAIT and not a join: at exit a stuck
    // reader must not hang the process.
    const deadline: u64 = budget_ms;
    var waited: u64 = 0;
    while (waited < deadline) : (waited += 10) {
        if (!anyReading(reg)) return;
        napMs(10);
    }
}

fn anyReading(reg: *Registry) bool {
    for (&reg.slots) |*j| {
        if (j.state == .running) return true;
    }
    return false;
}

pub fn deinit(reg: *Registry, io: ?std.Io, gpa: std.mem.Allocator) void {
    killAll(reg, io, 1000);
    for (&reg.slots) |*j| j.deinit(gpa);
    reg.* = .{};
}

/// Starts a job. Returns its id, or an error.
///
/// The spawn happens HERE, on the calling thread, and only the READING goes to a
/// thread. That split matters: `spawn` touches the shared `Io` (and its PATH), so
/// doing it from a worker of ours is fine, but the `Child` struct has to be
/// published to the registry before the reader can store the exit status into it.
pub fn spawn(
    reg: *Registry,
    gpa: std.mem.Allocator,
    io: std.Io,
    command: []const u8,
) !u32 {
    // ESC pressed: refuse to start something the user just asked to stop.
    if (reg.cancel_all) return error.Cancelled;

    var slot: ?*Job = null;
    for (&reg.slots) |*j| {
        if (!j.isLive()) {
            slot = j;
            break;
        }
    }
    const j = slot orelse return error.TooManyJobs;

    const cmd_copy = try gpa.dupe(u8, command);
    errdefer gpa.free(cmd_copy);

    var argv = [_][]const u8{ "/bin/sh", "-c", command };
    // `pgid = 0` puts the child in its OWN process group (as the leader). It is
    // what makes `kill(-pid)` possible in `killGroup`, and without it a `sh -c
    // "a && b"` leaves `a`'s children alive when only the shell is killed — which
    // is a background build that keeps burning the CPU after `/bg kill`.
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    }) catch return error.SpawnFailed;
    errdefer child.kill(io);

    j.* = .{};
    j.state = .running;
    j.id = reg.next_id;
    j.command = cmd_copy;
    j.child = child;
    // The pid, taken BEFORE the reader thread can reap the child. `killTree`
    // signals `-pgid`, and after a reap that pid belongs to somebody else.
    j.pgid = child.id orelse 0;
    reg.next_id +%= 1;
    if (reg.next_id == 0) reg.next_id = 1;

    const ctx = try gpa.create(ReaderCtx);
    ctx.* = .{ .reg = reg, .id = j.id, .gpa = gpa, .io = io };

    // `child` is COPIED into the thread's own copy: the registry slot's `Child`
    // is what `bash_kill`/`killAll` use, and two threads calling `Child.kill` on
    // the same struct (it asserts `id == null` afterwards) is a data race on a
    // pointer the kernel side does not protect.
    // The reader thread gets its OWN copy of the child: `wait()` mutates it and
    // `kill()` zeroes its `id`, so sharing the struct with the registry slot
    // would be a race between `bash_kill` and the reader.
    ctx.child = child;
    const t = std.Thread.spawn(.{}, reader, .{ctx}) catch {
        gpa.destroy(ctx);
        child.kill(io);
        j.deinit(gpa);
        return error.ThreadSpawnFailed;
    };
    t.detach();
    return j.id;
}

/// The reading thread: stdout+stderr into the slot's buffer, then the exit status.
///
/// `MultiReader` is the same mechanism `std.process.run` uses, and for the same
/// reason: reading the two pipes with two blocking reads in one thread DEADLOCKS
/// as soon as one of them fills its 64 KB pipe buffer while the other is being
/// waited on. `MultiReader` uses the `Io`'s poller, so it interleaves them.
fn reader(ctx: *ReaderCtx) void {
    const gpa = ctx.gpa;
    defer gpa.destroy(ctx);
    const io = ctx.io;
    var child = &ctx.child;
    defer child.kill(io);

    var slot: ?*Job = null;
    for (&ctx.reg.slots) |*j| {
        if (j.isLive() and j.id == ctx.id) {
            slot = j;
            break;
        }
    }
    const j = slot orelse return;
    const job_id = ctx.id;

    var mr_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var mr: std.Io.File.MultiReader = undefined;
    mr.init(gpa, io, mr_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();

    while (mr.fill(4096, .none)) |_| {
        for (0..2) |ix| {
            const chunk = mr.reader(ix).buffered();
            if (chunk.len == 0) continue;
            lockSlot(j);
            appendLocked(j, gpa, chunk);
            unlockSlot(j);
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => {
            lockSlot(j);
            appendLocked(j, gpa, "\n(zode: could not read the job's output)\n");
            unlockSlot(j);
        },
    }

    const term = child.wait(io) catch {
        lockSlot(j);
        j.state = .finished;
        j.exit = null;
        j.child = null;
        unlockSlot(j);
        return;
    };

    lockSlot(j);
    // The slot may have been RELEASED while the job was still running (the model
    // deinit on exit). Writing into it then would be writing into freed memory,
    // so the id is re-checked and only that guards it.
    if (j.isLive() and j.id == job_id) {
        j.state = if (j.kill_requested) .killed else .finished;
        j.exit = switch (term) {
            .exited => |code| code,
            .signal => |sig| @as(u8, @truncate(128 + @intFromEnum(sig))),
            .stopped, .unknown => 255,
        };
        j.child = null;
    }
    unlockSlot(j);
}

/// ESC pressed while jobs are running: marks every live job, kills its child and
/// reaps it at once. This is what the UI's ESC calls — `requestKillAll` alone only
/// MARKS the jobs and the kill used to happen only at app exit, so a background
/// build kept burning CPU for the whole session after ESC.
///
/// Runs on the UI thread (the one allowed to call `Child.kill`, see `killAll`):
/// the marking is atomic enough for the reader thread, which only ever reads
/// `kill_requested` to decide the final `.killed` state.

/// Releases a finished job so its slot can be reused. Only the caller that owns
/// the model does this (never the reader thread: see the header).
pub fn reap(reg: *Registry, gpa: std.mem.Allocator, id: u32) void {
    for (&reg.slots) |*j| {
        if (j.state != .running and j.isLive() and j.id == id) {
            j.deinit(gpa);
            return;
        }
    }
}

/// Kills one job (by id), if it is running.
pub fn kill(reg: *Registry, io: std.Io, id: u32) bool {
    for (&reg.slots) |*j| {
        if (j.isLive() and j.id == id) {
            if (j.state != .running) return false;
            j.kill_requested = true;
            killTree(j, io);
            return true;
        }
    }
    return false;
}

/// Kills a job's whole PROCESS GROUP, not just the shell.
///
/// `Child.kill` signals a single pid, and the child of a job is always
/// `/bin/sh -c "…"`. A shell has children of its own, and killing only the shell
/// leaves them running: a `zig build` killed this way keeps compiling, still
/// holds the CPU, and still holds the output pipe open so the reader thread never
/// sees EOF. That was measurable — `/bg kill` on a `sleep 30 & wait` returned
/// "killed" and the `sleep` was still there 30 s later.
///
/// `spawn` sets `pgid = 0`, so the child LEADS its own group and `kill(-pid)`
/// reaches all of it. The plain `c.kill(io)` still runs after, for its own side
/// effects on the struct (it zeroes `id`, which the reader's `wait` relies on).
fn killTree(j: *Job, io: std.Io) void {
    if (j.child) |*c| {
        // The GROUP first, using the pid captured at spawn (`j.pgid`), not
        // `c.id`: the reader thread's `wait()` can have zeroed `c.id` already, and
        // even if it has not, `j.pgid` is the one value the reaper cannot
        // invalidate under us.
        if (j.pgid > 0) std.posix.kill(-j.pgid, std.posix.SIG.KILL) catch {};
        c.kill(io);
    }
}

/// A plain `nanosleep`, NOT `Io.sleep`: `Io.sleep` goes through the shared `Io`,
/// which the TUI's redraw ticks also use. Sleeping on it from a worker freezes
/// the screen (this is the trap AGENTS.md documents for `Retry.wait` and the ACP
/// cancel loop).
fn napMs(ms: u64) void {
    if (builtin.os.tag != .linux) {
        std.Thread.yield() catch {};
        return;
    }
    const ts = std.os.linux.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.os.linux.nanosleep(&ts, null);
}

const bgproc = @This();

test "read: unknown id es un error con nombre, no un panic" {
    var reg = Registry{};
    defer reg.deinit(undefined, std.testing.allocator);
    var out = bgproc.Output{};
    try std.testing.expectError(error.UnknownJob, bgproc.read(&reg, &out, 42));
}

test "read: un id liberado vuelve a ser desconocido (no resurrecta)" {
    // El id es un contador, no un puntero: si `read` guardase el indice, el
    // recycled slot 0 devolveria la salida de OTRO trabajo.
    var reg = Registry{};
    defer reg.deinit(undefined, std.testing.allocator);
    reg.slots[0] = .{ .state = .finished, .id = 7, .exit = 0 };
    try reg.slots[0].buf.appendSlice(std.testing.allocator, "hola");
    bgproc.reap(&reg, std.testing.allocator, 7);
    var out = bgproc.Output{};
    try std.testing.expectError(error.UnknownJob, bgproc.read(&reg, &out, 7));
}

test "read: devuelve lo nuevo y NO repite lo viejo" {
    // Es la propiedad que hace que un agente que hace polling no pague dos
    // veces por la misma salida.
    var reg = Registry{};
    defer reg.deinit(undefined, std.testing.allocator);
    // OWNED command: `deinit` frees it, so a literal here is an "Invalid free"
    // in the test rather than in production. (Sixth family, and the tests are
    // the only place where you get to see it for free.)
    const cmd = try std.testing.allocator.dupe(u8, "zig build");
    reg.slots[0] = .{ .state = .finished, .id = 3, .exit = 0, .command = cmd };
    try reg.slots[0].buf.appendSlice(std.testing.allocator, "linea1\nlinea2\n");

    var o1 = bgproc.Output{};
    const first = try bgproc.read(&reg, &o1, 3);
    try std.testing.expect(std.mem.indexOf(u8, first, "linea1") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "exit=0") != null);

    // La segunda vez ya no hay salida nueva, pero el estado sigue importando:
    // es la respuesta a "termino?".
    var o2 = bgproc.Output{};
    const second = try bgproc.read(&reg, &o2, 3);
    try std.testing.expect(std.mem.indexOf(u8, second, "linea1") == null);
    try std.testing.expect(std.mem.indexOf(u8, second, "exit=0") != null);
}

test "read: un job vivo sin salida nueva es NoNewOutput, no una cadena vacia" {
    var reg = Registry{};
    defer reg.deinit(undefined, std.testing.allocator);
    reg.slots[0] = .{ .state = .running, .id = 1 };
    var o3 = bgproc.Output{};
    try std.testing.expectError(error.NoNewOutput, bgproc.read(&reg, &o3, 1));
}

test "read: lo que se perdio por el cap se DICE" {
    var reg = Registry{};
    defer reg.deinit(undefined, std.testing.allocator);
    reg.slots[0] = .{ .state = .finished, .id = 1, .exit = 0 };
    reg.slots[0].dropped = 12345;
    var o4 = bgproc.Output{};
    const out = try bgproc.read(&reg, &o4, 1);
    try std.testing.expect(std.mem.indexOf(u8, out, "12345") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "exit status is still exact") != null);
}

test "el cap de salida avisa UNA vez, no en cada trozo" {
    var reg = Registry{};
    defer reg.deinit(undefined, std.testing.allocator);
    reg.slots[0] = .{ .state = .running, .id = 1 };
    const j = &reg.slots[0];
    const big = [_]u8{'x'} ** 1024;
    var i: usize = 0;
    while (i < 200) : (i += 1) bgproc.appendLocked(j, std.testing.allocator, &big);
    // Lo que se perdio es todo menos lo que cupo, y lo que cupo deja sitio para
    // el aviso: el total del buffer nunca pasa de `max_output`.
    try std.testing.expect(j.dropped > 0);
    try std.testing.expect(j.buf.items.len <= bgproc.max_output);
    try std.testing.expect(std.mem.endsWith(u8, j.buf.items, "polling for the exit status)\n"));
    // Y el aviso aparece UNA vez dentro del buffer, no una por trozo discarded:
    // 200 trozos de "truncated" es el mismo ruido que no avisar nunca.
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, j.buf.items, pos, "output truncated")) |at| {
        count += 1;
        pos = at + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "stateWord y statusLine cuentan lo que toca" {
    var reg = Registry{};
    defer reg.deinit(undefined, std.testing.allocator);
    var sl0: [16]u8 = undefined;
    try std.testing.expectEqualStrings("", bgproc.statusLine(&reg, &sl0));
    reg.slots[0] = .{ .state = .running, .id = 1 };
    reg.slots[2] = .{ .state = .running, .id = 3 };
    reg.slots[1] = .{ .state = .finished, .id = 2, .exit = 0 };
    try std.testing.expectEqual(@as(usize, 2), bgproc.runningCount(&reg));
    try std.testing.expectEqual(@as(usize, 3), bgproc.liveCount(&reg));
    var sl: [16]u8 = undefined;
    try std.testing.expectEqualStrings("2 bg", bgproc.statusLine(&reg, &sl));
    try std.testing.expectEqualStrings("ok", bgproc.stateWord(&reg, 2));
    try std.testing.expectEqualStrings("running", bgproc.stateWord(&reg, 3));
}

test "cancel_all: ESC impide que arranque lo siguiente" {
    var reg = Registry{};
    defer reg.deinit(undefined, std.testing.allocator);
    reg.cancel_all = true;
    // Sin `io` no se puede ni intentar el spawn, y aun asi el refusal tiene que
    // ser el de ESC y no un crash: es la condicion que se comprueba primero.
    try std.testing.expectError(error.Cancelled, bgproc.spawn(&reg, std.testing.allocator, undefined, "ls"));
}

test "reap no toca un job vivo" {
    var reg = Registry{};
    defer reg.deinit(undefined, std.testing.allocator);
    reg.slots[0] = .{ .state = .running, .id = 1 };
    bgproc.reap(&reg, std.testing.allocator, 1);
    try std.testing.expect(bgproc.liveCount(&reg) == 1);
}

test "spawn: el hijo LIDERA su grupo de procesos (o ESC no puede matarlo)" {
    // El bug 1. `bash` es `/bin/sh -c "..."`, y un shell tiene hijos: sin que el
    // hijo sea su propio lider de grupo, `kill(-pid, SIGKILL)` no tiene ningun
    // grupo al que apuntar, ESC cae al `kill(pid)` de siempre, y lo que sobrevive
    // es el NIETO (`sleep`, `zig`, `npm`) con el core prendido. Medido: un
    // `sleep 30 & wait` siguo vivo 30 s despues de "ESC lo paro".
    //
    // Aqui se mira el invariante sobre un hijo REAL, no una cadena en el fuente: se
    // hace el mismo `std.process.spawn` que hace `spawn`, con y sin `pgid = 0`, y
    // se comprueba que el grupo cambia.
    //
    // NO se pasa por `bgproc.spawn`: ese deja un hilo lector que hace `wait()`
    // sobre su copia del `Child`, y un `std.Io.Threaded` hecho a mano tambien
    // recoge los hijos. Dos `wait` sobre el mismo proceso, el segundo recibe
    // `ECHILD`, y Zig 0.16 convierte `error.CHILD` en un PANIC que tumba el
    // runner entero (no solo el test). Es una peculiaridad de un `Threaded` de
    // pruebas, no de `spawn` en produccion — y el camino de produccion esta
    // cubierto por `tools/esc_kill_pty.py`, que es donde se prueba de verdad que
    // ESC mata al NIETO.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const own = try procPgrp(io, std.os.linux.getpid());

    // Sin `pgid = 0`: el hijo comparte nuestro grupo. Esta es la situacion que
    // hacia que `kill(-pid)` no tuviera nada a lo que apuntar.
    {
        var argv = [_][]const u8{ "/bin/sh", "-c", "sleep 30" };
        const c = try std.process.spawn(io, .{
            .argv = &argv,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        const pid = c.id.?;
        try std.testing.expectEqual(own, try procPgrp(io, pid));
        std.posix.kill(pid, std.posix.SIG.KILL) catch {};
    }

    // Con `pgid = 0`: el hijo LIDERA su propio grupo, y ese grupo es su pid.
    {
        var argv = [_][]const u8{ "/bin/sh", "-c", "sleep 30" };
        const c = try std.process.spawn(io, .{
            .argv = &argv,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = 0,
        });
        const pid = c.id.?;
        const child = try procPgrp(io, pid);
        try std.testing.expect(child != own);
        try std.testing.expectEqual(@as(i64, pid), child);
        // Y `kill(-pid)` alcanza al grupo entero, que es lo que hace `killTree`.
        std.posix.kill(-pid, std.posix.SIG.KILL) catch {};
    }

    // Y el resto: los dos spawns REALES (el de `spawn` y el del foreground de
    // `tools.zig`) tienen que pasar por aqui. Es una guarda por SOURCE, no por
    // comportamiento, y es a proposito: los dos bloques de arriba no pueden
    // llegar a `spawn` sin el panic del `ECHILD` que explica el comentario, asi
    // que sin esta linea el test describiria el mecanismo y no protegeria el
    // sitio donde se decidio. El comportamiento de verdad esta en
    // `tools/esc_kill_pty.py`, que mata un nieto de verdad en la pty real.
    //
    // Se miran las DOS lineas porque los dos caminos tienen el mismo bug: el
    // foreground es el que se usa el 99% de las veces y el background el que mas
    // duele (un build en segundo plano).
    //
    // `@embedFile` con ruta RELATIVA al modulo (`src/bgproc.zig` se compila
    // desde `src/test_all.zig`, asi que la ruta es `bgproc.zig`), y el path del
    // modulo no se puede escribir en un `@embedFile` de comptime.
    const bg_src = @embedFile("bgproc.zig");
    try std.testing.expect(std.mem.indexOf(u8, bg_src, ".pgid = 0,") != null);
    const tools_src = @embedFile("tools.zig");
    try std.testing.expect(std.mem.indexOf(u8, tools_src, ".pgid = 0,") != null);
}

/// Campo 5 de `/proc/<pid>/stat` (el `pgrp`), o error si no se puede leer.
///
/// El campo 2 (`comm`) va entre parentesis y PUEDE contener espacios y
/// parentesis (`(mi (proceso))`), asi que no se puede partir por campo a pelo:
/// se parte por el ULTIMO `)`, que es el que cierra `comm`.
///
/// `readFileAlloc` NO sirve aqui, y el motivo es de procfs: `st_size` de un
/// fichero de `/proc` es 0, asi que cualquier lector que se guie por el tamaño
/// (que es lo que hace `allocRemaining`) se devuelve VACIO sin error. Se lee con
/// un `readSliceShort` sobre un buffer fijo, que pregunta al kernel y no al
/// `stat`.
fn procPgrp(io: std.Io, pid: std.posix.pid_t) !i64 {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch return error.NoPath;

    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);

    var buf: [4096]u8 = undefined;
    var r = f.reader(io, &buf);
    const n = try r.interface.readSliceShort(&buf);
    const st = buf[0..n];

    const close = std.mem.lastIndexOfScalar(u8, st, ')') orelse return error.BadStat;
    var it = std.mem.tokenizeAny(u8, st[close + 1 ..], " \t\n");
    _ = it.next() orelse return error.BadStat; // state
    _ = it.next() orelse return error.BadStat; // ppid
    const pgrp = it.next() orelse return error.BadStat;
    return std.fmt.parseInt(i64, pgrp, 10);
}
