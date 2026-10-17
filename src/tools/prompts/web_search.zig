//! The `web_search` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "web_search";

pub const description: []const u8 =
    "Search the web and return titles, URLs and short snippets. USE IT WHEN: you need to find information you do not already have. Use ONE focused query; the default is 5 results. Snippets are for discovery — fetch only the best primary source(s) when you need to verify details, and cite the supporting URL. USE INSTEAD OF: bash curl against a search engine — this handles rate limits, fallbacks, and honest no results messages. LIMITS: max 20 results; if the engine is rate-limiting it says WAIT, not rephrase — do not retry in a loop. ON ERROR: names the engine and the reason; a broken configured key degrades the search, it does not stop it.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"},\"max_results\":{\"type\":\"integer\",\"description\":\"1..20, default 5\"}},\"required\":[\"query\"]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "web_search: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
