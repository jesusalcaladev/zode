# Harness machinery: zode vs. Claude Code

A verified gap analysis of the **machinery** — the parts of a harness that are not
the model: permissions, hooks, background tasks, context/compaction, memory,
subagents/teams, skills, tool results, cost, sandbox.

Upstream is the vendored copy of Claude Code's source in `code-base/` (TypeScript).
Ours is `src/` (Zig 0.16, no C deps).

Every claim below is cited with `path:line`. A mechanism described in one paragraph
of upstream prose is not treated as a mechanism until its implementation was read.

---

## 1. Our machinery today

The harness is one loop (`src/agent.zig:3763` `chatWorker` → `runOneTurn` at
`src/agent.zig:5071`) driving a tool dispatcher (`src/tools/dispatch.zig:208`
`execute`) over a **single registry table** (`src/tools/registry.zig:82` `defs`,
37 rows) from which the schema, the permission table, the read-only schema and the
parallel-safety table are all derived (`src/tools/registry.zig:453` `needsPermission`,
`:459` `isParallelSafe`, `:600` `blob`).

| Subsystem | Where it lives | Shape |
|---|---|---|
| Permission model | `src/agent.zig:789` `PermMode{default,accept_edits,read_only,bypass}`; `src/agent.zig:1836` `permAutoAllowed`; `src/agent.zig:1845` `bashPatternAllowed`; `src/agent.zig:1883` `allowAlwaysFor`; `src/agent.zig:1928` `loadAllowlist` / `:1976` `saveAllowlist` (`~/.config/zode/permissions.json`, a flat `{tools:[…],bash:[…]}`) | 4 modes + a flat allowlist (≤8 tool names, ≤16 bash prefixes). **No rule language, no `deny`, no `ask`.** |
| Permission dialog | `src/tui.zig:1867` `Model.requestPermission` (worker blocks on its own lock + `nanosleep` backoff, epoch to wake); `src/tui.zig:1897` `answerPermission` | Modal, single yes/no/always/deny |
| Tool registry | `src/tools/registry.zig:82` | One table; `read_only`/`parallel_safe`/`destructive`/`max_result_chars` per row; per-tool schema in `src/tools/prompts/*.zig` |
| Batch permission set | `src/tools/registry.zig:494` `callPermissionTools` | Union of the tools a call is a call to (`batch` is the only tool whose set is computed) |
| Agent loop / exit gate | `src/agent.zig:3763` loop; `src/lib/exitgate.zig:190` `Gate.decide`; `src/autochk.zig:587` `AutoCheck.exitGate`; called at `src/agent.zig:3814` | The turn may not end on red code or on an unread diff. **Upstream has no equivalent.** |
| Turn goal / verdict | `src/lib/goal.zig:107` `parseVerdict`, `:295` `verdictCredible` (a `blocked` needs ≥1 tool run) | Machine-checkable "met"/"blocked" |
| Repetition guard | `src/lib/repeats.zig:27` `repeat_limit = 3`, `:57` `isRepeatExempt` (`read`/`bash_output` exempt) | Hash of the call, not the args |
| Review checklist | `src/lib/review.zig:35` `items` (8 entries), `:83` `checklist` | The model must read its own diff back |
| Compaction | `src/compaction.zig:201` `elideTier` (tier 1, free), `:323` `summaryPrompt` (tier 2, one LLM call); budget = 80% of the limit (`:171` `budgetTokens`); modes `off|elide|full` (`:134`) | 2 tiers. Tier 1 replaces old tool results with a marker; tier 2 replaces them with a summary. Cadence: `summary_gap=6`, `summary_max=3` (`src/agent.zig:1520-1521`) |
| Background jobs | `src/bgproc.zig:77` `Job`, `:156` `slots` (fixed array of 8), `src/tools/bg.zig:28` `toolBashOutput` (incremental), `:53` `toolBashKill` | One registry, one reader thread per job, output in RAM (64 KB cap, `src/bgproc.zig:48`). **No notification to the model when a job finishes.** |
| Subagents | `src/lib/subagent.zig:44` `tool_names` (read-only, 7 tools), `:66` `max_iterations=8`, `:77` `budget_tokens=24_000`, `:111` `capResult`; loop at `src/agent.zig:6580` `runSubagent` | Disposable window, effort always `low`, depth 1. Parallelism capped by `ZODE_TASK_PARALLEL` |
| `ask` | `src/lib/ask.zig:200` `parse`, `:119` `decide` (YOLO: take the recommendation, or leave it open) | One question, ≤5 options, 5-minute timeout (`src/tui.zig:1023`) |
| Plan | `src/lib/plan.zig:33` `max_items=20`, `:358` `parseItems` | Visible todo list + approval gate (`src/agent.zig:901` `PlanGate`) |
| Task graph | `src/lib/taskstore.zig:81` `Task`, `:123` `Store`; `src/tools/tasks.zig` | `blocks`/`blocked_by` derived, never typed twice |
| Skills | `src/lib/skills.zig:83` `Meta`, `:103` `splitFrontmatter`, `:240` `systemPromptSection`; `src/lib/skillstore.zig:28` `Loader`; bundled in `src/skills/*.md` | Name+description in the prompt, body loaded on demand via the `skill` tool |
| Output styles | `src/lib/outputstyles.zig:83` `Meta`, `src/lib/outputstyle_store.zig:57` `scan`; bundled `src/output_styles/*.md` | Selected with `/style`, injected at the END of the prompt (`src/agent.zig:551-568`) |
| Result caps | `src/lib/resultcap.zig:39` `capResult`, `:78` `capAggregate`; per-tool caps from the registry | Cut with a notice INSIDE the budget; UTF-8 safe |
| Verification / typecheck | `src/lib/verify.zig:174` `classify` (slow vs quick), `src/lib/typecheck.zig:135` `planFor`, `:89` `proofWord` | Slow verifications auto-background; the typecheck gate runs the project's own compiler |
| Cost / usage | `src/cache_stats.zig`, `src/lib/bench.zig:22` `Stats` | **Tokens and hit-rate only. No USD, no per-model cost.** |
| Hooks | — | **None.** |
| MCP | — | **None** (there is a JSON-RPC client in `src/lsp/`, but it is LSP-only) |
| Sandbox | — | **None** |
| Memory store | — | **None** (only the project's own `AGENTS.md`) |
| Teams | — | **None** (the task graph exists; there are no teammates) |

---

## 2. Mechanism-by-mechanism comparison

### 2.1 Permissions

**Upstream.** The rule model is a *language*, not a list. A rule is
`ToolName(content)` — `code-base/utils/permissions/permissionRuleParser.ts:93`
`permissionRuleValueFromString` splits on the first unescaped `(` (`:158`
`findFirstUnescapedChar`) and unescapes `\(`, `\)`, `\\` (`:74`
`unescapeRuleContent`). Legacy tool names are aliased so a renamed tool does not
orphan its rules (`permissionRuleParser.ts:21` `LEGACY_TOOL_NAME_ALIASES`).

Behaviours are `allow | deny | ask`
(`code-base/utils/permissions/PermissionRule.ts:25` `permissionBehaviorSchema`).
Rules are loaded **per source** — `userSettings`, `projectSettings`,
`localSettings`, `flagSettings`, `policySettings`
(`code-base/utils/settings/constants.ts:7` `SETTING_SOURCES`), and each source keeps
its own allow/deny/ask triple
(`code-base/utils/permissions/permissionsLoader.ts:91` `settingsJsonToRules`,
`:140` `getPermissionRulesForSource`). A managed policy can lock the whole thing
down (`permissionsLoader.ts:31` `shouldAllowManagedPermissionRulesOnly`).

The evaluation order is the substance of the feature
(`code-base/utils/permissions/permissions.ts:1158` `hasPermissionsToUseToolInner`):

- **1a** whole-tool deny rule (`:1171`)
- **1b** whole-tool ask rule (`:1184`) — *except* when bash is sandboxed and
  auto-allow is on (`:1189-1194`)
- **1c** the tool's own `checkPermissions` (`:1216`, `Tool.ts:500`)
- **1d** the tool denied (`:1226`)
- **1e** `requiresUserInteraction()` survives bypass mode (`:1231`, `Tool.ts:435`)
- **1f** a content-specific *ask* rule beats `bypassPermissions` (`:1244`)
- **1g** safety checks (`.git/`, `.claude/`, `.vscode/`, shell configs) are
  bypass-immune (`:1255`, `code-base/utils/permissions/filesystem.ts:620`
  `checkPathSafetyForAutoEdit`)

A separate `checkRuleBasedPermissions` (`permissions.ts:1071`) is the subset that
survives bypass mode, so a hook's "allow" cannot override a `deny`
(`code-base/services/tools/toolHooks.ts:373` `ruleCheck`).

Shell rules have three shapes — exact, legacy prefix (`npm:*`), and wildcard with
`\*`/`\\` escapes (`code-base/utils/permissions/shellRuleMatching.ts:159`
`parsePermissionRule`, `:90` `matchWildcardPattern`). The wildcard matcher is
carefully specified: a trailing ` *` with exactly one unescaped star matches both
`git add` and bare `git` (`shellRuleMatching.ts:142-145`).

Deny rules are *enforced against the model's own tool list*: a denied tool is
removed from the schema, not merely blocked at call time
(`code-base/tools.ts:262` `filterToolsByDenyRules`).

There is also a **shadowed-rule detector** (`code-base/utils/permissions/shadowedRuleDetection.ts:14`
`ShadowType`) that tells the user their `allow` rule can never fire because a
`deny` shadows it, and a **dangerous-rule stripper**
(`code-base/utils/permissions/dangerousPatterns.ts:44` `DANGEROUS_BASH_PATTERNS` —
`python`, `node`, `bash`, `curl`, …) used when entering auto mode
(`code-base/utils/permissions/permissionSetup.ts:510`
`stripDangerousPermissionsForAutoMode`).

**Ours.** A permission decision is `read_only` on a registry row
(`src/tools/registry.zig:453` `needsPermission` = `!read_only`) plus a flat
allowlist of tool names and bash prefixes
(`src/agent.zig:1928` `loadAllowlist` reads `permissions.json`, whose two shapes
are `{tools:[…],bash:[…]}`). The bash matcher is prefix-at-a-token-boundary plus
a refusal to accept a chained remainder
(`src/agent.zig:1845` `bashPatternAllowed`: the remainder may not contain
`;|&<>\`$\n`, because `git status && rm -rf /` is a different command). The
allowlist is per-session and persisted; the "always allow" key for `bash` saves
the *command*, not the tool (`src/agent.zig:1883` `allowAlwaysFor`), which is the
right instinct and matches upstream's prefix-suggestion idea
(`code-base/utils/permissions/shellRuleMatching.ts:211` `suggestionForPrefix`).

**Delta.**

1. **No `deny` and no `ask` behaviours.** We can allow or ask; we cannot deny. A
   rule that says "never run `rm`" is inexpressible, and the "always allow" list is
   the only persistent decision.
2. **No rule syntax.** `Tool(pattern)` does not exist; the allowlist is a set of
   tool *names* plus bash *prefixes*. `Read(*.ts)`, `Bash(git *)` and
   `Edit(src/**)` cannot be expressed.
3. **No precedence model and no sources.** One flat file, one list. The upstream
   `local > project > user > policy` ordering has no analogue, so a project
   cannot tighten what a user globally allowed.
4. **No path-scoped rules at all.** Upstream validates the *path* of a read/edit
   against the working directory and against deny rules
   (`code-base/utils/permissions/pathValidation.ts:141` `isPathAllowed`), and
   blocks `.git/`, `.claude/`, `.vscode/`, `.idea/` and the user's shell configs
   (`code-base/utils/permissions/filesystem.ts:74` `DANGEROUS_DIRECTORIES`).
   Ours has **no path validation on `write`/`edit`/`rename`**: `src/tools/write.zig:61`
   writes whatever path it is given relative to the cwd, and `src/tools/write.zig:46`
   does the same for the multi-file form. A model that writes `.git/config` gets
   the ordinary permission dialog and, on "always allow", permission forever.
5. **No dangerous-rule stripper.** An allowlist entry `bash` (the tool name) is
   exactly the upstream `Bash(python:*)` hazard.
6. **No shadowed-rule detection** — and with a flat list there is nothing to shadow.

**Effort.** M for the rule language + precedence + `deny`/`ask`; M for path
validation (needs a working-dir resolver and a dangerous-path table); S for
dangerous-rule stripping and shadow detection.

**Risk.** Medium. A rule language is a *security surface*, not a feature: `deny`
rules and path rules make the harness safer, but a parser that mis-reads
`Bash(rm *)` as `Bash(rm)` is a hole. The upstream parser is 198 lines and its
escape rules are subtle (`permissionRuleParser.ts:55-79`).

**TASKS phase.** Phase 6 (`TASKS.md:140`) covers "rule model with sources and
precedence" and "once-off suggestions" and "bash read-only classification table"
and "optional sandbox". It does **not** mention `deny`, path rules, dangerous-path
protection, or the stripper/shadow-detector.

---

### 2.2 Hooks

**Upstream.** 27 event names (`code-base/entrypoints/sdk/coreTypes.ts:25-53`
`HOOK_EVENTS`), covering the tool lifecycle (`PreToolUse`, `PostToolUse`,
`PostToolUseFailure`), the turn lifecycle (`UserPromptSubmit`, `Stop`,
`StopFailure`, `SessionStart`, `SessionEnd`), the compaction lifecycle
(`PreCompact`, `PostCompact`), the permission lifecycle (`PermissionRequest`,
`PermissionDenied`), the subagent/team lifecycle (`SubagentStart`,
`SubagentStop`, `TeammateIdle`, `TaskCreated`, `TaskCompleted`), and the
environment (`CwdChanged`, `FileChanged`, `ConfigChange`, `WorktreeCreate`,
`WorktreeRemove`, `InstructionsLoaded`, `Setup`, `Notification`, `Elicitation`).

Four hook *types*: `command` (shell), `prompt` (an LLM evaluates a prompt),
`agent` (an LLM runs a full query), `http` (POST JSON to a URL)
(`code-base/schemas/hooks.ts:32` `BashCommandHookSchema`, `:67` `PromptHookSchema`,
`:97` `HttpHookSchema`).

The payload is a fixed JSON document on stdin
(`code-base/utils/hooks.ts:301` `createBaseHookInput`: `session_id`,
`transcript_path`, `cwd`, `permission_mode`, `agent_id`, `agent_type`).
The `if` field uses **permission-rule syntax** to filter which calls fire
(`code-base/schemas/hooks.ts:19-27` `IfConditionSchema`, filtered at
`code-base/utils/hooks.ts:1819-1821`), so `if: "Bash(git *)"` reuses the rule
language.

The output contract is richer than "exit code":
`code-base/types/hooks.ts:70-165` defines per-event `hookSpecificOutput`, including
`permissionDecision` (`allow|deny|ask`), `updatedInput` (a hook can *rewrite the
tool's arguments*), `additionalContext` (text injected into the model's context),
`updatedMCPToolOutput`, `watchPaths`, and a `decision: approve|block` + `reason`.
Exit code **2** is the blocking signal (`code-base/utils/hooks.ts:2648`,
`:3334` `blocked = result.status === 2 || jsonBlocked`); any other non-zero is a
non-critical error shown to the user only.

A hook's *allow* does not bypass a `deny` rule
(`code-base/services/tools/toolHooks.ts:373-405`), and a hook's *deny* is absolute
(`toolHooks.ts:408`).

`PermissionRequest` is the headless path: a headless agent has no dialog, so
`code-base/utils/permissions/permissions.ts:400`
`runPermissionRequestHooksForHeadlessAgent` lets a hook decide, and only
auto-denies if no hook answered.

**Ours.** **Nothing.** `grep -rn "PreToolUse|PostToolUse|hooks.json" src/` returns
nothing. The closest thing is the *automatic* typecheck, which is a built-in
behaviour with no user-extensible surface (`src/autochk.zig:355` `maybeStart`).

**Delta.** All of it. The minimum useful subset for zode is: `PreToolUse`
(block or annotate a call), `PostToolUse` (feed a result back), `Stop` (refuse the
end of a turn — this is upstream's *hook-based* version of our exit gate) and
`UserPromptSubmit`. The richer parts (`updatedInput`, `additionalContext`,
`PermissionRequest`) are worth stealing because they turn the hook from a
side-channel into a participant in the loop.

**Effort.** M for four events with command hooks only (spawn a process, feed it
JSON, read stdout/exit code, map exit 2 to a block). L for the full output
contract (`updatedInput` rewrites the call, `additionalContext` enters the
context).

**Risk.** Medium-high, and it is a *security* risk, not a complexity one: a hook
runs an arbitrary command with the user's privileges. Upstream's mitigations are
worth copying verbatim — workspace-trust gating for every hook type
(`code-base/utils/hooks.ts:286` `shouldSkipHookDueToTrust`), an SSRF guard for
HTTP hooks (`code-base/utils/hooks/ssrfGuard.ts`), a URL allowlist for HTTP hooks
(`code-base/utils/hooks/execHttpHook.ts:49` `getHttpHookPolicy`), and a
10-minute execution timeout (`code-base/utils/hooks.ts:166`).

**TASKS phase.** Phase 5 (`TASKS.md:126`) covers exactly four events
(`PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `Stop`), a `.zode/hooks.json`
config, the `if` field using Phase 6's rule syntax, `timeout_ms` and `once`. It
does **not** cover the `updatedInput`/`additionalContext` output contract, the
`PermissionRequest` headless path, the workspace-trust gate, or non-command hook
types. **Phase 5 is a reasonable v1; the gap is the output contract.**

---

### 2.3 Background tasks

**Upstream.** A background task is a first-class object with a **typed** lifecycle:
`code-base/Task.ts:6` `TaskType` (`local_bash | local_agent | remote_agent |
in_process_teammate | local_workflow | monitor_mcp | dream`), `Task.ts:15`
`TaskStatus` (`pending|running|completed|failed|killed`), `Task.ts:27`
`isTerminalTaskStatus`. The state carries an output file path and a read offset
(`Task.ts:45-57` `TaskStateBase`: `outputFile`, `outputOffset`, `notified`).

Output goes to a **file** per task
(`code-base/utils/task/diskOutput.ts:72` `getTaskOutputPath`, opened with
`O_NOFOLLOW` at `diskOutput.ts:21` so a symlink in the tasks directory cannot
redirect the write). The `TaskOutput` tool is explicitly **deprecated** in favour
of "Read the task's output file path"
(`code-base/tools/TaskOutputTool/TaskOutputTool.tsx:173`).

The key mechanism we do not have: **the model is told when a task finishes.** A
completion enqueues a `<task-notification>` message
(`code-base/tasks/LocalShellTask/LocalShellTask.tsx:160-171`), with a
`notified` flag on the task state so the notification fires exactly once
(`LocalShellTask.tsx:110-119`) and a `TaskStop` does not double-notify. The
notification carries the task id, the tool-use id, the **output file path**, the
status and a one-line summary. The model is told to *read the file*, not to
poll. Background commands that finish are also collapsed into a single summary
message (`code-base/utils/collapseBackgroundBashNotifications.ts:71`).

Upstream also blocks a foreground `sleep` in the Bash tool with a message
telling the model to use `run_in_background`
(`code-base/tools/BashTool/BashTool.tsx:524-536` `validateInput`).

**Ours.** `src/bgproc.zig:156` `slots` — a fixed array of 8 `Job`s
(`src/bgproc.zig:35` `max_jobs = 8`), each with its own mutex and buffer, one
reader thread per job (`src/bgproc.zig:67` `ReaderCtx`). Output is **in RAM**
(64 KB cap, `src/bgproc.zig:48` `max_output`) with a truncation notice
(`src/bgproc.zig:51`). `bash_output` is incremental from a cursor
(`src/bgproc.zig:308-330`, `src/tools/bg.zig:28`) and says
`[job N] still running, nothing new yet` rather than erroring.

The good parts, honestly: the job id is a **counter, not a pointer**
(`src/bgproc.zig:83`), the reader thread owns its own copy of the `Child`
(`src/bgproc.zig:74`), the registry owns the allocator
(`src/bgproc.zig:158-180` — the fix for a real crash), and ESC kills the process
group (`src/bgproc.zig` `killTree`, `.pgid`).

**Delta.**

1. **No notification to the model.** This is the big one and it is already on the
   board (Phase 10, `TASKS.md:188`). Today the model must poll; upstream tells it.
2. **No output file.** Ours keeps output in RAM and hands it back through
   `bash_output`; upstream writes a file and tells the model to `Read` it. The
   file version scales past 64 KB and it is what makes the notification work.
3. **No typed lifecycle / no `notified` flag.** Ours has `State{running,finished,
   killed,free}` (`src/bgproc.zig:54`) but nothing equivalent to "fire the
   notification exactly once".
4. **No "task id → file path" mapping**, so a model cannot be told where the
   output went.
5. **No blocking of foreground sleeps.** Upstream refuses a foreground `sleep` and
   redirects to the background. Ours has a `sleep` tool with its own semantics.

**Effort.** S for the notification (a queue + a message injected into the next
turn); M for the output file (the `O_NOFOLLOW` open, the offset read, the
session-scoped directory); S for the `notified` flag.

**Risk.** Medium. Injecting a message into a running turn is a re-entrancy
problem: the turn may be mid-flight, may be in a permission dialog, or may be
about to end. Upstream solves it with a notification *queue*
(`code-base/utils/messageQueueManager.ts:142` `enqueuePendingNotification`) and
delivers it between turns.

**TASKS phase.** Phase 10 (`TASKS.md:183`) covers the registry unification, the
file output, incremental polling and the notification. **Well covered.**

---

### 2.4 Compaction and context management

**Upstream.** Three mechanisms, not one.

1. **Microcompaction** (`code-base/services/compact/microCompact.ts:253`
   `microcompactMessages`) clears the *content* of old tool results while keeping
   the tool_use blocks, for a fixed set of tools
   (`microCompact.ts:41` `COMPACTABLE_TOOLS`: read, shell, grep, glob, web_search,
   web_fetch, edit, write). It has a **time-based trigger**
   (`microCompact.ts:422` `evaluateTimeBasedTrigger`,
   `code-base/services/compact/timeBasedMCConfig.ts:30`): when more than 60 minutes
   have passed since the last assistant message the server-side prompt cache has
   expired anyway, so clearing old tool results *before* the request shrinks what
   gets rewritten for free. There is also a cache-editing variant
   (`microCompact.ts:305` `cachedMicrocompactPath`) that uses Anthropic's
   `cache_edits` API to delete tool results **without invalidating the cached
   prefix** — that is a provider feature, not a portable mechanism.

2. **Auto-compaction** (`code-base/services/compact/autoCompact.ts:241`
   `autoCompactIfNeeded`) summarizes the conversation when the token count crosses
   `context_window - 13_000` (`autoCompact.ts:62` `AUTOCOMPACT_BUFFER_TOKENS`),
   with warning/error thresholds 20 000 below that (`autoCompact.ts:63-64`) and a
   **circuit breaker**: after 3 consecutive failures it stops trying
   (`autoCompact.ts:70` `MAX_CONSECUTIVE_AUTOCOMPACT_FAILURES`, with the comment
   "1,279 sessions had 50+ consecutive failures … wasting ~250K API calls/day").

3. **Boundary + preservation.** Compaction leaves a boundary marker and only the
   messages after it are sent (`code-base/utils/messages.ts:4643`
   `getMessagesAfterCompactBoundary`). The boundary carries relink metadata so
   the preserved segment stays connected in the transcript
   (`code-base/services/compact/compact.ts:349`
   `annotateBoundaryWithPreservedSegment`). After compaction, the **files that were
   read** and the **skills that were invoked** are re-attached
   (`compact.ts:1415` `createPostCompactFileAttachments`, 5 files / 50 000 token
   budget; `compact.ts:1494` `createSkillAttachmentIfNeeded`, 5 000 per skill /
   25 000 total).

Grouping is by API round, not by human turn
(`code-base/services/compact/grouping.ts:22` `groupMessagesByApiRound`), so a
single-turn agentic session can still be compacted reactively.

**Ours.** `src/compaction.zig:201` `elideTier` replaces old tool results (>256 B,
outside the recent window) with `[tool result elided: N bytes — re-run the tool if
you need it]`, and reports `elided_at` so the read cache can forget what it
cached (`src/compaction.zig:183-197`). Tier 2 (`src/compaction.zig:323`
`summaryPrompt`) builds a bounded 16 KB prompt keeping the start and the newest
messages and replaces the middle with one user note
(`src/agent.zig:5267`). The budget is 80% of the limit
(`src/compaction.zig:171`), the limit is the model's own window unless overridden
(`src/compaction.zig:75` `contextLimitFor`). Cadence is
`summary_gap = 6` iterations and `summary_max = 3` per session
(`src/agent.zig:1520-1521`), and a failed summary counts against the budget
(`src/agent.zig:5280`).

**Delta.**

1. **No boundary.** Ours rewrites the message list in place; there is no marker
   and no "only send what is after the last boundary". A resume therefore
   re-sends the whole summarized history. Upstream's `getMessagesAfterCompactBoundary`
   is the mechanism that makes a resumed session cheap.
2. **No preservation of read files / invoked skills across a compaction.** Ours
   summarizes them away; upstream re-attaches them (bounded).
3. **No time-based (cache-expired) trigger.** Ours compacts on token count only.
   The upstream trigger is free: when the cache is cold anyway, clearing old tool
   results costs nothing and shrinks the rewrite.
4. **No circuit breaker per se** — we have `summary_max = 3` per session, which
   is a *budget*, not a *failure counter*. Upstream's breaker is keyed on
   consecutive *failures*, so a session where the summarizer works keeps
   compacting; ours stops after 3 summaries whether they worked or not.
5. **Microcompaction is coarser than upstream's.** Ours elides by age
   (outside the recent window); upstream elides by tool (a fixed set) and by
   count.

**Effort.** S for the boundary (one marker + one slice); M for the
preserve-and-reattach (needs the read-file set and the invoked-skill set to be
tracked across compaction); S for the time-based trigger; S for the failure-keyed
breaker.

**Risk.** Low-medium. The boundary changes what a resumed session contains, so
the session loader has to agree with it — that is the "side tables carried over"
trap Phase 30.4 already names (`TASKS.md:614`).

**TASKS phase.** Phase 7 (`TASKS.md:152`) covers microcompaction with a
recoverable marker, compaction boundaries, preserving invoked skills and read
files, and the circuit breaker. **Essentially fully covered.** Phase 3
(`TASKS.md:98`) covers the tool-result storage that the marker points at.

---

### 2.5 Memory

**Upstream.** A *directory* of markdown files, not a list.

- `code-base/memdir/memdir.ts:34` `ENTRYPOINT_NAME = "MEMORY.md"` is an **index**
  in the memory directory, capped at 200 lines and 25 000 bytes, with a truncation
  warning that names which cap fired
  (`memdir.ts:57` `truncateEntrypointContent`). The detail lives in topic files.
- The memory directory is guaranteed to exist so the model never has to `mkdir`
  (`memdir.ts:130` `ensureMemoryDirExists`, with the guidance string at `:116`:
  "This directory already exists — write to it directly with the Write tool").
- Memories have a **type** (`code-base/memdir/memoryTypes.ts:14` `MEMORY_TYPES`:
  `user | feedback | project | reference`), and each type has its own scope
  (`private` or `team`) and its own `when_to_save` / `how_to_use` guidance
  (`memoryTypes.ts:37` `TYPES_SECTION_COMBINED`).
- Extraction is **automatic and at the end of the turn**: a forked agent reads the
  transcript and writes memories
  (`code-base/services/extractMemories/extractMemories.ts:1-10`, run at the end
  of the turn from `code-base/query/stopHooks.ts:149`
  `executeExtractMemories`).
- Recall is **selective**: `code-base/memdir/findRelevantMemories.ts:39`
  `findRelevantMemories` scans the headers and asks a *cheap model* to pick up to
  5 relevant files, excluding `MEMORY.md` itself and excluding files already
  surfaced in a previous turn (`findRelevantMemories.ts:46`, `:35` on
  `alreadySurfaced`).
- Memories carry a **staleness note**: `code-base/memdir/memoryAge.ts:15`
  `memoryAge` renders "47 days ago" instead of a raw timestamp, because "models
  are poor at date arithmetic", and `memoryAge.ts:33` `memoryFreshnessText` adds
  "Memories are point-in-time observations, not live state — claims about code
  behavior or file:line citations may be outdated".
- There is a **consolidation** job (`code-base/services/autoDream/autoDream.ts:1-11`:
  time gate + session count + a lock) and a **session memory** that is a running
  markdown summary of the current conversation
  (`code-base/services/SessionMemory/sessionMemory.ts:1-5`).
- Team memories have their own path tree and a secret scanner
  (`code-base/memdir/teamMemPaths.ts`, `code-base/services/teamMemorySync/secretScanner.ts`).

**Ours.** **Nothing.** There is no memory directory, no index, no extraction, no
recall. What we have is the project's own `AGENTS.md` read once at startup
(`src/agent.zig:697` `systemPromptBase`).

**Delta.** The whole mechanism. The pieces that matter most, in order:

1. A memory directory with an **index file** (bounded) + topic files, so the
   prompt carries a table of contents and not the corpus.
2. **Selective recall**: a cheap model picking the ≤5 relevant memories for the
   current query, with the already-surfaced set excluded so it does not re-pick
   the same file forever.
3. **Extraction at end of turn** by a forked subagent — we already have the
   machinery for a forked subagent (`src/lib/subagent.zig`), so this is
   re-wiring, not new machinery.
4. **Staleness notes**. Free, and it fixes a specific failure: a memory that
   says "file:42 does X" becomes a false claim the moment the file changes.

**Effort.** M for the store + index + recall; S for extraction (reuse the
subagent); S for the staleness note.

**Risk.** Medium, and the risk is *misinformation*: a memory that is wrong is
worse than no memory, because the model treats it as ground truth. The upstream
staleness note and the "point-in-time observations" framing are the mitigations
and they should be copied.

**TASKS phase.** Phase 11 (`TASKS.md:193`) covers the store, the extractor and
`@import` precedence. It does **not** cover the index file with its caps, the
cheap-model recall step, the staleness notes, or the consolidation job.

---

### 2.6 Subagents and teams

**Upstream.**

- **Subagents** are the `Agent` tool (`code-base/tools/AgentTool/AgentTool.tsx`).
  They can run in the background (`AgentTool.tsx:87` `run_in_background`) and the
  model is told it will be notified (`code-base/tools/AgentTool/prompt.ts:263`).
  They can be **isolated** in a worktree or a remote environment
  (`AgentTool.tsx:99` `isolation`), they can be **resumed**
  (`code-base/tools/AgentTool/resumeAgent.ts`) and **forked**
  (`code-base/tools/AgentTool/forkSubagent.ts`, which shares the parent's prompt
  cache). The tool set is filtered by role
  (`code-base/tools/AgentTool/agentToolUtils.ts:70` `filterToolsForAgent`:
  `ALL_AGENT_DISALLOWED_TOOLS`, `ASYNC_AGENT_ALLOWED_TOOLS`,
  `CUSTOM_AGENT_DISALLOWED_TOOLS`).
- **Definitions on disk**: `code-base/tools/AgentTool/loadAgentsDir.ts:73`
  `AgentJsonSchema` — `description`, `tools`, `disallowedTools`, `prompt`, `model`,
  `effort`, `permissionMode`, `mcpServers`, `hooks`, `maxTurns`, `skills`,
  `initialPrompt`, `memory` (scope), `background`, `isolation`.
- **Built-in roles**: `code-base/tools/AgentTool/builtInAgents.ts:22`
  `getBuiltInAgents` — general-purpose, statusline-setup, Explore, Plan,
  claude-code-guide, Verification.
- **Teams**: `code-base/tools/TeamCreateTool/prompt.ts:24` — "Teams have a 1:1
  correspondence with task lists". A team is a config file
  (`~/.claude/teams/{name}/config.json`) plus a task-list directory. Teammates are
  spawned as in-process tasks (`code-base/tasks/InProcessTeammateTask/`), claim
  work from the shared task list, and go idle between turns. Messages are a tool
  (`code-base/tools/SendMessageTool/SendMessageTool.tsx`), not prose: "Plain
  assistant text is NOT visible to another agent — a message is a tool call, that
  is the only channel" (`TeamCreateTool/prompt.ts:381` in the board's terms).
- The task store is **file-per-task with locking**, and claiming is atomic:
  `code-base/utils/tasks.ts:541` `claimTask` takes an exclusive lock on the task
  file, re-reads, checks `owner`/`completed`/`blockedBy`, and writes — returning a
  reason (`already_claimed`, `already_resolved`, `blocked`) instead of throwing.
  Task ids come from a high-water-mark file (`utils/tasks.ts:110-130`).

**Ours.**

- Subagent: `src/lib/subagent.zig:44` `tool_names` is a fixed read-only list
  (read, grep, glob, list_files, web_fetch, web_search, lsp); `:66`
  `max_iterations = 8`; `:77` `budget_tokens = 24_000`; `:81` `max_tool_output =
  4 KB`; `:111` `capResult` cuts at a line boundary and announces the cut. Effort
  is always `low`; depth is 1; the subagent does **not** see the conversation.
  The loop is `src/agent.zig:6580` `runSubagent`.
- Parallelism: up to `ZODE_TASK_PARALLEL` (3), results returned in request order,
  each with its own arena (`AGENTS.md`, "Tools in parallel").
- Task graph: `src/lib/taskstore.zig:81` `Task{id, subject, description, status,
  owner, blocks, blocked_by}`, `:198` `in_progress` without an owner is refused,
  `blocked_by` is derived (never typed twice), stored in one JSON file next to
  the session (`src/lib/taskstore.zig:613` `pathForSession`).

**Delta.**

1. **No agent definitions on disk.** Ours has one hard-coded role (a read-only
   searcher). Upstream has a schema with `tools`/`disallowedTools`/`model`/
   `effort`/`permissionMode`/`maxTurns`/`memory`/`isolation`.
2. **No built-in roles.** Upstream ships Explore, Plan, Verification as distinct
   agents; ours has none.
3. **No background subagents and no notification.** Ours' `task` is synchronous:
   the turn waits for it. Upstream's `run_in_background` returns immediately and
   the model is notified later.
4. **No resume and no fork.** Upstream can resume a subagent with its window
   intact or fork it.
5. **No teams.** No `team_create`, no `send_message`, no claiming, no idle
   teammates. Ours' task graph has the *data* but no *actors*.
6. **No atomic claim.** Ours' `owner` is set by `task_update`; two agents could
   set the same owner. Upstream locks the file.
7. **No MCP servers per agent**, no `hooks` per agent, no `skills` per agent.

**Effort.** M for definitions on disk + built-in roles; M for background
subagents + notification (needs the notification queue from §2.3); M for teams
(the task store already exists — it needs claiming, a message channel and an
idle/wake lifecycle).

**Risk.** Medium for teams (a message channel between agents is a new failure
surface: two agents waiting on each other). Low for definitions on disk, but the
safety floor has to be enforced: upstream's rule is that a custom agent cannot
*escalate* — `filterToolsForAgent` removes the disallowed tools
(`agentToolUtils.ts:94-99`).

**TASKS phase.** Phase 9 (`TASKS.md:172`) = agent definitions on disk;
Phase 20 (`TASKS.md:373`) = team mode; Phase 26 (`TASKS.md:450`) = built-in
roles + agent memory + resume/fork. **Background subagents and their notification
are the gap** — Phase 10 covers background *shell* jobs, not background *agents*.

---

### 2.7 Skills

**Upstream.** `code-base/skills/loadSkillsDir.ts:185` `parseSkillFrontmatterFields`
parses, per skill: `displayName`, `description`, `allowedTools`, `argumentHint`,
`argumentNames`, `whenToUse`, `version`, `model` (with `"inherit"` meaning
inherit, `loadSkillsDir.ts:222`), `disableModelInvocation`, `userInvocable`,
`hooks` (`:259`), `executionContext` (`'fork'`, `:260`), `agent` (`:261`),
`effort` (`:262`), `shell` (`:263`).

Two more mechanisms:

- **Conditional skills by path**: a skill with a `paths:` frontmatter is not
  listed until a matching file is touched
  (`code-base/skills/loadSkillsDir.ts:159` `parseSkillPaths`,
  `:986` `activateConditionalSkillsForPaths`).
- **Budgeted listing**: the listing gets 1% of the context window, with a 250
  character per-entry cap and a fallback of "names only"
  (`code-base/tools/SkillTool/prompt.ts:20-29` `SKILL_BUDGET_CONTEXT_PERCENT`,
  `MAX_LISTING_DESC_CHARS`, `:31` `getCharBudget`, `:70`
  `formatCommandsWithinBudget`).

**Ours.** `src/lib/skills.zig:83` `Meta{name, description, when_to_use,
argument_hint, allowed_tools, model, effort, context}` and `:103`
`splitFrontmatter` (a deliberately narrow `key: value` parser, no YAML). Discovery
in `src/lib/skillstore.zig:28` `Loader` with shadowing order
(project → `.agents/skills` → repo root → user), bundled skills appended after
(`src/lib/bundled_skills.zig`). Only the name and description go into the prompt
(`src/lib/skills.zig:240` `systemPromptSection`); the body is loaded on demand by
the `skill` tool. `$ARGUMENTS` is substituted (`src/lib/skills.zig`, `Meta.argument_hint`;
`src/lib/bundled_outputstyles.zig:49` `substituteArguments`).

**Delta.**

1. **`allowed_tools`, `model` and `effort` are parsed and then ignored.**
   `src/lib/skills.zig:88-91` stores them; nothing reads them at runtime
   (`grep -rn allowed_tools src/` finds only the parser and the bundled
   definitions). A skill that says `allowed_tools: ["read"]` is not enforced.
   Upstream enforces `allowedTools`
   (`loadSkillsDir.ts:243`) and resolves `model`/`effort` per skill.
2. **`context: fork` is parsed and never read.** `src/lib/skills.zig:91` and
   `:157` set it; the only reader is a test
   (`src/lib/skills.zig:325`). The board says so explicitly
   (`TASKS.md:30`: "`context: fork` is parsed and never read").
3. **`when_to_use` is displayed but not a matcher.** Upstream's `whenToUse` is
   part of the description in the listing (`code-base/tools/SkillTool/prompt.ts:44`
   `getCommandDescription` appends it), which is what we do
   (`src/lib/skills.zig:240`), so this one is fine.
4. **No conditional skills by path.** Upstream can hide a skill until the project
   touches a matching file. Ours lists everything.
5. **The listing budget is a constant** (`src/lib/skills.zig:74`
   `max_listed = 40`), not 1% of the context window, and there is no 250-char
   per-entry cap.
6. **No `disable-model-invocation` / `user-invocable`**, no per-skill `hooks`,
   no per-skill `agent`.

**Effort.** S for the budget (2.1) and named args (2.3); S for enforcing
`allowed_tools` (the skill tool already knows its caller's tool list); M for
`context: fork` (it needs a subagent invocation path, which exists).

**Risk.** Low for the budget, medium for `context: fork` (a fork is a real
subagent run: tokens, time, and a report that has to come back into the parent's
context). Enforcing `allowed_tools` on a skill is a *security* property: a skill
that says `allowed_tools: ["read"]` and is then given `bash` is a hole.

**TASKS phase.** Phase 2 (`TASKS.md:83`) covers 2.1 (listing budget),
2.3 (named args), 2.4 (`context: fork`), 2.5 (`!cmd` in a skill). It does **not**
cover enforcing `allowed_tools`, nor the `model`/`effort` fields that Phase 1
(`TASKS.md:73`) already put in the frontmatter.

---

### 2.8 Output styles

**Upstream.** `code-base/outputStyles/loadOutputStylesDir.ts:26`
`getOutputStyleDirStyles` — a flat directory of `.md` files, one per style, from
the project (`.claude/output-styles/`) and the user (`~/.claude/output-styles/`),
project shadowing user. The filename is the style name; frontmatter gives
`name`, `description` and `keep-coding-instructions`
(`loadOutputStylesDir.ts:52-62`, the flag parsed as boolean or the string
`"true"`/`"false"`). Plugin styles are loaded separately and the caches are
invalidated on change (`loadOutputStylesDir.ts:94` `clearOutputStyleCaches`).

**Ours.** `src/lib/outputstyles.zig` — a **directory** per style, each containing
an `OUTPUT_STYLE.md` (`src/lib/outputstyles.zig:38` `filename`), discovered in
`src/lib/outputstyle_store.zig:57` `scan`, with the same shadowing order as
skills. The style block is injected at the **end** of the system prompt
(`src/agent.zig:551-568`, with the comment "THE ORDER IS THE CACHE"), and
`keep_coding_instructions = false` drops the harness's own coding rules
(`src/agent.zig:515-519`). Three styles ship bundled
(`src/output_styles/default.md`, `explanatory.md`, `learning.md`).

**Delta.** Small and mostly cosmetic: ours is a directory-per-style with a
`OUTPUT_STYLE.md` inside, upstream is a flat `.md` file; the frontmatter key is
`keep_coding_instructions` (underscores) vs upstream's `keep-coding-instructions`
(hyphens). Upstream also has plugin-provided styles.

**Effort.** S. **Risk.** Low.

**TASKS phase.** Phase 4 (`TASKS.md:115`) covers the discovery, the injection and
the `keep-coding-instructions` flag, and says to ship `default`, `explanatory`,
`learning` — all three of which already exist. **Effectively done; the board
understates it.**

---

### 2.9 MCP and deferred tool loading

**Upstream.** `code-base/services/mcp/client.ts` connects to MCP servers over
five transports (`code-base/services/mcp/types.ts:23` `TransportSchema`:
`stdio | sse | sse-ide | http | ws | sdk`) and exposes tools, resources and
prompts. Server config lives in `.mcp.json`, written atomically (temp file +
rename) preserving the file mode (`code-base/services/mcp/config.ts:88`
`writeMcpjsonFile`).

The part that matters for the *machinery* is **deferred tool loading**. A tool
can be marked `shouldDefer` (`code-base/Tool.ts:442`) or `alwaysLoad`
(`Tool.ts:449`); deferred tools are sent with `defer_loading: true` and their
schemas are excluded from the prompt-cache hash
(`code-base/services/api/claude.ts:1208-1246`, `:1461-1466`). The model then finds
them with the **ToolSearch** tool
(`code-base/tools/ToolSearchTool/ToolSearchTool.ts`), which searches tool names
and descriptions by keyword (`:132` `parseToolName` splits `mcp__server__tool`
and CamelCase into tokens; `:167` `compileTermPatterns`; the search itself is
at `:181+`), supports a direct `select:<tool_name>` form, and returns up to
`max_results` (default 5) matches plus the count of deferred tools and any
pending MCP servers (`ToolSearchTool.ts:37-45` `outputSchema`).

**Ours.** **No MCP.** There *is* a JSON-RPC client — `src/lsp/client.zig` — but
it speaks LSP, not MCP, and it is a per-language server, not a general tool
provider.

**Delta.** The whole thing: a transport, a server registry, a tool namespace
(`mcp__server__tool`), and the deferred-loading mechanism so that adding ten MCP
servers does not add ten schemas to every prompt.

**Effort.** L for MCP (transport + lifecycle + namespacing + error mapping).
M for deferred loading, and it has to be done *differently*: upstream leans on
Anthropic's `defer_loading` beta header, which does not exist for an
OpenAI-compatible provider. The portable version is the ToolSearch half — keep
the schemas out of the prompt and let the model search for them — which needs
our own search index.

**Risk.** Medium-high. MCP servers are third-party code the harness spawns; the
tool names they inject are attacker-controlled in a shared project. Upstream's
mitigations are worth copying: a channel allowlist
(`code-base/services/mcp/channelAllowlist.ts`), server approval
(`code-base/services/mcp/mcpServerApproval.tsx`), and per-server OAuth.

**TASKS phase.** Phase 12 (`TASKS.md:204`) covers MCP over stdio (connect, list
tools, call) **and** deferred tool loading / tool search. **Covered** — with the
caveat that the deferred part cannot use the upstream beta and needs its own
design.

---

### 2.10 Tool result storage and rendering

**Upstream.** `code-base/utils/toolResultStorage.ts` is the whole mechanism:

- **Persist, don't truncate.** `toolResultStorage.ts:137` `persistToolResult`
  writes a result over its threshold to
  `<project>/<session>/tool-results/<tool_use_id>.txt` and returns a preview
  (`:109` `PREVIEW_SIZE_BYTES = 2000`). The file is written with the `wx` flag
  so a replayed turn does not rewrite it and a symlink cannot redirect it
  (`:161-172`, with the comment "Use 'wx' instead of a stat-then-write race").
  The model gets `<persisted-output>` … `</persisted-output>` with the path and
  the preview (`:189` `buildLargeToolResultMessage`).
- **Per-tool thresholds** (`toolResultStorage.ts:55` `getPersistenceThreshold`),
  with `Infinity` as a hard opt-out for `Read` (whose output is self-bounded and
  whose persistence would create a circular Read→file→Read loop).
- **A per-message aggregate budget**, enforced across the whole message group
  (`:769` `enforceToolResultBudget`, limit from `:421`
  `getPerMessageBudgetLimit`), and the decision is **frozen**: once a result has
  been replaced, the replacement is re-applied verbatim on later turns
  (`:802-803` `mustReapply`, `:797` `partitionByPriorDecision`) so the prompt
  cache does not break. The frozen state is reconstructed from the transcript on
  resume (`:960` `reconstructContentReplacementState`).
- **Collapsed rendering** of read/search calls in the transcript
  (`code-base/utils/collapseReadSearch.ts`), so a run of reads is one line.
- A one-line human summary of a tool batch generated by a cheap model
  (`code-base/services/toolUseSummary/toolUseSummaryGenerator.ts:45`).

**Ours.** `src/lib/resultcap.zig` is a **pure cap layer**: per-tool
(`src/tools/registry.zig:471` `maxResultChars`, `read` unbounded) and per-message
aggregate (`src/lib/resultcap.zig:78` `capAggregate`, budget
`max_results_per_message_chars = 200_000`). A cut always carries a notice inside
the budget (`src/lib/resultcap.zig:23` `cut_notice`) and never splits a UTF-8
sequence (`:60` `validPrefixBytes`). The subagent has its own tighter cap
(`src/lib/subagent.zig:111` `capResult`, 4 KB, line-boundary + UTF-8 boundary +
notice).

**Delta.**

1. **We truncate; upstream persists.** A cut result is unrecoverable: the model
   must re-run the tool, which costs a round trip and can be non-deterministic.
   Upstream keeps the bytes and hands the model a path.
2. **No frozen decisions.** Our aggregate cap is recomputed per message; if the
   budget changes between turns the same result can be cut differently, which
   changes the prompt prefix and breaks the cache. Upstream freezes the decision.
3. **No reconstruction on resume.** Ours recomputes from the session file; the
   cut points can differ from the original session's, so a resume is not
   byte-identical to the original.
4. **Collapsed rendering**: ours has the Ctrl+R toggle for diffs and the live
   paragraph, but not upstream's "a run of reads is one collapsed group".

**Effort.** M for the persistence layer (file naming, `wx` semantics, preview,
the marker, the session directory). S for freezing the decisions (a map from
result id to the cut that was made, persisted).

**Risk.** Low-medium. The `wx` flag and the session-scoped directory are the
parts that matter; the preview must be small or it defeats the purpose.

**TASKS phase.** Phase 3 (`TASKS.md:98`) covers exactly this: `toolstore.zig`,
file + preview + path, the four constants, and the per-tool render.
**Covered** — with two additions it does not mention: the *frozen* decision
(so the cache survives) and the reconstruction on resume.

---

### 2.11 Cost tracking

**Upstream.** `code-base/cost-tracker.ts` accumulates per-model usage
(`ModelUsage`), total cost in USD (`:177` `calculateUSDCost` in
`code-base/utils/modelCost.ts`, which uses a per-model price table), input/output
tokens, cache read/creation tokens, total duration, API duration with and without
retries, **tool** duration, web-search request count, and **lines added/removed**
(`addToTotalLinesChanged`). Cost state is persisted per session in the project
config so a resumed session keeps its number
(`cost-tracker.ts:87` `getStoredSessionCosts`, which refuses a stale
`lastSessionId`). `/cost` prints it (`code-base/commands/cost/cost.ts:6`).

**Ours.** `src/cache_stats.zig` tracks tokens and cache hit-rate.
`src/lib/bench.zig:22` `Stats` tracks turns, iterations, tool calls, asks, TTFT
percentiles and read-cache hits. **Neither computes money and neither is
per-model.** There is no `/cost`.

**Delta.** No USD accounting, no per-model usage breakdown, no lines-changed
metric, no persisted cost across a resume.

**Effort.** S–M. The token counts we already have; a price table and a
multiplier are the rest. The price table is a maintenance burden (it goes stale
and a stale price is a wrong number, which is worse than no number).

**Risk.** Low, but note the failure mode: **a cost number that is wrong is worse
than no cost number**, because the user trusts it. Upstream solves this with
`hasUnknownModelCost` (`cost-tracker.ts:56`).

**TASKS phase.** Phase 30.5 (`TASKS.md:616`) mentions "the cost state" as
something a resume should restore — but no phase *creates* a cost state. **This
is the clearest "no phase owns it" gap in the board.**

---

### 2.12 Sandbox and bash safety

**Upstream.** Two separate things.

**Sandbox.** Upstream wraps Anthropic's `sandbox-runtime`
(`code-base/utils/sandbox/sandbox-adapter.ts:1-3`). The config is a first-class
schema (`code-base/entrypoints/sandboxTypes.ts:14` `SandboxNetworkConfigSchema`,
`:44` `SandboxFilesystemConfigSchema`) with `allowWrite`/`denyWrite`/`denyRead`/
`allowRead`, network domain allowlists, Unix-socket policy, and a **violation
store** (`SandboxViolationStore`) that surfaces what the sandbox caught. Two
permission interactions matter: a sandboxed `Bash` can be **auto-allowed** even
when an `ask` rule matches (`code-base/utils/permissions/permissions.ts:1094-1100`
`canSandboxAutoAllow`), and `excludedCommands` keeps specific commands out of
the sandbox (`code-base/tools/BashTool/shouldUseSandbox.ts:21`
`containsExcludedCommand`, which splits compound commands so
`docker ps && curl evil.com` cannot escape via the first subcommand).

**Bash safety.** The read-only classification is a **table with per-command safe
flags**, not a heuristic: `code-base/utils/shell/readOnlyCommandValidation.ts:104`
`GIT_READ_ONLY_COMMANDS` (every git subcommand with its safe flags),
`:1539` `EXTERNAL_READONLY_COMMANDS`, `:1416` `RIPGREP_READ_ONLY_COMMANDS`,
`:1386` `DOCKER_READ_ONLY_COMMANDS`, `:1504` `PYRIGHT_READ_ONLY_COMMANDS`.
The rules exclude the flags that turn a read into a write, with the reason in
comments (`:52-60`: "`-x/--exec` and `-X/--exec-batch` are deliberately excluded
— they execute arbitrary commands for each search result"). Separately there is a
**destructive-command warning** table for the dialog
(`code-base/tools/BashTool/destructiveCommandWarning.ts:12`
`DESTRUCTIVE_PATTERNS`: `git reset --hard`, `git push --force`, `rm -rf`,
`DROP TABLE`, `terraform destroy`, …) and **command injection** detection
(`code-base/tools/BashTool/bashSecurity.ts`, 2592 lines).

**Ours.** No sandbox at all. For bash safety we have exactly one thing:
`src/lib/verify.zig:174` `classify`, a table of *verification* commands
(`zig build`, `npm test`, `cargo test`, `make`, `just`, …) that decides whether a
command is a slow verification (→ background it) or a quick one. It is a
well-built table with the same "specific before broad" discipline
(`src/lib/verify.zig:60-63`), but it answers a different question: *how long will
this take*, not *is this safe*.

There is no read-only bash classification, no destructive-command warning, and no
command-injection detection. `src/agent.zig:1845` `bashPatternAllowed` refuses a
chained remainder, which is one specific injection defence.

**Delta.**

1. **No sandbox.** `bash` runs with the user's full privileges.
2. **No read-only bash classification.** Every `bash` call asks, even `ls`.
3. **No destructive-command warning in the dialog.** The dialog shows the raw
   command (`src/agent.zig:7082-7085`) and nothing else; upstream adds "Note:
   may discard uncommitted changes".
4. **No command-injection detection.**

**Effort.** M for the read-only table (it is large upstream — 1893 lines for the
flags alone — but a 100-row version covers most projects). S for the
destructive-warning table. M for a sandbox (bwrap/firejail), L if the sandbox has
to be a policy engine with allow/deny lists rather than a wrapper.

**Risk.** High for the sandbox, and that is the point: it is the difference
between "the model runs what the user approved" and "the model runs what the
model wanted". Medium for the read-only table (a table that marks `rm -rf` as
read-only is a hole; upstream's per-flag approach is the reason to copy it
verbatim rather than by command name).

**TASKS phase.** Phase 25 (`TASKS.md:435`) = bash safety
(`lib/cmdsafety.zig`, split pipelines, name the exact dangerous fragment, the
dialog shows the risk in words). Phase 6 (`TASKS.md:140`) = the read-only table
and an optional `bwrap`/`firejail` sandbox. **Covered** — Phase 6's sandbox is
one sentence against upstream's 1777-line permission filesystem plus a
sandbox-runtime integration, so the *depth* is not covered.

---

## 3. Not covered by TASKS.md

Ranked by value per unit of risk. Each item is a real upstream mechanism, read
in its implementation, with no phase in the board that owns it.

### 3.1 Path-scoped permissions and dangerous-path protection — **NOT COVERED**

Upstream: `code-base/utils/permissions/pathValidation.ts:141` `isPathAllowed`
(resolve → deny rule → internal editable paths → **safety check** → working-dir
check → sandbox allowlist → allow rule); `code-base/utils/permissions/filesystem.ts:620`
`checkPathSafetyForAutoEdit` (blocks `.git/`, `.claude/`, `.vscode/`, `.idea/`
(`filesystem.ts:74`), the user's shell configs, UNC paths, and Windows path
patterns); `filesystem.ts:683` `pathInAllowedWorkingPath` (symlink-resolved
working-directory containment).

Ours: nothing. `src/tools/write.zig:61` writes any path relative to the cwd.

**Proposal.** A new pure module `src/lib/pathrules.zig`:
- `resolve(path) → canonical absolute path` (symlinks resolved; a path outside
  the cwd is flagged).
- `dangerous(path) → bool` with the table `{".git", ".claude", ".vscode",
  ".idea"}` plus the shell-config names.
- `allowed(path, rule_set) → Decision` where the rule set is the same
  `Tool(pattern)` grammar Phase 6 introduces, so `Read(*.ts)` and
  `Edit(src/**)` work.
Wire it into `src/tools/write.zig`, `src/tools/edit.zig`, `src/tools/rename.zig`
and into the permission detail shown in the dialog.

**Files.** `src/lib/pathrules.zig` (new, pure), `src/tools/write.zig`,
`src/tools/edit.zig`, `src/tools/rename.zig`, `src/agent.zig:7076` (the
permission call), `src/tools/registry.zig` (a `path_sensitive` row flag).

**Effort.** M. **Risk.** Medium — a path rule that resolves incorrectly either
blocks legitimate work or allows a dangerous write. The mitigation is that it is
*pure and testable*, and that the failure direction is chosen per case (a
sensitive path asks rather than refuses).

### 3.2 The frozen-decision property of the result cap — **NOT COVERED**

Upstream: `code-base/utils/toolResultStorage.ts:797` `partitionByPriorDecision`
and `:802-803` re-apply a frozen replacement verbatim on every later turn;
`:960` `reconstructContentReplacementState` rebuilds it from the transcript on
resume.

Ours: `src/lib/resultcap.zig:78` `capAggregate` recomputes per call.

**Proposal.** Give the cap layer a *state* object: a map from result id → the
cut that was made. Persist it next to the session
(`sessions/zode-<id>.toolcaps.json`), reload it on resume, and make
`capAggregate` consult it before cutting. A result that was cut once is cut the
same way forever, so the prompt prefix is byte-stable.

**Files.** `src/lib/resultcap.zig` (add a `Caps` state struct),
`src/session.zig` (load/save), `src/agent.zig:5166-5176` (the call site),
`src/main.zig:308` (the headless call site — the two must agree).

**Effort.** S–M. **Risk.** Low, but it is a *cache* property: without it, a
session that compacts differently on resume silently loses its cached prefix.
That is invisible until the bill arrives.

### 3.3 `deny` and `ask` permission behaviours — **NOT COVERED** (Phase 6 says "deny/allow/ask")

Phase 6 (`TASKS.md:144`) does list `deny / allow / ask` as the actions, so this is
*arguably* covered — but the board gives it one clause with no mention of the
precedence order, of the deny-beats-allow rule, or of deny rules removing the
tool from the model's schema (`code-base/tools.ts:262`
`filterToolsByDenyRules`).

**Proposal.** Make the semantics explicit in Phase 6 and add the two upstream
behaviours that are easy to miss: (a) a `deny` rule for a tool removes that
tool's schema from the request (`src/tools/registry.zig:600` `blob` already
composes the schema list, so this is a filter at compose time); (b) the
precedence table is written down and pinned by a test, exactly like
`src/lib/exitgate.zig:190` `decide` pins the exit rule.

**Files.** `src/tools/registry.zig` (a `deny` filter at compose time),
`src/agent.zig` (the evaluation order), a new `src/lib/permrules.zig` if Phase 6
lands as a pure module.

**Effort.** M. **Risk.** Medium.

### 3.4 Dangerous-allow-rule stripping and shadowed-rule detection — **NOT COVERED**

Upstream: `code-base/utils/permissions/dangerousPatterns.ts:44`
`DANGEROUS_BASH_PATTERNS` + `permissionSetup.ts:510`
`stripDangerousPermissionsForAutoMode`; and
`code-base/utils/permissions/shadowedRuleDetection.ts:14` (a rule that can never
fire because another rule shadows it).

Ours: nothing. An allowlist entry `bash` is the upstream `Bash(python:*)` hazard
in its purest form.

**Proposal.** In the Phase 6 rule store, mark a rule "broad" when its pattern is
a bare interpreter (`python`, `node`, `sh`, `bash`, `curl`, `sudo`, `env`,
`xargs` — upstream's list at `dangerousPatterns.ts:18-42`). When the user
answers "always allow" with such a rule, either refuse it or warn once. And when
the rule set is loaded, detect and report shadowed rules.

**Files.** `src/lib/permrules.zig` (new), `src/agent.zig:1883` `allowAlwaysFor`
(the warning), `src/tui.zig` (the message).

**Effort.** S. **Risk.** Low — it is a warning, not a refusal.

### 3.5 A cost number, per model — **NOT COVERED** (no phase creates a cost state)

Upstream: `code-base/cost-tracker.ts` + `code-base/utils/modelCost.ts:177`
`calculateUSDCost` + `/cost` (`code-base/commands/cost/cost.ts:6`) and the
per-session persistence at `cost-tracker.ts:87`.

Ours: tokens and hit-rate (`src/cache_stats.zig`), session counters
(`src/lib/bench.zig`), no money.

**Proposal.** A `src/lib/cost.zig` that multiplies the per-model token counts we
already have by a price table from the provider catalogue (which
`src/lib/models.zig` already parses for `context_length` — the same table can
carry `pricing`). `/cost` prints the total, the per-model breakdown and the
session's duration. A model whose price is unknown prints "price unknown"
rather than a number — upstream's `hasUnknownModelCost` is the right precedent.

**Files.** `src/lib/cost.zig` (new), `src/lib/models.zig` (the price table),
`src/cache_stats.zig` (per-model counters), `src/commands.zig` (the command),
`src/agent.zig` (the `/cost` handler, near `cmdBench` at `src/agent.zig:970`).

**Effort.** S–M. **Risk.** Low, but a wrong number is worse than none.

### 3.6 The hook output contract (`updatedInput`, `additionalContext`) — **NOT COVERED**

Upstream: `code-base/types/hooks.ts:70-165` — `hookSpecificOutput` per event,
including `updatedInput` (rewrite the call's arguments), `additionalContext`
(put text in the model's context), `permissionDecision`, `updatedMCPToolOutput`,
`decision: approve|block`.

Phase 5 (`TASKS.md:133-136`) says "Hook output fed back as a tool result / system
note; a non-zero exit on `PreToolUse` blocks the tool with the reason". That is
the *thin* contract. The fat one is what makes hooks worth having: `updatedInput`
lets a hook rewrite a call (e.g. rewrite `rm -rf build/` into `rm -rf build/tmp/`),
and `additionalContext` lets a hook inject a fact.

**Proposal.** Extend Phase 5's JSON schema to the upstream shape (per-event
`hookSpecificOutput`), and implement two fields first: `permissionDecision` and
`updatedInput`. `updatedInput` is the higher-value one: it turns a hook from a
veto into a *rewriter*, which is the difference between "your hook said no" and
"your hook changed the command".

**Files.** `src/lib/hooks.zig` (new: config, spawn, parse, the output schema),
`src/agent.zig:7086` (the permission call — a hook decision must be consulted
*before* the dialog), `src/tools/dispatch.zig:232` `executeWith` (the rewritten
input has to reach the tool).

**Effort.** M for the two fields; L for the whole contract. **Risk.** Medium —
a hook that rewrites tool arguments is a security boundary, and it is exactly the
place where a bug is silent.

### 3.7 Memory recall by relevance, and staleness notes — **PARTIALLY COVERED**

Phase 11 (`TASKS.md:193-200`) covers the store, the extractor and `@import`
precedence. It does not cover the two mechanisms that make memory *useful*
rather than merely *present*:

- `code-base/memdir/findRelevantMemories.ts:39` `findRelevantMemories` — a cheap
  model picks ≤5 relevant memories per query, excluding `MEMORY.md` and
  excluding already-surfaced files (`:46`).
- `code-base/memdir/memoryAge.ts:15` `memoryAge` and `:33` `memoryFreshnessText`
  — "this memory is 47 days ago" and "point-in-time observations, not live state".

**Proposal.** In Phase 11: (a) an index file (`MEMORY.md`) with the upstream caps
(200 lines / 25 KB) and a truncation warning, so the prompt carries a table of
contents; (b) a `findRelevantMemories` step using our own subagent machinery
(`src/lib/subagent.zig`) with the already-surfaced set excluded;
(c) a `mtime`-based staleness note on every surfaced memory.

**Files.** `src/lib/memstore.zig` (new: the directory, the index, the scan),
`src/lib/memoryage.zig` or inside the store (the note), `src/agent.zig:496`
(`buildSystemPrompt` — where the recall would attach), `src/lib/subagent.zig`
(the selector).

**Effort.** M. **Risk.** Medium — a wrong memory is worse than no memory.

### 3.8 Background *subagents* and their notification — **NOT COVERED**

Phase 10 (`TASKS.md:183`) is about background *shell* jobs. Upstream's background
*agents* (`code-base/tools/AgentTool/AgentTool.tsx:87` `run_in_background`,
`:567` `shouldRunAsync`) are a different thing: the model keeps working while a
search runs, and is notified when it lands (`code-base/tools/AgentTool/prompt.ts:263`:
"you will be automatically notified when it completes — do NOT sleep, poll, or
proactively check on its progress").

This is the natural composition of two things we already have — the subagent
(`src/lib/subagent.zig`) and the notification queue that Phase 10 will build —
and it is the single biggest *latency* win available: today a `task` blocks the
turn.

**Proposal.** Add `run_in_background: bool` to the `task` tool
(`src/tools/prompts/task.zig`). A backgrounded task registers in a small
registry, returns immediately with an id, and the Phase 10 notification queue
delivers `<task-notification>` with the report when it lands. The tool result
is the report; the notification carries it.

**Files.** `src/tools/prompts/task.zig` (the schema), `src/agent.zig:6580`
`runSubagent` (the spawn), a new `src/lib/taskreg.zig` or an extension of
`src/bgproc.zig` (the registry), `src/agent.zig` (the notification drain).

**Effort.** M. **Risk.** Medium — a background task that reports into a turn
that has already moved on needs the report to be *attributable* to the request
that spawned it.

### 3.9 Atomic task claiming — **NOT COVERED**

Upstream: `code-base/utils/tasks.ts:541` `claimTask` — an exclusive lock on the
task file, then a re-read, then `owner` / `completed` / `blockedBy` checks, and
a *reason* on failure (`already_claimed`, `already_resolved`, `blocked`) instead
of an exception. The lock options are sized for ~10 concurrent swarm agents
(`utils/tasks.ts:95-108`).

Ours: `src/lib/taskstore.zig:222` `setOwner` and `:198` (the
`in_progress`-needs-an-owner refusal). Two agents can both set the same owner;
there is no claim operation at all.

**Proposal.** A `claim_task` operation in `src/lib/taskstore.zig`: take the
store's lock, re-read, verify the task is open and unblocked, set the owner,
and return the reason on failure. Our store is a single JSON file, so the lock
is one `std.atomic.Mutex` plus a re-read — much simpler than upstream's
per-file locking.

**Files.** `src/lib/taskstore.zig` (the operation), `src/tools/tasks.zig` (the
tool), `src/tools/prompts/task_update.zig` (the schema).

**Effort.** S. **Risk.** Low.

### 3.10 Enforcement of a skill's `allowed_tools` / `model` / `effort` — **NOT COVERED**

Phase 1 (`TASKS.md:73`) added these fields to the frontmatter; nothing reads
them (`grep -rn allowed_tools src/` finds only the parser at
`src/lib/skills.zig:150` and the bundled definitions in
`src/lib/bundled_skills.zig:40-84`).

Upstream enforces `allowedTools` (`code-base/skills/loadSkillsDir.ts:243`) and
resolves `model` (`loadSkillsDir.ts:222`, where `"inherit"` means inherit) and
`effort` (`:262`).

**Proposal.** When the `skill` tool loads a skill, take its `allowed_tools` as
the subagent's tool list (a skill that says `["read"]` gets only `read`) and its
`model`/`effort` as the run parameters. `src/lib/subagent.zig:44` `tool_names`
becomes a *parameter* instead of a constant, with the current list as the default.

**Files.** `src/lib/subagent.zig:44` (the tool list becomes a parameter),
`src/lib/skills.zig:88` (the fields are read), `src/tools/skill.zig` (the
caller), `src/agent.zig` (the fork's model/effort).

**Effort.** S–M. **Risk.** Medium — this is a *safety* property. A skill that
declares `allowed_tools: ["read"]` and is handed `bash` is a hole, and the
failure is silent.

### 3.11 Conditional skills by path — **NOT COVERED**

Upstream: `code-base/skills/loadSkillsDir.ts:159` `parseSkillPaths` + `:986`
`activateConditionalSkillsForPaths` — a skill with `paths:` is not even listed
until a matching file is touched. This is how upstream keeps the skill list
small without hiding skills that do not apply.

**Proposal.** Add a `paths:` field to `src/lib/skills.zig:83` `Meta` and a
per-session activation set in the skills cache: a skill whose patterns do not
match anything read/written this session is not listed.

**Files.** `src/lib/skills.zig` (the field and the matcher),
`src/lib/skillstore.zig` (the activation set), `src/agent.zig:498`
(`discoverSkills` call site).

**Effort.** M. **Risk.** Low.

### 3.12 A `dontAsk` permission mode — **NOT COVERED**

Upstream has six modes: `default`, `plan`, `acceptEdits`, `bypassPermissions`,
`dontAsk`, `auto` (`code-base/utils/permissions/PermissionMode.ts:45-91`). Ours has
four (`src/agent.zig:789` `PermMode`): `default`, `accept_edits`, `read_only`,
`bypass`. The missing one that matters for automation is `dontAsk`: it converts
"ask" into "deny" (`code-base/utils/permissions/permissions.ts:505-517`).

That is the mode a CI runner or a script wants: "run the agent, but never block
on a human — if it is not pre-approved, fail". Ours has no equivalent: in
headless mode (`zode --chat`) the agent runs with implicit yolo
(`AGENTS.md`, "a loop of up to 6 iterations with implicit yolo"), which is the
*opposite* of `dontAsk`.

**Proposal.** Add `PermMode.dont_ask`: `permNeedsDialog` returns false and the
call is refused with a named reason instead of asking. Wire it to `--deny-ask`
and to the headless runner.

**Files.** `src/agent.zig:789` (the enum), `:7998` `permNeedsDialog`,
`:7078` (the call site — the refusal path already exists at `:7089`),
`src/main.zig` (the headless runner).

**Effort.** S. **Risk.** Low.

### 3.13 The upstream *circuit breaker* keyed on failures, not on a budget — **PARTIALLY COVERED**

Phase 7 lists "Circuit breaker: after N failed summarizer attempts, stop trying"
(`TASKS.md:159`), which is the upstream idea. Our implementation
(`src/agent.zig:1520-1521`) is a *budget*: `summary_gap = 6` iterations and
`summary_max = 3` per session, and a failure counts against the budget
(`src/agent.zig:5280`). Upstream's is a **consecutive-failure** counter
(`code-base/services/compact/autoCompact.ts:70`
`MAX_CONSECPTIVE_AUTOCOMPACT_FAILURES = 3`), so a session whose summarizer works
keeps compacting forever while a session whose summarizer is broken stops after
three tries.

**Proposal.** Change the counter to consecutive failures, and reset it on
success. The failure count and the success count are two numbers
(`src/agent.zig:1537` `noteSummarized` already records one of them).

**Files.** `src/agent.zig:1520-1546` (the two counters).

**Effort.** S. **Risk.** Low.

### 3.14 A `PermissionRequest` hook path for headless runs — **NOT COVERED**

Upstream: `code-base/utils/permissions/permissions.ts:400`
`runPermissionRequestHooksForHeadlessAgent` — in a headless run there is no
dialog, so a `PermissionRequest` hook gets to decide, and only if no hook
answered does the tool auto-deny.

This is the piece that makes upstream's headless mode *safe* rather than
*yolo*: a project can ship a hook that allows `Bash(npm test)` and denies
everything else, and the headless run honours it.

**Proposal.** Fold it into Phase 5 rather than treat it as separate: the
`PermissionRequest` event is the one that makes hooks useful in `--chat` mode.
The decision path already exists (`src/agent.zig:7078-7098`).

**Files.** `src/lib/hooks.zig` (the event), `src/agent.zig:7078` (the call),
`src/main.zig` (the headless runner).

**Effort.** S–M. **Risk.** Low.

### 3.15 A "the model was told to stop and did not" mechanism — **PARTIALLY COVERED, upstream is the other shape**

Upstream's `Stop` hook can **prevent the turn from ending**
(`code-base/query/stopHooks.ts:269-280`, `preventContinuation` +
`stopReason`) and the loop continues with the hook's message attached. Ours does
the opposite: the exit gate (`src/lib/exitgate.zig:190` `decide`) *refuses* to
let the turn end and the harness keeps iterating.

Both shapes are worth having, and the upstream one is the generalisation: the
harness's exit gate is a *built-in* `Stop` hook. When Phase 5 lands, the exit
gate should be expressible as one, and a user's own `Stop` hook should compose
with it rather than fight it.

**Proposal.** In Phase 5, define `Stop` with upstream's semantics
(`preventContinuation` + `stopReason`), and implement the harness's own exit gate
as a *built-in* `Stop` hook that runs first. The rule about who wins (the
built-in gate refuses on red code; a user hook can refuse for its own reasons)
has to be written down, because two things refusing to let a turn end is a
loop.

**Files.** `src/lib/hooks.zig`, `src/agent.zig:3814` (the exit gate call),
`src/lib/exitgate.zig` (the built-in hook's decision).

**Effort.** S. **Risk.** Low — but the *composition rule* must be explicit.

### 3.16 A per-session price/usage table the `/context` command can show — **NOT COVERED**

Related to §3.5 but separate in shape: upstream's `/cost` and the per-model
`ModelUsage` breakdown (`code-base/cost-tracker.ts`, exported at `:52-69`) sit
next to a context-window readout per model (`getContextWindowForModel`,
`cost-tracker.ts:105`). Ours' `/context` shows tokens and hit-rate
(`src/cache_stats.zig`, `src/agent.zig:1575` `ctxTokens`) but not a per-model
split, so "which model is eating the window" is unanswerable.

**Proposal.** Per-model counters in `src/cache_stats.zig` and a per-model line in
`/context`.

**Files.** `src/cache_stats.zig`, `src/agent.zig` (the `/context` handler).

**Effort.** S. **Risk.** Low.

---

## 4. Where our machinery is better than upstream

Stated honestly, with the caveat where it applies.

1. **The exit gate.** Upstream has *no* mechanism that stops a turn from ending
   on broken code. Its closest is the `Stop` hook, which the *user* has to
   write. Ours is built in and pure (`src/lib/exitgate.zig:190` `decide`), it is
   called at the top of every iteration (`src/agent.zig:3814`, before the
   `again orelse break`), and it distinguishes *red*, *stale* (a green from
   before the last edit), *unread diff* and *not checkable* as four different
   outcomes (`src/lib/exitgate.zig:36-67`). The "stale" case
   (`src/lib/exitgate.zig:152` `unverified`) is a mechanism upstream does not
   have at all — upstream's `checkPermissions` and `maxTurnSize` are stateless
   with respect to edits.

2. **The review checklist.** Upstream has no "read your own diff back" tool. Ours
   has `src/lib/review.zig:35` — eight named failure modes with a *reason* for
   each — and the gate refuses to end the turn on an unreviewed diff
   (`src/lib/exitgate.zig:199` `refused_review`), with the same staleness
   arithmetic as the build check (`src/lib/exitgate.zig:110` `reviewed_writes`).
   The ordering (red build outranks unread diff) is a deliberate decision
   (`src/lib/exitgate.zig:195-199`).

3. **A machine-checkable goal.** `src/lib/goal.zig:107` `parseVerdict` +
   `:295` `verdictCredible` — a `blocked` verdict with zero tools run is refused
   once and then accepted, so the model cannot shrug its way out of a task in
   one line. Upstream has `/goal`-like behaviour only as prose in the system
   prompt, and no schema for the verdict.

4. **The repetition guard.** `src/lib/repeats.zig:27-88` — the same tool with the
   same arguments three times in a turn, *reported back to the model as a
   recovery hint*, with `read` and `bash_output` exempt because re-reading and
   polling are their designed use. Upstream has no such guard (the
   `grep -rn "loop detection"` finds nothing).

5. **The batch tool.** `src/lib/batch.zig:40` `Op` — a fixed, enumerable set of
   14 steps, no shell, no pipes, no network — with the permission set of a batch
   being the **union** of the tools its steps are calls to
   (`src/tools/registry.zig:494`). Upstream has no batch primitive; it has
   parallel tool calls (`code-base/services/tools/toolOrchestration.ts:91`
   `partitionToolCalls`), which is a different thing (many round trips, not one).

6. **Parallelism that is provably safe.** Ours splits the call set by a static
   `parallel_safe` flag and each call gets its own arena
   (`src/agent.zig`, "Tools in parallel"), and the read-only set is enforced by
   the registry (`src/tools/registry.zig:459`). Upstream computes
   `isConcurrencySafe(input)` per call
   (`code-base/Tool.ts:402`, `code-base/services/tools/StreamingToolExecutor.ts:40`)
   — more flexible, but the safety argument lives in each tool's own code, which
   is 29 places to keep in sync instead of one table.

7. **A registry with one row per tool.** `src/tools/registry.zig:82` — the schema,
   the permission flag, the parallel flag, the destructive flag and the result cap
   are all in one place, and the read-only schema is *derived* from the same
   table at comptime (`src/tools/registry.zig:600` `blob`), with a test that
   fails if the two ever disagree (`src/tools/registry.zig:802`). Upstream
   spreads the same facts over the `Tool` interface
   (`code-base/Tool.ts:394-500`), the schema builders, `constants/tools.ts` and
   `tools.ts`.

8. **Ask-mode semantics that produce a decidable answer.** `src/lib/ask.zig:48`
   `declined_text` ("decide yourself and say which") and `:56` `timed_out_text`
   are instructions *to the model*, not empty results. Upstream's
   `AskUserQuestionTool` returns the answers map and nothing else
   (`code-base/tools/AskUserQuestionTool/AskUserQuestionTool.tsx`); a model told
   "the user declined" will stop or repeat, and the upstream schema has no place
   to say what to do instead.

9. **The provider-agnostic substrate.** `src/lib/providers.zig` + the
   Anthropic-native wire format (`src/chat.zig`) mean the *machinery* — the
   registry, the caps, the compaction, the exit gate — is provider-independent by
   construction. Upstream's machinery is entangled with Anthropic-specific
   features: cache breakpoints, `cache_edits`, `defer_loading`,
   `clear_tool_uses_20250919`. Ours can only adopt the *portable* half of
   upstream's ideas, which is a real constraint on the MCP/deferred-loading phase
   (§2.9).

10. **The free-auto rotation.** `src/roster.zig` + `src/free_auto.zig` — the
    harness rotates across the free models of every provider and survives one
    model's quota. Upstream has a classifier-based fallback
    (`code-base/utils/permissions/yoloClassifier.ts`) and a cheap-turn router, but
    no quota-aware pool.

---

## 5. Risks and traps for a Zig port

Concrete hazards found while reading upstream, in the order a port would hit
them.

### 5.1 The permission dialog blocks a worker thread; upstream never blocks

Upstream is single-threaded React: `useCanUseTool` returns a `Promise` that the
UI resolves (`code-base/hooks/useCanUseTool.tsx:32`). The tool execution awaits
it (`code-base/services/tools/toolExecution.ts:921` `resolveHookPermissionDecision`
→ `canUseTool`). The UI pushes a queue item and the user's answer calls back
into the promise (`code-base/hooks/toolPermission/handlers/interactiveHandler.ts:92`
`ctx.pushToQueue`).

Ours blocks a *worker thread* on a mutex plus a `nanosleep` backoff
(`src/tui.zig:1867` `requestPermission` → `waitPermAnswer`). Two consequences
the port must respect:

- **The lock must not be the history's lock.** Ours already has its own
  (`src/tui.zig:987` `perm_epoch`, and the comment at `src/tui.zig:878` about
  "the model lock (which the worker may hold in `requestPermission`)").
- **A "resolve once" guard is mandatory.** Upstream has one explicitly:
  `code-base/hooks/toolPermission/PermissionContext.ts:75` `createResolveOnce`
  with an atomic `claim()` (`:88`) so that two racing resolvers (the user
  clicking *and* an abort firing) cannot both resolve. Ours has the same race
  shape: `src/tui.zig:1897` `answerPermission` can be called twice (ESC and then
  a keypress) and `src/tui.zig:1890` reads `perm_answer` unconditionally. There
  is no claim. **This is a live bug shape, not a hypothetical one.**

### 5.2 The `notified` flag is what makes a notification exactly-once

Upstream's completion notification is guarded by a flag on the task state
(`code-base/tasks/LocalShellTask/LocalShellTask.tsx:110-119`), set inside an
atomic state update, with the comment "Atomically check and set notified flag to
prevent duplicate notifications … If the task was already marked as notified
(e.g., by TaskStopTool), skip enqueueing". A `TaskStop` and a natural completion
can race, and without the flag the model gets two notifications for one task.

Ours has no notification at all, so when Phase 10 adds one this is the trap to
avoid: the flag must live with the task state, not with the notifier.

### 5.3 `Child.kill` reaps; the reader thread also reaps

This one already bit us and is documented in `src/bgproc.zig:74` ("`wait()`
mutates it and `kill()` zeroes its `id`, so it cannot be shared with the registry
slot"). The upstream shape is the same: `killTask`
(`code-base/tasks/LocalShellTask/killShellTasks.ts:16`) and the reader's `wait`
are two reapers of one pid. Upstream avoids the double-reap because the reader
owns the wait. **Keep the reader as the sole reaper** — the port's version of
this is `src/bgproc.zig` `killTree`, which signals and does not reap.

### 5.4 A hook's `allow` must not bypass a `deny` rule

Upstream states this twice and implements it twice
(`code-base/services/tools/toolHooks.ts:373-405` and
`code-base/utils/permissions/permissions.ts:1071` `checkRuleBasedPermissions`).
A hook that says "allow" is an *input* to the permission system, not a decision
that overrides it. If Phase 5 lets a hook's `allow` win outright, the `deny`
rules Phase 6 adds become advisory.

### 5.5 A hook that rewrites the tool's input must not change the transcript

Upstream backfills derived fields on a *shallow clone* so observers (hooks,
`canUseTool`) see the enriched input while the API-bound input is untouched
(`code-base/services/tools/toolExecution.ts:775-793`, with the comment "that
mutation must not reach `call()` because tool results embed the input path
verbatim … changing it alters the serialized transcript and VCR fixture
hashes"). A hook's `updatedInput` is the same hazard: it must reach `call()`
but the *tool result* must reflect what actually happened.

### 5.6 The permission rules must survive the settings reload

Upstream's rules live in a settings file that is re-read; the in-memory context
is updated separately (`code-base/utils/permissions/PermissionUpdate.ts`
`applyPermissionUpdates` / `persistPermissionUpdates`), and a hook's
`updatedPermissions` are persisted *and* applied
(`code-base/utils/permissions/permissions.ts:424-434`). Ours' allowlist is loaded
once (`src/agent.zig:1928` `loadAllowlist`) and saved on change
(`:1976` `saveAllowlist`) — but `reloadUserConfig` (`src/agent.zig:2381`) does
**not** reload the allowlist, so a config reload and an allowlist change can
disagree. Minor today, fatal once the allowlist becomes a rule file.

### 5.7 Do not read the environment from a module global that a test can leave undefined

Upstream's `getAllowedSettingSources` reaches into bootstrap state
(`code-base/utils/settings/constants.ts:159` → `getAllowedSettingSources` in
`code-base/bootstrap/state.ts`). Ours has the same class of bug already fixed
once: `src/agent.zig:1966-1967` ("`environ_global` panicked when the global was
null, which is its normal state in every test that did not set it"). The rule
that keeps holding: **an environment read takes the map as a parameter**, and a
module global is a fallback, not the source.

### 5.8 The rule parser's escape rules are subtle; copy them, do not reinvent them

`code-base/utils/permissions/permissionRuleParser.ts:55-79`:
`escapeRuleContent` escapes backslashes *first* and parentheses second;
`unescapeRuleContent` unescapes parentheses *first* and backslashes last. The
order is the whole thing, and it is the inverse of the escape order. A Zig port
that gets the order wrong turns `Bash(python -c "print\\(1\\)")` into a rule
that matches the wrong commands.

The wildcard matcher has one more subtlety that is easy to miss
(`code-base/utils/permissions/shellRuleMatching.ts:142-145`): a pattern ending
in ` *` with **exactly one** unescaped star matches both `git add` and bare
`git`; with two or more stars it does not (otherwise `* run *` would match
`npm run`). A port that compiles the pattern to a plain glob gets this wrong.

### 5.9 "Permission: none" is a claim about *where the command comes from*, not about the tool

Upstream's `Tool.ts:435` `requiresUserInteraction` and the permission rules make
this explicit: the tool's *own* safety checks (`checkPermissions`) run before the
generic system. Ours encodes the same idea in the registry row
(`src/tools/registry.zig:351` `lsp` is `read_only = true` "because the command
that gets spawned comes from the table in `lsp/servers.zig` … never from the
model: there is no argument a model could put an obligation in"). Any new tool
that spawns a process must make the same argument, and the registry row is where
the argument is written down.

### 5.10 The upstream read-only table is per-*flag*, not per-*command*

`code-base/utils/shell/readOnlyCommandValidation.ts:52-60` excludes `-x/--exec`
from `fd` because "they execute arbitrary commands for each search result", and
`:77-78` excludes `-l/--list-details` because "internally executes `ls` as
subprocess". A Phase 6 table keyed on command names would classify
`fd -x rm` as read-only. **The flag level is the requirement, not a nicety** —
and the exclusions are the interesting part of the table, because they are the
cases where a "read" command runs something else.

### 5.11 A per-message budget that is recomputed breaks the prompt cache

Upstream freezes the decision per result
(`code-base/utils/toolResultStorage.ts:797` `partitionByPriorDecision`) and
reconstructs it on resume (`:960` `reconstructContentReplacementState`), with
the reason at `:833-840`: "Mark non-persisting candidates as seen NOW
(synchronously) … keeps the pair atomic under observation so no concurrent reader
… ever sees X∈seenIds but X∉replacements, which would misclassify X as frozen
and send full content while the main thread sends the preview → cache miss".

Note that upstream's cap layer is not a pure function either — it carries state
across turns. Ours' is (`src/lib/resultcap.zig`), which is why §3.2 is a change
to the *shape* of the module, not a new function.

### 5.12 The permission dialog must not be the only place a decision is visible

Upstream logs every decision with its source
(`code-base/hooks/toolPermission/permissionLogging.ts`, 238 lines) and writes a
`<task-notification>`-style summary for the transcript. Ours shows a modal and
nothing else. When Phase 5 lands and hooks can decide, the decision's *source*
becomes invisible — a hook that silently allows everything would look exactly
like the user clicking "always allow". The record is cheap; add it.

### 5.13 Sandbox exclusion must be applied per subcommand, not per command line

`code-base/tools/BashTool/shouldUseSandbox.ts:60-70` splits compound commands so
`docker ps && curl evil.com` cannot escape the sandbox through its first
subcommand, and `:82-101` iterates the strip operations to a fixed point so
`timeout 300 FOO=bar bazel run` matches `bazel:*`. A Phase 6/25 sandbox that
matches the whole line is bypassable by prefixing a command.

### 5.14 A "deny" rule must remove the tool from the schema, not only block the call

`code-base/tools.ts:262` `filterToolsByDenyRules` strips a denied tool from the
tool list the model sees, using the same matcher as the runtime check
(`code-base/utils/permissions/permissions.ts:238` `toolMatchesRule`) so that
MCP server-prefix rules strip every tool of that server *before* the model sees
it. A `deny` that only blocks at call time still spends the schema tokens and
still shows the model a tool it may not use — and a denied tool in the prompt is
an invitation to try it.

### 5.15 Do not make the permission path depend on a tool that the model can name

Upstream's `Read` is exempt from persistence because "persisting its output to a
file the model reads back with Read is circular"
(`code-base/utils/toolResultStorage.ts:60-64`). Ours' `read` is unbounded
(`src/tools/registry.zig:90` `max_result_chars = 0` → `maxInt`), with the same
reasoning recorded at `src/tools/registry.zig:67-71`. Keep the reason next to
the number: a number without a reason is a number that gets "fixed" later.

---

## Appendix: file counts read

| Area | Upstream (`code-base/`) | Ours (`src/`) |
|---|---|---|
| Tools | 184 files, 43 tool dirs, 29 in `getAllBaseTools` (`tools.ts:193`) | 37 tools in one table (`src/tools/registry.zig:82`), 23 files in `src/tools/` |
| Hooks | 104 files, 27 events (`entrypoints/sdk/coreTypes.ts:25`) | 0 |
| Services | 130 files | — |
| Tasks | 12 files + `Task.ts` + `tasks.ts` | `src/lib/taskstore.zig` + `src/tools/tasks.zig` |
| Context | 9 files (React contexts) | `src/compaction.zig` + `src/lib/resultcap.zig` |
| Memory | 8 files (`memdir/`) + `services/SessionMemory` + `services/extractMemories` + `services/autoDream` | 0 |
| Skills | 20 files | `src/lib/skills.zig` + `src/lib/skillstore.zig` + `src/skills/*.md` |
| Output styles | 1 file | `src/lib/outputstyles.zig` + `src/lib/outputstyle_store.zig` + `src/output_styles/` |
| Plugins | 2 files | 0 |
