//! Discovery of skills on disk, and the loader for the `skill` tool.
//!
//! Split from `skills.zig` on purpose: that file is pure and tested with
//! fixtures, this one touches the filesystem and cannot be (a test that walks
//! `~/.config` is a test that passes or fails depending on whose machine it runs
//! on). What is here is the boring I/O; what is tested is there.
//!
//! Search order is project-first with SHADOWING, not merging: `.zode/skills/foo`
//! replaces `~/.config/zode/skills/foo` entirely. The reason is that a skill is
//! usually the answer to "how does THIS project want this done", and a global
//! default that half-overrides the project's own file is worse than not having
//! one.
//!
//! Four roots, not two: `.zode/skills` is this harness's own convention and
//! `.agents/skills` is the one shared with other agents, so a skill written for
//! one works in the other. Both are scanned in the cwd, and both are scanned again
//! in the repository root when zode was launched below it — which is the whole
//! reason `project.zig` exists.
//!
//! Bundled skills are appended AFTER on-disk skills so they can be shadowed.

const std = @import("std");
const skills = @import("skills.zig");
const bundled = @import("bundled_skills.zig");

const store = @This();

pub const Loader = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// `?*const std.process.Environ.Map` (optional) so a test can pass `null`
    /// instead of building a real environment.
    env: ?*const std.process.Environ.Map,
    /// Where the PROJECT skills live, relative to the cwd.
    ///
    /// A field and not a constant because the tests have to point it at a temp
    /// directory: writing fixtures into the real `.zode/skills` of whoever runs
    /// the suite would leave junk in their repo, which is exactly the mistake the
    /// fuzzer made with `~/.config/zode/auth.json`.
    project_dir: []const u8 = skills.project_dir,
    /// `.agents/skills`, the cross-agent convention. Same reason it is a field:
    /// the tests must not write into the real one.
    agents_dir: []const u8 = skills.agents_dir,
    /// Absolute path of the git repository root, when zode was launched BELOW it.
    ///
    /// This is the fix for "cd src && zode sees no skills at all": the
    /// project's skills live in the root, and the root is a fact git already
    /// knows. It is `null` when the cwd IS the root (nothing to add) or when there
    /// is no repository.
    repo_root: ?[]const u8 = null,
    /// Scratch used for the joined paths; the caller's `Io.Dir` calls need a
    /// buffer and allocating one per path would be a lot of garbage on a
    /// directory walk.
    path_buf: [std.fs.max_path_bytes]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map) Loader {
        return .{ .gpa = gpa, .io = io, .env = env };
    }

    /// Every root that will be scanned, in shadowing order, into `out`.
    ///
    /// Exposed because the freshness check needs the same list the scan used, and
    /// recomputing it here with a second, subtly different rule would be a bug
    /// waiting to happen: "the cache is valid for the roots I remember" has to be
    /// the same roots.
    ///
    /// `bufs` is one buffer per root and NOT `self.path_buf`: every path here has
    /// to survive the loop, and a shared scratch buffer would leave the earlier
    /// roots pointing at the last one (the `sb.path` trap from the fuzzer round).
    pub fn roots(self: *Loader, bufs: *[max_roots][std.fs.max_path_bytes]u8, out: [][]const u8) usize {
        var n: usize = 0;

        if (bufs[n].len >= self.project_dir.len) {
            @memcpy(bufs[n][0..self.project_dir.len], self.project_dir);
            out[n] = bufs[n][0..self.project_dir.len];
            n += 1;
        }
        if (bufs[n].len >= self.agents_dir.len) {
            @memcpy(bufs[n][0..self.agents_dir.len], self.agents_dir);
            out[n] = bufs[n][0..self.agents_dir.len];
            n += 1;
        }

        // The same two, in the repository root, when that is not the cwd. Guarded
        // on `n + 2 < max_roots` so adding a root later cannot write past the end.
        if (self.repo_root) |root| {
            if (!std.mem.eql(u8, root, self.project_dir)) {
                for ([_][]const u8{ self.project_dir, self.agents_dir }) |sub| {
                    if (n + 1 >= max_roots) break;
                    const joined = std.fmt.bufPrint(&bufs[n], "{s}/{s}", .{ root, sub }) catch continue;
                    out[n] = joined;
                    n += 1;
                }
            }
        }

        if (self.joinHome()) |home| {
            if (n >= max_roots) return n;
            const joined = std.fmt.bufPrint(&bufs[n], "{s}/.config/{s}", .{ home, skills.user_subdir }) catch return n;
            out[n] = joined;
            n += 1;
        }
        return n;
    }

    /// The user's HOME, or `null` when there is none.
    ///
    /// `null` makes the USER skills silently absent, which is the right behaviour
    /// for a sandboxed test and would be the wrong one for a real user with a
    /// broken HOME — so the caller can tell "no HOME" apart from "no skills", and
    /// `/skills` says so instead of claiming there are none.
    fn userHome(self: *Loader, out: []u8) ?[]const u8 {
        const m = self.env orelse return null;
        const home = m.get("HOME") orelse return null;
        if (home.len == 0) return null;
        @memcpy(out[0..home.len], home);
        return out[0..home.len];
    }

    /// Source for a root index (used for tagging skills).
    fn sourceForRoot(self: *Loader, root_index: usize) skills.Source {
        // Roots order: project_dir, agents_dir, [repo_project_dir, repo_agents_dir], user_dir
        // The bundled skills are added separately after all disk roots.
        if (root_index == 0) return .project;
        if (root_index == 1) return .agents;
        if (self.repo_root) |_| {
            if (root_index == 2) return .project;
            if (root_index == 3) return .agents;
            if (root_index == 4) return .user;
        } else {
            if (root_index == 2) return .user;
        }
        return .user; // fallback
    }

    /// Walks disk roots and returns the entries, project first, deduplicated by
    /// name.
    ///
    /// The caller OWNS the returned slice AND every string in it (all gpa), and
    /// must free them with `freeEntries`. The ownership is in the signature of
    /// the pair of functions precisely because it is easy to get wrong: a cached
    /// list freed by the wrong caller is the "Invalid free" family.
    pub fn scan(self: *Loader, out: []skills.Entry, cap: usize) []skills.Entry {
        var n: usize = 0;

        var bufs: [max_roots][std.fs.max_path_bytes]u8 = undefined;
        var paths: [max_roots][]const u8 = undefined;
        const root_count = self.roots(&bufs, &paths);

        for (paths[0..root_count], 0..) |dir_path, root_idx| {
            var d = std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch continue;
            defer d.close(self.io);

            var it = d.iterate();
            while (it.next(self.io) catch null) |entry| {
                if (n >= cap) return out[0..n];
                if (entry.kind != .directory) continue;
                // `dot` files are not skills and a `.git` inside the skills dir
                // is not either.
                if (entry.name.len == 0 or entry.name[0] == '.') continue;
                if (!skills.validName(entry.name)) continue;

                // The project root SHADOWS: if this name is already in, skip it.
                if (alreadyIn(out[0..n], entry.name)) continue;

                var file_buf: [std.fs.max_path_bytes]u8 = undefined;
                const file_path = std.fmt.bufPrint(&file_buf, "{s}/{s}/{s}", .{
                    dir_path, entry.name, skills.filename,
                }) catch continue;

                var head: [8 * 1024]u8 = undefined;
                // Only the HEAD is read here, not the whole body: the list needs
                // the frontmatter and nothing else, and a 60 KB skill must not
                // cost 60 KB of reading at startup for every request's prompt.
                // 8 KB is enough for a frontmatter by a wide margin.
                const text = readPrefix(self.io, file_path, &head) orelse continue;
                if (text.len == 0) continue;

                const fm = skills.splitFrontmatter(text);
                const meta = if (fm) |f| f.meta else skills.Meta{};
                const name = skills.nameFor(meta, entry.name);

                // The project copy wins even if the USER one was scanned first in
                // a future reordering, so re-check: `alreadyIn` above only skips
                // duplicates, and the caller of `scan` is documented as project
                // first. This makes the order not matter.
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
                const when_copy = self.gpa.dupe(u8, meta.when_to_use) catch {
                    self.gpa.free(name_copy);
                    self.gpa.free(desc_copy);
                    self.gpa.free(path_copy);
                    continue;
                };
                errdefer self.gpa.free(when_copy);
                const source = self.sourceForRoot(root_idx);
                out[n] = .{
                    .name = name_copy,
                    .description = desc_copy,
                    .path = path_copy,
                    .body = null,
                    .source = source,
                    .context = meta.context,
                    .when_to_use = when_copy,
                };
                n += 1;
            }
        }

        // Append bundled skills (they can be shadowed by on-disk skills)
        const bundled_entries = bundled.bundled_skills;
        for (bundled_entries) |bs| {
            if (n >= cap) break;
            // Only add if not already shadowed by a disk skill
            if (alreadyIn(out[0..n], bs.name)) continue;
            const name_copy = self.gpa.dupe(u8, bs.name) catch continue;
            errdefer self.gpa.free(name_copy);
            const desc_copy = self.gpa.dupe(u8, bs.description) catch {
                self.gpa.free(name_copy);
                continue;
            };
            errdefer self.gpa.free(desc_copy);
            var path_buf: [128]u8 = undefined;
            const path_str = std.fmt.bufPrint(path_buf[0..], "bundled://{s}", .{bs.name}) catch {
                self.gpa.free(name_copy);
                self.gpa.free(desc_copy);
                continue;
            };
            const path_copy = self.gpa.dupe(u8, path_str) catch {
                self.gpa.free(name_copy);
                self.gpa.free(desc_copy);
                continue;
            };
            errdefer self.gpa.free(path_copy);
            const when_copy = self.gpa.dupe(u8, bs.when_to_use) catch {
                self.gpa.free(name_copy);
                self.gpa.free(desc_copy);
                self.gpa.free(path_copy);
                continue;
            };
            errdefer self.gpa.free(when_copy);
            out[n] = .{
                .name = name_copy,
                .description = desc_copy,
                .path = path_copy,
                // The body travels WITH the entry: a bundled skill's body is
                // in the binary, and its path is not a file at all. Carrying
                // it is what lets `load` answer without opening anything.
                .body = bs.body,
                .source = .bundled,
                .context = bs.context,
                .when_to_use = when_copy,
            };
            n += 1;
        }

        return out[0..n];
    }

    /// `<HOME>/.config`, or `null` when there is no HOME.
    ///
    /// The caller joins `user_subdir` (and the repository-root roots) onto it,
    /// because `roots` needs a DIFFERENT buffer per path: one shared scratch
    /// buffer left every path pointing at the last one written, which is the
    /// `sb.path` trap from the fuzzer round.
    fn joinHome(self: *Loader) ?[]const u8 {
        return self.userHome(&self.path_buf);
    }

    /// The body of a skill, framed for the model. Writes into `out` and returns a
    /// slice of it.
    ///
    /// `name` and `description` come from the ENTRY, not from the file: they were
    /// already read at discovery time and re-parsing them here would make the
    /// frontmatter a second source of truth (and the two could disagree).
    pub fn load(
        self: *Loader,
        entry: skills.Entry,
        out: []u8,
    ) ?[]const u8 {
        // A body that came WITH the entry never opens a file.
        //
        // That is what the bundled skills are: their body is in the binary and
        // their path (`bundled://name`) is not a file at all. A loader that
        // opened the disk for them would fail, and the body it was already
        // holding would be thrown away with the failure.
        if (entry.body) |b| {
            return skills.formatSkill(entry.name, entry.description, b, out);
        }
        // Bundled skills: body is in the embedded data
        if (std.mem.startsWith(u8, entry.path, "bundled://")) {
            const name = entry.path["bundled://".len..];
            const bundled_skill = bundled.getBundled(name) orelse return null;
            return bundled.formatBundledSkill(bundled_skill, null, out);
        }

        // `max_body` on the READ, so a 500 KB "skill" cannot make the TUI allocate
        // 500 KB to then complain about it.
        const text = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            entry.path,
            self.gpa,
            .limited(skills.max_body),
        ) catch return null;
        defer self.gpa.free(text);
        const fm = skills.splitFrontmatter(text);
        const body = if (fm) |f| f.body else text;
        return skills.formatSkill(entry.name, entry.description, body, out);
    }

    /// Load a skill with optional arguments ($ARGUMENTS substitution).
    pub fn loadWithArgs(
        self: *Loader,
        entry: skills.Entry,
        args: ?[]const u8,
        out: []u8,
    ) ?[]const u8 {
        // The body that came with the entry: same rule as `load`, and the
        // substitution happens on it.
        if (entry.body) |b| {
            if (args) |a| {
                const trimmed = std.mem.trim(u8, a, " \t\r\n");
                if (trimmed.len > 0) {
                    var buf: [8192]u8 = undefined;
                    const substituted = bundled.substituteArguments(b, trimmed, &buf);
                    return skills.formatSkill(entry.name, entry.description, substituted, out);
                }
            }
            return skills.formatSkill(entry.name, entry.description, b, out);
        }
        if (std.mem.startsWith(u8, entry.path, "bundled://")) {
            const name = entry.path["bundled://".len..];
            const bundled_skill = bundled.getBundled(name) orelse return null;
            return bundled.formatBundledSkill(bundled_skill, args, out);
        }

        const text = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            entry.path,
            self.gpa,
            .limited(skills.max_body),
        ) catch return null;
        defer self.gpa.free(text);
        const fm = skills.splitFrontmatter(text);
        const body = if (fm) |f| f.body else text;
        // Substitute $ARGUMENTS if args provided
        if (args) |a| {
            const trimmed = std.mem.trim(u8, a, " \t\r\n");
            if (trimmed.len > 0) {
                var buf: [8192]u8 = undefined;
                const substituted = bundled.substituteArguments(body, trimmed, &buf);
                return skills.formatSkill(entry.name, entry.description, substituted, out);
            }
        }
        return skills.formatSkill(entry.name, entry.description, body, out);
    }
};

