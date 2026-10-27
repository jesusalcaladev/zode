//! The MCP wire: JSON-RPC 2.0 over stdio, and the slice of the protocol zode uses.
//!
//! Pure on purpose. What always breaks in an MCP client is not the transport:
//! it is the SHAPES (a tool list that is not `tools`, a result whose content is
//! an array of blocks and not a string, an error that arrives as a JSON-RPC
//! `error` object and not as a tool result), and none of those needs a server
//! to be installed to be tested. So the wire lives here, with no process, no
//! clock and no filesystem, and the tests for it are pure.
//!
//! ## The framing is NOT the LSP framing
//!
//! MCP's stdio transport is **newline-delimited JSON**: one JSON-RPC message
//! per line, and a message must not contain a raw newline. LSP uses
//! `Content-Length` headers instead, so the two cannot share a framer even
//! though they speak the same JSON-RPC dialect. Copying the LSP framer here
//! would be the single most likely way to get this wrong, so it is called out.

const std = @import("std");

/// The protocol revision zode asks for.
///
/// It is a REQUEST and not a demand: the server answers with the revision it
/// speaks, and zode keeps going. The two methods used here (`tools/list` and
/// `tools/call`) have been stable since the first revision, so a server that
/// answers with an older one is still usable.
pub const requested_version = "2025-06-18";

/// The methods zode uses.
pub const method_initialize = "initialize";
pub const method_initialized = "notifications/initialized";
pub const method_tools_list = "tools/list";
pub const method_tools_call = "tools/call";

/// The JSON-RPC error code for "I do not implement this method".
///
/// It is what zode answers to a server that asks IT something (a server may
/// call back: `roots/list`, `sampling/createMessage`). Answering with a null
/// result would tell the server the call succeeded, which is a lie; the
/// protocol's own code for "no such method" is the honest one.
pub const method_not_found: i64 = -32601;

/// One tool, as the server published it.
pub const Tool = struct {
    /// The tool's name, as the server spells it.
    name: []const u8,
    /// The one-line description the server gave. Empty is legal.
    description: []const u8,
    /// The JSON Schema of its arguments, verbatim, as JSON text.
    ///
    /// Verbatim because the model is going to READ this and build a call out of
    /// it: re-serializing it through a typed struct would drop the parts of
    /// JSON Schema that do not fit any struct (`oneOf`, `patternProperties`,
    /// `additionalProperties`), and a schema with a hole in it is a schema the
    /// model gets wrong.
    schema: []const u8,
};

/// A JSON-RPC error, as the server sent it.
pub const Error = struct {
    code: i64 = 0,
    message: []const u8 = "",
};

/// One message off the wire.
pub const Message = struct {
    /// The request id, when the message is a response.
    id: ?i64 = null,
    /// The method, when the message is a request or a notification.
    method: ?[]const u8 = null,
    /// The result, when the message is a successful response.
    result: ?std.json.Value = null,
    /// The error, when the message is a failed response.
    /// The JSON-RPC error, when the message is a failed response.
    ///
    /// It is NOT named `error`: that is a keyword, and `msg.error` does not
    /// compile without escaping it, which is a trap for every reader.
    failure: ?Error = null,

    /// Is this a message the SERVER sent us to do something?
    ///
    /// A server may ask the client for roots or for a sampling completion. zode
    /// implements neither, and it has to ANSWER: a server waiting for a reply
    /// that never comes is a server waiting forever.
    pub fn isServerRequest(self: Message) bool {
        return self.method != null and self.id != null;
    }
};

/// Writes `s` as a JSON string (quotes included) with the escaping RFC 8259
/// asks for.
///
/// Bytes >= 0x80 pass through: the wire is UTF-8 and re-encoding them as
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

/// A JSON-RPC request, as one line (the newline included).
///
/// The id is a number and not a string: the spec allows both, and numbers are
/// what every server implementation I have read parses without a second code
/// path.
pub fn requestLine(
    arena: std.mem.Allocator,
    id: i64,
    method: []const u8,
    params_json: []const u8,
) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    try aw.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":", .{id});
    try writeJsonString(&aw.writer, method);
    try aw.writer.writeAll(",\"params\":");
    try aw.writer.writeAll(params_json);
    try aw.writer.writeAll("}\n");
    return aw.toArrayList().items;
}

