//! Prompt command substitution for Phase 31: `` !`cmd` `` and fenced `!…` blocks.
//!
//! Commands embedded in prompt templates are executed and their output is
//! substituted inline. This gives slash commands (e.g. `/commit`, `/pr`) verified
//! context without an extra round trip.
//!
//! ## Safety / correctness
//!
//! - Every substituted command is permission-checked and classified with
//!   `cmdsafety` before execution (even when the user invoked the command that
//!   contains it).
//! - Substitution builds the result by appending slices (never string replace),
//!   so shell output containing `$&`, `$$`, `` $` ``, `$'` is preserved verbatim.
//! - Failure is loud and named: `Shell command failed for pattern "<cmd>": …`.
//!   A failed substitution never becomes a silent empty string.
//! - Interactive/TTY-only commands (e.g. `git rebase -i`) are refused via
//!   `cmdsafety`'s `forbidden` verdict.
//!
//! ## Syntax
//!
//! - Inline: `` !`command` `` (command inside backticks, prefixed by `!`).
//! - Fenced block: a markdown fence whose info string is exactly `!`:
//!   ```!
//!   command
//!   ```
//!   The block's trimmed content is executed as a single command.
//!
//! ## Vocabulary bridge (external spec ↔ internal)
//!
//! External specs / TASKS prose may phrase bash allowlists as `Bash(git add:*)`,
//! `git status:*`, or other agents' "always-allow command rules"
//! (e.g. `alwaysAllowRules.command`). Internal zode form is a turn-scoped
//! `allow_rules` slice of `Bash(...)` command-prefix patterns, typically
//! `Bash(git add *)` (space-star). `matchesAllowRules` normalizes `:*` → prefix
//! match for spec compatibility. These are NOT persisted `permrules.Rule`
//! entries; they are an implicit allow for the current substitution/turn only.

const std = @import("std");
const cmdsafety = @import("cmdsafety.zig");

pub const max_output_bytes: usize = 64 * 1024;

pub const Error = error{
    PermissionDenied,
    CommandFailed,
    Forbidden,
    OutOfMemory,
};

/// Permission decision for a command substitution.
pub const Permission = enum {
    allow,
    deny,
};

pub const Ctx = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    /// cwd for the command; null uses the process cwd.
    cwd: ?[]const u8 = null,
    /// Optional allowlist override for this substitution pass (Phase 31.2).
    /// When set, a command whose first-token-prefix matches one of these rules
    /// is allowed without consulting `permission`. Rules are zode-style
    /// `Bash(...)` patterns interpreted as command-prefix allows
    /// (e.g. `Bash(git status *)`, `Bash(git add *)`).
    allow_rules: []const []const u8 = &.{},
    /// Called when no allow rule matches. Must not block indefinitely in tests;
    /// production wiring may consult the permission system.
    permission: *const fn (ctx: *const Ctx, command: []const u8) Permission = denyAll,
    userdata: ?*anyopaque = null,
};

fn denyAll(_: *const Ctx, _: []const u8) Permission {
    return .deny;
}

/// Expands command substitutions in `text`. Returns a newly allocated slice in
/// `ctx.arena` (or `text` unchanged when there are no substitutions).
/// On the first failure, returns `error.CommandFailed` with the formatted
/// reason available via `lastErrorMessage`? (callers can format from the error
/// context they control; this API returns a composed error text in `err_out`).
pub fn expand(text: []const u8, ctx: *const Ctx, err_out: *?[]const u8) Error![]const u8 {
    err_out.* = null;
    if (!hasSubstitution(text)) return text;

    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var last: usize = 0;
    var changed = false;

    while (i < text.len) {
        // Fenced `!` block: ```!\n...\n```
        if (startsFenceBang(text, i)) {
            if (findFenceEnd(text, i)) |fe| {
                const inner_start = fenceInnerStart(text, i);
                const inner_end = fe.content_end;
                const cmd = std.mem.trim(u8, text[inner_start..inner_end], " \t\r\n");
                if (cmd.len > 0) {
                    try out.appendSlice(ctx.arena, text[last..i]);
                    changed = true;
                    const result = runOne(cmd, ctx) catch |err| {
                        err_out.* = failMessage(ctx.arena, cmd, err);
                        return error.CommandFailed;
                    };
                    try out.appendSlice(ctx.arena, result);
                    last = fe.after;
                    i = fe.after;
                    continue;
                }
            }
        }

        // Inline `` !`cmd` `` (single-backtick command after `!`)
        if (text[i] == '!' and i + 1 < text.len and text[i + 1] == '`') {
            if (findInlineEnd(text, i + 2)) |end| {
                const cmd = text[i + 2 .. end];
                try out.appendSlice(ctx.arena, text[last..i]);
                changed = true;
                const result = runOne(cmd, ctx) catch |err| {
                    err_out.* = failMessage(ctx.arena, cmd, err);
                    return error.CommandFailed;
                };
                try out.appendSlice(ctx.arena, result);
                last = end + 1; // skip closing backtick
                i = last;
                continue;
            }
        }
        i += 1;
    }

    if (!changed) return text;
    if (last < text.len) try out.appendSlice(ctx.arena, text[last..]);
    return out.items;
}

