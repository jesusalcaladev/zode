//! The `team_status` tool's schema text, kept in its own file so the rule can be
//! changed and TESTED without touching the tools array or any other tool.
const validate = @import("validate.zig");

pub const name = "team_status";

pub const description: []const u8 =
    "Report the current team: roster, who acknowledged shutdown, and queued messages. No arguments.";

const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{},\"required\":[]}";

pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "team_status: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
