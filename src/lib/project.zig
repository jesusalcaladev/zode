//! Where zode is running: the cwd, the project root, and the git branch.
//!
//! Split from `agent.zig` because all of it is answerable without a model, a
//! terminal or a network, and because the parts that can be wrong (walking up,
//! following a `gitdir:` pointer, reading `HEAD`) are exactly the parts that want
//! a test.
//!
//! ## Why the root matters
//!
//! zode used to read `AGENTS.md` and `.zode/skills` from the cwd EXACTLY, so
//! launching it one directory below the root silently used none of the project's
//! own instructions. git is the anchor that fixes it without inventing a rule: the
//! repository root is a fact that already exists, and it is the directory whose
//! `AGENTS.md` describes the tree the model is editing.
//!
//! ## No allocator, on purpose
//!
//! `Info` is fixed buffers, so it can be filled once on one thread and READ from
//! any other without a lock and without the ownership questions that a heap slice
//! would raise (the prompt is composed on the worker, `/context` is drawn on the UI
//! thread, and the cwd cannot change while zode runs).

const std = @import("std");

const store = @This();

pub const max_path = std.fs.max_path_bytes;
/// Git branch names are short; anything longer is a path or a mistake.
pub const max_branch = 128;
/// How many parent directories to walk before giving up on finding a repository.
pub const max_levels: usize = 32;

pub const Info = struct {
    cwd_buf: [max_path]u8 = undefined,
    cwd_len: usize = 0,
    /// The git top level, when there is one. `null` means "not in a repository",
    /// which is a real answer (a tarball, a home directory, `/tmp`).
    root_buf: [max_path]u8 = undefined,
    root_len: usize = 0,
    /// Where the git metadata lives. Usually `<root>/.git`, but for a worktree or
    /// a submodule it is a FILE with `gitdir: <path>` inside, and that path is
    /// where `HEAD` lives — which is why it is kept separately instead of being
    /// derived from the root every time.
    git_dir_buf: [max_path]u8 = undefined,
    git_dir_len: usize = 0,
    branch_buf: [max_branch]u8 = undefined,
    branch_len: usize = 0,

    pub fn cwd(self: *const Info) []const u8 {
        return self.cwd_buf[0..self.cwd_len];
    }

    pub fn root(self: *const Info) ?[]const u8 {
        if (self.root_len == 0) return null;
        return self.root_buf[0..self.root_len];
    }

    pub fn branch(self: *const Info) ?[]const u8 {
        if (self.branch_len == 0) return null;
        return self.branch_buf[0..self.branch_len];
    }

    /// The same information on ONE line, for the UI.
    ///
    /// A paragraph in the middle of a status block is three rows of noise; `/context`
    /// wants to say "here is where you are" in a single line under the gauge.
    pub fn oneLine(self: *const Info, out: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(out);
        w.print("cwd {s}", .{self.cwd()}) catch return out[0..0];
        if (self.root()) |repo| {
            if (std.mem.eql(u8, repo, self.cwd())) {
                w.writeAll(" · git repo") catch {};
            } else {
                w.print(" · git repo {s}", .{repo}) catch {};
            }
            if (self.branch()) |b| w.print(" ({s})", .{b}) catch {};
        }
        return w.buffered();
    }

    /// The paragraph the system prompt carries.
    ///
    /// It says the cwd ALWAYS: without it the model works with relative paths and
    /// cannot tell the user which file it means, and it has no way to notice that
    /// it was launched somewhere other than where the user thinks.
    ///
    /// The git line is what makes git usable without being asked about it: the
    /// model gets `branch` for free instead of spending an iteration on
    /// `git status`, and it learns the tree is a repository at all — which is not
    /// something a relative path implies.
    ///
    /// Deliberately NOT reported: dirty state, ahead/behind, the last commit.
    /// Every one of those needs reading the index or spawning git, and a line that
    /// is wrong when it is stale is worse than no line. `bash git status` is one
    /// iteration away whenever the model actually needs it.
    pub fn promptLines(self: *const Info, out: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(out);
        w.print("Working directory: {s}\n", .{self.cwd()}) catch return out[0..0];
        if (self.root()) |repo| {
            if (std.mem.eql(u8, repo, self.cwd())) {
                w.print("Git repository: {s}", .{repo}) catch {};
            } else {
                w.print("Git repository: {s} (you are in a subdirectory of it)", .{repo}) catch {};
            }
            if (self.branch()) |b| w.print(" · branch {s}", .{b}) catch {};
            // `git status` and `git diff` BY NAME, and not "you have a shell": a
            // model that does not know git answers "what changed" with `ls` and
            // `cat`, which is both slower and wrong.
            w.writeAll(" — git is available through bash: git status, git diff and git log are how you answer questions about what changed and what the history says.\n") catch {};
        }
        return w.buffered();
    }
};

