//! The `task_get` tool's schema text: the prose and the parameters the model
//! reads when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "task_get";

pub const description: []const u8 =
    "The full record of one task: subject, description, status, owner and the edges BOTH ways (what it waits on, what waits on it). USE IT WHEN: you are about to start a task and need its description, or you are about to change one and want its current state before sending the change. EFFICIENCY: task_list already gives you status, owner and waiting-on for every task; call this only when the DESCRIPTION is what you need, or when you want the other direction of a dependency (what breaks if this one changes). DEPENDENCIES: a task that waits on an open task cannot be completed until that one is done — that is the check task_update enforces, and this is where you see why it would refuse. LIMITS: one task per call. ON ERROR: an unknown id is refused and lists nothing; task_list is how you find the right one.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"integer\",\"description\":\"the task id from task_create or task_list\"}},\"required\":[\"id\"]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "task_get: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
