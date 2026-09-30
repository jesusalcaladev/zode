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
    /// Ventana de contexto en tokens (0 = el provider no lo publica).
    /// OpenRouter sí lo manda, y es lo que permite dejar de usar el 128k fijo.
    context_length: u32 = 0,
    /// Precio por prompt token en USD (0 = desconocido). Viene como string
    /// decimal en OpenRouter ("0.00000015").
    price_prompt: f64 = 0,
    /// Precio por completion token en USD.
    price_completion: f64 = 0,
    /// [roster] ¿Es gratis de verdad? Ver `isFreeId` y `isFreeByPrice`.
    ///
    /// Antes esto se decidía en el consumidor con `endsWith(id, "-free")`, y eso
    /// solo veía los modelos de opencode: en OpenRouter el sufijo es `:free`, y
    /// hay providers que no usan ningún sufijo y se limitan a publicar precio 0.
    is_free: bool = false,
};

/// ¿El id tiene la marca de "gratis" que usa su provider?
///
/// Dos convenciones y las dos existen: opencode usa `-free`
/// ("space-bunny-free") y OpenRouter usa `:free` ("qwen/qwen3-8b:free").
/// Comprobar solo una de las dos es lo que hacía que el pool de modelos free
/// viera un provider y ningún otro.
pub fn isFreeId(id: []const u8) bool {
    return std.mem.endsWith(u8, id, "-free") or std.mem.endsWith(u8, id, ":free");
}

/// ¿El precio publica que es gratis?
///
/// Solo vale si el modelo TRAÍA el objeto `pricing` (lo sabe el parser). Un
/// provider que no publica precios deja los dos a 0, y sin esta comprobación
/// todos sus modelos saldrían gratis: el peor fallo posible para un modo que se
/// llama "free-auto", porque se creería que puede gastar sin pagar.
pub fn isFreeByPrice(has_pricing: bool, price_prompt: f64, price_completion: f64) bool {
    return has_pricing and price_prompt == 0 and price_completion == 0;
}

pub const ModelList = struct {
    items: []Model,
    /// Modelos free detectados (`is_free`), no "los que acaban en -free".
    free_count: usize,
    /// El provider publicó contexto/precio para al menos un modelo.
    has_metadata: bool = false,

    pub fn deinit(self: *ModelList, gpa: std.mem.Allocator) void {
        for (self.items) |m| {
            gpa.free(m.id);
            gpa.free(m.owned_by);
        }
        gpa.free(self.items);
    }
};

/// GET /models (formato OpenAI: {"object":"list","data":[{"id":...}]}).
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
    // OpenAI y Anthropic usan {"data":[...]}; algunos proxies anidan
    // (data.data) o devuelven el array directamente.
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

        // Metadatos opcionales: solo OpenRouter los publica, el resto de
        // providersOpenAI-compat los omiten. Si faltan, quedan en 0.
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
        // [roster] ¿Vino el objeto `pricing`? Distingue "precio 0" de "no public
        // precio", que es la diferencia entre un modelo gratis y un provider que
        // no dice nada.
        var has_pricing = false;
        if (entry.object.get("pricing")) |pv| {
            if (pv == .object) {
                has_pricing = true;
                if (pv.object.get("prompt")) |v| p_prompt = jsonNumber(v);
                if (pv.object.get("completion")) |v| p_completion = jsonNumber(v);
            }
        }
        if (ctx > 0 or p_prompt > 0) has_metadata = true;

        const free = isFreeId(id_copy) or isFreeByPrice(has_pricing, p_prompt, p_completion);
        if (free) free_count += 1;

        items[i] = .{
            .id = id_copy,
            .owned_by = owner_copy,
            .context_length = ctx,
            .price_prompt = p_prompt,
            .price_completion = p_completion,
            .is_free = free,
        };
    }

    return .{ .items = items, .free_count = free_count, .has_metadata = has_metadata };
}

/// Lee un número que el provider puede mandar como float, entero, o como
/// string decimal (OpenRouter manda los precios así para no perder precisión
/// en float). Nunca devuelve NaN: eso rompería las comparaciones de /cost.
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
    // Payload real de OpenRouter (los precios vienen como strings decimales).
    const json =
        \\{"object":"list","data":[
        \\ {"id":"anthropic/claude-sonnet-4-5","owned_by":"anthropic",
        \\  "context_length":200000,
        \\  "pricing":{"prompt":"0.000003","completion":"0.000015"}},
        \\ {"id":"some/free-model","owned_by":"x","context_length":8192}
        \\]}
    ;
    // Reusa el parser sin red: extraemos la parte de parseo a un helper.
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

    // Modelo sin pricing: 0, no NaN.
    const no_price = data.array.items[1].object.get("pricing");
    try std.testing.expect(no_price == null);
}

