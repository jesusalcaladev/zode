const std = @import("std");
const tools_mod = @import("../tools/dispatch.zig");
const permrules = @import("../lib/permrules.zig");

pub fn formatRuleDenyMessage(rule_text: []const u8, source_name: []const u8, arena: std.mem.Allocator) []const u8 {
    return std.fmt.allocPrint(
        arena,
        "refused: the rule `{s}` ({s}) does not allow this.",
        .{ rule_text, source_name },
    ) catch "refused: a permission rule does not allow this.";
}

pub fn formatRuleAskText(rule_text: []const u8, pattern: []const u8, source: permrules.Source, arena: std.mem.Allocator) []const u8 {
    if (source == .policy)
        return std.fmt.allocPrint(arena, "policy: protected path ({s})", .{pattern}) catch rule_text;
    return rule_text;
}

pub const HookPermDecision = enum { allow, deny, ask };

pub fn mapHookPermDecision(decision: anytype) HookPermDecision {
    // hooks_mod.permissionDecision returns an enum with allow/deny/ask variants.
    return switch (decision) {
        .allow => .allow,
        .deny => .deny,
        .ask => .ask,
    };
}

/// The rule the "always allow" answer would remember, as TEXT.
/// See agent.zig permSuggestion for semantics.
pub fn permSuggestion(call_name: []const u8, args_json: []const u8, arena: std.mem.Allocator) ?[]const u8 {
    if (std.mem.eql(u8, call_name, "bash")) {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch return null;
        if (parsed != .object) return null;
        const cmd = parsed.object.get("command") orelse return null;
        if (cmd != .string) return null;
        return bashPermSuggestion(cmd.string, arena);
    }
    if (std.mem.eql(u8, call_name, "mcp")) {
        const q = tools_mod.callSubjects(call_name, args_json, arena);
        if (q.len != 1 or q[0].len == 0) return null;
        return std.fmt.allocPrint(arena, "Mcp({s}) allow", .{q[0]}) catch null;
    }
    if (std.mem.eql(u8, call_name, "batch")) {
        const paths = tools_mod.callTouchedPaths(call_name, args_json, arena);
        if (paths.len == 1 and paths[0].len > 0) {
            return std.fmt.allocPrint(arena, "batch({s}) allow", .{paths[0]}) catch null;
        }
        return null;
    }
    const paths = tools_mod.callTouchedPaths(call_name, args_json, arena);
    if (paths.len == 1 and paths[0].len > 0) {
        return std.fmt.allocPrint(arena, "{s}({s}) allow", .{ call_name, paths[0] }) catch null;
    }
    return null;
}

pub fn bashPermSuggestion(command: []const u8, arena: std.mem.Allocator) ?[]const u8 {
    const words = commandWords(command, arena);
    if (words.len == 0) return null;
    const first = words[0];
    if (isDangerousInterpreter(first)) {
        return scopedInterpreterSuggestion(words, arena);
    }
    return std.fmt.allocPrint(arena, "Bash({s} *) allow", .{first}) catch null;
}

pub fn isDangerousInterpreter(word: []const u8) bool {
    for (permrules.dangerous_patterns) |dp| {
        if (std.ascii.eqlIgnoreCase(word, dp)) return true;
    }
    return false;
}

pub fn scopedInterpreterSuggestion(words: []const []const u8, arena: std.mem.Allocator) ?[]const u8 {
    if (words.len == 0) return null;
    const first = words[0];
    var i: usize = 1;
    while (i < words.len) : (i += 1) {
        const w = words[i];
        if (isInlineCodeFlag(w)) return null;
        if (std.mem.eql(u8, w, "-m") and i + 1 < words.len) {
            return std.fmt.allocPrint(arena, "Bash({s} -m {s} *) allow", .{ first, words[i + 1] }) catch null;
        }
        if (w.len > 0 and w[0] == '-') continue;
        break;
    }
    if (i >= words.len) return null;
    return std.fmt.allocPrint(arena, "Bash({s} {s} *) allow", .{ first, words[i] }) catch null;
}

pub fn isInlineCodeFlag(w: []const u8) bool {
    return std.mem.eql(u8, w, "-c") or std.mem.eql(u8, w, "-e") or
        std.mem.eql(u8, w, "--eval") or std.mem.eql(u8, w, "--execute") or
        std.mem.eql(u8, w, "-command") or std.mem.eql(u8, w, "/c") or std.mem.eql(u8, w, "/C");
}

