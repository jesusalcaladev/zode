//! Turns an LSP result into text a model can read, and only that.
//!
//! A language server answers with `{uri, range}` objects whose positions are
//! 0-based and whose paths are `file://` URIs. Handing that to the model
//! unchanged is strictly worse than `grep`: it has to decode the URI, add one to
//! two numbers per hit and still cannot see the line it landed on. So every
//! result goes through here, and what comes out is `path:line:col` (1-based, as
//! an editor shows it) with the source line beside it.
//!
//! This module is pure — the source lines arrive through a callback, so a test
//! can render a fixture with no filesystem and no server.

const std = @import("std");
const protocol = @import("protocol.zig");

/// Output ceiling. The dispatcher truncates at the same order of magnitude, and
/// stopping here means a server that answers with ten thousand symbols does not
/// build a megabyte of text only to have it cut.
pub const max_output = 24 * 1024;

pub const Ctx = struct {
    arena: std.mem.Allocator,
    /// Used to shorten a path that is under it.
    root: []const u8 = "",
    /// The file the operation was asked about. The tree form of
    /// `documentSymbol` carries no URI, so this is the only place its positions
    /// can get a path from.
    current_uri: []const u8 = "",
    /// Returns the source line at a 0-based `line`, or null. `abs_path` is a
    /// decoded filesystem path (not a URI).
    read_line: ?*const fn (ud: ?*anyopaque, abs_path: []const u8, line: u32) ?[]const u8 = null,
    read_ud: ?*anyopaque = null,
};

/// The path inside a `file://` URI, shortened against the root when it is under
/// it. Falls back to the decoded path (never an empty string for a real file).
fn pathFor(ctx: Ctx, uri: []const u8) ![]const u8 {
    if (uri.len == 0) return "";
    const full = try protocol.uriToPath(ctx.arena, uri);
    const root = std.mem.trimEnd(u8, ctx.root, "/");
    if (root.len > 0 and std.mem.startsWith(u8, full, root)) {
        const rest = full[root.len..];
        if (rest.len == 0) return ".";
        if (rest[0] == '/') return rest[1..];
    }
    return full;
}

/// The decoded filesystem path, for the line reader. Never shortened: the reader
/// has to be able to open it.
fn absFor(ctx: Ctx, uri: []const u8) ![]const u8 {
    if (uri.len == 0) return "";
    return protocol.uriToPath(ctx.arena, uri);
}

