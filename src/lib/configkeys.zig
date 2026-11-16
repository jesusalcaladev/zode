//! Whitelist of settings the MODEL may read and change with the `config` tool
//! (Phase 23). Pure on purpose: the key set, secret masking and the exact
//! refusal text are data — testable without a TUI, without IO and without a
//! network.
//!
//! The rules that matter:
//! - WHITELIST, not free-form. Only documented keys; an unknown key is refused
//!   WITH the list of known ones, so the model can fix the call in one turn.
//! - NEVER `auth.json`. Credential-backed keys are reported as "set"/"not set"
//!   and the value is never returned, not even to a `get`.
//! - A `set` that changes every later request (model, compaction, effort) is a
//!   WRITE that asks for permission unless the key was already allowed.

const std = @import("std");

pub const Key = enum {
    model,
    effort,
    compaction,
    auto_check,
    task_parallel,
    output_style,
    web_allow_local,

    pub fn name(self: Key) []const u8 {
        return switch (self) {
            .model => "model",
            .effort => "effort",
            .compaction => "compaction",
            .auto_check => "auto_check",
            .task_parallel => "task_parallel",
            .output_style => "output_style",
            .web_allow_local => "web_allow_local",
        };
    }

    pub fn description(self: Key) []const u8 {
        return switch (self) {
            .model => "model id used for requests",
            .effort => "reasoning effort (none|minimal|low|medium|high|xhigh|max)",
            .compaction => "compaction mode (off|elide|full)",
            .auto_check => "automatic checks after edits (on|off)",
            .task_parallel => "parallel subagents (1-8)",
            .output_style => "output style name, or off",
            .web_allow_local => "let web_fetch reach private ranges (on|off)",
        };
    }

    /// Keys whose value is stored in ~/.config/zode/auth.json, never config.json.
    /// There are none in the whitelist: credentials are deliberately NOT
    /// reachable through this tool at all. This is the invariant that keeps
    /// "never auth.json" true even if someone adds a key later.
    pub fn isSecret(self: Key) bool {
        _ = self;
        return false;
    }

    /// Changing these changes EVERY later request, so `set` must ask unless
    /// the permission was already granted for this key.
    pub fn needsWriteDialog(self: Key) bool {
        return switch (self) {
            .model, .compaction, .effort => true,
            else => false,
        };
    }

    /// Accepted values for `set`, or null when the key accepts any string
    /// (model id, output style name) — those are validated against the live
    /// catalog by the caller, not by this pure catalog.
    pub fn values(self: Key) ?[]const []const u8 {
        return switch (self) {
            .effort => &.{ "none", "minimal", "low", "medium", "high", "xhigh", "max" },
            .compaction => &.{ "off", "elide", "full" },
            .auto_check, .web_allow_local => &.{ "on", "off" },
            .task_parallel => &.{ "1", "2", "3", "4", "5", "6", "7", "8" },
            .model, .output_style => null,
        };
    }
};

pub const all = [_]Key{
    .model,
    .effort,
    .compaction,
    .auto_check,
    .task_parallel,
    .output_style,
    .web_allow_local,
};

pub fn fromName(name: []const u8) ?Key {
    for (all) |k| {
        if (std.mem.eql(u8, k.name(), name)) return k;
    }
    return null;
}

/// The permission-rule subject for a write to this key, e.g. `Config(model)`.
/// The persisted allowlist can remember it, so a second `set model` does not
/// ask again — that is the "already allowed" exception.
pub fn permitSubject(k: Key, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "Config({s})", .{k.name()}) catch null;
}

/// Same as `permitSubject` but from a raw name (used by the registry before
/// the key is validated). Returns null for an unsafe name.
pub fn permitSubjectBound(name: []const u8, gpa: std.mem.Allocator) ?[]const u8 {
    if (fromName(name) == null) return null;
    return std.fmt.allocPrint(gpa, "Config({s})", .{name}) catch null;
}

/// Exact refusal text for an unknown key, including the list of known keys.
pub fn unknownKeyText(gpa: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa, "unknown config key '{s}'. Known keys: ", .{name});
    for (all, 0..) |k, i| {
        if (i > 0) try out.appendSlice(gpa, ", ");
        try out.appendSlice(gpa, k.name());
    }
    try out.appendSlice(gpa, ". Credentials are never reachable with this tool (auth.json is off-limits).");
    return out.toOwnedSlice(gpa);
}

/// A secret value is NEVER returned. The caller passes whether it is set;
/// this produces only the word, never the bytes.
pub fn secretPresenceText(gpa: std.mem.Allocator, name: []const u8, is_set: bool) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{s}: {s} (value never shown)", .{
        name,
        if (is_set) "set" else "not set",
    });
}

/// Validates a `set` value against the key's accepted vocabulary. A null
/// vocabulary means "any non-empty string" (live-validated by the caller).
pub fn validValue(k: Key, value: []const u8) bool {
    if (value.len == 0) return false;
    if (k.values()) |vs| {
        for (vs) |v| if (std.mem.eql(u8, v, value)) return true;
        return false;
    }
    return true;
}

test "configkeys: whitelist has no duplicates and no secret keys" {
    for (all, 0..) |k, i| {
        try std.testing.expect(!k.isSecret());
        for (all[0..i]) |prev| try std.testing.expect(k != prev);
    }
}

test "configkeys: unknown key is refused with the full list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try unknownKeyText(a, "api_key");
    try std.testing.expect(std.mem.indexOf(u8, text, "api_key") != null);
    for (all) |k| try std.testing.expect(std.mem.indexOf(u8, text, k.name()) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "auth.json") != null);
}

test "configkeys: secret presence never leaks the value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = try secretPresenceText(a, "api_key", true);
    try std.testing.expectEqualStrings("api_key: set (value never shown)", t);
    try std.testing.expect(std.mem.indexOf(u8, t, "sk-") == null);
}

test "configkeys: value validation and write-dialog policy" {
    try std.testing.expect(fromName("model") == .model);
    try std.testing.expect(fromName("api_key") == null);
    try std.testing.expect(validValue(.compaction, "full"));
    try std.testing.expect(!validValue(.compaction, "sometimes"));
    try std.testing.expect(validValue(.model, "kimi-k2.6"));
    try std.testing.expect(Key.model.needsWriteDialog());
    try std.testing.expect(Key.compaction.needsWriteDialog());
    try std.testing.expect(!Key.auto_check.needsWriteDialog());
}

test "configkeys: permit subject names the key" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Config(model)", permitSubject(.model, &buf).?);
}
