//! The batch step model: the fixed set of step kinds, the parser that
//! validates them, the item collection they operate on, and the permission set
//! a batch implies.
//!
//! Pure: no I/O, no terminal, no network. The executor lives in
//! `src/tools/batch.zig` and does the reading; everything that can be decided
//! without touching the disk is here, which is what makes it testable.
//!
//! ## Why the surface is a fixed list
//!
//! A batch is NOT a shell and NOT a general language. There is no way to
//! spell a step that is not one of `Op`'s members, the model never supplies
//! a command, and there is no network. The size of the surface IS the safety
//! argument. A tool that evaluates its own arguments is a tool whose power
//! grows with the model's imagination, and the permission dialog cannot
//! describe what it cannot enumerate.
//!
//! The only processes that run are the two FIXED git reads (`git status
//! --porcelain=v1` and `git diff HEAD`), which are the same commands the
//! `git_status` and `git_diff` tools run: a fixed argv, never the model's.
//!
//! ## The permission set of a batch is the UNION of its steps
//!
//! Every step names the tool it is a call to (`read` is a call to `read`,
//! `write` is a call to `write`). A batch that only reads needs no
//! permission, exactly like a direct `read`; a batch that writes needs the
//! same approval a direct `write` would, and the dialog names the files it
//! would touch. A batch is a way of doing several things in ONE round trip,
//! never a way of doing one of them without asking.

const std = @import("std");
const textcap = @import("textcap.zig");

/// The most steps one batch may carry. A bound, not a suggestion: the batch
/// runs host-side in one request, and a request that reads a thousand files
/// is a request that times out.
pub const max_steps = 32;

