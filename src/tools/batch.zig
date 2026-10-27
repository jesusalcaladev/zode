/// The `batch` tool: several operations in ONE round trip.
///
/// ## Why it exists
///
/// A request is the expensive thing. "Count the lines in 4 files, find the
/// TODOs in the 2 that have them, write a report" is 5 tool calls, and each
/// one is a full model request: the prompt goes out, the answer comes back,
/// and the whole thing is billed again on the NEXT iteration. A batch does the
/// same work host-side and returns one answer.
///
/// ## What it is NOT
///
/// Not a shell and not a general language. The model never supplies a
/// command, there is no way to spell a step that is not in `lib/batch.zig`'s
/// `Op`, and there is no network. The only processes that run are the two
/// FIXED git reads, which are the same commands the `git_status` and
/// `git_diff` tools run. The size of the surface IS the safety argument: a
/// tool that evaluates what the model wrote has a power that grows with the
/// model's imagination, and the permission dialog cannot describe what it
/// cannot enumerate.
///
/// ## The permission set is the UNION of the steps
///
/// A batch of reads never asks. A batch with a `write` or an `edit` step asks
/// exactly what that direct call would have asked, and the dialog names the
/// files. A batch is a way of doing several things in one round trip, never a
/// way of doing one of them without asking.
const std = @import("std");
const common = @import("common.zig");
const batch_lib = @import("../lib/batch.zig");
const resultcap = @import("../lib/resultcap.zig");
const regex_lib = @import("../lib/regex.zig");
const symbols = @import("../lib/symbols.zig");
const refs_tool = @import("refs.zig");
const glob_tool = @import("glob.zig");
const bg_tool = @import("bg.zig");
const edit_hint = @import("../lib/edit_hint.zig");

/// The largest file a read step reads.
///
/// HALF of what the `refs` scanner allows, and on purpose: a batch can read
/// thirty-two files, and the contents live in the turn's arena until the turn
/// ends. 32 × 512 KB is 16 MB of arena for a step whose whole point is to be
/// cheap. A file that big wants a `read`, which streams it.
const max_file_bytes = 256 * 1024;

/// The most matches one search step collects. Without a cap, a search for a
/// common word in a big repository is a megabyte of tool result, and the
/// thing the batch was for (saving tokens) is the thing it spends.
const max_matches = 400;

/// The result is cut here. The tool cap does the same thing later; this one
/// is here so the log and the value are cut together and the notice is not
/// the only thing that survives.
const max_value_bytes = 16 * 1024;

pub fn toolBatch(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const batch = batch_lib.parse(arena, obj) catch |err| {
        // The op's own name rides in the message: "step 3 is wrong" is not an
        // error message.
        var op_name: []const u8 = "";
        if (obj.get("steps")) |sv| {
            if (sv == .array and sv.array.items.len > 0 and sv.array.items[0] == .object) {
                op_name = common.getStr(sv.array.items[0].object, "op") orelse "";
            }
        }
        return std.fmt.allocPrint(
            arena,
            "error: {s} (step: {s})",
            .{ batch_lib.parseErrorText(err), op_name },
        );
    };

    var runner: Runner = .{ .arena = arena, .io = io };

    for (batch.steps, 0..) |step, i| {
        const outcome = runner.runStep(step) catch |err| {
            return std.fmt.allocPrint(
                arena,
                "error: step {d} ({s}) failed: {t}",
                .{ i + 1, step.op.name(), err },
            );
        };
        if (!outcome.ok) {
            runner.logStep(i, step, outcome);
            if (batch.continue_on_error) {
                runner.failed += 1;
                continue;
            }
            // The batch stops HERE: a step that failed left the collection in
            // a state the later steps were not written for, and running them
            // anyway would produce an answer about the wrong data.
            return runner.finish(arena, batch, i + 1, outcome.err_msg);
        }
        runner.logStep(i, step, outcome);
    }
    return runner.finish(arena, batch, 0, null);
}

