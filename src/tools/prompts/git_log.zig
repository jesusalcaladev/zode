//! The `git_log` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "git_log";

pub const description: []const u8 =
    "The last commits, most recent first, one line each (short hash and subject). USE IT WHEN: you want to know who touched a file or what changed recently. USE INSTEAD OF: bash git log — this is machine-readable and costs the same. LIMITS: clamped to 200 commits; beyond that it says so. ON ERROR: no commits yet means the repository has no history.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"limit\":{\"type\":\"integer\",\"description\":\"how many commits (default 20, max 200)\"}},\"required\":[]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "git_log: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
