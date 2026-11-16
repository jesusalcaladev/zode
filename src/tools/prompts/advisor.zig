//! The `advisor` tool's schema (Phase 32.2): no arguments — the whole
//! conversation is forwarded automatically by the harness. One LLM call at
//! the checkpoint, as a read-only task-shaped subagent (effort low).
const validate = @import("validate.zig");

pub const name = "advisor";

pub const description: []const u8 =
    "Ask a second, independent agent to review the conversation before you commit to an answer. No arguments: the harness forwards the whole session automatically. Call it BEFORE substantive work (orientation is not substantive; writing, editing and declaring an answer are) and again when you believe the task is complete — but make the deliverable durable first, because this call takes time and an unwritten result does not persist through it. A passing self-test is NOT evidence the advice is wrong: it is evidence your test does not check what the advice checks. If advice conflicts with data you already retrieved, surface it in one more call; do not silently switch. The advisor cannot see your tools — it only reads the conversation and advises in words.";

const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{},\"required\":[]}";

pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "advisor: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
