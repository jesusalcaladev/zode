//! What the session has cost, in dollars, per model.
//!
//! ## Why this is not `/usage` with a price multiplied in
//!
//! `/usage` counts the WHOLE session in one bucket. The money is per model, and a
//! session talks to several: `free-auto` rotates when a pool model runs out of
//! quota, the cheap router falls back to the user's model, and `/submodel` sends
//! subagents somewhere else on purpose. One total multiplied by one price would be
//! a number about a model that did not answer.
//!
//! ## The rule that makes the number trustworthy: `null` is not zero
//!
//! A price the provider did not publish is `null`, and every consumer has to say
//! **price unknown**. Printing `$0.00` there is a bill that reads as free, and that
//! is the one thing a cost display must never do. It is the same reason
//! `models.jsonNumber` refuses to return NaN: a number that cannot be computed
//! must not become a number that looks computed.
//!
//! ## What this module does NOT do
//!
//! It does not read the catalogue: `src/lib/` cannot reach `modelcache.zig`'s IO,
//! and the price belongs to the caller that knows which providers are connected.
//! Here there is only the arithmetic and the words, so both can be tested with no
//! TUI, no network and no file.

const std = @import("std");
const models = @import("models.zig");

/// One published price. Both fields are USD per TOKEN, which is the unit the
/// providers publish (OpenRouter's `"0.00000015"` is $0.15 per million).
pub const Price = struct {
    prompt: f64,
    completion: f64,
};

/// Distinct models the tracker keeps apart. Above this they are added to one
/// `other models` row instead of being dropped: a token count that vanishes is a
/// bill that is wrong, and a row that says "other" is a bill that is honest.
pub const max_models: usize = 16;

pub const Entry = struct {
    model_buf: [96]u8 = undefined,
    model_len: usize = 0,
    prompt_tokens: i64 = 0,
    completion_tokens: i64 = 0,

    pub fn text(self: *const Entry) []const u8 {
        return self.model_buf[0..self.model_len];
    }
};

/// Per-model tokens for the process's session.
///
/// A module global like `cache_stats.session`, and for the same reason: the turn
/// ends inside `chatWorker`, and that function has the `Usage` and the model that
/// answered but no consumer to hand them to.
pub const Tracker = struct {
    entries: [max_models]Entry = @splat(.{}),
    len: usize = 0,
    /// Tokens of the models that did not fit in `entries`. `spill_requests` is a
    /// count of RECORDS, not of models: counting distinct ids needs the memory the
    /// cap just refused, and the line only has to say that something is not broken
    /// out.
    spill_prompt: i64 = 0,
    spill_completion: i64 = 0,
    spill_requests: usize = 0,

    pub fn reset(self: *Tracker) void {
        self.len = 0;
        self.spill_prompt = 0;
        self.spill_completion = 0;
        self.spill_requests = 0;
    }

    /// Adds one request's tokens to its model's row.
    ///
    /// A request with no tokens is not recorded: a cancelled stream that produced
    /// nothing did not cost anything, and a row of zeros would be a model that
    /// looks like it answered.
    pub fn record(self: *Tracker, model: []const u8, prompt: i64, completion: i64) void {
        const p = @max(prompt, 0);
        const c = @max(completion, 0);
        if (p == 0 and c == 0) return;

        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            if (std.mem.eql(u8, self.entries[i].text(), model)) {
                self.entries[i].prompt_tokens += p;
                self.entries[i].completion_tokens += c;
                return;
            }
        }

        if (self.len < max_models and model.len > 0) {
            const e = &self.entries[self.len];
            e.* = .{};
            const n = @min(model.len, e.model_buf.len);
            @memcpy(e.model_buf[0..n], model[0..n]);
            e.model_len = n;
            e.prompt_tokens = p;
            e.completion_tokens = c;
            self.len += 1;
            return;
        }

        self.spill_prompt += p;
        self.spill_completion += c;
        self.spill_requests += 1;
    }
};

/// The session's tracker.
pub var session: Tracker = .{};

/// One line of the report: a model, its tokens, and what the catalogue charges
/// for it.
pub const Row = struct {
    model: []const u8,
    prompt: i64 = 0,
    completion: i64 = 0,
    /// `null` is "the provider published no price", NOT "free". The difference is
    /// the whole point of this module.
    price: ?Price = null,
};

/// The price of one model inside a PARSED catalogue, or null when nobody
/// published one.
///
/// The three answers are different and only one of them is a zero:
///
/// - a model the provider marks free is `{0, 0}` — it really is free;
/// - a model with a price is that price;
/// - a model with neither (a provider that publishes no `pricing` object at all,
///   which `models.zig` stores as 0/0) is `null`, and the report says
///   `price unknown`. Rendering it as `$0.00` is the lie the module exists to
///   prevent, and it is what a naive `0 * tokens` does.
pub const Lookup = union(enum) {
    /// The model is in this catalogue and this is its price.
    found: ?Price,
    /// The model is in no catalogue here (a custom id, or one that was never
    /// downloaded). Not the same answer as `found: null`, and the caller needs
    /// both: a model that is missing here may be priced by the next provider.
    missing,
};

