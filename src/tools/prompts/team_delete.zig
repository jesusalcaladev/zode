//! The `team_delete` tool's schema text, kept in its own file so the rule can be
//! changed and TESTED without touching the tools array or any other tool.
const validate = @import("validate.zig");

pub const name = "team_delete";

pub const description: []const u8 =
    "Shut down the current team: request an orderly acknowledgement from every teammate and clear the roster. Call it before ending a turn that created a team - no teammate outlives the app.";

const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{},\"required\":[]}";

pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "team_delete: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
