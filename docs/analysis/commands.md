# Claude Code's command surface vs. ours

An inventory of every user-facing slash command in the **reference
implementation** (Claude Code), compared with zode's own command surface.

> **Note on citations.** This report was written while the reference
> implementation's source was available locally, and it cited it by file and
> line. Those citations have been **removed on purpose**: the reference
> implementation's source is not part of this repository and is not
> distributable, so a path into it is a pointer to something a reader cannot
> open. What the citations carried — *what
> the reference implementation does, and how big it is* — has been kept and
> rewritten as prose, so every claim below can still be acted on. Where the
> reference names a component or a prompt constant, that name is kept: it
> identifies the artefact, and it is not a path.

**Scope of the reference side**: the reference implementation's command registry
— 207 command files plus the registry module itself. The registry that decides
which commands exist in the shipped build is the `COMMANDS` array; the
`INTERNAL_ONLY_COMMANDS` array holds the commands that only exist for
Anthropic's own builds. The 18 per-command entry files under the reference
implementation's commands directory are all **disabled stubs**
(`export default { isEnabled: () => false, isHidden: true, name: 'stub' }`)
and are not part of the user-facing surface.

**Scope of our side**: `src/commands.zig`, the dispatch in `src/agent.zig`,
`src/palette.zig`, `src/lib/usercmds.zig`, `src/lib/skills.zig`,
`src/lib/skillstore.zig`, `src/lib/outputstyles.zig`,
`src/lib/outputstyle_store.zig`, `src/output_styles/`, `src/lib/goal.zig`,
`src/lib/bench.zig`, `src/clipboard.zig`.

**Verdicts**

- **HAVE** — zode has an equivalent; our own file and line are in the table.
- **PARTIAL** — zode has something weaker or with a different meaning; the
  difference is spelled out in §3.
- **MISSING** — zode has nothing equivalent.

**Not in scope**: the tool surface (the reference implementation's `TodoWrite`,
`Task`, `Bash`, …) except where a command is a thin wrapper over a tool. Its
`/todos` **does not exist** — Claude Code's todo list is the `TodoWrite` tool,
and the visible list is drawn by the UI, not by a command (there is no
`name: 'todos'` entry anywhere in the reference command registry). zode's
`todo` tool (`src/tools/registry.zig:273`) is the same idea and is already more
visible than the reference's.

---

## 1. Our command surface today

The command table is `src/commands.zig:591-625` (`pub const commands`). The
dispatch that routes a typed `/x` to a handler is `src/agent.zig:2972`
(`pub fn submit`) — one `if/else` chain, ending at `src/agent.zig:3102` where
an unknown token falls through to the user's own command files.

| Command | Where implemented | What it does |
|---|---|---|
| `/help` | `src/commands.zig:43` (`cmdHelp`) | Prints the command table, then the advanced ones, then the user's own commands, then the bare shortcuts |
| `/models` | `src/agent.zig:2989` → `listModelsAsync` | Fetches the provider's model catalogue and prints the counts |
| `/model` | `src/agent.zig:2995` → `openModelPaletteAsync` (`src/agent.zig:8911`) | Two-column modal (providers \| models), fills in from the network |
| `/provider` | `src/agent.zig:2993` → `openProviderPicker` | Modal picker for the active provider |
| `/providers` | `src/commands.zig:535` (`cmdProviders`) | Text list of providers with their key state |
| `/use` | `src/commands.zig:552` (`cmdUse`) | `provider [model]` — switch provider and/or model by name |
| `/effort` | `src/agent.zig:2943` (`cmdEffort`) | Sets the reasoning effort, or opens the picker; degrades to what the model supports |
| `/color` | `src/agent.zig:8704` (`cmdColor`) | **Diff palette**: `default \| daltonized`. *Not* the reference implementation's prompt-bar colour |
| `/submodel` | `src/agent.zig:4673` (`cmdSubmodel`) | Which model the **subagents** run on (session > config.json > env > off) |
| `/task-parallel` | `src/agent.zig:1001` (`cmdTaskParallel`) | Simultaneous subagent limit, `1..8 \| auto` |
| `/reload-cmds` | `src/agent.zig:3051` | Re-reads `.zode/commands` + `~/.config/zode/commands` from disk |
| `/which-cmd` | `src/agent.zig:3059` | Says where a command name comes from (builtin, project file, user file) |
| `/free-auto` (alias `/free`) | `src/free_auto.zig:321` (`cmdFreeAuto`) | Rotates between the free models of every provider that has a key; keeps going when one runs out |
| `/goal` | `src/commands.zig:323` (`cmdGoal`) | Sets the objective the turn may not stop short of; `clear` drops it |
| `/undo` | `src/agent.zig:5599` (`cmdUndo`) | Restores the files the **last turn** changed (snapshot ring) |
| `/clean` | `src/agent.zig:3514` (`cmdClean`) | Purges zode leftovers (dry run; `/clean yes` applies) |
| `/yolo` | `src/agent.zig:2889` (`cmdYolo`) | Bypass: allow everything, ask nothing (questions are answered for you and said in the summary) |
| `/mode` | `src/agent.zig:2901` (`cmdMode`) | `build \| accept-edits \| plan \| bypass` |
| `/ask` | `src/agent.zig:842` (`cmdAskMode`) | `on \| off` — the plan/read-only mode (Shift+Tab also cycles modes) |
| `/allowlist` | `src/commands.zig:83` (`cmdAllowlist`) | Shows the always-allowed tools and the always-allowed bash prefixes |
| `/bg` | `src/agent.zig:1443` (`cmdBg`) | Background commands: `list \| kill <id> \| killall` |
| `/new` | `src/agent.zig:2454` (`newSession`) | Starts a fresh session (new id, new file, cache stats reset) |
| `/resume` | `src/agent.zig:3598` (`resumeLatest`) | Reopens the **most recent** session by mtime |
| `/context` | `src/commands.zig:387` (`cmdContext`) | Estimated tokens vs. limit, a 20-cell gauge, the breakdown and the elided count |
| `/usage` | `src/commands.zig:157` (`cmdUsage`) | Session input/output tokens, cache reads/writes, request totals |
| `/compact` | `src/commands.zig:256` (`cmdCompact`) | `off \| elide \| full \| default` — the compaction **mode** |
| `/bench` | `src/agent.zig:970` (`cmdBench`) → `src/lib/bench.zig:120` | Turns, iterations, first-token times (mean + p95), capped-turn percentage |
| `/session` | `src/commands.zig:521` (`cmdSession`) | Session id, message count, file path |
| `/cache` | `src/commands.zig:117` (`cmdCache`) | Prompt-cache hit rate for the session, with the *why* (router vs. provider) |
| `/skills` | `src/agent.zig:1027` (`cmdSkills`) | Lists the loadable skills (name, description, when-to-use, source) |
| `/style` | `src/agent.zig:1064` (`cmdStyle`) | Output style: `default \| explanatory \| learning`, `off` clears it |
| `/copy` | `src/agent.zig:1203` (`cmdCopy`) → `src/clipboard.zig:102` | Copies an answer (or the Nth-latest) to the clipboard **and** to a file |
| `/quit` | `src/agent.zig:2987` (the TUI handles it) | Exits |

**Keyboard-only surfaces that are not commands**: Ctrl+P command palette
(`src/agent.zig:9505`, groups at `src/agent.zig:9433`), Ctrl+T model palette,
Ctrl+A connect a provider (`src/agent.zig:9477`), Ctrl+L clear the view,
Ctrl+R expand the last tool result, Shift+Tab cycle modes, Shift+Enter newline.

**User-defined commands**: `.zode/commands/<name>.md` (project) and
`~/.config/zode/commands/<name>.md` (user) — `src/lib/usercmds.zig:39-40`,
scanned at `src/lib/usercmds.zig:233`, dispatched at `src/agent.zig:3107`.
Frontmatter `description`, `$ARGUMENTS` expansion (`src/lib/usercmds.zig:167`).

