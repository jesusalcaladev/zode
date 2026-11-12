---
name: skillify
description: Turn a repeated, stable workflow into a reusable zode SKILL.md with clear trigger criteria and correct frontmatter
when_to_use: When the same multi-step process has appeared 3+ times, has stable steps/tool usage, and can be described with clear “when to use” criteria. Load this before writing a new skill from memory.
argument_hint: Optional skill name (lowercase letters/digits/hyphens/underscores) and/or a short description of the workflow
allowed_tools: ["write", "read", "glob", "grep", "bash"]
model: ""
effort: low
context: inline
---

# Skillify: Capture a Repeatable Workflow as a Skill

You create a `SKILL.md` that zode can discover and load on demand. A good skill saves future turns by making the trigger and procedure explicit.

**Request (from args):** $ARGUMENTS

If `$ARGUMENTS` names a skill, use it (normalize to a valid name: lowercase/digits/`-`/`_`, max 64 chars). If the workflow is unclear, ask for the missing details **only if you cannot infer them safely**; otherwise infer from context and state assumptions.

## When to create a skill

- The workflow repeats (3+ times) or is clearly reusable.
- It has a stable sequence, constraints, or tool pattern.
- It has an obvious trigger (“when to use”).
- It benefits from being loaded only when relevant (keeps prompts cheap).

Do **not** create a skill for one-off tasks, rapidly changing procedures, or vague advice with no actionable steps.

## zode skill format

Write `SKILL.md` in a directory named after the skill:

- Project skill (preferred for repo-specific workflows): `.zode/skills/<name>/SKILL.md`
- Personal skill: `~/.config/zode/skills/<name>/SKILL.md` (only if the user asked for a personal/global skill)

Frontmatter fields zode understands:

```markdown
---
name: <short-name>
description: <what the user/model sees in listings; say WHEN to use it, not just what it is>
when_to_use: <detailed trigger criteria>
argument_hint: <optional args the skill accepts>
allowed_tools: ["read", "grep", "glob", "bash"]  # optional; restrict to what is needed
model: ""       # optional
effort: low     # optional: low|medium|high
context: inline # inline or fork (fork runs in a subagent; avoid if the skill must edit/write)
---
```

## Authoring rules

- **Description is the trigger.** Write it so the model can decide correctly before loading the body.
- **Body is instructions, not marketing.** Be specific, ordered, and defensive.
- **Use `$ARGUMENTS` when useful.** zode substitutes `$ARGUMENTS`, positional `$1`/`$2`, and named `$name` from `name=value` args.
- **Choose `context` carefully.** Use `inline` when the skill may need to edit files or interact with the full session. Use `fork` only for read/analysis-style skills that can run in a subagent.
- **Least privilege tools.** Include only tools the workflow actually needs.
- **Include failure handling.** Say what to do when inputs are missing, commands fail, or results are ambiguous.
- **Keep it maintainable.** Prefer clear steps over long prose; avoid project-specific paths unless the skill is project-scoped.

## Workflow

1. Identify the repeated task, trigger, inputs, tools, outputs, and failure modes.
2. Pick a valid name and the correct location (`.zode/skills/<name>/SKILL.md` for this project unless told otherwise).
3. Read an existing skill if helpful (`glob`/`read` `.zode/skills/*/SKILL.md`) to match local style.
4. Write the `SKILL.md` with frontmatter + clear instructions.
5. Sanity-check: frontmatter present, name valid, description states *when* to use, `context` matches tool needs, and `$ARGUMENTS` used where appropriate.
6. Tell the user how to invoke it: load the `skill` tool with `name: "<name>"` (and optional `args`).

## Output format

```text
## Skill Created/Updated: <name>

- Location: <path>
- Description (trigger): <description>
- When to use: <when_to_use>
- Context: inline|fork
- Allowed tools: <list or "default">
- Args: <argument_hint or "none">

How to use:
- Call the `skill` tool with `name: "<name>"` and optional `args: "<$ARGUMENTS example>"`.

Assumptions / follow-ups:
- <any>
```
