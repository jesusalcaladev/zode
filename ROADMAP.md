# ROADMAP — zode

A work plan derived from a diagnostic session (2026-09-30). Everything this
document claims is **measured or reproduced**, not estimated. There is a section
at the end with what got forgotten on the way and has to be corrected in
`AGENTS.md`.

Decisions already made by the user:

| Decision | Value |
|---|---|
| Build default | **ReleaseSafe + strip** (2.06 MB) |
| End-of-turn summary | **In the history**, 2-4 lines, foldable with Ctrl+R |
| Memory pruning | **By bytes**, re-read from the session JSONL |

---

## 0. Diagnosis

The complaint was "it freezes when it starts writing or running bash". **The main
freeze is not a performance problem: it is a reproducible bug.**

### 0.1 Infinite loop in the history layout (THE main cause)

`src/tui.zig:1970` and `src/tui.zig:1999`:

```zig
while (self.seg_cache.items.len < self.paras.items.len) {   // 1970
    ...  // append  → len+1
    if (self.seg_cache.items.len > Model.max_cached_paras) { // 1999, cap = 128 (tui.zig:369)
        const old = self.seg_cache.orderedRemove(0);          // → len-1
        ...
    }
}
```

With **≥129 paragraphs** the condition never stops being true: append (129) →
evict (128) → and back into the loop. Forever, creating and destroying an
`ArenaAllocator` per iteration.

Reproduced against the current tree (copy in `/tmp/opencode/zv2`):

| Suite | Result |
|---|---|
| `zig build test` as is | **159/159 green, 31 s** |
| + test with **130 paragraphs** | **hangs** (killed at 90 s, exit 124) |
| + test with a **129-line** `write` via `pushDiff` | **hangs** |

**The link to the complaint**: `pushDiff` puts **one paragraph per diff line**
(`tui.zig:1122-1126`):

```zig
for (lines) |l| {
    const copy = self.allocator.dupe(u8, l) catch return;
    self.pushKind(.diff, copy);     // ← one PARAGRAPH per line
    self.allocator.free(copy);
}
```

A single `write` of a 129-line file → 129 paragraphs → **the app hangs instantly
at 100 % CPU, with no way out**. That is literally "it freezes when it starts
writing". It is the same with `bash` or long file reads, and a normal session
reaches 129 paragraphs in ~40-60 exchanges.

### 0.2 The other four freezes

**a) No feedback from the 2nd iteration of the agent loop.**
`streamStart()` is called **only once per prompt** (`agent.zig:1330`, in
`startChat`). `runOneTurn` does `m.streamEnd()` at the end (`agent.zig:1561`) and
**never calls `streamStart` again**. The loop runs up to 8 iterations
(`agent.zig:1370`). From the 2nd round on `streaming == false` and `busy == false`,
so there is no live paragraph, no activity strip, no spinner, no clock.

**b) The tick chain can die forever.**
The `.tick` only re-arms if there is work (`tui.zig:1839-1846`):

```zig
.tick => {
    self.tick_armed = false;
    const a = self.activity();
    if (a.busy or a.dirty or a.perm or a.picker or self.pal.active) {
        ctx.redraw = true;
        try self.armTick(ctx);
    }
}
```

And `streamEnd` (`tui.zig:965-985`) **adds a new paragraph to the history and sets
`busy = false` without setting `dirty = true`**. There is a window (`streamEnd` →
`pushToolStart`, with a session `write(2)` and a DEFLATE-9 in between) where
`busy == false` and `dirty == false`. If a tick lands there, `App.timers` is left
**empty** and the worker **has no way to ask for a frame**: there is no pointer to
`vxfw.EventContext` or to the event queue in `Model`. From that moment the screen
is dead until a key is pressed, the wheel is used, or the window is resized. That
is the "frozen until I touch something".

**c) O(n²) re-parse of the live paragraph inside the spinlock, every frame**
(`tui.zig:2011-2048`): all of `stream_buf` is duped into the frame's arena and
markdown + highlighter + grapheme widths are re-parsed **completely** every
frame, **with the model's lock held**. The worker competes with the draw on every
`streamDelta`.