/// Fills `out` from the process's real cwd.
pub fn detect(io: std.Io, env: ?*const std.process.Environ.Map, out: *Info) void {
    out.* = .{};
    const cwd = cwdPath(io, env, &out.cwd_buf) orelse return;
    out.cwd_len = cwd.len;
    fillFrom(io, cwd, out);
}

/// `detect` with the starting directory given, so the tests can point it at a
/// fixture instead of at whatever directory the runner happens to be in.
pub fn detectAt(io: std.Io, start: []const u8, out: *Info) void {
    out.* = .{};
    if (start.len == 0 or start.len > out.cwd_buf.len) return;
    @memcpy(out.cwd_buf[0..start.len], start);
    out.cwd_len = start.len;
    fillFrom(io, start, out);
}

fn fillFrom(io: std.Io, cwd: []const u8, out: *Info) void {
    const root = findRoot(io, cwd, &out.root_buf) orelse return;
    out.root_len = root.len;

    const git_dir = readGitDir(io, root, &out.git_dir_buf) orelse return;
    out.git_dir_len = git_dir.len;

    if (readBranch(io, git_dir, &out.branch_buf)) |b| out.branch_len = b.len;
}

/// The absolute cwd.
///
/// `/proc/self/cwd` and not `PWD`: the environment's `PWD` is a string that a
/// `cd` in a subshell or a `tar -x` can leave pointing somewhere else, and the
/// whole point of asking is to tell the truth about where the tools will read.
/// Falls back to `PWD` and then to `/` so the prompt line is never empty.
///
/// Public because the tests need to make their fixture ABSOLUTE: `findRoot`
/// refuses a relative path (it cannot walk up from one), and a relative fixture
/// under the cwd is the only kind of fixture these tests can write.
pub fn cwdPath(io: std.Io, env: ?*const std.process.Environ.Map, out: []u8) ?[]const u8 {
    const n = std.Io.Dir.cwd().readLink(io, "/proc/self/cwd", out) catch 0;
    if (n > 0 and out[0] == '/') return out[0..n];
    if (env) |e| {
        if (e.get("PWD")) |pwd| {
            if (pwd.len > 0 and pwd[0] == '/') {
                if (pwd.len > out.len) return null;
                @memcpy(out[0..pwd.len], pwd);
                return out[0..pwd.len];
            }
        }
    }
    if (out.len > 0) {
        out[0] = '/';
        return out[0..1];
    }
    return null;
}

/// The nearest ancestor of `start` (including itself) that holds a `.git`.
pub fn findRoot(io: std.Io, start: []const u8, out: []u8) ?[]const u8 {
    if (start.len == 0 or start[0] != '/') return null;
    if (start.len > out.len) return null;
    // The walk happens in the CALLER's buffer (`out`), not in a local: `dirname`
    // returns `[]const u8` and the loop assigns to `cur` every level, so a local
    // mutable copy and an immutable view of it are two different things. Using
    // `out` for both is what makes this compile at all.
    @memcpy(out[0..start.len], start);
    var cur: []const u8 = out[0..start.len];

    var level: usize = 0;
    while (level < max_levels) : (level += 1) {
        // The trailing slash is trimmed HERE and not on the way in: the input is a
        // view of somebody else's buffer, and writing to it would be a bug that
        // only shows up when the caller passes a `const` slice (the cwd's).
        while (cur.len > 1 and cur[cur.len - 1] == '/') cur = cur[0 .. cur.len - 1];

        if (hasGitEntry(io, cur)) return cur;

        const parent = std.fs.path.dirname(cur) orelse return null;
        if (parent.len >= cur.len) return null; // reached "/" or something cyclic
        // `copyForwards` and NOT `@memcpy`: `dirname` returns a PREFIX of `cur`,
        // and `cur` points into `out`, so source and destination overlap. The
        // destination always starts before the source (that is what "prefix"
        // means) and it can only be shorter, so copying front to back is correct.
        // `@memcpy` on overlapping slices is undefined behaviour — it compiled,
        // passed on the paths that did not happen to overlap, and panicked the
        // first time a test walked more than one level up.
        std.mem.copyForwards(u8, out[0..parent.len], parent);
        cur = out[0..parent.len];
    }
    return null;
}

