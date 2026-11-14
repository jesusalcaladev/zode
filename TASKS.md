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

- [ ] 🔴 **Sprint A2 — Phase 33** (the TUI at a mature harness's level): the port list,
  42 features read out of the reference implementation. 33.1 and 33.2 are done;
  the rest is the board. The porting notes are in `docs/analysis/tui-chrome.md`.
- [ ] 🟡 **Tool track — Phase 26 → 20** (roles → teams); Phase 25 (bash safety) is complete. 20 waits on 15, 32 on 26.
- [ ] 🟢 Everything else per the dependency table at the bottom.

**Done since the board was written**: Phase 0 (tool registry + result cap) · Phase 1 (bundled skills + rich frontmatter) · **Phase 2 (2.1–2.5)** (skill listing budget, once-per-session listing, named args/`$ARGUMENTS`, `context: fork`, `!cmd` substitution behind permissions) · Phase 4 (output styles) · Phase 12 (MCP over stdio + deferred tool loading) · Phase 14 (LSP client) · Phase 15 (task graph) · Phase 16 (`batch` tool) · Phase 19.1 (`sleep`, claimed; Phase 19 section still pending) · Phase 25.1 (bash safety classify) · Phase 27 (diff with gutter + word diff + colour ladder) · Phase 28 (`/copy`) · Phase 35.1 (`/files`) · Phase 35.2 (`/init`) · Phase 36 (use-after-free crash, worker lifetime/counting audit, and build-step fixes) · Tool upgrades (grep context, bash description, read PDF, glob subdir).

**Completed phase sections removed from the board (all checklist items done):** Phase 2, 3, 5, 6, 7, 10, 11, 24, 25, 29, 30, 31, 34, 35, 36.

**The analysis behind the new phases** lives in `docs/analysis/`:
`tui-chrome.md` (the TUI port list, 42 features) · `commands.md` (72 reference
commands, 26 gaps) · `harness.md` (the machinery gaps) · `audit.md` (our own
state, the open bug and the quality bar).

---

## Phase 8 — Prompt-cache break detection

`⚡ tokens · 🟡 · independent · pairs with /cache`

## Phase 9 — Agent definitions on disk

`✨ feature · 🟡 · independent · basis for 26`

---

## Phase 13 — Ecosystem

`⏳ optional · 🟢 · only if usage asks for it`

- [ ] Plugins/marketplace · remote sessions · keybindings/vim mode — outside the core (basic vim input mode toggle `/vim` implemented; rest pending)

---

## Phase 17 — Notebook editing

`✨ feature · 🟢 · independent`

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

## Phase 20 — Team mode: persistent collaborators

`✨ feature · 🟢 · depends on 15`

> `task` = one bounded search, throwaway window. "Watch the test suite and fix flakes" is a _role_, not a question.

- [ ] `team_create {name}` starts a team and its task list (Team ≡ TaskList); `team_delete` shuts it down
- [ ] Teammates = the existing subagent machinery + `name` + `team`; same safety defaults (read-only unless the lead grants more, effort `low`, depth 1)
- [ ] `send_message {to, message}`: to a teammate by name, or `"*"` for a broadcast (explicitly expensive, linear in team size). Plain assistant text is NOT visible to another agent — a message is a tool call, that is the only channel
- [ ] Teammates go idle between turns and **claim** from the task graph (`task_list` → `task_update` with `owner`); a teammate is never pushed work it did not take, and the lead does not narrate the idleness
- [ ] Orderly shutdown: the lead requests it, teammates acknowledge, a killing sweep runs on exit like `bgproc`'s — no teammate outlives the app
- [ ] The concurrency cap stays `ZODE_TASK_PARALLEL` (three streams on one key is the whole reason it exists)
- [ ] Pure tests: create/delete · message routing by name and broadcast · a message to an unknown name is a named error · claiming sets the owner and only one agent can own a task · a shutdown request is answered exactly once

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

## Phase 23 — Settings the model can read and change

`✨ feature · 🟢 · independent`

- [ ] `config` tool with `get`/`set` over a **whitelisted** key set (model, effort, compaction mode, auto-check, task-parallel, output style, web allow-local)
- [ ] Whitelist, not free-form: only documented keys; never `auth.json`; an unknown key is refused with the list of known ones
- [ ] Secrets are never returned: `get` on a credential-backed key answers "set"/"not set", never the value
- [ ] `set` is a write with a dialog unless the key was already allowed (changing model or compaction changes every later request)
- [ ] Pure tests: whitelist enforced · an unknown key lists the known ones · a secret is masked · `set` round-trips the config serializer and survives a reload

---

## Phase 26 — Built-in subagent roles + agent memory

`✨ feature · 🟡 · depends on 9`

- [ ] Three built-in roles with their own prompts, chosen by name:
  | role      | job                                                                            |
  | --------- | ------------------------------------------------------------------------------ |
  | `explore` | broad, parallel search; report paths and lines, never edits                    |
  | `plan`    | read-only architect: explore, then produce an ordered plan                     |
  | `verify`  | try to break the change: run it, exercise it, find the 20% the first 80% hides |
- [ ] Agent memory: a per-project, per-role directory the agent reads at start and appends lessons to; out of the prompt until consulted (costs nothing when empty)
- [ ] Resume / fork a subagent: resumed with its window intact (a search that found half the answer continues) or forked (same context, different question) — both bounded by the same 24k window and depth 1
- [ ] Pure tests: role selection by name · an unknown role falls back to the default · a role's tool list is a subset of what the caller is allowed (a role cannot escalate) · memory is not inlined into the prompt · resume keeps the window and fork does not share it

---

## Phase 32 — Verify or refute: the three-way count

`✨ feature + 🐛 fix · 🟡 · depends on 26 (advisor is a `task` subagent; the counts ride on the roles)`

- [ ] **32.1** Three-way finding counts in a `verify`-role Report + the activity strip: `finding` → `verifying` → `12 found · 5 verified · 2 refuted` → `deduping` → `ultrareview ready`
  - [ ] Word labels, never `✓`/`✗` (no provenance icons) · **hide the refuted count when it is 0** (a stable prefix teaches the eye to ignore the line) · counts animate `+1` (the `tps_win_ns` rolling-window pattern) · no data is NOT "0 findings": `setting up` / `done` — this is `proofWord(.nothing) → "not checked"` applied to a progress pill
  - [ ] The finder prompt is NOT in the tree we read — port the **protocol** (`found`/`verified`/`refuted`) and nothing else; the prompt is ours from our own `review.zig` checklist (writing a plausible-looking prompt for a server-side agent is exactly the `effortSupport`-table failure this repo already paid for)
- [ ] **32.2** `advisor` tool: no arguments, the whole conversation forwarded automatically, one LLM call at the checkpoint
  - [ ] Call BEFORE substantive work ("orientation is not substantive work. Writing, editing, and declaring an answer are") and when believing the task is complete — **make the deliverable durable first** (write the file, stage the change: the call takes time; an unwritten result does not persist through it)
  - [ ] Anti-sycophancy calibration, verbatim: a passing self-test is NOT evidence the advice is wrong — it is evidence your test does not check what the advice is checking; a conflict with data you already retrieved → surface it in one more call, do not silently switch
  - [ ] Implementation: a `task`-shaped subagent (effort `low`, read-only) that receives the serialized session — no provider beta, no new transport; the same gate as `/goal`'s checkpoint seen from the other side (`verdictCredible` already refuses a `blocked` with zero tools run)
- [ ] **32.3** Gate before you spend: four cheap local checks with user-facing messages BEFORE anything expensive starts — merge-base with main exists · non-empty diff (`--shortstat`) · repo not too large · "bail early on empty diffs instead of launching a container that will just echo 'no changes'"
  - [ ] Fail-OPEN bias, copied as a rule: an unreadable quota/utilization → `{ kind: 'proceed' }`. An unreadable counter must not become a wall; the gate informs, and a spend is the failure you can justify
- [ ] **32.4** One rule for anything that finishes in the background: `STABLE_IDLE_POLLS = 5` consecutive idle polls with no log growth **AND** an explicit completion tag (a single idle observation means nothing between tool turns; a tag can split across pipe flushes — so both, never one)
- [ ] Tests: the three-way formatter (refuted hidden at 0, honesty with no data) · the advisor checkpoint wiring · the gate's four messages · the idle-stability counter

---

## Phase 33 — The TUI at a mature harness's level

`✨ feature · 🔴 · the port list · source: docs/analysis/tui-chrome.md`

> The reference is a TUI written in TypeScript + Ink, read line by
> line. 42 candidate features: **18 PORT**, **15 ALREADY** (we are equal or
> better), **9 SKIP** (with reasons). The full table is in
> `docs/analysis/tui-chrome.md`; this is the board version, and the porting
> notes for the top rows are in §4 of that file.
>
> **The rule of the phase**: nothing enters the TUI that does not answer a
> question the user actually has. A decorative port is a port that costs
> frames and buys nothing.

- [x] The **effective** effort level (`chat.effortSupport` decides whether there is a knob at all) — the preference is not the same thing, and showing it would be a lie: the footer would say `xhigh` while the wire carries `high`
- [x] The permission-mode **glyph** (`○ ◐ ● ◉`, the four shapes the reference implementation uses) — a word costs 12 columns in a footer that has to survive an 80-column terminal
- [x] …and with it, `accept edits` becomes visible again: the test that pins "the normal permission modes cost NOTHING on the row" is a decision about COLUMNS, and a glyph is one column. **The test was rewritten on purpose** (the default still costs nothing; a deviation costs ONE column) and the legend of the glyphs lives in the shortcut list (`?`)
- [x] Counts assistant **turns**, not entries (the reference implementation counts them the same way): a tool line is not an answer the reader is missing
- [x] The baseline moves with the reader: leaving the bottom starts a count, reaching it ends the one that was running
- [x] The **pill** over the transcript: a centred "3 new messages" that floats over the scrollback. It covers the last row on purpose — a control on its own row would move the transcript every time it appeared
- [x] It names the turn you are reading: the last `.user` paragraph at or above the anchor
- [x] It goes OVER the transcript's first row and **only when the reader is away from the bottom**. A reserved row was tried FIRST and it moved the text under the reader's eyes (10 tests and a crash in the click/selection math): a header that appears and disappears takes a row away exactly when the reader is looking
- [x] The editor's own convention: a sticky line covers the content under it
- [x] **33.4** The transcript screen (`ctrl+o`) — a VIEW of our own history, not new content; `ctrl+e` shows all
- [x] **33.5** The bottom-anchored modal pane with a `▔` divider — a pane that keeps 2 transcript rows visible beats a centred box that hides the context
  - [x] The query as a **subsequence** of the label, with a WINDOW (three times the query plus eight) so the fallback does not match half the catalogue
  - [x] Leftmost and **runs win**: "bc" in "a-xbc" highlights the run and not a scattered "b"
  - [x] The matched characters are painted in the accent colour, and the positions are BYTE offsets joined to the painting at the grapheme's first byte
  - [x] The fuzzy is a FALLBACK: an exact match always wins, so the item the user meant is never pushed down
  - [x] **33.6** Filtered results sort by match score (exact/prefix/substring/fuzzy, best first; ties keep original order). With no query the list stays in its deliberate order (providers/free-first as provided) so the default ordering is unchanged.
- [x] **33.7** The picker with a **preview pane** (at the bottom or at the right) — the model preview (context window, price, free) is the most useful picker addition we do not have
  - [x] It has to be a **bottom pane**, not a third column: at 110 columns there is no room for a third one
  - [x] The parser receives the WIDTH (`DiffOpts.width`), because "does it fit" is a question only the width can answer
- [x] **33.9** The notifications channel — a transient queue for "the updater restarted", "the IDE connected", "the token budget is nearly gone"; absolutely positioned, so nothing shifts (stacked top-right toasts in `src/tui.zig`, `Model.pushNotification`; updater flow emits notifications)
- [x] **33.10** The context visualisation — we compute the numbers; the reference implementation draws a proportional chart per category (system, tools, messages, skills, compaction reserve) (`/context` shows a proportional breakdown bar and per-category estimates)
- [x] **33.11** The task panel with blockers and priorities — **the data model already exists** (`src/lib/taskstore.zig`: `blocks`/`blocked_by`/`hasOpenBlocker`) and is now surfaced via `/tasks` (panel view with blocked/ready/in-progress/completed counts, dependency/blocker details, and priority-ordered listing)
- [x] **33.12** The per-message actions — `shift+↑` targets the message under the cursor; ours has `/copy N` and no per-message targeting
- [x] **33.13** The transcript search (`/` and `n`/`N`) — our paragraphs are already segmented, so the scan is over the segments, not the cells
- [x] **33.14** OSC 8 hyperlinks — the paths and the URLs as real links; the detection is ~30 lines and vaxis exposes the cell attributes
- [x] **33.16** The external editor (`ctrl+g`) and the image paste (`ctrl+v`) — the image path already exists (`src/lib/images.zig`)
- [x] **33.18** The modal diff viewer — only worth it once a turn can produce multi-file diffs
- [x] **33.19** The compact-summary line — after a tier-2 compaction the transcript loses history **silently**; one honest line says what was summarised
- [x] **33.21** The permission dialog with the **rule** explanation — which rule matched, and the rule the user could accept instead of a bare "always allow" (shows the matched `ask` rule as "asked by rule: …", shows the scoped rule the "always allow" answer would remember, e.g. `Bash(git *)`; stale rule/suggestion state cleared between dialogs)

**What we deliberately do NOT copy** (and why) — the reasoning is in
`docs/analysis/tui-chrome.md` §5: the alternate screen (it destroys the
terminal's native scrollback), the random-verb spinner (our phase label says
more), the boxed prompt (our rule costs 1 row instead of 3), the user-defined
status line (an execution surface we do not need) and the shimmer animation (a
permanent CPU cost for a decoration).

---

**Where we are BETTER than the reference implementation** (so nobody ports it
backwards) — `docs/analysis/harness.md` §4 lists ten: the exit gate, the
`goal` checkpoint, the `verdictCredible` refusal, the `batch` sandbox, the
"stale green" detection (no equivalent there), the free-model rotation, the
edit hint, the repetition guard, the `ask` cap and the `proofWord` precision.
