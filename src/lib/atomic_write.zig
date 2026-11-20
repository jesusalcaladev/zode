const std = @import("std");
const builtin = @import("builtin");

/// Replaces `path` with `data` atomically, so a crash, a full disk or a killed
/// process can never leave a half-written source file behind.
///
/// The bytes go into a random-named temp file in the SAME directory (std's
/// `createFileAtomic` opens it exclusively), are flushed and synced, and only
/// then renamed over the target. A failure before the rename leaves the old
/// file byte-identical; `File.Atomic.deinit` removes the temp file on every
/// failure path, including a simulated crash that never reaches `replace`.
///
/// Mode: an existing file KEEPS its permissions and its executable bit, so an
/// atomic edit never silently turns a script into a non-script. A new file is
/// created with `default_file` and the process umask decides the rest.
/// (The 0600 rule belongs to secrets in `config.zig`, not to source files.)
pub fn writeFile(dir: std.Io.Dir, io: std.Io, path: []const u8, data: []const u8) !void {
    const mode: std.Io.File.Permissions = blk: {
        const st = dir.statFile(io, path, .{}) catch break :blk .default_file;
        break :blk st.permissions;
    };
    var tmp = try dir.createFileAtomic(io, path, .{
        .replace = true,
        .permissions = mode,
    });
    defer tmp.deinit(io);
    var buf: [8192]u8 = undefined;
    var fw = tmp.file.writer(io, &buf);
    try fw.interface.writeAll(data);
    try fw.interface.flush();
    try tmp.file.sync(io);
    try tmp.replace(io);
}

// ── tests ─────────────────────────────────────────────────────

test "atomic write: a crash before replace leaves the original byte-identical" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "original" });

    // A crash between "temp created" and "rename" is exactly a caller that
    // deinits the File.Atomic without calling replace.
    var af = try tmp.dir.createFileAtomic(io, "a.txt", .{ .replace = true });
    defer af.deinit(io);
    var buf: [16]u8 = undefined;
    var fw = af.file.writer(io, &buf);
    try fw.interface.writeAll("half");
    try fw.interface.flush();

    const after = try tmp.dir.readFileAlloc(io, "a.txt", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings("original", after);
}

test "atomic write: no temp file survives a crash" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "original" });

    {
        var af = try tmp.dir.createFileAtomic(io, "a.txt", .{ .replace = true });
        var buf: [16]u8 = undefined;
        var fw = af.file.writer(io, &buf);
        try fw.interface.writeAll("half");
        try fw.interface.flush();
        af.deinit(io); // removes the temp file, exactly as a crash path would.
    }

    var listing = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer listing.close(io);
    var it = listing.iterate();
    var count: usize = 0;
    while (try it.next(io)) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "atomic write: replace publishes the new bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "old" });

    try writeFile(tmp.dir, io, "a.txt", "brand new content");
    const after = try tmp.dir.readFileAlloc(io, "a.txt", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings("brand new content", after);
}

test "atomic write: creates a missing file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try writeFile(tmp.dir, io, "new.txt", "hello");
    const after = try tmp.dir.readFileAlloc(io, "new.txt", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings("hello", after);
}

test "atomic write: an existing file keeps its permissions and executable bit" {
    if (builtin.os.tag == .windows) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const mode: std.Io.File.Permissions = @enumFromInt(0o751);

    var f = try tmp.dir.createFile(io, "run.sh", .{ .truncate = true, .permissions = mode });
    f.close(io);
    try writeFile(tmp.dir, io, "run.sh", "#!/bin/sh\nexit 0\n");

    const st = try tmp.dir.statFile(io, "run.sh", .{});
    // stat includes the S_IFREG type bits; compare only the mode bits.
    const got: u32 = @intCast(@backingInt(st.permissions) & 0o7777);
    try std.testing.expectEqual(@as(u32, 0o751), got);
}
