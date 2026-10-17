//! Language Server Protocol: the WIRE, and nothing that touches a process.
//!
//! Everything here is pure on purpose. What always breaks in an LSP client is
//! not the socket: it is the framing (`Content-Length` + `\r\n\r\n`), the
//! `file://` URIs (a space or an accent in a path is enough to get a "no such
//! document" that says nothing), and the 0-based/1-based dance between what an
//! editor shows and what a server expects. None of those needs a language server
//! to be tested, so none of them lives next to one.
//!
//! The transport (a child process) is in `process.zig` and the request state
//! machine in `client.zig`; this file is imported by both and by the formatter.

const std = @import("std");

/// The blank line that closes the header block, as the spec mandates it.
pub const header_end = "\r\n\r\n";

/// Just past the header block, or null when it is not complete yet.
///
/// A bare `\n\n` is accepted as well: the spec says `\r\n`, but a server that
/// was written on the cheap (or a proxy) sends one, and rejecting it turns a
/// working server into "unsupported". Accepting it can never mis-parse a
/// well-formed message, because a bare `\n\n` cannot appear inside a header.
pub fn headerEnd(buf: []const u8) ?usize {
    if (std.mem.indexOf(u8, buf, header_end)) |i| return i + header_end.len;
    if (std.mem.indexOf(u8, buf, "\n\n")) |i| return i + 2;
    return null;
}

/// `Content-Length` out of a header block (case-insensitive), or null.
///
/// The header is returned as a byte count and anything unparsable is null: the
/// caller turns that into "the server sent a message we could not read" instead
/// of allocating `Content-Length: banana`.
pub fn contentLength(header: []const u8) ?usize {
    var lines = std.mem.splitScalar(u8, header, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "Content-Length")) continue;
        const val = std.mem.trim(u8, line[colon + 1 ..], " \t");
        return std.fmt.parseInt(usize, val, 10) catch null;
    }
    return null;
}

/// The exact bytes to write on the wire for one JSON message.
pub fn frame(arena: std.mem.Allocator, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
}

/// Writes `s` as a JSON string (quotes included) with the escaping RFC 8259 asks
/// for. Bytes >= 0x80 pass through: the wire is UTF-8 and re-encoding them as
/// `\u` escapes would be correct but unreadable in a log.
pub fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x08 => try w.writeAll("\\b"),
        0x0c => try w.writeAll("\\f"),
        else => {
            if (c < 0x20) {
                try w.print("\\u{x:0>4}", .{c});
            } else {
                try w.writeByte(c);
            }
        },
    };
    try w.writeByte('"');
}

/// A local path as a `file://` URI, percent-encoding everything outside the
/// RFC 3986 unreserved set (plus `/`, which is the path separator).
///
/// Nothing else will do: a space is not "probably fine", it is a URI that the
/// server will look up as-is and not find. Same for `+`, `#` and the accents of
/// a home directory.
pub fn pathToUri(arena: std.mem.Allocator, abs_path: []const u8) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    try aw.writer.writeAll("file://");
    for (abs_path) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~' or c == '/') {
            try aw.writer.writeByte(c);
        } else {
            try aw.writer.print("%{X:0>2}", .{c});
        }
    }
    return aw.toArrayList().items;
}

/// The path inside a `file://` URI, percent-decoded. For a URI that is not a
/// `file:` one (some servers report `untitled:` or a `jdt:` scheme) the whole
/// string is returned decoded, which is at least greppable.
pub fn uriToPath(arena: std.mem.Allocator, uri: []const u8) ![]const u8 {
    const body = if (std.mem.startsWith(u8, uri, "file://")) uri["file://".len..] else uri;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < body.len) {
        if (body[i] == '%' and i + 2 < body.len) {
            const hi = std.fmt.charToDigit(body[i + 1], 16) catch null;
            const lo = std.fmt.charToDigit(body[i + 2], 16) catch null;
            if (hi != null and lo != null) {
                try out.append(arena, @as(u8, hi.?) * 16 + lo.?);
                i += 3;
                continue;
            }
        }
        try out.append(arena, body[i]);
        i += 1;
    }
    return out.items;
}

/// LSP positions are 0-based and count UTF-16 code units. What an editor shows
/// is 1-based, and the count is the same for anything in the BMP — which is why
/// every tool that sends `character: col - 1` works until it meets an emoji.
pub const Position = struct { line: u32, character: u32 };