/// The step kinds. Fixed and enumerable — see the header.
pub const Op = enum {
    /// Read one file. Item: {path, text}.
    read,
    /// Read several files. One item per file.
    read_many,
    /// Search file contents. One item per match: {path, line, text}.
    grep,
    /// Find paths by pattern. One item per path: {path}.
    glob,
    /// List a directory. One item per entry: {path, kind}.
    list_files,
    /// Find a symbol's definition and uses. One item per hit.
    refs,
    /// The repository's status. One item per changed file: {path, status}.
    git_status,
    /// The repository's diff. One item: {text}.
    git_diff,
    /// Add a derived field to every item.
    map,
    /// Keep the items whose field matches.
    filter,
    /// Keep only the named fields of every item.
    select,
    /// The final value is the number of items.
    count,
    /// Write the items' text to a file.
    write,
    /// Edit a file in place.
    edit,

    pub fn name(self: Op) []const u8 {
        return @tagName(self);
    }

    pub fn fromName(s: []const u8) ?Op {
        inline for (@typeInfo(Op).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }

    /// The tool this step is a call to, when it is one.
    ///
    /// The read-only steps answer with the tool they shadow; the transforms
    /// (`map`, `filter`, `select`, `count`) answer with nothing because they
    /// touch no file at all.
    pub fn tool(self: Op) ?[]const u8 {
        return switch (self) {
            .read, .read_many => "read",
            .grep => "grep",
            .glob => "glob",
            .list_files => "list_files",
            .refs => "refs",
            .git_status => "git_status",
            .git_diff => "git_diff",
            .write => "write",
            .edit => "edit",
            .map, .filter, .select, .count => null,
        };
    }

    /// Does this step change a file?
    pub fn writes(self: Op) bool {
        return self == .write or self == .edit;
    }
};

/// The fields `map` can derive. A fixed set: a new derived field is a new row
/// here, not a new expression the model gets to write.
pub const derived_fields = [_][]const u8{ "lines", "bytes" };

pub fn isDerivedField(name: []const u8) bool {
    for (derived_fields) |f| {
        if (std.mem.eql(u8, f, name)) return true;
    }
    return false;
}

/// How `filter` compares a field against the needle.
pub const MatchMode = enum { contains, equals };

/// One step, parsed.
pub const Step = struct {
    op: Op,
    /// The file a step reads, writes or edits.
    path: []const u8 = "",
    /// The files `read_many` reads.
    paths: []const []const u8 = &.{},
    /// The pattern a search takes, or the symbol `refs` looks for.
    pattern: []const u8 = "",
    /// A glob filter for `grep`.
    glob: []const u8 = "",
    /// Where a search starts.
    subdir: []const u8 = ".",
    /// The directory `list_files` lists.
    dir: []const u8 = ".",
    /// The field a transform reads.
    field: []const u8 = "",
    /// The fields `select` keeps.
    fields: []const []const u8 = &.{},
    /// What `filter` looks for.
    match: []const u8 = "",
    mode: MatchMode = .contains,
    /// The pair `edit` replaces.
    old_string: []const u8 = "",
    new_string: []const u8 = "",
};

/// A whole batch.
pub const Batch = struct {
    steps: []const Step,
    /// Keep going after a step fails. Off by default: a batch whose third
    /// step failed is a batch whose later steps ran on the wrong data.
    continue_on_error: bool = false,
};

/// The ways a batch can be malformed. Every one of them is a NAMED refusal:
/// a batch that is quietly half-understood is a batch that writes the wrong
/// thing.
pub const ParseError = error{
    NoSteps,
    TooManySteps,
    MissingOp,
    UnknownOp,
    MissingArg,
    BadArg,
    BadField,
};

/// The sentence a refusal comes with.
///
/// The op's own name is in the CALLER's message, because "step 3 is wrong"
/// is not an error message: what has to be named is the step.
pub fn parseErrorText(err: ParseError) []const u8 {
    return switch (err) {
        error.NoSteps => "a batch needs at least one step",
        error.TooManySteps => "too many steps: a batch is one round trip, not a script",
        error.MissingOp => "every step needs an `op`",
        error.UnknownOp => "unknown step op",
        error.MissingArg => "this step is missing an argument it needs",
        error.BadArg => "this step has an argument it does not accept",
        error.BadField => "this step names a field that does not exist",
    };
}

/// Parses a batch out of the tool's arguments.
pub fn parse(arena: std.mem.Allocator, obj: std.json.ObjectMap) ParseError!Batch {
    const steps_value = obj.get("steps") orelse return error.NoSteps;
    if (steps_value != .array) return error.NoSteps;
    if (steps_value.array.items.len == 0) return error.NoSteps;
    if (steps_value.array.items.len > max_steps) return error.TooManySteps;

    var steps: std.ArrayList(Step) = .empty;
    for (steps_value.array.items) |sv| {
        if (sv != .object) return error.BadArg;
        const step = parseStep(arena, sv.object) catch |e| return e;
        steps.append(arena, step) catch return error.BadArg;
    }

    return .{
        .steps = steps.items,
        .continue_on_error = getBool(obj, "continue_on_error"),
    };
}

fn parseStep(arena: std.mem.Allocator, obj: std.json.ObjectMap) ParseError!Step {
    const op_name = getStr(obj, "op") orelse return error.MissingOp;
    const op = Op.fromName(op_name) orelse return error.UnknownOp;
    var s: Step = .{ .op = op };

    switch (op) {
        .read => {
            s.path = getStr(obj, "path") orelse return error.MissingArg;
        },
        .read_many => {
            s.paths = getStrList(arena, obj, "paths");
            if (s.paths.len == 0) return error.MissingArg;
        },
        .grep => {
            s.pattern = getStr(obj, "pattern") orelse return error.MissingArg;
            s.glob = getStr(obj, "glob") orelse "";
            s.subdir = getStr(obj, "subdir") orelse ".";
        },
        .glob => {
            s.pattern = getStr(obj, "pattern") orelse return error.MissingArg;
            s.subdir = getStr(obj, "subdir") orelse ".";
        },
        .list_files => {
            s.dir = getStr(obj, "dir") orelse ".";
        },
        .refs => {
            s.pattern = getStr(obj, "symbol") orelse return error.MissingArg;
            s.subdir = getStr(obj, "subdir") orelse ".";
        },
        .git_status, .git_diff => {},
        .map => {
            s.field = getStr(obj, "field") orelse return error.MissingArg;
            if (!isDerivedField(s.field)) return error.BadField;
        },
        .filter => {
            s.field = getStr(obj, "field") orelse return error.MissingArg;
            s.match = getStr(obj, "match") orelse return error.MissingArg;
            if (getStr(obj, "mode")) |m| {
                if (std.mem.eql(u8, m, "contains")) {
                    s.mode = .contains;
                } else if (std.mem.eql(u8, m, "equals")) {
                    s.mode = .equals;
                } else return error.BadArg;
            }
        },
        .select => {
            s.fields = getStrList(arena, obj, "fields");
            if (s.fields.len == 0) return error.MissingArg;
        },
        .count => {},
        .write => {
            s.path = getStr(obj, "path") orelse return error.MissingArg;
        },
        .edit => {
            s.path = getStr(obj, "path") orelse return error.MissingArg;
            s.old_string = getStr(obj, "old_string") orelse return error.MissingArg;
            s.new_string = getStr(obj, "new_string") orelse return error.MissingArg;
        },
    }
    return s;
}

// ── the item collection ─────────────────────────────────────────

/// One field of an item: a name and a value. A list and not a map because
/// the ORDER is part of what the model reads, and a hash map's order is not.
pub const Field = struct {
    key: []const u8,
    value: []const u8,
};

/// One row of the collection the steps operate on.
pub const Item = struct {
    fields: []const Field,
};

/// The value of a field, or null when the item does not have it.
pub fn fieldOf(item: Item, key: []const u8) ?[]const u8 {
    for (item.fields) |f| {
        if (std.mem.eql(u8, f.key, key)) return f.value;
    }
    return null;
}

/// An item with one field set (replacing it when it is already there).
pub fn withField(arena: std.mem.Allocator, item: Item, key: []const u8, value: []const u8) !Item {
    var fields: std.ArrayList(Field) = .empty;
    var replaced = false;
    for (item.fields) |f| {
        if (std.mem.eql(u8, f.key, key)) {
            try fields.append(arena, .{ .key = key, .value = value });
            replaced = true;
        } else {
            try fields.append(arena, f);
        }
    }
    if (!replaced) try fields.append(arena, .{ .key = key, .value = value });
    return .{ .fields = fields.items };
}

/// An item with two fields.
pub fn item2(arena: std.mem.Allocator, k1: []const u8, v1: []const u8, k2: []const u8, v2: []const u8) !Item {
    const fields = try arena.alloc(Field, 2);
    fields[0] = .{ .key = k1, .value = v1 };
    fields[1] = .{ .key = k2, .value = v2 };
    return .{ .fields = fields };
}

/// An item with three fields.
pub fn item3(arena: std.mem.Allocator, k1: []const u8, v1: []const u8, k2: []const u8, v2: []const u8, k3: []const u8, v3: []const u8) !Item {
    const fields = try arena.alloc(Field, 3);
    fields[0] = .{ .key = k1, .value = v1 };
    fields[1] = .{ .key = k2, .value = v2 };
    fields[2] = .{ .key = k3, .value = v3 };
    return .{ .fields = fields };
}

/// `map`: every item gains a derived field.
///
/// The derived fields are a fixed set (`lines`, `bytes`), so the map cannot
/// become a place where the model writes an expression.
pub fn mapItems(arena: std.mem.Allocator, items: []const Item, field: []const u8) ![]Item {
    var out: std.ArrayList(Item) = .empty;
    for (items) |item| {
        // The text of an item is its `content` (a whole file) or its `text`
        // (a line). Both are "the text of the item", and the map counts
        // whichever it has.
        const text = fieldOf(item, "content") orelse fieldOf(item, "text") orelse "";
        const value: []const u8 = if (std.mem.eql(u8, field, "lines"))
            try std.fmt.allocPrint(arena, "{d}", .{countLines(text)})
        else
            try std.fmt.allocPrint(arena, "{d}", .{text.len});
        try out.append(arena, try withField(arena, item, field, value));
    }
    return out.items;
}

/// `filter`: the items whose field matches the needle.
///
/// An item WITHOUT the field is dropped: a filter that kept the items it
/// could not judge would silently change the shape of the answer.
pub fn filterItems(
    arena: std.mem.Allocator,
    items: []const Item,
    field: []const u8,
    mode: MatchMode,
    needle: []const u8,
) ![]Item {
    var out: std.ArrayList(Item) = .empty;
    for (items) |item| {
        const value = fieldOf(item, field) orelse continue;
        const keep = switch (mode) {
            .contains => std.mem.indexOf(u8, value, needle) != null,
            .equals => std.mem.eql(u8, value, needle),
        };
        if (keep) try out.append(arena, item);
    }
    return out.items;
}

/// `select`: the items, with only the named fields.
pub fn selectItems(arena: std.mem.Allocator, items: []const Item, fields: []const []const u8) ![]Item {
    var out: std.ArrayList(Item) = .empty;
    for (items) |item| {
        var kept: std.ArrayList(Field) = .empty;
        for (fields) |want| {
            if (fieldOf(item, want)) |value| {
                try kept.append(arena, .{ .key = want, .value = value });
            }
        }
        try out.append(arena, .{ .fields = kept.items });
    }
    return out.items;
}

/// The number of lines in a text. An empty text is ZERO lines, not one: the
/// file that does not exist yet has no lines, and "1" would be a lie.
pub fn countLines(text: []const u8) usize {
    if (text.len == 0) return 0;
    var n: usize = 1;
    for (text) |c| {
        if (c == '\n') n += 1;
    }
    // A trailing newline does not start a new line.
    if (text[text.len - 1] == '\n') n -= 1;
    return n;
}

/// The collection, as text: ONE line per item.
///
/// The shape of a line depends on what the item carries, and that is what
/// makes it readable: a search hit reads as `path:line: text`, a file reads
/// as its path with its size and a PREVIEW of its first line, and anything
/// else reads as its fields.
///
/// The preview is a preview and not the file: a batch over four files would
/// otherwise carry four whole files into the answer, and the whole point of
/// the tool is that the answer is SMALLER than the work was.
pub fn renderItems(arena: std.mem.Allocator, items: []const Item) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (items) |item| {
        if (out.items.len > 0) try out.append(arena, '\n');

        const path = fieldOf(item, "path");
        const line = fieldOf(item, "line");
        const text = fieldOf(item, "text");
        const content = fieldOf(item, "content");

        if (path) |p| {
            if (line) |l| {
                try out.appendSlice(arena, p);
                try out.append(arena, ':');
                try out.appendSlice(arena, l);
                if (text) |t| {
                    try out.appendSlice(arena, ": ");
                    try out.appendSlice(arena, t);
                }
                continue;
            }
            try out.appendSlice(arena, p);
            for (item.fields) |f| {
                if (std.mem.eql(u8, f.key, "path")) continue;
                if (std.mem.eql(u8, f.key, "content")) continue;
                try out.print(arena, " · {s}={s}", .{ f.key, f.value });
            }
            if (content) |c| {
                try out.appendSlice(arena, " · ");
                try out.appendSlice(arena, try preview(arena, c));
            }
            continue;
        }

        var first = true;
        for (item.fields) |f| {
            if (!first) try out.append(arena, ' ');
            first = false;
            try out.print(arena, "{s}={s}", .{ f.key, f.value });
        }
    }
    return out.items;
}

