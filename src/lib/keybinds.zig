//! Configurable keybindings (Phase 13.3). Pure resolution layer: it knows
//! nothing about Vaxis or the TUI — the caller turns a key event into a
//! canonical key string, asks `Map.resolve`, and runs the returned command.
//!
//! A binding maps a canonical key (or a space-separated chord like "g g") to
//! an existing zode command name. User bindings override the defaults by key;
//! they never add a new command out of thin air, so a typo is a missing
//! command, not a crash. Everything here is string math and testable without
//! a terminal.

const std = @import("std");

pub const Binding = struct {
    key: []const u8,
    command: []const u8,
};

/// The built-in layer. These duplicate existing hardwired shortcuts so the
/// configuration surface can show and override them; the TUI is the runtime
/// owner of the actual actions.
// Keys that currently fall through to the composer, so a default adds an
// action instead of fighting a hardwired shortcut. Commands are the real
// slash-command names (they include the leading slash).
pub const defaults = [_]Binding{
    .{ .key = "f2", .command = "/help" },
    .{ .key = "f3", .command = "/context" },
    .{ .key = "f4", .command = "/session" },
    .{ .key = "f5", .command = "/tasks" },
};

/// Canonicalize a user spelling into the form `resolve` looks up.
/// Accepts `Ctrl+P`, `C-P`, `ctrl+p`, `esc`/`escape`, `enter`/`return`, and
/// leaves a space-separated chord intact (each part is canonicalized).
/// Returns null for an empty key or an unsupported form.
pub fn canonicalize(gpa: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var parts = std.mem.tokenizeAny(u8, trimmed, " \t");
    var first = true;
    while (parts.next()) |part| {
        if (!first) try out.append(gpa, ' ');
        first = false;
        const c = try canonicalPart(gpa, part) orelse return null;
        defer gpa.free(c);
        try out.appendSlice(gpa, c);
    }
    if (out.items.len == 0) {
        out.deinit(gpa);
        return null;
    }
    return try out.toOwnedSlice(gpa);
}

fn canonicalPart(gpa: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    var lower_buf: [64]u8 = undefined;
    if (raw.len > lower_buf.len) return null;
    for (raw, 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
    const s = lower_buf[0..raw.len];

    // Aliases and modifiers.
    if (std.mem.eql(u8, s, "escape") or std.mem.eql(u8, s, "esc")) return @as(?[]const u8, try gpa.dupe(u8, "esc"));
    if (std.mem.eql(u8, s, "return") or std.mem.eql(u8, s, "cr") or std.mem.eql(u8, s, "enter")) return @as(?[]const u8, try gpa.dupe(u8, "enter"));
    if (std.mem.eql(u8, s, "space") or std.mem.eql(u8, s, "spc")) return @as(?[]const u8, try gpa.dupe(u8, "space"));
    if (std.mem.eql(u8, s, "del")) return @as(?[]const u8, try gpa.dupe(u8, "delete"));
    if (std.mem.eql(u8, s, "pageup")) return @as(?[]const u8, try gpa.dupe(u8, "pageup"));
    if (std.mem.eql(u8, s, "pagedown")) return @as(?[]const u8, try gpa.dupe(u8, "pagedown"));

    var mods: std.ArrayList(u8) = .empty;
    defer mods.deinit(gpa);
    var body: []const u8 = s;
    // Emacs-style leading modifiers: C-x, M-x, S-x, and combinations C-M-x.
    while (body.len > 2 and body[1] == '-') {
        const m: ?[]const u8 = switch (body[0]) {
            'c' => "ctrl",
            'm' => "alt",
            's' => "shift",
            else => null,
        };
        if (m == null) break;
        if (mods.items.len > 0) try mods.append(gpa, '+');
        try mods.appendSlice(gpa, m.?);
        body = body[2..];
    }
    if (std.mem.indexOfScalar(u8, s, '+') != null) {
        var it = std.mem.splitScalar(u8, s, '+');
        var tail: []const u8 = "";
        mods.clearRetainingCapacity();
        while (it.next()) |piece| tail = piece;
        // The last piece is the key; everything before is a modifier. Preserve
        // the original spelling of the pieces (they are already lowercased).
        it = std.mem.splitScalar(u8, s, '+');
        var count: usize = 0;
        while (it.next()) |piece| {
            count += 1;
            if (count == std.mem.count(u8, s, "+") + 1) break;
            if (mods.items.len > 0) try mods.append(gpa, '+');
            if (std.mem.eql(u8, piece, "ctrl") or std.mem.eql(u8, piece, "c")) {
                try mods.appendSlice(gpa, "ctrl");
            } else if (std.mem.eql(u8, piece, "alt") or std.mem.eql(u8, piece, "m")) {
                try mods.appendSlice(gpa, "alt");
            } else if (std.mem.eql(u8, piece, "shift") or std.mem.eql(u8, piece, "s")) {
                try mods.appendSlice(gpa, "shift");
            } else {
                return null;
            }
        }
        body = tail;
    }
    if (body.len == 0) return null;
    // A named key stays as-is; a single byte is its own key.
    if (body.len > 1 and !isNamedKey(body)) return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (mods.items.len > 0) {
        try out.appendSlice(gpa, mods.items);
        try out.append(gpa, '+');
    }
    try out.appendSlice(gpa, body);
    return @as(?[]const u8, try out.toOwnedSlice(gpa));
}

fn isNamedKey(s: []const u8) bool {
    const names = [_][]const u8{ "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12", "up", "down", "left", "right", "home", "end", "tab", "backspace", "delete", "pageup", "pagedown", "insert", "esc", "enter", "space" };
    for (names) |n| if (std.mem.eql(u8, s, n)) return true;
    return false;
}

/// A resolved, immutable binding table. Later entries override earlier ones
/// for the same key, so build it as defaults followed by user overrides.
pub const Map = struct {
    bindings: []const Binding,

    pub fn resolve(self: Map, key: []const u8) ?[]const u8 {
        // Walk backwards: the last binding for a key wins.
        var i = self.bindings.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.bindings[i].key, key)) return self.bindings[i].command;
        }
        return null;
    }

    /// Is every command non-empty and every key well-formed enough to look up?
    pub fn validate(self: Map) bool {
        for (self.bindings) |b| {
            if (b.key.len == 0 or b.command.len == 0) return false;
        }
        return true;
    }
};

