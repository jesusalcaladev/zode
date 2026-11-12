const std = @import("std");
const tui = @import("../tui.zig");
const chat = @import("../chat.zig");
const router_mod = @import("../lib/router.zig");
const roster_mod = @import("../roster.zig");
const free_auto = @import("../free_auto.zig");
const submodel_mod = @import("submodel.zig");

pub const Target = submodel_mod.Target;

pub const Action = union(enum) {
    retry_request,
    cancelled,
    fail: anyerror,
};

pub const Ops = struct {
    cheap_router: *router_mod.State,
    quotaVerdict: *const fn (anyerror, []const u8) ?roster_mod.Why,
    switchTo: *const fn (std.mem.Allocator, roster_mod.Why, []const u8) ?free_auto.Switch,
    targetForCandidate: *const fn (*tui.Model, roster_mod.Candidate) ?Target,
    updateModelContextFromPick: *const fn (Target) void,
    pushSwitchNotice: *const fn (*tui.Model, free_auto.Switch, Target) void,
    isRetryable: *const fn (anyerror) bool,
    pushRetryNotice: *const fn (*tui.Model, anyerror, usize) void,
    waitRetry: *const fn (usize) anyerror!void,
    noteTurnFailure: *const fn (*tui.Model, anyerror, Target) void,
    setAnswering: *const fn ([]const u8) void,
    pushCheapFallbackInfo: *const fn (*tui.Model, router_mod.Why, []const u8) void,
};

pub fn handleTurnStreamError(
    gpa: std.mem.Allocator,
    m: *tui.Model,
    err: anyerror,
    attempt: usize,
    active_pick: Target,
    pick: *Target,
    used_cheap: *bool,
    rotations: *u8,
    ops: Ops,
) Action {
    // Cheap router fallback before quota/retry handling.
    if (used_cheap.*) {
        if (router_mod.onFailure(ops.cheap_router, err, chat.lastErrorBody(), active_pick.model)) {
            pick.* = active_pick;
            used_cheap.* = false;
            ops.setAnswering(pick.model);
            const w = router_mod.why(err, chat.lastErrorBody());
            ops.pushCheapFallbackInfo(m, w, pick.model);
            return .retry_request;
        }
        // Account error: fallback would fail the same way; keep cheap state off for normal handling.
        used_cheap.* = false;
        ops.setAnswering("");
    }

    // Free-auto quota rotation before retry backoff.
    if (ops.quotaVerdict(err, chat.lastErrorBody())) |why| {
        if (rotations.* < roster_mod.max_rotations_per_turn) {
            if (ops.switchTo(gpa, why, chat.lastErrorBody())) |sw| {
                if (ops.targetForCandidate(m, sw.cand)) |next| {
                    rotations.* += 1;
                    pick.* = next;
                    ops.updateModelContextFromPick(pick.*);
                    ops.pushSwitchNotice(m, sw, pick.*);
                    return .retry_request;
                }
            }
            // No live pair left: fall through to normal retry/terminal handling.
        }
    }

    if (ops.isRetryable(err) and attempt < 3) {
        ops.pushRetryNotice(m, err, attempt);
        ops.waitRetry(attempt) catch return .cancelled; // ESC cuts it short
        return .retry_request;
    }

    // Retries exhausted/terminal: drop pair for future turns and fail this turn.
    ops.noteTurnFailure(m, err, pick.*);
    return .{ .fail = err };
}