fn alreadyIn(list: []const skills.Entry, name: []const u8) bool {
    for (list) |e| {
        if (std.mem.eql(u8, e.name, name)) return true;
    }
    return false;
}

/// Reads the HEAD of a file into `out`, stopping at the end of the frontmatter.
///
/// It reads the WHOLE file with `readFileAlloc` and then keeps only the head,
/// because `Io.File` has no positional partial read in 0.16 and hand-rolling one
/// over `readStreaming` would be a lot of code for a directory walked once. The
/// cost is bounded by `max_scan`, so a 60 KB skill cannot make startup slow.
fn readPrefix(io: std.Io, path: []const u8, out: []u8) ?[]const u8 {
    // `page_allocator`: this copy is thrown away immediately and the caller owns
    // only what lands in `out`. Using the Model's allocator here would be an
    // allocation per skill per discovery that nobody frees.
    const full = std.Io.Dir.cwd().readFileAlloc(io, path, std.heap.page_allocator, .limited(max_scan)) catch return null;
    defer std.heap.page_allocator.free(full);
    const n = @min(full.len, out.len);
    @memcpy(out[0..n], full[0..n]);
    return out[0..n];
}

/// Ceiling on what discovery reads from a `SKILL.md`.
///
/// The frontmatter is at the top and is a few hundred bytes; 32 KB is a very
/// generous frontmatter, and anything past it is body we would throw away.
pub const max_scan = 32 * 1024;

