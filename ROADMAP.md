# ROADMAP — zode

The plan from here on: what zode is missing to be a first-class coding harness,
and the order to build it in. This supersedes the earlier diagnostic roadmap (the
layout-loop hang, the tick chain and the render work): that round is done and its
findings live in `AGENTS.md`.

Everything here obeys the three project principles, restated because every item
below is judged against them:

1. **Pure Zig std** — no C dependencies, no mandatory libc. Only external dep:
   libvaxis (pure Zig).
2. **Token saving by design** — anything that goes into the LLM has to earn its
   place. This is the expensive resource.
3. **Radical simplicity** — direct, readable code over premature abstraction.

And the rule that has kept the tree honest: **a module that can be tested without
a TUI and without the network goes in `src/lib/`; anything that touches the
terminal or the socket stays in `src/`.** New features are pushed toward `lib/`
unless they genuinely need the `Model`.

---

## 0. Where zode is today

**Done and verified** (`zig build test`, `tools/pty_smoke.py`, `tools/subagent_smoke.py`,
`tools/router_smoke.py`; binary ~2 MB stripped):

| Area | State |
|---|---|
| TUI | own multiline editor with history, `/` autocomplete, Ctrl+P command palette, Ctrl+T model palette (two columns), Ctrl+A connect, page scroll with sticky bottom, activity strip, segmented status bar, permission modal, ask modal |
| Tools (36) | read, write, edit (multi-hunk), notebook_edit, bash (+background), glob (`subdir`/`limit`/`sort` shipped 2026-10-16), grep, refs, rename, check, git_status/diff/log/branch/add/commit/stash, list_files, web_fetch, web_search, think, todo, task_create/get/list/update/stop, ask, lsp, skill, task (subagents), review, goal, bash_output/bash_kill, sleep |
| Skills | on-disk `.zode/skills/<name>/SKILL.md` (+ `.agents/skills`, + user), name+description in the prompt, body loaded on demand by the `skill` tool; shadowing, mtime+size freshness |
| Subagents | `task` with read-only tools, effort `low`, 24k window, depth 1, up to 3 in parallel, silent retry, model override via `/submodel` |
| Context | 2-tier compaction (free elide + one summarizer call), cache stats, `/context` gauge, prompt ordered by frequency-of-change for the provider cache |
| Discipline | `/goal` + exit gate (a turn may not end on code nobody checked), auto typecheck, `review` before the turn ends, verification table |
| Providers | multi-provider, native Anthropic, retries with backoff, error classification, free-auto rotation, cheap-turn router |
| Sessions | append-only JSONL with zjsonl compression, resume, `/undo` file snapshots |
| Task graph | Phase 15 shipped: `task_create/get/list/update/stop` with derived `blocked_by` (one edge, two views), owner rules, completion refused while a blocker is open, `sessions/zode-<id>.tasks.json`; `task_list` shows who waits on whom |
| Notebooks | Phase 17 shipped: `notebook_edit` (replace / insert before-after / delete by index, outputs + metadata + cell ids preserved, malformed file refused WITH the parse line/column), `read` shows a numbered outline |
| Waiting | Phase 19 partial: `sleep` shipped (no shell process, ESC-interruptible, reports the wait it actually did); periodic ticks and `schedule` still open |

**Measured, not estimated**: binary ~2 MB stripped; 1001 tests (1000 pass, 1 network skip); startup ~18 ms
with the terminal cap; idle RSS ~7 MB.

The gaps are not in any of the above. They are in **what a harness of this class
adds on top**: skills that ship with the binary, output that does not get lost,
an output-shaping layer, extension points, a finer permission model, and memory.

---

## 1. The gaps (what "the next level" means here)

| Capability | Today | Phase |
|---|---|---|
| Tool registry (one table instead of scattered `if/else` + flag lists) | `dispatch.zig` is 26 branches; flags live in 3 places | 0 |
| A single result-cap layer | split between `textcap.zig`, `bgproc`, `max_tool_output` | 0 |
| Bundled skills (shipped in the binary) | none | 1 |
| Rich skill frontmatter (`when-to-use`, `allowed-tools`, `model`, `effort`, `context`) | only `name`/`description` | 1 |
| Skill args (`$ARGUMENTS`) and `context: fork` | none | 2 |
| Skill listing under a token budget | fixed `max_listed = 40` | 2 |
| Large tool result → file + preview + path (recoverable) | elide/truncate | 3 |
| Per-tool output render (condensed / transcript), collapse reads | generic two-tone | 3 |
| Output styles (prompt overlays, `/style`) | none | 4 |
| Hooks (extension points around tool use and prompts) | none | 5 |
| Permission rules with deny/allow/ask + once-off suggestions | flat allowlist + `y/a/n` | 6 |
| Bash read-only classification + optional sandbox | partial | 6 |
| Microcompaction with a recoverable marker, compaction boundaries | 2-tier only | 7 |
| Prompt-cache break detection | fixed order, no detection | 8 |
| Agent definitions on disk | `subagent.zig` hardcoded | 9 |
| Unified background-task registry with notifications | `bgproc` (~70%) | 10 |
| Persistent memory the agent writes | none | 11 |
| MCP over stdio + deferred tool loading | pending | 12 |
| Ecosystem (plugins, keybindings) | none | 13 |
| Semantic code intelligence (a language-server client) | `lsp` tool + client in tree, acceptance of Phase 14 not verified yet | 14 |
| Structured task graph (identity, dependencies, owner) | **shipped** (Phase 15): `task_*` tools over `sessions/zode-<id>.tasks.json` | 15 |
| Batch execution of tool primitives | one call per operation | 16 |
| Notebook cell editing | **shipped** (Phase 17): `notebook_edit` + outline `read` | 17 |
| Isolated worktree sessions | none | 18 |
| Waiting: sleep, ticks, scheduled prompts | `sleep` shipped; ticks and `schedule` pending | 19 |
| Team mode (persistent teammates + messaging) | ephemeral subagents | 20 |
| A durable message to the user, with attachments | plain answer text | 21 |
| Structured output for scripted runs | prose only | 22 |
| Config the model can read and change | human-only edits | 23 |
| Web fetch cache + secondary-model extraction + domain lists | per-URL session cache wired (`webcache.zig`: LRU + byte budget + TTL, `force` flag missing); extractor and domain lists pending | 24 |
| Bash command-safety scan (classify before you ask) | raw line in the dialog | 25 |
| Built-in subagent roles + agent memory + resume/fork | one generic searcher | 26 |
| Word-level diff (which words changed, not which lines) | line-level only, `diff_add_bg`/`diff_del_bg` | 27 |
| Line numbers + markers in the diff gutter | none | 27 |
| A colour capability ladder (truecolor / 256 / no colour) | every colour is sent as `38;2;r;g;b` | 27 |
| A colour-vision-safe palette (daltonized) | none | 27 |
| `/copy` (take the answer with you) | none | 28 |
| `/resume` as a picker over every session | resumes the newest by mtime | 29 |
| Session titles (derived, AI-upgraded, user-renamed) + `/branch` | no titles, no forks | 30 |
| Per-command git allowlist + `/commit` + `/pr` | 8 read-mostly git tools | 31 |
| `` !`cmd` `` inlined into a prompt, with a permission check | `!cmd` from the input only | 31 |
| Three-way finding counts (found / verified / **refuted**) | none | 32 |
| An `advisor` tool with no arguments, at the goal checkpoint | none | 32 |
| Gate before you spend (is there anything to review?) | none | 32 |

---

## Phase 0 — Foundation: tool registry + result cap

Not user-visible. It is what stops every later phase from spreading state across
the tree.

### 0.1 `src/tools/registry.zig` — one table, not four lists

Today a single tool's facts live in four places: its branch in
`dispatch.execute`, its line in `needsPermission`, its line in `defs`, and its
JSON schema. The flags (`read_only`, parallel-safe, destructive) are inferred from
membership in hand-written `std.mem.eql` chains.

Collapse them into a table:

```zig
pub const ToolDef = struct {
    name: []const u8,
    desc: []const u8,
    schema: []const u8,              // the parameter JSON
    read_only: bool = false,         // no permission dialog
    parallel_safe: bool = false,     // may join the parallel batch
    destructive: bool = false,       // for the UI only
    max_result_chars: usize = 16 * 1024,
    run: *const fn (Ctx) anyerror![]const u8,
};
```

`needsPermission(name)` becomes `find(name).read_only == false`; `isParallelSafe`
reads the table; `defs` is generated. **A new tool is one row.** The `run` function
is the only per-tool code; keep the existing files and have each row point at them.

### 0.2 `src/lib/resultcap.zig` — one place that decides what reaches the model

A pure function that applies, in order: (a) the per-tool cap, (b) the aggregate
cap for one turn's batch of parallel results, (c) a "persist instead of truncate"
hook (Phase 3). Today each tool caps on its own and the numbers drift.

Tests (pure): per-tool cap respected; aggregate cap trims the largest results
first; a result exactly at the boundary is untouched; a cut result always carries
its notice inside the budget.

---

## Phase 1 — Bundled skills + rich frontmatter  ← start here

Reuses the whole skill system that already works (`skills.zig`, `skillstore.zig`,
`skillCall`, `buildSystemPrompt`). Highest value for the least risk.

### 1.1 `src/lib/bundled_skills.zig` (pure)

A compiled table. Bodies live as `src/skills/<name>.md` and are pulled in with
`@embedFile`, so there is **no extraction to disk and no runtime temp files**.

```zig
pub const BundledSkill = struct {
    name: []const u8,
    description: []const u8,        // WHEN to use it, not what it is
    when_to_use: []const u8 = "",
    allowed_tools: []const []const u8 = &.{},
    model: []const u8 = "",
    effort: []const u8 = "",
    context: skills.Context = .inline,
    argument_hint: []const u8 = "",
    body: []const u8,               // @embedFile
};

pub fn all() []const BundledSkill;
```

First set — each one reuses something zode already has:

