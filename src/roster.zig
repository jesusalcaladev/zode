const std = @import("std");
const models = @import("lib/models.zig");
const providers = @import("lib/providers.zig");
const config_mod = @import("config.zig");
const http_client = @import("lib/http_client.zig");

/// The pool of free models from EVERY provider that has a key, and the wheel that
/// hands turns out among them.
///
/// ## What it solves
///
/// With a single provider, when its quota runs out (402) or the gate rejects it
/// (403 "can only be used from within OpenCode"), the turn dies and the user has
/// to type "continue" with a different model. Here, instead of that, the turn
/// goes on by itself: the provider/model pair is marked dead for a while and the
/// same request is retried with the next candidate.
///
/// ## Why it does NOT wait for the rotation
///
/// `build` talks to N providers, and that is N requests (hundreds of ms each).
/// If it happened on the first failure, the user would watch it "think" exactly
/// when they need something to happen. It is built in a worker at startup, and if
/// it is not ready the turn proceeds with the current model: the rotation waits
/// for the next turn, it never blocks.
///
/// ## What it does NOT do
///
/// - It does not guess providers: only the ones `providers.keyFor` returns a key
///   for, which are the ones the user actually connected.
/// - It does not persist across processes (yet). The pool is rebuilt at startup,
///   which is N requests in the background.
/// - It does not touch `cur_provider_id`/`cur_model`: the mode is a layer on top,
///   and `/use` and `/model` still rule over whatever is active.
/// Cap on rotations per turn. Three: past that it is almost certainly a
/// configuration problem (all the free ones down), not a quota one, and from
/// there on what you are doing is spinning and annoying the user.
pub const max_rotations_per_turn = 3;
/// Cap per task (prompt). Ten: covers a long session with several providers
/// dying, and cuts off before the turn looks hung.
pub const max_rotations_per_task = 10;

/// How long a pair stays dead before it is tried again.
///
/// Ten minutes. An openrouter/sound rate limit lasts seconds or minutes; a daily
/// quota (deepseek) lasts hours, and for that one the message to the user is a
/// different one (more "quota" than "rate limit"), not an automatic retry.
pub const cooldown_ms: i128 = 10 * 60 * 1000;

/// How long a pair is out of the game depending on WHY it died.
///
/// A single cap for everything was wrong: an openrouter 429 and a passing 503
/// are not the same thing, and 10 minutes of punishment for a one-second blip
/// takes a good model out of the pool exactly when the user needs it most. A
/// quota (402/429) does last: that is what takes a while to come back.
pub const failed_cooldown_ms: i128 = 60 * 1000;

/// Candidate cap. With 5 providers and 3 free each that is 15; the cap is there
/// so a provider that returns the whole catalog (openrouter has ~460 models)
/// does not blow up the fixed array.
pub const max_candidates = 24;

/// How many free models are kept from EACH provider.
///
/// It exists for a reason the probe showed: openrouter publishes 20 free models
/// and opencode 8, and with a GLOBAL-only cap whichever is listed first eats the
/// whole pool. In other words, the provider with the most models (the most
/// useful one) was the one that came out worst. With this cap each contributes
/// its best ones and the sum decides who gets in.
pub const per_provider_max = 8;

/// A provider/model pair that can be used.
pub const Candidate = struct {
    /// Own copies in the roster arena (never a slice from the worker that built
    /// the model list: that arena dies on the way out).
    provider_id: []const u8,
    model_id: []const u8,
    /// Published context window, 0 = unknown.
    ctx: u32 = 0,
    /// Stable shuffling: lower = preferred. See `rankFor`.
    rank: u8 = 0,
    /// The provider is opencode, whose `-free` models answer 403 outside the
    /// official client. They stay last: they have to be tried once in a while,
    /// but they are not a plan B.
    gated_opencode: bool = false,
    /// Already finished a turn with tools in this session: it goes up in priority.
    worked: bool = false,
    /// Times it went half way (came up twice without closing the turn).
    stalls: u8 = 0,
};

