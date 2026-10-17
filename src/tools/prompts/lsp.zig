//! The `lsp` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! This module did not exist while the tool did: `defs` declared `lsp` and the tools
//! array never carried it, so the model could not call a tool that was fully
//! implemented. The dispatcher's count test is what said so.
const validate = @import("validate.zig");

pub const name = "lsp";

pub const description: []const u8 =
    "Ask a language server about the code: where a symbol is DEFINED, where it is USED, its type, the symbols in a file or in the workspace, its call hierarchy. " ++
    "USE IT WHEN: `grep` or `refs` would be guessing — the answer depends on types, overloads, generics or macros, and being RIGHT is worth more than being fast. " ++
    "USE INSTEAD OF: `refs` for an ambiguous name (the same word in a comment or a string is not a use) and `grep` for anything the compiler understands and text does not. " ++
    "EFFICIENCY: pass `symbol` and the position is FOUND for you in the file — never count columns by hand; a `symbol` that appears twice, or not at all, is reported instead of guessed, and that answer costs no server time. " ++
    "The first question about a file STARTS its server, which then indexes it: expect a pause on the first call and batch what you can on the same file. " ++
    "LIMITS: `file` is required because it also picks the server; ops that need a position want `symbol`, or `line`+`character` (1-based); `workspaceSymbol` wants `query`. " ++
    "ON ERROR: no server for that extension, a document too big for one, and a server that never answered are three different messages, and each one names the fallback (`refs`, `grep`, `read`).";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"operation\":{\"type\":\"string\",\"description\":\"goToDefinition | findReferences | hover | documentSymbol | workspaceSymbol | goToImplementation | prepareCallHierarchy | incomingCalls | outgoingCalls\"},\"file\":{\"type\":\"string\",\"description\":\"the file the question is about; it also picks the language server\"},\"symbol\":{\"type\":\"string\",\"description\":\"the name to ask about: the position is found for you, so do not count columns\"},\"query\":{\"type\":\"string\",\"description\":\"workspaceSymbol only: part of a symbol name to search the workspace for\"},\"line\":{\"type\":\"integer\",\"description\":\"1-based; use with character when there is no symbol\"},\"character\":{\"type\":\"integer\",\"description\":\"1-based column; only meaningful with line\"}},\"required\":[\"operation\",\"file\"]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "lsp: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