**Skills**: `.zode/skills/<name>/SKILL.md`, `.agents/skills/`,
`~/.config/zode/skills/<name>/SKILL.md` — `src/lib/skills.zig:53-61`, with
bundled ones embedded in the binary (`src/lib/bundled_skills.zig`).

**Output styles**: `.zode/output-styles/*.md` and
`~/.config/zode/output-styles/*.md` — `src/lib/outputstyles.zig:38-42`; three
shipped in `src/output_styles/` (`default.md`, `explanatory.md`,
`learning.md`).

---

## 2. Reference inventory

"Reference source" is **where the behaviour lives** in the reference
implementation: the command's own definition (the `name:` line of the command
object or the array element that registers it), the prompt text it expands to,
or the modal component it opens. "kind" is the reference implementation's `type`
field: `prompt` expands to a user-turn prompt, `local` runs a function and
returns text, `local-jsx` opens a React modal.

### 2.1 The shipped user-facing surface (`COMMANDS`)

| Command | Reference source | Kind | Reference behaviour | Ours | Our file:line |
|---|---|---|---|---|---|
| `/add-dir` | command definition | local-jsx | Adds a working directory to the workspace, persists it in `additionalDirectories` and applies a permission update | **MISSING** | — |
| `/advisor` | command definition | local | Configures the advisor model (`/advisor <model>\|off`); validates the model supports the advisor | **MISSING** (the *tool* is planned, not the command) | — |
| `/agents` | command definition + the `AgentsMenu` component | local-jsx | `AgentsMenu` — manage the subagent definitions (`~/.claude/agents`, `.claude/agents`) | **MISSING** | — |
| `/branch` (alias `/fork`) | command definition | local-jsx | Forks the conversation at this point into a new session file, with provenance | **MISSING** (planned) | — |
| `/btw` | command definition | local-jsx | Asks a quick side question **without** interrupting the main conversation (own scrollback, own request) | **MISSING** | — |
| `/chrome` | command definition | local-jsx | Claude-in-Chrome (beta) settings | **MISSING** (N/A: no browser tool) | — |
| `/clear` (aliases `/reset`, `/new`) | command definition + a teardown helper and a cache-reset helper | local | Wipes the conversation, regenerates the session id, frees the context, clears every cache | **PARTIAL** — `/new` does the job; no `/clear`, no `/reset` | `src/agent.zig:2454` |
| `/color` | command definition | local-jsx | Sets the **prompt-bar / agent colour** for this session (persisted in the transcript) | **PARTIAL** — the name is taken by our *diff* palette, a different feature | `src/agent.zig:8704` |
| `/compact` | command definition + a compaction helper | local | Compacts now: clears the history but keeps a summary; accepts custom summarization instructions | **PARTIAL** — ours sets the automatic compaction *mode*, it does not compact on demand | `src/commands.zig:256` |
| `/config` (alias `/settings`) | command definition + the `Settings` component | local-jsx | The Settings panel (`Settings` component, tab `Config`) — model, theme, editor mode, env, permissions, output style, statusline | **PARTIAL** — the settings exist but are scattered over `/providers`, `/use`, `/effort`, `/allowlist`, `/mode`, `/style` | — |
| `/context` | command definition (plus a non-interactive variant) | local-jsx | A **coloured grid** of the context, computed on the *API view* (post-collapse, post-microcompact) | **PARTIAL** — ours is a text gauge on the raw history | `src/commands.zig:387` |
| `/copy` | command definition | local-jsx | Copies the last response (or the Nth-latest, `MAX_LOOKBACK = 20`) to the clipboard, with a code-block picker | **HAVE** | `src/agent.zig:1203`, `src/clipboard.zig:102` |
| `/cost` | command definition | local | Total cost and **duration** of the session, in dollars (hidden for subscribers) | **PARTIAL** — ours has tokens, not money, and no duration | `src/commands.zig:157` (`/usage`) |
| `/desktop` (alias `/app`) | command definition | local-jsx | Continue the current session in Claude Desktop | **MISSING** (N/A) | — |
| `/diff` | command definition + the `DiffDialog` component | local-jsx | `DiffDialog` — uncommitted changes **and** the per-turn diffs | **PARTIAL** — we paint the diff inline after a write/edit and Ctrl+R expands it, but there is no `/diff` and no uncommitted view | `src/tui.zig:3770` (`toggleLastTool`), `src/lib/diffview.zig` |
| `/doctor` | command definition + the `Doctor` screen + a diagnostics helper | local-jsx | `Doctor` screen — version, install type, PATH, alias, settings errors, MCP warnings, keybinding warnings, sandbox dependencies, agent directories | **MISSING** | — |
| `/effort` | command definition | local-jsx | Sets the reasoning effort (`low\|medium\|high\|max\|auto`), persisted per settings source | **HAVE** | `src/agent.zig:2943` |
| `/exit` (alias `/quit`) | command definition | local-jsx | Exits the REPL (detaches in a `tmux` bg session) | **PARTIAL** — we have `/quit`, not `/exit` | `src/commands.zig:624` |
| `/fast` | command definition | local-jsx | Toggles "fast mode" (a faster model variant), may switch the model | **MISSING** | — |
| `/files` | command definition + an eight-line helper | local | Lists every file currently in the context (`readFileState`) | **MISSING** (the data exists in `src/lib/readcache.zig`) | — |
| `/help` | command definition + the `HelpV2` screen | local-jsx | `HelpV2` screen — the commands, the keybindings and the general help | **HAVE** (as text, not a modal) | `src/commands.zig:43` |
| `/hooks` | command definition + the `HooksConfigMenu` component | local-jsx | `HooksConfigMenu` — view/edit the hook configurations per tool event | **MISSING** (Phase 5) | — |
| `/ide` | command definition | local-jsx | Detects the IDEs, manages the integration, shows the status, `open` | **MISSING** (we have the `lsp` tool instead) | — |
| `/init` | prompt text (`NEW_INIT_PROMPT`, about 200 lines; the old variant about 20 lines) | prompt | Analyses the codebase and writes `CLAUDE.md` (new variant: also skills and hooks, 8 phases) | **MISSING** | — |
| `/install-github-app` | command definition | local-jsx | Sets up Claude GitHub Actions for a repository (OAuth, secret, workflow) | **MISSING** (N/A) | — |
| `/install-slack-app` | command definition | local | Installs the Claude Slack app | **MISSING** (N/A) | — |
| `/keybindings` | command definition | local | Creates the keybindings template and opens it in `$EDITOR` | **MISSING** | — |
| `/login` | command definition | local-jsx | OAuth sign-in (or switch account) with an Anthropic account | **PARTIAL** — we have API keys (`/provider`, Ctrl+A, `auth.json`), no OAuth | `src/agent.zig:9477` |
| `/logout` | command definition | local-jsx | Removes the credentials, wipes the secure storage and the auth caches | **MISSING** | — |
| `/mcp` | command definition + the `MCPSettings` panel | local-jsx | Manage the MCP servers: list, enable/disable, add; `enable\|disable [server]` | **MISSING** (Phase 12) | — |
| `/memory` | command definition + a memory-file helper | local-jsx | Picks a memory file (`CLAUDE.md`, `~/.claude/CLAUDE.md`) and opens it in `$EDITOR` | **MISSING** | — |
| `/mobile` (aliases `/ios`, `/android`) | command definition | local-jsx | Shows a QR code to download the Claude mobile app | **MISSING** (N/A) | — |
| `/model` | command definition + the `ModelPicker` component | local-jsx | `ModelPicker` — pick the model (and the effort, and fast mode) | **HAVE** | `src/agent.zig:8911` |
| `/output-style` (hidden) | command definition | local-jsx | **Deprecated in the reference implementation**: prints "use /config". Ours implements the feature properly as `/style` | **HAVE** (as `/style`) | `src/agent.zig:1064` |
| `/passes` | command definition | local-jsx | Referral programme: share a free week | **MISSING** (N/A) | — |
| `/permissions` (alias `/allowed-tools`) | command definition + the `PermissionRuleList` component | local-jsx | `PermissionRuleList` — manage allow/deny rules, and retry the denied commands | **PARTIAL** — ours shows a flat allowlist, no rules, no deny | `src/commands.zig:83` |
| `/plan` | command definition | local-jsx | Enables plan mode **or** shows the current plan; `/plan open` opens the plan file in `$EDITOR` | **PARTIAL** — the mode exists, the plan *file* and the "open" do not | `src/agent.zig:842` |
| `/plugin` (aliases `/plugins`, `/marketplace`) | command definition | local-jsx | Manage plugins and the marketplaces | **MISSING** (Phase 13) | — |
| `/pr-comments` | prompt text | prompt | Fetches and formats the comments of a GitHub PR (`gh api …`) | **MISSING** | — |
| `/privacy-settings` | command definition | local-jsx | Anthropic account privacy settings | **MISSING** (N/A) | — |
| `/rate-limit-options` (hidden) | command definition | local-jsx | The menu shown when the rate limit is reached (upgrade / extra usage / cancel) | **MISSING** (we retry and rotate instead) | — |
| `/release-notes` | command definition | local | Fetches the changelog (500 ms timeout) and falls back to the cached copy | **MISSING** | — |
| `/reload-plugins` | command definition | local | Applies pending plugin changes to the running session | **MISSING** (N/A) | — |
| `/remote-control` (alias `/rc`) | command definition | local-jsx | Pairs the terminal with a remote-control session | **MISSING** (N/A) | — |
| `/remote-env` | command definition | local-jsx | The default remote environment for teleport sessions | **MISSING** (N/A) | — |
| `/rename` | command definition + a rename helper | local-jsx | Renames the conversation (a custom title, stored in the transcript) | **MISSING** (planned in Phase 30.1) | — |
| `/resume` (alias `/continue`) | command definition + the `LogSelector` component | local-jsx | A picker over every session (`LogSelector`) plus search by id/title, with cross-project checks | **PARTIAL** — ours reopens the newest by mtime | `src/agent.zig:3598` |
| `/review` | prompt text (`LOCAL_REVIEW_PROMPT`, about 20 lines) | prompt | Reviews a **GitHub pull request**: `gh pr list` / `gh pr view` / `gh pr diff`, then a structured review | **PARTIAL** — our `review` **tool** reviews the working diff with a checklist; there is no PR review | `src/tools/registry.zig:379`, `src/lib/review.zig` |
| `/rewind` (alias `/checkpoint`) | command definition + a rewind helper | local | Opens the message selector to restore the **code and/or the conversation** to an earlier point | **PARTIAL** — `/undo` restores the files of the **last turn** only | `src/agent.zig:5599` |
| `/sandbox` | command definition + the `SandboxSettings` panel | local-jsx | Toggles/configures the OS sandbox (seatbelt/bubblewrap), with per-command exclusions | **MISSING** (Phase 6) | — |
| `/security-review` | prompt text (`SECURITY_REVIEW_MARKDOWN`, roughly 190 lines) | prompt | A full security-review protocol: inlined `git status` / `git diff origin/HEAD...` / `git log`, an objective, a confidence bar (>80%), explicit exclusions, and a 3-step sub-task protocol | **MISSING** | — |
| `/session` (alias `/remote`) | command definition | local-jsx | Shows the **remote** session URL and a QR code | **PARTIAL** — ours shows the session id, the message count and the path | `src/commands.zig:521` |
| `/skills` | command definition + the `SkillsMenu` component | local-jsx | `SkillsMenu` — list the skills, see their details | **HAVE** (as a text list) | `src/agent.zig:1027` |
| `/stats` | command definition + the `Stats` component | local-jsx | `Stats` — usage statistics and activity | **PARTIAL** — `/bench` has the turn/iteration/TTFT numbers, not the activity | `src/agent.zig:970` |
| `/status` | command definition + the `Status` tab of the `Settings` panel | local-jsx | The `Status` tab of the Settings panel: version, model, account, API connectivity, tool statuses | **PARTIAL** — spread over `/session`, `/providers`, `/bench` | — |
| `/statusline` | prompt text | prompt | Sets up a custom status line: spawns a `statusline-setup` subagent that reads the shell PS1 and writes the config | **MISSING** | — |
| `/stickers` | command definition | local | Orders Claude Code stickers | **MISSING** (N/A) | — |
| `/tag` | command definition | local-jsx | Toggles a searchable tag on the current session | **MISSING** | — |
| `/terminal-setup` | command definition | local-jsx | Installs the Shift+Enter (CSI-u) key binding into the terminal's config (iTerm2, VS Code, Ghostty, Kitty, WezTerm) | **PARTIAL** — Shift+Enter already works in our editor (`src/lib/editor.zig`), but there is no installer | — |
| `/theme` | command definition + the `ThemePicker` component | local-jsx | `ThemePicker` — changes the theme at runtime | **MISSING** — our theme is compile-time (`src/lib/theme.zig`) | — |
| `/think-back` | command definition | local-jsx | The 2025 Year in Review | **MISSING** (N/A) | — |
| `/thinkback-play` (hidden) | command definition | local | Plays the thinkback animation | **MISSING** (N/A) | — |
| `/upgrade` | command definition | local-jsx | Opens `claude.ai/upgrade/max` in the browser and re-logs in — upgrades the **subscription** | **PARTIAL** — we self-update the **binary** automatically, with no command | `src/lib/selfupdate.zig:243`, `src/main.zig:744` |
| `/usage` | command definition + the `Usage` tab of the `Settings` panel | local-jsx | The `Usage` tab of the Settings panel: the **plan's** usage limits (subscription quota) | **PARTIAL** — ours is the session's token totals | `src/commands.zig:157` |
| `/vim` | command definition | local | Toggles vim / normal editing modes, persisted in the global config | **MISSING** | — |
| `/voice` | command definition | local | Toggles voice mode | **MISSING** (N/A) | — |
| `/web-setup` | command definition | local-jsx | Sets up Claude Code on the web (needs a GitHub connection) | **MISSING** (N/A) | — |
| `/extra-usage` | command definition (plus a non-interactive variant) | local-jsx | Configures the overage ("extra usage") so a rate limit does not stop the work | **MISSING** (N/A) | — |
| `/insights` | a registry entry + a very large prompt template (about 3 200 lines) | prompt | A 3 200-line analysis of your own sessions → a report (a JSON schema of 9 sections) | **PARTIAL** — `/bench` has the raw counters, not the analysis | `src/lib/bench.zig:120` |
| `/ultrareview` | command definition | local-jsx | Remote ("Claude Code on the web") bug hunt over your branch | **MISSING** (N/A) | — |
| `/tasks` (alias `/bashes`) | command definition + the `BackgroundTasksDialog` component | local-jsx | `BackgroundTasksDialog` — list and manage the background tasks | **PARTIAL** — `/bg` lists and kills `bgproc` jobs only, not the subagents | `src/agent.zig:1443` |
| `/install` | a CLI flow (`claude install`), dispatched from the CLI's own handler — not a REPL slash command | local-jsx | Installs the native build — **a CLI flow** (`claude install`), not a REPL slash command | n/a | — |

