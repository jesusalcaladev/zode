//! Discovery of output styles on disk, and the loader for the `style` tool.
//!
//! Split from `outputstyles.zig` on purpose: that file is pure and tested with
//! fixtures, this one touches the filesystem and cannot be.
//!
//! Search order is project-first with SHADOWING, not merging.
//! Bundled styles are appended AFTER on-disk styles so they can be shadowed.

const std = @import("std");
const styles = @import("outputstyles.zig");
const bundled = @import("bundled_outputstyles.zig");

const store = @This();

pub const Loader = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    env: ?*const std.process.Environ.Map,
    project_dir: []const u8 = styles.project_dir,
    repo_root: ?[]const u8 = null,
    /// Absolute user root. When null the root is derived from `$HOME`. Tests set
    /// it so shadowing can be exercised without touching the real home.
    user_dir: ?[]const u8 = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map) Loader {
        return .{ .gpa = gpa, .io = io, .env = env };
    }

    pub fn roots(self: *Loader, bufs: *[max_roots][std.fs.max_path_bytes]u8, paths: *[max_roots][]const u8) usize {
        var n: usize = 0;

        // project_dir is already set to absolute path by the caller (stylesLoader)
        if (self.project_dir.len > 0) {
            @memcpy(bufs[n][0..self.project_dir.len], self.project_dir);
            paths[n] = bufs[n][0..self.project_dir.len];
            n += 1;
        }

        if (self.repo_root) |root| {
            const pr = std.fmt.bufPrint(&bufs[n], "{s}/{s}", .{ root, styles.project_dir }) catch "";
            paths[n] = pr;
            n += 1;
        }

        if (self.user_dir) |u| {
            if (u.len > 0) {
                @memcpy(bufs[n][0..u.len], u);
                paths[n] = bufs[n][0..u.len];
                n += 1;
            }
        } else if (self.env) |env| {
            const home = env.get("HOME") orelse "";
            if (home.len > 0) {
                const uh = std.fmt.bufPrint(&bufs[n], "{s}/{s}", .{ home, styles.user_subdir }) catch "";
                paths[n] = uh;
                n += 1;
            }
        }

        return n;
    }

    /// Whether the LAST root returned by `roots` is the user one.
    fn hasUserRoot(self: *Loader) bool {
        if (self.user_dir) |u| return u.len > 0;
        const env = self.env orelse return false;
        const home = env.get("HOME") orelse return false;
        return home.len > 0;
    }

    /// Walks disk roots and returns the entries, project first, deduplicated by
    /// name. Bundled styles are appended LAST, so any on-disk style shadows them.
    pub fn scan(self: *Loader, out: []styles.Entry, cap: usize) []styles.Entry {
        var n: usize = 0;

        var bufs: [max_roots][std.fs.max_path_bytes]u8 = undefined;
        var paths: [max_roots][]const u8 = undefined;
        const root_count = self.roots(&bufs, &paths);
        const user_root: ?usize = if (self.hasUserRoot() and root_count > 0) root_count - 1 else null;

        for (paths[0..root_count], 0..) |dir_path, root_idx| {
            if (dir_path.len == 0) continue;
            var d = std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch continue;
            defer d.close(self.io);

            var it = d.iterate();
            while (it.next(self.io) catch null) |entry| {
                if (n >= cap) return out[0..n];

                // Two layouts, both documented: `<name>.md` and `<name>/OUTPUT_STYLE.md`.
                var file_buf: [std.fs.max_path_bytes]u8 = undefined;
                var fallback_name: []const u8 = "";
                const file_path: []const u8 = switch (entry.kind) {
                    .directory => blk: {
                        if (entry.name.len == 0 or entry.name[0] == '.') continue;
                        if (!styles.validName(entry.name)) continue;
                        fallback_name = entry.name;
                        break :blk std.fmt.bufPrint(&file_buf, "{s}/{s}/{s}", .{
                            dir_path, entry.name, styles.filename,
                        }) catch continue;
                    },
                    .file => blk: {
                        const stem = styles.stemOf(entry.name) orelse continue;
                        fallback_name = stem;
                        break :blk std.fmt.bufPrint(&file_buf, "{s}/{s}", .{
                            dir_path, entry.name,
                        }) catch continue;
                    },
                    else => continue,
                };

                // Cheap pre-check: a name already claimed by a higher-precedence
                // root is not read at all.
                if (alreadyIn(out[0..n], fallback_name)) continue;

                var head: [8 * 1024]u8 = undefined;
                const text = readPrefix(self.io, file_path, &head) orelse continue;
                if (text.len == 0) continue;

                const fm = styles.splitFrontmatter(text);
                const meta = if (fm) |f| f.meta else styles.Meta{};
                const name = styles.nameFor(meta, fallback_name);

                if (alreadyIn(out[0..n], name)) continue;

                const name_copy = self.gpa.dupe(u8, name) catch continue;
                errdefer self.gpa.free(name_copy);
                const desc_copy = self.gpa.dupe(u8, meta.description) catch {
                    self.gpa.free(name_copy);
                    continue;
                };
                errdefer self.gpa.free(desc_copy);
                const path_copy = self.gpa.dupe(u8, file_path) catch {
                    self.gpa.free(name_copy);
                    self.gpa.free(desc_copy);
                    continue;
                };
                errdefer self.gpa.free(path_copy);

                out[n] = .{
                    .name = name_copy,
                    .description = desc_copy,
                    .path = path_copy,
                    .body = null,
                    .source = if (user_root == root_idx) .user else .project,
                    .keep_coding_instructions = meta.keep_coding_instructions,
                };
                n += 1;
            }
        }

        // The styles compiled into the binary. Appended after disk so a project
        // or user style with the same name wins.
        for (bundled.bundled_styles) |b| {
            if (n >= cap) break;
            if (alreadyIn(out[0..n], b.name)) continue;
            // The name is allocated like the on-disk ones: every free path in the
            // app (and in tests) frees `name`, `description` and `path` uniformly.
            const name_copy = self.gpa.dupe(u8, b.name) catch continue;
            errdefer self.gpa.free(name_copy);
            const path = std.fmt.allocPrint(self.gpa, "bundled://{s}", .{b.name}) catch {
                self.gpa.free(name_copy);
                continue;
            };
            errdefer self.gpa.free(path);
            const desc_copy = self.gpa.dupe(u8, b.description) catch {
                self.gpa.free(name_copy);
                self.gpa.free(path);
                continue;
            };
            errdefer self.gpa.free(desc_copy);
            out[n] = .{
                .name = name_copy,
                .description = desc_copy,
                .path = path,
                .body = b.body,
                .source = .bundled,
                .keep_coding_instructions = b.keep_coding_instructions,
            };
            n += 1;
        }

        return out[0..n];
    }

    /// The body of a style, framed for the model. Writes into `out` and returns a slice of it.
    pub fn load(
        self: *Loader,
        entry: styles.Entry,
        args: ?[]const u8,
        out: []u8,
    ) ?[]const u8 {
        // Bundled styles are served from the embedded data.
        if (std.mem.startsWith(u8, entry.path, "bundled://")) {
            const name = entry.path["bundled://".len..];
            const bundled_style = bundled.getBundled(name) orelse return null;
            return styles.formatStyle(bundled_style.name, bundled_style.description, bundled_style.body, out);
        }

        const text = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            entry.path,
            self.gpa,
            .limited(styles.max_body),
        ) catch return null;
        defer self.gpa.free(text);
        const fm = styles.splitFrontmatter(text);
        const body = if (fm) |f| f.body else text;
        // Substitute $ARGUMENTS if args provided
        if (args) |a| {
            const trimmed = std.mem.trim(u8, a, " \t\r\n");
            if (trimmed.len > 0) {
                var buf: [8192]u8 = undefined;
                const substituted = bundled.substituteArguments(body, trimmed, &buf);
                return styles.formatStyle(entry.name, entry.description, substituted, out);
            }
        }
        return styles.formatStyle(entry.name, entry.description, body, out);
    }
};

