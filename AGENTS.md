# zode — AGENTS.md

A code harness in pure Zig (no C deps), focused on speed and saving tokens.

## How we work

- **Pure Zig std** — no C dependencies, no mandatory libc (musl target possible). Only external dep: libvaxis (pure Zig).
- **Token saving by design**: the context is the expensive resource. Anything that goes into the LLM has to earn its place.
- **Radical simplicity**: prefer direct, readable code over premature abstraction.
- **All visible text in English**: UI, system prompts, code comments, test names, and assertions. No Spanish or other languages in source — only identifiers, protocol names, paths, tool names, and ASCII art are exempt. Check: both language greps come out empty.
- **No TODOs** in code — `AGENTS.md` forbids them; a placeholder is a decision deferred.
- **Every file that touches the model has a test** — pure modules (`src/lib/`) are testable without TUI or network; TUI-heavy code uses `drawTest` + `tools/pty_smoke.py`. A feature without a passing test is not done.

## Zig 0.17 — traps worth remembering

The tree moved from 0.16 to 0.17 (`minimum_zig_version`, vendored `zig-pkg`, and
`build.zig` are all 0.17 now). What the migration actually changed:

- **`**` array multiplication is GONE.** `"x" ** 5000` does not compile, in any
  spacing. Test data uses `src/lib/repeat.zig`: `&repeat.rep("x", 5000)` where a
  slice is wanted, bare `repeat.rep("x", 5)` inside `++` (concat takes arrays, not
  pointers), and `@as([N]T, @splat(v))` for a non-byte element type.
- **`std.meta.fields` is a `@compileError`**: `@typeInfo(T).@"struct".fields` (with
  `.name`/`.type` per field) and for enums `@typeInfo(E).@"enum".field_names` plus
  `field_values` — the enum shape is TWO parallel arrays now, there is no per-field
  struct, and `field.value` does not exist. `std.meta.eql`, `activeTag`,
  `stringToEnum` and `fieldInfo` all still exist.
- **`std.fmt.bufPrintZ` is gone** → `std.mem.printSentinel(buf, fmt, args, 0)`.
  `std.fmt.bufPrint` still works but is marked deprecated in favor of `std.mem.print`.
- **`std.ascii.indexOfIgnoreCase` is gone**: only `eqlIgnoreCase` and
  `startsWithIgnoreCase` remain. Lowercase into a buffer and use `std.mem.indexOf`.
- **`std.Build.args` (the `--` passthrough) is gone.** Build scripts see only `-D`
  options: tests filter with `-Dtest-filter=name`, and the runnable steps
  (`ui-frame`, the probes, `tool-test`) take `-Drun-args="turn 100 34"`.
- Optimize modes are lowercase in code (`.debug .safe .fast .small`), and the
  `std.lang.Optimize` enum literal that 0.16 code wrote as `.ReleaseSmall` no longer
  resolves there (`std.builtin.OptimizeMode.ReleaseSmall` does, and
  `-Doptimize=ReleaseSmall` on the command line still works as a deprecated alias —
  measured, both spellings build the same binary).
- `std.testing.expectEqual` takes TWO arguments (`@as(usize), 3, i` was the old
  three-argument form and does not compile).
- **`free` now checks the LENGTH, not just the address.** The safe allocator (the
  `gpa` in `.debug` and `.safe`) aborts with `free of invalid memory [addr…, len: 20
  (0x14) align: 1] or corrupted metadata` when the slice handed to `gpa.free` is
  SHORTER than the block behind it — which is exactly what `gpa.free(list.items)` is
  for an `ArrayList` that grew (`items.len` < `capacity`). 0.16 only matched the
  address, so "return `out.items`, let the caller free it" was silently legal. It
  was not: `jsonString` did it and the first `!echo` of the session killed the
  release binary on the shell thread, with `zig build test` green all the while
  (no test freed the result). Hand back `list.toOwnedSlice(gpa)` — it resizes to
  the length — or an exact `gpa.alloc` / `gpa.dupe`.

