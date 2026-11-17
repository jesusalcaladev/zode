//! Memory-safety source auditor (Phase 39). It catches the two crash classes
//! that actually hit zode, using precise, deterministic source scanning:
//!
//!   1. stack_field_slice — a struct FIELD (not a local const) is assigned a
//!      `bufPrint(&stack_local, ...)` slice. The struct is typically returned
//!      or stored in a long-lived object, so the field dangles the moment the
//!      function exits (the `@memcpy arguments alias` bug in discovery.zig and
//!      the latent one in commands.zig's copy toast).
//!   2. content_items_alias — a message `.content` field is assigned the
//!      borrowed `.items` slice of a growable buffer with no owning copy. The
//!      next iteration clears and refills that buffer, so the message reads
//!      new bytes or freed memory (the subagent SIGSEGV in chat.jsonEscape).
//!
//! Both detectors are deliberately NARROW: they match only the high-signal
//! shapes, because a general "any .items / any return" linter drowns in false
//! positives (arena-backed slices, array-by-value returns, caller buffers).
//! Findings are advisory: a line annotated `memaudit: allow` is skipped, so a
//! reviewed intentional case can be marked. Pure string scanning — no parser,
//! no AST, no IO, so it is testable in isolation and cheap in CI.

const std = @import("std");

pub const Kind = enum {
    stack_field_slice,
    content_items_alias,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .stack_field_slice => "stack buffer stored in a struct field",
            .content_items_alias => "borrowed .items stored as message content",
        };
    }

    pub fn advice(self: Kind) []const u8 {
        return switch (self) {
            .stack_field_slice => "use a module-level static buffer or dupe() into an arena",
            .content_items_alias => "duplicate with arena.dupe(u8, ...) before storing",
        };
    }
};

pub const Finding = struct {
    kind: Kind,
    line: usize,
    snippet: []const u8,
};

/// `var name: [N]T ...` with leading indentation. A module-level `var` at
/// column 0 is NOT a stack local — discovery.zig's fix relies on that — so it
/// is deliberately ignored.
fn stackArrayName(line: []const u8) ?[]const u8 {
    const t = std.mem.trimStart(u8, line, " \t");
    if (t.len == line.len) return null; // column 0: module global, allowed
    if (!std.mem.startsWith(u8, t, "var ")) return null;
    const after_var = std.mem.trimStart(u8, t[4..], " \t");
    const colon = std.mem.indexOfScalar(u8, after_var, ':') orelse return null;
    const name = std.mem.trim(u8, after_var[0..colon], " \t");
    if (name.len == 0) return null;
    const typ = std.mem.trimStart(u8, after_var[colon + 1 ..], " \t");
    if (!std.mem.startsWith(u8, typ, "[")) return null;
    return name;
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// The name passed as `&name` right after `bufPrint(` on this line.
fn bufPrintBuffer(line: []const u8) ?[]const u8 {
    const marker = "bufPrint(&";
    const at = std.mem.indexOf(u8, line, marker) orelse return null;
    const start = at + marker.len;
    var end = start;
    while (end < line.len and (isIdent(line[end]) or line[end] == '[' or line[end] == ']' or line[end] == '.')) : (end += 1) {}
    if (end == start) return null;
    // Strip an index like `buf[0]` down to `buf`.
    const raw = line[start..end];
    const bracket = std.mem.indexOfScalar(u8, raw, '[') orelse raw.len;
    return raw[0..bracket];
}

/// Does the first assignment on this line target a struct field (`foo.bar`,
/// `.bar`)? `const x = ...` and `_ = ...` are safe local scalar copies.
fn assignedToField(line: []const u8) bool {
    const eq = std.mem.indexOf(u8, line, "=") orelse return false;
    if (eq > 0 and (line[eq - 1] == '=' or line[eq - 1] == '!' or line[eq - 1] == '<' or line[eq - 1] == '>')) return false;
    if (eq + 1 < line.len and line[eq + 1] == '=') return false;
    const lhs = std.mem.trim(u8, line[0..eq], " \t");
    return std.mem.indexOfScalar(u8, lhs, '.') != null;
}

/// Is the right-hand side of a `.content = ...` assignment a borrowed slice?
fn storedContentItems(line: []const u8) bool {
    const marker = ".content =";
    const at = std.mem.indexOf(u8, line, marker) orelse return false;
    const rhs = std.mem.trimStart(u8, line[at + marker.len ..], " \t");
    // Owning copies are safe regardless of where they appear on the line.
    const owners = [_][]const u8{ "dupe(", "toOwnedSlice(", "allocPrint(", "alloc(", "clone(", "copy(" };
    for (owners) |o| if (std.mem.indexOf(u8, line, o) != null) return false;
    const ia = std.mem.indexOf(u8, rhs, ".items") orelse return false;
    // `.items` must be the end of the value, not `.items.len` / `.append`.
    const after = std.mem.trimStart(u8, rhs[ia + ".items".len ..], " \t");
    if (after.len == 0) return true;
    const c = after[0];
    return c == ',' or c == ';' or c == ')' or c == '}';
}

/// Scan one source string. Findings are owned by `gpa`; snippets borrow
/// `source` and stay valid as long as it does.
pub fn scan(gpa: std.mem.Allocator, source: []const u8) ![]Finding {
    var out: std.ArrayList(Finding) = .empty;
    errdefer out.deinit(gpa);

    // Stack arrays are tracked PER FUNCTION: only a local of the same function
    // can make a `field = bufPrint(&local)` escape. A new `fn` resets the set.
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);

    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_no: usize = 0;
    while (lines.next()) |raw| {
        line_no += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        const leading = std.mem.trimStart(u8, line, " \t");
        // Comments and multiline-string lines (the auditor's own examples, or
        // documentation snippets) are not executable patterns.
        if (std.mem.startsWith(u8, leading, "//") or std.mem.startsWith(u8, leading, "\\\\")) continue;
        if (std.mem.indexOf(u8, line, " fn ") != null or std.mem.startsWith(u8, leading, "fn ")) {
            names.clearRetainingCapacity();
        }
        if (stackArrayName(line)) |n| try names.append(gpa, n);
        if (std.mem.indexOf(u8, line, "memaudit: allow") != null) continue;

        // Class 1: field = bufPrint(&stack_local, ...)
        if (std.mem.indexOf(u8, line, "bufPrint(&") != null and assignedToField(line)) {
            if (bufPrintBuffer(line)) |buf| {
                for (names.items) |n| {
                    if (std.mem.eql(u8, n, buf)) {
                        try out.append(gpa, .{ .kind = .stack_field_slice, .line = line_no, .snippet = line });
                        break;
                    }
                }
            }
        }

        // Class 2: .content = <borrowed>.items
        if (storedContentItems(line)) {
            try out.append(gpa, .{ .kind = .content_items_alias, .line = line_no, .snippet = line });
        }
    }
    return out.toOwnedSlice(gpa);
}

