/// Which command TYPECHECKS this project, and why it is worth running.
///
/// ## What this is for
///
/// The single most expensive mistake an agent makes is finding out it broke
/// something one iteration too late: the edit is applied, the next request goes
/// out with the broken state in the prompt, the tokens for that request are
/// billed, and only then does a build say so.
///
/// An LSP would fix that with real diagnostics. This is the 80% of it that costs
/// **zero bytes of RAM** and needs nothing installed: the project's own typecheck,
/// started in the background the moment an edit lands, so the error is already
/// waiting when the model looks.
///
/// `lib/verify.zig` already knows how long a command takes; this knows which
/// command to run. They are different questions and they were answered in
/// different files because the answers have different lifetimes.
///
/// ## Why a table and not a probe
///
/// Probing would mean reading `package.json` scripts, `build.zig` steps and
/// `Makefile` targets and hoping to pick the right one. A table of marker files is
/// wrong in exactly one way — an unusual project gets no typecheck — and that way
/// is silent and harmless: the tool says "no typecheck known here", and the model
/// runs `bash` like it does today. A probe is wrong in a way nobody can predict,
/// and it runs commands it assembled itself.
///
/// It is pure: no I/O, so the whole table is testable without a filesystem. The
/// caller does the `access` calls.
const std = @import("std");

/// The fastest thing that would FAIL if the code were wrong.
///
/// `slow` is not an option here even where a full build is the only check: this is
/// spawned in the background precisely so the model keeps working, so a command
/// that takes 40 s costs nothing except a poll.
pub const Plan = struct {
    /// The shell command line. Fixed, like `git.zig`'s: nothing from the model
    /// goes in it, so there is nothing for it to inject.
    command: []const u8,
    /// What the user would call this check, for the message the model reads.
    label: []const u8,
};

/// What the caller found on disk.
pub const Markers = struct {
    zig_build: bool = false,
    tsconfig: bool = false,
    tsc_local: bool = false,
    package_json: bool = false,
    cargo_toml: bool = false,
    go_mod: bool = false,
    /// `python -m compileall` catches syntax errors in seconds. Not a type
    /// check, and it is labelled honestly as a syntax check because "typecheck"
    /// would be a claim the command cannot back.
    pyproject: bool = false,
    py_source: bool = false,
    // The rest. Every one of these is a MARKER FILE and a fixed command, never
    // something the model names: a table that asks the model what to run is a table
    // that runs whatever the model wants.
    mix_exs: bool = false,
    mix_source: bool = false,
    gemfile: bool = false,
    rb_source: bool = false,
    csproj: bool = false,
    cs_source: bool = false,
    gradle: bool = false,
    java_source: bool = false,
    pom: bool = false,
    composer: bool = false,
    php_source: bool = false,
    dune_project: bool = false,
    ocaml_source: bool = false,
};

/// The command for this project, or null when nothing here is known.
///
/// Order matters and it is not alphabetical: the FIRST marker that matches wins,
/// so a repository with both a `build.zig` and a `package.json` (this one does)
/// gets the Zig check and not the JavaScript one. Without `order` this would be a
/// coin flip decided by the order of a struct's fields.
pub fn planFor(m: Markers) ?Plan {
    if (m.zig_build) return .{
        .command = "zig build",
        .label = "zig build",
    };
    if (m.cargo_toml) return .{
        .command = "cargo check",
        .label = "cargo check",
    };
    // `node_modules/.bin/tsc` before `npx tsc`: `npx` re-resolves the package on
    // every invocation and can reach the NETWORK, which on a rate-limited
    // connection turns a type check into a timeout. The local binary is the same
    // program and it is already on disk.
    if (m.tsconfig) return .{
        .command = if (m.tsc_local)
            "node_modules/.bin/tsc --noEmit --pretty false"
        else
            "npx tsc --noEmit --pretty false",
        .label = "tsc --noEmit",
    };
    if (m.go_mod) return .{
        .command = "go build ./...",
        .label = "go build ./...",
    };
    // Python last and only as what it is: a syntax check. Offering mypy here
    // would mean running a command that is not installed, failing, and reporting
    // a broken project for a missing dev dependency.
    if (m.pyproject and m.py_source) return .{
        .command = "python3 -m compileall -q .",
        .label = "python syntax check",
    };
    if (m.mix_exs and m.mix_source) return .{
        .command = "mix compile",
        .label = "mix compile",
    };
    // `.exs` is Elixir's build AND its test config, and `mix compile` is the cheapest
    // thing that answers "does this still parse". `mix credo` would be a lint nobody
    // asked for.
    if (m.dune_project and m.ocaml_source) return .{
        .command = "dune build",
        .label = "dune build",
    };
    // Ruby has no typechecker to run and pretending otherwise would mean installing
    // one. A syntax check is what the language actually offers, and it is labelled as
    // that.
    if (m.gemfile and m.rb_source) return .{
        .command = "ruby -c",
        .label = "ruby -c (syntax only; ruby has no typechecker)",
    };
    if (m.csproj and m.cs_source) return .{
        .command = "dotnet build --nologo -v q",
        .label = "dotnet build",
    };
    if (m.gradle and m.java_source) return .{
        .command = "gradle compileJava --quiet",
        .label = "gradle compileJava",
    };
    if (m.pom and m.java_source) return .{
        .command = "mvn -q -o compile",
        .label = "mvn compile",
    };
    if (m.composer and m.php_source) return .{
        .command = "php -l",
        .label = "php -l (syntax only)",
    };
    return null;
}