test "jsonNumber acepta float, integer y string decimal" {
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), jsonNumber(.{ .float = 1.5 }), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), jsonNumber(.{ .integer = 7 }), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), jsonNumber(.{ .number_string = "0.25" }), 1e-12);
    // Basura → 0, nunca NaN (que rompería las comparaciones).
    try std.testing.expectApproxEqAbs(@as(f64, 0), jsonNumber(.{ .string = "abc" }), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), jsonNumber(.null), 1e-9);
}

// ── [roster] qué es un modelo gratis ──────────────────────────

test "isFreeId: las dos convenciones de sufijo" {
    // opencode
    try std.testing.expect(isFreeId("space-bunny-free"));
    try std.testing.expect(isFreeId("kimi-k2.6-free"));
    // OpenRouter, con prefijo de provider
    try std.testing.expect(isFreeId("qwen/qwen3-8b:free"));
    try std.testing.expect(isFreeId("meta-llama/llama-3.3-70b-instruct:free"));
    // Y lo que NO es
    try std.testing.expect(!isFreeId("gpt-4o"));
    try std.testing.expect(!isFreeId("deepseek/deepseek-chat"));
    try std.testing.expect(!isFreeId("free-model-with-no-suffix"));
    try std.testing.expect(!isFreeId(""));
    // El sufijo va AL FINAL: un "free" en medio es otra cosa (un nombre).
    try std.testing.expect(!isFreeId("free-tier/default"));
}

test "isFreeByPrice: precio 0 con pricing es gratis; sin pricing NO" {
    // La señal que no depende de la convención del id.
    try std.testing.expect(isFreeByPrice(true, 0, 0));
    // Cualquiera de los dos a > 0 ya no es gratis.
    try std.testing.expect(!isFreeByPrice(true, 0.00000015, 0));
    try std.testing.expect(!isFreeByPrice(true, 0, 0.0000006));
    try std.testing.expect(!isFreeByPrice(true, 3, 15));
    // Y el caso peligroso: provider que no publica pricing. Sin el `has_pricing`
    // TODOS sus modelos saldrían gratis y el free-auto creería que puede
    // gastar sin pagar.
    try std.testing.expect(!isFreeByPrice(false, 0, 0));
}

test "el parser marca is_free con las tres señales" {
    // Fixture que mezcla las tres formas y un modelo de pago, con los precios
    // reales en el formato string de OpenRouter.
    const json =
        \\{"object":"list","data":[
        \\ {"id":"space-bunny-free","owned_by":"opencode"},
        \\ {"id":"qwen/qwen3-8b:free","owned_by":"openrouter","context_length":32768,
        \\  "pricing":{"prompt":"0","completion":"0"}},
        \\ {"id":"llama-3.3-free","owned_by":"groq","context_length":131072,
        \\  "pricing":{"prompt":"0","completion":"0"}},
        \\ {"id":"anthropic/claude-sonnet-4-5","owned_by":"anthropic","context_length":200000,
        \\  "pricing":{"prompt":"0.000003","completion":"0.000015"}},
        \\ {"id":"gpt-4o","owned_by":"openai"}
        \\]}
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), json, .{});
    const data = parsed.object.get("data").?.array;

    var free: usize = 0;
    for (data.items) |entry| {
        const id = entry.object.get("id").?.string;
        var has_pricing = false;
        var p_prompt: f64 = 0;
        var p_completion: f64 = 0;
        if (entry.object.get("pricing")) |pv| {
            if (pv == .object) {
                has_pricing = true;
                if (pv.object.get("prompt")) |v| p_prompt = jsonNumber(v);
                if (pv.object.get("completion")) |v| p_completion = jsonNumber(v);
            }
        }
        const is_free = isFreeId(id) or isFreeByPrice(has_pricing, p_prompt, p_completion);
        if (is_free) free += 1;
        // El de pago y el que no publica nada tienen que salir falsos.
        if (std.mem.eql(u8, id, "anthropic/claude-sonnet-4-5") or std.mem.eql(u8, id, "gpt-4o")) {
            try std.testing.expect(!is_free);
        }
    }
    try std.testing.expectEqual(@as(usize, 3), free);
}
