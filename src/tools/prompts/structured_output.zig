//! The `structured_output` tool's schema (Phase 22): the final, validated
//! answer for scripted runs (`--chat --schema`). It is ONLY offered in that
//! mode; a human in the TUI never sees it.
const validate = @import("validate.zig");

pub const name = "structured_output";

pub const description: []const u8 =
    "In --schema mode you MUST call this tool exactly once at the END, after all other work, with a single object that matches the caller's JSON schema. The harness validates the object against that schema before the run exits: a mismatch is returned to you by name so you can fix it and call again. Do not answer in prose instead — the script reads only this object. Make sure any deliverable is durable before this call: it takes time and an unwritten result does not persist through it.";

const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"object\":{\"type\":\"object\",\"description\":\"the complete answer matching the caller's schema\"}},\"required\":[\"object\"]}";

pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "structured_output: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
