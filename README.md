# zode

A code agent in the terminal, written in **pure Zig** (no libc, no C
dependencies; the only external one is libvaxis). **1.29 MB** binary, ~6 MB of
RAM, all the code in one directory.

It is not a wrapper around another agent: it speaks HTTP with the provider, runs
the tools on your machine, and decides on its own which tool to call.

```
$ zode
######  ####  ####   ######
##  ## ##  ## ##   # ##
   ##  ##  ## ##   # ###
  ##   ##  ## ##   # ##
######  ####  ####   ######
────────────────────────────────────────
❯ read src/tui.zig and tell me why the scroll does not follow
```

## What it does

- **An agent with tools**: it reads, writes, edits, compiles, searches, and uses
  git. The agent loop decides on its own (with `ask` when the answer changes what
  it does, and in read-only mode it investigates and asks you).
- **Tools in parallel** for the read-only ones, **bash in the background** with
  incremental output, and **ESC kills the whole process group** (the grandchild
  too).
- **Parallel subagents**: several independent searches in one message go to
  subagents at the same time (3 by default, `ZODE_TASK_PARALLEL`), each with its
  own throwaway window, and the reports come back in the order you asked for them.
- **`write` and `edit` take several files at once** — `files: [...]`, max 8.
  Renaming a symbol is one call, not one per file, and **the file that failed is
  named with the reason**, because a rename applied to nine files out of ten and
  not reported is a codebase that does not compile.
- **`read` takes several paths at once** — one call is one round trip, and a round
  trip is a whole request. On a free tier (`total_credits: 0`, measured) every
  request is also a chance to be rate-limited plus three backoff waits.
- **`!` in the input**: `!git status` runs the command and puts its output into
  the context, spending neither a turn nor a token.
- **Skills**: folders of instructions loaded **only when they are needed**. The
  prompt carries the name and when to use it; the body does not.
- **Two-tier context compaction**: old tool results are elided without losing the
  history, and if it still does not fit, a summary is asked for. The budget is
  the **model's own** context window when the provider publishes one, and
  `/context` says which of the three numbers it used.
- **File cache**: a `read` of something that has not changed is not sent again.
  It is the most direct token saving there is.
- **A prompt cache you can see**: measured 2026-10-04 with an identical 3.5k
  prefix, three requests in a row —
  `openrouter/free` (a **router**) answered 3583 / 3273 / 3381 prompt tokens and
  served **0%** from cache, and a fixed model answered 3611 / 3613 / 3613 and
  served **3328 cached (98%)**. A router picks a different upstream per request,
  the tokenizers differ and the caches are not shared, so no amount of prefix
  tuning can make one hit. zode says so when you pick one, and `/cache`
  diagnoses it from the evidence afterwards rather than from a list.
- **Providers**: OpenCode, OpenRouter, Anthropic (native API with prompt
  caching), OpenAI, Groq, DeepSeek, and local (Ollama/LM Studio). You connect
  them from the TUI itself, without editing files.
- **`rename`**: renames a symbol everywhere it appears as **real code**, in one
  call, and reports every file it touched. A name inside a string, a comment or a
  longer identifier is left alone — measured, not assumed. A rename applied by the
  model one `edit` at a time lands on nine files out of ten and does not say which
  one it missed; this cannot miss one silently.
- **`refs`**: where a symbol is defined and where it is used, **in one call and
  with the two separated**. It knows the declaration shapes of zig, rust, go,
  python, js/ts, c and sh, steps over Go method receivers, skips comments and does
  not match `foo` inside `foobar`. It is not an AST and it does not pretend to be:
  it saves the model from guessing the declaration shape, running two greps and
  working out which hit is the definition — three round trips, and a round trip is
  a whole request.
- **The repository as tools**: `git_status`, `git_diff` and `git_log` with
  **fixed arguments** — no argument reaches git, so there is no new injection
  surface, and `bash` is still there for a commit or a checkout.
- **`/free-auto`**: spreads the turns across the free models each provider
  publishes, and when one runs out of quota it **carries on by itself** with the
  next one.

## Install

Grab the binary and you are done. There is nothing else to install.

```bash
./zode
```

## Build from source

You need **Zig 0.16.0**.

```bash
zig build                    # release stripped, 1.29 MB (ReleaseSmall)
zig build test               # 500+ unit tests, in Debug
zig build -Doptimize=Debug   # with symbols, for when something crashes
```

`zig build` steps:

| Step | What it does |
|---|---|
| `zig build` | The usual binary |
| `zig build debug` | Same but **unstripped**, with a readable stack trace |
| `zig build test` | The tests (`-- <filter>` runs only the ones whose name matches) |
| `zig build tool-test -- "command"` | The tools headless, to try one without opening the TUI |
| `zig build roster-probe` | Which providers you have a key for, and how many free models each publishes |

## First steps

1. `./zode` and press **Ctrl+T** to pick a provider and a model, or **Ctrl+A** to
   paste the provider key (saved in `~/.config/zode/auth.json` with 0600
   permissions).
2. The environment works too, which is what the scripts will use:
   `ZODE_OPENCODE_KEY=… ./zode`.