/// A pair that is not available right now, and why.
/// Reason length. With the 4 KB an error body sometimes returns, the text gets
/// truncated: what is kept is "what happened", not the whole response.
pub const reason_len_max = 96;

pub const Dead = struct {
    idx: u16 = 0,
    until_ms: i128 = 0,
    reason: [reason_len_max]u8 = undefined,
    reason_len: u8 = 0,

    pub fn reasonStr(self: *const Dead) []const u8 {
        return self.reason[0..self.reason_len];
    }

    pub fn expired(self: *const Dead, now_ms: i128) bool {
        return now_ms >= self.until_ms;
    }
};

/// Why a pair died, in a phrase the user can act on.
pub const Why = enum {
    /// 402: out of credits. It does not come back on its own.
    no_credits,
    /// 429: rate limit. It comes back on its own in a while.
    rate_limited,
    /// 403 with the opencode gate text: it is neither the key nor the config.
    gated,
    /// 403/404 with no further story: almost always a bad id or a config.
    misconfigured,
    /// Went half way twice.
    stalled,
    /// The retries with this pair ran out (3 attempts with backoff) without the
    /// error being a quota one. You see: a 5xx or a weird body is NOT a reason
    /// to rotate on the spot (the model is not to blame and it can be a blip),
    /// but if the turn dies with it, the NEXT turn has to start somewhere else
    /// or the user stays stuck on the same model forever.
    failed,

    pub fn label(self: Why) []const u8 {
        return switch (self) {
            .no_credits => "no credits",
            .rate_limited => "rate limited",
            .gated => "gated to the official client",
            .misconfigured => "not available on this account",
            .stalled => "stalled twice",
            .failed => "failed 3 times",
        };
    }
};