pub fn hasSubstitution(text: []const u8) bool {
    // Inline
    if (std.mem.indexOf(u8, text, "!`") != null) return true;
    // Fenced ```!
    if (std.mem.indexOf(u8, text, "```!") != null) return true;
    return false;
}

fn startsFenceBang(text: []const u8, i: usize) bool {
    if (i + 4 > text.len) return false;
    if (!std.mem.eql(u8, text[i .. i + 4], "```!")) return false;
    // Must be at line start (or start of text)
    return i == 0 or text[i - 1] == '\n';
}

const FenceEnd = struct { content_end: usize, after: usize };

fn fenceInnerStart(text: []const u8, fence_start: usize) usize {
    var i = fence_start + 4; // after ```!
    // skip rest of info line
    while (i < text.len and text[i] != '\n') i += 1;
    if (i < text.len) i += 1; // skip \n
    return i;
}

fn findFenceEnd(text: []const u8, fence_start: usize) ?FenceEnd {
    const inner = fenceInnerStart(text, fence_start);
    var i = inner;
    while (i < text.len) {
        if (text[i] == '`' and i + 2 < text.len and text[i + 1] == '`' and text[i + 2] == '`') {
            // closing fence at line start
            if (i == 0 or text[i - 1] == '\n') {
                var after = i + 3;
                while (after < text.len and text[after] != '\n') after += 1;
                // Do not consume the newline after the closing fence: keep
                // surrounding text structure intact.
                // content ends before the closing fence line
                var content_end = i;
                if (content_end > inner and text[content_end - 1] == '\n') content_end -= 1;
                return .{ .content_end = content_end, .after = after };
            }
        }
        i += 1;
    }
    return null;
}

fn findInlineEnd(text: []const u8, start: usize) ?usize {
    // Single backtick terminator; do not cross newlines in the simple form
    // (keeps parsing predictable). Commands needing backticks/newlines should
    // use a fenced `!` block.
    var i = start;
    while (i < text.len) : (i += 1) {
        if (text[i] == '`') return i;
        if (text[i] == '\n') return null;
    }
    return null;
}

pub fn runOne(command: []const u8, ctx: *const Ctx) Error![]const u8 {
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    if (trimmed.len == 0) return "";

    // Safety classification first: forbidden commands are refused even if a
    // permissive allowlist/rule would match (31.1: permission-checked; 31.3:
    // never -i / interactive TTY hangs).
    const verdict = cmdsafety.classify(trimmed, ctx.arena);
    if (verdict.verdict == .forbidden) {
        return error.Forbidden;
    }

    if (!isAllowed(trimmed, ctx)) return error.PermissionDenied;

    const argv = [_][]const u8{ "sh", "-c", trimmed };
    var run_opts: std.process.RunOptions = .{
        .argv = &argv,
        .stdout_limit = .limited(max_output_bytes),
        .stderr_limit = .limited(max_output_bytes),
    };
    if (ctx.cwd) |cwd_path| run_opts.cwd = .{ .path = cwd_path };
    const result = std.process.run(ctx.arena, ctx.io, run_opts) catch return error.CommandFailed;

    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) return error.CommandFailed;

    // Prefer stdout; if empty, fall back to stderr (some git commands report there).
    const out = std.mem.trimEnd(u8, result.stdout, " \t\r\n");
    if (out.len > 0) return out;
    return std.mem.trimEnd(u8, result.stderr, " \t\r\n");
}

