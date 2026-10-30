const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // Version - can be overridden at build time: `zig build -Dversion=v0.1.0`
    const version = b.option([]const u8, "version", "Version string (default: dev)") orelse "dev";

    // ReleaseSmall for Default.
    //
    // `zig build` used to produce a Debug binary (10.8 MB, 79 % of it debug
    // sections, with the `DebugAllocator` on the hot path). Then it became
    // ReleaseSafe + strip, and now ReleaseSmall + strip. Measured on THIS tree
    // (nm/llvm-size on the unstripped binary, and tools/measure.py in a pty):
    //
    //   ReleaseSafe + strip   2.20 MB   (.text 1.82 MB · .rodata 0.51 MB)
    //   ReleaseSmall + strip  1.34 MB   (.text 0.86 MB · .rodata 0.38 MB)   <--
    //
    // And it costs no speed, at least in what is visible at startup: measure.py
    // gives 11 ms / 6.22 MB RSS with ReleaseSafe against 6 ms / 5.79 MB with
    // ReleaseSmall. The app is I/O-bound (it waits on the network and on the
    // user), so the optimize mode mostly decides how big the file ends up.
    //
    // THE FLOOR, so nobody measures again what does not depend on us (nm over
    // zode-debug, ReleaseSafe): crypto 509 KB — `std.crypto.tls.Client` mandates
    // key shares of x25519_ml_kem768/secp256r1/secp384r1/x25519 with no option to
    // trim them, and certificate verification drags in RSA, P-256, P-384, ed25519
    // and SHA-1 — plus 185 KB of rodata of `uucode`'s unicode tables, which comes
    // in through `vaxis.gwidth`. Both are dependencies (std and vaxis); changing
    // them is a `patch` declared in build.zig.zon, like 5.7/5.9.
    //
    // For real debugging: `zig build -Doptimize=Debug`, and
    // `-Doptimize=ReleaseSafe` if you ever need the fast binary instead of the
    // small one.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimize mode (default: ReleaseSmall)",
    ) orelse .ReleaseSmall;
    // Strip is ON by default because it takes the binary from 10.78 MB to 1.89 MB
    // (measured), and zode is I/O-bound so it costs nothing at runtime.
    //
    // **But `-Dstrip=false` DOES NOT GIVE YOU A DEBUGGABLE BUILD, and it used to be
    // documented here as if it did.** Measured 2026-10-06 while chasing a real SIGSEGV:
    //
    //     zig build -Dstrip=false  ->  nm: no hay símbolos
    //     readelf -SW              ->  no .symtab, no .debug_*   (not one section)
    //
    // `strip` only removes debug sections that were EMITTED, and ReleaseSafe /
    // ReleaseSmall do not emit them. There is nothing for it to keep, so "unstripped"
    // and "with symbols" are two different things and only the first one happens.
    //
    // For a crash trace, use the `debug` STEP, which builds in `.Debug` — that is where
    // the symbols come from. `debug_mod` below fell into this same trap, in a step whose
    // entire description was the promise it did not keep.
    const strip = b.option(bool, "strip", "Strip the debug sections (default: true)") orelse true;
    // The tests go in Debug on purpose (the DebugAllocator and the overflow checks
    // are what catch bugs), but their binary needs no symbols: without this every
    // rebuild leaves another 49 MB in `.zig-cache/o`.
    const strip_tests = b.option(bool, "strip-tests", "Strip the test binary (default: true)") orelse true;

    // The LIVE network tests (`web_fetch for real`, `web_search for real`, the
    // offset round trip, `braveSearch for real`) are OFF by default and behind
    // `zig build test -Dlive`.
    //
    // They are real requests to DuckDuckGo / Bing / example.com, and they fail
    // for reasons that are not zode's: measured on 2026-10-23, both DuckDuckGo
    // endpoints answered HTTP 202 (anomaly detection) for minutes at a time and
    // the suite went red on a machine where nothing had changed.
    //
    // A red suite that is red because a scraper got rate-limited is how a suite
    // gets ignored — and this one is IN the release workflow's test step, so a
    // scrape mood would block a release. The gate is the same idea as `-De2e`:
    // the tests stay reachable by hand (`zig build test -Dlive`), and they stop
    // being a coin toss on every run.
    const live = b.option(bool, "live", "run the live network tests (web fetch/search against the real internet)") orelse false;

    // Build options module for passing version to code
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    const build_options_mod = build_options.createModule();

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("build_options", build_options_mod);

    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("vaxis", vaxis.module("vaxis"));

    // The strip goes on the MODULE (`root_module.strip`), not on the executable.
    //
    // AND IT IS SET EXPLICITLY, in both directions: `strip = null` is NOT
    // "unstripped", it is "use the default", and the default for ReleaseSmall
    // and ReleaseFast is TO STRIP. So `if (strip) exe_mod.strip = true;` left
    // `-Dstrip=false` as a no-op, and the binary came out stripped anyway.
    // `false` has to be written down for it to mean anything.
    exe_mod.strip = strip;
    const exe = b.addExecutable(.{
        .name = "zode",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run zode");
    run_step.dependOn(&run_cmd.step);

    // `zig build debug` = the same binary but NOT stripped, which is what to use
    // when something crashes. The default binary has no symbols, so a panic comes
    // out as "Cannot print stack trace: stack tracing is disabled" — which is
    // precisely the moment you least want the build to be mute. (It happened: a
    // SIGSEGV with no way to tell where from.)
    //
    // **`.Debug` HERE, not `optimize`, and that one word was the whole bug.** This
    // step said "has symbols, for crash traces" and produced a binary the same size as
    // the stripped release one, with `nm` reporting no symbols and `readelf -SW` listing
    // no `.symtab` and no `.debug_*` section at all. Setting `strip = null` on a
    // ReleaseSmall module does not create debug info; it only declines to remove debug
    // info that was never emitted. So the one build whose entire job is to be
    // symbolizable was the one build with no symbols, and it took a real segfault to
    // find out.
    const debug_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .Debug,
    });
    debug_mod.addImport("vaxis", vaxis.module("vaxis"));
    // `build_options` is NOT optional: `main.zig` and `lib/selfupdate.zig`
    // import it for the version, and a module that does not have it cannot
    // compile at all.
    //
    // It was missing here, so `zig build debug` — the step whose ENTIRE job is
    // to be a trustworthy artifact for a crash — did not compile. The binary on
    // disk was a leftover from some earlier `zig build`, byte-identical to the
    // stripped release one: a file with a reassuring name and nothing behind it.
    debug_mod.addImport("build_options", build_options_mod);
    const debug_exe = b.addExecutable(.{ .name = "zode-debug", .root_module = debug_mod });
    // Kept as well as `.Debug`, and both are needed: `.Debug` is what CREATES the
    // symbols and `strip = null` is what stops them being taken away again.
    debug_exe.root_module.strip = null;
    // `addInstallArtifact` and NOT `installArtifact`, because of what was measured:
    // `installArtifact` hangs the artifact off the DEFAULT install step, so `zig build
    // debug` compiled the executable and never put it anywhere — the `zode-debug` that
    // existed on disk had been copied by some earlier plain `zig build`, and it was
    // BYTE-IDENTICAL to the stripped release binary (same md5). A step whose whole
    // promise is "here is your crash-trace binary" was producing no binary at all, and
    // the one on disk was a lie with a reassuring name.
    //
    // An install step that only this one depends on is also what keeps a normal
    // `zig build` from dropping a ~50 MB Debug binary into `zig-out/bin` every time.
    const install_debug = b.addInstallArtifact(debug_exe, .{});
    const debug_step = b.step("debug", "Build and install zode-debug in Debug: WITH SYMBOLS, for crash traces");
    debug_step.dependOn(&debug_exe.step);
    debug_step.dependOn(&install_debug.step);

    // tool_test binario temporal
    const tt_mod = b.createModule(.{
        .root_source_file = b.path("src/bin/tool_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Rooted at `src/tools_root.zig`, one level ABOVE `src/tools/`, on purpose:
    // a module's root file sets its module path, and the tools reach `bgproc`,
    // `readcache`, `regex` and `verify` from `src/`. Rooted inside `src/tools/`
    // those would be imports from outside the module. It only re-exports the
    // dispatcher; `tool_test.zig` keeps importing a module named `tools`.
    // The tools module needs its OWN `build_options` (with `live`): the live
    // network tests live in `src/tools/web.zig`, which is compiled here too.
    const tools_opts = b.addOptions();
    tools_opts.addOption(bool, "live", live);
    const tools_mod_root = b.createModule(.{
        .root_source_file = b.path("src/tools_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    tools_mod_root.addImport("build_options", tools_opts.createModule());
    tt_mod.addImport("tools", tools_mod_root);
    const tt = b.addExecutable(.{ .name = "tool_test", .root_module = tt_mod });
    const tt_run = b.addRunArtifact(tt);
    if (b.args) |args| tt_run.addArgs(args);
    const tt_step = b.step("tool-test", "Prueba las tools headless");
    tt_step.dependOn(&tt_run.step);

    // Free-auto probe: which providers have a key, how many free models each
    // one publishes, and the pool already sorted the way the wheel will use it.
    // Not a test: it talks to the network.
    //
    // Only `vaxis` is declared here; the probe picks the other modules BY PATH
    // (which is why the probe lives in `src/`, not `src/bin/`). Declaring them
    // here clashes too: a file cannot be the root of two modules in the same
    // compilation, and `providers.zig` already is the root of `agent`.
    // The typecheck probe: it shows what the model would be told after an edit,
    // with a real compiler's real diagnostics in it. Same placement reason as
    // `roster_probe` — `tools/check.zig` imports files above `src/tools/`, so a
    // module rooted in `src/bin/` cannot reach them.
    const check_probe_mod = b.createModule(.{
        .root_source_file = b.path("src/check_probe.zig"),
        .target = target,
        .optimize = optimize,
    });
    check_probe_mod.addImport("vaxis", vaxis.module("vaxis"));
    const check_probe = b.addExecutable(.{ .name = "check_probe", .root_module = check_probe_mod });
    const check_probe_run = b.addRunArtifact(check_probe);
    if (b.args) |args| check_probe_run.addArgs(args);
    const check_probe_step = b.step("check-probe", "Runs the automatic typecheck against a project with a deliberate error");
    check_probe_step.dependOn(&check_probe_run.step);

    const shell_mod = b.createModule(.{
        .root_source_file = b.path("src/shell_probe.zig"),
        .target = target,
        .optimize = optimize,
    });
    shell_mod.addImport("vaxis", vaxis.module("vaxis"));
    const shell_probe = b.addExecutable(.{ .name = "shell_probe", .root_module = shell_mod });
    const shell_probe_run = b.addRunArtifact(shell_probe);
    if (b.args) |args| shell_probe_run.addArgs(args);
    const shell_probe_step = b.step("shell-probe", "Measures what a bash tool call costs in the harness, against the child alone");
    shell_probe_step.dependOn(&shell_probe_run.step);

    const roster_mod = b.createModule(.{
        .root_source_file = b.path("src/roster_probe.zig"),
        .target = target,
        .optimize = optimize,
    });
    roster_mod.addImport("vaxis", vaxis.module("vaxis"));
    const roster_probe = b.addExecutable(.{ .name = "roster_probe", .root_module = roster_mod });
    const roster_probe_run = b.addRunArtifact(roster_probe);
    if (b.args) |args| roster_probe_run.addArgs(args);
    const roster_probe_step = b.step("roster-probe", "Shows the pool of free models of every provider");
    roster_probe_step.dependOn(&roster_probe_run.step);

    // The LSP probe: it asks a REAL language server about a real file and
    // prints what comes back. The companion of `tools/fake_lsp.py`, which
    // proves the wire and this one proves the server.
    //
    // Same placement reason as `roster_probe`: the module's path is the
    // directory, and the probe needs `lsp/` from `src/`.
    const lsp_probe_mod = b.createModule(.{
        .root_source_file = b.path("src/lsp_probe.zig"),
        .target = target,
        .optimize = optimize,
    });
    lsp_probe_mod.addImport("vaxis", vaxis.module("vaxis"));
    const lsp_probe = b.addExecutable(.{ .name = "lsp_probe", .root_module = lsp_probe_mod });
    const lsp_probe_run = b.addRunArtifact(lsp_probe);
    if (b.args) |args| lsp_probe_run.addArgs(args);
    const lsp_probe_step = b.step("lsp-probe", "Asks a real language server about a real file");
    lsp_probe_step.dependOn(&lsp_probe_run.step);

    // Tests that need vaxis (markdown/highlight test styles).
    // ALWAYS in Debug: the binary already comes out ReleaseSafe+strip, but
    // compiling the suite in ReleaseSafe takes 2 minutes and finds no MORE bug —
    // it finds fewer, because the DebugAllocator and the overflow checks are
    // exactly what catch them.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_all.zig"),
        .target = target,
        .optimize = .Debug,
        // The test binary in Debug weighs ~49 MB (almost all vaxis debug
        // sections) and `.zig-cache/o` keeps ONE PER REBUILD: 44 of them
        // accumulated once, which is 1.4 GB. The tests are not debugged with gdb,
        // so the symbols are worth nothing: `strip` brings it to ~10 MB.
        .strip = strip_tests,
    });
    test_mod.addImport("vaxis", vaxis.module("vaxis"));

    // The network E2E test (a REAL turn against a REAL provider) is OFF by default and
    // behind `zig build test -De2e`. Two reasons, and the second is the one that matters:
    //
    // 1. It costs money, takes thirty seconds, and fails for reasons that have nothing to
    //    do with zode (a rate limit, a provider having a bad minute).
    // 2. It takes over the module globals to run a real turn, and its teardown interacts
    //    with the test runner in a way that segfaults. That is a real defect in MY test
    //    and not in the harness, but shipping a test that crashes the suite to prove a
    //    point is how a suite gets ignored.
    //
    // The gate is a build option and not `ZODE_E2E` in the environment, because this Zig
    // version gives a test no way to read the process environment: `Environ.Map.init`
    // makes an EMPTY map, `std.posix.getenv` does not exist, and `std.testing.environ` is
    // `undefined` in a test. A flag the build understands is the only one a test can see.
    const e2e = b.option(bool, "e2e", "run the network E2E tests (needs a provider key)") orelse false;
    const opts = b.addOptions();
    opts.addOption(bool, "e2e", e2e);
    opts.addOption(bool, "live", live);
    opts.addOption([]const u8, "version", version);
    test_mod.addImport("build_options", opts.createModule());
    // `zig build test -- <filter>` runs only the tests whose name contains the
    // filter. Zig 0.16's runner has no `--test-filter`, so the filter is applied
    // AT COMPILE TIME (it does not reach the binary's args).
    const filters: []const []const u8 = if (b.args) |args| args else &.{};
    const tests = b.addTest(.{ .root_module = test_mod, .filters = filters });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // ── the design harness ────────────────────────────────────────────
    //
    // Renders scripted scenes of the TUI and prints them as ANSI text:
    // `zig build ui-frame -- turn 100 34`, `-- --flat all` for plain text.
    //
    // It exists because neither existing check can judge a DESIGN. The
    // `drawTest` unit tests compare a row against a string, so they prove a word
    // is there and say nothing about whether the frame is composed. The pty
    // smoke sees the truth about vaxis, but it needs a terminal, a timing
    // budget and (for a real turn) a key.
    //
    // Same placement reason as `check_probe`: a module rooted in `src/bin/`
    // cannot import files above it, and this needs `tui.zig`.
    const ui_frame_mod = b.createModule(.{
        .root_source_file = b.path("src/ui_frame.zig"),
        .target = target,
        .optimize = optimize,
    });
    ui_frame_mod.addImport("vaxis", vaxis.module("vaxis"));
    const ui_frame = b.addExecutable(.{ .name = "ui_frame", .root_module = ui_frame_mod });
    const ui_frame_run = b.addRunArtifact(ui_frame);
    if (b.args) |args| ui_frame_run.addArgs(args);
    const ui_frame_step = b.step("ui-frame", "Render scripted TUI scenes as ANSI text (design review)");
    ui_frame_step.dependOn(&ui_frame_run.step);

    // ── pty checks: the only verification that sees what vaxis renders ──
    //
    // vaxis renders DIFFERENTIALLY and queries the terminal (colors,
    // capabilities, size), so a `drawTest` surface cannot tell you what the
    // terminal ends up showing: a working turn can look frozen and a broken one
    // can look fine. These two scripts drive the real binary in a real pty.
    //
    // `zig build pty-check` builds the app and runs both. They need no API key
    // and take a few seconds each, which is the point: they are fast enough to
    // run after every change instead of "when something looks wrong".
    //
    // Both scripts use their OWN HOME under /tmp/opencode and must never be
    // pointed at the real one: the app writes `~/.config/zode/auth.json` and
    // `sessions/`, and the June fuzzer once saved a pasted key there.
    const pty_check = b.step("pty-check", "Build and run the pty checks (scroll + smoke)");
    // The scripts exec `./zig-out/bin/zode` by path, so the INSTALL step is what
    // has to have run, not just the compile step.
    pty_check.dependOn(b.getInstallStep());
    const run_smoke = b.addSystemCommand(&.{ "python3", "tools/pty_smoke.py" });
    run_smoke.setName("pty_smoke");
    run_smoke.has_side_effects = true;
    const run_scroll = b.addSystemCommand(&.{ "python3", "tools/scroll_repro.py" });
    run_scroll.setName("scroll_repro");
    run_scroll.has_side_effects = true;
    pty_check.dependOn(&run_smoke.step);
    pty_check.dependOn(&run_scroll.step);
    // `/copy`: the command, the picker and the file, in a real pty, with a
    // session that has an answer in it. It sets NO api key on purpose: the
    // ReleaseSmall build stops answering keys when the active provider has
    // one (the open bug in AGENTS.md), and `/copy` needs no provider.
    const run_copy = b.addSystemCommand(&.{ "python3", "tools/copy_smoke.py" });
    run_copy.setName("copy_smoke");
    run_copy.has_side_effects = true;
    pty_check.dependOn(&run_copy.step);

    // churn: Zig-native changeset tool for version bumps and changelogs.
    const cm_mod = b.createModule(.{
        .root_source_file = b.path("tools/churn.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    const cm = b.addExecutable(.{ .name = "churn", .root_module = cm_mod });
    const cm_step = b.step("churn", "Churn: add/release/changelog/version");
    cm_step.dependOn(&cm.step);
    const cm_run = b.addRunArtifact(cm);
    cm_run.setName("churn_run");
    cm_run.has_side_effects = true;
    cm_step.dependOn(&cm_run.step);
}
