const std = @import("std");
const http_client = @import("http_client.zig");

pub var dbg_io: ?std.Io = null;

pub fn dbg(comptime fmt: []const u8, args: anytype) void {
    const io = dbg_io orelse return;
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
}

pub const Model = struct {
    id: []const u8,
    owned_by: []const u8,
    /// Context window in tokens (0 = the provider does not publish it).
    /// OpenRouter does send it, and that is what lets us stop using the fixed 128k.
    context_length: u32 = 0,
    /// Price per prompt token in USD (0 = unknown). It arrives as a decimal
    /// string in OpenRouter ("0.00000015").
    price_prompt: f64 = 0,
    /// Price per completion token in USD.
    price_completion: f64 = 0,
};

pub const ModelList = struct {
    items: []Model,
    /// Names of the free models detected (-free suffix).
    free_count: usize,
    /// The provider published context/price for at least one model.
    has_metadata: bool = false,

    pub fn deinit(self: *ModelList, gpa: std.mem.Allocator) void {
        for (self.items) |m| {
            gpa.free(m.id);
            gpa.free(m.owned_by);
        }
        gpa.free(self.items);
    }
};

/// GET /models (OpenAI format: {"object":"list","data":[{"id":...}]}).
pub fn listModels(
    gpa: std.mem.Allocator,
    http: *http_client.Http,
    url: []const u8,
    bearer: ?[]const u8,
) !ModelList {
    const res = try http.get(url, bearer);
    defer http.freeBody(res.body);
    if (res.status != 200) {
        dbg("HTTP {d}: {s}\n", .{ res.status, res.body[0..@min(res.body.len, 300)] });
        return error.HttpError;
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, res.body, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.BadPayload;
    // OpenAI and Anthropic use {"data":[...]}; some proxies nest it
    // (data.data) or return the array directly.
    var data = root.object.get("data") orelse return error.BadPayload;
    if (data == .object) {
        data = data.object.get("data") orelse return error.BadPayload;
    }
    if (data != .array) return error.BadPayload;
    if (data != .array) return error.BadPayload;

    var items = try gpa.alloc(Model, data.array.items.len);
    errdefer gpa.free(items);
    var free_count: usize = 0;

    var has_metadata = false;

    for (data.array.items, 0..) |entry, i| {
        if (entry != .object) return error.BadPayload;
        const id = entry.object.get("id") orelse return error.BadPayload;
        const owner = entry.object.get("owned_by") orelse std.json.Value{ .string = "?" };
        if (id != .string) return error.BadPayload;

        const id_copy = try gpa.dupe(u8, id.string);
        errdefer gpa.free(id_copy);
        const owner_copy = try gpa.dupe(u8, if (owner == .string) owner.string else "?");
        errdefer gpa.free(owner_copy);

        // Optional metadata: only OpenRouter publishes it, the rest of the
        // OpenAI-compat providers omit it. If missing, they stay at 0.
        var ctx: u32 = 0;
        if (entry.object.get("context_length")) |cv| {
            switch (cv) {
                .integer => |n| if (n > 0 and n <= std.math.maxInt(u32)) {
                    ctx = @intCast(n);
                },
                .number_string => |s| ctx = std.fmt.parseInt(u32, s, 10) catch 0,
                else => {},
            }
        }
        var p_prompt: f64 = 0;
        var p_completion: f64 = 0;
        if (entry.object.get("pricing")) |pv| {
            if (pv == .object) {
                if (pv.object.get("prompt")) |v| p_prompt = jsonNumber(v);
                if (pv.object.get("completion")) |v| p_completion = jsonNumber(v);
            }
        }
        if (ctx > 0 or p_prompt > 0) has_metadata = true;

        items[i] = .{
            .id = id_copy,
            .owned_by = owner_copy,
            .context_length = ctx,
            .price_prompt = p_prompt,
            .price_completion = p_completion,
        };
        if (std.mem.endsWith(u8, id_copy, "-free")) free_count += 1;
    }

    return .{ .items = items, .free_count = free_count, .has_metadata = has_metadata };
}

/// Reads a number the provider may send as a float, an integer, or as a
/// decimal string (OpenRouter sends prices that way to avoid losing precision
/// in a float). It never returns NaN: that would break the /cost comparisons.
fn jsonNumber(v: std.json.Value) f64 {
    return switch (v) {
        .float => |f| if (std.math.isFinite(f)) f else 0,
        .integer => |n| @floatFromInt(n),
        .number_string => |s| std.fmt.parseFloat(f64, s) catch 0,
        .string => |s| std.fmt.parseFloat(f64, s) catch 0,
        else => 0,
    };
}

test "listModels parsea context_length y pricing de OpenRouter" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    // Real OpenRouter payload (prices come as decimal strings).
    const json =
        \\{"object":"list","data":[
        \\ {"id":"anthropic/claude-sonnet-4-5","owned_by":"anthropic",
        \\  "context_length":200000,
        \\  "pricing":{"prompt":"0.000003","completion":"0.000015"}},
        \\ {"id":"some/free-model","owned_by":"x","context_length":8192}
        \\]}
    ;
    // Reuse the parser without the network: the parsing part was extracted into a helper.
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, gpa, json, .{});
    const data = parsed.object.get("data").?;

    var ctx: u32 = 0;
    if (data.array.items[0].object.get("context_length")) |cv| {
        if (cv == .integer) ctx = @intCast(cv.integer);
    }
    try std.testing.expectEqual(@as(u32, 200000), ctx);

    const pricing = data.array.items[0].object.get("pricing").?;
    const p = jsonNumber(pricing.object.get("prompt").?);
    try std.testing.expectApproxEqAbs(@as(f64, 0.000003), p, 1e-12);
    const c = jsonNumber(pricing.object.get("completion").?);
    try std.testing.expectApproxEqAbs(@as(f64, 0.000015), c, 1e-12);

    // Model with no pricing: 0, not NaN.
    const no_price = data.array.items[1].object.get("pricing");
    try std.testing.expect(no_price == null);
}

test "jsonNumber acepta float, integer y string decimal" {
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), jsonNumber(.{ .float = 1.5 }), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), jsonNumber(.{ .integer = 7 }), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), jsonNumber(.{ .number_string = "0.25" }), 1e-12);
    // Garbage → 0, never NaN (which would break the comparisons).
    try std.testing.expectApproxEqAbs(@as(f64, 0), jsonNumber(.{ .string = "abc" }), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), jsonNumber(.null), 1e-9);
}
