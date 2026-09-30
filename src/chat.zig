const std = @import("std");
const http_client = @import("http_client.zig");
const acp = @import("acp.zig");

/// Io configurado por la TUI/CLI al arrancar.
///
/// OJO: ya NO se usa para dormir (ver `sleepMs`): `Io.sleep` desde un worker se
/// lleva el event loop de la TUI. Sigue aquí para el resto de la capa HTTP.
pub var io_global: std.Io = undefined;

pub const Effort = enum(u32) {
    low = 1024,
    medium = 4096,
    high = 16384,

    pub fn parse(s: []const u8) ?Effort {
        if (std.mem.eql(u8, s, "low")) return .low;
        if (std.mem.eql(u8, s, "medium")) return .medium;
        if (std.mem.eql(u8, s, "high")) return .high;
        return null;
    }
};

/// Wire format del provider para chat: OpenAI-compat (chat/completions) o
/// Anthropic nativo (Messages API con cache_control para prompt caching).
pub const ProviderKind = enum { openai, anthropic };

/// Mapea el id del provider a su wire format.
pub fn kindForProvider(provider_id: []const u8) ProviderKind {
    if (std.mem.eql(u8, provider_id, "anthropic")) return .anthropic;
    return .openai;
}

/// Familias de modelo que cambian la forma del request más allá del
/// wire format: no basta con saber si es OpenAI o Anthropic.
pub const Family = enum {
    generic_openai,
    /// o-series / gpt-5: quieren `max_completion_tokens`, rechazan
    /// `temperature`, yfram `reasoning_effort`.
    openai_reasoning,
    /// Anthropic con thinking extended: `max_tokens` debe superar el budget
    /// de razonamiento.
    anthropic_thinking,
    anthropic,

    pub fn parse(s: []const u8) ?Family {
        if (std.mem.eql(u8, s, "openai_reasoning")) return .openai_reasoning;
        if (std.mem.eql(u8, s, "anthropic_thinking")) return .anthropic_thinking;
        if (std.mem.eql(u8, s, "anthropic")) return .anthropic;
        if (std.mem.eql(u8, s, "openai") or std.mem.eql(u8, s, "generic")) return .generic_openai;
        return null;
    }
};

/// Detecta la familia a partir del nombre del modelo. Heurística, no tabla:
/// cubre los prefijos habituales de OpenAI y los gates de OpenCode.
pub fn familyForModel(model: []const u8) Family {
    if (startsWithAny(model, &.{
        "o1", "o3", "o4", "gpt-5", "gpt5", "o1-", "o3-", "o4-", "gpt-5-",
    })) return .openai_reasoning;
    return .generic_openai;
}

fn startsWithAny(haystack: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, haystack, p)) return true;
    }
    return false;
}

/// Referencia a un mensaje del historial para el wire format.
pub const ChatMessage = struct {
    role: []const u8, // "system" | "user" | "assistant" | "tool"
    content: []const u8,
    tool_calls_json: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
};

pub const Callbacks = struct {
    userdata: ?*anyopaque = null,
    /// Fragmento de texto del asistente.
    onDelta: *const fn (?*anyopaque, []const u8) void = defaultOnDelta,
    /// Tool call completo (id + name + arguments ya ensamblados).
    onToolCall: ?*const fn (?*anyopaque, id: []const u8, name: []const u8, args_json: []const u8) void = null,
    /// finish_reason ("stop", "tool_calls", ...).
    onFinish: ?*const fn (?*anyopaque, reason: []const u8) void = null,

    fn defaultOnDelta(_: ?*anyopaque, _: []const u8) void {}
};

/// Saca el texto de `"message":"..."` de un JSON de error del server y lo deja
/// en `last_error_buf`.
///
/// A mano y no con `std.json` porque este cuerpo se lee justo cuando ya se va a
/// devolver un error: parsearlo aqui solo podria fallar otra vez. Si el JSON no
/// trae `message` (o no es JSON), el caller cae al "HTTP nnn".
fn setServerMessage(body: []const u8) void {
    last_error_len = 0;
    const key = "\"message\"";
    const at = std.mem.indexOf(u8, body, key) orelse return;
    var i = at + key.len;
    while (i < body.len and (body[i] == ' ' or body[i] == ':')) i += 1;
    if (i >= body.len or body[i] != '"') return;
    i += 1;

    var n: usize = 0;
    while (i < body.len and body[i] != '"') : (i += 1) {
        // Solo se desescapan la barra invertida y la comilla: un \uXXXX
        // indulgingido no merece la pena y es texto de error, no contenido.
        if (body[i] == '\\' and i + 1 < body.len) i += 1;
        if (n + 1 >= last_error_buf.len) break;
        last_error_buf[n] = body[i];
        n += 1;
    }
    if (n == 0) return;
    last_error_len = n;
}

/// Últimos bytes del body cuando el server rechaza (para diagnóstico).
pub var last_error_buf: [512]u8 = undefined;
pub var last_error_len: usize = 0;

// ── ZODE_DBG_ERR: volcar la respuesta del server ──────────────
//
// `ZODE_DBG_ERR=1` imprime a stderr el status y los primeros bytes de CADA
// respuesta (buena o mala). Existe por una razón concreta: el mensaje de error
// que se ve en la TUI sale de `"message":"..."` del body, y cuando el body no
// tiene ese campo (o viene troceado) lo que se muestra es "HTTP 403" y no hay
// por dónde tirar. Con esto se lee lo que contestó de verdad.
//
// Se lee UNA vez al arrancar (`dbgInitEnv`): el `Io` no expone el entorno, y
// leerlo por cada respuesta sería una lookup por request.
pub var dbg_err_flag: bool = false;

pub fn dbgInitEnv(env: ?*const std.process.Environ.Map) void {
    const v = if (env) |e| e.get("ZODE_DBG_ERR") else null;
    dbg_err_flag = if (v) |x| x.len > 0 and x[0] != '0' else false;
}

fn dbg_err() bool {
    return dbg_err_flag;
}

pub fn lastErrorBody() []const u8 {
    return last_error_buf[0..last_error_len];
}

/// Puesto a true por la UI (ESC) para abortar el stream en vuelo. Atómico:
/// lo escribe el hilo de la TUI y lo lee el worker del request.
pub var cancel_current = std.atomic.Value(bool).init(false);

/// ¿Se pidió cancelar? Lo consulta el loop de SSE.
pub fn cancelled() bool {
    return cancel_current.load(.seq_cst);
}

/// Limpia el flag al empezar un request nuevo.
pub fn clearCancel() void {
    cancel_current.store(false, .seq_cst);
}

/// Token usage of the last completed stream (provider-agnostic):
/// OpenAI style (prompt_tokens_details.cached_tokens) and Anthropic style
/// (cache_read_input_tokens) both normalized here.
pub const Usage = struct {
    prompt: i64 = 0,
    cached: i64 = 0,
    completion: i64 = 0,
};
pub var last_usage: Usage = .{};

// ── capa 1: eventos internos del stream ──────────────────────
const Event = union(enum) {
    delta: []const u8,
    /// Fragmento de tool call (indexado, llega incremental).
    tool_frag: struct {
        index: usize,
        id: ?[]const u8,
        name: ?[]const u8,
        args: ?[]const u8,
    },
    finish: []const u8,
    err: []const u8,
    usage: Usage,
};

