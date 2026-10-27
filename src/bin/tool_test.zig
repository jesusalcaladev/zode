const std = @import("std");
const tools = @import("tools");

pub fn main(init: std.process.Init) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buf);

    // read
    const r1 = try tools.execute(init.io, "read", "{\"path\":\"src/lib/provider.zig\"}", arena, null, null);
    try out.interface.print("READ: {d} bytes\n", .{r1.len});
    // grep (rg nativo)
    const r2 = try tools.execute(init.io, "grep", "{\"pattern\":\"pub fn execute\",\"subdir\":\"src\"}", arena, null, null);
    try out.interface.print("GREP: {s}\n", .{r2[0..@min(r2.len, 200)]});
    // glob
    const r3 = try tools.execute(init.io, "glob", "{\"pattern\":\"src/lib/*.zig\"}", arena, null, null);
    try out.interface.print("GLOB: {d} archivos\n", .{std.mem.count(u8, r3, "\n")});
    // bash
    const r4 = try tools.execute(init.io, "bash", "{\"command\":\"echo hola-zode && wc -l src/lib/*.zig | tail -1\"}", arena, null, null);
    try out.interface.print("BASH: {s}\n", .{r4[0..@min(r4.len, 150)]});
    // edit
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "/tmp/zode_edit_test.txt", .data = "hola mundo" });
    const r5 = try tools.execute(init.io, "edit", "{\"path\":\"/tmp/zode_edit_test.txt\",\"old_string\":\"mundo\",\"new_string\":\"zode\"}", arena, null, null);
    try out.interface.print("EDIT: {s}\n", .{r5});

    // The git tools, on THIS repository: the only honest way to see whether the
    // header rewriting and the counts work is against a real diff.
    const g1 = try tools.execute(init.io, "git_status", "{}", arena, null, null);
    try out.interface.print("GIT_STATUS: {s}\n", .{g1[0..@min(g1.len, 300)]});
    const g2 = try tools.execute(init.io, "git_diff", "{}", arena, null, null);
    const tail_start = if (g2.len > 400) g2.len - 400 else 0;
    try out.interface.print("GIT_DIFF (fin): {s}\n", .{g2[tail_start..]});
    const g3 = try tools.execute(init.io, "git_log", "{\"limit\":3}", arena, null, null);
    try out.interface.print("GIT_LOG: {s}\n", .{g3[0..@min(g3.len, 300)]});

    // refs, on THIS repository: the only honest check of the definition/use split
    // is against a codebase that actually has cross-file references.
    const rf = try tools.execute(init.io, "refs", "{\"symbol\":\"hitRatePct\"}", arena, null, null);
    try out.interface.print("REFS: {s}\n", .{rf[0..@min(rf.len, 700)]});

    // rename, on a THROWAWAY copy of this repository: the safest way to see the
    // scanner agree with itself on real code is to let it change real code.
    {
        var ast = std.heap.ArenaAllocator.init(init.gpa);
        defer ast.deinit();
        const aa = ast.allocator();
        try std.Io.Dir.cwd().createDirPath(init.io, "/tmp/opencode/rename-live");
        // A file with the symbol in every shape that must NOT be touched.
        try std.Io.Dir.cwd().writeFile(init.io, .{
            .sub_path = "/tmp/opencode/rename-live/a.zig",
            .data =
            \\pub fn widget() void {}
            \\const note = "widget in a string";
            \\// widget in a comment
            \\const widgetCount = 1;
            \\fn use() void { widget(); }
            \\
            ,
        });
        const rn = try tools.execute(init.io, "rename", "{\"symbol\":\"widget\",\"to\":\"gadget\",\"subdir\":\"/tmp/opencode/rename-live\"}", aa, null, null);
        try out.interface.print("RENAME: {s}\n", .{rn});
        const after = try std.Io.Dir.cwd().readFileAlloc(init.io, "/tmp/opencode/rename-live/a.zig", aa, .limited(1 << 20));
        try out.interface.print("RENAME-FILE:\n{s}", .{after});
    }

    // read with `paths`: three files, ONE call, on this repository.
    const rp = try tools.execute(init.io, "read", "{\"paths\":[\"src/cache_stats.zig\",\"src/compaction.zig\"]}", arena, null, null);
    try out.interface.print("READ-PATHS: {d} bytes, {d} file(s)\n", .{ rp.len, std.mem.count(u8, rp, "\n--- ") + 1 });

    // The batch: FOUR files, ONE call, on this repository. The point of the
    // tool is the round trip it saves, and the log is where that saving is
    // said out loud.
    const bt = try tools.execute(init.io, "batch",
        \\{"steps":[
        \\ {"op":"read_many","paths":["src/cache_stats.zig","src/compaction.zig","src/session.zig","src/config.zig"]},
        \\ {"op":"map","field":"lines"},
        \\ {"op":"select","fields":["path","lines"]},
        \\ {"op":"count"}
        \\]}
    , arena, null, null);
    try out.interface.print("BATCH:\n{s}\n", .{bt});

    try out.interface.flush();
    return 0;
}
