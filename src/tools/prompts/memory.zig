//! The `memory` tool's schema: consult and manage the per-project memory store.
//!
//! Memories are durable, user-approved project notes stored in `.zode/memory/`.
//! They are intentionally **out of the prompt until consulted**.
const validate = @import("validate.zig");

pub const name = "memory";

pub const description: []const u8 =
    "Consult the per-project persistent memory store (approved notes under .zode/memory). Memories are out of the prompt until you ask for them. USE IT WHEN: you need durable project facts, decisions, or conventions saved from earlier work. OPERATIONS: `search` finds matching memories under a budget; `list` shows ids/titles; `get` returns one memory by id; `pending` lists proposals waiting for user approval; `approve` moves a pending proposal into the store after the user asked you to approve it; `propose` saves a candidate proposal for user approval (do not present unapproved proposals as facts). LIMITS: search results are capped by budget — entries outside the budget are omitted, not inlined.";

const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"operation\":{\"type\":\"string\",\"enum\":[\"search\",\"list\",\"get\",\"pending\",\"approve\",\"propose\"],\"description\":\"search, list, get, pending, approve, or propose\"},\"query\":{\"type\":\"string\",\"description\":\"search text (for search)\"},\"id\":{\"type\":\"string\",\"description\":\"memory or pending proposal id (for get/approve)\"},\"title\":{\"type\":\"string\",\"description\":\"short title (for propose)\"},\"body\":{\"type\":\"string\",\"description\":\"memory text with evidence (for propose)\"},\"tags\":{\"type\":\"string\",\"description\":\"optional comma-separated tags (for propose)\"},\"budget\":{\"type\":\"integer\",\"description\":\"max bytes for search results (default 4000)\"}},\"required\":[\"operation\"]}";

pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "memory: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
