/// `sleep`: wait on purpose, without holding a shell process.
///
/// ## Why it exists next to `bash sleep 30`
///
/// `bash sleep 30` works and costs a process, a shell, and a job in the background
/// registry — and it is one of the few `bash` calls a model can make that has no
/// plausible reason to be there. This is the same wait with none of that, and with
/// one thing `bash` cannot do: it reports how long it ACTUALLY waited, so a sleep cut
/// short by ESC is visible instead of being a command that "exited 0".
///
/// ## What it is for, and what it is not
///
/// It is for "the thing I am waiting on has no way to tell me it is done": a deploy,
/// a rate limit, a file another process writes. It is NOT for polling a background job
/// this harness started — `bash_output` reads exactly what arrived since the last look,
/// and waking up to poll with a fixed timer pays an API call per wake-up to learn
/// nothing. The tool's description says that out loud, because a model with a sleep
/// tool and a long task will otherwise reach for the sleep.
///
/// ## The wait is in slices
///
/// `nanosleep` in 50 ms slices via `lib/sleep.zig` (NOT `Io.sleep`, which is a vtable
/// call on an `Io` shared with the UI), checking the ESC flag between them. A single
/// 300-second nanosleep would be a 300-second freeze the user cannot get out of.
const std = @import("std");
const common = @import("common.zig");
const sleepz = @import("../lib/sleep.zig");
const chat = @import("../chat.zig");

/// The ceiling, and the number is a design decision rather than a limit: the point of
/// refusing is that a wait this long means the turn should have been planned around
/// the work instead — polling a job, or ending the turn and doing something else. A
/// silent clamp would be worse than either (the model would believe it waited).
pub const max_seconds: u64 = 300;
const slice_ms: u64 = 50;

/// MILLISECONDS, not seconds, and that unit is the whole reason this function is
/// named the way it is: `seconds: 0.15` truncated to an integer is 0, so the tool
/// would answer "waited 0.0s" without waiting — a success report for a no-op, which
/// is the one thing a wait must not do.
fn parseMillis(obj: std.json.ObjectMap) !u64 {
    const v = obj.get("seconds") orelse return error.MissingSeconds;
    switch (v) {
        // An integer arrives whenever the model writes `2` and a float whenever it
        // writes `2.5`; both are the same request, and refusing either one is a round
        // trip spent on JSON.
        .integer => |i| {
            if (i < 0) return error.BadSeconds;
            if (i > max_seconds) return error.SleepTooLong;
            return @as(u64, @intCast(i)) * 1000;
        },
        .float => |f| {
            if (f < 0 or std.math.isNan(f) or std.math.isInf(f)) return error.BadSeconds;
            if (f > @as(f64, @floatFromInt(max_seconds))) return error.SleepTooLong;
            return @intFromFloat(f * 1000.0);
        },
        .string => |s| {
            const text = std.mem.trim(u8, s, " \t");
            const f = std.fmt.parseFloat(f64, text) catch return error.BadSeconds;
            if (f < 0 or std.math.isNan(f) or std.math.isInf(f)) return error.BadSeconds;
            if (f > @as(f64, @floatFromInt(max_seconds))) return error.SleepTooLong;
            return @intFromFloat(f * 1000.0);
        },
        else => return error.BadSeconds,
    }
}

/// `sleep` needs the `Io` for the clock and nothing else: the wait itself is a bare
/// syscall that does not touch it.
pub fn toolSleep(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const want_ms = try parseMillis(obj);
    const t0 = std.Io.Timestamp.now(io, .real).nanoseconds;
    var waited_ms: u64 = 0;
    var interrupted = false;
    while (waited_ms < want_ms) {
        // ESC means the user wants the turn to stop. A wait is exactly the moment
        // that signal matters most: 300 seconds of silence with a set flag is the
        // freeze this tool would otherwise introduce.
        if (chat.cancelled()) {
            interrupted = true;
            break;
        }
        const step = @min(slice_ms, want_ms - waited_ms);
        sleepz.nap(step);
        waited_ms += step;
    }
    const elapsed_ms: u64 = blk: {
        const now = std.Io.Timestamp.now(io, .real).nanoseconds;
        if (now <= t0) break :blk waited_ms;
        break :blk @intCast(@divTrunc(now - t0, std.time.ns_per_ms));
    };

    if (interrupted) {
        return std.fmt.allocPrint(
            arena,
            "interrupted after {d}.{d}s of the {d}.{d}s asked for (ESC). The turn is stopping: do not sleep again, and do not start new work.",
            .{ elapsed_ms / 1000, (elapsed_ms % 1000) / 100, want_ms / 1000, (want_ms % 1000) / 100 },
        );
    }
    // The real elapsed time, not the requested one: they are the same number on the
    // happy path, and the clock is the only thing that can be right when they are not.
    return std.fmt.allocPrint(arena, "waited {d}.{d}s.", .{ elapsed_ms / 1000, (elapsed_ms % 1000) / 100 });
}

