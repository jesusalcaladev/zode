# TUI chrome and interaction: the reference implementation (Claude Code) vs zode

Scope: **screen composition** (header / transcript / input / footer), **overlay
painting**, **transcript rendering**, and **interaction** (keys, mouse,
modals, pickers).

Everything below compares two implementations:

* the **reference implementation** (Claude Code, TypeScript + Ink), read from
  its own source tree
* **ours** = `src/` (zode, Zig + libvaxis/vxfw)

The reference implementation is **not** part of this repository and is not
redistributed here, so this document deliberately carries **no pointers into
its tree**: no file paths, no line numbers. Every claim about it names the
*component* and describes the *mechanism* in prose instead, so a reader can
check each statement against **our** code (the `src/…:line` citations below
are exact and point at this repository) and against the observable behaviour
of the reference implementation itself.

No source file was modified to produce this document.

---

## 1. The reference implementation's screen anatomy

### 1.1 The root: an alternate screen, then a flexbox column

The reference implementation has **two rendering modes** (alt-buffer fullscreen
vs. normal scrollback) plus a **third screen** (the transcript, `ctrl+o`), and
it picks between the first two with an environment flag.

* An environment probe, `isFullscreenEnvEnabled()`, decides whether the REPL
  owns the terminal's alternate buffer. It is opt-in for external users
  (`CLAUDE_CODE_NO_FLICKER=1`), default-on internally, and it is
  **auto-disabled under `tmux -CC`** because alt-screen + mouse tracking
  corrupts terminal state there. The same module holds `isTmuxControlMode()`,
  the check that detects tmux control mode.
* When virtual scroll is available the whole REPL is wrapped in an
  `AlternateScreen` component with `mouseTracking={isMouseTrackingEnabled()}`.
* The `AlternateScreen` component itself is the thing that switches the
  terminal into the alternate buffer.

Inside the alt buffer the screen is a **Yoga flexbox column** with three
regions, not a hand-computed row arithmetic:

The fullscreen layout component receives five slots:

| prop | meaning | slot order |
|---|---|---|
| `scrollable` | the transcript | 1 |
| `bottom` | spinner + prompt + permissions | 2 |
| `overlay` | rendered *inside* the scroll box, after the messages | 3 |
| `bottomFloat` | absolutely positioned, bottom-right, over the scrollback | 4 |
| `modal` | an absolutely positioned bottom-anchored pane | 5 |

The composition, in source order:

```
<ScrollBox flexGrow={1} flexDirection="column" paddingTop={t9} stickyScroll={true}>
<Box flexGrow={1} flexDirection="column" overflow="hidden">   <- sticky header + scrollbox + pill + float
<Box flexDirection="column" flexShrink={0} width="100%" maxHeight="50%">  <- the bottom slot
<Box position="absolute" bottom={0} left={0} right={0} maxHeight={terminalRows - MODAL_TRANSCRIPT_PEEK} opaque={true}>  <- modal
```

Three consequences that we do not have:

1. **The bottom slot is capped at 50 % of the terminal height** (`maxHeight="50%"`
   on the bottom slot). The prompt can never eat the whole screen.
2. **The transcript is a virtualised scroll box with sticky bottom** (the
   `ScrollBox` component, 236 lines) — the app keeps its own scroll offset and
   renders only the visible window.
3. **The modal is a bottom-anchored pane with a `▔` divider and 2 rows of
   transcript still visible above it**: the constant `MODAL_TRANSCRIPT_PEEK = 2`
   and the absolute pane whose rule is `{"\u2594".repeat(columns)}` (the `▔`)
   with `paddingX={2}`.

Outside fullscreen the same component degrades to a plain sequence:
`{scrollable}{bottom}{overlay}{modal}`.

### 1.2 The scroll-derived chrome (the "N new" pill and the sticky header)

This is the reference implementation's most distinctive piece of screen chrome
and we have nothing equivalent.

* A hook, `useUnseenDivider(messageCount)`, tracks where the user was when they
  scrolled away from the bottom. The "am I at the bottom" test uses
  `scrollTop + pendingDelta >= scrollHeight - viewportHeight`, i.e. it accounts
  for the wheel momentum that has not been applied yet. On the **first**
  scroll-away it snapshots `scrollHeight` and records the message index; later
  scroll-aways are ref-only no-ops so the transcript does not re-render.
* `countUnseenAssistantTurns` counts *turns*, not raw entries: tool-use-only
  assistant entries are skipped so `"⏺ Searched for 13 patterns"` does not tick
  the pill.
* `computeUnseenDivider` floors the count at 1 so the pill flips from "Jump to
  bottom" to "1 new message" as soon as anything arrives.
* The **"N new" pill** (`NewMessagesPill`): an absolutely positioned centred
  pill at `bottom={0}` over the scrollback, with a background colour and a
  hover state. Its text is `"{count} new {message|messages}"` or
  `"Jump to bottom"`.
* The **sticky prompt header** (`StickyPromptHeader`): a **fixed one-row**
  breadcrumb above the scroll box that pins the prompt the assistant was
  answering, with `figures.pointer` and `wrap="truncate-end"`. The comment next
  to it is the design rule: a *variable* height header shifts the scroll box by
  one row every time the sticky prompt changes, so the content jumps on screen
  even though `scrollTop` did not move.

### 1.3 The prompt (input box)

The reference implementation's prompt component:

* The prompt is a **box with only a bottom rounded border**:
  `borderStyle="round" borderLeft={false} borderRight={false} borderBottom`
  (so the shape is `╰─────────╯`).
* The border colour follows the **mode**: `getBorderColor()` returns
  `bashBorder` in bash mode, the teammate colour when a teammate owns the
  turn, `promptBorder` otherwise.
* While an external editor is open, the prompt is replaced by the single line
  `Save and close editor to continue...`.
* While a permission is suppressed, a `Waiting for permission…` line is
  printed above the box.
* The "swarm banner" mode replaces the border with a coloured banner whose
  text is embedded in a full-width rule.
* Notifications are **absolutely positioned** above the prompt
  (`position="absolute" marginTop={-1} height={1}`), so an appearing
  notification does not shift the prompt by a row. The comment there explains
  the negative margins and why the box stays mounted.
* The input viewport is capped at
  `max(MIN_INPUT_VIEWPORT_LINES, floor(rows / 2) - PROMPT_FOOTER_LINES)`: the
  prompt may not take more than half the terminal.
* The placeholder is a **suggestion**: `showPromptSuggestion &&
  promptSuggestion ? promptSuggestion : defaultPlaceholder`.

### 1.4 The footer

Two components, side by side: the footer shell and the footer's left side.

The footer shell, in source order:

```
<Box flexDirection={isNarrow ? 'column' : 'row'} justifyContent={isNarrow ? 'flex-start' : 'space-between'} paddingX={2} gap={isNarrow ? 0 : 1}>
  <Box flexDirection="column" flexShrink={isNarrow ? 0 : 1}>
    {mode === 'prompt' && !isShort && !exitMessage.show && !isPasting && statusLineShouldDisplay(settings) && <StatusLine .../>}
    <PromptInputFooterLeftSide ... />
  <Box flexShrink={1} gap={1}>
    {isFullscreen ? null : <Notifications ... />}
```

