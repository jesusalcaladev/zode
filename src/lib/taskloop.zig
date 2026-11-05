const std = @import("std");

pub const Kind = enum { probe, change, long };

pub const StopReason = enum {
    done,
    blocked,
    cancelled,
    stalled,
    ceiling,
    failed,
};

pub const Verdict = enum { none, met, blocked };

pub const Evidence = struct {
    files_written: usize = 0,
    check_green: bool = false,
    check_red: bool = false,
    checkable: bool = true,
    plan_open: u8 = 0,
    plan_done: u8 = 0,
    tools_run: usize = 0,
    verdict: Verdict = .none,
    blocked_credible: bool = false,
};

pub const Budget = struct {
    soft: usize,
    hard: usize,
    grant: usize,
    extensions: u8 = 0,
    max_extensions: u8 = 4,

    pub fn init(soft: usize, hard: usize) Budget {
        const clamped_soft = @max(soft, 4);
        const clamped_hard = @max(hard, clamped_soft);
        return .{
            .soft = clamped_soft,
            .hard = clamped_hard,
            .grant = clamped_soft,
        };
    }

    pub fn reported(self: Budget) usize {
        return self.soft;
    }

    pub fn allows(self: Budget, iterations: usize) bool {
        return iterations < self.hard;
    }

    pub fn atTarget(self: Budget, iterations: usize) bool {
        return iterations >= self.soft;
    }

    pub fn extend(self: *Budget, iterations: usize) bool {
        if (iterations < self.soft) return false;
        if (self.extensions >= self.max_extensions) return false;
        const step = if (self.grant == 0) self.soft else self.grant;
        const next = @min(self.soft + step, self.hard);
        if (next <= self.soft) return false;
        self.soft = next;
        self.extensions += 1;
        return true;
    }
};

pub const Progress = struct {
    last_change_iteration: usize = 0,
    changes: usize = 0,
    stalls: u8 = 0,

    pub fn record(self: *Progress, iteration: usize, changed: bool) void {
        if (changed) {
            self.changes += 1;
            self.last_change_iteration = iteration;
            self.stalls = 0;
        } else {
            self.stalls += 1;
        }
    }

    pub fn changedSince(self: *const Progress, iteration: usize) bool {
        return self.last_change_iteration >= iteration;
    }
};

pub const Decision = union(enum) {
    work,
    checkpoint,
    stop: StopReason,
};

pub const Policy = struct {
    budget: Budget,
    progress: Progress = .{},
    marks_at_target: usize = 0,

    pub fn init(soft: usize, hard: usize) Policy {
        return .{ .budget = Budget.init(soft, hard) };
    }

    pub fn note(self: *Policy, iteration: usize, changed: bool) void {
        self.progress.record(iteration, changed);
    }

    pub fn decide(self: *Policy, iteration: usize) Decision {
        if (!self.budget.allows(iteration)) return .{ .stop = .ceiling };
        if (!self.budget.atTarget(iteration)) return .work;
        if (self.progress.changes > self.marks_at_target and self.budget.extend(iteration)) {
            self.marks_at_target = self.progress.changes;
            return .checkpoint;
        }
        return .{ .stop = .stalled };
    }
};

pub fn classify(wants_change: bool, plan_items: usize) Kind {
    if (!wants_change) return .probe;
    if (plan_items > 2) return .long;
    return .change;
}

pub fn endReason(e: Evidence) ?StopReason {
    if (e.verdict == .blocked) {
        if (!e.blocked_credible) return null;
        return .blocked;
    }
    if (e.verdict == .met) {
        if (e.plan_open > 0) return null;
        return .done;
    }
    if (e.check_red) return null;
    if (e.files_written > 0 and e.checkable and !e.check_green) return null;
    if (e.plan_open > 0 and e.plan_done > 0 and e.tools_run > 0) return null;
    return .done;
}

// ════════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════════

const t = std.testing;

test "a short probe ends without touching the budget ladder" {
    var p = Policy.init(12, 60);
    try t.expectEqual(@as(usize, 12), p.budget.reported());
    try t.expectEqual(Decision.work, p.decide(3));
    try t.expectEqual(StopReason.done, endReason(.{ .tools_run = 1 }).?);
}

test "a long task earns an extension only while it is making progress" {
    var p = Policy.init(12, 60);
    var i: usize = 0;
    while (i < 12) : (i += 1) p.note(i, i == 2);
    try t.expectEqual(Decision.checkpoint, p.decide(12));
    try t.expectEqual(@as(usize, 24), p.budget.soft);

    switch (p.decide(24)) {
        .stop => |why| try t.expectEqual(StopReason.stalled, why),
        else => return error.TestExpectedEqual,
    }
}

test "extensions never walk past the hard wall" {
    var b = Budget.init(4, 10);
    var iter: usize = 4;
    var granted: usize = 0;
    while (b.extend(iter)) : (iter = b.soft) {
        granted += 1;
        try t.expect(b.soft <= b.hard);
        if (granted > 10) return error.TestExpectedEqual;
    }
    try t.expectEqual(@as(usize, 10), b.soft);
    try t.expect(!b.allows(10));
}

test "the model may not end a written change without a green check" {
    const unverified = Evidence{ .files_written = 2, .tools_run = 4 };
    try t.expect(endReason(unverified) == null);
    const red = Evidence{ .files_written = 2, .tools_run = 4, .check_red = true };
    try t.expect(endReason(red) == null);
    const green = Evidence{ .files_written = 2, .tools_run = 4, .check_green = true };
    try t.expectEqual(StopReason.done, endReason(green).?);
}

test "a project the harness cannot check may end, and says so" {
    const unchecked = Evidence{ .files_written = 2, .tools_run = 4, .checkable = false };
    try t.expectEqual(StopReason.done, endReason(unchecked).?);
}

test "met with open plan steps is refused, blocked without evidence is refused" {
    try t.expect(endReason(.{ .verdict = .met, .plan_open = 2, .plan_done = 1 }) == null);
    try t.expectEqual(StopReason.done, endReason(.{ .verdict = .met }).?);
    try t.expect(endReason(.{ .verdict = .blocked }) == null);
    try t.expectEqual(StopReason.blocked, endReason(.{ .verdict = .blocked, .blocked_credible = true }).?);
}

test "an open plan with work behind it is not a finished task" {
    try t.expect(endReason(.{ .plan_open = 1, .plan_done = 2, .tools_run = 5 }) == null);
    try t.expectEqual(StopReason.done, endReason(.{ .plan_open = 1, .plan_done = 2, .tools_run = 0 }).?);
}

test "task kind is a hint, never a permission" {
    try t.expectEqual(Kind.probe, classify(false, 0));
    try t.expectEqual(Kind.change, classify(true, 0));
    try t.expectEqual(Kind.long, classify(true, 3));
}