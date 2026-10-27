//! The `task` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "task";

pub const description: []const u8 =
    "Send a read-only investigation to a SUBAGENT that has its own context window, and get back a short report (a few lines with paths and line numbers). USE IT WHEN: the search is big — grepping across a large tree, tracing where something is used, reading many files to answer one question. Everything the subagent reads is paid for ONCE in a window that is then thrown away, instead of staying in your context and being resent on every remaining step — so for a wide search this is much cheaper than doing it yourself. It cannot write anything and cannot ask the user anything; if it needs a decision only the user can make, it says so in the report and you decide whether to ask. USE INSTEAD OF: doing a wide search yourself and bloating your context. For several independent unknowns, split them into distinct scoped questions and send consecutive task calls in the SAME message — reports return in request order with live completion progress. Usually 2–4 useful tracks are enough; keep one focused question per task, never duplicate work, never split merely by file. They run concurrently up to the configured limit (/task-parallel). LIMITS: effort is always low, depth 1, 24k budget — it is a bounded search, not a design. Running out of steps is not an error; the partial report is still useful.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"description\":{\"type\":\"string\",\"description\":\"one line: what to find out\"},\"prompt\":{\"type\":\"string\",\"description\":\"the full question, including where to look and what to report back\"}},\"required\":[\"description\"]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "task: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