/// How many roots `Loader.roots` can return: two in the cwd, two in the
/// repository root, one user. A constant and not a count because every root needs
/// its own `max_path_bytes` buffer, and a stack array sized by a variable would be
/// a 20 KB `scan` frame.
pub const max_roots = 5;

/// The `mtime` + size of one path, for deciding whether a cached list is stale.
///
/// Size is in it because a same-second edit of a same-length file is exactly the
/// case where `mtime` alone (in whole seconds) lies, and this repo has already
/// been bitten by filesystem timestamp granularity elsewhere.
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
        if (!self.exists) return true; // both missing: unchanged, and that is a fact
        return self.mtime_ns == other.mtime_ns and self.size == other.size;
    }
};

/// Paths are stored in the stamp, not pointed at: the point of a stamp is to
/// survive the rescan that produced it, and a pointer into the freed previous list
/// would be a dangling read on the exact path that decides freshness.
/// 512 and not `max_path_bytes`: there are ~70 stamps and each one carries its
/// path, so at 4096 they were 284 KB of `.bss` that the binary never used for
/// anything. A skill path over 512 bytes is not a thing, and if it happens the
/// stamp is skipped (a miss, not an error).
pub const stamp_path_max = 512;

/// `true` when `path` can be stored (fits in a stamp) and the stamp was filled.
pub fn stampPath(io: std.Io, path: []const u8, out: *Stamp) bool {
    out.* = .{};
    if (path.len == 0 or path.len > stamp_path_max) return false;
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch {
        // A path that is gone is NOT a failure: it is a fact about the disk, and
        // `exists = false` is what makes the cache notice the deletion.
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

/// True once a closing `---` fence has been seen on its own line.
///
/// It is what says "we have everything we need from the head", and the test below
/// pins the distinction between the opening fence and the closing one — which is
/// the bug a naive `indexOf("---", 3)` would have.
fn hasFrontmatterEnd(prefix: []const u8) bool {
    var i: usize = 0;
    var seen_open = false;
    while (i < prefix.len) {
        const nl = std.mem.indexOfScalar(u8, prefix[i..], '\n') orelse prefix.len - i;
        const line = std.mem.trim(u8, prefix[i .. i + nl], " \t\r");
        if (!seen_open) {
            if (std.mem.eql(u8, line, "---")) seen_open = true;
        } else if (std.mem.eql(u8, line, "---")) {
            return true;
        }
        i += nl + 1;
    }
    return false;
}

test "hasFrontmatterEnd: tells the closing fence from the opening one" {
    try std.testing.expect(hasFrontmatterEnd("---\nname: x\n---\nbody"));
    try std.testing.expect(!hasFrontmatterEnd("---\nname: x\n"));
    try std.testing.expect(!hasFrontmatterEnd("no frontmatter\n---\n"));
    // A horizontal line inside the frontmatter does NOT close it.
    try std.testing.expect(!hasFrontmatterEnd("---\nname: x\n-----------\nmore"));
}

test "alreadyIn: finds exact duplicates, not similar ones" {
    var list = [_]skills.Entry{
        .{ .name = "pty-tests" },
        .{ .name = "other" },
    };
    try std.testing.expect(alreadyIn(&list, "pty-tests"));
    try std.testing.expect(alreadyIn(&list, "other"));
    try std.testing.expect(!alreadyIn(&list, "pty"));
    try std.testing.expect(!alreadyIn(&list, "pty-tests-2"));
    try std.testing.expect(!alreadyIn(&list, ""));
}

// ── tests with FIXTURES on a real disk ───────────────────────
//
// These DO touch the filesystem (unlike `skills.zig`, which is pure and tested
// with strings). The reason is in the header: what always fails when discovering
// skills is the I/O — the `openDir` without `.iterate`, the `createDirPath`, the
// file name — and that cannot be tested with a string.
//
// The `HOME` is the test sandbox's, and the directories are deleted at the end:
// an automated test that wrote into the real `~/.config` would be the mistake
// the June fuzzer already made (it saved a pasted key and left the provider
// with a 401).

/// A unique temp root, written into `out`.
///
/// It takes a buffer and does NOT return a slice of its own stack: that is the
/// `&[_]u8{c}` bug this repo has now hit seven times, and here it was silent in
/// the worst way — the fixtures were written to a garbage path and every
/// discovery test failed with "found 0" for no visible reason.
fn tmpRoot(out: []u8) ![]const u8 {
    return std.fmt.bufPrint(out, ".zode-skills-test-{d}", .{std.testing.random_seed});
}

/// `<root>/<sub>`, as gpa memory (the `project_dir` field outlives the buffer).
fn skillRootOf(gpa: std.mem.Allocator, root: []const u8, sub: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, sub });
}

