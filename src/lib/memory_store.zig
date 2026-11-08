//! Persistence and discovery for per-project memory (Phase 11).
//!
//! Store location: `<project-root>/.zode/memory/entries/*.md`.
//! Precedence/discovery is repo-root aware: when launched from a subdirectory,
//! the canonical per-project store is still found at the repository root (same
//! class of fix as skills/project root detection). A cwd-local `.zode/memory`
//! is accepted when no repo root is known.

const std = @import("std");
const memory = @import("memory.zig");
const project = @import("project.zig");

pub const project_dir = ".zode/memory";
pub const entries_dir = "entries";
pub const pending_dir = "pending";

pub const Store = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Resolved store root (`.../.zode/memory`), or empty when none found.
    root: []u8 = &.{},
    /// Where the store came from (for diagnostics/precedence).
    source: Source = .none,

    pub const Source = enum { repo_root, cwd, explicit, none };

    pub fn deinit(self: *Store) void {
        if (self.root.len > 0) self.gpa.free(self.root);
        self.root = &.{};
    }

    /// Discovers the per-project memory store. `repo_root` is the git root (may
    /// be null outside a repo or when cwd is the root). Precedence: repo root
    /// wins for the canonical project store; cwd is used when repo root is null
    /// or equal (and we still look there).
    pub fn discover(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, repo_root: ?[]const u8) !Store {
        if (repo_root) |root| {
            if (root.len > 0) {
                const p = try join(gpa, root, project_dir);
                if (dirExists(io, p)) return .{ .gpa = gpa, .io = io, .root = p, .source = .repo_root };
                gpa.free(p);
            }
        }
        if (cwd.len > 0) {
            // If cwd differs from repo root we already checked root; checking cwd
            // again only when it might be the right place.
            const same_as_root = if (repo_root) |r| std.mem.eql(u8, r, cwd) else false;
            if (!same_as_root) {
                const p = try join(gpa, cwd, project_dir);
                if (dirExists(io, p)) return .{ .gpa = gpa, .io = io, .root = p, .source = .cwd };
                gpa.free(p);
            }
        }
        return .{ .gpa = gpa, .io = io, .root = &.{}, .source = .none };
    }

    /// Returns the canonical store root for a project (repo root preferred),
    /// creating it if `create` is true. Used when the agent maintains the store.
    pub fn resolveForProject(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, repo_root: ?[]const u8, create: bool) !Store {
        const s = try discover(gpa, io, cwd, repo_root);
        if (s.root.len > 0 or !create) return s;
        const base = if (repo_root) |r| (if (r.len > 0) r else cwd) else cwd;
        const p = try join(gpa, base, project_dir);
        errdefer gpa.free(p);
        std.Io.Dir.cwd().createDirPath(io, p) catch {};
        return .{ .gpa = gpa, .io = io, .root = p, .source = if (repo_root != null) .repo_root else .cwd };
    }

    pub fn entriesPath(self: *const Store, buf: []u8) ?[]const u8 {
        if (self.root.len == 0) return null;
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ self.root, entries_dir }) catch null;
    }

    pub fn pendingPath(self: *const Store, buf: []u8) ?[]const u8 {
        if (self.root.len == 0) return null;
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ self.root, pending_dir }) catch null;
    }

    pub fn loadAll(self: *const Store, out: []memory.Entry) ![]memory.Entry {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir_path = self.entriesPath(&buf) orelse return out[0..0];
        var dir = std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch return out[0..0];
        defer dir.close(self.io);

        var count: usize = 0;
        var it = dir.iterate();
        while (it.next(self.io) catch null) |ent| {
            if (count >= out.len) break;
            if (ent.kind != .file) continue;
            if (!std.mem.endsWith(u8, ent.name, ".md")) continue;
            var fp: [std.fs.max_path_bytes]u8 = undefined;
            const full = std.fmt.bufPrint(&fp, "{s}/{s}", .{ dir_path, ent.name }) catch continue;
            const data = std.Io.Dir.cwd().readFileAlloc(self.io, full, self.gpa, .limited(memory.max_body_bytes * 4)) catch continue;
            defer self.gpa.free(data);
            const parsed = memory.parseMemory(data);
            // Own stable copies of key fields for callers that keep the list.
            // `parsed` slices point into `data`; dupe everything we keep.
            var e = memory.Entry{
                .id = self.gpa.dupe(u8, parsed.id) catch "",
                .title = self.gpa.dupe(u8, parsed.title) catch "",
                .tags = self.gpa.dupe(u8, parsed.tags) catch "",
                .body = self.gpa.dupe(u8, parsed.body) catch "",
                .path = self.gpa.dupe(u8, full) catch "",
                .created_at = "",
                .updated_at = "",
                .evidence = "",
            };
            // If dupes failed partially, keep what we have; never point into freed `data`.
            if (e.title.len == 0 and parsed.title.len > 0) e.title = "";
            out[count] = e;
            count += 1;
        }
        // Stable order by id/title for deterministic tests and listings.
        std.mem.sort(memory.Entry, out[0..count], {}, struct {
            fn lt(_: void, a: memory.Entry, b: memory.Entry) bool {
                return std.mem.lessThan(u8, if (a.id.len > 0) a.id else a.title, if (b.id.len > 0) b.id else b.title);
            }
        }.lt);
        return out[0..count];
    }

    pub fn freeEntries(self: *const Store, entries: []memory.Entry) void {
        for (entries) |e| {
            if (e.id.len > 0) self.gpa.free(e.id);
            if (e.title.len > 0) self.gpa.free(e.title);
            if (e.tags.len > 0) self.gpa.free(e.tags);
            if (e.body.len > 0) self.gpa.free(e.body);
            if (e.path.len > 0) self.gpa.free(e.path);
            if (e.created_at.len > 0) self.gpa.free(e.created_at);
            if (e.updated_at.len > 0) self.gpa.free(e.updated_at);
            if (e.evidence.len > 0) self.gpa.free(e.evidence);
        }
    }

    pub fn ensureLayout(self: *const Store) !void {
        if (self.root.len == 0) return error.NoStore;
        std.Io.Dir.cwd().createDirPath(self.io, self.root) catch {};
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (self.entriesPath(&buf)) |p| std.Io.Dir.cwd().createDirPath(self.io, p) catch {};
        if (self.pendingPath(&buf)) |p| std.Io.Dir.cwd().createDirPath(self.io, p) catch {};
    }

    pub fn saveEntry(self: *const Store, id: []const u8, title: []const u8, tags: []const u8, evidence: []const u8, body: []const u8) !void {
        try self.ensureLayout();
        const data = try memory.renderEntry(self.gpa, id, title, tags, evidence, body);
        defer self.gpa.free(data);
        var name_buf: [256]u8 = undefined;
        const safe = sanitizeId(id, &name_buf);
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = self.entriesPath(&path_buf) orelse return error.NoStore;
        var file_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full = try std.fmt.bufPrint(&file_buf, "{s}/{s}.md", .{ path, safe });
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = full, .data = data });
        setPrivate(self.io, full);
    }

    pub fn savePending(self: *const Store, id: []const u8, title: []const u8, tags: []const u8, evidence: []const u8, body: []const u8) !void {
        try self.ensureLayout();
        const data = try memory.renderEntry(self.gpa, id, title, tags, evidence, body);
        defer self.gpa.free(data);
        var name_buf: [256]u8 = undefined;
        const safe = sanitizeId(id, &name_buf);
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = self.pendingPath(&path_buf) orelse return error.NoStore;
        var file_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full = try std.fmt.bufPrint(&file_buf, "{s}/{s}.md", .{ path, safe });
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = full, .data = data });
        setPrivate(self.io, full);
    }

    /// Approves a pending proposal by id: moves/copies it into entries. Returns
    /// true if a pending file was found and approved.
    pub fn approvePending(self: *const Store, id: []const u8) !bool {
        try self.ensureLayout();
        var name_buf: [256]u8 = undefined;
        const safe = sanitizeId(id, &name_buf);
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        var ebuf: [std.fs.max_path_bytes]u8 = undefined;
        var pf: [std.fs.max_path_bytes]u8 = undefined;
        var ef: [std.fs.max_path_bytes]u8 = undefined;
        const pp = self.pendingPath(&pbuf) orelse return false;
        const ep = self.entriesPath(&ebuf) orelse return false;
        const src = std.fmt.bufPrint(&pf, "{s}/{s}.md", .{ pp, safe }) catch return false;
        const dst = std.fmt.bufPrint(&ef, "{s}/{s}.md", .{ ep, safe }) catch return false;
        std.Io.Dir.rename(.cwd(), src, .cwd(), dst, self.io) catch {
            // Cross-dir rename quirks or missing file: fall back to copy+delete.
            const data = std.Io.Dir.cwd().readFileAlloc(self.io, src, self.gpa, .limited(memory.max_body_bytes * 4)) catch return false;
            defer self.gpa.free(data);
            std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = dst, .data = data }) catch return false;
            std.Io.Dir.cwd().deleteFile(self.io, src) catch {};
            setPrivate(self.io, dst);
            return true;
        };
        setPrivate(self.io, dst);
        return true;
    }
};

