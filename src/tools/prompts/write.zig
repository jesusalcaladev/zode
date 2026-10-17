//! The `write` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const std = @import("std");
const validate = @import("validate.zig");

pub const name = "write";

pub const description: []const u8 =
    "Create or overwrite a file with the given content. Returns a short preview of what was written so you can verify without opening the file. USE IT WHEN: creating a new file, or rewriting a whole file. USE INSTEAD OF: edit when the file ALREADY EXISTS — overwriting it to change a few lines discards everything you did not read and did not mean to touch, so rewriting a file is a decision and not a reflex. EFFICIENCY: files:[{path,content},...] writes up to 8 files in ONE call — one round trip instead of N. A failure on one file does not lose the others. LIMITS: 8 files per call; the preview is capped at 12 lines. ON ERROR: the response names the file and the reason; fix and re-send only that file.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"},\"files\":{\"type\":\"array\",\"description\":\"up to 8 {path,content} objects, written in ONE call\",\"items\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"]}}},\"required\":[]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "write: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}

test "write: it says that overwriting an existing file is the expensive choice" {
    // The rule these tools were missing: an agent reaches for `write` on a file it has
    // already read and rewrites the whole thing to change two lines, discarding every
    // line it had not looked at.
    try std.testing.expect(std.mem.indexOf(u8, description, "ALREADY EXISTS") != null);
}
