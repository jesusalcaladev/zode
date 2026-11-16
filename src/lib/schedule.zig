//! Scheduled prompts (Phase 19): a recurring prompt for this project, stored
//! next to the session and delivered as a user message when it fires.
//!
//! Pure on purpose: parsing a schedule file, deciding which schedules are due,
//! and computing the next fire time need no clock, no session and no network.
//! The harness owns the clock and the delivery; `Once` schedules are removed
//! after one fire.

const std = @import("std");
const cron_mod = @import("cron.zig");

pub const max_schedules: usize = 32;
pub const max_prompt: usize = 8000;
pub const max_expr: usize = 128;
pub const max_id: usize = 32;

pub const Schedule = struct {
    id_buf: [max_id]u8 = undefined,
    id_len: usize = 0,
    expr_buf: [max_expr]u8 = undefined,
    expr_len: usize = 0,
    prompt_buf: [max_prompt]u8 = undefined,
    prompt_len: usize = 0,
    /// Fire once and be removed, instead of recurring.
    once: bool = false,
    /// Epoch seconds of the last fire (0 = never).
    last_fire: i64 = 0,

    pub fn id(self: *const Schedule) []const u8 {
        return self.id_buf[0..self.id_len];
    }

    pub fn expr(self: *const Schedule) []const u8 {
        return self.expr_buf[0..self.expr_len];
    }

    pub fn prompt(self: *const Schedule) []const u8 {
        return self.prompt_buf[0..self.prompt_len];
    }
};

pub const Error = error{
    Full,
    BadExpression,
    EmptyPrompt,
    PromptTooLong,
    UnknownId,
    BadFile,
};

pub const Store = struct {
    items: [max_schedules]Schedule = undefined,
    len: usize = 0,

    pub fn add(self: *Store, id_str: []const u8, expr_str: []const u8, prompt_str: []const u8, once: bool) Error!void {
        if (self.len >= max_schedules) return error.Full;
        _ = cron_mod.parse(expr_str) catch return error.BadExpression;
        if (prompt_str.len == 0) return error.EmptyPrompt;
        if (prompt_str.len > max_prompt or expr_str.len > max_expr or id_str.len > max_id) return error.PromptTooLong;
        const s = &self.items[self.len];
        @memcpy(s.id_buf[0..id_str.len], id_str);
        s.id_len = id_str.len;
        @memcpy(s.expr_buf[0..expr_str.len], expr_str);
        s.expr_len = expr_str.len;
        @memcpy(s.prompt_buf[0..prompt_str.len], prompt_str);
        s.prompt_len = prompt_str.len;
        s.once = once;
        s.last_fire = 0;
        self.len += 1;
    }

    pub fn indexOf(self: *const Store, id_str: []const u8) ?usize {
        for (self.items[0..self.len], 0..) |s, i| {
            if (std.mem.eql(u8, s.id(), id_str)) return i;
        }
        return null;
    }

    /// Remove by id. Returns true when something was removed.
    pub fn remove(self: *Store, id_str: []const u8) bool {
        const ix = self.indexOf(id_str) orelse return false;
        var j = ix;
        while (j + 1 < self.len) : (j += 1) self.items[j] = self.items[j + 1];
        self.len -= 1;
        return true;
    }

    /// Return the indices of schedules that should fire at the given epoch
    /// time. A schedule fires when its cron matches the current minute AND it
    /// has not already fired in that same minute (last_fire < now).
    pub fn due(self: *const Store, now_secs: i64, out: []usize) usize {
        if (now_secs < 0) return 0;
        const ep = std.time.epoch.EpochSeconds{ .secs = @intCast(now_secs) };
        const ds = ep.getDaySeconds();
        const md = ep.getEpochDay().calculateYearDay().calculateMonthDay();
        const minute: usize = ds.getMinutesIntoHour();
        const hour: usize = ds.getHoursIntoDay();
        const dom: usize = md.day_index + 1;
        // std.time.epoch.Month is 1-based (jan=1); cron.zig maps jan→0.
        const mon: usize = @intFromEnum(md.month) - 1;
        // 1970-01-01 was a Thursday (dow = 4 in cron's 0=Sunday convention).
        const epoch_day: usize = @intCast(ep.getEpochDay().day);
        const dow: usize = (epoch_day + 4) % 7;
        var n: usize = 0;
        for (self.items[0..self.len], 0..) |s, i| {
            if (n >= out.len) break;
            // last_fire == 0 means "never fired", even at epoch time 0.
            if (s.last_fire != 0 and s.last_fire >= now_secs) continue; // already fired this minute
            const c = cron_mod.parse(s.expr()) catch continue;
            if (c.matches(minute, hour, dom, mon, dow)) {
                out[n] = i;
                n += 1;
            }
        }
        return n;
    }

    pub fn markFired(self: *Store, index: usize, now_secs: i64) void {
        if (index < self.len) self.items[index].last_fire = now_secs;
    }

    /// Serialize the store to a compact JSON array.
    pub fn toJson(self: *const Store, gpa: std.mem.Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.append(gpa, '[');
        for (self.items[0..self.len], 0..) |s, i| {
            if (i > 0) try out.append(gpa, ',');
            try out.appendSlice(gpa, "{\"id\":");
            try writeStr(&out, gpa, s.id());
            try out.appendSlice(gpa, ",\"cron\":");
            try writeStr(&out, gpa, s.expr());
            try out.appendSlice(gpa, ",\"prompt\":");
            try writeStr(&out, gpa, s.prompt());
            try out.print(gpa, ",\"once\":{s},\"last_fire\":{d}}}", .{
                if (s.once) "true" else "false", s.last_fire,
            });
        }
        try out.append(gpa, ']');
        return out.toOwnedSlice(gpa);
    }

/// Load from JSON. Malformed or unknown fields are skipped so a hand-edit or
/// an older version cannot take the whole session down.
pub fn fromJson(self: *Store, gpa: std.mem.Allocator, data: []const u8) void {
    self.len = 0;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, gpa, data, .{}) catch return;
    if (parsed != .array) return;
    for (parsed.array.items) |item| {
        if (item != .object) continue;
        const id_v = item.object.get("id") orelse continue;
        const cron_v = item.object.get("cron") orelse continue;
        const prompt_v = item.object.get("prompt") orelse continue;
        if (id_v != .string or cron_v != .string or prompt_v != .string) continue;
        const once = if (item.object.get("once")) |v| (v == .bool and v.bool) else false;
        self.add(id_v.string, cron_v.string, prompt_v.string, once) catch continue;
        if (item.object.get("last_fire")) |v| {
            if (v == .integer) self.items[self.len - 1].last_fire = v.integer;
        }
    }
}

};

