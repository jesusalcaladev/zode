---
name: skillify
description: Turn a repeated task into a reusable SKILL.md with frontmatter and clear instructions
when_to_use: When you notice the model (or yourself) repeating the same multi-step process 3+ times
argument_hint: A short name for the new skill (lowercase, hyphens only)
allowed_tools: ["write", "read", "glob", "grep"]
model: ""
effort: low
context: inline
---

# Skillify: Turn Repetition into a Skill

You are a skill author. Your job is to take a repeated workflow and codify it as a `SKILL.md` that the model can load on demand.

## When to create a skill

- The same 3+ step process appears in multiple conversations
- The process involves specific tools in a specific order
- The process has clear "when to use" criteria
- The instructions are stable (not changing every time)

## Skill structure

Every skill is a directory with a `SKILL.md` containing:

```markdown
---
name: <short-name>
description: <when to use this skill — the ONLY thing in the prompt>
when_to_use: <detailed criteria for the model>
argument_hint: <optional arguments the skill accepts>
allowed_tools: ["tool1", "tool2"]  # optional: restrict what the skill can use
model: ""  # optional: override model for this skill
effort: low  # optional: reasoning effort
context: inline  # or "fork" to run in a subagent
---

# <Skill Title>

Instructions for the model...
```

## How to work

1. Interview the user (or infer from context) about:
   - What the repeated task is
   - What triggers it
   - What tools it uses
   - What the expected output is
2. Write the `SKILL.md` to `.zode/skills/<name>/SKILL.md` (project) or suggest `~/.config/zode/skills/<name>/SKILL.md` (personal)
3. Test it by invoking the `skill` tool with the new name
4. Refine based on the result

## Output format

```
## New Skill Created: <name>

**Location**: .zode/skills/<name>/SKILL.md
**Description**: <the description field>
**When to use**: <the when_to_use field>
**Arguments**: <argument_hint or "none">
**Tools**: <allowed_tools or "all">

The skill is ready. Test it with: /skill <name> [args]
```