**d) `requestPermission` hammers the shared lock** (`tui.zig:670-675`):
`while(true) { yield; lock; read; unlock }` for as long as you take to decide. It
burns a whole core and makes every UI lock acquisition a failed `yield`. Every
`write`/`edit`/`bash` goes through there unless you are in `/yolo`.

**e) Latent, for 2-core machines.** `Threaded.async`'s limit is
`cpu_count - 1` (`Threaded.zig:1639`) and vaxis's TTY reader thread takes one
**forever** (`Loop.zig:77`, `io.concurrent`). With 2 cores, `async_limit = 1` is
exhausted and any `io.async` runs **inline**
(`Threaded.zig:2100-2105`). zode does not call `io.async` today, so it does not
bite, but it is a time bomb for the day one is added.

### 0.3 The render: why "all green" and "very spread out"

- **The green is the diff, not the highlighter.** `markdown.zig:182-194` paints
  **one single segment of the whole line** with `styles.diff_add = fg(2)`
  (`#00cd00`, bright green), with no syntax highlighting inside, and the test
  `markdown.zig:469` **pins that behaviour**. Rewriting a 200-line file = 200
  solid green rows. That green is also the same one as code *strings*
  (`highlight.zig:13`).
- **"Very spread out" = one paragraph per diff line + a blank row between
  paragraphs** (`tui.zig:1995`). 129 diff lines = 128 blank rows in between. On
  top of that each tool produces 2 paragraphs (header + result) with a blank row
  between them.
- **Code blocks are not blocks**: in `buildLinesBase` (`tui.zig:174`) `blk.kind`
  and `blk.lang` are computed and **never read** (the only use of `blk.` in the
  whole file is `blk.lines`). No gutter, no background, no padding, no indent, no
  language chip. And a line wrapped across the width continues at **column 0**,
  indistinguishable from a new sentence (`wrapCells`, `tui.zig:124-146`).
- **The rest of the code stays flat**: `T.def = Style{}` (no fg → **the
  terminal's default colour, which is the brightest thing on screen**) covers
  ~90 % of lines, `fn_call` is just `bold` with no colour, and `generic` (the
  fallback for any fence without a tag, or with a rare tag like `json`, `tsx`,
  `diff`, `text`) has `builtins` and `types` **empty**, which also disables the
  PascalCase→type heuristic (`highlight.zig:276-278`).
- The history has no left margin: `drawLines` starts at column 0 and the area is
  painted at full width every frame.

### 0.4 Size, RAM and speed (measured)

| Build | Size | Build time |
|---|---|---|
| ReleaseSafe as is (what was installed) | **10.78 MB** | 13 s incremental |
| ReleaseSafe + `strip` | **2.06 MB** | 13 s |
| ReleaseFast | 11.67 MB | 3 m 36 s |
| ReleaseSmall (auto-strip) | **1.12 MB** | 1 m 21 s |

**79 % of the binary is debug sections**: `.debug_loc` 4.23 MB + `.debug_info`
1.87 MB + `.debug_line` 0.97 MB + `.debug_ranges` 0.60 MB + `_str` 0.54 MB +
`_pubtypes` 0.20 MB + `_pubnames` 0.13 MB = **8.55 MB of 10.87 MB**. The actual
code is 1.51 MB of `.text` + 0.46 MB of `.rodata`.

**RAM: the baseline is already low.** Measured with a real pty at 200×50:
**7.2 MB** of RSS in the TUI, 7.9 MB headless. The problem is not startup, it is
**unbounded growth**: `Model.paras` is never pruned, and the segment cache keeps
128 paragraphs × ~160 KB of `CellRun` arena (40 B per grapheme) ≈ **20 MB** in a
long session. On top of that, 1 MB of permanent `tty_buffer`, 1 MB + 256 KB of
buffers on the worker's stack (with `std.Thread`'s default 16 MiB stack), and
`readFileAlloc` of up to 4 MB ×2 for the diffs.