fn writeStr(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    try out.append(gpa, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(gpa, "\\\""),
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            else => try out.append(gpa, c),
        }
    }
    try out.append(gpa, '"');
}

pub fn pathForSession(buf: []u8, session_path: []const u8) ![]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, session_path, '.') orelse return error.BadFile;
    if (!std.mem.endsWith(u8, session_path, ".jsonl")) return error.BadFile;
    return std.fmt.bufPrint(buf, "{s}.schedules.json", .{session_path[0..dot]}) catch error.BadFile;
}

test "schedule: add/list/remove by id" {
    var store = Store{};
    try store.add("a", "0 9 * * 1", "run the flaky test", false);
    try store.add("b", "*/15 * * * *", "check the build", true);
    try std.testing.expectEqual(@as(usize, 2), store.len);
    try std.testing.expect(store.indexOf("a") != null);
    try std.testing.expect(store.items[store.indexOf("b").?].once);
    try std.testing.expect(store.remove("a"));
    try std.testing.expect(!store.remove("a"));
    try std.testing.expectEqual(@as(usize, 1), store.len);
}

test "schedule: rejects bad expression and empty prompt" {
    var store = Store{};
    try std.testing.expectError(error.BadExpression, store.add("a", "not a cron", "x", false));
    try std.testing.expectError(error.EmptyPrompt, store.add("a", "* * * * *", "", false));
}

test "schedule: fires on a matching minute and not twice in the same minute" {
    var store = Store{};
    // 1970-01-01 00:00 UTC was a Thursday; "* * * * *" fires every minute.
    try store.add("every", "* * * * *", "tick", false);
    var out: [max_schedules]usize = undefined;
    const n = store.due(60, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    store.markFired(out[0], 60);
    try std.testing.expectEqual(@as(usize, 0), store.due(60, &out));
    // One minute later it fires again (a recurring schedule).
    try std.testing.expectEqual(@as(usize, 1), store.due(120, &out));
}

test "schedule: once flag does not repeat automatically (harness removes it)" {
    var store = Store{};
    try store.add("once", "* * * * *", "do it once", true);
    try std.testing.expect(store.items[0].once);
    // The store does not fire twice in the same minute; the harness removes a
    // `once` schedule after its first fire (tested via remove above).
    var out: [max_schedules]usize = undefined;
    try std.testing.expectEqual(@as(usize, 1), store.due(0, &out));
    store.markFired(out[0], 0);
    _ = store.remove("once");
    try std.testing.expectEqual(@as(usize, 0), store.len);
}

test "schedule: sidecar path derives from the session" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/s/zode-ab.schedules.json",
        (pathForSession(&buf, "/s/zode-ab.jsonl") catch unreachable),
    );
}

test "schedule: JSON round-trip preserves schedules and last_fire" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var store = Store{};
    try store.add("monday", "0 9 * * 1", "run the flaky test", false);
    store.markFired(0, 12345);
    const data = try store.toJson(a);

    var loaded = Store{};
    loaded.fromJson(a, data);
    try std.testing.expectEqual(@as(usize, 1), loaded.len);
    try std.testing.expectEqualStrings("monday", loaded.items[0].id());
    try std.testing.expectEqualStrings("run the flaky test", loaded.items[0].prompt());
    try std.testing.expectEqual(@as(i64, 12345), loaded.items[0].last_fire);
}
