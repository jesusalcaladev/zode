# Using zode

This guide walks through the normal flow of working with zode: run, pick a model, do a task, manage sessions, and verify the results. For the full list of environment variables and config files, see `docs/settings.md`. For how the pieces work under the hood, see `docs/architecture.md`.

## 1. Run zode

### TUI (interactive)

```bash
./zig-out/bin/zode
```

Type your task at the prompt and use slash commands (`/command`) for everything else. The keyboard shortcuts are listed in §8.

### Headless (no TTY)

Good for scripts, CI, or anything without a terminal:

```bash
./zig-out/bin/zode --chat "refactor the read cache to use a sliding window"
./zig-out/bin/zode --resume             # reopen the most recent session
./zig-out/bin/zode --models             # list available models of the active provider
```

`--chat` accepts a slash command too: `./zig-out/bin/zode --chat "/context"`.

## 2. Configure (one line is enough)

Zode works out of the box on the OpenCode free tier. To use a different provider:

```bash
export ZODE_API_KEY="your-key"
export ZODE_PROVIDER="openrouter"   # opencode | openrouter | anthropic | openai | groq | deepseek | …
```

Keys are looked up in this order:
1. `~/.config/zode/auth.json` — what you typed in `/connect` (`0600`, wins over env)
2. the provider's own variable (`ZODE_OPENROUTER_KEY`, `ZODE_ANTHROPIC_KEY`, …)
3. `ZODE_API_KEY` — the generic fallback

See `docs/settings.md` §1–§2 for the full provider table and `config.json` schema.

## 3. Pick a model

`/model` (or `Ctrl+T`) opens the model palette: every model of every connected provider, with context window and whether it is free. Pick one to switch provider and/or model.

Quick switch by name:

```text
/use openrouter
/use anthropic claude-3-5-sonnet
```

Effort (reasoning rung) via `/effort`: `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max` (default `medium`).

Subagents run on their own model — see `/submodel` (session > `config.json` > env > off).

## 4. Do a task

Just type it:

```
read src/tui.zig and tell me why the scroll does not follow
```

Zode decides which tools to call, runs them on your machine, and streams the answer back. Useful commands while working:

| Command | What it does |
|---|---|
| `/read <path>` | Read a file (multiple paths accepted) |
| `/write <path>` | Write or create a file |
| `/edit <path>` | Edit a file (old_string → new_string) |
| `/glob <pattern>` | Find files by pattern |
| `/grep <pattern>` | Search file contents |
| `/task <description>` | Send a read-only investigation to a subagent |
| `/web_search <query>` | Search the web |
| `/web_fetch <url>` | Fetch a URL and extract text |

### Permissions while you work

Zode asks before destructive actions. The flow:

1. `/yolo` (bypass) — asks nothing (global switch).
2. persisted allowlist (`~/.config/zode/permissions.json`, `0600`) — pre-approved tools/commands.
3. dialog — the model blocks and waits for your answer; a denial feeds back as `tool_result "denied: permission required"`.

`/mode` cycles permission mode: `accept edits on` → `plan` → `read-only` → `bypass` (`/yolo`). `plan` refuses every write. `lsp` asks no permission (spawns from a fixed table, read-only only). `/allowlist` lists the pre-approved entries; `/permissions` shows every rule in force and which file it came from.

See `docs/architecture.md` §permissions for the rule precedence (local > project > user > policy; deny beats any allow).

## 5. Manage sessions

Sessions are append-only JSONL in `./sessions/zode-<id>.jsonl`; long lines are compressed and the file is never touched by compaction.

| Command | What it does |
|---|---|
| `/new` | Fresh session (new id, new file) |
| `/resume` | Reopen the most recent session (also `ZODE_RESUME=1` or `--resume`) |
| `/resume <term>` | Resolve UUID → file → exact title; ambiguity errors with the count |
| `/session` | Session picker: newest first, filter by title, `F2` renames, `Enter` resumes |
| `/rename <name>` | Custom title (wins over AI titles) |
| `/clear` (alias `/reset`) | Wipe the conversation |

### Session picker (`/session`) — three-tier search

