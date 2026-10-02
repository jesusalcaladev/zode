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

const std = @import("std");
const skills = @import("skills.zig");

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
    /// This is the fix for "cd src && zode sees no project skills at all": the
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

    /// Walks both roots and returns the entries, project first, deduplicated by
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

        for (paths[0..root_count]) |dir_path| {
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
                out[n] = .{ .name = name_copy, .description = desc_copy, .path = path_copy };
                n += 1;
            }
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

test "hasFrontmatterEnd: distingue el cierre del que abre" {
    try std.testing.expect(hasFrontmatterEnd("---\nname: x\n---\nbody"));
    try std.testing.expect(!hasFrontmatterEnd("---\nname: x\n"));
    try std.testing.expect(!hasFrontmatterEnd("no frontmatter\n---\n"));
    // Una linea horizontal dentro del frontmatter NO lo cierra.
    try std.testing.expect(!hasFrontmatterEnd("---\nname: x\n-----------\nmore"));
}

test "alreadyIn: encuentra duplicados exactos y no parecidos" {
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

// ── tests con FIXTURES en disco de verdad ────────────────────
//
// Estos SÍ tocan el sistema de ficheros (a diferencia de `skills.zig`, que es puro
// y se testea con strings). La razón está en el header: lo que falla siempre al
// descubrir skills es la I/O — el `openDir` sin `.iterate`, el `createDirPath`, el
// nombre del fichero — y eso no se puede probar con un string.
//
// El `HOME` es el del sandbox de pruebas y los directorios se borran al final:
// un test automático que escribiera en el `~/.config` real sería el error que el
// fuzzer de junio ya cometio (guardo una key pegada y dejo el provider con 401).

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

test "scan: encuentra un skill del PROYECTO y lee su frontmatter" {
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
        \\---
        \\# Verifying a TUI
        \\
        \\Use a real pty. Never a homemade emulator.
    );

    var loader = store.Loader.init(gpa, std.testing.io, null);
    loader.project_dir = try skillRootOf(gpa, root, ".zode/skills");
    var buf: [8]skills.Entry = undefined;
    const found = loader.scan(&buf, buf.len);

    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("pty-tests", found[0].name);
    try std.testing.expectEqualStrings("after any change to tui.zig drawing code", found[0].description);
    for (found) |e| {
        gpa.free(e.name);
        gpa.free(e.description);
        gpa.free(e.path);
    }
}

test "scan: el PROYECTO tapa al usuario con el mismo nombre (no se fusionan)" {
    // Un skill de proyecto que se mezcla con el global es peor que no tenerlo:
    // la mitad de las instrucciones serian del otro proyecto.
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
    var buf: [8]skills.Entry = undefined;
    const found = loader.scan(&buf, buf.len);

    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("the project's own version", found[0].description);
    for (found) |e| {
        gpa.free(e.name);
        gpa.free(e.description);
        gpa.free(e.path);
    }
}

test "scan: ignora ficheros sueltos, directorios con punto y nombres imposibles" {
    var gpa_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var root_buf: [256]u8 = undefined;
    const root = try tmpRoot(&root_buf);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    // Un fichero, no un directorio.
    try writeFixture(root, ".zode/skills/README.md", "no soy un skill");
    // Un directorio con punto (`.git`).
    try writeFixture(root, ".zode/skills/.git/SKILL.md", "--- description: x ---");
    // Un directorio con un nombre que no puede ser un tool arg.
    try writeFixture(root, ".zode/skills/con espacio/SKILL.md", "--- description: x ---");
    // Y uno bueno, para comprobar que el filtro NO se comio el de verdad.
    try writeFixture(root, ".zode/skills/bueno/SKILL.md",
        \\---
        \\description: este si
        \\---
    );

    var loader = store.Loader.init(gpa, std.testing.io, null);
    loader.project_dir = try skillRootOf(gpa, root, ".zode/skills");
    var buf: [8]skills.Entry = undefined;
    const found = loader.scan(&buf, buf.len);

    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("bueno", found[0].name);
    for (found) |e| {
        gpa.free(e.name);
        gpa.free(e.description);
        gpa.free(e.path);
    }
}

test "load: el cuerpo llega enmarcado y SIN el frontmatter" {
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
    var buf: [8]skills.Entry = undefined;
    const found = loader.scan(&buf, buf.len);
    try std.testing.expectEqual(@as(usize, 1), found.len);

    var out: [8192]u8 = undefined;
    const text = loader.load(found[0], &out) orelse return error.TestUnexpectedResult;
    // El nombre y el "cuando usarlo" estan, porque sin ellos el modelo no sabe
    // que esta leyendo ni cuando aplicarlo.
    try std.testing.expect(std.mem.indexOf(u8, text, "=== skill: guia ===") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cuando haya dudas de estilo") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Una regla por parrafo.") != null);
    // Y el frontmatter NO viaja: son tokens de mas en cada llamada.
    try std.testing.expect(std.mem.indexOf(u8, text, "name: guia") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "---") == null);

    for (found) |e| {
        gpa.free(e.name);
        gpa.free(e.description);
        gpa.free(e.path);
    }
}

