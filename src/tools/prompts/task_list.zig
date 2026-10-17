//! The `task_list` tool's schema text: the prose and the parameters the model
//! reads when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "task_list";

pub const description: []const u8 =
    "List every task with its id, status, owner and what it is waiting on. USE IT WHEN: you finished a task and want to know what is available now, when you need to see the whole shape of the work, or after a compaction, which is the one moment a task list and a plan are the only things that survive. READ IT AS: a task is AVAILABLE when it is pending, unassigned and waiting on nothing — take the LOWEST id first, because earlier tasks are usually the ones that set up the context the later ones need. A task that says waiting on #N is not available; do not start it, and if it is the only thing left, unblock it by doing #N. EFFICIENCY: one call returns the whole graph, so prefer it to a task_get per task; task_get is for the one task whose full description you need. LIMITS: one line per task, so a long description is NOT included. ON ERROR: nothing to list is not an error, it says the list is empty and how to start one.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{},\"required\":[]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "task_list: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