/// A JSON-RPC notification, as one line.
///
/// A notification has no id and gets no answer: that is the whole difference
/// from a request, and getting it wrong makes the server wait for a reply that
/// was never promised.
pub fn notificationLine(
    arena: std.mem.Allocator,
    method: []const u8,
    params_json: []const u8,
) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    try aw.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":");
    try writeJsonString(&aw.writer, method);
    try aw.writer.writeAll(",\"params\":");
    try aw.writer.writeAll(params_json);
    try aw.writer.writeAll("}\n");
    return aw.toArrayList().items;
}

/// The `params` of the `initialize` request.
pub fn initializeParams(arena: std.mem.Allocator) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    try aw.writer.print(
        "{{\"protocolVersion\":\"{s}\",\"capabilities\":{{}},\"clientInfo\":{{\"name\":\"zode\",\"version\":\"1.0\"}}}}",
        .{requested_version},
    );
    return aw.toArrayList().items;
}

/// The `params` of a `tools/call` request.
pub fn toolsCallParams(arena: std.mem.Allocator, name: []const u8, arguments_json: []const u8) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    try aw.writer.writeAll("{\"name\":");
    try writeJsonString(&aw.writer, name);
    try aw.writer.writeAll(",\"arguments\":");
    try aw.writer.writeAll(arguments_json);
    try aw.writer.writeAll("}");
    return aw.toArrayList().items;
}

/// Parses one line of the wire into a message.
pub fn parseMessage(arena: std.mem.Allocator, line: []const u8) !Message {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch
        return error.BadJson;
    if (v != .object) return error.BadJson;
    const obj = v.object;

    var m = Message{};
    if (obj.get("id")) |idv| {
        if (idv == .integer) {
            m.id = idv.integer;
        } else if (idv == .string) {
            // The spec allows a string id. A server that sends one is not broken,
            // and refusing to answer it would hang the request.
            m.id = std.fmt.parseInt(i64, idv.string, 10) catch -1;
        }
    }
    if (obj.get("method")) |mv| {
        if (mv == .string) m.method = mv.string;
    }
    if (obj.get("result")) |rv| m.result = rv;
    if (obj.get("error")) |ev| {
        if (ev == .object) {
            var e = Error{};
            if (ev.object.get("code")) |cv| {
                if (cv == .integer) e.code = cv.integer;
            }
            if (ev.object.get("message")) |sv| {
                if (sv == .string) e.message = sv.string;
            }
            m.failure = e;
        }
    }
    return m;
}

/// The `tools/list` result: the tools and the cursor for the next page.
pub const ToolPage = struct {
    tools: []Tool = &.{},
    /// The cursor for the next page, when the server has more.
    next_cursor: ?[]const u8 = null,
};

/// Reads a `tools/list` result.
pub fn parseToolPage(arena: std.mem.Allocator, result: std.json.Value) !ToolPage {
    if (result != .object) return error.BadResult;
    const obj = result.object;

    var out: std.ArrayList(Tool) = .empty;
    if (obj.get("tools")) |tv| {
        if (tv == .array) {
            for (tv.array.items) |item| {
                if (item != .object) continue;
                const name_v = item.object.get("name") orelse continue;
                if (name_v != .string or name_v.string.len == 0) continue;
                const desc_v = item.object.get("description");
                const desc: []const u8 = if (desc_v) |d| (if (d == .string) d.string else "") else "";

                // The schema is kept as the JSON TEXT the server sent, and the
                // only way to get it out of a parsed value is to serialize it
                // again. The text is what the model reads, so it is what matters.
                const schema_v = item.object.get("inputSchema");
                const schema: []const u8 = if (schema_v) |sv| blk: {
                    if (sv == .null) break :blk "{\"type\":\"object\"}";
                    const txt = std.json.Stringify.valueAlloc(arena, sv, .{}) catch break :blk "{\"type\":\"object\"}";
                    break :blk txt;
                } else "{\"type\":\"object\"}";

                try out.append(arena, .{
                    .name = try arena.dupe(u8, name_v.string),
                    .description = try arena.dupe(u8, desc),
                    .schema = try arena.dupe(u8, schema),
                });
            }
        }
    }

    var cursor: ?[]const u8 = null;
    if (obj.get("nextCursor")) |cv| {
        if (cv == .string and cv.string.len > 0) cursor = try arena.dupe(u8, cv.string);
    }

    return .{ .tools = out.items, .next_cursor = cursor };
}

