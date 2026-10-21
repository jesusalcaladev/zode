//! What a path is ALLOWED to be, and what it must never be.
//!
//! ## Why this module exists
//!
//! Upstream (Claude Code) has a path layer that zode does not have at all:
//! writes are refused inside `.git/`, `.claude/`, `.vscode/`, `.idea/` and the
//! shell configs, and reads are constrained to the working directory. The
//! upstream lists are in `utils/permissions/filesystem.ts` (`DANGEROUS_FILES`,
//! `DANGEROUS_DIRECTORIES`) and `utils/permissions/pathValidation.ts`
//! (`validatePath`).
//!
//! In zode the gap is not theoretical. `read` is `read_only = true`, so it
//! NEVER asks: the model can read `~/.config/zode/auth.json` (the provider
//! key), `~/.ssh/id_rsa` or `~/.aws/credentials` and send them to a third
//! party, with nothing on screen. And `write` asks a generic question — "may I
//! write X?" — which a `.git/hooks/pre-commit` passes under a `description`
//! the user does not read carefully. A file that runs on every commit is not
//! a file.
//!
//! ## The rules, and why each one is a rule
//!
//! 1. **By SEGMENT, never by prefix.** `a/b/.git/hooks/x` is as much a git
//!    hook as `.git/hooks/x`, and a prefix test misses it. The other way
//!    round: `zig-out-mine` is not `zig-out`, and `myproject.git` is not
//!    `.git`.
//! 2. **Case-insensitively.** `.Git/hooks/x` works on a case-insensitive
//!    filesystem (macOS, Windows), so a case-sensitive comparison is a
//!    bypass there.
//! 3. **A refusal NAMES the risk.** "this is a git hook, it runs on every
//!    commit" tells the user what they are approving; "path not allowed" does
//!    not.
//! 4. **The escape hatch is `bash`, which asks.** The dedicated tool refuses;
//!    the shell goes through the permission dialog. A rule that cannot be
//!    worked around is a rule the user cannot use; a rule with a visible,
//!    permission-checked way around it is a rule the user controls.
//!
//! It is pure: no filesystem, no terminal, no network. Everything here is a
//! question about a STRING, which is what makes it testable without a TUI.

const std = @import("std");

/// The directory names that are never written into, and why.
///
/// The order is the order of how much damage the write does.
pub const dangerous_dirs = [_]struct { name: []const u8, why: []const u8 }{
    .{ .name = ".git", .why = "it is the repository itself: a hook there runs on every commit, and a file in `refs/` or `hooks/` changes what git does" },
    .{ .name = ".claude", .why = "it holds the settings that decide what this harness is allowed to do" },
    .{ .name = ".vscode", .why = "it holds editor settings that run code when a folder is opened" },
    .{ .name = ".idea", .why = "it holds editor settings that run code when a folder is opened" },
    .{ .name = ".zsh", .why = "it is a shell configuration directory: something there runs on every shell" },
    .{ .name = ".ssh", .why = "it holds private keys" },
    .{ .name = ".gnupg", .why = "it holds private keys" },
    .{ .name = ".aws", .why = "it holds cloud credentials" },
};

/// The file names that are never written into, and why.
pub const dangerous_files = [_]struct { name: []const u8, why: []const u8 }{
    .{ .name = ".gitconfig", .why = "it decides what git runs: `core.pager`, `core.fsmonitor` and `core.hooksPath` are all code execution" },
    .{ .name = ".gitmodules", .why = "it makes a clone run commands from another repository" },
    .{ .name = ".bashrc", .why = "it runs on every bash shell" },
    .{ .name = ".bash_profile", .why = "it runs on every login shell" },
    .{ .name = ".zshrc", .why = "it runs on every zsh shell" },
    .{ .name = ".zprofile", .why = "it runs on every login shell" },
    .{ .name = ".profile", .why = "it runs on every login shell" },
    .{ .name = ".ripgreprc", .why = "it decides how every search in this machine is run, and it can carry a `--pre` command" },
    .{ .name = ".mcp.json", .why = "it decides which servers this harness talks to" },
    .{ .name = ".claude.json", .why = "it holds the harness's own settings" },
};