/// What one step did.
const Outcome = struct {
    ok: bool,
    /// The step's own words: the path, the pattern.
    detail: []const u8 = "",
    /// How many items it produced (or kept).
    count: usize = 0,
    /// The reason it failed, when it did.
    err_msg: ?[]const u8 = null,
};

const Runner = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    items: std.ArrayList(batch_lib.Item) = .empty,
    log: std.ArrayList(u8) = .empty,
    /// The value the batch ends with. `count` sets it to a number; everything
    /// else ends with the collection.
    final_value: ?[]const u8 = null,
    /// How many steps failed (only ever more than zero with
    /// `continue_on_error`).
    failed: usize = 0,

    fn runStep(self: *Runner, s: batch_lib.Step) !Outcome {
        switch (s.op) {
            .read => {
                const data = self.readFile(s.path) catch |err| {
                    return .{
                        .ok = false,
                        .detail = s.path,
                        .err_msg = try std.fmt.allocPrint(self.arena, "cannot read {s}: {t}", .{ s.path, err }),
                    };
                };
                const item = try batch_lib.item3(
                    self.arena,
                    "path",
                    s.path,
                    "content",
                    data,
                    "bytes",
                    try std.fmt.allocPrint(self.arena, "{d}", .{data.len}),
                );
                try self.items.append(self.arena, item);
                return .{ .ok = true, .detail = s.path, .count = 1 };
            },
            .read_many => {
                for (s.paths) |p| {
                    const data = self.readFile(p) catch |err| {
                        return .{
                            .ok = false,
                            .detail = p,
                            .err_msg = try std.fmt.allocPrint(self.arena, "cannot read {s}: {t}", .{ p, err }),
                        };
                    };
                    const item = try batch_lib.item3(
                        self.arena,
                        "path",
                        p,
                        "content",
                        data,
                        "bytes",
                        try std.fmt.allocPrint(self.arena, "{d}", .{data.len}),
                    );
                    try self.items.append(self.arena, item);
                }
                return .{ .ok = true, .detail = "the files", .count = s.paths.len };
            },
            .grep => {
                const re = regex_lib.Regex.compile(s.pattern);
                var found: usize = 0;
                var files = common.searchableFiles(self.io, self.arena, s.subdir);
                defer files.deinit();
                while (files.next()) |path| {
                    defer self.arena.free(path);
                    if (found >= max_matches) break;
                    if (s.glob.len > 0 and !glob_tool.globMatch(s.glob, path)) continue;
                    const data = self.readFile(path) catch continue;
                    var line_no: usize = 0;
                    var it = std.mem.splitScalar(u8, data, '\n');
                    while (it.next()) |line| {
                        line_no += 1;
                        if (!re.matches(line)) continue;
                        if (found >= max_matches) break;
                        const item = try batch_lib.item3(
                            self.arena,
                            "path",
                            path,
                            "line",
                            try std.fmt.allocPrint(self.arena, "{d}", .{line_no}),
                            "text",
                            try self.arena.dupe(u8, line),
                        );
                        try self.items.append(self.arena, item);
                        found += 1;
                    }
                }
                return .{ .ok = true, .detail = s.pattern, .count = found };
            },
            .glob => {
                var found: usize = 0;
                var walker = common.walkZig(self.io, self.arena, s.subdir) catch |err| {
                    return .{
                        .ok = false,
                        .detail = s.pattern,
                        .err_msg = try std.fmt.allocPrint(self.arena, "cannot walk {s}: {t}", .{ s.subdir, err }),
                    };
                };
                defer walker.deinit();
                while (walker.next()) |path| {
                    defer self.arena.free(path);
                    if (found >= max_matches) break;
                    if (!glob_tool.globMatch(s.pattern, path)) continue;
                    const item = try batch_lib.item2(self.arena, "path", path, "kind", "file");
                    try self.items.append(self.arena, item);
                    found += 1;
                }
                return .{ .ok = true, .detail = s.pattern, .count = found };
            },
            .list_files => {
                var dir = std.Io.Dir.cwd().openDir(self.io, s.dir, .{ .iterate = true }) catch |err| {
                    return .{
                        .ok = false,
                        .detail = s.dir,
                        .err_msg = try std.fmt.allocPrint(self.arena, "cannot list {s}: {t}", .{ s.dir, err }),
                    };
                };
                defer dir.close(self.io);
                var found: usize = 0;
                var it = dir.iterate();
                while (it.next(self.io) catch null) |e| {
                    if (e.name.len > 0 and e.name[0] == '.') continue;
                    const path = if (std.mem.eql(u8, s.dir, "."))
                        try self.arena.dupe(u8, e.name)
                    else
                        try std.fmt.allocPrint(self.arena, "{s}/{s}", .{ s.dir, e.name });
                    const kind: []const u8 = switch (e.kind) {
                        .directory => "dir",
                        .file => "file",
                        else => "other",
                    };
                    const item = try batch_lib.item3(self.arena, "path", path, "kind", kind, "name", e.name);
                    try self.items.append(self.arena, item);
                    found += 1;
                    if (found >= max_matches) break;
                }
                return .{ .ok = true, .detail = s.dir, .count = found };
            },
            .refs => {
                if (!symbols.validSymbol(s.pattern)) {
                    return .{
                        .ok = false,
                        .detail = s.pattern,
                        .err_msg = try std.fmt.allocPrint(
                            self.arena,
                            "{s} is not a plain identifier, so it cannot be a symbol. Use a grep step for a pattern.",
                            .{s.pattern},
                        ),
                    };
                }
                const found = refs_tool.findHits(self.io, self.arena, s.subdir, s.pattern) catch |err| {
                    return .{
                        .ok = false,
                        .detail = s.pattern,
                        .err_msg = try std.fmt.allocPrint(self.arena, "the symbol search failed: {t}", .{err}),
                    };
                };
                for (found.hits) |hit| {
                    const item = try batch_lib.item3(
                        self.arena,
                        "path",
                        hit.path,
                        "line",
                        try std.fmt.allocPrint(self.arena, "{d}", .{hit.line}),
                        "text",
                        hit.text,
                    );
                    try self.items.append(self.arena, item);
                }
                return .{ .ok = true, .detail = s.pattern, .count = found.hits.len };
            },
            .git_status => {
                const r = bg_tool.runForeground(self.arena, self.io, "git status --porcelain=v1", 10, 64 * 1024) catch |err| {
                    return .{
                        .ok = false,
                        .detail = "git status",
                        .err_msg = try std.fmt.allocPrint(self.arena, "git status failed: {t}", .{err}),
                    };
                };
                if (r.term) |t| {
                    if (t.exited != 0) {
                        return .{
                            .ok = false,
                            .detail = "git status",
                            .err_msg = "git status failed: not a repository, or git is not there",
                        };
                    }
                }
                var found: usize = 0;
                var it = std.mem.splitScalar(u8, r.stdout, '\n');
                while (it.next()) |line| {
                    if (line.len < 4) continue;
                    const status = line[0..2];
                    var path = line[3..];
                    // A rename is "old -> new"; the new one is what matters.
                    if (std.mem.indexOf(u8, path, " -> ")) |arrow| {
                        path = path[arrow + 4 ..];
                    }
                    const item = try batch_lib.item3(self.arena, "path", path, "status", status, "kind", "file");
                    try self.items.append(self.arena, item);
                    found += 1;
                    if (found >= max_matches) break;
                }
                return .{ .ok = true, .detail = "git status", .count = found };
            },
            .git_diff => {
                const r = bg_tool.runForeground(self.arena, self.io, "git diff HEAD", 10, 256 * 1024) catch |err| {
                    return .{
                        .ok = false,
                        .detail = "git diff",
                        .err_msg = try std.fmt.allocPrint(self.arena, "git diff failed: {t}", .{err}),
                    };
                };
                if (r.term) |t| {
                    if (t.exited != 0) {
                        return .{
                            .ok = false,
                            .detail = "git diff",
                            .err_msg = "git diff failed: not a repository, or git is not there",
                        };
                    }
                }
                const item = try batch_lib.item2(self.arena, "text", r.stdout, "kind", "diff");
                try self.items.append(self.arena, item);
                return .{ .ok = true, .detail = "git diff", .count = 1 };
            },
            .map => {
                self.items.items = try batch_lib.mapItems(self.arena, self.items.items, s.field);
                return .{ .ok = true, .detail = s.field, .count = self.items.items.len };
            },
            .filter => {
                self.items.items = try batch_lib.filterItems(self.arena, self.items.items, s.field, s.mode, s.match);
                return .{ .ok = true, .detail = s.field, .count = self.items.items.len };
            },
            .select => {
                self.items.items = try batch_lib.selectItems(self.arena, self.items.items, s.fields);
                return .{ .ok = true, .detail = "the fields", .count = self.items.items.len };
            },
            .count => {
                self.final_value = try std.fmt.allocPrint(self.arena, "{d} items", .{self.items.items.len});
                return .{ .ok = true, .detail = "the items", .count = self.items.items.len };
            },
            .write => {
                const content = try self.itemsText();
                std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = s.path, .data = content }) catch |err| {
                    return .{
                        .ok = false,
                        .detail = s.path,
                        .err_msg = try std.fmt.allocPrint(self.arena, "cannot write {s}: {t}", .{ s.path, err }),
                    };
                };
                const item = try batch_lib.item3(
                    self.arena,
                    "path",
                    s.path,
                    "bytes",
                    try std.fmt.allocPrint(self.arena, "{d}", .{content.len}),
                    "kind",
                    "written",
                );
                try self.items.append(self.arena, item);
                self.final_value = try std.fmt.allocPrint(self.arena, "wrote {s} ({d} bytes)", .{ s.path, content.len });
                return .{ .ok = true, .detail = s.path, .count = 1 };
            },
            .edit => {
                const data = self.readFile(s.path) catch |err| {
                    return .{
                        .ok = false,
                        .detail = s.path,
                        .err_msg = try std.fmt.allocPrint(self.arena, "cannot read {s}: {t}", .{ s.path, err }),
                    };
                };
                if (std.mem.eql(u8, s.old_string, s.new_string)) {
                    return .{
                        .ok = false,
                        .detail = s.path,
                        .err_msg = "old_string and new_string are identical, so this step would write the file back unchanged. Send the text you meant to put there, or drop the step.",
                    };
                }
                const idx = std.mem.indexOf(u8, data, s.old_string) orelse {
                    // The same recovery the `edit` tool offers: the nearest line
                    // and WHICH of the failures this is, so the model does not
                    // spend an iteration reading the file again.
                    const hint = edit_hint.hintFor(self.arena, data, s.old_string) catch edit_hint.Hint{ .text = "" };
                    return .{
                        .ok = false,
                        .detail = s.path,
                        .err_msg = try std.fmt.allocPrint(self.arena, "{s}", .{edit_hint.message(hint, s.path)}),
                    };
                };
                const out = try std.mem.concat(self.arena, u8, &.{
                    data[0..idx],
                    s.new_string,
                    data[idx + s.old_string.len ..],
                });
                std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = s.path, .data = out }) catch |err| {
                    return .{
                        .ok = false,
                        .detail = s.path,
                        .err_msg = try std.fmt.allocPrint(self.arena, "cannot write {s}: {t}", .{ s.path, err }),
                    };
                };
                const item = try batch_lib.item3(
                    self.arena,
                    "path",
                    s.path,
                    "bytes",
                    try std.fmt.allocPrint(self.arena, "{d}", .{out.len}),
                    "kind",
                    "edited",
                );
                try self.items.append(self.arena, item);
                self.final_value = try std.fmt.allocPrint(self.arena, "edited {s}", .{s.path});
                return .{ .ok = true, .detail = s.path, .count = 1 };
            },
        }
    }

    fn readFile(self: *Runner, path: []const u8) ![]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, self.arena, .limited(max_file_bytes));
    }

    /// The text of every item, joined. What a `write` step writes.
    ///
    /// An item's text is its `content` (a whole file) or its `text` (a
    /// line): the file is what a `write` step is for, and a line is what a
    /// search step produced.
    fn itemsText(self: *Runner) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (self.items.items) |item| {
            const text = batch_lib.fieldOf(item, "content") orelse batch_lib.fieldOf(item, "text") orelse continue;
            if (out.items.len > 0) try out.append(self.arena, '\n');
            try out.appendSlice(self.arena, text);
        }
        return out.items;
    }

    fn logStep(self: *Runner, index: usize, s: batch_lib.Step, outcome: Outcome) void {
        self.log.print(self.arena, "{d}. {s} {s}", .{ index + 1, s.op.name(), outcome.detail }) catch {};
        if (outcome.ok) {
            self.log.print(self.arena, " -> {d} item(s)\n", .{outcome.count}) catch {};
        } else {
            self.log.print(self.arena, " -> FAILED\n", .{}) catch {};
        }
    }

    /// The result: the log, one line per step, and the final value.
    fn finish(self: *Runner, arena: std.mem.Allocator, batch: batch_lib.Batch, stopped_at: usize, err_msg: ?[]const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        // The saving, said out loud: this is what the batch bought.
        try out.print(arena, "{d} step(s), 1 request\n", .{batch.steps.len});
        try out.appendSlice(arena, self.log.items);
        if (err_msg) |m| {
            try out.print(arena, "STOPPED at step {d}: {s}\n", .{ stopped_at, m });
        }
        if (self.failed > 0) {
            try out.print(arena, "{d} step(s) failed and the batch carried on\n", .{self.failed});
        }
        try out.appendSlice(arena, "RESULT:\n");
        if (self.final_value) |v| {
            try out.appendSlice(arena, v);
            try out.append(arena, '\n');
        } else {
            const rendered = try batch_lib.renderItems(arena, self.items.items);
            // The same 16 KB budget every other tool gets. A cut always
            // carries its notice INSIDE the budget, and the notice says what
            // to do: the point of the batch is that the answer is smaller
            // than the work was.
            const capped = try resultcap.capResult(arena, rendered, max_value_bytes);
            try out.appendSlice(arena, capped.text);
            if (capped.cut) try out.append(arena, '\n');
        }
        return out.items;
    }
};

