//! `lib/cmdsafety.zig`: what a shell command DOES.
//!
//! Pure on purpose: a command is a string and a table, and every decision
//! about it can be tested with no shell and no filesystem.
//!
//! ## The rule
//!
//! **The classifier is DATA and not a heuristic.** A command family is a row,
//! and the flags that change what a subcommand does are part of the row:
//! `git status` is quiet and `git clean -fdx` is not, and the difference is
//! a table entry and not a guess.
//!
//! ## The direction of the failure
//!
//! **UNKNOWN is not read-only.** A command we do not know is a command we
//! ask about, because the cost of asking is one dialog and the cost of
//! guessing wrong is a file the user did not want touched.
//!
//! ## The parts of a command
//!
//! A shell command is not one command: `a && b | c` is three, and the
//! verdict is the WORST of the three. The splitter knows about the
//! separators (`|`, `||`, `&&`, `;`, `&`), the redirections (`>`, `>>`) and
//! the substitutions (`$(…)`, backticks), and it does not split inside
//! quotes.

const std = @import("std");

/// What a command does.
pub const Verdict = enum {
    /// It only reads. Nothing on disk changes.
    read_only,
    /// It changes files.
    writes,
    /// It removes things.
    deletes,
    /// It runs another program: a shell, an interpreter, a downloader.
    executes,
    /// We do not know this command.
    unknown,

    pub fn name(self: Verdict) []const u8 {
        return @tagName(self);
    }
};

/// The verdict and the fragment that produced it.
pub const Finding = struct {
    verdict: Verdict,
    /// The exact part of the command that decided it.
    fragment: []const u8,
    /// What it does, IN WORDS: "this deletes unreferenced files" beats
    /// `git clean -fdx`.
    why: []const u8 = "",
};

/// A command family: the program and what its subcommands do.
const Entry = struct {
    program: []const u8,
    /// The subcommand, or "" for the program alone.
    sub: []const u8,
    verdict: Verdict,
    /// The flags that change the verdict.
    ///
    /// `git log` is quiet and `git log --output=x` is not, and the difference
    /// is a row and not a guess.
    danger_flags: []const []const u8 = &.{},
    /// The flags that make it READ, when it would otherwise write.
    ///
    /// `git config` writes and `git config --get x` reads: one program, two
    /// verbs, and the table has to say which is which.
    read_flags: []const []const u8 = &.{},
    /// What the dangerous flags do, in words.
    why: []const u8 = "",
    /// The subcommand only reads when it has NO positional argument:
    /// `git branch` LISTS and `git branch x` CREATES.
    no_args: bool = false,
};

/// The programs that only read, on their own.
///
/// The list is a list of NAMES and not of paths: `/usr/bin/ls` is `ls`.
const read_only_programs = [_][]const u8{
    "ls",       "cat",     "head",   "tail",  "wc",     "grep",   "egrep",
    "fgrep",    "rg",      "ag",     "find",  "fd",     "tree",   "pwd",
    "echo",     "printf",  "which",  "whereis", "type",  "stat",   "du",
    "df",       "date",    "uname",  "whoami", "hostname", "id",   "groups",
    "printenv", "realpath", "basename", "dirname", "file", "sort", "uniq",
    "cut",      "tr",      "nl",     "comm",  "join",   "paste", "column",
    "tac",      "seq",     "expr",   "test",  "jq",     "yq",     "diff",
    "cmp",      "md5sum",  "sha1sum", "sha256sum", "ps",  "uptime", "free",
    "lscpu",    "lsblk",   "nproc",  "who",   "w",      "last",   "column",
    "getconf",  "locale",  "tty",    "stdbuf",
};

