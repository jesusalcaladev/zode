# Zode — Terminal-Native Development Environment (TUI Design Rules)

**Project:** Zode  
**Language:** Zig 0.17+  
**TUI framework:** Vaxis 0.6 (pure Zig)  
**Architecture:** Preserve the existing Zode architecture. This is an evolution, not a rewrite.  
**Status:** Living design guide. Phase 1 is in progress.

This document adapts the terminal-native development environment direction to Zode's actual codebase, theme system, and `AGENTS.md` rules. It is a design/reference guide for incremental work, not a mandate to implement every section at once and not a substitute for tests.

---

## 1. Product vision

Evolve Zode from a conversational terminal coding agent into a sophisticated terminal-native development environment while preserving Zode's identity, performance, architecture, and operational behavior.

The terminal remains the primary interface. Do not introduce unnecessary GUI-like dashboards.

The experience should combine, incrementally:

- AI-assisted development.
- Rich conversation rendering.
- Structured tool execution.
- File intelligence.
- Interactive code review.
- Git awareness.
- Permission and question management.
- Context inspection.
- Streaming responses.
- Session and process management.
- Agent/task orchestration where supported.

**The terminal is the development environment, not merely a place where messages are printed.**

### Design philosophy

1. Preserve the existing Zode identity.
2. Maximum information density without visual noise.
3. Borderless-first interface.
4. Contextual visual components.
5. Keyboard-first interaction; mouse support is additive where already practical.
6. Incremental rendering.
7. Subtle directional motion only when safe, measurable, and disableable.
8. Real-time operational transparency.
9. Terminal-native performance.
10. No unnecessary dependencies. Pure Zig/std where possible; existing deps only (Vaxis).

---

## 2. Preserve existing Zode identity

Do not replace Zode with a generic Claude Code, Codex, or IDE-inspired theme.

### Existing visual characteristics to preserve

- Near-black / terminal-native background behavior (surfaces generally let the terminal background show through).
- Electric teal accent as the single brand accent.
- Monospace typography.
- Minimal separators.
- Open conversation layout.
- Compact status/footer information.
- Discrete event indicators.
- Syntax-highlighted code.
- Inline tool activity.
- Existing streaming behavior.
- Mascot/phase cues where they already exist.

New UI must feel like a more sophisticated version of Zode.

### Color and theme source of truth

**Do not introduce a duplicate color system.** The source of truth is `src/lib/theme.zig`.

`theme.zig` defines semantic roles, not ad hoc decoration:

- **Ink:** `ink`, `ink2`, `ink3` for readable text hierarchy.
- **Lines:** `line`, `line_bright`, `rule`, gutters/rails for separators and structure (lines are not text).
- **Brand/accent:** `brand`, `brand_hi`, `brand_soft`, `input_prompt` (electric teal family). Brand marks interaction, focus, prompts, and the user's active context.
- **Semantics:** `ok`, `warn`, `err` are semantic, not decorative, and must remain distinguishable from brand/syntax roles.
- **Diff:** diff roles and `diffStyles(caps)` including daltonized blue/orange support.
- **Code:** syntax palette kept outside the accent hue band.
- **Surfaces/selection:** `panel_bg`, `well_bg`, `selected`, `sel_bg` follow terminal-native behavior.
- **Capabilities:** `caps`, `detectCaps`, `resolve`, `resolveStyle`, ANSI256 ladder, `NO_COLOR`, `ZODE_DALTONIZED`.

When this document mentions colors, interpret them as theme roles:

| Intent | Theme role guidance |
|---|---|
| Active input, selection, focus, streaming, current navigation | `brand*`, `input_prompt`, `selected` |
| Primary/secondary/tertiary text | `ink`, `ink2`, `ink3`, role aliases as appropriate |
| Success/completed/valid | `ok` |
| Permission/warning/pending/attention | `warn` |
| Error/failure/destructive | `err` |
| Metadata/inactive/hints | `ink3`, `hint`, `key_hint`, `status`, `notice` |
| Add/remove/modify in diffs | `diff*` / `diffStyles(caps)` |

