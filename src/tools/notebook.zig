/// `notebook_edit`: edit a Jupyter notebook by CELL INDEX.
///
/// ## Why this is a tool and not `edit` with a long old_string
///
/// A `.ipynb` is JSON, and a cell's source is a JSON string with the newlines
/// escaped (`"import pandas as pd\nimport numpy as np\n"`). Editing one through
/// `edit` means writing an `old_string` with the escapes exactly right, which is
/// the kind of match that looks right and silently fails — and when it does not
/// fail, the failure mode of a bad `edit` here is a notebook that no longer parses
/// and whose OUTPUTS the user was looking at are gone.
///
/// ## The one rule that matters: everything else survives
///
/// The file is parsed, the addressed cell is changed, and the tree is written back
/// WHOLE. Outputs, metadata (kernelspec, language_info, cell ids), the nbformat
/// version and every other cell come out as they went in. A tool that rebuilt a
/// notebook from its cells would throw away the outputs, the execution counts and
/// the kernel metadata — which is most of what the file is FOR.
///
/// The costs of that choice, said plainly: the JSON is re-serialized, so key order
/// inside an object follows the hash map and the formatting comes out 1-space
/// indented (what nbformat itself writes). Semantically identical, and the diff of
/// a notebook is not read by hand — the alternative is a byte-for-byte splicer with
/// no idea what it is editing.
///
/// ## The source is the cell TEXT, never its JSON encoding
///
/// `new_source` is what the cell would read as in Jupyter ("import pandas as pd\n"),
/// and this module does the splitting into the array of lines that nbformat stores.
/// The model never counts escapes and never counts columns.
const std = @import("std");
const pathsafe = @import("../lib/pathsafe.zig");
const common = @import("common.zig");

const max_notebook_bytes = 32 * 1024 * 1024;
/// After this many cells the outline stops printing them and says how many are
/// left. The COUNT at the top is always the real one: a truncated index list must
/// not read as a short notebook.
const max_outline_cells = 120;
const preview_lines = 3;
const preview_cols = 100;

/// Where the JSON stops making sense (both 1-based, as the model is told).
pub const Loc = struct { line: u64 = 0, column: u64 = 0 };

fn parseNotebook(io: std.Io, path: []const u8, arena: std.mem.Allocator, loc: ?*Loc) !std.json.Value {
    var dir = std.Io.Dir.cwd();
    const data = try dir.readFileAlloc(io, path, arena, .limited(max_notebook_bytes));
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{}) catch {
        // A SYNTAX failure is its own error, with its own place when the caller
        // asked for one. "Does not parse" and "parses but is not a notebook" are
        // two different problems, and only the first has a line to point at —
        // an error name cannot carry a payload, so the location rides out as
        // text from the tool that has a message to compose.
        // The error does not depend on whether a location was asked for: the
        // parse failed either way, and calling that "not a notebook" would send
        // a future caller looking for a shape problem in a file that is simply
        // broken. The location is filled when someone can use it.
        if (loc) |l| {
            if (locateSyntax(data, arena)) |bad| l.* = bad;
        }
        return error.NotebookSyntax;
    };
    if (v != .object) return error.NotANotebook;
    const cells = v.object.get("cells") orelse return error.NotANotebook;
    if (cells != .array) return error.NotANotebook;
    return v;
}

/// The line and column where a scan of `data` fails, or null when it scans
/// clean. Only reached AFTER `parseFromSliceLeaky` already said no, so the
/// happy path never pays for having this around.
fn locateSyntax(data: []const u8, arena: std.mem.Allocator) ?Loc {
    var diag = std.json.Diagnostics{};
    var scan = std.json.Scanner.initCompleteInput(arena, data);
    scan.enableDiagnostics(&diag);
    while (true) {
        // An error is the answer we came for; a clean scan means there is no
        // location to give (and the caller keeps the old contract).
        const tok = scan.nextAlloc(arena, .alloc_if_needed) catch break;
        if (tok == .end_of_document) return null;
    }
    return .{ .line = diag.getLine(), .column = diag.getColumn() };
}

/// A cell's text, from whichever of the two legal encodings it uses: an array of
/// lines (what nbformat writes) or a single string (also legal, and seen in files
/// written by hand).
fn cellSource(arena: std.mem.Allocator, cell: std.json.ObjectMap) ![]const u8 {
    const src = cell.get("source") orelse return "";
    switch (src) {
        .string => |s| return s,
        .array => |arr| {
            var out: std.ArrayList(u8) = .empty;
            for (arr.items) |piece| {
                if (piece == .string) try out.appendSlice(arena, piece.string);
            }
            return out.items;
        },
        else => return "",
    }
}