const R = struct {
    ctx: Ctx,
    out: std.ArrayList(u8) = .empty,
    count: usize = 0,
    truncated: usize = 0,

    fn add(self: *R, text: []const u8) !void {
        if (self.out.items.len + text.len + 1 > max_output) {
            self.truncated += 1;
            return;
        }
        try self.out.appendSlice(self.ctx.arena, text);
        try self.out.append(self.ctx.arena, '\n');
    }

    fn place(self: *R, uri: []const u8, pos: protocol.Position) !void {
        const path = try pathFor(self.ctx, uri);
        if (self.ctx.read_line) |rf| {
            const abs = try absFor(self.ctx, uri);
            if (abs.len > 0) {
                if (rf(self.ctx.read_ud, abs, pos.line)) |src| {
                    const trimmed = std.mem.trim(u8, src, " \t\r\n");
                    if (trimmed.len > 0) {
                        const snippet = trimmed[0..@min(trimmed.len, 160)];
                        try self.add(try std.fmt.allocPrint(self.ctx.arena, "{s}:{d}:{d}  {s}", .{ path, pos.line + 1, pos.character + 1, snippet }));
                        self.count += 1;
                        return;
                    }
                }
            }
        }
        try self.add(try std.fmt.allocPrint(self.ctx.arena, "{s}:{d}:{d}", .{ path, pos.line + 1, pos.character + 1 }));
        self.count += 1;
    }

    /// One diagnostic: where it is, how bad it is and what it says.
    ///
    /// The source line comes AFTER the message, not before it: the message is
    /// what the model has to act on, and a line of code in front of it makes
    /// the model read the code before it reads the problem.
    fn diagnostic(
        self: *R,
        pos: protocol.Position,
        severity: i64,
        message: []const u8,
        source: ?[]const u8,
        code: ?[]const u8,
    ) !void {
        const path = try pathFor(self.ctx, self.ctx.current_uri);
        var line = try std.fmt.allocPrint(self.ctx.arena, "{s}:{d}:{d}  {s}: {s}", .{
            path, pos.line + 1, pos.character + 1, severityName(severity), message,
        });
        if (source) |s| {
            if (s.len > 0) line = try std.fmt.allocPrint(self.ctx.arena, "{s} ({s})", .{ line, s });
        }
        if (code) |c| {
            if (c.len > 0) line = try std.fmt.allocPrint(self.ctx.arena, "{s} [{s}]", .{ line, c });
        }
        if (self.ctx.read_line) |rf| {
            const abs = try absFor(self.ctx, self.ctx.current_uri);
            if (abs.len > 0) {
                if (rf(self.ctx.read_ud, abs, pos.line)) |src| {
                    const trimmed = std.mem.trim(u8, src, " \t\r\n");
                    if (trimmed.len > 0) {
                        const snippet = trimmed[0..@min(trimmed.len, 160)];
                        line = try std.fmt.allocPrint(self.ctx.arena, "{s}\n    {s}", .{ line, snippet });
                    }
                }
            }
        }
        try self.add(line);
        self.count += 1;
    }
};

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn getInt(obj: std.json.ObjectMap, key: []const u8) i64 {
    const v = obj.get(key) orelse return 0;
    return if (v == .integer) v.integer else 0;
}

fn arrayOf(v: std.json.Value) ?[]std.json.Value {
    return if (v == .array) v.array.items else null;
}

fn objOf(v: std.json.Value) ?std.json.ObjectMap {
    return if (v == .object) v.object else null;
}

/// Start of a `range`/`selectionRange` object, as a 0-based position.
fn startOf(v: std.json.Value) ?protocol.Position {
    const obj = objOf(v) orelse return null;
    var range: std.json.Value = v;
    if (obj.get("range")) |r| {
        range = r;
    } else if (obj.get("selectionRange")) |r| {
        range = r;
    }
    const robj = objOf(range) orelse return null;
    const start = robj.get("start") orelse return null;
    const sobj = objOf(start) orelse return null;
    const l = sobj.get("line") orelse return null;
    const c = sobj.get("character") orelse return null;
    if (l != .integer or c != .integer) return null;
    return .{ .line = @intCast(@max(0, l.integer)), .character = @intCast(@max(0, c.integer)) };
}

/// The `uri` of a Location, or the `targetUri` of a LocationLink.
fn locationUri(v: std.json.Value) ?[]const u8 {
    const obj = objOf(v) orelse return null;
    return getStr(obj, "uri") orelse getStr(obj, "targetUri");
}

/// The range of a Location (`range`) or a LocationLink (`targetRange`).
fn locationRange(v: std.json.Value) ?std.json.Value {
    const obj = objOf(v) orelse return null;
    return obj.get("range") orelse obj.get("targetRange") orelse obj.get("targetSelectionRange");
}

pub const symbolKindNames = [_][]const u8{
    "File",        "Module",      "Namespace",  "Package",     "Class",
    "Method",      "Property",    "Field",      "Constructor", "Enum",
    "Interface",   "Function",    "Variable",   "Constant",    "String",
    "Number",      "Boolean",     "Array",      "Object",      "Key",
    "Null",        "EnumMember",  "Struct",     "Event",       "Operator",
    "TypeParameter",
};

/// The severity names of the LSP, in the order the spec numbers them.
const severity_names = [_][]const u8{ "problem", "error", "warning", "information", "hint" };

