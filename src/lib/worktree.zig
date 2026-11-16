//! Isolated worktree sessions (Phase 18) — the PURE half.
//!
//! The git commands and the cwd switch live in the agent; everything that can
//! be decided from DATA is here and tested with no repo, no TUI and no network:
//! name validation, path derivation, and the "dirty worktree" refusal (which
//! LISTS what would be lost before `discard: true` can override it).
//!
//! WHY "only when asked": a branch is what a branch is for. A worktree is a
//! second checkout of the SAME repo at a different path; creating one without
//! being asked is a side effect the user did not request. The tool description
//! says so, and nothing in the harness creates one proactively.

const std = @import("std");

pub const worktrees_subdir = ".zode/worktrees";

/// The active worktree session: the ONE place that remembers where to return.
/// `return_*` are fixed buffers (no allocator) so this can live as a global and
/// be saved/restored like `project.Info` — the cwd cannot be represented by a
/// heap slice that a worker might read after a switch frees it.
pub const Session = struct {
    active: bool = false,
    name_buf: [64]u8 = undefined,
    name_len: usize = 0,
    path_buf: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize = 0,
    /// Where we came from: restored on exit_worktree.
    return_cwd_buf: [std.fs.max_path_bytes]u8 = undefined,
    return_cwd_len: usize = 0,
    return_root_buf: [std.fs.max_path_bytes]u8 = undefined,
    return_root_len: usize = 0,

    pub fn name(self: *const Session) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn path(self: *const Session) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    pub fn returnCwd(self: *const Session) []const u8 {
        return self.return_cwd_buf[0..self.return_cwd_len];
    }

    pub fn returnRoot(self: *const Session) ?[]const u8 {
        if (self.return_root_len == 0) return null;
        return self.return_root_buf[0..self.return_root_len];
    }

    pub fn enter(self: *Session, name_str: []const u8, path_str: []const u8, cwd_str: []const u8, root_str: []const u8) bool {
        if (name_str.len == 0 or name_str.len > self.name_buf.len) return false;
        if (path_str.len > self.path_buf.len or cwd_str.len > self.return_cwd_buf.len) return false;
        if (root_str.len > self.return_root_buf.len) return false;
        self.active = true;
        @memcpy(self.name_buf[0..name_str.len], name_str);
        self.name_len = name_str.len;
        @memcpy(self.path_buf[0..path_str.len], path_str);
        self.path_len = path_str.len;
        @memcpy(self.return_cwd_buf[0..cwd_str.len], cwd_str);
        self.return_cwd_len = cwd_str.len;
        @memcpy(self.return_root_buf[0..root_str.len], root_str);
        self.return_root_len = root_str.len;
        return true;
    }

    pub fn leave(self: *Session) void {
        self.* = .{};
    }
};

/// A worktree name becomes a directory under `.zode/worktrees/` and a git
/// branch name, so it must be path-safe and branch-safe.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (name[0] == '-' or name[name.len - 1] == '-') return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!ok) return false;
    }
    return true;
}

/// `<repo_root>/.zode/worktrees/<name>`. Returns null when the name is unsafe
/// or the buffer is too small — a path that escapes the repo is never built.
pub fn worktreePath(buf: []u8, repo_root: []const u8, name: []const u8) ?[]const u8 {
    if (!validName(name)) return null;
    return std.fmt.bufPrint(buf, "{s}/{s}/{s}", .{ repo_root, worktrees_subdir, name }) catch null;
}

/// The branch created with the worktree. Prefixed so it cannot collide with a
/// user's branch by accident (`zode-wt/<name>`).
pub fn branchName(buf: []u8, name: []const u8) ?[]const u8 {
    if (!validName(name)) return null;
    return std.fmt.bufPrint(buf, "zode-wt/{s}", .{name}) catch null;
}

/// One line of `git status --porcelain` → a short human description. We keep
/// the raw line too, so the refusal can show exactly what would be lost.
pub const Change = struct {
    raw: []const u8,
    path: []const u8,
};

