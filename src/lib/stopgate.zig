//! Shared hard-stop rules for both runners.
//!
//! The interactive loop (`taskloop`) and the mission supervisor
//! (`mission/contract.zig`) used to own separate ceilings. This module is the
//! ONE ordered list of reasons a loop may not continue, written as pure data
//! so neither runner can quietly change the priority. They are wired together
//! as a shared Build module because a source file can belong to only one
//! module in Zig; importing the same `.zig` from both module roots is an error.
//!
//! Zero means "unlimited" for every budget field. An absent ceiling never
//! invents a stop.

const std = @import("std");

pub const Reason = enum {
    none,
    stop_file,
    inactive,
    deadline,
    budget,
    turns,
    writes,
    failures,
    blocked,
};

pub const Input = struct {
    stop_file: bool = false,
    active: bool = true,
    deadline_exceeded: bool = false,
    cost_usd: f64 = 0,
    budget_usd: f64 = 0,
    turn: usize = 0,
    max_turns: usize = 0,
    writes: usize = 0,
    max_writes: usize = 0,
    failures: usize = 0,
    max_failures: usize = 0,
    blocked: bool = false,
};

/// The kill switch and explicit blocks come FIRST. A green result, a cheap
/// run or an unfinished plan never outranks "the operator stopped this".
pub fn firstStop(input: Input) Reason {
    if (input.stop_file) return .stop_file;
    if (!input.active) return .inactive;
    if (input.deadline_exceeded) return .deadline;
    if (input.budget_usd > 0 and input.cost_usd >= input.budget_usd) return .budget;
    if (input.max_turns > 0 and input.turn >= input.max_turns) return .turns;
    if (input.max_writes > 0 and input.writes >= input.max_writes) return .writes;
    if (input.max_failures > 0 and input.failures >= input.max_failures) return .failures;
    if (input.blocked) return .blocked;
    return .none;
}

pub fn isStop(reason: Reason) bool {
    return reason != .none;
}

test "stopgate: kill switch and blocked verdict beat every ceiling" {
    const all: Input = .{
        .deadline_exceeded = true, .cost_usd = 9, .budget_usd = 5,
        .turn = 99, .max_turns = 10, .writes = 99, .max_writes = 10,
        .failures = 9, .max_failures = 3, .blocked = true,
    };
    try std.testing.expectEqual(Reason.stop_file, firstStop(.{ .stop_file = true, .blocked = true }));
    try std.testing.expectEqual(Reason.inactive, firstStop(.{ .active = false, .blocked = true }));
    try std.testing.expectEqual(Reason.deadline, firstStop(all));
    try std.testing.expectEqual(Reason.budget, firstStop(.{ .cost_usd = 5, .budget_usd = 5, .turn = 99, .max_turns = 10 }));
    try std.testing.expectEqual(Reason.turns, firstStop(.{ .turn = 10, .max_turns = 10, .writes = 99, .max_writes = 10 }));
    try std.testing.expectEqual(Reason.writes, firstStop(.{ .writes = 10, .max_writes = 10, .failures = 9, .max_failures = 3 }));
    try std.testing.expectEqual(Reason.failures, firstStop(.{ .failures = 3, .max_failures = 3, .blocked = true }));
    try std.testing.expectEqual(Reason.blocked, firstStop(.{ .blocked = true }));
}

test "stopgate: zero ceilings are unlimited, not stops" {
    const none: Input = .{ .cost_usd = 1000, .turn = 500, .writes = 500, .failures = 500 };
    try std.testing.expectEqual(Reason.none, firstStop(none));
    try std.testing.expect(!isStop(firstStop(none)));
}