/// The first line of a text, clipped to `preview_cols` columns.
///
/// A preview and not the text: the whole text of four files is the thing the
/// batch was built to avoid.
pub const preview_cols: usize = 100;

fn preview(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var end: usize = text.len;
    if (std.mem.indexOfScalar(u8, text, '\n')) |nl| end = nl;
    const first_line = text[0..end];
    var buf: [preview_cols * 4]u8 = undefined;
    const clipped = textcap.clipInto(first_line, preview_cols, &buf);
    if (clipped.len == first_line.len) return first_line;
    return std.fmt.allocPrint(arena, "{s}…", .{clipped});
}

// ── the permission set ──────────────────────────────────────────

/// The tools a batch calls, in the order they first appear.
///
/// THE union of its steps: a batch's permission set is exactly the set of
/// permissions its steps would have needed one by one. That is the property
/// that makes a batch a shortcut and not a hole.
pub fn permissionTools(arena: std.mem.Allocator, b: Batch) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (b.steps) |s| {
        const t = s.op.tool() orelse continue;
        var seen = false;
        for (out.items) |o| {
            if (std.mem.eql(u8, o, t)) {
                seen = true;
                break;
            }
        }
        if (!seen) try out.append(arena, t);
    }
    return out.items;
}

/// The files a batch would write or edit, in order and without repeats.
///
/// The permission dialog names them: a dialog that says "batch" and nothing
/// else is a dialog about nothing.
pub fn touchedPaths(arena: std.mem.Allocator, b: Batch) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (b.steps) |s| {
        if (!s.op.writes()) continue;
        if (s.path.len == 0) continue;
        var seen = false;
        for (out.items) |o| {
            if (std.mem.eql(u8, o, s.path)) {
                seen = true;
                break;
            }
        }
        if (!seen) try out.append(arena, s.path);
    }
    return out.items;
}

