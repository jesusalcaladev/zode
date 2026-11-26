# Mission runtime — gaps vs `opencode-mission`

This is an honest delta between the zode core mission runtime (`zode mission`)
and the OpenCode plugin as of plugin commit `6fc066f`. Items are ordered by impact.

## 1. Speed

- ~~**Parallel cached checks.**~~ **DONE.** `src/mission/io.zig` now runs up to
  `max_parallel_checks` (3) criteria in each batch and caches verdicts in
  `.mission/checks-cache.json`, keyed by a workspace fingerprint (path + size +
  mtime, excluding `.mission`) plus the criteria signature. An unchanged suite
  is not re-run. The remaining difference: the cache is all-or-nothing per
  mission (any workspace change re-runs every check) and it does not model
  environment or network dependencies.
- ~~**Event-driven worker completion.**~~ **DONE.** `callWorkers` now runs one
  thread per worker with an explicit `.mission/prompts/task-N.done` /
  `.failed` marker on exit, instead of a `sh -c '… & …; wait'` aggregate. The
  remaining difference: zode does not expose a `mission_task_done` tool call —
  workers announce completion in their final answer and the harness records
  the marker.

## 2. Intelligence

- ~~**Model per role.**~~ **DONE.** `ZODE_MISSION_FAST_MODEL` serves read-only
  roles (investigator, reviewer, auditor, tester); implementers and workers
  keep the lead model from `ZODE_MISSION_MODELS`. `ZODE_MISSION_MODELS_BY_ROLE`
  accepts `role=model,…` overrides (case-insensitive role, last wins).
  Remaining difference: the plugin can change models per brief; zode resolves
  them once per turn.
- ~~**Project instructions.**~~ **DONE.** `src/mission/runner.zig` reuses
  `src/lib/instructions.zig` and injects the `CLAUDE.local.md` / `AGENTS.md` /
  `CLAUDE.md` hierarchy (plus the user-level file) into lead, worker and role
  prompts, capped at 12 KB. Remaining difference: the plugin may re-read rules
  per brief; zode loads them once per `mission run`.
- ~~**Durable fact store.**~~ **DONE.** `.mission/facts.json` holds structured
  `{kind, subject, text}` facts (`check`, `task`, `review`, `state`), keyed by
  kind+subject and capped at 64. They are harness-confirmed (check verdicts,
  task completion, review outcome), rendered into a 4 KB prompt block, and
  survive compaction and restarts. zode does not expose an agent-writable
  `mission_fact` call — model assertions are deliberately excluded.

## 3. Reliability

- ~~**Automatic improvement rollback.**~~ **DONE.** Before an improvement
  task the runner records HEAD and the green count in `state.json`. If a later
  turn is less green, it reverts exactly the checkpoint the improvement
  created (never the baseline) and journals the outcome.
- ~~**Second-opinion review.**~~ **DONE.** Two independent reviewers write
  `.mission/reports/reviewer.txt` and `reviewer2.txt`; both reports gate the
  review stage, so one false `SEVERITY: high` no longer reopens the work alone.
- ~~**Test guard scope.**~~ **DONE.** `hashTestsFor` hashes only test files under
  the `files` declared by tasks; unrelated edits no longer trigger
  `test-erosion`. Missions with no declared files keep the strict whole-tree
  baseline.

## 4. UX

- **TUI part.** Neither harness exposes mission progress in the terminal UI.
  OpenCode plugins support a `./tui` part; zode could add a status line driven by
  `.mission/state.json`.
- ~~**Progress / cost dashboard.**~~ **DONE.** `zode mission status` now prints
  ASCII progress bars for checks and tasks, cost spend vs budget with a
  percentage, improvement cycles, clean audits and failures. No ETA is shown:
  elapsed-per-turn history is not recorded, so guessing one would invent data.

## 5. Code quality

- The zode runtime still duplicates a few decisions that already exist in the
  interactive core (`exitgate`, `taskloop`, `team`, `pipeline`). The long-term
  goal is one shared decision layer for both interactive and mission modes.
- Parity tests: the plugin has 80 tests including cache, facts, instructions and
  scoped commits; zode's mission tests cover contracts and IO but not these.

## Suggested order

1. ~~Parallel + cached checks in `src/mission/io.zig`.~~ DONE.
2. ~~Reuse `instructions.zig` in the runner and add a fact store.~~ DONE.
3. ~~Automatic `git revert` for failed improvement cycles.~~ DONE.
4. TUI status line and progress bar.
5. Unify mission decisions with `exitgate`/`taskloop`.