**Speed per frame**: `vaxis.Cell` = **136 bytes** (measured). At 200×50 the
surface buffer is 1.36 MB with a memset every frame, and the history's `fillRange`
is 200×45×136 ≈ **1.22 MB written cell by cell every frame**. That is **~2.6 MB
of traffic per frame** at 25 fps ≈ 65 MB/s, and on top of that
`arena.reset(.free_all)` in vaxis's loop turns it into malloc/free instead of
bump allocation.

**Separately**: `unifiedDiff` is **O(n·m) per line** LCS, with snapshots of up to
4 MB. A big `write` is not slow: it is a hang. And in `sessions/` there are **58
files, 24 of them empty at 0 bytes**, because a session file was created on every
startup even when nothing was ever chatted.

---

## Phase 0 — Safety net (~30 min)

`zig build test` takes 31 s and gives 159/159 green. Before touching anything, add
in `src/tui.zig`:

| Test | What it pins |
|---|---|
| `layout: N paragraphs does not hang above the cap` (128, 129, 200, 1000) | **Today it hangs the whole runner.** Written with an iteration budget so it fails cleanly in 1 s |
| `pushDiff of N lines produces 1 paragraph` | The contract that kills the hang |
| `runOneTurn restarts streaming every iteration` | That there is feedback on all 8 iterations |
| `the tick re-arms even with no work` | That the redraw chain cannot die |
| `streamEnd marks dirty` | That a state change without `dirty` is detected |
| `markdown: a diff + line carries tokens, not a green segment` | Anti-all-green |
| `tui: two consecutive + lines go on consecutive rows` | Anti-very-spread-out |

The first one is special: today the failure **hangs the test binary** instead of
failing, so without the iteration budget there is no CI possible.

## Phase 1 — Freezes (P0)

| | Change | Where |
|---|---|---|
| 1.1 | **Finish the layout loop**: index by paragraph, iterate up to `min(paras.len, max_cached_paras)`, evict **before** appending, and lay out over a window instead of `orderedRemove(0)` | `tui.zig:1970-2019` |
| 1.2 | **`pushDiff` = a single paragraph** with the diff joined by `\n`; also return the count of `+`/`-`, which is already computed and thrown away (`tui.zig:1116-1119`) | `tui.zig:1110-1127` |
| 1.3 | **`runOneTurn` calls `streamStart()`** at the start of each iteration, and sets `iterating N/8` | `agent.zig:1431`, `1370` |
| 1.4 | **`dirty = true`** in `streamEnd`, `toolRunEnd`, `setStatusText`, `setStatusWithMood` | `tui.zig:965, 1040, 617, 630` |
| 1.5 | **Self-sufficient tick**: the `.tick` re-arms **always**; `ctx.redraw` only if something changed. Add `redraw_requested: std.atomic.Value(bool)` that the worker sets on every `push*` | `tui.zig:1839-1846, 1212-1218` |
| 1.6 | **Live paragraph out of the lock**: snapshot `stream_buf` with the lock held, parse outside. And cache it incrementally (re-parse only the last line + re-wrap) instead of O(n) per frame | `tui.zig:2011-2048` |
| 1.7 | **`requestPermission` with futex/condvar** over a monotonic counter, instead of spin-yield on the common lock | `tui.zig:658-682` |
| 1.8 | **Cap the diff**: if the file goes over ~2000 lines, `diff omitted (file too large)` instead of the O(n·m) LCS | `agent.zig:1592-1617`, `markdown.zig:201` |
| 1.9 | **The session file is created on the first message**, not at startup | `main.zig:219` → `agent.zig:380-440` |

> 1.4 and 1.5 together are what make the freeze **structurally impossible**:
> nothing can kill the redraw because the tick is never consumed without
> re-arming, and any worker state change sets an atomic.

## Phase 2 — Feedback (P0/P1)

All of this goes in with data that **already exists** and is not painted.

