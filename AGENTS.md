# zode — AGENTS.md

A code harness in pure Zig (no C deps), in the style of Claude Code, focused on
speed and on saving tokens.

## Project principles

1. **Pure Zig std** — no C dependencies, no mandatory libc (a musl target is
   possible). Only external dep: libvaxis (pure Zig).
2. **Token saving by design**: the context is the expensive resource. Anything
   that goes into the LLM has to earn its place.
3. **Radical simplicity**: prefer direct, readable code over premature
   abstraction.

## Zig 0.16 — known traps

- **`main` receives `std.process.Init`**: `init.gpa`, `init.io`,
  `init.environ_map`, `init.arena`, `init.minimal.args`.
- **Args**: `std.process.Args.Iterator.init(init.minimal.args)` + `.next()`.
- **Env**: `init.environ_map.get("KEY")` (NOT `std.posix.getenv`).
- **Mutex**: `std.atomic.Mutex` (spinlock `tryLock`/`unlock`); `std.Thread.Mutex`
  does not exist any more. For long locks with yield: `while (!m.tryLock())
  std.Thread.yield() catch {}`.
- **HTTP client**: the flow is `client.request()` → `sendBodyComplete(body)` /
  `sendBodiless()` → `receiveHead(&redirect_buf)` → `response.reader(&transfer_buf)`
  (buffer ≥16KB for streaming) → `allocRemaining()`.
- **`sendBodyComplete` wants a mutable `[]u8`** — JSON bodies are built in stack
  buffers and passed with `@constCast`.
- **Compression**: ask for `.headers = .{ .accept_encoding = .omit }` — std HTTP
  does not decompress transparently.
- **JSON**: `std.json.parseFromSliceLeaky(std.json.Value, arena, ...)` with a
  per-request arena.
- **Writers**: `var w: std.Io.Writer = .fixed(buf)`; `std.io.fixedBufferStream`
  does not exist any more. Headless output: `std.Io.File.stdout().writer(io, &buf)`
  + `.interface.print(...)` + `flush()`.
- **vaxis 0.6**: `App.init(io, gpa, environ_map, tty_buffer)`; vxfw widgets with
  `userdata/eventHandler/drawFn`; `Surface.children` is a slice (assign, do not
  append); `Cell` is a struct with `.default`, not a union.
- **Time**: `std.time.timestamp()` does NOT exist. Use
  `std.Io.Timestamp.now(io, .real).toSeconds()`. Durations:
  `Io.Duration.fromSeconds(x)`; process `Timeout`s want
  `Clock.Duration` = `.{ .raw = .fromSeconds(n), .clock = .awake }` (`.awake`,
  not `.monotonic`).
- **Child.Term**: lowercase tags (`.exited`, `.signal`); `signal` is an enum
  `std.posix.SIG` → `@intFromEnum` + truncate to u8.
- **Dirs**: there is NO `makePath`; use `dir.createDirPath(io, path)` (mkdir -p).
  To iterate a dir: `openDir(io, path, .{ .iterate = true })` — without the flag,
  iterating is Illegal Behavior (EBADF panic in debug). `dir.iterate()` returns an
  `Iterator` that carries its own buffer; `Iterator.next(io)`.
- **File.Writer**: `file.writer(io, &buf)` returns a struct with a stable
  `.interface: *Writer`; keep the whole struct, not the pointer.
- **process.run**: `std.process.run(gpa, io, .{ .argv, .stdout_limit,
  .stderr_limit, .timeout })` → `RunResult{ .term, .stdout, .stderr }`. There is
  no `std.regex` (there is a small engine of our own in `src/lib/regex.zig`).
- **Writing files directly**: `dir.writeFile(io, .{ .sub_path, .data })` to
  create/overwrite the whole thing.
- **grep tool**: native `rg` → native `grep -rn` → our own regex fallback (in that
  order). It respects .gitignore via rg.
- **graphemes NEVER with `&[_]u8{c}`**: `vxfw.Surface.writeCell` stores the
  `Cell` BY VALUE, but vaxis reads the BYTES of `char.grapheme` in
  `Vaxis.render()`, that is AFTER `drawFn` has returned. A pointer to a stack
  temporary reaches the renderer as garbage (NULs) → blank screen except for the
  literals. ALWAYS use `Painter.putText` (copies into the frame's arena) or
  `putStable` (a literal/arena of the paragraph's own). Tests in `tui.zig` cover
  it.
- **`ArrayList.clearRetainingCapacity` does `@memset(items, undefined)`**: you
  cannot keep a slice of `items` and then clear. Consume the line BEFORE
  clearing (see `StreamCtx.feed`).
- **`std.ArrayList` in Zig 0.16 is UNMANAGED**: `append(gpa, item)`,
  `insertSlice(gpa, i, s)`, `replaceRange(gpa, start, len, s)`.

## Commands

```bash
zig build                        # debug
zig build -Doptimize=ReleaseSafe # release (binary ~8.5MB, 1.6MB stripped)
zig test src/chat.zig            # tests of the SSE parser
./zig-out/bin/zode --models      # list models (headless, to try without a TTY)
./zig-out/bin/zode --chat "txt"  # headless streaming chat
./zig-out/bin/zode               # TUI
```

## Config (env)

- `ZODE_BASE_URL` (default: `https://opencode.ai/inference/openai/v1`)
- `ZODE_MODELS_URL` (default: `https://opencode.ai/inference/v1/models`)
- `ZODE_API_KEY`
- `ZODE_MODEL` (default: `kimi-k2.6`), `ZODE_EFFORT` (low|medium|high)
- Load with `set -a && source .env && set +a` (`.env` is gitignored)

## State and roadmap

**Done**: pure std HTTP/TLS verified against the real API; multi-provider models
(opencode/openrouter/anthropic/openai/groq/deepseek/local); **real incremental
SSE streaming** (socket chunks → `StreamCtx.feed` → events immediately, with ESC
cutting the connection); chat with fragmented tool_calls (OpenAI and Anthropic);
2-tier compaction; JSONL sessions with zjsonl; agent loop with 8 tools;
permissions with a persisted allowlist; TUI with markdown+syntax highlighting,
scroll, spinner, tok/s, modal pickers; universal highlighter; **89 tests**; 10MB
binary (1.9MB stripped).

**Next (suggested order)**:
1. Skills (loadable instruction directories).
2. MCP over stdio.
3. A real E2E against Anthropic with your own key (the wire format is already unit
   tested; OpenRouter serves Claude through OpenAI-compat).

## Mascot: Zo

- `mascot.zig`: Zo. A one-line face per mood (idle/thinking/tooling/done/warn) in
  the status bar and in the activity strip. The startup banner is ONLY the `ZODE`
  wordmark: an 18-row mascot was tried (Houston, Astro Boy) and rejected for
  filling the view.
- The agent uses it via `setStatusWithZo(m, .mood, "text")`.

## Cache stats (provider-agnostic)

- `chat.Usage` normalizes OpenAI (`prompt_tokens_details.cached_tokens`) and
  Anthropic (`cache_read_input_tokens`); it arrives over SSE with
  `stream_options:{include_usage:true}`.
- `cache_stats.zig` accumulates per session: `hitRatePct()`, requests with a hit,
  prompt/cached/completion tokens.
- `/cache` in the TUI shows it. The headless agent prints `[cache] X% hit-rate` at
  the end.
- Note: OpenRouter's free models do not report cache; the metric shines with
  Anthropic/DeepSeek/OpenAI.

## Current tools (10)

read, write, edit (multi-hunk), bash, glob, grep (native rg), list_files (a cheap
flat listing), **web_fetch**, **web_search**, think (a scratchpad with no effects,
for planning). They do not ask for permission: read, glob, grep, list_files,
think, web_fetch, web_search.

## The web tools: `web_fetch` and `web_search`

- `web_fetch {url, max_bytes?}`: a GET with a browser `user-agent` and
  `accept-encoding: identity`. The HTML is turned into text with `web.zig`; JSON
  or plain text pass through untouched. A 4xx/5xx returns status + body (which is
  where the real reason is).
- `web_search {query, max_results?}`: DuckDuckGo's `html/` endpoint (no key). It
  is a scrape: `web.searchResults` gets the title, URL and snippet by the position
  of its classes. When the HTML changes it returns a message saying so, NEVER an
  empty list (which the model would read as "there are no results").
- `max_tool_output` (16 KB) is the default budget; hard cap 200 KB.

Four things that cost something and have to be known:

1. **Explicit `accept-encoding: identity`.** `openRequest` sets
   `accept_encoding = .omit`, which is "do not send the header", and without it
   GitHub and friends answer gzip: the model eats 16 KB of unreadable bytes. std
   does not decompress transparently. Also `looksCompressed` (gzip/zstd magic + a
   binary heuristic) is the safety net for when a server ignores the header:
   "it arrived compressed" is better than garbage.
2. **The `content-type` CANNOT be returned in `JsonResult`.** The headers live in
   `receiveHead`'s redirect buffer, which is on the STACK and dies when `request`
   returns. The type is deduced from the body (`looksLikeHtml`).
3. **The result is COPIED into memory of the arena's own.** Returning a view of
   the HTTP buffer is a bomb: the `defer freeBody` lets it go on return and the
   ArenaAllocator reuses that memory on the next allocation. It was seen as `0xAA`
   where the JSON should have been, and only with the arena, which is why the
   network tests (which are skipped without internet) are the ones that catch it.
4. **The art cannot use `*` or `~`** (same reason as the banner:
   `markedSegments` eats them as style marks). The iris is `=` and the pupil `o`.

`web.zig` is PURE (no network) on purpose: what always fails is parsing the HTML,
and that is tested with fixtures.

## Context compaction (80% of the limit)

- `compaction.zig`: `budgetTokens(env)` = 80% of `ZODE_CONTEXT_LIMIT` (default
  128k → 102k budget).
- **Tier 1 (free, wired)**: `elideTier()` replaces old tool results (>256B,
  outside the `recent_window=8` window) with `[tool result elided: N bytes —
  re-run the tool if you need it]`. It is a VIEW of the wire: the JSONL session
  keeps the whole history.
- Applied in `chatWorker` (TUI) and `runChat` (headless) before
  `buildBodyMessages`. The headless prints `· N tool results elided` next to
  `[cache]`.
- `/context` in the TUI: estimated tokens vs budget and the session's accumulated
  elided count.
- **Tier 2 (wired, verified E2E)**: if `needs_summary`,
  `agent.summarizeTurns()` makes ONE LLM call with `summaryPrompt()` and replaces
  `msgs[after system..summary_upto]` with a user note `[earlier conversation
  summarized to fit the context budget]`. Best-effort: if it fails, it carries on
  without a summary. It counts towards cache_stats.
- Real E2E test (with `ZODE_CONTEXT_LIMIT=6000` and 8 reads): it fires
  `summarizing old turns…` on successive iterations and the agent repairs itself
  by re-reading what was summarized when it needs it. Caveat: with very small
  contexts the iteration limit (6/8) can be reached before it finishes.
- `estimateTokens`: ~4 chars/token + JSON overhead per message.

## Modal pickers (opencode style)

- `tui.zig`: `openPicker(tag, title, items, cb)` (thread-safe, the worker can open
  it), `pickerHandleKey` captures ALL the input while it is open (up/down/
  enter/esc/backspace + a live case-insensitive filter, 10 visible rows of scroll),
  `closePicker` frees the gpa-owned labels.
- Drawing: `drawPicker` is a centred box with borders, a title, a filter line,
  items with the selection highlighted and a footer `up/down · enter · esc
  (n/total)`. Per-frame snapshot (`pickerSnapshot`) copies ≤10 items into the
  frame's arena.
- Commands: `/model` (async list of the provider, free first + a "free" hint),
  `/provider` (with key state and default model), `/effort` with no args
  (low/medium/high). `/use` and `/effort <arg>` still work.
- Callback: `fn(*Model, tag, label)`; the label is a heap copy freed after the
  callback.
- FIX: `cur_model` now lives in a static `cur_model_buf` (`setModel()`) — before,
  a `/use <model>` with an ephemeral string from the input left a dangling slice.

## Token counter (tok/s)

- `TextSink` measures the stream's chars per turn and `updateTps()` computes
  tok/s (~4 chars/token) with `Io.Timestamp.now(io_global, .real)` — streaming
  only, without tool execs or permissions.
- `agent.tps_live` (in flight) paints it in the status bar as `⚡ N tok/s` while
  `busy`; `tps_last` stays for `/context`.

## /context (gauge and breakdown)

- Line 1: a 20-cell gauge `[████░░…]` + `~used / limit tokens (P% of limit)`.
- Line 2: `system ~N · history ~N · N turns · budget N (P% used)`.
- Line 3: `elided this session: N tool results · last stream: N tok/s`.

## Native Anthropic (Messages API + prompt caching)

- `chat.ProviderKind{openai, anthropic}` + `kindForProvider(provider_id)`; the
  `anthropic` provider in providers.zig (`ZODE_ANTHROPIC_KEY`, base
  `https://api.anthropic.com/v1`, default model `claude-sonnet-4-5`).
- `buildBodyAnthropic`: `system` at the top level, tools with `input_schema`
  (accepts the nested OpenAI format or the flat one), OpenAI `tool_calls` →
  `tool_use` blocks, role=tool runs → ONE user message with `tool_result` blocks
  (Anthropic has no "tool" role). Messages with empty content are skipped
  (Anthropic rejects them).
- **3 `cache_control:{type:"ephemeral"}` breakpoints**: the last tool, the system
  and the last block of the last message → the stable prefix (tools+system+history)
  is served from the server's cache every turn (the technique Claude Code uses for
  a ~90% hit rate).
- Anthropic SSE parsed in `dispatchEvents`: `message_start` (usage
  input+cache_read), `content_block_start`/`content_block_delta`
  (`text_delta`, `input_json_delta`), `message_delta` (output_tokens, stop_reason
  `tool_use`→`tool_calls`). `last_usage` now MERGES per field (Anthropic spreads
  the usage across events).
- Auth via `postJsonWithHeaders` (x-api-key + `anthropic-version: 2023-06-01`);
  OpenAI still uses Bearer in `streamRaw`.
- TRAP: `postJsonWithHeaders` does NOT send Bearer — in `streamRaw` the choice of
  method/auth is by `ctx.kind`.
- `models.zig` tolerates nested `data` (proxies).

## Compressed session architecture (zjsonl)

- Every JSONL line whose content is >= 512 bytes is compressed with raw DEFLATE
  level 9 and marked with a `z` prefix + base64 (JSON-safe, byte-exact). Typical
  ratio: 90-97% saving.
- On load, the `z` lines are decompressed transparently. Round-trip tested byte by
  byte.
- Session.create/resumePath return a heap `*Session`: the File.Writer references
  the write_buf inside the struct (moving it by value = use-after-free).
- Zig 0.16's File.Writer is positional: to append use `Writer.initStreaming` (the
  positional mode creates 0xFF holes).

## Universal highlighter (v2)

- `highlight.zig`: a generic one-line token scanner (not per language): strings
  with escapes and r/b/f prefixes, line and block comments, numbers (hex/floats),
  keywords vs control-flow (2 styles), builtins (zig `@fn`, rust `macro!`), types
  (+ a PascalCase heuristic), fn calls (`word(`), `@` decorators (JS/TS).
- Languages with a table: zig, js, ts, py, sh, c/cpp, rust, go, sql + a `generic`
  fallback that is safe for any fence tag.
- Tested invariant: the concatenation of the segments == the original line (text
  is never lost).

## Incremental render (TUI)

- Each closed paragraph is parsed ONCE into segments and cached with its own arena
  (max 128; LIFO eviction). Only the streaming paragraph is re-parsed per frame.
- The cache is invalidated when the terminal's width changes.

## Headless agent

- `zode --chat "..."` is a full agent with no UI: system prompt + tools + a loop
  of up to 6 iterations with implicit yolo. Ideal for testing end-to-end without
  a TTY.

## Permission flow

- The tool worker calls `model.requestPermission(tool, detail)` → **blocks the
  worker's thread** (spin + yield) until the UI answers.
- UI: when `permActive()`, the event handler captures `y/a/n/Esc` and calls
  `answerPermission(.allow/.allow_always/.deny)`; the draw paints the modal dialog
  (fixed buffers in the Model, zero allocs per frame).
- Priority: `/yolo` (global) > the "always allow" allowlist (persisted in
  `~/.config/zode/permissions.json`) > the dialog.
- A denied answer is fed back to the LLM as a tool_result `"denied: permission
  required"` so it can re-plan.
- Ticks (`ctx.redraw` in `.tick`) repaint only while there is a dialog or
  streaming — 0 CPU when idle.

## Sessions and resume

- Append-only JSONL in `./sessions/zode-<id>.jsonl` (1 write per event; tool_calls
  as raw JSON for a faithful replay).
- `zode --resume` or `ZODE_RESUME=1` loads the most recent session (by mtime) and
  reopens it: it rewrites the history once (truncate) and keeps appending.
- `/resume` in the TUI resumes the last one; `/new` creates another.
- IMPORTANT FIX: the assistant's final answer IS persisted (TextSink accumulates
  the deltas in the turn's arena).

## System prompt

- `systemPrompt()` reads the `AGENTS.md` (or `CLAUDE.md`) of the user's project
  CWD, caches it once, and injects it as the first `system` message in every
  request → a stable prefix the provider can cache.

## OpenCode provider gotchas

- The `-free` models only work from the official OpenCode client (server-side
  gate, and the gate is respected).
- Paid models need credits in opencode.ai/console.
- Chat: `POST {ZODE_BASE_URL}/chat/completions`; models: `GET
  /inference/v1/models`.

## SSE streaming (really incremental)

- `http_client.streamPost()` delivers the body IN CHUNKS (`response.reader` with a
  64KB buffer) instead of buffering it whole with `allocRemaining`. Before, the
  TUI stayed frozen until the model finished.
- `StreamCtx.feed(chunk)` accumulates into `line_buf` and dispatches each `data:`
  as soon as its line is complete. `scanSse` uses the SAME parser by feeding it
  whole (tests and paths with no socket).
- CAREFUL: `clearRetainingCapacity` does `@memset(items, undefined)` → consume
  the line BEFORE clearing.
- `chat.cancel_current` is a `std.atomic.Value(bool)`; ESC sets it and `on_chunk`
  returns `error.Cancelled`, which cuts the connection. The text already received
  is kept (`result.partial`).
- Streaming headers: `accept: text/event-stream` + `cache-control: no-cache`
  (several gateways renegotiate the stream based on this).

## Tool calls: not getting stuck

- The historical trigger was "the last byte of the args is `}`". If the stream was
  cut before that, or the model sent empty arguments, the tool call was NEVER
  emitted and the agent loop waited forever.
- Now `tryEmitTool` validates real JSON, and `flushPendingTools()` (called in
  `finish`) forces the emission of the ones that are executable. A tool with no
  arguments is treated as `{}`.
- Tests: "tool call cut in half is emitted at finish" and "tool with no arguments".

## Retries and errors

- 429/5xx → `error.RateLimited` / `error.Overloaded` / `error.ServerError`,
  retried with exponential backoff + jitter (3 attempts, 500ms/1s/2s).
  `Retry-After` is respected if the server sends it.
