//! ACP (Agent Client Protocol) v1 - JSON-RPC 2.0 helpers over NDJSON stdio.
//!
//! Local agents use stdio: one UTF-8 JSON-RPC message per line (`\n` delimited),
//! no embedded newlines in messages. This module is pure/testable where possible.

const std = @import("std");

pub const protocol_version: i64 = 1;

pub const ErrorCode = struct {
    pub const parse_error: i64 = -32700;
    pub const invalid_request: i64 = -32600;
    pub const method_not_found: i64 = -32601;
    pub const invalid_params: i64 = -32602;
    pub const internal_error: i64 = -32603;
    pub const auth_required: i64 = -32000;
    pub const resource_not_found: i64 = -32002; // session not found / unknown session
    pub const cancelled: i64 = -32800;
};

pub const RequestId = union(enum) {
    null_id,
    integer: i64,
    string: []const u8,

    pub fn eql(a: RequestId, b: RequestId) bool {
        return switch (a) {
            .null_id => b == .null_id,
            .integer => |av| switch (b) {
                .integer => |bv| av == bv,
                else => false,
            },
            .string => |av| switch (b) {
                .string => |bv| std.mem.eql(u8, av, bv),
                else => false,
            },
        };
    }

    pub fn fromValue(v: std.json.Value) ?RequestId {
        return switch (v) {
            .null => .null_id,
            .integer => |i| .{ .integer = i },
            .string => |s| .{ .string = s },
            else => null,
        };
    }

    pub fn writeJson(self: RequestId, w: *std.Io.Writer) !void {
        switch (self) {
            .null_id => try w.writeAll("null"),
            .integer => |i| try w.print("{d}", .{i}),
            .string => |s| try writeJsonString(w, s),
        }
    }
};

pub const Incoming = struct {
    id: ?RequestId = null,
    method: ?[]const u8 = null,
    params: ?std.json.Value = null,
    result: ?std.json.Value = null,
    has_error: bool = false,
    error_code: i64 = 0,
    error_message: []const u8 = "",

    pub fn isRequest(self: Incoming) bool {
        return self.id != null and self.method != null;
    }
    pub fn isNotification(self: Incoming) bool {
        return self.id == null and self.method != null;
    }
    pub fn isResponse(self: Incoming) bool {
        return self.id != null and self.method == null;
    }
};

pub fn parseLine(arena: std.mem.Allocator, line: []const u8) !Incoming {
    const trimmed = std.mem.trimEnd(u8, line, "\r\n");
    if (trimmed.len == 0) return error.Empty;
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, trimmed, .{}) catch return error.BadJson;
    if (v != .object) return error.BadMessage;
    const obj = v.object;
    var msg: Incoming = .{};
    if (obj.get("id")) |idv| msg.id = RequestId.fromValue(idv);
    if (obj.get("method")) |mv| if (mv == .string) {
        msg.method = mv.string;
    };
    if (obj.get("params")) |pv| msg.params = pv;
    if (obj.get("result")) |rv| msg.result = rv;
    if (obj.get("error")) |ev| {
        msg.has_error = true;
        if (ev == .object) {
            if (ev.object.get("code")) |cv| if (cv == .integer) {
                msg.error_code = cv.integer;
            };
            if (ev.object.get("message")) |mv| if (mv == .string) {
                msg.error_message = mv.string;
            };
        }
    }
    return msg;
}

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

/// Writes a JSON-RPC response with raw JSON `result_json` (already serialized).
pub fn writeResponse(arena: std.mem.Allocator, id: RequestId, result_json: []const u8) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    try aw.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try id.writeJson(&aw.writer);
    try aw.writer.writeAll(",\"result\":");
    try aw.writer.writeAll(result_json);
    try aw.writer.writeAll("}\n");
    return aw.toArrayList().items;
}

pub fn writeError(arena: std.mem.Allocator, id: RequestId, code: i64, message: []const u8) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    try aw.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try id.writeJson(&aw.writer);
    try aw.writer.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
    try writeJsonString(&aw.writer, message);
    try aw.writer.writeAll("}}\n");
    return aw.toArrayList().items;
}

pub fn writeNotification(arena: std.mem.Allocator, method: []const u8, params_json: []const u8) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    try aw.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":");
    try writeJsonString(&aw.writer, method);
    try aw.writer.writeAll(",\"params\":");
    try aw.writer.writeAll(params_json);
    try aw.writer.writeAll("}\n");
    return aw.toArrayList().items;
}

pub fn writeRequest(arena: std.mem.Allocator, id: RequestId, method: []const u8, params_json: []const u8) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    try aw.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try id.writeJson(&aw.writer);
    try aw.writer.writeAll(",\"method\":");
    try writeJsonString(&aw.writer, method);
    try aw.writer.writeAll(",\"params\":");
    try aw.writer.writeAll(params_json);
    try aw.writer.writeAll("}\n");
    return aw.toArrayList().items;
}

fn getStr(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn getObj(v: ?std.json.Value) ?std.json.ObjectMap {
    const vv = v orelse return null;
    return if (vv == .object) vv.object else null;
}

pub fn paramStr(params: ?std.json.Value, key: []const u8) ?[]const u8 {
    const o = getObj(params) orelse return null;
    return getStr(o, key);
}

pub fn paramInt(params: ?std.json.Value, key: []const u8) ?i64 {
    const o = getObj(params) orelse return null;
    const v = o.get(key) orelse return null;
    return if (v == .integer) v.integer else null;
}

pub fn paramBool(params: ?std.json.Value, key: []const u8) ?bool {
    const o = getObj(params) orelse return null;
    const v = o.get(key) orelse return null;
    return if (v == .bool) v.bool else null;
}

pub fn paramVal(params: ?std.json.Value, key: []const u8) ?std.json.Value {
    const o = getObj(params) orelse return null;
    return o.get(key);
}

const t = std.testing;

test "acp protocol: parses request/notification/response" {
    var astate = std.heap.ArenaAllocator.init(t.allocator);
    defer astate.deinit();
    const a = astate.allocator();
    const req = try parseLine(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":1}}\n");
    try t.expect(req.isRequest());
    try t.expectEqualStrings("initialize", req.method.?);
    const note = try parseLine(a, "{\"jsonrpc\":\"2.0\",\"method\":\"session/cancel\",\"params\":{\"sessionId\":\"s\"}}\n");
    try t.expect(note.isNotification());
    const resp = try parseLine(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n");
    try t.expect(resp.isResponse());
}

test "acp protocol: writes NDJSON lines" {
    var astate = std.heap.ArenaAllocator.init(t.allocator);
    defer astate.deinit();
    const a = astate.allocator();
    const line = try writeResponse(a, .{ .integer = 7 }, "{\"ok\":true}");
    try t.expect(std.mem.endsWith(u8, line, "\n"));
    try t.expect(std.mem.indexOf(u8, line, "\"id\":7") != null);
    try t.expect(std.mem.indexOf(u8, line, "\"result\":{\"ok\":true}") != null);
}