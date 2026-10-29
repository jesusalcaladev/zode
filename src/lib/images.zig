/// Images a `read` left behind, waiting to go on the next user message.
///
/// ## Why the harness holds them and not the tool
///
/// A `tool` message's content is a plain string in OpenAI's shape, so an image a
/// tool read cannot ride along on its own result. The alternatives were both
/// worse: base64 inside the tool result (which every provider then refuses or
/// silently drops, and which would sit in the session file and in the context
/// forever) or a second round trip to ask again.
///
/// So `read` on a picture leaves the bytes here, returns a line of text the model
/// can read, and the harness attaches the image to the NEXT user message — where
/// the protocol allows it and where the model is already reading.
///
/// ## Why there is a cap, and why it is small
///
/// Base64 is 4 bytes of text per 3 bytes of image, so a 2 MB screenshot is 2.7 MB
/// of prompt — on a free tier, on every subsequent iteration of the turn, and
/// (OpenAI's cache being a literal prefix) as a permanently uncacheable tail. The
/// per-image cap is `max_bytes` and the count cap is `max_images`, and both are
/// here rather than in the tool because the tool does not know what the model is.
///
/// The buffers are FREED as soon as the message goes out. They are not cached and
/// not persisted: an image is worth seeing once, and keeping it would make this the
/// largest thing in the process after a session with a few screenshots.
const std = @import("std");
const models = @import("models.zig");
const chat = @import("../chat.zig");

/// Images attached to one message.
///
/// 2, not 4: the point is to let the model look at a screenshot or a diagram next
/// to the question about it, and a request with four full-resolution images is
/// slow and expensive for no extra insight into a coding task.
pub const max_images = 2;

/// Bytes of image per attachment. 1 MB is a screenshot; a photograph is bigger and
/// is refused with a message rather than silently resized, because resizing an
/// image properly needs a decoder and this is not one.
pub const max_bytes = 1024 * 1024;

pub const Pending = struct {
    images: [max_images]chat.Image = undefined,
    len: u8 = 0,
    /// Bytes refused because of the caps (including images evicted to make room),
    /// so the message can say so instead of the model believing it saw everything.
    refused: u8 = 0,
    pub fn clear(self: *Pending, gpa: std.mem.Allocator) void {
        for (self.images[0..self.len]) |img| {
            if (img.path.len > 0) gpa.free(img.path);
        }
        self.len = 0;
        self.refused = 0;
    }

    pub fn isEmpty(self: *const Pending) bool {
        return self.len == 0;
    }
};

/// The mime type for a path, or null when it is not an image we can send.
pub fn mimeForPath(path: []const u8) ?[]const u8 {
    // Case-insensitive: `Shot.PNG` is a real file on a case-preserving filesystem,
    // and matching it exactly would send a 400 for a file the user can open.
    const ext = std.fs.path.extension(path);
    const table = [_]struct { []const u8, []const u8 }{
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".jpeg", "image/jpeg" },
        .{ ".gif", "image/gif" },
        .{ ".webp", "image/webp" },
        .{ ".bmp", "image/bmp" },
    };
    for (table) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e[0])) return e[1];
    }
    return null;
}

/// The text `read` returns for an image, and what it does with the bytes.
///
/// It returns the text to hand the model plus the base64, and the CALLER owns the
/// base64 (it is an allocation, not a slice of the input). Returning the allocation
/// in the signature is what makes the ownership visible: a `[]const u8` returned
/// from here and freed by someone else is the "Invalid free of a literal" family
/// this repo has hit six times.
///
/// `vision` is whether the CURRENT model takes images. When it does not, the bytes
/// are dropped and the text says so in words the model can act on, because
/// "here is a 2 MB blob you cannot interpret" is how a turn goes sideways.
pub const Prepared = struct {
    text: []const u8,
    /// null when the model has no vision, or when the caps refused it.
    image_b64: ?[]u8 = null,
    /// Bytes the caller must free when it is done with `image_b64`.
    pub fn deinit(self: Prepared, gpa: std.mem.Allocator) void {
        if (self.image_b64) |b| gpa.free(b);
    }
};

