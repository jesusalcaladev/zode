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
    path_buf: [std.fs.max_path_bytes]u8 = undefined,

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

        if (self.env) |env| {
            const home = env.get("HOME") orelse "";
            if (home.len > 0) {
                const uh = std.fmt.bufPrint(&bufs[n], "{s}/{s}", .{ home, styles.user_subdir }) catch "";
                paths[n] = uh;
                n += 1;
            }
        }

        return n;
    }

    /// Walks disk roots and returns the entries, project first, deduplicated by name.
    pub fn scan(self: *Loader, out: []styles.Entry, cap: usize) []styles.Entry {
        var n: usize = 0;

        var bufs: [max_roots][std.fs.max_path_bytes]u8 = undefined;
        var paths: [max_roots][]const u8 = undefined;
        const root_count = self.roots(&bufs, &paths);

        for (paths[0..root_count], 0..) |dir_path, root_idx| {
            if (dir_path.len == 0) continue;
            var d = std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch continue;
            defer d.close(self.io);

            var it = d.iterate();
            while (it.next(self.io) catch null) |entry| {
                if (n >= cap) return out[0..n];
                if (entry.kind != .directory) continue;
                if (entry.name.len == 0 or entry.name[0] == '.') continue;
                if (!styles.validName(entry.name)) continue;

                if (alreadyIn(out[0..n], entry.name)) continue;

                var file_buf: [std.fs.max_path_bytes]u8 = undefined;
                const file_path = std.fmt.bufPrint(&file_buf, "{s}/{s}/{s}", .{
                    dir_path, entry.name, styles.filename,
                }) catch continue;

                var head: [8 * 1024]u8 = undefined;
                const text = readPrefix(self.io, file_path, &head) orelse continue;
                if (text.len == 0) continue;

                const fm = styles.splitFrontmatter(text);
                const meta = if (fm) |f| f.meta else styles.Meta{};
                const name = styles.nameFor(meta, entry.name);

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

                // roots 0, 1, 2 are project variants (.project = enum index 0);
                // anything beyond is user (.user = enum index 1).
                const source = @as(styles.Source, @enumFromInt(@as(u8, if (root_idx <= 2) 0 else 1)));
                out[n] = .{
                    .name = name_copy,
                    .description = desc_copy,
                    .path = path_copy,
                    .body = null,
                    .source = source,
                    .keep_coding_instructions = meta.keep_coding_instructions,
                };
                n += 1;
            }
        }

        return out[0..n];
    }

    /// `<HOME>/.config`, or `null` when there is no HOME.
    fn joinHome(self: *Loader) ?[]const u8 {
        return self.userHome(&self.path_buf);
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