fn cellType(cell: std.json.ObjectMap) []const u8 {
    const t = cell.get("cell_type") orelse return "code";
    if (t != .string) return "code";
    return t.string;
}

/// The cell text as the array of lines nbformat stores: every line keeps its own
/// newline, so a cell that ends in a newline round-trips as one.
fn linesValue(arena: std.mem.Allocator, src: []const u8) !std.json.Value {
    var arr: std.json.Array = .init(arena);
    var start: usize = 0;
    while (start < src.len) {
        const nl = std.mem.indexOfScalarPos(u8, src, start, '\n');
        if (nl) |at| {
            try arr.append(.{ .string = src[start .. at + 1] });
            start = at + 1;
        } else {
            try arr.append(.{ .string = src[start..] });
            start = src.len;
        }
    }
    return .{ .array = arr };
}

fn lineCount(src: []const u8) usize {
    if (src.len == 0) return 0;
    return 1 + std.mem.count(u8, src, "\n") - @as(usize, if (src[src.len - 1] == '\n') 1 else 0);
}

/// A short id for a NEW cell, derived from the cell's own text and its position.
///
/// nbformat 4.5 requires an id and 4.4 and older forbid one, so it is only written
/// when the notebook's own cells already carry one — decided by the FILE, never by a
/// version guess, because both mistakes produce a notebook that will not open.
///
/// Derived and not random on purpose: two inserts in one call, or in one test run,
/// cannot collide (the salt is the length the notebook has at that moment), and a
/// deterministic id makes the round-trip testable without a seam for randomness.
fn newCellId(arena: std.mem.Allocator, source: []const u8, salt: usize) ![]const u8 {
    var h = std.hash.Wyhash.init(0x9e3779b9 +% salt);
    h.update(source);
    const n: u32 = @truncate(h.final());
    return std.fmt.allocPrint(arena, "zode{x:0>8}", .{n});
}

fn hasCellIds(cells: *const std.json.Array) bool {
    if (cells.items.len == 0) return false;
    const first = cells.items[0];
    if (first != .object) return false;
    return first.object.get("id") != null;
}

/// Makes the cell the type it now is, including the fields that type REQUIRES.
///
/// A code cell without `outputs`/`execution_count` and a markdown cell WITH them
/// are both invalid nbformat: Jupyter refuses to open the file, which from the
/// outside is "zode broke my notebook" with no other explanation. This is the part
/// of the tool that has to know a little about the format rather than about JSON.
fn setCellType(arena: std.mem.Allocator, cell: *std.json.ObjectMap, kind: []const u8) !void {
    try cell.put(arena, "cell_type", .{ .string = kind });
    if (std.mem.eql(u8, kind, "code")) {
        if (cell.get("outputs") == null) try cell.put(arena, "outputs", .{ .array = .init(arena) });
        if (cell.get("execution_count") == null) try cell.put(arena, "execution_count", .null);
    } else {
        _ = cell.orderedRemove("outputs");
        _ = cell.orderedRemove("execution_count");
    }
    if (cell.get("metadata") == null) try cell.put(arena, "metadata", .{ .object = .empty });
}

