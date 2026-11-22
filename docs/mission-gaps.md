# Mission runtime — gaps vs `opencode-mission`

This is an honest delta between the zode core mission runtime (`zode mission`)
and the OpenCode plugin as of plugin commit `6fc066f`. Items are ordered by impact.

## 1. Speed

- **Parallel cached checks.** The plugin runs criteria with bounded parallelism
  (`maxParallel`, default 3) and skips unchanged suites using a workspace
  fingerprint (paths + mtime + size) plus a criteria signature. zode's
  `mission_io.runChecks` is still sequential and re-runs everything every turn.
- **Event-driven worker completion.** The plugin finishes workers through the
  `mission_task_done` tool; zode still uses a fixed timeout wait.

## 2. Intelligence

- **Model per role.** Plugin: `fastModel` for read-only roles, `model` for
  implementers, `modelsByRole` overrides. zode uses one agent command/model.
- **Project instructions.** Plugin injects the `AGENTS.md` / `CLAUDE.md`
  hierarchy into every brief. zode's mission runner does not load them, even
  though `src/lib/instructions.zig` already exists and could be reused.
- **Durable fact store.** Plugin has `mission_fact(kind, subject, text)` with
  structured facts that survive compaction. zode keeps only distilled text.

## 3. Reliability

- **Automatic improvement rollback.** Plugin reverts the checkpoint when an
  improvement cycle breaks verification (`gitRevert`). zode journals the
  failure but does not revert.
- **Second-opinion review.** Both use a single reviewer; a second independent
  review would reduce false positives on `SEVERITY: high`.
- **Test guard scope.** zode hashes every test file in the workspace; unrelated
  edits can trigger `test-erosion`. It should hash only `files` owned by tasks.

## 4. UX

- **TUI part.** Neither harness exposes mission progress in the terminal UI.
  OpenCode plugins support a `./tui` part; zode could add a status line driven by
  `.mission/state.json`.
- **Progress ETA / cost dashboard.** Plugin now prints a progress bar and
  improvement cycles in `/mission status`; zode's `mission status` is plain text.

## 5. Code quality

- The zode runtime still duplicates a few decisions that already exist in the
  interactive core (`exitgate`, `taskloop`, `team`, `pipeline`). The long-term
  goal is one shared decision layer for both interactive and mission modes.
- Parity tests: the plugin has 80 tests including cache, facts, instructions and
  scoped commits; zode's mission tests cover contracts and IO but not these.

## Suggested order

1. Parallel + cached checks in `mission_io.zig`.
2. Reuse `instructions.zig` in the runner and add a fact store.
3. Automatic `git revert` for failed improvement cycles.
4. TUI status line and progress bar.
5. Unify mission decisions with `exitgate`/`taskloop`.
