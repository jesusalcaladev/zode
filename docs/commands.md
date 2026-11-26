# Slash commands

Type any of these in the TUI input line. Slash commands are dispatched by the
TUI palette; `--chat` takes plain text only (it sends `"/context"` literally).
The generated list of all commands is in
[`docs/commands-generated.md`](commands-generated.md).

Every command in the generated reference comes from the TUI command table with its syntax, what it does, and how to use it.

---

## Output styles

### `/style <name>`

Selects an output style (instruction block appended to the system prompt).
`/style` with no argument reports the current one; `/style off` clears it.
The choice is persisted in `~/.config/zode/config.json` and restored at startup.

Bundled styles: `default`, `concise`, `explanatory`, `learning` and `terse`.

- `terse` is the token-saving style: it selects short tool schemas (~26% fewer
  schema bytes per request) and restates every rule those schemas normally
  carry in a single block, so nothing is lost. The selection is reported as
  `output style: terse — terse tool schemas…`. Custom styles can opt in with
  `terse_tools: true` in their frontmatter.

## Plugins, remote sessions and keybindings

### `/plugin`

Declarative plugin marketplace. A plugin is a JSON manifest under
`.zode/plugins/<name>/plugin.json` (or the user config dir) that contributes
instructions to the system prompt — it never executes code.

- `/plugin list` — bundled catalog plus installed plugins (project shadows user).
- `/plugin search <query>` — search the bundled catalog by name or description.
- `/plugin install <name>` — copy a catalog entry into this project.
- `/plugin remove <name>` — remove a project plugin.
- `/plugin info <name>` — show a catalog entry's instructions.
- `/plugin enable|disable <name>` — toggle an installed plugin (no reinstall).

### `/remote`

Sync sessions with an HTTP endpoint configured by `ZODE_REMOTE_URL` and
`ZODE_REMOTE_TOKEN` (see `docs/settings.md`). `tools/remote_server.py` is a
working reference server.

- `/remote status` — show the configured URL (never the token).
- `/remote list` — list remote session ids, sizes and update times.
- `/remote pull <id>` / `/remote push <id>` — transfer one session file.
- `/remote sync [local|remote]` — plan and apply a sync; conflicts skip by
  default, `local`/`remote` choose a side.

### `/keybinds`

Custom key -> command map, persisted in `~/.config/zode/config.json`.

- `/keybinds list` — show the current bindings.
- `/keybinds set <key> <command>` — e.g. `/keybinds set alt+r /review`.
- `/keybinds reset` — back to defaults (`f2` help, `f3` context, `f4` session,
  `f5` tasks). Bindings do not fire while vim normal mode is active.

## Sessions

### `/new`

Starts a fresh session: new id, new session file in `./sessions/`. Equivalent to `/clear`.

### `/resume`

Reopens the most recent session. Also happens at startup when `ZODE_RESUME=1` or when you pass `--resume`.

### `/resume <term>`

Resolve a UUID -> file -> exact title. If the term matches more than one session, zode errors and reports the count of matches so you can narrow it down.

### `/session`

Open the **session picker**: one row per session, newest first, with age.

**Keys in the picker:**
- `↑` / `↓` — navigate rows
- `Enter` — resume the focused session
- `Esc` — close the picker (or clear the filter when filtering)
- `F2` — rename the focused session
- `s` — toggle semantic search
- type anything — filter rows by title (case-insensitive substring)
- `↑` on the first row — jump into the filter

### `/rename <name>`

Set a custom title for the current session. Custom titles win over AI-generated titles and are never overwritten by the AI.

### `/compact`

Set the compaction mode: `off`, `elide`, or `full`. See `docs/settings.md` §4 for how the two tiers (elide + summarize) work and how the budget is computed.

### `/clear` (alias `/reset`)

Wipe the conversation. Alias for `/new`.

---

## Provider & model

### `/model`