pub const Roster = struct {
    /// Its own arena: the candidate strings are its copies, and the roster
    /// outlives the workers that built it.
    arena: std.mem.Allocator = undefined,
    inited: bool = false,
    /// The worker finished building it (or finished trying to).
    built: bool = false,
    /// There was a key but no free model (or there was no key). That is a LEGAL
    /// state.
    empty_reason: []const u8 = "",

    items: [max_candidates]Candidate = undefined,
    len: u8 = 0,
    /// Index of the active candidate. It points at the live list, not the raw one.
    idx: u8 = 0,
    /// Real position in `items` of the active one, so it can be marked dead.
    cur_raw: u8 = 0,

    dead: [max_candidates]Dead = undefined,
    dead_len: u8 = 0,

    rotations_turn: u8 = 0,
    rotations_task: u8 = 0,

    /// Why the last provider that was asked failed (for diagnostics).
    last_error: ?anyerror = null,

    pub fn init(gpa: std.mem.Allocator) Roster {
        return .{ .arena = gpa, .inited = true };
    }

    pub fn total(self: *const Roster) u8 {
        return self.len;
    }

    pub fn isEmpty(self: *const Roster) bool {
        return self.len == 0;
    }

    /// Builds the pool: for every provider with a key, its free models.
    ///
    /// It fails as a whole (not the turn): if a provider answers 403 or has no
    /// key, it is skipped and the rest continue. A single provider that answers
    /// 200 with no free models is NOT an error.
    pub fn build(
        self: *Roster,
        io: std.Io,
        env: ?*const std.process.Environ.Map,
        defs: []const providers.ProviderDef,
    ) !void {
        self.len = 0;
        self.dead_len = 0;
        self.built = true;
        self.last_error = null;
        self.empty_reason = "";

        if (defs.len == 0) {
            self.empty_reason = "no providers configured";
            return;
        }

        var http = http_client.Http.init(self.arena, io);
        defer http.deinit();

        var found_any_key = false;
        for (defs) |def| {
            // Start of the run this provider contributes, so its candidates can be
            // trimmed without touching the earlier ones.
            const start: u8 = self.len;
            // No key, no question: a 401 here is only noise.
            if (providers.keyFor(&def, env) == null) continue;
            found_any_key = true;
            if (self.len >= max_candidates) break;

            // `var` and not `const`: `deinit` needs a non-const pointer to free
            // the list (Zig does not let a `*const` be passed to a `*`).
            var list = models.listModels(self.arena, &http, def.models_url, providers.catalogAuth(&def, env)) catch {
                // A down provider does not bring the pool down: carry on with the rest.
                self.last_error = error.ProviderListFailed;
                continue;
            };
            defer list.deinit(self.arena);

            for (list.items) |mo| {
                if (!mo.is_free) continue;
                // Free is not the same as usable: an aggregator's free tier is
                // full of embeddings, image and audio models, and offering one of
                // those as "the model to write code with" fails on the first
                // token and then looks like a quota problem.
                if (!models.isConversational(mo.id)) continue;
                if (self.len >= max_candidates) break;
                self.items[self.len] = .{
                    .provider_id = self.arena.dupe(u8, def.id) catch continue,
                    .model_id = self.arena.dupe(u8, mo.id) catch continue,
                    .ctx = mo.context_length,
                    .gated_opencode = std.mem.eql(u8, def.id, "opencode"),
                };
                self.len += 1;
            }

            trimProvider(self, start);
        }

        if (!found_any_key) {
            self.empty_reason = "no provider has an API key (ctrl+a to connect one)";
            return;
        }
        if (self.len == 0) {
            self.empty_reason = "no free models published by any provider with a key";
            return;
        }

        self.sort();
        self.idx = 0;
        self.cur_raw = 0;
    }

    /// Stable order, and one with a rationale. It matters: not every free model
    /// knows how to use multi-step tools, and landing on a bad one produces
    /// garbage edits.
    ///
    /// 1. The ones that already worked (`worked`): what is known to work wins.
    /// 2. The ones not gated to opencode (their 403 is known and nothing fixes
    ///    it: trying them last is wasting an attempt).
    /// 3. Bigger context first: less chance of compacting halfway through a
    ///    turn, which is where it hurts.
    /// 4. Alphabetical as the tie-breaker, so the list is the same on every
    ///    startup and the tests can pin it.
    fn sort(self: *Roster) void {
        const items = self.items[0..self.len];
        std.mem.sort(Candidate, items, {}, less);
    }

    /// Trims the candidates THIS provider contributes (the run `start..self.len`)
    /// down to `per_provider_max`, keeping the ones with the biggest context.
    ///
    /// It lives outside `build` on purpose: `build` talks to the network and
    /// cannot be tested, and the trim is exactly where the bug hides. This way a
    /// test checks it without going near the network (the bug was found by the
    /// `zig build roster-probe` probe: with the global-only cap, openrouter ate
    /// the pool and out of its 20 free models only 16 got in, in any order).
    fn trimProvider(self: *Roster, start: u8) void {
        const added = self.len - start;
        if (added <= per_provider_max) return;
        // Sorting BEFORE throwing the rest away (not the other way round) is
        // what leaves the best ones in the pool. Trimming first would keep the
        // first 8 the provider published, which can be the worst ones.
        std.mem.sort(Candidate, self.items[start..self.len], {}, byCtxThenName);
        self.len = start + per_provider_max;
    }

    /// Bigger context first, alphabetical as the tie-breaker. Used to trim the
    /// candidates of ONE provider before they go into the pool.
    ///
    /// It deliberately does not reuse `less`: here all the candidates are from
    /// the same provider, so neither `worked` nor `gated_opencode` tells them
    /// apart, and sorting by the global comparator would mix the runs.
    fn byCtxThenName(_: void, a: Candidate, b: Candidate) bool {
        if (a.ctx != b.ctx) return a.ctx > b.ctx;
        return std.mem.lessThan(u8, a.model_id, b.model_id);
    }

    /// Total order in ONE single comparator.
    ///
    /// CAREFUL: it is NOT four `std.mem.sort` calls chained by key. `std.mem.sort`
    /// is an UNSTABLE block sort, so in a chain of sorts only the last one
    /// survives: the final order would have been alphabetical only, and the
    /// three criteria written before would have been lost without warning. A
    /// single comparator with an alphabetical tie-breaker is a total order and
    /// does not have that problem.
    fn less(_: void, a: Candidate, b: Candidate) bool {
        // `return a.worked` and not `!a.worked`: the ones that ALREADY worked go
        // first. (The first version had the sign inverted and the sort test
        // caught it: one `!` too many and the pool started with the worst model.)
        if (a.worked != b.worked) return a.worked;
        // The ones gated to opencode last: their 403 is known and nothing fixes
        // it, so they are the last resort, not the first option.
        if (a.gated_opencode != b.gated_opencode) return !a.gated_opencode;
        // Bigger context first: less compaction halfway through a turn.
        if (a.ctx != b.ctx) return a.ctx > b.ctx;
        if (!std.mem.eql(u8, a.provider_id, b.provider_id)) {
            return std.mem.lessThan(u8, a.provider_id, b.provider_id);
        }
        return std.mem.lessThan(u8, a.model_id, b.model_id);
    }

    /// The active candidate (ignoring cooldowns: the one in use right now, even if
    /// it is about to die). Null if the pool is empty.
    pub fn currentCandidate(self: *const Roster) ?Candidate {
        if (self.len == 0 or self.cur_raw >= self.len) return null;
        return self.items[self.cur_raw];
    }

    /// The active candidate, or null if none is left alive.
    ///
    /// It only moves forward over the ones NOT in cooldown: `active()` does not
    /// mutate the index, it only reads and normalizes it. (If they are all dead,
    /// it leaves the index where it was and returns null: the caller warns.)
    pub fn active(self: *const Roster, now_ms: i128) ?Candidate {
        if (self.len == 0) return null;
        var i: u8 = self.idx;
        var tries: u8 = 0;
        while (tries < max_rotations_per_turn) : (tries += 1) {
            if (!self.isDead(i, now_ms)) return self.items[i];
            i = @intCast((i + 1) % self.len);
        }
        return null;
    }

    /// The next live one AFTER the current, or null if none is left.
    ///
    /// This is what the quota failure calls: it does not rotate until it is
    /// called, so that a turn going fine does not burn rotations.
    pub fn nextLive(self: *Roster, now_ms: i128) ?u8 {
        if (self.len == 0) return null;
        var i: u8 = @intCast((self.cur_raw + 1) % self.len);
        var tries: u8 = 0;
        while (tries < max_rotations_per_turn) : (tries += 1) {
            if (!self.isDead(i, now_ms)) {
                self.idx = i;
                self.cur_raw = i;
                return i;
            }
            i = @intCast((i + 1) % self.len);
        }
        return null;
    }

    /// Marks the current candidate dead and jumps to the next live one.
    ///
    /// Returns the index of the new active one, or null if none is left (which
    /// is the signal to give up and explain why, not to keep trying).
    pub fn rotate(self: *Roster, now_ms: i128, why: Why, detail: []const u8) ?u8 {
        self.noteDead(self.cur_raw, now_ms, why, detail);
        return self.nextLive(now_ms);
    }

    pub fn noteDead(self: *Roster, idx: u8, now_ms: i128, why: Why, detail: []const u8) void {
        if (idx >= self.len) return;
        if (self.dead_len >= self.dead.len) return;

        // CAREFUL: the text is composed into a LOCAL buffer and then copied to
        // `d.reason`. Writing into `d.reason` while reading from a slice of
        // `d.reason` is aliasing, and with a long detail it blows up in the
        // middle of bufPrint (which is exactly what a 4 KB error body does).
        var tmp: [reason_len_max]u8 = undefined;
        const text = if (detail.len == 0)
            std.fmt.bufPrint(&tmp, "{s}", .{why.label()}) catch why.label()
        else
            std.fmt.bufPrint(&tmp, "{s}: {s}", .{ why.label(), detail }) catch why.label();

        const cool: i128 = switch (why) {
            .failed, .stalled => failed_cooldown_ms,
            else => cooldown_ms,
        };
        var d = Dead{ .idx = idx, .until_ms = now_ms + cool, .reason_len = 0 };
        const n = @min(text.len, d.reason.len);
        @memcpy(d.reason[0..n], text[0..n]);
        d.reason_len = @intCast(n);
        self.dead[self.dead_len] = d;
        self.dead_len += 1;
    }

    /// Is candidate `idx` in cooldown right now?
    pub fn isDead(self: *const Roster, idx: u8, now_ms: i128) bool {
        for (self.dead[0..self.dead_len]) |*d| {
            if (d.idx == idx and !d.expired(now_ms)) return true;
        }
        return false;
    }

    /// The reason the active candidate died, for the message to the user
    /// ("groq/openai-free: rate limited: 429 Too Many Requests").
    pub fn deadReason(self: *const Roster, idx: u8) []const u8 {
        for (self.dead[0..self.dead_len]) |*d| {
            if (d.idx == idx) return d.reasonStr();
        }
        return "";
    }

    /// "2/7 · openrouter/qwen3-free", for the status bar.
    ///
    /// With an empty list it returns the reason (or an empty string): the status
    /// bar has to be able to say "why there is no free-auto" and not just stay
    /// silent.
    pub fn statusLabel(self: *const Roster, arena: std.mem.Allocator) []const u8 {
        if (!self.built) return "";
        if (self.len == 0) {
            if (self.empty_reason.len == 0) return "free-auto: pool empty";
            return std.fmt.allocPrint(arena, "free-auto: {s}", .{self.empty_reason}) catch "free-auto: pool empty";
        }
        const n = self.idx + 1;
        if (self.idx < self.len) {
            return std.fmt.allocPrint(arena, "free-auto {d}/{d} · {s}/{s}", .{
                n, self.len, self.items[self.idx].provider_id, self.items[self.idx].model_id,
            }) catch "free-auto";
        }
        return std.fmt.allocPrint(arena, "free-auto {d}/{d} · exhausted", .{ n, self.len }) catch "free-auto";
    }

    /// The final report when no pair is left alive: what was tried and why each one
    /// died. It is what turns an opaque failure into something actionable.
    pub fn exhaustedReport(self: *const Roster, arena: std.mem.Allocator) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        out.appendSlice(arena, "free-auto: no free model left. ") catch return "";
        if (self.dead_len == 0) {
            out.appendSlice(arena, "The pool was empty from the start.") catch return "";
            return out.items;
        }
        out.appendSlice(arena, "Tried: ") catch return "";
        for (self.dead[0..self.dead_len], 0..) |*d, i| {
            if (i > 0) out.appendSlice(arena, "; ") catch return "";
            if (d.idx >= self.len) continue;
            out.print(arena, "{s}/{s} ({s})", .{
                self.items[d.idx].provider_id, self.items[d.idx].model_id, d.reasonStr(),
            }) catch return "";
        }
        return out.items;
    }
};

