const std = @import("std");
const common = @import("common.zig");
const sandbox_mod = @import("../lib/sandbox.zig");
const agent = @import("../agent.zig");
const bg_tool = @import("bg.zig");
const bgproc = @import("../bgproc.zig");

pub fn toolBash(
    io: std.Io,
    obj: std.json.ObjectMap,
    arena: std.mem.Allocator,
    reg: ?*bgproc.Registry,
) ![]const u8 {
    const command = common.getStr(obj, "command") orelse return error.MissingCommand;
    const timeout_s: u64 = if (common.getInt(obj, "timeout_seconds")) |t| (if (t > 0) @intCast(t) else 30) else 30;

    // THE HARNESS DECIDES, for the slow verifications.
    //
    // `run_in_background` already existed and the model already had to remember
    // to use it, which is the whole problem: a model that forgets to sets the
    // input on the floor for the length of a full build, once per edit. So a
    // command that `verify.classify` recognises as a slow verification goes to
    // the background EVEN IF the model asked for the foreground.
    //
    // Two escapes, both deliberate: an explicit `timeout_seconds` means the model
    // knows what it is doing (it set a number for this command), and
    // `ZODE_AUTO_BG=0` turns the whole thing off for someone who would rather
    // see it hang than have it disappear into a job.
    if (bg_tool.autoBackgroundRule(obj, command)) |rule| {
        {
            const r = reg orelse return error.NoBackgroundRegistry;
            const id = try bgproc.spawn(r, io, command);
            return std.fmt.allocPrint(arena,
                \\started in the background as job {d}, because `{s}` is a slow verification
                \\
                \\The command is running NOW and you are not blocked. Do something else
                \\while it runs: read a file, grep the code you just changed, keep
                \\editing. Then call bash_output with id {d} for the result.
                \\
                \\One poll per step, never a polling loop.
                \\
            , .{ id, rule, id });
        }
    }

    if (common.getBool(obj, "run_in_background")) {
        const r = reg orelse return error.NoBackgroundRegistry;
        const id = try bgproc.spawn(r, io, command);
        return std.fmt.allocPrint(arena,
            \\started in the background as job {d}
            \\
            \\It is running NOW and you are not blocked. Keep working: read a file,
            \\grep the error, ask the user something — anything. When you need the
            \\result, call bash_output with id {d}: it gives you the output that
            \\appeared since your last call plus whether it is still running.
            \\
            \\Do not poll in a loop. Do one poll per step.
            \\
        , .{ id, id });
    }

    // The SANDBOX, when the model asks for it and there is one.
    //
    // It is opt-IN and not a policy: a harness that sandboxes every command
    // breaks every build (the home is read-only and `/tmp` is empty), and a
    // sandbox that breaks the build is one the user turns off.
    var sandbox_argv: ?[]const []const u8 = null;
    if (common.getBool(obj, "sandbox")) {
        // The PATH from the environment: a sandbox installed in
        // `~/.local/bin` is a sandbox, and the usual places are the fallback.
        const env = agent.environ_global;
        const path = if (env) |e| e.get("PATH") else null;
        const kind = sandbox_mod.detect(io, std.Io.Dir.cwd(), path);
        if (kind == .none) {
            return "sandbox: no sandbox is installed (looked for bwrap and firejail). Run the command without it, or install one.";
        }
        var cwd_buf: [1024]u8 = undefined;
        const n = std.Io.Dir.cwd().realPath(io, &cwd_buf) catch 0;
        const cwd = cwd_buf[0..n];
        sandbox_argv = sandbox_mod.argv(kind, command, cwd, arena) catch null;
        if (sandbox_argv == null) {
            return "sandbox: the sandbox arguments could not be built.";
        }
    }

    const result = if (sandbox_argv) |argv|
        try bg_tool.runForegroundArgv(arena, io, argv, timeout_s, common.max_tool_output)
    else
        try bg_tool.runForeground(arena, io, command, timeout_s, common.max_tool_output);

    var out: std.ArrayList(u8) = .empty;
    // Null means WE stopped it at the cap, so there is no exit code to report and
    // inventing one (`255`, or a synthetic signal) would read to the model as the
    // command's own verdict. The notice at the end says what happened instead.
    const exit_line: ?u8 = if (result.term) |t| switch (t) {
        .exited => |code| code,
        .signal => |sig| blk: {
            out.print(arena, "(signal {d}) ", .{sig}) catch {};
            break :blk @as(u8, @truncate(128 + @intFromEnum(sig)));
        },
        else => 255,
    } else null;
    if (exit_line) |code| {
        try out.print(arena, "exit={d}\n", .{code});
    } else {
        try out.appendSlice(arena, "exit=(stopped at the tool's output cap)\n");
    }
    if (result.stdout.len > 0) {
        try out.appendSlice(arena, "--- stdout ---\n");
        try out.appendSlice(arena, result.stdout[0..@min(result.stdout.len, common.max_tool_output)]);
        try out.appendSlice(arena, "\n");
    }
    if (result.stderr.len > 0) {
        try out.appendSlice(arena, "--- stderr ---\n");
        try out.appendSlice(arena, result.stderr[0..@min(result.stderr.len, common.max_tool_output)]);
        try out.appendSlice(arena, "\n");
    }
    // The notice, and it is the LAST thing: anything after it reads as part of the
    // output. A silent cut is the failure this replaces — with one, the model can
    // tell "that was everything" from "that was the first 16 KB", which is the whole
    // difference between rephrasing the request and repeating it.
    if (result.truncated) {
        try bg_tool.foregroundTruncationNotice(&out, arena, result.bytes_read, common.max_tool_output);
    }
    return out.items;
}