No-TUI mode, to try it without a terminal and for scripts:

```bash
./zode --models              # list the provider's models
./zode --chat "find my TODOs and tell me which ones are urgent"
./zode --resume             # reopen the last session
```

### There is no default model

A model name written into the code is a time bomb: the day the provider retires
it, **every** request starts failing with a 403 that explains nothing. So the
providers ship without a model and zode **does not guess**:

- if there is a `ZODE_MODEL` or you picked one with `/model`, that one is used;
- if not, zode **asks the provider** what the catalogue is and picks the first
  free one, and says on screen which one it chose and why;
- if the catalogue cannot be downloaded it **sends nothing**: it tells you and
  opens the picker, instead of spending a turn on a 403.

## Commands

They start with `/` and autocomplete with **Tab**. **Ctrl+P** opens them in a
palette that **runs** the one you pick.

| | |
|---|---|
| `/help` | this list |
| `/model` | model picker (modal, two columns: providers \| models) |
| `/provider` | provider picker |
| `/providers` | list the providers and whether they have a key |
| `/models` | models of the active provider |
| `/use <provider> [model]` | change provider and model at once |
| `/effort [low\|medium\|high\|…]` | reasoning effort (no argument: opens the picker) |
| `/free-auto [on\|off\|status]` | rotate across free models when one runs out of quota |
| `/plan` | clear the visible task list |
| `/undo` | put the files back the way they were before a turn |
| `/clean [yes]` | purge zode's leftovers (simulates by default) |
| `/yolo` | automatic permissions |
| `/allowlist` | tools that are always allowed (persisted) |
| `/ask [on\|off]` | read-only mode (also **Shift+Tab**) |
| `/skills` | which skills there are and where they come from |
| `/bg [list\|kill <id>\|killall]` | background commands |
| `/new` · `/resume` | new session / reopen the last one |
| `/context` | tokens used against the budget |
| `/bench` | session numbers: turns, iterations, first token |
| `/cache` | the provider's cache hit rate |
| `/session` | id, file and messages of the session |
| `/quit` | exit |

### Shortcuts

| | |
|---|---|
| `Ctrl+P` | command palette |
| `Ctrl+T` | model palette |
| `Ctrl+A` | connect a provider |
| `Ctrl+L` | clear the view (the session file is untouched) |
| `Ctrl+R` | fold/unfold the last result |
| `Ctrl+U` / `Ctrl+D` | half a page of scroll |
| `PageUp` / `PageDown` | a page |
| `Shift+Enter` | newline (Enter sends) |
| `Shift+Tab` | read-only mode |
| `Esc` | stop the turn, kill the command, or answer "you decide" |
| `Tab` | complete a `/` command |
| `↑` / `↓` | prompt history |

## Configuration

**By environment.** You only need a key if you are not using Ctrl+A:

| Variable | What it does |
|---|---|
| `ZODE_<PROVIDER>_KEY` | that provider's key (`ZODE_ANTHROPIC_KEY`, `ZODE_GROQ_KEY`, …) |
| `ZODE_API_KEY` | generic key, the last resort |
| `ZODE_PROVIDER` | starting provider |
| `ZODE_MODEL` | starting model |
| `ZODE_EFFORT` | `low` \| `medium` \| `high` |
| `ZODE_BASE_URL` / `ZODE_MODELS_URL` | endpoints, for your own providers or gateways |
| `ZODE_CONTEXT_LIMIT` | context tokens (128k by default; the compaction budget is 80% of it) |
| `ZODE_MAX_ITER` | agent loop iterations per turn (12) |
| `ZODE_TASK_PARALLEL` | subagents at once (3; `1` = in series) |
| `ZODE_RECENT_WINDOW` | recent messages compaction leaves alone (8) |
| `ZODE_AUTO_BG` | `0` turns off auto-backgrounding slow verifications |
| `ZODE_CHEAP_TURN` | a small model id: the main turn goes to it and falls back if it will not answer (off by default) |
| `ZODE_CHEAP_MODEL` | the same thing, named separately, for when the flag is just `1` |
| `ZODE_FREE_AUTO` | `1` starts with `/free-auto on` |
| `ZODE_RESUME` | `1` reopens the last session |
| `ZODE_DBG_ERR` | `1` dumps the status and body of every response to stderr |
| `ZODE_YES` | `1` makes `/clean` apply without asking (for when the model runs it) |

**By file**, in `~/.config/zode/`:

- `config.json` — your own providers (id, base_url, models_url, `key_env`,
  `default_model`, `kind`), plus the default `provider`/`model`. Compiled
  providers cannot be shadowed: the built-in wins.
- `auth.json` — the keys you paste with Ctrl+A. **0600**, written to a temp file
  and renamed. Never in `config.json`, which people version.
- `skills/<name>/SKILL.md` — your skills.

**In the project**, from wherever you launch it:

- `AGENTS.md` (or `CLAUDE.md`) — project instructions. It looks in the current
  directory and, failing that, at the repository root.
- `.zode/skills/<name>/SKILL.md` — harness skills.
- `.agents/skills/<name>/SKILL.md` — skills, in the convention shared with other
  agents.
