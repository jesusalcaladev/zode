const std = @import("std");
const tui = @import("../tui.zig");

/// Queues or starts a chat turn. Handles queue-vs-spawn and TUI
/// streaming/busy bookkeeping; worker owns the job lifetime.
pub fn startQueuedOrSpawn(
    comptime Job: type,
    m: *tui.Model,
    copy: []u8,
    mode: anytype,
    bash_allow_rules: []const []const u8,
    expand_cmdsubst: bool,
    comptime worker: fn (*Job) void,
    comptime set_thinking: fn (*tui.Model) void,
) !void {
    if (m.isBusy()) {
        _ = m.enqueueTurn(.{
            .text = copy,
            .mode = mode,
            .bash_allow_rules = bash_allow_rules,
            .expand_cmdsubst = expand_cmdsubst,
        });
        m.pushInfoFmt("⏳ queued ({d} waiting)", .{m.queuedCount()});
        return;
    }

    m.beginCheckpoint(copy);
    m.streamStart();
    set_thinking(m);

    const job = try m.allocator.create(Job);
    m.beginWorker();
    job.* = .{
        .model = m,
        .text = copy,
        .mode = mode,
        .bash_allow_rules = bash_allow_rules,
        .expand_cmdsubst = expand_cmdsubst,
    };
    const spawned = std.Thread.spawn(.{}, worker, .{job}) catch null;
    const th = spawned orelse {
        m.endWorker();
        m.allocator.destroy(job);
        m.allocator.free(copy);
        m.streamEnd();
        return error.ThreadSpawnFailed;
    };
    th.detach();
}