- 401/403 → `error.AuthFailed`, NOT retried (the key is wrong; insisting does not
  help).
- `Retry.wait()` sleeps in slices via `io.sleep` and aborts early if there is an
  ESC.

## Parameters per model family

- `chat.familyForModel(model)` detects o-series/gpt-5 → `max_completion_tokens` +
  `reasoning_effort` (and no `temperature` at all, which is a 400 there). The rest
  use `max_tokens`.
- Anthropic: `max_tokens` is mandatory, and if `thinking.budget_tokens` is sent it
  has to be STRICTLY smaller (otherwise 400).
- Tests: "buildBodyOpenAI: o-series uses max_completion_tokens +
  reasoning_effort".

## User config (~/.config/zode/config.json)

- The providers used to be compiled in: pointing at vLLM/LM Studio/Together
  required recompiling. Now `src/config.zig` loads them from disk.
- `provider`, `model` and `providers[]` (id, name, base_url, models_url, key_env
  string or array, default_model, kind, note).
- A compiled provider cannot be shadowed (the built-in wins on an id clash).
- `key_env` is a list: the first non-empty one is used. `ZODE_API_KEY` is the
  generic fallback.

## Model metadata

- `models.zig` parses OpenRouter's `context_length` and
  `pricing.{prompt,completion}` (the prices arrive as decimal strings →
  `jsonNumber` converts them; it never returns NaN).

## Userdata bugs / crossed casts (verified in a pty)

- The 3 callbacks of a turn (`onDelta`, `onToolCall`, `onFinish`) receive the SAME
  `?*anyopaque`. Each casts it to its own view, so you need a struct with a proper
  name (`TurnCtx{ text, tools }`), not passing `&tool_sink` and having `onDelta`
  cast it to `*TextSink`: that is "incorrect alignment" the moment the first token
  arrives, and in ReleaseFast it is silent UB (reading fields of another type).
- `ZODE_PROVIDER` was ignored in the TUI (`cur_provider_id` hardcoded to "opencode")
  → it sent one provider's key to another one's endpoint and got a 403. Now the
  precedence is config.json > ZODE_PROVIDER > opencode.

## Verification without a real TTY

Screenshots in a pty with `pty.openpty()` + `TIOCSWINSZ` and a minimal screen
emulator (CUP/ED/EL/ED) for the replay. It is the only reliable way to see the TUI
from an agent: `script` does not set the window size and vaxis does
`width_pix / width` → division by zero with a size of 0.

## Input: our own editor (`editor.zig`)

- `vxfw.TextField` is ONE line and has no history → it was replaced by
  `editor.Editor`: a buffer with a cursor, graphemes (not bytes), Shift/Alt+Enter =
  newline, history with ↑/↓ (with a draft), Ctrl+A/E/U/K/W, Ctrl+←/→ and Alt+B/F
  by word, and a 256 KB cap so a paste cannot take the TUI down.
- The box is drawn by hand (`drawInput`): borders `╭─╮│╰─╯`, prompt `❯`,
  placeholder, and the **terminal cursor anchored** at the real position
  (`surface.cursor`). It grows up to 8 lines and is clipped if it does not fit.
- Layout from the bottom up: status(height-2) · bottom border · input · top border
  · separator · history. It is computed BEFORE laying out the history because
  `history_h` depends on the input's height.
- The layout `doc` is in the code itself: if you touch those rows, read the
  comments in `typeErasedDrawFn`.

## `/` autocomplete

- It is offered only if the input starts with `/` and has NO spaces (otherwise it
  is already a command with arguments).
- The match is by **prefix of the command name without the slash** (`/use <prov>
  [model]` → `use`). With the whole line, `/mod` matched `/use ... [model]`.
- Tab **and Enter** accept the highlight; Esc closes without erasing; ↑/↓ navigate.

## write/edit diff

- `markdown.unifiedDiff` = LCS by lines (O(n*m)), prefixed with ` ` / `+` / `-`.
  `splitLines` ignores the final newline so it does not generate a spurious line.
- `diffSegments` colours by prefix: +green, -red, context grey, `@@` as a heading.
- The agent photographs the file BEFORE running the tool and reads it again
  afterwards (`filePathOf` + `readFileAlloc`); if it did not change, nothing is
  added to the history.

## Autocomplete bugs already fixed (do not reintroduce them)

- `containsIgnoreCase` is a *substring*, not a prefix: using it for commands gave
  false positives.
- The input's prefix goes WITHOUT the slash; the keys of `agent.commands` go WITH
  it. The slash has to be removed on one side.

## End-to-end example: `examples/platformer`

A platformer in pure Zig 0.16, built to put the harness to the test.
`zig build test` → 34 tests, `zig build run` → play.

- `src/game.zig` — pure simulation (no I/O, which is why it is testable without
  a terminal).
- `src/render.zig` — draws the state. It only reads.
- `src/main.zig` — the loop: input, fixed step, output.

### What the harness CANNOT do (reviewed by hand)

When asked for a complete game, the model produced a plausible skeleton that did
not compile. The concrete errors that came up:

- **Zig 0.11 API mixed with 0.16**: `std.ArrayList(T).init(gpa)` (in 0.16
  `ArrayList` is *unmanaged*: `.empty` + `append(gpa, x)`), `std.io.getStdIn()`,
  `std.time.sleep(nanos)`.
- **Files with crossed APIs**: `main.zig` called `Game.init()` without an
  allocator while `game.zig` defined `Game.init(allocator)`, and `game.update()`
  vs `game.step()`. It iterated `game.platforms` as if it were a slice when it is
  an `ArrayList`.
- **A non-existent `build.zig`** and a `build.zig.zon` with an invented
  fingerprint.
- **TODOs** in the code, even though the project's `AGENTS.md` forbids them.

Practical conclusion: for work spanning several files, the prompt has to fix the
contract between them (the signature of `init`, the names of the public
functions) and you have to compile after each step. The harness is good at
editing a file that already compiles; for one that has to be invented whole, it is
better to fix the contract and give the result a second look.

### Bugs of zode itself that the example uncovered

- **`takeDelimiter` and `StreamTooLong`**: if an SSE line does not fit in the
  transfer buffer (a huge tool call, a giant delta), the stream died halfway
  through the response with `error.StreamTooLong`. Now the buffer is 256 KB and,
  if it still does not fit, the full buffer is delivered as is and it carries on
  (the parser reassembles the partials). Test: "an SSE line bigger than any buffer
  is reassembled".
- **A leak in the error path**: `streamChatCtx` used `errdefer gpa.destroy(ctx)`,
  which frees neither `parts` nor `line_buf` → a leak on every 429/5xx. Now it is
  `errdefer ctx.destroy()`.

### Terminal traps that cost an afternoon (useful for any TUI)

- **`std.Io.Timestamp.durationTo(from, to)` is `to - from`.** Writing
  `now.durationTo(last)` is always NEGATIVE; with an `@max(0, …)` the elapsed time
  stays at 0 and the simulation never advances (but the render does, so it looks
  like it works: a static frame is repainted at 200 fps).
- **Canonical mode**: without `tcsetattr` removing `ICANON`/`ECHO`, the terminal
  does not deliver a single byte until Enter. And reading from a TTY is blocking
  even when it is in raw mode, so you need a separate thread.
- **There is no "key released" event** in raw mode. The terminal's auto-repeat is
  used: if the bytes stop arriving for ~120 ms, the key is considered released.
- **`Writer.fixed` does not write to the terminal**: it composes into its buffer.
  You have to dump it into a `File.Writer` and `flush()`.
- **One ANSI sequence per cell** is ~350 KB/s. Grouping contiguous cells of the
  same colour into one run brings it down to ~40 KB/s.
- **When verifying with a pty you have to always drain it**: if the child process
  fills the pty's buffer (~64 KB) and the parent does not read, it blocks on
  `write` and looks like the program deadlocked. It is not a bug in the program.

## The Ctrl+P modal palette (`palette.zig`)

A modal in the style of opencode/Claude Code, with two modes:

- **Ctrl+P** — commands, grouped (Suggested · Model · Session) with the shortcut
  on the right. Enter **puts the command in the input** instead of running it:
  `/use` needs arguments and the user wants to see what is going to happen.
- **Ctrl+T** (and `/model`) — two columns: providers on the left (with their key
  state) and the models of the active provider on the right (with `free` or the
  context window). `Tab` / `←→` change column. At the bottom, `Connect an
  integration` + `ctrl+a` to type the API key.

Decisions that are not obvious:

- **The filter is by SUBSTRING, not by prefix.** It is a search box, not the `/`
  autocomplete: with a strict prefix, typing "mod" did not find `/model` (which
  starts with a slash) and looked broken. Mind: this is exactly the opposite of
  what the `/` autocomplete does, which IS by prefix.
- **`sel[c]` indexes `filtered[c]`, NEVER `items`.** Each column has its own
  filtered list. With a single list the drawing filtered on the fly while the
  selection counted on the complete list, and with any filter the highlight bar
  went to the wrong row.
- **An item's row is computed AFTER the group header block.** Computed before, the
  label came out one row too high and the header ate its place: the list looked
  disordered.
- **`items` and `groups` are copied to the model's allocator, not to a frame
  arena.** The palette lives between frames; if they pointed at the frame's arena
  they would dangle when the streamer redrew. It is the SAME trap the graphemes
  point warns about, and it cost two crashes.
- **Every key the palette consumes sets `ctx.redraw = true`**, including the ones
  that change nothing about the action. Without that, typing in the search box
  mutated the state but the screen stayed the same (and Esc "did not close").
- **The models are downloaded in a worker**; the modal opens right away with just
  the providers column (which is local) so there is no blank wait.
- **The keys go to `~/.config/zode/auth.json` with 0600 permissions**, never to
  `config.json` (which people version). It is written to a temp file and renamed,
  so a half-way failure does not leave half a key in a 0644.
- `{f}` does **not** format `json.ObjectMap` or `json.Array` in 0.16's writer:
  there are hand-written serializers in `config.zig` (`writeStringMap`,
  `writeJsonString`).

## Scroll

- PageUp/PageDown move a **page** (the window, minus one line), not a fixed 5.
  `hist_rows` is published from the draw (the only place that knows the height).
- **Ctrl+U / Ctrl+D** = half a page, like in less and in Claude Code.
- A `↓ N` indicator in the status when the history is not anchored at the bottom:
  without it you lose the notion of "why is it not scrolling down".
- `ctx_used`/`ctx_pct` are **cached in the agent** and refreshed at the end of
  each turn: the status bar reads them every frame and walking the history 60
  times per second is wasted work.

## State

**Done**: TUI with its own multiline editor, `/` autocomplete, write/edit diff,
Ctrl+P palette (commands + models in two columns), connecting providers, page
scrolling, a segmented status bar with the session info, and the brand colour
(truecolor) in the header, borders and status.

**Next**: Skills, MCP over stdio, E2E against Anthropic with your own key, and
`@file` mentions (deferred).

## Bugs from June 2026: the ones that cost hours (all verified)

These are not hypothetical: they all came out of a real debugging session. They
all have a test that catches them; **do not reintroduce them**:

### `drainPending` reset the scroll on EVERY frame

`self.scroll = 0` was at the end of `drainPending`, which is called on every draw
even when there is nothing new. Result: `scrollBy` set 17 and the next frame
erased it. **PageUp moved nothing and the scroll looked broken.** Now it only
re-anchors if `pending.items.len > 0` **and** `scroll == 0` (sticky bottom: if
you are reading above, new text does not drag you back).

### Enter did not send when the autocomplete was open

`acceptAutocomplete` took the key and rewrote `/help` as `/help ` without
sending. You had to press Enter twice, and since nothing was sent either, the
view stayed empty and the scroll "had nothing to show". Now `isExactMatch`
detects that what was typed IS the command and lets the key fall through to the
editor.

### `streamChat` received the base URL, not the URL

`runOneTurn` passed `def.base_url` as is; `streamChat` expects the **complete**
URL (`{base}/chat/completions` or `{base}/messages` for Anthropic). Every request
from the TUI was a 404. `main.zig`'s headless runner does add the path, which is
why it worked there and was invisible in the tests.

### `writeFileSecure` called `configDir(null, …)`

`configDir` returns null without an environment, so "Connect an integration"
could **never** save: always "could not write auth.json". `env` is a parameter of
the function, and it is given `m.environ`.

### The saved key was not used

`providers.keyFor` only looked at environment variables, so connecting a provider
saved the key and then ignored it. Now there is a `saved_keys` in memory (loaded
from `auth.json` at startup, updated on save) that **wins** over the environment,
and `reloadUserConfig` + `loadAuthKeys` refresh it. With a test of the precedence
order.

### `std.atomic.Mutex` is not reentrant

`pushHeader` took the lock and inside called `pushKind`, which takes it again:
the app ended up waiting on a mutex it held itself and hung **before the first
frame** (blank screen, 0 bytes written). Wrap it in a `pushPending` that enqueues
with the lock already taken, once.

### The palette's hint was painted over the label

It only checked that the hint fit, not that the hint **and** the label fit: in
the narrow providers column you read `anthrclaude-sonnet-4-5`. Now it is measured
in columns (`displayWidth`, not bytes) and if both do not fit the hint is
omitted: the label is what gets selected.

## Network errors: the server's message is the only useful thing

`StreamCtx` keeps the first 512 bytes of the body (`noteRaw`) because on a
4xx/5xx it is the error JSON, and `setServerMessage` pulls the text out of
`"message":"…"`. "HTTP 403" says nothing; *"Model access is disabled"* does.

Each status has its own error because the **action** it calls for is different:

| status | error         | retried | message                                    |
|--------|---------------|---------|--------------------------------------------|
| 401    | AuthFailed    | no      | key rejected, check `ZODE_<P>_KEY`         |
| 402    | NoCredits     | **no**  | no credits → a `-free` model or `/provider`|
| 403    | Forbidden     | no      | the MODEL is not available for your account |
| 404    | ModelNotFound | no      | the model does not exist → `/model`        |
| 429    | RateLimited   | **yes** | retry with backoff                        |
| 503    | Overloaded    | **yes** | retry with backoff                        |

402 was being retried 3 times as if it were a 5xx: three backoff waits for an
error that does not fix itself. And 403 was reported as "bad key" when it is
almost always the model.

**A provider's default model is a time bomb**: `kimi-k2.6` disappeared from
opencode's list and EVERY request got a 403 until it was changed. When a provider
retires a model you have to change `default_model` in `providers.zig`.

## Modules and StreamCtx: a `deinit` that destroyed itself

`StreamCtx.deinit` did `gpa.destroy(self)`. Renamed to **`destroy`** because a
`defer ctx.deinit()` over a stack StreamCtx blows up with *Invalid free*. Only
used with the ones that come out of `gpa.create`.

## Header markers: `*…*` and `~…~`

The header has TWO kinds of marker because the logo is fixed and Zo's colour is
not:

- `*…*` → `brand_hi` (#c0caf5): the wordmark and the tagline, one tone above the
  owl so the logo reads lit against the art.
- `~…~` → the style the **caller passes in**: Zo's face, with the colour of its
  mood (which until now `Mood.color()` was not used for anything visible).

The markers are REMOVED from the text: the caller sees the clean text, the
drawing comes out in several colours. An unpaired marker is normal text (a byte
is never lost). The invariant is tested against the real `mascot.banner`, not
against a hand-written string, so the test stays valid if the art is edited.

## Connecting providers (Ctrl+T → Ctrl+A)

- **Ctrl+T** opens the two-column model palette (providers | models).
- **Ctrl+A** opens the key prompt for the provider **highlighted in the left
  column** (or the active one if there is none). The footer announced it and did
  nothing, which is worse than not announcing it.
- The prompt shows which provider the key is for, masks it with the last 3
  characters visible, and on save returns to the palette with the state updated.
- The key is serialized from the whole already-updated map: if it were also added
  by hand it came out duplicated (`{"a":"x","a":"x"}`).
- `auth.json` with 0600, written to a temp file and renamed.

## State

**Done**: brand colour in header/borders/status, segmented status bar with
`model · provider (effort) · ctx% · tok/s`, page scrolling with Ctrl+U/D and
sticky bottom, the Ctrl+P palette (grouped commands) and Ctrl+T (providers |
models in two columns), connecting providers with Ctrl+A, network errors with the
server's message, a new banner with the mascot in the brand colour.

**Next**: Skills, MCP over stdio, `@file` mentions (deferred), and whatever we
agree at the end of this session.

## `/clean`: deletes the AGENT's junk, and only that

`src/lib/clean.zig`, pure and tested without a TUI. `/clean` (**simulates**,
`/clean yes` applies, or `ZODE_YES=1` for when the model runs it).

**The only thing it deletes**: 0-byte sessions (the leftover of 58 files / 24
empty ones from when one was created per startup), `zode-*.tmp` from a cut-off
atomic write, and dead instances of the `<gitdir>/zode/inst` registry (dead pid,
heartbeat > 30 s, or JSON that does not parse). **Old sessions are LISTED but NOT
deleted**: `/clean yes` does not touch them, which is what `old_session` is for
and `deletable()` is `false` for that bucket.

**Never**: `.zig-cache`, `zig-out`, `zig-pkg`, the code, `auth.json` and
`permissions.json`. The exclusion lives in `clean.isProtected`, next to the scan
that could reach them, and not in the UI: a "do not touch" list written in the
render only holds until someone adds a new scan.

Three things that cost something:

1. **`const a = std.mem.Allocator;` inside `cmdClean` breaks the whole module.**
   The local `a` shadows the TYPE `a` for the rest of the function, so
   `allocPrint(a, ...)` resolves to a variable of type `type` and the error comes
   out in `clean.instanceDir` (a file that was never touched), not on the line
   that caused it. The tests that build a `Model` on a `FixedBufferAllocator`
   catch it; the module on its own does not.
2. **`sb.path(buf, …)` writes into the buffer you give it.** Keeping
   `const a = sb.path(&b, …)` and then calling again with the SAME `b` leaves `a`
   pointing at the second path: the test ends up checking the wrong file against
   the wrong expectation and fails for no apparent reason. Every path that
   survives another call needs its own buffer.
3. **`isProtected` by segment, not by prefix.** `a/b/.zig-cache/o` is as much a
   build artifact as `.zig-cache/o`, and a prefix test overlooks it. The other way
   round too: `zig-out-mine` is NOT `zig-out` and deleting it would be a bug. With
   a test of both directions.

The `.zig-cache` exclusion is structural as well as explicit: the three
directories that are walked (`sessions/`, the registry, `~/.config/zode`) do not
contain build artifacts, so they cannot even be reached.

## Bugs from the fuzzing round (2026-06-29)

They all showed up with `fuzz.py` (random key sequences against the real TUI,
with network and threads) and they all have a test now. **The lesson: a TUI is
not tested by pressing four keys**; it has to be bombed.

### The mouse wheel took the app down

`self.scroll` is a `usize` and the wheel did `self.scroll -= 3`: with the scroll
at 0 that underflows -> panic. Minimised to two `\x1b[<65;...M` in a row. Now the
wheel uses `scrollBy`, which saturates at 0. **Any scroll arithmetic goes through
`scrollBy`; nothing touches `self.scroll` by hand.**

### `key[1..]` on an empty key

In Zig 0.16 a `0..1` slice over a `[]const u8` of len 0 is a panic, not an empty
slice. `cmdGroup` removed the slash without checking. Now it removes the slash
only if it is there, and there is a test with an empty key and with no slash.

### `/model` was sent as `/models`

The autocomplete accepted with Enter by comparing the exact match ONLY against
the highlighted item, and the popup sorted `/models` before `/model`. Typing
`/model` + Enter ended up sending `/models` (a different command). Now: **if what
was typed is a complete command it is sent; if it is partial, it is completed.**
Tab always accepts.

### A crash on exit from literals in the palette

`freeItems` freed the palette's `label`/`hint`, but the `+ connect` item brought
**literals** (`"+ connect"`, `"ctrl+a"`). `gpa.free` on `.rodata` is an *Invalid
free* that only showed on exit, with the palette already half destroyed: blaming
it on the offending item is nearly impossible. **Every label/hint in the palette
is its own copy; `buildModelItems` is the only constructor.**

### Dangling pointers in the models column

The worker delivered a `[]models_mod.Model` and immediately freed the list: the
items' `id`s were left dangling and the drawing blew up with `InvalidStartByte`.
Now the worker builds the **items** (own strings) and leaves them in
`pending_items`; the draw collects them. `Palette.setItemsOwned` is now owned and
frees the previous ones, so it does not grow either.

### The palette was modified from two threads

The models worker filled the palette while the UI thread drew it **without a
lock** (the lock only covers the history) -> segfault. The worker no longer
touches the palette: it leaves the items and the draw applies them.

### Detached workers + destroyed `io` = use-after-free

The threads are spawned with `detach`: nobody joins them. On exit, `app.deinit()`
destroyed the `Io` while a worker was still inside `io.async`
(`Threaded.cancelThreads` -> segfault). Now there is an atomic worker counter and
`runTui` does `model.waitWorkers(2000)` **before** the `defer`s run, with a time
cap so it does not hang if a worker is stuck in the network. The wait counts
turns with `yield`, not with the clock: during shutdown, asking the time through
the `Io` is exactly what you should not do.

### Reloading the config freed the keys' arena

Connecting a provider calls `reloadUserConfig`, which freed the config's arena.
But the keys from `auth.json` lived there, and a worker downloading the model list
was reading `saved_keys` through `providers.hasKey` at that very instant: use
after free, with nothing giving it away (it only happens if the worker lands
exactly on that line).

Now the keys have **an arena of their own that is not destroyed until the process
exits** (`keys_arena_state`): reloading only reassigns the pointer, which is
atomic, and the old map stays valid memory until the teardown.

**Rule: a map that can be read from several threads is never freed at runtime; the
pointer is reassigned and everything is thrown at the teardown, when there is
nobody left reading.**

## Palette filtering: the group vetoed, and both columns emptied

Two bugs that make the model list look empty:

1. **The group name VETOED the match.** In `matches` the group was checked with
   `return containsIgnoreCase(g.name, q)`, that is "if the group does not match,
   the item does not exist". Searching `sonnet` did not find `claude-sonnet-4`,
   because it lives in the "Models" group and "sonnet" does not appear there. With
   the filtered list empty, Enter ended up applying a model that was **not** the
   highlighted one (it looked like it was, because the index-based selection fell
   on the first). The group is one MORE way to find things, never a veto.
2. **Both columns were filtered.** With focus on Models, typing `sonnet` also
   emptied the providers column and you saw "no matches" on both: the feeling that
   the model list does not exist. Now **only the focused column is filtered**, and
   the other one stays as context. When you change column (`Tab`, arrows) it
   filters again.

And the silliest of all: `openModelPalette` set the mode **after**
`setItemsOwned`, and `resetSelection` computes the active column from the mode.
With the old mode it stayed on providers: the arrows did not move the models.
**The mode goes before `setItemsOwned`.**

On top of that, both columns highlighted their row and there was no way to tell
which had the focus. Now only the focused one is highlighted; the other marks the
chosen row with `>` in dim blue (you can see which without it looking focused).

## The slime: three failed versions before getting it right

The ASCII art of a mascot is a matter of taste, and zode's went through three
versions that were wrong and make clear what makes something "read":

1. **Symmetric square** (the first one): no silhouette. It is a cushion.
2. **Dome + a base that spills**: the right shape for a drop of water, not for a
   slime. With the widths going up and down it looked like a mushroom.
3. **A drop with a drip on top**: it looked like a water drop with bubbles, not a
   creature.
4. **Minecraft slime** (the one that stayed): a box with rounded corners TALLER
   THAN WIDE, with the two oval eyes and the wide mouth of the game's sprite.

**What matters is the proportion, not the decoration.** The game's slime is tall
and narrow; anything square reads as a box. And the eyes and the mouth are
**filled** with `█` because in the sprite they are dark patches, not outlines.

The widths are computed by centring each row over the widest one with a script,
not by eye: by hand it always comes out crooked on the third row.

## THE FUZZER WRITES TO YOUR REAL CONFIG

`fuzz.py` types pseudo-random keys, among them `ctrl+a` and `enter`, which open
the "connect" prompt and **save a key in `~/.config/zode/auth.json`**. In one
round it saved `"opencode": "pasted texthelpoommxllmm"`, and since a saved key
has priority over the environment it masked the good key from `.env` and left the
provider with a 401 "Invalid credential" and no apparent explanation.

- **The fuzzer runs with its own `HOME`** (`/tmp/opencode/fuzzhome`). Never touch
  the real config with automated tests.
- `normalizeKey` rejects keys with spaces or that are too short, which is what
  catches a text pasted by mistake. With a test.

## OpenCode's default

Only `space-bunny-free` answers; the rest of opencode's free tier gives a 403
("can only be used from within OpenCode") because it is gated to the official
client. The paid ones give a 402 without credits. So the default is that one, and
the provider's `note` says so to avoid wasting time trying the others.

## Zig's cache serves stale artifacts

`zig build` with a clean source kept installing a binary with a debug `print`
that no longer existed, and `touch` did not fix it. **If a trace or a change "does
not appear", delete `zig-out/bin/zode` and rebuild** before losing half an hour
convincing yourself you are going mad. Checking with `strings zig-out/bin/zode |
grep <text>` is the fastest check.

## Freeing a LITERAL from the worker: `[]const u8` does not say so

`execToolCalls` returned the literal `"Continue with the tool results above."`
typed as `?[]const u8`, and `chatWorker` freed it because it assumed everything
`runOneTurn` returned was its own. Freeing `.rodata` with the process allocator is
a **"reached unreachable code"** in ReleaseSafe: any turn that used a tool took
the app down, always.

The real fix is not the `dupe` (which fixes the symptom) but the **type**:
functions that return memory owned by the caller return `[]u8`, and Zig literals
are `[]const u8`, so the compiler PREVENTS returning one that way. Same criterion
as `setItemsOwned` in the palette: ownership has to be in the signature, not in a
comment.

## The TUI's agent loop was BROKEN with tools (and silently)

A turn with a tool in the TUI: the tool ran and **the final answer never
arrived**. With no visible error, because the API notice stayed in `pending` and
you had to press a key to see it. Two bugs chained:

1. **The assistant's message was stored WITHOUT its `tool_calls`**
   (`appendAssistant(text, null)`). The tool message carries a `tool_call_id`, so
   it matched nothing and the API answered 400 `invalid_request_error` on the
   NEXT turn. Now `toolCallsJsonFromCalls` rebuilds the JSON (the SAME format as
   `chat.StreamCtx.toolCallsJson`, which is what the headless runner uses: if they
   diverge, one of the two clients sends a conversation the other cannot read).
   With a test that pins the literal format.
2. **Nobody opened the live paragraph for the iterations.** `streamEnd` only set
   the paragraph `if (streaming)`, and after the tool `streamStart` was not
   called: the response's deltas accumulated in `stream_buf` with no owner and
   were discarded. Now every iteration opens a paragraph with `streamStartIteration`
   (which does NOT reset the strip's clock, unlike `streamStart`: a clock that
   jumps to 0 on each iteration cannot tell "slow" from "hung"), and `streamEnd`
   has `or stream_buf.len > 0` so no text is lost.

And the third one, while we were at it: **the system prompt was re-inserted on
every iteration** (`items[0].role != .system` with the user already appended, so
`items[0]` was `user`). The second turn went out as
`[user, system, tool, system]`. Now the system is looked for in the WHOLE list.

How it was found: the new tool (`web_fetch`) prompts, the turn stayed in
"thinking" forever, and the first instinct was "it is the new tool". With `[DBG]`
in the loop it printed `iter 1 ERROR ServerError` on a `bash` of `echo hola`: it
had nothing to do with the web.

## `Io.sleep` from a worker FREEZES the TUI (and has done it twice)

`Retry.wait` and `chat.sleepMs` used `io_global.sleep`, and that takes the event
loop of the `Io` shared with the UI away with it: during the backoff the redraws
stop, the strip's clock freezes and the retry notices stay in `pending` unpainted
(you have to press a key to see them). It is exactly the problem
`lib/sleep.zig` exists for, and the solution is the same: a bare `nanosleep`
syscall that does not touch the `Io`. `Retry.wait` sleeps in 50 ms slices so ESC
can cut it short, and it respects the server's `retry-after` (which was read into
`chat.retry_after_secs` and **read by nobody**: a 429 with `retry-after: 30` waited
1 s and ate the entire rate limit, three times). 30 s ceiling.

## The status messages have to say WHY, not just WHAT

- The activity strip's label is the PHASE: `thinking` / `streaming` /
  `running <tool>` / `waiting for your permission` / `queued`. Before it was
  always "working", and 40 s of "working" does not tell thinking from writing from
  a hung `bash`.
- `pushRetryNotice` says the error in words (`errPhrase`), the server's text and
  how long is left: `rate limited: Too many requests · retrying in 1.0s (attempt
  2/3)`. `@errorName` gives identifiers (`RateLimited`), not messages.
- `execToolCalls` ends with `3 tools · 1.2s` (+ `· denied` if there were any)
  instead of "tools done", and the turn with `done · 12.4s`.
- The backoff was `1 << (attempt -| 1)`, which saturates to 0: the real series was
  500/500/1000 ms, not the 500/1000/2000 the comment said. Now `1 << attempt`,
  with a test.
- The status bar's tok/s are only painted **while there is a stream**: `tps_live`
  is the last stream's and it is not cleared, so with a 30 s `bash` the row kept
  announcing "⚡ 42 tok/s" without a single token arriving.

## Queued prompts

`startChat` did not check whether a turn was already in flight, so sending a
second prompt launched ANOTHER worker and the two fought over the session and the
streaming state: the input froze, the history cut itself off, and there was no
way to tell whether it was working or hung.

- `Model.queue` with `enqueuePrompt` / `takeQueued` / `queuedCount` /
  `clearQueue`, all under a lock.
- The worker, when it finishes its turns, **takes the next one off the queue and
  carries on** instead of finishing and letting another worker compete.
- `deinit` frees the queue AND its buffer: `clearQueue` keeps the capacity (good,
  so we do not reallocate on every prompt), so `queue.deinit` goes separately or
  it leaks.

## Activity strip: the little mascot is the "working" indicator

One row above the input box, which **only appears if there is something to say**
(when idle it takes up nothing):

- The face **animates** between two frames (`mascot.faceFrames`): open eyes and
  narrowed eyes. A static icon does not tell "thinking" from "hung".
- The state: `working` / `queued` / `waiting for your permission`.
- **The elapsed seconds**: it is the only thing that answers "has it hung?".
  Mind the units: the value is **milliseconds** and it is printed as
  `{ms/1000}.{(ms%1000)/100}s`; treated as tenths it said "153.3s" for 1.5s.
- The queue: how many and which is next.

The clock uses the `Io` given by `Model.attachIo` and an `io_ready` flag: the
tests build a Model without an app, and reading an uninitialized `Io` is using
garbage as a vtable.

## Clearing the history before painting

The live paragraph is re-wrapped every frame and when it SHRINKS (every time the
model breathes between tokens) the leftover cells kept the old text: the same
answer was visible **twice, split and mixed** ("deSsyftware:tcorregir"). The
history area is cleared with a `fillRange` before painting the blocks.

## Separation between paragraphs

A blank row between blocks, so the history is not a wall of text. Two things that
cost an afternoon:

- The row is **added to the array of lines** (an empty `PLine` at the front), not
  just added to the height: `drawLines` walks `c.lines`, so if the height says more
  than there is, the last block is lost.
- It goes **before**, not after: placed at the end the gap came out after each
  paragraph and separated nothing.

The render tests looked for concrete rows (0, 1, 2) and broke with every layout
change. Now they use `findRow` / `hasBlankRowBetween`, which search by
**content**.

## UI flows (the ones the user asked for)

- **Ctrl+P** -> grouped command palette (Connect · Suggested · Model · Session).
  `Enter` **runs** the chosen command (see "The palette RUNS, it does not fill").
  The exception is `/use`, which needs arguments.
- **Ctrl+P -> Connect -> provider -> key** is the short way to connect: the
  `Connect` item in the header opens a modal with all the providers and their key
  state; `Enter` on one opens the key field. On save it goes back to that same
  list with the state already updated (to "key ok"), which is where you see that
  it worked. Dumping the user into the models palette leaves them with an empty
  column and no idea why.
- **Ctrl+T** or **/model** -> "Switch model" in two columns (providers | models).
  It **opens right away** with the providers column (which is local) and the
  models are filled in when they arrive from the network: before, nothing opened
  until the provider answered, and with a slow one it looked like the command did
  nothing.
- **Ctrl+A** opens the connect modal directly.
- The activity strip goes above the input, and the history blocks are separated
  with a blank row. The tokens and the ctx% ALWAYS appear in the status bar
  (before the ctx% only appeared after a whole turn, and at the start you saw
  nothing, which made it look like the counter did not exist).
- The keys go to `~/.config/zode/auth.json` with 0600, never to `config.json`.
  `providers.keyFor` looks at the saved ones first and the environment second, so
  connecting actually does something.

## All the code in English

The visible UI is in English, the agent's system prompt too (models answer
better), **the code comments too** and **the test names too**.

This was decided in September 2026 and completed in October: the code is read by
people who did not write it, and two languages in the same file make the
_cautions_ get read halfway. A test name is the other half of the caution: it is
what would say "this broke" if the test were removed, so it also has to be
readable by someone who does not speak the language of whoever wrote it.

**What is NOT translated**, because it is not text: identifiers, protocol names
(SSE, JSON-RPC, `session/prompt`), tool names, paths, strings the test asserts on
(a `⏺` or a `⎿` are part of the assertion), and the ASCII diagrams.

Check (both have to come out empty):

```bash
grep -h '^test "' src/*.zig src/lib/*.zig | grep -P '[\x{00e1}\x{00e9}\x{00ed}\x{00f3}\x{00fa}\x{00f1}\x{00bf}\x{00a1}]'
grep -rn '^\s*//[/!].*\b\(que\|para\|del\|los\|las\|una\|como\|esta\|mas\)\b' --include=*.zig src/
```

## The palette RUNS, it does not fill

Choosing a command from the list with `Enter` **runs** it. Before it put the label
in the input and needed one more `Enter`, and since the palette closed before
writing, the command was left half-done until the next key: it read as "this does
nothing".

- `agent.runPaletteCommand` decides and returns `done` / `needs_args` / `quit`.
  `/use` is the ONLY one that needs arguments (it goes back to the input with the
  slash in place); `/quit` is handled by the TUI because it is who has the
  `ctx.quit`.
- The command echoes in the history as `.user`, just as if it had been typed, so
  you see THAT it ran and not just that something happened.
- The palette closes **before** dispatching: some commands reopen it with
  different content (`/model` -> the models palette) and if it were still active,
  that one would be drawn on top and the new `esc` would not close the old one.
- The palette's footer says `enter run`, not `enter insert`.

Two bugs that came out while touching this:

- **`Palette.close` let go of the items without freeing them.** It did
  `items = &.{}` by hand, so every closed Ctrl+P was a leak of the labels, and
  `owns_items` stayed `true` over an empty list (the palette looked like it owned
  something it no longer had). Now `close` does NOT touch the items: they are
  freed in the next `setItemsOwned` or in `destroy` (which is what `Model.deinit`
  calls). With a test.
- **`/effort` with no arguments answered "unknown effort"**. `it.rest()` returns
  `""`, not `null`, for "/effort", and the `else` of "low|medium|high" ate the
  case: the picker never opened. In `submit` an empty rest is now a real `null`.
  With a test.

## The banner: ZODE in block letters, and why NOT a hand-drawn creature

Three versions of a creature (symmetric square, dome with a spilled base, a drop
with a drip) came out wrong for the same reason, and it is worth writing down
because it is going to repeat as soon as someone wants "a nicer little mascot":

**`▀` and `▄` paint HALF a cell.** `▀` is the bottom half, `▄` the top half, and
`█` the whole one. Drawing an outline with half cells leaves the edges at half
height: the result is not a silhouette, it is a pile of loose bars. It was tried
being fixed by keeping and losing halves and it did not work, because the problem
is not which half you keep but that the drawing depends on the terminal aligning
rows and columns with millimetric accuracy.

**With box-drawing characters (`█ ╗ ╝ ═ ║`) every cell is painted whole** and the
shape is the one you meant. ASCII art with boxes is deceptively fragile; box
drawing is not.

That is why the banner is the name in block letters (figlet "big"), 6 lines, and
the mascot stays as **a one-line face** for the activity strip and the status
bar, which is where it has to be legible without taking up rows.

## The status row goes by SEGMENTS, and the face in its mood's colour

The complaint was "you cannot even tell by the colour". The reason: the row was
composed as **a single string** painted entirely in `brand_soft` (the dim blue),
so the face came out in the same dim grey as the text. `Mood.color()` was not used
for anything visible.

- The row is composed as `[]InfoSeg` and painted cell by cell: the face with
  `Mood.vaxisColor()` in bold, the text in `brand_soft`, the spinner separately.
- The mood is set by whoever composes the status (`setStatusWithMood(mood,
  text)`), not deduced from `busy`: the agent knows whether it is thinking,
  waiting for permission or hung, and the TUI's state only knows two of those
  three.
- `setStatusWithZo` does NOT put the face in the text any more. Before it did,
  and since the row also painted it, there were **two** (one in the strip and one
  in the text) and the second one in grey. If you change one, change the other.

## `putText` returns the FINAL COLUMN, not the width

`p.putText(col, row, text, style) u16` returns the column it ends at. So
**`col += p.putText(col, ...)` is wrong** (it adds two absolute positions) and
`col = p.putText(col, ...)` is correct. That bug sent the "A" of "always allow" to
column 92 of a 68-wide panel, outside the box, and made the test of the four
options fail. It has only been fixed in two places; any new loop that chains
texts has to do it this way.

## The permission dialog is a centred MODAL, not four lines

Before they were four lines stuck right above the input box, in the middle of the
normal flow: with a full history they were half visible or the box covered them,
and the app looked **hung** waiting for something nobody could see. Now it is
`drawPermissionModal`: a centred box, a clean background (otherwise the history
shows through underneath), a yellow border, the tool and its arguments, and the
four options with their key highlighted. It is drawn **on top of everything**,
just before the palette.