// ── small JSON helpers ──────────────────────────────────────────
//
// The ones in `tools/common.zig` allocate their list with the PAGE allocator,
// which is fine for a tool that hands the list to a caller that never frees
// it and wrong for a library that has to be leak-free. These two are the
// same functions with the arena they are given.

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn getBool(obj: std.json.ObjectMap, key: []const u8) bool {
    const v = obj.get(key) orelse return false;
    return switch (v) {
        .bool => |b| b,
        .string => |s| std.ascii.eqlIgnoreCase(s, "true"),
        .integer => |i| i != 0,
        else => false,
    };
}

fn getStrList(arena: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) []const []const u8 {
    const v = obj.get(key) orelse return &.{};
    if (v != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (v.array.items) |e| {
        if (e == .string) out.append(arena, e.string) catch return out.items;
    }
    return out.items;
}

// ── tests ────────────────────────────────────────────────────────

fn parseJson(a: std.mem.Allocator, json: []const u8) !Batch {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    return parse(a, v.object);
}

test "batch: the steps are parsed and each op keeps its own arguments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const b = try parseJson(a,
        \\{"steps":[
        \\ {"op":"read","path":"src/a.zig"},
        \\ {"op":"read_many","paths":["src/b.zig","src/c.zig"]},
        \\ {"op":"grep","pattern":"TODO","glob":"**/*.zig"},
        \\ {"op":"filter","field":"path","match":"src/","mode":"equals"},
        \\ {"op":"select","fields":["path","line"]},
        \\ {"op":"map","field":"lines"},
        \\ {"op":"count"},
        \\ {"op":"write","path":"report.md"},
        \\ {"op":"edit","path":"src/a.zig","old_string":"x","new_string":"y"}
        \\]}
    );
    try std.testing.expectEqual(@as(usize, 9), b.steps.len);
    try std.testing.expectEqual(Op.read, b.steps[0].op);
    try std.testing.expectEqualStrings("src/a.zig", b.steps[0].path);
    try std.testing.expectEqualStrings("src/b.zig", b.steps[1].paths[0]);
    try std.testing.expectEqualStrings("TODO", b.steps[2].pattern);
    try std.testing.expectEqualStrings("**/*.zig", b.steps[2].glob);
    try std.testing.expectEqual(MatchMode.equals, b.steps[3].mode);
    try std.testing.expectEqualStrings("line", b.steps[4].fields[1]);
    try std.testing.expectEqual(Op.map, b.steps[5].op);
    try std.testing.expectEqual(Op.count, b.steps[6].op);
    try std.testing.expectEqualStrings("y", b.steps[8].new_string);
    try std.testing.expect(!b.continue_on_error);
}