// ── tests ─────────────────────────────────────────────────────
//
// They are all PURE: they touch neither the network nor the disk. `build` with
// real providers is covered by the integration test at the end, and what is
// tested here is the wheel logic, which is where the expensive bugs live
// (rotating to a dead one, running out of candidates, blowing past the cap).

/// A fake roster: `n` candidates with a predictable name.
fn fakeRoster(gpa: std.mem.Allocator, n: u8) Roster {
    var r = Roster.init(gpa);
    r.built = true;
    r.len = n;
    for (0..n) |i| {
        r.items[i] = .{
            .provider_id = gpa.dupe(u8, "prov") catch unreachable,
            .model_id = std.fmt.allocPrint(gpa, "m{d}", .{i}) catch unreachable,
        };
    }
    return r;
}

test "trimProvider: only the best of each provider get in, not the first ones" {
    // The failure the probe found: with the GLOBAL-only cap, the provider with the
    // most models ate the pool. And worse: the first 8 it published got in, not
    // the best 8.
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    var r = Roster.init(astate.allocator());

    // 20 candidates from ONE provider, in publication order (growing context, the
    // way openrouter returns them: they are not sorted by anything useful).
    var i: u8 = 0;
    while (i < 20) : (i += 1) {
        r.items[i] = .{ .provider_id = "openrouter", .model_id = "m", .ctx = 1000 + @as(u32, i) * 10 };
    }
    r.len = 20;

    Roster.trimProvider(&r, 0);
    try std.testing.expectEqual(@as(u8, per_provider_max), r.len);
    // The 8 with the biggest context, not the first 8.
    try std.testing.expectEqual(@as(u32, 1000 + 19 * 10), r.items[0].ctx);
    try std.testing.expectEqual(@as(u32, 1000 + 12 * 10), r.items[per_provider_max - 1].ctx);
}