/// The programs that change something.
///
/// They are listed so the answer is a REASON and not a shrug: "this removes
/// files" beats "not read-only".
const write_programs = [_]struct { name: []const u8, verdict: Verdict, why: []const u8 }{
    .{ .name = "rm", .verdict = .deletes, .why = "this removes files" },
    .{ .name = "rmdir", .verdict = .deletes, .why = "this removes directories" },
    .{ .name = "shred", .verdict = .deletes, .why = "this overwrites and removes a file" },
    .{ .name = "mv", .verdict = .writes, .why = "this moves files" },
    .{ .name = "cp", .verdict = .writes, .why = "this copies files" },
    .{ .name = "install", .verdict = .writes, .why = "this writes files" },
    .{ .name = "mkdir", .verdict = .writes, .why = "this creates directories" },
    .{ .name = "touch", .verdict = .writes, .why = "this creates or changes files" },
    .{ .name = "ln", .verdict = .writes, .why = "this creates links" },
    .{ .name = "chmod", .verdict = .writes, .why = "this changes permissions" },
    .{ .name = "chown", .verdict = .writes, .why = "this changes ownership" },
    .{ .name = "chgrp", .verdict = .writes, .why = "this changes the group" },
    .{ .name = "truncate", .verdict = .writes, .why = "this truncates files" },
    .{ .name = "tee", .verdict = .writes, .why = "this writes to files" },
    .{ .name = "dd", .verdict = .writes, .why = "this writes raw blocks" },
    .{ .name = "mktemp", .verdict = .writes, .why = "this creates a file" },
    .{ .name = "make", .verdict = .writes, .why = "this builds, and the build writes" },
    .{ .name = "cmake", .verdict = .writes, .why = "this configures a build" },
    .{ .name = "ninja", .verdict = .writes, .why = "this builds" },
    .{ .name = "gcc", .verdict = .writes, .why = "this compiles" },
    .{ .name = "cc", .verdict = .writes, .why = "this compiles" },
    .{ .name = "clang", .verdict = .writes, .why = "this compiles" },
    .{ .name = "tsc", .verdict = .writes, .why = "this compiles" },
    .{ .name = "cargo", .verdict = .writes, .why = "cargo builds and installs" },
    .{ .name = "go", .verdict = .writes, .why = "go builds and installs" },
    .{ .name = "npm", .verdict = .writes, .why = "npm installs and runs scripts" },
    .{ .name = "npx", .verdict = .writes, .why = "npx runs arbitrary packages" },
    .{ .name = "yarn", .verdict = .writes, .why = "yarn installs and runs scripts" },
    .{ .name = "pnpm", .verdict = .writes, .why = "pnpm installs and runs scripts" },
    .{ .name = "pip", .verdict = .writes, .why = "pip installs" },
    .{ .name = "pip3", .verdict = .writes, .why = "pip installs" },
    .{ .name = "gem", .verdict = .writes, .why = "gem installs" },
    .{ .name = "apt", .verdict = .writes, .why = "apt installs" },
    .{ .name = "apt-get", .verdict = .writes, .why = "apt installs" },
    .{ .name = "brew", .verdict = .writes, .why = "brew installs" },
    .{ .name = "docker", .verdict = .writes, .why = "docker builds and runs containers" },
    .{ .name = "kubectl", .verdict = .writes, .why = "kubectl changes a cluster" },
    .{ .name = "terraform", .verdict = .writes, .why = "terraform changes infrastructure" },
    .{ .name = "ansible", .verdict = .writes, .why = "ansible changes hosts" },
    .{ .name = "systemctl", .verdict = .writes, .why = "systemctl changes services" },
    .{ .name = "service", .verdict = .writes, .why = "service changes services" },
    .{ .name = "launchctl", .verdict = .writes, .why = "launchctl changes services" },
    .{ .name = "crontab", .verdict = .writes, .why = "crontab changes the schedule" },
    .{ .name = "shutdown", .verdict = .writes, .why = "this shuts the machine down" },
    .{ .name = "reboot", .verdict = .writes, .why = "this reboots the machine" },
    .{ .name = "halt", .verdict = .writes, .why = "this halts the machine" },
    .{ .name = "poweroff", .verdict = .writes, .why = "this powers the machine off" },
    .{ .name = "mkfs", .verdict = .deletes, .why = "this formats a filesystem" },
    .{ .name = "fdisk", .verdict = .writes, .why = "this changes the partition table" },
    .{ .name = "passwd", .verdict = .writes, .why = "this changes a password" },
    .{ .name = "useradd", .verdict = .writes, .why = "this changes the users" },
    .{ .name = "usermod", .verdict = .writes, .why = "this changes the users" },
    .{ .name = "userdel", .verdict = .deletes, .why = "this removes a user" },
    .{ .name = "groupadd", .verdict = .writes, .why = "this changes the groups" },
};

