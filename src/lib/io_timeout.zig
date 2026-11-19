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
};

threadlocal var slot: Slot = .{};

fn timedOperate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
    _ = userdata; // inner userdata is captured in slot.io
    const inner = slot.io orelse return error.Canceled;
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
    slot.io = inner;
    slot.timeout = timeout;
    slot.vtable = inner.vtable.*;
    slot.vtable.operate = timedOperate;
    slot.refs = 1;
    return .{ .userdata = inner.userdata, .vtable = &slot.vtable };
}

/// Release one reference. Must be called on the same thread as `wrap`.
pub fn unwrap() void {
    if (slot.refs > 0) slot.refs -= 1;
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