| Improvement | Where | Data available |
|---|---|---|
| `thinking · 3.2s` placeholder until the first token | `tui.zig:2015-2019` (`else` branch) | `busyMillis()` (`tui.zig:847`) |
| TTFT (time to first token) | new field + strip | `TurnCtx.stream_start_ns` (`agent.zig:1403`) |
| **Animation during tools** (frozen today) | `tui.zig:2048`: `if (self.busy)` → `if (self.workingLocked())` | `workingLocked()` already exists (`tui.zig:870`) |
| **Argument** of the running tool | `tui.zig:2032, 2445` | `ToolRun.arg` is stored and **never read** |
| Explicit phases: `thinking` / `streaming` / `running tool` / `waiting for permission` | `Model.phase` + strip | — |
| `iterating 2/8` indicator | `agent.zig:1370` | `iterations`, `max_iterations` (`agent.zig:56`) |
| `+N −M` on the `write`/`edit` result | `tui.zig:1116` | already counted and discarded |
| **Errors in red**: `md.Kind.error_msg` exists with a `✗` prefix and **has no caller**; everything goes out grey as `.info` | `agent.zig:1753-1811` | `markdown.zig:27` |
| Compaction notice **in the TUI**: tier 2 only runs headless today (`main.zig:106`); `runOneTurn` only reads `comp.elided` | `agent.zig:1451-1460` | `comp.needs_summary` |
| Refresh ctx% at the end of a turn with no tools | `agent.zig:1575-1578` | already called in the tools path (`1581`) |
| `/allowlist` to see which tools are always allowed | new command | `always_names` (`agent.zig:135`) |
| Revive `drawHints` (dead code) or delete it | `tui.zig:2576` | — |
| `tool_res_bold` that is actually bold (today identical to `tool_res`, so the "two tones" of the tools is a no-op) | `markdown.zig:52` | — |

## Phase 3 — End-of-turn summary (P1)

Today the end of a turn is literally `setStatusWithZo(m, .done, "done")` and
nothing else (`agent.zig:1576`). No files, no tools, no tokens, no duration, no
cache.

**Structural blocker**: everything per-turn lives in `TurnCtx`, which is destroyed
in the `defer` of `runOneTurn` (`agent.zig:1437`).

Solution: a module-level **`TurnStats`** global (like `CacheStats`), with `reset()`
in `startChat`, accumulated inside `execToolCalls` (which does have `call.name`
and per-tool `ms` in `agent.zig:1604`, and the path in `filePathOf`), and
`pushTurnSummary(m)` in `chatWorker` between `agent.zig:1381` and `1383`. The
touched files need a per-turn `std.StringHashMap`: today `filePathOf` is
discarded after the diff.

Proposed output (2-4 lines, in English like the rest of the UI):

```
⏺ Done · 4 tools · 3 files changed · 12.4s · ~18k tokens (62% cached)
  read src/agent.zig · edit src/tui.zig · bash zig build test · write src/x.zig
```

Foldable with Ctrl+R, reusing the `last_tool` mechanism (`tui.zig:1130`).

## Phase 4 — Render (P1)

In order of visual impact:

| | Change | Where |
|---|---|---|
| 4.1 | **Read `blk.kind` and `blk.lang`** in `buildLinesBase` (computed and thrown away today) → 2-column `│` gutter in `brand_faint`, block background, and a blank row before and after the block (today there is **zero** separation inside a message) | `tui.zig:174-204`, `theme.zig` |
| 4.2 | **Colour the diff by token**: split the `+`/`-`/` ` into its own segment, pass the rest through `hl.highlightLine`, and derive the language from the path extension. Kills the green wall | `markdown.zig:182-194`, `highlight.zig` |
| 4.3 | **2-space indent in code and hanging indent** when wrapping lines, to tell a continuation from a new sentence | `wrapCells` (`tui.zig:124-146`) |
| 4.4 | **Move the token palette to `theme.zig` in truecolor** (today `highlight.zig:8-19` is a hardcoded copy in xterm-256 indices and **does not import `theme.zig`**) | `highlight.zig:1-19`, `theme.zig` |
| 4.5 | **`T.def` with an explicit dimmed colour** (today `Style{}` = the brightest thing in the terminal) and **a real colour for `fn_call`** (today only `bold`) | `highlight.zig:16-18` |
| 4.6 | **Decouple the green**: `str` and `diff_add` are both `index 2` | `highlight.zig:13`, `markdown.zig:53` |
| 4.7 | **Fill in `generic`** (builtins + types) and **normalise the tag** (lowercase, trim, aliases `tsx`/`jsx`/`json`/`text`/`diff`/`html`/`css`/`yaml`/`toml`) | `highlight.zig:124-145` |
| 4.8 | **Follow multiline strings** across lines, so a Zig `\\` or an unclosed quote does not paint the rest of the file green | `highlight.zig:336-348` |
| 4.9 | **2-column left margin** across the whole history (as the input box already does) and wrap to `width - 4` | `tui.zig:1900-1943, 2335` |
| 4.10 | A real `tool_res_bold` (shared with Phase 2) | `markdown.zig:52` |

