/// A probe that measures what a `bash` tool call COSTS in the harness, with no model
/// and no network in the way.
///
/// It exists because "the shell calls are slow" cannot be acted on without knowing
/// which part is slow. A `bash` call has three costs and they are wildly different:
///
///   1. the child process itself (`/bin/sh -c ...`) — measured here as the FLOOR, in
///      the same process and the same run, so it is the same machine and the same
///      clock as the number it is compared against;
///   2. OUR overhead on top: argument parsing, the JSON, the capture buffers, the
///      auto-background classification, the permission lookup;
///   3. the model's round trip, which is seconds and is not measured at all.
///
/// Only (2) is ours to remove.
///
/// Three things this had to get right, each of them a measurement trap:
///
/// - **The two loops are INTERLEAVED, not sequential.** Measuring the floor for 40
///   rounds and then the tool for 40 rounds charged all the process-creation warmup
///   (page cache, first fork, allocator arena growth) to the first one, and it came
///   out as OUR overhead being NEGATIVE: 18.5 ms through the tool against a 20.7 ms
///   "floor". A number below the floor is not a result, it is a warmup.
/// - **The cases carry OUTPUT**, because a `true` is the one command whose cost is
///   almost entirely the fork. The copy is where our buffers would show up, so a
///   probe that only runs `true` cannot see the thing it is looking for.
/// - **No command that zode sends to the background.** `verify.classify` recognises
///   `zig build`, `npm test`, `pytest`, `*_smoke.py` and friends and starts them in
///   the background even when the model did not ask, so those would measure the
///   background path instead of the question.
const std = @import("std");
const tools = @import("tools_root.zig");

const rounds: usize = 30;

const Case = struct {
    label: []const u8,
    /// The shell command, which is also what the tool is asked to run.
    cmd: []const u8,
    /// The JSON the model would send. Kept beside the command instead of composed
    /// from it, because the point is to measure what really goes over the wire.
    args: []const u8,
};

const cases = [_]Case{
    .{
        .label = "no output",
        .cmd = "true",
        .args = "{\"command\":\"true\",\"timeout_seconds\":30}",
    },
    .{
        .label = "8 KB of output",
        .cmd = "seq 1 800",
        .args = "{\"command\":\"seq 1 800\",\"timeout_seconds\":30}",
    },
    .{
        .label = "512 KB of output (truncated)",
        .cmd = "seq 1 40000",
        .args = "{\"command\":\"seq 1 40000\",\"timeout_seconds\":30}",
    },
};

fn nowMs(io: std.Io) f64 {
    const ns = std.Io.Timestamp.now(io, .real).toNanoseconds();
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    const w = &fw.interface;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var tool_ms: [cases.len]f64 = @splat(0);
    var floor_ms: [cases.len]f64 = @splat(0);
    var tool_err: [cases.len]usize = @splat(0);
    var tool_errmsg: [cases.len][]const u8 = @splat("");

    // Warmup, thrown away: the first fork in a process pays for a lot.
    for (0..3) |_| {
        _ = std.process.run(gpa, io, .{
            .argv = &.{ "/bin/sh", "-c", "true" },
            .stdout_limit = .limited(64 * 1024),
            .stderr_limit = .limited(64 * 1024),
        }) catch {};
        _ = tools.execute(io, "bash", cases[0].args, a, null, null) catch {};
    }

    // Interleaved, so neither side pays the whole warmup.
    for (0..rounds) |_| {
        for (cases, 0..) |c, i| {
            const t0 = nowMs(io);
            _ = std.process.run(gpa, io, .{
                .argv = &.{ "/bin/sh", "-c", c.cmd },
                .stdout_limit = .limited(64 * 1024),
                .stderr_limit = .limited(64 * 1024),
            }) catch {};
            floor_ms[i] += nowMs(io) - t0;

            const t1 = nowMs(io);
            if (tools.execute(io, "bash", c.args, a, null, null)) |_| {} else |e| {
                tool_err[i] += 1;
                tool_errmsg[i] = @errorName(e);
            }
            tool_ms[i] += nowMs(io) - t1;
        }
    }

    try w.print("bash tool overhead, {d} interleaved rounds per case\n\n", .{rounds});
    try w.print("  {s:<30} {s:>10} {s:>10} {s:>12} {s:>8}\n", .{
        "case", "child", "through", "OUR overhead", "x floor",
    });
    for (cases, 0..) |c, i| {
        const f = floor_ms[i] / @as(f64, @floatFromInt(rounds));
        const t = tool_ms[i] / @as(f64, @floatFromInt(rounds));
        try w.print("  {s:<30} {d:>9.3}ms {d:>9.3}ms {d:>11.3}ms {d:>7.2}x", .{
            c.label, f, t, t - f, t / @max(f, 0.000001),
        });
        if (tool_err[i] > 0) try w.print("  ({d} errors: {s})", .{ tool_err[i], tool_errmsg[i] });
        try w.print("\n", .{});
    }
    try w.print("\n", .{});
    try w.flush();
}