/// The file names whose CONTENT is a secret.
///
/// A separate table from `dangerous_files` on purpose: reading `.gitconfig` is
/// harmless (it is a text file of settings), and reading `auth.json` puts the
/// provider key in a request to a third party. One table for both would refuse
/// a harmless read, and a rule that gets in the way is a rule that gets turned
/// off — and turning it off takes the real ones with it.
pub const secret_files = [_][]const u8{
    "auth.json",
    ".netrc",
    ".npmrc",
    ".pypirc",
    ".htpasswd",
};

/// The extensions that are a private key or a certificate.
const secret_extensions = [_][]const u8{ ".pem", ".key", ".p12", ".pfx", ".jks", ".keystore", ".ppk" };

/// What is wrong with a path, when something is.
pub const Verdict = union(enum) {
    /// The path is fine.
    ok,
    /// The path names a place that must not be written into.
    ///
    /// `what` is the file or directory name that matched, and `why` says what
    /// writing there would DO — not "it is forbidden".
    dangerous: struct { what: []const u8, why: []const u8 },
    /// The path names a file that holds a secret, and reading it would put
    /// that secret in a request to a provider.
    secret: struct { what: []const u8 },
};

/// The last segment of a path, with the trailing slash removed.
fn baseName(path: []const u8) []const u8 {
    var p = path;
    while (p.len > 1 and p[p.len - 1] == '/') p = p[0 .. p.len - 1];
    const slash = std.mem.lastIndexOfScalar(u8, p, '/') orelse return p;
    return p[slash + 1 ..];
}

/// Every segment of a path, without the empty ones.
fn segments(path: []const u8, arena: std.mem.Allocator, out: *std.ArrayList([]const u8)) void {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        out.append(arena, seg) catch return;
    }
}

/// Case-insensitive equality, ASCII only.
fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// Whether writing to `path` is refused, and why.
///
/// The answer is a VERDICT and not a bool, because the caller has to write a
/// sentence and a sentence needs the reason. "this is a git hook: it runs on
/// every commit" is a sentence the user can act on.
pub fn checkWrite(path: []const u8) Verdict {
    if (path.len == 0) return .ok;

    const base = baseName(path);

    // The FILE names first: `.gitconfig` is a file and `.git` is a directory,
    // and a path can carry both (`a/.git/config`).
    for (dangerous_files) |f| {
        if (eqIgnoreCase(base, f.name)) {
            return .{ .dangerous = .{ .what = f.name, .why = f.why } };
        }
    }

    var segs: std.ArrayList([]const u8) = .empty;
    defer segs.deinit(std.heap.page_allocator);
    segments(path, std.heap.page_allocator, &segs);
    for (segs.items) |seg| {
        for (dangerous_dirs) |d| {
            if (eqIgnoreCase(seg, d.name)) {
                return .{ .dangerous = .{ .what = d.name, .why = d.why } };
            }
        }
    }

    return .ok;
}

/// Whether READING `path` would put a secret in the request.
///
/// The list is deliberately short and unambiguous: a private key, a
/// credentials file. A `.env` inside the project is NOT here: it is a project
/// file that the user may well want the agent to look at, and refusing it
/// would be a rule that gets turned off.
pub fn checkRead(path: []const u8) Verdict {
    const base = baseName(path);
    for (secret_files) |f| {
        if (eqIgnoreCase(base, f)) {
            return .{ .secret = .{ .what = f } };
        }
    }
    for (secret_extensions) |ext| {
        if (std.mem.endsWith(u8, base, ext)) {
            return .{ .secret = .{ .what = base } };
        }
    }
    // `id_rsa`, `id_ed25519`, and anything that starts with `id_`.
    if (std.mem.startsWith(u8, base, "id_")) return .{ .secret = .{ .what = base } };
    return .ok;
}