fn writeFixture(root: []const u8, rel: []const u8, body: []const u8) !void {
    var buf: [512]u8 = undefined;
    const full = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ root, rel });
    if (std.fs.path.dirname(full)) |dir| {
        try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    }
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = full, .data = body });
}

test "scan: finds a skill from the PROJECT and reads its frontmatter" {
    var gpa_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var root_buf: [256]u8 = undefined;
    const root = try tmpRoot(&root_buf);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try writeFixture(root, ".zode/skills/pty-tests/SKILL.md",
        \\---
        \\name: pty-tests
        \\description: after any change to tui.zig drawing code
        \\when_to_use: when you touch drawing code
        \\---
        \\# Verifying a TUI
        \\
        \\Use a real pty. Never a homemade emulator.
    );

    var loader = store.Loader.init(gpa, std.testing.io, null);
    loader.project_dir = try skillRootOf(gpa, root, ".zode/skills");
    var buf: [16]skills.Entry = undefined;
    const found = loader.scan(&buf, buf.len);

    // 1 project skill + 5 bundled skills
    try std.testing.expectEqual(@as(usize, 6), found.len);
    // Find the project skill
    var found_pty = false;
    for (found) |e| {
        if (std.mem.eql(u8, e.name, "pty-tests")) {
            found_pty = true;
            try std.testing.expectEqualStrings("after any change to tui.zig drawing code", e.description);
            try std.testing.expectEqualStrings("when you touch drawing code", e.when_to_use);
            try std.testing.expect(e.source == .project);
            try std.testing.expect(e.context == .inline_mode);
        }
        gpa.free(e.name);
        gpa.free(e.description);
        gpa.free(e.path);
        gpa.free(e.when_to_use);
    }
    try std.testing.expect(found_pty);
}