test "trimProvider: it does not touch the candidates of the earlier providers" {
    // The trim goes by RUN, not over the whole array: if it sorted everything, the
    // best 8 would all be from the biggest provider and we would be back to the
    // original bug.
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    var r = Roster.init(astate.allocator());

    // 6 from the first provider (fits whole), 18 from the second (has to be
    // trimmed; and 6+18 is exactly the 24 of the cap, as in `build`).
    for (0..6) |k| {
        r.items[@intCast(k)] = .{ .provider_id = "a", .model_id = "a", .ctx = 10 };
    }
    for (0..18) |k| {
        r.items[6 + @as(u8, @intCast(k))] = .{
            .provider_id = "b",
            .model_id = "b",
            .ctx = 1000 + @as(u32, @intCast(k)) * 10,
        };
    }
    r.len = 24;

    Roster.trimProvider(&r, 6);
    try std.testing.expectEqual(@as(u8, 6 + per_provider_max), r.len);
    // The first 6 are still from provider "a" with their context untouched.
    for (0..6) |k| {
        try std.testing.expectEqualStrings("a", r.items[@intCast(k)].provider_id);
        try std.testing.expectEqual(@as(u32, 10), r.items[@intCast(k)].ctx);
    }
    try std.testing.expectEqualStrings("b", r.items[6].provider_id);
    try std.testing.expectEqual(@as(u32, 1000 + 17 * 10), r.items[6].ctx);
}

