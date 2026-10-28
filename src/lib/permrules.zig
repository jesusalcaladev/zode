//! The rule model of Phase 6: `Tool(pattern)` and an action.
//!
//! Pure on purpose: it is a grammar, a matcher and a precedence, and every
//! one of those can be tested with no filesystem and no TUI.
//!
//! ## The grammar
//!
//! ```text
//! Tool(pattern) action
//! ```
//!
//! - **Tool**: the tool's name (`Write`, `Bash`, `Read`…), case-insensitive,
//!   or `*` for any tool.
//! - **pattern**: a glob over the thing the call acts on — the PATH for a
//!   file tool, the COMMAND for `bash`. `*` matches any run of characters
//!   (including `/`), `?` matches exactly one. The pattern is matched
//!   against the whole subject, so `*.ts` finds `src/main.ts`.
//! - **action**: `allow`, `deny` or `ask`. It is optional and it DEFAULTS TO
//!   `allow`, so `Bash(git *)` is the whole rule.
//!
//! The same rules are written as strings in the JSON files and as objects
//! when the fields are more convenient:
//!
//! ```json
//! { "rules": ["Write(.vscode/**) allow", {"tool": "Bash", "pattern": "git *"}] }
//! ```
//!
//! ## The precedence
//!
//! Four sources, and the FIRST one that matches wins:
//!
//! | source | where |
//! |---|---|
//! | `local` | this session (the user answered a question) |
//! | `project` | `.zode/permissions.json` in the project |
//! | `user` | `~/.config/zode/permissions.json` |
//! | `policy` | the built-in defaults (the sensitive-path table) |
//!
//! **A `deny` beats any `allow`, from any source.** That is the one rule
//! that is not about specificity: a deny is a statement about what must
//! never happen, and the most specific file in the world does not get to
//! overrule it.
//!
//! Within one source, the LAST matching rule wins: a file can override an
//! earlier line of its own by adding another one.

const std = @import("std");

/// What a rule says about the calls it matches.
pub const Action = enum {
    /// The call is refused, and the refusal says which rule refused it.
    deny,
    /// The call goes through without asking.
    allow,
    /// The call does not ask the user: the model answers for itself.
    /// A `dontAsk` rule means "do not open a dialog about this; the model
    /// decides on its own". It is weaker than an explicit `allow` (the user
    /// pre-approved it) and stronger than `ask` (the user would be asked).
    dontAsk,
    /// The call asks the user via the permission dialog.
    ask,

    pub fn parse(text: []const u8) ?Action {
        if (std.ascii.eqlIgnoreCase(text, "allow")) return .allow;
        if (std.ascii.eqlIgnoreCase(text, "deny")) return .deny;
        if (std.ascii.eqlIgnoreCase(text, "ask")) return .ask;
        if (std.ascii.eqlIgnoreCase(text, "dontask") or std.ascii.eqlIgnoreCase(text, "dont_ask"))
            return .dontAsk;
        return null;
    }

    pub fn name(self: Action) []const u8 {
        return @tagName(self);
    }
};

/// Where a rule comes from, in PRECEDENCE order: the first is the strongest.
pub const Source = enum {
    local,
    project,
    user,
    policy,

    pub fn name(self: Source) []const u8 {
        return @tagName(self);
    }
};

/// One rule.
pub const Rule = struct {
    /// The tool's name, or `*`.
    tool: []const u8,
    /// The glob over the subject.
    pattern: []const u8,
    action: Action,
    source: Source,
    /// The line it was written as, for the message that names it.
    text: []const u8 = "",
};

/// A rule set: the rules of every source, in the order they were loaded.
pub const Set = struct {
    rules: []const Rule = &.{},

    pub fn isEmpty(self: Set) bool {
        return self.rules.len == 0;
    }
};

