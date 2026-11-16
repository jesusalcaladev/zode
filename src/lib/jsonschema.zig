//! A small, pure JSON Schema validator for `structured_output` (Phase 22).
//!
//! It is deliberately a SUBSET: the contract of `--chat --schema` is that the
//! model's object matches the caller's schema, and the failure is a NAMED
//! error pointing at the first field that is wrong — so the model can fix it
//! in one turn, and CI fails loudly instead of parsing a prose apology.
//!
//! Supported keywords: type, required, properties, items, enum, const,
//! minimum, maximum, minLength, maxLength, additionalProperties. Unknown
//! keywords are ignored (forward compatible). Pure: no IO, no clock, no TUI.

const std = @import("std");

pub const Violation = struct {
    /// JSON Pointer-ish path to the offending value, e.g. "items[2].name".
    path: []const u8,
    /// What was expected, in words the model can act on.
    expected: []const u8,
};

pub const Result = union(enum) {
    ok,
    fail: Violation,
};

/// Validate `value` against `schema` (both parsed `std.json.Value` trees).
/// `gpa` is used only to build the path of the first violation.
pub fn validate(gpa: std.mem.Allocator, schema: std.json.Value, value: std.json.Value) !Result {
    return check(gpa, schema, value, "$");
}

fn check(gpa: std.mem.Allocator, schema: std.json.Value, value: std.json.Value, path: []const u8) !Result {
    if (schema != .object) return .ok; // a boolean/absent schema accepts everything

    // enum / const first — they are the most specific claims.
    if (schema.object.get("const")) |c| {
        if (!jsonEqual(c, value)) return fail(gpa, path, "the exact const value");
    }
    if (schema.object.get("enum")) |e| {
        if (e == .array) {
            var found = false;
            for (e.array.items) |candidate| {
                if (jsonEqual(candidate, value)) {
                    found = true;
                    break;
                }
            }
            if (!found) return fail(gpa, path, "one of the enum values");
        }
    }

    if (schema.object.get("type")) |tv| {
        if (tv == .string and !typeMatches(tv.string, value)) {
            return fail(gpa, path, try std.fmt.allocPrint(gpa, "type {s}", .{tv.string}));
        }
    }

    switch (value) {
        .object => |obj| {
            if (schema.object.get("required")) |rv| {
                if (rv == .array) {
                    for (rv.array.items) |req| {
                        if (req != .string) continue;
                        if (obj.get(req.string) == null) {
                            return fail(gpa, try joinPath(gpa, path, req.string), "a required field");
                        }
                    }
                }
            }
            if (schema.object.get("properties")) |pv| {
                if (pv == .object) {
                    for (pv.object.keys(), pv.object.values()) |key, prop_schema| {
                        if (obj.get(key)) |child| {
                            const r = try check(gpa, prop_schema, child, try joinPath(gpa, path, key));
                            if (r == .fail) return r;
                        }
                    }
                }
            }
            if (schema.object.get("additionalProperties")) |ap| {
                if (ap == .bool and !ap.bool) {
                    if (schema.object.get("properties")) |pv| {
                        if (pv == .object) {
                            for (obj.keys()) |key| {
                                if (pv.object.get(key) == null) {
                                    return fail(gpa, try joinPath(gpa, path, key), "no additional properties");
                                }
                            }
                        }
                    }
                }
            }
        },
        .array => |arr| {
            if (schema.object.get("items")) |items_schema| {
                for (arr.items, 0..) |child, i| {
                    const child_path = try std.fmt.allocPrint(gpa, "{s}[{d}]", .{ path, i });
                    const r = try check(gpa, items_schema, child, child_path);
                    if (r == .fail) return r;
                }
            }
            if (schema.object.get("minItems")) |mv| {
                if (intOf(mv)) |min| if (arr.items.len < min) return fail(gpa, path, "more array items");
            }
        },
        .integer => |num_i| {
            const num: f64 = @floatFromInt(num_i);
            if (schema.object.get("minimum")) |mv| {
                if (numberOf(mv)) |min| if (num < min) return fail(gpa, path, "a larger number");
            }
            if (schema.object.get("maximum")) |mv| {
                if (numberOf(mv)) |max| if (num > max) return fail(gpa, path, "a smaller number");
            }
        },
        .float => |num| {
            if (schema.object.get("minimum")) |mv| {
                if (numberOf(mv)) |min| if (num < min) return fail(gpa, path, "a larger number");
            }
            if (schema.object.get("maximum")) |mv| {
                if (numberOf(mv)) |max| if (num > max) return fail(gpa, path, "a smaller number");
            }
        },
        .string => |str| {
            if (schema.object.get("minLength")) |mv| {
                if (intOf(mv)) |min| if (str.len < min) return fail(gpa, path, "a longer string");
            }
            if (schema.object.get("maxLength")) |mv| {
                if (intOf(mv)) |max| if (str.len > max) return fail(gpa, path, "a shorter string");
            }
        },
        else => {},
    }
    return .ok;
}