fn isAllowed(command: []const u8, ctx: *const Ctx) bool {
    if (matchesAllowRules(command, ctx.allow_rules)) return true;
    return ctx.permission(ctx, command) == .allow;
}

/// Matches zode-style `Bash(...)` allow patterns against `command`.
/// Supports glob-like `*` at end (e.g. `Bash(git status *)`, `Bash(git *)`)
/// and `:*` suffix used in TASKS phrasing (treated as ` *` / prefix).
pub fn matchesAllowRules(command: []const u8, rules: []const []const u8) bool {
    const cmd = std.mem.trim(u8, command, " \t\r\n");
    for (rules) |rule| {
        if (matchesAllowRule(cmd, rule)) return true;
    }
    return false;
}

fn matchesAllowRule(command: []const u8, rule: []const u8) bool {
    // Extract inner pattern from `Bash(...)` or accept raw pattern.
    var pat = std.mem.trim(u8, rule, " \t\r\n");
    if (std.ascii.startsWithIgnoreCase(pat, "Bash(") and pat.len > 0 and pat[pat.len - 1] == ')') {
        pat = pat[5 .. pat.len - 1];
    }
    pat = std.mem.trim(u8, pat, " \t");

    // Normalize TASKS-style `:*` to ` *` prefix matching.
    if (std.mem.endsWith(u8, pat, ":*")) {
        const prefix = std.mem.trimEnd(u8, pat[0 .. pat.len - 2], " \t");
        return prefixMatchesCommand(command, prefix);
    }
    if (std.mem.endsWith(u8, pat, " *")) {
        const prefix = pat[0 .. pat.len - 2];
        return prefixMatchesCommand(command, prefix);
    }
    if (std.mem.eql(u8, pat, "*")) return true;
    // Exact match
    return std.mem.eql(u8, command, pat);
}

fn prefixMatchesCommand(command: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, command, prefix)) return false;
    if (command.len == prefix.len) return true;
    const c = command[prefix.len];
    return c == ' ' or c == '\t';
}

pub fn failMessage(arena: std.mem.Allocator, command: []const u8, err: Error) []const u8 {
    const reason: []const u8 = switch (err) {
        error.PermissionDenied => "permission denied",
        error.Forbidden => "refused: interactive/TTY-only command is not allowed in a non-interactive harness",
        error.CommandFailed => "command exited with an error",
        error.OutOfMemory => "out of memory",
    };
    return std.fmt.allocPrint(
        arena,
        "Shell command failed for pattern \"{s}\": {s}",
        .{ command, reason },
    ) catch "Shell command failed for pattern: (error formatting failure message)";
}

// ── tests ─────────────────────────────────────────────────────────────────

fn allowAll(_: *const Ctx, _: []const u8) Permission {
    return .allow;
}

fn testCtx(arena: std.mem.Allocator, perm: *const fn (*const Ctx, []const u8) Permission, rules: []const []const u8) Ctx {
    return .{
        .io = std.testing.io,
        .arena = arena,
        .allow_rules = rules,
        .permission = perm,
    };
}

test "cmdsubst: no substitution returns text unchanged (same pointer)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ctx = testCtx(arena_state.allocator(), allowAll, &.{});
    var err_out: ?[]const u8 = null;
    const text = "plain prompt with no commands";
    const got = try expand(text, &ctx, &err_out);
    try std.testing.expect(got.ptr == text.ptr);
}

test "cmdsubst: inline substitution runs and preserves dollar sequences" {
    // Use a command that prints literal $ sequences; build-by-append preserves them.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ctx = testCtx(arena_state.allocator(), allowAll, &.{});
    var err_out: ?[]const u8 = null;
    const text = "before !`printf '$$ $&'` after";
    const got = try expand(text, &ctx, &err_out);
    try std.testing.expect(err_out == null);
    try std.testing.expectEqualStrings("before $$ $& after", got);
}

test "cmdsubst: permission denied is loud and named" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ctx = testCtx(arena_state.allocator(), denyAll, &.{});
    var err_out: ?[]const u8 = null;
    try std.testing.expectError(error.CommandFailed, expand("x !`git status` y", &ctx, &err_out));
    const msg = err_out.?;
    try std.testing.expect(std.mem.indexOf(u8, msg, "Shell command failed for pattern") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "git status") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "permission denied") != null);
    // Never a silent empty substitution in the message/result contract.
    try std.testing.expect(msg.len > 0);
}