pub fn severityName(s: i64) []const u8 {
    if (s >= 1 and s <= severity_names.len) return severity_names[@intCast(s)];
    return severity_names[0];
}

pub fn symbolKindName(k: i64) []const u8 {
    if (k >= 1 and k <= symbolKindNames.len) return symbolKindNames[@intCast(k - 1)];
    return "Unknown";
}

fn placeLocation(r: *R, it: std.json.Value) !void {
    const uri = locationUri(it) orelse return;
    const range = locationRange(it) orelse it;
    const pos = startOf(range) orelse protocol.Position{ .line = 0, .character = 0 };
    try r.place(uri, pos);
}

fn renderLocations(r: *R, result: std.json.Value) !void {
    if (arrayOf(result)) |items| {
        for (items) |it| try placeLocation(r, it);
        return;
    }
    // Some servers answer with a single Location instead of a one-element array.
    if (objOf(result) != null) try placeLocation(r, result);
}

fn renderSymbols(r: *R, result: std.json.Value, depth: usize) !void {
    const items = arrayOf(result) orelse return;
    for (items) |it| {
        const obj = objOf(it) orelse continue;
        const name = getStr(obj, "name") orelse "?";
        const kind = getInt(obj, "kind");
        // DocumentSymbol has `range`/`selectionRange` and no URI; the flat
        // SymbolInformation has a `location`. They are told apart per node, not
        // by the operation, because servers answer documentSymbol with both.
        const loc = obj.get("location");
        const uri = if (loc) |l| (locationUri(l) orelse r.ctx.current_uri) else r.ctx.current_uri;
        const pos: ?protocol.Position = if (loc) |l| startOf(l) else startOf(it);
        const indent = "                                        "[0..@min(depth * 2, 40)];
        if (pos) |p| {
            const path = try pathFor(r.ctx, uri);
            if (path.len > 0) {
                try r.add(try std.fmt.allocPrint(r.ctx.arena, "{s}{s} ({s}) {s}:{d}:{d}", .{ indent, name, symbolKindName(kind), path, p.line + 1, p.character + 1 }));
            } else {
                try r.add(try std.fmt.allocPrint(r.ctx.arena, "{s}{s} ({s}) {d}:{d}", .{ indent, name, symbolKindName(kind), p.line + 1, p.character + 1 }));
            }
        } else {
            try r.add(try std.fmt.allocPrint(r.ctx.arena, "{s}{s} ({s})", .{ indent, name, symbolKindName(kind) }));
        }
        r.count += 1;
        if (obj.get("children")) |kids| try renderSymbols(r, kids, depth + 1);
    }
}

fn itemPlace(r: *R, item: std.json.Value, prefix: []const u8) !void {
    const obj = objOf(item) orelse return;
    const name = getStr(obj, "name") orelse "?";
    const kind = getInt(obj, "kind");
    const uri = getStr(obj, "uri") orelse "";
    const pos = startOf(item) orelse protocol.Position{ .line = 0, .character = 0 };
    const path = try pathFor(r.ctx, uri);
    try r.add(try std.fmt.allocPrint(r.ctx.arena, "{s}{s} ({s}) {s}:{d}:{d}", .{
        prefix, name, symbolKindName(kind), path, pos.line + 1, pos.character + 1,
    }));
    r.count += 1;
}

/// `field` is `from` (incoming) or `to` (outgoing). The `fromRanges` of an
/// incoming call are the call sites, in the caller's file, so they are rendered;
/// for an outgoing call they belong to the file that was queried and the result
/// does not carry it, so they are left out rather than pointed at the wrong file.
fn renderCallTargets(r: *R, result: std.json.Value, field: []const u8, with_ranges: bool) !void {
    const items = arrayOf(result) orelse return;
    for (items) |it| {
        const obj = objOf(it) orelse continue;
        const target = obj.get(field) orelse continue;
        try itemPlace(r, target, "");
        if (!with_ranges) continue;
        const uri = getStr(objOf(target).?, "uri") orelse "";
        if (obj.get("fromRanges")) |fr| {
            if (arrayOf(fr)) |ranges| {
                for (ranges) |range| {
                    const pos = startOf(range) orelse continue;
                    try r.place(uri, pos);
                }
            }
        }
    }
}