/// The programs that RUN another program.
///
/// `curl x | sh` is the shape this table exists for: the downloader reads and
/// the shell executes, and the whole line is a program that was never read.
const execute_programs = [_]struct { name: []const u8, why: []const u8 }{
    .{ .name = "sh", .why = "this runs a shell" },
    .{ .name = "bash", .why = "this runs a shell" },
    .{ .name = "zsh", .why = "this runs a shell" },
    .{ .name = "dash", .why = "this runs a shell" },
    .{ .name = "ksh", .why = "this runs a shell" },
    .{ .name = "csh", .why = "this runs a shell" },
    .{ .name = "fish", .why = "this runs a shell" },
    .{ .name = "eval", .why = "this evaluates a string as a command" },
    .{ .name = "exec", .why = "this replaces the process" },
    .{ .name = "xargs", .why = "this runs the command it is given" },
    .{ .name = "nohup", .why = "this runs a program in the background" },
    .{ .name = "setsid", .why = "this runs a program in a new session" },
    .{ .name = "nice", .why = "this runs a program" },
    .{ .name = "watch", .why = "this runs a program over and over" },
    .{ .name = "script", .why = "this records a session" },
    .{ .name = "sudo", .why = "this runs a program as another user" },
    .{ .name = "su", .why = "this runs a program as another user" },
    .{ .name = "doas", .why = "this runs a program as another user" },
    .{ .name = "curl", .why = "this downloads" },
    .{ .name = "wget", .why = "this downloads" },
};

