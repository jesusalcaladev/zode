const std = @import("std");

/// Cliente HTTP JSON sobre std.http.Client (Zig 0.16).
///
/// NOTA: `Request` se alina en heap porque `receiveHead` y `bodyReader`
/// guardan punteros internos al request.
pub const Http = struct {
    client: std.http.Client,
    gpa: std.mem.Allocator,
    io: std.Io,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Http {
        return .{
            .client = .{
                .allocator = gpa,
                .io = io,
            },
            .gpa = gpa,
            .io = io,
        };
    }

    pub fn deinit(self: *Http) void {
        self.client.deinit();
    }

    pub const JsonResult = struct {
        status: u16,
        body: []u8, // el caller libera con `freeBody`
        /// Valor del header `retry-after` en segundos, si vino.
        retry_after: ?u16 = null,
    };

    // NO hay `content_type` aqui a proposito: `receiveHead` deja los headers en
    // el buffer de redirects, que es de STACK y muere al salir de `request`. Un
    // `?[]const u8` a ese buffer colgado no da error de compilacion: da basura
    // (y un crash en ReleaseSafe) el primer dia que alguien lea el campo. Quien
    // necesite el tipo lo deduce del body, que si vive en `body`.

    /// Header adicional para APIs que no usan Bearer (ej: x-api-key de Anthropic).
    pub const ExtraHeader = struct {
        name: []const u8,
        value: []const u8,
    };

    pub fn freeBody(self: *Http, body: []u8) void {
        self.gpa.free(body);
    }

    /// Resultado de un request sin cuerpo de respuesta (streaming).
    pub const StreamResult = struct {
        status: u16,
        retry_after: ?u16 = null,
    };

    /// Callback invocado con cada trozo de bytes tal cual llega. Devolver
    /// `error.Cancelled` aborta la lectura (el caller ve ese error).
    pub const ChunkFn = *const fn (userdata: ?*anyopaque, chunk: []const u8) anyerror!void;

    /// POST que entrega el body POR TROZOS en vez de acumularlo entero.
    ///
    /// Esto es lo que hace que el streaming SSE sea real: con `request()` el
    /// body se bufferea completo (hasta 10 MB) y solo se parsea al final, así
    /// que la TUI se queda congelada durante toda la generación. Aquí cada
    /// chunk se entrega en cuanto llega desde el socket.
    pub fn streamPost(
        self: *Http,
        url: []const u8,
        bearer: ?[]const u8,
        body: []u8,
        extra_headers: []const ExtraHeader,
        on_chunk: ChunkFn,
        userdata: ?*anyopaque,
    ) !StreamResult {
        const req = try self.openRequest(.POST, url, bearer, body, extra_headers, true);
        defer req.deinit();
        defer self.gpa.destroy(req);

        var redirect_buf: [8192]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);
        const status: u16 = @intFromEnum(response.head.status);
        const retry_after = parseRetryAfter(response.head);

        // El buffer de transferencia va al HEAP (5.5 del ROADMAP), no a la pila: son
        // 256 KiB residentes durante toda la descarga y, con el stack por defecto
        // de `std.Thread`, dejarían una trampa para el día que alguien lo baje.
        const transfer_buf = try self.gpa.alloc(u8, 256 * 1024);
        defer self.gpa.free(transfer_buf);
        var reader = response.reader(transfer_buf);
        // `takeDelimiter` exige que el delimitador quepa en el buffer: una
        // línea SSE más larga (un tool call enorme, un delta gigante) lo hace
        // fallar con StreamTooLong y MATABA el stream a mitad de respuesta.
        // Cuando ocurre, el buffer está lleno de una línea sin cerrar: se
        // entrega tal cual y se sigue, porque el parser reensambla parciales.
        while (true) {
            const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    const rest = reader.buffer[reader.seek..reader.end];
                    if (rest.len == 0) break;
                    try on_chunk(userdata, rest);
                    reader.toss(rest.len);
                    continue;
                },
                error.EndOfStream => {
                    const rest = reader.buffer[reader.seek..reader.end];
                    if (rest.len > 0) try on_chunk(userdata, rest);
                    break;
                },
                else => |e| return e,
            };
            try on_chunk(userdata, line);
        }
        return .{ .status = status, .retry_after = retry_after };
    }

    /// GET que devuelve el body completo (límite 10MB).
    pub fn get(self: *Http, url: []const u8, bearer: ?[]const u8) !JsonResult {
        return self.request(.GET, url, bearer, null, &.{});
    }

    /// GET con headers propios.
    ///
    /// Lo necesita la tool de web: medio internet (Cloudflare, GitHub, Wikipedia)
    /// devuelve 403 al `User-Agent` por defecto de std, que es `zig`, y la
    /// respuesta de un 403 no dice nada de lo que había detrás.
    pub fn getWithHeaders(self: *Http, url: []const u8, headers: []const ExtraHeader) !JsonResult {
        return self.request(.GET, url, null, null, headers);
    }

    /// POST con body JSON. Devuelve el body completo (para SSE: `sendSse`).
    /// `body` debe ser mutable por la firma de std (`sendBodyComplete`).
    pub fn postJson(self: *Http, url: []const u8, bearer: ?[]const u8, body: []u8) !JsonResult {
        return self.request(.POST, url, bearer, body, &.{});
    }

    /// POST con headers adicionales (ej: x-api-key de Anthropic).
    pub fn postJsonWithHeaders(
        self: *Http,
        url: []const u8,
        body: []u8,
        headers: []const ExtraHeader,
    ) !JsonResult {
        return self.request(.POST, url, null, body, headers);
    }

    /// Abre un request y envía el body. El caller hace `deinit` + `destroy`.
    /// `streaming` añade los headers de SSE.
    fn openRequest(
        self: *Http,
        method: std.http.Method,
        url: []const u8,
        bearer: ?[]const u8,
        body: ?[]u8,
        extra_headers: []const ExtraHeader,
        streaming: bool,
    ) !*std.http.Client.Request {
        const uri = std.Uri.parse(url) catch return error.InvalidUrl;

        var auth_buf: [512]u8 = undefined;
        var auth_value: ?[]const u8 = null;
        if (bearer) |token| {
            auth_value = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token}) catch null;
        }

        var extra: [6]std.http.Header = undefined;
        var extra_len: usize = 0;
        if (auth_value) |v| {
            extra[extra_len] = .{ .name = "authorization", .value = v };
            extra_len += 1;
        }
        if (body != null) {
            extra[extra_len] = .{ .name = "content-type", .value = "application/json" };
            extra_len += 1;
        }
        if (streaming) {
            // Muchos gateways (vLLM, Ollama, proxies) renegocian el stream
            // según estos headers; sin ellos pueden devolver JSON de error.
            extra[extra_len] = .{ .name = "accept", .value = "text/event-stream" };
            extra_len += 1;
            extra[extra_len] = .{ .name = "cache-control", .value = "no-cache" };
            extra_len += 1;
        }
        for (extra_headers) |h| {
            if (extra_len >= extra.len) break;
            extra[extra_len] = .{ .name = h.name, .value = h.value };
            extra_len += 1;
        }

        const req = try self.gpa.create(std.http.Client.Request);
        errdefer self.gpa.destroy(req);
        req.* = try self.client.request(method, uri, .{
            .extra_headers = extra[0..extra_len],
            .redirect_behavior = @enumFromInt(3),
            // Sin compresión: evita depender del decompress transparente
            .headers = .{ .accept_encoding = .omit },
        });
        errdefer req.deinit();

        if (body) |b| {
            try req.sendBodyComplete(b);
        } else {
            try req.sendBodiless();
        }
        return req;
    }

    fn request(
        self: *Http,
        method: std.http.Method,
        url: []const u8,
        bearer: ?[]const u8,
        body: ?[]u8,
        extra_headers: []const ExtraHeader,
    ) !JsonResult {
        const req = try self.openRequest(method, url, bearer, body, extra_headers, false);
        defer req.deinit();
        defer self.gpa.destroy(req);

        var redirect_buf: [8192]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);
        const status: u16 = @intFromEnum(response.head.status);
        const retry_after = parseRetryAfter(response.head);

        var transfer_buf: [64 * 1024]u8 = undefined;
        const rd = response.reader(&transfer_buf);
        const max = 10 * 1024 * 1024;
        const alloc_body = try rd.allocRemaining(self.gpa, .limited(max));
        errdefer self.gpa.free(alloc_body);

        return .{ .status = status, .body = alloc_body, .retry_after = retry_after };
    }
};

/// Lee `retry-after` (segundos) de la respuesta, si el server lo mandó.
fn parseRetryAfter(head: anytype) ?u16 {
    var it = head.iterateHeaders();
    while (it.next()) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "retry-after")) continue;
        return std.fmt.parseInt(u16, std.mem.trim(u8, h.value, " "), 10) catch null;
    }
    return null;
}

test "json escape helper" {
    _ = struct {
        pub fn jsonStringify(s: []const u8, w: anytype) !void {
            try std.json.Stringify.encodeJsonString(s, .{}, w);
        }
    };
}
