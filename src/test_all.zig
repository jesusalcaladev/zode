// Test aggregator: it compiles with the vaxis import available.
pub const chat = @import("chat.zig");
pub const bgproc = @import("bgproc.zig");
pub const bench = @import("bench.zig");
pub const session = @import("session.zig");
pub const tools = @import("tools.zig");
pub const markdown = @import("markdown.zig");
pub const highlight = @import("highlight.zig");
pub const models = @import("models.zig");
pub const compaction = @import("compaction.zig");
pub const tui = @import("tui.zig");
pub const acp = @import("acp.zig");
pub const theme = @import("theme.zig");
pub const config = @import("config.zig");
pub const editor = @import("editor.zig");
pub const providers = @import("providers.zig");
pub const agent = @import("agent.zig");
pub const palette = @import("palette.zig");
pub const web = @import("web.zig");
pub const roster = @import("roster.zig");
pub const free_auto = @import("free_auto.zig");
pub const plan = @import("plan.zig");
pub const checkpoint = @import("checkpoint.zig");
pub const mentions = @import("mentions.zig");
pub const clean = @import("clean.zig");
pub const ask = @import("ask.zig");
pub const subagent = @import("subagent.zig");
pub const skills = @import("skills.zig");
pub const project = @import("project.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
