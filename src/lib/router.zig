/// Which model answers the MAIN turn: the cheap one or the one the user picked.
///
/// ## Why this is opt-in and not the default
///
/// `ZODE_CHEAP_TURN=1`, and off otherwise. The default stays the model the user
/// chose because the failure mode is invisible from the outside: a small model
/// that is not available for your account answers **403**, the turn fails, and
/// the model has no way to know the fallback would have worked. Turning it on
/// silently is trading "correct but expensive" for "cheap and sometimes broken".
///
/// The subagents already run at effort `low` for the same money, which is where
/// this idea is paid for without that risk.
///
/// ## The rule, and it is NOT the same rule as `/free-auto`
///
/// The cheap model is given up when the cheap MODEL is wrong, and never when the
/// ACCOUNT is wrong:
///
/// | error | cheap model | why |
/// |---|---|---|
/// | 403 with the gate text | give it up | opencode's gate: only the official client |
/// | 403 without it | give it up | the model is not available on this account |
/// | 404 | give it up | the id does not exist; the real one will |
/// | 401 | **keep it** | the KEY is wrong: falling back hides a broken key behind a fallback that fails too, and the error reported is the wrong one |
/// | 402 | **keep it** | no credits: the paid model fails identically |
/// | 429 | **keep it** | transient, and the retry with backoff is the answer |
/// | 5xx | **keep it** | the provider is having a moment, not the model |
///
/// `/free-auto` rotates on 402/429/403-gated because it is escaping a QUOTA.
/// This falls back because a MODEL is unusable. Using the same table here would
/// mean reporting "the small model is out of quota" when the real problem is
/// that the key is wrong.
const std = @import("std");

pub const cheap_env = "ZODE_CHEAP_TURN";
pub const cheap_model_env = "ZODE_CHEAP_MODEL";

/// Once the cheap model has said no, it is not asked again this session.
///
/// A session-long flag and not a per-turn one, on purpose: a model that is gated
/// is gated tomorrow too, and re-asking costs a 403 and a fallback on every
/// single turn of the rest of the session.
pub const State = struct {
    /// The cheap model to try first, or "" when the user did not name one.
    cheap_model: []const u8 = "",
    /// Set once the cheap model has been disqualified.
    given_up: bool = false,
    /// How many turns have actually been sent to the cheap model. Only used to
    /// report the saving, and it counts attempts, not successes.
    attempts: u32 = 0,
    /// How many of those fell back.
    fallbacks: u32 = 0,
};

/// Whether the feature is on at all.
///
/// `ZODE_CHEAP_TURN=1` and the model is named, either by `ZODE_CHEAP_MODEL` or
/// by `ZODE_CHEAP_TURN` itself (`ZODE_CHEAP_TURN=model-id` is the one-flag form).
/// An empty or "0"/"off"/"false" means off.
pub fn enabledFrom(env: ?*const std.process.Environ.Map) bool {
    const m = env orelse return false;
    const raw = m.get(cheap_env) orelse return false;
    if (raw.len == 0) return false;
    if (isFalsey(raw)) return false;
    return m.get(cheap_model_env) != null or !isFalsey(raw);
}

/// `cheapModelFrom`: what `ZODE_CHEAP_TURN` itself names, when it is a model id
/// rather than a flag.
pub fn cheapModelFrom(env: ?*const std.process.Environ.Map) []const u8 {
    const m = env orelse return "";
    if (m.get(cheap_model_env)) |explicit| {
        if (explicit.len > 0) return explicit;
    }
    const raw = m.get(cheap_env) orelse return "";
    // "1", "true", "on", "yes" are the flag spellings, not model ids.
    if (raw.len == 0 or isFalsey(raw) or isTruthy(raw)) return "";
    return raw;
}

fn isFalsey(s: []const u8) bool {
    const yes = [_][]const u8{ "0", "off", "false", "no", "none" };
    for (yes) |y| if (std.ascii.eqlIgnoreCase(s, y)) return true;
    return false;
}

fn isTruthy(s: []const u8) bool {
    const yes = [_][]const u8{ "1", "on", "true", "yes" };
    for (yes) |y| if (std.ascii.eqlIgnoreCase(s, y)) return true;
    return false;
}