### Color rules

- Never use colors without semantic meaning.
- Never communicate a critical state through color alone. Use text, markers, weight, labels, or structure.
- Support terminal-native behavior, 16/256/truecolor paths as implemented by theme capabilities.
- Preserve contrast invariants and theme tests in `src/lib/theme.zig`.

---

## 3. Borderless-first design

Avoid unnecessary ASCII boxes. Preserve Zode's open layout.

Prefer:

- Whitespace.
- Indentation.
- Semantic colors.
- Hierarchical alignment.
- Subtle separators.
- Compact inline components.
- Contextual highlighting.

Borders are allowed when they improve interaction or distinguish a special component.

### Border usage hierarchy

No border by default.

Subtle/functional borders may be used for:

- Interactive diff/review surfaces.
- Permission dialogs.
- Question/ask panels and focused selectors.
- Expanded code/file inspection surfaces.
- Command/model palettes and focused overlays.

Avoid borders for:

- Normal messages.
- Routine tool events.
- Simple file summaries.
- Ordinary status/metadata.
- Completed low-emphasis operations.

A border must communicate a functional boundary, not decoration.

---

## 4. Main conversation workspace

Preserve the existing conversation-first structure.

The primary workspace consists of:

1. Conversation history.
2. User messages.
3. Assistant responses.
4. Structured tool events.
5. Inline interactive components where appropriate.
6. File change components.
7. Input composer.
8. Persistent status/footer.

Conceptual structure (illustrative, not a fixed layout):

```text
  › Implement a complete authentication system.

  ◉ read  src/auth/
    18 files inspected

  ◉ edit  src/auth/session.ts
    1 hunk · 3 replacements

  ◈ session.ts  +24 -8  ·  src/auth
  ◈ Login.tsx   +42 -5  ·  src/components

  ✓ Verification completed
    typechecked / tested as reported by the harness or tools

  ─────────────────────────────────────────────

  › Ask anything...                  / for commands

  ( ✓ ) done · model-name · ctx 42% · cache warm
```

The workspace must adapt to terminal dimensions.

### Conversation rules

- Preserve message ordering.
- Preserve streaming behavior.
- Avoid full-screen redraws for ordinary updates.
- Support long responses.
- Support Markdown.
- Support syntax highlighting (`src/lib/highlight.zig`, `src/lib/markdown.zig`).
- Support expandable tool output where implemented.
- Preserve user scroll position.
- Automatically follow the latest output only when appropriate.

Do not force the user to follow the bottom of the conversation when inspecting historical content. When new output arrives while the user is scrolled up, show a subtle new-content indicator.

### Existing Zode behavior to preserve

- Harness-authored prompts go into the session as user messages through the established session path (`AGENTS.md`: `appendHarnessPrompt` is the one door).
- The ceiling turn gets no tools and must not end in silence.
- Scroll anchor behavior is paragraph/offset based, not absolute line numbers tied to stale heights.

---

## 5. File intelligence system

A major target feature, to be implemented incrementally.

Zode should treat relevant file operations as structured visual entities, not only raw strings in tool output.

### File operation types

Support as applicable:

- File created.
- File modified.
- File deleted.
- File renamed.
- File read.
- File restored.
- File conflict.

Do not present file reads as modifications.

### File metadata model

A structured file-change representation should support available fields such as:

```text
FileChange:
  id
  path
  name
  extension
  language
  operation
  additions
  deletions
  changed_hunks
  previous_content_hash
  current_content_hash
  timestamp
  status
  session_id / correlation context
  diff_reference
```

Optional fields remain optional. **Never invent unavailable statistics.**

### File icons / labels

Use semantic file/type labels with text fallbacks. Nerd Font glyphs are optional and must never be required. Reuse existing icon/language infrastructure where present (`src/lib/lang_icons.zig`, theme/style conventions).

### Compact file card

Default presentation (single line, minimal metadata, semantic type, add/delete counts, relative path context, expandable).

### Expanded file card

Expanded metadata, status, change summary, and relevant actions when the component is active.

