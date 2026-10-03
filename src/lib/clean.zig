//! `/clean`: purge the garbage ZODE leaves behind, and nothing else.
//!
//! The scope is the whole point of the command, so it is stated here as a rule
//! and then enforced structurally: every candidate is built from an entry name
//! read out of a directory zode owns, and every candidate is checked against
//! `isProtected` before it reaches the report.
//!
//! What zode owns, and only this:
//!
//! - `sessions/zode-*.jsonl` of **0 bytes** (the cause is already fixed — the
//!   session is lazy since Fase 1.9 — but the residue of 58 files / 24 empty is
//!   still sitting there, and `find -empty` is not something anyone remembers to
//!   run).
//! - the leftover `<name>.tmp` of an interrupted atomic write (`config.zig`
//!   writes a temp and renames it).
//! - the instance registry `<gitdir>/zode/inst/*.json`, when a process died
//!   without cleaning up after itself.
//!
//! What is NEVER touched, and this is a bug if it ever shows up in the list:
//!
//! - **`.zig-cache`, `zig-out`, `zig-pkg` and the code.** Those belong to the
//!   developer and the build. An agent that deletes its own compile cache while
//!   compiling costs a full `zig build` for nothing.
//! - **`auth.json` and `permissions.json`.** A lost key is a 401 with no
//!   explanation, and the June fuzzer already saved a pasted key into the real
//!   config.
//!
//! The scan is a first pass and the deletion a second one, so a failure halfway
//! through reports what it could not remove instead of leaving the state
//! half-changed and silent. Nothing is deleted unless `apply` is called: the
//! command shows the plan by default.

const std = @import("std");

/// What a candidate is, and therefore what happens to it.
pub const Bucket = enum {
    /// A session file of 0 bytes. Deletable.
    empty_session,
    /// An instance file whose process is gone (or unreadable). Deletable.
    stale_instance,
    /// A `<name>.tmp` of an interrupted atomic write. Deletable.
    own_temp,
    /// A session older than the cutoff. **Reported, never deleted silently**:
    /// the transcript may still be wanted, so this one is a separate question.
    old_session,

    pub fn label(b: Bucket) []const u8 {
        return switch (b) {
            .empty_session => "empty sessions",
            .stale_instance => "stale instance files",
            .own_temp => "leftover temp files",
            .old_session => "old sessions",
        };
    }

    /// `old_session` is the odd one out: it is listed so the count is honest,
    /// but it needs a yes of its own, not the one that clears the rest.
    pub fn deletable(b: Bucket) bool {
        return b != .old_session;
    }

    /// The directory it comes from, spelled for the report. A cleanup command
    /// that does not say WHERE it looked is one you cannot audit.
    pub fn rootHint(b: Bucket) []const u8 {
        return switch (b) {
            .empty_session => "sessions/zode-*.jsonl, 0 bytes",
            .own_temp => "interrupted atomic write",
            .stale_instance => "instance registry, process gone",
            .old_session => "older than 30 days",
        };
    }

    /// Draw order: the ones that go first, the ones that stay last.
    pub fn rank(b: Bucket) u8 {
        return switch (b) {
            .empty_session => 0,
            .own_temp => 1,
            .stale_instance => 2,
            .old_session => 3,
        };
    }
};

/// Where a candidate lives. An enum and not a path string so that deleting
/// cannot be talked into a directory that was never scanned.
pub const Root = enum {
    sessions,
    instances,
    config,

    pub fn label(r: Root) []const u8 {
        return switch (r) {
            .sessions => "sessions/",
            .instances => "instance registry",
            .config => "config dir",
        };
    }
};

pub const Item = struct {
    /// Full path, for printing. Owned by the report.
    path: []const u8,
    /// Basename inside the root, the thing `deleteFile` takes. Owned too.
    name: []const u8,
    root: Root,
    bucket: Bucket,
    bytes: u64,
};

/// The directories `/clean` looks in. Tests point all three inside a temp dir,
/// which is the only reason this is a struct instead of three constants.
pub const Roots = struct {
    sessions: []const u8 = "sessions",
    /// `<gitdir>/zode/inst`, or null when there is no git repo here.
    instances: ?[]const u8 = null,
    /// `~/.config/zode`, or null without an environment.
    config: ?[]const u8 = null,
};