fn setPrivate(io: std.Io, path: []const u8) void {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return;
    defer file.close(io);
    file.setPermissions(io, @enumFromInt(0o600)) catch {};
}

fn dirExists(io: std.Io, path: []const u8) bool {
    var d = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

fn join(gpa: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ a, b });
}

fn sanitizeId(id: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    for (id) |c| {
        if (n >= buf.len) break;
        buf[n] = if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.') c else '-';
        n += 1;
    }
    if (n == 0) return "memory";
    return buf[0..n];
}

const testing = std.testing;

test "memory store discovery: repo root wins for a subdirectory launch" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "repo/.zode/memory/entries");
    try tmp.dir.createDirPath(testing.io, "repo/src");
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];
    var rb: [std.fs.max_path_bytes]u8 = undefined;
    var cb: [std.fs.max_path_bytes]u8 = undefined;
    const repo = try std.fmt.bufPrint(&rb, "{s}/repo", .{root});
    const cwd = try std.fmt.bufPrint(&cb, "{s}/repo/src", .{root});

    var s = try Store.discover(testing.allocator, testing.io, cwd, repo);
    defer s.deinit();
    try testing.expectEqual(Store.Source.repo_root, s.source);
    try testing.expect(std.mem.endsWith(u8, s.root, "/repo/.zode/memory"));
}