### Interaction (when implemented)

- Enter: inspect diff.
- O: open file (external editor integration where supported).
- C: copy path.
- R: revert changes only with explicit confirmation and runtime support.
- Space: expand/collapse.
- Tab: navigate available actions.

All shortcuts must respect active interaction context. Never execute destructive actions through an ambiguous shortcut.

### Aggregation

If a file is modified multiple times during the same logical task:

- Update the existing visual representation where appropriate.
- Avoid duplicate cards for low-level edits.
- Preserve operation history/evidence.
- Calculate final net diff from actual before/after state.
- Do not merge unrelated sessions or logically separate tasks without explicit strategy.

### Change statistics

Calculate additions/deletions from actual before/after diffs.

Do not sum individual tool-operation statistics blindly. New files use `Created`; deleted files use `Deleted`; renamed files preserve rename information.

Never show a successful change summary until underlying modifications have completed.

---

## 6. File change summary

Provide a compact change summary when an operation or logical task modifies multiple files.

Requirements:

- Group by task or logical operation.
- Avoid repeating identical file cards.
- Support expansion and file navigation.
- Support opening complete review when available.
- Display accurate statistics.

---

## 7. Interactive diff viewer

A target component. Implement only when file/diff infrastructure and tests are ready.

### Requirements

- Syntax-aware highlighting where practical.
- Added/removed/modified/change markers.
- Line numbers or gutters when useful.
- Hunk navigation.
- File navigation.
- Context expansion.
- Copy selected code/path where supported.
- Expand/collapse.
- Accept/reject actions only where runtime semantics are explicit and safe.

Never rely on color alone. Use markers, text, and structure.

### Layout

- Unified diff by default.
- Optional side-by-side only when terminal width is sufficient.
- Narrow terminals use unified/compact diff.
- Never horizontally overflow the terminal; never silently clip important content.

---

## 8. Code blocks as mini editors

Markdown code blocks should feel inspectable and integrated.

Requirements:

- Language detection.
- Syntax highlighting.
- Line numbers when useful.
- Copy support where supported.
- Expand/collapse for large blocks.
- Horizontal scrolling/wrapping strategy appropriate to content and width.
- Accurate Unicode display width (`theme.graphemeWidth` / painter measurement patterns).
- Preserve original code content. Never modify code during rendering.

Prefer subtle framing over heavy bordered containers for ordinary blocks.

---

## 9. Tool event intelligence

Tool execution should become a consistent visual system, implemented incrementally over existing tool rendering.

Every relevant tool execution should have a clear semantic representation.

### Tool event model (conceptual)

```text
ToolEvent:
  id
  name
  operation
  input_summary
  output_summary
  status
  started_at
  completed_at
  duration
  correlation_id
  parent_task_id
  expandable_output
```

### Tool states

```text
Queued
Running
Completed
Failed
Cancelled
WaitingForPermission
```

Only display a completed state after receiving a successful result.

### Rules

- Collapse unimportant output by default where useful.
- Preserve access to complete output/evidence.
- Group related operations carefully.
- Avoid excessive repeated metadata.
- Display duration when available.
- Display meaningful summaries.
- Support keyboard expansion where implemented.
- Preserve execution order.

Never hide errors inside collapsed output. Never fabricate tool results.

---

## 10. Tool event deduplication

Repeated operations can overwhelm the conversation.

When grouping visually:

- Preserve the actual operation history.
- Group visually related operations.
- Indicate repetition.
- Keep individual operations accessible.
- Never silently remove evidence of execution.

If an execution guard prevents an operation from running again, represent that as a distinct system event, not a successful repeated execution.

The deduplication layer must never modify runtime behavior.

---

## 11. Directional motion (Zode Motion)

Optional and incremental. Introduce only when it does not harm correctness or performance.

Possible transitions: event reveal, stream reveal, state morph, file card entrance, overlay/expand transitions.

### Constraints