/// Dispatch interno: traduce JSON del stream a Events y llama `dispatch`.
fn dispatchEvents(gpa: std.mem.Allocator, payload: []const u8, userdata: ?*anyopaque, dispatch: *const fn (?*anyopaque, Event) void) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, payload, .{});
    if (parsed != .object) return error.BadPayload;

    if (parsed.object.get("error")) |e| {
        var msg: []const u8 = "server error";
        if (e == .object) {
            if (e.object.get("message")) |m| {
                if (m == .string) msg = m.string;
            }
        }
        const n = @min(msg.len, last_error_buf.len);
        @memcpy(last_error_buf[0..n], msg[0..n]);
        last_error_len = n;
        dispatch(userdata, .{ .err = msg });
        return error.ServerError;
    }

    // usage (llega en el chunk final, a veces sin choices)
    if (parsed.object.get("usage")) |u| {
        if (u == .object) {
            var usage = Usage{};
            if (u.object.get("prompt_tokens")) |v| {
                if (v == .integer) usage.prompt = v.integer;
            }
            if (u.object.get("completion_tokens")) |v| {
                if (v == .integer) usage.completion = v.integer;
            }
            // OpenAI style
            if (u.object.get("prompt_tokens_details")) |d| {
                if (d == .object) {
                    if (d.object.get("cached_tokens")) |v| {
                        if (v == .integer) usage.cached = v.integer;
                    }
                }
            }
            // Anthropic style
            if (u.object.get("cache_read_input_tokens")) |v| {
                if (v == .integer and usage.cached == 0) usage.cached = v.integer;
            }
            if (usage.prompt > 0 or usage.completion > 0) {
                dispatch(userdata, .{ .usage = usage });
            }
        }
    }

    // ── Anthropic Messages API (eventos tipados) ────────────────
    if (parsed.object.get("type")) |tv| {
        if (tv == .string) {
            const ty = tv.string;

            if (std.mem.eql(u8, ty, "message_start")) {
                if (parsed.object.get("message")) |m| {
                    if (m == .object) {
                        if (m.object.get("usage")) |u| {
                            if (u == .object) {
                                var usage = Usage{};
                                if (u.object.get("input_tokens")) |v| {
                                    if (v == .integer) usage.prompt = v.integer;
                                }
                                if (u.object.get("cache_read_input_tokens")) |v| {
                                    if (v == .integer) usage.cached = v.integer;
                                }
                                if (usage.prompt > 0 or usage.cached > 0) {
                                    dispatch(userdata, .{ .usage = usage });
                                }
                            }
                        }
                    }
                }
                return;
            }

            if (std.mem.eql(u8, ty, "content_block_start")) {
                if (parsed.object.get("content_block")) |cb| {
                    if (cb == .object) {
                        const bt = cb.object.get("type") orelse return;
                        if (bt == .string and std.mem.eql(u8, bt.string, "tool_use")) {
                            var index: usize = 0;
                            if (parsed.object.get("index")) |ix| {
                                if (ix == .integer and ix.integer >= 0) index = @intCast(ix.integer);
                            }
                            var id: ?[]const u8 = null;
                            var name: ?[]const u8 = null;
                            if (cb.object.get("id")) |v| {
                                if (v == .string) id = v.string;
                            }
                            if (cb.object.get("name")) |v| {
                                if (v == .string) name = v.string;
                            }
                            dispatch(userdata, .{ .tool_frag = .{ .index = index, .id = id, .name = name, .args = null } });
                        }
                    }
                }
                return;
            }

            if (std.mem.eql(u8, ty, "content_block_delta")) {
                const d = parsed.object.get("delta") orelse return;
                if (d != .object) return;
                const dt = d.object.get("type") orelse return;
                if (dt != .string) return;
                var index: usize = 0;
                if (parsed.object.get("index")) |ix| {
                    if (ix == .integer and ix.integer >= 0) index = @intCast(ix.integer);
                }
                if (std.mem.eql(u8, dt.string, "text_delta")) {
                    if (d.object.get("text")) |v| {
                        if (v == .string and v.string.len > 0) dispatch(userdata, .{ .delta = v.string });
                    }
                    return;
                }
                if (std.mem.eql(u8, dt.string, "input_json_delta")) {
                    if (d.object.get("partial_json")) |v| {
                        if (v == .string and v.string.len > 0) {
                            dispatch(userdata, .{ .tool_frag = .{ .index = index, .id = null, .name = null, .args = v.string } });
                        }
                    }
                    return;
                }
                return; // thinking_delta, signature_delta, etc.
            }

            if (std.mem.eql(u8, ty, "message_delta")) {
                if (parsed.object.get("usage")) |u| {
                    if (u == .object) {
                        if (u.object.get("output_tokens")) |v| {
                            if (v == .integer) dispatch(userdata, .{ .usage = .{ .completion = v.integer } });
                        }
                    }
                }
                if (parsed.object.get("delta")) |d| {
                    if (d == .object) {
                        if (d.object.get("stop_reason")) |sr| {
                            if (sr == .string and sr.string.len > 0) {
                                const reason: []const u8 =
                                    if (std.mem.eql(u8, sr.string, "tool_use")) "tool_calls" else sr.string;
                                dispatch(userdata, .{ .finish = reason });
                            }
                        }
                    }
                }
                return;
            }

            // message_stop, ping, content_block_stop: nada que hacer.
            return;
        }
    }

    const choices = parsed.object.get("choices") orelse return;
    if (choices != .array or choices.array.items.len == 0) return;
    const choice = choices.array.items[0];
    if (choice != .object) return;

    if (choice.object.get("finish_reason")) |fr| {
        if (fr == .string and fr.string.len > 0) {
            dispatch(userdata, .{ .finish = fr.string });
        }
    }

    const delta = choice.object.get("delta") orelse return;
    if (delta != .object) return;

    if (delta.object.get("tool_calls")) |tcs| {
        if (tcs == .array) {
            for (tcs.array.items) |tc| {
                if (tc != .object) continue;
                var index: usize = 0;
                var id: ?[]const u8 = null;
                var name: ?[]const u8 = null;
                var args: ?[]const u8 = null;
                if (tc.object.get("index")) |ix| {
                    if (ix == .integer and ix.integer >= 0) index = @intCast(ix.integer);
                }
                if (tc.object.get("id")) |v| {
                    if (v == .string and v.string.len > 0) id = v.string;
                }
                if (tc.object.get("function")) |f| {
                    if (f == .object) {
                        if (f.object.get("name")) |v| {
                            if (v == .string and v.string.len > 0) name = v.string;
                        }
                        if (f.object.get("arguments")) |v| {
                            if (v == .string) args = v.string;
                        }
                    }
                }
                dispatch(userdata, .{ .tool_frag = .{ .index = index, .id = id, .name = name, .args = args } });
            }
        }
    }

    const content = delta.object.get("content") orelse return;
    if (content != .string) return;
    if (content.string.len == 0) return;
    dispatch(userdata, .{ .delta = content.string });
}