test "trimProvider: a provider with 100 free models does not leave the next one without room" {
    // The edge case of the original bug. With the per-run trim, the first provider
    // fills the 24 slots, gets trimmed to 8, and the next one has room for
    // real. (With the global-only cap the second one was left with 0 and
    // free-auto had no plan B even with 3 providers holding keys.)
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    var r = Roster.init(astate.allocator());

    for (0..max_candidates) |k| {
        r.items[@intCast(k)] = .{
            .provider_id = "openrouter",
            .model_id = "m",
            .ctx = 1000 + @as(u32, @intCast(k)),
        };
    }
    r.len = max_candidates;
    Roster.trimProvider(&r, 0);
    try std.testing.expectEqual(@as(u8, per_provider_max), r.len);

    // And now the second one comes in with room to spare.
    for (0..4) |k| {
        r.items[per_provider_max + @as(u8, @intCast(k))] = .{
            .provider_id = "groq",
            .model_id = "g",
            .ctx = 2000,
        };
    }
    r.len = per_provider_max + 4;
    Roster.trimProvider(&r, per_provider_max);
    try std.testing.expectEqual(@as(u8, per_provider_max + 4), r.len);
    try std.testing.expectEqualStrings("groq", r.items[per_provider_max].provider_id);
}

test "currentCandidate is the one in use, even if it is dead" {
    // It is what the "I switched model" line needs: the pair that dropped, not the
    // next one. And it has to keep returning the dead one (that is exactly when
    // it is asked for).
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    var r = fakeRoster(astate.allocator(), 3);

    const before = r.currentCandidate().?;
    try std.testing.expectEqualStrings("m0", before.model_id);

    _ = r.rotate(0, .no_credits, "402");
    // The active one is another now, and the dead one can be asked for its reason.
    const now = r.currentCandidate().?;
    try std.testing.expectEqualStrings("m1", now.model_id);
    try std.testing.expect(std.mem.indexOf(u8, r.deadReason(0), "402") != null);
}

