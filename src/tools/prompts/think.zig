//! The `think` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "think";

pub const description: []const u8 =
    "Think privately step by step before acting. Use for planning and complex reasoning. No side effects — nothing is read or written. USE IT WHEN: you need to decide what to do next before spending a tool call. EFFICIENCY: costs a turn but can save several by avoiding a wrong edit.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"thought\":{\"type\":\"string\"}},\"required\":[\"thought\"]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "think: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