// ── capa 2: StreamCtx (acumula tool_calls, filtra repetidos) ──
pub const StreamCtx = struct {
    gpa: std.mem.Allocator,
    user: Callbacks,
    kind: ProviderKind = .openai,
    parts: std.ArrayList(Part) = .empty,
    finish_count: usize = 0,
    /// Buffer de la línea SSE en curso (gpa-owned).
    line_buf: std.ArrayList(u8) = .empty,
    /// Un evento `data:` ya se vio completo.
    saw_done: bool = false,
    /// El request se cortó con ESC: hay texto parcial que sí se conserva.
    partial: bool = false,
    /// Primeros bytes del body de la respuesta. En un 200 es el preámbulo SSE
    /// (nunca se lee), pero en un 4xx/5xx es el JSON de error del server, que es
    /// lo único que explica por qué falló ("Insufficient account funds",
    /// "Model access is disabled"). Sin esto el usuario solo veía "HTTP 403".
    raw: [512]u8 = undefined,
    raw_len: usize = 0,

    const Part = struct {
        index: usize,
        id: std.ArrayList(u8) = .empty,
        name: std.ArrayList(u8) = .empty,
        args: std.ArrayList(u8) = .empty,
        emitted: bool = false,
    };

    /// Guarda los primeros bytes del body (ver el campo `raw`).
    pub fn noteRaw(self: *StreamCtx, chunk: []const u8) void {
        if (self.raw_len >= self.raw.len) return;
        const n = @min(chunk.len, self.raw.len - self.raw_len);
        @memcpy(self.raw[self.raw_len..][0..n], chunk[0..n]);
        self.raw_len += n;
    }

    /// Libera los buffers Y destruye el struct: se llama `destroy` y no
    /// `deinit` a propósito, porque se lleva el `self` consigo y un
    /// `defer ctx.deinit()` sobre un StreamCtx del stack revienta con
    /// "Invalid free". Solo se usa con los que salen de `gpa.create`.
    pub fn destroy(self: *StreamCtx) void {
        for (self.parts.items) |*p| {
            p.id.deinit(self.gpa);
            p.name.deinit(self.gpa);
            p.args.deinit(self.gpa);
        }
        self.parts.deinit(self.gpa);
        self.line_buf.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Consume un chunk del socket. Acumula en `line_buf` y despacha cada
    /// evento `data:` en cuanto su línea queda completa: así el texto llega a
    /// la UI token a token en vez de al final.
    pub fn feed(self: *StreamCtx, chunk: []const u8) !void {
        self.noteRaw(chunk);
        for (chunk) |c| {
            if (self.saw_done) return;
            if (c != '\n') {
                self.line_buf.append(self.gpa, c) catch continue;
                continue;
            }
            // OJO: `clearRetainingCapacity` hace `@memset(items, undefined)`,
            // así que hay que consumir la línea ANTES de limpiar el buffer.
            try self.handleLine(self.line_buf.items);
            self.line_buf.clearRetainingCapacity();
        }
    }

    /// Fin del stream: la última línea puede no venir con '\n'.
    pub fn finish(self: *StreamCtx) !void {
        if (self.line_buf.items.len > 0) {
            try self.handleLine(self.line_buf.items);
            self.line_buf.clearRetainingCapacity();
        }
    }

    fn handleLine(self: *StreamCtx, raw: []const u8) !void {
        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (line.len == 0) return;
        if (!std.mem.startsWith(u8, line, "data:")) return; // event:, id:, :
        const payload = std.mem.trim(u8, line[5..], " ");
        if (payload.len == 0) return;
        if (std.mem.eql(u8, payload, "[DONE]")) {
            self.saw_done = true;
            return;
        }
        dispatchEvents(self.gpa, payload, self, StreamCtx.dispatch) catch |err| switch (err) {
            error.ServerError => return error.ServerError,
            else => {}, // chunk malformado: saltar y seguir
        };
    }

    fn partFor(self: *StreamCtx, index: usize) !*Part {
        for (self.parts.items) |*p| {
            if (p.index == index) return p;
        }
        try self.parts.append(self.gpa, .{ .index = index });
        return &self.parts.items[self.parts.items.len - 1];
    }

    /// Slices devueltos válidos hasta el próximo streamChatCtx.
    pub fn toolCallsJson(self: *StreamCtx, arena: std.mem.Allocator) ![]const u8 {
        if (self.parts.items.len == 0) return "";
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(arena, "[");
        for (self.parts.items, 0..) |*p, i| {
            if (i > 0) try out.appendSlice(arena, ",");
            try out.appendSlice(arena, "{\"id\":\"");
            try out.appendSlice(arena, p.id.items);
            try out.appendSlice(arena, "\",\"type\":\"function\",\"function\":{\"name\":\"");
            try out.appendSlice(arena, p.name.items);
            try out.appendSlice(arena, "\",\"arguments\":\"");
            // arguments ya es JSON válido → escapamos como string para anidar.
            for (p.args.items) |c| {
                switch (c) {
                    '"' => try out.appendSlice(arena, "\\\""),
                    '\\' => try out.appendSlice(arena, "\\\\"),
                    '\n' => try out.appendSlice(arena, "\\n"),
                    '\r' => try out.appendSlice(arena, "\\r"),
                    '\t' => try out.appendSlice(arena, "\\t"),
                    else => try out.append(arena, c),
                }
            }
            try out.appendSlice(arena, "\"}}");
        }
        try out.appendSlice(arena, "]");
        return out.items;
    }

    fn dispatch(ud: ?*anyopaque, ev: Event) void {
        const self: *StreamCtx = @ptrCast(@alignCast(ud.?));
        switch (ev) {
            .usage => |u| {
                // Merge por campo: Anthropic reparte usage entre
                // message_start (input) y message_delta (output).
                if (u.prompt > 0) last_usage.prompt = u.prompt;
                if (u.cached > 0) last_usage.cached = u.cached;
                if (u.completion > 0) last_usage.completion = u.completion;
            },
            .delta => |d| self.user.onDelta(self.user.userdata, d),
            .finish => |r| {
                self.finish_count += 1;
                // Solo el primer finish interesa; los servers a veces
                // mandan finish en cada chunk final.
                if (self.finish_count == 1) {
                    if (self.user.onFinish) |f| f(self.user.userdata, r);
                }
            },
            .tool_frag => |frag| {
                const p = self.partFor(frag.index) catch return;
                if (frag.id) |v| {
                    if (p.id.items.len == 0) p.id.appendSlice(self.gpa, v) catch {};
                }
                if (frag.name) |v| {
                    if (p.name.items.len == 0) p.name.appendSlice(self.gpa, v) catch {};
                }
                if (frag.args) |v| {
                    p.args.appendSlice(self.gpa, v) catch {};
                }
                self.tryEmitTool(p);
            },
            .err => |msg| {
                // Un error embebido en un chunk 200 (algunos gateways lo hacen).
                if (self.user.onFinish) |f| f(self.user.userdata, msg);
            },
        }
    }

    /// Emite el tool call en cuanto sus argumentos son JSON válido.
    ///
    /// El trigger histórico era "el último byte es `}`", que colgaba el agent
    /// loop si el stream se cortaba antes del cierre o el modelo devolvía
    /// argumentos vacíos. Ahora se fuerza además en `finish`.
    fn tryEmitTool(self: *StreamCtx, p: *Part) void {
        if (p.emitted) return;
        if (p.id.items.len == 0 or p.name.items.len == 0) return;
        if (p.args.items.len == 0) return;

        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), p.args.items, .{});
        if (parsed) |_| {
            p.emitted = true;
            if (self.user.onToolCall) |f| {
                f(self.user.userdata, p.id.items, p.name.items, p.args.items);
            }
        } else |_| {}
    }

    /// Recupera tool calls que nunca llegaron a emitirse (stream cortado).
    /// Los que sí tienen args ejecutables se emiten ahora; el resto se descarta.
    fn flushPendingTools(self: *StreamCtx) void {
        for (self.parts.items) |*p| {
            if (p.emitted) continue;
            if (p.id.items.len == 0 or p.name.items.len == 0) continue;
            if (p.args.items.len == 0) {
                // Un tool sin argumentos es legal: se trata como objeto vacío.
                p.args.appendSlice(self.gpa, "{}") catch continue;
            }
            self.tryEmitTool(p);
        }
    }
};

pub const StreamResult = struct {
    ctx: *StreamCtx,
    /// True si el request se cortó con ESC (hay texto parcial).
    partial: bool = false,
};

/// Stream con acumulación de tool_calls. El caller hace `result.ctx.destroy()`.
pub fn streamChatCtx(
    gpa: std.mem.Allocator,
    http: *http_client.Http,
    url: []const u8,
    bearer: ?[]const u8,
    body: []u8,
    user_cb: Callbacks,
    kind: ProviderKind,
) !StreamResult {
    const ctx = try gpa.create(StreamCtx);
    ctx.* = .{ .gpa = gpa, .user = user_cb, .kind = kind };
    // OJO: en error hay que usar `deinit`, no `destroy`: el ctx puede tener
    // `parts` (tool calls acumuladas) y `line_buf` ya reservados.
    // Con `errdefer gpa.destroy(ctx)` esos dos se fugaban en cada 429/5xx.
    errdefer ctx.destroy();
    try streamRaw(gpa, http, url, bearer, body, ctx);
    return .{ .ctx = ctx, .partial = ctx.partial };
}