test "scan: the PROJECT shadows the user's one with the same name (they do not merge)" {
    // A project skill that gets merged with the global one is worse than not
    // having it: half of the instructions would be from the other project.
    var gpa_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var root_buf: [256]u8 = undefined;
    const root = try tmpRoot(&root_buf);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try writeFixture(root, ".zode/skills/mine/SKILL.md",
        \\---
        \\description: the project's own version
        \\---
        \\proyecto
    );
    try writeFixture(root, "home/.config/zode/skills/mine/SKILL.md",
        \\---
        \\description: the user's own version
        \\---
        \\persona
    );

    // A hand-built `Environ.Map` with just HOME. `scan` reads exactly one key.
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    var home_buf: [320]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buf, "{s}/home", .{root});
    try env_map.put("HOME", home);

    var loader = store.Loader.init(gpa, std.testing.io, &env_map);
    loader.project_dir = try skillRootOf(gpa, root, ".zode/skills");
    var buf: [16]skills.Entry = undefined;
    const found = loader.scan(&buf, buf.len);

    // 1 project skill + 5 bundled skills
    try std.testing.expectEqual(@as(usize, 6), found.len);
    // Find the project skill
    var found_mine = false;
    for (found) |e| {
        if (std.mem.eql(u8, e.name, "mine")) {
            found_mine = true;
            try std.testing.expectEqualStrings("the project's own version", e.description);
            try std.testing.expect(e.source == .project);
        }
        gpa.free(e.name);
        gpa.free(e.description);
        gpa.free(e.path);
        gpa.free(e.when_to_use);
    }
    try std.testing.expect(found_mine);
}

test "scan: ignores loose files, dotted directories and impossible names" {
    var gpa_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var root_buf: [256]u8 = undefined;
    const root = try tmpRoot(&root_buf);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    // A file, not a directory.
    try writeFixture(root, ".zode/skills/README.md", "no soy un skill");
    // A dotted directory (`.git`).
    try writeFixture(root, ".zode/skills/.git/SKILL.md", "--- description: x ---");
    // A directory whose name cannot be a tool argument.
    try writeFixture(root, ".zode/skills/con espacio/SKILL.md", "--- description: x ---");
    // And a good one, to check that the filter did NOT eat the real thing.
    try writeFixture(root, ".zode/skills/bueno/SKILL.md",
        \\---
        \\description: este si
        \\---
    );

    var loader = store.Loader.init(gpa, std.testing.io, null);
    loader.project_dir = try skillRootOf(gpa, root, ".zode/skills");
    var buf: [16]skills.Entry = undefined;
    const found = loader.scan(&buf, buf.len);

    // 1 project skill + 5 bundled skills
    try std.testing.expectEqual(@as(usize, 6), found.len);
    // Find the project skill
    var found_bueno = false;
    for (found) |e| {
        if (std.mem.eql(u8, e.name, "bueno")) {
            found_bueno = true;
            try std.testing.expectEqualStrings("este si", e.description);
            try std.testing.expect(e.source == .project);
        }
        gpa.free(e.name);
        gpa.free(e.description);
        gpa.free(e.path);
        gpa.free(e.when_to_use);
    }
    try std.testing.expect(found_bueno);
}

