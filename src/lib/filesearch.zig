//! The file list behind the `@` popup.
//!
//! Two decisions, one per exported function:
//!
//! - WHICH files (`collect`): everything under the working directory that a
//!   person would type. The walk is done ONCE and cached by the caller, because
//!   this runs on every keystroke after an `@` and a keystroke must not touch
//!   the disk.
//! - In WHAT ORDER (`sortShallowFirst`): shallow first, then alphabetical. A
//!   bare `@` then shows the top of the tree, not whatever `readdir` happened
//!   to return first (which on ext4 is not alphabetical, and on two runs of the
//!   same directory is not even the same).
//!
//! ## What is skipped, and why
//!
//! VCS metadata, dependency trees and build output: directories nobody edits by
//! hand that can hold more files than the whole project (`.git` of a big repo
//! is tens of thousands of entries, `node_modules` is worse). A hidden
//! directory is skipped too, with one exception: `.github/…` is real work, so
//! hidden dirs are not skipped wholesale — `.git` alone is.
//!
//! ## Separators are `/`, always
//!
//! The walker uses the OS separator, and a `@src\tui.zig` on Windows is not a
//! mention at all: `mentions.scan` accepts `/` and not `\`, so it would send
//! `@src` and nothing would expand. `/` also opens fine on Windows, so one
//! form works on all three systems.

const std = @import("std");

/// Hard cap on the index. A monorepo with 200k files would make every keystroke
/// a full sort, and a `@` list that long is not a list anyone reads: the fuzzy
/// query is the way in.
pub const default_cap: usize = 20_000;

