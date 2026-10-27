/// Helpers shared by more than one tool.
///
/// They were private inside a single 1800-line file, which is how they can reach
/// from `read.zig` to `grep.zig`. `walkZig` is here for the same reason: it is the
/// `.zig` file walker `glob` uses to answer a bare `**/*.zig` pattern, and `grep`
/// uses it to walk the project when the native `rg` is not there.
const std = @import("std");

pub fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

pub fn getInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    if (v != .integer) return null;
    return v.integer;
}

/// `true`, `false`, or absent. A STRING `"true"` counts: models emit both, and
/// rejecting the string form makes `run_in_background` silently false, which
/// looks like the tool ignoring the flag.
pub fn getBool(obj: std.json.ObjectMap, key: []const u8) bool {
    const v = obj.get(key) orelse return false;
    return switch (v) {
        .bool => |b| b,
        .string => |s| std.ascii.eqlIgnoreCase(s, "true"),
        .integer => |i| i != 0,
        else => false,
    };
}

/// The per-tool output budget, in bytes. Defaults to 1 MB.
///
/// Read once at startup from `ZODE_MAX_TOOL_OUTPUT`, which accepts bare numbers
/// and the suffixes `K`, `M`, `G` (case-insensitive, e.g. `5M`, `1G`, `512K`).
///
/// There is also a hard cap (`max_tool_output_hard_cap`) so a runaway command
/// cannot exhaust memory: if the env value exceeds it, the cap wins.
pub var max_tool_output: usize = 1 * 1024 * 1024;
pub var max_tool_output_hard_cap: usize = 10 * 1024 * 1024;

/// Read `ZODE_MAX_TOOL_OUTPUT` from the environment and install it as the
/// per-tool budget. Safe to call once at startup; calling it again overwrites
/// the previous value (which is what tests do).
pub fn initMaxToolOutput(env: ?*const std.process.Environ.Map) void {
    const raw = if (env) |e| e.get("ZODE_MAX_TOOL_OUTPUT") else null;
    const val = raw orelse return;
    if (val.len == 0) return;

    // Parse an optional numeric suffix: 5M, 1G, 512K, 1024, etc.
    var digits: usize = 0;
    while (digits < val.len and std.ascii.isDigit(val[digits])) : (digits += 1) {}

    const num_str = val[0..digits];
    const suffix = std.mem.trim(u8, val[digits..], " ");

    const n = std.fmt.parseInt(usize, num_str, 10) catch return;

    var mult: usize = 1;
    if (suffix.len > 0) {
        const s = std.ascii.toLower(suffix[0]);
        if (s == 'k') {
            mult = 1024;
        } else if (s == 'm') {
            mult = 1024 * 1024;
        } else if (s == 'g') {
            mult = 1024 * 1024 * 1024;
        } else {
            return; // unknown suffix: ignore, keep the default
        }
    }

    var wanted = n * mult;
    if (wanted > max_tool_output_hard_cap) wanted = max_tool_output_hard_cap;
    max_tool_output = wanted;
}

pub const Walker = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    stack: std.ArrayList([]const u8),
    current_dir: ?std.Io.Dir = null,
    current_iter: ?std.Io.Dir.Iterator = null,
    current_base: []const u8 = "",

    pub fn deinit(self: *Walker) void {
        for (self.stack.items) |p| self.arena.free(p);
        self.stack.deinit(self.arena);
    }

    /// Returns the path of the next file (caller frees with arena.free)
    pub fn next(self: *Walker) ?[]const u8 {
        while (true) {
            if (self.current_dir == null) {
                const next_dir = self.stack.pop() orelse return null;
                self.current_base = next_dir;
                self.current_dir = std.Io.Dir.cwd().openDir(self.io, next_dir, .{ .iterate = true }) catch {
                    self.arena.free(next_dir);
                    continue;
                };
                self.current_iter = self.current_dir.?.iterate();
                continue;
            }
            // Next entry of the current dir
            const entry = self.current_iter.?.next(self.io) catch null;
            if (entry) |e| {
                const full = if (std.mem.eql(u8, self.current_base, "."))
                    (self.arena.dupe(u8, e.name) catch continue)
                else
                    (std.fmt.allocPrint(self.arena, "{s}/{s}", .{ self.current_base, e.name }) catch continue);
                switch (e.kind) {
                    .directory => {
                        if (isSkippable(e.name)) {
                            self.arena.free(full);
                            continue;
                        }
                        self.stack.append(self.arena, full) catch self.arena.free(full);
                    },
                    .file => return full,
                    else => {
                        self.arena.free(full);
                        continue;
                    },
                }
            } else {
                // Dir exhausted
                if (self.current_base.len > 0) self.arena.free(self.current_base);
                self.current_dir.?.close(self.io);
                self.current_dir = null;
                self.current_iter = null;
            }
        }
    }
};