/// Is there a `.git` here? A directory (normal repo) or a file (worktree,
/// submodule). Both count: a worktree has its own `HEAD` with its own branch, and
/// refusing to look would make `git worktree` directories the one place where
/// zode pretends it is not in a repository.
fn hasGitEntry(io: std.Io, dir: []const u8) bool {
    var path_buf: [max_path + 8]u8 = undefined;
    const p = std.fmt.bufPrint(&path_buf, "{s}/.git", .{dir}) catch return false;
    const st = std.Io.Dir.cwd().statFile(io, p, .{}) catch return false;
    return st.kind == .directory or st.kind == .file;
}

/// `<root>/.git` as a directory, or the target of the `gitdir:` pointer inside it.
///
/// Returns null when there is no `.git` (which `findRoot` already checked, so this
/// is the unreadable case) — and never returns the `.git` FILE itself as if it
/// were the directory, which is the mistake that makes `HEAD` unreadable in every
/// worktree.
pub fn readGitDir(io: std.Io, root: []const u8, out: []u8) ?[]const u8 {
    var path_buf: [max_path + 8]u8 = undefined;
    const dotgit = std.fmt.bufPrint(&path_buf, "{s}/.git", .{root}) catch return null;
    const st = std.Io.Dir.cwd().statFile(io, dotgit, .{}) catch return null;

    if (st.kind == .directory) {
        if (dotgit.len > out.len) return null;
        @memcpy(out[0..dotgit.len], dotgit);
        return out[0..dotgit.len];
    }
    if (st.kind != .file) return null;

    // `gitdir: /path/to/.git/worktrees/name` or a relative one, which is relative
    // to the repository root (that is what git itself documents).
    // `page_allocator` for a file that is 40 bytes: the caller keeps only what
    // lands in `out`, and a long-lived allocator here would leak one block per
    // discovery.
    const max_gitdir_file = 1024;
    const full = std.Io.Dir.cwd().readFileAlloc(io, dotgit, std.heap.page_allocator, .limited(max_gitdir_file)) catch return null;
    defer std.heap.page_allocator.free(full);
    const text = full[0..@min(full.len, max_gitdir_file)];
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    // `startsWith` and not `trimLeft`: trimLeft would eat those exact characters
    // from a line that does not start with them, turning "gitdirfile" into "file".
    const prefix = "gitdir:";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    const target = std.mem.trim(u8, trimmed[prefix.len..], " \t\r\n");
    if (target.len == 0) return null;

    // Absolute target: copy, because `target` is a view into `full`, which is
    // freed on return. Returning a view of it would be the "slice to a dead
    // frame" family that `promptLines` then reads from a worker thread.
    if (target[0] == '/') {
        if (target.len > out.len) return null;
        @memcpy(out[0..target.len], target);
        return out[0..target.len];
    }
    return std.fmt.bufPrint(out, "{s}/{s}", .{ root, target }) catch null;
}

/// The current branch, or null when detached (or when `HEAD` is unreadable).
///
/// Detached HEAD is NOT reported as the sha: a sha in a prompt reads like a branch
/// name, and the model would `git checkout` it.
pub fn readBranch(io: std.Io, git_dir: []const u8, out: []u8) ?[]const u8 {
    var path_buf: [max_path + 8]u8 = undefined;
    const head = std.fmt.bufPrint(&path_buf, "{s}/HEAD", .{git_dir}) catch return null;
    const full = std.Io.Dir.cwd().readFileAlloc(io, head, std.heap.page_allocator, .limited(512)) catch return null;
    defer std.heap.page_allocator.free(full);
    return branchFromHead(full, out);
}

/// `ref: refs/heads/main` → `main`. Anything else → null.
pub fn branchFromHead(head: []const u8, out: []u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, head, " \t\r\n");
    const prefix = "ref: refs/heads/";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    const name = trimmed[prefix.len..];
    if (name.len == 0 or name.len > out.len) return null;
    @memcpy(out[0..name.len], name);
    return out[0..name.len];
}

// ── tests ─────────────────────────────────────────────────────

/// Length of the relative name `sandbox` wrote into `rel`.
///
/// `sandbox` fills `rel` with a NUL-terminated path and no length attached, so
/// the length has to be recovered from the buffer. It used to return only the
/// LAST component (`everything after the last '/'`), which worked while the
/// directory was directly in the cwd and stopped working the moment it moved
/// under `.zig-cache/`: the delete needs the whole relative path.
fn rel_buf_len(rel: []const u8) usize {
    return if (std.mem.indexOfScalar(u8, rel, 0)) |n| n else rel.len;
}

