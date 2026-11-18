//! Churn - the release/beta flow tool (Phase 38). Replaces the old stub and
//! the buggy churn.sh. One binary, four commands, no shell scripting:
//!
//!   churn add <type> <scope> <description>   record a changeset
//!   churn version [--beta|--stable]          print the bumped version (dry run)
//!   churn changelog                          regenerate [Unreleased] from git log
//!   churn release [--beta] [--push]          cut: version + changelog + tag + push
//!
//! Safety: `release` refuses on a dirty tree, runs `zig build test` first, and
//! NEVER pushes unless `--push` is explicit. Tags follow the v-prefix convention.

const std = @import("std");
const release_mod = @import("release");

const types = [_][]const u8{ "feat", "fix", "perf", "refactor", "docs", "chore", "breaking", "next", "beta" };

fn run(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, argv: []const []const u8) ?[]const u8 {
    const r = std.process.run(gpa, io, .{ .argv = argv, .environ_map = env, .stdout_limit = .limited(4 * 1024 * 1024) }) catch return null;
    defer gpa.free(r.stderr);
    if (r.term != .exited or r.term.exited != 0) {
        gpa.free(r.stdout);
        return null;
    }
    return r.stdout;
}

fn trimmed(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn currentVersion(gpa: std.mem.Allocator, io: std.Io) []const u8 {
    const zon = std.Io.Dir.cwd().readFileAlloc(io, "build.zig.zon", gpa, .limited(64 * 1024)) catch return "";
    defer gpa.free(zon);
    const needle = ".version = \"";
    const at = std.mem.indexOf(u8, zon, needle) orelse return "";
    const rest = zon[at + needle.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return "";
    return gpa.dupe(u8, rest[0..end]) catch "";
}

fn countChangesets(gpa: std.mem.Allocator, io: std.Io) usize {
    _ = gpa;
    var dir = std.Io.Dir.cwd().openDir(io, ".churn", .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var it = dir.iterate();
    var n: usize = 0;
    while (it.next(io) catch null) |e| {
        if (e.kind == .file and std.mem.endsWith(u8, e.name, ".json") and !std.mem.eql(u8, e.name, "config.json")) n += 1;
    }
    return n;
}

fn bumpFromChangesets(gpa: std.mem.Allocator, io: std.Io) release_mod.Bump {
    var dir = std.Io.Dir.cwd().openDir(io, ".churn", .{ .iterate = true }) catch return .patch;
    defer dir.close(io);
    var it = dir.iterate();
    var bump: release_mod.Bump = .patch;
    while (it.next(io) catch null) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".json") or std.mem.eql(u8, e.name, "config.json")) continue;
        const path = std.fmt.allocPrint(gpa, ".churn/{s}", .{e.name}) catch continue;
        defer gpa.free(path);
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4096)) catch continue;
        defer gpa.free(data);
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, gpa, data, .{}) catch continue;
        if (parsed != .object) continue;
        const t = parsed.object.get("type") orelse continue;
        if (t != .string) continue;
        if (std.mem.eql(u8, t.string, "breaking") or std.mem.eql(u8, t.string, "next")) {
            return .major;
        } else if (std.mem.eql(u8, t.string, "feat")) {
            if (bump != .major) bump = .minor;
        } else if (std.mem.eql(u8, t.string, "beta")) {
            if (bump == .patch) bump = .beta;
        }
    }
    return bump;
}

fn cmdAdd(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8) u8 {
    if (args.len < 3) {
        std.debug.print("usage: churn add <type> <scope> <description>\n", .{});
        return 1;
    }
    const kind = args[0];
    var valid = false;
    for (types) |t| {
        if (std.mem.eql(u8, t, kind)) valid = true;
    }
    if (!valid) {
        std.debug.print("unknown type '{s}'. Use: feat, fix, perf, refactor, docs, chore, breaking, next, beta\n", .{kind});
        return 1;
    }
    const ms: u64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
    var name_buf: [32]u8 = undefined;
    const name = std.mem.print(&name_buf, "{x}.json", .{@as(u64, @intCast(ms))}) catch "changeset.json";
    const path = std.fmt.allocPrint(gpa, ".churn/{s}", .{name}) catch return 1;
    defer gpa.free(path);
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    payload.print(gpa, "{{\"type\":\"{s}\",\"scope\":\"{s}\",\"description\":\"{s}\",\"breaking\":{s}}}\n", .{
        kind, args[1], args[2], if (std.mem.eql(u8, kind, "breaking")) "true" else "false",
    }) catch return 1;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = payload.items }) catch {
        std.debug.print("could not write {s} (is .churn/ present?)\n", .{path});
        return 1;
    };
    std.debug.print("added {s}\n", .{path});
    return 0;
}