pub fn commandWords(command: []const u8, arena: std.mem.Allocator) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < command.len) {
        while (i < command.len and (command[i] == ' ' or command[i] == '\t')) i += 1;
        if (i >= command.len) break;
        const start = i;
        var quote: u8 = 0;
        while (i < command.len) : (i += 1) {
            const c = command[i];
            if (quote != 0) {
                if (c == quote) quote = 0;
                continue;
            }
            if (c == '"' or c == '\'') {
                quote = c;
                continue;
            }
            if (c == '\\') {
                i += 1;
                continue;
            }
            if (c == ' ' or c == '\t') break;
        }
        var word = command[start..i];
        if (word.len >= 2 and (word[0] == '"' or word[0] == '\'') and word[word.len - 1] == word[0]) {
            word = word[1 .. word.len - 1];
        }
        if (word.len > 0) out.append(arena, word) catch return out.items;
    }
    return out.items;
}

pub fn firstWord(command: []const u8) []const u8 {
    var i: usize = 0;
    while (i < command.len and (command[i] == ' ' or command[i] == '\t')) i += 1;
    const start = i;
    while (i < command.len and command[i] != ' ' and command[i] != '\t') i += 1;
    return command[start..i];
}

/// Args JSON with `"sandbox":true` injected (user dialog choice wins).
pub fn withSandboxArg(arena: std.mem.Allocator, args_json: []const u8) []const u8 {
    if (std.mem.indexOf(u8, args_json, "\"sandbox\"")) |_| {
        const needles = [_]struct { from: []const u8, to: []const u8 }{
            .{ .from = "\"sandbox\":false", .to = "\"sandbox\":true" },
            .{ .from = "\"sandbox\": false", .to = "\"sandbox\": true" },
            .{ .from = "\"sandbox\" : false", .to = "\"sandbox\" : true" },
            .{ .from = "\"sandbox\" :false", .to = "\"sandbox\" :true" },
        };
        var out: []const u8 = args_json;
        for (needles) |n| {
            if (std.mem.indexOf(u8, out, n.from)) |_| {
                out = replaceAll(arena, out, n.from, n.to) catch out;
            }
        }
        return out;
    }
    const trimmed = std.mem.trim(u8, args_json, " \t\r\n");
    if (trimmed.len >= 2 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}') {
        const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n");
        if (inner.len == 0) return "{\"sandbox\":true}";
        return std.fmt.allocPrint(arena, "{s},\"sandbox\":true}}", .{trimmed[0 .. trimmed.len - 1]}) catch args_json;
    }
    return args_json;
}

fn replaceAll(arena: std.mem.Allocator, input: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
    if (needle.len == 0) return input;
    const count = std.mem.count(u8, input, needle);
    if (count == 0) return input;
    const out_len = input.len - count * needle.len + count * replacement.len;
    var buf = try arena.alloc(u8, out_len);
    var i: usize = 0;
    var o: usize = 0;
    while (i < input.len) {
        if (std.mem.startsWith(u8, input[i..], needle)) {
            @memcpy(buf[o..][0..replacement.len], replacement);
            o += replacement.len;
            i += needle.len;
        } else {
            buf[o] = input[i];
            o += 1;
            i += 1;
        }
    }
    return buf[0..o];
}

test "withSandboxArg injects and forces true" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const injected = withSandboxArg(a, "{\"command\":\"echo hi\"}");
    try std.testing.expect(std.mem.indexOf(u8, injected, "\"sandbox\":true") != null);
    const forced = withSandboxArg(a, "{\"command\":\"echo hi\",\"sandbox\":false}");
    try std.testing.expect(std.mem.indexOf(u8, forced, "\"sandbox\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, forced, "\"sandbox\":false") == null);
}

test "bash perm suggestion scopes dangerous interpreters" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const git = bashPermSuggestion("git status", a).?;
    try std.testing.expectEqualStrings("Bash(git *) allow", git);
    try std.testing.expect(bashPermSuggestion("python -c 'print(1)'", a) == null);
}

test "formatRuleDenyMessage" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const msg = formatRuleDenyMessage("Bash(rm *) deny", "project", a);
    try std.testing.expect(std.mem.indexOf(u8, msg, "Bash(rm *) deny") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "project") != null);
}

/// Whether to offer sandboxed execution for a flagged bash command in the dialog.
pub fn shouldOfferSandbox(is_bash: bool, command: []const u8, flagged: bool, sandbox_available: bool) bool {
    _ = command;
    return is_bash and flagged and sandbox_available;
}

pub fn formatRiskyPathDetail(path: []const u8, why: []const u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "{s} is not a place this tool writes: {s}",
        .{ path, if (why.len > 0) why else "it is protected" },
    ) catch path;
}