// ── tests ────────────────────────────────────────────────────────

fn parseJson(a: std.mem.Allocator, json: []const u8) !std.json.ObjectMap {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    return v.object;
}

test "batch: a batch over four files returns ONE result and one log line per step" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A temp project with four files.
    const root = "/tmp/zode-batch-test";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    for ([_][]const u8{ "a.txt", "b.txt", "c.txt", "d.txt" }, 0..) |name, i| {
        const content = try std.fmt.allocPrint(a, "line one\nline {d}\n", .{i});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, name }), .data = content });
    }

    const obj = try parseJson(a,
        \\{"steps":[
        \\ {"op":"read_many","paths":["/tmp/zode-batch-test/a.txt","/tmp/zode-batch-test/b.txt","/tmp/zode-batch-test/c.txt","/tmp/zode-batch-test/d.txt"]},
        \\ {"op":"map","field":"lines"},
        \\ {"op":"select","fields":["path","lines"]},
        \\ {"op":"count"}
        \\]}
    );
    const out = try toolBatch(io, obj, a);

    // The header says what the batch bought.
    try std.testing.expect(std.mem.indexOf(u8, out, "4 step(s), 1 request") != null);
    // One line per step.
    try std.testing.expect(std.mem.indexOf(u8, out, "1. read_many") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "4. count") != null);
    // And ONE final value.
    try std.testing.expect(std.mem.indexOf(u8, out, "RESULT:\n4 items") != null);
}