fn streamRaw(
    gpa: std.mem.Allocator,
    http: *http_client.Http,
    url: []const u8,
    bearer: ?[]const u8,
    body: []u8,
    ctx: *StreamCtx,
) !void {
    _ = gpa; // el parser vive en el ctx (line_buf)
    last_usage = .{}; // fresh por request: no arrastrar campos del turno anterior
    clearCancel();

    const Hdr = http_client.Http.ExtraHeader;
    var hdrs_buf: [2]Hdr = undefined;
    var n: usize = 0;
    // Anthropic no usa Bearer: x-api-key + versión de la API.
    var auth: ?[]const u8 = bearer;
    if (ctx.kind == .anthropic) {
        if (bearer) |k| {
            hdrs_buf[n] = .{ .name = "x-api-key", .value = k };
            n += 1;
        }
        hdrs_buf[n] = .{ .name = "anthropic-version", .value = "2023-06-01" };
        n += 1;
        auth = null;
    }

    const Feed = struct {
        fn onChunk(ud: ?*anyopaque, chunk: []const u8) anyerror!void {
            if (cancelled()) return error.Cancelled; // ESC corta la conexión
            const c = @as(*StreamCtx, @ptrCast(@alignCast(ud.?)));
            c.feed(chunk) catch |err| switch (err) {
                error.ServerError => return error.ServerError,
            };
        }
    };

    const res = http.streamPost(url, auth, body, hdrs_buf[0..n], Feed.onChunk, ctx) catch |err| {
        if (err == error.Cancelled) {
            ctx.partial = true; // el texto recibido hasta ESC se conserva
            return;
        }
        return err;
    };

    if (res.status != 200) {
        if (dbg_err()) {
            std.debug.print("[DBG] status={d} raw={s}\n", .{ res.status, ctx.raw[0..@min(ctx.raw_len, 240)] });
        }
        if (res.retry_after) |ra| retry_after_secs = ra;
        // Cada status tiene su propio error porque la ACCION que hay que hacer
        // es distinta, y "HTTP 403" no dice nada:
        //   400  peticion mala   -> no reintentar (repetirla no la arregla)
        //   401  key invalida    -> no reintentar, revisar la key
        //   402  sin creditos    -> no reintentar (antes reintentaba 3 veces!)
        //   403  acceso denegado -> casi siempre es el MODELO, no la key
        //   429/503 transitorios  -> reintentar
        const err: anyerror = switch (res.status) {
            429 => error.RateLimited,
            503 => error.Overloaded,
            401 => error.AuthFailed,
            402 => error.NoCredits,
            403 => error.Forbidden,
            // 404 casi siempre es "este modelo no existe (o tu cuenta no lo
            // tiene)". Reintentarlo 3 veces es esperar en balde.
            404 => error.ModelNotFound,
            // 400: la PETICIÓN está mal. Reintentar la misma cosa 3 veces son
            // 3,5 s de reloj y un turno que parece colgado. Y con el free-auto
            // encendido lo trata `noteTurnFailure`: este par se aparta y el
            // siguiente turno empieza en otro.
            400 => error.BadRequest,
            else => error.ServerError,
        };
        // El mensaje del server es lo que de verdad explica el fallo; se saca
        // de su JSON ("message":"...") y si no esta, se deja el status.
        last_error_len = 0;
        setServerMessage(ctx.raw[0..ctx.raw_len]);
        if (last_error_len == 0) {
            const fb = std.fmt.bufPrint(&last_error_buf, "HTTP {d}", .{res.status}) catch return err;
            last_error_len = fb.len;
        }
        return err;
    }
    if (dbg_err()) std.debug.print("[DBG] 200 raw={s}\n", .{ctx.raw[0..@min(ctx.raw_len, 240)]});
    retry_after_secs = null;
    if (res.retry_after) |ra| retry_after_secs = ra;
    ctx.finish() catch |err| switch (err) {
        error.ServerError => return error.ServerError,
    };
    // Un tool call a medio llegar al final del stream no se emitía nunca y
    // colgaba el agent loop: se fuerza la emisión de los que sí sean válidos.
    ctx.flushPendingTools();
}

/// Último `retry-after` visto en una respuesta de error (segundos).
pub var retry_after_secs: ?u16 = null;

/// Duerme `ms` milisegundos. Interrumpe pronto si se pulsa ESC.
///
/// ## Por qué `nanosleep` y no `Io.sleep`
///
/// Esto corre en el WORKER, y `Io.sleep` se lleva por delante el event loop del
/// `Io` que la TUI tiene en el mismo hilo de eventos: durante el backoff se
/// paran los redraws, el reloj de la franja se congela y los avisos se quedan
/// en `pending` sin pintar. Es el mismo problema que el ACP resolvió con `nap()`
/// y la misma solución: una syscall de verdad, sin tocar el `Io`.
///
/// Se duerme a trozos de 50ms para que ESC pueda cortar la espera.
pub fn sleepMs(ms_arg: u64) void {
    if (ms_arg == 0) return;
    // Techo: no dormir medio minuto seguido.
    var left: u64 = @min(ms_arg, 30_000);
    while (left > 0) {
        if (cancel_current.load(.seq_cst)) return;
        const chunk = @min(left, 50);
        acp.nap(chunk);
        left -= chunk;
    }
}

/// xorshift para el jitter del backoff (no necesita estado global seguro:
/// solo lo usa el worker que ya está serializando sus requests).
var rng_state: u64 = 0x9E3779B97F4A7C15;

pub fn randBelow(n: u64) u64 {
    if (n == 0) return 0;
    var x = rng_state;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    rng_state = x;
    return x % n;
}

/// Procesa un body SSE completo de una sola vez (tests y paths sin socket).
/// Usa el mismo parser incremental que el stream real, alimentándolo entero.
pub fn scanSse(gpa: std.mem.Allocator, sse_body: []const u8, ctx: *StreamCtx) !void {
    _ = gpa;
    ctx.line_buf.clearRetainingCapacity();
    // Un SSE malformado no tumba el parseo; solo un error del server
    // (payload con `{"error":...}`) es fatal.
    ctx.feed(sse_body) catch |err| switch (err) {
        error.ServerError => return error.ServerError,
    };
    ctx.finish() catch |err| switch (err) {
        error.ServerError => return error.ServerError,
    };
    ctx.flushPendingTools();
}

/// Stream simple sin tool_calls (CLI, tests). El caller libera `ctx`.
pub fn streamChat(
    gpa: std.mem.Allocator,
    http: *http_client.Http,
    url: []const u8,
    bearer: ?[]const u8,
    body: []u8,
    cb: Callbacks,
    kind: ProviderKind,
) !void {
    const ctx = try gpa.create(StreamCtx);
    ctx.* = .{ .gpa = gpa, .user = cb, .kind = kind };
    defer ctx.destroy(); // libera parts y destruye el struct
    try streamRaw(gpa, http, url, bearer, body, ctx);
}

// ── body builders ────────────────────────────────────────────

/// Body con historial completo (multi-turno + tools), según provider.
pub fn buildBodyMessages(
    buf: []u8,
    model: []const u8,
    messages: []const ChatMessage,
    effort: Effort,
    tools_json: []const u8,
    kind: ProviderKind,
) ![]u8 {
    return switch (kind) {
        .openai => buildBodyOpenAI(buf, model, messages, effort, tools_json),
        .anthropic => buildBodyAnthropic(buf, model, messages, effort, tools_json),
    };
}

/// Formato OpenAI (chat/completions). Sin deps de alloc.
fn buildBodyOpenAI(
    buf: []u8,
    model: []const u8,
    messages: []const ChatMessage,
    effort: Effort,
    tools_json: []const u8,
) ![]u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.writeAll("{\"model\":\"");
    try jsonEscape(&w, model);
    try w.writeAll("\",\"messages\":[");
    for (messages, 0..) |m, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"role\":\"");
        try w.writeAll(m.role);
        try w.writeAll("\",");
        if (std.mem.eql(u8, m.role, "tool")) {
            try w.writeAll("\"tool_call_id\":\"");
            try jsonEscape(&w, m.tool_call_id orelse "");
            try w.writeAll("\",\"content\":\"");
        } else {
            try w.writeAll("\"content\":\"");
        }
        try jsonEscape(&w, m.content);
        try w.writeAll("\"");
        if (m.tool_calls_json) |tj| {
            if (tj.len > 0) {
                try w.writeAll(",\"tool_calls\":");
                try w.writeAll(tj);
            }
        }
        try w.writeAll("}");
    }
    try w.writeAll("],\"stream\":true,\"stream_options\":{\"include_usage\":true}");

    // Los o-series / gpt-5 de OpenAI rechazan `max_tokens` (piden
    // `max_completion_tokens`) y no aceptan `temperature`. Mandar el campo
    // equivocado es un 400 directo, así que se ramifica por familia.
    const fam = familyForModel(model);
    switch (fam) {
        .openai_reasoning => {
            try w.writeAll(",\"max_completion_tokens\":");
            try w.print("{d}", .{@intFromEnum(effort)});
        },
        else => {
            try w.writeAll(",\"max_tokens\":");
            try w.print("{d}", .{@intFromEnum(effort)});
        },
    }
    if (fam == .openai_reasoning) {
        // low/medium/high mapeado al vocabulario de OpenAI.
        const re: []const u8 = switch (effort) {
            .low => "low",
            .high => "high",
            .medium => "medium",
        };
        try w.writeAll(",\"reasoning_effort\":\"");
        try w.writeAll(re);
        try w.writeAll("\"");
    }

    // tools FIRST after messages? No: tools va fuera de messages (nivel raíz),
    // y su posición estable en el JSON ayuda al caching del prefijo del provider.
    if (tools_json.len > 0) {
        try w.writeAll(",\"tools\":");
        try w.writeAll(tools_json);
    }
    try w.writeAll("}");
    return w.buffered();
}