/// What the turn should do.
pub const Decision = enum {
    /// Send this turn to the cheap model.
    cheap,
    /// Send it to the model the user picked.
    active,
};

/// The ONLY constructor.
///
/// It exists so the invariant is enforced by construction rather than by
/// discipline: `cheap_model` is empty whenever the feature is off. Without it,
/// "the feature is off" and "there is a cheap model" can both be true, and then
/// `onFailure` gives up a model nobody is using — which is what the first
/// version of the "feature off" test did by hand, and it failed, correctly.
pub fn initFromEnv(env: ?*const std.process.Environ.Map) State {
    if (!enabledFrom(env)) return .{};
    const m = cheapModelFrom(env);
    if (m.len == 0) return .{};
    return .{ .cheap_model = m };
}

/// Whether the state has a cheap model at all.
pub fn active(st: *const State) bool {
    return st.cheap_model.len > 0 and !st.given_up;
}

/// The one decision, pure, with everything it needs passed in.
///
/// `active_model` is compared so a cheap model equal to the active one is not
/// "cheaper": it would double the state for nothing and, on a failure, fall back
/// to the model that had just failed.
pub fn decide(st: *State, active_model: []const u8, feature_on: bool) Decision {
    if (!feature_on) return .active;
    if (st.given_up) return .active;
    if (st.cheap_model.len == 0) return .active;
    if (active_model.len > 0 and std.mem.eql(u8, st.cheap_model, active_model)) return .active;
    st.attempts += 1;
    return .cheap;
}

/// Gives the cheap model up, and says whether the turn should be retried on the
/// active one.
///
/// Returns false when the error is the ACCOUNT's, not the model's. Retrying then
/// would be sending the same broken key to a second endpoint and reporting
/// whichever answer came back — which is how a wrong key becomes a 403 about a
/// model that works fine.
pub fn onFailure(st: *State, err: anyerror, detail: []const u8, active_model: []const u8) bool {
    if (st.cheap_model.len == 0) return false;
    if (!disqualifies(err, detail)) return false;
    st.given_up = true;
    st.fallbacks += 1;
    // Falling back onto the model that just failed is a loop, not a fallback.
    return !(active_model.len > 0 and std.mem.eql(u8, st.cheap_model, active_model));
}

/// Whether THIS error means the model is unusable, as opposed to the account.
///
/// `_detail` is the server's body and it is DELIBERATELY not read, which is the
/// whole difference from `agent.quotaVerdict` (that one reads it to tell
/// opencode's gate from "not on your account", because there the fallback is
/// another pair in the pool; here both mean the same thing).
///
/// It stays in the signature on purpose. A parameter named `_detail` makes the
/// compiler point at the next person who wonders whether they should read it,
/// which is the only moment that question is worth asking.
pub fn disqualifies(err: anyerror, _detail: []const u8) bool {
    _ = _detail;
    return switch (err) {
        error.Forbidden => true, // gated or not: either way this model will not answer
        error.ModelNotFound => true,
        error.AuthFailed => false, // the key. Never the model.
        error.NoCredits => false, // the account. The paid model fails the same way.
        error.RateLimited => false, // transient; the backoff is the answer
        error.Overloaded => false,
        error.ServerError => false,
        else => false,
    };
}

/// One line for the history, and only when something happened.
///
/// Silence on success would be wrong: a mode you cannot see is a mode where
/// "the model ignored my instruction" cannot be told apart from "the model was
/// never asked".
pub fn report(st: *const State, gpa: std.mem.Allocator, cheap_model: []const u8) ?[]u8 {
    if (st.fallbacks > 0) {
        return std.fmt.allocPrint(
            gpa,
            "cheap turn: {s} is not available on this account ({d}/{d} turns), so this one went to the model you picked. Set {s}=0 to stop trying.",
            .{ cheap_model, st.fallbacks, st.attempts, cheap_env },
        ) catch null;
    }
    if (st.attempts > 0) {
        return std.fmt.allocPrint(
            gpa,
            "cheap turn: {d}/{d} turns answered by {s}. Unset {s} to always use the model you picked.",
            .{ st.attempts, st.attempts, cheap_model, cheap_env },
        ) catch null;
    }
    return null;
}
// ── tests ────────────────────────────────────────────────────────