test "batch: reading four files does NOT carry four files into the answer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "/tmp/zode-batch-size";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    var total: usize = 0;
    for ([_][]const u8{ "a.txt", "b.txt", "c.txt", "d.txt" }) |name| {
        const content = try a.alloc(u8, 8 * 1024);
        @memset(content, 'y');
        total += content.len;
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, name }),
            .data = content,
        });
    }

    const obj = try parseJson(a,
        \\{"steps":[
        \\ {"op":"read_many","paths":["/tmp/zode-batch-size/a.txt","/tmp/zode-batch-size/b.txt","/tmp/zode-batch-size/c.txt","/tmp/zode-batch-size/d.txt"]}
        \\]}
    );
    const out = try toolBatch(io, obj, a);

    // The answer is MUCH smaller than what it read. That is the whole point
    // of the tool: the work is bigger than the answer.
    try std.testing.expect(out.len < total / 4);
    // And it still says WHICH files and HOW BIG they are.
    try std.testing.expect(std.mem.indexOf(u8, out, "/tmp/zode-batch-size/a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "bytes=8192") != null);
}

test "batch: a failed step stops the batch and NAMES itself" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const obj = try parseJson(a,
        \\{"steps":[
        \\ {"op":"read","path":"/tmp/zode-batch-does-not-exist.txt"},
        \\ {"op":"count"}
        \\]}
    );
    const out = try toolBatch(io, obj, a);
    // The failure names the step and the file.
    try std.testing.expect(std.mem.indexOf(u8, out, "STOPPED at step 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "zode-batch-does-not-exist.txt") != null);
    // And the step after it did NOT run: there is no "2. count" line.
    try std.testing.expect(std.mem.indexOf(u8, out, "2. count") == null);
}

test "batch: continue_on_error keeps going and says how many failed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const obj = try parseJson(a,
        \\{"steps":[
        \\ {"op":"read","path":"/tmp/zode-batch-does-not-exist.txt"},
        \\ {"op":"count"}
        \\],"continue_on_error":true}
    );
    const out = try toolBatch(io, obj, a);
    try std.testing.expect(std.mem.indexOf(u8, out, "FAILED") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "1 step(s) failed") != null);
    // The second step DID run.
    try std.testing.expect(std.mem.indexOf(u8, out, "2. count") != null);
}