### 2.2 Anthropic-internal commands (`INTERNAL_ONLY_COMMANDS`)

Present in the reference implementation's registry, gated to
`USER_TYPE === 'ant'`. Listed for completeness; none of them is part of the
public surface.

| Command | Reference source | Kind | Behaviour | Ours |
|---|---|---|---|---|
| `/commit` | prompt text | prompt | Inlines `git status` / `git diff HEAD` / `git branch --show-current` / `git log --oneline -10`, a 6-rule git safety protocol, and a heredoc commit | **PARTIAL** — the `git_commit` **tool** exists (`src/tools/registry.zig:219`), the *command* does not |
| `/commit-push-pr` | prompt text | prompt | Branch + commit + push + `gh pr create`/`edit`, with a PR body template, a changelog block and a reviewer | **MISSING** |
| `/init-verifiers` | prompt text | prompt | Creates verifier *skills* (Playwright / Tmux / HTTP) for the project's areas | **MISSING** |
| `/version` | command definition | local | Prints the version this session is running | **MISSING** (the version is known: `src/lib/selfupdate.zig:10`) |
| `/ultraplan` | command definition | local-jsx | Remote planner on claude.ai | **MISSING** (N/A) |
| `/bridge-kick` | command definition | local | Injects bridge failure states for testing | **MISSING** (N/A) |
| `/reset-limits` | a one-line disabled stub | stub | Disabled stub (`isEnabled: () => false`) | n/a |
| `/backfill-sessions`, `/break-cache`, `/bughunter`, `/ctx_viz`, `/good-claude`, `/issue`, `/mock-limits`, `/onboarding`, `/share`, `/summary`, `/teleport`, `/env`, `/oauth-refresh`, `/debug-tool-call`, `/ant-trace`, `/perf-issue`, `/autofix-pr` | one-line disabled stubs | stub | All are one-line disabled stubs (`export default { isEnabled: () => false, isHidden: true, name: 'stub' }`) | n/a |

