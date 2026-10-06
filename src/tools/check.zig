/// `check`: run the project's own typecheck, in the background, and report the
/// errors with a file and a line.
///
/// ## Why it is not `bash`
///
/// The command is already known to the harness: `build.zig` means `zig build`,
/// `tsconfig.json` means `tsc --noEmit`. Making the model type it means one round
/// trip to arrive at a string it could have been told, and — worse — that it
/// types it *every time*, or forgets.
///
/// ## Why it is not an LSP
///
/// An LSP gives real diagnostics for 200 ms at the cost of a process per language
/// and, on a good machine, a gigabyte of RAM. This gives the same information
/// with the project's own compiler, already installed, for zero extra bytes of
/// memory. What it does NOT give is per-keystroke latency, and that is the honest
/// trade: the error arrives after the edit, not before the line is finished.
///
/// ## The background is not an optimisation, it is the point
///
/// A typecheck can take 40 s. In the foreground that is 40 s in which the user
/// cannot type and the model cannot think. Started in the background, the model
/// goes on reading the next file and the result is waiting when it looks — which
/// is also why the result is only worth anything if something collects it, and
/// that is `agent.autoCheck`, not this tool.
const std = @import("std");
const common = @import("common.zig");
const bgproc = @import("../bgproc.zig");
const tcheck = @import("../lib/typecheck.zig");

/// The command for the project rooted at `dir`, or null.
///
/// Exposed for the tests and for `agent.autoCheck`, which wants the SAME answer
/// this tool would give without spawning anything.
/// Marker FILES, as data.
///
/// It is a table and not a dozen `if`s because it is the thing that grows: a language is
/// one row here plus one in `typecheck.planFor`, and with the `if`s it was a hunt for
/// the one that had been forgotten.
/// A `Markers` field, as an enum, because `@field` needs a comptime-known name and a
/// `[]const u8` is not one. With strings here the table does not compile, which is the
/// kind of thing a compiler settles for you.
const MarkerField = enum {
    zig_build,
    cargo_toml,
    tsconfig,
    go_mod,
    pyproject,
    mix_exs,
    gemfile,
    csproj,
    gradle,
    pom,
    composer,
    dune_project,
};

const markers = [_]struct { field: MarkerField, files: []const []const u8 }{
    .{ .field = .zig_build, .files = &.{"build.zig"} },
    .{ .field = .cargo_toml, .files = &.{"Cargo.toml"} },
    .{ .field = .tsconfig, .files = &.{ "tsconfig.json", "jsconfig.json" } },
    .{ .field = .go_mod, .files = &.{"go.mod"} },
    .{ .field = .pyproject, .files = &.{ "pyproject.toml", "setup.py", "setup.cfg", "requirements.txt" } },
    .{ .field = .mix_exs, .files = &.{"mix.exs"} },
    .{ .field = .gemfile, .files = &.{"Gemfile"} },
    .{ .field = .csproj, .files = &.{"global.json"} },
    .{ .field = .gradle, .files = &.{ "build.gradle", "build.gradle.kts", "settings.gradle" } },
    .{ .field = .pom, .files = &.{"pom.xml"} },
    .{ .field = .composer, .files = &.{"composer.json"} },
    .{ .field = .dune_project, .files = &.{ "dune-project", "dune" } },
};

/// Source extensions that prove the language is actually USED here.
///
/// The marker alone is not enough: a repository can carry a `Gemfile` for a vendored
/// gem and no Ruby of its own, and running `ruby -c` on it proves nothing. The pair
/// (marker AND source) is what makes the answer mean something, and it is the same rule
/// Python already followed.
const SourceField = enum {
    py_source,
    mix_source,
    rb_source,
    cs_source,
    java_source,
    php_source,
    ocaml_source,
};

const sources = [_]struct { field: SourceField, ext: []const u8 }{
    .{ .field = .py_source, .ext = ".py" },
    .{ .field = .mix_source, .ext = ".ex" },
    .{ .field = .mix_source, .ext = ".exs" },
    .{ .field = .rb_source, .ext = ".rb" },
    .{ .field = .cs_source, .ext = ".cs" },
    .{ .field = .java_source, .ext = ".java" },
    .{ .field = .java_source, .ext = ".kt" },
    .{ .field = .php_source, .ext = ".php" },
    .{ .field = .ocaml_source, .ext = ".ml" },
    .{ .field = .ocaml_source, .ext = ".mli" },
};

pub fn planAt(io: std.Io, dir: []const u8) ?tcheck.Plan {
    var m = tcheck.Markers{};

    var dirh = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return null;
    var it = dirh.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .file) continue;
        m.zig_build = m.zig_build or std.mem.eql(u8, e.name, "build.zig");
        m.cargo_toml = m.cargo_toml or std.mem.eql(u8, e.name, "Cargo.toml");
        m.tsconfig = m.tsconfig or std.mem.eql(u8, e.name, "tsconfig.json");
        m.go_mod = m.go_mod or std.mem.eql(u8, e.name, "go.mod");
        m.pyproject = m.pyproject or std.mem.eql(u8, e.name, "pyproject.toml") or
            std.mem.eql(u8, e.name, "setup.py");
        // One table for the markers and one for the extensions, so adding a language is
        // two lines and not a hunt through a `if` per ecosystem.
        // `inline for`: it unrolls at comptime, which is what makes `@field` legal
        // with a table. A plain `for` over the same table does not compile.
        inline for (markers) |mk| {
            for (mk.files) |f| {
                if (std.mem.eql(u8, e.name, f)) @field(m, @tagName(mk.field)) = true;
            }
        }
        inline for (sources) |src| {
            if (std.mem.endsWith(u8, e.name, src.ext)) @field(m, @tagName(src.field)) = true;
        }
    }
    dirh.close(io);

    // `node_modules/.bin/tsc` decides between `npx tsc` and the local binary. It
    // lives one level down, so the iteration above cannot see it — and it is
    // precisely the case that matters, because `npx` re-resolves the package on
    // every run and can reach the NETWORK.
    if (m.tsconfig) {
        var nd = std.Io.Dir.cwd().openDir(io, dir, .{}) catch return tcheck.planFor(m);
        defer nd.close(io);
        nd.access(io, "node_modules/.bin/tsc", .{}) catch return tcheck.planFor(m);
        m.tsc_local = true;
    }
    return tcheck.planFor(m);
}

