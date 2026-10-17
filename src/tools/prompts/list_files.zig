//! The `list_files` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "list_files";

pub const description: []const u8 =
    "List files and directories directly inside a path (non-recursive, cheap). Tags each entry d (directory) or f (file). USE IT WHEN: you need a quick overview of what is in a directory without reading anything. USE INSTEAD OF: bash ls — this is machine-readable and costs the same. LIMITS: skips hidden entries; capped at 500. ON ERROR: names the path and the reason it could not be opened.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"directory to list (default: current directory)\"}},\"required\":[]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "list_files: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
