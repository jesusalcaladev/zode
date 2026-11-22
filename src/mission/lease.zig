//! Task leases (pure): claim / renew / release / expire / bounded retry.

const std = @import("std");

pub const Status = enum { pending, in_progress, completed, failed };
pub const Lease = struct {
    id: u32,
    subject: []const u8,
    status: Status = .pending,
    owner: []const u8 = "",
    attempts: usize = 0,
    lease_until: i64 = 0,
    last_error: []const u8 = "",
    verify: []const u8 = "",
};
pub const max_attempts: usize = 3;
pub const default_ttl_ms: i64 = 300_000;

pub fn fromTasks(gpa: std.mem.Allocator, tasks: []const TaskInput) ![]Lease {
    var out = std.ArrayList(Lease).empty;
    errdefer out.deinit(gpa);
    for (tasks, 0..) |t, i| {
        try out.append(gpa, .{
            .id = if (t.id > 0) t.id else @intCast(i + 1),
            .subject = try gpa.dupe(u8, t.subject),
            .verify = try gpa.dupe(u8, t.verify),
        });
    }
    return out.toOwnedSlice(gpa);
}

pub const TaskInput = struct { id: u32 = 0, subject: []const u8, verify: []const u8 = "" };

pub fn isLeased(leases: []const Lease, id: u32, now: i64) bool {
    for (leases) |l| if (l.id == id and l.status == .in_progress and l.lease_until > now) return true;
    return false;
}

pub fn claim(leases: []Lease, id: u32, owner: []const u8, now: i64, ttl: i64) bool {
    for (leases) |*l| {
        if (l.id != id or l.status == .completed or l.attempts >= max_attempts) continue;
        if (isLeased(leases, id, now)) return false;
        l.status = .in_progress;
        l.owner = owner;
        l.lease_until = now + ttl;
        l.last_error = "";
        return true;
    }
    return false;
}

pub fn renew(leases: []Lease, id: u32, now: i64, ttl: i64) bool {
    for (leases) |*l| {
        if (l.id == id and l.status == .in_progress) {
            l.lease_until = @max(l.lease_until, now) + ttl;
            return true;
        }
    }
    return false;
}

pub fn release(leases: []Lease, id: u32, status: Status) bool {
    for (leases) |*l| {
        if (l.id == id) {
            l.status = status;
            l.owner = "";
            l.lease_until = 0;
            l.last_error = "";
            return true;
        }
    }
    return false;
}

pub fn fail(leases: []Lease, id: u32, error_text: []const u8) bool {
    for (leases) |*l| {
        if (l.id == id) {
            l.attempts += 1;
            l.last_error = error_text;
            l.status = if (l.attempts >= max_attempts) .failed else .pending;
            l.owner = "";
            l.lease_until = 0;
            return true;
        }
    }
    return false;
}

pub fn expired(leases: []const Lease, now: i64, out: []u32) usize {
    var n: usize = 0;
    for (leases) |l| {
        if (n >= out.len) break;
        if (l.status == .in_progress and l.lease_until > 0 and l.lease_until <= now) {
            out[n] = l.id;
            n += 1;
        }
    }
    return n;
}

pub fn retryable(leases: []const Lease, id: u32) bool {
    for (leases) |l| if (l.id == id) return l.status != .completed and l.attempts < max_attempts;
    return false;
}

test "lease: claim, renew, expire and bounded retry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tasks = [_]TaskInput{.{ .id = 1, .subject = "a" }};
    const leases = try fromTasks(a, &tasks);
    try std.testing.expect(claim(leases, 1, "w1", 1000, 100));
    try std.testing.expect(!claim(leases, 1, "w2", 1000, 100));
    try std.testing.expect(renew(leases, 1, 1050, 100));
    var ids: [4]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), expired(leases, 1149, &ids));
    try std.testing.expectEqual(@as(usize, 1), expired(leases, 1151, &ids));
    try std.testing.expect(fail(leases, 1, "expired"));
    try std.testing.expect(retryable(leases, 1));
    _ = release(leases, 1, .completed);
    try std.testing.expect(!claim(leases, 1, "w3", 2000, 100));
}