/// The sentence the model reads when a write is refused.
///
/// It names the file, says what writing there WOULD DO, and says where the
/// escape hatch is. A refusal without a way forward is a wall, and the model
/// answers a wall by trying the next tool until one works.
pub fn refusalText(arena: std.mem.Allocator, v: Verdict) []const u8 {
    switch (v) {
        .ok => return "ok",
        .dangerous => |d| return std.fmt.allocPrint(
            arena,
            "refused: `{s}` is not a place this tool writes. {s}. If the user really wants it, say so and they can do it themselves — `bash` runs with their approval.",
            .{ d.what, d.why },
        ) catch "refused: that path is not writable by this tool.",
        .secret => |s| return std.fmt.allocPrint(
            arena,
            "refused: `{s}` holds credentials, and reading it would put them in a request to the model provider. The user can read it themselves, or copy the part that matters into the conversation.",
            .{s.what},
        ) catch "refused: that file holds credentials.",
    }
}

// ── tests ──────────────────────────────────────────────────────────────────────
//
// The table is the product, so the table is what is tested: every dangerous
// name is refused, and the look-alikes are NOT. A test that only checks the
// happy path proves that the list is empty.

const t = std.testing;

test "pathsafe: the dangerous directories are refused, by SEGMENT" {
    const cases = [_][]const u8{
        ".git/config",
        "a/b/.git/hooks/pre-commit",
        "src/.git/config",
        "proj/.claude/settings.json",
        "proj/.vscode/tasks.json",
        "proj/.idea/workspace.xml",
    };
    for (cases) |p| {
        const v = checkWrite(p);
        switch (v) {
            .dangerous => {},
            else => {
                std.debug.print("not refused: {s}\n", .{p});
                return error.TestUnexpectedResult;
            },
        }
    }
}

test "pathsafe: a look-alike is NOT refused" {
    // The other direction of the segment rule: `myproject.git` is a project,
    // `zig-out-mine` is a build directory that is not `zig-out`, and
    // `.gitignore` is a file every repository has.
    for ([_][]const u8{ "myproject.git/README.md", "zig-out-mine/x", ".gitignore", "src/git.zig", "docs/.gitbook.yaml" }) |p| {
        try t.expect(checkWrite(p) == .ok);
    }
}

test "pathsafe: the dangerous FILES are refused" {
    for ([_][]const u8{ ".gitconfig", "/home/u/.gitconfig", ".bashrc", "sub/.zshrc", ".ripgreprc", ".mcp.json" }) |p| {
        const v = checkWrite(p);
        switch (v) {
            .dangerous => {},
            else => {
                std.debug.print("not refused: {s}\n", .{p});
                return error.TestUnexpectedResult;
            },
        }
    }
}

test "pathsafe: the match does not care about the case" {
    // On a case-insensitive filesystem `.Git/hooks/x` IS `.git/hooks/x`.
    const v = checkWrite(".Git/hooks/pre-commit");
    switch (v) {
        .dangerous => {},
        else => return error.TestUnexpectedResult,
    }
    const w = checkWrite(".BASHRC");
    switch (w) {
        .dangerous => {},
        else => return error.TestUnexpectedResult,
    }
}

test "pathsafe: a private key is not readable" {
    for ([_][]const u8{ "/home/u/.ssh/id_rsa", "id_ed25519", "cert.pem", "key.p12", ".netrc" }) |p| {
        const v = checkRead(p);
        switch (v) {
            .secret => {},
            else => {
                std.debug.print("readable: {s}\n", .{p});
                return error.TestUnexpectedResult;
            },
        }
    }
    // And an ordinary project file is.
    for ([_][]const u8{ "src/main.zig", ".env.example", "README.md", "src/keys.zig" }) |p| {
        try t.expect(checkRead(p) == .ok);
    }
}

test "pathsafe: the refusal text names the file and the way out" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = refusalText(arena, checkWrite(".git/hooks/pre-commit"));
    try t.expect(std.mem.indexOf(u8, text, "refused") != null);
    try t.expect(std.mem.indexOf(u8, text, "bash") != null);
}