fn envWith(pairs: []const [2][]const u8) !std.process.Environ.Map {
    var m = std.process.Environ.Map.init(std.testing.allocator);
    errdefer m.deinit();
    for (pairs) |kv| try m.put(kv[0], kv[1]);
    return m;
}

test "the cheap model is given up when the MODEL is wrong, and kept when the ACCOUNT is" {
    // The whole table in one place, because this is the decision the feature is:
    // fall back or do not. Falling back on a 401 hides a broken key behind a
    // fallback that fails too, and reports the wrong cause.

    // The model is unusable: give it up.
    try std.testing.expect(disqualifies(error.Forbidden, ""));
    try std.testing.expect(disqualifies(error.Forbidden, "can only be used from within OpenCode"));
    try std.testing.expect(disqualifies(error.Forbidden, "Model access is disabled"));
    try std.testing.expect(disqualifies(error.Forbidden, "not available on this account"));
    try std.testing.expect(disqualifies(error.ModelNotFound, ""));

    // The account is wrong: keep the cheap model, because the fallback fails the
    // same way and only hides the real cause.
    try std.testing.expect(!disqualifies(error.AuthFailed, ""));
    try std.testing.expect(!disqualifies(error.NoCredits, ""));
    try std.testing.expect(!disqualifies(error.RateLimited, ""));
    try std.testing.expect(!disqualifies(error.Overloaded, ""));
    try std.testing.expect(!disqualifies(error.ServerError, ""));
    try std.testing.expect(!disqualifies(error.BadRequest, ""));
    try std.testing.expect(!disqualifies(error.Cancelled, ""));
}

test "a 403 disqualifies whether or not it carries the gate text" {
    // The reason this is different from `quotaVerdict`: that one distinguishes
    // the opencode gate (rotate) from "not on your account" (do not rotate),
    // because there the fallback is another pair in the pool. Here both mean the
    // same thing — THIS model will not answer you — so there is nothing to gain
    // from reading the text, and getting the read wrong costs a 403 per turn.
    try std.testing.expect(disqualifies(error.Forbidden, ""));
}

test "the fallback is not onto the model that just failed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    _ = arena_state.allocator();

    // A cheap model equal to the active one is not cheaper.
    var st: State = .{ .cheap_model = "same" };
    try std.testing.expectEqual(Decision.active, decide(&st, "same", true));
    try std.testing.expectEqual(@as(u32, 0), st.attempts);

    // And it is never retried onto itself after a failure.
    try std.testing.expect(!onFailure(&st, error.Forbidden, "", "same"));
    // But it IS given up, so it is not asked again.
    try std.testing.expect(st.given_up);
}

test "a model that said no is not asked again for the rest of the session" {
    var st: State = .{ .cheap_model = "small" };
    try std.testing.expectEqual(Decision.cheap, decide(&st, "big", true));
    try std.testing.expectEqual(@as(u32, 1), st.attempts);

    try std.testing.expect(onFailure(&st, error.Forbidden, "", "big"));

    // Every later turn goes to the active model and never touches the small one.
    try std.testing.expectEqual(Decision.active, decide(&st, "big", true));
    try std.testing.expectEqual(Decision.active, decide(&st, "big", true));
    try std.testing.expectEqual(@as(u32, 1), st.attempts);
}

test "an account error does NOT give the cheap model up" {
    var st: State = .{ .cheap_model = "small" };
    try std.testing.expect(!onFailure(&st, error.AuthFailed, "", "big"));
    try std.testing.expect(!st.given_up);
    // So the next turn tries it again: it might have been the paid model's quota.
    try std.testing.expectEqual(Decision.cheap, decide(&st, "big", true));
}

test "off is off, in every spelling, and no flag means off" {
    try std.testing.expect(!enabledFrom(null));
    var none = try envWith(&.{});
    defer none.deinit();
    try std.testing.expect(!enabledFrom(&none));
    try std.testing.expectEqualStrings("", cheapModelFrom(&none));

    for ([_][]const u8{ "0", "off", "false", "no", "OFF", "False", "" }) |v| {
        var m = try envWith(&.{.{ cheap_env, v }});
        defer m.deinit();
        try std.testing.expect(!enabledFrom(&m));
        try std.testing.expectEqualStrings("", cheapModelFrom(&m));
    }
}

