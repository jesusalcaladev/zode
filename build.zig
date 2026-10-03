const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // ReleaseSmall POR DEFECTO.
    //
    // Antes `zig build` producía un binario Debug (10.8 MB, el 79 % secciones de
    // debug, con el `DebugAllocator` en el camino caliente). Luego se pasó a
    // ReleaseSafe + strip, y ahora a ReleaseSmall + strip. Medido HOY sobre este
    // árbol (nm/llvm-size sobre el binario sin strip, y tools/measure.py en pty):
    //
    //   ReleaseSafe + strip   2.20 MB   (.text 1.82 MB · .rodata 0.51 MB)
    //   ReleaseSmall + strip  1.34 MB   (.text 0.86 MB · .rodata 0.38 MB)   <--
    //
    // Y no cuesta velocidad, al menos en lo que se nota al arrancar: measure.py da
    // 11 ms / 6.22 MB RSS con ReleaseSafe contra 6 ms / 5.79 MB con ReleaseSmall.
    // La app es I/O-bound (espera red y esperas del usuario), así que el modo de
    // optimización casi solo decide cómo de grande queda el fichero.
    //
    // EL SUELO, para no volver a medir lo que no depende de nosotros (nm sobre
    // zode-debug, ReleaseSafe): crypto 509 KB — `std.crypto.tls.Client` manda key
    // shares de x25519_ml_kem768/secp256r1/secp384r1/x25519 sin opción para
    // recortarlos, y la verificación de certificados arrastra RSA, P-256, P-384,
    // ed25519 y SHA-1 — más 185 KB de rodata de las tablas unicode de `uucode` que
    // entra por `vaxis.gwidth`. Los dos son dependencia (std y vaxis); tocarlos es
    // un `patch` declarado en build.zig.zon, como 5.7/5.9.
    //
    // Para el debug de verdad: `zig build -Doptimize=Debug`, y `-Doptimize=ReleaseSafe`
    // si alguna vez make falta el binario rápido en vez del pequeño.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Modo de optimización (default: ReleaseSmall)",
    ) orelse .ReleaseSmall;
    // Strip is ON by default because it takes the binary from 10.78 MB to 1.89 MB
    // (measured), and zode is I/O-bound so it costs nothing at runtime.
    //
    // But a STRIPPED BINARY HAS NO STACK TRACE: when zode crashed with SIGSEGV
    // the only thing on screen was "Cannot print stack trace: stack tracing is
    // disabled", which is exactly the moment you least want the build to be
    // mute. So `-Dstrip=false` is the documented way to get a debuggable build,
    // and `zig build -Dstrip=false` is what to run when something crashes.
    const strip = b.option(bool, "strip", "Quita las secciones de debug (default: true)") orelse true;
    // Los tests van en Debug a propósito (el DebugAllocator y las
    // comprobaciones de overflow son los que cazan los bugs), pero su binario
    // no necesita símbolos: sin esto, cada reconstrucción deja otro de 49 MB en
    // `.zig-cache/o`.
    const strip_tests = b.option(bool, "strip-tests", "Strip del binario de tests (default: true)") orelse true;

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

    // El strip va en el MÓDULO (`root_module.strip`), no en el ejecutable.
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
    tt_mod.addImport("tools", b.createModule(.{
        .root_source_file = b.path("src/tools.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const tt = b.addExecutable(.{ .name = "tool_test", .root_module = tt_mod });
    const tt_run = b.addRunArtifact(tt);
    if (b.args) |args| tt_run.addArgs(args);
    const tt_step = b.step("tool-test", "Prueba las tools headless");
    tt_step.dependOn(&tt_run.step);

    // Sonda de ACP contra el agente real (`opencode acp`). No es un test: es
    // para mirar el cable a pelo, con `zig build acp-probe -- "prompt"`.
    const probe_mod = b.createModule(.{
        .root_source_file = b.path("src/bin/acp_probe.zig"),
        .target = target,
        .optimize = optimize,
    });
    probe_mod.addImport("acp", b.createModule(.{
        .root_source_file = b.path("src/acp.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const probe = b.addExecutable(.{ .name = "acp_probe", .root_module = probe_mod });
    const probe_run = b.addRunArtifact(probe);
    if (b.args) |args| probe_run.addArgs(args);
    const probe_step = b.step("acp-probe", "Habla con el agente ACP real y enseña el tráfico");
    probe_step.dependOn(&probe_run.step);

    // Free-auto probe: which providers have a key, how many free models each
    // one publishes, and the pool already sorted the way the wheel will use it.
    // Not a test: it talks to the network.
    //
    // Only `vaxis` is declared here; the probe picks the other modules BY PATH
    // (which is why the probe lives in `src/`, not `src/bin/`). Declaring them
    // here clashes too: a file cannot be the root of two modules in the same
    // compilation, and `providers.zig` already is the root of `agent`.
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

    // Tests con acceso a vaxis (markdown/highlight testean estilos).
    // SIEMPRE en Debug: el binario ya sale ReleaseSafe+strip, pero compilar la
    // suite en ReleaseSafe cuesta 2 min y no encuentra un fallo más (al revés:
    // encuentra menos, porque el DebugAllocator y las comprobaciones de
    // overflow están justo para eso).
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_all.zig"),
        .target = target,
        .optimize = .Debug,
        // El binario de tests en Debug pesa ~49 MB (casi todo secciones de
        // debug de vaxis) y .zig-cache/o guarda UNO POR CADA RECONSTRUCCION: se
        // llegaron a acumular 44, o sea 1.4 GB. Los tests no se depuran con gdb,
        // así que los símbolos no sirven de nada: `strip` los deja en ~10 MB.
        .strip = strip_tests,
    });
    test_mod.addImport("vaxis", vaxis.module("vaxis"));
    // `zig build test -- <filtro>` corre solo los tests cuyo nombre contiene el
    // filtro. El runner de Zig 0.16 no trae `--test-filter`, así que el filtro
    // se aplica al COMPILAR (no entra en los args del binario).
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