1. **Title** — instant, case-insensitive substring. Always runs.
2. **Transcript** — fuzzy match over user + assistant prose (cropped at both ends). Debounced 1 s.
3. **Semantic** — optional stateful search via the `task` subagent (effort `low`, depth 1, 24k budget). Toggle with `s`; `Esc` cancels. Requires network/LLM.

Ranking: more than 60 s apart → recency wins; within a minute → relevance tiebreak.

Title resolution order: `custom_title` > `ai_title` (AI-generated at turn 3) > `name` > session id.

## 6. Watch the context budget

Four numbers decide compaction:

| Knob | Default | Meaning |
|---|---|---|
| `ZODE_CONTEXT_LIMIT` | unset | Overrides the model's window; always wins when set |
| model's window | from catalogue | Adopted when you pick a model in `/model` |
| fallback window | 128000 | When nothing above says anything |
| `ZODE_COMPACT_PCT` | `80` | Budget = this % of the window (clamped 10–95) |
| `ZODE_COMPACT` | `full` | `off`, `elide`, or `full` |
| `ZODE_RECENT_WINDOW` | `8` | Messages kept verbatim |

Two tiers, applied until the request is under budget:
1. **Elide** (`elide`, `full`): old tool results >256 B outside the recent window become a marker. No request, no tokens; the session file keeps the original.
2. **Summarize** (`full` only): oldest turns replaced by one summary from a single extra model call capped at 16 KB.

`off` does neither — the provider will eventually reject an over-long request.

Check where you stand with `/context` (window, budget, source of the limit, compaction mode, elided count).

## 7. Verify what zode wrote

| Command | What it does |
|---|---|
| `/context` | Tokens vs budget, gauge, breakdown |
| `/usage` | Input/output tokens, cache reads/writes, request totals |
| `/cache` | Prompt-cache hit rate, with evidence |
| `/cost` | Session cost, per model |
| `/bench` | Iterations, TTFT, tokens/s, limit hits |
| `/verify` | Run automatic verification (typecheck / test) after edits |
| `/check` | Force a typecheck / syntax check on changed files |

The exit gate (`AutoCheck.exitGate`) runs at the top of each iteration and refuses to end on red (`refused_failed`), stale green (`refused_unverified`), or unverified writes.

Project-level `zig build test` is the primary gate (800+ tests); `tools/pty_smoke.py` is the real-pty smoke test.

## 8. Keyboard shortcuts

| Key | Action |
|---|---|
| `Ctrl+C` | Interrupt / clear input (double-press to exit) |
| `Ctrl+D` | Exit |
| `Ctrl+L` | Redraw screen |
| `Ctrl+T` | Model palette (providers \| models) |
| `Ctrl+P` | Command palette |
| `Ctrl+R` | Expand/collapse last tool result (or refresh history) |
| `Ctrl+O` | Transcript / history |
| `↑` / `↓` | Navigate picker rows |
| `Enter` | Select / submit |
| `Esc` | Cancel / close picker / dismiss filter |
| `F2` | Rename focused session (in picker) |
| `s` | Toggle semantic search (in session picker) |
| `Shift+Tab` | Cycle permission mode |

## 9. Subagents & skills

- `/task <description>` — read-only investigation on its own context window (depth 1, effort `low`, 24 k budget; parallel capped at `ZODE_TASK_PARALLEL`, default 3).
- `/free-auto` — rotate between free models of providers that have a key; quotas cause rotation.
- `/skills` / `/skill <name>` — list and load skills from `.zode/skills/<name>/SKILL.md` (project) or `~/.config/zode/skills/<name>/SKILL.md` (personal). Only name + description enter the prompt (budget = 1 % of `ZODE_CONTEXT_LIMIT`). Project overrides global; no merge.

## Where each doc lives

| File | For |
|---|---|
| `README.md` | Install, quick start, command + shortcut cheat sheet |
| `docs/settings.md` | All environment variables, `config.json`, key precedence, token budget |
| `docs/usage.md` | this file — how to use zode, end to end |
| `docs/architecture.md` | how streaming, compaction, permissions, subagents, MCP, self-update work |
| `AGENTS.md` | code conventions for contributors and AI coding agents |