### 2.3 Referenced by the command registry but **not present in the reference build**

These are behind `bun:bundle` feature flags and their implementation is not
shipped in the reference build. They are named here so the inventory is
complete: `/proactive`, `/brief`, `/assistant`, `/fork` (the `/branch` alias is
dropped when it exists), `/buddy`, `/peers`, `/workflows`, `/torch`,
`/subscribe-pr`, `/force-snip`, `/remote-control-server`, `/agents-platform`.

### 2.4 The dynamic part of the surface (not a fixed registry entry)

- **User markdown commands**: `.claude/commands/*.md` — loaded as
  `loadedFrom: 'commands_DEPRECATED'`.
- **Skills**: `.claude/skills/<name>/SKILL.md`, bundled skills, plugin skills —
  the registry carries a second array for the skills, and the skills loader
  reads those directories.
- **Plugin and MCP-provided commands**: contributed by the plugin loader.

**Ours**: `.zode/commands/*.md` (`src/lib/usercmds.zig:39`) and
`.zode/skills/<name>/SKILL.md` (`src/lib/skills.zig:56`) cover the first two.
Plugin/MCP commands have no analogue (no plugins; MCP is Phase 12).

---

## 3. The gap list

Only **MISSING** and **PARTIAL** entries appear here. The reference-only
Anthropic surface (N/A: OAuth accounts, subscriptions, browser, mobile,
marketplace, remote sessions) is grouped at the end and is **not** a gap to
work on.

### 3.1 `/init` — the biggest single gap

**Reference implementation**: a `prompt` command whose text is
`NEW_INIT_PROMPT` — a prompt of roughly 200 lines, with eight phases: ask what
to set up (`AskUserQuestion`), survey the codebase with a **subagent**,
interview the user about what could not be read from the code, write
`CLAUDE.md` / `CLAUDE.local.md`, suggest and create **skills**, suggest
**hooks**, and recap. The old variant is `OLD_INIT_PROMPT`, a much shorter
prompt of about 20 lines.

**Ours**: nothing. We *read* `AGENTS.md` (`src/lib/prompt.zig`, injected as the
system prompt) but there is no command that writes one.

**A Zig port** would live in `src/lib/init.zig` (pure: the prompt text + the
file-plan) with the command wired in `src/agent.zig:2972` next to the other
prompts. Two shapes are possible: (a) a **prompt-expanding command** like the
reference implementation — the command injects a fixed instruction and the
*model* does the work with our existing `read`/`write`/`task` tools; (b) a
harness-side generator. (a) is what the reference implementation does and it is
the right one: the model is better at writing prose about a codebase than a Zig
program is.

**Effort**: **M** (the prompt is ~50 lines of prose; the wiring is one branch in
`submit` plus the `task` subagent call it asks for). **L** if the
`AskUserQuestion` phase is ported as well (our `ask` tool is the equivalent:
`src/tools/registry.zig:327`).

**Risk**: low. It writes one file the user can review. The risk is *scope*:
the reference implementation's eight-phase prompt asks for skills and hooks
too, and ours have neither of the pieces yet (Phase 5, Phase 9).

**Dependencies**: `src/lib/prompt.zig` (the `AGENTS.md` contract),
`src/lib/skills.zig` (if the prompt also creates skills),
`src/tools/registry.zig` (the `task` tool for the survey subagent).

### 3.2 `/doctor` — the diagnostic the user runs when something is broken

**Reference implementation**: the `/doctor` command opens a `Doctor` screen,
fed by a diagnostics helper of roughly 75 lines. It reports the installation
type, the version, the invoked binary, multiple installations, the
`~/.local/bin` PATH problem, the install-method mismatch (a check inside that
helper), the settings validation errors, the MCP parsing warnings, the
keybinding warnings, the sandbox dependencies and the agent directories.

**Ours**: nothing equivalent. We have `src/lib/clean.zig` (deletes leftovers)
and the boot probe (`ZODE_DBG_BOOT=1`, `src/agent.zig`), but no user-facing
diagnostic.

**A Zig port**: `src/lib/doctor.zig` (pure: a list of checks, each returning
`{ issue, fix }`) plus a `cmdDoctor(m)` in `src/commands.zig`. The checks that
pay off for us: the provider's key state and reachability (`/providers` already
computes the key state), the config's validity, the session directory's
permissions (we fixed that in the security pass), the model catalogue's
reachability, the LSP server table, and the `auth.json` permissions.

**Effort**: **M**. **Risk**: low (read-only). **Dependencies**: `src/lib/providers.zig`,
`src/config.zig`, `src/lib/selfupdate.zig`.

### 3.3 `/permissions` — the rule editor (we have an allowlist, not rules)

**Reference implementation**: the `/permissions` command (alias
`/allowed-tools`) opens a `PermissionRuleList` component. It manages **allow
and deny** rules per tool with patterns, and can retry the commands that were
denied.

**Ours**: `/allowlist` (`src/commands.zig:83`) prints a flat list of
always-allowed tool names and always-allowed bash prefixes. There is no deny
side, no patterns, and no editing — only the "always allow" checkbox in the
permission dialog.

**A Zig port**: Phase 6 is exactly this (`TASKS.md:140-149`: rule model with
sources and precedence, `Tool(pattern)` syntax, actions `deny`/`allow`/`ask`).
Once the rule model exists, the *command* is a picker over the rules — the
picker machinery already exists (`src/palette.zig`, `src/tui.zig`'s
`openPicker`). The extra work over Phase 6 is only the UI and the persistence.

**Effort**: **M** for the command alone, **L** for the whole thing (Phase 6
first). **Risk**: medium — the rule language is a security surface, and a
rule engine that matches the wrong thing asks for the wrong thing.

**Dependencies**: Phase 6 (`src/lib/`), the permission dialog, `auth.json` /
`permissions.json` persistence.

### 3.4 `/review` — a PR review, not a diff review