/// Compat: mensaje único (CLI headless).
pub fn buildBody(buf: []u8, model: []const u8, user_text: []const u8, effort: Effort) ![]u8 {
    const msgs = [_]ChatMessage{.{ .role = "user", .content = user_text }};
    return buildBodyMessages(buf, model, &msgs, effort, "", .openai);
}

/// Formato Anthropic Messages API:
///  - system y tools van a nivel raíz, con breakpoints `cache_control`
///    (prompt caching estilo Claude Code: el prefijo estable —tools+system+
///    historial— se sirve de cache del server entre turnos).
///  - assistant.tool_calls (formato OpenAI) → bloques `tool_use`.
///  - runs de mensajes role=tool → UN mensaje user con bloques `tool_result`.
fn buildBodyAnthropic(
    buf: []u8,
    model: []const u8,
    messages: []const ChatMessage,
    effort: Effort,
    tools_json: []const u8,
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var w: std.Io.Writer = .fixed(buf);
    try w.writeAll("{\"model\":\"");
    try jsonEscape(&w, model);
    // Anthropic EXIGE max_tokens (no tiene default). Además, con thinking
    // extended el presupuesto de razonamiento va aparte y tiene que ser
    // MENOR que max_tokens, si no el server responde 400.
    const think_budget: u32 = switch (effort) {
        .low => 1024,
        .medium => 4096,
        .high => 16384,
    };
    const max_tok: u32 = @intFromEnum(effort);
    try w.print("\",\"max_tokens\":{d},\"stream\":true", .{max_tok});
    if (max_tok > think_budget) {
        try w.print(",\"thinking\":{{\"type\":\"enabled\",\"budget_tokens\":{d}}}", .{think_budget});
    }

    // tools: {type,function:{name,description,parameters}} → {name,description,input_schema}
    if (tools_json.len > 0) {
        const pt = std.json.parseFromSliceLeaky(std.json.Value, arena, tools_json, .{}) catch null;
        if (pt) |pv| {
            if (pv == .array and pv.array.items.len > 0) {
                try w.writeAll(",\"tools\":[");
                var emitted: usize = 0;
                for (pv.array.items, 0..) |t, ti| {
                    if (t != .object) continue;
                    // Formato OpenAI: {type:function, function:{name,...}}.
                    // También acepta forma plana {name, description, parameters}.
                    var name_v: ?std.json.Value = t.object.get("name");
                    var desc_v: ?std.json.Value = t.object.get("description");
                    var params_v: ?std.json.Value = t.object.get("parameters");
                    if (t.object.get("function")) |f| {
                        if (f == .object) {
                            if (name_v == null) name_v = f.object.get("name");
                            if (desc_v == null) desc_v = f.object.get("description");
                            if (params_v == null) params_v = f.object.get("parameters");
                        }
                    }
                    const name = name_v orelse continue;
                    if (name != .string) continue;
                    if (emitted > 0) try w.writeAll(",");
                    emitted += 1;
                    try w.writeAll("{\"name\":\"");
                    try jsonEscape(&w, name.string);
                    try w.writeAll("\",\"description\":\"");
                    if (desc_v) |d| {
                        if (d == .string) try jsonEscape(&w, d.string);
                    }
                    try w.writeAll("\",\"input_schema\":");
                    if (params_v) |p| {
                        try writeJsonValue(&w, p);
                    } else {
                        try w.writeAll("{\"type\":\"object\"}");
                    }
                    // Breakpoint en la ÚLTIMA tool: tools+system son estables,
                    // así todo ese prefijo queda cacheado entre turnos.
                    if (ti == pv.array.items.len - 1) {
                        try w.writeAll(",\"cache_control\":{\"type\":\"ephemeral\"}");
                    }
                    try w.writeAll("}");
                }
                try w.writeAll("]");
            }
        }
    }

    var start: usize = 0;
    if (messages.len > 0 and std.mem.eql(u8, messages[0].role, "system")) {
        try w.writeAll(",\"system\":[{\"type\":\"text\",\"text\":\"");
        try jsonEscape(&w, messages[0].content);
        try w.writeAll("\",\"cache_control\":{\"type\":\"ephemeral\"}}]");
        start = 1;
    }

    try w.writeAll(",\"messages\":[");
    var first = true;
    var i = start;
    while (i < messages.len) {
        const m = messages[i];
        const has_tc = m.tool_calls_json != null and m.tool_calls_json.?.len > 0;
        if (m.content.len == 0 and !has_tc and !std.mem.eql(u8, m.role, "tool")) {
            i += 1;
            continue; // Anthropic rechaza contenido vacío
        }

        if (std.mem.eql(u8, m.role, "tool")) {
            // Run de resultados consecutivos → UN mensaje user con tool_result.
            if (!first) try w.writeAll(",");
            first = false;
            try w.writeAll("{\"role\":\"user\",\"content\":[");
            var fb = true;
            while (i < messages.len and std.mem.eql(u8, messages[i].role, "tool")) : (i += 1) {
                if (!fb) try w.writeAll(",");
                fb = false;
                try w.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":\"");
                try jsonEscape(&w, messages[i].tool_call_id orelse "");
                try w.writeAll("\",\"content\":\"");
                try jsonEscape(&w, messages[i].content);
                try w.writeAll("\"");
                // Breakpoint al final del historial: el próximo turno reutiliza
                // de cache TODO el prefijo (tools+system+mensajes).
                if (i == messages.len - 1) try w.writeAll(",\"cache_control\":{\"type\":\"ephemeral\"}");
                try w.writeAll("}");
            }
            try w.writeAll("]}");
            continue;
        }

        if (!first) try w.writeAll(",");
        first = false;
        try w.writeAll("{\"role\":\"");
        try w.writeAll(m.role); // "user" | "assistant" (system solo en 0)
        try w.writeAll("\",\"content\":");

        if (has_tc) {
            try w.writeAll("[");
            var wrote_text = false;
            if (m.content.len > 0) {
                try w.writeAll("{\"type\":\"text\",\"text\":\"");
                try jsonEscape(&w, m.content);
                try w.writeAll("\"}");
                wrote_text = true;
            }
            const pcs = std.json.parseFromSliceLeaky(std.json.Value, arena, m.tool_calls_json.?, .{}) catch null;
            if (pcs) |pv| {
                if (pv == .array) {
                    for (pv.array.items, 0..) |tc, ti| {
                        if (tc != .object) continue;
                        const fnv = tc.object.get("function") orelse continue;
                        if (fnv != .object) continue;
                        const idv = tc.object.get("id");
                        const namev = fnv.object.get("name");
                        if (idv == null or idv.? != .string) continue;
                        if (namev == null or namev.? != .string) continue;
                        if (wrote_text) try w.writeAll(",");
                        wrote_text = true;
                        try w.writeAll("{\"type\":\"tool_use\",\"id\":\"");
                        try jsonEscape(&w, idv.?.string);
                        try w.writeAll("\",\"name\":\"");
                        try jsonEscape(&w, namev.?.string);
                        try w.writeAll("\",\"input\":");
                        var input_written = false;
                        if (fnv.object.get("arguments")) |av| {
                            if (av == .string) {
                                const obj = std.json.parseFromSliceLeaky(std.json.Value, arena, av.string, .{}) catch null;
                                if (obj) |ov| {
                                    if (ov == .object) {
                                        try writeJsonValue(&w, ov);
                                        input_written = true;
                                    }
                                }
                            }
                        }
                        if (!input_written) try w.writeAll("{}");
                        if (ti == pv.array.items.len - 1 and i == messages.len - 1) {
                            try w.writeAll(",\"cache_control\":{\"type\":\"ephemeral\"}");
                        }
                        try w.writeAll("}");
                    }
                }
            }
            if (!wrote_text) {
                try w.writeAll("{\"type\":\"text\",\"text\":\"\"}");
            }
            try w.writeAll("]");
        } else if (i == messages.len - 1) {
            // Último mensaje: forma bloque para anclar el breakpoint de cache.
            try w.writeAll("[{\"type\":\"text\",\"text\":\"");
            try jsonEscape(&w, m.content);
            try w.writeAll("\",\"cache_control\":{\"type\":\"ephemeral\"}}]");
        } else {
            try w.writeAll("\"");
            try jsonEscape(&w, m.content);
            try w.writeAll("\"");
        }
        try w.writeAll("}");
        i += 1;
    }
    try w.writeAll("]}");
    return w.buffered();
}

