//! The `/init` prompt: analyses the codebase and writes AGENTS.md.
//!
//! This is a prompt-expanding command like the reference implementation:
//! the command injects a fixed instruction and the MODEL does the work
//! with our existing `read`/`write`/`task`/`bash`/`glob`/`grep` tools.
//!
//! The prompt text is kept here (pure) so it can be tested without a TUI
//! and the wiring is one branch in `submit` plus the `task` subagent call
//! it asks for.

const std = @import("std");

/// The initialization prompt.
///
/// Eight phases:
/// 1. Ask what to set up (the model asks via `ask`)
/// 2. Survey the codebase with a `task` subagent
/// 3. Interview the user about what could not be read from the code
/// 4. Write AGENTS.md (and CLAUDE.local.md for personal preferences)
/// 5. Suggest and create skills
/// 6. Suggest hooks
/// 7. Suggest output styles
/// 8. Recap
pub const initPrompt = "---BEGIN INIT PROMPT---\n" ++
    "# Initializing a new zode project\n" ++
    "\n" ++
    "You are the agent that helps set up this project for zode. Your job is to\n" ++
    "understand the codebase, write an AGENTS.md that captures how to work on it,\n" ++
    "and suggest skills/hooks that will help future sessions.\n" ++
    "\n" ++
    "## Phase 1 \u{2014} Ask what to set up\n" ++
    "\n" ++
    "Start by asking the user one question (use `ask`):\n" ++
    "\n" ++
    "> \"What would you like me to set up? For example: AGENTS.md, skills, hooks, output styles, or all of the above?\"\n" ++
    "\n" ++
    "Wait for their answer before proceeding.\n" ++
    "\n" ++
    "## Phase 2 \u{2014} Survey the codebase\n" ++
    "\n" ++
    "Run a `task` subagent to explore the repository. Give it this prompt:\n" ++
    "\n" ++
    "> \"Survey this codebase and report:\n" ++
    "> - Language(s) and build system\n" ++
    "> - Project structure (main entry points, key directories)\n" ++
    "> - Test commands and how to run them\n" ++
    "> - Lint/typecheck commands\n" ++
    "> - Any existing AGENTS.md, CLAUDE.md, or instruction files\n" ++
    "> - Any .github/, .vscode/, .claude/ directories\n" ++
    "> - What the project does (one paragraph)\"\n" ++
    "\n" ++
    "The subagent should use `glob`, `grep`, `read`, and `bash` to gather this.\n" ++
    "When it returns, continue.\n" ++
    "\n" ++
    "## Phase 3 \u{2014} Interview the user\n" ++
    "\n" ++
    "Ask the user (via `ask`) about anything the survey could not find:\n" ++
    "\n" ++
    "> \"I found the following from the codebase survey:\n" ++
    "> [summarize key findings]\n" ++
    "> \n" ++
    "> What else should I know? For example:\n" ++
    "> - Team conventions not in the code (commit style, review process)\n" ++
    "> - Deployment / CI details\n" ++
    "> - Any 'gotchas' a new contributor should know\n" ++
    "> - Preferred model/effort for this project\n" ++
    "> - Files or directories that should never be touched\"\n" ++
    "\n" ++
    "## Phase 4 \u{2014} Write AGENTS.md\n" ++
    "\n" ++
    "Write `AGENTS.md` at the project root (use `write`). It should contain:\n" ++
    "\n" ++
    "1. **Project overview** (what this is, 2-3 sentences)\n" ++
    "2. **Commands** (build, test, lint, typecheck, run)\n" ++
    "3. **Code conventions** (from the survey and the user's answers)\n" ++
    "4. **Workflow** (how to contribute: branch, commit, PR, review)\n" ++
    "5. **Gotchas** (what breaks, what's slow, what to avoid)\n" ++
    "6. **Architecture notes** (key modules, data flow \u{2014} brief)\n" ++
    "\n" ++
    "Also write `CLAUDE.local.md` for the user's personal preferences (model, effort,\n" ++
    "output style) \u{2014} this file is gitignored by zode's defaults.\n" ++
    "\n" ++
    "## Phase 5 \u{2014} Suggest skills\n" ++
    "\n" ++
    "If the project has repeated tasks (e.g. \"add a new API endpoint\", \"write a test\n" ++
    "for X\"), suggest creating a skill for each. Use the `skillify` skill to create\n" ++
    "them:\n" ++
    "\n" ++
    "> \"I noticed [pattern]. Should I create a skill for it?\"\n" ++
    "\n" ++
    "If yes, call `skillify` with the skill name.\n" ++
    "\n" ++
    "## Phase 6 \u{2014} Suggest hooks\n" ++
    "\n" ++
    "If there are natural hook points (pre-commit, pre-push, on test failure), suggest\n" ++
    "creating hooks in `.zode/hooks.json`. Example:\n" ++
    "\n" ++
    "```json\n" ++
    "{\n" ++
    "  \"hooks\": [\n" ++
    "    { \"event\": \"PreToolUse\", \"matcher\": \"Bash\", \"command\": \"echo 'Running: $TOOL_ARGS'\" }\n" ++
    "  ]\n" ++
    "}\n" ++
    "```\n" ++
    "\n" ++
    "## Phase 7 \u{2014} Suggest output styles\n" ++
    "\n" ++
    "If the user wants a specific interaction style, suggest creating an output style\n" ++
    "in `.zode/output-styles/` (or `~/.config/zode/output-styles/`).\n" ++
    "\n" ++
    "## Phase 8 \u{2014} Recap\n" ++
    "\n" ++
    "Summarize what was created:\n" ++
    "\n" ++
    "- AGENTS.md (and CLAUDE.local.md if applicable)\n" ++
    "- Any skills created\n" ++
    "- Any hooks created\n" ++
    "- Any output styles created\n" ++
    "\n" ++
    "Tell the user they can now start working with zode, and the harness will use\n" ++
    "their AGENTS.md automatically.\n" ++
    "---END INIT PROMPT---\n";

/// Returns the prompt as an owned slice in the given allocator.
pub fn prompt(gpa: std.mem.Allocator) ![]u8 {
    return gpa.dupe(u8, initPrompt);
}

test "init prompt is non-empty and contains key phases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try prompt(arena.allocator());
    defer arena.allocator().free(p);

    try std.testing.expect(p.len > 100);
    try std.testing.expect(std.mem.indexOf(u8, p, "Phase 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "Phase 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "Phase 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "Phase 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "Phase 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "Phase 6") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "Phase 7") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "Phase 8") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "AGENTS.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "CLAUDE.local.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "skillify") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "task") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "ask") != null);
}