/// The whole `notebook_edit` call.
pub fn toolNotebookEdit(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const path = common.getStr(obj, "notebook_path") orelse common.getStr(obj, "path") orelse return error.MissingPath;

    // The same rule as `write` and `edit`: a notebook is a file, and there are
    // places this tool does not write.
    const verdict = pathsafe.checkWriteApproved(std.Io.Dir.cwd(), io, arena, path);
    if (verdict != .ok) return pathsafe.refusalText(arena, verdict);
    if (!std.mem.endsWith(u8, path, ".ipynb")) return error.NotANotebook;
    const index_raw = common.getInt(obj, "cell_number") orelse common.getInt(obj, "cell_index") orelse return error.MissingCellNumber;
    if (index_raw < 0) return error.BadCellNumber;
    const idx: usize = @intCast(index_raw);
    const mode = common.getStr(obj, "edit_mode") orelse "replace";
    const new_source = common.getStr(obj, "new_source") orelse common.getStr(obj, "source") orelse "";
    const want_type = common.getStr(obj, "cell_type");

    const replace = std.mem.eql(u8, mode, "replace");
    const insert = std.mem.eql(u8, mode, "insert");
    const delete = std.mem.eql(u8, mode, "delete");
    if (!replace and !insert and !delete) return error.BadEditMode;

    // The one refusal that carries its own evidence: a line and a column to
    // look at. Nothing is written before the WHOLE file parses, so the file on
    // disk is still exactly the one the user had.
    var loc: Loc = .{};
    var root = parseNotebook(io, path, arena, &loc) catch |err| {
        // `loc.line != 0` means the re-scan really named a spot. If it could not
        // (a failure that is not a syntax error), the error itself still reaches
        // `describeError`, which has prose for it.
        if (err == error.NotebookSyntax and loc.line != 0) {
            const msg = std.fmt.allocPrint(
                arena,
                "refused: {s} does not parse as JSON — the syntax breaks at line {d}, column {d}. Nothing was written (notebook_edit parses the whole file before touching a cell). Look at that spot with bash (`cat {s}`) or fix the line with edit, then send the call again.",
                .{ path, loc.line, loc.column, path },
            ) catch return err;
            return msg;
        }
        return err;
    };
    const cells_value = root.object.getPtr("cells").?;
    const cells = &cells_value.array;

    var out = std.Io.Writer.Allocating.init(arena);
    const w = &out.writer;

    if (delete) {
        if (idx >= cells.items.len) return error.CellOutOfRange;
        const removed = cells.items[idx];
        const kind = if (removed == .object) cellType(removed.object) else "?";
        _ = cells.orderedRemove(idx);
        try w.print("deleted cell {d} ({s}) in {s}; {d} cells left.", .{ idx, kind, path, cells.items.len });
    } else if (insert) {
        // An insert at exactly `len` appends, which is what "insert after the last
        // cell" means and the only way to add one to an empty notebook.
        if (idx > cells.items.len) return error.CellOutOfRange;
        const kind = want_type orelse "code";
        if (!std.mem.eql(u8, kind, "code") and !std.mem.eql(u8, kind, "markdown")) return error.BadCellType;
        // `.empty`, not `.init(arena)`: `json.ObjectMap` is the UNMANAGED hash map,
        // so every call that allocates takes the arena as its first argument.
        var cell: std.json.ObjectMap = .empty;
        try setCellType(arena, &cell, kind);
        if (hasCellIds(cells)) {
            try cell.put(arena, "id", .{ .string = try newCellId(arena, new_source, cells.items.len) });
        }
        try cell.put(arena, "source", try linesValue(arena, new_source));
        try cells.insert(idx, .{ .object = cell });
        try w.print("inserted a {s} cell at {d} in {s}; {d} cells now.", .{ kind, idx, path, cells.items.len });
    } else {
        if (idx >= cells.items.len) return error.CellOutOfRange;
        const cell_value = &cells.items[idx];
        if (cell_value.* != .object) return error.NotANotebook;
        const cell = &cell_value.object;
        try cell.put(arena, "source", try linesValue(arena, new_source));
        if (want_type) |kind| {
            if (!std.mem.eql(u8, kind, "code") and !std.mem.eql(u8, kind, "markdown")) return error.BadCellType;
            try setCellType(arena, cell, kind);
        }
        try w.print("edited cell {d} ({s}) in {s}: now {d} lines.", .{ idx, cellType(cell.*), path, lineCount(new_source) });
    }

    // The preview, capped, and on ONE line per line of source: it is the same
    // "show what was written" the `write` tool does, and it is what lets the model
    // see that the newlines it sent landed where it meant them to.
    if (new_source.len > 0 and !delete) {
        try w.writeAll("\n");
        var it = std.mem.splitScalar(u8, new_source, '\n');
        var shown: usize = 0;
        while (it.next()) |line| : (shown += 1) {
            if (shown == preview_lines) break;
            if (line.len == 0 and shown + 1 == preview_lines) break;
            const clip = line[0..@min(line.len, preview_cols)];
            try w.print("    {s}\n", .{clip});
        }
        const total = lineCount(new_source);
        if (total > shown) try w.print("    … {d} more line(s)\n", .{total - shown});
    }

    var dir = std.Io.Dir.cwd();
    const file = try dir.createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var body = std.Io.Writer.Allocating.init(arena);
    try std.json.Stringify.value(root, .{ .whitespace = .indent_1 }, &body.writer);
    try file.writeStreamingAll(io, body.written());

    return out.written();
}