/// Serializa std.json.Value a JSON compacto (subconjunto propio, sin
/// depender de la API de stringify de std).
fn writeJsonValue(w: *std.Io.Writer, v: std.json.Value) !void {
    switch (v) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |n| try w.print("{d}", .{n}),
        .float => |f| try w.print("{d}", .{f}),
        .number_string, .string => |s| {
            try w.writeByte('"');
            try jsonEscape(w, s);
            try w.writeByte('"');
        },
        .array => |a| {
            try w.writeAll("[");
            for (a.items, 0..) |item, ai| {
                if (ai > 0) try w.writeAll(",");
                try writeJsonValue(w, item);
            }
            try w.writeAll("]");
        },
        .object => |o| {
            try w.writeAll("{");
            var it = o.iterator();
            var first = true;
            while (it.next()) |e| {
                if (!first) try w.writeAll(",");
                first = false;
                try w.writeByte('"');
                try jsonEscape(w, e.key_ptr.*);
                try w.writeAll("\":");
                try writeJsonValue(w, e.value_ptr.*);
            }
            try w.writeAll("}");
        },
    }
}

fn jsonEscape(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
}

// ── tests herméticos ─────────────────────────────────────────
test "scanSse junta deltas y termina en [DONE]" {
    const sse =
        "data: {\"choices\":[{\"delta\":{\"content\":\"Hola \"}}]}\n" ++
        "\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"mundo\"}}]}\n" ++
        "\n" ++
        "data: [DONE]\n" ++
        "\n";

    const Collector = struct {
        text: std.ArrayList(u8) = .empty,
        fn onDelta(ud: ?*anyopaque, delta: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            self.text.appendSlice(std.testing.allocator, delta) catch {};
        }
    };
    var col = Collector{};
    defer col.text.deinit(std.testing.allocator);

    const ctx = try std.testing.allocator.create(StreamCtx);
    ctx.* = .{
        .gpa = std.testing.allocator,
        .user = .{ .userdata = &col, .onDelta = Collector.onDelta },
    };
    defer ctx.destroy();

    try scanSse(std.testing.allocator, sse, ctx);
    try std.testing.expectEqualStrings("Hola mundo", col.text.items);
}

test "tool_call fragmentado se acumula y emite una vez" {
    const Collector = struct {
        calls: usize = 0,
        last_name: []const u8 = "",
        last_args: []const u8 = "",
        fn onToolCall(ud: ?*anyopaque, id: []const u8, name: []const u8, args: []const u8) void {
            _ = id;
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            self.calls += 1;
            self.last_name = name;
            self.last_args = args;
        }
        fn onDelta(_: ?*anyopaque, _: []const u8) void {}
    };
    var col = Collector{};

    const ctx = try std.testing.allocator.create(StreamCtx);
    ctx.* = .{
        .gpa = std.testing.allocator,
        .user = .{ .userdata = &col, .onDelta = Collector.onDelta, .onToolCall = Collector.onToolCall },
    };
    defer ctx.destroy();

    // Fragmentos: id+name primero, args en 3 pedazos (con llave adentro de
    // un string para verificar que no confunde el parseo).
    const sse =
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"grep\",\"arguments\":\"\"}}]}}]}\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"pattern\\\":\\\"a{b\\\"\"}}]}}]}\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\",\\\"x\\\":\\\"}\\\"\"}}]}}]}\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"}\"}}]}}]}\n" ++
        "data: [DONE]\n\n";

    // args completos: {"pattern":"a{b","x":"}"}
    try scanSse(std.testing.allocator, sse, ctx);

    try std.testing.expectEqual(@as(usize, 1), col.calls);
    try std.testing.expectEqualStrings("grep", col.last_name);
    try std.testing.expectEqualStrings("{\"pattern\":\"a{b\",\"x\":\"}\"}", col.last_args);
}

test "detecta error del server" {
    const ctx = try std.testing.allocator.create(StreamCtx);
    ctx.* = .{ .gpa = std.testing.allocator, .user = .{} };
    defer ctx.destroy();
    try std.testing.expectError(
        error.ServerError,
        scanSse(std.testing.allocator, "data: {\"error\":{\"type\":\"x\",\"message\":\"no\"}}\n\n", ctx),
    );
    try std.testing.expectEqualStrings("no", lastErrorBody());
}

test "buildBody escapa JSON y fija max_tokens" {
    var buf: [512]u8 = undefined;
    const body = try buildBody(&buf, "m1", "linea\ncon \"quotes\"", .medium);
    try std.testing.expectEqualStrings(
        "{\"model\":\"m1\",\"messages\":[{\"role\":\"user\",\"content\":\"linea\\ncon \\\"quotes\\\"\"}],\"stream\":true,\"stream_options\":{\"include_usage\":true},\"max_tokens\":4096}",
        body,
    );
}

test "buildBodyMessages con tool result y tools" {
    var buf: [1024]u8 = undefined;
    const msgs = [_]ChatMessage{
        .{ .role = "user", .content = "lee a.zig" },
        .{ .role = "assistant", .content = "", .tool_calls_json = "[{\"id\":\"c1\",\"type\":\"function\",\"function\":{\"name\":\"read\",\"arguments\":\"{}\"}}]" },
        .{ .role = "tool", .content = "ok", .tool_call_id = "c1" },
    };
    const body = try buildBodyMessages(&buf, "m", &msgs, .low, "[{\"type\":\"function\",\"function\":{\"name\":\"read\"}}]", .openai);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_call_id\":\"c1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":1024") != null);
}

test "scanSse parsea eventos Anthropic (delta, tool_use y usage)" {
    const Collector = struct {
        text: std.ArrayList(u8) = .empty,
        calls: usize = 0,
        last_name: []const u8 = "",
        last_args: []const u8 = "",
        fn onDelta(ud: ?*anyopaque, delta: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            self.text.appendSlice(std.testing.allocator, delta) catch {};
        }
        fn onToolCall(ud: ?*anyopaque, id: []const u8, name: []const u8, args: []const u8) void {
            _ = id;
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            self.calls += 1;
            self.last_name = name;
            self.last_args = args;
        }
    };
    var col = Collector{};
    defer col.text.deinit(std.testing.allocator);

    last_usage = .{};

    const ctx = try std.testing.allocator.create(StreamCtx);
    ctx.* = .{
        .gpa = std.testing.allocator,
        .user = .{ .userdata = &col, .onDelta = Collector.onDelta, .onToolCall = Collector.onToolCall },
    };
    defer ctx.destroy();

    const sse =
        "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":120,\"cache_read_input_tokens\":100}}}\n\n" ++
        "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"grep\"}}\n\n" ++
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"pattern\\\":\"}}\n\n" ++
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\"x\\\"}\"}}\n\n" ++
        "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":42}}\n\n" ++
        "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n";

    try scanSse(std.testing.allocator, sse, ctx);

    try std.testing.expectEqual(@as(usize, 1), col.calls);
    try std.testing.expectEqualStrings("grep", col.last_name);
    try std.testing.expectEqualStrings("{\"pattern\":\"x\"}", col.last_args);
    try std.testing.expectEqual(@as(i64, 120), last_usage.prompt);
    try std.testing.expectEqual(@as(i64, 100), last_usage.cached);
    try std.testing.expectEqual(@as(i64, 42), last_usage.completion);
}