/// Where a symbol was found when the caller did not give a column.
pub const SymbolMatch = union(enum) {
    none,
    /// Exactly one whole-word occurrence.
    one: Position,
    /// Several. The 1-based lines, capped, so the tool can say "tell me which".
    many: []const u32,
};

const is_ident_byte = struct {
    fn f(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
    }
}.f;

/// Finds a whole-word occurrence of `symbol` in `content`.
///
/// This is the improvement over requiring line+column from the model: counting
/// columns is where a model gets it wrong, and a wrong column makes
/// `textDocument/hover` answer about the whitespace to the left of the symbol
/// rather than about the symbol. With several hits it refuses and names the
/// lines instead of silently picking the first, which would answer about a
/// different definition and look right.
pub fn findSymbol(arena: std.mem.Allocator, content: []const u8, symbol: []const u8) !SymbolMatch {
    if (symbol.len == 0) return .none;
    var offsets: std.ArrayList(usize) = .empty;
    var i: usize = 0;
    while (i + symbol.len <= content.len) {
        const hit = std.mem.indexOfPos(u8, content, i, symbol) orelse break;
        const left_ok = hit == 0 or !is_ident_byte(content[hit - 1]);
        const end = hit + symbol.len;
        const right_ok = end >= content.len or !is_ident_byte(content[end]);
        if (left_ok and right_ok) try offsets.append(arena, hit);
        i = hit + 1;
    }
    if (offsets.items.len == 0) return .none;
    if (offsets.items.len == 1) return .{ .one = byteOffsetToPosition(content, offsets.items[0]) };
    var lines: std.ArrayList(u32) = .empty;
    for (offsets.items) |off| {
        if (lines.items.len >= 12) break;
        try lines.append(arena, byteOffsetToPosition(content, off).line + 1);
    }
    return .{ .many = lines.items };
}

/// Turns a byte offset into an LSP position: 0-based line, UTF-16 column.
pub fn byteOffsetToPosition(content: []const u8, offset: usize) Position {
    const clamped = @min(offset, content.len);
    var line: u32 = 0;
    var line_start: usize = 0;
    for (content[0..clamped], 0..) |c, i| {
        if (c == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    return .{ .line = line, .character = utf16Len(content[line_start..clamped]) };
}

/// UTF-16 code units in a UTF-8 slice, which is what `character` counts.
pub fn utf16Len(s: []const u8) u32 {
    var n: u32 = 0;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            i += 1;
            n += 1;
            continue;
        };
        if (i + len > s.len) {
            n += 1;
            break;
        }
        const cp = std.unicode.utf8Decode(s[i .. i + len]) catch {
            i += 1;
            n += 1;
            continue;
        };
        n += if (cp > 0xFFFF) 2 else 1;
        i += len;
    }
    return n;
}

/// The operations the `lsp` tool exposes, and the LSP method each maps to.
///
/// `incomingCalls`/`outgoingCalls` are two round trips on the wire
/// (`textDocument/prepareCallHierarchy` first) and that is not hidden from the
/// caller: the tool does both and reports the item it followed.
pub const Operation = enum {
    goToDefinition,
    findReferences,
    hover,
    documentSymbol,
    workspaceSymbol,
    goToImplementation,
    prepareCallHierarchy,
    incomingCalls,
    outgoingCalls,

    pub fn parse(s: []const u8) ?Operation {
        inline for (std.meta.fields(Operation)) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }

    /// The `textDocument/*` method, or null for the two that are not.
    pub fn method(self: Operation) ?[]const u8 {
        return switch (self) {
            .goToDefinition => "textDocument/definition",
            .findReferences => "textDocument/references",
            .hover => "textDocument/hover",
            .documentSymbol => "textDocument/documentSymbol",
            .goToImplementation => "textDocument/implementation",
            .prepareCallHierarchy, .incomingCalls, .outgoingCalls => "textDocument/prepareCallHierarchy",
            .workspaceSymbol => null,
        };
    }

    /// Does this operation need a position inside a file?
    ///
    /// `documentSymbol` needs the file but not a position (it lists the whole
    /// document) and `workspaceSymbol` needs neither: the search is by name
    /// across the workspace.
    pub fn needsPosition(self: Operation) bool {
        return switch (self) {
            .documentSymbol, .workspaceSymbol => false,
            else => true,
        };
    }

    /// A human label for the result header (`3 definitions:`).
    pub fn label(self: Operation) []const u8 {
        return switch (self) {
            .goToDefinition => "definition",
            .findReferences => "reference",
            .hover => "hover",
            .documentSymbol => "symbol",
            .workspaceSymbol => "workspace symbol",
            .goToImplementation => "implementation",
            .prepareCallHierarchy => "call hierarchy item",
            .incomingCalls => "incoming call",
            .outgoingCalls => "outgoing call",
        };
    }
};

