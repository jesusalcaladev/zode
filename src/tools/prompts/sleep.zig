//! The `sleep` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "sleep";

pub const description: []const u8 =
    "Wait a number of seconds without holding a shell process. USE IT WHEN: you are waiting on something you cannot watch any other way (a deploy, a rate limit, a file another process writes) and there is genuinely nothing else to do. USE INSTEAD OF: bash sleep, which needs a shell and a process for the same wait. DO NOT USE IT AS A POLL TIMER: for a background job this harness started, bash_output returns exactly what arrived since the last look — and it also tells you whether the job is still running, which a timer never does. THE REAL COST is not the seconds, it is that the TURN IS BLOCKED: the user cannot send anything new until this returns and nothing else happens in the meantime, so do the independent work FIRST and sleep once, or end the turn and let the user come back. And each wake-up costs ONE API CALL — the turn's next iteration — on top of the seconds. One call to sleep is also one call not spent on the work. LIMITS: 300 seconds maximum, and over that it is refused rather than trimmed, so you always know what happened. ESC cuts it short, and the result says how much of the wait actually happened instead of repeating what was asked for.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"seconds\":{\"type\":\"number\",\"description\":\"how long to wait; fractions are fine; 300 max\"}},\"required\":[\"seconds\"]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "sleep: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