test "batch: a malformed batch is refused with the reason, not run" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const obj = try parseJson(a, "{\"steps\":[{\"op\":\"exec\",\"cmd\":\"rm -rf /\"}]}");
    const out = try toolBatch(io, obj, a);
    try std.testing.expect(std.mem.indexOf(u8, out, "unknown step op") != null);
    // And it says nothing about the command it refused.
    try std.testing.expect(std.mem.indexOf(u8, out, "rm -rf") == null);
}

test "batch: a write step writes what the items carry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const src = "/tmp/zode-batch-src.txt";
    const dst = "/tmp/zode-batch-dst.txt";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = src, .data = "hello\n" });
    std.Io.Dir.cwd().deleteFile(io, dst) catch {};

    const obj = try parseJson(a,
        \\{"steps":[
        \\ {"op":"read","path":"/tmp/zode-batch-src.txt"},
        \\ {"op":"write","path":"/tmp/zode-batch-dst.txt"}
        \\]}
    );
    const out = try toolBatch(io, obj, a);
    try std.testing.expect(std.mem.indexOf(u8, out, "wrote /tmp/zode-batch-dst.txt") != null);

    const got = try std.Io.Dir.cwd().readFileAlloc(io, dst, a, .limited(4096));
    try std.testing.expectEqualStrings("hello\n", got);
}

test "batch: an edit step whose old_string is not there fails with the hint" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = "/tmp/zode-batch-edit.txt";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "alpha\nbeta\n" });

    const obj = try parseJson(a,
        \\{"steps":[{"op":"edit","path":"/tmp/zode-batch-edit.txt","old_string":"gamma","new_string":"delta"}]}
    );
    const out = try toolBatch(io, obj, a);
    try std.testing.expect(std.mem.indexOf(u8, out, "STOPPED at step 1") != null);
    // The file is untouched.
    const got = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4096));
    try std.testing.expectEqualStrings("alpha\nbeta\n", got);
}