fn fail(gpa: std.mem.Allocator, path: []const u8, expected: []const u8) !Result {
    return .{ .fail = .{ .path = try gpa.dupe(u8, path), .expected = try gpa.dupe(u8, expected) } };
}

fn joinPath(gpa: std.mem.Allocator, base: []const u8, key: []const u8) ![]const u8 {
    if (std.mem.eql(u8, base, "$")) return std.fmt.allocPrint(gpa, "{s}", .{key});
    return std.fmt.allocPrint(gpa, "{s}.{s}", .{ base, key });
}

fn intOf(v: std.json.Value) ?usize {
    return switch (v) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        .float => |f| if (f >= 0) @intFromFloat(f) else null,
        else => null,
    };
}

fn numberOf(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

fn typeMatches(type_name: []const u8, v: std.json.Value) bool {
    if (std.mem.eql(u8, type_name, "object")) return v == .object;
    if (std.mem.eql(u8, type_name, "array")) return v == .array;
    if (std.mem.eql(u8, type_name, "string")) return v == .string;
    if (std.mem.eql(u8, type_name, "boolean")) return v == .bool;
    if (std.mem.eql(u8, type_name, "null")) return v == .null;
    if (std.mem.eql(u8, type_name, "number")) return v == .integer or v == .float;
    if (std.mem.eql(u8, type_name, "integer")) return v == .integer;
    return true; // unknown type keyword: do not fail the model for it
}

fn jsonEqual(a: std.json.Value, b: std.json.Value) bool {
    if (@as(std.meta.Tag(std.json.Value), a) != @as(std.meta.Tag(std.json.Value), b)) return false;
    return switch (a) {
        .null => true,
        .bool => a.bool == b.bool,
        .integer => a.integer == b.integer,
        .float => a.float == b.float,
        .number_string => std.mem.eql(u8, a.number_string, b.number_string),
        .string => std.mem.eql(u8, a.string, b.string),
        else => false,
    };
}

/// The message the model sees when validation fails: names the FIRST field,
/// the expected shape, and the way out (call structured_output again).
pub fn violationText(gpa: std.mem.Allocator, v: Violation) ![]const u8 {
    return std.fmt.allocPrint(gpa,
        "structured_output did not match the schema: {s} must be {s}. Fix that field and call structured_output again with the complete object.",
        .{ v.path, v.expected },
    );
}

const t = std.testing;

test "jsonschema: a valid object passes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, a,
        "{\"type\":\"object\",\"required\":[\"name\",\"count\"],\"properties\":{\"name\":{\"type\":\"string\"},\"count\":{\"type\":\"integer\",\"minimum\":1}}}", .{});
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"name\":\"x\",\"count\":3}", .{});
    try t.expect(try validate(a, schema, value) == .ok);
}

test "jsonschema: names the first missing required field" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, a,
        "{\"type\":\"object\",\"required\":[\"name\",\"count\"],\"properties\":{\"name\":{\"type\":\"string\"}}}", .{});
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"name\":\"x\"}", .{});
    const r = try validate(a, schema, value);
    try t.expect(r == .fail);
    try t.expectEqualStrings("count", r.fail.path);
    try t.expectEqualStrings("a required field", r.fail.expected);
}

test "jsonschema: names a wrong field type and an out-of-range item" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, a,
        "{\"properties\":{\"name\":{\"type\":\"string\"},\"items\":{\"type\":\"array\",\"items\":{\"type\":\"integer\",\"minimum\":1}}}}", .{});
    const bad_type = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"name\":5}", .{});
    const r1 = try validate(a, schema, bad_type);
    try t.expect(r1 == .fail);
    try t.expectEqualStrings("name", r1.fail.path);

    const bad_item = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"name\":\"x\",\"items\":[1,0]}", .{});
    const r2 = try validate(a, schema, bad_item);
    try t.expect(r2 == .fail);
    try t.expectEqualStrings("items[1]", r2.fail.path);
}

test "jsonschema: enum and additionalProperties" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const enum_schema = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"enum\":[\"a\",\"b\"]}", .{});
    try t.expect(try validate(a, enum_schema, try std.json.parseFromSliceLeaky(std.json.Value, a, "\"a\"", .{})) == .ok);
    try t.expect(try validate(a, enum_schema, try std.json.parseFromSliceLeaky(std.json.Value, a, "\"c\"", .{})) == .fail);

    const strict = try std.json.parseFromSliceLeaky(std.json.Value, a,
        "{\"properties\":{\"a\":{\"type\":\"string\"}},\"additionalProperties\":false}", .{});
    try t.expect(try validate(a, strict, try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"extra\":1}", .{})) == .fail);
    try t.expect(try validate(a, strict, try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"a\":\"x\"}", .{})) == .ok);
}