test "ZODE_CHEAP_TURN takes the model id directly, and ZODE_CHEAP_MODEL overrides it" {
    // The one-flag form, because the two-variable version is two things to set
    // and people set one of them.
    var one = try envWith(&.{.{ cheap_env, "some-small-model" }});
    defer one.deinit();
    try std.testing.expect(enabledFrom(&one));
    try std.testing.expectEqualStrings("some-small-model", cheapModelFrom(&one));

    // With the model named separately the flag is just a switch.
    var two = try envWith(&.{ .{ cheap_env, "1" }, .{ cheap_model_env, "other-model" } });
    defer two.deinit();
    try std.testing.expect(enabledFrom(&two));
    try std.testing.expectEqualStrings("other-model", cheapModelFrom(&two));

    // A bare "1" with no model named is on but has nothing to try, so it is off
    // in effect: `decide` returns `.active` and nobody is ever asked.
    var bare = try envWith(&.{.{ cheap_env, "1" }});
    defer bare.deinit();
    try std.testing.expect(enabledFrom(&bare));
    try std.testing.expectEqualStrings("", cheapModelFrom(&bare));
    var st: State = .{};
    try std.testing.expectEqual(Decision.active, decide(&st, "big", enabledFrom(&bare)));
}

test "with the feature off there IS no cheap model, so nothing can fall back" {
    // Built with the constructor, which is the point: the first version of this
    // test wrote `State{ .cheap_model = "small" }` and turned the feature off,
    // which is a state that cannot exist, and asserted `onFailure` was a no-op.
    // It was not, and it was right not to be: with a cheap model in hand, a 403
    // gives it up whatever the flag says.
    var off = try envWith(&.{});
    defer off.deinit();
    var st = initFromEnv(&off);

    try std.testing.expectEqualStrings("", st.cheap_model);
    try std.testing.expect(!active(&st));
    try std.testing.expectEqual(Decision.active, decide(&st, "big", enabledFrom(&off)));
    try std.testing.expectEqual(@as(u32, 0), st.attempts);
    try std.testing.expect(!onFailure(&st, error.Forbidden, "", "big"));
    try std.testing.expect(!st.given_up);

    // And with it on there IS one.
    var on = try envWith(&.{.{ cheap_env, "small" }});
    defer on.deinit();
    var st2 = initFromEnv(&on);
    try std.testing.expectEqualStrings("small", st2.cheap_model);
    try std.testing.expect(active(&st2));
    try std.testing.expectEqual(Decision.cheap, decide(&st2, "big", enabledFrom(&on)));
    // After a 403 it is no longer active.
    _ = onFailure(&st2, error.Forbidden, "", "big");
    try std.testing.expect(!active(&st2));
}

test "it says what happened, because a mode you cannot see cannot be diagnosed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Nothing happened: no line at all.
    var quiet: State = .{};
    try std.testing.expect(report(&quiet, a, "small") == null);

    // It worked: one line, with the count and the way out.
    var worked: State = .{ .cheap_model = "small" };
    _ = decide(&worked, "big", true);
    _ = decide(&worked, "big", true);
    const ok = report(&worked, a, "small").?;
    try std.testing.expect(std.mem.indexOf(u8, ok, "2/2") != null);
    try std.testing.expect(std.mem.indexOf(u8, ok, "small") != null);
    try std.testing.expect(std.mem.indexOf(u8, ok, cheap_env) != null);

    // It gave up: the line says WHY and how to stop trying.
    var gave_up: State = .{ .cheap_model = "small" };
    _ = decide(&gave_up, "big", true);
    _ = decide(&gave_up, "big", true);
    _ = decide(&gave_up, "big", true);
    _ = onFailure(&gave_up, error.Forbidden, "", "big");
    const bad = report(&gave_up, a, "small").?;
    try std.testing.expect(std.mem.indexOf(u8, bad, "not available") != null);
    // And it must not claim the cheap model answered all three.
    try std.testing.expect(std.mem.indexOf(u8, bad, "3/3") == null);
    try std.testing.expect(std.mem.indexOf(u8, bad, "1/3") != null);
}
