//! The `review` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "review";

pub const description: []const u8 =
    "Review YOUR OWN change: returns the diff of the files you changed this turn plus a checklist of what to look for in it. The harness has already checked that the code compiles, so this is NOT about running the build — it is about whether the change is the one you meant to make. USE IT WHEN: after a set of edits, before you report what you did. The harness will not end your turn while an edit of yours is unreviewed. It costs no wall clock.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{},\"required\":[]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "review: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
