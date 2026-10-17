//! The `lsp` tool: ask the language server the questions a compiler can answer
//! and grep cannot.
//!
//! `refs` guesses at a symbol's declaration from its shape and gets it wrong on
//! macros, generics and overloads; `grep` sees text and counts a name in a
//! comment as a use. A language server knows, and the whole value of this tool is
//! that it is right.
//!
//! Three things make it usable by a model rather than a chore:
//!
//! - **`symbol`, not a column.** Counting columns is where a model gets it wrong,
//!   and a column off by one makes `textDocument/hover` answer about the
//!   whitespace to the left of the symbol. The position is found from the name.
//! - **`path:line:col` with the source line beside it.** A raw `{uri, range}` is
//!   worse than `grep`.
//! - **It says why it could not answer.** A missing server, an unknown extension
//!   and a server that never replied are three different problems and the model
//!   gets a different sentence for each, with the fallback tool named.
//!
//! Permission: none. The command that gets spawned is fixed by the table in
//! `lsp/servers.zig` and is never chosen by the model, so there is no argument a
//! model could put an obligation in — the same reason `read` asks nothing.

const std = @import("std");
const common = @import("common.zig");
const manager = @import("../lsp/manager.zig");
const protocol = @import("../lsp/protocol.zig");
const format = @import("../lsp/format.zig");
const client = @import("../lsp/client.zig");
const servers = @import("../lsp/servers.zig");
const sleep = @import("../lib/sleep.zig");

const Op = protocol.Operation;

/// The one error worth retrying: the server's own state changed while it was
/// answering (an edit landed, or its index moved under it).
const error_content_modified = -32801;
const max_attempts: usize = 3;
const retry_delays_ms = [_]u64{ 500, 1000, 2000 };

/// A file bigger than this is not sent to a server (see `client.max_doc_bytes`).
const max_source_bytes = client.max_doc_bytes;

pub const operations_help =
    "Valid operations: goToDefinition, findReferences, hover, documentSymbol, workspaceSymbol, goToImplementation, prepareCallHierarchy, incomingCalls, outgoingCalls.";

pub fn toolLsp(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const op_name = common.getStr(obj, "operation") orelse
        return std.fmt.allocPrint(arena, "the `lsp` call needs `operation`. {s}", .{operations_help});
    const op = Op.parse(op_name) orelse
        return std.fmt.allocPrint(arena, "unknown `operation` \"{s}\". {s}", .{ op_name, operations_help });

    // A file selects the LANGUAGE (which server to talk to), so it is required
    // even for the workspace-wide search: a repository can hold several.
    const rel = common.getStr(obj, "file") orelse
        return std.fmt.allocPrint(arena, "`{s}` needs a `file` (it is what picks the language server).", .{op_name});
    const abs = std.Io.Dir.cwd().realPathFileAlloc(io, rel, arena) catch |e| switch (e) {
        error.FileNotFound => return std.fmt.allocPrint(arena, "no such file: {s}. Find it with `glob` or `list_files`.", .{rel}),
        else => return std.fmt.allocPrint(arena, "could not open {s}: {t}", .{ rel, e }),
    };

    if (!servers.supported(&.{}, abs)) {
        return std.fmt.allocPrint(
            arena,
            "no language server is configured for `{s}` ({s}). Ones that are: {s}. For plain text use `grep` or `read`.",
            .{ rel, std.fs.path.extension(rel), try servers.knownExtensions(arena, &.{}) },
        );
    }

    // The position is resolved BEFORE a server is started, and that order is the
    // point: a `symbol` that appears three times, or not at all, is answered from
    // the file on disk in microseconds, and starting `rust-analyzer` to be told
    // "there is nothing at 1:1" is a second of indexing for nothing.
    var pos: protocol.Position = .{ .line = 0, .character = 0 };
    var resolved_note: []const u8 = "";
    if (op.needsPosition()) {
        const pr = try resolvePosition(io, arena, obj, abs, rel, op_name);
        switch (pr) {
            .text => |msg| return msg,
            .pos => |p| pos = p,
            .found => |f| {
                pos = f.pos;
                resolved_note = try std.fmt.allocPrint(arena, "\"{s}\" at {s}:{d}:{d}\n", .{ f.symbol, rel, f.pos.line + 1, f.pos.character + 1 });
            },
        }
    }

    const query = common.getStr(obj, "query") orelse "";
    if (op == .workspaceSymbol and query.len == 0) {
        return "`workspaceSymbol` needs a `query`: part of a symbol name to search the workspace for.";
    }

    var err_text: manager.ErrText = .{};
    const maybe_client = manager.use(abs, &err_text) catch {
        const why = err_text.slice();
        if (why.len > 0) return std.fmt.allocPrint(arena, "{s}. Fall back to `refs`, `grep` or `read`.", .{why});
        return "could not start a language server for that file. Fall back to `refs`, `grep` or `read`.";
    };
    const c = maybe_client orelse return std.fmt.allocPrint(
        arena,
        "no language server is configured for `{s}` (yet). Ones that are: {s}.",
        .{ rel, try servers.knownExtensions(arena, &.{}) },
    );
    defer manager.done(c);

    const uri = c.ensureOpen(arena, abs) catch |e| switch (e) {
        error.FileTooBig => return std.fmt.allocPrint(
            arena,
            "{s} is bigger than the {d} MB a language server is sent. Search inside it with `grep`.",
            .{ rel, max_source_bytes / (1024 * 1024) },
        ),
        error.FileReadFailed => return std.fmt.allocPrint(arena, "could not read {s} to send it to the server.", .{rel}),
        else => return std.fmt.allocPrint(arena, "could not send {s} to the language server: {t}", .{ rel, e }),
    };

    const body = try runWithRetry(io, arena, c, op, uri, pos, query, "");

    // The resolved position is worth one line: it says WHICH occurrence was
    // asked about, which is the answer the model would otherwise have to guess.
    if (resolved_note.len == 0) return body;
    return std.fmt.allocPrint(arena, "{s}{s}", .{ resolved_note, body });
}

