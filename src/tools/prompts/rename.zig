//! The `rename` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "rename";

pub const description: []const u8 =
    "Rename a symbol EVERYWHERE it appears as code, in ONE call, and report every file it touched. Only whole-word occurrences that are real CODE are changed — a name inside a string, a comment, or a longer identifier is left alone. USE IT WHEN: you are renaming a symbol across the codebase. USE INSTEAD OF: a series of edit calls — a rename applied to nine files out of ten leaves a codebase that does not compile, and only this tool says which file was skipped. EFFICIENCY: one call, one round trip, every file touched reported. Run refs first if two same-named symbols might exist; narrow with subdir then. LIMITS: max 200 replacements per call — beyond that it refuses and says so; new name must be a plain identifier; cannot be the same as the old name. ON ERROR: if a file could not be read it is named as SKIPPED; the old name remains there. After renaming, run the build and tests — a rename is only done when it compiles.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"symbol\":{\"type\":\"string\"},\"to\":{\"type\":\"string\",\"description\":\"the new name; must be a plain identifier\"},\"subdir\":{\"type\":\"string\"}},\"required\":[\"symbol\",\"to\"]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "rename: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
