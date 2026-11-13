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
- [ ] 🔴 **Sprint A3 — Phase 34** (the machinery the reference implementation has and we do not): remaining mechanisms beyond core permissions/rules; **34.1 path-scoped permissions is done** (resolved-path checks, deny rules, dangerous-path/secret protection, `Tool(pattern)` rules), with follow-ups noted in Phase 34.
  **2.1 done** (budget listing); **2.2 done** (skills once per session at end of prompt);
  **2.3 done** (named args `$1`, `$name`); **2.4 done** (`context: fork` via subagent);
  **2.5 done** (`!cmd` output substitution behind Phase 6 permissions).
- [x] 🟡 **Sprint C — Phase 3 → 7 → 10** (recoverable results → compaction v2 → background tasks) — complete.
- [x] 🟡 **Sprint D — Phase 6 → 5 → 25** (permissions → hooks → bash safety) — Phase 6 rule engine (permrules/load/enforce) + Phase 5 hooks (`.zode/hooks.json`, Pre/Post/UserPromptSubmit/Stop, `if` via permission-rule syntax) + Phase 25 bash classification/sandbox offer complete.
- [x] 🟡 **Sprint E — Phase 35** (the command surface): complete (35.1–35.15, including `/mcp`, `/sandbox`, `/add-dir`, `/vim`).
- [ ] 🟡 **Tool track — Phase 25 → 26 → 20** (bash safety → roles → teams); 20 waits on 15, 32 on 26
- [ ] 🟡 **Phase 30** (names/forks/restore): Phase 29 complete; Phase 30 pending (30.3 summaries, remaining 30.5 resume restore) — **30.2 auto-titles and 30.4 `/branch` done**
- [ ] 🟢 Everything else per the dependency table at the bottom.

**Done since the board was written**: Phase 0 (tool registry + result cap) · Phase 1 (bundled skills +
rich frontmatter) · Phase 12 (MCP over stdio + deferred tool loading) · Phase 14 (LSP client) ·
Phase 15 (task graph) · Phase 16 (`batch` tool) · Phase 19.1 (`sleep`, claimed; Phase 19 section still pending) · Phase 25.1 (bash safety classify) ·
Phase 27 (diff with gutter + word diff + colour ladder) · Phase 28 (`/copy`) · **Phase 2.1** (skill listing
budget) · **Phase 2.2** (skills once per session at end of prompt) · Phase 35.1 (`/files`) ·
Phase 35.2 (`/init`) · **Phase 36** (use-after-free crash, worker lifetime/counting audit, and build-step fixes) · **Phase 4** (output
styles: project/user discovery with shadowing, both layouts, `/style`, bundled `default`/`explanatory`/`learning`) · Tool upgrades
(grep context, bash description, read PDF, glob subdir).

**Completed phase sections removed from the board (all checklist items done):** Phase 3, 5, 6, 7, 10, 11, 24, 25, 29, 31, 36.

**The analysis behind the new phases** lives in `docs/analysis/`:
`tui-chrome.md` (the TUI port list, 42 features) · `commands.md` (72 reference
commands, 26 gaps) · `harness.md` (the machinery gaps) · `audit.md` (our own
state, the open bug and the quality bar).

---

## Phase 2 — Skill listing budget + args + inline/fork

`✨ feature · 🔴 · depends on 1`

---

## Phase 8 — Prompt-cache break detection

`⚡ tokens · 🟡 · independent · pairs with /cache`

## Phase 9 — Agent definitions on disk

`✨ feature · 🟡 · independent · basis for 26`

---

## Phase 13 — Ecosystem

`⏳ optional · 🟢 · only if usage asks for it`

- [ ] Plugins/marketplace · remote sessions · keybindings/vim mode — outside the core (basic vim input mode toggle `/vim` implemented for 35.13; rest pending)

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

### What was done, and what it cost to find out (2026-10-21)

The three pieces (the word diff, the gutter, the colour ladder) were **written and
never wired**: the gutter's caller passed `null, 0`, the ladder was called from
nowhere outside `theme.zig`, and the word diff compared the indices of one token
list against the indices of another. The first job was not writing the diff: it
was finding out what was already there and what was broken about it.