pub fn priceOf(list: []const models.Model, model_id: []const u8) Lookup {
    for (list) |m| {
        if (!std.mem.eql(u8, m.id, model_id)) continue;
        if (m.is_free) return .{ .found = .{ .prompt = 0, .completion = 0 } };
        if (m.price_prompt <= 0 and m.price_completion <= 0) return .{ .found = null };
        return .{ .found = .{ .prompt = m.price_prompt, .completion = m.price_completion } };
    }
    return .missing;
}

/// Dollars for one row, or null when the price is unknown.
pub fn costOf(row: Row) ?f64 {
    const p = row.price orelse return null;
    return @as(f64, @floatFromInt(@max(row.prompt, 0))) * p.prompt +
        @as(f64, @floatFromInt(@max(row.completion, 0))) * p.completion;
}

/// Sum of the rows that HAVE a price. Read `unpricedCount` before presenting it as
/// the bill: it is a floor, not a total, whenever anything is missing.
pub fn totalOf(rows: []const Row) f64 {
    var total: f64 = 0;
    for (rows) |r| {
        if (costOf(r)) |v| total += v;
    }
    return total;
}

pub fn unpricedCount(rows: []const Row) usize {
    var n: usize = 0;
    for (rows) |r| {
        if (r.price == null) n += 1;
    }
    return n;
}

/// Money, at the precision the amount deserves.
///
/// A value that is not a finite number is `n/a` and never `$0.00`: a NaN rendered
/// as zero is a bill that reads as free.
pub fn formatUsd(buf: []u8, value: f64) []const u8 {
    if (!std.math.isFinite(value)) return "n/a";
    if (value <= 0) return std.fmt.bufPrint(buf, "$0.00", .{}) catch "$0.00";
    if (value >= 1) return std.fmt.bufPrint(buf, "${d:.2}", .{value}) catch "n/a";
    if (value >= 0.01) return std.fmt.bufPrint(buf, "${d:.4}", .{value}) catch "n/a";
    if (value >= 0.0001) return std.fmt.bufPrint(buf, "${d:.6}", .{value}) catch "n/a";
    return "<$0.0001";
}

/// Thousands separators, from the right. The same shape as `/usage`'s numbers, so
/// the two commands cannot disagree about how a token count is written.
pub fn groupDigits(buf: []u8, value: i64) []const u8 {
    const n: u64 = @intCast(@max(value, 0));
    var len: usize = 1;
    var divisor: u64 = 1;
    while (divisor <= n / 10) : (divisor *= 10) {
        len += 1;
    }
    var out: usize = 0;
    for (0..len) |i| {
        if (out >= buf.len) return buf[0..out];
        buf[out] = '0' + @as(u8, @intCast((n / divisor) % 10));
        out += 1;
        if (i + 1 < len and (len - i - 1) % 3 == 0) {
            if (out >= buf.len) return buf[0..out];
            buf[out] = ',';
            out += 1;
        }
        divisor /= 10;
    }
    return buf[0..out];
}

/// A model id cut to `width` bytes at a UTF-8 boundary, with an ellipsis.
/// The ids are ASCII today; a user's `config.json` is not required to agree, and
/// half a codepoint on the wire is a rendering bug with no cause in sight.
fn fitName(buf: []u8, model: []const u8, width: usize) []const u8 {
    if (model.len <= width) return model;
    if (buf.len < 3) return model[0..@min(model.len, buf.len)];
    var cut = @min(width - 3, buf.len - 3);
    while (cut > 0 and (model[cut] & 0xC0) == 0x80) cut -= 1;
    @memcpy(buf[0..cut], model[0..cut]);
    @memcpy(buf[cut .. cut + 3], "\u{2026}");
    return buf[0 .. cut + 3];
}

fn appendFmt(out: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const line = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(line);
    try out.appendSlice(gpa, line);
}