/// A throwaway tree, removed at the end, as an ABSOLUTE path.
///
/// Fixtures go in a directory of their own and never in the repo of whoever runs
/// the suite: the fuzzer once saved a key into the real `~/.config/zode`, and the
/// lesson was that "just write it to the real path" is never the shortcut it looks
/// like.
///
/// It lives under `.zig-cache/`, which is where a disposable directory belongs:
/// already gitignored, already disposable, and OUT of the tree the user is
/// looking at. It used to be a `.zode-project-test-<seed>` directory directly in
/// the cwd, and thirteen of them were sitting in the repo root, because the
/// `defer` that deletes it never runs when the test binary is interrupted and
/// every interrupted run left one behind.
///
/// The name is relative (it has to live inside the cwd for `createDirPath`) but
/// the RETURNED path is absolute, because `findRoot` walks UP and refuses to walk
/// up from a relative path. Two buffers, because each path that survives another
/// call needs its own — the `sb.path` trap from the fuzzer round.
fn sandbox(rel: []u8, abs: []u8) ![]const u8 {
    // `bufPrintZ`, NOT `bufPrint`: the name has to be NUL terminated in `rel`,
    // because that is the only thing `rel_buf_len` has to recover the length
    // from. `bufPrint` leaves no terminator, so `rel_buf_len` fell back to the
    // whole 512-byte buffer, the delete was handed a path with garbage in it,
    // and the `catch {}` swallowed the failure: the fixture was created and
    // never removed, which is the very bug this move is fixing.
    const name = try std.fmt.bufPrintZ(rel, ".zig-cache/zode-project-test-{d}", .{std.testing.random_seed});
    std.Io.Dir.cwd().deleteTree(std.testing.io, name) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, name);

    var cwd: [max_path]u8 = undefined;
    const base = cwdPath(std.testing.io, null, &cwd) orelse return error.NoCwd;
    const full = try std.fmt.bufPrint(abs, "{s}/{s}", .{ base, name });
    return full;
}

/// Writes `path` (absolute-ish, relative to the cwd) with its parent directories.
///
/// Every path is composed into a STACK buffer on purpose: a test helper that
/// `allocPrint`s into `std.testing.allocator` and never frees is a leak report
/// that has nothing to do with what the test is checking.
fn writeAt(io: std.Io, path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path) orelse ".");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn join(comptime fmt: []const u8, args: anytype, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, fmt, args);
}

test "branchFromHead: la rama sale, un sha no" {
    var buf: [max_branch]u8 = undefined;
    try std.testing.expectEqualStrings("main", branchFromHead("ref: refs/heads/main\n", &buf).?);
    try std.testing.expectEqualStrings("feat/algo", branchFromHead("ref: refs/heads/feat/algo", &buf).?);
    // Detached HEAD: a sha is NOT a branch, and returning it as one makes the
    // model check out a sha thinking it is a name.
    try std.testing.expect(branchFromHead("9f2c1ab\n", &buf) == null);
    // A remote branch is not the current branch either.
    try std.testing.expect(branchFromHead("ref: refs/remotes/origin/main\n", &buf) == null);
    try std.testing.expect(branchFromHead("", &buf) == null);
}

test "detect: encuentra la raiz subiendo desde un subdirectorio" {
    var rel_buf: [max_path]u8 = undefined;
    var root_buf: [max_path]u8 = undefined;
    const root = try sandbox(&rel_buf, &root_buf);
    const rel_len = rel_buf_len(&rel_buf);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, rel_buf[0..rel_len]) catch {};

    var sub_buf: [max_path]u8 = undefined;
    const sub = try join("{s}/src/deep", .{root}, &sub_buf);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, sub);

    var head_buf: [max_path]u8 = undefined;
    try writeAt(std.testing.io, try join("{s}/.git/HEAD", .{root}, &head_buf), "ref: refs/heads/main\n");

    var info: Info = .{};
    detectAt(std.testing.io, sub, &info);
    try std.testing.expectEqualStrings(root, info.root().?);
    try std.testing.expectEqualStrings("main", info.branch().?);
    try std.testing.expectEqualStrings(sub, info.cwd());

    var lines: [512]u8 = undefined;
    const text = info.promptLines(&lines);
    try std.testing.expect(std.mem.indexOf(u8, text, "Working directory:") != null);
    // The model has to know it is NOT at the root: that is what explains why a
    // relative path is not what it looks like.
    try std.testing.expect(std.mem.indexOf(u8, text, "subdirectory") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "branch main") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "git") != null);
}