fn flag(args: []const []const u8, name: []const u8) bool {
    for (args) |a| if (std.mem.eql(u8, a, name)) return true;
    return false;
}

fn cmdVersion(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8) u8 {
    const cur = currentVersion(gpa, io);
    if (cur.len == 0) {
        std.debug.print("could not read version from build.zig.zon\n", .{});
        return 1;
    }
    const beta = flag(args, "--beta");
    const promote = flag(args, "--stable") and !beta;
    const bump = bumpFromChangesets(gpa, io);
    const next = release_mod.nextVersion(gpa, cur, bump, promote) catch return 1;
    defer gpa.free(next);
    std.debug.print("current: {s}\nchangesets: {d}\nbump: {s}\nnext: {s}\n", .{
        cur, countChangesets(gpa, io), @tagName(bump), next,
    });
    return 0;
}

fn cmdChangelog(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map) u8 {
    const result = run(gpa, io, env, &.{ "python3", "tools/generate_changelog.py" }) orelse {
        std.debug.print("changelog generation failed\n", .{});
        return 1;
    };
    defer gpa.free(result);
    std.debug.print("changelog regenerated from git history\n", .{});
    return 0;
}

/// Rename `## [Unreleased]` into a dated version section and open a fresh one.
/// The Python generator only rebuilds the Unreleased block; the cut is ours.
fn cutChangelog(gpa: std.mem.Allocator, io: std.Io, version: []const u8) u8 {
    const data = std.Io.Dir.cwd().readFileAlloc(io, "CHANGELOG.md", gpa, .limited(8 * 1024 * 1024)) catch {
        std.debug.print("release: cannot read CHANGELOG.md\n", .{});
        return 1;
    };
    defer gpa.free(data);
    const marker = "## [Unreleased]";
    const at = std.mem.indexOf(u8, data, marker) orelse {
        std.debug.print("release: CHANGELOG.md has no [Unreleased] section\n", .{});
        return 1;
    };
    const secs: u64 = @intCast(std.Io.Timestamp.now(io, .real).toSeconds());
    const ep = std.time.epoch.EpochSeconds{ .secs = secs };
    const yd = ep.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const date = std.fmt.allocPrint(gpa, "{d}-{d:0>2}-{d:0>2}", .{ yd.year, @intFromEnum(md.month), md.day_index + 1 }) catch return 1;
    defer gpa.free(date);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, data[0..at]) catch return 1;
    // Fresh Unreleased goes ABOVE the dated section, so the generated entries
    // that followed the old marker stay under the version we are cutting.
    out.print(gpa, "{s}\n\n## [{s}] - {s}", .{ marker, version, date }) catch return 1;
    out.appendSlice(gpa, data[at + marker.len ..]) catch return 1;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "CHANGELOG.md", .data = out.items }) catch {
        std.debug.print("release: cannot write CHANGELOG.md\n", .{});
        return 1;
    };
    return 0;
}

/// Delete the changesets that were just released (keep config.json), so the
/// next release starts from zero instead of reusing this one's bump.
fn consumeChangesets(gpa: std.mem.Allocator, io: std.Io) void {
    var dir = std.Io.Dir.cwd().openDir(io, ".churn", .{ .iterate = true }) catch return;
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".json")) continue;
        if (std.mem.eql(u8, e.name, "config.json")) continue;
        const copy = gpa.dupe(u8, e.name) catch continue;
        names.append(gpa, copy) catch gpa.free(copy);
    }
    for (names.items) |n| dir.deleteFile(io, n) catch {};
}

