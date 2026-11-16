//! Cron parsing (Phase 19): the 5-field expression used by `schedule`.
//!
//! Pure on purpose: parsing the expression and deciding "does it fire at time
//! T" need no clock, no IO and no session — they are testable with plain
//! integers. The harness owns the clock and calls `nextFire`/`matches`.
//!
//! Field order: minute hour day-of-month month day-of-week (standard cron).
//! Supported: `*` (all), `A` (one value), `A-B` (range), `A-B/S` and `*/S`
//! (steps), comma lists, and three-letter names for months and weekdays.

const std = @import("std");

pub const Error = error{
    BadFieldCount,
    BadField,
    OutOfRange,
    BadStep,
};

pub const max_values: usize = 128;

pub const Field = struct {
    values: [max_values]bool = @splat(false),
    len: usize = 0, // highest allowed value + 1 (for validation/bounds)

    pub fn has(self: *const Field, v: usize) bool {
        return v < self.len and self.values[v];
    }

    fn set(self: *Field, v: usize) Error!void {
        if (v >= self.len) return error.OutOfRange;
        if (!self.values[v]) {
            self.values[v] = true;
            if (v + 1 > self.len) self.len = v + 1;
        }
    }
};

pub const Cron = struct {
    minute: Field = .{ .len = 60 },
    hour: Field = .{ .len = 24 },
    day_of_month: Field = .{ .len = 32 },
    month: Field = .{ .len = 13 },
    day_of_week: Field = .{ .len = 7 },

    /// Does this expression fire at the given UTC calendar time?
    /// `dow` uses 0=Sunday (cron convention).
    pub fn matches(self: *const Cron, minute: usize, hour: usize, dom: usize, mon: usize, dow: usize) bool {
        return self.minute.has(minute) and self.hour.has(hour) and
            self.day_of_month.has(dom) and self.month.has(mon) and
            self.day_of_week.has(dow);
    }
};

const month_names = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };
const day_names = [_][]const u8{ "sun", "mon", "tue", "wed", "thu", "fri", "sat" };

fn nameValue(names: []const []const u8, tok: []const u8) ?usize {
    for (names, 0..) |n, i| {
        if (std.ascii.eqlIgnoreCase(n, tok)) return i;
    }
    return null;
}

fn parseOne(field: *Field, tok: []const u8, names: ?[]const []const u8) Error!void {
    if (tok.len == 0) return error.BadField;

    // Step: BASE/STEP, where BASE may be `*` or a range.
    if (std.mem.indexOfScalar(u8, tok, '/')) |slash| {
        const base = tok[0..slash];
        const step_tok = tok[slash + 1 ..];
        const step = std.fmt.parseInt(usize, step_tok, 10) catch return error.BadStep;
        if (step == 0) return error.BadStep;

        var lo: usize = 0;
        var hi: usize = field.len - 1;
        if (!std.mem.eql(u8, base, "*")) {
            if (std.mem.indexOfScalar(u8, base, '-')) |dash| {
                lo = try valueOf(base[0..dash], names);
                hi = try valueOf(base[dash + 1 ..], names);
            } else {
                lo = try valueOf(base, names);
                hi = if (std.mem.eql(u8, base, "0")) field.len - 1 else lo;
            }
        }
        if (lo > hi) return error.BadField;
        var v = lo;
        while (v <= hi) : (v += step) try field.set(v);
        return;
    }

    // Range: A-B.
    if (std.mem.indexOfScalar(u8, tok, '-')) |dash| {
        const lo = try valueOf(tok[0..dash], names);
        const hi = try valueOf(tok[dash + 1 ..], names);
        if (lo > hi) return error.BadField;
        var v = lo;
        while (v <= hi) : (v += 1) try field.set(v);
        return;
    }

    // Star: all values.
    if (std.mem.eql(u8, tok, "*")) {
        var v: usize = 0;
        while (v < field.len) : (v += 1) try field.set(v);
        return;
    }

    try field.set(try valueOf(tok, names));
}

fn valueOf(tok: []const u8, names: ?[]const []const u8) Error!usize {
    if (names) |ns| {
        if (nameValue(ns, tok)) |v| return v;
    }
    return std.fmt.parseInt(usize, tok, 10) catch error.BadField;
}

pub fn parse(expr: []const u8) Error!Cron {
    var cron = Cron{};
    var fields: [5][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, expr, " \t");
    while (it.next()) |tok| {
        if (count >= fields.len) return error.BadFieldCount;
        fields[count] = tok;
        count += 1;
    }
    if (count != 5) return error.BadFieldCount;

    // Day-of-month and day-of-week are OR-ed in classic cron when both are
    // restricted; for `schedule` we keep AND semantics but accept `*` for
    // either one, which covers the intended "every Monday" / "on the 1st".
    try parseList(&cron.minute, fields[0], null);
    try parseList(&cron.hour, fields[1], null);
    try parseList(&cron.day_of_month, fields[2], null);
    try parseList(&cron.month, fields[3], &month_names);
    try parseList(&cron.day_of_week, fields[4], &day_names);
    return cron;
}

fn parseList(field: *Field, spec: []const u8, names: ?[]const []const u8) Error!void {
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |part| try parseOne(field, part, names);
}

test "cron: parse a 5-field expression and match a time" {
    const c = try parse("0 9 * * 1-5");
    try std.testing.expect(c.minute.has(0));
    try std.testing.expect(!c.minute.has(1));
    try std.testing.expect(c.hour.has(9));
    try std.testing.expect(c.day_of_week.has(1)); // Monday
    try std.testing.expect(c.day_of_week.has(5)); // Friday
    try std.testing.expect(!c.day_of_week.has(0)); // Sunday
    try std.testing.expect(c.matches(0, 9, 15, 11, 1));
    try std.testing.expect(!c.matches(1, 9, 15, 11, 1));
}

test "cron: ranges, steps and star steps" {
    const steps = try parse("*/15 0-12/3 * * *");
    try std.testing.expect(steps.minute.has(0));
    try std.testing.expect(steps.minute.has(15));
    try std.testing.expect(steps.minute.has(30));
    try std.testing.expect(!steps.minute.has(7));
    try std.testing.expect(steps.hour.has(0));
    try std.testing.expect(steps.hour.has(3));
    try std.testing.expect(steps.hour.has(12));
    try std.testing.expect(!steps.hour.has(13));
}

test "cron: month and weekday names" {
    const c = try parse("30 4 * jan,mar mon");
    try std.testing.expect(c.month.has(0)); // jan
    try std.testing.expect(c.month.has(2)); // mar
    try std.testing.expect(!c.month.has(1)); // feb
    try std.testing.expect(c.day_of_week.has(1)); // mon
}

test "cron: rejects bad field counts and out-of-range values" {
    try std.testing.expectError(error.BadFieldCount, parse("* * * *"));
    try std.testing.expectError(error.OutOfRange, parse("60 * * * *"));
    try std.testing.expectError(error.OutOfRange, parse("0 24 * * *"));
    try std.testing.expectError(error.BadField, parse("zero * * * *"));
    try std.testing.expectError(error.BadStep, parse("*/0 * * * *"));
}