/// Build the effective table: defaults first, then user bindings in order.
pub fn merged(gpa: std.mem.Allocator, user: []const Binding) ![]Binding {
    var out: std.ArrayList(Binding) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &defaults);
    try out.appendSlice(gpa, user);
    return try out.toOwnedSlice(gpa);
}

/// Read a `{ "key": "command", ... }` JSON object into bindings. Unknown or
/// malformed keys are skipped rather than crashing the TUI; the returned
/// strings borrow `value`.
pub fn parseJsonObject(gpa: std.mem.Allocator, value: std.json.Value) ![]Binding {
    var out: std.ArrayList(Binding) = .empty;
    errdefer out.deinit(gpa);
    if (value != .object) return try out.toOwnedSlice(gpa);
    var it = value.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        const key = try canonicalize(gpa, entry.key_ptr.*) orelse continue;
        defer gpa.free(key);
        const cmd = std.mem.trim(u8, entry.value_ptr.string, " \t\r\n");
        if (cmd.len == 0) continue;
        try out.append(gpa, .{ .key = try gpa.dupe(u8, key), .command = try gpa.dupe(u8, cmd) });
    }
    return try out.toOwnedSlice(gpa);
}

pub fn freeBindings(gpa: std.mem.Allocator, bindings: []const Binding) void {
    for (bindings) |b| {
        gpa.free(b.key);
        gpa.free(b.command);
    }
    gpa.free(bindings);
}

test "keybinds: canonicalize modifiers and aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("ctrl+p", (try canonicalize(a, "Ctrl+P")).?);
    try std.testing.expectEqualStrings("ctrl+p", (try canonicalize(a, "C-p")).?);
    try std.testing.expectEqualStrings("esc", (try canonicalize(a, "Escape")).?);
    try std.testing.expectEqualStrings("ctrl+alt+x", (try canonicalize(a, "ctrl+alt+x")).?);
    try std.testing.expectEqualStrings("g g", (try canonicalize(a, "g g")).?);
    try std.testing.expect((try canonicalize(a, "")) == null);
    try std.testing.expect((try canonicalize(a, "notakey")) == null);
}

test "keybinds: later bindings override earlier ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const table = try merged(a, &.{
        .{ .key = "f2", .command = "/help-custom" },
        .{ .key = "alt+n", .command = "next" },
    });
    try std.testing.expectEqualStrings("/help-custom", (Map{ .bindings = table }).resolve("f2").?);
    try std.testing.expectEqualStrings("next", (Map{ .bindings = table }).resolve("alt+n").?);
    try std.testing.expect((Map{ .bindings = table }).resolve("f7") == null);
}

test "keybinds: parse a JSON object into bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"Ctrl+K":"/palette","g g":"/goto","bad":"","n":7}
    , .{});
    const bindings = try parseJsonObject(a, parsed);
    const table = Map{ .bindings = bindings };
    try std.testing.expectEqualStrings("/palette", table.resolve("ctrl+k").?);
    try std.testing.expectEqualStrings("/goto", table.resolve("g g").?);
    try std.testing.expect(table.resolve("n") == null);
    try std.testing.expect(table.validate());
}