/// What `read` shows for a notebook instead of its raw JSON.
///
/// Without it the model cannot address a cell: the indices it needs are the
/// POSITIONS in an array it would have to count through thousands of lines of
/// escaped JSON, and the first line of each cell is what tells it which one to
/// change.
///
/// `error.NotANotebook` is for the caller to fall back on the ordinary read: a
/// `.ipynb` that does not parse is still a file someone may want to see.
pub fn outline(io: std.Io, path: []const u8, arena: std.mem.Allocator) ![]const u8 {
    const root = try parseNotebook(io, path, arena, null);
    const cells_value = root.object.getPtr("cells").?;
    const cells = &cells_value.array;

    var code: usize = 0;
    var md: usize = 0;
    for (cells.items) |cell| {
        if (cell != .object) continue;
        if (std.mem.eql(u8, cellType(cell.object), "markdown")) md += 1 else code += 1;
    }
    const version: []const u8 = blk: {
        const major = root.object.get("nbformat") orelse break :blk "?";
        const minor = root.object.get("nbformat_minor") orelse break :blk "?";
        if (major != .integer or minor != .integer) break :blk "?";
        break :blk try std.fmt.allocPrint(arena, "{d}.{d}", .{ major.integer, minor.integer });
    };

    var out = std.Io.Writer.Allocating.init(arena);
    const w = &out.writer;
    try w.print(
        "notebook {s} · nbformat {s} · {d} cell{s} ({d} code, {d} markdown)\n",
        .{ path, version, cells.items.len, if (cells.items.len == 1) "" else "s", code, md },
    );

    const shown = @min(cells.items.len, max_outline_cells);
    for (cells.items[0..shown], 0..) |cell, i| {
        if (cell != .object) {
            try w.print("[{d}] (not a cell object)\n", .{i});
            continue;
        }
        const src = try cellSource(arena, cell.object);
        try w.print("[{d}] {s} · {d} line{s}", .{ i, cellType(cell.object), lineCount(src), if (lineCount(src) == 1) "" else "s" });
        if (std.mem.eql(u8, cellType(cell.object), "code")) {
            if (cell.object.get("outputs")) |o| {
                if (o == .array) try w.print(" · {d} output{s}", .{ o.array.items.len, if (o.array.items.len == 1) "" else "s" });
            }
        }
        try w.writeAll("\n");
        // The first line, which is the cell's heading or its import: enough to know
        // WHICH cell this is without spending the notebook in the context twice.
        if (src.len > 0) {
            const nl = std.mem.indexOfScalar(u8, src, '\n') orelse src.len;
            const first = std.mem.trim(u8, src[0..nl], " \t\r");
            if (first.len > 0) try w.print("    {s}\n", .{first[0..@min(first.len, preview_cols)]});
        }
    }
    if (cells.items.len > shown) {
        try w.print("… and {d} more cell(s); the count above is the real one.\n", .{cells.items.len - shown});
    }
    // The reciprocal pointer, at the one moment it is useful: this is the file the
    // model just decided it wants to change, and the tool that can change it by index
    // is named here rather than remembered.
    try w.writeAll("change a cell with notebook_edit {notebook_path, cell_number, new_source}.\n");
    return out.written();
}

// ── tests ────────────────────────────────────────────────────────

const testing = std.testing;

/// A notebook with everything the round-trip has to preserve: an output with a
/// stream, cell ids, kernelspec metadata and a trailing newline in a source.
const fixture =
    \\{
    \\ "cells": [
    \\  {
    \\   "cell_type": "code",
    \\   "execution_count": 3,
    \\   "id": "aaaaaaaa",
    \\   "metadata": {},
    \\   "outputs": [
    \\    {
    \\     "name": "stdout",
    \\     "output_type": "stream",
    \\     "text": [
    \\      "hello\n"
    \\     ]
    \\    }
    \\   ],
    \\   "source": [
    \\    "import pandas as pd\n",
    \\    "print(pd)"
    \\   ]
    \\  },
    \\  {
    \\   "cell_type": "markdown",
    \\   "id": "bbbbbbbb",
    \\   "metadata": {},
    \\   "source": [
    \\    "# Analysis\n"
    \\   ]
    \\  }
    \\ ],
    \\ "metadata": {
    \\  "kernelspec": {
    \\   "display_name": "Python 3",
    \\   "language": "python",
    \\   "name": "python3"
    \\  }
    \\ },
    \\ "nbformat": 4,
    \\ "nbformat_minor": 5
    \\}
    \\
