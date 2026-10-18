# zode

A code agent in the terminal, written in **pure Zig** (no libc, no C
dependencies; the only external one is libvaxis). **~1.3 MB** binary, ~6 MB RAM,
all code in one directory.

It is not a wrapper around another agent: it speaks HTTP with the provider, runs
the tools on your machine, and decides on its own which tool to call.

```bash
$ zode
######  ####  ####   ######
##  ## ##  ## ##   # ##
   ##  ##  ## ##   # ###
  ##   ##  ## ##   # ##
######  ####  ####   ######
────────────────────────────────────────
❯ read src/tui.zig and tell me why the scroll does not follow
```

## Quick Start

```bash
# Clone and build
git clone https://github.com/jesusalcaladev/zode.git
cd zode
zig build -Doptimize=ReleaseSafe  # Release binary at ./zig-out/bin/zode

# Configure (optional - uses OpenCode free tier by default)
export ZODE_API_KEY="your-key"          # Generic fallback
export ZODE_PROVIDER="openrouter"       # Or: opencode, anthropic, openai, groq, deepseek, local
export ZODE_MODEL="kimi-k2.6"           # Model to use
export ZODE_EFFORT="medium"             # low | medium | high (for o-series/GPT-5/Gemini)

# Run
./zig-out/bin/zode                      # TUI
./zig-out/bin/zode --chat "your task"   # Headless streaming
./zig-out/bin/zode --models             # List available models
```
## Key Features

| Feature | Description |
|---------|-------------|
| **Agent with tools** | Reads, writes, edits, compiles, searches, uses git. The loop decides autonomously (`ask` when the answer changes what it does; Plan mode investigates and asks you). Repeated identical calls get one corrective nudge before stopping. |
| **Parallel tools** | Read-only tools (read, grep, glob, list_files, web_fetch, web_search) run in parallel. Bash runs in background with incremental output. **ESC kills the whole process group** (grandchildren too). |
| **Parallel subagents** | Independent searches in one message go to subagents simultaneously (3 by default, `ZODE_TASK_PARALLEL`). Each has a throwaway window; reports return in request order. |
| **Multi-file operations** | `write`/`edit` accept `files: [...]` (max 8). Renaming a symbol is one call. Failed files are named with reasons. |
| **Batched reads** | `read` takes multiple paths — one round trip per call. Critical on free tiers where every request risks rate limits + backoff. |
| **`!` inline commands** | `!git status` runs the command and puts output into context, spending **no turn, no token**. |
| **Skills** | Folders of instructions loaded **on demand**. Prompt carries name + when to use; body loads only when needed. |
| **Two-tier compaction** | Old tool results elided without losing history; if still over budget, a summary is requested. Budget = model's context window. `/context` shows which number is used. |
| **File cache** | Unchanged `read` results are not re-sent — the most direct token saving. |
| **Visible prompt cache** | Fixed models show ~98% cache hit; routers (OpenRouter free) show 0% because each request hits a different upstream. zode tells you which you picked; `/cache` diagnoses from evidence. |
| **Multi-provider** | OpenCode, OpenRouter, Anthropic (native API with prompt caching), OpenAI, Groq, DeepSeek, local (Ollama/LM Studio). Connect from TUI without editing files. |
| **`check` tool** | Typechecks **this** project with its own compiler (`zig build`, `tsc --noEmit`, `cargo check`, etc.) in background, reports errors with file:line. Runs automatically after edits. |
| **`/undo`** | File snapshots per turn (ring of 8 turns, 24 files, 256 KB/file). |
| **`@file` mentions** | `@src/main.zig` injects file content into the prompt (last user message only). |
| **Task graph** | `task_create`/`task_get`/`task_list`/`task_update`/`task_stop` — stable IDs, blocking, owner, persisted per session. |


## TUI Shortcuts

| Key | Action |
|-----|--------|
| `PageUp` / `PageDown` | Scroll history by page |
| `Ctrl+U` / `Ctrl+D` | Scroll half page |
| `Ctrl+P` | Command palette (grouped: Connect, Suggested, Model, Session) |
| `Ctrl+T` | Model palette (providers | models, two columns) |
| `Ctrl+A` | Connect provider (key entry) |
| `/model` | Open model palette |
| `/provider` | Switch provider |
| `/use <provider> [model]` | Quick model switch |
| `/effort` | Set reasoning effort (low/medium/high) |
| `/yolo` | Disable permission prompts |
| `/goal <text>` | Set task goal (enables ceiling at 60 iterations) |
| `/plan` | Show/clear visible task list |
| `/context` | Token budget gauge + breakdown |
| `/cache` | Cache hit rate stats |
| `/bench` | Iteration/TTFT/tok/s statistics |
| `/free-auto` | Rotate through free models of all keyed providers |
| `/submodel` | Override subagent model |
| `Shift+Tab` | Toggle read-only / accept-edits mode |
| `Esc` | Cancel stream / kill foreground / decline ask |

