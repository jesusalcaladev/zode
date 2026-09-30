const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // ReleaseSafe POR DEFECTO (Fase 5.1/5.2 del ROADMAP).
    //
    // Antes `zig build` producía un binario Debug: 10.8 MB (el 79 % secciones de
    // debug), con el `DebugAllocator` en el camino caliente y sin las
    // comprobaciones de overflow. Medido: ReleaseSafe tal cual 10.78 MB,
    // ReleaseSafe + strip 2.06 MB, ReleaseSmall 1.12 MB. La app es I/O-bound
    // (espera red y esperas del usuario), así que la diferencia de velocidad
    // entre modos es indistinguible y el default correcto es el stripped.
    //
    // Para el debug de verdad: `zig build -Doptimize=Debug`.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Modo de optimización (default: ReleaseSafe)",
    ) orelse .ReleaseSafe;
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
    const debug_exe = b.addExecutable(.{ .name = "zode-debug", .root_module = exe_mod });
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
}
