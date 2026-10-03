// Test aggregator: it compiles with the vaxis import available.
pub const chat = @import("chat.zig");
pub const bgproc = @import("bgproc.zig");
pub const bench = @import("lib/bench.zig");
pub const session = @import("session.zig");
pub const tools = @import("tools/dispatch.zig");
pub const markdown = @import("lib/markdown.zig");
pub const highlight = @import("lib/highlight.zig");
pub const models = @import("lib/models.zig");
pub const compaction = @import("compaction.zig");
pub const tui = @import("tui.zig");
pub const acp = @import("acp.zig");
pub const theme = @import("lib/theme.zig");
pub const config = @import("config.zig");
pub const editor = @import("lib/editor.zig");
pub const providers = @import("lib/providers.zig");
pub const agent = @import("agent.zig");
pub const palette = @import("palette.zig");
pub const web = @import("lib/web.zig");
pub const roster = @import("roster.zig");
pub const free_auto = @import("free_auto.zig");
pub const plan = @import("lib/plan.zig");
pub const checkpoint = @import("lib/checkpoint.zig");
pub const mentions = @import("lib/mentions.zig");
pub const clean = @import("lib/clean.zig");
pub const ask = @import("lib/ask.zig");
pub const subagent = @import("lib/subagent.zig");
pub const skills = @import("lib/skills.zig");
pub const project = @import("lib/project.zig");
pub const readcache = @import("lib/readcache.zig");
pub const verify = @import("lib/verify.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
