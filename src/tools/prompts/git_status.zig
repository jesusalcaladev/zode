//! The `git_status` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "git_status";

pub const description: []const u8 =
    "The state of the working tree and the branch: one line per staged, modified or untracked path (XY = staged then worktree, ?? = untracked), plus how many files changed and by how much. USE IT WHEN: you need to know what changed before editing or committing. USE INSTEAD OF: bash git status — that returns English prose with colour codes you then have to parse; this is a table. Returns a clean-tree note when there is nothing to report. LIMITS: size is reported via a separate shortstat so you can tell a 3-file change from a 300-file one. ON ERROR: says whether this is a git repository and what to do if it is not.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{},\"required\":[]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "git_status: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