test "batch: an empty batch, an unknown op and a missing argument are refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try std.testing.expectError(error.NoSteps, parseJson(a, "{}"));
    try std.testing.expectError(error.NoSteps, parseJson(a, "{\"steps\":[]}"));
    try std.testing.expectError(error.MissingOp, parseJson(a, "{\"steps\":[{}]}"));
    try std.testing.expectError(error.UnknownOp, parseJson(a, "{\"steps\":[{\"op\":\"exec\"}]}"));
    try std.testing.expectError(error.MissingArg, parseJson(a, "{\"steps\":[{\"op\":\"read\"}]}"));
    try std.testing.expectError(error.MissingArg, parseJson(a, "{\"steps\":[{\"op\":\"grep\"}]}"));
    try std.testing.expectError(error.MissingArg, parseJson(a, "{\"steps\":[{\"op\":\"filter\",\"field\":\"path\"}]}"));
    try std.testing.expectError(error.MissingArg, parseJson(a, "{\"steps\":[{\"op\":\"select\"}]}"));
    // A derived field that does not exist is refused rather than ignored: a
    // `map` that silently does nothing looks exactly like a `map` that worked.
    try std.testing.expectError(error.BadField, parseJson(a, "{\"steps\":[{\"op\":\"map\",\"field\":\"whatever\"}]}"));
    try std.testing.expectError(error.BadArg, parseJson(a, "{\"steps\":[{\"op\":\"filter\",\"field\":\"path\",\"match\":\"x\",\"mode\":\"fuzzy\"}]}"));
}

