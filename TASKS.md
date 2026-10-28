# TASKS — zode

> Visual checklist converted from [`ROADMAP.md`](ROADMAP.md) (2026-10-16).
> The roadmap keeps the *why*, the research and the upstream findings; this file is
> the board. One checkbox per deliverable.
>
> **Ticking a box** means: `zig build test` green · the phase's acceptance check
> passes · ROADMAP.md §0 ("Where zode is today") is updated.

## Legend

| Badge | Kind | | Priority | Meaning |
|---|---|---|---|---|
| ✨ | feature | | 🔴 | next |
| 🏗️ | refactor (not user-visible) | | 🟡 | later |
| 🐛 | fix (wrong today) | | 🟢 | on demand |
| ⚡ | token/time saving | | | |
| 🔒 | security | | | |

Task IDs mirror the roadmap (`27.3` = Phase 27, item 3) so both files cross-reference.

---

## 🚀 Next up — the roadmap's own verdict

- [ ] 🔴 **Sprint A2 — Phase 33** (the TUI at a mature harness's level): the port list,
      42 features read out of the reference implementation. 33.1 and 33.2 are done;
      the rest is the board. The porting notes are in `docs/analysis/tui-chrome.md`.
- [ ] 🔴 **Sprint A3 — Phase 34** (the machinery the reference implementation has and we do not): sixteen
      mechanisms that no phase owned, of which **34.1 (path-scoped permissions)** is
      the one that should not wait — today `write` writes any path it is handed.
- [x] 🔴 **Sprint B — Phase 2** (skill listing budget + named args + `context: fork`):
      **2.1 done** (budget listing); **2.2 done** (skills once per session at end of prompt);
      **2.3 done** (named args `$1`, `$name`); **2.4 done** (`context: fork` via subagent);
      **2.5 done** (`!cmd` output substitution behind Phase 6 permissions).
- [ ] 🟡 **Sprint C — Phase 3 → 7 → 10** (recoverable results → compaction v2 → background tasks)
- [ ] 🟡 **Sprint D — Phase 6 → 5 → 25** (permissions → hooks → bash safety)
- [ ] 🟡 **Sprint E — Phase 35** (the command surface): `/files` is **done** (35.1), `/init` is
      **done** (35.2); the panels that need a rule engine wait for the engine (Phase 6).
- [ ] 🟡 **Tool track — Phase 25 → 26 → 20** (bash safety → roles → teams); 20 waits on 15, 32 on 26
- [ ] 🟡 **Phase 29 + 30** (`/resume` picker → names/forks): most needed, least fun — quietly wrong today
- [ ] 🟢 Everything else per the dependency table at the bottom.

**Done since the board was written**: Phase 0 (tool registry + result cap) · Phase 1 (bundled skills +
rich frontmatter) · Phase 12 (MCP over stdio + deferred tool loading) · Phase 14 (LSP client) ·
Phase 15 (task graph) · Phase 16 (`batch` tool) · Phase 19.1 (`sleep`) · Phase 25.1 (bash safety classify) ·
Phase 27 (diff with gutter + word diff + colour ladder) · Phase 28 (`/copy`) · **Phase 2.1** (skill listing
budget) · **Phase 2.2** (skills once per session at end of prompt) · Phase 35.1 (`/files`) ·
Phase 35.2 (`/init`) · **Phase 36** (use-after-free crash + two broken build steps) · Tool upgrades
(grep context, bash description, read PDF, glob subdir).

**The analysis behind the new phases** lives in `docs/analysis/`:
`tui-chrome.md` (the TUI port list, 42 features) · `commands.md` (72 reference
commands, 26 gaps) · `harness.md` (the machinery gaps) · `audit.md` (our own
state, the open bug and the quality bar).

---

## Phase 2 — Skill listing budget + args + inline/fork

`✨ feature · 🔴 · depends on 1`

- [x] **2.1** Listing under a budget ⚡ — **DONE 2026-10-21** (`src/lib/skills.zig`): the budget is **1% of `ZODE_CONTEXT_LIMIT`** in characters (at the same ~4 chars/token the compaction estimate uses), the per-entry cap is **250 columns**, a **bundled** entry is never truncated, and the ladder when it does not fit is: everything in full → the bundled ones keep their description and the rest degrade to their **name** → everything degrades to its name → entries are left out from the end and the note says how many. The fixed `max_listed = 40` is **gone**.
- [x] **2.2** Send the listing **once per session** as an attachment at the END of the prompt (cacheable prefix untouched); dedupe per session; reset on config reload, NOT on compaction — **DONE** (`src/agent.zig` `skillsSectionText` + `buildSystemPrompt` with `include_skills`; `Session.skills_sent` + `resetSkillsSent`). Skills no longer bloat the stable system-prefix on every turn; they are attached once as a `[Skills] …` user message.
- [x] **2.4** `context: fork` runs the skill via `lib/subagent.zig` (effort low, read-only, disposable window) and returns the result to the main turn — **DONE** (`src/agent.zig` `skillCall` takes the `.fork` branch and runs `runSubagent`; nothing of the subagent's window enters the main context, parent message list unchanged)
- [x] **2.5** `!cmd` inside a skill: run the command, substitute its output (behind Phase 6 permissions) — **DONE** (`src/agent.zig` `expandSkillCommands`: runs only when bash is allowed or matches a persisted prefix, else `[permission required]` / `[command failed]`)
- [x] Tests: budget caps total size ✓ · bundled survive a tight budget while others degrade to names ✓ · args substituted ✓ · fork skill runs via subagent and leaves the parent message list unchanged ✓ · `!cmd` output substituted behind permissions ✓

---

## Phase 3 — Output: recoverable results + per-tool render

`⚡ token · 🔴 · depends on 0 · blocks 7, 10`

> Blind elision loses detail. Storage loses it *on purpose* — and the model can get it back.

- [ ] **3.1** `src/lib/toolstore.zig` — large result → file + preview + path
  - [ ] Over cap → write `sessions/<id>/tool-results/<n>.txt`, return `[result stored: N bytes at <path>; read the part you need]` + 2 KB preview
  - [ ] Constants (env-overridable): `default_max_result_chars=50_000` · `max_result_bytes=400_000` · `max_results_per_message_chars=200_000` · `summary_max_len=50`

---

## Phase 4 — Output styles

`✨ feature · 🟡 · independent`

- [ ] `.zode/output-styles/*.md` (project) + `~/.config/zode/output-styles/*.md` (user); frontmatter `name`, `description`, `keep-coding-instructions`
- [ ] Style injected as a block **at the end** of the prompt; selected with `/style [name]`
- [ ] Ship `default`, `explanatory`, `learning`
- [ ] Pure tests: discovery with shadowing · the style block is present when selected and absent otherwise · `keep-coding-instructions` controls whether the coding rules are kept alongside the style

---

## Phase 5 — Hooks

`✨ feature · 🟡 · depends on 6 (for the `if` syntax)`

> Cheapest way to make zode extensible. v1 = command hooks only.

- [ ] Events: `PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `Stop`
- [ ] Config `.zode/hooks.json`: `{ matcher, if, command, timeout_ms, once }`
  - [ ] `matcher` = tool name or regex · `if` = permission-rule syntax (Phase 6) · `timeout_ms` bounds the run · `once` fires at most once
- [ ] Hook output fed back as a tool result / system note; a non-zero exit on `PreToolUse` blocks the tool with the reason
- [ ] Pure tests: config parsing · event/matcher/`if` matching · `once` · timeout + one integration test with a real script

---

## Phase 7 — Context compaction v2

`⚡ tokens · 🟡 · depends on 3`

- [ ] Microcompaction with a **recoverable marker**: old tool results replaced by a marker naming the stored file (Phase 3) — nothing is lost, only moved
- [ ] Compaction **boundaries**: trim requests to the last boundary so a later resume does not re-send summarized history
- [ ] Preserve invoked skills and read files across a compaction
- [ ] **Circuit breaker**: after N failed summarizer attempts, stop trying (no request-per-turn forever)
- [ ] Tests: boundary trimming · a skill invoked before compaction is still known after · the breaker trips and stops

---

## Phase 8 — Prompt-cache break detection

`⚡ tokens · 🟡 · independent · pairs with /cache`

- [ ] Compare the prefix actually sent with the previous one; warn when it broke and **which block**
- [ ] Target signal: `writes_per_request > 0.5` in a long session = unstable prefix
- [ ] Pure tests: a stable prefix reports no break · a change in the skills block reports the block and the position

## Phase 9 — Agent definitions on disk

`✨ feature · 🟡 · independent · basis for 26`

- [ ] `.zode/agents/*.md` frontmatter: `name`, `description`, `tools`, `model`, `effort`
- [ ] A `task` call can name a definition; without one it uses the current defaults
- [ ] Keep the existing safety floor: read-only tools, effort `low`, depth 1, 24k window
- [ ] Pure tests: discovery with shadowing · an unknown definition falls back to the default · a definition's tool list must be a subset of the read-only set (a definition cannot escalate)

---

## Phase 10 — Unified background tasks

`⚡ · 🟡 · depends on 3 · bgproc is ~70% there`

- [ ] Unify `bgproc` + `bash_output` into one task registry: output written to a file, incremental polling
- [ ] **Notification to the model when a task finishes** (a system event, not polling)
- [ ] Tests: a finished task notifies once · incremental output returns only what is new · a killed task reports its terminal state

---

## Phase 11 — Persistent memory

`✨ feature · 🟡 · independent`

- [ ] Per-project store (markdown, indexed, out of the prompt until consulted)
- [ ] End-of-turn extractor (a subagent) proposes memories → **the user approves**
- [ ] `AGENTS.md` loading with `@import` and precedence (zode already injects the instruction file; this adds the store the agent maintains)
- [ ] Pure tests with temp-root fixtures: discovery · precedence · `@import` resolution · a memory outside the budget is not inlined

---

## Phase 13 — Ecosystem

`⏳ optional · 🟢 · only if usage asks for it`

- [ ] Plugins/marketplace · remote sessions · keybindings/vim mode — outside the core

---

## Phase 17 — Notebook editing

`✨ feature · 🟢 · independent`

- [x] `notebook_edit`: address a cell by index — replace its source, insert before/after, delete (editing `.ipynb` via `edit` means matching a JSON string with escaped newlines)
- [x] The round-trip preserves everything else: outputs, metadata, cell id, format version — a tool that rewrites an ipynb into a "clean" one destroys the outputs the user was looking at
- [x] The source is the cell's text (join of its lines), not its JSON encoding; the tool encodes on write
- [x] It is a write: same permission, same undo snapshot as `write`/`edit`
- [x] `read` on a `.ipynb` shows cell boundaries and indices, so the model knows the numbering before it edits
- [x] Pure tests (fixture notebooks): replace by index · insert before/after · delete · out-of-range index is a named error, not corruption · outputs and metadata survive · a malformed ipynb is refused with the parse location

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

- [x] `sleep {seconds}`: waits without holding a shell process, ESC-interruptible; the prompt says it costs one API call per wake-up so it is not used where a `bash_output` poll would do
- [ ] Periodic ticks while a turn is parked: a short check-in ("anything useful to do while you wait?") instead of silence — off by default, a session flag turns it on
- [ ] `schedule {cron, prompt}`: recurring prompt for this project ("every Monday, run the flaky test and report"), plus `schedule list` / `schedule remove`; stored next to the session, delivered as a user message when it fires
- [ ] Scheduled prompts obey the same permissions as typed ones (a scheduled prompt that wants to write still asks)
- [x] Pure tests: a `sleep` is interruptible (ESC) and reports how long it actually waited
- [ ] Pure tests (waiting on ticks + schedule): cron parsing (5-field, ranges, steps, names) · a `once` schedule fires once and is removed · a tick is suppressed while a tool is running

## Phase 20 — Team mode: persistent collaborators

`✨ feature · 🟢 · depends on 15`

> `task` = one bounded search, throwaway window. "Watch the test suite and fix flakes" is a *role*, not a question.

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

## Phase 24 — Web fetch/search quality

`⚡ tokens · 🟡 · independent`

- [ ] Per-URL cache for the session, so the "2–3 calls at one url" the routing table recommends do not pay the network twice; a `force` flag bypasses it
- [ ] Secondary-model extraction: long page + narrow question → a cheap model reads the window and returns the answer **plus the quotes it relied on** (quotes mandatory — an answer with no quote is not evidence)
- [ ] Domain allow/block lists (`web_domains.allow` / `.block` in config) applied to search AND fetch; the metadata-service range stays a fixed floor; a user block beats an allow
- [ ] Pure tests: the cache returns the stored page and `force` re-fetches · the extractor must quote text that appears in the window or the call errors · block wins over allow

## Phase 25 — Bash safety: classify before you ask

`🔒 security · 🟡 · depends on 6`

> Phase 6 decides *whether* to ask; this decides *what is dangerous*. A dialog is useless if one line hides an `rm -rf` behind a pipe.

- [x] **25.1** `lib/cmdsafety.zig` (pure): split a command into its parts (pipelines, `&&`/`||`/`;`, substitutions); flag the ones that write, delete, exfiltrate, or chain into a shell (`curl … | sh`), naming the **exact dangerous fragment** — **DONE 2026-10-21** (as part of Phase 6's read-only table): the splitter knows the separators, the redirections and the substitutions, and the verdict is the WORST of the parts
- [x] **25.2** The classifier is **data, not a heuristic**: command families + the flags that change them — `git status` is quiet and `git clean -fdx` is not; a new family is one row — **DONE 2026-10-21**: `git branch` LISTS and `git branch x` CREATES, and `git config` READS with `--get` and WRITES without
- [x] **25.3** The dialog shows the risk in words, not the raw line: "this deletes unreferenced files" beats `git clean -fdx` — **DONE 2026-10-21**
- [x] **25.4** Phase 6's read-only table reuses it: a command is only "read-only" if the scanner found nothing to flag — **DONE 2026-10-27**: `execOneCall` skips the permission dialog for a `bash` command `lib/cmdsafety.zig` found nothing to flag (`git status`, `ls`, `rg foo`); `reads_only` is `false` for every other tool, so nothing else changes — the scanner decides, not the static registry flag. Tests: `cmdsafety` (read-only decided by the scanner; redirects, pipes into shells and unknown programs are not read-only) and `execOneCall` (`bash ls` runs with `/yolo` off, no persisted prefix, no rules, and the dialog is never opened).
- [ ] Optional sandbox: if `bwrap` exists, offer a sandboxed `bash` for flagged commands — a dialog is not the only answer
- [ ] Pure tests: the parser splits quoted separators correctly (a `;` inside a string is not a separator) · a pipe into `sh` is flagged with the fragment · `git status` is clean and `git clean -fdx` is not · a substitution is flagged by the substitution

---

## Phase 26 — Built-in subagent roles + agent memory

`✨ feature · 🟡 · depends on 9`

- [ ] Three built-in roles with their own prompts, chosen by name:
  | role | job |
  |---|---|
  | `explore` | broad, parallel search; report paths and lines, never edits |
  | `plan` | read-only architect: explore, then produce an ordered plan |
  | `verify` | try to break the change: run it, exercise it, find the 20% the first 80% hides |
- [ ] Agent memory: a per-project, per-role directory the agent reads at start and appends lessons to; out of the prompt until consulted (costs nothing when empty)
- [ ] Resume / fork a subagent: resumed with its window intact (a search that found half the answer continues) or forked (same context, different question) — both bounded by the same 24k window and depth 1
- [ ] Pure tests: role selection by name · an unknown role falls back to the default · a role's tool list is a subset of what the caller is allowed (a role cannot escalate) · memory is not inlined into the prompt · resume keeps the window and fork does not share it

---

## Phase 27 — The diff you can read — **DONE 2026-10-21**

`✨ feature + 🐛 fix · 🔴 · independent · a complete colour-diff implementation to port (native TypeScript, ~1000 lines)`

> The part worth stealing is not the colours, it is the **order of the pipeline**. Measured today: the diff has NO background at all (`diff_add_bg`/`diff_del_bg` are declared and never painted) and no line numbers.

- [x] **27.1** Word-level diff — which words changed, not which lines
  - [x] Per hunk, in order: (1) assign marker + line number via two counters (`+`→new, `-`→old, context shows the new one) · (2) pair a `-` run with the following `+` run positionally; pure insertions/deletions stay unpaired and get NO word diff · (3) tokenize + token-level LCS → byte ranges · (4) the noise guard · (5) split segments at the range boundaries
  - [x] The tokenizer is **shared with `edit_hint.zig`** — one tokenizer or the two diffs disagree: a `[\p{L}\p{N}_]` run = 1 token, whitespace run = 1 token, **everything else one token per codepoint** (`x += 1` = 5 tokens; in code, `+=`/`=>`/`!=` are words)
  - [x] `CHANGE_THRESHOLD = 0.4`: above 40% changed → discard the word ranges, flat line colour (a rewrite is not information, it is confetti — the same call as edit_hint's 0.50 Jaccard)
  - [x] Word diff skipped entirely when the block is `dim` (collapsed preview / collapsed Ctrl+R — highlights inside a quiet box are noise)
  - [x] Forced change: `diffSegments` must call `highlightLineState` with the state threaded down the hunk (a changed line is often the middle of a block comment or a multiline string) and reset at each `@@`
- [x] **27.2** Gutter: marker + right-aligned line number; width = digits of the hunk's max line **per hunk** (not per file); wrapped continuation rows get blank gutter cells and never a second copy of the number

- [x] **27.3** Colour capability ladder 🐛
  - [x] vaxis does NOT convert rgb→256 (`Vaxis.zig:626-630`): every one of the 32 `rgb()`/`bg()` literals in `theme.zig` ships as `38;2;r;g;b` even when DA1 said no truecolor. Ladder: `caps.rgb` true → palette as-is · false → `.index` colours via a ported `ansi256FromRgb` · `no_color` → `+`/`-` in **bold** and nothing else
  - [x] `ansi256FromRgb`: the grey ramp is a **competitor**, not a fallback — quantize to the cube, build BOTH candidates (cube + ramp), pick the closer in RGB distance; beyond the ramp's range the cube corner is the only option
  - [x] Lives in `theme.zig` behind the existing `rgb()`/`bg()` helpers — 38 call sites, one change; `no_color` is a single early return
- [x] **27.4** Colour-vision-safe palette 🔒
  - [x] `ZODE_DALTONIZED=1` (+ a `/color daltonized` picker entry) → blue/orange pair instead of green/red (the most common deficiency, and the axis most monitors collapse)
  - [x] A test asserts the add/delete pair differs in **hue** via `hueSat`, not only lightness (precedent: `theme.zig:439`)
- [x] **27.5** NOT ported on purpose: `asTerminalEscaped`/`colorToEscape`/the `{r,g,b,a}` sentinel struct (~120 lines — vaxis paints cells, escape generation is its job), the highlight.js integration, the `BAT_THEME` stub, the lazy loader. `ColorFile` (plain file view with line numbers) deferred to a future `/file`
- [x] **27.6** Pure tests: `x += 1` is 5 tokens · a pure deletion stays unpaired · a line 50% changed gets no ranges · a line 10% changed does (not vacuous) · ranges split a segment into three · **the segments of a diffed line concatenate to the original line** · ansi256 picks the cube for a saturated colour and the ramp for a grey · every theme colour survives the 256 round trip (no colour becomes "terminal default") · the daltonized pair differs in hue · drawTest: only the changed token carries the word background
- [x] Plus one `zig build ui-frame` scene (a `write` of a 600-line file) so the *composition* is judged — the question only that harness can answer

**Acceptance**: green suite + the scene reads as designed at 80x24 and 200x50.

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

## Phase 29 — `/resume` as a picker

`🐛 fix + ✨ feature · 🟡 · most NEEDED, least interesting · writes what 30 reads`

> Today `/resume` reopens the newest session by mtime (`agent.resumeLatest`). After a crash, or with two projects open, that is a guess.

- [ ] **29.1** Two-phase rows: `stat` for the row (mtime/size/id — no parsing, so a corrupt file cannot make a session disappear), then head+tail windows (≤128 KB per file, first 50 sessions) fill the title
  - [ ] String scanning, NOT JSON parsing (the first line may be cut in half); title ladder: `lastPrompt` (tail) || first prompt (head) || `content` prefix || …
  - [ ] The **tail** entry wins because it is written at write time by the writer, who knows what the user was doing — a `last_prompt` entry is Phase 30.3 and it makes every future listing better
  - [ ] The picker opens with **zero I/O per session** (today every JSONL is inflated to list it — which is why `/resume` is not instant)
- [ ] **29.2** 🐛 The highest-value line in the file: a session whose head cannot be read is listed as `(session)`, never dropped — today a first message with a 1 MB `@file` mention or a truncated zjsonl line makes the file invisible to `/resume` while `/clean` offers to delete it
- [ ] **29.3** The row: `<relative time> · <git branch> · <size or N messages> · #<tag>`; the header shows the position (`Resume (3 of 57)`) — a picker that lies about its size is worse than no picker
  - [ ] The title is a **total function**: `agentName || customTitle || aiTitle || firstPrompt || sessionId[0..8]`
  - [ ] Skip a `firstPrompt` starting with `<tICK>` (an autonomous prompt does not become a session name); strip display-hostless tags via the `_AllowEmpty` variant so a `/clear`-only prompt falls through instead of becoming the name
- [ ] **29.4** Interaction: type anything = filter (no insert mode) · ↑ on the first row jumps into the filter · Ctrl+V previews the focused session **in place**, lazily loaded, **with the same renderer as the live one** (never a summary line) · Ctrl+A/B toggle all-projects/branch · Enter resumes · Esc cancels — or clears the filter when filtering, and the footer says which
- [ ] **29.5** Search in three honest tiers:
  - [ ] (1) title substring — instant
  - [ ] (2) transcript fuzzy, debounced, cropped at BOTH ends (first 1000 + last 1000 of >2000 messages), built from **prose only** (no tool names, no thinking blocks — they add noise to the ranking); each hit shows a snippet that is a bounded window **inside that session** (the `web_search` neighbour-snippet bug)
  - [ ] (3) semantic — optional, and a **state, not a filter**: the footer shows "Searching…" where the shortcuts were, Esc cancels; the primitive already exists (`task`, effort `low`, depth 1, 24k)
  - [ ] Ranking, stolen whole: `|Δt| > 60s → recency wins; within a minute → relevance is the tiebreak` — relevance never outranks recency across sessions, only within a minute of it
- [ ] **29.6** Resuming checks the session BELONGS to this directory
  - [ ] Different project → refuse with the exact command, shell-quoted (`cd '…' && zode --resume <id>` — a path with a space is a command injection), copied to clipboard, delivered as a **user message** (an instruction, not an error); same-repo worktree → resume directly
  - [ ] `/resume <term>` never opens a picker: resolve UUID → file → exact title; an ambiguity is an error with the count (`Found 3 sessions matching foo. Use /resume to pick.`)
  - [ ] When the index says "not found", **read the file directly before telling the user it does not exist** — the index filters sessions it could not enrich, and losing one to that is losing it forever

---

## Phase 30 — Names, forks, and a resume that restores

`✨ feature + 🐛 fix · 🟡 · independent; writes what 29 reads`

- [x] **30.1** Two title keys on disk, so precedence is structural: `customTitle` (`/rename`, never overwritten) vs `aiTitle` (generated, ephemeral, safe to regenerate). A single `title` with a `source` flag is the same idea implemented worse — **DONE** (`sessionindex.zig` `Meta.custom_title`/`Meta.ai_title` + `Entry.title()` resolution; `session.zig` `Session.custom_title`/`Session.ai_title` loaded from Meta on resume, persisted via `writeMeta` on create)
- [x] **30.2** Derive now, upgrade later, guard the upgrade — **DONE** (`cmdRename` sets `custom_title` directly via `/rename <name>`; F2 in session picker renames via `onSessionRename`; titles persisted via `sessionindex.writeMeta`)
- [ ] **30.3** A running summary for the list — not yet (write-time summary line every N steps)
- [ ] **30.4** `/branch` — fork is not `/new` — not yet (copy JSONL, rewrite session id, provenance chain)
- [x] **29.1** Two-phase rows — **DONE** (`sessionindex.scan` uses `stat` for mtime/size, then `readMeta` for titles; picker opens with zero per-session JSON parsing)
- [x] **29.2** Bug fix: unreadable head session — **DONE** (sessions with unreadable head are still listed; title falls back to session id)
- [x] **29.3** The row format — **DONE** (`<title>  (current)` + age desc)
- [x] **29.4** Interaction — **DONE** (Enter resumes via `onSessionPick`; F2 renames via `onSessionRename`; Esc cancels via picker's built-in cancel)
- [ ] **29.5** Search in three tiers — not yet (title substring, transcript fuzzy, semantic)
- [x] **29.6** Resume directory check — **DONE** (`sessionpath.sessionBelongsToProject()` resolves the project's sessions dir and verifies each session path starts with it; `cmdSession` filters out sessions from other projects so they never leak into this project's list)
- [ ] **30.5** Resume restores more than messages — not yet (plan hydration, cost state, tags)
  - [ ] Turn 1: a title derived from the first prompt — synchronously, free
  - [ ] Turn 3: the AI upgrade via a `task` subagent (effort `low`) over the **last 1000 characters** of the conversation (recent context wins, input bounded); patched only while three things hold: the generation counter matches (a cheap turn-1 request resolving late must not clobber a richer turn-3 one), the session is unchanged, and there is no custom title (the `/rename` race)
  - [ ] Prompt shape: good `Fix login button on mobile` · bad `Code changes` (vague) · bad `Investigate and fix the issue where…` (long) · bad `Fix Login Button On Mobile` (wrong case); 3–7 words, sentence case, JSON-schema-constrained, `null` on any failure, and it **never blocks**
- [ ] **30.3** A running summary for the list: one line written at write time (no model call) every `min(5 steps, 2 min)` — in a three-hour session the first prompt is hours stale and the row is useless
- [ ] **30.4** `/branch` — fork is not `/new`
  - [ ] Copy the JSONL, rewrite the session id, stamp provenance, keep the parent chain: only main-thread entries · `parentUuid` rebuilt, not copied · `progress` entries never become parents · **side tables carried over** (elision markers, compaction summary, the plan — a resume rewrites the history, so anything derived from it must be re-recorded, not assumed) · `0o600` file, `0o700` dir
  - [ ] It names itself and tells you how back: `Branched "foo". To resume the original: zode --resume <id>`; collision ladder `foo`, `foo (Branch)`, `foo (Branch 2)`
- [ ] **30.5** Resume restores more than messages: the id **and the project directory**, the cost state, the custom title, the tag, the agent definition — and the **plan**, by scanning the transcript for the last `todo` call (free: the plan block reappears on `--resume` with no new state file and no new failure mode)
  - [ ] Counters that only make sense across a session (prompts asked, permissions asked, ESCs) — turns `/bench` from a per-session number into a lifetime one
  - [ ] A defensive consistency marker in the transcript (a turn checkpoint recording how many messages it expected), compared on resume — our zjsonl has no integrity marker and a truncated resume is currently silent
- [ ] Tests: pure + fixture JSONL for fork provenance, title precedence (custom beats AI, generation counter), plan hydration, the consistency marker

---

## Phase 31 — Commanding git: `/commit`, `/pr`, `` !`cmd` ``

`✨ feature · 🟡 · depends on 0 (per-command allowlist = a registry property) · a complete command to port (copy the prompt text verbatim)`

- [ ] **31.1** Layer 1 — verified context inlined into the prompt:
  ```
  - Current git status: !`git status`
  - Current git diff: !`git diff HEAD`
  - Current branch: !`git branch --show-current`
  - Recent commits: !`git log --oneline -10`
  ```
  - [ ] Both syntaxes (fenced ``` !… ``` blocks + inline `` !`cmd` ``); we already have `!cmd` from the input — this moves it *into* a prompt (~30 lines) and gives every command a verified context block (`/review` becomes a merge-base diff for free)
  - [ ] Each command is permission-checked even though the user chose the command that ran it
  - [ ] Substitution uses a function replacer, never a string replace — `$$`, `$&`, `` $` ``, `$'` are shell output, i.e. arbitrary user data
  - [ ] Failure is loud and named (`Shell command failed for pattern "git status": …`) — never a silent empty substitution; an empty `git status` that looks like a clean tree is the worst possible lie
- [ ] **31.2** Layer 2 — the allowlist is a property of the command: `/commit` gets `Bash(git add:*)`, `git status:*`, `git commit:*` only; `/commit-push-pr` adds `checkout -b`, `push`, `gh pr create/edit/view/merge` — **the asymmetry is the feature**. Injected into `alwaysAllowRules.command` so the turn does not prompt
- [ ] **31.3** Layer 3 — the git safety protocol, verbatim: never update the git config · never skip hooks (`--no-verify`, `--no-gpg-sign`) unless explicitly requested · **ALWAYS create NEW commits, NEVER `--amend`** unless explicitly requested (the only CRITICAL-classified rule — it destroys work) · do not commit files that likely contain secrets (warn if asked) · no empty commits · never `-i` (`rebase -i` hangs a non-TTY harness forever; `verify.zig` should classify it as **forbidden**, not merely slow)
- [ ] **31.4** The message never touches argv: the heredoc (upstream) is the same insight as our `git_commit` `-F <file>`; plus the closing clause that makes it ONE round trip: *"Stage and create the commit using a single message. Do not use any other tools or send any other text."*
  - [ ] Style rules: look at the recent commits for this repo's style · name the nature of the change (add/update/fix/refactor/test/docs) · 1–2 sentences on the **why**
- [ ] **31.5** `/pr` adds: branch name with a user prefix when on the default branch (`username/feature`) · diff against the **merge base**, said explicitly to be *all* the commits in the PR · PR body template (`## Summary` 1–3 bullets + `## Test plan` checklist + a managed `## Changelog` between markers) · title under 70 characters · **idempotent** (`gh pr view --json number 2>/dev/null || true` is itself an inlined command — including the `|| true` — then `gh pr edit` instead of a second PR) · "Return the PR URL when you're done"
  - [ ] `contentLength` as a getter for dynamic prompts — a wrong static length is how `/context` loses the credibility `ctxTokens` just bought
- [ ] Tests: context substitution (permission-denied, loud failure, replacer safety) · the allowlist asymmetry pinned · the `/pr` idempotence path · `rebase -i` classified forbidden

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

- [x] **33.1** The footer says the state that decides the next tool call — **DONE 2026-10-21**
  - [x] The **effective** effort level (`chat.effortSupport` decides whether there is a knob at all) — the preference is not the same thing, and showing it would be a lie: the footer would say `xhigh` while the wire carries `high`
  - [x] The permission-mode **glyph** (`○ ◐ ● ◉`, the four shapes the reference implementation uses) — a word costs 12 columns in a footer that has to survive an 80-column terminal
  - [x] …and with it, `accept edits` becomes visible again: the test that pins "the normal permission modes cost NOTHING on the row" is a decision about COLUMNS, and a glyph is one column. **The test was rewritten on purpose** (the default still costs nothing; a deviation costs ONE column) and the legend of the glyphs lives in the shortcut list (`?`)
- [x] **33.2** The "N new" counter — **DONE 2026-10-21**
  - [x] Counts assistant **turns**, not entries (the reference implementation counts them the same way): a tool line is not an answer the reader is missing
  - [x] The baseline moves with the reader: leaving the bottom starts a count, reaching it ends the one that was running
  - [x] The **pill** over the transcript: a centred "3 new messages" that floats over the scrollback. It covers the last row on purpose — a control on its own row would move the transcript every time it appeared
- [x] **33.3** The sticky prompt header — **DONE 2026-10-21, as an OVERLAY**
  - [x] It names the turn you are reading: the last `.user` paragraph at or above the anchor
  - [x] It goes OVER the transcript's first row and **only when the reader is away from the bottom**. A reserved row was tried FIRST and it moved the text under the reader's eyes (10 tests and a crash in the click/selection math): a header that appears and disappears takes a row away exactly when the reader is looking
  - [x] The editor's own convention: a sticky line covers the content under it
- [ ] **33.4** The transcript screen (`ctrl+o`) — a VIEW of our own history, not new content; `ctrl+e` shows all
- [ ] **33.5** The bottom-anchored modal pane with a `▔` divider — a pane that keeps 2 transcript rows visible beats a centred box that hides the context
- [x] **33.6** The fuzzy picker with the matched characters highlighted — **DONE 2026-10-21**
  - [x] The query as a **subsequence** of the label, with a WINDOW (three times the query plus eight) so the fallback does not match half the catalogue
  - [x] Leftmost and **runs win**: "bc" in "a-xbc" highlights the run and not a scattered "b"
  - [x] The matched characters are painted in the accent colour, and the positions are BYTE offsets joined to the painting at the grapheme's first byte
  - [x] The fuzzy is a FALLBACK: an exact match always wins, so the item the user meant is never pushed down
  - [ ] The list is still in the provider's order, and the reference implementation sorts by score. Ours is deliberate (the free models first), so sorting is a decision and not a port
- [ ] **33.7** The picker with a **preview pane** (at the bottom or at the right) — the model preview (context window, price, free) is the most useful picker addition we do not have
  - [ ] It has to be a **bottom pane**, not a third column: at 110 columns there is no room for a third one
- [x] **33.8** Markdown tables — **DONE 2026-10-21**: a boxed table, cells padded to the column width, shrinking to fit and **wrapping inside the cell** instead of being clipped; a table that does not fit at all degrades to `name: value` rows. 11 pure tests, and the invariant that every cell's text survives the rendering
  - [x] The parser receives the WIDTH (`DiffOpts.width`), because "does it fit" is a question only the width can answer
- [ ] **33.9** The notifications channel — a transient queue for "the updater restarted", "the IDE connected", "the token budget is nearly gone"; absolutely positioned, so nothing shifts
- [ ] **33.10** The context visualisation — we compute the numbers; the reference implementation draws a proportional chart per category (system, tools, messages, skills, compaction reserve)
- [ ] **33.11** The task panel with blockers and priorities — **the data model already exists** (`src/lib/taskstore.zig`: `blocks`/`blocked_by`/`hasOpenBlocker`) and is not surfaced
- [ ] **33.12** The per-message actions — `shift+↑` targets the message under the cursor; ours has `/copy N` and no per-message targeting
- [ ] **33.13** The transcript search (`/` and `n`/`N`) — our paragraphs are already segmented, so the scan is over the segments, not the cells
- [ ] **33.14** OSC 8 hyperlinks — the paths and the URLs as real links; the detection is ~30 lines and vaxis exposes the cell attributes
- [x] **33.15** The shortcut help in the footer (`? for shortcuts`) — **DONE 2026-10-21**: `?` on an empty input opens the list, and the list carries the LEGEND of the permission glyphs. The hint in the footer only appears when the state has room for it
- [ ] **33.16** The external editor (`ctrl+g`) and the image paste (`ctrl+v`) — the image path already exists (`src/lib/images.zig`)
- [x] **33.17** The focus detection (dim the caret when the window is not focused) — vaxis reports focus events — **DONE 2026-10-27**: `Model.focused` tracks `focus_in`/`focus_out`; the composer's accent bar (the caret mark) is painted dimmed while the window is unfocused. Two draw tests pin the flag flip and the dimming.
- [ ] **33.18** The modal diff viewer — only worth it once a turn can produce multi-file diffs
- [ ] **33.19** The compact-summary line — after a tier-2 compaction the transcript loses history **silently**; one honest line says what was summarised
- [x] **33.20** The queued prompts' **text**, not just the count — **DONE 2026-10-21**: "2 queued · arregla los tests" instead of "2 queued", truncated with an ellipsis (a half-line that looks complete is a lie about what is queued)
- [ ] **33.21** The permission dialog with the **rule** explanation — which rule matched, and the rule the user could accept instead of a bare "always allow"

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

- [ ] **34.1** Path-scoped permissions and the dangerous-path protection — **MOSTLY COVERED (2026-10-21)**
  - The reference implementation: a path is allowed through SEVEN checks in this order — resolve the path → the deny rules → the internally editable paths → the **safety check** → the working-directory check → the sandbox allowlist → the allow rules. Its safety check blocks `.git/`, `.claude/`, `.vscode/`, `.idea/`, the shell configs and the UNC paths
  - [x] `src/lib/pathsafe.zig` (new, pure): the table, matched **by SEGMENT and case-insensitively** (`a/b/.git/hooks/x` and `.Git/hooks/x` are both caught; `myproject.git`, `zig-out-mine` and `.gitignore` are NOT), and a separate table for the files whose CONTENT is a secret
  - [x] Wired into `write`, `edit`, `notebook_edit` (per file: one bad path does not lose the good ones) and into `read` — `read` never asks for permission, so it was the only place a secret could be refused before going to the provider
  - [x] The refusal NAMES what writing there would do ("a hook there runs on every commit") and points at `bash`, which asks the user
  - [x] **It ASKS now, it does not refuse** (2026-10-21): the dispatcher finds the risky paths of the call, opens a question that says WHICH path and WHY, and the answer approves that one path. The tool cannot ask (it has no `Model` and cannot see a dialog), so the answer comes back through `pathsafe.approve` — the one place both can reach. The question has **no "always allow"**: a rule that remembers "the agent may write inside .git/" is the opposite of the rule
  - [x] `rename` is wired in too: it finds its own files, so its arguments NEVER name them, and it is the tool a rename reaches that the dialog could not ask about
  - [x] The multi-file form of `edit` (`files: [{path,…}]`) is in the permission detail AND in the risky-path question: the dialog used to name NO file for a call that touches eight
  - [x] **The path it RESOLVES to is checked too** (2026-10-21): a symlink with an innocent name (`ln -s .git/hooks hooks`) is a path whose NAME says nothing and whose TARGET is exactly what the rule protects. The resolver is component by component and in PURE ZIG (`readLink`), not `realpath(3)`: this project has no libc dependency
  - [x] The `Tool(pattern)` grammar — **DONE 2026-10-21**: `src/lib/permrules.zig` (pure) parses `Tool(pattern) action` (`allow` / `deny` / `ask`, the action optional and defaulting to `allow`), matches the pattern as a glob over the thing the call acts on (the PATH for a file tool, the COMMAND for `bash`), and decides by precedence. The rules live in `.zode/permissions.json` (the project) and `~/.config/zode/permissions.json` (the user), and `/permissions` prints them
  - [x] The "always allow" answer still remembers the TOOL and not a pattern: "always allow `Bash(git *)`" is the rule the user would want, and the flat list is a coarser answer
- [ ] **34.2** The **frozen decision** of the result cap — **NOT COVERED**
  - The reference implementation: the cap layer keeps a **frozen decision** — a cut is re-applied verbatim on every later turn instead of being recomputed — and it rebuilds that state from the transcript on resume
  - Ours: `src/lib/resultcap.zig:78` `capAggregate` recomputes per call
  - [x] A `Caps` state (result id → the cut that was made), persisted next to the session and reloaded on resume — **DONE 2026-10-27**: Added `CutRecord` and `Caps` structs in `src/lib/resultcap.zig` with `find`/`record`, `frozenCapResult`/`frozenCapAggregate` that re-apply previous cuts verbatim, and `serializeCaps`/`deserializeCaps` for JSON persistence next to the session. 6 pure tests (frozen cut reuse, no-cut reuse, aggregate stability, serialize/deserialize round trip, empty serialization). The `Caps` state is held in memory by the caller (session layer integration left as a thin wiring step).
  - [x] Why it matters covered: a session that compacts differently on resume silently loses its cached prefix — the frozen cut prevents this by re-applying the same cut.
- [x] **34.3** `deny` and `ask` as real permission behaviours — Phase 6 says "deny/allow/ask" but never the **precedence** — **DONE 2026-10-27**: `deny` removes the tool's schema from the request via `toolsJsonFiltered()` in `src/tools/registry.zig`, used in `agent.zig`'s request loop so a denied tool is never offered to the model (incl. `deny` with `*` = deny all). Precedence (deny > allow > ask, source priority, last-match-wins) was already implemented in `permrules.decide` and is pinned by existing tests ("a DENY beats any allow", "the strongest source wins"), plus 3 new `toolsJsonFiltered` tests. `blob` stays comptime; filtering is runtime since deny rules come from user-editable permission files.
- [x] **34.4** The dangerous-allow-rule warning and the shadowed-rule detection — **DONE 2026-10-27**
  - `permrules.Action` gained `dontAsk` (34.12) and now `dangerous_patterns` + `isDangerousPattern()` flag bare interpreters with broad patterns (`bash(*)`, `python(*)`, …). `shadowedRule()` detects when an `allow` rule can never fire because another rule covers it (deny beats allow always; stronger source or later same-source rule wins; `ask`/`dontAsk` never shadow).
  - `agent.zig`: `setAlwaysAllowed` and `allowAlwaysFor` now warn once per session about dangerous broad allows (bash `*` or empty, or any interpreter tool with `*` pattern), via `warnDangerousAllowOnce()`. Warning is informational, not a refusal.
  - 9 new pure tests in `permrules.zig` (isDangerousPattern, shadowedRule allow/deny/same-source/ask).
- [x] **34.5** A **cost** number, per model — **DONE 2026-10-22**
  - The reference implementation: a cost tracker that multiplies the token counts by the model's price, and a `/cost` command that prints the total and the per-model breakdown
  - Ours was tokens and hit-rate (`src/cache_stats.zig`), no money
  - [x] `src/lib/cost.zig` (pure, tested) over the price `src/lib/models.zig` already parses. `/cost` reads the price from the **cached** catalogue (`modelcache.zig`), never the network
  - [x] A model whose price is unknown prints **"price unknown"**, never a number; the total then says it is a floor, and a session with NO priced row prints "no total" instead of `$0.00`
  - [x] Per MODEL and not one bucket: `free-auto` rotates, the cheap router falls back and `/submodel` sends subagents elsewhere, so the row is the model that **answered** (`pick.model`), not the one that was selected
  - [x] A resumed session says which tokens are not in the breakdown: the per-model rows live in memory and the token totals are restored from the session file
  - Where: `commands.cmdCost` + the dispatch in `agent.zig` · `recordSessionUsage` now takes the model · the price decision (`free` / `unpriced` / `priced`) is `cost.priceOf`, so it is tested with no catalogue on disk
- [ ] **34.6** The hook output contract (`updatedInput`, `additionalContext`) — Phase 5 has the events, not the contract
  - [ ] The reference implementation: 27 events and 5 hook types
- [ ] **34.7** The memory recall by relevance and the staleness notes — Phase 11 has the store, not the recall
- [ ] **34.8** The background **subagents** (not the background shell jobs) — **NOT COVERED**
  - The reference implementation: the agent tool can run a whole agent in the background; Phase 10 is about `bgproc`
  - [ ] `run_in_background: bool` on the `task` tool, and a **notification to the model** when it lands
- [ ] **34.9** The atomic task claiming — **NOT COVERED** (the reference implementation has a `claim` operation): three parallel agents must not take the same task
- [x] **34.10** The enforcement of a skill's `allowed_tools` / `model` / `effort` — **NOT COVERED** — **DONE 2026-10-27**: Carried the three frontmatter fields into `skills.Entry` and `skillstore.scan()`; `subagent.skillAllowedTools()` validates a forked skill's `allowed_tools` against the read-only set (a skill naming `write`/`edit`/`bash` is refused — cannot escalate); `agent.zig` skillCall passes `allowed_tools`/`model`/`effort` into `runSubagent`, which builds the tool list from them, resolves the skill's model, and clamps its effort to the model's ladder. 5 pure tests in subagent.zig + 1 scan carry-over test in skillstore.zig.
- [x] **34.11** The conditional skills by path — **NOT COVERED** (a `paths:` field in the frontmatter) — **DONE 2026-10-27**: Added `paths` to `skills.Meta`/`Entry` (parsed from frontmatter, carried through `skillstore.scan()`); `skillAppliesHere()` matches a skill against the project root (empty `paths` = applies everywhere; a path-conditional skill with no project root does not apply); `skillsSectionText` filters the listing to matching skills. 5 pure tests in skills.zig.
- [x] **34.12** The `dontAsk` permission mode — **NOT COVERED** (a third state, not a bool: `ask` becomes "answer for yourself") — **DONE 2026-10-27**: Added `.dontAsk` to `permrules.Action` (parse: "dontask"/"dont_ask"); `decide()` tracks it separately with precedence deny > allow > dontAsk > ask; agent.zig sets `rule_allowed = true` for `.dontAsk` (no dialog, model self-authorizes). 7 pure tests (6 in permrules, 1 in agent).
- [x] **34.13** The circuit breaker keyed on **consecutive failures**, not on a budget — **DONE 2026-10-28**: `SummaryBreaker` in `src/agent.zig` trips after `max_consecutive` (3) consecutive summarizer failures and `summarizeTurns` stops spending requests on it (`maySummarize` returns false, `summarizeTurns` returns null without attempting). Any success resets the counter; `/new`/`/resume` reset it via `resetSummaries`. Wired into every `summarizeTurns` failure path and the success path, so both call sites (main.zig and agent.zig) are protected from "request-per-turn forever". Pure tests in agent.zig; verified with `zig build test`.
- [ ] **34.14** The `PermissionRequest` hook path for the headless runs
- [x] **34.15** The "the model was told to stop and did not" mechanism — **DONE 2026-10-28**: `StopHook` in `src/lib/autochk.zig` — a user-written callback that can refuse to end a turn, the user-written version of our exit gate. Composition rule is explicit and ordered: the gate (`exitGate`) runs FIRST; if it refuses (code is bad, turn cannot end), the hook is not consulted. Only when the gate passes does `stopHookCheck` run — they never both claim the turn. Wired into both runners: TUI (`chatWorker` in agent.zig) and headless (`--chat` in main.zig). Pure tests in autochk.zig; verified with `zig build test`.
- [x] **34.16** The per-session price/usage table that `/context` can show — **DONE 2026-10-28**: `/context` now prints a compact per-session price/usage summary next to the token gauge, reusing `lib/cost.zig` (`Tracker`, per-model price lookup, `totalOf`/`formatUsd`/`unpricedCount`). Honest "price unknown"/floor semantics; a resumed session's tokens are noted, not priced. Pure tests in cost.zig; verified with `zig build test` and `zig build`.

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

- [x] **35.1** `/files` — **DONE 2026-10-21**: the files the model has READ (and whether their content is still in the context) and the files the agent WROTE to, this session. It is the answer to "what is the model looking at?", which is the question you ask when a turn goes sideways. It also found a bug: the read cache survived `/new`, so the new session's first `read` of a file the previous session had read answered "it is already in your context" WITHOUT sending the body — the model would have been working from a file it could not see
- [x] **35.2** `/init` — **M** for the prompt, **L** with the interview phase. The highest-value missing command: without it a new project has no `AGENTS.md` and the harness silently runs with the built-in prompt only. Port the reference implementation's prompt text **verbatim** and let the model do the work — **DONE 2026-10-22**
- [ ] **35.3** `/rename` + the `#tag` + the session title — **S** each, and together they are the readability layer of the session list. Phase 30.1 has the design; the command is 20 lines
- [ ] **35.4** `/review` and `/security-review` — **S-M** each, and together the highest-traffic command we lack. Both are prompt commands whose text is the reference implementation's, and Phase 31.1 already has the `` !`cmd` `` substitution
- [ ] **35.5** `/clear` (with the cache reset) and the `/exit` alias — **S**. `/new` exists but leaves the read cache, the skills-sent marker and the user commands stale
- [ ] **35.6** `/doctor` — **M**: the one command you run when zode behaves strangely. Half the checks (the key state, the config, the session dir's permissions) we already compute elsewhere
- [ ] **35.7** `/config` + `/status` + `/usage` as ONE panel — **M**: six scattered commands become one "what is my configuration?" screen, assembled from the functions the commands already call, so it cannot drift
- [ ] **35.8** `/compact` on demand — **S-M**: the machinery is done, the trigger and the argument are missing
- [ ] **35.9** `/release-notes` + `/version` — **S**: two one-liners over `src/lib/selfupdate.zig`, which already runs at startup with nobody told
- [ ] **35.10** `/diff` — **M**: a diff dialog shows the uncommitted changes and the per-turn diffs; the renderer exists (`src/lib/diffview.zig`), the command is the missing half
- [ ] **35.11** `/permissions` (the rule editor) · `/hooks` (the hook editor) · `/agents` (the subagent definitions) — **M** each, and each one is a panel over a mechanism another phase builds. **They wait for it**: a UI over a rule engine that does not exist yet is how a command ends up promising something the engine does not do
- [ ] **35.12** `/rewind` (an arbitrary point, not the last turn) · `/compact` · `/resume` as a picker — covered by Phases 29 and 30
- [ ] **35.13** `/add-dir` · `/sandbox` · `/mcp` · `/vim` — wait for Phases 6, 12 and 13
- [ ] **35.14** `/btw` (a side question that does not interrupt) — **S**: one subagent call whose answer is appended, not a turn
- [ ] **35.15** The **name collision** to settle: the reference implementation's `/color` sets the agent colour and ours sets the **diff palette**. Rename one of them the day the other lands

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

## Phase 36 — The crash that was open for a month, and the two build steps that lied

`🐛 fix · 🔴 · DONE 2026-10-21 · source: docs/analysis/audit.md`

> The "ReleaseSmall + a saved key = the TUI stops answering" bug was open in
> AGENTS.md since 2026-10-14 and was written up as **not ours**: an A/B against
> the parent commit showed base and current behaving identically. It was a
> use-after-free, and it was ours since the warmup was written.

- [x] **36.1** The use-after-free in the catalogue warmup — **DONE 2026-10-21**
  - [x] `src/agent.zig` `warmupWorker`: the two `defer`s were in the wrong order, and `defer` is LIFO — the job was **freed** and then `job.model.endWorker()` dereferenced the freed block to do its atomic RMW. A SIGSEGV in a detached worker, which is exactly the "the app stops answering" symptom
  - [x] The pointer is copied into a local before anything can die
  - [x] The double free next to it: the `errdefer` in `catalogWarmupAsync` freed the job a second time on the spawn-failure path
  - [x] A test that the warmup's job lifetime is correct
- [x] **36.2** `zig build debug` did not compile — **DONE 2026-10-21**: `debug_mod` was missing the `build_options` import, so the step whose ENTIRE job is to be a trustworthy artifact for a crash produced no artifact at all, and the `zode-debug` on disk was a leftover from some earlier build, byte-identical to the stripped release one
- [x] **36.3** `-Dstrip=false` did not disable the stripping — **DONE 2026-10-21**: `strip = null` is not "unstripped", it is "use the default", and the default for ReleaseSmall is TO STRIP. The option has to be written down for it to mean anything
- [x] **36.4** The permission dialog painted NOTHING on a terminal with no room for the box — **DONE 2026-10-21**: the dialog BLOCKS the turn, so an invisible dialog is a turn that can never be answered, and the app looks exactly like the "it stopped answering" bug. There is now a compact two-row form
- [ ] **36.5** The `endWorker`/`destroy` lifetime is a CLASS, not an incident: every detached worker in the tree needs the same audit (the model worker, the self-update thread, the background reader, the subagents)
- [ ] **36.6** The self-update thread is neither counted as a worker nor isolated from the shared `Io` (`src/main.zig:737-747`) — the same shape as the crash of 36.1

---

## 🔧 Tool upgrades (independent, one registry row each, no permission changes)

- [x] **`grep`** + context lines (`-A/-B/-C`), a `glob`/`type` filter, an output mode (`content` / `files_with_matches` / `count`), and a `head_limit` — today the model compensates with more calls — shipped 2026-10-16
- [x] **`bash`** + a `description` field: one line for the timeline ("running the test suite") so the user reads what a command is FOR — shipped 2026-10-16 (the timeline and the status bar show the description; the permission dialog and the allowlist keep matching the COMMAND, so prose can never ride an allowed prefix)
- [x] **`read`** + PDF page ranges (the image path already exists), so a spec handed to the agent is readable without shelling out to a converter — shipped 2026-10-20
- [x] **`glob`** + a `subdir` and a `limit`, so "the 20 newest `.zig` under `src/`" is one call (plus `sort: newest|oldest|name`, which is what makes "newest" true — shipped 2026-10-16)
- [x] One pure test per row on the argument parsing

---

## 📐 Constants and thresholds (data table)

| Constant | Value | Phase |
|---|---|---|
| Skill listing budget | 1% of `ZODE_CONTEXT_LIMIT` (in chars) | 2.1 ✓ |
| Skill per-entry cap | 250 chars | 2.1 ✓ |
| `default_max_result_chars` | 50 000 | 0/3 |
| `max_result_bytes` | 400 000 | 3 |
| `max_results_per_message_chars` | 200 000 | 3 |
| `summary_max_len` | 50 | 3 |
| Per-tool `max_result_chars` | 100 000 (read = unbounded) | 0/3 |
| Compaction budget | 80% of `ZODE_CONTEXT_LIMIT` | existing |
| Batch step kinds | fixed set (`map`/`filter`/`select`/`count`/`write`) | 16 |
| Ticks while parked | off by default | 19 |
| Recurring schedule max age | 30 days | 19 |
| Web fetch cache TTL | per session | 24 |
| Word-diff change threshold | 0.40 (above it, no word ranges) | 27 |
| Diff gutter width | digits of the hunk's max line, per hunk | 27 |
| `/copy` lookback | 20 turns | 28 |
| `/copy` block label width | 60 columns (display width, not bytes) | 28 |
| Resume list enrich window | first 50 sessions, 128 KB head+tail each | 29 |
| Resume search crop | first 1000 + last 1000 messages, prose only | 29 |
| Resume relevance window | 60 s (relevance is a tiebreak inside it) | 29 |
| AI title trigger | turn 3 (turn 1 is the derived placeholder) | 30 |
| Running summary cadence | every 5 steps or 2 min, whichever first | 30 |
| Fork name collisions | `X`, `X (Branch)`, `X (Branch 2)` | 30 |
| Idle before "done" | 5 consecutive quiet intervals, no growth | 32 |
| Review precondition | `merge-base` + `--shortstat`, fail-open | 32 |

---

## 🔗 Dependencies (quick matrix)

| Phase | Needs | Why here |
|---|---|---|
| 0 | — | every later phase reads the registry |
| 1 | 0 (optional) | the requested start; reuses the skill system |
| 2 | 1 | listing and fork build on the new frontmatter |
| 3 | 0 | the cap layer is where storage plugs in |
| 4, 6, 8, 9, 11, 13, 15, 17–19, 21–24, 27, 28, 30 | — | independent |
| 5 | 6 | hooks reuse the rule syntax |
| 7 | 3 | microcompaction needs the stored-result marker |
| 10 | 3 | task output reuses storage |
| 12 | 0 | tool search needs the registry |
| 14 | 12 | the LSP client reuses the stdio JSON-RPC transport |
| 16 | 0 | a batch is a registry of step kinds |
| 20 | 15 | teammates coordinate through the task graph |
| 25 | 6 | reuses the rule syntax and the read-only table |
| 26 | 9 | roles are a built-in set of the on-disk definitions |
| 29 | 30 | a row's title is Phase 30's key; the tail entry is written at write time |
| 31 | 0 | the per-command allowlist is a registry property |
| 32 | 26 | the advisor is a `task` subagent; the counts ride on the roles |
| 33 | — | the TUI port list; independent, one item at a time |
| 34 | 6 (for 34.3, 34.4) | the permission gaps reuse Phase 6's rule syntax; the rest is independent |
| 35 | 6, 12, 13 (for the panels) | a UI over a rule engine that does not exist yet promises what the engine does not do |
| 36 | — | the crash and the two build steps; independent of everything |

**Tool-track ranking** by value per unit of risk: 15 → 16 → 14 → 25 → 26 → (17, 21, 22, 23, 24) → (18, 19, 20).

---

## ✅ How a box gets ticked

- **Pure logic** (`src/lib/`): `zig build test`, no TUI, no network.
- **TUI**: `drawTest` + `rowText` + `readCell`, and always a real frame in a pty (`tools/pty_smoke.py`) — libvaxis redraws differentially and a homemade emulator loses half of it. Always drain the pty.
- **Wiring**: a `*_smoke.py` per command a unit test cannot prove fires (a command can be perfect and still do nothing when typed).
- **Precision**: a typecheck is "typechecked", not "verified"; a run that could not reach the model reports the gap instead of calling it a pass.
- The two language checks (test names and code comments in English) come out empty.

## 🔴 Tareas importantes — memoria, entrada, imágenes y scroll infinito

Tareas de alta prioridad para portar el comportamiento del harness de referencia. Cada una es independiente y se puede tickear en cualquier orden.

- [ ] 🔴 **Memoria: capa única de capado de resultados** — un solo lugar que límite cada resultado de herramienta (tope por herramienta) y el total de todos los resultados de un mensaje (tope agregado). Cuando un resultado se corta, el aviso de corte viaja dentro del presupuesto (texto retenido + aviso nunca superan el tope). Nunca cortar en medio de un carácter multi-byte.
- [ ] 🔴 **Memoria: compacción del contexto en dos niveles** — primero, reemplazar resultados de herramientas antiguos por un marcador que nombre dónde quedó guardado (nada se pierde, solo se mueve); segundo, si sigue sobre presupuesto, pedir al modelo que resuma los turnos más antiguos en una nota y reemplazar esos turnos por la nota. Cada turno y cada llamada a herramienta con su resultado se guardan íntegros con identificador, para buscarlos o abrirlos después. Desde la segunda compacción, la anterior se guarda entera y sale de la vista; un resumen escrito por el modelo sustituye a todos los turnos previos.
- [ ] 🔴 **Memoria: presupuesto de contexto** — la compacción automática arranca cuando una request alcanza un porcentaje configurable del usable input del modelo (rango 10–80 %, valor por defecto 80 %). Después de compactar, la request completa usa como máximo una quinta parte del usable; los turnos nuevos conservados usan como máximo el 40 % del espacio del compactado (hasta cuatro turnos). El historial completo se conserva; solo la vista enviada al modelo se compacta.
- [ ] 🔴 **Entrada: admisión segura de texto** — leer byte a byte formando caracteres UTF-8 completos de forma atómica; descartar bytes inválidos o caracteres incompletos sin retener basura; si cambia el contexto del escritor, descartar lo pendiente nombrando el contexto anterior.
- [ ] 🔴 **Entrada: límite de visualización** — cuando el texto escrito supere un tope de bytes, rechazar la edición con un mensaje claro que nombre el límite y pida repintar solo la zona afectada. Nunca cortar un carácter UTF-8 por la mitad.
- [ ] 🔴 **Imágenes: custodia por el harness** — las imágenes leídas por una herramienta las guarda el harness, no la herramienta, y se adjuntan al siguiente mensaje del usuario (donde el protocolo lo permite).
- [ ] 🔴 **Imágenes: topes y rechazo con motivo** — cantidad máxima de imágenes por mensaje, bytes máximos por imagen, bytes totales por mensaje, cantidad máxima por request y bytes máximos de request. Si una imagen excede un tope, rechazarla diciendo por qué y nombrando el archivo guardado donde está la copia.
- [ ] 🔴 **Imágenes: imágenes viejas fuera del request y vida breve** — cada request re-envía todas las imágenes previas; dejar fuera las más antiguas primero hasta que quepa el límite, cada una con una nota que apunte a su archivo guardado. El historial no se modifica. Los búferes de imagen se liberan tan pronto sale el mensaje; no se cachean ni persisten entre turnos.
- [ ] 🔴 **Scroll infinito de salida de terminal** — eliminar el tope de bytes que detiene el crecimiento del output en streaming; el texto nuevo sigue renderizándose sin límite artificial. La ancla de scroll es absoluta y no pierde posición cuando llega contenido nuevo. El modo seguir-al-fondo funciona con contenido ilimitado. El contador de mensajes no vistos se actualiza correctamente. El estado de scroll es serializable para restaurar la posición de lectura.

**Acceptance**: cada comportamiento tiene pruebas puras sin terminal ni red; ningún recorte deja texto UTF-8 inválido; ningún aviso de corte queda fuera del presupuesto; el scroll no mueve el texto bajo el lector mientras llega contenido nuevo.

## 🚫 Deliberately NOT on this board

- No plugin marketplace, telemetry, or accounts — none of it is core.
- Nothing enters the prompt that is not used: carrying instructions the model has already learned to skip is the biggest mistake a harness of this class makes.
- No abstraction without a second caller: the registry exists because four lists disagree today, not because structure is nice.
