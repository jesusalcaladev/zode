# zode — AGENTS.md

A code harness in pure Zig (no C deps), focused on speed and saving tokens.

## How we work

- **Pure Zig std** — no C dependencies, no mandatory libc (musl target possible). Only external dep: libvaxis (pure Zig).
- **Token saving by design**: the context is the expensive resource. Anything that goes into the LLM has to earn its place.
- **Radical simplicity**: prefer direct, readable code over premature abstraction.
- **All visible text in English**: UI, system prompts, code comments, test names, and assertions. No Spanish or other languages in source — only identifiers, protocol names, paths, tool names, and ASCII art are exempt. Check: both language greps come out empty.
- **No TODOs** in code — `AGENTS.md` forbids them; a placeholder is a decision deferred.
- **Every file that touches the model has a test** — pure modules (`src/lib/`) are testable without TUI or network; TUI-heavy code uses `drawTest` + `tools/pty_smoke.py`. A feature without a passing test is not done.

## Zig 0.16 — traps worth remembering

- `main` receives `std.process.Init` (`init.gpa`, `init.io`, `init.environ_map`, `init.arena`, `init.minimal.args`).
- Args: `std.process.Args.Iterator.init(init.minimal.args)` + `.next()`.
- Env: `init.environ_map.get("KEY")` (NOT `std.posix.getenv`).
- Mutex: `std.atomic.Mutex` (`tryLock`/`unlock`); long locks with yield: `while (!m.tryLock()) std.Thread.yield() catch {}`.
- HTTP: `client.request()` → `sendBodyComplete(body)` / `sendBodiless()` → `receiveHead` → `response.reader` (buffer ≥16KB for streaming) → `allocRemaining()`.
- `sendBodyComplete` wants mutable `[]u8` — build JSON in stack buffers, pass with `@constCast`.
- Compression: ask for `.headers = .{ .accept_encoding = .omit }`; std HTTP does not decompress transparently.
- JSON: `std.json.parseFromSliceLeaky(std.json.Value, arena, ...)` with a per-request arena.
- Writers: `var w: std.Io.Writer = .fixed(buf)`; headless output via `std.Io.File.stdout().writer(io, &buf)` + `.interface.print(...)` + `flush()`.
- vaxis 0.6: `App.init(io, gpa, environ_map, tty_buffer)`; widgets with `userdata/eventHandler/drawFn`; `Surface.children` is a slice (assign, do not append); `Cell` is a struct with `.default`.
- Time: `std.time.timestamp()` does NOT exist. Use `std.Io.Timestamp.now(io, .real).toSeconds()`.
- Child.Term: lowercase tags (`.exited`, `.signal`); `signal` is `std.posix.SIG` → `@intFromEnum` + truncate to u8.
- Dirs: no `makePath`; use `dir.createDirPath(io, path)`. To iterate: `openDir(io, path, .{ .iterate = true })` — without flag, iterating is illegal (EBADF panic in debug).
- File.Writer: `file.writer(io, &buf)` returns a struct with stable `.interface: *Writer`; keep the whole struct.
- Process run: `std.process.run(gpa, io, .{ .argv, .stdout_limit, .stderr_limit, .timeout })` → `RunResult{ .term, .stdout, .stderr }`.
- No `std.regex`; use `src/lib/regex.zig`.
- Writing directly: `dir.writeFile(io, .{ .sub_path, .data })`.
- `grep`: native `rg` → native `grep -rn` → our regex fallback (in that order). Respects `.gitignore` via `rg`.
- **Graphemes never with `&[_]u8{c}`**: `vxfw.Surface.writeCell` stores `Cell` by value, but vaxis reads the BYTES after `drawFn` returns. A pointer to a stack temporary reaches the renderer as garbage (NULs). ALWAYS use `Painter.putText` (copies into frame arena) or `putStable`. Tests in `tui.zig` cover it.
- `ArrayList.clearRetainingCapacity` does `@memset(items, undefined)` — consume the line BEFORE clearing.
- `std.ArrayList` is UNMANAGED: `append(gpa, item)`, `insertSlice(gpa, i, s)`, `replaceRange(gpa, start, len, s)`.

## Commands

```bash
zig build                        # debug
zig build -Doptimize=ReleaseSafe # release (~8.5MB, 1.6MB stripped)
zig test src/chat.zig            # SSE parser tests
./zig-out/bin/zode --models      # list models (headless, no TTY needed)
./zig-out/bin/zode --chat "txt"  # headless streaming chat
./zig-out/bin/zode               # TUI
```

