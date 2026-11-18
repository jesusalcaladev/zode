//! The `task` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "task";

pub const description: []const u8 =
    "Send an investigation to a SUBAGENT with its own context; get a short report with paths and line numbers. USE WHEN: a wide search - grepping a large tree, tracing uses, reading many files for one question. What it reads is paid ONCE in a thrown-away window, not resent in your context on every step, so a wide search is cheaper this way. It cannot ask the user; if only the user can decide, it says so and you decide whether to ask. USE INSTEAD OF: doing the wide search yourself. For independent unknowns send distinct scoped task calls in the SAME message - reports return in request order with live completion progress. Usually 2-4 tracks suffice; one focused question per call; never duplicate or split merely by file. They run concurrently up to the configured limit (/task-parallel). ROLES: role = explore (read-only search; paths and lines, never edits), plan (read-only architect producing an ordered plan), verify (try to break the change); unknown roles fall back to default. MEMORY: role runs may read and append per-project per-role lessons; memory is consulted, not inlined. RESUME/FORK: resume with a returned id continues that window; fork copies its context for a different question (original untouched). LIMITS: effort low, depth 1, 24k budget - a bounded search, not a design. Running out of steps is not an error; the partial report is useful. run_in_background: true returns an id at once and notifies when the report lands.";

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