fn renderWorkspaceSymbols(r: *R, result: std.json.Value) !void {
    const items = arrayOf(result) orelse return;
    for (items) |it| {
        const obj = objOf(it) orelse continue;
        const name = getStr(obj, "name") orelse "?";
        const kind = getInt(obj, "kind");
        const loc = obj.get("location") orelse it;
        const uri = locationUri(loc) orelse getStr(obj, "uri") orelse "";
        const pos = startOf(loc) orelse protocol.Position{ .line = 0, .character = 0 };
        const path = try pathFor(r.ctx, uri);
        if (path.len > 0) {
            try r.add(try std.fmt.allocPrint(r.ctx.arena, "{s} ({s}) {s}:{d}:{d}", .{ name, symbolKindName(kind), path, pos.line + 1, pos.character + 1 }));
        } else {
            try r.add(try std.fmt.allocPrint(r.ctx.arena, "{s} ({s})", .{ name, symbolKindName(kind) }));
        }
        r.count += 1;
    }
}

fn appendMarked(arena: std.mem.Allocator, out: *std.ArrayList(u8), v: std.json.Value) !void {
    switch (v) {
        .string => |s| try out.appendSlice(arena, s),
        .object => |obj| {
            const value = getStr(obj, "value") orelse return;
            if (getStr(obj, "language")) |lang| {
                try out.appendSlice(arena, "```");
                try out.appendSlice(arena, lang);
                try out.append(arena, '\n');
                try out.appendSlice(arena, value);
                try out.appendSlice(arena, "\n```");
            } else {
                try out.appendSlice(arena, value);
            }
        },
        .array => |arr| {
            for (arr.items, 0..) |it, i| {
                if (i > 0) try out.append(arena, '\n');
                try appendMarked(arena, out, it);
            }
        },
        else => {},
    }
}

fn renderHover(arena: std.mem.Allocator, result: std.json.Value) ![]const u8 {
    const obj = objOf(result) orelse return "no hover information";
    const contents = obj.get("contents") orelse return "no hover information";
    var out: std.ArrayList(u8) = .empty;
    try appendMarked(arena, &out, contents);
    const text = std.mem.trim(u8, out.items, " \n\t\r");
    if (text.len == 0) return "no hover information";
    return text;
}

/// Renders the diagnostics a server published for a file.
///
/// The order is the server's: they come in the order the server found them,
/// and a list sorted by severity would be a second opinion about what matters.
pub fn renderDiagnostics(ctx: Ctx, items: std.json.Value) ![]const u8 {
    const arr = arrayOf(items) orelse return "the server published no diagnostics";
    var r = R{ .ctx = ctx };
    for (arr) |it| {
        const obj = objOf(it) orelse continue;
        const severity = getInt(obj, "severity");
        const message = getStr(obj, "message") orelse "(no message)";
        const source = getStr(obj, "source");
        const code = codeOf(ctx.arena, obj);
        const pos = startOf(it) orelse protocol.Position{ .line = 0, .character = 0 };
        try r.diagnostic(pos, severity, message, source, code);
    }
    if (r.count == 0) {
        return "the language server reported no problems in this file";
    }
    if (r.truncated > 0) {
        try r.out.appendSlice(ctx.arena, try std.fmt.allocPrint(ctx.arena, "(+{d} more not shown)\n", .{r.truncated}));
    }
    const plural = if (r.count == 1) "" else "s";
    return std.fmt.allocPrint(ctx.arena, "{d} diagnostic{s}:\n{s}", .{ r.count, plural, r.out.items });
}