/// A JSON object for the tool arguments, with everything freed.
///
/// `parseFromSliceLeaky` needs an arena and the map has to outlive it, so the two
/// go together in a struct instead of being two things a test has to remember.
pub const Args = struct {
    state: std.heap.ArenaAllocator,
    obj: std.json.ObjectMap,

    pub fn parse(json: []const u8) !Args {
        var self: Args = .{ .state = std.heap.ArenaAllocator.init(std.testing.allocator), .obj = .{} };
        errdefer self.state.deinit();
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, self.state.allocator(), json, .{});
        self.obj = parsed.object;
        return self;
    }

    pub fn deinit(self: *Args) void {
        self.state.deinit();
    }
};

test "bash: a full build is started in the background even in the foreground" {
    // The complaint this answers: a harness that blocks on the whole suite after
    // every edit. `run_in_background` existed, but the model has to REMEMBER to
    // use it, and a model that forgets costs the user the length of a build.
    defer bg_tool.setAutoBackground(true);

    var args = try Args.parse("{\"command\":\"zig build test\"}");
    defer args.deinit();
    try std.testing.expectEqualStrings("zig build", bg_tool.autoBackgroundRule(args.obj, "zig build test").?);

    // Quick and unknown commands stay in the foreground.
    var quick = try Args.parse("{\"command\":\"ls\"}");
    defer quick.deinit();
    try std.testing.expect(bg_tool.autoBackgroundRule(quick.obj, "ls") == null);
    var commit = try Args.parse("{\"command\":\"git commit -m x\"}");
    defer commit.deinit();
    try std.testing.expect(bg_tool.autoBackgroundRule(commit.obj, "git commit -m x") == null);
}

test "bash: asking for the background explicitly is not 'auto', and a timeout is an override" {
    defer bg_tool.setAutoBackground(true);

    // Already backgrounded: nothing to decide.
    var bg = try Args.parse("{\"command\":\"zig build\",\"run_in_background\":true}");
    defer bg.deinit();
    try std.testing.expect(bg_tool.autoBackgroundRule(bg.obj, "zig build") == null);

    // An explicit timeout means the model knows what it is doing.
    var t = try Args.parse("{\"command\":\"zig build\",\"timeout_seconds\":600}");
    defer t.deinit();
    try std.testing.expect(bg_tool.autoBackgroundRule(t.obj, "zig build") == null);
}

test "bash: ZODE_AUTO_BG=0 turns the automatic backgrounding off" {
    bg_tool.setAutoBackground(false);
    defer bg_tool.setAutoBackground(true);

    var args = try Args.parse("{\"command\":\"zig build test\"}");
    defer args.deinit();
    try std.testing.expect(bg_tool.autoBackgroundRule(args.obj, "zig build test") == null);
}
