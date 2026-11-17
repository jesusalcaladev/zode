# TASKS — zode

> Visual checklist and board for zode phases and deliverables.
> One checkbox per deliverable.
>
> **Ticking a box** means: `zig build test` green · the phase's acceptance check
> passes · status in this file is updated.

## Legend

| Badge | Kind                        |     | Priority | Meaning   |
| ----- | --------------------------- | --- | -------- | --------- |
| ✨    | feature                     |     | 🔴       | next      |
| 🏗️    | refactor (not user-visible) |     | 🟡       | later     |
| 🐛    | fix (wrong today)           |     | 🟢       | on demand |
| ⚡    | token/time saving           |     |          |           |
| 🔒    | security                    |     |          |           |

Task IDs mirror the phase numbers (`27.3` = Phase 27, item 3). The board is the
source of truth; the old roadmap/analysis docs it used to point at were never
committed, so those references were removed.

---

## 🚀 Next up — the roadmap's own verdict

- [x] 🟢 **Tool track complete** — Phase 32 (verify-or-refute) is done; Phases 20, 25, 26, 9 are done. Verified against code and tests.
- [x] 🟢 **All other boarded phases complete** — every phase on this board except the optional Phase 13 is implemented and tested. (The old "dependency table at the bottom" never existed; this line replaces it.)

