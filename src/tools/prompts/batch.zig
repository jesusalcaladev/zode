//! The `batch` tool's schema text: the prose and the parameters the model
//! reads when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the
//! invariants every entry has to satisfy, and says why the prose may not
//! contain a quote.
const validate = @import("validate.zig");

pub const name = "batch";

pub const description: []const u8 =
    "Run several operations in ONE round trip instead of one request per operation. Send a list of steps; they run in order on this machine and you get one result back: a one-line log per step, and the final value. THE OPS, and there is no other: read (path) - read_many (paths) - grep (pattern, glob) - glob (pattern) - list_files (dir) - refs (symbol) - git_status - git_diff - map (field, which is lines or bytes) - filter (field, match, mode, which is contains or equals) - select (fields) - count - write (path) - edit (path, old_string, new_string). The steps work on a collection: read, read_many, grep, glob, list_files, refs, git_status and git_diff ADD items to it, and map, filter, select and count work on the items that are there. A step that fails STOPS the batch and names itself, unless you set continue_on_error. PERMISSIONS: a batch of reads asks for nothing; a batch with a write or an edit step asks exactly what that call would have asked, and the dialog names the files. It is not a shell: you never supply a command, there are no pipes and no network. Use it when you would otherwise make several calls over the same files, for example count the lines in four files, find the TODOs in two of them and write a report. Use a plain call when it is ONE thing.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"steps\":{\"type\":\"array\",\"maxItems\":32,\"description\":\"the steps, in order.\",\"items\":{\"type\":\"object\",\"properties\":{\"op\":{\"type\":\"string\",\"enum\":[\"read\",\"read_many\",\"grep\",\"glob\",\"list_files\",\"refs\",\"git_status\",\"git_diff\",\"map\",\"filter\",\"select\",\"count\",\"write\",\"edit\"],\"description\":\"which operation this step is.\"},\"path\":{\"type\":\"string\",\"description\":\"the file to read, write or edit.\"},\"paths\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"the files to read, for read_many.\"},\"pattern\":{\"type\":\"string\",\"description\":\"what to search for, for grep and glob.\"},\"glob\":{\"type\":\"string\",\"description\":\"a file filter for grep.\"},\"subdir\":{\"type\":\"string\",\"description\":\"where a search starts.\"},\"dir\":{\"type\":\"string\",\"description\":\"the directory to list.\"},\"symbol\":{\"type\":\"string\",\"description\":\"the identifier to look for, for refs.\"},\"field\":{\"type\":\"string\",\"description\":\"for map it is lines or bytes; for filter and select it is a field the items carry, such as path or line.\"},\"fields\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"the fields to keep, for select.\"},\"match\":{\"type\":\"string\",\"description\":\"what filter keeps, for filter.\"},\"mode\":{\"type\":\"string\",\"enum\":[\"contains\",\"equals\"],\"description\":\"how filter compares, for filter.\"},\"old_string\":{\"type\":\"string\",\"description\":\"the text to replace, for edit.\"},\"new_string\":{\"type\":\"string\",\"description\":\"the text to put there, for edit.\"}},\"required\":[\"op\"]}},\"continue_on_error\":{\"type\":\"boolean\",\"description\":\"keep going after a step fails, instead of stopping at it.\"}},\"required\":[\"steps\"]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "batch: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
