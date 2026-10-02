const std = @import("std");

/// JSON HTTP client on top of std.http.Client (Zig 0.16).
///
/// NOTE: `Request` is heap-allocated because `receiveHead` and `bodyReader`
/// keep internal pointers to the request.
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
        body: []u8, // the caller frees with `freeBody`
        /// Value of the `retry-after` header in seconds, if the server sent one.
        retry_after: ?u16 = null,
    };

    // There is deliberately NO `content_type` here: `receiveHead` leaves the headers
    // in the redirect buffer, which lives on the STACK and dies when `request`
    // returns. A `?[]const u8` pointing at that dead buffer is not a compile
    // error: it yields garbage (and a crash in ReleaseSafe) the first day
    // someone reads the field. The type is deduced from the body instead.

    /// Extra header for APIs that do not use Bearer (e.g: Anthropic's x-api-key).
    pub const ExtraHeader = struct {
        name: []const u8,
        value: []const u8,
    };

    pub fn freeBody(self: *Http, body: []u8) void {
        self.gpa.free(body);
    }

    /// Result of a request with no response body (streaming).
    pub const StreamResult = struct {
        status: u16,
        retry_after: ?u16 = null,
    };

    /// Callback invoked with each chunk of bytes as it arrives. Returning
    /// `error.Cancelled` aborts the read (the caller sees that error).
    pub const ChunkFn = *const fn (userdata: ?*anyopaque, chunk: []const u8) anyerror!void;

    /// POST that delivers the body IN CHUNKS instead of buffering it whole.
    ///
    /// This is what makes SSE streaming real: with `request()` the body is
    /// buffered completely (up to 10 MB) and only parsed at the end, so the
    /// TUI stays frozen for the whole generation. Here every chunk is handed
    /// over as soon as it arrives from the socket.
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

        // The transfer buffer goes on the HEAP (5.5 of the ROADMAP), not the stack:
        // it is 256 KiB resident for the whole download and, with the default
        // `std.Thread` stack, it would be a trap for the day someone lowers it.
        const transfer_buf = try self.gpa.alloc(u8, 256 * 1024);
        defer self.gpa.free(transfer_buf);
        var reader = response.reader(transfer_buf);
        // `takeDelimiter` requires the delimiter to fit in the buffer: a longer SSE
        // line (a huge tool call, a giant delta) makes it fail with
        // StreamTooLong and it KILLED the stream mid-response. When that
        // happens the buffer holds a full unterminated line: it is delivered
        // as-is and we keep going, because the parser reassembles partials.
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

    /// GET that returns the whole body (10MB limit).
    pub fn get(self: *Http, url: []const u8, bearer: ?[]const u8) !JsonResult {
        return self.request(.GET, url, bearer, null, &.{});
    }

    /// GET with its own headers.
    ///
    /// The web tool needs it: half the internet (Cloudflare, GitHub, Wikipedia)
    /// returns 403 to std's default `User-Agent`, which is `zig`, and a 403
    /// response says nothing about what was behind it.
    pub fn getWithHeaders(self: *Http, url: []const u8, headers: []const ExtraHeader) !JsonResult {
        return self.request(.GET, url, null, null, headers);
    }

    /// POST with a JSON body. Returns the whole body (for SSE: `sendSse`).
    /// `body` must be mutable because of std's signature (`sendBodyComplete`).
    pub fn postJson(self: *Http, url: []const u8, bearer: ?[]const u8, body: []u8) !JsonResult {
        return self.request(.POST, url, bearer, body, &.{});
    }

    /// POST with extra headers (e.g: Anthropic's x-api-key).
    pub fn postJsonWithHeaders(
        self: *Http,
        url: []const u8,
        body: []u8,
        headers: []const ExtraHeader,
    ) !JsonResult {
        return self.request(.POST, url, null, body, headers);
    }

    /// Opens a request and sends the body. The caller does `deinit` + `destroy`.
    /// `streaming` adds the SSE headers.
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
            // Many gateways (vLLM, Ollama, proxies) renegotiate the stream
            // depending on these headers; without them they may return error JSON.
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
            // No compression: avoids depending on transparent decompression
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

/// Reads `retry-after` (seconds) from the response, if the server sent it.
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
