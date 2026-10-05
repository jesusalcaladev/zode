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
const sleep = @import("lib/sleep.zig");
const builtin = @import("builtin");

pub const Registry = @This();

/// Jobs at the same time. Each one is a thread and a pipe pair, so this is not
/// free: 8 is already more than a person can keep track of.
pub const max_jobs = 8;

/// Bytes of command kept for display.
///
/// Not for `exec`: the whole line goes to `/bin/sh -c` either way. This is only
/// what the header shows, and a header that cannot hold the whole command is
/// better than one that can point at freed memory.
pub const max_command = 256;

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
    /// The command, for `bash_output`'s header.
    ///
    /// A FIXED buffer and not a heap slice, and the reason is a use-after-free
    /// that was already there: `spawn` was called with the TURN's arena (that is
    /// what `tools/bash.zig` had to hand it), the arena is freed at the end of
    /// `execToolCalls`, and the job — which can still be running, and is still
    /// read by `statusLine` from the draw — kept a pointer into it. A finished
    /// build's header then printed whatever the next allocation put there.
    ///
    /// A fixed buffer removes the ownership question instead of answering it: no
    /// allocator is involved, nothing to free, nothing to dangle. 256 bytes holds
    /// any command that is worth running; a longer one is truncated and says so.
    cmd_buf: [max_command]u8 = @splat(0),
    cmd_len: usize = 0,
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
    /// The command as a slice of the job's own buffer. Never null, never a
    /// pointer somebody else can free.
    pub fn commandSlice(self: *const Job) []const u8 {
        return self.cmd_buf[0..self.cmd_len];
    }

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
        if (j.isLive() and j.id == id) return j.commandSlice();
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
        const cmd = j.commandSlice();

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
/// The new output WITHOUT the header `read` prepends.
///
/// It exists for the tools that PARSE what a command printed, and the reason is
/// not tidiness: the header is a line zode writes, `[zig build] finished exit=1`,
/// and a parser that scans for `file:line: error:` finds the whole command line
/// inside it. `zig build check-probe` reported "3 type error(s)" for a build with
/// 2, the third one being its own command echoed back.
///
/// So the two readings are different things and they are named as such: `read` is
/// for a model to read (the header answers "what was this?"), `readNoHeader` is
/// for code that has to tell output from metadata.
pub fn readNoHeader(reg: *Registry, out: *Output, id: u32) ![]const u8 {
    for (&reg.slots) |*j| {
        if (!j.isLive() or j.id != id) continue;

        lockSlot(j);
        defer unlockSlot(j);

        const finished = j.state != .running;
        const from = j.cursor;
        const avail = j.buf.items.len;
        if (from >= avail and !finished) return error.NoNewOutput;

        var w: std.Io.Writer = .fixed(&out.buf);
        if (from < avail) {
            w.writeAll(j.buf.items[from..avail]) catch {};
            j.cursor = avail;
        }
        if (j.dropped > 0) {
            w.print("\n({d} bytes of output dropped by the {d} KB cap)\n", .{
                j.dropped, max_output / 1024,
            }) catch {};
        }
        if (w.buffered().len == 0) return "";
        out.len = w.buffered().len;
        return out.slice();
    }
    return error.UnknownJob;
}

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
/// threads on the same `Child` is a race). The reader
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
    // Truncated, not refused: a long command still has to run. The header is a
    // label, and a label that lies about whether the command ran is worse than a
    // short one.
    j.cmd_len = @min(command.len, max_command);
    @memcpy(j.cmd_buf[0..j.cmd_len], command[0..j.cmd_len]);
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

    // `reader(ix).buffered()` is the WHOLE data read from that stream so far, not
    // what arrived in this cycle: `fill` advances `end`, and nothing ever consumes
    // it. Appending it every cycle therefore re-appended the entire buffer on each
    // fill, and a job that printed two error lines had them six times in its
    // output by the time the agent read it.
    //
    // Found by `zig build check-probe` against a command with a known output: the
    // report said "7 type error(s)" for a build with 2. A duplicated diagnostic is
    // worse than a missing one — the model reads it as 7 places to fix.
    //
    // `consumed` is per stream and only ever grows. `rebaseGrowing` memmoves the
    // data to offset 0 and preserves its length, so a shrink here would mean the
    // accounting is wrong; skipping is the safe direction, because losing output is
    // worse than repeating it.
    var consumed = [_]usize{ 0, 0 };
    while (mr.fill(4096, .none)) |_| {
        for (0..2) |ix| {
            const chunk = mr.reader(ix).buffered();
            if (chunk.len <= consumed[ix]) continue;
            lockSlot(j);
            appendLocked(j, gpa, chunk[consumed[ix]..]);
            unlockSlot(j);
            consumed[ix] = chunk.len;
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
/// the screen (this is the trap AGENTS.md documents for `Retry.wait` and the
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

test "read: an unknown id is a named error, not a panic" {
    var reg = Registry{};
    defer reg.deinit(undefined, std.testing.allocator);
    var out = bgproc.Output{};
    try std.testing.expectError(error.UnknownJob, bgproc.read(&reg, &out, 42));
}

test "read: a freed id becomes unknown again (it does not resurrect)" {
    // The id is a counter, not a pointer: if `read` kept the index, the recycled
    // slot 0 would return the output of ANOTHER job.
    var reg = Registry{};
    defer reg.deinit(undefined, std.testing.allocator);
    reg.slots[0] = .{ .state = .finished, .id = 7, .exit = 0 };
    try reg.slots[0].buf.appendSlice(std.testing.allocator, "hola");
    bgproc.reap(&reg, std.testing.allocator, 7);
    var out = bgproc.Output{};
    try std.testing.expectError(error.UnknownJob, bgproc.read(&reg, &out, 7));
}

test "read: returns what is new and does NOT repeat the old" {
    // This is the property that stops a polling agent from paying twice for the
    // same output.
    var reg = Registry{};
    defer reg.deinit(undefined, std.testing.allocator);
    // The command is COPIED into the job's own fixed buffer, so `deinit` has
    // nothing to free for it any more. This `dupe` used to be freed by `deinit`
    // and now has to be freed here, and that shift is the proof: the job no
    // longer holds a pointer somebody else could have released.
    const cmd = try std.testing.allocator.dupe(u8, "zig build");
    defer std.testing.allocator.free(cmd);
    reg.slots[0] = .{ .state = .finished, .id = 3, .exit = 0, .cmd_len = @min(cmd.len, max_command) };
    @memcpy(reg.slots[0].cmd_buf[0..reg.slots[0].cmd_len], cmd[0..reg.slots[0].cmd_len]);
    try reg.slots[0].buf.appendSlice(std.testing.allocator, "linea1\nlinea2\n");

    var o1 = bgproc.Output{};
    const first = try bgproc.read(&reg, &o1, 3);
    try std.testing.expect(std.mem.indexOf(u8, first, "linea1") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "exit=0") != null);

    // The second time there is no new output, but the state still matters: it is
    // the answer to "did it finish?".
    var o2 = bgproc.Output{};
    const second = try bgproc.read(&reg, &o2, 3);
    try std.testing.expect(std.mem.indexOf(u8, second, "linea1") == null);
    try std.testing.expect(std.mem.indexOf(u8, second, "exit=0") != null);
}

test "read: a live job with no new output is NoNewOutput, not an empty string" {
    var reg = Registry{};
    defer reg.deinit(undefined, std.testing.allocator);
    reg.slots[0] = .{ .state = .running, .id = 1 };
    var o3 = bgproc.Output{};
    try std.testing.expectError(error.NoNewOutput, bgproc.read(&reg, &o3, 1));
}

test "read: what was lost to the cap is REPORTED" {
    var reg = Registry{};
    defer reg.deinit(undefined, std.testing.allocator);
    reg.slots[0] = .{ .state = .finished, .id = 1, .exit = 0 };
    reg.slots[0].dropped = 12345;
    var o4 = bgproc.Output{};
    const out = try bgproc.read(&reg, &o4, 1);
    try std.testing.expect(std.mem.indexOf(u8, out, "12345") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "exit status is still exact") != null);
}

