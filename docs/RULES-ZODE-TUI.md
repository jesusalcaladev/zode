# Zode TUI — Never-Break Guide

**Purpose:** concise invariants for TUI/runtime/UX changes in Zode. This is not a feature roadmap. If a change conflicts with an invariant, the change is wrong or needs an explicit, tested design decision.

**Scope:** `src/tui.zig`, `src/palette.zig`, `src/commands.zig`, TUI-facing agent integration, and `src/lib/*` modules that render or supply UI state (`theme`, `markdown`, `highlight`, `ask`, `lang_icons`, `filechange`, `filesview`, `diffhunks`, etc.).

## Hard invariants

- **Preserve Zode architecture and identity.** Zig 0.17+, Vaxis 0.6, pure-Zig/std-first approach; no unnecessary dependencies, no rewrites, no dashboard/sidebar-heavy UI. Keep the terminal-native, borderless-first, electric-teal-accent identity.
- **`src/lib/theme.zig` is the only color/theme source of truth.** No duplicate palettes or ad hoc color systems. Use semantic roles (`ink*`, `line*`, `brand*`, `ok`/`warn`/`err`, diff roles, surfaces/selection) and respect capabilities (`NO_COLOR`, ANSI256/truecolor paths, daltonized support, contrast/theme tests).
- **Runtime owns truth.** Never invent file stats, tool states, permission decisions, execution results, or session/runtime state. File diffs/counts come from actual before/after state; reads are not modifications. UI renders structured state.
- **Permission decisions are runtime-owned.** UI presents the request; it never approves, denies, or auto-selects dangerous actions because of rendering/layout failures. Destructive actions (revert/delete/reset/commit/apply where applicable) require explicit runtime support and confirmation semantics.
- **Never parse rendered terminal/UI strings to infer important state.** Use structured runtime/session/tool state, stable IDs/correlation, and explicit fields.
- **Scroll/viewport safety is critical.** Preserve paragraph/offset anchoring behavior, follow-bottom only when appropriate, preserve position while browsing history, and avoid losing viewport on height changes/expand-collapse. Never silently clip important content; every interactive surface needs a compact fallback.
- **No event-loop blocking for UI/motion.** No sleeps on the main thread, no blocking animation paths, no full-screen redraws for ordinary updates, incremental rendering where practical, cancel-safe behavior, and resize-safe rendering.
- **Motion must degrade safely.** Respect `ZODE_REDUCED_MOTION`/`REDUCED_MOTION` and `ZODE_NO_ANIMATION`/`NO_ANIMATION`. If motion is reduced/disabled or cannot be performed safely, render the final state immediately. Continuous motion is optional; correctness and responsiveness are mandatory.
- **Terminal safety.** Restore terminal state on exit/crash paths as implemented (raw restore/crash handling constraints apply). Never let ANSI/control bytes corrupt rendering; follow existing sanitization/width-measurement patterns.
- **Zig 0.17 / Vaxis 0.6 constraints apply.** Follow `AGENTS.md` traps (allocator/free semantics, grapheme lifetimes in Vaxis cells, no `**`, no `std.meta.fields`, timestamp APIs, etc.). Do not invent Vaxis APIs.
- **All visible text is in English.** UI strings, code comments, test names, and repository artifacts/docs must be in English.

## Validation expectations

- Run `zig build test` when the working tree can compile/test cleanly.
- For TUI changes, also use relevant harnesses: `zig build ui-frame`, `drawTest` coverage, and/or `tools/pty_smoke.py` as appropriate.
- Add or update tests for behavior you change. A TUI/runtime rule without coverage is easy to regress.
- When full validation is blocked by unrelated in-progress work, say so explicitly and run the closest targeted checks.