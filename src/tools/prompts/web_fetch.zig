//! The `web_fetch` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "web_fetch";

pub const description: []const u8 =
    "Fetch an http(s) URL and return the content as readable text (HTML tags, scripts and styles are stripped; JSON and plain text pass through untouched). USE IT WHEN: reading documentation, a release page, or any URL the user mentions. USE INSTEAD OF: bash curl — this asks for no permission and strips markup automatically. EFFICIENCY: truncated to a byte budget (default 16000, max 200000); the truncation note names the exact offset to pass to continue where it stopped — pass that number, do not re-fetch the same first page. A per-session URL cache avoids re-fetching the same page; pass force=true to bypass it. EXTRACTION: when question is set, a secondary model answers from the fetched window and returns the answer plus the exact quotes it relied on (quotes are mandatory evidence). LIMITS: refuses credential endpoints (169.254.0.0/16, metadata.google.internal, fd00:ec2::254) and loopback/private addresses unless ZODE_WEB_ALLOW_LOCAL=1; config web_domains allow/block lists apply (block wins). ON ERROR: the notice says which host was refused and what to set if you genuinely need it.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\"},\"max_bytes\":{\"type\":\"integer\",\"description\":\"bytes of text to keep (default 16000, max 200000)\"},\"offset\":{\"type\":\"integer\",\"description\":\"byte offset into the extracted text (0 = start); pass the value the truncation note names to continue reading deeper\"},\"force\":{\"type\":\"boolean\",\"description\":\"bypass the per-session URL cache and re-fetch\"},\"question\":{\"type\":\"string\",\"description\":\"narrow question to answer from a long page; returns the answer plus mandatory quotes from the page window\"}},\"required\":[\"url\"]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "web_fetch: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
