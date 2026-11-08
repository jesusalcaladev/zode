//! Output styles: core types and parsing (facade).
//! Implementation lives in `outputstyle/core.zig`; this path is kept stable for importers.

const core = @import("outputstyle/core.zig");

pub const filename = core.filename;
pub const extension = core.extension;
pub const project_dir = core.project_dir;
pub const user_subdir = core.user_subdir;
pub const max_body = core.max_body;
pub const max_listed = core.max_listed;
pub const Meta = core.Meta;
pub const splitFrontmatter = core.splitFrontmatter;
pub const validName = core.validName;
pub const nameFor = core.nameFor;
pub const stemOf = core.stemOf;
pub const Source = core.Source;
pub const Entry = core.Entry;
pub const formatStyle = core.formatStyle;
pub const systemPromptSection = core.systemPromptSection;

test {
    _ = core;
}