| skill | What it does | Reuses |
|---|---|---|
| `simplify` | review the diff for reuse/duplication before calling it done | `review.zig`, `git_diff` |
| `verify` | verify with the narrowest command that would break if you were wrong | `verify.zig`, `check` |
| `skillify` | turn a repeated task into a new `SKILL.md` | write path + `skills.zig` |
| `debug` | reproduce → isolate → fix the cause, with a backgrounded command | `bgproc`, `bash_output` |
| `goal` | split the objective into steps and drive the visible `todo` list | `todo`, `goal` |

### 1.2 Rich frontmatter in `skills.zig`

Extend `Meta` (the parser stays narrow — `key: value`, no YAML):
`when_to_use`, `argument_hint`, `allowed_tools` (comma/space separated),
`model`, `effort`, `context: inline|fork`.

### 1.3 `Entry` gains `body`, `source`, `context`, `when_to_use`

```zig
pub const Source = enum { project, agents, user, bundled };
pub const Entry = struct {
    name: []const u8,
    description: []const u8,
    when_to_use: []const u8 = "",
    path: []const u8 = "",          // "" for bundled
    body: ?[]const u8 = null,       // non-null for bundled
    source: Source = .project,
    context: Context = .inline,
};
```

`Loader.load` returns the embedded body when `body != null` and never touches the
disk for a bundled skill.

### 1.4 Discovery: bundled as fallback, shadowed like everything else

`discoverSkills` appends bundled entries **after** the on-disk ones; a project or
user skill with the same name shadows a bundled one, exactly as project shadows
user today. `/skills` prints `[bundled]` / `[project]` / `[user]`.

### 1.5 Listing carries `when_to_use`

`systemPromptSection` prints `- name: description (when to use: …)` when the field
is present. `max_listed` stays for now; Phase 2 replaces it with a byte budget.

### 1.6 The `skill` tool takes optional `args`

Schema becomes `{name, args?}`. `skillCall` substitutes `$ARGUMENTS` in the body
with `args` (a single substitution; named args are Phase 2).

### 1.7 Tests (pure, no network)

- table: names unique and valid, description non-empty, body non-empty;
- parser: all eight fields, with and without frontmatter, CRLF, a file that ends
  at the closing fence;
- `systemPromptSection`: includes `when_to_use`; lists bundled; shadowing works;
- `Loader.load`: `body != null` never opens the path (point it at a path that does
  not exist on purpose);
- `skillCall` with `args`: `$ARGUMENTS` substituted, frontmatter absent.

**Acceptance**: `zig build test` green, `/skills` shows the bundled ones tagged,
and the prompt grows by no more than ~1 KB with the five skills.

---

## Phase 2 — Skill listing budget + args + inline/fork

- **Listing under a budget.** `skillListing()` gets a character budget equal to
  **1% of `ZODE_CONTEXT_LIMIT`**, with a **per-entry cap of 250 chars**; bundled
  entries are never truncated; in the worst case only names are listed. Replaces
  the fixed `max_listed`.
- **Send the listing once per session** as an attachment at the end of the prompt
  (so the cacheable prefix is not disturbed), deduplicated per session. Reset when
  the config is reloaded, **not** on compaction.
- **`$ARGUMENTS` and named args** (`$1`, `$name`) substituted into the body.
- **`context: fork`** runs the skill in `src/lib/subagent.zig` (effort `low`,
  read-only tools, disposable window) and returns the result to the main turn.
- **`!cmd` inside a skill** runs the command and substitutes its output (behind
  the permission model from Phase 6).

Tests: the budget caps total size; bundled entries survive a tight budget while
others degrade to names; args substituted; a `fork` skill leaves the main context
untouched (assert the parent message list length is unchanged).

---

## Phase 3 — Output: recoverable results + per-tool render

### 3.1 `src/lib/toolstore.zig` — large result → file + preview + path

If a result exceeds the tool's cap, write it to
`sessions/<id>/tool-results/<n>.txt` and return
`[result stored: N bytes at <path>; read the part you need]` followed by a 2 KB
preview. This **replaces blind elision with something the model can recover**,
which is the difference between losing detail and losing it on purpose.

Constants (all overridable by env, defaults fixed):

| Name | Value | Meaning |
|---|---|---|
| `default_max_result_chars` | `50_000` | threshold to store instead of inline |
| `max_result_bytes` | `400_000` | system-wide ceiling per result |
| `max_results_per_message_chars` | `200_000` | aggregate cap for one turn's batch |
| `summary_max_len` | `50` | one-line summary length for condensed view |

### 3.2 Per-tool render, driven by the registry

`ToolDef` gains two small functions: `summarize` (one line for the timeline:
`read(src/x.zig) · 120 lines`) and `activity` (`Reading src/x.zig` for the strip).
The TUI paints a `condensed` form by default and the full `transcript` on
`ctrl+r` (the mechanism already exists for diffs). Reads and searches
(`grep`/`glob`/`read`) collapse into one line in the timeline.

Tests: a large result is stored and the returned text names the real path; a
stored result survives resume; `summarize` output is one line and under
`summary_max_len`; collapsing does not drop the first line of context.

---

## Phase 4 — Output styles

`.zode/output-styles/*.md` (project) and `~/.config/zode/output-styles/*.md`
(user), with frontmatter `name`, `description`, `keep-coding-instructions`. The
style text is injected as a block **at the end** of the prompt, selected with
`/style [name]`. Ship `default`, `explanatory`, `learning`. Pure: the style is
text, the selection is session state.

Tests: discovery with shadowing; the style block is present when selected and
absent otherwise; `keep-coding-instructions` controls whether the coding rules are
kept alongside the style.

---

## Phase 5 — Hooks

The cheapest way to make zode extensible. v1 is command hooks only.

