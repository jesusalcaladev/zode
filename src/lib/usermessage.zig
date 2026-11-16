//! `send_user_message` (Phase 21): the durable statement to the user, not the
//! tool log. Pure on purpose: validation, status parsing and attachment checks
//! are testable without the TUI, without a network and without a session.
//!
//! WHY THIS TOOL EXISTS: in a long turn the user's answer is buried in a wall
//! of tool results. This is the one call whose `message` is THE answer — the
//! prompt tells the model the opposite of the failure it removes: write the
//! answer in plain text + "done!" here, not a play-by-play in the log.

const std = @import("std");

pub const Status = enum {
    /// A normal reply to the user's request.
    normal,
    /// The model initiated contact: a scheduled task finished, a blocker
    /// surfaced in the background. Routed to the notification channel.
    proactive,

    pub fn parse(s: []const u8) ?Status {
        if (std.ascii.eqlIgnoreCase(s, "normal")) return .normal;
        if (std.ascii.eqlIgnoreCase(s, "proactive")) return .proactive;
        return null;
    }

    pub fn name(self: Status) []const u8 {
        return switch (self) {
            .normal => "normal",
            .proactive => "proactive",
        };
    }
};

pub const max_message_bytes = 64 * 1024;
pub const max_attachments = 8;

pub const Attachment = struct {
    path: []const u8,
    kind: Kind,

    pub const Kind = enum { infer, image, diff, log };

    pub fn parseKind(s: []const u8) ?Kind {
        if (s.len == 0 or std.ascii.eqlIgnoreCase(s, "infer")) return .infer;
        if (std.ascii.eqlIgnoreCase(s, "image")) return .image;
        if (std.ascii.eqlIgnoreCase(s, "diff")) return .diff;
        if (std.ascii.eqlIgnoreCase(s, "log")) return .log;
        return null;
    }
};

pub const Error = error{
    EmptyMessage,
    MessageTooLong,
    BadStatus,
    UnknownStatus,
    TooManyAttachments,
    BadAttachment,
    AttachmentNotFound,
};

/// Validated input, ready for the TUI/headless to render.
pub const Message = struct {
    text: []const u8,
    status: Status = .normal,
    attachments: []const Attachment = &.{},
};

/// Parse and validate the tool arguments. Called before ANY user-visible
/// output, so a bad call is a named error the model sees and can fix — never a
/// half-rendered message followed by a failure.
pub fn parse(gpa: std.mem.Allocator, obj: std.json.ObjectMap) Error!Message {
    const msg_v = obj.get("message") orelse return error.EmptyMessage;
    if (msg_v != .string) return error.EmptyMessage;
    const text = std.mem.trim(u8, msg_v.string, " \t\r\n");
    if (text.len == 0) return error.EmptyMessage;
    if (text.len > max_message_bytes) return error.MessageTooLong;

    var status: Status = .normal;
    if (obj.get("status")) |sv| {
        if (sv != .string) return error.BadStatus;
        status = Status.parse(sv.string) orelse return error.UnknownStatus;
    }

    var attachments: []const Attachment = &.{};
    if (obj.get("attachments")) |av| {
        if (av != .array) return error.BadAttachment;
        if (av.array.items.len > max_attachments) return error.TooManyAttachments;
        var list: std.ArrayList(Attachment) = .empty;
        for (av.array.items) |item| {
            if (item != .object) return error.BadAttachment;
            const path_v = item.object.get("path") orelse return error.BadAttachment;
            if (path_v != .string or path_v.string.len == 0) return error.BadAttachment;
            var kind: Attachment.Kind = .infer;
            if (item.object.get("kind")) |kv| {
                if (kv != .string) return error.BadAttachment;
                kind = Attachment.parseKind(kv.string) orelse return error.BadAttachment;
            }
            list.append(gpa, .{ .path = path_v.string, .kind = kind }) catch return error.BadAttachment;
        }
        attachments = list.toOwnedSlice(gpa) catch return error.BadAttachment;
    }

    return .{ .text = text, .status = status, .attachments = attachments };
}