/// The families: the program, its subcommands and the flags that matter.
const families = [_]Entry{
    // ── git ──
    .{ .program = "git", .sub = "status", .verdict = .read_only },
    .{ .program = "git", .sub = "diff", .verdict = .read_only, .danger_flags = &.{"--output", "-o"}, .why = "this writes the diff to a file" },
    .{ .program = "git", .sub = "log", .verdict = .read_only, .danger_flags = &.{"--output", "-o"}, .why = "this writes the log to a file" },
    .{ .program = "git", .sub = "show", .verdict = .read_only, .danger_flags = &.{"--output", "-o"}, .why = "this writes the output to a file" },
    .{ .program = "git", .sub = "blame", .verdict = .read_only },
    .{ .program = "git", .sub = "ls-files", .verdict = .read_only },
    .{ .program = "git", .sub = "ls-tree", .verdict = .read_only },
    .{ .program = "git", .sub = "rev-parse", .verdict = .read_only },
    .{ .program = "git", .sub = "rev-list", .verdict = .read_only },
    .{ .program = "git", .sub = "describe", .verdict = .read_only },
    .{ .program = "git", .sub = "shortlog", .verdict = .read_only },
    .{ .program = "git", .sub = "whatchanged", .verdict = .read_only },
    .{ .program = "git", .sub = "name-rev", .verdict = .read_only },
    .{ .program = "git", .sub = "count-objects", .verdict = .read_only },
    .{ .program = "git", .sub = "verify-commit", .verdict = .read_only },
    .{ .program = "git", .sub = "show-ref", .verdict = .read_only },
    .{ .program = "git", .sub = "for-each-ref", .verdict = .read_only },
    .{ .program = "git", .sub = "reflog", .verdict = .read_only },
    .{ .program = "git", .sub = "cat-file", .verdict = .read_only },
    .{ .program = "git", .sub = "check-ignore", .verdict = .read_only },
    .{ .program = "git", .sub = "check-attr", .verdict = .read_only },
    .{ .program = "git", .sub = "grep", .verdict = .read_only },
    .{ .program = "git", .sub = "help", .verdict = .read_only },
    .{ .program = "git", .sub = "version", .verdict = .read_only },
    // `git branch` LISTS. `git branch x` CREATES and `git branch -d` DELETES:
    // the verdict depends on the ARGUMENTS, and the table says so.
    .{
        .program = "git",
        .sub = "branch",
        .verdict = .read_only,
        .no_args = true,
        .danger_flags = &.{ "-d", "-D", "-m", "-M", "-c", "-C", "--delete", "--move", "--copy", "--set-upstream-to" },
        .why = "this renames or deletes a branch",
    },
    // `git config` READS with --get/--list and WRITES without: `git config
    // user.name x` sets a value, and the table has to know it.
    .{
        .program = "git",
        .sub = "config",
        .verdict = .read_only,
        .read_flags = &.{ "--get", "--get-all", "--get-regexp", "--list", "-l" },
        .danger_flags = &.{ "--global", "--system", "--local", "--edit", "-e", "--unset", "--add", "--rename-section", "--remove-section" },
        .why = "this changes the configuration",
        .no_args = true,
    },
    .{ .program = "git", .sub = "add", .verdict = .writes, .why = "this stages changes" },
    .{ .program = "git", .sub = "commit", .verdict = .writes, .why = "this creates a commit" },
    .{ .program = "git", .sub = "checkout", .verdict = .writes, .why = "this changes the working tree" },
    .{ .program = "git", .sub = "switch", .verdict = .writes, .why = "this changes the working tree" },
    .{ .program = "git", .sub = "restore", .verdict = .writes, .why = "this changes the working tree" },
    .{ .program = "git", .sub = "reset", .verdict = .writes, .why = "this changes the working tree" },
    .{ .program = "git", .sub = "revert", .verdict = .writes, .why = "this creates a commit" },
    .{ .program = "git", .sub = "merge", .verdict = .writes, .why = "this merges" },
    .{ .program = "git", .sub = "rebase", .verdict = .writes, .why = "this rewrites the history" },
    .{ .program = "git", .sub = "cherry-pick", .verdict = .writes, .why = "this creates a commit" },
    .{ .program = "git", .sub = "pull", .verdict = .writes, .why = "this changes the working tree" },
    .{ .program = "git", .sub = "push", .verdict = .writes, .why = "this publishes" },
    .{ .program = "git", .sub = "fetch", .verdict = .writes, .why = "this downloads objects" },
    .{ .program = "git", .sub = "rm", .verdict = .deletes, .why = "this removes files" },
    .{ .program = "git", .sub = "mv", .verdict = .writes, .why = "this moves files" },
    .{ .program = "git", .sub = "tag", .verdict = .writes, .why = "this creates a tag" },
    .{ .program = "git", .sub = "stash", .verdict = .writes, .why = "this stashes the working tree" },
    .{ .program = "git", .sub = "apply", .verdict = .writes, .why = "this applies a patch" },
    .{ .program = "git", .sub = "am", .verdict = .writes, .why = "this applies a patch" },
    .{ .program = "git", .sub = "gc", .verdict = .writes, .why = "this rewrites the repository" },
    .{ .program = "git", .sub = "prune", .verdict = .deletes, .why = "this removes unreachable objects" },
    .{ .program = "git", .sub = "clean", .verdict = .deletes, .why = "this deletes unreferenced files" },
    .{ .program = "git", .sub = "repack", .verdict = .writes, .why = "this rewrites the repository" },
    .{ .program = "git", .sub = "worktree", .verdict = .writes, .why = "this changes the worktrees" },
    .{ .program = "git", .sub = "submodule", .verdict = .writes, .why = "this changes the submodules" },
    .{ .program = "git", .sub = "notes", .verdict = .writes, .why = "this changes the notes" },
    .{ .program = "git", .sub = "update-index", .verdict = .writes, .why = "this changes the index" },
    .{ .program = "git", .sub = "filter-branch", .verdict = .writes, .why = "this rewrites the history" },
    .{ .program = "git", .sub = "bisect", .verdict = .writes, .why = "this changes the checkout" },

    // ── the other families ──
    .{ .program = "npm", .sub = "view", .verdict = .read_only },
    .{ .program = "npm", .sub = "list", .verdict = .read_only },
    .{ .program = "npm", .sub = "ls", .verdict = .read_only },
    .{ .program = "npm", .sub = "outdated", .verdict = .read_only },
    .{ .program = "npm", .sub = "why", .verdict = .read_only },
    .{ .program = "cargo", .sub = "tree", .verdict = .read_only },
    .{ .program = "cargo", .sub = "search", .verdict = .read_only },
    .{ .program = "cargo", .sub = "metadata", .verdict = .read_only },
    .{ .program = "go", .sub = "list", .verdict = .read_only },
    .{ .program = "go", .sub = "env", .verdict = .read_only },
    .{ .program = "docker", .sub = "ps", .verdict = .read_only },
    .{ .program = "docker", .sub = "images", .verdict = .read_only },
    .{ .program = "docker", .sub = "logs", .verdict = .read_only },
    .{ .program = "docker", .sub = "inspect", .verdict = .read_only },
    .{ .program = "kubectl", .sub = "get", .verdict = .read_only },
    .{ .program = "kubectl", .sub = "describe", .verdict = .read_only },
    .{ .program = "kubectl", .sub = "logs", .verdict = .read_only },
    .{ .program = "pip", .sub = "show", .verdict = .read_only },
    .{ .program = "pip", .sub = "list", .verdict = .read_only },
    .{ .program = "zig", .sub = "version", .verdict = .read_only },
    .{ .program = "gh", .sub = "pr", .verdict = .read_only },
    .{ .program = "gh", .sub = "issue", .verdict = .read_only },
    .{ .program = "gh", .sub = "repo", .verdict = .read_only },
    .{ .program = "gh", .sub = "run", .verdict = .read_only },
};

