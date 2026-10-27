//! The `git_diff` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "git_diff";

pub const description: []const u8 =
    "The unified diff of the working tree against the index (or of the index against HEAD with staged:true). One block per file, headed by the path, with +N and −M counted for you at the end. USE IT WHEN: you want to see what you changed. USE INSTEAD OF: counting + lines yourself in raw git diff output. EFFICIENCY: the diff is cut at a line boundary and says how much is missing — a cut mid-hunk would make you edit the wrong thing. For anything git does that these do not cover (a commit, a checkout, a stash, a log of one path), use bash. LIMITS: 16 KB readable budget; beyond that it says how many KB are hidden and suggests bash git diff -- path for one file at a time.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"staged\":{\"type\":\"boolean\",\"description\":\"diff the index against HEAD instead of the working tree\"}},\"required\":[]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "git_diff: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
