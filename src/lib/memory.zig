//! Project memory: core parsing/types (facade).
//! Implementation lives in `memory/core.zig`; this path is kept stable for importers.

const core = @import("memory/core.zig");

pub const max_title = core.max_title;
pub const max_body_bytes = core.max_body_bytes;
pub const max_scan_entries = core.max_scan_entries;
pub const Entry = core.Entry;
pub const Meta = core.Meta;
pub const parse = core.parse;
pub const parseMemory = core.parseMemory;
pub const matches = core.matches;
pub const ConsultResult = core.ConsultResult;
pub const consult = core.consult;
pub const scoreMatch = core.scoreMatch;
pub const stalenessNote = core.stalenessNote;
pub const renderEntry = core.renderEntry;
pub const renderList = core.renderList;

test {
    _ = core;
}
