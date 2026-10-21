# zode — audit of its own weaknesses

**Date:** 2026-10-21 · **Scope:** this repository only (`src/`, `build.zig`, `tools/*.py`,
`TASKS.md`, `AGENTS.md`). The reference implementation was not read: this audit is
about US.

**Method.** Everything below was either measured on this machine or read out of the source.
Where a claim could not be verified, it says so. The one place where I changed code was a
**scratch copy of the tree in `/tmp/opencode/zode-dbg`**, used to instrument and to confirm the
root cause of the open bug. **No file in this repository was modified.**

---

## 1. State of the tree

### 1.1 The test suite is **red right now** — on one live-network test

```
$ zig build test --summary all
+- run test 1236 pass, 1 skip, 1 fail (1238 total)
error: 'tools.web.test.web_search for real: returns results with a URL' failed without output
Build Summary: 5/7 steps succeeded (1 failed); 1236/1238 tests passed (1 skipped, 1 failed)
```

- **1238 tests, 1236 pass, 1 skip, 1 FAIL.** The failure is
  `tools.web.test.web_search for real` — a live scrape of DuckDuckGo. It **passes in
  isolation** (`zig build test -- "web_search for real"` → 1/1) and fails in the full run,
  where it competes with the other live-network tests. AGENTS.md already flags it
  ("falla de vez en cuando contra DuckDuckGo… Está porque el endpoint es un scrape"), so
  it is a known flake — but the honest reading is that **`zig build test` is not green
  today**, and a test that is red for a reason unrelated to the code is a test the team
  learns to ignore. It is also the *only* live-network test in the suite that is not
  gated behind `-De2e`.
- The skip is `braveSearch for real` (needs `ZODE_BRAVE_KEY`, skipped by design).
- The count **moved during this audit** (1221 → 1234 → 1238): another session was editing
  `src/tools/{git,glob,grep}.zig` in the same working tree while the audit ran. The first
  measurement, at the start of the session, was **1220 pass / 1 skip / 1221 total, green**.
  The numbers above are the ones current at the end.
- All `test "…"` blocks in `src/` are in the transitive import closure of
  `src/test_all.zig` (verified by computing the closure): **no test file is orphaned** —
  the failure mode AGENTS.md documents for `src/lsp_test.zig` has been fixed.
- Test blocks per file (top 12):

  | file | tests | file | tests |
  |---|---|---|---|
  | `src/tui.zig` | 163 | `src/lib/web.zig` | 42 |
  | `src/agent.zig` | 140 | `src/chat.zig` | 33 |
  | `src/tools/dispatch.zig` | 75 | `src/lib/markdown.zig` | 29 |
  | `src/palette.zig` | 24 | `src/lib/plan.zig` | 21 |
  | `src/compaction.zig` | 21 | `src/tools/grep.zig` | 18 |

**The important observation is not the number, it is the gap:** ~1236 unit tests, and a
**SIGSEGV on startup in the default release build** that none of them sees. The bug in §2 is
a one-line ordering error in a `defer` pair, in a file with 140 tests, in a function that is
reachable on every single launch (whenever the catalogue cache is cold). The suite is
almost green and the app crashes. That is the measurable statement of where the test
coverage is thin: **it covers pure logic, not lifetime and ordering.**

### 1.2 Build steps — what each one actually does

| step | `build.zig` | what it does | verified |
|---|---|---|---|
| (default) | `:82-86` | `zode` executable, **ReleaseSmall + strip** (1.95 MB) | yes |
| `run` | `:88-91` | runs the exe | — |
| **`debug`** | `:107-130` | **DOES NOT COMPILE.** See below. | **yes — broken** |
| `tool-test` | `:132-152` | headless tool dispatcher exercise | yes, runs |
| `check-probe` | `:166-176` | automatic typecheck against a project with a deliberate error | builds |
| `shell-probe` | `:178-188` | measures the harness overhead of a `bash` call | builds |
| `roster-probe` | `:190-200` | lists the free-model pool | builds |
| `lsp-probe` | `:202-218` | asks a **real** language server about a real file | builds |
| `test` | `:225-263` | the unit suite (Debug, `-De2e` adds the network E2E) | yes, green |
| `ui-frame` | `:278-288` | renders scripted TUI scenes as ANSI (the design harness) | yes, runs |
| `pty-check` | `:304-323` | `pty_smoke.py` + `scroll_repro.py` + `copy_smoke.py` | see §1.4 |

#### `zig build debug` does not build. The step whose entire job is to give you a
symbolizable crash binary produces no binary at all.

```
$ zig build debug
error: the following build command failed with exit code 1:
+- compile exe zode-debug Debug native 2 errors
src/lib/selfupdate.zig:10:49: error: no module named 'build_options' available within module 'root'
src/main.zig:831:37: error: no module named 'build_options' available within module 'root'
```

Cause: `build.zig:107-112` creates `debug_mod` and gives it the `vaxis` import but **not the
`build_options` import**, which `exe_mod` does get at `build.zig:72`. Since commit `3c74fc2`
("feat(build): add version support and integrate self-update"), `src/main.zig:831` and
`src/lib/selfupdate.zig:10` import `build_options`, so the debug module no longer compiles.