Everything below carried over from 0.16 unchanged:

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
- `ZODE_MAX_TOOL_OUTPUT` (default 1 MB, hard cap 10 MB; `K`/`M`/`G` suffixes)
- `ZODE_CONTEXT_LIMIT` (unset: the model's own window, else 128k; budget = `ZODE_COMPACT_PCT`, 80% by default) — full settings reference in `docs/settings.md`
- `ZODE_FREE_AUTO=1` / `ZODE_TASK_PARALLEL` (default 3) / `ZODE_MAX_ITER` (default 12)
- `ZODE_COMPACT=off|elide|full` (default when unset: `elide`, Tier 1 only), `ZODE_COMPACT_PCT=10..95`
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
         facts, filewatch,
         zjsonl, verify, exitgate, cost, review, diffview, repeat,
         outputstyles, outputstyle_store, bundled_outputstyles
```

`src/lib/` describes **how it is tested**, not what it does. Moving modules together does not change internal imports (paths are relative to the file).

## Mascot: Zo

- `mascot.zig`: six keyframed TRACKS (idle/thinking/tooling/done/warn/err), each a list of beats with its own duration, plus a MOTION layer under them (`breathe`/`tilt`/`jitter`/`jump`/`shake-*`) sampled as a pure function of time. `poseAt(kind, ms)` is what a renderer paints: 7 ASCII columns, a beat `hint`, and a lean of at most one cell to the RIGHT (home is the footer's left margin; the column left of it is the app's).
- **The animation clock is milliseconds** (`nowMs`, `Timestamp.nanoseconds / ns_per_ms`), never `toSeconds() * 1000`: the beats are 70–520 ms, and a seconds clock rounds them all to the same instant. A track always opens on its FIRST beat (`Animator.started`): measuring the elapsed time from 0 made the resting face start mid-loop, with a double blink and no rest.
- **The tick is scheduled at the frame's END** (`frames.remainingMs`), and the tick handler repaints on `mascotMoved()` (the painted cells or the lean changed), not on "there is an animation": 120 ms wake-ups at rest, ~30 fps only while the motion layer moves.
- The footer's face has a one-cell slot and the legend starts after it, so a shake never pushes the words; the legend reads the phase, the face reads the mood.
- Startup banner: ONLY the `ZODE` wordmark (5 lines of plain ASCII, no mascot, no greeting, no shortcuts line — Houston/Astro Boy tried and rejected for filling the view).
- The face is in the composer's footer (the last row of the well), not inside the input.

## Key design decisions (durable — do not undo without a test)

- **SSE streaming is really incremental**: `streamPost()` delivers chunks via `response.reader`; `StreamCtx.feed()` dispatches each `data:` line as soon as complete. ESC cuts via `chat.cancel_current` (`std.atomic.Value(bool)`), and partial text is kept (`result.partial`).
- **Tool calls do not get stuck**: `tryEmitTool` validates JSON; `flushPendingTools()` forces emission at `finish`. Empty args = `{}`.
- **Recoverable tool results (Phase 3)**: oversized tool results can be spilled to session-isolated files (`toolstore`) with preview + recoverable `read path=` notices; per-tool and aggregate per-message caps (`resultcap`/`ResultBudget`) apply, and frozen cut decisions/caps sidecars keep cuts stable. Compaction preserves recoverable markers.
- **Compaction is 2-tier (v2)**: Tier 1 (`elideTier`) elides old/large tool results outside the recent window; when a stored result exists the marker keeps a recoverable `read path=`, and sync compaction can persist large non-stored elided results. Tier 2 (`summarizeTurns`) makes one LLM call with `summaryPrompt()` capped at 16 KB, replacing old turns with a summary (only in `full` mode and never at 256k+). Budget scales with window (80/90/98%). Critical context (invoked skills/`<skill_content`, non-elided reads, goal/plan/summary/boundary markers) is preserved; compaction boundaries/summary state (`trimToBoundary`, session `compact_summary`/`compact_tail_keep`) prevent re-sending summarized history on resume; a summarizer circuit breaker stops repeated tier-2 failures.
- **Prompt caching is one breakpoint**: `chat.markCachePrefix` marks the END of the stable prefix (2 messages from the end) and nothing else. Anthropic allows 4 `cache_control` markers per request and the system block + tool schemas already take 2, so marking every old message 400s any conversation of 5+ messages. The warm/hot thresholds (`bgPct`/`hotPct`) scale the same way: 80/90 under 256k, 85/92 at 256k, 90/95 at 1M.
- **Session file format is zjsonl**: append-only JSONL in `./sessions/zode-<id>.jsonl`; lines ≥512 bytes compressed with raw DEFLATE level 9 (`z` prefix + base64). Round-trip tested byte-for-byte. `File.Writer` uses `Writer.initStreaming`; positional mode creates 0xFF holes.
- **Compressed session architecture**: session create/resume returns heap `*Session`; the File.Writer references `write_buf` inside the struct — never move by value.
- **Permission flow**: `model.requestPermission()` blocks worker thread (spin + yield) until UI answers. Priority: `/yolo` (global) > persisted allowlist (`~/.config/zode/permissions.json`, 0600) > dialog. Denied answers feed back as `tool_result "denied: permission required"`. `lsp` asks NO permission (spawns from fixed table, never model). `batch` asks union of step permissions. `bash` is classified before asking (`cmdsafety`); read-only bash can avoid prompts and flagged commands may offer a sandbox when available.
- **Hooks (Phase 5)**: project `.zode/hooks.json` defines command hooks for `PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `Stop` with `matcher` (tool/regex), `if` (permission-rule syntax), `timeout_ms`, `once`. `PreToolUse` can block the tool (reason returned as tool result); `PostToolUse` output is appended as `[hook note]`; malformed hooks are skipped. Wired in agent/tool execution paths.
- **Background tasks (Phase 10)**: unified bg registry (`bgproc`) supports file-backed session-isolated output with incremental polling (`bash_output`/`check`, file cursor returns only new output) and terminal-state reporting. On completion/kill, the harness drains completions once and injects `[background task finished]` as a session/harness event (not model polling).
- **Verifications (what the harness actually checks)**: `zig build` (types/syntax) is the floor; model's own `check` / `bash` covers upper rungs (`npm test`, `pytest`, `cargo test`, etc.). `proofWord` maps to `typechecked / syntax-checked / tested / not checked` — never "verified" for a typecheck alone. The exit gate (`AutoCheck.exitGate`) runs at the TOP of each iteration, before `again orelse break`, refusing to end on red (`refused_failed`), stale green (`refused_unverified`), or unverified writes.
- **Subagent (`task`)**: depth 1, effort `low` always, 24k budget, only read tools, does not see conversation. Parallel capped at `ZODE_TASK_PARALLEL` (default 3) by waves; `mirror_globals` prevents module-global stomping (`last_usage`, `cancel_current`, etc.).
- **Free-auto (`/free-auto`)**: rotates between free models of providers with a key; quotas cause rotation (`quotaVerdict` distinguishes gate 403 vs account 403 vs 401/404/5xx). Filter by `models.isConversational(id)` (embeddings/images/audio excluded).
- **Skills**: `.zode/skills/<name>/SKILL.md` (project) and `~/.config/zode/skills/<name>/SKILL.md` (personal), with `name` + `description` frontmatter. Only name + description enter prompt (budget = 1% of `ZODE_CONTEXT_LIMIT`). Project overrides global; no merge.
- **Images reach a message two ways**: a `read` leaves bytes in `pending_images` (attached to the next user message, wire note says "a file you read"), and Ctrl+V reads the CLIPBOARD image (`wl-paste -t image/<fmt>`, then `xclip`) into `draft_images` — staged with the typed text, moved to `pending_images` at submit, die with a Ctrl+C'd draft; wire note says "attached by the USER". Staged images show as `[name]` tags on their own row inside the composer. Caps (`max_images` in `images.zig`, 4 at 1 MB each) and the vision gate live in `images.zig`.
- **Bracketed paste is aggregated by US**: vaxis forwards `paste_start`/`paste_end` markers and parses everything between them as ordinary key events (a pasted newline arrives as Ctrl+J). `pasting` + `paste_buf` in the `Model` swallow those keys and insert once at `paste_end` — otherwise every pasted line submits its own prompt.
- **Notebooks**: `read` returns numbered outline (index, type, size, first line); `notebook_edit` by index. Round trip preserves outputs, execution counts, cell ids, metadata. Malformed file refused with parse line/column.
- **MCP**: server is a PROGRAM; schemas live in manager catalogue, NOT in request `tools` array (cache prefix protection). `mcp` tool has `search`, `list`, `call`. Server config is user-level (`~/.config/zode/config.json` `mcp_servers`), not from `.mcp.json` (remote code execution risk). Read-only schema composed from `registry.blob` at comptime; `lsp` permission fixed to `read_only = true`.
- **Path-scoped rules (`Tool(pattern)`)**: rules loaded once from `local` > `project` (`.zode/permissions.json`) > `user` > `policy`; `deny` beats any `allow`; within one source, last match wins. Resolver is pure Zig (`readLink`), not `realpath(3)`; checks resolved path, not written path (symlink hole fixed).
- **Self-update**: cache in `~/.cache/zode/update.json` (6h TTL, one file, respects `XDG_CACHE_HOME`). Check notifies; `/update` verifies binary (`--version`) before replacing; refuses to go backwards; writes `{exe}.new`, atomic rename over.
- **Harness-authored prompts go into the SESSION as a `user` message**: `appendHarnessPrompt` is the one door. The wire of every iteration IS the session, so a refusal, checkpoint question or nudge that is not appended is one the model cannot read — action and reason silently uncorrelated. If you ever find yourself passing a nudge as a function argument that reaches no message, stop and append it instead.
- **The ceiling turn gets no tools**: when the iteration budget is exhausted, `Model.deny_all_tools` removes the tools field from the body (buildBody omits it for an empty schema) and the model is asked for a final summary. A turn ended by a limit must not end in silence. `ZODE_CRASH_TEST=1 zig-out/bin/zode` is the diagnostic for the other hard failure: an intentional panic with the alt screen active, which exercises the crash handler (restore + `/tmp/zode-crash.log`).
- **Crash path is its own code**: `src/main.zig` defines `pub const panic` (restore terminal via `termseq.restore_all` + `/dev/tty`, crash log with frames to `/tmp/zode-crash.log`), `.enable_segfault_handler = true` in `std_options`, and a `pub const debug = struct { handleSegfault }` override — a real SIGSEGV (a Release build without safety checks) never reaches `panic`, so the override restores the terminal and appends a back-traced `pc:` entry, then defers to `defaultHandleSegfault` (no stack unwinding inside a signal). No `Io`, no allocator, raw syscalls only. ANSI/control bytes never reach a cell: `ansi.strip` removes complete CSI/OSC sequences from every paragraph at build time; `isControlGrapheme` U+FFFD backstop remains for anything else, and the palette refuses key text containing a control byte (a terminal reply is a sequence, not a character).
- **The task pipeline is a state machine in code, not a prompt**: `/pipeline` (or `ZODE_PIPELINE=auto` on a code/install task) runs Explorer → Investigator? → Implementer → Tester → harness-run suite (with up to 2 repair passes) → Reviewer, and nobody — not the model, not a skill — can skip a stage. The harness runs the tests itself (`lib/testplan.zig`), and **existing tests are untouched or the run stops**: `lib/testguard.zig` re-hashes every `test "..."` block in the repo before and after each writing stage; red → the pipeline says what broke and by name. Review is read-only (`SEVERITY: high|medium|low` lines). `.zode/pipeline/<id>/` holds the artifacts (evidence, notes, review, tester report). "omit tests" / "omit review" in the prompt skips those stages. `/code-review [paths]` runs just the review stage, read-only.

## Verification workflow

- `zig build test` — the primary gate. Tests read `AGENTS.md` for routing rules (`systemPromptBase` + `tool_routing_prompt` must stay separate) and for banner content (only ASCII wordmark, nothing else below art).
- `tools/pty_smoke.py` — real pty (`TIOCSWINSZ` at 200x50, own `HOME`, drains pty). Checks: startup, banner, input, palette, scroll, `!cmd`, long prompt preserved, no panic, no `Invalid free`.
- `tools/segv_probe.py` — SIGSEGV against the real binary in a pty: terminal must be restored, `/tmp/zode-crash.log` must gain a `pc:` entry. The panic path is `ZODE_CRASH_TEST=1`; this one is the memory-fault one.
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
