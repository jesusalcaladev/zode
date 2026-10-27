//! The `git_commit` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "git_commit";

pub const description: []const u8 =
    "Commit what is staged, with a message. One line of what changed and why is enough; do not put the diff in it. Returns the short hash. Does NOT push and does NOT add — stage first. The message is written to a temp file and passed with -F, so it is never part of the command line. USE IT WHEN: you have staged changes and want to record them. LIMITS: message over 4096 characters is refused — the first paragraph is what git shows.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"message\":{\"type\":\"string\",\"description\":\"the commit message, one paragraph\"}},\"required\":[\"message\"]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "git_commit: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