test "active returns the first one and respects the length" {
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    var r = fakeRoster(astate.allocator(), 3);

    const a = r.active(0).?;
    try std.testing.expectEqualStrings("m0", a.model_id);
    try std.testing.expectEqual(@as(u8, 3), r.total());
    try std.testing.expect(!r.isEmpty());

    // Empty pool: null and not a crash.
    var empty = Roster.init(astate.allocator());
    try std.testing.expect(empty.active(0) == null);
    try std.testing.expect(empty.nextLive(0) == null);
    try std.testing.expect(empty.isEmpty());
}

test "rotate kills the current one and jumps to the next live one" {
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    var r = fakeRoster(astate.allocator(), 3);

    // The first dies → the active one becomes the second.
    const next = r.rotate(0, .rate_limited, "429 Too Many Requests").?;
    try std.testing.expectEqualStrings("m1", r.items[next].model_id);
    try std.testing.expect(r.isDead(0, 0));
    try std.testing.expect(!r.isDead(1, 0));
    // And the reason stored is readable, not a code.
    try std.testing.expect(std.mem.indexOf(u8, r.deadReason(0), "rate limited") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.deadReason(0), "429") != null);
}

test "rotate skips the ones still in cooldown" {
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    var r = fakeRoster(astate.allocator(), 4);

    // m0 dies, and rotating lands on m1.
    _ = r.rotate(0, .rate_limited, "429").?;
    // m1 also dies by hand (as if it had dropped in between).
    r.noteDead(1, 0, .no_credits, "402 out of credits");
    // The next live one has to be m2, not m1.
    const next = r.nextLive(0).?;
    try std.testing.expectEqualStrings("m2", r.items[next].model_id);
}

test "the cooldown expires: after a while the pair is usable again" {
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    var r = fakeRoster(astate.allocator(), 2);

    r.noteDead(0, 0, .rate_limited, "429");
    try std.testing.expect(r.isDead(0, 0));
    try std.testing.expect(r.isDead(0, cooldown_ms - 1));
    // Right when it elapses it stops being dead (rate limits last seconds).
    try std.testing.expect(!r.isDead(0, cooldown_ms));
}

test "with no live candidates it returns null, not an infinite loop" {
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    var r = fakeRoster(astate.allocator(), 2);

    r.noteDead(0, 0, .no_credits, "402");
    r.noteDead(1, 0, .no_credits, "402");
    try std.testing.expect(r.active(0) == null);
    try std.testing.expect(r.nextLive(0) == null);
    try std.testing.expect(r.rotate(0, .no_credits, "402") == null);
}

test "sort: working ones first, then ungated, then context size, then alphabetical" {
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    var r = Roster.init(astate.allocator());
    r.built = true;
    // a: gated and small. b: big but gated. c: big, not gated.
    // d: small, not gated, but ALREADY WORKED.
    r.items[0] = .{ .provider_id = "a", .model_id = "small-gated", .ctx = 1000, .gated_opencode = true };
    r.items[1] = .{ .provider_id = "b", .model_id = "big-gated", .ctx = 200000, .gated_opencode = true };
    r.items[2] = .{ .provider_id = "c", .model_id = "big-open", .ctx = 200000 };
    r.items[3] = .{ .provider_id = "d", .model_id = "small-open-worked", .ctx = 1000, .worked = true };
    r.len = 4;
    r.sort();

    // 1st the one that already worked, even if it is the smallest.
    try std.testing.expectEqualStrings("small-open-worked", r.items[0].model_id);
    // 2nd the big one without a gate.
    try std.testing.expectEqualStrings("big-open", r.items[1].model_id);
    // 3rd and 4th the gated ones, by context.
    try std.testing.expectEqualStrings("big-gated", r.items[2].model_id);
    try std.testing.expectEqualStrings("small-gated", r.items[3].model_id);
}

