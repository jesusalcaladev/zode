//! The `ask` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "ask";

pub const description: []const u8 =
    "Ask the USER one short, precise question. Use it ONLY when the answer changes what you do next (a choice between approaches, an ambiguous request). Do NOT ask what you can find out yourself — read, grep, or run the command first. One question per step, max 3 per turn. Put your recommendation first so the user can just press Enter. 2-5 options = menu; none = free text. If the user presses Esc, decide yourself, state which option you picked and why, then continue — do not re-ask. header = 2-3 word label for the dialog, not the question.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"question\":{\"type\":\"string\",\"description\":\"the question, with your recommendation and its reason up front\"},\"header\":{\"type\":\"string\",\"description\":\"2-3 word label for the dialog\"},\"options\":{\"type\":\"array\",\"minItems\":2,\"maxItems\":5,\"items\":{\"type\":\"string\",\"description\":\"one choice, on a single line\"}}},\"required\":[\"question\"]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "ask: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