test "load: the body arrives framed and WITHOUT the frontmatter" {
    var gpa_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var root_buf: [256]u8 = undefined;
    const root = try tmpRoot(&root_buf);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try writeFixture(root, ".zode/skills/guia/SKILL.md",
        \\---
        \\name: guia
        \\description: cuando haya dudas de estilo
        \\---
        \\# Reglas
        \\
        \\Una regla por parrafo.
    );

    var loader = store.Loader.init(gpa, std.testing.io, null);
    loader.project_dir = try skillRootOf(gpa, root, ".zode/skills");
    var buf: [16]skills.Entry = undefined;
    const found = loader.scan(&buf, buf.len);
    // 1 project skill + 5 bundled skills
    try std.testing.expectEqual(@as(usize, 6), found.len);

    // Find the project skill
    var guia_entry: ?skills.Entry = null;
    for (found) |e| {
        if (std.mem.eql(u8, e.name, "guia")) {
            guia_entry = e;
        }
    }
    try std.testing.expect(guia_entry != null);

    var out: [8192]u8 = undefined;
    const text = loader.load(guia_entry.?, &out) orelse return error.TestUnexpectedResult;
    // The name and the "when to use it" are in, because without them the model
    // does not know what it is reading nor when to apply it.
    try std.testing.expect(std.mem.indexOf(u8, text, "=== skill: guia ===") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cuando haya dudas de estilo") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Una regla por parrafo.") != null);
    // And the frontmatter does NOT travel: those are wasted tokens on every call.
    try std.testing.expect(std.mem.indexOf(u8, text, "name: guia") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "---") == null);

    for (found) |e| {
        gpa.free(e.name);
        gpa.free(e.description);
        gpa.free(e.path);
        gpa.free(e.when_to_use);
    }
}

test "load: a skill without frontmatter works too (it is markdown and a dot)" {
    var gpa_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var root_buf: [256]u8 = undefined;
    const root = try tmpRoot(&root_buf);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try writeFixture(root, ".zode/skills/simple/SKILL.md", "# Solo markdown\n\ninstrucciones\n");

    var loader = store.Loader.init(gpa, std.testing.io, null);
    loader.project_dir = try skillRootOf(gpa, root, ".zode/skills");
    var buf: [16]skills.Entry = undefined;
    const found = loader.scan(&buf, buf.len);
    // 1 project skill + 5 bundled skills
    try std.testing.expectEqual(@as(usize, 6), found.len);

    // Find the project skill
    var simple_entry: ?skills.Entry = null;
    for (found) |e| {
        if (std.mem.eql(u8, e.name, "simple")) {
            simple_entry = e;
        }
    }
    try std.testing.expect(simple_entry != null);
    // With no description, the name comes from the DIRECTORY (that is what really
    // exists on disk) and it is marked in the prompt as "(no description)".
    try std.testing.expectEqualStrings("simple", simple_entry.?.name);
    try std.testing.expectEqualStrings("", simple_entry.?.description);
    try std.testing.expect(simple_entry.?.source == .project);

    var out: [8192]u8 = undefined;
    const text = loader.load(simple_entry.?, &out) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, text, "instrucciones") != null);

    for (found) |e| {
        gpa.free(e.name);
        gpa.free(e.description);
        gpa.free(e.path);
        gpa.free(e.when_to_use);
    }
}

test "roots: the order is the shadowing one and the last root is the user's" {
    var gpa_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var root_buf: [256]u8 = undefined;
    const root = try tmpRoot(&root_buf);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};

    const proj = try skillRootOf(gpa, root, ".zode/skills");
    const agents = try skillRootOf(gpa, root, ".agents/skills");
    var loader = store.Loader.init(gpa, std.testing.io, null);
    loader.project_dir = proj;
    loader.agents_dir = agents;

    var bufs: [store.max_roots][std.fs.max_path_bytes]u8 = undefined;
    var paths: [store.max_roots][]const u8 = undefined;
    const n = loader.roots(&bufs, &paths);
    // With no HOME (env = null) the two are the only ones.
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings(proj, paths[0]);
    try std.testing.expectEqualStrings(agents, paths[1]);

    // Each path survives the next call: a single scratch buffer left ALL of them
    // pointing at the last one written (the `sb.path` trap).
    try std.testing.expect(!std.mem.eql(u8, paths[0], paths[1]));
}