;

const fixture_path = "/tmp/opencode/notebook-test/a.ipynb";

fn writeFixture(body: []const u8) !void {
    _ = std.Io.Dir.cwd().createDirPath(testing.io, "/tmp/opencode/notebook-test") catch {};
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = fixture_path, .data = body });
}

fn readFixture(arena: std.mem.Allocator) !std.json.Value {
    const data = try std.Io.Dir.cwd().readFileAlloc(testing.io, fixture_path, arena, .limited(1 << 20));
    return std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{});
}

fn call(arena: std.mem.Allocator, comptime fmt: []const u8, a: anytype) ![]const u8 {
    const text = try std.fmt.allocPrint(arena, fmt, a);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    return toolNotebookEdit(testing.io, v.object, arena);
}

test "notebook_edit: replace rewrites the source and keeps the outputs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try writeFixture(fixture);

    const out = try call(arena, "{{\"notebook_path\":\"{s}\",\"cell_number\":0,\"new_source\":\"x = 1\\ny = 2\\n\"}}", .{fixture_path});
    try testing.expect(std.mem.indexOf(u8, out, "edited cell 0 (code)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "now 2 lines") != null);
    try testing.expect(std.mem.indexOf(u8, out, "x = 1") != null);

    const after = try readFixture(arena);
    const cells = after.object.get("cells").?.array;
    try testing.expectEqual(@as(usize, 2), cells.items.len);
    const first = cells.items[0].object;
    // The source is the array of lines nbformat stores, each with its newline.
    try testing.expectEqualStrings("x = 1\n", first.get("source").?.array.items[0].string);
    try testing.expectEqualStrings("y = 2\n", first.get("source").?.array.items[1].string);
    // AND THE OUTPUTS ARE STILL THERE — with the stream text and the execution count
    // exactly as they were, which is the whole reason the file is a notebook.
    try testing.expectEqual(@as(i64, 3), first.get("execution_count").?.integer);
    const outputs = first.get("outputs").?.array;
    try testing.expectEqual(@as(usize, 1), outputs.items.len);
    try testing.expectEqualStrings("hello\n", outputs.items[0].object.get("text").?.array.items[0].string);
    // Nothing else moved: the id, the markdown cell and the kernel metadata.
    try testing.expectEqualStrings("aaaaaaaa", first.get("id").?.string);
    try testing.expectEqualStrings("# Analysis\n", cells.items[1].object.get("source").?.array.items[0].string);
    try testing.expectEqualStrings("python3", after.object.get("metadata").?.object.get("kernelspec").?.object.get("name").?.string);
    try testing.expectEqual(@as(i64, 5), after.object.get("nbformat_minor").?.integer);
}

test "notebook_edit: insert adds the fields the cell type requires" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try writeFixture(fixture);

    const out = try call(arena, "{{\"notebook_path\":\"{s}\",\"cell_number\":1,\"edit_mode\":\"insert\",\"cell_type\":\"code\",\"new_source\":\"print(1)\\n\"}}", .{fixture_path});
    try testing.expect(std.mem.indexOf(u8, out, "inserted a code cell at 1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "3 cells now") != null);

    const after = try readFixture(arena);
    const cells = after.object.get("cells").?.array;
    try testing.expectEqual(@as(usize, 3), cells.items.len);
    const new_cell = cells.items[1].object;
    try testing.expectEqualStrings("code", new_cell.get("cell_type").?.string);
    // A code cell with no `outputs`/`execution_count` is an invalid notebook, and
    // Jupyter refuses the whole file rather than the cell.
    try testing.expect(new_cell.get("outputs").?.array.items.len == 0);
    try testing.expect(new_cell.get("execution_count").? == .null);
    try testing.expect(new_cell.get("metadata").? == .object);
    // The id is there because this notebook's cells have ids (nbformat 4.5).
    try testing.expect(new_cell.get("id").?.string.len > 0);
    // And it landed BETWEEN the two originals.
    try testing.expectEqualStrings("# Analysis\n", cells.items[2].object.get("source").?.array.items[0].string);

    // The other half of insert before/after: AT the cell count it appends, which
    // is "after the last cell" — the same one index addressing both directions.
    _ = try call(arena, "{{\"notebook_path\":\"{s}\",\"cell_number\":3,\"edit_mode\":\"insert\",\"new_source\":\"# tail\"}}", .{fixture_path});
    const after2 = try readFixture(arena);
    const cells2 = after2.object.get("cells").?.array;
    try testing.expectEqual(@as(usize, 4), cells2.items.len);
    try testing.expectEqualStrings("# tail", cells2.items[3].object.get("source").?.array.items[0].string);
}

test "notebook_edit: markdown insert has no code-only fields, and a type change fixes them" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try writeFixture(fixture);

    _ = try call(arena, "{{\"notebook_path\":\"{s}\",\"cell_number\":0,\"edit_mode\":\"insert\",\"cell_type\":\"markdown\",\"new_source\":\"note\\n\"}}", .{fixture_path});
    var after = try readFixture(arena);
    const inserted = after.object.get("cells").?.array.items[0].object;
    try testing.expect(inserted.get("outputs") == null);
    try testing.expect(inserted.get("execution_count") == null);

    // code -> markdown on an EXISTING cell: the outputs go with the type, or
    // nbformat has a markdown cell carrying outputs.
    _ = try call(arena, "{{\"notebook_path\":\"{s}\",\"cell_number\":1,\"cell_type\":\"markdown\",\"new_source\":\"no code any more\\n\"}}", .{fixture_path});
    after = try readFixture(arena);
    const changed = after.object.get("cells").?.array.items[1].object;
    try testing.expectEqualStrings("markdown", changed.get("cell_type").?.string);
    try testing.expect(changed.get("outputs") == null);
    try testing.expect(changed.get("execution_count") == null);
}

test "notebook_edit: delete removes exactly one cell" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try writeFixture(fixture);

    const out = try call(arena, "{{\"notebook_path\":\"{s}\",\"cell_number\":0,\"edit_mode\":\"delete\"}}", .{fixture_path});
    try testing.expect(std.mem.indexOf(u8, out, "deleted cell 0 (code)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1 cells left") != null);
    const after = try readFixture(arena);
    try testing.expectEqual(@as(usize, 1), after.object.get("cells").?.array.items.len);
    try testing.expectEqualStrings("markdown", after.object.get("cells").?.array.items[0].object.get("cell_type").?.string);
}

