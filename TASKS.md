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

Task IDs mirror the roadmap (`27.3` = Phase 27, item 3) so both files cross-reference.

---

## 🚀 Next up — the roadmap's own verdict

- [ ] 🟢 **Tool track complete** — Phase 32 (verify-or-refute) is done; Phases 20, 25, 26, 9 are done. Remaining work is the independent phases below.
- [ ] 🟢 Everything else per the dependency table at the bottom.

**Done since the board was written**: Phase 0 (tool registry + result cap) · Phase 1 (bundled skills + rich frontmatter) · **Phase 2 (2.1–2.5)** (skill listing budget, once-per-session listing, named args/`$ARGUMENTS`, `context: fork`, `!cmd` substitution behind permissions) · Phase 4 (output styles) · Phase 9 (agent definitions on disk: `.zode/agents/<name>/AGENT.md` + `~/.config/zode/agents/<name>/AGENT.md`, frontmatter parsing/validation, project-over-user shadowing, cached discovery) · Phase 12 (MCP over stdio + deferred tool loading) · Phase 14 (LSP client) · Phase 15 (task graph) · Phase 16 (`batch` tool) · Phase 19.1 (`sleep`, claimed; Phase 19 section still pending) · Phase 20 (team mode: `team_create`/`team_delete`/`send_message`/`team_status`, Team equals TaskList, message routing by name and broadcast, idle claim from the task graph, orderly shutdown acknowledged once, session overrides) · Phase 25.1 (bash safety classify) · Phase 26 (built-in subagent roles `explore`/`plan`/`verify` with role prompts, per-project per-role agent memory consulted/not inlined, resumable/forkable subagent windows with persisted ids, role-aware tool access and pure tests) · **model catalog invalidation at 5 minutes** (one `modelcache.max_age_seconds` TTL drives `--models` freshness, the palette refresh throttle, and a "catalog older than 5 min · refreshing" notice; a stale list is still shown for resilience but flagged) · **image input improvements** (`@shot.png` typed in the prompt is staged as a real attachment instead of binary text — TUI and headless; last-moment vision gate in `withPendingImages` and headless wire drops all image bytes when the answering model cannot see images, even if it changed after staging) · **interactive Settings screen** (full-surface two-column Claude-Code-style internal config opened with `/config` or `Ctrl+,`: sections for Model & reasoning, Output style with live preview and source badge, Context & cache with stats/verdict + prompt-cache + read-cache size, Agent behavior, Permissions, Appearance; changes persist to `~/.config/zode/config.json` through a patch writer that preserves unknown fields; `/config report` keeps the numbers panel; bundled `concise` output style added) · Phase 27 (diff with gutter + word diff + colour ladder) · Phase 28 (`/copy`) · **Phase 33 (TUI at a mature harness's level)** (effective effort/glyphs, turn counts, scroll pill/context header, transcript screen, bottom-anchored modal/fuzzy picker with scoring and preview, notifications, context visualisation, task panel, per-message actions, transcript search, OSC 8 hyperlinks, external editor/image paste, modal diff viewer, compact-summary line, permission dialog with rule explanation) · Phase 35.1 (`/files`) · Phase 35.2 (`/init`) · Phase 36 (use-after-free crash, worker lifetime/counting audit, and build-step fixes) · Tool upgrades (grep context, bash description, read PDF, glob subdir).

**Completed phase sections removed from the board (all checklist items done):** Phase 2, 3, 5, 6, 7, 8, 9, 10, 11, 17, 20, 23, 24, 25, 26, 29, 30, 31, 32, 33, 34, 35, 36.

**The analysis behind the new phases** lives in `docs/analysis/`:
`tui-chrome.md` (the TUI port list, 42 features) · `commands.md` (72 reference
commands, 26 gaps) · `harness.md` (the machinery gaps) · `audit.md` (our own
state, the open bug and the quality bar).

---

---

**Phase 8 (Prompt-cache break detection)** is complete: `src/lib/cachebreak.zig` compares the eight blocks of the stable prefix against the previous request by FNV hash, reporting the first block that changed with its byte offset. `prompt_system.zig` records a bounded history (8) of breaks and `/cache` now reports "prefix: N break(s) detected — block @ byte" (plus the frequent-writes warning), so the reader knows WHICH of our blocks stopped being stable — the one thing the harness can fix. A break is reported once per turn (`clearCacheBreakLast`). Tests cover hash stability, block offsets, describeBreak, the bounded history and `/cache` reporting zero breaks.

---

**Phase 9 (Agent definitions on disk)** is complete: definitions load from BOTH `.zode/agents/<name>.md` (flat, the common case) and `.zode/agents/<name>/AGENT.md` (directory), and the same under `~/.config/zode/agents/`; frontmatter (`name`, `description`, `tools`, `model`, `effort`) is parsed and validated (read-only tools only, no escalation); project shadows user by name and a directory shadows a flat file in the same root; discovery is cached and resettable. The Settings screen has an **Agent definitions** section: `Default agent` (persisted as `settings.active_agent` in config.json, applied by `task` when no definition is named) and `New agent…` (creates `.zode/agents/<name>.md` from a pure template). `/agents` lists the real discovered definitions. Pure tests cover name validation, flat stems, frontmatter, tool validation, template and discovery (`src/lib/agentdefs.zig`, `src/agent/discovery.zig`).

---

## Phase 13 — Ecosystem

`⏳ optional · 🟢 · only if usage asks for it`

- [ ] Plugins/marketplace · remote sessions · keybindings/vim mode — outside the core (basic vim input mode toggle `/vim` implemented; rest pending)

---

---

**Phase 17 (Notebook editing)** is complete: `read` on a `.ipynb` returns a numbered outline (index, cell type, line count, output count, first line) instead of raw JSON, and `notebook_edit` changes a cell by index. The file is parsed and written back WHOLE so outputs, execution counts, cell ids, metadata and nbformat version survive; `new_source` is the cell text (the tool does the line splitting), not its JSON encoding. A malformed notebook is refused with the line/column of the syntax error (and degrades to an error on `read`, never a crash). Pure tests cover the outline (indices/types/sizes/first line), syntax and not-a-notebook refusal, and the round trip. (`src/tools/notebook.zig`, wired via `read.zig` + `dispatch.zig`.)

---

## Phase 18 — Isolated worktree sessions

`✨ feature · 🟢 · independent`

> A risky refactor should be able to happen somewhere else and come back.

- [ ] `enter_worktree` / `exit_worktree`: create a git worktree under `.zode/worktrees/`, switch the session's cwd, remember where to return
- [ ] **Only when asked** — never proactive (a branch is what a branch is for; the tool's description says so)
- [ ] `exit` keeps or removes; `remove` refuses a dirty worktree unless `discard: true` is explicit, listing what would be lost first
- [ ] Session caches reset on the switch: project info, instruction file, plan directory, cwd-derived prompt blocks — never mix two trees
- [ ] Cleanup at exit: a leftover worktree is named on the way out; `/clean` knows about them but never removes one unprompted
- [ ] No-op with a clear message outside a git repository
- [ ] Pure tests (fixture repo): enter creates and switches · a second enter is refused · exit keep leaves the tree · remove on a dirty tree is refused and lists the changes · cwd and caches are restored · no-op outside a repo

---

## Phase 19 — Waiting: sleep, ticks and scheduled prompts

`✨ feature · 🟢 · independent`

> The harness has a clock but no way for the model to wait on purpose.

- [ ] Periodic ticks while a turn is parked: a short check-in ("anything useful to do while you wait?") instead of silence — off by default, a session flag turns it on
- [ ] `schedule {cron, prompt}`: recurring prompt for this project ("every Monday, run the flaky test and report"), plus `schedule list` / `schedule remove`; stored next to the session, delivered as a user message when it fires
- [ ] Scheduled prompts obey the same permissions as typed ones (a scheduled prompt that wants to write still asks)
- [ ] Pure tests (waiting on ticks + schedule): cron parsing (5-field, ranges, steps, names) · a `once` schedule fires once and is removed · a tick is suppressed while a tool is running

---

**Phase 20 (Team mode: persistent collaborators)** is complete: `team_create`/`team_delete`/`send_message`/`team_status` tools over a pure `lib/team.zig` store (Team equals TaskList, sharing the session's task graph); messages route by name or `"*"` broadcast (explicitly expensive, linear in team size) and an unknown name is a named error. A teammate is spawned with `task(name=…, team=…)`: it keeps its own persisted subagent window between turns (Phase 26), gets the task-graph + message tools with read-only defaults, and the harness wakes it ONLY when a message is addressed to it — it claims work itself with `task_list` → `task_update(claim, owner)`, never pushed, no idleness narration. Turns are serialized on the turn thread so two teammates never race the store. Orderly shutdown acknowledges each teammate exactly once, and an exit sweep (`sweepOnExit`) leaves no live team state. Concurrency stays capped by `ZODE_TASK_PARALLEL`. Pure and integration tests cover create/delete, routing/broadcast, unknown-name error, wake/claim/window persistence, atomic claim and shutdown acknowledgement.

---

## Phase 21 — Answering the user: the message, not the log

`✨ feature · 🟡 · independent`

- [ ] `send_user_message {message, status, attachments?}`
  - [ ] `message` is what the user reads (markdown); the prompt explicitly says the opposite of the failure it removes: answer in plain text + "done!" here
  - [ ] `status`: `normal` for a reply, `proactive` when the model initiates (scheduled task finished, blocker surfaced in the background)
  - [ ] `attachments` take paths (images/diffs/logs) rendered inline; a path that does not exist is a named error, not a silent drop
  - [ ] Not a replacement for interactive streaming — it is the durable statement and the non-interactive runs (Phase 22)
- [ ] Pure tests: markdown passes through · a missing attachment errors · `proactive` routes to the notification path · an empty message is refused

---

## Phase 22 — Structured output for scripted runs

`✨ feature · 🟡 · independent`

- [ ] `zode --chat --schema <file>`: the caller supplies a JSON schema; the model MUST call `structured_output` exactly once at the end, with an object validated against the schema before the run exits
- [ ] Validation is the contract: a mismatch is a named error the model sees and can fix — not a malformed line a script trips on
- [ ] The mode is off in the TUI (a human is reading); the schema never enters the interactive prompt
- [ ] The exit code reflects the shape: satisfied → 0 with the JSON on stdout; ended without the call → non-zero with the reason (CI fails loudly instead of parsing a prose apology)
- [ ] Pure tests: validation names the first missing/wrong field · a run that never calls the tool exits non-zero · the schema is absent from an interactive prompt

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

**What we deliberately do NOT copy** (and why) — the reasoning is in
`docs/analysis/tui-chrome.md` §5: the alternate screen (it destroys the
terminal's native scrollback), the random-verb spinner (our phase label says
more), the boxed prompt (our rule costs 1 row instead of 3), the user-defined
status line (an execution surface we do not need) and the shimmer animation (a
permanent CPU cost for a decoration).

**Where we are BETTER than the reference implementation** (so nobody ports it
backwards) — `docs/analysis/harness.md` §4 lists ten: the exit gate, the
`goal` checkpoint, the `verdictCredible` refusal, the `batch` sandbox, the
"stale green" detection (no equivalent there), the free-model rotation, the
edit hint, the repetition guard, the `ask` cap and the `proofWord` precision.
