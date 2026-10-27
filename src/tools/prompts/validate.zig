//! The invariants every tool's schema entry has to hold.
//!
//! A tool is two things at once: code that runs, and text that decides whether the
//! model reaches for it at all. The text lives in `prompts/<name>.zig`; the code
//! lives one level up. This is the test the text has to pass, and it is in ONE file
//! so the tools do not carry the same assertions twenty-nine times: a copied test is
//! a test that gets fixed in one place.
//!
//! ## Why the prose may not contain a quote
//!
//! `<name>.zig` builds its entry by interpolating `description` into a JSON string
//! at COMPTIME. That is what keeps the entry free of hand-written escaping, and it
//! is why a `"` or a `\` in the prose is not cosmetic: it would invalidate the whole
//! tools array — every tool, not this one — and the provider answers a 400 that names
//! none of it. The bad edit looks exactly like a correct one, so it gets a test and a
//! message that says which byte and why.
//!
//! ## The check is a VALUE, and only the failing path prints
//!
//! `fault` returns the reason instead of writing it, so the test below can provoke
//! every branch without printing anything. A suite that prints alarming lines while
//! it is green is a suite whose output people stop reading, and this one would print
//! four of them on every run.
//!
//! ## What is checked here, and what is not
//!
//! Checked: the prose is safe to interpolate; the entry parses as JSON; it is the
//! entry of THIS tool (name and description match the module); and it carries a
//! `parameters` object.
//!
//! NOT checked here: that the parameters match what the tool's code actually reads.
//! That belongs to the dispatcher, which has a test per tool where the argument is
//! easy to get wrong (`bash`'s `run_in_background`, `edit`'s `files`, `todo`'s
//! `update`), and to those tools' own tests.
const std = @import("std");

/// The reason an entry is rejected. A value, not a printed line — see the header.
pub const Fault = union(enum) {
    /// A byte that cannot appear in prose interpolated into a JSON string.
    unsafe_byte: u8,
    /// Not a JSON object, or not `{"function":{...}}`.
    not_json,
    name_mismatch,
    description_mismatch,
    no_parameters,

    pub fn text(self: Fault) []const u8 {
        return switch (self) {
            .unsafe_byte => |c| switch (c) {
                '"' => "the description carries a `\"`, which cannot appear in prose that is put inside a JSON string",
                '\\' => "the description carries a `\\`, which cannot appear in prose that is put inside a JSON string",
                else => "the description carries a control character, which cannot appear in a JSON string",
            },
            .not_json => "the entry is not a `{\"function\": {...}}` object",
            .name_mismatch => "the entry's `name` is not this module's `name`",
            .description_mismatch => "the entry's `description` is not this module's `description`",
            .no_parameters => "the entry has no `parameters` object",
        };
    }
};

/// The pure half: what is wrong with this entry, or null. No I/O, so a test can
/// provoke every branch.
pub fn fault(name: []const u8, description: []const u8, json: []const u8) ?Fault {
    for (description) |c| {
        if (c == '"' or c == '\\' or c < 0x20) return .{ .unsafe_byte = c };
    }

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), json, .{}) catch
        return .not_json;
    if (v != .object) return .not_json;
    const fn_value = v.object.get("function") orelse return .not_json;
    if (fn_value != .object) return .not_json;
    const f = fn_value.object;

    const name_value = f.get("name") orelse return .not_json;
    if (name_value != .string) return .not_json;
    if (!std.mem.eql(u8, name_value.string, name)) return .name_mismatch;

    const desc_value = f.get("description") orelse return .not_json;
    if (desc_value != .string) return .not_json;
    if (!std.mem.eql(u8, desc_value.string, description)) return .description_mismatch;

    const params_value = f.get("parameters") orelse return .no_parameters;
    if (params_value != .object) return .no_parameters;
    if (params_value.object.get("type") == null) return .no_parameters;
    return null;
}

/// What each tool's module calls. Prints the reason with the tool's name, because
/// the reader is looking at one failed test among hundreds and the test's own name
/// already says which tool.
pub fn entry(name: []const u8, description: []const u8, json: []const u8) !void {
    const f = fault(name, description, json) orelse return;
    std.debug.print("{s}: {s}\n", .{ name, f.text() });
    return switch (f) {
        .unsafe_byte => error.DescriptionNotJsonSafe,
        .not_json => error.SchemaIsNotJson,
        .name_mismatch => error.SchemaNameMismatch,
        .description_mismatch => error.SchemaDescriptionMismatch,
        .no_parameters => error.SchemaHasNoParameters,
    };
}

// ── tests ────────────────────────────────────────────────────────

test "validate: every way an entry can be wrong, provoked without printing" {
    try std.testing.expectEqualDeep(@as(?Fault, .{ .unsafe_byte = '"' }), fault("x", "a \" quote", "{}"));
    try std.testing.expectEqualDeep(@as(?Fault, .{ .unsafe_byte = '\\' }), fault("x", "a \\ backslash", "{}"));
    try std.testing.expectEqualDeep(@as(?Fault, .{ .unsafe_byte = '\n' }), fault("x", "a \n newline", "{}"));
    try std.testing.expectEqualDeep(@as(?Fault, .not_json), fault("x", "clean prose", "not json"));
    // An object with no `function` is not an entry, and neither is a `function` that
    // is not an object.
    try std.testing.expectEqualDeep(@as(?Fault, .not_json), fault("x", "clean prose", "{\"name\":\"x\"}"));
    try std.testing.expectEqualDeep(@as(?Fault, .not_json), fault("x", "clean prose", "{\"function\":7}"));
    // Right shape, wrong tool: the module and the entry have drifted apart.
    try std.testing.expectEqualDeep(@as(?Fault, .name_mismatch), fault("x", "clean prose", ok_entry("y", "clean prose")));
    try std.testing.expectEqualDeep(@as(?Fault, .description_mismatch), fault("x", "other prose", ok_entry("x", "clean prose")));
    try std.testing.expectEqualDeep(@as(?Fault, .no_parameters), fault("x", "clean prose",
        "{\"type\":\"function\",\"function\":{\"name\":\"x\",\"description\":\"clean prose\",\"parameters\":7}}"));
    // And the happy path is silent and passes.
    try std.testing.expectEqual(@as(?Fault, null), fault("x", "clean prose", ok_entry("x", "clean prose")));
}

fn ok_entry(comptime n: []const u8, comptime d: []const u8) []const u8 {
    return "{\"type\":\"function\",\"function\":{\"name\":\"" ++ n ++
        "\",\"description\":\"" ++ d ++
        "\",\"parameters\":{\"type\":\"object\"}}}";
}
