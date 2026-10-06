/// A probe that runs the automatic typecheck against a project with a DELIBERATE
/// error in it, and prints what the model would be told.
///
/// It exists because the tests can prove `extractDiagnostics` keeps the lines with
/// a location, and they cannot prove that a real compiler's real output survives
/// the trip from the background job to the text the model reads. This is the only
/// way to see that shape with real bytes in it.
const std = @import("std");
const check_tool = @import("tools/check.zig");
const bgproc = @import("bgproc.zig");
const sleep = @import("lib/sleep.zig");

const dir = "/tmp/opencode/checklive";

pub fn main(init: std.process.Init) !void {
    var reg = bgproc.Registry{};
    defer reg.deinit(init.io, init.gpa);
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &buf);
    const w = &fw.interface;

    std.Io.Dir.cwd().deleteTree(init.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(init.io, dir);
    // A marker file, so `planAt` recognises the project. It does NOT have to be a
    // real build.zig: the point of the probe is the plumbing, not the compiler.
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = dir ++ "/build.zig", .data = "" });

    const plan = check_tool.planAt(init.io, dir) orelse return error.NoPlan;
    try w.print("PLAN: {s}\n", .{plan.command});

    // A shell command that fails the way a compiler fails, printing real
    // diagnostics to stderr, and that then takes a moment so the "still running"
    // branch is a real one.
    const cmd = "echo 'src/broken.zig:3:9: error: unused local variable' >&2; " ++
        "echo '        unused_variable' >&2; " ++
        "echo 'src/broken.zig:4:5: error: call to undeclared function' >&2; " ++
        "sleep 1; exit 1";
    const id = try bgproc.spawn(&reg, init.io, cmd);
    try w.print("JOB {d}\n", .{id});

    var waited: u32 = 0;
    while (waited < 3000) : (waited += 50) {
        sleep.nap(50);
        if (!std.mem.eql(u8, bgproc.stateWord(&reg, id), "running")) break;
    }

    const out = try check_tool.report(a, &reg, id);
    try w.print("---REPORT---\n{s}\n---END---\n", .{out});
    try w.flush();
}