test "the output cap warns ONCE, not on every chunk" {
    var reg = Registry{};
    defer reg.deinit(undefined, std.testing.allocator);
    reg.slots[0] = .{ .state = .running, .id = 1 };
    const j = &reg.slots[0];
    const big = [_]u8{'x'} ** 1024;
    var i: usize = 0;
    while (i < 200) : (i += 1) bgproc.appendLocked(j, std.testing.allocator, &big);
    // What was lost is everything that did not fit, and what fit leaves room for
    // the notice: the buffer total never passes `max_output`.
    try std.testing.expect(j.dropped > 0);
    try std.testing.expect(j.buf.items.len <= bgproc.max_output);
    try std.testing.expect(std.mem.endsWith(u8, j.buf.items, "polling for the exit status)\n"));
    // And the notice shows up ONCE inside the buffer, not once per discarded
    // chunk: 200 chunks of "truncated" is the same noise as never warning.
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, j.buf.items, pos, "output truncated")) |at| {
        count += 1;
        pos = at + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "stateWord and statusLine count what they should" {
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

test "cancel_all: ESC stops the next one from starting" {
    var reg = Registry{};
    defer reg.deinit(undefined, std.testing.allocator);
    reg.cancel_all = true;
    // Without `io` the spawn cannot even be attempted, and still the refusal has
    // to be ESC's and not a crash: it is the first condition checked.
    try std.testing.expectError(error.Cancelled, bgproc.spawn(&reg, std.testing.allocator, undefined, "ls"));
}

test "reap does not touch a live job" {
    var reg = Registry{};
    defer reg.deinit(undefined, std.testing.allocator);
    reg.slots[0] = .{ .state = .running, .id = 1 };
    bgproc.reap(&reg, std.testing.allocator, 1);
    try std.testing.expect(bgproc.liveCount(&reg) == 1);
}

test "spawn: the child LEADS its process group (or ESC cannot kill it)" {
    // Bug 1. `bash` is `/bin/sh -c "..."`, and a shell has children: without the
    // child leading its own group, `kill(-pid, SIGKILL)` has no group to aim
    // at, ESC falls back to the usual `kill(pid)`, and what survives is the
    // GRANDCHILD (`sleep`, `zig`, `npm`) with the core burning. Measured: a
    // `sleep 30 & wait` was still alive 30 s after "ESC stopped it".
    //
    // Here the invariant is checked against a REAL child, not a string in the
    // source: the same `std.process.spawn` that `spawn` does, with and without
    // `pgid = 0`, and the group is checked to change.
    //
    // It does NOT go through `bgproc.spawn`: that leaves a reader thread doing
    // `wait()` on its copy of the `Child`, and a hand-made `std.Io.Threaded`
    // also reaps children. Two `wait`s on the same process, the second one gets
    // `ECHILD`, and Zig 0.16 turns `error.CHILD` into a PANIC that takes down
    // the whole runner (not just the test). That is a quirk of a test
    // `Threaded`, not of `spawn` in production — and the production path is
    // covered by `tools/esc_kill_pty.py`, which is where ESC really killing
    // the GRANDCHILD is proven.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const own = try procPgrp(io, std.os.linux.getpid());

    // Without `pgid = 0`: the child shares our group. This is the situation that
    // left `kill(-pid)` with nothing to aim at.
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

    // With `pgid = 0`: the child LEADS its own group, and that group is its pid.
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
        // And `kill(-pid)` reaches the whole group, which is what `killTree` does.
        std.posix.kill(-pid, std.posix.SIG.KILL) catch {};
    }

    // And the rest: the two REAL spawns (the one in `spawn` and the foreground one
    // in `tools.zig`) have to go through here. It is a guard on SOURCE, not on
    // behaviour, and deliberately so: the two blocks above cannot reach `spawn`
    // without the `ECHILD` panic the comment explains, so without these lines
    // the test would describe the mechanism instead of protecting the place
    // where the decision was made. The real behaviour lives in
    // `tools/esc_kill_pty.py`, which kills a real grandchild in a real pty.
    //
    // BOTH lines are checked because both paths carry the same bug: foreground
    // is the one used 99% of the time, and background is the one that hurts
    // most (a build running in the background).
    //
    // `@embedFile` with a path RELATIVE to the module (`src/bgproc.zig` is
    // compiled from `src/test_all.zig`, so the path is `bgproc.zig`), and the
    // module path cannot be written into a comptime `@embedFile`.
    const bg_src = @embedFile("bgproc.zig");
    try std.testing.expect(std.mem.indexOf(u8, bg_src, ".pgid = 0,") != null);
    const tools_src = @embedFile("tools/bg.zig");
    try std.testing.expect(std.mem.indexOf(u8, tools_src, ".pgid = 0,") != null);
}

/// Field 5 of `/proc/<pid>/stat` (the `pgrp`), or an error if it cannot be read.
///
/// Field 2 (`comm`) is wrapped in parentheses and CAN contain spaces and
/// parentheses (`(my (process))`), so it cannot be split by field blindly: it
/// splits on the LAST `)`, the one that closes `comm`.
///
/// `readFileAlloc` does NOT work here, and the reason is procfs: `st_size` of a
/// `/proc` file is 0, so any reader that goes by the size (which is what
/// `allocRemaining` does) returns EMPTY with no error. This reads with a
/// `readSliceShort` over a fixed buffer, which asks the kernel and not `stat`.
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

test "a job's output is NOT duplicated: the reader consumes what it appended" {
    // Real bug, found by `zig build check-probe`: `MultiReader.reader(ix).buffered()`
    // returns EVERYTHING read from that stream so far, because `fill` only advances
    // `end` and nothing consumes it. The reader appended the whole buffer on every
    // fill, so a command with two error lines had six in the job's output by the
    // time it was read, and `check` reported "7 type error(s)" for a build with 2.
    //
    // A duplicated diagnostic is worse than a missing one: the model reads the count
    // as places to go and fix.
    // A real job needs an allocator that outlives the reader thread, and
    // `std.testing.allocator` frees everything at the end of the test while the
    // thread may still be running. A page allocator cannot fail a leak check.
    // A real job needs an allocator that OUTLIVES the reader thread, and
    // `std.testing.allocator` checks for leaks at the end of the test while that
    // thread may still be running. A page allocator cannot fail that check, and
    // these two tests are about output accounting, not about leaks.
    const gpa = std.heap.page_allocator;

    var reg = Registry{};
    defer reg.deinit(undefined, gpa);

    // One line per write, and several writes, so a per-fill append shows up.
    const cmd = "i=0; while [ $i -lt 5 ]; do echo \"line$i\"; i=$((i+1)); done";
    const id = try spawn(&reg, gpa, std.testing.io, cmd);

    var waited: u32 = 0;
    while (waited < 5000) : (waited += 20) {
        sleep.nap(20);
        if (!std.mem.eql(u8, stateWord(&reg, id), "running")) break;
    }
    try std.testing.expect(!std.mem.eql(u8, stateWord(&reg, id), "running"));

    // Counted on the header-free read, and the reason is the same finding: the
    // header contains the command, and the command contains the word being counted.
    // Counting on `read` gave 6 for 5 lines and looked like a second bug.
    var out = Output{};
    const text = try readNoHeader(&reg, &out, id);
    try std.testing.expectEqual(@as(usize, 1), countOf(text, "line0\n"));
    try std.testing.expectEqual(@as(usize, 1), countOf(text, "line4\n"));
    try std.testing.expectEqual(@as(usize, 5), countOf(text, "line"));
}

test "readNoHeader: the command line is not part of the output a parser sees" {
    // The other half of the same finding. `read` prepends `[cmd] finished exit=1`,
    // which is zode's own text, and a scanner looking for `file:line: error:`
    // finds the whole command inside it. `check-probe` counted its own command line
    // as a third type error.
    const gpa = std.heap.page_allocator;

    var reg = Registry{};
    defer reg.deinit(undefined, gpa);

    const cmd = "echo 'src/a.zig:1:1: error: real' >&2";
    const id = try spawn(&reg, gpa, std.testing.io, cmd);
    var waited: u32 = 0;
    while (waited < 5000) : (waited += 20) {
        sleep.nap(20);
        if (!std.mem.eql(u8, stateWord(&reg, id), "running")) break;
    }

    var with = Output{};
    const a = try read(&reg, &with, id);
    try std.testing.expect(std.mem.indexOf(u8, a, "src/a.zig:1:1: error: real") != null);
    // The header carries the command, and with it a copy of the error text.
    try std.testing.expect(std.mem.indexOf(u8, a, "echo 'src/a.zig:1:1: error") != null);

    // A second job, because the first one's cursor has already been consumed.
    const id2 = try spawn(&reg, gpa, std.testing.io, cmd);
    waited = 0;
    while (waited < 5000) : (waited += 20) {
        sleep.nap(20);
        if (!std.mem.eql(u8, stateWord(&reg, id2), "running")) break;
    }
    var without = Output{};
    const b = try readNoHeader(&reg, &without, id2);
    try std.testing.expect(std.mem.indexOf(u8, b, "src/a.zig:1:1: error: real") != null);
    // And no trace of the command that produced it.
    try std.testing.expect(std.mem.indexOf(u8, b, "echo 'src/a.zig:1:1: error") == null);
    try std.testing.expect(std.mem.indexOf(u8, b, "finished exit=") == null);
}

fn countOf(hay: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, hay, from, needle)) |at| {
        n += 1;
        from = at + needle.len;
    }
    return n;
}