And the verification screenshot has to **wait for the modal to appear** before
sending the key: sending it at 6 s when the dialog takes 12 s proves nothing, the
`n` goes to the input and it looks like the shortcut does not work.

## Tools are marked so the parser paints them in two tones

`pushToolStart` composes `*write*(hola.js)`: the name marked with `*…*` so that
`markdown.markedSegments` paints it in the tool's strong colour and the argument
in the dim one. Without the mark, `write` and `hola.js` came out in the same cyan
and were indistinguishable at a glance. The tool's result uses the same trick
(`*summary* · Nms`) with `tool_res_bold`.

**No space before the parenthesis**: the tests look for `read(src/tui.zig)`, and
a space breaks them. The markers are removed when painting: the row never shows
them (test).

## The header has NO paragraph separator

The paragraph separation (a blank row) cut the ASCII art into pieces: a blank row
between the letters and the logo stops reading. `prev_banner` in the segment cache
loop disables the separator around `.banner`.

## Detail when writing drawing tests

- A little face is **several graphemes** in different cells (`◔◕`): comparing the
  whole string against `cell.char.grapheme` never matches. You have to walk it
  with `vaxis.unicode.graphemeIterator`, as the painter does.
- Looking for art lines by a **fragment** is fragile: `█████╗` (line 3) is a
  substring of `███████╗` (line 1), so `findRow` returns row 0 and the test
  compares a line with itself. Compare the **whole** row.
- The face appears **both in the activity strip and in the status**: `findRow`
  finds the first one, and the test ends up checking the wrong row. For the status
  you have to read `s.readCell(col, height - 2)` directly.

## State

**Done**: web tools (`web_fetch` with HTML→text, `web_search` via DuckDuckGo, no
permissions) + pure `web.zig` with tests, **the TUI's agent loop fixed** (the
assistant's message carried `null` instead of its `tool_calls` and killed the turn
with a silent 400; and the post-tool iteration's paragraph did not open, so the
final answer was lost), an activity strip with the PHASE
(`thinking`/`streaming`/`running <tool>`) instead of "working", retry messages with
the reason and the wait, a header with **only the ZODE wordmark** (5 rows of plain
ASCII, no mascot, no greeting line, no shortcuts line: Houston was tried and
rejected, see "v4"), the Ctrl+P palette **runs** the chosen command instead of
leaving it in the input, the permission dialog as a centred modal, a status row by
segments with the face in its mood's colour, tools in two tones, UI in English,
Ctrl+T (/model instantly in two columns), Ctrl+A (connect), page scrolling with
Ctrl+U/D and sticky bottom, network errors with the server's message, and the
fuzzing crashes.

**Next**: Skills, MCP over stdio, `@file` mentions (deferred), selective
permissions (so harmless tools run without asking instead of only with a global
`/yolo`), `web_fetch` with a per-range budget (now it only reads the beginning of
the document) and a real search engine behind `web_search`, and whatever we agree
at the end of this session.

## The banner: three versions, and the one that stayed

**v1 (box drawing, figlet "big")** — misaligned rows, it read as "diec FERE". The
underlying problem: box-drawing art is a **map of cells**, and if the rows do not
land on the same columns there is nothing to read. Also the test that watched it
measured with `.len`, which is BYTES (row 0 "measured" 101 columns), so it always
passed.

**v2 (box drawing, composed at comptime)** — well aligned and good in the test
pty. In the user's terminal it was **illegible**: a relief smudge that read as
nothing. Reason: art made of `█ ╗ ╝ ═ ║` depends on how the font draws the full
block, and with a double width or a substitute the strokes get fat and overlap.

**v3 (plain ASCII, the one that is there)** — `#` and space, 5 rows, four boxes of
6 columns. It reads the same in any terminal and `O` and `D` are distinguishable
at a glance (which was the other failure: it read as "ZOOE").

What stayed:

```
######  ####  ####   ######
##  ## ##  ## ##   # ##
   ##  ##  ## ##   # ###
  ##   ##  ## ##   # ##
######  ####  ####   ######
```

Two things that cost something and have to be known:

- **`#` clashes with markdown.** Every row that starts with `##` is a HEADING, and
  the parser eats the `#`: the logo came out as "####  ####  *zode*". The real fix
  is that `parseBase` does not look for structure in `kind == .banner`: the banner
  is a drawing, not prose. There is a test in `markdown.zig` that pins it, and
  another that checks the other kinds STILL interpret headings (the fix is not
  turning the parser off).
- **The text (`zode` / `a code agent` / `in your terminal`) was removed.**
  Explicitly asked for: only the ASCII.

The art is composed at comptime with `bannerRow()` from the glyph table, because
in figlet the letters have different widths and the padding on the right is lost
when an editor strips the trailing spaces. `banner_art_width` is the assertion and
the TUI test checks it, measuring in COLUMNS (`plainColumns`).

## v4: Houston (Astro Boy) — TRIED AND REJECTED

The mascot that was asked for got made (Houston from Astro Boy, solid dome, two
eyes with ring/iris/pupil, a grid mouth, a body with arms) and it was **out on the
first try**, with a "it's horrible, just ZODE and take that away, all that junk in
the view annoys me".

The failure was not the drawing, and it is worth writing down because it is going
to repeat:

**A TUI header is read in the first half second, and 20 rows of ASCII art are 20
rows of nothing.** It measured 18 of robot + 1 of greeting + 1 of shortcuts = 20
rows before the first word of the conversation. In a 30-row terminal 10 were left,
and the art is exactly what you see while it "loads". A well drawn robot does not
compete with the text: it crushes it.

What stayed is what it was before: **five rows with `ZODE`** and nothing else. No
mascot, no "zo the code robot says: hi!…", no shortcuts line
`/help · /model · ctrl+p…` (they are already in the Ctrl+P palette and in `/help`).

Details that served and are still alive:

- **The art cannot use `*` or `~`.** `markedSegments` (`markdown.zig`) strips
  `*…*` and `~…~` from the banner because they are STYLE marks: an eye drawn with
  `***` ended up with no outline, and with an odd number of rows the asterisks of
  one paired up with those of another.
- **The two halves were composed separately** (`robotRow` filled to
  `robot_art_width`, `bannerRow` composed the wordmark from the glyph table,
  `bannerLine` glued them with two columns of air and centred the wordmark on the
  head's vertical). The wordmark glued to row 0 read at the dome's height and
  looked like a stray label. If a mascot ever goes next to the name again, that
  is the split that works.
- **`banner` was assembled with a loop inside a comptime `blk`**, because
  `bannerLine` wants a COMPTIME row: with a normal runtime `for` the index is not
  one and it does not compile.

The test in `tui.zig` still pins that below the art **there is nothing**: if
someone hangs another line (or a mascot) on the header again, `zig build test`
fails.

## Tool loading: "working" does not say whether it is alive

With a 30s `bash` the last row stayed frozen at `⏺ bash(...)`: there is no way to
know whether the process is still going or the app hung. Now:

- `Model.tool_run` (`?ToolRun`): `pushToolStart` sets it, `pushToolDone` clears it
  (via `toolRunEnd`). **Own** copies of the name and the argument: the argument
  comes from the worker's arena, which is freed at the end of the turn.
- A `⎿  bash running · 21.4s` line under the tool header, **repainted every
  frame** from the "live paragraph" block (the same mechanism as the streaming).
  It replaces the live paragraph instead of being added to it: they never coexist.
- The activity strip and the status bar **name the tool** (`working bash 7.6s`, and
  the status puts the argument), because "working" on its own does not say whether
  it is working or hung.
- `Model.workingLocked()` counts `tool_run` as work. Without that, between
  `streamEnd` and `pushToolDone` there is a window where `busy` is already false:
  no spinner, no clock, and the strip saying "queued".

Two traps that came out on the way:

- **`toolRunEnd` is called BEFORE `pushToolDone`'s `lock()`**: `std.atomic.Mutex`
  is not reentrant and taking it with your own hangs the app.
- **The line's text is copied into the frame's arena**, not into a stack buffer:
  the `CellRun`s store the grapheme by value but with a pointer to its bytes, and
  the painting happens AFTER the block. It is the `&[_]u8{c}` bug from above, and
  it shows up as a row full of NULs.

## The September 2026 freeze: it was NOT performance

Full diagnosis in `ROADMAP.md`. What has to be kept, because the three things
that caused it are invisible in a CPU profile:

1. **The layout loop did not terminate.** It was
   `while (seg_cache.len < paras.len)` + `orderedRemove(0)` when going over the
   cap of 128: append (129) -> evict (128) -> back into the loop, forever. With
   `pushDiff` putting ONE PARAGRAPH PER DIFF LINE, a single `write` of a 129-line
   file hung the app instantly. Now the cache is a WINDOW (`layoutWindow`) with
   `para_idx` per entry and `para_heights` per paragraph, and there is an
   iteration budget (`layout_iters` / `layout_overflow`) so that a FUTURE
   regression fails a test in 1 s instead of hanging the process. That budget is
   not decorative: without it the test hangs the whole runner and there is no CI
   possible.

2. **The tick chain could die forever.** The `.tick` only re-armed "if there is
   work", and `busy`/`dirty` have windows where both are false (between
   `streamEnd` and `pushToolStart` there is a session `write(2)` and a DEFLATE-9 in
   between). A tick there left `App.timers` EMPTY, and the worker has neither a
   pointer to the `EventContext` nor to the event queue: there was no way to ask
   for a frame. The tick now re-arms ALWAYS.

3. **`requestPermission` did spin-yield on the HISTORY's lock** for the 30 s you
   take to decide: it burned a core and made every UI lock acquisition a failed
   `yield`. Now it has its OWN lock and a sleeping wait with `nanosleep` and
   1->20 ms backoff.

## Correction: the `Io.sleep` diagnosis was WRONG

This document used to say (and repeated) that "`Io.sleep` hijacks vaxis's event
loop". **On Linux it is false**, and it is worth keeping corrected so nobody
investigates it again:

- `Io.sleep` is a vtable call. `Threaded.sleep` goes to `sleepPosix` because
  `use_parking_sleep` is only true on Windows/NetBSD/illumos.
- `sleepPosix` is a `clock_nanosleep` in the calling thread, with a per-thread
  `Syscall` that **does not touch `t.mutex`**.
- vaxis's tick is a normal entry in `App.timers` that evaluates `App.checkTimers`
  on the UI thread.

The clock was freezing because of points 1 and 2 above, not because of the sleep.
That is why `lib/sleep.zig`'s bare `nanosleep` is equally correct: it is what
`Retry.wait` and the permission dialog's wait use, but for robustness, not because
`Io.sleep` was a problem.

## Correction: the segment cache's capacity

`max_cached_paras`'s comment said "deep scroll re-parses on demand". **It did
not**, and that assumption is exactly what made the `tui.zig` loop not terminate.
Now it does: `layoutWindow` picks the window containing the visible lines and
`layoutFor` iterates until the range stabilises (the heights start estimated and
are corrected on parse).

## Zig 0.16 traps that cost an afternoon

- **`gpa.free(list.items)` is an `Invalid free`.** In 0.16 `items` is the LENGTH
  slice and the capacity is separate. To free you have to use `allocatedSlice()`.
  It blows up in `pushDiff` with "Invalid free".
- **`clearRetainingCapacity` does `@memset(items, undefined)`.** If it is called in
  `deinit` AFTER the `deinit` of that same list, it is a memset of `undefined`
  over freed memory -> GPF.
- **`std.Thread.Mutex` does not exist any more.** `std.Io.Mutex` /
  `std.Io.Condition` have it, but they need an `Io` (and the tests build the
  `Model` without an app). For the permission dialog: its own `std.atomic.Mutex` +
  a sleeping wait.
- **Unmanaged `ArrayList` asks for exact capacity**: a 128 B
  `FixedBufferAllocator` fails when asked for 128 B for 8 pointers. The `TurnStats`
  tests use 512.
- **Returning a slice to a stack temporary** (`normalizeLang` did it) is read
  AFTER the function returns: three red tests in a row until it fell.
- **`rowText` returns BYTES, not columns**: `◆` is 3 bytes for 2 columns and `─`
  is 3 bytes for 1. Comparing bytes against columns gives a red test with the
  layout correct.

## `tools/pty_smoke.py`: the only verification that is really worth something

The `drawTest` tests read the surface and check the text and the styles, but they
do **not** check what breaks most: vaxis's render is DIFFERENTIAL and queries the
terminal (colour, capabilities, size). A homemade emulator loses half the redraw,
which is exactly what makes a turn that works look frozen.

So there is a smoke test in a real pty (`pty.fork` + `TIOCSWINSZ` at 200x50):
startup, banner, input box, status, prompt echo, **Ctrl+P opening and closing the
palette**, Ctrl+L, scroll, and no panic and no `Invalid free`.

```
zig build && python3 tools/pty_smoke.py
```

Two things it does well and have to be kept:

- **Its own `HOME`** (`/tmp/opencode/zode-smoke-home`). The app writes
  `~/.config/zode/auth.json` and `sessions/`, and an automated script must not
  touch the real config of whoever runs it. June's fuzzer saved a key pasted by
  mistake and left the provider with a 401 and no apparent explanation.
- **`TIOCSWINSZ` first**: without a window size vaxis does `width_pix / width` and
  exits with a division by zero. `script` does NOT set the size.

## vaxis is NOT patched in the tree (5.7 and 5.9)

The ROADMAP proposes two patches on `zig-pkg/vaxis-…/src/vxfw/App.zig`:

- **5.7** `arena.reset(.free_all)` -> `.retain_capacity`, so the frame is a bump
  instead of 1.36 MB of malloc/free per frame.
- **5.9** lower the timeout of `vx.queryTerminal` (`.fromSeconds(1)`), which is up
  to **1 s of blank screen** at startup on terminals that do not answer.

They are not done here because `zig-pkg/` is a dependency cache: a patch in that
directory is lost on the next `zig fetch` and does not show up in the repo's diff
(it is the worst combination: a fix that looks like it is there and is not). If you
want them, the way is an **upstream PR to vaxis** or a `patch` declared in
`build.zig.zon` that applies visibly and reproducibly.

**5.10** (removing `subscribeToColorSchemeUpdates`) is not touched for the same
reason: it is INSIDE `App.run`, so it cannot be done from outside either. And even
if it could, the saving is one round trip at startup.

---

# Branch `feat/roster`: what the other session does not cover (2026-09-30)

This worktree (`/home/jesusalcala/Projects/zode-agente`, branch `feat/roster`)
implements what the other session's `ROADMAP.md` does **not** cover. The task
digest is ceded to them (their Phase 3 is more detailed).

| area | who | note |
|---|---|---|
| task digest | **them** | ceded, their Phase 3 is more detailed |
| render / size / RAM | **them** | their Phases 4 and 5 |
| `is_free` (3 signals) | **us** | useful for both: the pool would not exist without it |
| free-auto (rotation) | us | `/free-auto`, `roster.zig`, `free_auto.zig` |
| visible plan | us | `todo` tool + on-screen block |
| `/undo` | us | file snapshots per turn |
| `@file` | us | the content goes with the prompt |

**3 RED tests in that worktree belong to the other session** (they were in the
commit base, nobody touched them here):
`tui.test.pushDiff puts ONE paragraph…`, `tui.test.a diff of 300 lines…` and
— this one we did fix — `tui.test.streamEnd marks dirty` (it passes now).

Merged on 2026-09-30 (see the merge commit for the conflict resolutions).

## free-auto: rotates between the free models of every provider

`/free-auto on` (or `ZODE_FREE_AUTO=1`) lists the free models of each provider that
has a key and spreads the turns between them. When one runs out of quota, the turn
**carries on by itself** with the next one: there is no need to type "continue".

- `src/roster.zig` — the pool: order, caps, cooldowns, rotation, exhaustion
  report. Pure and tested (no network).
- `src/free_auto.zig` — the mode: a global state with a spinlock, the worker that
  builds the pool, and `/free-auto [on|off|status]`.
- `zig build roster-probe` — **the question that matters**: do I really have a plan
  B? It lists the providers with a key, how many free models each one publishes and
  the pool already sorted the way the wheel will use it. It lives in `src/` and not
  in `src/bin/` because its module path is the directory, and with the probe in
  `src/bin/` the `@import("agent.zig")` next to it falls outside the module. The
  only thing `build.zig` declares is `vaxis`: a file cannot be the root of two
  modules and `providers.zig` already is one of `agent`'s.

### The table that decides whether an error rotates

`agent.quotaVerdict(err, detail)` → `?roster.Why`. It is fine-grained on purpose,
because the **action** that corresponds to each row is the opposite one:

| error | verdict | why |
|---|---|---|
| 402 no credits | rotate | repeating the same thing is pointless |
| 429 rate limited | rotate | the model's quota, not the key's |
| 403 with the gate text | rotate | opencode's 403 is a GATE, not a config problem |
| 403 without the gate | **NO** | a model not available on your account |
| 401 | **NO** | it is the key: rotating would give a 401 on all 16 |
| 404 | **NO** | bad id, not quota |
| 5xx | **NO** | the model is not to blame: it is backoff |

Gate phrases that really exist (verified on 2026-09-30):
`can only be used from within OpenCode`, `Model access is disabled`,
`is only available on agentic harnesses` (openrouter; it does not matter that zode
is an agent, it is not in its app list), `not available on this account`.

And 400 = `error.BadRequest`, which is **not** retried: before it fell into the
`else` → `ServerError` → 3 retries with backoff to repeat a request the server had
already said it does not want.

### Three wiring things that are not obvious

1. **`Target` instead of consulting the global in three places.** The `pick` is
   REPLACED inside the retry loop; if the body, the url and the key each consulted
   the active provider, half the requests would go to the wrong place. There is a
   test that the key is the candidate's and not the active one's.
2. **The body is composed INSIDE the loop.** The body carries the model's name
   inside, so on rotation it has to be redone. With the body outside: the request
   went to the new provider/model with the old name inside, and openrouter answered
   a 400 `JSON parsing failed` three times, which made no sense at all.
3. **`nowMs()` needs `attachIo`.** `agent.io_global` is `undefined` until startup
   assigns it, and reading the clock from an uninitialized `Io` is jumping through
   a garbage vtable (a GPF, not a 0). It is the `Model.attachIo` trap.

## The visible plan (the `todo` tool)

The model writes the list and the user sees it above the input, without Ask Mode.
A COMPLETE list on every call (it replaces the previous one); it accepts
`items`/`todos` and `content`/`text`/`task`; an unknown `status` falls into
`pending` (the step is not wrong, it is mislabelled); more than 20 steps is an
ERROR and not a silent truncation. Done is drawn on one line. Cap of 6 rows
(`plan_max_rows`) and, if it does not fit, `+N more · 1/20 done`. `/plan` clears it.

A bug of its own that the tests caught: in `Plan.apply` the loop wrote
`self.items[self.len] = it` and `self.len` was only updated at the end, so **every**
iteration landed in slot 0: the plan was one repeated step, with uninitialised
garbage in the text (the `Item.text`s are fixed buffers).

## `/undo`

It undoes **files**, not messages: the session is append-only and rewriting it
halfway through a turn has no explanation. The snapshot is taken before each tool
that touches a file; `existed` is explicit ("it was not there" and "it was empty"
undo differently) and if the read fails for another reason **nothing** is
snapshotted. A ring of 8 turns, 24 files, 256 KB per file, 1 MB per turn; what
does not fit is marked and the message says so.