test "buildBodyAnthropic convierte tool_calls/results y ancla cache_control" {
    var buf: [2048]u8 = undefined;
    const msgs = [_]ChatMessage{
        .{ .role = "system", .content = "be terse" },
        .{ .role = "user", .content = "busca foo" },
        .{ .role = "assistant", .content = "", .tool_calls_json = "[{\"id\":\"c1\",\"type\":\"function\",\"function\":{\"name\":\"grep\",\"arguments\":\"{\\\"pattern\\\":\\\"foo\\\"}\"}}]" },
        .{ .role = "tool", .content = "src/a.zig:1:foo", .tool_call_id = "c1" },
    };
    const tools = "[{\"type\":\"function\",\"function\":{\"name\":\"read\",\"description\":\"d\",\"parameters\":{\"type\":\"object\"}}}]";
    const body = try buildBodyMessages(&buf, "claude-test", &msgs, .low, tools, .anthropic);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"input_schema\":{\"type\":\"object\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"tool_use\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_use_id\":\"c1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"input\":{\"pattern\":\"foo\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"system\":[{\"type\":\"text\",\"text\":\"be terse\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":1024") != null);
    // El role "tool" no existe en Anthropic: van como tool_result en user.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"tool\"") == null);
    // 3 breakpoints: system, última tool y último mensaje.
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, body, "\"cache_control\":{\"type\":\"ephemeral\"}"));
}

test "feed: un evento partido a mitad de línea se entrega entero" {
    const Collector = struct {
        text: std.ArrayList(u8) = .empty,
        fn onDelta(ud: ?*anyopaque, delta: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            self.text.appendSlice(std.testing.allocator, delta) catch {};
        }
    };
    var col = Collector{};
    defer col.text.deinit(std.testing.allocator);

    const ctx = try std.testing.allocator.create(StreamCtx);
    ctx.* = .{
        .gpa = std.testing.allocator,
        .user = .{ .userdata = &col, .onDelta = Collector.onDelta },
    };
    defer ctx.destroy();

    // Un solo evento, partido en 5 trozos arbitrarios (en mitad de línea y
    // entre el `\n` y el siguiente `data:`).
    const full = "data: {\"choices\":[{\"delta\":{\"content\":\"Hola mundo\"}}]}\n\ndata: [DONE]\n\n";
    const cuts = [_]usize{ 7, 23, 51, 52, full.len };
    var prev: usize = 0;
    for (cuts) |cut| {
        try ctx.feed(full[prev..cut]);
        prev = cut;
    }
    try ctx.finish();
    try std.testing.expectEqualStrings("Hola mundo", col.text.items);
}

test "feed: un payload partido a mitad de UTF-8 no se corrompe" {
    const Collector = struct {
        text: std.ArrayList(u8) = .empty,
        fn onDelta(ud: ?*anyopaque, delta: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            self.text.appendSlice(std.testing.allocator, delta) catch {};
        }
    };
    var col = Collector{};
    defer col.text.deinit(std.testing.allocator);

    const ctx = try std.testing.allocator.create(StreamCtx);
    ctx.* = .{
        .gpa = std.testing.allocator,
        .user = .{ .userdata = &col, .onDelta = Collector.onDelta },
    };
    defer ctx.destroy();

    // "ñ" son 2 bytes y "✓" son 3: los cortes caen dentro de esos bytes.
    const full = "data: {\"choices\":[{\"delta\":{\"content\":\"a\u{00f1}\u{2713}b\"}}]}\n\n";
    for (full, 0..) |_, i| {
        try ctx.feed(full[i .. i + 1]); // un byte por chunk, el peor caso
    }
    try ctx.finish();
    try std.testing.expectEqualStrings("a\u{00f1}\u{2713}b", col.text.items);
}

test "feed: un tool call cortado a mitad de args se emite al finish" {
    // Regresión: con el trigger antiguo ("último byte == '}'") un stream
    // cortado antes del cierre colgaba el agent loop para siempre.
    const Collector = struct {
        calls: usize = 0,
        last_name: []const u8 = "",
        last_args: []const u8 = "",
        fn onToolCall(ud: ?*anyopaque, _: []const u8, name: []const u8, args: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            self.calls += 1;
            self.last_name = name;
            self.last_args = args;
        }
        fn onDelta(_: ?*anyopaque, _: []const u8) void {}
    };
    var col = Collector{};

    const ctx = try std.testing.allocator.create(StreamCtx);
    ctx.* = .{
        .gpa = std.testing.allocator,
        .user = .{ .userdata = &col, .onToolCall = Collector.onToolCall },
    };
    defer ctx.destroy();

    // Args que NO terminan en '}' (la conexión se corta justo después).
    const sse =
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"a.txt\\\"}\"}}]}}]}\n\n";
    try scanSse(std.testing.allocator, sse, ctx);

    try std.testing.expectEqual(@as(usize, 1), col.calls);
    try std.testing.expectEqualStrings("read", col.last_name);
    try std.testing.expectEqualStrings("{\"path\":\"a.txt\"}", col.last_args);
}

test "feed: un tool sin argumentos se trata como objeto vacío" {
    const Collector = struct {
        calls: usize = 0,
        last_args: []const u8 = "",
        fn onToolCall(ud: ?*anyopaque, _: []const u8, _: []const u8, args: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            self.calls += 1;
            self.last_args = args;
        }
        fn onDelta(_: ?*anyopaque, _: []const u8) void {}
    };
    var col = Collector{};

    const ctx = try std.testing.allocator.create(StreamCtx);
    ctx.* = .{
        .gpa = std.testing.allocator,
        .user = .{ .userdata = &col, .onToolCall = Collector.onToolCall },
    };
    defer ctx.destroy();

    // `list_files` sin argumentos: el server manda "arguments":"".
    const sse =
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"list_files\",\"arguments\":\"\"}}]}}]}\n\n";
    try scanSse(std.testing.allocator, sse, ctx);

    try std.testing.expectEqual(@as(usize, 1), col.calls);
    try std.testing.expectEqualStrings("{}", col.last_args);
}

test "buildBodyOpenAI: o-series usa max_completion_tokens + reasoning_effort" {
    var buf: [64 * 1024]u8 = undefined;
    const msgs = [_]ChatMessage{.{ .role = "user", .content = "hi" }};

    // gpt-5: `max_tokens` da 400 en la API de OpenAI.
    const body = try buildBodyMessages(&buf, "gpt-5", &msgs, .medium, "", .openai);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_completion_tokens\":4096") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"medium\"") != null);
    // Los modelos de razonamiento no aceptan temperature.
    try std.testing.expect(std.mem.indexOf(u8, body, "temperature") == null);

    // o3 también entra por la rama de razonamiento.
    const o3 = try buildBodyMessages(&buf, "o3-mini", &msgs, .high, "", .openai);
    try std.testing.expect(std.mem.indexOf(u8, o3, "\"max_completion_tokens\":16384") != null);
    try std.testing.expect(std.mem.indexOf(u8, o3, "\"reasoning_effort\":\"high\"") != null);
}

test "buildBodyOpenAI: modelo normal conserva max_tokens" {
    var buf: [64 * 1024]u8 = undefined;
    const msgs = [_]ChatMessage{.{ .role = "user", .content = "hi" }};

    const body = try buildBodyMessages(&buf, "kimi-k2.6", &msgs, .low, "", .openai);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":1024") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "max_completion_tokens") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "reasoning_effort") == null);
}

test "buildBodyAnthropic: thinking con budget menor que max_tokens" {
    var buf: [64 * 1024]u8 = undefined;
    const msgs = [_]ChatMessage{.{ .role = "user", .content = "hi" }};

    // effort=high → max_tokens 16384 > budget 16384? No: debe ser estrictamente
    // menor, así que con high no se manda thinking.
    const high = try buildBodyMessages(&buf, "claude-sonnet-4-5", &msgs, .high, "", .anthropic);
    try std.testing.expect(std.mem.indexOf(u8, high, "\"max_tokens\":16384") != null);
    try std.testing.expect(std.mem.indexOf(u8, high, "thinking") == null);

    // effort=medium → max_tokens 4096 > budget 4096, tampoco.
    const med = try buildBodyMessages(&buf, "claude-sonnet-4-5", &msgs, .medium, "", .anthropic);
    try std.testing.expect(std.mem.indexOf(u8, med, "thinking") == null);

    // effort=low → max_tokens 1024 == budget 1024: tampoco (debe ser <).
    const low = try buildBodyMessages(&buf, "claude-sonnet-4-5", &msgs, .low, "", .anthropic);
    try std.testing.expect(std.mem.indexOf(u8, low, "thinking") == null);

    // El presupuesto de thinking nunca puede igualar max_tokens: Anthropic
    // exige budget_tokens < max_tokens.
    try std.testing.expect(!hasBadThinkingBudget(high));
    try std.testing.expect(!hasBadThinkingBudget(med));
    try std.testing.expect(!hasBadThinkingBudget(low));
}

