//! The `skill` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "skill";

pub const description: []const u8 =
    "Load a skill: a folder of instructions written for a specific kind of task. Your prompt lists only the name and when to use it (the body is NOT in your prompt, so it costs nothing until you ask). Load one when its description matches what you are about to do, and load none when none of them do. USE IT WHEN: a skill's description matches the task at hand. LIMITS: the skill cannot write or ask — it is guidance you read and act on. OPTIONAL: pass `args` to substitute into the skill's $ARGUMENTS placeholder.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\",\"description\":\"the skill's name, exactly as listed\"},\"args\":{\"type\":\"string\",\"description\":\"optional arguments to substitute for $ARGUMENTS in the skill body\"}},\"required\":[\"name\"]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "skill: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}