//! The `task_update` tool's schema text: the prose and the parameters the model
//! reads when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "task_update";

pub const description: []const u8 =
    "Change a task: its status, subject, description, owner, or the dependencies in either direction. USE IT WHEN: you START a task (status in_progress plus owner, in ONE call), you FINISH one (status completed), requirements changed, or a dependency appeared. USE INSTEAD OF: task_create for anything about a task that already exists — creating a second task for the same work loses the dependencies the first one had. WHEN TO COMPLETE: only when the work is fully done. Tests failing, a partial implementation, an unresolved error or a file you could not find all mean NOT completed; say so in the answer instead. DEPENDENCIES: add_blocks on A means B cannot start until A is done; add_blocked_by is the same edge from the other side, and either spelling writes both (so never send both for one relation). Completing a task is REFUSED while what it waits on is still open, and a completion reports what it just unblocked — read that line instead of re-listing. owner is required to start a task: use main for your own work. LIMITS: one task per call; all fields are validated before any is applied, so a refusal leaves the task exactly as it was. ON ERROR: status deleted removes the task (same as task_stop); an unknown status lists the accepted ones; an unknown id or an impossible edge changes nothing.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"integer\",\"description\":\"the task id\"},\"status\":{\"type\":\"string\",\"enum\":[\"pending\",\"in_progress\",\"completed\",\"deleted\"],\"description\":\"in_progress needs owner; completed is refused while a prerequisite is open; deleted removes the task\"},\"subject\":{\"type\":\"string\"},\"description\":{\"type\":\"string\"},\"owner\":{\"type\":\"string\",\"description\":\"who is doing it; main for your own work\"},\"add_blocks\":{\"type\":\"array\",\"items\":{\"type\":\"integer\"},\"description\":\"ids that cannot start until this one is done\"},\"add_blocked_by\":{\"type\":\"array\",\"items\":{\"type\":\"integer\"},\"description\":\"ids that must be done before this one can start (the same edge, from the other side)\"}},\"required\":[\"id\"]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "task_update: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