pub fn prepare(
    gpa: std.mem.Allocator,
    path: []const u8,
    bytes: []const u8,
    mime: []const u8,
    vision: bool,
) !Prepared {
    const name = std.fs.path.basename(path);
    // Bytes below a kilobyte, because "0 KB" reads as "nothing there" and the
    // model concludes the file is empty. A 75-byte PNG said "0 KB" and the model
    // reported an image with no content.
    const size = if (bytes.len < 1024)
        try std.fmt.allocPrint(gpa, "{d} bytes", .{bytes.len})
    else
        try std.fmt.allocPrint(gpa, "{d} KB", .{bytes.len / 1024});

    if (!vision) {
        return .{ .text = try std.fmt.allocPrint(
            gpa,
            "{s}: an image, {s}, {s}. The CURRENT MODEL CANNOT SEE IMAGES, so it was not attached and there is nothing to look at here. " ++
                "If the task needs to see it, tell the user which model to switch to (Ctrl+T lists the ones with vision) or describe what you need looked at.",
            .{ name, size, mime },
        ) };
    }
    if (bytes.len > max_bytes) {
        return .{ .text = try std.fmt.allocPrint(
            gpa,
            "{s}: an image of {s}, over the {d} KB limit for attaching one, so it was NOT sent. Shrink it, crop it, or read it in pieces.",
            .{ name, size, max_bytes / 1024 },
        ) };
    }

    const buf = try gpa.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    _ = std.base64.standard.Encoder.encode(buf, bytes);

    return .{
        .text = try std.fmt.allocPrint(
            gpa,
            "{s}: an image, {s}, {s}. It is attached to this message — look at it.",
            .{ name, size, mime },
        ),
        .image_b64 = buf,
    };
}

/// The note that goes with the images on the wire.
///
/// It is not decoration. Without it the model sees a user message whose text is
/// "Continue with the tool results above." followed by an image, and the natural
/// reading is that the image IS the tool result — which it is not, and which sends
/// it looking for a tool output that does not exist.
pub fn wireNote(gpa: std.mem.Allocator, pending: *const Pending) ![]const u8 {
    var names: [256]u8 = undefined;
    var n: usize = 0;
    for (pending.images[0..pending.len], 0..) |img, i| {
        if (i > 0 and n + 2 <= names.len) {
            names[n] = ',';
            names[n + 1] = ' ';
            n += 2;
        }
        // Name the saved file so the model knows which image is which.
        const label = if (img.path.len > 0) std.fs.path.basename(img.path) else img.mime;
        const written = @min(label.len, names.len -| n);
        @memcpy(names[n .. n + written], label[0..written]);
        n += written;
    }
    var text = std.Io.Writer.Allocating.init(gpa);
    const w = &text.writer;
    try w.print(
        "The image{s} above ({s}) came from a file you read. It is not a screenshot of the terminal: it is the file's contents.",
        .{ if (pending.len == 1) "" else "s", names[0..n] },
    );
    if (pending.refused > 0) {
        try w.print(
            " {d} more image{s} could not be attached (limit: {d} at a time, {d} KB each).",
            .{ pending.refused, if (pending.refused == 1) "" else "s", max_images, max_bytes / 1024 },
        );
    }
    return text.written();
}

comptime {
    // `models` is imported for the caller's benefit in this module's contract; the
    // reference here keeps the dependency honest if the table is ever removed.
    _ = models.isVision;
}

// ── tests ────────────────────────────────────────────────────────

test "mimeForPath: the formats providers accept, and nothing else" {
    try std.testing.expectEqualStrings("image/png", mimeForPath("a/b/shot.PNG").?);
    try std.testing.expectEqualStrings("image/jpeg", mimeForPath("x.jpg").?);
    try std.testing.expectEqualStrings("image/jpeg", mimeForPath("x.JPEG").?);
    try std.testing.expectEqualStrings("image/gif", mimeForPath("x.gif").?);
    try std.testing.expectEqualStrings("image/webp", mimeForPath("x.webp").?);
    // Not images, and pretending otherwise is how a 400 happens.
    try std.testing.expect(mimeForPath("main.zig") == null);
    try std.testing.expect(mimeForPath("notes.md") == null);
    try std.testing.expect(mimeForPath("archive.tar.gz") == null);
    try std.testing.expect(mimeForPath("noext") == null);
}