- `sessions/zode-*.jsonl` — the sessions. Compressed: the big lines go through
  DEFLATE and base64.

## Skills

A skill is a folder with a `SKILL.md` and `name` / `description` frontmatter.
Only the name and the description go into the prompt; the body is read when the
model decides it needs it, through the `skill` tool.

```markdown
---
name: pty-tests
description: after touching the drawing code in tui.zig
---

Verify TUI changes in a real pty: `python3 tools/pty_smoke.py`.
```

The `description` has to say **when** to use it, not what it contains: "after
touching the drawing code in tui.zig" decides well; "notes about pty" makes the
model guess. A project's skills **override** the global ones instead of merging:
half a skill from another project is worse than not having it.

`/skills` says which ones exist and where they come from.

## Sessions

Every turn is written to `sessions/zode-<id>.jsonl` (one line per event, with
`tool_calls` raw so the replay is faithful). `/resume` reopens the last one and
`/undo` gives you back **files**, not messages: the session is append-only and
rewriting it halfway through a turn has no explanation.

## Development

```bash
zig build test                              # unit tests
zig build && python3 tools/pty_smoke.py     # smoke test in a real pty
python3 tools/measure.py ./zig-out/bin/zode # startup and RSS
python3 tools/esc_kill_pty.py               # ESC kills the grandchild, not the shell
```

`tools/pty_smoke.py` uses its own `HOME` on purpose: the app writes
`~/.config/zode/auth.json` and `sessions/`, and an automated test must not touch
the config of whoever runs it.

## Architecture

Two folders, and the line between them is whether the module can be tested
without a terminal:

```
src/                    what needs the TUI, a thread or the network
  main.zig              CLI: --models / --chat / TUI / --resume
  tui.zig               the TUI (vxfw): drawing, input, scroll, palettes
  agent.zig             agent loop, permissions, turns, session state
  commands.zig          the /commands and the tables /help prints
  chat.zig              streaming SSE client + parser + native Anthropic
  tools/                the 16 tools, one per file
    dispatch.zig        the name the model sent -> the function that runs
    common.zig          the helpers more than one tool needs
    read.zig  write.zig  edit.zig  bash.zig  glob.zig  grep.zig
    list_files.zig  web.zig  think.zig  todo.zig  bg.zig  git.zig
    refs.zig  rename.zig  errors.zig
  bgproc.zig            background commands
  palette.zig           the Ctrl+P / Ctrl+T modal palette
  session.zig           compressed JSONL sessions
  config.zig            the user's config.json
  compaction.zig        context budget, elision and summary
  cache_stats.zig       the provider's cache hit rate
  roster.zig            the free-model pool
  free_auto.zig         /free-auto over the pool
  roster_probe.zig      the `zig build roster-probe` probe
  test_all.zig          the test aggregator
  bin/                  helper executables (tool_test)
  tools_root.zig        the `tools` module, re-exporting the dispatcher

src/lib/                modules that test on their own, no TUI and no network
  readcache.zig         which files have already been sent to the model
  project.zig           cwd, repository root and git branch
  prompt.zig            the system prompt text
  sleep.zig             nanosleep that does not touch the shared Io
  skills.zig            the format of a SKILL.md
  skillstore.zig        skill discovery on disk
  mentions.zig          @file
  markdown.zig          markdown + unified diff
  highlight.zig         universal syntax highlighting
  web.zig               HTML -> text, and the search result parser
  models.zig            the model catalogue and its metadata
  providers.zig         compiled providers + key precedence
  provider.zig          per-environment config (compat)
  http_client.zig       HTTP JSON on top of std.http.Client
  subagent.zig          the subagent's report
  ask.zig               the `ask` tool
  plan.zig              the visible task list
  checkpoint.zig        /undo's snapshots
  editor.zig            the one-line editor
  bench.zig             /bench
  clean.zig             /clean
  verify.zig            which verifications are slow enough to background
  router.zig             which model answers the main turn (cheap, or yours)
  symbols.zig            declarations per language + the string/comment mask
  regex.zig             a mini regex engine
  mascot.zig            Zo
  theme.zig             colours
  zjsonl.zig            DEFLATE + base64 per line
```

`src/lib/` is not "the small files": it is **the ones that can be tested without
starting the app**. That is why `roster.zig` does not move: it depends on
`config.zig`, which already depends on the chat client.

`src/tools/` is the interesting case: the tools ARE nearly all pure (they read
files, they hit the network) but the **dispatcher** needs the background process
registry, which lives in the `Model`. The answer was to split the file rather than
move it: each tool in its own file, `dispatch.zig` holding what it needs from the
`Model`. `ask`, `task` and `skill` are NOT there (they need the `Model` for the
dialog, the worker and the skills) and are intercepted in `agent.zig`, which is
where they already were.

Any OpenAI-compatible provider works: OpenCode, OpenRouter, Groq, DeepSeek and
any gateway that speaks the same format, by changing the `base_url`.

`AGENTS.md` has the conventions of the code and **why** each unusual decision
cost something (which Zig 0.16 traps have already been paid for, which memory
bugs exist, and what must NOT be done). It is the file to read before touching
anything.