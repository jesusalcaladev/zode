//! The `task` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "task";

pub const description: []const u8 =
    "Send an investigation to a SUBAGENT that has its own context window, and get back a short report (a few lines with paths and line numbers). USE IT WHEN: the search is big — grepping across a large tree, tracing where something is used, reading many files to answer one question. Everything the subagent reads is paid for ONCE in a window that is then thrown away, instead of staying in your context and being resent on every remaining step — so for a wide search this is much cheaper than doing it yourself. It cannot ask the user anything; if it needs a decision only the user can make, it says so in the report and you decide whether to ask. USE INSTEAD OF: doing a wide search yourself and bloating your context. For several independent unknowns, split them into distinct scoped questions and send consecutive task calls in the SAME message — reports return in request order with live completion progress. Usually 2–4 useful tracks are enough; keep one focused question per task, never duplicate work, never split merely by file. They run concurrently up to the configured limit (/task-parallel). ROLES: set `role` to `explore` (broad read-only search; report paths and lines, never edits), `plan` (read-only architect: explore, then produce an ordered plan), or `verify` (try to break the change: run/exercise it, find what the first pass hides). Unknown roles fall back to the default. MEMORY: role runs may read and append per-project, per-role lessons; memory is consulted, not inlined into the prompt. RESUME/FORK: pass `resume` with a returned subagent id to continue that window intact, or `fork` with an id to copy its context for a different question (the original is not shared). LIMITS: effort is always low, depth 1, 24k budget — a bounded search, not a design. Running out of steps is not an error; the partial report is still useful. Set `run_in_background: true` to run the subagent in the background: the call returns an id immediately and the model is notified when the report lands, so the turn is not parked while a long search runs.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"description\":{\"type\":\"string\",\"description\":\"one line: what to find out\"},\"prompt\":{\"type\":\"string\",\"description\":\"the full question, including where to look and what to report back\"},\"role\":{\"type\":\"string\",\"description\":\"built-in role: explore, plan, or verify\"},\"definition\":{\"type\":\"string\",\"description\":\"agent definition name from .zode/agents or ~/.config/zode/agents\"},\"name\":{\"type\":\"string\",\"description\":\"register this run as a persistent teammate with this name (needs an active team)\"},\"team\":{\"type\":\"string\",\"description\":\"team name for a teammate run\"},\"resume\":{\"type\":\"string\",\"description\":\"subagent id to resume with its window intact\"},\"fork\":{\"type\":\"string\",\"description\":\"subagent id to fork (copy context) for a different question\"},\"run_in_background\":{\"type\":\"boolean\",\"description\":\"run the subagent in the background; returns an id immediately instead of waiting\"}},\"required\":[\"description\"]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "task: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
