//! The `goal` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "goal";

pub const description: []const u8 =
    "Say whether the OBJECTIVE of this turn was reached. Only meaningful when the user set one with /goal; without it there is nothing to decide and you should not call this. Two answers, and both end the turn: met with a summary of what you finished AND the evidence (a command you ran, a number you measured), or blocked with the reason AND what_would_unblock, which is required. Call met only when you are certain: a confident summary is not the same as having checked. Do not use blocked because something is hard or slow — if neither is true, keep working and do not call this. what_would_unblock is the whole safety of the feature: without it, blocked is indistinguishable from giving up.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"status\":{\"type\":\"string\",\"enum\":[\"met\",\"blocked\"],\"description\":\"met = reached, blocked = cannot be done here\"},\"summary\":{\"type\":\"string\",\"description\":\"what you finished and how you know, or why it cannot be done\"},\"what_would_unblock\":{\"type\":\"string\",\"description\":\"REQUIRED when blocked: the one thing that would change the answer (a credential, a service that is up, a decision only the user can make)\"}},\"required\":[\"status\",\"summary\"]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "goal: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