/// Route decision for a validated message. `normal` is the durable answer in
/// the transcript; `proactive` ALSO goes to the notification channel (a toast)
/// because the model initiated contact while the user may be looking away.
pub fn routesToNotification(status: Status) bool {
    return status == .proactive;
}

/// Check that every attachment path actually exists. Pure with respect to the
/// TUI — the only IO is a stat — so the "a missing path is a named error, not a
/// silent drop" rule is testable. Callers run this BEFORE rendering anything.
pub fn missingAttachment(io: std.Io, msg: Message) ?[]const u8 {
    for (msg.attachments) |att| {
        _ = std.Io.Dir.cwd().statFile(io, att.path, .{}) catch return att.path;
    }
    return null;
}

/// The named error text for a missing attachment — it says the PATH, so the
/// model can fix the call instead of guessing which one was dropped.
pub fn missingAttachmentText(gpa: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(gpa,
        "attachment path does not exist: {s}. Check it with glob or list_files, then call send_user_message again.",
        .{path},
    );
}

/// The exact prose guidance the model reads, saying the OPPOSITE of the failure
/// this tool removes. Kept here (pure) so prompt and tests share one source.
pub const guidance =
    "When you have the answer, write it in plain text in send_user_message and add \"done!\" — " ++
    "that message is what the user reads. Do not narrate your steps there; the tool log is not the answer.";

test "usermessage: a normal message with markdown passes through unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var parsed = try std.json.parseFromSlice(std.json.Value, a,
        "{\"message\":\"## Result\\n**done!** here\"}", .{});
    defer parsed.deinit();
    const m = try parse(a, parsed.value.object);
    try std.testing.expectEqualStrings("## Result\n**done!** here", m.text);
    try std.testing.expectEqual(Status.normal, m.status);
    try std.testing.expectEqual(@as(usize, 0), m.attachments.len);
}

test "usermessage: empty message is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"message\":\"   \"}", .{});
    defer parsed.deinit();
    try std.testing.expectError(error.EmptyMessage, parse(a, parsed.value.object));
}

test "usermessage: proactive status parses and routes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var parsed = try std.json.parseFromSlice(std.json.Value, a,
        "{\"message\":\"scheduled check finished\",\"status\":\"proactive\"}", .{});
    defer parsed.deinit();
    const m = try parse(a, parsed.value.object);
    try std.testing.expectEqual(Status.proactive, m.status);
    try std.testing.expect(std.mem.indexOf(u8, guidance, "done!") != null);
}

test "usermessage: unknown status and bad attachment are named errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var p1 = try std.json.parseFromSlice(std.json.Value, a,
        "{\"message\":\"x\",\"status\":\"whenever\"}", .{});
    defer p1.deinit();
    try std.testing.expectError(error.UnknownStatus, parse(a, p1.value.object));

    var p2 = try std.json.parseFromSlice(std.json.Value, a,
        "{\"message\":\"x\",\"attachments\":[{\"kind\":\"image\"}]}", .{});
    defer p2.deinit();
    try std.testing.expectError(error.BadAttachment, parse(a, p2.value.object));
}

test "usermessage: missing attachment error names the path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try missingAttachmentText(arena.allocator(), "shot.png");
    try std.testing.expect(std.mem.indexOf(u8, text, "shot.png") != null);
}

test "usermessage: proactive routes to notification, normal does not" {
    try std.testing.expect(routesToNotification(.proactive));
    try std.testing.expect(!routesToNotification(.normal));
}

test "usermessage: a missing attachment path is detected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var parsed = try std.json.parseFromSlice(std.json.Value, a,
        "{\"message\":\"x\",\"attachments\":[{\"path\":\"no/such/file.png\"}]}", .{});
    defer parsed.deinit();
    const m = try parse(a, parsed.value.object);
    try std.testing.expectEqualStrings("no/such/file.png", missingAttachment(std.testing.io, m).?);
}