test "memaudit: flags a stack buffer stored in a returned struct field" {
    const src =
        \\fn loader() Loader {
        \\    var path_buf: [4096]u8 = undefined;
        \\    var loader = Loader.init();
        \\    loader.project_dir = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ a, b }) catch loader.project_dir;
        \\    return loader;
        \\}
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const findings = try scan(arena.allocator(), src);
    var found = false;
    for (findings) |f| {
        if (f.kind == .stack_field_slice and f.line == 4) found = true;
    }
    try std.testing.expect(found);
}

test "memaudit: a module-level scratch buffer is allowed" {
    const src =
        \\var loader_path_bufs: [4][4096]u8 = undefined;
        \\fn loader() Loader {
        \\    var loader = Loader.init();
        \\    loader.project_dir = std.fmt.bufPrint(&loader_path_bufs[0], "{s}", .{a}) catch loader.project_dir;
        \\    return loader;
        \\}
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const findings = try scan(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "memaudit: flags a borrowed .items stored as message content" {
    const src =
        \\msgs.append(sarena, .{ .role = "assistant", .content = tstate.text.items, .tool_calls_json = tc });
        \\const owned = sarena.dupe(u8, tstate.text.items);
        \\msgs.append(sarena, .{ .role = "assistant", .content = owned });
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const findings = try scan(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(Kind.content_items_alias, findings[0].kind);
    try std.testing.expectEqual(@as(usize, 1), findings[0].line);
}

test "memaudit: memaudit-allow suppresses a reviewed line" {
    const src =
        \\    var buf: [16]u8 = undefined;
        \\    out.field = std.fmt.bufPrint(&buf, "{s}", .{a}) catch out.field; // memaudit: allow - reviewed
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const findings = try scan(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "memaudit: safe patterns are not findings" {
    const src =
        \\const p = std.fmt.bufPrint(&buf, "{s}", .{a}) catch return; // local const, safe
        \\for (tstate.calls.items) |call| use(call);
        \\segs[0] = .{ .text = arena_list.items, .style = theme.table }; // arena-backed
        \\m.field = std.fmt.bufPrint(&module_static[0], "{s}", .{a}) catch ""; // static buffer
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const findings = try scan(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}