**Reference implementation**: a `prompt` command. The prompt text is
`LOCAL_REVIEW_PROMPT` — about 20 lines: run `gh pr list` (or `gh pr view <n>`),
run `gh pr diff <n>`, and produce a review with *Overview / code quality /
suggestions / issues and risks*, focused on correctness, conventions,
performance, test coverage and security.

**Ours**: the `review` **tool** (`src/tools/registry.zig:379`,
`src/lib/review.zig`) reviews the **working diff** with an eight-entry
checklist and gates the end of the turn. There is no PR.

**A Zig port**: a prompt-expanding command whose text is the reference
implementation's, verbatim (Phase 31.1 (`TASKS.md:627`) already specifies the
``!`cmd` `` substitution mechanism and the
"loud, named failure" rule). The command needs the `gh` binary and a
`gh pr list` to pick a PR when no number is given.

**Effort**: **S** (it is a prompt plus one branch in `submit`) **M** if it
also does the `gh pr list` picker. **Risk**: low-medium — it runs `gh`, which
needs the permission dialog, and `gh` may not be installed.

**Dependencies**: Phase 31 (the ``!`cmd` `` substitution), the permission system.

### 3.5 `/security-review` — a protocol we can port verbatim

**Reference implementation**: a `prompt` command. The prompt is
`SECURITY_REVIEW_MARKDOWN` — about 190 lines: a frontmatter with
`allowed-tools`, four inlined git commands (`git status`,
`git diff --name-only origin/HEAD...`, `git log --no-decorate origin/HEAD...`,
`git diff origin/HEAD...`), an OBJECTIVE (only high-confidence, newly added
issues), four CRITICAL INSTRUCTIONS (minimize false positives >80%,
avoid noise, focus on impact, and an explicit exclusion list), a set of
security categories, and a 3-step protocol (one sub-task finds, parallel
sub-tasks filter, drop anything under confidence 8).

**Ours**: nothing. Our `review` tool is a general diff checklist
(`src/lib/review.zig`), and it explicitly is *not* a judgement — the file's own
doc comment says so.

**A Zig port**: `src/lib/securityreview.zig` with the prompt text as a
constant, plus the ``!`cmd` `` substitution (Phase 31.1). The 3-step protocol maps
onto our `task` tool: one finder subagent, parallel filter subagents. Our
`task` cap is 3 and its depth is 1, which is enough for "one finder + two
filters".

**Effort**: **S-M**. **Risk**: low — it is read-only by construction
(`git diff` / `git log`).

**Dependencies**: Phase 31.1 (the ``!`cmd` `` substitution), `src/tools/registry.zig:370`
(the `task` tool).

### 3.6 `/files` — the cheapest missing command

**Reference implementation**: the `/files` command lists the keys of the
context's read-file state (`readFileState`) joined with newlines. Eight lines
of implementation.

**Ours**: nothing, but the data is already tracked —
`src/lib/readcache.zig` is the read-file cache the `read` tool fills.

**A Zig port**: `cmdFiles(m)` in `src/commands.zig` reading `readcache` and
printing the paths relative to the cwd. **Effort**: **S**. **Risk**: none.

**Dependencies**: `src/lib/readcache.zig`.

### 3.7 `/rename` — naming the conversation

**Reference implementation**: the `/rename` command generates a name (or takes
the argument), stores it as the session's `customTitle`, and refuses for
teammates.

**Ours**: nothing. The session file has no title concept; `/resume` shows the
newest session, so a title has nowhere to live yet.

**A Zig port**: `src/agent.zig` gains a `renameSession(m, name)` that writes a
`customTitle` entry into the JSONL, and `cmdRename(m, arg)` in
`src/commands.zig`. It is **the first half of Phase 30.1** and it is what
makes the Phase 29 resume rows readable.

**Effort**: **S**. **Risk**: low. **Dependencies**: Phase 30.1 (the two title
keys on disk), `src/session.zig` (the JSONL writer).

### 3.8 `/resume` — a picker, not a guess

**Reference implementation**: the `/resume` command opens a `LogSelector` over
every session of every project, plus a search by id or title, plus
`checkCrossProjectResume` (a session from another directory is refused with the
exact command to run).

**Ours**: `/resume` (`src/agent.zig:3598`) reopens the **newest session by
mtime**. With two projects open, or after a crash, that is a guess.

**A Zig port**: this is Phase 29 (`TASKS.md:576-600`), item by item. The
`/resume <term>` variant is the cheapest slice: resolve a UUID or a title
against the session directory and open it.

**Effort**: **L** (Phase 29 as written). **Risk**: medium — the session
loader is the fragile part (zjsonl, truncated lines, 1 MB `@file` mentions).

**Dependencies**: Phase 29; `src/session.zig`, `src/lib/zjsonl.zig`.

### 3.9 `/rewind` — an arbitrary point, not the last turn

**Reference implementation**: the `/rewind` command opens the message selector
(`context.openMessageSelector()`) — a selector over the conversation, and the
user picks a point to restore the code and/or the conversation to.

**Ours**: `/undo` (`src/agent.zig:5599`) restores the files of the **last
turn** from the checkpoint ring (`src/lib/checkpoint.zig`: 8 turns, 24 files,
256 KB per file, 1 MB per turn). The conversation is not rewound at all.

**A Zig port**: two independent halves.
(a) *Files*: pick a turn from the ring instead of only the last — the ring
already stores 8 turns, so this is a picker over an existing structure. **S**.
(b) *Conversation*: rewind the message list to a chosen point. That is a real
rewrite of the JSONL and of the in-memory list; the session format is
append-only by design (`src/session.zig`). **L**.

**Effort**: **S** for (a), **L** for (b). **Risk**: medium for (b) — a
rewritten session that later resumes wrong is worse than no rewind.

**Dependencies**: `src/lib/checkpoint.zig` (a), `src/session.zig` (b).

### 3.10 `/compact` — compact *now*, with instructions

**Reference implementation**: the `/compact` command compacts **on demand**:
takes the messages after the last compact boundary, optionally asks the
session-memory compactor, otherwise asks the model to summarize with the
user's own instructions, replaces the history with the summary, runs the
post-compact cleanup and resets the cache-read baseline.

**Ours**: `/compact` (`src/commands.zig:256`) sets the **automatic** compaction
mode (`off | elide | full | default`). There is no "compact this conversation
right now" and no way to pass summarization instructions.

**A Zig port**: the compaction machinery already exists
(`src/compaction.zig`: tier 1 `elideTier`, tier 2 `summarizeTurns`). The
missing piece is a *trigger* with an argument: "summarize the history now,
with these instructions". That is one new branch in `submit` plus a call into
the tier-2 summarizer with a custom instruction.

**Effort**: **S-M**. **Risk**: medium — the summary replaces the history, and
a bad summary is invisible until the next turn.

**Dependencies**: `src/compaction.zig`, `src/session.zig`.

### 3.11 `/agents` — manage the subagent definitions

**Reference implementation**: the `/agents` command opens an `AgentsMenu`: list
the agent definitions from `~/.claude/agents` and `.claude/agents`, see their
tools and model, create and delete them.

**Ours**: no agent definitions on disk at all. `src/lib/skills.zig:60` reads
`.agents/skills`, but there is no `.zode/agents/*.md`. The `task` tool
(`src/tools/registry.zig:370`) always uses the built-in defaults.

**A Zig port**: the *discovery* is Phase 9 (`TASKS.md:172-180`) — frontmatter
`name`, `description`, `tools`, `model`, `effort` in `.zode/agents/*.md`. The
*command* is a picker over the discovered files once Phase 9 exists.

**Effort**: **M** for the command, **L** with Phase 9 first. **Risk**: medium
— an agent definition can widen a tool set, and the safety floor (read-only,
effort `low`, depth 1) must not be escapable.

**Dependencies**: Phase 9, `src/lib/subagent.zig`.

### 3.12 `/hooks` — the hook editor