## `@file`

The content goes with the prompt, in a block at the end (not at the `@` itself, so
the provider's prefix stays stable). 4 files, 32 KB each, read as a **prefix** with
`readPositional`: `readFileAlloc(.limited(n))` does not clip, it returns
`error.FileTooBig`, and with that the big files were never injected. Only what goes
to the model is expanded (the session stores the prompt with its `@path`), and only
the **last user message**: the last message in the list is the `system`, because the
system prompt is appended at the end.

The scanner does not eat emails (`jorge@example.com` is not a mention: if there is
another `@` after the token, it is an email) nor trailing punctuation
(`@notes.txt,` is `notes.txt`), and it accepts bytes ≥ 0x80 so that
`@docs/guide.md` works.

## Three TUI bugs that only show in the pty

1. **`streamEnd` ate the worker's `dirty`.** `streamEnd` calls `drainPendingLocked`
   (so the assistant's text does not end up ahead of its tool) and that function
   lowered `dirty = false`: the worker pushed the error and then immediately erased
   its own request to repaint. On screen the old frame stayed, with the strip
   frozen on "streaming 3.9s" forever, until the user pressed a key. Now it is the
   DRAW that lowers `dirty`, after painting, and `streamEnd`, `setStatusWithMood`
   and `toolRunEnd` set it to true.
2. **The tick disarmed when idle, and a worker cannot wake the UI.** With the tick
   disarmed, whatever a background worker pushed (the free-auto pool, the model
   list) stayed in `pending` until a key arrived: the symptom was "the command
   does nothing". Now the tick re-arms ALWAYS and when idle it goes to 250 ms
   (`Model.tickIntervalMs`): the cost is a spinlock four times per second and
   **not** a redraw, which is what the "0 CPU when idle" note really meant.
3. **A dead turn left an empty paragraph** (`◆` alone in the history). `streamEnd`
   only stores the paragraph if there is text, trimmed.

## The memory bug family (five times this month)

- `pushInfoOwned` **takes ownership** of the text and frees it in `Model.deinit`:
  a literal there is an "Invalid free" (the palette), a `catch "literal"` is the
  same (`/free-auto status`), a `bufPrint` into a stack is a pointer to a temporary
  (the undo heading showed up as `�`), and **text from the turn's arena** leaves a
  dangling pointer that vaxis reads in the renderer → segfault (the `@file`
  notice).
- `pushInfo` **copies**: for text on the stack, or from an arena that lives less
  than the frame, it is the only safe thing.
- The same with `takeCheckpointOwned`: the first version did `deinit` and returned
  the copy with the `data` already freed.

## Diagnosis

- `ZODE_DBG_ERR=1` dumps the status + the first bytes of each response to stderr.
  That is how openrouter's 400 was read, the one that was eating the retries;
  without it, the TUI only said "HTTP 400".
- `zig build roster-probe` for the real pool.

## The sixth time: `catch "literal"` into `pushInfoOwned` (13 places, all fixed)

The section above says `pushInfoOwned` takes ownership of the text. The pattern
that had been written **13 times** in the repo was:

```zig
const msg = std.fmt.allocPrint(a, "…", args) catch "a literal";
pushInfoOwned(m, msg);
```

On the happy path `msg` is from the heap and nothing happens. With the allocator
**out of memory**, `msg` is a pointer to `.rodata`, `pushInfoOwned` takes it and
`Model.deinit` frees it: two failures that cancel out into "zode crashed and I
don't know why". It is a failure that only shows up when there is already another
failure, which is exactly when you cannot diagnose it.

**The fix is `Model.pushInfoFmt(fmt, args)`**: it composes AND owns the text, so
the mistake cannot be written. All 13 places use that.

And the worst of the 13 was in `tui.zig`, in `submitInput`:

```zig
const msg = std.fmt.allocPrint(ctx.alloc, "error: {t}", .{err}) catch "error";
self.pushInfoOwned(msg);
```

`ctx.alloc` is the **frame's arena**, which is reset on every frame and **is not**
the model's allocator. So `pushInfoOwned`: (a) put it in the queue and vaxis read
the bytes after the arena had been reset (a dangling pointer in the renderer) and
(b) freed it with a different allocator ("Invalid free" on exit). Both at once.

**The rule that comes out of here**: if memory changes hands, the *length* has to
be the one that was allocated. `providerEnvNames` returned `buf[0..n]` out of a
512-byte block, and `std.testing.allocator` treats that — rightly — as an
"Invalid free" of 33 bytes in a 512-byte block. A `Writer.fixed` is the wrong shape
for memory that someone else is going to free.

## Two error messages that do not tell the truth

An error whose job is to say *what to look at* cannot lie in the middle. Both
things that were found together, in the same message:

1. `ZODE_{s}_KEY` over `key_env[0]`, which **is already the whole name**
   (`ZODE_OPENROUTER_KEY`). It printed `check ZODE_ZODE_OPENROUTER_KEY_KEY`: a
   variable that cannot exist. And it only quoted the first of the list, so on
   opencode (`ZODE_OPENCODE_KEY` or `ZODE_API_KEY`) it sent you to the wrong place.
   Now they go **verbatim and all of them**.
2. The server's `reason` was thrown away on the 401, being the only branch that did
   so (the other five show it). Found with a real openrouter 401, which answered
   `{"error":{"message":"User not found."}}`: that is the **account**, not the key,
   and saying "key rejected" sends you to rotate a key that is perfectly fine. A
   401 is **not always** the key, and the server says so when it wants to.

## `@file`: a snippet with decorators eats the mentions

`@Override`, `@deprecated`, `@staticmethod`, `@import`… are tokens that pass the
mention scanner. With 8 slots, **seven decorators and the real `@src/agent.zig` was
already not being looked at** — measured, with no warning. And each decorator
counted as "not found", so the user saw a "1 not found" without having asked for
anything.

The filter (`looksLikePath`: a `/` or an extension) goes in `scan` and **not** in
`expand`, and that is the important part: if the filter were at the bottom, the
decorators would keep eating the scanner's budget and the real mention would keep
being lost. `expand` no longer counts against the budget but `scan` does, and that
is why the filter has to be at the top.

The cost: a bare `@Makefile` is no longer expanded. You write `@./Makefile`, which
also does not depend on where you are looking.

## The key precedence, which confuses debugging

A 401 in the TUI with the key **from `.env`**, when `~/.config/zode/auth.json` has
**another** one that does work. It is not a bug: the saved key wins over the
environment on purpose (see "The saved key was not used"), so testing with a clean
`HOME` **changes the key that gets sent**. What did come out of the mess is the
401's message, which then said "key rejected" without letting you see the server's
"User not found.".

To test for real you have to use the real `HOME`, or deliberately delete the
sandbox's `auth.json` and know that you are testing the environment's key.

---

# From "an agent that executes" to "an agent that collaborates" (2026-10-01)

Eight new things, and what was learned from each one. The `ask` one is what
changes the character of the whole thing; four of the others are about price
(time and tokens) and the last one is about saving tokens.

## 1. `ask`: the model asks you

It is THE missing piece. Before, the model either got it right or made it up, and
the only interaction was the yes/no permission on a command that was already
decided.

**Why the answer is a `tool_result` and not a new `user` message.** An assistant
message that asks, followed by a `user`, is not accepted by any provider: the user
turn has to follow a user turn, not an assistant with pending `tool_calls`. A tool
call parks the turn exactly where the API expects it, so the wire format does not
change and **every provider accepts it without a change**.

**The pure module (`src/lib/ask.zig`) is separate from the wiring** because what
goes wrong here is always the SHAPE of the question and, above all, the text the
MODEL reads back. That is testable with no TUI and no network, which is how it was
confirmed that `formatAnswered` never truncates the user's answer silently.

Three outputs, and each one says something different to the model:

| Output | What it tells it |
|---|---|
| `The user answered: X` | the user's words, verbatim |
| `declined_text` | "I will not answer that" → **decide yourself and say which** |
| `timed_out_text` | 5 min with nobody there → the same, but "you were away" |

A model told just "no" either stops or repeats the question. The only actionable
thing is "pick the most reasonable option, say which one you picked and why, carry
on". And neither phrase contains the word *stop*: the model reads it as
permission to give up.

**The dialog is NOT the permission dialog.** It is a copy of its shape (its own
lock, a sleeping wait with 1→20 ms backoff, an epoch to wake on) and not of its
code, because they are different questions with different timeouts, and sharing
them makes every change to one a change in the other's behaviour.

**The worker does NOT open the palette.** That is the rule that already cost two
segfaults (see "Detached workers"): the worker leaves the question in the `Model`
and the **draw** turns it into a picker. What you see in the code is
`askNeedsPicker()` inside `typeErasedDrawFn`.

**The strip has to show even when there is no turn.** `act_rows` counts
`act.ask`, not only `busy`. Without that the question was painted in the middle
with nothing saying why the app had stopped, and a parked worker with no clock is
**indistinguishable from the freezes this repo already paid an afternoon for**.

**The panel reserves its rows ALWAYS.** The first version reserved 4 rows under
the question and 2 when there were options, so a free-text question came out with
three empty rows under it: it looked like a broken panel. Now they are 2 fixed ones
(the key help and the clock).

**ESC means three things, and the ORDER is the whole design**:

1. Open question → "I don't know, you decide". It is **not** cancelling the turn.
2. Foreground tool → **kill the child** (see point 4).
3. Otherwise → abort the stream.

And `declineAsk` closes the dialog in the SAME frame. Without that the question
stayed painted for a few milliseconds after you had answered it, which reads as
"it did not catch my answer".

**The input in answer mode.** Enter answers instead of sending a prompt, and an
EMPTY answer is a valid answer ("you decide"): that is why the check goes
**before** the empty-prompt check, or you would send a turn with an empty `user`.

**The cap of 3 per turn** resets on every turn (otherwise a long session would
eventually be unable to ask) and on reaching the cap it **degrades into "you
decide"**, not into a broken turn. The turn's number of questions is in `/bench`.

## 2. Ask mode (read-only): shift+tab

`write`/`edit`/`bash` come back as a `tool_result` with a text that **says not to
retry** (otherwise the model repeats and the loop eats the iterations) and that
offers `ask` as the way out.

The decision is per TOOL, not by parsing the command: if it looked at the command,
`bash ls` would serve to find out what the model really wants to run, and the mode
could be bypassed. `bash` is blocked even when it only reads.

The mode is injected into the **system prompt**, not only into the tool's error:
otherwise the model plans a `write`, hits an error, reads it as a harness bug and
looks for the workaround. It always shows in the status bar, because a mode you
cannot see is a mode where "the model ignored my edit" cannot be told apart from
"the model did not try".

`Session.replaceSystem` exists for this: the prompt depends on things that change
during the session, and **adding** a second `system` is exactly the bug the agent
loop had (`[user, system, tool, system]`, and a 400 on the next turn). It is
compared before writing: on a stable turn it is a `memcmp`.

## 3. Background bash: `run_in_background`

A normal `bash` put the worker inside `std.process.run` for **30 s**: it could
not read a file, grep an error, or answer. The interesting work ("which of these
40 errors is mine?") happens **during** the wait instead of after it.

- `bash_output` is **incremental**: what appeared since the last call. Without
  that, an agent that polls pays twice for the same output and the context fills
  up with duplicates. The status (still running? exit=?) is **not** incremental,
  because it is short and it is what answers "has it finished?".
- The 64 KB cap **reserves room for the truncation notice from the start**.
  Without the reservation the notice can never be written: when you find out the
  buffer is full is exactly when there is no space left, so the message saying
  "you are not seeing all of it" is the one that gets lost.
- The id is a **counter, not a pointer**: a freed and reused slot cannot make id 3
  return the output of another job.
- The reader thread has **its own copy of the `Child`**. `wait()` mutates it and
  `kill()` sets its id to null, so sharing it with the registry is a race between
  `bash_kill` and the reader.
- The reader **never** frees the slot (it compares the id and nothing else): the
  model's teardown may have released the memory while the process was still
  alive.

## 4. ESC kills the child

`std.process.run` keeps the `Child` in its own frame and does not pass a handle to
anyone, so ESC only set a flag that `run` never looks at: a 30 s `zig build` kept
running, with the worker blocked inside and the CPU at 100 %. Now
`tools.runForeground` does the spawn by hand and publishes the pid.

`kill(-pid, SIGKILL)`, with the **negative pid**: an `sh -c "a && b"` has children,
and killing only the shell leaves the grandchild (`zig`, `npm`) running. The
process group is what gets killed. The foreground path deliberately does NOT set
`pgid` (the child shares our group and the negative would take zode down with it),
so there it falls back to the bare pid and kills the shell: that is the honest
trade-off.

And ESC marks **all background jobs** too. ESC means "stop", and leaving
something compiling in the background after pressing ESC is how you end up with a
warm laptop.

## 5. Tools in parallel

Only the ones that cannot observe each other are parallelised: `read`, `grep`,
`glob`, `list_files`, `web_fetch`, `web_search`. The criterion is not "they are
fast" nor "they usually do not conflict": it is that they do not write and do not
need to see the world afterwards. `bash` is out even when it looks like a read,
because it can write and the model may have asked for two `bash` where the second
reads what the first wrote. The test `isParallelSafe` ∧ `isWriteSafe` == ∅ pins
that the two lists do not contradict each other, because a tool in both would be a
security failure shaped like a feature.

What came out of it:

- **An arena per call.** The turn's arena is shared between the three and its
  `ArrayList` length is a **silent** race, not a crash.
- **Results in request order.** Ordering them by response time would be faster to
  look at and would make the same request produce different transcripts on every
  run.
- **Headers first, results after.** All the `⏺ grep(...)` lines go out before any
  `⎿ 12 matches`, so the history reads "these four things at once" instead of
  four unrelated pairs.
- **The wait does NOT count `m.workerCount()`**: that global counter includes the
  turn's worker, so waiting for it here would mean waiting for the turn to finish,
  which is waiting for this function. It is a counter **local to the batch**.
- The threads are detached (`detach`) and wrapped in `beginWorker`/`endWorker`,
  because on exit `waitWorkers` has to wait for them or `app.deinit()` destroys
  the `Io` while one of them is inside `process.run`.

## 6. Subagents (`task`)

The second big gap, and the biggest token saving. **Everything the main agent
reads goes into its context, and that context is sent again on every iteration and
billed every time.** A 40 KB `grep -r` is 10k tokens in the prompt of iterations
2, 3, 4… and what was useful was two lines saying which function to look at. The
subagent pays those 10k **once**, in a window that is thrown away, and returns a
paragraph.

Decisions that are not obvious:

- **It does not see the conversation.** Only the task's prompt. If it inherited
  the history it would inherit the tokens, which is exactly what this avoids.
- **Effort `low` always.** It is a bounded search, not a design, and there is
  nobody to impress. This is where the money is saved and no quality is lost.
- **Depth 1.** A subagent that can nest is a way of spending a hundred times the
  tokens by accident and cannot be budgeted.
- **Its tools are the read ones and ONLY those.** `ask` is out on purpose: a
  subagent asking from a thread that is not the turn's leaves the user not knowing
  which of the two agents is talking to them. What it needs the user to do, it
  returns as "you need to decide X" and the main agent decides.
- **A 24k budget, constant**, not derived from `ZODE_CONTEXT_LIMIT`: the subagent's
  window is disposable, and deriving it from the user's would make it 100k for
  someone with a big window.
- **Running out of steps is NOT an error.** The report it was writing is usually
  enough, and throwing it away because the search did not finish is the worse of
  the two options.
- One of its failures (no key, provider down) comes back as **text**, not as an
  error: the turn has to be able to continue, and the main agent needs to know it
  is its turn to search.

## 7. `/bench` and the iteration limit

`max_iterations` was 8, nobody knew how often it was reached, and "raising it to
20" was a bet in both directions. Now it is 12 and configurable with
`ZODE_MAX_ITER`, and `/bench` says **the percentage of turns that reached the cap**,
which is the number that decides.

`first token` is the mean and the p95 of the TTFT, which is what separates "the
model is slow" from "we made the request badly". The sample ring keeps the **last
64**: a p95 of the whole session describes a machine that an hour ago was
compiling something else.

The default limit went up to 12 because 8 was for a loop where each iteration is
an edit, and a real task is "read three files, grep twice, edit, compile, read the
error, fix it, compile" — 8 or 9 before even writing the final answer. And raising
it costs nothing in the normal case, because the loop ends on its own as soon as
the model stops asking for tools.

## 8. Skills

`.zode/skills/<name>/SKILL.md` (project) and
`~/.config/zode/skills/<name>/SKILL.md` (personal), with `name` and `description`
frontmatter.

**The whole design is: only the name and the description go into the prompt.** The
body is loaded with the `skill` tool at the moment the model decides it needs it.
The alternative — putting it all in — is how a project ends up with 40 KB of
instructions the model has already learned to skip, on every request, forever,
whether or not the task needs them. The `description` has to say **WHEN** to use
it, not WHAT it is: "after touching the drawing code in tui.zig" decides well;
"notes about pty" makes the model guess.

The project **overrides** the global one, they are not merged: a project skill
mixed with the global one is worse than not having it, because half the
instructions would be about another project.

No frontmatter works too (it is markdown and a dot) and then the name comes from
the **directory**, which is what actually exists on disk: a frontmatter `name`
that does not match the directory would make the tool call fail and the model has
no way to recover.

## Three things that hung on the way

1. **`readPrefix` returned a slice of its own stack** (`.zode-skills-test-N`).
   The fixtures were written to a garbage path and the six discovery tests failed
   with "found 0" for no visible reason. The eighth time round of the `&[_]u8{c}`
   family.
2. **`splitFrontmatter` blew up with a file that ENDS in the closing `---`.**
   Without a final newline, `nl` is 0 and the index went one position past;
   `rest[i..]` with `i > len` is a panic, not an empty slice. Every pure test had
   a final newline, so only the on-disk ones caught it — which is exactly what they
   are for.
3. **The smoke test did not wait after the last key.** It sent the `\r` and closed
   right away, so `/skills` was checked against a frame in which the app had not
   answered yet. A test that depends on that does not prove the feature, it proves
   the machine's speed. Now there is a turn of waiting before the ctrl+c.

And one design thing that came out while writing the tests:

**A question's `PickerItem`s are their own copies (gpa).** `closePicker` frees
them, and `askPickerChosen` receives a label the picker frees right after the
callback. Without the copy, choosing the first option is an "Invalid free". It is
the same bug the fuzzer found with the `+ connect` item.

## What has NOT been done

- **MCP**, on purpose (out of scope).
- **A cheap model router for the main turn.** It stayed in the subagent (effort
  `low`), which is where it is paid for without risk: sending the main turn to a
  small model can give a 403 as soon as that model is not available for the
  account, and that is an error you cannot see coming.
- **The model still cannot ask from a subagent** (by design, see point 6).

---

# Six reported bugs (2026-10-01)

All verified before and after: the one that can be reproduced with a test is
reproduced first, the fix is removed, and the test is seen going red.

## 1. ESC did not stop the processes: there was no group to kill

**The symptom**: "ESC does not stop the processes". ESC set the cancel flag and
killed the shell's pid. The shell died. **The grandchild did not.**

Measured with a probe that times `tools.runForeground` over `sleep 30 & wait`:

```
killForeground returned true
elapsed=30034ms term=signal      <-- 30 s: the sleep is still going
```

and in the process table, three seconds after the ESC:

```
PID    PPID  PGID  COMM
10174  10171 10171  escprobe
10179  826   10171  sleep      <-- PPID 826 = reparented to init. Orphan.
```

**The cause**: `kill(-pid, SIGKILL)` (the negative, to kill the GROUP) could never
work, because the child was not the leader of its own group: `std.process.spawn`
without `pgid` leaves the child in zode's group. So `kill(-pid)` failed with ESRCH
and the code fell back to the usual `kill(pid)`. The code's comment said "a shell
has children, that is why I use the negative", and the negative did not work: it
was the right intention with the wrong primitive.

**The fix**: `.pgid = 0` in BOTH spawns (the foreground one in `tools/` and the
background one in `bgproc.zig`), and `killTree` for the background jobs, which
before used `Child.kill` (a single pid) like everything else.

With the fix: `elapsed=700ms`, and neither the shell nor the grandchild is left.

What had to be written down:

- **Both spawns, not just the one that was seen.** The foreground and the
  background have the same bug and different entry paths.
- **`Job.pgid` apart from `child.id`.** The reader thread does `wait()` on its own
  copy of the `Child` and sets `id` to null; also the pid is recycled as soon as
  the child is reaped. `kill(-<recycled-pid>)` is killing a stranger.
- **`tools/esc_kill_pty.py`**: the only test that looks at the GRANDCHILD in the
  process table. And it looks at the grandchild, not the shell, for a reason that
  cost a round trip: the shell DID die without the fix, so a test that looked at
  it would go green with and without the fix. The marker is `sleep 301 & wait`
  (two pids) and it looks for the exact argv `sleep 301`. With `exec` the shell is
  replaced, one process is left, and the test distinguishes nothing.

## 2. `reasoning_effort`: the enum was the token ceiling

**The symptom**: "they do not infer the effort well, there are models that support
more".

**The cause** was two things at once:

1. `Effort` was an `enum(u32)` whose VALUE was `max_tokens` (`low = 4096`,
   `xhigh = 49152`). Effort and answer length were tied together: asking for more
   reasoning also shortened the answer, and asking for `low` gave 4096 tokens in
   TOTAL (thinking budget + answer), which cuts a response with tools in half.
2. `reasoningToken` sent `.xhigh` as `"high"` **for everyone**, and
   `familyForModel` only recognised o-series/gpt-5. So Gemini (`minimal`),
   gpt-5.1 (`xhigh`) and any model with levels of its own had no way to be asked
   for anything: the enum did not have those members.

**The fix**: `Effort` is an enum of LEVELS and nothing else. The ceiling lives in
`outputCeiling`, the thinking budget in `thinkingBudget`, and an
`effortSupport(model)` table decides which level actually goes on the wire.

`effortFor` degrades **downwards** and never upwards (going up is a 400), and
`/effort` says out loud what is really going out ("xhigh (this model tops out at
high)") instead of accepting it silently. The picker offers
`effortLevels(model)`, which is the SAME picture as `effortFor` — a test demands
that what the picker offers comes out exact, without degrading in silence.

`reasoning_effort` now goes out whenever the MODEL has it, not only for o-series.
And the clamp of `thinking.budget_tokens` against the ceiling happens in the place
that composes the body (the only one that knows both numbers), not in the caller.

### The table was verified against the DOCS, and the first version was FALSE

This is the important part, and it is a failure mode that **no test in this repo
catches**: a test that compares the JSON zode generates against the JSON zode's
own code says it should generate. If both are wrong, the test passes. I wrote the
table from memory, the tests went green, and when I went looking for the
documentation it turned out that three rows were invented:

| what I put | the reality |
|---|---|
| `xhigh` on `gpt-5.1` | `xhigh` is **only** for `gpt-5.1-codex-max`. On plain 5.1 it is a 400. |
| `minimal` on all of GPT-5 | `minimal` is **5.1 onwards**. On earlier GPT-5 it is a 400. |
| `minimal` on Gemini | `gemini-2.5-*` is `low/medium/high`. `minimal` is Gemini 3.5+. |

And a fourth, which is not about levels: Gemini calls the field `thinking_level`,
not `reasoning_effort`. The OpenAI name is sent because that is how zode talks
(`/v1beta/openai/`, OpenRouter), but the **values** are Gemini's.

The corrected table (verified against OpenAI's levels matrix and Google's
`thinking_level` table):

| model | levels |
|---|---|
| `kimi-k2.6` (no knob) | the field is not sent |
| `gpt-5`, `o3`, `o1`, `gemini-2.5-*` | low / medium / high |
| `gpt-5.1` | + none, minimal |
| `gemini-3.5+`, `gemini-3-flash` | minimal / low / medium / high |
| `gpt-5.1-codex-max` | + xhigh |

**The lesson**: a test that verifies how a payload is composed **does not**
verify that the server accepts it. For that you have to read the provider's
documentation, and the test has to have the "accepted" list written **by hand**,
not derived from the table it is proving. That is what `effortFor` does now: it
NEVER asks for a level the model does not document — it walks the whole model x
level combination against a separately written list of accepted ones. If the two
were derived from each other, the test would pass with both wrong — which is
exactly how the three failures got in.

### And the effort is decided ALONE, by model

Asked literally: "the harness should know, not me". In other words `zode` works
out the model's ladder and there is nothing to investigate:

- **`defaultEffort(model)`** is the step in the MIDDLE of that model's ladder, not
  a fixed `.medium`. The index is what decides, and the ladders are not all the
  same length: 3 levels → `medium`, 5 → `low`, 6 → `medium`.
- **`clampEffort`** is applied in `setModel`, that is **when the model changes**:
  an `xhigh` chosen on a codex-max becomes `high` when you switch to a
  `gemini-2.5`. Without this it degraded in silence on every request, with the
  status bar saying `xhigh` and the wire carrying `high`: two texts for the same
  thing and nothing indicating they are different.
- **`effectiveEffort(model, want)`** collapses `effortFor`'s `?Effort` into an
  `Effort`. The `null` ("this model has no knob") is not an error, but it forced
  every caller to remember that; now the request path does not have to know
  anything.
- In the `free-auto` loop it is resolved against **`pick.model`**, not against the
  active model: that loop rotates between pool models and each one has its own
  ladder, so using the active model's would send a level the candidate does not
  know.
- The status bar and `/effort` show the **effective** level, not the preference.
- The picker is titled `effort · <model> goes up to <level>` (or "no effort
  control"), which is the automatic made visible: you do not need to know in
  advance that this model reaches `high` and another one reaches `xhigh`.

**The case that shows the index is not a detail**: `gemini-3-pro-preview` has no
`medium` (docs: `low` and `high`). With a literal `.medium` default it would
receive a level that does not exist and the first turn of a new session — where
the user has not touched `/effort` — would eat a 400. It has its own row in the
table (`no_medium`) for that.

Verified in the real pty with `space-bunny-free`: the picker opens with the title
`effort · space-bunny-free (no effort control)` and offers `low/medium/high`,
without `minimal` or `xhigh`; and `/effort xhigh` answers "this model has no
effort knob" instead of accepting it silently.

## 3. The tool guide disappeared with `AGENTS.md`

**The symptom**: "I asked it to find me a games page and it went off to use Bash".

**The cause**: `systemPromptBase` returns the project's `AGENTS.md` **instead of**
`default_system_prompt`. And the routing table ("anything on the INTERNET belongs
to web_search/web_fetch, NEVER use bash") lived INSIDE
`default_system_prompt`. So in any project that has an `AGENTS.md` — the normal
case — the model saw **not one** routing rule. With the shell available and no
table, `curl` is the obvious way to ask the internet something.

The tool routing rule does not belong to the PROJECT. An `AGENTS.md` says what
the code is and how to work on it; it is not its job to decide that this harness
has a `web_search`.

**The fix**: `tool_routing_prompt` is its own constant, it is composed ALWAYS
after the base (whichever was chosen), and there is a test that puts it into an
`AGENTS.md` cache on purpose and checks it is still there.

Measured in the real pty, with the exact prompt from the report: before
`bash(...)`, now `web_search`.

## 4. `@` did not show the file list

The popup existed, filled up and was painted. What did not exist was **saying there
was more**: with 10 entries in the directory and `max_visible` = 6 you saw 6 and
nothing else, with no hint at all. From outside that is not a truncated list, it is
a directory that apparently has six things in it.

The popup's footer now says the total and what is missing
(`10 matches · +4 more`), in the two popup rows that were already reserved. A
picker that lies about its size is worse than no picker.

The content expansion (`@file` -> the file's text in the prompt) already worked and
was checked with real files from this repo.

## 5. The banner and the first prompt read as one block

A blank row does not separate a 5-row drawing from the user's words: the prompt
looks like the last line of the logo. Now there is a **rule** under the banner
(the same `─` mark the popup and the input box already use), not a blank row. It
costs the same and says "the header ends here" without spending two more blank
rows.

`bannerRuleLine` splits the `─` into 255-column chunks because `CellRun.w` is a
**u8**: a single wider run stops being drawn halfway across a wide terminal and
looks like a rendering bug.

## `src/lib/`: the modules that are tested without starting the app

Since 2026-10-02 the tree has two folders and the line between them is a single
one: **can this module be tested without a TUI and without the network?**

```
src/     main, tui, agent, tools (the dispatcher), chat, bgproc, palette,
         session, config, compaction, cache_stats, roster, free_auto
src/lib/ everything else: readcache, project, prompt, sleep, skills, skillstore,
         mentions, markdown, highlight, web, models, providers, provider,
         http_client, subagent, ask, plan, checkpoint, editor, bench, clean,
         regex, mascot, theme, zjsonl, verify
```

The reason it is `lib/` and not `core/` or `pure/`: "pure" describes what the
module DOES and `lib` describes **how it is tested**, which is what matters here.
A module in `lib/` is imported with `@import("lib/x.zig")` from above and with
`@import("x.zig")` from inside the folder (Zig's paths are relative to the file),
and that is why moving one from inside to outside **does not touch its internal
imports**: if `markdown.zig` imports `highlight.zig` and both move together, that
line does not change.

Three modules that do NOT move even though they look like `lib`, and why:

- **`src/tools/`**: half of its tools are pure, but the dispatcher receives the
  background process registry, which lives in the `Model`. It could be split into
  `lib/tools/*.zig` + a dispatcher above; it is not done because it would be the
  first move *within* a file that is also growing.
- **`roster.zig`**: it depends on `config.zig`, which already depends on the chat
  client.
- **`compaction.zig` and `cache_stats.zig`**: they depend on `chat.ChatMessage`,
  and that type is part of the wire format. Importing the whole client to have the
  type would be worse than leaving it up top.

And the one that stays in `src/` on purpose although it only uses the network:
`roster_probe.zig` (it needs the module's path = the directory, see below).

`src/bin/` are helper executables declared as separate modules in `build.zig`
(`tool-test`), and that is why they import by **module name**
(`@import("tools")`) and not by path. `tool_test.zig` was broken since `execute`
changed signature: nobody ran it, and a `zig build tool-test` that does not compile
is the fastest way to stop anyone from ever running it again.

---

# The `ask` modal: two widgets on top of each other (2026-10-02)

The symptom was "the texts come out all wrong and you cannot tell what are
options". The cause was not the text: they were **TWO widgets** painted one over
the other.

- `drawPicker` (tui.zig) was painted BEFORE and `drawAskPanel` AFTER, and the
  panel clears its rectangle with `theme.code_bg`. The geometries guarantee the
  overlap: `top = (height - box_h) / 2` against `y0 = (height - box_h) / 4`, and
  the panel is also the WIDER one (`min(max(q_cols+8,44), width-4)` against
  `min(width-4,64)`). At 80x24 the panel's border landed exactly on the `Other…`
  row.
- The panel **never painted the options**: `snap.options` only decided what help
  text showed. There was no way to understand them, because they were not there.
- `desc` ("recommended") was painted with the SAME style as the label, so it
  looked like part of the option. And `theme.selected` was bold+blue **without a
  background**: the selected row had no background.
- header, hint and clock used `brand_faint` (#3b4261) over `code_bg` (#1a1b26):
  1.9:1. The only legible thing in the panel was the question.
- `wrapTextToRows` did not look at `\n`, and the tool's schema asks for
  "recommendation + reason" (multiline): an interior `\n` was painted as a raw
  byte and vaxis writes it as is.

**Fix: a single widget.** The options are painted INSIDE the panel, numbered
(`▸ 1 postgres ← recommended`), with a real background and `Other` as the last
row. The modal picker for `ask` was removed (it was a menu with filter and scroll
for a list of 5 items that neither fits nor overflows). `ask_sel` lives in the
Model; `↑↓` move it, Enter answers.

Three more things that came out and were also bugs:

1. **The free-text input did NOT answer the question.** With a question with no
   options, nothing set `ask_typing`, so the panel said "type your answer below"
   and the input was in normal prompt mode: sending text **started a new turn**
   instead of answering, and it queued up behind the parked worker. Now
   `submitInput` looks at `askActive()`, not `askTyping()`.
2. **`wrapTextToRows` splits on `\n` first** (now), and each line is clipped with
   `putClipped` against the BOX and not against the screen. Before, `putText` only
   limited to the terminal's width: a 120-column option in a 64-wide picker was
   painted 56 columns outside its own border.
3. **The panel had uncapped height**: a long question in a narrow terminal covered
   the input, which is the only way to answer. Now it is clipped to the screen and
   says `… N more lines of the question`.

Contrast: `theme.brand_faint` is for LINES (borders, rules), never for text.
`theme.hint` (#7a8399, ~4.5:1) is for secondary text you have to be able to read.
`theme.selected` gained `.bg`: a highlight with only `bold` cannot be seen at 60
columns wide.

# The input: two different wraps (the "I don't know what I'm typing" bug)

`input_h` was computed with `ed.displayLines(text_w)` (which counts soft wraps)
and `drawInput` split with `splitLines` (only `\n`) and passed each line to
`putText`, which **cuts at the border without warning**. Result: an 8-row box,
the text on one line disappearing to the right, and the cursor anchored at
`col = 2 + accumulated_width`, outside the surface. Zero tests: the multiline ones
use `"a\nb\nc"`, which does pass.

Now there is ONE implementation in `editor.zig`:

- `RowIter` — hard breaks first, then **word** wrapping (with a hard cut for a
  token longer than the row, because a path has to fit).
- `displayLines` = count the iterator's rows (no alloc).
- `rowsInWindow(first, want)` = only the rows that get painted. A 256 KB paste is
  ~6500 rows and the box holds 8: counting them all and storing eight would
  allocate the other 6492 on every frame.
- `cursorRowCol` = (visual row, visual column). `cursorLine` counted `\n` and
  returned a LOGICAL index used as a row: that is where the off-screen caret came
  from.

The width is `width - 3` in layout and in painting (the real region goes from
column 2 to `width - 1`), and `displayLines` measures with
`theme.graphemeWidth` like the painter does (before it used `cp >= 0x1100`, which
does not match CJK, emoji or combining marks).

`editor.Measure` receives the caller's `Step` because the Editor does not know what
a grapheme is (that is `vaxis.unicode`) nor how much it measures in THIS terminal
(`ctx.stringWidth`, which depends on what vaxis negotiated). Guessing either of
the two is how the wrap and the painting get separated.

# Scroll: the anchor was an absolute line (2026-10-02)

`anchor` was an absolute line index. A paragraph's height is an **ESTIMATION**
until it is parsed, and parsing replaces it with the real one. So the same line
number meant one thing before the parse and another after: the view jumped right
when the parse entered the window, which is while you are scrolling. The
convergence loop (`layoutFor`, 4 passes) hid it in the same frame, but the jump had
already happened.

Fix: the anchor is **(paragraph, offset)**, and the line is derived from the
CURRENT heights (`anchorLine` / `setAnchorLine`). If the correction lands in a
paragraph above, the line is recomputed and the text you were reading stays where
it is.

The detail that makes it work: `computeVisible` **only** re-derives the anchor when
it runs **out of space** (line > `max_offset`). Being re-derivable in any other
case is the original bug with another name: a correction above shifts the anchor's
line, and converting that shifted line back into (paragraph, offset) lands in
ANOTHER paragraph, so the reader moves exactly what the fix was supposed to
absorb.

On the way, `estHeight` counts the fences (3 rows each: blank + chip + blank),
which was what the estimate was furthest off on.

Tests: "correcting a height does not move the text", "reading above, the text
keeps arriving without moving the view", "down and up returns to the same line",
and the wheel does not overflow the `usize`.

# Markdown and the timeline: half the parser did not exist (2026-10-02)

`parseLang` distinguished **two** things: code block and "the rest is prose". Zero
lists, zero quotes, zero dashes, zero links; `*italic*` and `~~strikethrough~~`
came out literally. And `md.prefix(kind)` went **only on the first row** of each
paragraph, with a 2-space continuation indent as wide as the marker: a 6-row
result had one identifiable row and five that looked like a warning.

What there is now (and what is deliberately NOT there):

- **Gutter**: the continuation carries `│` (`theme.gutter`) in the indent column.
  One glyph per row and the row is still attributable to its block.
- **Minimal hierarchy**: `-`/`*`/`+` → `•`, `N.`/`N)` keeps the number, the model's
  indent becomes visible indent, and the body goes through the normal inline
  path (an item's `**bold**` is still bold). `>` is a bar with its own style. A
  heading puts a blank row in front (unless it opens the paragraph).
- **A real background in code blocks**: `applyCodeGutter` painted `code_bg` only
  on the final padding, never behind the text, so it came out as a dark stripe of
  variable width in any terminal whose background is not #1a1b26. The code's
  comment said it did.
- **Heading ≠ diff hunk**: both were `bold + fg(4)`, the same blue as the user's
  `›`. Now the heading is `brand_hi` and the hunk has its own style.

The invariant that does not break: concatenating the segments gives the original
line.

# Cache: on OpenAI the tools were NOT cacheable (2026-10-02)

OpenAI's prompt cache is indexed by the **literal prefix** of the body, and the
prefix stops being served at the first byte that changes. The body was
`{"model":…,"messages":[…],"stream":…,"tools":[…]}`: since `tools` went AFTER the
`messages` array (which changes every turn), those ~16 KB of static schema fell
outside the cacheable region in **every** request. Putting `tools` before
`messages` brings them in all at once. The order of a JSON object is the only
thing that decides this, and it is easy to undo by accident: there is a test that
looks at the order and that parses the body.

In Anthropic, 3 fixed breakpoints with the third on the LAST message forced a
rewrite of the whole prefix every turn (the cache is read at the breakpoints, not
continuously). Now there are 4 (the API's cap) with a **rolling** pair: the last
two messages. The older half stays on a breakpoint the next turn does reach, so
it is READ and only the new segment is written.

`cache_creation_input_tokens` was not parsed, so `/cache` only showed reads. A
prefix that is rewritten every turn has a pretty hit rate and keeps billing the
whole prefix: **`writesPerRequest` above 0.5 in a long session means the prefix is
not stable**.

And the **order of the system prompt is the cache**: what changes invalidates what
comes after. The read-only notice (4th of 6) made a `shift+tab` also rewrite the
skills list and the location lines. Now the order is by frequency of change: base
· routing · verification · ask · skills · location · (read-only last).

**Measured or not measured**: in this environment the hit rate comes out 0% with
OpenRouter's free router because every request lands in a different upstream model
(the prompt tokens vary between 2792 and 3273 for the same prompt). The `tools`
order change is correct according to the documented semantics, but here you cannot
see a win.

# Expensive verification: the harness decides, not the model (2026-10-02)

The complaint: "opencode and claude write scripts to verify things and take
forever to finish a task". Two halves:

1. **`verification_prompt`** (its own constant, like `tool_routing_prompt`, because
   an `AGENTS.md` replaces the project prompt): verify with the narrowest command
   that would break if you were wrong; do NOT write a harness/pty/fuzzer unless you
   are asked for one; put the long ones in the background and keep working; do not
   repeat a verification that already passed with the code unchanged; if it fails,
   fix the cause and do not loosen the check.
2. **`src/lib/verify.zig`** — a pure, tested table. A foreground `bash` that
   matches a known verification (`zig build`, `npm test`, `pytest`, `cargo test`,
   `go test`, `fuzz`, `*_smoke.py`…) **starts in the background even if the model
   did not ask for it**, and the result tells it to keep working and do a
   `bash_output` per step.

The three details that cost something:

- **`maketar` is not `make`**: the "anywhere" rules look for the WHOLE word, and
  `.`, `/`, `-` and `_` are boundaries. With a `.` inside the word, `fuzz` did not
  match `fuzz.py` and `smoke.py` did not match `pty_smoke.py`: exactly the two
  cases the table exists to catch.
- **`cd x && cmd`**: the separators are ALL of them. With `&&` it ate the second
  `&` and the comparison never found anything — which is the case the function
  exists for.
- **Two escapes, and they are deliberate**: an explicit `timeout_seconds` means the
  model knows what it is doing (it chose a number for THAT command), and
  `ZODE_AUTO_BG=0` turns it off for someone who would rather watch it hang.

And what is NOT automated, on purpose: `git commit`, `docker build`, a server.
Sending them to the background with nobody polling them is worse than being slow.

# `/free-auto`: it existed and could not be found (2026-10-02)

"I cannot see the auto-free-model command". It was in the table, but it was the
**last item of the Session group** among twenty others, with no alias and no
state. Now:

- its own **"Free models"** group, third in the palette (before: `Session`).
- the `/free` alias.
- the hint says the STATE: `on · 3/8` when it is active. Seeing the state in the
  palette is what says the rotation is running without having to ask.
- connecting a key **rebuilds the pool**: the list was built with the providers
  that had a key at that moment, so connecting one afterwards left the rotation
  offering the models of the old set.

And the pool had a problem that `zig build roster-probe` shows: it offered
`google/lyria-3-pro-preview` (music), `lyria-3-clip-preview` and the `clip-*`
(embeddings) as "the model to write code with". The turn fails on the first token,
the error is attributed to quota and it rotates — to the next image model.
`models.isConversational(id)` filters by name (it is the only thing several
providers publish): embeddings, images, video, audio, moderation. It is a filter,
not a guarantee, and getting it wrong costs a rotation.

# `tools/pty_smoke.py`: what the emulator CANNOT check

Found by measuring, not by assuming: **the text typed into the input is not
readable in the smoke test**. vaxis redraws DIFFERENTIALLY (it moves the cursor and
patches cells) and this emulator concatenates the byte stream, so the last redraw
wins by luck: typing "a" and then "b" three seconds apart comes out as "a"
followed by a gap where "b" should be.

That is why the new long-prompt case checks that **nothing is lost** (that the
beginning comes back in the history after Enter) and that the app does not break;
the real wrapping is pinned by the `drawTest` tests, which read the surface cell by
cell. Trying to sharpen the emulator for this is endless work: the honest
alternative is `tmux`, as is already done.

---

# Parallel subagents, `!` shell, and the three things that limited the rest (2026-10-02)

## Parallel subagents: first `chat.zig` had to be de-globalised

`task` was intercepted BEFORE the parallel batch, so three `task` calls in one
message were three sequential waits, and each subagent is a full agent loop (up to
8 iterations of its own calls). The safety criterion was already written and was
met: `subagent.tool_names` are read-only.

The real blocker was four module globals that a parallel subagent stomps on:

| Global | What happened |
|---|---|
| `chat.last_usage` | two requests interleaving into one `Usage` → `/cache` is fiction |
| `chat.last_error_buf/len` | two failures interleaving → each turn reports the other's error |
| `chat.cancel_current` | the subagent that **started** erased the user's ESC |
| `bench.subagents` | `usize += 1` from N threads is a lost update |

The fix is not a lock: it is that **the state belongs to the REQUEST, not to the
module**. `StreamCtx` now carries `usage`, `err: ErrBuf`, `retry_after` and
`mirror_globals: bool`. The turn the user is watching publishes to the globals; a
subagent does not, and it also **does not call `clearCancel()`**: ESC is the user's
signal and it stays set so that everybody obeys it.

Two traps that came out:

- `setServerMessage` PARSES the `"message"` key out of a JSON body. The error path
  already had the message extracted, so handing it over stored **nothing** and the
  user saw an empty error where there was one. They are two functions:
  `setServerMessageInto` (parses) and `storeErrText` (stores).
- `streamRaw` cleared `last_usage` and `last_error` on ENTRY. With that inside the
  request, two subagents no longer stomp on each other: each one starts its own.

The cap is **3** (`ZODE_TASK_PARALLEL`, `1` = in series). Three streams against the
same key are deliberate concurrency; six are a self-inflicted 429. The parallelism
is by WAVES of `limit` threads, not "N threads and sort it out": the pending
counter IS the semaphore.

And there is a test that warns about the obvious: **the tool's description says
that several can be sent**. A capability that is not in the schema does not get
used.

## `!cmd` in the input

It runs the command and puts the output **into the context**, with no turn and no
token: `$ git status` + the output, as a session `user` message. The model has it
the next time you type.

What it CANNOT be: running it on the UI thread. `submitInput` is called from the
event handler, and a foreground command there freezes the whole app (the same bug
as the permission dialog, and the same answer): a worker, `beginWorker` /
`endWorker`, and the result goes in through the `shell_out` queue that the **draw
drains**. The session append happens in the drain, on the UI thread, because the
session (its `ArrayList` and its file) has one owner and is not thread-safe.

## Three things that limited the rest

**1. Tier-2 compaction DID NOT RUN IN THE TUI.** It printed "context budget
reached: summarizing older turns…" and never did it again: `summarizeTurns` had a
single caller, in `main.zig`. So the ctx% climbed with no brake until the body
outgrew the 1 MiB buffer and the turn died with a writer error. The announcement
was a lie. Now it runs before the request, **once per session** (retrying every
turn is a wasted request per turn forever) and the body is composed from the
already-summarized list — because composing it from `comp.msgs` made all of this a
silent no-op.

**2. Tool errors came back to the model as Zig names.** `allocPrint("{t}", .{err})`
gave it the literal `"BadArgs"` or `"UnknownTool"`. A model cannot recover from
that: it does not know which argument failed, whether the tool exists, or what the
schema asks for. `tools.describeError` says what happened **and what to do**, and
for `UnknownTool` it includes the list of tools that do exist.

And a tool call with invalid arguments **was not discarded in silence**: it is
emitted anyway so the executor reports it. Before there was no tool result, no
error, no history line, and the turn ended as if the model had only sent prose.

**3. `web_search`: the snippet was not the neighbouring result's.** It was
searched for from the end of the title to the **end of the document**, so a result
with no snippet of its own got the next one's, and the model read a description
that had nothing to do with the title above it. Now the search is bounded to the
block. And if `html/` does not parse, `lite/` is tried (another page, other
classes) before giving up: a layout change on one endpoint becomes a retry, not a
"there is nothing about this".

## A ctrl+d that exited the app

`tools/scroll_repro.py` (a pty reproduction script, not versioned) failed on one
case: "ctrl+d (half page down) redraws". It was not the scroll.

`ctrl+d` with an empty input was **EOF**: `ctx.quit = true`. And an empty input is
the NORMAL state when you scroll: you scroll up to read something, press ctrl+d to
come back down, and **zode closes**. `/help` documents "ctrl+u / ctrl+d = scroll
half a page" and the status bar says "ctrl+c exits": the app contradicted both of
its own strings, and the exit key was the one advertised as a scroll.

The scroll handler was AFTER the EOF one, so the EOF one always won. The exit is
**ctrl+c**, which is what both places say.

The test that pins it does "up and then down" instead of "down moves": where the
end of the scroll is depends on which paragraphs have been laid out (the rest are
still at their estimated height), and a test that pinned an absolute line would be
a test of the estimates.

## Verification

`zig build test` (515), `tools/pty_smoke.py` (with three new cases: `!cmd` runs
and leaves the input free, the long prompt is not lost, and `/free-auto` is found
by typing "free" in Ctrl+P) and `tools/scroll_repro.py`.

---

# The split tree: `src/tools/`, `commands.zig`, `lib/prompt.zig` (2026-10-03)

`agent.zig` was 7112 lines with 181 functions and 38 module globals, and
`tools.zig` was 1822 lines with an `if (name == "read") … else if (name == "write")`
that is a table of contents disguised as a file. Everything green before: 515
tests.

## `src/tools/`: one tool per file

It was split with a script that moves **blocks**, not by retyping: 1800 lines of
code that already works, retyped, are 1800 chances to write something that compiles
and means something else. The script **refuses to run if any declaration has no
destination**, which is the only reason I trust the result.

Three things came out on the way and cost some time:

1. **Counting braces without looking at literals breaks the whole parser.**
   `looksLikeHtml` compares `head[0] == '{'`, and counting that brace as structure
   made the extractor swallow **half the test table** forwards. It shows up as
   "NOT FOUND" for ten functions that are all there. `brace_delta` now ignores
   strings and char literals.

2. **A one-line declaration has to end on its line, and the comment eats it.**
   `const max_tool_output = 16 * 1024; // output budget per tool` does NOT end in
   `;`, it ends in the comment, so the matcher ran on to the `};` of the **next**
   declaration and `ToolDef` disappeared with it.

3. **Shared helpers stop being private the day there are two files.**
   `getStr`/`getInt`/`getBool`, `max_tool_output` and the `.zig` walker were private
   inside an 1800-line file and now different tools use them. `walkZig` lives in
   `common.zig` and not in `glob.zig` because `grep` walks the project with it too.

**A test that calls `execute` is testing the DISPATCHER**, not the tool, and that
is why they all live in `dispatch.zig` even though they name a tool. The ones that
test a helper go next to it. All 30 are still there.

### The `tools` module of `zig build tool-test`

`zig build tool-test` **did not compile**, and AGENTS.md already said nobody ran it
— which is exactly how something breaks and stays broken.

The cause is a Zig rule that cannot be negotiated: **a module cannot import
outside the directory of its root file**. The tools are in `src/tools/` and need
`bgproc`, `readcache`, `regex` and `verify`, which live in `src/`. With the module
rooted in `src/tools/` those are imports from outside the module and Zig rejects
them with an error that mentions neither the module nor the path.

The solution is to root it **one level up**, at `src/tools_root.zig`, which only
re-exports the dispatcher. Worth testing here: a probe binary already did it, and
that is why it works. **A relative import resolves against the file that imports,
not against the module's path**: that is why from `src/tools/dispatch.zig` you need
`../bgproc.zig` and not `bgproc.zig`.

Also `@embedFile("tools.zig")` in a `bgproc` test: `zig build` does not compile it
and `zig build test` does, so it only failed once the file moved.

## `commands.zig`: `submit` stays

The pattern that makes this possible without an import cycle: **`submit` STAYS**
in `agent.zig`, because it is the only function that decides whether a line of
input is a command or a chat (a chat starts a worker, a command runs on the UI
thread) and because it is what the TUI calls. Everything below it is local work.
`commands.zig` imports `agent.zig` for the shared helpers and `agent.zig` calls
into it: **one edge, not two**.

**`/effort` and `/yolo` did NOT move**, and the reason is worth writing down: they
**write agent state** (`current_effort`, the yolo flag). A file that imported the
other one to write would be the cycle, and the way out is not a `usingnamespace`,
it is deciding which side owns the entry point.

## `lib/prompt.zig`: the system prompt text

Three string constants and nothing else: the prompt, the tool routing table and
the verification rule. They were 370 lines of `\\`-string in the middle of a file
with 38 globals, and they are **the only piece of this repo where "did this
change?" is a question worth asking out loud**, because they are the biggest
stable prefix in the request and that is what the provider's cache indexes.

Pure, so it goes in `lib/`: a test reads the prompt with no TUI and the ORDER of
the blocks is asserted directly. Two things that are easy to undo by accident:

- **Each block is separate because a project's `AGENTS.md` REPLACES the built-in
  prompt.** When the routing and the verification lived inside, every project with
  an `AGENTS.md` — the normal case — sent **not one** routing rule, and the only
  way it had to ask the internet was `curl`.
- **The order IS the cache.** What changes most often goes last: the cache is read
  up to the first byte that differs, and read-only mode (a `shift+tab` in the
  middle of the session) at the top invalidated the skills list and the location
  lines.

## `agent.zig` is 6230, and the loop stays inside

What did NOT move is the agent loop, and that is deliberate: it is **what
everything else is a helper of**. Splitting it would give files of the same size
with the same seams, and the big file that remains is the one that really has 181
functions sharing 38 globals.

## A test caught an improvement to the art

The pty smoke and the Zig test had the **old banner** written by hand. Someone had
improved the glyphs (the `D` with its right stroke, the `E` with its crossbar) and
had not updated the expected art. The test was right to fail: the improvement is
what makes `O` and `D` stop being the same box twice, which is exactly the failure
that AGENTS.md says motivated the banner's v3 design.

Box-drawing art is a **map of cells**: if the rows do not land on the same columns
there is nothing to read, and comparing the **whole** row is the only thing that
tells `█████╗` from `███████╗`.

## Verification

515 tests, `zig build tool-test` **works** (it had not compiled for a long time),
the pty smoke and scroll_repro green.

---

# Ultrafast, minus the OpenAI part (2026-10-05)

Six commits. Everything measured in a pty or in a probe that measures the floor in the
SAME process, because "faster" without a number is a wish.

## Where the 1 second was, and where it was not

`ZODE_DBG_BOOT=1` prints the startup breakdown to stderr. The probe lives in
`agent.zig` and not `main.zig` because `tui` has to reach it from the draw function.
It keeps its OWN `Io` and its OWN t0 rather than the agent globals: the first mark sits
inside `vxfw.App.init`, BEFORE `environ_global` and `gpa_global` are assigned, and a
probe reading a global that is still `undefined` prints nothing at all — which is
indistinguishable from "the marks do not fire" and cost a round trip.

    vxfw.App.init             0.95 ms
    initProjectInfo           1.46 ms
    loadUserConfig            1.51 ms
    bootstrapSession          1.52 ms
    initFreeAutoFromEnv       1.55 ms
    app.run start             1.55 ms
    first frame drawn      1005.91 ms

ALL of our startup is 1.55 ms. The other 1004 ms is inside `vxfw.App.run`: vaxis calls
`vx.queryTerminal(tty.writer(), .fromSeconds(1))` with a hardcoded second, and the wait
ends ONLY on a DA1 reply (`Loop.zig` wakes the futex in the `.cap_da1` branch and
nowhere else).

`ZODE_TERM_QUERY_MS` (default 250, 0 to leave vaxis alone) bounds it with a thread that
calls `std.Io.futexWake(vx.io, &vx.query_futex, 1)` — the same call vaxis makes when a
DA1 arrives, only on a timer.

    terminal answers, cap on        17.65 ms
    terminal silent,   cap on      273.25 ms
    terminal silent,   cap off    1016.42 ms

Three traps in that work, all of them reusable:

- **A plain `query_futex.store(1)` does NOT wake the wait.** It changes the value the
  waiter compares against and the full second still runs, because `futexWait` goes
  through the `Io` vtable, which keeps its own waiter bookkeeping. Only `futexWake`
  unblocks it.
- **The mark belongs in OUR `drawFn`.** It started after `app.run`, which measures when
  the user QUIT — and it printed "first paint" on a line whose number was the length of
  the session.
- **The probe's stderr must not share the pty.** The marker arrives in the middle of
  vaxis's redraw, so an anchor on the start of a line finds nothing while the marks are
  firing.

`tools/pty_smoke.py` takes the SAME 1m31s with the cap on and off: its wall time is its
own `drain()` budgets. The cap's benefit is the user's blank screen, not that suite.

## Exit: `quitFast`

    idle                      0.018 s  ->  0.018 s
    with a turn in flight     0.767 s  ->  0.048 s
    with a background job     1.470 s  ->  0.042 s

Two costs: `waitWorkers(2000)` counts SPINS (`budget_ms * 200` yields), and
`bgproc.deinit` had a hardcoded `killAll(..., 1000)`.

`std.process.exit` skips every defer, so nothing is freed while a worker might still be
inside `io.async` — the segfault the wait was added for. Only three things still have to
happen: children die, `chat.cancel_current` is set (the SSE loop polls it), and the
session's last append is on disk. A half-written last line costs ONE append: the loader
already skips what it cannot parse.

**The half that is easy to forget is the FOREGROUND child.** A `bash` without
`run_in_background` keeps its pid in the foreground slot, not in the job registry, so
`killAll` walks past it. Measured: a `sleep` survived ctrl+c, 0.05 s after the exit.
`tools/esc_kill_pty.py` now has a second case for this.

In that script: `BINARY` is absolute from the start, because one case `chdir`s before
`execv` and a relative path made the child die with FileNotFoundError — which the "the
grandchild never started" SKIP swallowed into a green test.

## `bash` over the cap was DEAD

`runForeground` returned `error.StreamTooLong` past 16 KB, with a comment saying why:
"a tool result that stops mid-line looks to the model like the output ended". Sound
reasoning, and the consequence was that `cat`, `ls -laR`, `git log`, a `grep -r`
through the shell and the output of `zig build` all returned an ERROR. No rephrasing
gets a file under 16 KB.

Now it truncates and says so, which is what `bgproc` has always done for background
jobs. `Foreground.term` is OPTIONAL because `Child.kill` REAPS: it waits and clears the
id, so the `wait` that would report the term cannot follow it (`wait` asserts
`id != null`; without the assert it comes back as `error.Unexpected`). So `bash` prints
`exit=(stopped at the tool's output cap)` instead of inventing `128+9`, which reads to
the model as a crash it caused. A test runs `yes` and asserts the call returns in under
5 s with a 30 s timeout: that is what proves the child died.

## `zig build shell-probe`: there is nothing to win on a shell call

    case                                child    through OUR overhead
    no output                          3.40ms     3.46ms      +0.06ms
    8 KB of output                     4.62ms     4.83ms      +0.21ms
    512 KB of output (truncated)       5.33ms     4.99ms      -0.35ms

Our overhead is under a third of a millisecond and NEGATIVE in one case, which is what
noise looks like. A `bash` call costs what `/bin/sh` costs. A probe that reported "8x
faster shell calls" for this code would be measuring something other than zode.

The probe's loops are INTERLEAVED on purpose: measuring the floor for 30 rounds and
then the tool for 30 charged all the process-creation warmup to the first one and came
out as our overhead being negative (18.5 ms through the tool against a 20.7 ms "floor").
A number below the floor is not a result, it is a warmup.

## Compactación configurable

`ZODE_COMPACT=off|elide|full`, `ZODE_COMPACT_PCT=10..95`, `/compact [off|elide|full|default]`.

`elide` exists because tier 1 replaces OLD tool results with a marker and costs nothing
(no request, no tokens, and the session file still has everything) while tier 2 spends a
request and can drop a detail. The percentage is clamped because 0% fires the summary on
EVERY turn and 100% never compacts until the provider 400s. An unknown value means
`full`, never `off`: a typo must not disable compaction.

`elideTier` takes the mode as a PARAMETER instead of reading the environment, because
with three definitions of "what compaction does" (the env, a `/compact` override, the
caller's assumption) every one of them drifts — and `main.zig`'s headless runner WAS a
third definition, ignoring `off` entirely.

`describe` takes a Mode and not the environment, because `/compact off` came to answer
"elide, then summarize": the command described the env while the override was what it
had just set.

## Seguridad

**Las sesiones eran legibles por todos.** `-rw-r--r-- sessions/*.jsonl`, con todo lo que
leíste, la salida de los comandos y lo que pegaste. Ahora `drwx------` y `-rw-------`,
con el modo puesto SOBRE EL FICHERO ABIERTO (no `create` + `chmod`, que deja una ventana
en la que existe a 0644) y otra vez al reanudar, porque un resume trunca y recrea.
`auth.json` ya usaba 0600: el principio estaba en el repo y este fichero quedó fuera.

**`web_fetch` podía llegar al servicio de metadatos.** `web_fetch` NO pide permiso y
`bash` sí, así que es una cuestión de permisos y no de sandbox: un modelo siempre puede
llegar con `curl` por `bash`, detrás de un diálogo. Ahora se rechazan
`169.254.0.0/16` (AWS, GCP, Azure y DigitalOcean sirven ahí las credenciales de
instancia), `metadata.google.internal` y `fd00:ec2::254`. Loopback y rangos privados son
otro predicado y otro interruptor, porque fetchear tu propio servidor de desarrollo es
algo normal y una regla que lo rompiera se desactivaría entera, llevándose el bloqueo de
metadatos con ella.

Un bug lo cazó mi propio test: el primer blocklist comparaba las dos primeras ETIQUETAS
punteadas, así que `169.254.169.254.example.com` —un host público— quedaba bloqueado.
Leer etiquetas iniciales no es leer octetos; ahora hay un parseo IPv4 de verdad.

Verificado E2E: el modelo recibe el refusal y **se niega** a poner
`ZODE_WEB_ALLOW_LOCAL=1` para saltárselo, ofreciéndolo sólo como instrucción explícita.

## Un check que afirmaba algo que sólo era cierto por suerte

`router_smoke` decía que el aviso no decía cómo apagar el router, con el aviso en
pantalla. Tres cosas en medio, las tres la app funcionando bien: el stripper no conocía
los dos puntos de `[38:2:74:81:112m`; el GUTTER de párrafo (`│`) va en cada fila de
continuación; y dónde cae el wrap depende del CATÁLOGO EN VIVO, porque el aviso empieza
con un id de modelo. Ahora busca en una copia con el gutter y los espacios ELIMINADOS
(eliminados, no sustituidos por un espacio: el wrap cae DENTRO del token, y
`ZODE_CHE AP_TURN=0` tampoco contiene `ZODE_CHEAP_TURN=0`).

## Lo que sigue flaky

`tools.web.test.web_search for real` falla de vez en cuando contra DuckDuckGo. Es un test
de RED, no tiene que ver con nada de esto, y pasa al re-ejecutarlo. Está porque el
endpoint es un scrape.

---

# Que el harness termine tareas (2026-10-05, segunda tanda)

La pregunta era «dejando aparte los modelos, ¿el harness está bien hecho?». La
respuesta honesta fue: la maquinaria sí, y el hueco **no está en las piezas, está en la
condición de salida del bucle**. Lo que sigue es lo que se hizo con eso.

## `/goal`: el turno no puede quedarse corto

El fallo que se quejaba: a las 12 iteraciones el turno para con «agent iteration limit
reached (12): stopping the turn», el plan tiene pasos abiertos, y escribes «continue».
Esa frase no dice si la tarea está terminada.

    /goal <objetivo>      lo fija para lo que escribas después
    /goal                 lo reporta y su estado
    /goal clear           lo quita
    ZODE_GOAL_MAX          el techo duro (por defecto max(3x el blando, 60))

**Dos números en vez de uno.** El blando (12) pasa a ser un objetivo REPORTADO — contra
el que se mide `/bench` — y un objetivo se gana un techo duro y generoso (60). El caso
que llega a 60 nunca iba a terminarse parando en 12; debería haber dicho `blocked` mucho
antes. `ZODE_GOAL_MAX` nunca puede quedar por debajo del blando: un techo duro bajo el
objetivo pararía el turno antes del checkpoint.

**Decide el modelo, no el harness.** El harness sabe cuántas iteraciones lleva; no sabe
si el paquete pesa menos de 10 KB. Un harness que lo adivinara pararía en trabajo
inacabado o no pararía nunca. El veredicto es una HERRAMIENTA con dos respuestas:

- `met` + `summary` — termina el turno.
- `blocked` + `summary` + **`what_would_unblock`** — termina el turno, con calma.

`what_would_unblock` es OBLIGATORIO. Sin él, `blocked` es indistinguible de «no me
apetece» y el harness aceptaría rendirse como un hecho. Ese campo es toda la seguridad
del invento: un bucle sin techo que además puede PARAR es un bucle que puedes dejar
corriendo, y sólo significa algo si la parada está justificada.

Un `status` desconocido es ERROR, no un valor por defecto: `met` acabaría el bucle por
una errata y `none` haría que una llamada malformada pareciera que el modelo sigue
trabajando.

**El checkpoint.** En el límite blando el harness para al modelo y pide veredicto, en
su propio vocabulario y con las dos formas escritas, porque «sigo o paro» invita a una
tercera opción que no está en la lista. Si no declara, el harness dice «no verdict yet:
continuing» y sigue hasta el techo duro. El presupuesto entra en el prompt como
NÚMEROS («18 left»): es la palanca más barata del invento, porque a un modelo con
presupuesto de sobra lo pulimenta y a uno con dos iteraciones lo termina.

En el techo duro el mensaje dice qué queda abierto («N plan steps still open»), porque
«stopping the turn» es la frase que empezó todo esto.

**Por qué la nota es su propio mensaje de sistema.** `buildSystemPrompt` compone el
prefijo estable más grande y el caché se indexa por sus bytes literales: meter ahí un
objetivo que cambia DENTRO de un turno invalidaría los ~16 KB de esquemas de
herramientas en cada iteración. Va al FINAL, marcado, y `Session.setGoalNote` lo
encuentra para sustituirlo.

## El detector de repetición

La misma herramienta con los mismos argumentos tres veces seguidas para el turno, y dice
**qué** se repitió. Se comprueba en el bucle y se alimenta desde `execToolCalls`,
porque el bucle nunca ve una llamada. `read` está EXENTO: releer un fichero que acabas
de editar es el hábito correcto, y parar ahí castigaría justo lo que hace bien a un
agente. Un hash y no los argumentos: comparar bytes significa poseerlos durante el
turno, y una colisión cuesta una parada temprana en un turno que no iba a ninguna parte.

## El desperdicio que sí se puede medir

`edit` fallaba diciendo «not found in X» más 80 bytes, y la única salida del modelo era
`read` el fichero otra vez: **una iteración entera** gastada en que le dijeran lo que
la herramienta podía decirle. Y un edit fallido es el fallo recuperable más común en un
agente de código, así que esto probablemente pagaba una parte grande de las 12.

`lib/edit_hint.zig` es puro y se testea solo. Busca la línea más cercana por Jaccard
sobre tokens separados por ESPACIOS y escribe una frase DISTINTA para cada uno de los
tres fallos reales, porque una frase que vale para los tres no le deja elegir nada:

- texto correcto, ESPACIOS distintos → «here is the real line»
- texto correcto, LUGAR distinto → «the surroundings are what did not match»
- texto que NUNCA EXISTIÓ → dilo claro, porque re-leer no lo va a producir

Tres cosas que sólo funcionan por accidente si no se escriben:

- **Tokens por espacio, no palabras ni caracteres.** El tokenizador con puntuación era
  la primera versión y es incorrecto para código: `+=`, `=>` y `!=` están hechos
  ENTEROS de separadores, así que un parche cuyos tokens son `x += 1;` volvía sin
  tokens y toda puntuación era cero. En código, los operadores son palabras.
- **La prueba verbatim/espacios compara la línea TAL COMO SE ENVIÓ**, sangría
  incluida. Una línea con sangría de tabulador CONTIENE la versión recortada de un
  parche que la sangró con cuatro espacios, así que «¿está el texto recortado en el
  fichero?» dice que sí para los dos fallos y no los separa. Comparar recortes es
  cierto para toda línea y no prueba nada.
- **El umbral es 0,50 y es una negativa, no un ajuste**: enseñar una región que no tiene
  nada que ver cuesta otro edit fallido y otra iteración.

`old_string not found in` sigue siendo el principio de todas las ramas: es el
vocabulario del esquema y otro test lo fija. Lo que cambió es la frase de después.

## La caché de modelos (1144 ms → 118 ms)

Medido con `capture-pane` de tmux, que lee una pantalla de verdad:

    frío, sin caché:   1144 ms   y   1756 ms   (dos corridas, varianza de red)
    caliente:           118 ms
    --models:            594 ms  →  18 / 22 / 28 ms

Un script de pty que concatena el stream **reporta el picker VACÍO con 464 modelos
cargados**, porque vaxis repinta diferencialmente y una celda que no cambió no se
reemite. AGENTS.md ya lo decía y me costó una hora creyendo la captura de pantalla.

No es por el parseo: `curl` sola tardaba 415-858 ms y zode 475-673 ms, o sea ~90% es la
ida y vuelta de 772 KB. Es **resiliencia**: un pty que no contesta, un SSH, un mal
minuto en OpenRouter convierten 772 KB en segundos, y un picker muerto cuatro segundos
parece una app rota.

**Normalizada, no cruda** — y es una decisión: guardar el cuerpo crudo ahorra los ~60 ms
de parseo pero los paga en cada lectura, que es el camino que tiene que sentirse
instantáneo. La lista parseada se lee en ~5 ms y el único riesgo es un cambio de
esquema, que el `version` convierte en un fallo de caché. La versión es un entero
escrito a mano y no un hash de la estructura: un hash se mueve cuando se mueve un
COMENTARIO.

Clave por PROVEEDOR, guardando la URL: una URL que no coincide es un fallo. Un
proveedor cuyo `models_url` cambió tiene otro catálogo, y enseñar el viejo manda al
usuario a elegir un modelo que no está.

**El diff suele estar VACÍO.** `describe()` devuelve cadena vacía cuando nada se movió y
el llamante no reordena: una línea en cada refresco enseña a ignorarla, y reordenar una
lista bajo el cursor es peor que no reordenarla.

### El SIGSEGV que hay que escribir

La primera versión hacía `gpa.dupe(Model, cached.models)`. `Model` es
`id: []const u8, owned_by: []const u8` — un struct de SLICES al arena de la caché, así
que una copia de struct es una lista de punteros a memoria que muere en la llave de
cierre.

Invisible en `--models`, que usa la lista antes de que muera el arena, y un SIGSEGV
crudo en el TUI (status 139, sin mensaje de panic, stderr vacío) porque guarda la copia
un frame. `copyOut` es copia PROFUNDA y su nombre lo dice. La regla: **la propiedad tiene
que estar en la firma, no en un comentario.** El test que lo prueba destruye el arena a
propósito y luego lee la copia — y NO debe llevar además un `defer` de ese deinit, que es
doble free y segfault en la propia lista libre del arena.

## git que escribe, y tablas que saben más idiomas

`git_status`, `git_diff`, `git_log` sólo leían; todo lo que cambiaba el repositorio
pasaba por `bash`. Ahora hay `git_branch`, `git_add`, `git_commit` y `git_stash`.

**Todo argv es lista fija.** Un nombre de rama, un mensaje y una ruta vienen del modelo
y los tres acaban en una línea de comandos. `validRefName` rechaza un nombre que empiece
por `-`: esa es toda la regla, y es la que impide que un nombre se lea como OPCIÓN de
git. El mensaje de commit va a un FICHERO y `-F` lo nombra, así que nunca es un argv.

`check` pasó de 5 idiomas a 12. Los marcadores son DATOS: añadir un idioma es una fila
más un brazo de `planFor`. Y un marcador SIN código fuente no es nada: un repo puede
traer un `Gemfile` de una gema vendorizada sin tener Ruby, y `ruby -c` sobre eso no
prueba nada. Donde no hay typechecker (Ruby, PHP) el comando es una comprobación de
sintaxis y la etiqueta LO DICE.

`@field` exige un nombre comptime, así que las tablas llevan un enum y los bucles son
`inline for`. Un `[]const u8` como nombre de campo no compila, que es de esas cosas que
el compilador te lo pone bien.

## Dos reglas de `verify` que se leían bien y no casaban con nada

Las dos por la misma causa, y en direcciones opuestas:

- `at_start = false` necesita un byte NO-palabra DESPUÉS de la needle. La `t` de
  `just test` es byte de palabra, así que `"just "` no disparaba nunca. Igual que
  `./scripts/`: la `c` de detrás es byte de palabra.
- `at_start = true` no tiene esa comprobación, así que un `"just"` a secas disparaba
  sobre `just-file.md`.

Solución: `at_start` Y un espacio final. El espacio es el límite; `at_start` es lo que
evita que case dentro de otra palabra. El coste es que un `just` a secas se queda en
foreground, que es la dirección segura en la que equivocarse.

Y el test del lookalike asegura `!= .slow_verify` y no un tipo concreto, porque
`cat test.txt` cae en `.quick` por la regla de `cat`, que es la mejor respuesta.

## Dos tests míos que estaban mal, con el código correcto

- `a/b` en la lista de «nombres de rama inválidos»: una barra DENTRO de un nombre de
  rama es normal (`fix/goal-loop`) y sólo se rechaza una inicial. El test pedía que git
  rechazara algo que git acepta.
- `cat test.txt` esperando `.unknown` cuando la regla de `cat` lo hace `.quick`.

## Lo que NO se hizo, y por qué

**La puerta final**: cuando el plan llega al 100% y el modelo dice terminado, ejecutar
`check` una vez más y reportar. Necesita la salida del auto-check metida en el resumen
del turno, y vale más que las tablas de arriba sólo si algún modelo declara terminado
sin estarlo. No se ha observado, así que no está construido.

## The harness was telling the model to stop (2026-10-06)

Five real task runs. The same model that codes well inside another harness finished
**none** of them. The harness had the evidence the whole time and never asked with it.

**The control was held and nobody noticed.** The model is the same one that finishes
tasks in opencode. The variable that was actually free is this orchestration, and
three turns of blaming the model were three turns of not reading the loop.

### 1. The checkpoint said STOP

At iteration 12, with the work half done, the prompt said:

    STOP AND REPORT. You have used the iteration budget for this turn.
    Do not start new work.

A model that obeys writes a summary instead of finishing. A model that does not obey
burns the next 48 iterations ignoring an instruction. **Neither finishes the task**,
and which one happens is not the harness's decision to make with someone's work.

Its escape hatch was "say so in your answer and the harness will give you more
iterations" — **prose the harness cannot read**. The only machine-readable ending is
the `goal` call, so the prompt was offering a door made of a material nothing here
handles.

Now it says keep going, and it says what to keep going ON: the plan's own open steps,
which the harness counts and the model does not have to report. "Keep going" alone is
a mood; "keep going on these two steps" is a task.

### 2. A red check could not stop the turn

The harness read the build's exit code and built the model's OWN error message out of
the diagnostics (`[zig build found 3 problem(s) …] Fix these before writing more`) — and
then let the turn end anyway. Five times out of five, on a task that was about code
compiling.

`AutoCheck.last_verdict` remembers what the last verification said, and `turnMayEnd`
refuses the ending when it was red and the goal is open. Not "usually", and not
"unless the budget is over": the ceiling's job is to say UNFINISHED, not to allow
broken code. `blocked` always remains, which is what keeps this from being a dead end.

**Asking the model whether it is finished is what does not work.** A turn that has
ended in prose is a turn where nobody is grading anything, and the one moment a
self-assessment would be worth something is the one moment there is nobody left to
give it. The harness has the evidence; the loop just has to ask with it.

### 3. "say `continue` to go on" at the ceiling

The exact sentence `/goal` was built to delete, still shipping. It now leads with
UNFINISHED and names what is unresolved.

And the goal note no longer repeats "Budget: 58 iterations left of 60" on every one of
up to 60 iterations. **A number that has not changed in any way the model can act on is
not information; it is a deadline the model learns to hurry for**, which is the
opposite of finishing careful work. The number appears in the last few iterations,
where it is actionable.

## A test that asserts the OPPOSITE of the fix

The test for the goal note asserted `"18"` was present ("you have 18 left is what makes
a model finish"). It had to be **rewritten**, not extended, and the rewrite is the
record: it now asserts the countdown is **absent** in the steady state and present only
near the ceiling.

A test that pins behaviour you have just decided is wrong has to be deleted on purpose,
in the open, with the reason. Otherwise the next person reads a green suite as
endorsement of the thing that was measured to be wrong.

## `tmux` `default-shell` is `/bin/fish`, and `$?` is a COMPILE error there

Two reproduction runs "showed" a dead session, a missing exit code and no stderr. The
conclusion drawn from them was close to catastrophic and **completely wrong**: that
zode exits instantly. zode was never launched.

    fish: $? is not the exit status. In fish, use $status.

It is a **parse** error, so the whole command line never runs: rc 127, no files
created, no app. And the harness reported it as a finding, because a missing file and
a dead session look exactly like a crash.

- The inner command goes in a **file** that tmux runs with `sh`, not a variable expanded
  inside nested double quotes. A file has no quoting to get wrong and no shell to
  disagree about.
- `sh -n -c "$CMD"` before believing anything about a command line: it is the difference
  between "zode died" and "fish refused to parse it".
- **A harness that reports "no evidence" must distinguish it from "no observation".**
  A missing `exit.txt` is not a zero exit; it is a file that was never created, and the
  two look identical from the outside.

## The measurement that was wrong twice

`echo "EXIT=$?"` inside a double-quoted `tmux new-session` argument is expanded by the
OUTER shell when the argument is BUILT. The `exit.txt` it wrote held the status of
whatever ran before `tmux new-session`. It said `EXIT=1`, was quoted back as fact, and
was defended twice — on a process whose exit code had never been observed.

`git push` has a variant of the same shape in this repo's history: "Everything
up-to-date" with three unpushed commits, fixed by `git push origin HEAD:main`.