/// Directory names that are never worth listing.
///
/// `.git` is here and the OTHER hidden directories are not: `.github/` holds
/// workflows, `.zode/` holds skills, and both are files a person mentions.
pub fn skipDir(name: []const u8) bool {
    if (name.len == 0) return true;
    if (std.mem.eql(u8, name, ".git")) return true;
    const skip = [_][]const u8{
        "node_modules", "zig-cache", ".zig-cache", "zig-out", "target",
        "dist",       "build",       "vendor",      "venv",   ".venv",
        "__pycache__", "sessions",   "Pods",        "tmp",    "coverage",
    };
    for (skip) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

/// Appends the path of every file under `root` to `out`, `/`-separated.
///
/// Best-effort by design: a directory that cannot be read (permissions, a file
/// that vanished mid-walk) is a hole in the list, never an error that leaves
/// the popup empty. The cap is a stop, not a failure: a list of 20 000 paths is
/// already more than the fuzzy filter can use.
///
/// The caller owns the strings and the list.
pub fn collect(
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    /// `*std.ArrayList([]u8)` or `*std.ArrayList([]const u8)`: the caller's pool
    /// is owned strings either way, and a generic parameter is cheaper than two
    /// wrappers that can disagree.
    out: anytype,
    cap: usize,
) void {
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var walker = dir.walk(gpa) catch return;
    defer walker.deinit();

    while (walker.next(io) catch null) |e| {
        switch (e.kind) {
            .directory => {
                if (skipDir(e.basename)) walker.leave(io);
            },
            .file => {
                if (out.items.len >= cap) return;
                const path = gpa.dupe(u8, e.path) catch return;
                // `e.path` borrows the walker's buffer and dies on the next
                // `next`, so the copy above is the only safe exit.
                for (path) |*c| {
                    if (c.* == '\\') c.* = '/';
                }
                out.append(gpa, path) catch {
                    gpa.free(path);
                    return;
                };
            },
            else => {},
        }
    }
}

/// How many directories deep a path is (`src/lib/x.zig` is 2).
pub fn depth(path: []const u8) usize {
    var d: usize = 0;
    for (path) |c| {
        if (c == '/') d += 1;
    }
    return d;
}

/// Shallow first, then alphabetical: the order a bare `@` shows.
///
/// Generic over the slot type (`[]u8` in the popup's pool, `[]const u8` in the
/// tests): the comparison only reads, so both are the same order.
pub fn sortShallowFirst(items: anytype) void {
    std.mem.sort(std.meta.Elem(@TypeOf(items)), items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            const da = depth(a);
            const db = depth(b);
            if (da != db) return da < db;
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
}

/// The part of the path after the last `/` — what the eye looks at.
pub fn basename(path: []const u8) []const u8 {
    const at = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[at + 1 ..];
}

// ── tests ─────────────────────────────────────────────────────

const t = std.testing;

test "skipDir: git, dependencies and build output; .github is NOT skipped" {
    try t.expect(skipDir(".git"));
    try t.expect(skipDir("node_modules"));
    try t.expect(skipDir(".zig-cache"));
    try t.expect(skipDir("zig-out"));
    try t.expect(!skipDir(".github"));
    try t.expect(!skipDir("src"));
    try t.expect(!skipDir("notas"));
}

test "collect: walks the tree, skips the heavy directories, uses / separators" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;

    const root = try std.fmt.allocPrint(a, ".zode-filesearch-{d}", .{t.random_seed});
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const files = [_][]const u8{
        "top.zig",
        "src/agent.zig",
        "src/lib/fuzzy.zig",
        ".github/workflows/ci.yml",
        "node_modules/pkg/index.js",
        ".git/config",
        "zig-out/bin/zode",
    };
    for (files) |rel| {
        const full = try std.fs.path.join(a, &.{ root, rel });
        if (std.fs.path.dirname(full)) |d| try std.Io.Dir.cwd().createDirPath(io, d);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = full, .data = "x" });
    }

    var out: std.ArrayList([]const u8) = .empty;
    collect(a, io, root, &out, default_cap);

    try t.expectEqual(@as(usize, 4), out.items.len);
    for (out.items) |p| {
        try t.expect(std.mem.indexOfScalar(u8, p, '\\') == null);
        try t.expect(std.mem.indexOf(u8, p, "node_modules") == null);
        try t.expect(std.mem.indexOf(u8, p, ".git/") == null);
        try t.expect(std.mem.indexOf(u8, p, "zig-out") == null);
    }
    // The nested ones are there, and `.github` survived the skip list.
    var seen_src = false;
    var seen_ci = false;
    for (out.items) |p| {
        const base = basename(p);
        if (std.mem.eql(u8, base, "fuzzy.zig")) {
            seen_src = true;
            try t.expect(std.mem.indexOf(u8, p, "src/lib/fuzzy.zig") != null);
        }
        if (std.mem.eql(u8, base, "ci.yml")) seen_ci = true;
    }
    try t.expect(seen_src);
    try t.expect(seen_ci);
}

test "collect: the cap stops the walk instead of running to the end" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;

    const root = try std.fmt.allocPrint(a, ".zode-filesearch-cap-{d}", .{t.random_seed});
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    for (0..12) |i| {
        const full = try std.fmt.allocPrint(a, "{s}/f{d}.txt", .{ root, i });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = full, .data = "x" });
    }

    var out: std.ArrayList([]const u8) = .empty;
    collect(a, io, root, &out, 5);
    try t.expectEqual(@as(usize, 5), out.items.len);
}

test "sortShallowFirst: root files first, then alphabetical" {
    var items = [_][]const u8{
        "src/lib/z.zig",
        "zzz.zig",
        "src/a.zig",
        "README.md",
        "a/b/c.zig",
    };
    sortShallowFirst(&items);
    const want = [_][]const u8{ "README.md", "zzz.zig", "src/a.zig", "a/b/c.zig", "src/lib/z.zig" };
    for (want, 0..) |w, i| try t.expectEqualStrings(w, items[i]);
}

test "depth and basename" {
    try t.expectEqual(@as(usize, 0), depth("a.zig"));
    try t.expectEqual(@as(usize, 2), depth("src/lib/x.zig"));
    try t.expectEqualStrings("x.zig", basename("src/lib/x.zig"));
    try t.expectEqualStrings("x.zig", basename("x.zig"));
}
