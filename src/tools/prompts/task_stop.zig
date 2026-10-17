//! The `task_stop` tool's schema text: the prose and the parameters the model
//! reads when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "task_stop";

pub const description: []const u8 =
    "Remove a task that is not going to happen: it was created in error, the user dropped it, or it was superseded by another task. USE IT WHEN: the work behind the task is cancelled, NOT when it is finished (that is task_update status completed, which keeps the record that it was done) and NOT when it is merely stuck (leave it with the blocker named, so the reason survives). USE INSTEAD OF: bash_kill, which is a completely different tool — this stops a TASK, that kills a running process; a cancelled task does not touch any process. The removal clears every edge that pointed at it, in both directions, and the result says how many tasks stop waiting on it, so nothing is left pointing at an id that no longer exists. EFFICIENCY: one call, no task_list afterwards: the result names what changed. LIMITS: one task per call; the id is never reused. ON ERROR: an unknown id is refused and changes nothing; the other tasks are untouched by a removal.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"integer\",\"description\":\"the task to remove\"},\"reason\":{\"type\":\"string\",\"description\":\"one line kept in the result, so a later reader knows why it went\"}},\"required\":[\"id\"]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "task_stop: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
