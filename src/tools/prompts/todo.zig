//! The `todo` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "todo";

pub const description: []const u8 =
    "Write the implementation plan the USER SEES on screen, with enough context that implementation can follow it without guessing. When you CREATE the plan (items), include objective (what the feature/change must achieve and how success is known), approach (overall how you will do it: files/strategy), and guardrails (constraints, what must not change/regress, and how you will verify). Make steps concrete actions, not loose tasks: for each step prefer how (the implementation move: file/symbol/command) and verify (how to confirm this step) when useful. Call it when you FINISH a step and another is still open. Two forms: send the WHOLE list in items to make/reshape the plan (you may resend items without objective/approach/guardrails to preserve the existing brief); afterwards change single steps with update (index, status and/or text/how/verify), remove ([3]) or add ([{content}]); indexes are 1-BASED. Prefer update over resending the list to mark a step done. Mark exactly one step in_progress while you work on it, never more than one. Clear it when everything is done. Do not use it for a single obvious step or to think out loud. LIMITS: max 20 steps per call.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"objective\":{\"type\":\"string\",\"description\":\"what the feature/change must achieve and how success is known\"},\"approach\":{\"type\":\"string\",\"description\":\"overall implementation strategy: key files, modules, or commands\"},\"guardrails\":{\"type\":\"string\",\"description\":\"constraints, what must not break/regress, and required verification\"},\"items\":{\"type\":\"array\",\"maxItems\":20,\"items\":{\"type\":\"object\",\"properties\":{\"content\":{\"type\":\"string\",\"description\":\"imperative, short: what this step does\"},\"how\":{\"type\":\"string\",\"description\":\"how to do it: file/symbol/command or concrete implementation move\"},\"verify\":{\"type\":\"string\",\"description\":\"how to confirm this step (test, check, or observable result)\"},\"status\":{\"type\":\"string\",\"enum\":[\"pending\",\"in_progress\",\"done\"]}},\"required\":[\"content\"]},\"description\":\"the WHOLE list, which REPLACES the previous one. Include objective/approach/guardrails on new plans.\"},\"update\":{\"type\":\"array\",\"maxItems\":20,\"items\":{\"type\":\"object\",\"properties\":{\"index\":{\"type\":\"integer\",\"description\":\"1-based position of the step\"},\"status\":{\"type\":\"string\",\"enum\":[\"pending\",\"in_progress\",\"done\"]},\"text\":{\"type\":\"string\",\"description\":\"new wording for the step\"},\"how\":{\"type\":\"string\",\"description\":\"updated implementation note\"},\"verify\":{\"type\":\"string\",\"description\":\"updated verification note\"}},\"required\":[\"index\"]},\"description\":\"change ONE step in place by 1-based index.\"},\"remove\":{\"type\":\"array\",\"maxItems\":20,\"items\":{\"type\":\"integer\"},\"description\":\"drop steps by 1-based position.\"},\"add\":{\"type\":\"array\",\"maxItems\":20,\"items\":{\"type\":\"object\",\"properties\":{\"content\":{\"type\":\"string\"},\"how\":{\"type\":\"string\"},\"verify\":{\"type\":\"string\"},\"status\":{\"type\":\"string\",\"enum\":[\"pending\",\"in_progress\",\"done\"]}},\"required\":[\"content\"]},\"description\":\"append one or more steps to the end of the list.\"}}}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "todo: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
