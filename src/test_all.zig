// Test aggregator: it compiles with the vaxis import available.
pub const chat = @import("chat.zig");
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

test {
    @import("std").testing.refAllDecls(@This());
}