## Config (env) — load with `set -a && source .env && set +a` (`.env` is gitignored)

- `ZODE_BASE_URL` (default: `https://opencode.ai/inference/openai/v1`)
- `ZODE_MODELS_URL` (default: `https://opencode.ai/inference/v1/models`)
- `ZODE_API_KEY`
- `ZODE_MODEL` (default: `kimi-k2.6`), `ZODE_EFFORT` (low|medium|high)
- `ZODE_MAX_TOOL_OUTPUT` (default 10 MB, hard cap 100 MB)
- `ZODE_CONTEXT_LIMIT` (default 128k; budget = 80%)
- `ZODE_FREE_AUTO=1` / `ZODE_TASK_PARALLEL` (default 3) / `ZODE_MAX_ITER` (default 12)
- `ZODE_COMPACT=off|elide|full`, `ZODE_COMPACT_PCT=10..95`
- `ZODE_YES=1` (autoconfirm destructive commands)
- `ZODE_RESUME=1` / `ZODE_DBG_ERR=1`

## Architecture map

```
src/     main, tui, agent, tools (dispatcher), chat, bgproc, palette,
         session, config, compaction, cache_stats, roster, free_auto
src/lib/ pure/testable modules (no TUI, no network): readcache, project,
         prompt, sleep, skills, skillstore, mentions, markdown, highlight,
         web, models, providers, provider, http_client, subagent, ask,
         plan, checkpoint, editor, bench, clean, regex, mascot, theme,
         zjsonl, verify, exitgate, cost, review, diffview
```

`src/lib/` describes **how it is tested**, not what it does. Moving modules together does not change internal imports (paths are relative to the file).

## Mascot: Zo

- `mascot.zig`: one-line face per mood (idle/thinking/tooling/done/warn).
- Startup banner: ONLY the `ZODE` wordmark (5 lines of plain ASCII, no mascot, no greeting, no shortcuts line — Houston/Astro Boy tried and rejected for filling the view).
- Status row is composed as `[]InfoSeg`: face with `Mood.vaxisColor()` bold, text in `brand_soft`, spinner separately. `Mood.color()` is now actually used.
- The face is in the bottom status line, not inside the input well.

## Key design decisions (durable — do not undo without a test)

- **SSE streaming is really incremental**: `streamPost()` delivers chunks via `response.reader`; `StreamCtx.feed()` dispatches each `data:` line as soon as complete. ESC cuts via `chat.cancel_current` (`std.atomic.Value(bool)`), and partial text is kept (`result.partial`).
- **Tool calls do not get stuck**: `tryEmitTool` validates JSON; `flushPendingTools()` forces emission at `finish`. Empty args = `{}`.
- **Compaction is 2-tier**: Tier 1 (`elideTier`) replaces old tool results (>256B, outside `recent_window=8`) with a marker; Tier 2 (`summarizeTurns`) makes one LLM call with `summaryPrompt()` capped at 16 KB, replacing old turns with `[earlier conversation summarized...]`. Budget = 80% of `ZODE_CONTEXT_LIMIT`. Tier 1 tracks running estimates so long history is scanned once.
- **Session file format is zjsonl**: append-only JSONL in `./sessions/zode-<id>.jsonl`; lines ≥512 bytes compressed with raw DEFLATE level 9 (`z` prefix + base64). Round-trip tested byte-for-byte. `File.Writer` uses `Writer.initStreaming`; positional mode creates 0xFF holes.
- **Compressed session architecture**: session create/resume returns heap `*Session`; the File.Writer references `write_buf` inside the struct — never move by value.
- **Permission flow**: `model.requestPermission()` blocks worker thread (spin + yield) until UI answers. Priority: `/yolo` (global) > persisted allowlist (`~/.config/zode/permissions.json`, 0600) > dialog. Denied answers feed back as `tool_result "denied: permission required"`. `lsp` asks NO permission (spawns from fixed table, never model). `batch` asks union of step permissions.
- **Verifications (what the harness actually checks)**: `zig build` (types/syntax) is the floor; model's own `check` / `bash` covers upper rungs (`npm test`, `pytest`, `cargo test`, etc.). `proofWord` maps to `typechecked / syntax-checked / tested / not checked` — never "verified" for a typecheck alone. The exit gate (`AutoCheck.exitGate`) runs at the TOP of each iteration, before `again orelse break`, refusing to end on red (`refused_failed`), stale green (`refused_unverified`), or unverified writes.
- **Subagent (`task`)**: depth 1, effort `low` always, 24k budget, only read tools, does not see conversation. Parallel capped at `ZODE_TASK_PARALLEL` (default 3) by waves; `mirror_globals` prevents module-global stomping (`last_usage`, `cancel_current`, etc.).
- **Free-auto (`/free-auto`)**: rotates between free models of providers with a key; quotas cause rotation (`quotaVerdict` distinguishes gate 403 vs account 403 vs 401/404/5xx). Filter by `models.isConversational(id)` (embeddings/images/audio excluded).
- **Skills**: `.zode/skills/<name>/SKILL.md` (project) and `~/.config/zode/skills/<name>/SKILL.md` (personal), with `name` + `description` frontmatter. Only name + description enter prompt (budget = 1% of `ZODE_CONTEXT_LIMIT`). Project overrides global; no merge.
- **Notebooks**: `read` returns numbered outline (index, type, size, first line); `notebook_edit` by index. Round trip preserves outputs, execution counts, cell ids, metadata. Malformed file refused with parse line/column.
- **MCP**: server is a PROGRAM; schemas live in manager catalogue, NOT in request `tools` array (cache prefix protection). `mcp` tool has `search`, `list`, `call`. Server config is user-level (`~/.config/zode/config.json` `mcp_servers`), not from `.mcp.json` (remote code execution risk). Read-only schema composed from `registry.blob` at comptime; `lsp` permission fixed to `read_only = true`.
- **Path-scoped rules (`Tool(pattern)`)**: rules loaded once from `local` > `project` (`.zode/permissions.json`) > `user` > `policy`; `deny` beats any `allow`; within one source, last match wins. Resolver is pure Zig (`readLink`), not `realpath(3)`; checks resolved path, not written path (symlink hole fixed).
- **Self-update**: cache in `~/.cache/zode/update.json` (6h TTL, one file, respects `XDG_CACHE_HOME`). Check notifies; `/update` verifies binary (`--version`) before replacing; refuses to go backwards; writes `{exe}.new`, atomic rename over.