const PosResult = union(enum) {
    pos: protocol.Position,
    found: struct { symbol: []const u8, pos: protocol.Position },
    text: []const u8,
};

/// Reads the source line that the formatter prints beside each `path:line:col`.
///
/// One file is kept: a definition list is two or three locations in the SAME
/// file, and reading the whole file once per location is reading the same bytes
/// three times. `abs_path` comes from the formatter's own arena, so holding on to
/// it for the render is safe. A read that fails gives no snippet, never an error:
/// the location is the answer and the snippet is the courtesy.
const LineReader = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    path: []const u8 = "",
    text: []const u8 = "",

    fn line(ud: ?*anyopaque, abs_path: []const u8, want: u32) ?[]const u8 {
        const self: *LineReader = @ptrCast(@alignCast(ud.?));
        if (!std.mem.eql(u8, self.path, abs_path)) {
            self.text = std.Io.Dir.cwd().readFileAlloc(self.io, abs_path, self.arena, .limited(max_source_bytes)) catch "";
            self.path = abs_path;
        }
        if (self.text.len == 0) return null;
        var i: usize = 0;
        var cur: u32 = 0;
        var start: usize = 0;
        while (true) {
            const nl = std.mem.indexOfScalarPos(u8, self.text, i, '\n');
            const end = nl orelse self.text.len;
            if (cur == want) return std.mem.trimEnd(u8, self.text[start..end], "\r");
            if (nl == null) return null;
            cur += 1;
            i = nl.? + 1;
            start = i;
        }
    }
};

/// The position to ask about: from `symbol` (preferred), or from 1-based
/// `line`/`character`. Never silently defaults to 1:1 — a server asked about
/// column 1 of line 1 answers about something the model did not mean.
fn resolvePosition(
    io: std.Io,
    arena: std.mem.Allocator,
    obj: std.json.ObjectMap,
    abs: []const u8,
    rel: []const u8,
    op_name: []const u8,
) !PosResult {
    if (common.getStr(obj, "symbol")) |sym| {
        if (sym.len == 0) return .{ .text = "`symbol` was empty. Give a name that appears in the file." };
        const content = std.Io.Dir.cwd().readFileAlloc(io, abs, arena, .limited(max_source_bytes)) catch
            return .{ .text = "could not read the file to locate `symbol`." };
        switch (try protocol.findSymbol(arena, content, sym)) {
            .none => return .{ .text = try std.fmt.allocPrint(arena, "\"{s}\" does not appear in {s}. Check the spelling with `grep`.", .{ sym, rel }) },
            .one => |p| return .{ .found = .{ .symbol = sym, .pos = p } },
            .many => |lines| {
                var buf: std.ArrayList(u8) = .empty;
                try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "\"{s}\" appears {d} times in {s} (lines ", .{ sym, lines.len, rel }));
                for (lines, 0..) |l, i| {
                    if (i > 0) try buf.appendSlice(arena, ", ");
                    try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{l}));
                }
                try buf.appendSlice(arena, "). Pass `line` and `character` (1-based) to say which one.");
                return .{ .text = buf.items };
            },
        }
    }
    if (common.getInt(obj, "line")) |line1| {
        const ch1 = common.getInt(obj, "character") orelse 1;
        return .{ .pos = .{ .line = @intCast(@max(0, line1 - 1)), .character = @intCast(@max(0, ch1 - 1)) } };
    }
    return .{ .text = try std.fmt.allocPrint(
        arena,
        "`{s}` needs a position: pass `symbol` (a name in the file — the easy way) or 1-based `line` and `character`.",
        .{op_name},
    ) };
}