Open the **model palette**: every model of every connected provider, with its context window and whether it is free. Keyboard (`↑↓`, `tab`, `enter`), mouse (move to highlight, click to choose), and wheel (scroll) all work. Picking a model adopts **its** context window for the token budget, unless `ZODE_CONTEXT_LIMIT` says otherwise. Also reachable with `Ctrl+T`.

What you pick is **remembered**: the next time you open zode it comes back with the same provider and model, unless `ZODE_MODEL` or a `model` in `config.json` says otherwise (an explicit instruction beats the habit). The memory lives in `~/.config/zode/last_model`.

### `/providers`

List all providers with their key state — which ones have a key configured and which is active.

### `/submodel`

Show which model subagents run on. Precedence: session > `config.json` > env > off.

### `/effort`

Set the reasoning effort rung: `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max` (default `medium`). Without an argument it opens the effort picker. Not every model supports every rung — zode maps to the closest rung the model understands.

### `/color`

Set the diff palette: `default` or `daltonized` (colour-blind-safe).

---

## Context & verification

### `/context`

Print estimated tokens vs budget, a gauge, a breakdown (system + history), the source of the limit, and the elided count. This is where you confirm what limit is actually in force.

### `/usage`

Session input/output tokens, cache reads/writes, and request totals.

### `/cache`

Prompt-cache hit rate, with evidence.

### `/cost`

What this session has cost, per model.

### `/bench`

Iterations, TTFT (time to first token), tokens/s, and how often the limit was hit.

### `/verify`

Run automatic verification (typecheck / test) after edits.

### `/check`

Force a typecheck / syntax check on changed files.

The exit gate (`AutoCheck.exitGate`) runs at the top of each iteration and refuses to end on red (`refused_failed`), stale green (`refused_unverified`), or unverified writes.

---

## Files

### `/read <path>`

Read a file. Multiple paths accepted.

### `/write <path>`

Write or create a file.

### `/edit <path>`

Edit a file: `old_string` -> `new_string`.

### `/files`

Show what the model has read and what it has changed in this session.

### `/file open`

Open the focused changed file in a small in-TUI editor: `Ctrl+S` saves it back,
`Esc` closes. No external `$EDITOR` is spawned and the terminal is never
suspended. Files above 4 MB are refused rather than partially loaded.

### `/glob <pattern>`

Find files by pattern.

### `/grep <pattern>`

Search file contents by pattern.

### `/notebook <path>`

Read a Jupyter notebook outline (numbered: index, type, size, first line).

### `/notebook_edit <index>`

Edit a notebook cell by index. Round trip preserves outputs, execution counts, cell ids, and metadata.

---

## Web & search

### `/web_fetch <url>`

Fetch a URL and extract text.

### `/web_search <query>`

Search the web (DuckDuckGo / Brave / … depending on config).

---

## Git and GitHub

### `/git`

Read-only local Git overview: current branch, working tree status, and recent commits. No network calls and no destructive actions.

### `/github`

Native GitHub integration status for the current workspace (local, read-only, no network API calls by default).

- Shows resolved repository/host from git remotes (or reports unresolved), current branch when available, token configuration state, and token source (`GITHUB_TOKEN`, `GH_TOKEN`, or `~/.config/zode/auth.json`) without ever showing token values.
- Explains how to use the native `github` tool (structured, permission-checked) for remote GitHub operations and which ops are read vs write.
- `/pr` and `/commit-push-pr` workflows prefer native `github` operations when supported, with `gh`/CLI fallback when needed.

Usage: `/github [status]`

### `/pr`

Guided pull request workflow. Prefers native `github` tool operations (`repo`, `pr_list`/`pr_view`, `pr_checks`, `pr_create`/`pr_update`, `pr_comment`) with `gh`/CLI fallback, while keeping git safety and idempotence (inspect existing PRs before creating duplicates, full diff from merge base, no secrets in output).

### `/commit-push-pr`

Commit, push, and open/update a pull request in one guided flow. Prefers native `github` tool operations for PR inspection/creation/update when supported, with `gh`/CLI fallback.

