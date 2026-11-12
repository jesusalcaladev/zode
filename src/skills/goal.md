---
name: goal
description: Split a high-level objective into a concrete todo plan and drive it step by step with verification checkpoints
when_to_use: At the start of any multi-step task, when the objective is ambiguous, or when work has lost track of what “done” means. Load this before making scattered edits.
argument_hint: Optional objective text (if empty, use the current request or active /goal)
allowed_tools: ["todo", "read", "grep", "glob", "bash", "check", "ask", "task_create", "task_list"]
model: ""
effort: low
context: inline
---

# Goal: Decompose → Track → Verify → Finish

You turn a high-level objective into a concrete, trackable plan that the user can follow. The `todo` tool is the live plan — keep it accurate.

**Objective (from args):** $ARGUMENTS

If `$ARGUMENTS` is empty, use the user’s current request. If the objective is still unclear, ask **one** precise question with `ask` (put your recommendation first). If the user presses Esc, choose the recommended option, state it, and continue.

## Planning rules

- **Make steps concrete.** Each step starts with a verb and names the target (file, command, module, behavior).
- **Make steps testable.** Each step has a clear done criterion (command passes, file changed as specified, output observed).
- **Keep steps small.** Aim for 1–3 tool calls per step. Split large steps.
- **Order by dependency.** Independent steps can be adjacent but should not create hidden ordering assumptions.
- **Do not pad.** Use 3–10 steps when possible. For trivial tasks, do not force a todo list.

## zode `todo` tool (use the real schema)

`todo` accepts `items` (whole list, replaces previous), `update` (1-based index changes), `remove` (1-based indexes), and `add` (append). Status values are exactly: `pending`, `in_progress`, `done`.

- Send the full plan once with `items`.
- While working, prefer `update` (e.g. mark current step `done`, next `in_progress`) instead of resending the whole list.
- Keep **exactly one** step `in_progress` while actively working; never more than one.
- When everything is done, clear/complete the list so the UI does not show stale work.

Example full list:

```json
{
  "items": [
    {"content": "Read src/foo.zig and locate the failing path", "status": "in_progress"},
    {"content": "Edit src/foo.zig to fix the root cause", "status": "pending"},
    {"content": "Run zig test src/foo.zig -Dtest-filter=\"foo\"", "status": "pending"}
  ]
}
```

Example incremental update:

```json
{
  "update": [
    {"index": 1, "status": "done"},
    {"index": 2, "status": "in_progress"}
  ]
}
```

## Checkpoints and verification

- After any `write`/`edit`, or every 3–5 steps, run the narrowest relevant verification.
- Prefer `check` for type errors in supported projects; use `bash` for targeted tests/commands.
- If verification fails, add or insert a fix step (do not mark downstream steps done). Fix first, then continue.
- Do not declare the objective complete until verification evidence supports it.

## Output format

```text
## Goal
<objective>

## Plan
- N steps tracked with `todo`
- Checkpoints: <when/how you will verify>

## Next
<the single next action you are taking now>
```

Then call `todo` with the plan and begin step 1.