fn runWithRetry(
    io: std.Io,
    arena: std.mem.Allocator,
    c: *client.Client,
    op: Op,
    uri: []const u8,
    pos: protocol.Position,
    query: []const u8,
    abs_for_resync: []const u8,
) ![]const u8 {
    _ = abs_for_resync;
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const outcome = attempt_(arena, c, op, uri, pos, query) catch |e| {
            return std.fmt.allocPrint(
                arena,
                "the language server did not answer ({t}). It may still be indexing the project — try again in a moment, or fall back to `refs`.",
                .{e},
            );
        };
        switch (outcome) {
            .result => |v| {
                var lr = LineReader{ .io = io, .arena = arena };
                const ctx = format.Ctx{
                    .arena = arena,
                    .root = manager.workspaceRoot(),
                    .current_uri = uri,
                    .read_line = LineReader.line,
                    .read_ud = @ptrCast(&lr),
                };
                return format.render(ctx, op, v);
            },
            .content_modified => {
                if (attempt + 1 >= max_attempts) {
                    return "the language server kept reporting the file as modified while it answered. Save the file and try again.";
                }
                sleep.nap(retry_delays_ms[@min(attempt, retry_delays_ms.len - 1)]);
            },
            .failed => |f| return std.fmt.allocPrint(
                arena,
                "the language server answered with an error ({d}): {s}",
                .{ f.code, f.message },
            ),
            .no_item => return "no symbol was found at that position, so there is nothing to follow calls from. Check the line with `symbol` or `read`.",
        }
    }
}

const Outcome = union(enum) {
    result: std.json.Value,
    content_modified,
    failed: client.Fail,
    no_item,
};

fn attempt_(
    arena: std.mem.Allocator,
    c: *client.Client,
    op: Op,
    uri: []const u8,
    pos: protocol.Position,
    query: []const u8,
) !Outcome {
    const timeout = manager.requestTimeoutMs();
    switch (op) {
        // Two round trips on the wire, and the tool does both: prepare the
        // hierarchy at the position, then ask the ONE item it returned. Hiding
        // that behind a single verb is what makes the operation usable.
        .incomingCalls, .outgoingCalls => {
            const prep = try c.request(arena, "textDocument/prepareCallHierarchy", try posParams(arena, uri, pos, false), timeout);
            const items = switch (prep) {
                .err => |e| return errOutcome(e),
                .ok => |v| v,
            };
            const item = firstArrayItem(items) orelse return .no_item;
            const item_json = try std.json.Stringify.valueAlloc(arena, item, .{});
            var aw = std.Io.Writer.Allocating.init(arena);
            try aw.writer.writeAll("{\"item\":");
            try aw.writer.writeAll(item_json);
            try aw.writer.writeAll("}");
            const method = if (op == .incomingCalls) "callHierarchy/incomingCalls" else "callHierarchy/outgoingCalls";
            const resp = try c.request(arena, method, aw.toArrayList().items, timeout);
            return switch (resp) {
                .err => |e| errOutcome(e),
                .ok => |v| .{ .result = v },
            };
        },
        .workspaceSymbol => {
            var aw = std.Io.Writer.Allocating.init(arena);
            try aw.writer.writeAll("{\"query\":");
            try protocol.writeJsonString(&aw.writer, query);
            try aw.writer.writeAll("}");
            const resp = try c.request(arena, "workspace/symbol", aw.toArrayList().items, timeout);
            return switch (resp) {
                .err => |e| errOutcome(e),
                .ok => |v| .{ .result = v },
            };
        },
        .documentSymbol => {
            const resp = try c.request(arena, "textDocument/documentSymbol", try docParams(arena, uri), timeout);
            return switch (resp) {
                .err => |e| errOutcome(e),
                .ok => |v| .{ .result = v },
            };
        },
        .goToDefinition, .goToImplementation, .findReferences, .hover => {
            const include_decl = op == .findReferences;
            const resp = try c.request(arena, singleMethod(op), try posParams(arena, uri, pos, include_decl), timeout);
            return switch (resp) {
                .err => |e| errOutcome(e),
                .ok => |v| .{ .result = v },
            };
        },
        .prepareCallHierarchy => {
            const resp = try c.request(arena, "textDocument/prepareCallHierarchy", try posParams(arena, uri, pos, false), timeout);
            return switch (resp) {
                .err => |e| errOutcome(e),
                .ok => |v| .{ .result = v },
            };
        },
    }
}

