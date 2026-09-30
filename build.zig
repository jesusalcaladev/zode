const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    const exe = b.addExecutable(.{
        .name = "zode",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run zode");
    run_step.dependOn(&run_cmd.step);

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

    // Sonda del free-auto: providers con key, modelos free y el pool ya ordenado
    // (`zig build roster-probe`). No es un test: habla con la red.
    //
    // Solo se declara `vaxis`: el resto de módulos los coge la sonda POR RUTA
    // (y por eso la sonda vive en `src/`, no en `src/bin/`). Declararlos aquí
    // también choca: un fichero no puede ser la raíz de dos módulos en la misma
    // compilación, y `providers.zig` ya lo es de `agent`.
    const roster_mod = b.createModule(.{
        .root_source_file = b.path("src/roster_probe.zig"),
        .target = target,
        .optimize = optimize,
    });
    roster_mod.addImport("vaxis", vaxis.module("vaxis"));
    const roster_probe = b.addExecutable(.{ .name = "roster_probe", .root_module = roster_mod });
    const roster_probe_run = b.addRunArtifact(roster_probe);
    if (b.args) |args| roster_probe_run.addArgs(args);
    const roster_probe_step = b.step("roster-probe", "Enseña el pool de modelos free de cada provider");
    roster_probe_step.dependOn(&roster_probe_run.step);

    // Tests con acceso a vaxis (markdown/highlight testean estilos)
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_all.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("vaxis", vaxis.module("vaxis"));
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    // `zig build test -- <filtro>` para correr un solo test (o un grupo) sin
    // pagar los 30 s de la suite entera.
    if (b.args) |args| run_tests.addArgs(args);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