/// The `code` of a diagnostic, which can be a string or a number.
fn codeOf(arena: std.mem.Allocator, obj: std.json.ObjectMap) ?[]const u8 {
    const v = obj.get("code") orelse return null;
    return switch (v) {
        .string => |s| if (s.len > 0) s else null,
        .integer => |i| std.fmt.allocPrint(arena, "{d}", .{i}) catch null,
        else => null,
    };
}

/// Renders one operation's result. `result` is the JSON `result` field of the
/// response (already unwrapped from the JSON-RPC envelope).
pub fn render(ctx: Ctx, op: protocol.Operation, result: std.json.Value) ![]const u8 {
    if (op == .hover) return renderHover(ctx.arena, result);
    if (op == .diagnostics) return renderDiagnostics(ctx, result);

    var r = R{ .ctx = ctx };
    switch (op) {
        .goToDefinition, .goToImplementation, .findReferences => try renderLocations(&r, result),
        .documentSymbol => try renderSymbols(&r, result, 0),
        .workspaceSymbol => try renderWorkspaceSymbols(&r, result),
        .prepareCallHierarchy => {
            const items = arrayOf(result) orelse &.{};
            for (items) |it| try itemPlace(&r, it, "");
        },
        .incomingCalls => try renderCallTargets(&r, result, "from", true),
        .outgoingCalls => try renderCallTargets(&r, result, "to", false),
        .hover => unreachable,
        .diagnostics => unreachable,
    }

    if (r.count == 0) {
        return std.fmt.allocPrint(ctx.arena, "no {s} found at that position", .{op.label()});
    }
    if (r.truncated > 0) {
        try r.out.appendSlice(ctx.arena, try std.fmt.allocPrint(ctx.arena, "(+{d} more not shown)\n", .{r.truncated}));
    }
    const plural = if (r.count == 1) "" else "s";
    return std.fmt.allocPrint(ctx.arena, "{d} {s}{s}:\n{s}", .{ r.count, op.label(), plural, r.out.items });
}

// ── tests ───────────────────────────────────────────────────────────────

fn testLine(ud: ?*anyopaque, abs_path: []const u8, line: u32) ?[]const u8 {
    _ = ud;
    _ = abs_path;
    _ = line;
    return "pub fn main() void {";
}

fn testCtx(arena: std.mem.Allocator) Ctx {
    return .{ .arena = arena, .root = "/proj", .current_uri = "file:///proj/src/a.zig", .read_line = testLine };
}

fn parse(arena: std.mem.Allocator, json: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
}

test "format: definitions become path:line:col with the source line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const result = try parse(arena,
        \\[{"uri":"file:///proj/src/a.zig","range":{"start":{"line":11,"character":4},"end":{"line":11,"character":8}}}]
    );
    const out = try render(testCtx(arena), .goToDefinition, result);
    try std.testing.expect(std.mem.indexOf(u8, out, "1 definition:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "src/a.zig:12:5") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn main() void {") != null);
}

test "format: LocationLink targetUri is read, not ignored" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const result = try parse(arena,
        \\[{"targetUri":"file:///proj/b.zig","targetRange":{"start":{"line":2,"character":0},"end":{"line":2,"character":1}},"targetSelectionRange":{"start":{"line":2,"character":0},"end":{"line":2,"character":1}}}]
    );
    const out = try render(testCtx(arena), .goToDefinition, result);
    try std.testing.expect(std.mem.indexOf(u8, out, "b.zig:3:1") != null);
}

test "format: a count that pluralizes and a real empty answer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const two = try parse(arena,
        \\[{"uri":"file:///proj/a.zig","range":{"start":{"line":0,"character":0}}},{"uri":"file:///proj/a.zig","range":{"start":{"line":9,"character":2}}}]
    );
    const out = try render(testCtx(arena), .findReferences, two);
    try std.testing.expect(std.mem.indexOf(u8, out, "2 references:") != null);

    const none = try render(testCtx(arena), .findReferences, .null);
    try std.testing.expect(std.mem.indexOf(u8, none, "no reference found") != null);
}