test "headerEnd finds the blank line past the headers" {
    const msg = "Content-Length: 2\r\n\r\n{}";
    try std.testing.expectEqual(@as(?usize, 21), headerEnd(msg));
    try std.testing.expect(headerEnd("Content-Length: 2\r\n") == null);
    // A cheap server that sends `\n\n` is still understood.
    try std.testing.expectEqual(@as(?usize, 6), headerEnd("A: 1\n\n{}"));
}

test "contentLength is case-insensitive and survives other headers" {
    try std.testing.expectEqual(@as(?usize, 42), contentLength("Content-Type: application/vscode-jsonrpc\r\ncontent-length: 42\r\n\r\n"));
    try std.testing.expect(contentLength("Content-Length: banana") == null);
    try std.testing.expect(contentLength("X: 1") == null);
}

test "pathToUri escapes what a server would otherwise not find" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("file:///home/a/b.zig", try pathToUri(arena, "/home/a/b.zig"));
    try std.testing.expectEqualStrings("file:///home/a%20b/c%2Bd.zig", try pathToUri(arena, "/home/a b/c+d.zig"));
    // An accent is UTF-8 on the wire and must be percent-encoded byte by byte.
    try std.testing.expectEqualStrings("file:///tmp/%C3%B1.zig", try pathToUri(arena, "/tmp/\u{00f1}.zig"));
    // Round trip.
    const back = try uriToPath(arena, try pathToUri(arena, "/tmp/a b/c+d.zig"));
    try std.testing.expectEqualStrings("/tmp/a b/c+d.zig", back);
}

test "byteOffsetToPosition counts lines and UTF-16 columns" {
    const content = "ab\ncd\u{1F600}e\n";
    // Offset 0 -> line 0, col 0.
    try std.testing.expectEqual(Position{ .line = 0, .character = 0 }, byteOffsetToPosition(content, 0));
    // Start of line 1 ("cd..."): line 1, col 0.
    try std.testing.expectEqual(Position{ .line = 1, .character = 0 }, byteOffsetToPosition(content, 3));
    // After the emoji: the emoji is 4 UTF-8 bytes but 2 UTF-16 units.
    try std.testing.expectEqual(Position{ .line = 1, .character = 4 }, byteOffsetToPosition(content, 9));
}

test "findSymbol: one hit, many hits, and a substring that is not a word" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const one = try findSymbol(arena, "fn main() void {}\n", "main");
    try std.testing.expectEqual(Position{ .line = 0, .character = 3 }, one.one);

    const many = try findSymbol(arena, "x = 1;\nx = 2;\n", "x");
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, many.many);

    // `local` contains `cal` but is not a word.
    const none = try findSymbol(arena, "local = 1;\n", "cal");
    try std.testing.expect(none == .none);
    const whole = try findSymbol(arena, "local = 1;\ncal();\n", "cal");
    try std.testing.expectEqual(Position{ .line = 1, .character = 0 }, whole.one);
}

test "Operation parses exactly the nine names" {
    try std.testing.expectEqual(Operation.goToDefinition, Operation.parse("goToDefinition").?);
    try std.testing.expectEqual(Operation.outgoingCalls, Operation.parse("outgoingCalls").?);
    try std.testing.expect(Operation.parse("goToDefinitionx") == null);
    try std.testing.expect(Operation.parse("") == null);
    // A file is always needed to pick the language; a POSITION is not needed to
    // list a document's symbols or to search the workspace by name.
    try std.testing.expect(!Operation.documentSymbol.needsPosition());
    try std.testing.expect(!Operation.workspaceSymbol.needsPosition());
    try std.testing.expect(Operation.hover.needsPosition());
    try std.testing.expect(Operation.findReferences.needsPosition());
}