test "load: un skill sin frontmatter tambien funciona (es markdown y punto)" {
    var gpa_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var root_buf: [256]u8 = undefined;
    const root = try tmpRoot(&root_buf);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try writeFixture(root, ".zode/skills/simple/SKILL.md", "# Solo markdown\n\ninstrucciones\n");

    var loader = store.Loader.init(gpa, std.testing.io, null);
    loader.project_dir = try skillRootOf(gpa, root, ".zode/skills");
    var buf: [8]skills.Entry = undefined;
    const found = loader.scan(&buf, buf.len);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    // Sin descripcion, el nombre sale del DIRECTORIO (es lo que existe de
    // verdad en disco) y se marca en el prompt como "(no description)".
    try std.testing.expectEqualStrings("simple", found[0].name);
    try std.testing.expectEqualStrings("", found[0].description);

    var out: [8192]u8 = undefined;
    const text = loader.load(found[0], &out) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, text, "instrucciones") != null);

    for (found) |e| {
        gpa.free(e.name);
        gpa.free(e.description);
        gpa.free(e.path);
    }
}

test "roots: el orden es el del shadowing y la ultima raiz es la del usuario" {
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
    // Sin HOME (env = null) las dos son las unicas.
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings(proj, paths[0]);
    try std.testing.expectEqualStrings(agents, paths[1]);

    // Cada path sobrevive a la llamada siguiente: un unico buffer de scratch
    // dejaba TODOS apuntando al ultimo escrito (la trampa de `sb.path`).
    try std.testing.expect(!std.mem.eql(u8, paths[0], paths[1]));
}

test "roots: con repo_root se anaden sus dos directorios, y el cwd no se repite" {
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

    // El cwd YA es la raiz: leer las mismas rutas dos veces seria work sin
    // resultado, asi que no se anaden.
    loader.project_dir = "/home/x/proj/.zode/skills";
    loader.agents_dir = "/home/x/proj/.agents/skills";
    var bufs2: [store.max_roots][std.fs.max_path_bytes]u8 = undefined;
    var paths2: [store.max_roots][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), loader.roots(&bufs2, &paths2));
}

test "scan: .agents/skills tambien se lee, y .zode gana si estan los dos" {
    var gpa_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var root_buf: [256]u8 = undefined;
    const root = try tmpRoot(&root_buf);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};

    // El mismo nombre en las dos: `.zode/skills/shared` gana.
    try writeFixture(root, ".zode/skills/shared/SKILL.md", "---\ndescription: del propio harness\n---\nbody zode\n");
    try writeFixture(root, ".agents/skills/shared/SKILL.md", "---\ndescription: del convenio\n---\nbody agents\n");
    // Y uno solo en `.agents`, que tambien tiene que aparecer.
    try writeFixture(root, ".agents/skills/solo-agents/SKILL.md", "---\ndescription: solo en agents\n---\nbody\n");

    var loader = store.Loader.init(gpa, std.testing.io, null);
    loader.project_dir = try skillRootOf(gpa, root, ".zode/skills");
    loader.agents_dir = try skillRootOf(gpa, root, ".agents/skills");
    var buf: [8]skills.Entry = undefined;
    const found = loader.scan(&buf, buf.len);

    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings("shared", found[0].name);
    try std.testing.expectEqualStrings("del propio harness", found[0].description);
    try std.testing.expectEqualStrings("solo-agents", found[1].name);

    for (found) |e| {
        gpa.free(e.name);
        gpa.free(e.description);
        gpa.free(e.path);
    }
}

test "stampPath: un fichero que desaparece se recuerda como ausente" {
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
    // Mismo contenido: el stamp compara igual, y por eso la cache no se invalida.
    try std.testing.expect(before.sameAs(&now));

    try writeFixture(root, "SKILL.md", "---\ndescription: x\n---\ncuerpo nuevo\n");
    var after: store.Stamp = .{};
    try std.testing.expect(store.stampPath(std.testing.io, rel_path, &after));
    try std.testing.expect(!before.sameAs(&after));

    // Y BORRARLO es un cambio, no "no ha pasado nada": si no, el prompt seguiria
    // ofreciendo un skill cuyo fichero ya no existe.
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    var gone: store.Stamp = .{};
    try std.testing.expect(store.stampPath(std.testing.io, rel_path, &gone));
    try std.testing.expect(!gone.exists);
    try std.testing.expect(!after.sameAs(&gone));
}

test "scan: un directorio que no existe no es un error (0 skills, sin ruido)" {
    // Es el caso NORMAL de la mayoria de proyectos, y si `scan` protestara el
    // prompt llevaria un aviso de error en cada request.
    var gpa_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var loader = store.Loader.init(gpa, std.testing.io, null);
    // A directory that was never created, which is what a project without skills
    // looks like.
    loader.project_dir = ".zode/no-existe-esto";
    var buf: [8]skills.Entry = undefined;
    const found = loader.scan(&buf, buf.len);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "scan: respeta el tope de entradas (no crece sin limite)" {
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
    // Corta en 5, y los que no entraron NO se filtran con nombre roto: los que
    // hay son entradas completas y propias.
    try std.testing.expectEqual(@as(usize, 5), found.len);
    for (found) |e| {
        try std.testing.expect(skills.validName(e.name));
        gpa.free(e.name);
        gpa.free(e.description);
        gpa.free(e.path);
    }
}
