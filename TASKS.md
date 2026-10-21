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

- [x] 🔴 **Sprint A — Phase 27** (the diff you can read) — **DONE 2026-10-21**: the gutter
      is painted, the word diff is computed where the diff is painted, and the colour
      ladder is applied where the cell is written.
- [ ] 🔴 **Sprint A2 — Phase 33** (the TUI at Claude Code's level): the port list,
      42 features read out of the reference implementation. 33.1 and 33.2 are done;
      the rest is the board. The porting notes are in `docs/analysis/tui-chrome.md`.
- [ ] 🔴 **Sprint A3 — Phase 34** (the machinery the reference implementation has and we do not): sixteen
      mechanisms that no phase owned, of which **34.1 (path-scoped permissions)** is
      the one that should not wait — today `write` writes any path it is handed.
- [ ] 🔴 **Sprint B — Phase 2** (skill listing budget + named args + `context: fork`):
      `max_listed = 40` is still a constant and `context: fork` is parsed and never read.
- [ ] 🟡 **Sprint C — Phase 3 → 7 → 10** (recoverable results → compaction v2 → background tasks)
- [ ] 🟡 **Sprint D — Phase 6 → 5 → 25** (permissions → hooks → bash safety)
- [ ] 🟡 **Sprint E — Phase 35** (the command surface): `/files` and `/init` first;
      the panels that need a rule engine wait for the engine (Phase 6).
- [ ] 🟡 **Tool track — Phase 25 → 26 → 20** (bash safety → roles → teams); 20 waits on 15, 32 on 26
- [ ] 🟡 **Phase 29 + 30** (`/resume` picker → names/forks): most needed, least fun — quietly wrong today
- [ ] 🟢 Everything else per the dependency table at the bottom.

**Done since the board was written**: Phase 1 (bundled skills + rich frontmatter) ·
Phase 16 (the `batch` tool: many operations, one round trip) · Phase 28 (`/copy`) ·
**Phase 14 (the language server: the tool was offered to the model and could not be
called — it is wired now, with `diagnostics` and `lsp_servers`)** ·
**Phase 27 (the diff you can read: the gutter, the word diff and the colour ladder)** ·
**Phase 36 (the crash that was open for a month — a use-after-free in the catalogue
warmup — plus the two build steps that promised an artifact and produced none)**.

**The analysis behind the new phases** lives in `docs/analysis/`:
`tui-chrome.md` (the TUI port list, 42 features) · `commands.md` (72 reference
commands, 26 gaps) · `harness.md` (the machinery gaps) · `audit.md` (our own
state, the open bug and the quality bar).

---

## Phase 0 — Foundation: tool registry + result cap

`🏗️ refactor · 🔴 · not user-visible · blocks 3, 12, 16, 31`

> Today one tool's facts live in four places. A new tool is a hunt. This makes it a row.

- [x] **0.1** `src/tools/registry.zig` — one table, not four lists
  - [x] `ToolDef { name, desc, schema, read_only, parallel_safe, destructive, max_result_chars }`
  - [x] `needsPermission(name)` = `!find(name).read_only`; `isParallelSafe` reads the table; `defs` generated
  - [x] Each row points at the existing per-tool file — keep the files, lose the scattered flags
- [x] **0.2** `src/lib/resultcap.zig` — the single cap layer ⚡
  - [x] Order: per-tool cap → batch aggregate cap → "persist instead of truncate" hook (Phase 3 plugs in here)
  - [x] Pure tests: per-tool cap respected · aggregate trims the largest first · a result exactly at the boundary untouched · a cut always carries its notice *inside* the budget

**Acceptance**: adding a tool requires no edit outside its own file + one registry row.

---

## Phase 1 — Bundled skills + rich frontmatter

`✨ feature · 🔴 · reuses skills.zig + skillstore.zig (already works) · roadmap says "start here"` — **DONE 2026-10-20**

> Skills compiled into the binary. Highest value for the least risk.

- [x] **1.1** `src/lib/bundled_skills.zig` + bodies in `src/skills/<name>.md` via `@embedFile`
  - [x] No extraction to disk, no temp files at runtime
  - [x] Ship 5 first: **simplify** (review the diff for reuse/duplication) · **verify** (narrowest command that would break if you were wrong) · **skillify** (turn a repeated task into a SKILL.md) · **debug** (reproduce → isolate → fix the cause, backgrounded) · **goal** (split the objective → drive the `todo` list)
- [x] **1.2** Rich frontmatter in `skills.zig` (parser stays narrow: `key: value`, no YAML)
  - [x] `when_to_use`, `argument_hint`, `allowed_tools`, `model`, `effort`, `context: inline|fork`
- [x] **1.3** `Entry` gains `body`, `source` (`project|agents|user|bundled`), `context`, `when_to_use`
  - [x] The body travels WITH the entry for a bundled skill: it is in the binary and its path is not a file, so `load` never opens the disk for it
- [x] **1.4** Discovery: bundled appended AFTER on-disk; project/user shadow bundled; `/skills` tags `[bundled]`/`[project]`/`[user]`
- [x] **1.5** Listing prints `when_to_use` next to the description
- [x] **1.6** `skill` tool takes optional `args`; `$ARGUMENTS` substituted (single substitution; named args = Phase 2)
- [x] **1.7** Pure tests: table (unique valid names, non-empty desc/body) · parser (8 fields, CRLF, a file ending at the closing fence) · prompt includes `when_to_use` · `Loader.load` with `body != null` never opens disk (point it at a nonexistent path on purpose) · shadowing · `$ARGUMENTS`

**Acceptance**: `zig build test` green · `/skills` shows bundled tagged · prompt grows ≤ ~1 KB with the five skills.

## Phase 2 — Skill listing budget + args + inline/fork

`✨ feature · 🔴 · depends on 1`

- [ ] **2.1** Listing under a budget ⚡
  - [ ] Budget = **1% of `ZODE_CONTEXT_LIMIT`**, per-entry cap **250 chars**; bundled entries never truncated; worst case: names only
  - [ ] Replaces the fixed `max_listed = 40`
- [ ] **2.2** Send the listing **once per session** as an attachment at the END of the prompt (cacheable prefix untouched); dedupe per session; reset on config reload, NOT on compaction
- [ ] **2.3** Named args (`$1`, `$name`) substituted into the body
- [ ] **2.4** `context: fork` runs the skill via `lib/subagent.zig` (effort low, read-only, disposable window) and returns the result to the main turn
- [ ] **2.5** `!cmd` inside a skill: run the command, substitute its output (behind Phase 6 permissions)
- [ ] Tests: budget caps total size · bundled survive a tight budget while others degrade to names · args substituted · a fork skill leaves the parent message list length unchanged

---

## Phase 3 — Output: recoverable results + per-tool render

`⚡ token · 🔴 · depends on 0 · blocks 7, 10`

> Blind elision loses detail. Storage loses it *on purpose* — and the model can get it back.

- [ ] **3.1** `src/lib/toolstore.zig` — large result → file + preview + path
  - [ ] Over cap → write `sessions/<id>/tool-results/<n>.txt`, return `[result stored: N bytes at <path>; read the part you need]` + 2 KB preview
  - [ ] Constants (env-overridable): `default_max_result_chars=50_000` · `max_result_bytes=400_000` · `max_results_per_message_chars=200_000` · `summary_max_len=50`
- [ ] **3.2** Per-tool render, driven by the registry
  - [ ] `ToolDef.summarize` (one timeline line: `read(src/x.zig) · 120 lines`) + `ToolDef.activity` (`Reading src/x.zig` for the strip)
  - [ ] TUI paints `condensed` by default, full `transcript` on Ctrl+R (the mechanism already exists for diffs)
  - [ ] `grep`/`glob`/`read` collapse into one line in the timeline
- [ ] Tests: a large result is stored and the returned text names the real path · a stored result survives resume · `summarize` is one line under `summary_max_len` · collapsing does not drop the first line of context

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

## Phase 6 — Fine-grained permissions + bash read-only + sandbox

`🔒 security · 🟡 · independent`

- [ ] Rule model with sources and precedence: local > project > user > policy; syntax `Tool(pattern)` (`Bash(git *)`, `Read(*.ts)`); actions `deny` / `allow` / `ask`
- [ ] Once-off suggestions: a permission request returns rules the user can accept ("always allow `Bash(git *)`") → learned per tool+pattern (today: a flat allowlist)
- [ ] Bash read-only classification table (`git status`, `rg`, `ls`, `wc`…) — by command and flags, never by guessing
- [ ] Optional sandbox: if `bwrap`/`firejail` is present, run `bash` inside it
- [ ] Pure tests: rule parsing and precedence · `Tool(pattern)` matching · the read-only table (a write command with a read-looking name is NOT exempt) · a `deny` beats any `allow`

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

## Phase 12 — MCP over stdio + deferred tool loading

`✨ feature · 🟡 · depends on 0`

- [ ] MCP over stdio (JSON-RPC): connect, list tools, call
- [ ] **Deferred tool loading / tool search**: with many tools (MCP servers), do not put every schema in the prompt; load them by search — this is what keeps MCP from wrecking the cache
- [ ] Tests: a fake MCP server over a pipe · a deferred tool is invisible until searched and callable afterwards

---

## Phase 13 — Ecosystem

`⏳ optional · 🟢 · only if usage asks for it`

- [ ] Plugins/marketplace · remote sessions · keybindings/vim mode — outside the core

---

## Phase 14 — Semantic code intelligence (a language-server client)

`✨ feature · 🟡 · depends on 12 (stdio JSON-RPC transport)` — **DONE 2026-10-20**

> `refs`/`rename` are regex heuristics; the compiler already knows the answer. LSP is asked for when precision matters; `refs` stays (instant, no server needed).

- [x] Optional LSP client: keyed by file extension, started on demand over stdio, reused for the session, killed at teardown
- [x] One `lsp` tool with `operation`: `definition` · `references` · `hover` · `document_symbols` · `workspace_symbols` · `implementations` · `incoming_calls`/`outgoing_calls` · `diagnostics`
- [x] **Degrade, never block**: no server for the file type → named error, the model falls back to `refs`/`grep`. The server is a bonus, not a barrier
- [x] Position = `file` + `line` + `character` (1-based); `character` resolved from the symbol name when given, so the model does not count columns
- [x] `lsp/protocol.zig` pure and tested separately (framing, requests, `initialize`/`shutdown` handshake, `textDocument/*` mapping) against a fake server over a pipe — no editor, no network
- [x] Per-project `lsp_servers` table in config (extension → command) + small built-in defaults (zls, rust-analyzer, gopls, typescript-language-server, pyright, clangd); "not installed → skip" like `check`
- [x] Small `max_result_chars` — semantic answers are short (a location, a signature)
- [x] Tests: the fake server drives every operation · a missing server degrades to a named error and never hangs · a server that dies mid-session is restarted once · `document_symbols` on a real fixture returns the outline · **`refs` still works with zero servers installed**

### What was done, and what it cost to find out (2026-10-20)

The library was written and the tool was offered to the model with **no branch in the
dispatcher**: every call answered `there is no tool called lsp`. A tool the model can see
and cannot use is a promise the harness does not keep.

**What is wired now**: the dispatcher branch · the manager (started at boot, killed at
exit — a `zls` that outlives the app keeps indexing a project nobody is looking at) ·
`lsp_servers` in `config.json` · `diagnostics` · a dead server is replaced instead of
answering `ServerClosed` forever · the 32 test blocks that never compiled are in
`src/test_all.zig` and run.

**Five things that were not obvious**:

1. **`diagnostics` is NOT a request.** A server PUBLISHES its diagnostics as a
   `textDocument/publishDiagnostics` notification, so the operation WAITS for one. The
   client keeps the last publication per file and forgets it when the file is sent
   again: the diagnostics of the previous version would be reported as the current
   ones. "No diagnostics arrived in 8 s" and "there are no problems" are two different
   facts, and only the first one is ever said.
2. **A notification that arrives while another request is in flight is not lost.** The
   diagnostics usually land in the middle of a `hover`, and the reader used to skip
   every message without an `id` — which is every notification.
3. **One server can serve two languages.** `typescript-language-server` answers for
   `.ts` ("typescript") and for `.tsx` ("typescriptreact"), and a client that carries
   ONE language id opens a `.tsx` as TypeScript. The id is asked per FILE now.
4. **The user's servers are COPIED, not borrowed.** `config.json` lives in an arena
   that is freed on every reload (connecting a provider reloads it), so a server list
   that pointed into it is a dangling pointer from then on. The map key of a running
   client is a copy for the same reason.
5. **The read-only schema was a hand-written list of INDICES** (`defs[0].schema ++ "," ++
   defs[1].schema ++ …`), and the `lsp` row had never been added to it. Both arrays are
   now composed at comptime from the table, so the copy that drifts cannot exist.

**The permission drift is settled**: `lsp` is `read_only = true`. The command that gets
spawned comes from a table (or from the user's `lsp_servers`), never from the model,
so there is no argument a model could put an obligation in — the same reason `read`
asks nothing. The model got a dialog for a tool nobody thought should ask.

**How it is checked**: `tools/fake_lsp.py` is a fake server that speaks the wire, and
the test drives EVERY operation through the real dispatcher, the real manager and a real
spawn. `zig build lsp-probe` does the same against a REAL server (clangd) and prints
what comes back: the two are complements — the fake proves the wire, the probe proves
the server.

**Not done** (and not on this board): the `shutdown`/`exit` request of the protocol (the
server is killed, not asked), and `workspace/diagnostic` (the workspace-wide pull that
some servers support).

---

## Phase 15 — The structured task graph

`✨ feature · 🟡 · independent · blocks 20`

> `todo` is what the human sees. This is work items with identity, dependencies and an owner — what a long task and a team coordinate on.

- [x] Task store `sessions/zode-<id>.tasks.json` (one file next to the session instead of a directory per session — the id never changes, and a file the session loader already knows how to find); `Task { id, subject, description, status, owner, blocks, blocked_by }`
- [x] Tools: `task_create` / `task_get` / `task_list` / `task_update` (status, subject, description, owner, `add_blocks`/`add_blocked_by`) / `task_stop`
- [x] **`blocked_by` is derived, never typed twice**: setting `blocks` on A adds `blocked_by A` to B — one edge, two views, always consistent
- [x] `in_progress` with no owner is refused; `task_list` names what is waiting on what
- [x] A task cannot complete while it waits on an open one; completing a blocker unblocks the list in the same update
- [x] Pure tests: create/get/list round-trip · an edge set from either side reads the same from both · a blocked task reports its blocker · completing a blocker unblocks · deleting clears the edges that pointed at it

## Phase 16 — Batch execution: many operations, one round trip

`⚡ tokens · 🟡 tool-track #2 · depends on 0` — **DONE 2026-10-20**

> "Count lines in 4 files, find the TODOs in the 2 that have them, write a report" = 5 calls, 5 round trips. A round trip is a whole request.

- [x] `batch` tool: a small **sandboxed** step runner; steps run in order host-side; returns only the final value plus a one-line log per step
  - [x] The step kinds are a FIXED, enumerable list: `read` · `read_many` · `grep` · `glob` · `list_files` · `refs` · `git_status` · `git_diff` · `map` · `filter` · `select` · `count` · `write` · `edit`. There is no way to spell a step that is not one of them
  - [x] The log's first line says what it bought: `4 step(s), 1 request`
- [x] Exposes the read-only primitives (`read`, `grep`, `glob`, `list_files`, `refs`, `git_*`) + the editors (`write`, `edit`) under the **same** permission rules as a direct call — a batch is not a way to bypass the dialog
  - [x] **The permission set of a batch is the UNION of its steps**: a batch of reads asks for nothing; a batch with a `write` step asks for exactly what that `write` would have asked, and the dialog names the files
  - [x] "always allow" on a batch remembers the **tools** its steps call (`write`), not `batch` — one approval must not cover every batch the model writes later
- [x] **Not a shell and not a general language**: the model never supplies a command, there is no way to spell a step that is not one of the fourteen, and there is no network — the size of the surface IS the safety argument. (The only processes that run are the two FIXED git reads, the same commands the `git_status` and `git_diff` tools run.)
- [x] Read-only by default; a batch that writes needs the same approval a `write` call would, naming the files it would touch
- [x] Failure is per-step and named; the rest does not run unless the batch declares `continue_on_error`
- [x] The savings are visible: the log reports `9 steps, 1 request`
- [x] Pure tests: step parsing and validation · the read-only default refuses a write without approval · a failed step stops the batch and names itself · a batch over four files returns one result and no per-file round trip · the permission set of a batch equals the union of its steps

**Where the code is**: `src/lib/batch.zig` (the model, the parser, the item collection and the permission set — pure) · `src/tools/batch.zig` (the executor) · `src/tools/prompts/batch.zig` (the schema) · one row in `src/tools/registry.zig`.

**Two decisions that are not obvious**:

- **The batch is NOT in the read-only toolset.** A batch's steps can write, so the
  static flag says `read_only = false` and the model is not offered it in plan
  mode. The per-call answer (does THIS batch ask?) is the union of its steps.
- **`/undo` snapshots every file a batch touches**, not one: a batch that wrote
  three files and snapshotted one would undo a third of the turn.

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

- [ ] `lib/cmdsafety.zig` (pure): split a command into its parts (pipelines, `&&`/`||`/`;`, substitutions); flag the ones that write, delete, exfiltrate, or chain into a shell (`curl … | sh`), naming the **exact dangerous fragment**
- [ ] The classifier is **data, not a heuristic**: command families + the flags that change them — `git status` is quiet and `git clean -fdx` is not; a new family is one row
- [ ] The dialog shows the risk in words, not the raw line: "this deletes unreferenced files" beats `git clean -fdx`
- [ ] Phase 6's read-only table reuses it: a command is only "read-only" if the scanner found nothing to flag
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

## Phase 28 — `/copy`: taking the answer with you

`✨ feature · 🔴 · reuses the picker + termseq · a complete command to port (~370 lines)`

> Today: scroll up, select with the mouse, copy with the terminal's own machinery — three steps and a scroll position to lose.

- [x] **28.1** Walk newest-first and skip the turns that said nothing (wrong role / API error / empty text); join one turn's text blocks with `\n\n`; strip prompt-XML tags first (or a system-only block becomes a fake "code block")
- [x] **28.2** `/copy N` reaches back N−1 turns, `MAX_LOOKBACK = 20`; honest arithmetic on failure ("Only 3 assistant messages available to copy" — not "invalid", pluralisation included)
- [x] **28.3** The picker only appears when there is something to choose; first row = the whole response, focused:
  ```
  Full response (8123 characters, 214 lines)   ← focused
  <first line of block 0>  (zig, 40 lines)
  Always copy full response
  ```
  - Labels are the code's own first line, truncated to 60 columns by **display width**; the "Always copy" row is remembered (a picker that reappears identically teaches the user it is broken); row labels are heap copies (the `askPickerChosen` rule)
  - The picker hands over the **index**, not the label: two blocks can start with the same line, and matching the label back to the entry would copy the wrong one while showing the right row
- [x] **28.4** Clipboard = a three-rung ladder, decided BEFORE the copy runs: native (pbcopy/wl-copy) → `tmux load-buffer` → OSC 52
  - [x] OSC 52 first, file I/O after (upstream's expensive lesson: awaiting tmux cost 50–100 ms); in a vaxis TUI the OSC must go through the render, never outside `vx.render` — `tui.zig` already has the scar of one painted over the UI
  - [x] The file is written ALWAYS and the message says so with numbers (`Copied … (8123 characters, 214 lines) — also written to /tmp/…/response.md`); OSC 52 is genuinely best-effort, and a copy confirmation you cannot check is not a confirmation
  - The message names the **rung** that was used, because "copied!" in the dark is a hope, not a confirmation
- [x] **28.5** Fence language → file extension, sanitised (`[^a-zA-Z0-9]` stripped; empty/`plaintext` → `.txt`) — a language tag is model output, a path is a filesystem
- [x] **28.6** Cancelled is not an error: Esc shows `Copy cancelled` as a system line, not a failure in the history; a failed write says `Failed to write file: …` — shown, not swallowed
- [x] Not ported: `config.copyFullResponse` as a global setting (a session flag is enough until someone asks) — DONE as the session flag `Model.copy_always_full`
- [x] Tests + a `*_smoke.py` wiring check (a command can be unit-perfect and still do nothing when typed) — `tools/copy_smoke.py`

**Acceptance**: `zig build test` green · the smoke opens the picker, writes the file the message names, and says `Copy cancelled` on Esc.

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

- [ ] **30.1** Two title keys on disk, so precedence is structural: `customTitle` (`/rename`, never overwritten) vs `aiTitle` (generated, ephemeral, safe to regenerate). A single `title` with a `source` flag is the same idea implemented worse
- [ ] **30.2** Derive now, upgrade later, guard the upgrade
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

## Phase 33 — The TUI at Claude Code's level

`✨ feature · 🔴 · the port list · source: docs/analysis/tui-chrome.md`

> The reference is the TUI of Claude Code (TypeScript + Ink), read line by
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
  - [ ] The permission-mode **glyph** (`○ ◐ ● ◉`, the four shapes the reference implementation uses) — a word costs 12 columns in a footer that has to survive an 80-column terminal
  - [ ] …and with it, `accept edits` becomes visible again: the test that pins "the normal permission modes cost NOTHING on the row" is a decision about COLUMNS, and a glyph is one column
- [x] **33.2** The "N new" counter — **DONE 2026-10-21**
  - [x] Counts assistant **turns**, not entries (the reference implementation counts them the same way): a tool line is not an answer the reader is missing
  - [x] The baseline moves with the reader: leaving the bottom starts a count, reaching it ends the one that was running
  - [ ] The **pill** over the transcript: a centred "3 new messages" that floats over the scrollback, with a click target
- [ ] **33.3** The sticky prompt header — **fixed ONE row**, or the transcript shifts every time the sticky prompt changes (the reference implementation says so in its own comment)
  - [ ] It has to live OUTSIDE `history_h` or the clear at `tui.zig:5728-5731` erases it
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
- [ ] **33.8** Markdown tables — models emit tables and we render them as prose; a contained addition to `src/lib/markdown.zig`
- [ ] **33.9** The notifications channel — a transient queue for "the updater restarted", "the IDE connected", "the token budget is nearly gone"; absolutely positioned, so nothing shifts
- [ ] **33.10** The context visualisation — we compute the numbers; the reference implementation draws a proportional chart per category (system, tools, messages, skills, compaction reserve)
- [ ] **33.11** The task panel with blockers and priorities — **the data model already exists** (`src/lib/taskstore.zig`: `blocks`/`blocked_by`/`hasOpenBlocker`) and is not surfaced
- [ ] **33.12** The per-message actions — `shift+↑` targets the message under the cursor; ours has `/copy N` and no per-message targeting
- [ ] **33.13** The transcript search (`/` and `n`/`N`) — our paragraphs are already segmented, so the scan is over the segments, not the cells
- [ ] **33.14** OSC 8 hyperlinks — the paths and the URLs as real links; the detection is ~30 lines and vaxis exposes the cell attributes
- [ ] **33.15** The shortcut help in the footer (`? for shortcuts`) — discoverability, cheap
- [ ] **33.16** The external editor (`ctrl+g`) and the image paste (`ctrl+v`) — the image path already exists (`src/lib/images.zig`)
- [ ] **33.17** The focus detection (dim the caret when the window is not focused) — vaxis reports focus events
- [ ] **33.18** The modal diff viewer — only worth it once a turn can produce multi-file diffs
- [ ] **33.19** The compact-summary line — after a tier-2 compaction the transcript loses history **silently**; one honest line says what was summarised
- [ ] **33.20** The queued prompts' **text**, not just the count
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

- [ ] **34.1** Path-scoped permissions and the dangerous-path protection — **PARTIALLY COVERED (the table + the write tools)**
  - The reference implementation: a path is allowed through SEVEN checks in this order — resolve the path → the deny rules → the internally editable paths → the **safety check** → the working-directory check → the sandbox allowlist → the allow rules. Its safety check blocks `.git/`, `.claude/`, `.vscode/`, `.idea/`, the shell configs and the UNC paths
  - [x] `src/lib/pathsafe.zig` (new, pure): the table, matched **by SEGMENT and case-insensitively** (`a/b/.git/hooks/x` and `.Git/hooks/x` are both caught; `myproject.git`, `zig-out-mine` and `.gitignore` are NOT), and a separate table for the files whose CONTENT is a secret
  - [x] Wired into `write`, `edit`, `notebook_edit` (per file: one bad path does not lose the good ones) and into `read` — `read` never asks for permission, so it was the only place a secret could be refused before going to the provider
  - [x] The refusal NAMES what writing there would do ("a hook there runs on every commit") and points at `bash`, which asks the user
  - [ ] **It REFUSES where the plan says it should ASK.** The false-positive surface is small (a static table, no symlink resolution) but it is not zero: a project with a `.vscode/` the user wants edited is blocked. The "ask" version needs the permission engine of Phase 6, because a tool cannot ask on its own: `ask`/`review`/`skill` are intercepted in `agent.zig` precisely because they need the `Model`
  - [ ] `resolve` (symlinks) — the comparison is on the path as WRITTEN, so a symlink into `.git/` is not caught
  - [ ] The `Tool(pattern)` grammar of Phase 6, and `rename` + the permission detail the dialog shows
- [ ] **34.2** The **frozen decision** of the result cap — **NOT COVERED**
  - The reference implementation: the cap layer keeps a **frozen decision** — a cut is re-applied verbatim on every later turn instead of being recomputed — and it rebuilds that state from the transcript on resume
  - Ours: `src/lib/resultcap.zig:78` `capAggregate` recomputes per call
  - [ ] A `Caps` state (result id → the cut that was made), persisted next to the session and reloaded on resume
  - [ ] Why it matters: a session that compacts differently on resume **silently loses its cached prefix**, and that is invisible until the bill arrives
- [ ] **34.3** `deny` and `ask` as real permission behaviours — Phase 6 says "deny/allow/ask" but never the **precedence**
  - [ ] A `deny` rule removes the tool's schema from the request (the reference implementation filters the tools by the deny rules before composing them) — `src/tools/registry.zig`'s `blob` is where the filter goes
  - [ ] The precedence table written down and pinned by a test, the way `src/lib/exitgate.zig:190` `decide` pins the exit rule
- [ ] **34.4** The dangerous-allow-rule warning and the shadowed-rule detection — **NOT COVERED**
  - The reference implementation: a list of the DANGEROUS patterns (the bare interpreters) and a detector for the SHADOWED rules (a rule that can never fire because another one covers it)
  - Ours: an allowlist entry of `bash` is that hazard in its purest form
  - [ ] When the user answers "always allow" with a broad rule, warn once — a warning, not a refusal
- [ ] **34.5** A **cost** number, per model — **NOT COVERED** (no phase creates a cost state)
  - The reference implementation: a cost tracker that multiplies the token counts by the model's price, and a `/cost` command that prints the total and the per-model breakdown
  - Ours: tokens and hit-rate (`src/cache_stats.zig`), no money
  - [ ] `src/lib/cost.zig` over the price table `src/lib/models.zig` already parses
  - [ ] A model whose price is unknown prints **"price unknown"**, never a number
- [ ] **34.6** The hook output contract (`updatedInput`, `additionalContext`) — Phase 5 has the events, not the contract
  - [ ] The reference implementation: 27 events and 5 hook types
- [ ] **34.7** The memory recall by relevance and the staleness notes — Phase 11 has the store, not the recall
- [ ] **34.8** The background **subagents** (not the background shell jobs) — **NOT COVERED**
  - The reference implementation: the agent tool can run a whole agent in the background; Phase 10 is about `bgproc`
  - [ ] `run_in_background: bool` on the `task` tool, and a **notification to the model** when it lands
- [ ] **34.9** The atomic task claiming — **NOT COVERED** (the reference implementation has a `claim` operation): three parallel agents must not take the same task
- [ ] **34.10** The enforcement of a skill's `allowed_tools` / `model` / `effort` — **NOT COVERED**
  - Phase 1 put the three fields in the frontmatter; **nothing reads them**. A skill that says `allowed_tools: read` can still call `write`
- [ ] **34.11** The conditional skills by path — **NOT COVERED** (a `paths:` field in the frontmatter)
- [ ] **34.12** The `dontAsk` permission mode — **NOT COVERED** (a third state, not a bool: `ask` becomes "answer for yourself")
- [ ] **34.13** The circuit breaker keyed on **consecutive failures**, not on a budget — Phase 7 has the budget
- [ ] **34.14** The `PermissionRequest` hook path for the headless runs
- [ ] **34.15** The "the model was told to stop and did not" mechanism — the reference implementation's `Stop` hook is the user-written version of our exit gate
  - [ ] The composition rule has to be explicit: our gate and a user hook must not both claim the turn
- [ ] **34.16** The per-session price/usage table that `/context` can show

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

- [ ] **35.1** `/files` — **S, the cheapest item on the list**: eight lines of work and we already hold the data (`src/lib/readcache.zig`). It answers "what is the model looking at?", which is the question you ask when a turn goes sideways
- [ ] **35.2** `/init` — **M** for the prompt, **L** with the interview phase. The highest-value missing command: without it a new project has no `AGENTS.md` and the harness silently runs with the built-in prompt only. Port the reference implementation's prompt text **verbatim** and let the model do the work
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
| Skill listing budget | 1% of `ZODE_CONTEXT_LIMIT` | 2 |
| Skill per-entry cap | 250 chars | 2 |
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

## 🚫 Deliberately NOT on this board

- No plugin marketplace, telemetry, or accounts — none of it is core.
- Nothing enters the prompt that is not used: carrying instructions the model has already learned to skip is the biggest mistake a harness of this class makes.
- No abstraction without a second caller: the registry exists because four lists disagree today, not because structure is nice.
