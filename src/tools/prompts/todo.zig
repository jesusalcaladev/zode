//! The `todo` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "todo";

pub const description: []const u8 =
    "Write the task list the USER SEES on screen. Call it when you FINISH a step and another is still open — that is when it earns its call, because the user reads your last line to know whether you are still working. Two forms: send the WHOLE list in items when you make the plan or it changes shape; afterwards change single steps with update (index, status or index, text), remove ([3]) or add ([{content}]); indexes are 1-BASED. Prefer update over resending the list to mark a step done. Mark exactly one step in_progress while you work on it, never more than one. Call it again when a step finishes, and clear it when everything is done. Do not use it for a single obvious step or to think out loud: a list that never changes is noise. LIMITS: max 20 steps per call.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"items\":{\"type\":\"array\",\"maxItems\":20,\"items\":{\"type\":\"object\",\"properties\":{\"content\":{\"type\":\"string\",\"description\":\"imperative, short: what this step does\"},\"status\":{\"type\":\"string\",\"enum\":[\"pending\",\"in_progress\",\"done\"]}},\"required\":[\"content\"]},\"description\":\"the WHOLE list, which REPLACES the previous one.\"},\"update\":{\"type\":\"array\",\"maxItems\":20,\"items\":{\"type\":\"object\",\"properties\":{\"index\":{\"type\":\"integer\",\"description\":\"1-based position of the step\"},\"status\":{\"type\":\"string\",\"enum\":[\"pending\",\"in_progress\",\"done\"]},\"text\":{\"type\":\"string\",\"description\":\"new wording for the step\"}},\"required\":[\"index\"]},\"description\":\"change ONE step in place: index,status to mark it, index,text to reword it.\"},\"remove\":{\"type\":\"array\",\"maxItems\":20,\"items\":{\"type\":\"integer\"},\"description\":\"drop steps by 1-based position.\"},\"add\":{\"type\":\"array\",\"maxItems\":20,\"items\":{\"type\":\"object\",\"properties\":{\"content\":{\"type\":\"string\"},\"status\":{\"type\":\"string\",\"enum\":[\"pending\",\"in_progress\",\"done\"]}},\"required\":[\"content\"]},\"description\":\"append one or more steps to the end of the list.\"}}}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "todo: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
