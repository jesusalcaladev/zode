const std = @import("std");
const compaction = @import("../compaction.zig");
const chat = @import("../chat.zig");
const http_client = @import("../lib/http_client.zig");
const models_mod = @import("../lib/models.zig");
const summary_policy = @import("summary_policy.zig");

const SummarySink = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
};

/// Summarizes a stretch of old messages with the model itself.
/// Returns summary text (arena-owned) or null if it could not be done.
pub fn summarizeTurns(
    gpa: std.mem.Allocator,
    body_buf: []u8,
    http: *http_client.Http,
    url: []const u8,
    bearer: ?[]const u8,
    kind: chat.ProviderKind,
    model_name: []const u8,
    effort: chat.Effort,
    msgs: []chat.ChatMessage,
    arena: std.mem.Allocator,
    extra_headers: []const http_client.Http.ExtraHeader,
    max_output_tokens: u32,
) ?[]const u8 {
    if (summary_policy.tripped()) return null;

    var ast = std.heap.ArenaAllocator.init(gpa);
    defer ast.deinit();
    const a = ast.allocator();

    const prompt = compaction.summaryPrompt(a, msgs) catch {
        summary_policy.noteFailure();
        models_mod.dbg("[compaction] could not build the summary prompt\n", .{});
        return null;
    };
    const one = [_]chat.ChatMessage{.{ .role = "user", .content = prompt }};
    const body = chat.buildBodyMessagesCapped(body_buf, model_name, &one, effort, "", kind, max_output_tokens) catch {
        summary_policy.noteFailure();
        models_mod.dbg("[compaction] could not build the summary body\n", .{});
        return null;
    };

    var sink = SummarySink{ .gpa = gpa };
    const cb: chat.Callbacks = .{
        .userdata = &sink,
        .onDelta = struct {
            fn f(ud: ?*anyopaque, d: []const u8) void {
                const s: *SummarySink = @ptrCast(@alignCast(ud.?));
                s.buf.appendSlice(s.gpa, d) catch {};
            }
        }.f,
    };
    chat.streamChat(gpa, http, url, bearer, @constCast(body), cb, kind, false, extra_headers) catch |err| {
        summary_policy.noteFailure();
        models_mod.dbg("[compaction] el resumen fallo: {t}\n", .{err});
        return null;
    };
    if (sink.buf.items.len == 0) {
        summary_policy.noteFailure();
        return null;
    }
    summary_policy.noteSuccess();
    return arena.dupe(u8, sink.buf.items) catch null;
}