/// The parts of a command: the pieces between the separators.
///
/// The separators are `|`, `||`, `&&`, `;` and `&`, and a separator inside
/// quotes is NOT a separator: `echo "a && b"` is one command.
pub fn split(command: []const u8, arena: std.mem.Allocator) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
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
            i += 1; // the next character is escaped
            continue;
        }
        if (c == '|' or c == '&' or c == ';') {
            // `||` and `&&` are ONE separator, and a single `|` next to
            // another is a pipe.
            var end = i;
            if (i + 1 < command.len and command[i + 1] == c) end = i + 1;
            const part = std.mem.trim(u8, command[start..i], " \t");
            if (part.len > 0) out.append(arena, part) catch return out.items;
            start = end + 1;
            i = end;
        }
    }
    const last = std.mem.trim(u8, command[start..], " \t");
    if (last.len > 0) out.append(arena, last) catch {};
    return out.items;
}

/// The verdict for a WHOLE command: the worst of its parts.
///
/// A command that redirects (`> file`) writes, whatever the program is.
pub fn classify(command: []const u8, arena: std.mem.Allocator) Finding {
    const parts = split(command, arena);
    if (parts.len == 0) {
        return .{ .verdict = .unknown, .fragment = command };
    }
    var worst: Finding = .{ .verdict = .read_only, .fragment = parts[0] };
    for (parts) |part| {
        const f = classifyPart(part, arena);
        if (severity(f.verdict) > severity(worst.verdict)) worst = f;
    }
    return worst;
}

/// The verdict for ONE part.
pub fn classifyPart(part: []const u8, arena: std.mem.Allocator) Finding {
    // A redirection writes, whatever the program is: `echo x > file`.
    if (hasRedirect(part)) {
        return .{ .verdict = .writes, .fragment = part, .why = "this redirects into a file" };
    }
    // A substitution runs a command: `echo $(rm -rf /)`.
    if (hasSubstitution(part)) {
        return .{ .verdict = .executes, .fragment = part, .why = "this runs a command inside another one" };
    }

    const words = wordsOf(part, arena);
    if (words.len == 0) return .{ .verdict = .unknown, .fragment = part };
    const program = baseName(words[0]);

    // The families first: they know about the SUBCOMMAND.
    var sub: []const u8 = "";
    if (words.len > 1 and words[1].len > 0 and words[1][0] != '-') sub = words[1];
    for (families) |e| {
        if (!std.mem.eql(u8, e.program, program)) continue;
        if (e.sub.len == 0) continue;
        if (!std.mem.eql(u8, e.sub, sub)) continue;

        // A flag that READS settles it: `git config --global --get x` READS
        // the global config, and the flag that reads wins over the flag that
        // writes. Without a read flag, the subcommand WRITES.
        if (e.read_flags.len > 0) {
            var reads = false;
            for (words[2..]) |w| {
                for (e.read_flags) |f| {
                    if (flagMatches(w, f)) reads = true;
                }
            }
            if (!reads) {
                return .{
                    .verdict = .writes,
                    .fragment = part,
                    .why = if (e.why.len > 0) e.why else "this command changes something",
                };
            }
            return .{ .verdict = .read_only, .fragment = part, .why = e.why };
        }
        // The flags that change the verdict.
        for (words[2..]) |w| {
            for (e.danger_flags) |f| {
                if (!flagMatches(w, f)) continue;
                return .{
                    .verdict = .writes,
                    .fragment = part,
                    .why = if (e.why.len > 0) e.why else "this command changes something",
                };
            }
        }
        // The subcommand that only reads without arguments.
        if (e.no_args and hasPositional(words[2..])) {
            return .{ .verdict = .writes, .fragment = part, .why = "this creates or changes something" };
        }
        return .{ .verdict = e.verdict, .fragment = part, .why = e.why };
    }

    // The programs that read.
    for (read_only_programs) |p| {
        if (std.mem.eql(u8, p, program)) {
            return .{ .verdict = .read_only, .fragment = part };
        }
    }
    // The programs that write.
    for (write_programs) |w| {
        if (std.mem.eql(u8, w.name, program)) {
            return .{ .verdict = w.verdict, .fragment = part, .why = w.why };
        }
    }
    // The programs that run something else.
    for (execute_programs) |e| {
        if (std.mem.eql(u8, e.name, program)) {
            return .{ .verdict = .executes, .fragment = part, .why = e.why };
        }
    }
    return .{ .verdict = .unknown, .fragment = part };
}