/// Is this change worth a typecheck at all?
///
/// `zig fmt` rewrites a file and `git commit` does not touch one; running a build
/// after either is a request spent proving nothing. It is a cheap gate in front of
/// a background job, and it is deliberately conservative in the other direction:
/// an edit to an unknown extension still triggers a check, because "we do not
/// know what this file is" is not the same as "this changed no code".
pub fn worthChecking(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    const interesting = [_][]const u8{
        ".zig", ".ts",  ".tsx",  ".mts", ".cts",   ".js", ".jsx", ".mjs",
        ".cjs", ".rs",  ".go",   ".py",  ".c",     ".h",  ".cc",  ".cpp",
        ".hpp", ".cxx", ".java", ".kt",  ".swift", ".rb", ".php", ".scala",
    };
    for (interesting) |e| {
        if (std.mem.eql(u8, ext, e)) return true;
    }
    // An extensionless file that is a well-known build script is still code:
    // `Makefile`, `CMakeLists.txt` has one so it is covered above, but `Makefile`
    // is the one that matters.
    const base = std.fs.path.basename(path);
    if (std.mem.eql(u8, base, "Makefile") or std.mem.eql(u8, base, "meson.build")) return true;
    return false;
}

/// Reads the first `max_bytes` of a command's output looking for
/// `path:line:col: error: …`, which is the shape of every compiler worth reading.
///
/// It is not a parser and does not try to be: the goal is to put the LINE in
/// front of the model so it can read that file, not to classify diagnostics. The
/// first N that match are returned, and everything else is dropped, because a
/// build that fails in 40 places is a build whose 41st error is noise.
pub fn extractDiagnostics(
    arena: std.mem.Allocator,
    output: []const u8,
    max: usize,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var found: usize = 0;
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |raw| {
        if (found >= max) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (!looksLikeDiagnostic(line)) continue;
        try out.print(arena, "{s}\n", .{clip(arena, line, 300)});
        found += 1;
    }
    if (found == 0) return "";
    return out.items;
}

/// `path:line:col: error|warning: …`, or `path:line: error: …`.
///
/// The `path` has to contain something that looks like a path or a source line —
/// a bare `error: expected …` with no location is not something the model can act
/// on, and printing forty of them buries the two that have a line number.
fn looksLikeDiagnostic(line: []const u8) bool {
    // A location: `x:12:3:` or `x:12:` where x ends in a source-ish extension.
    // The increment advances `i`. The first version had it advancing a second
    // variable, so the `continue` below — taken on every character that is not a
    // colon, which is most of the line — spun forever. A pure function that hangs
    // is worse than one that is wrong: the test suite did not fail, it stopped.
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] != ':') continue;
        var j = i + 1;
        var digits: usize = 0;
        while (j < line.len and std.ascii.isDigit(line[j])) : (j += 1) digits += 1;
        if (digits == 0) {
            i += 1;
            continue;
        }
        // col
        while (j < line.len and (line[j] == ':' or line[j] == '.')) j += 1;
        while (j < line.len and std.ascii.isDigit(line[j])) j += 1;
        if (j < line.len and line[j] == ':') j += 1;
        const rest = std.mem.trim(u8, line[j..], " \t");
        if (std.mem.startsWith(u8, rest, "error") or std.mem.startsWith(u8, rest, "warning")) {
            return true;
        }
        i += 1;
    }
    return false;
}