test "format: documentSymbol renders a tree with kinds" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const result = try parse(arena,
        \\[{"name":"main","kind":12,"range":{"start":{"line":9,"character":0}},"selectionRange":{"start":{"line":9,"character":3}},"children":[{"name":"helper","kind":12,"range":{"start":{"line":11,"character":0}},"selectionRange":{"start":{"line":11,"character":3}}}]}]
    );
    const out = try render(testCtx(arena), .documentSymbol, result);
    try std.testing.expect(std.mem.indexOf(u8, out, "main (Function) src/a.zig:10:1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "  helper (Function)") != null);
}

test "format: hover flattens MarkupContent and MarkedString" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const markup = try parse(arena, "{\"contents\":{\"kind\":\"markdown\",\"value\":\"`fn main() -> void`\\n\\nDocs.\"}}");
    const out = try render(testCtx(arena), .hover, markup);
    try std.testing.expect(std.mem.indexOf(u8, out, "`fn main() -> void`") != null);

    const marked = try parse(arena, "{\"contents\":[{\"language\":\"zig\",\"value\":\"pub fn f()\"}]}");
    const out2 = try render(testCtx(arena), .hover, marked);
    try std.testing.expect(std.mem.indexOf(u8, out2, "```zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, out2, "pub fn f()") != null);

    const empty = try render(testCtx(arena), .hover, .null);
    try std.testing.expectEqualStrings("no hover information", empty);
}

test "format: incomingCalls names the caller and the call site" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const result = try parse(arena,
        \\[{"from":{"name":"caller","kind":12,"uri":"file:///proj/c.zig","range":{"start":{"line":4,"character":0}},"selectionRange":{"start":{"line":4,"character":5}}},"fromRanges":[{"start":{"line":3,"character":2}}]}]
    );
    const out = try render(testCtx(arena), .incomingCalls, result);
    try std.testing.expect(std.mem.indexOf(u8, out, "caller (Function) c.zig:5:1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "c.zig:4:3") != null);
}

test "format: workspaceSymbol uses the location inside each symbol" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const result = try parse(arena,
        \\[{"name":"Server","kind":5,"location":{"uri":"file:///proj/s.zig","range":{"start":{"line":6,"character":0}}}}]
    );
    const out = try render(testCtx(arena), .workspaceSymbol, result);
    try std.testing.expect(std.mem.indexOf(u8, out, "Server (Class) s.zig:7:1") != null);
}

test "format: diagnostics say where they are, how bad they are and what they are" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const items = try parse(arena,
        \\[{"range":{"start":{"line":11,"character":4}},"severity":1,"source":"clangd","code":"err-42","message":"expected ';'"},
        \\ {"range":{"start":{"line":2,"character":0}},"severity":2,"message":"unused variable"}]
    );
    const out = try render(testCtx(arena), .diagnostics, items);
    try std.testing.expect(std.mem.indexOf(u8, out, "2 diagnostics:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "src/a.zig:12:5") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "error: expected ';'") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(clangd)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[err-42]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "warning: unused variable") != null);
    // The line the problem is on comes with it.
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn main() void {") != null);
}

test "format: no diagnostics is an answer, not an empty list" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const none = try parse(arena, "[]");
    const out = try render(testCtx(arena), .diagnostics, none);
    try std.testing.expect(std.mem.indexOf(u8, out, "no problems") != null);
}

test "format: a severity the spec does not have is still a word" {
    try std.testing.expectEqualStrings("error", severityName(1));
    try std.testing.expectEqualStrings("warning", severityName(2));
    try std.testing.expectEqualStrings("hint", severityName(4));
    // An unknown number is not a crash and not a lie about the severity.
    try std.testing.expectEqualStrings("problem", severityName(99));
}
