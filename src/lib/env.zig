//! Reading `ZODE_*` out of an environment map.
//!
//! ## Why this is a module and not two functions in `agent.zig`
//!
//! Because `agent.zig` is not the only thing that reads these. The automatic typecheck
//! moved to `src/autochk.zig`, and it reads `ZODE_AUTO_CHECK` — and it must read it from
//! the same rule as everything else, or "turn the automatic check off" works in the TUI
//! and does nothing in `--chat`, which is the exact shape of bug this repo keeps
//! hitting.
//!
//! The rule itself is three lines. The module exists so there is exactly one copy of it,
//! and so neither owner has to reach into the other's globals to get it: `truthy` in
//! `agent.zig` reads `environ_global`, and `truthyIn` here is the pure part under it.

const std = @import("std");

/// The value of `key`, or null. A null map is "no environment", which is what the
/// tests pass, and it reads as unset rather than as a crash.
pub fn getIn(env: ?*const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const m = env orelse return null;
    const v = m.get(key) orelse return null;
    return if (v.len == 0) null else v;
}

/// Is this flag on?
///
/// ## The rules, and why they are these
///
/// - **Unset takes the default.** A harness whose behaviour depends on a variable the
///   user has never heard of is a harness that behaves differently on their machine.
/// - **Explicit off is off**, and it is checked with case-insensitive `0`, `false`, `no`
///   and `off`. Just `0` was the first version and it made `ZODE_AUTO_CHECK=false` mean
///   ON, which is the worst possible direction for a flag that decides whether the
///   harness checks your code.
/// - **Anything else is ON.** An unrecognised value is not a reason to disable a safety
///   feature silently. The mistake is loud — it does the thing — instead of quiet.
pub fn truthyIn(env: ?*const std.process.Environ.Map, key: []const u8, default: bool) bool {
    const raw = getIn(env, key) orelse return default;
    if (raw.len == 0) return default;
    const off = [_][]const u8{ "0", "false", "no", "off" };
    for (off) |o| {
        if (std.ascii.eqlIgnoreCase(raw, o)) return false;
    }
    return true;
}

const t = std.testing;

test "unset takes the default, and explicit off is really off" {
    var map: std.process.Environ.Map = .init(t.allocator);
    defer map.deinit();

    try t.expect(truthyIn(&map, "ZODE_X", true));
    try t.expect(!truthyIn(&map, "ZODE_X", false));

    // The four spellings of off. `false` is the one that used to mean ON, because the
    // first version only checked for "0" — and a flag that decides whether the harness
    // checks your code is exactly where that direction hurts.
    for ([_][]const u8{ "0", "false", "FALSE", "no", "off" }) |v| {
        map.put("ZODE_X", v) catch return error.OutOfMemory;
        try t.expect(!truthyIn(&map, "ZODE_X", true));
        map.put("ZODE_X", "1") catch return error.OutOfMemory;
        try t.expect(truthyIn(&map, "ZODE_X", false));
    }

    // No environment at all: the tests build a `Model` without an app, and reading an
    // unset environment must be the default and not a crash.
    try t.expect(truthyIn(null, "ZODE_X", true));
    try t.expectEqual(@as(?[]const u8, null), getIn(null, "ZODE_X"));
}

test "an empty value is unset, not an off" {
    // `ZODE_X=` in a shell is a different thing from `ZODE_X=0`, and treating the first
    // as the second silently disables a feature for anyone who writes the empty one by
    // accident.
    var map: std.process.Environ.Map = .init(t.allocator);
    defer map.deinit();
    map.put("ZODE_X", "") catch return error.OutOfMemory;
    try t.expect(truthyIn(&map, "ZODE_X", true));
}

test "an unrecognised value turns the flag ON, loudly" {
    // The alternative — treat a typo as off — is how a safety feature disappears
    // without anybody deciding to remove it.
    var map: std.process.Environ.Map = .init(t.allocator);
    defer map.deinit();
    map.put("ZODE_X", "maybe") catch return error.OutOfMemory;
    try t.expect(truthyIn(&map, "ZODE_X", false));
    map.put("ZODE_X", "yes please") catch return error.OutOfMemory;
    try t.expect(truthyIn(&map, "ZODE_X", false));
}
