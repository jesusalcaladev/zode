const std = @import("std");

/// Case-insensitive substring search (Zig 0.17 removed std.ascii.indexOfIgnoreCase).
pub fn idxIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// Did the user's prompt ask for something to be implemented (code, files,
/// changes)? Used to decide whether to nudge the model when it stops after
/// only exploring.
pub fn userWantsImplementation(text: []const u8) bool {
    const impl_signals = [_][]const u8{
        "implement", "implementa", "implementar",
        "create",    "crea",       "crear",
        "write",     "escribe",    "escribir",
        "build",     "construir",  "fix",
        "corrige",   "corregir",   "arregla",
        "arreglar",  "add",        "agrega",
        "agregar",   "feature",    "funcionalidad",
        "component", "componente", "stack",
        "pilas",     "refactor",   "migrate",
        "update",    "change",     "delete",
        "remove",    "rename",     "move",
        "make",      "resolve",    "optimize",
        "automate",
    };
    for (impl_signals) |s| {
        if (idxIgnoreCase(text, s) != null) return true;
    }
    return false;
}

test "loop_helpers: userWantsImplementation detects common signals" {
    try std.testing.expect(userWantsImplementation("implement a stack"));
    try std.testing.expect(userWantsImplementation("please fix the bug"));
    try std.testing.expect(userWantsImplementation("crea un archivo"));
    try std.testing.expect(!userWantsImplementation("what does this do?"));
    try std.testing.expect(!userWantsImplementation("explain the architecture"));
}

test "loop_helpers: idxIgnoreCase" {
    try std.testing.expectEqual(@as(?usize, 6), idxIgnoreCase("hello WORLD", "world"));
    try std.testing.expectEqual(@as(?usize, null), idxIgnoreCase("hello", "xyz"));
}

/// Phase 11: end-of-turn extractor proposes memories; user approves.
/// Enabled by default, best-effort. Disable with ZODE_MEMORY_EXTRACT=0.
pub fn memoryExtractEnabled(env: ?*const std.process.Environ.Map) bool {
    const e = env orelse return true;
    const v = e.get("ZODE_MEMORY_EXTRACT") orelse return true;
    if (v.len == 0) return true;
    return !(std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "false") or std.ascii.eqlIgnoreCase(v, "off") or std.ascii.eqlIgnoreCase(v, "no"));
}

pub fn sanitizeMemoryId(id: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    for (id) |c| {
        if (n >= buf.len) break;
        buf[n] = if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') c else '-';
        n += 1;
    }
    if (n == 0) return "proposal";
    return buf[0..n];
}

/// Replace image references with [image.ext] placeholders for UI display.
pub fn replaceImagePlaceholders(text: []const u8) []const u8 {
    const image_exts = &[_][]const u8{ "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp" };
    var result: [512]u8 = undefined;
    var ri: usize = 0;
    var li: usize = 0;

    while (li < text.len) {
        if (text[li] == '@' and li + 1 < text.len) {
            li += 1;
            var fe: usize = li;
            while (fe < text.len and text[fe] != ' ' and text[fe] != '\n' and text[fe] != '\t' and text[fe] != '@') {
                fe += 1;
            }
            const filename = text[li..fe];
            const dot = std.mem.lastIndexOfScalar(u8, filename, '.') orelse continue;
            if (dot >= filename.len - 1) {
                if (ri + 1 > result.len) break;
                result[ri] = '@';
                ri += 1;
                li += 1;
                continue;
            }
            const ext = filename[dot + 1 ..];
            var is_image = false;
            var ei: usize = 0;
            while (ei < image_exts.len) {
                if (ext.len == image_exts[ei].len) {
                    var match = true;
                    var ci: usize = 0;
                    while (ci < ext.len) {
                        if (std.ascii.toLower(ext[ci]) != std.ascii.toLower(image_exts[ei][ci])) {
                            match = false;
                            break;
                        }
                        ci += 1;
                    }
                    if (match) {
                        is_image = true;
                        break;
                    }
                }
                ei += 1;
            }
            if (is_image) {
                var repl_buf: [32]u8 = undefined;
                const repl_slice = std.fmt.bufPrint(repl_buf[0..], "[image.{s}]", .{ext}) catch break;
                const repl_len = repl_slice.len;
                if (ri + repl_len > 512) break;
                @memcpy(result[ri .. ri + repl_len], repl_buf[0..repl_len]);
                ri += repl_len;
                li = fe;
                continue;
            }
        }
        if (ri + 1 > result.len) break;
        result[ri] = text[li];
        ri += 1;
        li += 1;
    }
    return result[0..ri];
}