- Never block the event loop.
- Never sleep the main execution thread for animations.
- Avoid full viewport redraws.
- Use incremental rendering.
- Avoid unnecessary allocations per animation frame.
- Cancel animations when components disappear.
- Handle terminal resize during animation.
- Support reduced motion.
- Provide a no-animation mode.

If animation cannot be performed safely, render the final state immediately. Correctness takes priority over motion.

---

## 12. Interactive prompts and selectors

Interactive questions and selectors must never overlap important content unpredictably or escape terminal bounds.

Zode already has ask/question state and modal/palette patterns (`src/lib/ask.zig`, ask panel/palette behavior in `src/tui.zig` and `src/palette.zig`). Evolve these components; do not duplicate them.

### Requirements

- Calculate bounds before rendering.
- Adapt width/height to terminal size.
- Wrap long descriptions/questions.
- Preserve option ordering.
- Highlight the selected option clearly.
- Support keyboard navigation.
- Support custom text answers where applicable.
- Preserve the original question/context.
- For narrow terminals, use compact/full-width presentation.
- Never render a fixed-width popup that extends beyond the viewport.

The selector must not hide the user's previous conversation unless the interaction explicitly requires focus.

---

## 13. Permission experience

Permission dialogs must be reliable, accessible, and runtime-owned.

Zode already has a permission flow (agent/runtime control, `requestPermission`/answer path, modal rendering in `tui.zig`). The UI must remain a presentation of runtime decisions, not the decision-maker.

### Requirements

- Never overflow horizontally.
- Wrap long paths and commands.
- Show the exact operation/tool.
- Explain why the dialog appeared when rule context is available.
- Explain potentially destructive effects when relevant.
- Make the selected action obvious.
- Never preselect dangerous permissions.
- Support keyboard navigation.
- Preserve permission policy semantics.
- Allow inspection before approval where supported.

A rendering failure must never approve an operation. Permission prompts have higher priority than normal streaming updates.

---

## 14. Status footer

Preserve and refine Zode's persistent footer/status information.

The footer should display runtime truth: status/phase, model, context usage, cache information, throughput/timing when available. Prioritize critical state (especially permission/waiting/error) over secondary metadata.

When space is limited, progressively hide secondary metadata. Never truncate or obscure the actual critical status.

---

## 15. Scroll and navigation system

Improve navigation without breaking existing scroll semantics.

Support:

- Conversation history navigation.
- Tool event navigation.
- File change navigation.
- Diff navigation (when implemented).
- New output indicators.
- Scroll position preservation.
- Jump to latest.
- Jump to previous user message / next tool operation where practical.

### Scroll behavior

- If the user is at the bottom, follow new output.
- If the user scrolls upward, preserve position.
- If new output arrives while browsing history, show a subtle indicator.
- Do not force-scroll to the bottom.
- Do not lose the viewport when expandable content changes height.
- Use stable logical identifiers/paragraph-based anchoring consistent with Zode's current approach.

---

## 16. Command palette

Zode already has a modal palette (`src/palette.zig`, Ctrl+P path) for commands/models/connect flows. Extend it carefully rather than replacing it.

Possible future commands (only when implemented and useful): new/resume session, inspect modified files, review all changes, search conversation/files, inspect context/tools, git status, switch model/permissions, toggle compact/motion, settings.

Requirements when extended:

- Fuzzy search.
- Keyboard and existing mouse behavior.
- Clear descriptions.
- Contextual commands.
- No duplicated commands without navigational value.

---

## 17. Workspace modes

Potential modes: Focus, Flow, Review.

If implemented, modes must be presentation layers over shared runtime state. Do not duplicate runtime logic or create independent copies of the same information.

---

## 18. Git intelligence

Git awareness is useful but optional by repository state.

Possible information: branch, working tree state, changed/staged/unstaged/untracked files, diff summaries, commit info when available.

Never execute commits, resets, or other destructive Git actions without explicit user authorization. Do not assume every project is a Git repository.

---

## 19. Editor-like interaction

Zode should become a capable editing/review environment without pretending to be a full graphical IDE.

Prioritize useful terminal-native workflows first:

- File inspection and navigation.
- Syntax-highlighted code.
- Interactive diffs.
- Change review.
- Search in output.
- Copy code/paths.
- Open files in an external editor.
- Inspect agent modifications/history where available.

Future capabilities (only after stable file/diff navigation): file tree, search/replace, in-terminal editing, multi-file review, hunk accept/reject, git staging by hunk.

Preserve external editor workflows.

---

## 20. Responsive terminal layout

Terminal resize is a first-class feature.

Behavior targets:

- ~60–79 columns: compact conversation, full-width interactive components, unified diffs, minimal metadata.
- ~80–119 columns: default experience, readable code, expanded cards when useful.
- ~120+ columns: more metadata, optional side-by-side diff, wider code/details.

Never hardcode popup widths. Never allow components to render outside terminal bounds. Never silently clip important content. Every component must have a compact fallback.

---

## 21. Vaxis and Zig implementation rules

- Use existing Vaxis/Zode rendering abstractions.
- Follow repository allocation and lifetime conventions.
- Preserve the current event loop.
- Keep UI components independent from agent execution.
- Avoid unnecessary heap allocations and redundant formatting.
- Handle resize events safely.
- Restore terminal state on exit.
- Preserve existing keyboard behavior unless intentionally changed and documented/tested.
- Do not invent Vaxis APIs; inspect the installed Vaxis 0.6 behavior and existing abstractions.
- Follow Zig 0.17 constraints in `AGENTS.md`.
- All visible UI strings, code comments, test names, and repository docs/artifacts must be in English.

---

## 22. State and event architecture

The UI must be driven by structured state.

Never derive important UI state by parsing previously rendered terminal strings. Use existing runtime/session/tool events where possible. Extend event structures only for real requirements.

Relevant events should carry stable identifiers, type, timestamps/correlation context, session/operation context, structured payload, and current state where available.

The UI must not invent events to make animations look realistic.

---

## 23. Performance requirements

Performance is a product feature.

- Incremental updates; avoid full-screen redraws.
- Minimize allocations; reuse buffers/caches where appropriate.
- Cache expensive highlighting/layout work when safe.
- Batch high-frequency stream updates.
- Avoid unnecessary terminal output.
- Support large conversations, many tool events, large code blocks/diffs, and long histories with viewport-aware strategies as needed.
- Measure rendering/performance impact before and after motion or heavy UI changes.

Animation must never degrade responsiveness. Deterministic transitions are preferred over continuous decoration.

---

## 24. Accessibility and terminal compatibility

Support:

- Keyboard-only operation.
- Reduced motion and no-animation mode.
- Monochrome / `NO_COLOR` behavior.
- 16/256/truecolor terminals as supported by theme capabilities.
- ASCII/text fallbacks.
- Unicode-aware rendering and correct display width.
- Terminal resize.
- Common terminals and SSH environments.

Do not require Nerd Fonts. Do not require mouse support. Never assume Unicode characters occupy exactly one terminal cell.

---

## 25. Language and content policy

Follow `AGENTS.md`: all UI strings, code comments, test names, and codebase artifacts are in English unless project policy explicitly allows otherwise. Assistant conversation may follow the user's language.

---

## 26. Implementation priorities

Do not implement every feature simultaneously. Advance only when the current phase is stable and tested.

### Phase 1 — UI foundations (started)

- [x] Create/adapt this design guide and reference it from `AGENTS.md`.
- [x] Audit existing TUI components and rendering paths (initial pass).
- [ ] Preserve the current visual identity during changes.
- [x] Improve responsive layout calculations where needed (incremental).
- [x] Harden question/ask selector overflow and narrow-terminal behavior (incremental).
- [x] Harden permission dialog overflow and narrow-terminal behavior (incremental).
- [x] Improve scroll anchoring and viewport stability where needed (incremental).
- [x] Standardize event presentation (incremental).

#### Phase 1 audit notes (initial)

Audited paths/components (read-only review, to guide incremental changes):