* `isNarrow = columns < 80`: under 80 columns the footer becomes a **column**
  instead of a row.
* `isShort = isFullscreen && rows < 24`: under 24 rows the optional status
  line is dropped.
* The `? for shortcuts` hint is suppressed when a custom status line exists or
  while searching.

The footer's left side:

* `Press {key} again to exit` (the double-press ctrl+c guard).
* `Pasting text…` (a large paste is acknowledged).
* `-- INSERT --` (vim mode).
* The **permission mode pill**: `{symbol} {title} on` in the mode's colour,
  plus a dim `shift+tab to cycle` hint (rendered by a
  `KeyboardShortcutHint` component).
* `getSpinnerHintParts(...)`: the footer hint is assembled from `esc`,
  `ctrl+t` (todos), `ctrl+x ctrl+k` (kill agents) and the teammate state, so
  the hint changes with what is running.
* While a history search is open, the footer left side is *replaced* by the
  search input (`HistorySearchInput`).

The status line:

* The status line is **a user-configured external command**. The app builds a
  JSON object (model, workspace, cost, context window, rate limits, vim mode,
  agent type, worktree) and runs the user's command; the output is the status
  line.
* It is re-evaluated on a **300 ms debounce** and only when the assistant
  message id, permission mode, vim mode or model changed.
* In fullscreen the status line must have a **stable height**: a 0→1 row
  change would steal a row from the scroll box and shift the content.

### 1.5 The transcript

**Tool calls.** The assistant tool-use message:

* The leading marker is a `ToolUseLoader` (spinner) for an unresolved call and
  a dim `BLACK_CIRCLE` (`⏺` on macOS, `●` elsewhere — the figure constants
  define it) for a queued one.
* The tool name is **bold**, `flexShrink={0}`, `wrap="truncate-end"`.
* The arguments are in parentheses in a separate `<Text>`.
* The whole header is `minWidth={stringWidth(name) + 2}` so the row does not
  reflow when the name changes.

**Tool results.** The message-response component prefixes the result with a
dim gutter `  ⎿  `, and marks that gutter as `NoSelect` so a mouse selection
does not include it. Nested results do not repeat the `⎿` (a context flag).

**Diffs.** The structured-diff component:

* `computeGutterWidth(patch)`: the gutter is
  `marker + space + right-aligned line number + space`, and the width depends
  only on the patch, so it is cacheable.
* **If the gutter would eat the whole width (narrow terminal) the split is
  skipped**; the single-column output stays correct, only `noSelect` is lost.
* A `WeakMap` cache keyed by patch identity, plus a key that includes
  theme/width/dim/gutter.

**Todos / tasks.** The task-list panel:

* `maxDisplay = rows <= 10 ? 0 : min(10, max(3, rows - 14))`: the panel
  shrinks on a short terminal.
* When the list is truncated the **priority is** recently completed (within
  30 s) → in progress → pending (unblocked first) → older completed.
* The hidden ones are summarised as `… +2 in progress, 3 pending`.
* A task shows its **open blockers** (`openBlockers={task.blockedBy.filter(...)}`).

**Thinking.** The thinking message and its highlighted-text variant exist as
separate message kinds.

### 1.6 Overlays

Four overlay mechanisms, and they do not overlap by accident:

1. **Modal pane** (the absolute bottom-anchored box of the fullscreen layout)
   — bottom-anchored, `▔` rule, `paddingX={2}`, `opaque`, and it paints **over
   both the scroll box and the bottom slot**. It carries a `ModalContext` with
   `{rows: terminalRows - 3, columns: columns - 4}` so a `Dialog` inside it
   knows it is inside a modal and skips its own frame (the design system's
   `Pane` handles that).
2. **Suggestions overlay** (an absolute `bottom="100%"` box above the prompt) —
   portalled out of the prompt component so it is not clipped by the prompt's
   own box.
3. **Dialog overlay** — same escape pattern, rendered later in tree order so
   it paints over the suggestions.
4. **Permission dialog** — a **top border only** box:
   `borderStyle="round" borderLeft={false} borderRight={false} borderBottom={false}`,
   `marginTop={1}`.

Dialogs themselves: the design system's dialog component — title in bold,
optional dim subtitle, children in a column with `gap={1}`, and an **input
guide** line: `Enter to confirm · Esc to cancel`, or `Press {key} again to
exit` when a ctrl+c is pending.

### 1.7 Interaction model

**Keybindings are data.** The reference implementation keeps its keybindings in
a table of `{context, bindings}` blocks; a separate parser turns
`"ctrl+shift+k"` into a `ParsedKeystroke`; a schema and a validator check a
user file; and a reserved-shortcut list refuses to let the user rebind
ctrl+c / ctrl+d.

The contexts and what is in them:

| context | keys | scope |
|---|---|---|
| Global | `ctrl+c` interrupt, `ctrl+d` exit, `ctrl+l` redraw, `ctrl+t` todos, `ctrl+o` transcript, `ctrl+r` history search, `ctrl+shift+f` global search, `ctrl+shift+p` quick open | everywhere, including the transcript screen |
| Chat | `esc` cancel, `shift+tab` cycle mode, `meta+p` model picker, `meta+t` thinking, `enter` submit, `↑/↓` history, `ctrl+_` undo, `ctrl+g` external editor, `ctrl+s` stash, `ctrl+v` image paste, `shift+↑` message actions | the prompt |
| Autocomplete | `tab` accept, `esc` dismiss, `↑/↓` | the completion popup |
| Confirmation | `y/n/enter/esc`, `↑/↓`, `tab`, `space`, `shift+tab` cycle, `ctrl+e` toggle explanation, `ctrl+d` debug info | a confirmation dialog |
| Tabs | `tab`/`shift+tab`/`←/→` | tabbed panes |
| Transcript | `ctrl+e` show all, `ctrl+c`/`esc`/`q` exit | the transcript screen (`ctrl+o`) |
| HistorySearch | `ctrl+r` next, `esc`/`tab` accept, `ctrl+c` cancel, `enter` execute | the history-search input |
| Scroll | `pageup/pagedown`, `wheelup/wheeldown`, `ctrl+home/end`, `ctrl+shift+c` copy | the scrollable transcript |
| Footer | `↑/↓/←/→`, `enter` open, `esc` clear | the footer |
| MessageActions | `↑/↓/j/k`, `ctrl+↑/↓`, `c` copy, `p` paste | the per-message action menu |
| DiffDialog | `esc`, `←/→` source, `↑/↓` file, `enter` details | the modal diff viewer |

