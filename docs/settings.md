# Settings and token budgets

Everything zode can be told to do lives in one of two places: **environment
variables** (this shell, or a `.env` file) and the **config directory**
(`~/.config/zode/`). Nothing needs a rebuild, and nothing is hidden in the
binary.

Load a `.env` without exporting every line by hand:

```bash
set -a && source .env && set +a
```

---

## Where settings live

| What | Where | Notes |
|---|---|---|
| Per-session switches | environment | Beats `config.json` for the fields they name (see each section) |
| Provider, model, subagents, custom endpoints, LSP, MCP | `~/.config/zode/config.json` | Versionable: it holds no secrets |
| API keys | `~/.config/zode/auth.json` | `0600`, written atomically by `/connect`; never in `config.json` |
| Permission allowlist and rules | `~/.config/zode/permissions.json`, `.zode/permissions.json` | User rules + project rules |
| Sessions | `./sessions/zode-<id>.jsonl` | Compressed JSONL, `drwx------` / `-rw-------` |
| Skills | `.zode/skills/<name>/SKILL.md`, `.agents/skills/…`, `~/.config/zode/skills/…` | Project first, no merge |
| Slash commands | `.zode/commands`, `~/.config/zode/commands` | Markdown files |
| Output styles | `.zode/output-styles`, `~/.config/zode/output-styles` | Selected with `/style` |

---

## 1. Provider

The provider is picked in this order:

1. `provider` in `~/.config/zode/config.json`
2. `ZODE_PROVIDER`
3. `opencode` (the default, free tier)

Compiled providers and the environment variable that holds each key:

| `ZODE_PROVIDER` | Key variable(s) | Notes |
|---|---|---|
| `opencode` | `ZODE_OPENCODE_KEY`, `ZODE_API_KEY` | Default; free tier |
| `openrouter` | `ZODE_OPENROUTER_KEY` | Big catalogue, context window and prices per model |
| `anthropic` | `ZODE_ANTHROPIC_KEY` | Native Messages API with prompt caching |
| `openai` | `ZODE_OPENAI_KEY`, `ZODE_API_KEY` | `max_completion_tokens` + `reasoning_effort` |
| `groq` | `ZODE_GROQ_KEY` | Very low latency |
| `deepseek` | `ZODE_DEEPSEEK_KEY` | Cheap reasoning |
| `mistral` | `ZODE_MISTRAL_KEY` | |
| `command-code` | `ZODE_COMMAND_CODE_KEY` | |
| `github-copilot` | `ZODE_GITHUB_COPILOT_KEY` | |
| `xai` | `ZODE_XAI_KEY` | Grok models |
| `zai` | `ZODE_ZAI_KEY`, `ZAI_API_KEY` | GLM, no `/models` endpoint (documented ids only) |
| `zai-coding` | `ZODE_ZAI_CODING_KEY` | Subscription key, **not** the API key |
| `nvidia` | `ZODE_NVIDIA_KEY`, `NVIDIA_API_KEY` | Hosted NIM; output capped at 16k |
| `local` | *(no key)* | Ollama / LM Studio on `localhost:11434` |

Anything else is a provider you defined in `config.json` (see §8).

Point zode at an OpenAI-compatible endpoint without touching the config file:

```bash
export ZODE_BASE_URL="https://my-gateway/v1"
export ZODE_MODELS_URL="https://my-gateway/v1/models"
export ZODE_API_KEY="sk-..."
```

`ZODE_BASE_URL` / `ZODE_MODELS_URL` are also overridable per provider in
`config.json` with `base_url` / `models_url`.

## 2. Keys

A key is looked up in this order:

1. **`~/.config/zode/auth.json`** — what you typed in `/connect` (`ctrl+a`, or
   the `+ connect` row of the model palette). It is `0600` and it wins, so
   connecting from the TUI is never silently overruled by an old `.env`.
2. **The provider's own variables**, in the order shown in the table above.
3. **`ZODE_API_KEY`** — the generic fallback.

`auth.json` is a flat map of provider id → key:

```json
{ "openrouter": "sk-or-...", "groq": "gsk_..." }
```

A provider with `key_env: []` (like `local`) needs no key and never asks for
one.

## 3. Model and effort

Model precedence:

1. `ZODE_MODEL`
2. `model` in `config.json`
3. the provider's `default_model` (only when the provider ships one)
4. the first free model in the provider's catalogue — zode asks rather than
   guessing a name that may have been retired

`/model` (or `ctrl+t`) opens the picker. It lists every model of every
connected provider, with its context window and whether it is free; the
keyboard (`↑↓`, `tab`, `enter`), the mouse (move to highlight, click to
choose) and the wheel (scroll) all work. Picking a model also adopts **its**
context window for the token budget (§4), unless `ZODE_CONTEXT_LIMIT` says
otherwise.

`ZODE_EFFORT` = `none | minimal | low | medium | high | xhigh | max`
(default `medium`), also `/effort`. It selects the reasoning rung the model
understands and, with it, the output ceiling (§5).

