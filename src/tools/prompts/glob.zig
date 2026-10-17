//! The `glob` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "glob";

pub const description: []const u8 =
    "Find files matching a glob pattern (*, **, ?). USE IT WHEN: you know the shape of a file name but not where it lives (e.g. src/**/*.zig, **/config.*). ARGUMENTS: subdir walks only that directory; the pattern matches the path from the project root OR the path inside subdir, so both spellings name the same file. limit picks how many paths come back (an integer from 1 to 200, default 200) and the result says when it cut something off. sort is newest or oldest (by modification time) or name — pass sort=newest together with limit for the N newest files; the default is walk order. USE INSTEAD OF: grep when you are looking for text inside files — glob only matches names. EFFICIENCY: beyond the limit it says so and you narrow the pattern. LIMITS: skips .git, node_modules, .zig-cache, zig-pkg, target, dist, build and anything starting with . . ON ERROR: no matches means the pattern found nothing — widen it or check the directory with list_files; a limit or sort outside these values is rejected with the accepted values shown.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\"},\"subdir\":{\"type\":\"string\",\"description\":\"walk only this directory (default: the whole project)\"},\"limit\":{\"type\":\"integer\",\"description\":\"max paths returned, 1-200 (default 200)\"},\"sort\":{\"type\":\"string\",\"enum\":[\"newest\",\"oldest\",\"name\"],\"description\":\"order by modification time or by name (default: walk order)\"}},\"required\":[\"pattern\"]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "glob: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
