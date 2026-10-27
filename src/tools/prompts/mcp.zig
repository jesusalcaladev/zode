//! The `mcp` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! The prose has to teach the DEFERRED part, because the model has never seen
//! an MCP server's tools: they are not in its prompt. The three sentences that
//! matter are that the schemas come with a search, that a call is asked for,
//! and that a tool nobody searched for is a tool whose arguments nobody knows.
const validate = @import("validate.zig");

pub const name = "mcp";

pub const description: []const u8 =
    "Call a tool published by an MCP server (an external service zode talks to over stdio). " ++
    "The servers are the user's own, and their tools are NOT in your prompt: you find them with a search, and the schema comes back with the search result. " ++
    "OPERATIONS: search (words that appear in a tool's name or description; you get its input schema), list (every server and every tool it publishes), call (one tool, with its arguments). " ++
    "USE IT WHEN: the task needs a capability no built-in tool has (an issue tracker, a database, a design file). " ++
    "DO NOT GUESS a tool's name or its arguments: search for it first and read the schema that comes back, because a schema you did not read is a call that will be refused. " ++
    "A CALL IS ASKED FOR: the user sees which tool you are about to run and can refuse it, and an answer of always allow remembers that one tool. " ++
    "The first call to a server starts it, which takes a moment; the list and the search are what you pay for.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"operation\":{\"type\":\"string\",\"description\":\"search | list | call\"},\"query\":{\"type\":\"string\",\"description\":\"search only: the words to look for in a tool's name or description\"},\"server\":{\"type\":\"string\",\"description\":\"call only: the server that publishes the tool\"},\"tool\":{\"type\":\"string\",\"description\":\"call only: the tool to call, or its qualified name server.tool\"},\"arguments\":{\"type\":\"object\",\"description\":\"call only: the arguments, exactly as the schema the search returned says\"}},\"required\":[\"operation\"]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "mcp: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
