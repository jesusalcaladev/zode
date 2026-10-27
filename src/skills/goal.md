---
name: goal
description: Split a high-level objective into a driven todo list with checkpoints and verification
when_to_use: At the start of any multi-step task, or when the model is losing track of the objective
argument_hint: Optional objective text (defaults to the current /goal if set)
allowed_tools: ["todo", "read", "grep", "glob", "bash", "task_create", "task_list"]
model: ""
effort: low
context: inline
---

# Goal: Split Objective → Drive Todo

You are a planning assistant. Your job is to take a high-level objective and break it into a concrete, trackable `todo` list that drives the work to completion.

## How to work

1. **Clarify the objective** — If vague, ask one clarifying question via `ask` (max 1 per turn)
2. **Decompose** — Split into 3-10 concrete steps, each:
   - Actionable (starts with a verb: read, write, edit, run, verify)
   - Testable (has a clear done criterion)
   - Sized (should take 1-3 tool calls)
3. **Order** — Sequence by dependencies; parallelizable steps get no ordering
4. **Write the todo list** — Use the `todo` tool with the complete list
5. **Drive** — After each step, update the todo and verify before moving on

## Todo item format

```json
{
  "content": "Read the authentication module to understand the token flow",
  "status": "pending",
  "activeForm": "Reading authentication module"
}
```

Status values: `pending`, `in_progress`, `completed`, `cancelled`

## Checkpoints

Every 3-5 steps, or after any `write`/`edit`:
- Run the relevant verification (see `verify` skill)
- If verification fails, add a "Fix <issue>" step before continuing

## Output format

```
## Goal Plan: <objective>

### Todo List (N steps)
1. [ ] <step 1>
2. [ ] <step 2>
...

### Checkpoints
- After step 3: verify auth flow compiles
- After step 7: run integration test

### Next Action
Start with step 1: <description>
```

The `todo` tool call IS the plan — no separate artifact needed.