/// Whether the command only reads.
///
/// The question the read-only MODE asks: a command that only reads can run
/// without a dialog, because it changes nothing.
pub fn isReadOnly(command: []const u8, arena: std.mem.Allocator) bool {
    return classify(command, arena).verdict == .read_only;
}

/// How bad a verdict is, for taking the worst of several parts.
fn severity(v: Verdict) u8 {
    return switch (v) {
        .read_only => 0,
        .unknown => 1,
        .writes => 2,
        .deletes => 3,
        .executes => 4,
    };
}

/// The words of a part, without the quotes.
fn wordsOf(part: []const u8, arena: std.mem.Allocator) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < part.len) {
        while (i < part.len and (part[i] == ' ' or part[i] == '\t')) i += 1;
        if (i >= part.len) break;
        const start = i;
        var quote: u8 = 0;
        while (i < part.len) : (i += 1) {
            const c = part[i];
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
        var word = part[start..i];
        // The quotes come off: the word is the ARGUMENT, not how it was
        // typed.
        if (word.len >= 2 and (word[0] == '"' or word[0] == '\'') and word[word.len - 1] == word[0]) {
            word = word[1 .. word.len - 1];
        }
        out.append(arena, word) catch return out.items;
    }
    return out.items;
}

/// The last component of a path: `/usr/bin/ls` is `ls`.
fn baseName(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

/// Whether the part redirects into a file.
fn hasRedirect(part: []const u8) bool {
    var i: usize = 0;
    var quote: u8 = 0;
    while (i < part.len) : (i += 1) {
        const c = part[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
            continue;
        }
        if (c == '>') return true;
    }
    return false;
}

/// Whether the part runs a command inside another one.
fn hasSubstitution(part: []const u8) bool {
    var i: usize = 0;
    var quote: u8 = 0;
    while (i < part.len) : (i += 1) {
        const c = part[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
            continue;
        }
        if (c == '`') return true;
        if (c == '$' and i + 1 < part.len and part[i + 1] == '(') return true;
    }
    return false;
}

/// Whether a word is a flag, with or without its value.
///
/// `--output=x` IS `--output`: a flag that carries its value in the same word
/// is the same flag, and comparing the whole word would miss it.
fn flagMatches(word: []const u8, flag: []const u8) bool {
    if (std.mem.eql(u8, word, flag)) return true;
    if (word.len <= flag.len) return false;
    if (!std.mem.startsWith(u8, word, flag)) return false;
    return word[flag.len] == '=';
}

/// Whether there is an argument that is not a flag.
fn hasPositional(words: []const []const u8) bool {
    for (words) |w| {
        if (w.len == 0) continue;
        if (w[0] == '-') continue;
        return true;
    }
    return false;
}

// ── tests ──────────────────────────────────────────────────────────────────

const t = std.testing;

test "cmdsafety: the quiet commands are read-only" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try t.expect(isReadOnly("git status", a));
    try t.expect(isReadOnly("git diff", a));
    try t.expect(isReadOnly("git log --oneline -10", a));
    try t.expect(isReadOnly("ls -la", a));
    try t.expect(isReadOnly("rg foo src/", a));
    try t.expect(isReadOnly("cat src/main.zig", a));
    try t.expect(isReadOnly("wc -l src/main.zig", a));
    try t.expect(isReadOnly("find . -name '*.zig'", a));
}