## 4. The token budget

Four numbers decide when the conversation gets compacted. They are separate on
purpose — "the model has 200k" is not the same statement as "keep the request
under 160k".

| Knob | Default | Meaning |
|---|---|---|
| `ZODE_CONTEXT_LIMIT` | *(unset)* | Overrides the context window. When set it **always** wins, because it exists for the case where the catalogue is wrong (a gateway that truncates, a plan with a smaller window). |
| model's own window | from the catalogue | Used when `ZODE_CONTEXT_LIMIT` is not set. The palette shows it (`free · 200k`), and choosing a model adopts it. |
| fallback window | `128000` | Used when neither of the above says anything. |
| `ZODE_COMPACT_PCT` | `80` | The **budget**: this percentage of the window. Clamped to `10..95`. |
| `ZODE_COMPACT` | `full` | What compaction may do: `off`, `elide`, `full` (§ below). |
| `ZODE_RECENT_WINDOW` | `8` | Messages kept verbatim. Clamped to `2..200`. Counts **messages**, so one tool round can be several of them. |

The two tiers, applied until the request is under budget:

1. **Elide** (`elide`, `full`): old tool results over 256 bytes, outside the
   recent window, are replaced by a marker. No request, no tokens, and the
   session file keeps the original.
2. **Summarize** (`full` only): the oldest turns are replaced by one summary,
   produced by a single extra model call capped at 16 KB.

`off` does neither, and the provider will eventually reject the request for
being too long. That is a valid choice while watching a request, not a good
default.

`/context` prints the numbers and **where each one came from**:

```
context [████████░░░░░░░░░░░░] ~41100 / 200000 tokens (20.6% of limit)
  system ~9800 · history ~31300 · 14 turns · budget 160000 (26% used)
  limit from: the model's own context window · elided this session: 3 tool results
  compaction: full at 80% of the limit (ZODE_COMPACT)
```

`/compact [off|elide|full]` overrides `ZODE_COMPACT` for the session;
`/compact default` returns to the environment.

## 5. Output tokens

The provider is asked for a hard ceiling per request, never a length target:

| `ZODE_EFFORT` | Ceiling | Thinking budget (Anthropic) |
|---|---|---|
| `none`, `minimal` | 16 384 | 0 / 1 024 |
| `low`, `medium` | 32 768 | 4 096 / 8 192 |
| `high`, `xhigh`, `max` | 65 536 | 16 384 / 24 576 |

Two things can lower it, and neither can raise it:

- the provider's own `max_output_tokens` (NVIDIA NIM documents per-model
  maxima as low as 4 096);
- `ZODE_MAX_OUTPUT_TOKENS` — your ceiling, for an account with a tighter
  limit than the provider publishes.

The smallest of the three wins.

## 6. Tool output and stored results

| Variable | Default | Meaning |
|---|---|---|
| `ZODE_MAX_TOOL_OUTPUT` | `1M` | Byte cap for one tool's output. Bare numbers and `K` / `M` / `G`. Hard-capped at `10M`. |
| `ZODE_MAX_RESULT_CHARS` | `50000` | Above this, a result is written to `sessions/<id>/tool-results/` and the model gets a preview plus the path. |
| `ZODE_MAX_RESULT_BYTES` | `400000` | How much of an oversized result is stored on disk. |
| `ZODE_MAX_RESULTS_PER_MESSAGE_CHARS` | `200000` | Total result text allowed in one message. |
| `ZODE_SUMMARY_MAX_LEN` | `50` | Length of the per-result summary line shown to the model. |

Lowering `ZODE_MAX_TOOL_OUTPUT` is the cheapest way to cut tokens on a noisy
project: a `grep` that dumps 4 MB is the bulk of the next request.

## 7. Iterations and subagents

| Variable | Default | Meaning |
|---|---|---|
| `ZODE_MAX_ITER` | `12` | Tool/answer iterations per turn. Clamped to `4..200`. `/bench` reports the percentage of turns that hit it — 0% means it could be lowered, 30% means real tasks are being cut. |
| `ZODE_GOAL_MAX` | `max(ZODE_MAX_ITER * 3, 60)` | The hard ceiling a `/goal` turn may reach. |
| `ZODE_TASK_PARALLEL` | `3` | Subagent requests in flight at once. `/task-parallel [1..8|auto]` overrides it for the session. |

Subagents run at effort `low` on a throwaway 24k window. Where they run is set
by `/submodel`, then `subagent_provider` / `subagent_model` in `config.json`,
then `ZODE_SUBAGENT_PROVIDER` / `ZODE_SUBAGENT_MODEL`. Nothing set means they
follow the main turn.

## 8. `config.json`

Everything is optional; an empty `{}` is valid.