test "batch: the permission set of a batch is the union of its steps" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // A batch of reads: the union is the read-only tools, and none of them
    // needs a permission.
    const reads = try parseJson(a,
        \\{"steps":[{"op":"read","path":"a"},{"op":"grep","pattern":"x"},{"op":"map","field":"lines"}]}
    );
    const read_set = try permissionTools(a, reads);
    try std.testing.expectEqual(@as(usize, 2), read_set.len);
    try std.testing.expectEqualStrings("read", read_set[0]);
    try std.testing.expectEqualStrings("grep", read_set[1]);

    // The same batch with a write in it: the union grows by exactly the tool
    // the write step is a call to, and not by "batch".
    const writes = try parseJson(a,
        \\{"steps":[{"op":"read","path":"a"},{"op":"write","path":"out.md"},{"op":"read","path":"b"}]}
    );
    const write_set = try permissionTools(a, writes);
    try std.testing.expectEqual(@as(usize, 2), write_set.len);
    try std.testing.expectEqualStrings("read", write_set[0]);
    try std.testing.expectEqualStrings("write", write_set[1]);

    // The union has no repeats: the same tool twice is one permission.
    const twice = try parseJson(a,
        \\{"steps":[{"op":"write","path":"a.md"},{"op":"write","path":"b.md"}]}
    );
    const twice_set = try permissionTools(a, twice);
    try std.testing.expectEqual(@as(usize, 1), twice_set.len);
    try std.testing.expectEqualStrings("write", twice_set[0]);
}

test "batch: the files a batch would touch are named, once each" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const b = try parseJson(a,
        \\{"steps":[
        \\ {"op":"read","path":"a.zig"},
        \\ {"op":"write","path":"out.md"},
        \\ {"op":"edit","path":"a.zig","old_string":"x","new_string":"y"},
        \\ {"op":"write","path":"out.md"}
        \\]}
    );
    const paths = try touchedPaths(a, b);
    try std.testing.expectEqual(@as(usize, 2), paths.len);
    try std.testing.expectEqualStrings("out.md", paths[0]);
    try std.testing.expectEqualStrings("a.zig", paths[1]);
}

test "batch: map adds a derived field to every item" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const one = try item2(a, "path", "a.zig", "text", "one\ntwo\nthree\n");
    const two = try item2(a, "path", "b.zig", "text", "x\n");
    const items = [_]Item{ one, two };

    const mapped = try mapItems(a, &items, "lines");
    try std.testing.expectEqualStrings("3", fieldOf(mapped[0], "lines").?);
    try std.testing.expectEqualStrings("1", fieldOf(mapped[1], "lines").?);
    // The original fields survive the map.
    try std.testing.expectEqualStrings("a.zig", fieldOf(mapped[0], "path").?);

    const bytes = try mapItems(a, &items, "bytes");
    try std.testing.expectEqualStrings("14", fieldOf(bytes[0], "bytes").?);
}

