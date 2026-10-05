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

    try out.interface.flush();
    return 0;
}