pub const Options = struct {
    roots: Roots = .{},
    now_secs: i64 = 0,
    /// A session older than this is reported as `old_session`.
    old_after_secs: i64 = 30 * 24 * 60 * 60,
    /// An instance whose last heartbeat is older than this counts as dead.
    heartbeat_ttl_secs: i64 = 30,
};

pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    items: []Item = &.{},
    /// Entries looked at in the three roots. Printed next to the counts, so
    /// "0 empty sessions" reads as "looked at 58 and found none" and not as
    /// "did not look".
    scanned: u32 = 0,
    /// True when a root that should exist could not be opened. A cleanup
    /// command that cannot see a directory has to say so instead of reporting
    /// a clean bill of health.
    missing_sessions: bool = false,
    /// What `deleteFile` refused to remove, so a failure is never silent.
    failed: u32 = 0,
    /// Set once `apply` ran, so the summary can say "deleted" and not "would".
    applied: bool = false,

    pub fn deinit(self: *Report) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn count(self: *const Report, b: Bucket) usize {
        var n: usize = 0;
        for (self.items) |it| {
            if (it.bucket == b) n += 1;
        }
        return n;
    }

    /// Everything that `apply` would remove.
    pub fn deletable(self: *const Report) usize {
        var n: usize = 0;
        for (self.items) |it| {
            if (it.bucket.deletable()) n += 1;
        }
        return n;
    }

    pub fn bytes(self: *const Report) u64 {
        var n: u64 = 0;
        for (self.items) |it| {
            if (it.bucket.deletable()) n += it.bytes;
        }
        return n;
    }
};

/// The files that must never be deleted, whatever the scan finds.
///
/// The first two are structural: the build artifacts are not in any of the
/// three roots, so they cannot be reached. The check is kept anyway because it
/// is the assertion that says so, and because the day someone adds a "scan the
/// repo root" pass this is what stops it.
pub fn isProtected(path: []const u8) bool {
    const blocked_dirs = [_][]const u8{ ".zig-cache", "zig-out", "zig-pkg" };
    // SEGMENT by segment, not by prefix: `a/b/.zig-cache/o` is as much a build
    // artifact as `.zig-cache/o`, and a prefix test on the whole path would miss
    // it. The converse is also true and is tested: `zig-out-mio` is somebody
    // else's directory whose name happens to start the same way.
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        for (blocked_dirs) |b| {
            if (std.mem.eql(u8, seg, b)) return true;
        }
    }
    const base = std.fs.path.basename(path);
    const blocked_files = [_][]const u8{ "auth.json", "permissions.json" };
    for (blocked_files) |f| {
        if (std.mem.eql(u8, base, f)) return true;
    }
    return false;
}

// ── scanning ─────────────────────────────────────────────────

/// First pass: look, do not touch. Everything it returns lives in the report's
/// arena, so `deinit` on the report is the whole cleanup.
pub fn scan(gpa: std.mem.Allocator, io: std.Io, opts: Options) !Report {
    var rep = Report{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer rep.arena.deinit();
    const a = rep.arena.allocator();

    rep.items = try scanSessions(a, io, opts, &rep.missing_sessions);
    const inst = try scanInstances(a, io, opts);
    const conf = try scanTemps(a, io, opts);

    var all: std.ArrayList(Item) = .empty;
    try all.appendSlice(a, rep.items);
    try all.appendSlice(a, inst);
    try all.appendSlice(a, conf);
    rep.items = all.items;

    // Draw order, so the numbers land grouped instead of in directory order.
    const S = struct {
        fn lessThan(_: void, x: Item, y: Item) bool {
            return x.bucket.rank() < y.bucket.rank();
        }
    };
    std.mem.sort(Item, rep.items, {}, S.lessThan);
    return rep;
}

fn scanSessions(a: std.mem.Allocator, io: std.Io, opts: Options, missing: *bool) ![]Item {
    var out: std.ArrayList(Item) = .empty;
    var dir = std.Io.Dir.cwd().openDir(io, opts.roots.sessions, .{ .iterate = true }) catch {
        // A cleanup command that invents the directory it was asked to clean is
        // odd, and one that stays silent about not finding it is worse.
        missing.* = true;
        return out.items;
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file) continue;
        if (std.mem.endsWith(u8, e.name, ".tmp")) {
            try push(a, &out, .sessions, opts.roots.sessions, e.name, .own_temp, 0);
            continue;
        }
        if (!std.mem.startsWith(u8, e.name, "zode-")) continue;
        if (!std.mem.endsWith(u8, e.name, ".jsonl")) continue;
        const st = dir.statFile(io, e.name, .{}) catch continue;
        if (st.size == 0) {
            try push(a, &out, .sessions, opts.roots.sessions, e.name, .empty_session, 0);
        } else if (opts.now_secs - st.mtime.toSeconds() > opts.old_after_secs) {
            try push(a, &out, .sessions, opts.roots.sessions, e.name, .old_session, st.size);
        }
    }
    return out.items;
}

