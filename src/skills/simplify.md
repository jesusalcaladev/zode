---
name: simplify
description: Review recent or targeted code for duplication, unnecessary complexity, and safe reuse opportunities; suggest concrete simplifications without changing behavior
when_to_use: After a non-trivial write/edit, when code feels repetitive or hard to follow, or when asked to clean up a file/diff. Load this before refactoring by intuition.
argument_hint: Optional file path, directory, or scope to review (defaults to the last edited/mentioned code)
allowed_tools: ["read", "grep", "glob", "bash"]
model: ""
effort: low
context: inline
---

# Simplify: Reduce Complexity, Preserve Behavior

You review code for simplification opportunities. Your goal is **clarity and maintainability** with **no behavior change** unless the user explicitly asked for a behavior change.

**Scope (from args):** $ARGUMENTS

If `$ARGUMENTS` is empty, focus on the most recently changed files or the code under discussion. If you cannot identify scope, say so and inspect the likely files with `read`/`glob`/`grep` (and `git diff --name-only` / `git diff` via `bash` when helpful).

## What to look for

- **Duplication with intent:** repeated logic that can become a small helper with a clear name and signature.
- **Overly complex conditionals:** nested branches, repeated guards, or boolean soup that can be flattened safely.
- **Dead or misleading structure:** unused helpers, redundant wrappers, or abstractions that add indirection without value.
- **Local consistency issues:** naming/style that diverges from the surrounding file in ways that hurt readability.

## Guardrails

- **Do not invent changes.** Base suggestions on code you actually read.
- **Prefer small, safe extractions.** Avoid clever abstractions that obscure control flow.
- **Respect project conventions.** Follow the language/framework style already used nearby.
- **Do not “simplify” away correctness.** Keep error handling, edge cases, tests, and invariants intact.
- **Call out risk.** If an extraction could change semantics (ownership, lifetimes, error propagation, ordering, performance), say so.
- **If the code is already clean, say so.** Do not manufacture work.

## How to work

1. Identify the target files and read enough surrounding context.
2. Find repeated patterns (2+ occurrences) or complexity hotspots.
3. Propose specific changes: where, what repeats, suggested function/structure, and impact.
4. Prioritize high-confidence, low-risk improvements. Keep the report short and actionable.

## Output format

```text
## Simplification Report

### Scope
<files/paths reviewed>

### Opportunities
1. **<title>** (`path:line-line`, ...)
   - Pattern: <what repeats / what is complex>
   - Suggestion: <concrete change, e.g. extract `fn name(args) -> T`>
   - Benefit: <clarity / duplication removed>
   - Risk: <none / specific risk>

### Already clean
<areas with no worthwhile simplification, if any>

### Next step
<smallest safe change to apply first, or “no changes recommended”>
```

If there are no good opportunities:

```text
## Simplification Report

### Scope
<files/paths reviewed>

No simplifications recommended — the code is already clear and non-redundant for its current purpose.
```
