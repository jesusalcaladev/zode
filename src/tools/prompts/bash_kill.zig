//! The `bash_kill` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "bash_kill";

pub const description: []const u8 =
    "Kill a backgrounded command. USE IT WHEN: you no longer need the result, or it is clearly going the wrong way. You can still read what it printed with bash_output.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"integer\",\"description\":\"the id bash gave you\"}},\"required\":[\"id\"]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "bash_kill: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
