//! The `refs` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "refs";

pub const description: []const u8 =
    "Where a symbol is DEFINED and where it is USED, in one call, with the two separated: definitions first, then calls, then plain references. One plain identifier only — not a pattern (use grep for text). USE IT WHEN: you need to find a symbol's definition and all its call sites. USE INSTEAD OF: guessing the declaration shape for the language, running two greps, and working out which hit is the definition — that is three round trips where one answers directly. EFFICIENCY: knows declaration shapes of zig, rust, go, python, js/ts, c, sh and steps over Go method receivers, so refs Listen finds func (s *Server) Listen() instead of calling it a use. Skips strings, comments, and longer identifiers. LIMITS: one symbol per call; subdir narrows the tree; capped on files and hits. ON ERROR: not a plain identifier -> use grep; no declaration -> the symbol does not exist as code here.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"symbol\":{\"type\":\"string\"},\"subdir\":{\"type\":\"string\",\"description\":\"where to look (default: the whole project)\"}},\"required\":[\"symbol\"]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "refs: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
