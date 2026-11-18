//! The `notebook_edit` tool's schema text: the prose and the parameters the model
//! reads when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "notebook_edit";

pub const description: []const u8 =
    "Edit ONE Jupyter cell (.ipynb) by index. USE WHEN: the file ends in .ipynb - always. USE INSTEAD OF edit (its old text is JSON-escaped, so a match fails for a reason you cannot see) or write (destroys the outputs the user was looking at). Address: read the notebook first for a numbered outline (index, type, size, first line); cell_number is that 0-based index. new_source is the cell TEXT with real newlines - this tool does the encoding. edit_mode replace (default) overwrites; insert puts a NEW cell AT that index, BEFORE the old occupant - to add AFTER cell k use k+1, and index = cell count appends; delete removes it. cell_type code|markdown fixes the fields the type requires (code gets outputs and execution_count, markdown loses them), keeping the file valid. PRESERVED: outputs, execution counts, cell ids, kernelspec and every other cell; only the addressed cell changes. LIMITS: one cell per call; an out-of-range index is refused and the file is NOT touched. ON ERROR: out of range -> re-read the outline; not a notebook -> use read/write on it as plain JSON only if you really mean to.";

/// The `parameters` object, verbatim.
const parameters: []const u8 =
    "{\"type\":\"object\",\"properties\":{\"notebook_path\":{\"type\":\"string\",\"description\":\"path to the .ipynb file\"},\"cell_number\":{\"type\":\"integer\",\"description\":\"0-based index of the cell, as the read outline numbers them\"},\"new_source\":{\"type\":\"string\",\"description\":\"the cell text with real newlines (not JSON-escaped)\"},\"edit_mode\":{\"type\":\"string\",\"enum\":[\"replace\",\"insert\",\"delete\"],\"description\":\"replace (default) | insert at the index | delete\"},\"cell_type\":{\"type\":\"string\",\"enum\":[\"code\",\"markdown\"],\"description\":\"for insert, and to convert an existing cell\"}},\"required\":[\"notebook_path\",\"cell_number\"]}";

/// The whole entry, ready to be spliced into the tools array.
pub const json: []const u8 =
    "{\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++
    "\",\"description\":\"" ++ description ++
    "\",\"parameters\":" ++ parameters ++ "}}";

test "notebook_edit: the schema entry is valid and matches this tool" {
    try validate.entry(name, description, json);
}