test "notebook_edit: an out-of-range index is a named error and never touches the file" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try writeFixture(fixture);

    try testing.expectError(error.CellOutOfRange, call(arena, "{{\"notebook_path\":\"{s}\",\"cell_number\":9,\"edit_mode\":\"delete\"}}", .{fixture_path}));
    try testing.expectError(error.CellOutOfRange, call(arena, "{{\"notebook_path\":\"{s}\",\"cell_number\":9,\"new_source\":\"x\"}}", .{fixture_path}));
    // Inserting at exactly len appends; one past that is still an error.
    try testing.expectError(error.CellOutOfRange, call(arena, "{{\"notebook_path\":\"{s}\",\"cell_number\":3,\"edit_mode\":\"insert\"}}", .{fixture_path}));

    const after = try readFixture(arena);
    try testing.expectEqual(@as(usize, 2), after.object.get("cells").?.array.items.len);
    try testing.expectEqualStrings("import pandas as pd\n", after.object.get("cells").?.array.items[0].object.get("source").?.array.items[0].string);
}

test "notebook_edit: bad arguments are refused with a name, not written" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try writeFixture(fixture);

    try testing.expectError(error.MissingCellNumber, call(arena, "{{\"notebook_path\":\"{s}\",\"new_source\":\"x\"}}", .{fixture_path}));
    try testing.expectError(error.BadEditMode, call(arena, "{{\"notebook_path\":\"{s}\",\"cell_number\":0,\"edit_mode\":\"upsert\"}}", .{fixture_path}));
    try testing.expectError(error.BadCellType, call(arena, "{{\"notebook_path\":\"{s}\",\"cell_number\":0,\"cell_type\":\"latex\"}}", .{fixture_path}));
    try testing.expectError(error.BadCellNumber, call(arena, "{{\"notebook_path\":\"{s}\",\"cell_number\":-2}}", .{fixture_path}));
    // A `.py` is not a notebook, and saying so beats corrupting one.
    try testing.expectError(error.NotANotebook, call(arena, "{{\"notebook_path\":\"src/main.zig\",\"cell_number\":0}}", .{}));

    // A malformed notebook is refused with WHERE it broke, and the original bytes stay.
    const broken = "{\n  \"cells\": [],\n  oops\n}";
    try writeFixture(broken);
    const refused = try call(arena, "{{\"notebook_path\":\"{s}\",\"cell_number\":0,\"new_source\":\"x\"}}", .{fixture_path});
    try testing.expect(std.mem.indexOf(u8, refused, "does not parse as JSON") != null);
    try testing.expect(std.mem.indexOf(u8, refused, "line 3, column") != null);
    try testing.expect(std.mem.indexOf(u8, refused, "Nothing was written") != null);
    const raw = try std.Io.Dir.cwd().readFileAlloc(testing.io, fixture_path, arena, .limited(1 << 16));
    try testing.expectEqualStrings(broken, raw);
}