fn scanInstances(a: std.mem.Allocator, io: std.Io, opts: Options) ![]Item {
    var out: std.ArrayList(Item) = .empty;
    const root = opts.roots.instances orelse return out.items;
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return out.items;
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file) continue;
        if (std.mem.endsWith(u8, e.name, ".tmp")) {
            try push(a, &out, .instances, root, e.name, .own_temp, 0);
            continue;
        }
        if (!std.mem.endsWith(u8, e.name, ".json")) continue;
        const st = dir.statFile(io, e.name, .{}) catch continue;
        if (isStaleInstance(io, a, dir, e.name, opts, st.size)) {
            try push(a, &out, .instances, root, e.name, .stale_instance, st.size);
        }
    }
    return out.items;
}

/// An instance file is stale when the process it names is gone, when its
/// heartbeat stopped, or when it cannot be understood at all.
///
/// The three are lumped together on purpose: for a CLEANUP command "I could
/// not read it" and "it is dead" lead to the same action, and splitting them
/// would only add a bucket nobody can act on. A file that is alive and readable
/// is never touched.
fn isStaleInstance(
    io: std.Io,
    a: std.mem.Allocator,
    dir: std.Io.Dir,
    name: []const u8,
    opts: Options,
    size: u64,
) bool {
    // A registry entry is small by construction. Anything big enough to be a
    // mistake is not going to be parsed as JSON anyway.
    if (size > 64 * 1024) return true;
    const text = dir.readFileAlloc(io, name, a, .limited(64 * 1024)) catch return true;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch return true;
    if (parsed != .object) return true;
    const obj = parsed.object;

    // An unknown version is a file written by a newer zode. Ignoring it is the
    // documented rule: refusing to understand is not a reason to delete.
    const v = switch (obj.get("v") orelse return true) {
        .integer => |n| n,
        else => return true,
    };
    if (v != 1) return false;

    const pid = switch (obj.get("pid") orelse return true) {
        .integer => |n| n,
        else => return true,
    };
    if (pid <= 0) return true;
    if (!pidAlive(@intCast(pid))) return true;

    const beat_ms = switch (obj.get("last_beat") orelse return false) {
        .integer => |n| n,
        else => return false,
    };
    if (beat_ms < 0) return false;
    return opts.now_secs - @divFloor(beat_ms, 1000) > opts.heartbeat_ttl_secs;
}

/// `kill(pid, 0)`: signal 0 is not delivered, it only asks whether the process
/// is there. `PermissionDenied` means it IS there and belongs to someone else,
/// so it counts as alive — deleting another user's live entry would be the one
/// destructive thing this command could plausibly do.
/// Signal 0 is not delivered: the kernel only checks that the pid exists.
const signal_zero: std.posix.SIG = @enumFromInt(0);

pub fn pidAlive(pid: i32) bool {
    std.posix.kill(pid, signal_zero) catch |err| switch (err) {
        error.ProcessNotFound => return false,
        error.PermissionDenied => return true,
        else => return true,
    };
    return true;
}

fn scanTemps(a: std.mem.Allocator, io: std.Io, opts: Options) ![]Item {
    var out: std.ArrayList(Item) = .empty;
    const root = opts.roots.config orelse return out.items;
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return out.items;
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file) continue;
        // zode only ever creates `<name>.tmp` right next to `<name>`, so a
        // `.tmp` inside a directory it owns is always its own leftover.
        if (!std.mem.endsWith(u8, e.name, ".tmp")) continue;
        try push(a, &out, .config, root, e.name, .own_temp, 0);
    }
    return out.items;
}

