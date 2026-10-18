//! The `read` tool's schema text: the prose and the parameters the model reads
//! when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "read";

pub const description: []const u8 =
    "Read a file from disk, with line numbers, or SEVERAL at once with paths (max 8). A PNG/JPG/GIF/WEBP arrives as an IMAGE you can look at, never as bytes: do not use bash xxd/hexdump/base64/strings on a picture. PDF pages can be extracted as text with pdf_page_start/pdf_page_end (requires pdftotext from poppler-utils). ONE line per file in the header so you know what arrived and what did not. USE IT WHEN: you need to see code before editing it, or you are comparing files. USE INSTEAD OF: bash cat / bash head — those print raw bytes, parse worse, and cost the same round trip. EFFICIENCY: paths is ONE round trip for up to 8 files; reading them one by one is N requests. Files already in your context come back as a short unchanged note — quote from there instead of re-reading. LIMITS: 2000 lines per file by default; pass offset/limit for a range; huge lines are clipped at 2000 chars. ON ERROR: does not exist -> check with glob or list_files; is a directory -> use list_files on it. Pass force:true only when you genuinely need the text again (e.g. it was elided from context).";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"paths\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"read up to 8 files in ONE call; each is cached separately\"},\"offset\":{\"type\":\"integer\",\"description\":\"1-indexed start line\"},\"limit\":{\"type\":\"integer\"},\"force\":{\"type\":\"boolean\",\"description\":\"send the text again even if it is unchanged\"},\"pdf_page_start\":{\"type\":\"integer\",\"description\":\"1-indexed first PDF page to extract (requires pdftotext from poppler-utils)\"},\"pdf_page_end\":{\"type\":\"integer\",\"description\":\"1-indexed last PDF page to extract (defaults to pdf_page_start)\"}},\"required\":[]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "read: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