/// The text `/cost` prints. Owned by the caller's allocator.
///
/// `requests` and `session_prompt` come from `cache_stats.session` and exist for
/// the two honesty checks a per-model table cannot do by itself: how many requests
/// are behind it, and how many tokens the session counted that this breakdown did
/// NOT see (a resumed session restores the totals from disk and has no per-model
/// rows to restore).
pub fn report(
    gpa: std.mem.Allocator,
    rows: []const Row,
    requests: usize,
    session_prompt: i64,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    const unpriced = unpricedCount(rows);
    var money_buf: [32]u8 = undefined;

    if (rows.len == 0) {
        // A resumed session restores the token totals from disk and has no
        // per-model rows to restore: "no total" would be true, and "no published
        // price" would be a lie about why.
        try appendFmt(&out, gpa, "cost \u{b7} {d} {s} \u{b7} no per-model breakdown in this process\n", .{
            requests,
            plural(requests, "request", "requests"),
        });
    } else if (unpriced == rows.len) {
        // No row can be priced: saying "$0.00" here is the lie this module exists
        // to avoid, and saying nothing at all looks like the command is broken.
        try appendFmt(&out, gpa, "cost \u{b7} {d} {s} \u{b7} no published price for the models used, so there is no total\n", .{
            requests,
            plural(requests, "request", "requests"),
        });
    } else {
        try appendFmt(&out, gpa, "cost \u{b7} {d} {s} \u{b7} {s} counted\n", .{
            requests,
            plural(requests, "request", "requests"),
            formatUsd(&money_buf, totalOf(rows)),
        });
    }

    var name_buf: [64]u8 = undefined;
    var in_buf: [32]u8 = undefined;
    var out_buf: [32]u8 = undefined;
    for (rows) |r| {
        const name = fitName(&name_buf, r.model, 36);
        const money = if (costOf(r)) |v| formatUsd(&money_buf, v) else "price unknown";
        try appendFmt(&out, gpa, "  {s: <36} {s: >10} in \u{b7} {s: >10} out   {s}\n", .{
            name,
            groupDigits(&in_buf, r.prompt),
            groupDigits(&out_buf, r.completion),
            money,
        });
    }

    if (unpriced > 0 and unpriced < rows.len) {
        try appendFmt(&out, gpa, "  total counted {s} \u{b7} {d} {s} with no published price, so the real bill is higher\n", .{
            formatUsd(&money_buf, totalOf(rows)),
            unpriced,
            plural(unpriced, "model", "models"),
        });
    }

    var seen_prompt: i64 = 0;
    for (rows) |r| seen_prompt += @max(r.prompt, 0);
    if (session_prompt > seen_prompt) {
        var missing_buf: [32]u8 = undefined;
        try appendFmt(&out, gpa, "  {s} prompt tokens of this session were counted before this process (resumed); they are not in this breakdown\n", .{
            groupDigits(&missing_buf, session_prompt - seen_prompt),
        });
    }

    return out.toOwnedSlice(gpa);
}

fn plural(n: usize, one: []const u8, many: []const u8) []const u8 {
    return if (n == 1) one else many;
}

// ── tests ─────────────────────────────────────────────────────

test "cost: the same model accumulates into one row, different models do not" {
    var t = Tracker{};
    t.record("model-a", 1000, 100);
    t.record("model-a", 2000, 200);
    t.record("model-b", 500, 50);
    try std.testing.expectEqual(@as(usize, 2), t.len);
    try std.testing.expectEqualStrings("model-a", t.entries[0].text());
    try std.testing.expectEqual(@as(i64, 3000), t.entries[0].prompt_tokens);
    try std.testing.expectEqual(@as(i64, 300), t.entries[0].completion_tokens);
    try std.testing.expectEqual(@as(i64, 500), t.entries[1].prompt_tokens);
}

test "cost: a request that produced no tokens is not a row" {
    // A cancelled stream did not cost anything, and a zero row reads as a model
    // that answered.
    var t = Tracker{};
    t.record("model-a", 0, 0);
    try std.testing.expectEqual(@as(usize, 0), t.len);
}

test "cost: past the cap the tokens go to the spill row, they do not vanish" {
    var t = Tracker{};
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < max_models) : (i += 1) {
        const id = std.fmt.bufPrint(&buf, "model-{d}", .{i}) catch unreachable;
        t.record(id, 100, 10);
    }
    try std.testing.expectEqual(max_models, t.len);
    t.record("one-more", 700, 70);
    t.record("one-more", 300, 30);
    try std.testing.expectEqual(max_models, t.len);
    try std.testing.expectEqual(@as(i64, 1000), t.spill_prompt);
    try std.testing.expectEqual(@as(i64, 100), t.spill_completion);
    try std.testing.expectEqual(@as(usize, 2), t.spill_requests);
}

test "cost: a price that is unknown is null, and the total is a floor" {
    const rows = [_]Row{
        .{ .model = "priced", .prompt = 1_000_000, .completion = 0, .price = .{ .prompt = 0.000003, .completion = 0.000015 } },
        .{ .model = "no-price", .prompt = 5_000, .completion = 500, .price = null },
    };
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), costOf(rows[0]).?, 1e-9);
    try std.testing.expect(costOf(rows[1]) == null);
    try std.testing.expect(@as(usize, 1) == unpricedCount(&rows));
    // Only the priced row is in the sum: a floor, never presented as the bill.
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), totalOf(&rows), 1e-9);
}