fn push(
    a: std.mem.Allocator,
    out: *std.ArrayList(Item),
    root: Root,
    root_path: []const u8,
    name: []const u8,
    bucket: Bucket,
    bytes: u64,
) !void {
    const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ root_path, name });
    if (isProtected(full)) return;
    try out.append(a, .{
        .path = full,
        .name = try a.dupe(u8, name),
        .root = root,
        .bucket = bucket,
        .bytes = bytes,
    });
}

/// Second pass, and the only thing in the module that removes anything.
///
/// A candidate is deleted by BASENAME inside a root that was just opened, never
/// by the path that was printed: a printed path is a string, and a string can
/// be anything. The basename came out of `dir.iterate()`, so it cannot contain a
/// separator.
pub fn apply(io: std.Io, rep: *Report, roots: Roots) !usize {
    var deleted: usize = 0;
    rep.applied = true;
    var idx: usize = 0;
    while (idx < rep.items.len) {
        // Group by root so each directory is opened once instead of once per
        // file, and so a run of failures is contiguous in the output.
        const root = rep.items[idx].root;
        const root_path = switch (root) {
            .sessions => roots.sessions,
            .instances => roots.instances orelse {
                idx += 1;
                continue;
            },
            .config => roots.config orelse {
                idx += 1;
                continue;
            },
        };
        var dir = std.Io.Dir.cwd().openDir(io, root_path, .{}) catch {
            idx += 1;
            continue;
        };
        defer dir.close(io);
        while (idx < rep.items.len and rep.items[idx].root == root) : (idx += 1) {
            const it = rep.items[idx];
            if (!it.bucket.deletable()) continue;
            dir.deleteFile(io, it.name) catch {
                rep.failed += 1;
                continue;
            };
            deleted += 1;
        }
    }
    return deleted;
}

// ── the git dir, for the instance registry ───────────────────

/// `<gitdir>/zode/inst`, or null outside a git repo.
///
/// Per WORKTREE, not per repository, and that is the whole point: two zodes in
/// the same directory share the gitdir and see each other, while two in
/// different worktrees have different gitdirs and never do. It also cannot
/// show up in `git status`, and `rm -rf .git` takes the registry with it.
///
/// The worktree case is a `.git` FILE whose first line is `gitdir: <path>`, and
/// that is the discriminator here: `openDir` on a file fails, on a directory
/// it does not.
pub fn instanceDir(gpa: std.mem.Allocator, io: std.Io) !?[]u8 {
    var cwd = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer cwd.close(io);
    return instanceDirIn(gpa, io, cwd);
}