Events: `PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `Stop`. Config in
`.zode/hooks.json`:

```json
{ "hooks": { "PreToolUse": [
  { "matcher": "bash", "if": "Bash(git *)",
    "command": "./scripts/pre.sh", "timeout_ms": 5000, "once": false }
] } }
```

- `matcher` is a tool name or a regex; `if` uses the permission-rule syntax
  (Phase 6); `timeout_ms` bounds the run; `once` fires a hook at most once.
- Hook output is fed back as a tool result / system note. A non-zero exit on
  `PreToolUse` blocks the tool with the reason.

Tests (pure): config parsing, event/matcher/`if` matching, `once`, timeout. The
execution path uses the existing process runner and is covered by one integration
test with a real script.

---

## Phase 6 — Fine-grained permissions + bash read-only + sandbox

- **Rule model** with sources and precedence (local > project > user > policy),
  syntax `Tool(pattern)` (e.g. `Bash(git *)`, `Read(*.ts)`), actions
  `deny` / `allow` / `ask`.
- **Once-off suggestions**: a permission request returns rules the user can accept
  ("always allow `Bash(git *)`") that are then learned per tool+pattern. Today
  there is only a flat allowlist.
- **Bash read-only classification**: a table of commands and flags that are safe
  (`git status`, `rg`, `ls`, `wc`, …) so the common read commands stop asking. By
  command and flags, not by guessing.
- **Optional sandbox**: if `bwrap` or `firejail` is present, run `bash` inside it.

Tests (pure): rule parsing and precedence; `Tool(pattern)` matching; the
read-only table (a write command with a read-looking name is not exempt); a denied
rule yields `deny` before any `allow`.

---

## Phase 7 — Context compaction v2

Today: 2-tier (elide + one summarizer call) with a per-session capped count. Add:

- **Microcompaction with a recoverable marker**: old tool results are replaced by
  a marker that names the stored file (Phase 3), so nothing is lost, only moved.
- **Compaction boundaries**: requests are trimmed to the last boundary so a later
  resume does not re-send summarized history.
- **Preserve invoked skills and read files** across a compaction.
- **Circuit breaker**: after N failed summarizer attempts, stop trying (do not
  spend a request per turn forever).

Tests: boundary trimming; a skill invoked before compaction is still known after;
the circuit breaker trips and stops.

---

## Phase 8 — Prompt-cache break detection

The prompt prefix order is already chosen to be stable (most-frequently-changing
last). Add detection on top: compare the prefix actually sent with the previous
one, and warn when it broke and why. Target: `writes_per_request > 0.5` in a long
session means the prefix is unstable. Pairs with the existing cache stats.

Tests (pure): a stable prefix reports no break; inserting a change in the skills
block reports the block and the position.

---

## Phase 9 — Agent definitions on disk

`.zode/agents/*.md` with frontmatter (`name`, `description`, `tools`, `model`,
`effort`). A `task` call can name a definition; without one it uses the current
defaults. Keeps the existing safety: read-only tools, effort `low`, depth 1,
24k window.

Tests: discovery with shadowing; an unknown definition falls back to the default;
the tool list of a definition is a subset of the read-only set (a definition
cannot escalate).

---

## Phase 10 — Unified background tasks

Unify `bgproc` + `bash_output` into one task registry with: output written to a
file, incremental polling, and a **notification to the model** when a task
finishes (a system event, not polling). The current implementation already covers
~70% of this.

Tests: a finished task notifies once; incremental output returns only what is
new; a killed task reports its terminal state.

---

## Phase 11 — Persistent memory

Memory the agent writes and reads back, separate from the session log:

- per-project store (markdown, indexed, out of the prompt until consulted);
- an end-of-turn extractor (a subagent) that proposes memories; the user approves;
- `AGENTS.md` loading with `@import` and precedence.

zode already injects the project's instruction file; this adds the store the agent
maintains. Tests (pure parsing, disk fixtures in a temp root): discovery,
precedence, `@import` resolution, a memory outside the budget is not inlined.

---

## Phase 12 — MCP over stdio + deferred tool loading

- MCP over stdio (JSON-RPC): connect, list tools, call.
- **Deferred tool loading / tool search**: when many tools exist (MCP servers),
  do not put every schema in the prompt; load them by search. This is what keeps
  MCP from wrecking the cache.

Tests: a fake MCP server over a pipe; a deferred tool is invisible until searched
and callable afterwards.

---

## Phase 13 — Ecosystem (optional, on demand)

Plugins/marketplace, remote sessions, keybindings/vim mode. Outside the core; done
only if usage asks for it.

---

## Phase 14 — Semantic code intelligence (a language-server client)

`refs` and `rename` are regex heuristics over declaration shapes: they know
zig/rust/go/python/js/ts/c/sh but they guess. The one thing they cannot answer is
what the compiler already knows: the *type* of an expression, the *interface
implementations*, the *callers* of a function, the *diagnostics* a file has right
now.

Add an optional language-server client: keyed by file extension, started on
demand over stdio (JSON-RPC, the same transport Phase 12 uses for MCP), reused
for the session, killed at teardown. One `lsp` tool with an `operation` field:

| operation | answers |
|---|---|
| `definition` | where this symbol is declared (exact, multi-file) |
| `references` | every real reference, not a text match |
| `hover` | the signature and doc of the symbol under the cursor |
| `document_symbols` | the outline of one file |
| `workspace_symbols` | search symbols across the project by name |
| `implementations` | the types that implement an interface or method |
| `incoming_calls` / `outgoing_calls` | who calls this, what this calls |
| `diagnostics` | the errors and warnings a file has right now |

`refs` stays: it is instant, needs no server, and works in a language with no
server configured. `lsp` is asked for when precision matters (a rename plan, a
"who calls this", a type you cannot read off the source).

- **Degrade, never block**: no server for the file type → the tool says so and
  the model falls back to `refs`/`grep`. The server is a bonus, not a barrier.
- **Position is `file` + `line` + `character`** (1-based, the coordinate every
  editor and server agrees on). The `character` is resolved from the symbol name
  when one is given, so the model does not have to count columns.
- **The protocol is pure and tested separately** (`lib/lsp_protocol.zig`:
  framing, requests, the `initialize`/`shutdown` handshake, the
  `textDocument/*` mapping) against a fake server over a pipe — no editor, no
  network.
- **A per-project server table** in config (`lsp_servers`: extension → command),
  with a small built-in default set (zls, rust-analyzer, gopls,
  typescript-language-server, pyright, clangd) and the same "not installed →
  skip" rule as `check`.
- A semantic answer is short (a location, a signature), so `max_result_chars` is
  small and the feature costs little in the prompt.

Tests: the fake server drives every operation; a missing server degrades to a
named error and never hangs; a server that dies mid-session is restarted once;
`document_symbols` on a real fixture returns the outline. Acceptance: `refs`
still works with no server installed.

---

## Phase 15 — The structured task graph

`todo` is what the user SEES: one list, one screen, replaced as work moves. It
is deliberately not durable and deliberately not shared. What is missing is the
other thing: **work items with identity, dependencies and an owner**, which a
long task — and a team of agents (Phase 20) — needs to coordinate.

Add a task store (`sessions/<id>/tasks.json`), one record per item:

```zig
pub const Task = struct {
    id: u32,
    subject: []const u8,        // imperative: "Run the migration"
    description: []const u8,    // enough for another agent to do it
    status: Status,             // pending | in_progress | completed | deleted
    owner: []const u8 = "",     // "" = unclaimed
    blocks: []const u32 = &.{},
    blocked_by: []const u32 = &.{},
};
```

Tools: `task_create`, `task_get`, `task_list`, `task_update` (status, subject,
description, owner, `add_blocks`/`add_blocked_by`), `task_stop`. The visible
`todo` remains for the human; the graph is for coordination.

- **`blocked_by` is derived, never typed twice**: setting `blocks` on A adds
  `blocked_by A` to B. One edge, two views, always consistent.
- **An `in_progress` item with no owner is refused**, so a teammate cannot claim
  work by ignoring it, and `task_list` names what is waiting on what — the thing
  a flat checklist cannot say.
- **A task cannot complete while it blocks an open one**, and completing a
  blocker unblocks the list in the same update.

Tests (pure): create/get/list round-trip; an edge set from either side reads the
same from both; a blocked task reports its blocker; completing a blocker
unblocks; deleting a task clears the edges that pointed at it.

---

## Phase 16 — Batch execution: many operations, one round trip

A round trip is a whole request, and requests are the expensive resource. Today
a rename across nine files is one `edit` with nine hunks (good), but "count the
lines in these four files, find the TODO in the two that have it, and write the
result to a report" is five calls and five round trips.

Add a `batch` tool: a small, **sandboxed** step runner that takes a list of
steps, runs them in order on the host side, and returns only the final value
plus a one-line log per step. It exposes the read-only primitives (`read`,
`grep`, `glob`, `list_files`, `refs`, `git_*`) and the editors (`write`, `edit`)
under the SAME permission rules as a direct call — a batch is not a way to
bypass the dialog.

- **Not a shell and not a general language.** No process spawn, no network, no
  arbitrary code: a fixed, enumerable set of step kinds (`map`, `filter`,
  `select`, `count`, `write`) over the tool outputs. The size of the surface is
  the whole safety argument.
- **Read-only by default**: a batch that writes needs the same approval a
  `write` call would, and the approval names the files it would touch.
- **Failure is per-step and named**: a step that fails says which step and why;
  the rest does not run unless the batch declares `continue_on_error`.
- **The savings are visible**: the log reports `9 steps, 1 request`.

Tests (pure): step parsing and validation; the read-only default refuses a write
without approval; a failed step stops the batch and names itself; a batch over
four files returns one result and no per-file round trip; the permission set of a
batch equals the union of its steps.

---

## Phase 17 — Notebook editing

`.ipynb` is JSON with an array of cells, and editing it with `edit` means matching
a JSON string with escaped newlines — which fails for the reason every
escaped-match fails. Add `notebook_edit`: address a cell by index, replace its
source, or insert/delete a cell.

- **The round-trip preserves everything else**: outputs, metadata, the cell id
  and the notebook format version are written back untouched. A tool that
  rewrites an ipynb into a clean one destroys the outputs the user was looking
  at.
- **The source is the cell's text, not its JSON encoding** (the join of its
  lines); the tool encodes on write.
- **It is a write**: same permission, same undo snapshot as `write`/`edit`.
- Discovery: a `.ipynb` read through `read` shows cell boundaries and indices, so
  the model knows the numbering before it edits.

Tests (pure, fixture notebooks): replace by index; insert before/after; delete;
an out-of-range index is a named error, not a corruption; outputs and metadata
survive; a malformed ipynb is refused with the parse location.

---

## Phase 18 — Isolated worktree sessions

A session that starts a risky refactor should be able to do it somewhere else and
come back. Add `enter_worktree` / `exit_worktree`: create a git worktree (under
the project's own `.zode/worktrees/`), switch the session's working directory to
it, and remember where to return.

- **Only when asked.** The tool is never proactive: a branch is what a branch is
  for, and a worktree is a heavier promise. The tool's description says so.
- **`exit` keeps or removes**, and **`remove` refuses a dirty worktree** unless
  `discard: true` is explicit, listing what would be lost first — "destructive" is
  a decision the user makes, not a default.
- **The session caches reset on the switch**: project info, the instruction file,
  the plan directory and the cwd-derived prompt blocks are re-read, so the session
  never mixes two trees (the `@file` and read-cache correctness depends on it).
- **Cleanup at exit**: a worktree left behind is named on the way out, and
  `/clean` (which already lists leftovers) knows about them — but never removes
  one without being told.
- Both tools are a no-op with a clear message outside a git repository or when no
  worktree session is active.

Tests (pure, fixture repo): enter creates and switches; a second enter is
refused; exit keep leaves the tree; exit remove on a dirty tree is refused and
lists the changes; the cwd and caches are restored; no-op outside a repo.

---

## Phase 19 — Waiting: sleep, ticks and scheduled prompts

The harness has a clock but no way for the model to wait on purpose. A model that
polled a background job in a tight loop burned iterations; a model that wanted to
"check back in five minutes" ran `bash sleep`.

- **`sleep {seconds}`** — waits without holding a shell process, interruptible by
  ESC. It costs one API call per wake-up, and the prompt says so, so it is not
  used where a `bash_output` poll would do.
- **Periodic ticks** — while a turn is parked waiting, the harness may deliver a
  short check-in ("anything useful to do while you wait?") instead of sitting
  silent. Off by default; a session flag turns it on. It is the only way a
  long-running background job becomes useful instead of just background.
- **Scheduled prompts** — `schedule {cron, prompt}` creates a recurring prompt for
  this project ("every Monday, run the flaky test and report"), with `schedule
  list` / `schedule remove`. Stored next to the session, never in the prompt, and
  delivered as a user message when it fires.
- **The permissions are the same as a typed prompt**: a scheduled prompt that
  wants to write still asks.

Tests (pure): cron expression parsing (5-field, ranges, steps, names); a `once`
schedule fires once and is removed; a `sleep` is interruptible and reports how
long it actually waited; a tick is suppressed while a tool is running.

---

## Phase 20 — Team mode: persistent collaborators

`task` spawns a subagent for one bounded search and throws its window away. That
is right for a search and wrong for a long job that needs to keep its own state:
"watch the test suite and fix flakes as they appear" is not a question, it is a
role.

Add teams: a small set of named agents with durable identity, sharing the task
graph (Phase 15) and able to message each other.

- **`team_create {name}`** starts a team and its task list (Team ≡ TaskList);
  **`team_delete`** shuts it down.
- **Spawning a teammate** uses the existing subagent machinery plus `name` and
  `team` — same safety defaults (read-only tools unless the lead grants more,
  effort `low`, depth 1).
- **`send_message {to, message}`** — to a teammate by name, or to `"*"` for a
  broadcast (explicitly expensive, linear in team size). Plain assistant text is
  NOT visible to another agent; a message is a tool call, and that is the only
  channel.
- **Teammates go idle between turns** and claim from the task graph (`task_list`
  → `task_update` with `owner`); a teammate is never pushed work it did not take,
  and the lead does not narrate the idleness.
- **Orderly shutdown**: the lead requests shutdown, teammates acknowledge, and a
  killing sweep runs on exit like `bgproc`'s. No teammate outlives the app.
- **The concurrency cap is the same `ZODE_TASK_PARALLEL`**, because three streams
  on one key is the whole reason it exists.

Tests (pure): create/delete; message routing by name and broadcast; a message to
an unknown name is a named error; claiming sets the owner and only one agent can
own a task; a shutdown request is answered exactly once.

---

## Phase 21 — Answering the user: the message, not the log

Today the model's answer is whatever text the turn produced, and a file it wants
to show (an image, a diff, a log) has to be described in prose. Add
`send_user_message {message, status, attachments?}`:

- **`message` is what the user reads** — markdown, and the place the real answer
  goes. A turn that puts the answer in plain text and "done!" in the message is
  the failure this tool exists to remove, so the prompt says the opposite
  explicitly.
- **`status`** labels intent: `normal` for a reply, `proactive` when the model
  initiates (a scheduled task finished, a blocker surfaced in the background).
- **`attachments`** take paths (images, diffs, logs) that the TUI renders inline
  (images already have a path from `read`); a path that does not exist is a named
  error, not a silent drop.
- It is **not** a replacement for the streaming answer in an interactive session:
  it is for the durable statement, and for the non-interactive runs (Phase 22)
  where there is no reply stream to read.

Tests (pure): markdown passes through; an attachment that does not exist errors;
a `proactive` status routes to the notification path; an empty message is refused
(the user would read nothing).

---

## Phase 22 — Structured output for scripted runs

`zode --chat` is used from scripts and CI, and a script wants a machine-readable
final answer, not prose it has to parse. Add an **opt-in structured-output mode**:
the caller supplies a JSON schema and the runner exposes one tool
(`structured_output`) that the model MUST call exactly once at the end, with an
object validated against the schema before the run exits.

- **Validation is the contract**: the object is checked against the schema (types,
  required fields) and a mismatch is a named error the model sees and can fix, not
  a malformed line a script trips on.
- **The mode is off in the TUI** (there is a human reading the answer) and on for
  `--chat --schema <file>`; the schema never enters the interactive prompt.
- **Exit code reflects the shape**: schema satisfied → 0 with the JSON on stdout;
  a turn that ended without calling the tool → non-zero with the reason, so a CI
  job fails loudly instead of parsing a prose apology.

Tests (pure): schema validation accepts a good object and names the first
missing/wrong field; a run that never calls the tool exits non-zero; the schema is
absent from an interactive prompt.

---

## Phase 23 — Settings the model can read and change

zode's configuration lives in `config.json`, `auth.json` and the permission
allowlist, and today only the human edits it (except for `/submodel`, which is
session state). Add a `config` tool with `get` / `set` over a **whitelisted** set
of keys (model, effort, compaction mode, auto-check, task-parallel, output style,
web allow-local), so "turn on plan mode by default" is a request the model can
carry out instead of an instruction it can only repeat.

- **Whitelist, not free-form**: the tool can only touch keys it documents, and
  never `auth.json`; a key it does not know is refused with the list of keys it
  does.
- **Secrets are never returned**: `get` on a key backed by a credential returns
  "set"/"not set", never the value.
- **`set` is a write with a dialog** unless the key was already allowed, because
  changing the model or the compaction mode changes every later request.

Tests (pure): whitelist enforced; an unknown key lists the known ones; a secret is
masked; `set` round-trips through the config serializer and survives a reload.

---

## Phase 24 — Web fetch/search quality

`web_fetch` pages correctly (header + `offset`) and `web_search` has two engines.
Three upgrades that each save either tokens or a failed call:

- **A per-URL cache** for a session, so the "2–3 calls at one url" the routing
  table recommends do not pay the network twice; a `force` flag bypasses it.
- **Secondary-model extraction**: when a page is long and the question is narrow,
  a cheap model reads the window and returns the answer plus the quotes it relied
  on, instead of the model paying for 16 KB of HTML-derived text. The quotes are
  mandatory — an answer with no quote is not evidence.
- **Domain allow/block lists** (`web_domains.allow` / `.block` in config) applied
  to both the search results and the fetch, with the metadata-service range
  (already refused) as a fixed floor. A block-list entry the user sets is
  absolute; the allow list is for a company wiki the model should prefer.

Tests (pure): the cache returns the stored page and `force` re-fetches; the
extractor must return a quote that appears in the window or the call errors;
allow/block precedence (block wins over allow).

---

## Phase 25 — Bash safety: classify before you ask

Related to Phase 6 but its own concern: Phase 6 decides *whether to ask*, this
decides *what is dangerous*. The dialog is useless if a one-line command hides a
`rm -rf` behind a pipe.

- **A command-safety scan** (pure, `lib/cmdsafety.zig`): splits a command line
  into its parts (pipelines, `&&`/`||`/`;`, substitutions) and flags the ones that
  write, delete, exfiltrate, or chain into a shell (`curl … | sh`), naming the
  exact fragment that is dangerous.
- **The classifier is data, not a heuristic**: a table of command families and the
  flags that change them, so `git status` is quiet and `git clean -fdx` is not,
  and a new family is one row.
- **The dialog shows the risk**, not the raw line: "this deletes unreferenced
  files" beats "git clean -fdx", and a flagged fragment is what the user reads.
- **The read-only table (Phase 6) reuses it**: a command is only "read-only" if
  the scanner found nothing to flag.
- **Optional sandbox**: if `bwrap` exists, offer a sandboxed `bash` for commands
  the scan flags, so a dialog is not the only answer.

Tests (pure): the parser splits quoted separators correctly (a `;` inside a string
is not a separator); a pipe into `sh` is flagged with the fragment; `git status`
is clean and `git clean -fdx` is not; a command with a substitution is flagged by
the substitution.

---

## Phase 26 — Built-in subagent roles and agent memory

`task` is one generic read-only searcher. Three roles pay for themselves as
built-ins with their own prompts, chosen by name:

| role | job |
|---|---|
| `explore` | broad, parallel search; report paths and lines, never edits |
| `plan` | read-only architect: explore, then produce an ordered plan |
| `verify` | try to break the change: run it, exercise it, find the 20% the first 80% hides |

And, on top of Phase 9's on-disk definitions:

- **Agent memory**: a per-project, per-role directory the agent reads at start and
  appends lessons to; out of the prompt until consulted, so it costs nothing when
  empty.
- **Resume / fork**: a subagent can be resumed with its window intact (a search
  that found half the answer continues) or forked (the same context, a different
  question) — both bounded by the same 24k window and depth 1.

Tests (pure): role selection by name; an unknown role falls back to the default;
a role's tool list is a subset of what the caller is allowed (a role cannot
escalate); memory is not inlined into the prompt; resume keeps the window and fork
does not share it.

---

# Findings from `code-of-claude-code/` (2026-10-16)

A read of five things in `code-of-claude-code/`: `commands/review.ts` +
`commands/review/`, `commands/ultraplan.tsx`, `commands/resume/`,
`commands/commit.ts` + `commit-push-pr.ts`, `commands/copy/`, and
`native-ts/color-diff/`. What follows is what is **actually in those files**, and
what it costs us to do the same.

Three of them are a port of a readable source, three are not, and the difference
matters:

| source | in this tree? | what we can honestly do |
|---|---|---|
| `native-ts/color-diff/index.ts` (999 lines) | **yes, complete** | port the algorithm. Every constant is in the file. |
| `commands/copy/copy.tsx` (370 lines) | **yes, complete** | port the walk, the picker and the clipboard ladder |
| `commands/resume/` | client only; the picker is `components/LogSelector.tsx`, the data layer is `utils/sessionStorage.ts` | port the ideas; the code is elsewhere |
| `commands/commit.ts`, `commit-push-pr.ts` | **yes, complete** | copy the prompt text verbatim |
| `/ultraplan`, `/ultrareview`'s engine, `/bughunter` | **no** — the prompt and the finder agents live server-side; `commands/bughunter/index.js` is `isEnabled: () => false, isHidden: true` | port the **protocol** (`found`/`verified`/`refuted`) and nothing else |

**The rule for this section**: a mechanism that is only described by env vars is
not a mechanism. `BUGHUNTER_FLEET_SIZE=5`, `BUGHUNTER_MAX_DURATION=10min` and the
three-stage `finding → verifying → synthesizing` progress wire are pinned by the
client that reads them; "what the finder agents are told" is not in this tree, and
writing a plausible-looking prompt for it would be exactly the
`effortSupport`-table failure this repo has already paid for once — a test that
compares our JSON against our own idea of the JSON proves nothing.

---

## Phase 27 — The diff you can read ← **start here**

The one source in this set that is a complete, readable implementation of
something we do worse. `native-ts/color-diff/index.ts` is a diff renderer, and the
part worth stealing is not the colours: it is **the order of the pipeline**.

### 27.1 What we have today, measured

`markdown.unifiedDiff` produces `@@ -a,b +c,d @@` plus `+`/`-`/` ` lines;
`diffSegments` colours a line by its prefix (`diff_add` / `diff_del` /
`diff_ctx`) and tokenizes the body with `highlight.highlightLine`. So the **line**
is the unit of change, and there are **no line numbers** — the `@@ -a,b +c,d @@`
header carries the position, once per hunk, and nothing after it does.

The finding that changes the estimate: **the diff has no background at all.**

```
$ grep -rn diff_add_bg src/
src/lib/theme.zig:149:pub const diff_add_bg: vaxis.Style = bg(0x0e, 0x1f, 0x14);
src/lib/theme.zig:325:    .{ ok, diff_add_bg },
```

Two hits. `diff_add_bg` / `diff_del_bg` are **declared and never painted** —
their only use is as the *other half of a contrast pair* in `text_pairs`. A diff
line is green or red **text** on the terminal's own background, exactly like the
flat-green wall that section 23's own comment says was fixed and came back in a
different form: `code_bg` is applied to `.code` blocks (`tui.zig:496`) and
`.diff` gets nothing (`tui.zig:427` puts a `null` gutter on it and moves on).

So the ladder is missing its **bottom two rungs**, not its top one:

| level | today | after |
|---|---|---|
| line band (background) | **absent** | `diff_add_bg` / `diff_del_bg`, padded to the right edge |
| changed words | absent | a third colour *on top of* the band |
| gutter | absent | marker + right-aligned line number, per hunk |

That is why the phase is cheap rather than a rewrite: the pipeline already
produces exactly what step 5 consumes (`md.Segment`s with byte ranges), and the
painter already knows how to set a background per cell.

### 27.2 The algorithm, which is the whole port

Per hunk, in this order. Steps 1-4 are pure; only step 5 touches the painter.

**1. Assign a marker and a line number.** Two counters. `+` consumes the new one,
`-` the old one, a context line consumes **both** and shows the new one
(`color-diff`'s `render`, the first pass):

```ts
case '+': lineNumber = newLine++; break
case '-': lineNumber = oldLine++; break
case ' ': lineNumber = newLine; oldLine++; newLine++
```

The gutter width is `digits(max(oldStart+oldLines, newStart+newLines))` **per
hunk**, not per file, so a hunk at line 4000 does not widen the gutter of the
whole diff. Wrapped continuation rows get blank gutter cells and **never** a
second copy of the number.

**2. Pair the runs.** `findAdjacentPairs` walks the markers: a maximal run of `-`
immediately followed by a maximal run of `+` is paired positionally, up to
`min(del_count, add_count)`. A `-` with no `+` after it (a pure deletion) and a
`+` with no `-` before it (a pure insertion) stay **unpaired and get no word diff**
— there is nothing to compare them against.

**3. Tokenize and LCS each pair.** The tokenizer splits into three kinds of run,
and the third one is the one that matters in code:

- a run of `[\p{L}\p{N}_]` → one token,
- a run of whitespace → one token,
- **anything else → one token per codepoint**.

"Anything else, one codepoint at a time" is why `x += 1` is five tokens and not
one: in code, `+=`, `=>` and `!=` are words. This is the same conclusion
`lib/edit_hint.zig` reached independently (tokens split on **spaces**, never on
punctuation), and the two must use **one** tokenizer or the two diffs disagree
about what a token is.

Then a token-level LCS (`markdown.unifiedDiff` already does line-level LCS and
can be reused verbatim on the token arrays) yields byte ranges: removed tokens map
to ranges in the old line, added tokens to ranges in the new line.

**4. The noise guard, which is the feature.** `CHANGE_THRESHOLD = 0.4`:

```ts
if (totalLen > 0 && changedLen / totalLen > CHANGE_THRESHOLD) return [[], []]
```

Above 40% changed, the word ranges are **discarded** and the line falls back to
the flat line colour. A rewrite highlights nothing at word level because at that
point the word highlighting is not information, it is confetti. This is the same
call as `lib/edit_hint.zig`'s 0.50 Jaccard threshold, for the same reason: a
highlight that is wrong is worse than no highlight.

**5. Split each highlighted segment at the range boundaries.** `diffSegments`
already tokenizes the body into `md.Segment`s; `applyBackground` then walks those
segments tracking a byte offset and emits a **word-coloured** sub-segment inside a
range and a **line-coloured** one outside. Byte offsets, not columns: the ranges
come out of the tokenizer as byte positions.

One change is forced by this step: **`diffSegments` calls `hl.highlightLine`, the
stateless one** (`markdown.zig:383`). A diff hunk is a *contiguous slice of a
file*, so a changed line is very often the middle of a block comment or a
multiline string, and the stateless call has no idea. It has to become
`highlightLineState` with the state threaded down the hunk — which is also what
the `@@` header breaks: after a hunk header the state resets, or line 40 of a hunk
is coloured as the tail of line 12's comment.

**6. Two things the pipeline does that we would otherwise get wrong.**

- **Word diff is skipped entirely when the block is `dim`.** The collapsed
  preview (`diff_preview_lines = 12`) and the collapsed Ctrl+R state are already
  "quieter"; word highlights on top of a dimmed preview is noise in a box.
- **Changed lines are padded to the right edge** with the line background, so the
  band reaches the border instead of stopping at the last character. Ours has
  **no band at all** (see 27.1), so this is the trailing half of a fix whose
  first half is "paint the background".

### 27.3 The colour ladder: vaxis does **not** do this for us

This is the finding worth the most, and it is verifiable in the dependency.
`Vaxis.zig:626-630` (`printCell`, the foreground branch):

```zig
.rgb => |rgb| switch (self.sgr) {
    .standard => try tty.print(ctlseqs.fg_rgb, .{ rgb[0], rgb[1], rgb[2] }),
    .legacy   => try tty.print(ctlseqs.fg_rgb_legacy, .{ rgb[0], rgb[1], rgb[2] }),
},
```

**There is no rgb → 256 conversion anywhere in vaxis.** The only capability it
consults is `caps.no_color`, which means "print no colour at all". So every one of
the 32 `rgb(...)`/`bg(...)` literals in `theme.zig` — the brand colour, the two
diff backgrounds, the header — is emitted as `38;2;r;g;b` on a terminal that
answered DA1 saying it has no truecolor. Most terminals approximate it; some show
nothing. We have been shipping truecolor to 256-color terminals for the life of
the project and never asked.

The ladder, top to bottom:

| `caps` | what we paint |
|---|---|
| `caps.rgb` true | the palette as it is |
| `caps.rgb` false | `.index` colours: a port of `ansi256FromRgb` |
| `caps.no_color` true | no colour: the diff is `+`/`-` in **bold** and nothing else |

`ansi256FromRgb` is 20 lines and it is worth copying exactly because of one rule:
the grey ramp is a **competitor**, not a fallback.

```ts
const cubeIdx = 16 + 36 * qr + 6 * qg + qb
const greyLevel = clamp(round((grey - 8) / 10), 0, 23)
const dCube = (r-cr)² + (g-cg)² + (b-cb)²
const dGrey = (r-g)² + (g-g)² + (b-g)²      // vs the ramp's own colour
return dGrey < dCube ? greyIdx : cubeIdx
```

Quantize each channel to the cube's six levels, build **both** candidates, and
pick the closer one in RGB distance. The comment that earns it:

> "Beyond the ramp's range the cube corner is the only option — ansi_colours snaps
> 248,248,242 to 231 (cube white), not 255 (ramp top)."

It goes in `theme.zig` behind the existing `rgb()`/`bg()` helpers, which is the
only place that knows about a colour: 38 call sites, one change, and the
`no_color` case is a single early return.

### 27.4 A colour-vision-safe palette

`buildTheme` has a `isDaltonized` axis and it is not decoration: green/red is the
single most common colour-vision deficiency, and green-vs-red at low background
intensity is *also* the axis most 3-of-5 monitors collapse. The alternative pair
in the source is blue/orange (`addLine: rgb(219,237,255)`,
`addDecoration: rgb(36,87,138)` for light; `rgb(0,27,41)`/`rgb(81,160,200)` for
dark).

`theme.zig` already owns the measuring instruments — `contrast()`, `luminance()`,
`hueSat()` — which is what makes this testable instead of a matter of taste:

- `ZODE_DALTONIZED=1` (and a `/color daltonized` picker entry) selects the pair.
- A test asserts the add/delete pair differs in **hue**, not only in lightness,
  using `hueSat`. A palette that passes on lightness and fails on hue is the exact
  failure this is for.
- The existing test at `theme.zig:439` ("the accent and the diff green are told
  apart by CHROMA, not by lightness") is the precedent: the palette is a measured
  artefact here, not a set of literals somebody liked.

### 27.5 What is deliberately NOT ported

`asTerminalEscaped` / `colorToEscape` / the whole `{r,g,b,a}` `Color` struct with
its `a: 0` = palette-index and `a: 1` = terminal-default sentinels (≈120 lines):
we paint vaxis cells, so the escape generation is vaxis's job and the sentinel
encoding is a workaround for not having one. Also not ported: the highlight.js
integration (`highlight.zig` is ours and stateful), the `BAT_THEME` env stub, and
the lazy `require` loader. `ColorFile` — a plain file view with line numbers, no
markers — **is** worth having later, for a `/file` view; it is not in this phase.

### 27.6 Tests (all pure, no TUI, no network)

| test | what it pins |
|---|---|
| `tokenize splits an operator into its own token` | `x += 1` is 5 tokens |
| `findAdjacentPairs leaves a pure deletion unpaired` | no word diff without a counterpart |
| `a line that is 50% changed gets no word ranges` | the 0.4 guard |
| `a line that is 10% changed does` | and it is not vacuous |
| `ranges split a segment into three` | inside / before / after, byte offsets |
| `the segments of a diffed line concatenate to the original line` | the invariant `markdown.zig` already asserts for every other path |
| `ansi256FromRgb picks the cube for a saturated colour and the ramp for a grey` | both branches |
| `every theme colour survives a round trip through the 256 ladder` | no colour becomes "terminal default" |
| `the daltonized pair differs in hue` | `hueSat`, not eyeballs |
| `tui.drawTest: only the changed token carries the word background` | reads the surface cell by cell |

Plus one scene in `zig build ui-frame` (a `write` of a 600-line file) so the
*composition* is judged, which is the question the `ui-frame` harness exists for
and the only one a per-cell test cannot answer.

---

## Phase 28 — `/copy`: taking the answer with you

There is no way to get the model's answer out of zode. The user scrolls up,
selects with the mouse, and copies with the terminal's own machinery — which
works, and is three steps and a scroll position to lose.

From `copy.tsx`, in order of value:

1. **Walk newest-first, and skip the turns that said nothing.** The last entry in
   a message array is very often a tool-only turn.

   > "Walk messages newest-first, returning text from assistant messages that
   > actually said something (skips tool-use-only turns and API errors)."

   Three filters, each earning its place: wrong role, an API error masquerading as
   an assistant turn, empty text. The text blocks of one turn are joined with
   `\n\n`, so an assistant message with interleaved tool_use blocks is one
   copyable string. **The markdown must be cleaned first** (`stripPromptXMLTags`
   upstream; here: our own prompt-XML removal) or a system-only block becomes a
   fake "code block".

2. **`/copy N` reaches back N-1 turns**, `MAX_LOOKBACK = 20`, and the failures are
   honest arithmetic: `Only 3 assistant messages available to copy` — not
   "invalid". The pluralisation of message/messages is the tell of a codebase
   that treats feedback text as UI.

3. **The picker only appears when there is something to choose**, and the first
   row is the whole response, focused by default:

   ```
   Full response (8123 characters, 214 lines)      ← focused
   <first line of block 0>  (zig, 40 lines)
   <first line of block 1>  (bash, 3 lines)
   Always copy full response                        ← writes copyFullResponse
   ```

   The labels are **the code's own first line**, truncated to 60 columns by
   display width. The last row remembers: a picker that reappears identically every
   time teaches the user that it is broken. We have the picker
   (`openPicker`/`drawPicker`) and the row owner has to be a heap copy — the same
   rule as `askPickerChosen`'s labels.

4. **The clipboard is a three-rung ladder, decided BEFORE the copy runs**:
   `native` (pbcopy/wl-copy) → `tmux load-buffer` → `OSC 52`. And two things
   about the order of operations:

   - **OSC 52 first, file I/O after.** Upstream learned this the expensive way
     (awaiting tmux cost 50-100 ms before pbcopy even started, so a fast
     cmd+tab→paste beat it). In a vaxis TUI the sequence has to go through
     `app.renderer` and must not interleave with a differential redraw — and
     `tui.zig:3889-3895` already has the scar of an OSC 52 written at the wrong
     moment (it painted `^[]52;c;…` over the UI, because it was emitted outside
     `vx.render`). Write it in the same place that one goes, or nowhere.
   - **The file is written ALWAYS**, and the message says so with numbers:

     > "Copied to clipboard (8123 characters, 214 lines)\nAlso written to
     > /tmp/…/response.md"

     OSC 52 is genuinely best-effort (iTerm2 disables it by default). A copy
     confirmation you cannot check is not a confirmation.

5. **The fence language becomes a file extension, sanitised**, because a language
   tag is model output and a path is a filesystem:

   > "Sanitize to prevent path traversal (e.g. ` ```../../etc/passwd `)"
   > `const sanitized = lang.replace(/[^a-zA-Z0-9]/g, ''); return sanitized && sanitized !== 'plaintext' ? '.'+sanitized : '.txt'`

6. **Cancelled is not an error.** Esc says `Copy cancelled` as a system line, not
   a failure in the history. A write that fails says `Failed to write file: …` —
   shown, not swallowed.

Not ported: the `config.copyFullResponse` global as a *setting* (a session flag is
enough until someone asks for it across projects).

---

## Phase 29 — `/resume` as a picker

Today `/resume` reopens the newest session by mtime (`agent.resumeLatest`). After
a crash, or with two projects open, that is a guess.

### 29.1 The structural idea: `stat` for the row, the file for the label

The upstream picker is two-phase and the reason is written in the code: enriching
50 sessions reads up to 128 KB per file. Phase 1 builds a row from `stat` alone
(mtime, size, id — no parsing, so a corrupt file cannot make a session
disappear); phase 2 reads **head + tail** windows and fills in the title.

> "Extract stable metadata from the first line via string search. Works even when
> the first line is truncated (>64KB message)."

**String scanning, not JSON parsing**, because the first line may be cut in half.
And the title has an explicit fallback ladder:

```ts
extractLastJsonStringField(tail, 'lastPrompt')
  || extractFirstPromptFromChunk(head)
  || extractJsonStringFieldPrefix(head, 'content', 200)
  || ''
```

The **tail** entry wins because it is written at write time by the writer, who
knows what the user was doing. Two consequences, both cheap:

- the picker opens with **zero I/O per session** (today we inflate every JSONL to
  list it — which is why `/resume` is not instant),
- a `last_prompt` entry is a Phase 30 item and it makes every future listing
  better.

### 29.2 The highest-value line in the file

```ts
// Provide a fallback title for sessions where we couldn't extract the first
// prompt. Previously these sessions were silently dropped, making them
// inaccessible via /resume after crashes or large-context sessions.
if (!enriched.firstPrompt && !enriched.customTitle) enriched.firstPrompt = '(session)'
```

**A session you cannot read the head of must still be listed.** Our failure mode
is real: a first message with a 1 MB `@file` mention, or a truncated zjsonl line.
Today that session is a file on disk that `/resume` never mentions, and `/clean`
offers to delete it. `(session)` is the fix and it is one line.

### 29.3 The row

```
<relative time ago> · <git branch> · <size or "N messages"> · #<tag>
```
with the position in the header (`Resume (3 of 57)`) — the same "a picker that
lies about its size is worse than no picker" rule as the `@` popup's
`10 matches · +4 more`.

The title is a **total function** and the chain never returns empty, worst case
the truncated id:

```
agentName || customTitle || aiTitle || firstPrompt || sessionId[0..8]
```

Two details from `getLogDisplayTitle` that are bug reports:

- `firstPrompt` is skipped when it starts with `<tICK>` (an autonomous prompt
  does not become a session name),
- display-hostile tags are stripped, and because `stripDisplayTags` **returns the
  original when the result is empty**, the code calls the `_AllowEmpty` variant to
  detect a command-only prompt (`/clear`) and falls through to the next fallback
  instead of showing `/clear` as the name.

### 29.4 Interaction

| key | action |
|---|---|
| type anything | filter (there is no "insert mode"; a printable key means filter) |
| ↑ on the first row | jump into the filter |
| Ctrl+V | preview the focused session **in place**, lazily loaded |
| Ctrl+A / Ctrl+B | toggle all-projects / branch filter |
| Enter | resume |
| Esc | cancel — or **clear the filter** when filtering, and the footer says which |

The preview renders the conversation **with the same renderer as the live one**,
loaded at preview time and again at selection time — never a summary line. Our
`drawTest` helpers (`rowText`, `readCell`) and the paragraph/segment machinery
already exist; the preview is a `Model` with the messages appended.

### 29.5 Search, in three tiers, each with an honest degradation

1. **title substring** — instant.
2. **transcript fuzzy**, debounced, cropped at **both ends** (first 1000 + last
   1000 of >2000 messages) and built from **prose only**: no tool names, no
   thinking blocks, because they add noise to the ranking. Each hit shows a
   snippet that is a bounded window **inside that session** — the same bug
   `web_search` had, where a result with no snippet of its own got its
   neighbour's.
3. **semantic** — optional, and a **state, not a filter**: the footer shows
   "Searching…" where the shortcuts were, Esc cancels. We already have the
   primitive (`task`, effort `low`, depth 1, 24k) and only need the state machine.

Ranking, which is the part worth stealing whole:

```ts
if (Math.abs(timeDiff) > 60_000) return timeDiff;   // recency
return (a.score ?? 1) - (b.score ?? 1);             // relevance, as a tiebreak
```

**Relevance never outranks recency across sessions, only within a minute of it.**
zode's `/resume` throws the relevance dimension away entirely; upstream scopes it
to a window instead of discarding it.

### 29.6 Resuming: refuse with the exact command

Four steps, and the fourth is the point: resume is not "load the file", it is
**check that this file belongs to this directory**.

> "For same-repo worktrees, we can resume directly without requiring cd. For
> different projects, we generate the cd command."
> ```ts
> command = `cd ${quote([log.projectPath])} && zode --resume ${sessionId}`
> ```

with `quote()` being **shell quoting**, because a path with a space in it is a
command injection, and the command is put on the clipboard before it is printed:

```
This conversation is from a different directory.

To resume, run:
  cd "/home/…/other" && zode --resume a1b2c3d4

(Command copied to clipboard)
```

It is a **user** message, not an error: it is an instruction. For us this is the
worktree case — `/resume` from a worktree must either resume or say exactly what
to run elsewhere, and never silently load a session whose relative paths now
point at the wrong tree.

Also: `/resume <term>` **never opens a picker**. It resolves a UUID, then a file,
then an exact title, and an ambiguity is an error with the count (`Found 3
sessions matching foo. Use /resume to pick.`). And when the index says "not found",
**go read the file directly before telling the user it does not exist** — the
index filters sessions it could not enrich, and losing one to that is losing it
forever.

---

## Phase 30 — Names, forks, and a resume that restores

### 30.1 Two title keys, so precedence is structural

```
customTitle   ← /rename, never overwritten
aiTitle       ← generated, ephemeral, safe to regenerate
```

> "Distinct from CustomTitleMessage so that: user renames always win over AI
> titles in read preference; re-appendSessionMetadata never re-append AI titles
> (they're ephemeral/regeneratable — re-appending would clobber user renames on
> resume)."

Two different keys on disk means the reader checks a different field and the
precedence cannot be violated by a bug. A single `title` with a `source` flag is
the same idea implemented worse.

### 30.2 Derive now, upgrade later, guard the upgrade

At turn 1: a title derived from the first prompt, **synchronously, free**. Then
the AI title is requested in the background and patched when it arrives — but only
if three things still hold:

```ts
if (generated && gen === genSeq && lastBridgeSessionId === bridgeSessionId
    && !getCurrentSessionTitle(...)) patch(generated, ...)
```

**the generation counter is the point**: a cheap turn-1 request can resolve after
a richer turn-3 request and clobber it. And `!getCurrentSessionTitle()` is the
`/rename` race: the user renamed in between, and the generated title must not
overwrite it.

For us the upgrade request is a `task` subagent (effort `low`) over the **last
1000 characters** of the conversation — recent context wins, and the input is
bounded. It runs at turn 3, not turn 1, and it is free when the user already
named the session. Prompt shape worth copying nearly verbatim:

> "Good: `Fix login button on mobile` · Bad (too vague): `Code changes` · Bad (too
> long): `Investigate and fix the issue where…` · Bad (wrong case): `Fix Login
> Button On Mobile`"

3-7 words, sentence case, JSON-schema-constrained, `null` on any failure, and it
**never blocks**.

### 30.3 A running summary for the list

> "Periodic summary of what the agent is currently doing. Written every
> min(5 steps, 2 min) so the session list shows something more useful than the
> last user prompt (which is often 'ok go')."

One line, written at write time, no model call. In a three-hour session the first
prompt is hours stale and the row is useless; this is the cheapest possible fix
and it also makes the Phase 29 tail read (`lastPrompt`) mean the right thing.

### 30.4 `/branch`: fork is not `/new`

`/new` throws the thread away. A fork copies the JSONL, rewrites the session id,
stamps provenance and keeps the parent chain:

```ts
const forkedEntry = { ...entry, sessionId: forkSessionId, parentUuid,
                      isSidechain: false, forkedFrom: { sessionId: original, messageUuid: entry.uuid } }
```

Four details that are the whole design:

- **only main-thread entries** (`filter(e => isMessage(e) && !e.isSidechain)`),
- **`parentUuid` is rebuilt, not copied**, and a `progress` entry never becomes a
  parent,
- **side tables are carried over.** Upstream's comment is a scar:

  > "Without them in the fork JSONL, resume reconstructs state with an empty
  > replacements map → previously-replaced results are classified as FROZEN and
  > sent as full content (prompt cache miss + permanent overage)."

  Ours has the same hazard: a resume rewrites the history, so anything **derived**
  from it (the elision markers, the compaction summary, the plan) must be
  re-recorded, not assumed.
- **`mode: 0o600`** on the new file (the parent dir is `0o700`) — we already do
  this for sessions.

And it **names itself and tells you how back**:

> "Branched conversation \"foo\". You are now in the branch.\nTo resume the
> original: zode --resume <originalId>"

with `getUniqueForkName` producing `foo`, `foo (Branch)`, `foo (Branch 2)` by
collision check. `~40 lines` over `Session` and it turns `/new` from "lose the
thread" into "branch it".

### 30.5 What resume restores besides the messages

`restoreSessionStateFromLog` restores the id **and the project directory**
(`switchSession(sid, dirname(transcriptPath))`), the cost state, the custom title,
the tag, the agent definition — and the plan, by **scanning the transcript for
the last `todo` tool call**:

> "Scan the transcript for the last TodoWrite tool_use block and return its todos.
> Used to hydrate the todos on resume so the model's todo list survives session
> restarts without file persistence."

Free: the plan block above the input reappears on `--resume` with no new state
file and no new failure mode.

Plus **counters that only make sense across a session** (prompts asked,
permissions asked, ESCs pressed) — that is what turns `/bench` from a per-session
number into a lifetime one.

And one defensive habit to copy: write a cheap consistency marker in the
transcript (a turn checkpoint recording how many messages it expected) and compare
it on resume. Our JSONL is DEFLATE-compressed with no integrity marker; a
truncated resume is currently silent.

---

## Phase 31 — Commanding git: `/commit`, `/pr`, and `` !`cmd` ``

Upstream's `/commit` is the best-engineered 92 lines in this set, because it is
three independent layers, and **the difference between them is the design**.

### 31.1 Layer 1 — verified context inlined into the prompt

The prompt is built from shell invocations:

```
- Current git status: !`git status`
- Current git diff (staged and unstaged changes): !`git diff HEAD`
- Current branch: !`git branch --show-current`
- Recent commits: !`git log --oneline -10`
```

Two syntaxes (`` ```! … ``` `` blocks and `` !`cmd` `` inline), and three details
that are bug prevention, not features:

1. **Each command is permission-checked**, even though the user chose the command
   that ran it: `if (permissionResult.behavior !== 'allow') throw`.
2. **Substitution uses a function replacer**, not a string: `String.replace`
   interprets `$$`, `$&`, `` $` ``, `$'` in the replacement, and shell output is
   arbitrary user data (`$PATH`, `$$`, `$PSVersionTable`). We have the same
   hazard in the `!cmd` output path and in every `bufPrint`-into-a-`allocPrint`.
3. **Failure is loud and named**: `Shell command failed for pattern "git status": …`.
   Never a silent empty substitution — an empty `git status` that looks like a
   clean tree is the worst possible lie.

We already have `!cmd` **from the input**. Moving it to **inside a prompt** is
~30 lines and it gives every command a verified context block: `/review` becomes
`!git diff $(git merge-base HEAD main)...HEAD` for free, with the permission check
attached.

### 31.2 Layer 2 — the allowlist is a property of the command

```ts
// /commit
const ALLOWED_TOOLS = ['Bash(git add:*)', 'Bash(git status:*)', 'Bash(git commit:*)']
// /commit-push-pr — note what is NOT in the first list
'Bash(git checkout --branch:*)', 'Bash(git checkout -b:*)', 'Bash(git push:*)',
'Bash(gh pr create:*)', 'Bash(gh pr edit:*)', 'Bash(gh pr view:*)', 'Bash(gh pr merge:*)'
```

The same list is injected into `alwaysAllowRules.command` so the turn does not
prompt. **The asymmetry is the feature**: `gh pr merge` is allowed for
`/commit-push-pr` and not for `/commit`. Ours is a flat allowlist in
`permissions.json` with no per-command narrowing; `validRefName` already stops a
model string becoming a git **option**, and a per-command verb allowlist is the
same threat model at a different layer.

### 31.3 Layer 3 — the git safety protocol, verbatim

```
- NEVER update the git config
- NEVER skip hooks (--no-verify, --no-gpg-sign) unless explicitly requested
- CRITICAL: ALWAYS create NEW commits. NEVER use git commit --amend, unless explicitly requested
- Do not commit files that likely contain secrets (.env, credentials.json). Warn if asked to.
- If there are no changes to commit, do not create an empty commit
- Never use git commands with the -i flag (git rebase -i, git add -i) since they
  require interactive input which is not supported
```

Only the destructive ones are CRITICAL-classified — `--amend` is the one that
destroys work. Three of these map onto things this repo has already paid for:

- **no empty commit** → Phase 32's "is there anything to review" gate,
- **never `-i`** → an interactive command hangs a non-TTY harness forever; this
  is the same class as `tcsetattr` and `std.process.run` inside a worker, both of
  which cost an afternoon. `verify.zig` should classify `rebase -i` as
  **forbidden**, not merely slow,
- **never skip hooks** → zode must never pass `--no-verify` itself.

### 31.4 The message never touches argv

```
git commit -m "$(cat <<'EOF'
Commit message here.
EOF
)"
```

and the closing instruction, which is what makes it one round trip:

> "Stage and create the commit using a single message. Do not use any other tools
> or do anything else. Do not send any other text or messages besides these tool
> calls."

Our `git_commit` already writes the message to a **file** and names it with `-F`
for exactly this reason; the heredoc is the upstream spelling of the same insight,
and the "single message, no other text" clause is what turns a three-iteration
commit into a one-iteration commit.

The style rules themselves: **look at the recent commits to follow this repo's
style**, name the nature of the change (add / update / fix / refactor / test /
docs), and write 1-2 sentences about the **why**.

### 31.5 What `/pr` adds

- **branch name with a user prefix** when on the default branch
  (`username/feature-name`),
- **diff against the merge base, not HEAD**, and the instruction is explicit that
  it is *all* the commits in the PR, not the latest one,
- **PR body template**: `## Summary` (1-3 bullets) + `## Test plan` (checklist)
  + a managed `## Changelog` block between `<!-- CHANGELOG:START -->` markers,
- **title under 70 characters**,
- **idempotent**: `gh pr view --json number 2>/dev/null || true` is *itself* an
  inlined command — including the `|| true`, so "no PR yet" is not an error —
  and then `gh pr edit` instead of a second PR,
- **`Return the PR URL when you're done`** so the user sees it.

One structural bit worth porting beyond git: **`contentLength` is a getter, not a
field**, when the prompt is dynamic:

```ts
get contentLength() { return getPromptContent('main').length }
```

Because it feeds token estimation. A command whose context block depends on the
repo has **no static length**, and reporting a wrong one is how `/context` loses
the credibility `ctxTokens(real, estimate)` just bought.

---

## Phase 32 — Verify or refute: the three-way count

### 32.1 A verifier that only confirms is a rubber stamp

The progress wire `RemoteAgentTask.tsx:627` is the whole finding:

```ts
stage?: 'finding' | 'verifying' | 'synthesizing';
bugs_found?: number;  bugs_verified?: number;  bugs_refuted?: number;  // ← the third one
```

Three-way, and the refuted count is **displayed**. The formatting rules are as
valuable as the field:

```
finding      → "finding"
verifying    → "12 found · 5 verified · 2 refuted"
synthesizing → "5 verified · 2 refuted · deduping"
completed    → "ultrareview ready · shift+↓ to view"
```

- **word labels, never `✓`/`✗`** (no provenance icons),
- **hide the refuted count when it is 0** — "a stable prefix of the line that
  doesn't change teaches the eye to ignore the line",
- counts animate `+1` toward the target (exactly our `tps_win_ns` rolling window),
- and the honesty rule when there is no data at all:

  > "Don't claim '0 findings' when completed; we just don't know." → `'setting
  up'` / `'done'`

  This is `proofWord(.nothing) → "not checked"` applied to a progress pill, and
  the same failure: a default-constructed struct claiming a number.

For us it is one field in a `verify`-role subagent's `Report` (Phase 26's role
table already has `verify`: *"try to break the change"*) and a permanent home in
the activity strip. The prompt behind the finders is **not** in this tree, so what
gets written is the protocol and the three-way verdict, and the prompt is ours
from our own `review.zig` checklist.

### 32.2 `advisor`: a stronger model, called at the checkpoint, with no arguments

`utils/advisor.ts` is one LLM call: a read-only `advisor` tool that takes **no
parameters** and gets the whole conversation forwarded automatically. The prompt
is about **when**, not what:

> "Call advisor BEFORE substantive work — before writing code, before committing
> to an interpretation, before building on an assumption. Orientation is not
> substantive work. Writing, editing, and declaring an answer are."

> "When you believe the task is complete. BEFORE this call, make your deliverable
> durable: write the file, stage the change, save the result. The advisor call
> takes time; if the session ends during it, a durable result persists and an
> unwritten one doesn't."

and the anti-sycophancy calibration:

> "Give the advice serious weight. If you follow a step and it fails empirically,
> or you have primary-source evidence that contradicts a specific claim, adapt. **A
> passing self-test is not evidence the advice is wrong — it's evidence your test
> doesn't check what the advice is checking.**"

> "If you've already retrieved data pointing one way and the advisor points
> another: don't silently switch. Surface the conflict in one more call."

The second quote is a direct fix for a real zode failure (a 60-iteration turn
whose only output lived in a throwaway arena), and the third is nearly free: our
`/goal` **already** has a soft checkpoint where the model issues a verdict, and
`verdictCredible` already refuses a `blocked` with zero tools run. An advisor call
is the same gate seen from the other side.

Implementation: a `task`-shaped subagent (effort `low`, read-only) that receives
the serialized session. No provider beta, no new transport.

### 32.3 Gate before you spend

Four cheap local checks, each with a user-facing message, **before** anything
expensive starts:

> "Could not find merge-base with main. Make sure you're in a git repo with a main
> branch."
> "No changes against the main fork point. Make some commits or stage files
> first."
> "Repo is too large."
> "// Bail early on empty diffs instead of launching a container that will just
> echo 'no changes'."

The first is a hole in `/goal` and in the review gate today: a turn that spends
twelve iterations in a repo with nothing to look at is a turn that ends with a
summary. `git merge-base` + `git diff --shortstat` are two subprocesses and they
answer "is there anything to review?" before the first token of the review.

And the inverse default, which is the correct bias and worth copying as a rule:

```ts
if (!quota) return { kind: 'proceed' }        // "No quota info — let it through"
if (!utilization) return { kind: 'proceed' }   // "Utilization fetch failed"
```

**An unreadable counter must not become a wall.** The gate's job is to inform, not
to refuse; a hard stop is the failure mode, a spend is the failure you can justify.

### 32.4 One rule for anything that finishes in the background

`STABLE_IDLE_POLLS = 5`:

> "remote sessions briefly flip to 'idle' between every tool turn, so a single idle
> observation means nothing. Require 5 consecutive idle polls with no log growth."

Combined with an **explicit completion tag**, because the alternative is a
heuristic:

> "Hook-stdout concat fallback: a single echo should land in one event, but large
> JSON payloads can flush across two if the pipe buffer fills mid-write. Per-message
> scan above misses a tag split across events."

Ours has the same shape of risk (`toolRunEnd`, the 250 ms idle tick, and a
`pushPending` that can flush across a tick) and the same two-part answer: N
consecutive quiet intervals **and** an explicit end marker.

---

## Tool upgrades (independent of the phases above)

Independent of the phases above, four small upgrades to existing tools:

1. **`grep`** gains context lines (`-A/-B/-C`), a `glob`/`type` filter, an output
   mode (`content` / `files_with_matches` / `count`), and a `head_limit`. Today it
   is "pattern + subdir" and the model compensates with more calls.
2. **`bash`** gains a `description` field: one line for the timeline ("running the
   test suite"), so the user reads what a command is FOR and not only what it is.
3. **`read`** gains PDF page ranges (the image path already exists), so a spec
   handed to the agent is readable without shelling out to a converter.
4. **`glob`** gains a `subdir` and a `limit`, so "the 20 newest `.zig` under
   `src/`" is one call — **shipped 2026-10-16**, together with the
   `sort: newest|oldest|name` that makes "newest" true (walk order is not it).

Each is one row in the registry (Phase 0) and one pure test on the argument
parsing; none changes a permission.

---

## Constants and thresholds (a data table)

| Name | Value | Used by |
|---|---|---|
| Skill listing budget | 1% of `ZODE_CONTEXT_LIMIT` | Phase 2 |
| Skill per-entry cap | 250 chars | Phase 2 |
| `default_max_result_chars` | 50 000 | Phase 0/3 |
| `max_result_bytes` | 400 000 | Phase 3 |
| `max_results_per_message_chars` | 200 000 | Phase 3 |
| `summary_max_len` | 50 | Phase 3 |
| Per-tool `max_result_chars` | 100 000 (read = unbounded) | Phase 0/3 |
| Compaction budget | 80% of `ZODE_CONTEXT_LIMIT` | existing |
| Batch step kinds | fixed set (map/filter/select/count/write) | Phase 16 |
| Ticks while parked | off by default | Phase 19 |
| Recurring schedule max age | 30 days | Phase 19 |
| Web fetch cache TTL | per session | Phase 24 |
| Word-diff change threshold | 0.40 (above it, no word ranges) | Phase 27 |
| Diff gutter width | digits of the hunk's max line number, per hunk | Phase 27 |
| `/copy` lookback | 20 turns | Phase 28 |
| `/copy` block label width | 60 columns (display width, not bytes) | Phase 28 |
| Resume list enrich window | first 50 sessions, 128 KB head+tail each | Phase 29 |
| Resume search crop | first 1000 + last 1000 messages, prose only | Phase 29 |
| Resume relevance window | 60 s (relevance is a tiebreak inside it) | Phase 29 |
| AI title trigger | turn 3 (turn 1 is the derived placeholder) | Phase 30 |
| Running summary cadence | every 5 steps or 2 min, whichever first | Phase 30 |
| Fork name collisions | `X`, `X (Branch)`, `X (Branch 2)` | Phase 30 |
| Idle before "done" | 5 consecutive quiet intervals with no growth | Phase 32 |
| Review precondition | `merge-base` + `--shortstat`, fail-open | Phase 32 |

## Order and dependencies

| Phase | Depends on | Why here |
|---|---|---|
| 0 | — | every later phase reads the registry |
| 1 | 0 (optional) | the requested start; reuses the skill system |
| 2 | 1 | listing and fork build on the new frontmatter |
| 3 | 0 | the cap layer is where storage plugs in |
| 4 | — | independent |
| 5 | 6 (for `if`) | hooks reuse the rule syntax |
| 6 | — | independent |
| 7 | 3 | microcompaction needs the stored-result marker |
| 8 | — | independent |
| 9 | — | independent |
| 10 | 3 | task output reuses storage |
| 11 | — | independent |
| 12 | 0 | tool search needs the registry |
| 13 | — | optional |
| 14 | 12 (transport) | the language-server client reuses the stdio JSON-RPC transport |
| 15 | — | independent; Phase 20 consumes it |
| 16 | 0 | a batch is a registry of step kinds |
| 17 | — | independent |
| 18 | — | independent |
| 19 | — | independent |
| 20 | 15 | teammates coordinate through the task graph |
| 21 | — | independent |
| 22 | — | independent |
| 23 | — | independent |
| 24 | — | independent |
| 25 | 6 | reuses the rule syntax and the read-only table |
| 26 | 9 | roles are a built-in set of the on-disk definitions |
| 27 | — | independent; touches `markdown`, `highlight`, `theme` and the painter |
| 28 | — | independent; reuses the picker and `termseq` |
| 29 | 30 | a row's title is Phase 30's key; the tail entry is written at write time |
| 30 | — | independent; writes what 29 reads |
| 31 | 0 | the per-command allowlist is a registry property |
| 32 | 26 | the `advisor` is a `task` subagent; the counts ride on the roles |

**Minimum next delivery**: Phase 27 (the diff) + Phase 28 (`/copy`).

**Phase 27 is the recommendation over Phase 0 + Phase 1**, and the reason is in
this section: `native-ts/color-diff/index.ts` is 999 complete lines with every
constant in it, the algorithm is six steps of pure logic, and the surface it
improves is the one the user reads on **every single tool call**. Phase 0 is a
refactor that pays on the twenty-first change; Phase 27 pays on the first.

**Phase 29 is the most *needed* and the least *interesting*** — `/resume` resumes
the newest session by mtime and a session whose head cannot be parsed is
invisible and deletable. It is last because it is the least fun, which is exactly
the profile of the thing that has been quietly wrong.

The registry track starts here: that is a registry that makes the
tree easier to extend, and bundled skills with the new frontmatter — the two that
move the harness to the next level with the least risk.

**The tool track (14–26)** is a second, independent axis: it grows what the model
can DO rather than how the turn is shaped. Ordered by value per unit of risk:

| Order | Phase | Why this rank |
|---|---|---|
| 1 | 15 — task graph | pure, durable, and Phase 20 depends on it |
| 2 | 16 — batch execution | the biggest token saving after subagents; a fixed surface |
| 3 | 14 — code intelligence | the compiler already knows; `refs` guesses |
| 4 | 25 — bash safety | makes every `bash` dialog honest |
| 5 | 26 — subagent roles | one prompt per role, reuses the existing runner |
| 6 | 17, 21, 22, 23, 24 | each is self-contained and low-risk |
| 7 | 18, 19, 20 | session-level; 20 waits on 15 |

## How it is verified

- **Pure logic** (`src/lib/`): `zig build test`, no TUI, no network.
- **TUI**: `drawTest` + `rowText` + `readCell`, and always a real frame in a pty
  (`tools/pty_smoke.py`) — libvaxis redraws differentially and a homemade emulator
  loses half of it. Always drain the pty.
- **Wiring**: a `*_smoke.py` per command that a unit test cannot prove fires
  (a command can be perfect and still do nothing when typed).
- **Reports are stated at the precision earned**: a typecheck is "typechecked",
  not "verified"; a run that could not reach the model reports the gap instead of
  calling it a pass.
- The two language checks (test names and code comments in English) come out
  empty.

## What is deliberately NOT done

- No plugin marketplace, telemetry, or accounts — none of it is core.
- Nothing enters the prompt that is not used: the biggest mistake a harness of
  this class makes is carrying instructions the model has already learned to skip.
- No abstraction without a second caller. The registry arrives because four lists
  disagree today, not because structure is nice.