fn clip(arena: std.mem.Allocator, s: []const u8, n: usize) []const u8 {
    if (s.len <= n) return s;
    return arena.dupe(u8, s[0..n]) catch s[0..n];
}

// ── tests ────────────────────────────────────────────────────────

test "planFor: the marker file decides the command, and nothing comes from the model" {
    try std.testing.expectEqualStrings("zig build", (planFor(.{ .zig_build = true }) orelse unreachable).command);
    try std.testing.expectEqualStrings("cargo check", (planFor(.{ .cargo_toml = true }) orelse unreachable).command);
    try std.testing.expectEqualStrings("go build ./...", (planFor(.{ .go_mod = true }) orelse unreachable).command);
    try std.testing.expectEqualStrings("npx tsc --noEmit --pretty false", (planFor(.{ .tsconfig = true }) orelse unreachable).command);
    // The local binary, because `npx` can reach the network.
    try std.testing.expectEqualStrings(
        "node_modules/.bin/tsc --noEmit --pretty false",
        (planFor(.{ .tsconfig = true, .tsc_local = true }) orelse unreachable).command,
    );
}

test "planFor: a project with both build.zig and package.json gets the zig check" {
    // This repository is exactly that case. Without an explicit order the winner
    // would be decided by the order of a struct's fields, which is not a
    // decision anybody made.
    const m = Markers{ .zig_build = true, .package_json = true, .tsconfig = true };
    try std.testing.expectEqualStrings("zig build", (planFor(m) orelse unreachable).command);
}

test "planFor: an unknown project is null, and null means the model runs bash" {
    try std.testing.expect(planFor(.{}) == null);
    try std.testing.expect(planFor(.{ .package_json = true }) == null);
    // `pyproject.toml` alone is not enough: with no Python source there is
    // nothing to compile.
    try std.testing.expect(planFor(.{ .pyproject = true }) == null);
    // And it is called a SYNTAX check, not a typecheck, because that is what it is.
    try std.testing.expectEqualStrings(
        "python syntax check",
        (planFor(.{ .pyproject = true, .py_source = true }) orelse unreachable).label,
    );
}

test "worthChecking: code yes, formatting and lockfiles no" {
    for ([_][]const u8{ "src/a.zig", "a.ts", "a.go", "x.py", "main.c", "lib.rs", "Makefile", "a.hpp" }) |p| {
        try std.testing.expect(worthChecking(p));
    }
    for ([_][]const u8{ "README.md", "notes.txt", "build.lock", "package-lock.json", "a.png", "" }) |p| {
        try std.testing.expect(!worthChecking(p));
    }
}

test "extractDiagnostics: keeps the lines with a LOCATION and drops the rest" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();

    const out =
        \\Building.
        \\src/lib/foo.zig:12:5: error: unused local variable
        \\        never used.
        \\src/bar.ts:40:1: error: TS2345: Argument of type 'string'
        \\note: some explanatory prose
        \\error: expected '}' found 'EOF'
        \\src/baz.zig:1:2: warning: unused
    ;
    const d = try extractDiagnostics(a, out, 10);
    try std.testing.expect(std.mem.indexOf(u8, d, "src/lib/foo.zig:12:5: error") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "src/bar.ts:40:1: error") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "src/baz.zig:1:2: warning") != null);
    // The two without a location are gone: the model cannot open a line it was
    // not given, and 40 of them bury the 2 that have one.
    try std.testing.expect(std.mem.indexOf(u8, d, "expected '}'") == null);
    try std.testing.expect(std.mem.indexOf(u8, d, "explanatory prose") == null);
}

test "extractDiagnostics: a build with 40 errors gives the model 10" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();

    var buf: std.ArrayList(u8) = .empty;
    for (0..40) |i| {
        try buf.appendSlice(a, try std.fmt.allocPrint(a, "src/f.zig:{d}:1: error: nope {d}\n", .{ i + 1, i }));
    }
    const d = try extractDiagnostics(a, buf.items, 10);
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, d, '\n');
    while (it.next()) |l| if (std.mem.trim(u8, l, " \t").len != 0) {
        count += 1;
    };
    try std.testing.expectEqual(@as(usize, 10), count);
}

test "extractDiagnostics: no location at all means empty, not a wall of text" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const d = try extractDiagnostics(a, "error: something\nerror: something else\n", 10);
    try std.testing.expectEqualStrings("", d);
}
