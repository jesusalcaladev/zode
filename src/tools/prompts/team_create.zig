//! The `team_create` tool's schema text, kept in its own file so the rule can be
//! changed and TESTED without touching the tools array or any other tool.
const validate = @import("validate.zig");

pub const name = "team_create";

pub const description: []const u8 =
    "Start a persistent team and its shared task list (Team equals TaskList). USE IT WHEN: a group of collaborators must work over several turns and claim work from a shared list. Do not start one for a single bounded search - that is task. Pass name; teammates are added by the lead and start read-only.";

const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\",\"description\":\"stable team name\"}},\"required\":[\"name\"]}";

pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "team_create: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