**Consequence:** `zig-out/bin/zode-debug` does not exist, so `nm zig-out/bin/zode-debug` has
nothing to inspect. The claim in AGENTS.md ("`zig build debug` → 59 370 296 bytes,
`.symtab` present") was true on 2026-10-06 and **is false today**. This is the same class of
error AGENTS.md itself warns about ("a build step's DESCRIPTION is part of the interface,
and a description that is wrong is worse than no step at all") — and it is precisely what made
the open bug in §2 expensive to diagnose.

**A second, related defect:** `-Dstrip=false` does **not** actually disable stripping.
`build.zig:81` is `if (strip) exe_mod.strip = true;` — there is no `else`, so the module is
left at `null`, which means "the compiler's default", and the compiler's default for
ReleaseSmall is *strip*. Measured:

```
$ zig build -Doptimize=ReleaseSmall -Dstrip=false
$ readelf -SW zig-out/bin/zode | grep -E 'symtab|debug_info'
(no output)
```

But with `exe_mod.strip = false` explicitly (one-line change in a scratch copy) the same
ReleaseSmall build produces `.symtab` (7592 symbols) **and** `.debug_info`. **ReleaseSmall
does emit debug info; the build was throwing it away.** This is what made the §2 diagnosis
take an hour instead of five minutes.

### 1.3 Line counts and module map

```
76 379 lines of Zig in src/ (including tests)
 14 020  src/agent.zig          ← the hub
 12 337  src/tui.zig            ← the hub
  2 505  src/chat.zig
  1 999  src/tools/dispatch.zig
  1 900  src/lib/web.zig
  1 611  src/palette.zig
  1 581  src/lib/markdown.zig
  1 295  src/bgproc.zig
   853  src/main.zig
```

`src/` (stateful, needs the app): `agent`, `tui`, `palette`, `commands`, `main`, `chat`,
`session`, `config`, `bgproc`, `free_auto`, `roster`, `compaction`, `cache_stats`,
`autochk`, `clipboard`.
`src/lib/` (pure, testable without a TUI): 37 modules.
`src/tools/` (one file per tool + `dispatch.zig` + `registry.zig` + `prompts/`).
`src/lsp/` (the language-server client: protocol, client, manager, process, servers, format).

**115 module-level mutable variables** across `src/`, of which **76 are in `src/agent.zig`
alone** (`src/agent.zig:64-7905`). `src/lsp/manager.zig` has 12, `src/chat.zig` 7,
`src/free_auto.zig` 5.

### 1.4 The pty smoke test's verdict depends on leftover state

`tools/pty_smoke.py:147` copies the developer's **real** `~/.config/zode/auth.json` into the
sandbox HOME, and it **never resets the sandbox**. The model-catalogue cache lives at
`~/.config/zode/models/<provider>.json`, so whether the app crashes on startup (§2) depends
on whether a *previous* run left a catalogue behind. Measured, back to back, on the same
binary:

```
# with the catalogue cache present in the sandbox HOME
smoke: 3956 bytes through the pty
  OK   hero: the wordmark is on screen            ... 31 checks
  OK   /which-cmd says not found for a file that is not there
smoke: OK

$ rm -rf /tmp/opencode/zode-smoke-home/.config/zode/models
# with it removed
smoke: 1628 bytes through the pty
  OK   hero: the wordmark is on screen
  FAIL the user prompt echoes
  FAIL ctrl+p opens the command palette
  FAIL /clean answers (dry run)
  FAIL /context says the cwd
  FAIL `!cmd` runs the command
  ...                                        14 FAIL, 17 OK
```

14 failures, all of them "the app died", all of them caused by §2. **The smoke is not
red or green on its own merits; it is red or green depending on a file it never cleans.**
A check that inherits its verdict from a leftover directory is not a check.

---

## 2. The open bug

### 2.1 What AGENTS.md says, and what is actually true

AGENTS.md:4592-4654 ("ReleaseSmall + a saved key = the app stops answering", 2026-10-14)
describes: the app paints its first frame and then **no input of any kind is answered**; the
process is in `S` with 0 % CPU; "every thread parked in a futex or a timed sleep";
"waitpid never fires"; "coredumpctl gets nothing"; and the conclusion
`ReleaseSmall + keyFor != null = the input loop stops answering`.

**Two of those statements are wrong, and they are the two that mattered.**

1. **It is not a hang. It is a SIGSEGV.** The child dies with signal 11. Measured with a
   pty harness that waits on the child *before* killing it:

   ```
   opencode-key    boot=1669 after=0 -> DEAD  alive=False status=139
   ```
   `139 = 128 + 11 = SIGSEGV`. `coredumpctl` **does** get a core (the app's `core_pattern`
   is the systemd pipe, and `ulimit -c` is already `unlimited` here).

2. **It is not ReleaseSmall-specific.** With the network unreachable (a network namespace
   with no route), **every** build dies the same way:

   | build | network + saved key | no network + saved key |
   |---|---|---|
   | ReleaseSmall (default) | **SIGSEGV** @ ~0.9 s | **SIGSEGV** @ ~5.5 s |
   | ReleaseSafe | alive | **SIGSEGV** @ ~6.3 s |
   | Debug | alive | **SIGSEGV** @ ~5.8 s |

   The saved key is not the cause either — it is only what makes the crash **observable**,
   because it is what makes the freed memory get recycled before the stale read happens.

3. It does **not** need a keypress. The app dies on its own, ~0.9 s after launch, without
   any input:

   ```
   opencode-key-nokeypress  died_at=0.929 status=139 bytes=1669   SIGNAL=11 (SIGSEGV)
   opencode-nokey-nokeypress died_at=None status=None bytes=1750  (alive)
   ```

### 2.1b The precise trigger: a **cold model-catalogue cache**

The catalogue cache is `~/.config/zode/models/<provider>.json`. `src/main.zig:730-733`:

```zig
tui.resolveStatusModel(&model);
if (model.status_model_len == 0) {
    agent.catalogWarmupAsync(&model) catch {};
}
```

**The warmup worker only runs when the catalogue is NOT cached.** That is the necessary
condition, and it is the one AGENTS.md never mentions. Measured on the same binary:

| catalogue cache | provider key | result |
|---|---|---|
| cold | present | **SIGSEGV** @ ~0.9 s |
| warm | present | alive |
| cold | absent | alive (the request fails with a 401 in ~50 ms, before the freed block is recycled) |
| cold | provider unreachable | **SIGSEGV** @ ~5.5 s (DNS timeout) |
| warm | provider unreachable | alive |

So the whole formula is:

> **the warmup worker runs (cold catalogue) AND its HTTP request takes long enough
> (~0.9 s with a valid key, ~5.5 s with an unreachable provider) for the 8-byte job block
> to be recycled by the allocator before the stale read.**

That is why the bug looks like "ReleaseSmall + a saved key": the key is what makes the
request slow, and the catalogue cache is what makes the warmup run at all. It also explains
why `tools/pty_smoke.py` is sometimes green (§1.4): the sandbox's catalogue cache decides.

So the AGENTS.md characterisation ("the input loop stops answering") describes the
*symptom* correctly and the *mechanism* incorrectly, and the "ReleaseSmall + saved key"
formula is a coincidence of two independent timing effects. **The bug is always there.**

### 2.2 Root cause — a use-after-free caused by `defer` ordering

`src/agent.zig:8809-8811`:

```zig
fn warmupWorker(job: *WarmupJob) void {
    defer job.model.endWorker();            // ← registered FIRST  ⇒ runs LAST
    defer job.model.allocator.destroy(job); // ← registered SECOND ⇒ runs FIRST
```

`defer` is LIFO. The second line frees the `WarmupJob`; the first line then dereferences
`job.model` **out of the freed block**. `src/tui.zig:3221-3223`:

```zig
pub fn endWorker(self: *Model) void {
    _ = self.workers.fetchSub(1, .seq_cst);
}
```

`self` is read out of freed memory and used as the address of an atomic RMW.

**Symbolized backtrace** (ReleaseSmall with `-Dstrip=false`, `gdb` on the coredump):

```
Program terminated with signal SIGSEGV, Segmentation fault.
#0  atomic.Value(usize).fetchSub (self=<optimized out>, ...) at /usr/lib/zig/std/atomic.zig:57
#1  tui.Model.endWorker (self=<optimized out>) at tui.zig:3222
#2  agent.warmupWorker (job=0x7f81fedc0098) at agent.zig:8810
#3  Thread.callFn__anon_480606 (args=...) at /usr/lib/zig/std/Thread.zig:422
```

Registers at the fault: `rip = 0x11ecff2`, **`rdi = 0x3`** — `rdi` is the address of the
atomic, so the address is `0x3`: `self` is a garbage pointer read out of the recycled
8-byte block. `SEGV_MAPERR`.

**Confirmation of the fix** (applied in the scratch copy only — swapping the two lines so
`endWorker` runs first and `destroy` last):

| scenario | before | after |
|---|---|---|
| network + saved key + cold catalogue | SIGSEGV 3/3 | **answers 5/5** |
| no network + saved key + cold catalogue | SIGSEGV 3/3 | **alive 3/3** |
| network + no key | alive | alive |

The same one-line reorder also removes the "no network" crash, which is **the same bug**,
not a second one: the unreachable provider is just another way of making the warmup's
request slow enough to recycle the block.

**The correct pattern already exists 100 lines away**, which is why this survived review:
`src/agent.zig:8916-8921` (`modelsWorker`) registers `destroyModelsJob` *first* and
`endWorker` *second*, and captures `const m = job.model;` before either. `warmupWorker`
has it backwards.

**Why the AGENTS.md eliminations were wrong:**

- *"Gating the warmup off entirely (`ZODE_NO_WARMUP=1`, temporary) changed nothing."* —
  **`ZODE_NO_WARMUP` does not exist anywhere in the tree** (grep: zero hits in `src/`,
  `tools/`). It was a temporary hack that was reverted. **The claim is currently
  unverifiable**, and it is the claim that pointed away from the right file. When I
  re-implemented the gate in the scratch copy, the warmup was the crash site 3/3 times.
- *"The network"* — the network is not involved in the *cause*, only in the *timing*.
- *"The value of the key"* — correct that the key's value is irrelevant, but the key's
  *presence* matters, because it is what makes the request slow enough for the freed block
  to be recycled.

### 2.3 Why it took a session to find

The three things that were true and were not believed:

1. **The binary was stripped and the "debug" step did not compile.** There was no way to
   get a backtrace. The fix was two lines in `build.zig` (add the `build_options` import to
   `debug_mod`; make `-Dstrip=false` set `exe_mod.strip = false`), after which the whole
   diagnosis took minutes.
2. **The crash was reported as a hang**, because the harness that found it killed the child
   with `SIGKILL` and then read the status of the *kill* rather than of the crash. A pty
   probe that does `waitpid(WNOHANG)` **before** killing reports `status=139` immediately.
3. **The failing path is 8 bytes long.** `WarmupJob` is `{ model: *tui.Model }`. The whole
   bug is that a pointer to the model is read out of a block that was freed one line
   earlier.

### 2.4 Ranked root-cause candidates (post-mortem)

For the record, and because the pre-mortem list is the useful artefact:

| # | candidate | verdict | evidence |
|---|---|---|---|
| 1 | **use-after-free in `warmupWorker`'s defer order** | **CONFIRMED** | symbolized backtrace `agent.zig:8810 → tui.zig:3222`; `rdi = 0x3`; the one-line reorder removes 6/6 crashes |
| 2 | the model-catalog warmup worker being the trigger | confirmed as the *site*, wrong as the *cause* | the crash frame is inside `warmupWorker`; but the cause is the defer order, not the worker. Gating the warmup off removes the crash — and also removes the only reason the app touches the network at startup. |
| 3 | the shared `Io` being used by a detached worker | **eliminated as the cause** | the warmup has its own `std.Io.Threaded` (`agent.zig:8829-8831`); the crash is not in the Io |
| 4 | `std.Io.Threaded.deinit()` racing its own DNS thread | **eliminated** | the crash frame is `endWorker`, not `Threaded.deinit` |
| 5 | a stale/partial `Model` pointer elsewhere | eliminated | `endWorker`'s `self` comes from `job.model` in the freed block |

### 2.5 The same shape, elsewhere (see §4)

`src/agent.zig:8793-8805` (`catalogWarmupAsync`) has a **second, independent** lifetime bug
in the same function — see §4, row H1.

---

## 3. Architecture debt

### 3.1 The hubs

| file | lines | why it is a hub |
|---|---|---|
| `src/agent.zig` | 14 020 | 293 functions, **76 module-level `var`s**, owns the agent loop, the provider routing, the permission table, the palette, the subagents, the compaction, the skill cache, the config arena, the session bootstrap and the slash commands. It is the place where every "second implementation" of a rule ends up. |
| `src/tui.zig` | 12 337 | 80 functions, the `Model` (one struct with ~90 fields), the event handler (`typeErasedEventHandler`, `tui.zig:4985`), the layout engine, the segment cache, the editor glue, the palette/picker/permission/ask overlays and the whole drawing stack. |
| `src/chat.zig` | 2 505 | the wire format. Three providers, three body shapes, one SSE parser. The place where a field-name drift is invisible until a provider rejects it. |
| `src/tools/dispatch.zig` | 1 999 | the tool table and the read-only subset. Already composited from `registry.zig` — the one place where the "two copies that drift" problem was *solved*. |
| `src/palette.zig` | 1 611 | the modal palette: two columns, filtering, scrolling, ownership of the labels. |

**The structural problem with `agent.zig` is not its size, it is its state.** The rule that
`src/lib/*` cannot import outward (`AGENTS.md`, "The split tree") means a module can only
move out of `src/` if it does not read `agent.zig`'s globals. Today
`autochk.zig` moved out; `compaction.zig`, `cache_stats.zig`, `roster.zig` and `src/tools/`
could not. **76 globals is the ceiling on decomposition**, and 76 globals is the debt.

### 3.2 The shared global state that is read from more than one thread

| global | file:line | read by | risk |
|---|---|---|---|
| `saved_keys` | `src/lib/providers.zig:108` | UI thread + every worker | a plain (non-atomic) global pointer to a map; the arena is permanent, so the *map* is safe, but the pointer store is a data race by the letter of the standard |
| `status_model_target` | `src/agent.zig:2334` | UI + `loadUserConfig` | a `?*tui.Model` global; set once at startup, read from `agent.zig:2324` |
| `io_global` | `src/agent.zig:64` | **every** worker | `undefined` until `main.zig:663` assigns it; a probe that reads it before that jumps through a garbage vtable |
| `gpa_global`, `environ_global` | `src/agent.zig:66-67` | every worker | same shape |
| `cur_model`, `cur_provider_id` | `src/agent.zig:1675`, `:1634` | UI draw + workers | already fixed once by copying into `cur_model_buf` / `cur_provider_buf` (`agent.zig:1687`, `:1646`) — **the third and fourth occurrence of the same class**; the pattern is not yet enforced anywhere |
| `chat.last_usage`, `last_error_buf` | `src/chat.zig` | every request | already de-globalised into `StreamCtx` (`mirror_globals`) for parallel subagents |
| `body_buf_heap` + `body_buf_with` | `src/agent.zig:2668-2672` | the chat worker | the allocator is now recorded next to the buffer, so the "free with the wrong allocator" GPF is fixed |
| `cap_thread` | `src/agent.zig:7905` | the main thread only | fine, but it is a global that points into `app.vx` |
| `workers` | `src/tui.zig` (atomic) | every worker | correct (atomic), but see §2: the counter itself was read out of freed memory |

### 3.3 The untested seams

These are the places where **no test can currently reach the failure**, and where the bugs
actually live:

1. **Lifetime and ordering across `defer`s** (§2, §4). ~1236 unit tests, zero of which
   exercise a function whose *exit order* is wrong. This is the single largest blind spot.
2. **The TUI event loop under a real terminal.** `tools/pty_smoke.py` (347 lines) is the
   only thing that exercises it, and **its verdict is decided by a leftover cache file**
   (§1.4) — 31/31 OK or 14 FAIL, depending on a directory the script never cleans.
   `tools/ab_probe.py` (116 lines) is the only thing that can A/B a binary, and its
   `--base` default (`/tmp/opencode/z-base2`) **does not exist on this machine** — it
   refuses to run, which is the right behaviour, but it means the A/B is manual.
3. **The exit path.** `src/agent.zig:13491` (`waitWorkers(2000)`),
   `src/main.zig:770` (`app.run`), `src/tui.zig` `Model.deinit`. Nothing runs this except
   a user quitting.
4. **The network-failure path.** The §2 crash reproduction with no network kills *every*
   build; no unit test simulates a provider that is unreachable.
5. **`src/main.zig:737-747`** — the self-update thread. It is spawned **without**
   `beginWorker`/`endWorker`, so `waitWorkers` does not wait for it, and it uses the
   **shared** `init.io` (`main.zig:746`) for a blocking HTTPS request, on a detached
   thread. AGENTS.md calls this shape out ("a detached worker's blocking I/O must not share
   the event loop's `Io`") and the warmup was hardened for exactly that reason
   (`agent.zig:8829`) — but the self-update thread was not.
6. **`src/tools/dispatch.zig`** has 75 tests, but they test the *dispatcher*. The tools
   themselves (`src/tools/*.zig`, 30 files) have 74 more between them, and `read`,
   `write`, `edit`, `rename`, `git_*`, `notebook_edit` have 0–10 each.

---

## 4. Latent hazards

Every row is a *candidate* with a file:line. "How to confirm" is the cheapest check that
would settle it.

| # | file:line | hazard family | why it matters | how to confirm |
|---|---|---|---|---|
| **H1** | `src/agent.zig:8796` + `:8801` | **double free** | `errdefer gpa.destroy(job)` is armed, and the `catch` branch also calls `gpa.destroy(job)` before `return error.ThreadSpawnFailed`. The errdefer then fires on that error return and frees the block **a second time**. | Read the code; or force `std.Thread.spawn` to fail. In a Debug build the DebugAllocator aborts with "double free". One-line fix: drop the `errdefer` (the catch covers it) or drop the `destroy` in the catch. |
| **H2** | `src/agent.zig:8810-8811` | **pointer into a dead arena / UAF** | **CONFIRMED CRASH.** `defer job.model.endWorker()` runs after `defer job.model.allocator.destroy(job)`. See §2. | Fixed and verified in a scratch copy: 6/6 crashes → 0/6. |
| **H3** | `src/agent.zig:8810` (pattern) | **ownership not in the signature** | `warmupWorker(job: *WarmupJob)` takes a raw pointer to a block it also frees. The type does not say who owns `job`. The correct sibling (`modelsWorker`, `agent.zig:8916`) has the same shape but the right order. | A lint that rejects "a function frees its own `*T` argument" would catch H1 and H2 together. |
| **H4** | `src/main.zig:738-746` | **detached worker not counted / shared `Io`** | The self-update thread is not wrapped in `beginWorker`/`endWorker`, so `waitWorkers` (which runs before the `Io` is destroyed) does not wait for it; and it performs a blocking HTTPS request on the **shared** `init.io`, on a detached thread. | `grep -n "beginWorker" src/main.zig` → no match. Confirm the shape by running with `ZODE_NO_SELF_UPDATE=1` and comparing exit latency under a slow network. |
| **H5** | `src/main.zig:643` + `src/agent.zig:7929-7940` | **global pointing at another object's memory** | `cap_thread` is a global `std.Thread` whose target function writes into `&app.vx`; `stopTermQueryCap` is registered as a `defer` **after** `defer app.deinit()` (`main.zig:641-644`) specifically so it joins first. The ordering is correct *today* and fragile: any new `defer` inserted between them re-introduces the use-after-free. | Read `main.zig:638-646`. A test that asserts "the cap thread is joined before `app.deinit`" would pin it. |
| **H6** | `src/lib/plan.zig:171`, `:177`; `src/lib/checkpoint.zig:152`, `:159`, `:165` | **`catch "literal"` into an owning path** | These return a **string literal** when the arena allocation fails, and the text goes into the *history*, which outlives the turn. If any caller takes ownership and frees it, that is an "Invalid free" of `.rodata` — the exact shape AGENTS.md says has bitten this repo ("a `catch "literal"` is the same (`/free-auto status`)"). | `grep -rn "\.summary(arena)" src/` → `agent.zig:5759`, `:5813`, `:5816`. Check whether the caller frees the returned slice. The fix is `pushInfoFmt` (compose **and** own), which AGENTS.md already introduced for exactly this. |
| **H7** | `src/agent.zig:1634` (`cur_provider_id`), `:1675` (`cur_model`), `:1745` (`cur_answering`), `:2093` (`cheap_router`), `:4505-4507` (`sub_provider_buf`…) | **a global pointing at caller-owned memory** | The `*_buf` pattern exists because of three separate use-after-frees of this class (documented in AGENTS.md). The pattern is applied by hand, per variable, with no test that would notice a new offender. | `grep -n "= .*_buf\[" src/agent.zig`. A test that assigns each global and then frees the source buffer would catch the next one. |
| **H8** | `src/tui.zig:781` (`paras: std.ArrayList(Para)`) | **unbounded growth in a long session** | `paras` is only cleared by `clearHistory` (`tui.zig:4027`). Every paragraph keeps its text (compressed when cold, `tui.zig:1236-1244`), so a long session's memory grows monotonically. `seg_cache` is capped at 128 (`tui.zig:1230`) but `paras` is not. | `tools/ram_probe.py` exists and does not assert a bound. Run a 200-turn session and watch RSS. |
| **H9** | `src/tui.zig:3264` (`shell_out.append`), `src/tui.zig:2864`/`:2891`/`:2903`/`:3253`/`:3304`/`:3395`/`:3572`/`:3729` (`pending.append`) | **unbounded growth** | `pending` and `shell_out` are drained by the draw (`tui.zig:4006`, `:1507`). If the draw stops running (the §2 class of failure!), the queues grow without bound while the workers keep pushing. | The §2 bug is a live demonstration of "the consumer stops and the producers do not notice". |
| **H10** | `src/agent.zig:8890-8892` (`spawnModelsJob`) | **counter imbalance on an error path** | `m.beginWorker()` is called, then `std.Thread.spawn` can fail and `spawnModelsJob` returns the error **without** undoing it. The callers (`agent.zig:8766-8770`, `:8859-8864`) do call `m.endWorker()`, so the count balances — but only because two callers remember. A third caller would leak the counter and make `waitWorkers` spin its whole budget at exit. | Read the three sites. A test that forces a spawn failure would pin it. |
| **H11** | `src/lib/providers.zig:108-113` | **non-atomic global pointer swapped at runtime** | `setSavedKeys` stores a plain `?*StringHashMapUnmanaged` into a module global. `reloadUserConfig` (`agent.zig:2381`) reassigns it while a worker may be reading it through `keyFor`. The map's *arena* is permanent (so the pointee is stable), but the pointer store/load is not atomic. | `grep -n "saved_keys" src/lib/providers.zig`. Make it `std.atomic.Value` — a 3-line change. |
| **H12** | `src/agent.zig:8829-8831` vs `src/agent.zig:8962` | **inconsistent `Io` discipline** | `warmupWorker` got its own `std.Io.Threaded` (hardening, `agent.zig:8817-8828`); `modelsWorker` still uses the **shared** `io_global` (`agent.zig:8962`). Two workers, two policies, one of them still exposes the shared `Io` to a detached thread. | `grep -n "io_global" src/agent.zig` inside the worker functions. |
| **H13** | `src/agent.zig:64` (`io_global: std.Io = undefined`) | **a global that is `undefined` until startup** | Any code path that reads `io_global` before `main.zig:663` jumps through a garbage vtable. This has already produced a "probe prints nothing" round trip (AGENTS.md, "The first mark is inside `runTui`"). | `grep -n "io_global" src/` and check each use is after the assignment. A `?std.Io` would make the mistake a compile error. |
| **H14** | `src/tools/dispatch.zig` (`defs`) + `src/tools/registry.zig` | **a hand-written list that can drift** | AGENTS.md records this failure mode three times ("the authoritative list is `tools/dispatch.zig`'s `defs` — a hand-kept copy is how a list goes stale"). The registry now composes the read-only subset from the table, which fixed *that* copy. But `src/tools/prompts/` (one module per tool) is a fourth place where a tool's identity lives. | `src/tools/prompts/validate.zig` is the shared test. Extend it to assert that the *number* of prompt modules equals the number of registry rows. |
| **H15** | `build.zig:81` | **a build option that does nothing** | `-Dstrip=false` leaves `exe_mod.strip = null` → the compiler default → ReleaseSmall is stripped anyway. The option is documented in the build's own comments as a debugging aid. | `zig build -Doptimize=ReleaseSmall -Dstrip=false && readelf -SW zig-out/bin/zode \| grep symtab` → nothing. One-line fix: `else exe_mod.strip = false;`. |
| **H16** | `build.zig:107-112` | **a build step that does not compile** | `zig build debug` fails: `debug_mod` lacks the `build_options` import. See §1.2. | `zig build debug` → 2 errors. One-line fix. |
| **H17** | `tools/ab_probe.py:77` | **a default path that does not exist** | `--base` defaults to `/tmp/opencode/z-base2`. The script correctly *refuses* to run when a binary is missing (`ab_probe.py:94-101`) — but the default means the tool's headline use case needs a manual step first. | `ls /tmp/opencode/z-base2` → absent. |
| **H18** | `tools/pty_smoke.py:147` + `:151` | **a test that inherits its verdict from leftover state** | It copies the real `auth.json` into the sandbox and **never resets the sandbox**, so the run is green or red depending on whether a previous run left a catalogue cache at `~/.config/zode/models/`. Measured: 31/31 OK with the cache, **14 FAIL** without it — and the 14 failures are the §2 crash, not a regression. | `rm -rf /tmp/opencode/zode-smoke-home/.config/zode/models && python3 tools/pty_smoke.py` → 14 FAIL. Fix: wipe the sandbox HOME (or at least `models/`) at the start of every run. |
| **H19** | `src/main.zig:730-733` | **a startup decision that depends on a cache on disk** | The warmup worker — and therefore the §2 crash — only runs when `model.status_model_len == 0`, i.e. when `~/.config/zode/models/<provider>.json` is absent. The same binary is therefore crash-free or crash-prone depending on a file the user never sees, and the difference is invisible in a diff. | `grep -n "status_model_len" src/` → `agent.zig`, `tui.zig:7155`. The gate is correct (do not re-fetch a catalogue you have); the *consequence* — that it decides whether the app starts — is what makes it dangerous. |

---

## 5. Quality bar

Eleven properties. For each: **what it means**, **how it would be measured**, and **whether
that measurement exists today**. The third column is the honest state of the harness.

| # | property | the instrument | exists today? | the number today |
|---|---|---|---|---|
| **Q1** | **A turn never ends in silence.** Either the model answered, or a human was told why it did not. | a rule in the agent loop + an E2E assertion | **partly.** The E2E exists (`zig build test -De2e`, `src/main.zig`), but it is **off by default** and it needs a provider key, so it is skipped on most machines. The in-process equivalent (a turn that produced neither text nor an error) is **not** asserted anywhere. | unknown on a machine with quota; the E2E is a no-op without `-De2e` |
| **Q1b** | **The unit suite is green, and a red suite means a defect, not a flake.** | `zig build test` in CI, with the live-network tests either fixed or gated | **no.** The suite is red today on `web_search for real`, a scrape that passes in isolation and fails under load. It is not gated behind `-De2e`, so **the default test run depends on the mood of DuckDuckGo.** | 1 red test, 3 runs in a row |
| **Q2** | **The app never dies without a word.** A crash prints the reason and the state on stderr. | `main.zig:770-790` prints on `app.run` error; but a **SIGSEGV** prints nothing | **no.** §2 is a SIGSEGV with an empty stderr. There is no signal handler, and the "why we are leaving, always, on stderr" comment (`main.zig:751`) only covers *clean* exits. | 1 unreported crash per launch with a cold catalogue cache |
| **Q3** | **The TUI answers every key within X ms.** | a pty harness that writes a key and asserts bytes come back, with a timeout | **partly.** `tools/ab_probe.py` does exactly this (it is what found the bug) but it is a *manual* tool with a **nonexistent default base path**, and it is not in `zig build pty-check`. `tools/pty_smoke.py` is in `pty-check` but does not assert a latency bound, and **its verdict depends on a leftover file** (§1.4). | the probe answers in <100 ms when alive; **never** when dead (the process is gone) |
| **Q4** | **The session file is never half-written.** | a reader that can always parse the last line | **partly.** `zjsonl` skips what it cannot parse (AGENTS.md), so a torn line is *skipped* rather than *detected*. Nothing asserts "the last line is complete". | unknown; no test writes a torn line and checks the loader's behaviour |
| **Q5** | **No tool result is silently lost.** | a counter: tool calls in == tool results out | **partly.** `chat.Usage` counts tokens, not results. There is a test that the unknown-tool message names every tool in `defs` (good), but no invariant on the *round trip*. | unknown |
| **Q6** | **A code change is never reported as verified unless a check ran after the last edit.** | `src/lib/exitgate.zig` (`Gate.decide`) + `src/autochk.zig` | **yes, for the rule.** `Gate.decide` is pure and has 12 tests. **But the seam is thin**: `exitGate` itself (the part that waits for a process and reads its exit code) has tests, and `chatWorker` — which must *call* it — does not. | the rule is tested; the wiring is not |
| **Q7** | **No memory outlives its owner.** | a DebugAllocator run of a full turn + the ASAN-ish `zig build test` leak check | **partly.** `zig build test` runs under `std.testing.allocator`, which catches leaks **in the tested code**. It cannot catch a leak in a code path no test reaches (the warmup worker's job, for instance). | the §2 UAF is invisible to it because the freed block was never *leaked*, only *read* |
| **Q8** | **A release build is debuggable.** | `nm zig-out/bin/zode-debug` and `readelf -SW` | **no.** `zig build debug` does not compile, and `-Dstrip=false` does not disable stripping. | 2 broken build affordances |
| **Q9** | **Every build step's description is true.** | `zig build --help` vs. the actual steps | **partly.** The descriptions are excellent prose; two of them are false today (`debug`, `-Dstrip=false`). A one-line test (`zig build debug && nm zig-out/bin/zode-debug`) would pin it. | 2 false descriptions |
| **Q10** | **The repo's own claims are still true.** | a "docs vs. reality" check | **no.** At least four stale claims: (a) `AGENTS.md:4592-4654` mischaracterises the open bug (a SIGSEGV, not a hang; not ReleaseSmall-specific; the trigger is a cold catalogue cache, not the key); (b) `AGENTS.md:4625` eliminates the warmup using `ZODE_NO_WARMUP=1`, **a flag that does not exist in the tree**; (c) `AGENTS.md:4638` says `debug` and `ReleaseSafe` "both answer normally", but `zig build debug` does not compile, so the claim about `debug` is unverifiable; (d) the "A build step whose description is the promise it did not keep" section still describes a `zig build debug` that produces a 59 MB binary. | 4 stale claims, one of which pointed the previous diagnosis at the wrong file |

**What "Claude-Code-grade" would mean here, in one line per property:** a turn that cannot
finish says so; a crash says what it was doing; a keypress is answered or the app is dead
and says so; a file on disk is either complete or absent; a tool call has a result; a
"verified" claim has a check behind it; nothing outlives its owner; a release build can be
symbolized; a build step does what its description says; and the documentation is not
believed to the point of being wrong.

---

## 6. Highest-leverage next work

Ordered by (value × probability of being right) ÷ effort. "Risk" = the risk of the change
itself, not of leaving it undone.

| # | item | effort | risk | touches |
|---|---|---|---|---|
| **1** | **Fix the `warmupWorker` defer order** (swap `agent.zig:8810` and `:8811`). The default build currently SIGSEGVs on startup whenever the catalogue cache is cold — i.e. on a machine that has never run zode against that provider, with a saved key. | 2 lines | trivial | `src/agent.zig:8809-8811` |
| **2** | **Fix `zig build debug`**: add `debug_mod.addImport("build_options", build_options_mod);`. Without it, the next crash costs a session. | 1 line | trivial | `build.zig:112` |
| **3** | **Make `-Dstrip=false` real**: `if (strip) { exe_mod.strip = true; } else { exe_mod.strip = false; }`. ReleaseSmall *does* emit DWARF; the build was throwing it away, and that is what made §2 expensive. | 1 line | trivial | `build.zig:81` |
| **4** | **Add a regression test for the defer-order family.** A test that asserts "a worker that frees its own job struct calls `endWorker` before the free" is hard to write generically, but a **lint** is easy: reject any function that frees its own `*T` parameter and also dereferences it in a `defer`. Even simpler and more valuable: a **pty smoke case** that starts the app with a saved key and asserts it answers. | 1–3 h | low | `src/agent.zig`, `tools/pty_smoke.py` |
| **5** | **Fix the double free in `catalogWarmupAsync`** (H1): drop the `errdefer gpa.destroy(job)` at `agent.zig:8796`, since the `catch` branch already frees it. | 1 line | trivial | `src/agent.zig:8793-8805` |
| **6** | **Make `tools/pty_smoke.py` reset its sandbox HOME** (H18) — wipe `~/.config/zode/models` before each run, and do **not** copy the developer's real `auth.json`. Today the smoke's verdict (31 OK vs. 14 FAIL) is decided by a leftover catalogue file, and the 14 failures are the §2 crash, not a regression. | 30 min | low | `tools/pty_smoke.py:135-155` |
| **7** | **Wire `tools/ab_probe.py` into `zig build pty-check`** and give it a base that exists (or make it build the base itself with `git stash`). It is the instrument that found the bug; it should be a first-class check, not a manual tool with a broken default. | 1 h | low | `build.zig:304-323`, `tools/ab_probe.py` |
| **8** | **Count the self-update thread as a worker and give it its own `Io`** (H4). It is the last detached thread using the shared `Io`, and it is not waited for at exit. | 30 min | medium | `src/main.zig:737-747` |
| **9** | **Make the network-unreachable case a message, not a crash.** The §2.1 table shows **every** build dies when the provider is unreachable and the catalogue is cold. The one-line defer reorder fixes the crash, but the *condition* — the app spends five seconds silently doing a DNS timeout on startup — is still a product defect: the user sees a frozen first frame with no explanation. It needs an explicit "cannot reach <provider>" state. | 2–4 h | medium | `src/agent.zig`, `src/lib/http_client.zig` |
| **10** | **Write the quality-bar checks as executable assertions, and make the default suite deterministic** (Q1b, Q2, Q8, Q9): a `zig build check-build` step that asserts `zig build debug` produces a binary with a `.symtab` and that every `b.step` description matches; and gate (or retry) the live-network tests so `zig build test` is green on a clean machine. A build step whose description is false is worse than no step, and a default test run that depends on DuckDuckGo's mood is not a test. | 1–2 h | low | `build.zig`, `src/tools/web.zig`, `src/lib/web.zig`, `src/tools/registry.zig` |

**Deliberately not in the list** (and why): splitting `agent.zig` (the 76 globals are the
constraint, and reducing the globals is a much bigger job than moving files — §3.1);
replacing the pty smoke with a "better" harness (it is the only thing that sees what vaxis
renders, and its verdict is currently decided by a leftover file rather than by the code);
and the "unbounded `paras` growth" (H8) — real, but it is a design question (what does a
500-turn session do with 200 MB of history?) rather than a bug.

---

## Appendix — how the §2 diagnosis was produced (reproducible)

1. `zig build` → `zig-out/bin/zode` (ReleaseSmall, stripped).
2. A pty probe that does `waitpid(WNOHANG)` **before** `kill -9` reports `status=139`
   instead of "hung". The stock `tools/ab_probe.py` kills first and therefore cannot tell a
   crash from a hang.
3. `coredumpctl list` shows the core; `coredumpctl dump` extracts it.
4. A **symbolized** ReleaseSmall requires `exe_mod.strip = false` (see item 3 above).
   With that, `gdb` on the core names the frame immediately:
   `#1 tui.Model.endWorker (self=<optimized out>) at tui.zig:3222` /
   `#2 agent.warmupWorker (job=…) at agent.zig:8810`, with `rdi = 0x3`.
5. Reordering the two `defer`s in a scratch copy removes 6/6 crashes.

**Everything else in this document was either read out of the source with a `file:line`
citation, or measured with a command that is quoted inline.**
