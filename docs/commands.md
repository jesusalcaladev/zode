# Slash commands — complete reference

Type any of these in the TUI input line, or run them headless with:

```bash
./zig-out/bin/zode --chat "/command args"
```

Every command listed here is documented with its syntax, what it does, and how to use it.

---

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

### `/providers`

List all providers with their key state — which ones have a key configured and which is active.

### `/submodel`

Show which model subagents run on. Precedence: session > `config.json` > env > off.

### `/use <provider> [model]`

Quick switch provider and/or model by name. Omit the model to keep the current one.

Examples:
```text
/use openrouter
/use anthropic claude-3-5-sonnet
```

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

## Permissions

### `/mode`

Set the permission mode. Cycles: `accept edits on` -> `plan` -> `read-only` -> `bypass` (`/yolo`). Also reachable with `Shift+Tab`.

- `accept edits on` — normal: asks per the rules below
- `plan` — refuses every write
- `read-only` — read tools only
- `bypass` (`/yolo`) — asks nothing

### `/allowlist`

List allowed tools and commands (the persisted answers from the permission dialog).

### `/permissions`

Show every permission rule in force and which file each rule came from (`local` > `project` > `user` > `policy`; `deny` beats any `allow`).

### `/ask`

Toggle ask mode: whether the model may ask the user questions.

**Permission flow:** `model.requestPermission()` blocks until the UI answers. Priority:
1. `/yolo` (global bypass) — asks nothing
2. persisted allowlist (`~/.config/zode/permissions.json`, `0600`)
3. dialog

Denied answers feed back as `tool_result "denied: permission required"`. `lsp` asks NO permission (spawns from a fixed table, read-only only). `batch` asks the union of step permissions.

---

## Subagents & skills

### `/task <description>`

Send a read-only investigation to a subagent on its own context window. Depth 1, effort `low` always, 24 k budget. Parallel capped at `ZODE_TASK_PARALLEL` (default 3) by waves.

### `/free-auto`

Rotate between free models of providers that have a key. Quotas cause rotation (`quotaVerdict` distinguishes gate 403 vs account 403 vs 401/404/5xx). Only conversational models are selected (embeddings/images/audio excluded).

### `/skills`

List available skills from `.zode/skills/<name>/SKILL.md` (project) and `~/.config/zode/skills/<name>/SKILL.md` (personal).

### `/skill <name>`

Load a skill. Only the skill's name + description enter the prompt (budget = 1% of `ZODE_CONTEXT_LIMIT`). Project overrides global; no merge.

---

## Session & history

### `/goal <text>`

Set a task goal, which enables a ceiling at 60 iterations.

### `/todo`

Manage the visible todo list.

---

## System

### `/help`

Show available commands.

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
| `Ctrl+C` | Interrupt / clear input (double-press to exit) |
| `Ctrl+D` | Exit |
| `Ctrl+L` | Redraw screen |
| `Ctrl+T` | Model palette (providers | models) |
| `Ctrl+P` | Command palette |
| `Ctrl+R` | Expand/collapse last tool result (or refresh history) |
| `Ctrl+O` | Transcript / history |
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