// ── tests ────────────────────────────────────────────────────────

const testing = std.testing;

fn args(arena: std.mem.Allocator, comptime fmt: []const u8, a: anytype) !std.json.ObjectMap {
    const text = try std.fmt.allocPrint(arena, fmt, a);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    return v.object;
}

test "sleep: it waits for about as long as it was asked, and says so" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const t0 = std.Io.Timestamp.now(testing.io, .real).nanoseconds;
    const out = try toolSleep(testing.io, try args(arena, "{{\"seconds\":0.15}}", .{}), arena);
    const elapsed_ms: u64 = @intCast(@divTrunc(std.Io.Timestamp.now(testing.io, .real).nanoseconds - t0, std.time.ns_per_ms));

    // The report is the measured wait, and the measurement is what the clock says:
    // a tool that echoed back the number it was given would pass a test that only
    // looked at the text.
    try testing.expect(std.mem.startsWith(u8, out, "waited 0."));
    try testing.expect(out.len < 40);
    try testing.expect(elapsed_ms >= 100);
}

test "sleep: a fraction of a second is a legal request and not a zero" {
    // `seconds: 0.4` is how a model asks for "a moment". Truncating it to 0 would
    // make the tool a no-op that still reported success.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const t0 = std.Io.Timestamp.now(testing.io, .real).nanoseconds;
    _ = try toolSleep(testing.io, try args(arena, "{{\"seconds\":0.3}}", .{}), arena);
    const elapsed_ms: u64 = @intCast(@divTrunc(std.Io.Timestamp.now(testing.io, .real).nanoseconds - t0, std.time.ns_per_ms));
    try testing.expect(elapsed_ms >= 250);
}

test "sleep: zero is allowed and returns at once" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = try toolSleep(testing.io, try args(arena, "{{\"seconds\":0}}", .{}), arena);
    try testing.expect(std.mem.startsWith(u8, out, "waited 0."));
}

test "sleep: over the ceiling is refused instead of clamped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const t0 = std.Io.Timestamp.now(testing.io, .real).nanoseconds;
    try testing.expectError(error.SleepTooLong, toolSleep(testing.io, try args(arena, "{{\"seconds\":301}}", .{}), arena));
    // And it refused BEFORE waiting: a clamp would have sat here for five minutes.
    const elapsed_ms: u64 = @intCast(@divTrunc(std.Io.Timestamp.now(testing.io, .real).nanoseconds - t0, std.time.ns_per_ms));
    try testing.expect(elapsed_ms < 100);
}

test "sleep: nothing to parse, or a number that is not one, is named" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.MissingSeconds, toolSleep(testing.io, try args(arena, "{{}}", .{}), arena));
    try testing.expectError(error.BadSeconds, toolSleep(testing.io, try args(arena, "{{\"seconds\":\"soon\"}}", .{}), arena));
    try testing.expectError(error.BadSeconds, toolSleep(testing.io, try args(arena, "{{\"seconds\":-1}}", .{}), arena));
    // A numeric STRING is accepted: it is the same request, and refusing it costs a
    // whole round trip to fix nothing.
    const out = try toolSleep(testing.io, try args(arena, "{{\"seconds\":\"0\"}}", .{}), arena);
    try testing.expect(std.mem.startsWith(u8, out, "waited 0."));
}

test "sleep: ESC cuts the wait short and the report says how much of it happened" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The flag is global to the harness (it is what the TUI sets), so this test puts
    // it back the way it found it.
    const before = chat.cancelled();
    defer chat.cancel_current.store(before, .seq_cst);

    chat.cancel_current.store(true, .seq_cst);
    const t0 = std.Io.Timestamp.now(testing.io, .real).nanoseconds;
    const out = try toolSleep(testing.io, try args(arena, "{{\"seconds\":5}}", .{}), arena);
    const elapsed_ms: u64 = @intCast(@divTrunc(std.Io.Timestamp.now(testing.io, .real).nanoseconds - t0, std.time.ns_per_ms));

    try testing.expect(std.mem.indexOf(u8, out, "interrupted after") != null);
    try testing.expect(std.mem.indexOf(u8, out, "of the 5.0s asked for") != null);
    try testing.expect(elapsed_ms < 1000);
}
