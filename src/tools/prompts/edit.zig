//! The `edit` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const std = @import("std");
const validate = @import("validate.zig");

pub const name = "edit";

pub const description: []const u8 =
    "Exact string replacement in a file. Single hunk via old_string/new_string; several HUNKS in one file via edits:[{old_string,new_string},...] (all validated against the ORIGINAL text first, then applied in order — if a hunk no longer matches because an earlier one rewrote it, NOTHING is written). For several FILES in ONE call use files:[{path,old_string,new_string},...] (max 8) — that is the shape a rename takes. USE IT WHEN: you know the exact old text and the exact new text. USE INSTEAD OF: write for a small change (rewriting a whole file to fix one line is wasteful and error-prone). EFFICIENCY: keep the match SMALL — the fewest lines that identify the spot uniquely, not ten lines of surrounding context, because extra context is exactly what makes a patch stop matching after an unrelated edit. validate-then-apply means a bad hunk leaves the file untouched, not half-edited. allow_multiple:true replaces every occurrence. LIMITS: old_string must appear exactly once unless allow_multiple; old_string and new_string must differ; max 16 hunks per file; max 8 files per call. ON ERROR: old_string not found includes the nearest real line and which of the three failure types it is — re-read that region and re-send. nothing was written means an earlier hunk consumed the text a later hunk needed; re-read and split the hunks so none depends on a region another rewrites.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"old_string\":{\"type\":\"string\"},\"new_string\":{\"type\":\"string\"},\"edits\":{\"type\":\"array\",\"description\":\"several HUNKS in this one file\",\"items\":{\"type\":\"object\",\"properties\":{\"old_string\":{\"type\":\"string\"},\"new_string\":{\"type\":\"string\"}},\"required\":[\"old_string\",\"new_string\"]}},\"files\":{\"type\":\"array\",\"description\":\"up to 8 {path,old_string,new_string} objects, edited in ONE call\",\"items\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"old_string\":{\"type\":\"string\"},\"new_string\":{\"type\":\"string\"}},\"required\":[\"path\",\"old_string\",\"new_string\"]}},\"allow_multiple\":{\"type\":\"boolean\"}},\"required\":[]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "edit: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}

test "edit: it asks for a SMALL match, which is what keeps a patch valid" {
    // Ten lines of context do not make a patch safer, they make it fragile: it stops
    // matching the moment anything else in those lines is edited, and the cost is one
    // failed edit plus the re-read that follows it.
    try std.testing.expect(std.mem.indexOf(u8, description, "keep the match SMALL") != null);
    try std.testing.expect(std.mem.indexOf(u8, description, "must differ") != null);
}