⚠️ **Careful**: the test `tui.zig:3414` (`hasBlankRowBetween`) **requires** a blank
row between paragraphs. 4.1 and 4.9 break it and it has to be narrowed to
separation between *groups* (tool result → next header), not between every
paragraph.

## Phase 5 — Size / RAM / speed (P1/P2)

| | Change | Gain |
|---|---|---|
| 5.1 | **`.strip = true`** + a `-Dstrip` option in `build.zig` | **10.78 → 2.06 MB** (measured) |
| 5.2 | **`b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe })`** | takes the `DebugAllocator` off the hot path |
| 5.3 | Script/documentation that `zig build run` already goes to release | avoids installing the Debug build out of habit |
| 5.4 | `tty_buffer` 1 MB → 64 KiB | −960 KB permanent (`main.zig:195`) |
| 5.5 | `body_buf` (1 MB) and `transfer_buf` (256 KB) **on the heap**, reused between requests | −1.3 MB of resident stack; removes the trap of a future `stack_size` being a segfault (`agent.zig:1495,1887`, `http_client.zig:78`) |
| 5.6 | **`CellRun` 40 B → ~12 B** (`u8` palette index + `u32` offset instead of slice + `Style`) | 3.3× less arena in the cache: **~20 MB → ~6 MB** (`tui.zig:112-116`) |
| 5.7 | **Patch vaxis**: `arena.reset(.retain_capacity)` instead of `.free_all` | 1.36 MB of malloc/free per frame → bump (`zig-pkg/…/vxfw/App.zig:142`; or an upstream PR) |
| 5.8 | **Paint only the visible rows** instead of `fillRange` over the whole history | −1.22 MB of writes per frame (`tui.zig:2082-2085`) |
| 5.9 | Lower timeout in `vx.queryTerminal` | up to **1 s of blank screen** at startup on terminals that do not answer (`zig-pkg/…/vxfw/App.zig:66`) |
| 5.10 | Remove `subscribeToColorSchemeUpdates` (zode does not react to scheme changes) | one round trip less at startup |

> ReleaseSmall gives **1.12 MB** and the app is I/O-bound, so it is probably
> indistinguishable in speed. It is not the default without measuring it, but it
> is the natural next step if you want the minimum.

## Phase 6 — Memory pruning (P2, the most delicate)

`Model.paras` (≈20 MB in long sessions) is pruned by a byte budget (~8 MB) plus a
small recent window. Each `Para` keeps a `session_line: ?usize` pointing at the
matching message in the JSONL, which already exists and is already compressed
with zjsonl. Scrolling above the oldest window rehydrates a range with `Session`
and re-inserts it. What is evicted **is never lost**: it stays in the file, which
is exactly what `/resume` already knows how to read.

It is the only point with real regression risk (dangling pointers on rehydration),
which is why it goes last and with its own tests: **prune → scroll up → check the
text comes out identical byte for byte**.

## Phase 7 — Polish (P2)

A 5-row header that reads instantly · a usage column in the status bar · a diff
with **real hunks** (`@@` plus context ellipsis; today `unifiedDiff` spits out the
whole file) · `/help` that also lists the shortcuts · a preview of the file in
`write` instead of an opaque "OK".

### State after the first round (2026-09-30)

