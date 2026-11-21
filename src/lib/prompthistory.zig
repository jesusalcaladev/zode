//! Prompt history that survives a restart.
//!
//! The editor's in-memory history dies with the process, so ↑ on a fresh
//! zode had nothing even when the session had dozens of prompts. Stored as
//! JSON lines under the config dir, one prompt per line (JSON keeps embedded
//! newlines and quotes intact). Best-effort everywhere: a full or unreadable
//! history file must never stop the TUI from starting or a prompt from being
//! sent.

const std = @import("std");
const configdir = @import("configdir.zig");

pub const max_entries = 100;
const max_bytes = 2 * 1024 * 1024;

pub fn filePath(
    env: ?*const std.process.Environ.Map,
    dir_buf: []u8,
    out_buf: []u8,
) ?[]const u8 {
    const dir = configdir.dir(env, dir_buf) orelse return null;
    return std.mem.print(out_buf, "{s}/prompt-history.jsonl", .{dir}) catch null;
}

/// Loads the most recent prompts, oldest first, ready to hand to the editor.
pub fn load(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map) !std.ArrayList([]u8) {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s);
        out.deinit(gpa);
    }
    var dbuf: [512]u8 = undefined;
    var pbuf: [640]u8 = undefined;
    const path = filePath(env, &dbuf, &pbuf) orelse return out;
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_bytes)) catch |err| {
        if (err == error.FileNotFound) return out;
        return err;
    };
    defer gpa.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const text = std.json.parseFromSliceLeaky([]const u8, gpa, line, .{
            .allocate = .alloc_always,
        }) catch continue;
        defer gpa.free(@constCast(text));
        if (text.len == 0) continue;
        out.append(gpa, gpa.dupe(u8, text) catch continue) catch {};
    }
    while (out.items.len > max_entries) {
        const old = out.orderedRemove(0);
        gpa.free(old);
    }
    return out;
}

/// Rewrites the file with the current history (bounded, so it cannot grow
/// forever). `history` is oldest first, as the editor keeps it.
pub fn save(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: ?*const std.process.Environ.Map,
    history: []const []const u8,
) void {
    var dbuf: [512]u8 = undefined;
    var pbuf: [640]u8 = undefined;
    const path = filePath(env, &dbuf, &pbuf) orelse return;
    if (configdir.dir(env, &dbuf)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    }

    const n = @min(history.len, max_entries);
    const start = history.len - n;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (history[start..]) |text| {
        const json = std.json.Stringify.valueAlloc(gpa, text, .{}) catch continue;
        defer gpa.free(json);
        out.appendSlice(gpa, json) catch return;
        out.append(gpa, '\n') catch return;
    }
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items }) catch {};
}

test "prompt history: JSON lines round-trip, including quotes and newlines" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/opencode/zode-prompt-history-test");

    const prompts = [_][]const u8{ "first prompt", "say \"hi\"\nand indent\t", "third" };
    save(std.testing.allocator, threaded.io(), &env, &prompts);
    var loaded = try load(std.testing.allocator, threaded.io(), &env);
    defer {
        for (loaded.items) |s| std.testing.allocator.free(s);
        loaded.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(prompts.len, loaded.items.len);
    for (prompts, loaded.items) |want, got| try std.testing.expectEqualStrings(want, got);
}