```json
{
  "provider": "my-vllm",
  "model": "qwen3-coder",
  "subagent_provider": "groq",
  "subagent_model": "llama-3.3-70b-versatile",

  "providers": [
    {
      "id": "my-vllm",
      "name": "vLLM local",
      "base_url": "http://localhost:8000/v1",
      "models_url": "http://localhost:8000/v1/models",
      "key_env": "MY_VLLM_KEY",
      "default_model": "qwen3-coder",
      "max_output_tokens": 16384,
      "preferred_models": ["qwen3-coder", "qwen3-32b"],
      "kind": "openai"
    }
  ],

  "lsp_servers": [
    {
      "name": "my-zls",
      "language_id": "zig",
      "command": ["my-lsp", "--stdio"],
      "extensions": [".zig", ".zon"]
    }
  ],

  "mcp_servers": [
    {
      "name": "github",
      "command": ["npx", "-y", "server-github"],
      "env": { "GITHUB_TOKEN": "..." }
    }
  ]
}
```

Notes that save an afternoon:

- `id` must not collide with a compiled provider — those win.
- `base_url` is mandatory; a provider without it is skipped, not fatal.
- `kind: "anthropic"` switches that provider to the Messages API (and to the
  `x-api-key` header for its catalogue).
- `key_env` accepts a string or an array of strings, tried in order.
- `mcp_servers` is **user-level only**. A server is a program: a project that
  could choose one would be remote code execution with your credentials.
- A malformed entry is skipped, never fatal: one bad row must not take the
  working provider down with it.

## 9. Permissions

Two files, same rule format:

- `.zode/permissions.json` — project rules (travels with the repo)
- `~/.config/zode/permissions.json` — your rules

```json
{
  "rules": [
    "Write(.vscode/**) deny",
    "Bash(npm test) allow",
    { "tool": "Bash", "pattern": "git push*", "action": "ask" }
  ]
}
```

Grammar: `Tool(pattern) action`, where the pattern is a glob over the path (file
tools) or the command (`bash`), `*` also matches `/`, and the action is
`allow` (the default), `deny` or `ask`.

Precedence: `local` (this session) > `project` > `user` > `policy` (built-in).
A `deny` beats any `allow` from any source; within one file the last match
wins. Permission modes (`shift+tab`, `/mode`) sit above all of it: `bypass`
(`/yolo`) asks nothing, `plan` refuses every write.

The user file also carries the ANSWERS from the permission dialog, which is a
separate mechanism (`/allowlist` lists them):

```json
{ "tools": ["write", "bash"], "bash": ["git status", "npm test"], "rules": [] }
```

A bare JSON array is read as the old `tools` list. The `bash` entries are
command PREFIXES, so `rm -rf /` never rides on a `git status` allowance.
`/permissions` prints the rules in force and which file each one came from.

## 10. Sessions

Sessions are append-only JSONL in `./sessions/zode-<id>.jsonl`; lines of 512
bytes or more are DEFLATE-compressed (level 9) and base64-encoded. Compaction
never touches them: what the wire drops, the file keeps.

| Variable | Meaning |
|---|---|
| `ZODE_SESSIONS_DIR` | Put sessions somewhere else (absolute path) |
| `ZODE_RESUME=1` | Resume the most recent session at startup (`--resume` does the same) |

## 11. Automation and diagnostics

| Variable | Default | Meaning |
|---|---|---|
| `ZODE_AUTO_CHECK` | `1` | Typecheck after edits (`check` tool) |
| `ZODE_AUTO_BG` | `1` | Move known-slow verifications to the background |
| `ZODE_YES` | `0` | Autoconfirm destructive commands (the TUI answer, not `/yolo`) |
| `ZODE_FREE_AUTO` | `0` | Start in free-model rotation (`/free-auto`) |
| `ZODE_CHEAP_TURN` | `0` | Route calm main turns to a small model |
| `ZODE_CHEAP_MODEL` | provider default | Which model that router uses |
| `ZODE_WEB_ALLOW_LOCAL` | `0` | Let `web_fetch` reach loopback and private ranges |
| `ZODE_BRAVE_KEY` | *(unset)* | Real search index for `web_search` instead of the free chain |
| `ZODE_NO_SELF_UPDATE` | `0` | Disable the update check |
| `ZODE_AUTO_UPDATE` | `0` | Install updates without asking |
| `ZODE_DALTONIZED` | `0` | Colour-blind-safe theme |
| `ZODE_LSP_TIMEOUT_MS` | built-in | LSP request timeout |
| `ZODE_DBG_ERR` | `0` | Verbose error output |

To check that what you set is what is being used:

| Command | Answers |
|---|---|
| `/context` | Window, budget, source of the limit, compaction mode |
| `/cache` | Prompt-cache hit rate, with evidence |
| `/cost` | What this session has cost, per model |
| `/bench` | Iterations, TTFT, tokens/s, how often the limit was hit |
| `/providers` | Which providers have a key, which is active |
| `zode --models` | The catalogue of the active provider, headless |
| `zode --version` | The build you are running |