**The transcript screen is a separate screen, not a mode of the prompt.**
A global-keybindings hook swaps `screen` between `'prompt'` and `'transcript'`
on `ctrl+o`; `ctrl+e` toggles "show all" *inside* the transcript;
`ctrl+c`/`esc`/`q` leave it. In transcript mode the bottom slot is a
`TranscriptModeFooter` (or a `TranscriptSearchBar` when searching), and the
prompt is **not mounted at all**. The pager keys in that screen follow
`less`/`tmux copy-mode`: `g`/`G`, `ctrl+u`/`ctrl+d` (half page),
`ctrl+b`/`ctrl+f` (full page), space (handled by the scroll-keybinding
handler, which binds both the half-page and the full-page motions).

**Selection and copy.** The selection module is 917 lines: line-based
selection with an anchor and a focus, word/line snapping for multi-click,
accumulators for the rows that scrolled out of the viewport during the drag
(`scrolledOffAbove` / `scrolledOffBelow`), and `softWrap` bits so a
soft-wrapped row is joined back into its logical line. The search-highlight
module inverts **all** matches in the screen buffer; the screen renderer has
`applyPositionedHighlight`, which paints the *current* match on top in yellow.

**Key parsing.** The keypress parser documents the **kitty keyboard protocol**
(`CSI u`), has the kitty mode query, and the `CSI u` branch. A separate
module detects OSC 8 support (ghostty, kitty, alacritty, iTerm, plus
`LC_TERMINAL` so it survives tmux).

**Spinners.** The spinner row is a **50 ms animation frame** carrying a random
verb (*Accomplishing, Baking, Beaming, Booping…*), the elapsed time, and —
after 30 s — the token count (`SHOW_TOKENS_AFTER_MS`). A separate hook turns
the spinner red when it stalls.

**Notifications.** A priority/timeout keyed notification store (in the app's
notification context) surfaces: API key status, auto-updater, IDE connection,
token warning, MCP clients, sandbox hints.

### 1.8 Other components the reference implementation has

| component | what it is |
|---|---|
| Context visualisation | a per-category context breakdown with a proportional bar chart, a "free space" line and the autocompact reserve |
| Context suggestions | concrete suggestions to reduce the context |
| Global search dialog | search across the whole session |
| History search dialog | search the prompt history |
| Message selector (830 lines) | pick a past message to rewind to |
| Per-message actions | per-message actions (copy, rewind, …) |
| Modal diff viewer | a modal diff viewer that navigates between files and between the old/new side |
| Per-hunk diff detail view | the per-hunk detail view of that dialog |
| Markdown table renderer | markdown tables rendered as a flexbox grid |
| Design-system progress bar | a determinate bar |
| Design-system tabs | tabbed panes |
| Design-system fuzzy picker | the shared picker (`DEFAULT_VISIBLE = 8`, `CHROME_ROWS = 10`) |
| Design-system search box | the search field with a `⌕` prefix and an inverse cursor |
| Design-system list item | the list row with a `❯` pointer, a `✓` tick and a dim description |
| Design-system byline | the dim hint line under a dialog |
| Design-system keyboard-shortcut hint | the `ctrl+o to expand` chip |
| Design-system ratchet | a box that keeps its height while it is off-screen (lazy rendering) |
| Highlighted code | syntax-highlighted code blocks |
| Thinking toggle | a modal to enable/disable extended thinking |
| Effort indicator | the effort glyph (`○ ◐ ● ◉`) |
| Queued-commands strip | the queue of prompts waiting to be sent |
| Stash notice | "you have a stashed prompt" |
| Shimmered input | a shimmering placeholder for suggested input |
| Startup logo / welcome screen | the startup logo / welcome screen |
| Vim mode | a full vim mode for the prompt |

---

## 2. What we have today

### 2.1 Our screen composition

One function draws the whole screen: `src/tui.zig:5473` `typeErasedDrawFn`.

The layout is computed **bottom-up** and the comment at `src/tui.zig:5494-5510`
is the specification:

```
row height-1                       the footer's row (the mascot)
rows ..input_top+input_h-1         prompt, no box, grows upward
row  rule_row                      one hairline
rows rule_row-ac..plan             only when relevant
rows 0..history_h                  the conversation, and nothing else
```

The arithmetic:

| quantity | line | value |
|---|---|---|
| `max_input_lines` | `src/tui.zig:5510` | 8 |
| `text_w` | `:5511` | `width - 4` |
| `chrome` | `:5543` | `1 + ac_rows + plan_rows` (hairline + autocomplete + plan) |
| `avail` | `:5544` | `height - chrome - 2` |
| `input_h` | `:5546` | `min(displayLines(ed_w), max_input_lines)`, at least 1 |
| `well_h` | `:5550` | `input_h + 1` (the footer row is always reserved) |
| `input_top` | `:5551` | `height - well_h` |
| `rule_row` | `:5552` | `input_top - 1` |
| `history_h` | `:5554` | `workspace_top` |

Paint order in one frame:

1. `src/tui.zig:5559` `drainPending()` / `:5563` `drainShellOut()`.
2. `:5568-5585` the segment cache is invalidated on a width change or a
   paragraph edit.
3. `:5604-5668` the **live paragraph** is copied out of the model under the
   lock and parsed **outside** it.
4. `:5705` `layoutFor(...)` computes the visible paragraph range and the
   scroll anchor.
5. `:5728-5731` the history area is **cleared** before painting.
6. `:5747-5755` only the visible cached paragraphs and the live paragraph are
   painted.
7. `:5756` the scrollbar, `:5757-5758` the text selection.
8. `:5783` the modal picker, `:5793` the plan block, `:5798` the
   autocomplete popup, `:5811` the hairline, `:5816` the input,
   `:5823` the state footer.
9. `:5832` the permission modal, `:5844` the ask panel, `:5856` the palette
   (last, on top of everything).

### 2.2 What we have that is equal or better

**Fewer permanent rows.** The reference implementation's prompt block is a box
with a rounded bottom border plus a status line plus a left/right footer row
(the prompt component plus the footer shell): at least 4 rows of furniture.
Ours is a **hairline + the prompt rows + one footer row**
(`src/tui.zig:5543`, `:5550`), and the footer row is *always* reserved so the
input never jumps (`:5547-5549`).

**One state surface.** The reference implementation shows the state in up to
three places at once: the spinner row, the footer's `ModeIndicator` and the
notifications (the footer shell renders the status line, the left side and the
notifications row). Ours has exactly one: the footer's row
(`src/tui.zig:6911` `drawStateFooter`). The comment at `:5513-5520` records
that the previous design had the activity strip **and** the mascot row saying
the same thing in two places.

**A footer that degrades in a defined order.** `src/tui.zig:7062-7076` — the
right-hand group gives up pieces from the tail (scroll hint → tok/s → ctx %)
and the model name is the last thing to go. The reference implementation's
footer just hides whole components at 80/24 columns (its `isNarrow` and
`isShort` rules).