## Configuration

Environment variables (`.env` supported via `set -a && source .env && set +a`):

| Variable | Default | Description |
|----------|---------|-------------|
| `ZODE_API_KEY` | — | Generic fallback key |
| `ZODE_PROVIDER` | `opencode` | Provider ID |
| `ZODE_MODEL` | `kimi-k2.6` | Model name |
| `ZODE_EFFORT` | `medium` | Reasoning effort (low/medium/high) |
| `ZODE_BASE_URL` | `https://opencode.ai/inference/openai/v1` | Chat endpoint base |
| `ZODE_MODELS_URL` | `https://opencode.ai/inference/v1/models` | Models endpoint |
| `ZODE_CONTEXT_LIMIT` | `131072` | Context window (tokens) |
| `ZODE_COMPACT` | `elide` | `off` | `elide` | `full` |
| `ZODE_COMPACT_PCT` | `80` | Compaction trigger % |
| `ZODE_FREE_AUTO` | `0` | Enable free-model rotation |
| `ZODE_TASK_PARALLEL` | `3` | Max parallel subagents |
| `ZODE_CHEAP_TURN` | `0` | Route calm main turns to small model |
| `ZODE_AUTO_CHECK` | `1` | Auto typecheck after edits |
| `ZODE_GOAL_MAX` | `60` | Hard iteration ceiling |

User config: `~/.config/zode/config.json` (providers, model, custom providers).  
Keys: `~/.config/zode/auth.json` (0600, written atomically).

## Architecture

```
src/
├── main.zig           # Entry, headless --chat, --models
├── tui.zig            # TUI: layout, draw, input, scroll, palettes
├── agent.zig          # Agent loop, tool execution, permissions, session
├── commands.zig       # Slash command handlers
├── tools/             # One file per tool (dispatcher in dispatch.zig)
│   ├── prompts/       # Tool schemas + descriptions (per tool)
│   ├── common.zig     # Shared helpers
│   └── validate.zig   # Schema validation tests
├── palette.zig        # Ctrl+P / Ctrl+T modal palettes
├── bgproc.zig         # Background process registry
├── session.zig        # Compressed JSONL (zjsonl) sessions
├── config.zig         # User config.json loading
├── compaction.zig     # Tier 1 (elide) + Tier 2 (summarize)
├── cache_stats.zig    # Provider-agnostic cache stats
├── roster.zig         # Free-model pool (order, caps, cooldowns)
├── free_auto.zig      # /free-auto rotation logic
└── roster_probe.zig   # `zig build roster-probe` probe

src/lib/               # Pure modules (test without TUI/network)
├── theme.zig          # Semantic colors + contrast tests
├── markdown.zig       # Markdown + unified diff rendering
├── highlight.zig      # Universal syntax highlighter
├── web.zig            # HTML→text, search parser (pure, tested)
├── http_client.zig    # HTTP JSON on std.http.Client
├── providers.zig      # Compiled providers + key precedence
├── models.zig         # Model catalogue + metadata
├── subagent.zig       # Subagent report format
├── ask.zig            # Ask tool (pure dialog logic)
├── plan.zig           # Visible task list
├── router.zig         # Cheap-turn model router
├── verify.zig         # Slow verification → background
├── skills.zig / skillstore.zig  # Skills on disk
├── mentions.zig       # @file mention scanner
├── checkpoint.zig     # /undo snapshots
├── editor.zig         # Multiline input editor
├── regex.zig          # Mini regex engine
├── zjsonl.zig         # DEFLATE+base64 per session line
└── ...
```

`src/lib/` = modules testable **without** TUI or network.  
`src/tools/` = tools split per file; dispatcher holds Model deps.  
`AGENTS.md` = code conventions + why each Zig 0.16 trap was paid for.

---

## Contributing / Public repo files

- [`CONTRIBUTING.md`](CONTRIBUTING.md) — how to contribute (Zig 0.16, pure std, tests)
- [`SECURITY.md`](SECURITY.md) — vulnerability reporting, scope
- [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md) — community conduct
- [`.github/ISSUE_TEMPLATE/bug_report.md`](.github/ISSUE_TEMPLATE/bug_report.md) — bug template
- [`.github/ISSUE_TEMPLATE/feature_request.md`](.github/ISSUE_TEMPLATE/feature_request.md) — feature template
- [`.github/pull_request_template.md`](.github/pull_request_template.md) — PR template
- [`.github/workflows/zig.yml`](.github/workflows/zig.yml) — basic CI (`zig build` + `zig build test`)

This repo is under MIT (`LICENSE`). If you open a PR, confirm `zig build test` passes and that the change respects the `pure Zig std` rule.