## Verification workflow

- `zig build test` — the primary gate. Tests read `AGENTS.md` for routing rules (`systemPromptBase` + `tool_routing_prompt` must stay separate) and for banner content (only ASCII wordmark, nothing else below art).
- `tools/pty_smoke.py` — real pty (`TIOCSWINSZ` at 200x50, own `HOME`, drains pty). Checks: startup, banner, input, palette, scroll, `!cmd`, long prompt preserved, no panic, no `Invalid free`.
- `zig build ui-frame` — design harness: renders scenes with real `drawFn` + `Model` (public API only: `pushToolStart`, `streamStart`, `requestAsk`, etc.). Finds layout bugs (e.g., cache unsorted → banner painted in middle of transcript) that unit tests miss.
- `zig build debug` — must produce symbolized binary (`.symtab`, `.debug_info`, `nm` lists symbols). A broken `debug` step is worse than none — the description IS the interface.
- `zig build roster-probe` — verifies free model pool before rotation.

## Key conventions to preserve

- **Markdown parser**: banner (`kind == .banner`) is a drawing, not prose — `parseBase` skips heading parsing there. `*…*` and `~…~` are style markers removed from text (used for tool names / mood colors); unpaired markers are normal text.
- **Diff rendering**: word-level colors (row = band, words = point); gutter width per hunk; wrapped rows skip gutter; color ladder picks closer RGB candidate (not only grey ramp); `NO_COLOR` / `COLORTERM` / `TERM` respected; with no color diff is still readable (bold markers + bold changed words).
- **Edit hint**: tokenizes by space (operators are words in code); Jaccard nearest line; three distinct messages (wrong spaces, wrong place, never existed); threshold 0.50; verbatim + spaces compare exact line including indent.
- **History painting**: `fillRange` clears before painting; separation row is an empty `PLine` added to array (not just height); goes BEFORE paragraph; render tests search by content (`findRow` / `hasBlankRowBetween`), not fixed row numbers.
- **Scroll anchor**: `(paragraph, offset)`, not absolute line; derived from current heights; only re-derived when out of space.

## What this file is NOT

- A bug chronicle. Dated debugging notes, fuzzing rounds, SIGSEGV post-mortems, release build fixes, and per-feature essays belong in `ROADMAP.md` or commit messages, not here.
- A feature spec for anything unbuilt. Unbuilt items (selective permissions fully wired, `@file` with per-range budget) stay in task tracking, not in this document.
- A substitute for tests. If a rule is important, it has a test that fails when removed.
