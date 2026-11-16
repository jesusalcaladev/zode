//! The `config` tool's schema (Phase 23): read or change whitelisted settings.
//! Secrets and auth.json are NOT reachable — an unknown key lists the known ones.
const validate = @import("validate.zig");

pub const name = "config";

pub const description: []const u8 =
    "Read or change a whitelisted setting for this session. WHITELIST ONLY: model, effort, compaction, auto_check, task_parallel, output_style, web_allow_local. Use operation=get with a key to read its current value, or operation=set with key and value to change it. An unknown key is refused with the list of known ones. Credentials and auth.json are NEVER reachable: there is no key for them. Changing model, effort or compaction affects every later request, so those writes ask for permission unless already allowed — make the deliverable durable first. Values: effort none|minimal|low|medium|high|xhigh|max; compaction off|elide|full; auto_check and web_allow_local on|off; task_parallel 1-8; model and output_style are free strings validated against the live catalog.";

const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"operation\":{\"type\":\"string\",\"description\":\"get or set\"},\"key\":{\"type\":\"string\",\"description\":\"one of the whitelisted keys\"},\"value\":{\"type\":\"string\",\"description\":\"new value, only for set\"}},\"required\":[\"operation\",\"key\"]}";

pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "config: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