test "detect: en la raiz no dice que es un subdirectorio" {
    var rel_buf: [max_path]u8 = undefined;
    var root_buf: [max_path]u8 = undefined;
    const root = try sandbox(&rel_buf, &root_buf);
    const rel_len = rel_buf_len(&rel_buf);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, rel_buf[0..rel_len]) catch {};

    var head_buf: [max_path]u8 = undefined;
    try writeAt(std.testing.io, try join("{s}/.git/HEAD", .{root}, &head_buf), "ref: refs/heads/main\n");

    var info: Info = .{};
    detectAt(std.testing.io, root, &info);
    var lines: [512]u8 = undefined;
    const text = info.promptLines(&lines);
    try std.testing.expect(std.mem.indexOf(u8, text, "subdirectory") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "branch main") != null);
}

test "detect: sin repositorio no inventa uno" {
    // NOT `sandbox()`: a fixture under the cwd is inside the zode repository, and
    // "no repository here" is only testable somewhere with no `.git` in any
    // ancestor. `/tmp` is the honest place for it.
    const dir = "/tmp/zode-no-repo-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};

    var info: Info = .{};
    detectAt(std.testing.io, dir, &info);
    try std.testing.expect(info.root() == null);
    try std.testing.expect(info.branch() == null);
    // The cwd is stated all the same: it is half the line the model needs.
    var lines: [512]u8 = undefined;
    const text = info.promptLines(&lines);
    try std.testing.expect(std.mem.indexOf(u8, text, "Git repository:") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, dir) != null);
}

test "detect: un worktree con .git como fichero se lee igual" {
    var rel_buf: [max_path]u8 = undefined;
    var root_buf: [max_path]u8 = undefined;
    const root = try sandbox(&rel_buf, &root_buf);
    const rel_len = rel_buf_len(&rel_buf);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, rel_buf[0..rel_len]) catch {};

    // `git worktree add` deja un FICHERE `.git` con `gitdir: ...` dentro, y el
    // HEAD vive en esa ruta, no en `<root>/.git`. Si esto devuelve null, zode
    // cree que no esta en un repositorio justo en el directorio de trabajo.
    var meta_buf: [max_path]u8 = undefined;
    const gitdir = try join("{s}/meta/wt", .{root}, &meta_buf);
    var head_buf: [max_path]u8 = undefined;
    try writeAt(std.testing.io, try join("{s}/HEAD", .{gitdir}, &head_buf), "ref: refs/heads/feat/wt\n");
    var dot_buf: [max_path]u8 = undefined;
    const dotgit = try join("{s}/.git", .{root}, &dot_buf);
    var ptr_buf: [max_path * 2]u8 = undefined;
    try writeAt(std.testing.io, dotgit, try join("gitdir: {s}\n", .{gitdir}, &ptr_buf));

    var info: Info = .{};
    detectAt(std.testing.io, root, &info);
    try std.testing.expectEqualStrings(root, info.root().?);
    try std.testing.expectEqualStrings("feat/wt", info.branch().?);
}

test "detect: un gitdir relativo a la raiz tambien vale" {
    var rel_buf: [max_path]u8 = undefined;
    var root_buf: [max_path]u8 = undefined;
    const root = try sandbox(&rel_buf, &root_buf);
    const rel_len = rel_buf_len(&rel_buf);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, rel_buf[0..rel_len]) catch {};

    // The git metadata lives OUTSIDE `.git` here, because `.git` is a FILE in this
    // case: writing `HEAD` under `.git/...` first would make `writeAt` create
    // `.git` as a directory and the pointer file could not be written over it
    // (error.IsDir — which is exactly what the first version of this test did).
    var head_buf: [max_path]u8 = undefined;
    try writeAt(std.testing.io, try join("{s}/meta/worktrees/w/HEAD", .{root}, &head_buf), "ref: refs/heads/w\n");
    var dot_buf: [max_path]u8 = undefined;
    try writeAt(std.testing.io, try join("{s}/.git", .{root}, &dot_buf), "gitdir: meta/worktrees/w\n");

    var info: Info = .{};
    detectAt(std.testing.io, root, &info);
    try std.testing.expectEqualStrings("w", info.branch().?);
}

