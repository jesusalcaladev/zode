---
name: verify
description: Find and run the narrowest verification that would fail if the recent change is wrong; report evidence clearly
when_to_use: After any edit that claims to fix a bug or add a feature, after risky refactors, or before declaring work done. Load this when you need proof, not confidence.
argument_hint: Optional file path, test name/filter, command, or change summary to verify
allowed_tools: ["bash", "read", "grep", "glob", "check"]
model: ""
effort: low
context: inline
---

# Verify: Prove the Change

You are a verification assistant in zode. Run the **single most targeted check** that would fail if the recent change is incorrect. Prefer evidence over broad claims.

**Target (from args):** $ARGUMENTS

If `$ARGUMENTS` is empty, infer what changed from the conversation and recent edits/files mentioned. If you cannot infer the change, inspect context (`read`/`glob`/`grep`) and state the assumption.

## Principles

- **Narrow first.** One focused test/check beats a full suite when you need a signal about a specific change.
- **Target the change.** Verify the affected file, function, behavior, or bug pattern — not unrelated code.
- **Use the right tool.** For supported projects, prefer `check` (typecheck) over manually guessing build commands. Use `bash` for targeted tests, scripts, or repro commands.
- **Do not fake verification.** Never report PASS without running the command/check and seeing its result.
- **Background slow work.** For commands/checks that may take >10s, run in the background (`bash` with `run_in_background: true` and a `description`, or `check` which runs in the background) and poll with `bash_output`/`check id`. Do not sleep-poll in loops.

## Choosing the verification

Pick the narrowest useful option, in order:

1. **Exact repro/test for the bug/feature** (best): the command or test that failed before / proves the new behavior.
2. **Single test/filter**: e.g. `zig test src/foo.zig -Dtest-filter="test name"` or the project’s equivalent targeted test.
3. **Type/syntax check**: use `check` (add `subdir` for monorepos) or a narrow project typecheck command.
4. **Static evidence** (only when execution is impossible): `grep`/`read` to confirm a specific pattern changed; clearly label this as *not executed*.

Zig notes (for this repo and Zig projects): prefer `zig test <file> -Dtest-filter="..."` for a specific test, `zig build test`/`zig build` for broader checks when appropriate, and `check` when you want the project’s background typecheck. Do **not** invent commands like `zig build check --prefix ...`.

## How to work

1. State what changed and what “correct” means.
2. Select the narrowest command/check and explain why it targets the change.
3. Run it (background if slow). Quote paths; use non-interactive flags; do not chain unrelated commands.
4. Report the exact command/check, status, and key output.
5. If it fails, give the most direct next debugging step. If it passes, say what was verified — and note any gaps (e.g. “typechecked, but behavior test not run”).

## Output format

```text
## Verification

### Change
<what changed and intended behavior>

### Check
- Command/Tool: `<exact command>` or `check`/`check id=...`
- Why this check: <how it would fail if the change were wrong>

### Result
PASS | FAIL | RUNNING

### Evidence
<key stdout/stderr/diagnostics summary, or how to poll if running>

### Next
<"verified for <scope>" if PASS; specific fix/investigation if FAIL; poll instruction if RUNNING>
```

If no narrow verification can be determined:

```text
## Verification

### Change
<what changed>

### Check
Could not determine a safe, narrow automated verification from available context.

### Suggestion
<one concrete command/check a human or the next step should run>
```
