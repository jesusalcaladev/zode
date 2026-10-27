//! The `task_create` tool's schema text: the prose and the parameters the model
//! reads when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "task_create";

pub const description: []const u8 =
    "Create a task: a work item with an id, a status, an owner and dependencies. USE IT WHEN: the work has three or more steps, when steps depend on each other, or when the user handed you a list. USE INSTEAD OF: todo, which is a different thing — todo is the ordered plan the USER watches on screen, this is what you coordinate on. Tasks keep their id across edits, carry dependencies and can be claimed; a plan is rewritten top to bottom every time you re-read your own steps. When both are useful, use todo for the plan and tasks for the parts with an order that is not linear. EFFICIENCY: create every task of the known work in ONE call each before starting, then claim with task_update (status in_progress, owner main). A task created mid-way is fine, a task created after the work is history. DEPENDENCIES: blocks takes ids that cannot start until this one is done; with no ids to give yet, link them later with task_update add_blocks. Ids are stable and never reused. LIMITS: 64 tasks per session; subject max 160 chars, description max 4000. ON ERROR: an id in blocks that does not exist keeps the task and drops that edge (the result says so); no subject is refused.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"subject\":{\"type\":\"string\",\"description\":\"short imperative title: what will be true when it is done\"},\"description\":{\"type\":\"string\",\"description\":\"what needs to be done, detailed enough for another agent to pick it up\"},\"blocks\":{\"type\":\"array\",\"items\":{\"type\":\"integer\"},\"description\":\"ids of tasks that cannot start until this one is done\"}},\"required\":[\"subject\"]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "task_create: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