test "roots: with repo_root its two directories are added, and the cwd is not repeated" {
    var gpa_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var loader = store.Loader.init(gpa, std.testing.io, null);
    loader.project_dir = ".zode/skills";
    loader.agents_dir = ".agents/skills";
    loader.repo_root = "/home/x/proj";

    var bufs: [store.max_roots][std.fs.max_path_bytes]u8 = undefined;
    var paths: [store.max_roots][]const u8 = undefined;
    const n = loader.roots(&bufs, &paths);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualStrings(".zode/skills", paths[0]);
    try std.testing.expectEqualStrings(".agents/skills", paths[1]);
    try std.testing.expectEqualStrings("/home/x/proj/.zode/skills", paths[2]);
    try std.testing.expectEqualStrings("/home/x/proj/.agents/skills", paths[3]);

    // The cwd IS already the root: reading the same paths twice would be work
    // with no result, so they are not added.
    loader.project_dir = "/home/x/proj/.zode/skills";
    loader.agents_dir = "/home/x/proj/.agents/skills";
    var bufs2: [store.max_roots][std.fs.max_path_bytes]u8 = undefined;
    var paths2: [store.max_roots][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), loader.roots(&bufs2, &paths2));
}

test "scan: .agents/skills is read too, and .zode wins when both are present" {
    var gpa_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var root_buf: [256]u8 = undefined;
    const root = try tmpRoot(&root_buf);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};

    // The same name in both: `.zode/skills/shared` wins.
    try writeFixture(root, ".zode/skills/shared/SKILL.md", "---\ndescription: del propio harness\n---\nbody zode\n");
    try writeFixture(root, ".agents/skills/shared/SKILL.md", "---\ndescription: del convenio\n---\nbody agents\n");
    // And one only in `.agents`, which must also show up.
    try writeFixture(root, ".agents/skills/solo-agents/SKILL.md", "---\ndescription: solo en agents\n---\nbody\n");

    var loader = store.Loader.init(gpa, std.testing.io, null);
    loader.project_dir = try skillRootOf(gpa, root, ".zode/skills");
    loader.agents_dir = try skillRootOf(gpa, root, ".agents/skills");
    var buf: [16]skills.Entry = undefined;
    const found = loader.scan(&buf, buf.len);

    // 2 project/agents skills + 5 bundled skills = 7
    try std.testing.expectEqual(@as(usize, 7), found.len);
    // Find the project skill (should win over agents)
    var found_shared = false;
    var found_solo = false;
    for (found) |e| {
        if (std.mem.eql(u8, e.name, "shared")) {
            found_shared = true;
            try std.testing.expectEqualStrings("del propio harness", e.description);
            try std.testing.expect(e.source == .project);
        }
        if (std.mem.eql(u8, e.name, "solo-agents")) {
            found_solo = true;
            try std.testing.expect(e.source == .agents);
        }
        gpa.free(e.name);
        gpa.free(e.description);
        gpa.free(e.path);
        gpa.free(e.when_to_use);
    }
    try std.testing.expect(found_shared);
    try std.testing.expect(found_solo);
}

test "scan: bundled skills are appended and can be shadowed" {
    var gpa_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var root_buf: [256]u8 = undefined;
    const root = try tmpRoot(&root_buf);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};

    // Create a disk skill that shadows a bundled one (simplify)
    try writeFixture(root, ".zode/skills/simplify/SKILL.md",
        \\---
        \\description: my custom simplify
        \\---
        \\custom body
    );

    var loader = store.Loader.init(gpa, std.testing.io, null);
    loader.project_dir = try skillRootOf(gpa, root, ".zode/skills");
    var buf: [16]skills.Entry = undefined;
    const found = loader.scan(&buf, buf.len);

    // Should have 5 bundled + 0 (shadowed) = 5, but simplify is from project
    try std.testing.expect(found.len >= 5);
    var found_simplify = false;
    for (found) |e| {
        if (std.mem.eql(u8, e.name, "simplify")) {
            found_simplify = true;
            try std.testing.expectEqualStrings("my custom simplify", e.description);
            try std.testing.expect(e.source == .project);
        }
        if (e.source == .bundled) {
            try std.testing.expect(e.name.len > 0);
        }
        gpa.free(e.name);
        gpa.free(e.description);
        gpa.free(e.path);
        gpa.free(e.when_to_use);
    }
    try std.testing.expect(found_simplify);
}

test "load: an entry that carries its body never opens a file" {
    var gpa_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var loader = store.Loader.init(gpa, std.testing.io, null);

    // The path does not exist, ON PURPOSE. A loader that went to the disk
    // for this body would answer null, and the body it was already holding
    // would be thrown away with the failure: the skill would look broken
    // exactly when it is the one that cannot be broken.
    const entry = skills.Entry{
        .name = "embedded",
        .description = "a skill whose body is already here",
        .path = "/tmp/zode-skill-that-does-not-exist/SKILL.md",
        .body = "# The rules\n\nOne rule per paragraph.",
    };

    var out: [8192]u8 = undefined;
    const text = loader.load(entry, &out) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, text, "One rule per paragraph.") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "=== skill: embedded ===") != null);
}