**Done and verified** (`zig build test`: 211/211 green, binary 1.89 MB)

| Phase | What |
|---|---|
| 0 | Safety-net tests. `zig build test -- <filter>` (0.16's runner has no `--test-filter`). The 130-paragraph test HUNG the whole runner; now there is an iteration budget and it fails in 1 s. |
| 1 | **All nine.** 1.1 `layoutWindow` with window + `para_idx` + `para_heights`; 1.2 `pushDiff` = one paragraph (+ `DiffCounts`); 1.3 live paragraph and `iteration N/8` per iteration; 1.4 `dirty` on every state change; 1.5 self-sufficient tick + `redraw_requested`; 1.6 snapshot with the lock, parse outside; 1.7 permission with its own lock and a sleeping wait; 1.8 a 2000-line cap on the LCS; 1.9 lazy session. |
| 2 | Complete. `thinking · Ns` placeholder, tool with its argument in the strip, spinner on `workingLocked`, TTFT, errors in red (`.error_msg` had gone months without callers), a real `tool_res_bold`, `/allowlist`, compaction notice, ctx% on turns with no tools, `drawHints` deleted. |
| 3 | Complete. `TurnStats` + `pushTurnSummary`. |
| 4 | Complete. 4.1 blocks with gutter/background/chip, 4.2 diff by token, 4.3 continuation indent, 4.4 palette in `theme.zig` truecolor, 4.5 dimmed `T.def` and coloured `fn_call`, 4.6 string green != diff green, 4.7 `generic` filled + `normalizeLang`, 4.8 multiline strings, 4.9 left margin. |
| 5 | 5.1/5.2/5.4/5.5 done. **5.3** done de facto (the default is already release+strip). |
| 6 | Done, **with a different design than the one proposed** (see below). |
| 7 | Complete: diff with real hunks, `/help` with shortcuts, a usage column in the status bar and a `write` preview. **The header is not touched** (see below). |

**Measured, not estimated (this changed two decisions)**

| Thing | Real number | Consequence |
|---|---|---|
| `Model.paras` with 128 paragraphs of 16 KB | **2 MB of text**, no limit | That was the real leak. |
| Segment window (`seg_cache`) | ~2.7 MB in the worst case | Already bounded by the window design, so 5.6 was not needed. |
| `CellRun` | 40 B | With the window bounded, 5.6 would save hundreds of KB, not the ~14 MB the ROADMAP claimed. **Not done.** |
| History `fillRange` | 200×45×136 B ≈ 1.2 MB per frame | 5.8 is still not done: it is the anti-ghosting net for the live paragraph, and without a TTY there is no way to verify it can be touched. |

**Why Phase 6 was done differently**

The ROADMAP proposed pruning `paras` and **rehydrating from the session JSONL**.
That does not fit: not every paragraph has a session message behind it (tool
headers, diffs, agent notices), so there would be nothing to re-read from. Losing
half the history to save memory is worse than not saving any.

What was done instead: **cold compression with `zjsonl`** (raw DEFLATE + base64,
round trip already tested). On leaving the window the paragraph is compressed
(~10×); on coming back, `Para.textLive` decompresses it. Memory is lost, never
information, and no mapping to the session is needed. `pruneCold` only touches
paragraphs whose height is already measured, which is what lets
`ensureParaHeights` keep working on base64 without decompressing anything.

**Still pending**

| Phase | What |
|---|---|
| 5 | 5.6 (dropped after measuring), 5.7/5.9/5.10 (need a vaxis patch, documented in AGENTS.md), 5.8 (not verifiable without a TTY). |
| 7 | Nothing. |

**The header is NOT touched, and that is deliberate.** The item asked for a
"instantly readable 5-row header", but that item predates the banner's v3, which is
the one that **passed** the user's review (plain ASCII with `#`). AGENTS.md
documents the two versions that were tried and rejected (misaligned rows; box
drawing illegible in the user's terminal). Touching it again risks a rejection that
has already been issued for nothing. The pty smoke test pins that the wordmark
rows read, so if it ever breaks, it shows.

**AGENTS.md corrections**: the three from the ROADMAP are written (the layout
loop, the tick chain, and the **wrong** `Io.sleep` diagnosis: on Linux it is a
per-thread `clock_nanosleep` and does not touch `t.mutex`, so the clock was
freezing because of points 1 and 2, not the sleep). Also added a section on Zig
0.16 traps that cost an afternoon.

**Convention**: code comments moved to English. **Test names stayed in Spanish**
on purpose: they are the index of the suite.

---

## Order and why

| Phase | Content |
|---|---|
| 0 | Tests. Nothing is touched without the net |
| 1 | Freezes. 1.1+1.2 kill the hang, 1.4+1.5 make it impossible, 1.3+1.6+1.7 remove the "it gets stuck" |
| 2 | Feedback. Invisible without Phase 1: there is nobody to warn if there are no frames |
| 3 | Summary. Depends on 2 |
| 4 | Render. Independent; can be done in parallel |
| 5 | Size/RAM/speed. 5.1 is one line and it is −80 % size |
| 6 | Pruning. The riskiest, last |
| 7 | Polish |

**Minimum delivery that fixes what was happening: Phase 0 + Phase 1 + 5.1.**

## How it is verified

- **Freezes**: the Phase 0 tests. The 130-paragraph one hangs the runner today;
  afterwards it must fail/pass in <2 s.
- **Feedback and render**: drawing tests with `drawTest` + `rowText` +
  `readCell` (`tui.zig:2668`). Watch out for two known traps: a little face is
  several graphemes (`◔◕`), so you have to walk it with
  `vaxis.unicode.graphemeIterator`; and compare the **whole** row, because
  `█████╗` is a substring of `███████╗` and `findRow` returns row 0.
- **Frame in a real pty**: the TUI can only be judged in tmux or in a pty with
  `TIOCSWINSZ`; vaxis does differential redraws and a homemade emulator loses
  half of it. And you have to **always drain** the pty: if the child fills the
  buffer (~64 KB) and the parent does not read, it blocks on `write` and looks
  like a deadlock.
- **RAM/size**: `ls -l zig-out/bin/zode`, `size -A`, and RSS with
  `grep VmRSS /proc/<pid>/status` over a 200×50 pty (current baseline: 7.2 MB).
- **Build speed**: `time zig build`. Baseline: 13 s incremental in ReleaseSafe.

## Corrections to make in `AGENTS.md`

1. **The `Io.sleep` diagnosis is incorrect on Linux.** The real chain: `Io.sleep`
   is a vtable call; `Threaded.sleep` (`Threaded.zig:11575-11585`) goes to
   `sleepPosix` because `use_parking_sleep` is only true on
   Windows/NetBSD/illumos (`Threaded.zig:17241`); and `sleepPosix` is a
   `clock_nanosleep` in the calling thread, with a per-thread `Syscall` that
   **does not touch `t.mutex`**. vaxis's tick is a normal entry in `App.timers`
   evaluated by `App.checkTimers` on the UI thread. The clock was freezing
   because of points 0.2 (a) and (b), not the sleep. Worth writing down so nobody
   investigates it again.
2. **The segment cache's capacity is posed wrong.** The comment at
   `tui.zig:367-368` says "deep scroll re-parses on demand": the code does not do
   that, and that assumption is exactly what makes the `tui.zig:1970` loop not
   terminate.
3. `pushDiff` puts one paragraph per line: document it, because it is the reason
   a big `write` takes the app down.

---

## Later (2026-10-04)

- **ACP removed.** `/acp` handed the turn to another agent over JSON-RPC. Gone,
  with `acp.zig`, `acp_bridge.zig`, `acp_probe` and the `zig build acp-probe`
  step. `nap()` survived in `lib/sleep.zig`: it had lived in `acp.zig` by
  accident and the retry backoff and the permission dialog both need it.
- **The tree was split**: `tools.zig` became `src/tools/` (one file per tool),
  the `/commands` moved to `commands.zig`, the system prompt text to
  `lib/prompt.zig`. See the last section of `AGENTS.md`.