- **Theme/capabilities:** `src/lib/theme.zig` — semantic roles, contrast tests, ANSI256/`NO_COLOR`/daltonized, Unicode width helper. Keep as the only palette source.
- **Modal palette:** `src/palette.zig` — Ctrl+P commands/models/connect/key prompt, responsive `boxFor`, filtering, row walker, mouse hit testing, scrollbar/counter, clipping. Reuse/extend; avoid duplicate command UI.
- **Permission UI/runtime boundary:** permission state and `requestPermission`/answer flow in `src/tui.zig` + agent runtime; rendering in `drawPermissionModal`/`drawPermissionModalCompact`. Runtime owns decisions; UI must never approve on render failure. Detail/rule wrapping, compact fallback, and action-label consistency (`allow_always`/sandbox) hardened; `drawTest` coverage added.
- **Ask/question UI:** `src/lib/ask.zig` (parse/format/guidance, pure/tested) + ask state/snapshot and `drawAskPanel` in `src/tui.zig`. Has wrapping, compact mode, clipping, explicit truncation; existing draw tests cover narrow/long cases.
- **Conversation/streaming/tool rendering:** `src/tui.zig` (large surface), `src/lib/markdown.zig`, `src/lib/highlight.zig`, `src/lib/lang_icons.zig`. Changes here must preserve streaming, scroll anchor semantics, and performance.
- **Scroll/viewport:** paragraph/offset anchoring, `follow_bottom`, anchor clamping behavior in `src/tui.zig`. Treat as sensitive; improve only with targeted tests/harness validation.
- **Status/mascot/composer:** footer/phase presentation and mascot state are part of Zode identity; preserve semantics and readability.

Phase 1 foundations are substantially complete (visual identity remains a continuous constraint). Phase 2 is now in progress: semantic file labels (`lang_icons.forPath`), compact/expanded file card formatters, and honest aggregation/summary building are implemented as pure/tested lib modules (`src/lib/lang_icons.zig`, `src/lib/filechange.zig`). Next: wire structured file-change rendering into the TUI event path, keep stats sourced from real diffs/baselines, and add grouped summaries/navigation incrementally with `drawTest`/harness coverage once the working tree compiles cleanly.

### Phase 2 — File intelligence (complete, incremental UI integration)

- [x] Semantic file/type labels and icon fallback strategy (`src/lib/lang_icons.zig`: `lookup` + `forPath` for basename/extension, Nerd Font optional, text fallback always).
- [x] Compact file card formatting foundation (pure/tested: `src/lib/filechange.zig` `formatCompact`).
- [x] Expanded file card formatting foundation (pure/tested: `src/lib/filechange.zig` `formatExpanded`).
- [x] Accurate diff statistics from real diffs (TUI/agent compute `DiffCounts` from actual before/after diffs; no invented/summed net stats).
- [x] TUI file-diff presentation integration: `Model.pushFileDiff`/`pushFileDiffOp` emits a compact semantic card (operation/label + real `+/-`) before the real diff; `agent.execOneCall` uses it as the single source for file diffs.
- [x] True net-diff aggregation across multiple edits to the same file in one turn (honest): first edit stores bounded `before` baseline; subsequent edits compute/display real net diff `baseline -> after` (`(net)` card + net diff, or `(net, no changes)`). Baseline storage is turn-scoped (`beginCheckpoint`), capped (64 files, 256KB/file, 1MB total), lock-safe; fallback to real operation diff if unavailable (no invented stats).
- [x] File change aggregation foundation (pure/tested: `filechange.Summary` groups by path; net replacement requires caller-provided net stats).
- [x] Live grouped change summaries (honest): `Model` stores latest net stats per turn baseline (`appendTurnFileSummary`/`pushTurnFileSummary`); `/files` (`src/commands.zig`) shows the session report plus a turn-scoped net summary when available. `src/lib/filesview.zig` renders changed files with semantic labels (no invented stats).
- [x] Interactive/navigation foundation (incremental): structured cards/summaries are rendered in the timeline and `/files`; diff content remains inspectable via existing diff preview/expansion behavior. Full timeline focus actions/navigation (jump/open/copy/revert shortcuts on individual cards) remain a follow-up UX increment (overlaps Phase 3 review/navigation), to be added with stable focus/hit semantics and tests.