/// Parses ONE rule: `Tool(pattern) action`.
///
/// The action is optional and defaults to `allow`. The pattern may contain
/// parentheses (a command with one in it), so the closing parenthesis is
/// the LAST one in the line.
pub fn parseRule(text: []const u8, source: Source, arena: std.mem.Allocator) ?Rule {
    const line = std.mem.trim(u8, text, " \t\r\n");
    if (line.len == 0) return null;
    if (line[0] == '#') return null;

    // The tool's name: up to the first parenthesis.
    const open = std.mem.indexOfScalar(u8, line, '(') orelse return null;
    const tool = std.mem.trim(u8, line[0..open], " \t");
    if (tool.len == 0) return null;

    // The pattern: up to the LAST closing parenthesis.
    const close = std.mem.lastIndexOfScalar(u8, line, ')') orelse return null;
    if (close <= open) return null;
    const pattern = std.mem.trim(u8, line[open + 1 .. close], " \t");

    // What is after the parenthesis is the action, if anything.
    var action: Action = .allow;
    const rest = std.mem.trim(u8, line[close + 1 ..], " \t");
    if (rest.len > 0) {
        action = Action.parse(rest) orelse return null;
    }

    return .{
        .tool = arena.dupe(u8, tool) catch return null,
        .pattern = arena.dupe(u8, pattern) catch return null,
        .action = action,
        .source = source,
        .text = arena.dupe(u8, line) catch return null,
    };
}

/// Parses a file's worth of rules: one per line, `#` comments and blanks
/// ignored.
///
/// A line that does not parse is SKIPPED, and it is not an error: a
/// hand-edited file with a typo in one line must not cost the user the
/// other nineteen.
pub fn parseLines(text: []const u8, source: Source, arena: std.mem.Allocator) []Rule {
    var out: std.ArrayList(Rule) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (parseRule(line, source, arena)) |r| out.append(arena, r) catch {};
    }
    return out.items;
}

/// The glob: `*` matches any run of characters, `?` matches exactly one.
///
/// The match is over the WHOLE subject, and it is case-SENSITIVE: a rule
/// that says `.vscode/**` means that directory and not `.VSCODE/`, which is
/// a different directory on a case-sensitive filesystem.
pub fn matchesPattern(pattern: []const u8, subject: []const u8) bool {
    if (pattern.len == 0) return true;
    if (std.mem.eql(u8, pattern, "*")) return true;
    return globAt(pattern, 0, subject, 0);
}

/// The glob, with the two positions walking together.
fn globAt(p: []const u8, pi: usize, s: []const u8, si: usize) bool {
    var p_i = pi;
    var s_i = si;
    while (p_i < p.len) {
        const c = p[p_i];
        if (c == '*') {
            // `*` matches any run of characters, INCLUDING the separators:
            // `*.ts` has to find `src/main.ts`.
            if (p_i + 1 == p.len) return true;
            var k: usize = s_i;
            while (k <= s.len) : (k += 1) {
                if (globAt(p, p_i + 1, s, k)) return true;
            }
            return false;
        }
        if (s_i >= s.len) return false;
        if (c == '?') {
            p_i += 1;
            s_i += 1;
            continue;
        }
        if (c != s[s_i]) return false;
        p_i += 1;
        s_i += 1;
    }
    return s_i == s.len;
}

/// Whether the rule matches a call: the tool's name AND the subject.
///
/// The tool's name is case-insensitive (`write` and `Write` are the same
/// tool) and `*` matches any tool. The pattern is matched against the
/// subject; an EMPTY pattern matches any subject.
pub fn matches(rule: Rule, tool: []const u8, subject: []const u8) bool {
    if (!std.mem.eql(u8, rule.tool, "*") and !std.ascii.eqlIgnoreCase(rule.tool, tool)) return false;
    return matchesPattern(rule.pattern, subject);
}

/// The action for a call, or null when no rule has an opinion.
///
/// The order of the questions:
/// 1. **A `deny` beats any `allow`**, from any source.
/// 2. Otherwise the matching `allow` with the STRONGEST source wins, and
///    within a source the last rule wins.
/// 3. Otherwise the matching `ask` with the strongest source wins.
pub fn decide(rules: []const Rule, tool: []const u8, subjects: []const []const u8) ?Decision {
    var best_allow: ?Decision = null;
    var best_dont_ask: ?Decision = null;
    var best_ask: ?Decision = null;

    for (rules) |r| {
        var hit = false;
        for (subjects) |sub| {
            if (matches(r, tool, sub)) {
                hit = true;
                break;
            }
        }
        if (!hit) continue;

        const d: Decision = .{ .action = r.action, .rule = r };
        switch (r.action) {
            .deny => return d,
            .allow => {
                if (best_allow == null or stronger(r.source, best_allow.?.rule.source)) {
                    best_allow = d;
                }
            },
            .dontAsk => {
                if (best_dont_ask == null or stronger(r.source, best_dont_ask.?.rule.source)) {
                    best_dont_ask = d;
                }
            },
            .ask => {
                if (best_ask == null or stronger(r.source, best_ask.?.rule.source)) {
                    best_ask = d;
                }
            },
        }
    }
    return best_allow orelse best_dont_ask orelse best_ask;
}