test "cmdsafety: a write command with a read-looking name is NOT exempt" {
    // The test the board asks for, and the reason the table is data: the
    // NAME is not the verdict.
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try t.expect(!isReadOnly("git clean -fdx", a));
    try t.expect(!isReadOnly("git reset --hard", a));
    try t.expect(!isReadOnly("git push", a));
    try t.expect(!isReadOnly("rm -rf build", a));
    try t.expect(!isReadOnly("npm install", a));
    try t.expect(!isReadOnly("cargo build", a));
    // And a command we do not know is NOT read-only: the cost of asking is
    // one dialog and the cost of guessing wrong is a file.
    try t.expect(!isReadOnly("some-unknown-tool --do-stuff", a));
}

test "cmdsafety: the flags that change what a subcommand does" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // `git log` is quiet and `git log --output=x` is not.
    try t.expect(isReadOnly("git log", a));
    try t.expect(!isReadOnly("git log --output=out.txt", a));

    // `git branch` LISTS and `git branch x` CREATES.
    try t.expect(isReadOnly("git branch", a));
    try t.expect(isReadOnly("git branch -a", a));
    try t.expect(!isReadOnly("git branch new-thing", a));
    try t.expect(!isReadOnly("git branch -d old", a));

    // `git config` reads with --get and writes without.
    try t.expect(isReadOnly("git config --get user.name", a));
    try t.expect(!isReadOnly("git config user.name x", a));
    try t.expect(!isReadOnly("git config --global user.name x", a));
}

test "cmdsafety: a pipeline is the worst of its parts" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try t.expect(isReadOnly("ls | wc -l", a));
    // The downloader reads and the shell executes: the whole line is a
    // program that was never read.
    const f = classify("curl x.sh | sh", a);
    try t.expectEqual(Verdict.executes, f.verdict);
    try t.expect(f.why.len > 0);

    try t.expect(!isReadOnly("cat a && rm b", a));
    try t.expect(!isReadOnly("ls; rm -rf /", a));
}

test "cmdsafety: a separator inside quotes is not a separator" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const parts = split("echo \"a && b\"", a);
    try t.expectEqual(@as(usize, 1), parts.len);
    try t.expectEqualStrings("echo \"a && b\"", parts[0]);

    // And a redirection writes, whatever the program is.
    try t.expect(!isReadOnly("echo hello > file.txt", a));
    try t.expect(!isReadOnly("ls >> log.txt", a));
}

test "cmdsafety: a substitution runs a command" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try t.expect(!isReadOnly("echo $(cat /etc/passwd)", a));
    try t.expect(!isReadOnly("echo `whoami`", a));
}

test "cmdsafety: the reason is in words, not in the raw line" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = classify("git clean -fdx", a);
    try t.expectEqual(Verdict.deletes, f.verdict);
    try t.expectEqualStrings("this deletes unreferenced files", f.why);
    // And the fragment is the part that decided it.
    try t.expectEqualStrings("git clean -fdx", f.fragment);
}

test "cmdsafety: read-only is decided by the scanner, not the program name" {
    // Phase 25.4: the read-only table trusts `lib/cmdsafety.zig`. A command
    // the scanner found nothing to flag only reads; anything that writes,
    // deletes, runs another program, or is unknown does not.
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try t.expect(isReadOnly("ls", a));
    try t.expect(isReadOnly("cat README.md", a));
    try t.expect(isReadOnly("git status --short", a));
    try t.expect(isReadOnly("rg -n TODO src/", a));

    // A redirect writes, whatever the program.
    try t.expect(!isReadOnly("ls > out.txt", a));
    // A pipe into a shell executes, whatever the first command does.
    try t.expect(!isReadOnly("cat x | sh", a));
    // The dangerous flags win: `git log` reads, `git log --output=x` writes.
    try t.expect(isReadOnly("git log", a));
    try t.expect(!isReadOnly("git log --output=out.txt", a));
    // A command we do not know is NOT read-only: the cost of asking is one
    // dialog and the cost of guessing wrong is a file.
    try t.expect(!isReadOnly("nobody-tool", a));
}