/// The project's own files, as `git` sees them: tracked PLUS untracked-but-not-ignored.
///
/// ## What this fixes, measured
///
/// `refs` and `rename` walked the tree with `walkAll`, and that walk has a file budget
/// (`symbols.max_files`) and no order worth trusting. In this repository it spent the
/// whole budget inside an ignored tree — a vendored copy of another project,
/// thousands of files, none of them ours — and answered **"no declaration in the
/// files searched"** for a symbol that is right there in `src/`. A tool that cannot
/// see the project's own code is not slow, it is blind, and it says so in a
/// sentence that reads like the symbol does not exist.
///
/// `git ls-files --cached --others --exclude-standard` is exactly the set of files the
/// user considers theirs: 336 here, against 2057 on disk, in 5 ms. It includes a file
/// the agent just wrote and has not staged (the reason a plain `--cached` would be
/// wrong), and it excludes the ignored trees (the vendored copy, `zig-pkg/`,
/// `sessions/`) the same way `rg` already does for `grep`.
///
/// Returns `null` when git cannot answer — not a repository, no git, a failure — and
/// the caller falls back to the walker, which is what a directory outside a repo needs.
pub fn gitFiles(io: std.Io, arena: std.mem.Allocator, subdir: []const u8) ?[]const []const u8 {
    const result = std.process.run(arena, io, .{
        // `-z`: NUL-separated, so a path with a newline or a quote in it survives.
        .argv = &.{ "git", "ls-files", "--cached", "--others", "--exclude-standard", "-z" },
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(2048),
        .reserve_amount = 4096,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    }) catch return null;
    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => return null,
    };
    if (code != 0 or result.stdout.len == 0) return null;

    // `git ls-files` names paths relative to the CWD, which is the same frame the
    // walker's paths are in, so the only thing left is to keep the ones under `subdir`.
    var base = subdir;
    const whole = base.len == 0 or std.mem.eql(u8, base, ".");
    if (!whole and std.mem.startsWith(u8, base, "./")) base = base[2..];

    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, result.stdout, 0);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        if (!whole) {
            if (!std.mem.startsWith(u8, entry, base)) continue;
            // A path SEGMENT boundary: `subdir: "a/b"` must not match `a/bc/d`.
            if (entry.len > base.len and entry[base.len] != '/') continue;
        }
        out.append(arena, entry) catch return null;
    }
    if (out.items.len == 0) return null;
    return out.items;
}

/// The files a symbol search should visit, from whichever source can answer.
pub const Files = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    list: []const []const u8 = &.{},
    idx: usize = 0,
    walker: ?Walker = null,

    /// The next path, in the arena's memory (an arena free is a no-op, which is what
    /// the callers already do with the result).
    pub fn next(self: *Files) ?[]const u8 {
        if (self.walker) |*w| return w.next();
        if (self.idx >= self.list.len) return null;
        const p = self.list[self.idx];
        self.idx += 1;
        return p;
    }

    pub fn deinit(self: *Files) void {
        if (self.walker) |*w| w.deinit();
    }
};

/// Git's file list when there is one, the tree walk otherwise.
///
/// One call site decides, so a new caller cannot accidentally get the blind version:
/// the fallback exists for a directory OUTSIDE a repository (a fixture in `/tmp`),
/// not as a second way of doing the same thing.
pub fn searchableFiles(io: std.Io, arena: std.mem.Allocator, subdir: []const u8) Files {
    if (gitFiles(io, arena, subdir)) |list| return .{ .io = io, .arena = arena, .list = list };
    return .{ .io = io, .arena = arena, .walker = walkAll(io, arena, subdir) catch null };
}

/// Walks EVERY file under `root`, of any extension.
///
/// The name says "all" because the walker was written for `glob`'s `**/*.zig`
/// and `refs` needs it for every language: a symbol in a `.py` is as real as one
/// in a `.zig`, and the tool that is supposed to be language-agnostic must not
/// stop at the extension.
pub fn walkAll(io: std.Io, arena: std.mem.Allocator, root: []const u8) !Walker {
    var w = Walker{
        .io = io,
        .arena = arena,
        .stack = .empty,
    };
    const root_copy = try arena.dupe(u8, root);
    try w.stack.append(arena, root_copy);
    return w;
}

pub fn walkZig(io: std.Io, arena: std.mem.Allocator, root: []const u8) !Walker {
    return walkAll(io, arena, root);
}

/// Directory names the walker never descends into.
///
/// It also skips anything starting with `.`, which is what keeps `.git` and
/// `.zig-cache` out of a `**/*.zig` without listing them.
pub fn isSkippable(name: []const u8) bool {
    // `zig-pkg` is this project's dependency cache and it is NOT skipped by the
    // leading-dot rule because it has no dot. It holds the vaxis, zigimg and uucode
    // checkouts: thousands of files, none of them the user's code. Without it in
    // the list, `glob`, `grep` and `refs` all walked it, and `refs` read every
    // file in it looking for a symbol.
    //
    // that belongs to another project. It is in the list for the same reason
    // `zig-pkg` is — a walk that descends into it costs seconds and finds
    // nothing that belongs to this one.
    const skip = [_][]const u8{ ".git", "node_modules", ".zig-cache", "zig-out", "zig-pkg", ".cache", "target", "dist", "build" };
    for (skip) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return name.len > 0 and name[0] == '.';
}

/// A string array field, or an empty slice when it is missing or not an array.
///
/// Empty means "none given", which for `git_add` means "everything that changed" — a
/// different meaning from "an empty list", and the two are not the same request. The
/// caller says which one it treats as what, in its own words.
pub fn getStrList(obj: std.json.ObjectMap, key: []const u8) []const []const u8 {
    const v = obj.get(key) orelse return &.{};
    if (v != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (v.array.items) |e| {
        if (e == .string) out.append(std.heap.page_allocator, e.string) catch break;
    }
    return out.items;
}