/// The result of a `tools/call`.
pub const CallResult = struct {
    /// The text the tool produced, with the non-text blocks described.
    text: []const u8 = "",
    /// The server said the call FAILED (`isError: true`).
    ///
    /// It is not an exception: the call went through and the tool decided it
    /// could not do it. The text says so.
    is_error: bool = false,
};

/// Reads a `tools/call` result.
pub fn parseCallResult(arena: std.mem.Allocator, result: std.json.Value) !CallResult {
    if (result != .object) return error.BadResult;
    const obj = result.object;

    var is_error = false;
    if (obj.get("isError")) |ev| {
        if (ev == .bool) is_error = ev.bool;
    }

    var out: std.ArrayList(u8) = .empty;
    if (obj.get("content")) |cv| {
        if (cv == .array) {
            for (cv.array.items) |block| {
                if (block != .object) continue;
                const type_v = block.object.get("type");
                const kind: []const u8 = if (type_v) |tv| (if (tv == .string) tv.string else "") else "";
                if (std.mem.eql(u8, kind, "text")) {
                    if (block.object.get("text")) |tv| {
                        if (tv == .string and tv.string.len > 0) {
                            if (out.items.len > 0) try out.append(arena, '\n');
                            try out.appendSlice(arena, tv.string);
                        }
                    }
                    continue;
                }
                // The other kinds are described, not dropped: a tool that
                // returned a picture and got silence back is a tool the model
                // cannot tell from one that returned nothing.
                if (std.mem.eql(u8, kind, "image")) {
                    const mime_v = block.object.get("mimeType");
                    const mime: []const u8 = if (mime_v) |m| (if (m == .string) m.string else "image") else "image";
                    try out.appendSlice(arena, "[image: ");
                    try out.appendSlice(arena, mime);
                    try out.append(arena, ']');
                    continue;
                }
                if (std.mem.eql(u8, kind, "audio")) {
                    try out.appendSlice(arena, "[audio]");
                    continue;
                }
                if (std.mem.eql(u8, kind, "resource")) {
                    const resource_v = block.object.get("resource");
                    if (resource_v) |rv| {
                        if (rv == .object) {
                            if (rv.object.get("text")) |tv| {
                                if (tv == .string and tv.string.len > 0) {
                                    if (out.items.len > 0) try out.append(arena, '\n');
                                    try out.appendSlice(arena, tv.string);
                                    continue;
                                }
                            }
                            const uri_v = rv.object.get("uri");
                            if (uri_v) |u| {
                                if (u == .string and u.string.len > 0) {
                                    try out.appendSlice(arena, "[resource: ");
                                    try out.appendSlice(arena, u.string);
                                    try out.append(arena, ']');
                                    continue;
                                }
                            }
                        }
                    }
                    try out.appendSlice(arena, "[resource]");
                    continue;
                }
                try out.appendSlice(arena, "[content]");
            }
        }
    }

    return .{ .text = out.items, .is_error = is_error };
}

// ── tests ────────────────────────────────────────────────────────────────

const t = std.testing;

test "the request is one JSON-RPC line with a numeric id" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const line = try requestLine(a, 7, method_tools_list, "{}");
    try t.expect(std.mem.endsWith(u8, line, "\n"));
    // ONE line: a newline inside the message would split it in two.
    try t.expect(std.mem.count(u8, line, "\n") == 1);

    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
    try t.expect(v == .object);
    try t.expectEqualStrings("2.0", v.object.get("jsonrpc").?.string);
    try t.expectEqual(@as(i64, 7), v.object.get("id").?.integer);
    try t.expectEqualStrings("tools/list", v.object.get("method").?.string);
}