test "prepare: no vision means NO image and a message the model can act on" {
    // This is the case on the free tier, where `space-bunny-free` is the model
    // that answers. "Here is a 2 MB blob you cannot interpret" is how a turn goes
    // sideways, so the text names the limit AND the way out.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    const p = try prepare(gpa, "shot.png", &[_]u8{ 1, 2, 3 }, "image/png", false);
    try std.testing.expect(p.image_b64 == null);
    try std.testing.expect(std.mem.indexOf(u8, p.text, "CANNOT SEE IMAGES") != null);
    try std.testing.expect(std.mem.indexOf(u8, p.text, "Ctrl+T") != null);
    // It says "not attached", which contains the word "attached": the assertion
    // has to be on the phrase that claims it, or it passes on the wrong text and
    // fails on the right one. (`expect(x == null)` returns TestUnexpectedResult,
    // which is how this was found — the failure had no output.)
    try std.testing.expect(std.mem.indexOf(u8, p.text, "attached to this message") == null);
}

test "prepare: with vision it encodes base64 and says it is attached" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    const raw = [_]u8{ 'P', 'N', 'G' };
    const p = try prepare(gpa, "shot.png", &raw, "image/png", true);
    defer p.deinit(gpa);
    try std.testing.expect(p.image_b64 != null);
    try std.testing.expectEqualStrings("UE5H", p.image_b64.?);
    try std.testing.expect(std.mem.indexOf(u8, p.text, "attached to this message") != null);
    // Never "0 KB": a 75-byte PNG reported as 0 KB reads as an empty file, and the
    // model duly reported an image with no content.
    try std.testing.expect(std.mem.indexOf(u8, p.text, "0 KB") == null);
    try std.testing.expect(std.mem.indexOf(u8, p.text, "3 bytes") != null);
}

test "prepare: an image over the cap is refused WITH the reason, not truncated" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    const big = try gpa.alloc(u8, max_bytes + 1);
    defer gpa.free(big);
    @memset(big, 0);

    const p = try prepare(gpa, "huge.png", big, "image/png", true);
    try std.testing.expect(p.image_b64 == null);
    try std.testing.expect(std.mem.indexOf(u8, p.text, "NOT sent") != null);
    try std.testing.expect(std.mem.indexOf(u8, p.text, "1024 KB limit") != null);
}

test "the caps are small on purpose: base64 is 4 bytes of prompt per 3 of image" {
    // 1 MB of image is ~1.37 MB of base64, which is ~340k tokens, sent again on
    // every iteration of the turn. On a free tier that is the whole budget, and
    // since it is at the END of the conversation it is also permanently
    // uncacheable: OpenAI's cache is a literal prefix.
    try std.testing.expect(max_bytes <= 1024 * 1024);
    try std.testing.expect(max_images <= 4);
}

test "wireNote: it says the image is the FILE, not a screenshot of the terminal" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    var p = Pending{};
    p.images[0] = .{ .mime = "image/png", .data_b64 = "AAAA" };
    p.len = 1;

    const note = try wireNote(gpa, &p);
    // Without this the model reads an image next to "Continue with the tool results
    // above." and concludes the image IS the tool result, then goes looking for an
    // output that does not exist.
    try std.testing.expect(std.mem.indexOf(u8, note, "not a screenshot") != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "image/png") != null);

    // Two images, and one that did not fit: the refusal is in the message too,
    // because a model that believes it saw everything is worse than one that knows.
    p.images[1] = .{ .mime = "image/jpeg", .data_b64 = "BBBB" };
    p.len = 2;
    p.refused = 1;
    const note2 = try wireNote(gpa, &p);
    try std.testing.expect(std.mem.indexOf(u8, note2, "images above") != null);
    try std.testing.expect(std.mem.indexOf(u8, note2, "image/jpeg") != null);
    try std.testing.expect(std.mem.indexOf(u8, note2, "1 more image could not be attached") != null);
}

test "wireNote: names the saved file, not just the mime" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    var p = Pending{};
    p.images[0] = .{
        .mime = "image/png",
        .data_b64 = "AAAA",
        .path = try gpa.dupe(u8, "/home/user/shots/screenshot.png"),
    };
    p.images[1] = .{
        .mime = "image/jpeg",
        .data_b64 = "BBBB",
        .path = try gpa.dupe(u8, "/tmp/photo.JPG"),
    };
    p.len = 2;
    defer p.clear(gpa);

    const note = try wireNote(gpa, &p);
    // The note names each saved file by basename.
    try std.testing.expect(std.mem.indexOf(u8, note, "screenshot.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "photo.JPG") != null);
    // Case preserved: the real file name, not lowercased.
    try std.testing.expect(std.mem.indexOf(u8, note, "JPG") != null);
}