fn alreadyIn(list: []const styles.Entry, name: []const u8) bool {
    for (list) |e| {
        if (std.mem.eql(u8, e.name, name)) return true;
    }
    return false;
}

/// Reads the HEAD of a file into `out`, stopping at the end of the frontmatter.
fn readPrefix(io: std.Io, path: []const u8, out: []u8) ?[]const u8 {
    const full = std.Io.Dir.cwd().readFileAlloc(io, path, std.heap.page_allocator, .limited(max_scan)) catch return null;
    defer std.heap.page_allocator.free(full);
    const n = @min(full.len, out.len);
    @memcpy(out[0..n], full[0..n]);
    return out[0..n];
}

/// Ceiling on what discovery reads from an `OUTPUT_STYLE.md`.
pub const max_scan = 32 * 1024;

/// How many roots `Loader.roots` can return: two in the cwd (+1 repo root), one user.
pub const max_roots = 5;

/// Max path length stored in a stamp.
pub const stamp_path_max = 512;

/// The `mtime` + size of one path, for deciding whether a cached list is stale.
pub const Stamp = struct {
    path: [stamp_path_max]u8 = undefined,
    path_len: u16 = 0,
    mtime_ns: i128 = 0,
    size: u64 = 0,
    exists: bool = false,

    pub fn pathOf(self: *const Stamp) []const u8 {
        return self.path[0..self.path_len];
    }

    pub fn sameAs(self: *const Stamp, other: *const Stamp) bool {
        if (self.exists != other.exists) return false;
        if (!self.exists) return true; // both missing: unchanged
        if (self.mtime_ns != other.mtime_ns) return false;
        return self.size == other.size;
    }
};

