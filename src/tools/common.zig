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

pub const max_tool_output = 16 * 1024; // output budget per tool

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
    const skip = [_][]const u8{ ".git", "node_modules", ".zig-cache", "zig-out", ".cache", "target", "dist", "build" };
    for (skip) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return name.len > 0 and name[0] == '.';
}
