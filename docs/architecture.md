# Architecture — how zode works

This document describes the internal flow: streaming, compaction, permissions, subagents, skills, MCP, and self-update. It is aimed at maintainers and anyone curious about the internals. User-facing behaviour is in `docs/usage.md`; the full settings reference is `docs/settings.md`; code conventions are in `AGENTS.md`.

## Source layout

```
src/                          # TUI, agent loop, tools, commands
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

src/lib/               # Pure modules (testable without TUI/network)
├── theme.zig          # Semantic colors + contrast tests
├── markdown.zig       # Markdown + unified diff rendering
├── highlight.zig      # Universal syntax highlighter
├── web.zig            # HTML→text, search parser (pure, tested)
├── http_client.zig    # HTTP JSON on std.http.Client
├── providers.zig      # Compiled providers + key precedence
├── models.zig         # Model catalogue + metadata
├── subagent.zig       # Subagent report format (task tool)
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

`src/lib/` = modules testable without TUI or network. `src/tools/` = tools split per file; dispatcher holds `Model` deps. `AGENTS.md` = code conventions + why each Zig 0.16 trap was paid for.

## SSE streaming is incremental

`streamPost()` delivers chunks via `response.reader`; `StreamCtx.feed()` dispatches each `data:` line as soon as it is complete. `ESC` cuts via `chat.cancel_current` (`std.atomic.Value(bool)`), and partial text is kept (`result.partial`).

## Tool calls do not get stuck

`tryEmitTool` validates JSON before emitting; `flushPendingTools()` forces emission at `finish`. Empty args become `{}`.

## Compaction is two-tier

Budget = 80 % of `ZODE_CONTEXT_LIMIT` (clamped 10–95), derived from `ZODE_CONTEXT_LIMIT` > the model's own window > 128000 fallback.

1. **Elide** (`elide`, `full`): old tool results >256 B outside `recent_window=8` become a marker. No request, no tokens; the session file keeps the original. Tier 1 tracks running estimates so long history is scanned once.
2. **Summarize** (`full` only): one LLM call with `summaryPrompt()` capped at 16 KB replaces old turns with `[earlier conversation summarized...]`.

`off` does neither; the provider eventually rejects an over-long request.

## Session file format is zjsonl

Append-only JSONL in `./sessions/zode-<id>.jsonl`. Lines ≥512 bytes are compressed with raw DEFLATE level 9 and base64-encoded (`z` prefix marker). Round-trip is tested byte-for-byte. `File.Writer` uses `Writer.initStreaming`; positional mode creates 0xFF holes.

Compressed session architecture: session create/resume returns heap `*Session`; the `File.Writer` references `write_buf` inside the struct — never move by value.

## Permission flow

`model.requestPermission()` blocks the worker thread (spin + yield) until the UI answers. Priority:

1. `/yolo` (global bypass) — asks nothing.
2. persisted allowlist (`~/.config/zode/permissions.json`, `0600`).
3. dialog.

Denied answers feed back as `tool_result "denied: permission required"`. `lsp` asks NO permission (spawns from a fixed table, never model). `batch` asks the union of step permissions.

Path-scoped rules (`Tool(pattern)`): loaded once from `local` > `project` (`.zode/permissions.json`) > `user` > `policy`; `deny` beats any `allow`; within one source, last match wins. Resolver is pure Zig (`readLink`), not `realpath(3)`; checks the resolved path, not the written path (symlink hole fixed).

## Subagent (`task`)

Depth 1, effort `low` always, 24 k budget, only read tools, does not see the conversation. Parallel capped at `ZODE_TASK_PARALLEL` (default 3) by waves; `mirror_globals` prevents module-global stomping (`last_usage`, `cancel_current`, etc.).

## Free-auto (`/free-auto`)

Rotates between free models of providers with a key; quotas cause rotation. `quotaVerdict` distinguishes gate 403 vs account 403 vs 401/404/5xx. Filter by `models.isConversational(id)` (embeddings/images/audio excluded).

## Skills

`.zode/skills/<name>/SKILL.md` (project) and `~/.config/zode/skills/<name>/SKILL.md` (personal), with `name` + `description` frontmatter. Only name + description enter the prompt (budget = 1 % of `ZODE_CONTEXT_LIMIT`). Project overrides global; no merge.

## MCP

A server is a **program**; schemas live in the manager catalogue, not in the request `tools` array (cache-prefix protection). The `mcp` tool has `search`, `list`, `call`. Server config is user-level (`~/.config/zode/config.json` `mcp_servers`), not from `.mcp.json` (remote-code-execution risk). Read-only schema composed from `registry.blob` at comptime; `lsp` permission fixed to `read_only = true`.

## Self-update

Cache in `~/.cache/zode/update.json` (6 h TTL, one file, respects `XDG_CACHE_HOME`). The check notifies; `/update` verifies the binary (`--version`) before replacing, refuses to go backwards, writes `{exe}.new`, then atomic rename over.

## Verification workflow

- `zig build test` — the primary gate (800+ tests). Tests read `AGENTS.md` for routing rules (`systemPromptBase` + `tool_routing_prompt` must stay separate) and for banner content (only ASCII wordmark, nothing else below art).
- `tools/pty_smoke.py` — real pty (`TIOCSWINSZ` at 200×50, own `HOME`, drains pty). Checks: startup, banner, input, palette, scroll, `!cmd`, long prompt preserved, no panic, no `Invalid free`.
- `zig build ui-frame` — design harness: renders scenes with real `drawFn` + `Model`. Finds layout bugs unit tests miss.
- `zig build debug` — must produce a symbolized binary (`.symtab`, `.debug_info`, `nm` lists symbols).
- `zig build roster-probe` — verifies the free model pool before rotation.
