//! The `git_branch` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "git_branch";

pub const description: []const u8 =
    "Work with branches: list them, create one, or switch to an existing one. USE IT WHEN: you are about to commit and want your change on its own branch so it is not mixed with whatever is already in the tree. create and switch need a name; a name starting with a dash is refused. Branch names are validated here, never interpolated into a shell.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\",\"enum\":[\"list\",\"create\",\"switch\"],\"description\":\"list | create | switch\"},\"name\":{\"type\":\"string\",\"description\":\"the branch; required for create and switch\"}},\"required\":[\"action\"]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "git_branch: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