/// `instanceDir` over an arbitrary directory, so a test can point it at a
/// sandbox instead of at whatever repo it happens to be running inside.
pub fn instanceDirIn(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !?[]u8 {
    var probe = dir.openDir(io, ".git", .{}) catch {
        const text = dir.readFileAlloc(io, ".git", gpa, .limited(4096)) catch return null;
        defer gpa.free(text);
        const target = parseGitdirPointer(gpa, text) catch return null;
        defer gpa.free(target);
        return try std.fmt.allocPrint(gpa, "{s}/zode/inst", .{target});
    };
    probe.close(io);
    return try std.fmt.allocPrint(gpa, ".git/zode/inst", .{});
}

/// The target of a `gitdir: <path>` pointer, resolved against the cwd.
///
/// Split out of `instanceDir` because the `.git`-as-a-FILE case is exactly the
/// linked-worktree one, which is the case that has to be right: it is what keeps
/// two zodes in two worktrees from thinking they are in the same project. A file
/// is much easier to test than a worktree.
pub fn parseGitdirPointer(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const line = std.mem.trim(u8, text, " \t\r\n");
    const prefix = "gitdir:";
    if (!std.mem.startsWith(u8, line, prefix)) return error.NotAGitdir;
    const raw = std.mem.trim(u8, line[prefix.len..], " \t\r\n");
    if (raw.len == 0) return error.NotAGitdir;
    // A relative gitdir is relative to the directory holding the pointer, which
    // is the cwd here.
    if (raw[0] == '/') return gpa.dupe(u8, raw);
    return std.fmt.allocPrint(gpa, "./{s}", .{raw});
}

// ── tests ─────────────────────────────────────────────────────

const testing = std.testing;

fn writeFileAt(io: std.Io, path: []const u8, data: []const u8) !void {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/').?;
    const dir_path = path[0..slash];
    std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var wbuf: [256]u8 = undefined;
    var w = f.writer(io, &wbuf);
    try w.interface.writeAll(data);
    try w.interface.flush();
}

/// A registry file with the given pid and heartbeat, on the caller's stack.
fn instanceJson(buf: []u8, pid: i32, last_beat_ms: i64) ![]const u8 {
    return std.fmt.bufPrint(buf, "{{\"v\":1,\"pid\":{d},\"last_beat\":{d}}}", .{ pid, last_beat_ms });
}

fn exists(io: std.Io, path: []const u8) bool {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/').?;
    const dir_path = path[0..slash];
    var d = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return false;
    defer d.close(io);
    _ = d.statFile(io, path[slash + 1 ..], .{}) catch return false;
    return true;
}

/// Sandbox: its own tree under /tmp, so a test can never touch the repo.
const Sandbox = struct {
    threaded: std.Io.Threaded,
    io: std.Io,
    base: []const u8,
    sessions: []const u8,
    instances: []const u8,
    config: []const u8,

    fn init(name: []const u8) !Sandbox {
        var threaded = std.Io.Threaded.init(testing.allocator, .{});
        errdefer threaded.deinit();
        const io = threaded.io();
        const base = try std.fmt.allocPrint(testing.allocator, "/tmp/zode-clean-test/{s}", .{name});
        errdefer testing.allocator.free(base);
        std.Io.Dir.cwd().deleteTree(io, base) catch {};
        try std.Io.Dir.cwd().createDirPath(io, base);
        const sessions = try std.fmt.allocPrint(testing.allocator, "{s}/sessions", .{base});
        errdefer testing.allocator.free(sessions);
        const instances = try std.fmt.allocPrint(testing.allocator, "{s}/.git/zode/inst", .{base});
        errdefer testing.allocator.free(instances);
        const config = try std.fmt.allocPrint(testing.allocator, "{s}/config", .{base});
        errdefer testing.allocator.free(config);
        try std.Io.Dir.cwd().createDirPath(io, sessions);
        try std.Io.Dir.cwd().createDirPath(io, instances);
        try std.Io.Dir.cwd().createDirPath(io, config);
        return .{
            .threaded = threaded,
            .io = io,
            .base = base,
            .sessions = sessions,
            .instances = instances,
            .config = config,
        };
    }

    fn deinit(self: *Sandbox) void {
        std.Io.Dir.cwd().deleteTree(self.io, self.base) catch {};
        self.threaded.deinit();
        testing.allocator.free(self.config);
        testing.allocator.free(self.instances);
        testing.allocator.free(self.sessions);
        testing.allocator.free(self.base);
    }

    fn roots(self: *const Sandbox) Roots {
        return .{ .sessions = self.sessions, .instances = self.instances, .config = self.config };
    }

    fn path(self: *const Sandbox, buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
        _ = self;
        return std.fmt.bufPrint(buf, fmt, args) catch unreachable;
    }
};

const now = 1_800_000_000; // a fixed "now" so the age buckets do not drift

test "scan: the dry run deletes NOTHING" {
    var sb = try Sandbox.init("dry");
    defer sb.deinit();

    var b: [256]u8 = undefined;
    try writeFileAt(sb.io, sb.path(&b, "{s}/zode-empty.jsonl", .{sb.sessions}), "");
    try writeFileAt(sb.io, sb.path(&b, "{s}/zode-full.jsonl", .{sb.sessions}), "{}\n");

    var rep = try scan(testing.allocator, sb.io, .{ .roots = sb.roots(), .now_secs = now });
    defer rep.deinit();

    try testing.expectEqual(@as(usize, 1), rep.count(.empty_session));
    // This is the whole point of a dry run: it found the file and left it there.
    try testing.expect(exists(sb.io, sb.path(&b, "{s}/zode-empty.jsonl", .{sb.sessions})));
}

test "apply: deletes ONLY the 0-byte files" {
    var sb = try Sandbox.init("apply");
    defer sb.deinit();

    var b: [256]u8 = undefined;
    try writeFileAt(sb.io, sb.path(&b, "{s}/zode-a.jsonl", .{sb.sessions}), "");
    try writeFileAt(sb.io, sb.path(&b, "{s}/zode-b.jsonl", .{sb.sessions}), "");
    // 1 byte: the boundary that separates "empty" from "almost empty". If this
    // one goes, the rule is a size test with a wrong limit and not a 0 test.
    try writeFileAt(sb.io, sb.path(&b, "{s}/zode-one.jsonl", .{sb.sessions}), "x");
    try writeFileAt(sb.io, sb.path(&b, "{s}/zode-full.jsonl", .{sb.sessions}), "{\"a\":1}\n");

    var rep = try scan(testing.allocator, sb.io, .{ .roots = sb.roots(), .now_secs = now });
    defer rep.deinit();

    const n = try apply(sb.io, &rep, sb.roots());
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expect(!exists(sb.io, sb.path(&b, "{s}/zode-a.jsonl", .{sb.sessions})));
    try testing.expect(!exists(sb.io, sb.path(&b, "{s}/zode-b.jsonl", .{sb.sessions})));
    try testing.expect(exists(sb.io, sb.path(&b, "{s}/zode-one.jsonl", .{sb.sessions})));
    try testing.expect(exists(sb.io, sb.path(&b, "{s}/zode-full.jsonl", .{sb.sessions})));
}

test "clean NEVER touches auth.json or permissions.json, not even with apply" {
    var sb = try Sandbox.init("protected");
    defer sb.deinit();

    var b: [256]u8 = undefined;
    try writeFileAt(sb.io, sb.path(&b, "{s}/auth.json", .{sb.config}), "{\"opencode\":\"sk-REAL\"}");
    try writeFileAt(sb.io, sb.path(&b, "{s}/permissions.json", .{sb.config}), "{}");

    var rep = try scan(testing.allocator, sb.io, .{ .roots = sb.roots(), .now_secs = now });
    defer rep.deinit();

    try testing.expectEqual(@as(usize, 0), rep.deletable());
    _ = try apply(sb.io, &rep, sb.roots());

    // A lost key is a 401 with no explanation, and the June fuzzer already
    // saved a pasted key into the real config. This is the test that says it
    // cannot happen again.
    try testing.expect(exists(sb.io, sb.path(&b, "{s}/auth.json", .{sb.config})));
    try testing.expect(exists(sb.io, sb.path(&b, "{s}/permissions.json", .{sb.config})));
}

test "clean NEVER touches .zig-cache, zig-out or zig-pkg" {
    // Even if one of them is somehow named like a session: the guard is on the
    // PATH, not on the file name, because a build artifact can be called
    // anything.
    try testing.expect(isProtected(".zig-cache/o"));
    try testing.expect(isProtected("zig-out/bin/zode"));
    try testing.expect(isProtected("zig-pkg/vaxis/src/vxfw/App.zig"));
    try testing.expect(isProtected("a/b/.zig-cache/x"));
    // Not a segment match: a directory that merely starts the same way is fine.
    try testing.expect(!isProtected("zig-out-mio/README.md"));
    try testing.expect(!isProtected(".zig-cachery/x"));
    try testing.expect(!isProtected("sessions/zode-1.jsonl"));
}

test "old sessions: they are listed but apply does NOT delete them" {
    var sb = try Sandbox.init("old");
    defer sb.deinit();

    var b: [256]u8 = undefined;
    const old = sb.path(&b, "{s}/zode-old.jsonl", .{sb.sessions});
    try writeFileAt(sb.io, old, "{\"a\":1}\n");
    // `now - 31 days` in mtime: without touching the file (which would need a
    // syscall per field) the age is expressed through the cutoff instead.
    const ancient = now - 40 * 24 * 60 * 60;
    var rep = try scan(testing.allocator, sb.io, .{
        .roots = sb.roots(),
        .now_secs = now,
        .old_after_secs = -1, // everything non-empty counts as old
    });
    defer rep.deinit();
    _ = ancient;

    try testing.expectEqual(@as(usize, 1), rep.count(.old_session));
    // Listed, counted, and deliberately left out of the deletion.
    try testing.expectEqual(@as(usize, 0), rep.deletable());
    const n = try apply(sb.io, &rep, sb.roots());
    try testing.expectEqual(@as(usize, 0), n);
    try testing.expect(exists(sb.io, old));
}

test "temporaries: a zode-*.tmp inside a zode directory is deleted" {
    var sb = try Sandbox.init("temps");
    defer sb.deinit();

    var b: [256]u8 = undefined;
    try writeFileAt(sb.io, sb.path(&b, "{s}/zode-cortado.tmp", .{sb.sessions}), "{partial");
    try writeFileAt(sb.io, sb.path(&b, "{s}/auth.json.tmp", .{sb.config}), "{partial");
    // Not a `.tmp`: nothing of zode's, so nothing of zode's to clean.
    try writeFileAt(sb.io, sb.path(&b, "{s}/notas.txt", .{sb.config}), "hola");

    var rep = try scan(testing.allocator, sb.io, .{ .roots = sb.roots(), .now_secs = now });
    defer rep.deinit();
    try testing.expectEqual(@as(usize, 2), rep.count(.own_temp));

    _ = try apply(sb.io, &rep, sb.roots());
    try testing.expect(!exists(sb.io, sb.path(&b, "{s}/zode-cortado.tmp", .{sb.sessions})));
    try testing.expect(!exists(sb.io, sb.path(&b, "{s}/auth.json.tmp", .{sb.config})));
    try testing.expect(exists(sb.io, sb.path(&b, "{s}/notas.txt", .{sb.config})));
}

test "instances: dead pid or stale heartbeat = garbage; a live one is left alone" {
    var sb = try Sandbox.init("inst");
    defer sb.deinit();

    var b: [256]u8 = undefined;
    // A pid that cannot exist: kill(pid, 0) answers ProcessNotFound.
    try writeFileAt(sb.io, sb.path(&b, "{s}/999999.json", .{sb.instances}),
        \\{"v":1,"pid":999999,"last_beat":1800000000000}
    );
    // Alive (our own pid) but the heartbeat stopped 10 minutes ago.
    const me = std.os.linux.getpid();
    const dead_path = sb.path(&b, "{s}/{d}.json", .{ sb.instances, me });
    var jb: [128]u8 = undefined;
    try writeFileAt(sb.io, dead_path, try instanceJson(&jb, me, (now - 600) * 1000));
    // Alive and beating right now: hands off. Its path needs its OWN buffer:
    // `sb.path` writes into the one it is given, so a second call would
    // overwrite the first slice and the test would then check the wrong file
    // against the wrong expectation.
    var b2: [256]u8 = undefined;
    const live_path = sb.path(&b2, "{s}/{d}b.json", .{ sb.instances, me });
    var jb2: [128]u8 = undefined;
    try writeFileAt(sb.io, live_path, try instanceJson(&jb2, me, (now - 1) * 1000));

    var rep = try scan(testing.allocator, sb.io, .{ .roots = sb.roots(), .now_secs = now });
    defer rep.deinit();
    try testing.expectEqual(@as(usize, 2), rep.count(.stale_instance));

    _ = try apply(sb.io, &rep, sb.roots());
    try testing.expect(!exists(sb.io, sb.path(&b, "{s}/999999.json", .{sb.instances})));
    try testing.expect(!exists(sb.io, dead_path));
    try testing.expect(exists(sb.io, live_path));
}

test "instances: JSON that cannot be parsed is cleaned, one from a newer version is not" {
    var sb = try Sandbox.init("inst-json");
    defer sb.deinit();

    var b: [256]u8 = undefined;
    try writeFileAt(sb.io, sb.path(&b, "{s}/a.json", .{sb.instances}), "{no json at all");
    try writeFileAt(sb.io, sb.path(&b, "{s}/c.json", .{sb.instances}), "{\"v\":1,\"pid\":");
    // v=2 is a NEWER zode. Not understanding it is not a reason to delete: the
    // documented rule is "ignore what you do not know".
    try writeFileAt(sb.io, sb.path(&b, "{s}/d.json", .{sb.instances}), "{\"v\":2,\"pid\":999999}");

    var rep = try scan(testing.allocator, sb.io, .{ .roots = sb.roots(), .now_secs = now });
    defer rep.deinit();
    try testing.expectEqual(@as(usize, 2), rep.count(.stale_instance));
    _ = try apply(sb.io, &rep, sb.roots());
    try testing.expect(!exists(sb.io, sb.path(&b, "{s}/c.json", .{sb.instances})));
    try testing.expect(exists(sb.io, sb.path(&b, "{s}/d.json", .{sb.instances})));
}

test "missing sessions/: it says so and does NOT create it" {
    var sb = try Sandbox.init("nosessions");
    defer sb.deinit();
    std.Io.Dir.cwd().deleteTree(sb.io, sb.sessions) catch {};

    var rep = try scan(testing.allocator, sb.io, .{ .roots = sb.roots(), .now_secs = now });
    defer rep.deinit();
    try testing.expect(rep.missing_sessions);
    try testing.expectEqual(@as(usize, 0), rep.items.len);
    // A cleanup command that creates the directory it was asked to clean is
    // strange; one that does not notice it is missing is worse.
    try testing.expect(!exists(sb.io, sb.sessions));
}

test "with no git or config roots, scan does not fail and invents no directories" {
    var sb = try Sandbox.init("bare");
    defer sb.deinit();

    var b: [256]u8 = undefined;
    try writeFileAt(sb.io, sb.path(&b, "{s}/zode-e.jsonl", .{sb.sessions}), "");

    var rep = try scan(testing.allocator, sb.io, .{
        .roots = .{ .sessions = sb.sessions, .instances = null, .config = null },
        .now_secs = now,
    });
    defer rep.deinit();
    try testing.expectEqual(@as(usize, 1), rep.count(.empty_session));
    try testing.expectEqual(@as(usize, 1), try apply(sb.io, &rep, .{ .sessions = sb.sessions }));
}

test "the report sorts by bucket, so the numbers come out grouped" {
    var sb = try Sandbox.init("order");
    defer sb.deinit();

    var b: [256]u8 = undefined;
    try writeFileAt(sb.io, sb.path(&b, "{s}/zode-e.jsonl", .{sb.sessions}), "");
    try writeFileAt(sb.io, sb.path(&b, "{s}/z.json.tmp", .{sb.config}), "x");
    try writeFileAt(sb.io, sb.path(&b, "{s}/888888.json", .{sb.instances}), "{\"v\":1,\"pid\":888888}");

    var rep = try scan(testing.allocator, sb.io, .{ .roots = sb.roots(), .now_secs = now });
    defer rep.deinit();
    try testing.expectEqual(@as(usize, 3), rep.items.len);
    try testing.expectEqual(Bucket.empty_session, rep.items[0].bucket);
    try testing.expectEqual(Bucket.own_temp, rep.items[1].bucket);
    try testing.expectEqual(Bucket.stale_instance, rep.items[2].bucket);
}

test "instanceDir: with .git as a DIRECTORY, and with no repo, it invents nothing" {
    var sb = try Sandbox.init("gitdir");
    defer sb.deinit();

    // The Sandbox already has `base/.git/zode/inst` (that is the instances root
    // it hands to `scan`), so the "not a repo" half needs a directory of its
    // own: point it at `base/sessions`, which has no `.git` above it.
    var bare = try std.Io.Dir.cwd().openDir(sb.io, sb.sessions, .{});
    defer bare.close(sb.io);
    try testing.expectEqual(@as(?[]u8, null), try instanceDirIn(testing.allocator, sb.io, bare));

    // And with `.git` as a directory (the main worktree) the registry is right
    // under it: invisible to `git status`, and gone with `rm -rf .git`.
    var base = try std.Io.Dir.cwd().openDir(sb.io, sb.base, .{});
    defer base.close(sb.io);
    const got = try instanceDirIn(testing.allocator, sb.io, base);
    defer if (got) |g| testing.allocator.free(g);
    try testing.expectEqualStrings(".git/zode/inst", got.?);
}

test "parseGitdirPointer: the pointer of a worktree, which is the case that matters" {
    // Two zodes in two worktrees must NOT end up in the same registry: that is
    // the whole isolation story, and it hangs on this one line of parsing.
    const a = try parseGitdirPointer(testing.allocator, "gitdir: /repo/.git/worktrees/wt-a\n");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("/repo/.git/worktrees/wt-a", a);

    // Relative pointer, and the CR that a Windows-authored file brings.
    const b = try parseGitdirPointer(testing.allocator, "gitdir: ../.git/worktrees/wt-b\r\n");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("./../.git/worktrees/wt-b", b);

    try testing.expectError(error.NotAGitdir, parseGitdirPointer(testing.allocator, "not a pointer"));
    try testing.expectError(error.NotAGitdir, parseGitdirPointer(testing.allocator, "gitdir:   "));
}
