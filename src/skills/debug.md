---
name: debug
description: Reproduce a failure, isolate the root cause, and apply a minimal fix — use when a test fails, a build breaks, or an error cannot be explained
when_to_use: When a test fails, a build/typecheck breaks, a command errors, or behavior is wrong and the cause is not obvious. Load this before guessing or making speculative edits.
argument_hint: Optional error message, failing test name, file path, or command to investigate
allowed_tools: ["bash", "read", "grep", "glob", "check", "bash_output", "bash_kill", "edit", "write"]
model: ""
effort: medium
context: inline
---

# Debug: Reproduce → Isolate → Fix

You are debugging inside zode. Your job is to take a real failure, find its root cause from evidence, and apply the smallest fix that resolves it — then verify the fix.

**Target (from args):** $ARGUMENTS

If `$ARGUMENTS` is empty, identify the failure from the current conversation, the last tool error, or by running the project’s narrowest failing check.

## Non-negotiable rules

- **Never guess.** Every claim needs evidence: a command, output, file location, or reproducible symptom.
- **Reproduce before editing.** If you cannot reproduce the failure, say exactly what you tried and what blocked reproduction.
- **Fix the cause, not the symptom.** Do not silence errors, add broad try/catch/ignore, or weaken tests unless the test is demonstrably wrong and you explain why.
- **Keep the fix minimal.** Change only what is needed. Preserve surrounding style and behavior.
- **Verify after fixing.** A fix without a passing verification is not done.

## Workflow

### 1) Capture the failure
- Record the exact failing command, test, file, line, and error text.
- If the failure is a type/build error in a known project, prefer `check` (optionally with `subdir`) over guessing `zig build`/`tsc`/`cargo check`.
- For long commands (>10s), run `bash` with `run_in_background: true` and a short `description`, then poll with `bash_output` (or `check id` for `check`). Do not loop-sleep; check once when you need the result.

### 2) Reproduce reliably
- Run the narrowest command that reproduces the issue (one test, one file, one target).
- For Zig tests: `zig test path/to/file.zig -Dtest-filter="test name"` (quote names with spaces/special chars).
- For project builds/tests, use the project’s real command/marker — read `build.zig`, `package.json`, `Cargo.toml`, etc. if unclear.
- If reproduction is flaky, run the same narrow command a few times and report the pattern.

### 3) Isolate the cause
- Narrow scope before changing code: which file, function, input, or state triggers it?
- Use `read`/`grep`/`glob` to inspect code paths and related tests.
- Form a specific hypothesis: *“X fails because Y under condition Z, evidenced by …”*.
- If the hypothesis is wrong, update it from new evidence — do not stack guesses.

### 4) Apply the minimal fix
- Make the smallest safe change that addresses the root cause.
- Use `edit` for targeted changes; `write` only when replacing a file is truly simpler/safer.
- Do not refactor unrelated code while debugging.

### 5) Verify
- Re-run the exact reproduction command first.
- Then run the next narrowest relevant check (related tests, or `check` for type errors) if appropriate.
- Report pass/fail with command and key output. If it still fails, return to isolation with the new evidence.

## Output format

```text
## Debug: <short failure summary>

### Target
$ARGUMENTS

### Reproduce
- Command: `<exact command>`
- Result: <exit/status + key error lines>
- Evidence: <file:line or output excerpt>

### Isolate
- Scope: <file/function/test>
- Hypothesis: <specific cause>
- Why: <evidence>

### Fix
- Change: <what changed, where>
- Risk: <what could still break / none>

### Verify
- Command: `<exact command>`
- Result: PASS / FAIL
- Details: <key output>

### Status
FIXED | NOT FIXED | BLOCKED
Next: <only if not fixed>
```

If blocked (cannot reproduce, missing dependency, permissions, or ambiguous intent), be explicit and give the single most useful next action.