fn cmdRelease(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, args: []const []const u8) u8 {
    const push = flag(args, "--push");
    // 1. Refuse a dirty tree.
    const status = run(gpa, io, env, &.{ "git", "status", "--porcelain" }) orelse {
        std.debug.print("release: could not check git status\n", .{});
        return 1;
    };
    defer gpa.free(status);
    if (trimmed(status).len > 0) {
        std.debug.print("release: the working tree is dirty. Commit or stash first.\n", .{});
        return 1;
    }
    // 2. Run the gate.
    std.debug.print("release: running zig build test ...\n", .{});
    const test_out = run(gpa, io, env, &.{ "zig", "build", "test" }) orelse {
        std.debug.print("release: tests failed\n", .{});
        return 1;
    };
    gpa.free(test_out);

    // 3. Compute + write the version into build.zig.zon.
    const cur = currentVersion(gpa, io);
    const bump = bumpFromChangesets(gpa, io);
    const beta = flag(args, "--beta");
    const next = release_mod.nextVersion(gpa, cur, bump, !beta) catch return 1;
    defer gpa.free(next);

    const zon = std.Io.Dir.cwd().readFileAlloc(io, "build.zig.zon", gpa, .limited(64 * 1024)) catch return 1;
    defer gpa.free(zon);
    const needle = ".version = \"";
    const at = std.mem.indexOf(u8, zon, needle) orelse return 1;
    const rest = zon[at + needle.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return 1;
    var updated: std.ArrayList(u8) = .empty;
    defer updated.deinit(gpa);
    updated.appendSlice(gpa, zon[0 .. at + needle.len]) catch return 1;
    updated.appendSlice(gpa, next) catch return 1;
    updated.appendSlice(gpa, rest[end..]) catch return 1;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "build.zig.zon", .data = updated.items }) catch return 1;

    // 4. Regenerate the changelog, then cut the dated version section.
    if (cmdChangelog(gpa, io, env) != 0) return 1;
    if (cutChangelog(gpa, io, next) != 0) return 1;
    // The bump is spent: consume the changesets so the next release is fresh.
    consumeChangesets(gpa, io);

    // 5. Commit + tag (push only when explicit).
    const tag = std.fmt.allocPrint(gpa, "v{s}", .{next}) catch return 1;
    defer gpa.free(tag);
    const commit_msg = std.fmt.allocPrint(gpa, "chore(release): {s}", .{tag}) catch return 1;
    defer gpa.free(commit_msg);
    _ = run(gpa, io, env, &.{ "git", "add", "-A" });
    _ = run(gpa, io, env, &.{ "git", "commit", "-m", commit_msg });
    _ = run(gpa, io, env, &.{ "git", "tag", tag });
    std.debug.print("release {s} cut. Tag created locally.\n", .{tag});
    if (push) {
        _ = run(gpa, io, env, &.{ "git", "push", "origin", "main" });
        _ = run(gpa, io, env, &.{ "git", "push", "origin", tag });
        std.debug.print("pushed main and {s} - the release workflow will build all platforms.\n", .{tag});
    } else {
        std.debug.print("not pushed. Review, then: git push origin main && git push origin {s}\n", .{tag});
    }
    return 0;
}

pub fn main(init: std.process.Init) !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = std.heap.page_allocator;

    var it = std.process.Args.Iterator.init(init.minimal.args);
    var arg_list: std.ArrayList([]const u8) = .empty;
    while (it.next()) |a| arg_list.append(gpa, a) catch {};
    const args = arg_list.items;
    if (args.len < 2) {
        std.debug.print("churn - zode release/beta flow\n" ++
            "  churn add <type> <scope> <description>\n" ++
            "  churn version [--beta|--stable]\n" ++
            "  churn changelog\n" ++
            "  churn release [--beta] [--push]\n", .{});
        return;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "help")) {
        std.debug.print(
            "churn - zode release/beta flow\n" ++
            "  churn add <type> <scope> <description>   record a changeset\n" ++
            "  churn version [--beta|--stable]          print the next version (dry run)\n" ++
            "  churn changelog                          regenerate [Unreleased] from git log\n" ++
            "  churn release [--beta] [--push]          cut the release (push is explicit)\n",
            .{},
        );
        return;
    }
    const rest = args[2..];
    const code: u8 = if (std.mem.eql(u8, cmd, "add"))
        cmdAdd(gpa, io, rest)
    else if (std.mem.eql(u8, cmd, "version"))
        cmdVersion(gpa, io, rest)
    else if (std.mem.eql(u8, cmd, "changelog"))
        cmdChangelog(gpa, io, init.environ_map)
    else if (std.mem.eql(u8, cmd, "release"))
        cmdRelease(gpa, io, init.environ_map, rest)
    else blk: {
        std.debug.print("unknown command '{s}'\n", .{cmd});
        break :blk 1;
    };
    if (code != 0) std.process.exit(code);
}
