const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // ReleaseSmall POR DEFECTO.
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
    // But a STRIPPED BINARY HAS NO STACK TRACE: when zode crashed with SIGSEGV
    // the only thing on screen was "Cannot print stack trace: stack tracing is
    // disabled", which is exactly the moment you least want the build to be
    // mute. So `-Dstrip=false` is the documented way to get a debuggable build,
    // and `zig build -Dstrip=false` is what to run when something crashes.
    const strip = b.option(bool, "strip", "Strip the debug sections (default: true)") orelse true;
    // The tests go in Debug on purpose (the DebugAllocator and the overflow checks
    // are what catch bugs), but their binary needs no symbols: without this every
    // rebuild leaves another 49 MB in `.zig-cache/o`.
    const strip_tests = b.option(bool, "strip-tests", "Strip the test binary (default: true)") orelse true;

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("vaxis", vaxis.module("vaxis"));

    // The strip goes on the MODULE (`root_module.strip`), not on the executable.
    if (strip) exe_mod.strip = true;
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
    const debug_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    debug_mod.addImport("vaxis", vaxis.module("vaxis"));
    const debug_exe = b.addExecutable(.{ .name = "zode-debug", .root_module = debug_mod });
    debug_exe.root_module.strip = null;
    b.installArtifact(debug_exe);
    b.step("debug", "Build an UNSTRIPPED zode-debug (has symbols, for crash traces)")
        .dependOn(&debug_exe.step);

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
    tt_mod.addImport("tools", b.createModule(.{
        .root_source_file = b.path("src/tools_root.zig"),
        .target = target,
        .optimize = optimize,
    }));
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
    // `zig build test -- <filter>` runs only the tests whose name contains the
    // filter. Zig 0.16's runner has no `--test-filter`, so the filter is applied
    // AT COMPILE TIME (it does not reach the binary's args).
    const filters: []const []const u8 = if (b.args) |args| args else &.{};
    const tests = b.addTest(.{ .root_module = test_mod, .filters = filters });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

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
}