fn errOutcome(e: client.Fail) Outcome {
    if (e.code == error_content_modified) return .content_modified;
    return .{ .failed = e };
}

fn singleMethod(op: Op) []const u8 {
    return switch (op) {
        .goToDefinition => "textDocument/definition",
        .goToImplementation => "textDocument/implementation",
        .findReferences => "textDocument/references",
        .hover => "textDocument/hover",
        else => unreachable,
    };
}

fn firstArrayItem(v: std.json.Value) ?std.json.Value {
    if (v != .array) return null;
    if (v.array.items.len == 0) return null;
    return v.array.items[0];
}

fn posParams(arena: std.mem.Allocator, uri: []const u8, pos: protocol.Position, include_decl: bool) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    try aw.writer.writeAll("{\"textDocument\":{\"uri\":");
    try protocol.writeJsonString(&aw.writer, uri);
    try aw.writer.writeAll("},\"position\":{\"line\":");
    try aw.writer.print("{d}", .{pos.line});
    try aw.writer.writeAll(",\"character\":");
    try aw.writer.print("{d}", .{pos.character});
    try aw.writer.writeAll("}");
    if (include_decl) try aw.writer.writeAll(",\"context\":{\"includeDeclaration\":true}");
    try aw.writer.writeAll("}");
    return aw.toArrayList().items;
}

fn docParams(arena: std.mem.Allocator, uri: []const u8) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    try aw.writer.writeAll("{\"textDocument\":{\"uri\":");
    try protocol.writeJsonString(&aw.writer, uri);
    try aw.writer.writeAll("}}");
    return aw.toArrayList().items;
}

// ── tests: no server needed for the argument handling ───────────────────

const testing = std.testing;

test "lsp: a missing operation says which ones exist" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const out = try toolLsp(testing.io, try parseObj(arena_state.allocator(), "{}"), arena_state.allocator());
    try testing.expect(std.mem.indexOf(u8, out, "needs `operation`") != null);
    try testing.expect(std.mem.indexOf(u8, out, "goToDefinition") != null);
}

test "lsp: an unknown operation lists the vocabulary instead of failing silently" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const out = try toolLsp(testing.io, try parseObj(arena_state.allocator(), "{\"operation\":\"goto\"}"), arena_state.allocator());
    try testing.expect(std.mem.indexOf(u8, out, "unknown `operation` \"goto\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "findReferences") != null);
}

test "lsp: a missing file is named, not left to the server" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const out = try toolLsp(testing.io, try parseObj(arena_state.allocator(), "{\"operation\":\"goToDefinition\"}"), arena_state.allocator());
    try testing.expect(std.mem.indexOf(u8, out, "needs a `file`") != null);
}

test "lsp: a file that does not exist points at glob, and never spawns anything" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const args = "{\"operation\":\"goToDefinition\",\"file\":\"does/not/exist.zig\",\"symbol\":\"main\"}";
    const out = try toolLsp(testing.io, try parseObj(arena_state.allocator(), args), arena_state.allocator());
    try testing.expect(std.mem.indexOf(u8, out, "no such file") != null);
    try testing.expect(std.mem.indexOf(u8, out, "glob") != null);
}

test "lsp: an extension with no server lists the extensions that have one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "notes.txt", .data = "hello\n" });
    const abs = try tmp.dir.realPathFileAlloc(testing.io, "notes.txt", arena_state.allocator());
    const args = try std.fmt.allocPrint(arena_state.allocator(), "{{\"operation\":\"hover\",\"file\":\"{s}\",\"symbol\":\"hello\"}}", .{abs});
    const out = try toolLsp(testing.io, try parseObj(arena_state.allocator(), args), arena_state.allocator());
    try testing.expect(std.mem.indexOf(u8, out, "no language server is configured") != null);
    // The message names the fallback, not just the failure.
    try testing.expect(std.mem.indexOf(u8, out, "grep") != null);
}

test "lsp: the operation list and the method table agree on every name" {
    // A name in `operations_help` that `Operation.parse` does not know is a
    // documented operation that answers "unknown operation".
    inline for (std.meta.fields(Op)) |f| {
        try testing.expect(std.mem.indexOf(u8, operations_help, f.name) != null);
        try testing.expect(Op.parse(f.name) != null);
    }
}

