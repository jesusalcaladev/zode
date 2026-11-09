// Test aggregator: it compiles with the vaxis import available.
pub const chat = @import("chat.zig");
pub const bgproc = @import("bgproc.zig");
pub const sleep = @import("lib/sleep.zig");
pub const ansi = @import("lib/ansi.zig");
pub const acp_protocol = @import("acp/protocol.zig");
pub const pipeline = @import("lib/pipeline.zig");
pub const testguard = @import("lib/testguard.zig");
pub const testplan = @import("lib/testplan.zig");
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
pub const textadmit = @import("lib/textadmit.zig");
pub const textcap = @import("lib/textcap.zig");
pub const resultcap = @import("lib/resultcap.zig");
pub const toolstore = @import("lib/toolstore.zig");
pub const skills = @import("lib/skills.zig");
pub const outputstyles = @import("lib/outputstyles.zig");
pub const outputstyle_store = @import("lib/outputstyle_store.zig");
pub const bundled_outputstyles = @import("lib/bundled_outputstyles.zig");
pub const usercmds = @import("lib/usercmds.zig");
pub const project = @import("lib/project.zig");
pub const readcache = @import("lib/readcache.zig");
pub const verify = @import("lib/verify.zig");
pub const prompt = @import("lib/prompt.zig");
pub const init_mod = @import("lib/init.zig");
pub const commands = @import("commands.zig");
pub const selfupdate = @import("lib/selfupdate.zig");
pub const clipboard = @import("clipboard.zig");
pub const copytext = @import("lib/copytext.zig");
pub const permrules = @import("lib/permrules.zig");
pub const cmdsafety = @import("lib/cmdsafety.zig");
pub const sandbox = @import("lib/sandbox.zig");
pub const pathsafe = @import("lib/pathsafe.zig");
pub const filesview = @import("lib/filesview.zig");
pub const cost = @import("lib/cost.zig");
pub const session_search = @import("lib/session_search.zig");
pub const cachebreak = @import("lib/cachebreak.zig");
pub const facts = @import("lib/facts.zig");
pub const filewatch = @import("lib/filewatch.zig");
pub const agentdefs = @import("lib/agentdefs.zig");
pub const taskloop = @import("lib/taskloop.zig");
pub const redact = @import("lib/redact.zig");
pub const spawnenv = @import("lib/spawnenv.zig");
pub const keychain = @import("lib/keychain.zig");
pub const agentsdoc = @import("lib/agentsdoc.zig");
pub const memory = @import("lib/memory.zig");
pub const memory_store = @import("lib/memory_store.zig");

// Additional lib modules (pure/testable utilities, storage, UI helpers).
pub const env = @import("lib/env.zig");
pub const regex = @import("lib/regex.zig");
pub const repeat = @import("lib/repeat.zig");
pub const repeat_guard = @import("lib/repeat_guard.zig");
pub const zjsonl = @import("lib/zjsonl.zig");
pub const termseq = @import("lib/termseq.zig");
pub const http_client = @import("lib/http_client.zig");
pub const webcache = @import("lib/webcache.zig");
pub const modelcache = @import("lib/modelcache.zig");
pub const provider = @import("lib/provider.zig");
pub const typecheck = @import("lib/typecheck.zig");
pub const edit_hint = @import("lib/edit_hint.zig");
pub const diff_tokenizer = @import("lib/diff_tokenizer.zig");
pub const diffview = @import("lib/diffview.zig");
pub const review = @import("lib/review.zig");
pub const goal = @import("lib/goal.zig");
pub const exitgate = @import("lib/exitgate.zig");
pub const fuzzy = @import("lib/fuzzy.zig");
pub const filesearch = @import("lib/filesearch.zig");
pub const sessionindex = @import("lib/sessionindex.zig");
pub const sessionpath = @import("lib/sessionpath.zig");
pub const skillstore = @import("lib/skillstore.zig");
pub const bundled_skills = @import("lib/bundled_skills.zig");
pub const mascot = @import("lib/mascot.zig");
pub const images = @import("lib/images.zig");
pub const batch = @import("lib/batch.zig");
pub const lang_icons = @import("lib/lang_icons.zig");
pub const hooks = @import("lib/hooks.zig");

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

// The MCP client. The same lesson as the language server above: the modules
// have to be in this aggregator or their tests never compile.
pub const mcp_protocol = @import("mcp/protocol.zig");
pub const mcp_client = @import("mcp/client.zig");
pub const mcp_process = @import("mcp/process.zig");
pub const mcp_servers = @import("mcp/servers.zig");
pub const mcp_search = @import("mcp/search.zig");
pub const mcp_manager = @import("mcp/manager.zig");
pub const mcp_tool = @import("tools/mcp.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