test "cost: a published price of zero is $0.00 and is NOT unknown" {
    const free = Row{ .model = "x:free", .prompt = 10_000, .completion = 200, .price = .{ .prompt = 0, .completion = 0 } };
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), costOf(free).?, 1e-12);
    try std.testing.expectEqual(@as(usize, 0), unpricedCount(&[_]Row{free}));
}

test "cost: a free model is $0.00, an unpriced one is unknown, a priced one is the price" {
    const list = [_]models.Model{
        .{ .id = "free-one", .owned_by = "p", .is_free = true },
        .{ .id = "no-prices", .owned_by = "p" },
        .{ .id = "paid", .owned_by = "p", .price_prompt = 0.000003, .price_completion = 0.000015 },
    };
    const free = priceOf(&list, "free-one").found.?;
    try std.testing.expectEqual(@as(f64, 0), free.prompt);
    try std.testing.expectEqual(@as(f64, 0), free.completion);
    // In the catalogue and unpriced: `found: null`, not `missing`.
    try std.testing.expect(priceOf(&list, "no-prices").found == null);
    const paid = priceOf(&list, "paid").found.?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.000003), paid.prompt, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.000015), paid.completion, 1e-12);
    // An id nobody lists is MISSING, and that is not the same as free.
    try std.testing.expect(priceOf(&list, "not-in-the-catalogue") == .missing);
}

test "cost: money is rendered at the precision it was earned" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("$0.00", formatUsd(&buf, 0));
    try std.testing.expectEqualStrings("$1.23", formatUsd(&buf, 1.2345));
    try std.testing.expectEqualStrings("$0.0420", formatUsd(&buf, 0.042));
    try std.testing.expectEqualStrings("$0.000420", formatUsd(&buf, 0.00042));
    try std.testing.expectEqualStrings("<$0.0001", formatUsd(&buf, 0.000042));
    // Not a number is not zero: a NaN printed as $0.00 is a bill that reads free.
    try std.testing.expectEqualStrings("n/a", formatUsd(&buf, std.math.nan(f64)));
}

test "cost: the report names the model, its tokens and the money" {
    const rows = [_]Row{
        .{ .model = "kimi-k2.6", .prompt = 12_345, .completion = 678, .price = .{ .prompt = 0.000001, .completion = 0.000002 } },
        .{ .model = "gated:free", .prompt = 3_000, .completion = 100, .price = null },
    };
    const text = try report(std.testing.allocator, &rows, 3, 15_345);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "cost \u{b7} 3 requests") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "kimi-k2.6") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "12,345 in") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "$0.0137") != null);
    // The unknown one says so, and the total says it is a floor.
    try std.testing.expect(std.mem.indexOf(u8, text, "gated:free") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "price unknown") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "the real bill is higher") != null);
    // Nothing was restored from disk in this run.
    try std.testing.expect(std.mem.indexOf(u8, text, "resumed") == null);
}

test "cost: with NO priced model the report does not invent a $0.00 total" {
    const rows = [_]Row{
        .{ .model = "a", .prompt = 10, .completion = 1, .price = null },
        .{ .model = "b", .prompt = 20, .completion = 2, .price = null },
    };
    const text = try report(std.testing.allocator, &rows, 2, 30);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "no total") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "$0.00") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "price unknown") != null);
}

test "cost: a resumed session with no per-model rows says why, not \"no price\"" {
    const text = try report(std.testing.allocator, &.{}, 3, 1200);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "no per-model breakdown in this process") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "no published price") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "1,200 prompt tokens") != null);
}

test "cost: a resumed session says which tokens are missing from the breakdown" {
    const rows = [_]Row{
        .{ .model = "a", .prompt = 100, .completion = 10, .price = .{ .prompt = 0.000001, .completion = 0.0 } },
    };
    // The session counted 900 prompt tokens before this process started.
    const text = try report(std.testing.allocator, &rows, 4, 1000);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "900 prompt tokens of this session") != null);
}

test "cost: a model id wider than its column is cut, not wrapped" {
    const rows = [_]Row{
        .{ .model = "thinkingmachines/inkling-small:free-with-a-very-long-suffix", .prompt = 1, .completion = 1, .price = null },
    };
    const text = try report(std.testing.allocator, &rows, 1, 1);
    defer std.testing.allocator.free(text);
    // Cut at 36 columns with an ellipsis, never at half a codepoint.
    try std.testing.expect(std.mem.indexOf(u8, text, "\u{2026}") != null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(text));
}

test "cost: groupDigits is the same arithmetic /usage prints" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0", groupDigits(&buf, 0));
    try std.testing.expectEqualStrings("999", groupDigits(&buf, 999));
    try std.testing.expectEqualStrings("1,000", groupDigits(&buf, 1_000));
    try std.testing.expectEqualStrings("1,234,567", groupDigits(&buf, 1_234_567));
}