**Reference implementation**: the `/hooks` command opens a `HooksConfigMenu`:
the hooks per event (`PreToolUse`, `PostToolUse`, `Stop`, …) with their
matchers and commands.

**Ours**: nothing. Phase 5 (`TASKS.md:126-137`) is the hooks themselves
(`.zode/hooks.json`, four events, `matcher` / `if` / `command` /
`timeout_ms` / `once`).

**A Zig port**: once Phase 5 lands, the command is a modal over the parsed
config. The config file is JSON, and zode already has a JSON reader.

**Effort**: **M** for the command, **L** with Phase 5. **Risk**: medium — a
hook that runs a command on every tool call is arbitrary code execution with
an implicit grant.

**Dependencies**: Phase 5, Phase 6 (the `if` syntax is the permission-rule
syntax).

### 3.13 `/config` — one panel instead of six commands

**Reference implementation**: the `/config` command opens the `Settings` panel,
tab `Config`: model, theme, editor mode, output style, env vars, permissions,
statusline, keybindings, the sandbox.

**Ours**: six separate commands (`/providers`, `/use`, `/effort`,
`/allowlist`, `/mode`, `/style`) plus Ctrl+A for the key. There is no single
place that answers "what is my configuration right now?".

**A Zig port**: a modal with one row per setting and the current value, in the
style of the model palette (`src/palette.zig` already supports a two-column
mode). The rows are assembled from the same functions the commands call
(`cmdProviders`, `cmdStyle`, `cmdAllowlist`), so the panel cannot drift from
the commands.

**Effort**: **M**. **Risk**: low. **Dependencies**: `src/palette.zig`,
`src/commands.zig`.

### 3.14 `/mcp` — manage the MCP servers

**Reference implementation**: the `/mcp` command opens an `MCPSettings` panel:
list the servers with their state, enable/disable one or all, add one, and
reconnect.

**Ours**: nothing. MCP over stdio is Phase 12 (`TASKS.md:204-211`).

**A Zig port**: Phase 12 first (the client), then the command. The command's
data is the server list, which the client already holds.

**Effort**: **L** overall; **S** for the command once the client exists.
**Risk**: medium — an MCP server is another process the model can talk to.

**Dependencies**: Phase 12.

### 3.15 `/keybindings` and `/vim` — a configurable editor

**Reference implementation**: the `/keybindings` command writes a template file
and opens it in `$EDITOR`; the `/vim` command toggles the editor mode,
persisted in the global config.

**Ours**: the editor (`src/lib/editor.zig`) has a **fixed** key map: Ctrl+A/E/
U/K/W, Alt+B/F, Ctrl+←/→, Shift+Alt+Enter, history on ↑/↓. No vim mode, no
user-remappable keys.

**A Zig port**: a `keybindings.json` (or a `.zode/keys.json`) read at startup;
the editor's key handler consults it. The vim mode is a bigger job: a modal
editor with its own cursor model inside the existing one.

**Effort**: **M** for the keymap file, **L** for the vim mode. **Risk**:
medium — a keymap that shadows "enter sends" is a broken app, and the editor's
wrap/cursor code is the part this repo has already broken several times.

**Dependencies**: `src/lib/editor.zig`, `src/tui.zig` (the key handler).

### 3.16 `/status` and `/usage` — the same panel, in the reference implementation

**Reference implementation**: the `/status` and `/usage` commands are **tabs of
the same `Settings` panel** (its `Status` and `Usage` tabs), with the third tab
`Config`.

**Ours**: `/session` (`src/commands.zig:521`) prints the session id, the
message count and the path; `/providers` prints the key state; `/bench`
prints the turn statistics; `/usage` prints the token totals. All four are
text lines in the history.

**A Zig port**: §3.13's panel absorbs both. `/status` becomes a row group
(version, model, provider + key, context %, cache, catalogue reachability);
`/usage` becomes another (the session's tokens + the provider's quota, if the
provider exposes one).

**Effort**: **S** once the panel exists, **M** on its own. **Risk**: low.

### 3.17 `/release-notes` and `/version` — cheap diagnostics

**Reference implementation**: the `/release-notes` command fetches the
changelog with a **500 ms** timeout and falls back to the cached copy; the
`/version` command prints the version the session is running.

**Ours**: `src/lib/selfupdate.zig:10` knows `current_version` and the repo
URL, and `src/main.zig:744` calls `autoUpdate` at startup — but there is no
command and nothing is shown to the user.

**A Zig port**: `/version` is one line. `/release-notes` fetches the GitHub
releases API for `src/lib/selfupdate.zig:13`'s repo with the same 500 ms
budget and prints the notes.

**Effort**: **S**. **Risk**: low. **Dependencies**: `src/lib/selfupdate.zig`,
`src/lib/http_client.zig`.

### 3.18 `/tags`, `/tasks`, `/stats` — session metadata

- `/tag`: toggles a searchable tag on the session. Phase 29.3 already wants a
  `#<tag>` column in the resume row (`TASKS.md:587`), so the tag has to exist
  before that row can show it. **Effort S**, **risk low**.
- `/tasks` (alias `/bashes`): the reference implementation's
  `BackgroundTasksDialog` covers **every** background thing (bash jobs, agents,
  remote tasks). Ours is `/bg` (`src/agent.zig:1443`), which only walks
  `bgproc`'s 8 slots. Phase 10 (`TASKS.md:183-191`) unifies `bgproc` and
  `bash_output` into one registry — that is the moment the command becomes
  honest. **Effort M** after Phase 10, **risk low**.
- `/stats`: the reference implementation's activity report. `/bench`
  (`src/lib/bench.zig:120`) has the counters but not the "activity" (what did
  you work on). **Effort M**, **risk low**.

### 3.19 `/add-dir` — a second working directory

**Reference implementation**: the `/add-dir` command opens an
`AddWorkspaceDirectory` panel: validates the path, adds it to
`additionalDirectories` (so its `CLAUDE.md` is read), and applies a permission
update so the tools may reach it.

**Ours**: no. The harness is single-root: the `read`/`write`/`grep` tools are
rooted at the cwd, and the AGENTS.md walk is upward from the cwd.

**A Zig port**: the permission part is Phase 6 (a rule that widens the
allowed roots). The tool part means the path allow-list has to reach
`src/tools/*.zig` — a real change to the tool layer, not to the command.

**Effort**: **L**. **Risk**: high — it widens what the model can touch. The
reference implementation pairs it with a permission dialog for exactly that
reason.

**Dependencies**: Phase 6, the permission dialog, the tool layer.

### 3.20 `/sandbox` — the OS sandbox

**Reference implementation**: the `/sandbox` command opens a `SandboxSettings`
panel: toggles the sandbox, shows the dependency state (`bubblewrap`/`seatbelt`),
allows per-command exclusions (`/sandbox exclude "command pattern"`), and
reports the "managed by policy" case.

**Ours**: nothing. Phase 6 mentions an optional sandbox with `bwrap`/`firejail`
(`TASKS.md:148`) and Phase 25 has the classifier that would decide what needs
one (`TASKS.md:435-447`).

**Effort**: **L**. **Risk**: high (a sandbox that is wrong is a sandbox that
does not contain anything).

**Dependencies**: Phase 6, Phase 25.

### 3.21 `/btw` — a side question that does not interrupt

**Reference implementation**: the `/btw` command asks a question in a side
scrollback with its own request, and the main conversation is untouched.

**Ours**: nothing equivalent. The `task` tool (`src/tools/registry.zig:370`)
runs a subagent, but it is the *model* that calls it, and it returns into the
main turn's context — which is the opposite of "without interrupting".

**A Zig port**: the mechanism is a **second worker** with its own window that
prints its answer as a side note and does not touch the session's message
list. Our worker machinery (`beginWorker`/`endWorker`, the queue) makes this
possible; the disposable window is `src/lib/subagent.zig`.

