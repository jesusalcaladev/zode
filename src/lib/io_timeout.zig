//! Per-client I/O timeout without touching std (Phase 40.10).
//!
//! Zig 0.17's `std.http.Client.RequestOptions` has no timeout field, but
//! `std.Io.operateTimeout` can bound any single low-level operation. This
//! module wraps ONLY `vtable.operate`; every other vtable entry is the
//! original and keeps receiving the original userdata.
//!
//! Threadlocal because the wrapper state belongs to the thread that runs the
//! HTTP client. Nested wrapping is shared by a refcount so an inner client
//! cannot release a wrapper an outer one still uses.

const std = @import("std");

const Slot = struct {
    io: ?std.Io = null,
    timeout: std.Io.Timeout = .none,
    vtable: std.Io.VTable = undefined,
    refs: usize = 0,
    /// The thread that called `wrap`. A wrapped `Io` borrows this thread's
    /// vtable; using it on another thread reads a DIFFERENT threadlocal slot,
    /// which used to fail as a silent `error.Canceled` — indistinguishable
    /// from a real timeout, so the bug looked like a flaky network.
    owner: std.Thread.Id = 0,
};

threadlocal var slot: Slot = .{};

fn timedOperate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
    _ = userdata; // inner userdata is captured in slot.io
    const inner = slot.io orelse @panic("io_timeout: wrapped Io used on a thread that never called wrap()");
    const result = std.Io.operateTimeout(inner, operation, slot.timeout) catch |err| switch (err) {
        // Timeout means the bound fired: the client sees a failed request
        // instead of a hung worker. Map ConcurrencyUnavailable the same way.
        error.Timeout, error.ConcurrencyUnavailable => return error.Canceled,
        error.Canceled => return error.Canceled,
    };
    return result;
}

/// Wrap `inner` so each I/O operation is bounded by `timeout`.
/// The returned Io borrows a threadlocal vtable: use it on the SAME thread.
pub fn wrap(inner: std.Io, timeout: std.Io.Timeout) std.Io {
    if (timeout == .none) return inner;
    if (slot.io != null) {
        slot.refs += 1;
        return .{ .userdata = slot.io.?.userdata, .vtable = &slot.vtable };
    }
    slot.owner = std.Thread.getCurrentId();
    slot.io = inner;
    slot.timeout = timeout;
    slot.vtable = inner.vtable.*;
    slot.vtable.operate = timedOperate;
    slot.refs = 1;
    return .{ .userdata = inner.userdata, .vtable = &slot.vtable };
}

/// Release one reference. Must be called on the same thread as `wrap`.
pub fn unwrap() void {
    if (slot.refs == 0) @panic("io_timeout: unwrap on a thread with no wrapped Io (deinit on the wrong thread?)");
    if (slot.owner != std.Thread.getCurrentId()) @panic("io_timeout: unwrap on a different thread than wrap()");
    slot.refs -= 1;
    if (slot.refs == 0) slot = .{};
}

test "io_timeout: wrap returns the inner Io unchanged when the timeout is none" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const inner = threaded.io();
    const wrapped = wrap(inner, .none);
    try std.testing.expect(wrapped.userdata == inner.userdata);
    try std.testing.expect(wrapped.vtable == inner.vtable);
}

test "io_timeout: wrap/unwrap on the owning thread releases the slot" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const inner = threaded.io();
    const timeout = std.Io.Timeout{ .duration = .{
        .raw = .fromMilliseconds(1000),
        .clock = .awake,
    } };
    const wrapped = wrap(inner, timeout);
    try std.testing.expect(wrapped.vtable != inner.vtable);
    try std.testing.expectEqual(@as(usize, 1), slot.refs);
    try std.testing.expectEqual(std.Thread.getCurrentId(), slot.owner);
    unwrap();
    try std.testing.expect(slot.io == null);
    try std.testing.expectEqual(@as(usize, 0), slot.refs);
}

test "io_timeout: nested wraps share one slot and both references are released" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const timeout = std.Io.Timeout{ .duration = .{
        .raw = .fromMilliseconds(1000),
        .clock = .awake,
    } };
    _ = wrap(threaded.io(), timeout);
    _ = wrap(threaded.io(), timeout);
    try std.testing.expectEqual(@as(usize, 2), slot.refs);
    unwrap();
    try std.testing.expectEqual(@as(usize, 1), slot.refs);
    unwrap();
    try std.testing.expect(slot.io == null);
}