test "load: a bundled entry carries its body, so nothing is read from the disk" {
    var gpa_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var loader = store.Loader.init(gpa, std.testing.io, null);
    var buf: [16]skills.Entry = undefined;
    const found = loader.scan(&buf, buf.len);

    var bundled_body: ?[]const u8 = null;
    var bundled_name: []const u8 = "";
    for (found) |e| {
        if (e.source == .bundled and e.body != null) {
            bundled_body = e.body;
            bundled_name = e.name;
        }
    }
    try std.testing.expect(bundled_body != null);
    try std.testing.expect(bundled_name.len > 0);

    // And it loads: the body is in the binary, so the path is never opened.
    var verify_entry: ?skills.Entry = null;
    for (found) |e| {
        if (std.mem.eql(u8, e.name, "verify")) verify_entry = e;
    }
    try std.testing.expect(verify_entry != null);
    try std.testing.expect(verify_entry.?.body != null);

    var out: [16384]u8 = undefined;
    const text = loader.load(verify_entry.?, &out) orelse return error.TestUnexpectedResult;
    try std.testing.expect(text.len > 0);
}

test "loadWithArgs: substitutes $ARGUMENTS in bundled skills" {
    var gpa_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var loader = store.Loader.init(gpa, std.testing.io, null);
    var buf: [16]skills.Entry = undefined;
    const found = loader.scan(&buf, buf.len);

    // Find the verify skill
    var verify_entry: ?skills.Entry = null;
    for (found) |e| {
        if (std.mem.eql(u8, e.name, "verify")) {
            verify_entry = e;
        }
    }
    try std.testing.expect(verify_entry != null);

    var out: [16384]u8 = undefined;
    const text = loader.loadWithArgs(verify_entry.?, "test argument", &out) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, text, "test argument") != null);

    for (found) |e| {
        gpa.free(e.name);
        gpa.free(e.description);
        gpa.free(e.path);
        gpa.free(e.when_to_use);
    }
}

test "stampPath: a file that disappears is remembered as missing" {
    var root_buf: [256]u8 = undefined;
    const root = try tmpRoot(&root_buf);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};

    var rel: [64]u8 = undefined;
    const rel_path = try std.fmt.bufPrint(&rel, "{s}/SKILL.md", .{root});
    try writeFixture(root, "SKILL.md", "---\ndescription: x\n---\n");

    var before: store.Stamp = .{};
    try std.testing.expect(store.stampPath(std.testing.io, rel_path, &before));
    try std.testing.expect(before.exists);

    var now: store.Stamp = .{};
    try std.testing.expect(store.stampPath(std.testing.io, rel_path, &now));
    // Same content: the stamps compare equal, and that is why the cache is not
    // invalidated.
    try std.testing.expect(before.sameAs(&now));

    try writeFixture(root, "SKILL.md", "---\ndescription: x\n---\ncuerpo nuevo\n");
    var after: store.Stamp = .{};
    try std.testing.expect(store.stampPath(std.testing.io, rel_path, &after));
    try std.testing.expect(!before.sameAs(&after));

    // And DELETING it is a change, not "nothing happened": otherwise the prompt
    // would keep offering a skill whose file no longer exists.
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    var gone: store.Stamp = .{};
    try std.testing.expect(store.stampPath(std.testing.io, rel_path, &gone));
    try std.testing.expect(!gone.exists);
    try std.testing.expect(!after.sameAs(&gone));
}

test "scan: a directory that does not exist is not an error (0 skills, no noise)" {
    // It is the NORMAL case for most projects, and if `scan` complained the
    // prompt would carry an error notice on every request.
    var gpa_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var loader = store.Loader.init(gpa, std.testing.io, null);
    // A directory that was never created, which is what a project without skills
    // looks like.
    loader.project_dir = ".zode/no-existe-esto";
    var buf: [8]skills.Entry = undefined;
    const found = loader.scan(&buf, buf.len);
    // Bundled skills are always available even if no project skills exist
    try std.testing.expectEqual(@as(usize, 5), found.len);
    for (found) |e| {
        gpa.free(e.name);
        gpa.free(e.description);
        gpa.free(e.path);
        gpa.free(e.when_to_use);
    }
}

test "scan: respects the entry cap (it does not grow without limit)" {
    var gpa_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var root_buf: [256]u8 = undefined;
    const root = try tmpRoot(&root_buf);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "s{d}", .{i});
        var body_buf: [128]u8 = undefined;
        const body = try std.fmt.bufPrint(&body_buf, "---\ndescription: d{d}\n---\n", .{i});
        var rel: [64]u8 = undefined;
        const rel_path = try std.fmt.bufPrint(&rel, ".zode/skills/{s}/SKILL.md", .{name});
        try writeFixture(root, rel_path, body);
    }

    var loader = store.Loader.init(gpa, std.testing.io, null);
    loader.project_dir = try skillRootOf(gpa, root, ".zode/skills");
    var buf: [5]skills.Entry = undefined;
    const found = loader.scan(&buf, buf.len);
    // It cuts at 5, and the ones that did not fit are NOT filtered out with a
    // broken name: what is there are complete, owned entries.
    try std.testing.expectEqual(@as(usize, 5), found.len);
    for (found) |e| {
        try std.testing.expect(skills.validName(e.name));
        gpa.free(e.name);
        gpa.free(e.description);
        gpa.free(e.path);
        gpa.free(e.when_to_use);
    }
}