Notes: `zig test src/lib/filechange.zig`, `src/lib/lang_icons.zig`, and `src/lib/filesview.zig` pass. TUI `drawTest`s added for file diff card and honest multi-edit net diff in `src/tui.zig`; full `zig build`/suite validation is currently blocked by unrelated pre-existing `agent.zig`/`agent/discovery` compile errors in the working tree (not caused by this work). All file/net stats are sourced from real diffs/baselines.

### Phase 3 — Interactive review

- [ ] Unified diff viewer.
- [ ] Syntax-aware diff rendering.
- [ ] Hunk navigation.
- [ ] File navigation.
- [ ] Expanded code views.
- [ ] Review actions (runtime-safe).
- [ ] External editor integration where appropriate.

### Phase 4 — Zode Motion

- [ ] Directional event reveal.
- [ ] File card entrance.
- [ ] State transitions.
- [ ] Overlay transitions.
- [ ] Expand/collapse animations.
- [ ] Reduced motion and no-animation mode.
- [ ] Performance profiling.

### Phase 5 — Workbench

- [ ] Focus mode.
- [ ] Flow mode.
- [ ] Review mode.
- [ ] Command palette extensions.
- [ ] Git overview.
- [ ] Context inspector.
- [ ] Improved session navigation.

---

## 27. Strict anti-patterns

Never:

- Rewrite the existing application architecture.
- Replace Zig or Vaxis.
- Introduce unnecessary dependencies.
- Turn Zode into a dashboard.
- Add permanent sidebars that waste terminal space.
- Add borders around every component.
- Replace Zode's electric teal identity with an unrelated generic palette.
- Animate every terminal character artificially.
- Redraw the entire screen for every token.
- Display fake file statistics.
- Duplicate file cards for every edit operation.
- Lose file operation history.
- Hide failed tool executions.
- Hide permission requests.
- Allow dialogs to overflow.
- Force automatic scrolling.
- Depend on Nerd Fonts.
- Require mouse interaction.
- Break existing keyboard shortcuts without migration and tests.
- Remove existing features to simplify rendering.
- Sacrifice terminal performance for decoration.
- Invent Vaxis APIs.
- Introduce fake execution states.
- Modify agent runtime behavior while implementing purely visual features.
- Parse rendered terminal strings to infer important UI state.

---

## 28. Acceptance criteria

Every new TUI component or significant change should satisfy:

- [ ] Preserves Zode visual identity and theme roles.
- [ ] Uses existing Zig/Vaxis architecture.
- [ ] Supports keyboard interaction.
- [ ] Respects terminal dimensions and has a compact fallback.
- [ ] Uses semantic colors and remains readable without color alone.
- [ ] Handles Unicode display width correctly.
- [ ] Does not overflow the viewport.
- [ ] Does not cause unnecessary redraws.
- [ ] Does not introduce fake runtime state.
- [ ] Handles terminal resizing.
- [ ] Preserves existing application behavior.
- [ ] Includes appropriate tests (`zig build test`, and TUI-focused harnesses such as `drawTest`, `ui-frame`, or `pty_smoke` as relevant).

Additionally for file/review/motion features:

- [ ] File statistics come from actual diffs/state.
- [ ] Tool events retain execution identity/history.
- [ ] Permission decisions remain controlled by runtime.
- [ ] Animation can be disabled and falls back safely.
- [ ] Scroll position remains stable.

---

## 29. Final design directive

Zode should become an exceptional terminal-native AI development environment by building on its existing strengths: performance, a clear identity, structured runtime behavior, and a lightweight Zig/Vaxis implementation.

The most important evolution is the transition from plain textual tool output to intelligent interactive components.

Files should look like files. Changes should look like changes. Tools should communicate execution state. Code should feel inspectable. Permissions should feel safe. Motion, if added, should feel natural. The developer must never lose control of the terminal.

**Zode is not a chatbot inside a terminal. Zode is an AI-powered development environment built for the terminal.**
