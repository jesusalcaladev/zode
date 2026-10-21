//! `lib/sandbox.zig`: running a command inside a sandbox, when there is one.
//!
//! Pure on purpose: the ARGUMENT LIST of the sandbox is a value, and it can
//! be tested with no bubblewrap installed.
//!
//! ## Why it is OPT-IN
//!
//! A harness that runs EVERY command inside a sandbox is a harness that
//! breaks every build: the home directory is read-only, `/tmp` is empty, and
//! the build writes to `~/.cache`. The sandbox is a tool for the commands
//! that are genuinely dangerous, and the user asks for it (or the harness
//! offers it) — it is not a policy applied to everything.
//!
//! ## What it does NOT do
//!
//! **The network stays.** `bwrap --unshare-net` would be the strongest
//! version, and it would also break every `npm install` and every build that
//! downloads a dependency. A sandbox that breaks the build is a sandbox the
//! user turns off, and a sandbox that is off protects nothing.

const std = @import("std");

/// The sandbox that is available, if any.
pub const Kind = enum {
    none,
    bwrap,
    firejail,

    pub fn name(self: Kind) []const u8 {
        return @tagName(self);
    }
};

/// The name of the binary, as it is typed.
pub fn binary(kind: Kind) []const u8 {
    return switch (kind) {
        .none => "",
        .bwrap => "bwrap",
        .firejail => "firejail",
    };
}

/// The sandbox's argument list for a command.
///
/// The filesystem is READ-ONLY and the working directory is WRITABLE: the
/// project is what a command is allowed to change, and everything else — the
/// home, the system, `/etc` — is not.
///
/// `/dev` and `/proc` are the minimum a program needs to start, and `/tmp` is
/// a tmpfs: a command that writes temporary files writes them where they do
/// not outlive it.
pub fn argv(
    kind: Kind,
    command: []const u8,
    workdir: []const u8,
    arena: std.mem.Allocator,
) ![]const []const u8 {
    if (kind == .none) return error.NoSandbox;

    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(arena);

    switch (kind) {
        .none => return error.NoSandbox,
        .bwrap => {
            try out.append(arena, "bwrap");
            // The whole filesystem, read-only.
            try out.append(arena, "--ro-bind");
            try out.append(arena, "/");
            try out.append(arena, "/");
            try out.append(arena, "--dev");
            try out.append(arena, "/dev");
            try out.append(arena, "--proc");
            try out.append(arena, "/proc");
            try out.append(arena, "--tmpfs");
            try out.append(arena, "/tmp");
            // And the project, writable: it is what the command is FOR.
            //
            // **THE ORDER IS THE BUG THIS FIXED.** The tmpfs on `/tmp` comes
            // BEFORE the bind, and a later mount SHADOWS an earlier one: with
            // the bind first, a project under `/tmp` vanished inside the
            // sandbox and the `chdir` failed with "No such file or
            // directory". The test that runs a REAL bubblewrap is what caught
            // it, and no amount of reading would have.
            if (workdir.len > 0) {
                try out.append(arena, "--bind");
                try out.append(arena, workdir);
                try out.append(arena, workdir);
                try out.append(arena, "--chdir");
                try out.append(arena, workdir);
            }
        },
        .firejail => {
            try out.append(arena, "firejail");
            // The home is private and empty, and the project is the only
            // writable thing.
            if (workdir.len > 0) {
                try out.append(arena, "--private=");
                try out.append(arena, workdir);
            }
            try out.append(arena, "--tmpfs=/tmp");
        },
    }

    try out.append(arena, "--");
    try out.append(arena, "/bin/sh");
    try out.append(arena, "-c");
    try out.append(arena, command);
    return out.items;
}

/// The usual places, for the case where there is no environment to read.
const standard_dirs = [_][]const u8{
    "/usr/bin", "/bin", "/usr/local/bin", "/usr/sbin", "/sbin", "/usr/local/sbin",
};

