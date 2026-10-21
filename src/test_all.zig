// Test aggregator: it compiles with the vaxis import available.
pub const chat = @import("chat.zig");
pub const bgproc = @import("bgproc.zig");
pub const sleep = @import("lib/sleep.zig");
pub const bench = @import("lib/bench.zig");
pub const session = @import("session.zig");
pub const tools = @import("tools/dispatch.zig");
pub const markdown = @import("lib/markdown.zig");
pub const highlight = @import("lib/highlight.zig");
pub const models = @import("lib/models.zig");
pub const compaction = @import("compaction.zig");
pub const tui = @import("tui.zig");
pub const theme = @import("lib/theme.zig");
pub const config = @import("config.zig");
pub const editor = @import("lib/editor.zig");
pub const providers = @import("lib/providers.zig");
pub const agent = @import("agent.zig");
pub const palette = @import("palette.zig");
pub const web = @import("lib/web.zig");
pub const roster = @import("roster.zig");
pub const free_auto = @import("free_auto.zig");
pub const router = @import("lib/router.zig");
pub const symbols = @import("lib/symbols.zig");
pub const plan = @import("lib/plan.zig");
pub const taskstore = @import("lib/taskstore.zig");
pub const registry = @import("tools/registry.zig");
pub const checkpoint = @import("lib/checkpoint.zig");
pub const mentions = @import("lib/mentions.zig");
pub const clean = @import("lib/clean.zig");
pub const ask = @import("lib/ask.zig");
pub const subagent = @import("lib/subagent.zig");
pub const textcap = @import("lib/textcap.zig");
pub const resultcap = @import("lib/resultcap.zig");
pub const skills = @import("lib/skills.zig");
pub const usercmds = @import("lib/usercmds.zig");
pub const project = @import("lib/project.zig");
pub const readcache = @import("lib/readcache.zig");
pub const verify = @import("lib/verify.zig");
pub const prompt = @import("lib/prompt.zig");
pub const commands = @import("commands.zig");
pub const selfupdate = @import("lib/selfupdate.zig");
pub const clipboard = @import("clipboard.zig");
pub const copytext = @import("lib/copytext.zig");
pub const permrules = @import("lib/permrules.zig");
pub const cmdsafety = @import("lib/cmdsafety.zig");
pub const sandbox = @import("lib/sandbox.zig");
pub const pathsafe = @import("lib/pathsafe.zig");

// The language server. It was in its own aggregator (`src/lsp_test.zig`) that
// no build step referenced: 33 test blocks written, and 32 of them not even
// compiled. They are here now, where `zig build test` reaches them.
pub const lsp_protocol = @import("lsp/protocol.zig");
pub const lsp_servers = @import("lsp/servers.zig");
pub const lsp_format = @import("lsp/format.zig");
pub const lsp_client = @import("lsp/client.zig");
pub const lsp_process = @import("lsp/process.zig");
pub const lsp_manager = @import("lsp/manager.zig");
pub const lsp_tool = @import("tools/lsp.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
