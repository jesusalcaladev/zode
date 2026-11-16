//! The `send_message` tool's schema text, kept in its own file so the rule can be
//! changed and TESTED without touching the tools array or any other tool.
const validate = @import("validate.zig");

pub const name = "send_message";

pub const description: []const u8 =
    "Send a message to a teammate by name, or to everyone with to set to an asterisk (explicitly expensive: one delivery per teammate). This is the ONLY channel another agent can see - plain assistant text is NOT visible to another agent. An unknown name is a named error.";

const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"to\":{\"type\":\"string\",\"description\":\"teammate name or * for all\"},\"message\":{\"type\":\"string\",\"description\":\"the message\"}},\"required\":[\"to\",\"message\"]}";

pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "send_message: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
