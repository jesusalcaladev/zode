//! The `notebook_edit` tool's schema text: the prose and the parameters the model
//! reads when it is choosing a tool.
//!
//! One module per tool, so a rule can be written, changed and TESTED without
//! touching the tools array or any other tool. `validate.zig` holds the invariants
//! every entry has to satisfy, and says why the prose may not contain a quote.
const validate = @import("validate.zig");

pub const name = "notebook_edit";

pub const description: []const u8 =
    "Replace, insert or delete ONE cell of a Jupyter notebook (.ipynb) by its index. USE IT WHEN: the file ends in .ipynb — every time, without exception. USE INSTEAD OF: edit on a .ipynb, where the old text would be a JSON string with escaped newlines and a match that fails for a reason you cannot see, and USE INSTEAD OF: write, which would rebuild the file and destroy the outputs the user was looking at. HOW TO ADDRESS A CELL: read the notebook first — read on a .ipynb returns a numbered outline (index, type, size, first line), and cell_number is one of those 0-based indices. new_source is the cell TEXT as it reads in Jupyter, not its JSON encoding: send real newlines, and this tool does the encoding. edit_mode replace overwrites the cell (default), insert puts a NEW cell AT that index and shifts the rest down — which lands it BEFORE the cell that used to be there, so a new cell AFTER cell k goes at k plus one, and cell_number equal to the cell count appends at the end; delete removes the cell. cell_type sets code or markdown, and it fixes the fields the type requires (a code cell gets outputs and execution_count, a markdown cell loses them) so the file stays valid. PRESERVED: outputs, execution counts, cell ids, kernelspec and every other cell come back exactly as they were; only the addressed cell changes. LIMITS: one cell per call; an index that is out of range is refused and the file is NOT touched. ON ERROR: out of range -> read the outline again and use one of the indices it printed; the file is not a notebook -> use read/write on it as plain JSON only if you really mean to.";

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
