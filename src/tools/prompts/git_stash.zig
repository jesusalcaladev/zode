//! The `git_stash` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "git_stash";

pub const description: []const u8 =
    "Put the current changes aside (push) so you can switch branches or start something clean, and bring them back (pop). list shows what is stashed. USE IT WHEN: the tree has unrelated work you must not touch while you do something else. push + pop, not push alone.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\",\"enum\":[\"push\",\"pop\",\"list\"],\"description\":\"push | pop | list\"}},\"required\":[]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "git_stash: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