test "familyForModel detecta razonamiento solo en o-series/gpt-5" {
    try std.testing.expectEqual(Family.openai_reasoning, familyForModel("gpt-5"));
    try std.testing.expectEqual(Family.openai_reasoning, familyForModel("gpt-5-mini"));
    try std.testing.expectEqual(Family.openai_reasoning, familyForModel("o3"));
    try std.testing.expectEqual(Family.openai_reasoning, familyForModel("o4-mini"));
    try std.testing.expectEqual(Family.generic_openai, familyForModel("gpt-4o"));
    try std.testing.expectEqual(Family.generic_openai, familyForModel("kimi-k2.6"));
    try std.testing.expectEqual(Family.generic_openai, familyForModel("claude-sonnet-4-5"));
}

/// Test helper: ¿el body tiene un budget de thinking >= max_tokens?
/// Anthropic rechaza esa combinación, así que sirve de red de seguridad.
fn hasBadThinkingBudget(body: []const u8) bool {
    const ti = std.mem.indexOf(u8, body, "\"thinking\"") orelse return false;
    const bt = std.mem.indexOfScalarPos(u8, body, ti, '{') orelse return false;
    const bpos = std.mem.indexOfPos(u8, body, bt, "budget_tokens\":") orelse return false;
    const budget = std.fmt.parseInt(u32, std.mem.trim(u8, body[bpos + 14 ..], "}"), 10) catch return false;
    const mpos = std.mem.indexOf(u8, body, "\"max_tokens\":") orelse return false;
    const max_tok = std.fmt.parseInt(u32, std.mem.trim(u8, body[mpos + 13 ..], ","), 10) catch return false;
    return budget >= max_tok;
}

test "feed: una línea SSE más grande que cualquier buffer se reensambla" {
    // Regresión: `takeDelimiter` fallaba con StreamTooLong si la línea no
    // cabía en el buffer de transferencia y el stream moría a mitad. El
    // parser tiene que poder recomponerla de many pieces.
    const Collector = struct {
        text: std.ArrayList(u8) = .empty,
        fn onDelta(ud: ?*anyopaque, delta: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            self.text.appendSlice(std.testing.allocator, delta) catch {};
        }
    };
    var col = Collector{};
    defer col.text.deinit(std.testing.allocator);

    const ctx = try std.testing.allocator.create(StreamCtx);
    ctx.* = .{
        .gpa = std.testing.allocator,
        .user = .{ .userdata = &col, .onDelta = Collector.onDelta },
    };
    defer ctx.destroy();

    // Payload de ~200 KB repartido en trozos de 8 KB: es lo que pasa de
    // cuando el modelo devuelve un tool call enorme o un fragmento largo.
    const payload_len: usize = 200_000;
    const prefix = "data: {\"choices\":[{\"delta\":{\"content\":\"";
    const suffix = "\"}}]}\n\ndata: [DONE]\n\n";

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const total = prefix.len + payload_len + suffix.len;
    const line = try arena.alloc(u8, total);
    @memcpy(line[0..prefix.len], prefix);
    @memset(line[prefix.len .. prefix.len + payload_len], 'x');
    @memcpy(line[prefix.len + payload_len ..], suffix);

    // Troceado agresivo, sin respetar líneas.
    var off: usize = 0;
    while (off < line.len) {
        const n = @min(8192, line.len - off);
        try ctx.feed(line[off .. off + n]);
        off += n;
    }
    try ctx.finish();

    try std.testing.expectEqual(payload_len, col.text.items.len);
    try std.testing.expectEqual(@as(u8, 'x'), col.text.items[0]);
    try std.testing.expectEqual(@as(u8, 'x'), col.text.items[payload_len - 1]);
}

test "StreamCtx.deinit no fuga con parts y line_buf poblados" {
    // El path de error de `streamChatCtx` debe llamar a `deinit` (no
    // `destroy`), porque para cuando un request falla el ctx ya tiene
    // tool calls acumuladas y buffer de línea. Con `destroy` se fugaban.
    const ctx = try std.testing.allocator.create(StreamCtx);
    ctx.* = .{
        .gpa = std.testing.allocator,
        .user = .{},
        .line_buf = .empty,
    };
    // Simula trabajo real: una tool call a medias y una línea SSE a medias.
    try ctx.line_buf.appendSlice(std.testing.allocator, "data: {\"a\":1}");
    const p = try ctx.partFor(0);
    try p.id.appendSlice(std.testing.allocator, "call_1");
    try p.name.appendSlice(std.testing.allocator, "read");
    try p.args.appendSlice(std.testing.allocator, "{\"path\":\"x\"}");
    try p.args.append(std.testing.allocator, '}');

    // `streamChatCtx` llama a esto en su `errdefer`; el allocator de tests
    // falla si algo queda sin liberar.
    ctx.destroy();
}

test "setServerMessage: saca el message del JSON de error" {
    // Es lo que convierte un inútil "HTTP 403" en "Model access is disabled".
    setServerMessage(
        \\{"error":{"type":"server_error","message":"Upstream request failed: Model access is disabled"}}
    );
    try std.testing.expectEqualStrings("Upstream request failed: Model access is disabled", lastErrorBody());

    setServerMessage(
        \\{"error":{"type":"server_error","message":"Upstream request failed: Insufficient account funds"}}
    );
    try std.testing.expectEqualStrings("Upstream request failed: Insufficient account funds", lastErrorBody());
}

test "setServerMessage: aguanta basura sin desbordar" {
    // Sin "message" (JSON raro), vacío, sin abrir comilla, y una cadena
    // enorme: en ningún caso puede sobrepasar el buffer ni dejar basura.
    setServerMessage("");
    try std.testing.expectEqual(@as(usize, 0), last_error_len);
    setServerMessage("<html>502 Bad Gateway</html>");
    try std.testing.expectEqual(@as(usize, 0), last_error_len);
    setServerMessage("{\"message\": 42}");
    try std.testing.expectEqual(@as(usize, 0), last_error_len);

    const huge = "{\"message\":\"" ++ "x" ** 900 ++ "\"}";
    setServerMessage(huge);
    try std.testing.expect(last_error_len > 0 and last_error_len < last_error_buf.len);
}

test "setServerMessage: desescapa comilla y barra" {
    setServerMessage("{\"message\":\"say \\\"hi\\\" \\\\o/\"}");
    try std.testing.expectEqualStrings("say \"hi\" \\o/", lastErrorBody());
}

test "noteRaw: guarda solo los primeros bytes, sin desbordar" {
    // El buffer es 512: sirve para el JSON de error corto, y si el body es
    // gigante (un HTML de error de un proxy) se corta sin reventar nada.
    // OJO: `destroy` se lleva el struct, así que tiene que estar en el heap
    // (por eso se pide con `gpa.create` y no como valor local).
    const ctx = try std.testing.allocator.create(StreamCtx);
    ctx.* = .{ .gpa = std.testing.allocator, .user = .{} };
    ctx.noteRaw("hola");
    ctx.noteRaw(" mundo");
    try std.testing.expectEqualStrings("hola mundo", ctx.raw[0..ctx.raw_len]);
    try std.testing.expect(!ctx.saw_done);
    ctx.destroy();
}

test "los 402 y 403 tienen error propio (no se reintentan)" {
    // 402 sin creditos se reintentaba 3 veces como si fuera 5xx: tres esperas
    // de backoff para un error que no se va a arreglar solo.
    try std.testing.expect(!isRetryableTest(error.NoCredits));
    try std.testing.expect(!isRetryableTest(error.Forbidden));
    try std.testing.expect(!isRetryableTest(error.AuthFailed));
    try std.testing.expect(isRetryableTest(error.RateLimited));
    try std.testing.expect(isRetryableTest(error.Overloaded));
}

/// Espejo de la decisión de `agent.isRetryable`, para poder testearla sin
/// depender del módulo del agente (que importa la TUI entera).
fn isRetryableTest(err: anyerror) bool {
    return switch (err) {
        error.RateLimited, error.Overloaded, error.ServerError => true,
        else => false,
    };
}
