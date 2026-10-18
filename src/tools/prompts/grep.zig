//! The `grep` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "grep";

pub const description: []const u8 =
    "Search file contents with a regex. Returns path:line:text matches. USE IT WHEN: you know a piece of text and need the files that contain it. USE INSTEAD OF: refs when you are looking for where a SYMBOL is declared or called — refs understands code shape, grep does not. EFFICIENCY: uses ripgrep, then git grep, then system grep, then a pure-Zig fallback — it never fails for lack of a binary. Capped at ~80 lines / 150 matches; beyond that it says so. LIMITS: pass subdir to search only part of the tree; the pattern comes from you and ends with -- so a leading dash is read as a pattern, not an option. CONTEXT: pass context (lines around match), context_before, context_after for surrounding lines; glob to filter files by pattern; type for common file types (zig, js, ts, py, rs, go, etc.); output_mode to return content, files_with_matches, or count; head_limit to cap results. ON ERROR: no matches — rephrase the pattern or check spelling.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\"},\"subdir\":{\"type\":\"string\",\"description\":\"where to look (default: the whole project)\"},\"context\":{\"type\":\"integer\",\"description\":\"lines before and after each match (like -C)\",\"minimum\":0},\"context_before\":{\"type\":\"integer\",\"description\":\"lines before each match (like -B)\",\"minimum\":0},\"context_after\":{\"type\":\"integer\",\"description\":\"lines after each match (like -A)\",\"minimum\":0},\"glob\":{\"type\":\"string\",\"description\":\"filter files by glob pattern (e.g. *.zig)\"},\"type\":{\"type\":\"string\",\"description\":\"filter by file type (zig, js, ts, py, rs, go, java, cpp, c, h, hpp, rb, php, sh, sql, md, json, yaml, toml, html, css, scss, less, xml)\"},\"output_mode\":{\"type\":\"string\",\"enum\":[\"content\",\"files_with_matches\",\"count\"],\"description\":\"what to return: matching lines, matching file paths, or match counts per file\"},\"head_limit\":{\"type\":\"integer\",\"description\":\"max number of results to return\",\"minimum\":1}},\"required\":[\"pattern\"]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "grep: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
