//! Skills: core types and parsing (facade).
//! Implementation lives in `skills/core.zig`; this path is kept stable for importers.

const core = @import("skills/core.zig");

pub const filename = core.filename;
pub const project_dir = core.project_dir;
pub const agents_dir = core.agents_dir;
pub const user_subdir = core.user_subdir;
pub const max_body = core.max_body;
pub const max_inline = core.max_inline;
pub const budget_percent = core.budget_percent;
pub const max_desc_chars = core.max_desc_chars;
pub const chars_per_token = core.chars_per_token;
pub const max_budget_chars = core.max_budget_chars;
pub const max_listed_entries = core.max_listed_entries;
pub const budgetCharsFor = core.budgetCharsFor;
pub const Context = core.Context;
pub const Meta = core.Meta;
pub const splitFrontmatter = core.splitFrontmatter;
pub const validName = core.validName;
pub const nameFor = core.nameFor;
pub const Source = core.Source;
pub const Entry = core.Entry;
pub const formatSkill = core.formatSkill;
pub const skillAppliesHere = core.skillAppliesHere;
pub const systemPromptSection = core.systemPromptSection;

test {
    _ = core;
}