test "a notification has no id: that is what makes it a notification" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const line = try notificationLine(a, method_initialized, "{}");
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
    try t.expect(v.object.get("id") == null);
    try t.expectEqualStrings("notifications/initialized", v.object.get("method").?.string);
}

test "a method with a quote in it is escaped, not injected" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const line = try requestLine(a, 1, "we\"ird", "{}");
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
    try t.expectEqualStrings("we\"ird", v.object.get("method").?.string);
}

test "a message is classified: response, request, notification" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const resp = try parseMessage(a, "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"ok\":true}}");
    try t.expectEqual(@as(?i64, 3), resp.id);
    try t.expect(resp.result != null);
    try t.expect(resp.failure == null);
    try t.expect(!resp.isServerRequest());

    const req = try parseMessage(a, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"roots/list\"}");
    try t.expect(req.isServerRequest());
    try t.expectEqualStrings("roots/list", req.method.?);

    const note = try parseMessage(a, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\"}");
    try t.expect(!note.isServerRequest());
    try t.expect(note.id == null);
}

test "a JSON-RPC error arrives as an error, not as a result" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const m = try parseMessage(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"no such method\"}}");
    try t.expect(m.failure != null);
    try t.expectEqual(@as(i64, -32601), m.failure.?.code);
    try t.expectEqualStrings("no such method", m.failure.?.message);
    try t.expect(m.result == null);
}

test "the tool list is read, and a tool without a schema still has one" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const result = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"tools":[
        \\  {"name":"create_issue","description":"Create an issue","inputSchema":{"type":"object","properties":{"title":{"type":"string"}},"required":["title"]}},
        \\  {"name":"ping"}
        \\]}
    , .{});
    const page = try parseToolPage(a, result);
    try t.expectEqual(@as(usize, 2), page.tools.len);
    try t.expectEqualStrings("create_issue", page.tools[0].name);
    try t.expectEqualStrings("Create an issue", page.tools[0].description);
    try t.expect(std.mem.indexOf(u8, page.tools[0].schema, "\"title\"") != null);
    // A tool with no schema gets the empty object, NOT an empty string: an empty
    // schema is not valid JSON and the model would read it as garbage.
    try t.expectEqualStrings("{\"type\":\"object\"}", page.tools[1].schema);
}

test "a paginated tool list carries the cursor" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const result = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"tools":[{"name":"a"}],"nextCursor":"page2"}
    , .{});
    const page = try parseToolPage(a, result);
    try t.expectEqualStrings("page2", page.next_cursor.?);
}

test "a call result is the text of its text blocks" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const result = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"content":[{"type":"text","text":"first"},{"type":"text","text":"second"}]}
    , .{});
    const r = try parseCallResult(a, result);
    try t.expect(!r.is_error);
    try t.expectEqualStrings("first\nsecond", r.text);
}

test "a call that failed says so, and a non-text block is described" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const result = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"content":[{"type":"text","text":"nope"},{"type":"image","mimeType":"image/png"}],"isError":true}
    , .{});
    const r = try parseCallResult(a, result);
    try t.expect(r.is_error);
    try t.expect(std.mem.indexOf(u8, r.text, "nope") != null);
    try t.expect(std.mem.indexOf(u8, r.text, "[image: image/png]") != null);
}

test "a resource block with text gives the text, one without gives the uri" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const with_text = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"content":[{"type":"resource","resource":{"uri":"file:///x","text":"body"}}]}
    , .{});
    try t.expectEqualStrings("body", (try parseCallResult(a, with_text)).text);

    const with_uri = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"content":[{"type":"resource","resource":{"uri":"file:///x"}}]}
    , .{});
    try t.expectEqualStrings("[resource: file:///x]", (try parseCallResult(a, with_uri)).text);
}