test "memory store discovery: cwd store found when no repo root" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "proj/.zode/memory/entries");
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];
    var cb: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.fmt.bufPrint(&cb, "{s}/proj", .{root});

    var s = try Store.discover(testing.allocator, testing.io, cwd, null);
    defer s.deinit();
    try testing.expectEqual(Store.Source.cwd, s.source);
}

test "memory store: save, load, and precedence-consistent discovery with temp root" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "r/src");
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];
    var rb: [std.fs.max_path_bytes]u8 = undefined;
    var cb: [std.fs.max_path_bytes]u8 = undefined;
    const repo = try std.fmt.bufPrint(&rb, "{s}/r", .{root});
    const cwd = try std.fmt.bufPrint(&cb, "{s}/r/src", .{root});

    var s = try Store.resolveForProject(testing.allocator, testing.io, cwd, repo, true);
    defer s.deinit();
    try s.saveEntry("auth-note", "Auth note", "auth", "providers.zig", "bearer tokens are used");

    var found = try Store.discover(testing.allocator, testing.io, cwd, repo);
    defer found.deinit();
    var buf: [32]memory.Entry = undefined;
    const entries = try found.loadAll(&buf);
    defer found.freeEntries(entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("auth-note", entries[0].id);
    try testing.expect(std.mem.indexOf(u8, entries[0].body, "bearer") != null);
}

test "memory store: pending proposal requires approval to enter entries" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "p");
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];
    var cb: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.fmt.bufPrint(&cb, "{s}/p", .{root});

    var s = try Store.resolveForProject(testing.allocator, testing.io, cwd, null, true);
    defer s.deinit();
    try s.savePending("prop1", "Proposed", "", "", "candidate");

    var buf: [8]memory.Entry = undefined;
    var entries = try s.loadAll(&buf);
    try testing.expectEqual(@as(usize, 0), entries.len);
    s.freeEntries(entries);

    try testing.expect(try s.approvePending("prop1"));
    entries = try s.loadAll(&buf);
    defer s.freeEntries(entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("prop1", entries[0].id);
}