test "batch: filter keeps the matching items and drops the ones without the field" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const one = try item2(a, "path", "src/a.zig", "text", "x");
    const two = try item2(a, "path", "docs/b.md", "text", "y");
    const three = try item2(a, "text", "no path here", "kind", "file");
    const items = [_]Item{ one, two, three };

    const kept = try filterItems(a, &items, "path", .contains, "src/");
    try std.testing.expectEqual(@as(usize, 1), kept.len);
    try std.testing.expectEqualStrings("src/a.zig", fieldOf(kept[0], "path").?);

    // An item without the field is dropped, not kept: a filter that cannot
    // judge an item must not pass it through.
    const all = try filterItems(a, &items, "path", .contains, "");
    try std.testing.expectEqual(@as(usize, 2), all.len);

    const exact = try filterItems(a, &items, "path", .equals, "docs/b.md");
    try std.testing.expectEqual(@as(usize, 1), exact.len);
    try std.testing.expectEqualStrings("docs/b.md", fieldOf(exact[0], "path").?);
}

test "batch: select keeps only the named fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const one = try item3(a, "path", "a.zig", "line", "42", "text", "hello");
    const items = [_]Item{one};

    const picked = try selectItems(a, &items, &.{ "path", "line" });
    try std.testing.expectEqual(@as(usize, 2), picked[0].fields.len);
    try std.testing.expectEqualStrings("a.zig", fieldOf(picked[0], "path").?);
    try std.testing.expectEqualStrings("42", fieldOf(picked[0], "line").?);
    try std.testing.expect(fieldOf(picked[0], "text") == null);
}

test "batch: a file renders as its path and a PREVIEW, never as the whole file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const big = try a.alloc(u8, 4000);
    @memset(big, 'x');
    @memcpy(big[0..11], "first line\n");

    const item = try item3(a, "path", "src/a.zig", "content", big, "bytes", "4000");
    const items = [_]Item{item};
    const out = try renderItems(a, &items);

    // The path and the size are there.
    try std.testing.expect(std.mem.indexOf(u8, out, "src/a.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "bytes=4000") != null);
    // The preview is the first line, and the file is NOT.
    try std.testing.expect(std.mem.indexOf(u8, out, "first line") != null);
    try std.testing.expect(out.len < 200);
}

test "batch: a search hit renders as path:line: text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const item = try item3(a, "path", "src/a.zig", "line", "42", "text", "// TODO: fix this");
    const items = [_]Item{item};
    const out = try renderItems(a, &items);
    try std.testing.expectEqualStrings("src/a.zig:42: // TODO: fix this", out);
}

test "batch: the number of lines of an empty text is zero" {
    try std.testing.expectEqual(@as(usize, 0), countLines(""));
    try std.testing.expectEqual(@as(usize, 1), countLines("one"));
    try std.testing.expectEqual(@as(usize, 1), countLines("one\n"));
    try std.testing.expectEqual(@as(usize, 2), countLines("one\ntwo"));
    try std.testing.expectEqual(@as(usize, 2), countLines("one\ntwo\n"));
}

test "batch: every op names the tool it is a call to" {
    // The permission set is built out of this, so an op with no tool is an op
    // that needs no permission and an op with the WRONG tool would ask about
    // the wrong thing.
    try std.testing.expectEqualStrings("read", Op.read.tool().?);
    try std.testing.expectEqualStrings("read", Op.read_many.tool().?);
    try std.testing.expectEqualStrings("grep", Op.grep.tool().?);
    try std.testing.expectEqualStrings("glob", Op.glob.tool().?);
    try std.testing.expectEqualStrings("list_files", Op.list_files.tool().?);
    try std.testing.expectEqualStrings("refs", Op.refs.tool().?);
    try std.testing.expectEqualStrings("write", Op.write.tool().?);
    try std.testing.expectEqualStrings("edit", Op.edit.tool().?);
    try std.testing.expect(Op.map.tool() == null);
    try std.testing.expect(Op.filter.tool() == null);
    try std.testing.expect(Op.select.tool() == null);
    try std.testing.expect(Op.count.tool() == null);
    try std.testing.expect(Op.write.writes());
    try std.testing.expect(Op.edit.writes());
    try std.testing.expect(!Op.read.writes());
}
