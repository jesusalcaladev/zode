//! The `send_user_message` tool's schema (Phase 21): the durable answer to the
//! user. `message` is what they READ (markdown); the log is not the answer.
const validate = @import("validate.zig");

pub const name = "send_user_message";

pub const description: []const u8 =
    "Write THE answer to the user. Your message is what they read, in markdown; the tool log is not the answer. Write the answer in plain text and end with done! — do not narrate your steps here. Use status=normal for a reply, or status=proactive when YOU initiate contact (a scheduled task finished, a blocker surfaced in the background). Optional attachments take paths to images/diffs/logs, rendered inline; a path that does not exist is a named error. This is the durable statement, not a replacement for streaming: use it for the final answer and in non-interactive runs. An empty message is refused. When you have the result, write it here with done! instead of leaving it buried in tool results.";

const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"message\":{\"type\":\"string\",\"description\":\"the answer the user reads, in markdown; end with done!\"},\"status\":{\"type\":\"string\",\"description\":\"normal (reply) or proactive (you initiate contact)\"},\"attachments\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"kind\":{\"type\":\"string\",\"description\":\"infer|image|diff|log\"}}},\"description\":\"paths rendered inline; a missing path is an error\"}},\"required\":[\"message\"]}";

pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "send_user_message: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