test "notebook_edit: a source given as one string round-trips as lines" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The other legal encoding: `source` as a single string.
    try writeFixture("{\"cells\":[{\"cell_type\":\"code\",\"metadata\":{},\"outputs\":[],\"execution_count\":null,\"source\":\"a = 1\\nb = 2\"}],\"metadata\":{},\"nbformat\":4,\"nbformat_minor\":4}");

    const out = try call(arena, "{{\"notebook_path\":\"{s}\",\"cell_number\":0,\"new_source\":\"c = 3\\nd = 4\"}}", .{fixture_path});
    try testing.expect(std.mem.indexOf(u8, out, "edited cell 0") != null);
    const after = try readFixture(arena);
    const src = after.object.get("cells").?.array.items[0].object.get("source").?;
    try testing.expectEqual(@as(usize, 2), src.array.items.len);
    try testing.expectEqualStrings("c = 3\n", src.array.items[0].string);
    try testing.expectEqualStrings("d = 4", src.array.items[1].string);
    // nbformat 4.4 has no cell ids, so an INSERT must not add one.
    _ = try call(arena, "{{\"notebook_path\":\"{s}\",\"cell_number\":0,\"edit_mode\":\"insert\"}}", .{fixture_path});
    const after2 = try readFixture(arena);
    try testing.expect(after2.object.get("cells").?.array.items[0].object.get("id") == null);
}

test "notebook outline: indices, types, sizes and the first line of each cell" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try writeFixture(fixture);

    const text = try outline(testing.io, fixture_path, arena);
    // The counts first: they are what tells the model how big the notebook is.
    try testing.expect(std.mem.indexOf(u8, text, "nbformat 4.5") != null);
    try testing.expect(std.mem.indexOf(u8, text, "2 cells (1 code, 1 markdown)") != null);
    // Then the cells, with the index AND the output count (the thing that says
    // whether the cell was ever run).
    try testing.expect(std.mem.indexOf(u8, text, "[0] code · 2 lines · 1 output") != null);
    try testing.expect(std.mem.indexOf(u8, text, "    import pandas as pd") != null);
    try testing.expect(std.mem.indexOf(u8, text, "[1] markdown · 1 line") != null);
    try testing.expect(std.mem.indexOf(u8, text, "    # Analysis") != null);
    // And the way out: the tool that edits what was just outlined.
    try testing.expect(std.mem.indexOf(u8, text, "change a cell with notebook_edit") != null);
}

test "notebook outline: a file that is not a notebook degrades to an error, never to a crash" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try writeFixture("not json at all");
    // A SYNTAX failure is named as what it is. `read` still falls back to the
    // raw bytes on ANY error from `outline`, and `notebook_edit` turns this one
    // into a message carrying the line and column.
    try testing.expectError(error.NotebookSyntax, outline(testing.io, fixture_path, arena));
    // Parses fine but has no `cells`: a different problem with no line to point
    // at, so it keeps the old error.
    try writeFixture("{}");
    try testing.expectError(error.NotANotebook, outline(testing.io, fixture_path, arena));
    // A file that is not there keeps its own error: the fallback in `read.zig` is what
    // turns it into the real "no such file", and masking it here as "not a notebook"
    // would send the model looking for a corrupt file instead of a wrong path.
    try testing.expectError(error.FileNotFound, outline(testing.io, "does/not/exist.ipynb", arena));
}