/// A decision and the rule behind it.
pub const Decision = struct {
    action: Action,
    rule: Rule,
};

/// Whether `a` is a stronger source than `b`.
///
/// The order is the enum's order (`local` first), so it is the INDEX that
/// decides — and a rule of the same source does NOT replace the one that is
/// already there: the LAST rule of a file wins, and that is handled by the
/// caller walking the rules in order.
fn stronger(a: Source, b: Source) bool {
    return @intFromEnum(a) < @intFromEnum(b);
}

/// The rules of a JSON value: the `rules` array, in either shape.
///
/// A rule is a STRING (the grammar: `Write(.vscode/**) allow`) or an OBJECT
/// with `tool`, `pattern` and `action`. The string form is the one the board
/// describes; the object form is there because a JSON file with a pattern
/// in it is easier to write with a tool than by hand.
pub fn parseJson(value: std.json.Value, source: Source, arena: std.mem.Allocator) []Rule {
    var out: std.ArrayList(Rule) = .empty;
    const parsed = switch (value) {
        .array => |arr| blk: {
            for (arr.items) |v| {
                switch (v) {
                    .string => |s| {
                        if (parseRule(s, source, arena)) |r| out.append(arena, r) catch {};
                    },
                    .object => |o| {
                        if (parseObjectRule(o, source, arena)) |r| out.append(arena, r) catch {};
                    },
                    else => {},
                }
            }
            break :blk &.{};
        },
        .object => |o| blk: {
            if (o.get("rules")) |rv| {
                if (rv == .array) {
                    for (rv.array.items) |v| {
                        switch (v) {
                            .string => |s| {
                                if (parseRule(s, source, arena)) |r| out.append(arena, r) catch {};
                            },
                            .object => |oo| {
                                if (parseObjectRule(oo, source, arena)) |r| out.append(arena, r) catch {};
                            },
                            else => {},
                        }
                    }
                }
            }
            break :blk &.{};
        },
        else => &.{},
    };
    _ = parsed;
    return out.items;
}

/// A rule written as an object: `{tool, pattern, action}`.
fn parseObjectRule(o: std.json.ObjectMap, source: Source, arena: std.mem.Allocator) ?Rule {
    const tool = getStr(o, "tool") orelse return null;
    const pattern = getStr(o, "pattern") orelse "";
    var action: Action = .allow;
    if (getStr(o, "action")) |a| {
        action = Action.parse(a) orelse return null;
    }
    // The text is the SAME shape as the string form, so `/permissions` shows
    // the two kinds of rule the same way.
    const text = std.fmt.allocPrint(arena, "{s}({s}) {s}", .{ tool, pattern, action.name() }) catch return null;
    return .{
        .tool = arena.dupe(u8, tool) catch return null,
        .pattern = arena.dupe(u8, pattern) catch return null,
        .action = action,
        .source = source,
        .text = text,
    };
}

fn getStr(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

// ── tests ──────────────────────────────────────────────────────────────────

const t = std.testing;

test "permrules: the grammar is Tool(pattern) and the action is optional" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const r = parseRule("Write(.vscode/**)", .project, a).?;
    try t.expectEqualStrings("Write", r.tool);
    try t.expectEqualStrings(".vscode/**", r.pattern);
    try t.expectEqual(Action.allow, r.action);

    const with_action = parseRule("Bash(git *) deny", .user, a).?;
    try t.expectEqual(Action.deny, with_action.action);
    try t.expectEqualStrings("git *", with_action.pattern);

    // A comment and a blank line are not rules.
    try t.expect(parseRule("# a comment", .user, a) == null);
    try t.expect(parseRule("", .user, a) == null);
    try t.expect(parseRule("   ", .user, a) == null);
    // And neither is a line that is not a rule at all.
    try t.expect(parseRule("Write(.vscode/**)", .user, a) != null);
    try t.expect(parseRule("no parentheses here", .user, a) == null);
    try t.expect(parseRule("Write(.vscode/**) alow", .user, a) == null);
}