test "cmdsubst: command failure is loud and named" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ctx = testCtx(arena_state.allocator(), allowAll, &.{});
    var err_out: ?[]const u8 = null;
    // `false` exits 1 on POSIX.
    try std.testing.expectError(error.CommandFailed, expand("!`false`", &ctx, &err_out));
    const msg = err_out.?;
    try std.testing.expect(std.mem.indexOf(u8, msg, "Shell command failed for pattern") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "false") != null);
}

test "cmdsubst: fenced ! block substitution" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ctx = testCtx(arena_state.allocator(), allowAll, &.{});
    var err_out: ?[]const u8 = null;
    // `printf` emits no trailing newline; the fence is replaced inline and the
    // newline after the closing fence is preserved.
    const text = "pre\n```!\nprintf fenced-ok\n```\npost";
    const got = try expand(text, &ctx, &err_out);
    try std.testing.expectEqualStrings("pre\nfenced-ok\npost", got);
}

test "cmdsubst: allow_rules permit matching commands without permission callback" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rules = [_][]const u8{ "Bash(git status *)", "Bash(git diff *)" };
    const ctx = testCtx(arena_state.allocator(), denyAll, &rules);
    var err_out: ?[]const u8 = null;
    const got = try expand("!`git status --short 2>/dev/null || true`", &ctx, &err_out);
    _ = got;
    // Should not fail with permission denied (command itself may vary in empty repo,
    // but the `|| true` keeps exit 0).
    try std.testing.expect(err_out == null);
}

test "cmdsubst: allow_rules TASKS-style :* suffix" {
    try std.testing.expect(matchesAllowRules("git add -A", &.{"Bash(git add:*)"}));
    try std.testing.expect(matchesAllowRules("git status", &.{"Bash(git status:*)"}));
    try std.testing.expect(!matchesAllowRules("git push", &.{"Bash(git add:*)"}));
}

test "cmdsubst: forbidden interactive command refused (rebase -i)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ctx = testCtx(arena_state.allocator(), allowAll, &.{"Bash(git *)"});
    var err_out: ?[]const u8 = null;
    try std.testing.expectError(error.CommandFailed, expand("!`git rebase -i HEAD~1`", &ctx, &err_out));
    const msg = err_out.?;
    try std.testing.expect(std.mem.indexOf(u8, msg, "Shell command failed for pattern") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "interactive") != null or std.mem.indexOf(u8, msg, "TTY") != null);
}

test "cmdsubst: allowlist asymmetry — commit rules do not allow push" {
    const commit_rules = [_][]const u8{
        "Bash(git add *)",
        "Bash(git status *)",
        "Bash(git diff *)",
        "Bash(git log *)",
        "Bash(git commit *)",
    };
    try std.testing.expect(matchesAllowRules("git add -A", &commit_rules));
    try std.testing.expect(matchesAllowRules("git status --short", &commit_rules));
    try std.testing.expect(matchesAllowRules("git commit -m x", &commit_rules));
    try std.testing.expect(!matchesAllowRules("git push origin main", &commit_rules));
    try std.testing.expect(!matchesAllowRules("gh pr create", &commit_rules));
    try std.testing.expect(!matchesAllowRules("git checkout -b feat", &commit_rules));
}

test "cmdsubst: allowlist asymmetry — PR/push rules include push and gh pr" {
    const pr_rules = [_][]const u8{
        "Bash(git add *)",
        "Bash(git status *)",
        "Bash(git diff *)",
        "Bash(git log *)",
        "Bash(git commit *)",
        "Bash(git checkout *)",
        "Bash(git push *)",
        "Bash(git rev-parse *)",
        "Bash(git branch *)",
        "Bash(git merge-base *)",
        "Bash(git remote *)",
        "Bash(gh pr *)",
    };
    try std.testing.expect(matchesAllowRules("git checkout -b user/feat", &pr_rules));
    try std.testing.expect(matchesAllowRules("git push -u origin user/feat", &pr_rules));
    try std.testing.expect(matchesAllowRules("gh pr create --title t", &pr_rules));
    try std.testing.expect(matchesAllowRules("gh pr view --json number 2>/dev/null || true", &pr_rules));
    // Still safe: not arbitrary shell
    try std.testing.expect(!matchesAllowRules("curl http://evil", &pr_rules));
}