//! The `git_add` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "git_add";

pub const description: []const u8 =
    "Stage changes for the next commit. With no paths it stages everything that changed — what you want after editing files yourself. Reports what is staged. USE IT WHEN: before git_commit. A path cannot start with a dash (use ./name if it does).";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"paths\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"stage only these paths; omit to stage everything\"}},\"required\":[]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "git_add: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