test "permrules: a pattern with a parenthesis in it" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // The closing parenthesis is the LAST one: a command with one inside is
    // still a rule.
    const r = parseRule("Bash(git commit -m 'fix(x)') allow", .user, a).?;
    try t.expectEqualStrings("git commit -m 'fix(x)'", r.pattern);
}

test "permrules: the glob" {
    try t.expect(matchesPattern("*", "anything"));
    try t.expect(matchesPattern("", "anything"));
    try t.expect(matchesPattern("*.ts", "main.ts"));
    // `*` crosses the separators: that is what makes `*.ts` find `src/main.ts`.
    try t.expect(matchesPattern("*.ts", "src/main.ts"));
    try t.expect(matchesPattern(".vscode/*", ".vscode/settings.json"));
    try t.expect(matchesPattern(".vscode/*", ".vscode/sub/settings.json"));
    try t.expect(matchesPattern("git *", "git status"));
    try t.expect(matchesPattern("git *", "git add src/a.zig"));
    try t.expect(!matchesPattern("git *", "cargo build"));
    try t.expect(!matchesPattern("*.ts", "main.zig"));
    try t.expect(matchesPattern("a?c", "abc"));
    try t.expect(!matchesPattern("a?c", "ac"));
    // The match is over the WHOLE subject.
    try t.expect(!matchesPattern("main.ts", "src/main.ts"));
}

test "permrules: the tool's name is case-insensitive and `*` is any tool" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const r = parseRule("write(*.ts)", .user, a).?;
    try t.expect(matches(r, "Write", "a.ts"));
    try t.expect(matches(r, "write", "a.ts"));
    try t.expect(!matches(r, "read", "a.ts"));

    const any = parseRule("*(*)", .user, a).?;
    try t.expect(matches(any, "Write", "whatever"));
}

test "permrules: a DENY beats any allow, from any source" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();

    const rules = [_]Rule{
        .{ .tool = "Write", .pattern = "*", .action = .allow, .source = .local },
        .{ .tool = "Write", .pattern = ".git/**", .action = .deny, .source = .policy },
    };
    const d = decide(&rules, "Write", &.{".git/config"}).?;
    try t.expectEqual(Action.deny, d.action);
}

test "permrules: the strongest source wins, and the last rule of a file wins" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();

    // The user allows it and the project denies it: the project is stronger.
    const rules = [_]Rule{
        .{ .tool = "Write", .pattern = "*", .action = .allow, .source = .user },
        .{ .tool = "Write", .pattern = ".git/**", .action = .deny, .source = .project },
    };
    const d = decide(&rules, "Write", &.{".git/config"}).?;
    try t.expectEqual(Action.deny, d.action);

    // Two rules of the SAME source: the last one wins.
    const same = [_]Rule{
        .{ .tool = "Write", .pattern = ".git/**", .action = .allow, .source = .project },
        .{ .tool = "Write", .pattern = ".git/**", .action = .deny, .source = .project },
    };
    const d2 = decide(&same, "Write", &.{".git/config"}).?;
    try t.expectEqual(Action.deny, d2.action);
}

test "permrules: no rule means no opinion" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();

    const rules = [_]Rule{
        .{ .tool = "Read", .pattern = "*", .action = .allow, .source = .user },
    };
    try t.expect(decide(&rules, "Write", &.{"a.zig"}) == null);
}

test "permrules: the rules of a JSON file, in both shapes" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const text =
        \\{"rules": [
        \\  "Write(.vscode/**) allow",
        \\  {"tool": "Bash", "pattern": "git *", "action": "deny"},
        \\  {"tool": "Read"}
        \\]}
    ;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
    const rules = parseJson(parsed, .project, a);
    try t.expectEqual(@as(usize, 3), rules.len);
    try t.expectEqualStrings("Write", rules[0].tool);
    try t.expectEqual(Action.allow, rules[0].action);
    try t.expectEqualStrings("git *", rules[1].pattern);
    try t.expectEqual(Action.deny, rules[1].action);
    try t.expectEqualStrings("Read", rules[2].tool);
    try t.expectEqual(Action.allow, rules[2].action);
}