/// Whether the sandbox binary is installed.
///
/// It looks in the PATH and in the usual places, and it checks for the FILE:
/// a `bwrap` in the current directory is not a sandbox, and a shell that
/// answers "bwrap: not found" is not a failure the user has to read.
pub fn detect(io: std.Io, dir: std.Io.Dir, path: ?[]const u8) Kind {
    var buf: [1024]u8 = undefined;
    if (path) |p| {
        var it = std.mem.splitScalar(u8, p, ':');
        while (it.next()) |d| {
            if (d.len == 0) continue;
            for ([_]Kind{ .bwrap, .firejail }) |kind| {
                const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ d, binary(kind) }) catch continue;
                dir.access(io, full, .{}) catch continue;
                return kind;
            }
        }
    }
    for (standard_dirs) |d| {
        for ([_]Kind{ .bwrap, .firejail }) |kind| {
            const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ d, binary(kind) }) catch continue;
            dir.access(io, full, .{}) catch continue;
            return kind;
        }
    }
    return .none;
}

// ── tests ──────────────────────────────────────────────────────────────────

const t = std.testing;

test "sandbox: the bwrap arguments make the project writable and the rest read-only" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const args = try argv(.bwrap, "zig build", "/home/u/proj", a);
    // The binary, then the read-only root.
    try t.expectEqualStrings("bwrap", args[0]);
    try t.expectEqualStrings("--ro-bind", args[1]);
    try t.expectEqualStrings("/", args[2]);
    // The project, writable.
    var found_bind = false;
    for (args, 0..) |arg, i| {
        if (!std.mem.eql(u8, arg, "--bind")) continue;
        try t.expectEqualStrings("/home/u/proj", args[i + 1]);
        try t.expectEqualStrings("/home/u/proj", args[i + 2]);
        found_bind = true;
    }
    try t.expect(found_bind);
    // And the command itself, at the end, after the `--`.
    try t.expectEqualStrings("--", args[args.len - 4]);
    try t.expectEqualStrings("/bin/sh", args[args.len - 3]);
    try t.expectEqualStrings("-c", args[args.len - 2]);
    try t.expectEqualStrings("zig build", args[args.len - 1]);
}

test "sandbox: there is no network isolation, on purpose" {
    // `bwrap --unshare-net` would be the strongest version, and it would also
    // break every `npm install`. A sandbox that breaks the build is a sandbox
    // the user turns off, and a sandbox that is off protects nothing.
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const args = try argv(.bwrap, "echo hi", "/tmp", a);
    for (args) |arg| {
        try t.expect(!std.mem.eql(u8, arg, "--unshare-net"));
    }
}

test "sandbox: no sandbox is no arguments" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try t.expectError(error.NoSandbox, argv(.none, "ls", "/tmp", a));
    try t.expectEqualStrings("", binary(.none));
}

test "sandbox: a command inside it cannot write outside the project" {
    // It needs bubblewrap (or firejail) INSTALLED, and the test SKIPS when
    // there is none: a test that needs a package is a test that cannot be
    // run everywhere, and the honest way to say it is to skip it.
    const kind = detect(std.testing.io, std.Io.Dir.cwd(), "/usr/bin:/bin:/usr/local/bin");
    if (kind == .none) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var pbuf: [1024]u8 = undefined;
    const n = tmp.dir.realPath(io, &pbuf) catch return error.SkipZigTest;
    const workdir = pbuf[0..n];

    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Writing INSIDE the project works: that is what the project is for.
    const inside = try std.fmt.allocPrint(a, "touch {s}/inside.txt && echo ok", .{workdir});
    const ok_args = try argv(kind, inside, workdir, a);
    var ok_child = try std.process.spawn(io, .{
        .argv = ok_args,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    const ok_term = try ok_child.wait(io);
    switch (ok_term) {
        .exited => |code| try t.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }

    // Writing OUTSIDE it does not: the filesystem is read-only and only the
    // project is bound writable.
    //
    // "Outside" is the PARENT of the project, and not `/tmp`: `/tmp` is a
    // tmpfs inside the sandbox, so a write there SUCCEEDS (and disappears
    // with the sandbox), and a test that used it would prove nothing.
    const slash = std.mem.lastIndexOfScalar(u8, workdir, '/') orelse return error.TestUnexpectedResult;
    const parent = workdir[0..slash];
    const outside = try std.fmt.allocPrint(a, "touch {s}/outside.txt", .{parent});
    const out_args = try argv(kind, outside, workdir, a);
    var out_child = try std.process.spawn(io, .{
        .argv = out_args,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    const out_term = try out_child.wait(io);
    switch (out_term) {
        .exited => |code| try t.expect(code != 0),
        else => {}, // a signal is not a success either
    }
}