**The LCS was filling the table with the SUFFIX convention and walking it back
with the PREFIX one.** The table had the right shape and the wrong answer, and
the word diff it fed marked the wrong tokens. It looked right whenever the two
lines happened to line up, which is most of the time in a small edit.

**The word diff is computed where the diff is PAINTED.** The ranges used to
travel in a map keyed by the line's TEXT, which was copied, freed and
re-hydrated in five places (the paragraph, the pending item, the drain, the
compression and the Ctrl+R toggle). Now `diffview.analyze` reads the diff text
once and says what every row is: its number, the width of its hunk's gutter and
the words that changed in it. The map is gone, and with it five places that
could forget to free it.

**A diff is not prose.** A deleted line starts with `- ` and the markdown
parser read that as a BULLET: the row came out as a list item and the `+`/`-`
that says what happened was gone. The diff now has its own path through the
parser, before the fences, the headings, the quotes and the lists.

**The highlighter's state is per SIDE, not per hunk.** A `-` row is a line of
the old file and a `+` row is a line of the new one, so there are two states:
a deleted line that opens a multiline string used to leave the ADDED line
painted as inside a string.

**Two tints per side.** The row is the band (the reader sees "this row is new")
and the words are the point (the reader sees "this is what is new inside the
row"). With ONE tint the changed words disappear into their own row, and a
rewrite is a green wall.

**The 256-colour ramp is a COMPETITOR and it was not one.** `ansi256FromRgb`
only considered the grey ramp for colours with a saturation under 0.15, which
is the fallback behaviour the rule warns about: a near-black green tint
(#08120b) went to the cube, which has nothing between #000000 and #333333 in
it, and the band the tint was supposed to paint disappeared. Both candidates
are built now and the closer one wins.

**The ladder is applied where the cell is written** (`Painter.putStable`), so
there is ONE place that can send a colour the terminal cannot show. vaxis
writes `38;2;r;g;b` whatever the terminal answered, and it does not ask: its
own `COLORTERM` sniffing is commented out in the library. So the app asks the
environment (`NO_COLOR`, `COLORTERM`, `TERM`), which is where every terminal
documents the answer.

**Not ported**: the `dim` style of the upstream. A collapsed preview is the
quiet box here: it shows the row tints and NOT the word highlights, and
Ctrl+R turns them on. That is the same rule with a different name.

---

## Phase 30 — Names, forks, and a resume that restores

`✨ feature + 🐛 fix · 🟡 · independent; writes what 29 reads`

- [x] **30.2** Automatic session titles (free first, AI upgrade later)
  - [x] Turn 1: a title derived from the first prompt — synchronously, free
  - [x] Turn 3: AI title upgrade (background, effort `low`, never blocks) over the last 1000 characters of conversation (recent context wins, bounded); applied only when generation matches (turn-3 upgrade over turn-1/empty), session meta is unchanged/eligible, and there is no custom title (`/rename` race)
  - [x] Prompt/result constraints: asks for JSON-only `{"title":"..."}` or `null` (3–7 words, sentence case guidance/examples in prompt), parses JSON/null safely, rejects/ignores invalid results on failure
- [ ] **30.3** A running summary for the list: one line written at write time (no model call) every `min(5 steps, 2 min)` — in a three-hour session the first prompt is hours stale and the row is useless
- [x] **30.4** `/branch` — fork is not `/new`
  - [x] Copy the session JSONL into a new session id, stamp provenance (`forked_from` in session meta), and carry side tables over (`.caps.json`, `.compact.json`, `tool-results/<stem>/`) · branch session file created with `0o600` permissions
  - [x] It names itself and tells you how back: reports `Branched "<title>". To resume the original: zode --resume <id>` and copies the resume command; collision ladder `foo`, `foo (Branch)`, `foo (Branch 2)` (custom branch title accepted via `/branch [title]`)
- [ ] **30.5** Resume restores more than messages: the id **and the project directory**, the cost state, the custom title, the tag, the agent definition — and the **plan**, by scanning the transcript for the last `todo` call (free: the plan block reappears on `--resume` with no new state file and no new failure mode)
  - [ ] Counters that only make sense across a session (prompts asked, permissions asked, ESCs) — turns `/bench` from a per-session number into a lifetime one
  - [ ] A defensive consistency marker in the transcript (a turn checkpoint recording how many messages it expected), compared on resume — our zjsonl has no integrity marker and a truncated resume is currently silent
- [ ] Tests: pure + fixture JSONL for fork provenance, title precedence (custom beats AI, generation counter), plan hydration, the consistency marker

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
- [ ] **33.4** The transcript screen (`ctrl+o`) — a VIEW of our own history, not new content; `ctrl+e` shows all
- [ ] **33.5** The bottom-anchored modal pane with a `▔` divider — a pane that keeps 2 transcript rows visible beats a centred box that hides the context
  - [x] The query as a **subsequence** of the label, with a WINDOW (three times the query plus eight) so the fallback does not match half the catalogue
  - [x] Leftmost and **runs win**: "bc" in "a-xbc" highlights the run and not a scattered "b"
  - [x] The matched characters are painted in the accent colour, and the positions are BYTE offsets joined to the painting at the grapheme's first byte
  - [x] The fuzzy is a FALLBACK: an exact match always wins, so the item the user meant is never pushed down
  - [ ] The list is still in the provider's order, and the reference implementation sorts by score. Ours is deliberate (the free models first), so sorting is a decision and not a port
- [ ] **33.7** The picker with a **preview pane** (at the bottom or at the right) — the model preview (context window, price, free) is the most useful picker addition we do not have
  - [ ] It has to be a **bottom pane**, not a third column: at 110 columns there is no room for a third one
  - [x] The parser receives the WIDTH (`DiffOpts.width`), because "does it fit" is a question only the width can answer
- [ ] **33.9** The notifications channel — a transient queue for "the updater restarted", "the IDE connected", "the token budget is nearly gone"; absolutely positioned, so nothing shifts
- [ ] **33.10** The context visualisation — we compute the numbers; the reference implementation draws a proportional chart per category (system, tools, messages, skills, compaction reserve)
- [ ] **33.11** The task panel with blockers and priorities — **the data model already exists** (`src/lib/taskstore.zig`: `blocks`/`blocked_by`/`hasOpenBlocker`) and is not surfaced
- [ ] **33.12** The per-message actions — `shift+↑` targets the message under the cursor; ours has `/copy N` and no per-message targeting
- [ ] **33.13** The transcript search (`/` and `n`/`N`) — our paragraphs are already segmented, so the scan is over the segments, not the cells
- [ ] **33.14** OSC 8 hyperlinks — the paths and the URLs as real links; the detection is ~30 lines and vaxis exposes the cell attributes
- [ ] **33.16** The external editor (`ctrl+g`) and the image paste (`ctrl+v`) — the image path already exists (`src/lib/images.zig`)
- [ ] **33.18** The modal diff viewer — only worth it once a turn can produce multi-file diffs
- [ ] **33.19** The compact-summary line — after a tier-2 compaction the transcript loses history **silently**; one honest line says what was summarised
- [x] **33.21** The permission dialog with the **rule** explanation — which rule matched, and the rule the user could accept instead of a bare "always allow" (shows the matched `ask` rule as "asked by rule: …", shows the scoped rule the "always allow" answer would remember, e.g. `Bash(git *)`; stale rule/suggestion state cleared between dialogs)

**What we deliberately do NOT copy** (and why) — the reasoning is in
`docs/analysis/tui-chrome.md` §5: the alternate screen (it destroys the
terminal's native scrollback), the random-verb spinner (our phase label says
more), the boxed prompt (our rule costs 1 row instead of 3), the user-defined
status line (an execution surface we do not need) and the shimmer animation (a
permanent CPU cost for a decoration).

---

## Phase 34 — The machinery the reference implementation has and we do not

`✨ feature · 🔴 · the gap list · source: docs/analysis/harness.md §3`

> Sixteen mechanisms of the reference implementation that no phase on this
> board owned. Every one was read in its **implementation**, not in its prose.
> Ranked by value per unit of risk.

- [x] **34.1** Path-scoped permissions and the dangerous-path protection — **DONE (2026-10-21, always-allow scoping completed 2026-11-08)**
  - The reference implementation: a path is allowed through SEVEN checks in this order — resolve the path → the deny rules → the internally editable paths → the **safety check** → the working-directory check → the sandbox allowlist → the allow rules. Its safety check blocks `.git/`, `.claude/`, `.vscode/`, `.idea/`, the shell configs and the UNC paths. Zode implements the core (resolved path, deny rules, dangerous-path/secret safety check with ask+approval, `Tool(pattern)` allow/deny/ask/dontAsk, project+user rules, and path-scoped enforcement); working-directory and sandbox allowlists remain separate mechanisms.
  - [x] `src/lib/pathsafe.zig` (new, pure): the table, matched **by SEGMENT and case-insensitively** (`a/b/.git/hooks/x` and `.Git/hooks/x` are both caught; `myproject.git`, `zig-out-mine` and `.gitignore` are NOT), and a separate table for the files whose CONTENT is a secret
  - [x] Wired into `write`, `edit`, `notebook_edit` (per file: one bad path does not lose the good ones) and into `read` — `read` never asks for permission, so it was the only place a secret could be refused before going to the provider
  - [x] The refusal NAMES what writing there would do ("a hook there runs on every commit") and points at `bash`, which asks the user
  - [x] **It ASKS now, it does not refuse** (2026-10-21): the dispatcher finds the risky paths of the call, opens a question that says WHICH path and WHY, and the answer approves that one path. The tool cannot ask (it has no `Model` and cannot see a dialog), so the answer comes back through `pathsafe.approve` — the one place both can reach. The question has **no "always allow"**: a rule that remembers "the agent may write inside .git/" is the opposite of the rule
  - [x] `rename` is wired in too: it finds its own files, so its arguments NEVER name them, and it is the tool a rename reaches that the dialog could not ask about
  - [x] The multi-file form of `edit` (`files: [{path,…}]`) is in the permission detail AND in the risky-path question: the dialog used to name NO file for a call that touches eight
  - [x] **The path it RESOLVES to is checked too** (2026-10-21): a symlink with an innocent name (`ln -s .git/hooks hooks`) is a path whose NAME says nothing and whose TARGET is exactly what the rule protects. The resolver is component by component and in PURE ZIG (`readLink`), not `realpath(3)`: this project has no libc dependency
  - [x] The `Tool(pattern)` grammar — **DONE 2026-10-21**: `src/lib/permrules.zig` (pure) parses `Tool(pattern) action` (`allow` / `deny` / `ask`, the action optional and defaulting to `allow`), matches the pattern as a glob over the thing the call acts on (the PATH for a file tool, the COMMAND for `bash`), and decides by precedence. The rules live in `.zode/permissions.json` (the project) and `~/.config/zode/permissions.json` (the user), and `/permissions` prints them
  - [x] The "always allow" answer remembers the **scoped pattern rule** it suggests (e.g. `Bash(git *)`, `Write(src/main.zig)`), not a flat whole-tool allow: `rememberAlwaysAllow` learns the rule into `perm_rules` as `local` (strongest) and persists it, and does not fall back to the coarse flat allowlist when a safe scoped rule was learned.
- [x] **34.2** The **frozen decision** of the result cap — **DONE 2026-11-08 (session wiring completed)**
  - The reference implementation: the cap layer keeps a **frozen decision** — a cut is re-applied verbatim on every later turn instead of being recomputed — and it rebuilds that state from the transcript on resume
  - Ours: `src/lib/resultcap.zig:78` `capAggregate` recomputes per call
  - [x] A `Caps` state (result id → the cut that was made), persisted next to the session and reloaded on resume — **DONE 2026-10-27/2026-11-08**: `resultcap.Caps`/`CutRecord`, `frozenCapResult`/`frozenCapAggregate`, `serializeCaps`/`deserializeCaps` (pure tests). Session lifecycle wired: `Session.result_caps` field, `saveCapsSidecar`/`loadCapsSidecar` (`.zode-caps.json` sidecar), loaded on `Session.load`/resume, freed on deinit, saved by agent after frozen cap decisions/tool-result capping (`s.saveCapsSidecar()`).
  - [x] Why it matters covered: a session that compacts differently on resume silently loses its cached prefix — the frozen cut prevents this by re-applying the same cut.
  - `permrules.Action` gained `dontAsk` (34.12) and now `dangerous_patterns` + `isDangerousPattern()` flag bare interpreters with broad patterns (`bash(*)`, `python(*)`, …). `shadowedRule()` detects when an `allow` rule can never fire because another rule covers it (deny beats allow always; stronger source or later same-source rule wins; `ask`/`dontAsk` never shadow).
  - `agent.zig`: `setAlwaysAllowed` and `allowAlwaysFor` now warn once per session about dangerous broad allows (bash `*` or empty, or any interpreter tool with `*` pattern), via `warnDangerousAllowOnce()`. Warning is informational, not a refusal.
  - 9 new pure tests in `permrules.zig` (isDangerousPattern, shadowedRule allow/deny/same-source/ask).
  - The reference implementation: a cost tracker that multiplies the token counts by the model's price, and a `/cost` command that prints the total and the per-model breakdown
  - Ours was tokens and hit-rate (`src/cache_stats.zig`), no money
  - [x] `src/lib/cost.zig` (pure, tested) over the price `src/lib/models.zig` already parses. `/cost` reads the price from the **cached** catalogue (`modelcache.zig`), never the network
  - [x] A model whose price is unknown prints **"price unknown"**, never a number; the total then says it is a floor, and a session with NO priced row prints "no total" instead of `$0.00`
  - [x] Per MODEL and not one bucket: `free-auto` rotates, the cheap router falls back and `/submodel` sends subagents elsewhere, so the row is the model that **answered** (`pick.model`), not the one that was selected
  - [x] A resumed session says which tokens are not in the breakdown: the per-model rows live in memory and the token totals are restored from the session file
  - Where: `commands.cmdCost` + the dispatch in `agent.zig` · `recordSessionUsage` now takes the model · the price decision (`free` / `unpriced` / `priced`) is `cost.priceOf`, so it is tested with no catalogue on disk
- [x] **34.6** Hook output contract subset (`updatedInput`, `additionalContext`, permission decisions) — **DONE 2026-11-08 (core contract wired)**
  - [x] `hooks.RunResult` carries `additional_context`, `updated_input`, `permission_decision`, `system_message` and parses JSON stdout contract (`additionalContext`, `hookSpecificOutput`, `systemMessage`, `updatedInput`, `permissionDecision` allow/deny/ask). Structured deny blocks.
  - [x] `PreToolUse` can block and apply `updatedInput`; `PostToolUse`/`UserPromptSubmit` notes/additional context fed back; `freeResults` owns cleanup.
  - [~] Broader upstream parity still open: 27 events and 5 hook types (Phase 5 has command hooks only).
- [ ] **34.7** The memory recall by relevance and the staleness notes — Phase 11 has the store, not the recall
- [ ] **34.8** The background **subagents** (not the background shell jobs) — **NOT COVERED**
  - The reference implementation: the agent tool can run a whole agent in the background; Phase 10 is about `bgproc`
  - [ ] `run_in_background: bool` on the `task` tool, and a **notification to the model** when it lands
- [ ] **34.9** The atomic task claiming — **NOT COVERED** (the reference implementation has a `claim` operation): three parallel agents must not take the same task
- [~] **34.14** The `PermissionRequest` hook path for the headless runs — **PARTIAL 2026-11-08**
  - [x] `PermissionRequest` event added (`hooks.Event`) and fired in `agent.execOneCall` permission flow before the dialog; hook can return allow/deny/ask (JSON contract) and is honored (pathsafe/rule checks still apply).
  - [ ] Headless `--chat` still executes tools via `main.execHeadless` (effectively yolo/direct tool exec), bypassing `agent.execOneCall` permission dialog/hooks; a full headless PermissionRequest path needs wiring there or a shared permission/tool-exec path.

**Where we are BETTER than the reference implementation** (so nobody ports it
backwards) — `docs/analysis/harness.md` §4 lists ten: the exit gate, the
`goal` checkpoint, the `verdictCredible` refusal, the `batch` sandbox, the
"stale green" detection (no equivalent there), the free-model rotation, the
edit hint, the repetition guard, the `ask` cap and the `proofWord` precision.

---

## Phase 35 — The command surface we do not have

`✨ feature · 🟡 · the gap list · source: docs/analysis/commands.md`

> 72 commands of the reference implementation, inventoried one by one. 26 gaps
> (MISSING or PARTIAL), each with the behaviour, what it does and a Zig port's
> home. The ~30 commands that are Anthropic-account or marketplace surface are
> **not** gaps and are listed as such, so nobody goes looking for them.

- [x] **35.3** `/rename` + the `#tag` + the session title — **S** each, and together they are the readability layer of the session list. `/rename` now sets custom title and/or `#tag` (`/rename <title>`, `/rename #tag`, `/rename <title> #tag`); tags are persisted in session meta and shown in the session picker/list (`· #tag`). Session title resolution (custom/AI/name/prompt/id) was already in place.
- [x] **35.4** `/review` and `/security-review` — **S-M** each. Prompt commands with verified git context via `` !`cmd` `` substitution (Phase 31.1) and read-only scoped allowlists: `/review` for correctness/regressions/risks and `/security-review` for security-focused findings (both accept optional focus instructions).
- [x] **35.5** `/clear` (with the cache reset) and the `/exit` alias — **S**. `/new` exists but leaves the read cache, the skills-sent marker and the user commands stale — implemented: `/clear` clears the transcript and resets session caches (read list, changed list, skills re-attached next turn); `/exit` alias of `/quit`.
- [x] **35.6** `/doctor` — **M**: the one command you run when zode behaves strangely. Half the checks (the key state, the config, the session dir's permissions) we already compute elsewhere — implemented: version, model, context window, effort, output style, permission mode (+yolo/read-only/accept-edits), API key (set/not set, never the value), compaction mode/threshold/limit/budget, session dir, elided results.
- [x] **35.7** `/config` + `/status` + `/usage` as ONE panel — **M**: implemented `renderStatusPanel` shared helper; `/config`, `/status`, `/usage` all render the same unified panel (version, model, context, effort, style, permissions, key, compaction, usage, session). `/doctor` builds on it with extra diagnosis details.
- [x] **35.8** `/compact` on demand — **S-M**: implemented `/compact now` — runs tier-1 elision immediately on the live session, reports elided count and new estimate, and tells when tier-2 summary will trigger next turn.
- [x] **35.9** `/release-notes` + `/version` — **S**: two one-liners over `src/lib/selfupdate.zig`, which already runs at startup with nobody told — implemented: `/version` shows the running version; `/release-notes` shows the matching CHANGELOG.md section (Unreleased for dev builds), read locally with no network.
- [x] **35.10** `/diff` — **DONE**: `/diff` shows uncommitted changes (git status + `git diff --no-color -U3 HEAD`, rendered as a diff block) and, when the current turn has changed files (`agent.turn_stats.files`), that turn's changed-file diff (`git diff HEAD -- <files>`). Not a git repo is reported clearly. Registered in the command table/palette and dispatched; command tests added in `src/commands.zig`.
- [x] **35.11** `/permissions` (rule panel) · `/hooks` (hooks panel) · `/agents` (subagent/definitions status panel) — **DONE (panels, 2026-11-08)**. `/permissions` shows mode, Phase 6 rules with source/precedence and dangerous/shadowed hints, legacy allowlist, and file paths; `/hooks` shows loaded Phase 5 hooks from `.zode/hooks.json`; `/agents` honestly reports current `task` subagent constraints and that definitions/roles/teams (Phases 9/26/20) are not implemented. Read-only panels (engines exist for permissions/hooks; agents definitions do not yet) — edit config files directly; interactive in-TUI editing remains future work.
- [x] **35.12** `/rewind` (an arbitrary point, not the last turn) · `/compact` · `/resume` as a picker — covered by Phases 29 and 30. `/rewind [N]` lists checkpoints (no args) or undoes the last N turns' file changes; `/compact` on demand (`/compact now`, 35.8) and `/resume` picker (Phase 29) are already in place.
- [x] **35.13** `/add-dir` · `/sandbox` · `/mcp` · `/vim` — implemented as command/panel support: `/add-dir [path]` adds/lists extra session directories, `/sandbox` and `/mcp` status panels, `/vim` toggles basic vim-style modal input editing (Phase 13 keybindings/vim mode groundwork).
- [x] **35.14** `/btw` (a side question that does not interrupt) — **S**: one subagent call whose answer is appended, not a turn. Implemented as `/btw <question>`: runs a read-only subagent in a background thread and appends the answer as an info block (no main turn, no iteration budget).
- [x] **35.15** The **name collision** to settle: the reference implementation's `/color` sets the agent colour and ours sets the **diff palette**. Renamed to **`/diff-color`** (canonical; `/color` kept as legacy alias) so agent colour can take `/color` later.

**Not gaps** (surface that is Anthropic-account, browser or marketplace, and
that we are not going to copy): `/login`, `/logout`,
`/upgrade`, `/usage`, `/feedback`, `/bug`, `/release-notes`'s browser half,
`/channel`, `/theme`, `/sandbox`'s cloud half — listed in
`docs/analysis/commands.md` §3.26 with the reason for each.

### 35.1 — What `/files` was, and what it found (2026-10-21)

**The data was already there and nothing showed it.** The read cache knows
every file the model has read; `/context` showed its counters and no place
showed the FILES. The board called it "eight lines of work" and it was more
than that, because the honest answer needs two lists and not one.

**Two lists, because they are two different facts.**

- **READ**: the files the model has read, most recent first, and whether their
  content is STILL in the context. A compacted-away read is not in the context
  any more, and saying so is the difference between "the model has this" and
  "the model THINKS it has this" — the second one is how an agent quotes a
  file it never saw.
- **CHANGED**: the files the agent WROTE to, this session. A question about
  "what did it do to my repo" is about the whole session, not the last turn.

**The changed list is recorded on the SUCCESS path, not from the list of
calls.** A denied `edit`, a `write` to a path that could not be opened and an
`edit` whose old string was not found all changed nothing, and a list that
says "changed" about them is a list that lies. `callTouchedPaths` knows the
multi-file form of `edit` and the writing steps of a `batch`; `filePathOf` does
not, and a `rename` is in neither (it FINDS its own files, and its arguments
never name them).

**The list says what it does not know.** A `bash` that was not read-only may
have changed files, and a command is a string and not a list of files: the
report says so instead of implying that the list is complete. Same for the
files that did not fit in the table (64) and for the ones the read cache
evicted (128, LRU).

**The bug it found: the read cache survived `/new`.** The cache is in the
`Model` and the Model outlives a session change, so after `/new` the entries
still said "the model has this file" — and the first `read` of a file the
PREVIOUS session had read took the fast path, answered "it is already in your
context" and did NOT send the body. The new session's context is empty, so
the model would have been working from a file it could not see, and it would
have said so with the confidence of somebody who had read it. `/new` and
`/resume` now clear it (`agent.resetSessionFiles`).

**Where it is**: `src/lib/filesview.zig` (the report, pure and tested) ·
`src/lib/readcache.zig` (`withAll`, `statsSnapshot`, `clear`) ·
`src/commands.zig` `cmdFiles` · one row in the command table · the hook in
`agent.execOneCall` · `tools/pty_smoke.py` types it (a command can be
unit-perfect and still do nothing when it is typed).

---
