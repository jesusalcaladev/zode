//! The `bash_output` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "bash_output";

pub const description: []const u8 =
    "Read the NEW output of a command you started with run_in_background, plus whether it is still running or what it exited with. Incremental: you get what appeared since your last call, not the whole buffer, so polling is cheap. USE IT WHEN: you started a background job and need its result. Poll ONCE per step, never in a tight loop — do something else in between.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"integer\",\"description\":\"the id bash gave you\"}},\"required\":[\"id\"]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "bash_output: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