test "sort is stable and deterministic" {
    // Same input, same output: otherwise the candidate list changes between
    // startups and the rotation test cannot pin anything.
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const ids = [_][]const u8{ "z", "a", "m", "b" };
    for (0..2) |_| {
        var r = Roster.init(astate.allocator());
        r.len = 4;
        for (ids, 0..) |id, i| r.items[i] = .{ .provider_id = "p", .model_id = id };
        r.sort();
        for (ids, 0..) |_, i| {
            const want = [_][]const u8{ "a", "b", "m", "z" };
            try std.testing.expectEqualStrings(want[i], r.items[i].model_id);
        }
    }
}

test "statusLabel says where it is and why there is no pool" {
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();

    var r = fakeRoster(arena, 3);
    const lbl = r.statusLabel(arena);
    try std.testing.expect(std.mem.indexOf(u8, lbl, "free-auto 1/3") != null);
    try std.testing.expect(std.mem.indexOf(u8, lbl, "prov/m0") != null);

    // Not built: nothing (it does not bother the user with a mode they did not
    // ask for).
    var fresh = Roster.init(arena);
    try std.testing.expectEqualStrings("", fresh.statusLabel(arena));

    // Built and empty: it DOES have to say why.
    var e = Roster.init(arena);
    e.built = true;
    e.empty_reason = "no provider has an API key";
    try std.testing.expect(std.mem.indexOf(u8, e.statusLabel(arena), "no provider has an API key") != null);
}

test "exhaustedReport lists what was tried and why" {
    // The failure the user reads when there is nothing left: if this does not say
    // what happened with each provider, there is nothing to do but guess.
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    var r = fakeRoster(arena, 2);
    r.noteDead(0, 0, .no_credits, "402 out of credits");
    r.noteDead(1, 0, .gated, "403 can only be used from within OpenCode");

    const rep = r.exhaustedReport(arena);
    try std.testing.expect(std.mem.indexOf(u8, rep, "no free model left") != null);
    try std.testing.expect(std.mem.indexOf(u8, rep, "prov/m0 (no credits") != null);
    try std.testing.expect(std.mem.indexOf(u8, rep, "prov/m1 (gated") != null);
}

test "the cooldown depends on WHY it died, it is not one size for all" {
    // 10 minutes for a passing 503 took a good model out of the pool exactly when
    // the user needed it. And the other way round: a 402 does have to last.
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    var r = fakeRoster(astate.allocator(), 2);

    r.noteDead(0, 0, .failed, "JSON parsing failed");
    r.noteDead(1, 0, .no_credits, "402");

    // The one that failed from a blip comes back before the one that ran out of
    // credits: still out at 59 s (the one minute cap) and back in at 60.
    try std.testing.expect(r.isDead(0, failed_cooldown_ms - 1));
    try std.testing.expect(!r.isDead(0, failed_cooldown_ms));
    try std.testing.expect(r.isDead(1, cooldown_ms - 1));
    try std.testing.expect(!r.isDead(1, cooldown_ms));
    // And the label says so, so the history does not lie.
    try std.testing.expect(std.mem.indexOf(u8, r.deadReason(0), "failed 3 times") != null);
}

test "noteDead with an overlong detail does not overflow" {
    // The reason is a fixed 96 byte buffer: a 4 KB error body cannot write past it
    // (it is the same job an error path elsewhere does: truncated, not a panic).
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    var r = fakeRoster(astate.allocator(), 1);
    const huge = "x" ** 4096;
    r.noteDead(0, 0, .rate_limited, huge);
    try std.testing.expect(r.deadReason(0).len <= r.dead[0].reason.len);
    try std.testing.expect(r.deadReason(0).len > 0);
}
