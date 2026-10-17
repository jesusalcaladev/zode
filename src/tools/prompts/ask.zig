//! The `ask` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "ask";

pub const description: []const u8 =
    "Ask the USER one question, and wait for the answer. USE IT WHEN: the answer changes what you do next — a choice between approaches, an ambiguous request with two real readings, a which one. Do NOT ask what you can find out yourself: read the file, grep, run the command first, and only ask if it is still unclear after that. One question per step, at most three in a whole turn. Put your recommendation first in the question text so the user can just press enter. With 2 to 5 options it becomes a menu; with no options the user types free text. If the user does not answer (esc) you must decide on your own, say which option you picked and why, and carry on — do not ask again. header is a 2-3 word label for the dialog, not the question.";

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