test "lsp: symbol lookup says WHICH lines when the name is not unique" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.zig", .data = "const x = 1;\nconst y = x;\nconst z = x;\n" });
    const abs = try tmp.dir.realPathFileAlloc(testing.io, "a.zig", a);
    const args = try std.fmt.allocPrint(a, "{{\"operation\":\"hover\",\"file\":\"{s}\",\"symbol\":\"x\"}}", .{abs});
    // The ambiguity is decided from the file on disk, before any server is
    // started, so this is deterministic on a machine without `zls`.
    const out = try toolLsp(testing.io, try parseObj(a, args), a);
    try testing.expect(std.mem.indexOf(u8, out, "appears 3 times") != null);
    try testing.expect(std.mem.indexOf(u8, out, "lines 1, 2, 3") != null);
}

fn parseObj(arena: std.mem.Allocator, json: []const u8) !std.json.ObjectMap {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    if (v != .object) return error.NotAnObject;
    return v.object;
}

test "lsp: a real clangd answers documentSymbol and hover (skipped without clangd)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const src =
        \\static int add(int a, int b) { return a + b; }
        \\int main(void) { return add(1, 2); }
    ;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "hello.c", .data = src });
    const abs = try tmp.dir.realPathFileAlloc(testing.io, "hello.c", testing.allocator);
    defer testing.allocator.free(abs);

    manager.init(testing.allocator, testing.io, null);
    defer manager.shutdown();

    // The skip has to happen HERE, at the spawn: the rest of the test assumes a
    // working server, and a machine without clangd must not see a red line for a
    // tool it can still use on a language it does have.
    var err_text: manager.ErrText = .{};
    const maybe = manager.use(abs, &err_text) catch |e| switch (e) {
        error.ServerNotFound => return error.SkipZigTest,
        else => return e,
    };
    const probe = maybe orelse return error.SkipZigTest;
    manager.done(probe);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const args = try std.fmt.allocPrint(a, "{{\"operation\":\"documentSymbol\",\"file\":\"{s}\"}}", .{abs});
    const out = try toolLsp(testing.io, try parseObj(a, args), a);
    try testing.expect(std.mem.indexOf(u8, out, "add") != null);
    try testing.expect(std.mem.indexOf(u8, out, "main") != null);
    // The path is shortened against the workspace root, so the temp file shows up
    // by name rather than as an absolute path.
    try testing.expect(std.mem.indexOf(u8, out, "hello.c") != null);

    // `hover` on `main`, resolved by NAME: this is the path a model takes, and it
    // is the one that proves `symbol` lands on a real column inside the file.
    // (`add` would be ambiguous here: it appears in the declaration AND the call,
    // and the tool answers that with the line numbers instead of guessing.)
    const hargs = try std.fmt.allocPrint(a, "{{\"operation\":\"hover\",\"file\":\"{s}\",\"symbol\":\"main\"}}", .{abs});
    const hout = try toolLsp(testing.io, try parseObj(a, hargs), a);
    try testing.expect(std.mem.indexOf(u8, hout, "int") != null);
    try testing.expect(std.mem.indexOf(u8, hout, "main") != null);
    // The resolved position rides in front, so the model can see WHICH occurrence.
    try testing.expect(std.mem.indexOf(u8, hout, "\"main\" at ") != null);
}

test "lsp: definition from a call site comes back with the source line beside it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const src =
        \\static int add(int a, int b) { return a + b; }
        \\int main(void) { return add(1, 2); }
    ;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "hello.c", .data = src });
    const abs = try tmp.dir.realPathFileAlloc(testing.io, "hello.c", testing.allocator);
    defer testing.allocator.free(abs);

    manager.init(testing.allocator, testing.io, null);
    defer manager.shutdown();

    var err_text: manager.ErrText = .{};
    const maybe = manager.use(abs, &err_text) catch |e| switch (e) {
        error.ServerNotFound => return error.SkipZigTest,
        else => return e,
    };
    const probe = maybe orelse return error.SkipZigTest;
    manager.done(probe);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // The call is on line 2; `symbol` would find the declaration on line 1, so
    // this asks by position — the other half of the API.
    const args = try std.fmt.allocPrint(
        a,
        "{{\"operation\":\"goToDefinition\",\"file\":\"{s}\",\"line\":2,\"character\":25}}",
        .{abs},
    );
    const out = try toolLsp(testing.io, try parseObj(a, args), a);
    try testing.expect(std.mem.indexOf(u8, out, "definition") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1:12") != null);
    // The snippet is the point of the formatter: the definition says WHICH line.
    try testing.expect(std.mem.indexOf(u8, out, "static int add") != null);
}
