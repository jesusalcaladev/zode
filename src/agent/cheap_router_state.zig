const std = @import("std");
const router_mod = @import("../lib/router.zig");

pub const CheapStats = struct {
    on: bool,
    model: []const u8,
    attempts: u32,
    fallbacks: u32,
    given_up: bool,
};

var state: router_mod.State = .{};
var on: bool = false;
pub var cheap_model_buf: [128]u8 = undefined;

pub fn initFromEnv(env: ?*const std.process.Environ.Map) void {
    state = router_mod.initFromEnv(env);
    if (state.cheap_model.len > 0) {
        const n = @min(state.cheap_model.len, cheap_model_buf.len);
        std.mem.copyForwards(u8, cheap_model_buf[0..n], state.cheap_model[0..n]);
        state.cheap_model = cheap_model_buf[0..n];
    }
    on = state.cheap_model.len > 0;
}

pub fn stats() CheapStats {
    return .{
        .on = on,
        .model = state.cheap_model,
        .attempts = state.attempts,
        .fallbacks = state.fallbacks,
        .given_up = state.given_up,
    };
}

pub fn resetIfGivenUp() bool {
    if (!on or !state.given_up) return false;
    state.given_up = false;
    state.attempts = 0;
    state.fallbacks = 0;
    state.last_why = null;
    return true;
}

pub fn isOn() bool { return on; }
pub fn givenUp() bool { return state.given_up; }
pub fn statePtr() *router_mod.State { return &state; }
pub fn cheapModel() []const u8 { return state.cheap_model; }