**Effort**: **M**. **Risk**: medium — a second concurrent stream against the
same key is a 429 waiting to happen (the `/free-auto` and `/submodel` notes
about concurrency).

**Dependencies**: `src/agent.zig`'s worker machinery, `src/lib/subagent.zig`.

### 3.22 `/clear` — the name, the caches and the context

**Reference implementation**: the `/clear` command (aliases `/reset`, `/new`)
does the full teardown: session-end hooks, a cache-eviction hint to the
inference service, a **new session id**, `clearSessionCaches()` (the context
caches, the file-suggestion caches, the commands/skills cache, the
prompt-cache-break detection, the system-prompt injection, the post-compact
cleanup, the "sent skill names" so the skill listing is re-sent, the memory
file cache, the repository caches, the git-dir cache, the session env vars),
and the task-output eviction.

**Ours**: `/new` (`src/agent.zig:2454`) destroys the old session, resets the
cache stats, creates a new session and forgets the git probe. It does **not**
reset the *sent skill names* (so the skill listing is not re-sent after
`/new`), the *read cache*, the *user commands* or the *output style*.

**A Zig port**: the cheap half is a `resetCachesForNewSession()` that clears
the read cache, the skills-sent marker and the user-command cache. The
expensive half (the reference implementation's cache list) is mostly N/A for
us — we have no hooks, no LSP diagnostic registry, no file-suggestion cache.

**Effort**: **S** for the cache half; the *name* `/clear` plus the `/reset`
alias is free. **Risk**: low.

**Dependencies**: `src/lib/readcache.zig`, `src/lib/skillstore.zig`,
`src/session.zig`.

### 3.23 `/exit` and the goodbye

**Reference implementation**: the `/exit` command (alias `/quit`): in a `tmux`
bg session it **detaches** instead of killing; otherwise a random goodbye and
`gracefulShutdown(0, 'prompt_input_exit')`.

**Ours**: `/quit` (`src/commands.zig:624`) and Ctrl+C. The TUI handles the
quit; `quitFast` (`src/agent.zig`) skips the defers and exits fast.

**Effort**: **S** (add `/exit` as an alias, and make Ctrl+C detach in a tmux
bg session if we ever want one). **Risk**: low.

### 3.24 Seven more

- **`/color`** — the reference implementation sets the **prompt-bar / agent
  colour** for the session and persists it in the transcript (`AGENT_COLORS`,
  `saveAgentColor`). **Ours**: `/color` (`src/agent.zig:8704`) is the **diff
  palette** (`default | daltonized`) — a different feature that happens to have
  taken the name. Anyone reading the reference implementation's `/color` and
  finding ours will think the feature is done. **Effort S** (the palette
  machinery exists; the colour would live in the session's metadata), **risk
  low**, **dependencies**: none beyond the status row.
- **`/insights`** — a 3 200-line prompt that analyses the user's own sessions
  and produces a structured report (a JSON schema of nine sections: project
  areas, interaction style, what works, friction analysis, suggestions, and so
  on). **Ours**: `/bench` (`src/lib/bench.zig:120`) has the raw counters
  (turns, iterations, TTFT, the capped-turn percentage) and no analysis.
  **Effort M** (the analysis is a prompt plus a schema; the *data* is ours
  already), **risk low** (it is read-only over the session files),
  **dependencies**: `src/session.zig`, `src/lib/bench.zig`.
- **`/memory`** — picks a memory file (`CLAUDE.md`, `~/.claude/CLAUDE.md`),
  creates it if missing, and opens it in `$EDITOR`. **Ours**: nothing, but the
  file we read is `AGENTS.md` and the `edit` tool can already write it — the
  gap is the *picker and the editor hand-off*, not the capability. **Effort S**,
  **risk low**, **dependencies**: `src/lib/prompt.zig` (the instruction-file
  contract) and `src/tools/registry.zig:102` (the `edit` tool).
- **`/pr-comments`** — a `prompt` command that fetches and formats the
  comments of a GitHub PR with `gh pr view --json number,headRepository` and
  two `gh api` calls, and returns **only** the formatted comments. **Ours**:
  nothing. It is the same shape as `/review` (§3.4): a prompt plus the
  ``!`cmd` `` substitution, and the same `gh` dependency. **Effort S**, **risk
  low-medium** (`gh` must be installed and it talks to a remote).
- **`/fast`** — toggles Anthropic's "fast mode" (a faster Opus variant) and
  may switch the model to one that supports it. **Ours**: nothing, and the
  concept is provider-specific. Our nearest thing is `/effort` (a level) and
  `/free-auto` (a rotation over the free models) — a `/fast` that means "use
  the cheapest model that can answer this" would be a different feature with a
  different name. **Effort S**, **risk low**, **dependencies**: none beyond
  `/effort`'s model ladder.
- **`/ide`** — detects the running IDEs, manages the integration, shows the
  status, and `open`s a file in it. **Ours**: no IDE integration, but the
  `lsp` tool (`src/tools/registry.zig:336`) already talks to the editor's
  language server. The IDE *picker* is a UI we do not need until we need it.
  **Effort M**, **risk low**, **dependencies**: the `lsp` client.
- **`/theme`** — a runtime theme picker. **Ours**: the theme is a compile-time
  table (`src/lib/theme.zig`), so a runtime theme means the styles have to
  become values instead of constants, and every painted cell has to read them.
  **Effort M-L**, **risk medium** (the theme is the one thing every draw
  touches), **risk low** in behaviour. **Dependencies**: `src/lib/theme.zig`,
  `src/tui.zig`.

### 3.25 Three that TASKS.md already plans

- **`/branch`** — **Phase 30.4** (`TASKS.md:613-617`). The reference
  implementation copies the transcript, rewrites the session id, stamps the
  provenance (`forkedFrom { sessionId, messageUuid }`) and saves a custom
  title. Ours would do the same with our JSONL: copy the file, rewrite the id,
  stamp the parent chain, carry the side tables over. **Effort M**, **risk
  medium** (a fork that resumes wrong is worse than no fork), **dependencies**:
  Phase 30.
- **`/commit`** — **Phase 31.1-31.4** (`TASKS.md:627-641`). The reference
  implementation's prompt inlines four git commands, states a six-rule safety
  protocol (never update the config, never `--no-verify`, never `--amend`, no
  secret files, no empty commits, never `-i`) and asks for one heredoc commit
  and nothing else. Ours already has the `git_commit` **tool**
  (`src/tools/registry.zig:219`); what is missing is the command that
  *composes* the context and the message. **Effort S-M**, **risk
  low-medium** (it writes to the repository), **dependencies**: Phase 31.
- **`/commit-push-pr`** — **Phase 31.5** (`TASKS.md:642-646`). Branch + commit +
  push + `gh pr create`/`edit`, with a PR body template (`## Summary` /
  `## Test plan` / a managed `## Changelog`), a title under 70 characters and an
  idempotent `gh pr view … || true` check. **Effort M**, **risk medium** (it
  pushes and it talks to GitHub), **dependencies**: Phase 31.

### 3.26 Reference surface that is MISSING but **not worth doing**

These are Anthropic-account, browser, marketplace or remote-session features
that zode, as a local multi-provider harness with no OAuth and no plugin
system, has no equivalent of and no reason to grow:

`/login` (the OAuth half), `/logout`, `/upgrade` (subscription), `/usage`
(plan-quota half), `/cost` (dollars), `/extra-usage`, `/rate-limit-options`,
`/privacy-settings`, `/mobile`, `/desktop`, `/chrome`, `/stickers`,
`/passes`, `/think-back`, `/thinkback-play`, `/plugin`, `/reload-plugins`,
`/install-github-app`, `/install-slack-app`, `/remote-control`, `/remote-env`,
`/web-setup`, `/session` (the remote-QR half), `/voice`, `/ultraplan`,
`/ultrareview`, `/statusline` (the *customisable* status line — ours is built
in and not scriptable), `/advisor` (the *command*; the tool is Phase 32.2),
`/init-verifiers` (Phase 32's verifier roles cover the intent),
`/heapdump`, `/version` (the command; the value exists), `/files` (no — that
one is a gap, see §3.6).

---

## 4. Already planned in TASKS.md

| Gap from §3 | TASKS.md phase | Covered? |
|---|---|---|
| `/branch` (fork a conversation) | **Phase 30.4** (`TASKS.md:613-617`) | **yes** — item by item |
| `/rename` (custom title) | **Phase 30.1** (`TASKS.md:607`) | **yes** — the title key is the first half |
| `/resume` as a picker | **Phase 29** (`TASKS.md:576-600`) | **yes** — six items, incl. `/resume <term>` |
| `/commit` as a command | **Phase 31.1-31.4** (`TASKS.md:627-641`) | **yes** — "copy the prompt text verbatim" |
| `/pr` (commit-push-pr) | **Phase 31.5** (`TASKS.md:642-646`) | **yes** |
| `/review` (PR review) | **Phase 31.1** (the ``!`cmd` `` block "makes every command a verified-context command") + Phase 32.1 (the protocol) | **partly** — the *mechanism* is planned, the *command* is not written down |
| `/security-review` | **Phase 31.1** (mechanism) + **Phase 32** (the verify/refute protocol) | **partly** — same |
| `/advisor` | **Phase 32.2** (`TASKS.md:655-659`) — as a **tool**, not a command | **partly** — the command (`/advisor <model>\|off`) is not planned |
| `/agents` | **Phase 9** (`TASKS.md:172-180`) — the definitions; Phase 26 (`TASKS.md:450-463`) — the roles | **partly** — the *menu* is not planned |
| `/hooks` | **Phase 5** (`TASKS.md:126-137`) | **partly** — the config and the runtime are planned, the menu is not |
| `/mcp` | **Phase 12** (`TASKS.md:204-211`) | **partly** — the client, not the UI |
| `/permissions` (rule editor) | **Phase 6** (`TASKS.md:140-149`) | **partly** — the rules, not the UI |
| `/sandbox` | **Phase 6** (optional sandbox) + **Phase 25** (the classifier) | **partly** |
| `/tasks` (unified background tasks) | **Phase 10** (`TASKS.md:183-191`) | **partly** |
| `/plan` (the plan file) | **Phase 15** (the task graph) gives the state; nothing plans the plan *file* | **no** |
| `/config` (the panel) | **Phase 23** (`TASKS.md:414-423`) plans a `config` **tool** for the model, not a user panel | **no** |
| `/status` / `/usage` panel | — | **no** |
| `/doctor` | — | **no** |
| `/init` | — | **no** |
| `/files` | — | **no** |
| `/release-notes`, `/version` | — | **no** |
| `/clear` (the caches) | — | **no** (the new-session path exists; the cache reset does not) |
| `/diff` (uncommitted + per-turn) | — | **no** |
| `/rewind` (an arbitrary point) | — | **no** (`/undo` is the last turn only) |
| `/keybindings`, `/vim` | **Phase 13** (`TASKS.md:214-219`) — "keybindings/vim mode — outside the core" | **yes**, explicitly deferred |
| `/btw` | — | **no** |
| `/add-dir` | — | **no** |
| `/compact` (on demand) | **Phase 7** (`TASKS.md:152-161`) plans compaction v2 but not an on-demand trigger | **no** |
| `/theme` | — | **no** |
| `/terminal-setup` | — | **no** (Shift+Enter already works; the installer is a portability nicety) |
| `/tag` | **Phase 29.3** wants a `#<tag>` column in the resume row | **partly** — the column, not the command |
| `/memory` (open `AGENTS.md` in `$EDITOR`) | — | **no** |
| `/pr-comments` | **Phase 31.1** (the mechanism) | **partly** — the mechanism, not the command |
| `/fast` | — | **no** (and provider-specific) |
| `/ide` | — | **no** (the `lsp` tool covers the useful half) |
| `/output-style` | **Phase 4** (`TASKS.md:115-123`) — done as `/style` | **yes** |
| `/skills` | **Phase 1** (`TASKS.md:63-80`) — done | **yes** |
| `/copy` | **Phase 28** (`TASKS.md:549-573`) — done | **yes** |
| `/context` | — | **no** (ours is a different visualisation) |
| `/help` | — | **n/a** (we have it) |
| `/model`, `/effort` | — | **n/a** (we have them) |

**Not covered anywhere** (the honest list): `/init`, `/doctor`, `/files`,
`/config` panel, `/status` panel, `/release-notes`, `/version`, `/clear`
cache reset, `/diff`, `/rewind` to an arbitrary point, `/compact` on demand,
`/btw`, `/add-dir`, `/theme`, `/terminal-setup`, `/memory`, `/pr-comments`,
`/fast`, `/ide`.

---

## 5. Recommended order

Ranked by value per unit of effort. "Value" is what a user hits in a normal
week, weighted by how bad the current answer is when it is missing.

1. **`/files`** — **S**. Eight lines of reference code and we already hold the
   data (`src/lib/readcache.zig`). It answers "what is the model looking at?",
   which is the question you ask when a turn goes sideways. Cheapest item on
   this list by a wide margin.
2. **`/init`** — **M** for the prompt, **L** with the interview phase. The
   highest-value *missing* command: without it, a new user has no `AGENTS.md`
   and the harness silently runs with the built-in prompt only. Port the
   reference implementation's prompt text verbatim and let the model do the
   work — the harness should not be the one writing prose about a codebase.
3. **`/rename` + the `#tag` + the session title** — **S** each, together the
   **readability layer** of the session list. Phase 30.1 already has the
   design; the command is 20 lines. Without it, Phase 29's resume rows are
   all `(session)`.
4. **`/review` and `/security-review`** — **S-M** each, together they are the
   highest-traffic reference command we do not have. Both are prompt commands
   whose text is the reference implementation's, and Phase 31.1 already
   specifies the ``!`cmd` `` substitution. Two commands, two prompts, one
   mechanism.
5. **`/clear` (with the cache reset) and the `/exit` alias** — **S**. `/new`
   exists but leaves the read cache, the skills-sent marker and the user
   commands stale; `/clear` is the name people type.
6. **`/doctor`** — **M**. The one command you run when zode is behaving
   strangely. Its checks are read-only, and half of them (the provider key
   state, the config, the session directory's permissions) we already compute
   elsewhere and could reuse.
7. **`/config` + `/status` + `/usage` as one panel** — **M**. Six scattered
   commands become one "what is my configuration?" screen. The rows are
   assembled from the functions the commands already call, so it cannot drift.
8. **`/compact` on demand** — **S-M**. The compaction machinery is done; the
   missing piece is a trigger and an argument. A user with a 200 k-token
   history has no way to say "summarize this now".
9. **`/release-notes` + `/version`** — **S**. Two one-liners on top of
   `src/lib/selfupdate.zig`, and the self-update already runs at startup with
   nobody told.
10. **`/diff`** — **M**. The reference implementation's diff dialog shows the
    uncommitted changes and the per-turn diffs; we paint the diff inline but
    have no way to ask "what did I change in this session?". The diff renderer
    exists (`src/lib/diffview.zig`); the command is the missing half.

**Deliberately last** (see §3.26): `/mcp` and `/add-dir` and `/sandbox` wait
for Phases 6 and 12 — building a UI over a rule engine that does not exist
yet is how a command ends up promising something the engine does not do.
`/vim` waits for Phase 13's explicit "outside the core".