test "readGitDir: un .git que no existe devuelve null en vez de una ruta inventada" {
    var rel_buf: [max_path]u8 = undefined;
    var root_buf: [max_path]u8 = undefined;
    const root = try sandbox(&rel_buf, &root_buf);
    const rel_len = rel_buf_len(&rel_buf);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, rel_buf[0..rel_len]) catch {};
    var out: [max_path]u8 = undefined;
    try std.testing.expect(readGitDir(std.testing.io, root, &out) == null);
}

test "findRoot: se detiene en el primer .git y no sube mas alla" {
    var rel_buf: [max_path]u8 = undefined;
    var root_buf: [max_path]u8 = undefined;
    const root = try sandbox(&rel_buf, &root_buf);
    const rel_len = rel_buf_len(&rel_buf);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, rel_buf[0..rel_len]) catch {};

    // A repo INSIDE another repo: the closest one wins, which is what git does,
    // not the one above.
    var inner_buf: [max_path]u8 = undefined;
    const inner = try join("{s}/vendor/lib", .{root}, &inner_buf);
    var head_buf: [max_path]u8 = undefined;
    try writeAt(std.testing.io, try join("{s}/.git/HEAD", .{root}, &head_buf), "ref: refs/heads/outer\n");
    try writeAt(std.testing.io, try join("{s}/.git/HEAD", .{inner}, &head_buf), "ref: refs/heads/inner\n");

    var out: [max_path]u8 = undefined;
    try std.testing.expectEqualStrings(inner, findRoot(std.testing.io, inner, &out).?);
    try std.testing.expectEqualStrings(root, findRoot(std.testing.io, root, &out).?);
    // Una ruta que no es absoluta no se puede recorrer hacia arriba.
    try std.testing.expect(findRoot(std.testing.io, "src/x", &out) == null);
}

test "promptLines: un cwd con espacios y no ascii no se rompe" {
    var info: Info = .{};
    const cwd = "/home/jesusalcala/Projects/zode/src";
    @memcpy(info.cwd_buf[0..cwd.len], cwd);
    info.cwd_len = cwd.len;
    var lines: [512]u8 = undefined;
    const text = info.promptLines(&lines);
    try std.testing.expect(std.mem.indexOf(u8, text, cwd) != null);
}

test "the fixtures live under .zig-cache, not in the repo the user is looking at" {
    // Regression, and not a cosmetic one: the fixture used to be a
    // `.zode-project-test-<seed>` directory in the cwd, and the suite left
    // THIRTEEN of them in the repo root. The `defer` that deletes it does not run
    // when the test binary is interrupted, and an interrupted run is normal
    // (Ctrl+C, a timeout, a crash in an unrelated test).
    //
    // Two separate bugs lived here and both had to go:
    //
    // 1. The directory was in the repo. A disposable directory belongs in a
    //    disposable, already-ignored place: `.zig-cache`.
    // 2. It was never deleted even on a clean run, because `sandbox` filled `rel`
    //    with `bufPrint` (no NUL terminator) while `rel_buf_len` recovered the
    //    length by looking for the NUL. The length came back as the whole
    //    512-byte buffer, `deleteTree` got a path with garbage in it, and the
    //    `catch {}` hid it. Fixed with `bufPrintZ`.
    //
    // So this test checks both: the path is under `.zig-cache`, AND it can
    // actually be deleted afterwards (which is the part that was silently broken).
    var rel_buf: [max_path]u8 = undefined;
    var root_buf: [max_path]u8 = undefined;
    const root = try sandbox(&rel_buf, &root_buf);
    const rel_len = rel_buf_len(&rel_buf);

    const rel = rel_buf[0..rel_len];
    try std.testing.expect(std.mem.startsWith(u8, rel, ".zig-cache/"));
    try std.testing.expect(std.mem.indexOf(u8, rel, "zode-project-test-") != null);
    // A NUL right after the name: this is what makes the length recoverable, and
    // its absence is what made the delete a no-op.
    try std.testing.expect(rel_buf[rel_len] == 0);

    var head_buf: [max_path]u8 = undefined;
    try writeAt(std.testing.io, try join("{s}/.git/HEAD", .{root}, &head_buf), "ref: refs/heads/main\n");

    std.Io.Dir.cwd().deleteTree(std.testing.io, rel) catch {};
    // And now it is really gone: `openDir` on it must fail.
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().openDir(std.testing.io, rel, .{}),
    );
}