/// `check` with no arguments: start the project's typecheck.
pub fn toolCheck(
    io: std.Io,
    obj: std.json.ObjectMap,
    arena: std.mem.Allocator,
    reg: ?*bgproc.Registry,
    gpa: std.mem.Allocator,
) ![]const u8 {
    _ = &gpa; // the registry owns its allocator now; kept for the dispatcher's shape
    // With an id, this is the second half: read what the job printed.
    if (common.getInt(obj, "id")) |id_i| {
        if (id_i <= 0) return error.MissingId;
        return report(arena, reg orelse return error.NoBackgroundRegistry, @intCast(id_i));
    }

    const subdir = common.getStr(obj, "subdir") orelse ".";
    // The plan BEFORE the registry, and the order is the point: "this project has
    // no typecheck I know, run it yourself with bash" is an answer the model can
    // act on, and `error.NoBackgroundRegistry` is not. A tool that fails with an
    // error where it had something useful to say spends the round trip to say
    // nothing.
    const plan = planAt(io, subdir) orelse return std.fmt.allocPrint(
        arena,
        "no typecheck is known for this project (no build.zig, Cargo.toml, tsconfig.json, go.mod, pyproject.toml, mix.exs, Gemfile, global.json, build.gradle, pom.xml, composer.json or dune-project). Run whatever the project uses with `bash`, in the background: bash with run_in_background true.",
        .{},
    );

    const r = reg orelse return error.NoBackgroundRegistry;

    const id = bgproc.spawn(r, io, plan.command) catch |err| switch (err) {
        error.TooManyJobs => return std.fmt.allocPrint(
            arena,
            "there are already {d} background jobs. Wait for one with bash_output before starting a check.",
            .{bgproc.max_jobs},
        ),
        else => return std.fmt.allocPrint(arena, "could not start `{s}`: {t}", .{ plan.command, err }),
    };

    return std.fmt.allocPrint(
        arena,
        "started `{s}` as job {d} in the background. Keep working; ask for it with `check {{id:{d}}}` (or bash_output) when you want the errors. It finds type errors you cannot see by reading, and it costs you no round trip to have running.",
        .{ plan.label, id, id },
    );
}

/// The second half of `check`: what the job printed, as errors with locations.
pub fn report(arena: std.mem.Allocator, reg: *bgproc.Registry, id: u32) ![]const u8 {
    var out = bgproc.Output{};
    // `readNoHeader` and NOT `read`: the header is zode's own line
    // `[zig build] finished exit=1`, and a scanner looking for `file:line: error:`
    // finds the whole command inside it. That is not a cosmetic problem — the
    // probe reported one more "error" than the build had, and the model is told to
    // fix every line it is given.
    const text = bgproc.readNoHeader(reg, &out, id) catch |err| switch (err) {
        error.NoNewOutput => return std.fmt.allocPrint(arena, "the check is still running, nothing new yet. Keep working and ask again later.", .{}),
        error.UnknownJob => return std.fmt.allocPrint(arena, "no check job {d}.", .{id}),
    };

    const running = std.mem.eql(u8, bgproc.stateWord(reg, id), "running");
    const diags = try tcheck.extractDiagnostics(arena, text, 12);

    if (diags.len == 0) {
        if (running) return "the check is still running and has printed no error yet.";
        // THE FAILED-EXIT CASE, and it is the dangerous direction.
        //
        // Measured: a `build.zig` that panics prints a source location and a
        // `thread N panic:` line — neither of which is `file:line: error:`, so the
        // diagnostic scan found nothing, and the tool said **"no type errors"** while
        // the build had exited 2 and produced a stack trace.
        //
        // A check that fails and reports success is worse than no check: the model
        // reads "no type errors" and carries on editing a project whose build does
        // not even run. So a non-zero exit with no diagnostics is reported as a
        // failure, with the tail of the output, which is where a panic or a missing
        // dependency actually is.
        const failed = !running and out.exit != null and out.exit.? != 0;
        if (failed) {
            var m: std.ArrayList(u8) = .empty;
            try m.print(arena, "the check FAILED (exit {d}) and did not report a type error. That usually means the build itself could not run — a broken build script, a missing dependency, or a panic. The output:", .{out.exit.?});
            const tail = text[if (text.len > 2000) text.len - 2000 else 0..];
            try m.print(arena, "\n{s}\nDo NOT treat this as a passing build: fix what the output says first.", .{tail});
            return m.items;
        }
        return "no type errors. The code compiles as far as this project's own check can tell.";
    }

    var msg: std.ArrayList(u8) = .empty;
    try msg.print(arena, "{d} type error(s):\n{s}", .{ countLines(diags), diags });
    if (running) try msg.appendSlice(arena, "\n(the check is still running; there may be more)");
    try msg.appendSlice(arena, "\nFix these before writing more code: each one is a line you can read.");
    return msg.items;
}

fn countLines(s: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |l| if (std.mem.trim(u8, l, " \t\r").len != 0) {
        n += 1;
    };
    return n;
}