**Done since the board was written**: Phase 0 (tool registry + result cap) · Phase 1 (bundled skills + rich frontmatter) · **Phase 2 (2.1–2.5)** (skill listing budget, once-per-session listing, named args/`$ARGUMENTS`, `context: fork`, `!cmd` substitution behind permissions) · Phase 4 (output styles) · Phase 9 (agent definitions on disk: `.zode/agents/<name>/AGENT.md` + `~/.config/zode/agents/<name>/AGENT.md`, frontmatter parsing/validation, project-over-user shadowing, cached discovery) · Phase 12 (MCP over stdio + deferred tool loading) · Phase 14 (LSP client) · Phase 15 (task graph) · Phase 16 (`batch` tool) · Phase 19 (sleep + ticks + schedule, complete) · Phase 20 (team mode: `team_create`/`team_delete`/`send_message`/`team_status`, Team equals TaskList, message routing by name and broadcast, idle claim from the task graph, orderly shutdown acknowledged once, session overrides) · Phase 25.1 (bash safety classify) · Phase 26 (built-in subagent roles `explore`/`plan`/`verify` with role prompts, per-project per-role agent memory consulted/not inlined, resumable/forkable subagent windows with persisted ids, role-aware tool access and pure tests) · **model catalog invalidation at 5 minutes** (one `modelcache.max_age_seconds` TTL drives `--models` freshness, the palette refresh throttle, and a "catalog older than 5 min · refreshing" notice; a stale list is still shown for resilience but flagged) · **image input improvements** (`@shot.png` typed in the prompt is staged as a real attachment instead of binary text — TUI and headless; last-moment vision gate in `withPendingImages` and headless wire drops all image bytes when the answering model cannot see images, even if it changed after staging) · **interactive Settings screen** (full-surface two-column Claude-Code-style internal config opened with `/config` or `Ctrl+,`: sections for Model & reasoning, Output style with live preview and source badge, Context & cache with stats/verdict + prompt-cache + read-cache size, Agent behavior, Permissions, Appearance; changes persist to `~/.config/zode/config.json` through a patch writer that preserves unknown fields; `/config report` keeps the numbers panel; bundled `concise` output style added) · Phase 27 (diff with gutter + word diff + colour ladder) · Phase 28 (`/copy`) · **Phase 33 (TUI at a mature harness's level)** (effective effort/glyphs, turn counts, scroll pill/context header, transcript screen, bottom-anchored modal/fuzzy picker with scoring and preview, notifications, context visualisation, task panel, per-message actions, transcript search, OSC 8 hyperlinks, external editor/image paste, modal diff viewer, compact-summary line, permission dialog with rule explanation) · Phase 35.1 (`/files`) · Phase 35.2 (`/init`) · Phase 36 (use-after-free crash, worker lifetime/counting audit, and build-step fixes) · Phase 37 (`/diag` + `--diag` + `zig build diag`, pure `src/lib/diag.zig` memory snapshot) · Phase 38 (release/beta flow: real `churn` tool, `ZODE_UPDATE_CHANNEL=beta`, `src/lib/release.zig`, `docs/releasing.md`, `v0.3.0-beta.1` published with four platform assets) · Phase 39 (`zig build memaudit`: pure `src/lib/memaudit.zig` + `tools/memaudit.zig` static auditor for stack-buffer escapes and borrowed `.items`; CI gate; found and fixed the latent `copy_toast_text` dangling slice) · auth-encryption hardening (`src/lib/authstore.zig`, passphrase-protected master key) · Tool upgrades (grep context, bash description, read PDF, glob subdir).

**Completed phase sections removed from the board (all checklist items done):** Phase 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39.

**Analysis docs:** the old `docs/analysis/` set (`tui-chrome.md`, `commands.md`,
`harness.md`, `audit.md`) and `ROADMAP.md` were referenced here but were never
committed. The completed-phase paragraphs above are the surviving record; the
references were removed instead of leaving dangling links.

---

---

**Phase 8 (Prompt-cache break detection)** is complete: `src/lib/cachebreak.zig` compares the eight blocks of the stable prefix against the previous request by FNV hash, reporting the first block that changed with its byte offset. `prompt_system.zig` records a bounded history (8) of breaks and `/cache` now reports "prefix: N break(s) detected — block @ byte" (plus the frequent-writes warning), so the reader knows WHICH of our blocks stopped being stable — the one thing the harness can fix. A break is reported once per turn (`clearCacheBreakLast`). Tests cover hash stability, block offsets, describeBreak, the bounded history and `/cache` reporting zero breaks.

---

**Phase 9 (Agent definitions on disk)** is complete: definitions load from BOTH `.zode/agents/<name>.md` (flat, the common case) and `.zode/agents/<name>/AGENT.md` (directory), and the same under `~/.config/zode/agents/`; frontmatter (`name`, `description`, `tools`, `model`, `effort`) is parsed and validated (read-only tools only, no escalation); project shadows user by name and a directory shadows a flat file in the same root; discovery is cached and resettable. The Settings screen has an **Agent definitions** section: `Default agent` (persisted as `settings.active_agent` in config.json, applied by `task` when no definition is named) and `New agent…` (creates `.zode/agents/<name>.md` from a pure template). `/agents` lists the real discovered definitions. Pure tests cover name validation, flat stems, frontmatter, tool validation, template and discovery (`src/lib/agentdefs.zig`, `src/agent/discovery.zig`).

---

## Phase 13 — Ecosystem

`✅ complete · 🟢 · was optional, now implemented and verified`

- [x] Plugins/marketplace · remote sessions · keybindings/vim mode — all three implemented in Phase 13 below.

---

---

**Phase 17 (Notebook editing)** is complete: `read` on a `.ipynb` returns a numbered outline (index, cell type, line count, output count, first line) instead of raw JSON, and `notebook_edit` changes a cell by index. The file is parsed and written back WHOLE so outputs, execution counts, cell ids, metadata and nbformat version survive; `new_source` is the cell text (the tool does the line splitting), not its JSON encoding. A malformed notebook is refused with the line/column of the syntax error (and degrades to an error on `read`, never a crash). Pure tests cover the outline (indices/types/sizes/first line), syntax and not-a-notebook refusal, and the round trip. (`src/tools/notebook.zig`, wired via `read.zig` + `dispatch.zig`.)

---

---

**Phase 18 (Isolated worktree sessions)** is complete: a single `worktree` tool (`operation=enter|exit|status`, `name`, `remove`, `discard`) over a pure `src/lib/worktree.zig` (name/path validation, porcelain dirty parse + refusal that LISTS changes, leftover note, fixed-size session that remembers where to return). `enter` is ONLY called when the user asks (the tool description and routing prompt say never proactively): it runs `git worktree add` under `.zode/worktrees/`, records the original cwd/root, and calls `switchProjectContext` — one place that tears down EVERY cwd-derived cache (AGENTS.md, cache-break history, agent defs, skills, styles, permission rules/hooks, sessions dir, plan mtime) and re-detects project info, then re-syncs the system prompt so the new tree's instructions are on the wire. `exit` restores all of it; `remove` refuses a dirty tree with the list of changes unless `discard:true` is explicit. Outside a git repo the call is a clear no-op. `/clean` now NAMES leftover worktrees as a known, never-deletable bucket (`exit_worktree` is the only door). Tests use a real fixture git repo: enter creates/switches, state is remembered, second enter refused, dirty removal refused with the list, no-op outside a repo, and /clean lists worktrees without deleting.

---

---

---

**Phase 19 (Waiting: sleep, ticks and scheduled prompts)** is complete: `sleep` (19.1) stays as the bounded wait tool. New: a `schedule {add|list|remove}` tool over pure `src/lib/cron.zig` (5-field parser: `*`, ranges, steps, comma lists, month/weekday names) and `src/lib/schedule.zig` (bounded store, due detection, `once` removal, JSON sidecar next to the session via `pathForSession`). Schedules are restored on resume and fired at the top of each iteration (and on the TUI tick while parked) through `appendHarnessPrompt` — the one door that puts harness text on the wire as a `user` message, so a scheduled prompt that wants to write still goes through the same permission gate as a typed one. Periodic ticks are OFF by default (`/ticks` toggles) and are suppressed while a tool is running or a turn is busy (`src/lib/tick.zig` pure predicate). Pure tests cover cron parsing, schedule due/once/JSON round-trip, tick suppression and the routing prose.

---

---

**Phase 20 (Team mode: persistent collaborators)** is complete: `team_create`/`team_delete`/`send_message`/`team_status` tools over a pure `lib/team.zig` store (Team equals TaskList, sharing the session's task graph); messages route by name or `"*"` broadcast (explicitly expensive, linear in team size) and an unknown name is a named error. A teammate is spawned with `task(name=…, team=…)`: it keeps its own persisted subagent window between turns (Phase 26), gets the task-graph + message tools with read-only defaults, and the harness wakes it ONLY when a message is addressed to it — it claims work itself with `task_list` → `task_update(claim, owner)`, never pushed, no idleness narration. Turns are serialized on the turn thread so two teammates never race the store. Orderly shutdown acknowledges each teammate exactly once, and an exit sweep (`sweepOnExit`) leaves no live team state. Concurrency stays capped by `ZODE_TASK_PARALLEL`. Pure and integration tests cover create/delete, routing/broadcast, unknown-name error, wake/claim/window persistence, atomic claim and shutdown acknowledgement.

---

---

**Phase 21 (Answering the user: the message, not the log)** is complete: a `send_user_message {message, status, attachments?}` tool over a pure `src/lib/usermessage.zig`. `message` is what the user reads — pushed as an `.assistant` paragraph (full markdown) into the transcript AND appended to the session so it survives resume, not a log line. `status=normal` is a reply; `status=proactive` ALSO raises a transient notification (the model initiated contact). The routing prompt tells the model the opposite of the failure this removes: write the answer in plain text + "done!" here, not a play-by-play in the tool log. `attachments` take paths rendered inline; a path that does not exist is a NAMED error with the path, never a silent drop, and it is checked before anything is rendered. The tool also works in `--chat` (headless), printing the durable message to stdout. Pure tests cover markdown passthrough, empty-message refusal, proactive routing, unknown status/bad attachment, and missing-path detection.

---

---

---

**Phase 22 (Structured output for scripted runs)** is complete: `zode --chat --schema <file> "text"` loads the caller's JSON schema and switches the run into schema mode. In that mode ONLY, the system prompt gets a directive (call `structured_output` exactly once, as the last action) and the tool array gains a `structured_output` entry — the TUI never sees either, so the schema never enters an interactive prompt. The tool is intercepted in the headless loop: the model's object is validated against the caller's schema by pure `src/lib/jsonschema.zig` (subset: type, required, properties, items, enum, const, min/max, lengths, additionalProperties); a mismatch is a NAMED error naming the first wrong field, appended as a tool result so the model fixes it and calls again. On success the validated JSON alone is printed to stdout (diagnostics to stderr) and the run exits 0; ending without a valid call exits non-zero (2) with the reason on stderr, so CI fails loudly instead of parsing a prose apology. `src/lib/structured_run.zig` holds the pure exit-code/directive/tool-injection decisions. Pure tests cover validation naming the first missing/wrong field, exit code with/without the call, and the schema being absent outside schema mode; verified end-to-end with the fake provider (valid object → 0 + JSON on stdout; no call → 2).

---

---

---

**Phase 23 (Settings the model can read and change)** is complete: a `config` tool (`operation=get|set`, `key`, `value`) over a WHITELIST of seven keys (model, effort, compaction, auto_check, task_parallel, output_style, web_allow_local) defined in pure `src/lib/configkeys.zig`. An unknown key is refused with the full list and the "auth.json is off-limits" note; credentials are never reachable (no credential key in the whitelist; `secretPresenceText` returns only set/not-set). `get` is free; `set` validates the value, is blocked in plan mode, and asks for permission unless `Config(<key>)` was already allowed (remembered in the allowlist). `set` applies the value to the live session and persists the full config snapshot so a single-key write does not erase other settings. Pure tests cover the whitelist, unknown-key refusal, secret masking, value validation, permit subjects and a `set` round-trip that survives a reload.

---

---

**Phase 26 (Built-in subagent roles + agent memory)** is complete: built-in roles `explore`, `plan`, and `verify` are selectable by name with role-specific prompts; per-project per-role memory lives under `.zode/agent-memory/<role>/` and is consulted (not inlined, costs nothing when empty) with role access to append lessons; subagents can be resumed (same window) or forked (copied window) via persisted subagent ids; pure tests cover role selection/fallback, role/caller tool subset rules, memory prompt behavior, and resume/fork window semantics.

---

---

**Phase 32 (Verify or refute: the three-way count)** is complete:
- **32.1** `src/lib/verifycounts.zig`: the `found/verified/refuted` protocol (DATA only — the prompt stays ours in `review.zig`), word labels never ✓/✗, refuted hidden at zero, "setting up" when no data (`proofWord(.nothing)` honesty), the activity-strip pill with a `+1` counter (the `tps_win_ns` pattern). A verify-role subagent feeds the pill from its report lines.
- **32.2** `advisor` tool (zero args, whole session forwarded automatically, one LLM call at the checkpoint): a `task`-shaped read-only subagent with effort low and anti-sycophancy calibration; make the deliverable durable before calling. No provider beta, no new transport.
- **32.3** `src/lib/spendgate.zig`: four cheap local checks (merge-base, non-empty `--shortstat`, repo size, quota) with user-facing messages before any expensive pipeline stage; fail-OPEN on unreadable counters.
- **32.4** `src/lib/idlestability.zig` + `bgproc.Job.idle_tracker`: `STABLE_IDLE_POLLS = 5` consecutive no-growth polls AND an explicit completion tag; a tag split across pipe flushes is accumulated by `TagScanner`.

---

**Phase 33 (TUI at a mature harness's level)** is complete: all 18 ported features (33.1–33.7, 33.9–33.14, 33.16, 33.18, 33.19, 33.21) are implemented and checked; its section was removed from the board per convention.

**What we deliberately do NOT copy** (and why): the alternate screen (it destroys the
terminal's native scrollback), the random-verb spinner (our phase label says
more), the boxed prompt (our rule costs 1 row instead of 3), the user-defined
status line (an execution surface we do not need) and the shimmer animation (a
permanent CPU cost for a decoration).

**Where we are BETTER than the reference implementation** (so nobody ports it
backwards) — ten concrete advantages: the exit gate, the
`goal` checkpoint, the `verdictCredible` refusal, the `batch` sandbox, the
"stale green" detection (no equivalent there), the free-model rotation, the
edit hint, the repetition guard, the `ask` cap and the `proofWord` precision.

---

**Phase 37 (Internal diagnostics)** is complete: `/diag`, `--diag` and `zig build diag` expose a one-shot memory snapshot from `/proc/self/status` without touching the network or the real HOME. The pure `src/lib/diag.zig` parses the status fields; it runs in CI-adjacent tooling only and never renders into the TUI.

---

**Phase 38 (Release/beta flow)** is complete: `tools/churn.zig` is a real four-command tool (`add`, `version`, `changelog`, `release`) that replaces the old stub and the buggy `churn.sh`. `release` refuses a dirty tree, runs `zig build test`, cuts the dated `CHANGELOG.md` section, consumes the changesets, commits and tags — and only pushes with explicit `--push`. The release math lives in pure `src/lib/release.zig` (channel selection, semver bump, `pickLatest` that prefers prereleases on the beta channel and never demotes stable to beta). Self-update reads `ZODE_UPDATE_CHANNEL=beta` and follows the newest prerelease; stable keeps `/releases/latest`. Runbook in `docs/releasing.md`. Verified end-to-end: `v0.3.0-beta.1` published with four platform binaries plus `install.sh`, marked as a GitHub prerelease, and the downloaded binary reports `zode v0.3.0-beta.1`.

---

**Phase 39 (Memory-safety auditor)** is complete: `zig build memaudit` runs `tools/memaudit.zig` over all 287 `.zig` files under `src/`. The pure `src/lib/memaudit.zig` has two narrow detectors for the two crash classes that actually hit zode — a stack buffer stored in a struct field (`field = bufPrint(&local, ...)`) and a borrowed `.items` stored as message `.content`. It is a CI gate (`.github/workflows/zig.yml`) and exits 1 on findings; `// memaudit: allow` suppresses a reviewed line. It immediately found a real latent bug: `m.copy_toast_text` was a slice into a dead stack buffer, now formatted into a Model-owned buffer.

---

**Quality cleanup (bookkeeping, no new feature)** is complete: the stale
`ROADMAP.md` / `docs/analysis/` references were removed from this board, the two
"Next up" boxes were resolved (only optional Phase 13 stays open), and Phases
37-39 plus the auth-encryption hardening are now recorded above. All Spanish
comments and test names in `src/lib/project.zig` and
`src/lib/skills/bundled.zig` were translated to English, along with Spanish
test fixtures in `ask.zig`, `checkpoint.zig`, `dispatch.zig`, `ui_frame.zig`
and `agent.zig` (Spanish kept only where it is the *subject* of a test, e.g.
the language-following prompt and filename fixtures). Pure tests were added for
`src/lib/authstore.zig` (4 tests: envelope round trip, tamper/wrong-key refusal,
key encoding, passphrase master key) and for the previously uncovered
`provider.zig`, `shellquote.zig`, `sleep.zig` and `highlight/{config,scanner,styles}.zig`;
all are registered in `src/test_all.zig`. The suite is 2054 passed / 4 skipped.

---

**Phase 13 (Ecosystem)** is complete — the last open checkbox, now closed:

- **13.1 Plugins/marketplace.** Pure `src/lib/plugins.zig` (manifest parse/validate, bundled catalog, search, prompt section) plus `src/lib/pluginstore.zig` for disk IO (discover with project-over-user shadowing, install from catalog, remove, toggle). A plugin is a DECLARATIVE JSON manifest that contributes instructions to the system prompt — it never executes code, so installing from the catalog is safe. Appended to the existing skills cache block so the eight-block prompt-cache prefix does not move. `/plugin` lists, searches, installs, removes, shows info and toggles plugins.
- **13.2 Remote sessions.** Pure `src/lib/remote.zig` (config from `ZODE_REMOTE_URL`/`ZODE_REMOTE_TOKEN`, URL validation, index parsing, pull/push/skip planning, session-id validation) plus `src/lib/remotesync.zig` for HTTP GET/PUT and local file IO. `/remote` supports `status`, `list`, `pull`, `push` and `sync [local|remote]`. IDs are validated before they become filenames (no path traversal). `tools/remote_server.py` is a working reference server; the full command flow was verified against it in a real pty.
- **13.3 Keybindings.** Pure `src/lib/keybinds.zig` (canonicalization, defaults, JSON map parsing, last-wins resolution) plus a Vaxis-to-canonical adapter in `src/tui.zig`. Bindings are resolved in the composer AFTER every modal had its chance and execute an existing slash command through `agent.runPaletteCommand` — the same door the palette uses. Vim normal mode keeps ownership of its keys. `/keybinds` lists, sets and resets the map, persisted through a config patch writer that preserves unknown fields.
