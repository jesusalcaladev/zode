# Missions in zode (headless supervisor)

This is the zode port of the `opencode-mission` plugin contract. It uses the same
on-disk `.mission/` layout, so a mission directory can move between the two
harnesses. See `CONTRACT.md` in that repository for the full host-agnostic spec.

## Principle

The model proposes work and verdicts. The **harness** re-runs executable criteria
and is the only writer of `status: complete` in `.mission/state.json`. A red check
always beats a model that says it is done. The kill switch, budgets and failure
ceiling are checked before the completion branch.

## Build

```bash
zig build mission            # installs ./zig-out/bin/zode-mission
zig build test               # includes the mission unit tests
```

## Use

```bash
# Create a workspace with a heuristic plan derived from the objective.
./zig-out/bin/zode-mission plan "Create alpha.txt containing alpha and beta.txt containing beta"

# Inspect, verify, and drive the agent until the criteria are green.
./zig-out/bin/zode-mission status ./missions/<id>
./zig-out/bin/zode-mission check  ./missions/<id>
./zig-out/bin/zode-mission run    ./missions/<id>
```

`run` repeats: run checks → write evidence → apply task results → decide → append
the journal → call the agent with a failure nudge. It stops on `complete`, a `STOP`
file, the turn/cost ceiling, `max_failures`, or a `blocked` verdict.

### Environment

| Variable | Default | Meaning |
| --- | --- | --- |
| `ZODE_MISSION_AGENT` | `zode --chat` | Command used for each lead/worker turn; the prompt is appended as the last argument |
| `ZODE_MISSION_WORKERS` | `1` | Parallel workers per wave. `>1` spawns one background agent per ready task, grouped by disjoint `files` |
| `ZODE_MISSION_PLANNER` | unset | Set to any value to ask the agent for a JSON plan; falls back to the heuristic plan on error |
| `ZODE_MISSION_MODELS` | unset | Comma-separated model ids. On a failed turn the driver rotates to the next one by setting `ZODE_MODEL` for the child |

With workers enabled the driver writes one prompt per task under
`.mission/prompts/` and starts them in the same shell wave. The lead receives the
failure summary afterwards. The harness still owns verification and completion.

## Recovery and integrity

- A failed agent turn increments `failures`, backs off (2s, 4s, 8s… capped at 30s),
  rotates to the next model in `ZODE_MISSION_MODELS`, and retries. After
  `max_failures` the mission aborts with `repeated-execution-failure` instead of
  spinning.
- Before each decision the driver hashes every test file in the workspace and
  stores the baseline in `state.json` as decimal strings (64-bit FNV fits in a
  string, not in a JSON `i64`). Editing or deleting a test that existed at the
  start aborts with `test-erosion`. Adding tests is allowed.
- `plan` with `ZODE_MISSION_PLANNER` asks the agent for a JSON plan and validates
  it: unsafe commands (`sudo`, `rm -rf /`, pipes to shell), bad ids, path
  traversal and missing `verify` checks are rejected before anything is written.

## Files

```text
<workspace>/.mission/
  mission.md        objective + frontmatter (max_turns, budget_usd)
  criteria.json     [{id, cmd, expect, timeout_ms}]   <- definition of done
  tasks.json        [{id, subject, files, verify, blocked_by, status}]
  state.json        durable supervisor state
  journal.md        append-only memory
  evidence/*.txt    stdout, stderr, exit, expectation per check
  prompts/*.txt     worker prompts (when workers are enabled)
  STOP              kill switch
```

`expect` is `exit0` or `contains:<text>` (exit 0 **and** substring in stdout).

## Code map

- `src/lib/mission.zig` — pure contract: decision, criteria evaluation, task graph,
  wave scheduling, heuristic planner. No IO, no model, no TUI.
- `src/lib/mission_io.zig` — persistence, criteria runner (`std.process.run` with
  `/bin/sh -c` and `cwd` = workspace), journal, git checkpoint.
- `tools/mission.zig` — headless CLI (`plan`, `status`, `check`, `run`).

## Differences from zode's native loop

zode already has `/goal`, `taskloop.zig`, `exitgate.zig`, `taskstore.zig`,
`team.zig`, `pipeline.zig`, `testguard.zig` and `checkpoint.zig`. This port adds the
one thing those do not provide on their own: **criteria that the harness runs as
shell commands**, with evidence on disk and a supervisor that survives process
restarts. It is deliberately a separate executable so the TUI and the interactive
agent loop are untouched.

## Safety

Criteria commands run in a shell with the workspace as cwd. Only run missions
whose `criteria.json` you trust. The planner rejects nothing here by itself —
review the generated checks before running a mission you did not author.