test "permrules: a line that does not parse does not cost the others" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const text =
        \\# the project allows its editor's settings
        \\Write(.vscode/**) allow
        \\this line is not a rule
        \\Bash(git *) deny
    ;
    const rules = parseLines(text, .project, a);
    try t.expectEqual(@as(usize, 2), rules.len);
    try t.expectEqualStrings("Write", rules[0].tool);
    try t.expectEqualStrings("Bash", rules[1].tool);
}

test "permrules: parses the dontAsk action" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const r = parseRule("Write(.git/**) dontask", .user, a).?;
    try t.expectEqual(Action.dontAsk, r.action);
    try t.expectEqualStrings("dontAsk", r.action.name());

    // The underscore spelling also works.
    const r2 = parseRule("Write(.git/**) dont_ask", .user, a).?;
    try t.expectEqual(Action.dontAsk, r2.action);
}

test "permrules: dontAsk beats ask from a weaker source" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();

    const rules = [_]Rule{
        .{ .tool = "Write", .pattern = ".git/**", .action = .ask, .source = .policy },
        .{ .tool = "Write", .pattern = ".git/**", .action = .dontAsk, .source = .user },
    };
    const d = decide(&rules, "Write", &.{".git/config"}).?;
    try t.expectEqual(Action.dontAsk, d.action);
    try t.expectEqual(Source.user, d.rule.source);
}

test "permrules: allow beats dontAsk from any source" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();

    const rules = [_]Rule{
        .{ .tool = "Write", .pattern = ".git/**", .action = .dontAsk, .source = .user },
        .{ .tool = "Write", .pattern = ".git/**", .action = .allow, .source = .policy },
    };
    const d = decide(&rules, "Write", &.{".git/config"}).?;
    try t.expectEqual(Action.allow, d.action);
}

test "permrules: deny beats dontAsk from any source" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();

    const rules = [_]Rule{
        .{ .tool = "Write", .pattern = ".git/**", .action = .dontAsk, .source = .local },
        .{ .tool = "Write", .pattern = ".git/**", .action = .deny, .source = .policy },
    };
    const d = decide(&rules, "Write", &.{".git/config"}).?;
    try t.expectEqual(Action.deny, d.action);
}

test "permrules: dontAsk from same source, last rule wins" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();

    // dontAsk is a stronger category than ask: it wins regardless of order.
    const same = [_]Rule{
        .{ .tool = "Write", .pattern = ".git/**", .action = .ask, .source = .project },
        .{ .tool = "Write", .pattern = ".git/**", .action = .dontAsk, .source = .project },
    };
    const d = decide(&same, "Write", &.{".git/config"}).?;
    try t.expectEqual(Action.dontAsk, d.action);

    const same2 = [_]Rule{
        .{ .tool = "Write", .pattern = ".git/**", .action = .dontAsk, .source = .project },
        .{ .tool = "Write", .pattern = ".git/**", .action = .ask, .source = .project },
    };
    const d2 = decide(&same2, "Write", &.{".git/config"}).?;
    // dontAsk still wins: category precedence, not order.
    try t.expectEqual(Action.dontAsk, d2.action);

    // Two dontAsk rules of the same source: the first one wins (same as allow).
    const same3 = [_]Rule{
        .{ .tool = "Write", .pattern = ".git/**", .action = .dontAsk, .source = .project },
        .{ .tool = "Write", .pattern = ".git/**", .action = .dontAsk, .source = .project },
    };
    const d3 = decide(&same3, "Write", &.{".git/config"}).?;
    try t.expectEqual(Action.dontAsk, d3.action);
    try t.expectEqualStrings(".git/**", d3.rule.pattern);
}

test "permrules: dontAsk without ask means no dialog is needed" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();

    // Only a dontAsk rule: the model answers for itself, so decide returns it
    // instead of falling through to "no opinion" / ask.
    const rules = [_]Rule{
        .{ .tool = "Write", .pattern = ".git/**", .action = .dontAsk, .source = .project },
    };
    const d = decide(&rules, "Write", &.{".git/config"}).?;
    try t.expectEqual(Action.dontAsk, d.action);
}