**Contrast is tested, not asserted.** `src/lib/theme.zig` — the palette has
three ink steps with measured ratios (`:41` 18.1:1, `:43` 6.9:1, `:49` 5.6:1),
`line` deliberately below 3:1 because a rule must recede (`:52`), and a
`contrastOk` test that fails the build if a pair goes under the floor.
The reference implementation has a theme (the design system's theme provider)
but no equivalent contrast gate that we found.

**An ASCII mascot with a fixed width.** `src/tui.zig:74` `face`,
`:84` `faceFrames`, `:104` `face_width = 7` with the comment explaining that
the previous set used `◕` (U+25D5) and `×` (U+00D7), both **East Asian
Ambiguous** width. The blink only runs while there is work (`:6947`).

**A diff viewer with a word-level diff and a colour ladder.**
`src/lib/diffview.zig` (376 lines) computes the word ranges per row;
`src/lib/markdown.zig:120-130` documents that a collapsed diff shows the row
tints but not the word highlights, and that the expanded diff turns them on.
The reference implementation does the word diff in a Rust NAPI module
(`expectColorDiff()`).

**Overlays that survive wide cells.** `src/tui.zig:6165` `expandWideCells`
splits a wide cell into one cell per column before an overlay paints, and the
comment at `:6148-6164` explains exactly why: vaxis's renderer *skips* the
columns a wide cell covers, so a modal painted over the hero's 95-column rule
had a hole in it. Every overlay calls it (`src/tui.zig:7259` for the picker,
`:6373` for the permission dialog, `src/palette.zig:685` for the palette).
The reference implementation solves the same problem in the renderer
(`CellWidth.SpacerHead` / `SpacerTail`) but has no equivalent "expand before
painting" call, because its layout engine never produces a cell that claims
more columns than it prints.

**A scroll anchor that survives layout corrections.** Our anchor is
`(paragraph, offset)`, not an absolute line, because a paragraph's height is
an estimate until it is parsed (`src/tui.zig:5696-5710`, and the AGENTS.md
section "Scroll: the anchor was an absolute line").

**Selection.** `src/tui.zig:4146` `snapshotSelectableHistory`,
`:4190` `selectionPoint`, `:4231` `paintTextSelection` — mouse drag selection
with the selection painted on the surface. The reference implementation's is
far larger (its selection module, 917 lines) but it exists in both.

### 2.3 What we are missing

Stated plainly, from the inventory above:

* no alternate screen (we always write to the normal buffer, so the terminal's
  own scrollback keeps the history that scrolled off);
* no separate transcript screen (`ctrl+o`); `ctrl+r` is our *expand last tool
  result* (`src/tui.zig:5045-5054`), not a transcript;
* no "N new messages" pill, no sticky prompt header;
* no transcript search, no global search, no history search;
* no `▔`-style modal pane (our modals are centred boxes);
* no notifications/toasts;
* no markdown tables;
* no per-hunk line-number gutter (our diff has a gutter but not the
  `marker + number` layout the reference implementation computes per patch);
* no external-editor integration, no image paste, no stash;
* no user-rebindable keybindings;
* no OSC 8 hyperlinks;
* no context visualisation beyond three `/context` lines;
* no permission-mode pill in the footer, no effort glyph;
* no vim mode.

---

## 3. Port list

`PORT` = worth doing. `ALREADY` = we have it (or something equivalent).
`SKIP` = do not copy.

| # | Feature | Reference impl | Our ref | Verdict | Effort | Risk | Notes |
|---|---|---|---|---|---|---|---|
| 1 | Alternate screen (alt buffer) for the REPL | the REPL's alt-buffer wrapper, the `AlternateScreen` component and the fullscreen env probe | — | **PORT** | L | High | Kills the terminal's native scrollback; the reference implementation auto-disables it under `tmux -CC` for good reason. Only with an opt-in env flag. |
| 2 | Separate transcript screen (`ctrl+o`) | the global-keybindings hook that swaps the screen, and the REPL's transcript branch | `src/tui.zig:5045` (ctrl+r = expand last tool) | **PORT** | M | Med | Our transcript already exists in the history; the screen is a *view*, not new content. Needs a second layout path in `typeErasedDrawFn`. |
| 3 | `ctrl+e` show-all inside the transcript | the same global-keybindings hook (`ctrl+e` inside the transcript) | — | **PORT** | S | Low | Cheap once (2) exists; one flag in `Model`. |
| 4 | `▔`-divider bottom-anchored modal pane (slash-command screens) | the absolute modal box of the fullscreen layout (`MODAL_TRANSCRIPT_PEEK = 2`) | `src/tui.zig:5783`, `:5832` (centred boxes) | **PORT** | S | Med | A pane that keeps 2 transcript rows visible is cheaper on screen than a centred modal that hides the context. |
| 5 | Sticky prompt header when scrolled up | the `StickyPromptHeader` component of the fullscreen layout (fixed one row) | — | **PORT** | S | Med | Must be **fixed 1 row** (the reference implementation's own comment explains why a variable height shifts the view). Pairs with our `(paragraph, offset)` anchor. |
| 6 | "N new messages" pill / "Jump to bottom" | the `NewMessagesPill` component and the unseen-turn counter of the fullscreen layout | `src/tui.zig:7050-7060` (`↓ latest`) | **PORT** | S | Low | We already have `↓ latest` in the footer; the pill adds the *count* and a click target. We already publish its columns (`src/tui.zig:7117-7124`) and handle the click (`:5431-5439`). |
| 7 | Transcript search bar (`/`, `n`/`N`, match badge) and global search (`ctrl+shift+f`) | the search-highlight module, the screen renderer's `applyPositionedHighlight`, the REPL's transcript branch and the global-search dialog | — | **PORT** | M | Med | Needs a screen-buffer scan; our paragraphs are already segmented, so we can scan the segments instead of the cells. The global search is the same scanner over the whole session. |
| 8 | Prompt-history search (`ctrl+r`) | the global keybinding table (`ctrl+r`) and the history-search dialog | `src/tui.zig:5045` already used | **SKIP** | S | Med | Our ctrl+r is taken by *expand last tool result* and that is more useful day to day. The history can still be walked with ↑/↓ (`src/lib/editor.zig:18`). |
| 9 | Fuzzy picker with match highlighting and scored ordering | the design system's fuzzy picker (`DEFAULT_VISIBLE = 8`, `CHROME_ROWS = 10`) and its list-item component | `src/palette.zig:377-392` (substring + group match) | **PORT** | M | Low | Our filter is substring; a fuzzy scorer with the matched characters highlighted is a visible quality jump in a 464-model list. |
| 10 | Picker with a **preview pane** | the fuzzy picker's `renderPreview` slot, with `previewPosition: 'bottom' \| 'right'` | `src/palette.zig:666` | **PORT** | M | Med | A model preview (context window, price, whether it is free) next to the model list is the single most useful picker addition. |
| 11 | Slash-command suggestions as a floating overlay above the prompt | the absolute suggestions box of the fullscreen layout, portalled out of the prompt | `src/tui.zig:6008` `drawAutocomplete` (a block above the input) | **ALREADY** | — | — | Ours is inline in the flow; the reference implementation portals it so the prompt does not move. Ours does not move the prompt either (the rows are reserved at `:5530-5533`), so the behaviour matches. |
| 12 | Prompt box with a **rounded bottom border** | the prompt component's `borderStyle="round" borderBottom` | `src/tui.zig:5811` (a hairline above) | **SKIP** | S | Low | Ours deliberately replaced the box with a rule: it costs 2 rows and 4 glyphs to say what the rule says in one (`src/tui.zig:5801-5806`). The border is a *style*, not a capability. |
| 13 | Responsive footer: reflows to a column under 80 columns, drops the optional status line under 24 rows | the footer shell's `isNarrow` (`columns < 80`), `isShort` (`rows < 24`) and its row/column switch | `src/tui.zig:7062-7076` (drops segments from the tail), `:5544`, `:5546` | **ALREADY** | — | — | Ours degrades by dropping segments, the reference implementation by re-flowing into a column and by dropping the status line. Ours keeps the model name visible, which is the more useful of the two; but ours shrinks the *input* on a short terminal, which is the wrong trade — the input is the thing the user looks at. |
| 14 | User-configurable status line (an external command) | the status-line component: a user shell command fed a JSON payload | `src/tui.zig:7151` `sessionInfo` | **SKIP** | M | High | Running a user shell command on every model change is an execution surface we do not need; `/context`, `/bench`, `/cache` cover the same ground. |
| 15 | Random "verb" spinner (`Accomplishing…`, `Baking…`) | the spinner's verb list and the 50 ms spinner animation row | `src/tui.zig:6978` (`thinking`) | **SKIP** | S | Low | Ours says the *phase* (`thinking` / `streaming` / `running <tool>`), which is more informative than a random verb. The reference implementation's own comment on the phase distinction is in our AGENTS.md. |
| 16 | Thinking shimmer / glow animation | the spinner's shimmer/glow animation | — | **SKIP** | M | Med | A 50 ms animation frame is a permanent CPU cost; ours ticks at 250 ms when idle (`Model.tickIntervalMs`). |
| 17 | Stall detection (the spinner turns red) | the spinner's stalled-animation hook | `src/tui.zig:5644` (a live clock next to the tool) | **ALREADY** | — | — | Ours answers "is it stuck?" with an elapsed clock that is always on screen; the reference implementation with a colour change. Ours is more explicit. |
| 18 | Token count in the spinner after 30 s | the spinner animation row's `SHOW_TOKENS_AFTER_MS` gate | `src/tui.zig:7033-7049` (`⚡ N tok/s` while streaming) | **ALREADY** | — | — | Ours shows tok/s only while tokens are actually arriving (`:7033`), which is the fix the reference implementation's own notes describe. |
| 19 | Permission-mode pill + effort glyph in the footer (`accept edits on`, `○ ◐ ● ◉`) | the footer left side's mode pill, the figure constants for the effort glyph and the effort-indicator component | `src/commands.zig:609` (`/mode`), `:598` (`/effort`), `src/tui.zig:7151` `sessionInfo` | **PORT** | S | Low | The current mode is invisible in ours unless you open `/context` or `/mode`. Two one-segment additions to the footer's right group. The **effective** effort level must be shown, not the preference, or the footer says `xhigh` and the wire carries `high`. |
| 20 | `Press {key} again to exit` (double-press ctrl+c) | the footer left side's double-press message | `src/tui.zig:4996-5005` (ctrl+c clears the input, then exits) | **ALREADY** | — | — | Ours uses a two-press rule with a different semantic (clear, then exit). The reference implementation's message is friendlier. |
| 21 | Kitty keyboard protocol (`CSI u`) parsing | the keypress parser's kitty (`CSI u`) branch | vaxis | **ALREADY** | — | — | vaxis owns the terminal protocol layer; we should not re-implement it. |
| 22 | OSC 8 hyperlinks | the hyperlink-support detection module | — | **PORT** | S | Low | File paths and URLs in the transcript as real hyperlinks. vaxis exposes the cell attributes; the detection (TERM_PROGRAM / LC_TERMINAL / COLORTERM) is ~30 lines. |
| 23 | Mouse selection + `ctrl+shift+c` copy | the selection module and the global keybinding table's copy binding | `src/tui.zig:4146`, `:4231` (selection), `:5018` (`/copy`) | **ALREADY** | — | — | We have selection and a copy command; we lack the `ctrl+shift+c` shortcut. Add the key, not the machinery. |
| 24 | Markdown tables | the markdown-table renderer (a flexbox grid) | `src/lib/markdown.zig:16` (`Kind` has no table) | **PORT** | M | Med | Models emit tables. Ours renders them as prose. A grid renderer is a contained addition to `markdown.zig`. |
| 25 | Diff gutter = marker + right-aligned line number, per hunk | the structured-diff component's `computeGutterWidth(patch)` | `src/lib/diffview.zig`, `src/tui.zig:548` `diffRowIndent` | **ALREADY** | — | — | Our gutter exists; the reference implementation's *width is computed from the patch*, ours is per-row. Equivalent in effect. |
| 26 | Narrow-terminal fallback when the gutter does not fit | the structured-diff component's narrow-terminal skip | `src/tui.zig:514` `appendContinuation` | **ALREADY** | — | — | Ours clips and indents the continuation; the reference implementation drops the split. Both are correct. |
| 27 | Modal diff viewer navigating between files / old-new sides | the diff dialog component and the global keybinding table's diff bindings | `src/tui.zig:5045` (ctrl+r expands one result inline) | **PORT** | L | Med | A diff *dialog* is a different feature from an inline diff. Only worth it if we get multi-file diffs in one turn. |
| 28 | Notifications / toasts with priority and timeout (+ the token-budget warning) | the prompt's notifications component, the notification-context store and the token-warning component | `src/tui.zig:5775` (the `ask` panel only), `:7204` `contextInfo` | **PORT** | M | Med | We push everything into the transcript; the reference implementation has a transient channel for "the auto-updater restarted", "the IDE connected", "the token budget is nearly gone". A one-line queue above the input (absolutely positioned, so nothing shifts) is a contained change. The same queue can carry the **token-budget warning**: we show the percentage, the reference implementation shows a warning with a threshold and the collapse progress. |
| 29 | Context visualisation (per-category breakdown) | the context-visualisation component (a proportional chart per category) | `src/commands.zig:614` (`/context`, 3 lines) | **PORT** | M | Med | We already compute the token counts; the reference implementation draws a proportional chart per category (system prompt, tools, messages, MCP, skills, autocompact reserve). High information density per row. |
| 30 | Task/todo panel with blockers and priorities | the task-list panel (`maxDisplay`, the truncation priority, the open blockers) | `src/lib/taskstore.zig:123` (`Store`, `link`, `hasOpenBlocker`), `src/tui.zig:6440` `drawPlanBlock` | **PORT** | M | Med | The **data model already exists** (the task graph with `blocked_by`) but is not surfaced. A panel is the missing half. |
| 31 | Message actions per message (copy / rewind) | the per-message actions module and the global keybinding table's `shift+↑` binding | `src/commands.zig:623` (`/copy N`) | **PORT** | M | Med | The reference implementation binds `shift+↑` to a per-message menu. Ours has `/copy N` (N answers back) but no per-message targeting. A `shift+↑` that targets the message under the cursor would make `/copy` redundant. |
| 32 | Quick open file palette (`ctrl+shift+p`) | the quick-open dialog | `src/tui.zig:4743` `refreshFileMatches` (`@` mention popup) | **ALREADY** | — | — | The `@` popup is the same capability with a different trigger. |
| 33 | Compact-summary line ("Summarized N messages … (ctrl+o to expand history)") | the compact-summary component | `src/lib/compaction.zig` (no visible marker) | **PORT** | S | Med | After a tier-2 compaction the transcript silently loses history. A one-line marker saying what was summarised is cheap and honest. |
| 34 | Permission dialog with a **rules explanation** (`ctrl+e` toggles it) | the permission rule-explanation component and the confirmation context's `ctrl+e` binding | `src/tui.zig:6352` `drawPermissionModal` | **PORT** | M | Med | Our dialog shows the tool and the argument; the reference implementation also explains *which rule* matched and lets the user edit the rule. That is the "always allow" story. |
| 35 | Permission dialog shape (top border only, no sides) | the permission dialog's top-border-only box | `src/tui.zig:6378-6388` (a full box) | **SKIP** | S | Low | A full box is more visible, and ours is a *modal* on purpose: the AGENTS.md notes the previous four-line version looked like a hang. Visibility wins. |
| 36 | "Waiting for permission…" suppression line above the prompt | the prompt component's suppressed-permission line | `src/tui.zig:6958` (the footer says `waiting for your permission`) | **ALREADY** | — | — | Ours says it in the one state surface. |
| 37 | Queued prompts shown above the prompt | the prompt's queued-commands strip | `src/tui.zig:6986` (`N queued` in the footer) | **ALREADY** | — | — | Ours shows the count, the reference implementation shows the text of the next one. A small upgrade worth taking. |
| 38 | External editor (`ctrl+g`) | the global keybinding table's `ctrl+g` and the prompt component's external-editor branch | — | **PORT** | S | Med | `!cmd` already exists as a shell-out; an external editor for a long prompt is the same idea with a better editor. |
| 39 | Image paste (`ctrl+v`) | the global keybinding table's `ctrl+v` | `src/lib/images.zig` (images exist) | **PORT** | M | Med | The infrastructure is already there. |
| 40 | Startup logo / welcome screen | the startup logo / welcome screen component | `src/tui.zig:6239` `heroFrame` | **ALREADY** | — | — | Ours shows a centred hero only when the conversation is empty (`:6240-6241`). Same intent. |
| 41 | Keyboard-shortcut help in the footer (`? for shortcuts`) | the prompt's help menu and the footer shell's `? for shortcuts` hint | `src/commands.zig:592` (`/help`) | **PORT** | S | Low | A `?` hint in the footer that opens the key list. Cheap, and the discoverability win is real. |
| 42 | Terminal focus detection (dim the cursor when the window is not focused) | the text input's `canShowCursor` check | — | **PORT** | S | Low | vaxis reports focus events; hiding the caret in an unfocused terminal is the standard behaviour and prevents a "phantom cursor" in a screenshot. |

---

## 4. Porting notes

Ten rows, in the order they would be built.

### 4.1 (2 + 3) The transcript screen — `ctrl+o`

**Files:** `src/tui.zig` (`typeErasedDrawFn`, `Model`), `src/agent.zig`
(`commands`), `src/commands.zig` (the command table).

**Data flow.** The transcript is not new content: it is the same
`Model.paras` list, rendered without the composer. The cheapest correct
implementation is a **mode flag on the Model**, read by the draw:

```
Model.transcript: bool          // ctrl+o toggles it
Model.transcript_show_all: bool // ctrl+e toggles it
```

In `typeErasedDrawFn` (`src/tui.zig:5473`) the layout block at `:5494-5556`
computes `history_h` from `height - chrome - 2`. In transcript mode the
chrome is zero and `history_h = height`, and the composer rows are not
painted at all. Everything else (the segment cache, `layoutFor`, the
scrollbar) is reused unchanged.

**What could break.**

* The segment cache is keyed on width only (`src/tui.zig:5568`), so switching
  modes does **not** invalidate it. That is correct, but it means the
  transcript and the prompt share the cache and the eviction window
  (`seg_cache`) has to hold both. With `max_cached_paras` entries and a long
  session the transcript may re-parse on every scroll. Measure before
  assuming it is fine.
* The scroll anchor is `(paragraph, offset)`; entering the transcript has to
  keep or reset it deliberately. Resetting to the bottom on entry is the
  reference implementation's behaviour (its unseen-divider hook).
* The `↓ latest` click target is published from the footer
  (`src/tui.zig:7117-7124`); in transcript mode there is no footer, so the
  target must be cleared or the click will scroll a screen that is not there.
* The permission modal and the ask panel are drawn **after** the composer
  (`:5832`, `:5844`). In transcript mode they must still be drawn, or the user
  cannot answer the model.

### 4.2 (5 + 6) Sticky header and the "N new" pill

**Files:** `src/tui.zig` (`Model`, `typeErasedDrawFn`, `layoutFor`).

**Data flow.** Two new published fields on the Model, set by the draw:

```
Model.sticky_prompt: ?[]const u8   // the prompt of the turn being read
Model.unseen_count: usize           // turns since the user scrolled away
```

`unseen_count` must be counted the way the reference implementation counts it
(its unseen-turn counter): assistant *turns* with visible text, not raw
entries — a tool-only entry does not tick the counter.

**What could break.**

* The reference implementation's sticky header is **fixed at one row** for a
  reason (its own comment says so): a variable height shifts the scroll box
  and the content jumps. Ours must reserve the row unconditionally, or the
  transcript will move every time the sticky prompt changes.
* The row has to be painted *before* the history, and the history area is
  cleared at `src/tui.zig:5728-5731` — so the sticky row must be outside
  `history_h`, or the clear will erase it.
* `history_h` is computed at `:5554` and published as `self.hist_rows`
  (`:5556`). A sticky row changes that number, and the key handlers use it
  to size a page (`:5555`).

### 4.3 (9 + 10) Fuzzy picker with a preview

**Files:** `src/palette.zig` (`matches` at `:377`, `draw` at `:666`,
`boxFor` at `:636`), `src/tui.zig` (`drawPicker` at `:7243`).

**Data flow.** `matches` becomes a **scorer** that returns a score plus the
matched character positions, and `drawColumn`/`draw` paint the matched
characters in the accent colour. The preview is a third column or a bottom
pane in `boxFor` (`:646-650` already computes a two-column split).

**What could break.**

* `boxFor` computes `w = min(width - 4, 110)` and `col_w = max(18, w/3)`.
  A third column (or a preview pane) has to fit inside that, and the model
  ids are up to 40 characters (`src/palette.zig:637-641`). At 110 columns
  there is no room for a third column — the preview must be a **bottom pane**,
  and it costs rows: `list_rows` is computed as `h - 5` at `:651`.
* The palette's scroll is measured in **rows**, not items
  (`src/palette.zig:782` `columnRows`, `:801` `selectedRow`), because the
  group headers live inside the list. Adding a preview does not change that,
  but changing the header rows does.
* Every overlay must call `tui.expandWideCells` on the rows it paints
  (`src/palette.zig:685`); a preview that is painted after the item rows must
  not reintroduce a wide cell.
* The items are owned by the palette (`setItemsOwned`); a preview that holds
  a slice of an item's description must be a copy, not a borrow, for the same
  reason the labels are.

### 4.4 (13) Narrow / short terminal reflow

**Files:** `src/tui.zig` (`drawStateFooter` at `:6911`).

**Data flow.** The footer already degrades by dropping segments
(`:7062-7076`). Adding the reference implementation's behaviour means
**re-flowing** the left group below the right group when `width < 80` — which
costs a row, and the footer row is deliberately always one row
(`:5547-5549`).

**What could break.** The input's height would jump when the terminal is
resized across 80 columns. The right answer is the reference implementation's
one (its `isShort` reduction): it drops the *optional* content, not the row
count. Ours would have to drop the ctx % or the tok/s, not add a row.

### 4.5 (19) Permission mode and effort glyph in the footer

**Files:** `src/tui.zig` (`sessionInfo` at `:7151`, `drawStateFooter` at
`:6911`), `src/agent.zig` (the effective effort), `src/lib/theme.zig`.

**Data flow.** `sessionInfo` already produces `[]InfoSeg`; the mode and the
effort are two more segments. The effort level must be the **effective** one
(the one that will be sent, after the per-model degradation), not the
preference — otherwise the footer says `xhigh` and the wire carries `high`,
which is the exact drift the AGENTS.md warns about.

**What could break.** The right group is capped at 12 segments
(`src/tui.zig:7010`) and the dropping loop at `:7068` removes from the tail.
Adding two segments at the **front** of the group changes which piece falls
off first. Put them after the model name, and re-check the drop order.

### 4.6 (24) Markdown tables

**Files:** `src/lib/markdown.zig` (`parse` at `:104`, `Kind` at `:16`),
`src/tui.zig` (`buildLines` at `:565`, `wrapCells` at `:432`).

**Data flow.** A table is a block in the parsed stream, and the block's
renderer produces `PLine`s directly (the same way the diff and the code
fence do), rather than going through the prose path.

**What could break.**

* The invariant "the concatenation of the segments is the original line"
  (tested in `markdown.zig`) has to hold for the table's own rows too.
* The table must be measured in **columns**, not bytes (the `rowText` trap):
  a table cell with a CJK character is two columns wide.
* A table wider than the terminal has to be clipped or wrapped **per cell**;
  the wrap width is `wrap_width` (`src/tui.zig:5675-5680`) and the history's
  margin is `historyMargin(width)` (`:6102`).
* The table is not prose: the parser must not interpret a `|` row as a
  paragraph, the same way the diff has its own path (see the AGENTS.md
  section "The diff you can read").

### 4.7 (28) Notifications and the token warning

**Files:** `src/tui.zig` (the draw), `src/agent.zig` (the queue),
`src/lib/theme.zig` (`warn`).

**Data flow.** A small queue on the Model, drained by the draw:

```
Model.notices: []Notice   // {text, style, expires_at}
```

Painted **above the input** in the `chrome` rows already computed at
`src/tui.zig:5543` (the same rows the autocomplete popup uses at `:5530`).
The reference implementation's trick is to make the notification layer
*absolutely positioned* so it does not shift the prompt; ours cannot do that
(there is no absolute positioning in the surface), so the rows have to be
**reserved** — which means the autocomplete popup and the notification cannot
both be visible, or the layout needs one more reserved row.

**What could break.** The input's height would jump every time a notice
appears or expires. The reserved-row approach fixes that but costs a row
permanently, which is exactly the kind of permanent furniture the footer
redesign removed.

### 4.8 (30) The task panel

**Files:** `src/lib/taskstore.zig` (`Store` at `:123`, `hasOpenBlocker` at
`:421`), `src/tui.zig` (`drawPlanBlock` at `:6440`), `src/agent.zig` (the
binding to the session).

**Data flow.** The store is already bound to the session
(`src/lib/taskstore.zig:567` `bind`) and already knows the blockers
(`:433` `openBlockers`). The panel is a **render** of the store, in the
`plan_rows` slot that `drawPlanBlock` uses today — but the plan block is one
row (`:5527`) and the panel needs up to ten.

**What could break.**

* `plan_rows` is computed at `src/tui.zig:5527` as 0 or 1 and it feeds
  `chrome` (`:5543`) and therefore `avail` and `input_h`. A ten-row panel
  takes ten rows from the transcript.
* The store is **not thread-safe**: it is an `ArrayList` per slot with no
  lock (`src/lib/taskstore.zig:123`). The draw reads it on the UI thread
  while a worker may be writing it from the tool call. This is the same
  hazard the task-graph section of the AGENTS.md describes for the parallel
  batch; the panel needs a snapshot.
* The reference implementation's own panel **prioritises** the rows it shows:
  recently completed first, then in progress, then unblocked pending. A naive
  "first N rows" panel would hide the step the agent is on.

### 4.9 (34) Permission dialog with the rule explanation

**Files:** `src/tui.zig` (`drawPermissionModal` at `:6352`), `src/agent.zig`
(the permission flow).

**Data flow.** The dialog has to gain a second state — "which rule matched"
— and a toggle. The existing dialog is 9 rows tall and fixed (`:6361`); the
explanation needs more, and the height must be **clipped to the screen**
(the same clipping the ask panel already does).

**What could break.**

* The dialog is centred (`:6364`) and its height is fixed; a variable height
  means the box jumps when the explanation is toggled, and the user is
  halfway through answering with the mouse.
* `expandWideCells` must be called on the rows the dialog paints
  (`:6373`) — including the rows the explanation adds.
* The permission modal is drawn **after** the composer (`:5832`), so a taller
  dialog covers the input. That is intended (it is a modal) but it must not
  cover the footer's row if the user needs the phase.

### 4.10 (22) OSC 8 hyperlinks

**Files:** `src/lib/theme.zig` (a link style), `src/tui.zig`
(`Painter.putStable` / `putText`), `src/lib/termseq.zig` (the OSC 8 writer).

**Data flow.** vaxis's `Cell` carries the attributes; the OSC 8 sequence has
to be written into the cell's grapheme bytes (the `putStable` trap: the bytes
must live in the frame's arena, `src/tui.zig:6165` is the wide-cell splitter,
and `putStable` does not copy).

**What could break.**

* The grapheme bytes are read by the renderer **after** `drawFn` returns, so
  the OSC 8 payload must be in the frame's arena, not on the stack.
* A URL in a cell changes the cell's **width** calculation: the OSC 8
  sequence is zero-width, and `theme.graphemeWidth` (`src/tui.zig:7136`) has
  to be told to ignore it, or the column arithmetic of the whole row shifts.
* Terminals that do not support OSC 8 will print the sequence literally.
  The detection has to be per-terminal (`TERM_PROGRAM`, `LC_TERMINAL`,
  `COLORTERM`), exactly as the reference implementation does (its
  hyperlink-support detection reads the same three variables).

---

## 5. Things the reference implementation does that we should NOT copy

1. **The alternate screen as the default.** The reference implementation's own
   code auto-disables it under `tmux -CC` because alt-screen plus mouse
   tracking corrupts the terminal (the `isFullscreenEnvEnabled` /
   `isTmuxControlMode` pair), and it leaves the tmux `mouse` option alone on
   purpose. Our terminal scrollback is a feature: the history that scrolled
   off is still there after the app exits. If we ever port it, it must be
   opt-in, and it must keep the mouse off by default.

2. **The random verb spinner** (the spinner's verb list).
   "Accomplishing…" says less than "running Bash · 12.4s", and our footer
   already names the phase. A verb is decoration that costs a 50 ms animation
   frame.

3. **The thinking shimmer** (the spinner's shimmer/glow animation).
   A permanent 50 ms repaint of the whole screen to make three words glow.
   Ours ticks at 250 ms when idle.

4. **The external status-line command** (the status-line component).
   It runs a user shell command with a JSON payload on every model or message
   change. It is an execution surface, and `/context`, `/bench` and `/cache`
   already answer the same questions.

5. **The prompt box with a rounded bottom border**
   (the prompt component's `borderStyle="round" borderBottom`). Ours replaced
   the box with a single hairline deliberately (`src/tui.zig:5801-5806`): a
   box is two extra rows and four more glyphs to say "this is the boundary of
   the page". This is a style choice that was made on purpose and measured
   ("eleven rows of furniture before the first word").

6. **The permission dialog as a top-border-only pane**
   (the permission dialog's `borderBottom={false}` box). Ours is a centred
   box with a clean background, and the reason is in the AGENTS.md:
   the previous version was four lines glued above the input, half hidden
   under a full history, and the app looked hung. Visibility wins over
   elegance for the one dialog that blocks the turn.

7. **Two state indicators.** The reference implementation can show the spinner,
   the mode pill, the notifications and the status line at the same time
   (the footer shell renders the status line, the left side and the
   notifications row). Ours has exactly one state surface
   (`src/tui.zig:6911`) and that is a deliberate rule ("un solo indicador de
   estado"), not an accident.

8. **Rewinding the conversation** (the message selector, 830 lines).
   It changes the session's semantics; it is a product feature,
   not chrome, and it is the one thing in this list that could corrupt state.

9. **Vim mode.** A mode system inside the editor for a user base that mostly
   types plain text.

10. **User-rebindable keybindings.** The reference implementation's system is a
    table plus a parser plus a validator plus a reserved-shortcut list. Ours is
    a short hard-coded chain (`src/tui.zig:4996-5054`). If the chain ever
    needs rebinding, the table is the right shape — but porting the whole
    subsystem before there is a demand for it is the kind of thing that rots.

11. **The `⎿` gutter repeated at every nesting level.** The reference
    implementation suppresses nested `⎿` with a context flag on the result
    component. Ours does not have nested results, so this is a non-issue — but
    if a nested result ever appears, the suppression has to come with it.

---

## 6. Open questions

1. **How much of the reference implementation's layout is the Yoga flexbox
   doing?** Its composition uses `flexGrow`, `flexShrink`, `maxHeight="50%"`
   and `position="absolute"`. Our layout is hand arithmetic
   (`src/tui.zig:5494-5556`). Before porting the transcript screen we should
   measure how much of the reference implementation's *appearance* comes from
   the flexbox rather than from the components. The `maxHeight="50%"` on the
   bottom slot is the part that has no equivalent in ours.

2. **What does the reference implementation's `Ratchet` actually save?** It
   keeps the box's height while the content is off-screen, so an off-screen
   block does not collapse. Our segment cache (`src/tui.zig:5572-5585`) is the
   equivalent idea, but we do not know whether the reference implementation's
   saving is significant at our scale (we cap the cache at 128 paragraphs).

3. **Is the "N new" pill worth the count semantics?** The reference
   implementation counts assistant *turns* with visible text and skips
   tool-only entries. Our history has paragraphs, not messages, so the mapping
   from "turn" to "paragraph" is not obvious: a turn that produced three tool
   calls and one answer is four paragraphs in ours and one turn in the
   reference implementation.

4. **How does the reference implementation handle the transcript when the
   prompt is unmounted?** It swaps the bottom slot for a
   `TranscriptModeFooter`; the *notification* and *permission* channels then
   have no home. We would have the same problem, and the answer is not
   obvious.

5. **Does the reference implementation's mouse selection survive a `tmux` pane
   without the `mouse` option?** Its fullscreen module has a dedicated hint
   for exactly that (`maybeGetTmuxMouseHint`). We have a selection
   implementation (`src/tui.zig:4146`) and we have never tested it inside
   tmux with `mouse off`.

6. **What is the actual default for `CLAUDE_CODE_NO_FLICKER` for external
   users?** The code says "off for external users
   (`CLAUDE_CODE_NO_FLICKER=1` to opt in)" in the comment next to the
   fullscreen layout's alt-buffer branch, but `isFullscreenEnvEnabled()`
   returns `process.env.USER_TYPE === 'ant'` at the end, so for an external
   user the default is **off**. The comment is right but the way it is phrased
   is ambiguous.

7. **Does the reference implementation's `▔` divider have a name or is it just
   `"\u2594"`?** The absolute modal box uses the literal
   `"\u2594".repeat(columns)`. It is the same character as `▔` but with the
   `REPEAT` semantics of a "heavy up" bar. If we port the pane, we should
   check whether the intent was a *half-height* rule (which reads as a
   "sheet of paper sliding up") rather than a full rule.

8. **How much of the reference implementation's visual identity is the theme
   file?** We did not find its theme module in this pass, so the comparison of
   palettes (the design system's theme provider) is incomplete. Our
   `src/lib/theme.zig` has a measured contrast contract that the reference
   implementation does not appear to have; that is a difference in *quality*,
   not in feature, and it should not be traded away.

9. **Is the reference implementation's `CtrlOToExpand` chip visible by
   default?** It is rendered inside the transcript's collapsible blocks and
   returns `null` inside a sub-agent or a virtual list. We could not determine
   whether the chip appears in the normal chat transcript.

10. **What is the reference implementation's behaviour when the terminal is
    narrower than the permission dialog?** Its permission dialog has no width
    handling of its own; it relies on Yoga. Our
    `drawPermissionModal` returns early when `w < 30` (`src/tui.zig:6360`),
    which means **no dialog at all** on a very narrow terminal — a
    permission request that cannot be answered is a hang. This is a bug on
    our side that the reference implementation cannot have; it is not in the
    port list because it is ours, but it should be fixed.

---

*Generated from the reference implementation's source and from `src/` at
commit time. Every claim about **ours** is anchored to a `path:line` in
`src/`; the claims about the reference implementation name the component and
describe the mechanism, because that tree is not part of this repository. No
source file was modified.*