/// `true` when `path` can be stored (fits in a stamp) and the stamp was filled.
pub fn stampPath(io: std.Io, path: []const u8, out: *Stamp) bool {
    out.* = .{};
    if (path.len == 0 or path.len > stamp_path_max) return false;
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch {
        out.exists = false;
        return true;
    };
    @memcpy(out.path[0..path.len], path);
    out.path_len = @intCast(path.len);
    out.mtime_ns = st.mtime.nanoseconds;
    out.size = st.size;
    out.exists = true;
    return true;
}
/// Frees the names, descriptions and paths `scan` allocated. `body` is never
/// owned: it is either null or the embedded copy.
pub fn deinitEntries(gpa: std.mem.Allocator, list: []styles.Entry) void {
    for (list) |e| {
        gpa.free(e.name);
        gpa.free(e.description);
        gpa.free(e.path);
    }
}

fn findEntry(list: []const styles.Entry, name: []const u8) ?styles.Entry {
    for (list) |e| if (std.mem.eql(u8, e.name, name)) return e;
    return null;
}

test "scan: project shadows repo and user, both layouts and bundled styles are found" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Project root: `project_dir` IS the styles directory.
    try tmp.dir.createDirPath(io, "proj/mine");
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/mine/OUTPUT_STYLE.md", .data =
        \\---
        \\name: mine
        \\description: from project
        \\---
        \\PROJECT MINE
    });

    // Repository root: the same name loses; `repoonly` comes from here.
    try tmp.dir.createDirPath(io, "repo/.zode/output-styles/mine");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.zode/output-styles/mine/OUTPUT_STYLE.md", .data =
        \\---
        \\name: mine
        \\description: from repo
        \\---
        \\REPO MINE
    });
    try tmp.dir.createDirPath(io, "repo/.zode/output-styles/repoonly");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.zode/output-styles/repoonly/OUTPUT_STYLE.md", .data = "REPO ONLY\n" });

    // User root: flat files. `useronly` uses the hyphenated key, which has to be
    // understood; `learning` shadows the bundled style of the same name.
    try tmp.dir.createDirPath(io, "user");
    try tmp.dir.writeFile(io, .{ .sub_path = "user/useronly.md", .data =
        \\---
        \\name: useronly
        \\description: from user
        \\keep-coding-instructions: false
        \\---
        \\USER ONLY BODY
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "user/learning.md", .data = "MY LEARNING\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "user/README.md", .data = "not a style\n" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    var path_bufs: [3][std.fs.max_path_bytes]u8 = undefined;
    const proj = try std.fmt.bufPrint(&path_bufs[0], "{s}/proj", .{root});
    const repo = try std.fmt.bufPrint(&path_bufs[1], "{s}/repo", .{root});
    const user = try std.fmt.bufPrint(&path_bufs[2], "{s}/user", .{root});

    var loader = Loader.init(a, io, null);
    loader.project_dir = proj;
    loader.repo_root = repo;
    loader.user_dir = user;

    var buf: [16]styles.Entry = undefined;
    const found = loader.scan(&buf, buf.len);
    defer deinitEntries(a, found);

    // Project first, then repo, then user, then bundled last.
    const names: []const []const u8 = &.{ "mine", "repoonly", "useronly", "learning", "default", "explanatory" };
    try std.testing.expectEqual(names.len, found.len);
    for (names, found) |want, got| try std.testing.expectEqualStrings(want, got.name);

    // Shadowing, not merging: the project's `mine` wins whole, description included.
    try std.testing.expectEqualStrings("from project", findEntry(found, "mine").?.description);

    const useronly = findEntry(found, "useronly").?;
    try std.testing.expect(useronly.source == .user);
    try std.testing.expect(!useronly.keep_coding_instructions); // hyphenated key parsed
    try std.testing.expect(std.mem.endsWith(u8, useronly.path, "user/useronly.md"));

    // A flat user file shadows a bundled style of the same name.
    const learning = findEntry(found, "learning").?;
    try std.testing.expect(learning.source == .user);
    try std.testing.expect(std.mem.endsWith(u8, learning.path, "user/learning.md"));

    const default_style = findEntry(found, "default").?;
    try std.testing.expect(default_style.source == .bundled);
    try std.testing.expect(std.mem.startsWith(u8, default_style.path, "bundled://"));
    try std.testing.expect(default_style.body != null);

    // `README.md` is not a style.
    try std.testing.expect(findEntry(found, "README") == null);

    // The body is loaded on demand, for both a flat file and a bundled style.
    var body_buf: [4096]u8 = undefined;
    const body = loader.load(useronly, null, &body_buf).?;
    try std.testing.expect(std.mem.indexOf(u8, body, "USER ONLY BODY") != null);
    const bundled_body = loader.load(default_style, null, &body_buf).?;
    try std.testing.expect(std.mem.indexOf(u8, bundled_body, "Default Output Style") != null);
}

test "scan: two directories with the same frontmatter name are deduplicated" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "styles/one");
    try tmp.dir.writeFile(io, .{ .sub_path = "styles/one/OUTPUT_STYLE.md", .data =
        \\---
        \\name: same
        \\description: first
        \\---
        \\ONE
    });
    try tmp.dir.createDirPath(io, "styles/two");
    try tmp.dir.writeFile(io, .{ .sub_path = "styles/two/OUTPUT_STYLE.md", .data =
        \\---
        \\name: same
        \\description: second
        \\---
        \\TWO
    });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const styles_dir = try std.fmt.bufPrint(&path_buf, "{s}/styles", .{root});

    var loader = Loader.init(a, io, null);
    loader.project_dir = styles_dir;

    var buf: [16]styles.Entry = undefined;
    const found = loader.scan(&buf, buf.len);
    defer deinitEntries(a, found);

    var same: usize = 0;
    for (found) |e| if (std.mem.eql(u8, e.name, "same")) {
        same += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), same);
}