/// Parses `git status --porcelain` output into changes. Blank lines and the
/// branch header are ignored. This is a PURE parse of text the caller obtained
/// from git; no process is spawned here.
pub fn parseStatus(gpa: std.mem.Allocator, porcelain: []const u8) ![]const Change {
    var out: std.ArrayList(Change) = .empty;
    var it = std.mem.splitScalar(u8, porcelain, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len < 4) continue;
        // Porcelain XY PATH — the first two bytes are the status codes.
        const path = std.mem.trim(u8, line[2..], " \t");
        if (path.len == 0) continue;
        try out.append(gpa, .{ .raw = line, .path = path });
    }
    return out.toOwnedSlice(gpa);
}

/// `true` when a worktree is dirty — any change at all blocks an implicit
/// remove. The caller only removes after an explicit `discard: true`.
pub fn isDirty(changes: []const Change) bool {
    return changes.len > 0;
}

/// The refusal text for removing a dirty worktree. It LISTS what would be lost
/// (capped) and names the way out: `discard: true`. A refusal without the list
/// asks the user to trust a claim they cannot check.
pub fn dirtyRefusal(gpa: std.mem.Allocator, name: []const u8, changes: []const Change) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa, 
        "worktree '{s}' is dirty ({d} change(s)) and was NOT removed. Pass discard: true to remove it anyway. Would be lost:",
        .{ name, changes.len },
    );
    const shown = @min(changes.len, 20);
    for (changes[0..shown]) |c| {
        try out.appendSlice(gpa, "\n  ");
        try out.appendSlice(gpa, c.raw);
    }
    if (changes.len > shown) try out.print(gpa, "\n  ... and {d} more", .{changes.len - shown});
    return out.toOwnedSlice(gpa);
}

/// What `/clean` reports about a leftover worktree: known, never removed.
pub fn leftoverNote(gpa: std.mem.Allocator, name: []const u8, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(gpa,
        "leftover worktree '{s}' at {s} — zode never removes worktrees unprompted; use exit_worktree(remove=true, discard=true) if you really want it gone",
        .{ name, path },
    );
}

test "worktree: names are path and branch safe" {
    try std.testing.expect(validName("feature-a"));
    try std.testing.expect(validName("fix_2"));
    try std.testing.expect(!validName(""));
    try std.testing.expect(!validName("../evil"));
    try std.testing.expect(!validName("has space"));
    try std.testing.expect(!validName("-leading"));
}

test "worktree: path and branch derivation" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("/repo/.zode/worktrees/feature-a", worktreePath(&buf, "/repo", "feature-a").?);
    try std.testing.expectEqualStrings("zode-wt/feature-a", branchName(&buf, "feature-a").?);
    try std.testing.expect(worktreePath(&buf, "/repo", "../evil") == null);
}

test "worktree: parse porcelain and refuse a dirty tree with the list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const changes = try parseStatus(a,
        " M src/main.zig\n?? notes.txt\nA  new.zig\n");
    try std.testing.expectEqual(@as(usize, 3), changes.len);
    try std.testing.expect(isDirty(changes));
    try std.testing.expect(!isDirty(&.{}));

    const text = try dirtyRefusal(a, "feature-a", changes);
    try std.testing.expect(std.mem.indexOf(u8, text, "feature-a") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "src/main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "discard: true") != null);
}

test "worktree: /clean names a leftover without removing it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try leftoverNote(arena.allocator(), "feature-a", "/repo/.zode/worktrees/feature-a");
    try std.testing.expect(std.mem.indexOf(u8, text, "never removes") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "feature-a") != null);
}

test "worktree: session remembers where to return and resets on leave" {
    var s = Session{};
    try std.testing.expect(!s.active);
    try std.testing.expect(s.enter("feature-a", "/repo/.zode/worktrees/feature-a", "/repo", "/repo"));
    try std.testing.expect(s.active);
    try std.testing.expectEqualStrings("feature-a", s.name());
    try std.testing.expectEqualStrings("/repo/.zode/worktrees/feature-a", s.path());
    try std.testing.expectEqualStrings("/repo", s.returnCwd());
    try std.testing.expectEqualStrings("/repo", s.returnRoot().?);
    s.leave();
    try std.testing.expect(!s.active);
    try std.testing.expectEqual(@as(usize, 0), s.name_len);
}