---

## Permissions

### `/permissions`

Show every permission rule in force and which file each rule came from (`local` > `project` > `user` > `policy`; `deny` beats any `allow`).

**Permission flow:** `model.requestPermission()` blocks until the UI answers. Priority:
1. `/yolo` (global bypass) — asks nothing
2. persisted allowlist (`~/.config/zode/permissions.json`, `0600`)
3. dialog

Denied answers feed back as `tool_result "denied: permission required"`. `lsp` asks NO permission (spawns from a fixed table, read-only only). `batch` asks the union of step permissions.

### `/ask`

Toggle ask mode (on | off) — whether the model may ask the user questions. When off the model cannot interrupt with questions and every tool runs at full speed.

## Subagents & skills

### `/task <description>`

Send a read-only investigation to a subagent on its own context window. Depth 1, effort `low` always, 24 k budget. Parallel capped at `ZODE_TASK_PARALLEL` (default 3) by waves.

### `/free-auto`

Rotate between free models of providers that have a key. Quotas cause rotation (`quotaVerdict` distinguishes gate 403 vs account 403 vs 401/404/5xx). Only conversational models are selected (embeddings/images/audio excluded).

### `/skills`

List available skills from `.zode/skills/<name>/SKILL.md` (project) and `~/.config/zode/skills/<name>/SKILL.md` (personal).

### `/skill <name>`

Load a skill. Only the skill's name + description enter the prompt (budget = 1% of `ZODE_CONTEXT_LIMIT`). Project overrides global; no merge.

### `/goal <text>`

Set a task goal, which enables a ceiling at 60 iterations.

### `/todo`

Manage the visible todo list.

### `/help`

Show available commands. The complete, generated list of all 75 commands is in
[`docs/commands-generated.md`](commands-generated.md).

### `/update`

Check for and install a new zode binary. The check is cached in `~/.cache/zode/update.json` for six hours. `/update` downloads the release asset, runs it once to prove it works on this machine, verifies `--version`, refuses to go backwards, writes `{exe}.new`, then atomically renames over.

### `/version`

Show the build version.

### `/quit` (alias `/exit`)

Quit the application.

---

## Keyboard shortcuts

| Key | Action |
|---|---|
| `Ctrl+C` | Clear input; press again on empty input to quit (Esc interrupts the turn) |
| `Ctrl+D` | Scroll half a page down |
| `Ctrl+L` | Redraw screen |
| `Ctrl+T` | Model palette (providers | models) |
| `Ctrl+P` | Command palette |
| `Ctrl+A` | Connect a provider |
| `Ctrl+V` | Attach the clipboard image to the next message |
| `Ctrl+,` | Settings screen |
| `?` | Shortcut list (empty input) |
| `F2/F3/F4/F5` | Custom bindings: help / context / sessions / tasks |
| `Ctrl+R` | Expand/collapse last tool result (or refresh the model palette) |
| `Alt+T` | Expand/collapse thinking blocks in the transcript (collapsed by default) |
| `Ctrl+O` | Transcript / history |
| `Ctrl+F` | Search the transcript; prefix the query with `/` for a regex (`/foo|bar`) |
| `↑` / `↓` | Navigate picker rows |
| `Enter` | Select / submit |
| `Esc` | Cancel / close picker / dismiss filter |
| `F2` | Rename focused session (in picker) |
| `s` | Toggle semantic search (in session picker) |
| `Shift+Tab` | Cycle permission mode |

---

## Where each doc lives

| File | For |
|---|---|
| `README.md` | Install, quick start, session format, verification, contributing |
| `docs/settings.md` | All environment variables, `config.json`, key precedence, token budget |
| `docs/commands.md` | this file — every slash command and what it does |
| `docs/usage.md` | how to use zode, end to end (run -> model -> task -> verify) |
| `docs/architecture.md` | how streaming, compaction, permissions, subagents, MCP, self-update work |
| `AGENTS.md` | code conventions for contributors and AI coding agents |
