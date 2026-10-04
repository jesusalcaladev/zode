const std = @import("std");
const builtin = @import("builtin");

/// Sleeps `ms` milliseconds WITHOUT touching the shared `Io`.
///
/// ## Why this exists and why it is not `Io.sleep`
///
/// `Io.sleep` is a vtable call, and the `Io` is shared with the TUI's event
/// thread: while a worker is inside it, the vaxis `tick` that drives the redraw
/// stops firing. From the outside that is a freeze — the clock in the activity
/// strip stops dead, the redraws stop, and the notices stay in `pending`
/// unpainted until you press a key.
///
/// `nanosleep` is a syscall in the calling thread and disturbs nobody.
///
/// It was an accident of history that this lived in `acp.zig`: the ACP worker
/// needed a poll that did not freeze the UI, and the retry backoff and the
/// permission dialog found it there. When ACP was removed, this had to survive it
/// — the two callers that matter (`chat.sleepMs` and the permission wait) have
/// nothing to do with ACP.
///
/// It is a no-op off Linux rather than an error: the caller is a backoff, and a
/// platform without it should wait less, not refuse to work.
pub fn nap(ms: u64) void {
    if (builtin.os.tag != .linux) return;
    const ts = std.os.linux.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.os.linux.nanosleep(&ts, null);
}
